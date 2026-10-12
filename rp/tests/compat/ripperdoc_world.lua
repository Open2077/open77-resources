-- tests/compat/ripperdoc_world.lua: the ripperdoc clinic's offline world (rp_ripperdoc), on multihost.lua.
--
-- String globals from the runner: ROOT_DIR (this pack), COMPAT_DIR (this folder), SYS_DIR (the Open77
-- `resources/system` folder holding open77_actions) and TX_DIR (the final open77_transactions).
-- Files are read in place, never copied or edited.
--
-- What runs for real: open77_transactions (model, policy, memory store, coordinator, exports, work
-- queue, tunables), open77_actions (engine, claims, main), rp_economy and rp_ripperdoc. The platform
-- natives and the street-food world's shims (players, animations, interactions, rp_jobs,
-- rp_inventory) come from streetfood_world.lua (SFW); this file adds the cyberware framework (records
-- that survive a restart, staged operations completed by a platform loop, the completion event), the
-- UI kit (menus answered by the test, bars that run their duration or are cancelled), rp_zones,
-- open77_seating, hacking/effects stubs and a JSON encoder.

dofile(COMPAT_DIR .. "/streetfood_world.lua")

RDW = {}

-- ---------------------------------------------------------------------------------------------
-- A small JSON encoder (the server has `json.encode`; the compat decoder has no encoder).
-- ---------------------------------------------------------------------------------------------
local function encode(value, depth)
    depth = depth or 0
    if depth > 20 then error("json: too deep", 0) end
    local t = type(value)
    if value == nil then return "null" end
    if t == "boolean" then return value and "true" or "false" end
    if t == "number" then
        if value ~= value or value == math.huge or value == -math.huge then error("json: non-finite", 0) end
        if math.type(value) == "integer" or (value % 1 == 0 and math.abs(value) < 2 ^ 53) then
            return ("%d"):format(math.floor(value))
        end
        return ("%.14g"):format(value)
    end
    if t == "string" then
        return '"' .. value:gsub('[%c"\\]', function(c)
            local map = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
            return map[c] or ("\\u%04x"):format(c:byte())
        end) .. '"'
    end
    if t == "table" then
        local n = #value
        local isArray = n > 0
        if isArray then
            for k in pairs(value) do if type(k) ~= "number" then isArray = false break end end
        end
        local parts = {}
        if isArray then
            for i = 1, n do parts[i] = encode(value[i], depth + 1) end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        local keys = {}
        for k in pairs(value) do keys[#keys + 1] = tostring(k) end
        table.sort(keys)
        for _, k in ipairs(keys) do
            local v = value[k]
            if v == nil then v = value[tonumber(k)] end
            parts[#parts + 1] = encode(k, depth + 1) .. ":" .. encode(v, depth + 1)
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    error("json: cannot encode " .. t, 0)
end
RDW.encode = encode

-- ---------------------------------------------------------------------------------------------
-- Platform fakes added to every resource (after SFW.PATCH).
-- ---------------------------------------------------------------------------------------------
RDW.PATCH = [==[
local W = HOST.shared.world
local CW = HOST.shared.cw
local NAME = GetCurrentResourceName()

json = { encode = RDW_ENCODE, decode = function(text)
    local ok, v = pcall(CompatJson.decode, text)
    if ok then return v end
    return nil
end }

local function copy(t)
    if type(t) ~= "table" then return t end
    local out = {}
    for k, v in pairs(t) do out[k] = copy(v) end
    return out
end

-- Profiles the "server catalogue" knows (Open77.animations.get).
Open77.animations.get = function(profile)
    if W.knownProfiles[profile] then return { id = profile, clip = profile .. "_clip", clips = { profile .. "_clip" } } end
    return nil
end

Open77.hacking = {
    define = function(def) if CW.hackingDown then return nil, "hacking_unavailable" end return { ok = true } end,
    defineIce = function(def) if CW.hackingDown then return nil, "hacking_unavailable" end return { ok = true } end,
    definePurge = function(def) if CW.hackingDown then return nil, "hacking_unavailable" end return { ok = true } end,
}

Open77.effects = {
    screen = function(pid, effect, options)
        W.screens[#W.screens + 1] = { pid = pid, effect = effect, owner = NAME }
        return true
    end,
}

-- The cyberware framework: one record per character (keyed by the account identifier, so it
-- survives a disconnect and a restart), staged operations completed by the platform loop.
local function recordOf(pid)
    local p = HOST.players[tonumber(pid)]
    if not p then return nil end
    local rec = CW.records[p.identifier]
    if not rec then
        rec = { revision = 0, operationId = "" }
        CW.records[p.identifier] = rec
    end
    return rec, p.identifier
end

local function validId(id) return type(id) == "string" and #id >= 1 and #id <= 96 and id:match("^[%w_%.:%-]+$") ~= nil end

local function stage(pid, implant, slot, options)
    local rec, identifier = recordOf(pid)
    if not rec then return nil, "player_unavailable" end
    if type(options) ~= "table" or not validId(options.operationId) then return nil, "invalid_request" end
    if CW.notReady[tonumber(pid)] then return nil, "cyberware_not_ready" end
    if rec.operationId == options.operationId then
        local prior = rec[slot]
        local same = slot == rec.operationSlot and options.expectedRevision == rec.revision - 1 and
            ((implant == nil and prior == nil) or (implant ~= nil and prior ~= nil and prior.definition == implant.definition
                and prior.grade.id == implant.grade.id))
        if same then
            CW.replays = CW.replays + 1
            return { ok = true }
        end
        return nil, "operation_conflict"
    end
    if CW.pending[identifier] then return nil, "character_busy" end
    if rec.revision ~= options.expectedRevision then return nil, "revision_conflict" end
    CW.seq = CW.seq + 1
    local ticket = "cw" .. CW.seq
    CW.pending[identifier] = ticket
    CW.staged[ticket] = { pid = tonumber(pid), identifier = identifier, slot = slot, implant = implant,
        operationId = options.operationId, at = HOST.now + CW.delay, owner = NAME }
    CW.submits[#CW.submits + 1] = { pid = tonumber(pid), slot = slot, definition = implant and implant.definition,
        operationId = options.operationId, owner = NAME }
    return { ok = true, ticket = ticket }
end

Open77.cyberware = {
    define = function(def)
        if type(def) ~= "table" or not validId(def.id) then return nil, "invalid_definition" end
        CW.defs[def.id] = copy(def)
        return { ok = true }
    end,
    current = function(pid)
        if CW.notReady[tonumber(pid)] then return nil end
        local rec = recordOf(pid)
        return rec and copy(rec) or nil
    end,
    install = function(pid, definition, grade, options)
        local def = CW.defs[definition]
        if not def then return nil, "definition_unavailable" end
        local g
        for _, x in ipairs(def.grades) do if x.id == grade then g = x end end
        if not g then return nil, "grade_unavailable" end
        local implant = { instanceId = "i" .. (CW.seq + 1), definition = definition, definitionVersion = def.version,
            profile = def.profile, slot = def.slot, grade = copy(g) }
        return stage(pid, implant, def.slot, options)
    end,
    remove = function(pid, options)
        local slot = type(options) == "table" and options.slot or "arms"
        return stage(pid, nil, slot, options)
    end,
    cancel = function(pid, ticket)
        local op = CW.staged[ticket]
        if not op then return nil, "stale_projection" end
        if op.owner ~= NAME then return nil, "operation_owned" end
        if CW.saving then return nil, "operation_committing" end
        CW.staged[ticket] = nil
        CW.pending[op.identifier] = nil
        CW.cancels = CW.cancels + 1
        TriggerEvent("onCyberwareOperationCompleted", tostring(op.pid), ticket, RDW_ENCODE({ ok = false, error = "operation_cancelled" }))
        return { ok = true, ticket = ticket }
    end,
    newOperationId = function()
        CW.seq = CW.seq + 1
        return ("%032x"):format(CW.seq)
    end,
}
]==]

-- The cyberware platform loop: completes staged operations after `CW.delay` seconds. `CW.mode`:
-- "ok" (default), "fail" (the native projection fails), "hang" (never answers). `CW.holdEvent`
-- commits the record but keeps the completion event (a resource that died in between never hears it).
RDW.CYBERWARE = [==[
local CW = HOST.shared.cw
CreateThread(function()
    while true do
        local tickets = {}
        for t in pairs(CW.staged) do tickets[#tickets + 1] = t end
        table.sort(tickets)
        for _, ticket in ipairs(tickets) do
            local op = CW.staged[ticket]
            if op and HOST.now >= op.at and CW.mode ~= "hang" then
                CW.staged[ticket] = nil
                CW.pending[op.identifier] = nil
                local result
                if not HOST.players[op.pid] then
                    result = { ok = false, error = "player_unavailable", ticket = ticket }
                elseif CW.mode == "fail" then
                    result = { ok = false, error = "native_projection_failed", ticket = ticket }
                else
                    local rec = CW.records[op.identifier]
                    rec.revision = rec.revision + 1
                    rec.operationId = op.operationId
                    rec.operationSlot = op.slot
                    rec[op.slot] = op.implant
                    CW.commits = CW.commits + 1
                    result = { ok = true, ticket = ticket }
                end
                if CW.holdEvent then
                    CW.held[#CW.held + 1] = { pid = op.pid, ticket = ticket, result = result }
                else
                    TriggerEvent("onCyberwareOperationCompleted", tostring(op.pid), ticket, RDW_ENCODE(result))
                end
            end
        end
        Wait(0)
    end
end)
-- A stopped resource's staged (not yet saving) operations are rolled back.
AddEventHandler("onResourceStop", function(name)
    for ticket, op in pairs(CW.staged) do
        if op.owner == name then
            CW.staged[ticket] = nil
            CW.pending[op.identifier] = nil
        end
    end
end)
]==]

-- The UI kit's server twins. `UI.picks[pid]` answers the next menu (an option id, or false for
-- Escape); a bar runs its duration unless `UI.cancel[pid]` is set (X) or `close` is called.
RDW.UIKIT = [==[
local UI = HOST.shared.ui
exports("context", function(pid, def)
    UI.menus[#UI.menus + 1] = { pid = pid, def = def, caller = GetInvokingResource() }
    Wait(250)
    local pick = UI.picks[pid]
    UI.picks[pid] = nil
    if pick == nil or pick == false then return { ok = false, outcome = "cancelled" } end
    for _, o in ipairs(def.options or {}) do
        if o.id == pick then
            if o.disabled then return { ok = false, outcome = "cancelled" } end
            return { ok = true, outcome = "ok", value = { id = pick } }
        end
    end
    return { ok = false, outcome = "cancelled" }
end)
exports("progress", function(pid, def)
    local bar = { pid = pid, label = def.label, duration = def.duration, caller = GetInvokingResource(), closed = false }
    UI.bars[#UI.bars + 1] = bar
    UI.open[pid] = bar
    local untilT = HOST.now + (def.duration or 0) / 1000
    while HOST.now < untilT do
        if bar.closed then return { ok = false, outcome = "cancelled" } end
        if UI.cancel[pid] then
            UI.cancel[pid] = nil
            bar.cancelled = true
            if UI.open[pid] == bar then UI.open[pid] = nil end
            return { ok = false, outcome = "cancelled" }
        end
        Wait(100)
    end
    if UI.open[pid] == bar then UI.open[pid] = nil end
    bar.done = true
    return { ok = true, outcome = "ok" }
end)
exports("close", function(pid)
    UI.closes[#UI.closes + 1] = pid
    local bar = UI.open[pid]
    if bar then bar.closed = true; UI.open[pid] = nil end
    return { ok = true }
end)
]==]

RDW.ZONES = [==[
local Z = { viktor_clinic = { x = -1548.0, y = 1230.0, z = 11.6, r = 12.0 } }
exports("isIn", function(pid, name)
    local zone = Z[name]
    local p = HOST.players[tonumber(pid)]
    if not zone or not p or not p.position then return false end
    local dx, dy = p.position.x - zone.x, p.position.y - zone.y
    return math.sqrt(dx * dx + dy * dy) <= zone.r
end)
]==]

-- rp_jobs: the street-food world's B4 shim plus the read exports rp_ripperdoc uses.
RDW.JOBS_EXTRA = [==[
local J = HOST.shared.jobs
exports("listOnDuty", function(job)
    local out = {}
    for pid, r in pairs(J.players) do if r.job == job and r.duty and HOST.players[pid] then out[#out + 1] = pid end end
    table.sort(out)
    return out
end)
exports("getGrade", function(pid)
    local r = J.players[tonumber(pid)]
    return r and { level = r.grade, label = "grade " .. tostring(r.grade) } or nil
end)
]==]

-- open77_seating: one session per player on a furniture id; seated / stood events.
RDW.SEATING = [==[
local SEAT = HOST.shared.seating
exports("current", function(pid)
    local s = SEAT.sessions[tonumber(pid)]
    return s and { playerId = tonumber(pid), furnitureId = s.furnitureId, spot = s.spot } or nil
end)
exports("sit", function(pid, furnitureId, options)
    pid = tonumber(pid)
    if SEAT.sessions[pid] then return nil, "already_seated" end
    for other, s in pairs(SEAT.sessions) do
        if s.furnitureId == tostring(furnitureId) then return nil, "target_claimed" end
    end
    SEAT.sessions[pid] = { furnitureId = tostring(furnitureId), spot = options and options.spot }
    SEAT.log[#SEAT.log + 1] = { op = "sit", pid = pid, furnitureId = tostring(furnitureId), caller = GetInvokingResource() }
    TriggerEvent("open77_seating:seated", { playerId = pid, furnitureId = tostring(furnitureId) })
    return { playerId = pid, furnitureId = tostring(furnitureId) }
end)
exports("stand", function(pid)
    pid = tonumber(pid)
    local s = SEAT.sessions[pid]
    if not s then return nil, "not_seated" end
    SEAT.sessions[pid] = nil
    SEAT.log[#SEAT.log + 1] = { op = "stand", pid = pid, caller = GetInvokingResource() }
    TriggerEvent("open77_seating:stood", { playerId = pid, furnitureId = s.furnitureId, reason = "stood" })
    return true
end)
]==]

-- A probe: records the job events and transitions; mints test money and items (its own mint rules).
RDW.PROBE = [==[
AddEventHandler("open77_actions:transition", function(op)
    HOST.shared.transitions[#HOST.shared.transitions + 1] = op
end)
AddEventHandler("rp:job:completed", function(e)
    HOST.shared.jobEvents[#HOST.shared.jobEvents + 1] = e
end)
AddEventHandler("rp_ripperdoc:operation", function(ripper, patient, action, key, grade, price)
    HOST.shared.operations[#HOST.shared.operations + 1] = { ripper = ripper, patient = patient, action = action, key = key }
end)
]==]

-- ---------------------------------------------------------------------------------------------
-- Boot
-- ---------------------------------------------------------------------------------------------
RDW.WRITERS_STRICT = "rp_ripperdoc:cash+bank+soc+char+stash/stock, rp_economy:cash+bank+soc, rp_inventory, rd_probe"
RDW.MINT_RULES = "rp_ripperdoc sys:ripperdoc.supplier * 1000; rp_inventory sys:* * 100000; " ..
    "rp_economy sys:* money 100000000; rd_probe sys:* * 100000; rd_probe sys:* money 100000000"

local function globals()
    return { json = { decode = CompatJson.decode, encode = encode }, CompatJson = CompatJson, ROOT_DIR = ROOT_DIR,
        RDW_ENCODE = encode }
end

local function startWith(name, scripts)
    local list = { { source = SFW.PATCH, name = "patch_" .. name .. ".lua" }, { source = RDW.PATCH, name = "rdpatch_" .. name .. ".lua" } }
    for _, s in ipairs(scripts) do list[#list + 1] = s end
    return MH.start(name, list, { host = true, globals = globals() })
end
RDW.startWith = startWith

local function shim(name, source) return startWith(name, { { source = source, name = name .. "_shim.lua" } }) end
RDW.shim = shim

-- rp_ripperdoc's server scripts in manifest order; `opts.configPatch` (Lua source) runs right after
-- the shared config (a test's operator settings).
function RDW.startRipper(opts)
    opts = opts or RDW.ripperOpts or {}
    local scripts = SFW.scripts(ROOT_DIR .. "/rp_ripperdoc")
    local out = {}
    for _, path in ipairs(scripts) do
        out[#out + 1] = path
        if path:find("shared/config%.lua$") and opts.configPatch then
            out[#out + 1] = { source = opts.configPatch, name = "config_patch.lua" }
        end
    end
    return startWith("rp_ripperdoc", out)
end

function RDW.freshShared()
    return {
        world = { props = {}, propSeq = 0, playing = {}, played = {}, playbackSeq = 0, bags = {}, toasts = {},
            client = {}, held = {}, heldSeq = 0, heldLog = {}, ix = {}, ixSeq = 0, ixLog = {}, reserved = {},
            badProfiles = {}, screens = {},
            knownProfiles = { lie = true, bedsidelie = true, seatedsleep = true, amb_6862d5_stand_use_driller = true,
                amb_2bfab5_stand_table_fryer = true, repair = true, mechanic = true,
                tablet2 = true, phone = true, examine = true } },
        jobs = { players = {}, seq = 100 },
        cw = { records = {}, defs = {}, staged = {}, pending = {}, seq = 0, delay = 1.0, mode = "ok", held = {},
            notReady = {}, submits = {}, commits = 0, replays = 0, cancels = 0 },
    }
end

-- The database: the wallet world's 1.x tables plus rp_ripperdoc's history table.
function RDW.sql(kind, sql, p, resource)
    local text = sql:gsub("^%s+", "")
    if text:find("^INSERT INTO rp_ripperdoc_operations") then
        local db = MH.shared.db
        db.ripperdocOps = db.ripperdocOps or {}
        db.ripperdocOps[#db.ripperdocOps + 1] = { ripper = p[1], patient = p[3], implant = p[5], grade = p[6],
            action = p[7], price = p[8], paidVia = p[9], at = p[10] }
        return #db.ripperdocOps
    end
    return WW.sql(kind, sql, p, resource)
end

-- opts: keep (RDW.keep()), writers, mint, configPatch, seating (start the open77_seating shim)
function RDW.boot(opts)
    opts = opts or {}
    RDW.ripperOpts = { configPatch = opts.configPatch }
    MH.reset()
    MH.sql = RDW.sql
    local fresh = RDW.freshShared()
    if opts.keep then
        MH.now = opts.keep.now + 60
        MH.shared.txStore, MH.shared.db, MH.kvp = opts.keep.store, opts.keep.db, opts.keep.kvp
        MH.shared.world, MH.shared.jobs, MH.shared.cw = opts.keep.world, opts.keep.jobs, opts.keep.cw
        local W = MH.shared.world
        W.props, W.playing, W.client, W.held, W.ix, W.reserved = {}, {}, {}, {}, {}, {}
        for _, r in pairs(MH.shared.jobs.players) do r.duty = false end
        MH.shared.cw.staged, MH.shared.cw.pending = {}, {}
    else
        MH.shared.txStore = nil
        MH.shared.db = WW.freshDb()
        MH.shared.world, MH.shared.jobs, MH.shared.cw = fresh.world, fresh.jobs, fresh.cw
    end
    MH.shared.ui = { picks = {}, cancel = {}, menus = {}, bars = {}, open = {}, closes = {} }
    MH.shared.seating = { sessions = {}, log = {} }
    MH.shared.needs, MH.shared.moves = {}, {}
    MH.shared.transitions, MH.shared.jobEvents, MH.shared.operations = {}, {}, {}
    MH.shared.tunables = {
        open77_transactions = { store = "lab_kvp", serverTag = "lab", writers = opts.writers or "*",
            mint1 = opts.mint or RDW.MINT_RULES },
    }
    MH.convars.open77_transactions_lab = "1"
    MH.convars.sv_masterServerEnabled = "false"
    MH.convars.open77_actions_trace = "1"
    startWith("open77_transactions", {
        TX_DIR .. "/shared/model.lua", TX_DIR .. "/server/policy.lua", TX_DIR .. "/server/memory_store.lua",
        TX_DIR .. "/server/sql_store.lua", TX_DIR .. "/server/coordinator.lua",
        { source = SFW.TXSTORE, name = "txstore_shim.lua" }, TX_DIR .. "/server/main.lua",
        { source = SFW.TXPUMP, name = "txpump_shim.lua" },
    })
    shim("open77_player_interactions", SFW.PLATFORM)
    shim("open77_cyberware", RDW.CYBERWARE)
    shim("open77_uikit", RDW.UIKIT)
    shim("rp_inventory", SFW.INVENTORY)
    shim("rp_jobs", SFW.JOBS .. "\n" .. RDW.JOBS_EXTRA)
    shim("rp_zones", RDW.ZONES)
    if opts.seating then shim("open77_seating", RDW.SEATING) end
    startWith("open77_actions", SFW.scripts(SYS_DIR .. "/open77_actions"))
    startWith("rp_economy", WW.scripts("rp_economy"))
    RDW.startRipper()
    MH.start("rd_probe", { { source = SFW.PATCH, name = "patch_probe.lua" }, { source = RDW.PROBE, name = "probe.lua" } },
        { host = true, globals = globals() })
    MH.until_(function() return RDW.svc() and RDW.svc().ready end, 60)
    MH.run(1)
end

-- What survives a server restart: the database (coordinator store), KVP files, the job registry,
-- the cyberware records; not runtime props, interactions, duty or staged operations.
function RDW.keep()
    return { store = MH.shared.txStore, db = MH.shared.db, kvp = MH.kvp, now = MH.now,
        world = MH.shared.world, jobs = MH.shared.jobs, cw = MH.shared.cw }
end

-- A restart of rp_ripperdoc alone (ensure rp_ripperdoc).
function RDW.restartRipper()
    MH.stop("rp_ripperdoc")
    MH.run(0.5)
    RDW.startRipper()
    MH.until_(function() return RDW.svc() and RDW.svc().ready end, 60)
    MH.run(1)
end

function RDW.svc() local R = MH.resources.rp_ripperdoc return R and R.running and R.env.RipperRuntime and R.env.RipperRuntime.service end
function RDW.cfg() return MH.resources.rp_ripperdoc.env.RpRipperConfig end
function RDW.store() return MH.shared.txStore end
function RDW.cw() return MH.shared.cw end
function RDW.ui() return MH.shared.ui end

-- ---------------------------------------------------------------------------------------------
-- Players
-- ---------------------------------------------------------------------------------------------
RDW.join = SFW.join
RDW.move = SFW.move
RDW.kill = SFW.kill

function RDW.disconnect(id)
    MH.emit("onPlayerDisconnected", id)
    MH.players[id] = nil
    MH.run(0.5)
end

-- The ripper job + duty, as the lab console does.
function RDW.setupRipper(pid)
    MH.command("ripper.setup", 0, { tostring(pid) })
    MH.run(1)
end

function RDW.clock(pid, on)
    MH.callSync("rd_probe", "rp_jobs", "setDuty", pid, on, { job = "ripper" })
    MH.run(1)
end

-- Money and items for the test, minted by the probe (its own mint rules).
function RDW.grant(lines, opId)
    return MH.callAsync("rd_probe", "open77_transactions", "transfer", { opId = opId or ("probe.grant." .. tostring(MH.now) .. "." .. #lines),
        kind = "probe", lines = lines })
end

function RDW.giveMoney(account, amount, tag)
    return RDW.grant({ { money = amount, from = "sys:probe", to = account } }, "probe.money." .. account .. "." .. (tag or tostring(MH.now)))
end

function RDW.seed(item, count)
    MH.command("ripper.seed", 0, { "viktor", item or "all", tostring(count or 1) })
    MH.run(3)
end

-- A player runs a chat command.
function RDW.say(pid, args)
    MH.command("ripper", pid, args)
end

-- ---------------------------------------------------------------------------------------------
-- Driving the libraries like a client would
-- ---------------------------------------------------------------------------------------------
RDW.intent = SFW.intent
RDW.clientCancel = SFW.clientCancel
RDW.respond = SFW.respond

function RDW.mark() return #(MH.shared.transitions or {}) end
RDW.finish = SFW.finish
RDW.waitState = SFW.waitState

-- The open quote / buy-back offer of a ripper (the platform interaction), or nil.
function RDW.offerOf(ripperPid) return SFW.offerOf(ripperPid) end

function RDW.answer(ripperPid, accepted, seconds)
    local id = SFW.offerOf(ripperPid)
    if not id then return nil end
    SFW.respond(id, accepted)
    MH.run(seconds or 3)
    return id
end

-- The operate action's current op of a player (from the transitions), or nil.
function RDW.lastOp(pid, actionId)
    local list = MH.shared.transitions or {}
    for i = #list, 1, -1 do
        local op = list[i]
        if op.playerId == pid and (actionId == nil or op.actionId == actionId) then return op end
    end
    return nil
end

function RDW.told(pid, pattern)
    for _, t in ipairs(MH.shared.world.toasts) do
        if t.pid == pid and t.resource == "rp_ripperdoc" and tostring(t.text):find(pattern) then return true end
    end
    for _, c in ipairs(MH.chat) do
        local text = type(c.message) == "table" and c.message.text or c.message
        if c.target == pid and c.resource == "rp_ripperdoc" and tostring(text):find(pattern) then return true end
    end
    return false
end

function RDW.printed(pattern)
    local n = 0
    for _, line in ipairs(MH.logs) do
        if line:find("^%[rp_ripperdoc%]") and line:find(pattern) then n = n + 1 end
    end
    return n
end

-- ---------------------------------------------------------------------------------------------
-- Durable truth
-- ---------------------------------------------------------------------------------------------
function RDW.count(account, item) return RDW.store():count(account, item) end
function RDW.balance(account) return RDW.store():balance(account) end
RDW.journal = SFW.journal
RDW.unbalanced = SFW.unbalanced
RDW.committed = SFW.committed

function RDW.record(identifier) return MH.shared.cw.records[identifier] end

function RDW.jobEvents(kind)
    local out = {}
    for _, e in ipairs(MH.shared.jobEvents or {}) do
        if kind == nil or e.kind == kind then out[#out + 1] = e end
    end
    return out
end

function RDW.journalRows()
    local n = 0
    for key in pairs(MH.kvp.rp_ripperdoc or {}) do
        if key:sub(1, 8) == "surgery:" then n = n + 1 end
    end
    return n
end

-- The coordinator's view of an operation (reserved holds are not in the store yet).
function RDW.status(opId)
    return MH.callAsync("rd_probe", "open77_transactions", "status", opId)
end

RDW.result = SFW.result
