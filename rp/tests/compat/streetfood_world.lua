-- tests/compat/streetfood_world.lua: the C4 street-food stall's offline world, on multihost.lua.
--
-- String globals from the runner: ROOT_DIR (this pack), COMPAT_DIR (this folder), SYS_DIR (the
-- Open77 `resources/system` folder holding open77_actions) and TX_DIR (the FINAL
-- open77_transactions resource, wave 1). Files are read from those folders, never copied or edited.
--
-- What runs for real: open77_transactions (model, policy, memory store, coordinator, server/main.lua
-- with its exports, work queue and tunables), open77_actions (engine, claims, carry, main),
-- rp_economy (B3) and rp_streetfood. Shims stand in for the PUBLIC exports of rp_jobs, rp_inventory,
-- rp_needs and open77_furniture (their own suites cover them). The platform natives (players,
-- animations, props, held items, player interactions, notifications, tunables) are fakes defined
-- here (SFW.PATCH), applied to every resource. The player-interaction fake models the documented
-- lifecycle (wiki/player-interactions.md): offered -> (accepted) -> active -> completed, or
-- cancelled on decline, invite timeout, separation, death, disconnect or owner stop.
--
-- The coordinator's store is the memory store in deferred mode, pumped every pass, so a test can
-- inject store faults and stop/restart the coordinator with its queued work executed detached or
-- discarded (A13 crash windows), exactly as the C1 suite does.

dofile(COMPAT_DIR .. "/multihost.lua")
dofile(COMPAT_DIR .. "/wallet_world.lua")
dofile(COMPAT_DIR .. "/json.lua")

SFW = {}

-- ---------------------------------------------------------------------------------------------
-- Manifests: shared + server scripts in order (both `server_script "x"` and `server_scripts {}`).
-- ---------------------------------------------------------------------------------------------
function SFW.scripts(dir)
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
SFW.PATCH = [==[
local W = HOST.shared.world
local NAME = GetCurrentResourceName()

local function pos3(p) return { x = p.x, y = p.y, z = p.z } end
local function copy(t)
    if type(t) ~= "table" then return t end
    local out = {}
    for k, v in pairs(t) do out[k] = copy(v) end
    return out
end

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

local function playback(pid, profile, kind, position, yaw, options)
    if not HOST.players[tonumber(pid)] then return nil, "player_not_found" end
    if W.badProfiles[profile] then return nil, "unknown_profile" end
    W.playbackSeq = W.playbackSeq + 1
    W.playing[tonumber(pid)] = { playbackId = W.playbackSeq, profile = profile, owner = NAME }
    W.played[#W.played + 1] = { pid = tonumber(pid), profile = profile, playbackId = W.playbackSeq, kind = kind,
        position = position and pos3(position) or nil, yaw = yaw, owner = NAME,
        held = W.held[tonumber(pid)] and W.held[tonumber(pid)].record or nil }
    return { playbackId = W.playbackSeq, profile = profile }
end
Open77.animations = {
    play = function(pid, profile, options) return playback(pid, profile, "play", nil, nil, options) end,
    playAt = function(pid, profile, position, yaw, options) return playback(pid, profile, "playAt", position, yaw, options) end,
    sequence = function(pid, steps) return playback(pid, steps and steps[1] and steps[1].profile or "sequence", "sequence") end,
    stop = function() return true end,
    stopAt = function() return true end,
    get = function() return nil end,
}

Open77.props = {
    create = function(def)
        if type(def) ~= "table" or type(def.model) ~= "string" then return nil, "invalid_model" end
        W.propSeq = W.propSeq + 1
        local id = tostring(W.propSeq)
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
        p.attachment = binding
        return true
    end,
    detach = function(id) local p = W.props[tostring(id)] if p then p.attachment = nil end return p ~= nil end,
    setTransform = function(id, t)
        local p = W.props[tostring(id)]
        if not p then return nil, "prop_not_found" end
        if t.position then p.position = pos3(t.position) end
        return true
    end,
    remove = function(id) W.props[tostring(id)] = nil return true end,
}

-- Resource-owned native hand items: one per player; another resource's item refuses.
Open77.heldItems = {
    hold = function(pid, record)
        pid = tonumber(pid)
        if not pid or not HOST.players[pid] then return nil, "invalid_argument" end
        if type(record) ~= "string" or not record:match("^Items%.") then return nil, "invalid_item_record" end
        local h = W.held[pid]
        if h and h.owner ~= NAME then return nil, "invalid_operation" end
        W.heldSeq = W.heldSeq + 1
        W.held[pid] = { record = record, owner = NAME }
        W.heldLog[#W.heldLog + 1] = { op = "hold", pid = pid, record = record, owner = NAME }
        return "h" .. W.heldSeq
    end,
    release = function(pid)
        pid = tonumber(pid)
        local h = W.held[pid]
        if h and h.owner == NAME then W.held[pid] = nil end
        W.heldSeq = W.heldSeq + 1
        W.heldLog[#W.heldLog + 1] = { op = "release", pid = pid, owner = NAME }
        return "h" .. W.heldSeq
    end,
}

-- Player interactions (server API): reserves both players, consent, a shared start, events to all
-- resources (the owner filters by id). The platform half lives in SFW.PLATFORM.
Open77.playerInteractions = {
    request = function(actor, target, kind, options)
        actor, target = tonumber(actor), tonumber(target)
        local a, b = HOST.players[actor], HOST.players[target]
        if not a or not b or actor == target then return nil, "invalid_participants" end
        if a.alive == false or b.alive == false then return nil, "player_not_alive" end
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

Open77.state = {
    entity = function(kind, id)
        local key = kind .. ":" .. tostring(id)
        W.bags[key] = W.bags[key] or {}
        local bag = W.bags[key]
        return { set = function(_, k, v) bag[k] = v; return true end, get = function(_, k) return bag[k] end }
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
        return values
    end,
}

Open77.notifications = {
    send = function(pid, def)
        W.toasts[#W.toasts + 1] = { resource = NAME, pid = pid, text = def and def.message }
        return "t" .. #W.toasts
    end,
}
]==]

-- The platform half of the player-interaction fake: invite timeouts, the active window, separation,
-- death, disconnect and owner stop. Ends are emitted to every resource (owners filter by id).
SFW.PLATFORM = [==[
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
-- A participant's answer to the invitation (the client's /interaction accept | decline).
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
    for pid, h in pairs(W.held) do if h.owner == name then W.held[pid] = nil end end
end)
AddEventHandler("onPlayerDisconnected", function(pid)
    W.held[tonumber(pid)] = nil
end)
]==]

-- The coordinator's store: the deferred memory store, kept in HOST.shared so it survives restarts.
SFW.TXSTORE = [==[
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

SFW.TXPUMP = [==[
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
-- Shims: the public exports of rp_jobs, rp_inventory, rp_needs and open77_furniture.
-- ---------------------------------------------------------------------------------------------
SFW.JOBS = [==[
-- rp_jobs B4 contract: eligible(pid, { job, duty, epoch }) -> true, epoch | nil, reason; workEpoch;
-- setDuty; setJob; the host-wide rp_jobs:workEpoch event on every change.
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
]==]

SFW.INVENTORY = [==[
-- rp_inventory B1/B2 contract (transactions backend): define -> registered, rejected, details;
-- backend; moveAsync (explicit accounts, ONE operation); addAsync. Pockets char:<subject> are
-- opened at join like the B2 facade does.
local TX = "open77_transactions"
local defs = {}
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
    for id, d in pairs(items) do defs[id] = d end
    local ok, _, rejected, collisions = pcall(push, items)
    if not ok then return nil, "store_unavailable" end
    local n = 0
    for _ in pairs(items) do n = n + 1 end
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
    if not defs[item] then return nil, "unknown_item" end
    counter = counter + 1
    local p = Open77.exports.call(TX, "transfer", { opId = opts and opts.opId or ("inv.add." .. counter .. "." .. item),
        kind = "inv.add", lines = { { item = item, count = count, from = "sys:" .. tostring(GetInvokingResource()), to = account } } })
    return p:await()
end)
exports("moveAsync", function(moves, opts)
    opts = opts or {}
    if type(moves) ~= "table" or #moves == 0 then return nil, "invalid_spec" end
    local lines = {}
    for _, m in ipairs(moves) do
        if not defs[m.item] then return nil, "invalid_spec" end
        lines[#lines + 1] = { item = m.item, count = m.count, from = m.from, to = m.to }
    end
    counter = counter + 1
    local caller = GetInvokingResource() or "unknown"
    HOST.shared.moves[#HOST.shared.moves + 1] = { caller = caller, opId = opts.opId, n = #lines }
    local p = Open77.exports.call(TX, "transfer", { opId = opts.opId or ("inv.mv." .. counter), kind = ("mv:" .. caller):sub(1, 32),
        actor = opts.actor, lines = lines })
    if not p then return nil, "store_unavailable" end
    local receipt, why, info = p:await()
    if not receipt and why == "insufficient_items" then return nil, "not_enough", info end
    return receipt, why, info
end)
AddEventHandler("onResourceStart", function(name)
    if name ~= GetCurrentResourceName() and name ~= TX then return end
    CreateThread(function()
        for _ = 1, 40 do
            if next(defs) == nil then break end
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

SFW.NEEDS = [==[
-- rp_needs contract: apply(playerId, delta, label) -> true | nil, reason (synchronous).
exports("apply", function(pid, delta, label)
    pid = tonumber(pid)
    if not pid or not HOST.players[pid] then return nil, "player_not_found" end
    HOST.shared.needs[#HOST.shared.needs + 1] = { pid = pid, delta = delta, label = label, caller = GetInvokingResource() }
    return true
end)
exports("get", function() return { hunger = 50, thirst = 50, fatigue = 50 } end)
]==]

SFW.FURNITURE = [==[
-- open77_furniture A1 contract: get(id) -> furniture with poseList; status(). The poses below are the
-- catalogue's (furniture-1-17f2d5e1987b), read in place offline by the C4 agent.
local F = {
    ["14182403679719868087"] = { id = "14182403679719868087", kind = "chair_lean_back", flags = 1544, version = "furniture-1-17f2d5e1987b",
        poseList = { { spot = "14182403679719868087", x = -403.207, y = 714.571, z = 115.000, yaw = -100.20, profile = "chair", verification = "unverified" } } },
    ["14644536518519442059"] = { id = "14644536518519442059", kind = "chair", flags = 1544, version = "furniture-1-17f2d5e1987b",
        poseList = { { spot = "14644536518519442059", x = -408.115, y = 712.281, z = 115.000, yaw = -38.00, profile = "seatedthink", verification = "unverified" } } },
    ["9160494166749203069"] = { id = "9160494166749203069", kind = "chair", flags = 1544, version = "furniture-1-17f2d5e1987b",
        poseList = { { spot = "9160494166749203069", x = -421.196, y = 710.938, z = 115.040, yaw = -109.01, profile = "seated", verification = "measured" },
                     { spot = "15302801922906504476", x = -421.176, y = 710.919, z = 115.100, yaw = -107.59, profile = "seated", verification = "measured" } } },
}
exports("get", function(id)
    HOST.shared.furnitureCalls = (HOST.shared.furnitureCalls or 0) + 1
    local f = F[tostring(id)]
    if not f then return nil, "unknown_furniture" end
    return f
end)
exports("status", function() return { indexed = true, version = "furniture-1-17f2d5e1987b" } end)
]==]

-- ---------------------------------------------------------------------------------------------
-- Boot
-- ---------------------------------------------------------------------------------------------
SFW.WRITERS_STRICT = "rp_streetfood:stash/pantry+stash/pass+char, rp_economy:cash+bank+soc, rp_inventory"
SFW.MINT_RULES = "rp_streetfood sys:streetfood.kitchen * 100000; rp_streetfood sys:streetfood.supplier * 100000; " ..
    "rp_inventory sys:* * 100000; rp_economy sys:* money 100000000; sf_probe sys:* * 100000"

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
    local list = { { source = SFW.PATCH, name = "patch_" .. name .. ".lua" } }
    for _, s in ipairs(scripts) do list[#list + 1] = s end
    return MH.start(name, list, { host = true, globals = globals() })
end
SFW.startWith = startWith

function SFW.startCoordinator()
    return startWith("open77_transactions", {
        TX_DIR .. "/shared/model.lua", TX_DIR .. "/server/policy.lua", TX_DIR .. "/server/memory_store.lua",
        TX_DIR .. "/server/sql_store.lua", TX_DIR .. "/server/coordinator.lua",
        { source = SFW.TXSTORE, name = "txstore_shim.lua" }, TX_DIR .. "/server/main.lua",
        { source = SFW.TXPUMP, name = "txpump_shim.lua" },
    })
end

function SFW.startActions() return startWith("open77_actions", SFW.scripts(SYS_DIR .. "/open77_actions")) end
function SFW.startStall() return startWith("rp_streetfood", SFW.scripts(ROOT_DIR .. "/rp_streetfood")) end
function SFW.startEconomy() return startWith("rp_economy", WW.scripts("rp_economy")) end
local function shim(name, source) return startWith(name, { { source = source, name = name .. "_shim.lua" } }) end
SFW.shim = shim

-- opts: keep (SFW.keep()), writers, mint, seating (true), noNeeds, noFurniture
function SFW.boot(opts)
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
    MH.shared.tunables = {
        open77_transactions = { store = "lab_kvp", serverTag = "lab", writers = opts.writers or "*",
            mint1 = opts.mint or SFW.MINT_RULES },
    }
    MH.convars.open77_transactions_lab = "1"
    MH.convars.sv_masterServerEnabled = "false"
    MH.convars.open77_actions_trace = "1"
    MH.convars.rp_streetfood_seating = opts.seating and "1" or "0"
    MH.dbMode = "sql"
    SFW.startCoordinator()
    shim("open77_player_interactions", SFW.PLATFORM)
    shim("rp_inventory", SFW.INVENTORY)
    shim("rp_jobs", SFW.JOBS)
    if not opts.noNeeds then shim("rp_needs", SFW.NEEDS) end
    if not opts.noFurniture then shim("open77_furniture", SFW.FURNITURE) end
    SFW.startActions()
    SFW.startEconomy()
    SFW.startStall()
    SFW.watch()
    MH.until_(function() return SFW.stall() and SFW.stall().ready end, 60)
    MH.run(1)
end

-- What survives a server restart: the database (coordinator store), KVP files, the job registry
-- (SQL in the real rp_jobs), but not runtime props, hand items, interactions or duty.
function SFW.keep()
    return { store = MH.shared.txStore, db = MH.shared.db, kvp = MH.kvp, now = MH.now,
        world = MH.shared.world, jobs = MH.shared.jobs }
end

function SFW.stall() local R = MH.resources.rp_streetfood return R and R.running and R.env.StreetfoodRuntime.service end
function SFW.store() return MH.shared.txStore end
function SFW.cfg() return MH.resources.rp_streetfood.env.StreetfoodConfig end

-- ---------------------------------------------------------------------------------------------
-- Players and movement
-- ---------------------------------------------------------------------------------------------
function SFW.join(id, identifier, name, position)
    MH.players[id] = { identifier = identifier, name = name or ("player" .. id), ready = true, alive = true,
        heading = 0.0, position = { x = position.x, y = position.y, z = position.z, bucket = position.bucket or 0 } }
    MH.emit("onPlayerReady", id)
    MH.until_(function() return MH.resources.rp_economy.env.Wallets.byPlayer[id] ~= nil end, 30)
    MH.run(1)
end

function SFW.move(id, position)
    local p = MH.players[id]
    p.position = { x = position.x, y = position.y, z = position.z, bucket = position.bucket or p.position.bucket or 0 }
end

function SFW.kill(id)
    MH.players[id].alive = false
    MH.emit("onPlayerLifeStateChanged", id, 1, "dead")
end

-- ---------------------------------------------------------------------------------------------
-- Driving the libraries like a client would
-- ---------------------------------------------------------------------------------------------
function SFW.intent(pid, actionKey, targetKey)
    local R = MH.resources.open77_actions
    R.env.source = pid
    MH.emit("open77:actions:intent", actionKey, targetKey)
    R.env.source = nil
end

function SFW.clientCancel(pid, opId)
    local R = MH.resources.open77_actions
    R.env.source = pid
    MH.emit("open77:actions:cancel", opId)
    R.env.source = nil
end

function SFW.sync(from, target, name, ...)
    local res = table.pack(MH.callSync(from, target, name, ...))
    if not res[1] then return nil, "raised:" .. tostring(res[2]) end
    return table.unpack(res, 2, res.n)
end

function SFW.command(name, args) MH.command(name, 0, args) end

-- The customer's answer to the platform invitation (/interaction accept | decline).
function SFW.respond(interactionId, accepted) return MH.shared.ixRespond(interactionId, accepted) end

-- The open offer of a cook (the platform's interaction), or nil.
function SFW.offerOf(cookPid)
    for id, st in pairs(MH.shared.world.ix) do
        if tonumber(st.actor) == cookPid then return id, st end
    end
    return nil
end

function SFW.watch()
    MH.start("sf_probe", { { source = [==[
AddEventHandler("open77_actions:transition", function(op)
    HOST.shared.transitions[#HOST.shared.transitions + 1] = op
end)
AddEventHandler("rp_streetfood:consumed", function(pid, item, opId)
    HOST.shared.consumed[#HOST.shared.consumed + 1] = { pid = pid, item = item, opId = opId }
end)
AddEventHandler("rp_streetfood:sold", function(cook, customer, item, opId)
    HOST.shared.sold[#HOST.shared.sold + 1] = { cook = cook, customer = customer, item = item, opId = opId }
end)
]==], name = "probe.lua" } }, { host = true })
    MH.shared.transitions, MH.shared.consumed, MH.shared.sold = {}, {}, {}
end

function SFW.mark() return #(MH.shared.transitions or {}) end

-- Runs until the player's first operation of `actionId` begun after `mark` is terminal; returns
-- its last transition.
function SFW.finish(pid, actionId, seconds, mark)
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

function SFW.waitState(pid, actionId, mark, state, seconds)
    return MH.until_(function()
        local list = MH.shared.transitions or {}
        for i = (mark or 0) + 1, #list do
            local op = list[i]
            if op.playerId == pid and op.actionId == actionId and op.state == state then return true end
        end
        return false
    end, seconds or 15)
end

-- A prompt choice, then its outcome.
function SFW.act(pid, actionKey, targetKey, actionId, seconds)
    local mark = SFW.mark()
    SFW.intent(pid, actionKey, targetKey)
    return SFW.finish(pid, actionId, seconds, mark)
end

-- Refusal tokens open77_actions sent to a player's client.
function SFW.refusals(pid)
    local out = {}
    for _, e in ipairs(MH.shared.world.client) do
        if e.name == "open77:actions:refused" and e.pid == pid then out[#out + 1] = e.args[1] and e.args[1].reason end
    end
    return out
end

-- Whether a player was told something matching a Lua pattern (chat line or toast of rp_streetfood).
function SFW.told(pid, pattern)
    for _, t in ipairs(MH.shared.world.toasts) do
        if t.pid == pid and t.resource == "rp_streetfood" and tostring(t.text):find(pattern) then return true end
    end
    for _, c in ipairs(MH.chat) do
        local text = type(c.message) == "table" and c.message.text or c.message
        if c.target == pid and c.resource == "rp_streetfood" and tostring(text):find(pattern) then return true end
    end
    return false
end

function SFW.printed(pattern)
    local n = 0
    for _, line in ipairs(MH.logs) do
        if line:find("^%[rp_streetfood%]") and line:find(pattern) then n = n + 1 end
    end
    return n
end

-- ---------------------------------------------------------------------------------------------
-- Durable truth (the coordinator store = the database)
-- ---------------------------------------------------------------------------------------------
function SFW.count(account, item) return SFW.store():count(account, item) end
function SFW.balance(account) return SFW.store():balance(account) end

-- Sum of journal deltas of an asset on accounts matching a Lua pattern.
function SFW.journal(accountPattern, asset)
    local total = 0
    for _, e in ipairs(SFW.store().journal) do
        if e.account:find(accountPattern) and e.asset == asset then total = total + e.delta end
    end
    return total
end

-- Every committed operation balances per asset (double entry); returns the first bad op or nil.
function SFW.unbalanced()
    local sums = {}
    for _, e in ipairs(SFW.store().journal) do
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

-- Committed operations of a kind (the coordinator's own journal).
function SFW.committed(kind)
    local seen, n = {}, 0
    for _, e in ipairs(SFW.store().journal) do
        if e.kind == kind and not seen[e.opId] then seen[e.opId] = true; n = n + 1 end
    end
    return n
end

function SFW.held(pid) local h = MH.shared.world.held[pid] return h and h.record or nil end

function SFW.result(t)
    t.errors = #MH.errors
    t.first_error = MH.errors[1] or ""
    local lines = {}
    for k, v in pairs(t) do lines[#lines + 1] = k .. "=" .. tostring(v) end
    table.sort(lines)
    return table.concat(lines, "\n")
end
