-- Complete server-authoritative Race engine.

local Config = RaceConfig
local function onFoot(course) return course and course.vehicle == "on_foot" end
local Engine = Config.engine

local players = {}
local queue = {}
local queueDeadlineMs = nil
local queuedCourse = nil
local ballot = nil
local ballotSequence = 0
local revealEndsAtMs = nil
-- Do not fall straight back into the legacy configured course on the first
-- automatic draw after a resource/server restart.
local lastCourseId = Config.selectedCourse
local heat = nil
local heatSequence = 0
local courseVehicles = {}
local editorVehicles = {}
local lastVehicleSeatPollMs = 0
local lastGridHoldCheckMs = 0
local editors = {}
local editorSessionSequence = 0

-- One VM, one owner for life/travel. Freeroam must not respawn or teleport a
-- driver while the submode owns their grid, editor or return transition.
FreeroamRace = {}
function FreeroamRace.ownsPlayer(playerId)
    local record = players[tonumber(playerId)]
    return record ~= nil and (record.returnPosition ~= nil or editors[tonumber(playerId)] ~= nil)
end
function FreeroamRace.isReserved(playerId)
    if FreeroamRace.ownsPlayer(playerId) then return true end
    for _, id in ipairs(queue) do if id == tonumber(playerId) then return true end end
    return false
end

local function nowMs()
    return math.floor(Open77.time.monotonic() * 1000)
end

local function log(text)
    print("[race] " .. tostring(text))
end

local function playerName(playerId)
    return Open77.players.name(playerId) or ("Player " .. tostring(playerId))
end

local function finite(value)
    local number = tonumber(value)
    if number == nil or number ~= number or number == math.huge or number == -math.huge then
        return nil
    end
    return number
end

local function integer(value)
    local number = finite(value)
    if number == nil or number % 1 ~= 0 then return nil end
    return number
end

local function clamp(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
end

local function clone(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local copy = {}
    seen[value] = copy
    for key, child in pairs(value) do copy[clone(key, seen)] = clone(child, seen) end
    return copy
end

local function output(source, raw, success, text)
    log(text)
    if source ~= nil and source > 0 then
        TriggerClientEvent("open77:command:result", source, raw or "", success == true, text)
    end
end

local function notify(playerId, kind, title, message, durationMs)
    if Open77.notifications and Open77.notifications.send then
        Open77.notifications.send(playerId, {
            type = kind or "info",
            title = title or "Race",
            message = message or "",
            durationMs = durationMs or 3500,
        })
    end
    TriggerClientEvent("race:notice", playerId, {
        kind = kind or "info", title = title or "RACE", message = message or "",
        durationMs = durationMs or 3500,
    })
end

local function ensurePlayer(playerId)
    if playerId == nil or playerId <= 0 then return nil end
    local record = players[playerId]
    if record == nil then
        record = {
            state = "freeroam",
            sinceMs = nowMs(),
            graceUntilMs = nowMs() + Config.lobby.placementGraceMs,
        }
        players[playerId] = record
        log(("adopted player %d"):format(playerId))
    end
    return record
end

local function setState(playerId, state)
    local record = ensurePlayer(playerId)
    if record == nil then return end
    record.state = state
    record.sinceMs = nowMs()
    TriggerEvent("race:stateChanged", playerId, state)
end

local function startLinePosition()
    local center, offset = Config.lobby.center, Config.lobby.start.offset
    return { x = center.x + offset.x, y = center.y + offset.y, z = center.z + offset.z }
end

local function placeAt(playerId, position, heading, bucket, reason)
    local life = Open77.players.getLifeState(playerId)
    if life == nil then return false, "player_not_found" end
    if life.phase == "alive" or life.phase == "recovering" then
        local killed, killReason = Open77.players.kill(playerId, {
            cause = "script", weapon = "race:" .. tostring(reason or "place"),
        })
        if not killed then return false, killReason end
    elseif life.phase ~= "dead" then
        return false, "life_transition_in_progress"
    end
    local respawned, respawnReason = Open77.players.respawn(playerId, {
        position = { x = position.x, y = position.y, z = position.z },
        heading = heading or 0.0,
        bucket = bucket or Config.lobby.bucket,
        health = 1.0,
        graceMs = 5000,
    })
    if not respawned then return false, respawnReason end
    local record = players[playerId]
    if record then
        record.graceUntilMs = nowMs() + Config.lobby.placementGraceMs
        record.lastPosition = nil
    end
    return true
end

local function sendLobbyDefinition(playerId)
    TriggerClientEvent("race:lobbyState", playerId, {
        center = Config.lobby.center,
        start = { position = startLinePosition(), radius = Config.lobby.start.radius },
    })
end

-- Return only to an authored point chosen by the server. Keep the incarnation,
-- loadout, lap and clock; suppress swept checkpoint tests until travel settles.
local function returnToPoint(playerId, point, bucket, done)
    local record = players[playerId]
    local life = Open77.players.getLifeState(playerId)
    local position = Open77.players.position(playerId)
    if not record or not point or not point.position then return false, "checkpoint_unavailable" end
    if not life or life.phase ~= "alive" or not position or position.bucket ~= bucket then
        return false, "player_not_ready"
    end
    if record.returningToCheckpoint or nowMs() < (record.nextRecoveryAtMs or 0) then
        return false, "checkpoint_return_pending"
    end
    local pending, reason = Open77.players.teleport(playerId, point.position, {
        heading = point.heading or 0, fade = true, fadeOutMs = 150, fadeInMs = 150,
    })
    if not pending then return false, reason end
    record.returningToCheckpoint = true
    record.lastPosition = nil
    record.nextRecoveryAtMs = nowMs() + 2000
    CreateThread(function()
        local settled, failure = pending:await()
        if players[playerId] ~= record then return end
        record.returningToCheckpoint = nil
        record.lastPosition = nil
        record.graceUntilMs = nowMs() + 500
        if done then done(settled ~= nil, failure) end
    end)
    return true
end

local function protectRacer(playerId, record)
    if record.previousGodMode == nil then
        local health = Open77.players.getHealth(playerId)
        if health == nil then return false end
        record.previousGodMode = health.godMode == true
    end
    return Open77.players.setGodMode(playerId, true) == true
end

local function releaseRaceProtection(playerId, record)
    if record and record.footGrid then
        Open77.players.setFrozen(playerId, false)
        record.footGrid = nil
    end
    if record == nil or record.previousGodMode == nil then return end
    local ok, reason = Open77.players.setGodMode(playerId, record.previousGodMode)
    if ok then record.previousGodMode = nil
    else log(("god mode restore failed for %d: %s"):format(playerId, tostring(reason))) end
end

local function sendToLobby(playerId, reason, retainedState, attempt)
    local record = ensurePlayer(playerId)
    if record == nil then return false end
    local destination = record.returnPosition
    -- Opening Race, joining the server and browsing never move a player.
    if destination == nil then
        releaseRaceProtection(playerId, record)
        setState(playerId, retainedState or "freeroam")
        sendLobbyDefinition(playerId)
        TriggerClientEvent("race:courseClear", playerId)
        return true
    end
    local ok, failure = placeAt(playerId, destination, destination.heading,
        destination.bucket, reason or "return_to_freeroam")
    if ok then
        releaseRaceProtection(playerId, record)
        record.returnPosition = nil
        record.returnRetryScheduled = nil
        setState(playerId, retainedState or "freeroam")
        sendLobbyDefinition(playerId)
        TriggerClientEvent("race:courseClear", playerId)
        log(("player %d returned to Freeroam"):format(playerId))
    else
        attempt = (attempt or 0) + 1
        log(("Freeroam return pending for %d (attempt %d): %s"):format(
            playerId, attempt, tostring(failure)))
        if not record.returnRetryScheduled and attempt < 10 then
            record.returnRetryScheduled = true
            SetTimeout(500, function()
                record.returnRetryScheduled = nil
                if players[playerId] == record and record.returnPosition == destination and
                    Open77.players.name(playerId) ~= nil then
                    sendToLobby(playerId, reason, retainedState, attempt)
                end
            end)
        elseif attempt >= 10 then
            notify(playerId, "error", "RETURN PENDING",
                "Could not return to Freeroam yet. Use /race.leave to retry.", 6000)
        end
    end
    return ok
end

local function moveToLobbyKeepingState(playerId, reason)
    local record = players[playerId]
    local previous = record and record.state
    -- Keep DNF in the heat's classification, including a delayed return.
    return sendToLobby(playerId, reason, previous)
end

local function rememberReturn(playerId)
    local position = Open77.players.position(playerId)
    if position == nil then return false end
    local record = ensurePlayer(playerId)
    if record.returnPosition == nil then
        local life = Open77.players.getLifeState(playerId)
        record.returnPosition = {
            x = position.x, y = position.y, z = position.z,
            bucket = position.bucket or Config.lobby.bucket,
            heading = position.heading or (life and life.heading) or 0,
        }
    end
    return true
end

local function entryFailure(playerId)
    if FreeroamPvp and FreeroamPvp.isReserved(playerId) then return "leave_pvp_first" end
    if editors[playerId] ~= nil then return "close_editor_first" end
    if FreeroamRace.ownsPlayer(playerId) then return "activity_in_progress" end
    local life = Open77.players.getLifeState(playerId)
    if not Open77.ready.isReady(playerId) or life == nil or life.phase ~= "alive" then
        return "player_not_ready"
    end
    local position = Open77.players.position(playerId)
    if position == nil or position.bucket ~= Config.lobby.bucket then return "not_in_freeroam" end
    return nil
end

local function queueIndex(playerId)
    for index, id in ipairs(queue) do
        if id == playerId then return index end
    end
    return nil
end

local function removeFromQueue(playerId)
    if ballot then ballot.votes[playerId] = nil end
    local removed = false
    for index = #queue, 1, -1 do
        if queue[index] == playerId then
            table.remove(queue, index)
            removed = true
        end
    end
    if #queue < Engine.minRacers then
        queueDeadlineMs = nil
        revealEndsAtMs = nil
        if #queue == 0 then ballot, queuedCourse = nil, nil
        elseif ballot and not ballot.open then
            ballotSequence = ballotSequence + 1
            ballot.id, ballot.open = ballotSequence, true
            ballot.winnerId, ballot.resultReason = nil, nil
        end
    end
    return removed
end

local function courseSummary(course)
    if course == nil then return nil end
    return RaceCourses.summary(course)
end

local function courseCapacity(course)
    return RaceCourses.capacity(course)
end

local function chooseNextCourse(mode)
    local first = queue[1] and players[queue[1]]
    mode = mode or (queuedCourse and (onFoot(queuedCourse) and "foot" or "vehicle"))
        or (first and first.menuMode) or "vehicle"
    ballot, revealEndsAtMs = nil, nil
    local override = RaceCourses.hasOverride(mode)
    local course = override and RaceCourses.next(lastCourseId, mode)
        or (Engine.randomCourseEachHeat == false and RaceCourses.selected(mode) or RaceCourses.next(lastCourseId, mode))
    if not course or override or Engine.randomCourseEachHeat == false or
        (Engine.voting or {}).enabled == false then return course end
    local available = RaceCourses.list(mode)
    -- Shuffle without replacement. A two-course catalogue still offers both.
    for i = #available, 2, -1 do
        local j = math.random(i)
        available[i], available[j] = available[j], available[i]
    end
    local candidates = {}
    for i = 1, math.min(#available, math.max(1, math.min(6,
        tonumber((Engine.voting or {}).candidateCount) or 3))) do
        candidates[#candidates + 1] = available[i]
    end
    ballotSequence = ballotSequence + 1
    ballot = { id = ballotSequence, candidates = candidates, votes = {}, lastVoteAt = {}, open = true }
    return course
end

local function ballotCounts()
    local counts, total = {}, 0
    if not ballot then return counts, total end
    for _, id in ipairs(queue) do
        local vote = ballot.votes[id]
        if vote and entryFailure(id) == nil then
            counts[vote], total = (counts[vote] or 0) + 1, total + 1
        end
    end
    return counts, total
end

local function resolveBallot()
    if not ballot or not ballot.open then return end
    local counts, total = ballotCounts()
    local best, tied = -1, {}
    for _, candidate in ipairs(ballot.candidates) do
        if RaceCourses.get(candidate.id) then
            local count = counts[candidate.id] or 0
            if count > best then best, tied = count, { candidate.id }
            elseif count == best then tied[#tied + 1] = candidate.id end
        end
    end
    if #tied > 0 then
        queuedCourse = RaceCourses.get(tied[math.random(#tied)])
        ballot.winnerId = queuedCourse.id
    end
    ballot.open = false
    ballot.resultReason = total == 0 and "random" or (#tied > 1 and "tie" or "votes")
    ballot.finalCounts, ballot.finalTotal = counts, total
end

local function ballotState()
    if not ballot then return nil end
    local counts, total = ballotCounts()
    if not ballot.open then counts, total = ballot.finalCounts, ballot.finalTotal end
    local options = {}
    for _, course in ipairs(ballot.candidates) do
        local option = {}
        for key, value in pairs(course) do option[key] = value end
        option.votes = counts[course.id] or 0
        options[#options + 1] = option
    end
    return { id = ballot.id, open = ballot.open and (queueDeadlineMs == nil or nowMs() < queueDeadlineMs),
        candidates = options, totalVotes = total, eligibleCount = #queue,
        winnerId = ballot.winnerId, resultReason = ballot.resultReason,
        timed = queueDeadlineMs ~= nil, durationMs = Engine.queueGraceSeconds * 1000 }
end

local function queueRoster()
    local result = {}
    for position, id in ipairs(queue) do
        result[#result + 1] = { id = id, name = playerName(id), queuePosition = position,
            ready = entryFailure(id) == nil, voteCourseId = ballot and ballot.votes[id] or nil }
    end
    return result
end

local function memberOfCurrentHeat(playerId)
    if heat == nil then return false end
    for _, id in ipairs(heat.members) do
        if id == playerId then return true end
    end
    return false
end

local function checkpointDistance(playerId, record)
    if heat == nil or record == nil or record.nextCheckpoint == nil then return math.huge end
    local checkpoint = heat.course.checkpoints[record.nextCheckpoint]
    local position = Open77.players.position(playerId)
    if checkpoint == nil or position == nil or position.bucket ~= heat.bucket then return math.huge end
    local dx = position.x - checkpoint.position.x
    local dy = position.y - checkpoint.position.y
    local dz = position.z - checkpoint.position.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function rankingRows()
    if heat == nil then return {} end
    local ranked = {}
    local finishPlace = {}
    for place, id in ipairs(heat.finishOrder) do finishPlace[id] = place end
    for grid, playerId in ipairs(heat.members) do
        local record = players[playerId]
        if record ~= nil then
            local category = 2
            if record.state == "finished" then category = 4
            elseif record.state == "racing" then category = 3
            elseif record.state == "countdown" or record.state == "grid" then category = 2
            elseif record.state == "dnf" or record.state == "disconnected" then category = 1 end
            local distance = checkpointDistance(playerId, record)
            ranked[#ranked + 1] = {
                id = playerId,
                name = playerName(playerId),
                state = record.state,
                category = category,
                grid = grid,
                finishPlace = finishPlace[playerId],
                lap = record.lap or 1,
                laps = heat.course.laps,
                checkpointIndex = record.nextCheckpoint or 1,
                totalCheckpoints = #heat.course.checkpoints,
                progress = record.completedCheckpoints or 0,
                progressTotal = #heat.course.checkpoints * heat.course.laps,
                distance = distance,
                finishMs = record.finishedAtMs and (record.finishedAtMs - heat.startedAtMs) or nil,
                bestLapMs = record.bestLapMs,
                lastLapMs = record.lastLapMs,
                connected = Open77.players.name(playerId) ~= nil,
                vehicleReady = record.vehicleReady == true,
            }
        end
    end
    table.sort(ranked, function(left, right)
        if left.category ~= right.category then return left.category > right.category end
        if left.finishPlace ~= right.finishPlace then
            if left.finishPlace == nil then return false end
            if right.finishPlace == nil then return true end
            return left.finishPlace < right.finishPlace
        end
        if left.progress ~= right.progress then return left.progress > right.progress end
        if left.distance ~= right.distance then return left.distance < right.distance end
        return left.grid < right.grid
    end)
    for rank, row in ipairs(ranked) do
        row.rank = rank
        row.category = nil
        row.grid = nil
        if row.distance == math.huge then row.distance = nil end
    end
    return ranked
end

-- One ranking, one course list and one storage snapshot per batch push.
--
-- stateFor() is per recipient, but rows, courses and storage are identical for
-- every recipient of the same push. Pushing N states used to compute them N
-- times: with 30 players that is 900 position lookups and 30 sorts per push,
-- and thirty disconnects in one tick -- each pushing every state -- blew the
-- resource's instruction quota (measured 2026-09-03, 30 probes leaving at
-- once). Inside a batch the shared parts are computed once and reused; outside
-- a batch they are computed fresh, exactly as before.
local sharedState = nil

local function sharedRows()
    if sharedState == nil then return rankingRows() end
    if sharedState.rows == nil then sharedState.rows = rankingRows() end
    return sharedState.rows
end

local function sharedCourses()
    if sharedState == nil then return RaceCourses.list() end
    if sharedState.courses == nil then sharedState.courses = RaceCourses.list() end
    return sharedState.courses
end

local function sharedStorage()
    if sharedState == nil then return RaceCourses.storageState() end
    if sharedState.storage == nil then sharedState.storage = RaceCourses.storageState() end
    return sharedState.storage
end

-- The selected course and the two course summaries are the same for every
-- player in a flush, and each costs a pass over the course's checkpoints
-- (`RaceCourses.selected` returns a deep copy). Built per player, they made
-- one flush cost ~8,000 Lua instructions per player: at ~110 players a single
-- pass exceeded the resource's instruction budget and the scheduler dropped
-- the loop running it, which stopped Race for the rest of the resource's life.
local function sharedSelected(mode)
    if sharedState == nil then return RaceCourses.selected(mode) end
    sharedState.selected = sharedState.selected or {}
    local cached = sharedState.selected[mode]
    if cached == nil then
        cached = { course = RaceCourses.selected(mode) }
        sharedState.selected[mode] = cached
    end
    return cached.course
end

-- Keyed by table identity: the cached selection above, the queued course and
-- the heat's course all stay the same tables for the whole flush. Summaries
-- are only serialized afterwards, never modified.
local function sharedSummary(course)
    if course == nil then return nil end
    if sharedState == nil then return courseSummary(course) end
    sharedState.summaries = sharedState.summaries or {}
    local summary = sharedState.summaries[course]
    if summary == nil then
        summary = courseSummary(course)
        sharedState.summaries[course] = summary
    end
    return summary
end

local function stateFor(playerId)
    local now = nowMs()
    local record = ensurePlayer(playerId)
    local mode = record.menuMode or "vehicle"
    local selected = queuedCourse or sharedSelected(mode)
    local phase = "waiting"
    local remainingMs = 0
    local elapsedMs = 0
    local rows = {}
    local activeCourse = selected
    local result = nil
    local finishWindowActive = false
    local gridLoadActive = false
    if heat ~= nil then
        phase = heat.phase
        activeCourse = heat.course
        if phase == "grid" then
            gridLoadActive = now < (heat.gridLoadEndsAtMs or 0)
            remainingMs = gridLoadActive
                and math.max(0, heat.gridLoadEndsAtMs - now)
                or math.max(0, heat.gridEndsAtMs - now)
        elseif phase == "countdown" then
            remainingMs = math.max(0, heat.countdownEndsAtMs - now)
        elseif phase == "active" then
            local activeDeadline = heat.finishEndsAtMs or heat.endsAtMs
            remainingMs = math.max(0, activeDeadline - now)
            elapsedMs = math.max(0, now - heat.startedAtMs)
            finishWindowActive = heat.finishEndsAtMs ~= nil
        elseif phase == "results" then
            remainingMs = math.max(0, heat.resultsEndsAtMs - now)
            local startedAt = heat.startedAtMs or heat.resolvedAtMs
            elapsedMs = heat.resolvedAtMs and startedAt and
                math.max(0, heat.resolvedAtMs - startedAt) or 0
            result = heat.result
        end
        rows = sharedRows()
    elseif revealEndsAtMs ~= nil then
        phase = "reveal"
        remainingMs = math.max(0, revealEndsAtMs - now)
    elseif queueDeadlineMs ~= nil then
        phase = "forming"
        remainingMs = math.max(0, queueDeadlineMs - now)
    end

    local position = queueIndex(playerId)
    local participant = memberOfCurrentHeat(playerId) and record.returnPosition ~= nil
    if sharedState and sharedState.roster == nil then
        sharedState.roster, sharedState.ballot = queueRoster(), ballotState()
    end
    local payload = {
        mode = mode,
        onFoot = onFoot(activeCourse) == true,
        phase = phase,
        playerId = playerId,
        playerState = record.state,
        participant = participant,
        queued = position ~= nil,
        queuePosition = position,
        queueCount = #queue,
        minimumRacers = Engine.minRacers,
        unlimitedRacers = onFoot(selected) == true,
        maximumRacers = not onFoot(selected) and courseCapacity(selected) or nil,
        queueUnlimited = true,
        nextCourse = sharedSummary(selected),
        nextCourseLocked = queuedCourse ~= nil and (ballot == nil or not ballot.open),
        nextGridAutomatic = onFoot(selected) == true,
        nextGridCapacity = not onFoot(selected) and courseCapacity(selected) or nil,
        participantCount = heat and #heat.members or 0,
        remainingMs = remainingMs,
        elapsedMs = elapsedMs,
        course = sharedSummary(activeCourse),
        courses = sharedCourses(),
        storage = sharedStorage(),
        rows = rows,
        roster = sharedState and sharedState.roster or queueRoster(),
        ballot = sharedState and sharedState.ballot or ballotState(),
        ownVote = ballot and ballot.votes[playerId] or nil,
        result = result,
        finishWindowActive = finishWindowActive,
        gridLoadActive = gridLoadActive,
        randomCourseRotation = Engine.randomCourseEachHeat ~= false,
        courseLocked = heat ~= nil or queuedCourse ~= nil,
        canJoin = entryFailure(playerId) == nil and not memberOfCurrentHeat(playerId) and
            position == nil and selected ~= nil and
            (queuedCourse == nil or onFoot(queuedCourse) == (mode == "foot")) and
            (heat == nil or onFoot(heat.course) == (mode == "foot")),
        canLeaveQueue = position ~= nil,
        canLeaveRace = participant and phase ~= "results",
        canReturnCheckpoint = participant and onFoot(heat.course) and
            phase == "active" and record.state == "racing",
        returningToCheckpoint = record.returningToCheckpoint == true,
    }
    if participant and record ~= nil then
        payload.lap = record.lap or 1
        payload.laps = heat.course.laps
        payload.checkpointIndex = record.nextCheckpoint or #heat.course.checkpoints
        payload.totalCheckpoints = #heat.course.checkpoints
        payload.completedCheckpoints = record.completedCheckpoints or 0
        payload.bestLapMs = record.bestLapMs
        payload.lastLapMs = record.lastLapMs
        if record.vehicleId ~= nil then
            local vehicle = RaceCourses.vehicle(heat.course.vehicle) or Engine.vehicle
            payload.vehicle = {
                id = record.vehicleId,
                preset = heat.course.vehicle,
                record = vehicle.record,
                label = vehicle.label,
                driverSeat = Engine.vehicle.driverSeat,
                ready = record.vehicleReady == true,
            }
        end
        local checkpoint = record.nextCheckpoint and heat.course.checkpoints[record.nextCheckpoint]
        local guidanceEnabled = record.state == "grid" or
            record.state == "countdown" or record.state == "racing"
        if checkpoint ~= nil and guidanceEnabled then
            payload.nextCheckpoint = {
                id = checkpoint.id,
                index = record.nextCheckpoint,
                position = checkpoint.position,
                heading = checkpoint.heading,
                radius = checkpoint.radius or heat.course.checkpointRadius,
            }
        end
    end
    return payload
end

local stateDelivery = RaceStateDelivery.new({
    send = function(playerId, payload)
        return TriggerClientEvent("race:state", playerId, payload)
    end,
    sendLatent = function(playerId, payload)
        return TriggerLatentClientEvent("race:state", playerId, 512 * 1024, payload)
    end,
    latentStatus = function(stream) return Open77.net.latentStatus(stream) end,
})

local idleEligibility = {}

local function pushState(playerId, suppressUnchanged)
    if players[playerId] == nil then return end
    local payload = stateFor(playerId)
    -- These collections are only consumed by the browser. Keep them opaque to
    -- the bounded Lua bridge so a large grid cannot silently drop the state.
    for _, key in ipairs({ "rows", "roster", "courses" }) do
        local cacheKey = key .. "Json"
        if sharedState and sharedState[cacheKey] then payload[key] = sharedState[cacheKey]
        else
            payload[key] = json.encode(payload[key])
            if sharedState then sharedState[cacheKey] = payload[key] end
        end
    end
    local accepted, reason = stateDelivery.send(playerId, payload, json.encode({ payload }), suppressUnchanged ~= true)
    -- An older latent state may still finish after this one. Keep refreshing
    -- until it drains and a current baseline has been admitted afterwards.
    idleEligibility[playerId] = nil
    if accepted and not stateDelivery.hasPending(playerId) then idleEligibility[playerId] = payload.canJoin end
    return accepted, reason
end

-- Every "push everyone" request is coalesced onto the tick.
--
-- Twenty call sites ask for an immediate push of every player's state. Queued
-- on one flag, thirty of them in the same tick cost one push instead of
-- thirty, and the periodic 250 ms push that keeps the countdown timers moving
-- is the same flush with `force`. A flush costs one ranking and one course
-- list thanks to sharedState above.
local statesDirty = false
local stateQueue, statePending = {}, {}
local stateHead, stateTail = 1, 0

local function drainStates()
    -- Bound each scheduler resume. A global roster can be much larger than a
    -- race grid; encoding every spectator in one resume kills the Lua thread.
    sharedState = {}
    local idle = heat == nil and #queue == 0 and queueDeadlineMs == nil and revealEndsAtMs == nil
    for _=1,64 do
        if stateHead > stateTail then break end
        local playerId = stateQueue[stateHead]
        stateQueue[stateHead], stateHead = nil, stateHead + 1
        local complete = statePending[playerId]
        statePending[playerId] = nil
        local record = players[playerId]
        if record and Open77.players.name(playerId) ~= nil then
            local eligible = idle and entryFailure(playerId) == nil
                and sharedSelected(record.menuMode or "vehicle") ~= nil
            if complete or not idle or idleEligibility[playerId] ~= eligible then pushState(playerId, true) end
        end
    end
    sharedState = nil
    if stateHead > stateTail then stateHead, stateTail = 1, 0 end
end

local function flushStates(force)
    if not force and not statesDirty then return end
    -- With no queue, heat or timer, eligibility is the only externally changing
    -- field. Check it before building/encoding thousands of identical payloads.
    -- Explicit requests and dirty shared state still take the complete path.
    local complete = statesDirty
    statesDirty = false
    for playerId in pairs(players) do
        if statePending[playerId] == nil then
            stateTail = stateTail + 1
            stateQueue[stateTail] = playerId
        end
        statePending[playerId] = complete or statePending[playerId] or false
    end
    drainStates()
end

CreateThread(function()
    while true do
        Wait(0)
        if stateHead <= stateTail then drainStates() end
    end
end)

local function pushAllStates()
    statesDirty = true
end

local function sendCourseState(playerId)
    local record = players[playerId]
    -- Classification membership outlives a forfeit. Once back in Freeroam,
    -- requesting the menu must not recreate the old track or its guidance.
    if heat == nil or heat.closing or not memberOfCurrentHeat(playerId) or
        record == nil or record.returnPosition == nil then return end
    TriggerClientEvent("race:courseState", playerId, {
        heatId = heat.id,
        bucket = heat.bucket,
        course = clone(heat.course),
    })
end

local function pushCoursePropDiagnostics(playerId)
    if not Config.debug.verbose then return end
    TriggerClientEvent("race:gateDebug", playerId, {
        model = "personal_native_ring",
        expected = 0,
        created = 0,
        entries = {},
    })
end

local function safeVehicleCall(name, ...)
    local api = Open77 and Open77.vehicles
    if type(api) ~= "table" or type(api[name]) ~= "function" then
        return nil, "vehicles_api_unavailable:" .. tostring(name)
    end
    local ok, result, reason = pcall(api[name], ...)
    if not ok then return nil, tostring(result) end
    if result == nil or result == false then return nil, reason or "rejected" end
    return result, reason
end

local function forgetCourseVehicle(id)
    for index = #courseVehicles, 1, -1 do
        if tostring(courseVehicles[index]) == tostring(id) then
            table.remove(courseVehicles, index)
        end
    end
end

local function removeRaceVehicle(record, why)
    if record == nil or record.vehicleId == nil then return false end
    local id = record.vehicleId
    record.vehicleId = nil
    record.vehicleReady = nil
    record.vehicleAssignmentRetryAtMs = nil
    forgetCourseVehicle(id)
    local removed, reason = safeVehicleCall("remove", id)
    if not removed then
        log(("vehicle %s removal failed (%s): %s"):format(
            tostring(id), tostring(why), tostring(reason)))
        return false
    end
    return true
end

local function clearCourseVehicles(why)
    for index = #courseVehicles, 1, -1 do
        local id = courseVehicles[index]
        local removed, reason = safeVehicleCall("remove", id)
        if not removed then
            log(("vehicle %s cleanup failed (%s): %s"):format(
                tostring(id), tostring(why), tostring(reason)))
        end
        table.remove(courseVehicles, index)
    end
    for _, record in pairs(players) do
        record.vehicleId = nil
        record.vehicleReady = nil
        record.vehicleAssignmentRetryAtMs = nil
    end
end

local function gridHoldFlags()
    local flags = Open77.vehicles.flags
    return flags.frozen
end

local function vehicleFlags(held)
    local flags = Open77 and Open77.vehicles and Open77.vehicles.flags
    if type(flags) ~= "table" then return 0 end
    -- Keep ignition and throttle live while physics is pinned: cutting the
    -- control input until GO loses an already-held accelerator key edge.
    local base = (flags.lightsOn or 0) | (flags.engineOn or 0)
    if held then return base | gridHoldFlags() end
    return base
end

-- One authority for the hold: replicated server flags, not a client Lua lock
-- which can be cleared by a native projection/mount refresh. Frozen also
-- rejects driver motion reports, including from a client that ignores its UI.
local function setRaceVehicleHeld(vehicleId, held)
    local snapshot, reason = safeVehicleCall("get", vehicleId)
    if type(snapshot) ~= "table" then return false, reason or "vehicle_unavailable" end
    local mask = gridHoldFlags()
    local flags = snapshot.flags or 0
    local desired = (held and (flags | mask) or (flags & ~mask)) |
        Open77.vehicles.flags.engineOn
    if flags ~= desired then
        local ok, updateReason = safeVehicleCall("update", vehicleId, { flags = desired })
        if not ok then return false, updateReason end
    end
    snapshot = safeVehicleCall("get", vehicleId)
    if type(snapshot) ~= "table" or ((snapshot.flags or 0) & mask) ~= (held and mask or 0) then
        return false, "grid_hold_not_applied"
    end
    return true
end

local function scheduleVehicleSettle(heatId, playerId, vehicleId, ground, heading)
    local delay = math.max(0, tonumber(Engine.vehicle.settleAfterMs) or 0)
    SetTimeout(delay, function()
        local record = players[playerId]
        if heat == nil or heat.id ~= heatId or heat.phase ~= "grid" or
            record == nil or record.vehicleId ~= vehicleId then return end

        local snapshot = safeVehicleCall("get", vehicleId)
        if type(snapshot) ~= "table" then
            log(("vehicle %s settle skipped: snapshot unavailable"):format(tostring(vehicleId)))
            return
        end
        local assignment = safeVehicleCall("getPlayerSeat", playerId)
        local driverConfirmed = type(assignment) == "table" and
            tostring(assignment.vehicleId) == tostring(vehicleId) and
            tostring(assignment.seat) == tostring(Engine.vehicle.driverSeat) and
            assignment.forcedEntry ~= true and assignment.entering ~= true
        if driverConfirmed then
            log(("vehicle %s settle skipped: native driver mount already confirmed"):format(
                tostring(vehicleId)))
            return
        end
        local dx = (tonumber(snapshot.x) or ground.x) - ground.x
        local dy = (tonumber(snapshot.y) or ground.y) - ground.y
        local drift = math.sqrt(dx * dx + dy * dy)
        if drift > (tonumber(Engine.vehicle.settleMaxDriftMetres) or 3.0) then
            log(("vehicle %s settle skipped: already moved %.2fm"):format(
                tostring(vehicleId), drift))
            return
        end

        local target = {
            x = ground.x,
            y = ground.y,
            z = ground.z + (tonumber(Engine.vehicle.settledZOffsetMetres) or 0.0),
        }
        local settled, reason = safeVehicleCall("setTransform", vehicleId, {
            position = target,
            yaw = heading,
        })
        if not settled then
            log(("vehicle %s settle failed: %s"):format(tostring(vehicleId), tostring(reason)))
            return
        end
        -- setTransform revokes the physics lease and clears electrical flags.
        setRaceVehicleHeld(vehicleId, true)
        log(("vehicle %s settled on grid z=%.2f after %dms"):format(
            tostring(vehicleId), target.z, delay))
    end)
end

local function spawnRaceVehicle(playerId, position, heading, bucket, course)
    local spec = RaceCourses.vehicle(course and course.vehicle) or Engine.vehicle
    local id, reason = safeVehicleCall("create", {
        record = spec.record,
        position = position,
        yaw = heading,
        bucket = bucket,
        health = 1.0,
        flags = vehicleFlags(true),
        primaryColor = spec.primaryColor,
        secondaryColor = spec.secondaryColor,
    })
    if id == nil then return nil, reason end
    courseVehicles[#courseVehicles + 1] = id
    log(("assigned vehicle %s to player %d at %.2f,%.2f,%.2f"):format(
        tostring(id), playerId, position.x, position.y, position.z))
    return id
end

local function assignRaceDriver(playerId, record, context)
    if record == nil or record.vehicleId == nil then return false, "vehicle_unavailable" end
    local assigned, reason = safeVehicleCall("warpPlayerIntoVehicle",
        playerId, record.vehicleId, Engine.vehicle.driverSeat, {
            moveBucket = true,
            exitLocked = true,
        })
    if not assigned then
        log(("driver assignment failed (%s, player=%d, vehicle=%s): %s"):format(
            tostring(context), playerId, tostring(record.vehicleId), tostring(reason)))
        return false, reason
    end
    record.vehicleReady = false
    log(("driver assignment armed (%s, player=%d, vehicle=%s, exitLocked=true)"):format(
        tostring(context), playerId, tostring(record.vehicleId)))
    return true
end

local function forceRaceDriverExit(playerId, record, context)
    if record == nil or record.vehicleId == nil then return false end
    local assignment = safeVehicleCall("getPlayerSeat", playerId)
    if type(assignment) ~= "table" or
        tostring(assignment.vehicleId) ~= tostring(record.vehicleId) then
        return false
    end
    local forced, reason = safeVehicleCall(
        "forcePlayerOutOfVehicle", playerId, record.vehicleId)
    if not forced then
        log(("forced driver exit failed (%s, player=%d, vehicle=%s): %s"):format(
            tostring(context), playerId, tostring(record.vehicleId), tostring(reason)))
        return false
    end
    log(("forced driver exit armed (%s, player=%d, vehicle=%s)"):format(
        tostring(context), playerId, tostring(record.vehicleId)))
    return true
end

local function removeEditorVehicle(playerId, why)
    local id = editorVehicles[playerId]
    if id == nil then return false end
    editorVehicles[playerId] = nil
    local session = editors[playerId]
    if session ~= nil then session.vehicleId = nil end
    local removed, reason = safeVehicleCall("remove", id)
    if not removed then
        log(("editor vehicle %s removal failed for %d (%s): %s"):format(
            tostring(id), playerId, tostring(why), tostring(reason)))
        return false
    end
    return true
end

local function spawnEditorVehicle(playerId, requestedHeading)
    local session = editors[playerId]
    if session == nil then return nil, "editor_session_required" end
    if onFoot(session.draft) then return nil, "on_foot_course" end
    local origin = Open77.players.position(playerId)
    if origin == nil then return nil, "position_unavailable" end

    local bucket = integer(Config.editor.worldBucket) or 0
    if origin.bucket ~= bucket then
        local moved = Open77.routingBuckets.setPlayer(playerId, bucket)
        if not moved then return nil, "editor_bucket_unavailable" end
        origin.bucket = bucket
    end

    local heading = finite(requestedHeading) or 0.0
    heading = heading % 360.0
    if heading < 0.0 then heading = heading + 360.0 end
    local radians = math.rad(heading)
    local distance = finite(Config.editor.vehicleSpawnDistance) or 4.5
    local ground = {
        x = origin.x - math.sin(radians) * distance,
        y = origin.y + math.cos(radians) * distance,
        z = origin.z,
    }
    local spawn = {
        x = ground.x,
        y = ground.y,
        z = ground.z + (finite(Config.editor.vehicleSpawnLiftMetres) or 0.35),
    }

    removeEditorVehicle(playerId, "replace")
    local spec = RaceCourses.vehicle(session.draft and session.draft.vehicle) or Engine.vehicle
    local id, reason = safeVehicleCall("create", {
        record = spec.record,
        position = spawn,
        yaw = heading,
        bucket = bucket,
        health = 1.0,
        flags = vehicleFlags(),
        primaryColor = spec.primaryColor,
        secondaryColor = spec.secondaryColor,
    })
    if id == nil then return nil, reason end
    editorVehicles[playerId] = id
    session.vehicleId = id

    local settleDelay = math.max(0, integer(Config.editor.vehicleSettleAfterMs) or 1200)
    SetTimeout(settleDelay, function()
        if editorVehicles[playerId] ~= id or editors[playerId] ~= session then return end
        local snapshot = safeVehicleCall("get", id)
        if type(snapshot) ~= "table" then return end
        if type(snapshot.occupants) == "table" and #snapshot.occupants > 0 then return end
        local settled, settleReason = safeVehicleCall("setTransform", id, {
            position = ground,
            yaw = heading,
        })
        if settled then
            safeVehicleCall("update", id, { flags = vehicleFlags() })
        else
            log(("editor vehicle %s settle failed: %s"):format(
                tostring(id), tostring(settleReason)))
        end
    end)

    log(("editor vehicle %s assigned to player %d in bucket %d"):format(
        tostring(id), playerId, bucket))
    return id
end

-- Freeze as soon as the respawn ACK lands, including recovery grace. Equipment
-- readiness and distance validation must not leave a runner free to walk away.
local function holdFootGrid(playerId, record)
    if not heat or not onFoot(heat.course) or not record or not record.footGrid
        or (heat.phase ~= "grid" and heat.phase ~= "countdown")
        or (record.state ~= "grid" and record.state ~= "countdown") then return false end
    local life = Open77.players.getLifeState(playerId)
    if not life or (life.phase ~= "alive" and life.phase ~= "recovering") then return false end
    local position = Open77.players.position(playerId)
    if not position or position.bucket ~= heat.bucket then return false end
    return Open77.players.setFrozen(playerId, true) == true
end

local function playerDrivesAssignedVehicle(playerId, record)
    if heat and onFoot(heat.course) then
        local life = Open77.players.getLifeState(playerId)
        local position = Open77.players.position(playerId)
        local seat = safeVehicleCall("getPlayerSeat", playerId)
        local ready = life and life.phase == "alive" and position and
            position.bucket == heat.bucket and not (seat and seat.vehicleId)
        if heat.phase ~= "active" then
            local held = holdFootGrid(playerId, record)
            ready = ready and held
        end
        if ready and heat.phase ~= "active" and Engine.requireFootLoadout ~= false then
            local implants = Open77.cyberware.effective(playerId)
            local dash = Open77.dash.current(playerId)
            ready = implants and implants.legs and implants.legs.profile == "double_jump"
                and dash and dash.projection and dash.projection.status == "ready"
        end
        if ready and heat.phase ~= "active" and record.footGrid then
            local p = record.footGrid
            ready = (position.x-p.x)^2 + (position.y-p.y)^2 + (position.z-p.z)^2 < 4
        end
        return ready == true, true
    end
    if record == nil or record.vehicleId == nil then return false, false end
    local assignment = safeVehicleCall("getPlayerSeat", playerId)
    if type(assignment) ~= "table" or
        tostring(assignment.vehicleId) ~= tostring(record.vehicleId) or
        tostring(assignment.seat) ~= tostring(Engine.vehicle.driverSeat) then
        return false, false
    end
    if assignment.exitLocked ~= true then
        local locked = safeVehicleCall(
            "setPlayerExitLocked", playerId, true, record.vehicleId)
        if not locked then return false, true end
    end
    local confirmed = assignment.forcedEntry ~= true and assignment.entering ~= true and
        assignment.exiting ~= true and assignment.forcedExit ~= true
    return confirmed, true
end

local function pollGridVehicles(now)
    if now - lastVehicleSeatPollMs < (Engine.vehicleSeatPollMs or 500) then return nil, nil end
    lastVehicleSeatPollMs = now
    local ready, waiting, changed = 0, 0, false
    for _, playerId in ipairs(heat and heat.members or {}) do
        local record = players[playerId]
        if record and record.state == "grid" then
            local seated, assigned = playerDrivesAssignedVehicle(playerId, record)
            if seated then
                ready = ready + 1
                if not record.vehicleReady then
                    record.vehicleReady = true
                    changed = true
                    record.vehicleAssignmentRetryAtMs = nil
                    notify(playerId, "success", onFoot(heat.course) and "RUNNER READY" or "DRIVER READY",
                        "Starting position confirmed. Waiting for the start sequence.", 3000)
                    log(("player %d ready on grid (%s)"):format(
                        playerId, onFoot(heat.course) and "on foot" or tostring(record.vehicleId)))
                end
            else
                if record.vehicleReady then changed = true end
                record.vehicleReady = false
                waiting = waiting + 1
                if not assigned and now >= (record.vehicleAssignmentRetryAtMs or 0) then
                    record.vehicleAssignmentRetryAtMs = now + 1000
                    assignRaceDriver(playerId, record, "grid_retry")
                end
            end
        end
    end
    return ready, waiting, changed
end

local function guardGridVehicles(now)
    if heat == nil or (heat.phase ~= "grid" and heat.phase ~= "countdown") or
        now - lastGridHoldCheckMs < 500 then return end
    lastGridHoldCheckMs = now
    for _, playerId in ipairs(heat.members) do
        local record = players[playerId]
        if record and (record.state == "grid" or record.state == "countdown") then
            if onFoot(heat.course) then
                holdFootGrid(playerId, record)
            else
            local ok, reason = setRaceVehicleHeld(record.vehicleId, true)
            if not ok then
                record.state = "dnf"
                record.dnfReason = "grid_hold_failed"
                record.vehicleReady = false
                removeRaceVehicle(record, "grid_hold_failed")
                log(("grid hold failed player=%d: %s"):format(playerId, tostring(reason)))
                notify(playerId, "error", "GRID FAILED",
                    "Your vehicle could not be held safely on the starting grid.", 5000)
            end
            end
        end
    end
end

local function gridSlot(course, index)
    if onFoot(course) then return RaceStartingGrid.footSlot(course.start, index) end
    local authored = type(course.grid) == "table" and course.grid[index] or nil
    if authored ~= nil then
        return {
            position = clone(authored.position),
            heading = authored.heading or course.start.heading or 0.0,
        }
    end
    local grid = Engine.startGrid
    local lanes = math.max(1, math.floor(grid.lanes))
    local lane = (index - 1) % lanes
    local row = math.floor((index - 1) / lanes)
    local memberCount = heat and #heat.members or 1
    local centeredLane = lane - (math.min(lanes, math.max(1, memberCount)) - 1) * 0.5
    local radians = math.rad(course.start.heading or 0.0)
    -- REDengine yaw 0 faces +Y: forward=(-sin(yaw), cos(yaw)).
    local forwardX, forwardY = -math.sin(radians), math.cos(radians)
    local rightX, rightY = math.cos(radians), math.sin(radians)
    -- Row zero is the surveyed vehicle mark itself.  Only later rows move
    -- backwards; adding a blanket offset moved the first car toward the
    -- walled end of this street and invalidated the measured door position.
    local backward = row * grid.rowSpacing
    return {
        position = {
            x = course.start.position.x - forwardX * backward + rightX * centeredLane * grid.laneSpacing,
            y = course.start.position.y - forwardY * backward + rightY * centeredLane * grid.laneSpacing,
            z = course.start.position.z,
        },
        heading = course.start.heading or 0.0,
    }
end

local function beginGrid(forced)
    if heat ~= nil or #queue == 0 then return false, "queue_empty_or_busy" end
    -- A queued player remains in Freeroam. Recheck immediately before travel:
    -- death, another activity or a bucket change must not be undone by Race.
    for index = #queue, 1, -1 do
        local playerId = queue[index]
        local failure = entryFailure(playerId)
        if failure ~= nil then
            table.remove(queue, index)
            setState(playerId, "freeroam")
            notify(playerId, "info", "QUEUE LEFT", "Race entry cancelled: " .. failure, 4000)
        end
    end
    if #queue == 0 or (not forced and #queue < Engine.minRacers) then
        queueDeadlineMs = nil
        queuedCourse = nil
        ballot, revealEndsAtMs = nil, nil
        pushAllStates()
        return false, "not_enough_racers"
    end
    if not forced and #queue < Engine.minRacers then return false, "not_enough_racers" end
    if queuedCourse == nil then queuedCourse = chooseNextCourse() end
    resolveBallot()
    local course = queuedCourse
    if course == nil or courseCapacity(course) == 0 then return false, "course_unavailable" end

    heatSequence = heatSequence + 1
    local members = {}
    while #queue > 0 and #members < courseCapacity(course) do
        local playerId = table.remove(queue, 1)
        if rememberReturn(playerId) then
            local record = players[playerId]
            if protectRacer(playerId, record) then
                members[#members + 1] = playerId
            else
                releaseRaceProtection(playerId, record)
                record.returnPosition = nil
                setState(playerId, "freeroam")
                notify(playerId, "error", "QUEUE LEFT", "Race protection could not be enabled. Please retry.", 4000)
            end
        else
            setState(playerId, "freeroam")
            notify(playerId, "error", "QUEUE LEFT", "Your return position is unavailable.", 4000)
        end
    end
    queueDeadlineMs = nil
    queuedCourse = nil
    ballot, revealEndsAtMs = nil, nil
    if #members == 0 then pushAllStates(); return false, "return_position_unavailable" end
    lastCourseId = course.id
    -- Overflow keeps its FIFO position; reserve its next course now instead of
    -- borrowing the current heat's (potentially smaller) capacity.
    if #queue > 0 then queuedCourse = chooseNextCourse() end
    local now = nowMs()
    heat = {
        id = heatSequence,
        phase = "grid",
        bucket = Engine.heatBucket,
        course = course,
        members = members,
        finishOrder = {},
        gridLoadEndsAtMs = now + math.floor(
            math.max(0, tonumber(Engine.gridLoadSeconds) or 20.0) * 1000),
        gridEndsAtMs = now + math.floor(math.max(
            tonumber(Engine.gridReadySeconds) or 60.0,
            tonumber(Engine.gridLoadSeconds) or 20.0) * 1000),
        forced = forced == true,
    }

    -- Each client draws its own authoritative target. Shared solo quest gates
    -- cannot represent drivers at different checkpoints and fade independently.
    for gridIndex, playerId in ipairs(members) do
        local record = ensurePlayer(playerId)
        record.lap = 1
        record.nextCheckpoint = 1
        record.completedCheckpoints = 0
        record.lapTimes = {}
        record.bestLapMs = nil
        record.lastLapMs = nil
        record.finishedAtMs = nil
        record.lastCheckpointAtMs = 0
        record.lastCheckpointIndex = nil
        record.lastPosition = nil
        record.vehicleId = nil
        record.vehicleReady = false
        record.vehicleAssignmentRetryAtMs = nil
        setState(playerId, "grid")
        sendCourseState(playerId)
        pushCoursePropDiagnostics(playerId)
        local slot = gridSlot(course, gridIndex)
        if onFoot(course) then
            record.footGrid = clone(slot.position)
            local placed, reason = placeAt(playerId, slot.position, slot.heading, heat.bucket, "foot_grid")
            if not placed then
                record.state, record.dnfReason = "dnf", "placement_failed"
                notify(playerId, "error", "GRID FAILED", tostring(reason), 5000)
            end
        else
        local carGround = slot.position
        local carHeading = slot.heading
        local carPosition = {
            x = carGround.x,
            y = carGround.y,
            -- A frozen chassis cannot settle under gravity. Spawn on its
            -- surveyed mark so releasing GO does not drop the car from a lift.
            z = carGround.z,
        }
        local vehicleId, vehicleReason = spawnRaceVehicle(
            playerId, carPosition, carHeading, heat.bucket, course)
        if vehicleId ~= nil then
            record.vehicleId = vehicleId
            scheduleVehicleSettle(heat.id, playerId, vehicleId, carGround, carHeading)
        end
        local assigned, assignmentReason = false, nil
        if vehicleId ~= nil then
            local held
            held, assignmentReason = setRaceVehicleHeld(vehicleId, true)
            if held then assigned, assignmentReason = assignRaceDriver(playerId, record, "grid") end
        end
        if vehicleId == nil or not assigned then
            if vehicleId ~= nil then removeRaceVehicle(record, "grid_failed") end
            record.state = "dnf"
            record.dnfReason = vehicleId == nil and "vehicle_failed" or "driver_assignment_failed"
            log(("grid setup failed for %d: vehicle=%s assignment=%s"):format(
                playerId, tostring(vehicleReason), tostring(assignmentReason)))
            notify(playerId, "error", "GRID FAILED",
                vehicleId == nil and "Your race vehicle could not be created."
                    or "You could not be assigned to the race vehicle.", 5000)
        else
            notify(playerId, "info", "STARTING GRID",
                "Vehicle held on the grid until GO. Exit remains locked until Race cleanup.", 8000)
        end
        end
    end
    log(("heat %d grid: course=%s racers=%d"):format(
        heat.id, heat.course.id, #heat.members))
    pushAllStates()
    return true
end

local function startCountdown()
    if heat == nil or heat.phase ~= "grid" then return false end
    heat.phase = "countdown"
    heat.countdownEndsAtMs = nowMs() + math.floor(Engine.countdownSeconds * 1000)
    for _, playerId in ipairs(heat.members) do
        local record = players[playerId]
        if record and record.state == "grid" and record.vehicleReady then
            setState(playerId, "countdown")
        end
    end
    log(("heat %d countdown: every participant is ready"):format(heat.id))
    pushAllStates()
    return true
end

local function maybeArmQueue()
    if FreeroamRace.playtestHold then return end
    if heat ~= nil or revealEndsAtMs ~= nil or #queue < Engine.minRacers then return end
    if queueDeadlineMs == nil then
        queuedCourse = queuedCourse or chooseNextCourse()
        if queuedCourse == nil then
            log("queue could not be armed: no course is available")
            return
        end
        queueDeadlineMs = nowMs() + math.floor(Engine.queueGraceSeconds * 1000)
        log(("queue grace armed for %d racer(s), course=%s, starts in %.1fs"):format(
            #queue, queuedCourse.id, Engine.queueGraceSeconds))
        pushAllStates()
    end
end

local function beginRace()
    if heat == nil or heat.phase ~= "countdown" then return end
    local now = nowMs()
    heat.phase = "active"
    heat.startedAtMs = now
    heat.endsAtMs = now + math.floor(Engine.durationSeconds * 1000)
    for _, playerId in ipairs(heat.members) do
        local record = players[playerId]
        if record and record.state == "countdown" then
            local seated = playerDrivesAssignedVehicle(playerId, record)
            local released, releaseReason = false, nil
            if seated then
                if onFoot(heat.course) then
                    released, releaseReason = Open77.players.setFrozen(playerId, false)
                else
                    released, releaseReason = setRaceVehicleHeld(record.vehicleId, false)
                end
            end
            if seated and released then
                record.vehicleReady = true
                record.state = "racing"
                record.sinceMs = now
                record.lapStartedAtMs = now
                record.graceUntilMs = now
                record.lastPosition = Open77.players.position(playerId)
                TriggerClientEvent("race:go", playerId, { heatId = heat.id })
                if onFoot(heat.course) and Engine.footWeapon and Open77.weapons then
                    -- Draw once the grid freeze is released. Slot 3 is the
                    -- Freeroam melee slot; never change the FFA loadout here.
                    local request, reason = Open77.weapons.assign(playerId, Engine.footWeapon, 3,
                        { active = true, addToInventory = true })
                    if not request then log("Foot race katana unavailable: " .. tostring(reason)) end
                end
            else
                record.vehicleReady = false
                record.state = "dnf"
                record.dnfReason = seated and "grid_release_failed" or "left_driver_seat"
                if seated then log("GO release failed: " .. tostring(releaseReason)) end
                notify(playerId, "error", "DISQUALIFIED",
                    seated and "Your vehicle could not be released safely."
                        or "You must be in your assigned driver seat when the race starts.", 5000)
            end
        end
    end
    log(("heat %d GO"):format(heat.id))
    pushAllStates()
end

local function allMembersResolved()
    if heat == nil then return true end
    for _, playerId in ipairs(heat.members) do
        local record = players[playerId]
        if record and (record.state == "racing" or record.state == "countdown" or
            record.state == "grid") then return false end
    end
    return true
end

local function resolveHeat(reason)
    if heat == nil or heat.phase == "results" then return end
    local now = nowMs()
    for _, playerId in ipairs(heat.members) do
        local record = players[playerId]
        if record and (record.state == "racing" or record.state == "countdown" or
            record.state == "grid") then
            record.state = "dnf"
            record.dnfReason = reason or "timeout"
        end
    end
    heat.phase = "results"
    heat.resolvedAtMs = now
    heat.resultsEndsAtMs = now + math.floor(Engine.resultsSeconds * 1000)
    local winnerId = heat.finishOrder[1]
    heat.result = {
        reason = reason or "finished",
        winnerId = winnerId,
        winnerName = winnerId and playerName(winnerId) or nil,
        finishers = #heat.finishOrder,
    }
    log(("heat %d resolved: %s winner=%s"):format(
        heat.id, tostring(reason), tostring(winnerId)))
    pushAllStates()
end

local function closeHeat()
    if heat == nil or heat.closing then return end
    -- Keep the heat busy through native dismount and cleanup. Otherwise a
    -- forced next start can create cars which this delayed cleanup deletes.
    local closingHeat = heat
    closingHeat.closing = true
    local members = heat.members
    local forcedExit = false
    for _, playerId in ipairs(members) do
        forcedExit = forceRaceDriverExit(
            playerId, players[playerId], "results_complete") or forcedExit
    end
    -- Keep the authoritative car alive while ForcedExit runs. Removing it on
    -- the same frame would bypass the native dismount and make the following
    -- lobby respawn race the stale workspot state.
    CreateThread(function()
        if forcedExit then
            Wait(math.max(0, integer(Engine.vehicle.exitSettleMs) or 1500))
        end
        if heat ~= closingHeat then return end
        clearCourseVehicles("results_complete")
        for _, playerId in ipairs(members) do
            local record = players[playerId]
            if record and Open77.players.name(playerId) ~= nil then
                record.lap = nil
                record.nextCheckpoint = nil
                record.completedCheckpoints = nil
                record.lastPosition = nil
                sendToLobby(playerId, "results_complete")
            end
        end
        heat = nil
        maybeArmQueue()
        pushAllStates()
    end)
end

local function finishPlayer(playerId, record)
    if heat == nil or record.state ~= "racing" then return end
    record.state = "finished"
    record.finishedAtMs = nowMs()
    heat.finishOrder[#heat.finishOrder + 1] = playerId
    record.place = #heat.finishOrder
    TriggerClientEvent("race:finished", playerId, {
        place = record.place,
        timeMs = record.finishedAtMs - heat.startedAtMs,
    })
    notify(playerId, "success", "FINISH",
        ("P%d · %0.3fs"):format(record.place,
            (record.finishedAtMs - heat.startedAtMs) / 1000.0), 5000)
    if allMembersResolved() then
        resolveHeat("finished")
    elseif #heat.finishOrder == 1 then
        heat.finishEndsAtMs = record.finishedAtMs +
            math.floor(Engine.finishGraceSeconds * 1000)
        for _, memberId in ipairs(heat.members) do
            local member = players[memberId]
            if member and member.state == "racing" then
                notify(memberId, "warning", "FINISH WINDOW",
                    ("The leader finished · %.0f seconds remaining."):format(
                        Engine.finishGraceSeconds), 5000)
            end
        end
        log(("heat %d finish window armed by player %d for %.1fs"):format(
            heat.id, playerId, Engine.finishGraceSeconds))
    end
end

local function playCheckpointFirework(checkpoint, bucket)
    local spec = (Config.presentation or {}).checkpointFirework
    if type(spec) ~= "table" or spec.enabled == false then return end
    local position = checkpoint.position
    -- Presentation can fail without interrupting progression, lap handling or
    -- results. No client-supplied effect, position or routing bucket is used.
    local called, played, reason = pcall(Open77.effects.play,
        spec.effect or "race.firework.burst", {
            position = { x = position.x, y = position.y,
                z = position.z + (tonumber(spec.height) or 12.0) },
            bucket = bucket,
            range = tonumber(spec.range) or 180.0,
        })
    if not called or not played then
        log("Checkpoint firework unavailable: " .. tostring(called and reason or played))
    end
end

local function acceptCheckpoint(playerId, record)
    if heat == nil or record.state ~= "racing" then return end
    local now = nowMs()
    if now - (record.lastCheckpointAtMs or 0) < Engine.checkpointDebounceMs then return end
    local index = record.nextCheckpoint
    local count = #heat.course.checkpoints
    if index == nil or heat.course.checkpoints[index] == nil then return end

    record.lastCheckpointAtMs = now
    record.lastCheckpointIndex = index
    record.completedCheckpoints = (record.completedCheckpoints or 0) + 1
    playCheckpointFirework(heat.course.checkpoints[index], heat.bucket)
    local completedLap = index == count
    if completedLap then
        local lapTime = now - (record.lapStartedAtMs or heat.startedAtMs)
        record.lastLapMs = lapTime
        record.lapTimes[#record.lapTimes + 1] = lapTime
        if record.bestLapMs == nil or lapTime < record.bestLapMs then record.bestLapMs = lapTime end
        if record.lap >= heat.course.laps then
            finishPlayer(playerId, record)
        else
            record.lap = record.lap + 1
            record.nextCheckpoint = 1
            record.lapStartedAtMs = now
            TriggerClientEvent("race:lap", playerId, {
                lap = record.lap, laps = heat.course.laps,
                lastLapMs = record.lastLapMs, bestLapMs = record.bestLapMs,
            })
        end
    else
        record.nextCheckpoint = index + 1
    end
    if record.state == "racing" and not completedLap then
        TriggerClientEvent("race:checkpointAccepted", playerId, {
            completed = index,
            next = record.nextCheckpoint,
            lap = record.lap,
            laps = heat.course.laps,
            total = count,
        })
    end
    pushAllStates()
end

local function evaluateCheckpoint(playerId, claimedId)
    if heat == nil or heat.phase ~= "active" then return false end
    local record = players[playerId]
    if record == nil or record.state ~= "racing" or record.returningToCheckpoint or
        nowMs() < (record.graceUntilMs or 0) then
        return false
    end
    if onFoot(heat.course) and not playerDrivesAssignedVehicle(playerId, record) then
        record.state, record.dnfReason = "dnf", "on_foot_required"
        pushAllStates()
        return false
    end
    local checkpoint = heat.course.checkpoints[record.nextCheckpoint]
    if checkpoint == nil or (claimedId ~= nil and tostring(claimedId) ~= checkpoint.id) then
        return false
    end
    local position = Open77.players.position(playerId)
    if position == nil or position.bucket ~= heat.bucket then return false end
    local radius = checkpoint.radius or heat.course.checkpointRadius or Engine.checkpointRadius
    local crossed = RaceCheckpointGeometry.crossed(record.lastPosition, position,
        checkpoint.position, radius, Engine.checkpointZTolerance, Engine.maxSegmentMetres)
    record.lastPosition = {
        x = position.x, y = position.y, z = position.z, bucket = position.bucket,
    }
    if crossed then acceptCheckpoint(playerId, record) end
    return crossed
end

local function joinQueue(playerId, requestedMode)
    local record = ensurePlayer(playerId)
    if record == nil then return false, "player_not_found" end
    local mode = requestedMode == "foot" and "foot" or
        (requestedMode == "vehicle" and "vehicle" or (record.menuMode or "vehicle"))
    record.menuMode = mode
    if heat and onFoot(heat.course) ~= (mode == "foot") then return false, "other_race_in_progress" end
    local failure = entryFailure(playerId)
    if failure then return false, failure end
    if memberOfCurrentHeat(playerId) then return false, "already_racing" end
    if queueIndex(playerId) ~= nil then return false, "already_queued" end
    if queuedCourse and onFoot(queuedCourse) ~= (mode == "foot") then return false, "other_race_queue_in_progress" end
    if queuedCourse == nil then queuedCourse = chooseNextCourse(mode) end
    if queuedCourse == nil then return false, "course_unavailable" end
    queue[#queue + 1] = playerId
    setState(playerId, "queued")
    maybeArmQueue()
    notify(playerId, "success", "RACE", ("Queued · P%d"):format(#queue), 3000)
    pushAllStates()
    return true
end

local function leaveRace(playerId, reason)
    if removeFromQueue(playerId) then
        setState(playerId, "freeroam")
        notify(playerId, "info", "RACE", "Queue left.", 2500)
        pushAllStates()
        return true
    end
    if heat ~= nil and memberOfCurrentHeat(playerId) then
        local record = players[playerId]
        if record and heat.phase ~= "results" then
            record.state = "dnf"
            record.dnfReason = reason or "left"
            local hadVehicle = record.vehicleId ~= nil
            local forcedExit = hadVehicle and
                forceRaceDriverExit(playerId, record, "race_left") or false
            CreateThread(function()
                if forcedExit then
                    Wait(math.max(0, integer(Engine.vehicle.exitSettleMs) or 1500))
                end
                if hadVehicle and players[playerId] == record then
                    removeRaceVehicle(record, "race_left")
                end
                if players[playerId] == record and Open77.players.name(playerId) ~= nil then
                    moveToLobbyKeepingState(playerId, "race_left")
                end
            end)
            if allMembersResolved() then resolveHeat("finished") end
            pushAllStates()
            return true
        end
    end
    local record = players[playerId]
    if record and record.returnPosition and record.vehicleId == nil and editors[playerId] == nil then
        return sendToLobby(playerId, "return_retry")
    end
    return false
end

-- Internal coordinator hooks. No client event can invoke these directly.
function FreeroamRace.preparePlaytest()
    FreeroamRace.playtestHold = true
    local queued = {}; for _, id in ipairs(queue) do queued[#queued + 1] = id end
    for _, id in ipairs(queued) do leaveRace(id, "admin_playtest") end
    if heat then resolveHeat("admin_playtest"); closeHeat() end
end
function FreeroamRace.finishPlaytest()
    FreeroamRace.playtestHold = false
    maybeArmQueue()
    pushAllStates()
end
function FreeroamRace.canPlaytest(mode)
    return chooseNextCourse(mode) ~= nil
end
function FreeroamRace.isEditing(id) return editors[id] ~= nil end
FreeroamRace.joinPlaytest = joinQueue

-- --------------------------------------------------------------- editor --

local function blankDraft(mode)
    return {
        name = mode == "foot" and "New Night City Foot Race" or "New Night City Race",
        description = "",
        type = "circuit",
        laps = mode == "foot" and 1 or 3,
        checkpointRadius = mode == "foot" and 3.0 or Engine.checkpointRadius,
        vehicle = mode == "foot" and "on_foot" or Engine.vehicle.id,
        start = nil,
        grid = {},
        checkpoints = {},
    }
end

local editorErrorMessages = {
    position_unavailable = "Your current position is not available yet.",
    editor_world_required = "Return to the editor world before placing a point.",
    grid_slots_overlap = "This grid slot is too close to another slot.",
    too_many_checkpoints = "This course already has the maximum number of checkpoints.",
    invalid_checkpoint_index = "That checkpoint no longer exists.",
    invalid_grid_index = "That grid slot no longer exists.",
    course_not_found = "That course no longer exists.",
    heat_in_progress = "Wait for the current heat to finish before selecting this course.",
    invalid_vehicle = "Choose one of the race vehicles allowed by the server.",
    unknown_action = "The editor did not recognize that action.",
}

local function editorErrorMessage(errorCode)
    local code = tostring(errorCode or "editor_error")
    if editorErrorMessages[code] ~= nil then return editorErrorMessages[code] end
    if code:match("^vehicle_spawn_failed:") then
        return "The editor vehicle could not be spawned (" ..
            code:sub(#"vehicle_spawn_failed:" + 1) .. ")."
    end
    return code:gsub("_", " ")
end

local function notifyEditor(playerId, kind, message, durationMs)
    if Open77.notifications and Open77.notifications.send then
        Open77.notifications.send(playerId, {
            id = "race_editor_feedback_" .. tostring(playerId),
            replace = true,
            type = kind or "info",
            title = "COURSE EDITOR",
            message = message,
            icon = "CP",
            durationMs = durationMs or 2400,
        })
    end
    TriggerClientEvent("race:notice", playerId, {
        kind = kind or "info", title = "COURSE EDITOR", message = message,
    })
end

local function closeEditorSession(playerId, reason, returnToLobby)
    local session = editors[playerId]
    if session == nil then return false end
    removeEditorVehicle(playerId, reason or "editor_closed")
    editors[playerId] = nil
    TriggerClientEvent("race:editorState", playerId, {
        open = false,
        error = reason == "session_expired" and reason or nil,
    })
    if returnToLobby and Open77.players.name(playerId) ~= nil then
        sendToLobby(playerId, reason or "editor_closed")
        notify(playerId, "info", "COURSE EDITOR",
            reason == "session_expired" and "Editor session expired."
                or "Editor closed. Returning to Freeroam.", 3500)
    end
    pushAllStates()
    return true
end

local function editorValid(playerId)
    local session = editors[playerId]
    if session == nil then return nil end
    if nowMs() > session.expiresAtMs then
        closeEditorSession(playerId, "session_expired", true)
        return nil
    end
    return session
end

local function pushEditor(playerId, message, errorCode, notificationKind)
    local session = editors[playerId]
    TriggerClientEvent("race:editorState", playerId, {
        open = session ~= nil,
        sessionId = session and session.id or nil,
        vehicleId = session and session.vehicleId or nil,
        mode = session and "drive" or nil,
        draft = session and clone(session.draft) or nil,
        vehicles = RaceCourses.vehicles(),
        courses = RaceCourses.list(),
        storage = RaceCourses.storageState(),
        message = message,
        error = errorCode,
    })
    if errorCode ~= nil then
        local friendly = editorErrorMessage(errorCode)
        notifyEditor(playerId, "error", friendly, 3500)
        log(("editor action failed for player %d: %s"):format(playerId, tostring(errorCode)))
    elseif type(message) == "string" and message ~= "" then
        notifyEditor(playerId, notificationKind or "info", message, 2400)
        log(("editor feedback for player %d: %s"):format(playerId, message))
    end
end

local function headingFrom(payload)
    local heading = type(payload) == "table" and finite(payload.heading) or nil
    if heading == nil then return 0.0 end
    heading = heading % 360.0
    if heading < 0.0 then heading = heading + 360.0 end
    return heading
end

-- Capturing while driving should author the vehicle mark, not the driver's
-- seated puppet offset. Both sources remain server-owned: occupancy comes from
-- the canonical vehicle ledger and the transform from its replicated snapshot.
-- On foot (or while the seat transition is still pending) we fall back to the
-- authenticated player position.
local function editorCapturePoint(playerId, session, payload)
    local worldBucket = integer(Config.editor.worldBucket) or 0
    if session.vehicleId ~= nil then
        local vehicle = safeVehicleCall("get", session.vehicleId)
        if type(vehicle) == "table" and vehicle.bucket == worldBucket and
            finite(vehicle.x) ~= nil and finite(vehicle.y) ~= nil and finite(vehicle.z) ~= nil and
            type(vehicle.occupants) == "table" then
            for _, occupant in ipairs(vehicle.occupants) do
                if tonumber(occupant.playerId) == playerId and
                    occupant.seat == Engine.vehicle.driverSeat then
                    return {
                        position = {
                            x = finite(vehicle.x), y = finite(vehicle.y), z = finite(vehicle.z),
                        },
                        heading = headingFrom(payload),
                    }, "editor vehicle"
                end
            end
        end
    end

    local position = Open77.players.position(playerId)
    if position == nil then return nil, "position_unavailable" end
    if position.bucket ~= worldBucket then return nil, "editor_world_required" end
    return {
        position = { x = position.x, y = position.y, z = position.z },
        heading = headingFrom(payload),
    }, "player"
end

local function loadDraft(id)
    local course = RaceCourses.get(id)
    if course == nil then return nil, "course_not_found" end
    if course.builtin then
        course.id = nil
        course.builtin = false
        course.name = "Copy of " .. course.name
        course.revision = nil
    end
    return course
end

RegisterNetEvent("race:editorAction", function(payload)
    local playerId = source
    local session = editorValid(playerId)
    if session == nil or type(payload) ~= "table" or type(payload.action) ~= "string" then return end
    session.expiresAtMs = nowMs() + Config.editor.sessionMinutes * 60000
    local action = payload.action

    if action == "returnCheckpoint" then
        if not onFoot(session.draft) then return end
        local draft = session.draft
        local point = draft.checkpoints[#draft.checkpoints] or draft.start
        local ok, reason = returnToPoint(playerId, point, integer(Config.editor.worldBucket) or 0,
            function(settled, failure)
                if editors[playerId] ~= session then return end
                pushEditor(playerId, settled and "Returned to last captured point." or nil,
                    not settled and tostring(failure) or nil)
            end)
        if not ok then pushEditor(playerId, nil, reason) end
        return
    elseif action == "spawnVehicle" then
        if onFoot(session.draft) then return pushEditor(playerId, "On-foot editor: walk to each point.") end
        local id, reason = spawnEditorVehicle(playerId, headingFrom(payload))
        if id == nil then return pushEditor(playerId, nil, "vehicle_spawn_failed:" .. tostring(reason)) end
        return pushEditor(playerId, "Editor vehicle ready. Enter it with F.")
    elseif action == "new" then
        session.draft = blankDraft(onFoot(session.draft) and "foot" or "vehicle")
        return pushEditor(playerId, "New course ready.")
    elseif action == "load" then
        local draft, reason = loadDraft(payload.id)
        if draft == nil then return pushEditor(playerId, nil, reason) end
        session.draft = draft
        if onFoot(draft) then removeEditorVehicle(playerId, "foot_course") end
        return pushEditor(playerId, "Course loaded.")
    elseif action == "fields" then
        local draft = session.draft
        local previousVehicle = draft.vehicle
        if type(payload.name) == "string" then draft.name = payload.name end
        if type(payload.description) == "string" then draft.description = payload.description end
        if payload.type == "circuit" or payload.type == "sprint" then draft.type = payload.type end
        local laps = integer(payload.laps)
        if laps ~= nil then draft.laps = clamp(laps, Config.editor.minimumLaps, Config.editor.maximumLaps) end
        if draft.type == "sprint" then draft.laps = 1 end
        local radius = finite(payload.checkpointRadius)
        if radius ~= nil then
            draft.checkpointRadius = clamp(radius,
                Config.editor.minimumRadius, Config.editor.maximumRadius)
        end
        if payload.vehicle ~= nil then
            local vehicle = RaceCourses.vehicle(payload.vehicle)
            if vehicle == nil or vehicle.id ~= tostring(payload.vehicle) then
                return pushEditor(playerId, nil, "invalid_vehicle")
            end
            draft.vehicle = vehicle.id
        end
        if draft.vehicle ~= previousVehicle then
            if onFoot(draft) then
                removeEditorVehicle(playerId, "foot_course")
                return pushEditor(playerId, "On-foot course. Walk to capture spawns and checkpoints.")
            end
            local vehicle = RaceCourses.vehicle(draft.vehicle)
            return pushEditor(playerId,
                ("Race vehicle set to %s. Press F4 to preview it."):format(vehicle.label),
                nil, "success")
        end
        return pushEditor(playerId)
    elseif action == "captureStart" or action == "captureGrid" or action == "addCheckpoint" then
        local point, captureSource = editorCapturePoint(playerId, session, payload)
        if point == nil then return pushEditor(playerId, nil, captureSource) end
        if action == "captureStart" then
            session.draft.start = point
            return pushEditor(playerId, "Start captured from " .. captureSource .. ".", nil, "success")
        end
        if action == "captureGrid" then
            if onFoot(session.draft) then
                return pushEditor(playerId, "Automatic grid: F6 sets the start and direction for every runner.")
            end
            local grid = session.draft.grid
            if type(grid) ~= "table" then grid = {}; session.draft.grid = grid end
            local spacing = Config.editor.minimumGridSpacing or 2.75
            for _, slot in ipairs(grid) do
                local dx = point.position.x - slot.position.x
                local dy = point.position.y - slot.position.y
                local dz = point.position.z - slot.position.z
                if math.sqrt(dx * dx + dy * dy + dz * dz) < spacing then
                    return pushEditor(playerId, nil, "grid_slots_overlap")
                end
            end
            grid[#grid + 1] = point
            return pushEditor(playerId, ("Grid slot %d captured from %s."):format(
                #grid, captureSource), nil, "success")
        end
        if #session.draft.checkpoints >= Config.editor.maximumCheckpoints then
            return pushEditor(playerId, nil, "too_many_checkpoints")
        end
        session.draft.checkpoints[#session.draft.checkpoints + 1] = point
        return pushEditor(playerId,
            ("Checkpoint %d captured from %s."):format(
                #session.draft.checkpoints, captureSource), nil, "success")
    elseif action == "removeCheckpoint" then
        local index = integer(payload.index)
        if index == nil or index < 1 or index > #session.draft.checkpoints then
            return pushEditor(playerId, nil, "invalid_checkpoint_index")
        end
        table.remove(session.draft.checkpoints, index)
        return pushEditor(playerId, "Checkpoint removed.", nil, "warning")
    elseif action == "undo" then
        if #session.draft.checkpoints > 0 then table.remove(session.draft.checkpoints) end
        return pushEditor(playerId, "Last checkpoint removed.", nil, "warning")
    elseif action == "removeGridSlot" then
        local grid = type(session.draft.grid) == "table" and session.draft.grid or {}
        local index = integer(payload.index)
        if index == nil or index < 1 or index > #grid then
            return pushEditor(playerId, nil, "invalid_grid_index")
        end
        table.remove(grid, index)
        return pushEditor(playerId, "Grid slot removed.", nil, "warning")
    elseif action == "undoGrid" then
        local grid = type(session.draft.grid) == "table" and session.draft.grid or {}
        if #grid > 0 then table.remove(grid) end
        return pushEditor(playerId, "Last grid slot removed.", nil, "warning")
    elseif action == "save" then
        local saved, saveError = RaceCourses.save(playerId, session.draft)
        if saved == nil then return pushEditor(playerId, nil, saveError) end
        session.draft = saved
        pushEditor(playerId, "Course saved to its JSON file.", nil, "success")
        pushAllStates()
        return
    elseif action == "delete" then
        local ok, reason = RaceCourses.remove(payload.id)
        if not ok then return pushEditor(playerId, nil, reason) end
        if session.draft and session.draft.id == payload.id then
            session.draft = blankDraft(onFoot(session.draft) and "foot" or "vehicle")
        end
        pushEditor(playerId, "Course deleted.", nil, "warning")
        pushAllStates()
        return
    elseif action == "select" then
        if heat ~= nil and heat.phase ~= "results" then
            return pushEditor(playerId, nil, "heat_in_progress")
        end
        local ok, reason = RaceCourses.select(payload.id)
        if not ok then return pushEditor(playerId, nil, reason) end
        if queuedCourse ~= nil or queueDeadlineMs ~= nil then queuedCourse = chooseNextCourse() end
        pushEditor(playerId, "Selected for the next heat.", nil, "success")
        pushAllStates()
        return
    elseif action == "close" then
        closeEditorSession(playerId, "editor_closed", true)
        return
    end
    pushEditor(playerId, nil, "unknown_action")
end)

-- --------------------------------------------------------------- events --

RegisterNetEvent("race:ready", function()
    local playerId = source
    local record = ensurePlayer(playerId)
    if not Open77.ready.isReady(playerId) then
        record.awaitingReady = true
        log(("player %d announced but is not ready yet; deferring Race availability"):format(
            playerId))
        return
    end
    record.awaitingReady = nil
    local editor = editorValid(playerId)
    if editor ~= nil then
        Open77.routingBuckets.setPlayer(playerId, integer(Config.editor.worldBucket) or 0)
        setState(playerId, "editing")
        pushEditor(playerId, "Drive mode restored.")
        TriggerClientEvent("race:courseClear", playerId)
        TriggerClientEvent("race:panel", playerId, false)
        if editor.vehicleId == nil and not onFoot(editor.draft) then
            TriggerClientEvent("race:editorRequestVehicle", playerId)
        end
        pushState(playerId)
        return
    end
    -- A repeated ready event must never pull an active driver off the track.
    sendLobbyDefinition(playerId)
    pushState(playerId)
end)

RegisterNetEvent("race:requestState", function()
    local playerId = source
    ensurePlayer(playerId)
    local editor = editorValid(playerId)
    if editor ~= nil then
        pushEditor(playerId)
        TriggerClientEvent("race:courseClear", playerId)
        TriggerClientEvent("race:panel", playerId, false)
        pushState(playerId)
        return
    end
    sendLobbyDefinition(playerId)
    sendCourseState(playerId)
    pushState(playerId)
end)

RegisterNetEvent("race:openPanel", function(mode)
    local playerId = source
    ensurePlayer(playerId).menuMode = mode == "foot" and "foot" or "vehicle"
    TriggerClientEvent("race:panel", playerId, true)
    pushState(playerId)
end)

RegisterNetEvent("race:join", function(mode)
    local ok, reason = joinQueue(source, mode)
    if not ok then notify(source, "error", "RACE", tostring(reason), 3500) end
end)

RegisterNetEvent("race:vote", function(payload)
    local playerId, now = source, nowMs()
    if type(payload) ~= "table" or not ballot or not ballot.open or
        payload.ballotId ~= ballot.id or type(payload.courseId) ~= "string" or
        queueIndex(playerId) == nil or entryFailure(playerId) ~= nil or
        (queueDeadlineMs ~= nil and now >= queueDeadlineMs) then return end
    if now - (ballot.lastVoteAt[playerId] or -10000) <
        (tonumber((Engine.voting or {}).cooldownMs) or 250) then return end
    for _, candidate in ipairs(ballot.candidates) do
        if candidate.id == payload.courseId then
            ballot.votes[playerId], ballot.lastVoteAt[playerId] = candidate.id, now
            pushAllStates()
            return
        end
    end
end)

RegisterNetEvent("race:leave", function(reason)
    if not leaveRace(source, tostring(reason or "left")) then
        notify(source, "warning", "RACE", "You are not queued or racing.", 3000)
    end
end)

RegisterNetEvent("race:checkpointIntent", function(checkpointId)
    evaluateCheckpoint(source, checkpointId)
end)

RegisterNetEvent("race:returnCheckpoint", function()
    local playerId, currentHeat = source, heat
    local record = players[playerId]
    if not currentHeat or currentHeat.phase ~= "active" or not onFoot(currentHeat.course) or
        not memberOfCurrentHeat(playerId) or not record or record.state ~= "racing" then return end
    local point = record.lastCheckpointIndex and currentHeat.course.checkpoints[record.lastCheckpointIndex]
        or currentHeat.course.start
    local ok, reason = returnToPoint(playerId, point, currentHeat.bucket, function(settled, failure)
        if heat ~= currentHeat or record.state ~= "racing" then return end
        notify(playerId, settled and "info" or "warning", "FOOT RACE",
            settled and "Returned to checkpoint. The clock keeps running." or
                "Checkpoint return failed: " .. tostring(failure), 3000)
        pushState(playerId)
    end)
    if not ok then notify(playerId, "warning", "FOOT RACE", tostring(reason), 2500) end
    pushState(playerId)
end)

-- Native lethal falls can still report a death despite server damage immunity.
-- Keep the course, lap and timer, and revive at the last validated checkpoint.
AddEventHandler("onPlayerLifeStateChanged", function(value)
    local playerId = tonumber(value)
    local currentHeat, record = heat, players[playerId]
    if currentHeat and onFoot(currentHeat.course) and record
        and (record.state == "grid" or record.state == "countdown") then
        holdFootGrid(playerId, record)
        return
    end
    if not currentHeat or currentHeat.phase ~= "active"
        or not onFoot(currentHeat.course) or not record or record.state ~= "racing"
        or not memberOfCurrentHeat(playerId) or record.footDeathRecovery then return end
    local currentLife = Open77.players.getLifeState(playerId)
    if not currentLife or currentLife.phase ~= "dead" then return end
    record.footDeathRecovery = true
    SetTimeout(500, function()
        record.footDeathRecovery = nil
        if players[playerId] ~= record or heat ~= currentHeat or heat.phase ~= "active"
            or record.state ~= "racing" or not memberOfCurrentHeat(playerId) then return end
        local life = Open77.players.getLifeState(playerId)
        if not life or life.phase ~= "dead" then return end
        local point = record.lastCheckpointIndex and currentHeat.course.checkpoints[record.lastCheckpointIndex]
            or currentHeat.course.start
        local ok, reason = placeAt(playerId, point.position, point.heading or 0,
            currentHeat.bucket, "foot_checkpoint_recovery")
        if ok then
            protectRacer(playerId, record)
            record.lastPosition = nil
            notify(playerId, "info", "FOOT RACE", "Returned to checkpoint. The clock keeps running.", 3000)
        else
            log(("foot checkpoint recovery failed player=%d reason=%s"):format(playerId, tostring(reason)))
        end
        pushState(playerId)
    end)
end)

AddEventHandler("onPlayerConnected", function(playerIdStr)
    local playerId = tonumber(playerIdStr)
    if playerId == nil or playerId <= 0 then return end
    local record = ensurePlayer(playerId)
    if Open77.ready.isReady(playerId) then
        sendLobbyDefinition(playerId)
        pushState(playerId)
    else
        record.awaitingReady = true
        log(("player %d connected; waiting for gameplay readiness"):format(playerId))
    end
end)

AddEventHandler("onPlayerReady", function(playerIdStr)
    local playerId = tonumber(playerIdStr)
    if playerId == nil or players[playerId] == nil then return end
    if players[playerId].awaitingReady then
        players[playerId].awaitingReady = nil
        log(("player %d gate opened; Race available in Freeroam"):format(playerId))
        sendLobbyDefinition(playerId)
        pushState(playerId)
    end
end)

AddEventHandler("onPlayerDisconnected", function(playerIdStr)
    local playerId = tonumber(playerIdStr)
    if playerId == nil then return end
    stateDelivery.forget(playerId)
    idleEligibility[playerId] = nil
    releaseRaceProtection(playerId, players[playerId])
    removeFromQueue(playerId)
    removeEditorVehicle(playerId, "disconnect")
    editors[playerId] = nil
    if heat ~= nil and memberOfCurrentHeat(playerId) then
        local record = players[playerId]
        if record then
            removeRaceVehicle(record, "disconnect")
            record.state, record.dnfReason = "disconnected", "disconnect"
        end
        if allMembersResolved() then resolveHeat("finished") end
    end
    players[playerId] = nil
    pushAllStates()
end)

AddEventHandler("race:coursesChanged", function(reason)
    -- Do not let a removed/edited candidate remain on an active ballot. A new
    -- generation invalidates in-flight clicks and gives everyone a fresh window.
    if reason ~= "selected" and #queue > 0 then
        queuedCourse = chooseNextCourse()
        if queueDeadlineMs then queueDeadlineMs = nowMs() + Engine.queueGraceSeconds * 1000 end
    end
    for playerId in pairs(editors) do pushEditor(playerId) end
    pushAllStates()
end)

-- --------------------------------------------------------------- ticks --

CreateThread(function()
    while true do
        Wait(Engine.positionTickMs)
        local now = nowMs()
        local expiredEditors = {}
        for playerId, session in pairs(editors) do
            if now > session.expiresAtMs then expiredEditors[#expiredEditors + 1] = playerId end
        end
        for _, playerId in ipairs(expiredEditors) do
            closeEditorSession(playerId, "session_expired", true)
        end
        -- Reassert protection through grid/countdown/racing/results and delayed
        -- dismount/return, without granting it to people merely queued in town.
        for playerId, record in pairs(players) do
            if record.previousGodMode ~= nil then
                if record.returnPosition ~= nil then protectRacer(playerId, record)
                else releaseRaceProtection(playerId, record) end
            end
        end
        guardGridVehicles(now)
        if heat == nil then
            if revealEndsAtMs ~= nil then
                if now >= revealEndsAtMs then beginGrid(false) end
            elseif queueDeadlineMs ~= nil and now >= queueDeadlineMs then
                if ballot and ballot.open then
                    resolveBallot()
                    revealEndsAtMs = now + math.max(0, tonumber((Engine.voting or {}).revealSeconds) or 4) * 1000
                    pushAllStates()
                else beginGrid(false) end
            end
        elseif heat.phase == "grid" then
            local ready, waiting, readinessChanged = pollGridVehicles(now)
            if ready ~= nil then
                local loadingComplete = now >= (heat.gridLoadEndsAtMs or 0)
                if ready > 0 and waiting == 0 and loadingComplete then
                    startCountdown()
                elseif ready == 0 and waiting == 0 then
                    heat.startedAtMs = now
                    resolveHeat("grid_setup_failed")
                elseif now >= heat.gridEndsAtMs then
                    for _, playerId in ipairs(heat.members) do
                        local record = players[playerId]
                        if record and record.state == "grid" and not record.vehicleReady then
                            record.state = "dnf"
                            record.dnfReason = "grid_timeout"
                            removeRaceVehicle(record, "grid_timeout")
                            notify(playerId, "error", "GRID TIMEOUT",
                                "Driver seat was not confirmed in time.", 5000)
                        end
                    end
                    if ready > 0 then
                        startCountdown()
                    else
                        heat.startedAtMs = now
                        resolveHeat("grid_timeout")
                    end
                end
                if readinessChanged and heat ~= nil and heat.phase == "grid" then
                    pushAllStates()
                end
            end
        elseif heat.phase == "countdown" and now >= heat.countdownEndsAtMs then
            beginRace()
        elseif heat.phase == "active" then
            for _, playerId in ipairs(heat.members) do evaluateCheckpoint(playerId) end
            if heat ~= nil and heat.phase == "active" and allMembersResolved() then
                resolveHeat("no_active_drivers")
            elseif heat ~= nil and heat.phase == "active" and heat.finishEndsAtMs ~= nil and
                now >= heat.finishEndsAtMs then
                resolveHeat("finish_window_expired")
            elseif heat ~= nil and heat.phase == "active" and now >= heat.endsAtMs then
                resolveHeat("timeout")
            end
        elseif heat.phase == "results" and now >= heat.resultsEndsAtMs then
            closeHeat()
        end
        -- Deliver whatever this tick (or the events before it) marked dirty, at
        -- most once per tick and with the shared parts computed once.
        flushStates(false)
    end
end)

CreateThread(function()
    while true do
        Wait(Engine.stateTickMs)
        -- Timers (countdown, remaining time) move even when nothing else does.
        flushStates(true)
    end
end)

-- ------------------------------------------------------------- commands --

local CHAT_SUGGESTIONS = {
    { command = "/race", help = "Open Freeroam's Race activity and course catalogue." },
    { command = "/race.join", help = "Join the next Race heat." },
    { command = "/race.leave", help = "Leave the Race queue or forfeit the heat." },
    { command = "/race.status", help = "Show Race server state." },
    { command = "/race.course.list", help = "List available courses." },
    { command = "/race.editor", help = "Open the gated course editor (admin)." },
}

RegisterNetEvent("chat:ready", function()
    TriggerClientEvent("chat:addSuggestions", source, CHAT_SUGGESTIONS)
end)

RegisterCommand("race", function(source)
    if source <= 0 then return output(source, "race", false, "race must be used in-game") end
    ensurePlayer(source).menuMode = "vehicle"
    TriggerClientEvent("race:panel", source, true)
    pushState(source)
end, false)

RegisterCommand("footrace", function(source)
    if source <= 0 then return end
    ensurePlayer(source).menuMode = "foot"
    TriggerClientEvent("race:panel", source, true)
    pushState(source)
end, false)

RegisterCommand("race.join", function(source, _, raw)
    if source <= 0 then return output(source, raw, false, "race.join must be used in-game") end
    local ok, reason = joinQueue(source)
    output(source, raw, ok, ok and "joined the Race queue" or ("join failed: " .. tostring(reason)))
end, false)

RegisterCommand("race.leave", function(source, _, raw)
    if source <= 0 then return output(source, raw, false, "race.leave must be used in-game") end
    local ok = leaveRace(source, "command")
    output(source, raw, ok, ok and "left Race" or "not queued or racing")
end, false)

RegisterCommand("race.status", function(source, _, raw)
    local selected = heat and heat.course or queuedCourse or RaceCourses.selected()
    local heatText = heat and ("%s#%d racers=%d"):format(heat.phase, heat.id, #heat.members) or "none"
    output(source, raw, true, ("queue=%d grace=%s heat=%s course=%s courses=%d"):format(
        #queue, tostring(queueDeadlineMs ~= nil), heatText,
        selected and selected.id or "none", #RaceCourses.list()))
end, false)

RegisterCommand("race.course.list", function(source, _, raw)
    local parts = {}
    for _, course in ipairs(RaceCourses.list()) do
        parts[#parts + 1] = ("%s%s [%s, %d lap(s), %d cp]"):format(
            course.selected and "*" or "", course.id, course.type,
            course.laps, course.checkpointCount)
    end
    output(source, raw, true, #parts > 0 and table.concat(parts, " | ") or "no courses")
end, false)

RegisterCommand("race.course.select", function(source, args, raw)
    if args.n ~= 1 then return output(source, raw, false, "usage: race.course.select <id>") end
    if heat ~= nil and heat.phase ~= "results" then
        return output(source, raw, false, "a heat is in progress")
    end
    local ok, reason = RaceCourses.select(args[1])
    if ok and (queuedCourse ~= nil or queueDeadlineMs ~= nil) then queuedCourse = chooseNextCourse() end
    output(source, raw, ok, ok and ("selected course " .. args[1]) or tostring(reason))
    if ok then pushAllStates() end
end, true)

RegisterCommand("race.force", function(source, _, raw)
    if heat ~= nil then return output(source, raw, false, "a heat is already in progress") end
    local ok, reason = beginGrid(true)
    output(source, raw, ok, ok and "Race heat forced" or tostring(reason))
end, true)

RegisterCommand("race.editor", function(source, args, raw)
    if source <= 0 then return output(source, raw, false, "race.editor must be used in-game") end
    if FreeroamPvp and FreeroamPvp.isReserved(source) then
        return output(source, raw, false, "leave PvP or its queue before editing")
    end
    if heat ~= nil and memberOfCurrentHeat(source) then
        return output(source, raw, false, "leave the active heat before editing")
    end
    local foot = args[1] == "--foot"
    local draft = blankDraft(foot and "foot" or "vehicle")
    if args.n >= 1 and not foot then
        local loaded, reason = loadDraft(args[1])
        if loaded == nil then return output(source, raw, false, tostring(reason)) end
        draft = loaded
    end
    local position = Open77.players.position(source)
    if position == nil then return output(source, raw, false, "position unavailable") end
    local life = Open77.players.getLifeState(source)
    if not Open77.ready.isReady(source) or life == nil or life.phase ~= "alive" then
        return output(source, raw, false, "player not ready")
    end
    if FreeroamRace.ownsPlayer(source) and editors[source] == nil then
        return output(source, raw, false, "return to Freeroam before editing")
    end
    local wasEditing = editors[source] ~= nil
    if not rememberReturn(source) then return output(source, raw, false, "return position unavailable") end
    local bucket = integer(Config.editor.worldBucket) or 0
    if not Open77.routingBuckets.setPlayer(source, bucket) then
        if not wasEditing then players[source].returnPosition = nil end
        return output(source, raw, false, "editor world unavailable")
    end
    removeFromQueue(source)
    removeEditorVehicle(source, "editor_reopened")
    editorSessionSequence = editorSessionSequence + 1
    editors[source] = {
        id = editorSessionSequence,
        draft = draft,
        expiresAtMs = nowMs() + Config.editor.sessionMinutes * 60000,
    }
    local record = ensurePlayer(source)
    record.lastPosition = nil
    setState(source, "editing")
    record.menuMode = onFoot(draft) and "foot" or "vehicle"
    pushEditor(source, onFoot(draft) and "Capture the start facing the route, then checkpoints. Runners line up behind you."
        or "Drive mode active. Use the mapped editor keys in the HUD.")
    TriggerClientEvent("race:courseClear", source)
    TriggerClientEvent("race:panel", source, false)
    if not onFoot(draft) then TriggerClientEvent("race:editorRequestVehicle", source) end
    pushState(source)
    output(source, raw, true, "Race drive editor enabled")
end, true)

RegisterCommand("race.where", function(source, args, raw)
    local playerId = tonumber(args and args[1]) or source
    if playerId == nil or playerId <= 0 then return output(source, raw, false, "usage: race.where [id]") end
    local position = Open77.players.position(playerId)
    local record = players[playerId]
    if position == nil then return output(source, raw, false, "position unavailable") end
    output(source, raw, true, ("player=%d state=%s pos=%.2f,%.2f,%.2f bucket=%s lap=%s next=%s"):format(
        playerId, record and record.state or "unknown", position.x, position.y, position.z,
        tostring(position.bucket), tostring(record and record.lap),
        tostring(record and record.nextCheckpoint)))
end, false)

RegisterCommand("race.probe", function(source, args, raw)
    if source <= 0 or args.n < 3 then
        return output(source, raw, false, "usage: race.probe <x> <y> <z> [heading]")
    end
    local x, y, z = finite(args[1]), finite(args[2]), finite(args[3])
    local heading = finite(args[4]) or 0.0
    if x == nil or y == nil or z == nil then return output(source, raw, false, "invalid coordinates") end
    ensurePlayer(source)
    local ok, reason = placeAt(source, { x = x, y = y, z = z }, heading,
        Config.lobby.bucket, "probe")
    output(source, raw, ok, ok and ("probing %.2f, %.2f, %.2f"):format(x, y, z) or tostring(reason))
end, true)

AddEventHandler("onResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    log(("Freeroam Race ready; %d authored course(s), Freeroam bucket=%d"):format(
        #RaceCourses.list(), Config.lobby.bucket))
end)

AddEventHandler("onResourceStop", function(name)
    if name ~= GetCurrentResourceName() then return end
    stateDelivery.clear()
    for playerId, record in pairs(players) do releaseRaceProtection(playerId, record) end
    clearCourseVehicles("resource_stop")
    local owners = {}
    for playerId in pairs(editorVehicles) do owners[#owners + 1] = playerId end
    for _, playerId in ipairs(owners) do removeEditorVehicle(playerId, "resource_stop") end
end)
