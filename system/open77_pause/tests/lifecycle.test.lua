-- Execute the shipped controller; only browser/native IO and timers are adapted.
local root = assert(arg[1])
local handlers, pageEvents, messages, timers = {}, {}, {}, {}
local visible, focused, ready, focusAllowed = true, false, false, true
local cursorCaptured = false
local page = {}
function page:send(name, payload) messages[name] = payload; return true end
function page:on(name, callback) pageEvents[name] = callback end
function page:show() visible = true; return true end
function page:hide() visible, focused = false, false; return true end
function page:setConsumedKeys() end
function page:setFocus(keyboard, cursor)
    if keyboard or cursor then
        assert(visible, "show the surface before acquiring input")
        if not focusAllowed then return false end
    end
    focused = keyboard or cursor
    return true
end
function AddEventHandler(name, callback) handlers[name] = callback end
function GetCurrentResourceName() return "open77_pause" end
local published = {}
function TriggerEvent(name, payload) published[#published + 1] = {name = name, payload = payload} end
function CreateThread() end -- periodic voice/state polling is outside this fixture
local exported = {}
function exports(name, fn) exported[name] = fn end -- voice service contract: voice setup tests
function SetTimeout(_, callback) timers[#timers + 1] = callback end
local function expireTimers()
    local pending = timers; timers = {}
    for _, callback in ipairs(pending) do callback() end
end
WebUI = {create = function() return page end}
Open77 = {
    session = {launcherContext = function() return {} end,
        setMenuReady = function(value) ready = value end},
    network = {status = function() return {phase = "active", playerName = "test"} end},
    runtime = {version = function() return "test" end},
    pauseMenu = {getAppearance = function() return nil end},
    input = {isCaptured = function() return focused, cursorCaptured end},
    voice = {setMicrophoneTest = function() end},
    map = {open = function() return nil, "unavailable" end},
}
dofile(root .. "/shared/strings.lua")
dofile(root .. "/client/voice_setup.lua")
dofile(root .. "/client/main.lua")
handlers.onClientResourceStart("open77_pause")
pageEvents["pause:ready"]()
assert(ready and not visible and not focused, "closed document must be suspended")
cursorCaptured = true
handlers["open77:pauseKey"]()
assert(not visible and not focused, "another UI's cursor capture must block opening pause")
cursorCaptured = false
local function openMenu()
    handlers["open77:pauseKey"]()
    assert(visible and focused)
    return messages["pause:open"].generation
end
local first = openMenu()
handlers["open77:pauseKey"]()
local closing = messages["pause:close"].generation
assert(visible and focused, "retain the ordinary closing animation")
-- Focus can be released independently while a browser close acknowledgement
-- is still in flight (native focus ownership/recovery).
page:setFocus(false, false)
local reopened = openMenu()
assert(reopened > first)
expireTimers()
pageEvents["pause:closed"]({generation = closing})
assert(visible and focused, "stale timers/acks must not hide a reopened menu")
pageEvents["pause:closed"]({generation = reopened})
assert(not visible and not focused, "browser close suspends rendering and releases input")
openMenu()
handlers["open77:pauseKey"]()
expireTimers()
assert(not visible and not focused, "missing browser ack still closes after transition")
openMenu()
handlers["open77:worldReady"]()
assert(not visible and not focused, "world transitions close immediately")
openMenu()
pageEvents["pause:action"]({action = "map"})
assert(visible and focused, "a refused native map restores the menu")
-- a resource's own city map replaces the game's
assert(published[1].name == "open77:mapProvider:query", "providers are asked to announce themselves")
local nativeOpened = 0
Open77.map.open = function() nativeOpened = nativeOpened + 1; return "ticket-" .. nativeOpened end
handlers["open77:mapProvider:register"]({resource = "low_map", priority = 1})
handlers["open77:mapProvider:register"]({resource = "op77_map3d", label = "City map (3D)", priority = 100})
assert(exported.mapProvider().resource == "op77_map3d")
openMenu()
pageEvents["pause:action"]({action = "map"})
local show = published[#published]
assert(show.name == "open77:mapProvider:show" and show.payload.provider == "op77_map3d" and nativeOpened == 0, "CITY MAP asks the provider")
assert(not focused, "the menu steps aside for the provider's map")
handlers["open77:mapProvider:shown"]({requestId = show.payload.requestId})
expireTimers()
assert(nativeOpened == 0, "an answering provider keeps the game's map closed")
-- a provider that does not answer: the game's map after the delay
openMenu()
pageEvents["pause:action"]({action = "map"})
expireTimers()
assert(nativeOpened == 1, "a silent provider falls back to the game's map")
-- a stopped provider is withdrawn; the next one takes over, then none
handlers.onClientResourceStop("op77_map3d")
assert(exported.mapProvider().resource == "low_map")
handlers["open77:mapProvider:withdraw"]({resource = "low_map"})
assert(exported.mapProvider() == nil)
openMenu()
pageEvents["pause:action"]({action = "map"})
assert(nativeOpened == 2, "no provider: the game's map")
pageEvents["webui:host-lost"]()
assert(not visible and not focused and not ready)
pageEvents["pause:ready"]()
assert(ready and not visible and not focused, "replacement page starts closed")
focusAllowed = false
handlers["open77:pauseKey"]()
assert(not visible and not focused, "failed input acquisition must not leave a visible modal")
focusAllowed = true
openMenu()
handlers.onClientResourceStop("open77_pause")
assert(not ready)
print("Pause lifecycle: suspend/reveal, close/reopen races, focus failure, world/map, map providers and host recovery passed")
