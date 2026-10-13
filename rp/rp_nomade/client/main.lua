-- rp_nomade / client: navigation only. Every prompt, bar and carry is drawn by open77_actions;
-- this script draws what the server says about the player's run on the map:
--   * a pin on the destination from the start of the run, the vanilla GPS route once the crates
--     are in a truck (or at once, per the server's config);
--   * a pin and route back to the camp when the run is off with goods still out;
--   * a pin on each NCPD checkpoint while a run goes on.
-- Nothing here decides anything: the server pushes `rp_nomade:nav` (false clears it).

local RESOURCE = GetCurrentResourceName()

local nav = { blip = nil, waypoint = false, checkpoints = {}, sig = nil }
local NONE = {}
local pending = NONE

local function log(fmt, ...) print(("[rp_nomade] " .. fmt):format(...)) end

local function blipsApi()
    return type(Open77.blips) == "table" and type(Open77.blips.create) == "function"
end

local function clear()
    if not blipsApi() then return end
    if nav.blip then
        Open77.blips.remove(nav.blip)
        nav.blip = nil
    end
    for _, id in ipairs(nav.checkpoints) do Open77.blips.remove(id) end
    nav.checkpoints = {}
    if nav.waypoint then
        Open77.blips.clearWaypoint()
        nav.waypoint = false
    end
    nav.sig = nil
end

local function signature(state)
    if not state then return "none" end
    return table.concat({ tostring(state.run), tostring(state.phase), tostring(state.route) }, "|")
end

local warned = false
local function apply(state)
    if not blipsApi() then
        if not warned then
            warned = true
            log("navigation off: Open77.blips is not available on this client (permission ui.vanilla.map)")
        end
        return
    end
    local sig = signature(state)
    if sig ~= nav.sig then clear() end
    if not state then return end
    local target = state.target
    if not nav.blip then
        local blip, why = Open77.blips.create({
            position = { x = target.x, y = target.y, z = target.z },
            sprite = state.sprite or "objective", title = state.title or "Nomad run",
            description = state.description or "",
        })
        if blip then nav.blip = blip else log("navigation pin refused: %s", tostring(why)) end
        for _, ck in ipairs(state.checkpoints or {}) do
            local id, cwhy = Open77.blips.create({ position = { x = ck.x, y = ck.y, z = ck.z },
                sprite = state.checkpointSprite or "HazardWarningVariant", title = ck.label,
                description = "NCPD checkpoint: they may search the truck." })
            if not id and state.checkpointSprite then
                id, cwhy = Open77.blips.create({ position = { x = ck.x, y = ck.y, z = ck.z }, sprite = "quest",
                    title = ck.label, description = "NCPD checkpoint: they may search the truck." })
            end
            if id then nav.checkpoints[#nav.checkpoints + 1] = id else log("checkpoint pin refused: %s", tostring(cwhy)) end
        end
    elseif state.description then
        Open77.blips.setDescription(nav.blip, state.description)
    end
    if state.route and not nav.waypoint then
        local ok, why = Open77.blips.setWaypoint({ x = target.x, y = target.y, z = target.z })
        if ok then nav.waypoint = true else log("GPS route refused: %s", tostring(why)) end
    end
    nav.sig = sig
end

-- One worker applies states in order; the latest one wins when several arrive at once. A blip
-- refusal must never kill the loop (a CreateThread loop that raises is gone for the session).
CreateThread(function()
    while true do
        if pending ~= NONE then
            local state = pending
            pending = NONE
            local ok, err = pcall(apply, state or nil)
            if not ok then log("navigation failed: %s", tostring(err)) end
        end
        Wait(100)
    end
end)

RegisterNetEvent("rp_nomade:nav", function(state)
    pending = state or false
end)

AddEventHandler("onClientResourceStart", function(name)
    if name ~= RESOURCE then return end
    TriggerServerEvent("rp_nomade:clientReady")
end)

AddEventHandler("onClientResourceStop", function(name)
    if name ~= RESOURCE then return end
    pcall(clear)
end)
