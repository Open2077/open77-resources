-- =============================================================================
-- open77_avdoor -- client/leave.lua
-- =============================================================================
-- THE EXIT KEY (1.9.0, `LEAVE` in shared/config.lua).
--
-- The game steps a body out of the Militech Manticore's seats the way it steps
-- out of a car: ANIMATED, the body held mounted, in the exit's workspot, for
-- about two seconds while it climbs down beside the hull. The exit then put the
-- body beside the door eight times in 1.5 s, none held, and gave the clip up
-- (XyberRP Staging, 2026-10-30, 22:46:23 -- "the screen glitched out ... and it
-- didn't play exit anim"). The Excalibur's seats have no such exit: the body is
-- out at once, and its exit clip plays.
--
-- So while this body sits in an airframe whose exit the game animates
-- (`AIRFRAMES` ... `EXIT_FORCED`), its exit key is this resource's: `LEAVE.KEY`
-- (F, the game's own), registered with `consume` -- the game's exit never
-- starts -- and dropped again the moment the body is out (F is the door card's
-- on foot). The press asks the server (`LEAVE`), which checks the seat and
-- steps the body out through the platform's forced exit, which the leaving game
-- makes instant (`Open77.vehicles.taskPlayerLeave`). The exit is then the
-- Excalibur's: the door opens, the body is put beside it, the clip plays.
--
-- A game that cannot consume the key keeps the game's own exit, and a body that
-- leaves another way (another exit key, a game pad) leaves animated: the exit
-- then sees the body still mounted and places nothing (client/main.lua,
-- `beginExit`). `L.Asked` tells the two apart.
-- =============================================================================

local M = AvDoor
local L = {}
M.Leave = L

local mapping = nil    -- { id, key, hull, seat, record, since } while the key is ours
local ask = nil        -- { id, seat, at, answered } the last press, for `L.Asked`
local refused = nil    -- why this game cannot have the key (said once)
local heard = {}

local function settings() return M.LeaveSettings() end

local function input()
    local api = Open77.input
    if type(api) ~= 'table' or type(api.registerKeyMapping) ~= 'function' then return nil end
    return api
end

--- Once per reason, a line in this game's log.
local function once(key, text)
    if heard[key] then return end
    heard[key] = true
    Open77.log.info(text)
end

--- What this game's engine says of the body: `{ mounted, workspot }`.
local function bodyNow()
    local character = Open77.character
    if type(character) ~= 'table' or type(character.state) ~= 'function' then return nil end
    local read, state = pcall(character.state)
    if not read or type(state) ~= 'table' then return nil end
    local vehicle = type(state.vehicle) == 'table' and state.vehicle or {}
    return { mounted = vehicle.mounted == true or state.inVehicle == true, workspot = state.inWorkspot == true }
end

--- The key is the game's again.
-- @param why string
local function release(why)
    local held = mapping
    if held == nil then return end
    mapping = nil
    local api = Open77.input
    local text = 'not dropped (no Open77.input.unregisterKeyMapping)'
    if type(api) == 'table' and type(api.unregisterKeyMapping) == 'function' then
        local read, ok, reason = pcall(api.unregisterKeyMapping, held.id)
        text = (read and ok ~= false) and 'dropped' or ('could not be dropped: ' .. tostring(read and reason or ok))
    end
    Open77.log.info(('exit key %s (%s) %s after %.1fs -- %s: the game\'s own again'):format(held.id, held.key, text,
        (M.Now() - held.since) / 1000.0, tostring(why)))
end

--- The press: step this body out of the seat the key was taken for.
local function press()
    local held = mapping
    if held == nil then return end
    local s = settings()
    local now = M.Now()
    if ask ~= nil and M.SameHull(ask.id, held.hull) and now - ask.at < s.askGap then
        Open77.log.info(('exit key: pressed again %.1fs after the ask -- waiting for its answer')
            :format((now - ask.at) / 1000.0))
        return
    end
    -- The game's own exit already holds the body (the key went to it too):
    -- the server's forced exit would meet it mid-way.
    local body = bodyNow()
    if body ~= nil and body.mounted ~= true then
        Open77.log.info('exit key: the engine has already let go of the body -- nothing to ask')
        return
    end
    ask = { id = held.hull, seat = held.seat, at = now }
    TriggerServerEvent(M.Event.LEAVE, { id = M.KeyOf(held.hull), seat = held.seat })
    Open77.log.info(('exit key %s pressed: the server is asked to step this body out of %s of %s (%s)')
        :format(held.key, tostring(held.seat), tostring(held.hull), tostring(held.airframe or held.record)))
end

--- Takes the key for this seat: `true`, or `false, why`.
local function take(seat)
    local s = settings()
    local api = input()
    if api == nil then return false, 'no Open77.input.registerKeyMapping on this client' end
    local called, first, second = pcall(api.registerKeyMapping, {
        id = s.id,
        name = s.name,
        key = s.key,
        consume = true,
        onPressed = function()
            local ran, failure = pcall(press)
            if not ran then Open77.log.error('the exit key failed: ' .. tostring(failure)) end
        end,
    })
    if not called then return false, 'error: ' .. tostring(first) end
    if first == nil or first == false then return false, tostring(second or 'refused') end
    -- `true, effectiveKey` (the platform), or the effective key alone.
    local effective = first == true and second or first
    local frame = M.Airframe(seat.record)
    mapping = { id = s.id, key = tostring(effective or s.key), hull = seat.vehicleId, seat = seat.seat,
        record = seat.record, airframe = frame ~= nil and frame.NAME or nil, since = M.Now() }
    return true
end

--- Every seat read (client/main.lua, `watchSeat`): the key is this
--- resource's while the body sits, not leaving, in an airframe whose exit the
--- game animates; the game's otherwise.
-- @param seat table|nil `{ vehicleId, seat, record }`, or nil when not seated
--   (or leaving)
function L.Tick(seat)
    -- Cheap on every pass that has nothing to do (the watch shares its resume
    -- with the rest of the seat's look, under the host's budget): no settings
    -- are read off an airframe the key is for.
    if mapping == nil and (seat == nil or seat.vehicleId == nil) then return end
    local wanted = seat ~= nil and seat.vehicleId ~= nil and M.ExitForced(seat.record) and not settings().off
    if mapping ~= nil then
        if not wanted then return release(seat == nil and 'the seat was left' or 'not an airframe the key is for') end
        if not M.SameHull(mapping.hull, seat.vehicleId) or mapping.seat ~= seat.seat then
            -- Another seat or another hull: the key follows it.
            mapping.hull, mapping.seat, mapping.record = seat.vehicleId, seat.seat, seat.record
        end
        return
    end
    if not wanted or refused ~= nil then
        if wanted and refused ~= nil then
            once('refused', ('exit key: not taken (%s) -- the game\'s own exit stays, animated'):format(refused))
        end
        return
    end
    local ok, why = take(seat)
    if not ok then
        refused = why
        Open77.log.warn(('exit key: %s (%s) could not be taken for %s of %s (%s): the game\'s own exit stays, '
            .. 'animated -- the body is not placed and no clip is played'):format(settings().id, settings().key,
            tostring(seat.seat),
            tostring(seat.vehicleId), tostring(why)))
        return
    end
    Open77.log.info(('exit key %s (%s) taken for %s of %s (%s): the game animates this seat\'s own exit, so the key '
        .. 'asks the server to step the body out at once -- the door, the body beside it, the clip'):format(mapping.id,
        mapping.key, tostring(seat.seat), tostring(seat.vehicleId), tostring(mapping.airframe or seat.record)))
end

--- Whether the exit from this hull now is the one the key asked for.
-- @param id any the hull
-- @return boolean
-- @return number|nil ms since the ask
function L.Asked(id)
    if ask == nil or not M.SameHull(ask.id, id) then return false end
    local since = M.Now() - ask.at
    if since > settings().asked then return false end
    return true, since
end

--- The exit from this hull has been seen: the ask is spent.
function L.Exited(id)
    if ask ~= nil and M.SameHull(ask.id, id) then ask = nil end
end

--- The server's answer to the ask.
local function answered(payload)
    if type(payload) ~= 'table' then return end
    if ask ~= nil and payload.id ~= nil and M.SameHull(ask.id, payload.id) then ask.answered = payload.ok == true end
    if payload.ok == true then
        Open77.log.info(('exit key: the server steps this body out of %s (%s)'):format(tostring(payload.id),
            tostring(payload.how or 'forced exit')))
        return
    end
    Open77.log.warn(('exit key: the server would not step this body out of %s: %s'):format(tostring(payload.id),
        tostring(payload.reason)))
    -- Refused: the next press is a new ask.
    if ask ~= nil and payload.id ~= nil and M.SameHull(ask.id, payload.id) then ask = nil end
end

--- What the key is doing, for `avdoor.status`.
function L.Status()
    return { held = mapping ~= nil, key = mapping ~= nil and mapping.key or nil,
        hull = mapping ~= nil and tostring(mapping.hull) or nil, refused = refused,
        asked = ask ~= nil and (M.Now() - ask.at) or nil }
end

function L.Start()
    RegisterNetEvent(M.Event.LEFT, function(payload)
        local ran, failure = pcall(answered, payload)
        if not ran then Open77.log.error('the exit key\'s answer failed: ' .. tostring(failure)) end
    end)
end

function L.Stop()
    release('the resource stops')
    ask = nil
end
