-- rp_inventory / server: the authoritative inventory of a Night City RP server.
--
-- Everything that moves an item runs here. Clients only render and request.
-- The /inv panel is a WebUI page (web/index.html) fed by rp_inventory:panel and
-- driven by rp_inventory:intent; every intent lands in the same functions as the commands.
--
-- Two backends, chosen once per boot (convar `rp_inventory_backend`, else
-- RpInventoryConfig.backend), never switched while running:
--   legacy        the original store: the in-memory cache is the truth for a connected player
--                 and every change is written straight through to SQL (or the kvp store when
--                 no database answers). Kept verbatim as the rollback path.
--   transactions  a facade over open77_transactions (world-interaction B2, A13 contract; the
--                 final coordinator, Open77 697e9e2f): char:<subject> pockets (subjectOf),
--                 stash:<id>, veh:<plate>:<part>, world:<id> (minted by openWorld);
--                 synchronous exports are write-behind, the *Async exports are one atomic
--                 operation with a receipt; never a KVP fallback; legacy rows are imported
--                 once per subject (server/migration.lua).
-- Item definitions go through the B1 schema (shared/schema.lua) in both backends.

local RESOURCE = GetCurrentResourceName()
local Items = RpInventoryItems
local Config = RpInventoryConfig
local Schema = RpItemSchema
local Accounts = RpInvAccounts

local BACKEND = GetConvar("rp_inventory_backend", Config.backend or "legacy")
if BACKEND ~= "transactions" then BACKEND = "legacy" end
local TX = BACKEND == "transactions"

-- B1: the built-in table is normalised in place, so Items[id] readers see the v1 definition.
local Registry = Schema.newRegistry(Items, { freezeShape = TX, builtin = RESOURCE })
local builtinRejected = Registry:importBuiltins()

local inventories = {}   -- [playerId] = { kind = "player", id = playerId, identifier, items = {}, capacity, loaded }
local stashes = {}       -- [stashId]  = { kind = "stash", id = stashId, items = {}, capacity, loaded }
local drops = {}         -- [tostring(lootId)] = { itemId, count }
local dbReady = false
local dbFailReason = nil

-- Transactions backend state (unused by the legacy backend).
local Facade = nil       -- RpInvFacade instance
local Migration = nil    -- RpInvMigration instance
local charPlayers = {}   -- [account] = { [playerId] = true }
local stashByAccount = {} -- [account] = stashId
local authorizers = {}   -- [scope] = { resource, export }

-- Panel refresh hooks, defined with the panel code below and forward-declared
-- so the primitive mutations can schedule a push whoever caused the change
-- (a command, the page, or another resource through the exports).
local refreshPanel        -- function(playerId, notice?)
local refreshStashViewers -- function(stashId)

---------------------------------------------------------------------------
-- Small helpers
---------------------------------------------------------------------------

local function log(fmt, ...)
    print(("[rp_inventory] " .. fmt):format(...))
end

local function tell(playerId, text)
    if type(playerId) ~= "number" or playerId <= 0 then
        print("[rp_inventory] " .. text)
        return
    end
    Open77.chat.send(playerId, { type = "system", author = "POCKETS", text = text, color = { 0, 229, 255 } })
end

local REASONS = {
    invalid_player = "That is not a player id.",
    player_not_found = "Nobody with that id in Night City.",
    not_loaded = "Pockets still loading. Try again in a second.",
    unknown_item = "No such item. Check the id or name.",
    invalid_count = "Give me a whole number above zero.",
    not_enough = "You do not have that many.",
    too_heavy = "Too heavy, choom. Drop something first (40 kg max).",
    target_too_heavy = "They cannot carry that much.",
    stash_full = "The stash is full.",
    not_usable = "You cannot use that. Sell it, give it, or drop it.",
    too_far = "Get closer. Three metres, arm's length.",
    self_target = "Giving things to yourself. Bold. No.",
    position_unknown = "The server has no fix on your position yet.",
    not_in_vehicle = "Sit in a vehicle first; the can does not pour itself.",
    fuel_unavailable = "No fuel system on this server. The can stays in your pockets.",
    full_health = "You are already at full health. Save it.",
    needs_refused = "You are not hungry or thirsty enough for that.",
    not_illegal = "That item is legal. NCPD cannot seize it.",
    not_surrendered = "They are neither cuffed nor surrendering. Cuff them or make them raise their hands.",
    loot_unavailable = "The loot system is not running. Nothing dropped.",
    dialog_active = "Close the other dialog first.",
    progress_active = "Finish what you are doing first.",
    -- transactions backend
    store_unavailable = "The pockets service is unavailable. Nothing moved; try again in a minute.",
    in_doubt = "The pockets service is slow to confirm. Check your pockets in a moment before retrying.",
    busy = "Still saving your last change. Try again in a second.",
    stack_limit = "That stack is full.",
    unknown_meta_field = "That item does not take that property.",
    invalid_meta = "That item property is not valid.",
    meta_unsupported = "This server's pockets cannot hold item properties.",
    not_migrated = "Your pockets are waiting for their import. Tell an admin.",
    legacy_diverged = "Your pockets need an admin check before they open (the old store changed).",
    migration_version_mismatch = "Your pockets were imported by a newer version. Tell an admin.",
    not_authorized = "You are not allowed to open that.",
    conflict = "Your pockets changed meanwhile. Try again.",
}

local function explain(reason)
    return REASONS[reason] or "That did not work. Try again in a moment."   -- never the raw code on screen; the server log keeps it
end

local function isCount(n)
    return type(n) == "number" and n >= 1 and n % 1 == 0 and n <= 1000000
end

-- Resolve "burrito", "Burrito", "bur" to an item id.
local function findItem(query)
    if type(query) ~= "string" or query == "" then return nil end
    local q = query:lower()
    if Items[q] then return q end
    for id, def in pairs(Items) do
        if def.label:lower() == q then return id end
    end
    local hit, hits = nil, 0
    for id, def in pairs(Items) do
        if id:sub(1, #q) == q or def.label:lower():sub(1, #q) == q then
            hit, hits = id, hits + 1
        end
    end
    if hits == 1 then return hit end
    return nil
end

local function containerWeight(c)
    if c.view then return Facade:weightG(c.view) / 1000 end
    local total = 0
    for itemId, n in pairs(c.items) do
        local def = Items[itemId]
        if def then total = total + def.weight * n end
    end
    return total
end

local function canCarry(c, itemId, n)
    local def = Items[itemId]
    if not def then return false end
    if c.view then return Facade:usedG(c.view) + def.weightG * n <= c.view.capacityG end
    return containerWeight(c) + def.weight * n <= c.capacity + 1e-6
end

-- The `sys:` account a legacy credit or debit is journaled against: the calling resource, so
-- the coordinator's journal says who minted or burned (A13 12.6 mint allowlist).
local function sysOf(name)
    return Accounts.sys(name or "unknown") or "sys:unknown"
end

local function sortedEntries(c)
    local entries = {}
    for itemId, n in pairs(c.items) do
        local def = Items[itemId]
        if def and n > 0 then
            entries[#entries + 1] = {
                id = itemId, label = def.label, count = n, weight = def.weight,
                total = def.weight * n, usable = def.usable == true, illegal = def.illegal == true,
                category = def.category or (def.effect and def.effect.kind) or "misc",
                unique = def.unique or nil,
            }
        end
    end
    table.sort(entries, function(a, b) return a.label < b.label end)
    return entries
end

-- Calls another resource's export: inline first, and through the promise form
-- when the callee needs to yield (a database-backed export). Returns
-- available (boolean), then the export's own values. A missing resource or
-- export answers false, reason and never raises.
local function callExport(resource, name, ...)
    local r = table.pack(pcall(Open77.exports.callSync, resource, name, ...))
    if r[1] then return true, table.unpack(r, 2, r.n) end
    local err = tostring(r[2])
    if err:find("export_yielded", 1, true) then
        local promise = Open77.exports.call(resource, name, ...)
        if promise then
            local a = table.pack(promise:await())
            if a[1] == nil and type(a[2]) == "string" and a[2]:find("^export_") then return false, a[2] end
            return true, table.unpack(a, 1, a.n)
        end
    end
    return false, err
end

-- An item is illegal for a holder unless they hold the permit job.
local function isIllegalFor(def, playerId)
    if not def.illegal then return false end
    if def.permit then
        local available, licensed = callExport("rp_jobs", "hasJob", playerId, def.permit)
        if available and licensed == true then return false end
    end
    return true
end

---------------------------------------------------------------------------
-- Persistence: SQL first, kvp only when the database is not ready
---------------------------------------------------------------------------

local function persist(c, itemId)
    local n = c.items[itemId] or 0
    if c.kind == "player" then
        if dbReady then
            if n > 0 then
                Open77.database.update("INSERT INTO rp_inventory_items (identifier, item_id, count) VALUES (?, ?, ?) "
                    .. "ON DUPLICATE KEY UPDATE count = VALUES(count)", { c.identifier, itemId, n })
            else
                Open77.database.update("DELETE FROM rp_inventory_items WHERE identifier = ? AND item_id = ?",
                    { c.identifier, itemId })
            end
        else
            local key = "inv:" .. c.identifier .. ":" .. itemId
            if n > 0 then Open77.kvp.set(key, n) else Open77.kvp.delete(key) end
        end
    else
        if dbReady then
            if n > 0 then
                Open77.database.update("INSERT INTO rp_inventory_stashes (stash_id, item_id, count) VALUES (?, ?, ?) "
                    .. "ON DUPLICATE KEY UPDATE count = VALUES(count)", { c.id, itemId, n })
            else
                Open77.database.update("DELETE FROM rp_inventory_stashes WHERE stash_id = ? AND item_id = ?",
                    { c.id, itemId })
            end
        else
            local key = "stash:" .. c.id .. ":" .. itemId
            if n > 0 then Open77.kvp.set(key, n) else Open77.kvp.delete(key) end
        end
    end
end

-- Runs one database call in its callback form and waits for the answer, with a
-- deadline. The cards document `.await` too, but the static validator does not
-- catalogue that spelling; a promise around the callback is the same wait and
-- cannot strand the task when the worker never answers.
-- Returns value, nil, true when the worker answered; nil, reason otherwise.
local function dbAwait(call, sql, params)
    local p = promise.new()
    local timer = SetTimeout(15000, function() p:reject("database_timeout") end)
    call(sql, params or {}, function(result)
        ClearTimeout(timer)
        p:resolve({ value = result })
    end)
    local box, reason = p:await()
    if type(box) ~= "table" then return nil, reason or "database_failed" end
    return box.value, nil, true
end

-- Wait a little for a database that is still connecting; never for one that will not come.
local function waitForDatabase(maxMs)
    local deadline = Open77.time.monotonic() + maxMs / 1000
    while not dbReady do
        local ready, reason = Open77.database.isReady()
        if not ready and reason ~= "database_connecting" and reason ~= "database_unreachable" then break end
        if Open77.time.monotonic() >= deadline then break end
        Wait(250)
    end
    return dbReady
end

-- Fills c.items from SQL or kvp. Yields: call from a managed task only.
local function loadContainer(c)
    waitForDatabase(10000)
    local items = {}
    if dbReady then
        local rows, reason
        for attempt = 1, 3 do
            if c.kind == "player" then
                rows, reason = dbAwait(Open77.database.query,
                    "SELECT item_id, count FROM rp_inventory_items WHERE identifier = ?", { c.identifier })
            else
                rows, reason = dbAwait(Open77.database.query,
                    "SELECT item_id, count FROM rp_inventory_stashes WHERE stash_id = ?", { c.id })
            end
            if type(rows) == "table" then break end
            log("%s %s: load attempt %d failed (%s)", c.kind, tostring(c.id), attempt, tostring(reason or "no rows"))
            Wait(2000)
        end
        if type(rows) ~= "table" then
            -- Never mark a container loaded on a failed read: a later write would erase the real rows.
            c.error = reason or "database_failed"
            log("%s %s NOT loaded: the database did not answer; it stays read-only until a reconnect", c.kind, tostring(c.id))
            return c
        end
        for _, row in ipairs(rows) do
            local n = tonumber(row.count) or 0
            if Items[row.item_id] and n > 0 then items[row.item_id] = math.floor(n) end
        end
        c.source = "sql"
    else
        local prefix = (c.kind == "player") and ("inv:" .. c.identifier .. ":") or ("stash:" .. c.id .. ":")
        for _, entry in ipairs(Open77.kvp.find(prefix, 512) or {}) do
            local itemId = entry.key:sub(#prefix + 1)
            local n = tonumber(entry.value) or 0
            if Items[itemId] and n > 0 then items[itemId] = math.floor(n) end
        end
        c.source = "kvp"
        local _, state = Open77.database.isReady()
        log("%s %s loaded from kvp: database not ready (%s)", c.kind, tostring(c.id),
            tostring(dbFailReason or state or "unknown"))
    end
    c.items = items
    c.loaded = true
    return c
end

---------------------------------------------------------------------------
-- Transactions backend plumbing (B2). Nothing here runs in the legacy backend.
---------------------------------------------------------------------------

-- One open77_transactions export, awaited. A refused dispatch or a lost answer is reported as
-- coordinator_unavailable; `ambiguous` says the request may have run (A13 2.6: in doubt).
local function txCall(name, ...)
    local pending, why = Open77.exports.call("open77_transactions", name, ...)
    if not pending then
        return nil, "coordinator_unavailable", { dispatch = why, retryable = true, ambiguous = false }
    end
    local r = table.pack(pending:await())
    if r[1] == nil and type(r[2]) == "string" and r[2]:find("^export_") then
        local ambiguous = r[2] == "export_timeout" or r[2] == "export_resource_stopped"
        return nil, "coordinator_unavailable", { dispatch = r[2], retryable = true, ambiguous = ambiguous }
    end
    return table.unpack(r, 1, r.n)
end

-- One NON-yielding open77_transactions export, inline (subjectOf, allowed, info): its values, or
-- nil, "coordinator_unavailable" when the coordinator is not running or the call raised.
local function txSync(name, ...)
    local res = table.pack(pcall(Open77.exports.callSync, "open77_transactions", name, ...))
    if not res[1] then return nil, "coordinator_unavailable", { detail = tostring(res[2]) } end
    return table.unpack(res, 2, res.n)
end

-- The durable subject of a connected player: the coordinator's subject provider (contract 12.5:
-- the account identifier by default; a character override provider's key when one registered).
-- A refusal is passed through, never replaced by the account identifier (that would fork a
-- character's pockets).
local function subjectOf(playerId)
    local subject, why = txSync("subjectOf", playerId)
    if type(subject) == "string" and subject ~= "" then return subject end
    return nil, why or "subject_unavailable"
end

-- One database call (callback form) with a deadline: value | nil, reason. Yields.
local function dbCall(method, sql, params)
    local p = promise.new()
    local timer = SetTimeout(15000, function() p:reject("database_timeout") end)
    local fn = method == "query" and Open77.database.query or Open77.database.update
    local accepted, refusal = fn(sql, params or {}, function(result, reason)
        ClearTimeout(timer)
        p:resolve({ value = result, reason = reason })
    end)
    if accepted == false then
        ClearTimeout(timer)
        return nil, refusal or "database_refused"
    end
    local box, reason = p:await()
    if type(box) ~= "table" then return nil, reason or "database_failed" end
    if box.reason then return nil, box.reason end
    return box.value
end

local function playersOf(account)
    local list = {}
    for playerId in pairs(charPlayers[account] or {}) do list[#list + 1] = playerId end
    table.sort(list)
    return list
end

-- The facade says a view changed by itself (reload, lost write-behind, committed operation):
-- refresh the counts the legacy code reads, raise rp_inventory:changed, push the panels.
local function onViewChanged(view, changes)
    for _, playerId in ipairs(playersOf(view.account)) do
        local inv = inventories[playerId]
        if inv and inv.view == view then
            inv.items = Facade:counts(view)
            for _, itemId in ipairs((function()
                local keys = {}
                for k in pairs(changes) do keys[#keys + 1] = k end
                table.sort(keys)
                return keys
            end)()) do
                TriggerEvent("rp_inventory:changed", playerId, itemId, changes[itemId])
            end
            if refreshPanel then refreshPanel(playerId) end
        end
    end
    local stashId = stashByAccount[view.account]
    local stash = stashId and stashes[stashId]
    if stash and stash.view == view then
        stash.items = Facade:counts(view)
        if refreshStashViewers then refreshStashViewers(stashId) end
    end
end

local reprojectDrops -- forward: world: drop containers re-projected after a (re)start

-- Async operations that answered in_doubt settle in the background (the facade polls the
-- coordinator's status with resolve, which fences an unknown outcome): every settlement raises
-- rp_inventory:settled(opId, state) -- "committed" or the not-committed state -- and runs the
-- continuation a flow registered for that opId (a drop or a pickup decides its projection then).
local doubtContinuations = {}   -- [opId] = function(state, receipt)
local settledRecently = {}      -- [opId] = { state, receipt } (a settlement before registration)

local function onSettled(opId, state, receipt)
    TriggerEvent("rp_inventory:settled", opId, state)
    local fn = doubtContinuations[opId]
    if fn then
        doubtContinuations[opId] = nil
        fn(state, receipt)
    else
        settledRecently[opId] = { state = state, receipt = receipt }
        SetTimeout(60000, function() settledRecently[opId] = nil end)
    end
end

local function afterDoubt(opId, fn)
    local done = settledRecently[opId]
    if done then
        settledRecently[opId] = nil
        return fn(done.state, done.receipt)
    end
    doubtContinuations[opId] = fn
end

if TX then
    Facade = RpInvFacade.new({
        call = txCall, callSync = txSync, spawn = CreateThread, wait = Wait,
        now = function() return Open77.time.monotonic() * 1000 end,
        log = function(fmt, ...) print(("[rp_inventory] " .. fmt):format(...)) end,
        registry = Registry, resource = RESOURCE, onView = onViewChanged,
        onReady = function() if reprojectDrops then CreateThread(reprojectDrops) end end,
        onSettled = onSettled,
    })
    Migration = RpInvMigration.new({
        db = dbCall, call = txCall, registry = Registry, facade = Facade,
        log = function(fmt, ...) print(("[rp_inventory] " .. fmt):format(...)) end,
        now = function() return Open77.time.unix() end,
        importUnknown = Config.importUnknownItems == true,
        requireStoreInfo = Config.requireDurableStore ~= false,
    })
end

-- Imports a subject's legacy rows once (when the server has a database). Yields.
-- Returns true | nil, reason.
local function ensureMigrated(account, kind, key, capacityG)
    if not waitForDatabase(10000) then
        local ready, state = Open77.database.isReady()
        if not ready and state == "database_unavailable" then return true end -- no database: no legacy rows
        return nil, "store_unavailable"
    end
    if Config.migrateOnLoad == false then
        local sourceOk, sourceWhy = Migration:checkSource()
        if not sourceOk then return nil, sourceWhy end
        local marker = Migration:marker(account)
        if marker == nil then return nil, "store_unavailable" end
        if marker then return true end
        local rows = Migration:legacyRows(kind, key)
        if rows and #rows == 0 then return true end
        return nil, "not_migrated"
    end
    local result, reason, info = Migration:ensure(account, kind, key, capacityG)
    -- Definers re-register their items when rp_inventory starts, concurrently with the first
    -- player loads: give them a moment before refusing a subject over an undefined id.
    for _ = 1, 3 do
        if result or reason ~= "unknown_items" then break end
        Wait(5000)
        result, reason, info = Migration:ensure(account, kind, key, capacityG)
    end
    if not result then
        log("%s not loaded: %s %s", account, tostring(reason), info and Schema.encode(info) or "")
        return nil, reason
    end
    return true
end

-- Authorization hooks (B2): a resource that owns access rules registers one scope
-- (`veh`, `world`, `stash`, `stash:<prefix>` such as `stash:home`) through registerAuthorizer.
-- Opening a trunk on screen is never authorization: vehicle scopes fail closed when nobody
-- registered; any registered scope fails closed when its owner does not answer `true`.
local function scopeOfStash(stashId)
    local prefix = stashId:match("^([^:]+):")
    if prefix and authorizers["stash:" .. prefix] then return "stash:" .. prefix end
    return "stash"
end

local function authorize(scope, request, required)
    local auth = authorizers[scope]
    if not auth then
        if required then return nil, "not_authorized", { detail = "no_authorizer", scope = scope } end
        return true
    end
    local pending = Open77.exports.call(auth.resource, auth.export, request)
    if not pending then return nil, "not_authorized", { detail = "authorizer_unavailable", scope = scope } end
    local allowed, reason = pending:await()
    if allowed == true then return true end
    return nil, "not_authorized", { detail = type(reason) == "string" and reason or "refused", scope = scope }
end

---------------------------------------------------------------------------
-- Player containers
---------------------------------------------------------------------------

-- Transactions backend: import the legacy rows (keyed by the account identifier) once, then open
-- char:<subject>, the subject being the coordinator's (subjectOf).
local function loadPlayerTx(playerId, inv)
    if not Facade:awaitReady(15000) then
        inv.error = "store_unavailable"
        tell(playerId, explain("store_unavailable"))
        return nil
    end
    if inventories[playerId] ~= inv then return nil end
    local subject, swhy = subjectOf(playerId)
    local account, why = nil, swhy
    if subject then account, why = Accounts.char(subject) end
    if not account then
        inv.error = why
        log("player %d inventory not loaded: %s", playerId, tostring(why))
        return nil
    end
    inv.subject, inv.account = subject, account
    local capacityG = math.floor(Config.maxCarryWeight * 1000 + 0.5)
    local ok, reason = ensureMigrated(account, "char", inv.identifier, capacityG)
    if inventories[playerId] ~= inv then return nil end
    if not ok then
        inv.error = reason
        tell(playerId, explain(reason))
        return nil
    end
    local view, vreason = Facade:load(account, capacityG)
    if inventories[playerId] ~= inv then return nil end
    if not view then
        inv.error = vreason
        tell(playerId, "Your pockets could not be read (" .. tostring(vreason) .. "). Reconnect in a minute.")
        return nil
    end
    charPlayers[account] = charPlayers[account] or {}
    charPlayers[account][playerId] = true
    inv.view = view
    inv.items = Facade:counts(view)
    inv.loaded = true
    inv.source = "transactions"
    log("player %d inventory loaded from open77_transactions (%s): %d item kinds, %.1f kg", playerId, account,
        #sortedEntries(inv), containerWeight(inv))
    return inv
end

local function loadPlayer(playerId)
    local identifier = Open77.players.identifier(playerId)
    if not identifier then
        log("player %d has no identifier yet, inventory not loaded", playerId)
        return nil
    end
    local inv = { kind = "player", id = playerId, identifier = identifier, items = {},
                  capacity = Config.maxCarryWeight, loaded = false }
    inventories[playerId] = inv
    if TX then return loadPlayerTx(playerId, inv) end
    loadContainer(inv)
    if inventories[playerId] ~= inv then return nil end  -- left while loading
    if not inv.loaded then
        tell(playerId, "Your pockets could not be read from the database. Reconnect in a minute.")
        return nil
    end
    log("player %d inventory loaded from %s: %d item kinds, %.1f kg", playerId, tostring(inv.source),
        #sortedEntries(inv), containerWeight(inv))
    return inv
end

local function resolvePlayer(playerId)
    playerId = tonumber(playerId)
    if not playerId or playerId <= 0 or playerId % 1 ~= 0 then return nil, "invalid_player" end
    local inv = inventories[playerId]
    if not inv then return nil, "player_not_found" end
    if not inv.loaded then return nil, "not_loaded" end
    return inv, playerId
end

-- Metadata on a legacy store: validated (unknown / invalid refused), but only the plain stack
-- can be stored, because rp_inventory_items has no metadata column.
local function legacyMetaProblem(itemId, meta)
    if meta == nil then return nil end
    local asset, canonical = Registry:assetFor(itemId, meta)
    if not asset then return canonical end
    local def = Items[itemId]
    if def.unique or asset ~= itemId then return "meta_unsupported" end
    return nil
end

-- The two primitive mutations. Both are synchronous and both log + persist + notify.
-- `meta` (B1 metadata) and `source` (the sys: account a transactions credit is journaled
-- against) are optional.
local function creditPlayer(playerId, itemId, n, why, meta, source)
    local inv, reason = resolvePlayer(playerId)
    if not inv then return nil, reason end
    local def = Items[itemId]
    if not def then return nil, "unknown_item" end
    if not isCount(n) then return nil, "invalid_count" end
    if not canCarry(inv, itemId, n) then return nil, "too_heavy" end
    if inv.view then
        local ok, wreason = Facade:credit(inv.view, itemId, n, meta, source or sysOf("unknown"))
        if not ok then return nil, wreason end
        inv.items = Facade:counts(inv.view)
    else
        local metaProblem = legacyMetaProblem(itemId, meta)
        if metaProblem then return nil, metaProblem end
        inv.items[itemId] = (inv.items[itemId] or 0) + n
        persist(inv, itemId)
    end
    log("player %d +%d %s total=%d%s", inv.id, n, itemId, inv.items[itemId], why and (" " .. why) or "")
    TriggerEvent("rp_inventory:changed", inv.id, itemId, n)
    if refreshPanel then refreshPanel(inv.id) end
    return true
end

local function debitPlayer(playerId, itemId, n, why, sink, meta)
    local inv, reason = resolvePlayer(playerId)
    if not inv then return nil, reason end
    local def = Items[itemId]
    if not def then return nil, "unknown_item" end
    if not isCount(n) then return nil, "invalid_count" end
    local have = inv.items[itemId] or 0
    if have < n then return nil, "not_enough" end
    local left = have - n
    if inv.view then
        local ok, wreason = Facade:debit(inv.view, itemId, n, meta, sink or sysOf("unknown"))
        if not ok then return nil, wreason end
        inv.items = Facade:counts(inv.view)
        left = inv.items[itemId] or 0
    else
        local metaProblem = legacyMetaProblem(itemId, meta)
        if metaProblem then return nil, metaProblem end
        inv.items[itemId] = left > 0 and left or nil
        persist(inv, itemId)
    end
    log("player %d -%d %s total=%d%s", inv.id, n, itemId, left, why and (" " .. why) or "")
    TriggerEvent("rp_inventory:changed", inv.id, itemId, -n)
    if refreshPanel then refreshPanel(inv.id) end
    return true
end

local function creditStash(stash, playerId, itemId, n)
    if not canCarry(stash, itemId, n) then return nil, "stash_full" end
    stash.items[itemId] = (stash.items[itemId] or 0) + n
    persist(stash, itemId)
    log("stash %s +%d %s total=%d by player %d", stash.id, n, itemId, stash.items[itemId], playerId)
    if refreshStashViewers then refreshStashViewers(stash.id) end
    return true
end

local function debitStash(stash, playerId, itemId, n)
    local have = stash.items[itemId] or 0
    if have < n then return nil, "not_enough" end
    local left = have - n
    stash.items[itemId] = left > 0 and left or nil
    persist(stash, itemId)
    log("stash %s -%d %s total=%d by player %d", stash.id, n, itemId, left, playerId)
    if refreshStashViewers then refreshStashViewers(stash.id) end
    return true
end

---------------------------------------------------------------------------
-- Exports (phase 1 contract): has add remove count list openStash
-- Synchronous callers (exports.rp_inventory:add(...)) are fine: nothing here yields. In the
-- transactions backend add/remove are write-behind (A13 7.4 decision (i)).
---------------------------------------------------------------------------

-- Client catalogue push and coordinator definitions, coalesced after a burst of define calls.
local scheduleCatalogue -- forward: defined with the catalogue code below
local definitionsPushPending = false
local function definitionsChanged()
    if scheduleCatalogue then scheduleCatalogue() end
    if TX and not definitionsPushPending then
        definitionsPushPending = true
        SetTimeout(250, function()
            definitionsPushPending = false
            if Facade:isReady() then Facade:_pushDefinitions() end
        end)
    end
end

-- define(items) -> registered, rejected, details
-- Lets another resource declare its own items (a crowbar, a boxed implant, a quickhack...) in
-- the shape of shared/items.lua, plus the optional B1 v1 fields (weightG, maxStack, unique,
-- metadata, durability, serial, quality, prop, hand, loot). Idempotent for its definer: call it
-- from onResourceStart and again when rp_inventory itself restarts (its VM restarts with the
-- built-in table only; rows of undefined ids stay in the store and come back after the next
-- definition). An id owned by another definer is REFUSED (details.collisions), never overwritten.
-- `registered` and `rejected` stay counts (rp_selftest, rp_crime and rp_fixer read them).
exports("define", function(items)
    if type(items) ~= "table" then return nil, "invalid_items" end
    local definer = GetInvokingResource() or "unknown"
    local registered, rejected, details = Registry:define(items, definer)
    if #details.collisions > 0 then
        log("define by %s: REFUSED colliding id(s) %s (owned by another resource)", definer,
            table.concat(details.collisions, ","))
    end
    if #details.warnings > 0 then
        log("define by %s: ignored unknown field(s) %s", definer, table.concat(details.warnings, ","))
    end
    log("define: %d item(s) registered, %d rejected", registered, rejected)
    if registered > 0 then definitionsChanged() end
    return registered, rejected, details
end)

exports("has", function(playerId, itemId, count)
    local inv = resolvePlayer(playerId)
    if not inv then return false end
    local n = tonumber(count) or 1
    return (inv.items[itemId] or 0) >= n
end)

-- add(playerId, itemId, count?, meta?) -- meta is the optional B1 metadata (stack variant or
-- instance fields); unknown or invalid metadata is refused.
exports("add", function(playerId, itemId, count, meta)
    return creditPlayer(playerId, itemId, tonumber(count) or 1, "(export add)", meta,
        sysOf(GetInvokingResource()))
end)

-- remove(playerId, itemId, count?, meta?) -- without meta: the plain stack first, then the
-- variants, then the most worn instances.
exports("remove", function(playerId, itemId, count, meta)
    return debitPlayer(playerId, itemId, tonumber(count) or 1, "(export remove)", sysOf(GetInvokingResource()), meta)
end)

exports("count", function(playerId, itemId)
    local inv = resolvePlayer(playerId)
    if not inv then return 0 end
    return inv.items[itemId] or 0
end)

-- list(playerId) -> entries, totalWeight, capacity | nil, reason
-- entries: { { id, label, count, weight, total, usable, illegal }, ... } sorted by label
exports("list", function(playerId)
    local inv, reason = resolvePlayer(playerId)
    if not inv then return nil, reason end
    return sortedEntries(inv), containerWeight(inv), inv.capacity
end)

---------------------------------------------------------------------------
-- UI kit server twins
---------------------------------------------------------------------------

-- Runs one uikit twin and normalises the answer: table | nil, reason.
local function uikit(method, playerId, ...)
    local promise, reason = Open77.exports.call("open77_uikit", method, playerId, ...)
    if not promise then return nil, reason end
    local answer, err = promise:await()
    if type(answer) ~= "table" then return nil, err or "no_answer" end
    return answer
end

local function chatListing(playerId, c, title)
    local entries = sortedEntries(c)
    tell(playerId, ("%s - %.1f / %.0f kg"):format(title, containerWeight(c), c.capacity))
    if #entries == 0 then
        tell(playerId, "Empty. Not even lint.")
        return
    end
    local parts = {}
    for _, e in ipairs(entries) do
        parts[#parts + 1] = ("%s x%d (%.1f kg)%s"):format(e.label, e.count, e.total, e.illegal and " [ILLEGAL]" or "")
    end
    tell(playerId, table.concat(parts, ", "))
end

---------------------------------------------------------------------------
-- Use
---------------------------------------------------------------------------

-- Applies the effect of one item. Returns true | nil, reason. May yield (fuel export, stats).
local function applyEffect(playerId, itemId, def)
    local effect = def.effect or {}
    local kind = effect.kind

    -- Items another resource declared through `define` own their effect: this resource only
    -- debits and raises rp_inventory:used; the definer applies whatever the item does. A
    -- `needs` table on the effect is applied here through rp_needs:apply for convenience.
    if def.definedBy then
        if type(effect.needs) == "table" then
            local called, result, reason = callExport("rp_needs", "apply", playerId, effect.needs, def.label)
            if called and not result then return nil, reason or "needs_refused" end
        end
        tell(playerId, effect.text or ("You use the %s."):format(def.label:lower()))
        return true
    end

    if kind == "heal" then
        local stats = Open77.stats.get(playerId)
        if stats and stats.health and stats.health.value >= stats.health.maximum and not effect.stamina then
            return nil, "full_health"
        end
        local ok, reason = Open77.players.heal(playerId, effect.amount or 25)
        if not ok then return nil, reason or "heal_refused" end
        if effect.stamina then Open77.players.restoreStamina(playerId) end
        tell(playerId, ("%s applied. +%d health."):format(def.label, effect.amount or 25))
        return true
    end

    if kind == "stamina" then
        local ok, reason = Open77.players.restoreStamina(playerId)
        if not ok then return nil, reason or "stamina_refused" end
        tell(playerId, "Your heart races. Stamina restored. Your nose will hate you tomorrow.")
        return true
    end

    if kind == "food" or kind == "drink" or kind == "smoke" then
        -- Optional needs resource owns the consumption effect and body gesture.
        local verb = kind == "food" and "eat" or kind == "smoke" and "smoke" or "drink"
        local called, result, reason = callExport("rp_needs", "consume", playerId, itemId)
        if called then
            if not result then return nil, reason or "needs_refused" end
            tell(playerId, ("You %s the %s."):format(verb, def.label:lower()))
        else
            tell(playerId, ("You %s the %s. (No needs system on this server, so it is just flavour.)")
                :format(verb, def.label:lower()))
        end
        return true
    end

    if kind == "fuel" then
        local seat = Open77.vehicles.getPlayerSeat(playerId)
        if not seat then return nil, "not_in_vehicle" end
        local litres = effect.litres or 20
        local called, result, reason = callExport("open77_fuel", "refuel", seat.vehicleId, litres)
        if not called then return nil, "fuel_unavailable" end
        if result == nil or result == false then return nil, reason or "refuel_refused" end
        local _, level = callExport("open77_fuel", "level", seat.vehicleId)
        if type(level) == "number" then
            tell(playerId, ("Poured %d L of CHOOH2. Tank: %.0f L."):format(litres, level))
        else
            tell(playerId, ("Poured %d L of CHOOH2 into the tank."):format(litres))
        end
        return true
    end

    return nil, "not_usable"
end

-- Uses one unit of an item: progress bar, effect, debit, event. May yield.
local function useItem(playerId, itemId)
    local inv, reason = resolvePlayer(playerId)
    if not inv then return nil, reason end
    local def = Items[itemId]
    if not def then return nil, "unknown_item" end
    if not def.usable then return nil, "not_usable" end
    if (inv.items[itemId] or 0) < 1 then return nil, "not_enough" end

    -- A short bar, cancellable, no focus taken. If the kit refuses it, use without it.
    local bar, barReason = uikit("progress", playerId, {
        label = "Using " .. def.label,
        duration = Config.useDurationMs,
        disable = { move = true, combat = true },
    })
    if bar then
        if not bar.ok then return nil, "cancelled" end
    elseif barReason == "progress_active" or barReason == "dialog_active" then
        return nil, barReason
    end

    -- Re-check after the wait: the item may have been given away meanwhile.
    if (inv.items[itemId] or 0) < 1 then return nil, "not_enough" end
    local ok, why = applyEffect(playerId, itemId, def)
    if not ok then return nil, why end
    local debited, dreason = debitPlayer(playerId, itemId, 1, "(used)", "sys:used")
    if not debited then return nil, dreason end
    TriggerEvent("rp_inventory:used", playerId, itemId)
    return true
end

---------------------------------------------------------------------------
-- Drop / pick up through the loot API
---------------------------------------------------------------------------

local function createDrop(def, itemId, count, pos, ttlMs)
    return Open77.loot.create({
        item = def.record or Config.lootRecord,
        quantity = count,
        position = { x = pos.x, y = pos.y, z = pos.z + 1.0 },
        bucket = pos.bucket,
        radius = 2.0,
        label = def.label,
        visualItem = def.visual or Config.lootVisual,
        ttlMs = ttlMs or Config.dropTtlMs,
    })
end

local function nowMs() return math.floor(Open77.time.unix() * 1000) end

-- Transactions backend: a drop is a world:<id> container that holds the goods; the native loot
-- is only its projection (A13 6.1, option b). The coordinator mints the container (openWorld)
-- and keeps its metadata, { owner = "rp_inventory", kind = "drop", item, count, x, y, z,
-- bucket }, and its expiry. The pickup credit is conditional on the picker's capacity, a refused
-- pickup re-projects the drop where it lay, not at the picker's feet, and an emptied container is
-- closed. The loot does not survive an rp_inventory restart (the loot registry is in memory, A13
-- F4); the goods do, and the next start re-projects every drop of this resource from the
-- coordinator's listing (reprojectDrops below).
local dropsByWorld = {}   -- [world account] = true while a loot projects it

local function dropMeta(itemId, count, pos)
    return { owner = RESOURCE, kind = "drop", item = itemId, count = count,
        x = pos.x, y = pos.y, z = pos.z, bucket = pos.bucket or 0 }
end

local function closeIfEmpty(account)
    local ok, reason = Facade:closeWorld(account)
    if ok then
        dropsByWorld[account] = nil
    elseif reason ~= "container_not_empty" and reason ~= "busy" then
        log("%s not closed (%s): it stays listed until it is emptied", account, tostring(reason))
    end
    return ok, reason
end

-- Closes an emptied world: container once no operation of this inventory holds it any more.
local function closeWhenIdle(account)
    for _ = 1, 20 do
        local ok, reason = closeIfEmpty(account)
        if ok or reason ~= "busy" then return end
        Wait(500)
    end
end

local function dropItemsTx(inv, playerId, def, itemId, count, pos)
    local picks, pwhy = Facade:pick(inv.view, itemId, count)
    if not picks then return nil, pwhy end
    local view, vreason = Facade:openWorld({
        capacityG = math.max(1, def.weightG * count),
        meta = dropMeta(itemId, count, pos),
        expiresAt = nowMs() + Config.dropTtlMs,
    })
    if not view then return nil, vreason end
    local account = view.account
    local lines, preason = Facade:planMove(inv.view, account, itemId, count)
    if not lines then closeIfEmpty(account); return nil, preason end
    local dropId, lreason = createDrop(def, itemId, count, pos)
    if not dropId then closeIfEmpty(account); return nil, lreason or "loot_unavailable" end
    local key = tostring(dropId)
    local place = { x = pos.x, y = pos.y, z = pos.z, bucket = pos.bucket }
    drops[key] = { itemId = itemId, count = count, world = account, pos = place }
    dropsByWorld[account] = true
    local receipt, reason, info = Facade:transact({
        kind = "inv.drop", actor = inv.account, lines = lines, capacityReason = { [account] = "stash_full" },
    })
    if not receipt then
        drops[key] = nil
        Open77.loot.remove(dropId)
        if reason == "in_doubt" and info and info.opId then
            -- The goods may be on the ground already: no projection until the outcome is known,
            -- then a commit is projected where it was dropped and a fence closes the empty box.
            dropsByWorld[account] = true
            afterDoubt(info.opId, function(state)
                dropsByWorld[account] = nil
                if state == "committed" then
                    local newId = createDrop(def, itemId, count, place)
                    if newId then
                        drops[tostring(newId)] = { itemId = itemId, count = count, world = account, pos = place }
                        dropsByWorld[account] = true
                    end
                    log("drop %s by player %d settled committed: projected as loot %s", account, playerId, tostring(newId))
                else
                    closeWhenIdle(account)
                    log("drop %s by player %d settled %s: nothing left the pockets", account, playerId, tostring(state))
                end
            end)
            return nil, reason, info
        end
        closeIfEmpty(account)
        return nil, reason, info
    end
    log("player %d dropped %s x%d into %s (loot %s, op %s)", playerId, itemId, count, account, key, tostring(receipt.opId))
    return true, dropId
end

-- Transactions backend pickup: world:<id> -> char:<picker>, one winner, capacity checked by the
-- coordinator. Anything but a commit leaves the goods in the world container and re-projects.
local function pickupTx(playerId, key, drop, how)
    local def = Items[drop.itemId]
    local inv, reason = resolvePlayer(playerId)
    local receipt, info
    if inv then
        local wview, wreason = Facade:load(drop.world)
        if wview then
            local lines, preason = Facade:planMove(wview, inv.account, drop.itemId, drop.count)
            if lines then
                receipt, reason, info = Facade:transact({
                    kind = "inv.pickup", actor = inv.account, lines = lines,
                    capacityReason = { [inv.account] = "too_heavy" },
                })
            else
                reason = preason
            end
        else
            reason = wreason
        end
    end
    if receipt then
        closeIfEmpty(drop.world)
        log("player %d picked up %s x%d from %s (loot %s%s, op %s)", playerId, drop.itemId, drop.count, drop.world,
            key, how, tostring(receipt.opId))
        if def then tell(playerId, ("Picked up %s x%d."):format(def.label, drop.count)) end
        return true
    end
    if reason == "in_doubt" and info and info.opId then
        -- The goods may be in the picker's pockets already: re-project only if nothing moved.
        if inv then tell(playerId, explain("in_doubt")) end
        afterDoubt(info.opId, function(state)
            if state == "committed" then
                closeWhenIdle(drop.world)
                log("pickup of %s by player %s settled committed", key, tostring(playerId))
            else
                local newId = def and drop.pos and createDrop(def, drop.itemId, drop.count, drop.pos) or nil
                if newId then drops[tostring(newId)] = drop end
                log("pickup of %s by player %s settled %s: re-projected as loot %s", key, tostring(playerId),
                    tostring(state), tostring(newId))
            end
        end)
        return nil, reason, info
    end
    local newId = def and drop.pos and createDrop(def, drop.itemId, drop.count, drop.pos) or nil
    if newId then drops[tostring(newId)] = drop end
    log("pickup of %s by player %s refused (%s): goods stay in %s%s", key, tostring(playerId), tostring(reason),
        drop.world, newId and (", re-projected as loot " .. tostring(newId)) or "")
    if inv then tell(playerId, explain(reason) .. (newId and " It stays on the ground." or "")) end
    return nil, reason
end

-- A drop's TTL ran out: the goods evaporate, as before, but through a journaled operation, and
-- the emptied container is closed. itemId / count nil: everything the container holds.
local function expireWorld(account, itemId, count)
    local wview, why = Facade:load(account)
    if not wview then return nil, why end
    local lines = {}
    if itemId then
        local part, pwhy = Facade:planMove(wview, "sys:expired", itemId, count)
        if not part then return nil, pwhy end
        lines = part
    else
        for id, n in pairs(Facade:counts(wview)) do
            for _, l in ipairs(Facade:planMove(wview, "sys:expired", id, n) or {}) do lines[#lines + 1] = l end
        end
    end
    local receipt, reason = nil, "empty"
    if #lines > 0 then receipt, reason = Facade:transact({ kind = "inv.expire", lines = lines }) end
    if receipt or reason == "empty" then closeIfEmpty(account) end
    return receipt, reason
end

local function expireTx(key, drop)
    local receipt, reason = expireWorld(drop.world, drop.itemId, drop.count)
    if receipt then
        log("drop %s (%s x%d) evaporated from %s (op %s)", key, drop.itemId, drop.count, drop.world, tostring(receipt.opId))
    else
        log("drop %s expired but %s keeps its goods (%s)", key, drop.world, tostring(reason))
    end
end

-- After a start (or a coordinator restart): every world: container this resource dropped that no
-- loot projects is listed from the coordinator (keyset pages) and projected again from its
-- metadata, where it lay, for the rest of its time; an expired one evaporates, an empty one is
-- closed. Bounded: Config.reprojectLimit containers per start.
reprojectDrops = function()
    local after, seen, projected = "", 0, 0
    local limit = Config.reprojectLimit or 500
    while seen < limit do
        local page, why = txCall("listWorld", after, math.min(100, limit - seen))
        if type(page) ~= "table" then
            log("drops not re-projected: listWorld %s", tostring(why))
            return
        end
        for _, row in ipairs(page) do
            after, seen = row.id, seen + 1
            local m = row.meta
            if type(m) == "table" and m.owner == RESOURCE and m.kind == "drop" and not dropsByWorld[row.id] then
                if (tonumber(row.weightG) or 0) == 0 then
                    closeIfEmpty(row.id)
                elseif row.expiresAt and row.expiresAt <= nowMs() then
                    expireWorld(row.id)
                else
                    local wview = Facade:load(row.id)
                    local pos = { x = tonumber(m.x) or 0, y = tonumber(m.y) or 0, z = tonumber(m.z) or 0,
                        bucket = tonumber(m.bucket) or 0 }
                    local ttl = row.expiresAt and math.max(1000, row.expiresAt - nowMs()) or nil
                    for itemId, n in pairs(wview and Facade:counts(wview) or {}) do
                        local def = Items[itemId]
                        local dropId = def and createDrop(def, itemId, n, pos, ttl)
                        if dropId then
                            drops[tostring(dropId)] = { itemId = itemId, count = n, world = row.id, pos = pos }
                            dropsByWorld[row.id] = true
                            projected = projected + 1
                        end
                    end
                end
            end
        end
        if #page < 100 then break end
    end
    if projected > 0 then log("re-projected %d drop(s) from open77_transactions", projected) end
end

local function dropItems(playerId, itemId, count)
    local inv, reason = resolvePlayer(playerId)
    if not inv then return nil, reason end
    local def = Items[itemId]
    if not def then return nil, "unknown_item" end
    if not isCount(count) then return nil, "invalid_count" end
    if (inv.items[itemId] or 0) < count then return nil, "not_enough" end
    local pos = Open77.players.position(playerId)
    if not pos then return nil, "position_unknown" end
    if inv.view then return dropItemsTx(inv, playerId, def, itemId, count, pos) end
    -- Loot first, debit second: a refused drop costs nothing.
    local dropId, lreason = createDrop(def, itemId, count, pos)
    if not dropId then return nil, lreason or "loot_unavailable" end
    drops[tostring(dropId)] = { itemId = itemId, count = count }
    local ok, dreason = debitPlayer(playerId, itemId, count, ("(dropped as loot %s)"):format(tostring(dropId)))
    if not ok then
        drops[tostring(dropId)] = nil
        Open77.loot.remove(dropId)
        return nil, dreason
    end
    return true, dropId
end

-- Credits a picked-up drop, or puts it back on the ground when the picker cannot carry it.
local function creditDrop(playerId, key, drop, how)
    if drop.world then return pickupTx(playerId, key, drop, how) end
    local def = Items[drop.itemId]
    if not def then return end
    local ok, reason = creditPlayer(playerId, drop.itemId, drop.count, ("(picked up loot %s%s)"):format(key, how))
    if ok then
        tell(playerId, ("Picked up %s x%d."):format(def.label, drop.count))
        return
    end
    local pos = Open77.players.position(playerId)
    local newId = pos and createDrop(def, drop.itemId, drop.count, pos) or nil
    if newId then drops[tostring(newId)] = drop end
    tell(playerId, explain(reason) .. (newId and " It stays on the ground." or ""))
end

AddEventHandler("onLootPickup", function(playerId, dropId, item, quantity, ownerResource)
    if ownerResource ~= RESOURCE then return end
    local key = tostring(dropId)
    local drop = drops[key]
    if not drop then
        log("pickup of unknown drop %s by player %s ignored", key, tostring(playerId))
        return
    end
    drops[key] = nil
    creditDrop(tonumber(playerId), key, drop, "")
end)

AddEventHandler("onLootRemoved", function(id, reason, resource)
    if resource ~= RESOURCE then return end
    if reason == "picked_up" then return end   -- onLootPickup owns that path
    local key = tostring(id)
    local drop = drops[key]
    if drop then
        log("drop %s (%s x%d) gone: %s", key, drop.itemId, drop.count, tostring(reason))
        drops[key] = nil
        if drop.world and reason == "expired" then expireTx(key, drop) end
    end
end)

-- Fallback to the native prompt: take the nearest of our drops within reach.
local function pickUpNearest(playerId)
    local pos = Open77.players.position(playerId)
    if not pos then return nil, "position_unknown" end
    local best, bestKey, bestDist
    for _, d in ipairs(Open77.loot.all(pos.bucket) or {}) do
        local key = tostring(d.id)
        local entry = drops[key]
        if entry then
            local p = d.position or d
            local dx = (tonumber(p.x) or 0) - pos.x
            local dy = (tonumber(p.y) or 0) - pos.y
            local dz = (tonumber(p.z) or 0) - pos.z
            local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
            if dist <= Config.interactDistance + 0.75 and (not bestDist or dist < bestDist) then
                best, bestKey, bestDist = d, key, dist
            end
        end
    end
    if not best then return nil, "nothing_nearby" end
    local entry = drops[bestKey]
    local inv = resolvePlayer(playerId)
    if not inv then return nil, "not_loaded" end
    if not canCarry(inv, entry.itemId, entry.count) then return nil, "too_heavy" end
    if not Open77.loot.remove(best.id) then
        drops[bestKey] = nil
        return nil, "already_taken"
    end
    drops[bestKey] = nil
    creditDrop(playerId, bestKey, entry, " via /ramasser")
    return true
end

---------------------------------------------------------------------------
-- Give
---------------------------------------------------------------------------

-- Validates a player-to-player target: number, exists, not self, loaded, within reach.
local function checkTarget(source, targetId)
    targetId = tonumber(targetId)
    if not targetId or targetId <= 0 or targetId % 1 ~= 0 then return nil, "invalid_player" end
    if targetId == source then return nil, "self_target" end
    if not Open77.players.name(targetId) then return nil, "player_not_found" end
    local tinv, reason = resolvePlayer(targetId)
    if not tinv then return nil, reason end
    local metres, dreason = Open77.players.distance(source, targetId)
    if not metres then return nil, dreason or "position_unknown" end
    if metres > Config.interactDistance then return nil, "too_far" end
    return targetId, tinv
end

-- Transactions backend: one operation char:<giver> -> char:<receiver>; nothing to roll back.
local function moveBetweenPlayers(kind, inv, tinv, itemId, count, opts, toReceiverReason)
    local lines, why = Facade:planMove(inv.view, tinv.account, itemId, count, opts and opts.meta, opts and opts.instances)
    if not lines then return nil, why end
    local receipt, reason, info = Facade:transact({
        kind = kind, actor = inv.account, opId = opts and opts.opId, lines = lines,
        capacityReason = { [tinv.account] = toReceiverReason },
    })
    if not receipt then return nil, reason, info end
    log("player %d -> player %d %s x%d (%s, op %s)", inv.id, tinv.id, itemId, count, kind, tostring(receipt.opId))
    return receipt
end

local function giveItems(source, targetId, itemId, count, opts)
    local inv, reason = resolvePlayer(source)
    if not inv then return nil, reason end
    local def = Items[itemId]
    if not def then return nil, "unknown_item" end
    if not isCount(count) then return nil, "invalid_count" end
    if (inv.items[itemId] or 0) < count then return nil, "not_enough" end
    local tid, tinv = checkTarget(source, targetId)
    if not tid then return nil, tinv end
    if not canCarry(tinv, itemId, count) then return nil, "target_too_heavy" end
    if inv.view then
        local receipt, greason, info = moveBetweenPlayers("inv.give", inv, tinv, itemId, count, opts, "target_too_heavy")
        if not receipt then return nil, greason, info end
        local from = Open77.players.name(source) or ("#" .. source)
        local to = Open77.players.name(tid) or ("#" .. tid)
        tell(source, ("You hand %s x%d to %s."):format(def.label, count, to))
        tell(tid, ("%s hands you %s x%d."):format(from, def.label, count))
        return true, receipt
    end
    local ok, dreason = debitPlayer(source, itemId, count, ("(given to player %d)"):format(tid))
    if not ok then return nil, dreason end
    local credited, creason = creditPlayer(tid, itemId, count, ("(given by player %d)"):format(source))
    if not credited then
        creditPlayer(source, itemId, count, "(give rolled back)")
        return nil, creason
    end
    local from = Open77.players.name(source) or ("#" .. source)
    local to = Open77.players.name(tid) or ("#" .. tid)
    tell(source, ("You hand %s x%d to %s."):format(def.label, count, to))
    tell(tid, ("%s hands you %s x%d."):format(from, def.label, count))
    return true
end

-- The dialog half of a give: pick the item (and how many) from the giver's pockets, then move it.
-- targetId may be nil: then the giver picks somebody within reach.
local function giveDialog(source, targetId)
    local inv, reason = resolvePlayer(source)
    if not inv then tell(source, explain(reason)) return end
    local entries = sortedEntries(inv)
    if #entries == 0 then tell(source, "Nothing to give. Your pockets are empty.") return end

    local fields = {}
    if not targetId then
        local near = Open77.players.nearby(source, Config.interactDistance) or {}
        local options = {}
        for _, p in ipairs(near) do
            options[#options + 1] = { value = tostring(p.playerId),
                label = ("%s (#%d, %.1f m)"):format(p.name or "?", p.playerId, p.distance or 0) }
        end
        if #options == 0 then tell(source, "Nobody within arm's length to give anything to.") return end
        fields[#fields + 1] = { id = "target", type = "select", label = "To whom?", options = options, required = true }
    else
        local tid, terr = checkTarget(source, targetId)
        if not tid then tell(source, explain(terr)) return end
        targetId = tid
    end
    local itemOptions = {}
    for _, e in ipairs(entries) do
        itemOptions[#itemOptions + 1] = { value = e.id, label = ("%s x%d (%.1f kg)"):format(e.label, e.count, e.weight) }
    end
    fields[#fields + 1] = { id = "item", type = "select", label = "What?", options = itemOptions, required = true }
    fields[#fields + 1] = { id = "count", type = "number", label = "How many?", min = 1, max = 1000, default = 1, required = true }

    local answer, uerr = uikit("input", source, {
        title = targetId and ("Give to " .. (Open77.players.name(targetId) or ("#" .. targetId))) or "Give an item",
        description = "The server checks the distance and their carry weight.",
        fields = fields, confirm = "Give", cancel = "Cancel", timeoutMs = 60000,
    })
    if not answer then
        tell(source, "Dialog unavailable (" .. tostring(uerr) .. "). Use /give <playerId> <item> [count].")
        return
    end
    if not answer.ok then return end
    local v = answer.value or {}
    local tid = targetId or tonumber(v.target)
    local n = math.floor(tonumber(v.count) or 0)
    local ok, gerr = giveItems(source, tid, v.item, n)
    if not ok then tell(source, explain(gerr)) end
end

---------------------------------------------------------------------------
-- Search (fouiller) and seize (saisir)
---------------------------------------------------------------------------

-- Does an animation state mention a profile id, wherever the host put it?
local function mentionsProfile(state, profileId)
    if type(state) ~= "table" then return false end
    local keys = { "profileId", "profile", "id" }
    for _, key in ipairs(keys) do
        if state[key] == profileId then return true end
    end
    if type(state.steps) == "table" then
        for _, step in ipairs(state.steps) do
            if step == profileId then return true end
            if type(step) == "table" then
                for _, key in ipairs(keys) do
                    if step[key] == profileId then return true end
                end
            end
        end
    end
    local encoded = json.encode(state)
    return encoded ~= nil and encoded:find('"' .. profileId .. '"', 1, true) ~= nil
end

-- Held by the RP kit, or hands up: the two states that allow a frisk.
local function isSurrendered(targetId)
    local called, hold = callExport("open77_rp_basics", "state", targetId)
    if called and hold then return true, "held" end
    local anim = Open77.animations.current(targetId)
    if anim and mentionsProfile(anim, "handsup") then return true, "handsup" end
    return false
end

local function searchPlayer(source, targetId)
    local tid, tinv = checkTarget(source, targetId)
    if not tid then return nil, tinv end
    if not isSurrendered(tid) then return nil, "not_surrendered" end
    local name = Open77.players.name(tid) or ("#" .. tid)
    tell(tid, ("%s is going through your pockets."):format(Open77.players.name(source) or "Someone"))
    chatListing(source, tinv, name .. "'s pockets")
    local illegal = {}
    for _, e in ipairs(sortedEntries(tinv)) do
        if isIllegalFor(Items[e.id], tid) then illegal[#illegal + 1] = e.id end
    end
    if #illegal > 0 then
        tell(source, ("Contraband found: %s. Seize it with /saisir %d <item>."):format(table.concat(illegal, ", "), tid))
    end
    log("player %d searched player %d", source, tid)
    return true
end

local function seizeItem(source, targetId, itemId)
    local tid, tinv = checkTarget(source, targetId)
    if not tid then return nil, tinv end
    local def = Items[itemId]
    if not def then return nil, "unknown_item" end
    if not isSurrendered(tid) then return nil, "not_surrendered" end
    if not isIllegalFor(def, tid) then return nil, "not_illegal" end
    local n = tinv.items[itemId] or 0
    if n < 1 then return nil, "not_enough" end
    local inv = resolvePlayer(source)
    if not inv then return nil, "not_loaded" end
    if not canCarry(inv, itemId, n) then return nil, "too_heavy" end
    if inv.view then
        local receipt, sreason = moveBetweenPlayers("inv.seize", tinv, inv, itemId, n, nil, "too_heavy")
        if not receipt then return nil, sreason end
        tell(source, ("Seized %s x%d from %s."):format(def.label, n, Open77.players.name(tid) or ("#" .. tid)))
        tell(tid, ("%s seized your %s x%d."):format(Open77.players.name(source) or "Someone", def.label, n))
        return true
    end
    local ok, reason = debitPlayer(tid, itemId, n, ("(seized by player %d)"):format(source))
    if not ok then return nil, reason end
    local credited, creason = creditPlayer(source, itemId, n, ("(seized from player %d)"):format(tid))
    if not credited then
        creditPlayer(tid, itemId, n, "(seizure rolled back)")
        return nil, creason
    end
    tell(source, ("Seized %s x%d from %s."):format(def.label, n, Open77.players.name(tid) or ("#" .. tid)))
    tell(tid, ("%s seized your %s x%d."):format(Open77.players.name(source) or "Someone", def.label, n))
    return true
end

---------------------------------------------------------------------------
-- The /inv panel: a WebUI page shipped by this resource (web/index.html).
--
-- The server owns the panel. It pushes the whole state through
-- rp_inventory:panel (on open and after every change, whoever caused it) and
-- answers each page intent with the same functions the slash commands use.
-- The page renders and asks; it never decides. A stash opened through the
-- openStash export is the same panel with a second column.
---------------------------------------------------------------------------

-- B7 (docs/world-interaction/b7-ui.md): the panel is PRIVATE. Every state goes to one player
-- through TriggerClientEvent(..., playerId, ...); nothing of it is ever written to a state bag
-- or broadcast. It shows only what that player may see: their own pockets, a stash a resource
-- opened for them (openStash: the caller authorizes), and a read-only vehicle cargo after
-- rp_garage:canAccessVehicle(..., "cargo", "view") said yes.
local panels = {}        -- [playerId] = { stashId?, name, seq, anchor?, cargo? = { vehicleId, view } }
local panelPending = {}  -- [playerId] = { notice = table | nil } while a push is scheduled
local panelOps = {}      -- [playerId] = { [opId] = op } panel actions answered in_doubt, watched until settled
local panelBusy = {}     -- [playerId] = action while a page intent runs (one at a time per player)

-- The RP name of a connected player (rp_identity, else the account name). fullName never yields.
local function nameOf(playerId)
    local ok, full = callExport("rp_identity", "fullName", playerId)
    if ok and type(full) == "string" and full ~= "" then return full end
    return Open77.players.name(playerId) or ("player " .. tostring(playerId))
end

-- Scalar metadata fields only (the B1 schema allows integer, number, string, boolean, enum).
local function scalarMeta(meta)
    if type(meta) ~= "table" then return nil end
    local out, any = {}, false
    for k, v in pairs(meta) do
        local t = type(v)
        if type(k) == "string" and (t == "string" or t == "number" or t == "boolean") then
            out[k] = v
            any = true
        end
    end
    return any and out or nil
end

-- Transactions backend: the entries of a container as the facade sees them (committed plus
-- pending minus held), with what matters per unit: stack variants (quality...) and unique units
-- (durability, serial), plus `held` = units leaving in an operation the store has not settled
-- yet (shown as "in transit", never as gone).
local function txEntries(c)
    local view = c.view
    local stacks, instances = Facade:effective(view)
    local byItem = {}
    local function entryOf(itemId)
        local e = byItem[itemId]
        if e then return e end
        local def = itemId and Items[itemId]
        if not def then return nil end
        e = {
            id = itemId, label = def.label, count = 0, weight = def.weight, total = 0,
            usable = def.usable == true, illegal = def.illegal == true,
            category = def.category or (def.effect and def.effect.kind) or "misc",
            unique = def.unique or nil,
        }
        byItem[itemId] = e
        return e
    end
    for asset, n in pairs(stacks) do
        local itemId, meta = Registry:decodeAsset(asset)
        if not itemId then itemId = Schema.splitAsset(asset) end
        local e = entryOf(itemId)
        if e then
            e.count = e.count + n
            if Items[itemId].stackFields then
                e.variants = e.variants or {}
                e.variants[#e.variants + 1] = { asset = asset, count = n, meta = scalarMeta(meta) }
            end
        end
    end
    for iid, rec in pairs(instances) do
        local e = entryOf(rec.item)
        if e then
            e.count = e.count + 1
            e.units = e.units or {}
            e.units[#e.units + 1] = { id = iid, meta = scalarMeta(rec.meta) }
        end
    end
    for asset, n in pairs(view.held.stacks) do
        local e = entryOf(Schema.splitAsset(asset))
        if e then e.held = (e.held or 0) + n end
    end
    for iid in pairs(view.held.inst) do
        local rec = view.committed.instances[iid] or view.pending.add[iid]
        local e = rec and entryOf(rec.item)
        if e then e.held = (e.held or 0) + 1 end
    end
    local out = {}
    for _, e in pairs(byItem) do
        if e.count > 0 or (e.held or 0) > 0 then
            e.total = e.weight * e.count
            if e.variants then table.sort(e.variants, function(a, b) return a.asset < b.asset end) end
            out[#out + 1] = e
        end
    end
    table.sort(out, function(a, b) return a.label < b.label end)
    -- Bounded payload: at most panelUnitsShown units per item and panelUnitsBudget per container
    -- (a unit is ~100 bytes of JSON; a state must stay far below the event envelope).
    local cap, budget = Config.panelUnitsShown or 24, Config.panelUnitsBudget or 64
    for _, e in ipairs(out) do
        if e.units then
            table.sort(e.units, function(a, b)
                local da = tonumber(a.meta and a.meta.durability) or math.huge
                local db = tonumber(b.meta and b.meta.durability) or math.huge
                if da ~= db then return da < db end
                return a.id < b.id
            end)
            local keep = math.max(0, math.min(cap, budget))
            if #e.units > keep then
                e.moreUnits = #e.units - keep
                for i = #e.units, keep + 1, -1 do e.units[i] = nil end
            end
            budget = budget - #e.units
            if #e.units == 0 then e.units = nil end
        end
    end
    return out
end

local function containerView(c)
    local out = { id = c.id, weight = containerWeight(c), capacity = c.capacity }
    if c.view then
        out.entries = txEntries(c)
        local v = c.view
        -- saving: write-behind changes not acknowledged yet (already shown); incomingKg: credits
        -- into this container in flight (not shown until they settle).
        if #v.queue > 0 or v.inflight > 0 or v.held.weightIn > 0 then
            out.sync = { saving = #v.queue > 0, inflight = v.inflight, incomingKg = v.held.weightIn / 1000 }
        end
    else
        out.entries = sortedEntries(c)
    end
    return out
end

-- The nearest other player within reach, the one a panel "Give" goes to.
local function nearestPlayer(playerId)
    local entry = Open77.players.closest(playerId, { radius = Config.interactDistance })
    if type(entry) ~= "table" or type(entry.playerId) ~= "number" then return nil end
    return { playerId = entry.playerId, name = nameOf(entry.playerId), distance = entry.distance or 0 }
end

-- The panel actions the store has not settled (answered in_doubt), oldest first.
local function pendingOpsOf(playerId)
    local list = {}
    local now = Open77.time.monotonic()
    for _, op in pairs(panelOps[playerId] or {}) do
        list[#list + 1] = { opId = op.opId, action = op.action, item = op.itemId, label = op.label, count = op.count,
            ageSeconds = math.floor(now - op.since), state = op.state }
    end
    table.sort(list, function(a, b)
        if a.ageSeconds ~= b.ageSeconds then return a.ageSeconds > b.ageSeconds end
        return a.opId < b.opId
    end)
    return #list > 0 and list or nil
end

-- Everything the page renders, nothing else. nil when the panel is not open.
local function panelState(playerId, notice)
    local session = panels[playerId]
    local inv = resolvePlayer(playerId)
    if not session or not inv then return nil end
    session.seq = (session.seq or 0) + 1
    local state = {
        open = true,
        seq = session.seq,
        backend = BACKEND,
        playerId = playerId,
        name = session.name,
        pockets = containerView(inv),
        nearest = nearestPlayer(playerId),
        pending = pendingOpsOf(playerId),
        notice = notice,
    }
    local stash = session.stashId and stashes[session.stashId]
    if stash and stash.loaded then state.stash = containerView(stash) end
    if session.cargo and session.cargo.view then state.cargo = session.cargo.view end
    return state
end

-- Coalesces every refresh of the next 50 ms into one push (a give is a debit
-- plus a credit, a rollback three changes). The last notice wins.
refreshPanel = function(playerId, notice)
    if not panels[playerId] then return end
    local pending = panelPending[playerId]
    if pending then
        if notice then pending.notice = notice end
        return
    end
    panelPending[playerId] = { notice = notice }
    SetTimeout(50, function()
        local p = panelPending[playerId]
        panelPending[playerId] = nil
        local state = panelState(playerId, p and p.notice or nil)
        -- One player, never -1: the panel is private (B7).
        if state then TriggerClientEvent("rp_inventory:panel", playerId, state) end
    end)
end

refreshStashViewers = function(stashId)
    for id, session in pairs(panels) do
        if session.stashId == stashId then refreshPanel(id) end
    end
end

local function closePanel(playerId, tellClient)
    if not panels[playerId] then return end
    panels[playerId] = nil
    panelPending[playerId] = nil
    if tellClient then TriggerClientEvent("rp_inventory:panel", playerId, { open = false }) end
end

-- Loads a stash on first use and waits for a load already in flight. Yields.
-- Returns the stash | nil.
-- Transactions backend: import the legacy stash rows once, then open stash:<id>.
local function loadStashTx(stash, capacity)
    local account, why = Accounts.stash(stash.id)
    if not account then stash.error = why; return nil end
    stash.account = account
    if not Facade:awaitReady(15000) then stash.error = "store_unavailable"; return nil end
    local capacityG = math.floor(capacity * 1000 + 0.5)
    local ok, reason = ensureMigrated(account, "stash", stash.id, capacityG)
    if not ok then stash.error = reason; return nil end
    local view, vreason = Facade:load(account, capacityG)
    if not view then stash.error = vreason; return nil end
    stashByAccount[account] = stash.id
    stash.view = view
    stash.items = Facade:counts(view)
    stash.loaded = true
    stash.source = "transactions"
    return stash
end

local function loadStash(stashId, capacity)
    local stash = stashes[stashId]
    if not stash then
        stash = { kind = "stash", id = stashId, items = {}, capacity = capacity, loaded = false }
        stashes[stashId] = stash
        if TX then loadStashTx(stash, capacity) else loadContainer(stash) end
        if not stash.loaded then
            stashes[stashId] = nil   -- let the next caller retry the read
            return nil
        end
        log("stash %s loaded from %s: %d item kinds", stashId, tostring(stash.source), #sortedEntries(stash))
    elseif not stash.loaded then
        for _ = 1, 40 do
            Wait(250)
            if stash.loaded or stash.error then break end
        end
        if not stash.loaded then
            stashes[stashId] = nil
            return nil
        end
    end
    if stash.view and capacity ~= stash.capacity then
        Facade:load(stash.account, math.floor(capacity * 1000 + 0.5))
    end
    stash.capacity = capacity
    return stash
end

-- Opens (or re-opens) the panel; with a stash id, the two-column form. Yields (stash load).
local function openPanel(playerId, stashId, capacity)
    local inv, reason = resolvePlayer(playerId)
    if not inv then tell(playerId, explain(reason)) return end
    -- seq carries over a re-open, so an intent from the previous page is still recognised as stale.
    local session = { stashId = nil, name = nameOf(playerId), seq = panels[playerId] and panels[playerId].seq or 0 }
    if stashId then
        local stash = loadStash(stashId, capacity)
        if not stash then
            tell(playerId, "The stash could not be read. Try again in a minute.")
            return
        end
        session.stashId = stashId
        -- B7: the panel no longer freezes the player (cursor-only focus), so the stash column is
        -- tied to where it was opened: walking away closes it (panelStashReach).
        session.anchor = Open77.players.position(playerId)
    end
    if not inventories[playerId] then return end   -- left while the stash was loading
    panels[playerId] = session
    refreshPanel(playerId)
end

-- Transactions backend: one operation between the pockets and the stash, re-authorized on every
-- move when the stash's prefix has an authorizer (a key revoked while the panel is open stops
-- the next move).
local function stashMoveTx(action, inv, stash, itemId, n, opts)
    local request = { playerId = inv.id, subject = inv.account, account = stash.account, stashId = stash.id,
        action = action, item = itemId, count = n }
    local allowed, why, info = authorize(scopeOfStash(stash.id), request, false)
    if not allowed then return nil, why, info end
    local fromView, to = inv.view, stash.account
    local capacityReason = { [stash.account] = "stash_full" }
    if action == "take" then
        fromView, to = stash.view, inv.account
        capacityReason = { [inv.account] = "too_heavy" }
    end
    local lines, preason = Facade:planMove(fromView, to, itemId, n, opts and opts.meta, opts and opts.instances)
    if not lines then return nil, preason end
    local receipt, reason, rinfo = Facade:transact({
        kind = "inv." .. action, actor = inv.account, opId = opts and opts.opId, lines = lines,
        capacityReason = capacityReason,
    })
    if not receipt then return nil, reason, rinfo end
    log("player %d %s %s x%d %s stash %s (op %s)", inv.id, action == "take" and "took" or "stored", itemId, n,
        action == "take" and "from" or "into", stash.id, tostring(receipt.opId))
    return true, receipt
end

-- Pockets <-> stash moves. Both check the receiving side first, then move with a rollback.
local function takeFromStash(playerId, stash, itemId, n, opts)
    local inv, reason = resolvePlayer(playerId)
    if not inv then return nil, reason end
    if not isCount(n) then return nil, "invalid_count" end
    if (stash.items[itemId] or 0) < n then return nil, "not_enough" end
    if not canCarry(inv, itemId, n) then return nil, "too_heavy" end
    if stash.view then return stashMoveTx("take", inv, stash, itemId, n, opts) end
    local ok, why = debitStash(stash, playerId, itemId, n)
    if not ok then return nil, why end
    local credited, cwhy = creditPlayer(playerId, itemId, n, ("(from stash %s)"):format(stash.id))
    if not credited then
        creditStash(stash, playerId, itemId, n)
        return nil, cwhy
    end
    return true
end

local function storeToStash(playerId, stash, itemId, n, opts)
    local inv, reason = resolvePlayer(playerId)
    if not inv then return nil, reason end
    if not isCount(n) then return nil, "invalid_count" end
    if (inv.items[itemId] or 0) < n then return nil, "not_enough" end
    if not canCarry(stash, itemId, n) then return nil, "stash_full" end
    if stash.view then return stashMoveTx("store", inv, stash, itemId, n, opts) end
    local ok, why = debitPlayer(playerId, itemId, n, ("(into stash %s)"):format(stash.id))
    if not ok then return nil, why end
    local stored, swhy = creditStash(stash, playerId, itemId, n)
    if not stored then
        creditPlayer(playerId, itemId, n, "(stash store rolled back)")
        return nil, swhy
    end
    return true
end

-- Page intents. Each returns ok, text, reason?, info?: the notice the page shows and, when
-- refused, the refusal token and its info (info.coordinator = the coordinator's own token, such
-- as capacity_exceeded; info.opId = the operation of an in_doubt answer). The state push that
-- follows is scheduled by the mutation itself or by the dispatcher.
local intents = {}

-- What a refusal means on the panel (B7). `kind` drives the colour: ok, refused, retry (nothing
-- moved, try again), pending (the store has not settled it: never shown as a loss).
local PANEL_TEXT = {
    in_doubt = "Pending: the store has not confirmed yet. Nothing is lost; it keeps checking.",
    store_unavailable = "The inventory service is unavailable. Nothing moved; try again in a minute.",
    busy = "Still saving your last change. Try again in a second.",
    busy_intent = "Still working on your last action.",
    not_authorized = "Not allowed: the owner's rules refused it.",
    panel_blocked = "Another menu holds the keyboard: close it, then /inv again.",
    no_vehicle = "No registered vehicle within reach.",
    no_access = "You have no access to this vehicle's cargo.",
    action_not_permitted = "Your access to this vehicle does not include its cargo.",
    impounded = "This vehicle is impounded.",
    off_duty = "Clock in first: that access needs you on duty.",
    no_job_order = "No job order from the owner for this vehicle.",
    warrant_required = "A warrant is required for this vehicle.",
    vehicle_not_tracked = "This vehicle is not registered: it has no cargo hold.",
    no_cargo_layout = "This vehicle has no cargo bed.",
    cargo_unavailable = "The cargo service is not running on this server.",
    garage_unavailable = "The garage registry is not running on this server.",
    intent_error = "That did not work (server error). Check your pockets before retrying.",
}
local PANEL_KIND = {
    in_doubt = "pending", store_unavailable = "retry", busy = "retry", busy_intent = "retry",
    coordinator_unavailable = "retry", cargo_unavailable = "retry", garage_unavailable = "retry",
}

local function panelText(reason)
    return PANEL_TEXT[reason] or explain(reason)
end

local function noticeOf(ok, text, reason, info, stale)
    local n = { ok = ok == true, text = text }
    if ok then
        n.kind = "ok"
        return n
    end
    n.kind = PANEL_KIND[reason] or "refused"
    n.reason = reason
    if type(info) == "table" then
        if type(info.coordinator) == "string" then n.code = info.coordinator end
        if type(info.opId) == "string" then n.opId = info.opId end
    end
    if stale then n.stale = true end
    return n
end

local function intentItem(payload)
    local itemId = type(payload.item) == "string" and payload.item or ""
    if not Items[itemId] then return nil, "unknown_item" end
    return itemId, math.floor(tonumber(payload.count) or 1)
end

-- ---------------------------------------------------------------------------
-- In-doubt panel actions (B7): the units stay "in transit" in the view (the facade keeps its
-- holds and settles in the background); the panel lists the action as pending and reads the
-- operation's status (read-only, never `resolve`: the facade owns settlement) until it is
-- committed or proven not committed. The answer reaches the panel, or the chat once closed.
-- ---------------------------------------------------------------------------
local VERBS = { store = "Stored", take = "Took", give = "Handed over", drop = "Dropped" }
local NOT_COMMITTED_STATES = { aborted = true, failed = true, expired = true, cancelled = true }
local MAX_WATCHED = 8

local function settleOp(playerId, op, outcome, state)
    local list = panelOps[playerId]
    if not list or list[op.opId] ~= op then return end
    list[op.opId] = nil
    if next(list) == nil then panelOps[playerId] = nil end
    local text, notice
    if outcome == "committed" then
        text = ("Confirmed: %s %s x%d."):format(VERBS[op.action] or op.action, op.label, op.count)
        notice = { ok = true, kind = "ok", text = text, opId = op.opId }
    elseif outcome == "not_committed" then
        text = ("Not done: %s x%d did not move (%s). Nothing was lost."):format(op.label, op.count, tostring(state))
        notice = { ok = false, kind = "refused", reason = "not_committed", code = state, text = text, opId = op.opId }
    else
        text = ("Still unconfirmed after %d min: tell an admin (operation %s)."):format(
            math.floor((Config.panelPendingWatchS or 900) / 60), op.opId)
        notice = { ok = false, kind = "pending", reason = "in_doubt", text = text, opId = op.opId }
    end
    log("player %d panel %s %s x%d op %s settled: %s%s", playerId, op.action, op.itemId, op.count, op.opId,
        outcome, state and (" " .. state) or "")
    if panels[playerId] then refreshPanel(playerId, notice) else tell(playerId, text) end
end

local function watchOp(playerId, action, itemId, count, info)
    if not TX or not itemId or type(info) ~= "table" or type(info.opId) ~= "string" then return end
    local list = panelOps[playerId] or {}
    local n = 0
    for _ in pairs(list) do n = n + 1 end
    if n >= MAX_WATCHED or list[info.opId] then return end
    local op = { opId = info.opId, action = action, itemId = itemId, label = Items[itemId].label, count = count,
        since = Open77.time.monotonic(), state = "in_doubt" }
    list[info.opId] = op
    panelOps[playerId] = list
    CreateThread(function()
        local delay = 2000
        local deadline = op.since + (Config.panelPendingWatchS or 900)
        while true do
            Wait(delay)
            if not (panelOps[playerId] and panelOps[playerId][op.opId] == op) then return end
            local st = txCall("status", op.opId)
            local state = type(st) == "table" and st.state or nil
            if state == "committed" then return settleOp(playerId, op, "committed") end
            if state and NOT_COMMITTED_STATES[state] then return settleOp(playerId, op, "not_committed", state) end
            if state then op.state = state end
            if Open77.time.monotonic() >= deadline then return settleOp(playerId, op, "timeout") end
            delay = math.min(delay * 2, 15000)
        end
    end)
end

intents.refresh = function() return true end

intents.use = function(playerId, session, payload)
    local itemId, err = intentItem(payload)
    if not itemId then return false, explain(err), err end
    local ok, why = useItem(playerId, itemId)
    if ok then return true, ("Used %s."):format(Items[itemId].label) end
    if why == "cancelled" then return false, nil end
    return false, panelText(why), why
end

intents.drop = function(playerId, session, payload)
    local itemId, n = intentItem(payload)
    if not itemId then return false, explain(n), n end
    local ok, why, info = dropItems(playerId, itemId, n)
    if not ok then return false, panelText(why), why, info end
    local text = ("Dropped %s x%d at your feet."):format(Items[itemId].label, n)
    tell(playerId, text .. " The prompt or /ramasser picks it up.")
    return true, text
end

-- The server picks the receiver: the nearest other player within 3 m, exactly what /give checks.
intents.give = function(playerId, session, payload)
    local itemId, n = intentItem(payload)
    if not itemId then return false, explain(n), n end
    local near = nearestPlayer(playerId)
    if not near then return false, "Nobody within arm's length to give anything to.", "too_far" end
    local ok, why, info = giveItems(playerId, near.playerId, itemId, n)
    if not ok then return false, panelText(why), why, info end
    return true, ("Handed %s x%d to %s."):format(Items[itemId].label, n, near.name)
end

local function openStashOf(session)
    local stash = session.stashId and stashes[session.stashId]
    if stash and stash.loaded then return stash end
    return nil
end

intents.store = function(playerId, session, payload)
    local itemId, n = intentItem(payload)
    if not itemId then return false, explain(n), n end
    local stash = openStashOf(session)
    if not stash then return false, "No stash open.", "no_stash" end
    local ok, why, info = storeToStash(playerId, stash, itemId, n)
    if not ok then return false, panelText(why), why, info end
    local text = ("Stored %s x%d."):format(Items[itemId].label, n)
    tell(playerId, text)
    return true, text
end

intents.take = function(playerId, session, payload)
    local itemId, n = intentItem(payload)
    if not itemId then return false, explain(n), n end
    local stash = openStashOf(session)
    if not stash then return false, "No stash open.", "no_stash" end
    local ok, why, info = takeFromStash(playerId, stash, itemId, n)
    if not ok then return false, panelText(why), why, info end
    local text = ("Took %s x%d."):format(Items[itemId].label, n)
    tell(playerId, text)
    return true, text
end

-- ---------------------------------------------------------------------------
-- The read-only vehicle cargo view (B7 over A9). The SERVER picks the vehicle: the one the
-- player sits in, else the nearest registered one within panelCargoReach. rp_garage decides the
-- access (canAccessVehicle(..., "cargo", "view"), asked here and again inside rp_cargo:contents);
-- an open tailgate on screen is never authorization. Nothing here moves cargo: loading and
-- unloading belong to the job flows (rp_cargo:load / unload).
-- ---------------------------------------------------------------------------
local function cargoVehicle(playerId)
    local seat = Open77.vehicles.getPlayerSeat(playerId)
    if type(seat) == "table" and seat.vehicleId ~= nil then return seat.vehicleId end
    local list = Open77.vehicles.nearby(playerId, Config.panelCargoReach or 5.0, { limit = 4 })
    for _, entry in ipairs(type(list) == "table" and list or {}) do
        local ok, plate = callExport("rp_garage", "plateOf", entry.id)
        if not ok then return nil, "garage_unavailable" end
        if type(plate) == "string" and plate ~= "" then return entry.id end
    end
    return nil, "no_vehicle"
end

local function cargoInReach(playerId, vehicleId)
    local seat = Open77.vehicles.getPlayerSeat(playerId)
    if type(seat) == "table" and seat.vehicleId == vehicleId then return true end
    local list = Open77.vehicles.nearby(playerId, (Config.panelCargoReach or 5.0) + 1.0, { limit = 8 })
    for _, entry in ipairs(type(list) == "table" and list or {}) do
        if entry.id == vehicleId then return true end
    end
    return false
end

-- The cargo of one vehicle as one player may see it. Yields (rp_cargo:contents).
-- Returns view | nil, reason.
local function fetchCargo(playerId, vehicleId)
    local available, allowed, why = callExport("rp_garage", "canAccessVehicle", playerId, vehicleId, "cargo", "view")
    if not available then return nil, "garage_unavailable" end
    if allowed ~= true then return nil, type(why) == "string" and why or "no_access" end
    local pending = Open77.exports.call("rp_cargo", "contents", playerId, vehicleId)
    if not pending then return nil, "cargo_unavailable" end
    local c, reason = pending:await()
    if type(c) ~= "table" then
        if reason == nil or (type(reason) == "string" and reason:find("^export_")) then return nil, "cargo_unavailable" end
        return nil, reason
    end
    local slots = {}
    for _, s in ipairs(type(c.slots) == "table" and c.slots or {}) do
        local objects = {}
        for _, o in ipairs(type(s.objects) == "table" and s.objects or {}) do
            local def = Items[o.item]
            objects[#objects + 1] = { instance = o.instance, item = o.item, label = def and def.label or tostring(o.item),
                rank = o.rank }
        end
        slots[#slots + 1] = { slot = s.slot, maxStack = s.maxStack, objects = objects }
    end
    return {
        vehicleId = vehicleId, plate = c.plate, account = c.account, record = c.record,
        capacityKg = c.capacityKg, objects = c.objects or 0, free = c.free or 0, slots = slots, readOnly = true,
    }
end

intents.cargo = function(playerId, session, payload)
    if payload.close then
        session.cargo = nil
        return true, nil
    end
    local vehicleId, why = cargoVehicle(playerId)
    if not vehicleId then return false, panelText(why), why end
    local view, reason = fetchCargo(playerId, vehicleId)
    if panels[playerId] ~= session then return false, nil end
    if not view then
        session.cargo = nil
        return false, panelText(reason), reason
    end
    session.cargo = { vehicleId = vehicleId, view = view }
    return true, ("Cargo of %s: %d object(s), %d free place(s). Read-only."):format(
        tostring(view.plate), view.objects, view.free)
end

-- Re-reads one open cargo view (access is asked again every time). Coalesced per session.
local function refreshCargoOf(playerId, session)
    local cargo = session.cargo
    if not cargo then return end
    if cargo.refreshing then cargo.again = true return end
    cargo.refreshing = true
    CreateThread(function()
        repeat
            cargo.again = false
            local view, reason = fetchCargo(playerId, cargo.vehicleId)
            if panels[playerId] ~= session or session.cargo ~= cargo then return end
            if not view then
                session.cargo = nil
                refreshPanel(playerId, noticeOf(false, "Cargo view closed: " .. panelText(reason), reason))
                return
            end
            cargo.view = view
            refreshPanel(playerId)
        until not cargo.again
        cargo.refreshing = false
    end)
end

local function refreshCargoViewers(match)
    for playerId, session in pairs(panels) do
        if session.cargo and session.cargo.view and match(session.cargo) then refreshCargoOf(playerId, session) end
    end
end

-- Transport: the page -> client -> rp_inventory:intent -> here -> rp_inventory:panel
RegisterNetEvent("rp_inventory:intent", function(payload)
    local playerId = source
    if type(playerId) ~= "number" or playerId <= 0 then return end
    if type(payload) ~= "table" or type(payload.action) ~= "string" then return end
    local action = payload.action

    -- Escape / the X on the page, focus taken by another menu, or a client that (re)started:
    -- nothing to check.
    if action == "close" then
        closePanel(playerId, false)
        return
    end
    -- B7: the client refused to take focus over another menu (a dialog, the chat) and gave up.
    if action == "blocked" then
        local was = panels[playerId] ~= nil
        closePanel(playerId, false)
        if was then tell(playerId, panelText(payload.reason == "dialog_active" and "dialog_active" or "panel_blocked")) end
        return
    end
    -- The client has no WebUI: the chat listing stands in, as rp_mdt's fallback does.
    if action == "unavailable" then
        local session = panels[playerId]
        closePanel(playerId, false)
        local inv = resolvePlayer(playerId)
        if not inv then return end
        chatListing(playerId, inv, "Pockets")
        local stash = session and openStashOf(session)
        if stash then chatListing(playerId, stash, "Stash " .. stash.id) end
        tell(playerId, ("Panel unavailable (%s); listed in chat. Commands: /use /drop /give."):format(
            tostring(payload.reason or "webui_unavailable")))
        return
    end
    local session = panels[playerId]
    if not session then
        -- A page nobody opened from here (stale client state): put it away.
        TriggerClientEvent("rp_inventory:panel", playerId, { open = false })
        return
    end
    local handler = intents[action]
    if not handler then
        refreshPanel(playerId, noticeOf(false, "Unknown panel action.", "unknown_action"))
        return
    end
    -- One intent at a time per player: an in_doubt answer can take 20 s, and a second click
    -- (or a forged burst) must not start a second operation against a view still settling.
    if panelBusy[playerId] and action ~= "refresh" then
        refreshPanel(playerId, noticeOf(false, panelText("busy_intent"), "busy_intent"))
        return
    end
    -- The page echoes the seq of the state it showed: an older one means the click was made on a
    -- stale picture, and a refusal then says so instead of looking like a bug.
    local stale = type(payload.seq) == "number" and payload.seq < (session.seq or 0)
    panelBusy[playerId] = action
    local r = table.pack(pcall(handler, playerId, session, payload))
    panelBusy[playerId] = nil
    if not r[1] then
        log("panel intent %s of player %d raised: %s", action, playerId, tostring(r[2]))
        r = table.pack(true, false, panelText("intent_error"), "intent_error")
    end
    local ok, text, reason, info = r[2], r[3], r[4], r[5]
    if not ok and reason == "in_doubt" then
        local itemId, n = intentItem(payload)
        watchOp(playerId, action, itemId, n, info)
    end
    if not panels[playerId] then return end   -- closed while the intent ran (a 3 s use, say)
    if not ok and stale and (reason == "not_enough" or reason == "unknown_item") then
        text = "That changed meanwhile: here is what you have now."
    end
    refreshPanel(playerId, text and noticeOf(ok, text, reason, info, stale) or nil)
end)

-- Cargo views follow the cargo: a commit on the account they show (any writer), a load or unload
-- through rp_cargo, an access change in rp_garage (keys, grants, impound) and a despawn.
AddEventHandler("open77_transactions:committed", function(_, _, accounts)
    if type(accounts) ~= "table" then return end
    local touched = {}
    for _, a in ipairs(accounts) do touched[a] = true end
    refreshCargoViewers(function(cargo) return touched[cargo.view.account] == true end)
end)
AddEventHandler("rp_cargo:changed", function(plate)
    refreshCargoViewers(function(cargo) return cargo.view.plate == plate end)
end)
AddEventHandler("rp_garage:changed", function(_, plate)
    refreshCargoViewers(function(cargo) return cargo.view.plate == plate end)
end)
AddEventHandler("rp_garage:despawned", function(plate)
    refreshCargoViewers(function(cargo) return cargo.view.plate == plate end)
end)

-- Every exit closes the panel and (through { open = false }) releases the client's focus. Death:
-- a panel left over the respawn screen cannot be clicked through.
AddEventHandler("onPlayerLifeStateChanged", function(playerId, _, phase)
    playerId = tonumber(playerId)
    if not playerId or not panels[playerId] then return end
    if phase ~= "alive" and phase ~= "recovering" then closePanel(playerId, true) end
end)

-- Reach watch, once a second: the panel does not freeze the player, so a stash column closes when
-- they walk away from where it opened, and a cargo view when they leave the vehicle's reach.
local function farFrom(pos, anchor, metres)
    local dx, dy, dz = pos.x - anchor.x, pos.y - anchor.y, pos.z - anchor.z
    return dx * dx + dy * dy + dz * dz > metres * metres
end

CreateThread(function()
    while true do
        Wait(1000)
        local ok, err = pcall(function()
            for playerId, session in pairs(panels) do
                if session.stashId and type(session.anchor) == "table" then
                    local pos = Open77.players.position(playerId)
                    if type(pos) == "table" and farFrom(pos, session.anchor, Config.panelStashReach or 6.0) then
                        session.stashId, session.anchor = nil, nil
                        refreshPanel(playerId, noticeOf(false, "You walked away from the stash: it is closed.", "too_far"))
                    end
                end
                local cargo = session.cargo
                if cargo and not cargo.refreshing and not cargoInReach(playerId, cargo.vehicleId) then
                    session.cargo = nil
                    refreshPanel(playerId, noticeOf(false, "You left the vehicle: cargo view closed.", "too_far"))
                end
            end
        end)
        if not ok then log("panel reach watch: %s", tostring(err)) end
    end
end)

-- openStash(playerId, stashId, capacity) -> true (panel scheduled) | nil, reason
exports("openStash", function(playerId, stashId, capacity)
    local inv, reason = resolvePlayer(playerId)
    if not inv then return nil, reason end
    if type(stashId) ~= "string" or #stashId == 0 or #stashId > 64 or not stashId:match("^[%w_%-:%.]+$") then
        return nil, "invalid_stash"
    end
    if TX then
        -- Durable keys only: no session id, no runtime vehicle/prop id as a stash key.
        local account, why = Accounts.stash(stashId)
        if not account then return nil, why end
    end
    local cap = tonumber(capacity) or Config.defaultStashCapacity
    if cap <= 0 then return nil, "invalid_capacity" end
    CreateThread(function() openPanel(inv.id, stashId, cap) end)
    return true
end)

---------------------------------------------------------------------------
-- B1/B2 exports. Synchronous ones never yield; the *Async ones and read/status/openVehicle/
-- createWorld yield: call them with Open77.exports.call(...):await() from a managed task.
-- Every async mutation is ONE open77_transactions operation: receipt | nil, reason, info
-- (info.opId lets the caller poll `status` after an in_doubt). Transactions backend only:
-- the legacy backend answers nil, "backend_legacy".
---------------------------------------------------------------------------

exports("backend", function() return BACKEND end)

-- The client catalogue's head: { schema, version, hash, pages, items }.
exports("catalogueVersion", function()
    local head = Registry:catalogue()
    return Schema.copy(head)
end)

-- A copy of one normalised definition (B1 v1 shape) | nil, "unknown_item".
exports("itemDefinition", function(itemId)
    local def = Registry:get(itemId)
    if not def then return nil, "unknown_item" end
    local out = Schema.copy(def)
    out.definedBy = Registry:definerOf(itemId)
    return out
end)

-- Durable account ids (pure, both backends): char:<identifier>, stash:<id>, veh:<PLATE>:<part>,
-- world:<id>. A session id or a runtime entity id is refused (session_key / runtime_id_key).
exports("accountOf", function(playerId)
    playerId = tonumber(playerId)
    if not playerId or playerId < 1 or playerId % 1 ~= 0 then return nil, "invalid_player" end
    local inv = inventories[playerId]
    if inv and inv.account then return inv.account end
    local identifier = Open77.players.identifier(playerId)
    if not identifier then return nil, "player_not_found" end
    if not TX then return Accounts.char(identifier) end
    local subject, why = subjectOf(playerId)
    if not subject then return nil, why end
    return Accounts.char(subject)
end)
exports("stashAccount", function(stashId) return Accounts.stash(stashId) end)
exports("vehicleAccount", function(plate, part) return Accounts.vehicle(plate, part) end)
exports("worldAccount", function(worldId) return Accounts.world(worldId) end)

-- registerAuthorizer(scope, exportName) -> true | nil, reason
-- scope: "veh" | "world" | "stash" | "stash:<prefix>". The caller resource answers
-- exports.<caller>:<exportName>(request) with true, or false/nil plus a reason; request =
-- { playerId, subject, account, action, item, count, plate?, part?, stashId?, worldId? }.
-- One resource per scope (A9 owns `veh`); the same resource may re-register after a restart.
exports("registerAuthorizer", function(scope, exportName)
    local caller = GetInvokingResource()
    if not caller then return nil, "invalid_caller" end
    if type(scope) ~= "string" or not (scope == "veh" or scope == "world" or scope == "stash"
        or scope:match("^stash:[%w_%-%.]+$")) then
        return nil, "invalid_scope"
    end
    if type(exportName) ~= "string" or not exportName:match("^[%a_][%w_]*$") then return nil, "invalid_export" end
    local current = authorizers[scope]
    if current and current.resource ~= caller then return nil, "authorizer_taken" end
    authorizers[scope] = { resource = caller, export = exportName }
    log("authorizer for %s: %s:%s", scope, caller, exportName)
    return true
end)

local function requireTx()
    if not TX then return nil, "backend_legacy" end
    if not Facade:isReady() then return nil, "store_unavailable" end
    return true
end

local function loadedPlayer(playerId)
    local inv, reason = resolvePlayer(playerId)
    if not inv then return nil, reason end
    if not inv.view then return nil, "not_loaded" end
    return inv
end

local function countArg(count)
    local n = tonumber(count) or 1
    if not isCount(n) then return nil end
    return math.tointeger(n)
end

-- grantPockets(opId, playerId, ttlMs?) -> true | nil, reason
-- A one-operation grant (open77_transactions authorize, contract 7.2): the CALLING resource may
-- touch this player's pockets (char:<subject>) in the coordinator operation `opId` only, for
-- ttlMs (default 30 s; spent when that operation commits or is fenced). For a job that commits
-- its own operation into or out of the pockets (C1: a salvage credit out of sys:salvage, a sale
-- through rp_economy) while the server's `writers` keeps `char` to rp_inventory. Callers:
-- Config.pocketGrantees (caller_not_allowed otherwise); the player must be loaded here. The
-- pockets' view follows through open77_transactions:committed.
exports("grantPockets", function(opId, playerId, ttlMs)
    local ok, why = requireTx()
    if not ok then return nil, why end
    local caller = GetInvokingResource()
    if not caller or not (Config.pocketGrantees or {})[caller] then return nil, "caller_not_allowed" end
    local inv, reason = loadedPlayer(playerId)
    if not inv then return nil, reason end
    local granted, gwhy = txSync("authorize", opId, caller, { inv.account }, ttlMs)
    if granted ~= true then return nil, gwhy or "store_unavailable" end
    log("pockets of player %d granted to %s for operation %s", inv.id, caller, tostring(opId))
    return true
end)

-- giveAsync(fromPlayerId, toPlayerId, itemId, count, opts?) -> receipt | nil, reason, info
-- opts: { opId, meta, instances, maxDistance }. Both players loaded; no reach rule unless
-- maxDistance is given (the caller owns its interaction rules, /give keeps its 3 m).
exports("giveAsync", function(fromId, toId, itemId, count, opts)
    local ok, why = requireTx()
    if not ok then return nil, why end
    local n = countArg(count)
    if not n then return nil, "invalid_count" end
    if not Items[itemId] then return nil, "unknown_item" end
    local inv, r1 = loadedPlayer(fromId)
    if not inv then return nil, r1 end
    local tinv, r2 = loadedPlayer(toId)
    if not tinv then return nil, r2 end
    if inv == tinv then return nil, "self_target" end
    opts = type(opts) == "table" and opts or {}
    if opts.maxDistance then
        local metres = Open77.players.distance(inv.id, tinv.id)
        if not metres then return nil, "position_unknown" end
        if metres > opts.maxDistance then return nil, "too_far" end
    end
    return moveBetweenPlayers("inv.give", inv, tinv, itemId, n, opts, "target_too_heavy")
end)

-- storeAsync / takeAsync(playerId, stashId, itemId, count, opts?) -> receipt | nil, reason, info
-- The caller (housing...) keeps its own access checks; a registered stash authorizer is asked too.
local function stashAsync(action, playerId, stashId, itemId, count, opts)
    local ok, why = requireTx()
    if not ok then return nil, why end
    local n = countArg(count)
    if not n then return nil, "invalid_count" end
    if not Items[itemId] then return nil, "unknown_item" end
    local inv, reason = loadedPlayer(playerId)
    if not inv then return nil, reason end
    local account, aw = Accounts.stash(stashId)
    if not account then return nil, aw end
    opts = type(opts) == "table" and opts or {}
    local capacity = tonumber(opts.capacity) or (stashes[stashId] and stashes[stashId].capacity)
        or Config.defaultStashCapacity
    local stash = loadStash(stashId, capacity)
    if not stash then return nil, "store_unavailable" end
    local moved, result, info
    if action == "store" then
        moved, result, info = storeToStash(inv.id, stash, itemId, n, opts)
    else
        moved, result, info = takeFromStash(inv.id, stash, itemId, n, opts)
    end
    if not moved then return nil, result, info end
    return result
end
exports("storeAsync", function(playerId, stashId, itemId, count, opts)
    return stashAsync("store", playerId, stashId, itemId, count, opts)
end)
exports("takeAsync", function(playerId, stashId, itemId, count, opts)
    return stashAsync("take", playerId, stashId, itemId, count, opts)
end)

-- sellAsync(playerId, sale) -> receipt | nil, reason, info
-- sale = { items = { { item, count, meta? }... }, buyer = "dealer" (a sys: name), payouts =
-- { { to = "cash" | "bank" | "soc:<name>", amount }... }, opId?, kind? }. Goods leave the
-- pockets and every payout lands in ONE operation (A13 6.1 sale). Requires
-- Config.coordinatorWallets (else wallet_not_coordinated): rp_economy 2.0 keeps the wallets on the
-- coordinator and re-reads them on open77_transactions:committed. rp_economy:sale is the usual
-- path (it applies its money allowlist per original caller); this one mints from sys:<buyer> as
-- rp_inventory, so it also needs a coordinator mint rule `rp_inventory sys:<buyer> money <cap>`.
exports("sellAsync", function(playerId, sale)
    local ok, why = requireTx()
    if not ok then return nil, why end
    if Config.coordinatorWallets ~= true then return nil, "wallet_not_coordinated" end
    if type(sale) ~= "table" or type(sale.items) ~= "table" or #sale.items == 0 or #sale.items > 16 then
        return nil, "invalid_sale"
    end
    local inv, reason = loadedPlayer(playerId)
    if not inv then return nil, reason end
    local buyer = Accounts.sys(type(sale.buyer) == "string" and sale.buyer or (GetInvokingResource() or "buyer"))
    if not buyer then return nil, "invalid_sale" end
    local lines = {}
    for _, entry in ipairs(sale.items) do
        local n = type(entry) == "table" and countArg(entry.count)
        if not n or not Items[entry.item] then return nil, "invalid_sale" end
        local moved, mwhy = Facade:planMove(inv.view, buyer, entry.item, n, entry.meta)
        if not moved then return nil, mwhy end
        for _, l in ipairs(moved) do lines[#lines + 1] = l end
    end
    for _, payout in ipairs(type(sale.payouts) == "table" and sale.payouts or {}) do
        local amount = type(payout) == "table" and math.tointeger(tonumber(payout.amount))
        if not amount or amount < 1 then return nil, "invalid_sale" end
        local to
        if payout.to == "cash" or payout.to == "bank" then
            to = payout.to .. ":" .. inv.subject
        elseif type(payout.to) == "string" and payout.to:match("^soc:[%w_%-]+$") then
            to = payout.to
        end
        if not to then return nil, "invalid_sale" end
        lines[#lines + 1] = { money = amount, from = buyer, to = to }
    end
    local kind = type(sale.kind) == "string" and sale.kind:sub(1, 32) or "inv.sell"
    local receipt, reason2, info = Facade:transact({ kind = kind, actor = inv.account, opId = sale.opId, lines = lines })
    if not receipt then return nil, reason2, info end
    log("player %d sold %d line(s) to %s (op %s)", inv.id, #lines, buyer, tostring(receipt.opId))
    return receipt
end)

-- openVehicle(plate, part, capacityKg) -> { account, capacityKg } | nil, reason
-- Creates or resizes veh:<PLATE>:<part>. The cargo layout owner (A9) decides parts and sizes.
exports("openVehicle", function(plate, part, capacityKg)
    local ok, why = requireTx()
    if not ok then return nil, why end
    local account, aw = Accounts.vehicle(plate, part)
    if not account then return nil, aw end
    local cap = tonumber(capacityKg)
    if not cap or cap <= 0 or cap > 100000 then return nil, "invalid_capacity" end
    local view, vreason = Facade:load(account, math.floor(cap * 1000 + 0.5))
    if not view then return nil, vreason end
    return { account = account, capacityKg = cap }
end)

local function vehicleMove(action, playerId, plate, part, itemId, count, opts)
    local ok, why = requireTx()
    if not ok then return nil, why end
    local n = countArg(count)
    if not n then return nil, "invalid_count" end
    if not Items[itemId] then return nil, "unknown_item" end
    local inv, reason = loadedPlayer(playerId)
    if not inv then return nil, reason end
    local account, aw = Accounts.vehicle(plate, part)
    if not account then return nil, aw end
    opts = type(opts) == "table" and opts or {}
    local allowed, deny, dinfo = authorize("veh", { playerId = inv.id, subject = inv.account, account = account,
        plate = Accounts.plate(plate), part = part, action = action, item = itemId, count = n }, true)
    if not allowed then return nil, deny, dinfo end
    -- A part that was never opened (openVehicle) has no row: the coordinator's lazy read answers
    -- unknown_account and creates nothing.
    local view, vreason = Facade:load(account)
    if not view then return nil, vreason == "unknown_account" and "vehicle_not_tracked" or vreason end
    if not view.committed.exists then return nil, "vehicle_not_tracked" end
    local fromView, to, capacityReason = inv.view, account, { [account] = "stash_full" }
    if action == "take" then fromView, to, capacityReason = view, inv.account, { [inv.account] = "too_heavy" } end
    local lines, preason = Facade:planMove(fromView, to, itemId, n, opts.meta, opts.instances)
    if not lines then return nil, preason end
    local receipt, r2, info = Facade:transact({ kind = "inv.veh_" .. action, actor = inv.account, opId = opts.opId,
        lines = lines, capacityReason = capacityReason })
    if not receipt then return nil, r2, info end
    log("player %d %s %s x%d %s %s (op %s)", inv.id, action, itemId, n, action == "take" and "from" or "into",
        account, tostring(receipt.opId))
    return receipt
end
-- vehicleStoreAsync / vehicleTakeAsync(playerId, plate, part, itemId, count, opts?)
-- Fail closed: refused with not_authorized unless the `veh` authorizer (A9: keys, owner,
-- mechanic, police) answers true for this player, vehicle part and action.
exports("vehicleStoreAsync", function(playerId, plate, part, itemId, count, opts)
    return vehicleMove("store", playerId, plate, part, itemId, count, opts)
end)
exports("vehicleTakeAsync", function(playerId, plate, part, itemId, count, opts)
    return vehicleMove("take", playerId, plate, part, itemId, count, opts)
end)

-- createWorld(capacityKg, opts?) -> { account, worldId } | nil, reason
-- A new, empty world:<id> container (a crate, a pile), minted by the coordinator (openWorld): its
-- id is never chosen by a caller (opts.worldId is refused, invalid_world_id). opts.meta (<= 2 KiB,
-- what the projection is rebuilt from) and opts.expiresAt (ms) are stored with it and listed by
-- open77_transactions:listWorld. Its prop and prompt are the projection owner's (A6); this
-- inventory only holds what is inside.
exports("createWorld", function(capacityKg, opts)
    local ok, why = requireTx()
    if not ok then return nil, why end
    local cap = tonumber(capacityKg)
    if not cap or cap <= 0 or cap > 100000 then return nil, "invalid_capacity" end
    opts = type(opts) == "table" and opts or {}
    if opts.worldId ~= nil then return nil, "invalid_world_id", { detail = "minted_by_coordinator" } end
    local view, vreason = Facade:openWorld({ capacityG = math.floor(cap * 1000 + 0.5), meta = opts.meta,
        expiresAt = opts.expiresAt })
    if not view then return nil, vreason end
    return { account = view.account, worldId = view.account:sub(7) }
end)

local function worldMove(action, playerId, worldId, itemId, count, opts)
    local ok, why = requireTx()
    if not ok then return nil, why end
    local n = countArg(count)
    if not n then return nil, "invalid_count" end
    if not Items[itemId] then return nil, "unknown_item" end
    local inv, reason = loadedPlayer(playerId)
    if not inv then return nil, reason end
    local account, aw = Accounts.world(worldId)
    if not account then return nil, aw end
    opts = type(opts) == "table" and opts or {}
    local allowed, deny, dinfo = authorize("world", { playerId = inv.id, subject = inv.account, account = account,
        worldId = worldId, action = action, item = itemId, count = n }, false)
    if not allowed then return nil, deny, dinfo end
    local view, vreason = Facade:load(account)
    if not view then return nil, vreason == "unknown_account" and "unknown_container" or vreason end
    if not view.committed.exists then return nil, "unknown_container" end
    local fromView, to, capacityReason = inv.view, account, { [account] = "stash_full" }
    if action == "take" then fromView, to, capacityReason = view, inv.account, { [inv.account] = "too_heavy" } end
    local lines, preason = Facade:planMove(fromView, to, itemId, n, opts.meta, opts.instances)
    if not lines then return nil, preason end
    local receipt, r2, info = Facade:transact({ kind = "inv.world_" .. action, actor = inv.account, opId = opts.opId,
        lines = lines, capacityReason = capacityReason })
    if not receipt then return nil, r2, info end
    return receipt
end
-- worldPutAsync / worldTakeAsync(playerId, worldId, itemId, count, opts?): pockets <-> world:<id>.
-- Concurrent takes have one winner (the coordinator holds the units of the first).
exports("worldPutAsync", function(playerId, worldId, itemId, count, opts)
    return worldMove("put", playerId, worldId, itemId, count, opts)
end)
exports("worldTakeAsync", function(playerId, worldId, itemId, count, opts)
    return worldMove("take", playerId, worldId, itemId, count, opts)
end)

-- wearAsync(playerId, itemId, amount, opts?) -> { receipt, instance, durability, broken } | nil, reason
-- Wears the most worn unit (or opts.instance) of a durability item: a compare-and-set update
-- of its metadata, or its destruction at zero (durability.breaks, default true).
exports("wearAsync", function(playerId, itemId, amount, opts)
    local ok, why = requireTx()
    if not ok then return nil, why end
    local inv, reason = loadedPlayer(playerId)
    if not inv then return nil, reason end
    local n = math.tointeger(tonumber(amount) or 1)
    if not n or n < 1 or n > 1000000 then return nil, "invalid_amount" end
    opts = type(opts) == "table" and opts or {}
    local lines, iid, left, broken = Facade:planWear(inv.view, itemId, n, opts.instance)
    if not lines then return nil, iid end
    local receipt, r2, info = Facade:transact({ kind = "inv.wear", actor = inv.account, opId = opts.opId, lines = lines })
    if not receipt then return nil, r2, info end
    return { receipt = receipt, instance = iid, durability = left, broken = broken }
end)

-- addAsync(playerId, itemId, count, meta?, opts?) / removeAsync(playerId, itemId, count, opts?)
-- Durable credit / debit with a receipt and an explicit capacity refusal (C1: a salvage credit
-- the job can rely on). The sys: account is the calling resource.
exports("addAsync", function(playerId, itemId, count, meta, opts)
    local ok, why = requireTx()
    if not ok then return nil, why end
    local n = countArg(count)
    if not n then return nil, "invalid_count" end
    local inv, reason = loadedPlayer(playerId)
    if not inv then return nil, reason end
    opts = type(opts) == "table" and opts or {}
    local lines, lwhy = Facade:createLines(itemId, n, meta, sysOf(GetInvokingResource()), inv.account)
    if not lines then return nil, lwhy end
    return Facade:transact({ kind = "inv.add", actor = inv.account, opId = opts.opId, lines = lines,
        capacityReason = { [inv.account] = "too_heavy" } })
end)
exports("removeAsync", function(playerId, itemId, count, opts)
    local ok, why = requireTx()
    if not ok then return nil, why end
    local n = countArg(count)
    if not n then return nil, "invalid_count" end
    local inv, reason = loadedPlayer(playerId)
    if not inv then return nil, reason end
    opts = type(opts) == "table" and opts or {}
    local lines, lwhy = Facade:planMove(inv.view, sysOf(GetInvokingResource()), itemId, n, opts.meta, opts.instances)
    if not lines then return nil, lwhy end
    return Facade:transact({ kind = "inv.remove", actor = inv.account, opId = opts.opId, lines = lines })
end)

-- moveAsync(moves, opts?) -> receipt | nil, reason, info
-- Server-to-server: moves = { { item, count, meta?, from, to } | { instance, from, to }... } with
-- explicit durable accounts (char:/stash:/veh:/world:/sys:). No player authorization: the
-- calling resource owns its rules; the journal names it in `kind`.
exports("moveAsync", function(moves, opts)
    local ok, why = requireTx()
    if not ok then return nil, why end
    if type(moves) ~= "table" or #moves == 0 or #moves > 24 then return nil, "invalid_spec" end
    opts = type(opts) == "table" and opts or {}
    local capacityG = math.floor(Config.maxCarryWeight * 1000 + 0.5)
    local lines = {}
    for _, m in ipairs(moves) do
        if type(m) ~= "table" then return nil, "invalid_spec" end
        local from, fwhy = Accounts.parse(m.from)
        if not from then return nil, fwhy end
        local to, twhy = Accounts.parse(m.to)
        if not to then return nil, twhy end
        for _, a in ipairs({ from, to }) do
            -- An offline character's pockets can be credited: open them at the carry capacity.
            if Accounts.kindOf(a) == "char" and not Facade:view(a) then
                local view, lwhy = Facade:load(a, capacityG)
                if not view then return nil, lwhy end
            end
        end
        if m.instance then
            lines[#lines + 1] = { instance = m.instance, from = from, to = to }
        else
            local n = countArg(m.count)
            if not n or not Items[m.item] then return nil, "invalid_spec" end
            local part, pwhy
            if Accounts.kindOf(from) == "sys" then
                part, pwhy = Facade:createLines(m.item, n, m.meta, from, to)
            else
                local view, vwhy = Facade:view(from), nil
                if not view then view, vwhy = Facade:load(from) end
                if not view then return nil, vwhy end
                part, pwhy = Facade:planMove(view, to, m.item, n, m.meta)
            end
            if not part then return nil, pwhy end
            for _, l in ipairs(part) do lines[#lines + 1] = l end
        end
    end
    local caller = GetInvokingResource() or "unknown"
    return Facade:transact({ kind = ("mv:" .. caller):sub(1, 32), actor = opts.actor, opId = opts.opId, lines = lines })
end)

-- read(account) -> { account, items = { [itemId] = n }, stacks, instances, weightKg, capacityKg, exists }
exports("read", function(account)
    local ok, why = requireTx()
    if not ok then return nil, why end
    local view, reason = Facade:view(account), nil
    if not view then view, reason = Facade:load(account) end
    if not view and reason == "unknown_account" then
        -- Never opened: the coordinator's read creates nothing; the answer keeps its shape.
        return { account = account, items = {}, stacks = {}, instances = {}, weightKg = 0, capacityKg = 0,
            exists = false }
    end
    if not view then return nil, reason end
    local stacks, instances = Facade:effective(view)
    return {
        account = account, items = Facade:counts(view), stacks = stacks, instances = Schema.copy(instances),
        weightKg = Facade:weightG(view) / 1000, capacityKg = view.capacityG / 1000, exists = view.committed.exists,
    }
end)

-- status(opId) -> { state, receipt? } | nil, reason: after an in_doubt answer.
exports("status", function(opId)
    local ok, why = requireTx()
    if not ok then return nil, why end
    return txCall("status", opId, { resolve = true })
end)

---------------------------------------------------------------------------
-- Client catalogue (B1): bounded pages on request, never one large state bag.
-- Server -> client: rp_inventory:catalogue(head) on join and after definitions change.
-- Client -> server: rp_inventory:catalogueRequest(version, page) -> rp_inventory:cataloguePage.
---------------------------------------------------------------------------

local catalogueBroadcastPending = false
scheduleCatalogue = function()
    if catalogueBroadcastPending then return end
    catalogueBroadcastPending = true
    SetTimeout(1000, function()
        catalogueBroadcastPending = false
        TriggerClientEvent("rp_inventory:catalogue", -1, (Registry:catalogue()))
    end)
end

local catalogueQuota = {} -- [playerId] = { version, served, windowStart, inWindow }

RegisterNetEvent("rp_inventory:catalogueRequest", function(version, page)
    local playerId = source
    if type(playerId) ~= "number" or playerId <= 0 then return end
    local head, pages = Registry:catalogue()
    if version ~= head.version then
        TriggerClientEvent("rp_inventory:catalogue", playerId, head)
        return
    end
    local index = math.tointeger(tonumber(page))
    if not index or index < 1 or index > head.pages then return end
    local now = Open77.time.monotonic()
    local q = catalogueQuota[playerId]
    if not q or q.version ~= head.version then
        q = { version = head.version, served = 0, windowStart = now, inWindow = 0 }
        catalogueQuota[playerId] = q
    end
    if now - q.windowStart >= 10 then q.windowStart, q.inWindow = now, 0 end
    -- Bounded: every page about twice per version, at most 20 pages per 10 s per player.
    if q.served >= head.pages * 2 + 4 or q.inWindow >= 20 then return end
    q.served, q.inWindow = q.served + 1, q.inWindow + 1
    TriggerClientEvent("rp_inventory:cataloguePage", playerId, pages[index])
end)

---------------------------------------------------------------------------
-- Commands
---------------------------------------------------------------------------

local function fromGame(source)
    if source == 0 then
        print("[rp_inventory] run this from the game, not the console")
        return false
    end
    return true
end

RegisterCommand("inv", function(source)
    if not fromGame(source) then return end
    openPanel(source)
end, false)

RegisterCommand("use", function(source, args)
    if not fromGame(source) then return end
    local itemId = findItem(args[1])
    if not itemId then return tell(source, "Usage: /use <item>. " .. explain("unknown_item")) end
    local ok, reason = useItem(source, itemId)
    if not ok and reason ~= "cancelled" then tell(source, explain(reason)) end
end, false)

RegisterCommand("drop", function(source, args)
    if not fromGame(source) then return end
    local itemId = findItem(args[1])
    if not itemId then return tell(source, "Usage: /drop <item> [count]. " .. explain("unknown_item")) end
    local n = math.floor(tonumber(args[2]) or 1)
    local ok, reason = dropItems(source, itemId, n)
    if ok then
        tell(source, ("Dropped %s x%d at your feet. The prompt or /ramasser picks it up."):format(Items[itemId].label, n))
    else
        tell(source, explain(reason))
    end
end, false)

RegisterCommand("ramasser", function(source)
    if not fromGame(source) then return end
    local ok, reason = pickUpNearest(source)
    if not ok then
        if reason == "nothing_nearby" then tell(source, "Nothing dropped within reach.")
        elseif reason == "already_taken" then tell(source, "Someone was faster.")
        else tell(source, explain(reason)) end
    end
end, false)

RegisterCommand("give", function(source, args)
    if not fromGame(source) then return end
    local target = tonumber(args[1])
    local itemId = findItem(args[2])
    if not target or not itemId then
        return tell(source, "Usage: /give <playerId> <item> [count]  (or ALT+click a player > Give item)")
    end
    local n = math.floor(tonumber(args[3]) or 1)
    local ok, reason = giveItems(source, target, itemId, n)
    if not ok then tell(source, explain(reason)) end
end, false)

RegisterCommand("fouiller", function(source, args)
    if not fromGame(source) then return end
    local target = tonumber(args[1])
    if not target then return tell(source, "Usage: /fouiller <playerId>") end
    local ok, reason = searchPlayer(source, target)
    if not ok then tell(source, explain(reason)) end
end, false)

RegisterCommand("saisir", function(source, args)
    if not fromGame(source) then return end
    local target = tonumber(args[1])
    local itemId = findItem(args[2])
    if not target or not itemId then return tell(source, "Usage: /saisir <playerId> <item>") end
    local ok, reason = seizeItem(source, target, itemId)
    if not ok then tell(source, explain(reason)) end
end, false)

-- Admin / console: put items in somebody's pockets. ACL: command.giveitem.
RegisterCommand("giveitem", function(source, args)
    local target = tonumber(args[1])
    local itemId = findItem(args[2])
    local n = math.floor(tonumber(args[3]) or 1)
    if not target or not itemId then return tell(source, "Usage: /giveitem <playerId> <item> [count]") end
    local ok, reason = creditPlayer(target, itemId, n, ("(giveitem by %d)"):format(source), nil, "sys:admin")
    if not ok then return tell(source, explain(reason)) end
    tell(source, ("Gave %s x%d to player %d."):format(Items[itemId].label, n, target))
    if target ~= source then tell(target, ("%s x%d appeared in your pockets."):format(Items[itemId].label, n)) end
end, true)

-- Admin / console: the one-shot legacy import (transactions backend). ACL: command.invmigrate.
--   invmigrate status               backend, coordinator readiness, write-behind counters
--   invmigrate all                  import every legacy subject not imported yet
--   invmigrate char <identifier>    import one character's pockets
--   invmigrate stash <stashId>      import one stash
--   invmigrate accept char|stash <key>   after legacy_diverged: keep the imported state
RegisterCommand("invmigrate", function(source, args)
    local function say(text) tell(source, "[invmigrate] " .. text) end
    if not TX then return say("the legacy backend is active: nothing to import (convar rp_inventory_backend)") end
    local verb = args[1] or "status"
    if verb == "status" then
        local st = Facade.stats
        return say(("backend %s, coordinator %s, submitted %d, committed %d, retried %d, in doubt %d, LOST %d"):format(
            BACKEND, Facade:isReady() and "ready" or "UNAVAILABLE", st.submitted, st.committed, st.retried, st.inDoubt, st.lost))
    end
    if not waitForDatabase(10000) then return say("no database: nothing to import") end
    local capacityOf = {
        char = math.floor(Config.maxCarryWeight * 1000 + 0.5),
        stash = math.floor(Config.defaultStashCapacity * 1000 + 0.5),
    }
    local function one(kind, key)
        local account, why
        if kind == "char" then account, why = Accounts.char(key) else account, why = Accounts.stash(key) end
        if not account then return nil, why end
        return Migration:ensure(account, kind, key, capacityOf[kind])
    end
    if verb == "all" then
        local done, failed = 0, 0
        local visited, reason = Migration:eachLegacySubject(function(kind, key)
            local result, why = one(kind, key)
            if result then done = done + 1 else
                failed = failed + 1
                say(("%s %s: %s"):format(kind, key, tostring(why)))
            end
        end)
        if not visited then return say("refused: " .. tostring(reason)) end
        return say(("%d subject(s) visited, %d ok, %d refused"):format(visited, done, failed))
    end
    if verb == "char" or verb == "stash" then
        local result, why, info = one(verb, args[2])
        if not result then return say(("refused: %s %s"):format(tostring(why), info and Schema.encode(info) or "")) end
        return say(("%s: %s %s"):format(tostring(args[2]), result.state, result.report and Schema.encode(result.report) or ""))
    end
    if verb == "accept" and (args[2] == "char" or args[2] == "stash") then
        local account, why
        if args[2] == "char" then account, why = Accounts.char(args[3]) else account, why = Accounts.stash(args[3]) end
        if not account then return say("refused: " .. tostring(why)) end
        local ok, aw = Migration:accept(account, args[2], args[3])
        return say(ok and (account .. ": the imported state is kept") or ("refused: " .. tostring(aw)))
    end
    say("usage: invmigrate status | all | char <identifier> | stash <stashId> | accept char|stash <key>")
end, true)

---------------------------------------------------------------------------
-- Client requests (context menu actions)
---------------------------------------------------------------------------

RegisterNetEvent("rp_inventory:giveMenu", function(targetId)
    if type(source) ~= "number" or source <= 0 then return end
    giveDialog(source, targetId)
end)

RegisterNetEvent("rp_inventory:search", function(targetId)
    if type(source) ~= "number" or source <= 0 then return end
    local ok, reason = searchPlayer(source, targetId)
    if not ok then tell(source, explain(reason)) end
end)

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

local SUGGESTIONS = {
    { command = "/inv", help = "Open your pockets" },
    { command = "/use", help = "Use an item", parameters = { { name = "item", help = "Item id or name" } } },
    { command = "/drop", help = "Drop an item on the ground", parameters = {
        { name = "item", help = "Item id or name" }, { name = "count", help = "How many (default 1)" } } },
    { command = "/ramasser", help = "Pick up the nearest dropped item" },
    { command = "/give", help = "Give an item to a player (or ALT+click them)", parameters = {
        { name = "playerId", help = "Their id" }, { name = "item", help = "Item id or name" },
        { name = "count", help = "How many (default 1)" } } },
    { command = "/fouiller", help = "Search a cuffed or surrendering player", parameters = {
        { name = "playerId", help = "Their id" } } },
    { command = "/saisir", help = "Seize an illegal item from a searched player", parameters = {
        { name = "playerId", help = "Their id" }, { name = "item", help = "Item id or name" } } },
    { command = "/giveitem", help = "(admin) Put items in a player's pockets", parameters = {
        { name = "playerId", help = "Their id" }, { name = "item", help = "Item id or name" },
        { name = "count", help = "How many" } } },
}

local readyOk, readyReason = Open77.database.ready(function()
    if TX then
        -- Transactions backend: the coordinator owns the item rows; this resource only keeps its
        -- per-subject import markers and reads the legacy tables once per subject.
        local ok, why = Migration:ensureTable()
        if not ok then
            dbFailReason = why
            log("database answered ready but rp_inventory_migrations could not be ensured (%s): "
                .. "subjects with legacy rows will not load", tostring(why))
            return
        end
        dbReady = true
        log("database ready: rp_inventory_migrations ensured (transactions backend)")
        return
    end
    local _, e1, a1 = dbAwait(Open77.database.update, [[
        CREATE TABLE IF NOT EXISTS rp_inventory_items (
            identifier VARCHAR(64) NOT NULL,
            item_id VARCHAR(32) NOT NULL,
            count INT NOT NULL DEFAULT 0,
            PRIMARY KEY (identifier, item_id)
        )
    ]])
    local _, e2, a2 = dbAwait(Open77.database.update, [[
        CREATE TABLE IF NOT EXISTS rp_inventory_stashes (
            stash_id VARCHAR(64) NOT NULL,
            item_id VARCHAR(32) NOT NULL,
            count INT NOT NULL DEFAULT 0,
            PRIMARY KEY (stash_id, item_id)
        )
    ]])
    if not a1 or not a2 then
        dbFailReason = e1 or e2 or "schema_failed"
        log("database answered ready but the schema could not be ensured (%s): persistence falls back to Open77.kvp",
            tostring(dbFailReason))
        return
    end
    dbReady = true
    log("database ready: rp_inventory_items and rp_inventory_stashes ensured")
end)
if not readyOk then
    dbFailReason = readyReason
    if TX then
        log("database not available (%s): no legacy import; pockets live in open77_transactions only", tostring(readyReason))
    else
        log("database not available (%s): persistence falls back to Open77.kvp", tostring(readyReason))
    end
end
for id, why in pairs(builtinRejected) do
    log("built-in item %s rejected by the B1 schema: %s", tostring(id), tostring(why))
end

AddEventHandler("onResourceStart", function(name)
    if TX and name == "open77_transactions" then
        -- A restarted coordinator lost its definitions and its opId counter: shake hands again.
        Facade:lost("open77_transactions restarted")
        return
    end
    if name ~= RESOURCE then return end
    Open77.chat.addSuggestions(-1, SUGGESTIONS)
    log("backend: %s, %d item definition(s), catalogue v%d", BACKEND, Registry.count, Registry.version)
    if TX then Facade:start() end
    -- Hot reload: players already in the city need their pockets back.
    for _, id in ipairs(Open77.players.all() or {}) do
        local playerId = tonumber(id)
        if playerId and not inventories[playerId] then
            CreateThread(function() loadPlayer(playerId) end)
        end
    end
    log("started")
end)

RegisterNetEvent("chat:ready", function()
    if type(source) == "number" and source > 0 then
        Open77.chat.addSuggestions(source, SUGGESTIONS)
    end
end)

AddEventHandler("onPlayerReady", function(playerId)
    playerId = tonumber(playerId)
    if not playerId or playerId < 1 then return end
    TriggerClientEvent("rp_inventory:catalogue", playerId, (Registry:catalogue()))
    if inventories[playerId] and inventories[playerId].loaded then return end
    loadPlayer(playerId)
end)

AddEventHandler("onResourceStop", function(name)
    if name ~= RESOURCE then
        if TX and name == "open77_transactions" then Facade:lost("open77_transactions stopped") end
        for scope, auth in pairs(authorizers) do
            if auth.resource == name then
                authorizers[scope] = nil
                log("authorizer for %s removed: %s stopped", scope, name)
            end
        end
        return
    end
    for id in pairs(panels) do
        TriggerClientEvent("rp_inventory:panel", id, { open = false })
    end
    panels = {}
    panelPending = {}
    if TX then
        local unsent = 0
        for _, view in pairs(Facade.views) do unsent = unsent + #view.queue end
        if unsent > 0 then
            log("stopping with %d write-behind operation(s) not acknowledged: they may be lost", unsent)
        end
    end
end)

-- Another resource committed an operation on open77_transactions (A13 7.2 event): reload the
-- containers this inventory shows. Payload: (opId, kind, accounts).
AddEventHandler("open77_transactions:committed", function(opId, kind, accounts)
    if not TX or type(opId) ~= "string" then return end
    Facade:onCommitted(opId, accounts)
end)

AddEventHandler("onPlayerDisconnected", function(playerId)
    playerId = tonumber(playerId)
    if not playerId then return end
    panels[playerId] = nil
    panelPending[playerId] = nil
    panelOps[playerId] = nil      -- in-doubt watchers stop; the facade still settles the operation
    panelBusy[playerId] = nil
    catalogueQuota[playerId] = nil
    local inv = inventories[playerId]
    if inv then
        inventories[playerId] = nil
        if inv.account then
            local sessions = charPlayers[inv.account]
            if sessions then
                sessions[playerId] = nil
                if next(sessions) == nil then
                    charPlayers[inv.account] = nil
                    Facade:release(inv.account)
                end
            end
            log("player %d inventory unloaded (%s; pending writes keep going)", playerId, inv.account)
        else
            log("player %d inventory unloaded (every change was already persisted)", playerId)
        end
    end
end)
