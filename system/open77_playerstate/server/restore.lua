-- open77_playerstate -- the join path.
--
-- Everything in this file exists to answer one question safely: the player has
-- just connected and there is a saved position for them, so WHEN may it be
-- applied, and how.
--
-- ============================================================================
-- WHY THIS IS NOT SIMPLY "PLACE THEM ON CONNECT"
-- ============================================================================
--
-- Three separate hazards, each of which has cost this project real time.
--
-- 1. ACTING ON A PLAYER WHO IS NOT THERE CRASHES THEIR CLIENT.
--    A connected session is not an incarnation. Between the connection and a
--    puppet actually existing in the world there is a stretch -- the "continue"
--    screen, a character creator, a world that has not streamed -- during which
--    the player reports as connected and `char.state` reports `alive=no`. A
--    server-side placement received there does not fail, it takes the client
--    down. This is measured, not theoretical, and it is the reason this file
--    proves incarnation three ways before touching anybody.
--
-- 2. SOMEBODY ELSE MAY STILL NEED THE PLAYER.
--    open77_appearance may be about to open the character creator for a player
--    with no saved character. On 2026-08-27 exactly this collision took the
--    live Pursuit server down: enabling the database for the ranked ladder also
--    enabled persistence for appearance, so every fresh player was teleported
--    to a lobby while still standing in the creator. Both resources were
--    individually correct.
--
--    They could not have negotiated it: server resources cannot call each
--    other. Only the host sees both, so the barrier lives there --
--    `Open77.ready`, the join-time readiness gate. This resource is on BOTH
--    sides of it, which is the interesting part and is described below.
--
-- 3. PLACEMENT IS A TRANSACTION THAT TAKES SECONDS.
--    A player is moved by kill -> respawn, never by a transform write: the
--    transaction carries the fade, the streaming preload and the grace window,
--    where a direct teleport over any real distance drops them into unstreamed
--    world. Throughout it the replicated position is stale or absent and the
--    life phase is one of the *pending transitions. Anything that reads or
--    writes the player during that window races it.
--
-- ============================================================================
-- WHAT THIS DEPENDS ON FROM THE READINESS GATE
-- ============================================================================
--
-- Concretely, four things, all server-side and all from the host:
--
--   Open77.ready.participate({ timeoutMs, reason })
--       Declared once at load. From then on EVERY player who connects arrives
--       with one hold already in this resource's name. That is the load-bearing
--       property: this resource is not racing to take a hold before a gamemode
--       places somebody, it already has one before the player exists.
--
--   Open77.ready.status(playerId) -> { known, ready, session, holds = {...} }
--       Each hold carries the resource holding it. That is how this file knows
--       whether anybody ELSE still needs the player -- and it is a read of host
--       state, not a call into another resource.
--
--   Open77.ready.hold(playerId, reason) -> session
--       Refreshes this resource's deadline. Used as a heartbeat while another
--       resource is legitimately holding the player, so a four-minute character
--       creation never costs anybody their saved position.
--
--   Open77.ready.release(playerId, session, note)
--       Opens the gate. The `session` is captured BEFORE the first await and
--       passed back afterwards: player ids are recycled, and this is what stops
--       an answer computed for someone who has since disconnected from opening
--       the gate of whoever inherited their id.
--
-- The gate settles ORDER. It does not settle who owns spawn -- see the long
-- note in server/main.lua -- and it is a barrier lifting rather than a trigger,
-- so this file never waits on `onPlayerReady`. It keeps its own signal and asks
-- the gate for permission, exactly as the platform documentation requires.
--
-- Note also what the gate does NOT promise: a gate can open on a TIMEOUT, with
-- the player still in a modal and no puppet at all. So "the gate is open" is
-- never sufficient on its own. Incarnation is proved separately, below.
--
-- ============================================================================
-- THE THREE SIGNALS THAT PROVE A PLAYER IS REAL
-- ============================================================================
--
-- The project's own rule for proving a connection is three signals, not one.
-- Server-side that reads:
--
--   getLifeState(playerId) ~= nil        the life authority knows them
--   phase is `alive` or `recovering`     not dead, not mid-transition
--   position(playerId) ~= nil            a replicated position resolves
--
-- The phase is spelled WITHOUT an underscore on the server (`respawnpending`,
-- not `respawn_pending`) -- the two hosts disagree, quietly, because `alive`,
-- `dead` and `recovering` are identical on both. `PlayerState.isSettled` is
-- where that is dealt with, once.
--
-- ============================================================================
-- THE WRITE GATE
-- ============================================================================
--
-- Whether this join may later OVERWRITE the stored row is decided here, and it
-- is decided by what happened to the restoration. The rule, in full:
--
--   restored     placed successfully              -> writable
--   nothing      no stored row; nothing to lose   -> writable
--   expired      stored row too old to use        -> writable
--   declined     policy says never place          -> writable
--   failed       could not read, or could not place -> NOT writable
--   abandoned    gave up waiting for a real player  -> NOT writable
--
-- The last two are the point. A player whose restoration did not land is
-- standing at the default spawn, which is not where they were. If this resource
-- then saved that position on their next disconnect, its own failure would
-- become permanent, silent data loss -- the player would lose the very spot the
-- restore failed to give back. So a failure keeps the row and says so loudly.

local Config = PlayerState.Config
local Tune = PlayerState.Tune
local players = PlayerState.players
local log = PlayerState.log
local nowMs = PlayerState.nowMs

-- ------------------------------------------------------------ participation --

local function participate()
    -- main.lua has already decided the resource records only when the gate is
    -- absent, so nothing below this file's `mode() ~= "full"` guard ever runs;
    -- this check keeps the load path itself from touching a nil table.
    if not PlayerState.hasReadyGate then return end
    local seconds = Tune.readyTimeoutSeconds
    if type(seconds) ~= "number" or seconds < 5 then seconds = 45 end
    Open77.ready.participate({
        timeoutMs = math.floor(seconds * 1000),
        reason = "restore_player_state",
    })
end

-- main.lua re-calls this from `onTunableChanged` so a live change to the hold
-- budget reaches the gate; the newest declaration wins.
PlayerState.participate = participate

-- Declared unconditionally at load, including on a server where this resource
-- will turn out to be inert.
--
-- The alternative -- declare only once the database probe and the spawn policy
-- have been resolved -- leaves a window at boot in which a joiner is not
-- reserved, and buys nothing: the inert path below releases synchronously in
-- the connect handler, before any await, so on a Pursuit server the hold exists
-- for a fraction of a tick and nobody waits on it.
participate()

-- ----------------------------------------------------------------- helpers --

local function releaseGate(playerId, session, note)
    if not PlayerState.hasReadyGate then return false end
    return Open77.ready.release(playerId, session, note)
end

-- Every hold on this player that is NOT ours. Returns the count and one name,
-- which is all the caller needs: it heartbeats while any exist and names one in
-- the log so "nothing happens when I join" has an answer in a single line.
local function foreignHolds(status)
    local count, who = 0, nil
    for _, hold in ipairs(status.holds or {}) do
        if hold.resource ~= PlayerState.resource then
            count = count + 1
            if who == nil then who = hold.resource end
        end
    end
    return count, who
end

-- `heading_known` is a TINYINT(1), and what comes back for one is not fixed.
-- MySqlConnector treats TINYINT(1) as MySQL's BOOL by default, so the bridge
-- hands Lua a BOOLEAN -- but the connection string is the operator's, and
-- `TreatTinyAsBoolean=false` in it makes the very same column arrive as an
-- integer instead. A naive `tonumber(x) ~= 0` reads `true` as nil and then as
-- 0, quietly turning every known heading into an unknown one. Accept both.
local function truthy(value)
    if value == nil then return false end
    if type(value) == "boolean" then return value end
    local number = tonumber(value)
    if number ~= nil then return number ~= 0 end
    return false
end

-- `respawn` takes a FRACTION of maximum health, validated to 0.01..1.0.
-- `getHealth` reports ABSOLUTE health against a maximum that defaults to 100.
-- Two different scales on two neighbouring APIs; this is the one place the
-- conversion happens.
local function healthFraction(row)
    if Tune.restoreHealth ~= true then return 1.0 end
    local maxHealth = tonumber(row.max_health) or 100.0
    if maxHealth <= 0 then maxHealth = 100.0 end
    local health = tonumber(row.health) or maxHealth
    local fraction = health / maxHealth
    local floor = tonumber(Tune.minRestoreHealth) or 0.15
    if fraction ~= fraction then fraction = 1.0 end        -- NaN
    if fraction < floor then fraction = floor end
    if fraction > 1.0 then fraction = 1.0 end
    if fraction < 0.01 then fraction = 0.01 end            -- engine floor
    return fraction
end

-- The one way this resource moves a player. Modelled on `Pursuit.placeAt`, and
-- for the same reasons.
local function placeAt(playerId, row, fraction)
    -- Read the phase before killing: a player who is already down must not be
    -- killed again, because the life authority refuses the second transition
    -- and the whole placement fails.
    local life = Open77.players.getLifeState(playerId)
    if life == nil then return false, "player_not_found" end
    local phase = life.phase or ""
    if phase == "alive" or phase == "recovering" then
        local ok, killError = Open77.players.kill(playerId, {
            cause = "script",
            -- Tagged so a gamemode with a "player died" rule can reject this
            -- one. Every placement is a death, and a mode that does not guard
            -- its own spawns will otherwise fire that rule on them.
            weapon = "playerstate:restore",
        })
        if not ok then return false, "kill:" .. tostring(killError) end
    elseif phase ~= "dead" then
        -- revive_pending / respawn_pending: a transaction is already in flight
        -- and the next one is refused. Report it rather than paper over it.
        return false, "transition_in_progress:" .. phase
    end

    local ok, respawnError = Open77.players.respawn(playerId, {
        position = { x = row.pos_x, y = row.pos_y, z = row.pos_z },
        heading = tonumber(row.heading) or 0.0,
        -- Always 0. See the bucket note in server/main.lua.
        bucket = 0,
        health = fraction,
        graceMs = 5000,
    })
    if not ok then return false, "respawn:" .. tostring(respawnError) end
    return true
end

-- Armour is not carried by the life transaction, so it has to be applied after
-- the respawn has landed -- set into the fade it is simply lost. This waits for
-- the phase to come back rather than sleeping a magic number, and gives up
-- saying so rather than writing armour onto a player who is not there.
local function settleThenArmor(record, armor)
    local playerId = record.playerId
    local deadlineMs = nowMs() + Config.settleMaxMs
    while nowMs() < deadlineMs do
        Wait(Config.settlePollMs)
        if players[playerId] ~= record then return false, "player_gone" end
        if PlayerState.isSettled(Open77.players.getLifeState(playerId)) then
            local ok, err = Open77.players.setArmor(playerId, armor)
            return ok, err
        end
    end
    return false, "respawn_did_not_settle"
end

-- One exit, so no path can forget to open the gate.
local function finish(record, session, state, writable, why, detail)
    record.restoreState = state
    if writable then PlayerState.setWritable(record, why) end
    releaseGate(record.playerId, session, "playerstate:" .. state)
    if detail ~= nil then
        log(("%s (%d): %s -- %s"):format(record.name, record.playerId, state, detail))
    end
end

-- ---------------------------------------------------------------- the join --

local function runJoin(record, session)
    local playerId = record.playerId

    -- 1. Is there anything to restore?
    local row, loadError = PlayerState.loadRow(record.identifier)
    if loadError ~= nil then
        -- Two different failures wear the same shape here, and calling them the
        -- same thing would send an operator hunting a database problem that is
        -- really a missing configuration.
        local ready = PlayerState.dbState()
        if ready == false then
            -- No bridge at all. Nothing was ever stored and nothing ever will
            -- be, so there is no row to protect: this is the clean "degrade to
            -- doing nothing" path, and the next tick of `announce` turns the
            -- whole resource off with one line naming the reason.
            return finish(record, session, "nothing", true, "no_database",
                "no database configured, so there is nothing to restore")
        end
        -- The bridge is up and the read failed anyway. Refusing to write later
        -- is the important half: a database that is briefly unreachable must
        -- not cost this player the position it could not fetch.
        return finish(record, session, "failed", false, nil,
            "database read failed, so the stored row is left untouched: " .. tostring(loadError))
    end
    if row == nil then
        return finish(record, session, "nothing", true, "no_stored_state",
            "no saved state; spawning normally")
    end

    local expiryHours = tonumber(Tune.expiryHours) or 0
    local ageSeconds = tonumber(row.age_seconds) or 0
    if expiryHours > 0 and ageSeconds > expiryHours * 3600 then
        return finish(record, session, "expired", true, "stored_state_expired",
            ("saved state is %.1f h old and the limit is %d h; spawning normally")
                :format(ageSeconds / 3600, expiryHours))
    end

    -- 2. Wait until this player is genuinely ours to touch.
    --
    -- Two clocks, measuring two different things.
    --
    -- The INCARNATION budget bounds how long the join gate is HELD, and it runs
    -- only while this resource is the last holder: if somebody else still needs
    -- the player, it is reset and our own hold heartbeated instead. When it
    -- expires the hold goes back -- and the attempt carries on regardless.
    --
    -- The CEILING bounds the attempt itself. It should never be reached; it is
    -- there so that a bug in this loop costs one restore rather than a
    -- coroutine per join for the lifetime of the server.
    local ceilingMs = nowMs() + Config.joinCeilingMs
    local budgetMs = (tonumber(Tune.readyTimeoutSeconds) or 45) * 1000
    local incarnationDeadlineMs = nowMs() + budgetMs
    local waitingOn = nil
    -- Set once the hold has been given back early. Waiting and HOLDING are two
    -- different things, and separating them is what stops a slow world costing
    -- somebody their saved position -- see the note at the deadline below.
    local released = false

    while true do
        Wait(Config.joinPollMs)

        if players[playerId] ~= record then
            -- Disconnected, or the id was recycled onto somebody else. The
            -- record is already gone from the roster, so there is nothing to
            -- mark and nothing to release that is still ours.
            return
        end
        if nowMs() > ceilingMs then
            return finish(record, session, "abandoned", false, nil,
                ("gave up after %.0fs; the player never became placeable and the stored " ..
                 "row is left untouched"):format(Config.joinCeilingMs / 1000))
        end

        local status = Open77.ready.status(playerId)
        if not status.known or status.session ~= session then
            -- The gate entry moved on: this answer was computed for a player
            -- who is no longer here. Dropping it is the whole reason the
            -- session was captured before the first await.
            return
        end

        local others, who = foreignHolds(status)
        if others > 0 then
            if who ~= waitingOn then
                waitingOn = who
                log(("%s (%d): waiting for %s before restoring"):format(record.name, playerId, who))
            end
            -- Heartbeat, but only while the hold is still ours to refresh.
            -- `hold` both takes and refreshes, so calling it after a deliberate
            -- early release would silently re-close a gate this resource has
            -- already decided to stop blocking.
            if not released then
                Open77.ready.hold(playerId, "awaiting:" .. tostring(who))
            end
            -- The budget measures time spent waiting for a WORLD, not time
            -- spent waiting for another resource. Somebody taking four minutes
            -- over their character's face must not cost this player anything.
            incarnationDeadlineMs = nowMs() + budgetMs
        else
            -- Nobody else needs them. Are they actually in the world?
            local life = Open77.players.getLifeState(playerId)
            if PlayerState.isSettled(life) and Open77.players.position(playerId) ~= nil then
                break
            end
            if not released and nowMs() > incarnationDeadlineMs then
                -- Connected, still not incarnated, and nothing else is holding
                -- them. Stop BLOCKING -- but do not stop waiting.
                --
                -- Those are two different decisions and conflating them is a
                -- bug this loop had for an afternoon. The hold exists to stop
                -- somebody else placing this player before we do; it is not the
                -- right instrument for waiting out a slow world, and letting it
                -- expire on its own costs one degraded join plus a WRN naming
                -- this resource. So the hold goes back now, and the attempt
                -- continues until the absolute ceiling. Nothing else on this
                -- server places players -- if something did, this resource
                -- would be inert -- so a late restore is still the right
                -- outcome, and `mayWrite` stays false throughout, so a player
                -- who never arrives loses nothing.
                released = true
                releaseGate(playerId, session, "playerstate:awaiting_world")
                log(("%s (%d): no character after %.0fs (life=%s); the join gate is released " ..
                     "and the restore will land when they appear")
                    :format(record.name, playerId, budgetMs / 1000,
                        life and tostring(life.phase) or "nil"))
            end
        end
    end

    -- 3. Place them.
    local fraction = healthFraction(row)
    local placed, placeError = placeAt(playerId, row, fraction)
    if not placed then
        return finish(record, session, "failed", false, nil,
            "placement refused (" .. tostring(placeError) ..
            "); the stored row is left untouched")
    end

    -- The restore IS the truth now. Overwrite the sample and the write mark
    -- with it, and drop the heading baseline: without this the next autosave
    -- would compare a sample taken at the default spawn against a write mark at
    -- the restored position, decide the player had moved, and write the default
    -- spawn straight back over the row that was just honoured.
    record.sample = {
        x = row.pos_x, y = row.pos_y, z = row.pos_z,
        bucket = 0,
        heading = tonumber(row.heading) or 0.0,
        headingKnown = truthy(row.heading_known),
        health = tonumber(row.health),
        maxHealth = tonumber(row.max_health),
        armor = tonumber(row.armor),
        atMs = nowMs(),
    }
    record.lastWrite = { x = row.pos_x, y = row.pos_y, z = row.pos_z }
    record.lastPos = nil
    record.heading = tonumber(row.heading) or 0.0
    record.headingKnown = truthy(row.heading_known)

    -- 4. Open the gate. Do it here rather than after the armour: the player is
    -- placed, the transaction is issued, and anything else waiting on this
    -- player has no reason to keep waiting for a cosmetic follow-up.
    finish(record, session, "restored", true, "restored", nil)

    log(("restored %s (%s) to %.1f %.1f %.1f heading %.1f at %.0f%% health")
        :format(record.name, PlayerState.shortId(record.identifier),
            row.pos_x, row.pos_y, row.pos_z, tonumber(row.heading) or 0.0, fraction * 100))

    -- 5. Armour, once the respawn has settled.
    if Tune.restoreArmor == true then
        local armor = tonumber(row.armor) or 0
        if armor > 0 then
            local ok, err = settleThenArmor(record, armor)
            if not ok then
                log(("%s (%d): armour not restored: %s"):format(record.name, playerId, tostring(err)))
            end
        end
    end
end

-- --------------------------------------------------------------- lifecycle --

AddEventHandler("onPlayerConnected", function(playerIdStr)
    local playerId = tonumber(playerIdStr)
    if playerId == nil or playerId <= 0 then return end

    local current = PlayerState.mode()

    if current ~= "full" then
        -- Inert, or recording without placing. Either way nobody is going to be
        -- moved, so the hold this resource was handed at connect is given back
        -- immediately -- synchronously, before any await, so that on a server
        -- where a gamemode owns spawn this resource costs a fraction of a tick
        -- and never a degraded join.
        releaseGate(playerId, nil, "playerstate:inactive")
        local record = players[playerId]
        if record ~= nil then
            record.restoreState = (current == "save") and "declined" or "off"
            PlayerState.setWritable(record, "placement_not_configured")
        end
        return
    end

    -- `ensurePlayer` is idempotent and is called here as well as in main.lua so
    -- this file does not depend on handler registration order within the VM.
    local record = PlayerState.ensurePlayer(playerId)
    if record == nil then
        -- No durable identifier: not authenticated, or already gone. Nothing
        -- can be keyed, so there is nothing to restore and no reason to hold.
        releaseGate(playerId, nil, "playerstate:unidentified")
        return
    end

    -- Captured BEFORE the coroutine, because everything inside it awaits a
    -- database round trip and the player could be gone and replaced on the same
    -- id by the time it returns.
    local session = Open77.ready.status(playerId).session
    record.session = session
    record.restoreState = "pending"

    CreateThread(function()
        local ok, err = pcall(runJoin, record, session)
        if not ok then
            -- A raise inside the join must not leave the player held: the gate
            -- would open on a timeout, one degraded join, and the reason would
            -- be lost. Say what happened and open it now.
            log(("join path raised for %s (%d): %s"):format(record.name, playerId, tostring(err)))
            record.restoreState = "failed"
            releaseGate(playerId, session, "playerstate:error")
        end
    end)
end)
