-- rp_cargo: the cargo service wired to the platform (row A9 of the world-interaction plan).
--
--   exports (yield: call them with Open77.exports.call("rp_cargo", name, ...):await())
--     load(playerId, vehicleId, instanceId, opts)    -> { opId, plate, account, slot, layer, propId, replay } | nil, reason, info
--     unload(playerId, vehicleId, instanceId?, opts) -> { opId, plate, account, instance, to, slot, layer, replay } | nil, reason, info
--     contents(playerId, vehicleId)                  -> { plate, account, slots = {...}, objects, free } | nil, reason
--     reconcile(plate)                               -> true | nil, reason
--   exports (synchronous)
--     layout(record) -> plain copy of the record's layout | nil
--     projection(plate) -> { vehicleId, props = { { instance, propId, slot, rank } } } | nil
--   event rp_cargo:changed(plate, "loaded" | "unloaded", instanceId, slot, layer)
--   console lab: cargospawn, cargotune, cargolayout, cargoclear, cargoinfo (see README.md)
--
-- Nothing here holds custody: the coordinator (open77_transactions) does, in "veh:<plate>:<part>".

local function log(fmt, ...)
    print(("[rp_cargo] " .. fmt):format(...))
end

-- ---------------------------------------------------------------------------------------------
-- The coordinator (A13). An export timeout or a stopped coordinator during a MUTATING call can
-- hide a commit that succeeded: that is `in_doubt`, never a failure (A13 contract, finding 2.6).
-- ---------------------------------------------------------------------------------------------

local TX = "open77_transactions"
local MUTATING = { transfer = true, commit = true, reserve = true }
local AMBIGUOUS = { export_timeout = true, export_resource_stopped = true }

-- Rejections of the export layer itself start with "export_" (the coordinator's own reasons never
-- do): the call did not reach it, or its answer is lost.
local function tx(name, ...)
    local promise, dispatch = Open77.exports.call(TX, name, ...)
    if not promise then return nil, "coordinator_unavailable", { retryable = true, detail = tostring(dispatch) } end
    local r = table.pack(promise:await())
    if r[1] == nil and type(r[2]) == "string" and r[2]:sub(1, 7) == "export_" then
        if AMBIGUOUS[r[2]] and MUTATING[name] then return nil, "in_doubt", { retryable = true, detail = r[2] } end
        return nil, "coordinator_unavailable", { retryable = true, detail = r[2] }
    end
    return table.unpack(r, 1, r.n)
end

-- The durable subject of a player: the coordinator's provider (A13 decision 5; non-yielding, so
-- asked inline). A refusal is passed through, never replaced by the account identifier: that
-- would key a character's cargo moves by the wrong pockets.
local function subjectOf(playerId)
    local ok, s, why = pcall(Open77.exports.callSync, TX, "subjectOf", playerId)
    if not ok then return nil, "coordinator_unavailable" end
    if type(s) == "string" and s ~= "" then return s end
    return nil, why or "subject_unavailable"
end

-- May this resource write `account` in operation `opId`? The coordinator's writers decide
-- (allowed, non-yielding): with the per-part list `rp_cargo:veh/cargo` the cargo bed is ours but
-- the pockets are rp_inventory's, which grants them for this one operation (grantPockets).
local RESOURCE = GetCurrentResourceName()
local function mayWrite(account, opId, playerId)
    local ok, allowed, why = pcall(Open77.exports.callSync, TX, "allowed", RESOURCE, account)
    if not ok or allowed == nil or allowed == true then return true end
    if account:match("^char:") then
        local granted, grant, gwhy = pcall(function() return exports.rp_inventory:grantPockets(opId, playerId) end)
        if granted and grant == true then return true end
        return nil, "namespace_denied", { account = account, detail = granted and tostring(gwhy) or "rp_inventory_unavailable" }
    end
    -- Any other account outside our writers may still be open to this one operation through a
    -- two-party grant (`authorize`, e.g. rp_salvage's crate hold), which the coordinator does not
    -- let us query: its transfer enforces writers and grants, so let it decide (C1 finding R-1).
    return true
end

-- ---------------------------------------------------------------------------------------------
-- rp_garage (synchronous exports, cache-only; pcall: a missing resource raises)
-- ---------------------------------------------------------------------------------------------

local Garage = {
    plateOf = function(vehicleId)
        local ok, plate = pcall(function() return exports.rp_garage:plateOf(vehicleId) end)
        if not ok then return nil, "garage_unavailable" end
        return plate
    end,
    describe = function(plate)
        local ok, d = pcall(function() return exports.rp_garage:describe(plate) end)
        if not ok then return nil, "garage_unavailable" end
        return d
    end,
    canAccess = function(playerId, plate, part, action)
        local ok, allowed, why = pcall(function() return exports.rp_garage:canAccess(playerId, plate, part, action) end)
        if not ok then return false, "garage_unavailable" end
        return allowed == true, why
    end,
}

-- ---------------------------------------------------------------------------------------------
-- Layouts and the service
-- ---------------------------------------------------------------------------------------------

local function loadLayouts()
    local doc, why = Open77.io.readJson(Config.layoutsFile)
    if not doc then
        log("no layout loaded: data/%s %s", Config.layoutsFile, tostring(why))
        return RpCargoLayout.load({ schema = 1, layouts = {} })
    end
    local registry = RpCargoLayout.load(doc)
    for _, problem in ipairs(registry.problems) do log("layout refused: %s", problem) end
    local count, unmeasured = 0, 0
    for _, layout in pairs(registry.layouts) do
        count = count + 1
        if not layout.measured then unmeasured = unmeasured + 1 end
    end
    log("%d layout(s) from data/%s, %d not measured yet (starting guesses)", count, Config.layoutsFile, unmeasured)
    return registry
end

local service = RpCargoService.new({
    config = Config,
    registry = loadLayouts(),
    tx = tx,
    subjectOf = subjectOf,
    mayWrite = mayWrite,
    garage = Garage,
    vehicles = {
        get = function(id)
            local car = Open77.vehicles.get(id)
            if car and car.id == nil then car.id = id end
            return car
        end,
        all = function() return Open77.vehicles.all() or {} end,
    },
    players = { position = function(playerId) return Open77.players.position(playerId) end },
    props = {
        create = function(def) return Open77.props.create(def) end,
        attach = function(id, binding) return Open77.props.attach(id, binding) end,
        remove = function(id) return Open77.props.remove(id) end,
        getAttachment = function(id) return Open77.props.getAttachment(id) end,
        setAttachmentTransform = function(id, offset, rotation) return Open77.props.setAttachmentTransform(id, offset, rotation) end,
    },
    wait = function(ms) Wait(ms) end,
    now = function() return Open77.time.unix() end,
    log = log,
    emit = function(name, ...) TriggerEvent(name, ...) end,
})

local function callerAllowed()
    if not Config.callers then return true end
    local caller = GetInvokingResource()
    for _, name in ipairs(Config.callers) do
        if name == caller then return true end
    end
    return false
end

-- ---------------------------------------------------------------------------------------------
-- Exports
-- ---------------------------------------------------------------------------------------------

exports("load", function(playerId, vehicleId, instanceId, opts)
    if not callerAllowed() then return nil, "caller_not_allowed" end
    return service:load(playerId, vehicleId, instanceId, opts)
end)

exports("unload", function(playerId, vehicleId, instanceId, opts)
    if not callerAllowed() then return nil, "caller_not_allowed" end
    return service:unload(playerId, vehicleId, instanceId, opts)
end)

exports("contents", function(playerId, vehicleId)
    return service:contents(playerId, vehicleId)
end)

exports("reconcile", function(plate)
    if type(plate) ~= "string" then return nil, "invalid_plate" end
    return service:reconcile(plate, "export")
end)

exports("layout", function(record)
    local layout = RpCargoLayout.find(service.registry, record)
    if not layout then return nil end
    local slots = {}
    for _, s in ipairs(layout.slots) do
        slots[#slots + 1] = { id = s.id, x = s.x, y = s.y, z = s.z, yaw = s.yaw, stackHeight = s.stackHeight, maxStack = s.maxStack, measured = s.measured }
    end
    return {
        record = layout.record, label = layout.label, part = layout.part, model = layout.model,
        capacityKg = layout.capacityKg, measured = layout.measured, objects = layout.objects, slots = slots,
    }
end)

exports("projection", function(plate)
    local proj = type(plate) == "string" and service.projections[plate] or nil
    if not proj then return nil end
    local props = {}
    for instance, cur in pairs(proj.props) do
        props[#props + 1] = { instance = instance, propId = cur.propId, slot = cur.slot, rank = cur.rank }
    end
    table.sort(props, function(a, b) return a.instance < b.instance end)
    return { vehicleId = proj.vehicleId, record = proj.record, props = props }
end)

-- ---------------------------------------------------------------------------------------------
-- Events: every reaction runs in its own task (the coordinator calls yield).
-- ---------------------------------------------------------------------------------------------

-- rp_garage took a vehicle out (garage, dealership, spawnOwned): new runtime id, same plate.
AddEventHandler("rp_garage:spawned", function(plate)
    if type(plate) ~= "string" then return end
    CreateThread(function() service:onSpawned(plate) end)
end)

-- Stored, impounded, lost: the props go, the cargo stays in "veh:<plate>:cargo".
AddEventHandler("rp_garage:despawned", function(plate)
    if type(plate) ~= "string" then return end
    CreateThread(function() service:onDespawned(plate) end)
end)

-- The platform detaches children on vehicle removal and on a parent bucket change.
AddEventHandler("onPropAttachmentChanged", function(propId, current)
    local plate = service:onAttachmentChanged(propId, current)
    if plate then CreateThread(function() service:reconcile(plate, "detached") end) end
end)

-- Another resource committed to a cargo we draw (an inventory move, a theft, an admin fix).
AddEventHandler("open77_transactions:committed", function(opId, kind, accounts)
    for _, plate in ipairs(service:onCommitted(opId, accounts)) do
        CreateThread(function() service:reconcile(plate, "committed:" .. tostring(kind)) end)
    end
end)

-- Authority handoff (a new driver or steward simulates the car): the binding is on the canonical
-- vehicle id, so nothing should move; verify instead of assuming.
AddEventHandler("onVehicleAuthorityChanged", function(vehicleId)
    local plate = Garage.plateOf(vehicleId)
    if plate and service.projections[plate] then
        CreateThread(function() service:verify(plate) end)
    end
end)

-- A reconnecting player streams the vehicle and its attachments in from the server's state;
-- the server side only re-checks its own bindings.
AddEventHandler("onPlayerReady", function()
    CreateThread(function()
        local plates = {}
        for plate in pairs(service.projections) do plates[#plates + 1] = plate end
        for _, plate in ipairs(plates) do service:verify(plate) end
    end)
end)

AddEventHandler("onResourceStart", function(name)
    if name == GetCurrentResourceName() or name == "rp_garage" then
        CreateThread(function()
            Wait(Config.startDelayMs)
            service:scan()
        end)
    end
    if name == GetCurrentResourceName() then
        log("started: reach %.1f m, sweep %d ms, coordinator %s", Config.reach, Config.sweepMs, TX)
    end
end)

CreateThread(function()
    while true do
        Wait(Config.sweepMs)
        service:scan()
    end
end)

-- ---------------------------------------------------------------------------------------------
-- Lab (console only, explicit ids). Measure a layout on a parked vehicle of the record:
--   cargospawn <vehicleId> [layers|all] [model]      a crate at every slot (and layer)
--   cargotune <vehicleId> <slot> <x> <y> <z> [yaw] [stackHeight]
--   cargolayout <vehicleId>                          the record's layout as JSON for data/layouts.json
--   cargoclear <vehicleId>                           remove the lab crates
--   cargoinfo <vehicleId|plate>                      plate, account, occupancy, drawn props
-- ---------------------------------------------------------------------------------------------

local function console(source)
    return source == 0
end

RegisterCommand("cargospawn", function(source, args)
    if not console(source) then return end
    local layers = args[2] == "all" and 99 or (tonumber(args[2]) or 1)
    local count, why = service:labSpawn(tonumber(args[1]), layers, args[3])
    if not count then return log("cargospawn %s: %s", tostring(args[1]), tostring(why)) end
    log("cargospawn %s: %d lab crate(s) attached (layers %s)", tostring(args[1]), count, args[2] == "all" and "all" or tostring(layers))
end, false)

RegisterCommand("cargotune", function(source, args)
    if not console(source) then return end
    local n = {}
    for i = 3, 8 do n[i] = tonumber(args[i]) end
    if not (n[3] and n[4] and n[5]) then
        return log("usage: cargotune <vehicleId> <slot> <x> <y> <z> [yaw] [stackHeight]")
    end
    local slot, why = service:labTune(tonumber(args[1]), tonumber(args[2]), n[3], n[4], n[5], n[6], n[7])
    if not slot then return log("cargotune %s: %s", tostring(args[1]), tostring(why)) end
    log("cargotune %s slot %d: x=%s y=%s z=%s yaw=%s stackHeight=%s (measured=false until checked on both clients)",
        tostring(args[1]), slot.id, RpCargoLayout.jsonNumber(slot.x), RpCargoLayout.jsonNumber(slot.y),
        RpCargoLayout.jsonNumber(slot.z), RpCargoLayout.jsonNumber(slot.yaw), RpCargoLayout.jsonNumber(slot.stackHeight))
end, false)

RegisterCommand("cargolayout", function(source, args)
    if not console(source) then return end
    local text, why = service:labLayout(tonumber(args[1]))
    if not text then return log("cargolayout %s: %s", tostring(args[1]), tostring(why)) end
    log("cargolayout %s: paste over the matching entry of data/layouts.json", tostring(args[1]))
    for line in text:gmatch("[^\n]+") do print(line) end
end, false)

RegisterCommand("cargoclear", function(source, args)
    if not console(source) then return end
    log("cargoclear %s: %d lab crate(s) removed", tostring(args[1]), service:labClear(tonumber(args[1])))
end, false)

RegisterCommand("cargoinfo", function(source, args)
    if not console(source) then return end
    local target = args[1]
    CreateThread(function()
        local plate = target
        if tonumber(target) then plate = Garage.plateOf(tonumber(target)) end
        if type(plate) ~= "string" then return log("cargoinfo %s: vehicle_not_tracked", tostring(target)) end
        local d = Garage.describe(plate)
        if type(d) ~= "table" then return log("cargoinfo %s: vehicle_not_tracked", plate) end
        local layout = RpCargoLayout.find(service.registry, d.record)
        if not layout then return log("cargoinfo %s: no_cargo_layout (%s)", plate, tostring(d.record)) end
        local account = RpCargoService.accountOf(plate, layout.part)
        local snap, why = service:read(account, layout, false)
        if not snap then return log("cargoinfo %s: %s", plate, tostring(why)) end
        local info = service:describe(plate, account, layout, snap)
        log("cargoinfo %s: %s state=%s vehicle=%s account=%s v%s objects=%d free=%d layout measured=%s",
            plate, d.record, tostring(d.state), tostring(d.vehicleId), account, tostring(info.version), info.objects, info.free, tostring(layout.measured))
        local proj = service.projections[plate]
        for _, entry in ipairs(info.slots) do
            local names = {}
            for _, o in ipairs(entry.objects) do
                local cur = proj and proj.props[o.instance]
                names[#names + 1] = ("%s(%s)%s"):format(o.instance, tostring(o.item), cur and ("@prop" .. tostring(cur.propId)) or "")
            end
            log("  slot %d (%d max%s): %s", entry.slot, entry.maxStack, entry.measured and ", measured" or "", #names > 0 and table.concat(names, " ") or "-")
        end
    end)
end, false)
