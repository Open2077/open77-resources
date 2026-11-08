-- =============================================================================
-- open77_avdoor -- server/land.lua
-- =============================================================================
-- The hull on its gear: an airframe whose last body just stepped out is set
-- down on its landing gear, where the platform's flight left it hovering --
-- and (1.7.1) an empty one a player is about to step up into, when its door's
-- step hangs out of the boarding clip's reach (server/enter.lua, `E.SetDown`).
--
-- WHY. The platform's AV flight lands a hull on the lowest point of its
-- collision hull, measured once by a ray at engage (`vhull ... belly=`). For
-- the Rayfield Excalibur that point is 1.46 m under the origin, while its gear
-- feet are 0.99 to 1.06 m under it: parked, it floats with its gear 0.4 m off
-- the ground, and its door's step -- which the exit clip starts on -- is 1.1 m
-- up instead of the 0.6 m the airframe stands it at. The clip steps down half
-- a metre; from 1.1 m it looked like a fall ("im falling down outside the av",
-- XyberRP Staging, 2026-10-27). So once nobody is aboard, the hull is lowered
-- onto its gear: `Open77.vehicles.setTransform`, the platform's own way to put
-- one pose in front of every viewer (the watch's heal uses it the same way).
--
-- WHAT IS TRUSTED. The server has no physics world, so the ground under each
-- foot comes from the game of the player who stepped out (`LAND`): a measure,
-- never a pose. The height is this file's own sum -- the highest foot's ground
-- plus the airframe's `LAND.HEIGHT` -- checked against the server's own hull:
-- one floor under all the feet (`FLAT_METRES`), a hull that comes DOWN, at most
-- `MAX_DROP_METRES`. It is asked of the player whose exit the server saw, for
-- that hull, within `LAND_WINDOW_MS`, and done once, `LAND_DELAY_MS` after the
-- exit (inside the fade), on a hull nobody is aboard and nobody froze. A
-- measure made away from the server's hull (an engine that still drew it where
-- its flight began: 2.6 m on Staging, 2026-10-28, 01:10:54) leaves the exit
-- open for the game's next one, `MAX_MEASURES` at most. Every refusal is a
-- line in the log, and so is a hull that already stood on its gear.
--
-- THE GLIDE (1.7.9). A pilot may step out while the AV still hovers -- its gear
-- 1.01 m over the ground, past the 0.8 m a hull was lowered by at most, and no
-- exit clip (Staging, 2026-10-29, 16:49:32). Up to `MAX_DROP_METRES` (3.0 for
-- the Excalibur) a hull is set down now, and a set-down of more than
-- `EXIT.LAND_GLIDE_FROM_METRES` is glided, not dropped: one `setTransform`
-- every `LAND_GLIDE_TICK_MS` (`Land.Glide`, a job that runs only while a glide
-- does), eased in and out (`M.GlideZ`), over the drop at `LAND_GLIDE_SPEED`
-- (`M.GlideMs`). Every pose re-reads the hull: somebody aboard, a freeze, a
-- move across by anything else, a pose refused or the hull gone end the glide
-- where it is, said. While it glides, the exit is still waited for
-- (`Land.Waiting`, `Land.Gliding`): an exit clip is played from the hull on
-- its gear, a boarding asked again once it stands there.
--
-- A BOARDING BEHIND A PILOT (1.8.4). The flight parks an AV its pilot sits in
-- the same way, 0.4 m over its gear, and a player boarding behind the pilot
-- was seated plainly: the door's step 1.07 m up, Corpo V's climb ending under
-- the back seat. For a boarding, a hull somebody is aboard is set down too --
-- if it hangs at most `BOARD.ABOARD_DROP_METRES` over its gear -- in ONE move
-- (a glide is a hand-over of the flight per pose), FROZEN first, and HELD on
-- its gear (`Land.Join`) until every body boarding it is seated or gave up
-- (`Land.Release`), `BOARD.ABOARD_HOLD_MS` at most: the pilot's own reports
-- are discarded while it is frozen, so every other screen keeps it on its gear
-- through the step. Then the freeze comes off and the pilot's flight has it
-- again. One move, one hand-over: the pilot's game may let its chase camera go
-- once. Every hold, join and release is a line in the log.
-- =============================================================================

local M = AvDoor

M.Land = {}
local Land = M.Land

-- Exits of an airframe with known gear, by hull key: `{ id, player, at, record }`.
local exits = {}
-- The games' measures, by hull key and then by player: `{ grounds, x, y, at }`.
-- Only the exiting player's own is ever used: nobody else's can stand in for it.
local asks = {}
-- What happened, for the status line.
local counts = { exits = 0, asked = 0, lowered = 0, refused = 0, glided = 0, glidesCut = 0, poses = 0 }
-- Glides under way, by hull key: `{ id, key, x, y, yaw, from, to, began, ms,
-- endsAt, poses, z, player, what, highest }`.
local glides = {}
-- The job that poses them (`Land.Glide`), only while there is one.
local glideJob = nil
-- Hulls held on their gear for boardings behind a pilot (1.8.4), by hull key:
-- `{ id, key, players = { [player] = true }, since, untilAt, crew, from, to }`.
local holds = {}
-- A glide is ended by a move of the hull across bigger than this: something
-- else (a resource, a flight) has it.
local GLIDE_MOVED_METRES = 0.75

local function finite(value)
    local number = tonumber(value)
    if number == nil or number ~= number or number == math.huge or number == -math.huge then return nil end
    return number
end

local function refuse(key, why)
    counts.refused = counts.refused + 1
    Open77.log.info(('aircraft %s stays where the flight left it: %s'):format(key, why))
end

--- An aircraft seat was left (`M.Exited`): its hull may be set on its gear.
-- @param id any the hull
-- @param record string|nil its record
-- @param playerId any who stepped out
function Land.Exited(id, record, playerId)
    local exit = M.ExitSettings()
    if exit.off or not exit.land or M.AirframeLand(record) == nil then return end
    local player = tonumber(playerId)
    if player == nil then return end
    exits[M.KeyOf(id)] = { id = id, player = player, at = M.Now(), record = record }
    counts.exits = counts.exits + 1
end

--- The exiting game's measure of the ground under the gear. A foot with no
--- ground under it is sent as a hole, with the game's own word for it.
-- @param playerId integer
-- @param payload table `{ id, grounds = { z, ... }, x, y, z?, why? }`
-- @return boolean whether it was kept
function Land.Ask(playerId, payload)
    local player = tonumber(playerId)
    if player == nil or type(payload) ~= 'table' or payload.id == nil then return false end
    local key = M.KeyOf(payload.id)
    if type(payload.grounds) ~= 'table' then return false end
    local grounds = {}
    for index = 1, 8 do
        local value = payload.grounds[index]
        if value ~= nil then
            local z = finite(value)
            if z == nil or math.abs(z) > 100000.0 then return false end
            grounds[index] = z
        end
    end
    asks[key] = asks[key] or {}
    asks[key][player] = { player = player, grounds = grounds, x = finite(payload.x), y = finite(payload.y),
        z = finite(payload.z), why = type(payload.why) == 'string' and payload.why:sub(1, 60) or nil, at = M.Now() }
    counts.asked = counts.asked + 1
    return true
end

--- Whether an exit of this hull may still be set down on its gear (its
--- window is open, or it glides down now): a clip ask whose step is out of
--- reach waits for it.
-- @param id any the hull
-- @return boolean
function Land.Waiting(id)
    local key = M.KeyOf(id)
    return exits[key] ~= nil or glides[key] ~= nil
end

--- The glide under way for this hull, or nil: `{ endsAt, from, to, z }` --
--- an exit clip is not started on a hull still coming down.
-- @param id any the hull
-- @return table|nil
function Land.Gliding(id)
    local g = glides[M.KeyOf(id)]
    if g == nil then return nil end
    return { endsAt = g.endsAt, from = g.from, to = g.to, z = g.z, ms = g.ms }
end

--- How many are aboard and not leaving.
local function aboard(snapshot)
    local n = 0
    for _, occupant in ipairs(type(snapshot.occupants) == 'table' and snapshot.occupants or {}) do
        if type(occupant) == 'table' and occupant.exiting ~= true then n = n + 1 end
    end
    return n
end

-- A measure made this close to the server's hull is of the hull itself: what
-- it found under the gear will not change with another one.
local SAME_PLACE_METRES = 0.3
-- At most this many measures are judged for one exit.
local MAX_MEASURES = 3

--- Sets one hull on its gear -- in one move, or (1.7.9) a glide -- or says why not.
-- @return boolean whether it was set down (or its glide begun)
-- @return boolean whether that is final (false: a later measure of the same exit may still do it)
-- @return integer|nil how long until it stands on its gear, ms (0: at once)
function Land.Lower(key, exit, ask)
    local api = Open77.vehicles
    if type(api) ~= 'table' or type(api.get) ~= 'function' or type(api.setTransform) ~= 'function' then
        refuse(key, 'no Open77.vehicles.setTransform on this host')
        return false, true
    end
    local read, snapshot = pcall(api.get, exit.id)
    if not read or type(snapshot) ~= 'table' then
        refuse(key, 'the hull is gone')
        return false, true
    end
    -- HELD ON ITS GEAR FOR A BOARDING ALREADY (1.8.4): held for this one too.
    if holds[M.KeyOf(exit.id)] ~= nil and exit.what == 'boarding' then
        Land.Join(exit.id, exit.player)
        Open77.log.info(('aircraft %s is already held on its gear for a boarding: player %d asks too, and is asked again')
            :format(key, exit.player))
        return true, true, 0
    end
    -- SOMEBODY ABOARD (1.8.4): only for a boarding, and only a short way down
    -- (`BOARD.ABOARD_DROP_METRES`): the flight is the pilot's.
    local crew = aboard(snapshot)
    local board = M.BoardSettings()
    if crew > 0 and (exit.what ~= 'boarding' or board.aboardDrop <= 0) then
        refuse(key, ('%d aboard'):format(crew))
        return false, true
    end
    -- The platform's own read of the bit (`isFrozen`), else the snapshot's (server/watch.lua).
    local frozen = M.FrozenOf ~= nil and M.FrozenOf(snapshot, exit.id) or snapshot.frozen == true
    if frozen and holds[M.KeyOf(exit.id)] == nil then
        refuse(key, 'it is frozen (a resource poses it)')
        return false, true
    end
    local land = M.AirframeLand(snapshot.record or exit.record)
    if land == nil then
        refuse(key, 'not an airframe whose gear is known')
        return false, true
    end
    local x, y, hullZ = finite(snapshot.x), finite(snapshot.y), finite(snapshot.z)
    if x == nil or y == nil or hullZ == nil then
        refuse(key, 'the server has no position for it')
        return false, true
    end
    -- The measure is of the hull where it stands: one made a metre and a half
    -- away is of somewhere else -- and the game may send another.
    local off = (ask.x ~= nil and ask.y ~= nil) and math.sqrt((ask.x - x) ^ 2 + (ask.y - y) ^ 2) or nil
    if off ~= nil and off > 1.5 then
        refuse(key, ('the ground was measured %.1f m from where the server has it (%.1f, %.1f against %.1f, %.1f)%s')
            :format(off, ask.x, ask.y, x, y, (exit.measures or 1) < MAX_MEASURES
                and '; a measure made again is still taken' or ''))
        return false, false
    end
    local z, why = M.LandHeight(hullZ, ask.grounds, land)
    if z == nil then
        local text = tostring(why)
        local under = table.concat((function()
            local parts = {}
            for index = 1, #land.gear do
                parts[index] = ask.grounds[index] ~= nil and ('%.2f'):format(ask.grounds[index]) or 'none'
            end
            return parts
        end)(), ', ')
        -- ALREADY ON ITS GEAR: nothing to do, and nothing wrong.
        if text:find('^on_its_gear') ~= nil then
            counts.onGear = (counts.onGear or 0) + 1
            Open77.log.info(('aircraft %s already stands on its gear (%s m over it; hull at %.2f, the ground under its '
                .. 'gear %s), %s'):format(key, text:match(':(.*)$') or '0', hullZ, under, exit.what == 'boarding'
                    and ('player %d is boarding'):format(exit.player) or ('player %d stepped out'):format(exit.player)))
            return false, true
        end
        refuse(key, ('%s (hull at %.2f, the ground under its gear %s%s)'):format(text, hullZ, under,
            ask.why ~= nil and ('; the game said: ' .. ask.why) or ''))
        return false, off ~= nil and off <= SAME_PLACE_METRES
    end
    -- `yaw` is passed on purpose: the platform's `setTransform` reads an absent
    -- heading as 0, not as "keep the current one".
    local yaw = finite(snapshot.yaw or snapshot.heading) or 0.0
    local settings = M.ExitSettings()
    local glideMs = M.GlideMs(why.drop, settings)
    local now = M.Now()
    if crew > 0 then
        return Land.HoldDown(key, exit, snapshot, { x = x, y = y, z = z, yaw = yaw, from = hullZ, why = why,
            off = off, crew = crew, board = board, now = now })
    end
    local who = exit.what == 'boarding' and 'pressed the key at its door (a boarding)' or 'stepped out'
    local line = ('aircraft %s set down on its gear %.2f m lower (%.2f -> %.2f, the ground under its feet %.2f, '
        .. '%.2f m apart), %.1fs after player %d %s; heading %.0f; measured %s from the server\'s hull%s')
        :format(key, why.drop, hullZ, z, why.highest, why.spread, (now - exit.at) / 1000.0, exit.player, who, yaw,
            off ~= nil and ('%.2f m'):format(off) or 'at an unknown place',
            (exit.measures or 1) > 1 and (' (measure %d)'):format(exit.measures) or '')
    -- THE GLIDE (1.7.9): a long way down is flown, not dropped.
    if glideMs > 0 then
        if glides[key] ~= nil then
            Open77.log.info(('aircraft %s already glides down onto its gear (%.2f -> %.2f): left to it')
                :format(key, glides[key].from, glides[key].to))
            return true, true, math.max(0, glides[key].endsAt - now)
        end
        glides[key] = { id = exit.id, key = key, x = x, y = y, yaw = yaw, from = hullZ, to = z, began = now,
            ms = glideMs, endsAt = now + glideMs, poses = 0, z = hullZ, player = exit.player, what = exit.what,
            highest = why.highest }
        counts.lowered = counts.lowered + 1
        Open77.log.info(('%s -- glided down over %.1fs, a pose every %d ms, eased in and out'):format(line,
            glideMs / 1000.0, settings.glideTick))
        if glideJob == nil then
            glideJob = M.Every('land', settings.glideTick, function() Land.Glide() end)
        end
        return true, true, glideMs
    end
    local called, moved, reason = pcall(api.setTransform, exit.id, { x = x, y = y, z = z, yaw = yaw })
    if not called or moved ~= true then
        refuse(key, 'setTransform refused: ' .. tostring(called and (reason or moved) or moved))
        return false, true
    end
    counts.lowered = counts.lowered + 1
    Open77.log.info(line)
    return true, true, 0
end

-- ── a boarding behind a pilot (1.8.4) ───────────────────────────────────────

local function setFrozen(id, frozen)
    local api = Open77.vehicles
    if type(api) ~= 'table' or type(api.setFrozen) ~= 'function' then return false, 'no Open77.vehicles.setFrozen' end
    local called, ok, reason = pcall(api.setFrozen, id, frozen)
    if not called or ok == false then return false, tostring(called and reason or ok) end
    return true, nil
end

--- Sets a hull somebody is aboard down on its gear for a boarding: frozen,
--- one move, held until the boarding ends (`Land.Release`). Called by
--- `Land.Lower` with the height it worked out.
-- @return boolean set down
-- @return boolean final
-- @return integer ms until it stands on its gear (0)
function Land.HoldDown(key, exit, snapshot, p)
    local who = ('player %d is boarding it'):format(exit.player)
    local hk = M.KeyOf(exit.id)
    if holds[hk] ~= nil then
        Land.Join(exit.id, exit.player)
        Open77.log.info(('aircraft %s is already held on its gear for a boarding: %s too'):format(key, who))
        return true, true, 0
    end
    if p.why.drop > p.board.aboardDrop then
        refuse(key, ('%d aboard and it hangs %.2f m over its gear, past BOARD.ABOARD_DROP_METRES (%.1f): its pilot '
            .. 'holds it there, %s'):format(p.crew, p.why.drop, p.board.aboardDrop, who))
        return false, true
    end
    local frozen, failure = setFrozen(exit.id, true)
    if not frozen then
        refuse(key, ('%d aboard, and the freeze for the boarding was refused (%s)'):format(p.crew, tostring(failure)))
        return false, true
    end
    local api = Open77.vehicles
    local called, moved, reason = pcall(api.setTransform, exit.id, { x = p.x, y = p.y, z = p.z, yaw = p.yaw })
    if not called or moved ~= true then
        setFrozen(exit.id, false)
        refuse(key, ('%d aboard; setTransform refused (%s): the freeze is off again'):format(p.crew,
            tostring(called and (reason or moved) or moved)))
        return false, true
    end
    holds[hk] = { id = exit.id, key = hk, players = { [exit.player] = true }, since = p.now,
        untilAt = p.now + p.board.aboardHold, crew = p.crew, from = p.from, to = p.z }
    counts.lowered = counts.lowered + 1
    counts.held = (counts.held or 0) + 1
    Open77.log.info(('aircraft %s set down on its gear %.2f m lower for a boarding (%.2f -> %.2f, the ground under its '
        .. 'feet %.2f, %.2f m apart), %.1fs after player %d pressed the key at its door; heading %.0f; measured %s from '
        .. 'the server\'s hull -- %d aboard: ONE move, FROZEN and held on its gear until the boarding body is seated '
        .. '(%.0fs at most), then the pilot\'s flight has it again'):format(key, p.why.drop, p.from, p.z, p.why.highest,
        p.why.spread, (p.now - exit.at) / 1000.0, exit.player, p.yaw, p.off ~= nil and ('%.2f m'):format(p.off)
        or 'at an unknown place', p.crew, p.board.aboardHold / 1000.0))
    return true, true, 0
end

--- Whether a hull is held on its gear for a boarding now.
function Land.Holding(id)
    return id ~= nil and holds[M.KeyOf(id)] ~= nil
end

--- Another body boards a hull held on its gear: it is held for that one too.
-- @return boolean whether the hull is held
function Land.Join(id, player)
    local h = id ~= nil and holds[M.KeyOf(id)] or nil
    if h == nil then return false end
    if not h.players[player] then
        h.players[player] = true
        h.untilAt = math.max(h.untilAt, M.Now() + M.BoardSettings().aboardHold)
        Open77.log.info(('aircraft %s stays held on its gear for player %d\'s boarding too'):format(h.key, player))
    end
    return true
end

--- Lets go of a hull held for a boarding: once nobody boarding it is left
--- (`player` nil: everybody), the freeze comes off. One line.
-- @param id any the hull
-- @param player integer|nil the body whose boarding ended
-- @param why string
function Land.Release(id, player, why)
    local key = id ~= nil and M.KeyOf(id) or nil
    local h = key ~= nil and holds[key] or nil
    if h == nil then return false end
    if player ~= nil then
        if not h.players[player] then return false end
        h.players[player] = nil
        if next(h.players) ~= nil then
            Open77.log.info(('aircraft %s: player %d\'s boarding is over (%s); still held for another'):format(key,
                player, tostring(why)))
            return false
        end
    end
    holds[key] = nil
    local released, failure = setFrozen(h.id, false)
    Open77.log.info(('aircraft %s let go after %.1fs on its gear for a boarding (%s): %s'):format(key,
        (M.Now() - h.since) / 1000.0, tostring(why), released and 'the freeze is off -- the pilot\'s flight has it again'
        or ('the freeze could NOT be taken off: ' .. tostring(failure))))
    return true
end

--- Ends a glide: where it is (`why`), or on its gear (`why` nil). One line.
local function endGlide(g, now, why)
    glides[g.key] = nil
    local flown = (now - g.began) / 1000.0
    if why == nil then
        counts.glided = counts.glided + 1
        Open77.log.info(('aircraft %s stands on its gear at %.2f (the ground under its feet %.2f): glided %.2f m down '
            .. 'in %.1fs, %d pose(s), after player %d %s'):format(g.key, g.to, g.highest or (g.to - 1.0), g.from - g.to,
            flown, g.poses, g.player, g.what == 'boarding' and 'pressed the key at its door' or 'stepped out'))
        return
    end
    counts.glidesCut = counts.glidesCut + 1
    Open77.log.warn(('aircraft %s: the glide onto its gear ended %.2f m over it, %.1fs in (%d pose(s)): %s')
        :format(g.key, (g.z or g.from) - g.to, flown, g.poses, why))
end

--- One pose of one glide.
local function glideStep(g, now, api)
    local read, snapshot = pcall(api.get, g.id)
    if not read or type(snapshot) ~= 'table' then return endGlide(g, now, 'the hull is gone') end
    local n = aboard(snapshot)
    if n > 0 then return endGlide(g, now, ('%d aboard: the flight is theirs'):format(n)) end
    local frozen = M.FrozenOf ~= nil and M.FrozenOf(snapshot, g.id) or snapshot.frozen == true
    if frozen then return endGlide(g, now, 'it is frozen (a resource poses it)') end
    local x, y = finite(snapshot.x), finite(snapshot.y)
    if x ~= nil and y ~= nil then
        local across = math.sqrt((x - g.x) ^ 2 + (y - g.y) ^ 2)
        if across > GLIDE_MOVED_METRES then
            return endGlide(g, now, ('moved %.1f m across by something else (%.1f, %.1f)'):format(across, x, y))
        end
    end
    local elapsed = now - g.began
    local z = M.GlideZ(g.from, g.to, elapsed, g.ms)
    local called, moved, reason = pcall(api.setTransform, g.id, { x = g.x, y = g.y, z = z, yaw = g.yaw })
    if not called or moved ~= true then
        return endGlide(g, now, 'setTransform refused: ' .. tostring(called and (reason or moved) or moved))
    end
    g.poses, g.z = g.poses + 1, z
    counts.poses = counts.poses + 1
    if elapsed >= g.ms then endGlide(g, now, nil) end
end

--- Every `LAND_GLIDE_TICK_MS` while a glide is under way: one pose of each;
--- the job ends with the last glide.
function Land.Glide(now)
    now = now or M.Now()
    local api = Open77.vehicles
    local list = {}
    for _, g in pairs(glides) do list[#list + 1] = g end
    for _, g in ipairs(list) do
        if type(api) ~= 'table' or type(api.get) ~= 'function' or type(api.setTransform) ~= 'function' then
            endGlide(g, now, 'no Open77.vehicles.setTransform on this host')
        else
            local ran, failure = pcall(glideStep, g, now, api)
            if not ran then
                glides[g.key] = nil
                Open77.log.error(('aircraft %s: a pose of the glide onto its gear failed: %s'):format(g.key,
                    tostring(failure)))
            end
        end
    end
    if next(glides) == nil and glideJob ~= nil then
        M.Cancel(glideJob)
        glideJob = nil
    end
end

--- Every tenth of a second (the tending job): exits whose measure came in and
--- whose delay is over are lowered; the others wait, up to the window. A
--- measure the server could not use because it was made elsewhere leaves the
--- exit open for another one (`MAX_MEASURES`): the game measures again before
--- the exit clip when its hull still hangs over its gear (client/walkout.lua).
function Land.Tend()
    local exit = M.ExitSettings()
    local now = M.Now()
    -- A hold past `BOARD.ABOARD_HOLD_MS` is let go, whatever its boarding does.
    for key, h in pairs(holds) do
        if now >= h.untilAt then Land.Release(h.id, nil, ('held %.0fs, the most a boarding may'):format(
            (now - h.since) / 1000.0)) end
    end
    for key, entry in pairs(exits) do
        local ask = asks[key] and asks[key][entry.player] or nil
        if now - entry.at > exit.landWindow then
            exits[key] = nil
            if ask == nil and not entry.judged then
                refuse(key, ('the game of player %d sent no measure of the ground under it within %.1fs')
                    :format(entry.player, exit.landWindow / 1000.0))
            end
        elseif ask ~= nil and now - entry.at >= exit.landDelay then
            asks[key][entry.player] = nil
            if next(asks[key]) == nil then asks[key] = nil end
            entry.measures = (entry.measures or 0) + 1
            entry.judged = true
            if ask.at < entry.at - exit.landWindow then
                exits[key] = nil
                refuse(key, 'the measure is older than the exit')
            else
                local ran, done, final = pcall(Land.Lower, key, entry, ask)
                if not ran then
                    exits[key] = nil
                    Open77.log.error('setting a hull on its gear failed: ' .. tostring(done))
                elseif done or final or entry.measures >= MAX_MEASURES then
                    exits[key] = nil
                end
            end
        end
    end
    -- Measures no exit came for (the server never saw one, or somebody who did
    -- not step out sent one): dropped after the window.
    for key, byPlayer in pairs(asks) do
        for player, ask in pairs(byPlayer) do
            if (exits[key] == nil or exits[key].player ~= player) and now - ask.at > exit.landWindow then
                byPlayer[player] = nil
            end
        end
        if next(byPlayer) == nil then asks[key] = nil end
    end
end

function Land.Forget(playerId)
    local player = tonumber(playerId)
    if player == nil then return end
    for key, byPlayer in pairs(asks) do
        byPlayer[player] = nil
        if next(byPlayer) == nil then asks[key] = nil end
    end
end

function Land.Status()
    local waiting, gliding = 0, 0
    for _ in pairs(exits) do waiting = waiting + 1 end
    for _ in pairs(glides) do gliding = gliding + 1 end
    local held = 0
    for _ in pairs(holds) do held = held + 1 end
    return { exits = counts.exits, asked = counts.asked, lowered = counts.lowered, refused = counts.refused,
        onGear = counts.onGear or 0, waiting = waiting, gliding = gliding, glided = counts.glided,
        glidesCut = counts.glidesCut, poses = counts.poses, held = held, holds = counts.held or 0 }
end

function Land.Start()
    RegisterNetEvent(M.Event.LAND, function(payload)
        local player = tonumber(source)
        if player == nil then return end
        if M.Cooling(player, 'land', 250) then return end
        local ran, kept = pcall(Land.Ask, player, payload)
        if not ran then Open77.log.error('a measure of the ground under a hull failed: ' .. tostring(kept)) end
    end)
end

function Land.Stop()
    for _, g in pairs(glides) do
        Open77.log.info(('aircraft %s: the glide onto its gear stopped with the resource, %.2f m over it')
            :format(g.key, (g.z or g.from) - g.to))
    end
    for _, h in pairs(holds) do
        local released = setFrozen(h.id, false)
        Open77.log.info(('aircraft %s: let go with the resource (%s)'):format(h.key,
            released and 'the freeze is off' or 'the freeze could not be taken off'))
    end
    exits, asks, glides, holds = {}, {}, {}, {}
    if glideJob ~= nil then
        M.Cancel(glideJob)
        glideJob = nil
    end
end
