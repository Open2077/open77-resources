-- Blip definitions, checked the same way on both sides. A blip is a point on the
-- 3D map and the minimap:
--   { position = { x, y, z }, icon = "store", color = "#FFCC00", label = "24/7",
--     description = "...", category = "service", scale = 1.0, map = true,
--     minimap = true, edge = false, pulse = false, heading = nil, routable = true,
--     priority = 0 }
-- icon: a built-in name (pin, user, car, store, briefcase, target, home, flag, star,
-- skull, shield, police, hospital, fuel, wrench, shirt, gun, phone, dollar, bed,
-- food, info, warning, garage, crosshair, waypoint, bank, mission, bus), inline
-- "<svg ...>" markup, or an image URL the page can load.
Map3DBlip = {}
local B = Map3DBlip

local function num(v, lo, hi)
    v = tonumber(v)
    if not v or v ~= v or v == math.huge or v == -math.huge then return nil end
    if lo and v < lo then v = lo end
    if hi and v > hi then v = hi end
    return v
end
local function str(v, max)
    if v == nil then return nil end
    v = tostring(v)
    if #v > max then v = v:sub(1, max) end
    return v
end
local function color(v)
    if type(v) ~= "string" then return nil end
    if v:match("^#%x%x%x%x%x%x$") or v:match("^#%x%x%x%x%x%x%x%x$") or v:match("^#%x%x%x$") then return v end
    return nil
end

-- A clean copy of def, or nil and the reason.
function B.normalize(def)
    if type(def) ~= "table" then return nil, "definition must be a table" end
    local p = def.position or def.coords or def
    local x, y = num(p.x), num(p.y)
    if not x or not y then return nil, "position {x, y[, z]} required" end
    local icon = def.icon
    if icon ~= nil and type(icon) ~= "string" then return nil, "icon must be a string" end
    if icon and #icon > 16384 then return nil, "icon too large" end
    return {
        x = x, y = y, z = num(p.z) or 0,
        icon = icon,
        color = color(def.color),
        label = str(def.label or def.title, 96),
        description = str(def.description, 512),
        category = str(def.category, 48) or "default",
        scale = num(def.scale, 0.3, 3),
        map = def.map ~= false,
        minimap = def.minimap ~= false,
        edge = def.edge == true,
        pulse = def.pulse == true,
        heading = num(def.heading),
        routable = def.routable ~= false,
        priority = num(def.priority, 0, 2),
    }
end

-- Fields of patch merged into blip (only the ones given); nil and a reason if invalid.
function B.patch(blip, patch)
    if type(patch) ~= "table" then return nil, "patch must be a table" end
    local merged = {}
    for k, v in pairs(blip) do merged[k] = v end
    local pos = patch.position or patch.coords
    if not pos and (patch.x or patch.y or patch.z) then pos = { x = patch.x or blip.x, y = patch.y or blip.y, z = patch.z or blip.z } end
    merged.position = pos or { x = blip.x, y = blip.y, z = blip.z }
    for k, v in pairs(patch) do if k ~= "position" and k ~= "coords" then merged[k] = v end end
    if patch.color == false then merged.color = nil end
    if patch.heading == false then merged.heading = nil end
    return B.normalize(merged)
end

