-- Run from the repository root with Lua 5.4. Exercise the real client policy
-- and server event handlers, including held-button/menu/release transitions.
local handlers, exported, threads = {}, {}, {}
local down, captured, changes, transmissions = {}, false, {}, {}
function AddEventHandler(name, fn) handlers[name] = fn end
RegisterNetEvent = AddEventHandler
function GetCurrentResourceName() return 'open77_voice' end
function exports(name, fn) exported[name] = fn end
function CreateThread(fn) threads[#threads+1] = coroutine.create(fn) end
function Wait() coroutine.yield() end
function TriggerEvent(name, key) changes[#changes+1] = {name, key} end
function TriggerServerEvent() return true end
Open77 = {
    input = { isCaptured = function() return captured end,
        isDown = function(key) return down[key] == true end },
    voice = {
        setTransmitting = function(value, intent)
            assert(intent == 'all')
            transmissions[#transmissions+1] = value
            return true
        end,
        setLipSyncEnabled = function() return true end,
        setMicrophoneTest = function() return true end,
    },
    nameplates = { setTalking = function() end },
}
dofile('resources/system/open77_voice/shared/config.lua')
dofile('resources/system/open77_voice/client/main.lua')
handlers.onClientResourceStart('open77_voice')
assert(#threads == 2, 'PTT and talker threads did not start')
local function tick() assert(coroutine.resume(threads[1])) end
tick()
for button = 1,5 do
    local key = 'MOUSE'..button
    assert(exported.setPushToTalkKey(' mouse'..button..' '))
    assert(exported.getPushToTalkKey() == key)
    assert(changes[#changes][2] == key)
    captured, down[key] = true, true
    local count = #transmissions
    tick()
    assert(#transmissions == count, 'capture click transmitted audio')
    captured = false
    tick()
    assert(transmissions[#transmissions] == true, 'mouse press failed to transmit')
    count = #transmissions
    tick()
    assert(#transmissions == count, 'held button emitted duplicate intent')
    captured = true
    tick()
    assert(transmissions[#transmissions] == false, 'menu did not stop transmission')
    captured = false
    tick()
    assert(transmissions[#transmissions] == true)
    down[key] = false
    tick()
    assert(transmissions[#transmissions] == false, 'release left transmission active')
end
for _, key in ipairs({'MOUSE0','MOUSE6','MOUSEWHEELUP','MOUSEX',''}) do
    local ok, reason = exported.setPushToTalkKey(key)
    assert(not ok and reason == 'unsupported_push_to_talk_key')
end
down.MOUSE5 = true
tick()
assert(transmissions[#transmissions] == true)
handlers['open77:voice:pushToTalkKeyApplied']('MOUSE4')
assert(exported.getPushToTalkKey() == 'MOUSE4' and transmissions[#transmissions] == false,
    'server key update did not release old held binding')
down.MOUSE5 = false
print('Voice client: five mouse buttons, held edges, menu capture, release and server update passed')

handlers = {}
local sent, now = {}, 0
Open77.time = { monotonic = function() now = now + 1; return now end }
function TriggerClientEvent(event, player, key) sent[#sent+1] = {event, player, key}; return true end
dofile('resources/system/open77_voice/server/main.lua')
source = 42
for button = 1,5 do
    handlers['open77:voice:setPushToTalkKey']('mouse'..button)
    assert(sent[#sent][2] == 42 and sent[#sent][3] == 'MOUSE'..button,
        'server rejected mouse binding')
    handlers['open77:voice:requestPushToTalkKey']()
    assert(sent[#sent][3] == 'MOUSE'..button, 'server sync lost mouse binding')
end
local count = #sent
for _, key in ipairs({'MOUSE0','MOUSE6','MOUSEWHEELUP','MOUSEX',''}) do
    handlers['open77:voice:setPushToTalkKey'](key)
end
assert(#sent == count, 'server accepted invalid mouse binding')
handlers.playerDropped()
handlers['open77:voice:requestPushToTalkKey']()
assert(sent[#sent][3] == 'N', 'departed player retained a stale binding')
print('Voice server: five mouse buttons, resync, invalid values and disconnect cleanup passed')
