-- =============================================================================
-- open77_avdoor -- client/main.lua
-- =============================================================================
-- The card at an aircraft's door, the key, the exit -- the guard that stands
-- the body beside the door, and the curtain the exit clip brings down -- the
-- watch over where this screen draws other aircraft, and the MaxTac AV's voice
-- for everybody near it.
--
-- THE CARD IS THE SERVER'S WORD. The server is the side that knows where every
-- aircraft stands, so it measures this body against every aircraft in its
-- bucket and says which door, if any, is open to it (`DOOR`). The card
-- (open77_interactions) is drawn from that word, hung on the hull, and taken
-- down the moment the body is seated; the key sends the hull's id and nothing
-- else, and the server judges it again from scratch. The server swings the
-- seat's door before it seats the body, so the press is answered (`BOARDED`)
-- about half a second later.
--
-- THE EXIT. The platform carries the body out of an AV in one cut and,
-- measured in a client log on XyberRP (2026-09-29), it does so INSIDE the hull:
-- the engine drops the body at the cockpit's exit point, the chassis wakes and
-- knocks the body down at +0.4 s, and the platform's own deferred eject sets it
-- 3.5 m behind and 2 m UNDER the hull's centre at about +1.7 s (that eject no
-- longer reaches the local player on 2.50: no Staging exit logged one). So the
-- moment a seat in an aircraft starts to empty this half puts the body on the
-- ground beside its seat's door, on the ground the static ray finds there, and
-- puts it back if the platform moves it (`EXIT`, the guard) -- WITH THE IMAGE
-- ON (1.6.0): the native quest fade holds the body still wherever it is, so a
-- body put beside the door under the old cut to black hung there in the air
-- for as long as the screen was black. The client hides the pilot's body for
-- 1.6 s and its chase camera holds the AV in view for 1.5 s while the body
-- lands; the exit clip brings a short curtain down only once the body stands
-- there, held (`M.CurtainDown`, `EXIT_FADE`; client/walkout.lua), and every
-- move lifts it first. The server opens that door for everybody as the seat
-- empties. The hull's place is the frame it FLEW at, read while the body was
-- aboard (`keepFlown`): an exit un-masks a hull flown off its pad and the
-- engine drags it back to where the flight began for a fifth of a second, so
-- its frame at that instant is not where the body stepped out.
--
-- THE WATCH. Every client measures where it draws each nearby aircraft it does
-- not simulate against the newest sample of it, and tells the server when the
-- two part (`WATCH`, see `M.Sight`), so a drift on somebody else's screen is a
-- line in the server's log and not only a report.
--
-- THE VOICE. While this client is the one flying a MaxTac AV (its seat is in
-- the hull and the hull is simulated here), the flight is read four times a
-- second -- the seated body's height over the ground under it
-- (`Open77.world.groundZ`) and the climb rate -- and the moments the base game
-- gives that aircraft a voice for (lifting off, coming down to land, touching
-- down) are sent to the server, which sends every listener near the hull the
-- sound to play on the airframe -- this pilot included. Every listener's
-- client answers what it did with the sound (`PLAYED`). The same reads start
-- and end the landing call of an AV that has one (`client/callout.lua`).
-- =============================================================================

local M = AvDoor

local RESOURCE = GetCurrentResourceName()

-- The door the server last named for this body: `{ id, role, at }`.
local door = nil

-- The card as drawn: `{ handle, signature }`; and whether the card must be
-- brought in line with `door` on the next pass (the interactions service is
-- called from the watch thread, never from an event handler).
local card = nil
local cardDirty = false
local reportedCard = false

-- The seat this client held on the last read, and the curtain (1.6.0): the
-- native fade the exit clip brings down once the body stands beside the door
-- (`{ id, since, block, why, by, tries }`), or nil.
local lastSeat = nil
local fading = nil
-- How many times the curtain came down for the exit in progress, and when that
-- exit began (`{ at, tries }`).
local curtainCount = nil

-- The exit guard (its state and its 50 ms job), and when the last exit ended,
-- so a seat the platform keeps flagged as leaving is one exit and not a loop of
-- fades.
local guard = nil
local guardJob = nil
local lastExit = nil

-- THE EXIT'S DRAG (1.6.1). An exit un-masks the hull and this game's engine
-- drags it back, for a fifth of a second, to where its first flight here began
-- -- the pad its never-moved chassis still holds -- and carries the leaving body
-- along (XyberRP Staging, 2026-10-28, 13:20:43: the body 15.5 m from the hull
-- where it stood, "a move made elsewhere", no clip). `padOf[key]` is that pad
-- as this game learnt it -- where the hull stood when it was first boarded
-- here, then the dragged frame each exit sees -- `{ x, y, z, at, how }`.
-- `exitFirst` is the exit's very first look (the hull this game draws and the
-- body, before anything breathes), for the guard; `dragSeen` the drag that look
-- found, `{ key, engine, real, at }`, so a network frame that carries it for a
-- moment (the server took the dragged pose, server/watch.lua) is not planned on.
local padOf = {}
local exitFirst = nil
local dragSeen = nil

-- When the last press was sent, so a second press while the door swings is the
-- same press.
local askedAt = nil

-- Which vehicle ids are aircraft (and MaxTac voices), memoised per id.
local kinds = {}

-- The flight as last read, for the voice, and when it was last read.
local flight = nil
local flightAt = 0

-- Which events have already been said in the log, so a missing sound is one
-- line and not one per landing.
local heard = {}

-- The one watch job.
local watchJob = nil
local cardJob, sightJob, sceneJob = nil, nil, nil

-- THE HELLO. The server's exit sync waits only for the screens it heard from,
-- and a hello sent while the game was still loading went nowhere (Staging,
-- 2026-10-28: no hello from either machine reached the server in any session).
-- So it is said at start and when the world is ready, then every
-- `HELLO_EVERY_MS` until the server answers (`WELCOME`) -- `HELLO_TRIES` times,
-- then every `HELLO_LATE_MS`: `{ tries, firstAt, at, welcomed, failures }`.
local HELLO_EVERY_MS = 3000
local HELLO_TRIES = 20
local HELLO_LATE_MS = 30000
local greeting = nil

-- THE EXIT AT ITS FIRST FRAME. While the body sits in an aircraft its seat is
-- read every frame (`Wait(SENTINEL_MS)`: the next frame at up to a hundred
-- frames a second), not at the watch's tenth of a second: the platform's own
-- exit drops the body beside the hull at the seat's height, and the sooner it
-- is put beside the door, the sooner it lands there (1.6.0: with the image on;
-- `EXIT_FADE`). `{ live, looks, since }`, or nil.
local SENTINEL_MS = 10
local sentinel = nil

-- THE WATCH (`WATCH` in the config): the open drift episodes, by hull id as
-- text -- `{ since, worst, calm, reportedAt, seenAt }` -- the reports owed to
-- the server (one goes out per look), when the last look was, and whether this
-- client's snapshots carry a position at all.
local sights = {}
local sightQueue = {}
local sightAt = 0
local sightBlind = false

-- How often the flight is read while this client flies a voiced AV.
local FLIGHT_MS = 250

-- The guard's pace, and how it judges a body it has moved: within this far of
-- the place it was put the move has landed; a placement that has not landed
-- after `PLACE_WAIT_MS` is made again; and it is made at most `MAX_PLACEMENTS`
-- times, so something else that keeps moving the body is not fought forever.
local GUARD_MS = 50
local ARRIVE_METRES = 1.5
local PLACE_WAIT_MS = 150
local MAX_PLACEMENTS = 8

-- How long after a press a second one is the same press.
local ASK_HOLD_MS = 1200

-- How long a seat the platform keeps flagged as leaving is still the exit that
-- began it: a second `leaving` for the same hull inside this is not a second
-- fade and a second placement.
local EXIT_HOLD_MS = 5000

-- How often the hull's frame is read while the body sits in an aircraft. The
-- read is the frame the hull FLEW at, kept because the engine's own frame is
-- not to be trusted at the moment of the exit (see `beginGuard`).
local FRAME_MS = 250

-- The card hangs this far over the hull's origin, and is live this far beyond
-- the server's own reach (the card's point is lifted, the server measures to
-- the hull's centre).
local CARD_LIFT = 1.6
local CARD_SLACK = 1.5

local function settings()
    return type(M.Settings) == 'table' and M.Settings or {}
end

--- The card's key: one letter (the interactions service takes A to Z).
local function cardKey()
    local declared = settings().KEY
    if type(declared) == 'string' and declared:match('^%a$') then return declared:upper() end
    return 'F'
end

local function vehiclesApi()
    local api = Open77.vehicles
    return type(api) == 'table' and api or nil
end

--- The local seat, or nil.
local function mySeat()
    local api = vehiclesApi()
    if api == nil or type(api.getPlayerSeat) ~= 'function' then return nil end
    local read, seat = pcall(api.getPlayerSeat)
    if read and type(seat) == 'table' and seat.vehicleId ~= nil then return seat end
    return nil
end

--- One streamed hull's snapshot, or nil. The host reads an id as an integer or
--- as its decimal string; the other spelling is tried before giving up.
local function hull(id)
    local api = vehiclesApi()
    if api == nil or type(api.get) ~= 'function' or id == nil then return nil end
    local read, snapshot = pcall(api.get, id)
    if read and type(snapshot) == 'table' then return snapshot end
    local number = tonumber(id)
    if number ~= nil and number ~= id then
        read, snapshot = pcall(api.get, number)
        if read and type(snapshot) == 'table' then return snapshot end
    end
    return nil
end

--- What a vehicle is to this resource, memoised by id: `{ record, aircraft, voiced, callout }`.
-- `voiced` is a MaxTac AV with the base game's sounds (`SOUNDS.RECORDS`);
-- `callout` is the landing call its record makes (`CALLOUTS.KINDS`), or nil.
-- A vehicle's record never changes, so one snapshot read per id is enough.
-- @param id any
-- @return table|nil nil while the vehicle is not streamed
local function kindOf(id)
    local key = M.KeyOf(id)
    local known = kinds[key]
    if known ~= nil then return known end
    local snapshot = hull(id)
    if snapshot == nil then return nil end
    local sounds = type(settings().SOUNDS) == 'table' and settings().SOUNDS or nil
    known = {
        record = snapshot.record,
        aircraft = M.IsAircraft(snapshot.record),
        voiced = sounds ~= nil and M.IsAircraft(snapshot.record, sounds.RECORDS) or false,
        callout = M.CalloutKind(snapshot.record, settings().CALLOUTS),
    }
    kinds[key] = known
    return known
end

--- Where the local body is, or nil. Seated, this is the seat: the body rides
--- the hull, which is why the flight is read from it.
-- @return table|nil `{ x, y, z }`
local function myself()
    local character = Open77.character
    if type(character) ~= 'table' or type(character.position) ~= 'function' then return nil end
    local read, x, y, z = pcall(character.position)
    if not read or type(x) ~= 'number' or type(y) ~= 'number' or type(z) ~= 'number' then return nil end
    if x ~= x or y ~= y or z ~= z then return nil end
    return { x = x, y = y, z = z }
end

--- A finite number, or nil.
local function finite(value)
    local number = tonumber(value)
    if number == nil or number ~= number or number == math.huge or number == -math.huge then return nil end
    return number
end

--- How far apart two points are on the ground.
local function across(a, b)
    local dx, dy = a.x - b.x, a.y - b.y
    return math.sqrt(dx * dx + dy * dy)
end

--- Whether the local body is alive: an unreadable answer is "yes", because a
--- guard that does nothing for a body that is fine is worse than one too many.
local function alive()
    local character = Open77.character
    if type(character) ~= 'table' or type(character.isAlive) ~= 'function' then return true end
    local read, answer = pcall(character.isAlive)
    return not read or answer ~= false
end

--- A native side notification, or a log line on a host without one.
local function notify(text)
    local hud = Open77.hud
    if type(hud) == 'table' and type(hud.notify) == 'function' then
        local ran = pcall(hud.notify, text, { replace = true })
        if ran then return end
    end
    Open77.log.info('notice: ' .. tostring(text))
end

-- A GAME WITHOUT THE CLIPS (1.7.2): said once a session, in the log and to the
-- player -- the moment this game knows (its hello, or the first boarding or
-- exit that finds no clips here).
local filesMissingSaid = false

--- Says, once, that this game cannot draw the AV clips: open77_avexit's
--- package is not registered here (its archive is not in the game it started
--- with), with what the launcher told this game at its start.
-- @param where string what found it, for the log
-- @param reason string|nil the registration's reason
function M.FilesMissingNotice(where, reason)
    if filesMissingSaid then return end
    filesMissingSaid = true
    local context = M.LauncherContext ~= nil and M.LauncherContext() or nil
    local started
    if context == nil then
        started = 'what the launcher told it is not known here'
    elseif not context.launched then
        started = 'it was not started by the Open77 launcher (Steam, a shortcut), and only the launcher lays a '
            .. 'world\'s mods'
    else
        started = ('the launcher started it for server %s at %s with the mods of digest %s -- when that is not this '
            .. 'server\'s ("Required mods: ... digest=" in its log), the server list gave out another copy\'s mods'):format(
            tostring(context.server or '?'), tostring(context.endpoint or '?'), tostring(context.digest or 'none'))
    end
    Open77.log.warn(('this game has no AV animation package (%s; found by %s): its boardings and exits are plain, '
        .. 'without the step; %s. Close the game and start it again through the Open77 launcher.'):format(
        tostring(reason or 'not registered'), tostring(where), started))
    notify(M.Text('files.missing'))
end

-- ── the card ──────────────────────────────────────────────────────────────────

--- Calls the interactions service and waits for its answer. From a thread only.
local function interactions(name, ...)
    local exportsApi = Open77.exports
    if type(exportsApi) ~= 'table' or type(exportsApi.call) ~= 'function' then return nil, 'no_exports' end
    local promise, reason = exportsApi.call('open77_interactions', name, ...)
    if not promise then return nil, reason end
    return promise:await()
end

--- The card hung on the server's position for the hull, or nil.
local function positionAnchor(d)
    if type(d.at) == 'table' and finite(d.at.x) and finite(d.at.y) and finite(d.at.z) then
        local at = { x = finite(d.at.x), y = finite(d.at.y), z = finite(d.at.z) }
        return { position = at }, ('at:%.0f:%.0f:%.0f'):format(at.x, at.y, at.z)
    end
    return nil, nil
end

-- Set once the interactions service refused a hull's projection as an anchor:
-- from then on every card hangs on the server's position for its hull, so a
-- refusal is one line and one fallback, not a create and a refusal per pass.
local entityRefused = false

-- A card the service refused is asked for again only after this long (or for
-- another door): a refusal is not retried ten times a second.
local CARD_RETRY_MS = 5000
local cardFailed = nil

--- What the card is hung on: the hull's own projection when this game has
--- one (the card then follows the hull as it is drawn), the server's position
--- for it otherwise.
local function anchor(d)
    if not entityRefused then
        local snapshot = hull(d.id)
        if snapshot ~= nil and snapshot.entity ~= nil and snapshot.streamed ~= false then
            return { entity = snapshot.entity }, 'entity:' .. tostring(snapshot.entity)
        end
    end
    return positionAnchor(d)
end

--- The card for a door.
local function cardDefinition(d, hang)
    local reach = M.Number(settings().REACH_METRES, 1.0, 50.0, 9.0)
    local definition = {
        id = ('avdoor:' .. tostring(d.id)):sub(1, 96),
        offset = { x = 0.0, y = 0.0, z = CARD_LIFT },
        distance = math.min(25.0, reach + CARD_SLACK),
        markerDistance = math.min(250.0, reach + 8.0),
        marker = 'vehicle',
        requireLookAt = false,
        priority = 40,
        choices = { {
            id = 'board',
            label = M.Text(d.role == 'passenger' and 'prompt.passenger' or 'prompt.pilot'),
            description = M.Text('prompt.description'),
            key = cardKey(),
            icon = 'AV',
            event = M.CHOICE,
            data = { id = tostring(d.id) },
        } },
    }
    definition.entity, definition.position = hang.entity, hang.position
    return definition
end

--- Takes the card down. From a thread only.
local function removeCard(why)
    if card == nil then return end
    local handle = card.handle
    card = nil
    if handle ~= nil then
        local answer, reason = interactions('remove', handle)
        if answer == nil and reason ~= nil and not reportedCard then
            reportedCard = true
            Open77.log.warn('the door card could not be taken down: ' .. tostring(reason))
        end
    end
    Open77.log.info('the door card is down (' .. tostring(why) .. ')')
end

--- Why a create was refused, in words.
local function refusal(answer, reason)
    return tostring(type(answer) == 'table' and (answer.error or 'refused') or reason or 'no answer')
end

--- Brings the card in line with the server's word and the body. From the
--- watch thread only: the interactions service answers through a promise.
-- THE COMMON PASS COSTS NOTHING: no door and no card is an early return before
-- a single native is read, which is what nearly every pass is.
-- @param seated boolean whether the body sits in a vehicle now
local function syncCard(seated)
    if door == nil and card == nil then return end
    -- No card while the body steps up into a door (client/enter.lua).
    local want = door ~= nil and not seated and not (M.Enter ~= nil and M.Enter.Active())
    if not want then return removeCard(seated and 'seated' or 'the door closed') end
    local hang, where = anchor(door)
    if hang == nil then return removeCard('nothing to hang it on') end
    local signature = table.concat({ door.id, door.role, where, cardKey() }, '|')
    cardDirty = false
    if card ~= nil and card.signature == signature then return end
    if card ~= nil then removeCard('the door changed') end
    if cardFailed ~= nil and cardFailed.signature == signature and M.Now() - cardFailed.at < CARD_RETRY_MS then
        return
    end
    local answer, reason = interactions('create', cardDefinition(door, hang))
    if (type(answer) ~= 'table' or answer.ok ~= true) and hang.entity ~= nil
        and refusal(answer, reason):find('entity', 1, true) ~= nil then
        -- The hull's projection was refused as an anchor: the server's position
        -- for it is the next best place to hang the card, from now on.
        entityRefused = true
        Open77.log.warn(('the door card could not hang on the hull (%s): cards hang on the '
            .. 'server\'s position for their hull from now on'):format(refusal(answer, reason)))
        hang, where = positionAnchor(door)
        if hang == nil then return end
        signature = table.concat({ door.id, door.role, where, cardKey() }, '|')
        answer, reason = interactions('create', cardDefinition(door, hang))
    end
    if type(answer) ~= 'table' or answer.ok ~= true then
        cardFailed = { signature = signature, at = M.Now() }
        if not reportedCard then
            reportedCard = true
            Open77.log.warn('the door card was refused: ' .. refusal(answer, reason))
        end
        return
    end
    cardFailed = nil
    card = { handle = answer.handle, signature = signature }
    if M.StandIn ~= nil then M.StandIn.CardUp(M.Now()) end
    Open77.log.info(('the door of %s is open to you (%s): press %s (card on %s)')
        :format(tostring(door.id), tostring(door.role), cardKey(), where))
end

--- The key: board the hull whose card is up.
-- @param origin string|nil
-- @param id any the hull the card named
-- @return table `{ ok, code }`
function M.Press(origin, id)
    if door == nil or card == nil then return { ok = false, code = 'no_aircraft' } end
    if id ~= nil and not M.SameHull(id, door.id) then return { ok = false, code = 'stale_card' } end
    -- ONE PRESS IS ONE BOARDING: the server swings the door first and seats the
    -- body about half a second later, and the card is still up until it does, so
    -- a second press inside that time is the first one again and asks for nothing.
    local now = M.Now()
    if askedAt ~= nil and now - askedAt < ASK_HOLD_MS then return { ok = false, code = 'busy' } end
    askedAt = now
    TriggerServerEvent(M.Event.BOARD, { id = door.id })
    Open77.log.info(('board asked for %s (%s)'):format(tostring(door.id), tostring(origin or 'key')))
    return { ok = true, queued = true }
end

--- Whether an exit is under way on this screen: its fade, its guard, its clip,
--- or another player's step watched or drawn here. The exit's pictures are
--- written to the store only once none is (client/shots.lua).
-- @return boolean
function M.ExitBusy()
    if fading ~= nil or (guard ~= nil and not guard.over) then return true end
    if M.WalkOut ~= nil and M.WalkOut.Active() then return true end
    -- The boarding step too: its pictures are written once it is over.
    if M.Enter ~= nil and M.Enter.Active() then return true end
    return M.Sync ~= nil and type(M.Sync.Busy) == 'function' and M.Sync.Busy() == true
end

--- Whether THIS player's own exit is under way on this screen: its curtain,
--- its guard (which puts back a body something else moved), its clip. The
--- boarding step waits for none of these: it gives the key up instead.
-- @return boolean
function M.OwnExitBusy()
    if fading ~= nil or (guard ~= nil and not guard.over) then return true end
    return M.WalkOut ~= nil and M.WalkOut.Active()
end

--- What this half knows, for a diagnostic or a test.
function M.Status()
    return {
        door = door ~= nil and door.id or nil,
        role = door ~= nil and door.role or nil,
        card = card ~= nil,
        key = cardKey(),
        seated = lastSeat ~= nil,
        aircraft = lastSeat ~= nil and lastSeat.aircraft == true or false,
        flown = lastSeat ~= nil and lastSeat.flown ~= nil or false,
        fading = fading ~= nil,
        curtain = fading ~= nil and fading.why or nil,
        curtainTries = curtainCount ~= nil and curtainCount.tries or 0,
        guarding = guard ~= nil,
        placements = guard ~= nil and guard.placements or nil,
        flight = flight ~= nil and flight.state or nil,
        height = flight ~= nil and flight.height or nil,
        -- The hello: answered by the server, and how many times it was said.
        welcomed = greeting ~= nil and greeting.welcomed == true or false,
        hellos = greeting ~= nil and greeting.tries or 0,
        sentinel = sentinel ~= nil,
        -- The exit's pictures kept on this machine (client/shots.lua).
        shots = M.Shots ~= nil and M.Shots.Status() or nil,
        -- The stand-in made ahead (client/standin.lua, 1.7.5).
        standIn = M.StandIn ~= nil and M.StandIn.Status() or nil,
        -- The exit key of an airframe the game's own exit animates (1.9.0,
        -- client/leave.lua).
        leave = M.Leave ~= nil and M.Leave.Status() or nil,
        sights = (function()
            local count = 0
            for _ in pairs(sights) do count = count + 1 end
            return count
        end)(),
    }
end

-- ── the exit ──────────────────────────────────────────────────────────────────

-- One look of the exit guard (defined with it, below).
local guardTick

local function fadeSettings()
    local block = settings().EXIT_FADE
    if type(block) ~= 'table' then return nil end
    return {
        out = math.floor(M.Number(block.OUT_MS, 0, 5000, 250)),
        back = math.floor(M.Number(block.IN_MS, 0, 5000, 550)),
        lift = math.floor(M.Number(block.LIFT_MS, 0, 5000, 0)),
        max = math.floor(M.Number(block.MAX_MS or block.MAX_HOLD_MS, 500, 30000, 6000)),
        tries = math.floor(M.Number(block.TRIES, 0, 10, 2)),
    }
end

--- The engine's own fade, whoever owns it (`Open77.screen.nativeState`):
--- `{ black, fading, out, busy, remainingMs }`, or nil when it cannot be read.
function M.ScreenState()
    local screen = Open77.screen
    if type(screen) ~= 'table' or type(screen.nativeState) ~= 'function' then return nil end
    local read, state = pcall(screen.nativeState)
    if not read or type(state) ~= 'table' then return nil end
    return { black = state.faded == true, fading = state.fading == true, out = state.out == true,
        busy = state.busy == true, remainingMs = tonumber(state.remainingMs) }
end

--- The screen as the log says it: the native fade holds the body still for as
--- long as it is out (see `EXIT_FADE`).
-- @return string
function M.ScreenText()
    local s = M.ScreenState()
    if s == nil then return 'the screen not read' end
    if s.black then return 'the screen black (a native fade: the body held still where it is)' end
    if s.fading or s.out then return 'the screen fading to black (a native fade: the body held still where it is)' end
    if s.busy or (s.remainingMs or 0) > 0 then
        return ('the screen coming back (%s ms left: the body still held where it is)'):format(tostring(s.remainingMs))
    end
    return 'the image on'
end

--- The scene the curtain's lines name: the exit's, or the boarding step's.
local function curtainScene()
    return curtainCount ~= nil and curtainCount.scene or 'exit'
end

--- THE CURTAIN (1.6.0), down: the screen black while the cameras change to
--- third person and the step is asked -- brought down by the exit clip once the
--- body stands beside the door, facing the step, held (client/walkout.lua).
--- Nothing may move the body while it is down: the native fade holds it still
--- wherever it is, in the air too.
-- @param why string for the log
-- @param outMs number|nil how long the screen takes to go black (the exit's
--   `EXIT_FADE.OUT_MS` when nil; the boarding's seat gives its own, 1.8.2)
-- @return boolean whether the screen is covered by it now
function M.CurtainDown(why, outMs)
    if fading ~= nil then return true end
    local block = fadeSettings()
    if block == nil then
        if not heard['\1curtain:off'] then
            heard['\1curtain:off'] = true
            Open77.log.info('exit curtain: none by configuration (`EXIT_FADE = false`): the step is asked in view')
        end
        return false
    end
    curtainCount = curtainCount or { tries = 0, at = M.Now() }
    if curtainCount.tries >= block.tries then
        if not curtainCount.spentSaid then
            curtainCount.spentSaid = true
            Open77.log.info(('%s curtain: down %d time(s) this %s already: the rest is asked in view (%s)')
                :format(curtainScene(), curtainCount.tries, curtainScene(), tostring(why)))
        end
        return false
    end
    local screen = Open77.screen
    if type(screen) ~= 'table' or type(screen.fadeOut) ~= 'function' then
        if not heard['\1curtain:api'] then
            heard['\1curtain:api'] = true
            Open77.log.warn('no Open77.screen.fadeOut on this client: the exit step is asked in view')
        end
        return false
    end
    -- ANOTHER FADE ALREADY COVERS THE SCREEN (a respawn, a server's move, a
    -- quest): not stacked on it -- and not ours to lift.
    local native = M.ScreenState()
    if native ~= nil and (native.black or native.fading or native.out) then
        Open77.log.info(('%s curtain: not brought down -- %s already (%s)'):format(curtainScene(), M.ScreenText(),
            tostring(why)))
        return false
    end
    local out = math.floor(M.Number(outMs, 0, 5000, block.out))
    local read, id, refusal = pcall(screen.fadeOut, { durationMs = out })
    if not read or id == nil then
        Open77.log.info(('%s curtain refused: %s'):format(curtainScene(), tostring(read and refusal or id)))
        return false
    end
    curtainCount.tries = curtainCount.tries + 1
    fading = { id = id, since = M.Now(), block = block, why = why, by = 'walk', try = curtainCount.tries }
    Open77.log.info(('%s curtain down (%s): black in %d ms, %.1fs at most, try %d of %d -- the native fade holds the '
        .. 'body still where it stands until the image is back; nothing moves it under the curtain')
        :format(curtainScene(), tostring(why), out, block.max / 1000.0, curtainCount.tries, block.tries))
    return true
end

--- THE CURTAIN, up: the image back -- with the step's first frame (`IN_MS`),
--- or at once for a move (`LIFT_MS`): a body moved under the native fade would
--- hang in the air where it was put until the image came back.
-- @param why string for the log
-- @param ms number|nil how long the image takes to come back
-- @param reveal boolean|nil take the 'reveal' picture (client/shots.lua)
-- @return boolean whether there was a curtain to lift
function M.CurtainUp(why, ms, reveal)
    if fading == nil then return false end
    local f = fading
    fading = nil
    local duration = math.floor(M.Number(ms, 0, 5000, f.block.back))
    local screen = Open77.screen
    local ok, refusal = false, 'no Open77.screen.fadeIn'
    if type(screen) == 'table' and type(screen.fadeIn) == 'function' then
        local read, answer, reason = pcall(screen.fadeIn, f.id, { durationMs = duration })
        ok, refusal = read and answer == true, read and reason or answer
    end
    Open77.log.info(('%s fade over after %.1fs (%s): the image back in %d ms%s'):format(curtainScene(),
        (M.Now() - f.since) / 1000.0,
        tostring(why), duration, ok and '' or (' -- the fade-in was refused: ' .. tostring(refusal))))
    if reveal and M.Shots ~= nil then
        M.Shots.Take('reveal', math.min(duration, 300), M.WalkOut ~= nil and M.WalkOut.ShotMeta or nil)
    end
    return true
end

--- A new scene for the curtain (the boarding step, 1.7.0): it may come down
--- `EXIT_FADE.TRIES` times again -- over the change to third person, and over
--- the seat.
-- @param why string for the log
function M.CurtainBegin(why)
    curtainCount = { tries = 0, at = M.Now(), why = why, scene = 'boarding' }
end


--- The curtain while it is down: `{ since, why, try }`, or nil.
function M.Curtain()
    if fading == nil then return nil end
    return { since = fading.since, why = fading.why, try = fading.try, max = fading.block.max }
end

--- Whether the guard is still settling the body: it has not landed the last
--- placement, or the body was moved less than `SETTLE_MS` ago.
-- @param now number
-- @return boolean
local function guardBusy(now)
    if guard == nil or guard.over then return false end
    return guard.arrived ~= true or now - guard.movedAt < guard.exit.settle
end
M.GuardBusy = function() return guardBusy(M.Now()) end
--- Whether the guard's placement of the body has not landed yet (its teleport
--- takes effect on a later frame): the exit clip judges the body after it.
M.GuardPlacing = function() return guard ~= nil and not guard.over and guard.arrived ~= true end

--- The curtain's own watch, every pass: up at its ceiling (the step then plays
--- in view), when nothing keeps it down any more (the exit clip asked for it
--- and is gone, or let it go), or on `force`.
-- @param force boolean
local function endFade(force)
    if fading == nil then return end
    local now = M.Now()
    local held = now - fading.since
    if force then
        M.CurtainUp('forced', nil, false)
        return
    end
    if held >= fading.block.max then
        Open77.log.warn(('%s curtain: %.1fs black, its ceiling -- the image comes back before the step; the step '
            .. 'plays in view'):format(curtainScene(), held / 1000.0))
        M.CurtainUp('its ceiling', nil, true)
        return
    end
    if M.WalkOut ~= nil and M.WalkOut.KeepCurtain(now) then return end
    if M.Enter ~= nil and M.Enter.KeepCurtain(now) then return end
    M.CurtainUp('nothing keeps it down', nil, true)
end

-- ── the guard ─────────────────────────────────────────────────────────────────

--- Where the engine says a hull stands and which way it faces, or nil.
-- The typed reference is asked first (it names the hull the way the server and
-- the seat ledger do), then the engine entity the snapshot carries -- never an
-- entity of 0, which the platform answers with the LOCAL PLAYER's geometry
-- (shared/core.lua, `M.EntityRef`): a hull read that way is the body itself.
-- @param id any the hull, as the seat names it
-- @return table|nil `{ x, y, z, fx, fy, bounds? }`
local function hullFrame(id)
    local world = Open77.world
    if type(world) ~= 'table' or type(world.entityGeometry) ~= 'function' then return nil end
    local refs = { { kind = 'vehicle', id = id } }
    local decimal = M.DecimalId(id)
    if decimal ~= nil and decimal ~= id then refs[#refs + 1] = { kind = 'vehicle', id = decimal } end
    local snapshot = hull(id)
    local entity = snapshot ~= nil and M.EntityRef(snapshot.entity) or nil
    if entity ~= nil then refs[#refs + 1] = entity end
    for _, ref in ipairs(refs) do
        local read, answer = M.Native('world.entityGeometry', world.entityGeometry, ref)
        if read and type(answer) == 'table' and answer.entity ~= nil and tonumber(answer.entity) == 0 then
            if not heard['\1self:' .. M.KeyOf(id)] then
                heard['\1self:' .. M.KeyOf(id)] = true
                Open77.log.warn(('the engine answered %s with the local player\'s own geometry (entity 0): not taken '
                    .. 'for the hull'):format(tostring(id)))
            end
        elseif read and M.EntityAnswer(answer) and type(answer.position) == 'table' then
            local at = answer.position
            local facing = type(answer.forward) == 'table' and answer.forward or {}
            local x, y, z = finite(at.x or at[1]), finite(at.y or at[2]), finite(at.z or at[3])
            local fx, fy = finite(facing.x or facing[1]), finite(facing.y or facing[2])
            if x ~= nil and y ~= nil and z ~= nil and fx ~= nil and fy ~= nil and (fx ~= 0 or fy ~= 0) then
                -- The loaded mesh's box, while it is streamed: the exit clip
                -- measures the hull's width from it. The client answers it in the
                -- hull's own frame (shared/core.lua, `M.BoundsLocal`).
                local bounds = type(answer.bounds) == 'table' and answer.bounds or nil
                return { x = x, y = y, z = z, fx = fx, fy = fy, bounds = bounds,
                    boundsLocal = M.BoundsLocal(bounds, { x = x, y = y, z = z }) == true }
            end
        end
    end
    return nil
end

M.HullFrame = function(id) return hullFrame(id) end

--- Where the NETWORK has a hull: the snapshot's replicated position and heading
--- (the motion its simulating game last sent, which the server holds and every
--- other game draws), as a frame, with the engine frame's mesh box when that box
--- is in the hull's own frame (it does not depend on where the hull stands).
-- @param id any the hull
-- @param engine table|nil the engine's frame, for its box
-- @return table|nil `{ x, y, z, fx, fy, bounds?, boundsLocal, network = true }`
local function networkFrame(id, engine)
    local snapshot = hull(id)
    if snapshot == nil or type(snapshot.position) ~= 'table' then return nil end
    local p = snapshot.position
    local x, y, z = finite(p.x or p[1]), finite(p.y or p[2]), finite(p.z or p[3])
    local yaw = finite(snapshot.yaw or snapshot.heading)
    if x == nil or y == nil or z == nil or yaw == nil then return nil end
    -- REDengine's yaw is 0 toward +y and grows toward -x.
    local r = math.rad(yaw)
    local box = engine ~= nil and engine.boundsLocal and engine.bounds or nil
    return { x = x, y = y, z = z, fx = -math.sin(r), fy = math.cos(r), bounds = box, boundsLocal = box ~= nil,
        network = true }
end

--- Reads the frame of the aircraft the body sits in and keeps it, when the body
--- is inside it.
--
-- THE FRAME THE HULL FLEW AT. An AV is flown kinematically: the platform moves
-- its root with the whole-vehicle mover while the chassis is masked, and the
-- chassis body stays where the flight began. The moment an exit un-masks it the
-- engine drags the root back to that body -- measured in a client log on
-- XyberRP (2026-09-30): `vflt-parkexit-unmask`, and 37 ms later the engine's
-- frame for the hull was 37.3 m from the body that had just been flying it --
-- and the platform's own pump then puts the hull back where it flew, about
-- 190 ms after. A guard that measured the engine's frame at that instant took
-- a hull flown off its pad for a body left far from it and did nothing. So the
-- frame is read here, while the body is aboard and inside the hull, and the
-- exit uses it when the engine's own frame is not where the body was.
-- @param id any the hull, as the seat names it
-- @param previous table|nil the frame kept so far
-- @return table|nil `{ x, y, z, fx, fy, at }`
local function keepFlown(id, previous)
    local now = M.Now()
    if previous ~= nil and now - previous.at < FRAME_MS then return previous end
    local frame = hullFrame(id)
    local at = myself()
    if frame == nil or at == nil then return previous end
    -- A frame the body is not inside is not the frame the hull flew at: an engine
    -- that has already dragged the hull elsewhere must not overwrite a good one.
    -- Seated, the body is within a few metres of its hull's origin; a frame far
    -- from where the network has the hull is the engine's own, dragged one.
    if across(at, frame) > M.CABIN_METRES then return previous end
    local net = networkFrame(id, frame)
    if net ~= nil and across(frame, net) > M.DRAG_METRES then return previous end
    frame.at = now
    -- THE PAD (1.6.1): where the hull stood the first time this game simulated
    -- it with the body aboard -- where its chassis stays once a flight here
    -- begins, and where an exit's drag takes the hull and the body back to (see
    -- `padOf`). A drag an exit sees is the better word, and replaces it.
    local key = M.KeyOf(id)
    if padOf[key] == nil then
        local snapshot = hull(id)
        if snapshot ~= nil and snapshot.locallyOwned == true then
            padOf[key] = { x = frame.x, y = frame.y, z = frame.z, at = now,
                how = 'where it stood when first boarded here' }
        end
    end
    return frame
end

--- The height of the static ground under a point, or nil.
local function groundBelow(x, y, fromZ)
    local world = Open77.world
    if type(world) ~= 'table' or type(world.groundZ) ~= 'function' then return nil end
    local read, z = pcall(world.groundZ, x, y, fromZ)
    if not read then return nil end
    return finite(z)
end
-- The boarding step plans on these too (client/enter.lua).
M.NetworkFrame = function(id, engine) return networkFrame(id, engine) end
M.GroundBelow = groundBelow

--- Where the body belongs after the seat is left: beside the seat's door on
--- the ground there, or -- when that place has no ground within reach under it
--- (a hull parked at the edge of a roof) -- the first of the other places that
--- has. When none has ground, the door's own place is used and the body falls
--- from the door's height.
-- @param frame table `{ x, y, z, fx, fy }`
-- @param seat string|nil
-- @param exit table `M.ExitSettings()`
-- @param record string|nil the hull's record: a known airframe's door wins
--   over the seat's side (the Rayfield Excalibur's one door is on the left)
-- @return table|nil `{ x, y, z, attempt, airborne, height, ground }`
local function plan(frame, seat, exit, record)
    local first = nil
    local door = M.SeatDoor(record, seat)
    for attempt = 1, M.EXIT_ATTEMPTS do
        local x, y = M.ExitPoint(frame, { x = frame.fx, y = frame.fy }, seat, exit, attempt, door)
        if x ~= nil then
            local ground = groundBelow(x, y, frame.z + 2.0)
            local z, airborne, height = M.ExitLevel(frame.z, ground, exit)
            local pick = { x = x, y = y, z = z, attempt = attempt, airborne = airborne,
                height = height, ground = ground }
            first = first or pick
            if ground ~= nil and not airborne then return pick end
        end
    end
    return first
end

--- THE HULL ON ITS GEAR (server/land.lua): for an airframe whose gear is known
--- (`AIRFRAMES` ... `LAND`), the static ground under each of its feet, measured
--- from this game and sent to the server, which sets the hull down on its gear
--- once nobody is aboard. Said in the log either way.
-- @param was table the seat as `watchSeat` last read it
-- @param frame table the hull: `{ x, y, z, fx, fy }`
-- @return boolean whether the server was asked
local function measureLand(was, frame, when)
    local exit = M.ExitSettings()
    if exit.off or not exit.land then return false end
    local land = M.AirframeLand(was.record)
    if land == nil then return false end
    local feet = M.GearPoints({ x = frame.x, y = frame.y }, { x = frame.fx, y = frame.fy }, land)
    if feet == nil then return false end
    local grounds, parts = {}, {}
    for index, foot in ipairs(feet) do
        grounds[index] = groundBelow(foot.x, foot.y, frame.z + 1.0)
        parts[index] = grounds[index] ~= nil and ('%.2f'):format(grounds[index]) or 'none'
    end
    local z, why = M.LandHeight(frame.z, grounds, land)
    -- THE MEASURE IS SENT EITHER WAY: the server judges it against its own hull
    -- and says why in its log ("the game of player 2 sent no measure ..." told
    -- nothing about a hull that already stood on its gear, 2026-10-28, 01:11:16).
    TriggerServerEvent(M.Event.LAND, { id = M.KeyOf(was.vehicleId), grounds = grounds, x = frame.x, y = frame.y,
        z = frame.z, why = z == nil and tostring(why):sub(1, 60) or nil })
    if z == nil then
        Open77.log.info(('exit from %s%s: the hull is not to be lowered as this game measures it (%s; its origin at '
            .. '%.2f, the ground under its %d gear feet %s); the measure goes to the server all the same')
            :format(tostring(was.vehicleId), when ~= nil and (' (' .. when .. ')') or '', tostring(why), frame.z, #feet,
            table.concat(parts, ', ')))
        return true
    end
    Open77.log.info(('exit from %s%s: it hovers %.2f m over its gear (origin %.2f, the ground under its %d feet %s): '
        .. 'the server sets it down once nobody is aboard'):format(tostring(was.vehicleId),
        when ~= nil and (' (' .. when .. ')') or '', why.drop, frame.z, #feet, table.concat(parts, ', ')))
    return true
end

--- Ends the guard and says how it went.
-- @param result string
local function endGuard(result)
    local g = guard
    if g == nil then return end
    g.over = true
    guard = nil
    if guardJob ~= nil then
        M.Cancel(guardJob)
        guardJob = nil
    end
    local now = M.Now()
    -- AN EXIT THAT DID NOT END BESIDE THE DOOR has no clip to play: the server
    -- shows the body to the others again.
    if result ~= 'done' and M.WalkOut ~= nil and g.clip ~= nil then M.WalkOut.Abandon('the guard ended: ' .. result) end
    -- A body that boarded again has finished with that exit: its NEXT step out is
    -- a new exit and gets its own fade and its own guard. Every other ending keeps
    -- the seat's leaving flag from starting the same exit over.
    lastExit = result ~= 'boarded again' and { id = g.id, at = now } or nil
    local at = myself()
    Open77.log.info(('exit guard over (%s) after %.1fs: %d placement(s), %d platform move(s), '
        .. 'body %s from the hull, %s from the door')
        :format(result, (now - g.since) / 1000.0, g.placements, g.jumps,
            at ~= nil and ('%.1f m'):format(across(at, g.frame)) or '?',
            at ~= nil and ('%.1f m'):format(across(at, g.target)) or '?'))
end

--- Puts the body on the guard's target through the platform's own move.
-- @param g table the guard
-- @param why string for the log
-- @param now number
-- @return boolean whether the move was queued
local function place(g, why, now)
    local travel = Open77.travel
    if type(travel) ~= 'table' or type(travel.teleport) ~= 'function' then
        if not heard['\1travel'] then
            heard['\1travel'] = true
            Open77.log.warn('no Open77.travel.teleport on this client: the exit cannot '
                .. 'put the body beside the door')
        end
        return false
    end
    -- AN EXIT CLIP NEEDS ITS HEADING: the clip's path turns with the entity,
    -- so the body is put facing the way that lays the path's start on the door.
    local yaw = g.yaw
    local character = Open77.character
    if yaw == nil and type(character) == 'table' and type(character.yaw) == 'function' then
        local read, answer = pcall(character.yaw)
        if read then yaw = finite(answer) end
    end
    -- Facing the way the hull faces when the body's own heading is unreadable:
    -- REDengine's yaw is 0 toward +y and grows toward -x.
    yaw = yaw or (math.deg(math.atan(-g.frame.fx, g.frame.fy)) % 360.0)
    -- A held body is let go before it is moved (client/walkout.lua): moved while
    -- held, it may be left off the ground, where no clip is drawn on it. And
    -- the curtain comes up first: under the native fade the body would hang in
    -- the air where it is put until the image came back.
    if M.WalkOut ~= nil and M.WalkOut.BodyMoved ~= nil then M.WalkOut.BodyMoved(why) end
    if fading ~= nil then M.CurtainUp('a move: ' .. tostring(why), fading.block.lift, false) end
    local read, ok, reason = M.Native('travel.teleport', travel.teleport, g.target.x, g.target.y, g.target.z, yaw)
    if not read or ok ~= true then
        Open77.log.warn(('the exit could not put the body beside the door (%s): %s')
            :format(why, tostring(read and reason or ok)))
        return false
    end
    g.placements = g.placements + 1
    g.placedAt, g.arrived, g.movedAt = now, false, now
    Open77.log.info(('exit: body put beside the %s door at %.1f, %.1f, %.1f facing %.0f (%s, placement %d)')
        :format(tostring(g.seat or 'seat'), g.target.x, g.target.y, g.target.z, yaw, why, g.placements))
    return true
end

--- Whether this game's engine still holds the body in a vehicle: what it says
--- of it (`mounts the body`, `holds it in a workspot`), or nil when it does not.
-- @return string|nil
local function engineHolds()
    local character = Open77.character
    if type(character) ~= 'table' or type(character.state) ~= 'function' then return nil end
    local read, state = pcall(character.state)
    if not read or type(state) ~= 'table' then return nil end
    local mounted = type(state.vehicle) == 'table' and state.vehicle.mounted == true
    if mounted and state.inWorkspot == true then return 'mounts the body, in a workspot' end
    if mounted then return 'mounts the body' end
    if state.inWorkspot == true then return 'holds the body in a workspot' end
    return nil
end

--- One look at the body, every `GUARD_MS` while the guard lasts.
local function guardStep()
    local g = guard
    if g == nil then return end
    local now = M.Now()
    if not alive() then return endGuard('the body is down') end
    local seat = mySeat()
    if seat ~= nil and M.SameHull(seat.vehicleId, g.id) and seat.exiting ~= true then
        -- Aboard again -- through the door it just left, say. Nothing to guard.
        return endGuard('boarded again')
    end
    local at = myself()
    if at == nil then
        if now >= g.endAt + 1000 then endGuard('the body could not be read') end
        return
    end

    -- A PLACEMENT IN FLIGHT: wait for it to land, and make it again when it did
    -- not (or when the platform moved the body again on top of it).
    if not g.arrived then
        if across(at, g.target) <= ARRIVE_METRES then
            g.arrived, g.last, g.movedAt = true, at, now
        elseif now - g.placedAt >= PLACE_WAIT_MS then
            -- THE GAME'S OWN EXIT, ANIMATED, SEEN LATE (1.9.0): a placement that
            -- did not hold while the engine still mounts the body, in a
            -- workspot, on an airframe whose own exit is animated and that the
            -- exit key did not step out of -- the game's exit holds it (the
            -- engine's mount was not read at the exit's first frame). It is
            -- left to the game, as `beginExit` leaves it: no more placements, no
            -- clip, the view let go.
            if g.gameMayAnimate then
                local holds = engineHolds()
                if holds ~= nil then
                    Open77.log.info(('exit from %s: the game\'s own exit, animated, seen late -- the placement did not '
                        .. 'hold and the engine %s, %.1fs after the seat was left: left to the game'):format(
                        tostring(g.id), holds, (now - g.since) / 1000.0))
                    if M.WalkOut ~= nil and M.WalkOut.ReleaseView ~= nil then
                        M.WalkOut.ReleaseView('the game\'s own exit, animated')
                    end
                    return endGuard('the game\'s own exit')
                end
            end
            if g.placements >= MAX_PLACEMENTS then return endGuard('gave up') end
            if not place(g, 'the last placement had not held', now) then return endGuard('refused') end
        end
        return
    end

    -- THE BODY IS WHERE IT WAS PUT: a jump between two looks is the platform's
    -- own eject (or anybody's), and is put back. The ground distance is the
    -- measure, so a body that is falling is not mistaken for one that was moved.
    if across(at, g.last) > g.exit.jump then
        -- FAR FROM THE HULL IS A MOVE MADE ELSEWHERE -- a server teleport, a
        -- respawn -- and not the platform's eject, which lands within a few
        -- metres of the hull: it is left alone, never put back.
        -- Back where the exit's drag left it (1.6.1) is the platform's own drop
        -- on the dragged hull, and is put back too.
        local dragBack = g.drag ~= nil and across(at, g.drag) <= g.exit.near
        if across(at, g.frame) > g.exit.near and not dragBack then
            Open77.log.info(('exit: the body was moved %.1f m from the hull (%.1fs after the seat was left): '
                .. 'a move made elsewhere, left alone'):format(across(at, g.frame), (now - g.since) / 1000.0))
            return endGuard('moved elsewhere')
        end
        g.jumps = g.jumps + 1
        g.movedAt = now
        Open77.log.info(('exit: something moved the body %.1f m in one look (%.1fs after the '
            .. 'seat was left): putting it back'):format(across(at, g.last), (now - g.since) / 1000.0))
        if g.placements >= MAX_PLACEMENTS then return endGuard('gave up') end
        if not place(g, 'the platform moved it', now) then return endGuard('refused') end
        return
    end
    g.last = at

    if now < g.endAt then return end
    -- THE LAST LOOK: a body that is still inside the hull is moved once more.
    if not g.final then
        g.final = true
        if across(at, g.frame) < g.exit.danger and g.placements < MAX_PLACEMENTS then
            if place(g, 'still inside the hull at the end', now) then
                g.endAt = now + PLACE_WAIT_MS + 200
                return
            end
        end
    end
    endGuard('done')
end

--- The job's step: the guard's look, and nothing that raises out of it.
guardTick = function()
    if guard == nil then return end
    local ran, failure = pcall(guardStep)
    if not ran then
        Open77.log.error('the exit guard failed and stops: ' .. tostring(failure))
        endGuard('error')
    end
end

--- Starts the guard for a seat that is being left, or says why not.
-- @param was table the seat as `watchSeat` last read it
-- @return string `guarded`, `far` (a move the server made: leave it alone),
--   `off` (no guard by configuration) or `unknown` (the hull could not be read)
local function beginGuard(was, opts)
    if guard ~= nil then return 'guarded' end
    local exit = M.ExitSettings()
    if exit.off or not exit.place then return 'off' end
    local at = myself()
    local engine = hullFrame(was.vehicleId)
    -- THE ENGINE'S FRAME IS NOT WHERE THE HULL FLEW when the exit un-masked a hull
    -- that was flown off its pad (see `keepFlown`): for a fifth of a second the
    -- engine drags it back to where the flight began -- 37 m on XyberRP
    -- (2026-09-30), 7.2 m on Staging (2026-10-28, the exit then planned beside a
    -- door that was not there: "walking on air"), 2.5 m after a hop from the
    -- back seat (01:10:52: "floating in air ... while the av doors where open").
    -- Where the NETWORK has the hull (the snapshot: the motion its game sent,
    -- which the server holds and every other game draws) is the reference: the
    -- engine's frame only within `AGREE_METRES` of it, else the network's own.
    -- The walk-out is planned again on the hull as it stands before the clip is
    -- asked (client/walkout.lua), and the server checks it once more.
    local flown = was.flown
    local net = networkFrame(was.vehicleId, engine)
    -- THE EXIT'S DRAG (1.6.1): the hull this game drew at the exit's first look,
    -- or draws now, far from where it stands -- the frame it flew at (kept while
    -- the body was aboard, fresh), else the network's -- is the engine's drag back
    -- to the pad, which carries the body along. The network's frame may carry it
    -- too (this game's own dragged sample, as the hull's simulator: Staging,
    -- 2026-10-28, 13:21:39, both on the pad): then the hull is where it flew.
    local key = M.KeyOf(was.vehicleId)
    local first = (exitFirst ~= nil and M.SameHull(exitFirst.id, was.vehicleId)) and exitFirst or nil
    exitFirst = nil
    local now0 = M.Now()
    -- The frame it flew at stands for the hull only while it was still (a hull
    -- moving at the exit has left that frame behind).
    local snapshot = hull(was.vehicleId)
    local still = snapshot == nil or (finite(snapshot.speed) or 0.0) <= 3.0
    local flownFresh = still and flown ~= nil and flown.at ~= nil and now0 - flown.at <= M.FLOWN_FRESH_MS
    local dragged, real, realSource = nil, nil, nil
    local looks = { first ~= nil and first.engine or nil, engine }
    for i = 1, 2 do
        local look = looks[i]
        if dragged == nil and look ~= nil then
            if net ~= nil and across(look, net) > M.DRAG_METRES then
                dragged, real, realSource = look, net, 'network'
            elseif flownFresh and across(look, flown) > M.DRAG_METRES then
                dragged, real, realSource = look, flown, 'flown'
            end
        end
    end
    local frame, source = M.ExitFrame(engine, flown, net, at, exit)
    if dragged ~= nil and frame ~= nil and across(frame, real) > M.DRAG_METRES then
        frame, source = real, realSource
    end
    real = real or net or flown
    -- Which hull the frame is, for the door slot's verdict (client/walkout.lua):
    -- a slot is read off the hull the engine draws.
    if frame ~= nil then frame.source = source end
    local function apart(a) return (a ~= nil and frame ~= nil) and ('%.1f m'):format(across(a, frame)) or 'none' end
    if source ~= 'engine' then
        local turn = M.FrameTurn(engine, net)
        Open77.log.info(('exit from %s: the engine reads the hull at %s, %s from where the network has it%s; '
            .. 'the frame kept aboard %s from it; using %s, %s from the body')
            :format(tostring(was.vehicleId),
                engine ~= nil and ('%.1f, %.1f'):format(engine.x, engine.y) or 'nowhere',
                (engine ~= nil and net ~= nil) and ('%.1f m'):format(across(engine, net)) or 'unknown',
                turn ~= nil and (', turned %.0f deg from it'):format(turn) or '',
                (flown ~= nil and net ~= nil) and ('%.1f m'):format(across(flown, net)) or 'unknown',
                source == 'flown' and 'the frame it flew at' or (source == 'network' and 'the network\'s'
                    or tostring(source)),
                at ~= nil and apart(at) or '?'))
    else
        Open77.log.info(('exit from %s: the hull at %.1f, %.1f, %.1f (the engine\'s frame, %s from where the network '
            .. 'has it)'):format(tostring(was.vehicleId), frame.x, frame.y, frame.z,
            net ~= nil and ('%.1f m'):format(across(frame, net)) or 'no network position'))
    end
    -- A BODY FAR FROM THE HULL WAS MOVED, even when the hull is no longer drawn
    -- here to measure against (a server teleport out of streaming range): the
    -- frame it flew at says where the hull was.
    if at ~= nil and frame == nil and flown ~= nil and across(at, flown) > exit.near then
        Open77.log.info(('left %s %.1f m from where it flew: a move made elsewhere, not an exit; '
            .. 'nothing is placed'):format(tostring(was.vehicleId), across(at, flown)))
        return 'far'
    end
    if at == nil or frame == nil then
        Open77.log.info(('exit from %s: the hull or the body could not be read, so the body '
            .. 'is not placed'):format(tostring(was.vehicleId)))
        return 'unknown'
    end
    -- The drag, learnt as this hull's pad, told to the server (the exiting game
    -- may have sent the dragged pose as the hull's own: server/watch.lua), and
    -- kept for `DRAG_HOLD_MS`, so a network frame that carries it is not planned on.
    if dragged ~= nil then
        padOf[key] = { x = dragged.x, y = dragged.y, z = dragged.z, at = now0, how = 'an exit\'s drag' }
        dragSeen = { key = key, engine = dragged, real = real, at = now0 }
    end
    local pad = padOf[key]
    -- A BODY FAR FROM THE HULL WHERE IT STANDS was moved elsewhere -- unless it
    -- is beside the hull this game drew at the exit, or at its pad: the drag
    -- took it there.
    local far = across(at, frame)
    local withDrag = nil
    if far > exit.near then
        local bodies = { at, first ~= nil and first.body or nil }
        local places = {
            { frame = dragged, reach = exit.near, why = 'carried along by the engine\'s drag of the hull back toward '
                .. 'where its flight began, and left there' },
            { frame = first ~= nil and first.engine or nil, reach = exit.near, why = 'beside the hull this game drew at '
                .. 'the exit' },
            { frame = engine, reach = exit.near, why = 'beside the hull this game draws' },
            { frame = (pad ~= nil and real ~= nil and across(pad, real) > M.DRAG_METRES) and pad or nil,
                reach = M.PAD_REACH_METRES, why = ('at the pad this game\'s engine keeps for the hull (%s): the exit\'s '
                    .. 'drag, gone by between two frames'):format(pad ~= nil and pad.how or '?') },
        }
        for _, place in ipairs(places) do
            if withDrag == nil and place.frame ~= nil then
                for i = 1, 2 do
                    local b = bodies[i]
                    if withDrag == nil and b ~= nil and across(b, place.frame) <= place.reach then
                        withDrag = { why = place.why, off = across(b, place.frame), place = place.frame }
                    end
                end
            end
        end
        if withDrag == nil then
            Open77.log.info(('left %s %.1f m from it: a move made elsewhere, not an exit; nothing is placed (the hull '
                .. 'this game drew at the exit %s from the body, the pad it keeps for it %s)'):format(
                tostring(was.vehicleId), far,
                (first ~= nil and first.engine ~= nil and first.body ~= nil)
                    and ('%.1f m'):format(across(first.body, first.engine)) or 'not read',
                (pad ~= nil) and ('%.1f m'):format(across(at, pad)) or 'not known'))
            return 'far'
        end
        Open77.log.info(('exit from %s: the body is %.1f m from the hull where it stands (%.1f, %.1f) -- %s, %.1f m '
            .. 'from it: an exit all the same, and the body is put beside the hull where it stands')
            :format(tostring(was.vehicleId), far, frame.x, frame.y, withDrag.why, withDrag.off))
    end
    -- THE DRAG TOLD TO THE SERVER: the engine's dragged frame (or the pad the
    -- body was left at) and where the hull stands.
    local told = dragged or (withDrag ~= nil and withDrag.place) or nil
    if told ~= nil and real ~= nil then
        TriggerServerEvent(M.Event.DRAG, { id = key,
            engine = { x = told.x, y = told.y, z = told.z }, real = { x = real.x, y = real.y, z = real.z },
            body = at ~= nil and { x = at.x, y = at.y, z = at.z } or nil,
            how = dragged ~= nil and 'seen at the exit' or 'the pad kept here' })
        Open77.log.info(('exit from %s: the engine\'s drag of the hull told to the server -- drawn at %.1f, %.1f, %.1f '
            .. 'm from where it stands (%.1f, %.1f), the body %s'):format(tostring(was.vehicleId), told.x, told.y,
            across(told, real), real.x, real.y, at ~= nil and ('%.1f m from it'):format(across(at, told)) or 'not read'))
        if dragSeen == nil or dragSeen.key ~= key or now0 - dragSeen.at > 100 then
            dragSeen = { key = key, engine = told, real = real, at = now0 }
        end
    end
    if not alive() then return 'unknown' end
    -- The hull on its gear (the server sets it down once nobody is aboard),
    -- measured here before the step is planned.
    local landed, landFailure = pcall(measureLand, was, frame)
    if not landed then Open77.log.error('measuring the ground under the hull failed: ' .. tostring(landFailure)) end
    M.Breathe()
    -- Boarded again, or the guard begun elsewhere, while this breathed.
    if guard ~= nil then return 'guarded' end
    -- THE EXIT CLIP, when there is one (client/walkout.lua): the body goes where
    -- the clip ends, facing the way that puts its first frame on the door.
    local walked = M.WalkOut ~= nil and M.WalkOut.Plan(was, frame, exit, groundBelow) or nil
    local target = walked ~= nil and walked.target or plan(frame, was.seat, exit, was.record)
    if target == nil then return 'unknown' end
    local now = M.Now()
    guard = {
        id = was.vehicleId, seat = was.seat, since = now, endAt = now + exit.guard,
        frame = frame, target = target, exit = exit, yaw = walked ~= nil and walked.yaw or nil,
        clip = walked ~= nil and walked.clip or nil,
        placements = 0, jumps = 0, arrived = false, movedAt = now, final = false,
        -- Where the exit's drag took the hull (and the body), if it did.
        drag = told,
        -- An exit the game may be animating itself (1.9.0): an airframe whose
        -- own exit is animated, and not stepped out of through the exit key.
        gameMayAnimate = M.ExitForced(was.record) and not (type(opts) == 'table' and opts.asked == true),
    }
    local door = M.SeatDoor(was.record, was.seat)
    Open77.log.info(('exit from %s (%s, %s): body %.1f m from the hull, door place %.1f, %.1f, %.1f '
        .. '(%s, ground %s, hull %s over it, %s)')
        :format(tostring(was.vehicleId), tostring(was.seat), door.airframe ~= nil
                and ('%s, its %s door'):format(door.airframe, door.side > 0 and 'left' or 'right')
                or (door.side > 0 and 'left door' or 'right door'),
            far, target.x, target.y, target.z,
            target.attempt == 1 and 'the door\'s own side'
                or ('side ' .. target.attempt .. ' of ' .. M.EXIT_ATTEMPTS),
            target.ground ~= nil and ('%.1f'):format(target.ground) or 'unknown',
            target.height ~= nil and ('%.1f m'):format(target.height) or 'unknown',
            walked ~= nil and ('exit clip ' .. walked.clip) or 'no exit clip'))
    if not place(guard, 'the seat was left', now) then
        endGuard('refused')
        return 'unknown'
    end
    guardJob = M.Every('guard', GUARD_MS, guardTick)
    return 'guarded'
end

-- ── what the exit clip asks of the guard (client/walkout.lua) ───────────────

--- The hull an exit is about, read again now: the engine's frame when it
--- agrees with where the network has the hull, else the network's.
-- @param id any the hull
-- @return table|nil frame
-- @return string|nil 'engine' | 'network'
-- @return table|nil the engine's frame
-- @return table|nil the network's frame
function M.ExitFrameNow(id)
    local engine = hullFrame(id)
    local net = networkFrame(id, engine)
    -- THE NETWORK CARRYING THE EXIT'S DRAG (1.6.1): the exiting game sent the
    -- dragged pose as the hull's own and the server took it for a moment
    -- (Staging, 2026-10-28, 18:20:46) -- it puts the hull back where it stood
    -- (server/watch.lua). For `DRAG_HOLD_MS` after the exit a network frame on
    -- the drag is not the hull: planned where it stood (the engine's own frame
    -- when it is there again, re-masked), and said once.
    local drag = dragSeen
    if drag ~= nil and drag.key == M.KeyOf(id) and net ~= nil and M.Now() - drag.at <= M.DRAG_HOLD_MS
        and across(net, drag.engine) <= M.DRAG_MATCH_METRES and across(net, drag.real) > M.DRAG_METRES then
        local stood = (engine ~= nil and across(engine, drag.real) <= M.AGREE_METRES) and engine or drag.real
        if not drag.said then
            drag.said = true
            Open77.log.info(('exit from %s: the network has the hull where this game\'s engine dragged it at the exit '
                .. '(%.1f, %.1f, %.1f m from where it stood) -- this game\'s own dragged sample, or the server took it; '
                .. 'the step is planned where the hull stood (%s)'):format(tostring(id), net.x, net.y,
                across(net, drag.real),
                stood == engine and 'the engine draws it there again' or 'as the exit read it'))
        end
        return stood, 'exit', engine, net
    end
    local frame, source = M.ExitFrame(engine, nil, net, myself(), M.ExitSettings())
    return frame, source, engine, net
end

--- The static ground under a point, for the walk-out's plan.
M.ExitGround = function(x, y, fromZ) return groundBelow(x, y, fromZ) end

--- The ground under the gear measured again and sent (the hull still hangs
--- over it when the clip is to be asked).
-- @param was table `{ vehicleId, seat, record }`
-- @param frame table the hull
-- @return boolean
function M.ExitMeasure(was, frame)
    local ran, sent = pcall(measureLand, was, frame, 'measured again before the clip')
    if not ran then
        Open77.log.error('measuring the ground under the hull again failed: ' .. tostring(sent))
        return false
    end
    return sent == true
end

--- The body moved to the exit clip's new end point -- through the guard while
--- it lasts, so a move of its own is not "put back" to the old one.
-- @param target table `{ x, y, z, ground, ... }`
-- @param yaw number the heading that puts the clip's first frame on the door
-- @param why string for the log
-- @param frame table|nil the hull the new plan was made on
-- @return boolean whether the move was made
function M.ExitRetarget(target, yaw, why, frame)
    local now = M.Now()
    if guard ~= nil and not guard.over then
        guard.target, guard.yaw = target, yaw
        if frame ~= nil then guard.frame = frame end
        guard.endAt = math.max(guard.endAt, now + PLACE_WAIT_MS * 4)
        return place(guard, why, now)
    end
    local travel = Open77.travel
    if type(travel) ~= 'table' or type(travel.teleport) ~= 'function' then return false end
    -- Never under the curtain: the body would hang where it is put.
    if fading ~= nil then M.CurtainUp('a move: ' .. tostring(why), fading.block.lift, false) end
    local read, ok, reason = M.Native('travel.teleport', travel.teleport, target.x, target.y, target.z, yaw)
    if not read or ok ~= true then
        Open77.log.warn(('the exit clip could not move the body to its new end point (%s): %s')
            :format(why, tostring(read and reason or ok)))
        return false
    end
    Open77.log.info(('exit: body put at %.1f, %.1f, %.1f facing %.0f for the exit clip (%s)')
        :format(target.x, target.y, target.z, yaw, why))
    return true
end

--- A seat in an aircraft is being left: the screen and the body.
-- @param was table the seat as `watchSeat` last read it
-- @param by string|nil what saw it: 'frame' (the per-frame read) or the watch
local function beginExit(was, by)
    -- The exit in progress, or one that began a moment ago and whose seat the
    -- platform has not yet stopped calling occupied.
    if guard ~= nil then return end
    local now = M.Now()
    if lastExit ~= nil and M.SameHull(lastExit.id, was.vehicleId) and now - lastExit.at < EXIT_HOLD_MS then
        return
    end
    lastExit = { id = was.vehicleId, at = now }
    -- A new exit: the curtain may come down again (`EXIT_FADE.TRIES`).
    curtainCount = { tries = 0, at = now }
    -- NO CUT TO BLACK AT THE EXIT (1.6.0). The native fade holds the body still
    -- wherever it is: a body put beside the door under it hung 3 cm over the
    -- ground, "falling", for the whole fade, where no screen draws the clip, and
    -- fell as the image came back (Staging, 2026-10-28, 10:32:56; `EXIT_FADE`).
    -- The image stays on: the client hides the pilot's body for 1.6 s and its
    -- chase camera holds the AV in view for 1.5 s, while the body is put beside
    -- the door and lands; the exit clip brings the curtain down once it stands
    -- there (client/walkout.lua). A body already far from the hull -- a server's
    -- move, a respawn -- is not an exit: far from the frame the hull flew at,
    -- from where the network has it, from the hull this game draws now (the
    -- exit's drag carries the body along with it, 1.6.1) and from the pad this
    -- game's engine keeps for it (the drag, gone by unseen).
    -- THE EXIT'S FIRST LOOK, before anything breathes: the hull this game draws
    -- now -- dragged, or not yet -- and the body (`exitFirst`, for the guard).
    local exitCfg = M.ExitSettings()
    local body = myself()
    local engineNow = hullFrame(was.vehicleId)
    exitFirst = { id = was.vehicleId, engine = engineNow, body = body, at = now }
    local refs = { was.flown, networkFrame(was.vehicleId, nil), engineNow, padOf[M.KeyOf(was.vehicleId)] }
    local seen, close = 0, false
    for i = 1, 4 do
        local ref = refs[i]
        if ref ~= nil then
            seen = seen + 1
            local reach = i == 4 and M.PAD_REACH_METRES or exitCfg.near
            if body == nil or across(body, ref) <= reach then close = true end
        end
    end
    local farAway = body ~= nil and seen > 0 and not close
    -- WHAT THE SCREEN SHOWS (client/shots.lua): a set of pictures for this exit,
    -- the first a frame after the exit is seen.
    if M.Shots ~= nil and not farAway then
        M.Shots.Begin('own', ('exit from %s of %s'):format(tostring(was.seat), tostring(was.vehicleId)))
        M.Shots.Take('exit', 60, M.WalkOut ~= nil and M.WalkOut.ShotMeta or nil)
    end
    local state = nil
    if type(Open77.character) == 'table' and type(Open77.character.state) == 'function' then
        local read, answer = pcall(Open77.character.state)
        if read and type(answer) == 'table' then state = answer end
    end
    local mounted = state ~= nil and type(state.vehicle) == 'table' and state.vehicle.mounted or nil
    Open77.log.info(('exit from %s (%s) seen %s; the engine %s; %s, the body %s'):format(tostring(was.vehicleId),
        tostring(was.seat),
        by == 'frame' and ('at its first frame (the seat read every frame%s)'):format(sentinel ~= nil
            and (', %d look(s) aboard, %.3f ms each'):format(sentinel.looks,
                sentinel.looks > 0 and sentinel.cost / sentinel.looks or 0) or '')
            or 'at the watch\'s look (a tenth of a second)',
        mounted == true and 'still mounts the body' or (mounted == false and 'has let go of the body'
            or 'mount was not read'), M.ScreenText(),
        state == nil and 'not read' or (state.grounded == true and 'on the ground'
            or (state.grounded == false and ('off the ground (%s)'):format(tostring(state.air or '?'))
                or 'ground not said'))))
    -- THE GAME'S OWN EXIT, ANIMATED (1.9.0). From an airframe whose seats the
    -- game steps out of with an animation (`EXIT_FORCED`: the Manticore's, a
    -- car's exit, the body held mounted in the exit's workspot for two
    -- seconds), the exit key steps the body out through the server's forced
    -- exit, instant on this game (client/leave.lua). An exit from such a seat
    -- that the key did not ask for, with the engine still mounting the body, is
    -- the game's own: placing the body beside the door then fights its
    -- workspot -- eight placements in 1.5 s, none held, and the clip given up
    -- (Staging, 2026-10-30, 22:46:23) -- so it is left to the game: nothing is
    -- placed, no clip is planned, the view is not held, and the server shows
    -- the body to the others at once.
    local asked, askedMs = false, nil
    if M.Leave ~= nil then
        asked, askedMs = M.Leave.Asked(was.vehicleId)
        M.Leave.Exited(was.vehicleId)
    end
    local animatedByGame = M.ExitForced(was.record) and mounted == true and not asked
    if asked then
        Open77.log.info(('exit from %s: asked through the exit key %.2fs before (the platform\'s forced exit)')
            :format(tostring(was.vehicleId), (askedMs or 0) / 1000.0))
    end
    -- THE REST ON THE NEXT FRAMES (1.5.1): the frames, the ground, the plan and
    -- the move are each a resume of their own (the host's budget,
    -- shared/core.lua `M.Breathe`).
    M.Breathe()
    local verdict
    if animatedByGame then
        verdict = 'vanilla'
        Open77.log.info(('exit from %s (%s): the game\'s own exit, animated -- not asked through the exit key and the '
            .. 'engine still mounts the body (%s): nothing is placed, no clip, the view the game\'s own')
            :format(tostring(was.vehicleId), tostring(was.seat), tostring(was.record)))
    else
        verdict = beginGuard(was, { asked = asked })
    end
    -- The view that keeps the head on the body, and the server's word about
    -- the clip (client/walkout.lua).
    if M.WalkOut ~= nil then
        local ran, failure = pcall(M.WalkOut.OnExit, was, verdict)
        if not ran then Open77.log.error('the exit clip failed at the exit: ' .. tostring(failure)) end
    end
    -- A body that was left far from its hull was MOVED, not exited: nothing of
    -- the exit's is on the screen.
    if verdict == 'far' then endFade(true) end
end

--- The per-frame look at the seat while the body sits in an aircraft (see
--- `sentinel`): ends with the seat, or at the exit it sees.
local function sentinelStart()
    if sentinel ~= nil then return end
    local handle = { live = true, looks = 0, cost = 0.0, since = M.Now() }
    sentinel = handle
    local clock = M.Sync ~= nil and M.Sync.Clock or nil
    CreateThread(function()
        while handle.live do
            Wait(SENTINEL_MS)
            if not handle.live or lastSeat == nil or lastSeat.aircraft ~= true then break end
            handle.looks = handle.looks + 1
            local ran, gone = pcall(function()
                local began = clock ~= nil and clock() or nil
                local seat = mySeat()
                if began ~= nil then handle.cost = handle.cost + (clock() - began) end
                local leaving = seat == nil or seat.exiting == true or not M.SameHull(seat.vehicleId, lastSeat.vehicleId)
                if leaving then beginExit(lastSeat, 'frame') end
                return leaving
            end)
            if not ran then
                if not heard['\1sentinel'] then
                    heard['\1sentinel'] = true
                    Open77.log.error('the per-frame exit look failed and stops: ' .. tostring(gone))
                end
                break
            end
            if gone then break end
        end
        if sentinel == handle then sentinel = nil end
    end)
end

--- The seat watch: an exit from an aircraft starts the fade and the guard;
--- standing outside (or the ceiling) ends the fade.
-- @param seat table|nil this pass's seat read
local function watchSeat(seat)
    if lastSeat ~= nil and lastSeat.aircraft == true then
        local leaving = seat == nil or seat.exiting == true
            or not M.SameHull(seat.vehicleId, lastSeat.vehicleId)
        if leaving then beginExit(lastSeat, 'look') end
    end
    if seat ~= nil then
        -- Aboard and not leaving: the next exit is a new exit.
        if seat.exiting ~= true then lastExit = nil end
        local known = lastSeat ~= nil and M.SameHull(lastSeat.vehicleId, seat.vehicleId)
        local kind = kindOf(seat.vehicleId)
        local aircraft = (known and lastSeat.aircraft == true) or (kind ~= nil and kind.aircraft == true)
        -- The frame the hull flies at is kept while the body is aboard. A frame the
        -- engine has already spoiled is never kept: `keepFlown` takes only one the
        -- body is still inside.
        local flown = known and lastSeat.flown or nil
        if aircraft then flown = keepFlown(seat.vehicleId, flown) end
        lastSeat = {
            vehicleId = seat.vehicleId,
            aircraft = aircraft,
            seat = M.SeatName(seat.seat) or (known and lastSeat.seat or nil),
            record = (kind ~= nil and kind.record) or (known and lastSeat.record or nil),
            flown = flown,
        }
        -- Aboard an aircraft and not leaving it: its exit is looked for every frame.
        if aircraft and seat.exiting ~= true and not M.ExitSettings().off then sentinelStart() end
    else
        lastSeat = nil
    end
    -- THE EXIT KEY (1.9.0, client/leave.lua): this resource's while the body
    -- sits, not leaving, in an airframe whose exit the game animates.
    if M.Leave ~= nil then
        local ran, failure = pcall(M.Leave.Tick, (seat ~= nil and seat.exiting ~= true and lastSeat ~= nil
            and lastSeat.aircraft == true) and lastSeat or nil)
        if not ran and not heard['\1leave'] then
            heard['\1leave'] = true
            Open77.log.error('the exit key\'s look failed: ' .. tostring(failure))
        end
    end
    endFade(false)
    if M.WalkOut ~= nil then M.WalkOut.Tick(seat) end
    -- The boarding step's look (client/enter.lua).
    if M.Enter ~= nil then M.Enter.Tick(seat) end
end

-- ── the voice ─────────────────────────────────────────────────────────────────

local function soundSettings()
    local block = settings().SOUNDS
    return type(block) == 'table' and block or nil
end

--- Sends one moment of the flight to the server.
local function say(id, which)
    TriggerServerEvent(M.Event.SOUND, { id = M.KeyOf(id), which = which })
    Open77.log.info(('flight of %s: %s'):format(M.KeyOf(id), which))
end

--- Reads the flight of the AV this client is flying -- a MaxTac AV for its
--- sounds, any AV that makes a landing call for the call -- and names the
--- moments: take-off, descent, touchdown, and a descent called off.
-- @param seat table|nil this pass's seat read
local function readFlight(seat)
    if seat == nil then flight = nil return end
    local kind = kindOf(seat.vehicleId)
    if kind == nil or (kind.voiced ~= true and kind.callout == nil) then flight = nil return end
    -- The thresholds are the SOUNDS block's, and their defaults when it is off:
    -- a Trauma Team AV's landing call reads the same ground as a MaxTac horn.
    local block = soundSettings() or {}
    -- Only the client simulating the hull reads its flight: the other seats
    -- would each report the same landing.
    local snapshot = hull(seat.vehicleId)
    if snapshot == nil or snapshot.locallyOwned == false then flight = nil return end
    local at = myself()
    if at == nil then return end

    local ground = groundBelow(at.x, at.y, at.z + 1.0)
    local height = ground ~= nil and (at.z - ground) or nil
    local now = M.Now()
    local band = M.Number(block.GROUND_METRES, 0.5, 30.0, 7.0)
    local still = M.Number(block.REST_CLIMB, 0.05, 10.0, 0.5)
    local settle = M.Number(block.SETTLE_MS, 0, 10000, 750)

    if flight == nil or not M.SameHull(flight.id, seat.vehicleId) then
        -- A fresh seat: the state is what the hull is doing NOW, and nothing is
        -- said for it -- boarding a hull on the ground is not a landing.
        flight = { id = seat.vehicleId, z = at.z, at = now, height = height,
            state = (height ~= nil and height <= band) and 'ground' or 'air',
            descending = false, calling = false, stillSince = nil }
        return
    end

    local dt = (now - flight.at) / 1000.0
    if dt <= 0 then return end
    local climb = (at.z - flight.z) / dt
    flight.z, flight.at, flight.height = at.z, now, height

    if math.abs(climb) <= still then
        flight.stillSince = flight.stillSince or now
    else
        flight.stillSince = nil
    end
    local low = height ~= nil and height <= band
    local settled = low and flight.stillSince ~= nil and now - flight.stillSince >= settle

    if flight.state == 'ground' then
        if climb >= M.Number(block.CLIMB_SPEED, 0.0, 50.0, 0.8) then
            flight.state = 'air'
            flight.descending = false
            say(flight.id, 'takeoff')
        end
        return
    end

    -- `calling` is the landing call's own flag: set by the descent and kept
    -- through a bob that clears `descending`, so a hull that eases the last
    -- metres down slower than DESCENT_SPEED still ends its call on the ground.
    if settled then
        flight.state = 'ground'
        if flight.descending or flight.calling then say(flight.id, 'touchdown') end
        flight.descending, flight.calling = false, false
        return
    end

    local ceiling = M.Number(block.DESCENT_METRES, 1.0, 500.0, 30.0)
    local approach = height ~= nil and height <= ceiling
    if approach and climb <= -M.Number(block.DESCENT_SPEED, 0.1, 50.0, 1.5) then
        if not flight.descending then
            flight.descending = true
            flight.calling = true
            say(flight.id, 'descent')
        end
    elseif climb > still then
        flight.descending = false
        -- CLIMBED BACK OUT OF THE BAND: the landing was called off, and its call
        -- with it. A bob inside the band is not that -- the hull is still coming
        -- down, and the call goes on.
        if flight.calling and height ~= nil and height > ceiling then
            flight.calling = false
            say(flight.id, 'abort')
        end
    end
end

--- Plays one of the airframe's sounds on it, here.
--
-- THE ANSWER IS WHAT THE SERVER LEARNS FROM: `streamed` says whether this client
-- has the hull at all (a hull that is not streamed here is one the platform's
-- own fan-out would drop just the same, so the server does not rescue it),
-- and `reason` says what the host said when it refused.
-- @param payload table `{ id, event, which, duration, token }`
-- @return table `{ ok, how, streamed, reason }`
local function play(payload)
    if type(payload) ~= 'table' or type(payload.event) ~= 'string' or payload.event == '' then
        return { ok = false, streamed = true, reason = 'malformed sound' }
    end
    local sfx = Open77.sfx
    if type(sfx) ~= 'table' or type(sfx.play) ~= 'function' then
        if not heard['\1sfx'] then
            heard['\1sfx'] = true
            Open77.log.warn('no Open77.sfx.play on this client: the MaxTac AV plays silent here')
        end
        return { ok = false, streamed = true, reason = 'no Open77.sfx.play' }
    end
    local duration = M.Number(payload.duration, 0.05, 60.0, 8.0)
    local snapshot = hull(payload.id)
    local entity = snapshot ~= nil and snapshot.entity or nil
    local read, handle, why = false, nil, 'not streamed here'
    if entity ~= nil then
        -- THE BASE GAME'S OWN EMITTER: every one of these events is played on the
        -- airframe's `vehicle_general_emitter` in the 2.31 scripts, so that is
        -- asked for first, and the entity's default emitter only if the host
        -- refuses it.
        read, handle, why = pcall(sfx.play, payload.event,
            { entity = entity, emitter = 'vehicle_general_emitter', duration = duration })
        if not read or handle == nil then
            read, handle, why = pcall(sfx.play, payload.event, { entity = entity, duration = duration })
        end
    end
    local how = 'on the airframe'
    if not read or handle == nil then
        -- A body aboard the hull is where the hull is: its own body is the
        -- emitter of last resort (`entity` omitted is the local player). A
        -- listener outside is not given a sound at their own feet instead.
        local seat = mySeat()
        if seat ~= nil and M.SameHull(seat.vehicleId, payload.id) then
            read, handle, why = pcall(sfx.play, payload.event, { duration = duration })
            how = 'on the crew'
        end
    end
    local played = read and handle ~= nil
    if not heard[payload.event] then
        heard[payload.event] = true
        Open77.log.info(('%s on %s: %s'):format(payload.event, tostring(payload.id),
            played and ('playing ' .. how) or ('refused: ' .. tostring(read and why or handle))))
    end
    if played then return { ok = true, how = how, streamed = true } end
    return { ok = false, streamed = entity ~= nil or how == 'on the crew',
        reason = tostring(read and why or handle) }
end

--- Says what became of a sound, to the server that sent it.
-- @param payload table the `PLAY` payload
-- @param answer table `play`'s answer
local function acknowledge(payload, answer)
    if type(payload) ~= 'table' or payload.token == nil then return end
    TriggerServerEvent(M.Event.PLAYED, {
        token = payload.token,
        ok = answer.ok == true,
        how = answer.how,
        streamed = answer.streamed ~= false,
        reason = answer.reason,
    })
end

-- ── the watch ─────────────────────────────────────────────────────────────────
--
-- WHERE THIS SCREEN DRAWS AN AIRCRAFT, AGAINST WHERE THE SERVER'S LAST SAMPLE
-- PUT IT. An AV "driving away ... going through buildings" on the other
-- player's screen and back "to the same spot" when the pilot moved is a picture
-- only the OTHER screen has. Every look, for the nearest aircraft this client
-- does not simulate itself, the engine's own frame for the hull
-- (`world.entityGeometry`, what is drawn) is measured against the snapshot's
-- position (the newest sample this client holds). Farther apart than
-- `M.DriftLimit` opens an episode: a line here and a report to the server,
-- which writes its own reads beside it. The report is evidence, never a
-- command.

--- A point `{ x, y, z }` from a table with x/y/z or [1]/[2]/[3], or nil.
local function pointFrom(value)
    if type(value) ~= 'table' then return nil end
    local x, y, z = finite(value.x or value[1]), finite(value.y or value[2]), finite(value.z or value[3])
    if x == nil or y == nil or z == nil then return nil end
    return { x = x, y = y, z = z }
end

local function apart3(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function tenth(value)
    local number = finite(value)
    if number == nil then return nil end
    return math.floor(number * 10.0 + 0.5) / 10.0
end

local function rounded(point)
    if point == nil then return nil end
    return { x = tenth(point.x), y = tenth(point.y), z = tenth(point.z) }
end

-- THE FALLBACK WALK, SLICED. Without `vehicles.nearby` the only read is
-- `vehicles.all`, every vehicle in the world, and a kind lookup and a snapshot
-- per entry. Done inside the watch job that is one resume per pass over a list
-- with no bound. So the walk runs on a thread of its own, yielding every
-- WALK_SLICE entries, and leaves the ids of the aircraft it found;
-- `aircraftNear` re-reads only those, fresh, each pass.
local WALK_SLICE = 16
local walkIds, walking = {}, false

--- Starts one sliced walk over `vehicles.all`, unless one is running.
-- @param api table `Open77.vehicles`
-- @param cap integer the most aircraft worth keeping
local function walkAll(api, cap)
    if walking then return end
    walking = true
    CreateThread(function()
        local ids = {}
        local read, entries = pcall(api.all)
        if read and type(entries) == 'table' then
            for index, entry in ipairs(entries) do
                if #ids >= cap then break end
                local id = type(entry) == 'table' and (entry.id or entry.vehicleId) or nil
                if id ~= nil then
                    local kind = kindOf(id)
                    if kind ~= nil and kind.aircraft == true then ids[#ids + 1] = id end
                end
                if index % WALK_SLICE == 0 then Wait(0) end
            end
        end
        walkIds, walking = ids, false
    end)
end

--- The aircraft near this body, nearest first: `{ id, snapshot }`.
-- @param watchCfg table `M.WatchSettings()`
-- @return table[]
local function aircraftNear(watchCfg)
    local api = vehiclesApi()
    if api == nil then return {} end
    local entries = nil
    if type(api.nearby) == 'function' then
        local read, answer = pcall(api.nearby, watchCfg.range)
        if read and type(answer) == 'table' then entries = answer end
        -- `nil, reason` is the call working: nothing in range, or no body yet.
        if read and answer == nil then return {} end
    end
    local me = nil
    if entries == nil then
        if type(api.all) ~= 'function' then return {} end
        me = myself()
        if me == nil then return {} end
        -- The last sliced walk's aircraft, re-read below; the next walk starts
        -- now and is ready for a later pass.
        entries = {}
        for index, id in ipairs(walkIds) do entries[index] = { id = id } end
        walkAll(api, math.max(64, watchCfg.hulls * 16))
    end
    local found = {}
    for _, entry in ipairs(entries) do
        if #found >= watchCfg.hulls * 4 then break end
        local id = type(entry) == 'table' and (entry.id or entry.vehicleId) or nil
        if id ~= nil then
            local kind = kindOf(id)
            if kind ~= nil and kind.aircraft == true then
                local snapshot = hull(id)
                if snapshot ~= nil then
                    local distance = finite(entry.distance)
                    if me ~= nil then
                        local at = pointFrom(snapshot.position)
                        distance = at ~= nil and apart3(me, at) or nil
                    end
                    if distance == nil or distance <= watchCfg.range then
                        found[#found + 1] = { id = id, snapshot = snapshot, distance = distance or 0.0 }
                    end
                end
            end
        end
    end
    table.sort(found, function(a, b) return a.distance < b.distance end)
    return found
end

--- Owes the server one report; the most telling kind first.
local function owe(report)
    local rank = { open = 1, closed = 2, still = 3 }
    for index, queued in ipairs(sightQueue) do
        if queued.id == report.id then
            -- One report per hull in the queue: the newer word replaces the older,
            -- unless the older opened an episode the server has not heard of yet.
            if not (queued.state == 'open' and report.state == 'still') then sightQueue[index] = report end
            return
        end
    end
    sightQueue[#sightQueue + 1] = report
    table.sort(sightQueue, function(a, b) return (rank[a.state] or 9) < (rank[b.state] or 9) end)
end

--- One hull, one look.
-- @param id any
-- @param snapshot table this client's snapshot
-- @param now number
-- @param watchCfg table
-- @param seat table|nil this client's seat read
local function sightOne(id, snapshot, now, watchCfg, seat)
    local key = M.KeyOf(id)
    local sampled = pointFrom(snapshot.position)
    if sampled == nil then
        if not sightBlind then
            sightBlind = true
            Open77.log.info('sight: this client\'s vehicle snapshot carries no position, so the '
                .. 'watch cannot compare what it draws with the server\'s samples here')
        end
        return
    end
    local frame = hullFrame(id)
    if frame == nil then return end
    local drawn = { x = frame.x, y = frame.y, z = frame.z }
    local metres = apart3(drawn, sampled)
    local speed = finite(snapshot.speed) or 0.0
    local limit = M.DriftLimit(watchCfg, speed)
    local seatedHere = seat ~= nil and M.SameHull(seat.vehicleId, id)
    local episode = sights[key]

    local function report(state)
        return {
            id = key, state = state, drawn = rounded(drawn), sampled = rounded(sampled),
            metres = tenth(metres), worst = tenth(episode and episode.worst or metres),
            seconds = episode and tenth((now - episode.since) / 1000.0) or 0.0,
            owner = tonumber(snapshot.physicsOwner), epoch = tonumber(snapshot.authorityEpoch),
            frozen = snapshot.frozen == true, speed = tenth(speed), seated = seatedHere,
            sampleAgeMs = tenth(snapshot.packetAgeMs), extrapolating = snapshot.extrapolating == true,
        }
    end

    if episode == nil then
        if metres <= limit then return end
        episode = { since = now, worst = metres, calm = 0, reportedAt = now, seenAt = now }
        sights[key] = episode
        Open77.log.warn(('sight: aircraft %s is drawn %.1f m from where its last sample puts it '
            .. '(limit %.1f m at %.1f m/s; owner %s, epoch %s%s%s%s%s): drawn %.1f, %.1f, %.1f -- sample %.1f, %.1f, %.1f')
            :format(key, metres, limit, speed, tostring(snapshot.physicsOwner or '?'),
                tostring(snapshot.authorityEpoch or '?'),
                snapshot.locallyOwned == true and ', simulated here' or '',
                snapshot.frozen == true and ', frozen' or '',
                seatedHere and ', this body is seated in it' or '',
                finite(snapshot.packetAgeMs) ~= nil and (', sample %.0f ms old'):format(finite(snapshot.packetAgeMs)) or '',
                drawn.x, drawn.y, drawn.z, sampled.x, sampled.y, sampled.z))
        owe(report('open'))
        return
    end

    episode.seenAt = now
    if metres > episode.worst then episode.worst = metres end
    if metres <= watchCfg.settle then
        episode.calm = episode.calm + 1
        if episode.calm >= 2 then
            Open77.log.info(('sight: aircraft %s is drawn where its sample is again after %.1f s '
                .. '(%.1f m at worst)'):format(key, (now - episode.since) / 1000.0, episode.worst))
            owe(report('closed'))
            sights[key] = nil
        end
        return
    end
    episode.calm = 0
    if now - episode.reportedAt >= watchCfg.repeatMs then
        episode.reportedAt = now
        Open77.log.warn(('sight: aircraft %s is still drawn %.1f m from its sample after %.1f s '
            .. '(%.1f m at worst; owner %s, epoch %s)'):format(key, metres, (now - episode.since) / 1000.0,
            episode.worst, tostring(snapshot.physicsOwner or '?'), tostring(snapshot.authorityEpoch or '?')))
        owe(report('still'))
    end
end

--- One look over the nearest aircraft, and at most one report sent.
-- @param now number
-- @param seat table|nil
-- @return integer how many hulls were measured
function M.Sight(now, seat)
    local watchCfg = M.WatchSettings()
    if watchCfg.off then return 0 end
    now = now or M.Now()
    local measured = 0
    for _, near in ipairs(aircraftNear(watchCfg)) do
        if measured >= watchCfg.hulls then break end
        -- A hull this client simulates is drawn where this client puts it, and that
        -- is the pose it reports: there is nothing to compare.
        if near.snapshot.locallyOwned ~= true and near.snapshot.streamed ~= false then
            measured = measured + 1
            sightOne(near.id, near.snapshot, now, watchCfg, seat)
        end
    end
    -- An episode whose hull has not been measured for a while (gone, out of range,
    -- now simulated here) is over, quietly: there is nothing left to compare.
    for key, episode in pairs(sights) do
        if now - (episode.seenAt or episode.since) > math.max(5000, watchCfg.sight * 4) then
            sights[key] = nil
        end
    end
    local report = table.remove(sightQueue, 1)
    if report ~= nil then TriggerServerEvent(M.Event.SIGHT, report) end
    return measured
end

-- ── the hello ────────────────────────────────────────────────────────────────

--- Says hello to the server (see `greeting`); a new sequence when the world is
--- ready again.
-- @param why string for the log
local function sayHello(why, restart)
    local now = M.Now()
    if greeting == nil or restart then
        greeting = { tries = 0, firstAt = now, at = now, welcomed = false, failures = {} }
    end
    if greeting.welcomed then return end
    greeting.tries = greeting.tries + 1
    greeting.at = now
    -- `enter`: this client knows the boarding step (1.7.0, client/enter.lua) --
    -- and can draw it (1.7.2): `anim`, open77_avexit's package on this game;
    -- `launcher`, what the launcher told this game at its start (the server's
    -- log names a game started with another world's mods).
    local package = M.AnimPackage ~= nil and M.AnimPackage() or nil
    local missing = package ~= nil and package.known == true and package.ok ~= true
    if missing then M.FilesMissingNotice('the hello', package.reason) end
    greeting.animKnown = package == nil or package.known == true
    local read, sent, reason = pcall(TriggerServerEvent, M.Event.HELLO, { try = greeting.tries, version = M.VERSION,
        why = why, enter = M.Enter ~= nil and not missing,
        anim = package ~= nil and { known = package.known == true, ok = package.ok == true,
            reason = package.reason ~= nil and tostring(package.reason):sub(1, 80) or nil } or nil,
        launcher = M.LauncherContext ~= nil and M.LauncherContext() or nil })
    if not read or sent == false then
        local cause = tostring(read and (reason or 'refused') or sent)
        greeting.failures[cause] = (greeting.failures[cause] or 0) + 1
        if greeting.failures[cause] == 1 then
            Open77.log.info(('hello to the server not sent (%s; try %d, %s): said again in %.0fs'):format(cause,
                greeting.tries, why, HELLO_EVERY_MS / 1000.0))
        end
        return
    end
    if greeting.tries == 1 or greeting.tries % 5 == 0 then
        Open77.log.info(('hello said to the server (try %d, %s): the exit sync waits for this screen once it is '
            .. 'answered'):format(greeting.tries, why))
    end
end

-- How often a hello that could not say whether the clips play here asks again.
local ANIM_ASK_EVERY_MS = 2000

--- Every pass: the hello said again until it is answered -- and once more
--- when open77_avexit answers only after it, that the clips cannot play here.
local function helloTick(now)
    if greeting ~= nil and greeting.welcomed and greeting.animKnown == false and M.AnimPackage ~= nil
        and now - (greeting.animAskAt or 0) >= ANIM_ASK_EVERY_MS then
        greeting.animAskAt = now
        local package = M.AnimPackage()
        if package.known then
            greeting.animKnown = true
            if package.ok ~= true then sayHello('open77_avexit answered after the hello: no clips here', true) end
        end
    end
    if greeting == nil or greeting.welcomed then return end
    if greeting.tries >= HELLO_TRIES and not greeting.lateSaid then
        greeting.lateSaid = true
        Open77.log.warn(('the server has not answered this client\'s hello in %.0fs (%d tries): no exit near this '
            .. 'player waits for this screen until it does; said again every %.0fs'):format(
            (now - greeting.firstAt) / 1000.0, greeting.tries, HELLO_LATE_MS / 1000.0))
    end
    local every = greeting.tries < HELLO_TRIES and HELLO_EVERY_MS or HELLO_LATE_MS
    if now - greeting.at >= every then sayHello('no answer yet') end
end

--- The server's answer to the hello.
local function welcomed(payload)
    if greeting == nil then greeting = { tries = 0, firstAt = M.Now(), at = M.Now(), failures = {} } end
    if greeting.welcomed then return end
    greeting.welcomed = true
    if M.StandIn ~= nil then M.StandIn.Up(M.Now()) end
    Open77.log.info(('the server heard this client\'s hello (try %d, %.1fs after the first%s): every exit near this '
        .. 'player waits for this screen'):format(greeting.tries, (M.Now() - greeting.firstAt) / 1000.0,
        type(payload) == 'table' and payload.version ~= nil and (', the server runs %s'):format(tostring(payload.version))
            or ''))
end

-- THE WATCH IS FOUR JOBS (1.5.1), each a thread of its own: the seat and the
-- exit; the door card and the flight; the sight check; the exit scene. One
-- pass that did all four ran past the host's budget on the laptop -- a resume
-- that reaches 10 000 instructions is killed on a loaded client (shared/core.lua,
-- `M.Breathe`) -- and lost the exit scene's pass mid-way (Staging, 2026-10-28,
-- 04:39:17 and :23). Each job is its own resume, with its own budget, every
-- frame they are due. The seat read the others need is the last one this job
-- made (`watched`).
local watched = nil

local function clockNow()
    local clock = M.Sync ~= nil and M.Sync.Clock or nil
    return clock ~= nil and clock() or nil
end

--- What a job's pass cost, for the frame meter (client/sync.lua): its time,
--- less what it waited (an interactions call, the frames it breathed).
local function passCost(began, waited, breathed)
    if began == nil or M.Sync == nil then return end
    local done = clockNow()
    local rested = breathed ~= nil and ((M.Breathed or 0) - breathed) or 0
    if done ~= nil then M.Sync.Pass(done - began - (waited or 0) - rested) end
end

--- One pass of the seat and the exit: the seat read, the fade, the guard, the
--- exit clip's look, the hello.
local function watch()
    local began = clockNow()
    local breathed = M.Breathed or 0
    local seat = mySeat()
    watched = { seat = seat, at = M.Now() }
    watchSeat(seat)
    helloTick(M.Now())
    -- The stand-in, made ahead out of sight (client/standin.lua, 1.7.5).
    if M.StandIn ~= nil then
        local ran, failure = pcall(M.StandIn.Tick, M.Now(), seat)
        if not ran then Open77.log.warn('the stand-in pass failed: ' .. tostring(failure)) end
    end
    passCost(began, 0, breathed)
end

--- One pass of the card, and -- four times a second while this client flies a
--- voiced AV -- the flight.
local function cardPass()
    local began = clockNow()
    local seat = watched ~= nil and watched.seat or mySeat()
    -- The card may wait on the interactions service (a frame or more): that
    -- wait is not what this pass costs the frame.
    local carded, failure = pcall(syncCard, seat ~= nil)
    if not carded then Open77.log.warn('the door card pass failed: ' .. tostring(failure)) end
    local waited = began ~= nil and (clockNow() - began) or 0
    local now = M.Now()
    if seat ~= nil or flight ~= nil then
        if now - flightAt >= FLIGHT_MS then
            flightAt = now
            readFlight(seat)
        end
    end
    passCost(began, waited)
end

--- The sight check, at its own rate.
local function sightPass()
    local now = M.Now()
    if now - sightAt < M.WatchSettings().sight then return end
    sightAt = now
    local began = clockNow()
    local ran, sightFailure = pcall(M.Sight, now, watched ~= nil and watched.seat or nil)
    if not ran then
        Open77.log.warn('the sight check failed: ' .. tostring(sightFailure))
    end
    passCost(began)
end

--- THE EXIT SCENE (client/sync.lua): the bodies this screen watches for the
--- server, and the reports due.
local function scenePass()
    if M.Sync == nil then return end
    local began = clockNow()
    local ran, syncFailure = pcall(M.Sync.Tick, M.Now())
    if not ran then Open77.log.warn('the exit scene pass failed: ' .. tostring(syncFailure)) end
    passCost(began)
end

-- ── the start and the stop ───────────────────────────────────────────────────

function M.Start()
    RegisterNetEvent(M.Event.DOOR, function(payload)
        if type(payload) ~= 'table' or payload.open ~= true or payload.id == nil then
            door = nil
        else
            door = { id = tostring(payload.id),
                role = payload.role == 'passenger' and 'passenger' or 'pilot',
                at = type(payload.at) == 'table' and payload.at or nil }
        end
        cardDirty = true
    end)

    -- THE CARD'S KEY. The interactions service raises the event on this
    -- resource's own VM, with this resource as the owner.
    AddEventHandler(M.CHOICE, function(payload)
        if type(payload) ~= 'table' or payload.owner ~= RESOURCE then return end
        local data = type(payload.data) == 'table' and payload.data or {}
        local ran, failure = pcall(M.Press, 'key', data.id)
        if not ran then Open77.log.error('the door key failed: ' .. tostring(failure)) end
    end)

    RegisterNetEvent(M.Event.BOARDED, function(payload)
        if type(payload) ~= 'table' then return end
        -- Answered, either way: the next press is a new press.
        askedAt = nil
        -- A boarding step under way ends with this word (client/enter.lua).
        if M.Enter ~= nil then
            local ran, failure = pcall(M.Enter.Boarded, payload)
            if not ran then Open77.log.error('the boarding step\'s end failed: ' .. tostring(failure)) end
        end
        if payload.ok == true then
            Open77.log.info(('boarded in %s as %s'):format(tostring(payload.seat),
                tostring(payload.role)))
            door = nil
            cardDirty = true
            return
        end
        local code = tostring(payload.reason or 'seat_refused')
        notify(M.Text(M.Refusal[code] or 'refused.failed', { reason = tostring(payload.detail or code) }))
        Open77.log.info(('boarding refused: %s%s'):format(code,
            payload.detail ~= nil and (' (' .. tostring(payload.detail) .. ')') or ''))
    end)

    RegisterNetEvent(M.Event.PLAY, function(payload)
        local ran, answer = pcall(play, payload)
        if not ran then
            Open77.log.warn('a flight sound failed: ' .. tostring(answer))
            answer = { ok = false, streamed = true, reason = ('error: %s'):format(tostring(answer):sub(1, 60)) }
        end
        acknowledge(payload, answer)
    end)

    -- A hull taken out of the world: what this half remembers of it goes.
    AddEventHandler('open77:vehicleRemoved', function(id)
        if id == nil then return end
        kinds[M.KeyOf(id)] = nil
        if door ~= nil and M.SameHull(door.id, id) then
            door = nil
            cardDirty = true
        end
    end)

    -- The exit clip's answers (client/walkout.lua).
    if M.WalkOut ~= nil then M.WalkOut.Start() end
    -- The exit key's answers (client/leave.lua, 1.9.0).
    if M.Leave ~= nil then M.Leave.Start() end
    -- The boarding step's ask and answer (client/enter.lua).
    if M.Enter ~= nil then M.Enter.Start() end
    -- The exit scenes this screen draws for the server, and its frame meter
    -- (client/sync.lua).
    if M.Sync ~= nil then M.Sync.Start() end

    -- A seat read every 100 ms (and every frame aboard an aircraft, the
    -- sentinel) catches the first frame of an exit; the card, the sight and the
    -- exit scene are jobs of their own, each its own resume (see `watched`).
    watchJob = M.Every('watch', 100, watch)
    cardJob = M.Every('card', 100, cardPass)
    sightJob = M.Every('sight', 100, sightPass)
    sceneJob = M.Every('scene', 100, scenePass)

    -- The diag pictures of each exit (`client/shots.lua`).
    if M.Shots ~= nil then M.Shots.Start() end
    -- The stand-in, made ahead out of sight (`client/standin.lua`).
    if M.StandIn ~= nil then M.StandIn.Start() end
    if M.GroundTest ~= nil then M.GroundTest.Start() end
    -- The landing pad under an AV a resource flies (`client/pad.lua`).
    if M.Pad ~= nil then M.Pad.Start() end
    -- The landing call, in this game's own language (`client/callout.lua`).
    if M.Call ~= nil then M.Call.Start() end
    -- The pad snap's measure of the deck, asked of the pilot (`client/snap.lua`).
    if M.SnapClient ~= nil then M.SnapClient.Start() end

    -- Every handler is registered: whatever the server sent before now went
    -- nowhere, so it is asked to send it again -- until it answers, and again
    -- when the world is up (a hello said while the game loads goes nowhere).
    RegisterNetEvent(M.Event.WELCOME, function(payload)
        local ran, failure = pcall(welcomed, payload)
        if not ran then Open77.log.error('the server\'s welcome failed: ' .. tostring(failure)) end
    end)
    AddEventHandler('open77:worldReady', function()
        local ran, failure = pcall(sayHello, 'the world is ready', true)
        if not ran then Open77.log.error('the hello failed: ' .. tostring(failure)) end
    end)
    sayHello('the resource started')

    local anim = M.WalkOutSettings()
    local step = M.EnterSettings()
    Open77.log.info(('client ready (%s): door card on %s, exit curtain %s (down once the body stands beside the door; '
        .. 'never at the exit), exit guard %s, watch %s, exit clip %s, exit view %s, boarding step %s, the seat %s')
        :format(M.VERSION, cardKey(), fadeSettings() ~= nil and 'on' or 'off',
            (M.ExitSettings().off or not M.ExitSettings().place) and 'off' or 'on',
            M.WatchSettings().off and 'off' or 'on',
            anim.off and 'off' or (anim.style .. ' (' .. anim.clip .. '/' .. anim.mirrorClip .. ')'),
            anim.holdView and 'held in third person' or 'the platform\'s',
            (step.off or anim.off or M.Enter == nil) and 'off' or (step.clip .. '/' .. tostring(step.mirrorClip or 'none')),
            (step.seatCurtain and fadeSettings() ~= nil)
                and ('under a short fade (black in %d ms as first person is forced, the image back over %d ms, %d ms '
                    .. 'after the seat)'):format(step.seatFadeOut, step.seatFadeIn, step.seatSettle)
                or 'a cut (no fade)'))
end

function M.Stop()
    M.Cancel(watchJob)
    M.Cancel(cardJob)
    M.Cancel(sightJob)
    M.Cancel(sceneJob)
    watchJob, cardJob, sightJob, sceneJob = nil, nil, nil, nil
    if sentinel ~= nil then sentinel.live = false end
    sentinel = nil
    if M.Pad ~= nil then M.Pad.Stop() end
    if M.Call ~= nil then M.Call.Stop() end
    if M.Shots ~= nil then M.Shots.Stop() end
    if M.StandIn ~= nil then M.StandIn.Stop() end
    if M.GroundTest ~= nil then M.GroundTest.Stop() end
    endGuard('stopped')
    endFade(true)
    if M.WalkOut ~= nil then M.WalkOut.Stop() end
    if M.Enter ~= nil then M.Enter.Stop() end
    if M.Sync ~= nil then M.Sync.Stop() end
    if M.Leave ~= nil then M.Leave.Stop() end
    -- The interactions service sweeps a stopped owner's cards on its own; this
    -- is the polite version, without waiting on an answer.
    if card ~= nil and type(Open77.exports) == 'table' and type(Open77.exports.call) == 'function' then
        pcall(Open77.exports.call, 'open77_interactions', 'clear')
    end
    card, door = nil, nil
end

AddEventHandler('onClientResourceStop', function(name)
    if name == RESOURCE then M.Stop() end
end)

M.Start()
