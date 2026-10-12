-- Pursuit -- match lifecycle and win conditions.
--
-- Owns everything from "two players are queued" to "both are back in the
-- lobby": bucket allocation, role assignment, spawn placement, the countdown,
-- the head start, the match clock, the four win conditions, resolution, and
-- the release path when someone leaves mid-match.
--
-- Phase B built the state machine; Phase C hangs the rules on it without
-- changing its shape. Phase E adds vehicles the same way -- the roles and the
-- resolution vocabulary do not change when the distance numbers do, which is
-- why `tuning()` is the only thing that has to switch columns.
--
-- This file shares a Lua state with server/main.lua and reaches it through the
-- `Pursuit` global. That is not laziness: the server runtime installs no
-- exports and no cross-resource event bus, so one gamemode is necessarily one
-- server resource, and files within it share globals.

local Config = PursuitConfig

-- matchId -> match record
local matches = {}
-- playerId -> matchId
local playerMatch = {}
-- bucket -> matchId, so allocation never hands the same dimension to two matches
local bucketOwner = {}
-- Match ids must be unique for as long as anything can still refer to them,
-- and that is the SERVER RUN, not the resource generation.
--
-- A hot reload wipes every local in this file -- `matches`, `playerMatch`,
-- vehicles.lua's `fleets` -- while the server, its log, the routing buckets and
-- whatever is reading the log all carry on. Restarting at 1 therefore mints a
-- second "match 1" a few minutes after the first, and the two are
-- indistinguishable in the only record that outlives them. Observed on
-- 2026-08-26: `match 10` at 08:05, reload, `match 1` at 08:10.
--
-- Seeded from server uptime in MILLISECONDS instead. `Open77.time.monotonic`
-- is the server clock and does not restart with the resource, so a reload
-- resumes above every id already issued -- no store, no persistence.
--
-- Milliseconds rather than seconds so the claim is actually true rather than
-- merely likely: the counter advances one per match, the seed advances a
-- thousand per second, so a reload can only collide with ids this run already
-- issued if the mode created a thousand matches in a second. Seconds would
-- have left a 1:1 race that a burst of forced matches could win.
--
-- The price is that an id stops being a small ordinal. An id is a handle, not
-- a count, and being able to trust it across a reload is worth more than
-- reading "match 3".
--
-- Seeded LAZILY, on the first allocation, and that is not a style choice. The
-- server clock is an upvalue the host writes on each tick, so at resource LOAD
-- time it still reads 0 -- seeding at the top of this file produced `match 1`
-- after a reload exactly as before, and the change looked applied while
-- changing nothing. Measured 2026-08-26, which is why the seed moved here.
local nextMatchId = nil

-- pairKey -> { roles = { [playerId] = role }, atMs }
-- Remembered so a rematch between the same two swaps sides (design 5.5 item 8).
local lastPairing = {}

local ROLES = { "cop", "runner" }

-- The tick period, needed outside the tick thread to bound the elapsed time a
-- single iteration may credit to an accumulator.
local TICK_MS = math.floor(1000 / math.max(1, Config.tickHz))

-- How often the active tick feeds the HUD. Deliberately slower than the tick
-- itself: the win conditions need 5 Hz because they integrate held time, but
-- the readout is looked at by a human eye, and the extra six packets a second
-- per player buy nothing. One number, one place, so the throttle cannot drift
-- away from the thing it throttles.
--
-- It is a floor, not a period, and the tick QUANTISES it. Pushes are only
-- considered once per tick, so the real interval is the first multiple of
-- TICK_MS at or above this number: 500 becomes 600. Measured 2026-08-26 with
-- `pursuit.hudtrace`, over two matches -- 633-700 ms between pushes, i.e.
-- ~1.5 Hz rather than the 2 Hz the figure suggests. The achievable rates
-- against a 200 ms tick are 400 / 600 / 800 ms and nothing between, so do not
-- read this constant as a promise of 2 Hz.
local HUD_PUSH_MS = 500

local function log(text) Pursuit.log(text) end
local function nowMs() return Pursuit.nowMs() end

-- ------------------------------------------------------------- tunables --
--
-- The numbers a server owner may move from Warden's Tuning tab, declared in
-- shared/config.lua and registered by server/main.lua, which puts the live
-- proxy in the shared global `Tune`.
--
-- THE ONE RULE: `Tune.key` is a call into the host, not a field. A `local`
-- taken at FILE scope freezes the value at load, and every later change from
-- the panel then silently does nothing while the panel goes on reporting the
-- new number. Nothing in this file holds one: every read below is inside a
-- function, at the point of use. A local inside a function is fine -- it lives
-- one call.

-- The mode the NEXT match will be created in.
--
-- This used to be a file-scope local seeded from `Config.match.mode` and moved
-- by `pursuit.mode`. It is the `matchMode` tunable now, so the console command
-- and the Tuning tab cannot disagree about what the next match will be: one
-- value, one validation, one place it persists.
--
-- IT READS `pending()` FIRST, and that is not an optimisation. `matchMode` is
-- declared `next_match`, so a write is stored and persisted at once but held by
-- the host until this resource promotes -- which it does at match creation, one
-- line before it captures. Between the write and that promotion the effective
-- value is still the old one, so a bare `Tune.matchMode` would answer "what the
-- LAST match got" to a question that is asking about the next one.
local function nextMode()
    local pending = Open77.tunables.pending()
    local wanted = pending.matchMode or Tune.matchMode
    return (wanted == "foot") and "foot" or "vehicle"
end

-- One tunable as a MATCH plays it: its own capture if it has one, and the live
-- value otherwise.
--
-- Every match freezes the whole tunable set at creation (`match.tune`), and
-- this is what reads it back. It is what stops a retune from moving a rule
-- under two people already chasing each other -- including the OTHER match, in
-- another routing bucket, which is the case `promote()` alone cannot serve:
-- promotion is per resource, so promoting at match B's creation would move
-- match A's finish line if match A were reading the live value.
--
-- The `~= nil` test rather than an `or` chain is load-bearing:
-- `copDeathEndsMatch` is a boolean, and `capture[key] or fallback` would
-- silently throw away a captured `false`.
local function tuned(match, key)
    local capture = (match ~= nil) and match.tune or nil
    if capture ~= nil and capture[key] ~= nil then return capture[key] end
    return Tune[key]
end

-- The tunables that overlay a DISTANCE COLUMN, by the column field they carry.
--
-- The names are deliberately identical on both sides so the overlay is a copy
-- rather than a mapping nobody would keep in step. Adding a key to the
-- `tunables` block in shared/config.lua and forgetting it here would leave a
-- control in the panel that moves nothing, so the two lists are checked against
-- each other at start -- see `onResourceStart` at the foot of this file.
local COLUMN_KEYS = {
    "bustDistance", "bustCoreDistance", "bustCoreFactor",
    "bustFillSeconds", "bustDrainSeconds",
    -- The 2026-08-28 arrest gate and crash stall -- see the long note above
    -- the distance columns in shared/config.lua.
    "bustRunnerMaxSpeedKph", "bustCopMaxSpeedKph", "bustContactDrainSeconds",
    "crashStallSeconds", "crashMinSpeedKph", "crashDropKph",
    "escapeDistance", "escapeGraceSeconds", "escapeDrainSeconds", "escapeArmSeconds",
    "durationSeconds", "headStartSeconds",
}

-- The distance column, with the match's captured tunables laid over it.
--
-- Given a match it returns the column that match was CREATED with and the
-- values it was created with; given nothing it returns what the NEXT match will
-- get. Those are two different questions, and answering both with one global
-- would let `pursuit.mode` -- or the panel -- move the finish line under two
-- people already playing. Phase C called this with no argument everywhere
-- because there was only one column; every in-match call site now passes its
-- match.
--
-- THE OVERLAY SUPERSEDES THE COLUMN for every key in `COLUMN_KEYS`, in both
-- modes, whether or not an operator has touched it -- the declared default IS
-- the value. That is what makes the panel honest: an owner who reads "15 m"
-- gets 15 m in whichever mode he switched to. Its cost, stated in
-- shared/config.lua where the columns live, is that foot mode no longer carries
-- its own tuned figures.
--
-- Merged ONCE per match and cached on the match. The capture is frozen and the
-- mode cannot change, so the result cannot either; without the cache the tick
-- would rebuild this table several times a second per match.
local function tuning(match)
    if match == nil then
        -- What the next match will get, pending writes included, so a command
        -- that has just been given a new number reports the new number.
        local mode = nextMode()
        local column = Config.match[mode] or Config.match.foot
        local pending = Open77.tunables.pending()
        local merged = {}
        for key, value in pairs(column) do merged[key] = value end
        for _, key in ipairs(COLUMN_KEYS) do
            local value = pending[key]
            if value == nil then value = Tune[key] end
            if value ~= nil then merged[key] = value end
        end
        return merged, mode
    end

    local mode = match.mode
    local column = Config.match[mode] or Config.match.foot
    if match.rules == nil then
        local merged = {}
        for key, value in pairs(column) do merged[key] = value end
        for _, key in ipairs(COLUMN_KEYS) do
            local value = tuned(match, key)
            if value ~= nil then merged[key] = value end
        end
        match.rules = merged
    end
    return match.rules, mode
end

-- ----------------------------------------------------------------- geometry --
--
-- Shared by every Phase E module. They live here rather than in a file of their
-- own because match.lua is loaded immediately before them, so `Pursuit` already
-- carries them by the time vehicles/scanner/bounds/roadblock run -- there is no
-- load-order trap left to remember.
--
-- The convention is the one MEASURED on the spawn marks and recorded in
-- shared/config.lua: a yaw y in degrees faces the world direction
-- (-sin y, cos y). Everything below is that single identity, read forwards and
-- backwards; nothing here is a fresh assumption about the engine.

local function forwardFromHeading(headingDegrees)
    local radians = math.rad(headingDegrees or 0.0)
    return { x = -math.sin(radians), y = math.cos(radians) }
end

-- The perpendicular of the above: the mark's own right-hand side.
local function rightFromHeading(headingDegrees)
    local radians = math.rad(headingDegrees or 0.0)
    return { x = math.cos(radians), y = math.sin(radians) }
end

-- Inverse of forwardFromHeading: the yaw that faces (dx, dy).
-- forward = (-sin y, cos y)  =>  y = atan2(-dx, dy).
--
-- Returns nil rather than 0 for a degenerate vector. A zero-length difference
-- means "he has not moved", and 0 degrees is a direction -- returning it would
-- turn "no information" into "due north", which is how a roadblock ends up in
-- the sea.
local function headingFromVector(dx, dy)
    if dx == nil or dy == nil then return nil end
    if (dx * dx + dy * dy) < 1e-8 then return nil end
    return math.deg(math.atan(-dx, dy))
end

-- ---------------------------------------------------------- extension points --
--
-- Phase E adds four concerns -- cars, the scanner, arena bounds, roadblocks --
-- that all want the same three moments and the same 5 Hz tick. They cannot be
-- separate RESOURCES: the server runtime installs no exports and no
-- cross-resource event bus, so a second server resource could not be asked for
-- anything. They are therefore separate FILES that register here.
--
-- Direct calls, not TriggerEvent, and that is deliberate. TriggerEvent on this
-- runtime `schedule()`s each handler as a coroutine (see the Lua prelude in
-- LuaResourceRuntime.cs), so it is ASYNCHRONOUS. That is fine for lifecycle
-- fan-out and is used for exactly that below -- but the scanner has to have
-- written `scannerAgeMs` before this tick's HUD payload is built, and a bounds
-- rule has to be able to end the match on the tick that decided it. Neither
-- survives being deferred to the next scheduler pass.
--
-- Every hook is pcall'd. A bug in a Phase E module must not take the tick
-- thread down with it: that would strand every player in a match bucket with no
-- clock running.
local hooks = { countdown = {}, active = {}, tick = {}, resolved = {} }

local function onMatch(kind, fn)
    local list = hooks[kind]
    if list == nil then error("unknown match hook: " .. tostring(kind)) end
    list[#list + 1] = fn
end

local function fireHooks(kind, match, now)
    for _, fn in ipairs(hooks[kind]) do
        local ok, err = pcall(fn, match, now)
        if not ok then
            log(("match %s %s hook error: %s"):format(
                tostring(match and match.id), kind, tostring(err)))
        end
    end
end

-- ------------------------------------------------------------------ buckets --

local function allocateBucket()
    for bucket = Config.match.buckets.from, Config.match.buckets.to do
        if bucketOwner[bucket] == nil then return bucket end
    end
    return nil
end

local function releaseBucket(bucket)
    if bucket == nil then return end
    bucketOwner[bucket] = nil
    -- Leave the policy in place: buckets are reused, and re-applying it on the
    -- next allocation is cheaper than churning it here.
end

-- ------------------------------------------------------------------ helpers --

local function push(match, event, payload)
    for _, playerId in ipairs(match.members) do
        TriggerClientEvent(event, playerId, payload)
    end
end

local function notify(playerId, kind, message, durationMs)
    Open77.notifications.send(playerId, {
        type = kind,
        title = "Pursuit",
        message = message,
        durationMs = durationMs or 5000,
    })
end

-- How many rounds this match is. From the match's own captured
-- `roundsPerMatch` tunable, so a retune reaches the next match and never this
-- one.
--
-- Takes the MATCH, not the config, for anything that can change mid-match: a
-- decider adds exactly one round to a drawn match and must not be able to add a
-- second one, and a config edit during a live match must not move the finish
-- line under two people who are already playing -- the same discipline
-- `tuning()` applies to the distance column.
local function roundCount(match)
    local total = tonumber(tuned(match, "roundsPerMatch")) or 1
    if total < 1 then total = 1 end
    if match ~= nil and match.deciderAdded then total = total + 1 end
    return total
end

local function matchStatePayload(match, extra)
    local t, mode = tuning(match)
    local payload = {
        matchId = match.id,
        state = match.state,
        mode = mode,
        durationSeconds = t.durationSeconds,
        countdownSeconds = tuned(match, "countdownSeconds"),
        headStartSeconds = t.headStartSeconds,
        escapeDistance = t.escapeDistance,
        bustDistance = t.bustDistance,
        -- Who the clock favours, so the HUD can label the timer honestly
        -- ("Cop wins in" against "Time") without holding the rule itself.
        timeoutWinner = tostring(tuned(match, "timeoutWinner") or "cop"),
        copReleased = match.copReleased == true,
        -- The round, always, even in a one-round match: the HUD hides the
        -- readout when `roundCount` is 1, and deciding that here would mean two
        -- places knowing what a match is shaped like.
        round = match.round or 1,
        roundCount = roundCount(match),
        -- TRUE exactly while the round being played IS the sudden-death
        -- decider. The HUD cannot infer it from round == roundCount -- a
        -- match configured to three ordinary rounds looks identical -- and a
        -- player in the round that decides the match must be told so.
        decider = (match.deciderAdded == true
            and (match.round or 1) >= roundCount(match)) or nil,
    }
    if extra then
        for key, value in pairs(extra) do payload[key] = value end
    end
    return payload
end

-- The scanner readout, for one player.
--
-- Sent to the COP only. `pursuit_hud` already renders it behind
-- `s.role === 'cop'` and hides the readout when the key is absent, so a runner
-- who was never sent the key simply has no scanner panel -- which is the whole
-- design: he is the thing being scanned, not the one holding the scanner.
--
-- `Pursuit.scannerAgeMs` is installed by server/scanner.lua and is optional on
-- purpose. Nothing here breaks when the scanner is disabled or absent; the key
-- is omitted, and omitted is exactly how the HUD is told "no data".
-- Live separation, for one player, and ONLY for the runner.
--
-- This is an information rule, not a display choice, which is why it lives on
-- the server: a number the client never receives cannot be read out of it.
--
-- Separation was previously sent to both sides and drawn as live metres. For
-- the cop that is a hot-and-cold meter: drive, watch the number fall, turn when
-- it rises. It is trilateration by feel, and it deletes the mechanic the whole
-- mode is built on -- the scanner fix is deliberately STALE so that the cop has
-- to think about where the runner is GOING, and a live distance readout means
-- he never has to. The owner's "c'est trop facile pour le policier" was this,
-- among other leaks.
--
-- The asymmetry is the mechanic, and it is not a handicap:
--
--   * the RUNNER keeps it. He is the one being hunted and feeling the threat
--     close is the tension of the role; he also cannot use it to find anyone,
--     because he is not looking for anybody.
--   * the COP gets the BUST METER instead, which is strictly better
--     information for his actual job -- it says whether he is succeeding
--     rather than how far away something is. And it leaks nothing: it is zero
--     everywhere beyond `bustDistance`, so it cannot be driven around and
--     watched. Inside 15 m he can see the car out of the windscreen anyway.
--
-- No coarse near/mid/far band either, deliberately. A band is the same channel
-- with fewer bits: a cop can still drive and watch it change, and binary-search
-- a runner he cannot see. Fewer bits is a slower leak, not a closed one.
-- The ESCAPE METER, 0..1, or nil while no attempt is running. Sent to BOTH
-- sides: a runner needs to know how much longer he has to keep the gap, and a
-- cop needs to know he is about to lose. The bar it drives on the HUD is the
-- same bar as the bust meter, because the two cannot both be happening --
-- separation cannot be at once below `bustDistance` and at or above
-- `escapeDistance`.
--
-- nil rather than 0 when empty, so the bar leaves the screen between attempts
-- instead of sitting at 0% for the whole chase -- the meter is an EVENT, not a
-- permanent gauge, and an empty escape bar would read as furniture.
local function escapeProgressOf(match)
    local meter = match.escapeMeter or 0.0
    if meter <= 0.0 then return nil end
    if meter > 1.0 then meter = 1.0 end
    return meter
end

local function separationFor(match, playerId, sep)
    if sep == nil then return nil end
    if match.roles[playerId] ~= "runner" then return nil end
    return sep
end

local function scannerAgeFor(match, playerId, now)
    if Pursuit.scannerAgeMs == nil then return nil end
    if match.roles[playerId] ~= "cop" then return nil end
    return Pursuit.scannerAgeMs(match, now)
end

-- The boarding readout, for one player.
--
-- Exactly the same shape of optional contribution as `scannerAgeFor` above, and
-- for the same reason: `Pursuit.boardingFor` is installed by
-- server/vehicles.lua, is absent in a foot match and on a server whose cars
-- failed to create, and an ABSENT key is how the HUD is told "draw nothing".
--
-- It answers "your car is over there and this is how far you are from the door
-- you actually need", which is the feedback whose total absence made the entry
-- prompt unreadable: the engine offers "F Monter" within ~1 m of the DRIVER
-- door and says nothing whatsoever anywhere else.
--
-- vehicles.lua owns when it stops -- aboard, window expired, no car, match over
-- -- so nothing here has to know about the chase in order to keep the strip off
-- the screen during it.
local function boardingFor(match, playerId, now)
    if Pursuit.boardingFor == nil then return nil end
    local ok, readout = pcall(Pursuit.boardingFor, match, playerId, now)
    if not ok then
        log(("match %d boarding readout error: %s"):format(match.id, tostring(readout)))
        return nil
    end
    return readout
end

local function opponentOf(match, playerId)
    for _, other in ipairs(match.members) do
        if other ~= playerId then return other end
    end
    return nil
end

-- One player's view of the scoreboard. Two numbers, already taken from his own
-- side, because a HUD that had to work out which half of a table was "mine"
-- would be holding a rule.
local function scoreFor(match, playerId)
    local score = match.score or {}
    local opponent = opponentOf(match, playerId)
    return score[playerId] or 0, (opponent ~= nil and score[opponent] or 0)
end

-- Push one state event to every member, with the fields that DIFFER BY SIDE
-- filled in for each.
--
-- `role`, the opponent's name and the scoreboard are per-player, and a
-- broadcast that omitted them was not harmless: `pursuit_hud` assigns
-- `state.role = payload.role` unconditionally, so a roleless push blanked the
-- role cell until the next tick replaced it. Every lifecycle push goes through
-- here for that reason.
local function pushState(match, extra)
    for _, playerId in ipairs(match.members) do
        local opponent = opponentOf(match, playerId)
        local mine, theirs = scoreFor(match, playerId)
        local payload = matchStatePayload(match, {
            role = match.roles[playerId],
            opponentName = opponent and Open77.players.name(opponent) or nil,
            scoreSelf = mine,
            scoreOpponent = theirs,
        })
        -- `extra` may be a table (the same for everyone) or a FUNCTION of the
        -- player, for the fields that are a matter of side: `won` is the
        -- obvious one, and getting it wrong would tell both players they won.
        local more = extra
        if type(extra) == "function" then more = extra(playerId) end
        if more then
            for key, value in pairs(more) do payload[key] = value end
        end
        TriggerClientEvent("pursuit:matchState", playerId, payload)
    end
end

local function pushRoles(match)
    pushState(match)
end

-- -------------------------------------------------------------------- roles --

-- A stable key for an unordered pair, so "3 vs 7" and "7 vs 3" are the same
-- entry however the queue happened to order them.
local function pairKey(playerIds)
    local sorted = {}
    for index, id in ipairs(playerIds) do sorted[index] = id end
    table.sort(sorted)
    return table.concat(sorted, "|")
end

-- Roles for a new match.
--
-- A first meeting is arbitrary but deterministic, so a scripted scenario knows
-- which side it is driving. A rematch inside the window swaps them: hunting and
-- being hunted are different games, and a best-of-two has to contain both.
local function assignRoles(playerIds, matchId)
    local roles = {}
    local previous = lastPairing[pairKey(playerIds)]
    -- Live rather than captured: no match exists yet, so nothing in flight
    -- depends on it. The same goes for the two queue-jump numbers read in
    -- `findRematchPair` below.
    if previous ~= nil and #playerIds == Config.match.size and
        (nowMs() - previous.atMs) <= (Tune.rematchWindowSeconds * 1000) then
        local complete = true
        for _, playerId in ipairs(playerIds) do
            local was = previous.roles[playerId]
            if was == nil then
                complete = false
            else
                roles[playerId] = (was == "cop") and "runner" or "cop"
            end
        end
        if complete then
            log(("rematch: roles swapped for %s"):format(pairKey(playerIds)))
            return roles, true
        end
        -- One of the two is new to this pairing after all; fall through to the
        -- deterministic assignment rather than half-swapping.
        roles = {}
    end

    local first = (matchId % 2 == 0) and 1 or 2
    roles[playerIds[1]] = ROLES[first]
    if playerIds[2] ~= nil and playerIds[2] ~= playerIds[1] then
        roles[playerIds[2]] = ROLES[3 - first]
    end
    return roles, false
end

local function rememberPairing(match)
    if #match.members < Config.match.size then return end
    local now = nowMs()
    -- Drop entries that can no longer swap anything. Without this the table
    -- keeps one row per distinct pair for the life of the server, which is
    -- small but unbounded -- and unbounded is the part that eventually matters.
    local expiry = Tune.rematchWindowSeconds * 1000
    for key, entry in pairs(lastPairing) do
        if (now - entry.atMs) > expiry then lastPairing[key] = nil end
    end
    local key = pairKey(match.members)
    local previous = lastPairing[key]
    local roles = {}
    for playerId, role in pairs(match.roles) do roles[playerId] = role end

    -- How many times in a row this pair jumped the queue to reach each other.
    --
    -- Counted from `match.repaired` -- did the PAIRING pick them out of FIFO
    -- order -- and not from `match.rematch`, which only says their roles were
    -- swapped. The two use different windows (30 s and 180 s), so reading one
    -- for the other would cap the wrong thing: a pair matched by ordinary FIFO
    -- would burn a rematch credit it never spent.
    local consecutive = 1
    if previous ~= nil and match.repaired then
        consecutive = (previous.consecutive or 1) + 1
    end
    lastPairing[key] = { roles = roles, atMs = now, consecutive = consecutive }
end

-- ------------------------------------------------------------------- spawns --

-- Which authored table a match takes its marks from.
--
-- ONE selector for the whole match, and that is the entire point of this
-- function existing. A vehicle match places its PLAYERS from
-- `Config.vehicles.spawns` when that table has been surveyed, because
-- server/vehicles.lua puts the CARS on the same pair -- it reads `match.spawn`,
-- which is written from here.
--
-- Two tables with two independent selectors was the arrangement this replaces,
-- and it was invisible until someone filled the second one in: measured offline
-- on 2026-08-26 with a probe pair 500 m from the foot marks, both players
-- stayed on the promenade deck while their cars appeared 470 m and 540 m away.
-- `Config.vehicles.spawns` is nil today, so the bug was latent -- and
-- pursuit-v1-duo.md E3 tells the next person to fill it in, which would arm it.
--
-- `mode` is the match's CAPTURED mode, never the mode the next match will get:
-- flipping `pursuit.mode`, or the `matchMode` tunable behind it, must not move
-- the ground under two people already playing.
local function spawnTableFor(mode)
    if mode == "vehicle" then
        local surveyed = Config.vehicles and Config.vehicles.spawns
        if type(surveyed) == "table" and #surveyed > 0 then
            return surveyed, "vehicles.spawns"
        end
    end
    return Config.match.spawns, "match.spawns"
end

-- Rotate through the authored pairs rather than picking at random: the same
-- match id always gets the same ground, which is what makes a failure
-- reproducible.
--
-- Returns the pair and the NAME of the table it came from. The name is carried
-- on the match as `match.spawnSource` so the log, `pursuit.match` and
-- server/vehicles.lua can all say which set of marks is in play without
-- re-deriving it -- re-deriving it is exactly how the two paths drifted apart.
local function pickSpawnPair(matchId, mode)
    local spawns, source = spawnTableFor(mode)
    if type(spawns) ~= "table" or #spawns == 0 then return nil, source end
    return spawns[((matchId - 1) % #spawns) + 1], source
end

-- Put both players on their marks, inside the match bucket.
--
-- Placement happens when the COUNTDOWN starts, not when the match goes active:
-- the respawn is a transaction with a fade and a streaming preload behind it,
-- and the ten seconds of countdown are exactly the budget it needs. By the time
-- the clock starts, both players are settled and standing still.
-- The authored mark, lifted.
--
-- `Config.match.spawnLiftMetres` and the measurement behind it are documented
-- in shared/config.lua; the short version is that every authored z is a player
-- position READ, a read sits ~0.55 m below the surface it was taken on, and a
-- mark within a stride of a step therefore describes a point inside that step.
-- A player put there is wedged, and the server cannot tell -- `placeAt` reports
-- success the moment the life authority accepts the transaction, and a wedged
-- player at a plausible z is indistinguishable from a standing one.
--
-- One function so that both the round placement and `pursuit.unstick` lift by
-- the same amount. Returns the point UNCHANGED when the lift is zero, so
-- turning it off restores the previous behaviour exactly rather than
-- approximately.
local function liftedMark(position)
    local lift = tonumber(Config.match.spawnLiftMetres) or 0.0
    if position == nil or lift == 0.0 then return position end
    return { x = position.x, y = position.y, z = position.z + lift }
end

local function placeForMatch(match)
    -- The ROUND, not just the match, selects the pair. `pickSpawnPair` rotates
    -- through the authored table, so round 2 of a match lands on the next entry
    -- -- which for the two authored marks is the same promenade run driven the
    -- other way. Swapping the roles and then replaying the identical opening
    -- straight would have made the second round feel like a re-run of the
    -- first; this costs one addition and makes it a different drive.
    local pair, source = pickSpawnPair(match.id + (match.round or 1) - 1, match.mode)
    if pair == nil then
        log(("match %d has no spawn pair configured in Config.%s; players stay where they are")
            :format(match.id, tostring(source)))
        return false
    end
    -- Written BEFORE anyone is moved, and read by every other file in the
    -- resource. server/vehicles.lua puts the cars on this same pair; nothing
    -- else may select one.
    match.spawn = pair
    match.spawnSource = source

    local placed = 0
    for _, playerId in ipairs(match.members) do
        local role = match.roles[playerId]
        local point = pair[role]
        if point == nil then
            log(("match %d: spawn pair '%s' has no '%s' point"):format(
                match.id, tostring(pair.name), tostring(role)))
        else
            -- placeAt is the only sanctioned way this gamemode moves anyone:
            -- kill -> respawn, never a raw transform write.
            local record = Pursuit.players[playerId]
            if record ~= nil then record.placedAtMs = nowMs() end
            -- `playerYaw` overrides the facing ONLY.
            --
            -- `heading` is doing two jobs that pull in opposite directions once
            -- there are cars: it is the frame the car's offset is measured in
            -- (`server/vehicles.lua markFor`), and it is the direction the
            -- player is turned to face. Authored for foot mode, it points the
            -- cop at the runner -- which in a car chase leaves the car at a
            -- dead 90 degrees to his view, invisible, with the engine's entry
            -- prompt silent because it only answers within a metre of the
            -- driver door. He sees empty street and concludes he has no car.
            --
            -- Splitting the two lets a vehicle mark turn the player toward his
            -- car without moving the car off ground that has been surveyed.
            -- Falls back to `heading`, so every existing mark -- and the whole
            -- of `Config.match.spawns`, which foot mode still uses -- behaves
            -- exactly as before.
            if Pursuit.placeAt(playerId, liftedMark(point.position),
                point.playerYaw or point.heading,
                match.bucket, "match_spawn") then
                placed = placed + 1
            else
                log(("match %d: placement of %d (%s) failed; see above"):format(
                    match.id, playerId, tostring(role)))
            end
        end
    end
    log(("match %d round %d spawned at '%s' from Config.%s (%d/%d placed, lift %.2fm)"):format(
        match.id, match.round or 1, tostring(pair.name), tostring(source),
        placed, #match.members, tonumber(Config.match.spawnLiftMetres) or 0.0))
    return placed > 0
end

-- --------------------------------------------------------------- separation --

-- Separation is the full 3D distance, not the planar one the lobby leash uses.
--
-- Height is real distance on foot. A cop standing on the street is not busting
-- a runner sixty metres above him on a walkway, and a planar measure would say
-- he is -- the bust is the condition that punishes that mistake, so the measure
-- has to include z. Escape reads the same number and is only ever made harder
-- by it, which is the safe direction to be wrong in.
--
-- Returns nil plus a reason when the server genuinely cannot tell. Callers must
-- treat that as "do not judge", never as a distance of zero or infinity.
-- Is a placement transaction still in flight for this player?
--
-- The same grace `bounds.lua` honours, read from the same field. It matters
-- here because the two rules disagreed about it, and the disagreement was
-- exploitable: bounds refuses to judge a player inside his grace, while the win
-- conditions judged him throughout. Measured in play 2026-08-26 -- a runner
-- placed by `pursuit.tp` (15 s of grace) banked 14 s of escape credit before
-- the bounds clock was allowed to start, and won a match from 1.3 km outside
-- the arena. The instrument set that up, but the asymmetry is the mode's.
local function inPlacementGrace(playerId, now)
    local record = playerId ~= nil and Pursuit.players[playerId] or nil
    return record ~= nil and record.graceUntilMs ~= nil and now < record.graceUntilMs
end

local function separation(match)
    if match.copId == nil or match.runnerId == nil then return nil, "no_pair" end
    -- A player mid-placement has a position, and it is a lie: it is either
    -- where he was, where he is going, or somewhere between. Reporting it as a
    -- distance would let a teleport look like a chase. "Cannot tell" is the
    -- truth, and every caller already handles it -- the accumulators freeze,
    -- the HUD omits the number rather than showing a stale one.
    local now = nowMs()
    if inPlacementGrace(match.copId, now) or inPlacementGrace(match.runnerId, now) then
        return nil, "placement_grace"
    end
    local cop = Open77.players.position(match.copId)
    local runner = Open77.players.position(match.runnerId)
    if cop == nil or runner == nil then return nil, "unknown" end
    -- Mid-transfer one of them still reports the old dimension. A distance
    -- across buckets is meaningless: the two are not in the same world.
    if cop.bucket ~= match.bucket or runner.bucket ~= match.bucket then
        return nil, "wrong_bucket"
    end
    local dx = cop.x - runner.x
    local dy = cop.y - runner.y
    local dz = cop.z - runner.z
    -- The two positions ride along so the pace tracker below reads the SAME
    -- samples the separation was computed from -- a second native read a
    -- moment later could disagree with this one, and two rules fed by two
    -- different snapshots of the same instant is how contradictions happen.
    return math.sqrt(dx * dx + dy * dy + dz * dz), nil, cop, runner
end

-- ---------------------------------------------------------------------- pace --
--
-- Per-role speed, differenced from the replicated positions, and the crash
-- stall that reads it. This is the measurement the arrest gate runs on; the
-- design argument is the "Relative speed" note above the distance columns in
-- shared/config.lua, and the discipline is roadblock.lua's: a window, a
-- minimum baseline, and NIL rather than a guess when the server cannot tell.
--
-- The numbers below are MECHANISM timing, not balance, which is why they are
-- not tunables (the same rule that keeps `tickHz` out of the panel):
--   * SPEED_WINDOW_MS  -- positions replicate at ~5 Hz and the tick runs at
--     5 Hz, so adjacent samples alias (a tick that saw no fresh sample reads a
--     false zero). A 1 s window spans ~5 replication intervals and bounds that
--     error at ~20%.
--   * SPEED_MIN_SPAN_MS -- refuse a speed measured over a shorter baseline
--     than two replication intervals; it would be mostly noise.
--   * Samples older than the window are dropped on every tick, which is also
--     what makes teleports safe: every placement carries a grace that blanks
--     `separation` for longer than the window, so by the time the pair is
--     readable again the pre-placement samples are gone and no phantom speed
--     spike can be derived across the jump.
local SPEED_WINDOW_MS = 1000
local SPEED_MIN_SPAN_MS = 400
local CRASH_LOOKBACK_MS = 1500

-- Record one position sample for `role` and refresh its windowed speed.
local function pacePush(match, role, pos, now)
    match.pace = match.pace or {}
    local p = match.pace[role]
    if p == nil then
        p = { samples = {}, speeds = {} }
        match.pace[role] = p
    end
    local s = p.samples
    s[#s + 1] = { t = now, x = pos.x, y = pos.y, z = pos.z }
    while #s > 1 and (now - s[1].t) > (SPEED_WINDOW_MS + 200) do
        table.remove(s, 1)
    end
    local oldest = s[1]
    local span = now - oldest.t
    if span >= SPEED_MIN_SPAN_MS then
        local dx = pos.x - oldest.x
        local dy = pos.y - oldest.y
        local dz = pos.z - oldest.z
        p.speedKph = (math.sqrt(dx * dx + dy * dy + dz * dz) / (span / 1000.0)) * 3.6
        local v = p.speeds
        v[#v + 1] = { t = now, kph = p.speedKph }
        while #v > 1 and (now - v[1].t) > CRASH_LOOKBACK_MS do
            table.remove(v, 1)
        end
    else
        -- Too short a baseline to trust -- right after a round starts or a
        -- placement grace lifts. NIL, and the arrest gate treats nil as "do
        -- not fill", never as "stopped".
        p.speedKph = nil
    end
    return p
end

-- The crash detector: a windowed speed that collapses from a real pace to
-- almost nothing inside the lookback is bodywork, and it stalls the engine for
-- `crashStallSeconds`. Both roles run through here; what a stall MEANS per
-- role is the arrest gate's business, not this function's.
local function paceCrashCheck(match, role, playerId, now)
    local t = tuning(match)
    local stallMs = (tonumber(t.crashStallSeconds) or 0) * 1000
    if stallMs <= 0 then return end
    local p = match.pace and match.pace[role]
    if p == nil or p.speedKph == nil then return end
    -- One crash, one stall: no re-trigger while the current one runs.
    if p.stalledUntilMs ~= nil and now < p.stalledUntilMs then return end
    local peak
    for _, entry in ipairs(p.speeds) do
        if peak == nil or entry.kph > peak then peak = entry.kph end
    end
    if peak == nil then return end
    if peak >= (tonumber(t.crashMinSpeedKph) or 45.0)
        and (peak - p.speedKph) >= (tonumber(t.crashDropKph) or 40.0) then
        p.stalledUntilMs = now + stallMs
        -- Spend the peak: the history that fired this stall must not fire the
        -- next one too. It rebuilds from live samples within the lookback.
        p.speeds = {}
        notify(playerId, "warning",
            ("Crash! Engine stalled — %.0fs."):format(stallMs / 1000),
            math.floor(math.min(stallMs, 4000)))
        log(("match %d round %d: %s (player %d) crashed -- %.0f -> %.0f km/h, stalled %.1fs"):format(
            match.id, match.round or 1, tostring(role), playerId,
            peak, p.speedKph, stallMs / 1000))
    end
end

-- Is this role's engine currently stalled?
local function paceStalled(match, role, now)
    local p = match.pace and match.pace[role]
    return p ~= nil and p.stalledUntilMs ~= nil and now < p.stalledUntilMs
end

-- The stall remaining for ONE recipient's own role, for the HUD, or nil.
-- Self-only on purpose: telling a cop "the runner just stalled" when the
-- runner may be 300 m away is a position leak, and the meter movement already
-- tells him everything he is entitled to know inside the radius.
local function stallRemainingFor(match, playerId, now)
    local role = match.roles[playerId]
    if role == nil then return nil end
    local p = match.pace and match.pace[role]
    if p == nil or p.stalledUntilMs == nil then return nil end
    local remaining = p.stalledUntilMs - now
    if remaining <= 0 then return nil end
    return remaining
end

-- Distance from a player to a fixed point, or nil when it cannot be read.
local function distanceTo(playerId, point, bucket)
    if playerId == nil or point == nil then return nil end
    local position = Open77.players.position(playerId)
    if position == nil then return nil end
    if bucket ~= nil and position.bucket ~= bucket then return nil end
    local dx = position.x - point.x
    local dy = position.y - point.y
    local dz = position.z - point.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- ---------------------------------------------------------------- mortality --

-- "Down because someone killed him", as opposed to "down because we moved him".
--
-- Every placement in this gamemode goes through the life authority as a kill,
-- so a naive read of the phase reports a death on every spawn and would end the
-- match the instant it started. The kill carries `weapon = "pursuit:<reason>"`
-- (see placeAt in server/main.lua) and that marker is what separates the two.
--
-- Polling rather than the `onPlayerLifeStateChanged` event: that event exists
-- but is not part of the documented server surface, and at 5 Hz the worst-case
-- latency is 200 ms on conditions that already resolve in seconds. One code
-- path, one guard.
-- The server and the client spell these phases DIFFERENTLY, and only one of the
-- two spellings ever reaches this file.
--
-- The server pushes `life.Phase.ToString().ToLowerInvariant()` straight out of
-- the C# enum (`LuaResourceRuntime.PushLife`), so a server resource reads
-- `respawnpending` and `revivepending` -- no underscore. The client host maps
-- the same enum to snake_case (`ClientResourceHost.cpp`), and
-- `docs/player-life.md` documents the client spelling, which is where the
-- underscored set below came from.
--
-- Measured 2026-08-26 with `pursuit.lifetrace`: `after-kill` reports
-- `phase=dead`, `after-respawn` reports `phase=respawnpending`. Against the
-- underscored set only `dead` ever matched, so the guard went blind the instant
-- a corpse left the `dead` step -- and with the death resource reviving on its
-- own, that step can be shorter than the 200 ms tick that has to catch it.
--
-- Both spellings are accepted deliberately: this is a server file today, but
-- the set is cheap and a silent miss here ends matches nobody won.
local DEAD_PHASES = {
    dead = true,
    revivepending = true, revive_pending = true,
    respawnpending = true, respawn_pending = true,
}

local function downedByPlay(playerId)
    if playerId == nil then return false end
    local life = Open77.players.getLifeState(playerId)
    if life == nil or not DEAD_PHASES[tostring(life.phase)] then return false end
    if tostring(life.weapon or ""):sub(1, 8) == "pursuit:" then return false end
    return true
end

-- --------------------------------------------------------------- resolution --

local function returnToLobby(playerId)
    local record = Pursuit.players[playerId]
    if record == nil then return end
    Pursuit.transition(playerId, "lobby", "match_over")
    SetPlayerRoutingBucket(playerId, Config.lobby.bucket)
    -- Drop the match team. Back in the lobby everyone is a bystander again, and
    -- leaving cop and runner on opposing teams would leave the damage arbiter
    -- happy to let them shoot each other on the ready-up circle.
    Open77.combat.setTeam(playerId, 0)
    record.placedAtMs = nowMs()
    -- `sendToLobby` announces the lobby itself, which is what puts the ready-up
    -- ring and its prompt back on screen. Deliberately NOT done at `resolved`:
    -- resolution fires about five seconds before this transfer, and redrawing
    -- there would show the prompt while the player is still standing in the
    -- match world -- the same defect from the other side.
    Pursuit.sendToLobby(playerId, "match_over")
end

-- Player-facing wording for an outcome, from that player's own side.
local OUTCOME_LINES = {
    runner_escaped = { won = "You lost him.",          lost = "He got away." },
    runner_busted  = { won = "Busted.",                lost = "You were busted." },
    runner_down    = { won = "Target down.",           lost = "You went down." },
    cop_down       = { won = "The cop is down.",       lost = "You went down." },
    -- `timeoutWinner = "runner"` only -- the survival rule an operator can
    -- restore. Under the default the timeout outcome is `runner_timed_out`.
    time_expired   = { won = "You survived the clock.", lost = "Out of time." },
    -- The default timeout since 2026-08-30: the clock ran out and the runner
    -- never completed an escape, so the cop takes the round.
    runner_timed_out = { won = "Time's up — you never lost him.",
                         lost = "Time's up — you never shook him." },
    opponent_left  = { won = "Your opponent left.",    lost = "Match abandoned." },
    -- Phase E, arena bounds. Two outcomes rather than one because the rule is
    -- symmetric: whoever leaves Watson forfeits, and a cop who gives up the
    -- chase by driving out of the district has lost it just as surely as a
    -- runner who tried to idle out the clock in the Badlands.
    runner_out_of_bounds = { won = "He left the zone.",       lost = "You left the zone." },
    cop_out_of_bounds    = { won = "The cop left the zone.",  lost = "You left the zone." },
}

local function outcomeMessage(outcome, won)
    local lines = OUTCOME_LINES[outcome]
    if lines == nil then return won and "You win." or ("Match over: " .. outcome) end
    return won and lines.won or lines.lost
end

-- Outcomes that end the whole MATCH rather than the round that produced them.
--
-- Exactly one, and it is less a rule than an absence: with one player gone
-- there is nobody to swap roles with, so there is no round two to play. Every
-- other outcome is a ROUND result and the match carries on.
local FINAL_OUTCOMES = { opponent_left = true }

-- Defined below, once the clocks exist. Declared here because a round ends
-- before it begins, in this file's reading order.
local beginRound

local function membersPresent(match)
    if #match.members < Config.match.size then return false end
    for _, playerId in ipairs(match.members) do
        if Pursuit.players[playerId] == nil then return false end
    end
    return true
end

-- The aggregate result of a finished match: the member with the most round
-- wins, or nil for a draw. nil is a real answer here, not a failure -- see
-- the `tieBreak` tunable.
local function aggregateWinner(match)
    local best, winner, tied = -1, nil, false
    for _, playerId in ipairs(match.members) do
        local score = (match.score or {})[playerId] or 0
        if score > best then
            best, winner, tied = score, playerId, false
        elseif score == best then
            tied = true
        end
    end
    if tied then return nil end
    return winner
end

-- Is the match level-pegged with every round played?
local function isDrawn(match)
    return aggregateWinner(match) == nil
end

-- End the MATCH: scoreboard, teardown, everyone back to the lobby.
--
-- `outcome` and `winner` are the LAST ROUND's; the match result is the
-- aggregate and is computed here. In a one-round match the two coincide, which
-- is why this reads exactly like the Phase C resolution it grew out of.
local function finishMatch(match, outcome, winner, detail)
    if match.state == "resolved" then return end
    match.state = "resolved"
    match.resolvedAtMs = nowMs()
    -- Kept on the record, not just sent. The scoreboard beat is five seconds
    -- long and a client can be republished inside it, in which case
    -- `Pursuit.repushMatchTo` has to be able to replay the outcome card rather
    -- than leave the player staring at a blank HUD in a match world.
    match.outcome = outcome
    match.winner = winner

    local total = roundCount(match)
    local champion
    if FINAL_OUTCOMES[outcome] and winner ~= nil then
        -- A forfeit is not a scoreline. Whoever stayed takes the match however
        -- the rounds had gone: "a match abandoned under pressure is a match
        -- lost" was already this file's rule, and a leaver who happened to be
        -- ahead must not be able to bank it by quitting.
        champion = winner
    elseif total > 1 then
        champion = aggregateWinner(match)
    else
        champion = winner
    end
    match.champion = champion
    match.drawn = (champion == nil)

    local scoreline = {}
    for _, playerId in ipairs(match.members) do
        scoreline[#scoreline + 1] = ("%d=%d"):format(playerId, (match.score or {})[playerId] or 0)
    end

    log(("match %d resolved after %d/%d round(s): last=%s winner=%s champion=%s score %s detail=%s (sep=%s bustMeter=%.0f%%)"):format(
        match.id, #(match.rounds or {}), total, outcome, tostring(winner),
        match.drawn and "DRAW" or tostring(champion),
        table.concat(scoreline, " "), tostring(detail),
        match.separation and ("%.1fm"):format(match.separation) or "?",
        (match.bustMeter or 0) * 100))

    -- Record the sides BEFORE the roster is torn down, so the next match
    -- between these two can swap them. The roles stored are the LAST round's,
    -- which is what makes a rematch continue the alternation rather than repeat
    -- whichever side each player happened to start on.
    rememberPairing(match)

    -- Fan-out for anything that only needs to KNOW, and can know a scheduler
    -- pass later. TriggerEvent is asynchronous on this runtime, which is why
    -- entity cleanup does not use it -- see the extension-point note above and
    -- the resolved hook in the teardown below.
    TriggerEvent("pursuit:matchResolved", match.id, outcome, champion)

    for _, playerId in ipairs(match.members) do
        if Pursuit.players[playerId] ~= nil then
            Pursuit.transition(playerId, "resolved", outcome)
        end
    end

    pushState(match, function(playerId)
        local mine, theirs = scoreFor(match, playerId)
        return {
            state = "resolved",
            outcome = outcome,
            -- The MATCH result, not the round's, and they genuinely differ: a
            -- player who loses round 2 of a three-round decider can still take
            -- the match 2-1. `outcome` above already carries the round.
            won = champion ~= nil and playerId == champion,
            matchResult = match.drawn and "draw"
                or ((champion ~= nil and playerId == champion) and "win" or "loss"),
            scoreSelf = mine,
            scoreOpponent = theirs,
            -- No separation on the outcome card. The HUD does not render it
            -- outside `active` anyway, and a number that is never drawn is a
            -- number that should never have been sent -- see `separationFor`.
        }
    end)

    for _, playerId in ipairs(match.members) do
        local wonMatch = champion ~= nil and playerId == champion
        local mine, theirs = scoreFor(match, playerId)
        local message = outcomeMessage(outcome, wonMatch)
        -- No scoreline on a forfeit: the rounds played do not add up to the
        -- result, and printing "Match won 0-1" would be worse than silence.
        if total > 1 and not FINAL_OUTCOMES[outcome] then
            message = ("%s  %s %d-%d."):format(message,
                match.drawn and "Match drawn" or (wonMatch and "Match won" or "Match lost"),
                mine, theirs)
        end
        Open77.notifications.send(playerId, {
            type = (wonMatch or match.drawn) and "success" or "info",
            title = "Pursuit",
            message = message,
            durationMs = 6000,
        })
    end

    -- A short scoreboard beat before the return transaction, so the outcome is
    -- readable rather than instantly replaced by a respawn fade.
    local members = {}
    for index, id in ipairs(match.members) do members[index] = id end
    local matchId = match.id
    SetTimeout(5000, function()
        -- Entities die here, with the players, and not five seconds ago when
        -- the outcome was decided. Removing a car out from under a driver while
        -- his own scoreboard is still fading is a worse experience than letting
        -- it roll to a stop, and it buys nothing: the bucket is released in the
        -- same breath either way.
        --
        -- Synchronous, and before the match record is dropped, because every
        -- cleanup below reads `match`. `fireHooks` pcalls each one, so a module
        -- that throws cannot prevent the bucket from being released -- but it
        -- CAN leak its own entities, which is why server/vehicles.lua and
        -- server/roadblock.lua each also run an orphan sweeper.
        --
        -- Firing this a second time is HARMLESS by construction: an
        -- intermission already fired it for the round that just ended, and
        -- every hook clears a table it has already emptied. That matters
        -- because a disconnect during an intermission lands here without one.
        fireHooks("resolved", match, nowMs())

        for _, playerId in ipairs(members) do
            playerMatch[playerId] = nil
            if Pursuit.players[playerId] ~= nil then returnToLobby(playerId) end
        end
        releaseBucket(matches[matchId] and matches[matchId].bucket or nil)
        matches[matchId] = nil
        log(("match %d released"):format(matchId))
    end)
end

-- End the ROUND.
--
-- This is what every win condition calls, and what `Pursuit.resolveMatch` still
-- points at, because from a rule's point of view nothing has changed: it
-- decided that this chase is over and who took it. What is new is that a chase
-- is not necessarily a match any more.
--
-- Three ways out, in order:
--   * the outcome is final (`FINAL_OUTCOMES`) or a player is gone -- finish;
--   * rounds remain -- intermission, then `beginRound`;
--   * no rounds remain -- finish, unless the match is drawn and the config
--     asks for a decider, which adds exactly one.
local function resolve(match, outcome, winner, detail)
    if match.state == "intermission" then
        -- Something happened in the beat BETWEEN rounds, and the only thing
        -- that can is a disconnect. The round that just ended is already on the
        -- record, so there is nothing to score here -- but the pending timer
        -- for the next round has to be invalidated, or it walks into a resolved
        -- match and starts a chase with a ghost in it.
        match.roundToken = (match.roundToken or 0) + 1
        return finishMatch(match, outcome, winner, detail)
    end
    if match.state ~= "countdown" and match.state ~= "active" then return end

    local now = nowMs()
    local index = match.round or 1
    local total = roundCount(match)

    match.score = match.score or {}
    -- A forfeit scores nothing -- see the champion rule in `finishMatch`.
    if winner ~= nil and not FINAL_OUTCOMES[outcome] then
        match.score[winner] = (match.score[winner] or 0) + 1
    end

    local roles = {}
    for playerId, role in pairs(match.roles) do roles[playerId] = role end
    match.rounds = match.rounds or {}
    match.rounds[#match.rounds + 1] = {
        index = index,
        outcome = outcome,
        winner = winner,
        detail = detail,
        roles = roles,
        -- How long the chase itself lasted, for the log and for anyone who
        -- later wants a tie-break that is better than the two offered by the
        -- `tieBreak` tunable.
        durationMs = match.startedAtMs and (now - match.startedAtMs) or nil,
    }

    log(("match %d round %d/%d: %s winner=%s detail=%s (sep=%s escapeMeter=%.0f%% bustMeter=%.0f%%)"):format(
        match.id, index, total, outcome, tostring(winner), tostring(detail),
        match.separation and ("%.1fm"):format(match.separation) or "?",
        (match.escapeMeter or 0) * 100, (match.bustMeter or 0) * 100))

    local final = FINAL_OUTCOMES[outcome] == true or not membersPresent(match)
    local more = (not final) and index < total

    -- The decider, if one is asked for and the match needs one.
    if (not final) and (not more) and isDrawn(match) and not match.deciderAdded and
        tostring(tuned(match, "tieBreak")) == "decider" then
        match.deciderAdded = true
        more = true
        log(("match %d is level after %d rounds; playing a decider"):format(match.id, total))
    end

    if not more then
        return finishMatch(match, outcome, winner, detail)
    end

    -- ------------------------------------------------------- intermission --
    --
    -- The match is not over, so nothing is torn down here. The cars stay where
    -- they stopped and the scanner blip stays where it lied, for the same
    -- reason a resolution waits five seconds before cleaning up: taking the
    -- world away from a player while he is still reading why he lost is worse
    -- than letting it roll to a stop. `beginRound` does the teardown, a
    -- moment before it builds the next one.
    match.state = "intermission"
    match.copReleased = false
    match.intermissionEndsAtMs = now + math.floor(
        (tonumber(tuned(match, "intermissionSeconds")) or 8.0) * 1000)

    -- A generation counter, so a timer that is no longer wanted does nothing.
    -- A disconnect during the intermission finishes the match through the path
    -- above; without this token, the pending timer would then walk into a
    -- resolved match and start a round in it.
    match.roundToken = (match.roundToken or 0) + 1
    local token = match.roundToken
    local matchId = match.id

    -- Is the round about to begin the sudden-death decider? Computed once:
    -- the intermission card and the notification must agree, and a player
    -- entering the round that decides the match must be TOLD -- the round
    -- indicator alone cannot distinguish a decider from a third ordinary
    -- round of a best-of-three.
    local nextIsDecider = match.deciderAdded == true and (index + 1) >= roundCount(match)

    pushState(match, function(playerId)
        local mine, theirs = scoreFor(match, playerId)
        return {
            state = "intermission",
            outcome = outcome,
            won = winner ~= nil and playerId == winner,
            scoreSelf = mine,
            scoreOpponent = theirs,
            -- The HUD interpolates this into a countdown to the next round, so
            -- the beat reads as a beat rather than as a hang.
            remainingMs = math.max(0, match.intermissionEndsAtMs - now),
            nextRound = index + 1,
            nextIsDecider = nextIsDecider or nil,
        }
    end)

    for _, playerId in ipairs(match.members) do
        local wonRound = winner ~= nil and playerId == winner
        local mine, theirs = scoreFor(match, playerId)
        Open77.notifications.send(playerId, {
            type = wonRound and "success" or "info",
            title = ("Pursuit — round %d/%d"):format(index, total),
            message = nextIsDecider
                and ("%s  Level at %d-%d — DECIDER: one round for the match. Roles swap."):format(
                    outcomeMessage(outcome, wonRound), mine, theirs)
                or ("%s  %d-%d. Roles swap for round %d."):format(
                    outcomeMessage(outcome, wonRound), mine, theirs, index + 1),
            durationMs = 6000,
        })
    end

    SetTimeout(match.intermissionEndsAtMs - now, function()
        local live = matches[matchId]
        if live == nil or live ~= match then return end
        if live.state ~= "intermission" or live.roundToken ~= token then return end
        beginRound(match, index + 1)
    end)
end

-- ------------------------------------------------------------------- clocks --

local function beginCountdown(match)
    local index = match.round or 1
    match.state = "countdown"
    match.countdownEndsAtMs = nowMs() + (tuned(match, "countdownSeconds") * 1000)

    -- The PER-PLAYER state machine only moves on the first round.
    --
    -- `STATES` (server/main.lua) has no active -> countdown edge, and it should
    -- not: from the roster's point of view a player is in a match for the whole
    -- of it, not for each chase inside it. Round two is a new chase, not a new
    -- match, so the player state stays `active` throughout and only the MATCH
    -- state machine cycles. Calling `transition` here on round two would earn a
    -- logged refusal per player per round and change nothing.
    if index <= 1 then
        for _, playerId in ipairs(match.members) do
            Pursuit.transition(playerId, "countdown", "match_found")
        end
    end
    pushRoles(match)

    placeForMatch(match)
    -- Nothing is derived from a replicated position until the placement has
    -- settled. Anchored on the placement rather than on the match start, so a
    -- slow transaction pushes the window out with it instead of being judged
    -- by a clock that started without it.
    match.evaluateFromMs = nowMs() + Config.match.spawnSettleMs

    -- Cars are created here, inside the countdown, for the same reason the
    -- players are placed here: the countdown IS the budget for a transaction
    -- with a fade and a streaming preload behind it. By the time the clock
    -- starts, the car has streamed in and has had its transform republished.
    fireHooks("countdown", match, nowMs())

    local t = tuning(match)
    local total = roundCount(match)
    local prefix = (total > 1) and ("Round %d/%d — "):format(index, total) or ""
    for _, playerId in ipairs(match.members) do
        local role = match.roles[playerId]
        -- With no head start there is nothing to hold and nothing to wait for,
        -- so the briefing says so instead of promising a "0s" advantage that
        -- would read as a bug. See `headStartSeconds` in shared/config.lua --
        -- the 100 m escape is what took the head start away.
        if role == "runner" then
            notify(playerId, "info", t.headStartSeconds > 0
                and ("%sYou are the RUNNER. %ds head start."):format(prefix, t.headStartSeconds)
                or ("%sYou are the RUNNER. Lose him."):format(prefix))
        elseif role == "cop" then
            notify(playerId, "info", t.headStartSeconds > 0
                and ("%sYou are the COP. Hold position for %ds."):format(prefix, t.headStartSeconds)
                or ("%sYou are the COP. Stay on him."):format(prefix))
        end
    end

    log(("match %d round %d/%d countdown (%ds), bucket %d, mode %s"):format(
        match.id, index, total, tuned(match, "countdownSeconds"), match.bucket,
        tostring(match.mode)))
end

-- Arm the escape rule, `escapeArmSeconds` after the cop is let off the leash.
--
-- One function because there are two release paths -- the head start expiring,
-- and there being no head start at all -- and an escape window that only one of
-- them armed would be a silent rule difference between two modes.
local function armEscape(match, now)
    local t = tuning(match)
    match.copReleasedAtMs = now
    match.escapeArmedAtMs = now + ((t.escapeArmSeconds or 0.0) * 1000)
end

local function beginActive(match)
    local t = tuning(match)
    match.state = "active"
    match.startedAtMs = nowMs()
    -- The decider may run on its own clock. 0 -- the declared default --
    -- means "as long as any other round", and the argument for that default
    -- lives on the `deciderDurationSeconds` tunable in shared/config.lua.
    local durationSeconds = t.durationSeconds
    if match.deciderAdded and (match.round or 1) >= roundCount(match) then
        local override = tonumber(tuned(match, "deciderDurationSeconds")) or 0
        if override > 0 then durationSeconds = override end
    end
    match.endsAtMs = match.startedAtMs + (durationSeconds * 1000)
    match.copReleaseAtMs = match.startedAtMs + (t.headStartSeconds * 1000)
    match.copReleased = false
    -- The escape meter, per ROUND, like the bust meter below: an attempt from
    -- the last round -- least of all one made in the other role -- is nobody's
    -- credit in this one. The banner re-arm clock resets with it.
    match.escapeMeter = 0.0
    match.escapeFilling = false
    match.escapeNotifiedAtMs = nil
    match.overtimeNotified = false
    -- The bust meter, per ROUND. It starts empty in every round: a cop who was
    -- half-way to a bust when the last one ended does not inherit that credit,
    -- least of all when the roles have swapped and he is now the runner.
    match.bustMeter = 0.0
    match.bustClosing = false
    match.bustContact = false
    -- Per ROUND, like the meter: a speed baseline and a stall earned on the
    -- other end of the map, in the other role, describe nobody in this round.
    match.pace = nil
    match.lastEvalMs = match.startedAtMs
    match.unknownSinceMs = nil
    match.copStrayWarned = false

    -- No head start: the cop is released the moment the round starts, without
    -- the "Released. Go." beat, because the countdown already said go and a
    -- second start signal a frame later reads as a stutter.
    if t.headStartSeconds <= 0 then
        match.copReleased = true
        armEscape(match, match.startedAtMs)
    end

    if (match.round or 1) <= 1 then
        for _, playerId in ipairs(match.members) do
            Pursuit.transition(playerId, "active", "match_start")
        end
    end
    pushState(match, { state = "active" })
    fireHooks("active", match, match.startedAtMs)
    TriggerEvent("pursuit:matchStarted", match.id, match.mode)
    log(("match %d round %d/%d active for %ds in %s mode (%s)"):format(
        match.id, match.round or 1, roundCount(match), t.durationSeconds,
        tostring(match.mode),
        t.headStartSeconds > 0
            and ("cop released after %ds"):format(t.headStartSeconds)
            or ("no head start; escape arms after %.0fs"):format(t.escapeArmSeconds or 0)))
end

-- The head start is a rule, not a cage.
--
-- No server-side movement lock exists, so "the cop is held" is enforced by
-- refusing to credit anything he does before this fires: no bust progress is
-- counted, and no escape progress accrues against him either. A cop who sets
-- off early gains position and nothing else, and both players are told when the
-- hunt actually begins.
local function releaseCop(match)
    match.copReleased = true
    match.escapeMeter = 0.0
    match.escapeFilling = false
    match.bustMeter = 0.0
    armEscape(match, nowMs())
    pushState(match, { state = "active", copReleased = true })
    for _, playerId in ipairs(match.members) do
        local role = match.roles[playerId]
        if role == "cop" then
            notify(playerId, "warning", "Released. Go.", 4000)
        elseif role == "runner" then
            notify(playerId, "warning", "The cop is moving.", 4000)
        end
    end
    log(("match %d: cop released"):format(match.id))
end

-- ------------------------------------------------------------------- rounds --

-- Start round `index` of a match already in flight.
--
-- Assigned to the forward local declared above the resolution, because a round
-- ends before it begins in this file's reading order.
--
-- Three things happen here and the ORDER of them is load-bearing:
--   1. the round's teardown, which is the `resolved` hook set -- those hooks
--      always described a ROUND (clear the cars, clear the blip, clear the
--      blockades) and a match only used to be one;
--   2. the role swap, which must come AFTER the teardown because
--      server/scanner.lua clears the blip belonging to `match.copId` and that
--      is the OLD cop;
--   3. the countdown, which places both players on their new marks and builds
--      the new cars from the new roles.
beginRound = function(match, index)
    fireHooks("resolved", match, nowMs())

    if #match.members == Config.match.size and
        match.copId ~= nil and match.runnerId ~= nil then
        -- The swap. This is the whole reason a match has more than one round:
        -- hunting and being hunted are different games, and a 1v1 that only
        -- measured one of them measured half the player.
        match.copId, match.runnerId = match.runnerId, match.copId
        for _, playerId in ipairs(match.members) do
            match.roles[playerId] = (playerId == match.copId) and "cop" or "runner"
            -- Teams follow the roles, or the damage arbiter spends round two
            -- believing the cop is on the runner's side.
            Open77.combat.setTeam(playerId, match.roles[playerId] == "cop" and 1 or 2)
        end
        match.rematch = true
    else
        -- A forced single-member match (`pursuit.force <one player>`) has one
        -- role filled and nothing to swap. Let it run its rounds rather than
        -- inventing an opponent: it exercises the lifecycle, which is what it
        -- is for.
        log(("match %d round %d: not a full pair, roles unchanged"):format(match.id, index))
    end

    match.round = index
    match.intermissionEndsAtMs = nil
    log(("match %d entering round %d/%d (cop=%s runner=%s)"):format(
        match.id, index, roundCount(match),
        tostring(match.copId), tostring(match.runnerId)))
    beginCountdown(match)
end

-- ------------------------------------------------------------ match creation --

local function startMatch(playerIds, repaired)
    local bucket = allocateBucket()
    if bucket == nil then
        log("no free match bucket; leaving players queued")
        return false
    end

    if nextMatchId == nil then nextMatchId = math.floor(nowMs()) + 1 end
    local matchId = nextMatchId
    nextMatchId = nextMatchId + 1

    local roles, swapped = assignRoles(playerIds, matchId)

    -- ---------------------------------------------- THE TUNABLE CAPTURE --
    --
    -- Promote, then freeze. Two lines, and the order is the whole mechanism.
    --
    -- PROMOTE adopts every value an operator has set since the last match was
    -- created. Everything that can decide a round is declared `next_match`, so
    -- until this call the host is holding those writes and `Tune.key` still
    -- answers with the old number -- which is exactly what a match already in
    -- flight needs, and would be a change that never lands if nobody ever
    -- promoted.
    --
    -- CAPTURE then takes a frozen plain table of every current value and hangs
    -- it on the match. From here on this match reads its capture and nothing
    -- else (`tuned`, `tuning`), so promoting for the NEXT match cannot touch
    -- it. That is the part `promote()` alone cannot do: promotion is per
    -- resource, not per match, and Pursuit runs concurrent matches in separate
    -- routing buckets -- so a promotion at match B's creation would move match
    -- A's finish line if match A were reading live values. It is the same
    -- discipline `match.mode` has always had, generalised to every number.
    local promoted = Open77.tunables.promote()
    local capture = Open77.tunables.capture()
    if #promoted > 0 then
        log(("retuned settings adopted for new matches: %s"):format(
            table.concat(promoted, ", ")))
    end
    local mode = (capture.matchMode == "foot") and "foot" or "vehicle"

    local match = {
        id = matchId,
        bucket = bucket,
        members = playerIds,
        roles = roles,
        state = "countdown",
        createdAtMs = nowMs(),
        rematch = swapped,
        -- Whether the PAIRING picked these two out of FIFO order, as opposed to
        -- `rematch`, which only records that their roles were swapped. Read by
        -- rememberPairing to cap consecutive queue jumps.
        repaired = repaired == true,
        -- The distance column is captured now and never re-read from the
        -- config. `pursuit.mode` -- or the Tuning tab -- may flip the switch a
        -- second after this line runs; the two people in this match keep the
        -- rules they started with.
        mode = mode,
        -- ...and so is every other number an operator may move. `tuned(match,
        -- key)` reads this, `tuning(match)` lays the distance keys over the
        -- column once, and `match.rules` caches the result.
        tune = capture,
        -- The escape meter, 0..1. Replaces `escapeHeldMs`, which was a
        -- resetting hold -- see the escape branch of the tick for the window
        -- rule that made it a meter.
        escapeMeter = 0.0,
        -- The bust meter, 0..1. Replaces `bustHeldMs`, which was a resetting
        -- hold timer -- see the long note above the distance columns in
        -- shared/config.lua for why that rule could not be satisfied in a car.
        bustMeter = 0.0,

        -- A match is a best of the captured `roundsPerMatch`, and these three
        -- fields are the whole of it: which round is being played, how many
        -- rounds each member has taken, and what happened in each.
        round = 1,
        score = {},
        rounds = {},
    }
    for _, playerId in ipairs(playerIds) do match.score[playerId] = 0 end
    -- Cache the two sides. Every rule below is written in terms of "the cop"
    -- and "the runner", not "member 1" and "member 2".
    for _, playerId in ipairs(playerIds) do
        if roles[playerId] == "cop" then match.copId = playerId end
        if roles[playerId] == "runner" then match.runnerId = playerId end
    end
    matches[matchId] = match
    bucketOwner[bucket] = matchId

    -- Isolate the match: no ambient population, and no client-authored entities
    -- leaking in from either side.
    SetRoutingBucketPopulationEnabled(bucket, false)
    SetRoutingBucketEntityLockdownMode(bucket, "relaxed")

    for _, playerId in ipairs(playerIds) do
        playerMatch[playerId] = matchId
        Pursuit.removeFromQueue(playerId)
        SetPlayerRoutingBucket(playerId, bucket)
        -- Teams keep the damage arbiter honest: cop and runner are opponents,
        -- so they must never read as teammates.
        Open77.combat.setTeam(playerId, roles[playerId] == "cop" and 1 or 2)
    end

    local who = {}
    for _, playerId in ipairs(playerIds) do
        who[#who + 1] = ("%d=%s"):format(playerId, roles[playerId])
    end
    log(("match %d created: %s bucket=%d mode=%s best-of-%d%s%s"):format(
        matchId, table.concat(who, " "), bucket, tostring(mode), roundCount(match),
        swapped and " (rematch, roles swapped)" or "",
        match.repaired and " (re-paired ahead of FIFO)" or ""))

    beginCountdown(match)
    Pursuit.broadcastQueue()
    return true
end

-- The second half of design §5.5 item 8: two players who re-queue together are
-- pulled out of FIFO order and paired with EACH OTHER.
--
-- Scanned before FIFO and only inside `rematchPairWindowSeconds`, which is much
-- shorter than the role-swap window: jumping the queue is a favour granted to a
-- pair still visibly playing the same best-of-two, not a permanent claim on the
-- front of the queue. `maxConsecutiveRematches` is what stops that favour from
-- starving a third player -- without it, every resolve refreshes the entry and
-- the same two hold the front for as long as they keep re-queueing.
--
-- O(n^2) over the queue. Correct for a 1v1 mode whose queue is measured in
-- single digits, and the wrong shape entirely at fifty; the cost is bounded by
-- the fact that this only runs when the queue changes.
local function findRematchPair(queue)
    if Config.match.size ~= 2 then return nil end
    local window = (Tune.rematchPairWindowSeconds or 0) * 1000
    if window <= 0 then return nil end
    local cap = Tune.maxConsecutiveRematches or 2
    local now = nowMs()
    for i = 1, #queue - 1 do
        for j = i + 1, #queue do
            local entry = lastPairing[pairKey({ queue[i], queue[j] })]
            if entry ~= nil and (now - entry.atMs) <= window and
                (entry.consecutive or 1) <= cap then
                return { queue[i], queue[j] }
            end
        end
    end
    return nil
end

-- Pairing is FIFO once findRematchPair has had its say: the two longest-waiting
-- players are matched. Anything cleverer than that (skill, region) belongs above
-- this, not inside it.
local pairing = false

AddEventHandler("pursuit:queueChanged", function()
    -- startMatch broadcasts the queue, which re-fires this event. Without a
    -- guard the handler re-enters while its own loop is still walking the
    -- queue and can pair the same player twice.
    if pairing then return end
    pairing = true
    local ok, err = pcall(function()

    local queue = Pursuit.queue
    while #queue >= Config.match.size do
        local picked, repaired = findRematchPair(queue), true
        if picked == nil then
            repaired = false
            picked = {}
            for index = 1, Config.match.size do picked[index] = queue[index] end
        end

        -- Re-verify every candidate still exists and is still queued: the queue
        -- is mutated from several paths and a stale entry would create a match
        -- with a ghost in it.
        local valid = true
        for _, playerId in ipairs(picked) do
            local record = Pursuit.players[playerId]
            if record == nil or record.state ~= "queued" then
                Pursuit.removeFromQueue(playerId)
                valid = false
            end
        end
        if not valid then
            -- The queue changed underneath us; re-evaluate from the top.
        elseif not startMatch(picked, repaired) then
            return -- No bucket free; stop trying this tick.
        end
    end

    end)
    pairing = false
    if not ok then Pursuit.log("pairing error: " .. tostring(err)) end
end)

-- A player leaving mid-match ends it for the other. Credit the survivor rather
-- than voiding: a match abandoned under pressure is a match lost.
AddEventHandler("pursuit:playerGone", function(playerId)
    local matchId = playerMatch[playerId]
    if matchId == nil then return end
    local match = matches[matchId]
    playerMatch[playerId] = nil
    if match == nil then return end

    local survivor
    for _, id in ipairs(match.members) do
        if id ~= playerId and Pursuit.players[id] ~= nil then survivor = id end
    end
    resolve(match, "opponent_left", survivor, ("player %d disconnected"):format(playerId))
end)

-- ---------------------------------------------------------------- match tick --

-- One active match, one 5 Hz evaluation.
--
-- Every win condition below is "held continuously for N seconds", never a
-- single sample: `Open77.players.position` is a replicated snapshot, and one
-- reading taken during a stall would end matches that nobody won.

-- How long after an escape-attempt banner the next one may fire, on top of the
-- meter having fully drained in between. MECHANISM timing, not balance (the
-- same rule that keeps `tickHz` out of the panel): it exists so a runner
-- flapping across the escape line cannot ring both players' screens every
-- crossing. The METER needs no such guard -- it is continuous, and drains
-- roughly three times faster than it fills, so flapping at the boundary loses
-- ground rather than ratcheting -- only the one-shot notification does.
local ESCAPE_NOTIFY_REARM_MS = 10000

local function tickActive(match, now)
    local elapsed = now - (match.lastEvalMs or now)
    -- A stalled scheduler must not hand an accumulator seconds of credit in a
    -- single iteration; that would turn a hitch into a bust.
    if elapsed > TICK_MS * 3 then elapsed = TICK_MS * 3 end
    if elapsed < 0 then elapsed = 0 end
    match.lastEvalMs = now

    if not match.copReleased and match.copReleaseAtMs ~= nil and
        now >= match.copReleaseAtMs then
        releaseCop(match)
    end

    -- THE CLOCK, and who it favours (2026-08-30, the owner's inversion:
    -- "surviving the round timer is no longer a runner win ... the runner
    -- must actually shake the cop to win"). A timeout with no completed
    -- escape and no bust now hands the round to the COP -- merely outlasting
    -- the hunt is not an escape. `timeoutWinner` restores the old survival
    -- rule for operators who prefer it; the argument for the default is on
    -- the tunable in shared/config.lua.
    --
    -- OVERTIME, first: an attempt already in progress at the buzzer plays
    -- out rather than being cut. `escapeFilling` (runner beyond the line,
    -- armed) and `bustClosing` (arrest conditions met) are the two "an act is
    -- underway" flags, written by the two meter branches below from the last
    -- readable tick. While either is true the round does not end: the meter
    -- either completes -- its own outcome, exactly as before the buzzer --
    -- or the CONDITION breaks (a dip under the line, contact lost, the pair
    -- unreadable past the stale window, which clears both flags), and the
    -- next pass of this check ends the round on the timeout rule.
    --
    -- Why overtime rather than "the clock is absolute": with the timeout the
    -- cop's, an absolute clock makes the endgame degenerate -- a cop 20 s
    -- from the horn need not contest a break at all, because even a 95%
    -- escape meter dies at zero and hands him the round for free. Letting
    -- the armed attempt finish keeps the last seconds a real contest, costs
    -- at most one meter's fill time, and CANNOT run away: overtime holds
    -- only while the condition itself holds, so it is a sudden-death hold,
    -- not a resumed meter -- flapping ends it on the first dip. The bust
    -- meter gets the identical grace for the identical reason (it matters
    -- under `timeoutWinner = "runner"`, where the buzzer would otherwise rob
    -- the cop mid-arrest); consistency between the two meters outranks
    -- either rule's simplicity.
    if match.endsAtMs ~= nil and now >= match.endsAtMs then
        if match.escapeFilling == true or match.bustClosing == true then
            if not match.overtimeNotified then
                match.overtimeNotified = true
                log(("match %d round %d: OVERTIME -- %s at the buzzer plays out"):format(
                    match.id, match.round or 1,
                    match.escapeFilling and "escape attempt" or "arrest"))
                for _, playerId in ipairs(match.members) do
                    notify(playerId, "warning",
                        "Overtime — the attempt in play decides it.", 4000)
                end
            end
        else
            local survival = tostring(tuned(match, "timeoutWinner")) == "runner"
            if survival then
                return resolve(match, "time_expired", match.runnerId,
                    match.overtimeNotified and "duration reached; overtime attempt broken"
                        or "duration reached")
            end
            return resolve(match, "runner_timed_out", match.copId,
                match.overtimeNotified and "duration reached; overtime attempt broken -- no escape"
                    or "duration reached -- no escape")
        end
    end

    -- Nothing is derived from a replicated position until the spawn transaction
    -- has settled; before that the position is stale, absent, or still reads as
    -- the lobby.
    if match.evaluateFromMs ~= nil and now < match.evaluateFromMs then return end

    -- COP wins: the runner dies. Anything that is not one of our own placement
    -- kills counts -- a firefight, a fall, a car. He does not have to be shot
    -- by the cop, because on foot the city does most of the killing.
    if downedByPlay(match.runnerId) then
        return resolve(match, "runner_down", match.copId, "runner died")
    end
    -- Not in the design's table. A dead cop cannot play out the clock, and
    -- leaving the runner to jog alone for four minutes is worse than ending it;
    -- config-gated so it can be turned off if it turns out to reward suicide.
    if tuned(match, "copDeathEndsMatch") and downedByPlay(match.copId) then
        return resolve(match, "cop_down", match.runnerId, "cop died")
    end

    local sep, why, copPos, runnerPos = separation(match)
    match.separation = sep
    match.separationDetail = why

    -- Feed the pace tracker from the same position reads the separation used,
    -- and run the crash detector on both roles. Before the HUD push, because
    -- the push carries the stall; harmless before the cop's release, because
    -- the arrest gate below is not consulted until he is.
    if sep ~= nil then
        pacePush(match, "cop", copPos, now)
        pacePush(match, "runner", runnerPos, now)
        paceCrashCheck(match, "cop", match.copId, now)
        paceCrashCheck(match, "runner", match.runnerId, now)
    end

    -- Phase E rules, in the middle of the tick and not at either end.
    --
    -- After `sep`, because the scanner's pressure band is defined in terms of
    -- it. Before the HUD push, because the scanner writes the very field the
    -- push has to carry. And before the `sep == nil` early return below,
    -- because arena bounds read each player's own position independently: one
    -- player mid-transfer makes the PAIR unreadable without making either
    -- player unreadable, and a runner should not stop being out of bounds
    -- because the cop happened to be respawning.
    fireHooks("tick", match, now)
    if match.state == "resolved" then return end

    -- Feed the HUD.
    --
    -- `pursuit_hud` is a separate resource and its only window onto a live
    -- match is this event. Pushed nowhere else during play, it can anchor its
    -- clock once at match start and interpolate locally forever after, and it
    -- can never show a separation at all -- which is the one number the mode
    -- is about. Hence a push from inside the tick that already knows all of
    -- it, rather than a second timer thread that would have to recompute it.
    --
    -- Per-player, like pushRoles, because `role` and `opponentName` differ by
    -- side.
    --
    -- `separation` is OMITTED when it cannot be read, never sent as 0 or as
    -- the previous value: assigning nil to a Lua table key simply leaves the
    -- key out, and the HUD hides a readout it was not given. A stale number
    -- would read as fact, and "0.0 m" tells a runner he has already been
    -- caught.
    if (now - (match.lastHudPushMs or 0)) >= HUD_PUSH_MS then
        match.lastHudPushMs = now
        for _, playerId in ipairs(match.members) do
            local opponent
            for _, other in ipairs(match.members) do
                if other ~= playerId then opponent = other end
            end
            local payload = matchStatePayload(match, {
                state = "active",
                role = match.roles[playerId],
                opponentName = opponent and Open77.players.name(opponent) or nil,
                remainingMs = match.endsAtMs and math.max(0, match.endsAtMs - now) or nil,
                -- RUNNER ONLY. See `separationFor` -- this is the leak that let
                -- a cop trilaterate a runner he could not see.
                separation = separationFor(match, playerId, sep),
                scoreSelf = (select(1, scoreFor(match, playerId))),
                scoreOpponent = (select(2, scoreFor(match, playerId))),
                -- The bust meter, 0..1, to BOTH sides. Both watching the same
                -- bar climb is the point: it is the one readout in the mode
                -- that says the same thing to the hunter and the hunted, and
                -- it is what makes closing in legible instead of invisible.
                --
                -- Sent as 0 rather than omitted, unlike `separation` and
                -- `scannerAgeMs`: an empty meter is a FACT the server knows,
                -- not an absence. It is omitted only before the cop is
                -- released, when the rule is not running at all.
                bustMeter = match.copReleased and (match.bustMeter or 0.0) or nil,
                bustClosing = match.copReleased and (match.bustClosing == true) or nil,
                -- Contact without arrest -- the tailing state, in which the
                -- meter bleeds slowly instead of filling. The HUD words the
                -- bar differently for it; leaks nothing beyond the meter's own
                -- movement, since it is false everywhere the meter would be
                -- draining at full rate anyway.
                bustContact = match.copReleased and (match.bustContact == true) or nil,
                -- SELF only -- the recipient's own stalled engine, remaining
                -- ms. Never the opponent's: a cop told "the runner stalled"
                -- has been told where the runner is not going, which is a
                -- position leak. See `stallRemainingFor`.
                bustStalled = stallRemainingFor(match, playerId, now),
                -- The escape meter, to BOTH sides, and mutually exclusive
                -- with the bust meter by construction: separation cannot be at
                -- once below `bustDistance` and at or above `escapeDistance`.
                -- What the cop learns from it is one bit -- beyond the line or
                -- not -- which is the same class of leak as `bustContact` and
                -- the price of a legible rule; what he does NOT get is a live
                -- distance (see `separationFor`).
                escapeProgress = escapeProgressOf(match),
                -- Whether the attempt is being EARNED right now (runner beyond
                -- the line) or clawed back (cop pulled him under it). The HUD
                -- words and colours the bar differently for the two.
                escapeFilling = (escapeProgressOf(match) ~= nil)
                    and (match.escapeFilling == true) or nil,
                -- Cop-only, and OMITTED rather than zeroed when there is no fix
                -- yet -- same discipline as `separation` above. "0.0s ago" would
                -- tell a cop his blip is live, which is the one thing the whole
                -- mechanic exists to deny him.
                scannerAgeMs = scannerAgeFor(match, playerId, now),
                boarding = boardingFor(match, playerId, now),
            })
            TriggerClientEvent("pursuit:matchState", playerId, payload)
            -- Narrate the contract on demand (pursuit.hudtrace). The three
            -- properties the HUD depends on are only observable from inside
            -- this loop: one packet PER PLAYER, each carrying that player's own
            -- role, and `separation` ABSENT rather than stale when it cannot be
            -- read. Off by default -- at 2 Hz per player this is still file I/O
            -- on the Lua frame budget (plan 7c).
            if match.hudTraceUntilMs ~= nil and now <= match.hudTraceUntilMs then
                log(("hudpush match %d -> player %d role=%s remainingMs=%s separation=%s scannerAgeMs=%s (%+dms)"):format(
                    match.id, playerId, tostring(payload.role),
                    payload.remainingMs and tostring(math.floor(payload.remainingMs)) or "absent",
                    payload.separation and ("%.1f"):format(payload.separation) or "ABSENT",
                    payload.scannerAgeMs and tostring(math.floor(payload.scannerAgeMs)) or "ABSENT",
                    now - (match.lastHudTraceMs or now)))
            end
        end
        if match.hudTraceUntilMs ~= nil then match.lastHudTraceMs = now end
    end

    if sep == nil then
        -- Freeze, do not reset: one missing snapshot is not evidence that a
        -- runner stopped running. Past the stale window we have genuinely lost
        -- track of someone, and resuming on that credit would be a guess.
        match.unknownSinceMs = match.unknownSinceMs or now
        if (now - match.unknownSinceMs) >= Config.match.positionStaleResetMs then
            -- Past the stale window we have genuinely lost track of someone.
            --
            -- BOTH meters DRAIN instead of resetting, each at its own recovery
            -- rate. That is the whole difference between a meter and a hold
            -- timer, and discarding it here would reintroduce the bug each
            -- meter replaced through the back door: a replication gap is
            -- exactly the kind of accident that must cost a player a fraction
            -- of his work rather than all of it. This held for the bust meter
            -- from the start and applies to the escape meter for the same
            -- reason since the 2026-08-29 window rework -- the escape used to
            -- RESET here, because a "held continuously" hold cannot be claimed
            -- across a gap the server could not see, and a meter makes no such
            -- claim. Long gaps still empty both -- seconds of silence drain a
            -- full meter as surely as seconds of clear road -- and no meter
            -- can FILL while the pair is unreadable, so a placement grace (a
            -- teleport, an unstick) still cannot bank progress for anyone.
            local t = tuning(match)
            local escapeDrain = t.escapeDrainSeconds or 6.0
            local escape = (match.escapeMeter or 0.0) -
                ((elapsed / 1000.0) / math.max(0.001, escapeDrain))
            match.escapeMeter = (escape > 0.0) and escape or 0.0
            match.escapeFilling = false
            local drainSeconds = t.bustDrainSeconds or t.bustFillSeconds or 5.0
            local meter = (match.bustMeter or 0.0) -
                ((elapsed / 1000.0) / math.max(0.001, drainSeconds))
            match.bustMeter = (meter > 0.0) and meter or 0.0
            match.bustClosing = false
            match.bustContact = false
        end
        return
    end
    match.unknownSinceMs = nil

    if not match.copReleased then
        -- The head start, enforced. No progress accrues to either side while
        -- the cop is held: a bust cannot be earned by a cop who has not been
        -- released, and an escape cannot be earned against one.
        --
        -- In `vehicle` mode there is no head start at all any more and this
        -- branch never runs -- see `headStartSeconds` in shared/config.lua.
        -- `foot` still has one, and it is the column a rule gets re-tested in.
        match.escapeMeter = 0.0
        match.escapeFilling = false
        match.bustMeter = 0.0
        match.bustClosing = false
        match.bustContact = false

        -- No movement lock exists, so straying is a warning and nothing more.
        -- TODO: if the warning proves insufficient, returning the cop to his
        -- mark through Pursuit.placeAt is the enforcement with teeth -- it
        -- needs the same hysteresis as the lobby leash to avoid a respawn loop,
        -- which is why it is not in this phase.
        if not match.copStrayWarned and match.spawn ~= nil then
            local mark = match.spawn.cop and match.spawn.cop.position
            local strayed = distanceTo(match.copId, mark, match.bucket)
            if strayed ~= nil and strayed > tuned(match, "copHoldRadius") then
                match.copStrayWarned = true
                notify(match.copId, "warning", "Hold your position.", 4000)
                log(("match %d: cop %d strayed %.0fm during the head start"):format(
                    match.id, match.copId, strayed))
            end
        end
        return
    end

    local t = tuning(match)

    -- CONTAINMENT OUTRANKS THE WIN CONDITIONS. No player earns his own win
    -- while he is outside the arena.
    --
    -- Left as a race, the two rules do not resolve in the order the design
    -- reads. An escape accrues from the moment separation passes
    -- `escapeDistance`, which happens well inside the arena; bounds only start
    -- at the boundary. A runner already clear who then drives out can therefore
    -- complete an escape before the bust he has earned lands. Measured in play
    -- 2026-08-26: `player 18 outside 1291m, 5.9s left` followed by
    -- `runner_escaped ... 1294m held for 20s`. He won the match from outside the
    -- map.
    --
    -- Reset rather than freeze. "Held continuously" is the escape's whole
    -- contract, and an excursion breaks the hold exactly as the cop closing in
    -- does.
    --
    -- ARENA BOUNDS ARE OFF as of 2026-08-26 (`Config.arena.enabled`, on the
    -- owner's instruction: the whole map is the arena now). `outsideArena`
    -- returns nil while they are, so both of these read false and every rule
    -- below runs everywhere. The checks stay because the bounds are disabled,
    -- not deleted, and this ordering is the thing that was expensive to get
    -- right.
    local runnerOutside = Pursuit.outsideArena and
        Pursuit.outsideArena(match, match.runnerId) == true
    local copOutside = Pursuit.outsideArena and
        Pursuit.outsideArena(match, match.copId) == true

    -- ---------------------------------------------------- RUNNER escapes --
    --
    -- THE ESCAPE WINDOW (2026-08-29; the full argument lives with the two
    -- escape tunables in shared/config.lua and in the plan's 5.4f). Crossing
    -- `escapeDistance` no longer ends the round on the spot -- the owner:
    -- "when the runner moves 100m away it shouldn't be instant -- like 15-20
    -- secs time for the cop to get closer; if he does not find a way to fall
    -- back below the limit then it's [the cop's] loss."
    --
    -- So the escape is now a METER, the bust meter's mirror. It fills over
    -- `escapeGraceSeconds` while separation is at or beyond `escapeDistance`
    -- (and the rule is armed -- `escapeArmSeconds` still protects the
    -- opening), and it DRAINS over `escapeDrainSeconds` -- deliberately much
    -- faster -- while the cop has pulled the gap back under the line. Full
    -- meter, round to the runner, through the same `runner_escaped` outcome
    -- the instant rule used.
    --
    -- Drain rather than reset, and the OPPOSITE asymmetry to the bust meter,
    -- both on purpose:
    --   * drain, because a cop who claws the gap back for one second has not
    --     un-escaped his man -- partial credit persisting briefly is the same
    --     honesty the bust meter's drain bought the cop;
    --   * FASTER than the fill (6 s against 18 s), where the bust drains
    --     SLOWER than it fills, because the escape threatens to END the round
    --     -- pulling the runner back under the line is the cop's whole
    --     comeback and has to be worth something at once -- and because it is
    --     what makes boundary-flapping a losing strategy: hovering on the
    --     line, the runner needs to spend more than three quarters of his
    --     time beyond it just to hold level.
    --
    -- `escapeGraceSeconds` at 0 restores the instant rule exactly.
    --
    -- PRECEDENCE, stated rather than left to evaluation order: THE ESCAPE
    -- WINS. The two rules cannot both fire on one tick unless `bustDistance`
    -- is at or above `escapeDistance`, which is a misconfiguration the
    -- startup banner warns about -- but if the bands ever do overlap, a
    -- runner who has reached escape distance has reached it, and the cop
    -- cannot simultaneously be close enough to have caught him. The escape is
    -- evaluated first, and a tick that completes it returns before the bust
    -- can be looked at.
    local escapeArmed = match.escapeArmedAtMs == nil or now >= match.escapeArmedAtMs
    local graceMs = (t.escapeGraceSeconds or 0) * 1000
    if sep >= t.escapeDistance and escapeArmed and not runnerOutside then
        if graceMs <= 0 then
            return resolve(match, "runner_escaped", match.runnerId,
                ("%.0fm -- broke clear"):format(sep))
        end
        local was = match.escapeMeter or 0.0
        match.escapeMeter = was + (elapsed / graceMs)
        match.escapeFilling = true
        -- Announce the ATTEMPT, once, on the empty->filling edge. Both sides:
        -- the runner is told what he has to keep doing, the cop is told he is
        -- on a clock -- with the RULE distance, never the live one (see
        -- `separationFor`; a live number here would hand him the rangefinder
        -- the scanner exists to deny). Re-armed only by a fully drained meter
        -- plus `ESCAPE_NOTIFY_REARM_MS`, so flapping at the line cannot ring
        -- anyone's screen twice; the HUD bar carries the continuous story.
        if was <= 0.0 and (match.escapeNotifiedAtMs == nil or
            (now - match.escapeNotifiedAtMs) >= ESCAPE_NOTIFY_REARM_MS) then
            match.escapeNotifiedAtMs = now
            notify(match.runnerId, "warning",
                ("You're clear of %.0fm -- keep the gap for %.0fs to escape."):format(
                    t.escapeDistance, t.escapeGraceSeconds or 0), 4000)
            notify(match.copId, "warning",
                ("He's past %.0fm -- pull him back inside %.0fs or lose him."):format(
                    t.escapeDistance, t.escapeGraceSeconds or 0), 4000)
        end
        if match.escapeMeter >= 1.0 then
            match.escapeMeter = 1.0
            return resolve(match, "runner_escaped", match.runnerId,
                ("%.0fm -- held the gap through the %.0fs window"):format(
                    sep, t.escapeGraceSeconds or 0))
        end
    else
        local drainSeconds = t.escapeDrainSeconds or 6.0
        local escape = (match.escapeMeter or 0.0) -
            ((elapsed / 1000.0) / math.max(0.001, drainSeconds))
        match.escapeMeter = (escape > 0.0) and escape or 0.0
        match.escapeFilling = false
    end

    -- ------------------------------------------------- COP busts: THE METER --
    --
    -- The rule the owner's playtest broke, rebuilt. The old rule was "within
    -- `bustDistance` for `bustSeconds` CONSECUTIVE seconds", and it could not
    -- be satisfied by anyone chasing a car that never stopped: the radius was
    -- shorter than the vehicle, and any break at all threw away the whole hold.
    -- shared/config.lua carries the full argument above the distance columns.
    --
    -- What replaces it fills while the cop is inside the radius and drains,
    -- more slowly, while he is not. Two things follow that the old rule could
    -- not offer: a tail survives its own mistakes, and the runner can still
    -- shake it off by making the break a real one.
    --
    -- Evaluated AFTER the escape so a round can never end both ways in one
    -- tick. With `bustDistance` far below `escapeDistance` the two are mutually
    -- exclusive anyway, but the ordering makes that true independently of the
    -- tuning.
    local fillSeconds = t.bustFillSeconds or t.bustSeconds or 5.0
    local drainSeconds = t.bustDrainSeconds or (fillSeconds * 1.6)
    local contactDrainSeconds = t.bustContactDrainSeconds or drainSeconds
    local meter = match.bustMeter or 0.0

    -- THE ARREST GATE (2026-08-28; the argument is the "Relative speed" note
    -- in shared/config.lua). Proximity alone no longer fills: the runner must
    -- be effectively caught -- at or under his arrest speed, or stalled by a
    -- crash -- and the cop must himself be slow enough to be arresting rather
    -- than passing, and not stalled. An UNREADABLE speed fills nothing, the
    -- same "freeze, never guess" the separation applies: nil is "cannot
    -- tell", and a bust must not be earned on a guess.
    local contact = (sep <= t.bustDistance) and not copOutside
    local runnerPace = match.pace and match.pace.runner
    local copPace = match.pace and match.pace.cop
    local runnerStalled = paceStalled(match, "runner", now)
    local copStalled = paceStalled(match, "cop", now)
    local runnerPinned = runnerStalled or
        (runnerPace ~= nil and runnerPace.speedKph ~= nil and
         runnerPace.speedKph <= (tonumber(t.bustRunnerMaxSpeedKph) or math.huge))
    local copPresent = (not copStalled) and
        (copPace ~= nil and copPace.speedKph ~= nil and
         copPace.speedKph <= (tonumber(t.bustCopMaxSpeedKph) or math.huge))
    local closing = contact and runnerPinned and copPresent
    match.bustContact = contact
    match.bustClosing = closing

    if closing then
        -- Graded fill: on the bumper is worth more than shadowing at the edge.
        --
        -- `bustCoreFactor` at or inside `bustCoreDistance`, falling linearly to
        -- 1.0 at `bustDistance`. Absent config leaves the factor at 1.0, so a
        -- column that does not set the two keys gets a flat meter and still
        -- works -- which is what `Config.match.foot` relied on before it was
        -- given its own pair.
        local factor = 1.0
        local core = t.bustCoreDistance
        local coreFactor = t.bustCoreFactor or 1.0
        if core ~= nil and coreFactor > 1.0 and t.bustDistance > core then
            if sep <= core then
                factor = coreFactor
            else
                factor = coreFactor +
                    (1.0 - coreFactor) * ((sep - core) / (t.bustDistance - core))
            end
        end
        meter = meter + ((elapsed / 1000.0) * factor / math.max(0.001, fillSeconds))
        if meter >= 1.0 then
            match.bustMeter = 1.0
            return resolve(match, "runner_busted", match.copId,
                ("%.1fm, meter full"):format(sep))
        end
    else
        -- Two drain rates, and which one applies is the redesign's second
        -- half: INSIDE the radius the cop is still on him, so the meter only
        -- bleeds (`bustContactDrainSeconds`, slow) and repeated short pins
        -- ratchet upward; OUTSIDE it the runner has genuinely broken contact
        -- and the ordinary recovery (`bustDrainSeconds`) applies.
        local rate = contact and contactDrainSeconds or drainSeconds
        meter = meter - ((elapsed / 1000.0) / math.max(0.001, rate))
        if meter < 0.0 then meter = 0.0 end
    end
    match.bustMeter = meter

    -- `pursuit.bustrace` -- narrate the arrest gate itself, 1 Hz, time-boxed.
    -- The gate has five inputs the resolution line cannot carry, and proving
    -- "tailing at speed does not fill" NEEDS the negative case on record:
    -- a meter that stayed at 0% is only evidence together with the line
    -- showing contact=yes and the speeds that refused the fill.
    if match.bustTraceUntilMs ~= nil and now <= match.bustTraceUntilMs
        and (now - (match.lastBustTraceMs or 0)) >= 1000 then
        match.lastBustTraceMs = now
        log(("busttrace match %d r%d sep=%.1fm contact=%s runner=%s cop=%s pinned=%s present=%s stalled=%s/%s meter=%.0f%% %s"):format(
            match.id, match.round or 1, sep,
            contact and "yes" or "no",
            (runnerPace and runnerPace.speedKph) and ("%.0fkph"):format(runnerPace.speedKph) or "?",
            (copPace and copPace.speedKph) and ("%.0fkph"):format(copPace.speedKph) or "?",
            runnerPinned and "yes" or "no",
            copPresent and "yes" or "no",
            runnerStalled and "R" or "-", copStalled and "C" or "-",
            meter * 100,
            closing and "[FILLING]" or (contact and "[contact-bleed]" or "[draining]")))
    end

    if Config.debug.verboseMatch then
        log(("match %d r%d sep=%.1fm escape=%.0f%%%s bust=%.0f%%%s%s%s"):format(
            match.id, match.round or 1, sep, (match.escapeMeter or 0) * 100,
            match.escapeFilling and " [escaping]" or "",
            meter * 100,
            closing and " [filling]" or (contact and " [contact-bleed]" or " [draining]"),
            runnerOutside and " [runner outside: no escape accrual]" or "",
            copOutside and " [cop outside: no bust accrual]" or ""))
    end
end

CreateThread(function()
    while true do
        Wait(TICK_MS)
        local now = nowMs()
        for _, match in pairs(matches) do
            if match.state == "countdown" then
                -- The countdown used to push ONCE, from `pushRoles`, and then
                -- go silent for ten seconds. That was survivable while the HUD
                -- only had a clock to free-run -- but the boarding readout has
                -- to be live during exactly these ten seconds, because the
                -- countdown IS the window in which a player is meant to find
                -- his car and get into it. A push at the same 2 Hz as the
                -- active loop also re-anchors the clock, which a republished
                -- client needs and a hitching one benefits from.
                if (now - (match.lastHudPushMs or 0)) >= HUD_PUSH_MS then
                    match.lastHudPushMs = now
                    -- Through `pushState`, so the countdown carries the round
                    -- and the scoreboard like every other push. Round two of a
                    -- match begins here, and a HUD that learned the score only
                    -- once the chase started would show "1-0" ten seconds late.
                    pushState(match, function(playerId)
                        return {
                            remainingMs = match.countdownEndsAtMs and
                                math.max(0, match.countdownEndsAtMs - now) or nil,
                            boarding = boardingFor(match, playerId, now),
                        }
                    end)
                end
                if now >= match.countdownEndsAtMs then
                    beginActive(match)
                end
            elseif match.state == "active" then
                -- A rules error must not take the tick thread down with it:
                -- every other match still needs its clock, and a dead tick
                -- thread leaves everyone stranded in a match bucket.
                local ok, err = pcall(tickActive, match, now)
                if not ok then
                    log(("match %d tick error: %s"):format(match.id, tostring(err)))
                end
            end
        end
    end
end)

-- ----------------------------------------------------------------- commands --

Pursuit.downedByPlay = downedByPlay

-- The one command that answers "what is actually happening".
--
-- Extended in Phase E to carry the four new subsystems, because the next agent
-- has one game and limited VRAM: every line here is a question that would
-- otherwise cost a six-minute match to ask. Each Phase E module contributes its
-- own line through `Pursuit.describe.<name>(match)`, so a module that failed to
-- load prints nothing rather than crashing the command.
RegisterCommand("pursuit.match", function(source, _, raw)
    local count = 0
    local lines = {}
    local nextT, nextMode = tuning()
    for _, match in pairs(matches) do
        count = count + 1
        local t = tuning(match)
        local now = nowMs()
        local remaining = 0
        if match.state == "countdown" and match.countdownEndsAtMs then
            remaining = math.max(0, (match.countdownEndsAtMs - now) / 1000)
        elseif match.state == "active" and match.endsAtMs then
            remaining = math.max(0, (match.endsAtMs - now) / 1000)
        elseif match.state == "intermission" and match.intermissionEndsAtMs then
            remaining = math.max(0, (match.intermissionEndsAtMs - now) / 1000)
        end

        local who = {}
        for _, playerId in ipairs(match.members) do
            who[#who + 1] = ("%d:%s(%d)"):format(playerId,
                tostring(match.roles[playerId]), (match.score or {})[playerId] or 0)
        end

        local head = "-"
        if match.state == "active" then
            head = match.copReleased and "released"
                or ("held %.0fs"):format(math.max(0, (match.copReleaseAtMs - now) / 1000))
        end

        lines[#lines + 1] = ("match %d [%s] round %d/%d mode=%s bucket=%d %s remaining=%.0fs cop=%s%s%s"):format(
            match.id, match.state, match.round or 1, roundCount(match),
            tostring(match.mode), match.bucket,
            table.concat(who, " "), remaining, head,
            match.rematch and " rematch" or "",
            match.repaired and " re-paired" or "")
        -- The bust reads as a PERCENTAGE and a direction, because that is what
        -- it now is: a meter that fills and drains, not a stopwatch. "62%
        -- closing" and "62% draining" are different situations and a single
        -- number could not tell them apart.
        lines[#lines + 1] = ("    spawn=%s(%s) sep=%s escape=%.0f%% %s of %.0fs%s bust=%.0f%% %s (<=%.0fm, fill %.0fs / drain %.0fs)"):format(
            match.spawn and match.spawn.name or "none",
            tostring(match.spawnSource or "-"),
            match.separation and ("%.1fm"):format(match.separation)
                or ("unreadable(%s)"):format(tostring(match.separationDetail)),
            (match.escapeMeter or 0) * 100,
            match.escapeFilling and "escaping" or "held",
            t.escapeGraceSeconds or 0,
            (match.escapeArmedAtMs ~= nil and now < match.escapeArmedAtMs)
                and (" [arms in %.1fs]"):format((match.escapeArmedAtMs - now) / 1000) or "",
            (match.bustMeter or 0) * 100,
            match.bustClosing and "closing" or "draining",
            t.bustDistance,
            t.bustFillSeconds or t.bustSeconds or 0,
            t.bustDrainSeconds or 0)

        -- Fixed order so two runs of the command are diffable, and pcall'd so a
        -- broken describer costs one line rather than the whole readout.
        for _, name in ipairs({ "vehicles", "scanner", "arena", "roadblock", "ranked" }) do
            local describe = Pursuit.describe and Pursuit.describe[name]
            if describe ~= nil then
                local ok, text = pcall(describe, match, now)
                lines[#lines + 1] = ("    %-10s %s"):format(
                    name, ok and tostring(text) or ("describe error: " .. tostring(text)))
            end
        end
    end
    Pursuit.output(source, raw, true,
        ("%d match(es) in flight -- next match mode=%s best-of-%d, escape >=%.0fm over %.0fs, bust <=%.0fm meter fill %.0fs / drain %.0fs"):format(
            count, nextMode, roundCount(nil),
            nextT.escapeDistance, nextT.escapeGraceSeconds or 0,
            nextT.bustDistance,
            nextT.bustFillSeconds or nextT.bustSeconds or 0,
            nextT.bustDrainSeconds or 0))
    for _, line in ipairs(lines) do
        Pursuit.output(source, raw, true, "  " .. line)
    end
end, false)

-- Read or set the mode NEW matches are created in.
--
-- A test affordance with teeth: it is the difference between re-testing a win
-- condition on foot in ninety seconds and re-testing it in a car over six
-- minutes. Matches already in flight are untouched by design -- they captured
-- their column at creation.
RegisterCommand("pursuit.mode", function(source, args, raw)
    local wanted = args and args[1]
    if wanted == nil then
        return Pursuit.output(source, raw, true,
            ("match mode = %s (declared default %s); foot|vehicle to change"):format(
                nextMode(), tostring((Config.tunables.matchMode or {}).value)))
    end
    wanted = tostring(wanted):lower()
    -- Written THROUGH the tunable rather than into a local of this file, so
    -- this command and Warden's Tuning tab cannot disagree about what the next
    -- match will be. The host does the validating (the choice list is declared
    -- in shared/config.lua), the persisting, and the holding until the next
    -- match is created -- so the usage line below is a fallback for a value the
    -- declaration refuses, not the only guard.
    local ok, message = Open77.tunables.set("matchMode", wanted)
    if not ok then
        return Pursuit.output(source, raw, false,
            ("%s -- usage: pursuit.mode [foot|vehicle]"):format(tostring(message)))
    end
    local t = tuning()
    Pursuit.output(source, raw, true,
        ("match mode = %s -- escape >=%.0fm held %.0fs / recovered %.0fs (arms %.0fs after release), bust <=%.0fm meter fill %.0fs / drain %.0fs, head start %.0fs, %ds per round; matches in flight keep their own"):format(
            nextMode(), t.escapeDistance, t.escapeGraceSeconds or 0,
            t.escapeDrainSeconds or 0, t.escapeArmSeconds or 0,
            t.bustDistance, t.bustFillSeconds or t.bustSeconds or 0,
            t.bustDrainSeconds or 0, t.headStartSeconds, t.durationSeconds))
end, false)

-- Force a match with whoever is queued, ignoring the size requirement. Test
-- affordance: a 1v1 mode otherwise needs two live clients for every iteration.
RegisterCommand("pursuit.force", function(source, args, raw)
    local queue = Pursuit.queue
    local picked = {}

    -- `pursuit.force 9 10` -- name the two sides instead of queueing them.
    --
    -- The ready-up containment check is Phase A's subject and is proven. From
    -- Phase C on, requiring two players to physically stand inside a 2 m circle
    -- before any win condition can be tested makes every iteration hostage to
    -- lobby geometry -- and it measurably is: a placement onto the ready-up
    -- mark settles up to 20 m away on the Corpo Plaza terrace, so the intent is
    -- refused with `too_far` however precisely it is aimed. Naming the sides
    -- skips the queue and nothing else: startMatch, the role assignment, the
    -- placement and the rules are the same code either way.
    if args ~= nil and (args.n or 0) > 0 then
        for index = 1, args.n do
            local playerId = tonumber(args[index])
            if playerId == nil or playerId <= 0 then
                return Pursuit.output(source, raw, false,
                    ("not a player id: %s"):format(tostring(args[index])))
            end
            local record = Pursuit.ensurePlayer(playerId)
            if record == nil then
                return Pursuit.output(source, raw, false,
                    ("player %d is not tracked"):format(playerId))
            end
            -- The readiness gate, for the same reason the lobby leash now consults it.
            --
            -- This is the ONE command that can name a player who never asked for
            -- anything: `ensurePlayer` ADOPTS an id the roster has never seen, so
            -- `pursuit.force 3 4` reaches someone still inside `open77_appearance`'s
            -- character creator -- and `startMatch` would then transfer his bucket, set
            -- his team and kill/respawn him onto a match mark, which is the whole
            -- catalogue of things the gate exists to forbid.
            --
            -- The queue path below cannot do this and needs no guard: entering the queue
            -- requires standing inside the 2 m ready-up circle in the lobby bucket
            -- (`toggleQueue` re-derives the position server-side), which requires having
            -- been placed, which requires the gate to have opened already.
            --
            -- Fail open if `Pursuit.readyToBeActedUpon` is absent, so this file still
            -- loads against a main.lua that predates it.
            if Pursuit.readyToBeActedUpon ~= nil and not Pursuit.readyToBeActedUpon(playerId) then
                return Pursuit.output(source, raw, false,
                    ("player %d is not ready to be acted upon yet -- their join-time gate is still held (character creation, most likely). Try again once the log says their gate opened."):format(
                        playerId))
            end
            if record.state == "lobby" then
                -- Enter the queue through the guarded transition rather than
                -- writing the state: an invalid move must still be refused.
                if not Pursuit.transition(playerId, "queued", "forced") then
                    return Pursuit.output(source, raw, false,
                        ("player %d refused lobby -> queued"):format(playerId))
                end
                queue[#queue + 1] = playerId
            elseif record.state ~= "queued" then
                return Pursuit.output(source, raw, false,
                    ("player %d is %s, not available"):format(playerId, tostring(record.state)))
            end
            picked[#picked + 1] = playerId
        end
        if startMatch(picked) then
            return Pursuit.output(source, raw, true,
                ("match forced with %d player(s)"):format(#picked))
        end
        return Pursuit.output(source, raw, false, "could not start a match")
    end

    if #queue == 0 then
        return Pursuit.output(source, raw, false, "queue is empty")
    end
    for index = 1, math.min(#queue, Config.match.size) do picked[index] = queue[index] end
    if #picked < 2 then
        -- Solo shakedown: one member exercises bucket allocation, the
        -- countdown, the spawn placement, the clock and the return
        -- transaction. Separation is unreadable with nobody to measure
        -- against, so escape and bust never arm and the clock ends it.
        Pursuit.output(source, raw, true,
            "forcing a single-member match: lifecycle only, no opponent")
    end
    if startMatch(picked) then
        Pursuit.output(source, raw, true, "match forced")
    else
        Pursuit.output(source, raw, false, "could not start a match")
    end
end, false)

-- Get me out of this staircase.
--
-- A player can materialise INSIDE geometry -- a step, a kerb, a ramp within a
-- stride of an authored mark -- and the only escape found in play was to
-- disconnect and reconnect. `Config.match.spawnLiftMetres` makes that much
-- rarer; this is what to do when it happens anyway.
--
-- Re-places the caller on his own mark rather than at his current position,
-- because his current position is the problem: it is inside something, and
-- putting him back there half a metre higher is a guess about which way out is.
-- The mark is surveyed ground he was meant to be standing on.
--
-- THE WINDOW IS THE SAFETY, and without it this would be an exploit rather than
-- a rescue. A placement grants a placement grace, during which separation is
-- unreadable and both meters drain -- so an unstick available mid-chase would
-- let a cornered runner erase the cop's work and teleport away from him, and
-- with the 100 m escape it would hand him free ground toward a win. Inside the
-- opening seconds there is nothing to erase and nowhere to gain: he is being
-- put back where the round started.
--
-- Once per round, on top of the window, so it cannot be spammed into a stutter.
RegisterCommand("pursuit.unstick", function(source, _, raw)
    local playerId = source
    if playerId == nil or playerId <= 0 then
        return Pursuit.output(source, raw, false,
            "pursuit.unstick is for the player who is stuck; run it in game")
    end

    local match = Pursuit.matchOf(playerId)
    if match == nil then
        -- Outside a match there is a lobby to go back to, and main.lua already
        -- owns that path. Say so rather than growing a second one here.
        return Pursuit.output(source, raw, false,
            "you are not in a match; use the lobby return instead")
    end

    local window = (tonumber(tuned(match, "unstickWindowSeconds")) or 0.0) * 1000
    if window <= 0 then
        return Pursuit.output(source, raw, false, "unstick is disabled on this server")
    end

    local now = nowMs()
    local open = match.state == "countdown"
    if match.state == "active" and match.startedAtMs ~= nil then
        open = (now - match.startedAtMs) <= window
    end
    if not open then
        return Pursuit.output(source, raw, false,
            ("unstick is only available in the first %.0fs of a round"):format(window / 1000))
    end

    match.unstuck = match.unstuck or {}
    local usedInRound = match.unstuck[playerId]
    if usedInRound == (match.round or 1) then
        return Pursuit.output(source, raw, false, "you have already used unstick this round")
    end

    local role = match.roles[playerId]
    local point = match.spawn ~= nil and match.spawn[role] or nil
    if point == nil or point.position == nil then
        return Pursuit.output(source, raw, false, "no mark to put you back on")
    end

    match.unstuck[playerId] = match.round or 1
    local record = Pursuit.players[playerId]
    if record ~= nil then record.placedAtMs = now end
    local ok = Pursuit.placeAt(playerId, liftedMark(point.position),
        point.playerYaw or point.heading, match.bucket, "unstick")
    log(("match %d round %d: player %d (%s) asked for unstick -> %s"):format(
        match.id, match.round or 1, playerId, tostring(role),
        ok and "re-placed on his mark" or "placement REFUSED, see above"))
    Pursuit.output(source, raw, ok,
        ok and "back on your mark" or "could not re-place you; try again in a moment")
end, false)

-- Narrate the periodic HUD push for a few seconds. The push is the HUD's only
-- window onto a live match, so its shape is a contract; this is how that
-- contract is checked without the HUD resource loaded.
RegisterCommand("pursuit.hudtrace", function(source, args, raw)
    local seconds = tonumber(args and args[1]) or 5
    if seconds <= 0 or seconds > 60 then
        return Pursuit.output(source, raw, false, "usage: pursuit.hudtrace [seconds 1..60]")
    end
    local armed = 0
    for _, match in pairs(matches) do
        if match.state == "active" then
            match.hudTraceUntilMs = nowMs() + math.floor(seconds * 1000)
            match.lastHudTraceMs = nil
            armed = armed + 1
        end
    end
    Pursuit.output(source, raw, armed > 0,
        ("hud trace armed for %.0fs on %d match(es)"):format(seconds, armed))
end, false)

-- Narrate the arrest gate for a few seconds, one line per second per match.
-- This is the instrument the 2026-08-28 redesign is proven with: the
-- resolution line can say a bust happened, but only this can show a fill that
-- was REFUSED and name which condition refused it -- contact without the
-- speeds, speeds without the contact, a stalled cop. Time-boxed like
-- `pursuit.hudtrace`, and for the same reason: file I/O on the Lua frame
-- budget must not be left armed.
RegisterCommand("pursuit.bustrace", function(source, args, raw)
    local seconds = tonumber(args and args[1]) or 30
    if seconds <= 0 or seconds > 300 then
        return Pursuit.output(source, raw, false, "usage: pursuit.bustrace [seconds 1..300]")
    end
    local armed = 0
    for _, match in pairs(matches) do
        if match.state == "active" then
            match.bustTraceUntilMs = nowMs() + math.floor(seconds * 1000)
            match.lastBustTraceMs = nil
            armed = armed + 1
        end
    end
    Pursuit.output(source, raw, armed > 0,
        ("bust trace armed for %.0fs on %d match(es)"):format(seconds, armed))
end, false)

-- Release the cop now instead of waiting out the head start. The head start is
-- the longest fixed wait in a test iteration, and skipping it weakens no
-- assertion: releaseCop is the same code path either way.
RegisterCommand("pursuit.release", function(source, _, raw)
    local released = 0
    for _, match in pairs(matches) do
        if match.state == "active" and not match.copReleased then
            releaseCop(match)
            released = released + 1
        end
    end
    Pursuit.output(source, raw, released > 0,
        ("released the cop in %d match(es)"):format(released))
end, false)

AddEventHandler("onResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    local t, mode = tuning()
    log(("match lifecycle ready -- buckets %d..%d, %ds countdown, best-of-%d at %ds per round, %.0fs between rounds, mode %s"):format(
        Config.match.buckets.from, Config.match.buckets.to,
        Tune.countdownSeconds, roundCount(nil), t.durationSeconds,
        tonumber(Tune.intermissionSeconds) or 8.0, mode))
    log(("win conditions in %s mode -- ESCAPE METER >=%.0fm fill %.0fs / drain %.0fs (armed %.0fs after release), BUST METER <=%.0fm fill %.0fs / drain %.0fs (core %.0fm x%.2f), head start %.0fs, %d spawn pair(s)"):format(
        mode, t.escapeDistance, t.escapeGraceSeconds or 0,
        t.escapeDrainSeconds or 0, t.escapeArmSeconds or 0,
        t.bustDistance, t.bustFillSeconds or t.bustSeconds or 0,
        t.bustDrainSeconds or 0, t.bustCoreDistance or 0, t.bustCoreFactor or 1.0,
        t.headStartSeconds, Config.match.spawns and #Config.match.spawns or 0))
    log(("arrest gate -- runner <=%.0f km/h, cop <=%.0f km/h, contact bleed %.0fs; crash stall %.1fs past %.0f km/h dropping %.0f"):format(
        t.bustRunnerMaxSpeedKph or 0, t.bustCopMaxSpeedKph or 0,
        t.bustContactDrainSeconds or 0, t.crashStallSeconds or 0,
        t.crashMinSpeedKph or 0, t.crashDropKph or 0))
    log(("tie-break for a level match: %s; the clock favours the %s (an attempt underway at the buzzer plays out)"):format(
        tostring(Tune.tieBreak), tostring(Tune.timeoutWinner or "cop")))
    -- The two win conditions must describe disjoint bands, or a single tick
    -- could satisfy both and the outcome would be decided by the order the
    -- lines happen to be written in. The escape wins that race by construction
    -- (it is evaluated first and returns), so this is a warning rather than a
    -- refusal -- but a mode whose bust radius reaches its escape distance is
    -- not tuned, it is broken.
    --
    -- It reads the TUNABLES and not the columns, because the tunables are what
    -- a match plays by -- and because an operator can now reach these numbers
    -- from a web page, which is precisely the way a bust radius ends up above
    -- an escape distance. The bounds cannot express "below whatever the other
    -- one is", so this is the check that catches it, on every start and after
    -- every reload.
    if (Tune.bustDistance or 0) >= (Tune.escapeDistance or math.huge) then
        log(("TUNING WARNING -- bust radius %.0fm is not below escape distance %.0fm; the two win conditions overlap, and the escape wins every tie"):format(
            Tune.bustDistance or 0, Tune.escapeDistance or 0))
    end

    -- A control in the panel that moves nothing is worse than no control at
    -- all, so say so at start rather than letting an operator discover it by
    -- retuning a number and watching nothing happen. Every key declared in
    -- shared/config.lua must be read somewhere: the distance columns take
    -- `COLUMN_KEYS`, and everything else is read by name through `tuned` or
    -- `Tune` in this file or in server/main.lua.
    local wired = {}
    for _, key in ipairs(COLUMN_KEYS) do wired[key] = true end
    for _, key in ipairs({
        "matchMode", "roundsPerMatch", "countdownSeconds", "intermissionSeconds",
        "tieBreak", "deciderDurationSeconds", "timeoutWinner",
        "copDeathEndsMatch", "copHoldRadius", "unstickWindowSeconds",
        "lobbyRadius", "leashWarnSeconds", "leashReturnSeconds", "lobbySpawnSpacing",
        "rematchWindowSeconds", "rematchPairWindowSeconds", "maxConsecutiveRematches",
    }) do wired[key] = true end
    local orphans = {}
    for key in pairs(Config.tunables or {}) do
        if not wired[key] then orphans[#orphans + 1] = key end
    end
    if #orphans > 0 then
        table.sort(orphans)
        log(("TUNING WARNING -- declared but read nowhere, so the panel would move nothing: %s"):format(
            table.concat(orphans, ", ")))
    end
end)

-- ----------------------------------------------------- surface for Phase E --
--
-- Everything below this line exists so that vehicles.lua, scanner.lua,
-- bounds.lua and roadblock.lua can do their jobs without reaching into
-- match.lua's locals. It is the same mechanism `Pursuit` already was in
-- main.lua: plain globals inside one Lua state, which is what a server gamemode
-- has instead of exports.

-- The live match table, and the reverse index. Read-mostly: a Phase E module
-- may annotate its OWN field on a match record (match.cars, match.scan,
-- match.bounds, match.roadblock) and must not touch anyone else's.
Pursuit.matches = matches
Pursuit.playerMatch = playerMatch

function Pursuit.matchOf(playerId)
    local matchId = playerMatch[playerId]
    if matchId == nil then return nil end
    return matches[matchId]
end

-- Re-send one player everything his client needs to rebuild a match he is
-- ALREADY in, without touching the match itself.
--
-- Why this exists: a resource republish swaps the client's whole resource host,
-- which destroys every client Lua VM and rebuilds it. `pursuit/client/main.lua`
-- comes back with `inMatch = false` and draws the LOBBY furniture, and
-- `pursuit_hud` comes back with an empty state table. Neither knows a match is
-- running, and nothing else would tell them until the next 2 Hz tick push --
-- which never comes at all during `countdown`, the state a match spends its
-- first ten seconds in.
--
-- So this is the server's half of "a republish is not a world transition":
-- server/main.lua keeps the player's bucket, and this puts his screen back.
--
-- READ-ONLY with respect to match state. It sends the numbers that already
-- exist; it does not advance a clock, take a scanner fix, or re-fire a hook. A
-- re-prime must be free to happen ten times in a row.
function Pursuit.repushMatchTo(playerId)
    local match = Pursuit.matchOf(playerId)
    if match == nil then return false end
    local now = nowMs()

    local opponent
    for _, other in ipairs(match.members) do
        if other ~= playerId then opponent = other end
    end

    -- The REMAINDER, never the duration. `pursuit_hud` prefers `remainingMs`
    -- and falls back to the full duration when it is absent -- which after a
    -- republish would hand the player back a clock that had reset to 6:00.
    local remainingMs
    if match.state == "active" and match.endsAtMs ~= nil then
        remainingMs = math.max(0, match.endsAtMs - now)
    elseif match.state == "countdown" and match.countdownEndsAtMs ~= nil then
        remainingMs = math.max(0, match.countdownEndsAtMs - now)
    elseif match.state == "intermission" and match.intermissionEndsAtMs ~= nil then
        remainingMs = math.max(0, match.intermissionEndsAtMs - now)
    end

    local mine, theirs = scoreFor(match, playerId)
    local extra = {
        role = match.roles[playerId],
        opponentName = opponent and Open77.players.name(opponent) or nil,
        remainingMs = remainingMs,
        scoreSelf = mine,
        scoreOpponent = theirs,
        -- Both omitted rather than zeroed when unknown, exactly as the live
        -- push does: "0.0 m" tells a runner he has already been caught, and
        -- "0.0s ago" tells a cop his blip is live. `separation` is RUNNER-ONLY
        -- besides -- a republish must not be a way to see through the gate the
        -- live push applies.
        separation = separationFor(match, playerId, match.separation),
        scannerAgeMs = scannerAgeFor(match, playerId, now),
        boarding = boardingFor(match, playerId, now),
        bustMeter = (match.state == "active" and match.copReleased)
            and (match.bustMeter or 0.0) or nil,
        bustClosing = (match.state == "active" and match.copReleased)
            and (match.bustClosing == true) or nil,
        bustContact = (match.state == "active" and match.copReleased)
            and (match.bustContact == true) or nil,
        bustStalled = (match.state == "active")
            and stallRemainingFor(match, playerId, now) or nil,
        escapeProgress = (match.state == "active") and escapeProgressOf(match) or nil,
        escapeFilling = (match.state == "active" and escapeProgressOf(match) ~= nil)
            and (match.escapeFilling == true) or nil,
    }
    if match.state == "resolved" then
        -- Inside the five-second scoreboard beat. Replay the card; do NOT send
        -- a separation, because the match is over and the number would keep
        -- ticking on a HUD that should be standing down.
        extra.outcome = match.outcome
        -- The MATCH result, matching what `finishMatch` sent the first time. A
        -- republish must not turn a drawn match into a loss.
        extra.won = match.champion ~= nil and playerId == match.champion
        extra.matchResult = match.drawn and "draw"
            or ((match.champion ~= nil and playerId == match.champion) and "win" or "loss")
        extra.separation = nil
        extra.scannerAgeMs = nil
    elseif match.state == "intermission" then
        -- Between rounds. The last round's card, replayed, with the countdown
        -- to the next one -- the same three things the live push sent.
        local last = (match.rounds or {})[#(match.rounds or {})]
        if last ~= nil then
            extra.outcome = last.outcome
            extra.won = last.winner ~= nil and playerId == last.winner
        end
        extra.nextRound = (match.round or 1) + 1
        extra.nextIsDecider = (match.deciderAdded == true
            and extra.nextRound >= roundCount(match)) or nil
        extra.separation = nil
        extra.scannerAgeMs = nil
    end

    TriggerClientEvent("pursuit:matchState", playerId, matchStatePayload(match, extra))

    -- The cop's scanner blip died with the old client VM. Installed by
    -- server/scanner.lua, absent when the scanner is disabled, and it re-sends
    -- the LAST fix without taking a new one -- so the blip comes back exactly as
    -- stale as it was, which is the whole mechanic.
    if match.state ~= "resolved" and Pursuit.repushScannerTo ~= nil then
        Pursuit.repushScannerTo(match, playerId)
    end
    return true
end

Pursuit.resolveMatch = resolve
Pursuit.tuning = tuning
Pursuit.notify = notify
Pursuit.pushToMatch = push
Pursuit.onMatch = onMatch
-- Shared so nothing else in the resource has to re-derive "which table are this
-- match's marks in". server/bounds.lua sweeps both tables at startup and needs
-- the same names this uses; the offline harness asserts the coupling through it.
Pursuit.spawnTableFor = spawnTableFor
Pursuit.pickSpawnPair = pickSpawnPair
Pursuit.forwardFromHeading = forwardFromHeading
Pursuit.rightFromHeading = rightFromHeading
Pursuit.headingFromVector = headingFromVector

-- The mode the NEXT match will be created in. A function, not a value, and it
-- always was: the answer moves the moment an operator retunes `matchMode`.
function Pursuit.activeMode() return nextMode() end

-- One-line-per-subsystem contributions to `pursuit.match`. Each module installs
-- its own key; a missing key prints nothing.
Pursuit.describe = Pursuit.describe or {}
