-- =============================================================================
-- open77_avdoor -- server/callout.lua
-- =============================================================================
-- The landing call: a voice on the aircraft's loudspeaker while it comes down.
--
-- "Warning. Clear the area. MaxTac landing." -- or "... Trauma Team landing."
-- -- said over and over from where the hull is, on top of the airframe's own
-- sounds, until it is down (`CALLOUTS` in shared/config.lua).
--
-- WHO STARTS AND ENDS A CALL. Two callers, one call per hull:
--   * a player-flown AV: the pilot's client reports the descent, the
--     touchdown, a take-off or a landing called off (`abort`), and `M.Called`
--     in server/main.lua checks the asker is seated in that hull before it
--     reaches `Start` or `Stop` here;
--   * an AV a resource flies itself, through `exports.open77_avdoor:callout`,
--     `:follow` and `:hush`: from its approach until it is down.
--
-- IN EACH PLAYER'S OWN LANGUAGE. One network sound would be one language for
-- the whole bucket, and players asked for "the voice locales with french german
-- spanish etc". So the server keeps the call -- who is calling, from where,
-- since when, ended or not -- and TELLS every player in the hull's bucket
-- within `MAX_METRES` (`M.Event.CALL`), and anybody who comes near on a later
-- pass with the point the loop has reached; each game plays the line itself in
-- its own voice-over language (`client/callout.lua`) from where it draws the
-- hull. Ending a call tells the same games to fade it out, or to cut it.
--
-- THE VOICE STOPS WHEN THE AV IS DOWN. It used to finish the sentence it was
-- saying, which is up to a whole clip (4.5 s) after the touchdown ("it doesnt
-- stop when av lands"). So it fades out over `FADE_MS` from the moment the hull
-- is down, wherever the sentence is. A call is KILLED at once when there is
-- nothing left to say it from: the hull is gone, `MAX_SECONDS` passed, the
-- resource that started it stopped, or this one did.
-- =============================================================================

local M = AvDoor

M.Callout = {}
local Callout = M.Callout

-- How many hulls may call at once.
local MAX_LIVE = 6

-- Live calls, by hull id as text: `{ id, key, kind, seconds, volume,
-- startedAt, untilMs, fadeFrom, finishAt, bucket, at, why, owned, owner, told,
-- toldAt, ended }`. `owned` is a call whose caller moves it (`Follow`) rather
-- than `Tend`. `fadeFrom` and `finishAt` are set while an ended call fades out.
local live = {}

-- Reasons already said once.
local said = {}

local function settings()
    local block = type(M.Settings) == 'table' and M.Settings.CALLOUTS or nil
    return type(block) == 'table' and block or nil
end

--- How often the games near a call are looked at again, in ms.
local function tellMs(block)
    return math.floor(M.Number(block and block.TELL_MS, 250, 10000, 1000))
end

local function sayOnce(key, line)
    if said[key] then return end
    said[key] = true
    Open77.log.warn(line)
end

--- Where a hull is and its bucket, as the host reads it, or nil when it is gone.
-- @param id any the id as the host knows it
-- @return table|nil `{ x, y, z }`
-- @return number bucket
-- @return string|nil record
local function hullAt(id)
    local api = type(Open77) == 'table' and Open77.vehicles or nil
    if type(api) ~= 'table' or type(api.get) ~= 'function' or id == nil then return nil, 0 end
    local read, snapshot = pcall(api.get, id)
    if (not read or type(snapshot) ~= 'table') and tonumber(id) ~= nil then
        read, snapshot = pcall(api.get, tonumber(id))
    end
    if not read or type(snapshot) ~= 'table' then return nil, 0 end
    local at = type(snapshot.position) == 'table' and snapshot.position or snapshot
    local x, y, z = tonumber(at.x), tonumber(at.y), tonumber(at.z)
    if x == nil or y == nil or z == nil or x ~= x or y ~= y or z ~= z then return nil, 0 end
    return { x = x, y = y, z = z }, tonumber(snapshot.bucket) or 0, snapshot.record
end

--- How long an ended call fades out, in milliseconds: `FADE_MS`, 0 to 2000.
local function fadeMs(block)
    local fade = tonumber(block and block.FADE_MS)
    if fade == nil or fade ~= fade then return 400 end
    return math.floor(math.max(0, math.min(2000, fade)))
end

--- The distances a call is heard over: full volume to `near`, nothing past `far`.
local function band(block)
    local near = M.Number(block.MIN_METRES, 0.5, 900.0, 30.0)
    local far = M.Number(block.MAX_METRES, 1.0, 1000.0, 300.0)
    if far <= near then far = math.min(1000.0, near + 1.0) end
    return near, far
end

--- What one game is sent to play a call, the loop's point included.
local function callPayload(call, block)
    local near, far = band(block)
    return {
        id = call.key, kind = call.kind, on = true,
        at = { x = call.at.x, y = call.at.y, z = call.at.z },
        elapsedMs = math.max(0, M.Now() - call.startedAt),
        volume = call.volume, near = near, far = far,
    }
end

local function sendCall(playerId, payload)
    return pcall(TriggerClientEvent, M.Event.CALL, playerId, payload)
end

--- Tells the games in a call's bucket within MAX_METRES that have not been
--- told yet; with `refresh`, the ones already told hear where it is now.
-- @return integer how many were sent anything
local function tellCall(call, block, refresh)
    local players = type(Open77) == 'table' and Open77.players or nil
    if type(players) ~= 'table' or type(players.all) ~= 'function' or type(players.position) ~= 'function' then
        return 0
    end
    local _, far = band(block)
    local listed, list = pcall(players.all)
    local sent, payload = 0, nil
    for _, playerId in ipairs(listed and type(list) == 'table' and list or {}) do
        local id = tonumber(playerId)
        -- The host's player reads throw on an id under 1: checked before any read.
        if id ~= nil and id >= 1 and id == math.floor(id) and (refresh or not call.told[id]) then
            local read, where = pcall(players.position, id)
            local x = read and type(where) == 'table' and tonumber(where.x) or nil
            local y = read and type(where) == 'table' and tonumber(where.y) or nil
            if x ~= nil and y ~= nil and (tonumber(where.bucket) or 0) == call.bucket then
                local dx, dy = x - call.at.x, y - call.at.y
                -- A game already told is told again even out of range: it keeps a
                -- sound whose fading out with distance is its own.
                if call.told[id] or dx * dx + dy * dy <= far * far then
                    payload = payload or callPayload(call, block)
                    if sendCall(id, payload) then
                        call.told[id] = true
                        sent = sent + 1
                    end
                end
            end
        end
    end
    return sent
end

--- Tells every game a call was sent to that it is over.
local function endCall(call, fade)
    if call.ended then return 0 end
    call.ended = true
    local count = 0
    for playerId in pairs(call.told) do
        if sendCall(playerId, { id = call.key, on = false, fadeMs = fade }) then count = count + 1 end
    end
    return count
end

--- Ends a call at once, on every game, and forgets it.
-- @param id any the hull
-- @param why string for the journal
-- @return boolean whether the hull was calling
function Callout.Kill(id, why)
    if id == nil then return false end
    local key = M.KeyOf(id)
    local call = live[key]
    if call == nil then return false end
    live[key] = nil
    local games = endCall(call, 0)
    Open77.log.info(('landing call of %s (%s) ended: %s, after %.1fs, %d game(s) told')
        :format(key, call.kind, tostring(why), (M.Now() - call.startedAt) / 1000.0, games))
    return true
end

--- Starts the landing call on a hull, or keeps the one it already has going.
-- @param id any the hull, as the host knows it
-- @param kind string|nil a `CALLOUTS.KINDS` name; nil for the one its record makes
-- @param why string|nil for the journal
-- @param from table|nil `{ x, y, z, bucket }`: where a hull the CALLER flies is
--   right now. Given, the caller moves the call (`Follow`); absent, `Tend` does.
-- @param owner string|nil the resource that asked, so its stop ends the call
-- @return boolean|nil true when the hull is calling
-- @return string|nil why not, or 'already'
function Callout.Start(id, kind, why, from, owner)
    local block = settings()
    if block == nil then return nil, 'callouts_off' end
    if id == nil then return nil, 'no_hull' end
    local key = M.KeyOf(id)
    local now = M.Now()
    local cap = math.floor(M.Number(block.MAX_SECONDS, 5, 3600, 90) * 1000)

    -- A DESCENT ON A HULL ALREADY CALLING is the same landing: the call goes on,
    -- a fade it had begun is taken back at full volume, and its clock is the new
    -- report's.
    local call = live[key]
    if call ~= nil then
        if call.finishAt ~= nil then
            -- A fade the games began is taken back by telling them again.
            call.fadeFrom, call.finishAt, call.ended = nil, nil, false
            tellCall(call, block, true)
        end
        call.untilMs = now + cap
        return true, 'already'
    end

    local at, bucket, record = hullAt(id)
    local owned = type(from) == 'table' and tonumber(from.x) ~= nil and tonumber(from.y) ~= nil
        and tonumber(from.z) ~= nil
    if owned then
        at = { x = tonumber(from.x), y = tonumber(from.y), z = tonumber(from.z) }
        bucket = tonumber(from.bucket) or bucket or 0
    end
    if at == nil then return nil, 'no_hull' end
    local kinds = type(block.KINDS) == 'table' and block.KINDS or {}
    local spec
    if kind ~= nil then
        spec = kinds[kind]
    else
        kind, spec = M.CalloutKind(record, block)
    end
    if type(spec) ~= 'table' or type(spec.ASSET) ~= 'string' or spec.ASSET == '' then
        return nil, 'no_call_for_this_hull'
    end

    local count = 0
    for _ in pairs(live) do count = count + 1 end
    if count >= MAX_LIVE then
        sayOnce('full', ('%d landing calls are already up: %s lands without one')
            :format(count, key))
        return nil, 'too_many_calls'
    end

    call = {
        id = id, key = key, kind = kind, told = {},
        seconds = M.Number(spec.SECONDS, 0.1, 600.0, 4.0),
        volume = M.Number(block.VOLUME, 0.0, 1.0, 1.0),
        startedAt = now, untilMs = now + cap, fadeFrom = nil, finishAt = nil,
        bucket = bucket, at = at, why = why, owned = owned, owner = owner, toldAt = now,
    }
    live[key] = call
    local told = tellCall(call, block, false)
    local _, far = band(block)
    Open77.log.info(('landing call of %s (%s) on the loudspeaker%s%s: %d game(s) within %.0f m in '
        .. 'bucket %d play it in their own language'):format(key, kind, why and (' for ' .. tostring(why)) or '',
        owner and (' asked by ' .. tostring(owner)) or '', told, far, bucket))
    return true
end

--- Ends a hull's call now: it fades out over `FADE_MS` and is released.
-- @param id any
-- @param why string|nil for the journal
-- @return boolean whether a call was ending
function Callout.Stop(id, why)
    if id == nil then return false end
    local key = M.KeyOf(id)
    local call = live[key]
    if call == nil then return false end
    if call.finishAt ~= nil then return true end
    local now = M.Now()
    local fade = fadeMs(settings())
    call.why = why or call.why
    Open77.log.info(('landing call of %s (%s): %s, fading out over %.1fs')
        :format(key, call.kind, tostring(why), fade / 1000.0))
    if fade <= 0 then
        Callout.Kill(key, call.why)
        return true
    end
    call.fadeFrom, call.finishAt = now, now + fade
    endCall(call, fade)
    return true
end

--- Moves a call to where its caller just put the hull (a call started with a
--- position, `Start`'s `from`). Nothing moves for under a quarter of a metre.
--- Each game moves the sound on the hull it draws; the server keeps the point
--- for the games it tells next.
-- @param id any
-- @param at table `{ x, y, z }`
-- @return boolean whether the point was moved
function Callout.Follow(id, at)
    local call = id ~= nil and live[M.KeyOf(id)] or nil
    if call == nil or type(at) ~= 'table' then return false end
    local x, y, z = tonumber(at.x), tonumber(at.y), tonumber(at.z)
    if x == nil or y == nil or z == nil or x ~= x or y ~= y or z ~= z then return false end
    local dx, dy, dz = x - call.at.x, y - call.at.y, z - call.at.z
    if dx * dx + dy * dy + dz * dz <= 0.0625 then return false end
    call.at = { x = x, y = y, z = z }
    return true
end

--- Whether a hull is calling now.
function Callout.IsLive(id)
    return id ~= nil and live[M.KeyOf(id)] ~= nil
end

--- One pass: every call follows its hull, newcomers near it are told, and a
--- call that finished, ran out or lost its hull is released.
function Callout.Tend()
    local now = M.Now()
    local block = settings()
    local keys = {}
    for key in pairs(live) do keys[#keys + 1] = key end
    for _, key in ipairs(keys) do
        local call = live[key]
        if call == nil then
            -- Killed by an earlier step of this pass.
        elseif call.finishAt ~= nil then
            -- The games fade it themselves; the server lets it go when they are done.
            if now >= call.finishAt then
                live[key] = nil
                Open77.log.info(('landing call of %s (%s) ended: %s, after %.1fs')
                    :format(key, call.kind, tostring(call.why or 'down'), (now - call.startedAt) / 1000.0))
            end
        elseif now >= call.untilMs then
            Callout.Kill(key, 'no touchdown in MAX_SECONDS')
        else
            if not call.owned then
                local at = hullAt(call.id)
                if at == nil then
                    Callout.Kill(key, 'the hull is gone')
                else
                    call.at = at
                end
            end
            if live[key] ~= nil and block ~= nil and now - (call.toldAt or 0) >= tellMs(block) then
                -- Newcomers near the hull, and where it is now for the games
                -- that do not draw it.
                call.toldAt = now
                tellCall(call, block, true)
            end
        end
    end
end

--- A player who left is nobody to tell anything.
function Callout.Forget(playerId)
    local id = tonumber(playerId)
    if id == nil then return end
    for _, call in pairs(live) do
        if call.told ~= nil then call.told[id] = nil end
    end
end

--- Ends every call a resource started, when that resource stops.
-- @param owner string the resource
-- @return integer how many were ended
function Callout.KillOwnedBy(owner, why)
    if type(owner) ~= 'string' then return 0 end
    local keys = {}
    for key, call in pairs(live) do
        if call.owner == owner then keys[#keys + 1] = key end
    end
    for _, key in ipairs(keys) do Callout.Kill(key, why) end
    return #keys
end

--- Ends every call at once: the resource is stopping.
function Callout.KillAll(why)
    local keys = {}
    for key in pairs(live) do keys[#keys + 1] = key end
    for _, key in ipairs(keys) do Callout.Kill(key, why) end
end

--- What the calls are, for the suite and the console.
-- @return table[] `{ id, kind, told, ending, seconds, owner }`
function Callout.Status()
    local out = {}
    local now = M.Now()
    for key, call in pairs(live) do
        local told = 0
        for _ in pairs(call.told) do told = told + 1 end
        out[#out + 1] = { id = key, kind = call.kind, told = told, ending = call.finishAt ~= nil,
            seconds = (now - call.startedAt) / 1000.0, owner = call.owner, owned = call.owned == true }
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

--- Forgets everything, without telling anybody: a restart starts clean.
function Callout.Reset()
    live, said = {}, {}
end
