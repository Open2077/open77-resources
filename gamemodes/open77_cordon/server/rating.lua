-- Cordon -- placement rating. Plan section 11.
--
-- THIS FILE IS PURE ARITHMETIC. It has no engine binding, no database, no
-- player id, no store, and no state that outlives a call, and it does not
-- require a single Open77 global to be present: every global it reads
-- (`Cordon`, `CordonConfig`) is read lazily inside a `pcall` and has a
-- spelled-out default behind it, so the whole module loads and computes
-- correctly in a bare Lua 5.4 state. That is deliberate -- a rating model that
-- can only be exercised by playing an eighteen-minute battle royale is a model
-- nobody checks.
--
-- Everything durable -- the stored rating, the write, the hot-reload carry, and
-- above all the LADDER GATE -- lives in `server/ranked.lua`, which owns the
-- ladder and calls in here for the one question this file answers: given what
-- everybody was rated and where they finished, who moves and by how much.
--
-- The separation is not tidiness. `ranked.lua` refuses a match containing a bot
-- BEFORE it reads a single standings row, and that refusal must remain the only
-- one in the mode. A rating module that could be reached by any other path
-- would be a second door onto the ladder and therefore a second gate to keep in
-- step; there is no such path, because this file cannot find a match on its own.
--
-- ===========================================================================
-- THE MODEL: THE DEATHMATCH FREE-FOR-ALL MODEL IS ALREADY A BATTLE-ROYALE MODEL
-- ===========================================================================
--
-- `open77_deathmatch/server/rating.lua` rates a twelve-player free-for-all by
-- reading the final standings as N(N-1)/2 pairwise results and dividing by
-- N-1. Nothing in that arithmetic is about kills, respawns or a 300 s clock --
-- it is about an ORDER over a field. A battle royale produces exactly that
-- order and produces nothing else: sixty-four players, one final standings
-- list, placement 1 at the top. So the model is copied rather than invented,
-- with the one substitution that matters:
--
--     deathmatch:  S_ij comes from the scoreboard comparator (kills, deaths, score)
--     cordon:      S_ij comes from PLACEMENT, which is the whole result
--
--     delta_i = K_i / (N - 1) * SUM over j /= i of ( S_ij - E_ij )
--
--     S_ij = 1 when i placed ABOVE j (a smaller placement number)
--            0 when i placed below j
--          0.5 when they placed equal (a squad wiped in one volley, a mutual
--              cordon death on the same tick -- see `outcomeBetween`)
--
--     E_ij = 1 / (1 + 10^((R_j - R_i) / spread))
--
-- Five properties, and they are the reasons for this shape rather than another:
--
-- 1. DIVIDING BY N-1 MAKES A MATCH WORTH A MATCH. Without it a 64-player match
--    would move a rating sixty-three times as far as a duel, purely because
--    there were more people in the lobby. With it, a 64-player match and a
--    16-player match are the same size of event, which is what lets one K
--    describe a format whose lobby size varies with the time of day.
--
-- 2. IT IS ZERO-SUM BEFORE ROUNDING. S_ij + S_ji = 1 and E_ij + E_ji = 1 for
--    every pair, and everybody divides by the same N-1, so the deltas sum to
--    zero and the ladder cannot inflate. (Rounding to whole points costs at
--    most half a point per player; see `roundHalfAway`. The floor and the
--    provisional K are the only two things allowed to move the total, and both
--    are deliberate.)
--
-- 3. IT IS SCALE-FREE IN KILLS, DAMAGE AND TIME. All three depend on the loot
--    seed, the drop pin, where the cordon happened to close and how many people
--    were still in the block -- none of which are properties of the player. A
--    PLACEMENT survives all of it, and placement is also the only number the
--    mode actually promises: the last squad standing wins.
--
-- 4. N = 2 DEGENERATES TO TEXTBOOK ELO. The same routine rates a 64-player drop
--    and, if it were ever pointed at one, a two-squad final, and the two cannot
--    drift apart in a way nobody notices.
--
-- 5. IT AGREES WITH THE STANDINGS BY CONSTRUCTION. The rating is computed from
--    the same placement column the result card prints. There is no arrangement
--    of inputs in which a player finishes above somebody and is rated as having
--    finished below them.
--
-- WHAT THIS MODEL REWARDS: finishing above people it expected you to finish
-- below. Placing 3rd of 64 in a lobby of veterans is worth more than placing
-- 3rd of 64 in a lobby of beginners, and being eliminated 60th costs more when
-- the field was weak.
--
-- WHAT IT DOES NOT REWARD, stated plainly because a rating whose blind spots
-- are undocumented gets trusted for things it cannot measure:
--
--   * KILLS. A 12-kill 4th place and a 0-kill 4th place are the same result.
--     This is the single most-argued property of every battle-royale rating and
--     it is chosen, not overlooked: kills are recorded in the career (see
--     `ranked.lua`) and they do not rate, because a kill-weighted rating is a
--     rating of aggression rather than of winning, and this mode's win
--     condition is survival.
--   * MARGIN. Winning with a full squad and winning as the last member of a
--     wiped squad are the same first place.
--   * DAMAGE, ASSISTS, REVIVES. Recorded, never rated -- same reason as kills.
--   * WHERE YOU DROPPED. Landing hot and placing 40th reads exactly like
--     landing in a corner and placing 40th.
--   * DISCONNECTS. Decision 10 makes a disconnect an elimination, so a leaver
--     is rated on the placement his elimination produced. That is harsh and it
--     is the honest reading of the rule the mode already enforces.
--
-- A kill-aware variant is a small change (blend a kill term into S_ij) and is
-- deliberately NOT taken now: it needs a weight nobody has measured, and an
-- unmeasured weight in a rating is worse than a known blind spot.
--
-- ===========================================================================
-- SQUADS: THE MEAN RATES, EVERY MEMBER TAKES THE WHOLE DELTA
-- ===========================================================================
--
-- A duo or squad match is not 64 contestants, it is 32 or 16 of them. Two
-- decisions had to be made explicitly, because a team format does not follow
-- from the formula:
--
-- 1. A SQUAD'S RATING IS THE MEAN OF ITS RATEABLE MEMBERS. The alternatives are
--    the sum (which makes a squad's strength depend on how many people are in
--    it, so a three-man squad after a disconnect would read as weaker rather
--    than as short-handed) and a "strongest member" reading (which lets one
--    veteran carry three beginners at no cost to himself and no benefit to
--    them). The mean is the usual choice and it is the one that keeps duo and
--    squad ratings comparable numbers on the same axis.
--
--    "Rateable" is load-bearing: a member with no master-backed identifier has
--    no rating to average in and receives none, so the mean is taken over the
--    members the ladder can actually key. A squad with nobody rateable cannot
--    form a comparison and is dropped from the field entirely -- it is not
--    rated as a phantom 1000.
--
-- 2. EVERY MEMBER OF A SQUAD TAKES THE WHOLE SQUAD DELTA. It is NOT divided
--    between them. Dividing would make a squad win worth a QUARTER of a solo
--    win, and since the formats rate separately that would not even show up as
--    an imbalance -- it would show up as squad ratings that never leave the
--    start value, and as an incentive to queue solo. A win is a win in every
--    format.
--
--    With equal squads this is still exactly zero-sum: every squad's delta is
--    multiplied by the same member count. The only things that break the
--    balance are a short-handed squad and two players carrying different K (see
--    `kFor`), and the second is deliberate and is what FIDE does.
--
-- THE PAIRWISE FIELD IS SQUADS, NOT PLAYERS. `squadPlacement` normalises by
-- (number of squads - 1), not by (number of players - 1). Sixteen squads is a
-- sixteen-way contest that sixty-four people played, and rating it as a
-- sixty-four-way contest would quadruple every exchange for no reason anybody
-- could point at.
--
-- ===========================================================================
-- THERE IS DELIBERATELY NO OVERALL RATING ACROSS FORMATS
-- ===========================================================================
--
-- Solo, duo and squad are different measurements and this module will never
-- produce a number that spans them. A solo rating measures one person against
-- sixty-three others with nobody to revive them; a squad rating measures a
-- four-person unit, and a large part of what it measures is the unit. Averaging
-- the two would produce a number with no definition at all -- not an imprecise
-- one, an undefined one.
--
-- The consequence for the caller is concrete and is enforced in `ranked.lua`:
-- the rating row is keyed `(identifier, mode)` where `mode` is the FORMAT, and
-- there is no row and no readout line for "overall". Anybody who later wants a
-- headline number has to decide what it means first, and that decision is not
-- this file's to make.
-- ===========================================================================

CordonRating = CordonRating or {}

local Rating = CordonRating


-- --------------------------------------------------------------- tunables --
--
-- Read FRESH on every use and clamped HERE and nowhere else, exactly as the
-- deathmatch and pursuit ladders do it: the Warden panel can move any of these
-- under a running server, and a number typed into a web form must not be able
-- to put the arithmetic into a state it does not survive.
--
-- `ratingK` and `ratedMinPlayers` are the two declared live tunables (plan
-- section 13). `ratedMinPlayers` is consumed by `ranked.lua` rather than here,
-- because "is this match big enough to rate" is a question about the match and
-- not about the arithmetic; this file rates whatever field it is handed.

local DEFAULTS = {
    -- Whether the ladder moves at all. A server can record careers and refuse
    -- to rate them, which is exactly what an unranked playtest server wants.
    enabled = true,

    -- THE BASELINE. A rating means nothing without one, and it is a tunable
    -- rather than a constant for a reason that shows up on the first day: every
    -- unrated player is exactly here, so this number decides whether the ladder
    -- reads as "1000 and climbing" or "1500 and drifting". 1000 matches
    -- `open77_deathmatch` and `pursuit`, so a player who plays all three modes
    -- on this platform sees one scale.
    start = 1000,

    -- The rating difference at which the favourite is expected to score 10/11.
    -- 400 is the Elo convention and there is no measurement on this ladder yet
    -- that would justify moving it.
    spread = 400.0,

    -- Nobody falls below this. A rating that can be driven arbitrarily low
    -- stops being a measurement and becomes a punishment -- and in a mode where
    -- sixty-three of sixty-four players lose every match, the floor is doing
    -- more work here than it does in a duel ladder.
    floor = 100,

    -- A decisive result that rounds to zero reads as a broken ladder, and it is
    -- a real loophole: at a large enough gap the winner would win for free.
    -- Applied only where "decisive" is unambiguous -- see `enforceMinDelta`.
    minDelta = 1,

    -- K PER MATCH, applied after the division by (field - 1).
    --
    -- 32 rather than the deathmatch's 16-per-arena-round because the units are
    -- different: a Cordon match is ~18 minutes of live play and exchanges
    -- ONCE, while a best-of-five arena match is several exchanges over a
    -- comparable stretch. 32 puts an hour of Cordon and an hour of arena in the
    -- same neighbourhood of rating movement, which is the only calibration
    -- available before there is a season of data to fit against.
    --
    -- Note what the division by field-1 does to the felt size of this number: a
    -- 64-player match at K=32 moves a winner by at most 32 points, not by 32
    -- points per opponent. A player who wins a lobby of beginners gains a few
    -- points; one who wins a lobby of veterans gains most of the 32.
    k = 32.0,

    -- ONE K PER FORMAT (plan section 11). The default above applies to every
    -- format; `CordonConfig.rating.formats.<format>.k` overrides it for one.
    -- A squad format exchanges over a field of 16 rather than 64 and an
    -- operator may well want that to move less; there is no measurement yet
    -- that says by how much, so the default is a single K and the override
    -- exists for when there is.

    -- A new player's rating is a guess and should move a long way; a settled
    -- player's is evidence and should not. Ten matches at ~20 minutes each is
    -- roughly one evening, which is the right size of window for "we do not
    -- know what you are yet".
    provisionalMatches = 10,
    provisionalScale = 2.0,
}
Rating.DEFAULTS = DEFAULTS


-- ----------------------------------------------- global access, guardedly --
--
-- Every global read in this file goes through one of the functions below.
--
-- Two reasons, and the second is the one that decided it. First, load order:
-- `shared/config.lua` and `server/kernel.lua` are owned by other files and this
-- one must not care whether either has run. Second and more importantly, THIS
-- MODULE IS MEANT TO BE UNIT-TESTABLE IN A BARE LUA STATE -- no `Cordon`, no
-- `CordonConfig`, no `Open77`, no `MySQL`. Reading an undeclared global is
-- legal Lua and yields nil, but a host that installs a strict-mode metatable on
-- the globals table would RAISE instead, and a rating module that cannot be
-- loaded outside the game is a module whose arithmetic is only ever checked by
-- playing an eighteen-minute match and then reading a table.

local function globalTable(name)
    local ok, value = pcall(function() return _ENV[name] end)
    if not ok or type(value) ~= "table" then return nil end
    return value
end

-- `Cordon.tune.<key>` is A CALL BEHIND A METATABLE (the kernel's tunable
-- registry), so it is read at the point of use and never captured -- the panel
-- can move it between two matches. Wrapped because a server whose kernel has
-- not started yet, or which never declared the tunable, has no registry at all.
local function live(key)
    if key == nil then return nil end
    local root = globalTable("Cordon")
    if root == nil then return nil end
    local tune = root.tune
    if type(tune) ~= "table" then return nil end
    local ok, value = pcall(function() return tune[key] end)
    if not ok then return nil end
    return value
end

local function configured(key, format)
    local config = globalTable("CordonConfig")
    local block = config ~= nil and config.rating or nil
    if type(block) ~= "table" then return nil end
    -- The per-format override wins over the mode-wide value, so
    -- `rating.formats.squad.k` beats `rating.k`. One K per format, section 11.
    if format ~= nil and type(block.formats) == "table" then
        local perFormat = block.formats[tostring(format)]
        if type(perFormat) == "table" and perFormat[key] ~= nil then return perFormat[key] end
    end
    if block[key] ~= nil then return block[key] end
    return nil
end

-- Live tunable, then per-format config, then mode-wide config, then the default
-- spelled out above -- so a server whose config predates this file still rates.
local function pick(tuneKey, key, format)
    local value = live(tuneKey)
    if value ~= nil then return value end
    value = configured(key, format)
    if value ~= nil then return value end
    return DEFAULTS[key]
end


-- ---------------------------------------------------------------- clamps --

local function clampNumber(value, fallback, low, high)
    local n = tonumber(value)
    -- NaN compares false against everything, including its own bounds, so it
    -- would pass both clamps untouched and then poison every expectation it
    -- reaches. It is caught here rather than allowed to propagate into a rating
    -- that silently never settles.
    if n == nil or n ~= n then return fallback end
    if n < low then return low end
    if n > high then return high end
    return n
end

local function clampInteger(value, fallback, low, high)
    return math.floor(clampNumber(value, fallback, low, high) + 0.5)
end

--- Every tunable this file has, clamped, for ONE format. One call per match;
--- pass the result around rather than re-reading, so one match is rated by one
--- set of numbers even if the panel moves them halfway through the write.
---
--- `format` is "solo", "duo", "squad" or whatever the config declares; it
--- selects the per-format K and nothing else. Passing nil is legal and yields
--- the mode-wide numbers.
function Rating.settings(format)
    local s = {
        format             = format ~= nil and tostring(format) or nil,
        enabled            = pick("ratingEnabled", "enabled", format) ~= false,
        start              = clampInteger(pick("ratingStart", "start", format),
                                          DEFAULTS.start, 100, 5000),
        spread             = clampNumber(pick(nil, "spread", format),
                                         DEFAULTS.spread, 50.0, 2000.0),
        floor              = clampInteger(pick(nil, "floor", format),
                                          DEFAULTS.floor, 0, 5000),
        minDelta           = clampInteger(pick(nil, "minDelta", format),
                                          DEFAULTS.minDelta, 0, 50),
        k                  = clampNumber(pick("ratingK", "k", format),
                                         DEFAULTS.k, 1.0, 200.0),
        provisionalMatches = clampInteger(pick(nil, "provisionalMatches", format),
                                          DEFAULTS.provisionalMatches, 0, 100),
        provisionalScale   = clampNumber(pick(nil, "provisionalScale", format),
                                         DEFAULTS.provisionalScale, 1.0, 5.0),
    }
    -- A floor above the baseline would put every new player instantly
    -- underwater, which is the one configuration the arithmetic cannot mean.
    if s.floor > s.start then s.floor = s.start end
    return s
end


-- ------------------------------------------------------------------- Elo --

--- What we expected of a rating `a` against a rating `b`, 0..1.
function Rating.expected(a, b, spread)
    return 1.0 / (1.0 + 10.0 ^ ((b - a) / (spread or DEFAULTS.spread)))
end

--- Round half AWAY from zero. `math.floor(x + 0.5)` is wrong for negatives --
--- it turns -0.5 into 0 and biases every loss upward by half a point. In a mode
--- where sixty-three of sixty-four results are losses, that bias is not a
--- rounding curiosity: it is a free half-point per player per match, and the
--- whole ladder inflates.
function Rating.roundHalfAway(value)
    if value >= 0 then return math.floor(value + 0.5) end
    return -math.floor(-value + 0.5)
end

--- The K a player carries into THIS match, from the rated matches they had
--- BEFORE it. Every player uses their OWN K, so a provisional player in a field
--- of settled ones moves further than they do and the exchange is not exactly
--- zero-sum. That is deliberate and is what FIDE does: a ladder is a
--- measurement, not a currency, and refusing to let a beginner converge in
--- order to keep the books balanced would be optimising the wrong thing.
function Rating.kFor(baseK, ratedMatches, s)
    local matches = math.max(0, math.floor(tonumber(ratedMatches) or 0))
    if matches < (s.provisionalMatches or 0) then
        return baseK * (s.provisionalScale or 1.0)
    end
    return baseK
end

-- A decisive result must move something. "Decisive" here means beating the
-- WHOLE field (placement 1, `scored == maximum`) or losing to all of it (last,
-- `scored == 0`). A mid-table finish is genuinely allowed to be worth nothing,
-- and in a 64-player field most of them are: that is what it means for the
-- model to be normalised.
local function enforceMinDelta(delta, actual, maximum, s)
    if s.minDelta <= 0 then return delta end
    if actual >= maximum and delta < s.minDelta then return s.minDelta end
    if actual <= 0.0 and delta > -s.minDelta then return -s.minDelta end
    return delta
end


-- ------------------------------------------------------- pairwise outcome --

--- One contestant's result against another, read off PLACEMENT alone.
--- 1 / 0.5 / 0, where placement 1 is the winner and a SMALLER number is better.
---
--- The tie is not decoration. Two squads wiped by the same cordon tick, or two
--- solo players who flatline each other, genuinely share a placement, and the
--- mode's own standings say so. Inventing a tiebreak here -- on kills, on
--- damage, on name -- would make the rating disagree with the card the players
--- just read, and that disagreement is the one failure a placement model exists
--- to rule out.
local function outcomeBetween(a, b)
    if a.placement == b.placement then return 0.5 end
    return a.placement < b.placement and 1.0 or 0.0
end
Rating.outcomeBetween = outcomeBetween


-- ------------------------------------------------------ input normalising --

-- An entry is `{ key, rating, placement, matches }`.
--
--   key        opaque -- this file never sees a player id, a name or an
--              identifier, only something to hang a result on
--   rating     the contestant's rating BEFORE this match
--   placement  1 = winner; ties are legal and rate as draws
--   matches    rated matches already behind them, which picks the K
--
-- Anything without a usable key or a usable placement is DROPPED rather than
-- guessed at. Placing an entry "last" because its placement was unreadable
-- would silently hand everybody else a free win over a contestant nobody can
-- name; the count of drops is reported in the note so the caller can see that
-- it happened rather than discovering it as an unexplained field size.
local function normalise(entries, s)
    local list, seen, dropped = {}, {}, 0
    for _, entry in ipairs(entries or {}) do
        local key = type(entry) == "table" and entry.key or nil
        local placement = type(entry) == "table" and tonumber(entry.placement) or nil
        if type(key) ~= "string" or key == "" or seen[key]
            or placement == nil or placement ~= placement or placement < 1 then
            dropped = dropped + 1
        else
            seen[key] = true
            list[#list + 1] = {
                key = key,
                rating = clampInteger(entry.rating, s.start, 0, 100000),
                placement = math.floor(placement),
                matches = math.max(0, math.floor(tonumber(entry.matches) or 0)),
                squad = entry.squad,
            }
        end
    end
    return list, dropped
end

-- The shared core of both public entry points: N contestants with a placement
-- each, compared pairwise. It computes `scored` and `expectedScore` and stops
-- there -- the K, the delta and the minimum are applied by the caller, because
-- `squadPlacement` expands ONE squad comparison into per-member deltas that
-- each carry their own K.
local function pairwise(list, s)
    local count = #list
    local results = {}
    for _, contestant in ipairs(list) do
        local scored, expectedScore = 0.0, 0.0
        for _, other in ipairs(list) do
            if other ~= contestant then
                scored = scored + outcomeBetween(contestant, other)
                expectedScore = expectedScore
                    + Rating.expected(contestant.rating, other.rating, s.spread)
            end
        end
        results[#results + 1] = {
            key = contestant.key,
            before = contestant.rating,
            matches = contestant.matches,
            placement = contestant.placement,
            squad = contestant.squad,
            -- `scored` and `expectedScore` are both out of `count - 1`, so
            -- `actual` and `expected` below are directly comparable fractions
            -- and the delta is per MATCH rather than per pair.
            scored = scored,
            expectedScore = expectedScore,
            actual = scored / (count - 1),
            expected = expectedScore / (count - 1),
            field = count,
        }
    end
    return results
end

-- The floor is applied HERE and the delta is then CORRECTED to match, so the
-- number reported as a delta and the number a caller adds to a stored rating can
-- never disagree about where a player ended up. `ranked.lua` writes the delta to
-- SQL and repeats the floor there with `GREATEST`; the two must agree, and they
-- do because both read `settings.floor`.
local function finish(results, s, baseK)
    local deltas = {}
    for _, result in ipairs(results) do
        local after = result.before + result.delta
        if after < s.floor then after = s.floor end
        result.after = after
        result.delta = after - result.before
        result.provisional = result.k > baseK + 1e-9
        deltas[result.key] = result.delta
    end
    return deltas
end


-- ------------------------------------------------------------- solo entry --

--- Rate one finished SOLO match.
---
--- `entries` is an array of `{ key, rating, placement, matches }`, placement 1
--- being the winner. `options` may carry `settings` (from `Rating.settings`) and
--- `format` (used only to pick the per-format K when `settings` is not given).
---
--- Returns `deltas, results, note`:
---   deltas   map of key -> integer delta -- the answer, and the whole contract
---   results  array of per-contestant detail (before, after, k, expected,
---            actual, placement, field, provisional) for a readout
---   note     nil on success; a sentence saying what happened otherwise
---
--- Returns `nil, nil, note` when the match cannot be rated at all. Nil rather
--- than an empty map on purpose: "nobody moved" and "this could not be rated"
--- are different facts, and a caller that conflates them records a match to the
--- ladder as a silent no-op instead of reporting the refusal.
function Rating.placement(entries, options)
    options = type(options) == "table" and options or {}
    local s = options.settings or Rating.settings(options.format)
    if not s.enabled then
        return nil, nil, "rating is disabled in this server's config"
    end

    local list, dropped = normalise(entries, s)
    if #list < 2 then
        return nil, nil, ("fewer than two rateable contestants (%d usable, %d dropped)")
            :format(#list, dropped)
    end

    local results = pairwise(list, s)
    for _, result in ipairs(results) do
        result.k = Rating.kFor(s.k, result.matches, s)
        result.delta = Rating.roundHalfAway(
            result.k * (result.scored - result.expectedScore) / (result.field - 1))
        -- `field - 1` is the maximum attainable, so the outright win and the
        -- outright last place are the only two finishes the minimum applies to.
        result.delta = enforceMinDelta(result.delta, result.scored, result.field - 1, s)
    end

    local deltas = finish(results, s, s.k)
    local note = nil
    if dropped > 0 then
        note = ("%d entry(ies) dropped for a missing key or placement"):format(dropped)
    end
    return deltas, results, note
end


-- ------------------------------------------------------------ squad entry --

--- Rate one finished DUO or SQUAD match.
---
--- `squads` is an array of `{ id, members = { { key, rating, matches }, ... },
--- placement }`, placement 1 being the winning squad. `options` is as above.
---
--- Returns `deltas, results, note` with the same contract as `Rating.placement`
--- -- `deltas` is keyed by MEMBER key, not by squad id, because the ladder is a
--- ladder of people. `results` carries one row per member with `squad`,
--- `squadRating` and `squadSize` set, so a readout can group them again.
---
--- THE FIELD IS SQUADS. The pairwise comparison runs over squads and normalises
--- by (squads - 1); every member of a squad then takes the WHOLE squad delta,
--- computed with that member's OWN K. See the header for why both halves of
--- that are chosen rather than inherited.
function Rating.squadPlacement(squads, options)
    options = type(options) == "table" and options or {}
    local s = options.settings or Rating.settings(options.format)
    if not s.enabled then
        return nil, nil, "rating is disabled in this server's config"
    end

    -- Build one pseudo-contestant per squad, rated by the MEAN of its rateable
    -- members. A squad with no rateable member forms no comparison and is left
    -- out of the field entirely rather than entered at the baseline: a phantom
    -- 1000 in the standings would hand every real squad an expectation against
    -- somebody who is not being rated back, and the books would stop balancing.
    local sides, membersOf = {}, {}
    local seen, droppedSquads, droppedMembers = {}, 0, 0

    for index, squad in ipairs(squads or {}) do
        local placement = type(squad) == "table" and tonumber(squad.placement) or nil
        local members = {}
        if type(squad) == "table" and type(squad.members) == "table" then
            for _, member in ipairs(squad.members) do
                local key = type(member) == "table" and member.key or nil
                if type(key) ~= "string" or key == "" or seen[key] then
                    -- A duplicate key across two squads is not a merge case: one
                    -- person cannot be on two sides of the same match, and
                    -- letting them be would give one contestant two votes in
                    -- every pairwise comparison. First occurrence wins.
                    droppedMembers = droppedMembers + 1
                else
                    seen[key] = true
                    members[#members + 1] = {
                        key = key,
                        rating = clampInteger(member.rating, s.start, 0, 100000),
                        matches = math.max(0, math.floor(tonumber(member.matches) or 0)),
                    }
                end
            end
        end

        if placement == nil or placement ~= placement or placement < 1 or #members == 0 then
            droppedSquads = droppedSquads + 1
            droppedMembers = droppedMembers + #members
            -- Members of a dropped squad must not stay in `seen`, or a later
            -- squad legitimately holding the same key would lose the member
            -- because of a squad that is not even in the field.
            for _, member in ipairs(members) do seen[member.key] = nil end
        else
            local total = 0
            for _, member in ipairs(members) do total = total + member.rating end
            local id = (type(squad) == "table" and squad.id ~= nil) and squad.id or index
            sides[#sides + 1] = {
                key = "squad:" .. tostring(id),
                squad = id,
                rating = total / #members,
                placement = math.floor(placement),
                -- Unused for a side: K is resolved PER MEMBER below, because a
                -- provisional player in a settled squad must still converge.
                matches = 0,
            }
            membersOf[#sides] = members
        end
    end

    if #sides < 2 then
        return nil, nil, ("fewer than two rateable squads (%d usable, %d dropped)")
            :format(#sides, droppedSquads)
    end

    local sideResults = pairwise(sides, s)

    -- Expand each squad's result into one row per member. The squad's
    -- (scored - expectedScore) is SHARED and the K is NOT: that is exactly the
    -- "whole delta each, own K each" rule from the header.
    local results = {}
    for index, side in ipairs(sideResults) do
        local members = membersOf[index]
        for _, member in ipairs(members) do
            local k = Rating.kFor(s.k, member.matches, s)
            local delta = Rating.roundHalfAway(
                k * (side.scored - side.expectedScore) / (side.field - 1))
            delta = enforceMinDelta(delta, side.scored, side.field - 1, s)
            results[#results + 1] = {
                key = member.key,
                before = member.rating,
                matches = member.matches,
                k = k,
                delta = delta,
                placement = side.placement,
                squad = side.squad,
                squadRating = side.before,
                squadSize = #members,
                expected = side.expected,
                actual = side.actual,
                scored = side.scored,
                expectedScore = side.expectedScore,
                field = side.field,
            }
        end
    end

    local deltas = finish(results, s, s.k)
    local note = nil
    if droppedSquads > 0 or droppedMembers > 0 then
        note = ("%d squad(s) and %d member(s) dropped as unrateable")
            :format(droppedSquads, droppedMembers)
    end
    return deltas, results, note
end


-- ----------------------------------------------------------------- readout --

--- One line saying what the model currently is, for `/br.stats` and for the
--- operator readout. A rating nobody can see the parameters of is a magic
--- number with a database behind it, and the first question a player asks about
--- a rating is what the numbers mean.
function Rating.describe(s)
    s = s or Rating.settings()
    if not s.enabled then return "rating DISABLED in config" end
    return ("%splacement model, start %d, spread %d, K %g/match (divided by field-1), floor %d, first %d match(es) at x%g")
        :format(s.format ~= nil and (s.format .. ": ") or "",
            s.start, s.spread, s.k, s.floor, s.provisionalMatches, s.provisionalScale)
end

return CordonRating
