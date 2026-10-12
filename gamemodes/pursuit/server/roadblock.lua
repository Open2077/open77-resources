-- Pursuit -- roadblocks.
--
-- Design §5.5 item 5: "The cop banks one roadblock per 60 s. Spending it makes
-- the server spawn two vehicles and NPCs roughly 200 m along the runner's
-- current heading."
--
-- This is the cop's only active ability, and the only thing in the mode that
-- spends a bankable resource rather than driving skill. It is also the only
-- mechanic that requires the server to guess where someone is GOING rather than
-- where he is, which is the interesting part.
--
-- ------------------------------------------------------------------------
-- DERIVING A HEADING FROM A POSITION STREAM
-- ------------------------------------------------------------------------
--
-- `Open77.players.position` returns `{ x, y, z, bucket }`. There is no facing,
-- no velocity, and no server-side orientation of any kind -- so "the runner's
-- current heading" has to be differenced out of two samples, which brings three
-- traps worth naming:
--
--   * a stationary runner produces a difference of pure replication jitter,
--     and normalising jitter yields a confident direction that is nonsense.
--     `headingMinMeters` is the guard: below it, there is NO heading, and
--     `headingFromVector` returns nil rather than 0 degrees.
--   * a single sample pair taken across a respawn or a bucket transfer spans a
--     teleport. Samples from a different bucket are discarded outright.
--   * "no heading" must not silently become "due north". When the runner has
--     not moved, the fallback is the cop->runner bearing -- he is presumably
--     fleeing away from the cop, which is a guess, but a MOTIVATED guess, and
--     it is logged as a fallback so a roadblock in a strange place can be
--     explained afterwards.
--
-- Everything spawned here is an authoritative server entity in the match's own
-- bucket, and every one of them is removed on resolve, on disconnect, on its
-- own lifetime expiry, and by an orphan sweeper. A leaked NCPD Cortes is a bug.

local Config = PursuitConfig

local function log(text) Pursuit.log(text) end
local function nowMs() return Pursuit.nowMs() end

-- matchId -> { blocks = { { vehicles = {ids}, npcs = {ids}, atMs, position } } }
local deployments = {}

-- ------------------------------------------------------------------ safety --

-- Same reasoning as server/vehicles.lua: a missing `world.vehicles` or
-- `world.npcs` permission may surface as a nil table, a raised error, or a
-- `nil, reason` return, and none of those may take down the tick thread. A
-- match without roadblocks is still a match.
local function safeCall(namespace, name, ...)
    local api = Open77 and Open77[namespace]
    if type(api) ~= "table" or type(api[name]) ~= "function" then
        return nil, ("%s_api_unavailable:%s"):format(namespace, name)
    end
    local ok, result, reason = pcall(api[name], ...)
    if not ok then return nil, tostring(result) end
    if result == nil then return nil, reason or "rejected" end
    return result, reason
end

local function vehicleFlags(spec)
    local flags = Open77 and Open77.vehicles and Open77.vehicles.flags
    if type(flags) ~= "table" then return nil end
    local mask = 0
    if spec.lightsOn then mask = mask | (flags.lightsOn or 0) end
    if spec.sirenOn then mask = mask | (flags.sirenOn or 0) end
    -- Locked, unlike the match cars: a blockade is scenery, and a runner who
    -- can commandeer an NCPD Cortes mid-chase has found a better car than the
    -- one the mode gave him.
    mask = mask | (flags.locked or 0)
    -- Immortal so the blockade cannot be shot out of the way. It is an
    -- obstacle; driving round it is the intended answer.
    mask = mask | (flags.immortal or 0)
    if mask == 0 then return nil end
    return mask
end

-- ----------------------------------------------------------------- heading --

-- Per-match sampling state on `match.roadblock`:
--   charge, chargedAtMs         the bank
--   sample = { x, y, z, atMs }  the older of the two position samples
--   heading                     the last GOOD derived heading, in degrees
--   headingAtMs                 when it was derived
--   grade                       recent path gradient, rise/run, always >= 0
--   gradeAtMs, gradeSamples     when, and how many pairs are behind it
local function stateOf(match)
    local state = match.roadblock
    if state == nil then
        state = {
            charge = 0, chargedAtMs = nowMs(), sample = nil,
            heading = nil, headingAtMs = nil,
            grade = nil, gradeAtMs = nil, gradeSamples = 0,
        }
        match.roadblock = state
    end
    return state
end

-- Fold one position reading into the heading AND gradient estimates.
--
-- Called every tick, but only actually differences a pair once they are
-- `headingSampleMs` apart AND `headingMinMeters` apart in the world. Both
-- conditions matter: time alone would difference jitter on a parked car, and
-- distance alone would difference two readings taken 200 ms apart, where the
-- signal-to-noise ratio is at its worst.
--
-- The gradient rides on exactly the same pair, deliberately. It is the same
-- measurement read on a different axis -- rise over run instead of bearing --
-- so it inherits the same guards, and it exists for exactly as long as the
-- heading does. That is the honest coupling: both describe the ground the
-- runner has just crossed, and neither says anything about ground he has not.
local function foldPathSample(match, now)
    local state = stateOf(match)
    if match.runnerId == nil then return end
    local position = Open77.players.position(match.runnerId)
    if position == nil or position.bucket ~= match.bucket then
        -- Do not fold an unreadable or cross-bucket reading in, and do not
        -- discard the pending sample either. Freeze, like every other
        -- accumulator in this gamemode.
        return
    end

    local previous = state.sample
    if previous == nil then
        state.sample = { x = position.x, y = position.y, z = position.z, atMs = now }
        return
    end
    if (now - previous.atMs) < (Config.roadblock.headingSampleMs or 1000) then return end

    local dx = position.x - previous.x
    local dy = position.y - previous.y
    local travelled = math.sqrt(dx * dx + dy * dy)
    if travelled >= (Config.roadblock.headingMinMeters or 4.0) then
        local heading = Pursuit.headingFromVector(dx, dy)
        if heading ~= nil then
            state.heading = heading
            state.headingAtMs = now
        end

        -- Gradient of that same step, as a magnitude: a blockade dropped at the
        -- runner's own z is equally wrong whether the road climbs or falls.
        local dz = math.abs((position.z or 0.0) - (previous.z or 0.0))
        local raw = dz / travelled
        -- Exponential moving average rather than the last reading or the worst
        -- one. The last reading is a single differenced pair and the house rule
        -- is not to decide on one; the worst reading is trivially spiked by
        -- replication jitter, and a single 15 cm blip over a 4 m step reads as
        -- 3.75%. Alpha 0.5 -- a half-life of one sample -- lets a genuine ramp
        -- be believed within two or three steps while capping what any one
        -- reading can do to the estimate at half the gap.
        if state.grade == nil then
            state.grade = raw
        else
            state.grade = state.grade + (raw - state.grade) * 0.5
        end
        state.gradeAtMs = now
        state.gradeSamples = (state.gradeSamples or 0) + 1
    end
    -- Either way the window slides: a runner who stopped should not keep being
    -- differenced against where he was a minute ago.
    state.sample = { x = position.x, y = position.y, z = position.z, atMs = now }
end

-- Age of a timestamped estimate in ms, or nil when there is nothing to age.
local function ageOf(atMs, now)
    if atMs == nil then return nil end
    return math.max(0, now - atMs)
end

-- The direction to place a blockade in, and where that direction came from.
--
-- A heading EXPIRES. `state.headingAtMs` was recorded here and read nowhere,
-- and the consequence was measured offline on 2026-08-26: after 90 s of a
-- runner standing perfectly still the direction was still reported `(measured)`
-- and a blockade was thrown 200 m along a bearing from another part of the
-- match. "The runner's current heading" has to mean current.
--
-- Past `headingMaxAgeMs` the measurement is treated as ABSENT rather than
-- wrong, so control falls through to the same `away_from_cop` fallback a runner
-- who never moved would have got. That fallback is a guess, but it is a guess
-- about the present, which beats a fact about a minute ago.
local function blockDirection(match, now)
    local state = stateOf(match)
    now = now or nowMs()

    local maxAge = Config.roadblock.headingMaxAgeMs or 6000
    local age = ageOf(state.headingAtMs, now)
    if state.heading ~= nil and age ~= nil and age <= maxAge then
        return Pursuit.forwardFromHeading(state.heading), state.heading, "measured", age
    end
    if state.heading ~= nil then
        log(("match %d: last measured heading %.0f deg is %s old (max %.1fs); ignoring it"):format(
            match.id, state.heading,
            age and ("%.1fs"):format(age / 1000) or "of unknown age",
            maxAge / 1000))
    end

    -- Fallback: away from the cop. A guess, but a motivated one -- and named
    -- as a fallback in the log so a blockade in an odd place can be explained.
    local cop = match.copId and Open77.players.position(match.copId)
    local runner = match.runnerId and Open77.players.position(match.runnerId)
    if cop ~= nil and runner ~= nil and cop.bucket == match.bucket and
        runner.bucket == match.bucket then
        local heading = Pursuit.headingFromVector(runner.x - cop.x, runner.y - cop.y)
        if heading ~= nil then
            return Pursuit.forwardFromHeading(heading), heading, "away_from_cop", nil
        end
    end
    return nil, nil, "unknown", nil
end

-- The gradient of the runner's recent path, or nil when the server has no
-- business claiming one.
--
-- Three ways to have nothing to say, and they are all "unknown", never "flat":
-- too few differenced pairs behind the average, an average older than
-- `gradeMaxAgeMs`, or no average at all. Absence of evidence is not evidence of
-- level ground -- so the CALLER contains an unknown gradient on the worst case
-- it would still accept (`maxGradePercent`) rather than letting it through.
--
-- Note the standing consequence: a heading, and therefore a gradient, only
-- exists above `headingMinMeters / headingSampleMs` = 4 m/s. A walk is ~1.5 m/s
-- and a jog ~3.5, so ON FOOT this returns nil essentially always, and the
-- assumed-gradient bound is therefore the normal on-foot case rather than an
-- edge one.
local function gradeEstimate(match, now)
    local state = stateOf(match)
    if state.grade == nil then return nil, nil, 0, "no_samples" end
    if (state.gradeSamples or 0) < (Config.roadblock.gradeMinSamples or 3) then
        return nil, nil, state.gradeSamples or 0, "too_few_samples"
    end
    local age = ageOf(state.gradeAtMs, now)
    if age == nil or age > (Config.roadblock.gradeMaxAgeMs or 6000) then
        return nil, age, state.gradeSamples or 0, "stale"
    end
    return state.grade, age, state.gradeSamples, "ok"
end

-- ---------------------------------------------------------------- containment --

-- Where along the ray `runner + t * direction` the planar arena circle is
-- entered and left, or nil when the ray never meets it at all.
--
-- Closed form, because the whole placement is closed form: the blockade centre
-- travels a ray and the arena is a planar circle, so substituting one into the
-- other gives a quadratic in t whose two roots are the entry and the exit.
-- `direction` is a unit vector (`forwardFromHeading` returns one), which is
-- what lets the quadratic drop its leading coefficient and lets t be read
-- directly as METRES along the heading.
--
-- Both roots are returned signed and unclamped. A negative exit means the whole
-- circle is behind the runner; callers intersect [enter, exit] with their own
-- [minimum, wanted] window and refuse on an empty result. Refusing is the point
-- -- see `deploy`.
local function arenaThrowWindow(runner, direction, limit, centre)
    local px = runner.x - centre.x
    local py = runner.y - centre.y
    local b = px * direction.x + py * direction.y
    local c = px * px + py * py - limit * limit
    local discriminant = b * b - c
    if discriminant < 0 then return nil, nil end
    local root = math.sqrt(discriminant)
    return -b - root, -b + root
end

-- ------------------------------------------------------------------ spawning --

local function removeBlock(block, why)
    local removed = 0
    for _, id in ipairs(block.vehicles or {}) do
        if safeCall("vehicles", "remove", id) then removed = removed + 1 end
    end
    for _, id in ipairs(block.npcs or {}) do
        if safeCall("npcs", "remove", id) then removed = removed + 1 end
    end
    block.vehicles, block.npcs = {}, {}
    block.removedAtMs = nowMs()
    if removed > 0 then
        log(("roadblock cleared: %d entit(ies) removed (%s)"):format(removed, tostring(why)))
    end
    return removed
end

local function clearDeployments(matchId, why)
    local list = deployments[matchId]
    if list == nil then return 0 end
    local removed = 0
    for _, block in ipairs(list) do removed = removed + removeBlock(block, why) end
    deployments[matchId] = nil
    return removed
end

-- Build one blockade: `count` cars abreast across the runner's path, with NPCs
-- standing behind them.
local function deploy(match, forced)
    if not Config.roadblock.enabled then return false, "disabled" end
    if match.runnerId == nil then return false, "no runner" end

    local now = nowMs()
    local cfg = Config.roadblock

    local runner = Open77.players.position(match.runnerId)
    if runner == nil or runner.bucket ~= match.bucket then
        return false, "runner position unreadable"
    end

    local direction, heading, source, headingAge = blockDirection(match, now)
    if direction == nil then
        return false, "no heading yet -- the runner has not moved far enough"
    end

    -- ------------------------------------------------------------ distance --
    --
    -- The throw is a WINDOW, not a number. It opens at `minDistanceMeters` --
    -- never on top of the runner -- and closes at the design's 200 m, and two
    -- rules may narrow it further:
    --
    --   * the gradient of the runner's recent path bounds how far the
    --     `centre.z = runner.z` assumption can be carried before the vertical
    --     error stops being cosmetic;
    --   * the arena bounds where a blockade may legally exist at all.
    --
    -- Whatever survives, the throw goes to the FAR end of the window: as close
    -- to the authored 200 m as the two rules allow. An EMPTY window is a
    -- refusal, and a refusal is the whole reason this is arranged as bounds
    -- rather than as a clamp -- `spendCharge` debits only on success, so the
    -- cop keeps the minute he waited instead of paying it for a blockade in a
    -- place nobody may drive to.
    local minDistance = cfg.minDistanceMeters or 60.0
    local wanted = math.max(minDistance, cfg.distanceMeters or 200.0)
    local lowBound, highBound = minDistance, wanted
    local narrowed = {}

    -- Gradient. `centre.z = runner.z` is the weakest assumption in this file:
    -- there is no ground query on the server and Lua cannot raycast, so the
    -- blockade takes the runner's own altitude however far away it lands. On
    -- the promenade deck -- 11.7%, the only slope ever surveyed here -- that is
    -- 23 m of error over 200 m, seven storeys of empty air. The damage is
    -- bounded rather than removed: shorten until the implied error fits, and
    -- refuse where the ground is too steep for shortening to help.
    local grade, gradeAge, gradeSamples, gradeWhy = gradeEstimate(match, now)
    local gradeNote
    local maxGrade = (cfg.maxGradePercent or 6.0) / 100.0
    if grade ~= nil then
        if grade > maxGrade then
            local detail = ("ground ahead is graded %.1f%% (max %.1f%%) -- too steep to guess an altitude %.0fm away; charge kept"):format(
                grade * 100.0, maxGrade * 100.0, wanted)
            log(("match %d roadblock REFUSED: %s [%d sample(s), %.1fs old]"):format(
                match.id, detail, gradeSamples, (gradeAge or 0) / 1000))
            return false, detail
        end
        if grade > 1e-4 then
            local allowed = (cfg.maxVerticalErrorMeters or 4.0) / grade
            if allowed < highBound then
                highBound = allowed
                narrowed[#narrowed + 1] = ("gradient %.1f%%"):format(grade * 100.0)
            end
        end
        gradeNote = ("%.1f%% over %d sample(s), %.1fs old"):format(
            grade * 100.0, gradeSamples, (gradeAge or 0) / 1000)
    else
        -- UNKNOWN IS NOT FLAT, and it must not be treated as permission.
        --
        -- The rule above shortens the throw so that `centre.z = runner.z` stays
        -- within `maxVerticalErrorMeters` at the measured gradient. With no
        -- measurement the rule cannot evaluate itself -- and for a long time
        -- that meant it evaluated to "throw the whole 200 m", which is the one
        -- answer the evidence cannot support. Measured in play 2026-08-26: a
        -- forced roadblock with `grade=unknown (no_samples)` threw the full
        -- 200 m and landed in a black void, `grounded=no` for 12 s.
        --
        -- The honest substitute is the steepest gradient this rule would still
        -- ACCEPT. It is the worst case consistent with not refusing, it needs
        -- no new constant, and it is continuous with the measured branch: at
        -- exactly `maxGradePercent` the two produce the same bound. On the
        -- authored numbers that is 4.0 / 0.06 = 66.7 m -- still above
        -- `minDistanceMeters`, so an unknown gradient shortens the throw
        -- rather than refusing it, and a blockade still appears.
        --
        -- Refusing outright was the alternative and is wrong: on foot the
        -- gradient is unknown essentially always (a heading needs 4 m/s), so
        -- refusal would delete the mechanic for every on-foot match rather than
        -- contain it.
        local allowed = (cfg.maxVerticalErrorMeters or 4.0) / maxGrade
        if allowed < highBound then
            highBound = allowed
            narrowed[#narrowed + 1] = ("unknown gradient (assumed %.1f%%)"):format(
                maxGrade * 100.0)
        end
        gradeNote = ("unknown (%s, %d sample(s))"):format(tostring(gradeWhy), gradeSamples or 0)
    end

    -- Arena. A blockade outside the playable area is scenery in a forbidden
    -- zone: measured offline 2026-08-26, a runner 640 m from the centre of a
    -- 600 m arena got one 840 m out, 240 m past the boundary, and it cost the
    -- cop his only charge.
    --
    -- SKIPPED ENTIRELY SINCE 2026-08-26, because there is no arena any more:
    -- `Config.arena.enabled` is false on the owner's instruction (the whole map
    -- is in play). This is the one place outside server/bounds.lua that the
    -- boundary reached into, and it is the reason the flag was checked here
    -- from the start rather than assumed -- so removing the arena narrows the
    -- throw window less, and refuses fewer blockades, and breaks nothing.
    --
    -- The containment that actually matters is UNAFFECTED. What keeps a
    -- blockade out of a void is the GRADIENT rule above -- `centre.z` is the
    -- runner's own altitude and the throw is shortened until the implied
    -- vertical error fits -- and that rule is about ground, not about
    -- geography. It runs whether or not there is a boundary. What is lost is
    -- only the guarantee that a blockade lands somewhere both players are
    -- ALLOWED to be, and with the whole map allowed, everywhere qualifies.
    if Config.arena ~= nil and Config.arena.enabled then
        local limit = math.max(0.0,
            (Config.arena.radius or 0.0) - (cfg.arenaMarginMeters or 25.0))
        local enter, leave = arenaThrowWindow(runner, direction, limit, Config.arena.center)
        if enter == nil or leave <= 0.0 then
            local detail = "no legal blockade position on that heading -- it leads out of the arena; charge kept"
            log(("match %d roadblock REFUSED: %s"):format(match.id, detail))
            return false, detail
        end
        if leave < highBound then
            highBound = leave
            narrowed[#narrowed + 1] = "arena edge"
        end
        if enter > lowBound then
            -- The runner is already outside the safe band and driving back in;
            -- the nearest legal point ahead of him is where the ray re-enters.
            lowBound = enter
            narrowed[#narrowed + 1] = "arena re-entry"
        end
    end

    if highBound < lowBound then
        local detail = ("no distance between %.0fm and %.0fm satisfies %s; charge kept"):format(
            lowBound, wanted,
            #narrowed > 0 and table.concat(narrowed, " + ") or "the containment rules")
        log(("match %d roadblock REFUSED: %s"):format(match.id, detail))
        return false, detail
    end
    local distance = highBound

    local centre = {
        x = runner.x + direction.x * distance,
        y = runner.y + direction.y * distance,
        -- The runner's own z -- see the gradient bound above, which is what
        -- keeps this from being carried an arbitrary distance. It is still the
        -- weakest assumption in this file and still the first thing to suspect
        -- if a blockade appears in the air or inside the geometry; the bound
        -- limits how wrong it can be, it does not make it right.
        z = runner.z,
    }

    -- Across the path, not along it. `right` of the travel heading is the axis
    -- the cars are spread on; each car is yawed a further 90 degrees so the
    -- blockade presents its flank, which is what makes it a wall rather than a
    -- queue.
    local across = Pursuit.rightFromHeading(heading)
    local spec = Config.roadblock.vehicles
    local block = { vehicles = {}, npcs = {}, atMs = now, position = centre,
                    heading = heading, source = source, forced = forced == true,
                    distance = distance, wanted = wanted, grade = grade,
                    headingAgeMs = headingAge }

    local count = math.max(1, spec.count or 2)
    local carYaw = heading + (spec.yawOffsetDegrees or 90.0)
    for index = 1, count do
        -- Centred spread: 2 cars -> -0.5, +0.5 spacings; 3 -> -1, 0, +1.
        local slot = index - (count + 1) / 2
        local offset = slot * (spec.spacingMeters or 3.6)
        local definition = {
            record = spec.record,
            position = {
                x = centre.x + across.x * offset,
                y = centre.y + across.y * offset,
                z = centre.z,
            },
            yaw = carYaw,
            bucket = match.bucket,
            health = 1.0,
            flags = vehicleFlags(spec),
        }
        local id, reason = safeCall("vehicles", "create", definition)
        if id == nil and spec.fallbackRecord ~= nil and spec.fallbackRecord ~= spec.record then
            definition.record = spec.fallbackRecord
            id, reason = safeCall("vehicles", "create", definition)
        end
        if id == nil then
            log(("match %d roadblock: vehicle %d/%d failed: %s"):format(
                match.id, index, count, tostring(reason)))
        else
            block.vehicles[#block.vehicles + 1] = id
        end
    end

    -- NPCs behind the cars, from the runner's point of view: they are a
    -- silhouette, not a firing line. Frozen and immortal on purpose -- see the
    -- long note on `Config.roadblock.npcs.template`.
    local npcSpec = Config.roadblock.npcs
    local npcCount = math.max(0, npcSpec.count or 0)
    local behind = npcSpec.behindMeters or 2.5
    for index = 1, npcCount do
        local slot = index - (npcCount + 1) / 2
        local offset = slot * (npcSpec.spacingMeters or 2.0)
        local ai = Open77 and Open77.npcs and Open77.npcs.ai
        local damage = Open77 and Open77.npcs and Open77.npcs.damage
        local id, reason = safeCall("npcs", "create", {
            template = npcSpec.template,
            position = {
                x = centre.x + across.x * offset + direction.x * behind,
                y = centre.y + across.y * offset + direction.y * behind,
                z = centre.z,
            },
            -- Facing back down the road, at the oncoming runner.
            yaw = heading + 180.0,
            bucket = match.bucket,
            aiMode = ai and ai.frozen or nil,
            damagePolicy = damage and damage.immortal or nil,
            despawnWhenUnobserved = false,
            persistent = false,
        })
        if id == nil then
            log(("match %d roadblock: npc %d/%d failed: %s"):format(
                match.id, index, npcCount, tostring(reason)))
        else
            block.npcs[#block.npcs + 1] = id
        end
    end

    if #block.vehicles == 0 and #block.npcs == 0 then
        return false, "nothing could be spawned -- check world.vehicles / world.npcs"
    end

    local list = deployments[match.id] or {}
    list[#list + 1] = block
    deployments[match.id] = list

    -- One line carrying every input the placement depended on. A blockade in a
    -- surprising place is then read rather than guessed at: the heading and its
    -- age say whether the direction was current, the gradient note says whether
    -- the altitude was bounded, and `narrowed` says which rule shortened the
    -- throw and by how much.
    log(("match %d roadblock%s: %d vehicle(s) + %d npc(s) at %.1f,%.1f,%.1f, %.0fm of %.0fm along heading %.0f (%s%s) grade=%s%s"):format(
        match.id, forced and " FORCED" or "", #block.vehicles, #block.npcs,
        centre.x, centre.y, centre.z, distance, wanted, heading, source,
        headingAge and (" %.1fs old"):format(headingAge / 1000) or "",
        gradeNote,
        #narrowed > 0 and (" shortened by " .. table.concat(narrowed, " + ")) or ""))

    if match.copId ~= nil then
        Pursuit.notify(match.copId, "success",
            ("Roadblock deployed %.0f m ahead of the target."):format(distance), 5000)
    end
    Pursuit.notify(match.runnerId, "warning", "NCPD roadblock ahead.", 5000)

    return true, ("%.0fm along %.0f deg (%s)%s"):format(distance, heading, source,
        #narrowed > 0 and (", shortened by " .. table.concat(narrowed, " + ")) or "")
end

-- --------------------------------------------------------------------- hooks --

Pursuit.onMatch("tick", function(match, now)
    if not Config.roadblock.enabled then return end
    local state = stateOf(match)

    -- Heading sampling runs from the head start onwards, not from the cop's
    -- release: the runner is moving during the head start and those are the
    -- samples that make his first roadblock land somewhere sensible.
    foldPathSample(match, now)

    -- Bank a charge. The cop cannot stockpile: `maxCharges` is the cap, and the
    -- timer only restarts once a charge has actually been granted, so a cop
    -- sitting at the cap is not silently accruing credit he will get all at
    -- once the moment he spends one.
    local cap = Config.roadblock.maxCharges or 1
    if state.charge < cap then
        if (now - (state.chargedAtMs or now)) >= (Config.roadblock.chargeSeconds or 60) * 1000 then
            state.charge = state.charge + 1
            state.chargedAtMs = now
            if match.copId ~= nil then
                Pursuit.notify(match.copId, "info",
                    "Roadblock available — /pursuit.roadblock", 4000)
            end
            log(("match %d: cop banked a roadblock (%d/%d)"):format(
                match.id, state.charge, cap))
        end
    else
        -- Hold the timer at the cap so the next charge takes a full interval
        -- from the moment one is spent, not from whenever the cap was reached.
        state.chargedAtMs = now
    end

    -- Expire blockades the chase has left behind. A six-minute match would
    -- otherwise accumulate six of them, each one an authoritative entity the
    -- server keeps replicating to nobody.
    local list = deployments[match.id]
    if list ~= nil then
        local lifetime = (Config.roadblock.lifetimeSeconds or 120) * 1000
        for index = #list, 1, -1 do
            local block = list[index]
            if (now - block.atMs) >= lifetime then
                removeBlock(block, "expired")
                table.remove(list, index)
            end
        end
        if #list == 0 then deployments[match.id] = nil end
    end
end)

Pursuit.onMatch("resolved", function(match)
    clearDeployments(match.id, "resolved")
    match.roadblock = nil
end)

-- Second cleanup path, independent of the resolution running to completion.
AddEventHandler("pursuit:playerGone", function(playerId)
    local match = Pursuit.matchOf(playerId)
    if match ~= nil and deployments[match.id] ~= nil then
        clearDeployments(match.id, "disconnect")
    end
end)

-- Third path: the orphan sweeper. `fireHooks` pcalls the resolved hook above,
-- so a bug in it is survivable -- which also makes it silent, and a leaked
-- blockade would sit in a released bucket forever.
CreateThread(function()
    while true do
        Wait(5000)
        for matchId in pairs(deployments) do
            if Pursuit.matches[matchId] == nil then
                log(("orphan roadblock(s) for match %d; sweeping"):format(matchId))
                clearDeployments(matchId, "orphan")
            end
        end
    end
end)

-- ---------------------------------------------------------------- readouts --

Pursuit.describe = Pursuit.describe or {}
Pursuit.describe.roadblock = function(match, now)
    if not Config.roadblock.enabled then return "disabled" end
    local state = match.roadblock
    if state == nil then return "not started" end
    local cap = Config.roadblock.maxCharges or 1
    local list = deployments[match.id] or {}
    local nextIn = math.max(0,
        ((Config.roadblock.chargeSeconds or 60) * 1000) - (now - (state.chargedAtMs or now)))

    -- The heading's AGE, not just its value. A bearing with no age beside it is
    -- how `state.headingAtMs` came to be written and never read; printing the
    -- age is what makes "still (measured) after 90 s of standing still" visible
    -- from `pursuit.match` instead of only in a post-mortem.
    local headingAge = ageOf(state.headingAtMs, now)
    local stale = headingAge ~= nil
        and headingAge > (Config.roadblock.headingMaxAgeMs or 6000)
    local headingText = "none"
    if state.heading ~= nil then
        headingText = ("%.0fdeg/%s%s"):format(state.heading,
            headingAge and ("%.1fs"):format(headingAge / 1000) or "?",
            stale and " STALE" or "")
    end

    local grade, gradeAge, gradeSamples, gradeWhy = gradeEstimate(match, now)
    local gradeText = grade
        and ("%.1f%%/%.1fs/n=%d"):format(grade * 100.0, (gradeAge or 0) / 1000, gradeSamples)
        or ("none(%s)"):format(tostring(gradeWhy))

    return ("charge=%d/%d next=%.0fs heading=%s grade=%s deployed=%d"):format(
        state.charge, cap,
        (state.charge < cap) and (nextIn / 1000) or 0,
        headingText, gradeText, #list)
end

-- ----------------------------------------------------------------- commands --

-- The cop spends his own charge. Issued in-game by the cop himself, which is
-- how a player uses the ability until the HUD grows a button for it -- the net
-- event below is the same code path and is what that button will call.
local function spendCharge(playerId)
    local match = Pursuit.matchOf(playerId)
    if match == nil then return false, "you are not in a match" end
    if match.state ~= "active" then return false, "the match is not active" end
    if match.roles[playerId] ~= "cop" then return false, "only the cop deploys roadblocks" end
    if not match.copReleased then return false, "not until the head start is over" end
    local state = stateOf(match)
    if state.charge < 1 then
        local wait = math.max(0, ((Config.roadblock.chargeSeconds or 60) * 1000)
            - (Pursuit.nowMs() - (state.chargedAtMs or 0))) / 1000
        return false, ("no charge banked (%.0fs)"):format(wait)
    end
    local ok, detail = deploy(match, false)
    if not ok then return false, detail end
    -- Debited only on success. A blockade that could not be spawned -- no
    -- heading yet, a refused record -- must not cost the cop the minute he
    -- waited for it.
    state.charge = state.charge - 1
    state.chargedAtMs = Pursuit.nowMs()
    return true, detail
end

RegisterCommand("pursuit.roadblock", function(source, _, raw)
    if source == nil or source <= 0 then
        return Pursuit.output(source, raw, false, "pursuit.roadblock must be issued in-game")
    end
    local ok, detail = spendCharge(source)
    Pursuit.output(source, raw, ok,
        ok and ("roadblock deployed: " .. tostring(detail)) or tostring(detail))
end, false)

RegisterNetEvent("pursuit:roadblockIntent", function()
    local playerId = source
    if Pursuit.ensurePlayer(playerId) == nil then return end
    local ok, detail = spendCharge(playerId)
    if not ok then
        Pursuit.notify(playerId, "error", tostring(detail), 4000)
    end
end)

-- Test affordance: deploy without spending, and without waiting a minute for
-- the first charge. Same `deploy` as the real path, so nothing is weakened --
-- only the bank is bypassed.
RegisterCommand("pursuit.forceroadblock", function(source, args, raw)
    local wanted = tonumber(args and args[1])
    local deployed = 0
    for matchId, match in pairs(Pursuit.matches) do
        if (wanted == nil or wanted == matchId) and match.state == "active" then
            local ok, detail = deploy(match, true)
            Pursuit.output(source, raw, ok,
                ("match %d: %s"):format(matchId,
                    ok and ("roadblock at " .. tostring(detail)) or tostring(detail)))
            if ok then deployed = deployed + 1 end
        end
    end
    if deployed == 0 then
        Pursuit.output(source, raw, false,
            "no roadblock deployed; usage: pursuit.forceroadblock [matchId]")
    end
end, false)

AddEventHandler("onResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    if not Config.roadblock.enabled then
        return log("roadblocks DISABLED in config")
    end
    log(("roadblocks ready -- 1 per %.0fs (cap %d), %.0fm ahead, %d vehicle(s) + %d npc(s), %.0fs lifetime"):format(
        Config.roadblock.chargeSeconds, Config.roadblock.maxCharges,
        Config.roadblock.distanceMeters,
        Config.roadblock.vehicles.count, Config.roadblock.npcs.count,
        Config.roadblock.lifetimeSeconds))
    -- The two containment rules, stated at startup so a refusal in play is
    -- recognisable rather than surprising. Both refuse WITHOUT spending the
    -- cop's charge.
    local arenaOn = Config.arena ~= nil and Config.arena.enabled
    log(("roadblock containment -- heading expires at %.1fs; throw shortened to keep vertical error <= %.1fm, refused above %.1f%% grade, UNKNOWN grade assumes %.1f%% (=> %.0fm); %s"):format(
        (Config.roadblock.headingMaxAgeMs or 6000) / 1000,
        Config.roadblock.maxVerticalErrorMeters or 4.0,
        Config.roadblock.maxGradePercent or 6.0,
        Config.roadblock.maxGradePercent or 6.0,
        (Config.roadblock.maxVerticalErrorMeters or 4.0) /
            ((Config.roadblock.maxGradePercent or 6.0) / 100.0),
        arenaOn
            and ("kept >= %.0fm inside the arena edge"):format(
                Config.roadblock.arenaMarginMeters or 25.0)
            or "NO arena clip (Config.arena.enabled = false; the gradient rule is the only containment)"))
end)
