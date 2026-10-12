-- rp_chooh2 / server/service.lua: the CHOOH2 chain, as hooks of the job libraries.
--
--   clock in        office target -> action `clock_in` -> rp_jobs:setDuty for the player's own job
--   harvest         row target -> action `harvest`; reserve = ONE coordinator reservation (room in
--                   the crate next to the row); commit = the rolled corn (+ the crate token when the
--                   crate is new); then the row's charge (open77_containers consume, idempotent)
--   carry           open77_actions carry kind `crate`; custody stays in the hold: a pickup moves
--                   nothing, a put-down on the ground persists the placement
--   load            put-down at the farm bay / onto a truck -> rp_cargo:load moves the crate token
--                   hold -> veh:<plate>:cargo (rp_garage decides who may)
--   unload          refinery bay action -> rp_cargo:unload moves the token back, the player lifts it
--   deliver         put-down at the intake hopper -> ONE transfer: every corn of the crate into the
--                   intake stash and the token back to its source; then the empty hold is closed
--   refine          control station action `refine`; reserve = ONE reservation (corn out of the
--                   intake, canisters minted into the output stash); commit = the same lines
--   collect         output rack action -> canisters from the output stash into the pockets
--   sell            depot counter action -> ONE rp_economy:sale (canisters out of the pockets, cash
--                   to the seller, share to the society)
--   refuel          pump target or `/chooh2 refuel` -> ONE reservation (a canister out of the
--                   pockets, burned); commit; then open77_fuel:refuel on that car
--
-- Every committed step that a contract could ask for fires `rp:job:completed`.
-- Durable state lives in the coordinator (holds, tokens, corn, stashes, canisters, money) and in
-- open77_containers (row charges). This file keeps caches it can rebuild at boot.
--
-- Global: Chooh2Service.

Chooh2Service = {}
local S = {}
S.__index = S

local ACTIONS = "open77_actions"
local OWN = "rp_chooh2"
local KIND_CRATE = "crate"
-- The coordinator's refusals that mean "nothing was applied, try again".
local TRANSIENT_REFUSAL = { coordinator_unavailable = true, store_unavailable = true, conflict = true }
-- Actions whose value moves through a reservation of this resource.
local RESERVED = { harvest = true, refine = true, collect = true, refuel = true }

function Chooh2Service.new(deps)
    local self = setmetatable({
        cfg = deps.config, M = deps.model, L = deps.ledger, P = deps.ports,
        resource = deps.resource or OWN,
        nodes = {}, nodeById = {},
        crates = {}, byItem = {},
        work = {},           -- [actions opId] = reservation (a live harvest)
        doubts = {},         -- [tx opId] = reservation (a commit in doubt, settled by the sweep)
        done = {},           -- [tx opId] = ms (afterCommit ran)
        pendingConsume = {}, -- [tx opId] = node container id (charge not spent yet)
        pendingFills = {},   -- [tx opId] = { vehicleId, litres, pid, subject, tries } (canister burned, tank not filled yet)
        opIds = {},          -- [actions opId] = coordinator / cargo op id (retries reuse it)
        sales = {},          -- [actions opId] = the sale spec (a retried commit sends the same one)
        receipts = {},       -- [subject] = ring of { kind, opId, text, at }
        notified = {},       -- [playerId] = ms of the last refusal toast
        ready = false, declared = false, npcId = nil, stashesOpen = false,
        containersUp = false, loadingNodes = false, nodesRetryAt = 0,
        stats = { harvests = 0, loads = 0, unloads = 0, deliveries = 0, runs = 0, collected = 0, sales = 0,
                  refuels = 0, refusals = 0, doubts = 0 },
    }, S)
    return self
end

function S:log(fmt, ...) self.P.log(fmt:format(...)) end
function S:warn(fmt, ...) self.P.warn(fmt:format(...)) end

local function fromActions() return GetInvokingResource() == ACTIONS end
S.fromActions = fromActions

-- ---------------------------------------------------------------------------------------------
-- Telling players, receipts, the fixer event
-- ---------------------------------------------------------------------------------------------
function S:tell(pid, text, kind)
    pid = self.M.playerId(pid)
    if pid then self.P.tell(pid, text, kind) end
end

function S:refuseTo(pid, reason)
    self.stats.refusals = self.stats.refusals + 1
    pid = self.M.playerId(pid)
    if not pid then return end
    local now = self.P.now()
    if (self.notified[pid] or 0) + self.cfg.notifyCooldownMs > now then return end
    self.notified[pid] = now
    self.P.tell(pid, self.M.textFor(reason), "warning")
end

-- The player still is the subject a deferred message is about (seats are reused).
function S:tellSubject(subject, pid, text, kind)
    if pid and self.L.subjectOf(pid) == subject then self:tell(pid, text, kind) end
end

function S:record(subject, entry)
    if not subject then return end
    local ring = self.receipts[subject] or {}
    entry.at = self.P.now()
    ring[#ring + 1] = entry
    while #ring > self.cfg.receiptsKept do table.remove(ring, 1) end
    self.receipts[subject] = ring
end

-- `rp:job:completed` for the fixer board: once per committed step in this process; `ref` is the
-- coordinator operation id (a consumer dedupes on it).
function S:completed(kind, pid, ref, data)
    self.P.emit("rp:job:completed", { job = self.cfg.fixerJob, kind = kind, playerId = pid, ref = ref, data = data or {} })
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
        self:warn("items: %s registered, %s refused %s (another definer owns them?)", tostring(registered),
            tostring(rejected), table.concat(names, ","))
    else
        self:log("items defined through rp_inventory: %s", tostring(registered))
    end
    return true
end

-- The refinery's two stashes: fixed names, so a restart finds the same corn and canisters.
function S:openStashes()
    if self.stashesOpen then return true end
    local A = self.cfg.accounts
    local a, awhy = self.L.open(A.intake, { capacityG = self.cfg.stashes.intake.capacityG,
        meta = { app = self.M.APP, role = "intake" } })
    local b, bwhy = self.L.open(A.output, { capacityG = self.cfg.stashes.output.capacityG,
        meta = { app = self.M.APP, role = "output" } })
    if type(a) == "table" and type(b) == "table" then
        self.stashesOpen = true
        return true
    end
    self:warn("refinery stashes not open (%s / %s): asked for again by the sweep", tostring(awhy), tostring(bwhy))
    return false
end

local HOOKS = { validate = "ch2Validate", reserve = "ch2Reserve", commit = "ch2Commit", cancel = "ch2Cancel" }

local function timed(cfg, id, spec, extra)
    local def = {
        id = id, label = spec.label, durationMs = spec.durationMs, maxDistance = cfg.maxDistance,
        animation = spec.animation, progress = { label = spec.progress }, epochs = cfg.epochs,
        reserveTimeoutMs = 20000,
    }
    for k, v in pairs(extra or {}) do def[k] = v end
    return def
end

-- A row's prompt: harvest and check; once picked clean, only "Check the row" (it regrows).
function S:nodeTarget(node, depleted)
    local actions = {
        { action = "harvest", label = "Harvest corn" },
        { action = "inspect", label = "Check the row" },
    }
    if depleted then actions = { { action = "inspect", label = "Check the row" } } end
    return {
        id = "node_" .. node.key, position = node.cfg.position, yaw = node.cfg.yaw, bucket = self.cfg.bucket,
        label = depleted and (node.cfg.label .. " (picked clean)") or node.cfg.label, distance = self.cfg.maxDistance,
        markerDistance = 12.0, requires = "empty", actions = actions, data = { node = node.key },
    }
end

function S:declare()
    local cfg, A = self.cfg, self.P.actions
    local act = cfg.actions
    local defs = {
        timed(cfg, "harvest", act.harvest, { hooks = HOOKS, eligibility = cfg.eligibility.harvest }),
        timed(cfg, "inspect", act.inspect, { hooks = { validate = "ch2Validate", commit = "ch2Inspect" },
            eligibility = cfg.eligibility.harvest }),
        timed(cfg, "unload", act.unload, { hooks = { validate = "ch2Validate", commit = "ch2Unload" },
            eligibility = cfg.eligibility.haul, maxDistance = 3.0 }),
        timed(cfg, "refine", act.refine, { hooks = HOOKS, eligibility = cfg.eligibility.refine }),
        timed(cfg, "gauges", act.gauges, { hooks = { validate = "ch2Validate", commit = "ch2Gauges" },
            eligibility = cfg.eligibility.refine }),
        timed(cfg, "collect", act.collect, { hooks = HOOKS, eligibility = cfg.eligibility.refine }),
        timed(cfg, "sell", act.sell, { hooks = { validate = "ch2Validate", commit = "ch2Sell" },
            eligibility = cfg.eligibility.refine, maxDistance = 3.0 }),
        -- Anyone with a canister may refuel a car: from the pump's prompt, or by command next to a car
        -- (no target: the server finds the car and re-checks it before pouring).
        timed(cfg, "refuel", act.refuel, { hooks = HOOKS, requiresTarget = false, epochs = false, maxDistance = 3.0 }),
        { id = "clock_in", label = "Clock in", durationMs = act.clock.durationMs, maxDistance = 3.0,
          claim = false, progress = false, claims = false, hooks = { commit = "ch2Duty" } },
        { id = "clock_out", label = "Clock out", durationMs = act.clock.durationMs, maxDistance = 3.0,
          claim = false, progress = false, claims = false, hooks = { commit = "ch2Duty" } },
    }
    for _, def in ipairs(defs) do
        if def.epochs == false then def.epochs = nil end
        local key, why = A.define(def)
        if not key then
            self:warn("action %s refused by open77_actions: %s", def.id, tostring(why))
            return false
        end
    end
    local kind, why = A.carryDefine({
        id = KIND_CRATE, model = cfg.crate.model, label = cfg.crate.label, reach = cfg.crate.reach,
        vehicleReach = cfg.crate.vehicleReach, binding = cfg.crate.binding,
        gripMs = cfg.crate.gripMs, releaseMs = cfg.crate.releaseMs,
        hooks = { validate = "ch2CrateValidate", pickup = "ch2CratePickup", putdown = "ch2CratePutdown",
                  dropped = "ch2CrateDropped" },
        eligibility = cfg.eligibility.haul, epochs = cfg.epochs,
    })
    if not kind then
        self:warn("carry kind refused by open77_actions: %s", tostring(why))
        return false
    end
    local function office(id, spec, which)
        return { id = id, position = spec.position, yaw = spec.yaw, bucket = cfg.bucket, label = spec.label,
            distance = spec.distance, markerDistance = 15.0, requires = "empty", data = { office = which },
            actions = { { action = "clock_in", label = "Clock in" }, { action = "clock_out", label = "Clock out" } } }
    end
    local targets = {
        office("farm_office", cfg.farmOffice, "farm"),
        office("refinery_office", cfg.refineryOffice, "refinery"),
        { id = "farm_bay", position = cfg.farmBay.position, bucket = cfg.bucket, label = cfg.farmBay.label,
          distance = 2.5, markerDistance = 15.0, requires = "carrying", data = { bay = "load" },
          actions = { { action = "open77_actions:carry_putdown", label = "Load into the truck" } } },
        { id = "unload_bay", position = cfg.unloadBay.position, bucket = cfg.bucket, label = cfg.unloadBay.label,
          distance = 2.5, markerDistance = 15.0, requires = "empty", data = { bay = "unload" },
          actions = { { action = "unload", label = "Unload a crate" } } },
        { id = "intake", position = cfg.intake.position, yaw = cfg.intake.yaw, bucket = cfg.bucket,
          label = cfg.intake.label, distance = 2.5, markerDistance = 15.0, requires = "carrying", data = { bay = "intake" },
          actions = { { action = "open77_actions:carry_putdown", label = "Empty into the intake" } } },
        { id = "control", position = cfg.control.position, yaw = cfg.control.yaw, bucket = cfg.bucket,
          promptAt = cfg.control.promptAt,
          label = cfg.control.label, distance = 2.5, markerDistance = 15.0, requires = "empty", data = { station = "control" },
          actions = { { action = "refine", label = "Run a batch" }, { action = "gauges", label = "Read the gauges" } } },
        { id = "output_rack", position = cfg.outputRack.position, yaw = cfg.outputRack.yaw, bucket = cfg.bucket,
          label = cfg.outputRack.label, distance = 2.5, markerDistance = 15.0, requires = "empty", data = { station = "output" },
          actions = { { action = "collect", label = "Take canisters" } } },
        { id = "depot_counter", position = cfg.depot.counter, yaw = cfg.depot.yaw, bucket = cfg.bucket,
          label = cfg.depot.label, distance = 2.5, markerDistance = 15.0, requires = "empty", data = { station = "depot" },
          actions = { { action = "sell", label = "Sell canisters" } } },
        { id = "pump", position = cfg.pump.position, bucket = cfg.bucket, label = cfg.pump.label,
          distance = 2.5, markerDistance = 15.0, requires = "empty", data = { pump = true },
          actions = { { action = "refuel", label = "Refuel the nearest car" } } },
    }
    for _, def in ipairs(targets) do
        local key, twhy = A.target(def)
        if not key then self:warn("target %s refused: %s", def.id, tostring(twhy)) end
    end
    for _, node in pairs(self.nodes) do self:refreshNodeTarget(node, true) end
    self.declared = true
    return true
end

-- Re-declares a row's prompt when its depletion changes (same target id: the library replaces it).
function S:refreshNodeTarget(node, force)
    if not node.id then return end
    local summary = self.P.containers.summary(node.id)
    local depleted = type(summary) == "table" and summary.depleted == true
    if not force and depleted == node.depleted then return end
    node.depleted = depleted
    local key, why = self.P.actions.target(self:nodeTarget(node, depleted))
    if not key then self:warn("row target %s refused: %s", node.key, tostring(why)) end
end

-- ---------------------------------------------------------------------------------------------
-- Rows: open77_containers containers of kind "node", named by the key `node.<key>` (a
-- zero-capacity world row open77_containers mints, plus durable charges, consume refs and lazy
-- regrowth). The prompt is this resource's own target at the configured position.
-- ---------------------------------------------------------------------------------------------
local CONTAINERS_TRANSIENT = { not_ready = true, busy = true, open77_containers_unavailable = true }

function S:nodesTransient(why, info)
    if CONTAINERS_TRANSIENT[why] or (type(info) == "table" and info.retryable == true) then return true end
    return type(why) == "string" and why:sub(1, 7) == "export_"
end

function S:nodeKey(nodeCfg) return nodeCfg.containerKey or ("node." .. nodeCfg.key) end

function S:nodeSpec(nodeCfg)
    local d = self.cfg.nodeDefaults
    return {
        key = self:nodeKey(nodeCfg), kind = "node", model = false, position = nodeCfg.position,
        yaw = nodeCfg.yaw or 0.0, bucket = self.cfg.bucket, label = nodeCfg.label,
        public = { node = nodeCfg.key, job = self.cfg.fixerJob },
        node = { charges = nodeCfg.charges or d.charges, regrowMs = nodeCfg.regrowMs or d.regrowMs },
        reachM = 0,
    }
end

-- Finds every row by its key, creating the missing ones (a keyed create is idempotent).
-- open77_containers answers `not_ready` until its boot join, so the create itself is the probe.
function S:loadNodes()
    if self.loadingNodes then return false, "busy" end
    self.loadingNodes = true
    local ok, done, why, created = pcall(self._loadNodes, self)
    self.loadingNodes = false
    if not ok then
        self:warn("row load raised: %s", tostring(done))
        return false, "raised"
    end
    if done or not self:nodesTransient(why) then self.containersUp = true end
    self.nodesCreated = (self.nodesCreated or 0) + (created or 0)
    if done then
        self:log("%d corn row(s) ready (%d created)", #self.cfg.nodes, self.nodesCreated)
        self.nodesCreated = 0
    end
    return done, why
end

function S:_loadNodes()
    local created, waiting, failed = 0, nil, nil
    for _, nodeCfg in ipairs(self.cfg.nodes) do
        if waiting then break end
        local node = self.nodes[nodeCfg.key] or { key = nodeCfg.key }
        node.cfg = nodeCfg
        self.nodes[nodeCfg.key] = node
        local found = self.P.containers.find(self:nodeKey(nodeCfg))
        local id = type(found) == "table" and found.id or nil
        if not id then
            local summary, why, info = self.P.containers.create(self:nodeSpec(nodeCfg))
            if type(summary) == "table" and summary.id then
                id = summary.id
                if not (type(info) == "table" and info.existing) then created = created + 1 end
            elseif self:nodesTransient(why, info) then
                waiting = waiting or why
                id = node.id
            else
                failed = failed or why
                if node.warned ~= why then
                    node.warned = why
                    self:warn("row %s (%s) unavailable: %s", nodeCfg.key, self:nodeKey(nodeCfg), tostring(why))
                end
            end
        end
        if node.id and node.id ~= id then self.nodeById[node.id] = nil end
        node.id = id
        if id then
            node.warned = nil
            self.nodeById[id] = nodeCfg.key
        end
    end
    if waiting or failed then return false, waiting or failed, created end
    return true, nil, created
end

-- Back to full charges, in place (open77_containers `refill`): same id, consume refs kept.
function S:resetNode(key)
    local node = self.nodes[key]
    if not node or not node.id then return nil, "unknown_node" end
    local state, why = self.P.containers.refill(node.id)
    if type(state) ~= "table" then return nil, why end
    self:refreshNodeTarget(node, true)
    return state
end

function S:consumeNode(nodeId, ref)
    if not nodeId then return end
    local state, why = self.P.containers.consume(nodeId, { count = 1, ref = ref })
    if state then
        self.pendingConsume[ref] = nil
        local key = self.nodeById[nodeId]
        if key and state.depleted then self:refreshNodeTarget(self.nodes[key]) end
        return true
    end
    local gone = (why == "unknown_container" or why == "container_closed") and self.containersUp
    if why == "depleted" or gone then
        -- A lease budget, not value: nothing to conserve. Logged, never retried.
        self.pendingConsume[ref] = nil
        self:log("row %s charge for %s not spent: %s", tostring(nodeId), ref, tostring(why))
        return false
    end
    self.pendingConsume[ref] = nodeId
    return false
end

function S:containersStopped() self.containersUp = false end

function S:onContainerClosed(id, reason)
    local key = self.nodeById[id]
    local node = key and self.nodes[key]
    if not node then return end
    self.nodeById[id] = nil
    node.id, node.depleted = nil, nil
    self.P.actions.untarget("node_" .. key)
    self:warn("row %s (%s) was closed in open77_containers (%s): it offers nothing until it gets a new " ..
        "containerKey in config", key, self:nodeKey(node.cfg), tostring(reason))
end

function S:retryMissingNodes()
    local missing = false
    for _, node in pairs(self.nodes) do if not node.id then missing = true end end
    if not missing or self.P.now() < self.nodesRetryAt then return end
    self.nodesRetryAt = self.P.now() + 30000
    if self:loadNodes() then
        for _, node in pairs(self.nodes) do self:refreshNodeTarget(node, true) end
    end
end

-- ---------------------------------------------------------------------------------------------
-- Crates
-- ---------------------------------------------------------------------------------------------
function S:adopt(holdId, meta, state)
    local crate = self.crates[holdId]
    if not crate then
        crate = { id = holdId, key = self.M.keyOf(holdId), iid = self.M.tokenOf(holdId) }
        self.crates[holdId] = crate
    end
    crate.meta = meta
    crate.state = state or crate.state
    return crate
end

function S:forget(crate)
    if crate.itemId then self.byItem[crate.itemId] = nil end
    self.crates[crate.id] = nil
end

function S:cratesOf(subject)
    local out = {}
    for _, crate in pairs(self.crates) do
        if crate.meta and crate.meta.owner == subject and crate.state ~= "delivered" then out[#out + 1] = crate end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

function S:openCount()
    local n = 0
    for _, crate in pairs(self.crates) do if crate.state ~= "delivered" then n = n + 1 end end
    return n
end

function S:placeItem(crate)
    if crate.itemId and self.P.actions.carryGet(crate.itemId) then return crate.itemId end
    if crate.itemId then self.byItem[crate.itemId] = nil end
    local meta = crate.meta
    local itemId, why = self.P.actions.carryPlace(KIND_CRATE, {
        position = meta.at, yaw = meta.yaw or 0.0, bucket = meta.bucket or 0, data = { container = crate.id },
    })
    if not itemId then
        crate.itemId = nil
        crate.unplaced = true
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

function S:persistMeta(crate)
    local snap, why = self.L.setMeta(crate.id, crate.meta)
    if snap then
        crate.dirty = nil
        return true
    end
    crate.dirty = true
    return nil, why
end

function S:setPlacement(crate, position, yaw, bucket)
    crate.meta.at = { x = position.x, y = position.y, z = position.z }
    if yaw ~= nil then crate.meta.yaw = yaw end
    if bucket ~= nil then crate.meta.bucket = bucket end
    crate.meta.where = nil
    local ok, why = self:persistMeta(crate)
    if not ok then
        self:warn("placement of %s not persisted (%s): retried by the sweep", crate.id, tostring(why))
    end
end

-- Your ground crate next to this row, or a new one. Returns crate, nil, isNew | nil, reason.
function S:crateForWork(subject, node, bucket, opId)
    local best, bestD
    for _, crate in pairs(self.crates) do
        local meta = crate.meta
        if crate.state == "ground" and meta.owner == subject and (meta.bucket or 0) == bucket then
            local d = self.M.planar(meta.at, node.cfg.position)
            if d and d <= self.cfg.crate.joinRadiusM and (not bestD or d < bestD) then best, bestD = crate, d end
        end
    end
    if best then
        if best.reservedBy and best.reservedBy ~= opId and self.work[best.reservedBy] then return nil, "crate_busy" end
        return best, nil, false
    end
    if #self:cratesOf(subject) >= self.cfg.crate.maxPerPlayer then return nil, "too_many_crates" end
    if self:openCount() >= self.cfg.crate.maxOpen then return nil, "farm_full" end
    local at = self.M.towards(node.cfg.position, self.cfg.laneCentre, self.cfg.crateOffsetM)
    local meta = self.M.crateMeta({
        owner = subject, node = node.key, created = self.P.now(), at = at,
        yaw = self.M.yawTowards(at, node.cfg.position), bucket = bucket,
    })
    local capacityG = math.floor(self.cfg.crate.contentsKg * 1000) + self.cfg.weightsG.chooh2_crate
    local snap, why = self.L.openWorld({ capacityG = capacityG, meta = meta })
    if type(snap) ~= "table" or type(snap.id) ~= "string" then return nil, why or "chooh2_unavailable" end
    local crate = self:adopt(snap.id, meta, "new")
    self:log("crate %s opened for %s at %s", crate.id, subject, node.key)
    return crate, nil, true
end

function S:dropNewCrate(crate)
    if not crate or crate.state ~= "new" then return end
    local ok, why = self.L.close(crate.id)
    if ok or why == "unknown_account" then
        self:forget(crate)
    else
        self:log("new crate %s not closed yet (%s): the sweep retries", crate.id, tostring(why))
    end
end

-- ---------------------------------------------------------------------------------------------
-- Vehicles
-- ---------------------------------------------------------------------------------------------
-- The nearest truck to `origin` the player may use for `action` ("put" | "take"): tracked (a
-- plate), with a cargo layout, in the player's bucket. Returns vehicleId | nil, reason.
function S:truckNear(pid, origin, radius, action)
    local read = self.P.players.position(pid)
    local bucket = read and read.bucket or 0
    local best, bestD, refusal
    for _, v in ipairs(self.P.vehicles.all()) do
        local id = v.id
        local pos = self.P.vehicles.position(v)
        local d = pos and origin and self.M.distance(pos, origin)
        if id and d and d <= radius and (v.bucket or 0) == bucket and self.P.cargo.layout(v.record) then
            local plate = self.P.garage.plateOf(id)
            if type(plate) ~= "string" then
                refusal = refusal or "vehicle_not_tracked"
            else
                local allowed, why = self.P.garage.canAccess(pid, plate, "cargo", action)
                if allowed == true then
                    if not bestD or d < bestD then best, bestD = id, d end
                else
                    refusal = why or "no_access"
                end
            end
        end
    end
    if best then return best end
    return nil, refusal or "no_truck"
end

-- The car a refuel is about: the one named (a command), else the nearest to the pump (a pump
-- prompt) or to the player. Any car with a tank: no key needed to pour fuel into it.
-- Returns vehicle snapshot | nil, reason.
function S:refuelTarget(pid, ctx)
    local cfg = self.cfg
    local read = self.P.players.position(pid)
    if not read then return nil, "position_unavailable" end
    local bucket = read.bucket or 0
    local wanted = type(ctx.data) == "table" and self.M.integer(ctx.data.vehicleId) or nil
    if not wanted and type(ctx.reservation) == "table" then wanted = ctx.reservation.vehicleId end
    local atPump = type(ctx.target) == "table" and type(ctx.target.data) == "table" and ctx.target.data.pump == true
    local origin = atPump and cfg.pump.position or read
    local radius = atPump and cfg.pump.vehicleRadius or cfg.refuel.reachM
    local best, bestD
    for _, v in ipairs(self.P.vehicles.all()) do
        local pos = self.P.vehicles.position(v)
        if v.id and pos and (v.bucket or 0) == bucket and (wanted == nil or v.id == wanted) then
            local d = self.M.distance(pos, origin)
            if d and (d <= radius or (wanted ~= nil and self.M.distance(pos, read) <= cfg.refuel.reachM)) then
                if not bestD or d < bestD then best, bestD = v, d end
            end
        end
    end
    if not best then return nil, "no_vehicle" end
    if (tonumber(best.speed) or 0) > cfg.refuel.maxSpeedMps then return nil, "vehicle_moving" end
    return best
end

-- How much a canister pours into that car now: litres | nil, reason.
function S:fillFor(vehicleId)
    if not self.P.running("open77_fuel") then return nil, "fuel_unavailable" end
    local level = self.P.fuel.level(vehicleId)
    local capacity = self.P.fuel.capacity()
    if type(level) ~= "number" or type(capacity) ~= "number" then return nil, "fuel_unavailable" end
    return self.M.fuelFill(level, capacity, self.cfg.refuel)
end

-- ---------------------------------------------------------------------------------------------
-- Hooks: validate (synchronous)
-- ---------------------------------------------------------------------------------------------
function S:validate(ctx)
    if not fromActions() then return false, "not_owner" end
    if not self.ready then return false, "chooh2_unavailable" end
    local action, cfg = ctx.actionId, self.cfg
    local function refuse(reason)
        if ctx.phase == "begin" then self:refuseTo(ctx.playerId, reason) end
        return false, reason
    end
    if action == "harvest" or action == "inspect" then
        local key = type(ctx.target) == "table" and type(ctx.target.data) == "table" and ctx.target.data.node or nil
        local node = key and self.nodes[key]
        if not node or not node.id then return refuse("unknown_node") end
        if action == "harvest" and ctx.phase == "begin" then
            local summary = self.P.containers.summary(node.id)
            if type(summary) == "table" and summary.depleted then return refuse("node_depleted") end
        end
    elseif action == "refine" or action == "collect" or action == "gauges" then
        if not self.stashesOpen then return refuse("chooh2_unavailable") end
        if ctx.phase == "begin" and action ~= "gauges" then
            -- An early, friendly refusal; the reservation is the authority.
            local account = action == "refine" and cfg.accounts.intake or cfg.accounts.output
            local item = action == "refine" and cfg.harvest.item or "chooh2_canister"
            local need = action == "refine" and cfg.refine.cornIn or 1
            local snap = self.L.readLoaded(account)
            if type(snap) == "table" and self.M.available(snap, item) < need then
                return refuse(action == "refine" and "intake_empty" or "output_empty")
            end
        end
    elseif action == "sell" then
        if ctx.phase == "begin" then
            local subject = self.L.subjectOf(ctx.playerId)
            local snap = subject and self.L.readLoaded("char:" .. subject)
            if type(snap) == "table" and self.M.available(snap, "chooh2_canister") < 1 then
                return refuse("no_canisters")
            end
        end
    elseif action == "refuel" then
        local v, why = self:refuelTarget(ctx.playerId, ctx)
        if not v then return refuse(why) end
        if ctx.phase == "begin" then
            local litres, fwhy = self:fillFor(v.id)
            if not litres then return refuse(fwhy) end
        end
    end
    return true
end

-- ---------------------------------------------------------------------------------------------
-- Hooks: reserve -> commit, or cancel (harvest, refine, collect, refuel)
-- ---------------------------------------------------------------------------------------------
function S:reserve(ctx)
    if not fromActions() then return nil, "not_owner" end
    if not self.P.actions.verify(ctx.opId, "reserve") then return nil, "not_owner" end
    if not self.ready then return nil, "chooh2_unavailable" end
    local action = ctx.actionId
    if action == "harvest" then return self:reserveHarvest(ctx) end
    if action == "refine" then return self:reserveRefine(ctx) end
    if action == "collect" then return self:reserveCollect(ctx) end
    if action == "refuel" then return self:reserveRefuel(ctx) end
    return nil, "unknown_action"
end

function S:reserveHarvest(ctx)
    local cfg = self.cfg
    local node = self.nodes[ctx.target.data.node]
    local pid = ctx.playerId
    local subject, why = self.L.subjectOf(pid)
    if not subject then return nil, why or "subject_unavailable" end
    local crate, cwhy, isNew = self:crateForWork(subject, node, ctx.bucket or cfg.bucket, ctx.opId)
    if not crate then return nil, cwhy end
    crate.reservedBy = ctx.opId
    local txOpId = self.L.newOpId("harvest")
    local reserved, reason = self.L.reserve({
        opId = txOpId, kind = "chooh2.harvest", actor = "char:" .. subject, reason = "harvest " .. node.key,
        ttlMs = cfg.actions.harvest.durationMs + 30000,
        lines = { { capacityG = self.M.maxHarvestG(cfg, isNew), from = cfg.accounts.fields, to = crate.id } },
    })
    if not reserved then
        crate.reservedBy = nil
        if isNew then self:dropNewCrate(crate) end
        return nil, self.M.harvestRefusal(reason)
    end
    local r = { kind = "harvest", txOpId = txOpId, node = node.key, nodeId = node.id, crate = crate.id,
        isNew = isNew, subject = subject, pid = pid }
    self.work[ctx.opId] = r
    self.opIds[ctx.opId] = txOpId
    return r
end

function S:reserveRefine(ctx)
    local cfg = self.cfg
    local subject = self.L.subjectOf(ctx.playerId)
    local txOpId = self.L.newOpId("refine")
    local reserved, reason = self.L.reserve({
        opId = txOpId, kind = "chooh2.refine", actor = subject and ("char:" .. subject) or nil, reason = "CHOOH2 run",
        ttlMs = cfg.actions.refine.durationMs + 30000, lines = self.M.refineLines(cfg),
    })
    if not reserved then return nil, self.M.refineRefusal(reason) end
    self.opIds[ctx.opId] = txOpId
    return { kind = "refine", txOpId = txOpId, subject = subject, pid = ctx.playerId }
end

function S:reserveCollect(ctx)
    local cfg = self.cfg
    local subject, why = self.L.subjectOf(ctx.playerId)
    if not subject then return nil, why or "subject_unavailable" end
    local snap, rwhy = self.L.read(cfg.accounts.output)
    if type(snap) ~= "table" then return nil, rwhy or "chooh2_unavailable" end
    local count = math.min(self.M.available(snap, "chooh2_canister"), cfg.collectMax)
    if count < 1 then return nil, "output_empty" end
    local txOpId = self.L.newOpId("collect")
    local reserved, reason = self.L.reserve({
        opId = txOpId, kind = "chooh2.collect", actor = "char:" .. subject, reason = "canisters taken",
        ttlMs = cfg.actions.collect.durationMs + 30000,
        lines = { { item = "chooh2_canister", count = count, from = cfg.accounts.output, to = "char:" .. subject } },
    })
    if not reserved then return nil, self.M.collectRefusal(reason) end
    self.opIds[ctx.opId] = txOpId
    return { kind = "collect", txOpId = txOpId, count = count, subject = subject, pid = ctx.playerId }
end

function S:reserveRefuel(ctx)
    local cfg = self.cfg
    local subject, why = self.L.subjectOf(ctx.playerId)
    if not subject then return nil, why or "subject_unavailable" end
    local v, vwhy = self:refuelTarget(ctx.playerId, ctx)
    if not v then return nil, vwhy end
    local litres, fwhy = self:fillFor(v.id)
    if not litres then return nil, fwhy end
    local txOpId = self.L.newOpId("refuel")
    local reserved, reason = self.L.reserve({
        opId = txOpId, kind = "chooh2.refuel", actor = "char:" .. subject, reason = "refuel",
        ttlMs = cfg.actions.refuel.durationMs + 30000,
        lines = { { item = "chooh2_canister", count = 1, from = "char:" .. subject, to = cfg.accounts.burned } },
    })
    if not reserved then
        if reason == "insufficient_items" or reason == "unknown_account" then reason = "no_canisters" end
        return nil, reason
    end
    self.opIds[ctx.opId] = txOpId
    return { kind = "refuel", txOpId = txOpId, vehicleId = v.id, litres = litres, subject = subject, pid = ctx.playerId }
end

-- The final lines of a commit: a harvest rolls its corn from the op id (identical on every retry);
-- the other reservations commit exactly what they hold.
function S:finalLines(r)
    if r.kind == "harvest" then return (self.M.harvestLines(self.cfg, r)) end
    return nil
end

function S:commit(ctx)
    if not fromActions() then return nil, "not_owner" end
    if not self.P.actions.verify(ctx.opId, "commit") then return nil, "not_owner" end
    local r = ctx.reservation
    if type(r) ~= "table" or not r.txOpId then return nil, "no_reservation" end
    local lines = self:finalLines(r)
    local receipt, why = self.L.commit(r.txOpId, lines and { lines = lines } or nil)
    if not receipt then
        if why == "in_doubt" or why == "busy" then
            self.doubts[r.txOpId] = r
        elseif TRANSIENT_REFUSAL[why] and self.doubts[r.txOpId] then
            -- Nothing was applied by THIS attempt, but an earlier one of the same op may have landed.
            why = "in_doubt"
        end
        return nil, why
    end
    local ok, err = pcall(self.afterCommit, self, r, receipt)
    if not ok then self:warn("after %s %s raised: %s", r.kind, r.txOpId, tostring(err)) end
    return { tx = r.txOpId, kind = r.kind, crate = r.crate, replay = receipt.replay == true }
end

function S:cancel(ctx)
    if not fromActions() then return end
    self.work[ctx.opId] = nil
    self.sales[ctx.opId] = nil
    local r = ctx.reservation
    if type(r) ~= "table" or not r.txOpId then return end
    if ctx.reason == "in_doubt" then
        -- The commit may have happened: never cancel; settle with the coordinator's fence.
        self.doubts[r.txOpId] = r
        self.stats.doubts = self.stats.doubts + 1
        self:settle(r)
        return
    end
    self.L.cancel(r.txOpId, ctx.reason)
    if r.kind == "harvest" then
        local crate = self.crates[r.crate]
        if crate and crate.reservedBy == ctx.opId then crate.reservedBy = nil end
        if r.isNew then self:dropNewCrate(crate) end
    end
end

function S:settle(r)
    local outcome, receipt = self.L.settle(r.txOpId)
    if outcome == "committed" then
        self:afterCommit(r, receipt)
    elseif outcome == "failed" or outcome == "aborted" then
        self.doubts[r.txOpId] = nil
        self:log("%s %s settled: %s (nothing moved)", r.kind, r.txOpId, outcome)
        if r.kind == "harvest" then
            local crate = self.crates[r.crate]
            if crate then crate.reservedBy = nil end
            if r.isNew then self:dropNewCrate(crate) end
        end
    end
    return outcome
end

-- What follows a committed reservation, once per op id in this process.
function S:afterCommit(r, receipt)
    if self.done[r.txOpId] then return end
    self.done[r.txOpId] = self.P.now()
    self.doubts[r.txOpId] = nil
    local replay = type(receipt) == "table" and receipt.replay == true
    if r.kind == "harvest" then return self:afterHarvest(r, replay) end
    if r.kind == "refine" then return self:afterRefine(r, replay) end
    if r.kind == "collect" then return self:afterCollect(r, replay) end
    if r.kind == "refuel" then return self:afterRefuel(r, replay) end
end

function S:afterHarvest(r, replay)
    self.stats.harvests = self.stats.harvests + 1
    local crate = self.crates[r.crate]
    if crate then
        crate.reservedBy = nil
        if crate.state == "new" then crate.state = "ground" end
        if crate.state == "ground" then self:placeItem(crate) end
    end
    self:consumeNode(r.nodeId, r.txOpId)
    local _, count = self.M.harvestLines(self.cfg, r)
    local text = ("+%d corn into your crate."):format(count)
    self:record(r.subject, { kind = "harvest", opId = r.txOpId, text = text, replay = replay })
    self:log("harvest %s by %s at %s committed: +%d corn (crate %s)", r.txOpId, r.subject, r.node, count, r.crate)
    self:tellSubject(r.subject, r.pid, text, "success")
    self:completed("harvest", r.pid, r.txOpId, { row = r.node, corn = count, crate = r.crate, subject = r.subject })
end

function S:afterRefine(r, replay)
    self.stats.runs = self.stats.runs + 1
    local cfg = self.cfg
    local text = ("Batch done: %d corn in, %d CHOOH2 canister(s) on the rack."):format(cfg.refine.cornIn,
        cfg.refine.canistersOut)
    self:record(r.subject, { kind = "refine", opId = r.txOpId, text = text, replay = replay })
    self:log("refine %s by %s committed: -%d corn, +%d canisters", r.txOpId, tostring(r.subject), cfg.refine.cornIn,
        cfg.refine.canistersOut)
    self:tellSubject(r.subject, r.pid, text, "success")
    self:completed("refine", r.pid, r.txOpId, { corn = cfg.refine.cornIn, canisters = cfg.refine.canistersOut,
        subject = r.subject })
end

function S:afterCollect(r, replay)
    self.stats.collected = self.stats.collected + r.count
    local text = ("+%d CHOOH2 canister(s) in your pockets."):format(r.count)
    self:record(r.subject, { kind = "collect", opId = r.txOpId, text = text, replay = replay })
    self:log("collect %s by %s committed: %d canisters", r.txOpId, r.subject, r.count)
    self:tellSubject(r.subject, r.pid, text, "success")
end

function S:afterRefuel(r, replay)
    self.stats.refuels = self.stats.refuels + 1
    self:record(r.subject, { kind = "refuel", opId = r.txOpId, text = "canister poured", replay = replay })
    self:completed("refuel", r.pid, r.txOpId, { vehicleId = r.vehicleId, litres = r.litres, subject = r.subject })
    self.pendingFills[r.txOpId] = { vehicleId = r.vehicleId, litres = r.litres, pid = r.pid, subject = r.subject, tries = 0 }
    self:fill(r.txOpId)
end

-- Pours a committed canister into the car (open77_fuel). The canister is gone either way: a
-- failure is retried by the sweep while the car exists, at most 12 times.
function S:fill(txOpId)
    local f = self.pendingFills[txOpId]
    if not f then return end
    f.tries = f.tries + 1
    local before = self.P.running("open77_fuel") and self.P.fuel.level(f.vehicleId) or nil
    local after, why
    if self.P.running("open77_fuel") then
        after, why = self.P.fuel.refuel(f.vehicleId, f.litres)
    else
        why = "fuel_unavailable"
    end
    if type(after) == "number" then
        self.pendingFills[txOpId] = nil
        local added = type(before) == "number" and math.max(0, after - before) or f.litres
        local text = ("Poured a CHOOH2 canister: +%.1f L, tank %.1f L."):format(added, after)
        self:log("refuel %s: vehicle %s +%.1f L -> %.1f L", txOpId, tostring(f.vehicleId), added, after)
        self:tellSubject(f.subject, f.pid, text, "success")
        return true
    end
    if why == "vehicle_not_found" or why == "invalid_vehicle_id" or f.tries >= 12 then
        self.pendingFills[txOpId] = nil
        self:warn("refuel %s: canister burned but the tank of vehicle %s was not filled (%s)", txOpId,
            tostring(f.vehicleId), tostring(why))
        self:tellSubject(f.subject, f.pid, "The canister was poured, but the car is gone: the fuel is lost.", "warning")
        return false
    end
    self:log("refuel %s: fill of vehicle %s deferred (%s)", txOpId, tostring(f.vehicleId), tostring(why))
    return false
end

-- ---------------------------------------------------------------------------------------------
-- Hooks without a reservation: check the row, the gauges, clock in, unload, sell
-- ---------------------------------------------------------------------------------------------
function S:inspect(ctx)
    if not fromActions() then return nil, "not_owner" end
    local subject = self.L.subjectOf(ctx.playerId)
    local key = ctx.target and ctx.target.data and ctx.target.data.node
    local node = self.nodes[key]
    local lines = {}
    for _, crate in ipairs(subject and self:cratesOf(subject) or {}) do
        if crate.state == "ground" and node and (self.M.planar(crate.meta.at, node.cfg.position) or 99) <= self.cfg.crate.joinRadiusM then
            local snap = self.L.read(crate.id)
            if type(snap) == "table" then
                lines[#lines + 1] = ("Your crate: %d corn (%.1f / %d kg)."):format(self.M.countOf(snap, self.cfg.harvest.item),
                    self.M.contentsWeightG(snap, self.cfg.weightsG) / 1000, self.cfg.crate.contentsKg)
            end
        end
    end
    if node then
        local summary = self.P.containers.summary(node.id)
        if type(summary) == "table" and summary.charges then
            lines[#lines + 1] = ("%s: %d / %d harvests left."):format(node.cfg.label, summary.charges,
                summary.maxCharges or summary.charges)
        end
    end
    self:tell(ctx.playerId, #lines > 0 and table.concat(lines, " ") or "No crate of yours here yet.", "info")
    return { inspected = true }
end

function S:gauges(ctx)
    if not fromActions() then return nil, "not_owner" end
    local cfg = self.cfg
    local intake = self.L.read(cfg.accounts.intake)
    local output = self.L.read(cfg.accounts.output)
    local corn = type(intake) == "table" and self.M.available(intake, cfg.harvest.item) or 0
    local cans = type(output) == "table" and self.M.available(output, "chooh2_canister") or 0
    self:tell(ctx.playerId, ("Intake: %d corn. Rack: %d canister(s). A batch takes %d corn and makes %d canister(s).")
        :format(corn, cans, cfg.refine.cornIn, cfg.refine.canistersOut), "info")
    return { corn = corn, canisters = cans }
end

function S:duty(ctx)
    if not fromActions() then return nil, "not_owner" end
    local on = ctx.actionId == "clock_in"
    local which = type(ctx.target) == "table" and type(ctx.target.data) == "table" and ctx.target.data.office or nil
    local summary, swhy = self.P.jobs.summary(ctx.playerId)
    if type(summary) ~= "table" then return nil, swhy or "not_eligible" end
    local job = summary.job
    if not job then return nil, "no_job" end
    if not self.M.jobIn(job, self.cfg.offices[which]) then return nil, "wrong_office" end
    local ok, why = self.P.jobs.setDuty(ctx.playerId, on, { job = job })
    if not ok then return nil, why or "not_eligible" end
    local where = which == "farm" and "the farm" or "the refinery"
    self:tell(ctx.playerId, on and ("On duty at " .. where .. ".") or "Off duty. See you, choom.", "success")
    return { duty = on, job = job }
end

function S:unloadAction(ctx)
    if not fromActions() then return nil, "not_owner" end
    if not self.P.actions.verify(ctx.opId, "commit") then return nil, "not_owner" end
    local bay = self.cfg.unloadBay
    local crate, itemOrWhy = self:unloadCrate(ctx.playerId, nil, bay.position, bay.truckRadius, ctx.opId)
    if not crate then return nil, itemOrWhy end
    return { crate = crate.id, item = itemOrWhy }
end

-- The canister sale: one rp_economy:sale. The spec is made once per action operation and kept
-- for its retries, so a retried commit replays the first receipt instead of selling again.
function S:sell(ctx)
    if not fromActions() then return nil, "not_owner" end
    if not self.P.actions.verify(ctx.opId, "commit") then return nil, "not_owner" end
    local cfg = self.cfg
    local pid = ctx.playerId
    local spec = self.sales[ctx.opId]
    if not spec then
        local subject, swhy = self.L.subjectOf(pid)
        if not subject then return nil, swhy end
        local pockets, rwhy = self.L.read("char:" .. subject)
        if type(pockets) ~= "table" then return nil, rwhy == "unknown_account" and "no_canisters" or rwhy end
        local count = math.min(self.M.available(pockets, "chooh2_canister"), cfg.saleMax)
        local q, qwhy = self.M.quote(count, cfg.prices.chooh2_canister, cfg.societyShare)
        if not q then return nil, qwhy end
        local payees = { { subject = subject, amount = q.seller } }
        if q.society > 0 then payees[#payees + 1] = { society = cfg.society, amount = q.society } end
        -- The seller as a connected player: under a strict `writers` list rp_economy asks
        -- rp_inventory for a one-operation grant on these pockets, which needs the player id.
        spec = {
            opId = self.L.newOpId("sale"), seller = { player = pid },
            items = { { item = "chooh2_canister", count = q.count } }, buyer = { sys = cfg.depot.buyer },
            total = q.total, payees = payees, reason = "CHOOH2 canisters",
            quote = q, subject = subject,
        }
        self.sales[ctx.opId] = spec
    end
    local call = {}
    for k, v in pairs(spec) do if k ~= "quote" and k ~= "subject" then call[k] = v end end
    local receipt, why = self.P.economy.sale(call)
    if not receipt then return nil, self.M.saleRefusal(why) end
    self.sales[ctx.opId] = nil
    local q = spec.quote
    self.stats.sales = self.stats.sales + 1
    local text = ("Sold %d canister(s) to %s: %d eddies (%d to you, %d to the %s society)."):format(q.count,
        cfg.depot.name, q.total, q.seller, q.society, cfg.society)
    self:record(spec.subject, { kind = "sale", opId = spec.opId, text = text, replay = receipt.replay == true })
    self:log("sale %s by %s: %d canisters total=%d seller=%d society=%d%s", spec.opId, spec.subject, q.count, q.total,
        q.seller, q.society, receipt.replay and " (replay)" or "")
    self:tell(pid, text, "success")
    if not (receipt.replay and self.done[spec.opId]) then
        self.done[spec.opId] = self.P.now()
        self:completed("sell", pid, spec.opId, { canisters = q.count, total = q.total, society = q.society,
            subject = spec.subject })
    end
    return { sale = spec.opId, total = q.total, count = q.count, replay = receipt.replay == true }
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
    if not self.ready then return false, "chooh2_unavailable" end
    local crate = self:crateOf(ctx)
    if not crate then return false, "crate_unavailable" end
    if ctx.kind == "carry_pickup" then
        if crate.state ~= "ground" then return false, "crate_unavailable" end
        if crate.reservedBy and self.work[crate.reservedBy] then return false, "crate_busy" end
        if self.cfg.crate.pickupBy == "owner" and self.L.subjectOf(ctx.playerId) ~= crate.meta.owner then
            self:refuseTo(ctx.playerId, "not_crate_owner")
            return false, "not_crate_owner"
        end
    end
    return true
end

function S:cratePickup(ctx)
    if not fromActions() then return nil, "not_owner" end
    local crate = self:crateOf(ctx)
    if not crate or crate.state ~= "ground" then return nil, "crate_unavailable" end
    local snap, why = self.L.read(crate.id)
    if type(snap) ~= "table" then return nil, why == "unknown_account" and "crate_unavailable" or (why or "chooh2_unavailable") end
    if not self.M.tokenHere(snap, crate.iid) then return nil, "crate_unavailable" end
    crate.state, crate.carrier = "carried", ctx.playerId
    return { crate = crate.id }
end

function S:cratePutdown(ctx)
    if not fromActions() then return nil, "not_owner" end
    local crate = self:crateOf(ctx)
    if not crate or crate.state ~= "carried" then return nil, "crate_unavailable" end
    local dest = ctx.carry and ctx.carry.destination or { kind = "ground" }
    local bay = (type(ctx.target) == "table" and type(ctx.target.data) == "table" and ctx.target.data.bay)
        or (type(ctx.data) == "table" and ctx.data.intent) or nil
    if bay == "intake" then return self:deliver(ctx, crate) end
    if bay == "load" or dest.kind == "vehicle" then return self:load(ctx, crate, dest, bay) end
    local read = self.P.players.get(ctx.playerId)
    local spot, yaw
    if dest.kind == "point" and dest.position then
        spot, yaw = dest.position, dest.yaw or 0.0
    else
        local origin = (read and read.position) or crate.meta.at
        yaw = (read and (read.heading or read.yaw)) or 0.0
        spot = self.M.offsetPoint(origin, yaw, 0.7)
    end
    crate.state, crate.carrier = "ground", nil
    self:setPlacement(crate, spot, yaw, read and read.bucket or crate.meta.bucket)
    return { placement = { kind = "point", position = spot, yaw = yaw } }
end

function S:crateDropped(ctx)
    if not fromActions() then return end
    local crate = self:crateOf(ctx)
    if not crate then return end
    crate.carrier = nil
    if crate.state == "carried" then crate.state = "ground" end
    self:reconcileCrate(crate, ctx.position)
end

-- Re-derives a crate's state from the coordinator. `spot` = where its item now lies (a drop).
function S:reconcileCrate(crate, spot)
    local snap, why = self.L.read(crate.id)
    if type(snap) ~= "table" then
        if why == "unknown_account" then
            self:unplaceItem(crate)
            self:forget(crate)
        else
            crate.needsReconcile = true
        end
        return
    end
    crate.needsReconcile = nil
    if not crate.dirty and self.M.isOurs(snap.meta) then crate.meta = snap.meta end
    if crate.meta.deliver and crate.state ~= "delivered" then
        local outcome = self:settleDelivery(crate)
        if outcome == "committed" or outcome == "pending" then return end
    end
    if self.M.tokenHere(snap, crate.iid) then
        if crate.state ~= "carried" then crate.state = "ground" end
        if spot and crate.state == "ground" then self:setPlacement(crate, spot, nil, nil) end
        if crate.state == "ground" and not crate.itemId then self:placeItem(crate) end
    elseif self.M.isEmpty(snap) then
        crate.state = crate.state == "new" and "new" or "empty"
        self:unplaceItem(crate)
    else
        crate.state = "truck"
        self:unplaceItem(crate)
    end
end

-- ---------------------------------------------------------------------------------------------
-- Load: the token leaves the hold for the bed (rp_cargo; rp_garage decides who may)
-- ---------------------------------------------------------------------------------------------
function S:load(ctx, crate, dest, bay)
    local pid = ctx.playerId
    local vid = dest.kind == "vehicle" and dest.vehicleId or nil
    if not vid then
        local origin = bay == "load" and self.cfg.farmBay.position or (self.P.players.position(pid) or crate.meta.at)
        local radius = bay == "load" and self.cfg.farmBay.truckRadius or self.cfg.truckNearM
        local why
        vid, why = self:truckNear(pid, origin, radius, "put")
        if not vid then return nil, why end
    end
    local opId = self.opIds[ctx.opId] or self.L.newOpId("load")
    self.opIds[ctx.opId] = opId
    local granted, gwhy = self.L.authorize(opId, "rp_cargo", { crate.id }, 60000)
    if not granted then return nil, gwhy or "chooh2_not_configured" end
    local res, why = self.P.cargo.load(pid, vid, crate.iid, {
        opId = opId, from = crate.id, item = "chooh2_crate", model = self.cfg.crate.model,
    })
    if not res then
        if why == "busy" then why = "in_doubt" end
        return nil, why
    end
    self.stats.loads = self.stats.loads + 1
    crate.state, crate.carrier, crate.plate = "truck", nil, res.plate
    if crate.itemId then self.byItem[crate.itemId] = nil end
    crate.itemId = nil
    crate.meta.where = "veh:" .. tostring(res.plate) .. ":cargo"
    self:persistMeta(crate)
    local text = ("Corn crate loaded on %s, slot %s."):format(tostring(res.plate), tostring(res.slot))
    self:record(crate.meta.owner, { kind = "load", opId = opId, text = text })
    self:tell(pid, text, "success")
    self:log("crate %s loaded on %s slot %s by player %d (op %s%s)", crate.id, tostring(res.plate), tostring(res.slot),
        pid, opId, res.replay and ", replay" or "")
    return { placement = { kind = "remove" }, load = { plate = res.plate, slot = res.slot, layer = res.layer } }
end

-- ---------------------------------------------------------------------------------------------
-- Unload: the token comes back into its hold, then the player lifts the crate
-- ---------------------------------------------------------------------------------------------
function S:unloadCrate(pid, vid, origin, radius, key)
    if not vid then
        local why
        vid, why = self:truckNear(pid, origin, radius, "take")
        if not vid then return nil, why end
    end
    local view, cwhy = self.P.cargo.contents(pid, vid)
    if type(view) ~= "table" then return nil, cwhy end
    local pick
    for _, slot in ipairs(view.slots or {}) do
        for _, object in ipairs(slot.objects or {}) do
            local hold = self.M.holdOfToken(object.instance)
            if object.item == "chooh2_crate" and hold then pick = { iid = object.instance, hold = hold } end
        end
    end
    if not pick then return nil, "no_corn_crate" end
    local crate = self.crates[pick.hold]
    if not crate then
        local snap = self.L.read(pick.hold)
        if type(snap) ~= "table" or not self.M.isOurs(snap.meta) then return nil, "unknown_crate" end
        crate = self:adopt(pick.hold, snap.meta, "truck")
    end
    local opId = (key and self.opIds[key]) or self.L.newOpId("unload")
    if key then self.opIds[key] = opId end
    local granted, gwhy = self.L.authorize(opId, "rp_cargo", { crate.id }, 60000)
    if not granted then return nil, gwhy or "chooh2_not_configured" end
    local res, why = self.P.cargo.unload(pid, vid, crate.iid, { to = crate.id, opId = opId })
    if not res then
        if why == "busy" then why = "in_doubt" end
        return nil, why
    end
    self.stats.unloads = self.stats.unloads + 1
    local read = self.P.players.get(pid)
    local yaw = (read and (read.heading or read.yaw)) or 0.0
    local origin2 = (read and read.position) or origin
    crate.state, crate.plate = "ground", nil
    self:setPlacement(crate, self.M.offsetPoint(origin2, yaw, 0.7), yaw, read and read.bucket or crate.meta.bucket)
    local itemId = self:placeItem(crate)
    self:record(crate.meta.owner, { kind = "unload", opId = opId, text = "Crate unloaded from " .. tostring(res.plate) })
    self:log("crate %s unloaded from %s by player %d (op %s%s)", crate.id, tostring(res.plate), pid, opId,
        res.replay and ", replay" or "")
    return crate, itemId
end

-- ---------------------------------------------------------------------------------------------
-- Deliver: the crate empties into the intake. ONE transfer moves every corn of the hold into the
-- intake stash and the token back to its source; the attempt's op id is persisted in the hold's
-- record BEFORE the transfer, so a crash at any point either finds it committed (the empty hold is
-- closed) or retries it under the next attempt id. The hold is then closed.
-- ---------------------------------------------------------------------------------------------
-- committed | pending | failed | aborted | none (boot and sweep recovery: nobody is waiting)
function S:settleDelivery(crate)
    local attempt = crate.meta.deliver
    if not attempt then return "none" end
    local outcome = self.L.settle(attempt.opId)
    if outcome == "committed" then
        self:log("delivery %s of %s found committed: closing the crate", attempt.opId, crate.id)
        if not self.done[attempt.opId] then
            self.done[attempt.opId] = self.P.now()
            self:completed("deliver_intake", nil, attempt.opId, { corn = attempt.corn, crate = crate.id,
                subject = attempt.by, harvester = crate.meta.owner, recovered = true })
        end
        self:retire(crate, true)
    elseif outcome == "failed" or outcome == "aborted" then
        crate.deliverChecked = attempt.opId
    end
    return outcome
end

-- A committed delivery, told once: the hauler's line, the receipt, the fixer event, the crate closed.
function S:delivered(pid, crate, attempt, replay)
    local cfg = self.cfg
    self.stats.deliveries = self.stats.deliveries + 1
    local intake = self.L.read(cfg.accounts.intake)
    local total = type(intake) == "table" and self.M.countOf(intake, cfg.harvest.item) or nil
    local text = ("%d corn into the intake%s."):format(attempt.corn, total and (" (intake: %d)"):format(total) or "")
    self:record(attempt.by, { kind = "deliver", opId = attempt.opId, text = text, replay = replay })
    self:log("delivery %s of crate %s by %s: %d corn%s", attempt.opId, crate.id, tostring(attempt.by), attempt.corn,
        replay and " (replay)" or "")
    self:tell(pid, text, "success")
    if not self.done[attempt.opId] then
        self.done[attempt.opId] = self.P.now()
        self:completed("deliver_intake", pid, attempt.opId, { corn = attempt.corn, crate = crate.id,
            subject = attempt.by, harvester = crate.meta.owner })
    end
    self:retire(crate, false)
    return { placement = { kind = "remove" }, deliver = { opId = attempt.opId, corn = attempt.corn, replay = replay } }
end

function S:deliver(ctx, crate)
    local pid = ctx.playerId
    local cfg = self.cfg
    if not self.stashesOpen then return nil, "chooh2_unavailable" end
    local subject, swhy = self.L.subjectOf(pid)
    if not subject then return nil, swhy end
    local pos = self.P.players.position(pid)
    if not pos or (self.M.planar(pos, cfg.intake.position) or 99) > 4.0 then return nil, "too_far" end

    -- An earlier attempt (this put-down's retry, another put-down, a restart): what became of it?
    -- `settle` fences an attempt that never reached the coordinator, so it can never land later.
    local attempt = crate.meta.deliver
    if attempt then
        local outcome = self.L.settle(attempt.opId)
        if outcome == "committed" then return self:delivered(pid, crate, attempt, true) end
        if outcome == "pending" then return nil, "in_doubt" end
        attempt = nil
    end
    local snap, rwhy = self.L.read(crate.id)
    if type(snap) ~= "table" then return nil, rwhy == "unknown_account" and "already_delivered" or rwhy end
    if not self.M.tokenHere(snap, crate.iid) then return nil, "crate_unavailable" end
    local n = (crate.meta.deliver and crate.meta.deliver.attempt or 0) + 1
    attempt = { attempt = n, by = subject, corn = self.M.countOf(snap, cfg.harvest.item),
        opId = ("ch2.deliver:%s.a%d"):format(crate.key, n) }
    -- Persisted BEFORE the transfer: a crash after it finds the attempt and settles it.
    local previous = crate.meta.deliver
    crate.meta.deliver = attempt
    local ok, mwhy = self:persistMeta(crate)
    if not ok then
        crate.meta.deliver = previous
        crate.dirty = nil
        return nil, mwhy or "store_unavailable"
    end
    local receipt, why = self.L.transfer({
        opId = attempt.opId, kind = "chooh2.deliver", actor = "char:" .. subject, reason = "corn delivered",
        lines = self.M.deliverLines(cfg, crate.id, attempt.corn),
    })
    if not receipt then
        if why == "busy" then why = "in_doubt" end
        return nil, self.M.deliverRefusal(why)
    end
    return self:delivered(pid, crate, attempt, receipt.replay == true)
end

-- The emptied hold is closed. Idempotent: an already closed hold is `unknown_account`.
function S:retire(crate, unplace)
    crate.state = "delivered"
    if unplace then self:unplaceItem(crate) elseif crate.itemId then
        self.byItem[crate.itemId] = nil
        crate.itemId = nil
    end
    local ok, why = self.L.close(crate.id)
    if ok or why == "unknown_account" then
        crate.retirePending = nil
        self:forget(crate)
        return true
    end
    if why == "container_not_empty" then
        -- Something entered the hold after the delivery: an operator sees it in chooh2.state.
        self:warn("delivered crate %s is not empty: not closed", crate.id)
        crate.retirePending = nil
        return false
    end
    crate.retirePending = true
    return false
end

-- ---------------------------------------------------------------------------------------------
-- Boot: rebuild every crate from the coordinator (the holds and their records)
-- ---------------------------------------------------------------------------------------------
function S:loadCrates()
    local after, seen = nil, 0
    local counts = { ground = 0, truck = 0, delivered = 0, orphan = 0, new = 0 }
    repeat
        local page, why = self.L.listWorld(after, 200)
        if type(page) ~= "table" then
            self:warn("crate listing failed: %s", tostring(why))
            return nil, why
        end
        for _, row in ipairs(page) do
            after = row.id
            if self.M.isOurs(row.meta) then
                seen = seen + 1
                local crate = self:adopt(row.id, row.meta, self.crates[row.id] and self.crates[row.id].state or "unknown")
                self:classify(crate, counts)
            end
        end
        self.P.wait(0)
    until #page < 200
    self:log("crates rebuilt from the coordinator: %d (ground %d, in a bed %d, delivered %d, new %d, orphans closed %d)",
        seen, counts.ground, counts.truck, counts.delivered, counts.new, counts.orphan)
    return seen
end

function S:classify(crate, counts)
    local snap = self.L.read(crate.id)
    if type(snap) ~= "table" then
        crate.needsReconcile = true
        return
    end
    if crate.meta.deliver then
        local outcome = self:settleDelivery(crate)
        if outcome == "committed" then counts.delivered = counts.delivered + 1 return end
    end
    if self.M.tokenHere(snap, crate.iid) then
        crate.state = crate.state == "carried" and "carried" or "ground"
        if crate.state == "ground" then self:placeItem(crate) end
        counts.ground = counts.ground + 1
    elseif not self.M.isEmpty(snap) then
        crate.state = "truck"
        counts.truck = counts.truck + 1
    else
        local age = self.P.now() - (tonumber(crate.meta.created) or 0)
        crate.state = "new"
        if age >= self.cfg.crate.orphanAgeMs and not (crate.reservedBy and self.work[crate.reservedBy]) then
            local ok, why = self.L.close(crate.id)
            if ok or why == "unknown_account" then
                self:forget(crate)
                counts.orphan = counts.orphan + 1
                return
            end
        end
        counts.new = counts.new + 1
    end
end

-- After open77_actions restarted: it forgot every item and carry; re-place the ground crates at
-- their durable placement (a carried crate returns to where it was last put down).
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
    if not self.stashesOpen then self:openStashes() end
    for _, r in pairs(self.doubts) do
        if not self.done[r.txOpId] then self:settle(r) end
    end
    for ref, nodeId in pairs(self.pendingConsume) do self:consumeNode(nodeId, ref) end
    local fills = {}
    for txOpId in pairs(self.pendingFills) do fills[#fills + 1] = txOpId end
    for _, txOpId in ipairs(fills) do self:fill(txOpId) end
    self:retryMissingNodes()
    local list = {}
    for _, crate in pairs(self.crates) do list[#list + 1] = crate end
    for _, crate in ipairs(list) do
        if crate.needsReconcile then
            self:reconcileCrate(crate)
        elseif crate.retirePending then
            self:retire(crate, true)
        elseif crate.meta.deliver and crate.state ~= "delivered" and crate.state ~= "carried"
            and crate.deliverChecked ~= crate.meta.deliver.opId then
            self:settleDelivery(crate)
        elseif crate.dirty then
            self:persistMeta(crate)
        elseif crate.state == "new" and not (crate.reservedBy and self.work[crate.reservedBy]) then
            local age = self.P.now() - (tonumber(crate.meta.created) or 0)
            if age >= self.cfg.crate.orphanAgeMs then
                local snap = self.L.read(crate.id)
                if type(snap) == "table" and self.M.isEmpty(snap) then self:dropNewCrate(crate)
                elseif type(snap) == "table" then self:reconcileCrate(crate) end
            end
        elseif crate.state == "ground" and crate.unplaced then
            self:placeItem(crate)
        end
    end
    for _, node in pairs(self.nodes) do self:refreshNodeTarget(node) end
    local cutoff = self.P.now() - 10 * 60 * 1000
    for txOpId, at in pairs(self.done) do
        if at < cutoff then self.done[txOpId] = nil end
    end
end

-- ---------------------------------------------------------------------------------------------
-- Presentation around the lifecycle (transition events of open77_actions)
-- ---------------------------------------------------------------------------------------------
local TERMINAL = { committed = true, cancelled = true, failed = true, in_doubt = true, refused = true }

function S:onTransition(op)
    if type(op) ~= "table" or op.owner ~= self.resource then return end
    if not TERMINAL[op.state] then return end
    local pid = op.playerId
    if op.state == "committed" then
        if op.actionId == "unload" and type(op.receipt) == "table" and op.receipt.item then
            local ok, why = self.P.actions.carryPickup(pid, op.receipt.item)
            if not ok then self:refuseTo(pid, why) end
        end
        self.opIds[op.opId] = nil
        return
    end
    self.opIds[op.opId] = nil
    self.sales[op.opId] = nil
    if op.reason == "superseded" then return end
    -- A begin refusal by our validate hook was already worded there.
    if op.stage == "validate" then return end
    if op.state == "in_doubt" then
        self:tell(pid, self.M.textFor("in_doubt"), "warning")
    else
        self:refuseTo(pid, op.reason)
    end
end

function S:spawnClerk()
    local npc = self.cfg.depot.npc
    if not npc or self.npcId then return end
    local def = { position = self.cfg.depot.position, yaw = self.cfg.depot.yaw, bucket = self.cfg.bucket,
        damagePolicy = npc.damagePolicy }
    if npc.record then def.record = npc.record else def.template = npc.template end
    local ok, id, why = pcall(self.P.npcs.create, def)
    if ok and id then
        self.npcId = id
    else
        self:log("depot clerk not spawned (%s): the counter works without it", tostring(ok and why or id))
    end
end

function S:shutdown()
    if self.npcId then pcall(self.P.npcs.remove, self.npcId) end
    self.npcId = nil
end

return Chooh2Service
