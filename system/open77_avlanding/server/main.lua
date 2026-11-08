-- =============================================================================
-- open77_avlanding -- server/main.lua
-- =============================================================================
-- The one thing the server does for a sign every game draws by itself:
-- `avlanding.test`, typed in chat. A server's chat (XyberRP's among them)
-- hands a /command to the SERVER, which answers "no such command" for one a
-- client registered for itself; so the test is a server command, and the
-- caller's game lays the word in front of them (client/main.lua, `L.Test`).
-- Anybody may ask: it shows the sign to the asker only, in their own game,
-- for `TEST_SECONDS`, at most once every `TEST_COOLDOWN_MS`.
-- =============================================================================

local cfg = Open77AvLandingConfig or {}
local EVENT = 'open77_avlanding:test'
local COMMAND = 'avlanding.test'

-- When each player last asked, by id.
local asked = {}

local function now()
    local time = Open77.time
    if type(time) == 'table' and type(time.monotonic) == 'function' then
        local read, seconds = pcall(time.monotonic)
        if read and type(seconds) == 'number' then return math.floor(seconds * 1000.0) end
    end
    return math.floor(os.clock() * 1000.0)
end

local function cooldown()
    local ms = tonumber(cfg.TEST_COOLDOWN_MS)
    if ms == nil or ms < 0 or ms > 600000 then return 3000 end
    return math.floor(ms)
end

--- The answer in the asker's console or chat (the platform's command result), and in the server log.
local function answer(id, raw, ok, text)
    if ok then Open77.log.info(text) else Open77.log.warn(text) end
    if id ~= nil then
        pcall(TriggerClientEvent, 'open77:command:result', id, raw or COMMAND, ok == true, text)
    end
end

RegisterCommand(COMMAND, function(source, _, raw)
    local id = math.tointeger(tonumber(source))
    if id == nil or id <= 0 then
        answer(nil, raw, false, 'avlanding.test needs a player: type it in chat in game, the sign is laid in that game')
        return
    end
    local t = now()
    if asked[id] ~= nil and t - asked[id] < cooldown() then
        answer(id, raw, false, ('avlanding.test for player %d: asked again within %d ms, not sent'):format(id, cooldown()))
        return
    end
    asked[id] = t
    local sent, failure = pcall(TriggerClientEvent, EVENT, id, { at = t })
    if not sent then
        answer(id, raw, false, ('avlanding.test for player %d: their game could not be told: %s'):format(id, tostring(failure)))
        return
    end
    answer(id, raw, true, ('avlanding.test for player %d: their game lays the sign on the ground in front of them '
        .. '(its client log says where, or why not)'):format(id))
end, false)

AddEventHandler('onPlayerDisconnected', function(playerId)
    local id = math.tointeger(tonumber(playerId))
    if id ~= nil then asked[id] = nil end
end)

Open77.log.info(('ready: /%s shows the landing sign in front of whoever types it'):format(COMMAND))
