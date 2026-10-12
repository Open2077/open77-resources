local handlers, callbacks, sent, replies, threads, timers = {}, {}, {}, {}, {}, {}
local status = { phase = "offline", error = "" }
local bootstrap = { phase = "waiting" }
local now, connects, quits, refreshes = 0, 0, 0, 0
local launcherOk, connectOk = false, true
local storedMusic
local page = { hide = function() end, show = function() end, setFocus = function() end }
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
    log = { info = function() end }, runtime = { version = function() return "fixture" end },
    time = { monotonic = function() return now / 1000 end },
    session = {
        launcherContext = function() return { protocolMajor = 1, protocolMinor = 35, gameBuild = 23100 } end,
        characterBootstrap = function() return bootstrap end,
        resetCharacterBootstrap = function() bootstrap = { phase = "waiting" }; return true end,
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
print("Connection shell: cancellation, stale workers/timers, retry, errors, replay and launcher dispatch passed")
