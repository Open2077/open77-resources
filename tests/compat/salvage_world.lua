-- tests/compat/salvage_world.lua: the C1 salvage pilot's offline world, on multihost.lua.
--
-- String globals from the runner: ROOT_DIR (this pack), COMPAT_DIR (this folder), SYS_DIR (the
-- Open77 `resources/system` folder holding open77_actions and open77_containers) and TX_DIR (the
-- FINAL open77_transactions resource, wave 1, wi/a13-coordinator 697e9e2f or later). Files are
-- read from those folders, never copied or edited.
--
-- What runs for real: open77_transactions (model, policy, memory store, coordinator, server/main.lua
-- with its exports, work queue, tunables and policy), open77_actions (engine, claims, carry, main),
-- open77_containers (model, lab_kvp store, service, main), rp_economy (B3), rp_cargo (A9) and
-- rp_salvage. Shims stand in for the PUBLIC exports of rp_jobs, rp_garage and rp_inventory (their
-- own suites cover them). The platform natives (players, animations, props, vehicles, NPCs, state
-- bags, tunables, readJson) are fakes defined here (SW.PATCH), applied to every resource.
--
-- The coordinator's store is the memory store in deferred mode, pumped every pass, so a test can
-- inject the store faults (lost_ack, unreachable_before, down) and stop/restart the coordinator
-- with its queued work either executed detached or discarded (A13 crash windows).

dofile(COMPAT_DIR .. "/multihost.lua")
dofile(COMPAT_DIR .. "/wallet_world.lua")
dofile(COMPAT_DIR .. "/json.lua")

SW = {}

-- ---------------------------------------------------------------------------------------------
-- Manifests: shared + server scripts in order (both `server_script "x"` and `server_scripts {}`).
-- ---------------------------------------------------------------------------------------------
function SW.scripts(dir)
    local file = assert(io.open(dir .. "/open77.lua", "rb"), "no manifest in " .. dir)
    local text = file:read("a")
    file:close()
    text = text:gsub("%-%-[^\n]*", "")
    local shared, server = {}, {}
    for kind, body in text:gmatch("(%a+_scripts?)%s*(%b{})") do
        for path in body:gmatch('"([^"]+)"') do
            if kind:match("^shared") then shared[#shared + 1] = dir .. "/" .. path
            elseif kind:match("^server") then server[#server + 1] = dir .. "/" .. path end
        end
    end
    for kind, path in text:gmatch('(%a+_script)%s+"([^"]+)"') do
        if kind == "shared_script" then shared[#shared + 1] = dir .. "/" .. path
        elseif kind == "server_script" then server[#server + 1] = dir .. "/" .. path end
    end
    for _, p in ipairs(server) do shared[#shared + 1] = p end
    return shared
end

-- ---------------------------------------------------------------------------------------------
-- The platform fakes, as the first script of every resource (they patch that resource's env).
-- ---------------------------------------------------------------------------------------------
SW.PATCH = [==[
local W = HOST.shared.world
local NAME = GetCurrentResourceName()

local function pos3(p) return { x = p.x, y = p.y, z = p.z } end

GetPlayers = function()
    local out = {}
    for id in pairs(HOST.players) do out[#out + 1] = id end
    table.sort(out)
    return out
end
GetPlayersInBucket = function(bucket)
    local out = {}
    for id, p in pairs(HOST.players) do if (p.position and p.position.bucket or 0) == bucket then out[#out + 1] = id end end
    table.sort(out)
    return out
end
GetResourceState = function(name)
    local T = HOST.resources[name]
    if not T then return "missing" end
    return T.running and "running" or "stopped"
end
GetInvokingResourceGeneration = function()
    local name = GetInvokingResource()
    local T = name and HOST.resources[name]
    return T and T.generation or nil
end
GetCurrentResourceGeneration = function() return HOST.resources[NAME].generation end
TriggerClientEvent = function(name, pid, ...)
    W.client[#W.client + 1] = { resource = NAME, name = name, pid = pid, args = table.pack(...) }
    return true
end

Open77.players.position = function(id)
    local p = HOST.players[tonumber(id)]
    if not p or not p.position then return nil end
    return { x = p.position.x, y = p.position.y, z = p.position.z, bucket = p.position.bucket or 0 }
end
Open77.players.get = function(id)
    local pid = tonumber(id)
    local p = pid and HOST.players[pid]
    if not p then return nil, "player_not_found" end
    return {
        playerId = pid, ready = p.ready ~= false, fresh = true, ageMs = 0,
        alive = p.alive ~= false, dead = p.alive == false, inVehicle = p.inVehicle == true,
        position = p.position and pos3(p.position) or nil, bucket = p.position and p.position.bucket or 0,
        heading = p.heading or 0.0, yaw = p.heading or 0.0, flags = p.flags or {},
        identifier = p.identifier, name = p.name,
    }
end

local function playback(pid, profile)
    if not HOST.players[tonumber(pid)] then return nil, "player_not_found" end
    W.playbackSeq = W.playbackSeq + 1
    W.playing[tonumber(pid)] = { playbackId = W.playbackSeq, profile = profile, owner = NAME }
    W.played[#W.played + 1] = { pid = tonumber(pid), profile = profile, playbackId = W.playbackSeq }
    return { playbackId = W.playbackSeq, profile = profile }
end
Open77.animations = {
    play = function(pid, profile) return playback(pid, profile) end,
    playAt = function(pid, profile) return playback(pid, profile) end,
    sequence = function(pid, steps) return playback(pid, steps and steps[1] and steps[1].profile or "sequence") end,
    stop = function() return true end,
    stopAt = function() return true end,
    get = function() return nil end,
}

Open77.props = {
    create = function(def)
        if type(def) ~= "table" or type(def.model) ~= "string" then return nil, "invalid_model" end
        if W.badModels[def.model] then return nil, "unknown_alias" end
        W.propSeq = W.propSeq + 1
        local id = tostring(W.propSeq)
        W.created[#W.created + 1] = { owner = NAME, model = def.model, id = id }
        W.props[id] = { id = id, owner = NAME, model = def.model, position = def.position and pos3(def.position),
            yaw = def.yaw or 0, bucket = def.bucket or 0 }
        return id
    end,
    get = function(id)
        local p = W.props[tostring(id)]
        if not p then return nil end
        return { id = p.id, resource = p.owner, model = p.model, position = p.position, yaw = p.yaw,
            bucket = p.bucket, attachment = p.attachment or false }
    end,
    attach = function(id, binding)
        local p = W.props[tostring(id)]
        if not p then return nil, "prop_not_found" end
        if p.owner ~= NAME then return nil, "not_owner" end
        p.attachment = binding
        return true
    end,
    detach = function(id)
        local p = W.props[tostring(id)]
        if not p then return nil, "prop_not_found" end
        p.attachment = nil
        return true
    end,
    setTransform = function(id, t)
        local p = W.props[tostring(id)]
        if not p then return nil, "prop_not_found" end
        if t.position then p.position = pos3(t.position) end
        if t.yaw then p.yaw = t.yaw end
        return true
    end,
    remove = function(id)
        local p = W.props[tostring(id)]
        if not p then return false, "prop_not_found" end
        W.props[tostring(id)] = nil
        return true
    end,
    getAttachment = function(id)
        local p = W.props[tostring(id)]
        return p and p.attachment or nil
    end,
    setAttachmentTransform = function(id, offset, rotation)
        local p = W.props[tostring(id)]
        if not p or not p.attachment then return nil, "not_attached" end
        p.attachment.offset, p.attachment.rotation = offset, rotation
        return true
    end,
}

local function vehicleOut(v)
    return { id = v.id, record = v.record, x = v.x, y = v.y, z = v.z, yaw = v.yaw or 0,
        position = { x = v.x, y = v.y, z = v.z }, bucket = v.bucket or 0, speed = v.speed or 0 }
end
Open77.vehicles = {
    get = function(id)
        local v = W.vehicles[tonumber(id)]
        return v and vehicleOut(v) or nil
    end,
    all = function()
        local out = {}
        for _, v in pairs(W.vehicles) do out[#out + 1] = vehicleOut(v) end
        table.sort(out, function(a, b) return a.id < b.id end)
        return out
    end,
}

Open77.npcs = {
    create = function(def) W.npcSeq = W.npcSeq + 1; W.npcs[W.npcSeq] = def; return W.npcSeq end,
    remove = function(id) W.npcs[id] = nil; return true end,
}

Open77.state = {
    entity = function(kind, id)
        local key = kind .. ":" .. tostring(id)
        W.bags[key] = W.bags[key] or {}
        local bag = W.bags[key]
        return {
            set = function(_, k, v) bag[k] = v; return true end,
            get = function(_, k) return bag[k] end,
        }
    end,
}

Open77.kvp.find = function(prefix, limit)
    local out = {}
    for _, key in ipairs(Open77.kvp.keys(prefix)) do
        out[#out + 1] = { key = key, value = Open77.kvp.get(key) }
        if limit and #out >= limit then break end
    end
    return out
end

Open77.tunables = {
    declare = function(declaration)
        local values = {}
        for key, decl in pairs(declaration) do values[key] = decl.value end
        for key, value in pairs((HOST.shared.tunables or {})[NAME] or {}) do values[key] = value end
        -- Kept so a test can change a live tunable (SW.setTunable).
        HOST.shared.liveTunables = HOST.shared.liveTunables or {}
        HOST.shared.liveTunables[NAME] = values
        return values
    end,
}

Open77.io = {
    readJson = function(path)
        local text = READ_FILE(ROOT_DIR .. "/" .. NAME .. "/data/" .. path)
        if not text then return nil, "not_found" end
        local ok, value = pcall(CompatJson.decode, text)
        if not ok then return nil, "invalid_json" end
        return value
    end,
}

Open77.notifications = {
    send = function(pid, def)
        W.toasts[#W.toasts + 1] = { resource = NAME, pid = pid, text = def and def.message }
        return "t" .. #W.toasts
    end,
}
]==]

-- The coordinator's store: the deferred memory store, kept in HOST.shared so it survives restarts.
SW.TXSTORE = [==[
Open77TxKvpStore = { new = function()
    local store = HOST.shared.txStore
    if not store then
        store = Open77TxMemoryStore.new({ deferred = true })
        HOST.shared.txStore = store
    end
    store.hydrated = 0
    return store
end }
]==]

-- Pumps the deferred store every pass (the "database"), unless a test holds a crash window open.
SW.TXPUMP = [==[
local RESOURCE = GetCurrentResourceName()
CreateThread(function()
    while true do
        if not HOST.shared.txPaused then HOST.shared.txStore:flush() end
        Wait(0)
    end
end)
AddEventHandler("onResourceStop", function(name)
    if name ~= RESOURCE then return end
    if HOST.shared.txOnStop == "discard" then HOST.shared.txStore:discard() else HOST.shared.txStore:runDetached() end
end)
]==]

-- ---------------------------------------------------------------------------------------------
-- Shims: the public exports of rp_jobs, rp_garage and rp_inventory (their own suites test them).
-- ---------------------------------------------------------------------------------------------
SW.JOBS = [==[
-- rp_jobs B4 contract: eligible -> true, epoch | nil, reason; workEpoch; setDuty; setJob.
local J = HOST.shared.jobs
local function bump(pid, reason)
    J.seq = J.seq + 1
    J.players[pid].epoch = J.seq
    TriggerEvent("rp_jobs:workEpoch", pid, J.seq, reason)
end
local function rec(pid)
    pid = tonumber(pid)
    if not pid or not HOST.players[pid] then return nil end
    J.players[pid] = J.players[pid] or { job = false, grade = 0, duty = false, epoch = 1 }
    return J.players[pid], pid
end
exports("setJob", function(pid, job, grade)
    local r, id = rec(pid)
    if not r then return nil, "player_not_found" end
    r.job, r.grade, r.duty = job, grade or 0, false
    bump(id, "job_changed")
    return true
end)
exports("setDuty", function(pid, on, requirement)
    local r, id = rec(pid)
    if not r then return nil, "player_not_found" end
    if not r.job then return nil, "no_job" end
    if requirement and requirement.job and requirement.job ~= r.job then return nil, "wrong_job" end
    if r.duty ~= on then
        r.duty = on
        bump(id, on and "duty_on" or "duty_off")
    end
    return true, r.epoch
end)
exports("eligible", function(pid, requirement)
    local r = rec(pid)
    if not r then return nil, "player_not_found" end
    requirement = requirement or {}
    if requirement.job and r.job ~= requirement.job then return nil, r.job and "wrong_job" or "no_job" end
    if requirement.duty and not r.duty then return nil, "off_duty" end
    return true, r.epoch
end)
exports("workEpoch", function(pid)
    local r = rec(pid)
    return r and r.epoch or false
end)
exports("summary", function(pid)
    local r = rec(pid)
    if not r then return nil, "player_not_found" end
    return { job = r.job, grade = r.grade, onDuty = r.duty }
end)
]==]

SW.GARAGE = [==[
-- rp_garage A9 contract: plateOf, describe, canAccess (owner / key / stranger), spawnOwned.
local G = HOST.shared.garage
exports("plateOf", function(vid) return G.plates[tostring(vid)] end)
exports("describe", function(plate)
    local row = G.rows[plate]
    if not row then return nil end
    return { plate = plate, record = row.record, label = "Thorton Mackinaw", state = row.vehicleId and "out" or "stored",
        owner = row.owner, vehicleId = row.vehicleId }
end)
exports("canAccess", function(pid, plate, part, action)
    local row = G.rows[plate]
    if not row then return false, "vehicle_not_tracked" end
    local id = Open77.players.identifier(pid)
    if id and row.owner == id then return true, "owner" end
    if id and row.keys[id] then return true, "key" end
    return false, "no_access"
end)
exports("spawnOwned", function() return nil, "not_in_this_fake" end)
]==]

SW.INVENTORY = [==[
-- rp_inventory B1/B2 contract (transactions backend): define -> registered, rejected, details;
-- backend; addAsync (a tool instance with its B1 durability). Pockets char:<subject> are
-- opened at join like the B2 facade does.
local TX = "open77_transactions"
local defs = {}
local counter = 0
local BUILTIN = { chip = { weight = 0.05 }, scrap = { weight = 1.0 }, component = { weight = 0.5 } }
local function toCoordinator(items)
    local out = {}
    for id, d in pairs(items) do
        out[id] = { weightG = math.floor((d.weight or 0) * 1000 + 0.5),
            unique = d.unique == true or d.durability ~= nil }
    end
    return out
end
local function push(items) return Open77.exports.callSync(TX, "define", toCoordinator(items)) end
exports("define", function(items)
    for id, d in pairs(items) do defs[id] = d end
    local ok, registered, rejected, collisions = pcall(push, items)
    if not ok then return nil, "store_unavailable" end
    local n = 0
    for _ in pairs(items) do n = n + 1 end
    HOST.shared.defined = HOST.shared.defined or {}
    for id in pairs(items) do HOST.shared.defined[id] = GetInvokingResource() end
    return n - (tonumber(rejected) or 0), tonumber(rejected) or 0, { collisions = collisions }
end)
exports("backend", function() return "transactions" end)
local function pockets(pid)
    local subject = Open77.exports.callSync(TX, "subjectOf", pid)
    if not subject then return nil end
    local p = Open77.exports.call(TX, "open", "char:" .. subject, { capacityG = 40000 })
    if p then p:await() end
    return "char:" .. subject
end
exports("addAsync", function(pid, item, count, meta, opts)
    local account = pockets(pid)
    if not account then return nil, "player_not_found" end
    local d = defs[item] or BUILTIN[item]
    if not d then return nil, "unknown_item" end
    local lines = {}
    if d.durability then
        for _ = 1, count do
            counter = counter + 1
            lines[#lines + 1] = { instance = ("inv.%s.%d.%d"):format(item, math.floor(Open77.time.unix()), counter),
                item = item, from = "sys:" .. tostring(GetInvokingResource()), to = account,
                meta = meta or { durability = d.durability.start or d.durability.max } }
        end
    else
        lines[1] = { item = item, count = count, from = "sys:" .. tostring(GetInvokingResource()), to = account }
    end
    local p = Open77.exports.call(TX, "transfer", { opId = opts and opts.opId or ("inv.add." .. counter .. "." .. item),
        kind = "inv.add", lines = lines })
    return p:await()
end)
AddEventHandler("onResourceStart", function(name)
    if name ~= GetCurrentResourceName() and name ~= TX then return end
    CreateThread(function()
        -- Definitions live in the coordinator's memory: push them again at each of its starts.
        local all = {}
        for id, d in pairs(BUILTIN) do all[id] = d end
        for id, d in pairs(defs) do all[id] = d end
        for _ = 1, 40 do
            local ok = pcall(push, all)
            if ok then break end
            Wait(250)
        end
    end)
end)
AddEventHandler("onPlayerReady", function(pid)
    CreateThread(function()
        Wait(500)
        pockets(pid)
    end)
end)
]==]

-- ---------------------------------------------------------------------------------------------
-- Boot
-- ---------------------------------------------------------------------------------------------
-- open77_containers mints the wreck nodes' (zero-capacity) world rows itself: it needs `world`.
SW.WRITERS_STRICT = "rp_salvage:world+char, rp_cargo:veh/cargo, rp_economy:cash+bank+soc, rp_inventory, " ..
    "open77_containers:world"
SW.MINT_RULES = "rp_salvage sys:salvage * 100000; rp_inventory sys:* * 100000; rp_economy sys:* money 100000000"

local function readFile(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local text = file:read("a")
    file:close()
    return text
end

local function globals()
    return { json = { decode = CompatJson.decode }, CompatJson = CompatJson, ROOT_DIR = ROOT_DIR, READ_FILE = readFile }
end

local function startWith(name, scripts)
    local list = { { source = SW.PATCH, name = "patch_" .. name .. ".lua" } }
    for _, s in ipairs(scripts) do list[#list + 1] = s end
    return MH.start(name, list, { host = true, globals = globals() })
end

function SW.startCoordinator()
    return startWith("open77_transactions", {
        TX_DIR .. "/shared/model.lua", TX_DIR .. "/server/policy.lua", TX_DIR .. "/server/memory_store.lua",
        TX_DIR .. "/server/sql_store.lua", TX_DIR .. "/server/coordinator.lua",
        { source = SW.TXSTORE, name = "txstore_shim.lua" }, TX_DIR .. "/server/main.lua",
        { source = SW.TXPUMP, name = "txpump_shim.lua" },
    })
end

function SW.startActions() return startWith("open77_actions", SW.scripts(SYS_DIR .. "/open77_actions")) end
function SW.startContainers() return startWith("open77_containers", SW.scripts(SYS_DIR .. "/open77_containers")) end
function SW.startCargo() return startWith("rp_cargo", SW.scripts(ROOT_DIR .. "/rp_cargo")) end
function SW.startSalvage() return startWith("rp_salvage", SW.scripts(ROOT_DIR .. "/rp_salvage")) end
function SW.startEconomy()
    local R = startWith("rp_economy", WW.scripts("rp_economy"))
    -- NEEDED CHANGE (reported, not made: rp_economy belongs to B3): rp_salvage on the mint
    -- allowlist, as rp_ferrailleur is (the two never run together).
    R.env.EconomyConfig.mint.callers.rp_salvage = 30000
    return R
end
local function shim(name, source) return startWith(name, { { source = source, name = name .. "_shim.lua" } }) end

-- opts: keep (SW.keep()), writers, mint, faults
function SW.boot(opts)
    opts = opts or {}
    MH.reset()
    MH.sql = WW.sql
    if opts.keep then
        MH.now = opts.keep.now + 60
        MH.shared.txStore, MH.shared.db, MH.kvp = opts.keep.store, opts.keep.db, opts.keep.kvp
        MH.shared.world, MH.shared.garage, MH.shared.jobs = opts.keep.world, opts.keep.garage, opts.keep.jobs
        -- Runtime presence does not survive a restart.
        MH.shared.world.props, MH.shared.world.playing, MH.shared.world.npcs, MH.shared.world.client = {}, {}, {}, {}
        MH.shared.world.created = {}
        MH.shared.world.vehicles = {}
        for _, row in pairs(MH.shared.garage.rows) do row.vehicleId = nil end
        MH.shared.garage.plates = {}
        for _, r in pairs(MH.shared.jobs.players) do r.duty = false end
    else
        MH.shared.txStore = nil
        MH.shared.db = WW.freshDb()
        MH.shared.world = { props = {}, propSeq = 0, vehicles = {}, playing = {}, played = {}, playbackSeq = 0,
            npcs = {}, npcSeq = 0, bags = {}, toasts = {}, client = {}, created = {}, badModels = { ["tool.crowbar"] = true } }
        MH.shared.garage = { plates = {}, rows = {} }
        MH.shared.jobs = { players = {}, seq = 100 }
    end
    MH.shared.tunables = {
        open77_transactions = { store = "lab_kvp", serverTag = "lab", writers = opts.writers or "*",
            mint1 = opts.mint or SW.MINT_RULES },
    }
    MH.convars.open77_transactions_lab = "1"
    MH.convars.sv_masterServerEnabled = "false"
    MH.convars.open77_containers_store = "lab_kvp"
    MH.convars.open77_containers_lab = "1"
    MH.convars.open77_actions_trace = "1"
    MH.dbMode = "sql"
    SW.startCoordinator()
    shim("rp_inventory", SW.INVENTORY)
    shim("rp_jobs", SW.JOBS)
    shim("rp_garage", SW.GARAGE)
    SW.startContainers()
    SW.startActions()
    SW.startEconomy()
    SW.startCargo()
    SW.startSalvage()
    SW.until_(function() return SW.salvage() and SW.salvage().ready end, 60)
    MH.run(1)
end

-- What survives a server restart: the database (coordinator store, 1.x tables), KVP files, the
-- garage and job registries (SQL in the real resources), but not runtime props/vehicles/duty.
function SW.keep()
    return { store = MH.shared.txStore, db = MH.shared.db, kvp = MH.kvp, now = MH.now,
        world = MH.shared.world, garage = MH.shared.garage, jobs = MH.shared.jobs }
end

function SW.crash(mode)
    local store = MH.shared.txStore
    if mode == "detached" then store:runDetached() else store:discard() end
    return SW.keep()
end

-- An operator changing a live tunable (`apply = "live"`): the value, then onTunableChanged.
function SW.setTunable(resource, key, value)
    MH.shared.liveTunables[resource][key] = value
    MH.shared.tunables[resource][key] = value
    MH.emit("onTunableChanged", key)
end

function SW.until_(predicate, seconds) return MH.until_(predicate, seconds) end
function SW.salvage() local R = MH.resources.rp_salvage return R and R.running and R.env.SalvageRuntime.service end
function SW.coordinator() return MH.resources.open77_transactions.env end
function SW.store() return MH.shared.txStore end

-- ---------------------------------------------------------------------------------------------
-- Players, vehicles, movement
-- ---------------------------------------------------------------------------------------------
function SW.join(id, identifier, name, position)
    MH.players[id] = { identifier = identifier, name = name or ("player" .. id), ready = true, alive = true,
        heading = 0.0, position = { x = position.x, y = position.y, z = position.z, bucket = position.bucket or 0 } }
    MH.emit("onPlayerReady", id)
    MH.until_(function()
        local env = MH.resources.rp_economy.env
        return env.Wallets.byPlayer[id] ~= nil
    end, 30)
    MH.run(1)
end

function SW.move(id, position, heading)
    local p = MH.players[id]
    p.position = { x = position.x, y = position.y, z = position.z, bucket = position.bucket or p.position.bucket or 0 }
    if heading then p.heading = heading end
end

function SW.kill(id)
    MH.players[id].alive = false
    MH.emit("onPlayerLifeStateChanged", id, 1, "dead")
end

function SW.disconnect(id) MH.disconnect(id) end

-- A plated truck owned by `ownerIdentifier`, `keys` = { identifier = true }.
function SW.truck(id, plate, ownerIdentifier, position, keys)
    MH.shared.world.vehicles[id] = { id = id, record = "Vehicle.v_standard3_thorton_mackinaw_player",
        x = position.x, y = position.y, z = position.z, yaw = 0, bucket = 0, speed = 0 }
    MH.shared.garage.plates[tostring(id)] = plate
    MH.shared.garage.rows[plate] = { owner = ownerIdentifier, keys = keys or {}, vehicleId = id,
        record = "Vehicle.v_standard3_thorton_mackinaw_player" }
    MH.emit("rp_garage:spawned", plate, id, "Vehicle.v_standard3_thorton_mackinaw_player")
    MH.run(0.5)
end

-- ---------------------------------------------------------------------------------------------
-- Driving the libraries like a client would
-- ---------------------------------------------------------------------------------------------
-- A prompt choice: the net event open77_actions' client sends (source = the player).
function SW.intent(pid, actionKey, targetKey)
    local R = MH.resources.open77_actions
    R.env.source = pid
    MH.emit("open77:actions:intent", actionKey, targetKey)
    R.env.source = nil
end

-- The put-down key (G): the net event, no destination.
function SW.putdownKey(pid)
    local R = MH.resources.open77_actions
    R.env.source = pid
    MH.emit("open77:actions:putdown")
    R.env.source = nil
end

function SW.sync(from, target, name, ...)
    local res = table.pack(MH.callSync(from, target, name, ...))
    if not res[1] then return nil, "raised:" .. tostring(res[2]) end
    return table.unpack(res, 2, res.n)
end

function SW.command(name, args) MH.command(name, 0, args) end

-- The actions engine of the running open77_actions VM (inspection only).
function SW.engine() return MH.resources.open77_actions.env.Open77ActionsRuntime end

-- Last transition seen for a player's operations of rp_salvage (from the host bus).
SW.transitions = {}
function SW.watch()
    MH.start("salvage_probe", { { source = [==[
AddEventHandler("open77_actions:transition", function(op)
    HOST.shared.transitions[#HOST.shared.transitions + 1] = op
end)
AddEventHandler("open77_actions:carry", function(ev)
    HOST.shared.carryEvents[#HOST.shared.carryEvents + 1] = ev
end)
]==], name = "probe.lua" } }, { host = true })
    MH.shared.transitions, MH.shared.carryEvents = {}, {}
end

function SW.lastOp(pid, actionId, after)
    local list = MH.shared.transitions or {}
    for i = #list, (after or 0) + 1, -1 do
        local op = list[i]
        if op.playerId == pid and (actionId == nil or op.actionId == actionId) then return op end
    end
    return nil
end

function SW.mark() return #(MH.shared.transitions or {}) end

-- Runs until the player's first operation of `actionId` begun after `mark` is terminal (its last
-- transition); returns that transition. Without a mark: the latest operation.
function SW.finish(pid, actionId, seconds, mark)
    local TERMINAL = { committed = true, cancelled = true, failed = true, in_doubt = true }
    local opId
    MH.until_(function()
        local list = MH.shared.transitions or {}
        for i = (mark or 0) + 1, #list do
            local op = list[i]
            if op.playerId == pid and (actionId == nil or op.actionId == actionId) then
                opId = opId or op.opId
                if op.opId == opId and TERMINAL[op.state] then return true end
            end
        end
        return false
    end, seconds or 30)
    MH.run(0.5)
    local list = MH.shared.transitions or {}
    for i = #list, (mark or 0) + 1, -1 do
        if list[i].opId == opId then return list[i] end
    end
    return nil
end

-- A prompt choice, then its outcome.
function SW.act(pid, actionKey, targetKey, actionId, seconds)
    local mark = SW.mark()
    SW.intent(pid, actionKey, targetKey)
    return SW.finish(pid, actionId, seconds, mark)
end

-- Refusal tokens open77_actions sent to a player's client (`open77:actions:refused`).
function SW.refusals(pid)
    local out = {}
    for _, e in ipairs(MH.shared.world.client) do
        if e.name == "open77:actions:refused" and e.pid == pid then out[#out + 1] = e.args[1] and e.args[1].reason end
    end
    return out
end

-- open77_actions carry items currently placed (optionally of one crate).
function SW.items(crateId)
    local engine = SW.engine()
    local n = 0
    for _, item in pairs(engine.carry.items) do
        if crateId == nil or (item.data and item.data.container == crateId) then n = n + 1 end
    end
    return n
end

-- Whether a player was told something matching a Lua pattern (chat line or toast of rp_salvage).
-- Lines rp_salvage printed (the console output of its commands) matching a pattern.
function SW.printed(pattern)
    local n = 0
    for _, line in ipairs(MH.logs) do
        if line:find("^%[rp_salvage%]") and line:find(pattern) then n = n + 1 end
    end
    return n
end

function SW.told(pid, pattern)
    for _, t in ipairs(MH.shared.world.toasts) do
        if t.pid == pid and t.resource == "rp_salvage" and tostring(t.text):find(pattern) then return true end
    end
    for _, c in ipairs(MH.chat) do
        local text = type(c.message) == "table" and c.message.text or c.message
        if c.target == pid and c.resource == "rp_salvage" and tostring(text):find(pattern) then return true end
    end
    return false
end

function SW.carrying(pid) return SW.sync("salvage_probe", "open77_actions", "carrying", pid) end

-- ---------------------------------------------------------------------------------------------
-- Durable truth (the coordinator store = the database)
-- ---------------------------------------------------------------------------------------------
function SW.count(account, item) return SW.store():count(account, item) end
function SW.balance(account) return SW.store():balance(account) end

function SW.instancesOf(item)
    local out = {}
    for iid, inst in pairs(SW.store().instances) do
        if inst.item == item then out[#out + 1] = { iid = iid, container = inst.container, meta = inst.meta } end
    end
    table.sort(out, function(a, b) return a.iid < b.iid end)
    return out
end

function SW.holdsOf(owner)
    local out = {}
    for id, c in pairs(SW.store().containers) do
        if id:match("^world:") and type(c.meta) == "table" and c.meta.app == "rp_salvage"
            and (owner == nil or c.meta.owner == owner) then
            out[#out + 1] = id
        end
    end
    table.sort(out)
    return out
end

-- Sum of journal deltas of an asset on one account (or every account matching a prefix).
function SW.journal(accountPattern, asset)
    local total = 0
    for _, e in ipairs(SW.store().journal) do
        if e.account:find(accountPattern) and e.asset == asset then total = total + e.delta end
    end
    return total
end

-- Every committed operation balances per asset (double entry); returns the first bad op or nil.
function SW.unbalanced()
    local sums = {}
    for _, e in ipairs(SW.store().journal) do
        sums[e.opId] = sums[e.opId] or {}
        sums[e.opId][e.asset] = (sums[e.opId][e.asset] or 0) + e.delta
    end
    for opId, assets in pairs(sums) do
        for asset, s in pairs(assets) do
            if s ~= 0 and asset ~= "weight_g" then return opId .. ":" .. asset .. "=" .. s end
        end
    end
    return nil
end

function SW.toolDurability(account, item)
    for _, inst in pairs(SW.store().instances) do
        if inst.container == account and inst.item == item then return inst.meta and inst.meta.durability end
    end
    return nil
end

function SW.result(t)
    t.errors = #MH.errors
    t.first_error = MH.errors[1] or ""
    local lines = {}
    for k, v in pairs(t) do lines[#lines + 1] = k .. "=" .. tostring(v) end
    table.sort(lines)
    return table.concat(lines, "\n")
end
