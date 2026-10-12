-- tests/compat/cargo_scenarios.lua: rp_cargo (layouts, slots, projection, lab), offline.
--
-- Loaded after fakehost.lua; COMPAT_DIR and CARGO_DIR are set by the runner. Boots the real
-- rp_cargo server scripts on the fake host with:
--   * the fake world (vehicles, props with vehicle attachments) of fakeworld.lua,
--   * the REAL final open77_transactions (Open77 697e9e2f, vendored; fake_tx.lua seeds it and
--     injects faults at the export boundary),
--   * a stub of rp_garage's A9 exports (plateOf, describe, canAccess) driven by GARAGE / ACCESS.
-- The garage's own access matrix is tested against the real rp_garage in
-- garage_access_scenarios.lua; here only the contract between the two is exercised.

dofile(COMPAT_DIR .. "/json.lua")
dofile(COMPAT_DIR .. "/fakeworld.lua")
dofile(COMPAT_DIR .. "/fake_tx.lua")

local MACKINAW = "Vehicle.v_standard3_thorton_mackinaw_player"
local PICKUP = "Vehicle.v_standard25_thorton_colby_pickup_player"
local QUADRA = "Vehicle.v_sport1_quadra_turbo_player"
local SPOT = { x = 100.0, y = 200.0, z = 10.0, bucket = 0 }

local function near(dx, bucket) return { x = SPOT.x + dx, y = SPOT.y, z = SPOT.z, bucket = bucket or 0 } end

local PLAYERS = {
    [1] = { identifier = "acct-1", name = "Owner", position = near(2) },
    [2] = { identifier = "acct-2", name = "Keyholder", position = near(-2) },
    [3] = { identifier = "acct-3", name = "Stranger", position = near(3) },
    [4] = { identifier = "acct-4", name = "FarAway", position = near(50) },
    [5] = { identifier = "acct-5", name = "OtherBucket", position = near(1, 3) },
    [6] = { identifier = "acct-6", name = "Impounded", position = near(1) },
    [7] = { identifier = "acct-7", name = "Officer", position = near(1) },
}

-- ---------------------------------------------------------------------------------------------
-- rp_garage stub (its A9 exports) and the coordinator
-- ---------------------------------------------------------------------------------------------

GARAGE = { live = {}, rows = {} }
ACCESS = {
    [1] = { view = true, take = true, put = true, role = "owner" },
    [2] = { view = true, take = true, put = true, role = "key" },
    [4] = { view = true, take = true, put = true, role = "owner" },
    [5] = { view = true, take = true, put = true, role = "owner" },
    [6] = { reason = "impounded" },
    [7] = { view = true, role = "police" },
}
CALLS = {}

local function installGarage()
    H.remote.rp_garage = {
        plateOf = function(vehicleId) return GARAGE.live[tostring(vehicleId)] end,
        describe = function(plate)
            local row = GARAGE.rows[plate]
            if not row then return nil, "vehicle_not_tracked" end
            return { plate = plate, record = row.record, state = row.state, vehicleId = row.vehicleId }
        end,
        canAccess = function(playerId, plate, part, action)
            CALLS[#CALLS + 1] = ("%s|%s|%s|%s"):format(tostring(playerId), tostring(plate), tostring(part), tostring(action))
            local a = ACCESS[playerId]
            if a and a[action] then return true, a.role, "out" end
            return false, (a and a.reason) or "no_access"
        end,
    }
end

-- What rp_garage does on a take-out / a store (server/main.lua spawnRow / retireRow).
local function garageSpawn(plate, record, bucket)
    local id = H.addVehicle({ record = record, position = SPOT, bucket = bucket or 0, resource = "rp_garage" })
    GARAGE.live[tostring(id)] = plate
    GARAGE.rows[plate] = { record = record, state = "out", vehicleId = id }
    TriggerEvent("rp_garage:spawned", plate, id, record)
    H.run(0.5)
    return id
end

local function garageStore(plate)
    local row = GARAGE.rows[plate]
    local id = row.vehicleId
    GARAGE.live[tostring(id)] = nil
    row.vehicleId, row.state = nil, "stored"
    H.removeVehicle(id, "removed")
    TriggerEvent("rp_garage:despawned", plate, id, "stored")
    H.run(0.5)
end

local function seedCrates(account, prefix, count, item)
    FakeTx.seed(account, 1000000)
    for i = 1, count do
        FakeTx.seedInstance(account, ("%s-%02d"):format(prefix, i), item or "nomad_crate", { origin = "salvage" })
    end
end

local SCRIPTS
local function boot()
    H.world.resourceDirs.rp_cargo = CARGO_DIR
    H.sql = function() error("rp_cargo issues no SQL") end
    local ex = H.boot("rp_cargo", SCRIPTS, "sql", PLAYERS, 5)
    return ex
end

local function setup()
    installGarage()
    FakeTx.install()
    FakeTx.define({ nomad_crate = { weightG = 25000, unique = true }, heavy_crate = { weightG = 260000, unique = true },
        scrap_metal = { weightG = 1000, unique = true } })
    seedCrates("char:acct-1", "c1", 12)
    seedCrates("char:acct-2", "c2", 6)
    seedCrates("char:acct-3", "c3", 2)
    seedCrates("char:acct-4", "c4", 1)
    seedCrates("char:acct-5", "c5", 1)
    seedCrates("char:acct-6", "c6", 1)
    return boot()
end

-- Runs a call that may yield (coordinator round trips, plate locks) in a managed task.
local function run(fn, ...)
    local args = table.pack(...)
    local out
    CreateThread(function() out = table.pack(fn(table.unpack(args, 1, args.n))) end)
    local guard = 0
    while not out and guard < 400 do
        H.run(0.25)
        guard = guard + 1
    end
    assert(out, "operation did not finish")
    return table.unpack(out, 1, out.n)
end

local function word(result, reason)
    if type(result) == "table" then
        if result.slot then return ("ok:%s:%s"):format(tostring(result.slot), tostring(result.layer)) end
        return "ok"
    end
    return tostring(result) .. ":" .. tostring(reason)
end

local function propOf(ex, plate, instance)
    local proj = ex.projection(plate)
    for _, p in ipairs(proj and proj.props or {}) do
        if p.instance == instance then return H.world.props[tostring(p.propId)], p end
    end
    return nil
end

local function num(n) return RpCargoLayout.jsonNumber(n) end

local function has(list, value)
    for _, v in ipairs(list) do if v == value then return true end end
    return false
end

local function logsMatching(pattern)
    local out = {}
    for _, line in ipairs(H.logs) do if line:find(pattern) then out[#out + 1] = line end end
    return out
end

local scenarios = {}

-- The data file loads, every shipped slot is an unmeasured guess, aliases resolve, bad layouts
-- are refused whole, and the lab's JSON round-trips to the data file's entry.
function scenarios.layouts()
    local ex = setup()
    local r = {}
    r.loaded_log = tostring(#logsMatching("4 layout%(s%) from data/layouts.json, 3 not measured yet") == 1)
    local l = ex.layout(MACKINAW)
    r.mackinaw_slots = tostring(#l.slots)
    r.mackinaw_objects = tostring(l.objects)
    r.mackinaw_measured = tostring(l.measured)
    r.alias_ncu = ex.layout("Vehicle.v_standard3_thorton_mackinaw_ncu_player").record
    r.alias_pickup02 = ex.layout("Vehicle.v_standard25_thorton_colby_pickup_02_player").record
    r.unknown = tostring(ex.layout(QUADRA))
    local doc = Open77.io.readJson("layouts.json")
    local registry = RpCargoLayout.load(doc)
    r.problems = tostring(#registry.problems)
    local unmeasured, mismatches = 0, {}
    for record, layout in pairs(registry.layouts) do
        for _, s in ipairs(layout.slots) do if not s.measured then unmeasured = unmeasured + 1 end end
        local back = CompatJson.decode("{" .. RpCargoLayout.toJson(layout) .. "}")
        local entry = back and back[record]
        local raw = doc.layouts[record]
        if not entry then
            mismatches[#mismatches + 1] = record .. ":undecodable"
        else
            for _, k in ipairs({ "label", "part", "capacityKg", "measured", "entityTemplate", "basis" }) do
                if entry[k] ~= raw[k] then mismatches[#mismatches + 1] = record .. ":" .. k end
            end
            if #entry.aliases ~= #raw.aliases then mismatches[#mismatches + 1] = record .. ":aliases" end
            for i, s in ipairs(raw.slots) do
                for _, k in ipairs({ "id", "x", "y", "z", "yaw", "stackHeight", "maxStack", "measured" }) do
                    if entry.slots[i][k] ~= s[k] then mismatches[#mismatches + 1] = ("%s:slot%d.%s"):format(record, i, k) end
                end
            end
        end
    end
    r.unmeasured_slots = tostring(unmeasured)
    r.roundtrip = #mismatches == 0 and "ok" or table.concat(mismatches, ",")
    local L = RpCargoLayout
    local function problems(raw)
        local layout, list = L.normalize("Vehicle.test_player", raw, { stackHeight = 0.5, maxStack = 2 })
        return layout and "ok" or table.concat(list, "|")
    end
    local many = {}
    for i = 1, 13 do many[i] = { id = i, x = 0, y = 0, z = 0 } end
    r.v_ok = problems({ capacityKg = 10, slots = { { id = 1, x = 0, y = -1, z = 1 } } })
    r.v_duplicate = problems({ capacityKg = 10, slots = { { id = 1, x = 0, y = 0, z = 0 }, { id = 1, x = 0, y = 0, z = 0 } } })
    r.v_offset = problems({ capacityKg = 10, slots = { { id = 1, x = 25, y = 0, z = 0 } } })
    r.v_too_many = problems({ capacityKg = 10, slots = many })
    r.v_measured = problems({ capacityKg = 10, measured = true, slots = { { id = 1, x = 0, y = 0, z = 0 } } })
    r.v_capacity = problems({ slots = { { id = 1, x = 0, y = 0, z = 0 } } })
    r.v_stack = problems({ capacityKg = 10, slots = { { id = 1, x = 0, y = 0, z = 0, maxStack = 0 } } })
    -- A stack rises by the height of the boxes under it (Config.stackHeights), the slot's
    -- stackHeight for a model without one.
    local two = L.normalize("Vehicle.stack_player", { capacityKg = 10, slots = { { id = 1, x = 0, y = -1, z = 0.9,
        stackHeight = 0.55, maxStack = 3 } } }, { stackHeight = 0.5, maxStack = 2 })
    local occ = { { instance = "a", slot = 1, model = "crate.ammo_box" }, { instance = "b", slot = 1, model = "crate.ammo_box" },
        { instance = "c", slot = 1, model = "crate.small" } }
    local p = L.placements(two, occ, { ["crate.ammo_box"] = 0.32 })
    r.stack_z = ("%.2f/%.2f/%.2f"):format(p.a.offset.z, p.b.offset.z, p.c.offset.z)
    local q = L.placements(two, occ)
    r.stack_z_default = ("%.2f/%.2f/%.2f"):format(q.a.offset.z, q.b.offset.z, q.c.offset.z)
    -- A model seated lower than crate.small rests on the floor; what stacks on it rises from there.
    local s = L.placements(two, occ, { ["crate.ammo_box"] = 0.32 }, { ["crate.ammo_box"] = -0.40 })
    r.stack_z_seated = ("%.2f/%.2f/%.2f"):format(s.a.offset.z, s.b.offset.z, s.c.offset.z)
    return r
end

-- Slots fill in layout order, then the next layer; a full vehicle refuses; props follow slots.
function scenarios.allocation()
    local ex = setup()
    local vid = garageSpawn("NC-TRK1", MACKINAW)
    local r, order = {}, {}
    for i = 1, 8 do
        local res = run(ex.load, 1, vid, ("c1-%02d"):format(i))
        order[#order + 1] = word(res):sub(4)
    end
    r.order = table.concat(order, ",")
    r.ninth = word(run(ex.load, 1, vid, "c1-09"))
    r.ninth_where = tostring(FakeTx.where("c1-09"))
    r.children = tostring(#H.childrenOf(vid))
    local p5 = propOf(ex, "NC-TRK1", "c1-05")
    r.c5_offset = ("%s,%s,%s"):format(num(p5.attachment.offset.x), num(p5.attachment.offset.y), num(p5.attachment.offset.z))
    local p2 = propOf(ex, "NC-TRK1", "c1-02")
    r.c2_offset = ("%s,%s,%s"):format(num(p2.attachment.offset.x), num(p2.attachment.offset.y), num(p2.attachment.offset.z))
    r.c2_binding = ("%s:%s:%s"):format(p2.attachment.parentType, tostring(p2.attachment.parentId == tostring(vid)), p2.attachment.bone)
    r.model = p2.model
    local inst = FakeTx.instance("c1-01")
    r.meta_slot = ("%s.%s"):format(tostring(inst.meta.cargo.slot), tostring(inst.meta.cargo.layer))
    r.meta_origin_kept = tostring(inst.meta.origin)
    r.where_c1_01 = tostring(FakeTx.where("c1-01"))
    r.access_call = tostring(has(CALLS, "1|NC-TRK1|cargo|put"))
    r.changed_events = 0
    for _, e in ipairs(H.events) do if e.name == "rp_cargo:changed" then r.changed_events = r.changed_events + 1 end end
    -- capacity is the coordinator's: a 260 kg crate does not fit a 250 kg pickup bed
    local pickup = garageSpawn("NC-PCK1", PICKUP)
    FakeTx.seedInstance("char:acct-1", "heavy-01", "heavy_crate", {})
    r.too_heavy = word(run(ex.load, 1, pickup, "heavy-01"))
    r.heavy_where = tostring(FakeTx.where("heavy-01"))
    r.pickup_children = tostring(#H.childrenOf(pickup))
    return r
end

-- A slot stacks up to maxStack; unloading the bottom crate lets the one above settle (rank),
-- the stored layer only orders the stack; an unload without a name takes the top of the last slot.
function scenarios.stacking()
    local ex = setup()
    local vid = garageSpawn("NC-TRK2", MACKINAW)
    local r = {}
    r.a = word(run(ex.load, 1, vid, "c1-01", { slot = 1 }))
    r.b = word(run(ex.load, 1, vid, "c1-02", { slot = 1 }))
    r.c_full = word(run(ex.load, 1, vid, "c1-03", { slot = 1 }))
    r.bad_slot = word(run(ex.load, 1, vid, "c1-03", { slot = 9 }))
    local res = run(ex.unload, 1, vid, "c1-01")
    r.unload_a = res and (res.instance .. "@" .. res.slot .. "->" .. res.to) or "fail"
    local pb = propOf(ex, "NC-TRK2", "c1-02")
    r.b_settled_z = num(pb.attachment.offset.z)
    r.b_stored_layer = tostring(FakeTx.instance("c1-02").meta.cargo.layer)
    r.c = word(run(ex.load, 1, vid, "c1-03", { slot = 1 }))
    r.c_z = num(propOf(ex, "NC-TRK2", "c1-03").attachment.offset.z)
    r.d = word(run(ex.load, 1, vid, "c1-04"))
    local top = run(ex.unload, 1, vid)
    r.unload_top = top and top.instance or "fail"
    r.a_cargo_meta = tostring(FakeTx.instance("c1-01").meta.cargo)
    r.a_origin = tostring(FakeTx.instance("c1-01").meta.origin)
    r.a_where = tostring(FakeTx.where("c1-01"))
    run(ex.unload, 1, vid)
    run(ex.unload, 1, vid)
    r.empty = word(run(ex.unload, 1, vid))
    r.children = tostring(#H.childrenOf(vid))
    r.props = tostring(#H.propsOf("rp_cargo"))
    return r
end

-- Every refusal names its reason and moves nothing.
function scenarios.refusals()
    local ex = setup()
    local vid = garageSpawn("NC-TRK3", MACKINAW)
    local r = {}
    r.unload_empty = word(run(ex.unload, 1, vid))
    r.stranger = word(run(ex.load, 3, vid, "c3-01"))
    r.garage_reason = word(run(ex.load, 6, vid, "c6-01"))
    r.untracked = word(run(ex.load, 1, H.addVehicle({ record = MACKINAW, position = SPOT, resource = "freeroam" }), "c1-01"))
    local quadra = garageSpawn("NC-SPT1", QUADRA)
    r.no_layout = word(run(ex.load, 1, quadra, "c1-01"))
    r.not_found = word(run(ex.load, 1, 99999, "c1-01"))
    r.bad_vehicle = word(run(ex.load, 1, "abc", "c1-01"))
    r.bad_player = word(run(ex.load, "x", vid, "c1-01"))
    r.too_far = word(run(ex.load, 4, vid, "c4-01"))
    r.wrong_bucket = word(run(ex.load, 5, vid, "c5-01"))
    H.world.vehicles[vid].speed = 5.0
    r.moving = word(run(ex.load, 1, vid, "c1-01"))
    H.world.vehicles[vid].speed = 0.0
    r.bad_instance = word(run(ex.load, 1, vid, "x"))
    r.not_mine = word(run(ex.load, 1, vid, "c2-01"))
    r.bad_source = word(run(ex.load, 1, vid, "c2-01", { from = "char:acct-2" }))
    r.bad_op = word(run(ex.load, 1, vid, "c1-01", { opId = "x" }))
    r.unload_not_in = word(run(ex.unload, 1, vid, "c1-12"))
    r.unload_bad_destination = word(run(ex.unload, 1, vid, nil, { to = "bank:acct-1" }))
    FakeTx.seed("world:pile-01", 1000000)
    FakeTx.seedInstance("world:pile-01", "pile-01", "nomad_crate", {})
    r.from_world = word(run(ex.load, 1, vid, "pile-01", { from = "world:pile-01" }))
    FakeTx.fault = "unavailable"
    r.store_down = word(run(ex.load, 1, vid, "c1-01"))
    r.store_down_where = tostring(FakeTx.where("c1-01"))
    FakeTx.uninstall()
    r.no_coordinator = word(run(ex.load, 1, vid, "c1-01"))
    FakeTx.install()
    H.remote.rp_garage = nil
    r.no_garage = word(run(ex.load, 1, vid, "c1-01"))
    installGarage()
    r.take_call = tostring(has(CALLS, "1|NC-TRK3|cargo|take"))
    r.props = tostring(#H.propsOf("rp_cargo"))
    r.children = tostring(#H.childrenOf(vid))
    return r
end

-- Two players loading the same truck at once: served in turn, never the same slot; with one
-- place left, exactly one wins.
function scenarios.concurrency()
    local ex = setup()
    local vid = garageSpawn("NC-TRK4", MACKINAW)
    for i = 1, 6 do run(ex.load, 1, vid, ("c1-%02d"):format(i)) end
    FakeTx.latencyMs = 500
    local results = {}
    CreateThread(function() results[1] = word(ex.load(1, vid, "c1-07")) end)
    CreateThread(function() results[2] = word(ex.load(2, vid, "c2-01")) end)
    for _ = 1, 40 do H.run(0.25) end
    local r = {}
    r.pair1 = tostring(results[1]) .. "|" .. tostring(results[2])
    run(ex.unload, 1, vid, "c1-01")
    results = {}
    CreateThread(function() results[1] = word(ex.load(1, vid, "c1-08")) end)
    CreateThread(function() results[2] = word(ex.load(2, vid, "c2-02")) end)
    for _ = 1, 40 do H.run(0.25) end
    r.pair2 = tostring(results[1]) .. "|" .. tostring(results[2])
    r.children = tostring(#H.childrenOf(vid))
    local seen, dup = {}, false
    for _, p in ipairs(ex.projection("NC-TRK4").props) do
        local key = p.slot .. "." .. p.rank
        if seen[key] then dup = true end
        seen[key] = true
    end
    r.duplicate_place = tostring(dup)
    r.loser_where = tostring(FakeTx.where("c2-02"))
    return r
end

-- Garage store / take-out: the props go with the vehicle, the cargo stays with the plate, and
-- comes back on the new runtime id in the same slots without a single new operation.
function scenarios.store_retrieve()
    local ex = setup()
    local vid = garageSpawn("NC-TRK5", MACKINAW)
    for i = 1, 3 do run(ex.load, 1, vid, ("c1-%02d"):format(i)) end
    local before = {}
    for _, p in ipairs(ex.projection("NC-TRK5").props) do before[#before + 1] = p.instance .. "@" .. p.slot .. "." .. p.rank end
    local ops = FakeTx.opCount()
    garageStore("NC-TRK5")
    local r = {}
    r.props_after_store = tostring(#H.propsOf("rp_cargo"))
    r.projection_after_store = tostring(ex.projection("NC-TRK5"))
    r.cargo_after_store = tostring(FakeTx.instancesIn("veh:NC-TRK5:cargo"))
    local vid2 = garageSpawn("NC-TRK5", MACKINAW)
    r.new_vehicle = tostring(vid2 ~= vid)
    r.children_new = tostring(#H.childrenOf(vid2))
    local after = {}
    for _, p in ipairs(ex.projection("NC-TRK5").props) do after[#after + 1] = p.instance .. "@" .. p.slot .. "." .. p.rank end
    r.same_slots = tostring(table.concat(before, ",") == table.concat(after, ","))
    r.slots = table.concat(after, ",")
    r.projection_vehicle = tostring(ex.projection("NC-TRK5").vehicleId == vid2)
    r.no_new_operation = tostring(FakeTx.opCount() == ops)
    return r
end

-- A resource restart (its props removed by the platform) redraws every live vehicle's cargo.
function scenarios.restart()
    local ex = setup()
    local vid = garageSpawn("NC-TRK6", MACKINAW)
    run(ex.load, 1, vid, "c1-01")
    run(ex.load, 1, vid, "c1-02")
    H.stopResource("rp_cargo")
    local r = {}
    r.props_after_stop = tostring(#H.propsOf("rp_cargo"))
    ex = boot()
    r.children_after_restart = tostring(#H.childrenOf(vid))
    local slots = {}
    for _, p in ipairs(ex.projection("NC-TRK6").props) do slots[#slots + 1] = p.instance .. "@" .. p.slot end
    r.slots = table.concat(slots, ",")
    return r
end

-- An authority handoff changes nothing; a bucket change (children detached by the platform)
-- is redrawn in the new bucket.
function scenarios.bucket_authority()
    local ex = setup()
    local vid = garageSpawn("NC-TRK7", MACKINAW)
    run(ex.load, 1, vid, "c1-01")
    run(ex.load, 1, vid, "c1-02")
    local function ids()
        local out = {}
        for _, p in ipairs(ex.projection("NC-TRK7").props) do out[#out + 1] = tostring(p.propId) end
        return table.concat(out, ",")
    end
    local before, ops = ids(), FakeTx.opCount()
    H.emit("onVehicleAuthorityChanged", tostring(vid), 3, 7, "driverclaim")
    H.emit("onPlayerReady", 2)
    H.run(1)
    local r = {}
    r.authority_same_props = tostring(ids() == before)
    r.authority_no_operation = tostring(FakeTx.opCount() == ops)
    H.setVehicleBucket(vid, 7)
    H.run(1)
    local children = H.childrenOf(vid)
    r.children_after_bucket = tostring(#children)
    local buckets = {}
    for _, c in ipairs(children) do buckets[#buckets + 1] = tostring(c.bucket) end
    r.child_buckets = table.concat(buckets, ",")
    r.props_total = tostring(#H.propsOf("rp_cargo"))
    r.bucket_no_operation = tostring(FakeTx.opCount() == ops)
    return r
end

-- An outcome in doubt keeps its slot claimed until the coordinator settles it; a settled abort
-- frees it, a settled commit is drawn.
function scenarios.in_doubt()
    local ex = setup()
    local vid = garageSpawn("NC-TRK8", MACKINAW)
    local r = {}
    FakeTx.fault = "in_doubt_aborted"
    FakeTx.statusOverride["op-a-000001"] = true
    r.first = word(run(ex.load, 1, vid, "c1-01", { opId = "op-a-000001" }))
    r.first_where = tostring(FakeTx.where("c1-01"))
    r.second = word(run(ex.load, 1, vid, "c1-02", { opId = "op-b-000001" }))
    FakeTx.statusOverride["op-a-000001"] = nil
    r.third = word(run(ex.load, 1, vid, "c1-03", { opId = "op-c-000001" }))
    FakeTx.fault = "in_doubt_committed"
    r.fourth = word(run(ex.load, 1, vid, "c1-04", { opId = "op-d-000001" }))
    r.fourth_where = tostring(FakeTx.where("c1-04"))
    r.children_before_settle = tostring(#H.childrenOf(vid))
    H.run(16)   -- the sweep settles plates with operations in doubt
    r.children_after_settle = tostring(#H.childrenOf(vid))
    local p4 = select(2, propOf(ex, "NC-TRK8", "c1-04"))
    r.fourth_slot = p4 and tostring(p4.slot) or "none"
    return r
end

-- Retrying the same intent answers the same placement and moves nothing twice; reusing an
-- operation id for another crate is refused by the coordinator.
function scenarios.replay()
    local ex = setup()
    local vid = garageSpawn("NC-TRK9", MACKINAW)
    local r = {}
    r.first = word(run(ex.load, 1, vid, "c1-01", { opId = "job:load:000001" }))
    local ops = FakeTx.opCount()
    local again = run(ex.load, 1, vid, "c1-01", { opId = "job:load:000001" })
    r.again = word(again) .. (again and again.already and ":already" or "")
    r.no_new_operation = tostring(FakeTx.opCount() == ops)
    r.children = tostring(#H.childrenOf(vid))
    r.other_crate_same_op = word(run(ex.load, 1, vid, "c1-02", { opId = "job:load:000001" }))
    r.other_where = tostring(FakeTx.where("c1-02"))
    FakeTx.fault = "stale_once"
    r.stale_retried = word(run(ex.load, 1, vid, "c1-03"))
    return r
end

-- Another resource's commit to the cargo account is drawn: a slotless crate takes a free place,
-- an item without a model is not drawn, a crate taken out by someone else disappears.
function scenarios.external()
    local ex = setup()
    local vid = garageSpawn("NC-TRKA", MACKINAW)
    run(ex.load, 1, vid, "c1-01")
    FakeTx.seedInstance("stash:dock", "crate-x1", "nomad_crate", {})
    FakeTx.seedInstance("stash:dock", "scrap-x1", "scrap_metal", {})
    local r = {}
    r.move_in = word(FakeTx.transferAs("rp_inventory", { opId = "inv-000001", kind = "inventory.move",
        lines = { { instance = "crate-x1", from = "stash:dock", to = "veh:NC-TRKA:cargo" } } }))
    H.run(1)
    local _, px = propOf(ex, "NC-TRKA", "crate-x1")
    r.slotless_drawn = px and (px.slot .. "." .. px.rank) or "none"
    FakeTx.transferAs("rp_inventory", { opId = "inv-000002", kind = "inventory.move",
        lines = { { instance = "scrap-x1", from = "stash:dock", to = "veh:NC-TRKA:cargo" } } })
    H.run(1)
    r.children_with_scrap = tostring(#H.childrenOf(vid))
    FakeTx.transferAs("rp_crime", { opId = "crime-000001", kind = "crime.steal",
        lines = { { instance = "c1-01", from = "veh:NC-TRKA:cargo", to = "stash:dock" } } })
    H.run(1)
    r.children_after_theft = tostring(#H.childrenOf(vid))
    r.c1_drawn = tostring(propOf(ex, "NC-TRKA", "c1-01") ~= nil)
    return r
end

-- The lab: crates at every slot, live tuning (lab crates AND drawn cargo follow), the JSON to
-- paste back, console only.
function scenarios.lab()
    local ex = setup()
    local r = {}
    local vid = H.addVehicle({ record = MACKINAW, position = SPOT, resource = "freeroam" })
    H.commands.cargospawn(0, { tostring(vid) })
    r.one_layer = tostring(#H.childrenOf(vid))
    H.commands.cargospawn(0, { tostring(vid), "all" })
    r.all_layers = tostring(#H.childrenOf(vid))
    H.commands.cargospawn(1, { tostring(vid) })   -- a player cannot
    r.player_ignored = tostring(#H.childrenOf(vid))
    H.commands.cargotune(0, { tostring(vid), "2", "0.6", "-1.6", "0.95", "90" })
    local tuned = {}
    for _, c in ipairs(H.childrenOf(vid)) do
        if num(c.attachment.offset.x) == "0.6" then tuned[#tuned + 1] = num(c.attachment.offset.z) .. "@" .. num(c.attachment.rotation.z) end
    end
    table.sort(tuned)
    r.tuned_lab_crates = table.concat(tuned, ",")
    H.logs = {}
    H.commands.cargolayout(0, { tostring(vid) })
    local body, inside = {}, false
    for _, line in ipairs(H.logs) do
        if inside then body[#body + 1] = line end
        if line:find("cargolayout " .. tostring(vid) .. ": paste", 1, true) then inside = true end
    end
    local entry = CompatJson.decode("{" .. table.concat(body, "\n") .. "}")
    local layout = entry and entry[MACKINAW]
    local s2 = layout and layout.slots[2]
    r.printed_slot2 = s2 and ("%s,%s,%s,%s,%s"):format(num(s2.x), num(s2.y), num(s2.z), num(s2.yaw), tostring(s2.measured)) or "undecodable"
    r.printed_measured = layout and tostring(layout.measured) or "undecodable"
    H.commands.cargotune(0, { tostring(vid), "9", "0", "0", "0" })
    H.commands.cargotune(0, { tostring(vid), "1", "30", "0", "0" })
    r.tune_refusals = tostring(#logsMatching("invalid_slot") + #logsMatching("invalid_offset"))
    H.commands.cargoclear(0, { tostring(vid) })
    r.cleared = tostring(#H.childrenOf(vid))
    local quadra = H.addVehicle({ record = QUADRA, position = SPOT, resource = "freeroam" })
    H.commands.cargospawn(0, { tostring(quadra) })
    r.no_layout_log = tostring(#logsMatching("no_cargo_layout:" .. QUADRA:gsub("%.", "%%.")) == 1)
    -- tuning re-places cargo already drawn on a tracked vehicle of the same record
    local truck = garageSpawn("NC-TRKB", MACKINAW)
    run(ex.load, 1, truck, "c1-01", { slot = 1 })
    H.commands.cargotune(0, { tostring(truck), "1", "-0.5", "-1.4", "1.0", "0" })
    local p = propOf(ex, "NC-TRKB", "c1-01")
    r.cargo_follows_tune = ("%s,%s,%s"):format(num(p.attachment.offset.x), num(p.attachment.offset.y), num(p.attachment.offset.z))
    H.logs = {}
    H.commands.cargoinfo(0, { "NC-TRKB" })
    r.info_header = tostring(#logsMatching("cargoinfo NC%-TRKB: " .. MACKINAW:gsub("%.", "%%.") .. " state=out") == 1)
    r.info_slot1 = tostring(#logsMatching("slot 1 %(2 max[^)]*%): c1%-01%(nomad_crate%)@prop") == 1)
    return r
end

-- The view: a listing for whoever may `view`, refused otherwise; no reach check.
function scenarios.contents()
    local ex = setup()
    local vid = garageSpawn("NC-TRKC", MACKINAW)
    for i = 1, 3 do run(ex.load, 1, vid, ("c1-%02d"):format(i)) end
    local r = {}
    local c = run(ex.contents, 7, vid)
    r.objects = tostring(c and c.objects)
    r.free = tostring(c and c.free)
    r.slot1 = c and (c.slots[1].objects[1].instance .. ":" .. c.slots[1].objects[1].rank) or "none"
    r.account = tostring(c and c.account)
    r.stranger = word(run(ex.contents, 3, vid))
    r.view_call = tostring(has(CALLS, "7|NC-TRKC|cargo|view"))
    return r
end

-- Per-part writers (A9 N4): the cargo bed is rp_cargo's, the pockets rp_inventory's. A load out
-- of the pockets needs rp_inventory's one-operation grant (grantPockets); without it nothing is
-- attempted.
function scenarios.per_part_writers()
    FakeTx.TUNABLES = { serverTag = "lab", writers = "rp_cargo:veh/cargo, rp_inventory:char, compat_seed",
        mint1 = "compat_seed sys:* * 100000000" }
    local ex = setup()
    local vid = garageSpawn("NC-TRKD", MACKINAW)
    local r = {}
    r.allowed_cargo = word(TXS.callSync("compat_test", "allowed", "rp_cargo", "veh:NC-TRKD:cargo"))
    r.allowed_trunk = word(TXS.callSync("compat_test", "allowed", "rp_cargo", "veh:NC-TRKD:trunk"))
    r.allowed_char = word(TXS.callSync("compat_test", "allowed", "rp_cargo", "char:acct-1"))
    local opsBefore = FakeTx.opCount()
    r.no_grant = word(run(ex.load, 1, vid, "c1-01"))
    r.no_grant_ops = tostring(FakeTx.opCount() - opsBefore)
    local grants = 0
    H.remote.rp_inventory = { grantPockets = function(opId, playerId)
        grants = grants + 1
        return TXS.callSync("rp_inventory", "authorize", opId, "rp_cargo", { "char:acct-" .. playerId }, 30000)
    end }
    r.with_grant = word(run(ex.load, 1, vid, "c1-01"))
    r.where = tostring(FakeTx.where("c1-01"))
    r.unload = word(run(ex.unload, 1, vid, "c1-01"))
    r.where_after = tostring(FakeTx.where("c1-01"))
    r.grants = tostring(grants)
    return r
end

function RUN_SCENARIO(name)
    SCRIPTS = { CARGO_DIR .. "/shared/config.lua", CARGO_DIR .. "/server/layout.lua",
        CARGO_DIR .. "/server/service.lua", CARGO_DIR .. "/server/main.lua" }
    local scenario = assert(scenarios[name], "unknown scenario " .. tostring(name))
    local result = scenario()
    local lines = {}
    for k, v in pairs(result) do lines[#lines + 1] = k .. "=" .. tostring(v) end
    table.sort(lines)
    return table.concat(lines, "\n")
end
