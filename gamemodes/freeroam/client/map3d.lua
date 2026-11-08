-- The 3D city map (op77_map3d), when the server runs it: freeroam's blue theme
-- and the freeroam destinations / spawn points as its blips. The map is
-- optional and never a dependency: every call is guarded, and nothing here
-- does anything while op77_map3d is absent or stopped.
--
-- The theme goes once per run of the map (it keeps runtime patches and replays
-- them when its pages reload); the blips use stable ids, so sending them again
-- on op77_map3d:ready (map restarted) replaces them instead of duplicating.

FreeroamMap3D = {}
local M = FreeroamMap3D
local Config = FreeroamConfig
local MAP = "op77_map3d"

local applied = false -- the theme reached this run of op77_map3d

local function settings() return Config.map3d or {} end

function M.enabled() return settings().enabled ~= false end

-- GetResourceState answers "running" (older builds: "started").
function M.running()
    if type(GetResourceState) ~= "function" then return false end
    local ok, state = pcall(GetResourceState, MAP)
    return ok and (state == "running" or state == "started")
end

local function call(method, ...)
    if not M.running() or (type(exports) ~= "table" and type(exports) ~= "userdata") then return false end
    local args = table.pack(...)
    return pcall(function()
        local map = exports[MAP]
        return map[method](map, table.unpack(args, 1, args.n))
    end)
end

-- The setConfig patch: theme, legend and title.
function M.patch()
    local s = settings()
    return {
        theme = s.theme,
        categories = s.categories,
        map = { title = s.title, subtitle = s.subtitle },
    }
end

local function categoryColor(id)
    for _, row in ipairs(settings().categories or {}) do
        if row.id == id then return row.color, row.icon end
    end
    return nil, nil
end

local function blip(id, category, position, label, description)
    local color, icon = categoryColor(category)
    return {
        id = id, position = position, icon = icon or "pin", color = color,
        label = label, description = description, category = category,
    }
end

-- The same places as the game map's blips (client/main.lua createBlips).
function M.blips()
    local list = {}
    if not (Config.blips and Config.blips.enabled) then return list end
    local s = settings()
    for _, location in ipairs((Config.teleport or {}).locations or {}) do
        list[#list + 1] = blip("location:" .. location.name, s.locationCategory or "destination",
            location.position, location.label,
            ("Freeroam destination. /goto %s"):format(location.name))
    end
    if Config.blips.showSpawns then
        for _, point in ipairs((Config.spawn or {}).points or {}) do
            list[#list + 1] = blip("spawn:" .. point.name, s.spawnCategory or "spawn",
                point.position, point.label or point.name,
                ("Freeroam spawn point. /spawn %s"):format(point.name))
        end
    end
    return list
end

-- Theme (once per map run) and blips (every time: keyed, so idempotent).
function M.apply()
    if not M.enabled() or not M.running() then return false end
    if not applied then
        local ok, done = call("setConfig", M.patch())
        applied = ok and done ~= false
        if not ok then print("[freeroam] op77_map3d theme refused: " .. tostring(done)) end
    end
    local sent = 0
    for _, def in ipairs(M.blips()) do
        local ok, id = call("addBlip", def)
        if ok and id then sent = sent + 1 end
    end
    return applied, sent
end

-- The map's page is up (first start, or op77_map3d restarted).
AddEventHandler("op77_map3d:ready", function() M.apply() end)

AddEventHandler("onClientResourceStart", function(name)
    if name == MAP then
        applied = false
    elseif name == GetCurrentResourceName() then
        M.apply()
    end
end)

-- A stopped map forgets its patches and the blips: send them again next run.
AddEventHandler("onClientResourceStop", function(name)
    if name == MAP then applied = false end
end)
