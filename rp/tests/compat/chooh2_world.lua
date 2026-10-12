-- tests/compat/chooh2_world.lua: the CHOOH2 chain's offline world (rp_chooh2), on multihost.lua.
--
-- Builds on salvage_world.lua (the platform fakes SW.PATCH, the deferred coordinator store, the
-- rp_garage shim, the actions/carry drivers and the durable-truth readers) and changes only what
-- this job needs:
--   * rp_chooh2 instead of rp_salvage, and the REAL open77_fuel (its shared model and server
--     main) with a small patch for the vehicle flags and engine natives the fakes lack;
--   * an rp_jobs shim that accepts a list of jobs (`job = { ... }`, any of them) and, when a test
--     names the known jobs, refuses the others `unknown_job` like the real rp_jobs;
--   * an rp_inventory shim with `grantPockets` (rp_economy asks it for the seller's pockets
--     under a strict `writers` list);
--   * rp_economy with rp_chooh2 on its mint allowlist (the depot's money is minted on its behalf).
--
-- String globals from the runner: ROOT_DIR, COMPAT_DIR, SYS_DIR, TX_DIR (see salvage_world.lua).

dofile(COMPAT_DIR .. "/salvage_world.lua")

CW = {}

CW.WRITERS_STRICT = "rp_chooh2:world+stash+char, rp_cargo:veh/cargo, rp_economy:cash+bank+soc, rp_inventory, " ..
    "open77_containers:world"
-- The README's rules (caps raised for the suite): corn and crate tokens out of the fields, canisters
-- out of the refinery, nothing else.
CW.MINT_RULES = "rp_chooh2 sys:chooh2.fields * 100000; rp_chooh2 sys:chooh2.refinery chooh2_canister 100000; " ..
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
    local list = { { source = SW.PATCH, name = "patch_" .. name .. ".lua" } }
    for _, s in ipairs(scripts) do list[#list + 1] = s end
    return MH.start(name, list, { host = true, globals = globals() })
end

local function shim(name, source) return startWith(name, { { source = source, name = name .. "_shim.lua" } }) end

-- rp_jobs: eligible / setDuty / setJob / workEpoch / summary, with job lists and unknown jobs.
CW.JOBS = [==[
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
local function jobsOf(requirement)
    local jobs = requirement and requirement.job
    if jobs == nil then return nil end
    if type(jobs) == "string" then jobs = { jobs } end
    for _, name in ipairs(jobs) do
        if J.known and not J.known[name] then return nil, "unknown_job" end
    end
    return jobs
end
local function unmet(r, requirement)
    requirement = requirement or {}
    local jobs, bad = jobsOf(requirement)
    if bad then return bad end
    if jobs then
        if not r.job then return "no_job" end
        local ok = false
        for _, name in ipairs(jobs) do if name == r.job then ok = true end end
        if not ok then return "wrong_job" end
    end
    if requirement.duty and not r.duty then return r.job and "off_duty" or "no_job" end
    return nil
end
exports("setJob", function(pid, job, grade)
    local r, id = rec(pid)
    if not r then return nil, "player_not_found" end
    if J.known and job and not J.known[job] then return nil, "unknown_job" end
    r.job, r.grade, r.duty = job, grade or 0, false
    bump(id, "job_changed")
    return true
end)
exports("setDuty", function(pid, on, requirement)
    local _, bad = jobsOf(requirement)
    if bad then return nil, bad end
    local r, id = rec(pid)
    if not r then return nil, "player_not_found" end
    if not r.job then return nil, "no_job" end
    local why = unmet(r, { job = requirement and requirement.job })
    if why then return nil, why end
    if r.duty ~= on then
        r.duty = on
        bump(id, on and "duty_on" or "duty_off")
    end
    return true, r.epoch
end)
exports("eligible", function(pid, requirement)
    local _, bad = jobsOf(requirement)
    if bad then return nil, bad end
    local r = rec(pid)
    if not r then return nil, "player_not_found" end
    local why = unmet(r, requirement)
    if why then return nil, why end
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

-- rp_inventory: salvage_world's shim plus grantPockets (a one-operation grant on the pockets).
CW.INVENTORY = SW.INVENTORY .. [==[
exports("grantPockets", function(opId, pid, ttlMs)
    local subject = Open77.exports.callSync(TX, "subjectOf", pid)
    if not subject then return nil, "player_not_found" end
    local ok, why = Open77.exports.callSync(TX, "authorize", opId, GetInvokingResource(), { "char:" .. subject }, ttlMs)
    if ok ~= true then return nil, why end
    HOST.shared.pocketGrants = (HOST.shared.pocketGrants or 0) + 1
    return true
end)
]==]

-- open77_fuel runs for real; the fakes have no vehicle flags or engine natives: add them.
CW.FUELPATCH = [==[
local W = HOST.shared.world
Open77.vehicles.flags = { engineOn = 1 }
local all = Open77.vehicles.all
Open77.vehicles.all = function()
    local list = all()
    for _, v in ipairs(list) do
        local raw = W.vehicles[v.id]
        v.flags = raw and raw.engineOn and 1 or 0
        v.destroyed = false
    end
    return list
end
Open77.vehicles.setEngine = function(id, on)
    local v = W.vehicles[tonumber(id)]
    if v then v.engineOn = on end
    return true
end
Open77.vehicles.isEngineOn = function(id)
    local v = W.vehicles[tonumber(id)]
    return v ~= nil and v.engineOn == true
end
]==]

function CW.startFuel()
    local list = { { source = CW.FUELPATCH, name = "fuelpatch.lua" } }
    for _, path in ipairs(SW.scripts(SYS_DIR .. "/open77_fuel")) do list[#list + 1] = path end
    return startWith("open77_fuel", list)
end

function CW.startChooh2() return startWith("rp_chooh2", SW.scripts(ROOT_DIR .. "/rp_chooh2")) end

function CW.startEconomy()
    local R = SW.startEconomy()
    -- NEEDED CHANGE (reported, not made: rp_economy is another resource): rp_chooh2 on the mint
    -- allowlist, as rp_salvage is.
    R.env.EconomyConfig.mint.callers.rp_chooh2 = 30000
    return R
end

-- opts: keep (SW.keep()), writers, mint, noFuel, knownJobs (a list: other jobs are unknown_job)
function CW.boot(opts)
    opts = opts or {}
    MH.reset()
    MH.sql = WW.sql
    if opts.keep then
        MH.now = opts.keep.now + 60
        MH.shared.txStore, MH.shared.db, MH.kvp = opts.keep.store, opts.keep.db, opts.keep.kvp
        MH.shared.world, MH.shared.garage, MH.shared.jobs = opts.keep.world, opts.keep.garage, opts.keep.jobs
        MH.shared.world.props, MH.shared.world.playing, MH.shared.world.npcs, MH.shared.world.client = {}, {}, {}, {}
        MH.shared.world.created = {}
        MH.shared.world.vehicles = {}
        MH.shared.world.bags = {}
        for _, row in pairs(MH.shared.garage.rows) do row.vehicleId = nil end
        MH.shared.garage.plates = {}
        for _, r in pairs(MH.shared.jobs.players) do r.duty = false end
    else
        MH.shared.txStore = nil
        MH.shared.db = WW.freshDb()
        MH.shared.world = { props = {}, propSeq = 0, vehicles = {}, playing = {}, played = {}, playbackSeq = 0,
            npcs = {}, npcSeq = 0, bags = {}, toasts = {}, client = {}, created = {}, badModels = {} }
        MH.shared.garage = { plates = {}, rows = {} }
        MH.shared.jobs = { players = {}, seq = 100 }
    end
    if opts.knownJobs then
        MH.shared.jobs.known = {}
        for _, name in ipairs(opts.knownJobs) do MH.shared.jobs.known[name] = true end
    else
        MH.shared.jobs.known = nil
    end
    MH.shared.tunables = {
        open77_transactions = { store = "lab_kvp", serverTag = "lab", writers = opts.writers or "*",
            mint1 = opts.mint or CW.MINT_RULES },
    }
    MH.convars.open77_transactions_lab = "1"
    MH.convars.sv_masterServerEnabled = "false"
    MH.convars.open77_containers_store = "lab_kvp"
    MH.convars.open77_containers_lab = "1"
    MH.convars.open77_actions_trace = "1"
    MH.dbMode = "sql"
    SW.startCoordinator()
    shim("rp_inventory", CW.INVENTORY)
    shim("rp_jobs", CW.JOBS)
    shim("rp_garage", SW.GARAGE)
    SW.startContainers()
    SW.startActions()
    CW.startEconomy()
    SW.startCargo()
    if not opts.noFuel then CW.startFuel() end
    CW.startChooh2()
    SW.until_(function() return CW.svc() and CW.svc().ready end, 60)
    MH.run(1)
end

function CW.svc() local R = MH.resources.rp_chooh2 return R and R.running and R.env.Chooh2Runtime.service end

-- Probes: open77_actions transitions and carries (SW.watch) plus the fixer events.
function CW.watch()
    SW.watch()
    MH.start("chooh2_probe", { { source = [==[
AddEventHandler("rp:job:completed", function(event)
    HOST.shared.jobEvents[#HOST.shared.jobEvents + 1] = event
end)
]==], name = "probe.lua" } }, { host = true })
    MH.shared.jobEvents = {}
end

-- "kind,kind,..." of the fixer events seen (optionally one kind), and their count.
function CW.events(kind)
    local out = {}
    for _, e in ipairs(MH.shared.jobEvents or {}) do
        if kind == nil or e.kind == kind then out[#out + 1] = e end
    end
    return out
end

function CW.printed(pattern)
    local n = 0
    for _, line in ipairs(MH.logs) do
        if line:find("^%[rp_chooh2%]") and line:find(pattern) then n = n + 1 end
    end
    return n
end

function CW.told(pid, pattern)
    for _, t in ipairs(MH.shared.world.toasts) do
        if t.pid == pid and t.resource == "rp_chooh2" and tostring(t.text):find(pattern) then return true end
    end
    for _, c in ipairs(MH.chat) do
        local text = type(c.message) == "table" and c.message.text or c.message
        if c.target == pid and c.resource == "rp_chooh2" and tostring(text):find(pattern) then return true end
    end
    return false
end

function CW.holdsOf(owner)
    local out = {}
    for id, c in pairs(SW.store().containers) do
        if id:match("^world:") and type(c.meta) == "table" and c.meta.app == "rp_chooh2"
            and (owner == nil or c.meta.owner == owner) then
            out[#out + 1] = id
        end
    end
    table.sort(out)
    return out
end

-- Committed coordinator operations of one kind (receipt.kind).
function CW.committed(kind)
    local n = 0
    for _, row in pairs(SW.store().ops) do
        if row.state == "committed" and type(row.receipt) == "table" and row.receipt.kind == kind then n = n + 1 end
    end
    return n
end

-- A vehicle's fuel, from its state bag (what open77_fuel writes).
function CW.fuel(vehicleId)
    local bag = MH.shared.world.bags["vehicle:" .. tostring(vehicleId)]
    return bag and bag.fuel
end

function CW.setFuel(vehicleId, litres)
    MH.shared.world.bags["vehicle:" .. tostring(vehicleId)] = MH.shared.world.bags["vehicle:" .. tostring(vehicleId)] or {}
    MH.shared.world.bags["vehicle:" .. tostring(vehicleId)].fuel = litres
end

-- A car that is not a truck (no cargo layout, no plate): what a player refuels on the street.
function CW.car(id, position)
    MH.shared.world.vehicles[id] = { id = id, record = "Vehicle.v_sport2_mizutani_shion_player",
        x = position.x, y = position.y, z = position.z, yaw = 0, bucket = 0, speed = 0 }
    MH.run(0.5)
end

-- A player's X on the bar of their running operation.
function CW.cancelKey(pid, opId)
    local R = MH.resources.open77_actions
    R.env.source = pid
    MH.emit("open77:actions:cancel", opId)
    R.env.source = nil
end
