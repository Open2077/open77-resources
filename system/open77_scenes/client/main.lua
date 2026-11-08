-- =============================================================================
-- open77_scenes -- client/main.lua
-- =============================================================================
-- Presentation only: the server's short list of nearby scene spots becomes
-- open77_interactions prompts ("Lie down"), a chosen prompt becomes the minimum
-- intent (a spot id), and while the server says a scene runs two rebindable
-- keys ask to get up or to change pose. The playback itself -- device, camera,
-- other players' view -- belongs to the platform's RP animation service.
-- No setmetatable here: the client Lua sandbox has none.
-- =============================================================================

local RESOURCE = GetCurrentResourceName()
local STAND_KEY = "open77_scenes_stand"
local POSE_KEY = "open77_scenes_pose"

local state = { generation = nil, spots = {}, live = {}, active = false, running = true, dirty = false, scene = nil,
    endedAt = -math.huge }

local function interactions(name, ...)
    local promise, reason = Open77.exports.call("open77_interactions", name, ...)
    if not promise then return nil, reason end
    return promise:await()
end

local function notify(text)
    if Open77.hud and Open77.hud.notify then
        pcall(Open77.hud.notify, text, { replace = true })
    else
        print("[scenes] " .. text)
    end
end

local function keyName(id, fallback)
    local ok, key = pcall(function() return Open77.input.keyFor and Open77.input.keyFor(id) end)
    return ok and key or fallback
end

local function accept(payload)
    if type(payload) ~= "table" then return false end
    if state.generation ~= nil and payload.generation ~= state.generation then
        if type(payload.generation) == "number" and type(state.generation) == "number" and payload.generation < state.generation then
            return false
        end
        state.spots, state.active, state.dirty = {}, false, true
    end
    state.generation = payload.generation
    return true
end

local REFUSALS = {
    spot_taken = "Someone is already there.",
    too_far = "Too far away.",
    already_in_scene = "You are already in a scene.",
    not_in_scene = "You are not in a scene.",
    scene_busy = "Wait a moment.",
    actor_busy = "Finish what you are doing first.",
    player_in_vehicle = "Not from a vehicle.",
    player_not_alive = "Not now.",
    no_spot = "Nothing to use here.",
    unknown_spot = "This place is not available.",
}

RegisterNetEvent("open77:scenes:refused", function(payload)
    if not accept(payload) then return end
    local reason = tostring(payload.reason)
    -- A get-up key pressed as the scene ended another way (an animation card's Stop, a step):
    -- nothing to say.
    if reason == "not_in_scene" and Open77.time.monotonic() - state.endedAt < 3 then return end
    notify(REFUSALS[reason] or ("Refused: " .. reason))
end)

RegisterNetEvent("open77:scenes:state", function(payload)
    if not accept(payload) then return end
    local was = state.active
    state.active, state.scene = payload.active == true, payload.active == true and payload or nil
    if state.active then
        state.spots, state.dirty = {}, true
        if not was then
            local idles = type(payload.idles) == "table" and #payload.idles or 1
            local text = ("Press %s to get up"):format(tostring(keyName(STAND_KEY, "H")))
            if idles > 1 then text = text .. (", %s to change pose"):format(tostring(keyName(POSE_KEY, "G"))) end
            notify(text)
        end
    elseif was then
        state.dirty, state.endedAt = true, Open77.time.monotonic()
        local reason = payload.reason
        if reason ~= nil and reason ~= "stood" and reason ~= "cancelled" and reason ~= "moved" then
            notify("Scene ended: " .. tostring(reason))
        end
    end
end)

RegisterNetEvent("open77:scenes:spots", function(payload)
    if not accept(payload) then return end
    local spots = {}
    for _, spot in ipairs(type(payload.spots) == "table" and payload.spots or {}) do
        if type(spot) == "table" and type(spot.id) == "string" and type(spot.position) == "table" then spots[spot.id] = spot end
    end
    state.spots, state.dirty = spots, true
end)

-- ---------------------------------------------------------------------------
-- Spots -> prompts
-- ---------------------------------------------------------------------------
local PROMPT_REACH = 2.5

local function signature(spot)
    local p = spot.position
    return table.concat({ spot.id, tostring(p.x), tostring(p.y), tostring(p.z), tostring(spot.label) }, "|")
end

local function promptDefinition(spot)
    return {
        -- open77_interactions ids are [%w_:%-.] only (a spot id carries "@"): the real id rides in `data`.
        id = ("scene:" .. (spot.id:gsub("[^%w_:%-%.]", "_"))):sub(1, 96),
        position = spot.position, offset = { x = 0.0, y = 0.0, z = 0.0 },
        distance = PROMPT_REACH + 1.0, markerDistance = 5.0, marker = "dot", requireLookAt = false,
        priority = 5, title = spot.title,
        choices = { {
            id = "use", label = spot.label or "Use", key = "E",
            event = "open77_scenes:choice", data = { spot = spot.id },
        } },
    }
end

local function sync()
    if not state.dirty then return end
    state.dirty = false
    local wanted = state.active and {} or state.spots
    for id, entry in pairs(state.live) do
        local spot = wanted[id]
        if spot == nil or signature(spot) ~= entry.signature then
            state.live[id] = nil
            if entry.handle then interactions("remove", entry.handle) end
        end
    end
    for id, spot in pairs(wanted) do
        if state.live[id] == nil then
            local answer, reason = interactions("create", promptDefinition(spot))
            if type(answer) == "table" and answer.ok then
                state.live[id] = { handle = answer.handle, signature = signature(spot) }
            else
                print(("[scenes] prompt for %s refused: %s"):format(id,
                    tostring(type(answer) == "table" and answer.error or reason)))
            end
        end
    end
end

AddEventHandler("open77_scenes:choice", function(payload)
    if type(payload) ~= "table" or payload.owner ~= RESOURCE or type(payload.data) ~= "table" then return end
    if state.active then return end
    TriggerServerEvent("open77:scenes:start", payload.data.spot)
end)

-- ---------------------------------------------------------------------------
-- Keys (rebindable from Pause -> Settings -> KEY BINDINGS). Not X: the animation cards of the
-- gamemodes (Freeroam, LightRP) bind X to "Stop", which ends the playback at once, without the
-- get-up (live, 2026-10-30).
-- ---------------------------------------------------------------------------
pcall(Open77.input.registerKeyMapping, {
    id = STAND_KEY, name = "Get up (scene)", key = "H",
    onPressed = function() if state.active then TriggerServerEvent("open77:scenes:stand") end end,
})
pcall(Open77.input.registerKeyMapping, {
    id = POSE_KEY, name = "Change pose (scene)", key = "G",
    onPressed = function() if state.active then TriggerServerEvent("open77:scenes:idle") end end,
})

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------
AddEventHandler("onClientResourceStop", function(name)
    if name ~= RESOURCE then return end
    state.running = false
    pcall(Open77.exports.callSync, "open77_interactions", "clear")
end)

CreateThread(function()
    Wait(1000)
    TriggerServerEvent("open77:scenes:sync")
    while state.running do
        local ok, err = pcall(sync)
        if not ok then print("[scenes] prompt sync raised: " .. tostring(err)) end
        Wait(250)
    end
end)
