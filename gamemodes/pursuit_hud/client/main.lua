-- Pursuit HUD.
--
-- Draws match state and nothing else. It holds no rules, no timers of its own
-- that decide anything, and no authority: every value here arrives from the
-- server through `pursuit:matchState` / `pursuit:queueState`, which are the
-- same events the gamemode already emits.
--
-- The one thing it does compute locally is the *display* of elapsed time,
-- interpolated between server pushes. That is presentation, not truth: the
-- server decides when a match ends, and a HUD that ticked its own clock to zero
-- while the server disagreed would be lying to the player. So the local clock
-- only ever fills the gap between pushes and is re-anchored by every one.

local page
local ready = false

-- The last authoritative snapshot, and when we received it.
local state = {
    visible = false,
    -- idle | queued | countdown | active | intermission | resolved
    phase = "idle",
    role = nil,           -- "cop" | "runner"
    opponentName = nil,
    remainingMs = 0,
    anchoredAt = 0,       -- Open77.time.monotonic() when remainingMs was true
    -- RUNNER ONLY, and not by accident: the server does not send this to a cop
    -- at all (`separationFor` in pursuit/server/match.lua). A live distance
    -- readout is a hot-and-cold meter, and handing one to the hunter deletes
    -- the stale-scanner mechanic the mode is built on.
    separation = nil,
    scannerAgeMs = nil,

    -- A match is a best of N with the roles swapped between rounds.
    round = 1,
    roundCount = 1,
    -- TRUE while the round being played is the sudden-death decider, and on
    -- the intermission card that precedes it. Sent explicitly by the server
    -- because round == roundCount cannot distinguish a decider from an
    -- ordinary last round.
    decider = false,
    nextIsDecider = false,
    scoreSelf = 0,
    scoreOpponent = 0,
    -- "win" | "loss" | "draw", on the final card only. `won` alone cannot say
    -- draw, and a 1-1 match is a real result.
    matchResult = nil,

    -- The bust meter, 0..1, and whether it is currently filling. Shown to BOTH
    -- sides: the cop watches his own progress, the runner watches the thing
    -- that is about to end his round. It is the cop's replacement for the
    -- separation readout he no longer gets, and a better one -- it says whether
    -- he is succeeding rather than how far away something is.
    bustMeter = nil,
    bustClosing = false,
    -- Contact without arrest -- the cop is inside the radius but the arrest
    -- conditions (both cars slow enough) are not met, so the meter bleeds
    -- slowly instead of filling. Worded differently on the bar.
    bustContact = false,
    -- The recipient's OWN stalled engine, remaining ms, after a hard crash.
    -- Self-only by server rule -- the opponent's stall is never sent.
    bustStalled = nil,
    -- The escape meter, 0..1, while an escape attempt is running -- the
    -- runner has crossed `escapeDistance` and the cop has `escapeGraceSeconds`
    -- to pull him back. nil the rest of the time, and the bar belongs to the
    -- bust meter alone.
    escapeProgress = nil,
    -- Whether the attempt is being earned right now (gap held) or clawed back
    -- (cop pulled it under the line). Worded and coloured differently.
    escapeFilling = false,
    -- { distance?, inReach?, side } while the player still has to get into his
    -- car, nil the rest of the time. Nil is the ONLY way this strip goes away,
    -- so it is never made sticky the way `separation` and `scannerAgeMs` are --
    -- see the assignment in the handler below.
    boarding = nil,
    copReleased = true,
    outcome = nil,
    won = nil,
    queuePosition = nil,
    queueTotal = nil,
}

-- Repaint faster than the server pushes, so the countdown reads smoothly. This
-- is cheap: it sends a small table to an already-open surface.
local FRAME_MS = 33

local function nowSeconds()
    return Open77.time.monotonic()
end

local function anchor(remainingMs)
    state.remainingMs = math.max(0, tonumber(remainingMs) or 0)
    state.anchoredAt = nowSeconds()
end

-- Remaining time, interpolated from the last server anchor. Never negative,
-- and never used to decide anything.
local function projectedRemainingMs()
    if state.remainingMs <= 0 then return 0 end
    local elapsed = (nowSeconds() - state.anchoredAt) * 1000.0
    return math.max(0, state.remainingMs - elapsed)
end

local function push()
    if not page or not ready then return end
    page:send("pursuit:hud", {
        visible = state.visible,
        phase = state.phase,
        role = state.role,
        opponentName = state.opponentName,
        remainingMs = projectedRemainingMs(),
        separation = state.separation,
        scannerAgeMs = state.scannerAgeMs,
        boarding = state.boarding,
        copReleased = state.copReleased,
        outcome = state.outcome,
        won = state.won,
        round = state.round,
        roundCount = state.roundCount,
        decider = state.decider,
        nextIsDecider = state.nextIsDecider,
        scoreSelf = state.scoreSelf,
        scoreOpponent = state.scoreOpponent,
        matchResult = state.matchResult,
        bustMeter = state.bustMeter,
        bustClosing = state.bustClosing,
        bustContact = state.bustContact,
        bustStalled = state.bustStalled,
        escapeProgress = state.escapeProgress,
        escapeFilling = state.escapeFilling,
        bustDistance = state.bustDistance,
        escapeDistance = state.escapeDistance,
        timeoutWinner = state.timeoutWinner,
        queuePosition = state.queuePosition,
        queueTotal = state.queueTotal,
    })
end

-- ------------------------------------------------------------------- events --

RegisterNetEvent("pursuit:matchState", function(payload)
    if type(payload) ~= "table" then return end

    state.visible = true
    state.phase = tostring(payload.state or "active")
    state.role = payload.role
    state.opponentName = payload.opponentName or state.opponentName
    state.copReleased = payload.copReleased ~= false

    -- The server may send either a remaining time or a duration; prefer the
    -- explicit remainder, because a duration says nothing about how much of it
    -- is already gone after a reconnect.
    if payload.remainingMs ~= nil then
        anchor(payload.remainingMs)
    elseif payload.state == "countdown" and payload.countdownSeconds then
        anchor(payload.countdownSeconds * 1000)
    elseif payload.state == "active" and payload.durationSeconds then
        anchor(payload.durationSeconds * 1000)
    end

    if payload.separation ~= nil then state.separation = tonumber(payload.separation) end
    if payload.scannerAgeMs ~= nil then state.scannerAgeMs = tonumber(payload.scannerAgeMs) end

    -- Sticky, like the two above: these describe the shape of the match and
    -- every push carries them, so a dropped packet must not blank the
    -- scoreboard for half a second.
    if payload.round ~= nil then state.round = tonumber(payload.round) end
    if payload.roundCount ~= nil then state.roundCount = tonumber(payload.roundCount) end
    -- Assigned, not merged: absent means "not a decider", and a stale true
    -- would brand an ordinary round as sudden death.
    state.decider = payload.decider == true
    state.nextIsDecider = payload.nextIsDecider == true
    if payload.scoreSelf ~= nil then state.scoreSelf = tonumber(payload.scoreSelf) end
    if payload.scoreOpponent ~= nil then state.scoreOpponent = tonumber(payload.scoreOpponent) end
    -- The thresholds the bar and the separation colours read are the SERVER's
    -- own rule distances, carried on every payload, so a config change moves
    -- the readout with the rule instead of leaving two numbers to drift.
    if payload.bustDistance ~= nil then state.bustDistance = tonumber(payload.bustDistance) end
    if payload.escapeDistance ~= nil then state.escapeDistance = tonumber(payload.escapeDistance) end
    -- Sticky like the two rule distances above: who the clock favours is part
    -- of the shape of the match, and the timer label reads it.
    if payload.timeoutWinner ~= nil then state.timeoutWinner = tostring(payload.timeoutWinner) end

    -- ASSIGNED, not merged, exactly like `boarding` below and for the same
    -- reason. An absent `bustMeter` is the server saying "the bust rule is not
    -- running" -- before the cop is released, between rounds, after a
    -- resolution -- and the correct response is for the bar to leave the
    -- screen. A sticky meter would freeze at whatever it last read and sit
    -- there through the scoreboard, which is a lie about a live rule.
    state.bustMeter = payload.bustMeter and tonumber(payload.bustMeter) or nil
    state.bustClosing = payload.bustClosing == true
    state.bustContact = payload.bustContact == true
    -- Same assignment discipline as the meter: an absent stall is the server
    -- saying "your engine is running", and the banner must leave with it.
    state.bustStalled = payload.bustStalled and tonumber(payload.bustStalled) or nil
    state.escapeProgress = payload.escapeProgress and tonumber(payload.escapeProgress) or nil
    -- Assigned, not merged, like the meter fields above: absent means "no
    -- attempt is filling", and a stale true would colour a fading attempt as
    -- one still being earned.
    state.escapeFilling = payload.escapeFilling == true

    -- ASSIGNED, not merged, and that is the whole disappearance mechanism.
    --
    -- The two readouts above are deliberately sticky: an absent `separation` is
    -- the server saying "I cannot tell right now", and blanking the number on
    -- one unreadable tick would flicker a value the player is steering by.
    -- Boarding is the opposite. Its absence is a DECISION -- the server has
    -- decided this player no longer needs telling where his car door is,
    -- because he is aboard, because the 45 s window closed, or because the
    -- match moved on -- and the correct response to that decision is for the
    -- strip to vanish. Making it sticky would leave "GET IN YOUR CAR" on screen
    -- for the whole chase, which is the exact clutter this affordance is
    -- supposed to avoid.
    --
    -- Cost of the choice, stated honestly: a dropped packet blanks the strip
    -- for one push. At 2 Hz that is half a second of a hint reappearing, which
    -- is a far cheaper failure than five minutes of a hint that will not leave.
    state.boarding = payload.boarding

    if payload.state == "intermission" then
        -- Between rounds. The card is the same one a resolution draws, with a
        -- countdown to the next round instead of a stand-down: the HUD stays up
        -- because the player is still in the match, still in the match world,
        -- and about to be placed on a new mark with the other role.
        state.outcome = payload.outcome
        state.won = payload.won
        state.matchResult = nil
        state.separation = nil
        state.scannerAgeMs = nil
        state.boarding = nil
        state.bustMeter = nil
        state.bustContact = false
        state.bustStalled = nil
        state.escapeProgress = nil
        state.escapeFilling = false
        push()
        return
    end

    if payload.state == "resolved" then
        state.outcome = payload.outcome
        state.won = payload.won
        state.matchResult = payload.matchResult
        state.separation = nil
        state.scannerAgeMs = nil
        state.boarding = nil
        state.bustMeter = nil
        state.bustContact = false
        state.bustStalled = nil
        state.escapeProgress = nil
        state.escapeFilling = false
        anchor(0)
        -- Hold the outcome card briefly, then stand down. The server also
        -- returns the player to the lobby on its own schedule; this only
        -- controls how long the card is readable.
        SetTimeout(6000, function()
            if state.phase == "resolved" then
                state.visible = false
                state.phase = "idle"
                state.outcome, state.won, state.role = nil, nil, nil
                state.matchResult = nil
                state.round, state.roundCount = 1, 1
                state.scoreSelf, state.scoreOpponent = 0, 0
            end
        end)
    end
    push()
end)

RegisterNetEvent("pursuit:queueState", function(payload)
    if type(payload) ~= "table" then return end
    if payload.queued then
        state.visible = true
        state.phase = "queued"
        state.queuePosition = tonumber(payload.position)
        state.queueTotal = tonumber(payload.total)
    else
        state.queuePosition, state.queueTotal = nil, nil
        if state.phase == "queued" then
            state.visible = false
            state.phase = "idle"
        end
    end
    push()
end)

-- ---------------------------------------------------------------- lifecycle --

AddEventHandler("onClientResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end

    local reason
    page, reason = WebUI.create({
        entry = "web/index.html",
        layer = "hud",
        width = 1920,
        height = 1080,
        fps = 60,
        -- Below open77_interactions (660) so a world prompt is never covered by
        -- the match panel.
        zIndex = 640,
        transparent = true,
        visible = true,
    })
    if not page then
        Open77.log.error("pursuit_hud WebUI failed: " .. tostring(reason))
        return
    end

    page:on("pursuit:hud:ready", function()
        ready = true
        push()
    end)

    CreateThread(function()
        while page do
            push()
            Wait(FRAME_MS)
        end
    end)

    Open77.log.info("pursuit_hud ready")
end)

AddEventHandler("onClientResourceStop", function(name)
    if name ~= GetCurrentResourceName() then return end
    page, ready = nil, false
end)
