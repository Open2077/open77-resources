-- Map jamming: the map and minimap drown in static ("NO SIGNAL") where there is no map
-- to show: an unmapped place, a custom zone, an RP action or interaction. A jam is either
-- direct (on while it exists) or a zone (a circle, full inside, fading over `fade` metres
-- outside). Several jams combine: the strongest wins. Checked the same way on both sides.
Map3DJam = {}
local J = Map3DJam

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

-- { strength = 0..1 (1: nothing of the map is left), label = "NO SIGNAL",
--   zone: position = { x, y } (or x, y), radius, fade }
function J.normalize(def)
    if def ~= nil and type(def) ~= "table" then return nil, "a jam is a table" end
    def = def or {}
    local j = {
        strength = clamp(tonumber(def.strength) or 1, 0, 1),
        label = type(def.label) == "string" and def.label:sub(1, 48) or nil,
    }
    local pos = type(def.position) == "table" and def.position or def
    if def.radius ~= nil then
        local x, y, r = tonumber(pos.x), tonumber(pos.y), tonumber(def.radius)
        if not x or not y or not r then return nil, "a jam zone needs a position {x, y} and a radius" end
        j.zone, j.x, j.y = true, x, y
        j.radius = clamp(r, 1, 20000)
        j.fade = clamp(tonumber(def.fade) or 60, 0, 5000)
    end
    return j
end

--- How strong a jam is at a position (a direct jam is the same everywhere).
function J.at(j, x, y)
    if not j.zone then return j.strength end
    if not x then return 0 end
    local d = math.sqrt((x - j.x) ^ 2 + (y - j.y) ^ 2)
    if d <= j.radius then return j.strength end
    if j.fade <= 0 or d >= j.radius + j.fade then return 0 end
    return j.strength * (1 - (d - j.radius) / j.fade)
end
