-- tests/compat/fixer_world.lua: the fixer contract board's offline world (rp_fixer 2.0), on
-- multihost.lua through streetfood_world.lua (its platform fakes and shims are reused as is).
--
-- String globals from the runner: ROOT_DIR (this pack), COMPAT_DIR (this folder), SYS_DIR (the
-- Open77 `resources/system` folder holding open77_actions) and TX_DIR (open77_transactions).
--
-- What runs for real: open77_transactions (deferred memory store = the database), open77_actions
-- (engine, claims, carry), rp_economy (the wallet facade, every eddy) and rp_fixer. Shims stand in
-- for the public exports of rp_jobs, rp_inventory and the open77_uikit server twins (a scenario
-- scripts the player's answers). Fakes defined here: server NPCs (create / remove / get / attitude /
-- tasks, a kill that raises onNpcDied host-wide), Open77.players.positions, the `json` global, and
-- rp_fixer's SQL tables (an interpreter of the statements server/store.lua sends, with the
-- transaction rollback the platform documents).

dofile(COMPAT_DIR .. "/streetfood_world.lua")

FXW = {}

-- ---------------------------------------------------------------------------------------------
-- JSON (the platform's `json` global; the decoder is CompatJson's)
-- ---------------------------------------------------------------------------------------------
local function encodeString(s)
    return '"' .. s:gsub('[%c"\\]', function(c)
        local map = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
        return map[c] or string.format("\\u%04x", c:byte())
    end) .. '"'
end

local function encode(v, depth)
    depth = depth or 0
    if depth > 32 then error("json: too deep") end
    local t = type(v)
    if t == "nil" then return "null" end
    if t == "boolean" then return v and "true" or "false" end
    if t == "number" then
        if v ~= v or v == math.huge or v == -math.huge then error("json: non-finite number") end
        if math.type(v) == "integer" then return tostring(v) end
        return string.format("%.14g", v)
    end
    if t == "string" then return encodeString(v) end
    if t ~= "table" then error("json: cannot encode " .. t) end
    local n, isArray = 0, true
    for k in pairs(v) do
        if type(k) ~= "number" then isArray = false end
        n = n + 1
    end
    if isArray then
        local parts = {}
        for i = 1, n do
            if v[i] == nil then error("json: sparse array") end
            parts[i] = encode(v[i], depth + 1)
        end
        return "[" .. table.concat(parts, ",") .. "]"
    end
    local keys = {}
    for k in pairs(v) do
        if type(k) ~= "string" then error("json: mixed table") end
        keys[#keys + 1] = k
    end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = encodeString(k) .. ":" .. encode(v[k], depth + 1) end
    return "{" .. table.concat(parts, ",") .. "}"
end
FXW.encode = function(v)
    local ok, out = pcall(encode, v)
    if ok then return out end
    return nil, out
end
FXW.decode = function(s)
    local v = CompatJson.decode(s)
    return v
end

-- ---------------------------------------------------------------------------------------------
-- rp_fixer's SQL tables
-- ---------------------------------------------------------------------------------------------
function FXW.freshDb()
    return { contracts = {}, rep = {}, replog = {}, gigs = {}, failing = false, statements = 0 }
end

local function deepCopy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = deepCopy(x) end
    return out
end

function FXW.sql(kind, sql, p)
    local db = MH.shared.fxdb
    db.statements = db.statements + 1
    if db.failing then error("database_unreachable (SQL 2013): Lost connection to server during query", 0) end
    sql = sql:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
    if sql:find("^CREATE TABLE IF NOT EXISTS") then return 0 end
    if sql == "SELECT MAX(seq) FROM rp_fixer_contracts" then
        local max = nil
        for _, row in pairs(db.contracts) do if not max or row.seq > max then max = row.seq end end
        return max
    end
    if sql == "SELECT id, data FROM rp_fixer_contracts WHERE live = 1 ORDER BY seq LIMIT ?" then
        local rows = {}
        for _, row in pairs(db.contracts) do
            if row.live == 1 then rows[#rows + 1] = { id = row.id, data = row.data, seq = row.seq } end
        end
        table.sort(rows, function(a, b) return a.seq < b.seq end)
        local out = {}
        for i = 1, math.min(#rows, p[1]) do out[i] = { id = rows[i].id, data = rows[i].data } end
        return out
    end
    if sql:find("^INSERT INTO rp_fixer_contracts") then
        db.contracts[p[1]] = { id = p[1], seq = p[2], state = p[3], live = p[4], data = p[5], expires_at = p[6],
            updated_at = p[7] }
        return 1
    end
    if sql == "SELECT score, completed, failed FROM rp_fixer_reputation WHERE identifier = ?" then
        local row = db.rep[p[1]]
        return row and { score = row.score, completed = row.completed, failed = row.failed } or nil
    end
    if sql:find("^INSERT INTO rp_fixer_rep_log") then
        if db.replog[p[1]] then
            error(("database_conflict (SQL 1062): Duplicate entry '%s' for key 'PRIMARY'"):format(p[1]), 0)
        end
        db.replog[p[1]] = { identifier = p[2], delta = p[3], at = p[4] }
        return 1
    end
    if sql:find("^INSERT INTO rp_fixer_reputation") then
        -- values: subject, delta, floor, completed, failed, now, delta, floor, completed, failed, now
        local row = db.rep[p[1]]
        if row then
            row.score = math.max(row.score + p[7], p[8])
            row.completed = row.completed + p[9]
            row.failed = row.failed + p[10]
            row.updated_at = p[11]
        else
            db.rep[p[1]] = { score = math.max(p[2], p[3]), completed = p[4], failed = p[5], updated_at = p[6] }
        end
        return 1
    end
    if sql == "SELECT COUNT(*) FROM rp_fixer_rep_log WHERE event_key = ?" then
        return db.replog[p[1]] and 1 or 0
    end
    if sql:find("^INSERT INTO rp_fixer_gigs") then
        db.gigs[#db.gigs + 1] = { gig_id = p[1], identifier = p[2], player_name = p[3], template = p[4], kind = p[5],
            outcome = p[6], pay = p[7], commission = p[8], publisher = p[9], accepted_at = p[10], ended_at = p[11] }
        return #db.gigs
    end
    error("fixer_world: unexpected SQL: " .. sql, 0)
end

-- Open77.database.transaction.await: every statement or none (the rows are restored on error).
function FXW.transaction(statements, resource)
    local db = MH.shared.fxdb
    local saved = { contracts = deepCopy(db.contracts), rep = deepCopy(db.rep), replog = deepCopy(db.replog),
        gigs = deepCopy(db.gigs) }
    for i, st in ipairs(statements) do
        local ok, err = pcall(MH.sql, "update", st.query, st.values or {}, resource)
        if not ok then
            db.contracts, db.rep, db.replog, db.gigs = saved.contracts, saved.rep, saved.replog, saved.gigs
            MH.logs[#MH.logs + 1] = ("[database] resource '%s' transaction statement %d/%d failed: %s"):format(
                resource, i, #statements, tostring(err))
            return false, tostring(err)
        end
    end
    return true
end

-- ---------------------------------------------------------------------------------------------
-- Platform fakes for rp_fixer (after SFW.PATCH)
-- ---------------------------------------------------------------------------------------------
FXW.PATCH = [==[
local W = HOST.shared.world
local NAME = GetCurrentResourceName()

json = { encode = HOST.shared.jsonEncode, decode = HOST.shared.jsonDecode }

Open77.players.positions = function()
    local out = {}
    for id, p in pairs(HOST.players) do
        if p.position then out[id] = { x = p.position.x, y = p.position.y, z = p.position.z, bucket = p.position.bucket or 0 } end
    end
    return out
end

Open77.database.transaction = {
    await = function(statements)
        Wait(0)
        if HOST.dbMode ~= "sql" then error("database_unavailable", 0) end
        return HOST.shared.sqlTransaction(statements, NAME)
    end,
}
local function copy(t)
    if type(t) ~= "table" then return t end
    local out = {}
    for k, v in pairs(t) do out[k] = copy(v) end
    return out
end

local function owned(id)
    local n = W.npcs[tonumber(id)]
    if not n or n.resource ~= NAME then return nil end
    return n
end

local function task(id, kind, params)
    local n = owned(id)
    if not n then return nil, "npc_not_found" end
    W.taskSeq = W.taskSeq + 1
    n.tasks[#n.tasks + 1] = { id = W.taskSeq, type = kind, params = copy(params) }
    W.npcLog[#W.npcLog + 1] = { op = "task", id = n.id, type = kind, params = copy(params) }
    return W.taskSeq
end

Open77.npcs = {
    damage = { mortal = 0, immortal = 1, invulnerable = 2 },
    ai = { tasks = 0, frozen = 1, native = 2 },
    create = function(def)
        if type(def) ~= "table" then error("bad argument #1 to 'create' (table expected)") end
        if HOST.shared.npcRefuse then return nil, HOST.shared.npcRefuse end
        if def.behavior and def.behavior.hitPricing ~= nil and HOST.shared.noHitPricing then
            return nil, "npc_behavior_unknown_option"
        end
        W.npcSeq = W.npcSeq + 1
        local p = def.position or {}
        W.npcs[W.npcSeq] = { id = W.npcSeq, resource = NAME, record = def.record, template = def.template,
            x = p.x, y = p.y, z = p.z, yaw = def.yaw, bucket = def.bucket or 0,
            health = def.health or 100, maxHealth = def.maxHealth or def.health or 100,
            damagePolicy = def.damagePolicy or 1, behavior = copy(def.behavior), loadout = copy(def.loadout), tasks = {} }
        W.npcLog[#W.npcLog + 1] = { op = "create", id = W.npcSeq, resource = NAME, record = def.record or def.template }
        return W.npcSeq
    end,
    remove = function(id)
        local n = owned(id)
        if not n then return false end
        W.npcs[n.id] = nil
        W.npcLog[#W.npcLog + 1] = { op = "remove", id = n.id, resource = NAME }
        return true
    end,
    get = function(id)
        local n = owned(id)
        if not n then return nil end
        return { id = n.id, resource = n.resource, record = n.record, x = n.x, y = n.y, z = n.z, bucket = n.bucket,
            health = n.health, maxHealth = n.maxHealth, damagePolicy = n.damagePolicy, behavior = copy(n.behavior) }
    end,
    setAttitude = function(id, attitude, options)
        local n = owned(id)
        if not n then return false, "npc_not_found" end
        n.attitude = attitude
        return true
    end,
    tasks = {
        guard = function(id, position, radius, options) return task(id, "guard", { position = position, radius = radius }) end,
        attack = function(id, target, options)
            local n = owned(id)
            if n then n.attacking = target end
            return task(id, "attack", { target = target })
        end,
        hold = function(id) return task(id, "hold", {}) end,
    },
}

AddEventHandler("onResourceStop", function(name)
    if name ~= NAME then return end
    for id, n in pairs(W.npcs) do if n.resource == NAME then W.npcs[id] = nil end end
end)
]==]

-- The open77_uikit server twins: the scenario answers for the player (MH.shared.uiAnswer).
FXW.UIKIT = [==[
local function ask(kind, pid, def)
    HOST.shared.ui[#HOST.shared.ui + 1] = { kind = kind, pid = pid, def = def }
    Wait(0)
    local answer = HOST.shared.uiAnswer
    if not answer then return { ok = false, outcome = "cancelled" } end
    return answer(kind, pid, def)
end
exports("context", function(pid, def) return ask("context", pid, def) end)
exports("alert", function(pid, def) return ask("alert", pid, def) end)
exports("input", function(pid, def) return ask("input", pid, def) end)
]==]

-- rp_inventory: SFW's shim plus the item definition read rp_fixer asks for.
FXW.INVENTORY = SFW.INVENTORY .. [==[
exports("itemDefinition", function(item)
    local d = defs[item]
    if not d then return nil, "unknown_item" end
    return { id = item, label = d.label, weightG = math.floor((d.weight or 0) * 1000 + 0.5) }
end)
]==]

-- ---------------------------------------------------------------------------------------------
-- Boot
-- ---------------------------------------------------------------------------------------------
FXW.WRITERS_STRICT = "rp_fixer:char+stash, rp_economy:cash+bank+soc, rp_inventory"
FXW.MINT_RULES = "rp_economy sys:* money 100000000; rp_inventory sys:* * 100000"
FXW.ITEMS = {
    chip = { label = "Data chip", weight = 0.05 },
    component = { label = "Component", weight = 0.5 },
    chooh2_canister = { label = "CHOOH2 canister", weight = 5.0 },   -- rp_chooh2's refinery output
    implant_box_arms = { label = "Implant box: Gorilla Arms (Street)", weight = 2.0 },
}

-- The UI answers: a queue per player of { kind, value } / { kind, fn = function(def) -> answer }.
function FXW.answerer(kind, pid, def)
    local q = MH.shared.uiQueue[pid]
    local nextAnswer = q and table.remove(q, 1)
    if not nextAnswer then
        MH.shared.uiUnanswered = (MH.shared.uiUnanswered or 0) + 1
        return { ok = false, outcome = "cancelled" }
    end
    if nextAnswer.kind ~= kind then
        MH.shared.uiMismatch = (MH.shared.uiMismatch or "") .. ("%s instead of %s; "):format(kind, nextAnswer.kind)
        return { ok = false, outcome = "cancelled" }
    end
    if nextAnswer.fn then return nextAnswer.fn(def) end
    if nextAnswer.cancel then return { ok = false, outcome = "cancelled" } end
    return { ok = true, outcome = "ok", value = nextAnswer.value }
end

function FXW.script(pid, answers)
    MH.shared.uiQueue[pid] = MH.shared.uiQueue[pid] or {}
    for _, a in ipairs(answers) do table.insert(MH.shared.uiQueue[pid], a) end
end

local function freshWorld()
    return { props = {}, propSeq = 0, playing = {}, played = {}, playbackSeq = 0, bags = {}, toasts = {},
        client = {}, held = {}, heldSeq = 0, heldLog = {}, ix = {}, ixSeq = 0, ixLog = {}, reserved = {},
        badProfiles = {}, npcs = {}, npcSeq = 1000, npcLog = {}, taskSeq = 0 }
end

function FXW.startFixer()
    local list = { { source = FXW.PATCH, name = "fixer_patch.lua" } }
    for _, s in ipairs(SFW.scripts(ROOT_DIR .. "/rp_fixer")) do list[#list + 1] = s end
    return SFW.startWith("rp_fixer", list)
end

-- opts: keep (FXW.keep()), writers, mint, noUikit, noHitPricing, dbFailing
function FXW.boot(opts)
    opts = opts or {}
    MH.reset()
    MH.sql = function(kind, sql, p, resource)
        if resource == "rp_fixer" then return FXW.sql(kind, sql, p) end
        return WW.sql(kind, sql, p)
    end
    if opts.keep then
        MH.now = opts.keep.now + 60
        MH.shared.txStore, MH.shared.db, MH.shared.fxdb, MH.kvp = opts.keep.store, opts.keep.db, opts.keep.fxdb, opts.keep.kvp
        MH.shared.world, MH.shared.jobs = opts.keep.world, opts.keep.jobs
        local W = MH.shared.world
        W.props, W.playing, W.client, W.held, W.ix, W.reserved, W.npcs = {}, {}, {}, {}, {}, {}, {}
        for _, r in pairs(MH.shared.jobs.players) do r.duty = false end
    else
        MH.shared.txStore = nil
        MH.shared.db = WW.freshDb()
        MH.shared.fxdb = FXW.freshDb()
        MH.shared.world = freshWorld()
        MH.shared.jobs = { players = {}, seq = 100 }
    end
    MH.shared.needs, MH.shared.moves = {}, {}
    MH.shared.ui, MH.shared.uiQueue, MH.shared.uiAnswer = {}, {}, FXW.answerer
    MH.shared.jsonEncode, MH.shared.jsonDecode = FXW.encode, FXW.decode
    MH.shared.sqlTransaction = FXW.transaction
    MH.shared.noHitPricing = opts.noHitPricing
    MH.shared.tunables = {
        open77_transactions = { store = "lab_kvp", serverTag = "lab", writers = opts.writers or "*",
            mint1 = opts.mint or FXW.MINT_RULES },
    }
    MH.convars.open77_transactions_lab = "1"
    MH.convars.sv_masterServerEnabled = "false"
    MH.convars.open77_actions_trace = "1"
    MH.dbMode = "sql"
    SFW.startCoordinator()
    SFW.shim("rp_inventory", FXW.INVENTORY)
    SFW.shim("rp_jobs", SFW.JOBS)
    if not opts.noUikit then SFW.shim("open77_uikit", FXW.UIKIT) end
    SFW.startActions()
    SFW.startEconomy()
    FXW.watch()
    MH.run(1)
    SFW.sync("fx_probe", "rp_inventory", "define", opts.items or FXW.ITEMS)
    FXW.startFixer()
    MH.until_(function() return FXW.svc() and FXW.svc().ready end, 60)
    -- Most scenarios want a quiet board: the NPC fixers post only when a scenario asks them to.
    if not opts.npcBoard and FXW.svc() then FXW.cfg().npcBoard.enabled = false end
    MH.run(1)
end

-- What survives a server restart: the databases (coordinator store, wallet tables, rp_fixer's
-- tables), KVP files and the job registry; not runtime props, NPCs, carries or duty.
function FXW.keep()
    return { store = MH.shared.txStore, db = MH.shared.db, fxdb = MH.shared.fxdb, kvp = MH.kvp, now = MH.now,
        world = MH.shared.world, jobs = MH.shared.jobs }
end

function FXW.svc()
    local R = MH.resources.rp_fixer
    return R and R.running and R.env.FixerRuntime and R.env.FixerRuntime.service or nil
end
function FXW.cfg() return MH.resources.rp_fixer.env.FixerConfig end
function FXW.contract(seq) local s = FXW.svc() return s and s:find(seq) end

function FXW.watch()
    MH.start("fx_probe", { { source = [==[
AddEventHandler("open77_actions:transition", function(op)
    HOST.shared.transitions[#HOST.shared.transitions + 1] = op
end)
AddEventHandler("rp_fixer:contract", function(id, state, pid)
    HOST.shared.fxEvents[#HOST.shared.fxEvents + 1] = { id = id, state = state, pid = pid }
end)
AddEventHandler("rp_fixer:gig", function(seq, phase, pid)
    HOST.shared.gigEvents[#HOST.shared.gigEvents + 1] = { seq = seq, phase = phase, pid = pid }
end)
AddEventHandler("rp:job:completed", function(p)
    HOST.shared.jobEvents[#HOST.shared.jobEvents + 1] = p
end)
]==], name = "fx_probe.lua" } }, { host = true })
    MH.shared.transitions, MH.shared.fxEvents, MH.shared.gigEvents, MH.shared.jobEvents = {}, {}, {}, {}
end

-- ---------------------------------------------------------------------------------------------
-- Players, money, items
-- ---------------------------------------------------------------------------------------------
function FXW.join(id, identifier, name, position)
    SFW.join(id, identifier, name, position)
    MH.until_(function()
        local s = FXW.svc()
        return s and s.players[id] ~= nil and s.reps[identifier] ~= nil
    end, 30)
    WW.settle(10)
end

function FXW.give(pid, amount)
    MH.command("givemoney", 0, { tostring(pid), tostring(amount) })
    WW.settle(10)
end

function FXW.giveItem(pid, item, count)
    local receipt, why = MH.callAsync("fx_probe", "rp_inventory", "addAsync", pid, item, count, nil,
        { opId = "fx.lab.give." .. pid .. "." .. item .. "." .. MH.now })
    return receipt, why
end

function FXW.setJob(pid, job, duty)
    SFW.sync("fx_probe", "rp_jobs", "setJob", pid, job, 0)
    if duty then SFW.sync("fx_probe", "rp_jobs", "setDuty", pid, true) end
end

function FXW.setRep(identifier, score)
    MH.shared.fxdb.rep[identifier] = { score = score, completed = 0, failed = 0, updated_at = 0 }
end

function FXW.balance(account) return SFW.store():balance(account) end

-- What rp_fixer's own operations (ids "fixer.*") moved on one account, in sum (paydays and other
-- jobs left out).
function FXW.fixerDelta(account, asset)
    local total = 0
    for _, e in ipairs(SFW.store().journal) do
        if e.account == account and e.asset == (asset or "money") and tostring(e.opId):find("^fixer%.") then
            total = total + e.delta
        end
    end
    return total
end
function FXW.count(account, item) return SFW.store():count(account, item) end

function FXW.hub(key) return FXW.cfg().hubs[key].position end
function FXW.point(key) return FXW.cfg().points[key].position end
function FXW.sighting(key) return FXW.cfg().sightings[key].position end

-- A prompt choice on a fixer point, then its outcome.
function FXW.board(pid, hub) return SFW.act(pid, "rp_fixer:board", "rp_fixer:hub_" .. hub, "board", 20) end
function FXW.handover(pid, hub) return SFW.act(pid, "rp_fixer:handover", "rp_fixer:hub_" .. hub, "handover", 30) end

function FXW.crateOf(c)
    local s = FXW.svc()
    local rt = s and s.rt[c.id]
    return rt and rt.crate or nil
end

function FXW.pickup(pid, c)
    local itemId = FXW.crateOf(c)
    if not itemId then return nil end
    return SFW.act(pid, "open77_actions:carry_pickup", "item:" .. itemId, "carry_pickup", 30)
end

function FXW.deliver(pid, drop)
    return SFW.act(pid, "open77_actions:carry_putdown", "rp_fixer:drop_" .. drop, "carry_putdown", 30)
end

function FXW.npcOf(c)
    local s = FXW.svc()
    local rt = s and s.rt[c.id]
    return rt and rt.npc or nil
end

function FXW.npc(id) return MH.shared.world.npcs[id] end

-- A player's kill as the platform reports it (hitPricing = "platform": source "player:<id>").
function FXW.kill(npcId, source)
    local n = MH.shared.world.npcs[npcId]
    if n then n.health = 0 end
    MH.emit("onNpcDied", tostring(npcId), source or "", "player_hit")
end

function FXW.damage(npcId, source, amount)
    local n = MH.shared.world.npcs[npcId]
    if n then n.health = math.max(0, n.health - amount) end
    MH.emit("onNpcDamaged", tostring(npcId), source, tostring(amount), tostring(n and n.health or 0), "player_hit")
end

-- Whether a player was told something matching a Lua pattern (chat line or toast of rp_fixer).
function FXW.told(pid, pattern)
    for _, t in ipairs(MH.shared.world.toasts) do
        if t.pid == pid and t.resource == "rp_fixer" and tostring(t.text):find(pattern) then return true end
    end
    for _, c in ipairs(MH.chat) do
        local text = type(c.message) == "table" and c.message.text or c.message
        if c.target == pid and c.resource == "rp_fixer" and tostring(text):find(pattern) then return true end
    end
    return false
end

function FXW.printed(pattern)
    local n = 0
    for _, line in ipairs(MH.logs) do
        if line:find("^%[rp_fixer%]") and line:find(pattern) then n = n + 1 end
    end
    return n
end

function FXW.events(state)
    local n = 0
    for _, e in ipairs(MH.shared.fxEvents) do if e.state == state then n = n + 1 end end
    return n
end

-- Runs until the contract reaches a state (or the time runs out).
function FXW.until_(c, state, seconds)
    return MH.until_(function() return c.state == state end, seconds or 60)
end

-- The rows of the last board shown to a player.
function FXW.lastBoard(pid)
    for i = #MH.shared.ui, 1, -1 do
        local e = MH.shared.ui[i]
        if e.pid == pid and e.kind == "context" and e.def.id == "fx_board" then return e.def end
    end
    return nil
end

function FXW.rowsOf(def)
    local ids = {}
    for _, o in ipairs(def and def.options or {}) do ids[o.id] = o end
    return ids
end

-- Every eddy is accounted for: the escrow society holds exactly what the escrowed contracts hold.
function FXW.escrowAgrees()
    local s = FXW.svc()
    local held = 0
    for _, c in pairs(s.contracts) do
        if c.state == "open" or c.state == "taken" or c.state == "paying" or c.state == "refunding" then held = held + c.reward end
    end
    local bal = FXW.balance("soc:fixer_escrow")
    return held == bal, ("contracts hold %d, escrow %d"):format(held, bal)
end

function FXW.result(t) return SFW.result(t) end
