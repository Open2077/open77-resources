-- rp_nomade / server/service.lua: the smuggling run, as hooks of the world-interaction libraries.
--
--   take a run    board target -> action `run_<route>`; reserve hook = the crates (open77_containers,
--                 keyed, presented by open77_actions) + ONE coordinator reservation (goods out of
--                 the camp's stash into the crates, one token minted per crate); commit hook = that
--                 commit, then the crates appear at the loading points
--   carry         open77_actions carry kind `crate`; custody stays in the crate: pickup is
--                 custody-neutral, a put-down on the ground persists the placement (containers place)
--   load          put-down at the truck bay / onto a truck -> rp_cargo:load moves the token
--                 crate -> veh:<plate>:cargo (rp_garage decides who may), the bed prop is rp_cargo's
--   checkpoints   a truck carrying goods inside an NCPD checkpoint zone rolls a search per run and
--                 checkpoint; a search moves every goods of that run in the truck to the evidence
--                 stash in ONE operation, fines the driver and raises their wanted level
--   unload        unload bay action -> rp_cargo:unload brings the token back into its crate, then
--                 a carry pickup lifts it (an emptied crate is thrown away instead)
--   deliver       put-down at the fence -> rp_economy:sale (goods out of the crate, pay to the run's
--                 nomad, the camp's cut to its society), then the crate is retired
--   hand-over     /nomad sell: a crate on the ground, a consented give to another player, one sale
--   return        put-down at the camp's stash -> goods back into the stash, crate retired
--   officer       /nomad search -> (warrant or consent) -> action `ncpd_search`: reserve the
--                 confiscation before the bar, commit it at the end
--
-- Durable state lives in the coordinator (stash, crates, tokens, bed, money) and in open77_containers
-- (each crate's key, placement and public record: run, owner, route, deadline, failure, plate
-- hint, checkpoints passed, a persisted sale quote). This file keeps caches rebuilt at boot.
--
-- Global: NomadService.

NomadService = {}
local S = {}
S.__index = S

local ACTIONS = "open77_actions"
local KIND = "crate"
local TRANSIENT_REFUSAL = { coordinator_unavailable = true, store_unavailable = true, conflict = true }
local DOUBT = { in_doubt = true, busy = true }

function NomadService.new(deps)
    local self = setmetatable({
        cfg = deps.config, M = deps.model, L = deps.ledger, P = deps.ports,
        resource = deps.resource or "rp_nomade",
        routes = {}, checkpoints = {},
        crates = {},         -- [container id] = crate
        byItem = {},         -- [carry item id] = container id
        byToken = {},        -- [token instance id] = container id
        runs = {},           -- [run key] = run
        takes = {},          -- [actions opId] = take reservation (live)
        doubts = {},         -- [tx opId] = take reservation whose commit is in doubt
        seizeDoubts = {},    -- [tx opId] = { spec, meta } a confiscation whose answer was lost
        done = {},           -- [tx opId] = ms (afterTake ran)
        opIds = {},          -- [actions opId] = business op id (retries reuse it)
        offers = {},         -- [interaction id] = a crate offered to a player
        sales = {},          -- [sale opId] = an offer whose sale is in doubt
        searches = {},       -- [interaction id] = an officer waiting for consent
        searchOps = {},      -- [actions opId] = search reservation
        pidOf = {}, subjectOfPid = {},
        navSig = {},         -- [player id] = last navigation signature sent
        notified = {},
        npcs = {},
        forced = {},         -- [run key .. "|" .. checkpoint] = "search" | "pass" (lab only)
        lastRestockWindow = nil,
        ready = false,
        stats = { takes = 0, loads = 0, unloads = 0, deliveries = 0, hot = 0, returns = 0, seized = 0,
                  passes = 0, retired = 0, refusals = 0, doubts = 0, playerSales = 0, reclaimed = 0, restocks = 0 },
    }, S)
    for _, route in ipairs(self.cfg.routes) do self.routes[route.id] = route end
    for _, ck in ipairs(self.cfg.checkpoints) do self.checkpoints[ck.id] = ck end
    return self
end

function S:log(fmt, ...) self.P.log(fmt:format(...)) end
function S:warn(fmt, ...) self.P.warn(fmt:format(...)) end

local function fromActions() return GetInvokingResource() == ACTIONS end
S.fromActions = fromActions

-- ---------------------------------------------------------------------------------------------
-- Players, subjects, telling
-- ---------------------------------------------------------------------------------------------
function S:tell(pid, text, kind)
    pid = self.M.playerId(pid)
    if pid then self.P.tell(pid, text, kind, self.cfg.ui) end
end

function S:refuseTo(pid, reason)
    self.stats.refusals = self.stats.refusals + 1
    pid = self.M.playerId(pid)
    if not pid then return end
    local now = self.P.now()
    if (self.notified[pid] or 0) + self.cfg.notifyCooldownMs > now then return end
    self.notified[pid] = now
    self.P.tell(pid, self.M.textFor(reason), "warning", self.cfg.ui)
end

function S:trackPlayer(pid)
    pid = self.M.playerId(pid)
    if not pid then return nil end
    local subject = self.L.subjectOf(pid)
    if not subject then return nil end
    local old = self.subjectOfPid[pid]
    if old and old ~= subject and self.pidOf[old] == pid then self.pidOf[old] = nil end
    self.subjectOfPid[pid], self.pidOf[subject] = subject, pid
    return subject
end

function S:untrackPlayer(pid)
    if not pid then return end
    local subject = self.subjectOfPid[pid]
    self.subjectOfPid[pid] = nil
    self.navSig[pid] = nil
    self.notified[pid] = nil
    if subject and self.pidOf[subject] == pid then self.pidOf[subject] = nil end
end

-- The online player of a subject, or nil.
function S:playerOf(subject)
    local pid = subject and self.pidOf[subject]
    if pid and self.P.players.name(pid) then return pid end
    return nil
end

function S:subjectOf(pid)
    return self.subjectOfPid[pid] or self:trackPlayer(pid)
end

function S:tellSubject(subject, text, kind)
    local pid = self:playerOf(subject)
    if pid then self:tell(pid, text, kind) end
end

function S:isCrew(pid)
    local ok = self.P.jobs.eligible(pid, self.cfg.eligibility.args)
    return ok == true
end

function S:isPolice(pid)
    local ok = self.P.jobs.eligible(pid, self.cfg.policeEligibility.args)
    return ok == true
end

function S:fixer(kind, pid, ref, data)
    self.P.emit("rp:job:completed", { job = self.cfg.fixerJob, kind = kind, playerId = pid, ref = ref, data = data })
end

-- ---------------------------------------------------------------------------------------------
-- Items, stashes, actions, targets (re-run whenever open77_actions or rp_inventory restarts)
-- ---------------------------------------------------------------------------------------------
function S:defineItems()
    local registered, rejected, details = self.P.inventory.define(self.cfg.items)
    if registered == nil then
        self:warn("rp_inventory:define unavailable (%s): items not defined yet", tostring(rejected))
        return false
    end
    if (tonumber(rejected) or 0) > 0 then
        local names = {}
        for _, c in ipairs(type(details) == "table" and details.collisions or {}) do names[#names + 1] = tostring(c) end
        self:warn("items: %s registered, %s refused %s (another definer owns them)", tostring(registered),
            tostring(rejected), table.concat(names, ","))
    else
        self:log("items defined through rp_inventory: %s", tostring(registered))
    end
    return true
end

-- The camp's stash and the evidence stash have fixed ids: `open` creates them, or finds them again.
function S:openStashes()
    local acc = self.cfg.accounts
    local ok1, why1 = self.L.open(acc.stash, { capacityG = self.cfg.stashCapacityG })
    local ok2, why2 = self.L.open(acc.evidence, { capacityG = self.cfg.evidenceCapacityG })
    if not ok1 then self:warn("camp stash %s not opened: %s", acc.stash, tostring(why1)) end
    if not ok2 then self:warn("evidence stash %s not opened: %s", acc.evidence, tostring(why2)) end
    return ok1 and ok2 and true or false, why1 or why2
end

function S:declare()
    local cfg, A = self.cfg, self.P.actions
    local defs = {}
    for _, route in ipairs(cfg.routes) do
        defs[#defs + 1] = {
            id = "run_" .. route.id, label = ("%s (%d crates)"):format(route.label, route.crates),
            durationMs = cfg.actions.take.durationMs, maxDistance = cfg.maxDistance,
            animation = cfg.actions.take.animation, progress = { label = cfg.actions.take.progress },
            hooks = { validate = "nmdValidate", reserve = "nmdReserve", commit = "nmdCommit", cancel = "nmdCancel" },
            eligibility = cfg.eligibility, epochs = cfg.epochs, reserveTimeoutMs = 30000,
        }
    end
    defs[#defs + 1] = {
        id = "unload", label = cfg.actions.unload.label, durationMs = cfg.actions.unload.durationMs,
        maxDistance = 3.0, progress = { label = cfg.actions.unload.progress },
        hooks = { validate = "nmdValidate", commit = "nmdUnload" }, eligibility = cfg.eligibility, epochs = cfg.epochs,
    }
    defs[#defs + 1] = {
        id = "ncpd_search", label = "Search", durationMs = cfg.officer.durationMs, requiresTarget = false,
        claim = false, animation = cfg.officer.animation, progress = { label = "Searching" },
        hooks = { validate = "nmdValidate", reserve = "nmdSearchReserve", commit = "nmdSearchCommit",
                  cancel = "nmdSearchCancel" },
        eligibility = cfg.policeEligibility, epochs = cfg.epochs,
    }
    for _, def in ipairs(defs) do
        local key, why = A.define(def)
        if not key then
            self:warn("action %s refused by open77_actions: %s", def.id, tostring(why))
            return false
        end
    end
    local kind, why = A.carryDefine({
        id = KIND, model = cfg.crate.model, label = cfg.crate.label, reach = cfg.crate.reach,
        vehicleReach = cfg.crate.vehicleReach, binding = cfg.crate.binding,
        hooks = { validate = "crateValidate", pickup = "cratePickup", putdown = "cratePutdown", dropped = "crateDropped" },
    })
    if not kind then
        self:warn("carry kind refused by open77_actions: %s", tostring(why))
        return false
    end
    local choices = {}
    for index, route in ipairs(cfg.routes) do
        if index <= 4 then
            choices[#choices + 1] = { action = "run_" .. route.id,
                label = ("%s, %d crates"):format(route.label, route.crates) }
        end
    end
    local camp = cfg.camp
    local targets = {
        { id = "board", position = camp.board.position, yaw = camp.board.yaw, bucket = cfg.bucket,
          label = camp.board.label, distance = 2.5, markerDistance = 20.0, requires = "empty", actions = choices },
        { id = "truck_bay", position = camp.truckBay.position, bucket = cfg.bucket, label = camp.truckBay.label,
          distance = 2.5, markerDistance = 20.0, requires = "carrying",
          actions = { { action = "open77_actions:carry_putdown", label = "Load into the truck" } }, data = { bay = "load" } },
        { id = "return_bay", position = camp.returnBay.position, yaw = camp.returnBay.yaw, bucket = cfg.bucket,
          label = camp.returnBay.label, distance = 2.5, markerDistance = 20.0, requires = "carrying",
          actions = { { action = "open77_actions:carry_putdown", label = "Return to the stash" } }, data = { bay = "return" } },
    }
    for _, route in ipairs(cfg.routes) do
        local d = route.destination
        targets[#targets + 1] = { id = "unload_" .. route.id, position = d.unloadBay.position, bucket = cfg.bucket,
            label = d.label, distance = 2.5, markerDistance = 25.0, requires = "empty",
            actions = { { action = "unload", label = "Unload a crate" } }, data = { bay = "unload", route = route.id } }
        targets[#targets + 1] = { id = "fence_" .. route.id, position = d.fence.position, yaw = d.fence.yaw,
            bucket = cfg.bucket, label = d.fence.label, distance = 2.5, markerDistance = 25.0, requires = "carrying",
            actions = { { action = "open77_actions:carry_putdown", label = "Hand over to " .. d.fence.name } },
            data = { bay = "fence", route = route.id } }
    end
    for _, def in ipairs(targets) do
        local key, twhy = A.target(def)
        if not key then self:warn("target %s refused: %s", def.id, tostring(twhy)) end
    end
    -- The truck bays, whose prompts follow the truck parked in them (S:anchorBays).
    self.bayDefs = {}
    for _, def in ipairs(targets) do
        local bay = def.data and def.data.bay
        if bay == "load" then
            self.bayDefs[def.id] = { def = def, bay = camp.truckBay }
        elseif bay == "unload" then
            local route = self:routeById(def.data.route)
            if route then self.bayDefs[def.id] = { def = def, bay = route.destination.unloadBay } end
        end
    end
    return true
end

function S:routeById(id)
    for _, route in ipairs(self.cfg.routes) do
        if route.id == id then return route end
    end
    return nil
end

-- The bay prompts follow the truck parked in the bay (cfg.bayPrompt): re-declared behind its bed
-- when it comes or moves, back at the bay's centre when it leaves. A parked truck covers the
-- centre, where the prompt could not be reached. Never yields.
function S:anchorBays()
    local opt = self.cfg.bayPrompt
    if not (opt and opt.followTruck) or not self.bayDefs then return end
    local vehicles = self.P.vehicles.all()
    for id, b in pairs(self.bayDefs) do
        local at, best = b.bay.position, nil
        for _, v in ipairs(vehicles) do
            local pos = type(v.position) == "table" and v.position or v
            local car = { x = tonumber(pos.x), y = tonumber(pos.y), z = tonumber(pos.z), yaw = tonumber(v.yaw) or 0.0 }
            local d = car.x and car.y and car.z and (v.bucket or 0) == self.cfg.bucket and self.M.planar(car, b.bay.position)
            if d and d <= (b.bay.truckRadius or 8.0) and (best == nil or d < best) then
                local spot = self.M.tailgate(car, self.P.cargo.layout(v.record), opt.behindBedM)
                if spot then at, best = spot, d end
            end
        end
        local mark = ("%.1f,%.1f,%.1f"):format(at.x, at.y, at.z)
        if b.mark ~= mark then
            b.mark = mark
            b.def.position = { x = at.x, y = at.y, z = at.z }
            local key, why = self.P.actions.target(b.def)
            if not key then self:warn("bay prompt %s not moved: %s", id, tostring(why)) end
        end
    end
end

function S:spawnFences()
    local npc = self.cfg.fenceNpc
    if not npc then return end
    for _, route in ipairs(self.cfg.routes) do
        if not self.npcs[route.id] then
            local f = route.destination.fence
            local def = { position = f.position, yaw = f.yaw, bucket = self.cfg.bucket, damagePolicy = npc.damagePolicy }
            if npc.record then def.record = npc.record else def.template = npc.template end
            local ok, id, why = pcall(self.P.npcs.create, def)
            if ok and id then
                self.npcs[route.id] = id
            else
                self:log("fence NPC for %s not spawned (%s): the drop point works without it", route.id,
                    tostring(ok and why or id))
            end
        end
    end
end

-- ---------------------------------------------------------------------------------------------
-- Runs and crates (memory caches of the durable records)
-- ---------------------------------------------------------------------------------------------
function S:runOf(key, meta)
    local run = self.runs[key]
    if run then return run end
    if type(meta) ~= "table" then return nil end
    run = {
        key = key, owner = meta.o, route = meta.r, n = self.M.integer(meta.n) or 0,
        deadline = tonumber(meta.d) or 0, created = tonumber(meta.t) or 0, failed = meta.f,
        passed = {}, crates = {}, told = {}, checking = {},
        delivered = 0, seized = 0, returned = 0, hot = 0, sold = 0, outcomes = {},
    }
    for _, ck in ipairs(type(meta.p) == "table" and meta.p or {}) do run.passed[tostring(ck)] = true end
    self.runs[key] = run
    self:loadTally(run)
    return run
end

-- What became of the crates that left a run (delivered, sold, seized, returned, hot), kept in the
-- resource's kvp. A run is rebuilt from its OPEN crates after a restart and a crate that left it
-- is closed, so the run used to forget it: measured live (2026-10-13), a crate returned to the
-- stash before an `ensure rp_nomade` read "gone" and the run summed "returned 0". One outcome per
-- crate index, the counts recounted from them: a replayed sale or return counts once.
local TALLY = "tally:"
local OUTCOMES = { delivered = true, sold = true, seized = true, returned = true, hot = true }

function S:saveTally(run)
    local words = {}
    for i = 1, run.n do words[i] = run.outcomes[i] or "" end
    local ok, saved = pcall(self.P.kvp.set, TALLY .. run.key, table.concat(words, ","))
    if not ok or saved == false then self:warn("run %s: tally not saved", run.key) end
end

function S:loadTally(run)
    local ok, raw = pcall(self.P.kvp.get, TALLY .. run.key)
    if not ok or type(raw) ~= "string" then return end
    local i = 0
    for word in (raw .. ","):gmatch("([^,]*),") do
        i = i + 1
        if OUTCOMES[word] and i <= run.n then run.outcomes[i] = word end
    end
    self:recount(run)
end

function S:recount(run)
    run.delivered, run.sold, run.seized, run.returned, run.hot = 0, 0, 0, 0, 0
    for _, word in pairs(run.outcomes) do run[word] = run[word] + 1 end
end

function S:noteOutcome(run, crate, word)
    if not run or not OUTCOMES[word] then return end
    local i = crate and self.M.integer(crate.i)
    if not i or i < 1 or i > run.n then
        run[word] = run[word] + 1   -- no index to remember it by: counted, not kept
        return
    end
    run.outcomes[i] = word
    self:recount(run)
    self:saveTally(run)
end

-- After the crates are rebuilt: the tallies of runs that are gone (every crate closed) are dropped.
function S:purgeTallies()
    local ok, keys = pcall(self.P.kvp.keys, TALLY, 256)
    if not ok or type(keys) ~= "table" then return end
    local dropped = 0
    for _, key in ipairs(keys) do
        local name = type(key) == "table" and key.key or key
        if type(name) == "string" and not self.runs[name:sub(#TALLY + 1)] then
            pcall(self.P.kvp.delete, name)
            dropped = dropped + 1
        end
    end
    if dropped > 0 then self:log("%d finished run tally(ies) dropped", dropped) end
end

function S:adopt(id, meta, placement)
    local crate = self.crates[id]
    local index = self.M.integer(meta.i) or 0
    if not crate then
        crate = { id = id, run = meta.run, i = index, key = self.M.crateKey(meta.run, index),
                  iid = self.M.tokenOf(meta.run, index) }
        self.crates[id] = crate
        self.byToken[crate.iid] = id
    end
    crate.meta = self.M.copy(meta)
    if placement then
        crate.position = placement.position and { x = placement.position.x, y = placement.position.y,
            z = placement.position.z } or crate.position
        crate.yaw = placement.yaw or crate.yaw or 0.0
        crate.bucket = placement.bucket or crate.bucket or self.cfg.bucket
    end
    local run = self:runOf(meta.run, meta)
    run.crates[index] = id
    if meta.f and not run.failed then run.failed = meta.f end
    for _, ck in ipairs(type(meta.p) == "table" and meta.p or {}) do run.passed[tostring(ck)] = true end
    return crate, run
end

function S:forget(crate)
    if crate.itemId then self.byItem[crate.itemId] = nil end
    if self.byToken[crate.iid] == crate.id then self.byToken[crate.iid] = nil end
    self.crates[crate.id] = nil
    crate.state = "done"
end

function S:openCount()
    local n = 0
    for _ in pairs(self.crates) do n = n + 1 end
    return n
end

function S:runLive(run)
    return run ~= nil and not run.failed and not run.ended and self.P.now() <= run.deadline
end

-- Crates of a run still holding goods.
function S:goodsLeft(run)
    local n = 0
    for _, id in pairs(run.crates) do
        local crate = self.crates[id]
        if crate and (crate.goods or 0) > 0 then n = n + 1 end
    end
    return n
end

function S:allLoaded(run)
    local any = false
    for _, id in pairs(run.crates) do
        local crate = self.crates[id]
        if crate and (crate.goods or 0) > 0 then
            any = true
            if crate.state ~= "truck" then return false end
        end
    end
    return any
end

-- The subject's live run, else a run that failed with goods still out (the way back to camp).
function S:activeRunOf(subject)
    local failed
    for _, run in pairs(self.runs) do
        if run.owner == subject and not run.ended then
            if not run.failed then return run end
            failed = failed or run
        end
    end
    return failed
end

-- Runs that block a new one: live (not ended, not failed). A failed run never blocks the next.
function S:runsOf(subject)
    local n = 0
    for _, run in pairs(self.runs) do
        if run.owner == subject and not run.ended and not run.failed and self:goodsLeft(run) > 0 then n = n + 1 end
    end
    return n
end

-- The prop players see for a crate on the ground: an open77_actions carry item.
function S:placeItem(crate)
    if crate.itemId and self.P.actions.carryGet(crate.itemId) then return crate.itemId end
    if crate.itemId then self.byItem[crate.itemId] = nil end
    if not crate.position then return nil, "no_position" end
    local itemId, why = self.P.actions.carryPlace(KIND, {
        position = crate.position, yaw = crate.yaw or 0.0, bucket = crate.bucket or self.cfg.bucket,
        data = { container = crate.id },
    })
    if not itemId then
        crate.itemId, crate.unplaced = nil, true
        self:warn("crate %s not placed: %s", crate.id, tostring(why))
        return nil, why
    end
    crate.itemId, crate.unplaced = itemId, nil
    self.byItem[itemId] = crate.id
    return itemId
end

function S:unplaceItem(crate)
    if not crate.itemId then return end
    self.byItem[crate.itemId] = nil
    self.P.actions.carryRemove(crate.itemId)
    crate.itemId = nil
end

-- Writes the crate's public record (failure, plate hint, checkpoints, sale quote).
function S:persistMeta(crate)
    local ok, why = self.P.containers.setPublic(crate.id, crate.meta)
    if ok then
        crate.dirty = nil
        return true
    end
    crate.dirty = true
    return nil, why
end

-- A durable placement (where the crate stands on the ground).
function S:setPlacement(crate, position, yaw, bucket)
    crate.position = { x = position.x, y = position.y, z = position.z }
    if yaw ~= nil then crate.yaw = yaw end
    if bucket ~= nil then crate.bucket = bucket end
    local ok, why = self.P.containers.place(crate.id, { position = crate.position, yaw = crate.yaw or 0.0,
        bucket = crate.bucket or self.cfg.bucket })
    if not ok then
        crate.placeDirty = true
        self:warn("placement of %s not persisted (%s): retried by the sweep", crate.id, tostring(why))
    else
        crate.placeDirty = nil
    end
end

-- ---------------------------------------------------------------------------------------------
-- Navigation (client pins and GPS route)
-- ---------------------------------------------------------------------------------------------
function S:navFor(subject)
    local nav = self.cfg.navigation
    if not nav or nav.enabled == false then return false end
    local run = self:activeRunOf(subject)
    if not run then return false end
    local left = self:goodsLeft(run)
    if left == 0 then return false end
    local out = { run = run.key, left = left }
    if run.failed and run.failed ~= "deadline" then return false end
    if run.failed or self.P.now() > run.deadline then
        out.phase = "camp"
        out.target = self.M.copy(self.cfg.camp.returnBay.position)
        out.title = self.cfg.camp.label
        out.description = "The run is off. Bring the crates back to the camp's stash."
        out.sprite = nav.campSprite
        out.route = true
    else
        local route = self.routes[run.route]
        if not route then return false end
        out.phase = "destination"
        out.target = self.M.copy(route.destination.unloadBay.position)
        out.title = route.destination.label
        out.description = ("%d crate%s for %s. Park at the bay, unload, hand over."):format(left,
            left == 1 and "" or "s", route.destination.fence.name)
        out.sprite = nav.destinationSprite
        out.route = nav.gpsFrom == "accepted" or self:allLoaded(run)
        out.deadline = run.deadline
    end
    if nav.showCheckpoints then
        out.checkpoints = {}
        for _, ck in ipairs(self.cfg.checkpoints) do
            out.checkpoints[#out.checkpoints + 1] = { id = ck.id, label = ck.label, x = ck.zone.position.x,
                y = ck.zone.position.y, z = ck.zone.position.z }
        end
        out.checkpointSprite = nav.checkpointSprite
    end
    return out
end

local function navSignature(nav)
    if not nav then return "none" end
    return table.concat({ nav.run or "", nav.phase or "", tostring(nav.route), tostring(nav.left) }, "|")
end

function S:pushNav(subject, force)
    local pid = self:playerOf(subject)
    if not pid then return end
    local nav = self:navFor(subject)
    local sig = navSignature(nav)
    if not force and self.navSig[pid] == sig then return end
    self.navSig[pid] = sig
    self.P.toClient(pid, "rp_nomade:nav", nav)
end

function S:pushRun(run) if run and run.owner then self:pushNav(run.owner) end end

-- ---------------------------------------------------------------------------------------------
-- Hooks: validate (synchronous, every action of this resource)
-- ---------------------------------------------------------------------------------------------
function S:routeOfAction(actionId)
    local id = type(actionId) == "string" and actionId:match("^run_(.+)$") or nil
    return id and self.routes[id] or nil
end

function S:searchTargetPosition(target)
    if type(target) ~= "table" then return nil end
    if target.kind == "truck" then return self.P.vehicles.position(target.vehicleId) end
    local crate = target.crate and self.crates[target.crate]
    return crate and crate.position or nil
end

function S:validate(ctx)
    if not fromActions() then return false, "not_owner" end
    if not self.ready then return false, "nomad_unavailable" end
    local action = ctx.actionId
    local route = self:routeOfAction(action)
    if route then
        if ctx.phase == "begin" then
            local subject = self:subjectOf(ctx.playerId)
            if subject and self:runsOf(subject) >= self.cfg.maxRunsPerNomad then
                self:refuseTo(ctx.playerId, "run_running")
                return false, "run_running"
            end
            if self:openCount() + route.crates > self.cfg.maxOpenCrates then
                self:refuseTo(ctx.playerId, "camp_full")
                return false, "camp_full"
            end
        end
        return true
    elseif action == "ncpd_search" then
        local target = type(ctx.data) == "table" and ctx.data or nil
        local at = self:searchTargetPosition(target)
        local me = self.P.players.position(ctx.playerId)
        local reach = (target and target.kind == "crate") and self.cfg.officer.crateReachM or self.cfg.officer.reachM
        local slack = ctx.phase == "complete" and 1.5 or 0.0
        local d = self.M.distance(me, at)
        if not d or d > reach + slack then return false, "too_far" end
        return true
    end
    return true
end

-- ---------------------------------------------------------------------------------------------
-- Hooks: taking a run (reserve -> commit, or cancel)
-- ---------------------------------------------------------------------------------------------
local CONTAINERS_TRANSIENT = { not_ready = true, busy = true, open77_containers_unavailable = true }

function S:closeCrates(ids, reason)
    for _, id in ipairs(ids or {}) do
        local ok, why = self.P.containers.close(id, { reason = reason or "cancelled" })
        if not ok and why ~= "unknown_container" and why ~= "container_closed" then
            self:log("empty crate %s not closed yet (%s): the sweep retries", id, tostring(why))
            self.closeLater = self.closeLater or {}
            self.closeLater[id] = true
        end
        local crate = self.crates[id]
        if crate then self:forget(crate) end
    end
end

function S:reserveTake(ctx)
    if not fromActions() then return nil, "not_owner" end
    if not self.P.actions.verify(ctx.opId, "reserve") then return nil, "not_owner" end
    if not self.ready then return nil, "nomad_unavailable" end
    local cfg, M, L = self.cfg, self.M, self.L
    local route = self:routeOfAction(ctx.actionId)
    if not route then return nil, "unknown_route" end
    local pid = ctx.playerId
    local subject, why = L.subjectOf(pid)
    if not subject then return nil, why or "subject_unavailable" end
    if self:runsOf(subject) >= cfg.maxRunsPerNomad then return nil, "run_running" end
    if route.crates > #cfg.camp.loadingPoints then return nil, "camp_full" end
    local rawId = L.rawId()
    local runKey = M.runKeyOf(rawId)
    if not runKey then return nil, "nomad_unavailable" end
    local txOpId = "nmd.run:" .. rawId
    local now = self.P.now()
    local deadline = now + route.timeLimitMs
    local capacityG = M.capacityG(cfg.weightsG, cfg.goodsItem, cfg.tokenItem, route.goodsPerCrate)
    local ids = {}
    for i = 1, route.crates do
        local point = cfg.camp.loadingPoints[i]
        local meta = M.crateMeta({ run = runKey, i = i, n = route.crates, owner = subject, route = route.id,
            deadline = deadline, created = now })
        local summary, cwhy = self.P.containers.create({
            key = M.crateKey(runKey, i), kind = "crate", model = cfg.crate.model, projection = "external",
            position = { x = point.x, y = point.y, z = point.z }, yaw = 0.0, bucket = ctx.bucket or cfg.bucket,
            capacityG = capacityG, label = "Nomad crate", public = meta,
        })
        if type(summary) ~= "table" or not summary.id then
            self:closeCrates(ids, "cancelled")
            if CONTAINERS_TRANSIENT[cwhy] then return nil, "nomad_unavailable" end
            if cwhy == "namespace_denied" then return nil, "nomad_not_configured" end
            return nil, cwhy or "nomad_unavailable"
        end
        ids[#ids + 1] = summary.id
    end
    local reserved, reason = L.reserve({
        opId = txOpId, kind = "nomad.take", actor = "char:" .. subject, reason = "nomad run " .. route.id,
        ttlMs = cfg.actions.take.durationMs + 30000,
        lines = M.stockLines({ goodsItem = cfg.goodsItem, tokenItem = cfg.tokenItem, goodsPerCrate = route.goodsPerCrate,
            stash = cfg.accounts.stash, tokens = cfg.accounts.tokens }, ids, runKey, subject),
    })
    if not reserved then
        self:closeCrates(ids, "cancelled")
        return nil, M.takeRefusal(reason)
    end
    local r = { txOpId = txOpId, run = runKey, route = route.id, subject = subject, pid = pid, crates = ids,
                deadline = deadline, created = now, goods = route.goodsPerCrate, bucket = ctx.bucket or cfg.bucket }
    self.takes[ctx.opId] = r
    self.opIds[ctx.opId] = txOpId
    return r
end

function S:afterTake(r, receipt)
    if self.done[r.txOpId] then return end
    self.done[r.txOpId] = self.P.now()
    self.doubts[r.txOpId] = nil
    self.stats.takes = self.stats.takes + 1
    local cfg, M = self.cfg, self.M
    local route = self.routes[r.route]
    for i, id in ipairs(r.crates) do
        local point = cfg.camp.loadingPoints[i]
        local meta = M.crateMeta({ run = r.run, i = i, n = #r.crates, owner = r.subject, route = r.route,
            deadline = r.deadline, created = r.created })
        local crate = self:adopt(id, meta, { position = point, yaw = 0.0, bucket = r.bucket })
        crate.state, crate.goods = "ground", r.goods
        self:placeItem(crate)
    end
    local run = self.runs[r.run]
    local minutes = M.minutesLeft(r.deadline, self.P.now())
    local dest = route and route.destination
    local text = ("Run signed: %d crates of %s for %s, %d minutes. Load them in a truck you hold a key for " ..
        "(the bay is south-east of the board) and drive. The pay is %s per crate, the camp keeps %d%%.")
        :format(#r.crates, cfg.items[cfg.goodsItem].label:lower(), dest and dest.label or r.route, minutes,
        M.money(route and route.price or 0), math.floor(cfg.campCut * 100 + 0.5))
    self:tellSubject(r.subject, text, "success")
    self:log("run %s taken by %s: route %s, %d crates, deadline in %d min (op %s%s)", r.run, r.subject, r.route,
        #r.crates, minutes, r.txOpId, receipt and receipt.replay and ", replay" or "")
    self:fixer("pickup", self:playerOf(r.subject) or r.pid, r.txOpId,
        { run = r.run, route = r.route, crates = #r.crates, deadline = r.deadline })
    self:pushRun(run)
end

function S:commitTake(ctx)
    if not fromActions() then return nil, "not_owner" end
    if not self.P.actions.verify(ctx.opId, "commit") then return nil, "not_owner" end
    local r = ctx.reservation
    if type(r) ~= "table" or not r.txOpId then return nil, "no_reservation" end
    local receipt, why = self.L.commit(r.txOpId)
    if not receipt then
        if DOUBT[why] then
            self.doubts[r.txOpId] = r
        elseif TRANSIENT_REFUSAL[why] and self.doubts[r.txOpId] then
            why = "in_doubt"
        end
        return nil, why
    end
    local ok, err = pcall(self.afterTake, self, r, receipt)
    if not ok then self:warn("after take %s raised: %s", r.txOpId, tostring(err)) end
    return { tx = r.txOpId, run = r.run, crates = #r.crates, replay = receipt.replay == true }
end

function S:cancelTake(ctx)
    if not fromActions() then return end
    self.takes[ctx.opId] = nil
    self.opIds[ctx.opId] = nil
    local r = ctx.reservation
    if type(r) ~= "table" or not r.txOpId then return end
    if ctx.reason == "in_doubt" then
        self.doubts[r.txOpId] = r
        self.stats.doubts = self.stats.doubts + 1
        self:settleTake(r)
        return
    end
    self.L.cancel(r.txOpId, ctx.reason)
    self:closeCrates(r.crates, "cancelled")
end

function S:settleTake(r)
    local outcome, receipt = self.L.settle(r.txOpId)
    if outcome == "committed" then
        self:afterTake(r, receipt)
    elseif outcome == "failed" or outcome == "aborted" then
        self.doubts[r.txOpId] = nil
        self:log("run %s settled: %s (nothing was taken out of the stash)", r.run, outcome)
        self:closeCrates(r.crates, "cancelled")
    end
    return outcome
end

-- ---------------------------------------------------------------------------------------------
-- Trucks
-- ---------------------------------------------------------------------------------------------
-- The nearest truck to `origin` the player may use for `action` ("put" | "take"): tracked (a
-- plate), with a cargo layout, in the player's bucket. Returns vehicleId, plate | nil, reason.
function S:truckNear(pid, origin, radius, action)
    local read = self.P.players.position(pid)
    local bucket = read and read.bucket or 0
    local best, bestPlate, bestD, refusal
    for _, v in ipairs(self.P.vehicles.all()) do
        local pos = type(v.position) == "table" and v.position or (v.x and { x = v.x, y = v.y, z = v.z }) or nil
        local d = pos and self.M.distance(pos, origin)
        if v.id and d and d <= radius and (v.bucket or 0) == bucket and self.P.cargo.layout(v.record) then
            local plate = self.P.garage.plateOf(v.id)
            if type(plate) ~= "string" then
                refusal = refusal or "vehicle_not_tracked"
            else
                local allowed, why = self.P.garage.canAccess(pid, plate, "cargo", action)
                if allowed == true then
                    if not bestD or d < bestD then best, bestPlate, bestD = v.id, plate, d end
                else
                    refusal = why or "no_access"
                end
            end
        end
    end
    if best then return best, bestPlate end
    return nil, refusal or "no_truck"
end

function S:vehicleOfPlate(plate)
    local d = self.P.garage.describe(plate)
    return type(d) == "table" and d.vehicleId or nil
end

-- ---------------------------------------------------------------------------------------------
-- Carry hooks
-- ---------------------------------------------------------------------------------------------
function S:crateOf(ctx)
    local data = type(ctx.carry) == "table" and ctx.carry.data or ctx.data
    local id = type(data) == "table" and data.container or nil
    return id and self.crates[id] or nil
end

function S:crateValidate(ctx)
    if not fromActions() then return false, "not_owner" end
    if not self.ready then return false, "nomad_unavailable" end
    local crate = self:crateOf(ctx)
    if not crate then return false, "crate_unavailable" end
    if ctx.kind == "carry_pickup" then
        if crate.state ~= "ground" then return false, "crate_unavailable" end
        if crate.offer or crate.reservedBy then return false, "crate_busy" end
        if self.cfg.crate.pickupBy == "crew" and not self:isCrew(ctx.playerId) then
            self:refuseTo(ctx.playerId, "not_crew")
            return false, "not_crew"
        end
    end
    return true
end

-- End of the pickup clip. Custody does not move: the crate stays where its token is.
function S:cratePickup(ctx)
    if not fromActions() then return nil, "not_owner" end
    local crate = self:crateOf(ctx)
    if not crate or crate.state ~= "ground" then return nil, "crate_unavailable" end
    local snap, why = self.L.read(crate.id)
    if type(snap) ~= "table" then
        return nil, why == "unknown_account" and "crate_unavailable" or (why or "nomad_unavailable")
    end
    if not self.M.tokenHere(snap, crate.iid) then return nil, "crate_unavailable" end
    crate.goods = self.M.goodsIn(snap, self.cfg.goodsItem)
    crate.state, crate.carrier = "carried", ctx.playerId
    -- A crate lifted by somebody outside the crew while its run is live: the run is lost (theft
    -- is role-play; the goods go where the thief takes them).
    local run = self.runs[crate.run]
    if self:runLive(run) and crate.goods > 0 then
        local subject = self:subjectOf(ctx.playerId)
        if subject ~= run.owner and not self:isCrew(ctx.playerId) then
            self:spawnFail(run, "stolen")
        end
    end
    return { crate = crate.id }
end

function S:cratePutdown(ctx)
    if not fromActions() then return nil, "not_owner" end
    local crate = self:crateOf(ctx)
    if not crate or crate.state ~= "carried" then return nil, "crate_unavailable" end
    local dest = ctx.carry and ctx.carry.destination or { kind = "ground" }
    local tdata = type(ctx.target) == "table" and type(ctx.target.data) == "table" and ctx.target.data or {}
    local bay = tdata.bay or (type(ctx.data) == "table" and ctx.data.intent) or nil
    if bay == "fence" then return self:sellToFence(ctx, crate, tdata.route or (type(ctx.data) == "table" and ctx.data.route)) end
    if bay == "return" then return self:returnToCamp(ctx, crate) end
    if bay == "load" or dest.kind == "vehicle" then return self:load(ctx, crate, dest, bay) end
    -- On the ground (G) or on a point: custody unchanged, the placement becomes durable.
    local read = self.P.players.get(ctx.playerId)
    local spot, yaw
    if dest.kind == "point" and dest.position then
        spot, yaw = dest.position, dest.yaw or 0.0
    else
        local origin = (read and read.position) or crate.position
        yaw = (read and (read.heading or read.yaw)) or 0.0
        spot = self.M.offsetPoint(origin, yaw, 0.7)
    end
    crate.state, crate.carrier = "ground", nil
    self:setPlacement(crate, spot, yaw, read and read.bucket or crate.bucket)
    return { placement = { kind = "point", position = spot, yaw = yaw } }
end

-- Death, disconnect, a vehicle, combat, a job change...: the item lies at the carrier's feet.
function S:crateDropped(ctx)
    if not fromActions() then return end
    local crate = self:crateOf(ctx)
    if not crate then return end
    crate.carrier = nil
    if crate.state == "carried" then crate.state = "ground" end
    if crate.state == "ground" and type(ctx.position) == "table" then
        self:setPlacement(crate, ctx.position, nil, nil)
    end
    self:log("crate %s dropped (%s)", crate.id, tostring(ctx.reason))
end

-- ---------------------------------------------------------------------------------------------
-- Load: the token leaves the crate for the bed (rp_cargo; rp_garage decides who may)
-- ---------------------------------------------------------------------------------------------
function S:load(ctx, crate, dest, bay)
    local pid = ctx.playerId
    local vid = dest.kind == "vehicle" and dest.vehicleId or nil
    if not vid then
        local origin = bay == "load" and self.cfg.camp.truckBay.position or (self.P.players.position(pid) or crate.position)
        local radius = bay == "load" and self.cfg.camp.truckBay.truckRadius or self.cfg.truckNearM
        local why
        vid, why = self:truckNear(pid, origin, radius, "put")
        if not vid then return nil, why end
    end
    local opId = self.opIds[ctx.opId] or self.L.newOpId("load")
    self.opIds[ctx.opId] = opId
    local granted, gwhy = self.L.authorize(opId, "rp_cargo", { crate.id }, 60000)
    if not granted then return nil, gwhy or "nomad_not_configured" end
    local res, why = self.P.cargo.load(pid, vid, crate.iid, {
        opId = opId, from = crate.id, item = self.cfg.tokenItem, model = self.cfg.crate.bedModel,
    })
    if not res then
        if why == "busy" then why = "in_doubt" end
        return nil, why
    end
    self.stats.loads = self.stats.loads + 1
    crate.state, crate.carrier, crate.plate = "truck", nil, res.plate
    if crate.itemId then self.byItem[crate.itemId] = nil end
    crate.itemId = nil                              -- the put-down removes the carried item
    crate.meta.w = res.plate
    self:persistMeta(crate)                         -- a hint only; the coordinator is the truth
    local run = self.runs[crate.run]
    local text = ("Crate %d/%d loaded on %s."):format(crate.i, run and run.n or crate.i, tostring(res.plate))
    if run and self:allLoaded(run) and self:runLive(run) then
        local route = self.routes[run.route]
        text = text .. (" Everything is in. Drive to %s: the GPS route is on your map. Mind the NCPD checkpoints.")
            :format(route and route.destination.label or "the drop")
    end
    self:tell(pid, text, "success")
    self:log("crate %s loaded on %s slot %s by player %d (op %s%s)", crate.id, tostring(res.plate), tostring(res.slot),
        pid, opId, res.replay and ", replay" or "")
    self:pushRun(run)
    return { placement = { kind = "remove" }, load = { plate = res.plate, slot = res.slot } }
end

-- ---------------------------------------------------------------------------------------------
-- Unload: the token comes back into its crate, then the player lifts it
-- ---------------------------------------------------------------------------------------------
-- The container behind a token instance (ours or found again by its key).
function S:crateOfToken(iid)
    local id = self.byToken[iid]
    if id and self.crates[id] then return self.crates[id] end
    local runKey, index = tostring(iid):match("^nmdc%.(.+)%.(%d+)$")
    if not runKey then return nil end
    local summary = self.P.containers.find(self.M.crateKey(runKey, tonumber(index)))
    if type(summary) ~= "table" or not self.M.isOurs(summary.public) then return nil end
    local crate = self:adopt(summary.id, summary.public, summary)
    crate.state = "truck"
    return crate
end

function S:unloadCrate(pid, vid, origin, radius, key)
    local plate
    if not vid then
        local why
        vid, why = self:truckNear(pid, origin, radius, "take")
        if not vid then return nil, why end
    end
    local view, cwhy = self.P.cargo.contents(pid, vid)
    if type(view) ~= "table" then return nil, cwhy end
    plate = view.plate
    -- Goods first (the subject's own run first), then emptied crates to throw away.
    local subject = self:subjectOf(pid)
    local pick, pickRank
    for _, slot in ipairs(view.slots or {}) do
        for _, object in ipairs(slot.objects or {}) do
            if object.item == self.cfg.tokenItem then
                local crate = self:crateOfToken(object.instance)
                if crate then
                    local run = self.runs[crate.run]
                    local rank = ((crate.goods or 0) > 0 and 0 or 2) + ((run and run.owner == subject) and 0 or 1)
                    if not pickRank or rank < pickRank or (rank == pickRank and crate.id < pick.id) then
                        pick, pickRank = crate, rank
                    end
                end
            end
        end
    end
    if not pick then return nil, "no_nomad_crate" end
    local crate = pick
    local opId = (key and self.opIds[key]) or self.L.newOpId("unload")
    if key then self.opIds[key] = opId end
    local granted, gwhy = self.L.authorize(opId, "rp_cargo", { crate.id }, 60000)
    if not granted then return nil, gwhy or "nomad_not_configured" end
    local res, why = self.P.cargo.unload(pid, vid, crate.iid, { to = crate.id, opId = opId })
    if not res then
        if why == "busy" then why = "in_doubt" end
        return nil, why
    end
    self.stats.unloads = self.stats.unloads + 1
    crate.plate = nil
    crate.meta.w = nil
    local snap = self.L.read(crate.id)
    if type(snap) == "table" then crate.goods = self.M.goodsIn(snap, self.cfg.goodsItem) end
    if (crate.goods or 0) == 0 then
        -- An emptied crate (the NCPD took its goods): thrown away, nothing to carry.
        crate.state = "empty"
        self:retire(crate)
        self:tell(pid, "An empty crate: the NCPD cleaned it out. Thrown away.", "info")
        self:log("crate %s unloaded empty from %s by player %d and retired (op %s)", crate.id, tostring(plate), pid, opId)
        return crate, nil
    end
    local read = self.P.players.get(pid)
    local yaw = (read and (read.heading or read.yaw)) or 0.0
    local origin2 = (read and read.position) or origin
    crate.state = "ground"
    self:setPlacement(crate, self.M.offsetPoint(origin2, yaw, 0.7), yaw, read and read.bucket or crate.bucket)
    self:persistMeta(crate)
    local itemId = self:placeItem(crate)
    self:log("crate %s unloaded from %s by player %d (op %s%s)", crate.id, tostring(plate), pid, opId,
        res.replay and ", replay" or "")
    self:pushRun(self.runs[crate.run])
    return crate, itemId
end

function S:unloadAction(ctx)
    if not fromActions() then return nil, "not_owner" end
    if not self.P.actions.verify(ctx.opId, "commit") then return nil, "not_owner" end
    local tdata = type(ctx.target) == "table" and type(ctx.target.data) == "table" and ctx.target.data or {}
    local route = self.routes[tdata.route or ""]
    local bay = route and route.destination.unloadBay or self.cfg.camp.truckBay
    local crate, itemOrWhy = self:unloadCrate(ctx.playerId, nil, bay.position, bay.truckRadius, ctx.opId)
    if not crate then return nil, itemOrWhy end
    return { crate = crate.id, item = itemOrWhy }
end

-- ---------------------------------------------------------------------------------------------
-- Retire: the crate's token is burned and the empty container closed. Idempotent by state.
-- ---------------------------------------------------------------------------------------------
-- `inPutdown`: called from the put-down that hands the crate over; that put-down's placement
-- (`remove`) takes the carried prop away itself, so the item is only forgotten here.
function S:retire(crate, inPutdown)
    if crate.retiring then return false end
    crate.retiring = true
    local ok, done = pcall(self._retire, self, crate, inPutdown)
    crate.retiring = nil
    if not ok then
        crate.retirePending = true
        self:warn("retire of %s raised: %s", crate.id, tostring(done))
        return false
    end
    return done
end

function S:_retire(crate, inPutdown)
    crate.state = crate.state == "done" and "done" or "empty"
    if crate.itemId then
        if inPutdown then
            self.byItem[crate.itemId] = nil
            crate.itemId = nil
        else
            self:unplaceItem(crate)
        end
    end
    local snap, rwhy = self.L.read(crate.id)
    if type(snap) ~= "table" then
        if rwhy == "unknown_account" then
            crate.retirePending = nil
            self:forget(crate)
            return true
        end
        crate.retirePending = true
        return false
    end
    if self.M.goodsIn(snap, self.cfg.goodsItem) > 0 then
        crate.retirePending = nil
        crate.goods = self.M.goodsIn(snap, self.cfg.goodsItem)
        return false                              -- never throw goods away
    end
    if self.M.tokenHere(snap, crate.iid) then
        local r, why = self.L.transfer({
            opId = self.L.newOpId("retire"), kind = "nomad.retire", reason = "crate retired",
            lines = { { instance = crate.iid, from = crate.id, to = self.cfg.accounts.tokens } },
        })
        if not r and why ~= "instance_unavailable" and why ~= "insufficient_items" then
            crate.retirePending = true
            return false
        end
    elseif crate.plate or crate.meta.w then
        -- The token rides in a bed: the crate is retired when it is unloaded.
        crate.retirePending = nil
        return false
    end
    local ok, why = self.P.containers.close(crate.id, { reason = "retired" })
    if ok or why == "unknown_container" or why == "container_closed" then
        crate.retirePending = nil
        self.stats.retired = self.stats.retired + 1
        self:forget(crate)
        return true
    end
    crate.retirePending = true
    return false
end

-- ---------------------------------------------------------------------------------------------
-- Runs: failure, end
-- ---------------------------------------------------------------------------------------------
local FAIL_TEXT = {
    deadline = "Too late: the run is off. Bring the crates back to the camp's stash; the fence pays hot prices only now.",
    stolen = "Someone else is carrying one of your crates: the run is off.",
    truck_destroyed = "The truck is wrecked: the run is off.",
    truck_lost = "The truck is gone: the run is off.",
    impounded = "The truck was impounded: the run is off.",
}

-- Marks a run failed and writes it on every open crate of the run (async).
function S:failRun(run, reason)
    if not run or run.failed or run.ended then return end
    run.failed = reason
    for _, id in pairs(run.crates) do
        local crate = self.crates[id]
        if crate then
            crate.meta.f = reason
            self:persistMeta(crate)
        end
    end
    self:log("run %s of %s failed: %s (%d crate(s) with goods left)", run.key, tostring(run.owner), reason, self:goodsLeft(run))
    self:tellSubject(run.owner, FAIL_TEXT[reason] or ("The run is off: " .. tostring(reason) .. "."), "warning")
    self:pushRun(run)
    if self:goodsLeft(run) == 0 then self:endRun(run, reason) end
end

function S:spawnFail(run, reason)
    if not run or run.failed or run.ended or run.failing then return end
    run.failing = true
    self.P.spawn(function()
        local ok, err = pcall(self.failRun, self, run, reason)
        run.failing = nil
        if not ok then self:warn("failRun raised: %s", tostring(err)) end
    end)
end

function S:endRun(run, outcome)
    if run.ended then return end
    run.ended = outcome or "ended"
    self:log("run %s of %s ended: %s (delivered %d, hot %d, sold to players %d, seized %d, returned %d)", run.key,
        tostring(run.owner), run.ended, run.delivered, run.hot, run.sold, run.seized, run.returned)
    self:pushRun(run)
end

-- A crate left its run (sold, returned, seized): end the run once no goods are left.
function S:afterCrate(run)
    if not run or run.ended then return end
    if self:goodsLeft(run) > 0 then
        self:pushRun(run)
        return
    end
    local outcome = run.failed or "delivered"
    if not run.failed then
        if run.seized > 0 and run.delivered + run.sold == 0 then outcome = "confiscated"
        elseif run.returned > 0 and run.delivered + run.sold == 0 then outcome = "returned" end
    end
    if run.delivered + run.sold > 0 and not run.failed then
        self:tellSubject(run.owner, ("Run complete: %d crate(s) delivered."):format(run.delivered + run.sold), "success")
    end
    self:endRun(run, outcome)
end

-- ---------------------------------------------------------------------------------------------
-- Deliver to the fence: one rp_economy:sale (goods out of the crate + pay + the camp's cut), with
-- the quote persisted in the crate's record BEFORE paying, so a crash at any point either finds the
-- sale committed (and retires the crate) or retries it under a fresh attempt id.
-- ---------------------------------------------------------------------------------------------
function S:saleSpec(crate, quote)
    local payees = { { subject = quote.to, amount = quote.owner } }
    if (quote.cut or 0) > 0 then payees[#payees + 1] = { society = self.cfg.society, amount = quote.cut } end
    local spec = {
        opId = quote.op, seller = { subject = quote.by },
        items = { { item = self.cfg.goodsItem, count = quote.goods, from = crate.id } },
        total = quote.total, payees = payees, reason = quote.hot and "nomad hot goods" or "nomad delivery",
    }
    if quote.buyer == "fence" then spec.buyer = { sys = "fence" } else spec.buyer = { player = quote.buyerPid } end
    return spec
end

-- committed | pending | failed | aborted | none
function S:settleSale(crate)
    local quote = crate.meta.s
    if not quote then return "none" end
    local outcome = self.L.settle(quote.op)
    if outcome == "committed" then
        self:log("sale %s of %s found committed: retiring the crate", quote.op, crate.id)
        crate.goods = 0
        self:retire(crate)
    elseif outcome == "failed" or outcome == "aborted" then
        crate.saleChecked = quote.op
    end
    return outcome
end

function S:afterDelivery(crate, quote, receipt, pid, inPutdown)
    local run = self.runs[crate.run]
    crate.goods = 0
    local replay = type(receipt) == "table" and receipt.replay == true
    self:noteOutcome(run, crate, quote.hot and "hot" or (quote.buyer == "fence" and "delivered" or "sold"))
    if quote.hot then self.stats.hot = self.stats.hot + 1
    elseif quote.buyer == "fence" then self.stats.deliveries = self.stats.deliveries + 1
    else self.stats.playerSales = self.stats.playerSales + 1 end
    self:log("sale %s of crate %s (%s) by %s: total=%d to=%s owner=%d cut=%d%s%s", quote.op, crate.id, quote.buyer,
        tostring(quote.by), quote.total, tostring(quote.to), quote.owner, quote.cut, quote.hot and " HOT" or "",
        replay and " (replay)" or "")
    if not quote.hot and run then
        self:fixer("deliver", self:playerOf(run.owner) or pid, quote.op, {
            run = run.key, route = run.route, crate = crate.i, of = run.n, pay = quote.owner, cut = quote.cut,
            buyer = quote.buyer, complete = self:goodsLeft(run) == 0,
        })
        if pid and self:subjectOf(pid) ~= run.owner then
            self:tellSubject(run.owner, ("Crate %d/%d handed over: +%s (the camp keeps %s)."):format(crate.i, run.n,
                self.M.money(quote.owner), self.M.money(quote.cut)), "success")
        end
    end
    self:retire(crate, inPutdown)
    self:afterCrate(run)
end

function S:sellToFence(ctx, crate, routeId)
    local pid = ctx.playerId
    local cfg, M = self.cfg, self.M
    local route = self.routes[routeId or ""]
    if not route then return nil, "unknown_route" end
    local subject, swhy = self:subjectOf(pid)
    if not subject then return nil, swhy or "subject_unavailable" end
    local pos = self.P.players.position(pid)
    if not pos or (M.planar(pos, route.destination.fence.position) or 99) > 4.0 then return nil, "too_far" end
    local snap, rwhy = self.L.read(crate.id)
    if type(snap) ~= "table" then return nil, rwhy == "unknown_account" and "crate_unavailable" or rwhy end
    if not M.tokenHere(snap, crate.iid) then return nil, "crate_unavailable" end
    local goods = M.goodsIn(snap, cfg.goodsItem)
    if goods < 1 then return nil, "crate_empty" end
    crate.goods = goods
    local quote = crate.meta.s
    local mine = quote and self.opIds[ctx.opId] == quote.op
    if quote and not mine then
        local outcome = self.L.settle(quote.op)
        if outcome == "committed" then
            self:afterDelivery(crate, quote, { replay = true }, pid, true)
            return { placement = { kind = "remove" }, sale = { opId = quote.op, total = quote.total, replay = true } }
        end
        if outcome == "pending" then return nil, "in_doubt" end
        quote = nil
    end
    if not quote then
        local run = self.runs[crate.run]
        local live = self:runLive(run) and run.route == route.id and self:isCrew(pid)
        local price = math.floor(route.price * goods / math.max(1, route.goodsPerCrate))
        local q, qwhy = M.fenceQuote(price, live, cfg.campCut, cfg.hotRatio)
        if not q then return nil, qwhy end
        local attempt = (crate.meta.s and crate.meta.s.a or 0) + 1
        quote = { op = ("nmd.sale:%s.a%d"):format(crate.key, attempt), a = attempt, total = q.total,
                  owner = q.owner, cut = q.cut, hot = q.hot, by = subject, to = q.hot and subject or run.owner,
                  goods = goods, buyer = "fence" }
        local previous = crate.meta.s
        crate.meta.s = quote
        local ok, mwhy = self:persistMeta(crate)
        if not ok then
            crate.meta.s, crate.dirty = previous, nil
            return nil, mwhy or "store_unavailable"
        end
        self.opIds[ctx.opId] = quote.op
    end
    local granted, gwhy = self.L.authorize(quote.op, "rp_economy", { crate.id }, 60000)
    if not granted then return nil, gwhy or "nomad_not_configured" end
    local receipt, why = self.P.economy.sale(self:saleSpec(crate, quote))
    if not receipt then return nil, why end
    local fence = route.destination.fence.name
    if quote.hot then
        self:tell(pid, ("%s takes the crate as hot goods: +%s."):format(fence, M.money(quote.total)), "success")
    else
        self:tell(pid, ("%s takes crate %d: %s, %s to the run's nomad, %s to the camp."):format(fence, crate.i,
            M.money(quote.total), M.money(quote.owner), M.money(quote.cut)), "success")
    end
    self:afterDelivery(crate, quote, receipt, pid, true)
    return { placement = { kind = "remove" }, sale = { opId = quote.op, total = quote.total, replay = receipt.replay == true } }
end

-- ---------------------------------------------------------------------------------------------
-- Return to the camp: goods back into the stash, token burned, crate closed. Crew only.
-- ---------------------------------------------------------------------------------------------
function S:returnToCamp(ctx, crate)
    local pid = ctx.playerId
    local cfg, M = self.cfg, self.M
    if not self:isCrew(pid) then return nil, "not_crew" end
    local pos = self.P.players.position(pid)
    if not pos or (M.planar(pos, cfg.camp.returnBay.position) or 99) > 4.0 then return nil, "too_far" end
    local snap, rwhy = self.L.read(crate.id)
    if type(snap) ~= "table" then return nil, rwhy == "unknown_account" and "crate_unavailable" or rwhy end
    if not M.tokenHere(snap, crate.iid) then return nil, "crate_unavailable" end
    local goods = M.goodsIn(snap, cfg.goodsItem)
    local opId = self.opIds[ctx.opId] or self.L.newOpId("return")
    self.opIds[ctx.opId] = opId
    local lines = {}
    if goods > 0 then
        lines[#lines + 1] = { item = cfg.goodsItem, count = goods, from = crate.id, to = cfg.accounts.stash }
    end
    lines[#lines + 1] = { instance = crate.iid, from = crate.id, to = cfg.accounts.tokens }
    local receipt, why = self.L.transfer({ opId = opId, kind = "nomad.return", reason = "crate back at the camp", lines = lines })
    if not receipt then
        if why == "busy" then why = "in_doubt" end
        return nil, why
    end
    self.stats.returns = self.stats.returns + 1
    crate.goods = 0
    local run = self.runs[crate.run]
    if goods > 0 then self:noteOutcome(run, crate, "returned") end
    self:tell(pid, goods > 0 and ("Crate back in the stash: %d %s returned. Nothing paid."):format(goods,
        cfg.items[cfg.goodsItem].label:lower()) or "Empty crate stacked away.", "info")
    self:log("crate %s returned to the stash by player %d: %d goods (op %s%s)", crate.id, pid, goods, opId,
        receipt.replay and ", replay" or "")
    local ok, cwhy = self.P.containers.close(crate.id, { reason = "returned" })
    if ok or cwhy == "unknown_container" or cwhy == "container_closed" then
        self.stats.retired = self.stats.retired + 1
        self:forget(crate)
    else
        crate.state, crate.retirePending = "empty", true
        if crate.itemId then self.byItem[crate.itemId] = nil end
        crate.itemId = nil
    end
    self:afterCrate(run)
    return { placement = { kind = "remove" }, returned = goods }
end

-- ---------------------------------------------------------------------------------------------
-- Confiscation: every goods of the given crates into the evidence stash, ONE operation.
-- ---------------------------------------------------------------------------------------------
function S:seizeLines(crates)
    local lines, used = {}, {}
    for _, crate in ipairs(crates) do
        local snap = self.L.read(crate.id)
        local goods = self.M.goodsIn(snap, self.cfg.goodsItem)
        if goods > 0 then
            lines[#lines + 1] = { item = self.cfg.goodsItem, count = goods, from = crate.id, to = self.cfg.accounts.evidence,
                reason = "NCPD seizure" }
            used[#used + 1] = crate
        end
    end
    return lines, used
end

-- After a committed confiscation: the crates are empty (they stay where they are: an emptied
-- crate in a bed is thrown away when unloaded, one on the ground is retired by the sweep).
function S:afterSeize(crates, info)
    local byRun = {}
    for _, crate in ipairs(crates) do
        crate.goods = 0
        if crate.state == "ground" then crate.retirePending = true end
        local run = self.runs[crate.run]
        if run then
            self:noteOutcome(run, crate, "seized")
            byRun[run.key] = byRun[run.key] or { run = run, n = 0 }
            byRun[run.key].n = byRun[run.key].n + 1
        end
    end
    self.stats.seized = self.stats.seized + #crates
    for _, entry in pairs(byRun) do
        local run = entry.run
        self:fixer("confiscated", self:playerOf(run.owner) or info.pid, info.opId, {
            run = run.key, route = run.route, crates = entry.n, by = info.by, checkpoint = info.checkpoint,
            officer = info.officer,
        })
        self:afterCrate(run)
    end
end

-- ---------------------------------------------------------------------------------------------
-- NCPD checkpoints (the tick)
-- ---------------------------------------------------------------------------------------------
function S:cratesInPlate(run, plate)
    local out = {}
    for _, id in pairs(run.crates) do
        local crate = self.crates[id]
        if crate and crate.state == "truck" and crate.plate == plate and (crate.goods or 0) > 0 then out[#out + 1] = crate end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

function S:persistPassed(run)
    local list = {}
    for id in pairs(run.passed) do list[#list + 1] = id end
    table.sort(list)
    for _, cid in pairs(run.crates) do
        local crate = self.crates[cid]
        if crate then
            crate.meta.p = list
            self:persistMeta(crate)
        end
    end
end

-- A run's truck entered a checkpoint: evaluated once, in its own task (the search yields).
function S:enterCheckpoint(run, ck, plate, vid, force)
    if run.passed[ck.id] or run.checking[ck.id] then return false end
    if self.seizeDoubts[("nmd.seize:%s:%s"):format(run.key, ck.id)] then return false end
    run.backoff = run.backoff or {}
    if not force and (run.backoff[ck.id] or 0) > self.P.now() then return false end
    run.checking[ck.id] = true
    self.P.spawn(function()
        local ok, err = pcall(self.checkpoint, self, run, ck, plate, vid, force)
        if not ok then
            run.checking[ck.id] = nil
            self:warn("checkpoint %s raised: %s", ck.id, tostring(err))
        end
    end)
    return true
end

-- One run's truck inside one checkpoint: pass (once) or search (one confiscation). The caller
-- (enterCheckpoint) holds run.checking[ck.id]; every way out releases it.
function S:checkpoint(run, ck, plate, vid, force)
    local key = run.key .. "|" .. ck.id
    local crates = self:cratesInPlate(run, plate)
    if #crates == 0 then
        run.checking[ck.id] = nil
        return
    end
    local searched, roll = self.M.searched(run.key, ck.id, ck.searchChance)
    local forced = force or self.forced[key]
    if forced == "search" then searched = true elseif forced == "pass" then searched = false end
    local driver = self.M.playerId(self.P.vehicles.driver(vid)) or self:playerOf(run.owner)
    local ownerPid = self:playerOf(run.owner)
    if not searched then
        run.passed[ck.id] = true
        run.checking[ck.id] = nil
        self.stats.passes = self.stats.passes + 1
        self:persistPassed(run)
        self:log("run %s passed %s (%s)", run.key, ck.id, forced == "pass" and ("forced by an operator, roll %d"):format(roll)
            or ("roll %d >= %d"):format(roll, ck.searchChance))
        local who = driver or ownerPid
        if who then self:tell(who, ("%s: the cops wave you through."):format(ck.label), "info") end
        self:fixer("checkpoint_passed", ownerPid or driver, "nmd.ck:" .. run.key .. ":" .. ck.id,
            { run = run.key, route = run.route, checkpoint = ck.id, label = ck.label })
        return
    end
    local opId = ("nmd.seize:%s:%s"):format(run.key, ck.id)
    local lines, used = self:seizeLines(crates)
    if #lines == 0 then
        run.checking[ck.id] = nil
        return
    end
    local spec = { opId = opId, kind = "nomad.seize", reason = "NCPD checkpoint " .. ck.id, lines = lines }
    local receipt, why = self.L.transfer(spec)
    if not receipt then
        run.checking[ck.id] = nil
        if DOUBT[why] or TRANSIENT_REFUSAL[why] then
            self.seizeDoubts[opId] = { spec = spec, crates = used, run = run.key, ck = ck.id, driver = driver, plate = plate }
            self:log("search %s at %s not settled (%s): the sweep retries the same operation", run.key, ck.id, tostring(why))
        else
            -- Goods held by another operation (a sale in flight), say: asked again in 10 s.
            run.backoff = run.backoff or {}
            run.backoff[ck.id] = self.P.now() + 10000
            self:warn("search %s at %s refused: %s (asked again in 10 s)", run.key, ck.id, tostring(why))
        end
        return
    end
    self:afterCheckpointSearch(run, ck, used, driver, plate, opId, receipt)
end

function S:afterCheckpointSearch(run, ck, crates, driver, plate, opId, receipt)
    run.checking[ck.id] = nil
    run.passed[ck.id] = true
    self:log("run %s searched at %s: %d crate(s) seized from %s (op %s%s)", run.key, ck.id, #crates, tostring(plate),
        opId, receipt and receipt.replay and ", replay" or "")
    self:afterSeize(crates, { by = "checkpoint", checkpoint = ck.id, opId = opId, pid = driver })
    self:penalize(driver, run, ck)
end

-- The driver: wanted level, the fine (cash then bank), a warrant and a record when it cannot be paid.
function S:penalize(driver, run, ck)
    local cfg = self.cfg.search
    if not driver then return end
    local heat, hwhy = self.P.players.setWanted(driver, cfg.wanted)
    if not heat then self:log("wanted level for player %d not set: %s", driver, tostring(hwhy)) end
    local paid, fwhy = nil, nil
    if (cfg.fine or 0) > 0 then
        paid, fwhy = self.P.economy.charge({ opId = ("nmd.fine:%s:%s"):format(run.key, ck.id), from = { player = driver },
            amount = cfg.fine, instrument = "cash_then_bank", to = { society = cfg.policeSociety },
            reason = "NCPD smuggling fine" })
    end
    local text = ("%s: NCPD search. They found the goods and seized them."):format(ck.label)
    if (cfg.fine or 0) > 0 then
        if paid then
            text = text .. (" Fine paid: %s."):format(self.M.money(cfg.fine))
        elseif fwhy == "in_doubt" then
            text = text .. (" Fine of %s: the payment is still settling."):format(self.M.money(cfg.fine))
        else
            text = text .. (" Fine of %s unpaid (%s): a warrant is out."):format(self.M.money(cfg.fine), tostring(fwhy))
            if (cfg.unpaidWarrant or 0) > 0 then
                self.P.ncpd.setWanted(driver, cfg.unpaidWarrant, "unpaid smuggling fine")
            end
        end
    end
    self.P.ncpd.addRecord(driver, "smuggling", ("Contraband seized at %s."):format(ck.label), nil)
    self:tell(driver, text .. " Lose the heat.", "error")
    if run.owner and self:playerOf(run.owner) ~= driver then
        self:tellSubject(run.owner, ("Your crates were seized at %s."):format(ck.label), "error")
    end
end

-- The 1 s tick: deadlines, trucks at checkpoints, wrecked trucks, arrival. Bounded by the runs
-- and their crates (no world scan).
function S:tick()
    if not self.ready then return end
    self:anchorBays()   -- every second: a truck that just parked gets its prompt at once
    local now = self.P.now()
    local plates = {}
    for _, run in pairs(self.runs) do
        if not run.ended then
            if not run.failed and now > run.deadline and self:goodsLeft(run) > 0 then
                self:spawnFail(run, "deadline")
            end
            for _, id in pairs(run.crates) do
                local crate = self.crates[id]
                if crate and crate.state == "truck" and crate.plate and (crate.goods or 0) > 0 then
                    plates[crate.plate] = plates[crate.plate] or {}
                    plates[crate.plate][run.key] = run
                end
            end
        end
    end
    for plate, runs in pairs(plates) do
        local vid = self:vehicleOfPlate(plate)
        local pos = vid and self.P.vehicles.position(vid)
        if pos then
            local health = self.P.vehicles.health(vid)
            if health ~= nil and health <= 0.001 then
                for _, run in pairs(runs) do self:spawnFail(run, "truck_destroyed") end
            else
                for _, ck in ipairs(self.cfg.checkpoints) do
                    if self.P.zones.contains(ck.zone, pos, self.M.inZone) then
                        for _, run in pairs(runs) do self:enterCheckpoint(run, ck, plate, vid) end
                    end
                end
                for _, run in pairs(runs) do
                    local route = self.routes[run.route]
                    if route and self:runLive(run) and not run.told.arrived and
                        (self.M.planar(pos, route.destination.unloadBay.position) or 1e9) <= route.destination.arrivalRadius then
                        run.told.arrived = true
                        self:tellSubject(run.owner, ("You made it to %s. Park at the bay, unload a crate (E), hand it to %s.")
                            :format(route.destination.label, route.destination.fence.name), "info")
                    end
                end
            end
        end
    end
end

-- The truck of a plate left the world for good (rp_garage:despawned).
function S:onDespawned(plate, reason)
    if reason == "stored" then return end
    for _, run in pairs(self.runs) do
        if not run.ended and #self:cratesInPlate(run, plate) > 0 then
            self:spawnFail(run, reason == "impounded" and "impounded" or "truck_lost")
        end
    end
end

-- ---------------------------------------------------------------------------------------------
-- The NCPD officer: /nomad search
-- ---------------------------------------------------------------------------------------------
-- What an officer standing at `pos` would search: the nearest truck carrying camp goods, else the
-- nearest camp crate with goods on the ground, else the nearest tracked vehicle (found clean).
function S:searchTarget(pid, pos)
    local cfg = self.cfg.officer
    local best, bestD
    local seen = {}
    for _, crate in pairs(self.crates) do
        if crate.state == "truck" and crate.plate and not seen[crate.plate] then
            seen[crate.plate] = true
            local vid = self:vehicleOfPlate(crate.plate)
            local at = vid and self.P.vehicles.position(vid)
            local d = at and self.M.distance(at, pos)
            if d and d <= cfg.reachM and (not bestD or d < bestD) then
                best, bestD = { kind = "truck", plate = crate.plate, vehicleId = vid }, d
            end
        end
    end
    if best then return best end
    for _, crate in pairs(self.crates) do
        if crate.state == "ground" and (crate.goods or 0) > 0 then
            local d = self.M.distance(crate.position, pos)
            if d and d <= cfg.crateReachM and (not bestD or d < bestD) then
                best, bestD = { kind = "crate", crate = crate.id }, d
            end
        end
    end
    if best then return best end
    for _, v in ipairs(self.P.vehicles.all()) do
        local at = type(v.position) == "table" and v.position or (v.x and { x = v.x, y = v.y, z = v.z }) or nil
        local d = at and self.M.distance(at, pos)
        if d and d <= cfg.reachM and (not bestD or d < bestD) then
            local plate = self.P.garage.plateOf(v.id)
            if type(plate) == "string" then best, bestD = { kind = "truck", plate = plate, vehicleId = v.id }, d end
        end
    end
    return best
end

-- Who may consent to a truck search: its driver, else a nomad whose run rides in it, on foot nearby.
function S:consenterOf(target, officerPos)
    local driver = self.M.playerId(self.P.vehicles.driver(target.vehicleId))
    if driver then return driver end
    local best, bestD
    for _, run in pairs(self.runs) do
        if not run.ended and #self:cratesInPlate(run, target.plate) > 0 then
            local pid = self:playerOf(run.owner)
            local d = pid and self.M.distance(self.P.players.position(pid), officerPos)
            if d and d <= self.cfg.officer.consentDistance and (not bestD or d < bestD) then best, bestD = pid, d end
        end
    end
    return best
end

function S:requestSearch(pid)
    if not self.ready then return nil, "nomad_unavailable" end
    if not self:isPolice(pid) then return nil, "not_police" end
    local pos = self.P.players.position(pid)
    if not pos then return nil, "position_unavailable" end
    local target = self:searchTarget(pid, pos)
    if not target then return nil, "nothing_to_search" end
    if target.kind == "crate" then return self:startSearch(pid, target) end
    local allowed = self.P.garage.canAccess(pid, target.plate, "cargo", "take")
    if allowed == true then
        target.authority = "warrant"
        return self:startSearch(pid, target)
    end
    local consenter = self:consenterOf(target, pos)
    if not consenter then return nil, "consent_needed" end
    local cfg = self.cfg.officer
    local officer = self.P.players.displayName(pid) or ("officer " .. pid)
    -- Live 2026-10-13: the card read "Someone makes you an offer." and the chat line told the driver
    -- to type /interaction accept; the card now says who asks what (Y / N answer it).
    local state, why = self.P.interactions.request(pid, consenter, "custom", {
        durationMs = 500, startDistance = cfg.consentDistance, breakDistance = cfg.consentDistance + 2.0,
        inviteTimeoutMs = cfg.inviteTimeoutMs, consent = true,
        label = ("NCPD %s: search your truck %s"):format(officer, target.plate):sub(1, 120),
    })
    if type(state) ~= "table" or not state.id then
        if why == "player_in_vehicle" then
            self:tell(pid, "Have the driver step out of the truck first.", "warning")
            return nil, "player_in_vehicle"
        end
        return nil, why or "interactions_unavailable"
    end
    target.authority = "consent"
    target.consenter = consenter
    self.searches[state.id] = { officer = pid, target = target }
    self:tell(consenter, ("NCPD: %s asks to search the truck %s. Y to let them search, N to refuse.")
        :format(officer, target.plate), "warning")
    self:tell(pid, "Waiting for the driver's consent.", "info")
    self:log("officer %d asks %d to search %s (interaction %s)", pid, consenter, target.plate, state.id)
    return { pending = state.id }
end

function S:startSearch(pid, target)
    local op, why = self.P.actions.request(pid, "ncpd_search", nil, { data = target })
    if not op then return nil, why end
    self:log("officer %d searches %s (%s, op %s)", pid, target.kind == "truck" and target.plate or target.crate,
        tostring(target.authority or "abandoned crate"), tostring(op.opId))
    return op
end

function S:searchCrates(target)
    local out = {}
    if target.kind == "crate" then
        local crate = self.crates[target.crate]
        if crate and crate.state == "ground" and (crate.goods or 0) > 0 then out[1] = crate end
        return out
    end
    for _, crate in pairs(self.crates) do
        if crate.state == "truck" and crate.plate == target.plate and (crate.goods or 0) > 0 then out[#out + 1] = crate end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

function S:searchReserve(ctx)
    if not fromActions() then return nil, "not_owner" end
    if not self.P.actions.verify(ctx.opId, "reserve") then return nil, "not_owner" end
    local target = ctx.data
    if type(target) ~= "table" then return nil, "nothing_to_search" end
    local crates = self:searchCrates(target)
    local lines, used = self:seizeLines(crates)
    if #lines == 0 then return { empty = true, target = target } end
    local txOpId = self.L.newOpId("search")
    local reserved, why = self.L.reserve({ opId = txOpId, kind = "nomad.seize", reason = "NCPD search",
        ttlMs = self.cfg.officer.durationMs + 30000, lines = lines })
    if not reserved then return nil, why end
    local ids = {}
    for _, crate in ipairs(used) do
        ids[#ids + 1] = crate.id
        crate.reservedBy = ctx.opId
    end
    local r = { txOpId = txOpId, crates = ids, target = target }
    self.searchOps[ctx.opId] = r
    return r
end

function S:releaseSearch(r, opId)
    for _, id in ipairs(r and r.crates or {}) do
        local crate = self.crates[id]
        if crate and crate.reservedBy == opId then crate.reservedBy = nil end
    end
    self.searchOps[opId] = nil
end

function S:afterOfficerSearch(r, opId, pid, receipt)
    local crates = {}
    for _, id in ipairs(r.crates) do
        local crate = self.crates[id]
        if crate then crates[#crates + 1] = crate end
    end
    self:releaseSearch(r, opId)
    self:afterSeize(crates, { by = "officer", officer = pid, opId = r.txOpId, pid = pid })
    local owners = {}
    for _, crate in ipairs(crates) do
        local run = self.runs[crate.run]
        if run and run.owner then owners[run.owner] = (owners[run.owner] or 0) + 1 end
    end
    for owner, n in pairs(owners) do
        local opid = self:playerOf(owner)
        if opid then
            self.P.ncpd.addRecord(opid, "smuggling", ("%d crate(s) of contraband seized by an officer."):format(n), pid)
            self:tell(opid, ("The NCPD seized %d of your crate(s)."):format(n), "error")
            local fine = self.cfg.officer.fine or 0
            if fine > 0 then
                self.P.economy.charge({ opId = ("nmd.ofine:%s"):format(r.txOpId), from = { player = opid }, amount = fine,
                    instrument = "cash_then_bank", to = { society = self.cfg.search.policeSociety }, reason = "NCPD smuggling fine" })
            end
        end
    end
    self:log("officer %d seized %d crate(s) (op %s%s)", pid, #crates, r.txOpId, receipt and receipt.replay and ", replay" or "")
    self:tell(pid, ("Contraband found: %d crate(s) seized into evidence."):format(#crates), "success")
end

function S:searchCommit(ctx)
    if not fromActions() then return nil, "not_owner" end
    if not self.P.actions.verify(ctx.opId, "commit") then return nil, "not_owner" end
    local r = ctx.reservation
    if type(r) ~= "table" then return nil, "no_reservation" end
    if r.empty then
        self:tell(ctx.playerId, "Clean: nothing of the camp's in there.", "info")
        return { found = 0 }
    end
    local receipt, why = self.L.commit(r.txOpId)
    if not receipt then return nil, why end
    local ok, err = pcall(self.afterOfficerSearch, self, r, ctx.opId, ctx.playerId, receipt)
    if not ok then self:warn("after search %s raised: %s", r.txOpId, tostring(err)) end
    return { found = #r.crates, tx = r.txOpId }
end

function S:searchCancel(ctx)
    if not fromActions() then return end
    local r = ctx.reservation
    if type(r) ~= "table" or not r.txOpId then return end
    if ctx.reason == "in_doubt" then
        local outcome = self.L.settle(r.txOpId)
        if outcome == "committed" then self:afterOfficerSearch(r, ctx.opId, ctx.playerId, nil) return end
        if outcome == "pending" then
            self.seizeDoubts[r.txOpId] = { officer = ctx.playerId, r = r, opId = ctx.opId }
            return
        end
    else
        self.L.cancel(r.txOpId, ctx.reason)
    end
    self:releaseSearch(r, ctx.opId)
end

function S:onSearchConsent(state, completed)
    local pending = self.searches[state.id]
    if not pending then return false end
    self.searches[state.id] = nil
    if not completed then
        local reason = tostring(state.reason or "cancelled")
        if reason:find("declin") or reason:find("reject") then reason = "declined" end
        self:tell(pending.officer, reason == "declined" and self.M.textFor("declined")
            or ("No consent (%s)."):format(reason), "warning")
        return true
    end
    local op, why = self:startSearch(pending.officer, pending.target)
    if not op then self:refuseTo(pending.officer, why) end
    return true
end

-- ---------------------------------------------------------------------------------------------
-- A crate handed to another player: consented, then ONE sale (goods to the buyer's pockets)
-- ---------------------------------------------------------------------------------------------
function S:offerCrate(seller, buyer, price)
    local cfg, M = self.cfg, self.M
    if not self.ready then return nil, "nomad_unavailable" end
    buyer = M.playerId(buyer)
    if not buyer or buyer == seller or not self.P.players.name(buyer) then return nil, "no_buyer" end
    price = M.integer(price)
    if not price or price < cfg.playerSale.minPrice or price > cfg.playerSale.maxPrice then return nil, "bad_price" end
    if self.P.actions.carrying(seller) then return nil, "no_crate_here" end
    local pos = self.P.players.position(seller)
    local best, bestD
    for _, crate in pairs(self.crates) do
        if crate.state == "ground" and (crate.goods or 0) > 0 and not crate.offer and not crate.reservedBy then
            local d = M.distance(crate.position, pos)
            if d and d <= cfg.playerSale.crateReachM and (not bestD or d < bestD) then best, bestD = crate, d end
        end
    end
    if not best then return nil, "no_crate_here" end
    local sellerSubject = self:subjectOf(seller)
    local buyerSubject = self:subjectOf(buyer)
    if not sellerSubject or not buyerSubject then return nil, "subject_unavailable" end
    local run = self.runs[best.run]
    local live = self:runLive(run) and self:isCrew(seller)
    local q = M.playerQuote(price, live, cfg.campCut)
    local sellerName = self.P.players.displayName(seller) or ("player " .. seller)
    local state, why = self.P.interactions.request(seller, buyer, "give", {
        durationMs = cfg.playerSale.durationMs, startDistance = cfg.playerSale.startDistance,
        breakDistance = cfg.playerSale.breakDistance, inviteTimeoutMs = cfg.playerSale.inviteTimeoutMs, consent = true,
        label = ("%s: a crate of %s for %s"):format(sellerName, cfg.items[cfg.goodsItem].label:lower(), M.money(price)):sub(1, 120),
    })
    if type(state) ~= "table" or not state.id then return nil, why or "interactions_unavailable" end
    local o = { id = state.id, seller = seller, buyer = buyer, crate = best.id, price = price, live = live,
                sellerSubject = sellerSubject, buyerSubject = buyerSubject, opId = self.L.newOpId("sell"), at = self.P.now(),
                quote = { op = nil, total = q.total, owner = q.owner, cut = q.cut, hot = q.hot, by = sellerSubject,
                          to = live and run.owner or sellerSubject, buyer = "player", buyerPid = buyer } }
    o.quote.op = o.opId
    self.offers[o.id] = o
    best.offer = o.id
    self:tell(buyer, ("%s offers you a crate of %s for %s. Y to take it and pay, N to decline.")
        :format(sellerName, cfg.items[cfg.goodsItem].label:lower(), M.money(price)), "info")
    self:tell(seller, ("Offer sent: the crate for %s."):format(M.money(price)), "info")
    self:log("offer %s: crate %s from %s to %s for %d (sale %s, live=%s)", o.id, best.id, sellerSubject, buyerSubject,
        price, o.opId, tostring(live))
    return o
end

function S:dropOffer(o, reason)
    local crate = self.crates[o.crate]
    if crate and crate.offer == o.id then crate.offer = nil end
    self.sales[o.opId] = nil
    self:log("offer %s dropped: %s (nothing was paid)", tostring(o.id), tostring(reason))
    if reason == "declined" then
        self:tell(o.seller, "The buyer declined.", "warning")
    else
        self:tell(o.seller, self.M.textFor(reason), "warning")
        self:tell(o.buyer, self.M.textFor(reason), "warning")
    end
end

function S:finishOffer(o, receipt)
    if self.done[o.opId] then return end
    self.done[o.opId] = self.P.now()
    self.sales[o.opId] = nil
    local crate = self.crates[o.crate]
    if not crate then return end
    crate.offer = nil
    if crate.itemId then self:unplaceItem(crate) end
    self:tell(o.buyer, ("Paid %s: the goods are in your pockets."):format(self.M.money(o.price)), "success")
    self:tell(o.seller, ("Sold: %s, %s to the run's nomad%s."):format(self.M.money(o.price), self.M.money(o.quote.owner),
        o.quote.cut > 0 and (", " .. self.M.money(o.quote.cut) .. " to the camp") or ""), "success")
    self:afterDelivery(crate, o.quote, receipt, o.seller)
end

function S:completeOffer(o)
    local cfg, M = self.cfg, self.M
    local crate = self.crates[o.crate]
    if not crate or crate.state ~= "ground" or crate.offer ~= o.id then return self:dropOffer(o, "crate_unavailable") end
    local snap = self.L.read(crate.id)
    local goods = M.goodsIn(snap, cfg.goodsItem)
    if goods < 1 or not M.tokenHere(snap, crate.iid) then return self:dropOffer(o, "crate_unavailable") end
    o.quote.goods = goods
    crate.meta.s = M.copy(o.quote)
    crate.meta.s.buyerPid = nil
    local ok, mwhy = self:persistMeta(crate)
    if not ok then return self:dropOffer(o, mwhy or "store_unavailable") end
    local granted, gwhy = self.L.authorize(o.opId, "rp_economy", { crate.id, "char:" .. o.buyerSubject }, 60000)
    if not granted then self:warn("grant for sale %s refused: %s (writers for rp_nomade: char)", o.opId, tostring(gwhy)) end
    local receipt, why = self.P.economy.sale(self:saleSpec(crate, o.quote))
    if type(receipt) == "table" then return self:finishOffer(o, receipt) end
    if why == "in_doubt" then
        self.sales[o.opId] = o
        self:tell(o.buyer, "The payment is still settling: one moment.", "info")
        return
    end
    crate.meta.s = nil
    self:persistMeta(crate)
    return self:dropOffer(o, why)
end

function S:onOfferEnded(state, completed)
    local o = self.offers[state.id]
    if not o then return false end
    self.offers[state.id] = nil
    if completed then
        self:completeOffer(o)
    else
        local reason = tostring(state.reason or "cancelled")
        if reason:find("declin") or reason:find("reject") then reason = "declined" end
        self:dropOffer(o, reason)
    end
    return true
end

-- ---------------------------------------------------------------------------------------------
-- The camp's supplier, the operator's stock, reclaiming abandoned crates
-- ---------------------------------------------------------------------------------------------
function S:stockOf()
    local snap = self.L.read(self.cfg.accounts.stash)
    return self.M.goodsIn(snap, self.cfg.goodsItem), snap
end

function S:stock(count, opId)
    count = self.M.integer(count)
    if not count or count < 1 then return nil, "invalid_count" end
    local receipt, why = self.L.transfer({ opId = opId or self.L.newOpId("stock"), kind = "nomad.restock",
        reason = "camp supply", lines = { { item = self.cfg.goodsItem, count = count, from = self.cfg.accounts.supplier,
        to = self.cfg.accounts.stash } } })
    if receipt then self.stats.restocks = self.stats.restocks + 1 end
    return receipt, why
end

function S:restockTick()
    local cfg = self.cfg.restock
    if not cfg or (cfg.amount or 0) < 1 then return end
    local window = math.floor(self.P.now() / cfg.everyMs)
    if self.lastRestockWindow == window then return end
    local have = self:stockOf()
    if have >= cfg.below then
        self.lastRestockWindow = window
        return
    end
    local receipt, why = self:stock(cfg.amount, ("nmd.restock:%d"):format(window))
    if receipt then
        self.lastRestockWindow = window
        if not receipt.replay then self:log("camp supply: +%d goods (stash had %d)", cfg.amount, have) end
    elseif why ~= "store_unavailable" and why ~= "coordinator_unavailable" then
        self.lastRestockWindow = window
        self:warn("camp supply refused: %s", tostring(why))
    end
end

-- A crate on the ground long after its run ended (or with no run): its goods go back to the stash.
function S:reclaim(crate)
    local snap = self.L.read(crate.id)
    if type(snap) ~= "table" or not self.M.tokenHere(snap, crate.iid) then return false end
    local goods = self.M.goodsIn(snap, self.cfg.goodsItem)
    local lines = {}
    if goods > 0 then lines[1] = { item = self.cfg.goodsItem, count = goods, from = crate.id, to = self.cfg.accounts.stash } end
    lines[#lines + 1] = { instance = crate.iid, from = crate.id, to = self.cfg.accounts.tokens }
    local receipt = self.L.transfer({ opId = ("nmd.reclaim:%s"):format(crate.key), kind = "nomad.reclaim",
        reason = "abandoned crate", lines = lines })
    if not receipt then return false end
    self.stats.reclaimed = self.stats.reclaimed + 1
    crate.goods = 0
    self:log("crate %s abandoned on the ground: %d goods back in the stash", crate.id, goods)
    self:retire(crate)
    return true
end

-- ---------------------------------------------------------------------------------------------
-- Boot: rebuild every crate and run from open77_containers and the coordinator
-- ---------------------------------------------------------------------------------------------
function S:loadCrates()
    local list, why = self.P.containers.list({ owner = self.resource })
    if type(list) ~= "table" then
        self:warn("crate listing failed: %s", tostring(why))
        return nil, why
    end
    local counts = { ground = 0, truck = 0, empty = 0, sold = 0, orphan = 0 }
    local seen = 0
    for index, summary in ipairs(list) do
        if self.M.isOurs(summary.public) then
            seen = seen + 1
            local crate = self:adopt(summary.id, summary.public, summary)
            self:classify(crate, counts)
            if index % 8 == 0 then self.P.wait(0) end
        end
    end
    for _, run in pairs(self.runs) do
        if self:goodsLeft(run) == 0 and not run.ended then run.ended = run.failed or "ended" end
    end
    self:purgeTallies()
    local live = 0
    for _, run in pairs(self.runs) do if not run.ended then live = live + 1 end end
    self:log("crates rebuilt: %d (ground %d, in a bed %d, empty %d, sold %d, orphans closed %d); %d run(s) going",
        seen, counts.ground, counts.truck, counts.empty, counts.sold, counts.orphan, live)
    return seen
end

function S:classify(crate, counts)
    -- A crate in somebody's hands right now (open77_containers restarted under a carry): its
    -- carry session is the truth until the put-down.
    if crate.state == "carried" or crate.retiring then return end
    local snap = self.L.read(crate.id)
    if type(snap) ~= "table" then
        crate.needsReconcile = true
        return
    end
    crate.goods = self.M.goodsIn(snap, self.cfg.goodsItem)
    if crate.meta.s then
        local outcome = self:settleSale(crate)
        if outcome == "committed" then counts.sold = counts.sold + 1 return end
    end
    if self.M.tokenHere(snap, crate.iid) then
        if crate.goods > 0 then
            crate.state = "ground"
            self:placeItem(crate)
            counts.ground = counts.ground + 1
        else
            crate.state = "empty"
            crate.retirePending = true
            counts.empty = counts.empty + 1
        end
    elseif crate.meta.w then
        crate.state, crate.plate = "truck", crate.meta.w
        counts.truck = counts.truck + 1
    elseif crate.goods == 0 then
        -- Never filled (a run whose reservation never committed): close it.
        local ok, why = self.P.containers.close(crate.id, { reason = "orphan" })
        if ok or why == "unknown_container" or why == "container_closed" then
            self:forget(crate)
            counts.orphan = counts.orphan + 1
        end
    else
        crate.state = "truck"
        counts.truck = counts.truck + 1
    end
end

-- Re-derives a crate's state from the coordinator (a lost read at boot).
function S:reconcile(crate)
    crate.needsReconcile = nil
    self:classify(crate, { ground = 0, truck = 0, empty = 0, sold = 0, orphan = 0 })
end

-- After open77_actions restarted: it forgot every item and every carry; re-place the ground
-- crates at their durable placement (a carried crate returns to where it was last put down).
function S:reproject()
    for _, crate in pairs(self.crates) do
        if crate.state == "carried" then crate.state, crate.carrier = "ground", nil end
        crate.itemId = nil
        if crate.state == "ground" then self:placeItem(crate) end
    end
    self.byItem = {}
    for _, crate in pairs(self.crates) do if crate.itemId then self.byItem[crate.itemId] = crate.id end end
end

-- ---------------------------------------------------------------------------------------------
-- Sweep: settle what is in doubt, retry what the store refused
-- ---------------------------------------------------------------------------------------------
function S:sweep()
    if not self.ready then return end
    local now = self.P.now()
    for _, r in pairs(self.doubts) do
        if not self.done[r.txOpId] then self:settleTake(r) end
    end
    for opId, d in pairs(self.seizeDoubts) do
        if d.spec then
            local receipt = self.L.transfer(d.spec)
            if receipt then
                self.seizeDoubts[opId] = nil
                local run, ck = self.runs[d.run], self.checkpoints[d.ck]
                if run and ck then self:afterCheckpointSearch(run, ck, d.crates, d.driver, d.plate, opId, receipt) end
            end
        elseif d.r then
            local outcome = self.L.settle(opId)
            if outcome == "committed" then
                self.seizeDoubts[opId] = nil
                self:afterOfficerSearch(d.r, d.opId, d.officer, nil)
            elseif outcome == "failed" or outcome == "aborted" then
                self.seizeDoubts[opId] = nil
                self:releaseSearch(d.r, d.opId)
            end
        end
    end
    for opId, o in pairs(self.sales) do
        local st = self.P.economy.status(opId)
        if type(st) == "table" then
            if st.state == "committed" then
                self:finishOffer(o, type(st.receipt) == "table" and st.receipt or { opId = opId })
            elseif st.state == "failed" or st.state == "aborted" then
                self:dropOffer(o, "store_unavailable")
            end
        end
    end
    for id in pairs(self.closeLater or {}) do
        local ok, why = self.P.containers.close(id, { reason = "cancelled" })
        if ok or why == "unknown_container" or why == "container_closed" then self.closeLater[id] = nil end
    end
    local list = {}
    for _, crate in pairs(self.crates) do list[#list + 1] = crate end
    table.sort(list, function(a, b) return a.id < b.id end)
    for index, crate in ipairs(list) do
        if index % 16 == 0 then self.P.wait(0) end
        if self.crates[crate.id] and not crate.retiring then
            local run = self.runs[crate.run]
            if crate.needsReconcile then
                self:reconcile(crate)
            elseif crate.meta.s and crate.state ~= "carried" and crate.saleChecked ~= crate.meta.s.op
                and not crate.offer and not self.sales[crate.meta.s.op] then
                self:settleSale(crate)
            elseif crate.retirePending then
                self:retire(crate)
            elseif crate.dirty then
                self:persistMeta(crate)
            elseif crate.placeDirty and crate.position then
                self:setPlacement(crate, crate.position, crate.yaw, crate.bucket)
            elseif crate.state == "ground" and crate.unplaced then
                self:placeItem(crate)
            elseif crate.state == "ground" and (crate.goods or 0) > 0 and not crate.offer and not crate.reservedBy
                and (not run or run.ended or run.failed or now > run.deadline)
                and now > (run and run.deadline or 0) + self.cfg.abandonMs then
                self:reclaim(crate)
            end
        end
    end
    self:restockTick()
    for id, o in pairs(self.offers) do
        if not self.P.interactions.get(id) and now - (o.at or now) > 60000 then
            self.offers[id] = nil
            self:dropOffer(o, "lost")
        end
    end
    local cutoff = now - 10 * 60 * 1000
    for id, at in pairs(self.done) do if at < cutoff then self.done[id] = nil end end
    -- A run that ended and has no crate left is forgotten (its record died with its crates).
    for key, run in pairs(self.runs) do
        if run.ended then
            local any = false
            for _, id in pairs(run.crates) do if self.crates[id] then any = true break end end
            if not any then self.runs[key] = nil end
        end
    end
end

-- ---------------------------------------------------------------------------------------------
-- Presentation around the lifecycle (transition events of open77_actions)
-- ---------------------------------------------------------------------------------------------
local TERMINAL = { committed = true, cancelled = true, failed = true, in_doubt = true, refused = true }

function S:onTransition(op)
    if type(op) ~= "table" or op.owner ~= self.resource then return end
    local pid = op.playerId
    if not TERMINAL[op.state] then return end
    if op.state == "committed" then
        if op.actionId == "unload" and type(op.receipt) == "table" and op.receipt.item then
            local ok, why = self.P.actions.carryPickup(pid, op.receipt.item)
            if not ok then self:refuseTo(pid, why) end
        end
        self.opIds[op.opId] = nil
        return
    end
    self.opIds[op.opId] = nil
    if op.reason == "superseded" then return end
    if op.state == "in_doubt" then
        self:tell(pid, self.M.textFor("in_doubt"), "warning")
    else
        self:refuseTo(pid, op.reason)
    end
end

function S:onPlayerReady(pid)
    local subject = self:trackPlayer(pid)
    if subject then self:pushNav(subject, true) end
end

function S:onPlayerGone(pid)
    if not pid then return end
    for id, o in pairs(self.offers) do
        if o.seller == pid or o.buyer == pid then
            self.offers[id] = nil
            self:dropOffer(o, "disconnected")
        end
    end
    for id, s in pairs(self.searches) do
        if s.officer == pid or s.target.consenter == pid then self.searches[id] = nil end
    end
    self:untrackPlayer(pid)
end

function S:shutdown()
    for key, id in pairs(self.npcs) do
        pcall(self.P.npcs.remove, id)
        self.npcs[key] = nil
    end
    for i, id in pairs(self.decor or {}) do
        pcall(self.P.props.remove, id)
        self.decor[i] = nil
    end
end

-- The camp's set dressing (cfg.camp.decor): the vanilla Aldecaldos camp is quest content the
-- multiplayer world never streams, so the board, the loading points and the bay stand on bare
-- desert without it. Presentation only: a refused prop is logged and the camp works without it.
function S:dressCamp()
    self.decor = self.decor or {}
    for i, d in ipairs(self.cfg.camp.decor or {}) do
        if not self.decor[i] then
            local ok, id, why = pcall(self.P.props.create, { model = d.model, position = d.position, yaw = d.yaw or 0.0,
                bucket = self.cfg.bucket })
            if ok and id then
                self.decor[i] = id
            else
                self:log("camp prop %s not placed (%s): the camp works without it", tostring(d.model),
                    tostring(ok and why or id))
            end
        end
    end
end

-- A read-only summary of a player's run (export, /nomad status).
function S:runSummary(subject)
    local run = subject and self:activeRunOf(subject)
    if not run then return nil end
    local out = { run = run.key, route = run.route, crates = run.n, deadline = run.deadline,
                  failed = run.failed, delivered = run.delivered, sold = run.sold, seized = run.seized,
                  returned = run.returned, hot = run.hot, left = self:goodsLeft(run), where = {} }
    for i = 1, run.n do
        local crate = self.crates[run.crates[i] or ""]
        out.where[i] = crate and (crate.state .. (crate.plate and (" " .. crate.plate) or "")) or run.outcomes[i] or "gone"
    end
    return out
end

return NomadService
