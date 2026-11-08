-- Server half of open77_braindance against a fake platform (exports, events,
-- Open77.players.teleport). Loaded after shared/sequence.lua.
local ROOT = BraindanceRoot or "."
local S = BraindanceSequence or dofile(ROOT .. "/shared/sequence.lua")
local passed = 0
local function check(cond, msg) if not cond then error(msg, 2) end passed = passed + 1 end

-- Fake platform ------------------------------------------------------------
local exported, netHandlers, localHandlers, commands = {}, {}, {}, {}
local sentToClient, teleports, clock = {}, {}, 0
exports = setmetatable({}, { __call = function(_, name, fn) exported[name] = fn end })
function RegisterNetEvent(name, fn) netHandlers[name] = fn end
function AddEventHandler(name, fn) localHandlers[name] = localHandlers[name] or {} table.insert(localHandlers[name], fn) end
local fired = {}
function TriggerEvent(name, ...) fired[#fired + 1] = { name = name, args = { ... } }
    for _, fn in ipairs(localHandlers[name] or {}) do fn(...) end
end
function TriggerClientEvent(name, pid, ...) sentToClient[#sentToClient + 1] = { name = name, pid = pid, args = { ... } } end
function CreateThread(fn) fn() end
function GetGameTimer() return clock end
function RegisterCommand(name, fn) commands[name] = fn end
function GetCurrentResourceName() return "open77_braindance" end
local printed = {}
function print(line) printed[#printed + 1] = line end
local teleportAnswer = { x = 1, y = 2, z = 3, state = "settled" }
Open77 = { players = { teleport = function(pid, position, options)
    teleports[#teleports + 1] = { pid = pid, position = position, options = options }
    return { await = function() return teleportAnswer end }
end } }

local function report(pid, id, phase, tag)
    source = tostring(pid)
    netHandlers["open77_braindance:report"](id, phase, tag)
end
local function last() return sentToClient[#sentToClient] end

dofile(ROOT .. "/server/main.lua")

-- start validation -----------------------------------------------------------
check(select(2, exported.start(0, {})) == "invalid_player", "player id")
check(select(2, exported.start(1, "x")) == "options_must_be_a_table", "options type")
check(select(2, exported.start(1, { teleport = { x = 1 } })) == "invalid_teleport", "teleport shape")
check(select(2, exported.start(1, { preset = "nope" })) == "unknown_preset", "validated like the client")

-- server start with teleport: client receives hold=true, no teleport key
local id = assert(exported.start(1, { preset = "transition", teleport = { x = 10, y = 20, z = 30, heading = 90, bucket = 2 }, tag = "t" }))
check(id == "s1", "server ids")
local msg = last()
check(msg.name == "open77_braindance:start" and msg.pid == 1 and msg.args[1] == "s1", "start relayed")
check(msg.args[2].hold == true and msg.args[2].teleport == nil and msg.args[2].tag == "t", "client options")

-- phases from the client reach server scripts; black teleports then resumes
local phases, blacks = {}, {}
AddEventHandler("open77_braindance:phase", function(pid, sid, phase, tag) phases[#phases + 1] = table.concat({ pid, sid, phase, tostring(tag) }, ":") end)
AddEventHandler("open77_braindance:black", function(pid, sid, tag) blacks[#blacks + 1] = pid .. ":" .. sid .. ":" .. tostring(tag) end)
report(1, "s1", "flash")
report(1, "s1", "darkening")
report(1, "s1", "black")
check(phases[#phases] == "1:s1:black:t" and blacks[1] == "1:s1:t", "phase + black events")
check(#teleports == 1 and teleports[1].position.x == 10 and teleports[1].options.fade == false
    and teleports[1].options.heading == 90 and teleports[1].options.bucket == 2, "teleport without extra fade")
check(last().name == "open77_braindance:resume" and last().args[1] == "s1", "resume after the body settled")
local st = exported.state(1)
check(st[1] ~= nil and st[1].phase == "black", "state: " .. #st .. " " .. tostring(phases[#phases]))
report(1, "s1", "revealing")
report(1, "s1", "finished")
check(#exported.state(1) == 0, "finished sequence forgotten")

-- a failed teleport still resumes (never leave a player on black)
teleportAnswer = nil
assert(exported.start(1, { preset = "glitch", teleport = { x = 1, y = 1, z = 1 } }))
report(1, "s2", "black")
check(last().name == "open77_braindance:resume" and last().args[1] == "s2", "resume after a failed teleport")
report(1, "s2", "cancelled")

-- client-started sequences are announced with their tag; forged server ids are ignored
report(2, "c1", "flash", "bd-room")
check(phases[#phases] == "2:c1:flash:bd-room", "client sequence announced")
local before = #phases
report(2, "s99", "black")
check(#phases == before, "unknown server id ignored")
report(2, "c1", "bogus")
check(#phases == before, "unknown phase ignored")

-- resume / exit / cancel only for known ids
check(select(2, exported.resume(1, "s404")) == "not_found", "resume unknown")
local live = assert(exported.start(3, { preset = "braindance" }))
check(exported.exit(3, live, { teleport = { x = 5, y = 6, z = 7 } }) == true, "exit with teleport")
check(last().name == "open77_braindance:exit" and last().args[2].hold == true, "exit holds for the teleport")
report(3, live, "exiting")
report(3, live, "black")
check(teleports[#teleports].position.x == 5, "exit teleport on the exit black")
check(exported.cancel(3, live) == true and last().name == "open77_braindance:cancel", "cancel relayed")
check(select(2, exported.playEffect(3, "bad name")) == "invalid_effect", "effect name checked")
check(exported.playEffect(3, "braindance_fpp", 1000) == true and last().name == "open77_braindance:effect", "effect relayed")

-- at most two live sequences per player
assert(exported.start(4, {}))
assert(exported.start(4, {}))
check(select(2, exported.start(4, {})) == "too_many_sequences", "per-player cap")
source = "4"
localHandlers.playerDropped[1]()
check(#exported.state(4) == 0, "dropped player forgotten")

-- vision layers (server/vision.lua)
dofile(ROOT .. "/server/vision.lua")
check(select(2, exported.setLayer(0, "thermal")) == "invalid_player", "layer player id")
check(select(2, exported.setLayer(5, "infrared")) == "invalid_layer", "layer name")
check(select(2, exported.setLayer(5, "thermal", "x")) == "invalid_options", "layer options type")
check(select(2, exported.setLayer(5, "thermal", { heat = { f = function() end } })) == "invalid_options", "plain data only")
check(exported.setLayer(5, "thermal", { heat = { radius = 30, colors = { npc = "hot" } }, effect = false }) == true, "setLayer")
check(last().name == "open77_braindance:setLayer" and last().pid == 5 and last().args[1] == "thermal"
    and last().args[2].heat.radius == 30 and last().args[2].heat.colors.npc == "hot", "setLayer relayed")
check(select(2, exported.setHeat(5, { entity = 3 }, "hot")) == "invalid_target", "heat target")
check(select(2, exported.setHeat(5, { playerId = 2 }, "lava")) == "invalid_level", "heat level")
check(exported.setHeat(5, { playerId = 2 }, "clue") == true and last().args[1].playerId == 2 and last().args[2] == "clue", "setHeat relayed")
check(exported.clearHeat(5) == true and last().name == "open77_braindance:clearHeat", "clearHeat relayed")
check(exported.layer(5) == "off", "no layer reported yet")
local changes = {}
AddEventHandler("open77_braindance:layerChanged", function(pid, layer, previous) changes[#changes + 1] = pid .. ":" .. previous .. ">" .. layer end)
source = "5"
netHandlers["open77_braindance:layerReport"]("thermal", "off")
netHandlers["open77_braindance:layerReport"]("infrared", "off")
check(exported.layer(5) == "thermal" and #changes == 1 and changes[1] == "5:off>thermal", "layer report")
localHandlers.playerDropped[#localHandlers.playerDropped]()
check(exported.layer(5) == "off", "dropped player's layer forgotten")

BraindanceServerTestsPassed = passed
io.write(("server_test: %d checks passed" .. string.char(10)):format(passed))
