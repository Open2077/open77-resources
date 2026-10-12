-- rp_fixer / server/ports.lua: every call this resource makes to another resource (other than
-- the coordinator, server/ledger.lua) and every native, in one table the service uses.
--
-- Server-only resources (rp_economy, rp_jobs, rp_inventory) cannot be manifest dependencies of a
-- resource that ships a client script, so they are reached through their public exports with
-- pcall (synchronous) or the promise form (asynchronous); a stopped resource answers
-- `<resource>_unavailable`.
--
-- Global: FixerPorts.

-- Every action shows this resource's own words when it is refused or stops (open77_actions
-- `messages`), never a raw reason code. An older open77_actions ignores the field.
local function withMessages(def)
    local text = type(FixerModel) == "table" and FixerModel.TEXT
    if type(def) == "table" and def.messages == nil and type(text) == "table" then
        local messages, n = {}, 0
        for reason, line in pairs(text) do
            if n < 96 and type(reason) == "string" and reason:match("^[%w_:%.%-]+$") and #reason <= 64 and
                type(line) == "string" and #line >= 1 and #line <= 200 and not line:find("%c") then
                messages[reason], n = line, n + 1
            end
        end
        def.messages = messages
    end
    return def
end

FixerPorts = {}
local P = FixerPorts

local function sync(resource, name, ...)
    local r = table.pack(pcall(Open77.exports.callSync, resource, name, ...))
    if not r[1] then return nil, resource .. "_unavailable", { detail = tostring(r[2]) } end
    return table.unpack(r, 2, r.n)
end

local function async(resource, name, ...)
    local promise, why = Open77.exports.call(resource, name, ...)
    if not promise then return nil, resource .. "_unavailable", { detail = tostring(why), retryable = true } end
    local r = table.pack(promise:await())
    if r[1] == nil and type(r[2]) == "string" and r[2]:sub(1, 7) == "export_" then
        return nil, resource .. "_unavailable", { detail = r[2], retryable = true }
    end
    return table.unpack(r, 1, r.n)
end

P.sync, P.async = sync, async

function P.running(resource) return GetResourceState(resource) == "running" end

-- ---------------------------------------------------------------------------------------------
-- open77_actions: the board and hand-over prompt, the delivery crate. Synchronous.
-- ---------------------------------------------------------------------------------------------
local ACTIONS = "open77_actions"
P.actions = {
    define = function(def) return sync(ACTIONS, "define", withMessages(def)) end,
    target = function(def) return sync(ACTIONS, "target", def) end,
    untarget = function(id) return sync(ACTIONS, "untarget", id) end,
    verify = function(opId, phase) return sync(ACTIONS, "verify", opId, phase) end,
    carryDefine = function(def) return sync(ACTIONS, "carryDefine", withMessages(def)) end,
    carryPlace = function(kind, placement) return sync(ACTIONS, "carryPlace", kind, placement) end,
    carryRemove = function(itemId) return sync(ACTIONS, "carryRemove", itemId) end,
    carryGet = function(itemId) return sync(ACTIONS, "carryGet", itemId) end,
}

-- ---------------------------------------------------------------------------------------------
-- rp_jobs: is this player a fixer on duty? Synchronous, never yields.
-- ---------------------------------------------------------------------------------------------
P.jobs = {
    eligible = function(pid, requirement) return sync("rp_jobs", "eligible", pid, requirement) end,
}

-- ---------------------------------------------------------------------------------------------
-- rp_inventory: the label of an item a retrieval asks for (and whether it exists). Synchronous.
-- ---------------------------------------------------------------------------------------------
P.inventory = {
    itemDefinition = function(item) return sync("rp_inventory", "itemDefinition", item) end,
}

-- ---------------------------------------------------------------------------------------------
-- rp_economy: every eddy. Each call is ONE coordinator operation with our operation id, so a
-- retry with the same id replays the first receipt and never pays twice. All yield.
-- ---------------------------------------------------------------------------------------------
P.economy = {
    pay = function(spec) return async("rp_economy", "pay", spec) end,
    charge = function(spec) return async("rp_economy", "charge", spec) end,
    status = function(opId) return async("rp_economy", "status", opId) end,
    balanceOf = function(party) return async("rp_economy", "balanceOf", party) end,
}

-- ---------------------------------------------------------------------------------------------
-- open77_uikit server twins: the board, the dialogs. All yield; `nil, reason` when the question
-- never reached an answer, else { ok, outcome, value }.
-- ---------------------------------------------------------------------------------------------
P.ui = {
    context = function(pid, def) return async("open77_uikit", "context", pid, def) end,
    alert = function(pid, def) return async("open77_uikit", "alert", pid, def) end,
    input = function(pid, def) return async("open77_uikit", "input", pid, def) end,
}

-- ---------------------------------------------------------------------------------------------
-- Natives (wiki/data/api.json)
-- ---------------------------------------------------------------------------------------------
P.unix = function() return math.floor(Open77.time.unix()) end
P.now = function() return math.floor(Open77.time.unix() * 1000) end
P.wait = function(ms) Wait(ms) end
P.spawn = function(fn) CreateThread(fn) end
P.log = function(line) print("[rp_fixer] " .. line) end
P.warn = function(line)
    if Open77.log and Open77.log.warn then Open77.log.warn("[rp_fixer] " .. line) else print("[rp_fixer] " .. line) end
end
P.emit = function(name, ...) TriggerEvent(name, ...) end
P.toClient = function(pid, name, ...) TriggerClientEvent(name, pid, ...) end

P.players = {
    position = function(pid) return Open77.players.position(pid) end,
    positions = function()
        local ok, all = pcall(Open77.players.positions)
        return ok and type(all) == "table" and all or {}
    end,
    name = function(pid) return Open77.players.name(pid) end,
    -- The character's name (rp_identity) when it runs, else the platform name.
    rpName = function(pid)
        local full = sync("rp_identity", "fullName", pid)
        if type(full) == "string" and full ~= "" then return full end
        return Open77.players.name(pid)
    end,
    all = function() return Open77.players.all() or {} end,
}

P.npcs = {
    -- world.npcs
    create = function(def) return Open77.npcs.create(def) end,
    remove = function(id) return Open77.npcs.remove(id) end,
    get = function(id) return Open77.npcs.get(id) end,
    setAttitude = function(id, attitude, options) return Open77.npcs.setAttitude(id, attitude, options) end,
    guard = function(id, position, radius) return Open77.npcs.tasks.guard(id, position, radius, { speed = "run" }) end,
    attack = function(id, pid) return Open77.npcs.tasks.attack(id, pid, { reacquireMs = 4000 }) end,
    hold = function(id) return Open77.npcs.tasks.hold(id) end,
    mortal = function() return (Open77.npcs.damage and Open77.npcs.damage.mortal) or 0 end,
}

-- One chat line (always) and a toast (network.events; drawn by open77_notifications).
-- kind "chat": a line of a listing, chat only (a toast per line buried the HUD).
P.tell = function(pid, text, kind)
    pcall(Open77.chat.send, pid, { author = "FIXER", text = text, color = { 0, 229, 255 } })
    if kind ~= "chat" and Open77.notifications and Open77.notifications.send then
        pcall(Open77.notifications.send, pid, { type = kind or "info", title = "Fixer", message = text, durationMs = 6000 })
    end
end

P.suggest = function(pid, list)
    if Open77.chat and Open77.chat.addSuggestions then pcall(Open77.chat.addSuggestions, pid, list) end
end

return P
