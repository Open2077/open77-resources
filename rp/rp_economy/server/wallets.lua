-- rp_economy / server/wallets.lua: the wallet cache over the open77_transactions coordinator.
--
-- The coordinator owns every balance (cash:<subject>, bank:<subject>, soc:<name>); this file
-- keeps a read cache of the wallets in use and submits every change as a coordinator operation
-- (double-entry money lines, A13 §3.2). Two ways in:
--
--   Wallets.legacy(spec)  synchronous, never yields: the write-behind facade behind the 1.x
--                         exports (add / remove / rp_bank's deposit ...). It checks the cache,
--                         applies the change to the cache at once and submits the operation in
--                         the background. No stronger than 1.x, but deltas (ordering-safe), one
--                         source of truth, and no KVP fork.
--   Wallets.run(spec)     yields: one atomic operation (pay, charge, sale, refund, invoice),
--                         answered with the coordinator's receipt or a typed refusal.
--
-- Ordering. A debit is accepted against the displayed balance, which already counts earlier
-- write-behind credits that may not have reached the coordinator. Such a debit therefore waits
-- until every earlier write-behind credit to the wallet it debits has settled; nothing else is
-- ordered (debits commute once their sum fits, credits never fail but at the 1e12 ceiling).
-- Dependencies only point to older operations, so the oldest pending one can always run.
--
-- Cache arithmetic. `snap` is the last coordinator snapshot of a wallet (balance, version).
-- The displayed balance is snap + the effect of every tracked operation the snapshot does not
-- contain yet: a write-behind change counts at once; an atomic operation's debit counts while it
-- is in flight (the coordinator holds it); its credit counts once committed. A committed
-- operation is "covered" when a snapshot's version reaches the version its receipt reports for
-- that wallet, and is then forgotten.

Wallets = {
    accounts = {},   -- [accountId] = cached wallet
    byPlayer = {},   -- [playerId] = { subject, identifier, cash = accountId, bank = accountId }
    entries = {},    -- [opId] = operation submitted by this generation
    own = {},        -- [attempt opId] = entry (filters our own committed events)
    seq = 0,
    bootTag = "0",
}

local W = Wallets
local cfg = EconomyConfig

local function log(fmt, ...)
    print(("[rp_economy] " .. fmt):format(...))
end

local function now() return Open77.time.monotonic() end

local function base36(n)
    local digits = "0123456789abcdefghijklmnopqrstuvwxyz"
    n = math.tointeger(n) or 0
    if n <= 0 then return "0" end
    local out = {}
    while n > 0 do
        local d = n % 36
        out[#out + 1] = digits:sub(d + 1, d + 1)
        n = n // 36
    end
    return string.reverse(table.concat(out))
end
W.base36 = base36

-- FNV-1a 32 as 8 hex digits: shortens an over-long key inside an operation id.
local function fnv32(s)
    local h = 2166136261
    for i = 1, #s do
        h = (h ~ s:byte(i)) * 16777619 % 4294967296
    end
    return string.format("%08x", h)
end
W.fnv32 = fnv32

-- An operation id `<prefix><key>` within the coordinator's rule: 96 bytes of [A-Za-z0-9_.:@-].
-- A longer key, or one with another character (the `~` of a later character's subject), is
-- cut and named by its hash.
function W.opIdFor(prefix, key)
    local id = prefix .. key
    if #id <= 96 and id:match("^[A-Za-z0-9_.:@%-]+$") then return id end
    return prefix .. key:gsub("[^A-Za-z0-9_.:@%-]", "_"):sub(1, 40) .. "." .. fnv32(key)
end

-- ---------------------------------------------------------------------------------------------
-- Keys

local ACCOUNT_KIND = { cash = "cash", bank = "bank", soc = "soc" }

function W.kindOf(id)
    local ns = type(id) == "string" and id:match("^(%a+):") or nil
    return ns
end

function W.isWallet(id) return ACCOUNT_KIND[W.kindOf(id) or ""] ~= nil end
function W.isSys(id) return W.kindOf(id) == "sys" end
function W.isContainer(id)
    local ns = W.kindOf(id)
    return ns == "char" or ns == "veh" or ns == "stash" or ns == "world"
end

-- A durable subject usable as an account key: the coordinator's lint (A13 §3.1.1) refuses
-- session-like and all-digit keys, and an account id is at most 96 bytes. `~` is the separator
-- of a later character's subject (`<accountId>~<n>`, contract 12.8).
function W.validSubject(s)
    if type(s) ~= "string" or #s < 1 or #s > 90 then return false end
    if not s:match("^[A-Za-z0-9_.@~%-]+$") then return false end
    if s:match("^%d+$") or s:match("^session") then return false end
    return true
end

-- Society names as rp_bank 1.x accepted them, lower-cased.
function W.cleanSociety(name)
    if type(name) ~= "string" or #name < 1 or #name > 64 or not name:match("^[%w_%-%.]+$") then return nil end
    return name:lower()
end

-- `sys:<resource>:<label>` -> mint budget key (server/mint.lua).
function W.mintKeyOf(sysId)
    local resource, label = sysId:match("^sys:([^:]+):(.+)$")
    if not resource then return nil end
    return Mint.keyOf(resource, label)
end

-- ---------------------------------------------------------------------------------------------
-- Readiness

function W.ready()
    return Tx.healthy and Migrate.ready()
end

function W.notReadyReason()
    if not Tx.healthy then return "store_unavailable" end
    return Migrate.reason or "migration_pending"
end

-- ---------------------------------------------------------------------------------------------
-- The cache

local TERMINAL = { committed = true, failed = true }

function W.account(id, kind, key)
    local a = W.accounts[id]
    if a then return a end
    a = {
        id = id, kind = kind, key = key, loaded = false, exists = false,
        snapBalance = 0, snapVersion = -1, readSeq = 0, adoptedSeq = 0,
        tracked = {}, published = nil, playerId = nil,
    }
    W.accounts[id] = a
    -- Operations already in flight for this wallet (a credit to a player who just joined).
    for opId, e in pairs(W.entries) do
        if e.effects[id] and e.state ~= "failed" then a.tracked[opId] = e end
    end
    return a
end

local function effectOn(e, a)
    local d = e.effects[a.id]
    if not d or d == 0 or e.state == "failed" then return 0 end
    if e.state == "committed" then
        local v = e.versions and e.versions[a.id]
        if v ~= nil and v <= a.snapVersion then return 0 end
        local seq = e.coverSeq and e.coverSeq[a.id]
        if seq ~= nil and seq <= a.adoptedSeq then return 0 end
        return d
    end
    if e.legacy or d < 0 then return d end
    return 0
end

function W.display(a)
    if not a then return 0 end
    local balance = a.snapBalance
    for _, e in pairs(a.tracked) do balance = balance + effectOn(e, a) end
    return balance
end

local function prune(a)
    for opId, e in pairs(a.tracked) do
        if e.state == "failed" or (e.state == "committed" and effectOn(e, a) == 0) then
            a.tracked[opId] = nil
        end
    end
end

-- An operation whose effect on `a` is counted but whose outcome the cache does not know yet:
-- a snapshot taken now could contain it AND count it again, so adoption waits.
local function inflightOn(a)
    for _, e in pairs(a.tracked) do
        if not TERMINAL[e.state] and effectOn(e, a) ~= 0 then return true end
    end
    return false
end

function W.adopt(a, snap, seq)
    if type(snap) ~= "table" then return false end
    local version = math.tointeger(snap.version) or 0
    if a.loaded and version < a.snapVersion then return false end
    a.loaded = true
    a.exists = snap.exists == true
    a.snapBalance = math.tointeger(snap.balance) or 0
    a.snapVersion = version
    if seq and seq > a.adoptedSeq then a.adoptedSeq = seq end
    prune(a)
    return true
end

-- Loads or re-reads one wallet from the coordinator. Yields. true | nil, reason.
function W.fetch(a)
    a.readSeq = a.readSeq + 1
    local seq = a.readSeq
    local snap, why = Tx.read(a.id)
    if type(snap) ~= "table" then
        Tx.noteFailure(why)
        return nil, why or "store_unavailable"
    end
    W.adopt(a, snap, seq)
    return true
end

-- Publishes a balance change of a cached wallet: rp_economy:changed (cash of an online player,
-- the 1.x event) and rp_economy:walletChanged (every kind; rp_bank re-emits rp_bank:changed).
function W.publish(a, reason)
    local balance = W.display(a)
    local before = a.published
    a.published = balance
    if before == nil or before == balance then return balance end
    local delta = balance - before
    if a.kind == "cash" and a.playerId then
        TriggerEvent("rp_economy:changed", a.playerId, balance, delta, reason)
    end
    TriggerEvent("rp_economy:walletChanged", a.kind, a.playerId, a.key, balance, delta, reason)
    return balance
end

-- Re-reads a wallet in the background (coalesced), once nothing counted is in flight on it.
function W.refresh(id)
    local a = W.accounts[id]
    if not a then return end
    if a.refreshing then a.again = true return end
    a.refreshing = true
    CreateThread(function()
        repeat
            a.again = false
            local waited = 0
            while inflightOn(a) and waited < 30000 do
                Wait(100)
                waited = waited + 100
            end
            W.fetch(a)
            W.publish(a, "sync")
        until not a.again
        a.refreshing = false
    end)
end

-- A society wallet, loaded in the background on first sight.
function W.society(name)
    local id = "soc:" .. name
    local a = W.account(id, "soc", name)
    if not a.loaded and not a.loading and Tx.healthy then
        a.loading = true
        CreateThread(function()
            local ok = W.fetch(a)
            a.loading = false
            if ok then a.published = W.display(a) end
        end)
    end
    return a
end

-- ---------------------------------------------------------------------------------------------
-- Operations

local function computeEffects(lines)
    local effects = {}
    for _, l in ipairs(lines) do
        if l.money then
            if W.isWallet(l.from) then effects[l.from] = (effects[l.from] or 0) - l.money end
            if W.isWallet(l.to) then effects[l.to] = (effects[l.to] or 0) + l.money end
        end
    end
    return effects
end

local function linesHash(kind, lines)
    local parts = { kind or "" }
    for _, l in ipairs(lines) do
        if l.money then
            parts[#parts + 1] = ("m|%d|%s|%s"):format(l.money, l.from, l.to)
        elseif l.instance then
            parts[#parts + 1] = ("u|%s|%s|%s"):format(l.instance, l.from, l.to)
        else
            parts[#parts + 1] = ("i|%s|%d|%s|%s"):format(l.item, l.count, l.from, l.to)
        end
    end
    return table.concat(parts, ";")
end

local function newEntry(opId, spec)
    return {
        opId = opId, attemptOpId = opId, attempt = 1,
        kind = spec.kind, actor = spec.actor, lines = spec.lines,
        hash = spec.requestKey or linesHash(spec.kind, spec.lines),
        effects = computeEffects(spec.lines), legacy = spec.legacy == true, single = spec.single == true,
        tokens = spec.tokens or {}, reason = spec.reason, caller = spec.caller,
        state = "queued", createdAt = now(),
    }
end

local DEFINITIVE = {
    insufficient_funds = true, insufficient_items = true, capacity_exceeded = true, balance_limit = true,
    invalid_spec = true, invalid_op_id = true, invalid_account = true, unknown_item = true,
    invalid_count = true, invalid_amount = true, namespace_denied = true, vehicle_not_tracked = true,
    instance_unavailable = true, exceeds_reservation = true, operation_too_large = true,
    unknown_operation = true, expired = true, cancelled = true, op_id_conflict = true,
    store_failed = true, not_owner = true, stale_version = true, unknown_account = true, invalid_key = true,
}
-- Refusals that a replay of an already committed operation can still produce. The coordinator
-- reads the operation row itself before reporting a business refusal (697e9e2f, contract 13.5:
-- insufficient_*, capacity_exceeded, instance_unavailable, balance_limit, stale_version), so
-- those replay there. Left: op_id_conflict when a cash-then-bank split computed again from
-- today's balances differs from the committed one (the operation id names the business
-- operation, A13 §3.4), and unknown_account (a container gone since).
local REPLAY_PROBE = { unknown_account = true, op_id_conflict = true }
-- Proven NOT committed: a fresh attempt is safe (write-behind only, under a new attempt id
-- `<opId>-r<n>`: always safe; the coordinator would also take the same id again after a failure,
-- but never after a fence, `aborted`).
local NOT_COMMITTED = { conflict = true, store_unavailable = true, coordinator_unavailable = true, aborted = true }

-- The business reason travels with the operation (contract 7.2: 1..64 bytes, no control
-- character; stored on the receipt and every journal row, read back by history). Not part of
-- the request hash, so it never turns a replay into a conflict.
local function coordinatorReason(reason)
    if type(reason) ~= "string" or reason == "" or reason:find("%c") then return nil end
    return reason:sub(1, 64)
end

local function specOf(e)
    return { opId = e.attemptOpId, kind = e.kind, actor = e.actor, lines = e.lines, reason = coordinatorReason(e.reason) }
end

-- A hint for a HUD (B7): the unsettled operations on a connected player's wallet changed -- one
-- entered in_doubt, or an atomic or in-doubt one settled. Listeners coalesce and re-read
-- (walletStatus); write-behind changes already raise rp_economy:changed / walletChanged.
local function pendingChanged(e)
    local seen = {}
    for id in pairs(e.effects) do
        local a = W.accounts[id]
        if a and a.playerId and not seen[a.playerId] then
            seen[a.playerId] = true
            TriggerEvent("rp_economy:pendingChanged", a.playerId)
        end
    end
end

local function settleCommitted(e, receipt)
    e.state = "committed"
    e.receipt = receipt
    -- A replayed receipt's versions are not this commit's (the stored receipt has none, the
    -- duplicate-key path reports the mirror before its reload): re-read instead.
    e.versions = (type(receipt.versions) == "table" and receipt.replay ~= true) and receipt.versions or {}
    e.coverSeq = {}
    e.settledAt = now()
    for id, delta in pairs(e.effects) do
        local a = W.accounts[id]
        if a then
            if delta > 0 then a.exists = true end
            if e.versions[id] == nil then
                e.coverSeq[id] = a.readSeq + 1
                W.refresh(id)
            end
            W.publish(a, e.reason)
        end
    end
    if not e.legacy or e.doubted then pendingChanged(e) end
end

local function settleFailed(e, reason, info)
    e.state = "failed"
    e.failure = reason
    e.failInfo = info
    e.settledAt = now()
    for _, token in ipairs(e.tokens) do Mint.release(token) end
    e.tokens = {}
    for id in pairs(e.effects) do
        local a = W.accounts[id]
        if a then
            a.tracked[e.opId] = nil
            W.publish(a, "reverted:" .. tostring(reason))
        end
    end
    if not e.legacy or e.doubted then pendingChanged(e) end
    if e.legacy then
        Open77.log.error(("[rp_economy] write-behind %s (%s) refused by the coordinator: %s; the cached change is reverted")
            :format(e.opId, tostring(e.kind), tostring(reason)))
        TriggerEvent("rp_economy:writeBehindFailed", e.opId, tostring(reason), e.kind, e.lines)
    end
end

local function waitHealthy(deadline)
    while not Tx.healthy and now() < deadline do Wait(500) end
    return Tx.healthy
end

-- Runs one queued operation to a terminal state. Yields.
local function process(e)
    local giveUp = e.createdAt + cfg.writeBehind.giveUpSeconds
    local backoff = cfg.writeBehind.backoffMs
    while true do
        e.state = "submitting"
        W.own[e.attemptOpId] = e
        local receipt, reason, info = Tx.call("transfer", specOf(e))
        if type(receipt) == "table" then return settleCommitted(e, receipt) end
        if reason == "already_committed" and type(info) == "table" and type(info.receipt) == "table" then
            e.replayed = true
            return settleCommitted(e, info.receipt)
        end
        if reason == "in_doubt" or reason == "busy" then
            e.state = "in_doubt"
            if not e.doubted then e.doubted = true pendingChanged(e) end
            local outcome, detail = Tx.resolve(e.attemptOpId, math.huge)
            if outcome == "committed" then return settleCommitted(e, detail or { opId = e.attemptOpId }) end
            if outcome == "failed" then
                reason = detail or "failed"
            else
                reason = "aborted"
            end
            info = { state = outcome }
        end
        log("operation %s attempt %d (%s): %s", e.attemptOpId, e.attempt, tostring(e.kind), tostring(reason))
        Tx.noteFailure(reason)
        if DEFINITIVE[reason] and REPLAY_PROBE[reason] then
            -- The row says whether the id already committed (a replay whose recomputed lines
            -- differ, or whose container is gone).
            local status = Tx.call("status", e.attemptOpId)
            if type(status) == "table" and status.state == "committed" then
                e.replayed = true
                return settleCommitted(e, type(status.receipt) == "table" and status.receipt or { opId = e.attemptOpId })
            end
        end
        if DEFINITIVE[reason] or not NOT_COMMITTED[reason] then
            return settleFailed(e, reason, info)
        end
        -- Proven not committed. An atomic operation answers its caller (who owns the id and
        -- decides); a write-behind change is the cache's promise, so it tries again.
        if not e.legacy or e.single or now() >= giveUp then
            local final = (e.legacy and not e.single and now() >= giveUp) and "write_behind_exhausted" or reason
            return settleFailed(e, final, info)
        end
        local delay = backoff[math.min(e.attempt, #backoff)]
        Wait(delay)
        if not waitHealthy(giveUp) then return settleFailed(e, "write_behind_exhausted", info) end
        e.attempt = e.attempt + 1
        e.attemptOpId = e.opId .. "-r" .. e.attempt
    end
end

local function submit(e)
    -- Older write-behind credits to a wallet this operation debits (see "Ordering" above).
    local deps = {}
    for id, delta in pairs(e.effects) do
        if delta < 0 then
            for _, other in pairs(W.entries) do
                if other.legacy and not TERMINAL[other.state] and (other.effects[id] or 0) > 0 then
                    deps[#deps + 1] = other
                end
            end
        end
    end
    W.entries[e.opId] = e
    for id in pairs(e.effects) do
        local a = W.accounts[id]
        if a then a.tracked[e.opId] = e end
    end
    CreateThread(function()
        for _, dep in ipairs(deps) do
            while not TERMINAL[dep.state] do Wait(0) end
        end
        process(e)
    end)
end

-- Number of operations not yet terminal (diagnostics, shutdown log).
function W.pendingCount()
    local n = 0
    for _, e in pairs(W.entries) do if not TERMINAL[e.state] then n = n + 1 end end
    return n
end

-- ---------------------------------------------------------------------------------------------
-- The synchronous write-behind path

-- spec = { lines = { { money, from, to } }, kind, reason, actor?, opId? (fixed id, one attempt) }
-- Accounts are resolved ids; a `sys:<resource>:<label>` source mints against that resource's
-- budget, a sys destination burns. A debit needs a loaded wallet; a credit does not (it cannot
-- fail below the 1e12 ceiling). Never yields. Returns balances ([accountId] = displayed balance
-- after the change, for every cached wallet; for one still loading it is the snapshot so far,
-- usually 0, plus the pending changes), opId | nil, reason, info.
function W.legacy(spec)
    if not W.ready() then return nil, W.notReadyReason() end
    if spec.opId and W.entries[spec.opId] then return nil, "duplicate_operation" end
    local sim = {}
    local function balanceOf(id)
        if sim[id] == nil then
            local a = W.accounts[id]
            sim[id] = (a and a.loaded) and W.display(a) or false
        end
        return sim[id]
    end
    for i, l in ipairs(spec.lines) do
        if W.isWallet(l.from) then
            local b = balanceOf(l.from)
            if b == false then return nil, "not_loaded", { line = i, account = l.from } end
            if b < l.money then return nil, "insufficient_funds", { line = i, account = l.from } end
            sim[l.from] = b - l.money
        end
        if W.isWallet(l.to) then
            local b = balanceOf(l.to)
            if b ~= false then
                if b + l.money > cfg.maxBalance then return nil, "balance_limit", { line = i, account = l.to } end
                sim[l.to] = b + l.money
            end
        end
    end
    local tokens = {}
    for i, l in ipairs(spec.lines) do
        if W.isSys(l.from) then
            local key = W.mintKeyOf(l.from)
            local token, why = nil, "mint_denied"
            if key then token, why = Mint.take(key, l.money) end
            if token then
                -- The coordinator's own rule for this resource (contract 12.6), asked inline: a
                -- missing rule refuses now instead of reverting the change later.
                local coordinatorOk, coordinatorWhy = Tx.mayMint(l.from)
                if not coordinatorOk then
                    Mint.release(token)
                    token, why = nil, coordinatorWhy
                end
            end
            if not token then
                for _, t in ipairs(tokens) do Mint.release(t) end
                return nil, why or "mint_denied", { line = i, account = l.from }
            end
            tokens[#tokens + 1] = token
        elseif W.isSys(l.to) then
            local key = W.mintKeyOf(l.to)
            if key then tokens[#tokens + 1] = Mint.burn(key, l.money) end
        end
    end
    local opId = spec.opId
    if not opId then
        W.seq = W.seq + 1
        opId = ("%s.wb.%s.%s"):format(cfg.serverTag, W.bootTag, base36(W.seq))
    end
    local e = newEntry(opId, {
        kind = spec.kind or "legacy", actor = spec.actor, lines = spec.lines, legacy = true,
        single = spec.opId ~= nil, tokens = tokens, reason = spec.reason, caller = spec.caller,
    })
    submit(e)
    local balances = {}
    for id in pairs(e.effects) do
        local a = W.accounts[id]
        if a then
            if a.loaded then balances[id] = W.publish(a, spec.reason) else balances[id] = W.display(a) end
        end
    end
    return balances, opId
end

-- ---------------------------------------------------------------------------------------------
-- The asynchronous atomic path

local function receiptOut(e)
    local r = {}
    for k, v in pairs(e.receipt or {}) do r[k] = v end
    r.opId = e.opId
    if e.replayed then r.replay = true end
    r.balances = {}
    for id in pairs(e.effects) do
        local a = W.accounts[id]
        if a and a.loaded then r.balances[id] = W.display(a) end
    end
    return r
end

local function failInfo(e)
    local info = { opId = e.opId, retryable = NOT_COMMITTED[e.failure] == true or e.failure == "conflict" }
    if type(e.failInfo) == "table" then
        for k, v in pairs(e.failInfo) do if info[k] == nil then info[k] = v end end
    end
    if e.failure == "aborted" or (type(e.failInfo) == "table" and e.failInfo.state == "aborted") then
        info.state = "aborted"   -- the id was fenced: it can never commit; use a new one
    end
    return info
end

-- Waits for an entry, at most asyncWaitSeconds. Yields.
function W.await(e)
    local deadline = now() + cfg.asyncWaitSeconds
    while not TERMINAL[e.state] do
        if now() >= deadline then
            return nil, "in_doubt", { retryable = true, opId = e.opId, state = e.state }
        end
        Wait(0)
    end
    if e.state == "committed" then return receiptOut(e) end
    return nil, e.failure, failInfo(e)
end

-- spec = { opId, kind, actor?, lines (coordinator lines, money and items), tokens (mint),
-- reason, caller }. Yields. Returns receipt | nil, reason, info.
function W.run(spec)
    local function refuse(reason, extra)
        for _, t in ipairs(spec.tokens or {}) do Mint.release(t) end
        local info = { retryable = reason == "store_unavailable", opId = spec.opId }
        for k, v in pairs(extra or {}) do info[k] = v end
        return nil, reason, info
    end
    if not Tx.healthy then return refuse("store_unavailable") end
    if not Migrate.ready() then return refuse(Migrate.reason or "migration_pending") end
    local existing = W.entries[spec.opId]
    if existing then
        if existing.hash ~= (spec.requestKey or linesHash(spec.kind, spec.lines)) then return refuse("op_id_conflict") end
        for _, t in ipairs(spec.tokens or {}) do Mint.release(t) end
        if existing.state == "failed" then
            -- A refused attempt leaves nothing durable; the caller may retry it as new.
            W.entries[spec.opId] = nil
        else
            local r, why, info = W.await(existing)
            if r then r.replay = true end
            return r, why, info
        end
    end
    local e = newEntry(spec.opId, spec)
    submit(e)
    return W.await(e)
end

-- Status of an operation id this facade submitted, or the coordinator's view. Yields.
function W.status(opId)
    local e = W.entries[opId]
    if e then
        if e.state == "committed" then return { state = "committed", receipt = receiptOut(e) } end
        if e.state == "failed" then return { state = "failed", reason = e.failure } end
        return { state = "in_doubt" }
    end
    local status, why = Tx.call("status", opId, { resolve = true })
    if type(status) ~= "table" then return nil, why or "store_unavailable" end
    return status
end

-- Forgets settled operations no cached wallet still counts (bounded memory).
function W.sweep(maxAgeSeconds)
    local cutoff = now() - (maxAgeSeconds or 300)
    for opId, e in pairs(W.entries) do
        if TERMINAL[e.state] and (e.settledAt or 0) < cutoff then
            local counted = false
            for id in pairs(e.effects) do
                local a = W.accounts[id]
                if a and a.tracked[opId] then counted = true break end
            end
            if not counted then
                W.entries[opId] = nil
                for attempt, owner in pairs(W.own) do if owner == e then W.own[attempt] = nil end end
            end
        end
    end
end

-- A committed event from the coordinator: wallets another writer changed are re-read.
function W.onCommitted(opId, kind, accounts)
    if W.own[opId] then return end
    if type(accounts) ~= "table" then return end
    for _, id in ipairs(accounts) do
        if W.accounts[id] and W.accounts[id].loaded then W.refresh(id) end
    end
end

-- ---------------------------------------------------------------------------------------------
-- Players

-- Loads the cash and bank wallets of a connected player. Yields. balance | nil, reason.
function W.attach(playerId)
    if not W.ready() then return nil, W.notReadyReason() end
    local subject, why = Tx.subjectOf(playerId)
    if not subject then return nil, why or "identifier_unavailable" end
    if not W.validSubject(subject) then
        log("subject of player %d is not a durable key (%s): wallet refused", playerId, tostring(subject))
        return nil, "invalid_subject"
    end
    local identifier = Open77.players.identifier(playerId)
    local cash = W.account("cash:" .. subject, "cash", subject)
    local bank = W.account("bank:" .. subject, "bank", subject)
    local ok, reason = W.fetch(cash)
    if not ok then return nil, reason end
    ok, reason = W.fetch(bank)
    if not ok then return nil, reason end
    if Open77.players.identifier(playerId) ~= identifier then return nil, "player_left" end
    cash.playerId, bank.playerId = playerId, playerId
    W.byPlayer[playerId] = { subject = subject, identifier = identifier, cash = cash.id, bank = bank.id }
    cash.published, bank.published = W.display(cash), W.display(bank)
    if not cash.exists and not bank.exists and next(cash.tracked) == nil then
        -- The 1.x tables are keyed by the account identifier, whatever the provider's subject.
        local legacy, err = Migrate.isLegacySubject(identifier)
        if legacy == nil then
            log("player %d %s: start grant postponed, archive unreadable (%s)", playerId, subject, tostring(err))
        elseif legacy == false then
            local balances, opIdOrWhy = W.legacy({
                opId = W.opIdFor("rp_economy.start.", subject), kind = "start", reason = "start",
                actor = cash.id,
                lines = { { money = cfg.startBalance, from = "sys:rp_economy:start", to = cash.id } },
            })
            if balances then
                log("new wallet player %d %s balance=%d", playerId, subject, balances[cash.id] or 0)
            elseif opIdOrWhy ~= "duplicate_operation" then
                log("start grant for %s refused: %s", subject, tostring(opIdOrWhy))
            end
        end
    end
    log("loaded player %d %s cash=%d bank=%d", playerId, subject, W.display(cash), W.display(bank))
    return W.display(cash)
end

function W.detach(playerId)
    local p = W.byPlayer[playerId]
    if not p then return end
    W.byPlayer[playerId] = nil
    for _, id in ipairs({ p.cash, p.bank }) do
        local a = W.accounts[id]
        if a and a.playerId == playerId then a.playerId = nil end
    end
end

function W.playerWallet(playerId, kind)
    local p = W.byPlayer[playerId]
    if not p then return nil end
    return W.accounts[kind == "bank" and p.bank or p.cash], p
end
