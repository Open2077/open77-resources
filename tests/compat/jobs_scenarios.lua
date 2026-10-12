-- tests/compat/jobs_scenarios.lua: rp_jobs (B4 adapter) on the B8 fake host, offline.
--
-- Loaded after fakehost.lua. The runner sets `JOBS_SCRIPT` (rp_jobs/server/main.lua) and
-- `JOBS_CONFIG` (rp_jobs/shared/config.lua). Everything this file adds to the fake host is
-- local to these scenarios: fakehost.lua itself is not changed.
--
--   * an SQL interpreter for exactly the statements rp_jobs issues, with fault injection
--     (a failing statement answers `nil, reason`, as the real bridge's callbacks do) and
--     deferred completions (the bridge completes on a later tick, H.drainSql());
--   * a "late" database mode: configured, not answering until the scenario lets it;
--   * player state bags, a subject provider, distances/positions, chat capture.
--
-- Each scenario returns a flat table; the runner turns it into "key=value" lines.

-- The final coordinator (the vendored Open77 697e9e2f) for the subject provider rule, on the
-- coordinator sandbox; the other scenarios never start it.
dofile(COMPAT_DIR .. "/txsandbox.lua")

-- ---------------------------------------------------------------------------
-- Scenario-local fakes
-- ---------------------------------------------------------------------------

local function count(pattern, tbl)
    local n = 0
    for k in pairs(tbl) do
        if pattern == nil or tostring(k):find(pattern) then n = n + 1 end
    end
    return n
end

local function resetLocal()
    H.bags = {}
    H.chat = {}
    H.distances = {}
    H.positions = {}
    H.sqlQueue = {}
    H.sqlCount = {}
    H.uikitCalls = 0
end
resetLocal()
H.providers = {}

local function rows()
    H.stores.sql.employees = H.stores.sql.employees or {}
    return H.stores.sql.employees
end

local function jobsSql(sql, p)
    local verb = sql:match("^%s*(%u+)")
    H.sqlCount[verb] = (H.sqlCount[verb] or 0) + 1
    if sql:find("CREATE TABLE IF NOT EXISTS rp_jobs_employees", 1, true) then
        if H.failSchema and (H.failSchemaTimes == nil or H.failSchemaTimes > 0) then
            if H.failSchemaTimes then H.failSchemaTimes = H.failSchemaTimes - 1 end
            return nil, H.failSchema
        end
        return 0
    end
    if H.failWrites and H.failWrites > 0 and (verb == "INSERT" or verb == "DELETE") then
        H.failWrites = H.failWrites - 1
        return nil, H.failReason or "database_unreachable (SQL 2013): Lost connection to server during query retry"
    end
    local employees = rows()
    if sql:find("UPDATE rp_jobs_employees SET on_duty = 0 WHERE on_duty <> 0", 1, true) then
        local n = 0
        for _, row in pairs(employees) do
            if row.on_duty ~= 0 then row.on_duty = 0; n = n + 1 end
        end
        return n
    end
    if sql:find("SELECT job, grade, hired_at, hired_by FROM rp_jobs_employees WHERE identifier = ?", 1, true) then
        local row = employees[p[1]]
        if not row then return nil end
        return { job = row.job, grade = row.grade, hired_at = row.hired_at, hired_by = row.hired_by }
    end
    if sql:find("INSERT INTO rp_jobs_employees", 1, true) then
        assert(#p == 11, "upsert parameter count")
        employees[p[1]] = { job = p[2], grade = p[3], on_duty = p[4], hired_at = p[5], hired_by = p[6] }
        return 1
    end
    if sql:find("DELETE FROM rp_jobs_employees WHERE identifier = ?", 1, true) then
        local had = employees[p[1]] ~= nil
        employees[p[1]] = nil
        return had and 1 or 0
    end
    error("jobs_scenarios: unexpected SQL: " .. sql)
end

-- Callback form: completes now, or on H.drainSql() when H.deferSql is set.
local function callbackMethod()
    return setmetatable({
        await = function(sql, params) return jobsSql(sql, params or {}) end,
    }, {
        __call = function(_, sql, params, cb)
            local function complete()
                local result, why = jobsSql(sql, params or {})
                if cb then cb(result, why) end
            end
            if H.deferSql then
                H.sqlQueue[#H.sqlQueue + 1] = complete
            else
                complete()
            end
            return true
        end,
    })
end
Open77.database.update = callbackMethod()
Open77.database.single = callbackMethod()

function H.drainSql()
    while #H.sqlQueue > 0 do
        local complete = table.remove(H.sqlQueue, 1)
        complete()
    end
end

-- "late": a database is configured but has not answered; the scenario answers it later.
local fakeReady, fakeIsReady = Open77.database.ready, Open77.database.isReady
Open77.database.ready = function(fn)
    if H.dbMode == "late" then
        H.lateReady = fn
        return true
    end
    return fakeReady(fn)
end
Open77.database.isReady = function()
    if H.dbMode == "late" then return false, "database_unreachable" end
    return fakeIsReady()
end

-- Player state bags: one table per player id; H.bagRefuse makes every write refuse.
Open77.state = {
    player = function(id)
        local key = tostring(id)
        return {
            set = function(_, name, value)
                if H.bagRefuse then return false, H.bagRefuse end
                H.bags[key] = H.bags[key] or {}
                H.bags[key][name] = value
                return true
            end,
        }
    end,
}

-- Cross-resource sync exports: H.providers[resource][name], else the call raises
-- (a resource that is not running), as Open77.exports.callSync does.
Open77.exports = {
    callSync = function(resource, name, ...)
        local provider = H.providers[resource]
        if not provider or not provider[name] then
            error(("export %s:%s resource_not_running"):format(resource, name), 2)
        end
        return provider[name](...)
    end,
    call = function(resource, name)
        if resource == "open77_uikit" then H.uikitCalls = H.uikitCalls + 1 end
        return nil, "not_faked"
    end,
}

Open77.players.distance = function(a, b)
    return H.distances[a .. ":" .. b] or H.distances[b .. ":" .. a] or 1.0
end
Open77.players.position = function(id)
    return H.positions[id] or { x = -1173.12, y = 2087.44, z = 11.94 }
end
Open77.props = {
    create = function() return 4242 end,
    remove = function() return true end,
}
Open77.chat.send = function(id, message)
    H.chat[#H.chat + 1] = { id = id, text = message and message.text or "" }
    return true
end

-- ---------------------------------------------------------------------------
-- Drivers
-- ---------------------------------------------------------------------------

local P7 = { identifier = "acct-0007", name = "V" }
local P8 = { identifier = "acct-0008", name = "Judy" }
local P9 = { identifier = "acct-0009", name = "River" }

local function players(...)
    local all, out = { [7] = P7, [8] = P8, [9] = P9 }, {}
    for _, id in ipairs({ ... }) do out[id] = all[id] end
    return out
end

-- A fresh resource generation over the same stores, with a freshly read config.
local function boot(dbMode, connected, overrides)
    local config = assert(loadfile(JOBS_CONFIG, "t"))
    config()
    for key, value in pairs(overrides or {}) do RpJobsConfig[key] = value end
    H.sql = jobsSql
    resetLocal()
    return H.boot("rp_jobs", JOBS_SCRIPT, dbMode, connected, 60)
end

local function cmd(name, source, ...)
    local args = { ... }
    CreateThread(function() H.commands[name](source, args) end)
    H.run(1)
end

local function net(name, from, ...)
    local args = table.pack(...)
    CreateThread(function()
        source = from
        for _, fn in ipairs(H.handlers[name] or {}) do fn(table.unpack(args, 1, args.n)) end
    end)
    H.run(1)
end

local function connect(id, player)
    H.players[id] = player
    H.emit("onPlayerReady", id)
    H.run(1)
end

local function disconnect(id)
    H.players[id] = nil
    H.emit("onPlayerDisconnected", id)
    H.run(1)
end

local function verdict(...)
    local ok, value = ...
    if ok then return "ok" end
    return tostring(value)
end

local function reason(...)
    local value, why = ...
    if value == nil then return tostring(why) end
    return "value:" .. tostring(value)
end

local function hasLog(fragment)
    for _, line in ipairs(H.logs) do
        if line:find(fragment, 1, true) then return true end
    end
    return false
end

local function lastChat(id)
    for i = #H.chat, 1, -1 do
        if H.chat[i].id == id then return H.chat[i].text end
    end
    return ""
end

local function encode(tbl)
    if type(tbl) ~= "table" then return tostring(tbl) end
    local parts = {}
    for k, v in pairs(tbl) do parts[#parts + 1] = tostring(k) .. "=" .. tostring(v) end
    table.sort(parts)
    return table.concat(parts, ";")
end

local function epochEvents(id)
    local out = {}
    for _, e in ipairs(H.events) do
        if e.name == "rp_jobs:workEpoch" and e.args[1] == id then
            out[#out + 1] = { epoch = e.args[2], reason = e.args[3] }
        end
    end
    return out
end

local function rowText(identifier)
    local row = rows()[identifier]
    if not row then return "none" end
    return ("%s:%s:duty=%s"):format(row.job, tostring(row.grade), tostring(row.on_duty))
end

local scenarios = {}

-- ---------------------------------------------------------------------------
-- Eligibility matrix
-- ---------------------------------------------------------------------------

function scenarios.eligibility_matrix()
    local ex = boot("sql", players(7, 8, 9))
    cmd("setjob", 0, "7", "ferrailleur", "1")
    cmd("setjob", 0, "9", "police", "3")
    cmd("service", 9)
    local function e(id, req) return verdict(ex.eligible(id, req)) end
    local r = {
        any_loaded = e(7, nil),
        jobless_any = e(8, nil),
        job_match = e(7, { job = "ferrailleur" }),
        job_alias = e(9, { job = "police" }),
        job_list = e(7, { job = { "ncpd", "ferrailleur" } }),
        job_wrong = e(7, { job = "ncpd" }),
        job_none = e(8, { job = "ferrailleur" }),
        duty_off = e(7, { job = "ferrailleur", duty = true }),
        duty_false_is_no_constraint = e(7, { job = "ferrailleur", duty = false }),
        duty_on = e(9, { job = "ncpd", duty = true }),
        duty_jobless = e(8, { duty = true }),
        grade_low = e(7, { job = "ferrailleur", minGrade = 2 }),
        grade_ok = e(7, { job = "ferrailleur", minGrade = 1 }),
        any_job = e(8, { minGrade = 0 }),
        boss_scoped = e(9, { job = "ncpd", minGrade = 3 }),
        boss_other_job = e(9, { job = "trauma", minGrade = 3 }),
        society_ok = e(7, { society = "Ferrailleur" }),
        society_wrong = e(7, { society = "ncpd" }),
        bad_type = e(7, "ferrailleur"),
        bad_key = e(7, { grade = 1 }),
        bad_grade = e(7, { minGrade = 7 }),
        bad_fraction = e(7, { minGrade = 1.5 }),
        bad_duty = e(7, { duty = "yes" }),
        bad_list = e(7, { job = { "ncpd", x = "trauma" } }),
        empty_list = e(7, { job = {} }),
        unknown_job = e(7, { job = "astronaut" }),
        bad_epoch = e(7, { epoch = "1" }),
        bad_id = e("abc", nil),
        zero_id = e(0, nil),
        unknown_player = e(99, nil),
    }
    local ok, epoch = ex.eligible(7, { job = "ferrailleur" })
    r.ok_returns_current_epoch = tostring(ok == true and type(epoch) == "number" and epoch == ex.workEpoch(7))
    cmd("service", 7)
    r.duty_after_service = e(7, { job = "ferrailleur", duty = true })
    return r
end

-- ---------------------------------------------------------------------------
-- Work epochs: every job/grade/duty change invalidates work captured before it
-- ---------------------------------------------------------------------------

function scenarios.epoch_invalidation()
    local ex = boot("sql", players(7, 8))
    local function e(id, req) return verdict(ex.eligible(id, req)) end
    local REQ = { job = "ferrailleur", duty = true }
    local function at(epoch) return { job = "ferrailleur", duty = true, epoch = epoch } end
    cmd("setjob", 0, "7", "ferrailleur", "0")
    cmd("service", 7)
    H.events = {}
    local r = {}

    local _, e0 = ex.eligible(7, REQ)                     -- captured when the work begins
    r.commit_unchanged = e(7, at(e0))
    cmd("service", 7)                                     -- duty off ...
    cmd("service", 7)                                     -- ... and on again
    r.after_duty_cycle_eligible = e(7, REQ)
    r.after_duty_cycle_commit = e(7, at(e0))

    local _, e1 = ex.eligible(7, REQ)
    cmd("setjob", 0, "7", "ferrailleur", "1")             -- grade change, same employer, duty kept
    r.after_grade_still_on_duty = tostring(ex.onDuty(7))
    r.after_grade_commit = e(7, at(e1))

    local _, e2 = ex.eligible(7, REQ)
    cmd("setjob", 0, "7", "ferrailleur", "1")             -- no change at all
    ex.setJob(7, "ferrailleur", 1)                        -- no change either
    r.noop_keeps_epoch = e(7, at(e2))

    local _, e3 = ex.eligible(7, nil)
    ex.setJob(7, "mecano", 0)                             -- job change (clears duty first)
    r.after_job_change_commit = e(7, { epoch = e3 })
    r.after_job_change_duty = tostring(ex.onDuty(7))

    local _, e4 = ex.eligible(7, nil)
    cmd("setjob", 0, "7", "none")
    r.after_removal_commit = e(7, { epoch = e4 })

    local reasons = {}
    for _, ev in ipairs(epochEvents(7)) do reasons[#reasons + 1] = ev.reason end
    r.event_reasons = table.concat(reasons, ",")
    local events = epochEvents(7)
    r.last_event_is_current = tostring(events[#events].epoch == ex.workEpoch(7))
    local increasing = true
    for i = 2, #events do
        if not (events[i].epoch > events[i - 1].epoch) then increasing = false end
    end
    r.events_increase = tostring(increasing)

    -- setDuty (the foreman path) moves the epoch too, and answers the new one.
    ex.setJob(7, "ferrailleur", 0)
    local _, e5 = ex.eligible(7, nil)
    local ok, e6 = ex.setDuty(7, true, { job = "ferrailleur" })
    r.setDuty_answer = tostring(ok) .. ":" .. tostring(e6 == ex.workEpoch(7) and e6 ~= e5)
    r.setDuty_commit_old = e(7, { epoch = e5 })
    r.setDuty_commit_new = e(7, at(e6))
    local _, again = ex.setDuty(7, true)
    r.setDuty_noop_keeps_epoch = tostring(again == e6)

    -- Disconnect: duty off (new epoch), then the file is gone (false).
    local _, e7 = ex.eligible(7, nil)
    disconnect(7)
    local tail = epochEvents(7)
    r.disconnect_events = ("%s,%s:%s"):format(tail[#tail - 1].reason, tostring(tail[#tail].epoch), tail[#tail].reason)
    r.after_disconnect = e(7, { epoch = e7 })
    r.after_disconnect_epoch = reason(ex.workEpoch(7))

    -- Seat reuse: another account on seat 7 never inherits an old epoch.
    connect(7, { identifier = "acct-panam", name = "Panam" })
    local _, e8 = ex.eligible(7, nil)
    r.seat_reuse_commit_old = e(7, { epoch = e7 })
    r.seat_reuse_new_epoch = tostring(type(e8) == "number" and e8 ~= e7)
    r.epochs_distinct_between_players = tostring(ex.workEpoch(7) ~= ex.workEpoch(8))

    -- Restart of rp_jobs: every file gets a fresh epoch, so nothing captured before survives.
    local before = ex.workEpoch(8)
    ex = boot("sql", players(8))
    r.restart_commit_old = e(8, { epoch = before })
    r.restart_loaded_event = tostring(#epochEvents(8) >= 1 and epochEvents(8)[1].reason == "loaded")
    return r
end

-- ---------------------------------------------------------------------------
-- Forged prompts grant nothing: the server re-decides every request
-- ---------------------------------------------------------------------------

function scenarios.forged_prompts()
    local ex = boot("sql", players(7, 8, 9))
    cmd("setjob", 0, "9", "ncpd", "3")
    local r = {}

    -- The ALT+click hire action is drawn only for bosses, but the net event is forgeable.
    net("rp_jobs:hire", 8, 7)
    r.forged_hire_by_jobless = tostring(ex.getJob(7))
    r.forged_hire_answer = lastChat(8)
    net("rp_jobs:hire", 9, "not-a-player")
    r.forged_hire_bad_target = tostring(ex.getJob(7))
    H.distances["9:7"] = 10.0
    net("rp_jobs:hire", 9, 7)
    r.boss_out_of_range = tostring(ex.getJob(7))
    H.distances["9:7"] = 2.0
    net("rp_jobs:hire", 9, 7)
    r.boss_in_range = tostring(ex.getJob(7)) .. ":" .. tostring(ex.getGrade(7).level)

    -- The agency prompt from far away: the server measures, the menu never opens.
    H.positions[8] = { x = 0.0, y = 0.0, z = 0.0 }
    net("rp_jobs:agency", 8)
    r.agency_far_menu_opened = tostring(H.uikitCalls)

    -- A consumer that pays only on the server's verdict (the B5 commit shape): whatever
    -- prompt a client showed or forged, the grant follows rp_jobs:eligible alone.
    local granted = 0
    local function commit(pid, captured)
        local ok, why = ex.eligible(pid, { job = "ferrailleur", duty = true, epoch = captured })
        if ok then granted = granted + 1 return "granted" end
        return tostring(why)
    end
    r.forged_by_jobless = commit(8, nil)
    r.forged_by_other_job = commit(7, nil)
    ex.setJob(8, "ferrailleur", 0)
    r.forged_off_duty = commit(8, nil)
    ex.setDuty(8, true)
    r.forged_epoch = commit(8, 12345)
    local _, captured = ex.eligible(8, { job = "ferrailleur", duty = true })
    r.legitimate = commit(8, captured)
    r.replayed_after_duty_change = (function()
        ex.setDuty(8, false)
        ex.setDuty(8, true)
        return commit(8, captured)
    end)()
    r.granted = tostring(granted)
    return r
end

-- ---------------------------------------------------------------------------
-- Persistence: SQL round trip, duty reset, ordered and retried writes
-- ---------------------------------------------------------------------------

function scenarios.persistence_round_trip()
    local ex = boot("sql", players(7))
    local r = {}
    cmd("setjob", 0, "7", "ferrailleur", "2")
    cmd("service", 7)
    r.row_on_duty = rowText("acct-0007")
    r.row_hired_by = tostring(rows()["acct-0007"].hired_by)

    -- Crash (no stop handler), then a new boot: job and grade back, duty cleared in SQL too.
    ex = boot("sql", players(7))
    r.after_restart = tostring(ex.getJob(7)) .. ":" .. tostring(ex.getGrade(7).level) .. ":duty=" .. tostring(ex.onDuty(7))
    r.row_after_restart = rowText("acct-0007")

    cmd("service", 7)
    r.row_duty_on = rowText("acct-0007")
    disconnect(7)
    r.row_after_disconnect = rowText("acct-0007")
    connect(7, P7)
    r.after_reconnect = tostring(ex.getJob(7)) .. ":duty=" .. tostring(ex.onDuty(7))
    r.greeted = tostring(lastChat(7):find("Welcome back", 1, true) ~= nil)

    cmd("setjob", 0, "7", "none")
    r.row_after_removal = rowText("acct-0007")

    -- Completions arrive later (the bridge's own pace): one write in flight per subject,
    -- the next one built from the newest state, so SQL ends on the last change.
    H.deferSql = true
    H.sqlCount = {}
    cmd("setjob", 0, "7", "ferrailleur", "0")
    cmd("setjob", 0, "7", "ferrailleur", "2")
    cmd("setjob", 0, "7", "mecano", "1")
    r.in_flight = tostring(#H.sqlQueue)
    H.drainSql()
    r.writes_submitted = tostring(H.sqlCount.INSERT or 0)
    r.row_after_burst = rowText("acct-0007")

    -- A quick reconnect while a write is still in flight reads the newer memory state.
    cmd("setjob", 0, "7", "nomade", "2")
    disconnect(7)
    connect(7, P7)
    r.reconnect_during_write = tostring(ex.getJob(7)) .. ":" .. tostring(ex.getGrade(7).level)
    H.drainSql()
    r.row_after_reconnect = rowText("acct-0007")
    H.deferSql = false

    -- An unreachable database: the write is retried until it lands.
    H.failWrites = 2
    cmd("setjob", 0, "7", "vigile", "1")
    r.row_during_outage = rowText("acct-0007")
    H.run(10)
    r.row_after_retry = rowText("acct-0007")
    r.retry_logged = tostring(hasLog("SQL write for acct-0007 failed"))
    r.kvp_employment_keys = tostring(count("^emp:", H.stores.kvp))
    return r
end

-- ---------------------------------------------------------------------------
-- No KVP fork: a configured database that is down refuses; it never forks
-- ---------------------------------------------------------------------------

function scenarios.no_kvp_fork()
    local ex = boot("sql", players(7))
    cmd("setjob", 0, "7", "ferrailleur", "2")
    local r = {}

    ex = boot("late", players(7))                         -- configured, not answering
    r.pending_getJob = tostring(ex.getJob(7))
    r.pending_hasJob = tostring(ex.hasJob(7, "ferrailleur"))
    r.pending_eligible = verdict(ex.eligible(7, { job = "ferrailleur" }))
    r.pending_setJob = reason(ex.setJob(7, "ncpd", 0))
    r.pending_workEpoch = reason(ex.workEpoch(7))
    r.pending_setDuty = reason(ex.setDuty(7, true))
    cmd("service", 7)
    r.pending_service_answer = lastChat(7)
    cmd("setjob", 0, "7", "ncpd", "0")
    r.pending_setjob_logged = tostring(hasLog("job file is not loaded (store_unavailable)"))
    r.pending_watchdog_logged = tostring(hasLog("store=pending after 15 s"))
    r.kvp_employment_keys = tostring(count("^emp:", H.stores.kvp))
    r.sql_row_untouched = rowText("acct-0007")

    H.dbMode = "sql"                                      -- the database answers, same boot
    CreateThread(H.lateReady)
    H.run(2)
    r.late_answer = tostring(ex.getJob(7)) .. ":" .. tostring(ex.getGrade(7).level)
    r.late_eligible = verdict(ex.eligible(7, { job = "ferrailleur", minGrade = 2 }))

    H.failSchema = "database_request_failed (SQL 1142): CREATE command denied"
    ex = boot("sql", players(7))
    r.schema_failed = verdict(ex.eligible(7, nil))
    r.schema_failed_logged = tostring(hasLog("store=refused"))

    -- An unreachable database during the schema step is waited for, not refused.
    H.failSchema = "database_unreachable (SQL 2003): Can't connect to MySQL server"
    H.failSchemaTimes = 2
    ex = boot("sql", players(7))
    r.schema_transient = tostring(ex.getJob(7)) .. ":" .. tostring(hasLog("schema statement failed")) ..
        ":" .. tostring(hasLog("store=refused"))
    H.failSchema, H.failSchemaTimes = nil, nil

    ex = boot("none", players(7), { LabKvpWithoutDatabase = false })
    r.no_database_refused = verdict(ex.eligible(7, nil))
    r.no_database_refused_kvp = tostring(count("^emp:", H.stores.kvp))

    ex = boot("none", players(7))                         -- the explicit lab store
    r.lab_store_logged = tostring(hasLog("store=kvp reason=database_unavailable"))
    r.lab_store_job = tostring(ex.getJob(7))
    ex.setJob(7, "ncpd", 1)
    r.lab_store_keys = tostring(count("^emp:", H.stores.kvp))

    ex = boot("sql", players(7))                          -- nothing from the lab store leaks back
    r.sql_after_lab = tostring(ex.getJob(7)) .. ":" .. tostring(ex.getGrade(7).level)
    return r
end

-- ---------------------------------------------------------------------------
-- Compatibility of the existing exports and events
-- ---------------------------------------------------------------------------

function scenarios.compat_exports()
    local ex = boot("sql", players(7, 8, 9))
    local r = {
        getJob_unknown = tostring(ex.getJob(99)),
        hasJob_unknown = tostring(ex.hasJob(99, "ncpd")),
        getGrade_unknown = tostring(ex.getGrade(99)),
        isBoss_unknown = tostring(ex.isBoss(99)),
        onDuty_unknown = tostring(ex.onDuty(99)),
        set_bad_id = reason(ex.setJob("x", "ncpd", 0)),
        set_unknown_player = reason(ex.setJob(99, "ncpd", 0)),
        set_unknown_job = reason(ex.setJob(7, "astronaut", 0)),
        set_reserved = reason(ex.setJob(7, "gang", 0)),
        set_bad_grade = reason(ex.setJob(7, "ncpd", 4)),
        set_alias = reason(ex.setJob(7, "taxi", 1)),
    }
    r.alias_job = tostring(ex.getJob(7))
    r.hasJob_alias = tostring(ex.hasJob(7, "taxi"))
    local grade = ex.getGrade(7)
    r.getGrade = tostring(grade.level) .. ":" .. grade.label
    r.isBoss_7 = tostring(ex.isBoss(7))
    ex.setJob(9, "ncpd", 3)
    r.isBoss_9 = tostring(ex.isBoss(9))
    ex.setJob(8, "ncpd", 0)
    ex.setDuty(9, true)
    ex.setDuty(8, true)
    r.listOnDuty = table.concat(ex.listOnDuty("police"), ",")
    r.listOnDuty_unknown = tostring(#ex.listOnDuty("astronaut"))
    r.salary = tostring(ex.salary("ncpd", 2))
    r.salary_bad = tostring(ex.salary("ncpd", 9))

    H.events = {}
    ex.setJob(9, "trauma", 1)
    local order = {}
    for _, e in ipairs(H.events) do
        if e.name == "rp_jobs:duty" then
            order[#order + 1] = ("duty(%s,%s,%s)"):format(tostring(e.args[1]), tostring(e.args[2]), tostring(e.args[3]))
        elseif e.name == "rp_jobs:changed" then
            order[#order + 1] = ("changed(%s,%s)"):format(tostring(e.args[1]), tostring(e.args[2]))
        elseif e.name == "rp_jobs:workEpoch" then
            order[#order + 1] = "epoch(" .. tostring(e.args[3]) .. ")"
        end
    end
    r.event_order = table.concat(order, " ")
    H.events = {}
    r.set_none = reason(ex.setJob(9, nil))
    r.after_none = tostring(ex.getJob(9))
    for _, e in ipairs(H.events) do
        if e.name == "rp_jobs:changed" then
            r.changed_none_payload = ("%s,%s"):format(tostring(e.args[1]), tostring(e.args[2]))
        end
    end
    r.setDuty_no_job = reason(ex.setDuty(9, true))
    r.setDuty_bad_value = reason(ex.setDuty(8, "on"))
    r.setDuty_wrong_job = reason(ex.setDuty(8, false, { job = "trauma" }))
    r.setDuty_off = reason(ex.setDuty(8, false, { job = "ncpd" }))
    r.after_setDuty_off = tostring(ex.onDuty(8))

    -- Commands keep their answers.
    cmd("service", 9)
    r.service_jobless = lastChat(9)
    cmd("setjob", 0, "9", "astronaut")
    r.setjob_unknown_logged = tostring(hasLog("Unknown job astronaut"))

    -- The admin diagnostic prints the server's verdict.
    cmd("jobcheck", 0, "8", "ncpd", "0", "duty")
    r.jobcheck_refused = tostring(hasLog("jobcheck player 8: refused off_duty (job=ncpd grade=0 duty=off"))
    cmd("jobcheck", 0, "8", "any")
    r.jobcheck_eligible = tostring(hasLog("jobcheck player 8: eligible epoch="))
    cmd("jobcheck", 0, "8", "astronaut")
    r.jobcheck_unknown = tostring(hasLog("jobcheck player 8: refused unknown_job"))
    return r
end

-- ---------------------------------------------------------------------------
-- Public summary: small, audience-appropriate, no private data
-- ---------------------------------------------------------------------------

function scenarios.public_summary()
    local ex = boot("sql", players(7, 8))
    local r = {}
    ex.setJob(7, "ncpd", 2)
    r.bag_off_duty = encode(H.bags["7"] and H.bags["7"].rp_jobs)
    ex.setDuty(7, true)
    r.bag_on_duty = encode(H.bags["7"].rp_jobs)
    local private = false
    for key in pairs(H.bags["7"].rp_jobs) do
        if key == "identifier" or key == "hiredBy" or key == "hired_by" or key == "hiredAt"
            or key == "salary" or key == "epoch" or key == "society" then private = true end
    end
    r.bag_has_private = tostring(private)
    r.bag_jobless = encode(H.bags["8"] and H.bags["8"].rp_jobs)
    r.summary_on_duty = encode(ex.summary(7))
    r.summary_jobless = encode(ex.summary(8))
    r.summary_unknown = reason(ex.summary(99))
    ex.setDuty(7, false)
    r.bag_after_clock_out = encode(H.bags["7"].rp_jobs)

    H.bagRefuse = "permission_denied:state.write"
    ex.setDuty(7, true)
    r.bag_refusal_logged = tostring(hasLog("public state key rp_jobs not written"))
    r.duty_despite_refusal = tostring(ex.onDuty(7))
    H.bagRefuse = nil

    ex = boot("sql", players(7), { PublicStateKey = false })
    ex.setDuty(7, true)
    r.bag_disabled = tostring(H.bags["7"] == nil)
    return r
end

-- ---------------------------------------------------------------------------
-- Durable keys through the subject provider rule
-- ---------------------------------------------------------------------------

function scenarios.subject_provider()
    local r = {}
    H.providers = { open77_transactions = { subjectOf = function() return "acct-0007~2" end } }
    local ex = boot("sql", players(7))
    ex.setJob(7, "ferrailleur", 0)
    r.keyed_by_provider = tostring(rows()["acct-0007~2"] ~= nil)
    r.not_keyed_by_account = tostring(rows()["acct-0007"] == nil)

    H.providers.open77_transactions.subjectOf = function() return nil, "subject_provider_unavailable" end
    ex = boot("sql", players(7))
    r.provider_refusal = verdict(ex.eligible(7, nil))

    H.providers = {}                                      -- coordinator not running
    ex = boot("sql", players(7))
    ex.setJob(7, "ncpd", 0)
    r.default_rule_key = tostring(rows()["acct-0007"] ~= nil)

    ex = boot("sql", players(7), { Subject = { resource = "open77_transactions", export = "subjectOf", required = true } })
    r.required_provider_missing = verdict(ex.eligible(7, nil))

    ex = boot("sql", {
        [7] = { identifier = "session:7", name = "x" },
        [8] = { identifier = "12", name = "y" },
        [9] = { identifier = string.rep("a", 65), name = "z" },
    })
    r.session_key = verdict(ex.eligible(7, nil))
    r.numeric_key = verdict(ex.eligible(8, nil))
    r.long_key = verdict(ex.eligible(9, nil))
    r.session_setJob = reason(ex.setJob(7, "ncpd", 0))
    r.rows_for_bad_keys = tostring((rows()["session:7"] or rows()["12"]) ~= nil)
    return r
end

-- The same rule against the REAL coordinator (697e9e2f): its default provider answers the account
-- identifier, one override (a character layer) re-keys employment, the override's refusal is
-- passed through, and its own key lint refuses session-like and all-digit keys.
local function startCoordinator()
    TXS.start({ tunables = { serverTag = "lab" } })
    for _ = 1, 64 do
        if TXS.ready() then break end
        TXS.step()
    end
    H.providers = { open77_transactions = TXS.syncTable(function() return "rp_jobs" end) }
end

function scenarios.subject_provider_real()
    local r = {}
    startCoordinator()
    local ex = boot("sql", players(7))
    ex.setJob(7, "mecano", 0)
    r.default_key = tostring(rows()["acct-0007"] and rows()["acct-0007"].job)
    H.providers.rp_identity_test = { characterOf = function(who)
        if who == 7 then return "acct-0007~3" end
        return nil, "no_character"
    end }
    r.register = tostring((TXS.callSync("rp_identity_test", "registerSubjectProvider", "characterOf")))
    ex = boot("sql", players(7, 8))
    ex.setJob(7, "ncpd", 0)
    r.override_key = tostring(rows()["acct-0007~3"] and rows()["acct-0007~3"].job)
    r.override_refusal = verdict(ex.eligible(8, nil))
    startCoordinator()   -- a fresh coordinator VM: no override provider
    ex = boot("sql", { [7] = { identifier = "session:7", name = "x" }, [8] = { identifier = "12", name = "y" } })
    r.session_key = verdict(ex.eligible(7, nil))
    r.numeric_key = verdict(ex.eligible(8, nil))
    r.rows_for_bad_keys = tostring((rows()["session:7"] or rows()["12"]) ~= nil)
    return r
end

function RUN_SCENARIO(name)
    local scenario = assert(scenarios[name], "unknown scenario " .. tostring(name))
    local result = scenario()
    local lines = {}
    for k, v in pairs(result) do lines[#lines + 1] = k .. "=" .. tostring(v) end
    table.sort(lines)
    return table.concat(lines, "\n")
end
