-- Pursuit -- arena bounds.
--
-- Design §5.5 item 7, and the plan's §0 decision: "Watson, bounded -- warn at
-- the edge, bust 10 s later."
--
-- ============================================================================
-- OFF SINCE 2026-08-26. `Config.arena.enabled` is false, on the owner's
-- instruction after the first real playtest: "faut remove le out of bounds
-- qu'on puisse aller ou on veut sur la map". The whole of Night City is the
-- arena now. Every hook, command and readout below already begins by testing
-- that flag, so this file is inert -- it is not dead code, it is a rule that is
-- switched off, and one word turns it back on.
--
-- Why it can be switched off without the mode collapsing, since the argument
-- below is a good one and has NOT been refuted:
--
-- The dominant strategy this rule existed to kill was "drive to the Badlands
-- and idle out the clock". That strategy needed two things that are both gone.
-- It needed a long timer to idle out -- the round is 3 minutes now, not 6. And
-- it needed distance to be worth nothing -- but the escape is now 100 m and
-- INSTANT, so a runner who drives far away does not idle, he simply wins, in
-- the first thirty seconds, by the rule that says shaking the cop off is the
-- win. There is nothing left to idle for.
--
-- What genuinely changes: nothing stops a match wandering into ground nobody
-- surveyed. That is a spawn-quality and streaming risk rather than a rules
-- risk, and it is the price the owner has chosen to pay for the freedom of the
-- map.
-- ============================================================================
--
-- The rest of this header describes the rule as built, and is still accurate.
--
-- Without this the mode had a dominant strategy and it was not a chase: the
-- runner drives to the Badlands, parks, and idles out six minutes with the cop
-- 4 km behind him. Every other mechanic in Phase E is about making the chase
-- interesting; this one was about making a chase happen at all.
--
-- The shape is the LOBBY LEASH's, deliberately, down to the numbers. There are
-- now two places in this gamemode that say "you are somewhere you should not
-- be, come back", and having them behave differently would be two things to
-- learn instead of one. The differences are only the ones the situation forces:
--
--   * the lobby RETURNS you (a placement); the arena ENDS THE MATCH. Placing a
--     player mid-chase would be a kill-then-respawn in the middle of a rule
--     that measures separation -- it would freeze both accumulators, teleport
--     one player, and hand the other a nonsense reading. Ending it is honest.
--   * the lobby warns once; the arena re-warns. Ten seconds is a long time at
--     140 km/h and the player deserves to be told how much of it is left.
--
-- The measure is PLANAR. An arena is a district footprint and Night City is
-- vertical: a runner on a rooftop ninety metres up is still in Watson. Match
-- separation includes z because a bust is about reach; bounds exclude it
-- because bounds are about geography.

local Config = PursuitConfig

local function log(text) Pursuit.log(text) end

-- Per-match, per-player state on `match.bounds`:
--   [playerId] = { outsideSinceMs, warnedAtMs, lastDistance }
local function stateOf(match)
    local bounds = match.bounds
    if bounds == nil then
        bounds = {}
        match.bounds = bounds
    end
    return bounds
end

local function entryFor(match, playerId)
    local bounds = stateOf(match)
    local entry = bounds[playerId]
    if entry == nil then
        entry = { outsideSinceMs = nil, warnedAtMs = nil, lastDistance = nil }
        bounds[playerId] = entry
    end
    return entry
end

-- Returns inside, distance. `distance` is nil when the server genuinely cannot
-- tell, and callers must treat that as "do not judge" -- never as "outside".
-- Same contract, and the same reasoning, as `containsPlayer` in main.lua.
local function evaluate(playerId, bucket)
    local position = Open77.players.position(playerId)
    if position == nil then return nil, nil end
    if position.bucket ~= bucket then return nil, nil end
    local dx = position.x - Config.arena.center.x
    local dy = position.y - Config.arena.center.y
    local planar = math.sqrt(dx * dx + dy * dy)
    return planar <= Config.arena.radius, planar
end

local OUTCOME_FOR_ROLE = {
    runner = "runner_out_of_bounds",
    cop = "cop_out_of_bounds",
}

Pursuit.onMatch("tick", function(match, now)
    if not Config.arena.enabled then return end

    local warnMs = (Config.arena.warnSeconds or 4.0) * 1000
    local bustMs = (Config.arena.bustSeconds or 10.0) * 1000
    local repeatMs = (Config.arena.warnRepeatSeconds or 3.0) * 1000

    for _, playerId in ipairs(match.members) do
        local record = Pursuit.players[playerId]
        -- The placement grace, honoured here as everywhere else: no rule judges
        -- a player while a placement transaction is still in flight. The match
        -- spawn itself is already covered by `match.evaluateFromMs`, which the
        -- tick checked before calling any hook; this catches anything that
        -- places a player mid-match, `pursuit.tp` included.
        local settled = record == nil or record.graceUntilMs == nil
            or now >= record.graceUntilMs
        if settled then
            local entry = entryFor(match, playerId)
            local inside, distance = evaluate(playerId, match.bucket)
            entry.lastDistance = distance

            if inside == nil then
                -- Cannot tell. FREEZE: leave `outsideSinceMs` exactly as it is.
                -- One missing snapshot is not evidence that a player came back,
                -- and it is not evidence that he left either. Clearing it here
                -- would let a runner sit outside the arena forever by driving
                -- through anything that interrupts replication.
            elseif inside then
                if entry.outsideSinceMs ~= nil and Config.debug.verboseArena then
                    log(("match %d: player %d back inside the arena after %.1fs"):format(
                        match.id, playerId, (now - entry.outsideSinceMs) / 1000))
                end
                entry.outsideSinceMs = nil
                entry.warnedAtMs = nil
                -- Reset too, so a second excursion tells the opponent again.
                entry.opponentToldAtMs = nil
            else
                entry.outsideSinceMs = entry.outsideSinceMs or now
                local elapsed = now - entry.outsideSinceMs

                if elapsed >= bustMs then
                    local role = match.roles[playerId]
                    local outcome = OUTCOME_FOR_ROLE[role]
                    local winner
                    for _, other in ipairs(match.members) do
                        if other ~= playerId then winner = other end
                    end
                    if outcome == nil then
                        -- A member with no role at all should be impossible;
                        -- log rather than invent an outcome vocabulary.
                        log(("match %d: player %d out of bounds with role '%s'; ignored"):format(
                            match.id, playerId, tostring(role)))
                    else
                        log(("match %d: %s (player %d) out of bounds %.0fm for %.1fs -> %s"):format(
                            match.id, tostring(role), playerId,
                            distance or -1, elapsed / 1000, outcome))
                        return Pursuit.resolveMatch(match, outcome, winner,
                            ("%.0fm from the arena centre for %.0fs"):format(
                                distance or -1, elapsed / 1000))
                    end
                elseif elapsed >= warnMs then
                    local due = entry.warnedAtMs == nil
                        or (now - entry.warnedAtMs) >= repeatMs
                    if due then
                        entry.warnedAtMs = now
                        local remaining = math.max(0, (bustMs - elapsed) / 1000)
                        Pursuit.notify(playerId, "error",
                            ("OUT OF BOUNDS — return to Watson (%.0fs)"):format(remaining),
                            math.max(2000, math.floor(repeatMs)))
                        -- The opponent is told once, at the first warning only.
                        -- He has a right to know the match may be about to end
                        -- for a reason he had nothing to do with, and no reason
                        -- to be told it four times.
                        if entry.opponentToldAtMs == nil then
                            entry.opponentToldAtMs = now
                            for _, other in ipairs(match.members) do
                                if other ~= playerId then
                                    Pursuit.notify(other, "info",
                                        "Your opponent is leaving the zone.", 4000)
                                end
                            end
                        end
                        if Config.debug.verboseArena then
                            log(("match %d: player %d outside %.0fm, %.1fs left"):format(
                                match.id, playerId, distance or -1, remaining))
                        end
                    end
                end
            end
        end
    end
end)

Pursuit.onMatch("resolved", function(match)
    match.bounds = nil
end)

-- Is this player outside the arena, as of the rule's own most recent look?
--
-- Published so the win conditions can defer to containment instead of racing
-- it. Reading the rule's stored verdict rather than re-evaluating is
-- deliberate: the tick hook above ran earlier in this same tick, so the answer
-- is current, and sharing one verdict means the escape is suppressed for
-- exactly the interval bounds considers the player outside -- no window where
-- the two rules disagree about where somebody is.
--
-- Three answers, not two. `nil` means the rule has not judged this player at
-- all (spawn settle, placement grace, arena disabled) and is not a claim that
-- he is inside; callers must not read it as one.
function Pursuit.outsideArena(match, playerId)
    if not Config.arena.enabled then return nil end
    local bounds = match.bounds
    local entry = bounds and bounds[playerId] or nil
    if entry == nil or entry.lastDistance == nil then return nil end
    return entry.outsideSinceMs ~= nil
end

-- ---------------------------------------------------------------- readouts --

Pursuit.describe = Pursuit.describe or {}
Pursuit.describe.arena = function(match, now)
    if not Config.arena.enabled then return "disabled" end
    local bounds = match.bounds
    local parts = {}
    for _, playerId in ipairs(match.members) do
        local entry = bounds and bounds[playerId]
        local outside = entry and entry.outsideSinceMs
        -- Three states, not two, and the difference matters when reading this
        -- after a surprise. "not-judged" means the rule has never looked at
        -- this player -- the spawn settle window, or a placement grace.
        -- "unreadable" means it looked and the server could not tell.
        local distance = "not-judged"
        if entry ~= nil then
            distance = entry.lastDistance and ("%.0fm"):format(entry.lastDistance)
                or "unreadable"
        end
        parts[#parts + 1] = ("%d:%s%s"):format(playerId, distance,
            outside and (" OUT %.1fs"):format((now - outside) / 1000) or "")
    end
    return ("r=%.0fm centre=%.0f,%.0f  %s"):format(
        Config.arena.radius, Config.arena.center.x, Config.arena.center.y,
        table.concat(parts, "  "))
end

-- ----------------------------------------------------------------- commands --

-- What the server sees, for the arena, for whoever asks.
--
-- The `<mode>.where` habit from docs/writing-a-gamemode.md §6, applied to the
-- second containment rule in the mode: print the position, the computed
-- distance, the verdict and the reason, so a bounds bust can be read rather
-- than guessed at.
RegisterCommand("pursuit.bounds", function(source, args, raw)
    Pursuit.output(source, raw, true,
        ("arena %s -- centre %.1f,%.1f,%.1f radius %.0fm, warn %.0fs, bust %.0fs (PLANAR)"):format(
            Config.arena.enabled and "ON" or "OFF",
            Config.arena.center.x, Config.arena.center.y, Config.arena.center.z,
            Config.arena.radius, Config.arena.warnSeconds, Config.arena.bustSeconds))

    local playerId = tonumber(args and args[1])
    local reported = 0
    for matchId, match in pairs(Pursuit.matches) do
        for _, member in ipairs(match.members) do
            if playerId == nil or playerId == member then
                reported = reported + 1
                local position = Open77.players.position(member)
                local inside, distance = evaluate(member, match.bucket)
                local entry = match.bounds and match.bounds[member]
                Pursuit.output(source, raw, true,
                    ("  match %d %s player %d pos=%s bucket=%s planar=%s inside=%s outsideFor=%s"):format(
                        matchId, tostring(match.roles[member]), member,
                        position and ("%.1f,%.1f,%.1f"):format(
                            position.x, position.y, position.z) or "unreadable",
                        position and tostring(position.bucket) or "?",
                        distance and ("%.1fm"):format(distance) or "?",
                        inside == nil and "cannot-tell" or tostring(inside),
                        (entry and entry.outsideSinceMs)
                            and ("%.1fs"):format((Pursuit.nowMs() - entry.outsideSinceMs) / 1000)
                            or "-"))
            end
        end
    end
    if reported == 0 then
        Pursuit.output(source, raw, true, "  no players in a match")
    end
end, false)

AddEventHandler("onResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    if not Config.arena.enabled then
        -- Said in full rather than in three words, because "arena disabled" in
        -- a log is exactly the line someone reads while hunting a bug that is
        -- really a deliberate setting. The spawn sweep below is skipped with
        -- it: with no boundary there is no such thing as a mark outside one.
        return log("arena bounds are OFF (Config.arena.enabled = false) -- the whole map is in play, no out-of-bounds rule is running, and roadblock placement is not clipped to a circle")
    end
    log(("arena ready -- %.0fm planar radius at %.1f, %.1f; warn %.0fs, bust %.0fs"):format(
        Config.arena.radius, Config.arena.center.x, Config.arena.center.y,
        Config.arena.warnSeconds, Config.arena.bustSeconds))
    -- Spawn marks inside the arena is the one property that must hold before
    -- any of the tuning above matters: a match that starts out of bounds warns
    -- both players four seconds in and ends itself at ten.
    --
    -- BOTH tables, and that is the fix. This swept `Config.match.spawns` only,
    -- so `Config.vehicles.spawns` -- a second, independent set of marks that a
    -- vehicle match now genuinely places players on -- was never checked. It is
    -- nil today, which is exactly why the gap was invisible: the moment someone
    -- follows pursuit-v1-duo.md E3 and surveys road spawns, a mark outside the
    -- arena would start matches that bust themselves at 10 s with no startup
    -- warning at all. The table NAME is printed with each mark so a warning
    -- names the file position that has to change.
    local checked, outside = 0, 0
    for _, source in ipairs({ "match.spawns", "vehicles.spawns" }) do
        local spawns = (source == "match.spawns")
            and Config.match.spawns
            or (Config.vehicles and Config.vehicles.spawns)
        for _, pair in ipairs(spawns or {}) do
            for _, role in ipairs({ "runner", "cop" }) do
                local point = pair[role] and pair[role].position
                if point ~= nil then
                    checked = checked + 1
                    local dx = point.x - Config.arena.center.x
                    local dy = point.y - Config.arena.center.y
                    local planar = math.sqrt(dx * dx + dy * dy)
                    if planar > Config.arena.radius then
                        outside = outside + 1
                        log(("arena WARNING -- Config.%s '%s' %s is %.0fm out, OUTSIDE the %.0fm arena"):format(
                            source, tostring(pair.name), role, planar, Config.arena.radius))
                    end
                end
            end
        end
    end
    log(("arena spawn sweep -- %d mark(s) across match.spawns + vehicles.spawns, %d outside"):format(
        checked, outside))
end)
