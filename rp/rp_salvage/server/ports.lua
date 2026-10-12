-- rp_salvage / server/ports.lua: every call this resource makes to another resource (other than
-- the coordinator, which is server/ledger.lua) and every native, in one table the service uses.
-- Adapters are reached only through their PUBLIC exports (rp_jobs, rp_inventory, rp_economy,
-- rp_garage, rp_cargo) and the libraries through theirs (open77_actions, open77_containers).
--
-- Synchronous exports are pcall'd: a stopped resource raises at the call. Asynchronous ones use
-- the promise form and yield; their export-layer rejections are passed through as reasons.
--
-- Global: SalvagePorts.

-- Every action shows this resource's own words when it is refused or stops (open77_actions
-- `messages`), never a raw reason code. An older open77_actions ignores the field.
local function withMessages(def)
    local text = type(SalvageModel) == "table" and SalvageModel.TEXT
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

SalvagePorts = {}
local P = SalvagePorts

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
-- open77_actions (B5/A5): actions, targets, claims, carry. All synchronous except `begin`.
-- ---------------------------------------------------------------------------------------------
local ACTIONS = "open77_actions"
P.actions = {
    define = function(def) return sync(ACTIONS, "define", withMessages(def)) end,
    target = function(def) return sync(ACTIONS, "target", def) end,
    untarget = function(id) return sync(ACTIONS, "untarget", id) end,
    request = function(pid, action, target, options) return sync(ACTIONS, "request", pid, action, target, options) end,
    verify = function(opId, phase) return sync(ACTIONS, "verify", opId, phase) end,
    current = function(pid) return sync(ACTIONS, "current", pid) end,
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
-- open77_containers (A6, 0.2.0): the wreck nodes. Mutations wait for its stores (asynchronous
-- form; the synchronous sugar answers `export_yielded`); reads are synchronous. Before its boot
-- join (`open77_containers:ready`) `create` answers `not_ready` and every read is empty.
-- ---------------------------------------------------------------------------------------------
local CONTAINERS = "open77_containers"
P.containers = {
    create = function(spec) return async(CONTAINERS, "create", spec) end,
    consume = function(id, options) return async(CONTAINERS, "consume", id, options) end,
    refill = function(id, options) return async(CONTAINERS, "refill", id, options) end,
    find = function(key) return sync(CONTAINERS, "find", key) end,
    summary = function(id) return sync(CONTAINERS, "summary", id) end,
}

-- ---------------------------------------------------------------------------------------------
-- rp_jobs (B4): synchronous, never yield.
-- ---------------------------------------------------------------------------------------------
P.jobs = {
    eligible = function(pid, requirement) return sync("rp_jobs", "eligible", pid, requirement) end,
    setDuty = function(pid, on, requirement) return sync("rp_jobs", "setDuty", pid, on, requirement) end,
    setJob = function(pid, job, grade) return sync("rp_jobs", "setJob", pid, job, grade) end,
    summary = function(pid) return sync("rp_jobs", "summary", pid) end,
}

-- ---------------------------------------------------------------------------------------------
-- rp_inventory (B1/B2): definitions (sync) and a tool instance for the lab (async).
-- ---------------------------------------------------------------------------------------------
P.inventory = {
    define = function(items) return sync("rp_inventory", "define", items) end,
    backend = function() return sync("rp_inventory", "backend") end,
    addAsync = function(pid, item, count, meta, opts) return async("rp_inventory", "addAsync", pid, item, count, meta, opts) end,
}

-- ---------------------------------------------------------------------------------------------
-- rp_economy (B3): the atomic sale and its status.
-- ---------------------------------------------------------------------------------------------
P.economy = {
    sale = function(spec) return async("rp_economy", "sale", spec) end,
    status = function(opId) return async("rp_economy", "status", opId) end,
    balanceOf = function(party) return async("rp_economy", "balanceOf", party) end,
}

-- ---------------------------------------------------------------------------------------------
-- rp_garage (A9 access) and rp_cargo (A9 bed slots).
-- ---------------------------------------------------------------------------------------------
P.garage = {
    plateOf = function(vehicleId) return sync("rp_garage", "plateOf", vehicleId) end,
    describe = function(plate) return sync("rp_garage", "describe", plate) end,
    canAccess = function(pid, plate, part, action) return sync("rp_garage", "canAccess", pid, plate, part, action) end,
    spawnOwned = function(pid, plate) return sync("rp_garage", "spawnOwned", pid, plate) end,
    -- A9-1 (c1-salvage.md section 7): labIssue(playerId, record, opts?) -> { plate, owner, state,
    -- vehicleId? }, behind the convar rp_garage_lab 1 (`lab_disabled` otherwise). An rp_garage
    -- without it answers rp_garage_unavailable.
    labIssue = function(pid, record, opts) return sync("rp_garage", "labIssue", pid, record, opts) end,
}
P.cargo = {
    load = function(pid, vehicleId, iid, opts) return async("rp_cargo", "load", pid, vehicleId, iid, opts) end,
    unload = function(pid, vehicleId, iid, opts) return async("rp_cargo", "unload", pid, vehicleId, iid, opts) end,
    contents = function(pid, vehicleId) return async("rp_cargo", "contents", pid, vehicleId) end,
    layout = function(record) return sync("rp_cargo", "layout", record) end,
}

-- ---------------------------------------------------------------------------------------------
-- Natives (wiki/data/api.json)
-- ---------------------------------------------------------------------------------------------
P.now = function() return math.floor(Open77.time.unix() * 1000) end
P.wait = function(ms) Wait(ms) end
P.spawn = function(fn) CreateThread(fn) end
P.log = function(line) print("[rp_salvage] " .. line) end
P.warn = function(line)
    if Open77.log and Open77.log.warn then Open77.log.warn("[rp_salvage] " .. line) else print("[rp_salvage] " .. line) end
end
P.emit = function(name, ...) TriggerEvent(name, ...) end

P.players = {
    -- { x, y, z, bucket } or nil (no permission)
    position = function(pid) return Open77.players.position(pid) end,
    -- the rich read: position, heading, bucket, ready (no permission for these fields)
    get = function(pid)
        local ok, read = pcall(Open77.players.get, pid)
        if ok and type(read) == "table" then return read end
        return nil
    end,
    identifier = function(pid) return Open77.players.identifier(pid) end,
    name = function(pid) return Open77.players.name(pid) end,
    all = function() return Open77.players.all() or {} end,
}

local function vehiclePosition(v)
    if type(v) ~= "table" then return nil end
    if type(v.position) == "table" then return v.position end
    if v.x then return { x = v.x, y = v.y, z = v.z } end
    return nil
end

P.vehicles = {
    -- world.vehicles
    all = function()
        local ok, list = pcall(Open77.vehicles.all)
        return ok and type(list) == "table" and list or {}
    end,
    get = function(id)
        local ok, v = pcall(Open77.vehicles.get, id)
        if ok and type(v) == "table" then return v end
        return nil
    end,
    position = vehiclePosition,
}

P.props = {
    -- world.props
    create = function(def) return Open77.props.create(def) end,
    attach = function(id, binding) return Open77.props.attach(id, binding) end,
    remove = function(id) return Open77.props.remove(id) end,
}

P.npcs = {
    -- world.npcs
    create = function(def) return Open77.npcs.create(def) end,
    remove = function(id) return Open77.npcs.remove(id) end,
}

-- One chat line (always) and a toast (network.events; drawn by open77_notifications).
P.tell = function(pid, text, kind, title)
    pcall(Open77.chat.send, pid, { author = "Scrapyard", text = text, color = { 214, 190, 120 } })
    if Open77.notifications and Open77.notifications.send then
        pcall(Open77.notifications.send, pid, { type = kind or "info", title = title or "Scrapyard",
            message = text, durationMs = 6000, icon = "SCRAP" })
    end
end

return P
