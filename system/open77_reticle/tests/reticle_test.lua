local state = { available = true, engaged = true, camera = "open77_rig",
    body = "proxy", input = "player", aiming = true }
local alive, armed, captured = true, true, false
local start, worker, onReady
local sent, shown, hidden = {}, 0, 0
local page = {}
function page:on(event, callback) assert(event == "reticle:ready"); onReady = callback end
function page:send(event, payload) assert(event == "reticle:state"); sent[#sent+1] = payload end
function page:show() shown = shown + 1 end
function page:hide() hidden = hidden + 1 end
Open77 = {
    perspective = { state = function() return state end },
    character = { isAlive = function() return alive end, isArmed = function() return armed end },
    input = { isCaptured = function() return captured end },
    log = { error = function(message) error(message) end },
}
WebUI = { create = function(options)
    assert(options.layer == "hud" and options.transparent and options.fps == 30)
    return page
end }
function GetCurrentResourceName() return "open77_reticle" end
function AddEventHandler(event, callback) assert(event == "onClientResourceStart"); start = callback end
function CreateThread(callback) worker = coroutine.create(callback) end
function Wait(ms) assert(ms == 16); coroutine.yield() end
local function tick() local ok, reason = coroutine.resume(worker); assert(ok, reason) end
assert(load(RETICLE_SOURCE, "@open77_reticle/client/main.lua", "t"))()
start("other_resource"); assert(worker == nil)
start("open77_reticle")
tick(); assert(#sent == 0) -- never lose a send before browser readiness
onReady(); assert(#sent == 1 and sent[1].visible and sent[1].aiming and shown == 1)
tick(); assert(#sent == 1) -- no per-frame IPC for stable state
state.aiming = false; tick(); assert(not sent[#sent].visible and hidden == 1)
state.aiming = true; tick(); assert(sent[#sent].visible)
for _, pair in ipairs({{"camera","engine"}, {"camera","player_eyes"}, {"body","engine"},
    {"input","engine"}, {"engaged",false}, {"available",false}}) do
    local before = state[pair[1]]
    state[pair[1]] = pair[2]; tick(); assert(not sent[#sent].visible)
    state[pair[1]] = before; tick(); assert(sent[#sent].visible)
end
alive = false; tick(); assert(not sent[#sent].visible)
alive = true; tick(); assert(sent[#sent].visible)
armed = false; tick(); assert(not sent[#sent].visible)
armed = true; tick(); assert(sent[#sent].visible)
captured = true; tick(); assert(not sent[#sent].visible)
captured = false; tick(); assert(sent[#sent].visible)
local previous = state; state = nil; tick(); assert(not sent[#sent].visible)
state = previous; onReady(); assert(sent[#sent].visible) -- page reload resends unchanged state
print("Reticle: readiness, aim, FPP/engine ownership, life, equipment and menus OK")
