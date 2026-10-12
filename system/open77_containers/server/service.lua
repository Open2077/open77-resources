-- =============================================================================
-- open77_containers -- server/service.lua
-- =============================================================================
-- Durable world containers (world-interaction row A6). A container is:
--
--   identity   a `world:` world container the A13 coordinator MINTS
--              (`open77_transactions` `openWorld`, contract §7.2). The id is the
--              ONLY durable key: it survives restart, reprojection and
--              re-placement. Prop ids are projections. A caller that needs to
--              find its container again names it with a `key` of its own.
--   coordinator  the source of truth for what it holds: contents, capacity,
--              expiry and, in the world row's metadata, the placement (model,
--              position, yaw, bucket) plus owner, kind and key. A restart pages
--              `listWorld` and re-projects from it.
--   registry   one row per container in this resource's own store for what the
--              coordinator does NOT hold: policy, presentation, public/private
--              metadata, node charges, grants and, once closed, the tombstone.
--   projection a server prop (or, for `model = false`, a point), its state-bag
--              summary and an interaction prompt. Rebuilt at boot and whenever
--              the prop is lost; never trusted back.
--
-- Authority. The coordinator owns value; this service owns `world:` policy:
-- which resource may take from, put into, target, deplete, move, re-label or
-- close which container (owner + grants), and whether the acting player is in
-- reach and in the container's bucket. Value movement on `world:` accounts goes
-- through this service's reserve/commit/transfer pass-through, which checks
-- those rights -- and, through the coordinator's own `allowed` export, the
-- real caller's right to every other account the operation touches -- before
-- forwarding (see a6-containers.md §4). State bags are written, never read for
-- a decision: any `state.write` resource can overwrite a prop's bag (A0 matrix
-- §8 fact 4), so the bag is a presentation mirror repaired when it drifts.
--
-- Continuation style throughout: `cb(result | nil, reason, info)`, possibly
-- synchronous. Dependencies are injected so the offline suites drive the real
-- logic over the real A13 coordinator and a memory store.
--
-- Global: Open77ContainersService.
-- =============================================================================

Open77ContainersService = {}
local Model = Open77ContainersModel
local S = {}
S.__index = S

local BAG_KEY = "open77.container"
local PROMPT_EVENT = "open77_containers:prompt"
local MAX_DECLARED_TARGETS = 32
local MAX_PROPS_PER_TARGET = 128
local DRAIN_LINES = 40
local USE_RATE_PER_SECOND = 4
local LIST_PAGE = 200
local CLOSE_RETRY_MS = 10000

-- Reasons a caller may retry (the A13 convention: `info.retryable`).
local RETRYABLE = {
    coordinator_unavailable = true, store_unavailable = true, busy = true, in_doubt = true, conflict = true,
    not_ready = true, mint_cap_exceeded = true,
}

local function noop() end

local function fnv32(text)
    local hash = 2166136261
    for index = 1, #text do
        hash = hash ~ text:byte(index)
        hash = (hash * 16777619) & 0xffffffff
    end
    return string.format("%08x", hash)
end

local function fail(cb, reason, info)
    info = info or {}
    if info.retryable == nil then info.retryable = RETRYABLE[reason] == true end
    if cb then cb(nil, reason, info) end
    return nil, reason, info
end

local function distance(a, b)
    local x, y, z = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(x * x + y * y + z * z)
end

local function keyIndex(owner, key) return tostring(owner) .. "/" .. tostring(key) end

function Open77ContainersService.new(deps)
    assert(type(deps) == "table" and deps.store and deps.tx and deps.props, "store, tx and props required")
    local self = setmetatable({
        store = deps.store,
        tx = deps.tx,
        props = deps.props,
        bags = deps.bags,
        interactions = deps.interactions,
        players = deps.players,
        -- The coordinator's `allowed(resource, target, asset?)` (A13 §7.2): may
        -- the real caller write this account, or mint this asset from this
        -- `sys:` account. Synchronous; true, or false plus the refusal.
        allowed = deps.allowed or function() return false, "coordinator_unavailable" end,
        -- The coordinator's `subjectOf(playerId)`: fills a forwarded op's
        -- `actor` (journal attribution) when the caller named a player only.
        subjectOf = deps.subjectOf,
        emit = deps.emit or noop,
        -- Runs a function in its own task (runtime: CreateThread), so a boot join
        -- reached from a store callback can still yield between batches.
        spawn = deps.spawn or function(fn) fn() end,
        nowMs = deps.nowMs or function() return 0 end,
        log = deps.log or noop,
        self = deps.resourceName or "open77_containers",
        rows = {},            -- [id] = container (registry half joined to the coordinator half)
        queues = {},          -- [id] = pending writes (one in flight per container)
        projection = {},      -- [id] = { propId?, bagSig?, failedAt?, lost? }
        propIndex = {},       -- [propId] = id
        zoneIndex = {},       -- [zone target id] = id
        contents = {},        -- [id] = { empty?, weightG } from the last coordinator read or listing
        carry = {},           -- [id] = { player?, binding } (runtime only)
        expiring = {},        -- [id] = true while a drain is in flight
        ops = {},             -- [opId] = { caller, accounts, state }
        keys = {},            -- [owner/key] = id of an open keyed container
        creating = {},        -- [owner/key] = true while a keyed create is in flight
        orphans = {},         -- [owner/key] = coordinator half of a keyed world row with no registry row
        pendingClose = {},    -- [id] = { nextAt, attempts } world rows to delete after their tombstone
        ownMeta = {},         -- [id] = { [encoded meta] = n } own setMeta calls whose event is due
        promptsDirty = true,
        promptSignature = nil,
        useBudget = {},       -- [playerId] = { windowStart, count }
        stats = { tamperRepairs = 0, projectionFailures = 0, reprojections = 0, adopted = 0, orphansClosed = 0,
            missingAccounts = 0, externalChanges = 0 },
        ready = false,
        starting = false,
    }, S)
    return self
end

-- ---------------------------------------------------------------------------
-- Writes: one in flight per container. A registry write is a compare-and-set
-- on the row version; a placement write replaces the coordinator metadata. The
-- mirror changes only after the store acknowledged.
-- ---------------------------------------------------------------------------
function S:_drain(id)
    local queue = self.queues[id]
    if not queue or queue.busy then return end
    local job = table.remove(queue, 1)
    if not job then
        self.queues[id] = nil
        return
    end
    queue.busy = true
    local function finish(...)
        queue.busy = false
        job.cb(...)
        self:_drain(id)
    end
    local current = self.rows[id]
    if not current then return finish(nil, "unknown_container") end
    job.run(current, finish)
end

function S:_enqueue(id, run, cb)
    local queue = self.queues[id]
    if not queue then
        queue = { busy = false }
        self.queues[id] = queue
    end
    queue[#queue + 1] = { run = run, cb = cb or noop }
    self:_drain(id)
end

-- mutate(copy) -> true (write), false (no write needed), or nil, reason.
function S:_persist(id, mutate, cb)
    self:_enqueue(id, function(current, finish)
        local copy = Model.deepCopy(current)
        local verdict, reason, info = mutate(copy)
        if verdict == nil then return finish(nil, reason, info) end
        if verdict == false then return finish(current, nil, info) end -- nothing to write
        local expect = current.version
        copy.version = expect + 1
        copy.updatedAt = self.nowMs()
        self.store:update(Model.registryRecord(copy), expect, function(ok, err)
            if ok then
                self.rows[id] = copy
                return finish(copy, nil, info)
            end
            if err == "conflict" then
                -- Somebody else moved the row (another server on the database):
                -- reload the registry half and let the caller re-plan.
                self.store:get(id, function(record)
                    local live = self.rows[id]
                    if type(record) == "table" and live then self.rows[id] = Model.join(record, live) end
                    finish(nil, "conflict")
                end)
                return
            end
            finish(nil, "store_unavailable", { detail = err })
        end)
    end, cb)
end

-- Own coordinator metadata writes, so their `open77_transactions:world` echo
-- is not mistaken for somebody else's change.
function S:_expectMeta(id, meta)
    local ok, encoded = pcall(Model.encode, meta)
    if not ok then return nil end
    local own = self.ownMeta[id] or {}
    self.ownMeta[id] = own
    own[encoded] = (own[encoded] or 0) + 1
    return encoded
end

function S:_forgetMeta(id, encoded)
    local own = encoded and self.ownMeta[id]
    if not own or not own[encoded] then return false end
    own[encoded] = own[encoded] - 1
    if own[encoded] <= 0 then own[encoded] = nil end
    if next(own) == nil then self.ownMeta[id] = nil end
    return true
end

-- Moves the projection to a container's new placement (rows[id] already holds it).
function S:_applyPlacement(id, before, after)
    local projection = self.projection[id]
    if projection and (before.bucket ~= after.bucket or before.model ~= after.model) then
        self:_unproject(id)
        self:_project(id)
    elseif projection and projection.propId and not self.carry[id] then
        self.props.setTransform(projection.propId, { position = after.position, yaw = after.yaw })
        self:_writeBag(id)
    end
    self.promptsDirty = true
    self.emit("open77_containers:placed", id, Model.deepCopy(after.position), after.bucket)
end

-- apply(copy) sets the new placement; true, false (unchanged) or nil, reason.
-- The placement is the coordinator's (metadata of the world row): one setMeta.
function S:_persistPlacement(id, apply, cb)
    self:_enqueue(id, function(current, finish)
        local copy = Model.deepCopy(current)
        local verdict, reason = apply(copy)
        if verdict == nil then return finish(nil, reason) end
        if verdict == false or Model.samePlacement(copy, current) then
            -- Nothing durable changes, but a dropped prop must still be put
            -- back where the container stands.
            self:_applyPlacement(id, current, current)
            return finish(current)
        end
        local meta = Model.coordinatorMeta(copy)
        local signature = self:_expectMeta(id, meta)
        self.tx.setMeta(id, meta, function(snapshot, why, info)
            if not snapshot then
                -- An unknown outcome may still echo later: it then reads as an
                -- outside change to this very placement, and is followed.
                self:_forgetMeta(id, signature)
                return finish(nil, why or "coordinator_unavailable", info)
            end
            self.rows[id] = copy
            self:_applyPlacement(id, current, copy)
            finish(copy)
        end)
    end, cb)
end

-- ---------------------------------------------------------------------------
-- Summary and projection
-- ---------------------------------------------------------------------------
function S:summary(id)
    local row = self.rows[id]
    if not row then return nil, "unknown_container" end
    local summary = Model.summary(row, self.contents[id], self.nowMs())
    summary.carried = self.carry[id] ~= nil
    local projection = self.projection[id]
    summary.propId = projection and projection.propId or nil
    return summary
end

function S:_writeBag(id)
    local projection = self.projection[id]
    if not projection or not projection.propId or not self.bags then return end
    local summary = self:summary(id)
    local signature = Model.encode(summary)
    local ok, why = self.bags.set(projection.propId, BAG_KEY, summary)
    if ok then
        projection.bagSig = signature
    else
        self.log("warn", ("bag write refused for %s: %s"):format(id, tostring(why)))
    end
end

-- The bag is a mirror. A drifted mirror (another resource wrote the key) is
-- rewritten from the server summary; its contents are never read for a decision.
function S:_verifyBag(id)
    local projection = self.projection[id]
    if not projection or not projection.propId or not self.bags or not self.bags.get then return end
    local current = self.bags.get(projection.propId, BAG_KEY)
    local ok, encoded = pcall(Model.encode, current)
    if not ok or encoded ~= projection.bagSig then
        self.stats.tamperRepairs = self.stats.tamperRepairs + 1
        self.log("warn", ("container %s: bag drifted from the server summary; rewritten"):format(id))
        self:_writeBag(id)
    end
end

function S:_applyTargetGrants(id)
    local row, projection = self.rows[id], self.projection[id]
    if not row or not projection or not projection.propId or not self.interactions then return end
    local now = self.nowMs()
    for grantee, grant in pairs(row.grants or {}) do
        if Model.grantLive(grant, now) then
            for _, right in ipairs(grant.rights) do
                if right == "target" then
                    local options = grant.expiresAt and { ttlMs = math.max(1000, grant.expiresAt - now) } or nil
                    local ok, why = self.interactions.grantProp(projection.propId, grantee, options)
                    if not ok then
                        self.log("warn", ("target grant for %s on %s refused: %s"):format(grantee, id, tostring(why)))
                    end
                end
            end
        end
    end
end

function S:_project(id)
    local row = self.rows[id]
    if not row or row.state ~= "open" then return end
    local projection = self.projection[id] or {}
    self.projection[id] = projection
    if row.model == false or row.projection == "external" then
        -- A point (zone prompt), or presented by another resource (the carry
        -- helper's own prop): nothing to create here.
        projection.propId = nil
        self.promptsDirty = true
        self.emit("open77_containers:projected", id, nil)
        return
    end
    if projection.propId and self.props.get(projection.propId) then return end
    if projection.propId then self.propIndex[projection.propId] = nil end
    local propId, why = self.props.create({
        model = row.model, position = row.position, yaw = row.yaw, bucket = row.bucket,
        streamingRadius = row.streamingRadius,
    })
    if not propId then
        projection.propId, projection.failedAt = nil, self.nowMs()
        self.stats.projectionFailures = self.stats.projectionFailures + 1
        self.log("warn", ("container %s: prop %s refused: %s"):format(id, tostring(row.model), tostring(why)))
        return
    end
    projection.propId, projection.failedAt, projection.lost = propId, nil, nil
    self.propIndex[propId] = id
    self:_writeBag(id)
    self:_applyTargetGrants(id)
    self.promptsDirty = true
    self.emit("open77_containers:projected", id, propId)
end

function S:_unproject(id)
    local projection = self.projection[id]
    if not projection then return end
    self.projection[id] = nil
    self.carry[id] = nil
    if projection.propId then
        self.propIndex[projection.propId] = nil
        local ok, why = self.props.remove(projection.propId)
        if not ok and why ~= "not_found" then
            self.log("warn", ("container %s: prop %s not removed: %s"):format(id, projection.propId, tostring(why)))
        end
    end
    self.promptsDirty = true
end

-- Re-reads a container's contents from the coordinator, then the summary and
-- the bag follow; an emptied despawn-when-empty container closes.
function S:refreshContents(id, cb)
    cb = cb or noop
    local row = self.rows[id]
    if not row or not Model.hasAccount(row) then return cb(nil, "no_contents") end
    self.tx.read(id, function(snapshot, why)
        if not snapshot then return cb(nil, why or "coordinator_unavailable") end
        local row2 = self.rows[id]
        if not row2 or row2.state ~= "open" then return cb(nil, "container_closed") end
        local contents = Model.contentsOf(snapshot)
        self.contents[id] = contents
        self:_writeBag(id)
        self.emit("open77_containers:changed", id, self:summary(id))
        if contents.empty and row2.despawnWhenEmpty and not self.expiring[id] then
            return self:_finalizeClose(id, "emptied", function() cb(contents) end)
        end
        cb(contents)
    end)
end

-- ---------------------------------------------------------------------------
-- Prompts: grouped server prop targets (interest-limited by the client:
-- nearest first, a few matches each), plus one zone per point container.
-- ---------------------------------------------------------------------------
function S:_promptVisible(id, row)
    if row.state ~= "open" or not row.prompt or self.expiring[id] or self.carry[id] then return false end
    if row.expiresAt and self.nowMs() >= row.expiresAt then return false end
    if row.node then return not Model.nodeState(row.node, self.nowMs()).depleted end
    return true
end

function S:rebuildPrompts()
    if not self.interactions then return end
    self.promptsDirty = false
    local groups, groupOrder, zones = {}, {}, {}
    local ids = {}
    for id in pairs(self.rows) do ids[#ids + 1] = id end
    table.sort(ids)
    self.zoneIndex = {}
    for _, id in ipairs(ids) do
        local row = self.rows[id]
        if self:_promptVisible(id, row) then
            local projection = self.projection[id]
            if row.model == false then
                zones[#zones + 1] = id
            elseif projection and projection.propId then
                local signature = Model.encode(row.prompt)
                local group = groups[signature]
                if not group then
                    group = { prompt = row.prompt, props = {}, signature = signature }
                    groups[signature] = group
                    groupOrder[#groupOrder + 1] = signature
                end
                group.props[#group.props + 1] = projection.propId
            end
        end
    end
    table.sort(groupOrder)
    local list, dropped = {}, 0
    local function base(prompt)
        return {
            label = prompt.label, key = prompt.key, holdSeconds = prompt.holdSeconds,
            distance = prompt.distance, markerDistance = prompt.markerDistance, marker = prompt.marker,
            choiceId = prompt.choiceId, event = PROMPT_EVENT, maxMatches = 4,
        }
    end
    for _, signature in ipairs(groupOrder) do
        local group = groups[signature]
        local index = 1
        while index <= #group.props do
            if #list >= MAX_DECLARED_TARGETS then
                dropped = dropped + (#group.props - index + 1)
                break
            end
            local slice = {}
            for offset = index, math.min(#group.props, index + MAX_PROPS_PER_TARGET - 1) do
                slice[#slice + 1] = group.props[offset]
            end
            local definition = base(group.prompt)
            definition.id = "p_" .. fnv32(signature) .. "_" .. tostring(index)
            definition.kind = "prop"
            definition.props = slice
            list[#list + 1] = definition
            index = index + MAX_PROPS_PER_TARGET
        end
    end
    for _, id in ipairs(zones) do
        if #list >= MAX_DECLARED_TARGETS then
            dropped = dropped + 1
        else
            local row = self.rows[id]
            local definition = base(row.prompt)
            definition.id = "z_" .. fnv32(id)
            definition.kind = "zone"
            definition.zone = { shape = "sphere", position = row.position,
                radius = math.max(row.prompt.distance, 1.0), maxHeight = 4.0 }
            definition.position = row.position
            definition.maxMatches = nil
            list[#list + 1] = definition
            self.zoneIndex[definition.id] = id
        end
    end
    if dropped > 0 then
        self.log("warn", ("%d container prompts not declared: the 32-target declaration budget is full"):format(dropped))
    end
    local signature = Model.encode(list)
    if signature == self.promptSignature then return end
    self.promptSignature = signature
    if #list == 0 then
        self.interactions.clear()
    else
        local ok, why = self.interactions.define(list)
        if not ok then
            self.promptSignature = nil
            self.log("warn", "container prompts refused by open77_interactions: " .. tostring(why))
        end
    end
end

-- A player pressed a container prompt. Everything the client sent is a claim:
-- the container comes from the prop or zone id, the distance and bucket from
-- the server's own player snapshot. Returns true or nil, reason (for tests).
function S:use(playerId, targetId, propId, choiceId)
    if math.type(playerId) ~= "integer" or playerId < 1 then return nil, "invalid_player" end
    local now = self.nowMs()
    local budget = self.useBudget[playerId]
    if not budget or now - budget.windowStart >= 1000 then
        budget = { windowStart = now, count = 0 }
        self.useBudget[playerId] = budget
    end
    budget.count = budget.count + 1
    if budget.count > USE_RATE_PER_SECOND then return nil, "rate_limited" end
    local id = (type(propId) == "string" and self.propIndex[propId]) or
        (type(targetId) == "string" and self.zoneIndex[targetId]) or nil
    if not id then return nil, "unknown_container" end
    local row = self.rows[id]
    if not row or not self:_promptVisible(id, row) then return nil, "not_interactable" end
    if type(choiceId) ~= "string" or choiceId ~= row.prompt.choiceId then return nil, "invalid_choice" end
    local position = self.players and self.players.position(playerId)
    if not position then return nil, "player_unavailable" end
    if (position.bucket or 0) ~= row.bucket then return nil, "wrong_bucket" end
    local gap = distance(position, row.position)
    if gap > row.prompt.distance + Model.LIMITS.reachToleranceM then return nil, "out_of_reach" end
    self.emit("open77_containers:used", id, playerId, choiceId,
        { owner = row.owner, kind = row.kind, distance = gap, propId = self.projection[id] and self.projection[id].propId })
    return true
end

-- ---------------------------------------------------------------------------
-- Coordinator world rows that must go: the leftover of a close interrupted
-- after its tombstone, or an empty orphan nobody can reach. Retried by the
-- sweep until the coordinator answers.
-- ---------------------------------------------------------------------------
function S:_closeCoordinatorRow(id)
    local entry = self.pendingClose[id] or { attempts = 0 }
    self.pendingClose[id] = entry
    entry.inFlight = true
    self.tx.close(id, function(ok, why)
        entry.inFlight = false
        if ok or why == "unknown_account" then
            self.pendingClose[id] = nil
            return
        end
        if why == "container_not_empty" then
            self.pendingClose[id] = nil
            self.log("warn", ("world row %s still holds something; left for the operator"):format(id))
            return
        end
        entry.attempts = entry.attempts + 1
        entry.nextAt = self.nowMs() + CLOSE_RETRY_MS
        if entry.attempts == 1 then
            self.log("warn", ("world row %s not deleted yet (%s); retrying every %d s")
                :format(id, tostring(why), CLOSE_RETRY_MS // 1000))
        end
    end)
end

-- ---------------------------------------------------------------------------
-- Boot: join the registry to the coordinator's world rows.
--   both                       -> rebuilt and projected
--   coordinator, no registry   -> orphan of a create interrupted after openWorld:
--                                 keyed = adopted by the next create with that key,
--                                 keyless and empty = deleted
--   coordinator, tombstone     -> a close interrupted after its tombstone: deleted
--   registry, no coordinator   -> the world row is gone: tombstoned (`account_missing`)
-- ---------------------------------------------------------------------------
function S:_orphanAtBoot(half, done)
    self.store:get(half.id, function(record)
        if record == nil then return done() end -- registry error: the next boot decides
        if record and record.state ~= "open" then
            self:_closeCoordinatorRow(half.id)
        elseif not record then
            if half.key then
                self.orphans[keyIndex(half.owner, half.key)] = half
            elseif (half.weightG or 0) == 0 then
                self.stats.orphansClosed = self.stats.orphansClosed + 1
                self:_closeCoordinatorRow(half.id)
            else
                self.log("warn", ("orphan world row %s holds %s g and has no registry row; left for the operator")
                    :format(half.id, tostring(half.weightG)))
            end
        end
        done()
    end)
end

function S:_rebuild(registry, listed, yield, cb)
    local seen, present, pending, finished = {}, {}, 1, false
    local live = 0
    local function settle()
        pending = pending - 1
        if pending > 0 or finished then return end
        finished = true
        -- The last lookup may answer from a store callback: project in a task.
        self.spawn(function()
            local ids = {}
            for id in pairs(self.rows) do ids[#ids + 1] = id end
            table.sort(ids)
            for index, id in ipairs(ids) do
                if yield and index % 64 == 0 then yield() end
                self:_project(id)
            end
            self.ready, self.starting = true, false
            self.promptsDirty = true
            self:rebuildPrompts()
            self.emit("open77_containers:ready", live)
            cb(live)
        end)
    end
    for index, listing in ipairs(listed) do
        if yield and index % 64 == 0 then yield() end
        if type(listing) == "table" and type(listing.id) == "string" then present[listing.id] = true end
        local half, why = Model.fromCoordinator(listing)
        if half then
            seen[half.id] = true
            local record = registry[half.id]
            if record then
                if record.owner ~= half.owner or record.kind ~= half.kind or record.key ~= half.key then
                    self.log("warn", ("container %s: registry and coordinator disagree on its identity; left inert")
                        :format(half.id))
                else
                    local row = Model.join(record, half)
                    self.rows[row.id] = row
                    if row.key then self.keys[keyIndex(row.owner, row.key)] = row.id end
                    if Model.hasAccount(row) then self.contents[row.id] = Model.contentsFromWeight(half.weightG) end
                    live = live + 1
                end
            else
                pending = pending + 1
                self:_orphanAtBoot(half, settle)
            end
        elseif why ~= "foreign" then
            self.log("warn", ("world row %s is marked as a container but unusable (%s); ignored")
                :format(tostring(listing.id), tostring(why)))
        end
    end
    for id, record in pairs(registry) do
        if not seen[id] and present[id] then
            -- The world row is there but its metadata is unusable: the placement
            -- is lost, the contents are not. Leave it to an operator.
            self.log("warn", ("container %s: its world row has unusable metadata; left inert"):format(id))
        elseif not seen[id] then
            -- Nothing to project without the coordinator's placement: record the
            -- loss instead of keeping a container that can never come back.
            self.stats.missingAccounts = self.stats.missingAccounts + 1
            self.log("warn", ("container %s: its world row is gone from the coordinator; closed (account_missing)")
                :format(id))
            local closed = Model.deepCopy(record)
            closed.state, closed.closedAt, closed.closeReason = "closed", self.nowMs(), "account_missing"
            closed.version = record.version + 1
            pending = pending + 1
            self.store:update(closed, record.version, function(ok, why)
                if not ok then
                    self.log("warn", ("container %s: tombstone not written: %s"):format(id, tostring(why)))
                end
                settle()
            end)
        end
    end
    settle()
end

-- options.yield (runtime): called between batches so a large rebuild spans
-- several resumes (the 1M-instruction quota per scheduler pass).
function S:start(cb, options)
    cb = cb or noop
    if self.ready then return fail(cb, "already_started") end
    if self.starting then return fail(cb, "busy") end
    self.starting = true
    local yield = options and options.yield
    local function abort(why, info)
        self.starting = false
        fail(cb, why, info)
    end
    self.store:loadOpen(function(records, why)
        if not records then return abort(why or "store_unavailable") end
        local registry = {}
        for _, record in ipairs(records) do registry[record.id] = record end
        local listed, after = {}, ""
        local function page()
            self.tx.listWorld(after, LIST_PAGE, function(rows, listWhy, info)
                if type(rows) ~= "table" then return abort(listWhy or "coordinator_unavailable", info) end
                local count = 0
                for _, listing in ipairs(rows) do
                    count = count + 1
                    listed[#listed + 1] = listing
                    after = listing.id
                end
                if count >= LIST_PAGE then return page() end
                self.spawn(function() self:_rebuild(registry, listed, yield, cb) end)
            end)
        end
        page()
    end)
end

-- ---------------------------------------------------------------------------
-- Create
-- ---------------------------------------------------------------------------
function S:_insert(row, cb, contents)
    local id = row.id
    self.store:insert(Model.registryRecord(row), function(ok, insertWhy)
        if not ok then
            if row.key then
                -- Adoptable by a retry with the same key (this process), and by
                -- the boot join (any later process).
                self.orphans[keyIndex(row.owner, row.key)] = {
                    id = id, owner = row.owner, kind = row.kind, key = row.key, model = row.model,
                    position = Model.deepCopy(row.position), yaw = row.yaw, bucket = row.bucket,
                    capacityG = row.capacityG, expiresAt = row.expiresAt, weightG = 0,
                }
            else
                -- Nobody can reach a keyless orphan: delete it now (the boot join
                -- would otherwise).
                self:_closeCoordinatorRow(id)
            end
            if insertWhy == "exists" then return fail(cb, "already_exists") end
            return fail(cb, "store_unavailable", { detail = insertWhy })
        end
        self.rows[id] = row
        if row.key then
            local index = keyIndex(row.owner, row.key)
            self.keys[index], self.orphans[index] = id, nil
        end
        if Model.hasAccount(row) then self.contents[id] = contents or { empty = true, weightG = 0 } end
        self:_project(id)
        self.emit("open77_containers:created", id, row.owner, row.kind)
        cb(self:summary(id))
    end)
end

local function stamp(self, row)
    local now = self.nowMs()
    row.state, row.version = "open", 1
    row.createdAt, row.updatedAt = now, now
    row.grants = {}
    local ttl = row.ttlMs
    row.ttlMs = nil
    return ttl and (now + ttl) or nil
end

-- The coordinator mints the id; then the registry row; then the projection.
-- A crash between the first two leaves an empty orphan world row: a keyed
-- retry adopts it, the boot join deletes a keyless one.
function S:_createNew(row, cb)
    row.expiresAt = stamp(self, row)
    self.tx.openWorld({ capacityG = row.capacityG, meta = Model.coordinatorMeta(row), expiresAt = row.expiresAt },
        function(snapshot, why, info)
            if not snapshot then return fail(cb, why or "coordinator_unavailable", info) end
            if type(snapshot) ~= "table" or not Model.validId(snapshot.id) then
                return fail(cb, "coordinator_unavailable", { detail = "openWorld returned no world id" })
            end
            row.id = snapshot.id
            self:_insert(row, cb)
        end)
end

function S:_adopt(orphan, row, cb)
    if Model.specSignature(orphan) ~= Model.specSignature(row) then
        return fail(cb, "already_exists", { id = orphan.id })
    end
    stamp(self, row)
    row.id, row.expiresAt = orphan.id, orphan.expiresAt
    self.stats.adopted = self.stats.adopted + 1
    self:_insert(row, cb, Model.contentsFromWeight(orphan.weightG))
end

function S:create(caller, spec, cb)
    cb = cb or noop
    if not self.ready then return fail(cb, "not_ready") end
    if not Model.validResourceName(caller) then return fail(cb, "invalid_owner") end
    if type(spec) == "table" and spec.id ~= nil then
        return fail(cb, "invalid_id", { detail = "world ids are minted by open77_transactions; pass `key`" })
    end
    local row, why = Model.normalizeSpec(spec)
    if not row then return fail(cb, why) end
    row.owner = caller
    if row.key == nil then return self:_createNew(row, cb) end
    local index = keyIndex(caller, row.key)
    local function existing(current)
        if current.state ~= "open" then return fail(cb, "container_closed", { id = current.id }) end
        if Model.specSignature(current) == Model.specSignature(row) then
            return cb(self:summary(current.id), nil, { existing = true })
        end
        return fail(cb, "already_exists", { id = current.id })
    end
    local live = self.keys[index]
    if live and self.rows[live] then return existing(self.rows[live]) end
    if self.creating[index] then return fail(cb, "busy") end
    self.creating[index] = true
    local function done(...)
        self.creating[index] = nil
        cb(...)
    end
    self.store:getByKey(caller, row.key, function(stored, err)
        if stored == nil then return fail(done, "store_unavailable", { detail = err }) end
        if stored then
            if stored.state ~= "open" then return fail(done, "container_closed", { id = stored.id }) end
            -- Open in the registry but not live here (another server on the
            -- database, or left inert at boot).
            return fail(done, "already_exists", { id = stored.id })
        end
        local orphan = self.orphans[index]
        if orphan then return self:_adopt(orphan, row, done) end
        self:_createNew(row, done)
    end)
end

-- ---------------------------------------------------------------------------
-- Reads
-- ---------------------------------------------------------------------------
function S:access(id, resource, right)
    local row = self.rows[id]
    if not row then return false, "unknown_container" end
    if not Model.RIGHT_SET[right] then return false, "invalid_right" end
    if row.state ~= "open" then return false, "container_closed" end
    if Model.hasRight(row, resource, right, self.nowMs()) then
        return true, row.owner == resource and "owner" or "granted"
    end
    return false, "not_authorized"
end

function S:list(filter)
    filter = type(filter) == "table" and filter or {}
    local out = {}
    for id, row in pairs(self.rows) do
        if row.state == "open" and (filter.owner == nil or row.owner == filter.owner) and
            (filter.kind == nil or row.kind == filter.kind) and
            (filter.bucket == nil or row.bucket == filter.bucket) then
            out[#out + 1] = self:summary(id)
        end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

-- The caller's own keyed container (keys are per owner).
function S:findByKey(owner, key)
    if not Model.validKey(key) then return nil, "invalid_key" end
    local id = self.keys[keyIndex(owner, key)]
    if not id or not self.rows[id] then return nil, "unknown_container" end
    return self:summary(id)
end

-- Console helper: a world id, or a key that names exactly one open container.
function S:resolve(text)
    if type(text) ~= "string" then return nil, "unknown_container" end
    if self.rows[text] then return text end
    local found
    for id, row in pairs(self.rows) do
        if row.key == text then
            if found then return nil, "ambiguous_key" end
            found = id
        end
    end
    if found then return found end
    return nil, "unknown_container"
end

-- Full detail: private metadata, grants and contents. Owner or `read` grantee.
function S:get(caller, id, cb)
    cb = cb or noop
    local row = self.rows[id]
    if not row then return fail(cb, "unknown_container") end
    if not Model.hasRight(row, caller, "read", self.nowMs()) then return fail(cb, "not_authorized") end
    local detail = Model.deepCopy(row)
    detail.summary = self:summary(id)
    if not Model.hasAccount(row) then return cb(detail) end
    self.tx.read(id, function(snapshot, why)
        if snapshot then
            detail.items = Model.deepCopy(snapshot.items or {})
            detail.instances = Model.deepCopy(snapshot.instances or {})
            detail.weightG = snapshot.weightG
            self.contents[id] = Model.contentsOf(snapshot)
        else
            detail.contentsError = why or "coordinator_unavailable"
        end
        cb(detail)
    end)
end

function S:projectionOf(id)
    local row = self.rows[id]
    if not row then return nil, "unknown_container" end
    local projection = self.projection[id] or {}
    local zoneTarget
    for targetId, containerId in pairs(self.zoneIndex) do
        if containerId == id then zoneTarget = targetId end
    end
    return {
        id = id, key = row.key, propId = projection.propId, zoneTarget = zoneTarget,
        projection = row.projection or (row.model == false and "point" or "prop"),
        position = Model.deepCopy(row.position), yaw = row.yaw, bucket = row.bucket,
        carried = self.carry[id] ~= nil, model = row.model,
    }
end

-- ---------------------------------------------------------------------------
-- Grants (owner only; grantees cannot re-grant)
-- ---------------------------------------------------------------------------
function S:grant(caller, id, grantee, rights, options, cb)
    cb = cb or noop
    local row = self.rows[id]
    if not row then return fail(cb, "unknown_container") end
    if row.state ~= "open" then return fail(cb, "container_closed") end
    if row.owner ~= caller then return fail(cb, "not_owner") end
    if not Model.validResourceName(grantee) or grantee == caller then return fail(cb, "invalid_grantee") end
    local list, why = Model.normalizeRights(rights)
    if not list then return fail(cb, why) end
    if options ~= nil and type(options) ~= "table" then return fail(cb, "invalid_options") end
    local expiresAt
    if options and options.ttlMs ~= nil then
        local ttl = Model.integer(options.ttlMs)
        if not ttl or ttl < Model.LIMITS.minGrantTtlMs or ttl > Model.LIMITS.maxGrantTtlMs then
            return fail(cb, "invalid_ttl")
        end
        expiresAt = self.nowMs() + ttl
    end
    self:_persist(id, function(copy)
        copy.grants = copy.grants or {}
        local now = self.nowMs()
        for name, grant in pairs(copy.grants) do
            if not Model.grantLive(grant, now) then copy.grants[name] = nil end
        end
        if copy.grants[grantee] == nil then
            local count = 0
            for _ in pairs(copy.grants) do count = count + 1 end
            if count >= Model.LIMITS.maxGrants then return nil, "grant_limit" end
        end
        copy.grants[grantee] = { rights = list, expiresAt = expiresAt, grantedAt = now }
        return true
    end, function(updated, persistWhy, info)
        if not updated then return fail(cb, persistWhy, info) end
        self:_applyTargetGrants(id)
        self.emit("open77_containers:granted", id, grantee, Model.deepCopy(list))
        cb(true)
    end)
end

function S:revoke(caller, id, grantee, cb)
    cb = cb or noop
    local row = self.rows[id]
    if not row then return fail(cb, "unknown_container") end
    if row.owner ~= caller then return fail(cb, "not_owner") end
    if not row.grants or not row.grants[grantee] then return fail(cb, "grant_not_found") end
    self:_persist(id, function(copy)
        if not copy.grants or not copy.grants[grantee] then return nil, "grant_not_found" end
        copy.grants[grantee] = nil
        return true
    end, function(updated, why, info)
        if not updated then return fail(cb, why, info) end
        local projection = self.projection[id]
        if projection and projection.propId and self.interactions then
            self.interactions.revokeProp(projection.propId, grantee)
        end
        self.emit("open77_containers:revoked", id, grantee)
        cb(true)
    end)
end

-- ---------------------------------------------------------------------------
-- Value movement: the authorized pass-through to the A13 coordinator.
-- ---------------------------------------------------------------------------
function S:_playerReach(row, id, player)
    if math.type(player) ~= "integer" or player < 1 then return nil, "player_required" end
    local position = self.players and self.players.position(player)
    if not position then return nil, "player_unavailable" end
    if (position.bucket or 0) ~= row.bucket then return nil, "wrong_bucket" end
    local carried = self.carry[id]
    if carried and carried.player == player then return true end
    local anchor = row.position
    if carried and carried.player then
        local carrier = self.players.position(carried.player)
        if carrier then anchor = carrier end
    end
    if distance(position, anchor) > row.reachM + Model.LIMITS.reachToleranceM then return nil, "out_of_reach" end
    return true
end

-- The asset a line out of a `sys:` account creates, as the coordinator's mint
-- policy names it: an item id, "money", or nil (a capacity envelope, any item).
local function mintAsset(line)
    if line.money ~= nil then return "money" end
    if type(line.item) == "string" then return line.item end
    return nil
end

-- Returns the sorted list of world accounts, or nil, reason, info.
--
-- The coordinator sees THIS resource as the writer of everything it forwards,
-- so the real caller is checked here, against the coordinator's own policy
-- (`allowed`): every non-world account it touches (per-part grants included),
-- and every `sys:` source it mints from (the coordinator never restricts a
-- `sys:` sink, so neither does this).
function S:_authorize(caller, lines, player, checkReach)
    if type(lines) ~= "table" or #lines == 0 then return nil, "invalid_spec" end
    local world, checks, seen = {}, {}, {}
    for _, line in ipairs(lines) do
        if type(line) ~= "table" then return nil, "invalid_spec" end
        for _, field in ipairs({ "from", "to", "at" }) do
            local account = line[field]
            if account ~= nil then
                if type(account) ~= "string" then return nil, "invalid_spec" end
                local ns = account:match("^([a-z]+):")
                if not ns then return nil, "invalid_account", { account = account } end
                if ns == "world" then
                    world[account] = world[account] or {}
                    world[account][field == "from" and "take" or "put"] = true
                elseif ns ~= "sys" or field == "from" then
                    local asset = ns == "sys" and mintAsset(line) or nil
                    local signature = account .. "\0" .. tostring(asset)
                    if not seen[signature] then
                        seen[signature] = true
                        checks[#checks + 1] = { account = account, asset = asset, mint = ns == "sys" }
                    end
                end
            end
        end
    end
    if next(world) == nil then return nil, "not_a_container_operation" end
    local now = self.nowMs()
    local accounts = {}
    for account, rights in pairs(world) do
        local row = self.rows[account]
        if not row then return nil, "unknown_container", { container = account } end
        if row.state ~= "open" or self.expiring[account] then return nil, "container_closed", { container = account } end
        if row.expiresAt and now >= row.expiresAt then return nil, "container_expired", { container = account } end
        if not Model.hasAccount(row) then return nil, "container_has_no_contents", { container = account } end
        for right in pairs(rights) do
            if not Model.hasRight(row, caller, right, now) then
                return nil, "not_authorized", { container = account, right = right }
            end
        end
        if checkReach and row.reachM > 0 then
            local ok, why = self:_playerReach(row, account, player)
            if not ok then return nil, why, { container = account } end
        end
        accounts[#accounts + 1] = account
    end
    for _, check in ipairs(checks) do
        local ok, why = self.allowed(caller, check.account, check.asset)
        if ok ~= true then
            local reason = type(why) == "string" and why or (check.mint and "mint_denied" or "namespace_denied")
            return nil, reason, { account = check.account, asset = check.asset }
        end
    end
    table.sort(accounts)
    return accounts
end

-- A retried operation must replay even when its first run closed the
-- container (the pickup that emptied a pile): before refusing for a gone
-- container, ask the coordinator whether this opId already committed.
local GONE = { unknown_container = true, container_closed = true, container_expired = true }

function S:_refuseOrReplay(opId, why, info, cb, asFailure)
    if not GONE[why] then return fail(cb, why, info) end
    self.tx.status(opId, nil, function(status)
        if type(status) == "table" and status.state == "committed" and status.receipt then
            local receipt = Model.deepCopy(status.receipt)
            receipt.replay = true
            if asFailure then return fail(cb, "already_committed", { opId = opId, receipt = receipt }) end
            return cb(receipt)
        end
        fail(cb, why, info)
    end)
end

function S:_forwardSpec(spec)
    local actor = spec.actor
    if actor == nil and spec.player ~= nil and self.subjectOf then
        local ok, subject = pcall(self.subjectOf, spec.player)
        if ok and type(subject) == "string" then actor = "char:" .. subject end
    end
    return { opId = spec.opId, kind = spec.kind, actor = actor, reason = spec.reason, ttlMs = spec.ttlMs,
        lines = spec.lines, expect = spec.expect }
end

function S:_afterCommit(accounts)
    for _, account in ipairs(accounts or {}) do
        if self.rows[account] then self:refreshContents(account) end
    end
end

-- spec = { opId, kind?, actor?, reason?, ttlMs?, lines, expect?, player? }
function S:reserve(caller, spec, cb)
    cb = cb or noop
    if type(spec) ~= "table" or type(spec.opId) ~= "string" then return fail(cb, "invalid_spec") end
    local known = self.ops[spec.opId]
    if known and known.caller ~= caller then return fail(cb, "not_owner", { opId = spec.opId }) end
    local accounts, why, info = self:_authorize(caller, spec.lines, spec.player, true)
    if not accounts then return self:_refuseOrReplay(spec.opId, why, info, cb, true) end
    self.tx.reserve(self:_forwardSpec(spec), function(result, reason, detail)
        if result then
            self.ops[spec.opId] = { caller = caller, accounts = accounts, state = "reserved", at = self.nowMs() }
        end
        cb(result, reason, detail)
    end)
end

function S:commit(caller, opId, final, cb)
    cb = cb or noop
    if type(opId) ~= "string" then return fail(cb, "invalid_op_id") end
    local op = self.ops[opId]
    if not op then
        -- Not reserved through this VM (or before a restart): only a committed
        -- outcome is reported; anything else is unknown here.
        return self.tx.status(opId, nil, function(status, reason, info)
            if type(status) == "table" and status.state == "committed" and status.receipt then
                local receipt = Model.deepCopy(status.receipt)
                receipt.replay = true
                return cb(receipt)
            end
            if status == nil and RETRYABLE[reason] then return fail(cb, reason, info) end
            fail(cb, "unknown_operation", { opId = opId })
        end)
    end
    if op.caller ~= caller then return fail(cb, "not_owner", { opId = opId }) end
    if final ~= nil then
        if type(final) ~= "table" then return fail(cb, "invalid_spec") end
        local accounts, why, info = self:_authorize(caller, final.lines, nil, false)
        if not accounts then return fail(cb, why, info) end
    end
    self.tx.commit(opId, final, function(receipt, reason, info)
        if receipt then
            -- A retried commit is answered from the coordinator's receipt
            -- (the unknown-op path above), so the record is no longer needed.
            self.ops[opId] = nil
            self:_afterCommit(op.accounts)
        end
        cb(receipt, reason, info)
    end)
end

function S:cancel(caller, opId, reason, cb)
    cb = cb or noop
    local op = self.ops[opId]
    if not op then return fail(cb, "unknown_operation", { opId = opId }) end
    if op.caller ~= caller then return fail(cb, "not_owner", { opId = opId }) end
    self.tx.cancel(opId, reason, function(ok, why, info)
        if ok then self.ops[opId] = nil end
        cb(ok, why, info)
    end)
end

function S:transfer(caller, spec, cb)
    cb = cb or noop
    if type(spec) ~= "table" or type(spec.opId) ~= "string" then return fail(cb, "invalid_spec") end
    local known = self.ops[spec.opId]
    if known and known.caller ~= caller then return fail(cb, "not_owner", { opId = spec.opId }) end
    local accounts, why, info = self:_authorize(caller, spec.lines, spec.player, true)
    if not accounts then return self:_refuseOrReplay(spec.opId, why, info, cb, false) end
    self.ops[spec.opId] = { caller = caller, accounts = accounts, state = "transferring", at = self.nowMs() }
    self.tx.transfer(self:_forwardSpec(spec), function(receipt, reason, detail)
        local op = self.ops[spec.opId]
        if op and op.state == "transferring" then self.ops[spec.opId] = nil end
        if receipt then self:_afterCommit(accounts) end
        cb(receipt, reason, detail)
    end)
end

-- `{ resolve = true }` fences an opId the coordinator does not know (A13
-- §7.2): use it only for an operation that may still be in flight from a
-- previous process, never for one about to be submitted.
function S:status(opId, options, cb)
    if type(opId) ~= "string" then return fail(cb, "invalid_op_id") end
    self.tx.status(opId, type(options) == "table" and { resolve = options.resolve == true } or nil, cb or noop)
end

-- A caller that stops takes its reservations with it (the coordinator only
-- sees this resource as their owner, so it cannot do it on its own).
function S:onResourceStop(name)
    for opId, op in pairs(self.ops) do
        if op.caller == name then
            if op.state == "reserved" then self.tx.cancel(opId, "resource_stopped", noop) end
            self.ops[opId] = nil
        end
    end
end

-- `open77_transactions:committed(opId, kind, accounts)` for every commit,
-- including ones made directly at the coordinator.
function S:onCommitted(opId, kind, accounts)
    if not self.ready or type(accounts) ~= "table" then return end
    for _, account in ipairs(accounts) do
        if type(account) == "string" and self.rows[account] then self:refreshContents(account) end
    end
end

-- `open77_transactions:world(id, change, meta)`. The coordinator is the source
-- of truth for a container's world row: a row closed under us is tombstoned
-- here; a placement changed under us is followed; metadata this resource could
-- not rebuild from at the next boot is restored from memory.
function S:onWorld(id, change, meta)
    if not self.ready or type(id) ~= "string" then return end
    local row = self.rows[id]
    if not row then return end
    if change == "closed" then
        self.stats.externalChanges = self.stats.externalChanges + 1
        self.log("warn", ("container %s: its world row was closed outside open77_containers; closed"):format(id))
        return self:_finalizeClose(id, "account_closed", noop, { accountGone = true })
    end
    if change ~= "meta" then return end
    local ok, encoded = pcall(Model.encode, meta)
    if ok and self:_forgetMeta(id, encoded) then return end -- our own write
    self.stats.externalChanges = self.stats.externalChanges + 1
    local half = Model.fromCoordinator({ id = id, meta = meta, capacityG = row.capacityG })
    if half and half.owner == row.owner and half.kind == row.kind and half.key == row.key then
        self.log("warn", ("container %s: placement changed outside open77_containers; following the coordinator")
            :format(id))
        self:_enqueue(id, function(current, finish)
            local copy = Model.deepCopy(current)
            copy.model, copy.position, copy.yaw, copy.bucket = half.model, half.position, half.yaw, half.bucket
            if Model.samePlacement(copy, current) then return finish(current) end
            self.rows[id] = copy
            self:_applyPlacement(id, current, copy)
            finish(copy)
        end, noop)
        return
    end
    self.log("warn", ("container %s: its world-row metadata was replaced outside open77_containers; restored")
        :format(id))
    self:_enqueue(id, function(current, finish)
        local restored = Model.coordinatorMeta(current)
        local signature = self:_expectMeta(id, restored)
        self.tx.setMeta(id, restored, function(snapshot)
            if not snapshot then self:_forgetMeta(id, signature) end
            finish(current)
        end)
    end, noop)
end

-- ---------------------------------------------------------------------------
-- Nodes: depletion (idempotent by ref) and lazy regrowth
-- ---------------------------------------------------------------------------
function S:consume(caller, id, options, cb)
    cb = cb or noop
    local row = self.rows[id]
    if not row then return fail(cb, "unknown_container") end
    if row.state ~= "open" or self.expiring[id] then return fail(cb, "container_closed") end
    if row.kind ~= "node" or not row.node then return fail(cb, "not_a_node") end
    if not Model.hasRight(row, caller, "consume", self.nowMs()) then return fail(cb, "not_authorized") end
    options = type(options) == "table" and options or {}
    local count = Model.integer(options.count or 1)
    if not count or count < 1 or count > Model.LIMITS.maxCharges then return fail(cb, "invalid_count") end
    local ref = options.ref
    if type(ref) ~= "string" or #ref < 1 or #ref > 96 or not ref:match("^[%w_.:@%-]+$") then
        return fail(cb, "invalid_ref")
    end
    if options.player ~= nil and row.reachM > 0 then
        local ok, why = self:_playerReach(row, id, options.player)
        if not ok then return fail(cb, why) end
    end
    local result
    self:_persist(id, function(copy)
        for _, entry in ipairs(copy.node.refs or {}) do
            if entry.ref == ref then
                result = Model.nodeState(copy.node, self.nowMs())
                result.replay, result.consumed = true, entry.count
                return false
            end
        end
        local state, why = Model.consume(copy.node, count, ref, self.nowMs())
        if not state then return nil, why end
        result = state
        return true
    end, function(updated, why, info)
        if not updated then return fail(cb, why, info) end
        if not result.replay then
            self:_writeBag(id)
            self.emit("open77_containers:changed", id, self:summary(id))
            if result.depleted then
                self.promptsDirty = true
                self.emit("open77_containers:depleted", id)
            end
        end
        cb(result)
    end)
end

-- refill(id, { charges? }) -- owner only (the lab console acts as the owner):
-- an operator or lab reset of a node without closing it, so its id, grants and
-- consume refs survive. Default: full.
function S:refill(caller, id, options, cb)
    cb = cb or noop
    local row = self.rows[id]
    if not row then return fail(cb, "unknown_container") end
    if row.state ~= "open" or self.expiring[id] then return fail(cb, "container_closed") end
    if row.kind ~= "node" or not row.node then return fail(cb, "not_a_node") end
    if row.owner ~= caller then return fail(cb, "not_owner") end
    options = type(options) == "table" and options or {}
    local result
    self:_persist(id, function(copy)
        local state, why = Model.refill(copy.node, options.charges, self.nowMs())
        if not state then return nil, why end
        result = state
        return true
    end, function(updated, why, info)
        if not updated then return fail(cb, why, info) end
        local projection = self.projection[id]
        if projection then projection.charges = result.charges end
        self:_writeBag(id)
        self.promptsDirty = true
        self.emit("open77_containers:changed", id, self:summary(id))
        if result.before == 0 and result.charges > 0 then
            self.emit("open77_containers:regrown", id, result.charges)
        elseif result.before > 0 and result.depleted then
            self.emit("open77_containers:depleted", id)
        end
        cb({ charges = result.charges, maxCharges = result.maxCharges, depleted = result.depleted,
            regrowAt = result.regrowAt })
    end)
end

-- ---------------------------------------------------------------------------
-- Placement and the carry hooks (A5): the durable placement is the
-- coordinator's (world-row metadata); a carry is runtime presentation only,
-- and a lost carrier leaves the crate where the prop came to rest.
-- ---------------------------------------------------------------------------
function S:place(caller, id, placement, cb)
    cb = cb or noop
    local row = self.rows[id]
    if not row then return fail(cb, "unknown_container") end
    if row.state ~= "open" then return fail(cb, "container_closed") end
    if not Model.hasRight(row, caller, "move", self.nowMs()) then return fail(cb, "not_authorized") end
    if type(placement) ~= "table" then return fail(cb, "invalid_placement") end
    local position = Model.vector(placement.position)
    if not position then return fail(cb, "invalid_position") end
    if placement.yaw ~= nil and not Model.finite(placement.yaw) then return fail(cb, "invalid_yaw") end
    local bucket = placement.bucket == nil and row.bucket or Model.integer(placement.bucket)
    if not bucket or bucket < 0 then return fail(cb, "invalid_bucket") end
    self:_persistPlacement(id, function(copy)
        copy.position = position
        if placement.yaw ~= nil then copy.yaw = Model.normalizeYaw(placement.yaw) end
        copy.bucket = bucket
        return true
    end, function(updated, why, info)
        if not updated then return fail(cb, why, info) end
        cb(self:summary(id))
    end)
end

function S:carryStart(caller, id, binding, cb)
    cb = cb or noop
    local row = self.rows[id]
    if not row then return fail(cb, "unknown_container") end
    if row.state ~= "open" then return fail(cb, "container_closed") end
    if not Model.hasRight(row, caller, "move", self.nowMs()) then return fail(cb, "not_authorized") end
    if row.projection == "external" then return fail(cb, "external_projection") end
    local projection = self.projection[id]
    if not projection or not projection.propId then return fail(cb, "not_projected") end
    if type(binding) ~= "table" then return fail(cb, "invalid_binding") end
    local ok, why = self.props.attach(projection.propId, binding)
    if not ok then return fail(cb, why or "attach_refused") end
    local player = binding.parentType == "player" and Model.integer(binding.parentId) or nil
    self.carry[id] = { player = player, binding = Model.deepCopy(binding) }
    self.promptsDirty = true
    self:_writeBag(id)
    cb(true)
end

-- drop(id, placement?) -- detaches and persists where the crate now stands:
-- the given placement, else the carrier's position, else where it was.
function S:drop(caller, id, placement, cb)
    cb = cb or noop
    local row = self.rows[id]
    if not row then return fail(cb, "unknown_container") end
    if not Model.hasRight(row, caller, "move", self.nowMs()) then return fail(cb, "not_authorized") end
    local carried = self.carry[id]
    local projection = self.projection[id]
    if projection and projection.propId then self.props.detach(projection.propId) end
    self.carry[id] = nil
    if placement == nil then
        local position = carried and carried.player and self.players and self.players.position(carried.player)
        placement = { position = position and { x = position.x, y = position.y, z = position.z } or row.position }
    end
    self:place(caller, id, placement, cb)
end

-- A carrier lost by the platform (disconnect, death) leaves the prop where it
-- stopped: adopt that as the durable placement.
function S:_reconcileCarry(id)
    local carried, projection = self.carry[id], self.projection[id]
    if not carried or not projection or not projection.propId then return end
    local record = self.props.get(projection.propId)
    if record and (record.attachment == nil or record.attachment == false) then
        self.carry[id] = nil
        local position = record.position or { x = record.x, y = record.y, z = record.z }
        local row = self.rows[id]
        if row and Model.vector(position) then
            self:place(row.owner, id, { position = position, yaw = record.yaw }, noop)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Metadata
-- ---------------------------------------------------------------------------
function S:setMeta(caller, id, which, value, cb)
    cb = cb or noop
    local row = self.rows[id]
    if not row then return fail(cb, "unknown_container") end
    if row.state ~= "open" then return fail(cb, "container_closed") end
    if not Model.hasRight(row, caller, "meta", self.nowMs()) then return fail(cb, "not_authorized") end
    local limit = which == "public" and Model.LIMITS.maxPublicBytes or Model.LIMITS.maxPrivateBytes
    if which ~= "public" and which ~= "private" then return fail(cb, "invalid_spec") end
    local meta, why = Model.normalizeMeta(value, limit, which)
    if not meta then return fail(cb, why) end
    self:_persist(id, function(copy)
        copy[which] = meta
        return true
    end, function(updated, persistWhy, info)
        if not updated then return fail(cb, persistWhy, info) end
        if which == "public" then
            self:_writeBag(id)
            self.emit("open77_containers:changed", id, self:summary(id))
        end
        cb(true)
    end)
end

-- ---------------------------------------------------------------------------
-- Close: drain (forced or expired) through the coordinator, write the
-- tombstone, despawn, then delete the (empty) coordinator world row. A closed
-- container's key is never reused; its id never comes back.
-- ---------------------------------------------------------------------------
function S:_drainKey(id, version, attempt)
    local key = id:sub(7)
    return "drain:" .. key:sub(1, 40) .. ":" .. fnv32(id) .. ":v" .. tostring(version or 0) .. ":" ..
        tostring(attempt or 1)
end

-- Outcomes that prove an opId can never commit: plan the drain again under a
-- new attempt number. `in_doubt` is NOT one of them -- the same opId is kept
-- until the coordinator's fence settles it, so a drain can never run twice.
-- Anything else (busy, a held line, an outage) fails this pass; the sweep
-- retries.
local DRAIN_REPLAN = { aborted = true, cancelled = true, expired = true, op_id_conflict = true, conflict = true }

-- Moves every stack and instance out to `sink` in journaled coordinator ops.
-- The opId is derived from the account version, so a retry after a lost
-- acknowledgement either replays the same op or plans the remainder (and the
-- coordinator's availability checks make an over-drain impossible anyway).
function S:_drainTo(id, sink, cb, depth)
    depth = depth or 0
    self.drainAttempts = self.drainAttempts or {}
    if depth > 16 then return cb(nil, "drain_incomplete") end
    self.tx.read(id, function(snapshot, why)
        if not snapshot then
            -- No world row left: nothing to drain.
            if why == "unknown_account" then return cb(true, nil, { accountGone = true }) end
            return cb(nil, why or "coordinator_unavailable")
        end
        -- A reservation still holds goods here (made before the container
        -- stopped accepting new ones): wait for it to commit or lapse.
        local held = type(snapshot.held) == "table" and snapshot.held or {}
        if (type(held.items) == "table" and next(held.items) ~= nil) or (held.weightIn or 0) > 0 then
            return cb(nil, "busy")
        end
        local lines = {}
        local items = {}
        for item, count in pairs(snapshot.items or {}) do
            if count and count > 0 then items[#items + 1] = item end
        end
        table.sort(items)
        for _, item in ipairs(items) do
            if #lines < DRAIN_LINES then
                lines[#lines + 1] = { item = item, count = snapshot.items[item], from = id, to = sink }
            end
        end
        local instances = {}
        for iid in pairs(snapshot.instances or {}) do instances[#instances + 1] = iid end
        table.sort(instances)
        for _, iid in ipairs(instances) do
            if #lines < DRAIN_LINES then lines[#lines + 1] = { instance = iid, from = id, to = sink } end
        end
        if #lines == 0 then
            self.drainAttempts[id] = nil
            return cb(true)
        end
        local attemptKey = id .. "@" .. tostring(snapshot.version)
        local attempt = self.drainAttempts[attemptKey] or 1
        self.tx.transfer({ opId = self:_drainKey(id, snapshot.version, attempt), kind = "container_drain",
            lines = lines }, function(receipt, reason)
                if not receipt then
                    if DRAIN_REPLAN[reason] then
                        self.drainAttempts[attemptKey] = attempt + 1
                        return self:_drainTo(id, sink, cb, depth + 1)
                    end
                    return cb(nil, reason)
                end
                self.drainAttempts[attemptKey] = nil
                self:_drainTo(id, sink, cb, depth + 1)
            end)
    end)
end

-- options.accountGone: the world row is already gone (nothing to delete).
function S:_finalizeClose(id, reason, cb, options)
    cb = cb or noop
    self:_persist(id, function(copy)
        if copy.state ~= "open" then return false end
        copy.state, copy.closedAt, copy.closeReason = "closed", self.nowMs(), reason
        return true
    end, function(updated, why, info)
        if not updated then
            self.expiring[id] = nil
            return fail(cb, why, info)
        end
        self:_unproject(id)
        self.expiring[id] = nil
        self.contents[id] = nil
        self.promptsDirty = true
        if updated.key then self.keys[keyIndex(updated.owner, updated.key)] = nil end
        -- A closed row stays in the registry as a tombstone; drop the mirror.
        self.rows[id] = nil
        self.emit("open77_containers:closed", id, reason, updated.owner)
        if not (options and options.accountGone) then self:_closeCoordinatorRow(id) end
        cb(true)
    end)
end

function S:close(caller, id, options, cb)
    cb = cb or noop
    local row = self.rows[id]
    if not row then return fail(cb, "unknown_container") end
    if row.state ~= "open" then return fail(cb, "container_closed") end
    if self.expiring[id] then return fail(cb, "busy") end
    if not Model.hasRight(row, caller, "close", self.nowMs()) then return fail(cb, "not_authorized") end
    options = type(options) == "table" and options or {}
    local reason = options.reason
    if reason == nil then reason = "closed" end
    if not Model.validResourceName(reason) or #reason > 32 then return fail(cb, "invalid_reason") end
    if not Model.hasAccount(row) then return self:_finalizeClose(id, reason, cb) end
    self.tx.read(id, function(snapshot, why)
        if not snapshot then
            if why == "unknown_account" then return self:_finalizeClose(id, reason, cb, { accountGone = true }) end
            return fail(cb, why or "coordinator_unavailable")
        end
        local contents = Model.contentsOf(snapshot)
        if not contents.empty and options.force ~= true then return fail(cb, "not_empty") end
        self.expiring[id] = true
        self.promptsDirty = true
        self:_drainTo(id, "sys:discarded", function(ok, drainWhy, drainInfo)
            if not ok then
                self.expiring[id] = nil
                self.promptsDirty = true
                return fail(cb, drainWhy)
            end
            self:_finalizeClose(id, reason, cb, drainInfo)
        end)
    end)
end

-- ---------------------------------------------------------------------------
-- Maintenance: call once a second.
-- ---------------------------------------------------------------------------
function S:sweep(options)
    if not self.ready then return end
    options = options or {}
    local now = self.nowMs()
    local ids = {}
    for id in pairs(self.rows) do ids[#ids + 1] = id end
    table.sort(ids)
    for index, id in ipairs(ids) do
        -- A Lua resume is capped at 1M instructions: a runtime that can wait
        -- passes `yield`, and a large registry is swept over several resumes.
        if options.yield and index % 128 == 0 then options.yield() end
        local row = self.rows[id]
        if row and row.state == "open" then
            if row.expiresAt and now >= row.expiresAt and not self.expiring[id] then
                self.expiring[id] = true
                self.promptsDirty = true
                local function done(ok, why)
                    if not ok then
                        self.expiring[id] = nil
                        self.log("warn", ("container %s: expiry drain failed (%s); retrying"):format(id, tostring(why)))
                    end
                end
                if Model.hasAccount(row) then
                    self:_drainTo(id, "sys:expired", function(ok, why, info)
                        if not ok then return done(nil, why) end
                        self:_finalizeClose(id, "expired", done, info)
                    end)
                else
                    self:_finalizeClose(id, "expired", done)
                end
            else
                local projection = self.projection[id]
                local backoff = projection and projection.failedAt and now - projection.failedAt < 10000
                local ownProp = row.model ~= false and row.projection ~= "external"
                if ownProp and (not projection or not projection.propId) and not backoff then
                    self.stats.reprojections = self.stats.reprojections + 1
                    self:_project(id)
                elseif projection and projection.propId and projection.lost then
                    self.stats.reprojections = self.stats.reprojections + 1
                    projection.propId = nil
                    self:_project(id)
                end
                self:_reconcileCarry(id)
                if row.node then
                    local state = Model.nodeState(row.node, now)
                    local last = projection and projection.charges
                    if last ~= nil and last ~= state.charges then
                        self:_writeBag(id)
                        if last == 0 and state.charges > 0 then
                            self.promptsDirty = true
                            self.emit("open77_containers:regrown", id, state.charges)
                        end
                    end
                    if projection then projection.charges = state.charges end
                end
                if options.verifyBags then self:_verifyBag(id) end
            end
        end
    end
    local closing = {}
    for id, entry in pairs(self.pendingClose) do
        if not entry.inFlight and now >= (entry.nextAt or 0) then closing[#closing + 1] = id end
    end
    table.sort(closing)
    for _, id in ipairs(closing) do self:_closeCoordinatorRow(id) end
    -- Reservation records outlive nothing: the coordinator expires a
    -- reservation after its TTL (600 s at most), so a record older than that
    -- can only refuse a legitimate commit's ownership check.
    for opId, op in pairs(self.ops) do
        if op.at and now - op.at > 15 * 60 * 1000 then self.ops[opId] = nil end
    end
    if self.promptsDirty then self:rebuildPrompts() end
end

-- open77_interactions keeps prompts and prop grants in memory: when it
-- (re)starts, everything this service declared there is gone. Redeclare.
function S:reapplyInteractions()
    for id in pairs(self.rows) do self:_applyTargetGrants(id) end
    self.promptSignature = nil
    self.promptsDirty = true
    self:rebuildPrompts()
end

-- Platform `onPropRemoved` for one of our props that we did not remove
-- (an admin clear, a quota sweep): the next sweep reprojects it.
function S:onPropRemoved(propId, reason)
    local id = self.propIndex[propId]
    if not id then return end
    self.propIndex[propId] = nil
    local projection = self.projection[id]
    if projection and projection.propId == propId then
        projection.propId = nil
        self.promptsDirty = true
    end
end

return Open77ContainersService
