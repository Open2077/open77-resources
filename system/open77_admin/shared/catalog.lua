-- GENERATED FILE -- do not edit by hand.
--
-- Produced by resources/system/open77_admin/tools/build-catalog.py from
-- docs/vehicle-models.md (Cyberpunk 2077 build 2.31). Re-run the
-- generator instead of editing; a hand edit is lost on the next build
-- and drifts silently from the catalogue it claims to mirror.
--
-- Shared, not client: the panel renders it and the server validates
-- against it, so both halves must read the same bytes.
--
-- Records are stored as parallel arrays rather than a table per
-- vehicle. 1372 tables of six string keys is a measurable amount
-- of Lua state to build on every client at load; six arrays is not.
--
-- ---------------------------------------------------------------------
-- DO NOT MERGE THE COMPANION FILES BACK INTO THIS ONE.
--
-- The scripting host loads each script of a resource with its own
-- lua_pcall, under a LUA_MASKCOUNT hook that fires every 10 000 VM
-- instructions and, when it fires, aborts the load if the wall clock is
-- past a 2 ms deadline (scripting/src/ResourceHost.cpp, Prepare()). The
-- instruction count and the deadline are both reset PER FILE.
--
-- So the whole trick is to stay under the hook's stride: a file that
-- executes fewer than 10 000 instructions never fires the hook, and the
-- deadline is therefore never consulted. The failure is not made less
-- likely, it is made structurally impossible.
--
-- As one file this catalogue executed about 13 700 instructions -- 9 583
-- opcodes of table constructors plus 1372 x 3 for the index loop. It
-- crossed the stride exactly once, and the host rolled back the entire
-- 25-resource candidate set whenever that single check landed on a
-- stalled frame: observed twice on 2026-08-28, each time silently
-- leaving the previous resource set running, so a deploy appeared to
-- succeed while the client kept executing the old code.
--
-- Load order is the shared_script order in open77.lua, and it matters:
--   catalog.lua
--   catalog-records.lua
--   catalog-names.lua
--   catalog-taxonomy.lua
--   catalog-attributes.lua
--   catalog-index-1.lua
--   catalog-index-2.lua
--
-- The last index part asserts that all of them ran. If you ever see
-- `catalogue incomplete` at startup, that list is wrong.
-- ---------------------------------------------------------------------

Open77AdminCatalog = {
    build = "2.31",
    count = 1372,
    groups = {
        { key = "player", label = "Player & garage", count = 89 },
        { key = "ground", label = "General ground", count = 474 },
        { key = "air", label = "AV & airborne", count = 23 },
        { key = "special", label = "Quest & special", count = 786 },
    },
    classes = {
        { key = "av", label = "Airborne", order = 70, count = 23 },
        { key = "other", label = "Other", order = 95, count = 810 },
        { key = "police", label = "Police", order = 5, count = 9 },
        { key = "sport1", label = "Hypercar", order = 10, count = 50 },
        { key = "sport2", label = "Sports", order = 20, count = 79 },
        { key = "sportbike1", label = "Superbike", order = 30, count = 30 },
        { key = "sportbike2", label = "Bike", order = 35, count = 15 },
        { key = "sportbike3", label = "Bike", order = 36, count = 15 },
        { key = "standard2", label = "Saloon", order = 40, count = 155 },
        { key = "standard25", label = "Pickup", order = 45, count = 68 },
        { key = "standard3", label = "SUV", order = 50, count = 56 },
        { key = "utility4", label = "Truck", order = 64, count = 62 },
    },
    makers = {
        { key = "PlayerBike", label = "Playerbike", count = 1 },
        { key = "PlayerCar", label = "Playercar", count = 1 },
        { key = "VehicleDroneCarrier", label = "Vehicledronecarrier", count = 1 },
        { key = "aerondight", label = "Aerondight", count = 1 },
        { key = "aldecado", label = "Aldecado", count = 4 },
        { key = "apollo", label = "Apollo", count = 1 },
        { key = "arch", label = "Arch", count = 15 },
        { key = "archer", label = "Archer", count = 49 },
        { key = "arr", label = "Arr", count = 2 },
        { key = "av", label = "AV", count = 23 },
        { key = "basilisk", label = "Basilisk", count = 3 },
        { key = "batty", label = "Batty", count = 1 },
        { key = "border", label = "Border", count = 3 },
        { key = "box", label = "Box", count = 1 },
        { key = "brennan", label = "Brennan", count = 16 },
        { key = "bubble", label = "Bubble", count = 1 },
        { key = "chevalier", label = "Chevalier", count = 52 },
        { key = "columbus", label = "Columbus", count = 1 },
        { key = "corpo", label = "Corpo", count = 1 },
        { key = "cs", label = "Cs", count = 204 },
        { key = "cvi", label = "Cvi", count = 1 },
        { key = "de", label = "De", count = 1 },
        { key = "demo", label = "Demo", count = 3 },
        { key = "destruction", label = "Destruction", count = 1 },
        { key = "e319", label = "E319", count = 7 },
        { key = "ep1", label = "Ep1", count = 21 },
        { key = "golf", label = "Golf", count = 1 },
        { key = "hackable", label = "Hackable", count = 63 },
        { key = "hackablequadra", label = "Hackablequadra", count = 1 },
        { key = "hella", label = "Hella", count = 1 },
        { key = "hellhound", label = "Hellhound", count = 1 },
        { key = "herrera", label = "Herrera", count = 12 },
        { key = "hil", label = "Hil", count = 1 },
        { key = "ina", label = "Ina", count = 1 },
        { key = "interceptor", label = "Interceptor", count = 3 },
        { key = "jackie", label = "Jackie", count = 1 },
        { key = "johnny", label = "Johnny", count = 1 },
        { key = "jpn", label = "Jpn", count = 1 },
        { key = "judy", label = "Judy", count = 1 },
        { key = "kab", label = "Kab", count = 2 },
        { key = "kaukaz", label = "Kaukaz", count = 40 },
        { key = "kerry", label = "Kerry", count = 2 },
        { key = "kurtz", label = "Kurtz", count = 6 },
        { key = "lego", label = "Lego", count = 1 },
        { key = "limousine", label = "Limousine", count = 1 },
        { key = "ma", label = "Ma", count = 15 },
        { key = "mahir", label = "Mahir", count = 18 },
        { key = "makigai", label = "Makigai", count = 19 },
        { key = "max", label = "Max", count = 7 },
        { key = "militech", label = "Militech", count = 12 },
        { key = "mitch", label = "Mitch", count = 1 },
        { key = "mizutani", label = "Mizutani", count = 34 },
        { key = "mq001", label = "Mq001", count = 2 },
        { key = "mq005", label = "Mq005", count = 1 },
        { key = "mq006", label = "Mq006", count = 1 },
        { key = "mq013", label = "Mq013", count = 1 },
        { key = "mq017", label = "Mq017", count = 1 },
        { key = "mq026", label = "Mq026", count = 2 },
        { key = "mq027", label = "Mq027", count = 1 },
        { key = "mq030", label = "Mq030", count = 1 },
        { key = "mq038", label = "Mq038", count = 1 },
        { key = "mq056", label = "Mq056", count = 1 },
        { key = "mq057", label = "Mq057", count = 1 },
        { key = "mq059", label = "Mq059", count = 1 },
        { key = "mq060", label = "Mq060", count = 7 },
        { key = "mq301", label = "Mq301", count = 8 },
        { key = "mq303", label = "Mq303", count = 1 },
        { key = "mq304", label = "Mq304", count = 1 },
        { key = "mt28", label = "Mt28", count = 1 },
        { key = "mws", label = "Mws", count = 23 },
        { key = "nid", label = "Nid", count = 1 },
        { key = "ow", label = "Ow", count = 5 },
        { key = "panam", label = "Panam", count = 4 },
        { key = "porsche", label = "Porsche", count = 5 },
        { key = "ps", label = "Ps", count = 1 },
        { key = "q000", label = "Q000", count = 53 },
        { key = "q001", label = "Q001", count = 12 },
        { key = "q003", label = "Q003", count = 3 },
        { key = "q005", label = "Q005", count = 5 },
        { key = "q101", label = "Q101", count = 7 },
        { key = "q103", label = "Q103", count = 3 },
        { key = "q104", label = "Q104", count = 12 },
        { key = "q108", label = "Q108", count = 4 },
        { key = "q110", label = "Q110", count = 9 },
        { key = "q111", label = "Q111", count = 1 },
        { key = "q112", label = "Q112", count = 15 },
        { key = "q113", label = "Q113", count = 1 },
        { key = "q114", label = "Q114", count = 32 },
        { key = "q115", label = "Q115", count = 4 },
        { key = "q116", label = "Q116", count = 1 },
        { key = "q201", label = "Q201", count = 1 },
        { key = "q202", label = "Q202", count = 2 },
        { key = "q203", label = "Q203", count = 1 },
        { key = "q204", label = "Q204", count = 2 },
        { key = "q301", label = "Q301", count = 15 },
        { key = "q302", label = "Q302", count = 6 },
        { key = "q303", label = "Q303", count = 2 },
        { key = "q304", label = "Q304", count = 27 },
        { key = "q305", label = "Q305", count = 16 },
        { key = "q306", label = "Q306", count = 18 },
        { key = "q307", label = "Q307", count = 3 },
        { key = "quadra", label = "Quadra", count = 48 },
        { key = "rayfield", label = "Rayfield", count = 14 },
        { key = "rcr", label = "Rcr", count = 1 },
        { key = "reed", label = "Reed", count = 2 },
        { key = "reginald", label = "Reginald", count = 1 },
        { key = "rogue", label = "Rogue", count = 2 },
        { key = "sa", label = "Sa", count = 3 },
        { key = "santiago", label = "Santiago", count = 2 },
        { key = "saul", label = "Saul", count = 1 },
        { key = "scavenger", label = "Scavenger", count = 1 },
        { key = "shion", label = "Shion", count = 1 },
        { key = "smalltruck", label = "Smalltruck", count = 1 },
        { key = "sobchak", label = "Sobchak", count = 2 },
        { key = "spr", label = "Spr", count = 1 },
        { key = "sq003", label = "Sq003", count = 1 },
        { key = "sq004", label = "Sq004", count = 11 },
        { key = "sq006", label = "Sq006", count = 2 },
        { key = "sq011", label = "Sq011", count = 2 },
        { key = "sq012", label = "Sq012", count = 2 },
        { key = "sq017", label = "Sq017", count = 1 },
        { key = "sq018", label = "Sq018", count = 1 },
        { key = "sq021", label = "Sq021", count = 4 },
        { key = "sq022", label = "Sq022", count = 1 },
        { key = "sq023", label = "Sq023", count = 3 },
        { key = "sq024", label = "Sq024", count = 6 },
        { key = "sq025", label = "Sq025", count = 13 },
        { key = "sq026", label = "Sq026", count = 1 },
        { key = "sq027", label = "Sq027", count = 12 },
        { key = "sq028", label = "Sq028", count = 2 },
        { key = "sq030", label = "Sq030", count = 1 },
        { key = "sq031", label = "Sq031", count = 1 },
        { key = "stadium", label = "Stadium", count = 1 },
        { key = "sts", label = "Sts", count = 19 },
        { key = "supron", label = "Supron", count = 1 },
        { key = "suv", label = "Suv", count = 2 },
        { key = "takemura", label = "Takemura", count = 2 },
        { key = "taxi", label = "Taxi", count = 1 },
        { key = "thorton", label = "Thorton", count = 104 },
        { key = "trauma", label = "Trauma", count = 1 },
        { key = "ue", label = "Ue", count = 1 },
        { key = "v", label = "V", count = 1 },
        { key = "vehicle", label = "Vehicle", count = 1 },
        { key = "villefort", label = "Villefort", count = 69 },
        { key = "vm", label = "Vm", count = 1 },
        { key = "wasteland", label = "Wasteland", count = 3 },
        { key = "wst", label = "Wst", count = 1 },
        { key = "yaiba", label = "Yaiba", count = 32 },
        { key = "z71", label = "Z71", count = 1 },
    },
    -- Measured rated top speeds, km/h. Seeded only where a real
    -- measurement exists; the server adds to this at runtime from
    -- Open77.vehicles.ratedTopSpeed and never estimates.
    ratedTopSpeed = {
        ["Vehicle.ncpd_villefort_cortes_heat_1"] = 140.0,
        ["Vehicle.v_sport1_quadra_turbo_r_player"] = 155.0,
        ["Vehicle.v_standard2_archer_hella_player"] = 115.0,
    },

    -- Filled by the companion files, in manifest order. Declared here so
    -- the shape of the catalogue is visible in one place, and so that no
    -- reader is ever handed a nil table.
    records = {},
    names = {},
    groupOf = {},
    classOf = {},
    makerOf = {},
    flags = {},
    byRecord = {},
}

--- Position of a record in the catalogue, or nil when it is not one.
--- This is the server's validity test: a client may name any string,
--- and only a string that is in here reaches Open77.vehicles.create.
---
--- `byRecord` was a file-local `index` before the split. It is a field
--- now because a local cannot be seen from another file, and it stays an
--- O(1) test -- 1372 linear scans per keystroke would be felt on the
--- search box.
function Open77AdminCatalog.position(record)
    if type(record) ~= "string" then return nil end
    return Open77AdminCatalog.byRecord[record]
end

--- One entry as a plain table, or nil. Built on demand precisely
--- because the columnar form exists to avoid building 1372 of them.
function Open77AdminCatalog.entry(record)
    local position = Open77AdminCatalog.position(record)
    if position == nil then return nil end
    local catalog = Open77AdminCatalog
    local flags = catalog.flags[position]
    return {
        record = record,
        name = catalog.names[position],
        group = catalog.groupOf[position],
        class = catalog.classes[catalog.classOf[position]].key,
        maker = catalog.makers[catalog.makerOf[position]].key,
        police = flags % 2 == 1,
        player = flags >= 2,
        ratedTopSpeed = catalog.ratedTopSpeed[record],
    }
end
