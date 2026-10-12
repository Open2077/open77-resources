-- tests/compat/garage_access_scenarios.lua: rp_garage's A9 access adapter, offline.
--
-- Loaded after fakehost.lua; COMPAT_DIR and GARAGE_DIR are set by the runner. Boots the real
-- rp_garage (shared/config.lua, server/access.lua, server/main.lua) on the fake host with an SQL
-- interpreter for its statements and an rp_jobs stub, then asks canAccess the access matrix:
-- owner, key holder, mechanic (with and without a job order), police (with and without a
-- warrant, on and off duty), stranger; grants across restarts and expiry; the plate identity
-- through take-out, removal and take-out again.

dofile(COMPAT_DIR .. "/json.lua")
dofile(COMPAT_DIR .. "/fakeworld.lua")

local MACKINAW = "Vehicle.v_standard3_thorton_mackinaw_player"

-- ---------------------------------------------------------------------------------------------
-- rp_garage's SQL, interpreted over H.stores.sql.garage
-- ---------------------------------------------------------------------------------------------

local function db()
    H.stores.sql.garage = H.stores.sql.garage or { vehicles = {}, keys = {}, grants = {} }
    return H.stores.sql.garage
end

local function sorted(map)
    local keys = {}
    for k in pairs(map) do keys[#keys + 1] = k end
    table.sort(keys)
    local out = {}
    for _, k in ipairs(keys) do out[#out + 1] = H.copy(map[k]) end
    return out
end

local function garageSql(sql, p)
    local d = db()
    if sql:find("CREATE TABLE", 1, true) then return 0 end
    local select = sql:match("^%s*SELECT") ~= nil
    if select and sql:find("FROM rp_garage_vehicles", 1, true) then return sorted(d.vehicles) end
    if select and sql:find("FROM rp_garage_keys", 1, true) then return sorted(d.keys) end
    if select and sql:find("FROM rp_garage_grants", 1, true) then
        local out = {}
        for _, g in ipairs(sorted(d.grants)) do
            if g.expires_at > p[1] then out[#out + 1] = g end
        end
        return out
    end
    if sql:find("INSERT INTO rp_garage_vehicles", 1, true) then
        d.vehicles[p[1]] = { plate = p[1], owner = p[2], owner_name = p[3], record = p[4], label = p[5], state = p[6],
            garage = p[7], paint = p[8], fuel = p[9], props = p[10], wanted = p[11], wanted_reason = p[12],
            impound_reason = p[13], bought_at = p[14], updated_at = p[15] }
        return 1
    end
    if sql:find("INSERT IGNORE INTO rp_garage_keys", 1, true) then
        local key = p[1] .. "|" .. p[2]
        if not d.keys[key] then d.keys[key] = { plate = p[1], holder = p[2], holder_name = p[3], given_by = p[4], at = p[5] } end
        return 1
    end
    if sql:find("DELETE FROM rp_garage_keys", 1, true) then
        for key, k in pairs(d.keys) do if k.plate == p[1] then d.keys[key] = nil end end
        return 1
    end
    if sql:find("REPLACE INTO rp_garage_grants", 1, true) then
        d.grants[p[1] .. "|" .. p[2] .. "|" .. p[3]] = { plate = p[1], role = p[2], holder = p[3], granted_by = p[4],
            reason = p[5], expires_at = p[6], at = p[7] }
        return 1
    end
    if sql:find("DELETE FROM rp_garage_grants", 1, true) then
        d.grants[p[1] .. "|" .. p[2] .. "|" .. p[3]] = nil
        return 1
    end
    error("garage_access_scenarios: unexpected SQL: " .. sql)
end

local function seedVehicle(plate, owner, record, state, wanted)
    db().vehicles[plate] = { plate = plate, owner = owner, owner_name = "", record = record, label = "Test car",
        state = state or "stored", garage = "public", paint = "", fuel = -1, props = "", wanted = wanted and 1 or 0,
        wanted_reason = "", impound_reason = "", bought_at = 0, updated_at = 0 }
end

local function seedKey(plate, holder)
    db().keys[plate .. "|" .. holder] = { plate = plate, holder = holder, holder_name = "", given_by = "", at = 0 }
end

-- ---------------------------------------------------------------------------------------------
-- Players and jobs
-- ---------------------------------------------------------------------------------------------

local SPOT = { x = -1400.0, y = 960.0, z = 23.5, bucket = 0 }
local function at(dx) return { x = SPOT.x + dx, y = SPOT.y, z = SPOT.z, bucket = 0 } end

local PLAYERS = {
    [1] = { identifier = "acct-owner", name = "Owner", position = at(0) },
    [2] = { identifier = "acct-key", name = "Keyholder", position = at(1) },
    [3] = { identifier = "acct-mech", name = "Mechanic", position = at(2) },
    [4] = { identifier = "acct-cop", name = "Officer", position = at(3) },
    [5] = { identifier = "acct-x", name = "Stranger", position = at(4) },
    [6] = { identifier = "acct-cop2", name = "OffDutyCop", position = at(5) },
    [7] = { identifier = "acct-nom", name = "Nomad", position = at(6) },
    [8] = { identifier = "acct-boss", name = "NomadBoss", position = at(7) },
    [9] = { identifier = "acct-cop3", name = "Rookie", position = at(8) },
    [10] = { identifier = "acct-mech2", name = "OffDutyMechanic", position = at(9) },
}

JOBS = {
    [3] = { job = "mecano", duty = true, grade = 1 },
    [4] = { job = "ncpd", duty = true, grade = 3 },
    [6] = { job = "ncpd", duty = false, grade = 3 },
    [7] = { job = "nomade", duty = true, grade = 1 },
    [8] = { job = "nomade", duty = true, grade = 3 },
    [9] = { job = "ncpd", duty = true, grade = 1 },
    [10] = { job = "mecano", duty = false, grade = 1 },
}

H.remote.rp_jobs = {
    hasJob = function(pid, job) return JOBS[pid] ~= nil and JOBS[pid].job == job end,
    onDuty = function(pid) return JOBS[pid] ~= nil and JOBS[pid].duty == true end,
    isBoss = function(pid) return JOBS[pid] ~= nil and JOBS[pid].grade == 3 end,
    getGrade = function(pid) return JOBS[pid] and { level = JOBS[pid].grade, label = "" } or nil end,
    getJob = function(pid) return JOBS[pid] and JOBS[pid].job or nil end,
    listOnDuty = function(job)
        local out = {}
        for pid, j in pairs(JOBS) do if j.job == job and j.duty then out[#out + 1] = pid end end
        table.sort(out)
        return out
    end,
}

local SCRIPTS
local function boot(dbMode, settle)
    H.sql = garageSql
    local ex = H.boot("rp_garage", SCRIPTS, dbMode or "sql", PLAYERS, settle or 20)
    return ex
end

local function seedWorld()
    seedVehicle("NC-AAAA", "acct-owner", MACKINAW, "stored")
    seedKey("NC-AAAA", "acct-key")
    seedVehicle("NC-FLT1", "society:nomade", MACKINAW, "stored")
    seedVehicle("NC-IMP1", "acct-owner", MACKINAW, "impounded")
end

local function word(ok, why)
    return tostring(ok) .. ":" .. tostring(why)
end

local function events(name)
    local out = {}
    for _, e in ipairs(H.events) do
        if e.name == name then
            local parts = {}
            for i = 1, e.args.n do parts[#parts + 1] = tostring(e.args[i]) end
            out[#out + 1] = table.concat(parts, ",")
        end
    end
    return table.concat(out, ";")
end

local scenarios = {}

-- The access matrix on one personal car, one society fleet car and one impounded car.
function scenarios.matrix()
    seedWorld()
    local ex = boot()
    local function can(pid, plate, part, action) return word(ex.canAccess(pid, plate, part, action)) end
    local r = {}
    -- owner and key holder
    r.owner_cargo_take = can(1, "NC-AAAA", "cargo", "take")
    r.owner_manage = can(1, "NC-AAAA", nil, "manage")
    r.owner_plate_without_prefix = can(1, "aaaa", "trunk", "put")
    r.key_cargo_put = can(2, "NC-AAAA", "cargo", "put")
    r.key_drive = can(2, "NC-AAAA", nil, "drive")
    r.key_manage = can(2, "NC-AAAA", nil, "manage")
    -- stranger
    r.stranger_cargo_view = can(5, "NC-AAAA", "cargo", "view")
    r.stranger_drive = can(5, "NC-AAAA", nil, "drive")
    -- mechanic without, then with a job order (issued by the owner)
    r.mech_no_order_view = can(3, "NC-AAAA", "cargo", "view")
    r.order_by_stranger = word(ex.authorize("NC-AAAA", "mechanic", 3, { by = 5 }))
    local grant = ex.authorize("NC-AAAA", "mechanic", 3, { by = 1, minutes = 30, reason = "brakes" })
    r.order_holder = grant and grant.holder or "none"
    r.order_minutes = grant and tostring(math.floor((grant.expiresAt - H.now) / 60)) or "none"
    r.mech_order_view = can(3, "NC-AAAA", "cargo", "view")
    r.mech_order_take = can(3, "NC-AAAA", "cargo", "take")
    r.mech_order_drive = can(3, "NC-AAAA", nil, "drive")
    r.mech_order_repair = can(3, "NC-AAAA", nil, "repair")
    r.mech_order_glovebox = can(3, "NC-AAAA", "glovebox", "view")
    r.mech_offduty_view = can(10, "NC-AAAA", "cargo", "view")
    -- police: no warrant, wanted flag, explicit warrant, off duty, grade too low to issue
    r.police_no_warrant_view = can(4, "NC-AAAA", "cargo", "view")
    ex.setWanted("NC-AAAA", true, "hit and run")
    r.police_wanted_take = can(4, "NC-AAAA", "cargo", "take")
    r.police_wanted_put = can(4, "NC-AAAA", "cargo", "put")
    r.police_wanted_impound = can(4, "NC-AAAA", nil, "impound")
    r.police_offduty_wanted = can(6, "NC-AAAA", "cargo", "view")
    ex.setWanted("NC-AAAA", false)
    r.police_after_unflag = can(4, "NC-AAAA", "cargo", "view")
    r.warrant_by_rookie = word(ex.authorize("NC-AAAA", "police", "job:ncpd", { by = 9 }))
    r.warrant_by_mechanic = word(ex.authorize("NC-AAAA", "police", "job:ncpd", { by = 3 }))
    local w = ex.authorize("NC-AAAA", "police", "job:ncpd", { by = 4, minutes = 10, reason = "search" })
    r.warrant_holder = w and w.holder or "none"
    r.police_warrant_take = can(4, "NC-AAAA", "cargo", "take")
    r.rookie_warrant_view = can(9, "NC-AAAA", "cargo", "view")
    -- impounded vehicle: owner refused, police (impound lot) allowed, manage still the owner's
    r.owner_impounded_take = can(1, "NC-IMP1", "cargo", "take")
    r.owner_impounded_manage = can(1, "NC-IMP1", nil, "manage")
    r.police_impounded_view = can(4, "NC-IMP1", "cargo", "view")
    -- society fleet: employee = key, boss = owner, outsider refused
    r.fleet_employee_put = can(7, "NC-FLT1", "cargo", "put")
    r.fleet_employee_manage = can(7, "NC-FLT1", nil, "manage")
    r.fleet_boss_manage = can(8, "NC-FLT1", nil, "manage")
    r.fleet_outsider = can(2, "NC-FLT1", "cargo", "view")
    -- vocabulary and identity
    r.untracked_plate = can(1, "NC-ZZZZ", "cargo", "view")
    r.numeric_plate = can(1, "1234", "cargo", "view")
    r.number_plate = can(1, 1234, "cargo", "view")
    r.bad_part = can(1, "NC-AAAA", "roof", "view")
    r.bad_action = can(1, "NC-AAAA", "cargo", "steal")
    r.part_action_on_vehicle = can(1, "NC-AAAA", nil, "take")
    r.bad_player = can("x", "NC-AAAA", "cargo", "view")
    r.unknown_player = can(99, "NC-AAAA", "cargo", "view")
    r.account = tostring(ex.accountOf("NC-AAAA", "cargo"))
    r.account_bad_part = word(ex.accountOf("NC-AAAA", "roof"))
    r.account_untracked = word(ex.accountOf("NC-ZZZZ", "cargo"))
    r.authorizations = tostring(#ex.authorizations("NC-AAAA"))
    r.changed = events("rp_garage:changed")
    return r
end

-- Grants are keyed by plate in SQL: they survive a restart, expire, and can be revoked.
function scenarios.grants_persist()
    seedWorld()
    local ex = boot()
    local r = {}
    ex.authorize("NC-AAAA", "mechanic", "acct-mech", { by = 1, minutes = 30 })
    r.sql_rows = tostring(#sorted(db().grants))
    ex = boot()
    r.after_restart = word(ex.canAccess(3, "NC-AAAA", "cargo", "view"))
    H.run(31 * 60)   -- the snapshot loop purges expired grants every 30 s
    r.after_expiry = word(ex.canAccess(3, "NC-AAAA", "cargo", "view"))
    r.sql_rows_after_expiry = tostring(#sorted(db().grants))
    ex = boot()
    r.after_expiry_restart = word(ex.canAccess(3, "NC-AAAA", "cargo", "view"))
    ex.authorize("NC-AAAA", "mechanic", 3, { by = 1, minutes = 30 })
    r.revoke_by_stranger = word(ex.revokeAuthorization("NC-AAAA", "mechanic", 3, { by = 5 }))
    r.revoke_by_owner = word(ex.revokeAuthorization("NC-AAAA", "mechanic", 3, { by = 1 }))
    r.after_revoke = word(ex.canAccess(3, "NC-AAAA", "cargo", "view"))
    r.revoke_again = word(ex.revokeAuthorization("NC-AAAA", "mechanic", 3))
    r.bad_holder = word(ex.authorize("NC-AAAA", "mechanic", "session:12"))
    r.runtime_holder = word(ex.authorize("NC-AAAA", "mechanic", "12345"))
    r.bad_role = word(ex.authorize("NC-AAAA", "admin", "acct-mech"))
    r.too_long = word(ex.authorize("NC-AAAA", "mechanic", "acct-mech", { minutes = 100000 }))
    return r
end

-- Until the store answered, every answer is a refusal, never a guess.
function scenarios.loading()
    seedWorld()
    local ex = boot("silent", 5)   -- the garage falls back to KVP after 15 s; ask before
    return {
        can = word(ex.canAccess(1, "NC-AAAA", "cargo", "view")),
        authorize = word(ex.authorize("NC-AAAA", "mechanic", 3)),
    }
end

-- The plate is the identity; the runtime id is a projection that changes on every take-out.
function scenarios.identity()
    seedWorld()
    local ex = boot()
    ex.authorize("NC-AAAA", "mechanic", 3, { by = 1, minutes = 30 })
    local r = {}
    local first = ex.spawnOwned(1, "NC-AAAA")
    r.first_ok = tostring(type(first) == "number")
    r.describe_first = tostring(ex.describe("NC-AAAA").vehicleId == first)
    r.key_vehicle_put = word(ex.canAccessVehicle(2, first, "cargo", "put"))
    r.stranger_vehicle = word(ex.canAccessVehicle(5, first, "cargo", "put"))
    r.mech_exception = tostring(H.world.exceptions[first] and H.world.exceptions[first][3])
    r.key_exception = tostring(H.world.exceptions[first] and H.world.exceptions[first][2])
    r.stranger_exception = tostring(H.world.exceptions[first] and H.world.exceptions[first][5])
    H.removeVehicle(first, "admin_dv")
    H.run(1)
    r.state_after_removal = ex.describe("NC-AAAA").state
    r.no_vehicle_after_removal = tostring(ex.describe("NC-AAAA").vehicleId == nil)
    r.old_id = word(ex.canAccessVehicle(2, first, "cargo", "put"))
    local second = ex.spawnOwned(1, "NC-AAAA")
    r.new_id_differs = tostring(second ~= first)
    r.describe_second = tostring(ex.describe("NC-AAAA").vehicleId == second)
    r.new_id = word(ex.canAccessVehicle(2, second, "cargo", "put"))
    r.plate_of_second = tostring(ex.plateOf(second))
    r.untracked_vehicle = word(ex.canAccessVehicle(2, H.addVehicle({ record = MACKINAW, position = SPOT, resource = "freeroam" }), "cargo", "put"))
    r.spawned = events("rp_garage:spawned"):gsub("%d%d%d+", "<id>")
    r.despawned = events("rp_garage:despawned"):gsub("%d%d%d+", "<id>")
    return r
end

-- Player commands: the owner revokes keys and hands out a job order; the console issues a warrant.
function scenarios.commands()
    seedWorld()
    local ex = boot()
    local r = {}
    r.key_before = word(ex.canAccess(2, "NC-AAAA", "cargo", "take"))
    H.commands["cles"](1, { "revoke", "NC-AAAA" })
    r.key_after_revoke = word(ex.canAccess(2, "NC-AAAA", "cargo", "take"))
    r.key_rows = tostring(#sorted(db().keys))
    H.commands["cles"](1, { "ordre", "3", "NC-AAAA", "20" })
    r.mech_after_order = word(ex.canAccess(3, "NC-AAAA", "cargo", "view"))
    H.commands["cles"](1, { "ordre", "5", "NC-AAAA" })   -- not a mechanic: refused
    r.stranger_after_order = word(ex.canAccess(5, "NC-AAAA", nil, "drive"))
    H.commands["cles"](2, { "ordre", "3", "NC-IMP1" })   -- not the owner of that car
    H.commands["cles"](1, { "ordre", "annuler", "NC-AAAA" })
    r.mech_after_cancel = word(ex.canAccess(3, "NC-AAAA", "cargo", "view"))
    H.commands["vehwarrant"](0, { "NC-AAAA", "15", "stolen", "goods" })
    r.police_after_console_warrant = word(ex.canAccess(4, "NC-AAAA", "cargo", "take"))
    H.commands["vehwarrant"](1, { "NC-AAAA", "off" })   -- players cannot use the console command
    r.police_after_player_attempt = word(ex.canAccess(4, "NC-AAAA", "cargo", "take"))
    H.commands["vehwarrant"](0, { "NC-AAAA", "off" })
    r.police_after_lift = word(ex.canAccess(4, "NC-AAAA", "cargo", "take"))
    local warrant = (ex.authorizations("NC-AAAA")[1] or {})
    r.no_grant_left = tostring(warrant.role == nil)
    return r
end

-- The lab issue (C1 two-client runs): a plated vehicle owned by the player, out next to them,
-- only with the convar rp_garage_lab 1.
function scenarios.lab_issue()
    seedWorld()
    local convars = {}
    GetConvar = function(name, default)
        local v = convars[name]
        if v == nil then return default end
        return v
    end
    local ex = boot()
    local r = {}
    r.disabled = word(ex.labIssue(1, MACKINAW))
    convars.rp_garage_lab = "1"
    local issued, why = ex.labIssue(2, MACKINAW, { label = "Lab truck" })
    r.issued = type(issued) == "table" and (issued.state .. ":" .. tostring(issued.plate:match("^NC%-") ~= nil)
        .. ":" .. tostring(type(issued.vehicleId) == "number")) or word(issued, why)
    local plate = type(issued) == "table" and issued.plate
    r.owner = plate and tostring(ex.describe(plate).owner) or "none"
    r.owner_cargo = plate and word(ex.canAccess(2, plate, "cargo", "put")) or "none"
    r.stranger_cargo = plate and word(ex.canAccess(5, plate, "cargo", "put")) or "none"
    r.account = plate and tostring(ex.accountOf(plate, "cargo")) == ("veh:" .. plate .. ":cargo") and "ok" or "none"
    r.persisted = plate and tostring(db().vehicles[plate] ~= nil) or "none"
    r.stored_only = (function()
        local s = ex.labIssue(2, MACKINAW, { spawn = false })
        return type(s) == "table" and s.state or "none"
    end)()
    r.bad_record = word(ex.labIssue(2, "not a record"))
    r.bad_player = word(ex.labIssue(999, MACKINAW))
    return r
end

function RUN_SCENARIO(name)
    SCRIPTS = { GARAGE_DIR .. "/shared/config.lua", GARAGE_DIR .. "/server/access.lua", GARAGE_DIR .. "/server/main.lua" }
    local scenario = assert(scenarios[name], "unknown scenario " .. tostring(name))
    local result = scenario()
    local lines = {}
    for k, v in pairs(result) do lines[#lines + 1] = k .. "=" .. tostring(v) end
    table.sort(lines)
    return table.concat(lines, "\n")
end
