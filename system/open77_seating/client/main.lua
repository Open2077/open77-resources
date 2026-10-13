-- =============================================================================
-- open77_seating -- client/main.lua
-- =============================================================================
-- Presentation only. This half:
--   * turns the server's short list of nearby seats (at most three, within
--     3 m, chosen and filtered on the server) into open77_interactions
--     prompts, and a chosen prompt into the minimum intent (a furniture id);
--   * offers a rebindable "stand up" key while the server says the player
--     is seated;
--   * says why a request was refused.
--
-- It never decides anything: no pose, no distance, no occupancy and no world
-- query (a world query costs hundreds of milliseconds in a crowd). It holds no
-- control or camera claim either: the workspot holds the body while it plays
-- and the platform restores the view when the playback ends.
-- =============================================================================

local RESOURCE = GetCurrentResourceName()
local STAND_KEY_ID = "open77_seating_stand"

local state = {
    generation = nil,
    seats = {},            -- [id] = seat as sent by the server
    live = {},             -- [id] = { handle, signature }
    seated = false,
    running = true,
    dirty = false,
}

local function interactions(name, ...)
    local promise, reason = Open77.exports.call("open77_interactions", name, ...)
    if not promise then return nil, reason end
    return promise:await()
end

local function notify(text)
    if Open77.hud and Open77.hud.notify then
        pcall(Open77.hud.notify, text, { replace = true })   -- generic: the vanilla action_blocked preset drops the text
    else
        print("[seating] " .. text)
    end
end

-- A message from another server generation: what this client held is void.
local function accept(payload)
    if type(payload) ~= "table" then return false end
    if state.generation ~= nil and payload.generation ~= state.generation then
        if type(payload.generation) == "number" and type(state.generation) == "number" and
            payload.generation < state.generation then
            return false
        end
        state.seats, state.seated, state.dirty = {}, false, true
    end
    state.generation = payload.generation
    return true
end

local REFUSALS = {
    seat_taken = "Someone is already sitting there.",
    target_claimed = "This seat is in use.",
    npc_occupied = "Someone is already sitting there.",
    too_far = "Too far away.",
    already_seated = "You are already seated.",
    not_seated = "You are not seated.",
    actor_busy = "Finish what you are doing first.",
    in_combat = "Not while fighting.",
    player_in_vehicle = "Not from a vehicle.",
    no_playable_pose = "There is no free seat here.",
    approach_blocked = "Something is in the way.",
    approach_failed = "You cannot get there.",
    indexing = "Seats are not ready yet.",
}

RegisterNetEvent("open77:seating:refused", function(payload)
    if not accept(payload) then return end
    local reason = tostring(payload.reason)
    notify(REFUSALS[reason] or ("Refused: " .. reason))
end)

RegisterNetEvent("open77:seating:state", function(payload)
    if not accept(payload) then return end
    local was = state.seated
    state.seated = payload.seated == true
    if state.seated then
        state.seats, state.dirty = {}, true
        if not was then
            local key = Open77.input and Open77.input.keyFor and Open77.input.keyFor(STAND_KEY_ID) or "X"
            notify(("Press %s to stand up"):format(tostring(key or "X")))
        end
    elseif was and payload.reason ~= nil and payload.reason ~= "stood" and payload.reason ~= "cancelled_by_player" then
        notify("You stood up: " .. tostring(payload.reason))
    end
end)

RegisterNetEvent("open77:seating:seats", function(payload)
    if not accept(payload) then return end
    local seats = {}
    for _, seat in ipairs(type(payload.seats) == "table" and payload.seats or {}) do
        if type(seat) == "table" and type(seat.id) == "string" and type(seat.position) == "table" then
            seats[seat.id] = seat
        end
    end
    state.seats, state.dirty = seats, true
end)

-- ---------------------------------------------------------------------------
-- Seats -> prompts (at most the three the server sent; nothing is ranked here)
-- ---------------------------------------------------------------------------
local function signature(seat)
    local p = seat.position
    return table.concat({ seat.id, tostring(p.x), tostring(p.y), tostring(p.z), tostring(seat.label) }, "|")
end

-- The card is lifted above the seat and live whenever the player is in reach and the card is
-- on screen, as open77_actions does: open77_interactions otherwise requires the crosshair on
-- the card (requireLookAt), and a card at mattress or seat height sits at the bottom of the
-- screen where E never reached it (a bed prompt was drawn, and E did nothing). The reach is
-- measured to the lifted point, hence the hypotenuse.
local PROMPT_LIFT = 0.8
local PROMPT_REACH = 2.0

local function promptDefinition(seat)
    return {
        id = ("seat:" .. seat.id):sub(1, 96),
        position = seat.position, offset = { x = 0.0, y = 0.0, z = PROMPT_LIFT },
        distance = math.sqrt(PROMPT_REACH * PROMPT_REACH + PROMPT_LIFT * PROMPT_LIFT),
        markerDistance = 4.0, marker = "dot", requireLookAt = false,
        priority = 5,
        choices = { {
            id = "sit", label = seat.label or "Sit", key = "E",
            event = "open77_seating:choice", data = { furniture = seat.id },
        } },
    }
end

local function sync()
    if not state.dirty then return end
    state.dirty = false
    local wanted = state.seated and {} or state.seats
    for id, entry in pairs(state.live) do
        local seat = wanted[id]
        if seat == nil or signature(seat) ~= entry.signature then
            state.live[id] = nil
            if entry.handle then interactions("remove", entry.handle) end
        end
    end
    for id, seat in pairs(wanted) do
        if state.live[id] == nil then
            local answer = interactions("create", promptDefinition(seat))
            if type(answer) == "table" and answer.ok then
                state.live[id] = { handle = answer.handle, signature = signature(seat) }
            end
        end
    end
end

AddEventHandler("open77_seating:choice", function(payload)
    if type(payload) ~= "table" or payload.owner ~= RESOURCE or type(payload.data) ~= "table" then return end
    if state.seated then return end
    TriggerServerEvent("open77:seating:sit", payload.data.furniture)
end)

-- ---------------------------------------------------------------------------
-- The stand-up key (rebindable from Pause -> Settings -> KEY BINDINGS)
-- ---------------------------------------------------------------------------
pcall(Open77.input.registerKeyMapping, {
    id = STAND_KEY_ID, name = "Stand up from a seat", key = "X",
    onPressed = function()
        if state.seated then TriggerServerEvent("open77:seating:stand") end
    end,
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
    TriggerServerEvent("open77:seating:sync")
    while state.running do
        local ok, err = pcall(sync)
        if not ok then print("[seating] prompt sync raised: " .. tostring(err)) end
        Wait(250)
    end
end)
