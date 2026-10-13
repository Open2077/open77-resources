-- rp_streetfood / server/ports.lua: every call this resource makes to another resource (other than
-- the coordinator, which is server/ledger.lua) and every native, in one table the service uses.
-- Adapters are reached only through their PUBLIC exports (rp_jobs, rp_inventory, rp_economy,
-- rp_needs) and the libraries through theirs (open77_actions, open77_furniture).
--
-- Synchronous exports are pcall'd: a stopped resource raises at the call. Asynchronous ones use the
-- promise form and yield; their export-layer rejections are passed through as reasons.
--
-- Global: StreetfoodPorts.

-- Every action shows this resource's own words when it is refused or stops (open77_actions
-- `messages`), never a raw reason code. An older open77_actions ignores the field.
local function withMessages(def)
    local text = type(StreetfoodModel) == "table" and StreetfoodModel.TEXT
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

StreetfoodPorts = {}
local P = StreetfoodPorts

local function sync(resource, name, ...)
    local r = table.pack(pcall(Open77.exports.callSync, resource, name, ...))
    if not r[1] then return nil, resource .. "_unavailable", { detail = tostring(r[2]) } end
    return table.unpack(r, 2, r.n)
end

local function async(resource, name, ...)
    local promise, why = Open77.exports.call(resource, name, ...)
    if not promise then return nil, resource .. "_unavailable", { detail = tostring(why) } end
    return promise:await()
end

P.sync, P.async = sync, async

function P.running(resource) return GetResourceState(resource) == "running" end

-- ---------------------------------------------------------------------------------------------
-- open77_actions (B5): actions, targets, claims. All synchronous.
-- ---------------------------------------------------------------------------------------------
local ACTIONS = "open77_actions"
P.actions = {
    define = function(def) return sync(ACTIONS, "define", withMessages(def)) end,
    undefine = function(id) return sync(ACTIONS, "undefine", id) end,
    target = function(def) return sync(ACTIONS, "target", def) end,
    untarget = function(id) return sync(ACTIONS, "untarget", id) end,
    request = function(pid, action, target, options) return sync(ACTIONS, "request", pid, action, target, options) end,
    verify = function(opId, phase) return sync(ACTIONS, "verify", opId, phase) end,
    current = function(pid) return sync(ACTIONS, "current", pid) end,
}

-- ---------------------------------------------------------------------------------------------
-- rp_jobs (B4): synchronous, never yield.
-- ---------------------------------------------------------------------------------------------
P.jobs = {
    eligible = function(pid, requirement) return sync("rp_jobs", "eligible", pid, requirement) end,
    workEpoch = function(pid) return sync("rp_jobs", "workEpoch", pid) end,
    setDuty = function(pid, on, requirement) return sync("rp_jobs", "setDuty", pid, on, requirement) end,
    setJob = function(pid, job, grade) return sync("rp_jobs", "setJob", pid, job, grade) end,
}

-- ---------------------------------------------------------------------------------------------
-- rp_inventory (B1/B2): definitions (sync), stocking from pockets and lab gifts (async).
-- ---------------------------------------------------------------------------------------------
P.inventory = {
    define = function(items) return sync("rp_inventory", "define", items) end,
    backend = function() return sync("rp_inventory", "backend") end,
    -- moves = { { item, count, from, to } } between explicit durable accounts: ONE operation
    moveAsync = function(moves, opts) return async("rp_inventory", "moveAsync", moves, opts) end,
    addAsync = function(pid, item, count, meta, opts) return async("rp_inventory", "addAsync", pid, item, count, meta, opts) end,
}

-- ---------------------------------------------------------------------------------------------
-- rp_economy (B3): the atomic sale, its status, balances. All yield.
-- ---------------------------------------------------------------------------------------------
P.economy = {
    sale = function(spec) return async("rp_economy", "sale", spec) end,
    status = function(opId) return async("rp_economy", "status", opId) end,
    balanceOf = function(party) return async("rp_economy", "balanceOf", party) end,
}

-- ---------------------------------------------------------------------------------------------
-- rp_needs (optional): apply(playerId, delta, label) -> true | nil, reason. Synchronous.
-- ---------------------------------------------------------------------------------------------
P.needs = {
    apply = function(pid, delta, label) return sync("rp_needs", "apply", pid, delta, label) end,
}

-- ---------------------------------------------------------------------------------------------
-- open77_furniture (A1, optional): a seat's pose by furniture id. Synchronous.
-- ---------------------------------------------------------------------------------------------
P.furniture = {
    get = function(id) return sync("open77_furniture", "get", id) end,
    status = function() return sync("open77_furniture", "status") end,
}

-- ---------------------------------------------------------------------------------------------
-- Natives (wiki/data/api.json)
-- ---------------------------------------------------------------------------------------------
P.now = function() return math.floor(Open77.time.unix() * 1000) end
P.spawn = function(fn) CreateThread(fn) end
P.log = function(line) print("[rp_streetfood] " .. line) end
P.warn = function(line)
    if Open77.log and Open77.log.warn then Open77.log.warn("[rp_streetfood] " .. line) else print("[rp_streetfood] " .. line) end
end
P.emit = function(name, ...) TriggerEvent(name, ...) end

P.players = {
    position = function(pid) return Open77.players.position(pid) end,     -- no permission
    get = function(pid)                                                    -- players.life.read
        local ok, read = pcall(Open77.players.get, pid)
        if ok and type(read) == "table" then return read end
        return nil
    end,
    name = function(pid) return Open77.players.name(pid) end,
    identifier = function(pid) return Open77.players.identifier(pid) end,
}

-- The consented hand-over (players.interactions.control / .read). Calls return directly.
P.interactions = {
    request = function(actor, target, kind, options)
        local ok, state, why = pcall(Open77.playerInteractions.request, actor, target, kind, options)
        if not ok then return nil, "interactions_unavailable", tostring(state) end
        return state, why
    end,
    cancel = function(id, reason)
        local ok, state, why = pcall(Open77.playerInteractions.cancel, id, reason)
        if not ok then return nil, "interactions_unavailable" end
        return state, why
    end,
    get = function(id)
        local ok, state, why = pcall(Open77.playerInteractions.get, id)
        if not ok then return nil, "interactions_unavailable" end
        return state, why
    end,
}

-- Resource-owned native hand items (world.props, players.life.read, network.events). A request id
-- answers acceptance, never a rendering proof.
P.held = {
    hold = function(pid, record)
        local ok, id, why = pcall(Open77.heldItems.hold, pid, record)
        if not ok then return nil, "held_items_unavailable" end
        return id, why
    end,
    release = function(pid)
        local ok, id, why = pcall(Open77.heldItems.release, pid)
        if not ok then return nil, "held_items_unavailable" end
        return id, why
    end,
}

-- One chat line (always) and a toast (network.events; drawn by open77_notifications).
P.tell = function(pid, text, kind)
    pcall(Open77.chat.send, pid, { author = "Street food", text = text, color = { 255, 170, 60 } })
    if Open77.notifications and Open77.notifications.send then
        pcall(Open77.notifications.send, pid, { type = kind or "info", title = "Street food",
            message = text, durationMs = 6000 })
    end
end

return P
