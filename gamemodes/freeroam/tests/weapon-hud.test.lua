-- Run from the repository root with Lua 5.4. Exercise the real resource's
-- asynchronous rows/completion boundary, including an old three-slot client.
local handlers, threads, pages = {}, {}, {}
local clock, requestId = 1, 0
local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item) end
    return result
end
FreeroamConfig = { weapons = { catalog = {} }, vehicles = { catalog = {} } }
DeathmatchConfig = { blade = {} }
Open77 = {
    time = { monotonic = function() return clock end },
    stats = { get = function() return { health = { value = 100, maximum = 100 } } end },
    hud = { setVisible = function() return true end },
    weapons = { snapshot = function() requestId = requestId + 1; return requestId end },
}
WebUI = { create = function(options)
    local page = { handlers = {} }
    function page:on(name, fn) self.handlers[name] = fn end
    function page:send(name, value) if name == "freeroam:hud" then self.state = copy(value) end end
    pages[options.entry] = page
    return page
end }
function GetCurrentResourceName() return "freeroam" end
function AddEventHandler(name, fn) handlers[name] = fn end
RegisterNetEvent = AddEventHandler
function CreateThread(fn) threads[#threads + 1] = coroutine.create(fn) end
function Wait() coroutine.yield() end
function TriggerServerEvent() end
function SetTimeout() end
dofile("resources/gamemodes/freeroam/client/main.lua")
local hudThreadIndex = #threads + 1
handlers.onClientResourceStart("freeroam")
local hud = assert(pages["web/hud.html"])
hud.handlers["freeroam:hud:ready"]()
local function tick()
    clock = clock + 0.25
    assert(coroutine.resume(threads[hudThreadIndex]))
    return requestId
end
local function row(id, slot, magazine, active, reloading, ammoId, total)
    handlers["open77:weapons:state"](id, tostring(slot), "Items.Preset_Test", "0x123",
        active == false and "false" or "true", "true", "false", "Ammo.Handgun", ammoId or "0x456",
        total or "120", "100", tostring(magazine), slot <= 3 and "20" or "10", reloading)
end
local function complete(id, accepted)
    handlers["open77:weapons:completed"](id, "snapshot", accepted == false and "false" or "true")
end
local id = tick()
row(id, 4, 7, true, "true") -- reverse order must still render right then left
row(id, 1, 18)
row(id, 2, 99, false)
tick()
assert(#hud.state.weapons == 0, "partial snapshot escaped into the HUD")
complete(id)
tick()
assert(#hud.state.weapons == 2 and hud.state.weapons[1].slot == 1 and hud.state.weapons[2].slot == 4)
assert(hud.state.weapons[1].magazine == 18 and hud.state.weapons[2].magazine == 7)
assert(not hud.state.weapons[1].reloading and hud.state.weapons[2].reloading)
assert(hud.state.weapons[1].reserve == 95 and hud.state.weapons[2].reserve == 95,
    "shared reserve must exclude both loaded magazines")

id = requestId
row(id, 1, 18)
row(id, 4, 7, true, false, "0x789")
complete(id)
tick()
assert(hud.state.weapons[1].reserve == 100 and hud.state.weapons[2].reserve == 100,
    "different ammo types must retain their individual reserve")

id = requestId
row(id, 1, 18)
row(id, 4, 7, true, false, "0x456", "119")
complete(id)
tick()
assert(not hud.state.weapons[1].reserveKnown and not hud.state.weapons[2].reserveKnown,
    "inconsistent pool observations must not invent a reserve")

id = requestId
row(id, 2, 8)
complete(id, false)
tick()
assert(#hud.state.weapons == 2, "failed snapshot erased the last verified pair")
id = requestId
row(id, 2, 8)
complete(id)
tick()
assert(#hud.state.weapons == 1 and hud.state.weapons[1].slot == 2, "secondary survived a single-weapon switch")
assert(hud.state.weapon.slot == 2 and not hud.state.weapon.reloading, "legacy row without reload flag changed meaning")

id = requestId
complete(id)
tick()
assert(#hud.state.weapons == 0 and not hud.state.weapon.equipped, "unarmed snapshot retained a card")
row(id, 4, 7)
tick()
assert(#hud.state.weapons == 0, "late row repopulated a completed snapshot")
print("freeroam-weapon-hud-ok")
