-- rp_netrunner / server/ports.lua: every call this resource makes to another resource (other than
-- the coordinator, which is server/ledger.lua) and every native, in one table the service and the
-- quickhacks use. Adapters are reached only through their PUBLIC exports (rp_jobs, rp_inventory,
-- rp_economy, rp_ncpd) and the libraries through theirs (open77_actions, open77_uikit).
--
-- Synchronous exports are pcall'd: a stopped resource raises at the call. Asynchronous ones use the
-- promise form and yield; their export-layer rejections are passed through as reasons.
--
-- Global: NetrunnerPorts.

-- Every action shows this resource's own words when it is refused or stops (open77_actions
-- `messages`), never a raw reason code. An older open77_actions ignores the field.
local function withMessages(def)
    local text = type(NetrunnerModel) == "table" and NetrunnerModel.TEXT
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

NetrunnerPorts = {}
local P = NetrunnerPorts

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
-- open77_actions: actions, targets, claims. All synchronous.
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
    cancel = function(opId, reason) return sync(ACTIONS, "cancel", opId, reason) end,
}

-- ---------------------------------------------------------------------------------------------
-- rp_jobs: synchronous, never yield.
-- ---------------------------------------------------------------------------------------------
P.jobs = {
    eligible = function(pid, requirement) return sync("rp_jobs", "eligible", pid, requirement) end,
    workEpoch = function(pid) return sync("rp_jobs", "workEpoch", pid) end,
    setDuty = function(pid, on, requirement) return sync("rp_jobs", "setDuty", pid, on, requirement) end,
    setJob = function(pid, job, grade) return sync("rp_jobs", "setJob", pid, job, grade) end,
    summary = function(pid) return sync("rp_jobs", "summary", pid) end,
    listOnDuty = function(job)
        local list = sync("rp_jobs", "listOnDuty", job)
        return type(list) == "table" and list or {}
    end,
}

-- ---------------------------------------------------------------------------------------------
-- rp_inventory: definitions (sync), console gifts (async).
-- ---------------------------------------------------------------------------------------------
P.inventory = {
    define = function(items) return sync("rp_inventory", "define", items) end,
    backend = function() return sync("rp_inventory", "backend") end,
    addAsync = function(pid, item, count, meta, opts) return async("rp_inventory", "addAsync", pid, item, count, meta, opts) end,
}

-- ---------------------------------------------------------------------------------------------
-- rp_economy: the atomic sale (delivery), the deck fee and its refund, balances. All yield.
-- ---------------------------------------------------------------------------------------------
P.economy = {
    sale = function(spec) return async("rp_economy", "sale", spec) end,
    charge = function(spec) return async("rp_economy", "charge", spec) end,
    refund = function(spec) return async("rp_economy", "refund", spec) end,
    status = function(opId) return async("rp_economy", "status", opId) end,
    balanceOf = function(party) return async("rp_economy", "balanceOf", party) end,
}

-- ---------------------------------------------------------------------------------------------
-- rp_ncpd: the record entry of a trace (synchronous). The dispatch is the rp_ncpd:alert event.
-- ---------------------------------------------------------------------------------------------
P.ncpd = {
    addRecord = function(pid, kind, text, by) return sync("rp_ncpd", "addRecord", pid, kind, text, by) end,
}

-- ---------------------------------------------------------------------------------------------
-- open77_uikit server twins (the contract board). They wait on the player: they yield.
-- ---------------------------------------------------------------------------------------------
P.uikit = {
    context = function(pid, definition, options) return async("open77_uikit", "context", pid, definition, options) end,
    alert = function(pid, definition) return async("open77_uikit", "alert", pid, definition) end,
    input = function(pid, definition) return async("open77_uikit", "input", pid, definition) end,
}

-- ---------------------------------------------------------------------------------------------
-- Natives (wiki/data/api.json)
-- ---------------------------------------------------------------------------------------------
P.now = function() return math.floor(Open77.time.unix() * 1000) end          -- ms
P.nowS = function() return math.floor(Open77.time.unix()) end                -- unix seconds
P.monotonic = function() return Open77.time.monotonic() end                   -- seconds
P.spawn = function(fn) CreateThread(fn) end
P.wait = function(ms) Wait(ms) end
P.log = function(line) print("[rp_netrunner] " .. line) end
P.warn = function(line)
    if Open77.log and Open77.log.warn then Open77.log.warn("[rp_netrunner] " .. line) else print("[rp_netrunner] " .. line) end
end
P.emit = function(name, ...) TriggerEvent(name, ...) end
P.toClient = function(name, pid, ...) TriggerClientEvent(name, pid, ...) end

P.players = {
    position = function(pid) return Open77.players.position(pid) end,     -- no permission
    get = function(pid)
        local ok, read = pcall(Open77.players.get, pid)
        if ok and type(read) == "table" then return read end
        return nil
    end,
    name = function(pid) return Open77.players.name(pid) end,
    identifier = function(pid) return Open77.players.identifier(pid) end,
    all = function() return Open77.players.all() or {} end,
    isDead = function(pid)                                                -- players.life.read
        local ok, dead = pcall(Open77.players.isDead, pid)
        return ok and dead == true
    end,
    distance = function(pid, other)
        local ok, metres, why = pcall(Open77.players.distance, pid, other)
        if not ok then return nil, tostring(metres) end
        return metres, why
    end,
    -- players.wanted / players.wanted.read: the native NCPD heat of one player's game
    getWanted = function(pid)
        local ok, policy, why = pcall(Open77.players.getWanted, pid)
        if not ok then return nil, "prevention_unavailable" end
        return policy, why
    end,
    setWanted = function(pid, level)
        local ok, res, why = pcall(Open77.players.setWanted, pid, level)
        if not ok then return nil, "prevention_unavailable" end
        return res, why
    end,
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

-- The platform's hacking kit and the implant framework (quickhacks).
P.hacking = {
    define = function(def)
        local ok, res, why = pcall(Open77.hacking.define, def)
        if not ok then return nil, "hacking_unavailable" end
        return res, why
    end,
    start = function(actor, target, definition, grade, options)
        local ok, res, why = pcall(Open77.hacking.start, actor, target, definition, grade, options)
        if not ok then return nil, "hacking_unavailable" end
        return res, why
    end,
    state = function(pid)
        local ok, res = pcall(Open77.hacking.state, pid)
        if ok and type(res) == "table" then return res end
        return nil
    end,
}
P.cyberware = {
    define = function(def)
        local ok, res, why = pcall(Open77.cyberware.define, def)
        if not ok then return nil, "cyberware_unavailable" end
        return res, why
    end,
    current = function(pid)
        local ok, res, why = pcall(Open77.cyberware.current, pid)
        if not ok then return nil, "cyberware_unavailable" end
        return res, why
    end,
    install = function(pid, definition, grade, options)
        local ok, res, why = pcall(Open77.cyberware.install, pid, definition, grade, options)
        if not ok then return nil, "cyberware_unavailable" end
        return res, why
    end,
    newOperationId = function()
        local ok, res, why = pcall(Open77.cyberware.newOperationId)
        if not ok then return nil, "cyberware_unavailable" end
        return res, why
    end,
}

-- One chat line (always) and a toast (network.events; drawn by open77_notifications).
P.tell = function(pid, text, kind, color)
    pcall(Open77.chat.send, pid, { type = "system", author = "NET", text = text, color = color or { 0, 229, 255 } })
    if Open77.notifications and Open77.notifications.send then
        pcall(Open77.notifications.send, pid, { type = kind or "info", title = "Netrunner", message = text,
            durationMs = 6000 })
    end
end

-- A chat line only (status listings, static on the NCPD radio).
P.say = function(pid, text, color, author)
    pcall(Open77.chat.send, pid, { type = "system", author = author or "NET", text = text, color = color or { 0, 229, 255 } })
end

return P
