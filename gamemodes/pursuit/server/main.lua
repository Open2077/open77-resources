-- Pursuit -- server authority.
--
-- Everything that grants something lives here. The client draws the ring and
-- reports intent; it never decides. In particular the queue is entered only
-- after this file re-derives the player's position from replicated state, so a
-- client claiming to stand in the circle from the other side of the city is
-- refused rather than believed.
--
-- Note on packaging: this is ONE server resource on purpose. The server
-- runtime installs no `exports` and no cross-resource event bus -- TriggerEvent
-- is per-VM and only the host fans events in -- so a second server resource
-- could not talk to this one at all. The client is where the split pays off.

local Config = PursuitConfig

-- The settings a server owner may move from Warden's Tuning tab, declared in
-- shared/config.lua and registered here.
--
-- THE CALL IS SERVER-ONLY AND THE TABLE IS NOT. `Open77.tunables` does not
-- exist on the client, and shared/config.lua is downloaded by every connecting
-- player -- so the declaration table lives there, beside everything else this
-- mode tunes, and this one line lives here. Putting the call in the shared
-- script would fail on every client and the whole resource set would be
-- refused.
--
-- Global rather than local on purpose: server/match.lua shares this Lua state
-- and reads the same proxy. That is the same mechanism as the `Pursuit` table
-- at the bottom of this file, and for the same reason -- the server runtime
-- installs no exports.
--
-- `Tune.key` IS A CALL, NOT A FIELD. It asks the host for the value at the
-- moment of the read, which is the whole point: a `local` taken at file scope
-- freezes the value at load and every later change from the panel does
-- nothing, while the panel goes on reporting the new number. Read it where it
-- is used. A misspelled key raises rather than returning nil.
Tune = Open77.tunables.declare(Config.tunables)

-- playerId -> { state, sinceMs, outsideSinceMs, warned }
local players = {}
-- Queue of playerIds in arrival order.
local queue = {}

local STATES = {
    lobby = { queued = true, gone = true },
    queued = { lobby = true, countdown = true, gone = true },
    countdown = { active = true, lobby = true, gone = true },
    active = { resolved = true, lobby = true, gone = true },
    resolved = { lobby = true, gone = true },
}

local function nowMs()
    return math.floor(Open77.time.monotonic() * 1000)
end

-- Command arguments arrive as strings and may be anything at all; NaN and the
-- infinities pass tonumber but poison every comparison downstream.
local function finiteNumber(value)
    local parsed = tonumber(value)
    if parsed == nil or parsed ~= parsed or
        parsed == math.huge or parsed == -math.huge then
        return nil
    end
    return parsed
end

local function readyUpPosition()
    local centre = Config.lobby.center
    local offset = Config.lobby.readyUp.offset
    return {
        x = centre.x + offset.x,
        y = centre.y + offset.y,
        z = centre.z + offset.z,
    }
end

local function log(text)
    print("[pursuit] " .. text)
end

local function output(source, raw, success, text)
    log(text)
    if source ~= nil and source > 0 then
        TriggerClientEvent("open77:command:result", source, raw or "", success == true, text)
    end
end

-- Is the platform's join-time readiness gate open for this player?
--
-- WHY A RULE THAT IS NOT THE JOIN PATH HAS TO ASK. The gate
-- (docs/writing-a-gamemode.md 2.8) exists because `open77_appearance` may be holding
-- this player inside the character creator. While it holds, the player is standing at
-- the PRISTINE-SAVE SPAWN -- kilometres from Corpo Plaza -- with no puppet anybody may
-- touch. The join placement below defers on exactly this check. The LEASH did not, and
-- on 2026-08-27 it dragged a live player out of the creator roughly every 25 s:
--
--   01:07:56 [open77_appearance] ready completed player=1 ok=true creating=true
--   01:07:58 [pursuit] player 1 announced but is not ready yet; deferring the lobby placement
--   01:09:15 [pursuit] player 1 leashed back to the lobby
--   01:09:40 [pursuit] player 1 leashed back to the lobby
--
-- `Config.lobby.placementGraceMs` could never have covered that, and reaching for it
-- would have been the third wrong fix: that grace starts at a PLACEMENT, and this
-- player had never been placed. A not-yet-placed player needs a gate, not a grace.
--
-- IT FAILS OPEN, on purpose and in both directions. If `Open77.ready` is ever absent --
-- an older host binary, a runtime predating the gate -- this answers true and every
-- rule behaves exactly as it did before the gate existed; if the call itself raises,
-- same answer, logged once rather than every tick. The host agrees: its `IsReady`
-- returns true for a player it holds no gate for. Failing CLOSED would mute the leash
-- forever on any host that lacks the gate, which is a larger outage than the one this
-- fixes.
local readyGateWarned = false
local function readyToBeActedUpon(playerId)
    local gate = Open77.ready
    if gate == nil or gate.isReady == nil then return true end
    local ok, ready = pcall(gate.isReady, playerId)
    if not ok then
        if not readyGateWarned then
            readyGateWarned = true
            log(("readiness gate unreadable (%s); treating every player as ready"):format(
                tostring(ready)))
        end
        return true
    end
    -- Anything but an explicit false is "ready": a host that returns nil here has told
    -- us nothing, and nothing must not mute a containment rule.
    return ready ~= false
end

-- Forget everything the leash believes about a player.
--
-- BOTH FIELDS MATTER. The timer, so time spent outside while the player was exempt
-- cannot fire the instant he becomes judgeable -- that would be the same teleport, one
-- tick later. And the warned flag, so his next genuine excursion still earns its
-- warning instead of being swallowed by a stale one.
--
-- Deliberately does NOT touch `deadHealAttempts`: that counter is capped on purpose and
-- every heal goes through `placeAt`, so clearing it here would turn a bounded five
-- attempts into an endless re-placement loop.
local function resetLeash(record)
    if record == nil then return end
    record.outsideSinceMs = nil
    record.warned = false
    -- The seated-return bookkeeping travels with the timer it qualifies: a
    -- player who came back inside (or was re-placed, or became exempt) starts
    -- his next excursion with a fresh reclaim budget and a fresh warning.
    record.seatedWarnedAtMs = nil
    record.seatedReclaimedVehicleId = nil
    record.seatedSettleUntilMs = nil
end

-- Adopt a player the roster has never seen.
--
-- A resource reload replaces this VM, so `players` comes back empty while the
-- server is still full of connected people -- and `onPlayerConnected` does not
-- re-fire for them. There is no enumeration API (`Open77.players` exposes no
-- all()/list()), so the roster cannot be rebuilt on start; it has to be
-- repopulated lazily from the next event each player produces. Every entry
-- point that receives a playerId therefore goes through this.
local function ensurePlayer(playerId)
    if playerId == nil or playerId <= 0 then return nil end
    local record = players[playerId]
    if record == nil then
        record = {
            state = "lobby",
            sinceMs = nowMs(),
            outsideSinceMs = nil,
            warned = false,
            -- Adopted mid-session: grant the placement grace so the leash does
            -- not judge someone it has only just heard of.
            graceUntilMs = nowMs() + Config.lobby.placementGraceMs,
        }
        players[playerId] = record
        log(("adopted player %d after a reload"):format(playerId))
    end
    return record
end

-- Single guarded transition point: an invalid transition is a logged refusal,
-- never a silent state corruption.
local function transition(playerId, target, detail)
    local record = players[playerId]
    if record == nil then return false, "unknown_player" end
    local allowed = STATES[record.state]
    if allowed == nil or allowed[target] ~= true then
        log(("refused transition %d: %s -> %s"):format(
            playerId, tostring(record.state), tostring(target)))
        return false, "invalid_transition"
    end
    local previous = record.state
    record.state = target
    record.sinceMs = nowMs()
    TriggerEvent("pursuit:stateChanged", playerId, target, previous, detail)
    return true
end

-- Server-side containment. This is the half that is trusted.
--
-- Replication is a snapshot stream, not a live read, so the position the
-- server holds lags the client's true position by up to a snapshot interval.
-- Rejecting on the exact radius would refuse honest players whose latest
-- snapshot has not landed yet; the grace is deliberately generous because the
-- point is to stop a client claiming to be somewhere else entirely, not to
-- arbitrate centimetres.
local CONTAINMENT_GRACE = 3.0
local CONTAINMENT_HEIGHT = 8.0

-- Returns inside, detail. `detail` is "unknown" when the server genuinely
-- cannot tell -- during a respawn the position briefly stops resolving -- which
-- callers must treat as "do not judge", never as "outside".
local function containsPlayer(playerId, centre, radius, bucket)
    local position = Open77.players.position(playerId)
    if position == nil then
        return false, "unknown"
    end
    if bucket ~= nil and position.bucket ~= bucket then
        return false, "wrong_bucket"
    end

    local dx = position.x - centre.x
    local dy = position.y - centre.y
    local dz = position.z - centre.z
    local planar = math.sqrt(dx * dx + dy * dy)

    if planar > radius + CONTAINMENT_GRACE then
        return false, ("too_far:%.1fm"):format(planar)
    end
    if dz >= CONTAINMENT_HEIGHT or dz <= -CONTAINMENT_HEIGHT then
        return false, ("wrong_level:%.1fm"):format(dz)
    end
    return true, planar
end

-- ------------------------------------------------------ the seated question --
--
-- Which vehicle, if any, holds this player's seat -- read from the server's
-- own occupancy ledger (`Open77.vehicles.all()` carries `occupants`), never
-- from anything the client claims.
--
-- WHY A PLACEMENT MUST ASK. Both halves were measured, not inferred:
--
--   * A kill -> respawn issued at a SEATED player does not move him. The
--     client absorbs the transaction and re-seats him where he was
--     (2026-08-28, `admin.player.at`/`tp` on a player in a vehicle: logs
--     success, respawns, ends re-seated at the old spot; no error, no move).
--   * Worse, it can DISCONNECT him. The respawn suspends the server's
--     position snapshot for the player; his still-seated client re-claims the
--     car's simulation authority into that gap; the claim needs a fresh
--     snapshot, gets none, and `VehicleAuthorityService.Control` answers
--     `PlayerUnavailable` -- which the session layer treats as a protocol
--     violation. Measured twice tonight (2026-08-29, agent-dev-server.log):
--     leash return at 03:23:13.398 -> `Disconnecting 6:
--     invalid_vehicle_control:playerunavailable` at 03:23:15.601, and again
--     03:30:20.962 -> 03:30:23.217. Same race class as the NotFound /
--     WrongBucket kicks softened on 2026-08-26 (SessionManager.cs), but this
--     status still disconnects -- flagged as release-work on the server.
--
-- So the leash refuses to place a seated player (see the tick), and this
-- helper is how it and `placeAt` ask. Fail-open on purpose: if the ledger is
-- unreadable the answer is "not seated" and every path behaves exactly as it
-- did before this check existed -- pursuit holds `world.vehicles`, so an empty
-- read here is an empty world, not a refusal.
local function seatedVehicleOf(playerId)
    local ok, all = pcall(Open77.vehicles.all)
    if not ok or type(all) ~= "table" then return nil end
    for _, vehicle in ipairs(all) do
        for _, occupant in ipairs(vehicle.occupants or {}) do
            if occupant.playerId == playerId then return vehicle end
        end
    end
    return nil
end

-- Mechanism timing, not tuning (the `spawnLiftMetres` rule): constants.
--
-- The settle covers the client stepping out of a car that was reclaimed under
-- him -- the server's occupancy ledger clears the instant the vehicle is
-- removed, a beat before the puppet has actually dismounted, and a respawn
-- issued into that beat is the exact absorbed-transaction this exists to
-- avoid. The warn interval paces the "leave the vehicle" reminder for a car
-- this resource may not remove.
local SEATED_RETURN_SETTLE_MS = 1500
local SEATED_RETURN_WARN_INTERVAL_MS = 5000

-- The one way this gamemode moves a player.
--
-- kill -> respawn, never a raw transform write: the transaction carries the
-- fade, the streaming preload and the grace window. A direct teleport over any
-- real distance drops the player into unstreamed world. Phase C places match
-- spawns through this same primitive.
local function placeAt(playerId, position, heading, bucket, reason)
    -- Observability, not a refusal: the leash now never sends a seated player
    -- here, but the dead-heal and the match return still can, and when one
    -- does the log must name the hazard instead of the symptom being chased
    -- two hours later ("feels like a disconnect").
    local seatedIn = seatedVehicleOf(playerId)
    if seatedIn ~= nil then
        log(("WARNING: placing player %d (%s) while he is SEATED in vehicle %s (%s, owner %s) -- the respawn may be absorbed by the client and his vehicle-control claim can race the snapshot gap into a disconnect"):format(
            playerId, tostring(reason or "place"), tostring(seatedIn.id),
            tostring(seatedIn.record), tostring(seatedIn.resource)))
    end
    -- Read the phase before killing. A player who is already down must not be
    -- killed again -- the life authority refuses the second transition and the
    -- whole placement fails, which from Phase C onward is a real path: the
    -- runner who just lost by dying is the very player the resolution then
    -- tries to send back to the lobby. Refusing there would strand him dead in
    -- a match bucket nobody owns any more. Same shape as freeroam's teleport
    -- transaction, and for the same reason.
    local life = Open77.players.getLifeState(playerId)
    if life == nil then
        log(("placement failed for %d: player_not_found"):format(playerId))
        return false
    end
    if life.phase == "alive" or life.phase == "recovering" then
        local ok, killError = Open77.players.kill(playerId, {
            cause = "script",
            weapon = "pursuit:" .. (reason or "place"),
        })
        if not ok then
            log(("placement failed for %d at kill: %s"):format(playerId, tostring(killError)))
            return false
        end
    elseif life.phase ~= "dead" then
        -- revive_pending / respawn_pending: a transaction is already in flight
        -- and the next one is refused. Report it rather than paper over it.
        log(("placement failed for %d: transition_in_progress (%s)"):format(
            playerId, tostring(life.phase)))
        return false
    end
    -- GHOSTING INTEGRATION (platform pass-through). Set while the player is
    -- dead, the flag rides the respawn transaction to the clients, so a
    -- placement can never shove a neighbour on arrival — even when two slots
    -- degrade to the same anchor. The server auto-clears the ghost once the
    -- player has been ~1 m clear of every same-bucket player for a moment; the
    -- slot grid still spreads players out, the two compose, ghosting just
    -- removes the stacked-spawn failure mode entirely. Guarded so the gamemode
    -- still runs against a server that predates `setGhosted`; a refusal is a
    -- log line, never a failed placement — the placement worked before
    -- ghosting existed and must keep working without it.
    if Open77.players.setGhosted ~= nil then
        local ghosted, ghostError = Open77.players.setGhosted(playerId, true)
        if not ghosted then
            log(("ghost-on-spawn refused for %d: %s"):format(
                playerId, tostring(ghostError)))
        end
    end
    local respawned, respawnError = Open77.players.respawn(playerId, {
        position = { x = position.x, y = position.y, z = position.z },
        heading = heading or 0.0,
        bucket = bucket or Config.lobby.bucket,
        health = 1.0,
        graceMs = 5000,
    })
    if not respawned then
        log(("placement failed for %d at respawn: %s"):format(
            playerId, tostring(respawnError)))
        return false
    end
    -- A respawn is a transaction: fade, streaming preload, then the puppet
    -- attaches. Throughout it the replicated position is stale or absent, so
    -- the leash must not evaluate this player until it has settled -- otherwise
    -- placing someone in the lobby is itself what trips the leash.
    local record = players[playerId]
    if record ~= nil then
        record.graceUntilMs = nowMs() + Config.lobby.placementGraceMs
        resetLeash(record)
    end
    return true
end

-- "You are in the lobby now" -- the event that owns the lobby's furniture.
--
-- The client draws the ready-up ring, its hold-E prompt and the boundary ring
-- once and kept them for the session, so during a match they were still on
-- screen 1.3 km away, the prompt cheerfully offering to queue at "6.1 M" and
-- ignoring its own 90 m `maxDistance`. Distance was never going to fix that:
-- the furniture is not far away, it is in a world the player has left. The rule
-- is CONTEXT, not range -- the lobby's props exist exactly while the player is
-- in the lobby.
--
-- So this is sent on every entry into the lobby, and the client tears the
-- furniture down on the first `pursuit:matchState` instead. Two events, one
-- edge each, and no polling.
local function pushLobbyState(playerId)
    TriggerClientEvent("pursuit:lobbyState", playerId, {
        center = Config.lobby.center,
        -- The client is TOLD the radius, it does not read the config, so a
        -- retuned leash reaches a player already standing in the lobby at his
        -- next push -- a placement, a queue change or a match ending. The
        -- SERVER side of the leash below is honest immediately either way, so
        -- the worst case is a drawn boundary that lags the enforced one by one
        -- event, and today nothing is drawn (`lobby.drawBoundary`).
        radius = Tune.lobbyRadius,
        readyUp = {
            position = readyUpPosition(),
            radius = Config.lobby.readyUp.radius,
        },
    })
end

-- --------------------------------------------------------- lobby spawn slots --
--
-- Every lobby placement used to aim at the SAME point, `Config.lobby.center`.
-- Two players placed together therefore materialised inside each other's
-- capsules and the physics solver shoved them apart -- the owner's "on top of
-- each other ... they move weirdly in a buggy way". Both members of a resolved
-- match return to the lobby in the same breath, so this was not a rare race;
-- it was the ordinary end of every match.
--
-- The fix is DETERMINISTIC SLOTS, not random jitter: jitter can collide by
-- luck, slots cannot. Slot 0 is the surveyed anchor itself; around it, ring k
-- sits at radius k * spacing and carries floor(2*pi*k) slots, which makes both
-- the gap between neighbours on a ring and the gap between rings come out at
-- the spacing (chord = 2r*sin(pi/n) >= spacing when n = floor(2*pi*k)).
-- Alternate rings are staggered half a step so radially adjacent slots do not
-- line up. The formula extends to any player count -- ring 4 exists the
-- moment somebody needs slot 37 -- so twenty simultaneous placements land
-- twenty separated players with no hand-authored list, and nothing ever falls
-- back to the bare anchor while a formula slot is free.
--
-- TERRAIN HONESTY -- the caps below are survey results, not tuning, which is
-- why they are constants and not panel entries (the `spawnLiftMetres` rule).
-- Every slot reuses the anchor's surveyed z: the server has no ground query
-- and Lua cannot raycast, so a slot has to stay on ground the survey vouches
-- for, or the z is a guess and a guess is how players end up wedged (the
-- staircase lesson). The authority is the 2026-08-27 ground survey, plan
-- doc section 10; in offsets from the centre it says:
--
--   * the centre reads 14.77 -- the lower slab the authored z belongs to.
--     The near neighbourhood of it is the ground lobby players stand on and
--     walk over every session;
--   * (+6.0, 0.0), the ready-up ring, reads 15.36 -- the RAISED plaza, a
--     ~0.6 m step somewhere between +0 and +6 in x that was never pinned
--     down. Placements at the shared z do land on that slab (pursuit.tpcircle
--     proves it), but a slot ON the unlocated step edge itself would wedge.
--     Hence MAX_EAST at +2.5: short of anywhere the step can plausibly run;
--   * (+3.0, +5.2) is ON the kerb where the raised plaza ends, with a wall
--     above it -- the survey calls the +y direction unusable. Hence
--     MAX_NORTH at +3.5 (a probe at (-1.0, +4.6) still read walkable ground,
--     so the cap keeps a metre of margin to the kerb line);
--   * the survey names one more no-go: a large planter with a drop to the
--     street behind it, in the quadrant SOUTH-WEST of the centre (its
--     bearing notation is ambiguous, but the south-EAST reading is refuted
--     by its own measurement -- the vehicle station at (+6.0, -6.0) and all
--     four of its ring extremities read clean, identical slab). Hence the
--     PLANTER exclusion: no slot both west and south of the centre beyond
--     3 m. The open ground the survey names -- and the direction the outer
--     rings therefore grow into -- is west through south of the centre,
--     inside that wedge.
--
-- Slots past ring 2 (beyond ~4 m) stand on ground the survey walked past
-- rather than measured point by point; they are reached only once 13+
-- players share the lobby, and the owner's live sessions are the standing
-- verification. If one of them turns out to sit on furniture, cap it via
-- these constants -- overflow then simply reaches one ring further.
--
-- The two lobby stations are kept clear by radius: a player spawning INSIDE
-- the 2 m ready-up circle would enter the queue by standing still, which is
-- exactly why the config offsets the circle from the spawn in the first
-- place, and the vehicle picker's prompt has the same problem one arc over.
--
-- OCCUPANCY. A slot is held from the player's first lobby placement until he
-- is placed into a match (the countdown transition) or disconnects; the
-- leash, the dead-heal and the join-placement RETRY all re-place the same
-- player and get his SAME slot back (`byPlayer` first), so a retry can never
-- consume a second slot. The offset is captured at acquisition, so a spacing
-- retune moves future acquisitions only, never the spot a standing player
-- would be re-placed onto. A resource reload wipes the table like every other
-- local; players are re-adopted lazily and re-acquire on their next
-- placement, which in the worst case is exactly the pre-slot behaviour once.
local LOBBY_SLOT_MAX_EAST = 2.5
local LOBBY_SLOT_MAX_NORTH = 3.5
-- The planter sector: excluded when the offset is beyond this radius AND
-- west AND south of these two lines (see the survey note above).
local LOBBY_SLOT_PLANTER_WEST = -1.0
local LOBBY_SLOT_PLANTER_SOUTH = -1.0
local LOBBY_SLOT_PLANTER_RADIUS = 3.0
local LOBBY_SLOT_FURNITURE_CLEARANCE = 3.0
-- Candidate indices tried before falling back to the anchor. 400 spans ~11
-- rings; exhausting it needs on the order of a hundred simultaneous lobby
-- players on a 32-slot server, so the fallback is a log line about an
-- impossible day, not a path with gameplay riding on it.
local LOBBY_SLOT_SEARCH_LIMIT = 400

-- playerId -> { index, offset = {x, y} }, and the reverse. Two tables so both
-- "where is HE" and "is slot 7 free" are O(1); they are written together.
local lobbySlotByPlayer = {}
local lobbySlotOwner = {}

local function lobbySpawnSpacing()
    local spacing = tonumber(Tune.lobbySpawnSpacing) or 2.0
    if spacing < 0.5 then spacing = 0.5 end
    return spacing
end

-- Pure geometry: the offset of slot `index` at a given spacing. No state, so
-- the offline harness can assert the pairwise-distance guarantee directly.
local function lobbySlotOffset(index, spacing)
    if index <= 0 then return { x = 0.0, y = 0.0 } end
    local ring, first = 1, 1
    while true do
        local capacity = math.floor(2 * math.pi * ring)
        if index < first + capacity then
            local step = (2 * math.pi) / capacity
            local angle = (index - first) * step + (ring % 2) * (step / 2)
            local radius = ring * spacing
            return { x = math.cos(angle) * radius, y = math.sin(angle) * radius }
        end
        first = first + capacity
        ring = ring + 1
    end
end

-- The terrain filter -- the survey caps and the furniture keep-outs above.
local function lobbySlotUsable(offset)
    if offset.x > LOBBY_SLOT_MAX_EAST then return false end
    if offset.y > LOBBY_SLOT_MAX_NORTH then return false end
    if offset.x < LOBBY_SLOT_PLANTER_WEST and offset.y < LOBBY_SLOT_PLANTER_SOUTH and
        (offset.x * offset.x + offset.y * offset.y) >
        (LOBBY_SLOT_PLANTER_RADIUS * LOBBY_SLOT_PLANTER_RADIUS) then
        return false
    end
    local clearance = LOBBY_SLOT_FURNITURE_CLEARANCE * LOBBY_SLOT_FURNITURE_CLEARANCE
    local readyUp = Config.lobby.readyUp.offset
    local dx, dy = offset.x - readyUp.x, offset.y - readyUp.y
    if (dx * dx + dy * dy) < clearance then return false end
    local picker = Config.lobby.vehiclePicker and Config.lobby.vehiclePicker.offset
    if picker ~= nil then
        dx, dy = offset.x - picker.x, offset.y - picker.y
        if (dx * dx + dy * dy) < clearance then return false end
    end
    return true
end

-- The slot this player will be placed on: his own if he already holds one,
-- otherwise the lowest free index the terrain filter accepts.
local function acquireLobbySlot(playerId)
    local held = lobbySlotByPlayer[playerId]
    if held ~= nil then return held end
    local spacing = lobbySpawnSpacing()
    for index = 0, LOBBY_SLOT_SEARCH_LIMIT do
        if lobbySlotOwner[index] == nil then
            local offset = lobbySlotOffset(index, spacing)
            if lobbySlotUsable(offset) then
                local slot = { index = index, offset = offset }
                lobbySlotOwner[index] = playerId
                lobbySlotByPlayer[playerId] = slot
                return slot
            end
        end
    end
    log(("no free lobby slot for player %d within %d candidates; using the bare anchor"):format(
        playerId, LOBBY_SLOT_SEARCH_LIMIT))
    return { index = 0, offset = { x = 0.0, y = 0.0 } }
end

local function releaseLobbySlot(playerId)
    local slot = lobbySlotByPlayer[playerId]
    if slot == nil then return end
    lobbySlotByPlayer[playerId] = nil
    if lobbySlotOwner[slot.index] == playerId then
        lobbySlotOwner[slot.index] = nil
    end
end

-- A player who enters a match leaves his lobby spot behind, so the next
-- joiner may have it. `countdown` is the one transition every match entry
-- passes through (`startMatch` -> `beginCountdown`), and the async delivery
-- of a local TriggerEvent is fine here -- a slot freed a scheduler pass late
-- is still freed before anyone could need it.
AddEventHandler("pursuit:stateChanged", function(playerId, target)
    if target == "countdown" then releaseLobbySlot(playerId) end
end)

local function sendToLobby(playerId, reason)
    local centre = Config.lobby.center
    -- The slot, not the anchor. Same z for every slot -- the caps above are
    -- what make that honest.
    local slot = acquireLobbySlot(playerId)
    local placed = placeAt(playerId, {
        x = centre.x + slot.offset.x,
        y = centre.y + slot.offset.y,
        z = centre.z,
    }, Config.lobby.heading, Config.lobby.bucket,
        reason or "lobby")
    -- Announce from HERE, not from each caller. Every path that puts a player
    -- in the lobby -- join, the leash, `pursuit.lobby`, the return after a
    -- match -- goes through this one function, so tying the announcement to the
    -- placement makes "in the lobby" and "told about the lobby" the same event.
    -- The alternative was a client-side timer hedging against a caller that
    -- forgot, which is a worse thing to have to reason about than an invariant.
    if placed then
        log(("player %d -> lobby slot %d (%+.1f, %+.1f) for %s"):format(
            playerId, slot.index, slot.offset.x, slot.offset.y, tostring(reason or "lobby")))
        pushLobbyState(playerId)
    end
    return placed
end

-- The join-time placement, factored out because it now has TWO entry points: the
-- client's announcement (`pursuit:ready`) when the readiness gate is already open, and
-- `onPlayerReady` when it was not and the platform has since opened it.
local function joinPlacement(playerId, record)
    record.awaitingReady = nil
    -- The gate has opened, so this player becomes leash-judgeable at this line. Hand
    -- him a clean sheet and hold the leash off for the placement transaction HERE,
    -- above everything that can return early -- the re-announce debounce below returns
    -- without placing, and every failure path inside `placeAt` returns before its own
    -- reset. A player who became judgeable still carrying a timer from the character
    -- creator would be leashed for standing where nobody had yet moved him from.
    resetLeash(record)
    record.graceUntilMs = nowMs() + Config.lobby.placementGraceMs
    SetPlayerRoutingBucket(playerId, Config.lobby.bucket)

    -- worldReady fires more than once per session on the client, so this event
    -- arrives more than once. A second placement lands mid-transaction and the
    -- life authority rejects it with `transition_in_progress`; debounce instead
    -- of letting the log fill with failures.
    local now = nowMs()
    if record.placedAtMs ~= nil and (now - record.placedAtMs) < Config.lobby.placementGraceMs then
        pushLobbyState(playerId)
        return
    end
    record.placedAtMs = now
    -- `sendToLobby` announces the lobby on success. The failure path still has
    -- to: a client that asked to be placed and was refused must not be left
    -- with no ring and no way to see the queue circle.
    if sendToLobby(playerId, "join") then
        log(("player %d placed in the lobby"):format(playerId))
    else
        pushLobbyState(playerId)
    end
end

local function removeFromQueue(playerId)
    for index = #queue, 1, -1 do
        if queue[index] == playerId then table.remove(queue, index) end
    end
end

local function queuePosition(playerId)
    for index, id in ipairs(queue) do
        if id == playerId then return index end
    end
    return nil
end

local function broadcastQueue()
    for _, id in ipairs(queue) do
        TriggerClientEvent("pursuit:queueState", id, {
            queued = true,
            position = queuePosition(id),
            total = #queue,
        })
    end
    -- Matchmaking lives in server/match.lua and listens for this. Server
    -- resources cannot call each other, but files inside one resource share a
    -- Lua state, so a local event is the seam between the two concerns.
    TriggerEvent("pursuit:queueChanged", #queue)
end

-- ---------------------------------------------------------------- lifecycle --

AddEventHandler("onPlayerConnected", function(playerIdStr)
    local playerId = tonumber(playerIdStr)
    if playerId == nil or playerId <= 0 then return end
    players[playerId] = {
        state = "lobby",
        sinceMs = nowMs(),
        outsideSinceMs = nil,
        warned = false,
        -- The same grace `ensurePlayer` grants an adopted player, and it was missing
        -- here. Without it `graceUntilMs` is nil, which the leash reads as ALREADY
        -- SETTLED -- so a player who has just connected, and who has certainly not been
        -- placed anywhere, was judgeable on the very next tick 200 ms later. The
        -- readiness gate in the leash is the real fix; this is the belt to its braces,
        -- and it costs an honest joiner nothing he was not already getting.
        graceUntilMs = nowMs() + Config.lobby.placementGraceMs,
    }
    -- THE BUCKET WRITE STAYS UNGATED, deliberately. The platform's rule is "do not
    -- teleport, spawn, kill or force a respawn on a player before their gate opens"
    -- (docs/writing-a-gamemode.md 2.8) -- a routing-bucket assignment does none of
    -- those: it moves nobody, interrupts nothing, and is issued here before the client
    -- has a world at all, which is the safest moment it could happen. What it does do
    -- is put the joiner in this mode's dimension, so that whatever incarnates him does
    -- so among the right people rather than alone in bucket 0. `joinPlacement`
    -- re-asserts it once the gate opens.
    SetPlayerRoutingBucket(playerId, Config.lobby.bucket)
    log(("player %d joined -> bucket %d"):format(playerId, Config.lobby.bucket))
end)

AddEventHandler("onPlayerDisconnected", function(playerIdStr)
    local playerId = tonumber(playerIdStr)
    if playerId == nil then return end
    -- Announce before dropping the record: matchmaking needs to read the
    -- player's match id to release the bucket and credit the survivor.
    TriggerEvent("pursuit:playerGone", playerId)
    removeFromQueue(playerId)
    releaseLobbySlot(playerId)
    players[playerId] = nil
    broadcastQueue()
end)

-- The client announces that its world is up and its POIs are drawn. Placement
-- happens here rather than on connect because a respawn issued before the
-- world exists is dropped.
--
-- ------------------------------------------------------------------------
-- THIS EVENT IS NOT A WORLD TRANSITION
-- ------------------------------------------------------------------------
--
-- It used to be treated as one, and that was a production defect rather than a
-- dev-loop annoyance. `pursuit:ready` is relayed from the client's
-- `open77:worldReady`, and the client emits that UNCONDITIONALLY every time it
-- swaps its resource host -- which it does on ANY resource republish, including
-- one that has nothing to do with Pursuit. The old handler answered by calling
-- `SetPlayerRoutingBucket(playerId, Config.lobby.bucket)` on line one, before
-- any state check at all, and then placing the player in the lobby.
--
-- Measured, not inferred: match 886843 was created at 13:30:35 in bucket 2000;
-- an unrelated CSS file was deleted from `open77_blips` at 13:30:39; at
-- 13:30:42.330 the log read `Player 1 moved from routing bucket 2000 to 1000`.
-- A player was pulled out of a car chase by another resource's stylesheet. On a
-- live server the same edit -- an owner fixing a typo in a HUD -- evicts every
-- player from every match in progress.
--
-- `Config.lobby.placementGraceMs` did NOT cover this, and must not be relied on
-- to: the debounce below short-circuits the log line and `sendToLobby`, but the
-- old bucket write happened ABOVE it and fired regardless.
--
-- So the handler now asks who this player is before it moves anything:
--
--   1. he belongs to a match  -> keep his bucket, re-prime his client, return.
--      A republish destroyed his Lua state, not his match.
--   2. he thinks he is in a match and there is none -> the match ended during
--      the swap; unstick him rather than leaving him in a released bucket.
--   3. lobby or queued -> the original path, unchanged.
RegisterNetEvent("pursuit:ready", function()
    local playerId = source
    local record = ensurePlayer(playerId)
    if record == nil then return end

    -- Case 1. The match record is the authority on where this player belongs,
    -- ahead of the roster state: `playerMatch` is written when the match is
    -- created and cleared when it is released, so it cannot claim someone the
    -- match code has already let go.
    local match = Pursuit.matchOf ~= nil and Pursuit.matchOf(playerId) or nil
    if match ~= nil then
        -- The bucket is RE-ASSERTED only when it demonstrably disagrees, never
        -- re-written blindly. A routing-bucket transfer is the least reliable
        -- step in the whole loop (plan §7b) and has crashed clients; setting a
        -- player to the bucket he is already in would be all of that risk for
        -- none of the benefit. An unreadable bucket means "do not judge": the
        -- server never moved him, so he is where the match put him.
        local position = Open77.players.position(playerId)
        if position ~= nil and position.bucket ~= match.bucket then
            log(("player %d re-announced in bucket %s but belongs to match %d's bucket %d; re-asserting"):format(
                playerId, tostring(position.bucket), match.id, match.bucket))
            SetPlayerRoutingBucket(playerId, match.bucket)
        end

        -- Re-prime the client. Keeping the bucket without this is its own bad
        -- outcome: the republished VM drew the LOBBY furniture from
        -- `onClientResourceStart` (it has no idea a match is on) and its HUD
        -- state is blank, so the player would be in a chase looking at a
        -- ready-up prompt and no clock. One `pursuit:matchState` fixes both --
        -- the client tears the lobby down on the first non-resolved push, and
        -- `pursuit_hud` re-anchors from the same payload.
        local primed = Pursuit.repushMatchTo ~= nil and Pursuit.repushMatchTo(playerId) or false
        log(("player %d re-announced during match %d [%s]; bucket %d KEPT (not evicted to the lobby), client %s"):format(
            playerId, match.id, tostring(match.state), match.bucket,
            primed and "re-primed" or "NOT re-primed -- Pursuit.repushMatchTo missing"))
        return
    end

    -- Case 2. No match claims him, but he is not in a lobby state either: the
    -- match ended while his client was being swapped and nothing will ever come
    -- back for him. Left alone he would sit in a released match bucket, alone
    -- in a dimension with no rules running.
    if record.state ~= "lobby" and record.state ~= "queued" then
        log(("player %d re-announced as '%s' with no match; returning him to the lobby"):format(
            playerId, tostring(record.state)))
        transition(playerId, "lobby", "ready_orphan")
        -- Bypass the debounce below on purpose. It exists to stop a redundant
        -- announce from stacking placements; a stranded player is the one case
        -- where NOT placing is worse than placing twice.
        record.placedAtMs = nil
    end

    -- Case 3. The original path -- but not before the platform says this player may
    -- be acted upon at all.
    --
    -- A placement here is a kill followed by a respawn, which is about the most
    -- disruptive thing that can be done to someone who is still in a modal they have
    -- to finish. On 2026-08-27, with the database enabled for the ranked ladder,
    -- `open77_appearance` was opening the character creator for every new player from
    -- the very same client announcement that reaches this handler, and the server was
    -- unusable. The gate is the platform's answer: `open77_appearance` holds it while
    -- it needs the player, everything else waits, and the host reopens it -- with a
    -- named warning in the log -- even if that resource dies without releasing.
    --
    -- This costs a returning player nothing: with no character to create the hold is
    -- released the moment appearance has looked them up, and the check below simply
    -- passes.
    if not readyToBeActedUpon(playerId) then
        record.awaitingReady = true
        log(("player %d announced but is not ready yet; deferring the lobby placement"):format(playerId))
        return
    end

    joinPlacement(playerId, record)
end)

-- Place a player whose gate has just opened, retrying until the life authority can
-- actually see them.
--
-- WHY THIS RETRIES, AND WHY THE OLD CODE DEADLOCKED. This handler used to refuse when
-- `getLifeState` came back nil and leave `awaitingReady` set, on the reasoning that the
-- player's next `pursuit:ready` would find the gate open. There is no next
-- `pursuit:ready`. The client announces once per VM (`announced` in client/main.lua)
-- and the world handoff does NOT rebuild that VM -- measured 2026-08-27 03:58:54.907,
-- `worldReady again; already announced`. So "wait for the next announce" meant "wait
-- forever", and forever is what the first player who reached that branch got: connected,
-- in a bucket, never placed, standing in an empty world with another player nameplate
-- floating in it. That is the void the owner reported.
--
-- The refusal itself is now belt-and-braces rather than the load-bearing check, because
-- the gate only opens once the platform has confirmed the player is incarnated. It is
-- kept because placing a player the life authority cannot see fails with
-- `player_not_found` and would leave them exactly as stranded, and because a gate that
-- opened for a reason OTHER than incarnation -- a participant crashing, a resource
-- being stopped -- can still land here early.
--
-- Same shape as freeroam's `applyJoinSpawn`: retry on the two transient refusals, give
-- up loudly on anything else, and never depend on an event to come back.
local function placeWhenPlaceable(playerId, record, detail, startedMs)
    if players[playerId] ~= record or record.awaitingReady ~= true then return end
    if Open77.players.getLifeState(playerId) ~= nil then
        joinPlacement(playerId, record)
        return
    end
    local waitedMs = nowMs() - startedMs
    if waitedMs >= Config.lobby.placementRetryTimeoutMs then
        record.awaitingReady = nil
        log(("player %d gate opened (%s) but the life authority never saw them after %dms; giving up on the join placement")
            :format(playerId, tostring(detail), math.floor(waitedMs)))
        return
    end
    if waitedMs == 0 then
        log(("player %d gate opened (%s) but no life state yet; retrying every %dms"):format(
            playerId, tostring(detail), Config.lobby.placementRetryMs))
    end
    SetTimeout(Config.lobby.placementRetryMs, function()
        placeWhenPlaceable(playerId, record, detail, startedMs)
    end)
end

-- The other half of the barrier: the platform has opened this player's gate, either
-- because everyone holding them is finished or because a hold expired.
--
-- Nothing happens for a player this resource was not already waiting on, so a gate
-- that opens for someone mid-match -- or for someone this handler never deferred --
-- is ignored. `onPlayerReady` is a permission, never a trigger: it says nothing about
-- whether the player's world is up, which is why the wait always starts from
-- `pursuit:ready` and never from here.
AddEventHandler("onPlayerReady", function(playerIdStr, detail)
    local playerId = tonumber(playerIdStr)
    if playerId == nil or playerId <= 0 then return end
    local record = players[playerId]
    if record == nil or record.awaitingReady ~= true then return end
    log(("player %d gate opened (%s); placing"):format(playerId, tostring(detail)))
    placeWhenPlaceable(playerId, record, detail, nowMs())
end)

-- ------------------------------------------------------------------- queue --

-- Shared by the in-world prompt and by `pursuit.queue`. The containment check
-- lives here so the test path cannot accidentally bypass the rule it is meant
-- to be testing.
local function toggleQueue(playerId)
    local record = ensurePlayer(playerId)
    if record == nil then return end

    if record.state == "queued" then
        removeFromQueue(playerId)
        transition(playerId, "lobby", "left_queue")
        TriggerClientEvent("pursuit:queueState", playerId, { queued = false })
        broadcastQueue()
        Open77.notifications.send(playerId, {
            type = "info",
            title = "Queue",
            message = "You left the queue.",
            durationMs = 3000,
        })
        return
    end

    if record.state ~= "lobby" then
        if Config.debug.verboseQueue then
            log(("queue refused for %d: state=%s"):format(playerId, tostring(record.state)))
        end
        return
    end

    -- The intent carries no position: the client cannot be trusted to report
    -- where it stands, so the check is re-derived from replicated state.
    local inside, detail = containsPlayer(
        playerId,
        readyUpPosition(),
        Config.lobby.readyUp.radius,
        Config.lobby.bucket)

    if not inside then
        if Config.debug.verboseQueue then
            log(("queue REFUSED for %d: %s"):format(playerId, tostring(detail)))
        end
        Open77.notifications.send(playerId, {
            type = "error",
            title = "Queue",
            message = "Stand in the circle to queue.",
            durationMs = 3500,
        })
        return
    end

    if not transition(playerId, "queued", "ready_up") then return end
    queue[#queue + 1] = playerId
    if Config.debug.verboseQueue then
        log(("queue accepted for %d at %.1fm; queue=%d"):format(
            playerId, tonumber(detail) or -1, #queue))
    end
    broadcastQueue()
    Open77.notifications.send(playerId, {
        type = "success",
        title = "Queue",
        message = ("In queue -- %d/%d"):format(#queue, Config.match.size),
        durationMs = 3500,
    })
end

RegisterNetEvent("pursuit:queueIntent", function()
    toggleQueue(source)
end)

-- Test affordance: same code path, same containment check, no prompt.
RegisterCommand("pursuit.queue", function(source, _, raw)
    if source == nil or source <= 0 then
        return output(source, raw, false, "pursuit.queue must be issued in-game")
    end
    toggleQueue(source)
    local record = players[source]
    output(source, raw, true, ("queue toggled; state=%s queue=%d"):format(
        record and record.state or "?", #queue))
end, false)

-- ------------------------------------------------------- stranded-dead heal --
--
-- A player can be standing in the lobby, walking around, `alive=yes` on his own
-- client -- and be DEAD in the life authority. Measured 2026-08-26, on every
-- first connection of a session:
--
--   life 3: bucket=1000 health=0.0099999997764826 phase=dead revision=7
--           position={x=-699.09, y=2164.29, z=53.10}
--
-- That is the pristine-save position, 1.5 km from the lobby he is standing in.
--
-- How it happens. `pursuit:ready` fires when the client's WORLD is up, which is
-- before the player has crossed the "press any key to continue" gate -- and a
-- life transition cannot be applied natively while that gate is up. The
-- placement's kill -> respawn therefore sits in `respawn_pending` until the
-- life authority's 10 s apply timeout expires and reverts it to
-- `Dead, Health = 0.01`. Crossing the gate took ~20 s in the measured runs, so
-- the timeout always won.
--
-- What the player then sees, and it is all one bug:
--   * his own client applies the Dead state as the soft-death health floor --
--     `health=1` out of 100, with the full-screen red damage vignette;
--   * every OTHER client applies it as a corpse: `life ragdoll-armed`, ragdoll
--     placed on the canonical death position -- so his body and his nameplate
--     are 1.5 km away and he is invisible to everyone standing next to him;
--   * it clears on the first match placement, because by then the client is
--     live and the same transaction applies inside the timeout. That is why it
--     reads as "the first session is broken and then it is fine".
--
-- The heal is deliberately here and not in the client. The failure is "a
-- transaction was dropped", and the honest server-side answer to a dropped
-- transaction is to notice and reissue it. Re-placing a lobby player who is
-- canonically dead is also just correct on its own terms: nobody should be a
-- corpse in the lobby.
--
-- Guards, all of them load-bearing: only lobby/queued players (a match member
-- belongs to the match code and its death guard); only past the placement
-- grace, so an in-flight transaction is never interrupted; and a cooldown plus
-- an attempt cap, so a genuinely unfixable player produces one line and not a
-- placement every tick.
-- Longer than the life authority's own 10 s apply timeout, ON PURPOSE. A heal
-- issued while the previous respawn is still `respawn_pending` is refused
-- (`transition_in_progress`) or, worse, times out in its turn -- so the cooldown
-- has to outlast the thing it is retrying. Measured with 8 s: the first attempt
-- fired 0.13 s after the join, before the client could possibly apply anything,
-- and was pure waste; the second, 17 s later, is the one that worked.
local DEAD_HEAL_COOLDOWN_MS = 12000
-- Five attempts at 12 s is a minute of patience. The window that has to be
-- covered is "how long until the player presses a key on the continue screen",
-- which is a human, not a machine.
local DEAD_HEAL_MAX_ATTEMPTS = 5

local function healStrandedDead(playerId, record)
    local life = Open77.players.getLifeState(playerId)
    if life == nil or life.phase ~= "dead" then
        -- Alive again (or unreadable): forget the history so a later, unrelated
        -- occurrence gets its own full budget of attempts.
        if record.deadHealAttempts ~= nil then
            log(("player %d recovered from being canonically dead in the lobby after %d re-placement(s)"):format(
                playerId, record.deadHealAttempts))
        end
        record.deadHealAttempts = nil
        record.deadHealAtMs = nil
        record.deadHealGaveUp = nil
        return false
    end
    -- There is deliberately NO "is he incarnate yet" pre-check here.
    --
    -- The obvious one -- skip while `Open77.players.position` is nil, on the
    -- theory that a body that does not exist cannot be re-placed -- was tried
    -- on 2026-08-26 and made the bug UNFIXABLE: the server has no position for
    -- a canonically dead player, so the guard silenced the heal for precisely
    -- the players it exists to rescue. One attempt fired during a brief window
    -- where the position happened to read, and then nothing, forever. The
    -- cooldown below is the only pacing needed, and it is sized against the
    -- life authority's own timeout rather than against a guess about the
    -- client.
    local now = nowMs()
    if record.deadHealAtMs ~= nil and (now - record.deadHealAtMs) < DEAD_HEAL_COOLDOWN_MS then
        return false
    end
    local attempts = (record.deadHealAttempts or 0) + 1
    if attempts > DEAD_HEAL_MAX_ATTEMPTS then
        if not record.deadHealGaveUp then
            record.deadHealGaveUp = true
            log(("player %d is canonically dead in the lobby and %d re-placement(s) did not fix it; leaving it alone"):format(
                playerId, DEAD_HEAL_MAX_ATTEMPTS))
        end
        return false
    end
    record.deadHealAttempts = attempts
    record.deadHealAtMs = now
    log(("player %d is standing in the lobby but canonically DEAD (health=%.2f at %.0f,%.0f,%.0f -- the pristine position, not the lobby); re-placing, attempt %d/%d"):format(
        playerId, life.health or 0.0,
        life.position and life.position.x or 0.0,
        life.position and life.position.y or 0.0,
        life.position and life.position.z or 0.0,
        attempts, DEAD_HEAL_MAX_ATTEMPTS))
    return sendToLobby(playerId, "dead_in_lobby")
end

-- -------------------------------------------------------------------- leash --

CreateThread(function()
    local intervalMs = math.floor(1000 / math.max(1, Config.tickHz))
    while true do
        Wait(intervalMs)
        local centre = Config.lobby.center
        for playerId, record in pairs(players) do
            local inLobby = record.state == "lobby" or record.state == "queued"

            -- THE READINESS GATE IS THE FIRST TEST, ahead of the grace and ahead of the
            -- state. A player the platform has not released is not a player this rule
            -- may JUDGE -- not merely one it may not teleport. No containment read, no
            -- warning toast, and above all no timer: being told "return to the lobby"
            -- while choosing a face is already a broken experience, and an
            -- `outsideSinceMs` accumulated during character creation would fire the
            -- moment the gate opened.
            --
            -- Two conditions, because the window is wider than the gate itself:
            --   * the gate is shut -- appearance still has him; and
            --   * `awaitingReady`, which stays set after the gate opens and until
            --     `joinPlacement` actually runs. `onPlayerReady` leaves it set on
            --     purpose when the player has no life state yet -- a hold that timed
            --     out opens the gate on someone still sitting in the creator. Between
            --     those two moments he is released but never placed, standing at the
            --     pristine spawn, and the leash would drag him in and call it
            --     enforcement.
            --
            -- The reset runs on every exempt tick rather than on an edge, because this
            -- loop has no edge to hang it on: the gate opens inside the host and is
            -- only ever observed here. Clearing it each pass makes the state fresh by
            -- construction, and `joinPlacement` clears it again on the way in.
            local exempt = record.awaitingReady == true or not readyToBeActedUpon(playerId)
            if exempt then
                resetLeash(record)
                if not record.leashExempt then
                    record.leashExempt = true
                    log(("player %d exempt from the lobby leash: readiness gate still closed"):format(
                        playerId))
                end
            elseif record.leashExempt then
                record.leashExempt = nil
                log(("player %d is ready; the lobby leash is live for him again"):format(playerId))
            end

            local settled = (not exempt) and
                (record.graceUntilMs == nil or nowMs() >= record.graceUntilMs)
            if settled and inLobby then
                -- A successful heal re-arms the placement grace, so re-read it:
                -- the leash below must not judge a player who was re-placed a
                -- millisecond ago -- that is the exact self-inflicted warning
                -- the grace exists to prevent.
                healStrandedDead(playerId, record)
                settled = record.graceUntilMs == nil or nowMs() >= record.graceUntilMs
            end
            if settled and inLobby then
                local inside, detail = containsPlayer(
                    playerId, centre, Tune.lobbyRadius, Config.lobby.bucket)
                if detail == "unknown" then
                    -- Cannot tell: leave the timer untouched rather than
                    -- counting an unreadable player as an absent one.
                elseif inside then
                    -- Through `resetLeash`, not field writes: coming back
                    -- inside must also clear the seated-return bookkeeping, or
                    -- a driver who returned on his own keeps a spent reclaim
                    -- budget and a stale settle gate for his next excursion.
                    resetLeash(record)
                else
                    local now = nowMs()
                    record.outsideSinceMs = record.outsideSinceMs or now
                    local elapsed = (now - record.outsideSinceMs) / 1000.0

                    if not record.warned and elapsed >= Tune.leashWarnSeconds then
                        record.warned = true
                        Open77.notifications.send(playerId, {
                            type = "warning",
                            title = "Lobby",
                            message = "Return to the lobby.",
                            durationMs = 4000,
                        })
                    end

                    if elapsed >= Tune.leashReturnSeconds then
                        -- THE SEATED DRIVER IS NEVER RETURNED BY THE RESPAWN.
                        -- Tonight's owner report ("I feel disconnected when I
                        -- wander off and get re-teleported... maybe because I
                        -- was in a moving vehicle") was exactly this branch
                        -- firing on a driver: the respawn was absorbed, and
                        -- ~2 s later the server kicked him --
                        -- `invalid_vehicle_control:playerunavailable`, twice,
                        -- 03:23:15.601 and 03:30:23.217 (see the note on
                        -- `seatedVehicleOf` for the whole chain). So while a
                        -- vehicle holds his seat, the leash acts on the SEAT:
                        --
                        --   * a car this resource owns is reclaimed -- pursuit
                        --     spawned it, and a runaway lobby car should come
                        --     back regardless. Removing it clears the seat and
                        --     the client dismounts; the settle below outlasts
                        --     the dismount so the respawn never lands mid-exit;
                        --   * a car another resource owns cannot be touched --
                        --     `Open77.vehicles.remove` is ownership-checked --
                        --     and there is NO safe way to move its driver
                        --     (no unseat primitive; a respawn is the measured
                        --     disconnect above). He is told to step out, on a
                        --     cadence, and the return fires the moment the
                        --     occupancy ledger says he is on foot -- the timer
                        --     stays expired, so the dismount IS the return.
                        local seated = seatedVehicleOf(playerId)
                        if seated ~= nil then
                            local now2 = nowMs()
                            if seated.resource == GetCurrentResourceName() and
                                record.seatedReclaimedVehicleId ~= seated.id then
                                -- Once per vehicle: a removal that fails must
                                -- not be retried every 200 ms tick.
                                record.seatedReclaimedVehicleId = seated.id
                                local ok, removed = pcall(Open77.vehicles.remove, seated.id)
                                if ok and removed then
                                    record.seatedSettleUntilMs = now2 + SEATED_RETURN_SETTLE_MS
                                    log(("player %d is leash-overdue seated in own vehicle %s; reclaimed it, placing after the dismount settles"):format(
                                        playerId, tostring(seated.id)))
                                    Open77.notifications.send(playerId, {
                                        type = "warning",
                                        title = "Lobby",
                                        message = "Vehicle reclaimed -- returning you to the lobby.",
                                        durationMs = 4000,
                                    })
                                else
                                    log(("player %d leash-overdue seated in own vehicle %s but the reclaim failed (%s); treating it as foreign"):format(
                                        playerId, tostring(seated.id), tostring(removed)))
                                end
                            end
                            if record.seatedWarnedAtMs == nil or
                                (now2 - record.seatedWarnedAtMs) >= SEATED_RETURN_WARN_INTERVAL_MS then
                                record.seatedWarnedAtMs = now2
                                if record.seatedSettleUntilMs == nil then
                                    log(("player %d is leash-overdue but seated in vehicle %s (owner %s); waiting for him to dismount"):format(
                                        playerId, tostring(seated.id), tostring(seated.resource)))
                                    Open77.notifications.send(playerId, {
                                        type = "warning",
                                        title = "Lobby",
                                        message = "Leave the vehicle to return to the lobby.",
                                        durationMs = 4000,
                                    })
                                end
                            end
                        elseif nowMs() >= (record.seatedSettleUntilMs or 0) then
                            resetLeash(record)
                            if record.state == "queued" then
                                removeFromQueue(playerId)
                                transition(playerId, "lobby", "leash")
                                broadcastQueue()
                            end
                            log(("player %d leashed back to the lobby"):format(playerId))
                            sendToLobby(playerId, "leash")
                        end
                    end
                end
            end
        end
    end
end)

-- ----------------------------------------------------------------- commands --

RegisterCommand("pursuit.status", function(source, _, raw)
    local total, byState = 0, {}
    for _, record in pairs(players) do
        total = total + 1
        byState[record.state] = (byState[record.state] or 0) + 1
    end
    local parts = {}
    for state, count in pairs(byState) do
        parts[#parts + 1] = ("%s=%d"):format(state, count)
    end
    table.sort(parts)
    output(source, raw, true, ("%d player(s) [%s]; queue=%d/%d; lobby bucket=%d at %.1f,%.1f,%.1f r=%.0f"):format(
        total,
        #parts > 0 and table.concat(parts, " ") or "none",
        #queue, Config.match.size,
        Config.lobby.bucket,
        Config.lobby.center.x, Config.lobby.center.y, Config.lobby.center.z,
        Tune.lobbyRadius))
end, false)

-- Diagnostic: print exactly what the server sees for a player, so a
-- containment refusal can be read rather than guessed at.
--
-- The context is the player's OWN, never assumed to be the lobby. It used to
-- measure every player against the lobby circle and the lobby bucket, so a
-- player correctly transferred into a match bucket was reported as
-- `want 1000 ... detail=wrong_bucket` -- the one token the protocol says must
-- never appear, printed by the instrument rather than by the rules. Two agents
-- have chased that token as a replication fault. The rules were right; the
-- readout was measuring against the wrong world.
local function contextFor(playerId)
    local match = Pursuit.matchOf and Pursuit.matchOf(playerId) or nil
    if match ~= nil and match.state ~= "resolved" then
        -- In a match the containment rule that applies is the ARENA, and it is
        -- PLANAR by design -- see bounds.lua. The lobby circle has no authority
        -- over a player 1.3 km away playing the mode exactly as intended.
        return {
            name = ("match %d [%s] as %s"):format(match.id, tostring(match.state),
                tostring(match.roles and match.roles[playerId])),
            bucket = match.bucket,
            centre = Config.arena.center,
            radius = Config.arena.radius,
            rule = Config.arena.enabled and "arena" or "arena(disabled)",
            planarOnly = true,
        }
    end
    return {
        name = "lobby",
        bucket = Config.lobby.bucket,
        centre = Config.lobby.center,
        radius = Tune.lobbyRadius,
        rule = "lobby leash",
        planarOnly = false,
    }
end

-- The slot ledger, for reading a "they spawned apart" claim off the server
-- instead of eyeballing it: which player holds which slot, at what offset.
RegisterCommand("pursuit.slots", function(source, _, raw)
    local indices = {}
    for index in pairs(lobbySlotOwner) do indices[#indices + 1] = index end
    table.sort(indices)
    local parts = {}
    for _, index in ipairs(indices) do
        local playerId = lobbySlotOwner[index]
        local slot = lobbySlotByPlayer[playerId]
        parts[#parts + 1] = ("%d:player %d (%+.1f, %+.1f)"):format(
            index, playerId,
            slot and slot.offset.x or 0.0, slot and slot.offset.y or 0.0)
    end
    output(source, raw, true,
        ("%d lobby slot(s) held, spacing %.1fm -- %s"):format(
            #indices, lobbySpawnSpacing(),
            #parts > 0 and table.concat(parts, "; ") or "none"))
end, false)

RegisterCommand("pursuit.where", function(source, args, raw)
    local playerId = tonumber(args and args[1]) or source
    if playerId == nil or playerId <= 0 then
        return output(source, raw, false, "usage: pursuit.where [playerId]")
    end
    local position = Open77.players.position(playerId)
    if position == nil then
        -- Say WHY, and in particular say the LIFE PHASE, because that is
        -- almost always the answer and a bare "position unavailable" reads as
        -- a server fault instead.
        --
        -- The server's position is a replicated player snapshot no older than
        -- 2 s, and a client stops sending snapshots entirely while its life
        -- phase is dead / revive_pending / respawn_pending -- the same
        -- condition the server uses to discard them. A client parked on the
        -- "press any key to continue" screen is exactly that: the join-time
        -- lobby placement kills and respawns him, and the respawn cannot
        -- complete until the shell hands the world over, so the phase sticks
        -- and he has no position at all until something incarnates him.
        --
        -- Measured 2026-08-26: players 16 and 18 each read "position
        -- unavailable" for over a minute after joining, and both started
        -- reporting the instant a `pursuit.tpcircle` placement completed. It
        -- was read as a replication fault and cost an hour. It is not a fault:
        -- there is genuinely no live position for a player who is not in the
        -- world, and the life phase says so out loud.
        --
        -- Falling back to `getLifeState().position` was considered and is
        -- wrong: that is the last PLACEMENT's position, not a live one -- it
        -- read -699,2164 for a player standing at -1460,99 -- so containment
        -- would judge a coordinate the player left minutes ago. "Cannot tell"
        -- is the honest answer; naming the reason is the fix.
        local record = Pursuit.players[playerId]
        local life = Open77.players.getLifeState(playerId)
        return output(source, raw, false,
            ("player %d: position unavailable -- no player snapshot in the last 2s; " ..
             "lifePhase=%s state=%s (a client that is not incarnated -- the \"continue\" " ..
             "screen -- sends none)"):format(
                playerId, life and tostring(life.phase) or "unreadable",
                record and tostring(record.state) or "not-tracked"))
    end
    local context = contextFor(playerId)
    local centre = context.centre
    local dx, dy, dz = position.x - centre.x, position.y - centre.y, position.z - centre.z
    local planar = math.sqrt(dx * dx + dy * dy)
    local bucketOk = position.bucket == context.bucket

    local verdict, detail
    if not bucketOk then
        verdict, detail = false, "wrong_bucket"
    elseif context.planarOnly then
        verdict = planar <= context.radius
        detail = ("%.1fm of %.0fm"):format(planar, context.radius)
    else
        verdict, detail = containsPlayer(playerId, centre, context.radius, context.bucket)
    end

    output(source, raw, true,
        ("player %d: context=%s pos=%.1f,%.1f,%.1f bucket=%s (want %d) rule=%s planar=%.1f dz=%.1f inside=%s detail=%s"):format(
            playerId, context.name, position.x, position.y, position.z,
            tostring(position.bucket), context.bucket, context.rule,
            planar, dz, tostring(verdict), tostring(detail)))
end, false)

-- Diagnostic: dump the raw life-state table the server reads. The whole
-- gamemode rests on `weapon` surviving a placement (see downedByPlay in
-- server/match.lua), and that is a claim about the native surface, not about
-- this Lua. It has to be readable, not assumed.
RegisterCommand("pursuit.life", function(source, args, raw)
    local playerId = tonumber(args and args[1]) or source
    if playerId == nil or playerId <= 0 then
        return output(source, raw, false, "usage: pursuit.life [playerId]")
    end
    local life = Open77.players.getLifeState(playerId)
    if life == nil then
        return output(source, raw, false, ("player %d: life state unavailable"):format(playerId))
    end
    local keys = {}
    for key in pairs(life) do keys[#keys + 1] = key end
    table.sort(keys)
    local parts = {}
    for _, key in ipairs(keys) do
        local value = life[key]
        if type(value) == "table" then
            value = ("{x=%s,y=%s,z=%s}"):format(
                tostring(value.x), tostring(value.y), tostring(value.z))
        end
        parts[#parts + 1] = ("%s=%s"):format(key, tostring(value))
    end
    output(source, raw, true, ("life %d: %s"):format(playerId, table.concat(parts, " ")))
end, false)

-- Diagnostic: place the caller and then watch the life state for 14 s.
-- Proves, or disproves, that `weapon` carries the placement marker for the
-- whole dead -> respawn_pending -> recovering -> alive trajectory.
RegisterCommand("pursuit.lifetrace", function(source, _, raw)
    if source == nil or source <= 0 then
        return output(source, raw, false, "pursuit.lifetrace must be issued in-game")
    end
    local playerId = source
    local startMs = nowMs()

    -- Read the state SYNCHRONOUSLY across the transaction, before handing it to
    -- a sampler.
    --
    -- A sampling thread cannot answer this question on its own: `CreateThread`
    -- does not run inline, so its first reading already lands ~30 ms after the
    -- placement and shows respawnpending -- the `dead` step, the one the guard
    -- is written against, has already gone by. Three inline reads bracket the
    -- two transitions exactly and cannot miss anything.
    local function snap(tag)
        local life = Open77.players.getLifeState(playerId)
        log(("lifetrace[%s] phase=%s weapon='%s' cause=%s revision=%s downedByPlay=%s"):format(
            tag,
            life and tostring(life.phase) or "nil",
            life and tostring(life.weapon or "") or "nil",
            life and tostring(life.cause) or "nil",
            life and tostring(life.revision) or "nil",
            tostring(Pursuit.downedByPlay and Pursuit.downedByPlay(playerId))))
        return life
    end

    snap("before")
    local killed, killError = Open77.players.kill(playerId, {
        cause = "script",
        weapon = "pursuit:lifetrace",
    })
    log(("lifetrace[kill] ok=%s err=%s"):format(tostring(killed), tostring(killError)))
    snap("after-kill")
    local centre = Config.lobby.center
    local respawned, respawnError = Open77.players.respawn(playerId, {
        position = { x = centre.x, y = centre.y, z = centre.z },
        heading = Config.lobby.heading,
        bucket = Config.lobby.bucket,
        health = 1.0,
        graceMs = 5000,
    })
    log(("lifetrace[respawn] ok=%s err=%s"):format(tostring(respawned), tostring(respawnError)))
    snap("after-respawn")
    local record = players[playerId]
    if record ~= nil then
        record.graceUntilMs = nowMs() + Config.lobby.placementGraceMs
        record.placedAtMs = nowMs()
        record.outsideSinceMs = nil
        record.warned = false
    end

    CreateThread(function()
        -- Sample fast, log on CHANGE only.
        --
        -- Two reasons, both learned the hard way. The dead -> respawn_pending
        -- window of a placement is short -- the first attempt sampled at 250 ms
        -- and never once caught it, so the trace showed only `recovering` and
        -- proved nothing about the phases downedByPlay actually tests. And log
        -- writes are file I/O on the Lua frame budget (plan 7c), so a 50 ms
        -- sampler that printed every reading would be measuring mostly itself.
        -- Buffer, print transitions.
        local lastKey, samples, deadSeen, deadTagged = nil, 0, 0, 0
        while (nowMs() - startMs) < 14000 do
            local life = Open77.players.getLifeState(playerId)
            local down = Pursuit.downedByPlay and Pursuit.downedByPlay(playerId)
            local position = Open77.players.position(playerId)
            local phase = life and tostring(life.phase) or "nil"
            local weapon = life and tostring(life.weapon or "") or "nil"
            samples = samples + 1
            -- The exact set downedByPlay judges on. A placement that left
            -- `weapon` empty in ANY of these would end a match on its own
            -- spawn, which is the whole reason this command exists.
            if phase == "dead" or phase == "revivepending" or phase == "respawnpending" or
                phase == "revive_pending" or phase == "respawn_pending" then
                deadSeen = deadSeen + 1
                if weapon:sub(1, 8) == "pursuit:" then deadTagged = deadTagged + 1 end
            end
            local key = ("%s|%s|%s"):format(phase, weapon, tostring(down))
            if key ~= lastKey then
                lastKey = key
                log(("lifetrace +%5dms phase=%s weapon='%s' cause=%s downedByPlay=%s pos=%s bucket=%s"):format(
                    nowMs() - startMs, phase, weapon,
                    life and tostring(life.cause) or "nil",
                    tostring(down),
                    position and ("%.1f,%.1f,%.1f"):format(position.x, position.y, position.z) or "nil",
                    position and tostring(position.bucket) or "nil"))
            end
            Wait(50)
        end
        log(("lifetrace done -- %d samples, %d in a downed phase, %d of those tagged pursuit: (%s)"):format(
            samples, deadSeen, deadTagged,
            (deadSeen > 0 and deadSeen == deadTagged) and "GUARD HOLDS"
                or (deadSeen == 0 and "INCONCLUSIVE: never sampled a downed phase"
                    or "GUARD BROKEN: an untagged downed phase would end a match")))
    end)
    output(source, raw, true, "lifetrace started")
end, false)

-- Diagnostic: teleport to a candidate spawn and watch where the player
-- actually ends up. An authored spawn point is a claim about the ground, and
-- the only way to check it is to stand on it and watch z stop changing --
-- a respawn "succeeds" just as happily into a wall or above a void.
RegisterCommand("pursuit.probe", function(source, args, raw)
    if source == nil or source <= 0 then
        return output(source, raw, false, "pursuit.probe must be issued in-game")
    end
    if args.n < 3 then
        return output(source, raw, false, "usage: pursuit.probe <x> <y> <z> [heading]")
    end
    local x, y, z = finiteNumber(args[1]), finiteNumber(args[2]), finiteNumber(args[3])
    local heading = args[4] ~= nil and finiteNumber(args[4]) or 0.0
    local label = args[5] or "probe"
    if x == nil or y == nil or z == nil or heading == nil then
        return output(source, raw, false, "invalid coordinates")
    end
    local playerId = source
    local record = ensurePlayer(playerId)
    if record ~= nil then record.placedAtMs = nowMs() end
    if not placeAt(playerId, { x = x, y = y, z = z }, heading, Config.lobby.bucket, "probe") then
        return output(source, raw, false, "probe placement rejected")
    end
    local startMs = nowMs()
    CreateThread(function()
        local lastZ = nil
        while (nowMs() - startMs) < 11000 do
            Wait(1000)
            local position = Open77.players.position(playerId)
            if position == nil then
                log(("probe[%s] +%5dms position unreadable"):format(label, nowMs() - startMs))
            else
                local dz = lastZ ~= nil and (position.z - lastZ) or 0.0
                lastZ = position.z
                log(("probe[%s] +%5dms pos=%.2f,%.2f,%.2f dz=%+.2f drift=%.2f bucket=%s"):format(
                    label, nowMs() - startMs, position.x, position.y, position.z, dz,
                    math.sqrt((position.x - x) ^ 2 + (position.y - y) ^ 2), tostring(position.bucket)))
            end
        end
        log(("probe[%s] done"):format(label))
    end)
    output(source, raw, true, ("probing %.1f, %.1f, %.1f"):format(x, y, z))
end, false)

-- Diagnostic: hold the leash off and narrate the player's position while he
-- walks. Authoring a spawn pair means proving the two points are on ground a
-- player can actually stand on and walk between; the only instrument that
-- proves that is a player walking between them.
RegisterCommand("pursuit.survey", function(source, args, raw)
    if source == nil or source <= 0 then
        return output(source, raw, false, "pursuit.survey must be issued in-game")
    end
    local seconds = tonumber(args and args[1]) or 60
    if seconds <= 0 or seconds > 600 then
        return output(source, raw, false, "usage: pursuit.survey [seconds 1..600]")
    end
    local playerId = source
    local record = ensurePlayer(playerId)
    if record == nil then
        return output(source, raw, false, "player not tracked")
    end
    -- Reuse the placement grace rather than adding a second way to mute the
    -- leash: one mechanism, one thing to get wrong.
    record.graceUntilMs = nowMs() + math.floor(seconds * 1000)
    record.outsideSinceMs = nil
    record.warned = false
    local origin = Open77.players.position(playerId)
    local startMs = nowMs()
    CreateThread(function()
        while (nowMs() - startMs) < (seconds * 1000) do
            Wait(1000)
            local position = Open77.players.position(playerId)
            if position ~= nil and origin ~= nil then
                local dx, dy = position.x - origin.x, position.y - origin.y
                local dz = position.z - origin.z
                log(("survey +%5ds pos=%.2f,%.2f,%.2f from-origin=%.1fm (planar %.1fm dz %+.1f)"):format(
                    math.floor((nowMs() - startMs) / 1000),
                    position.x, position.y, position.z,
                    math.sqrt(dx * dx + dy * dy + dz * dz), math.sqrt(dx * dx + dy * dy), dz))
            end
        end
        log("survey done -- the leash is live again")
    end)
    output(source, raw, true, ("leash suspended for %ds"):format(seconds))
end, false)

RegisterCommand("pursuit.tp", function(source, args, raw)
    if source == nil or source <= 0 then
        return output(source, raw, false, "pursuit.tp must be issued in-game")
    end
    if args.n < 3 then
        return output(source, raw, false, "usage: pursuit.tp <x> <y> <z> [heading]")
    end
    local x, y, z = finiteNumber(args[1]), finiteNumber(args[2]), finiteNumber(args[3])
    local heading = args[4] ~= nil and finiteNumber(args[4]) or 0.0
    if x == nil or y == nil or z == nil or heading == nil then
        return output(source, raw, false, "invalid coordinates")
    end
    local record = ensurePlayer(source)
    if record ~= nil then record.placedAtMs = nowMs() end
    -- Land in the dimension the player is ALREADY in, not the lobby's.
    --
    -- Forcing Config.lobby.bucket here silently pulled a player out of his
    -- match: separation then reads `wrong_bucket` on every tick, the
    -- accumulators are frozen and no win condition can ever arm -- while the
    -- teleport itself reports success and the player visibly moves. Since
    -- manufacturing separation inside a live match is precisely what this
    -- command exists for, the old behaviour made the instrument destroy the
    -- thing it was measuring.
    local current = Open77.players.position(source)
    local bucket = (current ~= nil and current.bucket) or Config.lobby.bucket
    if placeAt(source, { x = x, y = y, z = z }, heading, bucket, "tp") then
        output(source, raw, true,
            ("teleporting to %.1f, %.1f, %.1f (bucket %d)"):format(x, y, z, bucket))
    else
        output(source, raw, false, "teleport rejected; see the server log")
    end
end, false)

-- Stand on the ready-up circle without walking there.
--
-- ------------------------------------------------------------------------
-- WHY THIS COMMAND USED TO LIE, AND WHAT IT NOW REPORTS INSTEAD
-- ------------------------------------------------------------------------
--
-- The old body issued the placement and printed "moving to the ready-up
-- circle" the instant `placeAt` returned true -- and `placeAt` returning true
-- means only that the life authority ACCEPTED a kill and a respawn. It says
-- nothing about where the player ends up. The transaction then runs for
-- seconds behind a fade and a streaming preload, so a caller who reads
-- `position` straight afterwards sees the coordinates the player has not left
-- yet, which reads exactly like "the command moved nobody".
--
-- And when it does settle, on THIS ground, it settles somewhere else. Corpo
-- Plaza's terrace is the measured worst case of the post-placement drift
-- recorded in docs/gamemode-pursuit-plan.md section 7b: a placement aimed at
-- the ready-up mark has been observed to come to rest up to 20 m away, and
-- `pursuit.force <ids>` exists in server/match.lua precisely because of it --
-- its comment says the queue's own containment check refuses a player placed
-- on the circle "however precisely it is aimed". The reported ~14.7 m sits
-- squarely in that band.
--
-- So there was never a transport fault, which is why `pursuit.tp` looked fine:
-- nothing measures `pursuit.tp` against a 2 m target. The fault was that this
-- command reported an INTENT as an OUTCOME.
--
-- It now waits for the transaction, re-reads the server's own replicated
-- position, and reports what actually happened -- using the SAME containment
-- predicate the queue intent uses, so "tpcircle says you are on the circle"
-- and "the queue accepted you" can never disagree. If the drift put him
-- outside, it re-issues the placement rather than reporting a success nobody
-- can act on, and after the last attempt it says so and names the way round.
local TPCIRCLE_ATTEMPTS = 3
-- The placement transaction is a fade plus a streaming preload; on this
-- machine it has been observed to take several seconds, and the drift keeps
-- moving the player for a while after that. Poll rather than sleep a fixed
-- time, so a fast settle is reported fast.
local TPCIRCLE_SETTLE_MS = 12000
local TPCIRCLE_POLL_MS = 1000

RegisterCommand("pursuit.tpcircle", function(source, _, raw)
    if source == nil or source <= 0 then
        return output(source, raw, false, "pursuit.tpcircle must be issued in-game")
    end
    local playerId = source
    local target = readyUpPosition()

    CreateThread(function()
        for attempt = 1, TPCIRCLE_ATTEMPTS do
            local record = ensurePlayer(playerId)
            if record ~= nil then record.placedAtMs = nowMs() end
            if not placeAt(playerId, target, Config.lobby.heading, Config.lobby.bucket,
                "tpcircle") then
                return output(playerId, raw, false,
                    ("placement rejected on attempt %d/%d; see the server log"):format(
                        attempt, TPCIRCLE_ATTEMPTS))
            end

            -- Report the ISSUE separately from the OUTCOME, and only once: a
            -- caller that reads a single command result gets a line that is
            -- true when it is printed, and the verdict follows.
            if attempt == 1 then
                output(playerId, raw, true,
                    ("placement issued to %.1f, %.1f, %.1f -- verifying arrival (up to %ds)"):format(
                        target.x, target.y, target.z,
                        math.floor((TPCIRCLE_SETTLE_MS * TPCIRCLE_ATTEMPTS) / 1000)))
            end

            local waited, inside, detail = 0, false, "unknown"
            while waited < TPCIRCLE_SETTLE_MS do
                Wait(TPCIRCLE_POLL_MS)
                waited = waited + TPCIRCLE_POLL_MS
                -- The queue's own check, not a re-derived one. Same centre,
                -- same radius, same bucket, same grace.
                inside, detail = containsPlayer(playerId, target,
                    Config.lobby.readyUp.radius, Config.lobby.bucket)
                if inside then break end
            end

            local position = Open77.players.position(playerId)
            local distance
            if position ~= nil then
                local dx, dy = position.x - target.x, position.y - target.y
                local dz = position.z - target.z
                distance = math.sqrt(dx * dx + dy * dy + dz * dz)
            end

            if inside then
                return output(playerId, raw, true,
                    ("ARRIVED on the ready-up circle after %d attempt(s): %s from centre, radius %.1fm -- a queue intent will be accepted"):format(
                        attempt,
                        distance and ("%.1fm"):format(distance) or "distance unreadable",
                        Config.lobby.readyUp.radius))
            end

            log(("tpcircle attempt %d/%d for player %d settled %s from the circle (%s)"):format(
                attempt, TPCIRCLE_ATTEMPTS, playerId,
                distance and ("%.1fm"):format(distance) or "an unreadable distance",
                tostring(detail)))
        end

        -- Out of attempts. Say the true distance and name the way round, rather
        -- than printing a success the caller cannot act on.
        local position = Open77.players.position(playerId)
        local distance
        if position ~= nil then
            local dx, dy = position.x - target.x, position.y - target.y
            distance = math.sqrt(dx * dx + dy * dy)
        end
        output(playerId, raw, false,
            ("DID NOT ARRIVE after %d attempt(s): %s from a %.1fm circle. This is post-placement drift on the Corpo Plaza terrace (plan section 7b), not a transport fault -- use 'pursuit.force <playerId> <playerId>' to start a match without standing on the circle."):format(
                TPCIRCLE_ATTEMPTS,
                distance and ("%.1fm"):format(distance) or "an unreadable distance",
                Config.lobby.readyUp.radius))
    end)
end, false)

RegisterCommand("pursuit.projtest", function(source, _, raw)
    if source == nil or source <= 0 then
        return output(source, raw, false, "pursuit.projtest must be issued in-game")
    end
    TriggerClientEvent("pursuit:projtest", source)
    output(source, raw, true, "projection probe started; move the camera now")
end, false)

RegisterCommand("pursuit.markers", function(source, _, raw)
    if source == nil or source <= 0 then
        return output(source, raw, false, "pursuit.markers must be issued in-game")
    end
    TriggerClientEvent("pursuit:dumpMarkers", source)
    output(source, raw, true, "marker dump requested; see the client log")
end, false)

RegisterCommand("pursuit.lobby", function(source, _, raw)
    if source == nil or source <= 0 then
        return output(source, raw, false, "pursuit.lobby must be issued in-game")
    end
    -- Refuse for a player who is in a match.
    --
    -- It does not bust him, it STRANDS him: `placeAt` moves him to the lobby
    -- bucket while his state stays `active`, so the lobby leash never judges him
    -- (it only looks at `lobby`/`queued`), his separation reads `wrong_bucket`
    -- for the rest of the match, and the match runs uninterrupted to
    -- `time_expired`. The player is left outside a match he is still formally
    -- in, with no way back.
    --
    -- Refusing is deliberate rather than forfeiting on his behalf: a forfeit is
    -- a gameplay decision with a winner and a record, and inventing one inside a
    -- convenience command is how a debug affordance turns into a rules change.
    local record = players[source]
    if record ~= nil and record.state ~= "lobby" and record.state ~= "queued" then
        return output(source, raw, false, ("refused: you are in a match (state=%s). "):format(record.state) ..
            "Wait for it to resolve, or disconnect to forfeit.")
    end
    if sendToLobby(source, "command") then
        output(source, raw, true, "returning to the lobby")
    else
        output(source, raw, false, "lobby placement failed; see the server log")
    end
end, false)

AddEventHandler("onResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    log(("ready -- lobby bucket %d at %.1f, %.1f, %.1f (radius %.0fm)"):format(
        Config.lobby.bucket,
        Config.lobby.center.x, Config.lobby.center.y, Config.lobby.center.z,
        Tune.lobbyRadius))
    -- Say what an operator may move, so the log answers "is the Tuning tab
    -- wired?" without opening the panel.
    local declared = 0
    for _ in pairs(Config.tunables or {}) do declared = declared + 1 end
    log(("%d operator tunable(s) declared -- Warden's Tuning tab, or `tunables pursuit` from the console"):format(
        declared))
end)

-- Shared surface for the other server files in this resource. Not an export:
-- the server runtime has none. These are plain globals inside one Lua state,
-- which is exactly why a gamemode is one server resource.
Pursuit = {
    players = players,
    queue = queue,
    nowMs = nowMs,
    log = log,
    output = output,
    transition = transition,
    sendToLobby = sendToLobby,
    pushLobbyState = pushLobbyState,
    placeAt = placeAt,
    ensurePlayer = ensurePlayer,
    removeFromQueue = removeFromQueue,
    broadcastQueue = broadcastQueue,
    containsPlayer = containsPlayer,
    readyUpPosition = readyUpPosition,
    -- Shared so the other files in this resource ask the readiness gate the same
    -- fail-open way, instead of each growing its own `Open77.ready` call that raises on
    -- a host without one.
    readyToBeActedUpon = readyToBeActedUpon,
    resetLeash = resetLeash,
    -- Shared so any placement path can ask "does a vehicle hold this player's
    -- seat" the same fail-open way before it moves him -- a respawn issued at a
    -- seated player is absorbed and can end in a disconnect (see the note at
    -- the definition).
    seatedVehicleOf = seatedVehicleOf,
    -- The lobby slot allocator, shared for the same reason as the rest: the
    -- geometry (`lobbySlotOffset`, `lobbySlotUsable`) is pure and is what the
    -- offline harness asserts the spacing guarantee against; the two state
    -- functions let anything that learns a player has left the lobby world
    -- release his spot without reaching into the tables.
    lobbySlotOffset = lobbySlotOffset,
    lobbySlotUsable = lobbySlotUsable,
    acquireLobbySlot = acquireLobbySlot,
    releaseLobbySlot = releaseLobbySlot,
    -- Command arguments are strings and may be anything at all. Shared so the
    -- Phase E command handlers cannot quietly grow a second, laxer parser.
    finiteNumber = finiteNumber,
}
