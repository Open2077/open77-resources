-- Pursuit -- persistent player rating (Elo).
--
-- Owner, 2026-08-26, after playtesting: "on fait un systeme de rank, on monte
-- en pts quand on gagne et quand on perd ca descend ? une espece de ranked ?"
--
-- The obvious reading of that is a counter: +10 a win, -10 a loss. It is also
-- the wrong one, and it is worth saying why in the file rather than in a commit
-- message, because the counter is what every future edit will drift back
-- towards.
--
-- A counter measures VOLUME, not skill. Two players who both win 60% of their
-- matches end up hundreds of points apart if one of them plays five times as
-- often, and the top of the ladder becomes a record of who had the most
-- evenings free. Worse, it makes every opponent worth the same: beating
-- somebody four hundred points below you pays exactly what beating the best
-- player on the server pays, so once you are ahead the rational move is to
-- farm the weakest opponent in the lobby. That is the shape of the mode's
-- entire competitive incentive, decided by one constant.
--
-- Pursuit is a 1v1 with a definite winner, which is the same shape as chess or
-- a fighting-game ladder, so the answer is the one those settled on decades
-- ago: rate the RESULT AGAINST THE EXPECTATION. You are paid for the surprise
-- you caused, not for the fact you turned up.
--
--     E_a = 1 / (1 + 10^((R_b - R_a) / spread))     what we expected of you
--     R_a' = R_a + K * (S_a - E_a)                  what actually happened
--
-- with S = 1 for a win, 0.5 for a draw, 0 for a loss. Three consequences worth
-- stating out loud, because they are the whole reason for the arithmetic:
--
--   * beating a much stronger player pays nearly the full K; beating a much
--     weaker one pays nearly nothing. Farming is not profitable.
--   * losing to a much stronger player costs nearly nothing. Playing the best
--     player on the server is not punished, which is the behaviour a small
--     server most needs to encourage.
--   * a DRAW is not "nothing happened". Against a stronger opponent it is a
--     gain, against a weaker one a loss. That matters here more than in most
--     places -- see the draw note below.
--
-- ------------------------------------------------------------ why not Glicko --
--
-- Glicko-2 is better arithmetic and would be the wrong tool today. It carries
-- two more numbers per player (rating deviation and volatility), and both are
-- only defined against a RATING PERIOD -- a batch of games rated together.
-- Glickman's own guidance is 10-15 games per period. On a server with a handful
-- of regulars that is a period measured in weeks, during which a player's
-- rating does not move at all, which is precisely the feedback the owner asked
-- for. Applying Glicko-2 per match instead is a well-known approximation that
-- quietly loses the property it was chosen for.
--
-- The one thing Glicko genuinely buys -- new players converging fast, then
-- settling -- is bought here for one integer of state (`matches`) and one
-- config line: a higher K for a player's first few rated matches. That is
-- FIDE's own provisional rule, it is legible to a player ("your first ten
-- games count double"), and it is testable in an afternoon. Glicko stays on
-- the table for the day the ladder is big enough to have a rating period.
--
-- ------------------------------------------------------------------- rounds --
--
-- A match is a BEST OF TWO WITH THE ROLES SWAPPED (`Config.match.roundsPerMatch`).
-- This file rates the MATCH, never the round, and that is a design decision
-- with teeth:
--
--   * a 1-1 is a genuine draw and is rated as one, S = 0.5. It is not "no
--     result" -- see above, against a stronger opponent it is a gain.
--   * because the roles swap and the round count is even, BOTH PLAYERS PLAY
--     BOTH SIDES EXACTLY ONCE. Any first-order advantage in being the cop
--     cancels within the match, so a rating built on match results cannot
--     quietly reward whoever drew the easier role. Rating the ROUNDS would
--     have exactly that defect.
--
-- The cancellation has one hole and it is honestly a hole: `tieBreak =
-- "decider"` adds a third round, and an odd round count hands one player an
-- extra turn as the cop. Nothing here guesses at how big that is -- see
-- `pursuit_ranked_rounds` below, which exists to make the question answerable
-- from data instead of from opinion.
--
-- ---------------------------------------------------------------- forfeits --
--
-- A player who disconnects while losing must not escape the loss. He does not:
-- `finishMatch` already awards the match to whoever stayed regardless of the
-- scoreline, and that verdict arrives here as any other.
--
-- Whether a rage-quit should cost MORE than an honest loss is a different
-- question, and the honest answer is that this server cannot tell the two
-- apart. A crash, an ISP blip and alt-F4 all reach the gamemode as the same
-- `pursuit:playerGone`, carrying no reason. So the rule is the plainest one
-- that satisfies the requirement: an abandonment is rated EXACTLY as a loss.
-- No amnesty for the crash, no extra beating for the quit. `abandonPenaltyScale`
-- is there for the day a disconnect reason exists, and it is clamped at 1.0 from
-- below in code, not merely in a comment -- a leaver must never be able to lose
-- less by leaving than by playing it out.
--
-- ------------------------------------------------------------- persistence --
--
-- MySQL/MariaDB through the `database.access` bridge, keyed by
-- `GetPlayerIdentifier()` -- the master-backed GUID, bound to the client's
-- identity certificate, so a rating cannot be claimed by renaming.
--
-- When the bridge is off the module still runs, in memory, and SAYS SO
-- everywhere it can be read: the start-up log line, every `pursuit.rank`
-- output, and the notification after each match. That loudness is the point.
-- A rating that silently evaporates on restart is worse than no rating at all,
-- because players trust it first and are betrayed afterwards.
--
-- There is no file-backed alternative and that is not an omission: the server
-- Lua sandbox nils out `io` and `os` (LuaResourceRuntime.Sandbox), so a
-- resource cannot write a file at all. The database bridge is the only
-- persistence server-side Lua has. Turning it on is documented in
-- resources/gamemodes/pursuit/README.md.

local Config = PursuitConfig

local function log(text) Pursuit.log(text) end
local function nowMs() return Pursuit.nowMs() end

-- ---------------------------------------------------------------- tunables --
--
-- Read FRESH on every use, never captured into an upvalue at load time.
--
-- Another agent is building live config editing into the Warden panel, so the
-- assumption is that any of these can change under a running server between
-- one match and the next. Reading through this function means an edit takes
-- effect on the next match with no reload, and -- more importantly -- means a
-- value typed into a web form cannot put the maths into a state the arithmetic
-- does not survive. Every field is clamped here and nowhere else.
local function tunables()
    local raw = (PursuitConfig or {}).ranked or {}

    local function number(value, fallback, low, high)
        local n = tonumber(value)
        if n == nil or n ~= n then return fallback end
        if n < low then return low end
        if n > high then return high end
        return n
    end
    local function integer(value, fallback, low, high)
        return math.floor(number(value, fallback, low, high) + 0.5)
    end

    local t = {
        enabled = raw.enabled ~= false,
        startRating = integer(raw.startRating, 1000, 100, 5000),
        spread = number(raw.spread, 400.0, 50.0, 2000.0),
        baseK = number(raw.baseK, 20.0, 1.0, 100.0),
        provisionalK = number(raw.provisionalK, 40.0, 1.0, 200.0),
        provisionalMatches = integer(raw.provisionalMatches, 10, 0, 100),
        floorRating = integer(raw.floorRating, 100, 0, 5000),
        minDelta = integer(raw.minDelta, 1, 0, 50),
        -- Clamped at 1.0 FROM BELOW deliberately: see the forfeit note above.
        abandonPenaltyScale = number(raw.abandonPenaltyScale, 1.0, 1.0, 3.0),
        rateUnplayedForfeit = raw.rateUnplayedForfeit == true,
        announce = raw.announce ~= false,
        leaderboardSize = integer(raw.leaderboardSize, 10, 1, 25),
        requireDatabase = raw.requireDatabase == true,
    }
    -- A floor above the start would put every new player instantly underwater.
    if t.floorRating > t.startRating then t.floorRating = t.startRating end
    return t
end

-- -------------------------------------------------------------------- state --

-- identifier -> record. The authoritative copy while the server runs; the
-- database is where it goes to survive a restart, not where it is read from
-- during a match.
local ratings = {}

-- matchId -> { order = { playerId, playerId }, [playerId] = { identifier, name } }
--
-- Captured at the countdown of round one, not at resolution, because
-- resolution is exactly when a player may already be gone: `pursuit:playerGone`
-- clears the roster entry before `resolve` runs, so `Open77.players.identifier`
-- on the leaver returns nothing. Without this snapshot a forfeit -- the one
-- result that most needs recording -- would be the one result we could not
-- attribute.
local identities = {}

-- nil = not probed yet, true = schema is up, false = degraded to memory.
local dbReady = nil
local dbReason = "not probed"

-- Session-local role tally, so the role-symmetry question has an answer that
-- does not require a SQL client. Reset by a resource reload, which is fine:
-- `pursuit_ranked_rounds` is the durable copy.
local roleWins = { cop = 0, runner = 0, undecided = 0 }

-- ------------------------------------------------------------------- Elo --

-- What we expected of `a` against `b`, 0..1.
local function expected(a, b, spread)
    return 1.0 / (1.0 + 10.0 ^ ((b - a) / spread))
end

-- Round half away from zero. `math.floor(x + 0.5)` is wrong for negatives --
-- it turns -0.5 into 0 and biases every loss upward by half a point, which
-- over a season is a free ride for whoever loses most.
local function roundHalfAway(value)
    if value >= 0 then return math.floor(value + 0.5) end
    return -math.floor(-value + 0.5)
end

-- The K a player carries into THIS match, from the matches he had BEFORE it.
--
-- A new player's rating is a guess, so his first matches should move it a long
-- way; a settled player's rating is evidence, so his should not. Both players
-- use their OWN K, which means a provisional player facing a settled one moves
-- further than his opponent and the exchange is not zero-sum. That is
-- deliberate and is what FIDE does: a ladder is a measurement, not a currency,
-- and refusing to let a beginner converge in order to keep the books balanced
-- would be optimising the wrong thing.
local function kFor(record, t)
    if (record.matches or 0) < t.provisionalMatches then return t.provisionalK end
    return t.baseK
end

-- One player's rating change. `score` is 1 / 0.5 / 0.
local function deltaFor(rating, opponentRating, score, k, t)
    local delta = roundHalfAway(k * (score - expected(rating, opponentRating, t.spread)))
    -- A decisive result that rounds to zero reads as a broken ladder, and it is
    -- also a real loophole: at a large enough rating gap the favourite could
    -- win indefinitely for free. One point either way keeps the result honest
    -- without pretending it was close.
    if score >= 1.0 and delta < t.minDelta then delta = t.minDelta end
    if score <= 0.0 and delta > -t.minDelta then delta = -t.minDelta end
    return delta
end

-- ------------------------------------------------------------------ records --

local function blankRecord(identifier, name, t)
    return {
        identifier = identifier,
        name = name or "",
        rating = t.startRating,
        matches = 0, wins = 0, losses = 0, draws = 0, forfeits = 0,
        peak = t.startRating,
        loaded = false,
    }
end

-- A usable player identity, or nil.
--
-- The identifier is the master-backed GUID and is what every row is keyed by,
-- so anything that is not a plausible one is refused outright rather than
-- written to the database as a rating nobody can ever be matched back to.
local function identityOf(playerId)
    local identifier = Open77.players.identifier(playerId)
    if type(identifier) ~= "string" then return nil end
    if #identifier < 8 or #identifier > 64 then return nil end
    if identifier:find("%c") ~= nil then return nil end
    local name = Open77.players.name(playerId)
    if type(name) ~= "string" then name = "" end
    if #name > 64 then name = name:sub(1, 64) end
    return { identifier = identifier, name = name }
end

-- ------------------------------------------------------------------ schema --
--
-- Two tables, and the second one is not bookkeeping.
--
-- `pursuit_ranked_ratings` is the ladder. `pursuit_ranked_rounds` is one row
-- per ROUND with the two roles named, and it exists for exactly one question:
-- ARE COP AND RUNNER SYMMETRIC? Nothing in this file guesses at that -- a
-- guess baked into a K-factor would be indistinguishable from a rule -- so the
-- data is recorded and the question is left answerable:
--
--     SELECT mode, winner_role, COUNT(*)
--       FROM pursuit_ranked_rounds
--      GROUP BY mode, winner_role;
--
-- If the cop wins materially more than half of decided rounds in a mode, the
-- roles are not symmetric and the honest fixes are gameplay ones (tune
-- `escapeDistance`, `bustSeconds`, the head start) rather than a thumb on the
-- rating. The match-level swap already protects the LADDER from the imbalance;
-- this is about protecting the GAME from it.
local SCHEMA = {
    [[
    CREATE TABLE IF NOT EXISTS pursuit_ranked_ratings (
        identifier    VARCHAR(64) NOT NULL PRIMARY KEY,
        name          VARCHAR(64) NOT NULL DEFAULT '',
        rating        INT NOT NULL,
        matches       INT NOT NULL DEFAULT 0,
        wins          INT NOT NULL DEFAULT 0,
        losses        INT NOT NULL DEFAULT 0,
        draws         INT NOT NULL DEFAULT 0,
        forfeits      INT NOT NULL DEFAULT 0,
        peak_rating   INT NOT NULL,
        first_seen    DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
        -- Not read by anything today. It is the column a future inactivity
        -- decay would need, and adding it now costs nothing while adding it
        -- later costs a migration against live rows.
        last_match_at DATETIME NULL,
        KEY idx_pursuit_ranked_ratings_rating (rating DESC)
    ) ENGINE=InnoDB
    ]],
    [[
    CREATE TABLE IF NOT EXISTS pursuit_ranked_rounds (
        id                BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
        match_id          BIGINT NOT NULL,
        round_index       INT NOT NULL,
        played_at         DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
        mode              VARCHAR(16) NOT NULL,
        outcome           VARCHAR(32) NOT NULL,
        -- NULL when the round had no winner. Everything else is 'cop' or
        -- 'runner', which is the whole point of the table.
        winner_role       VARCHAR(8) NULL,
        cop_identifier    VARCHAR(64) NOT NULL,
        runner_identifier VARCHAR(64) NOT NULL,
        duration_ms       BIGINT NULL,
        KEY idx_pursuit_ranked_rounds_match (match_id),
        KEY idx_pursuit_ranked_rounds_role (mode, winner_role)
    ) ENGINE=InnoDB
    ]],
    [[
    CREATE TABLE IF NOT EXISTS pursuit_ranked_matches (
        id              BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
        match_id        BIGINT NOT NULL,
        played_at       DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
        mode            VARCHAR(16) NOT NULL,
        rounds_played   INT NOT NULL,
        outcome         VARCHAR(32) NOT NULL,
        drawn           TINYINT(1) NOT NULL DEFAULT 0,
        forfeit         TINYINT(1) NOT NULL DEFAULT 0,
        -- Did both players take each role the same number of times? False for
        -- a decider, and the flag that lets the query above exclude the rounds
        -- whose role allocation was not balanced.
        role_balanced   TINYINT(1) NOT NULL DEFAULT 0,
        a_identifier    VARCHAR(64) NOT NULL,
        a_name          VARCHAR(64) NOT NULL DEFAULT '',
        a_score         INT NOT NULL,
        a_rating_before INT NOT NULL,
        a_rating_after  INT NOT NULL,
        a_k             INT NOT NULL,
        b_identifier    VARCHAR(64) NOT NULL,
        b_name          VARCHAR(64) NOT NULL DEFAULT '',
        b_score         INT NOT NULL,
        b_rating_before INT NOT NULL,
        b_rating_after  INT NOT NULL,
        b_k             INT NOT NULL,
        KEY idx_pursuit_ranked_matches_a (a_identifier),
        KEY idx_pursuit_ranked_matches_b (b_identifier)
    ) ENGINE=InnoDB
    ]],
}

-- Probe the bridge by putting the schema up.
--
-- There is no "is the database on?" question to ask: `MySQL` is installed by
-- the bootstrap whether or not the bridge is enabled and whether or not this
-- resource holds `database.access`, so testing the global proves nothing. The
-- first real statement is the probe, exactly as open77_appearance does it.
-- Must run inside a coroutine -- `.await` yields.
local function ensureSchema()
    if dbReady ~= nil then return dbReady end
    local ok, reason = pcall(function()
        for _, statement in ipairs(SCHEMA) do MySQL.update.await(statement) end
    end)
    if not ok then
        dbReady = false
        dbReason = tostring(reason)
        log("ranked: DATABASE UNAVAILABLE (" .. dbReason .. ") -- ratings are VOLATILE this run")
        return false
    end
    dbReady = true
    dbReason = "ready"
    log("ranked: database ready, ratings persist")
    return true
end

-- Load one player's row into the cache. Coroutine only.
local function ensureLoaded(identity)
    local t = tunables()
    local record = ratings[identity.identifier]
    if record == nil then
        record = blankRecord(identity.identifier, identity.name, t)
        ratings[identity.identifier] = record
    end
    if identity.name ~= "" then record.name = identity.name end
    if record.loaded then return record end
    if not ensureSchema() then
        -- Degraded: the blank record IS the record, and it starts at the
        -- configured rating. Marked loaded so the same failed query is not
        -- retried once per match for the rest of the run.
        record.loaded = true
        return record
    end
    local ok, row = pcall(function()
        return MySQL.single.await([[
            SELECT rating, matches, wins, losses, draws, forfeits, peak_rating
              FROM pursuit_ranked_ratings
             WHERE identifier = ?
             LIMIT 1
        ]], { identity.identifier })
    end)
    if not ok then
        log(("ranked: load failed for %s: %s"):format(identity.identifier, tostring(row)))
        return record
    end
    if row ~= nil then
        record.rating = math.floor(tonumber(row.rating) or t.startRating)
        record.matches = math.floor(tonumber(row.matches) or 0)
        record.wins = math.floor(tonumber(row.wins) or 0)
        record.losses = math.floor(tonumber(row.losses) or 0)
        record.draws = math.floor(tonumber(row.draws) or 0)
        record.forfeits = math.floor(tonumber(row.forfeits) or 0)
        record.peak = math.floor(tonumber(row.peak_rating) or record.rating)
    end
    record.loaded = true
    return record
end

-- ------------------------------------------------------------- match capture --
--
-- Everything the rating needs, read SYNCHRONOUSLY out of the live match record
-- at the instant it resolves.
--
-- `finishMatch` drops the record five seconds later, and every database call
-- below runs on a coroutine that may well be scheduled after that. Snapshotting
-- here rather than dereferencing `Pursuit.matches[id]` inside the thread is the
-- difference between a rating that is always written and one that is written
-- whenever the scheduler happens to be quick.
local function snapshotMatch(matchId)
    local match = Pursuit.matches[matchId]
    if match == nil then return nil, "match_gone" end
    if #match.members ~= Config.match.size then return nil, "not_a_full_pair" end

    local a, b = match.members[1], match.members[2]
    local idA = (identities[matchId] or {})[a]
    local idB = (identities[matchId] or {})[b]
    -- Fall back to reading live -- the snapshot is missing only for a match
    -- created before this file was reloaded, and a present player still answers.
    if idA == nil then idA = identityOf(a) end
    if idB == nil then idB = identityOf(b) end
    if idA == nil or idB == nil then return nil, "no_identity" end
    -- Two clients on one account. Rating that would be a machine for printing
    -- points, and it is the single easiest exploit against any ladder.
    if idA.identifier == idB.identifier then return nil, "same_account" end

    local rounds = {}
    local copRounds = { [a] = 0, [b] = 0 }
    for _, round in ipairs(match.rounds or {}) do
        local roles = round.roles or {}
        local copId = (roles[a] == "cop") and a or ((roles[b] == "cop") and b or nil)
        local runnerId = (roles[a] == "runner") and a or ((roles[b] == "runner") and b or nil)
        if copId ~= nil then copRounds[copId] = copRounds[copId] + 1 end
        local winnerRole = nil
        if round.winner ~= nil then winnerRole = roles[round.winner] end
        rounds[#rounds + 1] = {
            index = round.index,
            outcome = tostring(round.outcome),
            winnerRole = winnerRole,
            copIdentifier = (copId == a and idA.identifier) or (copId == b and idB.identifier) or nil,
            runnerIdentifier = (runnerId == a and idA.identifier) or (runnerId == b and idB.identifier) or nil,
            durationMs = round.durationMs,
        }
    end

    return {
        matchId = matchId,
        mode = tostring(match.mode or "unknown"),
        outcome = tostring(match.outcome or "unknown"),
        drawn = match.drawn == true,
        forfeit = match.outcome == "opponent_left",
        champion = match.champion,
        players = {
            { playerId = a, identity = idA, score = (match.score or {})[a] or 0 },
            { playerId = b, identity = idB, score = (match.score or {})[b] or 0 },
        },
        rounds = rounds,
        roleBalanced = copRounds[a] == copRounds[b],
    }
end

-- ---------------------------------------------------------------- persistence --

-- Write the whole match atomically: both ladder rows, the match row, one row
-- per round. One transaction, because a rating change that landed for one
-- player and not the other is the one failure mode a ladder cannot recover
-- from on its own.
local function persist(snapshot, sides)
    if not dbReady then return false, "database_unavailable" end
    local statements = {}

    for _, side in ipairs(sides) do
        statements[#statements + 1] = {
            query = [[
                INSERT INTO pursuit_ranked_ratings
                    (identifier, name, rating, matches, wins, losses, draws, forfeits,
                     peak_rating, last_match_at)
                VALUES (@id, @name, @rating, @matches, @wins, @losses, @draws, @forfeits,
                        @peak, CURRENT_TIMESTAMP)
                ON DUPLICATE KEY UPDATE
                    name = VALUES(name), rating = VALUES(rating), matches = VALUES(matches),
                    wins = VALUES(wins), losses = VALUES(losses), draws = VALUES(draws),
                    forfeits = VALUES(forfeits),
                    peak_rating = GREATEST(peak_rating, VALUES(peak_rating)),
                    last_match_at = CURRENT_TIMESTAMP
            ]],
            values = {
                id = side.identity.identifier, name = side.identity.name,
                rating = side.after, matches = side.record.matches,
                wins = side.record.wins, losses = side.record.losses,
                draws = side.record.draws, forfeits = side.record.forfeits,
                peak = side.record.peak,
            },
        }
    end

    local a, b = sides[1], sides[2]
    statements[#statements + 1] = {
        query = [[
            INSERT INTO pursuit_ranked_matches
                (match_id, mode, rounds_played, outcome, drawn, forfeit, role_balanced,
                 a_identifier, a_name, a_score, a_rating_before, a_rating_after, a_k,
                 b_identifier, b_name, b_score, b_rating_before, b_rating_after, b_k)
            VALUES (@match, @mode, @rounds, @outcome, @drawn, @forfeit, @balanced,
                    @aid, @aname, @ascore, @abefore, @aafter, @ak,
                    @bid, @bname, @bscore, @bbefore, @bafter, @bk)
        ]],
        values = {
            match = snapshot.matchId, mode = snapshot.mode,
            rounds = #snapshot.rounds, outcome = snapshot.outcome,
            drawn = snapshot.drawn and 1 or 0,
            forfeit = snapshot.forfeit and 1 or 0,
            balanced = snapshot.roleBalanced and 1 or 0,
            aid = a.identity.identifier, aname = a.identity.name, ascore = a.score,
            abefore = a.before, aafter = a.after, ak = math.floor(a.k + 0.5),
            bid = b.identity.identifier, bname = b.identity.name, bscore = b.score,
            bbefore = b.before, bafter = b.after, bk = math.floor(b.k + 0.5),
        },
    }

    for _, round in ipairs(snapshot.rounds) do
        -- A round whose two sides are not both known cannot answer the role
        -- question, so it is not recorded as if it could.
        if round.copIdentifier ~= nil and round.runnerIdentifier ~= nil then
            -- A nil in a Lua table is an ABSENT KEY, so a nil-valued named
            -- parameter never reaches the binder and the driver then rejects
            -- the whole statement for an undefined `@role`. The two nullable
            -- columns therefore vary the SQL rather than the values: a literal
            -- NULL where there is nothing to bind. Both branches are constant
            -- text, so nothing here is string-built from data.
            local values = {
                match = snapshot.matchId, index = round.index or 0,
                mode = snapshot.mode, outcome = round.outcome,
                cop = round.copIdentifier, runner = round.runnerIdentifier,
            }
            local roleTerm = "NULL"
            if round.winnerRole ~= nil then
                roleTerm = "@role"
                values.role = tostring(round.winnerRole)
            end
            local durationTerm = "NULL"
            if tonumber(round.durationMs) ~= nil then
                durationTerm = "@duration"
                values.duration = math.floor(tonumber(round.durationMs))
            end
            statements[#statements + 1] = {
                query = ([[
                    INSERT INTO pursuit_ranked_rounds
                        (match_id, round_index, mode, outcome, winner_role,
                         cop_identifier, runner_identifier, duration_ms)
                    VALUES (@match, @index, @mode, @outcome, %s, @cop, @runner, %s)
                ]]):format(roleTerm, durationTerm),
                values = values,
            }
        end
    end

    local ok, committed, reason = pcall(function()
        return MySQL.transaction.await(statements)
    end)
    if not ok then return false, tostring(committed) end
    if committed ~= true then return false, tostring(reason or "rolled_back") end
    return true
end

-- ------------------------------------------------------------------- rating --

local function scoreFor(snapshot, playerId)
    if snapshot.drawn then return 0.5 end
    if snapshot.champion == nil then return 0.5 end
    return (playerId == snapshot.champion) and 1.0 or 0.0
end

-- Coroutine only: loads, computes, applies, announces, persists.
local function rateMatch(snapshot)
    local t = tunables()

    if #snapshot.rounds == 0 and snapshot.forfeit and not t.rateUnplayedForfeit then
        log(("ranked: match %d not rated -- abandoned before a round was played")
            :format(snapshot.matchId))
        return
    end

    local sides = {}
    for index, entry in ipairs(snapshot.players) do
        local record = ensureLoaded(entry.identity)
        sides[index] = {
            playerId = entry.playerId,
            identity = entry.identity,
            score = entry.score,
            record = record,
            before = record.rating,
            k = kFor(record, t),
        }
    end
    if t.requireDatabase and not dbReady then
        log(("ranked: match %d not rated -- requireDatabase is set and the bridge is off")
            :format(snapshot.matchId))
        return
    end

    local a, b = sides[1], sides[2]
    for index, side in ipairs(sides) do
        local other = sides[3 - index]
        local score = scoreFor(snapshot, side.playerId)
        local delta = deltaFor(side.before, other.before, score, side.k, t)
        -- The forfeit dial touches the LEAVER's loss only, never the winner's
        -- gain: inflating the survivor's gain would make being left a way to
        -- farm points, which is a worse exploit than the one it patches.
        if snapshot.forfeit and delta < 0 and t.abandonPenaltyScale > 1.0 then
            delta = roundHalfAway(delta * t.abandonPenaltyScale)
        end
        side.score01 = score
        side.delta = delta
        side.after = math.max(t.floorRating, side.before + delta)
        -- The floor can swallow part of a loss, so the delta REPORTED is the
        -- one that actually happened. A notification saying "-14" beside a
        -- rating that moved by 3 is how a player concludes the ladder is
        -- broken.
        side.applied = side.after - side.before
    end

    for _, side in ipairs(sides) do
        local record = side.record
        record.rating = side.after
        record.matches = record.matches + 1
        if side.score01 >= 1.0 then
            record.wins = record.wins + 1
        elseif side.score01 <= 0.0 then
            record.losses = record.losses + 1
            if snapshot.forfeit then record.forfeits = record.forfeits + 1 end
        else
            record.draws = record.draws + 1
        end
        if record.rating > record.peak then record.peak = record.rating end
    end

    for _, round in ipairs(snapshot.rounds) do
        local role = round.winnerRole
        if role == "cop" or role == "runner" then
            roleWins[role] = roleWins[role] + 1
        else
            roleWins.undecided = roleWins.undecided + 1
        end
    end

    local persisted, reason = persist(snapshot, sides)
    if not persisted then
        log(("ranked: match %d NOT PERSISTED (%s) -- the ladder is memory-only this run")
            :format(snapshot.matchId, tostring(reason)))
    end

    log(("ranked: match %d %s mode=%s balanced=%s | %s %d->%d (%+d, K=%.0f, s=%.1f) | %s %d->%d (%+d, K=%.0f, s=%.1f)%s")
        :format(snapshot.matchId,
            snapshot.drawn and "DRAW" or ("outcome=" .. snapshot.outcome),
            snapshot.mode, tostring(snapshot.roleBalanced),
            a.identity.name ~= "" and a.identity.name or a.identity.identifier,
            a.before, a.after, a.applied, a.k, a.score01,
            b.identity.name ~= "" and b.identity.name or b.identity.identifier,
            b.before, b.after, b.applied, b.k, b.score01,
            persisted and "" or "  [VOLATILE]"))

    if not t.announce then return end
    for _, side in ipairs(sides) do
        -- Only to a player still on the roster. A leaver is gone and the
        -- notification would be a no-op at best; his rating moved regardless,
        -- which is the entire point of rating the forfeit.
        if Pursuit.players[side.playerId] ~= nil then
            local provisional = (side.record.matches <= t.provisionalMatches)
                and "  (provisional)" or ""
            Pursuit.notify(side.playerId,
                side.applied >= 0 and "success" or "info",
                ("Rank %d (%+d)%s%s"):format(side.after, side.applied, provisional,
                    persisted and "" or "  — NOT SAVED, no database"),
                6000)
        end
    end
end

-- --------------------------------------------------------------------- hooks --
--
-- Both seams already existed; nothing in match.lua is touched.
--
--   * the `countdown` hook, to capture identities while both players are
--     certainly still connected;
--   * `pursuit:matchResolved`, which `finishMatch` fires once per match with
--     the aggregate champion already decided. It is a local event, so it is
--     asynchronous -- hence the synchronous snapshot before the thread.
Pursuit.onMatch("countdown", function(match)
    if not tunables().enabled then return end
    local slot = identities[match.id]
    if slot == nil then
        slot = { order = {} }
        identities[match.id] = slot
    end
    for _, playerId in ipairs(match.members) do
        local identity = identityOf(playerId)
        -- Never overwrite a known identity with a miss: a player whose
        -- identifier is momentarily unreadable at round two must not lose the
        -- one captured at round one.
        if identity ~= nil then slot[playerId] = identity end
    end
    -- Warm the cache during the countdown, so resolution is a computation
    -- rather than a round trip.
    CreateThread(function()
        for _, playerId in ipairs(match.members) do
            local identity = slot[playerId]
            if identity ~= nil then ensureLoaded(identity) end
        end
    end)
end)

AddEventHandler("pursuit:matchResolved", function(matchId)
    if not tunables().enabled then return end
    matchId = tonumber(matchId)
    if matchId == nil then return end
    -- BIGINT columns and the parameter binder both want an integer; the id is
    -- seeded from a clock that can carry a fraction.
    matchId = math.floor(matchId)
    local snapshot, reason = snapshotMatch(matchId)
    identities[matchId] = nil
    if snapshot == nil then
        log(("ranked: match %s not rated (%s)"):format(tostring(matchId), tostring(reason)))
        return
    end
    CreateThread(function()
        local ok, err = pcall(rateMatch, snapshot)
        if not ok then log("ranked: rating error: " .. tostring(err)) end
    end)
end)

-- A match that never reached a countdown leaves a stale slot behind. Cheap to
-- sweep, and unbounded growth is the part that eventually matters.
Pursuit.onMatch("resolved", function(match)
    if match ~= nil and match.state == "resolved" then identities[match.id] = nil end
end)

-- ---------------------------------------------------------------- describe --

-- Installed and ready, but NOT YET REACHED: `pursuit.match` iterates a fixed
-- list in match.lua -- `{ "vehicles", "scanner", "arena", "roadblock" }` -- so
-- this describer is only printed once "ranked" is added to it. That is a
-- one-word edit to a file this change deliberately does not touch; it is left
-- defined so the edit is the only thing outstanding.
Pursuit.describe = Pursuit.describe or {}
Pursuit.describe.ranked = function(match)
    local t = tunables()
    if not t.enabled then return "disabled" end
    local parts = {}
    for _, playerId in ipairs(match.members) do
        local identity = (identities[match.id] or {})[playerId] or identityOf(playerId)
        local record = identity and ratings[identity.identifier]
        parts[#parts + 1] = ("%d=%s"):format(playerId,
            record and tostring(record.rating) or "?")
    end
    return ("%s%s"):format(table.concat(parts, " "),
        dbReady and "" or " [VOLATILE: no database]")
end

-- ----------------------------------------------------------------- commands --

local function storageLine(t)
    if not t.enabled then return "ranked is DISABLED in config" end
    if dbReady == true then return "persistent (database)" end
    if dbReady == false then
        return "VOLATILE -- no database, every rating is lost on restart (" .. dbReason .. ")"
    end
    return "storage not probed yet (no match has resolved since this reload)"
end

local function reportOne(source, raw, t, playerId)
    local identity = identityOf(playerId)
    if identity == nil then
        return Pursuit.output(source, raw, false,
            ("player %d has no readable identifier; no rating can be keyed to him"):format(playerId))
    end
    local record = ratings[identity.identifier]
    if record == nil then
        -- Not in the cache: load it rather than reporting a default as if it
        -- were a result. Command handlers run on a coroutine, so awaiting here
        -- is legal.
        record = ensureLoaded(identity)
    end
    local provisional = (record.matches < t.provisionalMatches)
        and (" -- PROVISIONAL, %d of %d rated matches, K=%.0f"):format(
            record.matches, t.provisionalMatches, t.provisionalK)
        or ""
    Pursuit.output(source, raw, true,
        ("player %d (%s): %d (peak %d) — %dW %dL %dD over %d match(es)%s%s | %s"):format(
            playerId, record.name ~= "" and record.name or identity.identifier,
            record.rating, record.peak, record.wins, record.losses, record.draws,
            record.matches,
            record.forfeits > 0 and (", %d by forfeit"):format(record.forfeits) or "",
            provisional, storageLine(t)))
end

local function reportTop(source, raw, t)
    if dbReady ~= true then
        local rows = {}
        for _, record in pairs(ratings) do rows[#rows + 1] = record end
        table.sort(rows, function(x, y)
            if x.rating == y.rating then return x.matches > y.matches end
            return x.rating > y.rating
        end)
        Pursuit.output(source, raw, true,
            ("top %d (THIS RUN ONLY -- %s):"):format(
                math.min(#rows, t.leaderboardSize), storageLine(t)))
        for index = 1, math.min(#rows, t.leaderboardSize) do
            local record = rows[index]
            Pursuit.output(source, raw, true, ("  %d. %s %d (%dW %dL %dD)"):format(
                index, record.name ~= "" and record.name or record.identifier,
                record.rating, record.wins, record.losses, record.draws))
        end
        if #rows == 0 then Pursuit.output(source, raw, true, "  (nobody rated yet)") end
        return
    end
    -- `leaderboardSize` is an integer this file clamped to 1..25 in `tunables`
    -- and never a value a player supplied, so formatting it into the statement
    -- is provably safe. It is done rather than bound because LIMIT is the one
    -- clause whose parameter support varies by driver, and a leaderboard that
    -- silently fails on some deployments is not worth the purity.
    local ok, rows = pcall(function()
        return MySQL.query.await(([[
            SELECT identifier, name, rating, matches, wins, losses, draws
              FROM pursuit_ranked_ratings
             ORDER BY rating DESC, matches DESC
             LIMIT %d
        ]]):format(t.leaderboardSize))
    end)
    if not ok then
        return Pursuit.output(source, raw, false, "leaderboard query failed: " .. tostring(rows))
    end
    Pursuit.output(source, raw, true, ("top %d (%s):"):format(t.leaderboardSize, storageLine(t)))
    for index, row in ipairs(rows or {}) do
        Pursuit.output(source, raw, true, ("  %d. %s %d (%dW %dL %dD over %d)"):format(
            index, (row.name ~= nil and row.name ~= "") and row.name or row.identifier,
            math.floor(tonumber(row.rating) or 0),
            math.floor(tonumber(row.wins) or 0), math.floor(tonumber(row.losses) or 0),
            math.floor(tonumber(row.draws) or 0), math.floor(tonumber(row.matches) or 0)))
    end
    if rows == nil or #rows == 0 then
        Pursuit.output(source, raw, true, "  (nobody rated yet)")
    end
end

-- The role-symmetry readout.
--
-- Deliberately prints the SQL as well as the tally: the session figure is a
-- straw poll over however many rounds this VM has seen, and the honest way to
-- answer "is the cop favoured" is the durable table, not the straw poll.
local function reportRoles(source, raw)
    local decided = roleWins.cop + roleWins.runner
    Pursuit.output(source, raw, true, ("rounds this run: cop won %d, runner won %d%s%s"):format(
        roleWins.cop, roleWins.runner,
        roleWins.undecided > 0 and (", %d undecided"):format(roleWins.undecided) or "",
        decided > 0 and ("  (cop %.0f%%)"):format(100.0 * roleWins.cop / decided) or ""))
    Pursuit.output(source, raw, true,
        "durable answer: SELECT mode, winner_role, COUNT(*) FROM pursuit_ranked_rounds " ..
        "GROUP BY mode, winner_role;")
    Pursuit.output(source, raw, true,
        "note: the ladder is rated on MATCHES, and an even round count swaps the roles, " ..
        "so a role imbalance skews the GAME, not the rating -- except in a decider.")
end

RegisterCommand("pursuit.rank", function(source, args, raw)
    local t = tunables()
    local what = tostring((args and args[1]) or "")

    if what == "top" then return reportTop(source, raw, t) end
    if what == "roles" then return reportRoles(source, raw) end
    if what == "config" then
        return Pursuit.output(source, raw, true,
            ("start=%d K=%.0f provisionalK=%.0f for %d match(es) spread=%.0f floor=%d minDelta=%d abandonScale=%.2f | %s")
            :format(t.startRating, t.baseK, t.provisionalK, t.provisionalMatches,
                t.spread, t.floorRating, t.minDelta, t.abandonPenaltyScale, storageLine(t)))
    end

    local playerId = tonumber(what)
    if playerId == nil then playerId = source end
    if playerId == nil or playerId <= 0 then
        return Pursuit.output(source, raw, false,
            "usage: pursuit.rank [playerId | top | roles | config]  (from the console, pass a playerId)")
    end
    if not t.enabled then
        return Pursuit.output(source, raw, false, storageLine(t))
    end
    reportOne(source, raw, t, playerId)
end, false)

AddEventHandler("onResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    local t = tunables()
    if not t.enabled then return log("ranked DISABLED in config") end
    CreateThread(function()
        ensureSchema()
        log(("ranked ready -- Elo, start %d, K %.0f (%.0f for the first %d matches), spread %.0f, floor %d; %s")
            :format(t.startRating, t.baseK, t.provisionalK, t.provisionalMatches,
                t.spread, t.floorRating, storageLine(t)))
    end)
end)
