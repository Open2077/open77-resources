-- Run from repository root with Lua 5.4. Tests the actual resource lifecycle.
local handlers, callbacks, published, exported = {}, {}, {}, {}
local focusAllowed, focused = true, false
function RegisterNetEvent(name, fn) handlers[name] = fn end
AddEventHandler = RegisterNetEvent
function exports(name, fn) exported[name] = fn end
function GetCurrentResourceName() return 'open77_chat' end
function TriggerEvent() end
function TriggerServerEvent() return true end
function SetTimeout() end
Open77 = {
    time = {monotonic = function() return 1 end},
    -- Serialization is stubbed; the resource's ordering, count and byte budget
    -- are tested using variable-length serialized strings.
    json = {encode = function(m) return m.text end, decode = function(s) return {text=s} end},
}
WebUI = {create = function() return {
    on = function(_, name, fn) callbacks[name] = fn end,
    send = function(_, name, value) published[#published+1] = {name=name, value=value} end,
    setFocus = function(_, keyboard) focused = keyboard and focusAllowed; return not keyboard or focusAllowed end,
} end}
dofile('resources/system/open77_chat/client/main.lua')
handlers.onClientResourceStart('open77_chat')
callbacks['chat:ready']()
for i=1,60 do handlers['chat:addMessage']({text='message '..i}) end
handlers['chat:open']()
assert(focused)
callbacks['webui:host-lost']()
assert(not focused, 'host loss must close the composer')
published = {}
callbacks['chat:ready']()
local messages = {}
for _, event in ipairs(published) do
    if event.name == 'chat:addMessage' then messages[#messages+1] = event.value.text end
end
assert(#messages == 48 and messages[1] == 'message 13' and messages[48] == 'message 60',
    'replacement document must receive bounded history in order without another welcome')
focusAllowed = false
handlers['chat:open']()
focusAllowed = true
handlers['chat:open']()
assert(focused, 'a refused focus must not latch the composer open')
exported.clear()
handlers['chat:addMessage']({text=string.rep('x', 140000)})
handlers['chat:addMessage']({text=string.rep('y', 140000)})
published = {}
callbacks['chat:ready']()
messages = {}
for _, event in ipairs(published) do
    if event.name == 'chat:addMessage' then messages[#messages+1] = event.value.text end
end
assert(#messages == 1 and messages[1]:sub(1,1) == 'y', 'history must also respect the byte budget')
handlers['chat:clear']()
published = {}
callbacks['chat:ready']()
for _, event in ipairs(published) do assert(event.name ~= 'chat:addMessage', 'clear must survive recovery') end
print('Chat crash recovery, focus refusal, ordered history, count/byte limits and clear passed')
