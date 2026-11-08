-- client/map3d.lua: freeroam's theme and blips on op77_map3d (optional map).
local T, M, C = Map3DTest, FreeroamMap3D, FreeroamConfig

local function count(method)
    local n = 0
    for _, c in ipairs(T.calls) do if c.method == method then n = n + 1 end end
    return n
end
local function reset() T.calls = {} end

-- The patch: the blue theme, the legend and the title, straight from the config.
local patch = M.patch()
assert(patch.theme == C.map3d.theme and patch.categories == C.map3d.categories, "patch carries the config tables")
assert(patch.theme.accent == "#22d8e2" and patch.theme.buildingEdge == "#22d8e2", "freeroam cyan accent")
assert(patch.theme.background == "#0b0e14", "freeroam ink background")
assert(patch.map.title == "NIGHT CITY" and patch.map.subtitle == "FREEROAM", "map title")
for key, value in pairs(patch.theme) do
    assert(type(value) == "string" and (value:match("^#%x%x%x%x%x%x$") or value:match("^rgba%(")),
        "theme." .. key .. " is a CSS colour")
end

-- The blips: every destination and spawn point, stable ids, category colour and icon.
local blips = M.blips()
assert(#blips == #C.teleport.locations + #C.spawn.points, "one blip per destination and spawn")
local ids = {}
for _, b in ipairs(blips) do
    assert(not ids[b.id], "unique id " .. b.id)
    ids[b.id] = true
    assert(type(b.position.x) == "number" and type(b.position.y) == "number", "position " .. b.id)
    assert(b.label and b.description and b.icon and b.color, "complete blip " .. b.id)
end
local first = blips[1]
assert(first.id == "location:" .. C.teleport.locations[1].name and first.category == "destination", "destination id")
assert(first.icon == "flag" and first.color == "#22d8e2", "destination row icon and colour")
local spawn = blips[#blips]
assert(spawn.id == "spawn:" .. C.spawn.points[1].name and spawn.icon == "star" and spawn.color == "#2be58b", "spawn row")

-- The map's own switches.
C.blips.showSpawns = false
assert(#M.blips() == #C.teleport.locations, "showSpawns off: destinations only")
C.blips.showSpawns = true
C.blips.enabled = false
assert(#M.blips() == 0, "blips off: none on the map either")
C.blips.enabled = true

-- Without the map: nothing is called, freeroam starts normally.
T.state = "missing"
T.fire("onClientResourceStart", "freeroam")
assert(#T.calls == 0, "no export call while op77_map3d is absent")
T.state = "stopped"
T.fire("op77_map3d:ready")
assert(#T.calls == 0, "no export call while op77_map3d is stopped")

-- Freeroam starts after the map: theme once, every blip.
T.state = "running"
T.fire("onClientResourceStart", "freeroam")
assert(count("setConfig") == 1 and count("addBlip") == #blips, "theme and blips at freeroam start")
local sent = T.calls[1].args[1]
assert(sent.theme.accent == "#22d8e2" and sent.map.subtitle == "FREEROAM", "setConfig got the patch")

-- The map's page reloads: its own replay keeps the theme, blips are re-sent (keyed).
reset()
T.fire("op77_map3d:ready")
assert(count("setConfig") == 0, "the theme is not stacked again on the same map run")
assert(count("addBlip") == #blips, "blips sent again by id")

-- The map restarts: it forgot everything, the next ready re-applies it all.
reset()
T.fire("onClientResourceStop", "op77_map3d")
T.state = "starting"
T.fire("onClientResourceStart", "op77_map3d")
T.fire("op77_map3d:ready") -- not running yet: ignored
assert(#T.calls == 0, "nothing sent to a map still starting")
T.state = "running"
T.fire("op77_map3d:ready")
assert(count("setConfig") == 1 and count("addBlip") == #blips, "theme and blips after a map restart")

-- A failing export never breaks freeroam; the theme is retried on the next ready.
reset()
T.fire("onClientResourceStop", "op77_map3d")
T.fail = true
T.fire("op77_map3d:ready")
assert(count("setConfig") == 1, "tried")
assert(T.printed[#T.printed]:find("theme refused", 1, true), "failure logged")
T.fail = false
reset()
T.fire("op77_map3d:ready")
assert(count("setConfig") == 1, "retried after a failure")

-- Disabled in the config: nothing at all.
reset()
T.fire("onClientResourceStop", "op77_map3d")
C.map3d.enabled = false
T.fire("op77_map3d:ready")
assert(#T.calls == 0, "map3d.enabled = false")
C.map3d.enabled = true
