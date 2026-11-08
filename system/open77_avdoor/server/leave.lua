-- =============================================================================
-- open77_avdoor -- server/leave.lua
-- =============================================================================
-- THE EXIT KEY, THE SERVER'S HALF (1.9.0, `LEAVE` in shared/config.lua).
--
-- A body seated in an airframe whose exit the game animates (`AIRFRAMES` ...
-- `EXIT_FORCED`, the Militech Manticore) has this resource's exit key
-- (client/leave.lua). Its press reaches this file as `LEAVE { id, seat }`, is
-- judged again here in full -- the asker's own canonical seat, its hull, the
-- airframe, a body that is not already leaving -- and is carried out with the
-- platform's forced exit (`Open77.vehicles.forcePlayerOutOfVehicle`), which
-- the leaving game makes instant: no workspot, the body out at once, as from
-- the Excalibur's seats. The rest of the exit -- the door for everybody, the
-- body beside it, the clip -- is the exit every seat has (server/main.lua
-- `M.Exited`, server/walkout.lua). The asker is answered `LEFT`.
-- =============================================================================

local M = AvDoor
local L = {}
M.LeaveServer = L

local counts = { asked = 0, forced = 0, refused = 0 }
local lastRefusal = nil

--- The answer to the asker.
local function answer(player, payload)
    pcall(TriggerClientEvent, M.Event.LEFT, player, payload)
end

local function refuse(player, id, reason, detail)
    counts.refused = counts.refused + 1
    lastRefusal = reason
    Open77.log.info(('exit key of player %d: refused (%s)%s'):format(player, reason,
        detail ~= nil and (' -- ' .. tostring(detail)) or ''))
    answer(player, { id = id ~= nil and M.KeyOf(id) or nil, ok = false, reason = reason })
    return false, reason
end

--- One press: step this player out of the seat they hold, or say why not.
-- @param player integer the asker (`source`)
-- @param payload table `{ id, seat }`
-- @return boolean
-- @return string|nil why not
function L.Ask(player, payload)
    counts.asked = counts.asked + 1
    local settings = M.LeaveSettings()
    local named = type(payload) == 'table' and payload.id or nil
    if settings.off then return refuse(player, named, 'off') end
    if M.Cooling(player, 'leave', settings.serverGap) then return refuse(player, named, 'busy') end
    local seat = M.SeatOfPlayer(player)
    if seat == nil then return refuse(player, named, 'not_seated') end
    if named == nil or not M.SameHull(seat.vehicleId, named) then
        return refuse(player, named, 'not_this_hull', ('seated in %s'):format(tostring(seat.vehicleId)))
    end
    if seat.exiting == true then
        -- The game's own exit is already under way: a forced exit now would
        -- meet it mid-way.
        return refuse(player, named, 'already_leaving')
    end
    local snapshot = M.HullOf(seat.vehicleId)
    local record = type(snapshot) == 'table' and snapshot.record or nil
    if not M.ExitForced(record) then
        -- Elsewhere the game's own exit is instant: it is left to the game.
        return refuse(player, named, 'not_an_animated_exit', tostring(record))
    end
    local players = Open77.players
    if type(players) == 'table' and type(players.isDead) == 'function' then
        local read, dead = pcall(players.isDead, player)
        if read and dead == true then return refuse(player, named, 'dead') end
    end
    local api = Open77.vehicles
    local force = type(api) == 'table' and (api.forcePlayerOutOfVehicle or api.taskPlayerLeave) or nil
    if type(force) ~= 'function' then return refuse(player, named, 'no_forced_exit_on_this_host') end
    local called, ok, reason = pcall(force, player, seat.vehicleId)
    if not called or ok ~= true then
        Open77.log.warn(('exit key of player %d: the forced exit from %s of %s was refused: %s'):format(player,
            tostring(seat.seat), tostring(seat.vehicleId), tostring(called and reason or ok)))
        return refuse(player, named, 'forced_exit_refused', called and reason or ok)
    end
    counts.forced = counts.forced + 1
    Open77.log.info(('exit key of player %d: stepped out of %s of aircraft %s (%s) through the forced exit -- '
        .. 'instant on their game; the door and the clip follow as every exit\'s'):format(player,
        tostring(seat.seat), tostring(seat.vehicleId), tostring(record)))
    answer(player, { id = M.KeyOf(seat.vehicleId), ok = true, how = 'forced exit' })
    return true
end

function L.Status()
    return { asked = counts.asked, forced = counts.forced, refused = counts.refused, lastRefusal = lastRefusal }
end

function L.Start()
    counts = { asked = 0, forced = 0, refused = 0 }
    lastRefusal = nil
    RegisterNetEvent(M.Event.LEAVE, function(payload)
        local player = M.ValidPlayer(source)
        if player == nil or type(payload) ~= 'table' then return end
        local ran, failure = pcall(L.Ask, player, payload)
        if not ran then Open77.log.error('the exit key failed: ' .. tostring(failure)) end
    end)
end

function L.Stop() end
