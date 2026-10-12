-- rp_ripperdoc / server/ports.lua: every call this resource makes to another resource (other than
-- the coordinator, which is server/ledger.lua) and every native, in one table the service uses.
-- Resources are reached only through their PUBLIC exports; natives are the ones wiki/data/api.json
-- lists for this build.
--
-- Synchronous exports are pcall'd: a stopped resource raises at the call. Asynchronous ones use the
-- promise form and yield; their export-layer rejections are passed through as reasons.
--
-- Global: RipperPorts.

RipperPorts = {}
local P = RipperPorts

local TAG = "[rp_ripperdoc]"

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
-- open77_actions: actions, targets, the lifecycle. All synchronous.
-- ---------------------------------------------------------------------------------------------
local ACTIONS = "open77_actions"
P.actions = {
    define = function(def) return sync(ACTIONS, "define", def) end,
    target = function(def) return sync(ACTIONS, "target", def) end,
    untarget = function(id) return sync(ACTIONS, "untarget", id) end,
    request = function(pid, action, target, options) return sync(ACTIONS, "request", pid, action, target, options) end,
    cancel = function(opId, reason) return sync(ACTIONS, "cancel", opId, reason) end,
    status = function(opId) return sync(ACTIONS, "status", opId) end,
    verify = function(opId, phase) return sync(ACTIONS, "verify", opId, phase) end,
    current = function(pid) return sync(ACTIONS, "current", pid) end,
}

-- ---------------------------------------------------------------------------------------------
-- rp_jobs: synchronous, never yield.
-- ---------------------------------------------------------------------------------------------
P.jobs = {
    eligible = function(pid, requirement) return sync("rp_jobs", "eligible", pid, requirement) end,
    listOnDuty = function(job)
        local list = sync("rp_jobs", "listOnDuty", job)
        return type(list) == "table" and list or {}
    end,
    gradeLabel = function(pid)
        local grade = sync("rp_jobs", "getGrade", pid)
        return type(grade) == "table" and tostring(grade.label or "?") or "?"
    end,
}

-- ---------------------------------------------------------------------------------------------
-- rp_inventory: item definitions (the single definer toward the coordinator). Synchronous.
-- rp_zones: is a player inside a named zone. Synchronous; nil when rp_zones is not running.
-- rp_identity (optional): a character's full name.
-- ---------------------------------------------------------------------------------------------
P.inventory = {
    define = function(items) return sync("rp_inventory", "define", items) end,
    backend = function() return sync("rp_inventory", "backend") end,
}

P.zones = {
    isIn = function(pid, zone)
        if not P.running("rp_zones") then return nil end
        local inside = sync("rp_zones", "isIn", pid, zone)
        return inside == true
    end,
}

P.identity = {
    fullName = function(pid)
        if not P.running("rp_identity") then return nil end
        local name = sync("rp_identity", "fullName", pid)
        return type(name) == "string" and name ~= "" and name or nil
    end,
}

-- ---------------------------------------------------------------------------------------------
-- open77_seating (optional, chair.mode = "seating"): who lies on which furniture. Synchronous.
-- ---------------------------------------------------------------------------------------------
P.seating = {
    current = function(pid)
        if not P.running("open77_seating") then return nil end
        local session = sync("open77_seating", "current", pid)
        return type(session) == "table" and session or nil
    end,
    sit = function(pid, furnitureId, options) return sync("open77_seating", "sit", pid, furnitureId, options) end,
    stand = function(pid) return sync("open77_seating", "stand", pid) end,
}

-- ---------------------------------------------------------------------------------------------
-- open77_uikit server twins (they wait for the client's answer: call from a thread).
-- ---------------------------------------------------------------------------------------------
P.uikit = {
    context = function(pid, definition) return async("open77_uikit", "context", pid, definition) end,
    progress = function(pid, definition) return async("open77_uikit", "progress", pid, definition) end,
    close = function(pid) return async("open77_uikit", "close", pid) end,
}

-- ---------------------------------------------------------------------------------------------
-- Natives
-- ---------------------------------------------------------------------------------------------
P.now = function() return math.floor(Open77.time.unix() * 1000) end
P.spawn = function(fn) CreateThread(fn) end
P.log = function(line) print(TAG .. " " .. line) end
P.warn = function(line)
    if Open77.log and Open77.log.warn then Open77.log.warn(TAG .. " " .. line) else print(TAG .. " " .. line) end
end
P.emit = function(name, ...) TriggerEvent(name, ...) end
P.toClient = function(pid, name, ...) pcall(TriggerClientEvent, name, pid, ...) end

P.players = {
    all = function()
        local ok, list = pcall(Open77.players.all)
        return ok and type(list) == "table" and list or {}
    end,
    position = function(pid) return Open77.players.position(pid) end,     -- no permission
    get = function(pid)                                                    -- players.life.read: alive
        local ok, read = pcall(Open77.players.get, pid)
        if ok and type(read) == "table" then return read end
        return nil
    end,
    name = function(pid) return Open77.players.name(pid) end,
}

-- Two-player consent (players.interactions.control / .read). Calls return directly.
P.interactions = {
    request = function(actor, target, kind, options)
        local ok, state, why = pcall(Open77.playerInteractions.request, actor, target, kind, options)
        if not ok then return nil, "interactions_unavailable" end
        return state, why
    end,
    cancel = function(id, reason)
        local ok, state, why = pcall(Open77.playerInteractions.cancel, id, reason)
        if not ok then return nil, "interactions_unavailable" end
        return state, why
    end,
    get = function(id)
        local ok, state = pcall(Open77.playerInteractions.get, id)
        if not ok then return nil, "interactions_unavailable" end
        return state
    end,
    current = function(pid)
        local ok, state = pcall(Open77.playerInteractions.current, pid)
        if not ok then return nil end
        return state
    end,
}

-- The platform's implant framework (players.cyberware.define / .read / .manage).
P.cyberware = {
    define = function(definition)
        local ok, result, why = pcall(Open77.cyberware.define, definition)
        if not ok then return nil, tostring(result) end
        return result, why
    end,
    current = function(pid)
        local ok, record, why = pcall(Open77.cyberware.current, pid)
        if not ok then return nil, "cyberware_unavailable" end
        return record, why
    end,
    install = function(pid, definitionId, gradeId, options)
        local ok, result, why = pcall(Open77.cyberware.install, pid, definitionId, gradeId, options)
        if not ok then return nil, "cyberware_unavailable" end
        return result, why
    end,
    remove = function(pid, options)
        local ok, result, why = pcall(Open77.cyberware.remove, pid, options)
        if not ok then return nil, "cyberware_unavailable" end
        return result, why
    end,
    cancel = function(pid, ticket)
        local ok, result, why = pcall(Open77.cyberware.cancel, pid, ticket)
        if not ok then return nil, "cyberware_unavailable" end
        return result, why
    end,
}

-- The three hacking implants register their hacking grade first (players.hacking.define).
P.hacking = {
    define = function(kind, definition)
        local api = type(Open77.hacking) == "table" and Open77.hacking or nil
        local fn = api and ({ hack = api.define, ice = api.defineIce, purge = api.definePurge })[kind] or nil
        if not fn then return nil, "hacking_unavailable" end
        local ok, result, why = pcall(fn, definition)
        if not ok then return nil, tostring(result) end
        return result, why
    end,
}

-- The cyberpsychosis overlay (players.screenfx).
P.screen = function(pid, effect, options)
    local ok, done, why = pcall(Open77.effects.screen, pid, effect, options)
    if not ok then return nil, tostring(done) end
    return done, why
end

-- Profiles the server's RP catalogue knows (no permission).
P.profileKnown = function(profile)
    if type(Open77.animations) ~= "table" or type(Open77.animations.get) ~= "function" then return false end
    local ok, found = pcall(Open77.animations.get, profile)
    return ok and type(found) == "table"
end

-- One chat line (always) and a toast (network.events; drawn by open77_notifications).
P.tell = function(pid, text, kind)
    pcall(Open77.chat.send, pid, { author = "RIPPERDOC", text = text, color = { 181, 123, 255 } })
    if Open77.notifications and Open77.notifications.send then
        pcall(Open77.notifications.send, pid, { type = kind or "info", title = "Ripperdoc", message = text,
            icon = "RIP", durationMs = 6000 })
    end
end

-- The durable journal of this resource (Open77.kvp: one JSON file under the resource's data folder,
-- no permission). Values are JSON strings.
P.kvp = {
    get = function(key)
        local ok, value = pcall(Open77.kvp.get, key)
        if not ok then return nil end
        return value
    end,
    set = function(key, value)
        local ok, done, why = pcall(Open77.kvp.set, key, value)
        if not ok then return nil, tostring(done) end
        if done == false then return nil, why or "kvp_refused" end
        return true
    end,
    delete = function(key)
        local ok = pcall(Open77.kvp.delete, key)
        return ok
    end,
    find = function(prefix, limit)
        local ok, rows = pcall(Open77.kvp.find, prefix, limit)
        if not ok or type(rows) ~= "table" then return {} end
        return rows
    end,
}

-- The operations log keeps the 1.x table (database.access): a history, never value.
P.db = {
    ready = function(fn)
        local ok, queued, why = pcall(Open77.database.ready, fn)
        if not ok then return false, tostring(queued) end
        return queued, why
    end,
    update = function(sql, params) return Open77.database.update.await(sql, params) end,
    insert = function(sql, params, cb)
        local ok, why = pcall(Open77.database.insert, sql, params, cb)
        if not ok then return nil, tostring(why) end
        return true
    end,
}

P.json = {
    encode = function(value) local ok, text = pcall(json.encode, value) return ok and text or nil end,
    decode = function(text)
        if type(text) ~= "string" then return nil end
        local ok, value = pcall(json.decode, text)
        return ok and value or nil
    end,
}

return P
