-- tests/compat/trauma_world.lua: the Trauma Team International offline world (rp_trauma), on
-- multihost.lua and the street-food world's platform fakes (streetfood_world.lua, SFW).
--
-- String globals from the runner: ROOT_DIR (this pack), COMPAT_DIR (this folder), SYS_DIR (the
-- Open77 `resources/system` folder holding open77_actions) and TX_DIR (the FINAL
-- open77_transactions). Files are read from those folders, never copied or edited.
--
-- What runs for real: open77_transactions (model, policy, memory store, coordinator, main.lua
-- with its exports, work queue and tunables), open77_actions (engine, claims, main), rp_economy
-- and rp_trauma's server scripts (shared/config.lua, server/*.lua). Shims stand in for the PUBLIC
-- exports of rp_jobs (eligible, workEpoch, listOnDuty, setJob, setDuty), rp_inventory (define)
-- and open77_uikit (alert, context, progress: the player's answers are scripted by the test).
-- The platform natives rp_trauma calls (life state, freeze, revive, respawn, teleport, stats,
-- distance) are fakes defined here (TW.PATCH) on top of SFW.PATCH. A death is played the way the
-- platform and the freeroam gamemode play it: `dead`, then the freeroam respawn at its spawn
-- point (`alive`), which rp_trauma answers by holding the body back at the death spot.

dofile(COMPAT_DIR .. "/streetfood_world.lua")

TW = {}

TW.SPAWN = { x = -1430.26, y = 1257.66, z = 23.09 }   -- freeroam_spawn (gamemodes/freeroam config)

TW.PATCH = [==[
local W = HOST.shared.world
local T = HOST.shared.trauma

local function player(id) return HOST.players[tonumber(id)] end
local function pos3(p) return { x = p.x, y = p.y, z = p.z } end

local function life(id, phase)
    T.revision = T.revision + 1
    TriggerEvent("onPlayerLifeStateChanged", tonumber(id), T.revision, phase)
end

Open77.players.isDead = function(id)
    local p = player(id)
    return p ~= nil and p.alive == false
end
Open77.players.getLifeState = function(id)
    local p = player(id)
    if not p then return nil end
    return { playerId = tonumber(id), phase = p.alive == false and "dead" or "alive", cause = p.deathCause or "firearm",
        weapon = p.deathWeapon or "", killer = 0, killerPlayerId = 0 }
end
Open77.players.setFrozen = function(id, on)
    local p = player(id)
    if not p then return false, "player_not_found" end
    p.frozen = on == true
    return true
end
Open77.players.revive = function(id, opts)
    local p = player(id)
    if not p or p.alive ~= false then return false, "invalid_state" end
    p.alive = true
    p.health = math.max(1, math.floor((opts and opts.health or 0.2) * (p.maxHealth or 100)))
    T.revives[#T.revives + 1] = tonumber(id)
    life(id, "alive")
    return true
end
Open77.players.respawn = function(id, opts)
    local p = player(id)
    if not p or p.alive ~= false then return false, "invalid_state" end
    p.alive = true
    p.position = { x = opts.position.x, y = opts.position.y, z = opts.position.z, bucket = opts.bucket or 0 }
    p.health = math.max(1, math.floor((opts.health or 1.0) * (p.maxHealth or 100)))
    T.respawns[#T.respawns + 1] = { id = tonumber(id), position = pos3(opts.position) }
    life(id, "alive")
    return true
end
Open77.players.teleport = function(id, position, opts)
    local p = player(id)
    if not p then return nil, "invalid_player" end
    if p.alive == false then return nil, "player_not_alive" end
    if T.teleportFails then return nil, "settle_timeout" end
    p.position = { x = position.x, y = position.y, z = position.z, bucket = p.position and p.position.bucket or 0 }
    T.teleports[#T.teleports + 1] = { id = tonumber(id), position = pos3(position), resource = GetCurrentResourceName() }
    return { await = function() Wait(0) return { x = position.x, y = position.y, z = position.z, state = "settled" } end }
end
Open77.players.distance = function(a, b)
    local function at(v)
        if type(v) == "table" then return v end
        local p = player(v)
        return p and p.position or nil
    end
    local pa, pb = at(a), at(b)
    if not pa or not pb then return nil, "player_not_found" end
    local dx, dy, dz = pa.x - pb.x, pa.y - pb.y, (pa.z or 0) - (pb.z or 0)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end
Open77.stats = {
    get = function(id)
        local p = player(id)
        if not p then return nil end
        return { health = { value = p.health or 100, maximum = p.maxHealth or 100 } }
    end,
    setHealth = function(id, v)
        local p = player(id)
        if not p then return false, "player_not_found" end
        p.health = v
        return true
    end,
    restoreHealth = function(id)
        local p = player(id)
        if not p then return false, "player_not_found" end
        p.health = p.maxHealth or 100
        return true
    end,
    setHealthRegenEnabled = function(id, on)
        local p = player(id)
        if p then p.regen = on end
        return true
    end,
}
Open77.vehicles = {
    create = function() return nil, "vehicles_unavailable" end,
    remove = function() return true end,
    warpPlayerIntoVehicle = function() return false, "vehicles_unavailable" end,
}
]==]

-- rp_jobs: the B4 contract (eligible, workEpoch, setJob, setDuty) plus listOnDuty, hasJob,
-- onDuty, and the host-wide events rp_trauma follows (rp_jobs:workEpoch, rp_jobs:duty).
TW.JOBS = [==[
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
    TriggerEvent("rp_jobs:changed", id, job)
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
        TriggerEvent("rp_jobs:duty", id, r.job, on)
    end
    return true, r.epoch
end)
exports("eligible", function(pid, requirement)
    local r = rec(pid)
    if not r then return nil, "player_not_found" end
    requirement = requirement or {}
    if requirement.epoch ~= nil and requirement.epoch ~= false and requirement.epoch ~= r.epoch then
        return nil, "stale_job_epoch"
    end
    if requirement.job and r.job ~= requirement.job then return nil, r.job and "wrong_job" or "no_job" end
    if requirement.duty and not r.duty then return nil, "off_duty" end
    return true, r.epoch
end)
exports("workEpoch", function(pid)
    local r = rec(pid)
    return r and r.epoch or false
end)
exports("listOnDuty", function(job)
    local out = {}
    for pid, r in pairs(J.players) do
        if r.job == job and r.duty and HOST.players[pid] then out[#out + 1] = pid end
    end
    table.sort(out)
    return out
end)
exports("hasJob", function(pid, job) local r = rec(pid) return r ~= nil and r.job == job end)
exports("onDuty", function(pid) local r = rec(pid) return r ~= nil and r.duty == true end)
]==]

-- open77_uikit server twins. A player's answers are scripted in HOST.shared.trauma.ui:
--   alert[pid]   = "confirm" | "cancel" | "timeout" | "none" (no answer at all: nil, reason)
--   context[pid] = an option id ("plan_gold"), "cancel" or "timeout"
--   progressCancel[pid] = true: the next bar is cancelled with X
-- Every question is logged in HOST.shared.trauma.asked.
TW.UIKIT = [==[
local T = HOST.shared.trauma
exports("alert", function(pid, def)
    pid = tonumber(pid)
    T.asked[#T.asked + 1] = { kind = "alert", pid = pid, title = def and def.title, message = def and def.message }
    local answer = T.ui.alert[pid] or "timeout"
    if answer == "none" then return nil, "callback_timeout" end
    Wait(1000)
    if answer == "timeout" then
        Wait(math.max(0, (def and def.timeoutMs or 15000) - 1000))
        return { ok = false, outcome = "timeout" }
    end
    if answer == "confirm" then return { ok = true, outcome = "ok", value = "confirm" } end
    return { ok = false, outcome = "cancelled" }
end)
exports("context", function(pid, def, options)
    pid = tonumber(pid)
    local ids = {}
    for _, o in ipairs(def and def.options or {}) do ids[#ids + 1] = o.id end
    T.asked[#T.asked + 1] = { kind = "context", pid = pid, title = def and def.title, options = table.concat(ids, ",") }
    local answer = T.ui.context[pid] or "cancel"
    Wait(1500)
    if answer == "timeout" then return { ok = false, outcome = "timeout" } end
    if answer == "cancel" then return { ok = false, outcome = "cancelled" } end
    return { ok = true, outcome = "ok", value = { id = answer } }
end)
exports("progress", function(pid, def)
    pid = tonumber(pid)
    Wait((def and def.duration or 1000) / 1000 * 1000)
    if T.ui.progressCancel[pid] then
        T.ui.progressCancel[pid] = nil
        return { ok = false, outcome = "cancelled" }
    end
    return { ok = true, outcome = "ok" }
end)
exports("textUI", function() return { ok = true } end)
exports("hideTextUI", function() return { ok = true } end)
]==]

-- A probe: funds wallets out of sys:probe (its own mint rule) and records the events.
TW.PROBE = [==[
local T = HOST.shared.trauma
AddEventHandler("open77_actions:transition", function(op)
    HOST.shared.transitions[#HOST.shared.transitions + 1] = op
end)
AddEventHandler("rp:job:completed", function(e)
    T.jobs[#T.jobs + 1] = e
end)
AddEventHandler("rp_trauma:call", function(id, state, patient, extra)
    T.calls[#T.calls + 1] = { id = id, state = state, patient = patient, extra = extra }
end)
AddEventHandler("rp_trauma:revived", function(patient, by)
    T.revived[#T.revived + 1] = { patient = patient, by = by }
end)
exports("fund", function(account, amount, opId)
    local p = Open77.exports.call("open77_transactions", "transfer", { opId = opId, kind = "probe.fund",
        lines = { { money = amount, from = "sys:probe", to = account } } })
    return p:await()
end)
exports("drain", function(account, amount, opId)
    local p = Open77.exports.call("open77_transactions", "transfer", { opId = opId, kind = "probe.drain",
        lines = { { money = amount, from = account, to = "sys:probe" } } })
    return p:await()
end)
]==]

-- The 1.x rp_trauma tables (legacy import), interpreted statement by statement.
function TW.sql(kind, sql, p, resource)
    if resource ~= "rp_trauma" then return WW.sql(kind, sql, p) end
    local db = MH.shared.traumaDb
    sql = sql:gsub("^%s+", ""):gsub("%s+$", "")
    if sql:find("^CREATE TABLE IF NOT EXISTS rp_trauma_") then
        db.creates = (db.creates or 0) + 1
        return 0
    end
    if db.missing then error("database_conflict (SQL 1146): Table 'rp.rp_trauma_bills' doesn't exist", 0) end
    if sql:find("FROM rp_trauma_bills WHERE identifier = ? AND paid_at IS NULL", 1, true) then
        local out = {}
        for _, row in ipairs(db.bills) do
            if row.identifier == p[1] and row.paid_at == nil then out[#out + 1] = { id = row.id, amount = row.amount } end
        end
        return out
    end
    if sql:find("FROM rp_trauma_contracts WHERE identifier = ? AND active = 1", 1, true) then
        local out = {}
        for _, row in ipairs(db.contracts) do
            if row.identifier == p[1] and row.active == 1 then out[#out + 1] = { until_at = row.until_at } end
        end
        return out
    end
    if sql:find("^UPDATE rp_trauma_bills SET paid_at = 0 WHERE id = ?") then
        for _, row in ipairs(db.bills) do if row.id == p[1] then row.paid_at = 0 end end
        return { affectedRows = 1 }
    end
    if sql:find("^UPDATE rp_trauma_contracts SET active = 0 WHERE identifier = ?") then
        for _, row in ipairs(db.contracts) do if row.identifier == p[1] then row.active = 0 end end
        return { affectedRows = 1 }
    end
    error("trauma_world: unexpected SQL " .. sql, 0)
end

-- ---------------------------------------------------------------------------------------------
-- Boot
-- ---------------------------------------------------------------------------------------------
TW.WRITERS = "rp_trauma:cash+bank+soc+stash/tti, rp_economy:cash+bank+soc, rp_inventory, tt_probe"
TW.MINT = "rp_trauma sys:trauma.plans tti_card 500; rp_trauma sys:trauma.billing tti_invoice 2000000; " ..
    "rp_inventory sys:* * 100000; rp_economy sys:* money 100000000; tt_probe sys:* money 1000000000"

local function startWith(name, scripts)
    local list = { { source = SFW.PATCH, name = "patch_" .. name .. ".lua" },
        { source = TW.PATCH, name = "trauma_patch_" .. name .. ".lua" } }
    for _, s in ipairs(scripts) do list[#list + 1] = s end
    return MH.start(name, list, { host = true, globals = { READ_FILE = function() return nil end } })
end
TW.startWith = startWith

local function shim(name, source) return startWith(name, { { source = source, name = name .. "_shim.lua" } }) end

-- The test server's down rules (shared/config.lua ships the live ones, 600 s and no countdown with
-- nobody on duty): a 60 s countdown that runs even with no medic, so a scenario sees it end.
TW.DOWN_RULES = [[
Config.downSeconds = 60
Config.countdownWithoutMedics = true
]]

function TW.startTrauma()
    local scripts = {}
    for _, s in ipairs(SFW.scripts(ROOT_DIR .. "/rp_trauma")) do
        scripts[#scripts + 1] = s
        if type(s) == "string" and s:match("/shared/config%.lua$") then
            scripts[#scripts + 1] = { source = TW.DOWN_RULES, name = "trauma_down_rules.lua" }
        end
    end
    return startWith("rp_trauma", scripts)
end

function TW.startCoordinator()
    return startWith("open77_transactions", {
        TX_DIR .. "/shared/model.lua", TX_DIR .. "/server/policy.lua", TX_DIR .. "/server/memory_store.lua",
        TX_DIR .. "/server/sql_store.lua", TX_DIR .. "/server/coordinator.lua",
        { source = SFW.TXSTORE, name = "txstore_shim.lua" }, TX_DIR .. "/server/main.lua",
        { source = SFW.TXPUMP, name = "txpump_shim.lua" },
    })
end

-- opts: keep (TW.keep()), writers, mint, noActions, legacy = { bills, contracts, missing }
function TW.boot(opts)
    opts = opts or {}
    MH.reset()
    MH.sql = TW.sql
    if opts.keep then
        MH.now = opts.keep.now + 60
        MH.shared.txStore, MH.shared.db, MH.kvp = opts.keep.store, opts.keep.db, opts.keep.kvp
        MH.shared.world, MH.shared.jobs = opts.keep.world, opts.keep.jobs
        MH.shared.traumaDb = opts.keep.traumaDb
        local W = MH.shared.world
        W.props, W.playing, W.client, W.held, W.ix, W.reserved = {}, {}, {}, {}, {}, {}
        for _, r in pairs(MH.shared.jobs.players) do r.duty = false end
    else
        MH.shared.txStore = nil
        MH.shared.db = WW.freshDb()
        MH.shared.world = { props = {}, propSeq = 0, playing = {}, played = {}, playbackSeq = 0, bags = {}, toasts = {},
            client = {}, held = {}, heldSeq = 0, heldLog = {}, ix = {}, ixSeq = 0, ixLog = {}, reserved = {},
            badProfiles = {} }
        MH.shared.jobs = { players = {}, seq = 100 }
        MH.shared.traumaDb = { bills = {}, contracts = {}, missing = false }
    end
    if opts.legacy then
        for k, v in pairs(opts.legacy) do MH.shared.traumaDb[k] = v end
    end
    MH.shared.trauma = { revision = 0, revives = {}, respawns = {}, teleports = {}, asked = {}, jobs = {}, calls = {},
        revived = {}, ui = { alert = {}, context = {}, progressCancel = {} }, teleportFails = false }
    MH.shared.transitions = {}
    MH.shared.needs, MH.shared.moves = {}, {}
    MH.shared.tunables = {
        open77_transactions = { store = "lab_kvp", serverTag = "lab", writers = opts.writers or TW.WRITERS,
            mint1 = opts.mint or TW.MINT },
    }
    MH.convars.open77_transactions_lab = "1"
    MH.convars.sv_masterServerEnabled = "false"
    MH.convars.open77_actions_trace = "1"
    MH.dbMode = "sql"
    TW.startCoordinator()
    shim("rp_inventory", SFW.INVENTORY)
    shim("rp_jobs", TW.JOBS)
    shim("open77_uikit", TW.UIKIT)
    shim("tt_probe", TW.PROBE)
    if not opts.noActions then startWith("open77_actions", SFW.scripts(SYS_DIR .. "/open77_actions")) end
    startWith("rp_economy", WW.scripts("rp_economy"))
    TW.startTrauma()
    MH.until_(function() return TW.svc() and TW.svc().ready and (opts.noActions or TW.svc().actionsReady) end, 60)
    MH.run(1)
end

-- What survives a server restart: the database (coordinator store), KVP files, the legacy tables,
-- the job registry; not calls, holds, props or duty.
function TW.keep()
    return { store = MH.shared.txStore, db = MH.shared.db, kvp = MH.kvp, now = MH.now, world = MH.shared.world,
        jobs = MH.shared.jobs, traumaDb = MH.shared.traumaDb }
end

function TW.svc() local R = MH.resources.rp_trauma return R and R.running and R.env.TraumaRuntime.service end
function TW.cfg() return MH.resources.rp_trauma.env.TraumaConfig end
function TW.store() return MH.shared.txStore end
function TW.balance(account) return TW.store():balance(account) end
function TW.count(account, item) return TW.store():count(account, item) end
function TW.file(subject) return "stash:" .. subject .. ":tti" end

-- The membership card's metadata in the coordinator store (durable truth), or nil.
function TW.card(subject)
    local iid = MH.resources.rp_trauma.env.TraumaModel.cardInstance(subject)
    local rec = TW.store().instances[iid]
    if rec and rec.container == TW.file(subject) then return rec.meta end
    return nil
end

-- ---------------------------------------------------------------------------------------------
-- Players
-- ---------------------------------------------------------------------------------------------
function TW.join(id, identifier, name, position)
    MH.players[id] = { identifier = identifier, name = name or ("player" .. id), ready = true, alive = true,
        heading = 0.0, health = 100, maxHealth = 100,
        position = { x = position.x, y = position.y, z = position.z, bucket = position.bucket or 0 } }
    MH.emit("onPlayerReady", id)
    MH.until_(function() return MH.resources.rp_economy.env.Wallets.byPlayer[id] ~= nil end, 30)
    MH.run(1)
end

-- After joins: the connect grace of the down state (15 s) passes.
function TW.settle() MH.run(16) end

function TW.move(id, position)
    local p = MH.players[id]
    p.position = { x = position.x, y = position.y, z = position.z, bucket = position.bucket or p.position.bucket or 0 }
end

function TW.entry(pid) return TW.svc().down.entry(pid) end

-- A real death, then the freeroam respawn at its spawn point 4 s later, which rp_trauma answers
-- by holding the body back at the death spot. Returns the down entry once held.
function TW.die(pid, opts)
    opts = opts or {}
    local p = MH.players[pid]
    p.alive = false
    p.deathCause, p.deathWeapon = opts.cause or "firearm", opts.weapon or ""
    MH.shared.trauma.revision = MH.shared.trauma.revision + 1
    MH.emit("onPlayerLifeStateChanged", pid, MH.shared.trauma.revision, "dead")
    MH.run(0.5)
    if opts.stayDead then return TW.entry(pid) end
    MH.run(3.5)
    p.alive = true
    p.health = p.maxHealth
    p.position = { x = TW.SPAWN.x, y = TW.SPAWN.y, z = TW.SPAWN.z, bucket = 0 }
    MH.shared.trauma.revision = MH.shared.trauma.revision + 1
    MH.emit("onPlayerLifeStateChanged", pid, MH.shared.trauma.revision, "alive")
    MH.until_(function() local e = TW.entry(pid) return e == nil or e.held end, 15)
    return TW.entry(pid)
end

-- A player who comes back after a disconnect: joins at the freeroam spawn point, then the connect
-- life phases of a real client (a "dead" phase while the pristine template loads, which the connect
-- grace ignores, then "alive" once spawned). Returns the down entry once held, or nil.
function TW.rejoin(pid, identifier, name)
    TW.join(pid, identifier, name, TW.SPAWN)
    local p = MH.players[pid]
    p.alive = false
    MH.shared.trauma.revision = MH.shared.trauma.revision + 1
    MH.emit("onPlayerLifeStateChanged", pid, MH.shared.trauma.revision, "dead")
    MH.run(0.5)
    p.alive = true
    MH.shared.trauma.revision = MH.shared.trauma.revision + 1
    MH.emit("onPlayerLifeStateChanged", pid, MH.shared.trauma.revision, "alive")
    MH.until_(function() local e = TW.entry(pid) return e == nil or e.held end, 15)
    return TW.entry(pid)
end

-- rp_trauma's saved down state of a subject (its kvp string, which survives restarts), or nil.
function TW.saved(subject)
    return (MH.kvp.rp_trauma or {})["down:" .. subject]
end

function TW.setup(pid)
    MH.command("tti.setup", 0, { tostring(pid) })
    MH.run(1)
end

function TW.fund(account, amount)
    TW.seq = (TW.seq or 0) + 1
    return MH.callAsync("tt_probe", "tt_probe", "fund", account, amount, ("probe.fund.%d.%d"):format(TW.seq, amount))
end

function TW.drain(account)
    local b = TW.balance(account)
    if b <= 0 then return true end
    TW.seq = (TW.seq or 0) + 1
    return MH.callAsync("tt_probe", "tt_probe", "drain", account, b, ("probe.drain.%d.%d"):format(TW.seq, b))
end

-- A player's chat command, then the clock runs.
function TW.say(pid, command, args, seconds)
    MH.command(command, pid, args or {})
    MH.run(seconds or 2)
end

-- ---------------------------------------------------------------------------------------------
-- What players were told
-- ---------------------------------------------------------------------------------------------
function TW.told(pid, pattern)
    for _, t in ipairs(MH.shared.world.toasts) do
        if t.pid == pid and t.resource == "rp_trauma" and tostring(t.text):find(pattern) then return true end
    end
    for _, c in ipairs(MH.chat) do
        local text = type(c.message) == "table" and c.message.text or c.message
        if c.target == pid and c.resource == "rp_trauma" and tostring(text):find(pattern) then return true end
    end
    return false
end

function TW.toldCount(pid, pattern)
    local n = 0
    for _, c in ipairs(MH.chat) do
        local text = type(c.message) == "table" and c.message.text or c.message
        if c.target == pid and c.resource == "rp_trauma" and tostring(text):find(pattern) then n = n + 1 end
    end
    return n
end

-- Client events rp_trauma sent to a player: name -> list of argument packs.
function TW.clientEvents(pid, name)
    local out = {}
    for _, e in ipairs(MH.shared.world.client) do
        if e.resource == "rp_trauma" and e.name == name and e.pid == pid then out[#out + 1] = e.args end
    end
    return out
end

function TW.jobs(kind)
    local out = {}
    for _, e in ipairs(MH.shared.trauma.jobs) do
        if kind == nil or e.kind == kind then out[#out + 1] = e end
    end
    return out
end

function TW.printed(pattern)
    local n = 0
    for _, line in ipairs(MH.logs) do
        if line:find("^%[rp_trauma%]") and line:find(pattern) then n = n + 1 end
    end
    return n
end

-- ---------------------------------------------------------------------------------------------
-- Actions, as a client would drive them
-- ---------------------------------------------------------------------------------------------
TW.mark = SFW.mark
TW.finish = SFW.finish
TW.waitState = SFW.waitState
TW.refusals = SFW.refusals

function TW.act(pid, actionId, targetId, seconds)
    local mark = SFW.mark()
    SFW.intent(pid, "rp_trauma:" .. actionId, targetId and ("rp_trauma:" .. targetId) or nil)
    return SFW.finish(pid, actionId, seconds or 60, mark)
end

-- ---------------------------------------------------------------------------------------------
-- Ledger checks
-- ---------------------------------------------------------------------------------------------
TW.unbalanced = SFW.unbalanced
TW.journal = SFW.journal

-- Money held (reserved, not committed) on a wallet: there must be none at rest.
function TW.held(account)
    local ok, snap = MH.callSync("tt_probe", "open77_transactions", "read", account)
    if not ok or type(snap) ~= "table" then return 0 end
    return type(snap.held) == "table" and (snap.held.money or 0) or 0
end

function TW.committed(kind)
    local n = 0
    for _, row in pairs(TW.store().ops or {}) do
        if row.state == "committed" and (kind == nil or row.kind == kind) then n = n + 1 end
    end
    return n
end

TW.result = SFW.result
