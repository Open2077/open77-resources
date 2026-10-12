-- rp_economy - server-authoritative wallet (eurodollars) for an RP server. Version 2: a facade
-- over the open77_transactions coordinator (world-interaction row B3).
--
-- The coordinator owns every balance. This resource keeps the wallets of connected players in a
-- cache (server/wallets.lua) and offers two APIs:
--
--   Synchronous, unchanged signatures (the 25 resources of the pack call them today):
--     getBalance(playerId) -> integer (0 when unknown)
--     add(playerId, amount, reason) -> newBalance | nil, reason
--     remove(playerId, amount, reason) -> newBalance | nil, "insufficient_funds" | nil, reason
--   They are a WRITE-BEHIND facade: checked against the cache, applied to it at once, committed
--   in the background as one double-entry operation (A13 §7.4 option i). No stronger than 1.x.
--   New refusals: store_unavailable (coordinator down: no KVP fallback any more),
--   migration_pending, mint_denied / mint_cap (server/mint.lua).
--
--   Asynchronous, atomic (call with Open77.exports.call(...):await(); they yield):
--     pay, charge, sale, refund, invoice, status, balanceOf   (README.md, "Atomic API")
--   One coordinator operation each: the money, the items of a sale, the society share and every
--   split are committed together or not at all, and a repeated opId pays once.
--
-- Every change publishes TriggerEvent("rp_economy:changed", playerId, newBalance, delta, reason)
-- (cash of a connected player, as in 1.x) and rp_economy:walletChanged(kind, playerId, key,
-- newBalance, delta, reason) for cash, bank and society wallets.

local RESOURCE = GetCurrentResourceName()
local cfg = EconomyConfig
local CURRENCY = cfg.currency
local MAX_REASON_BYTES = 64

------------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------------

local function log(text)
    print("[" .. RESOURCE .. "] " .. text)
end

local function logToken(reason)
    if reason == nil then return "unspecified" end
    return (tostring(reason):gsub("%s+", "_"))
end

local function formatMoney(amount)
    return ("%d %s"):format(amount, CURRENCY)
end

local function asNumber(value)
    if value == nil then return nil end
    return tonumber(value)
end

-- A positive integer (integer-valued floats such as 5.0 are accepted), bounded.
local function toPositiveInteger(value, maximum)
    if type(value) ~= "number" then return nil end
    if value ~= value or value <= 0 or value % 1 ~= 0 then return nil end
    local integer = math.tointeger(value)
    if not integer or integer > maximum then return nil end
    return integer
end

local function tell(playerId, text)
    local id = asNumber(playerId)
    if not id or id <= 0 then return end
    local ok, reason = Open77.chat.send(id, text)
    if not ok then log(("chat.send refused for player %d: %s"):format(id, tostring(reason))) end
end

local function notify(playerId, definition)
    local id = asNumber(playerId)
    if not id or id <= 0 then return end
    if type(Open77.notifications) ~= "table" or type(Open77.notifications.send) ~= "function" then return end
    local notificationId, reason = Open77.notifications.send(id, definition)
    if not notificationId then log(("notifications.send refused for player %d: %s"):format(id, tostring(reason))) end
end

local function isPlayerReady(playerId)
    local read = Open77.players.get(playerId)
    return read ~= nil and read.ready == true
end

local function validateReason(reason)
    if reason == nil then return true end
    if type(reason) ~= "string" or reason == "" or #reason > MAX_REASON_BYTES then return nil, "invalid_reason" end
    if reason:find("[%c]") then return nil, "invalid_reason" end
    return true
end

local function validOpId(id)
    return type(id) == "string" and #id >= 8 and #id <= 96 and id:match("^[A-Za-z0-9_.:@%-]+$") ~= nil
end

local function callerOf()
    return Mint.segment(GetInvokingResource() or RESOURCE)
end

local function trustedCaller()
    local caller = GetInvokingResource()
    return caller ~= nil and cfg.trustedFacades[caller] == true
end

------------------------------------------------------------------------------
-- Synchronous 1.x exports (write-behind)
------------------------------------------------------------------------------

local function validatePlayer(playerId)
    local id = toPositiveInteger(playerId, 2147483647)
    if not id then return nil, "invalid_player_id" end
    if not Wallets.byPlayer[id] then return nil, "player_not_found" end
    return id
end

local function legacyCash(playerId, amount, reason, sign, caller)
    local id, idReason = validatePlayer(playerId)
    if not id then return nil, idReason end
    local value = toPositiveInteger(amount, cfg.maxBalance)
    if not value then return nil, "invalid_amount" end
    local reasonOk, reasonReason = validateReason(reason)
    if not reasonOk then return nil, reasonReason end
    local cash = Wallets.playerWallet(id, "cash")
    local sys = ("sys:%s:legacy"):format(caller)
    local line = sign > 0 and { money = value, from = sys, to = cash.id } or { money = value, from = cash.id, to = sys }
    local balances, opIdOrWhy = Wallets.legacy({
        lines = { line }, kind = sign > 0 and "legacy.add" or "legacy.remove", reason = reason, actor = cash.id,
    })
    if not balances then return nil, opIdOrWhy end
    local newBalance = balances[cash.id] or Wallets.display(cash)
    log(("%+d player %d %s by %s balance=%d op=%s"):format(sign * value, id, logToken(reason), caller, newBalance, opIdOrWhy))
    return newBalance
end

exports("getBalance", function(playerId)
    local id = toPositiveInteger(playerId, 2147483647)
    if not id then return 0 end
    local cash = Wallets.playerWallet(id, "cash")
    return cash and Wallets.display(cash) or 0
end)

exports("add", function(playerId, amount, reason)
    return legacyCash(playerId, amount, reason, 1, callerOf())
end)

exports("remove", function(playerId, amount, reason)
    return legacyCash(playerId, amount, reason, -1, callerOf())
end)

------------------------------------------------------------------------------
-- Synchronous wallet exports for the bank facade (rp_bank only: trustedFacades)
------------------------------------------------------------------------------

-- { account, subject, identifier, balance, exists } of a connected player's cash or bank.
exports("walletRead", function(playerId, kind)
    if not trustedCaller() then return nil, "caller_denied" end
    local id = toPositiveInteger(asNumber(playerId), 2147483647)
    if not id then return nil, "invalid_player_id" end
    if kind ~= "cash" and kind ~= "bank" then return nil, "invalid_wallet" end
    local a, p = Wallets.playerWallet(id, kind)
    if not a then return nil, Wallets.ready() and "account_not_loaded" or Wallets.notReadyReason() end
    return { account = a.id, subject = p.subject, identifier = p.identifier, balance = Wallets.display(a),
        exists = a.exists }
end)

-- { name, balance, loaded } of a society; an unknown society is loaded in the background.
exports("societyRead", function(name)
    if not trustedCaller() then return nil, "caller_denied" end
    local clean = Wallets.cleanSociety(name)
    if not clean then return nil, "invalid_society" end
    if not Tx.healthy then return nil, "store_unavailable" end
    local a = Wallets.society(clean)
    return { name = clean, balance = Wallets.display(a), loaded = a.loaded }
end)

-- Resolves a wallet reference for walletMove (synchronous: cached wallets only, except credits).
local function resolveRef(ref, onBehalfOf, role)
    if type(ref) ~= "table" then return nil, "invalid_party" end
    if ref.sys ~= nil then
        if type(ref.sys) ~= "string" or not ref.sys:match("^[a-z0-9_]+$") or #ref.sys > 24 then return nil, "invalid_party" end
        return ("sys:%s:%s"):format(onBehalfOf, ref.sys)
    end
    if ref.society ~= nil then
        local name = Wallets.cleanSociety(ref.society)
        if not name then return nil, "invalid_society" end
        local a = Wallets.society(name)
        if role == "from" and not a.loaded then return nil, "not_loaded", a.id end
        return a.id
    end
    local wallet = ref.wallet or "cash"
    if wallet ~= "cash" and wallet ~= "bank" then return nil, "invalid_wallet" end
    if ref.player ~= nil then
        local id = toPositiveInteger(asNumber(ref.player), 2147483647)
        if not id then return nil, "invalid_player_id" end
        local a = Wallets.playerWallet(id, wallet)
        if not a then return nil, "player_not_found" end
        return a.id
    end
    if ref.identifier ~= nil then
        local subject = Tx.subjectOf({ identifier = ref.identifier })   -- the provider, identifier form
        if not Wallets.validSubject(subject) then return nil, "unknown_recipient" end
        local a = Wallets.accounts[wallet .. ":" .. subject]
        -- A synchronous caller cannot ask whether an offline account exists: only wallets this
        -- server has loaded are accepted (rp_bank's asynchronous path checks the coordinator).
        if not a or not a.loaded then return nil, "unknown_recipient" end
        return a.id
    end
    return nil, "invalid_party"
end

-- spec = { onBehalfOf, kind, reason, lines = { { amount, from = ref, to = ref } } } where ref is
-- { player = id, wallet = "cash"|"bank" } | { identifier = guid, wallet } | { society = name } |
-- { sys = label } (sys:<onBehalfOf>:<label>: a mint as a source, a burn as a destination).
-- Returns { opId, lines = { { from = id, to = id } }, balances = { [id] = n } } | nil, reason, info.
exports("walletMove", function(spec)
    if not trustedCaller() then return nil, "caller_denied" end
    if type(spec) ~= "table" or type(spec.lines) ~= "table" or #spec.lines < 1 or #spec.lines > 8 then
        return nil, "invalid_spec"
    end
    local onBehalfOf = Mint.segment(spec.onBehalfOf or GetInvokingResource())
    local reasonOk = type(spec.reason) ~= "string" or (#spec.reason <= 128 and not spec.reason:find("[%c]"))
    if not reasonOk then return nil, "invalid_reason" end
    local lines, resolved = {}, {}
    for i, l in ipairs(spec.lines) do
        local amount = toPositiveInteger(l.amount, cfg.maxBalance)
        if not amount then return nil, "invalid_amount", { line = i } end
        local from, fromWhy, fromAccount = resolveRef(l.from, onBehalfOf, "from")
        if not from then return nil, fromWhy, { line = i, side = "from", account = fromAccount } end
        local to, toWhy, toAccount = resolveRef(l.to, onBehalfOf, "to")
        if not to then return nil, toWhy, { line = i, side = "to", account = toAccount } end
        if from == to then return nil, "self_transfer", { line = i } end
        lines[i] = { money = amount, from = from, to = to }
        resolved[i] = { from = from, to = to }
    end
    local kind = type(spec.kind) == "string" and spec.kind:sub(1, 32) or "legacy.move"
    local balances, opIdOrWhy, info = Wallets.legacy({ lines = lines, kind = kind, reason = spec.reason, actor = lines[1].from:match("^sys:") and lines[1].to or lines[1].from })
    if not balances then return nil, opIdOrWhy, info end
    log(("move %s by %s: %s op=%s"):format(kind, onBehalfOf, logToken(spec.reason), opIdOrWhy))
    return { opId = opIdOrWhy, lines = resolved, balances = balances }
end)

------------------------------------------------------------------------------
-- Asynchronous atomic API
------------------------------------------------------------------------------

-- Resolves a party to an account id. May yield (offline subjects through the provider).
--   { player = id [, wallet] } | { subject = s [, wallet] } | { identifier = guid [, wallet] }
--   | { society = name } | { sys = label }  (sys:<caller>:<label>)
local function accountOf(party, caller)
    if type(party) ~= "table" then return nil, "invalid_party" end
    if party.sys ~= nil then
        if type(party.sys) ~= "string" or not party.sys:match("^[a-z0-9_]+$") or #party.sys > 24 then return nil, "invalid_party" end
        return ("sys:%s:%s"):format(caller, party.sys)
    end
    if party.society ~= nil then
        local name = Wallets.cleanSociety(party.society)
        if not name then return nil, "invalid_society" end
        return "soc:" .. name
    end
    local wallet = party.wallet or "cash"
    if wallet ~= "cash" and wallet ~= "bank" then return nil, "invalid_wallet" end
    local subject
    if party.player ~= nil then
        local id = toPositiveInteger(asNumber(party.player), 2147483647)
        local p = id and Wallets.byPlayer[id]
        if not p then return nil, "player_not_found" end
        subject = p.subject
    elseif party.subject ~= nil then
        subject = party.subject
    elseif party.identifier ~= nil then
        subject = Tx.subjectOf({ identifier = party.identifier })
    else
        return nil, "invalid_party"
    end
    if not Wallets.validSubject(subject) then return nil, "invalid_subject" end
    return wallet .. ":" .. subject
end

-- The container a sale's goods leave from: an explicit container account, or the seller's
-- pockets char:<subject> (B2's character container).
local function containerOf(ref, sellerSubject)
    if ref == nil then
        if not sellerSubject then return nil, "invalid_party" end
        return "char:" .. sellerSubject
    end
    if type(ref) ~= "string" or #ref > 96 or not ref:match("^[A-Za-z0-9_.:@%-]+$") or not Wallets.isContainer(ref) then
        return nil, "invalid_container"
    end
    return ref
end

local function subjectOfAccount(id)
    return type(id) == "string" and id:match("^%a+:([^:]+)$") or nil
end

-- Mint / burn tokens for money lines: sys sources take budget, sys destinations give it back.
local function mintTokens(lines)
    local tokens = {}
    for i, l in ipairs(lines) do
        if l.money and Wallets.isSys(l.from) then
            local key = Wallets.mintKeyOf(l.from)
            local token, why = nil, "mint_denied"
            if key then token, why = Mint.take(key, l.money) end
            if not token then
                for _, t in ipairs(tokens) do Mint.release(t) end
                return nil, why or "mint_denied", { line = i, account = l.from }
            end
            tokens[#tokens + 1] = token
        elseif l.money and Wallets.isSys(l.to) then
            local key = Wallets.mintKeyOf(l.to)
            if key then tokens[#tokens + 1] = Mint.burn(key, l.money) end
        end
    end
    return tokens
end

-- payees = a list of { <party fields>, amount }. Returns { { account, amount } }, total | nil, reason.
local function payeesOf(list, caller)
    if type(list) ~= "table" or #list < 1 or #list > 40 then return nil, "invalid_split" end
    local out, total = {}, 0
    for i, p in ipairs(list) do
        local amount = toPositiveInteger(p.amount, cfg.maxBalance)
        if not amount then return nil, "invalid_amount", { payee = i } end
        local account, why = accountOf(p, caller)
        if not account then return nil, why, { payee = i } end
        out[#out + 1] = { account = account, amount = amount }
        total = total + amount
    end
    return out, total
end

-- Money from `sources` ({ { account, amount } }) to `payees`, cash-then-bank order kept.
local function allocate(sources, payees)
    local lines, si, left = {}, 1, sources[1] and sources[1].amount or 0
    for _, p in ipairs(payees) do
        local need = p.amount
        while need > 0 do
            while left == 0 do
                si = si + 1
                if not sources[si] then return nil end
                left = sources[si].amount
            end
            local part = math.min(need, left)
            if sources[si].account ~= p.account then
                lines[#lines + 1] = { money = part, from = sources[si].account, to = p.account }
            end
            need, left = need - part, left - part
        end
    end
    return lines
end

local function commonChecks(spec)
    if type(spec) ~= "table" then return nil, "invalid_spec" end
    if not validOpId(spec.opId) then return nil, "invalid_op_id" end
    local ok, why = validateReason(spec.reason)
    if not ok then return nil, why end
    return true
end

-- The business request, independent of balances: a replay is recognised by it, not by the lines
-- (a cash-then-bank split depends on the balances of the moment).
local function requestKey(kind, spec)
    local parts = { kind }
    local function walk(v, depth)
        if depth > 6 then return end
        if type(v) == "table" then
            local keys = {}
            for k in pairs(v) do keys[#keys + 1] = k end
            table.sort(keys, function(x, y) return tostring(x) < tostring(y) end)
            parts[#parts + 1] = "{"
            for _, k in ipairs(keys) do
                parts[#parts + 1] = tostring(k) .. "="
                walk(v[k], depth + 1)
            end
            parts[#parts + 1] = "}"
        else
            parts[#parts + 1] = tostring(v)
        end
    end
    walk(spec, 0)
    return table.concat(parts, ",")
end

local function run(spec, kind, lines, actor, caller)
    if #lines == 0 then return nil, "invalid_spec", { opId = spec.opId } end
    if #lines > 48 then return nil, "operation_too_large", { opId = spec.opId } end
    local tokens, why, info = mintTokens(lines)
    if not tokens then return nil, why, info end
    local receipt, reason, rinfo = Wallets.run({
        opId = spec.opId, kind = kind, actor = actor, lines = lines, tokens = tokens,
        reason = spec.reason, caller = caller, requestKey = requestKey(kind, spec),
    })
    if receipt then
        log(("%s %s by %s: %d line(s)%s"):format(kind, spec.opId, caller, #lines, receipt.replay and " (replay)" or ""))
    else
        log(("%s %s by %s refused: %s"):format(kind, spec.opId, caller, tostring(reason)))
    end
    return receipt, reason, rinfo
end

-- The payer's sources for `amount` given an instrument. Yields when a wallet is not cached.
local function fundsOf(payerAccount, instrument, amount)
    if instrument == nil or instrument == "cash" or instrument == "bank" or Wallets.isSys(payerAccount) or Wallets.kindOf(payerAccount) == "soc" then
        return { { account = payerAccount, amount = amount } }
    end
    if instrument ~= "cash_then_bank" then return nil, "invalid_instrument" end
    local subject = subjectOfAccount(payerAccount)
    local cashId, bankId = "cash:" .. subject, "bank:" .. subject
    local function balanceOf(id)
        local a = Wallets.accounts[id]
        if a and a.loaded then return Wallets.display(a) end
        local snap = Tx.read(id)
        return type(snap) == "table" and (math.tointeger(snap.balance) or 0) or 0
    end
    local cash = math.max(0, balanceOf(cashId))
    local fromCash = math.min(cash, amount)
    local sources = {}
    if fromCash > 0 then sources[#sources + 1] = { account = cashId, amount = fromCash } end
    if amount - fromCash > 0 then sources[#sources + 1] = { account = bankId, amount = amount - fromCash } end
    return sources
end

local Api = {}

-- pay { opId, from = party, to = party, amount | payees = { { party..., amount } }, reason }
function Api.pay(spec, caller)
    local ok, why = commonChecks(spec)
    if not ok then return nil, why end
    local from, fromWhy = accountOf(spec.from, caller)
    if not from then return nil, fromWhy end
    local payees, total
    if spec.payees ~= nil then
        payees, total = payeesOf(spec.payees, caller)
    else
        local amount = toPositiveInteger(spec.amount, cfg.maxBalance)
        if not amount then return nil, "invalid_amount" end
        local to, toWhy = accountOf(spec.to, caller)
        if not to then return nil, toWhy end
        payees, total = { { account = to, amount = amount } }, amount
    end
    if not payees then return nil, total end
    local lines = allocate({ { account = from, amount = total } }, payees)
    return run(spec, "pay", lines or {}, (not Wallets.isSys(from)) and from or nil, caller)
end

-- charge / invoice { opId, from = party, amount, instrument = "cash"|"bank"|"cash_then_bank",
--   to = party | payees = { ... } (default: burned into sys:<caller>:sink), reason }
local function chargeLike(spec, caller, kind, requirePayees)
    local ok, why = commonChecks(spec)
    if not ok then return nil, why end
    local payerParty = spec.from or spec.payer
    if type(payerParty) == "table" and payerParty.wallet == nil and spec.instrument == "bank" then
        local copy = {}
        for k, v in pairs(payerParty) do copy[k] = v end
        copy.wallet = "bank"
        payerParty = copy
    end
    local from, fromWhy = accountOf(payerParty, caller)
    if not from then return nil, fromWhy end
    if Wallets.isSys(from) then return nil, "invalid_party" end
    local amount = toPositiveInteger(spec.amount, cfg.maxBalance)
    if not amount then return nil, "invalid_amount" end
    local payees, total
    if spec.payees ~= nil then
        payees, total = payeesOf(spec.payees, caller)
        if not payees then return nil, total end
        if total ~= amount then return nil, "invalid_split" end
    elseif requirePayees then
        return nil, "invalid_split"
    else
        local to, toWhy = accountOf(spec.to or { sys = "sink" }, caller)
        if not to then return nil, toWhy end
        payees = { { account = to, amount = amount } }
    end
    local sources, sourceWhy = fundsOf(from, spec.instrument, amount)
    if not sources then return nil, sourceWhy end
    local lines = allocate(sources, payees)
    if not lines then return nil, "insufficient_funds" end
    return run(spec, kind, lines, from, caller)
end

function Api.charge(spec, caller) return chargeLike(spec, caller, "charge", false) end
function Api.invoice(spec, caller) return chargeLike(spec, caller, "invoice", true) end

-- Strict writers (the coordinator's `writers` keeps `char` to rp_inventory): a sale's goods that
-- leave a connected seller's pockets need rp_inventory's grant for this one operation
-- (grantPockets; open77_transactions authorize). Asked only when the coordinator says this
-- resource may not write them (allowed, non-yielding). true | nil, reason, info.
local function pocketsGranted(lines, opId, seller)
    for _, l in ipairs(lines) do
        local account = l.from
        if type(account) == "string" and account:match("^char:") then
            local ok, allowed = pcall(Open77.exports.callSync, cfg.coordinator, "allowed", RESOURCE, account)
            if ok and allowed == false then
                local pid = type(seller) == "table" and toPositiveInteger(asNumber(seller.player), 2147483647)
                if not pid then return nil, "namespace_denied", { account = account, detail = "seller_not_connected" } end
                local gok, granted, why = pcall(Open77.exports.callSync, "rp_inventory", "grantPockets", opId, pid)
                if not gok or granted ~= true then
                    return nil, "namespace_denied", { account = account, detail = gok and tostring(why) or "rp_inventory_unavailable" }
                end
                return true
            end
        end
    end
    return true
end

-- sale { opId, seller = party, items = { { item, count, from? } | { instance, from? } },
--   buyer = { sys = label } | party, total, payees? = { ... } (default: all to the seller), reason }
-- Goods leave their container to the buyer (an NPC buyer's sys account, or the buyer's pockets
-- char:<subject>); the price leaves the buyer and is split among the payees. One operation.
-- An `instance` entry moves one unique unit (a salvage crate out of veh:<plate>:cargo, C1) with
-- its metadata; `from` defaults to the seller's pockets like a stack.
function Api.sale(spec, caller)
    local ok, why = commonChecks(spec)
    if not ok then return nil, why end
    local seller, sellerWhy = accountOf(spec.seller, caller)
    if not seller then return nil, sellerWhy end
    if Wallets.isSys(seller) or Wallets.kindOf(seller) == "soc" then return nil, "invalid_party" end
    local sellerSubject = subjectOfAccount(seller)
    local buyer, buyerWhy = accountOf(spec.buyer, caller)
    if not buyer then return nil, buyerWhy end
    local goodsTo = buyer
    if not Wallets.isSys(buyer) then
        if Wallets.kindOf(buyer) == "soc" then return nil, "invalid_party" end
        goodsTo = "char:" .. subjectOfAccount(buyer)
    end
    local total = toPositiveInteger(spec.total, cfg.maxBalance)
    if not total then return nil, "invalid_amount" end
    if type(spec.items) ~= "table" or #spec.items < 1 or #spec.items > 16 then return nil, "invalid_items" end
    local lines = {}
    for i, it in ipairs(spec.items) do
        if type(it) ~= "table" then return nil, "unknown_item", { item = i } end
        local from, fromWhy = containerOf(it.from, sellerSubject)
        if not from then return nil, fromWhy, { item = i } end
        if it.instance ~= nil then
            -- The coordinator's instance id rule (model.lua validInstanceId).
            if type(it.instance) ~= "string" or #it.instance < 4 or #it.instance > 64
                or not it.instance:match("^[A-Za-z0-9_.:%-]+$") then
                return nil, "invalid_instance", { item = i }
            end
            lines[#lines + 1] = { instance = it.instance, from = from, to = goodsTo }
        else
            if type(it.item) ~= "string" or not it.item:match("^[a-z0-9_]+$") or #it.item > 64 then
                return nil, "unknown_item", { item = i }
            end
            local n = toPositiveInteger(it.count, 1000000)
            if not n then return nil, "invalid_count", { item = i } end
            lines[#lines + 1] = { item = it.item, count = n, from = from, to = goodsTo }
        end
    end
    local payees, sum
    if spec.payees ~= nil then
        payees, sum = payeesOf(spec.payees, caller)
        if not payees then return nil, sum end
        if sum ~= total then return nil, "invalid_split" end
    else
        payees = { { account = seller, amount = total } }
    end
    local money = allocate({ { account = buyer, amount = total } }, payees)
    for _, l in ipairs(money or {}) do lines[#lines + 1] = l end
    local granted, grantWhy, grantInfo = pocketsGranted(lines, spec.opId, spec.seller)
    if not granted then return nil, grantWhy, grantInfo end
    return run(spec, "sale", lines, seller, caller)
end

-- refund { opId? (default refund:<of>), of = original opId, reason }: the money lines of a
-- committed operation, reversed, so each payer gets back what it paid on the instrument it paid
-- with. Goods are not returned. Once per original: the default id is derived from it.
function Api.refund(spec, caller)
    if type(spec) ~= "table" or not validOpId(spec.of) then return nil, "invalid_op_id" end
    local refundSpec = { opId = spec.opId or Wallets.opIdFor("refund:", spec.of), reason = spec.reason }
    local ok, why = commonChecks(refundSpec)
    if not ok then return nil, why end
    local status, statusWhy = Wallets.status(spec.of)
    if type(status) ~= "table" then return nil, statusWhy or "store_unavailable" end
    if status.state ~= "committed" or type(status.receipt) ~= "table" then return nil, "not_committed" end
    if status.receipt.kind == "refund" then return nil, "invalid_spec" end
    local lines = {}
    for _, l in ipairs(status.receipt.lines or {}) do
        local amount = l.money or l.amount
        if amount and l.from and l.to then
            lines[#lines + 1] = { money = amount, from = l.to, to = l.from }
        end
    end
    if #lines == 0 then return nil, "nothing_to_refund" end
    return run(refundSpec, "refund", lines, nil, caller)
end

exports("pay", function(spec) return Api.pay(spec, callerOf()) end)
exports("charge", function(spec) return Api.charge(spec, callerOf()) end)
exports("invoice", function(spec) return Api.invoice(spec, callerOf()) end)
exports("sale", function(spec) return Api.sale(spec, callerOf()) end)
exports("refund", function(spec) return Api.refund(spec, callerOf()) end)

exports("status", function(opId)
    if not validOpId(opId) then return nil, "invalid_op_id" end
    return Wallets.status(opId)
end)

-- { account, balance, exists } of any party, connected or not. Yields.
exports("balanceOf", function(party)
    local id, why = accountOf(party, callerOf())
    if not id then return nil, why end
    if Wallets.isSys(id) then return nil, "invalid_party" end
    local a = Wallets.accounts[id]
    if a and a.loaded then return { account = id, balance = Wallets.display(a), exists = a.exists } end
    if not Tx.healthy then return nil, "store_unavailable" end
    local snap, snapWhy = Tx.read(id)
    if type(snap) ~= "table" then return nil, snapWhy or "store_unavailable" end
    return { account = id, balance = math.tointeger(snap.balance) or 0, exists = snap.exists == true }
end)

------------------------------------------------------------------------------
-- Read-only wallet status for a HUD (world-interaction row B7, docs/world-interaction/b7-ui.md).
-- Additive: no existing export, event or behaviour changes. Synchronous, never yields, reads the
-- cache only, and answers about connected players only (the caller pushes it to that player).
------------------------------------------------------------------------------

-- Operations not settled yet that touch one cached wallet, split by what the displayed balance
-- (Wallets.display) already counts:
--   incoming     atomic credits in flight: NOT in the displayed balance yet (a sale's payout the
--                store has not confirmed). A HUD shows them as pending, never as missing money.
--   outgoing     debits in flight (atomic or write-behind): already subtracted from the display.
--   unconfirmed  write-behind credits not acknowledged yet: already added to the display.
--   inDoubt      operations whose caller has been told in_doubt: state in_doubt, or older than
--                EconomyConfig.asyncWaitSeconds (W.await gave up waiting).
-- Only operations at least `minAge` seconds old count, so a normal round trip never flashes.
local function pendingOn(a, minAge)
    local out = { incoming = 0, outgoing = 0, unconfirmed = 0, ops = 0, inDoubt = 0, oldestSeconds = 0 }
    if not a then return out end
    local t = Open77.time.monotonic()
    for _, e in pairs(a.tracked) do
        if e.state ~= "committed" and e.state ~= "failed" then
            local d = e.effects[a.id] or 0
            local age = t - (e.createdAt or t)
            if d ~= 0 and age >= minAge then
                out.ops = out.ops + 1
                if age > out.oldestSeconds then out.oldestSeconds = age end
                if e.state == "in_doubt" or age >= cfg.asyncWaitSeconds then out.inDoubt = out.inDoubt + 1 end
                if d < 0 then
                    out.outgoing = out.outgoing - d
                elseif e.legacy then
                    out.unconfirmed = out.unconfirmed + d
                else
                    out.incoming = out.incoming + d
                end
            end
        end
    end
    out.oldestSeconds = math.floor(out.oldestSeconds)
    return out
end

local function minAgeOf(opts)
    local v = type(opts) == "table" and tonumber(opts.minAgeSeconds) or nil
    if not v or v < 0 then return 0 end
    return v
end

-- walletStatus(playerId, { minAgeSeconds }?) ->
--   { loaded = true, reason? = "store_unavailable", cash = { balance, incoming, outgoing,
--     unconfirmed, inDoubt, ops, oldestSeconds }, bank = { ... } }
--   | { loaded = false, reason = "not_loaded" | "store_unavailable" | "migration_pending" | ... }
--   | nil, "invalid_player_id"
-- `loaded = false` means "unknown", never 0: getBalance answers 0 there (1.x contract).
exports("walletStatus", function(playerId, opts)
    local id = toPositiveInteger(asNumber(playerId), 2147483647)
    if not id then return nil, "invalid_player_id" end
    local p = Wallets.byPlayer[id]
    if not p then
        return { loaded = false, reason = Wallets.ready() and "not_loaded" or Wallets.notReadyReason() }
    end
    local minAge = minAgeOf(opts)
    local out = { loaded = true, reason = (not Tx.healthy) and "store_unavailable" or nil }
    for _, kind in ipairs({ "cash", "bank" }) do
        local a = Wallets.accounts[p[kind]]
        local status = pendingOn(a, minAge)
        status.balance = a and Wallets.display(a) or 0
        out[kind] = status
    end
    return out
end)

-- pendingPlayers({ minAgeSeconds }?) -> { [playerId] = fingerprint } for the connected players
-- with at least one unsettled operation of that age on their cash or bank wallet. One call per
-- poll for the whole server: a HUD re-pushes a player whose fingerprint changed.
exports("pendingPlayers", function(opts)
    local minAge = minAgeOf(opts)
    local out = {}
    for playerId, p in pairs(Wallets.byPlayer) do
        local parts = {}
        for _, kind in ipairs({ "cash", "bank" }) do
            local s = pendingOn(Wallets.accounts[p[kind]], minAge)
            if s.ops > 0 then
                parts[#parts + 1] = ("%s:%d:%d:%d:%d"):format(kind, s.incoming, s.outgoing, s.unconfirmed, s.inDoubt)
            end
        end
        if #parts > 0 then out[playerId] = table.concat(parts, "|") end
    end
    return out
end)

------------------------------------------------------------------------------
-- Payday (a mint from sys:rp_economy:payday, capped)
------------------------------------------------------------------------------

local function runPayday(trigger)
    local paid = 0
    for _, rawId in ipairs(Open77.players.all() or {}) do
        local playerId = asNumber(rawId)
        local cash = playerId and Wallets.playerWallet(playerId, "cash")
        if cash and isPlayerReady(playerId) then
            local balances, why = Wallets.legacy({
                lines = { { money = cfg.paydayAmount, from = "sys:rp_economy:payday", to = cash.id } },
                kind = "payday", reason = "payday", actor = cash.id,
            })
            if balances then
                paid = paid + 1
                tell(playerId, ("Payday: +%d %s"):format(cfg.paydayAmount, CURRENCY))
            else
                log(("payday for player %d refused: %s"):format(playerId, tostring(why)))
            end
        end
    end
    log(("payday (%s) paid %d player(s)"):format(trigger, paid))
    return paid
end

------------------------------------------------------------------------------
-- Players and lifecycle
------------------------------------------------------------------------------

local attaching = {}   -- [playerId] = true while a load loop runs

-- Loads a player's wallets, retrying while the coordinator or the migration is not ready.
local function attachLoop(playerId, announce)
    if attaching[playerId] or Wallets.byPlayer[playerId] then return end
    attaching[playerId] = true
    CreateThread(function()
        local told = false
        while isPlayerReady(playerId) and not Wallets.byPlayer[playerId] do
            local balance, reason
            if Wallets.ready() then
                balance, reason = Wallets.attach(playerId)
            else
                reason = Wallets.notReadyReason()
            end
            if balance then
                if announce then tell(playerId, ("Balance: %s"):format(formatMoney(balance))) end
                break
            end
            if reason == "player_left" then break end
            if not told and announce then
                tell(playerId, ("Wallet unavailable (%s): retrying."):format(tostring(reason)))
                told = true
            end
            Wait(2000)
        end
        attaching[playerId] = nil
    end)
end

local function attachEveryone()
    for _, rawId in ipairs(Open77.players.all() or {}) do
        local playerId = asNumber(rawId)
        if playerId and playerId > 0 and isPlayerReady(playerId) then attachLoop(playerId, false) end
    end
end

local function preloadSocieties()
    for _, name in ipairs(cfg.societies) do Wallets.society(name) end
    for _, name in ipairs(Migrate.archivedSocieties()) do Wallets.society(name) end
end

-- Host-wide: every coordinator health transition (rp_hud redraws "offline, last known" at once
-- instead of on its 30 s keepalive; live 2026-10-12 the marker had not appeared after 19 s).
Tx.onChange(function(healthy, reason)
    TriggerEvent("rp_economy:healthChanged", healthy == true, reason)
end)

Tx.onChange(function(healthy)
    if not healthy then return end
    CreateThread(function()
        Migrate.check()
        if Migrate.ready() then
            attachEveryone()
            preloadSocieties()
        end
    end)
end)

AddEventHandler("onResourceStart", function(name)
    if name ~= RESOURCE then return end
    cfg.serverTag = GetConvar("rp_economy_server_tag", cfg.serverTag)
    -- Operation ids must never repeat across restarts: wall-clock seconds (the monotonic clock
    -- restarts with the process) plus a random suffix for two boots within one second.
    Wallets.bootTag = Wallets.base36(math.floor(Open77.time.unix())) .. Wallets.base36(math.random(46656, 1679615))
    Open77.chat.addSuggestions(-1, {
        { command = "/money", help = "Show your balance" },
        { command = "/pay", help = "Send eddies to a connected player", parameters = {
            { name = "playerId", help = "Player id" }, { name = "amount", help = "Amount in €$" } } },
    })
    Tx.startProbe()
    CreateThread(function()
        while true do
            Wait(cfg.paydayIntervalMs)
            runPayday("timer")
        end
    end)
    CreateThread(function()
        while true do
            Wait(60000)
            Wallets.sweep(300)
        end
    end)
    log("started (wallet facade over " .. cfg.coordinator .. ")")
end)

AddEventHandler("onResourceStop", function(name)
    if name ~= RESOURCE then return end
    local pending = Wallets.pendingCount()
    if pending > 0 then
        Open77.log.warn(("[rp_economy] stopping with %d operation(s) not yet settled: those already submitted finish in the coordinator, the others are lost")
            :format(pending))
    end
end)

AddEventHandler("onPlayerReady", function(rawPlayerId)
    local playerId = asNumber(rawPlayerId)
    if playerId and playerId > 0 then attachLoop(playerId, true) end
end)

AddEventHandler("onPlayerDisconnected", function(rawPlayerId)
    local playerId = asNumber(rawPlayerId)
    if playerId then Wallets.detach(playerId) end
end)

AddEventHandler("open77_transactions:committed", function(opId, kind, accounts)
    Wallets.onCommitted(opId, kind, accounts)
end)

RegisterNetEvent("chat:ready", function()
    local playerId = asNumber(source)
    if playerId and playerId > 0 then
        Open77.chat.addSuggestions(playerId, {
            { command = "/money", help = "Show your balance" },
        })
    end
end)

------------------------------------------------------------------------------
-- Commands
------------------------------------------------------------------------------

local paySeq = 0

local function parseTargetAndAmount(args, reply, usage)
    local target = toPositiveInteger(asNumber(args[1]), 2147483647)
    local amount = toPositiveInteger(asNumber(args[2]), cfg.maxBalance)
    if not target or not amount then
        reply("Usage: " .. usage)
        return nil
    end
    if not Wallets.byPlayer[target] or not isPlayerReady(target) then
        reply("Player not found or not in the world yet.")
        return nil
    end
    return target, amount
end

RegisterCommand("money", function(source)
    if source == 0 then
        print("[" .. RESOURCE .. "] /money: use it from the game, not from the console.")
        return
    end
    local cash = Wallets.playerWallet(source, "cash")
    if not cash then
        tell(source, ("Wallet unavailable (%s)."):format(Wallets.ready() and "loading" or Wallets.notReadyReason()))
        attachLoop(source, true)
        return
    end
    local balance = Wallets.display(cash)
    tell(source, ("Balance: %s"):format(formatMoney(balance)))
    notify(source, { type = "info", title = "Wallet", message = ("Balance: %s"):format(formatMoney(balance)),
        icon = "E$", durationMs = 5000 })
end, false)

-- Player to player, one atomic operation.
RegisterCommand("pay", function(source, args)
    if source == 0 then
        print("[" .. RESOURCE .. "] /pay: use it from the game, not from the console.")
        return
    end
    local reply = function(text) tell(source, text) end
    local p = Wallets.byPlayer[source]
    if not p then reply("Wallet unavailable: tell an admin.") return end
    local target, amount = parseTargetAndAmount(args, reply, "/pay <playerId> <amount>")
    if not target then return end
    if target == source then reply("You can't pay yourself, choom.") return end
    paySeq = paySeq + 1
    local opId = Wallets.opIdFor(("rp_economy.pay.%s.%s."):format(Wallets.bootTag, Wallets.base36(paySeq)), p.subject)
    local receipt, why = Api.pay({ opId = opId, from = { player = source }, to = { player = target },
        amount = amount, reason = "pay" }, RESOURCE)
    if not receipt then
        if why == "insufficient_funds" then
            reply("Insufficient funds.")
        else
            reply(("Payment refused (%s)."):format(tostring(why)))
        end
        return
    end
    local senderName = Open77.players.name(source) or ("#" .. source)
    local targetName = Open77.players.name(target) or ("#" .. target)
    local sender = Wallets.playerWallet(source, "cash")
    local receiver = Wallets.playerWallet(target, "cash")
    reply(("You sent %s to %s. Balance: %s"):format(formatMoney(amount), targetName, formatMoney(Wallets.display(sender))))
    tell(target, ("%s sent you %s. Balance: %s"):format(senderName, formatMoney(amount), formatMoney(Wallets.display(receiver))))
end, false)

-- Restricted: ACL command.givemoney; the console is always allowed. A mint (sys:rp_economy:admin).
RegisterCommand("givemoney", function(source, args)
    local reply
    if source == 0 then
        reply = function(text) print("[" .. RESOURCE .. "] givemoney: " .. text) end
    else
        reply = function(text) tell(source, text) end
    end
    local target, amount = parseTargetAndAmount(args, reply, "/givemoney <playerId> <amount>")
    if not target then return end
    local cash = Wallets.playerWallet(target, "cash")
    local balances, why = Wallets.legacy({
        lines = { { money = amount, from = "sys:rp_economy:admin", to = cash.id } },
        kind = "givemoney", reason = "givemoney:by:" .. tostring(source), actor = cash.id,
    })
    if not balances then
        reply(("Credit refused (%s)."):format(tostring(why)))
        return
    end
    local newBalance = balances[cash.id]
    tell(target, ("An admin credited you %s. Balance: %s"):format(formatMoney(amount), formatMoney(newBalance)))
    if source ~= 0 then
        local targetName = Open77.players.name(target) or ("#" .. target)
        reply(("%s credited %s (balance: %s)."):format(targetName, formatMoney(amount), formatMoney(newBalance)))
    end
end, true)

RegisterCommand("payday", function(source)
    local paid = runPayday(source == 0 and "console" or ("player:" .. source))
    if source ~= 0 then
        tell(source, ("Payday triggered: %d player(s) paid."):format(paid))
    else
        print("[" .. RESOURCE .. "] payday: " .. paid .. " player(s) paid.")
    end
end, true)

-- Console: import the 1.x tables (idempotent), or report.
RegisterCommand("economy_migrate", function(source, args)
    if source ~= 0 then return end
    if not Tx.healthy then
        log("economy_migrate: coordinator unavailable (" .. tostring(Tx.reason) .. ")")
        return
    end
    Migrate.check()
    if Migrate.ready() then
        log("economy_migrate: nothing to do (state=complete)")
        attachEveryone()
        return
    end
    local summary, why = Migrate.run("console")
    if not summary then
        log("economy_migrate: " .. tostring(why))
        return
    end
    attachEveryone()
    preloadSocieties()
end, true)

RegisterCommand("economy_kvp_report", function(source)
    if source ~= 0 then return end
    Migrate.kvpReport()
end, true)

RegisterCommand("economy_status", function(source)
    if source ~= 0 then return end
    log(("status: coordinator=%s (%s) store=%s migration=%s pending_ops=%d players=%d"):format(
        Tx.healthy and "ready" or "unavailable", tostring(Tx.reason), tostring(Tx.store), Migrate.state,
        Wallets.pendingCount(), (function() local n = 0 for _ in pairs(Wallets.byPlayer) do n = n + 1 end return n end)()))
end, true)
