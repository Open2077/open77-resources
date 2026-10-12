-- rp_fixer client: map presentation only. It never sends anything to the server: the board,
-- the hand-over and the crate are open77_actions prompts, every decision is the server's.
--
--   rp_fixer:hubs        the fixer points -> one map pin each
--   rp_fixer:objectives  the runner's objectives -> one map pin each, the GPS routed to the first

local hubBlips = {}
local objectiveBlips = {}
local routed = false

local function log(fmt, ...) print(("[rp_fixer] " .. fmt):format(...)) end

local function clear(list)
    for i = #list, 1, -1 do
        pcall(Open77.blips.remove, list[i])
        list[i] = nil
    end
end

local function pin(position, sprite, title, description)
    local ok, id, why = pcall(Open77.blips.create, { position = position, sprite = sprite, title = title,
        description = description })
    if ok and id then return id end
    log("map pin %s refused: %s", tostring(title), tostring(ok and why or id))
    return nil
end

RegisterNetEvent("rp_fixer:hubs", function(hubs)
    clear(hubBlips)
    if type(hubs) ~= "table" then return end
    for _, h in ipairs(hubs) do
        if type(h) == "table" and type(h.position) == "table" then
            local id = pin(h.position, "FixerVariant", tostring(h.label), ("%s. Contracts on the board."):format(tostring(h.fixer)))
            if id then hubBlips[#hubBlips + 1] = id end
        end
    end
end)

RegisterNetEvent("rp_fixer:objectives", function(list)
    clear(objectiveBlips)
    if type(list) ~= "table" or #list == 0 then
        if routed then
            pcall(Open77.blips.clearWaypoint)
            routed = false
        end
        return
    end
    for _, o in ipairs(list) do
        if type(o) == "table" and type(o.position) == "table" then
            local id = pin(o.position, o.sprite or "objective", tostring(o.title), tostring(o.label))
            if id then objectiveBlips[#objectiveBlips + 1] = id end
        end
    end
    local first = list[1]
    if type(first) == "table" and type(first.position) == "table" then
        local ok, done, why = pcall(Open77.blips.setWaypoint, first.position)
        if ok and done then routed = true else log("waypoint refused: %s", tostring(ok and why or done)) end
    end
end)

AddEventHandler("onClientResourceStop", function(name)
    if name ~= GetCurrentResourceName() then return end
    clear(hubBlips)
    clear(objectiveBlips)
end)
