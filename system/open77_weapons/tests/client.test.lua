-- Run from the repository root with Lua 5.4.
local handlers, network, public, sent, requests = {}, {}, {}, {}, {}
local nextId = 0
local function queue(operation, value)
    nextId = nextId + 1
    requests[#requests + 1] = { id = nextId, operation = operation, value = value }
    return nextId
end
Open77 = { weapons = {
    remove = function(slot) return queue("remove", slot) end,
    snapshot = function() return queue("snapshot") end,
    setDualWieldAllowed = function(value) return queue("setDualWieldAllowed", value) end,
} }
function exports(name, fn) public[name] = fn end
function AddEventHandler(name, fn) handlers[name] = fn end
function RegisterNetEvent(name, fn) network[name] = fn end
function TriggerServerEvent(...) sent[#sent + 1] = table.pack(...) end
function TriggerEvent() end
function CreateThread() end
function GetGameTimer() return 100 end

dofile("resources/system/open77_weapons/client/main.lua")
local complete = handlers["open77:weapons:completed"]
local dispatch = network["open77:weapons:request"]

-- Model the native CP 2.5 promotion rule, not the facade's loop order.
local slots = { "r1", "r2", "r3", "l1", "l2", "l3" }
dispatch("test:clear", "clear")
assert(#requests == 6)
for index = 1, 6 do
    local request = requests[index]
    local slot = request.value
    assert(request.operation == "remove")
    if slot <= 3 then
        slots[slot], slots[slot + 3] = slots[slot + 3], nil
    else
        slots[slot] = nil
    end
    complete(request.id, "remove", "true", "", tostring(slot))
end
for slot = 1, 6 do assert(slots[slot] == nil, "clear left a promoted pistol in slot " .. slot) end
local clearReply = assert(sent[1])
assert(clearReply[1] == "open77:weapons:result" and clearReply[2] == "test:clear")
assert(clearReply[3] == "clear" and clearReply[4] == true and clearReply[6].cleared == 6)
for slot = 1, 6 do
    assert(clearReply[6].slots[slot].slot == slot and clearReply[6].slots[slot].accepted)
end

dispatch("test:enable", "setDualWieldAllowed", true)
local enable = requests[#requests]
assert(enable.operation == "setDualWieldAllowed" and enable.value == true)
complete(enable.id, "setDualWieldAllowed", "true", "", "0")
local enabledReply = sent[#sent]
assert(enabledReply[2] == "test:enable" and enabledReply[4] == true)

-- The server snapshot carries every secondary slot, even identical records.
dispatch("test:snapshot", "snapshot")
local snapshot = requests[#requests]
for slot = 1, 6 do
    handlers["open77:weapons:state"](snapshot.id, tostring(slot), "Items.Preset_Lexington_Default",
        "0x1E1601AA89", "true", "true", "false", "Ammo.HandgunAmmo", "0x1234",
        "200", "180", tostring(slot <= 3 and 20 or 7), "20", slot == 4 and "true" or "false")
end
complete(snapshot.id, "snapshot", "true", "", "0")
local report = sent[#sent - 1]
assert(report[1] == "open77:weapons:report" and #report[2] == 6)
assert(report[2][1].ammo.magazine == 20 and report[2][4].ammo.magazine == 7)
local reply = sent[#sent]
assert(reply[2] == "test:snapshot" and #reply[6] == 6)
assert(not reply[6][1].reloading and reply[6][4].reloading)
print("weapons-client-dual-ok")
