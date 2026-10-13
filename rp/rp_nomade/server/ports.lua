-- rp_nomade / server/ports.lua: every call this resource makes to another resource (other than the
-- coordinator, which is server/ledger.lua) and every native, in one table the service uses.
-- Libraries and RP resources are reached only through their PUBLIC exports.
--
-- Synchronous exports are pcall'd: a stopped resource raises at the call. Asynchronous ones use
-- the promise form and yield; their export-layer rejections are passed through as reasons.
--
-- Global: NomadPorts.

-- Every action shows this resource's own words when it is refused or stops (open77_actions
-- `messages`), never a raw reason code. An older open77_actions ignores the field.
local function withMessages(def)
    local text = type(NomadModel) == "table" and NomadModel.TEXT
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

NomadPorts = {}
local P = NomadPorts

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
-- open77_actions: actions, targets, carry. All synchronous.
-- ---------------------------------------------------------------------------------------------
local ACTIONS = "open77_actions"
P.actions = {
    define = function(def) return sync(ACTIONS, "define", withMessages(def)) end,
    target = function(def) return sync(ACTIONS, "target", def) end,
    untarget = function(id) return sync(ACTIONS, "untarget", id) end,
    request = function(pid, action, target, options) return sync(ACTIONS, "request", pid, action, target, options) end,
    verify = function(opId, phase) return sync(ACTIONS, "verify", opId, phase) end,
    carryDefine = function(def) return sync(ACTIONS, "carryDefine", withMessages(def)) end,
    carryPlace = function(kind, placement) return sync(ACTIONS, "carryPlace", kind, placement) end,
    carryRemove = function(itemId) return sync(ACTIONS, "carryRemove", itemId) end,
    carryGet = function(itemId) return sync(ACTIONS, "carryGet", itemId) end,
    carrying = function(pid) return sync(ACTIONS, "carrying", pid) end,
    carryPickup = function(pid, itemId, options) return sync(ACTIONS, "carryPickup", pid, itemId, options) end,
    carryPutdown = function(pid, destination, options) return sync(ACTIONS, "carryPutdown", pid, destination, options) end,
    carryDrop = function(pid, reason) return sync(ACTIONS, "carryDrop", pid, reason) end,
}

-- ---------------------------------------------------------------------------------------------
-- open77_containers: the crates. Mutations wait for its stores (asynchronous form); reads are
-- synchronous. Before its boot join `create` answers `not_ready`.
-- ---------------------------------------------------------------------------------------------
local CONTAINERS = "open77_containers"
P.containers = {
    create = function(spec) return async(CONTAINERS, "create", spec) end,
    place = function(id, placement) return async(CONTAINERS, "place", id, placement) end,
    setPublic = function(id, meta) return async(CONTAINERS, "setPublic", id, meta) end,
    close = function(id, options) return async(CONTAINERS, "close", id, options) end,
    find = function(key) return sync(CONTAINERS, "find", key) end,
    summary = function(id) return sync(CONTAINERS, "summary", id) end,
    list = function(filter) return sync(CONTAINERS, "list", filter) end,
}

-- ---------------------------------------------------------------------------------------------
-- rp_jobs: synchronous, never yield.
-- ---------------------------------------------------------------------------------------------
P.jobs = {
    eligible = function(pid, requirement) return sync("rp_jobs", "eligible", pid, requirement) end,
    setDuty = function(pid, on, requirement) return sync("rp_jobs", "setDuty", pid, on, requirement) end,
    setJob = function(pid, job, grade) return sync("rp_jobs", "setJob", pid, job, grade) end,
}

-- ---------------------------------------------------------------------------------------------
-- rp_inventory: item definitions (the single definer toward the coordinator).
-- ---------------------------------------------------------------------------------------------
P.inventory = {
    define = function(items) return sync("rp_inventory", "define", items) end,
}

-- ---------------------------------------------------------------------------------------------
-- rp_economy: the atomic sale and charge, their status.
-- ---------------------------------------------------------------------------------------------
P.economy = {
    sale = function(spec) return async("rp_economy", "sale", spec) end,
    charge = function(spec) return async("rp_economy", "charge", spec) end,
    status = function(opId) return async("rp_economy", "status", opId) end,
    balanceOf = function(party) return async("rp_economy", "balanceOf", party) end,
}

-- ---------------------------------------------------------------------------------------------
-- rp_garage (keys, plates, warrants) and rp_cargo (truck beds)
-- ---------------------------------------------------------------------------------------------
P.garage = {
    plateOf = function(vehicleId) return sync("rp_garage", "plateOf", vehicleId) end,
    describe = function(plate) return sync("rp_garage", "describe", plate) end,
    canAccess = function(pid, plate, part, action) return sync("rp_garage", "canAccess", pid, plate, part, action) end,
    spawnOwned = function(pid, plate) return sync("rp_garage", "spawnOwned", pid, plate) end,
    labIssue = function(pid, record, opts) return sync("rp_garage", "labIssue", pid, record, opts) end,
}
P.cargo = {
    load = function(pid, vehicleId, iid, opts) return async("rp_cargo", "load", pid, vehicleId, iid, opts) end,
    unload = function(pid, vehicleId, iid, opts) return async("rp_cargo", "unload", pid, vehicleId, iid, opts) end,
    contents = function(pid, vehicleId) return async("rp_cargo", "contents", pid, vehicleId) end,
    layout = function(record) return sync("rp_cargo", "layout", record) end,
}

-- rp_ncpd (optional): criminal records and warrants. Absent, the fine and the heat still apply.
P.ncpd = {
    addRecord = function(pid, kind, text, by) return sync("rp_ncpd", "addRecord", pid, kind, text, by) end,
    setWanted = function(pid, level, reason) return sync("rp_ncpd", "setWanted", pid, level, reason) end,
}

-- ---------------------------------------------------------------------------------------------
-- Natives (wiki/data/api.json)
-- ---------------------------------------------------------------------------------------------
P.now = function() return math.floor(Open77.time.unix() * 1000) end
P.wait = function(ms) Wait(ms) end
P.spawn = function(fn) CreateThread(fn) end
P.log = function(line) print("[rp_nomade] " .. line) end
P.warn = function(line)
    if Open77.log and Open77.log.warn then Open77.log.warn("[rp_nomade] " .. line) else print("[rp_nomade] " .. line) end
end
P.emit = function(name, ...) TriggerEvent(name, ...) end
-- The resource's own key/value store (no permission): the run tallies (service.lua saveTally).
P.kvp = {
    get = function(key) return Open77.kvp.get(key) end,
    set = function(key, value) return Open77.kvp.set(key, value) end,
    delete = function(key) return Open77.kvp.delete(key) end,
    keys = function(prefix, limit) return Open77.kvp.keys(prefix, limit) end,
}
-- network.events
P.toClient = function(pid, name, ...) TriggerClientEvent(name, pid, ...) end

P.players = {
    position = function(pid) return Open77.players.position(pid) end,
    get = function(pid)
        local ok, read = pcall(Open77.players.get, pid)
        if ok and type(read) == "table" then return read end
        return nil
    end,
    name = function(pid) return Open77.players.name(pid) end,
    -- The character's full name from rp_identity (optional), else the account name.
    displayName = function(pid)
        if P.running("rp_identity") then
            local name = sync("rp_identity", "fullName", pid)
            if type(name) == "string" and name ~= "" then return name end
        end
        return Open77.players.name(pid)
    end,
    all = function() return Open77.players.all() or {} end,
    -- players.wanted
    setWanted = function(pid, level)
        if type(Open77.players.setWanted) ~= "function" then return nil, "wanted_unavailable" end
        local ok, res, why = pcall(Open77.players.setWanted, pid, level)
        if not ok then return nil, tostring(res) end
        return res, why
    end,
}

-- world.vehicles
P.vehicles = {
    all = function()
        local ok, list = pcall(Open77.vehicles.all)
        return ok and type(list) == "table" and list or {}
    end,
    get = function(id)
        local ok, v = pcall(Open77.vehicles.get, id)
        if ok and type(v) == "table" then return v end
        return nil
    end,
    position = function(id)
        if type(Open77.vehicles.getPosition) == "function" then
            local ok, pos = pcall(Open77.vehicles.getPosition, id)
            if ok and type(pos) == "table" then return pos end
        end
        local ok, v = pcall(Open77.vehicles.get, id)
        if ok and type(v) == "table" then
            if type(v.position) == "table" then return v.position end
            if v.x then return { x = v.x, y = v.y, z = v.z } end
        end
        return nil
    end,
    driver = function(id)
        if type(Open77.vehicles.getDriver) ~= "function" then return nil end
        local ok, pid = pcall(Open77.vehicles.getDriver, id)
        return ok and pid or nil
    end,
    health = function(id)
        if type(Open77.vehicles.getHealth) ~= "function" then return nil end
        local ok, h = pcall(Open77.vehicles.getHealth, id)
        return ok and tonumber(h) or nil
    end,
}

-- players.interactions.control / .read: the consented two-player steps.
P.interactions = {
    request = function(actor, target, kind, options)
        if type(Open77.playerInteractions) ~= "table" then return nil, "interactions_unavailable" end
        local ok, state, why = pcall(Open77.playerInteractions.request, actor, target, kind, options)
        if not ok then return nil, tostring(state) end
        return state, why
    end,
    get = function(id)
        if type(Open77.playerInteractions) ~= "table" then return nil end
        local ok, state = pcall(Open77.playerInteractions.get, id)
        return ok and state or nil
    end,
    cancel = function(id, reason)
        if type(Open77.playerInteractions) ~= "table" then return nil, "interactions_unavailable" end
        local ok, state, why = pcall(Open77.playerInteractions.cancel, id, reason)
        if not ok then return nil, tostring(state) end
        return state, why
    end,
}

-- Open77.zones (no permission): the one containment implementation both runtimes share. A
-- definition it refuses, or a host without it, falls back to the model's cylinder/sphere test.
local prepared = {}
P.zones = {
    contains = function(zone, point, fallback)
        if type(Open77.zones) == "table" and type(Open77.zones.normalize) == "function" then
            local p = prepared[zone]
            if p == nil then
                local ok, z = pcall(Open77.zones.normalize, zone)
                p = (ok and type(z) == "table") and z or false
                prepared[zone] = p
            end
            if p then
                local ok, inside = pcall(Open77.zones.contains, p, point)
                if ok and inside ~= nil then return inside == true end
            end
        end
        return fallback(zone, point)
    end,
}

-- world.npcs: the fence standing at its counter (presentation only).
P.npcs = {
    create = function(def) return Open77.npcs.create(def) end,
    remove = function(id) return Open77.npcs.remove(id) end,
}

-- world.props: the camp's set dressing (presentation only).
P.props = {
    create = function(def) return Open77.props.create(def) end,
    remove = function(id) return Open77.props.remove(id) end,
}

-- One chat line (always) and a toast (network.events; drawn by open77_notifications).
P.tell = function(pid, text, kind, ui)
    ui = ui or {}
    pcall(Open77.chat.send, pid, { author = ui.author or "Aldecaldos", text = text, color = ui.color or { 242, 179, 61 } })
    if Open77.notifications and Open77.notifications.send then
        pcall(Open77.notifications.send, pid, { type = kind or "info", title = ui.author or "Aldecaldos",
            message = text, durationMs = 6000, icon = ui.icon or "CARGO" })
    end
end

return P
