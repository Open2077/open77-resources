-- rp_trauma / server/ports.lua: every call the Trauma Team service makes to another resource (other
-- than the coordinator, which is server/ledger.lua) and every native it uses, in one table.
-- Adapters are reached only through their PUBLIC exports (rp_jobs, rp_inventory, rp_identity) and
-- the libraries through theirs (open77_actions, open77_uikit).
--
-- Synchronous exports are pcall'd: a stopped resource raises at the call. Asynchronous ones use the
-- promise form and yield; their export-layer rejections come back as reasons.
--
-- Global: TraumaPorts.

-- Every action shows this resource's own words when it is refused or stops (open77_actions
-- `messages`), never a raw reason code. An older open77_actions ignores the field.
local function withMessages(def)
    local text = type(TraumaModel) == "table" and TraumaModel.TEXT
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

TraumaPorts = {}
local P = TraumaPorts

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
-- open77_actions: actions, targets. All synchronous.
-- ---------------------------------------------------------------------------------------------
local ACTIONS = "open77_actions"
P.actions = {
    define = function(def) return sync(ACTIONS, "define", withMessages(def)) end,
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
    listOnDuty = function(job)
        local list = sync("rp_jobs", "listOnDuty", job)
        return type(list) == "table" and list or {}
    end,
    -- true / false when rp_jobs answered, nil when it is unavailable.
    onDutyAs = function(pid, job)
        local ok, epoch = sync("rp_jobs", "eligible", pid, { job = job, duty = true })
        if ok then return true, epoch end
        if type(epoch) == "string" and epoch:find("_unavailable$") then return nil end
        return false
    end,
}

-- ---------------------------------------------------------------------------------------------
-- rp_inventory: the single item definer.
-- ---------------------------------------------------------------------------------------------
P.inventory = {
    define = function(items) return sync("rp_inventory", "define", items) end,
}

-- ---------------------------------------------------------------------------------------------
-- open77_uikit server twins (they wait for the player: yield).
-- ---------------------------------------------------------------------------------------------
P.uikit = {
    alert = function(pid, def) return async("open77_uikit", "alert", pid, def) end,
    context = function(pid, def, options) return async("open77_uikit", "context", pid, def, options) end,
}

-- ---------------------------------------------------------------------------------------------
-- Natives (wiki/data/api.json)
-- ---------------------------------------------------------------------------------------------
P.now = function() return math.floor(Open77.time.unix()) end             -- unix seconds (plans)
P.nowMs = function() return math.floor(Open77.time.unix() * 1000) end
P.spawn = function(fn) CreateThread(fn) end
P.log = function(line) print("[rp_trauma] " .. line) end
P.warn = function(line)
    if Open77.log and Open77.log.warn then Open77.log.warn("[rp_trauma] " .. line) else print("[rp_trauma] " .. line) end
end
P.emit = function(name, ...) TriggerEvent(name, ...) end
P.client = function(name, pid, ...) TriggerClientEvent(name, pid, ...) end

P.players = {
    all = function() return Open77.players.all() end,
    position = function(pid) return Open77.players.position(pid) end,       -- no permission
    get = function(pid)                                                      -- players.life.read
        local ok, read = pcall(Open77.players.get, pid)
        if ok and type(read) == "table" then return read end
        return nil
    end,
    name = function(pid) return Open77.players.name(pid) end,
    identifier = function(pid) return Open77.players.identifier(pid) end,
    distance = function(a, b)
        local ok, d = pcall(Open77.players.distance, a, b)
        if ok and type(d) == "number" then return d end
        return nil
    end,
}

-- Legacy rp_trauma 1.x tables (database.access) and kvp, read once per player for the import.
P.db = {
    query = function(sql, params)
        local box = {}
        local ok, queued = pcall(Open77.database.query, sql, params, function(rows, err)
            box.rows, box.err, box.done = rows, err, true
        end)
        if not ok or queued == false then return nil, "database_unavailable" end
        local waited = 0
        while not box.done and waited < 15000 do
            Wait(100)
            waited = waited + 100
        end
        if not box.done then return nil, "database_timeout" end
        if box.err then return nil, tostring(box.err) end
        return box.rows or {}
    end,
    update = function(sql, params)
        local ok = pcall(Open77.database.update, sql, params, function() end)
        return ok
    end,
    ready = function()
        local ok, ready = pcall(Open77.database.isReady)
        return ok and ready == true
    end,
}
P.kvp = {
    get = function(key, default) return Open77.kvp.get(key, default) end,
    delete = function(key) return Open77.kvp.delete(key) end,
}

-- One chat line (always) and a toast (network.events; drawn by open77_notifications).
P.tell = function(pid, text, kind, title)
    pcall(Open77.chat.send, pid, { author = "TRAUMA", text = text, color = { 255, 96, 96 } })
    if kind and Open77.notifications and Open77.notifications.send then
        pcall(Open77.notifications.send, pid, { type = kind, title = title or "Trauma Team",
            message = text, icon = "TT", durationMs = 7000 })
    end
end

return P
