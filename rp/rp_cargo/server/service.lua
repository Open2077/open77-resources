-- rp_cargo/server/service.lua: the cargo service (row A9 of the world-interaction plan).
--
-- Custody lives in the A13 coordinator (open77_transactions), never here:
--   * the cargo of a vehicle is the container account "veh:<plate>:<part>" (plate = durable key);
--   * every object that takes a slot is an item INSTANCE in that account, and its slot is the
--     instance metadata `meta.cargo = { slot, layer, model }`, written by the same operation that
--     moves the instance in (a metaPatch on the move line) and cleared by the one that moves it out
--     (`metaPatch = { cargo = false }`: the coordinator merges one level and deletes nothing, so
--     the key stays as `false`, which reads as "no slot"; other metadata keys are kept);
--   * what players see is a PROJECTION: one prop per instance, created by this resource and
--     attached to the vehicle's current runtime id (Open77.props.attach, parentType "vehicle", root
--     binding). It is rebuilt from the coordinator whenever the vehicle (re)appears, changes bucket,
--     loses a prop, or someone else commits to its cargo. A visual failure after a commit is
--     retried by the projection; it never re-runs the economic operation.
-- Authorization is rp_garage's canAccess(playerId, plate, part, action); an open tailgate in the
-- world is not authorization.
--
-- Pure Lua: every native and export arrives through `deps` (server/main.lua wires them). Calls
-- through deps.tx may yield; run load/unload/reconcile inside a managed coroutine.
-- Global: RpCargoService.

RpCargoService = {}
local Svc = {}
Svc.__index = Svc
local L = RpCargoLayout

local function toPlayerId(value)
    local n = tonumber(value)
    if not n or n < 1 or n % 1 ~= 0 then return nil end
    return math.tointeger(n) or n
end

local function validOpId(id)
    return type(id) == "string" and #id >= 8 and #id <= 96 and id:match("^[A-Za-z0-9_.:@%-]+$") ~= nil
end

local function validInstance(id)
    return type(id) == "string" and #id >= 4 and #id <= 64 and id:match("^[A-Za-z0-9_.:%-]+$") ~= nil
end

local function accountOf(plate, part)
    return ("veh:%s:%s"):format(plate, part)
end
RpCargoService.accountOf = accountOf

-- deps = {
--   config   = Config (reach, maxVehicleSpeed, lockTimeoutMs, models, ...)
--   registry = RpCargoLayout registry (mutable: the lab tunes it)
--   tx(name, ...)                         -> coordinator export result(s); may yield
--   subjectOf(playerId)                   -> durable subject key | nil, reason
--   mayWrite(account, opId, playerId)     -> true | nil, reason, info: this resource may write the
--                                            account in that operation (the coordinator's writers,
--                                            or a one-operation pocket grant); optional
--   garage = { plateOf(vehicleId), describe(plate), canAccess(playerId, plate, part, action) }
--   vehicles = { get(id), all() }
--   players  = { position(playerId) }
--   props    = { create(def), attach(id, binding), remove(id), getAttachment(id),
--                setAttachmentTransform(id, offset, rotation) }
--   wait(ms), now() (seconds), log(fmt, ...), emit(name, ...), spawn(fn)
-- }
function RpCargoService.new(deps)
    return setmetatable({
        deps = deps,
        cfg = deps.config,
        registry = deps.registry,
        projections = {},   -- plate -> { vehicleId, record, props = { [instance] = { propId, slot, rank, model } } }
        propIndex = {},     -- tostring(propId) -> { plate, instance }
        locks = {},         -- plate -> true while an operation or a projection runs
        pending = {},       -- plate -> { [opId] = { instance, slot, layer, kind, at } } outcomes in doubt
        ownOps = {},        -- opId -> true: our commits (their committed events need no reconcile)
        lab = {},           -- tostring(vehicleId) -> { layout, props = { { propId, slot, layer } } }
        counter = 0,
        stats = { loads = 0, unloads = 0, refusals = 0, projections = 0, propFailures = 0 },
    }, Svc)
end

function Svc:log(fmt, ...)
    self.deps.log(fmt, ...)
end

function Svc:refuse(reason, info)
    self.stats.refusals = self.stats.refusals + 1
    return nil, reason, info
end

function Svc:newOpId(kind)
    local id = self.deps.tx("newOpId")
    if validOpId(id) then return id end
    self.counter = self.counter + 1
    return ("rp_cargo.%s:%d:%d"):format(kind, math.floor(self.deps.now()), self.counter)
end

-- Vehicle id -> { id, car, plate, layout, account } | nil, reason.
function Svc:resolve(vehicleId)
    local id = toPlayerId(vehicleId)   -- same integer rule as a player id
    if not id then return nil, "invalid_vehicle_id" end
    local car = self.deps.vehicles.get(id)
    if not car then return nil, "vehicle_not_found" end
    local plate, why = self.deps.garage.plateOf(id)
    if not plate then return nil, (why == "garage_unavailable") and why or "vehicle_not_tracked" end
    local layout = L.find(self.registry, car.record)
    if not layout then return nil, "no_cargo_layout" end
    return { id = id, car = car, plate = plate, layout = layout, account = accountOf(plate, layout.part) }
end

-- The player stands by the vehicle, in its bucket, and the vehicle is not moving.
function Svc:near(playerId, car)
    local p = self.deps.players.position(playerId)
    if not p then return nil, "player_not_found" end
    if (p.bucket or 0) ~= (car.bucket or 0) then return nil, "wrong_bucket" end
    local dx, dy, dz = p.x - car.x, p.y - car.y, p.z - car.z
    if math.sqrt(dx * dx + dy * dy + dz * dz) > self.cfg.reach then return nil, "too_far" end
    if (tonumber(car.speed) or 0) > self.cfg.maxVehicleSpeed then return nil, "vehicle_moving" end
    return true
end

-- One operation (or projection) per plate at a time: two players loading the same truck are
-- served in turn, each against the cargo the previous one left.
function Svc:withPlate(plate, fn)
    local waited = 0
    while self.locks[plate] do
        if waited >= self.cfg.lockTimeoutMs then return nil, "busy", { retryable = true } end
        self.deps.wait(50)
        waited = waited + 50
    end
    self.locks[plate] = true
    local results = table.pack(pcall(fn))
    self.locks[plate] = nil
    if not results[1] then
        self:log("internal error on plate %s: %s", plate, tostring(results[2]))
        return nil, "internal_error"
    end
    return table.unpack(results, 2, results.n)
end

-- The coordinator's snapshot of a cargo account. Its read loads on demand and never creates (a
-- never-opened account answers unknown_account). `create`: open it (capacity from the layout)
-- then; otherwise an unknown account reads as empty, and nothing is created by looking.
function Svc:read(account, layout, create)
    local snap, why, info = self.deps.tx("read", account)
    if snap then return snap end
    if why == "unknown_account" and create then
        snap, why, info = self.deps.tx("open", account, { capacityG = math.floor(layout.capacityKg * 1000 + 0.5) })
        if snap then return snap end
    end
    if why == "unknown_account" then return { id = account, version = 0, instances = {}, empty = true } end
    return nil, why or "coordinator_unavailable", info
end

-- Instances of a snapshot that take a slot: those carrying meta.cargo, plus instances of an item
-- with a configured model (moved in by another resource without a slot; drawn in a free slot).
function Svc:occupants(snap)
    local list = {}
    for iid, inst in pairs(snap.instances or {}) do
        local c = type(inst.meta) == "table" and type(inst.meta.cargo) == "table" and inst.meta.cargo or nil
        local model = (c and c.model) or self.cfg.models[inst.item or ""]
        if c or model then
            list[#list + 1] = {
                instance = iid, item = inst.item, model = model, version = inst.version,
                slot = c and tonumber(c.slot) or nil, layer = c and tonumber(c.layer) or nil,
            }
        end
    end
    table.sort(list, function(a, b) return a.instance < b.instance end)
    return list
end

-- Outcomes in doubt keep their slot claimed until the coordinator settles them (status with
-- resolve fences an opId it does not know). Never dropped on a timer.
function Svc:resolvePending(plate)
    local list = self.pending[plate]
    if not list then return end
    for opId in pairs(list) do
        local st = self.deps.tx("status", opId, { resolve = true })
        local state = type(st) == "table" and st.state or nil
        if state and state ~= "in_doubt" and state ~= "committing" and state ~= "reserved" then
            list[opId] = nil
            self:log("operation %s on plate %s settled: %s", opId, plate, state)
        end
    end
    if next(list) == nil then self.pending[plate] = nil end
end

function Svc:claimsOf(plate, occupants)
    local all = {}
    for _, o in ipairs(occupants) do all[#all + 1] = o end
    for opId, p in pairs(self.pending[plate] or {}) do
        if p.kind == "load" then all[#all + 1] = { instance = "pending:" .. opId, slot = p.slot, layer = p.layer } end
    end
    return all
end

-- ---------------------------------------------------------------------------------------------
-- Projection
-- ---------------------------------------------------------------------------------------------

function Svc:propBound(propId, vehicleId)
    local b = self.deps.props.getAttachment(propId)
    return type(b) == "table" and b.parentType == "vehicle" and tostring(b.parentId) == tostring(vehicleId)
end

function Svc:dropProp(propId)
    if propId == nil then return end
    self.propIndex[tostring(propId)] = nil
    self.deps.props.remove(propId)
end

function Svc:spawnProp(plate, instance, vehicleId, car, model, place)
    local propId, why = self.deps.props.create({
        model = model,
        position = { x = car.x, y = car.y, z = car.z + 1.0 },
        bucket = car.bucket or 0,
        yaw = car.yaw or 0.0,
    })
    if not propId then
        self.stats.propFailures = self.stats.propFailures + 1
        self:log("prop %s for %s on plate %s refused: %s", tostring(model), instance, plate, tostring(why))
        return nil
    end
    local ok, err = self.deps.props.attach(propId, {
        parentType = "vehicle", parentId = vehicleId, bone = "",
        offset = place.offset, rotation = place.rotation,
    })
    if not ok then
        self.stats.propFailures = self.stats.propFailures + 1
        self:log("attach of %s to vehicle %s (plate %s, slot %d) refused: %s", instance, tostring(vehicleId), plate, place.slot, tostring(err))
        self.deps.props.remove(propId)
        return nil
    end
    self.propIndex[tostring(propId)] = { plate = plate, instance = instance }
    return { propId = propId, slot = place.slot, rank = place.rank, model = model }
end

function Svc:clear(plate, reason)
    local proj = self.projections[plate]
    if not proj then return end
    local n = 0
    for _, cur in pairs(proj.props) do
        self:dropProp(cur.propId)
        n = n + 1
    end
    self.projections[plate] = nil
    if n > 0 then self:log("plate %s: %d cargo prop(s) removed (%s)", plate, n, tostring(reason)) end
end

-- Draws the coordinator's cargo on the vehicle. Caller holds the plate lock.
function Svc:projectLocked(plate, vehicleId, layout, snap)
    local car = vehicleId and self.deps.vehicles.get(vehicleId)
    if not car then
        self:clear(plate, "vehicle_gone")
        return true
    end
    if not snap then
        local s, why = self:read(accountOf(plate, layout.part), layout, false)
        if not s then
            -- Keep what is drawn: a coordinator outage must not empty a loaded truck on screen.
            self:log("projection of plate %s skipped: %s", plate, tostring(why))
            return nil, why
        end
        snap = s
    end
    local occupants = self:occupants(snap)
    local models = {}
    for _, o in ipairs(occupants) do models[o.instance] = o.model end
    local placements, hidden = L.placements(layout, occupants, self.cfg.stackHeights, self.cfg.seats)
    local proj = self.projections[plate]
    if proj and tostring(proj.vehicleId) ~= tostring(vehicleId) then
        self:clear(plate, "rebind")
        proj = nil
    end
    proj = proj or { vehicleId = vehicleId, record = car.record, props = {} }
    self.projections[plate] = proj
    for instance, place in pairs(placements) do
        local cur = proj.props[instance]
        if cur and self:propBound(cur.propId, vehicleId) then
            if cur.slot ~= place.slot or cur.rank ~= place.rank then
                local ok = self.deps.props.setAttachmentTransform(cur.propId, place.offset, place.rotation)
                if ok then
                    cur.slot, cur.rank = place.slot, place.rank
                else
                    self:dropProp(cur.propId)
                    proj.props[instance] = self:spawnProp(plate, instance, vehicleId, car, models[instance] or layout.model, place)
                end
            end
        else
            if cur then self:dropProp(cur.propId) end
            proj.props[instance] = self:spawnProp(plate, instance, vehicleId, car, models[instance] or layout.model, place)
        end
    end
    for instance, cur in pairs(proj.props) do
        if not placements[instance] then
            self:dropProp(cur.propId)
            proj.props[instance] = nil
        end
    end
    if #hidden > 0 then
        self:log("plate %s: %d object(s) do not fit the %s layout and are not drawn: %s", plate, #hidden, layout.record, table.concat(hidden, ","))
    end
    self.stats.projections = self.stats.projections + 1
    return true
end

-- Rebuilds the projection of a plate from the garage's current vehicle and the coordinator.
function Svc:reconcile(plate, reason)
    return self:withPlate(plate, function()
        self:resolvePending(plate)
        local desc = self.deps.garage.describe(plate)
        local vehicleId = type(desc) == "table" and desc.vehicleId or nil
        if not vehicleId then
            self:clear(plate, reason or "not_in_world")
            return true
        end
        local car = self.deps.vehicles.get(vehicleId)
        local layout = car and L.find(self.registry, car.record)
        if not layout then
            self:clear(plate, car and "no_layout" or "vehicle_gone")
            return true
        end
        return self:projectLocked(plate, vehicleId, layout)
    end)
end

-- Cheap check without the coordinator: every prop still bound to the current vehicle id.
function Svc:verify(plate)
    local proj = self.projections[plate]
    if not proj then return true end
    if not self.deps.vehicles.get(proj.vehicleId) then return self:reconcile(plate, "vehicle_gone") end
    for _, cur in pairs(proj.props) do
        if not self:propBound(cur.propId, proj.vehicleId) then return self:reconcile(plate, "detached") end
    end
    return true
end

-- Every tracked vehicle in the world with a layout and no (or a stale) projection is projected;
-- every projection is verified. Run at start and by the sweep.
function Svc:scan()
    local seen = {}
    for _, car in ipairs(self.deps.vehicles.all() or {}) do
        local plate = self.deps.garage.plateOf(car.id)
        if plate and L.find(self.registry, car.record) then
            seen[plate] = true
            local proj = self.projections[plate]
            if not proj or tostring(proj.vehicleId) ~= tostring(car.id) or self.pending[plate] then
                -- (a plate with an operation in doubt is settled and redrawn)
                self:reconcile(plate, "scan")
            else
                self:verify(plate)
            end
        end
    end
    local stale = {}
    for plate in pairs(self.projections) do
        if not seen[plate] then stale[#stale + 1] = plate end
    end
    for _, plate in ipairs(stale) do self:reconcile(plate, "scan") end
end

-- ---------------------------------------------------------------------------------------------
-- Operations
-- ---------------------------------------------------------------------------------------------

-- Common checks of load / unload / contents. Returns ctx | nil, reason.
function Svc:prepare(playerId, vehicleId, action, physical)
    local pid = toPlayerId(playerId)
    if not pid then return nil, "invalid_player_id" end
    local v, why = self:resolve(vehicleId)
    if not v then return nil, why end
    local subject, subjectWhy = self.deps.subjectOf(pid)
    if not subject then return nil, subjectWhy or "player_not_found" end
    if physical then
        local ok, reason = self:near(pid, v.car)
        if not ok then return nil, reason end
    end
    local allowed, role = self.deps.garage.canAccess(pid, v.plate, v.layout.part, action)
    if not allowed then return nil, role or "no_access" end
    v.playerId, v.subject, v.role = pid, subject, role
    return v
end

local function checkAccountArg(value, subject)
    if value == "char:" .. subject then return true end
    return type(value) == "string" and value:match("^world:[A-Za-z0-9_.:@%-]+$") ~= nil and #value <= 96
end

-- load(playerId, vehicleId, instanceId, opts) -> result | nil, reason, info
--   opts.from  : source account, default "char:<subject>" (or a "world:<id>" container)
--   opts.opId  : caller's business operation id (idempotent retries); minted when absent
--   opts.slot  : a specific slot id; opts.model: the prop alias drawn (default: config.models[item]
--                or the layout's model); opts.item: item id, only to pick the model
--   result = { opId, plate, account, slot, layer, propId?, replay, already? }
function Svc:load(playerId, vehicleId, instanceId, opts)
    opts = type(opts) == "table" and opts or {}
    if not validInstance(instanceId) then return self:refuse("invalid_instance") end
    if opts.opId ~= nil and not validOpId(opts.opId) then return self:refuse("invalid_op_id") end
    local v, why = self:prepare(playerId, vehicleId, "put", true)
    if not v then return self:refuse(why) end
    local from = opts.from or ("char:" .. v.subject)
    if not checkAccountArg(from, v.subject) then return self:refuse("invalid_source") end
    return self:withPlate(v.plate, function()
        self:resolvePending(v.plate)
        local opId = opts.opId or self:newOpId("load")
        for attempt = 1, 2 do
            local snap, err, info = self:read(v.account, v.layout, true)
            if not snap then return self:refuse(err, info) end
            local occupants = self:occupants(snap)
            for _, o in ipairs(occupants) do
                if o.instance == instanceId then
                    -- Already in this cargo (a retried intent): same answer, nothing moves.
                    self:projectLocked(v.plate, v.id, v.layout, snap)
                    local cur = self.projections[v.plate] and self.projections[v.plate].props[instanceId]
                    return { opId = opId, plate = v.plate, account = v.account, slot = o.slot, layer = o.layer,
                             propId = cur and cur.propId or nil, replay = true, already = true }
                end
            end
            local claims = self:claimsOf(v.plate, occupants)
            if #claims >= v.layout.objects then return self:refuse("cargo_full") end
            local slot, layer = L.allocate(v.layout, claims, opts.slot)
            if not slot then return self:refuse(layer) end
            local model = opts.model or self.cfg.models[opts.item or ""] or v.layout.model
            if self.deps.mayWrite then
                local may, mayWhy, mayInfo = self.deps.mayWrite(from, opId, v.playerId)
                if not may then return self:refuse(mayWhy, mayInfo) end
            end
            -- Marked before the call: the committed event can arrive before the export's answer.
            self.ownOps[opId] = true
            local receipt, reason, rinfo = self.deps.tx("transfer", {
                opId = opId, kind = "cargo.load", actor = v.subject,
                lines = { { instance = instanceId, from = from, to = v.account,
                            metaPatch = { cargo = { slot = slot, layer = layer, model = model } } } },
                expect = { [v.account] = snap.version },
            })
            if receipt then
                if receipt.replay then self.ownOps[opId] = nil end
                self.stats.loads = self.stats.loads + 1
                self:projectLocked(v.plate, v.id, v.layout)
                local cur = self.projections[v.plate] and self.projections[v.plate].props[instanceId]
                self:log("player %d loaded %s into %s slot %d layer %d (op %s%s)", v.playerId, instanceId, v.plate, slot, layer, opId,
                    receipt.replay and ", replay" or "")
                self.deps.emit("rp_cargo:changed", v.plate, "loaded", instanceId, slot, layer)
                return { opId = opId, plate = v.plate, account = v.account, slot = slot, layer = layer,
                         propId = cur and cur.propId or nil, replay = receipt.replay == true }
            end
            if reason == "in_doubt" or reason == "busy" then
                self.pending[v.plate] = self.pending[v.plate] or {}
                self.pending[v.plate][opId] = { instance = instanceId, slot = slot, layer = layer, kind = "load", at = self.deps.now() }
                self:log("load of %s into %s in doubt (op %s): slot %d stays claimed", instanceId, v.plate, opId, slot)
                return self:refuse(reason, rinfo)
            end
            self.ownOps[opId] = nil
            if not ((reason == "stale_version" or reason == "conflict") and attempt == 1) then
                return self:refuse(reason, rinfo)
            end
            -- Somebody else changed this cargo since the read: re-read and re-plan once.
        end
        return self:refuse("conflict", { retryable = true })
    end)
end

-- The object an unload takes when none is named: the top of the last occupied slot in layout
-- order (the tailgate end in the shipped layouts).
local function topOf(layout, occupants)
    local placements = L.placements(layout, occupants)   -- slots and ranks only: no heights needed
    local best, bestKey
    for _, o in ipairs(occupants) do
        local p = placements[o.instance]
        if p then
            local index = 0
            for i, s in ipairs(layout.slots) do if s.id == p.slot then index = i end end
            local key = index * 100 + p.rank
            if not bestKey or key > bestKey then best, bestKey = o, key end
        end
    end
    return best
end

-- unload(playerId, vehicleId, instanceId?, opts) -> result | nil, reason, info
--   opts.to: destination account, default "char:<subject>" (or a "world:<id>" container)
--   result = { opId, plate, account, instance, to, slot, layer, replay }
function Svc:unload(playerId, vehicleId, instanceId, opts)
    opts = type(opts) == "table" and opts or {}
    if instanceId ~= nil and not validInstance(instanceId) then return self:refuse("invalid_instance") end
    if opts.opId ~= nil and not validOpId(opts.opId) then return self:refuse("invalid_op_id") end
    local v, why = self:prepare(playerId, vehicleId, "take", true)
    if not v then return self:refuse(why) end
    local to = opts.to or ("char:" .. v.subject)
    if not checkAccountArg(to, v.subject) then return self:refuse("invalid_destination") end
    return self:withPlate(v.plate, function()
        self:resolvePending(v.plate)
        local opId = opts.opId or self:newOpId("unload")
        for attempt = 1, 2 do
            local snap, err, info = self:read(v.account, v.layout, false)
            if not snap then return self:refuse(err, info) end
            local occupants = self:occupants(snap)
            local target
            if instanceId then
                for _, o in ipairs(occupants) do
                    if o.instance == instanceId then target = o end
                end
                if not target then return self:refuse("not_in_cargo") end
            else
                target = topOf(v.layout, occupants)
                if not target then return self:refuse("cargo_empty") end
            end
            if self.deps.mayWrite then
                local may, mayWhy, mayInfo = self.deps.mayWrite(to, opId, v.playerId)
                if not may then return self:refuse(mayWhy, mayInfo) end
            end
            self.ownOps[opId] = true
            local receipt, reason, rinfo = self.deps.tx("transfer", {
                opId = opId, kind = "cargo.unload", actor = v.subject,
                lines = { { instance = target.instance, from = v.account, to = to, metaPatch = { cargo = false } } },
                expect = { [v.account] = snap.version },
            })
            if receipt then
                if receipt.replay then self.ownOps[opId] = nil end
                self.stats.unloads = self.stats.unloads + 1
                self:projectLocked(v.plate, v.id, v.layout)
                self:log("player %d unloaded %s from %s slot %s (op %s%s)", v.playerId, target.instance, v.plate, tostring(target.slot), opId,
                    receipt.replay and ", replay" or "")
                self.deps.emit("rp_cargo:changed", v.plate, "unloaded", target.instance, target.slot, target.layer)
                return { opId = opId, plate = v.plate, account = v.account, instance = target.instance, to = to,
                         slot = target.slot, layer = target.layer, replay = receipt.replay == true }
            end
            if reason ~= "in_doubt" and reason ~= "busy" then self.ownOps[opId] = nil end
            if not ((reason == "stale_version" or reason == "conflict") and attempt == 1) then
                return self:refuse(reason, rinfo)
            end
        end
        return self:refuse("conflict", { retryable = true })
    end)
end

-- contents(playerId, vehicleId) -> { plate, account, record, measured, capacityKg, slots = {
--   { slot, maxStack, objects = { { instance, item, rank } } } }, free, objects } | nil, reason
-- (needs `view`; no reach check: a UI may show it from the driver seat).
function Svc:contents(playerId, vehicleId)
    local v, why = self:prepare(playerId, vehicleId, "view", false)
    if not v then return self:refuse(why) end
    local snap, err = self:read(v.account, v.layout, false)
    if not snap then return self:refuse(err) end
    return self:describe(v.plate, v.account, v.layout, snap)
end

function Svc:describe(plate, account, layout, snap)
    local occupants = self:occupants(snap)
    local placements = L.placements(layout, occupants, self.cfg.stackHeights, self.cfg.seats)
    local slots, used = {}, 0
    for _, s in ipairs(layout.slots) do
        slots[#slots + 1] = { slot = s.id, maxStack = s.maxStack, measured = s.measured, objects = {} }
    end
    for _, o in ipairs(occupants) do
        local p = placements[o.instance]
        if p then
            used = used + 1
            for _, entry in ipairs(slots) do
                if entry.slot == p.slot then
                    entry.objects[#entry.objects + 1] = { instance = o.instance, item = o.item, rank = p.rank }
                end
            end
        end
    end
    for _, entry in ipairs(slots) do
        table.sort(entry.objects, function(a, b) return a.rank < b.rank end)
    end
    return {
        plate = plate, account = account, record = layout.record, measured = layout.measured,
        capacityKg = layout.capacityKg, slots = slots, objects = used, free = layout.objects - used,
        version = snap.version,
    }
end

-- ---------------------------------------------------------------------------------------------
-- Events from the garage, the props and the coordinator
-- ---------------------------------------------------------------------------------------------

function Svc:onSpawned(plate)
    return self:reconcile(plate, "spawned")
end

function Svc:onDespawned(plate)
    return self:withPlate(plate, function()
        self:clear(plate, "despawned")
        return true
    end)
end

-- A prop of ours lost its binding (vehicle removed or moved to another bucket: the platform
-- detaches children then). Our own removals left the index first, so they never come back here.
function Svc:onAttachmentChanged(propId, current)
    local ref = self.propIndex[tostring(propId)]
    if not ref or current ~= nil then return nil end
    return ref.plate
end

-- Another resource committed to a cargo account we draw: the projection follows.
function Svc:onCommitted(opId, accounts)
    if self.ownOps[opId] then
        self.ownOps[opId] = nil
        return {}
    end
    local plates = {}
    for _, account in ipairs(type(accounts) == "table" and accounts or {}) do
        local plate = type(account) == "string" and account:match("^veh:(.+):[a-z]+$")
        if plate and self.projections[plate] then plates[#plates + 1] = plate end
    end
    return plates
end

-- ---------------------------------------------------------------------------------------------
-- Lab (console only): measure layouts on any vehicle with a layout, tracked or not
-- ---------------------------------------------------------------------------------------------

function Svc:labTarget(vehicleId)
    local id = toPlayerId(vehicleId)
    if not id then return nil, "invalid_vehicle_id" end
    local car = self.deps.vehicles.get(id)
    if not car then return nil, "vehicle_not_found" end
    local layout = L.find(self.registry, car.record)
    if not layout then return nil, "no_cargo_layout:" .. tostring(car.record) end
    return id, car, layout
end

function Svc:labClear(vehicleId)
    local key = tostring(vehicleId)
    local entry = self.lab[key]
    if not entry then return 0 end
    for _, p in ipairs(entry.props) do self.deps.props.remove(p.propId) end
    self.lab[key] = nil
    return #entry.props
end

-- A crate at every slot (layers 1..`layers`, capped by each slot's maxStack). Returns count | nil, reason.
function Svc:labSpawn(vehicleId, layers, model)
    local id, car, layout = self:labTarget(vehicleId)
    if not id then return nil, car end
    self:labClear(id)
    local entry = { layout = layout, props = {} }
    self.lab[tostring(id)] = entry
    for _, s in ipairs(layout.slots) do
        for layer = 1, math.min(layers or 1, s.maxStack) do
            local offset, rotation = L.offset(layout, s.id, layer)
            local propId, why = self.deps.props.create({
                model = model or layout.model, position = { x = car.x, y = car.y, z = car.z + 1.0 },
                bucket = car.bucket or 0, yaw = car.yaw or 0.0,
            })
            if not propId then return nil, "create_refused:" .. tostring(why) end
            local ok, err = self.deps.props.attach(propId, { parentType = "vehicle", parentId = id, bone = "", offset = offset, rotation = rotation })
            if not ok then
                self.deps.props.remove(propId)
                return nil, "attach_refused:" .. tostring(err)
            end
            entry.props[#entry.props + 1] = { propId = propId, slot = s.id, layer = layer }
        end
    end
    return #entry.props
end

-- Moves one slot of the vehicle's layout (every vehicle of that record follows) and re-places
-- the lab crates and the cargo already drawn. Returns the slot | nil, reason.
function Svc:labTune(vehicleId, slotId, x, y, z, yaw, stackHeight)
    local id, car, layout = self:labTarget(vehicleId)
    if not id then return nil, car end
    local ok, why = L.tune(layout, slotId, x, y, z, yaw)
    if not ok then return nil, why end
    local slot = layout.slotById[tonumber(slotId)]
    if stackHeight ~= nil then
        if type(stackHeight) ~= "number" or stackHeight <= 0 or stackHeight > L.LIMITS.stackHeight then return nil, "invalid_stack_height" end
        slot.stackHeight = stackHeight
    end
    for _, entry in pairs(self.lab) do
        if entry.layout == layout then
            for _, p in ipairs(entry.props) do
                if p.slot == slot.id then
                    local offset, rotation = L.offset(layout, p.slot, p.layer)
                    self.deps.props.setAttachmentTransform(p.propId, offset, rotation)
                end
            end
        end
    end
    for plate, proj in pairs(self.projections) do
        if L.find(self.registry, proj.record) == layout then
            for _, cur in pairs(proj.props) do
                if cur.slot == slot.id then
                    local offset, rotation = L.offset(layout, cur.slot, cur.rank)
                    self.deps.props.setAttachmentTransform(cur.propId, offset, rotation)
                end
            end
            self:log("lab tune re-placed slot %d of plate %s", slot.id, plate)
        end
    end
    return slot
end

function Svc:labLayout(vehicleId)
    local id, car, layout = self:labTarget(vehicleId)
    if not id then return nil, car end
    return L.toJson(layout)
end

return RpCargoService
