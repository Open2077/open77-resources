local handlers, callbacks, sent, replies, threads, timers = {}, {}, {}, {}, {}, {}
local status = { phase = "offline", error = "" }
local bootstrap = { phase = "waiting" }
local now, connects, quits, refreshes = 0, 0, 0, 0
local logs = {}
local loading = { active = false, id = "1", revision = 1 }
local launcherOk, connectOk = false, true
local storedMusic
local visible, hides = false, 0
local page = {
    hide = function() visible = false; hides = hides + 1 end,
    show = function() visible = true end,
    setFocus = function() end
}
function page:on(name, callback) callbacks[name] = callback end
function page:send(name, payload) sent[#sent + 1] = { name = name, payload = payload } end
function page:reply(request, payload) replies[request] = payload end
function AddEventHandler(name, callback) handlers[name] = callback end
function TriggerEvent(name, ...) if handlers[name] then handlers[name](...) end end
function GetCurrentResourceName() return "open77_shell" end
function SetTimeout(delay, callback) timers[#timers + 1] = { at = now + delay, callback = callback } end
function Wait() coroutine.yield() end
function CreateThread(fn) threads[#threads + 1] = coroutine.create(fn) end
local function step()
    local batch = threads; threads = {}
    for _, thread in ipairs(batch) do
        if coroutine.status(thread) ~= "dead" then
            local ok, why = coroutine.resume(thread); assert(ok, why)
            if coroutine.status(thread) ~= "dead" then threads[#threads + 1] = thread end
        end
    end
end
local function advance(ms)
    now = now + ms
    local batch = timers; timers = {}
    for _, timer in ipairs(batch) do
        if timer.at <= now then timer.callback() else timers[#timers + 1] = timer end
    end
    step()
end
local function last(name)
    for i = #sent, 1, -1 do if sent[i].name == name then return sent[i].payload end end
end
Open77 = {
    kvp = { get = function(_, fallback) return storedMusic or fallback end, set = function(_, value) storedMusic = value; return true end },
    json = { encode = function(value) return value.enabled and "on" or "off" end,
        decode = function(value) return { enabled = value == "on", volume = 0.23 } end },
    log = { info = function(line) logs[#logs + 1] = line end },
    runtime = { version = function() return "fixture" end },
    time = { monotonic = function() return now / 1000 end },
    screen = { loadingState = function() return loading end },
    session = {
        launcherContext = function() return { protocolMajor = 1, protocolMinor = 35, gameBuild = 23100 } end,
        characterBootstrap = function() return bootstrap end,
        resetCharacterBootstrap = function() bootstrap = { phase = "waiting" }; return true end,
        loadPristine = function() return true end,
        openLauncher = function() return launcherOk, launcherOk and nil or "launcher_not_registered" end,
        quitGame = function() quits = quits + 1; return true end
    },
    network = {
        connect = function(endpoint)
            connects = connects + 1
            if not connectOk then return false, "invalid_endpoint" end
            status = { phase = "connecting", endpoint = endpoint, error = "" }; return true
        end,
        status = function() return status end,
        disconnect = function(reason) status = { phase = "offline", error = reason } end,
        refresh = function() refreshes = refreshes + 1; return true end,
        catalog = function() return { generation = 0, phase = "loading" } end
    }
}
WebUI = { create = function() return page end }
assert(load(SHELL_SOURCE, "@open77_shell/client/main.lua"))()
TriggerEvent("onClientResourceStart", "open77_shell")
TriggerEvent("open77:shell:show")
callbacks["shell:ready"]()
assert(last("privacy:state").visible == false, "addresses must start hidden")
callbacks["privacy:set"]({ visible = true })
assert(last("privacy:state").visible == true)
TriggerEvent("open77:privacy:request")
assert(last("privacy:state").visible == true, "pause readiness must retain the session choice")
TriggerEvent("open77:privacy:set", { visible = "true" })
assert(last("privacy:state").visible == true, "malformed toggle must be ignored")
TriggerEvent("open77:privacy:set", { visible = false })
assert(last("privacy:state").visible == false, "pause toggle must reach the shell")
assert(last("shell:state").client.protocolMinor == 35)
assert(refreshes == 0, "show/readiness must not start a directory request")
assert(last("music:preferences").volume == 0.12 and last("music:visibility").visible)
callbacks["music:preferences"]({ enabled = false, volume = 0.23 }, 10)
assert(replies[10].accepted and storedMusic == "off")
callbacks["shell:ready"]()
assert(last("music:preferences").enabled == false and last("music:preferences").volume == 0.23)
callbacks["music:preferences"]({ enabled = true, volume = 5 }, 11)
assert(not replies[11].accepted and storedMusic == "off")

-- Cancel while a worker is suspended. Its eventual wakeup cannot paint a failure.
TriggerEvent("open77:shell:autoconnect", "127.0.0.1:11936", "")
step(); step()
callbacks["connection:cancel"]({}, 1)
assert(replies[1].accepted and last("session:ended").reason == "connection_cancelled")
step()
assert(last("connection:update").phase ~= "failed", "stale worker painted a failure")

-- Retry the retained endpoint; old restoration timers cannot end the new attempt.
callbacks["connection:retry"]({}, 2)
step(); step(); advance(3000)
assert(replies[2].accepted and connects == 2)
assert(last("connection:update").phase == "connecting")
status = { phase = "active", error = "", hasResources = false }
bootstrap = { phase = "failed", error = "database_error" }
step()
assert(last("connection:update").reason == "database_error")
callbacks["shell:ready"]()
assert(last("connection:update").reason == "database_error", "page readiness lost error")
assert(refreshes == 0)

-- Immediate native refusal still reaches the page (no request object on autoconnect).
connectOk = false
TriggerEvent("open77:shell:autoconnect", "bad-endpoint", "")
step()
assert(last("connection:update").reason == "invalid_endpoint")

-- A native creator/load is not cancellable from the connection surface.
bootstrap = { phase = "creator_open" }
callbacks["connection:cancel"]({}, 3)
assert(not replies[3].accepted and replies[3].reason == "native_transition_in_progress")
bootstrap = { phase = "waiting" }

-- Failed launcher dispatch never closes the game. Explicit successful dispatch does.
callbacks["shell:launcher"]({}, 4)
advance(1000)
assert(not replies[4].accepted and quits == 0)
launcherOk = true
callbacks["shell:launcher"]({}, 5)
assert(replies[5].accepted and quits == 0)
advance(600)
assert(quits == 1)

-- The native menu unmount is early: the standard screen must still cover the
-- entire world stream when the server does not provide a custom loadscreen.
connectOk = true
TriggerEvent("open77:shell:autoconnect", "127.0.0.1:11936", "")
step(); step()
status = { phase = "active", error = "", hasResources = false }
bootstrap = { phase = "ready", family = "female" }
step()
assert(last("world:loading:begin"), "pristine load must enter the world stage")
local hidesBeforeLoad = hides
TriggerEvent("open77:shell:hide")
TriggerEvent("open77:worldReady")
advance(10000)
assert(visible and hides == hidesBeforeLoad, "native menu hide exposed the vanilla loading screen")
callbacks["connection:cancel"]({}, 12)
assert(not replies[12].accepted, "world streaming must remain non-cancellable")
local function logged(fragment)
    for i = #logs, 1, -1 do if logs[i]:find(fragment, 1, true) then return logs[i] end end
end
local function advanceBy(ms, slice)
    slice = slice or 100
    local done = 0
    while done < ms do advance(math.min(slice, ms - done)); done = done + slice end
end

-- The bootstrap completing is the world being loaded, not the player being
-- where the server wants them: the cover holds for the first placement
-- (2026-11-03: the pristine save's Badlands start showed for four seconds,
-- then a second loading screen streamed the server's spawn).
status.playerId = 7
TriggerEvent("open77:playerReset:complete")
assert(logged("loading handoff complete reason=player_bootstrap_complete"),
    "the harness marker for a completed join must keep its exact text")
assert(logged("first-placement hold begin"), "the bootstrap must start the first-placement hold")
advanceBy(3000)
assert(visible and hides == hidesBeforeLoad, "the cover dropped before the server placed the player")
-- Another player's transitions are not ours.
TriggerEvent("open77:playerLifeStateChanged", "12", "respawn_pending", "5")
TriggerEvent("open77:playerLifeStateChanged", "12", "recovering", "6")
-- The server's join spawn: kill + respawn far away, which opens a native load.
TriggerEvent("open77:playerLifeStateChanged", "7", "respawn_pending", "3")
assert(logged("first placement started"))
local updatesBefore = #sent
TriggerEvent("open77:loading:progress", "0.1")
for i = updatesBefore + 1, #sent do
    assert(sent[i].name ~= "world:loading", "a spawn teleport must not restart the loading bar")
end
loading = { active = true, id = "2", revision = 2 }
advanceBy(1500)
TriggerEvent("open77:playerLifeStateChanged", "7", "recovering", "4")
assert(logged("first placement landed"))
advanceBy(2000)
assert(visible and hides == hidesBeforeLoad, "the cover dropped over the spawn teleport's native load")
loading = { active = false, id = "2", revision = 3 }
advanceBy(500)
assert(visible, "the cover must outlast the native load by a settle")
advanceBy(1000)
assert(not visible and hides == hidesBeforeLoad + 1, "a landed first placement must release the cover")
assert(logged("loading cover released reason=first_placement"))
advance(2500)
TriggerEvent("open77:shell:show")
TriggerEvent("open77:shell:hide")
assert(not visible, "ordinary native hides must still work outside a load")

local function joinUntilBootstrap()
    TriggerEvent("open77:shell:autoconnect", "127.0.0.1:11936", "")
    step(); step()
    status = { phase = "active", error = "", hasResources = false, playerId = 7 }
    bootstrap = { phase = "ready", family = "female" }
    step()
    TriggerEvent("open77:shell:hide")
    TriggerEvent("open77:worldReady")
    advanceBy(5000, 500)
    assert(visible, "the world load must stay covered")
    local before = hides
    TriggerEvent("open77:playerReset:complete")
    return before
end

-- A server that never places on join: a bounded wait, never a strand.
local before = joinUntilBootstrap()
advanceBy(7000)
assert(visible and hides == before, "the quiet window ended early")
advanceBy(2000)
assert(not visible and hides == before + 1, "no placement must release after the quiet window")
assert(logged("loading cover released reason=no_placement"))
advance(2500)

-- A slow appearance restore pushes the quiet window: the restore and the
-- server's reaction to the gameplay announcement both stay covered.
before = joinUntilBootstrap()
advanceBy(7000)
TriggerEvent("open77:appearance:opened")
advanceBy(3000)
assert(visible and hides == before, "the cover dropped over the appearance restore")
TriggerEvent("open77:appearance:confirmed")
advanceBy(3500)
assert(visible and hides == before, "the cover dropped before the server could react to the restore")
advanceBy(1000)
assert(not visible and hides == before + 1, "the quiet window must end after the restore")
advance(2500)

-- A placement that never lands is capped: the cover never strands a player.
before = joinUntilBootstrap()
advanceBy(2000)
TriggerEvent("open77:playerLifeStateChanged", "7", "respawn_pending", "3")
advanceBy(22000, 500)
assert(visible and hides == before, "the cap fired early")
advanceBy(1500, 500)
assert(not visible and hides == before + 1, "a stuck placement must be released by the cap")
assert(logged("loading cover released reason=placement_timeout"))
advance(2500)

-- The session ending under the hold: the connection screen comes back and the
-- hold's thread never lifts it later.
before = joinUntilBootstrap()
advanceBy(1000)
local logsBefore = #logs
TriggerEvent("open77:session:ended", "server_disconnected")
advanceBy(30000, 1000)
assert(visible, "an ended session must keep the connection screen up")
for i = logsBefore + 1, #logs do
    assert(not logs[i]:find("loading cover released", 1, true), "an ended session's hold lifted the cover")
    assert(not logs[i]:find("pristine load abandoned", 1, true), "the hold was mistaken for a failed load")
end

-- A shell remount under the hold (the pre-game menu is back) ends the hold;
-- it is not a failed pristine load, which would disconnect the player.
TriggerEvent("open77:shell:hide")
advance(2500)
before = joinUntilBootstrap()
advanceBy(1000)
logsBefore = #logs
TriggerEvent("open77:shell:show")
advanceBy(5000, 500)
for i = logsBefore + 1, #logs do
    assert(not logs[i]:find("pristine load abandoned", 1, true), "a remount under the hold disconnected the player")
end
assert(logged("first-placement hold ended by a shell remount"))
print("Connection shell: cancellation, stale workers/timers, retry, errors, replay, launcher dispatch, world loading cover and first-placement hold passed")
