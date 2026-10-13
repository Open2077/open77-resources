-- tests/compat/techie_world.lua: the techie job's offline world (rp_techie), on multihost.lua.
--
-- String globals from the runner: ROOT_DIR (this pack), COMPAT_DIR (this folder), SYS_DIR (the
-- Open77 `resources/system` folder holding open77_actions) and TX_DIR (the open77_transactions
-- resource). Files are read from those folders, never copied or edited.
--
-- What runs for real: open77_transactions (model, policy, memory store, coordinator, server/main.lua
-- with its exports, work queue and tunables), open77_actions (engine, claims, main), rp_economy and
-- rp_techie. The platform fakes (players, animations, player interactions, notifications, tunables)
-- and the coordinator store/pump come from streetfood_world.lua (SFW). Shims stand in for the PUBLIC
-- exports of rp_jobs (with grades), rp_inventory (definitions with their definer, pockets, lab
-- gifts, grantPockets), open77_uikit (the context menu) and, when asked, rp_salvage's item
-- definitions.

dofile(COMPAT_DIR .. "/streetfood_world.lua")

TW = {}

-- ---------------------------------------------------------------------------------------------
-- Shims
-- ---------------------------------------------------------------------------------------------
-- rp_jobs B4 contract with grades: eligible(pid, { job, minGrade, duty, epoch }) -> true, epoch |
-- nil, reason (the real order: unknown_job, player_not_found, stale_job_epoch, no_job, wrong_job,
-- grade_too_low, off_duty); setJob(pid, job, grade); setDuty; workEpoch; the host-wide
-- rp_jobs:workEpoch event on every change.
TW.JOBS = [==[
local J = HOST.shared.jobs
local KNOWN = HOST.shared.knownJobs
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
    if job and not KNOWN[job] then return nil, "unknown_job" end
    local r, id = rec(pid)
    if not r then return nil, "player_not_found" end
    r.job, r.grade, r.duty = job, grade or 0, false
    bump(id, "job_changed")
    return true
end)
exports("setGrade", function(pid, grade)
    local r, id = rec(pid)
    if not r then return nil, "player_not_found" end
    r.grade = grade
    bump(id, "grade_changed")
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
    requirement = requirement or {}
    if requirement.job and not KNOWN[requirement.job] then return nil, "unknown_job" end
    local r = rec(pid)
    if not r then return nil, "player_not_found" end
    if requirement.epoch ~= nil and requirement.epoch ~= false and requirement.epoch ~= r.epoch then
        return nil, "stale_job_epoch"
    end
    if (requirement.job or requirement.minGrade or requirement.duty) and not r.job then return nil, "no_job" end
    if requirement.job and r.job ~= requirement.job then return nil, "wrong_job" end
    if requirement.minGrade and (r.grade or 0) < requirement.minGrade then return nil, "grade_too_low" end
    if requirement.duty and not r.duty then return nil, "off_duty" end
    return true, r.epoch
end)
exports("workEpoch", function(pid)
    local r = rec(pid)
    return r and r.epoch or false
end)
]==]

-- rp_inventory B1/B2 contract (transactions backend): define -> registered, rejected, details (an
-- id another definer owns is refused); itemDefinition; backend; addAsync (lab gifts, minted from
-- sys:<caller>); grantPockets (a one-operation grant of a loaded player's pockets to an allowed
-- caller). Pockets char:<subject> are opened at join like the B2 facade does.
TW.INVENTORY = [==[
local TX = "open77_transactions"
local defs = { chip = { label = "Data chip", weight = 0.05 } }
local owners = { chip = "rp_inventory" }
local GRANTEES = { rp_economy = true, rp_salvage = true, rp_cargo = true }
local counter = 0
local function toCoordinator(items)
    local out = {}
    for id, d in pairs(items) do
        out[id] = { weightG = math.floor((d.weight or 0) * 1000 + 0.5), unique = d.unique == true or d.durability ~= nil }
    end
    return out
end
local function push(items) return Open77.exports.callSync(TX, "define", toCoordinator(items)) end
exports("define", function(items)
    local definer = GetInvokingResource() or "unknown"
    local accepted, collisions, n = {}, {}, 0
    for id, d in pairs(items) do
        if owners[id] and owners[id] ~= definer then
            collisions[#collisions + 1] = id
        else
            owners[id], defs[id], accepted[id] = definer, d, d
            n = n + 1
        end
    end
    if next(accepted) ~= nil then
        local ok = pcall(push, accepted)
        if not ok then return nil, "store_unavailable" end
    end
    HOST.shared.defines[#HOST.shared.defines + 1] = { definer = definer, n = n, collisions = #collisions }
    return n, #collisions, { collisions = collisions, warnings = {} }
end)
exports("itemDefinition", function(id)
    local d = defs[id]
    if not d then return nil, "unknown_item" end
    return { label = d.label, weight = d.weight, definedBy = owners[id] }
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
    if not defs[item] then return nil, "unknown_item" end
    counter = counter + 1
    local p = Open77.exports.call(TX, "transfer", { opId = opts and opts.opId or ("inv.add." .. counter .. "." .. item),
        kind = "inv.add", lines = { { item = item, count = count, from = "sys:" .. tostring(GetInvokingResource()), to = account } } })
    return p:await()
end)
exports("grantPockets", function(opId, pid, ttlMs)
    local caller = GetInvokingResource()
    if not caller or not GRANTEES[caller] then return nil, "caller_not_allowed" end
    local subject = Open77.exports.callSync(TX, "subjectOf", pid)
    if not subject or not HOST.players[tonumber(pid)] then return nil, "player_not_loaded" end
    HOST.shared.grants[#HOST.shared.grants + 1] = { opId = opId, caller = caller, pid = pid }
    local ok, granted, why = pcall(Open77.exports.callSync, TX, "authorize", opId, caller, { "char:" .. subject }, ttlMs)
    if not ok or granted ~= true then return nil, why or "store_unavailable" end
    return true
end)
AddEventHandler("onResourceStart", function(name)
    if name ~= GetCurrentResourceName() and name ~= TX then return end
    CreateThread(function()
        for _ = 1, 40 do
            local ok = pcall(push, defs)
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

-- open77_uikit server twin `context(playerId, definition, options)`: records the menu and answers
-- what the test put in HOST.shared.uikitAnswer (a table, or a function(pid, def)).
TW.UIKIT = [==[
exports("context", function(pid, def, options)
    HOST.shared.menus[#HOST.shared.menus + 1] = { pid = pid, def = def, options = options, caller = GetInvokingResource() }
    local answer = HOST.shared.uikitAnswer
    if type(answer) == "function" then answer = answer(pid, def) end
    if answer == nil then return { ok = false, outcome = "cancelled" } end
    return answer
end)
]==]

-- rp_salvage, as far as items go: it defines scrap_metal and copper_wire at start.
TW.SALVAGE = [==[
CreateThread(function()
    Wait(200)
    exports.rp_inventory:define({
        scrap_metal = { label = "Scrap metal", weight = 1.0, usable = false, illegal = false, category = "material" },
        copper_wire = { label = "Copper wire", weight = 0.25, usable = false, illegal = false, category = "material" },
    })
end)
]==]

-- A resource allowed to start trades through exports.rp_techie:offer (the ripperdoc job).
TW.RIPPERDOC = [==[
exports("ping", function() return true end)
]==]

-- ---------------------------------------------------------------------------------------------
-- Boot
-- ---------------------------------------------------------------------------------------------
TW.WRITERS_STRICT = "rp_techie:stash/tray+char+cash, rp_economy:cash+bank+soc, rp_inventory"
TW.MINT_RULES = "rp_techie sys:techie.workshop * 100000; rp_techie sys:techie.dealer * 100000; " ..
    "rp_techie sys:techie.shop money 1000000; rp_inventory sys:* * 100000; rp_economy sys:* money 100000000; " ..
    "tch_probe sys:* * 100000"

function TW.startTechie() return SFW.startWith("rp_techie", SFW.scripts(ROOT_DIR .. "/rp_techie")) end

-- opts: keep (TW.keep()), writers, mint, shopPayment ("economy" | "ledger"), noEconomyBudget,
-- noUikit, salvage (an rp_salvage item definer), job (the convar rp_techie_job), knownJobs
function TW.boot(opts)
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
    MH.shared.knownJobs = opts.knownJobs or { techie = true, ferrailleur = true, cook = true, ripper = true }
    MH.shared.defines, MH.shared.grants, MH.shared.menus = {}, {}, {}
    MH.shared.uikitAnswer = nil
    MH.shared.tunables = {
        open77_transactions = { store = "lab_kvp", serverTag = "lab", writers = opts.writers or "*",
            mint1 = opts.mint or TW.MINT_RULES },
    }
    MH.convars.open77_transactions_lab = "1"
    MH.convars.sv_masterServerEnabled = "false"
    MH.convars.open77_actions_trace = "1"
    MH.convars.rp_techie_shop_payment = opts.shopPayment or "economy"
    MH.convars.rp_techie_job = opts.job
    MH.dbMode = "sql"
    SFW.startCoordinator()
    SFW.shim("open77_player_interactions", SFW.PLATFORM)
    SFW.shim("rp_inventory", TW.INVENTORY)
    SFW.shim("rp_jobs", TW.JOBS)
    if not opts.noUikit then SFW.shim("open77_uikit", TW.UIKIT) end
    if opts.salvage then SFW.shim("rp_salvage", TW.SALVAGE) end
    SFW.shim("rp_ripperdoc", TW.RIPPERDOC)
    SFW.startActions()
    SFW.startEconomy()
    -- rp_economy's own config grants rp_techie a mint budget for shop sales; noEconomyBudget removes
    -- it to prove the refusal path (an operator who dropped the line).
    MH.resources.rp_economy.env.EconomyConfig.mint.callers.rp_techie = (not opts.noEconomyBudget) and 30000 or nil
    TW.startTechie()
    TW.watch()
    MH.until_(function() return TW.svc() and TW.svc().ready end, 90)
    MH.run(1)
end

-- What survives a server restart: the database (coordinator store), KVP files, the job registry,
-- but not runtime props, interactions or duty.
function TW.keep()
    return { store = MH.shared.txStore, db = MH.shared.db, kvp = MH.kvp, now = MH.now,
        world = MH.shared.world, jobs = MH.shared.jobs }
end

function TW.svc() local R = MH.resources.rp_techie return R and R.running and R.env.TechieRuntime.service end
function TW.cfg() return MH.resources.rp_techie.env.TechieConfig end

function TW.watch()
    MH.start("tch_probe", { { source = [==[
AddEventHandler("open77_actions:transition", function(op)
    HOST.shared.transitions[#HOST.shared.transitions + 1] = op
end)
AddEventHandler("rp:job:completed", function(e)
    HOST.shared.jobEvents[#HOST.shared.jobEvents + 1] = e
end)
AddEventHandler("rp_techie:sold", function(e)
    HOST.shared.sold[#HOST.shared.sold + 1] = e
end)
AddEventHandler("rp_techie:crafted", function(pid, recipe, outputs, opId)
    HOST.shared.crafted[#HOST.shared.crafted + 1] = { pid = pid, recipe = recipe, outputs = outputs, opId = opId }
end)
]==], name = "probe.lua" } }, { host = true })
    MH.shared.transitions, MH.shared.jobEvents, MH.shared.sold, MH.shared.crafted = {}, {}, {}, {}
end

-- ---------------------------------------------------------------------------------------------
-- Driving and reading
-- ---------------------------------------------------------------------------------------------
TW.WORKBENCH = { x = -1238.89, y = 1998.18, z = 12.010 }
TW.ELECTRONICS = { x = -1240.88, y = 1999.11, z = 12.010 }
TW.DEALER = { x = -1235.566, y = 2000.680, z = 12.077 }
TW.GUNSHOP = { x = -1160.02, y = 2017.85, z = 7.76 }
TW.MEDPOINT = { x = -1224.52, y = 1990.59, z = 7.80 }
TW.NEAR_WORKBENCH = { x = -1237.0, y = 1999.0, z = 12.0 }    -- 1.56 m from the workbench
TW.BESIDE_WORKBENCH = { x = -1238.6, y = 1998.6, z = 12.0 }  -- 1.22 m from the workbench
TW.TRAY = "stash:tch.kabuki_west:tray"
TW.KNEEL_T, TW.STAND_T = "rp_techie:kabuki_west_kneel", "rp_techie:kabuki_west_stand"
TW.DEALER_T, TW.GUNSHOP_T, TW.MEDPOINT_T = "rp_techie:dealer_kabuki_west", "rp_techie:shop_gunshop", "rp_techie:shop_medpoint"

function TW.setup(pid, grade)
    SFW.command("techie.lab.setup", { tostring(pid), tostring(grade or 0) })
    MH.run(1)
end

function TW.give(pid, item, n)
    SFW.command("techie.lab.give", { tostring(pid), item, tostring(n) })
    MH.run(2)
end

-- Whether a recipe is one of its bench prompt's choices (the first three of its bench type).
function TW.onPrompt(recipe)
    local cfg = TW.cfg()
    local bench, n = cfg.recipes[recipe].bench, 0
    for _, key in ipairs(cfg.recipeOrder) do
        if cfg.recipes[key].bench == bench then
            n = n + 1
            if key == recipe then return n <= 3 end
        end
    end
    return false
end

-- A stage: the bench prompt's intent when the prompt offers it, else the request the bench menu
-- (and techie.lab.craft) makes. Returns the action's last transition.
function TW.startCraft(pid, recipe)
    local cfg = TW.cfg()
    if TW.onPrompt(recipe) then
        local bench = cfg.recipes[recipe].bench == "electronics" and TW.STAND_T or TW.KNEEL_T
        SFW.intent(pid, "rp_techie:craft_" .. recipe, bench)
    else
        SFW.command("techie.lab.craft", { tostring(pid), recipe })
    end
end

function TW.craft(pid, recipe, seconds)
    local mark = SFW.mark()
    TW.startCraft(pid, recipe)
    return SFW.finish(pid, "craft_" .. recipe, seconds or 40, mark)
end

function TW.buy(pid, item)
    return SFW.act(pid, "rp_techie:buy_kabuki_west_" .. item, TW.DEALER_T, "buy_kabuki_west_" .. item, 20)
end

function TW.sellShop(pid, shop)
    local t = shop == "medpoint" and TW.MEDPOINT_T or TW.GUNSHOP_T
    return SFW.act(pid, "rp_techie:sell_" .. shop, t, "sell_" .. shop, 20)
end

-- The open trade a player takes part in: its platform id, the sale op id and the offer.
function TW.offerOf(pid)
    local id = TW.svc().offerOf[pid]
    return id, id and TW.svc().offers[id] and TW.svc().offers[id].opId, id and TW.svc().offers[id]
end

-- The responder answers; runs until the trade settled or was dropped.
function TW.answer(pid, accepted, seconds)
    local id, opId = TW.offerOf(pid)
    if not id then return nil end
    local s = TW.svc()
    local dropped0 = s.stats.dropped
    SFW.respond(id, accepted)
    MH.until_(function()
        local t = TW.svc()
        return t and ((opId and t.done[opId] ~= nil) or t.stats.dropped > dropped0)
    end, seconds or 40)
    MH.run(1)
    return opId
end

-- Whether a player was told something matching a Lua pattern (chat line or toast of rp_techie).
function TW.told(pid, pattern)
    for _, t in ipairs(MH.shared.world.toasts) do
        if t.pid == pid and t.resource == "rp_techie" and tostring(t.text):find(pattern) then return true end
    end
    for _, c in ipairs(MH.chat) do
        local text = type(c.message) == "table" and c.message.text or c.message
        if c.target == pid and c.resource == "rp_techie" and tostring(text):find(pattern) then return true end
    end
    return false
end

function TW.printed(pattern)
    local n = 0
    for _, line in ipairs(MH.logs) do
        if line:find("%[rp_techie%]") and line:find(pattern) then n = n + 1 end
    end
    return n
end

function TW.jobEvents(kind, pid)
    local out = {}
    for _, e in ipairs(MH.shared.jobEvents) do
        if (kind == nil or e.kind == kind) and (pid == nil or e.playerId == pid) then out[#out + 1] = e end
    end
    return out
end

function TW.played(pid, profile, kind)
    for _, p in ipairs(MH.shared.world.played) do
        if p.pid == pid and p.profile == profile and (kind == nil or p.kind == kind) then return p end
    end
    return nil
end

-- Nothing is held (reserved) on an account any more.
function TW.nothingHeld(account)
    local snap = MH.callAsync("tch_probe", "open77_transactions", "read", account)
    return type(snap) == "table" and type(snap.held) == "table" and next(snap.held.items or {}) == nil
        and (snap.held.money or 0) == 0
end

-- Conservation per item: what entered the world (lab gifts, the dealer, the workshop's mints) =
-- what is in pockets and on trays + what left it (burned into the workshop, sold to shops).
function TW.conserved(accounts)
    local cfg = TW.cfg()
    local items = {}
    for _, i in ipairs(cfg.parts) do items[#items + 1] = i end
    for i in pairs(cfg.items) do items[#items + 1] = i end
    local problems = {}
    for _, item in ipairs(items) do
        local entered, left = 0, 0
        local held = 0
        for _, e in ipairs(SFW.store().journal) do
            if e.asset == item and e.account:find("^sys:") then
                if e.delta < 0 then entered = entered - e.delta else left = left + e.delta end
            end
        end
        for _, acct in ipairs(accounts) do held = held + SFW.count(acct, item) end
        held = held + SFW.count(TW.TRAY, item)
        if entered ~= held + left then
            problems[#problems + 1] = ("%s entered=%d held=%d left=%d"):format(item, entered, held, left)
        end
    end
    return #problems == 0, table.concat(problems, "; ")
end

TW.result = SFW.result
