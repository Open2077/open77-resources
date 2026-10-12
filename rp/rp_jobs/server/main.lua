-- rp_jobs v2.1 -- server-authoritative jobs, grades, bosses, duty and payroll.
--
-- One job per player, a grade 0..3 (recruit, employee, senior, boss), a duty
-- switch and a society per job (rp_bank). Everything is decided here: the
-- client only renders the agency ring, the ALT+click hire action and the
-- on-duty nameplate tags.
--
-- Persistence: SQL table rp_jobs_employees keyed by the durable subject (the
-- account id through the subject provider rule), mirrored in an in-memory
-- cache so every export answers synchronously and never yields. Writes are
-- serialized per subject and coalesced, so SQL always converges on the last
-- state. A server WITH a database never falls back to KVP: while it does not
-- answer, job files stay unloaded and changes are refused (store_unavailable).
-- A server with NO database configured may use the resource's KVP file as an
-- explicit, disposable lab store (RpJobsConfig.LabKvpWithoutDatabase). Duty is
-- never restored: it is cleared on disconnect, on resource stop and at boot.
--
-- Exports (synchronous, never yield):
--   getJob(playerId) -> name | nil
--   hasJob(playerId, name)              (aliases police->ncpd, medecin->trauma, taxi->delamain)
--   getGrade(playerId) -> { level, label } | nil
--   isBoss(playerId) -> boolean
--   onDuty(playerId) -> boolean
--   setJob(playerId, name | nil, grade) -> true | nil, reason
--   listOnDuty(name) -> { playerId, ... }
--   salary(name, level) -> integer
--   eligible(playerId, requirement) -> true, epoch | nil, reason      (B4: authoritative eligibility)
--   workEpoch(playerId) -> epoch | nil, reason                       (B4: pending-work invalidation)
--   summary(playerId) -> { job, label, grade, gradeLabel, onDuty } | nil, reason
--   setDuty(playerId, onDuty, requirement?) -> true, epoch | nil, reason
-- Host-wide events:
--   rp_jobs:changed   (playerId, name | nil)
--   rp_jobs:duty      (playerId, name, onDuty)
--   rp_jobs:workEpoch (playerId, epoch | false, reason)

local RESOURCE = GetCurrentResourceName()
local C = RpJobsConfig
local DB = Open77.database -- alias: the `.await` read form is reached through it inside handlers only

---------------------------------------------------------------------------
-- Job table helpers
---------------------------------------------------------------------------

local JOB_BY_NAME = {}
local JOB_NAMES = {}
for _, job in ipairs(C.Jobs) do
    JOB_BY_NAME[job.name] = job
    if not job.reserved then
        JOB_NAMES[#JOB_NAMES + 1] = job.name
    end
end
local JOB_NAMES_TEXT = table.concat(JOB_NAMES, " ")

-- Canonical job name for a user-supplied string (aliases honoured), or nil.
local function normalizeJob(name)
    if type(name) ~= "string" then
        return nil
    end
    local lower = string.lower(name)
    lower = C.Aliases[lower] or lower
    if JOB_BY_NAME[lower] then
        return lower
    end
    return nil
end

local function gradeLabel(level)
    local grade = C.Grades[level]
    return grade and grade.label or ("grade " .. tostring(level))
end

local function salaryOf(jobName, level)
    local job = JOB_BY_NAME[jobName]
    if not job or not job.salary then
        return 0
    end
    local amount = job.salary[level]
    if type(amount) ~= "number" or amount < 0 then
        return 0
    end
    return math.floor(amount)
end

local function isValidGrade(level)
    return type(level) == "number" and level % 1 == 0 and C.Grades[level] ~= nil
end

-- The rp_bank society a job pays from and is paid into: the job name, unless the
-- job row names another one (`society = "..."` in RpJobsConfig.Jobs).
local function societyOf(jobName)
    local job = JOB_BY_NAME[jobName]
    if not job then
        return nil
    end
    return string.lower(job.society or job.name)
end

---------------------------------------------------------------------------
-- State (keyed by session player id; the identifier inside is durable)
---------------------------------------------------------------------------

-- [playerId] = { identifier, loaded, job, grade, hiredAt, hiredBy, onDuty, epoch,
--                unavailable (why the file is not loaded), waiting (for the store) }
local records = {}

-- "pending" (a database is configured but has not answered), "sql", "lab_kvp"
-- (no database configured, explicit lab store) or "refused" (no store at all).
local storeState = "pending"
local storeReason = nil

---------------------------------------------------------------------------
-- Small helpers
---------------------------------------------------------------------------

local function log(fmt, ...)
    print(("[rp_jobs] " .. fmt):format(...))
end

local function eddies(amount)
    local text = tostring(math.floor(tonumber(amount) or 0))
    local sign = ""
    if text:sub(1, 1) == "-" then
        sign, text = "-", text:sub(2)
    end
    local grouped = text:reverse():gsub("(%d%d%d)", "%1 "):reverse()
    grouped = grouped:gsub("^ ", "")
    return sign .. grouped .. " €$"
end

-- Chat to one player. playerId must already be a number.
local function tell(playerId, text)
    local ok, reason = Open77.chat.send(playerId, { author = C.ChatAuthor, text = text, color = C.ChatColor })
    if not ok then
        log("chat to player %s refused: %s", tostring(playerId), tostring(reason))
    end
    return ok
end

-- Console (source 0) gets print, a player gets chat.
local function answer(source, text)
    if source == 0 then
        print("[rp_jobs] " .. text)
    else
        tell(source, text)
    end
end

local function toPlayerId(value)
    local id = tonumber(value)
    if id == nil or id < 1 or id % 1 ~= 0 then
        return nil
    end
    return math.floor(id)
end

-- The name other players read: the RP identity when rp_identity runs, else the account name.
local function displayName(playerId)
    local ok, name = pcall(function()
        return exports.rp_identity:fullName(playerId)
    end)
    if ok and type(name) == "string" and name ~= "" then
        return name
    end
    return Open77.players.name(playerId) or ("citizen #" .. tostring(playerId))
end

local function loadedRecord(playerId)
    local rec = records[playerId]
    if rec and rec.loaded then
        return rec
    end
    return nil
end

-- Why a record is not usable, as an export reason token.
local function unavailableReason(rec)
    if not rec then
        return "player_not_found"
    end
    return rec.unavailable or "not_loaded"
end

-- The chat line for a player whose file is not loaded.
local function notReadyText(rec)
    local why = rec and rec.unavailable
    if why == "store_unavailable" then
        if storeState == "pending" then
            return "Job records are offline (the database is not answering). Nothing was changed: try again in a moment."
        end
        return "Job records are unavailable on this server. Nothing was changed."
    end
    if why then
        return ("Your job file cannot be opened (%s). Reconnect in a moment."):format(why)
    end
    return "Your file is still loading, try again in a moment."
end

-- Every on-duty employee of one job, ascending player id.
local function onDutyIds(jobName)
    local ids = {}
    for _, playerId in ipairs(Open77.players.all()) do
        local rec = records[playerId]
        if rec and rec.loaded and rec.onDuty and rec.job == jobName then
            ids[#ids + 1] = playerId
        end
    end
    return ids
end

local function tellColleagues(playerId, jobName, text)
    for _, other in ipairs(onDutyIds(jobName)) do
        if other ~= playerId then
            tell(other, text)
        end
    end
end

---------------------------------------------------------------------------
-- Subjects: the durable key a job file is stored under
---------------------------------------------------------------------------

-- A key that is a session id, a bare number or too long for the column is refused:
-- seats are reused, runtime ids die with the boot (A13 contract section 3.1.1).
local function subjectProblem(key)
    if type(key) ~= "string" or key == "" then
        return "subject_unavailable"
    end
    if #key > 64 or key:find("%c") or key:lower():sub(1, 7) == "session" or key:match("^%d+$") then
        return "invalid_key"
    end
    return nil
end

-- The subject provider rule: ask the coordinator's provider when it runs, else the
-- account id it would answer by default. Never builds a key from the session id.
local function subjectOf(playerId)
    local provider = C.Subject or {}
    if type(provider.resource) == "string" and provider.resource ~= "" then
        local api = Open77.exports
        local ok, key, why = false, nil, nil
        if type(api) == "table" and type(api.callSync) == "function" then
            ok, key, why = pcall(api.callSync, provider.resource, provider.export or "subjectOf", playerId)
        end
        if ok then
            if key == nil then
                return nil, (type(why) == "string" and why ~= "") and why or "subject_unavailable"
            end
            local bad = subjectProblem(key)
            if bad then
                return nil, bad
            end
            return key
        end
        if provider.required then
            return nil, "subject_unavailable"
        end
    end
    local key = Open77.players.identifier(playerId)
    local bad = subjectProblem(key)
    if bad then
        return nil, bad
    end
    return key
end

---------------------------------------------------------------------------
-- Work epochs: one counter per loaded file, moved by every job/grade/duty change
---------------------------------------------------------------------------

-- Epochs are integers drawn from one sequence for the whole resource generation,
-- starting at the boot's wall clock in milliseconds. So an epoch never repeats for
-- another player who later takes the same seat, nor after a restart of rp_jobs:
-- compare epochs with == only, never by order.
local epochFloor = nil
local epochSeq = 0

local function nextEpoch()
    if epochFloor == nil then
        epochFloor = math.floor((tonumber(Open77.time.unix()) or 0) * 1000)
    end
    epochSeq = epochSeq + 1
    return epochFloor + epochSeq
end

-- epoch is false when the player has no loaded file any more.
local function publishEpoch(playerId, epoch, reason)
    local ok, why = TriggerEvent("rp_jobs:workEpoch", playerId, epoch, reason)
    if ok == false then
        log("rp_jobs:workEpoch for player %d not published: %s", playerId, tostring(why))
    end
end

local function bump(playerId, rec, reason)
    rec.epoch = nextEpoch()
    log("player %d work epoch=%d (%s)", playerId, rec.epoch, reason)
    publishEpoch(playerId, rec.epoch, reason)
end

---------------------------------------------------------------------------
-- Persistence: SQL, or the explicit no-database lab store; never a fallback
---------------------------------------------------------------------------

local SCHEMA = [[
CREATE TABLE IF NOT EXISTS rp_jobs_employees (
    identifier VARCHAR(64) NOT NULL,
    job        VARCHAR(32) NOT NULL,
    grade      TINYINT     NOT NULL DEFAULT 0,
    on_duty    TINYINT(1)  NOT NULL DEFAULT 0,
    hired_at   BIGINT      NOT NULL DEFAULT 0,
    hired_by   VARCHAR(80) NOT NULL DEFAULT '',
    PRIMARY KEY (identifier)
)
]]

local UPSERT = "INSERT INTO rp_jobs_employees (identifier, job, grade, on_duty, hired_at, hired_by) VALUES (?, ?, ?, ?, ?, ?) "
    .. "ON DUPLICATE KEY UPDATE job = ?, grade = ?, on_duty = ?, hired_at = ?, hired_by = ?"

-- Duty is never restored, so a flag left at 1 by a crash is cleared before anyone loads.
local CLEAR_STALE_DUTY = "UPDATE rp_jobs_employees SET on_duty = 0 WHERE on_duty <> 0"

-- A failed write is retried with backoff; a database that is merely unreachable is
-- retried for as long as it takes, any other failure this many times.
local MAX_WRITE_ATTEMPTS = 4

local function kvpKey(identifier)
    return "emp:" .. identifier
end

local function storeReady()
    return storeState == "sql" or storeState == "lab_kvp"
end

-- A completion failed when it carries a reason and no result.
local function failed(result, why)
    return why ~= nil and (result == nil or result == false)
end

local function transient(why)
    return tostring(why):find("database_unreachable", 1, true) ~= nil
end

-- [identifier] = { rec, dirty, writing, failures }: at most one statement in flight per
-- subject, built from the newest record when it leaves, so two changes can never land
-- in SQL out of order (the bridge does not serialize one resource's requests).
local writers = {}

local function rowStatement(rec)
    if rec.job then
        local duty = rec.onDuty and 1 or 0
        return UPSERT, { rec.identifier, rec.job, rec.grade, duty, rec.hiredAt or 0, rec.hiredBy or "",
                         rec.job, rec.grade, duty, rec.hiredAt or 0, rec.hiredBy or "" }
    end
    return "DELETE FROM rp_jobs_employees WHERE identifier = ?", { rec.identifier }
end

local flush
flush = function(identifier)
    local w = writers[identifier]
    if not w or w.writing then
        return
    end
    if not w.dirty then
        writers[identifier] = nil
        return
    end
    w.dirty = false
    w.writing = true
    local sql, params = rowStatement(w.rec)
    Open77.database.update(sql, params, function(result, why)
        w.writing = false
        if failed(result, why) then
            w.failures = w.failures + 1
            w.dirty = true
            if transient(why) or w.failures < MAX_WRITE_ATTEMPTS then
                local delay = math.floor(math.min(30000, 1000 * 2 ^ math.min(w.failures - 1, 5)))
                log("SQL write for %s failed (%s): attempt %d, retry in %d s", identifier, tostring(why),
                    w.failures, delay // 1000)
                SetTimeout(delay, function()
                    flush(identifier)
                end)
            else
                log("SQL write for %s failed %d times (%s): memory and SQL disagree until the next change",
                    identifier, w.failures, tostring(why))
            end
            return
        end
        w.failures = 0
        flush(identifier)
    end)
end

-- Write the whole record through (job present) or delete it (no job).
local function persist(rec)
    if storeState == "sql" then
        local w = writers[rec.identifier]
        if not w then
            w = { rec = rec, dirty = false, writing = false, failures = 0 }
            writers[rec.identifier] = w
        end
        w.rec = rec
        w.dirty = true
        w.failures = 0
        flush(rec.identifier)
        return
    end
    if storeState ~= "lab_kvp" then
        -- Unreachable: a record is only loaded once the store is ready.
        log("write for %s dropped: store=%s", rec.identifier, storeState)
        return
    end
    local ok, reason
    if rec.job then
        ok, reason = Open77.kvp.set(kvpKey(rec.identifier),
            ("%s|%d|%d|%s"):format(rec.job, rec.grade, rec.hiredAt or 0, rec.hiredBy or ""))
    else
        ok, reason = Open77.kvp.delete(kvpKey(rec.identifier))
        if not ok and reason == nil then
            ok = true -- absent key: nothing to delete
        end
    end
    if not ok then
        log("kvp write for %s failed: %s", rec.identifier, tostring(reason))
    end
end

local function persistDuty(rec)
    if storeState == "sql" and rec.job then
        persist(rec)
    end
    -- The lab KVP store does not keep duty: it is cleared on every disconnect anyway.
end

-- Read one record into `rec` (yields; call from a handler, never from an export).
-- Returns true when the store answered (even with no row), false on a failed read.
local function loadRecord(rec)
    if storeState == "sql" then
        -- A write for this subject still in flight (a quick reconnect) is newer than SQL.
        local w = writers[rec.identifier]
        if w and w.rec ~= rec and (w.dirty or w.writing) then
            local newer = w.rec
            rec.job, rec.grade, rec.hiredAt, rec.hiredBy = newer.job, newer.grade, newer.hiredAt, newer.hiredBy
            w.rec = rec
            return true
        end
        local ok, row, reason = pcall(function()
            return DB.single.await("SELECT job, grade, hired_at, hired_by FROM rp_jobs_employees WHERE identifier = ?",
                { rec.identifier })
        end)
        if not ok then
            log("SQL read for %s raised: %s", rec.identifier, tostring(row))
            return false
        end
        if row == nil and reason ~= nil then
            log("SQL read for %s failed: %s", rec.identifier, tostring(reason))
            return false
        end
        if row and JOB_BY_NAME[row.job] then
            rec.job = row.job
            rec.grade = isValidGrade(tonumber(row.grade)) and tonumber(row.grade) or 0
            rec.hiredAt = tonumber(row.hired_at) or 0
            rec.hiredBy = (type(row.hired_by) == "string" and row.hired_by ~= "") and row.hired_by or nil
        elseif row then
            log("%s holds unknown job %s in SQL: ignored", rec.identifier, tostring(row.job))
        end
        return true
    end
    if storeState ~= "lab_kvp" then
        return false
    end
    local stored = Open77.kvp.get(kvpKey(rec.identifier))
    if type(stored) == "string" then
        local job, grade, hiredAt, hiredBy = stored:match("^([%a_]+)|(%d+)|(%d+)|(.*)$")
        if job and JOB_BY_NAME[job] then
            rec.job = job
            rec.grade = isValidGrade(tonumber(grade)) and tonumber(grade) or 0
            rec.hiredAt = tonumber(hiredAt) or 0
            rec.hiredBy = (hiredBy ~= "") and hiredBy or nil
        else
            Open77.kvp.delete(kvpKey(rec.identifier))
        end
    end
    return true
end

---------------------------------------------------------------------------
-- Client presentation: on-duty nameplates, the public bag and the player's own state
---------------------------------------------------------------------------

local function plateFor(playerId, rec)
    if not rec or not rec.loaded or not rec.job or not rec.onDuty then
        return nil
    end
    local job = JOB_BY_NAME[rec.job]
    return { label = ("[%s] %s"):format(job.label, displayName(playerId)), color = job.color }
end

local function broadcastPlate(playerId)
    -- `false` stands for "no tag": a nil in the argument list would be a hole.
    TriggerClientEvent("rp_jobs:plate", -1, playerId, plateFor(playerId, records[playerId]) or false)
end

local function sendRoster(playerId)
    local roster = {}
    for _, other in ipairs(Open77.players.all()) do
        local plate = plateFor(other, records[other])
        if plate then
            roster[#roster + 1] = { playerId = other, label = plate.label, color = plate.color }
        end
    end
    TriggerClientEvent("rp_jobs:roster", playerId, roster)
end

local function sendSelf(playerId)
    local rec = records[playerId]
    if not rec then
        return
    end
    local job = rec.job and JOB_BY_NAME[rec.job] or nil
    TriggerClientEvent("rp_jobs:self", playerId, {
        job = rec.job or false,
        label = job and job.label or false,
        grade = rec.grade or 0,
        gradeLabel = gradeLabel(rec.grade or 0),
        boss = (job ~= nil) and rec.grade == C.BossGrade,
        onDuty = rec.onDuty == true,
    })
end

-- What everyone in the player's routing bucket may read: the same facts the on-duty
-- nameplate already shows, plus the grade label. Off duty, the job stays private.
-- Never the identifier, the hire record, the salary or the society balance.
local function publicSummary(rec)
    if rec and rec.loaded and rec.job and rec.onDuty then
        local job = JOB_BY_NAME[rec.job]
        return { job = rec.job, label = job.label, grade = gradeLabel(rec.grade), duty = true }
    end
    return { duty = false }
end

local bagWarned = false

local function publish(playerId, rec)
    local key = C.PublicStateKey
    local state = Open77.state
    if type(key) ~= "string" or key == "" or type(state) ~= "table" or type(state.player) ~= "function" then
        return
    end
    local ok, bag = pcall(state.player, playerId)
    if not ok or bag == nil then
        return
    end
    local called, set, why = pcall(function()
        return bag:set(key, publicSummary(rec))
    end)
    if (not called or set == false) and not bagWarned then
        bagWarned = true
        log("public state key %s not written: %s (logged once)", key, tostring(called and why or set))
    end
end

---------------------------------------------------------------------------
-- Mutations (the only places the cache changes; each one moves the work epoch)
---------------------------------------------------------------------------

local function setDuty(playerId, rec, on, why)
    if rec.onDuty == on then
        return false
    end
    rec.onDuty = on
    persistDuty(rec)
    log("player %d duty=%s job=%s (%s)", playerId, on and "on" or "off", tostring(rec.job), why)
    bump(playerId, rec, on and "duty_on" or "duty_off")
    local ok, reason = TriggerEvent("rp_jobs:duty", playerId, rec.job, on)
    if not ok then
        log("rp_jobs:duty for player %d not published: %s", playerId, tostring(reason))
    end
    broadcastPlate(playerId)
    if why ~= "disconnected" then
        publish(playerId, rec)
        sendSelf(playerId)
    end
    return true
end

-- Give (or take away, jobName == nil) a job. Duty is cleared first.
local function applyJob(playerId, rec, jobName, grade, hiredBy, why)
    if rec.onDuty then
        local previous = rec.job
        setDuty(playerId, rec, false, "job_changed")
        if previous then
            tellColleagues(playerId, previous,
                ("%s left the %s duty roster."):format(displayName(playerId), JOB_BY_NAME[previous].label))
        end
    end
    rec.job = jobName
    rec.grade = jobName and math.floor(grade) or 0
    if jobName then
        rec.hiredAt = math.floor(Open77.time.unix())
        rec.hiredBy = hiredBy
    else
        rec.hiredAt = nil
        rec.hiredBy = nil
    end
    persist(rec)
    log("player %d job=%s grade=%d (%s)", playerId, jobName or "none", rec.grade, why)
    bump(playerId, rec, "job_changed")
    local ok, reason = TriggerEvent("rp_jobs:changed", playerId, jobName)
    if not ok then
        log("rp_jobs:changed for player %d not published: %s", playerId, tostring(reason))
    end
    publish(playerId, rec)
    sendSelf(playerId)
end

local function setGrade(playerId, rec, grade, why)
    local level = math.floor(grade)
    local changed = rec.grade ~= level
    rec.grade = level
    persist(rec)
    log("player %d job=%s grade=%d (%s)", playerId, rec.job, level, why)
    if changed then
        bump(playerId, rec, "grade_changed")
    end
    sendSelf(playerId)
    if rec.onDuty then
        broadcastPlate(playerId)
        publish(playerId, rec)
    end
end

-- Clock in or out, with the chat lines /service has always sent.
local function clock(playerId, rec, on, why)
    local job = JOB_BY_NAME[rec.job]
    local name = displayName(playerId)
    if not on then
        setDuty(playerId, rec, false, why)
        tell(playerId, ("Clocked out of %s. Your tag is gone."):format(job.label))
        tellColleagues(playerId, rec.job, ("%s clocked out (%s)."):format(name, job.label))
        return
    end
    setDuty(playerId, rec, true, why)
    local colleagues = #onDutyIds(rec.job) - 1
    tell(playerId, ("Clocked in at %s as %s. %d colleague%s on duty. Payroll every %d min."):format(
        job.label, gradeLabel(rec.grade), colleagues, colleagues == 1 and "" or "s", math.floor(C.PayrollIntervalMs / 60000)))
    tellColleagues(playerId, rec.job, ("%s clocked in (%s, %s)."):format(name, job.label, gradeLabel(rec.grade)))
end

-- The society starts empty: the first boss of a job seeds it (once per job, ever).
-- The seed flag still lives in the resource's KVP file: it is economic state that moves
-- with the societies in the B3 wallet migration (B8 audit section 5.3).
local function seedSociety(jobName)
    local flag = "seeded:" .. jobName
    if Open77.kvp.get(flag, false) then
        return
    end
    local fund = math.floor(tonumber(C.SocietyStartingFund) or 0)
    if fund <= 0 then
        Open77.kvp.set(flag, true)
        return
    end
    local ok, balance, reason = pcall(function()
        return exports.rp_bank:societyAdd(jobName, fund, "seed")
    end)
    if not ok then
        log("society %s not seeded: rp_bank unavailable (%s)", jobName, tostring(balance))
        return
    end
    if balance == nil then
        log("society %s not seeded: %s", jobName, tostring(reason))
        return
    end
    Open77.kvp.set(flag, true)
    log("society %s seeded +%d balance=%s", jobName, fund, tostring(balance))
end

---------------------------------------------------------------------------
-- Payroll: every PayrollIntervalMs, the society pays each on-duty employee in cash
---------------------------------------------------------------------------

local function runPayroll()
    for _, playerId in ipairs(Open77.players.all()) do
        local rec = records[playerId]
        if rec and rec.loaded and rec.job and rec.onDuty then
            local job = JOB_BY_NAME[rec.job]
            local amount = salaryOf(rec.job, rec.grade)
            if amount > 0 then
                local okRemove, balance, reason = pcall(function()
                    return exports.rp_bank:societyRemove(rec.job, amount, "payroll")
                end)
                if not okRemove then
                    log("payroll player %d %s skipped: rp_bank unavailable (%s)", playerId, rec.job, tostring(balance))
                    tell(playerId, "Payroll skipped: the bank is offline.")
                elseif balance == nil then
                    log("payroll player %d %s refused: %s", playerId, rec.job, tostring(reason))
                    if reason == "insufficient_funds" then
                        tell(playerId, ("No payroll this time: the %s society is dry."):format(job.label))
                    else
                        tell(playerId, ("No payroll this time (%s)."):format(tostring(reason)))
                    end
                else
                    local okAdd, cash, addReason = pcall(function()
                        return exports.rp_economy:add(playerId, amount, "salary")
                    end)
                    if not okAdd or cash == nil then
                        pcall(function()
                            return exports.rp_bank:societyAdd(rec.job, amount, "payroll_refund")
                        end)
                        log("payroll player %d %s +%d failed: %s (society refunded)", playerId, rec.job, amount,
                            tostring(okAdd and addReason or cash))
                        tell(playerId, "Payroll failed: the wallet is offline. The society was refunded.")
                    else
                        log("payroll player %d %s grade=%d +%d cash=%s society=%s", playerId, rec.job, rec.grade,
                            amount, tostring(cash), tostring(balance))
                        tell(playerId, ("Payday from %s: +%s as %s. Cash: %s."):format(
                            job.label, eddies(amount), gradeLabel(rec.grade), eddies(cash)))
                    end
                end
            end
        end
    end
end

---------------------------------------------------------------------------
-- Hiring, firing, promoting (shared by the commands and the ALT+click action)
---------------------------------------------------------------------------

-- Returns the boss's record, or nil after telling the player why.
local function bossOf(source)
    local rec = records[source]
    if rec and not rec.loaded then
        tell(source, notReadyText(rec))
        return nil
    end
    if not rec or not rec.job then
        tell(source, "You have no job, choom. Nobody to hire, fire or promote.")
        return nil
    end
    if rec.grade ~= C.BossGrade then
        tell(source, ("Only the boss of %s can do that. You are %s."):format(
            JOB_BY_NAME[rec.job].label, gradeLabel(rec.grade)))
        return nil
    end
    return rec
end

-- Returns the target id and record, or nil after telling the caller why.
local function targetOf(source, value)
    local target = toPlayerId(value)
    if not target then
        tell(source, "Give a player id (see /players).")
        return nil
    end
    if target == source then
        tell(source, "That is you.")
        return nil
    end
    local rec = loadedRecord(target)
    if not rec then
        tell(source, ("Player %d is not here, or still loading."):format(target))
        return nil
    end
    return target, rec
end

local function withinHireRange(source, target)
    local metres, reason = Open77.players.distance(source, target)
    if not metres then
        tell(source, ("Cannot measure the distance to player %d (%s)."):format(target, tostring(reason)))
        return false
    end
    if metres > C.HireDistance then
        tell(source, ("Too far away (%d m). Get within %d m to hire someone."):format(
            math.floor(metres + 0.5), math.floor(C.HireDistance)))
        return false
    end
    return true
end

local function hire(source, target, grade)
    local boss = bossOf(source)
    if not boss then
        return
    end
    local _, trec = targetOf(source, target)
    if not trec then
        return
    end
    if not isValidGrade(grade) or grade >= C.BossGrade then
        tell(source, "Grade must be 0 (recruit), 1 (employee) or 2 (senior). A boss seat is transferred with /promouvoir <id> 3.")
        return
    end
    local job = JOB_BY_NAME[boss.job]
    if trec.job == boss.job then
        tell(source, ("%s already works for %s (%s)."):format(displayName(target), job.label, gradeLabel(trec.grade)))
        return
    end
    if trec.job then
        tell(source, ("%s already works for %s. They must resign first (/agence)."):format(
            displayName(target), JOB_BY_NAME[trec.job].label))
        return
    end
    if not withinHireRange(source, target) then
        return
    end
    applyJob(target, trec, boss.job, grade, boss.identifier, ("hired by player %d"):format(source))
    tell(source, ("You hired %s at %s as %s."):format(displayName(target), job.label, gradeLabel(grade)))
    tell(target, ("Welcome to %s, choom: %s hired you as %s. /service to clock in."):format(
        job.label, displayName(source), gradeLabel(grade)))
end

---------------------------------------------------------------------------
-- The employment agency menu (UI kit context, driven from the server)
---------------------------------------------------------------------------

local function distanceToAgency(playerId)
    local pos = Open77.players.position(playerId)
    if not pos then
        return nil
    end
    local a = C.Agency.position
    local dx, dy = pos.x - a.x, pos.y - a.y
    return math.sqrt(dx * dx + dy * dy)
end

local function agencyDefinition(rec)
    local options = {}
    for _, job in ipairs(C.Jobs) do
        if job.civil and not job.reserved then
            local current = rec.job == job.name
            options[#options + 1] = {
                id = "join:" .. job.name,
                label = job.label,
                description = current and "Your current employer." or job.description,
                disabled = current,
                metadata = {
                    { label = "Pay", value = ("%d-%d €$ / payroll"):format(salaryOf(job.name, 0), salaryOf(job.name, C.BossGrade)) },
                },
            }
        end
    end
    if rec.job then
        options[#options + 1] = {
            id = "resign",
            label = ("Resign from %s"):format(JOB_BY_NAME[rec.job].label),
            description = "Hand in the badge, the keys or the apron.",
            tone = "danger",
        }
    end
    options[#options + 1] = { id = "leave", label = "Leave" }
    return {
        id = "rp_jobs_agency",
        title = "Night City employment agency",
        description = "Open positions. NCPD, Trauma Team, rippers, fixers and netrunners recruit on their own.",
        options = options,
    }
end

-- Yields (the dialog waits for a human): call from a command or event handler.
-- The menu is pending work: a choice made under an older work epoch is refused.
local function openAgency(playerId)
    local rec = loadedRecord(playerId)
    if not rec then
        tell(playerId, notReadyText(records[playerId]))
        return
    end
    local epochAtOpen = rec.epoch
    local promise, dispatchError = Open77.exports.call("open77_uikit", "context", playerId, agencyDefinition(rec))
    if not promise then
        tell(playerId, ("The agency terminal is down (%s)."):format(tostring(dispatchError)))
        return
    end
    local result, reason = promise:await()
    if result == nil then
        log("agency menu for player %d never answered: %s", playerId, tostring(reason))
        tell(playerId, ("The agency terminal did not answer (%s)."):format(tostring(reason)))
        return
    end
    if not result.ok or type(result.value) ~= "table" then
        return -- cancelled or timed out: ordinary
    end
    local choice = tostring(result.value.id or "")
    local jobName = choice:match("^join:([%a_]+)$")
    local job = jobName and JOB_BY_NAME[jobName] or nil
    if choice ~= "resign" and (not job or not job.civil or job.reserved) then
        return -- "leave", or something the menu never offered
    end
    rec = loadedRecord(playerId)
    if not rec then
        return
    end
    if rec.epoch ~= epochAtOpen then
        log("agency choice %s for player %d refused: stale_job_epoch", choice, playerId)
        tell(playerId, "Your job file changed while the agency menu was open. Nothing was signed: open it again.")
        return
    end
    if choice == "resign" then
        if not rec.job then
            tell(playerId, "You have no job to resign from.")
            return
        end
        local label = JOB_BY_NAME[rec.job].label
        applyJob(playerId, rec, nil, 0, nil, "resigned")
        tell(playerId, ("You resigned from %s. The agency wishes you luck."):format(label))
        return
    end
    if rec.job == jobName then
        tell(playerId, ("You already work for %s."):format(job.label))
        return
    end
    applyJob(playerId, rec, jobName, 0, "agency", "agency")
    tell(playerId, ("Signed: you now work for %s as %s. /service to clock in, /job for your file."):format(
        job.label, gradeLabel(0)))
end

local function agencyRequest(playerId)
    if (tonumber(C.Agency.reach) or 0) > 0 then
        local metres = distanceToAgency(playerId)
        if not metres then
            tell(playerId, "Position unknown for now, try again in a moment.")
            return
        end
        if metres > C.Agency.reach then
            tell(playerId, ("The employment agency is %d m away (the ring and map pin on the Kabuki Gallery walkway). Walk over."):format(
                math.floor(metres + 0.5)))
            return
        end
    end
    openAgency(playerId)
end

---------------------------------------------------------------------------
-- Commands
---------------------------------------------------------------------------

local SUGGESTIONS = {
    { command = "/jobs", help = "Every job and who is on duty" },
    { command = "/job", help = "Your job, grade, duty state and society balance" },
    { command = "/service", help = "Clock in or out of your job" },
    { command = "/agence", help = "The employment agency: join a civil job or resign" },
    { command = "/embaucher", help = "Boss: hire a player standing next to you",
      parameters = { { name = "playerId", help = "the player to hire" }, { name = "grade", help = "0 recruit, 1 employee, 2 senior (default 0)" } } },
    { command = "/virer", help = "Boss: fire an employee",
      parameters = { { name = "playerId", help = "the employee" } } },
    { command = "/promouvoir", help = "Boss: change an employee's grade; 3 hands over the boss seat",
      parameters = { { name = "playerId", help = "the employee" }, { name = "grade", help = "0 recruit, 1 employee, 2 senior, 3 boss (transfer)" } } },
    { command = "/setjob", help = "Admin: give or remove a job",
      parameters = { { name = "playerId", help = "the player" }, { name = "job", help = "ncpd, trauma, ... or none" }, { name = "grade", help = "0..3 (default 0)" } } },
    { command = "/jobcheck", help = "Admin: the server's eligibility verdict and work epoch for a player",
      parameters = { { name = "playerId", help = "the player" }, { name = "job", help = "a job name, or any" },
                     { name = "minGrade", help = "0..3" }, { name = "duty", help = "duty = must be on duty" } } },
}

RegisterCommand("jobs", function(source)
    if source == 0 then
        print("[rp_jobs] /jobs: run it from the game, not from the console")
        return
    end
    local mine = loadedRecord(source)
    tell(source, "Night City job board:")
    for _, job in ipairs(C.Jobs) do
        if not job.reserved then
            Wait(0) -- two sends in one tick arrive reversed; one line per tick keeps the order
            local names = {}
            for _, other in ipairs(onDutyIds(job.name)) do
                names[#names + 1] = displayName(other)
            end
            local marker = (mine and mine.job == job.name) and " [yours]" or ""
            local who = (#names > 0) and ("on duty: " .. table.concat(names, ", ")) or "nobody on duty"
            tell(source, ("- %s (%s%s)%s: %s"):format(job.label, job.name, job.civil and ", agency" or "", marker, who))
        end
    end
    Wait(0)
    tell(source, "Civil jobs are joined at the agency (/agence). The others hire through their boss.")
end, false)

RegisterCommand("job", function(source)
    if source == 0 then
        print("[rp_jobs] /job: run it from the game, not from the console")
        return
    end
    local rec = loadedRecord(source)
    if not rec then
        tell(source, notReadyText(records[source]))
        return
    end
    if not rec.job then
        tell(source, "You have no job. /agence for the civil jobs, or get hired by a boss.")
        return
    end
    local job = JOB_BY_NAME[rec.job]
    tell(source, ("Job: %s (%s) - grade %d/%d %s - %s."):format(
        job.label, job.name, rec.grade, C.BossGrade, gradeLabel(rec.grade), rec.onDuty and "ON DUTY" or "off duty"))
    Wait(0)
    tell(source, ("Salary: %s per payroll (every %d min, on duty only)."):format(
        eddies(salaryOf(rec.job, rec.grade)), math.floor(C.PayrollIntervalMs / 60000)))
    Wait(0)
    local ok, society, reason = pcall(function()
        return exports.rp_bank:society(rec.job)
    end)
    if not ok then
        tell(source, "Society balance unavailable: the bank is offline.")
    elseif society == nil then
        tell(source, ("Society balance unavailable (%s)."):format(tostring(reason)))
    else
        tell(source, ("Society %s: %s."):format(job.label, eddies(society.balance)))
    end
end, false)

RegisterCommand("service", function(source)
    if source == 0 then
        print("[rp_jobs] /service: run it from the game, not from the console")
        return
    end
    local rec = loadedRecord(source)
    if not rec then
        tell(source, notReadyText(records[source]))
        return
    end
    if not rec.job then
        tell(source, "No job, no shift. /agence to find one.")
        return
    end
    clock(source, rec, not rec.onDuty, "player_request")
end, false)

RegisterCommand("agence", function(source)
    if source == 0 then
        print("[rp_jobs] /agence: run it from the game, not from the console")
        return
    end
    agencyRequest(source)
end, false)

RegisterCommand("embaucher", function(source, args)
    if source == 0 then
        print("[rp_jobs] /embaucher: run it from the game, not from the console (use setjob)")
        return
    end
    if not args[1] then
        tell(source, "Usage: /embaucher <playerId> [grade 0-2]")
        return
    end
    local grade = 0
    if args[2] then
        grade = tonumber(args[2])
        if not isValidGrade(grade) then
            tell(source, "Grade must be 0 (recruit), 1 (employee) or 2 (senior).")
            return
        end
    end
    local target = toPlayerId(args[1])
    if not target then
        tell(source, "Usage: /embaucher <playerId> [grade 0-2]")
        return
    end
    hire(source, target, grade)
end, false)

RegisterCommand("virer", function(source, args)
    if source == 0 then
        print("[rp_jobs] /virer: run it from the game, not from the console (use setjob <id> none)")
        return
    end
    local boss = bossOf(source)
    if not boss then
        return
    end
    local target, trec = targetOf(source, args[1])
    if not trec then
        return
    end
    if trec.job ~= boss.job then
        tell(source, ("%s does not work for %s."):format(displayName(target), JOB_BY_NAME[boss.job].label))
        return
    end
    local label = JOB_BY_NAME[boss.job].label
    applyJob(target, trec, nil, 0, nil, ("fired by player %d"):format(source))
    tell(source, ("%s is out of %s."):format(displayName(target), label))
    tell(target, ("%s fired you from %s. Hand in your badge, choom."):format(displayName(source), label))
end, false)

RegisterCommand("promouvoir", function(source, args)
    if source == 0 then
        print("[rp_jobs] /promouvoir: run it from the game, not from the console (use setjob)")
        return
    end
    local boss = bossOf(source)
    if not boss then
        return
    end
    local target, trec = targetOf(source, args[1])
    if not trec then
        return
    end
    local grade = tonumber(args[2])
    if not isValidGrade(grade) then
        tell(source, "Usage: /promouvoir <playerId> <grade 0-3>. 3 hands over your boss seat.")
        return
    end
    local job = JOB_BY_NAME[boss.job]
    if trec.job ~= boss.job then
        tell(source, ("%s does not work for %s."):format(displayName(target), job.label))
        return
    end
    if grade == C.BossGrade then
        -- The seat moves: the target becomes boss, the caller steps down to senior.
        setGrade(target, trec, C.BossGrade, ("boss seat from player %d"):format(source))
        setGrade(source, boss, C.BossGrade - 1, ("handed the boss seat to player %d"):format(target))
        tell(source, ("You handed the %s boss seat to %s. You are now %s."):format(
            job.label, displayName(target), gradeLabel(C.BossGrade - 1)))
        tell(target, ("%s made you the boss of %s. The society is yours to run."):format(displayName(source), job.label))
        tellColleagues(source, boss.job, ("%s is the new boss of %s."):format(displayName(target), job.label))
        return
    end
    if trec.grade == grade then
        tell(source, ("%s is already %s."):format(displayName(target), gradeLabel(grade)))
        return
    end
    local verb = (grade > trec.grade) and "promoted" or "demoted"
    setGrade(target, trec, grade, ("%s by player %d"):format(verb, source))
    tell(source, ("%s is now %s at %s."):format(displayName(target), gradeLabel(grade), job.label))
    tell(target, ("%s %s you: you are now %s at %s."):format(displayName(source), verb, gradeLabel(grade), job.label))
end, false)

-- Admin tool (ACL command.setjob, or the console): seeds bosses for testing.
RegisterCommand("setjob", function(source, args)
    local target = toPlayerId(args[1])
    if not target or not args[2] then
        answer(source, "Usage: setjob <playerId> <job|none> [grade 0-3]")
        return
    end
    local trec = loadedRecord(target)
    if not trec then
        local pending = records[target]
        if pending and pending.unavailable then
            answer(source, ("Player %d's job file is not loaded (%s): nothing changed."):format(target, pending.unavailable))
        else
            answer(source, ("Player %d is not here, or still loading."):format(target))
        end
        return
    end
    local by = (source == 0) and "console" or ("admin:" .. tostring(records[source] and records[source].identifier or source))
    local wanted = string.lower(args[2])
    if wanted == "none" then
        if not trec.job then
            answer(source, ("Player %d has no job."):format(target))
            return
        end
        local label = JOB_BY_NAME[trec.job].label
        applyJob(target, trec, nil, 0, nil, "setjob none by " .. by)
        answer(source, ("Player %d (%s) no longer works for %s."):format(target, displayName(target), label))
        tell(target, ("An admin removed you from %s."):format(label))
        return
    end
    local jobName = normalizeJob(wanted)
    if not jobName then
        answer(source, ("Unknown job %s. Jobs: %s, or none."):format(wanted, JOB_NAMES_TEXT))
        return
    end
    local job = JOB_BY_NAME[jobName]
    if job.reserved then
        answer(source, ("%s is reserved for a later resource."):format(jobName))
        return
    end
    local grade = 0
    if args[3] then
        grade = tonumber(args[3])
        if not isValidGrade(grade) then
            answer(source, "Grade must be 0, 1, 2 or 3.")
            return
        end
    end
    if trec.job == jobName then
        setGrade(target, trec, grade, "setjob by " .. by) -- same employer: keep duty and hire date
    else
        applyJob(target, trec, jobName, grade, by, "setjob by " .. by)
    end
    if grade == C.BossGrade then
        seedSociety(jobName)
    end
    answer(source, ("Player %d (%s) is now %s at %s."):format(target, displayName(target), gradeLabel(grade), job.label))
    tell(target, ("An admin made you %s at %s. /service to clock in."):format(gradeLabel(grade), job.label))
end, true)

---------------------------------------------------------------------------
-- Net events raised by this resource's own client script
---------------------------------------------------------------------------

RegisterNetEvent("rp_jobs:clientReady", function()
    local playerId = toPlayerId(source)
    if not playerId then
        return
    end
    sendRoster(playerId)
    sendSelf(playerId)
end)

-- The agency ring's E prompt; the distance is checked here again.
RegisterNetEvent("rp_jobs:agency", function()
    local playerId = toPlayerId(source)
    if not playerId then
        return
    end
    agencyRequest(playerId)
end)

-- ALT+click "Hire into <job>": the client only names the target it clicked.
RegisterNetEvent("rp_jobs:hire", function(targetPlayerId)
    local playerId = toPlayerId(source)
    local target = toPlayerId(targetPlayerId)
    if not playerId then
        return
    end
    if not target then
        tell(playerId, "That target is not a player.")
        return
    end
    hire(playerId, target, 0)
end)

---------------------------------------------------------------------------
-- Eligibility (B4): the server's answer, whatever a prompt showed the client
---------------------------------------------------------------------------

-- The loaded record of a player, or nil and the export reason token.
local function lookup(playerId)
    local id = toPlayerId(playerId)
    if not id then
        return nil, "invalid_player_id"
    end
    local rec = records[id]
    if not rec or not rec.loaded then
        return nil, unavailableReason(rec)
    end
    return rec, id
end

local REQUIREMENT_KEYS = { job = true, minGrade = true, duty = true, society = true, epoch = true }

-- requirement = { job = name | { name, ... }, minGrade = 0..3, duty = true, society = name, epoch = n }
-- Every field is optional; nil means "any loaded file". Unknown keys are refused, so a
-- typo (`grade` for `minGrade`) can never silently widen the requirement.
local function parseRequirement(requirement)
    if requirement == nil then
        return {}
    end
    if type(requirement) ~= "table" then
        return nil, "invalid_requirement"
    end
    for key in pairs(requirement) do
        if not REQUIREMENT_KEYS[key] then
            return nil, "invalid_requirement"
        end
    end
    local req = {}
    local jobs = requirement.job
    if jobs ~= nil then
        if type(jobs) == "string" then
            jobs = { jobs }
        elseif type(jobs) ~= "table" then
            return nil, "invalid_requirement"
        end
        local listed, count = 0, 0
        req.jobs = {}
        for _ in pairs(jobs) do
            count = count + 1
        end
        for _, name in ipairs(jobs) do
            local canonical = normalizeJob(name)
            if not canonical then
                return nil, "unknown_job"
            end
            req.jobs[canonical] = true
            listed = listed + 1
        end
        if listed == 0 or listed ~= count then
            return nil, "invalid_requirement"
        end
    end
    if requirement.minGrade ~= nil then
        if not isValidGrade(requirement.minGrade) then
            return nil, "invalid_requirement"
        end
        req.minGrade = math.floor(requirement.minGrade)
    end
    if requirement.duty ~= nil then
        if type(requirement.duty) ~= "boolean" then
            return nil, "invalid_requirement"
        end
        req.duty = requirement.duty -- false means "no duty constraint"
    end
    if requirement.society ~= nil then
        if type(requirement.society) ~= "string" or requirement.society == "" then
            return nil, "invalid_requirement"
        end
        req.society = string.lower(requirement.society)
    end
    if requirement.epoch ~= nil then
        if type(requirement.epoch) ~= "number" and requirement.epoch ~= false then
            return nil, "invalid_requirement"
        end
        req.checkEpoch, req.epoch = true, requirement.epoch
    end
    return req
end

-- nil when `rec` meets `req`, else the refusal token.
local function unmet(rec, req)
    if req.checkEpoch and req.epoch ~= rec.epoch then
        return "stale_job_epoch"
    end
    if (req.jobs or req.society or req.minGrade ~= nil or req.duty == true) and not rec.job then
        return "no_job"
    end
    if req.jobs and not req.jobs[rec.job] then
        return "wrong_job"
    end
    if req.society and societyOf(rec.job) ~= req.society then
        return "wrong_society"
    end
    if req.minGrade ~= nil and rec.grade < req.minGrade then
        return "grade_too_low"
    end
    if req.duty == true and not rec.onDuty then
        return "off_duty"
    end
    return nil
end

---------------------------------------------------------------------------
-- Exports (synchronous: they never yield, they read the cache only)
---------------------------------------------------------------------------

exports("getJob", function(playerId)
    local rec = loadedRecord(toPlayerId(playerId) or -1)
    return rec and rec.job or nil
end)

exports("hasJob", function(playerId, jobName)
    local rec = loadedRecord(toPlayerId(playerId) or -1)
    if not rec or not rec.job then
        return false
    end
    local wanted = normalizeJob(jobName)
    return wanted ~= nil and rec.job == wanted
end)

exports("getGrade", function(playerId)
    local rec = loadedRecord(toPlayerId(playerId) or -1)
    if not rec or not rec.job then
        return nil
    end
    return { level = rec.grade, label = gradeLabel(rec.grade) }
end)

exports("isBoss", function(playerId)
    local rec = loadedRecord(toPlayerId(playerId) or -1)
    return rec ~= nil and rec.job ~= nil and rec.grade == C.BossGrade
end)

exports("onDuty", function(playerId)
    local rec = loadedRecord(toPlayerId(playerId) or -1)
    return rec ~= nil and rec.job ~= nil and rec.onDuty == true
end)

exports("setJob", function(playerId, jobName, grade)
    local id = toPlayerId(playerId)
    if not id then
        return nil, "invalid_player_id"
    end
    local rec = records[id]
    if not rec then
        return nil, "player_not_found"
    end
    if not rec.loaded then
        return nil, unavailableReason(rec)
    end
    if jobName == nil or jobName == false then
        if rec.job then
            applyJob(id, rec, nil, 0, nil, "export setJob none")
        end
        return true
    end
    local name = normalizeJob(jobName)
    if not name then
        return nil, "unknown_job"
    end
    if JOB_BY_NAME[name].reserved then
        return nil, "reserved_job"
    end
    local level = grade == nil and 0 or grade
    if not isValidGrade(level) then
        return nil, "invalid_grade"
    end
    if rec.job == name and rec.grade == level then
        return true
    end
    if rec.job == name then
        setGrade(id, rec, level, "export setJob")
    else
        applyJob(id, rec, name, level, "export", "export setJob")
    end
    return true
end)

exports("listOnDuty", function(jobName)
    local name = normalizeJob(jobName)
    if not name then
        return {}
    end
    return onDutyIds(name)
end)

exports("salary", function(jobName, level)
    local name = normalizeJob(jobName)
    if not name or not isValidGrade(level) then
        return 0
    end
    return salaryOf(name, level)
end)

-- Authoritative eligibility: true, epoch | nil, reason. Call it when the work begins
-- (keep the epoch) and again at commit with `epoch = <kept>`: any job, grade or duty
-- change in between answers stale_job_epoch.
local function eligible(playerId, requirement)
    local req, bad = parseRequirement(requirement)
    if not req then
        return nil, bad
    end
    local rec, why = lookup(playerId)
    if not rec then
        return nil, why
    end
    local refusal = unmet(rec, req)
    if refusal then
        return nil, refusal
    end
    return true, rec.epoch
end

exports("eligible", eligible)

-- The current work epoch of a loaded file: an integer, or nil and the reason.
exports("workEpoch", function(playerId)
    local rec, why = lookup(playerId)
    if not rec then
        return nil, why
    end
    return rec.epoch
end)

-- The small HUD summary of one player (server side; the caller decides who sees it).
exports("summary", function(playerId)
    local rec, why = lookup(playerId)
    if not rec then
        return nil, why
    end
    local job = rec.job and JOB_BY_NAME[rec.job] or nil
    return {
        job = rec.job or false,
        label = job and job.label or false,
        grade = job and rec.grade or false,
        gradeLabel = job and gradeLabel(rec.grade) or false,
        onDuty = job ~= nil and rec.onDuty == true,
    }
end)

-- Clock a player in or out on behalf of a server flow (a foreman target, a shift start).
-- `requirement` (optional, as for `eligible`) is checked first. Answers true, epoch.
exports("setDuty", function(playerId, onDuty, requirement)
    if type(onDuty) ~= "boolean" then
        return nil, "invalid_duty"
    end
    local req, bad = parseRequirement(requirement)
    if not req then
        return nil, bad
    end
    local rec, id = lookup(playerId)
    if not rec then
        return nil, id
    end
    local refusal = unmet(rec, req)
    if refusal then
        return nil, refusal
    end
    if not rec.job then
        return nil, "no_job"
    end
    if rec.onDuty ~= onDuty then
        clock(id, rec, onDuty, ("export by %s"):format(tostring(GetInvokingResource() or "unknown")))
    end
    return true, rec.epoch
end)

-- Admin/console diagnostic (ACL command.jobcheck): the server's own verdict and epoch,
-- so a lab proof can watch eligibility and invalidation without a probe resource.
RegisterCommand("jobcheck", function(source, args)
    local target = toPlayerId(args[1])
    if not target then
        answer(source, "Usage: jobcheck <playerId> [job|any] [minGrade 0-3] [duty]")
        return
    end
    local requirement = {}
    if args[2] and string.lower(args[2]) ~= "any" then
        requirement.job = args[2]
    end
    if args[3] then
        requirement.minGrade = tonumber(args[3])
    end
    if args[4] then
        requirement.duty = string.lower(args[4]) == "duty"
    end
    local ok, value = eligible(target, requirement)
    local rec = records[target]
    local file = "no file"
    if rec and rec.loaded then
        file = ("job=%s grade=%d duty=%s epoch=%s"):format(tostring(rec.job or "none"), rec.grade or 0,
            rec.onDuty and "on" or "off", tostring(rec.epoch))
    end
    if ok then
        answer(source, ("jobcheck player %d: eligible epoch=%s (%s, store=%s)"):format(target, tostring(value), file, storeState))
    else
        answer(source, ("jobcheck player %d: refused %s (%s, store=%s)"):format(target, tostring(value), file, storeState))
    end
end, true)

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

-- Read one file now that the store is ready; yields, so it runs from a handler.
local function readInto(playerId, rec, greet)
    rec.unavailable = nil
    rec.waiting = false
    rec.reading = true
    local read = loadRecord(rec)
    rec.reading = false
    if records[playerId] ~= rec then
        return -- left while loading
    end
    if not read then
        -- Never mark a failed read as loaded: a later write could erase a real row.
        rec.unavailable = "store_unavailable"
        tell(playerId, "Your job file could not be read. Reconnect in a moment.")
        return
    end
    rec.loaded = true
    local storeName = storeState == "lab_kvp" and "kvp" or storeState
    if rec.job then
        log("player %d loaded job=%s grade=%d (%s)", playerId, rec.job, rec.grade, storeName)
        if greet then
            tell(playerId, ("Welcome back: you still work for %s as %s. /service to clock in."):format(
                JOB_BY_NAME[rec.job].label, gradeLabel(rec.grade)))
        end
    else
        log("player %d loaded job=none (%s)", playerId, storeName)
    end
    bump(playerId, rec, "loaded")
    publish(playerId, rec)
    sendSelf(playerId)
end

-- Open one player's file: resolve the durable subject, then read it, or wait for the store.
local function loadPlayer(playerId, greet)
    local rec = { identifier = nil, loaded = false, job = nil, grade = 0, onDuty = false, greet = greet }
    records[playerId] = rec
    local subject, why = subjectOf(playerId)
    if not subject then
        rec.unavailable = why or "subject_unavailable"
        log("player %d has no durable subject (%s): no job file", playerId, rec.unavailable)
        return
    end
    rec.identifier = subject
    if storeReady() then
        readInto(playerId, rec, greet)
        return
    end
    rec.unavailable = "store_unavailable"
    rec.waiting = storeState == "pending"
    log("player %d job file waits: store=%s", playerId, storeState)
    if storeState ~= "pending" then
        tell(playerId, "Job records are unavailable on this server: no job file this session.")
    end
end

-- The store became ready: open every file that was waiting for it.
local function loadWaiting()
    for playerId, rec in pairs(records) do
        if rec.waiting and not rec.loaded then
            rec.waiting = false
            CreateThread(function()
                if records[playerId] == rec then
                    readInto(playerId, rec, rec.greet)
                end
            end)
        end
    end
end

local function refuseWaiting()
    for playerId, rec in pairs(records) do
        if rec.waiting then
            rec.waiting = false
            tell(playerId, "Job records are unavailable on this server: no job file this session.")
        end
    end
end

local function refuseStore(reason)
    storeState, storeReason = "refused", tostring(reason)
    log("store=refused reason=%s: job files stay unloaded and every change is refused (no KVP fallback)", storeReason)
    refuseWaiting()
end

-- Schema, then the stale duty flags, then the store is SQL. A transiently unreachable
-- database is retried for as long as it takes (files keep waiting, nothing is decided
-- for the boot); any other schema failure refuses the store.
local function prepareSchema(attempt)
    Open77.database.update(SCHEMA, {}, function(result, why)
        if failed(result, why) then
            if transient(why) then
                local delay = math.min(60, 5 * attempt)
                log("schema statement failed (%s): retry %d in %d s", tostring(why), attempt, delay)
                SetTimeout(delay * 1000, function()
                    prepareSchema(attempt + 1)
                end)
                return
            end
            refuseStore("schema_failed: " .. tostring(why))
            return
        end
        Open77.database.update(CLEAR_STALE_DUTY, {}, function(cleared, clearWhy)
            if failed(cleared, clearWhy) then
                log("stale duty flags not cleared: %s", tostring(clearWhy))
            end
            if storeState ~= "pending" then
                log("database answered late: this boot keeps store=%s", storeState)
                return
            end
            storeState = "sql"
            log("store=sql table=rp_jobs_employees")
            loadWaiting()
        end)
    end)
end

-- `ready` answers false, database_unavailable only when the server has no database at all;
-- a configured database that is late keeps the handler queued, so it fires when it answers.
local function initStore()
    storeState, storeReason = "pending", nil
    local ok, reason = Open77.database.ready(function()
        prepareSchema(1)
    end)
    if ok then
        return
    end
    if reason == "database_unavailable" and C.LabKvpWithoutDatabase ~= false then
        storeState, storeReason = "lab_kvp", tostring(reason)
        log("store=kvp reason=%s: no database is configured, employment lives in this resource's KVP file "
            .. "(a disposable lab store, never a fallback)", storeReason)
        loadWaiting()
        return
    end
    refuseStore(reason)
end

-- The job board: one terminal prop behind the agency ring, owned here, removed on stop.
-- A refusal only logs: the ring and the prompt do not depend on it.
local boardProp = nil

local function spawnBoard()
    local prop = C.Agency.prop
    if not prop or not prop.model or boardProp then
        return
    end
    local id, reason = Open77.props.create({
        model = prop.model,
        position = { x = prop.position.x, y = prop.position.y, z = prop.position.z },
        yaw = prop.yaw or 0.0,
        bucket = 0,
        streamingRadius = 120.0,
    })
    if id then
        boardProp = id
        log("job board prop %s at %.1f %.1f %.1f", tostring(id), prop.position.x, prop.position.y, prop.position.z)
    else
        log("job board prop not spawned (%s): the ring alone marks the agency", tostring(reason))
    end
end

local function removeBoard()
    if boardProp then
        Open77.props.remove(boardProp)
        boardProp = nil
    end
end

AddEventHandler("onResourceStart", function(name)
    if name ~= RESOURCE then
        return
    end
    Open77.chat.addSuggestions(-1, SUGGESTIONS)
    initStore()
    local spawned, err = pcall(spawnBoard)
    if not spawned then
        log("job board prop failed: %s", tostring(err))
    end
    -- Players already in the world when the resource (re)started.
    for _, playerId in ipairs(Open77.players.all()) do
        local id = toPlayerId(playerId)
        if id then
            local read = Open77.players.get(id)
            if read and read.ready then
                CreateThread(function()
                    loadPlayer(id, false)
                end)
            end
        end
    end
    -- A configured database that has not answered: say so once, keep waiting (no fallback).
    CreateThread(function()
        Wait(15000)
        if storeState == "pending" then
            local _, reason = Open77.database.isReady()
            log("store=pending after 15 s (%s): job files stay unloaded until the database answers; no KVP fallback",
                tostring(reason or "schema_not_answered"))
            for playerId, rec in pairs(records) do
                if rec.waiting then
                    tell(playerId, "Job records are offline (the database is not answering): your job file loads as soon as it answers.")
                end
            end
        end
    end)
    CreateThread(function()
        while true do
            Wait(C.PayrollIntervalMs)
            runPayroll()
        end
    end)
    log("started: %d jobs, payroll every %d min, agency at %.1f %.1f %.1f",
        #C.Jobs, math.floor(C.PayrollIntervalMs / 60000), C.Agency.position.x, C.Agency.position.y, C.Agency.position.z)
end)

AddEventHandler("onResourceStop", function(name)
    if name ~= RESOURCE then
        return
    end
    removeBoard()
    for playerId, rec in pairs(records) do
        if rec.onDuty then
            rec.onDuty = false
            persistDuty(rec)
            log("player %d duty=off job=%s (resource_stop)", playerId, tostring(rec.job))
        end
        if rec.loaded then
            publish(playerId, rec)
        end
    end
end)

RegisterNetEvent("chat:ready", function()
    local id = toPlayerId(source)
    if id then
        Open77.chat.addSuggestions(id, SUGGESTIONS)
    end
end)

AddEventHandler("onPlayerReady", function(playerId)
    local id = toPlayerId(playerId)
    if not id then
        return
    end
    local existing = records[id]
    if existing and (existing.loaded or existing.reading or existing.waiting) then
        return -- already open (or opening) since the resource started: never re-read over live duty
    end
    loadPlayer(id, true)
end)

AddEventHandler("onPlayerDisconnected", function(playerId)
    local id = toPlayerId(playerId)
    if not id then
        return
    end
    local rec = records[id]
    if rec and rec.loaded and rec.onDuty then
        local jobName = rec.job
        setDuty(id, rec, false, "disconnected")
        if jobName then
            tellColleagues(id, jobName, ("%s went off duty (disconnected)."):format(displayName(id)))
        end
    end
    records[id] = nil
    if rec and rec.loaded then
        publishEpoch(id, false, "unloaded")
    end
end)
