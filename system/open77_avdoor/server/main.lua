-- =============================================================================
-- open77_avdoor -- server/main.lua
-- =============================================================================
-- Which aircraft door is open to which player, the mount itself, the doors
-- that swing as a body boards and steps out, and the relay that lets everybody
-- near a player-flown MaxTac AV hear it.
--
-- ONE VERDICT, TWO DOORS. `M.Verdict` is the whole decision -- the hull, the
-- body, the distance, the speed, the lock, the seat -- and both the scan (which
-- decides whether a client draws a card) and the key (`BOARD`, which seats) go
-- through it, so the card and the seat can never disagree about who may fly
-- what. Every read is the server's own: the hull's canonical transform, the
-- asker's position and bucket, the seat ledger, the life state, the lock and
-- whatever rule a resource registered for the hull.
--
-- THE SCAN IS HERE BECAUSE THE COORDINATES ARE HERE. Every `SCAN_MS` this half
-- lists the aircraft once, measures each player on foot against the ones in
-- their bucket, judges the nearest in reach, and sends that client a `DOOR`
-- only when its answer CHANGED.
--
-- WHO MAY FLY WHAT, in the order it is asked:
--   1. a rule a resource registered for this hull (`exports.open77_avdoor:allow`):
--      the pilots it names fly, everybody else may ride along unless the rule
--      says `passengers = false`;
--   2. otherwise the lock: a hull locked for this player is shut to them, as a
--      car's door is;
--   3. otherwise `PILOTS`: 'anyone' flies an unlocked aircraft; with
--      'registered', anybody who is not named only rides along (`PASSENGERS`).
-- A player who asked to ride (`/avdoor.ride`, 1.8.0) takes a passenger seat
-- wherever passengers may ride, even an aircraft they could fly.
--
-- THE DOORS. The seat's door (`DOORS`) is opened here, on the server, because a
-- door the server opens is canonical and replicated to every viewer. A door
-- this half opens it owes a closing: every open door is in a ledger with the
-- time it closes, and stopping the resource closes what is left.
--
-- NOTHING HERE OWNS A VEHICLE. No hull is created, stored or removed by this
-- resource; it seats a player through the platform's own authoritative mount
-- (`warpPlayerIntoVehicle`).
-- =============================================================================

local M = AvDoor

-- Rules resources registered, by the hull's id as text:
-- `{ pilots = { [playerId] = true } | nil, passengers, reason, owner }`.
local registry = {}

-- When each hull last spoke each of its sounds, so a hovering pilot bobbing
-- over the ground line is one horn, not one per bob.
local spoke = {}

-- The door each player was last told about, as `id|role` (or false for none),
-- so a scan only sends what changed.
local told = {}

-- RIDING ALONG BY CHOICE (1.8.0, `/avdoor.ride`): the players who asked to
-- board as passengers -- the card says "Ride along", the seat is a passenger's
-- (the Excalibur's back-left first: Corpo V's boarding). Forgotten when they
-- leave, or ask again.
local riders = {}

-- Which records are aircraft, memoised: a record never changes its answer.
local aircraftRecords = {}

-- The doors this half opened and owes a closing, by `id|door`.
local doorLedger = {}

-- Who sat where in each aircraft at the last occupancy event, by hull id as
-- text: `{ [seat] = { playerId, exiting } }`.
local occupancy = {}

-- Work owed for later, `{ at, run }`, drained by the one tending job.
local pending = {}

-- Players with a delayed boarding in flight, so one press is one boarding.
local boarding = {}

-- Hulls created a moment ago, by id as text: when each was created. Nobody
-- boards one until `BOARD.SETTLE_MS` has passed (`M.Fresh`).
local fresh = {}

-- Sounds sent and not yet answered, by token.
local heardBy = {}
local soundSerial = 0

-- Causes already said in the log, so a missing native is one line.
local warned = {}

-- The scheduler handles.
local scanJob, tendJob, calloutJob, padJob = nil, nil, nil, nil

local function settings()
    return type(M.Settings) == 'table' and M.Settings or {}
end

--- A point as `{ x, y, z }` from a snapshot carrying `position` or flat x/y/z.
local function pointOf(value)
    if type(value) ~= 'table' then return nil end
    local at = type(value.position) == 'table' and value.position or value
    local x, y, z = tonumber(at.x), tonumber(at.y), tonumber(at.z)
    if x == nil or y == nil or z == nil or x ~= x or y ~= y or z ~= z then return nil end
    return { x = x, y = y, z = z }
end

--- Whether a record is an aircraft, memoised.
local function aircraft(record)
    if type(record) ~= 'string' then return false end
    local known = aircraftRecords[record]
    if known == nil then
        known = M.IsAircraft(record)
        aircraftRecords[record] = known
    end
    return known
end

--- A player id the host may be asked about: a whole number of 1 or more. The
--- host's player reads THROW on 0 or a negative id (no pcall catches it, the
--- resource is stopped), so every id is checked before any read.
local function validPlayer(playerId)
    local id = tonumber(playerId)
    if id == nil or id < 1 or id ~= math.floor(id) then return nil end
    return id
end

--- The canonical hull a client named, or nil. AN ID IS COMPARED AS TEXT AS A
--- LAST RESORT: the host's 64-bit ids reach a client and come back as a number
--- or as a string.
-- @param raw any
-- @return table|nil snapshot
-- @return any the id as the host knows it
local function hullOf(raw)
    local api = Open77.vehicles
    if type(api) ~= 'table' or type(api.get) ~= 'function' or raw == nil then return nil end
    local read, snapshot = pcall(api.get, raw)
    if read and type(snapshot) == 'table' then return snapshot, raw end
    local number = tonumber(raw)
    if number ~= nil then
        read, snapshot = pcall(api.get, number)
        if read and type(snapshot) == 'table' then return snapshot, number end
    end
    if type(api.all) == 'function' then
        local listed, all = pcall(api.all)
        if listed and type(all) == 'table' then
            local wanted = tostring(raw)
            for _, entry in ipairs(all) do
                if type(entry) == 'table' and (tostring(entry.id) == wanted or M.SameHull(entry.id, raw)) then
                    local got, full = pcall(api.get, entry.id)
                    if got and type(full) == 'table' then return full, entry.id end
                    return entry, entry.id
                end
            end
        end
    end
    return nil
end

--- The seat a player holds, or nil.
local function seatOf(playerId)
    local api = Open77.vehicles
    if validPlayer(playerId) == nil then return nil end
    if type(api) ~= 'table' or type(api.getPlayerSeat) ~= 'function' then return nil end
    local read, seat = pcall(api.getPlayerSeat, playerId)
    if read and type(seat) == 'table' and seat.vehicleId ~= nil then return seat end
    return nil
end
-- For the other server files (server/leave.lua, 1.9.0).
M.ValidPlayer, M.HullOf, M.SeatOfPlayer = validPlayer, hullOf, seatOf

--- Where a player stands, as `{ x, y, z }` and their bucket, or nil.
local function bodyOf(playerId)
    local id = validPlayer(playerId)
    local players = Open77.players
    if id == nil or type(players) ~= 'table' or type(players.position) ~= 'function' then return nil, 0 end
    local read, at = pcall(players.position, id)
    if not read or type(at) ~= 'table' then return nil, 0 end
    return pointOf(at), tonumber(at.bucket) or 0
end

--- Every connected player, as numbers of 1 or more.
local function everybody()
    local players = Open77.players
    if type(players) ~= 'table' or type(players.all) ~= 'function' then return {} end
    local read, ids = pcall(players.all)
    local out = {}
    for _, raw in ipairs(read and type(ids) == 'table' and ids or {}) do
        local id = validPlayer(raw)
        if id ~= nil then out[#out + 1] = id end
    end
    return out
end

--- Whether a seat of a hull is free. An unreadable ledger is offered and left
--- to the mount, which refuses a taken seat by name.
local function seatFree(id, seat)
    local api = Open77.vehicles
    if type(api) ~= 'table' or type(api.seatFree) ~= 'function' then return true end
    local read, answer = pcall(api.seatFree, id, seat)
    if not read then return true end
    return answer ~= false
end

--- Whether a hull is locked as far as this one player is concerned: their
--- exception when they hold one, otherwise the canonical lock.
local function lockedFor(id, playerId)
    -- THE GAME'S OWN ENTRY SHUT (1.7.4, server/native.lua): a lock this
    -- resource holds for one player is not the owner's; the owner's decides.
    if M.NativeEntry ~= nil then
        local policy = M.NativeEntry.PolicyFor(id, playerId)
        if policy ~= nil then return policy end
    end
    local api = Open77.vehicles
    if type(api) ~= 'table' then return false end
    if type(api.isLockedForPlayer) == 'function' and validPlayer(playerId) ~= nil then
        local read, answer = pcall(api.isLockedForPlayer, id, playerId)
        if read and type(answer) == 'boolean' then return answer end
    end
    if type(api.isLocked) == 'function' then
        local read, answer = pcall(api.isLocked, id)
        return read and answer == true
    end
    return false
end

--- Whether somebody who may not fly a hull may ride in it.
local function passengerRole(id, playerId)
    if settings().PASSENGERS ~= true then return nil end
    if lockedFor(id, playerId) then return nil end
    return 'passenger'
end

--- Who this player is to this hull: `pilot`, `passenger`, or nil and why.
--
-- THE CONTROLS AND THE SEATS ARE TWO QUESTIONS. A rule that says "not yours to
-- fly" does not say "and not yours to sit in": the seats stay open to anybody
-- the hull is not locked for, unless the rule closes them.
-- @param playerId number
-- @param id any the hull's id as the host knows it
-- @return string|nil role
-- @return string|nil reason
local function roleFor(playerId, id)
    local rule = registry[M.KeyOf(id)]
    -- A rider takes a passenger seat wherever one is open to them; where the
    -- passenger seats are closed (`PASSENGERS = false`, a rule's
    -- `passengers = false`) the question is asked as for anybody.
    if riders[playerId] == true and (rule == nil or rule.passengers ~= false) then
        local role = passengerRole(id, playerId)
        if role ~= nil then return role end
    end
    if rule ~= nil then
        if rule.pilots == nil or rule.pilots[playerId] == true then return 'pilot' end
        local refusal = type(rule.reason) == 'string' and rule.reason or 'not_crew'
        if rule.passengers ~= false then
            local role = passengerRole(id, playerId)
            if role ~= nil then return role end
        end
        return nil, refusal
    end
    if lockedFor(id, playerId) then return nil, 'locked' end
    if settings().PILOTS == 'registered' then
        local role = passengerRole(id, playerId)
        if role ~= nil then return role end
        return nil, 'not_yours'
    end
    return 'pilot'
end

--- THE DECISION: may this player board this hull, and into which seat.
--
-- THE FREE SEAT, AND ITS OWN CLIP (1.8.4). A seat another body is stepping
-- into right now (`EnterServer.Reserved`) is not free: two players at the
-- door of an AV whose pilot is aboard get the back-left seat (Corpo V's
-- climb) and the back-right one (the door's step), not both the first.
-- `opts.prefer` keeps a boarding in the seat its step was planned into.
-- @param playerId number
-- @param raw any the hull as the client named it
-- @param opts table|nil `{ prefer = seat }`
-- @return table|nil `{ id, role, seat }`
-- @return string|nil the refusal code
function M.Verdict(playerId, raw, opts)
    playerId = validPlayer(playerId)
    if playerId == nil then return nil, 'no_player' end

    local snapshot, id = hullOf(raw)
    if snapshot == nil then return nil, 'no_aircraft' end
    if not aircraft(snapshot.record) then return nil, 'not_aircraft' end
    if snapshot.destroyed == true or snapshot.exploded == true then return nil, 'wrecked' end

    if seatOf(playerId) ~= nil then return nil, 'seated' end
    local players = Open77.players
    if type(players) == 'table' and type(players.isDead) == 'function' then
        local read, dead = pcall(players.isDead, playerId)
        if read and dead == true then return nil, 'down' end
    end

    local body, mine = bodyOf(playerId)
    if body == nil then return nil, 'no_position' end
    local hull = pointOf(snapshot)
    if hull == nil then return nil, 'no_aircraft' end
    local bucket = tonumber(snapshot.bucket)
    if bucket ~= nil and bucket ~= mine then return nil, 'no_aircraft' end

    local reach = M.Number(settings().REACH_METRES, 1.0, 50.0, 9.0)
    local dx, dy, dz = body.x - hull.x, body.y - hull.y, body.z - hull.z
    if dx * dx + dy * dy + dz * dz > reach * reach then return nil, 'too_far' end

    local rest = M.Number(settings().REST_SPEED, 0.0, 50.0, 2.0)
    local speed = tonumber(snapshot.speed) or 0.0
    if speed > rest then return nil, 'moving' end

    local role, why = roleFor(playerId, id)
    if role == nil then return nil, why or 'not_yours' end

    local reserved = {}
    if M.EnterServer ~= nil and type(M.EnterServer.Reserved) == 'function' then
        local read, list = pcall(M.EnterServer.Reserved, id, playerId)
        if read and type(list) == 'table' then reserved = list end
    end
    local seats = M.SeatsFor(role, snapshot.record)
    local prefer = type(opts) == 'table' and opts.prefer or nil
    if prefer ~= nil and reserved[prefer] == nil then
        for _, seat in ipairs(seats) do
            if seat == prefer and seatFree(id, seat) then
                return { id = id, role = role, seat = seat, record = snapshot.record }, nil
            end
        end
    end
    local boarded = nil
    for _, seat in ipairs(seats) do
        if seatFree(id, seat) then
            if reserved[seat] == nil then
                return { id = id, role = role, seat = seat, record = snapshot.record }, nil
            end
            boarded = boarded or seat
        end
    end
    return nil, boarded ~= nil and 'seats_boarding' or 'no_seat'
end

--- Says a hull was created just now, so nobody boards it before it settled.
--- Called for every aircraft the server creates (`onVehicleCreated`), and by a
--- resource that seats its own pilots through the export.
-- @param id any the hull, as the host knows it
-- @return number how long from now it settles, in milliseconds
function M.Fresh(id)
    if id == nil then return 0 end
    local settle = M.BoardSettings().settle
    if settle <= 0 then return 0 end
    local now = M.Now()
    -- The ledger only ever holds a few seconds of hulls: the settled ones go.
    for key, at in pairs(fresh) do
        if now - at >= settle then fresh[key] = nil end
    end
    fresh[M.KeyOf(id)] = now
    return settle
end

--- How long a hull still settles before a body may board it.
-- @param id any the hull, as the host knows it
-- @return number milliseconds, 0 for a settled or unknown hull
function M.SettleLeft(id)
    if id == nil then return 0 end
    local key = M.KeyOf(id)
    local at = fresh[key]
    if at == nil then return 0 end
    local left = at + M.BoardSettings().settle - M.Now()
    if left <= 0 then
        fresh[key] = nil
        return 0
    end
    return math.ceil(left)
end

--- Seats a player through the platform's own authoritative mount.
-- @param playerId number
-- @param raw any the hull as the client named it
-- @param options table|nil `{ door = true }` keeps the seat's door open for the
--   boarding hold; `{ door = 'close' }` (1.7.10, a boarding step) closes the
--   door the step opened now, if it is still open, and never opens it again
-- @return table a result: `{ ok, value = { id, role, seat } }` or `{ ok = false, error, detail }`
function M.Board(playerId, raw, options)
    -- The seat a boarding step was planned into, when it is still free (1.8.4).
    local verdict, why = M.Verdict(playerId, raw, { prefer = type(options) == 'table' and options.seat or nil })
    if verdict == nil then return M.Err(why or 'no_aircraft') end
    local api = Open77.vehicles
    if type(api) ~= 'table' or type(api.warpPlayerIntoVehicle) ~= 'function' then
        return M.Err('seat_refused', 'vehicles_api_unavailable')
    end
    -- The hold on the game's own entry comes off first (server/native.lua): the
    -- forced mount bypasses a lock, and meets none.
    if M.NativeEntry ~= nil then pcall(M.NativeEntry.Seating, verdict.id, playerId) end
    local called, placed, refusal = pcall(api.warpPlayerIntoVehicle, playerId, verdict.id, verdict.seat, {
        -- The hull is in the player's own bucket -- the verdict checked it --
        -- and moving them would be a routing change nobody asked for.
        moveBucket = false,
    })
    if not called or placed ~= true then
        local reason = tostring(called and refusal or placed)
        Open77.log.warn(('%d could not board %s in %s: %s')
            :format(playerId, tostring(verdict.id), verdict.seat, reason))
        return M.Err('seat_refused', reason)
    end
    -- The card comes down now rather than at the next scan: the body is in.
    told[playerId] = nil
    Open77.log.info(('%d boarded %s as %s in %s')
        :format(playerId, tostring(verdict.id), verdict.role, verdict.seat))
    -- The seat's door stays open for the hold and then closes, so the next
    -- body through the same side finds it open.
    if type(options) == 'table' and options.door == true then
        local door = M.ExitDoorName(verdict.record, verdict.seat)
        if door ~= nil then M.OpenDoor(verdict.id, door, M.BoardSettings().hold, 'board') end
    elseif type(options) == 'table' and options.door == 'close' then
        -- A BOARDING STEP'S SEAT (1.7.10): the door the step opened is shut
        -- before the seat; one still open now (a door's clip, a step given up)
        -- is shut now -- never opened again at the seat, which the pilot's own
        -- game would then draw open through the flight.
        local door = M.ExitDoorName(verdict.record, verdict.seat)
        if door ~= nil and M.DoorState(verdict.id, door) ~= nil then
            M.CloseDoorAt(verdict.id, door, M.Now(), 'board')
        end
    end
    -- Other resources hear of the boarding on the host bus (a rule cannot carry
    -- a callback across resources).
    pcall(TriggerEvent, M.Notice.BOARDED, playerId, M.KeyOf(verdict.id), verdict.seat, verdict.role)
    return M.Ok(verdict)
end

-- ── the doors ─────────────────────────────────────────────────────────────────

--- Says a note in the log once per cause.
local function warnOnce(cause, line)
    if warned[cause] then return end
    warned[cause] = true
    Open77.log.warn(line)
end

--- Work owed for `delayMs` from now, run by the tending job.
local function later(delayMs, run)
    pending[#pending + 1] = { at = M.Now() + math.max(0, delayMs), run = run }
end

--- Opens one door of one hull and takes the closing on.
--
-- THE DOOR IS CANONICAL: `openDoor` writes the durable state and the platform
-- replicates it to every viewer. What this resource opens it owes a closing,
-- and the closing is in the ledger before the call returns -- so no path
-- leaves a door open for good.
-- @param id any the hull, as the host knows it
-- @param door string the platform's door name
-- @param holdMs number how long it stays open from now
-- @param why string `exit` or `board`, for the journal
-- @param options table|nil `{ reassertFor, every }` in ms: look again and
--   open it again if the platform's own exit shut it
-- @return boolean whether the host took the call
-- @return string|nil the reason it did not
function M.OpenDoor(id, door, holdMs, why, options)
    if type(door) ~= 'string' or M.DOOR_NAMES[door] ~= true then return false, 'no_door' end
    local api = Open77.vehicles
    if type(api) ~= 'table' or type(api.openDoor) ~= 'function' then
        warnOnce('openDoor', 'no Open77.vehicles.openDoor on this host: aircraft doors stay shut')
        return false, 'unavailable'
    end
    local called, opened, reason = pcall(api.openDoor, id, door)
    if not called or opened == false or opened == nil then
        local detail = tostring(called and reason or opened)
        Open77.log.warn(('the %s door of %s would not open (%s): %s')
            :format(door, tostring(id), tostring(why), detail))
        return false, detail
    end
    local now = M.Now()
    local key = M.KeyOf(id) .. '|' .. door
    local entry = doorLedger[key]
    if entry == nil then
        entry = { id = id, door = door, since = now, asserts = 0, closeFailures = 0 }
        doorLedger[key] = entry
    end
    entry.why = why
    entry.closeAt = math.max(entry.closeAt or 0, now + math.max(0, tonumber(holdMs) or 0))
    local span = type(options) == 'table' and tonumber(options.reassertFor) or nil
    if span ~= nil and span > 0 then
        entry.every = math.max(100, tonumber(options.every) or 400)
        entry.assertUntil = math.max(entry.assertUntil or 0, now + span)
        entry.nextAssert = now + entry.every
    end
    return true
end

--- Closes one ledger door, or lets it go when the hull is gone. A close the
--- host refuses is tried again, three times, and then given up on aloud.
local function closeEntry(key, entry, now)
    local api = Open77.vehicles
    if type(api) ~= 'table' or type(api.closeDoor) ~= 'function' then
        warnOnce('closeDoor', 'no Open77.vehicles.closeDoor on this host: doors this resource opened stay open')
        doorLedger[key] = nil
        return
    end
    local called, closed, reason = pcall(api.closeDoor, entry.id, entry.door)
    if called and closed ~= false and closed ~= nil then
        doorLedger[key] = nil
        Open77.log.info(('the %s door of %s closed after %s, %.1fs open, %d re-open(s)')
            :format(entry.door, tostring(entry.id), tostring(entry.why),
                (now - entry.since) / 1000.0, entry.asserts))
        return
    end
    local detail = tostring(called and reason or closed)
    entry.closeFailures = entry.closeFailures + 1
    if detail == 'vehicle_not_found' or entry.closeFailures >= 3 then
        doorLedger[key] = nil
        Open77.log.warn(('the %s door of %s could not be closed (%s): let go after %d try(ies)')
            :format(entry.door, tostring(entry.id), detail, entry.closeFailures))
        return
    end
    entry.closeAt = now + 500
end

--- One pass of the tending job: the work that is due, then every open door.
function M.Tend()
    local now = M.Now()
    if #pending > 0 then
        local due, keep = {}, {}
        for _, item in ipairs(pending) do
            if item.at <= now then due[#due + 1] = item else keep[#keep + 1] = item end
        end
        pending = keep
        for _, item in ipairs(due) do
            local ran, failure = pcall(item.run)
            if not ran then Open77.log.error('a delayed step failed: ' .. tostring(failure)) end
        end
    end

    local api = Open77.vehicles
    for key, entry in pairs(doorLedger) do
        if entry.closeAt ~= nil and now >= entry.closeAt then
            closeEntry(key, entry, now)
        elseif entry.assertUntil ~= nil and now <= entry.assertUntil and now >= (entry.nextAssert or 0)
            and type(api) == 'table' and type(api.isDoorOpen) == 'function' then
            entry.nextAssert = now + (entry.every or 400)
            local read, open = pcall(api.isDoorOpen, entry.id, entry.door)
            if read and open == nil then
                -- The host does not know the hull any more: nothing to keep open.
                doorLedger[key] = nil
            elseif read and open == false then
                entry.asserts = entry.asserts + 1
                local called, again, reason = pcall(api.openDoor, entry.id, entry.door)
                Open77.log.info(('the %s door of %s had been shut again %.1fs after %s: opened it again (%s)')
                    :format(entry.door, tostring(entry.id), (now - entry.since) / 1000.0,
                        tostring(entry.why),
                        (called and again ~= false and again ~= nil) and 'ok'
                            or ('refused: ' .. tostring(called and reason or again))))
            end
        end
    end
end

--- Moves a ledger door's closing to `at` -- earlier as well as later (1.7.10:
--- a boarding step shuts its door before the seat). A door the ledger does not
--- hold is taken on, to close at `at`. Reasserting ends.
-- @param id any the hull
-- @param door string the platform's door name
-- @param at number when, on `M.Now()`'s clock
-- @param why string for the log
-- @return boolean whether a closing is set
function M.CloseDoorAt(id, door, at, why)
    if type(door) ~= 'string' or M.DOOR_NAMES[door] ~= true then return false end
    local now = M.Now()
    local key = M.KeyOf(id) .. '|' .. door
    local entry = doorLedger[key]
    if entry == nil then
        entry = { id = id, door = door, since = now, asserts = 0, closeFailures = 0 }
        doorLedger[key] = entry
    end
    entry.why = why
    entry.closeAt = tonumber(at) or now
    entry.assertUntil, entry.nextAssert = nil, nil
    -- Due now: closed in this call rather than at the next pass.
    if entry.closeAt <= now then closeEntry(key, entry, now) end
    return true
end

--- THE DOOR SHUT IN FLIGHT (1.7.10): an aircraft with somebody aboard moving
--- faster than `BOARD.FLIGHT_SPEED` whose door the network holds open has it
--- closed, one line per hull and flight. Called by `M.Scan` with its list.
-- @param hulls table[] `{ id, at, bucket, entry }`
-- @return integer how many doors were closed
local flightDoorSaid = {}
function M.DoorsInFlight(hulls)
    local board = M.BoardSettings()
    if not board.closeInFlight or type(hulls) ~= 'table' then return 0 end
    local api = Open77.vehicles
    if type(api) ~= 'table' or type(api.isDoorOpen) ~= 'function' or type(api.closeDoor) ~= 'function' then
        return 0
    end
    local closed, present = 0, {}
    for _, hull in ipairs(hulls) do
        local snapshot = hull.entry
        local key = M.KeyOf(hull.id)
        present[key] = true
        local speed = type(snapshot) == 'table' and tonumber(snapshot.speed) or nil
        local aboard = {}
        for _, occupant in ipairs(type(snapshot) == 'table' and type(snapshot.occupants) == 'table'
            and snapshot.occupants or {}) do
            if type(occupant) == 'table' and occupant.exiting ~= true and occupant.seat ~= nil then
                aboard[#aboard + 1] = { player = occupant.playerId,
                    seat = (M.SeatName ~= nil and M.SeatName(occupant.seat)) or occupant.seat }
            end
        end
        if speed ~= nil and speed == speed and speed > board.flightSpeed and #aboard > 0 then
            -- The doors this resource swings for this airframe's seats.
            local doors, seen = {}, {}
            for _, occupant in ipairs(aboard) do
                local door = M.ExitDoorName(snapshot.record, occupant.seat)
                if door ~= nil and not seen[door] then seen[door], doors[#doors + 1] = true, door end
            end
            for _, door in ipairs(doors) do
                local read, open = pcall(api.isDoorOpen, hull.id, door)
                if read and open == true then
                    local called, ok, reason = pcall(api.closeDoor, hull.id, door)
                    doorLedger[key .. '|' .. door] = nil
                    closed = closed + 1
                    local said = flightDoorSaid[key] or { count = 0 }
                    said.count = said.count + 1
                    flightDoorSaid[key] = said
                    if said.count <= 3 then
                        Open77.log.warn(('the %s door of aircraft %s was open in flight (%.1f m/s, %d aboard: %s): '
                            .. 'closed (%s)%s'):format(door, key, speed, #aboard, (function()
                                local parts = {}
                                for _, occupant in ipairs(aboard) do
                                    parts[#parts + 1] = ('%s:%s'):format(tostring(occupant.player or '?'),
                                        tostring(occupant.seat))
                                end
                                return table.concat(parts, ', ')
                            end)(), (called and ok ~= false and ok ~= nil) and 'ok'
                                or ('refused: ' .. tostring(called and reason or ok)),
                            said.count == 3 and ' -- not said again for this hull' or ''))
                    end
                end
            end
        end
    end
    for key in pairs(flightDoorSaid) do
        if not present[key] then flightDoorSaid[key] = nil end
    end
    return closed
end

--- Whether a door is on the ledger, and when it closes.
-- @return table|nil `{ closeAt, asserts, why, since }`
function M.DoorState(id, door)
    local entry = doorLedger[M.KeyOf(id) .. '|' .. tostring(door)]
    if entry == nil then return nil end
    return { closeAt = entry.closeAt, asserts = entry.asserts, why = entry.why, since = entry.since }
end

--- Keeps the door an exit opened open `holdMs` from now -- the exit clip walks
--- out of it, and on a slow game it starts late (server/walkout.lua). The
--- closing only ever moves later.
-- @param id any the hull
-- @param record string|nil its record
-- @param seat string|nil the seat that was left
-- @param holdMs number
-- @param why string for the log
-- @return boolean whether the door is held open
function M.HoldExitDoor(id, record, seat, holdMs, why)
    if M.ExitSettings().off then return false end
    local door = M.ExitDoorName(record, seat)
    if door == nil then return false end
    local opened, reason = M.OpenDoor(id, door, holdMs, why)
    local state = M.DoorState(id, door)
    Open77.log.info(('the %s door of %s held open for the %s: %s'):format(door, tostring(id), tostring(why),
        opened and state ~= nil and ('closing in %.1fs'):format(math.max(0, state.closeAt - M.Now()) / 1000.0)
            or ('would not open (' .. tostring(reason) .. ')')))
    return opened == true
end

--- What a seat's door does when the body in it steps out: it opens for
--- everybody, and closes after `DOOR_HOLD_MS`. The exit is also remembered for
--- its clip, and the body hidden from the others until the clip starts
--- (server/walkout.lua).
-- @param record string|nil the hull's record, for the clip
-- @return boolean whether a door was opened
function M.Exited(id, seat, playerId, how, record)
    pcall(TriggerEvent, M.Notice.EXITED, tonumber(playerId) or playerId, M.KeyOf(id), seat, how)
    -- The exit's drag watched for (server/watch.lua): the pose the hull stood
    -- at before it, kept now.
    if M.Watch ~= nil and M.Watch.Exited ~= nil then
        local ran, failure = pcall(M.Watch.Exited, id, playerId, how)
        if not ran then Open77.log.error('the drag watch failed at the exit: ' .. tostring(failure)) end
    end
    if M.WalkOutServer ~= nil then
        local ran, failure = pcall(M.WalkOutServer.Exited, playerId, id, seat, how, record)
        if not ran then Open77.log.error('the exit clip failed at the exit: ' .. tostring(failure)) end
    end
    local exit = M.ExitSettings()
    if exit.off then return false end
    -- An airframe whose gear is known is set down on it once nobody is aboard
    -- (server/land.lua), on the ground the exiting game measures under it.
    if M.Land ~= nil and how ~= 'changed' then
        local ran, failure = pcall(M.Land.Exited, id, record, playerId)
        if not ran then Open77.log.error('the hull\'s landing failed at the exit: ' .. tostring(failure)) end
    end
    -- A known airframe's own door (the Rayfield Excalibur has one, on the left,
    -- for every seat, swung by the platform's trunk), else the seat's.
    local door = M.ExitDoorName(record, seat)
    if door == nil then return false end
    local opened, reason = M.OpenDoor(id, door, exit.doorHold, 'exit',
        { reassertFor = exit.reassertFor, every = exit.reassertEvery })
    Open77.log.info(('player %s left %s of aircraft %s (%s): the %s door %s, closing in %.1fs')
        :format(tostring(playerId), tostring(seat), tostring(id), tostring(how), door,
            opened and 'is open' or ('would not open (' .. tostring(reason) .. ')'),
            exit.doorHold / 1000.0))
    return opened
end

--- The occupancy of an aircraft changed: whoever stepped out gets their door.
--- Runs on the platform's `onVehicleOccupancyChanged`. A seat that emptied, a
--- seat whose body began to leave (`exiting`) and a seat that changed hands
--- are all an exit; a hull that is not an aircraft costs one memoised lookup.
-- @param raw any the hull's id, as the event delivers it (a string)
-- @return integer how many exits were seen
function M.Occupancy(raw)
    -- The id goes to the host as it was delivered (a decimal string): a 64-bit
    -- id put through `tonumber` loses its low bits above 2^53.
    local snapshot, id = hullOf(raw)
    if snapshot == nil then
        occupancy[M.KeyOf(raw)] = nil
        return 0
    end
    if not aircraft(snapshot.record) then return 0 end
    local key = M.KeyOf(id)
    local before = occupancy[key] or {}
    local now = {}
    for _, occupant in ipairs(type(snapshot.occupants) == 'table' and snapshot.occupants or {}) do
        local seat = type(occupant) == 'table' and M.SeatName(occupant.seat) or nil
        if seat ~= nil then
            now[seat] = { playerId = occupant.playerId, exiting = occupant.exiting == true }
        end
    end
    local exits = 0
    for seat, was in pairs(before) do
        local is = now[seat]
        local how = nil
        if is == nil then
            -- A seat already marked as leaving had its door opened then; the seat
            -- emptying is the same exit, not a second one.
            if not was.exiting then how = 'left' end
        elseif is.exiting and not was.exiting then
            how = 'exiting'
        elseif tostring(is.playerId) ~= tostring(was.playerId) then
            how = 'changed'
        end
        if how ~= nil then
            exits = exits + 1
            M.Exited(id, seat, was.playerId, how, snapshot.record)
        end
    end
    -- A BODY THAT SAT DOWN in an aircraft -- through the door or the game's own
    -- entry -- is hidden in its seat: the moment to give it the exit style.
    for seat, is in pairs(now) do
        local was = before[seat]
        if not is.exiting and (was == nil or tostring(was.playerId) ~= tostring(is.playerId)) then
            if M.WalkOutServer ~= nil then
                local ran, failure = pcall(M.WalkOutServer.Seated, is.playerId, id, seat)
                if not ran then Open77.log.error('the exit style at boarding failed: ' .. tostring(failure)) end
            end
            -- Through the card, or through the game's own entry (server/native.lua):
            -- said. A body that moved from another seat of this hull switched seats.
            local switched = false
            for other, w in pairs(before) do
                if other ~= seat and tostring(w.playerId) == tostring(is.playerId) then switched = true end
            end
            if M.NativeEntry ~= nil and not switched then
                local ran, failure = pcall(M.NativeEntry.SatDown, id, seat, is.playerId)
                if not ran then Open77.log.error('the game\'s own entry check failed: ' .. tostring(failure)) end
            end
        end
    end
    occupancy[key] = now
    return exits
end

-- ── the scan ──────────────────────────────────────────────────────────────────

--- Every aircraft that exists, with where it stands and its bucket. `entry` is
--- the snapshot `all` answered, for the watch, which reads its owner, epoch and
--- seats without a second host call.
-- @return table[] `{ id, at, bucket, entry }`
local function aircraftNow()
    local api = Open77.vehicles
    if type(api) ~= 'table' or type(api.all) ~= 'function' then return {} end
    local listed, all = pcall(api.all)
    if not listed or type(all) ~= 'table' then return {} end
    local hulls = {}
    for _, entry in ipairs(all) do
        if type(entry) == 'table' and entry.id ~= nil and aircraft(entry.record) then
            local at = pointOf(entry)
            if at ~= nil then
                hulls[#hulls + 1] = { id = entry.id, at = at, bucket = tonumber(entry.bucket) or 0, entry = entry }
            end
        end
    end
    return hulls
end

--- The nearest aircraft to a body, in its bucket, and how far it is.
local function nearestTo(body, bucket, hulls)
    local found, best = nil, math.huge
    for _, hull in ipairs(hulls) do
        if hull.bucket == bucket then
            local dx, dy, dz = body.x - hull.at.x, body.y - hull.at.y, body.z - hull.at.z
            local metres = math.sqrt(dx * dx + dy * dy + dz * dz)
            if metres < best then found, best = hull, metres end
        end
    end
    return found, best
end

--- The door open to one player now: `{ id, role }`, or nil.
local function doorFor(playerId, hulls)
    if #hulls == 0 or seatOf(playerId) ~= nil then return nil end
    local body, bucket = bodyOf(playerId)
    if body == nil then return nil end
    local hull, metres = nearestTo(body, bucket, hulls)
    local reach = M.Number(settings().REACH_METRES, 1.0, 50.0, 9.0)
    if hull == nil or metres > reach then return nil end
    local verdict = M.Verdict(playerId, hull.id)
    if verdict == nil then return nil end
    return { id = M.KeyOf(verdict.id), role = verdict.role, at = hull.at }
end

--- Tells one client its door, when it changed. The hull's canonical position
--- goes with it, for a client that cannot hang the card on the hull itself (it
--- has no projection of it yet); a hull that moved more than two metres since
--- is told again.
local function tell(playerId, door)
    local key = false
    if door ~= nil then
        key = ('%s|%s|%d|%d|%d'):format(door.id, door.role, math.floor(door.at.x / 2.0),
            math.floor(door.at.y / 2.0), math.floor(door.at.z / 2.0))
    end
    -- Never told is the same as told "no door": a player who never stood at an
    -- aircraft is sent nothing at all.
    if (told[playerId] or false) == key then return end
    told[playerId] = key
    TriggerClientEvent(M.Event.DOOR, playerId, door ~= nil
        and { open = true, id = door.id, role = door.role,
            at = { x = door.at.x, y = door.at.y, z = door.at.z } } or { open = false })
end

--- Learns who sits in an aircraft this half has no record of yet. The seats
--- are otherwise learnt from the platform's change events only, so a hull
--- boarded before this resource started -- a restart, or a resource that
--- loaded late -- would give its first exit no door.
-- @param hulls table[] `aircraftNow()`
local function seed(hulls)
    for _, hull in ipairs(hulls) do
        local key = M.KeyOf(hull.id)
        if occupancy[key] == nil and type(hull.entry) == 'table' then
            local now = {}
            for _, occupant in ipairs(type(hull.entry.occupants) == 'table' and hull.entry.occupants or {}) do
                local seat = type(occupant) == 'table' and M.SeatName(occupant.seat) or nil
                if seat ~= nil then
                    now[seat] = { playerId = occupant.playerId, exiting = occupant.exiting == true }
                end
            end
            occupancy[key] = now
        end
    end
end

--- One pass over every player.
-- @return integer how many players have a door open to them
function M.Scan()
    local ids = everybody()
    local hulls = aircraftNow()
    seed(hulls)
    -- The watch measures the same list against the last one: a canonical move
    -- no aircraft flies is a line in the journal.
    if M.Watch ~= nil then
        local watched, failure = pcall(M.Watch.Observe, hulls)
        if not watched then Open77.log.warn('the watch failed: ' .. tostring(failure)) end
    end
    -- THE DOOR SHUT IN FLIGHT (1.7.10).
    local doorsRan, doorsFailure = pcall(M.DoorsInFlight, hulls)
    if not doorsRan then Open77.log.warn('the in-flight door check failed: ' .. tostring(doorsFailure)) end
    -- THE PAD SNAP (server/snap.lua): an AV coming down over a pad is caught.
    if M.Snap ~= nil then
        local snapped, failure = pcall(M.Snap.Observe, hulls)
        if not snapped then Open77.log.warn('the pad snap failed: ' .. tostring(failure)) end
    end
    -- THE GAME'S OWN ENTRY (server/native.lua): shut for every player on foot
    -- near an aircraft, before the door is told.
    if M.NativeEntry ~= nil then
        local ran, failure = pcall(M.NativeEntry.Observe, ids, hulls, bodyOf, seatOf)
        if not ran then Open77.log.warn('the game\'s own entry guard failed: ' .. tostring(failure)) end
    end
    local open, present = 0, {}
    for _, playerId in ipairs(ids) do
        present[playerId] = true
        local ran, door = pcall(doorFor, playerId, hulls)
        if not ran then
            Open77.log.warn(('the door read for %d failed: %s'):format(playerId, tostring(door)))
            door = nil
        end
        if door ~= nil then open = open + 1 end
        tell(playerId, door)
    end
    -- A connection that left takes its memory with it.
    for playerId in pairs(told) do
        if not present[playerId] then told[playerId] = nil end
    end
    return open
end

--- What the door nearest to a player says, in words, for `/avdoor.why`.
-- @param playerId number
-- @return string
function M.Explain(playerId)
    playerId = validPlayer(playerId)
    if playerId == nil then return 'the console has no body to measure' end
    local hulls = aircraftNow()
    local body, bucket = bodyOf(playerId)
    if body == nil then return 'your position is unknown to the server' end
    local hull, metres = nearestTo(body, bucket, hulls)
    if hull == nil then
        return ('no aircraft exists in your bucket (%d aircraft on the server)'):format(#hulls)
    end
    local verdict, why = M.Verdict(playerId, hull.id)
    local snapshot = hullOf(hull.id)
    local record = type(snapshot) == 'table' and tostring(snapshot.record) or '?'
    local settle = M.SettleLeft(hull.id)
    if verdict ~= nil then
        return ('aircraft %s (%s) %.1f m away: the door is OPEN to you as %s, seat %s -- press %s%s')
            :format(M.KeyOf(hull.id), record, metres, verdict.role, verdict.seat,
                tostring(settings().KEY or 'F'),
                settle > 0 and (' (it appeared a moment ago: you board in %d ms)'):format(settle) or '')
    end
    return ('aircraft %s (%s) %.1f m away: the door is SHUT to you -- %s')
        :format(M.KeyOf(hull.id), record, metres, tostring(why))
end

-- ── the MaxTac AV's own voice ─────────────────────────────────────────────────

--- Gives one listener the sound through the platform's own fan-out: the
--- platform plays a Wwise event on a vehicle for the whole bucket, so every
--- OTHER player in the bucket is excluded and the one listener is all that is
--- left. Only ever called for a listener whose own client was refused by the
--- host, so a sound is never heard twice.
local function rescue(wait, listener)
    local effects = type(Open77) == 'table' and Open77.effects or nil
    if type(effects) ~= 'table' or type(effects.sound) ~= 'function' then
        warnOnce('effects', 'no Open77.effects.sound on this host: a listener whose client '
            .. 'is refused stays silent')
        return false, 'unavailable'
    end
    local exclude = {}
    for _, other in ipairs(everybody()) do
        if other ~= listener then
            local _, where = bodyOf(other)
            if where == wait.bucket then exclude[#exclude + 1] = other end
        end
    end
    -- The platform takes at most 32 exclusions: past that the sound cannot be
    -- addressed to one body, and it is better silent for one than doubled.
    if #exclude > 32 then return false, 'too_many_listeners' end
    soundSerial = soundSerial + 1
    local target = M.DecimalId(wait.id) or tostring(wait.id)
    local ran, ok, why = pcall(effects.sound, { kind = 'vehicle', id = target }, wait.event, {
        duration = wait.duration,
        actionId = ('open77-avdoor:%s:%s:%d'):format(target, tostring(wait.which), soundSerial),
        excludePlayers = #exclude > 0 and exclude or nil,
    })
    if not ran or ok == nil or ok == false then
        return false, tostring(ran and why or ok)
    end
    return true
end

--- Relays one flight sound from the pilot's client to everybody near the hull.
--- EVERY LISTENER IN RANGE IS SENT IT -- THE PILOT INCLUDED -- and each answers
--- (`M.Heard`).
-- @param playerId number the asker
-- @param payload table `{ id, which }`
-- @return integer how many were sent it
function M.Speak(playerId, payload)
    local sounds = settings().SOUNDS
    if type(sounds) ~= 'table' or type(payload) ~= 'table' then return 0 end
    local field = M.SOUNDS[tostring(payload.which)]
    if field == nil then return 0 end
    local event = sounds[field]
    if type(event) ~= 'string' or event == '' then return 0 end

    -- THE ASKER MUST BE IN THAT HULL: a sound is the flight's, and only a body
    -- aboard is flying it.
    local seat = seatOf(playerId)
    if seat == nil or not M.SameHull(seat.vehicleId, payload.id) then return 0 end
    local snapshot, id = hullOf(seat.vehicleId)
    if snapshot == nil or not M.IsAircraft(snapshot.record, sounds.RECORDS) then return 0 end

    local key = M.KeyOf(id) .. '\1' .. field
    local now = M.Now()
    local floor = M.Number(sounds.FLOOR_MS, 0, 600000, 6000)
    if spoke[key] ~= nil and now - spoke[key] < floor then return 0 end
    spoke[key] = now

    local hull = pointOf(snapshot)
    if hull == nil then return 0 end
    local range = M.Number(sounds.RANGE, 1.0, 2000.0, 220.0)
    local bucket = tonumber(snapshot.bucket) or 0
    local duration = M.Number(sounds.DURATION_S, 0.05, 60.0, 8.0)

    soundSerial = soundSerial + 1
    local token = soundSerial
    local sent, names = {}, {}
    for _, listener in ipairs(everybody()) do
        local body, where = bodyOf(listener)
        if body ~= nil and where == bucket then
            local dx, dy, dz = body.x - hull.x, body.y - hull.y, body.z - hull.z
            local metres = math.sqrt(dx * dx + dy * dy + dz * dz)
            if metres <= range then
                sent[listener] = true
                names[#names + 1] = ('%d (%.0f m)'):format(listener, metres)
                TriggerClientEvent(M.Event.PLAY, listener, {
                    id = M.KeyOf(id), event = event, which = tostring(payload.which),
                    duration = duration, token = token,
                })
            end
        end
    end
    heardBy[token] = { id = id, event = event, which = tostring(payload.which), duration = duration,
        bucket = bucket, at = now, sent = sent }
    -- A sound nobody answered inside half a minute is not going to be.
    for old, wait in pairs(heardBy) do
        if now - wait.at > 30000 then heardBy[old] = nil end
    end
    Open77.log.info(('%s: %s (%s) sent to %d listener(s): %s')
        :format(M.KeyOf(id), tostring(payload.which), event, #names, table.concat(names, ', ')))
    return #names
end

--- A listener's word on what its client did with a sound: journalled, and a
--- refusal by the host is rescued through the platform's fan-out.
-- @param playerId number the listener
-- @param payload table `{ token, ok, how, streamed, reason }`
-- @return boolean whether the answer was one this half was waiting for
function M.Heard(playerId, payload)
    if type(payload) ~= 'table' then return false end
    local token = tonumber(payload.token)
    local wait = token ~= nil and heardBy[token] or nil
    -- Only a listener that was SENT the sound may answer for it, and only once.
    if wait == nil or wait.sent[playerId] ~= true then return false end
    wait.sent[playerId] = 'answered'
    local how = type(payload.how) == 'string' and payload.how:sub(1, 40) or '?'
    local reason = type(payload.reason) == 'string' and payload.reason:sub(1, 80) or '?'
    if payload.ok == true then
        Open77.log.info(('player %d heard %s of %s: playing %s')
            :format(playerId, wait.event, M.KeyOf(wait.id), how))
        return true
    end
    local block = settings().SOUNDS
    local rescued = 'not rescued'
    -- A hull that is not streamed on that machine is one the platform's own
    -- fan-out would drop just the same; only a REFUSAL by the host is rescued.
    if payload.streamed ~= false and type(block) == 'table' and block.RESCUE ~= false then
        local ok, why = rescue(wait, playerId)
        rescued = ok and 'rescued through the platform\'s fan-out'
            or ('the platform\'s fan-out refused too: ' .. tostring(why))
    end
    Open77.log.warn(('player %d could not play %s of %s (%s): %s')
        :format(playerId, wait.event, M.KeyOf(wait.id), reason, rescued))
    return true
end

--- The landing call's half of a pilot's report (`CALLOUTS`): a descent starts
--- the hull's call, and a touchdown, a take-off or a landing called off ends
--- it. Only a body seated in that hull speaks for its flight.
-- @return boolean|nil what `Start` or `Stop` answered, nil when nothing applied
-- @return string|nil why not
function M.Called(playerId, payload)
    if M.Callout == nil or type(payload) ~= 'table' then return nil end
    if type(settings().CALLOUTS) ~= 'table' then return nil, 'callouts_off' end
    local which = tostring(payload.which)
    if M.MOMENTS[which] ~= true then return nil, 'unknown_moment' end
    local seat = seatOf(playerId)
    if seat == nil or not M.SameHull(seat.vehicleId, payload.id) then return nil, 'not_aboard' end
    local snapshot, id = hullOf(seat.vehicleId)
    if snapshot == nil then return nil, 'no_hull' end
    local kind = M.CalloutKind(snapshot.record)
    if kind == nil then return nil, 'no_call_for_this_hull' end
    if which == 'descent' then
        return M.Callout.Start(id, kind, ('the descent player %d reported'):format(playerId))
    end
    return M.Callout.Stop(id, which)
end

-- ── the rules other resources register ───────────────────────────────────────

--- Puts a rule on a hull. `rule.pilots` is a list of player ids who may take
--- the controls (absent: anybody, the lock still applies to nobody named);
--- `rule.passengers = false` closes the passenger seats to everybody else;
--- `rule.reason` is the refusal code the others read (`not_crew` by default).
-- @param id any
-- @param rule table
-- @return boolean
function M.Allow(id, rule)
    if id == nil or type(rule) ~= 'table' then return false end
    local pilots = nil
    if type(rule.pilots) == 'table' then
        pilots = {}
        for _, raw in ipairs(rule.pilots) do
            local playerId = validPlayer(raw)
            if playerId ~= nil then pilots[playerId] = true end
        end
    end
    registry[M.KeyOf(id)] = {
        pilots = pilots,
        passengers = rule.passengers ~= false,
        reason = type(rule.reason) == 'string' and rule.reason:sub(1, 32) or nil,
        owner = type(GetInvokingResource) == 'function' and GetInvokingResource() or nil,
    }
    return true
end

--- Takes a hull's rule away.
-- @return boolean whether it had one
function M.Forget(id)
    if id == nil then return false end
    local key = M.KeyOf(id)
    local had = registry[key] ~= nil
    registry[key] = nil
    return had
end

--- Takes away every rule a resource registered: it stopped, and a rule nobody
--- keeps would shut a door for good.
-- @param owner string the resource
-- @return integer how many rules went
function M.ForgetOwnedBy(owner)
    if type(owner) ~= 'string' then return 0 end
    local gone = 0
    for key, rule in pairs(registry) do
        if rule.owner == owner then
            registry[key] = nil
            gone = gone + 1
        end
    end
    return gone
end

--- A client that started: everything it should know is sent again on the
--- next pass of each job (its door at the next scan, its pads and calls at
--- the next tell), and it is answered (`WELCOME`): it says hello until it is.
-- @param playerId number
-- @param payload table|nil `{ try, version, why }`
function M.Hello(playerId, payload)
    if M.WalkOutServer ~= nil then M.WalkOutServer.Hello(playerId, payload) end
    -- Whether its client knows the boarding step (server/enter.lua).
    if M.EnterServer ~= nil then M.EnterServer.Hello(playerId, payload) end
    -- Its screen can answer an exit scene from now on (server/sync.lua).
    if M.Sync ~= nil then M.Sync.Hello(playerId) end
    told[playerId] = nil
    if M.Pads ~= nil then M.Pads.Forget(playerId) end
    if M.Callout ~= nil then M.Callout.Forget(playerId) end
    pcall(TriggerClientEvent, M.Event.WELCOME, playerId, { version = M.VERSION })
    local info = type(payload) == 'table' and payload or {}
    local try = math.tointeger(tonumber(info.try))
    local version = type(info.version) == 'string' and info.version:sub(1, 16) or nil
    local why = type(info.why) == 'string' and info.why:sub(1, 40) or nil
    local parts = {}
    if try ~= nil then parts[#parts + 1] = ('try %d'):format(try) end
    if why ~= nil then parts[#parts + 1] = why end
    if version ~= nil then
        parts[#parts + 1] = version == M.VERSION and ('client %s'):format(version)
            or ('client %s, the server %s'):format(version, M.VERSION)
    end
    Open77.log.info(('player %d\'s client said hello%s: its door, pads and landing calls are sent again, and every exit '
        .. 'near it waits for its screen'):format(playerId, #parts > 0 and (' (' .. table.concat(parts, ', ') .. ')') or ''))
    -- A GAME WITHOUT THE CLIPS (1.7.2): open77_avexit's package is not
    -- registered on it -- its archive is not in the game it started with. Said
    -- whenever its hello says so, with what the launcher told that game.
    local anim = type(info.anim) == 'table' and info.anim or nil
    if anim ~= nil and anim.known == true and anim.ok ~= true then
        local launcher = type(info.launcher) == 'table' and info.launcher or nil
        local function word(value, n)
            return type(value) == 'string' and value:gsub('[^%w%.:%-_]', ''):sub(1, n) or '?'
        end
        local started = 'what its launcher did is not known'
        if launcher ~= nil and launcher.launched ~= true then
            started = 'it was not started by the Open77 launcher (Steam, a shortcut): only the launcher lays a world\'s mods'
        elseif launcher ~= nil then
            started = ('its launcher started it for server %s at %s with the mods of digest %s -- compare this server\'s '
                .. '"Required mods: ... digest=" line: another digest means the server list gave out another copy\'s '
                .. 'mods'):format(word(launcher.server, 40), word(launcher.endpoint, 64), word(launcher.digest, 12))
        end
        Open77.log.warn(('player %d\'s game has no AV animation package (%s): its boardings and exits are plain, '
            .. 'without the step, until it restarts through the launcher; %s'):format(playerId,
            word(anim.reason, 80), started))
    end
end

--- What this half holds, for the console and the suite.
-- @return table
function M.Status()
    local doors, rules, players, settling = 0, 0, 0, 0
    for _ in pairs(doorLedger) do doors = doors + 1 end
    for _ in pairs(registry) do rules = rules + 1 end
    for _, key in pairs(told) do if key ~= false then players = players + 1 end end
    local now, settle = M.Now(), M.BoardSettings().settle
    for _, at in pairs(fresh) do if now - at < settle then settling = settling + 1 end end
    return {
        doorsOpen = doors, rules = rules, playersAtADoor = players, settling = settling,
        pendingBoardings = #pending,
        watch = M.Watch ~= nil and M.Watch.Status() or nil,
        pads = M.Pads ~= nil and M.Pads.Status() or nil,
        calls = M.Callout ~= nil and M.Callout.Status() or nil,
    }
end

-- ── the phases ───────────────────────────────────────────────────────────────

--- Forgets everything the phases keep. Shared by start and stop so a restart
--- starts clean.
local function reset()
    registry, spoke, told, aircraftRecords = {}, {}, {}, {}
    doorLedger, occupancy, pending, boarding, heardBy, warned = {}, {}, {}, {}, {}, {}
    fresh = {}
    soundSerial = 0
    scanJob, tendJob, calloutJob, padJob = nil, nil, nil, nil
    if M.Watch ~= nil then M.Watch.Reset() end
    if M.Callout ~= nil then M.Callout.Reset() end
    if M.Pads ~= nil then M.Pads.Reset() end
    if M.Landing ~= nil then M.Landing.Reset() end
    if M.Snap ~= nil then M.Snap.Reset() end
    if M.EnterServer ~= nil then M.EnterServer.Reset() end
end

--- Answers a console command: the console prints it, a player reads it.
local function output(source, raw, success, text)
    print(text)
    local id = validPlayer(source)
    if id ~= nil then
        pcall(TriggerClientEvent, 'open77:command:result', id, raw or '', success == true, text)
    end
end

--- Tells the asker what the press came to.
local answer
answer = function(player, boarded)
    local sent, failure = pcall(TriggerClientEvent, M.Event.BOARDED, player, {
        ok = boarded.ok == true,
        seat = boarded.ok and boarded.value.seat or nil,
        role = boarded.ok and boarded.value.role or nil,
        reason = boarded.ok ~= true and tostring(boarded.error) or nil,
        detail = boarded.ok ~= true and boarded.detail or nil,
    })
    if not sent then
        Open77.log.warn(('%d could not be told what the press came to: %s')
            :format(player, tostring(failure)))
    end
end

-- The animated boarding (server/enter.lua) answers its seat the same way.
M.AnswerBoard = function(player, boarded) return answer(player, boarded) end

--- The key, judged now and again when the body is seated: the door swings
--- first, and a verdict that stopped being true in that half second (somebody
--- else took the seat, the hull moved, the player was hurt) is caught by the
--- second look.
-- @param player number
-- @param payload table `{ id }`
function M.Press(player, payload)
    if boarding[player] or (M.EnterServer ~= nil and M.EnterServer.Busy(player)) or M.Cooling(player, 'board', 700) then
        return answer(player, M.Err('busy'))
    end
    local verdict, why = M.Verdict(player, payload.id)
    if verdict == nil then return answer(player, M.Err(why or 'no_aircraft')) end
    -- THE BOARDING, ANIMATED (1.7.0, server/enter.lua): the client is asked for
    -- the step up into the door, and the seat comes at its end. Whatever it
    -- lacks, the press goes on below as it always did.
    if M.EnterServer ~= nil then
        local ran, took = pcall(M.EnterServer.Begin, player, verdict)
        if not ran then
            Open77.log.error('the boarding step could not begin: ' .. tostring(took))
        elseif took then
            return
        end
    end
    local board = M.BoardSettings()
    local door = M.ExitDoorName(verdict.record, verdict.seat)
    -- A HULL THAT APPEARED A MOMENT AGO is boarded once it has settled (see
    -- `M.Fresh`): the door opens on the press and the body steps in then.
    local settling = M.SettleLeft(verdict.id)
    local wait = math.max(board.delay, settling)
    if wait <= 0 or (door == nil and settling <= 0) then
        return answer(player, M.Board(player, verdict.id, { door = true }))
    end
    local options = { door = true }
    if door ~= nil then
        local opened, reason = M.OpenDoor(verdict.id, door, wait + board.hold, 'board')
        if not opened then
            -- A door the host will not swing is no reason to refuse the seat.
            Open77.log.warn(('%d boards %s without its %s door (%s)')
                :format(player, tostring(verdict.id), door, tostring(reason)))
            if settling <= 0 then return answer(player, M.Board(player, verdict.id)) end
            options = nil
        end
    end
    if settling > 0 then
        Open77.log.info(('%d boards %s in %d ms: the hull appeared a moment ago and '
            .. 'settles first'):format(player, tostring(verdict.id), wait))
    end
    boarding[player] = true
    later(wait, function()
        boarding[player] = nil
        answer(player, M.Board(player, verdict.id, options))
    end)
end

function M.Start()
    reset()

    RegisterNetEvent(M.Event.BOARD, function(payload)
        local player = validPlayer(source)
        if player == nil or type(payload) ~= 'table' then return end
        M.Press(player, payload)
    end)

    -- A CLIENT THAT HAS JUST STARTED knows nothing: a door, a pad or a call
    -- sent before its handlers were registered went nowhere, and this half
    -- only sends what CHANGED. So it says hello, and is told everything again.
    RegisterNetEvent(M.Event.HELLO, function(payload)
        local player = validPlayer(source)
        if player == nil or M.Cooling(player, 'hello', 250) then return end
        M.Hello(player, payload)
    end)

    -- A LISTENER'S ANSWER TO A SOUND. It carries no authority: the token names
    -- a sound this half sent that listener, and only that listener may answer.
    RegisterNetEvent(M.Event.PLAYED, function(payload)
        local player = validPlayer(source)
        if player == nil or type(payload) ~= 'table' then return end
        if M.Cooling(player, 'played', 100) then return end
        M.Heard(player, payload)
    end)

    RegisterNetEvent(M.Event.SOUND, function(payload)
        local player = validPlayer(source)
        if player == nil then return end
        if M.Cooling(player, 'sound', 500) then return end
        M.Speak(player, payload)
        M.Called(player, payload)
    end)

    -- WHO STEPPED OUT OF WHICH SEAT, from the platform's own ledger.
    AddEventHandler('onVehicleOccupancyChanged', function(id)
        local ran, failure = pcall(M.Occupancy, id)
        if not ran then
            Open77.log.error('an occupancy change could not be read: ' .. tostring(failure))
        end
    end)

    -- EVERY AIRCRAFT IS NEW FOR A MOMENT: nobody boards it through the door
    -- before its projection settled (`BOARD.SETTLE_MS`).
    AddEventHandler('onVehicleCreated', function(id, _, record)
        if id ~= nil and aircraft(record) then M.Fresh(id) end
    end)

    AddEventHandler('onVehicleRemoved', function(id)
        if id == nil then return end
        for key in pairs(occupancy) do
            if M.SameHull(key, id) then occupancy[key] = nil end
        end
        registry[M.KeyOf(id)] = nil
        -- A hull taken out of the world takes its landing call and its pad with it.
        if M.Callout ~= nil and M.Callout.IsLive(id) then M.Callout.Kill(id, 'the hull was removed') end
        if M.Pads ~= nil and M.Pads.Has(id) then M.Pads.Stop(id, 'the hull was removed') end
    end)

    AddEventHandler('onPlayerDisconnected', function(playerId)
        local id = tonumber(playerId)
        if id ~= nil then
            told[id] = nil
            riders[id] = nil
            boarding[id] = nil
            M.ForgetCooling(id)
            if M.Watch ~= nil then M.Watch.Forget(id) end
            if M.Pads ~= nil then M.Pads.Forget(id) end
            if M.Callout ~= nil then M.Callout.Forget(id) end
            if M.Landing ~= nil then M.Landing.Forget(id) end
            if M.WalkOutServer ~= nil then M.WalkOutServer.Forget(id) end
            if M.Land ~= nil then M.Land.Forget(id) end
            if M.Sync ~= nil then M.Sync.Forget(id) end
            if M.Snap ~= nil then M.Snap.Forget(id) end
            if M.EnterServer ~= nil then M.EnterServer.Forget(id) end
        end
    end)

    -- THE WATCH: every aircraft's change of hands, and every viewer's word
    -- about where it draws one (`server/watch.lua`).
    if M.Watch ~= nil and M.WatchSettings().off ~= true then M.Watch.Start() end

    RegisterCommand(M.Command.WHY, function(source, _, raw)
        output(source, raw, true, M.Explain(source))
    end, false)

    -- RIDE ALONG (1.8.0): `/avdoor.ride` boards the typing player as a
    -- passenger from now on (`on`), as before (`off`), or the other way round
    -- (no word). The card says which at the next scan.
    RegisterCommand(M.Command.RIDE, function(source, args, raw)
        local id = validPlayer(source)
        if id == nil then
            output(source, raw, false, 'avdoor.ride needs a player: type it in chat in game')
            return
        end
        local word = type(args) == 'table' and type(args[1]) == 'string' and args[1]:lower() or nil
        local ride
        if word == 'on' or word == 'yes' or word == '1' then ride = true
        elseif word == 'off' or word == 'no' or word == '0' then ride = false
        else ride = riders[id] ~= true end
        riders[id] = ride or nil
        told[id] = nil
        Open77.log.info(('player %d %s (avdoor.ride)'):format(id, ride
            and 'rides along from now on: a passenger seat wherever one is open to them'
            or 'boards as before: the controls when the aircraft is theirs to fly'))
        local passengers = settings().PASSENGERS == true
        output(source, raw, true, ride
            and ('avdoor.ride: you board aircraft as a passenger now -- the card says "Ride along"; in a Rayfield '
                .. 'Excalibur the back seat first. Type it again to fly.%s'):format(passengers and ''
                    or ' (This server closes the passenger seats of aircraft no resource made a rule for: there you still fly.)')
            or 'avdoor.ride: you board aircraft as before -- the controls when the aircraft is yours to fly.')
    end, false)

    -- THE GROUND TEST (1.5.3, client/groundtest.lua): what the typing player's
    -- game says of the ground after a move, under the platform's freeze and
    -- after a move while held -- on foot, about twenty seconds, written to that
    -- game's own log. Anyone may run it on their own body.
    local groundAsked = {}
    RegisterCommand(M.Command.GROUNDTEST, function(source, _, raw)
        local id = math.tointeger(tonumber(source))
        if id == nil or id <= 0 then
            output(source, raw, false, 'avdoor.groundtest needs a player: type it in chat in game, on foot')
            return
        end
        local now = M.Now()
        if groundAsked[id] ~= nil and now - groundAsked[id] < 25000 then
            output(source, raw, false, 'avdoor.groundtest: already running on your game (about 20 s)')
            return
        end
        groundAsked[id] = now
        local sent, failure = pcall(TriggerClientEvent, M.Event.GROUNDTEST, id, { asked = 'avdoor.groundtest' })
        if not sent then
            output(source, raw, false, 'avdoor.groundtest: your game could not be told: ' .. tostring(failure))
            return
        end
        Open77.log.info(('ground test asked by player %d: their game runs it now; its client log has the results'):format(id))
        output(source, raw, true, 'avdoor.groundtest: your game runs the ground test now -- about 20 seconds; stand '
            .. 'still on flat ground and keep your hands off the keys. Its results are in your game\'s log.')
    end, false)

    -- THE PADS (server/snap.lua): the snap's counts, what it flies now and the
    -- pads nearest to the typing player.
    RegisterCommand(M.Command.PADS, function(source, _, raw)
        if M.Snap == nil then
            output(source, raw, false, 'avdoor.pads: no pad snap in this build')
            return
        end
        local x, y, z = nil, nil, nil
        local id = validPlayer(source)
        if id ~= nil then
            local body = bodyOf(id)
            if body ~= nil then x, y, z = body.x, body.y, body.z end
        end
        output(source, raw, true, M.Snap.Describe(x, y, 5, z))
    end, false)

    RegisterCommand(M.Command.STATUS, function(source, _, raw)
        local s = M.Status()
        local w = M.WalkOutServer ~= nil and M.WalkOutServer.Status() or nil
        local y = M.Sync ~= nil and M.Sync.Status() or nil
        local e = M.EnterServer ~= nil and M.EnterServer.Status() or nil
        local n = M.Snap ~= nil and M.Snap.Status() or nil
        output(source, raw, true, ('open77_avdoor: %d door(s) open, %d rule(s), %d player(s) at a door, '
            .. '%d hull(s) settling, %d boarding(s) pending; watch %s; %d pad(s); %d landing call(s); exit clips %s; '
            .. 'exit sync %s; boarding steps %s; pad snap %s; the game\'s own entry %s')
            :format(s.doorsOpen, s.rules, s.playersAtADoor, s.settling, s.pendingBoardings,
                s.watch and ('%d hull(s), %d open sight(s)'):format(s.watch.hulls, s.watch.sights) or 'off',
                s.pads and #s.pads or 0, s.calls and #s.calls or 0,
                w and ('%d played, %d refused, %d without, %d asked; %d styled; %d hidden now')
                    :format(w.played, w.refused, w.none, w.asked, w.styled, w.hiddenNow) or 'off',
                y and ('%d scene(s), %d open, %d held (%.1fs in all), %d screen(s) late, %d report(s), %d thing(s) '
                    .. 'wrong, %d AV re-publish(es); %d client(s) said hello (%d only by answering an exit)')
                    :format(y.scenes, y.open, y.held, y.heldMs / 1000.0, y.late, y.reports, y.problems,
                    y.republished, y.hellos or 0, y.lateHellos or 0) or 'off',
                e and ('%d asked, %d played, %d seated, %d plain (%d without, %d refused, %d silent, %d failed), %d now')
                    :format(e.asked, e.played, e.seated, e.plain, e.none, e.refused, e.silent, e.failed, e.now) or 'off',
                n and ('%d pad(s), %d flying now, %d caught, %d set down, %d hovered, %d refused'):format(n.pads or 0,
                    #(n.flying or {}), n.caught or 0, n.landed or 0, n.hovered or 0, n.refused or 0) or 'off',
                M.NativeEntry ~= nil and (function()
                    local g = M.NativeEntry.Status()
                    return ('%s: %d held now, %d held, %d released, %d set again, %d refused; %d boarding(s) through it '
                        .. '(%d with a hold)'):format(M.NativeSettings().shut and 'shut near aircraft' or 'open',
                        g.holding, g.held, g.released, g.reasserted, g.failed, g.gameEntries, g.gameEntriesHeld)
                end)() or 'not in this build'))
    end, true)

    scanJob = M.Every('scan', math.floor(M.Number(settings().SCAN_MS, 100, 5000, 500)), function()
        M.Scan()
    end)

    -- THE TENDING JOB: the delayed boardings and every door this half opened
    -- and owes a closing. A tenth of a second, the finest a door is looked at.
    tendJob = M.Every('tend', 100, function()
        M.Tend()
        if M.WalkOutServer ~= nil then M.WalkOutServer.Tend() end
        if M.EnterServer ~= nil then M.EnterServer.Tend() end
        if M.Land ~= nil then M.Land.Tend() end
        if M.Sync ~= nil then M.Sync.Tend() end
    end)

    -- THE HULL ON ITS GEAR (server/land.lua): the exiting game's measure.
    if M.Land ~= nil then M.Land.Start() end

    -- THE EXIT CLIP: the style, the clip, what the others see (server/walkout.lua).
    if M.WalkOutServer ~= nil then M.WalkOutServer.Start() end
    if M.EnterServer ~= nil then M.EnterServer.Start() end
    -- The exit key of an airframe the game's own exit animates (1.9.0).
    if M.LeaveServer ~= nil then M.LeaveServer.Start() end

    -- THE EXIT SCENE: every screen near an exit, in step, and what each drew
    -- (server/sync.lua).
    if M.Sync ~= nil then M.Sync.Start() end

    -- THE PAD SNAP: every AV pad of the game, and the glide onto one
    -- (server/snap.lua, server/padlist.lua).
    if M.Snap ~= nil then M.Snap.Start() end

    -- THE LANDING CALLS follow their hulls.
    local calls = type(settings().CALLOUTS) == 'table' and settings().CALLOUTS or nil
    if calls ~= nil and M.Callout ~= nil then
        calloutJob = M.Every('callout', math.floor(M.Number(calls.FOLLOW_MS, 50, 2000, 150)), function()
            M.Callout.Tend()
        end)
    end

    -- THE LANDING PADS: whoever comes near a hull a resource flies is told to
    -- draw the pad under it (`server/pad.lua`).
    local pads = M.Pads ~= nil and M.Pads.Settings() or nil
    if pads ~= nil then
        padJob = M.Every('pads', pads.tellMs, function()
            M.Pads.Tend()
        end)
    end

    Open77.log.info(('ready: aircraft doors within %.1f m, measured every %d ms, pilots: %s, '
        .. 'passengers %s, new aircraft settle %d ms')
        :format(M.Number(settings().REACH_METRES, 1.0, 50.0, 9.0),
            math.floor(M.Number(settings().SCAN_MS, 100, 5000, 500)),
            settings().PILOTS == 'registered' and 'registered only' or 'anyone the hull is not locked for',
            settings().PASSENGERS == true and 'on' or 'off', M.BoardSettings().settle))
end

function M.Stop()
    M.Cancel(scanJob)
    M.Cancel(tendJob)
    M.Cancel(calloutJob)
    M.Cancel(padJob)
    -- Every landing call is released with it: a stopped resource moves nothing.
    if M.Callout ~= nil then M.Callout.KillAll('the resource stopped') end
    -- Every body hidden for its exit is shown again.
    if M.WalkOutServer ~= nil then M.WalkOutServer.Stop() end
    if M.Land ~= nil then M.Land.Stop() end
    if M.Sync ~= nil then M.Sync.Stop() end
    -- A hull the snap was flying is let go, its freeze off.
    if M.Snap ~= nil then M.Snap.Stop() end
    if M.EnterServer ~= nil then M.EnterServer.Stop() end
    if M.LeaveServer ~= nil then M.LeaveServer.Stop() end
    -- Every hold on the game's own entry is given back.
    if M.NativeEntry ~= nil then pcall(M.NativeEntry.Stop) end
    -- Every pad comes off every game that was drawing one.
    if M.Pads ~= nil then M.Pads.StopAll('the resource stopped') end
    -- Every card this half drew comes down with it.
    for playerId, key in pairs(told) do
        if key ~= false then
            pcall(TriggerClientEvent, M.Event.DOOR, playerId, { open = false })
        end
    end
    -- Every door this half opened is closed with it.
    local api = Open77 ~= nil and Open77.vehicles or nil
    if type(api) == 'table' and type(api.closeDoor) == 'function' then
        for _, entry in pairs(doorLedger) do
            pcall(api.closeDoor, entry.id, entry.door)
        end
    end
    reset()
end
