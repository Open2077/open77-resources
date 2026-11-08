-- Lua 5.4, run from this resource directory. No game or player data is changed.
dofile("config.lua")
local events, lifecycle, now, writes = {}, {}, 1000, {}
local seat = { vehicleId = 10, seat = "seat_front_left" }
local ready = true
local car = { health = 100, flags = 67, destroyed = false }
local siren = false
function RegisterNetEvent(name, fn) events[name] = fn end
function AddEventHandler(name, fn) lifecycle[name] = fn end
Open77 = {
    time = { monotonic = function() return now / 1000 end },
    ready = { isReady = function(id) assert(id == 1); return ready end },
    vehicles = {
        getPlayerSeat = function(id) assert(id == nil or id == 1); return seat end,
        get = function(id) assert(id == 10); return car end,
        isSirenOn = function(id) assert(id == 10); return siren end,
        setSiren = function(id, on)
            assert(id == 10 and type(on) == "boolean")
            writes[#writes + 1] = on
            siren = on
            return true
        end,
    },
}
dofile("server/main.lua")
local receive = events["open77:vehicleSiren:toggle"]
local checks = 0
local function request(expectWrite, id, sender, advance)
    now = now + (advance or 301)
    source = sender == nil and 1 or sender
    local before = #writes
    receive(id)
    assert(#writes == before + (expectWrite and 1 or 0), "unexpected write at check " .. (checks + 1))
    checks = checks + 1
end
request(true, 10)
assert(siren, "driver turns siren on")
request(false, 10, 1, 1)
assert(siren, "duplicate request inside cooldown does not reverse the state")
request(true, 10)
assert(not siren, "next distinct request turns it off")
request(false, 11) -- stale request for another vehicle
request(false, 10, 0)
request(false, 10, "spoofed")
request(false, "10")
request(false, -1)
request(false, 10.5)
request(false, 0/0)
request(false, math.huge)
request(false, {})
request(false, nil)
ready = false; request(false, 10); ready = true
seat = nil; request(false, 10)
seat = { vehicleId = 10, seat = "seat_front_right" }; request(false, 10)
seat.seat = "seat_front_left"
seat.entering = true; request(false, 10); seat.entering = false
seat.exiting = true; request(false, 10); seat.exiting = false
car.destroyed = true; request(false, 10); car.destroyed = false
car.health = 0; request(false, 10); car.health = 100
local savedCar = car; car = nil; request(false, 10); car = savedCar
siren = nil; request(false, 10); siren = false
request(true, 10, "1") -- authenticated source may be numeric text
assert(car.flags == 67, "the resource never rewrites other vehicle state")
lifecycle.onPlayerDisconnected("1")
request(true, 10, 1, 1) -- recycled player ID is not throttled by the old connection

local sent, mapping, exported = {}, nil, {}
function TriggerServerEvent(name, id)
    sent[#sent + 1] = { name = name, id = id }
    return true
end
function RegisterKeyMapping(id, name, key, fn)
    mapping = { id = id, name = name, key = key, press = fn }
    return true, "MouseX1" -- host's saved player binding wins
end
function exports(name, fn) exported[name] = fn end
dofile("client/main.lua")
assert(mapping.id == "vehicle_siren" and mapping.key == "F6")
assert(mapping.press == exported.toggle, "menu export follows the same request path")
seat = nil; assert(not mapping.press()); assert(#sent == 0)
seat = { vehicleId = 10, seat = "seat_front_right" }
assert(not mapping.press()); assert(#sent == 0)
seat.seat = "seat_front_left"; seat.entering = true
assert(not mapping.press()); assert(#sent == 0)
seat.entering = false; seat.exiting = true
assert(not mapping.press()); assert(#sent == 0)
seat.exiting = false
assert(mapping.press()); assert(#sent == 1 and sent[1].id == 10)
assert(sent[1].name == "open77:vehicleSiren:toggle")
assert(not mapping.press()); assert(#sent == 1)
now = now + 301
seat.vehicleId = 20
assert(mapping.press()); assert(sent[2].id == 20, "read the current seat each time")
print("siren: " .. checks .. " server request cases and client mapping/seat/cooldown checks passed")
