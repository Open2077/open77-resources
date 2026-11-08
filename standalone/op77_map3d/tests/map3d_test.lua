-- op77_map3d: blip validation, the client (page, blips, owners, waypoint mirror, open)
-- and the server (targets, late joiners, cleanup). Run: pwsh -File tests/run-lua.ps1
dofile("shared/config.lua"); dofile("shared/blip.lua"); dofile("shared/jam.lua")
-- jam validation: zones need a position and a radius; strength fades over `fade`
assert(Map3DJam.normalize({ radius = 5 }) == nil, "a zone needs a position")
local z = assert(Map3DJam.normalize({ position = { x = 0, y = 0 }, radius = 100, fade = 50, strength = 0.8 }))
assert(Map3DJam.at(z, 10, 0) == 0.8 and math.abs(Map3DJam.at(z, 125, 0) - 0.4) < 1e-9 and Map3DJam.at(z, 200, 0) == 0)
assert(Map3DJam.at(assert(Map3DJam.normalize({ strength = 3 })), nil, nil) == 1, "a direct jam is everywhere, clamped to 1")
local B = Map3DBlip

-- ---------------------------------------------------------------- validation
assert(B.normalize({}) == nil, "a blip needs a position")
local b = assert(B.normalize({ position = { x = 1, y = 2 }, color = "red", scale = 9, label = string.rep("x", 200) }))
assert(b.z == 0 and b.color == nil and b.scale == 3 and #b.label == 96 and b.category == "default" and b.map and b.minimap)
assert(B.normalize({ x = 5, y = 6, color = "#FFCC00" }).color == "#FFCC00", "flat x/y and a hex colour")
local moved = assert(B.patch(b, { x = 10 }))
assert(moved.x == 10 and moved.y == 2, "a patch with x keeps y")
assert(B.patch(b, { position = { x = 3, y = 4, z = 5 } }).z == 5)
assert(B.patch(b, { color = false }).color == nil)

-- ---------------------------------------------------------------- client
local threads, handlers, netHandlers, exported, sentToServer = {}, {}, {}, {}, {}
local function runThreads(n) for _ = 1, n or 1 do for _, t in ipairs(threads) do if coroutine.status(t) ~= "dead" then assert(coroutine.resume(t)) end end end end
_G.CreateThread = function(fn) threads[#threads + 1] = coroutine.create(fn) end
_G.Wait = function() coroutine.yield() end
_G.GetCurrentResourceName = function() return "op77_map3d" end
local invoking = nil
_G.GetInvokingResource = function() return invoking end
_G.AddEventHandler = function(name, fn) handlers[name] = fn end
_G.RegisterNetEvent = function(name, fn) netHandlers[name] = fn end
_G.TriggerServerEvent = function(name) sentToServer[#sentToServer + 1] = name end
local events = {}
_G.TriggerEvent = function(name, ...) events[#events + 1] = { name = name, args = { ... } } end
local function lastEvent(name) for i = #events, 1, -1 do if events[i].name == name then return events[i].args[1] end end end
_G.exports = function(name, fn) exported[name] = fn end
local keyFn
local keyMaps = {}
_G.RegisterKeyMapping = function(id, _, _, fn) if type(id) == "table" then keyMaps[id.id] = id else keyFn = fn end; return true end
local pageSent, focus = {}, { false, false }
local surfaces = {}   -- role -> { options, handlers, visible }
local function newPage(role, options)
    local s = { options = options, handlers = {}, visible = options.visible }
    surfaces[role] = s
    return {
        send = function(_, name, payload) pageSent[#pageSent + 1] = { name = name, payload = payload, role = role } end,
        on = function(_, name, fn) s.handlers[name] = fn end,
        setFocus = function(_, k, c) assert(role == "full", "only the map takes focus"); focus = { k, c }; return true end,
        setConsumedKeys = function() return true end,
        show = function() s.visible = true end,
        hide = function() s.visible = false end,
        destroy = function() s.destroyed = true end,
    }
end
_G.WebUI = { create = function(o) return newPage(({ [700] = "mini", [781] = "full", [699] = "holo" })[o.zIndex], o) end }
local nativeWp, blocked, hudMinimap = nil, nil, true
local otherCursor = false
_G.Open77 = {
    character = { state = function() return { position = { x = 100, y = 200, z = 10 }, yaw = 10, forward = { x = -0.70710678, y = 0.70710678, z = 0 }, groundSpeed = 3, attached = true } end,
        isInVehicle = function() return false end },
    camera = { view = function() return { forward = { x = 0, y = 1, z = 0 } } end },
    players = { nearby = function() return { { id = 7, name = "Jack", position = { x = 110, y = 205, z = 10 } }, { id = 1, isLocal = true, position = { x = 100, y = 200 } } } end },
    input = { setActionBlocked = function(action, v) assert(action == "Map"); blocked = v; return true end,
        isCaptured = function() return otherCursor, otherCursor end },
    hud = { setVisible = function(c, v) assert(c == "minimap"); hudMinimap = v; return true end },
    blips = { setWaypoint = function(p) nativeWp = p; return true end, clearWaypoint = function() nativeWp = nil; return true end,
        waypoint = function() return nativeWp end },
}
dofile("client/main.lua")
local function lastPage(name) for i = #pageSent, 1, -1 do if pageSent[i].name == name then return pageSent[i].payload end end end

handlers.onClientResourceStart("op77_map3d")
assert(blocked == true and hudMinimap == false, "the native map and minimap step aside")
assert(sentToServer[1] == "op77_map3d:hello")
local reg = lastEvent("open77:mapProvider:register")
assert(reg and reg.resource == "op77_map3d" and reg.priority == 100, "registered as the pause menu's city map")
runThreads(1)
local pageHandlers, miniHandlers = surfaces.full.handlers, surfaces.mini.handlers
assert(pageHandlers["map3d:ready"] and miniHandlers["map3d:ready"], "both surfaces created")
local mo, fo = surfaces.mini.options, surfaces.full.options
assert(mo.fps == 60 and mo.visible and mo.drawBounds.x < 0 and mo.drawBounds.y == 0 and mo.drawBounds.width > 264, "the minimap: its top-right corner, 60 fps")
assert(fo.fps == 60 and not fo.visible and fo.drawBounds == nil, "the map: full screen, hidden until opened")
assert(surfaces.holo and surfaces.holo.options.fps == 30 and not surfaces.holo.options.visible, "the holo GPS: its own surface, hidden without a route")
-- a blip before the page is ready is kept and sent on ready
invoking = "shop"
local id = exported.addBlip({ position = { x = 1, y = 2 }, icon = "store", label = "24/7", category = "service" })
assert(id and id:find("^shop#"))
assert(not lastPage("map3d:blip"), "nothing reaches a page that is not ready")
pageHandlers["map3d:ready"]({})
miniHandlers["map3d:ready"]({})
assert(lastPage("map3d:role").role == "mini", "each surface is told its role")
-- minimap zoom keys: held, sent to the minimap's surface
local zin = assert(keyMaps["op77_map3d.zoomIn"], "zoom in mapping"); assert(zin.hold and zin.key == "NUMPADPLUS")
local before = #pageSent
zin.onPressed(); keyMaps["op77_map3d.zoomOut"].onReleased()
local z1, z2 = pageSent[before + 1], pageSent[before + 2]
assert(z1.name == "map3d:miniZoom" and z1.role == "mini" and z1.payload.dir == 1 and z1.payload.down)
assert(z2.payload.dir == -1 and z2.payload.down == false)
local set = lastPage("map3d:blips").set
assert(#set == 1 and set[1].id == id and set[1].label == "24/7" and set[1].owner == nil, "ready: config + every blip")
assert(lastPage("map3d:config").theme.accent == "#FFCC00")
-- player feed and nearby players
runThreads(3)
local pl = lastPage("map3d:player")
assert(pl and pl.x == 100 and math.abs(pl.yaw - 45) < 1e-6 and math.abs(pl.camYaw) < 1e-6 and pl.speed == 3, "first person: the arrow follows the body's forward, not the look yaw")
-- third person: the visible body faces its motion, keeps that facing when it stops
local tpsState = { position = { x = 100, y = 200, z = 10 }, yaw = 0, forward = { x = 0, y = 1, z = 0 }, velocity = { x = 3, y = 0, z = 0 }, groundSpeed = 3, attached = true }
Open77.perspective = { get = function() return "tps" end }
local realState = Open77.character.state
Open77.character.state = function() return tpsState end
runThreads(2)
pl = lastPage("map3d:player")
assert(math.abs(pl.yaw + 90) < 1e-6, "third person: moving east (+x) faces east (yaw -90), not the camera")
tpsState.velocity = { x = 0, y = 0, z = 0 }; tpsState.groundSpeed = 0
runThreads(2)
assert(math.abs(lastPage("map3d:player").yaw + 90) < 1e-6, "standing still keeps the last facing")
Open77.character.isAiming = function() return true end
runThreads(2)
assert(math.abs(lastPage("map3d:player").yaw) < 1e-6, "aiming turns the body to the camera")
Open77.character.isAiming = nil
-- in a car reversing (moving south) while facing north: the arrow keeps the car's nose
tpsState.velocity = { x = 0, y = -4, z = 0 }; tpsState.groundSpeed = 4
Open77.character.isInVehicle = function() return true end
Open77.vehicles = { getPlayerSeat = function() return { vehicleId = 12 } end, get = function(id) assert(id == 12); return { heading = 0 } end }
runThreads(2)
pl = lastPage("map3d:player")
assert(pl.vehicle and math.abs(pl.yaw) < 1e-6, "reversing does not turn the arrow: it is the car's heading")
Open77.vehicles = nil
Open77.character.isInVehicle = function() return false end
Open77.perspective = nil
Open77.character.state = realState
-- updates and ownership
assert(exported.updateBlip(id, { label = "Shop" }) and lastPage("map3d:blip").label == "Shop")
invoking = "other"
assert(not exported.updateBlip(id, { label = "x" }), "another resource cannot change it")
local named = exported.addBlip({ id = "depot", x = 5, y = 5 })
assert(named == "other:depot")
handlers.onClientResourceStop("shop")
local rem = lastPage("map3d:blips").remove
assert(#rem == 1 and rem[1] == id, "a stopping resource takes its blips along")
assert(exported.getBlip(named) and not exported.getBlip(id))
-- waypoint: export -> page route + native mirror; page -> native; native -> page
assert(exported.setWaypoint({ x = 50, y = 60, z = 1 }))
assert(lastPage("map3d:route").x == 50 and nativeWp and nativeWp.x == 50)
pageSent = {}
pageHandlers["map3d:waypoint"]({ x = 70, y = 80, z = 2 })
assert(exported.getWaypoint().x == 70 and nativeWp.x == 70, "a waypoint placed on the page is the game's too")
local toMini, toFull = false, false
for _, s in ipairs(pageSent) do if s.name == "map3d:route" then if s.role == "mini" then toMini = s.payload.x == 70 else toFull = true end end end
assert(toMini and not toFull, "a route set on the map reaches the minimap, not back to the map")
pageHandlers["map3d:waypoint"]({ clear = true })
assert(exported.getWaypoint() == nil and nativeWp == nil)
nativeWp = { x = 300, y = 400, z = 0 }  -- another resource placed the native waypoint
runThreads(4)
assert(exported.getWaypoint() and exported.getWaypoint().x == 300 and lastPage("map3d:route").x == 300, "the map follows a native waypoint")
nativeWp = nil  -- the resource that placed it cleared it, after it had been read back
runThreads(4)
assert(exported.getWaypoint() == nil, "another resource's native waypoint that disappears clears the route")
-- ours, dropped by the game (it happens while driving): placed again, the route stays
assert(exported.setWaypoint({ x = 600, y = 700 }))
runThreads(2)
assert(nativeWp and nativeWp.x == 600)
nativeWp = nil
runThreads(2)
assert(exported.getWaypoint() and exported.getWaypoint().x == 600 and nativeWp and nativeWp.x == 600, "the game dropping our waypoint does not end the route")
exported.clearWaypoint()
-- the game refuses (or has not applied yet) our waypoint: the route stays
local realSet = Open77.blips.setWaypoint
Open77.blips.setWaypoint = function() return false, "world_unavailable" end
assert(exported.setWaypoint({ x = 500, y = 600 }))
runThreads(4)
assert(exported.getWaypoint() and exported.getWaypoint().x == 500, "a refused native waypoint does not wipe ours")
Open77.blips.waypoint = function() return nil, "native_unavailable" end
runThreads(2)
assert(exported.getWaypoint(), "a waypoint read that failed is not a clear")
Open77.blips.waypoint = function() return nativeWp end
Open77.blips.setWaypoint = realSet
-- a new destination while the game still reports the old one: the new one stays
assert(exported.setWaypoint({ x = 10, y = 10 }))
runThreads(2)
nativeWp = { x = 10, y = 10, z = 0 }
runThreads(2)
local lag = true
Open77.blips.setWaypoint = function(p) if not lag then nativeWp = p end; return true end
pageHandlers["map3d:waypoint"]({ x = 900, y = 900, z = 0 })
runThreads(4)
assert(exported.getWaypoint().x == 900, "a lagging native read of the previous waypoint does not bring the old route back")
lag = false
pageHandlers["map3d:waypoint"]({ x = 950, y = 950, z = 0 })
runThreads(2)
assert(exported.getWaypoint().x == 950 and nativeWp.x == 950)
nativeWp = { x = 42, y = 42, z = 0 }  -- then another resource really picks a place
runThreads(2)
assert(exported.getWaypoint().x == 42, "a genuinely new native waypoint is still followed")
Open77.blips.setWaypoint = realSet
-- route info and arrival are events
pageHandlers["map3d:routeInfo"]({ active = true, remaining = 999 })
miniHandlers["map3d:routeInfo"]({ active = true, remaining = 120 })
assert(exported.getRoute().remaining == 120, "route events come from the minimap's surface only")
-- open / close
local fakeNow = 0
_G.GetGameTimer = function() return fakeNow end
fakeNow = 1000
keyFn()
assert(exported.isOpen() and focus[1] and focus[2] and lastPage("map3d:open"))
-- M while open: the page closes the map and the mapping sees the same press
pageHandlers["map3d:close"]({})
fakeNow = 1100; keyFn()
assert(not exported.isOpen(), "the press that closed the map does not reopen it")
fakeNow = 2000; keyFn()
assert(exported.isOpen())
pageHandlers["map3d:typing"]({ active = true })
fakeNow = 3000; keyFn()
assert(exported.isOpen(), "an m typed in the search box is not the map key")
pageHandlers["map3d:typing"]({ active = false })
assert(surfaces.full.visible and not surfaces.mini.visible, "open: the map shows, the minimap rests")
pageHandlers["map3d:close"]({})
assert(not exported.isOpen() and not focus[1] and lastPage("map3d:close"))
assert(surfaces.mini.visible, "closed: the minimap is back at once")
assert(surfaces.full.visible, "the map's surface stays up for its closing animation")
runThreads(2)
assert(not surfaces.full.visible, "closed: the map's surface is hidden after it")
-- the holographic GPS: the minimap's route reaches it; it shows while a route runs and
-- the map is closed, unless switched off on the map
surfaces.holo.handlers["map3d:ready"]({})
local holoRoute = { pts = { 1, 2, 3, 4 }, left = "1 km" }
miniHandlers["map3d:holo"](holoRoute)
assert(surfaces.holo.visible and lastPage("map3d:holo") == holoRoute, "a route shows the holo")
pageHandlers["map3d:holo"]({ clear = true, pts = {} })
assert(surfaces.holo.visible, "only the GPS surface speaks for the route")
fakeNow = fakeNow + 1000; keyFn()
assert(exported.isOpen() and not surfaces.holo.visible, "the open map hides it")
pageHandlers["map3d:close"]({}); fakeNow = fakeNow + 1000
assert(surfaces.holo.visible)
pageHandlers["map3d:holoPref"]({ enabled = false })
assert(not surfaces.holo.visible, "switched off on the map")
pageHandlers["map3d:holoPref"]({ enabled = true })
miniHandlers["map3d:holo"]({ clear = true, pts = {} })
assert(not surfaces.holo.visible, "no route, no holo")
-- the player's switches on the map: the minimap's surface rests, the choices reach it
local before = #pageSent
pageHandlers["map3d:prefs"]({ hud = { minimap = false, holo = true }, layers = { metro = false }, hiddenCats = { "job" } })
assert(not surfaces.mini.visible, "minimap switched off: its surface is hidden")
local got
for i = before + 1, #pageSent do if pageSent[i].name == "map3d:prefs" and pageSent[i].role == "mini" then got = pageSent[i].payload end end
assert(got and got.layers.metro == false and got.hiddenCats[1] == "job", "the minimap gets the same layers and categories")
fakeNow = fakeNow + 1000; keyFn(); fakeNow = fakeNow + 1000; pageHandlers["map3d:close"]({})
assert(not surfaces.mini.visible, "closing the map does not bring a switched-off minimap back")
pageHandlers["map3d:prefs"]({ hud = { minimap = true }, layers = {}, hiddenCats = {} })
assert(surfaces.mini.visible)
-- jamming: a direct jam reaches every page and hides the holo; a zone follows the player
miniHandlers["map3d:holo"]({ pts = { 1, 2, 3, 4, 5, 6 } })
assert(surfaces.holo.visible)
invoking = "rp_scrambler"
local jamId = assert(exported.jam({ label = "SIGNAL LOST" }))
assert(lastPage("map3d:jam").strength == 1 and lastPage("map3d:jam").label == "SIGNAL LOST", "the pages drown in static")
assert(not surfaces.holo.visible and exported.isJammed(), "no holo GPS while the map is jammed")
assert(lastEvent("op77_map3d:jammed") == true)
invoking = "intruder"
assert(not exported.unjam(jamId), "another resource cannot lift it")
invoking = "rp_scrambler"
assert(exported.unjam(jamId) and lastPage("map3d:jam").strength == 0 and surfaces.holo.visible)
local zoneId = assert(exported.addJamZone({ position = { x = 100, y = 200 }, radius = 30, strength = 0.5, label = "NO MAP" }))
runThreads(2) -- the player feed puts the player at (100, 200): inside
assert(lastPage("map3d:jam").strength == 0.5 and lastPage("map3d:jam").label == "NO MAP", "a zone around the player jams")
assert(surfaces.holo.visible, "a partial jam keeps the holo")
assert(not exported.addJamZone({ strength = 1 }), "a zone needs a position and a radius")
handlers.onClientResourceStop("rp_scrambler")
assert(lastPage("map3d:jam").strength == 0 and not exported.isJammed(), "a stopping resource takes its jams along")
netHandlers["op77_map3d:jams"]({ upsert = { { id = "srv:x:j", strength = 1 } } })
assert(lastPage("map3d:jam").strength == 1, "the server's jams count too")
netHandlers["op77_map3d:jams"]({ remove = { "srv:x:j" } })
assert(lastPage("map3d:jam").strength == 0)
miniHandlers["map3d:holo"]({ clear = true, pts = {} })
-- another interface takes the cursor (inventory, F1 menu): the minimap steps aside
assert(surfaces.mini.visible)
otherCursor = true
runThreads(3)
assert(not surfaces.mini.visible, "an inventory or a menu hides the minimap")
otherCursor = false
runThreads(3)
assert(surfaces.mini.visible, "and it comes back when it closes")
-- the pause menu's CITY MAP
handlers["open77:mapProvider:show"]({ provider = "someone_else", requestId = "map:0" })
assert(not exported.isOpen(), "another provider's request is not ours")
handlers["open77:mapProvider:show"]({ provider = "op77_map3d", requestId = "map:1" })
assert(exported.isOpen() and lastEvent("open77:mapProvider:shown").requestId == "map:1", "opened and answered")
pageHandlers["map3d:close"]({})
events = {}
handlers["open77:mapProvider:query"]()
assert(lastEvent("open77:mapProvider:register"), "announces itself again when the menu asks")
-- moving the minimap recreates its cropped surface
local oldMini = surfaces.mini
exported.setConfig({ minimap = { anchor = "bottom-left" } })
runThreads(1)
assert(oldMini.destroyed and surfaces.mini ~= oldMini and surfaces.mini.options.drawBounds.x == 0 and surfaces.mini.options.drawBounds.y < 0)
miniHandlers = surfaces.mini.handlers
miniHandlers["map3d:ready"]({})
-- runtime config survives a page reload
exported.setTheme({ accent = "#3FE0D0" })
pageSent = {}
pageHandlers["map3d:hello"]({})
local patches = 0
for _, s in ipairs(pageSent) do if s.name == "map3d:config" then patches = patches + 1 end end
assert(patches == 3, "base config, then the runtime minimap and theme patches")
-- server blips
netHandlers["op77_map3d:blips"]({ set = { { id = "srv:x:1", x = 9, y = 9, label = "Garage" } } })
assert(lastPage("map3d:blips").upsert[1].id == "srv:x:1")
handlers.onClientResourceStop("op77_map3d")
assert(blocked == false and hudMinimap == true, "the native map and minimap come back")
assert(lastEvent("open77:mapProvider:withdraw").resource == "op77_map3d", "withdrawn from the pause menu on stop")

-- ---------------------------------------------------------------- server
local sHandlers, sNet, sExports, toClient = {}, {}, {}, {}
_G.AddEventHandler = function(name, fn) sHandlers[name] = fn end
_G.RegisterNetEvent = function(name, fn) sNet[name] = fn end
_G.exports = function(name, fn) sExports[name] = fn end
_G.GetPlayers = function() return { "1", "2" } end
_G.TriggerClientEvent = function(name, target, payload) toClient[#toClient + 1] = { name = name, target = target, payload = payload } end
local sCommands = {}
_G.RegisterCommand = function(name, fn, restricted) assert(restricted, name .. " is staff only"); sCommands[name] = fn end
dofile("server/main.lua")
invoking = "jobs"
local all = assert(sExports.addBlip(-1, { id = "depot", x = 1, y = 1, label = "Depot" }))
assert(all == "srv:jobs:depot" and #toClient == 2, "everyone gets it")
toClient = {}
local mine = assert(sExports.addBlip(2, { x = 5, y = 5, label = "Your car" }))
assert(#toClient == 1 and toClient[1].target == 2)
toClient = {}
_G.source = 1; sNet["op77_map3d:hello"]()
assert(#toClient[1].payload.set == 1 and toClient[1].payload.set[1].id == all, "a late joiner gets only what is meant for it")
toClient = {}
_G.source = 2; sNet["op77_map3d:hello"]()
assert(#toClient[1].payload.set == 2)
invoking = "other"
assert(not sExports.updateBlip(all, { label = "x" }), "only the owner updates")
toClient = {}
sHandlers.onResourceStop("jobs")
assert(#toClient == 3, "the owner stops: removed for everyone it was shown to")
assert(sExports.setWaypoint(2, { x = 1, y = 2 }) and toClient[#toClient].name == "op77_map3d:waypoint")
-- server jams: everyone gets them, late joiners too, the owner's stop lifts them
invoking = "blackout"
toClient = {}
local sj = assert(sExports.addJamZone(-1, { id = "zone", position = { x = 0, y = 0 }, radius = 500, label = "NO SIGNAL" }))
assert(sj == "srv:blackout:zone" and #toClient == 2 and toClient[1].name == "op77_map3d:jams" and toClient[1].payload.upsert[1].radius == 500)
assert(not sExports.addJamZone(-1, { strength = 1 }), "a server zone needs a position and a radius")
toClient = {}
_G.source = 1; sNet["op77_map3d:hello"]()
local jamSync
for _, e in ipairs(toClient) do if e.name == "op77_map3d:jams" then jamSync = e.payload end end
assert(jamSync and #jamSync.set == 1 and jamSync.set[1].id == sj, "a late joiner gets the jams meant for it")
toClient = {}
sHandlers.onResourceStop("blackout")
assert(#toClient == 2 and toClient[1].payload.remove[1] == sj, "the owner stops: lifted for everyone")
-- staff commands
toClient = {}
sCommands["map3d.jam"](0, { "2", "0.6", "NO", "MAP", n = 4 })
assert(#toClient == 1 and toClient[1].target == 2 and toClient[1].payload.upsert[1].strength == 0.6 and toClient[1].payload.upsert[1].label == "NO MAP")
toClient = {}
sCommands["map3d.unjam"](0, { n = 0 })
assert(#toClient == 1 and toClient[1].payload.remove[1], "unjam lifts the command's jams")
print("PASS: map3d blips (validation, owners, cleanup), page lifecycle, waypoint mirror both ways, open/close focus, runtime config replay, server targets and late joiners")
