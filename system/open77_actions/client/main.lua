-- =============================================================================
-- open77_actions -- client/main.lua
-- =============================================================================
-- Presentation only. This half:
--   * turns the server's point targets into open77_interactions prompts, and
--     a chosen prompt into the minimum intent (action, target);
--   * shows the progress bar of the running operation (open77_uikit) and
--     holds the control claims the server asked for (Movement / Attack /
--     jump / walk mode) for exactly as long as the server says;
--   * offers a rebindable "put down" key while carrying.
--
-- It never reports completion. The only things it may say are "I chose this
-- prompt", "put down what I carry" and "cancel my current operation", and the
-- server re-derives everything about each of them.
--
-- Prompt budget: open77_interactions holds at most 32 anchors per owner, and
-- a world query costs hundreds of milliseconds in a crowd (integrator,
-- 2026-10-12). So targets come only from the server registry, and at most
-- MAX_LIVE of them -- the nearest eligible ones -- are live prompts at a time,
-- recycled as the player moves. No world query is ever made here.
-- =============================================================================

local RESOURCE = GetCurrentResourceName()
local MAX_LIVE = 12
local POLL_MS = 500
local PUTDOWN_KEY_ID = "open77_actions_putdown"

local state = {
    generation = nil,
    targets = {},          -- [key] = target as sent by the server
    live = {},             -- [key] = { handle, signature }
    current = nil,         -- { opId, claims, progress }
    carry = nil,           -- { itemId, sessionId, label, claims }
    applied = { move = false, attack = false, jump = false, walkSpeed = nil },
    running = true,
}

local function call(name, ...)
    local promise, reason = Open77.exports.call("open77_uikit", name, ...)
    if not promise then return nil, reason end
    return promise:await()
end

local function interactions(name, ...)
    local promise, reason = Open77.exports.call("open77_interactions", name, ...)
    if not promise then return nil, reason end
    return promise:await()
end

-- The uikit calls that never wait (textUI, hideTextUI, cancelProgress) and the
-- interactions teardown run synchronously: an async call whose promise is
-- dropped unawaited may be released before it runs.
local function now(resource, name, ...)
    return pcall(Open77.exports.callSync, resource, name, ...)
end

local function notify(text)
    if Open77.hud and Open77.hud.notify then
        pcall(Open77.hud.notify, text, { replace = true })   -- generic: the vanilla action_blocked preset drops the text
    else
        print("[actions] " .. text)
    end
end

-- ---------------------------------------------------------------------------
-- Control claims: the union of the running operation's and the carry's.
-- Each lever is a per-resource claim the platform releases on our stop.
-- ---------------------------------------------------------------------------
local function applyClaims()
    local want = { move = false, attack = false, jump = false, walkSpeed = nil }
    for _, source in ipairs({ state.current and state.current.claims, state.carry and state.carry.claims }) do
        if type(source) == "table" then
            want.move = want.move or source.move == true
            want.attack = want.attack or source.attack == true
            want.jump = want.jump or source.jump == true
            if type(source.walkSpeed) == "number" and (want.walkSpeed == nil or source.walkSpeed < want.walkSpeed) then
                want.walkSpeed = source.walkSpeed
            end
        end
    end
    local applied = state.applied
    if want.move ~= applied.move then pcall(Open77.input.setActionBlocked, "Movement", want.move) end
    if want.attack ~= applied.attack then pcall(Open77.input.setActionBlocked, "Attack", want.attack) end
    if want.jump ~= applied.jump then pcall(Open77.players.allowJump, not want.jump) end
    if want.walkSpeed ~= applied.walkSpeed then
        if want.walkSpeed then
            pcall(Open77.movement.setWalkMode, true, want.walkSpeed)
        else
            pcall(Open77.movement.setWalkMode, false)
        end
    end
    state.applied = want
end

local function releaseEverything()
    state.current = nil
    state.carry = nil
    applyClaims()
    now("open77_uikit", "hideTextUI")
end

-- A message from a newer server generation means the server half restarted:
-- everything this client held for the old one is void.
local function accept(payload)
    if type(payload) ~= "table" then return false end
    local generation = payload.generation
    if state.generation ~= nil and generation ~= state.generation then
        if type(generation) == "number" and type(state.generation) == "number" and generation < state.generation then
            return false     -- a stale message from the previous server VM
        end
        state.generation = generation
        state.targets = {}
        releaseEverything()
    end
    state.generation = generation
    return true
end

-- ---------------------------------------------------------------------------
-- Operation presentation
-- ---------------------------------------------------------------------------
RegisterNetEvent("open77:actions:present", function(payload)
    if not accept(payload) or type(payload.opId) ~= "string" then return end
    local current = { opId = payload.opId, claims = payload.claims or {}, progress = payload.progress }
    state.current = current
    applyClaims()
    if type(payload.progress) == "table" then
        CreateThread(function()
            local answer = call("progress", {
                label = payload.progress.label or payload.label,
                duration = math.max(100, math.floor(tonumber(payload.durationMs) or 1000)),
                position = payload.progress.position, style = payload.progress.style,
                color = payload.progress.color, cancellable = payload.progress.cancellable ~= false,
                cancelKey = "X",
            })
            -- A cancel the player pressed is a REQUEST for this operation only;
            -- a bar we closed ourselves (the server ended it) asks nothing.
            if type(answer) == "table" and answer.outcome == "cancelled" and state.current == current and
                not current.ended then
                TriggerServerEvent("open77:actions:cancel", current.opId)
            end
        end)
    end
end)

RegisterNetEvent("open77:actions:end", function(payload)
    if not accept(payload) then return end
    local current = state.current
    if current == nil or current.opId ~= payload.opId then return end
    current.ended = true
    state.current = nil
    if type(current.progress) == "table" then now("open77_uikit", "cancelProgress") end
    applyClaims()
    if payload.state == "cancelled" or payload.state == "failed" then
        if payload.reason ~= "superseded" and payload.reason ~= "cancelled_by_player" then
            notify("Action stopped: " .. tostring(payload.reason))
        end
    end
end)

RegisterNetEvent("open77:actions:carry", function(payload)
    if not accept(payload) then return end
    if payload.itemId == false or payload.itemId == nil then
        if state.carry ~= nil and payload.sessionId ~= nil and state.carry.sessionId ~= payload.sessionId then return end
        state.carry = nil
        now("open77_uikit", "hideTextUI")
    else
        state.carry = { itemId = payload.itemId, sessionId = payload.sessionId, label = payload.label,
            claims = payload.claims or {} }
        local key = Open77.input and Open77.input.keyFor and Open77.input.keyFor(PUTDOWN_KEY_ID) or "G"
        now("open77_uikit", "textUI", {
            text = "Put down " .. tostring(payload.label or "item"), key = key or "G", eyebrow = "Carrying",
            position = "bottom",
        })
    end
    applyClaims()
end)

RegisterNetEvent("open77:actions:refused", function(payload)
    if not accept(payload) then return end
    local reason = tostring(payload.reason)
    local text = ({
        target_claimed = "Someone is already using this.",
        too_far = "Too far away.",
        carrying = "Your hands are full.",
        not_carrying = "You are not carrying anything.",
        actor_busy = "You are already doing something.",
        in_combat = "Not while fighting.",
        player_in_vehicle = "Not from a vehicle.",
    })[reason] or ("Refused: " .. reason)
    notify(text)
end)

-- ---------------------------------------------------------------------------
-- Targets -> prompts
-- ---------------------------------------------------------------------------
RegisterNetEvent("open77:actions:targets", function(payload)
    if not accept(payload) then return end
    if payload.reset then state.targets = {} end
    for _, key in ipairs(type(payload.remove) == "table" and payload.remove or {}) do
        state.targets[key] = nil
    end
    for _, target in ipairs(type(payload.upsert) == "table" and payload.upsert or {}) do
        if type(target) == "table" and type(target.key) == "string" and type(target.position) == "table" then
            state.targets[target.key] = target
        end
    end
end)

local function signature(target)
    local parts = { target.key, tostring(target.position.x), tostring(target.position.y), tostring(target.position.z),
        tostring(target.label), tostring(target.distance), tostring(target.markerDistance),
        tostring(target.promptHeight), tostring(target.lookAt) }
    for _, choice in ipairs(target.choices or {}) do parts[#parts + 1] = choice.action .. "/" .. tostring(choice.label) end
    return table.concat(parts, "|")
end

-- Where a target's card sits and when it is live.
--
-- A target's `position` is where the actor stands -- `playAt` puts the body
-- there -- so it is a floor point (rp_salvage's nodes are `/pos` readings).
-- Until 2026-10-12 the prompt was anchored ON that point with the
-- open77_interactions defaults, `requireLookAt = true` and a 0.18 focus
-- radius, and it never fired live: open77_interactions draws the card for
-- the best candidate whether or not it is active (dim text when not), and
-- fires only an ACTIVE one, which a look-at prompt is only while its anchor
-- sits within 0.18 of the screen centre. A point at the player's feet is
-- there only when he stares straight down at it; with a natural gaze it is
-- below the screen altogether (B5/A5: "the lab node card did not appear").
-- The integrator saw the card under the crosshair, pressed E, and nothing
-- reached the server. tests/prompt_test.lua replays that scene.
--
-- So the card is lifted `promptHeight` metres (default 1.0, the
-- open77_worldui shape of the rp_ferrailleur prompt that did fire) and is live
-- whenever the player is in reach and the card is on screen. `lookAt = true`
-- on the target restores the crosshair requirement for spots packed closer
-- than their reach. The reach is the hypotenuse: open77_interactions measures
-- from the feet to the lifted point, the server from the feet to the target
-- point, and on level ground the two gates are then the same.
local PROMPT_HEIGHT = (type(Open77ActionsModel) == "table" and Open77ActionsModel.PROMPT_HEIGHT) or 1.0
local MAX_PROMPT_DISTANCE = 25.0   -- open77_interactions normalizeDefinition bound

local function promptDefinition(target)
    local choices = {}
    for index, choice in ipairs(target.choices or {}) do
        choices[#choices + 1] = {
            id = "c" .. index, label = choice.label or target.label or "Use",
            description = target.description, key = choice.key or "E",
            icon = choice.icon or target.icon, color = target.color, holdSeconds = choice.holdSeconds,
            event = "open77_actions:choice",
            data = { target = target.key, action = choice.action },
        }
    end
    local lift = math.max(0.0, math.min(3.0, tonumber(target.promptHeight) or PROMPT_HEIGHT))
    local reach = tonumber(target.distance) or 2.0
    local distance = math.min(MAX_PROMPT_DISTANCE, math.sqrt(reach * reach + lift * lift))
    return {
        id = ("t:" .. target.key):sub(1, 96),
        position = target.position, offset = { x = 0.0, y = 0.0, z = lift },
        distance = distance,
        -- open77_interactions refuses a marker distance below the reach.
        markerDistance = math.max(tonumber(target.markerDistance) or 12.0, distance),
        requireLookAt = target.lookAt == true,
        marker = target.marker or "dot", color = target.color, priority = 10, choices = choices,
    }
end

local function eligible(target)
    if target.requires == "carrying" then return state.carry ~= nil end
    if target.requires == "empty" then return state.carry == nil end
    return true
end

local function recycle()
    local ok, x, y, z = pcall(Open77.character.position)
    if not ok or type(x) ~= "number" then return end
    local ranked = {}
    for key, target in pairs(state.targets) do
        local p = target.position
        local dx, dy, dz = p.x - x, p.y - y, p.z - z
        local d = math.sqrt(dx * dx + dy * dy + dz * dz)
        if d <= (target.markerDistance or 12.0) + 2.0 and eligible(target) then
            ranked[#ranked + 1] = { key = key, d = d, target = target }
        end
    end
    table.sort(ranked, function(l, r) return l.d < r.d end)
    local wanted = {}
    for index = 1, math.min(MAX_LIVE, #ranked) do wanted[ranked[index].key] = ranked[index].target end

    for key, entry in pairs(state.live) do
        local target = wanted[key]
        if target == nil or signature(target) ~= entry.signature then
            state.live[key] = nil
            if entry.handle then interactions("remove", entry.handle) end
        end
    end
    for key, target in pairs(wanted) do
        if state.live[key] == nil then
            local answer = interactions("create", promptDefinition(target))
            if type(answer) == "table" and answer.ok then
                state.live[key] = { handle = answer.handle, signature = signature(target) }
            end
        end
    end
end

AddEventHandler("open77_actions:choice", function(payload)
    if type(payload) ~= "table" or payload.owner ~= RESOURCE or type(payload.data) ~= "table" then return end
    TriggerServerEvent("open77:actions:intent", payload.data.action, payload.data.target)
end)

-- ---------------------------------------------------------------------------
-- The put-down key (rebindable from Pause -> Settings -> KEY BINDINGS)
-- ---------------------------------------------------------------------------
pcall(Open77.input.registerKeyMapping, {
    id = PUTDOWN_KEY_ID, name = "Put down the carried item", key = "G",
    onPressed = function()
        if state.carry ~= nil then TriggerServerEvent("open77:actions:putdown") end
    end,
})

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------
AddEventHandler("onClientResourceStop", function(name)
    if name ~= RESOURCE then return end
    state.running = false
    releaseEverything()
    now("open77_interactions", "clear")
end)

CreateThread(function()
    Wait(1000)
    TriggerServerEvent("open77:actions:sync")
    while state.running do
        local ok, err = pcall(recycle)
        if not ok then print("[actions] prompt recycle raised: " .. tostring(err)) end
        Wait(POLL_MS)
    end
end)
