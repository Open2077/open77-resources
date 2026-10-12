-- rp_fixer / server/store.lua: the durable records, in SQL (Open77.database, `database.access`).
--
--   rp_fixer_contracts   one row per contract: its state and the whole record as JSON. `live` = 1
--                        while it can still change (posting, open, taken, paying, refunding); the
--                        boot reloads exactly those rows.
--   rp_fixer_reputation  one row per player subject (the table of rp_fixer 1.0, unchanged, so a
--                        server upgrading keeps its players' reputation).
--   rp_fixer_rep_log     one row per reputation change, keyed by the event that caused it: the
--                        change and its key are written in ONE SQL transaction, so a replayed
--                        payout can never raise a score twice.
--   rp_fixer_gigs        the settled-contract history of rp_fixer 1.0, unchanged, one row per
--                        settled contract (best effort, never read back).
--
-- Money and goods are NOT here: they live in rp_economy / open77_transactions. Every function
-- may yield (call it from a thread, a handler or a hook) and answers `nil, reason` on failure.
--
-- Global: FixerStore.

FixerStore = {}
local St = FixerStore

St.ready = false
St.reason = "database_connecting"

local function await(kind, sql, params)
    local ok, result, extra = pcall(Open77.database[kind].await, sql, params)
    if not ok then return nil, tostring(result) end
    return result, extra
end

local SCHEMA = {
    [[
        CREATE TABLE IF NOT EXISTS rp_fixer_contracts (
            id         VARCHAR(48)  PRIMARY KEY,
            seq        INT          NOT NULL,
            state      VARCHAR(16)  NOT NULL,
            live       TINYINT      NOT NULL DEFAULT 1,
            data       TEXT         NOT NULL,
            expires_at BIGINT       NOT NULL DEFAULT 0,
            updated_at BIGINT       NOT NULL DEFAULT 0,
            INDEX (live),
            INDEX (seq)
        )
    ]],
    [[
        CREATE TABLE IF NOT EXISTS rp_fixer_reputation (
            identifier VARCHAR(64) PRIMARY KEY,
            score      INT    NOT NULL DEFAULT 0,
            completed  INT    NOT NULL DEFAULT 0,
            failed     INT    NOT NULL DEFAULT 0,
            updated_at BIGINT NOT NULL DEFAULT 0
        )
    ]],
    [[
        CREATE TABLE IF NOT EXISTS rp_fixer_rep_log (
            event_key  VARCHAR(96) PRIMARY KEY,
            identifier VARCHAR(64) NOT NULL,
            delta      INT         NOT NULL,
            at         BIGINT      NOT NULL DEFAULT 0
        )
    ]],
    [[
        CREATE TABLE IF NOT EXISTS rp_fixer_gigs (
            id          INT AUTO_INCREMENT PRIMARY KEY,
            gig_id      INT          NOT NULL,
            identifier  VARCHAR(64)  NOT NULL,
            player_name VARCHAR(80)  NOT NULL DEFAULT '',
            template    VARCHAR(32)  NOT NULL,
            kind        VARCHAR(16)  NOT NULL,
            outcome     VARCHAR(16)  NOT NULL,
            pay         INT          NOT NULL DEFAULT 0,
            commission  INT          NOT NULL DEFAULT 0,
            publisher   VARCHAR(80)  NOT NULL DEFAULT 'board',
            accepted_at BIGINT       NOT NULL DEFAULT 0,
            ended_at    BIGINT       NOT NULL DEFAULT 0,
            INDEX (identifier)
        )
    ]],
}

-- Registers the boot gate. `onReady(ok, reason)` runs once the tables exist (or failed).
-- Answers false, "database_unavailable" when the server has no database at all.
function St.init(onReady)
    local registered, why = Open77.database.ready(function()
        for _, sql in ipairs(SCHEMA) do
            local done, err = await("update", sql)
            if done == nil then
                St.ready, St.reason = false, "schema_failed"
                onReady(false, tostring(err))
                return
            end
        end
        St.ready, St.reason = true, nil
        onReady(true)
    end)
    if not registered then
        St.ready, St.reason = false, why or "database_unavailable"
        return false, St.reason
    end
    return true
end

-- The highest contract number ever used (0 on an empty table).
function St.maxSeq()
    local value, why = await("scalar", "SELECT MAX(seq) FROM rp_fixer_contracts")
    if value == nil and why then return nil, why end
    return math.tointeger(tonumber(value) or 0) or 0
end

-- Every contract that can still change, oldest first. A row that does not decode is reported,
-- never dropped silently (its money stays in escrow until an operator looks at it).
function St.loadLive(limit)
    local rows, why = await("query",
        "SELECT id, data FROM rp_fixer_contracts WHERE live = 1 ORDER BY seq LIMIT ?", { limit or 1000 })
    if rows == nil then return nil, why or "database_unavailable" end
    local out, bad = {}, {}
    for _, row in ipairs(rows) do
        local decoded = type(row.data) == "string" and json.decode(row.data) or nil
        if type(decoded) == "table" and decoded.id == row.id then
            out[#out + 1] = decoded
        else
            bad[#bad + 1] = tostring(row.id)
        end
    end
    return out, nil, bad
end

-- Writes the whole record (insert or replace). Answers true | nil, reason.
function St.save(c, now)
    local data = json.encode(c)
    if type(data) ~= "string" then return nil, "encode_failed" end
    local live = (c.state == "posting" or c.state == "open" or c.state == "taken"
        or c.state == "paying" or c.state == "refunding") and 1 or 0
    local done, why = await("update",
        "INSERT INTO rp_fixer_contracts (id, seq, state, live, data, expires_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?) " ..
        "ON DUPLICATE KEY UPDATE state = VALUES(state), live = VALUES(live), data = VALUES(data), " ..
        "expires_at = VALUES(expires_at), updated_at = VALUES(updated_at)",
        { c.id, c.seq, c.state, live, data, c.expiresAt or 0, now or 0 })
    if done == nil then return nil, why or "database_unavailable" end
    return true
end

-- { score, completed, failed } of a subject (zeros when the row does not exist yet).
function St.loadRep(subject)
    local ok, row = pcall(Open77.database.single.await,
        "SELECT score, completed, failed FROM rp_fixer_reputation WHERE identifier = ?", { subject })
    if not ok then return nil, tostring(row) end
    if not row then return { score = 0, completed = 0, failed = 0 } end
    return {
        score = math.tointeger(tonumber(row.score) or 0) or 0,
        completed = math.tointeger(tonumber(row.completed) or 0) or 0,
        failed = math.tointeger(tonumber(row.failed) or 0) or 0,
    }
end

-- Applies one reputation change exactly once, keyed by `key`. Answers "applied" | "duplicate",
-- or nil, reason. The log row and the score change commit together or not at all.
function St.applyRep(subject, key, delta, completed, failed, floor, now)
    local ok, committed, why = pcall(Open77.database.transaction.await, {
        { query = "INSERT INTO rp_fixer_rep_log (event_key, identifier, delta, at) VALUES (?, ?, ?, ?)",
          values = { key, subject, delta, now } },
        { query = "INSERT INTO rp_fixer_reputation (identifier, score, completed, failed, updated_at) " ..
                  "VALUES (?, GREATEST(?, ?), ?, ?, ?) ON DUPLICATE KEY UPDATE score = GREATEST(score + ?, ?), " ..
                  "completed = completed + ?, failed = failed + ?, updated_at = ?",
          values = { subject, delta, floor, completed, failed, now, delta, floor, completed, failed, now } },
    })
    if ok and committed then return "applied" end
    -- Rolled back: already applied (the key exists), or a real failure.
    local seen, seenWhy = await("scalar", "SELECT COUNT(*) FROM rp_fixer_rep_log WHERE event_key = ?", { key })
    if seen == nil and seenWhy then return nil, seenWhy end
    if (tonumber(seen) or 0) > 0 then return "duplicate" end
    return nil, tostring(ok and why or committed or "database_unavailable")
end

-- One history row of a settled contract (rp_fixer 1.0's table). Best effort: callback form.
function St.history(c, now)
    local runner = c.payee or c.runner
    Open77.database.insert(
        "INSERT INTO rp_fixer_gigs (gig_id, identifier, player_name, template, kind, outcome, pay, commission, " ..
        "publisher, accepted_at, ended_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        { c.seq, runner and runner.subject or "", (runner and runner.name or ""):sub(1, 80), c.template, c.kind,
          c.state, c.state == "completed" and c.net or 0, c.state == "completed" and c.cut or 0,
          (c.poster and (c.poster.subject or ("npc:" .. tostring(c.hub))) or "board"):sub(1, 80),
          c.takenAt or c.postedAt or 0, now or 0 },
        function(id, reason)
            if id == nil then print(("[rp_fixer] history row of contract %s not written: %s"):format(c.id, tostring(reason))) end
        end)
end

return St
