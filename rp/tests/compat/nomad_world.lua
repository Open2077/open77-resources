-- tests/compat/nomad_world.lua: the W3-7 nomad smuggling run's offline world, on multihost.lua.
--
-- Built on salvage_world.lua (its platform fakes, coordinator store shims, rp_jobs and
-- rp_inventory shims, the open77_actions drivers and the durable-truth readers), with what the
-- nomad run adds: vehicle position / driver / health, the wanted level, the player-interaction
-- lifecycle (the streetfood world's model), an rp_garage shim that also knows police warrants, an
-- rp_ncpd shim (records and warrants) and rp_nomade itself instead of rp_salvage.
--
-- String globals from the runner: ROOT_DIR, COMPAT_DIR, SYS_DIR, TX_DIR (salvage_world.lua).

dofile(COMPAT_DIR .. "/salvage_world.lua")

NW = {}

-- Appended to SW.PATCH: every resource gets these fakes too.
NW.PATCH = [==[
local W = HOST.shared.world
local NAME = GetCurrentResourceName()
local function copy(t)
    if type(t) ~= "table" then return t end
    local out = {}
    for k, v in pairs(t) do out[k] = copy(v) end
    return out
end

Open77.vehicles.getPosition = function(id)
    local v = W.vehicles[tonumber(id)]
    if not v then return nil, "vehicle_not_found" end
    return { x = v.x, y = v.y, z = v.z }
end
Open77.vehicles.getDriver = function(id)
    local v = W.vehicles[tonumber(id)]
    if not v then return nil, "vehicle_not_found" end
    return v.driver
end
Open77.vehicles.getHealth = function(id)
    local v = W.vehicles[tonumber(id)]
    if not v then return nil, "vehicle_not_found" end
    return v.health or 1.0
end

Open77.players.setWanted = function(pid, level)
    pid = tonumber(pid)
    if not pid or not HOST.players[pid] then return nil, "invalid_player" end
    W.wanted[pid] = level
    return { level = level, requested = level, maxLevel = 5 }
end

-- Player interactions (server API): reserves both players, consent, a shared start, events to
-- all resources (the owner filters by id). The platform half lives in NW.PLATFORM.
Open77.playerInteractions = {
    request = function(actor, target, kind, options)
        actor, target = tonumber(actor), tonumber(target)
        local a, b = HOST.players[actor], HOST.players[target]
        if not a or not b or actor == target then return nil, "invalid_participants" end
        if a.alive == false or b.alive == false then return nil, "player_not_alive" end
        if a.inVehicle or b.inVehicle then return nil, "player_in_vehicle" end
        if W.reserved[actor] or W.reserved[target] then return nil, "player_reserved" end
        options = options or {}
        local start = options.startDistance or 3
        local dx, dy, dz = a.position.x - b.position.x, a.position.y - b.position.y, a.position.z - b.position.z
        if math.sqrt(dx * dx + dy * dy + dz * dz) > start then return nil, "too_far" end
        W.ixSeq = W.ixSeq + 1
        local id = ("%032x"):format(W.ixSeq)
        local st = { id = id, kind = kind, actor = tostring(actor), target = tostring(target), phase = "offered",
            reason = "", bucket = 0, options = copy(options), owner = NAME, epoch = 1, revision = 1,
            inviteUntil = HOST.now + (options.inviteTimeoutMs or 15000) / 1000,
            durationS = (options.durationMs or 4000) / 1000, breakDistance = options.breakDistance or 5,
            consent = options.consent ~= false }
        W.ix[id] = st
        W.reserved[actor], W.reserved[target] = id, id
        W.ixLog[#W.ixLog + 1] = { id = id, op = "request", actor = actor, target = target, kind = kind, owner = NAME }
        if not st.consent then st.phase = "active"; st.endsAt = HOST.now + st.durationS end
        return copy(st)
    end,
    get = function(id)
        local st = W.ix[id]
        return st and copy(st) or nil
    end,
    current = function(pid)
        local id = W.reserved[tonumber(pid)]
        return id and W.ix[id] and copy(W.ix[id]) or nil
    end,
    isReserved = function(pid) return W.reserved[tonumber(pid)] ~= nil end,
    cancel = function(id, reason)
        local st = W.ix[id]
        if not st then return nil, "invalid_request" end
        if st.owner ~= NAME then return nil, "owned_by_another_resource" end
        return HOST.shared.ixEnd(id, "cancelled", reason or "cancelled")
    end,
}
]==]

NW.PLATFORM = [==[
local W = HOST.shared.world
local function finish(id, phase, reason)
    local st = W.ix[id]
    if not st then return nil, "invalid_request" end
    W.ix[id] = nil
    for pid, rid in pairs(W.reserved) do if rid == id then W.reserved[pid] = nil end end
    st.phase, st.reason = phase, reason or ""
    W.ixLog[#W.ixLog + 1] = { id = id, op = phase, reason = st.reason }
    local out = {}
    for k, v in pairs(st) do out[k] = v end
    if phase == "completed" then
        TriggerEvent("onPlayerInteractionCompleted", out)
    else
        TriggerEvent("onPlayerInteractionCancelled", out)
    end
    return out
end
HOST.shared.ixEnd = finish
HOST.shared.ixRespond = function(id, accepted)
    local st = W.ix[id]
    if not st or st.phase ~= "offered" then return nil, "invalid_phase" end
    if not accepted then return finish(id, "cancelled", "declined") end
    st.phase = "active"
    st.endsAt = HOST.now + st.durationS
    return true
end
local function far(st)
    local a, b = HOST.players[tonumber(st.actor)], HOST.players[tonumber(st.target)]
    if not a or not b then return "disconnected" end
    if a.alive == false or b.alive == false then return "player_not_alive" end
    local dx, dy, dz = a.position.x - b.position.x, a.position.y - b.position.y, a.position.z - b.position.z
    if math.sqrt(dx * dx + dy * dy + dz * dz) > st.breakDistance then return "too_far" end
    return nil
end
CreateThread(function()
    while true do
        local ids = {}
        for id in pairs(W.ix) do ids[#ids + 1] = id end
        table.sort(ids)
        for _, id in ipairs(ids) do
            local st = W.ix[id]
            if st then
                local bad = far(st)
                if bad then
                    finish(id, "cancelled", bad)
                elseif st.phase == "offered" and HOST.now >= st.inviteUntil then
                    finish(id, "cancelled", "timeout")
                elseif st.phase == "active" and HOST.now >= st.endsAt then
                    finish(id, "completed", "completed")
                end
            end
        end
        Wait(0)
    end
end)
AddEventHandler("onResourceStop", function(name)
    for id, st in pairs(W.ix) do if st.owner == name then finish(id, "cancelled", "resource_stopping") end end
end)
]==]

-- rp_garage: plateOf, describe (with the runtime vehicle id while out), canAccess (owner / key /
-- police with a warrant on the plate for view and take), labIssue, spawnOwned.
NW.GARAGE = [==[
local G = HOST.shared.garage
local J = HOST.shared.jobs
exports("plateOf", function(vid) return G.plates[tostring(vid)] end)
exports("describe", function(plate)
    local row = G.rows[plate]
    if not row then return nil, "vehicle_not_tracked" end
    return { plate = plate, record = row.record, label = "Thorton Mackinaw", state = row.vehicleId and "out" or "stored",
        owner = row.owner, vehicleId = row.vehicleId }
end)
exports("canAccess", function(pid, plate, part, action)
    local row = G.rows[plate]
    if not row then return false, "vehicle_not_tracked" end
    local id = Open77.players.identifier(pid)
    if id and row.owner == id then return true, "owner" end
    if id and row.keys[id] then return true, "key" end
    local job = J.players[tonumber(pid)]
    if job and job.job == "ncpd" then
        if not job.duty then return false, "off_duty" end
        if row.warrant and (action == "view" or action == "take") then return true, "police" end
        return false, "warrant_required"
    end
    return false, "no_access"
end)
exports("spawnOwned", function() return nil, "not_in_this_fake" end)
exports("labIssue", function() return nil, "lab_disabled" end)
]==]

NW.NCPD = [==[
local N = HOST.shared.ncpd
exports("addRecord", function(pid, kind, text, by)
    N.records[#N.records + 1] = { pid = pid, kind = kind, text = text, by = by }
    return true
end)
exports("setWanted", function(pid, level, reason)
    N.warrants[tonumber(pid)] = { level = level, reason = reason }
    return true
end)
exports("isOnDuty", function(pid)
    local job = HOST.shared.jobs.players[tonumber(pid)]
    return job ~= nil and job.job == "ncpd" and job.duty == true
end)
]==]

NW.WRITERS_STRICT = "rp_nomade:world+stash+char, rp_cargo:veh/cargo, rp_economy:cash+bank+soc, rp_inventory, " ..
    "open77_containers:world"
NW.MINT_RULES = "rp_nomade sys:nomad nomad_crate 1000; rp_nomade sys:nomad.supplier nomad_contraband 100000; " ..
    "rp_inventory sys:* * 100000; rp_economy sys:* money 100000000"

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
    local list = { { source = SW.PATCH, name = "patch_" .. name .. ".lua" },
                   { source = NW.PATCH, name = "patch2_" .. name .. ".lua" } }
    for _, s in ipairs(scripts) do list[#list + 1] = s end
    return MH.start(name, list, { host = true, globals = globals() })
end
NW.startWith = startWith

local function shim(name, source) return startWith(name, { { source = source, name = name .. "_shim.lua" } }) end

function NW.startNomad() return startWith("rp_nomade", SW.scripts(ROOT_DIR .. "/rp_nomade")) end

-- opts: keep (NW.keep()), writers, mint, config (function(cfg) patching NomadConfig before boot)
function NW.boot(opts)
    opts = opts or {}
    MH.reset()
    MH.sql = WW.sql
    if opts.keep then
        MH.now = opts.keep.now + 60
        MH.shared.txStore, MH.shared.db, MH.kvp = opts.keep.store, opts.keep.db, opts.keep.kvp
        MH.shared.world, MH.shared.garage, MH.shared.jobs = opts.keep.world, opts.keep.garage, opts.keep.jobs
        MH.shared.ncpd = opts.keep.ncpd
        local w = MH.shared.world
        w.props, w.playing, w.npcs, w.client, w.created = {}, {}, {}, {}, {}
        w.vehicles, w.ix, w.reserved = {}, {}, {}
        for _, row in pairs(MH.shared.garage.rows) do row.vehicleId = nil end
        MH.shared.garage.plates = {}
        for _, r in pairs(MH.shared.jobs.players) do r.duty = false end
    else
        MH.shared.txStore = nil
        MH.shared.db = WW.freshDb()
        MH.shared.world = { props = {}, propSeq = 0, vehicles = {}, playing = {}, played = {}, playbackSeq = 0,
            npcs = {}, npcSeq = 0, bags = {}, toasts = {}, client = {}, created = {}, badModels = {},
            wanted = {}, ix = {}, ixSeq = 0, ixLog = {}, reserved = {}, held = {}, heldSeq = 0, heldLog = {},
            badProfiles = {} }
        MH.shared.garage = { plates = {}, rows = {} }
        MH.shared.jobs = { players = {}, seq = 100 }
        MH.shared.ncpd = { records = {}, warrants = {} }
    end
    MH.shared.tunables = {
        open77_transactions = { store = "lab_kvp", serverTag = "lab", writers = opts.writers or "*",
            mint1 = opts.mint or NW.MINT_RULES },
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
    shim("rp_garage", NW.GARAGE)
    shim("rp_ncpd", NW.NCPD)
    shim("open77_player_interactions", NW.PLATFORM)
    SW.startContainers()
    SW.startActions()
    SW.startEconomy()
    SW.startCargo()
    if opts.config then
        -- The config is a server script of rp_nomade: patch it right after it ran.
        local scripts = SW.scripts(ROOT_DIR .. "/rp_nomade")
        local list = {}
        for i, path in ipairs(scripts) do
            list[#list + 1] = path
            if i == 1 then list[#list + 1] = { source = "NOMAD_PATCH(NomadConfig)", name = "config_patch.lua" } end
        end
        local R = MH.start("rp_nomade", (function()
            local all = { { source = SW.PATCH, name = "patch_rp_nomade.lua" }, { source = NW.PATCH, name = "patch2_rp_nomade.lua" } }
            for _, s in ipairs(list) do all[#all + 1] = s end
            return all
        end)(), { host = true, globals = (function() local g = globals() g.NOMAD_PATCH = opts.config return g end)() })
        NW.R = R
    else
        NW.R = NW.startNomad()
    end
    MH.until_(function() return NW.svc() and NW.svc().ready end, 90)
    MH.run(1)
end

function NW.keep()
    return { store = MH.shared.txStore, db = MH.shared.db, kvp = MH.kvp, now = MH.now, world = MH.shared.world,
        garage = MH.shared.garage, jobs = MH.shared.jobs, ncpd = MH.shared.ncpd }
end

function NW.svc() local R = MH.resources.rp_nomade return R and R.running and R.env.NomadRuntime.service end
function NW.cfg() return MH.resources.rp_nomade.env.NomadConfig end
function NW.model() return MH.resources.rp_nomade.env.NomadModel end

-- A plated truck owned by `ownerIdentifier`, `keys` = { identifier = true }.
function NW.truck(id, plate, ownerIdentifier, position, keys)
    MH.shared.world.vehicles[id] = { id = id, record = "Vehicle.v_standard3_thorton_mackinaw_player",
        x = position.x, y = position.y, z = position.z, yaw = 0, bucket = 0, speed = 0, health = 1.0 }
    MH.shared.garage.plates[tostring(id)] = plate
    MH.shared.garage.rows[plate] = MH.shared.garage.rows[plate] or { owner = ownerIdentifier, keys = keys or {},
        record = "Vehicle.v_standard3_thorton_mackinaw_player" }
    MH.shared.garage.rows[plate].vehicleId = id
    MH.emit("rp_garage:spawned", plate, id, "Vehicle.v_standard3_thorton_mackinaw_player")
    MH.run(0.5)
end

function NW.drive(id, position, driver)
    local v = MH.shared.world.vehicles[id]
    v.x, v.y, v.z = position.x, position.y, position.z
    v.driver = driver
end

-- The truck is removed from the world by the garage (stored, impounded, lost).
function NW.despawn(id, reason)
    local plate = MH.shared.garage.plates[tostring(id)]
    MH.shared.world.vehicles[id] = nil
    MH.shared.garage.plates[tostring(id)] = nil
    if plate then MH.shared.garage.rows[plate].vehicleId = nil end
    MH.emit("rp_garage:despawned", plate, id, reason)
    MH.run(0.5)
end

function NW.setJob(pid, job, duty)
    SW.sync("salvage_probe", "rp_jobs", "setJob", pid, job, 0)
    if duty ~= false then SW.sync("salvage_probe", "rp_jobs", "setDuty", pid, true, { job = job }) end
end

-- Last navigation state pushed to a player (false = cleared, nil = never).
function NW.nav(pid)
    local last
    for _, e in ipairs(MH.shared.world.client) do
        if e.resource == "rp_nomade" and e.name == "rp_nomade:nav" and e.pid == pid then last = e.args[1] end
    end
    return last
end

-- rp:job:completed events seen on the host bus.
function NW.watchFixer()
    MH.start("fixer_probe", { { source = [==[
AddEventHandler("rp:job:completed", function(ev)
    HOST.shared.fixer[#HOST.shared.fixer + 1] = ev
end)
]==], name = "fixer_probe.lua" } }, { host = true })
    MH.shared.fixer = {}
end

function NW.fixerKinds()
    local out = {}
    for _, ev in ipairs(MH.shared.fixer or {}) do out[#out + 1] = ev.kind end
    return table.concat(out, ",")
end

function NW.fixer(kind)
    for _, ev in ipairs(MH.shared.fixer or {}) do if ev.kind == kind then return ev end end
    return nil
end

function NW.told(pid, pattern)
    for _, t in ipairs(MH.shared.world.toasts) do
        if t.pid == pid and t.resource == "rp_nomade" and tostring(t.text):find(pattern) then return true end
    end
    for _, c in ipairs(MH.chat) do
        local text = type(c.message) == "table" and c.message.text or c.message
        if c.target == pid and c.resource == "rp_nomade" and tostring(text):find(pattern) then return true end
    end
    return false
end

function NW.printed(pattern)
    local n = 0
    for _, line in ipairs(MH.logs) do
        if line:find("^%[rp_nomade%]") and line:find(pattern) then n = n + 1 end
    end
    return n
end

-- The crates (open77_containers world accounts) of a run, in index order.
function NW.cratesOf(runKey)
    local out = {}
    for id, crate in pairs(NW.svc().crates) do
        if crate.run == runKey then out[crate.i] = crate end
    end
    return out
end

function NW.runOf(identifier)
    for key, run in pairs(NW.svc().runs) do
        if run.owner == identifier and not run.ended then return run end
    end
    return nil
end

function NW.lastRunOf(identifier)
    local best
    for _, run in pairs(NW.svc().runs) do
        if run.owner == identifier and (not best or run.created >= best.created) then best = run end
    end
    return best
end

-- Every world account the coordinator holds for rp_nomade crates (by token id prefix).
function NW.goodsTotal()
    local store = SW.store()
    local total = 0
    for id, c in pairs(store.containers) do
        total = total + store:count(id, "nomad_contraband")
    end
    return total
end

-- Conservation of goods: minted from the supplier = in the stash + in crates + burned at the
-- fence + in pockets + in evidence.
function NW.conserved()
    local store = SW.store()
    local minted = -SW.journal("^sys:nomad%.supplier$", "nomad_contraband")
    local held = 0
    for id in pairs(store.containers) do held = held + store:count(id, "nomad_contraband") end
    local burned = SW.journal("^sys:rp_nomade:fence$", "nomad_contraband")
    local discarded = SW.journal("^sys:discarded$", "nomad_contraband")
    return minted == held + burned + discarded, ("minted=%d held=%d burned=%d discarded=%d"):format(minted, held, burned,
        discarded)
end

-- Driving the libraries like a client would (aliases of the salvage world's).
function NW.act(pid, actionKey, targetKey, actionId, seconds) return SW.act(pid, actionKey, targetKey, actionId, seconds) end

function NW.pickup(pid, crate)
    SW.intent(pid, "open77_actions:carry_pickup", "item:" .. tostring(crate.itemId))
    MH.until_(function() return SW.carrying(pid) ~= nil end, 10)
    MH.run(0.5)
    return SW.carrying(pid)
end

function NW.putdownAt(pid, targetKey) return SW.act(pid, "open77_actions:carry_putdown", targetKey, "carry_putdown", 30) end

function NW.respond(pid, accepted)
    local W = MH.shared.world
    local id = W.reserved[pid]
    if not id then return nil, "no_interaction" end
    return MH.shared.ixRespond(id, accepted)
end

function NW.result(t) return SW.result(t) end
