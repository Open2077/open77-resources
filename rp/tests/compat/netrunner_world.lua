-- tests/compat/netrunner_world.lua: rp_netrunner's offline world (breach contracts), on the street-food
-- world (streetfood_world.lua), which itself runs on multihost.lua.
--
-- String globals from the runner: ROOT_DIR (this pack), COMPAT_DIR (this folder), SYS_DIR (the Open77
-- `resources/system` folder holding open77_actions) and TX_DIR (the open77_transactions resource).
-- Files are read from those folders, never copied or edited.
--
-- What runs for real: open77_transactions (model, policy, memory store, coordinator, server/main.lua),
-- open77_actions (engine, claims, main), rp_economy and rp_netrunner. Shims stand in for the PUBLIC
-- exports of rp_jobs (with grades), rp_inventory (with grantPockets), rp_ncpd and the open77_uikit
-- server twins (scripted answers). The platform natives are SFW.PATCH (players, animations, props,
-- player interactions with consent, notifications) plus NRW.PATCH below (death, distance, the native
-- NCPD heat, the hacking kit and the implant framework).

dofile(COMPAT_DIR .. "/streetfood_world.lua")

NRW = {}

-- ---------------------------------------------------------------------------------------------
-- rp_netrunner's own natives, as a fake patched into its environment.
-- ---------------------------------------------------------------------------------------------
NRW.PATCH = [==[
local NR = HOST.shared.nr

Open77.players.isDead = function(id)
    local p = HOST.players[tonumber(id)]
    return p ~= nil and p.alive == false
end

Open77.players.distance = function(a, b)
    local pa = HOST.players[tonumber(a)]
    if not pa or not pa.position then return nil, "player_not_found" end
    local pb
    if type(b) == "table" then
        pb = b
    else
        local p = HOST.players[tonumber(b)]
        if not p or not p.position then return nil, "player_not_found" end
        pb = p.position
    end
    local dx, dy, dz = pa.position.x - pb.x, pa.position.y - pb.y, pa.position.z - (pb.z or pa.position.z)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

Open77.players.getWanted = function(id)
    id = tonumber(id)
    if not HOST.players[id] then return nil, "invalid_player" end
    return { level = NR.wanted[id] or 0, maxLevel = 5, enabled = true }
end

Open77.players.setWanted = function(id, level)
    id = tonumber(id)
    if not HOST.players[id] then return nil, "invalid_player" end
    NR.wanted[id] = level
    NR.wantedLog[#NR.wantedLog + 1] = { pid = id, level = level }
    return { level = level, requested = level, maxLevel = 5 }
end

Open77.hacking = {
    define = function(def) NR.hackDefs[def.id] = def return true end,
    start = function(actor, target, definition, grade, options)
        NR.hackStarts[#NR.hackStarts + 1] = { actor = actor, target = target, definition = definition, grade = grade,
            operationId = options and options.operationId }
        if NR.hackRefuse then return nil, NR.hackRefuse end
        NR.hackSeq = NR.hackSeq + 1
        return { ok = true, actionId = "hk" .. NR.hackSeq }
    end,
    state = function() return {} end,
}

Open77.cyberware = {
    define = function() return true end,
    current = function(pid)
        pid = tonumber(pid)
        return NR.implants[pid] or { revision = 1 }
    end,
    install = function(pid, definition, grade, options)
        pid = tonumber(pid)
        NR.implants[pid] = { revision = 2, operating_system = { definition = definition, grade = { id = grade } } }
        -- The platform commits an install asynchronously: a ticket now, the completion event later.
        NR.opSeq = NR.opSeq + 1
        local ticket = "ticket" .. NR.opSeq
        TriggerEvent("onCyberwareOperationCompleted", pid, ticket, '{"ok":true}')
        return { ok = true, ticket = ticket }
    end,
    newOperationId = function()
        NR.opSeq = NR.opSeq + 1
        return "cw" .. NR.opSeq
    end,
}

json = { decode = CompatJson.decode, encode = CompatJson.encode }
]==]

-- rp_jobs with grades and the on-duty list (B4 contract + summary / listOnDuty).
NRW.JOBS = SFW.JOBS .. [==[
exports("summary", function(pid)
    local r = rec(pid)
    if not r then return nil, "player_not_found" end
    return { job = r.job or false, grade = r.job and r.grade or false, onDuty = r.job ~= false and r.duty == true }
end)
exports("listOnDuty", function(job)
    local out = {}
    for pid, r in pairs(J.players) do
        if r.job == job and r.duty and HOST.players[pid] then out[#out + 1] = pid end
    end
    table.sort(out)
    return out
end)
]==]

-- rp_inventory with its pocket grant (a sale out of a connected seller's pockets under strict writers).
NRW.INVENTORY = SFW.INVENTORY .. [==[
exports("grantPockets", function(opId, pid, ttlMs)
    local subject = Open77.exports.callSync("open77_transactions", "subjectOf", pid)
    if not subject then return nil, "player_not_found" end
    local ok, why = Open77.exports.callSync("open77_transactions", "authorize", opId, GetInvokingResource(),
        { "char:" .. subject }, ttlMs or 60000)
    HOST.shared.nr.grants = HOST.shared.nr.grants + 1
    if ok ~= true then return nil, why or "store_unavailable" end
    return true
end)
-- A restarted coordinator lost its definitions: the real rp_inventory shakes hands again and pushes
-- every definition it holds (Facade:lost); the shim does it on the coordinator's ready event.
AddEventHandler("open77_transactions:ready", function()
    if next(defs) ~= nil then pcall(push, defs) end
end)
]==]

-- rp_ncpd: the record export and the dispatch event it listens to.
NRW.NCPD = [==[
local NR = HOST.shared.nr
exports("addRecord", function(pid, kind, text, by)
    NR.records[#NR.records + 1] = { pid = tonumber(pid), kind = kind, text = text, by = by, caller = GetInvokingResource() }
    return true
end)
AddEventHandler("rp_ncpd:alert", function(kind, position, text, by)
    NR.alerts[#NR.alerts + 1] = { kind = kind, position = position, text = text, by = by }
end)
]==]

-- open77_uikit server twins: each call takes the next scripted answer for that player and widget
-- (NRW.answer), or answers `cancelled`. What was shown is kept in NR.shown.
NRW.UIKIT = [==[
local NR = HOST.shared.nr
local function widget(kind)
    return function(pid, definition, options)
        NR.shown[#NR.shown + 1] = { kind = kind, pid = tonumber(pid), definition = definition, caller = GetInvokingResource() }
        Wait(0)
        local queue = NR.answers[tonumber(pid)]
        local nextAnswer = queue and queue[1]
        if nextAnswer and nextAnswer.kind == kind then
            table.remove(queue, 1)
            if type(nextAnswer.value) == "function" then return nextAnswer.value(definition) end
            return { ok = true, outcome = "ok", value = nextAnswer.value }
        end
        return { ok = false, outcome = "cancelled" }
    end
end
exports("context", widget("context"))
exports("alert", widget("alert"))
exports("input", widget("input"))
exports("progress", widget("progress"))
]==]

-- ---------------------------------------------------------------------------------------------
-- Boot
-- ---------------------------------------------------------------------------------------------
NRW.WRITERS_STRICT = "rp_netrunner:char+stash/contracts, rp_economy:cash+bank+soc, rp_inventory"
NRW.MINT_RULES = "rp_netrunner sys:netrunner * 100000; rp_inventory sys:* * 100000; rp_economy sys:* money 100000000; " ..
    "nr_probe sys:* * 100000"

local function startNetrunner()
    local list = { { source = SFW.PATCH, name = "patch_rp_netrunner.lua" }, { source = NRW.PATCH, name = "patch_nr.lua" } }
    for _, s in ipairs(SFW.scripts(ROOT_DIR .. "/rp_netrunner")) do list[#list + 1] = s end
    return MH.start("rp_netrunner", list, { host = true, globals = { json = { decode = CompatJson.decode },
        CompatJson = CompatJson, ROOT_DIR = ROOT_DIR } })
end
NRW.startNetrunner = startNetrunner

-- opts: keep (NRW.keep()), writers, mint, config = function(cfg, shared) (tuning before the boot
-- completes), noInteractions, noUikit, npcBoard (true keeps the NPC board on)
function NRW.boot(opts)
    opts = opts or {}
    MH.reset()
    MH.sql = WW.sql
    if opts.keep then
        MH.now = opts.keep.now + 60
        MH.shared.txStore, MH.shared.db, MH.kvp = opts.keep.store, opts.keep.db, opts.keep.kvp
        MH.shared.world, MH.shared.jobs = opts.keep.world, opts.keep.jobs
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
    end
    MH.shared.needs, MH.shared.moves = {}, {}
    MH.shared.nr = { wanted = {}, wantedLog = {}, hackDefs = {}, hackStarts = {}, hackSeq = 0, implants = {}, opSeq = 0,
        records = {}, alerts = {}, shown = {}, answers = {}, grants = 0 }
    MH.shared.tunables = {
        open77_transactions = { store = "lab_kvp", serverTag = "lab", writers = opts.writers or "*",
            mint1 = opts.mint or NRW.MINT_RULES },
    }
    MH.convars.open77_transactions_lab = "1"
    MH.convars.sv_masterServerEnabled = "false"
    MH.convars.open77_actions_trace = "1"
    MH.dbMode = "sql"
    SFW.startCoordinator()
    if not opts.noInteractions then SFW.shim("open77_player_interactions", SFW.PLATFORM) end
    SFW.shim("rp_inventory", NRW.INVENTORY)
    SFW.shim("rp_jobs", NRW.JOBS)
    SFW.shim("rp_ncpd", NRW.NCPD)
    if not opts.noUikit then SFW.shim("open77_uikit", NRW.UIKIT) end
    SFW.startActions()
    SFW.startEconomy()
    local R = startNetrunner()
    -- The NPC board is off unless a scenario asks for it (it would post contracts on its own).
    R.env.NetrunnerConfig.npcBoard.enabled = opts.npcBoard == true
    if opts.config then opts.config(R.env.NetrunnerConfig, R.env.Config) end
    NRW.watch()
    MH.until_(function() return NRW.svc() and NRW.svc().ready end, 60)
    NRW.defineChip()
    MH.run(1)
end

-- rp_inventory's built-in data chip (the breach kit), as the real rp_inventory defines it itself.
function NRW.defineChip()
    MH.callSync("nr_probe", "rp_inventory", "define", { chip = { label = "Data chip", weight = 0.05, usable = false,
        illegal = false, category = "tech" } })
end

-- What survives a server restart: the database (coordinator store), KVP files, the job registry
-- (SQL in the real rp_jobs), but not runtime props, interactions, duty or the resource's memory.
function NRW.keep()
    return { store = MH.shared.txStore, db = MH.shared.db, kvp = MH.kvp, now = MH.now,
        world = MH.shared.world, jobs = MH.shared.jobs }
end

-- Restarts rp_netrunner alone (ensure rp_netrunner): its memory goes, the coordinator stays.
function NRW.restartResource(config)
    MH.stop("rp_netrunner")
    local R = startNetrunner()
    R.env.NetrunnerConfig.npcBoard.enabled = false
    if config then config(R.env.NetrunnerConfig, R.env.Config) end
    MH.until_(function() return NRW.svc() and NRW.svc().ready end, 60)
    MH.run(1)
end

function NRW.svc() local R = MH.resources.rp_netrunner return R and R.running and R.env.NetrunnerRuntime.service end
function NRW.qh() local R = MH.resources.rp_netrunner return R and R.running and R.env.NetrunnerRuntime.quickhacks end
function NRW.cfg() return MH.resources.rp_netrunner.env.NetrunnerConfig end
function NRW.shared() return MH.resources.rp_netrunner.env.Config end
function NRW.model() return MH.resources.rp_netrunner.env.NetrunnerModel end

function NRW.watch()
    MH.start("nr_probe", { { source = [==[
AddEventHandler("open77_actions:transition", function(op)
    HOST.shared.transitions[#HOST.shared.transitions + 1] = op
end)
AddEventHandler("rp:job:completed", function(e)
    HOST.shared.jobEvents[#HOST.shared.jobEvents + 1] = e
end)
AddEventHandler("rp_netrunner:contract", function(phase, summary)
    HOST.shared.contractEvents[#HOST.shared.contractEvents + 1] = { phase = phase, summary = summary }
end)
AddEventHandler("rp_netrunner:traced", function(e)
    HOST.shared.traced[#HOST.shared.traced + 1] = e
end)
AddEventHandler("rp_netrunner:jammed", function(active)
    HOST.shared.jammed[#HOST.shared.jammed + 1] = active
end)
]==], name = "nr_probe.lua" } }, { host = true })
    MH.shared.transitions, MH.shared.jobEvents, MH.shared.contractEvents = {}, {}, {}
    MH.shared.traced, MH.shared.jammed = {}, {}
end

-- ---------------------------------------------------------------------------------------------
-- Helpers (SFW's work on the shared host)
-- ---------------------------------------------------------------------------------------------
NRW.join, NRW.move, NRW.kill = SFW.join, SFW.move, SFW.kill
NRW.mark, NRW.finish, NRW.waitState, NRW.intent = SFW.mark, SFW.finish, SFW.waitState, SFW.intent
NRW.clientCancel, NRW.respond, NRW.refusals = SFW.clientCancel, SFW.respond, SFW.refusals
NRW.count, NRW.balance, NRW.journal, NRW.unbalanced, NRW.store = SFW.count, SFW.balance, SFW.journal, SFW.unbalanced, SFW.store

function NRW.command(name, args) MH.command(name, 0, args) end
function NRW.player(pid, name, args) MH.command(name, pid, args) end

-- Scripted answers to the next uikit widgets a player gets: { kind = "context"|"alert"|"input", value = ... }.
function NRW.answer(pid, list)
    MH.shared.nr.answers[pid] = MH.shared.nr.answers[pid] or {}
    for _, a in ipairs(list) do table.insert(MH.shared.nr.answers[pid], a) end
end

-- Whether a player was told something matching a Lua pattern (chat line or toast of rp_netrunner).
function NRW.told(pid, pattern)
    for _, t in ipairs(MH.shared.world.toasts) do
        if t.pid == pid and t.resource == "rp_netrunner" and tostring(t.text):find(pattern) then return true end
    end
    for _, c in ipairs(MH.chat) do
        local text = type(c.message) == "table" and c.message.text or c.message
        if c.target == pid and c.resource == "rp_netrunner" and tostring(text):find(pattern) then return true end
    end
    return false
end

function NRW.printed(pattern)
    local n = 0
    for _, line in ipairs(MH.logs) do
        if line:find("^%[rp_netrunner%]") and line:find(pattern) then n = n + 1 end
    end
    return n
end

-- A contract's record on the board (durable truth: the coordinator store), or nil once retired.
function NRW.boardContract(id)
    local inst = NRW.store().instances["nrc." .. id]
    if not inst or inst.container ~= "stash:nr.board:contracts" then return nil end
    return inst.meta
end

-- Where a unique instance is now (its container in the store), or nil when it was burned.
function NRW.whereIs(iid)
    local inst = NRW.store().instances[iid]
    return inst and inst.container or nil
end

-- Contract instances on the board right now.
function NRW.boardCount()
    local n = 0
    for _, inst in pairs(NRW.store().instances) do
        if inst.container == "stash:nr.board:contracts" then n = n + 1 end
    end
    return n
end

function NRW.jobEvents(kind)
    local out = {}
    for _, e in ipairs(MH.shared.jobEvents) do if kind == nil or e.kind == kind then out[#out + 1] = e end end
    return out
end

function NRW.contractEvents(phase)
    local out = {}
    for _, e in ipairs(MH.shared.contractEvents) do if phase == nil or e.phase == phase then out[#out + 1] = e end end
    return out
end

function NRW.played(pid, profile, kind)
    for _, p in ipairs(MH.shared.world.played) do
        if p.pid == pid and p.profile == profile and (kind == nil or p.kind == kind) then return p end
    end
    return nil
end

-- A prompt choice, then its outcome.
function NRW.act(pid, actionId, targetId, seconds)
    local mark = SFW.mark()
    SFW.intent(pid, "rp_netrunner:" .. actionId, "rp_netrunner:" .. targetId)
    return SFW.finish(pid, actionId, seconds, mark)
end

NRW.result = SFW.result
