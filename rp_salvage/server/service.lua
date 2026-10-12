-- rp_salvage / server/service.lua: the salvage loop, as hooks of the wave-1 libraries.
--
--   clock in        foreman target -> action `clock_in` -> rp_jobs:setDuty
--   work            node target -> action `cut` | `pry`; reserve hook = ONE coordinator reservation
--                   (capacity envelope into the crate's hold + the tool's wear); commit hook = ONE
--                   commit (the rolled materials, the crate token when the crate is new, the same
--                   wear); then the node charge (open77_containers consume, idempotent by the op id)
--   carry           open77_actions carry kind `crate`; custody stays in the hold (A13 6.1): pickup
--                   is custody-neutral, a put-down on the ground persists the placement
--   load            put-down at the loading bay / onto a truck -> rp_cargo:load moves the crate token
--                   hold -> veh:<plate>:cargo (rp_garage canAccess decides), the bed prop is rp_cargo's
--   unload          unload bay action -> rp_cargo:unload moves the token back into its hold, then a
--                   carry pickup lifts it
--   sell            put-down at the buyer's counter -> rp_economy:sale (materials out of the hold +
--                   cash + society share, one operation, receipt), then the empty crate is retired
--
-- Durable state lives in the coordinator (holds, tokens, tools, money) and in open77_containers
-- (node charges; each node also has a zero-capacity world row it minted, which holds nothing).
-- This file keeps caches it can rebuild at boot (`loadCrates`, `loadNodes`).
--
-- Global: SalvageService.

SalvageService = {}
local S = {}
S.__index = S

local ACTIONS = "open77_actions"
local OWN = "rp_salvage"
local KIND_CRATE = "crate"
-- The coordinator's refusals that mean "nothing was applied, try again" (contract 7.2).
local TRANSIENT_REFUSAL = { coordinator_unavailable = true, store_unavailable = true, conflict = true }

function SalvageService.new(deps)
    local self = setmetatable({
        cfg = deps.config, M = deps.model, L = deps.ledger, P = deps.ports,
        resource = deps.resource or OWN,
        nodes = {}, nodeById = {},
        crates = {}, byItem = {},
        work = {},           -- [actions opId] = reservation summary (live work)
        doubts = {},         -- [tx opId] = reservation (a work commit in doubt, settled by the sweep)
        done = {},           -- [tx opId] = true (afterWork ran)
        pendingConsume = {}, -- [tx opId] = node container id (charge not spent yet)
        opIds = {},          -- [actions opId] = coordinator / cargo / sale op id (retries reuse it)
        receipts = {},       -- [subject] = ring of { kind, opId, text, at }
        notified = {},       -- [playerId] = ms of the last refusal toast
        handProps = {},      -- [actions opId] = prop id
        ready = false, declared = false, npcId = nil,
        containersUp = false,  -- open77_containers answered as ready since its last stop
        loadingNodes = false, nodesRetryAt = 0,
        stats = { works = 0, loads = 0, unloads = 0, sales = 0, retired = 0, refusals = 0, doubts = 0 },
    }, S)
    return self
end

function S:log(fmt, ...) self.P.log(fmt:format(...)) end
function S:warn(fmt, ...) self.P.warn(fmt:format(...)) end

local function fromActions() return GetInvokingResource() == ACTIONS end
S.fromActions = fromActions

-- ---------------------------------------------------------------------------------------------
-- Telling players
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

-- ---------------------------------------------------------------------------------------------
-- Items, actions, targets (re-run whenever open77_actions or rp_inventory restarts)
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
        self:warn("items: %s registered, %s refused %s (another definer owns them? rp_ferrailleur defines crowbar)",
            tostring(registered), tostring(rejected), table.concat(names, ","))
    else
        self:log("items defined through rp_inventory: %s", tostring(registered))
    end
    return true
end

local function workAction(cfg, id, spec)
    return {
        id = id, label = spec.label, durationMs = spec.durationMs, maxDistance = cfg.maxDistance,
        animation = spec.animation, progress = { label = spec.progress },
        hooks = { validate = "slvValidate", reserve = "slvReserve", commit = "slvCommit", cancel = "slvCancel" },
        eligibility = cfg.eligibility, epochs = cfg.epochs, reserveTimeoutMs = 20000,
    }
end

-- A wreck's prompt: cut, pry and check the haul; once stripped, only "Check the haul" (a node
-- regrows, the prompt comes back whole).
function S:nodeTarget(node, depleted)
    local actions = {
        { action = "cut", label = "Cut (torch)" },
        { action = "pry", label = "Pry (crowbar)" },
        { action = "inspect", label = "Check the haul" },
    }
    if depleted then actions = { { action = "inspect", label = "Check the haul" } } end
    return {
        id = "node_" .. node.key, position = node.cfg.position, yaw = node.cfg.yaw, bucket = self.cfg.bucket,
        label = depleted and (node.cfg.label .. " (stripped)") or node.cfg.label, distance = self.cfg.maxDistance,
        markerDistance = 12.0, requires = "empty", actions = actions, data = { node = node.key },
    }
end

function S:declare()
    local cfg, A = self.cfg, self.P.actions
    local defs = {
        workAction(cfg, "cut", cfg.actions.cut),
        workAction(cfg, "pry", cfg.actions.pry),
        {
            id = "inspect", label = cfg.actions.inspect.label, durationMs = cfg.actions.inspect.durationMs,
            maxDistance = cfg.maxDistance, animation = cfg.actions.inspect.animation,
            progress = { label = cfg.actions.inspect.progress },
            hooks = { validate = "slvValidate", commit = "slvInspect" }, eligibility = cfg.eligibility,
        },
        { id = "clock_in", label = "Clock in", durationMs = cfg.actions.clock.durationMs, maxDistance = 3.0,
          claim = false, progress = false, claims = false, hooks = { commit = "slvDuty" } },
        { id = "clock_out", label = "Clock out", durationMs = cfg.actions.clock.durationMs, maxDistance = 3.0,
          claim = false, progress = false, claims = false, hooks = { commit = "slvDuty" } },
        { id = "unload", label = cfg.actions.unload.label, durationMs = cfg.actions.unload.durationMs, maxDistance = 3.0,
          progress = { label = cfg.actions.unload.progress }, hooks = { validate = "slvValidate", commit = "slvUnload" },
          eligibility = cfg.eligibility, epochs = cfg.epochs },
    }
    for _, def in ipairs(defs) do
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
        hooks = { validate = "crateValidate", pickup = "cratePickup", putdown = "cratePutdown",
                  dropped = "crateDropped" },
        eligibility = cfg.eligibility, epochs = cfg.epochs,
    })
    if not kind then
        self:warn("carry kind refused by open77_actions: %s", tostring(why))
        return false
    end
    local targets = {
        { id = "foreman", position = cfg.foreman.position, yaw = cfg.foreman.yaw, bucket = cfg.bucket,
          label = cfg.foreman.label, distance = cfg.foreman.distance, markerDistance = 15.0, requires = "empty",
          actions = { { action = "clock_in", label = "Clock in" }, { action = "clock_out", label = "Clock out" } } },
        { id = "load_bay", position = cfg.bays.load.position, bucket = cfg.bucket, label = cfg.bays.load.label,
          distance = 2.5, markerDistance = 15.0, requires = "carrying",
          actions = { { action = "open77_actions:carry_putdown", label = "Load into the truck" } }, data = { bay = "load" } },
        { id = "sell_counter", position = cfg.buyer.counter, yaw = cfg.buyer.yaw, bucket = cfg.bucket,
          label = cfg.buyer.label, distance = 2.5, markerDistance = 15.0, requires = "carrying",
          actions = { { action = "open77_actions:carry_putdown", label = "Sell the crate" } }, data = { bay = "sell" } },
        { id = "unload_bay", position = cfg.bays.unload.position, bucket = cfg.bucket, label = cfg.bays.unload.label,
          distance = 2.5, markerDistance = 15.0, requires = "empty",
          actions = { { action = "unload", label = "Unload a crate" } }, data = { bay = "unload" } },
    }
    for _, def in ipairs(targets) do
        local key, twhy = A.target(def)
        if not key then self:warn("target %s refused: %s", def.id, tostring(twhy)) end
    end
    for _, node in pairs(self.nodes) do self:refreshNodeTarget(node, true) end
    self.declared = true
    return true
end

-- Re-declares a wreck's prompt when its depletion changes (same target id: the library replaces it).
function S:refreshNodeTarget(node, force)
    if not node.id then return end
    local summary = self.P.containers.summary(node.id)
    local depleted = type(summary) == "table" and summary.depleted == true
    if not force and depleted == node.depleted then return end
    node.depleted = depleted
    local key, why = self.P.actions.target(self:nodeTarget(node, depleted))
    if not key then self:warn("node target %s refused: %s", node.key, tostring(why)) end
end

-- ---------------------------------------------------------------------------------------------
-- Nodes: open77_containers (0.2.0) containers of kind "node", named by the key `node.<key>`.
-- Each is a zero-capacity coordinator world row minted by open77_containers (its id; the row
-- carries the placement and can hold nothing, so no value and no mint) plus, in
-- open77_containers' registry, the durable charges, consume refs and lazy regrowth. The
-- container's placement is informational: the prompt is this resource's open77_actions target at
-- the configured position, and reach is off.
-- ---------------------------------------------------------------------------------------------
local CONTAINERS_TRANSIENT = { not_ready = true, busy = true, open77_containers_unavailable = true }

-- A refusal that says "not now" (open77_containers booting, restarting or busy), not "never".
function S:nodesTransient(why, info)
    if CONTAINERS_TRANSIENT[why] or (type(info) == "table" and info.retryable == true) then return true end
    return type(why) == "string" and why:sub(1, 7) == "export_"
end

-- The node's durable name in open77_containers. A closed key is never reused there, so a node an
-- operator closed (`containers.remove`) comes back only under a new `containerKey` in config.
function S:nodeKey(nodeCfg) return nodeCfg.containerKey or ("node." .. nodeCfg.key) end

function S:nodeSpec(nodeCfg)
    local d = self.cfg.nodeDefaults
    return {
        key = self:nodeKey(nodeCfg), kind = "node", model = false, position = nodeCfg.position,
        yaw = nodeCfg.yaw or 0.0, bucket = self.cfg.bucket, label = nodeCfg.label,
        public = { node = nodeCfg.key, job = self.cfg.job },
        node = { charges = nodeCfg.charges or d.charges, regrowMs = nodeCfg.regrowMs or d.regrowMs },
        reachM = 0,
    }
end

-- Finds every node by its key, creating the missing ones (a keyed create is idempotent: the same
-- key and spec answer the existing container). open77_containers answers `not_ready` until its
-- boot join is done, and its `open77_containers:ready` is missed when it was up first, so the
-- create itself is the probe. Returns true when every node has an id; otherwise false and the
-- first reason (transient ones first: the caller waits on them, and logs the others).
function S:loadNodes()
    if self.loadingNodes then return false, "busy" end
    self.loadingNodes = true
    local ok, done, why, created = pcall(self._loadNodes, self)
    self.loadingNodes = false
    if not ok then
        self:warn("node load raised: %s", tostring(done))
        return false, "raised"
    end
    if done or not self:nodesTransient(why) then self.containersUp = true end
    -- Counted across the passes of one wait, so a boot that met `not_ready` still says how many
    -- nodes it created in all.
    self.nodesCreated = (self.nodesCreated or 0) + (created or 0)
    if done then
        self:log("%d wreck node(s) ready (%d created)", #self.cfg.nodes, self.nodesCreated)
        self.nodesCreated = 0
    end
    return done, why
end

function S:_loadNodes()
    local created, waiting, failed = 0, nil, nil
    for _, nodeCfg in ipairs(self.cfg.nodes) do
        if waiting then break end    -- open77_containers is not ready: the next pass asks again
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
                id = node.id    -- ids are durable: keep the one we knew while it restarts
            else
                failed = failed or why
                if node.warned ~= why then
                    node.warned = why
                    -- `container_closed`: an operator closed this node, and a closed key is never
                    -- reused. The node stays unavailable (prompts refuse `unknown_node`).
                    self:warn("node %s (%s) unavailable: %s", nodeCfg.key, self:nodeKey(nodeCfg), tostring(why))
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

-- Lab: back to full charges, in place (open77_containers `refill`, owner only). The node keeps
-- its id and its consume refs, so a retried charge of an earlier work still replays.
function S:resetNode(key)
    local node = self.nodes[key]
    if not node then return nil, "unknown_node" end
    if not node.id then return nil, "unknown_node" end
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
    -- While open77_containers restarts it knows no container yet: keep the charge for later.
    local gone = (why == "unknown_container" or why == "container_closed") and self.containersUp
    if why == "depleted" or gone then
        -- A lease budget, not value (A13 6.1): nothing to conserve. Logged, never retried.
        self.pendingConsume[ref] = nil
        self:log("node %s charge for %s not spent: %s", tostring(nodeId), ref, tostring(why))
        return false
    end
    self.pendingConsume[ref] = nodeId
    return false
end

-- open77_containers stopped: until its next `ready`, it answers `not_ready` / `unknown_container`.
function S:containersStopped() self.containersUp = false end

-- `open77_containers:closed(id, reason, owner)`: one of our nodes was closed (an operator's
-- `containers.remove`, or its world row closed outside). Its prompt goes; its key is spent.
function S:onContainerClosed(id, reason)
    local key = self.nodeById[id]
    local node = key and self.nodes[key]
    if not node then return end
    self.nodeById[id] = nil
    node.id, node.depleted = nil, nil
    self.P.actions.untarget("node_" .. key)
    self:warn("node %s (%s) was closed in open77_containers (%s): its wreck offers nothing until it gets a new " ..
        "containerKey in config", key, self:nodeKey(node.cfg), tostring(reason))
end

-- A node refused for a lasting reason (a `writers` entry missing, say) is asked for again every
-- 30 s, so fixing the configuration live brings it back without restarting this resource.
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
        if crate.meta and crate.meta.owner == subject and crate.state ~= "sold" then out[#out + 1] = crate end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

function S:openCount()
    local n = 0
    for _, crate in pairs(self.crates) do if crate.state ~= "sold" then n = n + 1 end end
    return n
end

-- The prop players see for a crate on the ground: an open77_actions carry item (A5 owns the
-- carriable prop; the crate's durable record is the hold's metadata).
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

-- Writes the crate record (placement, sale quote, where) into the hold's metadata.
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
        -- Presentation goes on; the sweep retries. A crash meanwhile brings the crate back at its
        -- previous durable spot, with its contents: no value is at stake.
        self:warn("placement of %s not persisted (%s): retried by the sweep", crate.id, tostring(why))
    end
end

-- Your ground crate next to this wreck, or a new one. Returns crate, nil, isNew | nil, reason.
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
    if self:openCount() >= self.cfg.crate.maxOpen then return nil, "yard_full" end
    local at = self.M.towards(node.cfg.position, self.cfg.yardCentre, self.cfg.crateOffsetM)
    local meta = self.M.crateMeta({
        owner = subject, node = node.key, created = self.P.now(), at = at,
        yaw = self.M.yawTowards(at, node.cfg.position), bucket = bucket,
    })
    local capacityG = math.floor(self.cfg.crate.contentsKg * 1000) + self.cfg.weightsG.salvage_crate
    local snap, why = self.L.openWorld({ capacityG = capacityG, meta = meta })
    if type(snap) ~= "table" or type(snap.id) ~= "string" then return nil, why or "salvage_unavailable" end
    local crate = self:adopt(snap.id, meta, "new")
    self:log("crate %s opened for %s at %s", crate.id, subject, node.key)
    return crate, nil, true
end

-- A crate opened for a work that did not commit: closed while it is still empty.
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
-- Hooks: validate (synchronous, every action of this resource)
-- ---------------------------------------------------------------------------------------------
function S:validate(ctx)
    if not fromActions() then return false, "not_owner" end
    if not self.ready then return false, "salvage_unavailable" end
    local action = ctx.actionId
    if action == "cut" or action == "pry" or action == "inspect" then
        local key = type(ctx.target) == "table" and type(ctx.target.data) == "table" and ctx.target.data.node or nil
        local node = key and self.nodes[key]
        if not node or not node.id then
            self:refuseTo(ctx.playerId, "unknown_node")
            return false, "unknown_node"
        end
        if action ~= "inspect" and ctx.phase == "begin" then
            local summary = self.P.containers.summary(node.id)
            if type(summary) == "table" and summary.depleted then
                self:refuseTo(ctx.playerId, "node_depleted")
                return false, "node_depleted"
            end
        end
    end
    return true
end

-- ---------------------------------------------------------------------------------------------
-- Hooks: the work (reserve -> commit, or cancel)
-- ---------------------------------------------------------------------------------------------
function S:wearLine(r)
    local account = "char:" .. r.subject
    if r.broken then
        return { instance = r.tool, from = account, to = self.cfg.accounts.broken, reason = "salvage wear" }
    end
    return { instance = r.tool, at = account, metaPatch = { durability = r.left }, reason = "salvage wear" }
end

-- The final lines of a work: the roll (from the op id: identical on every retry), the crate
-- token when the crate is new, the tool's wear. Exactly what the reservation's envelope covers.
function S:workLines(r)
    local cfg = self.cfg
    local rolled = self.M.roll(cfg.loot[r.action], r.txOpId)
    local lines = self.M.yieldLines(rolled, cfg.accounts.source, r.crate, "salvage " .. r.node)
    if r.isNew then
        lines[#lines + 1] = { instance = self.M.tokenOf(r.crate), item = "salvage_crate", from = cfg.accounts.source,
            to = r.crate, meta = { crate = r.crate, owner = r.subject }, reason = "salvage crate" }
    end
    lines[#lines + 1] = self:wearLine(r)
    return lines, rolled
end

function S:reserveWork(ctx)
    if not fromActions() then return nil, "not_owner" end
    if not self.P.actions.verify(ctx.opId, "reserve") then return nil, "not_owner" end
    if not self.ready then return nil, "salvage_unavailable" end
    local cfg = self.cfg
    local spec = cfg.actions[ctx.actionId]
    local node = self.nodes[ctx.target.data.node]
    local pid = ctx.playerId
    local subject, why = self.L.subjectOf(pid)
    if not subject then return nil, why or "subject_unavailable" end
    local account = "char:" .. subject
    local pockets, rwhy = self.L.read(account)
    if type(pockets) ~= "table" then
        return nil, (rwhy == "unknown_account") and "no_tool" or (rwhy or "salvage_unavailable")
    end
    local toolCfg = cfg.tools[spec.tool]
    local tool = self.M.pickTool(pockets.instances, spec.tool, toolCfg)
    if not tool then return nil, "no_tool" end

    local crate, cwhy, isNew = self:crateForWork(subject, node, ctx.bucket or cfg.bucket, ctx.opId)
    if not crate then return nil, cwhy end
    crate.reservedBy = ctx.opId
    local maxG = self.M.maxYieldG(cfg.loot[ctx.actionId], cfg.weightsG) + (isNew and cfg.weightsG.salvage_crate or 0)

    local wear, left, broken = self.M.wearLine(tool, account, toolCfg, cfg.accounts.broken, "salvage wear")
    local txOpId = self.L.newOpId("work")
    local reserved, reason = self.L.reserve({
        opId = txOpId, kind = "salvage.work", actor = account, reason = "salvage " .. node.key,
        ttlMs = spec.durationMs + 30000,
        lines = { { capacityG = maxG, from = cfg.accounts.source, to = crate.id }, wear },
    })
    if not reserved then
        crate.reservedBy = nil
        if isNew then self:dropNewCrate(crate) end
        return nil, self.M.workRefusal(reason)
    end
    local r = {
        txOpId = txOpId, action = ctx.actionId, node = node.key, nodeId = node.id, crate = crate.id, isNew = isNew,
        tool = tool.iid, toolItem = spec.tool, left = left, broken = broken, subject = subject, pid = pid,
    }
    self.work[ctx.opId] = r
    self.opIds[ctx.opId] = txOpId
    return r
end

function S:afterWork(r, receipt)
    if self.done[r.txOpId] then return end
    self.done[r.txOpId] = self.P.now()
    self.doubts[r.txOpId] = nil
    self.stats.works = self.stats.works + 1
    local crate = self.crates[r.crate]
    if crate then
        crate.reservedBy = nil
        if crate.state == "new" then crate.state = "ground" end
        if crate.state == "ground" then self:placeItem(crate) end
    end
    self:consumeNode(r.nodeId, r.txOpId)
    local _, rolled = self:workLines(r)
    local parts = {}
    for _, line in ipairs(rolled) do
        parts[#parts + 1] = ("+%d %s"):format(line.count, (self.cfg.items[line.item] or {}).label or line.item)
    end
    local toolLabel = self.cfg.items[r.toolItem].label
    local wearText = r.broken and (toolLabel .. " broke") or ("%s %d/%d"):format(toolLabel, r.left, self.cfg.tools[r.toolItem].max)
    local text = ("%s into your crate. %s."):format(table.concat(parts, ", "), wearText)
    self:record(r.subject, { kind = "work", opId = r.txOpId, text = text, replay = receipt and receipt.replay == true })
    self:log("work %s by %s at %s committed: %s (crate %s)", r.txOpId, r.subject, r.node, table.concat(parts, " "), r.crate)
    self:tellSubject(r.subject, r.pid, text, "success")
end

function S:commitWork(ctx)
    if not fromActions() then return nil, "not_owner" end
    if not self.P.actions.verify(ctx.opId, "commit") then return nil, "not_owner" end
    local r = ctx.reservation
    if type(r) ~= "table" or not r.txOpId then return nil, "no_reservation" end
    local lines = self:workLines(r)
    local receipt, why = self.L.commit(r.txOpId, { lines = lines })
    if not receipt then
        if why == "in_doubt" or why == "busy" then
            -- This submission may have landed (the ledger maps a lost answer to in_doubt).
            self.doubts[r.txOpId] = r
        elseif TRANSIENT_REFUSAL[why] and self.doubts[r.txOpId] then
            -- Nothing was applied by THIS attempt, but an earlier one of the same op may have
            -- landed: the outcome is still unknown, never "failed".
            why = "in_doubt"
        end
        -- Otherwise a transient refusal means nothing was applied: open77_actions retries it with
        -- the same op id, then fails the action with that reason (B5-3); cancelWork releases.
        return nil, why
    end
    local ok, err = pcall(self.afterWork, self, r, receipt)
    if not ok then self:warn("after work %s raised: %s", r.txOpId, tostring(err)) end
    return { tx = r.txOpId, crate = r.crate, durability = r.left, broken = r.broken, replay = receipt.replay == true }
end

function S:cancelWork(ctx)
    if not fromActions() then return end
    self.work[ctx.opId] = nil
    local r = ctx.reservation
    if type(r) ~= "table" or not r.txOpId then return end
    if ctx.reason == "in_doubt" then
        -- The commit may have happened: never cancel; settle with the coordinator's fence.
        self.doubts[r.txOpId] = r
        self.stats.doubts = self.stats.doubts + 1
        self:settleWork(r)
        return
    end
    self.L.cancel(r.txOpId, ctx.reason)
    local crate = self.crates[r.crate]
    if crate and crate.reservedBy == ctx.opId then crate.reservedBy = nil end
    if r.isNew then self:dropNewCrate(crate) end
end

function S:settleWork(r)
    local outcome, receipt = self.L.settle(r.txOpId)
    if outcome == "committed" then
        self:afterWork(r, receipt)
    elseif outcome == "failed" or outcome == "aborted" then
        self.doubts[r.txOpId] = nil
        self:log("work %s settled: %s (nothing was granted)", r.txOpId, outcome)
        local crate = self.crates[r.crate]
        if crate then crate.reservedBy = nil end
        if r.isNew then self:dropNewCrate(crate) end
    end
    return outcome
end

-- "Check the haul": presentation only (no value moves).
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
                local parts = {}
                for _, item in ipairs(self.cfg.saleOrder) do
                    local n = snap.items and snap.items[item]
                    if n and n > 0 then parts[#parts + 1] = ("%d %s"):format(n, self.cfg.items[item] and self.cfg.items[item].label or item) end
                end
                local contentsG = self.M.contentsWeightG(snap, self.cfg.weightsG)
                lines[#lines + 1] = ("Your crate: %s (%.1f / %d kg)."):format(#parts > 0 and table.concat(parts, ", ") or "empty",
                    contentsG / 1000, self.cfg.crate.contentsKg)
            end
        end
    end
    if node then
        local summary = self.P.containers.summary(node.id)
        if type(summary) == "table" and summary.charges then
            lines[#lines + 1] = ("%s: %d / %d left."):format(node.cfg.label, summary.charges, summary.maxCharges or summary.charges)
        end
    end
    self:tell(ctx.playerId, #lines > 0 and table.concat(lines, " ") or "No crate of yours here yet.", "info")
    return { inspected = true }
end

function S:duty(ctx)
    if not fromActions() then return nil, "not_owner" end
    local on = ctx.actionId == "clock_in"
    local ok, why = self.P.jobs.setDuty(ctx.playerId, on, { job = self.cfg.job })
    if not ok then return nil, why or "not_eligible" end
    self:tell(ctx.playerId, on and "On duty at the yard. Pick a wreck." or "Off duty. See you, choom.", "success")
    return { duty = on }
end

-- ---------------------------------------------------------------------------------------------
-- Trucks
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
        local d = pos and self.M.distance(pos, origin)
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
    if not self.ready then return false, "salvage_unavailable" end
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

-- End of the pickup clip. Custody does not move (A13 6.1): the crate stays in its hold.
function S:cratePickup(ctx)
    if not fromActions() then return nil, "not_owner" end
    local crate = self:crateOf(ctx)
    if not crate or crate.state ~= "ground" then return nil, "crate_unavailable" end
    local snap, why = self.L.read(crate.id)
    if type(snap) ~= "table" then return nil, why == "unknown_account" and "crate_unavailable" or (why or "salvage_unavailable") end
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
    if bay == "sell" then return self:sell(ctx, crate) end
    if bay == "load" or dest.kind == "vehicle" then return self:load(ctx, crate, dest, bay) end
    -- On the ground (G) or on a point: custody unchanged, the placement becomes durable.
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

-- Death, disconnect, a vehicle, combat, a job change, an in-doubt put-down...: the item lies at
-- the carrier's feet. Custody did not move unless a load or a sale was in doubt: verify.
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
            -- Closed: sold and retired already.
            self:unplaceItem(crate)
            self:forget(crate)
        else
            crate.needsReconcile = true
        end
        return
    end
    crate.needsReconcile = nil
    if not crate.dirty and self.M.isOurs(snap.meta) then crate.meta = snap.meta end
    if crate.meta.sale and crate.state ~= "sold" then
        local outcome = self:settleSale(crate)
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
-- Load: the token leaves the hold for the bed (rp_cargo, rp_garage decides who may)
-- ---------------------------------------------------------------------------------------------
function S:load(ctx, crate, dest, bay)
    local pid = ctx.playerId
    local vid = dest.kind == "vehicle" and dest.vehicleId or nil
    if not vid then
        local origin = bay == "load" and self.cfg.bays.load.position or (self.P.players.position(pid) or crate.meta.at)
        local radius = bay == "load" and self.cfg.bays.load.truckRadius or self.cfg.truckNearM
        local why
        vid, why = self:truckNear(pid, origin, radius, "put")
        if not vid then return nil, why end
    end
    local opId = self.opIds[ctx.opId] or self.L.newOpId("load")
    self.opIds[ctx.opId] = opId
    local granted, gwhy = self.L.authorize(opId, "rp_cargo", { crate.id }, 60000)
    if not granted then return nil, gwhy or "salvage_not_configured" end
    local res, why = self.P.cargo.load(pid, vid, crate.iid, {
        opId = opId, from = crate.id, item = "salvage_crate", model = self.cfg.crate.model,
    })
    if not res then
        if why == "busy" then why = "in_doubt" end
        return nil, why
    end
    self.stats.loads = self.stats.loads + 1
    crate.state, crate.carrier, crate.plate = "truck", nil, res.plate
    if crate.itemId then self.byItem[crate.itemId] = nil end
    crate.itemId = nil                              -- the put-down removes the carried item
    crate.meta.where = "veh:" .. tostring(res.plate) .. ":cargo"
    self:persistMeta(crate)                         -- a hint only; the coordinator is the truth
    local text = ("Crate loaded on %s, slot %s."):format(tostring(res.plate), tostring(res.slot))
    self:record(crate.meta.owner, { kind = "load", opId = opId, text = text })
    self:tell(pid, text, "success")
    self:log("crate %s loaded on %s slot %s layer %s by player %d (op %s%s)", crate.id, tostring(res.plate),
        tostring(res.slot), tostring(res.layer), pid, opId, res.replay and ", replay" or "")
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
            if object.item == "salvage_crate" and hold then pick = { iid = object.instance, hold = hold } end
        end
    end
    if not pick then return nil, "no_salvage_crate" end
    local crate = self.crates[pick.hold]
    if not crate then
        local snap = self.L.read(pick.hold)
        if type(snap) ~= "table" or not self.M.isOurs(snap.meta) then return nil, "unknown_crate" end
        crate = self:adopt(pick.hold, snap.meta, "truck")
    end
    local opId = (key and self.opIds[key]) or self.L.newOpId("unload")
    if key then self.opIds[key] = opId end
    local granted, gwhy = self.L.authorize(opId, "rp_cargo", { crate.id }, 60000)
    if not granted then return nil, gwhy or "salvage_not_configured" end
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

function S:unloadAction(ctx)
    if not fromActions() then return nil, "not_owner" end
    if not self.P.actions.verify(ctx.opId, "commit") then return nil, "not_owner" end
    local bay = self.cfg.bays.unload
    local crate, itemOrWhy = self:unloadCrate(ctx.playerId, nil, bay.position, bay.truckRadius, ctx.opId)
    if not crate then return nil, itemOrWhy end
    return { crate = crate.id, item = itemOrWhy }
end

-- ---------------------------------------------------------------------------------------------
-- Sale: one rp_economy:sale (materials out of the hold + seller cash + society share), with a
-- quote persisted in the hold's record BEFORE paying, so a crash at any point either finds the
-- sale committed (and retires the crate) or retries it under a fresh attempt id.
-- ---------------------------------------------------------------------------------------------
function S:saleSpec(crate, quote)
    local items = {}
    for _, it in ipairs(quote.items) do items[#items + 1] = { item = it.item, count = it.count, from = crate.id } end
    local payees = { { subject = quote.by, amount = quote.seller } }
    if quote.society > 0 then payees[#payees + 1] = { society = self.cfg.society, amount = quote.society } end
    return {
        opId = quote.opId, seller = { subject = quote.by }, items = items, buyer = { sys = "dealer" },
        total = quote.total, payees = payees, reason = "salvage crate",
    }
end

-- committed | pending | failed | aborted | none
function S:settleSale(crate)
    local quote = crate.meta.sale
    if not quote then return "none" end
    local outcome = self.L.settle(quote.opId)
    if outcome == "committed" then
        self:log("sale %s of %s found committed: retiring the crate", quote.opId, crate.id)
        self:retire(crate, true)
    elseif outcome == "failed" or outcome == "aborted" then
        -- Never paid (and, once fenced, never can be): the next sale starts a fresh attempt.
        crate.saleChecked = quote.opId
    end
    return outcome
end

function S:sell(ctx, crate)
    local pid = ctx.playerId
    local cfg = self.cfg
    local subject, swhy = self.L.subjectOf(pid)
    if not subject then return nil, swhy end
    local pos = self.P.players.position(pid)
    if not pos or (self.M.planar(pos, cfg.buyer.counter) or 99) > 4.0 then return nil, "too_far" end
    local snap, rwhy = self.L.read(crate.id)
    if type(snap) ~= "table" then return nil, rwhy == "unknown_account" and "already_sold" or rwhy end
    if not self.M.tokenHere(snap, crate.iid) then return nil, "crate_unavailable" end

    local quote = crate.meta.sale
    local mine = quote and self.opIds[ctx.opId] == quote.opId
    if quote and not mine then
        -- An earlier attempt (another put-down, a drop, a restart): what became of it?
        local outcome = self.L.settle(quote.opId)
        if outcome == "committed" then
            self:retire(crate, false)
            return { placement = { kind = "remove" }, sale = { opId = quote.opId, total = quote.total, replay = true } }
        end
        if outcome == "pending" then return nil, "in_doubt" end
        quote = nil                                -- failed or fenced: a fresh attempt
    end
    if not quote then
        local q, qwhy = self.M.quote(snap.items, cfg.prices, cfg.saleOrder, cfg.societyShare)
        if not q then return nil, qwhy end
        local attempt = (crate.meta.sale and crate.meta.sale.attempt or 0) + 1
        q.attempt, q.by = attempt, subject
        q.opId = ("slv.sale:%s.a%d"):format(crate.key, attempt)
        local previous = crate.meta.sale
        crate.meta.sale = q
        local ok, mwhy = self:persistMeta(crate)
        if not ok then
            crate.meta.sale = previous
            crate.dirty = nil
            return nil, mwhy or "store_unavailable"
        end
        quote = q
        self.opIds[ctx.opId] = q.opId
    end
    local granted, gwhy = self.L.authorize(quote.opId, "rp_economy", { crate.id }, 60000)
    if not granted then return nil, gwhy or "salvage_not_configured" end
    local receipt, why = self.P.economy.sale(self:saleSpec(crate, quote))
    if not receipt then return nil, why end
    self.stats.sales = self.stats.sales + 1
    local text = ("Sold to %s: %d eddies (%d to you, %d to the %s society)."):format(cfg.buyer.name, quote.total,
        quote.seller, quote.society, cfg.society)
    self:record(subject, { kind = "sale", opId = quote.opId, text = text, replay = receipt.replay == true })
    self:log("sale %s of crate %s by %s: total=%d seller=%d society=%d%s", quote.opId, crate.id, subject, quote.total,
        quote.seller, quote.society, receipt.replay and " (replay)" or "")
    self:tell(pid, text, "success")
    self:retire(crate, false)
    return { placement = { kind = "remove" }, sale = { opId = quote.opId, total = quote.total, replay = receipt.replay == true } }
end

-- The sold crate's token goes back to its source and the empty hold is closed. Idempotent by
-- state: a token already gone (`instance_unavailable`) means an earlier retire landed.
-- `unplace`: also remove the ground item (recovery); a sale's own put-down removes it itself.
function S:retire(crate, unplace)
    crate.state = "sold"
    if unplace then self:unplaceItem(crate) elseif crate.itemId then
        self.byItem[crate.itemId] = nil
        crate.itemId = nil
    end
    local snap, rwhy = self.L.read(crate.id)
    if type(snap) ~= "table" then
        if rwhy == "unknown_account" then          -- closed by an earlier retire
            crate.retirePending = nil
            self:forget(crate)
            return true
        end
        crate.retirePending = true
        return false
    end
    if self.M.tokenHere(snap, crate.iid) then
        local r, why = self.L.transfer({
            opId = self.L.newOpId("retire"), kind = "salvage.retire", reason = "crate sold",
            lines = { { instance = crate.iid, from = crate.id, to = self.cfg.accounts.retired } },
        })
        if not r and why ~= "instance_unavailable" and why ~= "insufficient_items" then
            crate.retirePending = true
            return false
        end
    end
    local ok, why = self.L.close(crate.id)
    if ok or why == "unknown_account" then
        crate.retirePending = nil
        self.stats.retired = self.stats.retired + 1
        self:forget(crate)
        return true
    end
    if why == "container_not_empty" then
        -- Unpriced leftovers: the crate stays sold and listed (salvage.lab.state) for an operator.
        self:warn("sold crate %s keeps unpriced contents: not closed", crate.id)
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
    local counts = { ground = 0, truck = 0, sold = 0, orphan = 0, new = 0 }
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
    self:log("crates rebuilt from the coordinator: %d (ground %d, in a bed %d, sold %d, new %d, orphans closed %d)",
        seen, counts.ground, counts.truck, counts.sold, counts.new, counts.orphan)
    return seen
end

function S:classify(crate, counts)
    local snap = self.L.read(crate.id)
    if type(snap) ~= "table" then
        crate.needsReconcile = true
        return
    end
    if crate.meta.sale then
        local outcome = self:settleSale(crate)
        if outcome == "committed" then counts.sold = counts.sold + 1 return end
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
    for _, r in pairs(self.doubts) do
        if not self.done[r.txOpId] then self:settleWork(r) end
    end
    for ref, nodeId in pairs(self.pendingConsume) do self:consumeNode(nodeId, ref) end
    self:retryMissingNodes()
    local list = {}
    for _, crate in pairs(self.crates) do list[#list + 1] = crate end
    for _, crate in ipairs(list) do
        if crate.needsReconcile then
            self:reconcileCrate(crate)
        elseif crate.retirePending then
            self:retire(crate, true)
        elseif crate.meta.sale and crate.state ~= "sold" and crate.state ~= "carried"
            and crate.saleChecked ~= crate.meta.sale.opId then
            self:settleSale(crate)
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
    -- Settled works are remembered ten minutes (a late retry of the same commit hook), not forever.
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
    local pid = op.playerId
    if op.state == "presenting" and op.actionId == "pry" then
        self:attachHandProp(op.opId, pid)
    end
    if not TERMINAL[op.state] then return end
    self:detachHandProp(op.opId)
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

function S:attachHandProp(opId, pid)
    local spec = self.cfg.actions.pry.handProp
    if not spec or self.handProps[opId] then return end
    local pos = self.P.players.position(pid)
    if not pos then return end
    for _, model in ipairs(spec.models) do
        local propId = self.P.props.create({ model = model, position = { x = pos.x, y = pos.y, z = pos.z },
            bucket = pos.bucket or 0 })
        if propId then
            local ok, why = self.P.props.attach(propId, { parentType = "player", parentId = pid, bone = spec.bone,
                offset = spec.offset, rotation = spec.rotation })
            if ok then
                self.handProps[opId] = propId
                return
            end
            self.P.props.remove(propId)
            self:log("hand prop %s not attached: %s", model, tostring(why))
            return
        end
    end
end

function S:detachHandProp(opId)
    local propId = self.handProps[opId]
    if propId then
        self.handProps[opId] = nil
        self.P.props.remove(propId)
    end
end

function S:spawnBuyer()
    local npc = self.cfg.buyer.npc
    if not npc or self.npcId then return end
    local def = { position = self.cfg.buyer.position, yaw = self.cfg.buyer.yaw, bucket = self.cfg.bucket,
        damagePolicy = npc.damagePolicy }
    if npc.record then def.record = npc.record else def.template = npc.template end
    local ok, id, why = pcall(self.P.npcs.create, def)
    if ok and id then
        self.npcId = id
    else
        self:log("buyer NPC not spawned (%s): the counter works without it", tostring(ok and why or id))
    end
end

function S:shutdown()
    for opId in pairs(self.handProps) do self:detachHandProp(opId) end
    if self.npcId then pcall(self.P.npcs.remove, self.npcId) end
    self.npcId = nil
end

return SalvageService
