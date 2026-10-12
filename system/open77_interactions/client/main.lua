local page
local ready = false
local nextHandle = 1
local entries = {}
local identities = {}
local ownerGenerations = {}
local ownerEnabled = {}
local nextOwnerSweep = 0
local previousKeys = {}
local hold = { token = nil, startedAt = 0, fired = false }
local activeHandle

-- Targets: standing rules ("every vending machine", "every vehicle") that are
-- resolved against the live world on a slow cadence and MATERIALISED as
-- ordinary entries in `entries`. See the targeting section below.
local targets = {}
local targetIdentities = {}
local nextTargetHandle = 1
local nextTargetResolve = 0
local nextTargetComplaint = 0
local groupCache = { at = -math.huge, set = {} }
-- Round-robin cursors for the bounded fallback reads in `scanCandidates`: an
-- Open77 NPC or vehicle whose position no list carries is located with one
-- `character.state` per pass, a few per pass, never the whole set at once.
local npcFallbackCursor = 0

-- Bumped by everything that changes what the arbitration can see: a create,
-- update or remove, an owner sweep, a materialised or dropped match, an owner
-- toggled. The gather compares it to decide whether last cycle's eligible set
-- is still the truth -- see `gatherEligible`.
local entriesRevision = 0
local function touchEntries() entriesRevision = entriesRevision + 1 end

-- Per-phase cost, measured with the same clock the host uses, so the number
-- the host attributes to this resource can be split by phase from inside.
-- `stats.natives` counts the calls whose cost this file does not control.
-- Reported every STATS_REPORT_SECONDS on one line, and through the `stats`
-- export for tests and the debug bridge.
local STATS_REPORT_SECONDS = 30.0
local stats
local function resetStats(now)
    stats = {
        since = now or 0,
        cycles = 0,
        gathersSkipped = 0,
        resolves = 0,
        phases = {},
        natives = { state = 0, query = 0, lists = 0, project = 0, anchorUpdates = 0, predicates = 0 },
    }
end
resetStats(0)

local function phaseSample(name, seconds)
    local phase = stats.phases[name]
    if not phase then
        phase = { count = 0, totalUs = 0.0, maxUs = 0.0 }
        stats.phases[name] = phase
    end
    local us = seconds * 1e6
    phase.count = phase.count + 1
    phase.totalUs = phase.totalUs + us
    if us > phase.maxUs then phase.maxUs = us end
end

local function countNative(name, amount)
    stats.natives[name] = (stats.natives[name] or 0) + (amount or 1)
end

-- Every yield inside a phase goes through here, so the phase's timing can
-- subtract the frames it spent parked: what is reported is work on this
-- resource's resumes -- the number the host attributes to it -- not the
-- wall time from a phase's first resume to its last.
local yieldedSeconds = 0.0
local function yieldFrame()
    local at = Open77.time.monotonic()
    Wait(0)
    yieldedSeconds = yieldedSeconds + (Open77.time.monotonic() - at)
end

-- Native per-frame projection. `anchors` maps an interaction handle to the
-- native anchor that follows it, `anchorIds` is the reverse lookup used to fold
-- `Open77.anchors.list()` back onto entries, and `anchorScreens` holds, per
-- handle, the row the plugin published for it on its last frame (`screen`,
-- `onScreen`, `distance`, `resolved`).
local anchors = {}
local anchorIds = {}
local anchorScreens = {}
local anchorsAvailable = true
local nextQuotaComplaint = 0

-- Native card drawing.
--
-- The anchor service had already taken Lua out of the per-frame path: the plugin
-- projects every anchor on the game thread and publishes it. A battle test still
-- measured this prompt 345 px behind the body it pointed at during a camera
-- whip, and the nameplate -- on a page declaring a higher frame rate -- 418 px
-- behind. What is left after Lua is the CEF chain itself: IPC, a page repaint on
-- the page's own timer, an offscreen raster, a shared-texture handoff, then the
-- composite. Every stage buffers, and no amount of projecting earlier helps.
--
-- `render = "card"` asks the plugin to draw the prompt in the frame that
-- presents it, from the projection taken on that frame. What is lost is the
-- page's artwork: the SVG markers, the multi-choice list and the CSS. What is
-- gained is that the card sits on the thing it describes. For a prompt, that is
-- the trade worth taking; anything that wants layout should stay a page.
--
-- `cardSupport` is nil until the first anchor settles it, so a client without
-- the native styles falls back to the page rather than showing nothing.
local cardSupport = nil
local nativeCardHandle = nil
local pageHidden = false

local MAX_INTERACTIONS = 256
local MAX_CHOICES = 4
-- The arbitration cycle: what the prompt says and whether a key fired settle
-- on this cadence. One cycle is several resumes, not one -- see "The
-- arbitration tick" below -- and FRAME_MS is the target for the whole cycle,
-- measured from its first resume, not a wait bolted onto its last.
local FRAME_MS = 33
-- The cycle while nothing can happen: the player has not moved, no entry
-- changed, no prompt is active and no key is held. A key sampled on this
-- cadence could miss a tap, which is exactly why it applies only when there
-- is no active prompt for a tap to fire on; the moment anything moves the
-- next cycle runs at FRAME_MS again.
local IDLE_FRAME_MS = 66
-- How far the player has to move before the ranked eligible set is rebuilt.
-- Position entries do not move; an entity entry that does is detected from
-- its anchor's resolved point, so the set is reused only while every input
-- to it is provably unchanged.
local GATHER_MOVE_EPSILON = 0.05
-- Native position reads the gather may spend per cycle on entity entries that
-- have no projected anchor yet (past the anchor budget, or on their first
-- cycle). Past that, an entry keeps the position its match was resolved at.
local GATHER_STATE_BUDGET = 8
-- Older than the slowest resolve cadence, so an entry the pass re-places
-- every pass (a registry NPC) is never read between two passes.
local GATHER_STATE_MAX_AGE = 1.5
-- The plugin's per-resource anchor quota. Entries outnumber it by design
-- (MAX_INTERACTIONS is 256), so the tick spends the budget on the entries that
-- can plausibly matter this instant -- see `gatherEligible`.
local ANCHOR_BUDGET = 32
-- Anchors stop reporting past `maxDistance`, and the plugin measures that from
-- the *camera* while this resource gates on distance from the *player*. The
-- margin keeps the native band from clipping an entry before our own
-- `showDistance` test does.
local ANCHOR_DISTANCE_MARGIN = 5.0

-- Targeting budgets. `MAX_TARGET_ENTRIES` is deliberately smaller than
-- `MAX_INTERACTIONS`: a rule matching a crowded street must never be able to
-- starve the hand-written interactions a gamemode placed on purpose.
local MAX_TARGETS = 64
local MAX_TARGET_ENTRIES = 96
local MAX_MATCHES_PER_TARGET = 32
local DEFAULT_MATCHES_PER_TARGET = 8
local MAX_SELECTOR_PATTERNS = 32
-- How often a rule is re-resolved against the world. A world query and a
-- `canInteract` predicate are both far too expensive for the 33 ms tick, and
-- neither answer changes meaningfully inside half a second. Where a prompt
-- is *drawn* is unaffected: that is the plugin's per-frame anchor, and an
-- entry that already exists keeps following its entity between passes. This
-- was 0.25 s until 2026-09-19; measured live, every pass cost ~43 ms of
-- native reads (see `scanCandidates`), and the cadence is the multiplier.
local TARGET_RESOLVE_SECONDS = 0.5
-- The cadence while the player stands still (within RESOLVE_MOVE_METRES of
-- where the last pass ran). A match that exists keeps following its entity
-- per frame; what the slower cadence delays is a NEW body walking into range
-- being noticed -- by up to a second, from a standing player.
local TARGET_RESOLVE_IDLE_SECONDS = 1.0
local RESOLVE_MOVE_METRES = 0.5
-- The winner is re-checked more often than the rest, because it is the one the
-- player is about to press a key on.
local TARGET_RECHECK_SECONDS = 0.5
local WORLD_SCAN_RADIUS_CAP = 120.0
-- Work per resume during a resolve pass, so a pass over a crowded street is
-- several resumes rather than one that trips the host's instruction hook.
-- Same rule as GATHER_CHUNK below. A candidate merely examined counts one;
-- a materialisation -- placement, payload, predicates -- counts
-- RESOLVE_MATERIALISE_WEIGHT, measured at ~400 VM instructions against ~15.
local RESOLVE_CHUNK = 48
local RESOLVE_MATERIALISE_WEIGHT = 6
-- Bounded fallbacks in the scan: bodies whose position no list carries.
local SCAN_STATE_BUDGET = 8
-- One resolve pass' whole predicate budget. Exceeding it is a bug in somebody's
-- `canInteract`, and the owner is named rather than left to be guessed.
local PREDICATE_BUDGET_SECONDS = 0.008
local allowedNamedKeys = {
    SPACE = true, ENTER = true, RETURN = true,
    UP = true, DOWN = true, LEFT = true, RIGHT = true,
}
local allowedMarkers = {
    dot = true,
    ring = true,
    diamond = true,
    arrow = true,
    chevron = true,
    exclamation = true,
    info = true,
    vehicle = true,
    car = true,
    person = true,
    door = true,
    shop = true,
}

local function response(ok, values)
    values = values or {}
    values.ok = ok == true
    return values
end

local function finite(value)
    return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function validEntity(value)
    if finite(value) then
        return value > 0 and value <= 9007199254740992 and value % 1 == 0
    end
    return type(value) == "string" and value:match("^[1-9][0-9]*$") ~= nil and #value <= 20
end

local function validText(value, maximum, allowEmpty)
    return type(value) == "string" and #value <= maximum and
        (allowEmpty or #value > 0) and not value:find("[%c]")
end

local function validName(value, maximum)
    return type(value) == "string" and #value > 0 and #value <= maximum and
        value:match("^[%w_:%-%.]+$") ~= nil
end

local function vector(value)
    if type(value) ~= "table" or not finite(value.x) or not finite(value.y) or not finite(value.z) then
        return nil
    end
    return { x = value.x + 0.0, y = value.y + 0.0, z = value.z + 0.0 }
end

local function normalizeKey(value)
    if type(value) ~= "string" then return nil end
    local key = value:upper()
    if (#key == 1 and key:match("^[A-Z0-9]$")) or allowedNamedKeys[key] then return key end
    return nil
end

local function normalizeColor(value, fallback)
    value = value or fallback or "#22D8E2"  -- --op77-accent
    if type(value) ~= "string" or not value:match("^#[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]$") then
        return nil
    end
    return value:upper()
end

local function normalizeChoice(choice, index, defaultColor)
    if type(choice) ~= "table" then return nil, "choice_must_be_a_table" end
    local id = choice.id or ("choice_" .. tostring(index))
    local label = choice.label or choice.text
    local key = normalizeKey(choice.key or "E")
    local color = normalizeColor(choice.color, defaultColor)
    if not validName(id, 64) then return nil, "invalid_choice_id" end
    if not validText(label, 96, false) then return nil, "invalid_choice_label" end
    if not key then return nil, "unsupported_action_key" end
    if not color then return nil, "invalid_choice_color" end
    if choice.description ~= nil and not validText(choice.description, 160, true) then
        return nil, "invalid_choice_description"
    end
    if choice.icon ~= nil and not validText(choice.icon, 12, true) then return nil, "invalid_choice_icon" end
    if choice.event ~= nil and not validName(choice.event, 96) then return nil, "invalid_choice_event" end
    local holdSeconds = choice.holdSeconds or 0
    if not finite(holdSeconds) or holdSeconds < 0 or holdSeconds > 10 or
        (holdSeconds > 0 and holdSeconds < 0.25) then return nil, "invalid_hold_duration" end
    return {
        id = id,
        label = label,
        description = choice.description or "",
        icon = choice.icon or "",
        key = key,
        color = color,
        holdSeconds = holdSeconds + 0.0,
        enabled = choice.enabled ~= false,
        event = choice.event,
        data = type(choice.data) == "table" and choice.data or {},
    }
end

local function normalizeDefinition(owner, definition, existingHandle)
    if not validName(owner, 64) then return nil, "invalid_owner" end
    if type(definition) ~= "table" then return nil, "definition_must_be_a_table" end
    local id = definition.id or ("interaction_" .. tostring(existingHandle or nextHandle))
    if not validName(id, 96) then return nil, "invalid_interaction_id" end
    local position = definition.position and vector(definition.position) or nil
    local entity = definition.entity
    if entity ~= nil and not validEntity(entity) then
        return nil, "invalid_entity"
    end
    if (position == nil) == (entity == nil) then return nil, "provide_exactly_one_of_position_or_entity" end
    local offset = vector(definition.offset or { x = 0, y = 0, z = 0 })
    if not offset then return nil, "invalid_offset" end
    local distance = definition.distance or definition.radius or 2.5
    local showDistance = definition.markerDistance or definition.showDistance or math.max(12.0, distance)
    local focusRadius = definition.focusRadius or 0.18
    local priority = definition.priority or 0
    local marker = definition.marker or definition.markerStyle or "dot"
    if marker == "car" then marker = "vehicle" end
    local markerScale = definition.markerScale or 1.0
    local markerNearScale = definition.markerNearScale or 2.0
    local markerAnimated = definition.markerAnimated ~= false
    if not finite(distance) or distance < 0.25 or distance > 25 then return nil, "invalid_distance" end
    if not finite(showDistance) or showDistance < distance or showDistance > 250 then
        return nil, "invalid_show_distance"
    end
    if not finite(focusRadius) or focusRadius < 0.02 or focusRadius > 1.0 then
        return nil, "invalid_focus_radius"
    end
    if not finite(priority) or priority < -1000 or priority > 1000 then return nil, "invalid_priority" end
    if type(marker) ~= "string" or not allowedMarkers[marker] then return nil, "invalid_marker" end
    if not finite(markerScale) or markerScale < 0.6 or markerScale > 2.0 then
        return nil, "invalid_marker_scale"
    end
    if not finite(markerNearScale) or markerNearScale < 1.0 or markerNearScale > 4.0 then
        return nil, "invalid_marker_near_scale"
    end
    if definition.markerAnimated ~= nil and type(definition.markerAnimated) ~= "boolean" then
        return nil, "invalid_marker_animated"
    end
    local color = normalizeColor(definition.color, "#22D8E2")  -- --op77-accent
    if not color then return nil, "invalid_color" end
    if definition.event ~= nil and not validName(definition.event, 96) then return nil, "invalid_event" end
    local sourceChoices = definition.choices
    if sourceChoices == nil then
        sourceChoices = {{
            id = definition.choiceId or "primary",
            label = definition.label or definition.text,
            description = definition.description,
            icon = definition.icon,
            key = definition.key,
            color = definition.color,
            holdSeconds = definition.holdSeconds,
            enabled = definition.choiceEnabled,
            event = definition.event,
            data = definition.data,
        }}
    end
    if type(sourceChoices) ~= "table" or #sourceChoices < 1 or #sourceChoices > MAX_CHOICES then
        return nil, "invalid_choice_count"
    end
    local choices, ids, keys = {}, {}, {}
    for index, source in ipairs(sourceChoices) do
        local choice, choiceError = normalizeChoice(source, index, color)
        if not choice then return nil, choiceError end
        if ids[choice.id] then return nil, "duplicate_choice_id" end
        if keys[choice.key] then return nil, "duplicate_choice_key" end
        ids[choice.id], keys[choice.key] = true, true
        choices[#choices + 1] = choice
    end
    return {
        handle = existingHandle,
        owner = owner,
        id = id,
        position = position,
        entity = entity,
        -- Cached once here rather than summed per cycle: for a position entry
        -- `world` IS the point the gather measures against, and `entityText`
        -- is what every anchor call would otherwise re-format.
        world = position and {
            x = position.x + offset.x, y = position.y + offset.y, z = position.z + offset.z,
        } or nil,
        entityText = entity ~= nil and tostring(entity) or nil,
        offset = offset,
        distance = distance + 0.0,
        showDistance = showDistance + 0.0,
        marker = marker,
        markerScale = markerScale + 0.0,
        markerNearScale = markerNearScale + 0.0,
        markerAnimated = markerAnimated,
        focusRadius = focusRadius + 0.0,
        requireLookAt = definition.requireLookAt ~= false,
        priority = priority + 0.0,
        color = color,
        visible = definition.visible ~= false,
        choices = choices,
        event = definition.event,
        data = type(definition.data) == "table" and definition.data or {},
        cooldown = finite(definition.cooldown) and math.max(0, math.min(60, definition.cooldown)) or 0,
        lastTrigger = -math.huge,
    }
end

local caller

local function create(definition)
    local owner, callerError = caller()
    if not owner then return response(false, { error = callerError }) end
    local count = 0
    for _ in pairs(entries) do count = count + 1 end
    if count >= MAX_INTERACTIONS then return response(false, { error = "interaction_limit" }) end
    local entry, reason = normalizeDefinition(owner, definition)
    if not entry then return response(false, { error = reason }) end
    local identity = owner .. ":" .. entry.id
    if identities[identity] then return response(false, { error = "duplicate_interaction_id" }) end
    local handle = nextHandle
    nextHandle = nextHandle + 1
    entry.handle = handle
    entries[handle] = entry
    identities[identity] = handle
    touchEntries()
    return response(true, { handle = handle, id = entry.id })
end

local function update(handle, definition)
    local owner, callerError = caller()
    if not owner then return response(false, { error = callerError }) end
    local current = entries[tonumber(handle)]
    if not current then return response(false, { error = "interaction_not_found" }) end
    if current.owner ~= owner then return response(false, { error = "not_owner" }) end
    if type(definition) ~= "table" then return response(false, { error = "patch_must_be_a_table" }) end
    local merged = {}
    for key, value in pairs(current) do merged[key] = value end
    for key, value in pairs(definition) do merged[key] = value end
    merged.id = definition.id or current.id
    merged.position = definition.position ~= nil and definition.position or current.position
    merged.entity = definition.entity ~= nil and definition.entity or current.entity
    if definition.position ~= nil then merged.entity = nil end
    if definition.entity ~= nil then merged.position = nil end
    local shorthandChanged = definition.choiceId ~= nil or definition.label ~= nil or
        definition.text ~= nil or definition.description ~= nil or definition.icon ~= nil or
        definition.key ~= nil or definition.color ~= nil or definition.holdSeconds ~= nil or
        definition.choiceEnabled ~= nil or definition.event ~= nil or definition.data ~= nil
    if definition.choices ~= nil then
        merged.choices = definition.choices
    elseif shorthandChanged then
        if #current.choices ~= 1 then
            return response(false, { error = "choices_required_for_multi_choice_update" })
        end
        local choice = {}
        for key, value in pairs(current.choices[1]) do choice[key] = value end
        if definition.choiceId ~= nil then choice.id = definition.choiceId end
        if definition.label ~= nil then choice.label = definition.label end
        if definition.text ~= nil then choice.label = definition.text end
        if definition.description ~= nil then choice.description = definition.description end
        if definition.icon ~= nil then choice.icon = definition.icon end
        if definition.key ~= nil then choice.key = definition.key end
        if definition.color ~= nil then choice.color = definition.color end
        if definition.holdSeconds ~= nil then choice.holdSeconds = definition.holdSeconds end
        if definition.choiceEnabled ~= nil then choice.enabled = definition.choiceEnabled end
        if definition.event ~= nil then choice.event = definition.event end
        if definition.data ~= nil then choice.data = definition.data end
        merged.choices = { choice }
    else
        merged.choices = current.choices
    end
    local replacement, reason = normalizeDefinition(owner, merged, current.handle)
    if not replacement then return response(false, { error = reason }) end
    local oldIdentity = owner .. ":" .. current.id
    local newIdentity = owner .. ":" .. replacement.id
    if newIdentity ~= oldIdentity and identities[newIdentity] then
        return response(false, { error = "duplicate_interaction_id" })
    end
    replacement.lastTrigger = current.lastTrigger
    identities[oldIdentity] = nil
    identities[newIdentity] = current.handle
    entries[current.handle] = replacement
    touchEntries()
    return response(true, { handle = current.handle, id = replacement.id })
end

local function remove(handle)
    local owner, callerError = caller()
    if not owner then return response(false, { error = callerError }) end
    handle = tonumber(handle)
    local entry = handle and entries[handle] or nil
    if not entry then return response(false, { error = "interaction_not_found" }) end
    if entry.owner ~= owner then return response(false, { error = "not_owner" }) end
    identities[entry.owner .. ":" .. entry.id] = nil
    entries[handle] = nil
    touchEntries()
    if hold.token and hold.token:match("^" .. tostring(handle) .. ":") then
        hold = { token = nil, startedAt = 0, fired = false }
    end
    return response(true)
end

-- `scope` says which half of an owner is being torn down, and the distinction
-- is load-bearing. A resource's client VM stopping says nothing about its
-- server VM: a job resource that declared its targets from `server/main.lua`
-- keeps them when its client half reloads, and loses them only when the server
-- retracts them. "client" (the default) sweeps hand-written interactions and
-- client-declared targets; "server" sweeps only what the server declared;
-- "all" is teardown of this service itself.
local function removeOwner(owner, scope)
    scope = scope or "client"
    local removed = 0
    local droppedTargets = {}
    for handle, target in pairs(targets) do
        if target.owner == owner and (scope == "all" or target.source == scope) then
            droppedTargets[handle] = true
            targetIdentities[target.owner .. ":" .. target.id] = nil
            targets[handle] = nil
        end
    end
    for handle, entry in pairs(entries) do
        if entry.owner == owner then
            local sweep
            if entry.target ~= nil then
                sweep = droppedTargets[entry.target] == true
            else
                sweep = scope ~= "server"
            end
            if sweep then
                identities[entry.owner .. ":" .. entry.id] = nil
                entries[handle] = nil
                removed = removed + 1
            end
        end
    end
    if removed > 0 or next(droppedTargets) ~= nil then touchEntries() end
    return removed
end

caller = function()
    local owner = GetInvokingResource()
    local generation = GetInvokingResourceGeneration()
    if not validName(owner, 64) or type(generation) ~= "number" then
        return nil, "export_call_required"
    end
    if ownerGenerations[owner] ~= nil and ownerGenerations[owner] ~= generation then
        removeOwner(owner)
    end
    ownerGenerations[owner] = generation
    if ownerEnabled[owner] == nil then ownerEnabled[owner] = true end
    return owner
end

local function snapshot(entry)
    local result = {
        handle = entry.handle, owner = entry.owner, id = entry.id,
        position = entry.position, entity = entry.entity, offset = entry.offset,
        distance = entry.distance, showDistance = entry.showDistance,
        markerDistance = entry.showDistance, marker = entry.marker, markerScale = entry.markerScale,
        markerNearScale = entry.markerNearScale, markerAnimated = entry.markerAnimated,
        requireLookAt = entry.requireLookAt, priority = entry.priority,
        visible = entry.visible, color = entry.color, choices = {},
    }
    for _, choice in ipairs(entry.choices) do
        result.choices[#result.choices + 1] = {
            id = choice.id, label = choice.label, description = choice.description,
            icon = choice.icon, key = choice.key, color = choice.color,
            holdSeconds = choice.holdSeconds, enabled = choice.enabled,
        }
    end
    return result
end

exports("create", create)
exports("update", update)
exports("remove", remove)
exports("setVisible", function(handle, visible)
    return update(handle, { visible = visible ~= false })
end)
exports("get", function(handle)
    local owner = caller()
    if not owner then return nil end
    local entry = entries[tonumber(handle)]
    if not entry or entry.owner ~= owner then return nil end
    return snapshot(entry)
end)
exports("all", function()
    local owner = caller()
    if not owner then return {} end
    local result = {}
    for _, entry in pairs(entries) do
        if entry.owner == owner then result[#result + 1] = snapshot(entry) end
    end
    table.sort(result, function(a, b) return a.handle < b.handle end)
    return result
end)
exports("clear", function()
    local owner, callerError = caller()
    if not owner then return response(false, { error = callerError }) end
    return response(true, { removed = removeOwner(owner) })
end)
exports("setEnabled", function(value)
    local owner, callerError = caller()
    if not owner then return response(false, { error = callerError }) end
    if ownerEnabled[owner] ~= (value ~= false) then touchEntries() end
    ownerEnabled[owner] = value ~= false
    return response(true)
end)
exports("isEnabled", function()
    local owner = caller()
    return owner ~= nil and ownerEnabled[owner] ~= false
end)

-- Native position reads the current gather may still spend; reset per cycle.
local gatherStateBudget = 0

local function worldPosition(entry, now)
    if entry.entity then
        -- The plugin already resolved this entity on the game thread, from the
        -- body REDengine actually drew. Reusing that point keeps the Lua-side
        -- distance test and the native marker talking about the same place, and
        -- saves a native call per entry per tick.
        local row = anchorScreens[entry.handle]
        if row and row.resolved then return row.resolved end
        -- No projected anchor for this entry: the point its match was resolved
        -- at is the fallback, refreshed by `character.state` only while it is
        -- stale and the cycle's native budget allows. The old shape -- one
        -- native read per unanchored entity entry per cycle -- is how thirty
        -- reads a second per entry crept in.
        local known = entry.world
        if known and now and entry.worldAt and now - entry.worldAt < GATHER_STATE_MAX_AGE then
            return known
        end
        if gatherStateBudget <= 0 then return known end
        gatherStateBudget = gatherStateBudget - 1
        countNative("state")
        local x, y, z
        if type(Open77.character.position) == "function" then
            -- The placement-only read: one engine call, not a snapshot.
            x, y, z = Open77.character.position(entry.entity)
            if type(x) ~= "number" then return known end
        else
            local state = Open77.character.state(entry.entity)
            if not state or not state.attached then return known end
            x, y, z = state.position.x, state.position.y, state.position.z
        end
        known = { x = x + entry.offset.x, y = y + entry.offset.y, z = z + entry.offset.z }
        entry.world, entry.worldAt = known, now or Open77.time.monotonic()
        return known
    end
    -- A position entry's point is summed once, at normalisation.
    return entry.world
end

local function distance(left, right)
    local x, y, z = left.x - right.x, left.y - right.y, left.z - right.z
    return math.sqrt(x * x + y * y + z * z)
end

local function sameVector(left, right)
    return left ~= nil and right ~= nil and
        math.abs(left.x - right.x) < 0.005 and
        math.abs(left.y - right.y) < 0.005 and
        math.abs(left.z - right.z) < 0.005
end

-- ---------------------------------------------------------------------------
-- Targets
--
-- A target is a standing rule -- "every vending machine", "every vehicle",
-- "every player" -- rather than one prompt bolted to one place. The rule is
-- re-resolved against what this client can currently see, and every match is
-- MATERIALISED as an ordinary entry in `entries`. That is the whole trick: the
-- arbiter, the anchor budget, the card, the hold, the cooldown and the owner
-- sweep above are reused unchanged, and a target cannot behave differently from
-- a hand-written interaction because by the time anything draws it, it *is* one.
--
-- Three cadences, and they are not interchangeable:
--
--   * WHERE a prompt is drawn -- every rendered frame, in the plugin, through
--     the anchor the materialised entry already owns.
--   * WHAT it says, and whether a key fired -- every arbitration cycle (33 ms).
--   * WHICH things match a rule, and whether `canInteract` still agrees --
--     every TARGET_RESOLVE_SECONDS. A world query and a predicate are both far
--     too expensive for the tick, and neither answer changes meaningfully
--     inside a quarter of a second.
--
-- A prompt is presentation. Nothing here is authority: `groups`, `canInteract`,
-- `distance` and the vehicle state in the payload are all read on a client that
-- owns this code. The server must re-derive every one of them when the intent
-- arrives. See wiki/interactions.md, "Event payload and server authority".
-- ---------------------------------------------------------------------------

local TARGET_KINDS = {
    model = true, class = true, globalVehicle = true,
    globalPlayer = true, globalNpc = true, zone = true,
}
local ZONE_SHAPES = { sphere = true, box = true, poly = true }
-- Bit indices into a vehicle snapshot's `doors` mask, mirroring the runtime's
-- own `Open77.vehicles.doors`. These are NOT slot or bone names and carry no
-- transform -- see wiki/interactions.md, "Why there are no bones".
local VEHICLE_PART_BITS = {
    frontLeft = 0, frontRight = 1, backLeft = 2, backRight = 3, trunk = 4, hood = 5,
}

local function complainAboutTargets(message)
    local now = Open77.time.monotonic()
    if now < nextTargetComplaint then return end
    nextTargetComplaint = now + 10.0
    print("[open77_interactions] " .. message)
end

local function identityKey(prefix, value)
    return prefix .. tostring(math.tointeger(value) or value)
end

-- One key per thing, whichever source reported it, so a body seen by the world
-- query and by a roster is one candidate and one materialised entry. The
-- identity ids the world query attaches (`playerId`, `npcId`, `vehicleId`) win
-- over the engine id because they are what the rosters key on.
local function keyFor(hit)
    if hit.playerId ~= nil then return identityKey("p", hit.playerId) end
    if hit.npcId ~= nil then return identityKey("n", hit.npcId) end
    if hit.vehicleId ~= nil then return identityKey("v", hit.vehicleId) end
    return identityKey("e", hit.engineEntity)
end

-- Selectors are matched case-insensitively, exactly, with one optional trailing
-- `*` for a prefix. Deliberately not Lua patterns: a resource must not be able
-- to hand this service a pattern that backtracks for a millisecond per entity.
local function normalizeSelector(value, field)
    if type(value) == "string" then value = { value } end
    if type(value) ~= "table" then return nil, "invalid_" .. field end
    local count = #value
    if count < 1 or count > MAX_SELECTOR_PATTERNS then return nil, "invalid_" .. field end
    local out = {}
    for index = 1, count do
        local text = value[index]
        if not validText(text, 128, false) then return nil, "invalid_" .. field end
        text = text:lower()
        local prefix = false
        if text:sub(-1) == "*" then
            prefix = true
            text = text:sub(1, -2)
        end
        if #text == 0 then return nil, "invalid_" .. field end
        out[#out + 1] = { text = text, prefix = prefix, size = #text }
    end
    return out
end

local function matchesOne(pattern, subject)
    if subject == nil then return false end
    if pattern.prefix then return subject:sub(1, pattern.size) == pattern.text end
    return subject == pattern.text
end

-- `first`/`second` are already lower-cased by the scan, so matching allocates
-- nothing per candidate.
local function matchesSelector(patterns, first, second)
    for index = 1, #patterns do
        local pattern = patterns[index]
        if matchesOne(pattern, first) or matchesOne(pattern, second) then return true end
    end
    return false
end

local function normalizeNameSet(value, field)
    if type(value) == "string" then value = { value } end
    if type(value) ~= "table" then return nil, "invalid_" .. field end
    local count = #value
    if count < 1 or count > 32 then return nil, "invalid_" .. field end
    local out = {}
    for index = 1, count do
        if not validName(value[index], 64) then return nil, "invalid_" .. field end
        out[value[index]] = true
    end
    return out
end

-- Zones. Containment is NOT owned here: `Open77.zones` carries it, from one Lua
-- source embedded in both runtimes, so a point on the edge of a shop floor
-- cannot be inside for the client drawing the prompt and outside for the server
-- deciding the sale. This file kept a local copy only until that module landed.
--
-- `Open77.zones.normalize` prepares a definition once; `Open77.zones.contains`
-- is pure and synchronous, which is what the resolve pass needs -- no promise,
-- no export round trip. The local normaliser below stays because it also
-- validates the presentation half of a target definition; the geometry it
-- produces is handed straight to the shared module.
local function normalizeZone(value)
    if type(value) ~= "table" then return nil, "invalid_zone" end
    local shape = value.shape
    if shape == nil then
        shape = (value.points ~= nil and "poly") or (value.size ~= nil and "box") or "sphere"
    end
    if type(shape) ~= "string" or not ZONE_SHAPES[shape] then return nil, "invalid_zone_shape" end

    if shape == "poly" then
        local points = value.points
        if type(points) ~= "table" or #points < 3 or #points > 32 then
            return nil, "invalid_zone_points"
        end
        if not finite(value.minZ) or not finite(value.maxZ) or value.minZ >= value.maxZ then
            return nil, "invalid_zone_height"
        end
        local ring, sumX, sumY = {}, 0.0, 0.0
        for index = 1, #points do
            local point = points[index]
            if type(point) ~= "table" or not finite(point.x) or not finite(point.y) then
                return nil, "invalid_zone_points"
            end
            ring[index] = { x = point.x + 0.0, y = point.y + 0.0 }
            sumX, sumY = sumX + point.x, sumY + point.y
        end
        local centre = value.position and vector(value.position) or {
            x = sumX / #ring, y = sumY / #ring, z = (value.minZ + value.maxZ) * 0.5,
        }
        if not centre then return nil, "invalid_zone_position" end
        return {
            shape = "poly", points = ring, position = centre,
            minZ = value.minZ + 0.0, maxZ = value.maxZ + 0.0,
        }
    end

    local position = vector(value.position)
    if not position then return nil, "invalid_zone_position" end

    -- The geometry below is written in the shared module's own vocabulary --
    -- `size` and `rotation` for a box, `radius` and `maxHeight` for a
    -- cylinder -- because that module is what `zoneContains` hands it to. The
    -- half-extents and the pre-computed heading this file used to keep were
    -- its own former containment code's, and `Open77.zones.normalize` refused
    -- them (`invalid_size`, `invalid_radius`): every box and sphere zone
    -- target was silently inert from 2026-09-16 until this was measured.
    if shape == "box" then
        local size = vector(value.size)
        if not size or size.x <= 0 or size.y <= 0 or size.z <= 0 or
            size.x > 400 or size.y > 400 or size.z > 400 then
            return nil, "invalid_zone_size"
        end
        local heading = value.heading or 0.0
        if not finite(heading) then return nil, "invalid_zone_heading" end
        return {
            shape = "box", position = position, size = size, rotation = heading + 0.0,
        }
    end

    local radius = value.radius
    if not finite(radius) or radius <= 0 or radius > 400 then return nil, "invalid_zone_radius" end
    local maxHeight = finite(value.maxHeight) and value.maxHeight or 6.0
    if maxHeight <= 0 or maxHeight > 400 then return nil, "invalid_zone_height" end
    -- What this API calls a sphere -- a planar radius with a height band, the
    -- shape every radius zone shipped as -- is the shared module's cylinder;
    -- its `sphere` is a true ball and refuses `maxHeight`.
    return {
        shape = "cylinder", position = position,
        radius = radius + 0.0, maxHeight = maxHeight + 0.0,
    }
end

local function zoneContains(zone, point)
    -- One implementation, shared with the server and with `open77_zones`.
    -- `prepared` is cached on the zone by the first call: the shared module
    -- costs about eight times more on a raw polygon definition than on a
    -- prepared one, and this runs every resolve pass.
    if zone == nil or point == nil then return false end
    if zone.prepared == nil then
        local prepared, reason = Open77.zones.normalize(zone)
        if prepared == nil then
            Open77.log.warn(("interaction zone refused by Open77.zones: %s"):format(
                tostring(reason)))
            zone.prepared = false
            return false
        end
        zone.prepared = prepared
    end
    if zone.prepared == false then return false end
    return Open77.zones.contains(zone.prepared, point) == true
end

-- Group membership. Open77 already has two permission models and this service
-- adds neither: the ACL is server-only (`Open77.acl.isAllowed` has no client
-- binding at all), so the one thing a client can read synchronously is its own
-- replicated state bag. A job resource writes the player's groups there once,
-- server-side, and every target gate reads them for free.
local function collectGroupNames(value, set)
    if type(value) == "string" then
        if #value > 0 then set[value] = true end
        return
    end
    if type(value) ~= "table" then return end
    for index = 1, #value do
        if type(value[index]) == "string" then set[value[index]] = true end
    end
    for key, enabled in pairs(value) do
        if type(key) == "string" and enabled == true then set[key] = true end
    end
    if type(value.name) == "string" then set[value.name] = true end
end

local function localStateBag()
    if type(Open77.state) ~= "table" or type(Open77.state.localPlayer) ~= "function" then
        return nil
    end
    local ok, bag = pcall(Open77.state.localPlayer)
    if not ok then return nil end
    return bag
end

local function localGroups()
    local now = Open77.time.monotonic()
    if now - groupCache.at < TARGET_RESOLVE_SECONDS then return groupCache.set end
    local set = {}
    local bag = localStateBag()
    if bag then
        for _, key in ipairs({ "groups", "group", "job" }) do
            local ok, value = pcall(bag.get, bag, key)
            if ok then collectGroupNames(value, set) end
        end
    end
    groupCache = { at = now, set = set }
    return set
end

local function readLocalState(path)
    local bag = localStateBag()
    if not bag then return nil end
    local head, rest = path:match("^([^%.]+)%.?(.*)$")
    if not head then return nil end
    local ok, value = pcall(bag.get, bag, head)
    if not ok then return nil end
    while rest ~= nil and #rest > 0 do
        if type(value) ~= "table" then return nil end
        local segment
        segment, rest = rest:match("^([^%.]+)%.?(.*)$")
        if not segment then return nil end
        value = value[segment]
    end
    return value
end

-- `canInteract` in two forms, and the reason there are two is the export
-- boundary: functions never cross it (wiki/resource-exports.md, "What crosses,
-- and what does not"), so a closure cannot be handed to this service the way
-- ox_target takes one.
--
--   * a STRING names an export the declaring resource published. It is invoked
--     with `Open77.exports.callSync`, which runs the predicate inline in the
--     owner's own VM, with the owner's own upvalues -- a closure in everything
--     but spelling. The runtime, not this service, enforces that it cannot
--     wait: `Wait`/`:await()` fail the call with `export_yielded`.
--   * a TABLE is a declarative rule evaluated here, with no call at all. It
--     covers the common gates (group, distance, state bag, vehicle state) and
--     is what a target should use whenever it fits.
local function normalizePredicate(value, field)
    if type(value) == "string" then
        if not validName(value, 64) then return nil, "invalid_" .. field end
        return { kind = "export", name = value }
    end
    if type(value) ~= "table" then return nil, "invalid_" .. field end
    local rule = { kind = "rule" }
    if value.groups ~= nil then
        local groups, reason = normalizeNameSet(value.groups, field)
        if not groups then return nil, reason end
        rule.groups = groups
    end
    if value.notGroups ~= nil then
        local groups, reason = normalizeNameSet(value.notGroups, field)
        if not groups then return nil, reason end
        rule.notGroups = groups
    end
    for _, bound in ipairs({ "minDistance", "maxDistance" }) do
        if value[bound] ~= nil then
            if not finite(value[bound]) or value[bound] < 0 or value[bound] > 250 then
                return nil, "invalid_" .. field
            end
            rule[bound] = value[bound] + 0.0
        end
    end
    if value.class ~= nil then
        local selector, reason = normalizeSelector(value.class, field)
        if not selector then return nil, reason end
        rule.class = selector
    end
    if value.record ~= nil then
        local selector, reason = normalizeSelector(value.record, field)
        if not selector then return nil, reason end
        rule.record = selector
    end
    if value.state ~= nil then
        if type(value.state) ~= "table" then return nil, "invalid_" .. field end
        local state = {}
        local count = 0
        for key, expected in pairs(value.state) do
            local kind = type(expected)
            if type(key) ~= "string" or #key == 0 or #key > 64 or
                key:match("^[%w_%.]+$") == nil or
                (kind ~= "string" and kind ~= "number" and kind ~= "boolean") then
                return nil, "invalid_" .. field
            end
            state[key] = expected
            count = count + 1
            if count > 8 then return nil, "invalid_" .. field end
        end
        rule.state = state
    end
    if value.vehicle ~= nil then
        if type(value.vehicle) ~= "table" then return nil, "invalid_" .. field end
        local vehicle = {}
        for _, flag in ipairs({ "locked", "occupied", "partOpen", "driven" }) do
            if value.vehicle[flag] ~= nil then
                if type(value.vehicle[flag]) ~= "boolean" then return nil, "invalid_" .. field end
                vehicle[flag] = value.vehicle[flag]
            end
        end
        rule.vehicle = vehicle
    end
    return rule
end

local function anyGroup(set, groups)
    for name in pairs(set) do
        if groups[name] then return true end
    end
    return false
end

local function evaluateRule(rule, payload)
    if rule.maxDistance and payload.distance > rule.maxDistance then return false end
    if rule.minDistance and payload.distance < rule.minDistance then return false end
    if rule.groups or rule.notGroups then
        local groups = localGroups()
        if rule.groups and not anyGroup(rule.groups, groups) then return false end
        if rule.notGroups and anyGroup(rule.notGroups, groups) then return false end
    end
    if rule.class and
        not matchesSelector(rule.class, payload.class and payload.class:lower() or nil) then
        return false
    end
    if rule.record and
        not matchesSelector(rule.record, payload.record and payload.record:lower() or nil) then
        return false
    end
    if rule.state then
        for key, expected in pairs(rule.state) do
            if readLocalState(key) ~= expected then return false end
        end
    end
    if rule.vehicle then
        local vehicle = payload.vehicle
        if not vehicle then return false end
        if rule.vehicle.locked ~= nil and (vehicle.locked == true) ~= rule.vehicle.locked then
            return false
        end
        if rule.vehicle.occupied ~= nil and (vehicle.occupied == true) ~= rule.vehicle.occupied then
            return false
        end
        if rule.vehicle.driven ~= nil and (vehicle.driver ~= nil) ~= rule.vehicle.driven then
            return false
        end
        if rule.vehicle.partOpen ~= nil and (payload.partOpen == true) ~= rule.vehicle.partOpen then
            return false
        end
    end
    return true
end

-- Fail closed, always. A predicate that raises, that tries to wait, or that
-- belongs to a resource that has since stopped refuses the prompt; it never
-- grants one by accident.
local function evaluatePredicate(owner, predicate, payload)
    if predicate == nil then return true end
    if predicate.kind == "rule" then
        local ok, allowed = pcall(evaluateRule, predicate, payload)
        if not ok then
            complainAboutTargets("canInteract rule failed for " .. owner .. ": " .. tostring(allowed))
            return false
        end
        return allowed == true
    end
    local ok, allowed = pcall(Open77.exports.callSync, owner, predicate.name, payload)
    if not ok then
        complainAboutTargets("canInteract export " .. owner .. ":" .. predicate.name ..
            " refused: " .. tostring(allowed))
        return false
    end
    return allowed == true
end

local function normalizeTarget(owner, definition, existingHandle)
    if not validName(owner, 64) then return nil, "invalid_owner" end
    if type(definition) ~= "table" then return nil, "definition_must_be_a_table" end
    local kind = definition.kind
    if type(kind) ~= "string" or not TARGET_KINDS[kind] then return nil, "invalid_target_kind" end
    local id = definition.id or ("target_" .. tostring(existingHandle or nextTargetHandle))
    if not validName(id, 64) then return nil, "invalid_target_id" end

    local target = { owner = owner, id = id, kind = kind, handle = existingHandle }

    if kind == "model" then
        local selector, reason = normalizeSelector(definition.models or definition.model, "models")
        if not selector then return nil, reason end
        target.models = selector
    elseif kind == "class" then
        local selector, reason = normalizeSelector(definition.classes or definition.class, "classes")
        if not selector then return nil, reason end
        target.classes = selector
    elseif kind == "zone" then
        local zone, reason = normalizeZone(definition.zone or definition)
        if not zone then return nil, reason end
        target.zone = zone
    end

    if definition.part ~= nil then
        if kind ~= "globalVehicle" then return nil, "part_requires_global_vehicle" end
        if type(definition.part) ~= "string" or VEHICLE_PART_BITS[definition.part] == nil then
            return nil, "invalid_vehicle_part"
        end
        target.part = definition.part
    end

    if definition.groups ~= nil then
        local groups, reason = normalizeNameSet(definition.groups, "groups")
        if not groups then return nil, reason end
        target.groups = groups
    end

    -- `npcs = "open77"` says a globalNpc target only ever means bodies Open77
    -- spawned (`Open77.npcs.create`), never the vanilla crowd. Such a target is
    -- resolved from the NPC registry -- which carries every replica's
    -- position -- and never runs the puppet world query, the one native a
    -- `globalNpc` target otherwise costs (24 ms a call in a market crowd,
    -- measured 2026-09-19). "any" (the default) keeps the crowd.
    if definition.npcs ~= nil then
        if kind ~= "globalNpc" then return nil, "npcs_requires_global_npc" end
        if definition.npcs ~= "open77" and definition.npcs ~= "any" then return nil, "invalid_npcs" end
        target.npcs = definition.npcs
    end

    local maximum = definition.maxMatches or DEFAULT_MATCHES_PER_TARGET
    if not finite(maximum) or maximum < 1 or maximum > MAX_MATCHES_PER_TARGET or maximum % 1 ~= 0 then
        return nil, "invalid_max_matches"
    end
    target.maxMatches = maximum

    if definition.canInteract ~= nil then
        local predicate, reason = normalizePredicate(definition.canInteract, "can_interact")
        if not predicate then return nil, reason end
        target.canInteract = predicate
    end

    -- A globalNpc target that is `npcs = "open77"`, or whose own rule gates on
    -- a `record`, can only ever match an Open77 NPC: a crowd puppet carries no
    -- record on this build (the world query reports none), so the rule refuses
    -- every one of them. Both resolve from the registry alone.
    if kind == "globalNpc" then
        local rule = target.canInteract
        target.registryOnly = target.npcs == "open77" or
            (rule ~= nil and rule.kind == "rule" and rule.record ~= nil)
    end

    -- The presentation half is validated by the very same code a hand-written
    -- interaction goes through, against a placeholder position that
    -- materialisation then replaces. One validator, one set of refusal tokens,
    -- and a target can never accept a definition `create` would reject.
    local template = {}
    for key, value in pairs(definition) do template[key] = value end
    template.kind, template.models, template.model = nil, nil, nil
    template.classes, template.class, template.zone = nil, nil, nil
    template.groups, template.maxMatches, template.canInteract = nil, nil, nil
    template.part, template.entity, template.npcs = nil, nil, nil
    template.position = { x = 0.0, y = 0.0, z = 0.0 }
    template.id = id
    if kind == "zone" then
        -- The card sits at the volume's centre unless the definition names its
        -- own anchor point. `addBoxZone`/`addSphereZone` pass the centre as
        -- `position` anyway, so the two agree for the sugar.
        template.position = vector(definition.position) or target.zone.position
        template.marker = definition.marker or "ring"
    end
    local normalized, reason = normalizeDefinition(owner, template, existingHandle)
    if not normalized then return nil, reason end

    -- Per-choice predicates and parts live beside the template, because
    -- `normalizeDefinition` builds choices field by field and would drop them.
    --
    -- Only the explicit `choices` form has per-choice rules. In the
    -- single-choice shorthand, `canInteract` and `part` sit on the definition
    -- itself and have already been taken as the target's own -- reading them
    -- again here would evaluate the very same predicate twice per resolve.
    local sourceChoices = definition.choices or {}
    target.choiceRules = {}
    for index, source in ipairs(sourceChoices) do
        local choice = normalized.choices[index]
        if choice and type(source) == "table" then
            local rule = {}
            if source.canInteract ~= nil then
                local predicate, why = normalizePredicate(source.canInteract, "can_interact")
                if not predicate then return nil, why end
                rule.canInteract = predicate
            end
            if source.part ~= nil then
                if kind ~= "globalVehicle" then return nil, "part_requires_global_vehicle" end
                if type(source.part) ~= "string" or VEHICLE_PART_BITS[source.part] == nil then
                    return nil, "invalid_vehicle_part"
                end
                rule.part = source.part
            end
            if next(rule) ~= nil then target.choiceRules[choice.id] = rule end
        end
    end

    target.template = normalized
    target.data = normalized.data
    target.showDistance = normalized.showDistance
    target.source = definition.source == "server" and "server" or "client"
    return target
end

local function cloneTemplate(template)
    local entry = {}
    for key, value in pairs(template) do entry[key] = value end
    local choices = {}
    for index = 1, #template.choices do
        local copy = {}
        for key, value in pairs(template.choices[index]) do copy[key] = value end
        choices[index] = copy
    end
    entry.choices = choices
    return entry
end

local function vehicleDriver(vehicle)
    if type(vehicle.occupants) ~= "table" then return nil end
    for index = 1, #vehicle.occupants do
        local occupant = vehicle.occupants[index]
        if occupant.seat == "driver" then return occupant.playerId end
    end
    return nil
end

local function partIsOpen(vehicle, part)
    local bit = VEHICLE_PART_BITS[part]
    if bit == nil or type(vehicle) ~= "table" or type(vehicle.doors) ~= "number" then return nil end
    return math.floor(vehicle.doors / (2 ^ bit)) % 2 == 1
end

local function targetPayload(target, candidate, part)
    local payload = {
        targetId = target.id,
        owner = target.owner,
        kind = target.kind,
        entity = candidate.entity,
        engineEntity = candidate.engineEntity,
        class = candidate.class,
        record = candidate.record,
        distance = candidate.distance,
        position = candidate.position,
        data = target.data,
    }
    if candidate.playerId then
        payload.playerId = candidate.playerId
        payload.playerName = candidate.playerName
    end
    if candidate.npcId then payload.npcId = candidate.npcId end
    if candidate.vehicle then
        local vehicle = candidate.vehicle
        payload.vehicleId = vehicle.id
        payload.vehicle = {
            id = vehicle.id, entity = vehicle.entity, record = vehicle.record,
            locked = vehicle.locked == true, health = vehicle.health, speed = vehicle.speed,
            doors = vehicle.doors, windows = vehicle.windows, occupants = vehicle.occupants,
            occupied = type(vehicle.occupants) == "table" and #vehicle.occupants > 0,
            driver = vehicleDriver(vehicle),
        }
    elseif candidate.vehicleRow then
        -- What the proximity row knows: identity, record, the lock, whether
        -- anyone is aboard. `partial` says the door mask and the occupant list
        -- are not here; the winner's payload is completed before a key fires.
        local row = candidate.vehicleRow
        payload.vehicleId = row.id
        payload.vehicle = {
            id = row.id, entity = row.entity, record = row.record,
            locked = row.locked == true,
            occupied = (tonumber(row.occupants) or 0) > 0,
            partial = true,
        }
    end
    if candidate.vehicleId ~= nil and payload.vehicleId == nil then payload.vehicleId = candidate.vehicleId end
    if target.kind == "zone" then payload.zoneId = target.id end
    if part then
        payload.part = part
        payload.partIndex = VEHICLE_PART_BITS[part]
        payload.partOpen = partIsOpen(candidate.vehicle or nil, part)
    end
    return payload
end

-- Evaluated at prompt-resolution time, never per frame and never per tick: once
-- when a match is materialised, and again at most every TARGET_RECHECK_SECONDS
-- while it is the entry the arbiter chose. `entry.payload` is the base the
-- predicate sees, so the common case needs no lookup of its own.
local function applyPredicates(entry, target, candidate)
    local base = targetPayload(target, candidate, target.part)
    entry.payload = base
    local allowedAny = false
    if evaluatePredicate(target.owner, target.canInteract, base) then
        for index = 1, #entry.choices do
            local choice = entry.choices[index]
            local rule = target.choiceRules[choice.id]
            local allowed = true
            if rule then
                local payload = base
                if rule.part or rule.canInteract then
                    payload = {}
                    for key, value in pairs(base) do payload[key] = value end
                    payload.choiceId = choice.id
                    if rule.part then
                        payload.part = rule.part
                        payload.partIndex = VEHICLE_PART_BITS[rule.part]
                        payload.partOpen = partIsOpen(candidate.vehicle or nil, rule.part)
                    end
                end
                allowed = evaluatePredicate(target.owner, rule.canInteract, payload)
                choice.payload = payload ~= base and payload or nil
            end
            choice.enabled = allowed and target.template.choices[index].enabled
            if choice.enabled then allowedAny = true end
        end
    else
        for index = 1, #entry.choices do entry.choices[index].enabled = false end
    end
    -- An entry nobody may use must leave the arbitration entirely, or it would
    -- shadow the interaction behind it with a card that refuses to do anything.
    entry.visible = allowedAny and target.template.visible
    entry.recheckAt = Open77.time.monotonic() + TARGET_RECHECK_SECONDS
    return allowedAny
end

local function targetEntryCount()
    local count = 0
    for _, entry in pairs(entries) do
        if entry.target ~= nil then count = count + 1 end
    end
    return count
end

local function dropMatch(target, key)
    local handle = target.matches[key]
    if not handle then return end
    local entry = entries[handle]
    if entry then
        identities[entry.owner .. ":" .. entry.id] = nil
        entries[handle] = nil
        touchEntries()
    end
    target.matches[key] = nil
end

-- Where a materialised entry is, in the two forms the rest of the file reads:
-- `world` for the gather (the resolved point plus the template offset) and
-- `entityText` for the anchor calls. Bumps the revision only when the point
-- actually moved, so a pass over a static scene leaves the gather's cache
-- valid.
local function placeEntry(entry, candidate, now)
    local previousEntity, previousWorld = entry.entity, entry.world
    local offset = entry.offset
    local world = {
        x = candidate.position.x + offset.x,
        y = candidate.position.y + offset.y,
        z = candidate.position.z + offset.z,
    }
    if candidate.entity then
        entry.entity, entry.position = candidate.entity, nil
        entry.entityText = tostring(candidate.entity)
    else
        entry.entity, entry.entityText = nil, nil
        entry.position = candidate.position
    end
    entry.world, entry.worldAt = world, now
    if previousEntity ~= entry.entity or not sameVector(previousWorld, world) then touchEntries() end
end

-- The full vehicle snapshot for a candidate the scan placed from a proximity
-- row, fetched once per candidate per pass and only when a target that
-- matched it has a predicate to evaluate -- a `vehicle`/`part` rule or an
-- export, which may read the door mask, the occupants, the health. A target
-- without one gets the row's own fields in its payload (see `targetPayload`),
-- and the winner's payload is completed by `recheckWinner` before any key
-- can fire on it. `vehicles.get` is one snapshot build in the plugin and one
-- table here, against the whole registry marshalled for every pass.
local function vehicleOf(candidate)
    if candidate.vehicle ~= nil or not candidate.isVehicle or candidate.vehicleId == nil then
        return candidate.vehicle
    end
    countNative("lists")
    local ok, vehicle = pcall(Open77.vehicles.get, candidate.vehicleId)
    if ok and type(vehicle) == "table" then
        candidate.vehicle = vehicle
        candidate.record = candidate.record or vehicle.record
        if type(candidate.record) == "string" then candidate.recordLower = candidate.record:lower() end
    else
        candidate.vehicle = false
    end
    return candidate.vehicle or nil
end

local function materialise(target, candidate, budget, now)
    local handle = target.matches[candidate.key]
    local entry = handle and entries[handle] or nil
    if not entry then
        if budget <= 0 then return false end
        local id = target.id .. ":" .. candidate.key
        if #id > 96 or identities[target.owner .. ":" .. id] then return false end
        entry = cloneTemplate(target.template)
        entry.id = id
        entry.target = target.handle
        entry.lastTrigger = -math.huge
        handle = nextHandle
        nextHandle = nextHandle + 1
        entry.handle = handle
        entries[handle] = entry
        identities[target.owner .. ":" .. id] = handle
        target.matches[candidate.key] = handle
        touchEntries()
    end
    placeEntry(entry, candidate, now)
    if candidate.isVehicle and candidate.vehicle == nil and
        (target.canInteract ~= nil or target.part ~= nil or next(target.choiceRules) ~= nil) then
        vehicleOf(candidate)
    end
    local visible = entry.visible
    applyPredicates(entry, target, candidate)
    if visible ~= entry.visible then touchEntries() end
    return true
end

local function entityPlacement(entity)
    countNative("state")
    local ok, state = pcall(Open77.character.state, entity)
    if not ok or type(state) ~= "table" or state.attached ~= true then return nil end
    local position = state.position
    if type(position) ~= "table" or not finite(position.x) or not finite(position.y) or
        not finite(position.z) then
        return nil
    end
    return position, state.engineId
end

-- A puppet the world query reported without an owner id, standing where a
-- roster says a player is, is that player. The identity ids on a hit are the
-- authoritative mapping; this is the belt for a frame where the roster entry
-- was not yet streamed, and it costs one comparison per player, not a native
-- read per body.
local PLAYER_BODY_MATCH_METRES = 0.75

-- One pass over every source the live target set actually needs, merged into a
-- single candidate list keyed so two sources describing the same thing become
-- one candidate. A vehicle seen by both the world query and the vehicle
-- registry keeps the registry's `record` and the entity anchor, and gains the
-- query's class name.
--
-- THE SCAN MAKES NO PER-BODY NATIVE READ. Every source below already carries a
-- position: the world query resolves it on the game thread, the vehicle
-- registry replicates it, the player roster keeps it. Until 2026-09-19 this
-- pass called `Open77.character.state` once per Open77 NPC, per nearby player
-- and per streamed vehicle to learn where it was -- 56 native reads per pass
-- on the RP server, each of which the plugin answered with a walk over every
-- vehicle in the world (see `CharacterState::ReadVehicle`), ~43 ms per pass,
-- four passes a second: the whole 160 ms/s this resource was measured at.
-- The bounded fallbacks that remain (`SCAN_STATE_BUDGET` reads per pass) are
-- for a body no list can place: a vehicle replica without a position, or an
-- Open77 NPC when the puppet query itself is unavailable.
local function scanCandidates(playerPosition, need, radius)
    local list, byKey, byEngine = {}, {}, {}
    local stateBudget = SCAN_STATE_BUDGET

    local function push(candidate)
        list[#list + 1] = candidate
        byKey[candidate.key] = candidate
        if candidate.engineEntity then byEngine[candidate.engineEntity] = candidate end
        return candidate
    end

    local function fromHit(hit)
        return push({
            key = keyFor(hit),
            engineEntity = hit.engineEntity,
            class = hit.className,
            classLower = type(hit.className) == "string" and hit.className:lower() or nil,
            position = hit.position,
            distance = hit.distance or distance(hit.position, playerPosition),
        })
    end

    -- The Open77 NPC index: one list call, no per-NPC native read. It only
    -- decorates a puppet the world query already placed -- record, entity --
    -- unless the query is unavailable, in which case it is the bounded
    -- fallback source.
    local npcs, npcById
    if need.npcs then
        countNative("lists")
        local at = Open77.time.monotonic()
        npcs = Open77.npcs.all()
        phaseSample("scan.npcs", Open77.time.monotonic() - at)
        if type(npcs) == "table" then
            npcById = {}
            for index = 1, #npcs do
                local npc = npcs[index]
                if type(npc) == "table" and npc.id ~= nil then npcById[npc.id] = npc end
            end
        else
            npcs = nil
        end
    end

    if need.world then
        countNative("query")
        local at = Open77.time.monotonic()
        local hits = Open77.world.nearby(radius)
        phaseSample("scan.world", Open77.time.monotonic() - at)
        if type(hits) ~= "table" then
            complainAboutTargets("world query unavailable for targets (" .. tostring(hits) .. ")")
        else
            -- `hits` is this call's own array, so yielding mid-walk is safe;
            -- 128 parts at ~70 VM instructions each is most of a hook interval.
            for index = 1, #hits do
                if index % RESOLVE_CHUNK == 0 then yieldFrame() end
                local hit = hits[index]
                if type(hit) == "table" and type(hit.engineEntity) == "number" and
                    hit.engineEntity ~= 0 and type(hit.position) == "table" then
                    fromHit(hit)
                end
            end
        end
    end

    local puppetsSeen = false
    if need.puppets then
        countNative("query")
        local at = Open77.time.monotonic()
        local hits = Open77.world.nearby(radius, "puppet")
        phaseSample("scan.puppets", Open77.time.monotonic() - at)
        if type(hits) == "table" then
            puppetsSeen = true
            for index = 1, #hits do
                local hit = hits[index]
                if type(hit) == "table" and type(hit.engineEntity) == "number" and
                    hit.engineEntity ~= 0 and type(hit.position) == "table" then
                    local candidate = byEngine[hit.engineEntity] or fromHit(hit)
                    candidate.isPuppet = true
                    if hit.playerId ~= nil then
                        candidate.playerId = hit.playerId
                        candidate.isPlayer = true
                    elseif hit.npcId ~= nil then
                        candidate.npcId = hit.npcId
                        candidate.isNpc = true
                        local npc = npcById and npcById[hit.npcId] or nil
                        if npc then
                            if type(npc.entity) == "number" and npc.entity ~= 0 then
                                candidate.entity = npc.entity
                            end
                            candidate.record = candidate.record or npc.record
                        end
                    end
                end
            end
        end
    end

    -- Open77 NPCs from the registry itself, for the registry-only targets: the
    -- row carries the replica's position (its authority's last sample, the
    -- latest replicated motion, or the spawn point), so placing every NPC in
    -- the session costs one list read and no engine call. A row without a
    -- position -- a host that does not carry one -- falls to the bounded
    -- body reads below.
    local registryPlaced = 0
    if npcs and need.npcRegistry then
        local px, py, pz = playerPosition.x, playerPosition.y, playerPosition.z
        local sqrt = math.sqrt
        for index = 1, #npcs do
            if index % RESOLVE_CHUNK == 0 then yieldFrame() end
            local npc = npcs[index]
            if type(npc) == "table" and type(npc.entity) == "number" and npc.entity ~= 0 and
                npc.streamed ~= false and npc.id ~= nil then
                local key = identityKey("n", npc.id)
                local candidate = byKey[key]
                if not candidate then
                    local at = npc.position
                    local x, y, z
                    if type(at) == "table" then x, y, z = at.x, at.y, at.z end
                    if type(x) == "number" and type(y) == "number" and type(z) == "number" then
                        registryPlaced = registryPlaced + 1
                        local dx, dy, dz = x - px, y - py, z - pz
                        local away = sqrt(dx * dx + dy * dy + dz * dz)
                        if away <= radius then
                            candidate = push({
                                key = key,
                                position = { x = x + 0.0, y = y + 0.0, z = z + 0.0 },
                                distance = away,
                            })
                        end
                    end
                end
                if candidate then
                    candidate.entity = npc.entity
                    candidate.npcId = npc.id
                    candidate.record = candidate.record or npc.record
                    candidate.isNpc = true
                    candidate.isPuppet = true
                    candidate.fromRegistry = true
                end
            end
        end
    end

    -- Open77 NPCs no list could place: when there was no puppet query and the
    -- rows carry no position, and never more than the budget per pass. The
    -- cursor rotates so a crowd is covered over a few passes rather than
    -- one NPC forever.
    if npcs and need.npcs and not puppetsSeen and registryPlaced == 0 and #npcs > 0 then
        local total = #npcs
        for step = 0, total - 1 do
            if stateBudget <= 0 then break end
            local npc = npcs[((npcFallbackCursor + step) % total) + 1]
            if type(npc) == "table" and type(npc.entity) == "number" and npc.entity ~= 0 and
                npc.streamed ~= false and npc.id ~= nil then
                local key = identityKey("n", npc.id)
                if not byKey[key] then
                    stateBudget = stateBudget - 1
                    local position, engineId = entityPlacement(npc.entity)
                    if position then
                        local candidate = engineId and byEngine[engineId] or nil
                        if not candidate then
                            candidate = push({
                                key = key,
                                engineEntity = engineId,
                                position = position,
                                distance = distance(position, playerPosition),
                            })
                        end
                        candidate.entity = npc.entity
                        candidate.npcId = npc.id
                        candidate.record = candidate.record or npc.record
                        candidate.isNpc = true
                        candidate.isPuppet = true
                    end
                end
            end
        end
        npcFallbackCursor = (npcFallbackCursor + math.min(total, SCAN_STATE_BUDGET)) % total
    end

    if need.vehicles then
        countNative("lists")
        -- The proximity read answers with the few replicas in range, as
        -- nine-field rows; `vehicles.all()` would marshal every replica the
        -- client knows -- forty-odd tables of sixty fields on the RP server,
        -- city-wide -- to find the same few. The full snapshot (doors, health,
        -- occupants: what a payload and a predicate read) is fetched by
        -- `vehicleOf` for a candidate a target actually matched, and only
        -- then. `all()` remains the path for a runtime without `nearby`.
        local vehicles
        local at = Open77.time.monotonic()
        if type(Open77.vehicles.nearby) == "function" then
            vehicles = Open77.vehicles.nearby(radius, { streamed = true })
        else
            vehicles = Open77.vehicles.all()
        end
        phaseSample("scan.vehicles", Open77.time.monotonic() - at)
        if type(vehicles) == "table" then
            local px, py, pz = playerPosition.x, playerPosition.y, playerPosition.z
            local sqrt = math.sqrt
            for index = 1, #vehicles do
                -- The registry lists every replica the client knows, streamed
                -- or not, city-wide; the list is this call's own array.
                if index % RESOLVE_CHUNK == 0 then yieldFrame() end
                local vehicle = vehicles[index]
                if type(vehicle) == "table" and type(vehicle.entity) == "number" and
                    vehicle.entity ~= 0 and vehicle.streamed ~= false then
                    local candidate = vehicle.engineEntity and byEngine[vehicle.engineEntity] or nil
                    if not candidate then
                        -- The replica's own position first: it is the same
                        -- point the anchor will follow once the entry exists.
                        -- Measured in place, and a replica past the radius is
                        -- dropped before any table is built for it -- a
                        -- city's worth of parked cars is the common case. A
                        -- NaN or infinite coordinate fails the radius test on
                        -- its own, so no per-axis finiteness call is needed.
                        local at = vehicle.position
                        local x, y, z
                        if type(at) == "table" then x, y, z = at.x, at.y, at.z end
                        if type(x) == "number" and type(y) == "number" and type(z) == "number" then
                            local dx, dy, dz = x - px, y - py, z - pz
                            local away = sqrt(dx * dx + dy * dy + dz * dz)
                            if away <= radius then
                                candidate = push({
                                    key = identityKey("v", vehicle.id),
                                    engineEntity = vehicle.engineEntity,
                                    position = { x = x + 0.0, y = y + 0.0, z = z + 0.0 },
                                    distance = away,
                                })
                            end
                        elseif stateBudget > 0 then
                            stateBudget = stateBudget - 1
                            local position = entityPlacement(vehicle.entity)
                            if position then
                                candidate = push({
                                    key = identityKey("v", vehicle.id),
                                    engineEntity = vehicle.engineEntity,
                                    position = position,
                                    distance = distance(position, playerPosition),
                                })
                            end
                        end
                    end
                    if candidate then
                        candidate.entity = vehicle.entity
                        candidate.vehicleId = vehicle.id
                        -- A proximity row has no door mask; a full snapshot
                        -- does. The row is enough to place, match and
                        -- describe the vehicle; `vehicleOf` fetches the
                        -- snapshot when a predicate needs the state in it.
                        if vehicle.doors ~= nil then
                            candidate.vehicle = vehicle
                        else
                            candidate.vehicleRow = vehicle
                        end
                        candidate.record = vehicle.record
                        candidate.isVehicle = true
                    end
                end
            end
        end
    end

    if need.players then
        countNative("lists")
        local at = Open77.time.monotonic()
        local nearbyPlayers = Open77.players.nearby(radius)
        phaseSample("scan.players", Open77.time.monotonic() - at)
        if type(nearbyPlayers) == "table" then
            for index = 1, #nearbyPlayers do
                local player = nearbyPlayers[index]
                if type(player) == "table" and type(player.entity) == "number" and
                    player.entity ~= 0 and type(player.position) == "table" then
                    local candidate = byKey[identityKey("p", player.playerId)]
                    if not candidate then
                        -- A puppet with no identity standing on this player is
                        -- this player's body.
                        for _, other in ipairs(list) do
                            if other.isPuppet and not other.isPlayer and other.npcId == nil and
                                other.vehicle == nil and
                                distance(other.position, player.position) <= PLAYER_BODY_MATCH_METRES then
                                candidate = other
                                break
                            end
                        end
                    end
                    if not candidate then
                        candidate = push({
                            key = identityKey("p", player.playerId),
                            position = player.position,
                            distance = player.distance or distance(player.position, playerPosition),
                        })
                    end
                    candidate.entity = player.entity
                    candidate.playerId = player.playerId
                    candidate.playerName = player.name
                    candidate.isPlayer = true
                    candidate.isNpc = false
                    candidate.isPuppet = false
                end
            end
        end
    end

    -- Lower-cased once per candidate, after every source had its say on
    -- `record`, so a selector match allocates nothing.
    for index = 1, #list do
        local candidate = list[index]
        if type(candidate.record) == "string" then candidate.recordLower = candidate.record:lower() end
    end
    return list
end

local function targetMatches(target, candidate)
    if target.kind == "globalVehicle" then return candidate.isVehicle == true end
    if target.kind == "globalPlayer" then return candidate.isPlayer == true end
    if target.kind == "globalNpc" then
        if candidate.isPuppet ~= true or candidate.isPlayer == true then return false end
        -- A registry-only target sees Open77 NPCs alone; a crowd target sees
        -- everything the query reported, which includes those NPCs under the
        -- same key.
        return not target.registryOnly or candidate.npcId ~= nil
    end
    if target.kind == "class" then
        return matchesSelector(target.classes, candidate.classLower)
    end
    -- `model` accepts either name a candidate can actually carry: the TweakDB
    -- record when the source knows one (vehicles and Open77 NPCs), and the RTTI
    -- class name otherwise. On build 2.31 the world query reports no record at
    -- all, so a `model` target on a prop matches by class -- see
    -- wiki/interactions.md, "What `model` can really see".
    return matchesSelector(target.models, candidate.recordLower, candidate.classLower)
end

-- What the live target set needs from the world this pass, and how far out.
local function collectLiveTargets()
    local live, need, radius = {}, {}, 0.0
    for _, target in pairs(targets) do
        if ownerEnabled[target.owner] ~= false then
            live[#live + 1] = target
            if target.showDistance > radius then radius = target.showDistance end
            local kind = target.kind
            if kind == "model" or kind == "class" then
                need.world = true
                need.vehicles = true
                need.npcs = true
            elseif kind == "globalVehicle" then
                need.vehicles = true
            elseif kind == "globalPlayer" then
                need.players = true
            elseif kind == "globalNpc" then
                need.npcs = true
                if target.registryOnly then
                    need.npcRegistry = true
                else
                    -- The crowd: the puppet query, and the players to tell a
                    -- player's body apart from a puppet.
                    need.puppets = true
                    need.players = true
                end
            end
        end
    end
    return live, need, radius
end

-- Returns true when a pass actually ran, so the tick can give the pass the
-- resume to itself: a world query plus every predicate is the one piece of
-- this loop whose cost nobody here controls.
--
-- THE PASS MAY YIELD. The candidate walk is chunked (`RESOLVE_CHUNK`), so a
-- crowded street is several resumes, none of which reaches the host's
-- instruction hook. Everything iterated across a yield is this function's
-- own array -- `live` is snapshotted before the first one, and a target that
-- was removed meanwhile is skipped by identity.
-- Where the last pass ran, for the idle cadence.
local lastResolvePosition = nil

local function resolveTargets(playerPosition)
    local now = Open77.time.monotonic()
    if now < nextTargetResolve then return false end
    local moved = lastResolvePosition == nil or
        distance(lastResolvePosition, playerPosition) >= RESOLVE_MOVE_METRES
    nextTargetResolve = now + (moved and TARGET_RESOLVE_SECONDS or TARGET_RESOLVE_IDLE_SECONDS)
    if moved then
        lastResolvePosition = { x = playerPosition.x, y = playerPosition.y, z = playerPosition.z }
    end

    local live, need, radius = collectLiveTargets()
    if #live == 0 then
        for _, target in pairs(targets) do
            for key in pairs(target.matches) do dropMatch(target, key) end
        end
        return false
    end
    stats.resolves = stats.resolves + 1

    local candidates
    local scanStarted, yieldedAtScan = now, yieldedSeconds
    if need.world or need.puppets or need.vehicles or need.npcs or need.players then
        radius = math.min(math.max(radius, 1.0), WORLD_SCAN_RADIUS_CAP)
        candidates = scanCandidates(playerPosition, need, radius)
    else
        candidates = {}
    end
    phaseSample("scan", Open77.time.monotonic() - scanStarted - (yieldedSeconds - yieldedAtScan))
    -- The scan was the natives; the walk below is the Lua. Two resumes.
    if #candidates > 0 then yieldFrame() end

    local budget = MAX_TARGET_ENTRIES - targetEntryCount()
    local predicateStart = Open77.time.monotonic()
    local yieldedBefore = yieldedSeconds
    local groups = nil
    local work = 0

    for _, target in ipairs(live) do
        local seen = {}
        -- Removed or replaced while this pass yielded: nothing to do for it.
        if targets[target.handle] == target and ownerEnabled[target.owner] ~= false then
            -- A target gated on a group the player is not in resolves to nothing
            -- at all, which is also the cheap path: no scan result is examined.
            local gated = false
            if target.groups then
                groups = groups or localGroups()
                gated = not anyGroup(target.groups, groups)
            end
            if not gated and target.kind == "zone" then
                if zoneContains(target.zone, playerPosition) then
                    local fresh = target.matches.zone == nil
                    local candidate = {
                        key = "zone",
                        position = target.zone.position,
                        distance = distance(target.zone.position, playerPosition),
                    }
                    if materialise(target, candidate, budget, now) then
                        if fresh then budget = budget - 1 end
                        seen.zone = true
                    end
                end
            elseif not gated then
                local matched = 0
                local showDistance = target.showDistance
                for index = 1, #candidates do
                    work = work + 1
                    if work >= RESOLVE_CHUNK then
                        work = 0
                        yieldFrame()
                    end
                    local candidate = candidates[index]
                    if candidate.distance <= showDistance and targetMatches(target, candidate) then
                        local fresh = target.matches[candidate.key] == nil
                        work = work + RESOLVE_MATERIALISE_WEIGHT
                        if materialise(target, candidate, budget, now) then
                            if fresh then budget = budget - 1 end
                            seen[candidate.key] = true
                            matched = matched + 1
                            if matched >= target.maxMatches then break end
                        end
                    end
                end
            end
        end
        if targets[target.handle] == target then
            for key in pairs(target.matches) do
                if not seen[key] then dropMatch(target, key) end
            end
        end
    end

    local spent = Open77.time.monotonic() - predicateStart - (yieldedSeconds - yieldedBefore)
    phaseSample("predicates", spent)
    if spent > PREDICATE_BUDGET_SECONDS then
        complainAboutTargets(string.format(
            "target resolution took %.1f ms; a canInteract predicate is too slow", spent * 1000))
    end
    return true
end

-- The winner is the entry a key is about to fire on, so its predicates get a
-- second look on a faster clock than the resolve pass -- still time-boxed, and
-- still never per frame.
local function recheckWinner(candidate)
    if not candidate then return end
    local entry = candidate.entry
    if entry.target == nil or entry.payload == nil then return end
    local target = targets[entry.target]
    if not target then return end
    local now = Open77.time.monotonic()
    if entry.recheckAt and now < entry.recheckAt then return end
    local payload = entry.payload
    payload.distance = candidate.distance
    payload.position = candidate.position
    local visible = entry.visible
    applyPredicates(entry, target, {
        key = "recheck",
        entity = entry.entity,
        engineEntity = payload.engineEntity,
        class = payload.class,
        record = payload.record,
        position = candidate.position,
        distance = candidate.distance,
        playerId = payload.playerId,
        playerName = payload.playerName,
        npcId = payload.npcId,
        vehicle = payload.vehicleId and Open77.vehicles.get(payload.vehicleId) or nil,
    })
    if entry.visible ~= visible then touchEntries() end
    if not entry.visible then
        activeHandle = nil
        candidate.active = false
    end
end

local function addTarget(owner, definition)
    local count = 0
    for _ in pairs(targets) do count = count + 1 end
    if count >= MAX_TARGETS then return response(false, { error = "target_limit" }) end
    local target, reason = normalizeTarget(owner, definition)
    if not target then return response(false, { error = reason }) end
    local identity = owner .. ":" .. target.id
    if targetIdentities[identity] then return response(false, { error = "duplicate_target_id" }) end
    local handle = nextTargetHandle
    nextTargetHandle = nextTargetHandle + 1
    target.handle = handle
    target.matches = {}
    targets[handle] = target
    targetIdentities[identity] = handle
    nextTargetResolve = 0
    lastResolvePosition = nil
    return response(true, { handle = handle, id = target.id })
end

local function removeTarget(owner, handle)
    handle = tonumber(handle)
    local target = handle and targets[handle] or nil
    if not target then return response(false, { error = "target_not_found" }) end
    if target.owner ~= owner then return response(false, { error = "not_owner" }) end
    for key in pairs(target.matches) do dropMatch(target, key) end
    targetIdentities[target.owner .. ":" .. target.id] = nil
    targets[handle] = nil
    return response(true)
end

local function targetSnapshot(target)
    local matches = {}
    for key, handle in pairs(target.matches) do
        matches[#matches + 1] = { key = key, handle = handle }
    end
    table.sort(matches, function(left, right) return left.handle < right.handle end)
    return {
        handle = target.handle, owner = target.owner, id = target.id, kind = target.kind,
        source = target.source, maxMatches = target.maxMatches, part = target.part,
        npcs = target.npcs, registryOnly = target.registryOnly == true,
        distance = target.template.distance, markerDistance = target.showDistance,
        matches = matches, matchCount = #matches,
    }
end

exports("addTarget", function(definition)
    local owner, callerError = caller()
    if not owner then return response(false, { error = callerError }) end
    if type(definition) == "table" then definition.source = nil end
    return addTarget(owner, definition)
end)
exports("removeTarget", function(handle)
    local owner, callerError = caller()
    if not owner then return response(false, { error = callerError }) end
    return removeTarget(owner, handle)
end)
exports("clearTargets", function()
    local owner, callerError = caller()
    if not owner then return response(false, { error = callerError }) end
    local removed = 0
    for handle, target in pairs(targets) do
        if target.owner == owner and target.source == "client" then
            for key in pairs(target.matches) do dropMatch(target, key) end
            targetIdentities[target.owner .. ":" .. target.id] = nil
            targets[handle] = nil
            removed = removed + 1
        end
    end
    return response(true, { removed = removed })
end)
exports("getTarget", function(handle)
    local owner = caller()
    if not owner then return nil end
    local target = targets[tonumber(handle)]
    if not target or target.owner ~= owner then return nil end
    return targetSnapshot(target)
end)
exports("allTargets", function()
    local owner = caller()
    if not owner then return {} end
    local result = {}
    for _, target in pairs(targets) do
        if target.owner == owner then result[#result + 1] = targetSnapshot(target) end
    end
    table.sort(result, function(left, right) return left.handle < right.handle end)
    return result
end)

-- FiveM-shaped sugar. Every one of these is `addTarget` with `kind` filled in,
-- so there is exactly one implementation and one set of refusal tokens.
local function sugar(name, kind, key)
    exports(name, function(first, second)
        local owner, callerError = caller()
        if not owner then return response(false, { error = callerError }) end
        local definition = second
        if key == nil then definition = first end
        if type(definition) ~= "table" then
            return response(false, { error = "definition_must_be_a_table" })
        end
        local merged = {}
        for field, value in pairs(definition) do merged[field] = value end
        merged.kind = kind
        merged.source = nil
        if key ~= nil then merged[key] = first end
        return addTarget(owner, merged)
    end)
end
sugar("addModel", "model", "models")
sugar("addClass", "class", "classes")
sugar("addGlobalVehicle", "globalVehicle")
sugar("addGlobalPlayer", "globalPlayer")
sugar("addGlobalPed", "globalNpc")
sugar("addGlobalNpc", "globalNpc")
sugar("addZone", "zone")
exports("addBoxZone", function(definition)
    local owner, callerError = caller()
    if not owner then return response(false, { error = callerError }) end
    if type(definition) ~= "table" then
        return response(false, { error = "definition_must_be_a_table" })
    end
    local merged = {}
    for field, value in pairs(definition) do merged[field] = value end
    merged.kind, merged.source = "zone", nil
    merged.zone = definition.zone or {
        shape = "box", position = definition.position, size = definition.size,
        heading = definition.heading,
    }
    return addTarget(owner, merged)
end)
exports("addSphereZone", function(definition)
    local owner, callerError = caller()
    if not owner then return response(false, { error = callerError }) end
    if type(definition) ~= "table" then
        return response(false, { error = "definition_must_be_a_table" })
    end
    local merged = {}
    for field, value in pairs(definition) do merged[field] = value end
    merged.kind, merged.source = "zone", nil
    merged.zone = definition.zone or {
        shape = "sphere", position = definition.position, radius = definition.radius,
        maxHeight = definition.maxHeight,
    }
    return addTarget(owner, merged)
end)

-- Server-declared targets. The wire is an ordinary authenticated net event, not
-- a protocol message: a job resource declares once on the server and every
-- client applies it. The owner is whatever the SERVER says it is -- a client
-- cannot forge one, because this event only ever arrives from the server.
local function applyServerDeclaration(message)
    if type(message) ~= "table" or not validName(message.owner, 64) then return end
    local owner = message.owner
    removeOwner(owner, "server")
    if type(message.targets) ~= "table" then return end
    for index = 1, math.min(#message.targets, MAX_TARGETS) do
        local definition = message.targets[index]
        if type(definition) == "table" then
            definition.source = "server"
            local result = addTarget(owner, definition)
            if not result.ok then
                print("[open77_interactions] server target refused for " .. owner .. ": " ..
                    tostring(result.error))
            end
        end
    end
end

RegisterNetEvent("open77:interactions:targets", applyServerDeclaration)
RegisterNetEvent("open77:interactions:retract", function(message)
    if type(message) ~= "table" or not validName(message.owner, 64) then return end
    removeOwner(message.owner, "server")
end)

local function releaseAnchor(handle)
    local anchor = anchors[handle]
    if not anchor then return end
    if nativeCardHandle == handle then nativeCardHandle = nil end
    anchors[handle] = nil
    anchorIds[anchor.id] = nil
    anchorScreens[handle] = nil
    if anchorsAvailable then Open77.anchors.remove(anchor.id) end
end

local function releaseAnchors()
    anchors, anchorIds, anchorScreens = {}, {}, {}
    nativeCardHandle = nil
    if anchorsAvailable then Open77.anchors.clear() end
end

-- Set when the native registry no longer matches what this file believes: an
-- anchor the plugin dropped, a create the quota refused. `syncAnchors` runs
-- on the next cycle whether or not the eligible set changed.
local anchorsDirty = false

-- Reads back what the plugin projected on its last frame. One native call for
-- the whole set, replacing the per-entry `Open77.camera.project` this loop used
-- to make, and it doubles as the reconciliation point: an anchor the plugin has
-- dropped (its page went away, or the quota reclaimed it) stops being listed and
-- is forgotten here rather than lingering as a dead handle.
-- Whether the last frame read differed from the one before it: an anchor
-- appeared or vanished, or any projection moved. A cycle whose frame is
-- identical, whose eligible set was reused and whose entries are unchanged
-- can keep last cycle's winner instead of arbitrating the same numbers again
-- -- a player standing still with a still camera is the RP server's common
-- state, and the select was its largest remaining per-cycle cost.
local frameChanged = true

local function readAnchorFrame()
    local previous = anchorScreens
    anchorScreens = {}
    frameChanged = false
    if not anchorsAvailable then return end
    countNative("lists")
    -- `frame()` is the per-frame half of `list()` -- projection, distance,
    -- resolved point -- in two tables per anchor instead of six; `list()`
    -- remains the read on a runtime without it.
    local list
    if type(Open77.anchors.frame) == "function" then
        list = Open77.anchors.frame()
    else
        list = Open77.anchors.list()
    end
    if type(list) ~= "table" then return end
    local alive = {}
    for index = 1, #list do
        local anchor = list[index]
        local id = anchor.id
        if type(id) ~= "string" then id = tostring(id) end
        alive[id] = true
        local handle = anchorIds[id]
        -- The native row itself is kept -- its screen coordinates (`x`/`y`,
        -- or the `screen` sub-table of a `list()` row), `onScreen`,
        -- `distance`, `resolved` -- rather than copied into a fresh table
        -- per anchor per cycle; the readers below take what they need.
        if handle and anchor.projected and (type(anchor.screen) == "table" or type(anchor.x) == "number") then
            anchorScreens[handle] = anchor
            if not frameChanged then
                local before = previous[handle]
                if not before then
                    frameChanged = true
                else
                    local now, was = anchor.screen or anchor, before.screen or before
                    if now.x ~= was.x or now.y ~= was.y or anchor.onScreen ~= before.onScreen then
                        frameChanged = true
                    end
                end
            end
        end
    end
    if not frameChanged then
        for handle in pairs(previous) do
            if anchorScreens[handle] == nil then
                frameChanged = true
                break
            end
        end
    end
    for id, handle in pairs(anchorIds) do
        if not alive[id] then
            anchorIds[id] = nil
            anchors[handle] = nil
            anchorScreens[handle] = nil
            anchorsDirty = true
        end
    end
end

-- Everything the player could plausibly see, ranked by how much it deserves one
-- of the 32 anchor slots. The ordering is deliberately projection-free, because
-- it has to be decided *before* the anchors exist: an entry the player is
-- already close enough to trigger outranks a distant marker, since focus can
-- only ever narrow that set further. The latched entry is pinned so the enter/
-- leave hysteresis can never lose its own projection mid-hold.
--
-- The order is one integer per candidate, packed most-significant-first --
-- not reachable, not latched, priority descending in thousandths, player
-- distance ascending in centimetres, then the handle so the order is total --
-- and the sort is `table.sort` on the bare integers, which runs entirely in C
-- and costs this resume nothing. The five-branch Lua comparator it replaces
-- ran ~350 times at ~25 VM instructions each with 45 prompts in range, and
-- ~2 900 times at the 256-entry cap: on its own more than the hook interval
-- (see the tick below). The fields are sized so the value stays under 2^62
-- and exact as a Lua integer: priority is bounded to +/-1000 and showDistance
-- to 250 m by `normalizeDefinition`, so the centimetre field never overflows.
local function rankOf(reachable, latched, priority, playerDistance, handle)
    return ((reachable and 0 or 1) << 61)
        + ((latched and 0 or 1) << 60)
        + (math.floor((1000.0 - priority) * 1000 + 0.5) << 39)
        + (math.floor(playerDistance * 100) << 24)
        + (handle & 0xFFFFFF)
end

-- Entries visited per resume. Measured at ~120 VM instructions per entry --
-- the position, the distance, the candidate table, the rank -- so a chunk is
-- ~4 800, and the resume that carries it has room left for the anchor frame
-- fold before the first chunk and the rank mapping after the last. 60
-- entries, the measured RP scale, is two resumes; the 256-entry cap is seven.
local GATHER_CHUNK = 40

-- What the last full gather saw, so the next cycle can tell whether anything
-- it depends on has changed. `entities` lists the candidates whose position
-- comes from a body rather than a fixed point; each is re-checked against its
-- anchor's resolved point before the set is reused.
local lastGather = nil

local function gatherEligible(playerPosition, now)
    -- Snapshot the handles before yielding: `next` is undefined across a
    -- resume boundary if a create lands mid-traversal, and entries are created
    -- by other resources' export calls, which run exactly between this loop's
    -- resumes. An entry removed meanwhile simply reads back as nil.
    local handles, total = {}, 0
    for handle in pairs(entries) do
        total = total + 1
        handles[total] = handle
    end
    gatherStateBudget = GATHER_STATE_BUDGET
    local ranks, byRank, count = {}, {}, 0
    local entityCandidates = {}
    local revision = entriesRevision
    local px, py, pz = playerPosition.x, playerPosition.y, playerPosition.z
    local sqrt = math.sqrt
    for index = 1, total do
        if index % GATHER_CHUNK == 0 then yieldFrame() end
        local entry = entries[handles[index]]
        if entry and entry.visible and ownerEnabled[entry.owner] ~= false then
            local position
            if entry.entity then position = worldPosition(entry, now) else position = entry.world end
            if position then
                local dx, dy, dz = position.x - px, position.y - py, position.z - pz
                local playerDistance = sqrt(dx * dx + dy * dy + dz * dz)
                if playerDistance <= entry.showDistance then
                    local reachable = playerDistance <= entry.distance + 0.35
                    local latched = activeHandle == entry.handle
                    local rank = rankOf(reachable, latched, entry.priority, playerDistance, entry.handle)
                    -- Handles only collide in the low 24 bits after 16.7 M
                    -- creates; the nudge keeps the order total even then.
                    while byRank[rank] do rank = rank + 1 end
                    count = count + 1
                    ranks[count] = rank
                    local candidate = {
                        entry = entry,
                        position = position,
                        distance = playerDistance,
                        reachable = reachable,
                        latched = latched,
                    }
                    byRank[rank] = candidate
                    if entry.entity then entityCandidates[#entityCandidates + 1] = candidate end
                end
            end
        end
    end
    table.sort(ranks)
    local eligible = {}
    for index = 1, count do eligible[index] = byRank[ranks[index]] end
    lastGather = {
        eligible = eligible,
        entities = entityCandidates,
        position = { x = playerPosition.x, y = playerPosition.y, z = playerPosition.z },
        -- The revision as it was when the walk STARTED: a create that landed
        -- during a yield above bumped it past this, which is exactly what makes
        -- the next cycle rebuild.
        revision = revision,
    }
    return eligible
end

-- Whether last cycle's eligible set is still exact: nothing was created,
-- updated, removed, materialised or toggled since, the player has not moved
-- past GATHER_MOVE_EPSILON, and every entity candidate's anchor still resolves
-- within the same epsilon of where it was ranked. Anything else rebuilds.
local function gatherStillValid(playerPosition)
    local previous = lastGather
    if not previous or previous.revision ~= entriesRevision then return false end
    if distance(previous.position, playerPosition) > GATHER_MOVE_EPSILON then return false end
    local entityCandidates = previous.entities
    for index = 1, #entityCandidates do
        local candidate = entityCandidates[index]
        local row = anchorScreens[candidate.entry.handle]
        if not row or not row.resolved then return false end
        if distance(row.resolved, candidate.position) > GATHER_MOVE_EPSILON then return false end
    end
    return true
end

local function anchorOptions(candidate, useCard)
    local entry = candidate.entry
    local options = {
        tag = "interaction." .. tostring(entry.handle),
        maxDistance = entry.showDistance + ANCHOR_DISTANCE_MARGIN,
    }
    if useCard then
        options.render = "card"
        -- Created invisible. Every eligible entry needs an anchor so that
        -- `list()` can report where it is on screen -- that is how focus is
        -- decided -- but only the winner is drawn. An invisible anchor is still
        -- projected and still listed; it just produces no card.
        options.visible = false
        options.presentation = {
            accent = entry.color,
            showDistance = true,
        }
    else
        options.page = page
    end
    if entry.entity then
        options.entity = entry.entityText or tostring(entry.entity)
        options.offset = entry.offset
    else
        -- A position anchor carries no offset of its own, so the offset is baked
        -- into the point -- the same sum `worldPosition` reports.
        options.position = candidate.position
    end
    return options
end

local function createAnchor(candidate)
    local entry = candidate.entry
    local useCard = cardSupport ~= false
    countNative("anchorUpdates")
    local id, reason = Open77.anchors.create(anchorOptions(candidate, useCard))
    if not id and useCard and cardSupport == nil then
        -- One probe, once: a client older than the native styles refuses the
        -- `render` field, and there is no capability query to ask first.
        print("[open77_interactions] native card unavailable (" .. tostring(reason) ..
            "); falling back to the page")
        cardSupport = false
        useCard = false
        id, reason = Open77.anchors.create(anchorOptions(candidate, false))
    end
    if id and cardSupport == nil then cardSupport = useCard end
    if not id then
        if reason == "anchors_backend_unavailable" then
            print("[open77_interactions] native anchors unavailable (" .. tostring(reason) ..
                "); falling back to Lua-tick projection")
            anchorsAvailable = false
            return nil
        end
        -- Quota pressure is transient -- another resource may release a slot --
        -- so keep retrying, but do not narrate it every 33 ms.
        anchorsDirty = true
        local now = Open77.time.monotonic()
        if now >= nextQuotaComplaint then
            nextQuotaComplaint = now + 10.0
            print("[open77_interactions] anchor refused: " .. tostring(reason))
        end
        return nil
    end
    id = tostring(id)
    anchors[entry.handle] = {
        id = id,
        kind = entry.entity and "entity" or "position",
        entity = entry.entity and (entry.entityText or tostring(entry.entity)) or nil,
        offset = entry.offset,
        point = candidate.position,
        maxDistance = entry.showDistance + ANCHOR_DISTANCE_MARGIN,
        drawn = false,
    }
    anchorIds[id] = entry.handle
    return anchors[entry.handle]
end

-- Keeps the native registry in step with the ranked eligible set. Only what
-- actually moved is patched: an anchor update is a native call and the common
-- case -- a prop bolted to the world -- never moves at all. Runs when the set
-- was rebuilt or the registry is known to be out of step (`anchorsDirty`); a
-- cycle that reused its eligible set skips it entirely.
local function syncAnchors(eligible)
    if not anchorsAvailable or not page then return end
    anchorsDirty = false
    local keep = {}
    local budget = ANCHOR_BUDGET
    for index = 1, #eligible do
        if budget <= 0 then break end
        local candidate = eligible[index]
        local entry = candidate.entry
        local anchor = anchors[entry.handle]
        -- The kind is fixed at creation, so an entry that swapped `position` for
        -- `entity` (or back) needs a new anchor rather than a patch.
        if anchor and anchor.kind ~= (entry.entity and "entity" or "position") then
            releaseAnchor(entry.handle)
            anchor = nil
        end
        if anchor then
            if anchor.kind == "entity" then
                local entityText = entry.entityText or tostring(entry.entity)
                if anchor.entity ~= entityText then
                    countNative("anchorUpdates")
                    Open77.anchors.update(anchor.id, { entity = entityText })
                    anchor.entity = entityText
                end
                if not sameVector(anchor.offset, entry.offset) then
                    countNative("anchorUpdates")
                    Open77.anchors.update(anchor.id, { offset = entry.offset })
                    anchor.offset = entry.offset
                end
            elseif not sameVector(anchor.point, candidate.position) then
                countNative("anchorUpdates")
                Open77.anchors.update(anchor.id, { position = candidate.position })
                anchor.point = candidate.position
            end
            local maxDistance = entry.showDistance + ANCHOR_DISTANCE_MARGIN
            if anchor.maxDistance ~= maxDistance then
                countNative("anchorUpdates")
                Open77.anchors.update(anchor.id, { maxDistance = maxDistance })
                anchor.maxDistance = maxDistance
            end
        else
            anchor = createAnchor(candidate)
            if not anchorsAvailable then return end
        end
        if anchor then
            keep[entry.handle] = true
            budget = budget - 1
        end
    end
    for handle in pairs(anchors) do
        if not keep[handle] then releaseAnchor(handle) end
    end
end

-- Candidates arbitrated per resume. Measured at ~75 VM instructions each --
-- most of it the Lua projection of the candidates past the anchor budget --
-- so 120 in range was 9 400 in one resume, a hair under the hook interval.
-- `eligible` is this loop's own array, so yielding mid-walk is safe.
local SELECT_CHUNK = 48

local function selectCandidate(eligible)
    local best
    -- With the native card, a candidate without an anchor cannot be drawn at
    -- all (`pushNativeCard` refuses it), so projecting it in Lua would decide
    -- nothing: the anchors are ranked reachable-first, and an unanchored entry
    -- is by construction one the player cannot act on this cycle. The Lua
    -- projection is kept for the page fallback, which draws from it.
    local projectUnanchored = cardSupport ~= true
    for index = 1, #eligible do
        if index % SELECT_CHUNK == 0 then yieldFrame() end
        local candidate = eligible[index]
        local entry = candidate.entry
        -- The anchor is the projection whenever there is one; the Lua projection
        -- covers the first tick of a new anchor, an entry that lost its slot, and
        -- a plugin without the anchor service.
        local row = anchorScreens[entry.handle]
        local anchor = row and anchors[entry.handle] or nil
        local screen, onScreen
        if row then
            screen, onScreen = row.screen or row, row.onScreen == true
        elseif projectUnanchored then
            countNative("project")
            local projected = Open77.camera.project(candidate.position)
            if projected then
                screen, onScreen = projected, projected.onScreen == true
            end
        end
        if screen and onScreen then
            local dx, dy = screen.x - 0.5, screen.y - 0.5
            -- Enter on the configured limits, leave with a small margin. Camera
            -- projection and player transforms are sampled independently, so a
            -- hard boundary otherwise makes the card oscillate while standing
            -- still.
            local latched = activeHandle == entry.handle
            local focusLimit = entry.focusRadius + (latched and 0.045 or 0)
            local distanceLimit = entry.distance + (latched and 0.35 or 0)
            local focused = not entry.requireLookAt or
                math.sqrt(dx * dx + dy * dy) <= focusLimit
            local active = candidate.distance <= distanceLimit and focused
            candidate.projection = screen
            candidate.active = active
            candidate.focused = focused
            -- Only claim an anchor id when the anchor is what produced this
            -- projection: the page hides the card when the id it was told to
            -- follow is missing from the frame, so a stale id would blank it.
            candidate.anchorId = anchor and anchor.id or nil
            if not best or (candidate.active and not best.active) or
                (candidate.active == best.active and entry.priority > best.entry.priority) or
                (candidate.active == best.active and entry.priority == best.entry.priority and
                 candidate.distance < best.distance) then best = candidate end
        else
            candidate.active = false
        end
    end
    if best and best.active then
        activeHandle = best.entry.handle
    else
        activeHandle = nil
    end
    return best
end

local function trigger(candidate, choice)
    local now = Open77.time.monotonic()
    local entry = candidate.entry
    if now - entry.lastTrigger < entry.cooldown then return end
    entry.lastTrigger = now
    local payload = {
        interactionId = entry.id,
        handle = entry.handle,
        owner = entry.owner,
        choiceId = choice.id,
        key = choice.key,
        position = candidate.position,
        distance = candidate.distance,
        data = choice.data,
        interactionData = entry.data,
    }
    -- A materialised target adds what it matched on. Every one of these fields
    -- is client presentation evidence and none of it is authority: the entity,
    -- the distance, the group gate and the vehicle state were all read on a
    -- machine the player owns. The server re-derives them or it grants nothing.
    if entry.payload then
        local source = (choice.payload or entry.payload)
        for key, value in pairs(source) do
            if payload[key] == nil then payload[key] = value end
        end
    end
    local event = choice.event or entry.event
    if event then TriggerEvent(event, payload) end
    if event ~= "open77:interaction" then TriggerEvent("open77:interaction", payload) end
    -- D11. A prompt used on an Open77 NPC is reported to the server as well, on the
    -- reserved `open77:npcs:` transport the server consumes and never forwards. Only
    -- the minimum intent travels -- which NPC, which prompt, which choice -- and
    -- the server re-derives the NPC, the bucket and the distance before it
    -- publishes `onNpcInteracted` to every server resource. Everything else in the
    -- payload above stays what it is: presentation evidence, not authority.
    if payload.kind == "globalNpc" and payload.npcId ~= nil then
        TriggerServerEvent("open77:npcs:interacted",
            tostring(payload.npcId), tostring(payload.interactionId), tostring(payload.choiceId or ""))
    end
end

local function resetHold()
    hold = { token = nil, startedAt = 0, fired = false }
end

local function sweepStoppedOwners()
    local now = Open77.time.monotonic()
    if now < nextOwnerSweep then return end
    nextOwnerSweep = now + 1.0
    for owner, generation in pairs(ownerGenerations) do
        if GetResourceState(owner) ~= "running" or Open77.resource.generation(owner) ~= generation then
            removeOwner(owner)
            ownerGenerations[owner] = nil
            ownerEnabled[owner] = nil
        end
    end
end

-- The set of keys any entry could fire on, rebuilt only when the entries
-- change: the previous shape walked every entry and every choice per cycle.
local keySet, keySetRevision = {}, -1
local function actionKeys()
    if keySetRevision == entriesRevision then return keySet end
    keySet = {}
    for _, entry in pairs(entries) do
        local choices = entry.choices
        for index = 1, #choices do keySet[choices[index].key] = true end
    end
    keySetRevision = entriesRevision
    return keySet
end

local function evaluateInput(candidate)
    local keys = actionKeys()
    local captured = Open77.input.isCaptured()
    local current = {}
    for key in pairs(keys) do current[key] = Open77.input.isDown(key) == true end
    local progress = {}
    if not candidate or not candidate.active or captured then
        resetHold()
    else
        local now = Open77.time.monotonic()
        for _, choice in ipairs(candidate.entry.choices) do
            local down = current[choice.key] == true
            local pressed = down and previousKeys[choice.key] ~= true
            local token = tostring(candidate.entry.handle) .. ":" .. choice.id
            if choice.enabled and choice.holdSeconds <= 0 and pressed then
                trigger(candidate, choice)
            elseif choice.enabled and choice.holdSeconds > 0 then
                if down then
                    if hold.token ~= token then hold = { token = token, startedAt = now, fired = false } end
                    local elapsed = math.max(0, now - hold.startedAt)
                    progress[choice.id] = math.min(1, elapsed / choice.holdSeconds)
                    if progress[choice.id] >= 1 and not hold.fired then
                        hold.fired = true
                        trigger(candidate, choice)
                    end
                elseif hold.token == token then resetHold() end
            end
        end
    end
    previousKeys = current
    return progress
end

-- Content for the one card the plugin draws. Position is not here and must not
-- be: the plugin already has it, per frame, and anything this tick published
-- would be the stale coordinate the native path exists to eliminate.
--
-- Visibility is decided here too, but from `candidate` -- which `gatherEligible`
-- rebuilt from live positions this tick -- and the plugin then re-tests the
-- distance band itself on every frame it draws. Both halves are recomputed; the
-- card cannot outlive the thing it points at.
--
-- The update is sent only when its content changed. A prompt the player is
-- standing next to used to cost one native patch -- a table marshalled across
-- the boundary -- every cycle, to say the same label again.
local function pushNativeCard(candidate, progress)
    if cardSupport ~= true then return end
    local handle = candidate and candidate.entry.handle or nil
    if handle and not anchors[handle] then handle = nil end

    if nativeCardHandle and nativeCardHandle ~= handle then
        local previous = anchors[nativeCardHandle]
        if previous then
            countNative("anchorUpdates")
            Open77.anchors.update(previous.id, { visible = false })
            previous.drawn = false
            previous.card = nil
        end
        nativeCardHandle = nil
    end
    if not handle then return end

    local entry = candidate.entry
    local anchor = anchors[handle]
    local shown, extra = nil, 0
    for _, choice in ipairs(entry.choices) do
        if choice.enabled then
            if shown == nil then shown = choice else extra = extra + 1 end
        end
    end
    if shown == nil then
        if anchor.drawn then
            countNative("anchorUpdates")
            Open77.anchors.update(anchor.id, { visible = false })
            anchor.drawn = false
            anchor.card = nil
        end
        nativeCardHandle = nil
        return
    end

    -- One keycap, so a prompt with several choices says how many more there are
    -- rather than silently hiding them. A resource that genuinely needs a menu
    -- wants a page, not a card.
    local sublabel = shown.description
    if extra > 0 then
        sublabel = (sublabel and (sublabel .. "  ") or "") .. "+" .. tostring(extra) .. " more"
    end
    local color = candidate.active and "#F2F6F8" or "#8D99A8"  -- --op77-text / --op77-text-dim
    local accent = shown.color or entry.color
    -- Only a hold shows a bar; a tap prompt with a permanent empty track reads
    -- as broken.
    local bar = shown.holdSeconds > 0 and (progress[shown.id] or 0) or -1

    local card = anchor.card
    if anchor.drawn and card and card.label == shown.label and card.sublabel == sublabel and
        card.key == shown.key and card.color == color and card.accent == accent and
        card.progress == bar then
        nativeCardHandle = handle
        return
    end

    countNative("anchorUpdates")
    Open77.anchors.update(anchor.id, {
        visible = true,
        presentation = {
            label = shown.label,
            sublabel = sublabel,
            key = shown.key,
            color = color,
            accent = accent,
            progress = bar,
            showDistance = true,
        },
    })
    anchor.drawn = true
    anchor.card = { label = shown.label, sublabel = sublabel, key = shown.key, color = color,
        accent = accent, progress = bar }
    nativeCardHandle = handle
end

local function push(candidate, progress)
    if cardSupport == true then
        -- The plugin owns the prompt now. Tell the page once, not every tick:
        -- the message is idempotent and repeating it 30 times a second would put
        -- back exactly the IPC this change removes.
        if page and ready and not pageHidden then
            page:send("interaction:update", { visible = false })
            pageHidden = true
        end
        return
    end
    pageHidden = false
    if not page or not ready then return end
    if not candidate then
        page:send("interaction:update", { visible = false })
        return
    end
    local choices = {}
    for _, choice in ipairs(candidate.entry.choices) do
        choices[#choices + 1] = {
            id = choice.id, label = choice.label, description = choice.description,
            icon = choice.icon, key = choice.key, color = choice.color,
            hold = choice.holdSeconds > 0, progress = progress[choice.id] or 0,
            enabled = choice.enabled and candidate.active,
        }
    end
    local scaleRange = math.max(0.001, candidate.entry.showDistance - candidate.entry.distance)
    local proximity = math.max(0, math.min(1,
        (candidate.entry.showDistance - candidate.distance) / scaleRange))
    local renderedScale = candidate.entry.markerScale *
        (1 + (candidate.entry.markerNearScale - 1) * proximity)
    page:send("interaction:update", {
        visible = true,
        -- Content only. `x`/`y`/`distance` are the fallback the page uses when
        -- `anchor` is absent, i.e. when this tick projected in Lua; otherwise the
        -- page takes the position from the plugin's own per-frame anchor feed and
        -- ignores them.
        anchor = candidate.anchorId,
        x = candidate.projection.x,
        y = candidate.projection.y,
        distance = candidate.distance,
        active = candidate.active,
        color = candidate.entry.color,
        marker = candidate.entry.marker,
        markerScale = renderedScale,
        markerAnimated = candidate.entry.markerAnimated,
        choices = choices,
    })
end

-- ---------------------------------------------------------------------------
-- The arbitration tick
--
-- THE TICK IS SEVERAL RESUMES, NOT ONE. Measured 2026-09-18 on an RP server
-- whose client ran ~70 resources in the downloaded host (45 platform, 39
-- gamemode): `ResourceHost::Tick` slices its frame budget by the number of
-- running resources, and the instruction hook guarding a resume fires every
-- 10 000 VM instructions and raises the moment the wall clock is past that
-- slice. A resume that stays under 10 000 instructions is never measured; one
-- that reaches the hook on a loaded client is killed -- and `ResumeTask`
-- retires a coroutine that raises, so this loop was gone for the session
-- seventeen seconds after start, with one line to show for it:
--
--   open77_interactions/client/main.lua:2196: Open77 script execution budget
--   exceeded
--
-- That was ~45 world POIs in range (rp_housing 16, rp_shops 5, rp_garage 3,
-- rp_bank 3, ...). Every E prompt on the server was dead from then on: the
-- native anchors kept drawing the cards, and nothing ever focused or fired.
-- The same loop was fine at ~30 resources, which is the actual defect -- the
-- number of resources a server loads is not something this tick may depend
-- on. The host's slice floor was raised in the same change (see
-- `kMinimumSlice` in scripting/src/ResourceHost.cpp) so one hook interval
-- survives whatever the count; this file's side is to never need more than
-- one per resume.
--
-- WHAT A RESUME COSTS IS THE NATIVES, NOT THE LUA. Measured 2026-09-19 on the
-- same server, with 40 worldui rings, two `globalNpc` targets and one
-- `globalVehicle` registered: the host attributed 2 200 us per frame to this
-- resource -- 160 ms of every second, a 69 ms peak -- and every millisecond
-- of it tracked the resolve pass, ~43 ms per pass at four passes a second.
-- The Lua of that pass was ~16 000 VM instructions; the cost was the 56
-- `Open77.character.state` reads it made to learn where NPCs, players and
-- vehicles stood, each of which the plugin answered by walking every vehicle
-- in the world. The pass now reads positions from the sources that already
-- carry them (`scanCandidates`), runs at 2 Hz, and is chunked; the gather
-- reuses its ranked set while nothing it depends on has changed; the select
-- projects nothing the card could not draw; the card is patched only when its
-- content changes; and every phase is timed, so the next regression is a
-- number on the `stats` line rather than a feeling while running.
--
-- Replayed offline against this file with a count hook (Lua 5.4.8, the
-- vendored version; position entries, one choice each, 32 anchors live), one
-- tick of the old loop cost 16 100 VM instructions with 60 entries / 45 in
-- range, 4 700 at 20 / 12 and 48 200 at the 256 / 120 cap. The tick is now
-- cut into resumes along the phase boundaries below, the walks that grow
-- with the entry or candidate count are chunked (`GATHER_CHUNK`,
-- `SELECT_CHUNK`, `RESOLVE_CHUNK`), and the sort runs in C on packed
-- integers (`rankOf`).
--
-- Every phase runs under `pcall`. A budget error skips the phase -- nothing
-- here is cumulative, the next cycle redoes it -- and is logged at most once
-- per PHASE_COMPLAINT_SECONDS. The yield straight after a caught error is
-- not optional: the hook only resets its count and deadline on the next
-- resume, so anything done before yielding runs on the exhausted budget and
-- dies again, outside the pcall this time. The watchdog in the start handler
-- covers the few instructions between `pcall` returning and `Wait` yielding.
--
-- Cadence. `Wait(0)` resumes on the next host tick, which in-world is the
-- next engine frame. A cycle that rebuilt its set is at least three resumes
-- -- targets+gather, anchors, select+input -- one frame more per extra
-- chunk; a cycle that reused it is ONE resume, and if it also has no active
-- prompt and no held key it waits IDLE_FRAME_MS instead of FRAME_MS. The
-- extra frames add no visual lag -- the card follows the native anchor,
-- projected per frame by the plugin -- and cost only the key-sampling
-- interval, which stays well under a human tap whenever a tap could fire.
-- ---------------------------------------------------------------------------

local PHASE_COMPLAINT_SECONDS = 10.0
local nextPhaseComplaint = 0
local heartbeat = 0
local tickGeneration = 0
local tickRestarts = 0
local nextStatsReport = 0

local function runPhase(name, fn, ...)
    local started = Open77.time.monotonic()
    local yieldedBefore = yieldedSeconds
    local ok, first, second = pcall(fn, ...)
    phaseSample(name, Open77.time.monotonic() - started - (yieldedSeconds - yieldedBefore))
    if ok then return true, first, second end
    -- Nothing before this yield; see the budget note above.
    Wait(0)
    local now = Open77.time.monotonic()
    if now >= nextPhaseComplaint then
        nextPhaseComplaint = now + PHASE_COMPLAINT_SECONDS
        local failure = tostring(first)
        if failure:find("execution budget exceeded", 1, true) then
            print("[open77_interactions] tick phase " .. name ..
                " exceeded the script budget; skipped")
        else
            print("[open77_interactions] tick phase " .. name .. " failed; skipped: " .. failure)
        end
    end
    return false
end

-- What exists this cycle. Returns the body state (nil without a body) and
-- whether a target pass ran.
-- Where the player stands, as a vector, or nil without an attached body.
-- `character.position` answers with three numbers; `character.state` builds
-- a forty-field snapshot with four nested tables for the same three numbers,
-- and this runs every cycle. The snapshot remains the path for a runtime
-- without `position`.
local function localBodyPosition()
    countNative("state")
    if type(Open77.character.position) == "function" then
        local x, y, z = Open77.character.position()
        if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then return nil end
        return { x = x, y = y, z = z }
    end
    local state = Open77.character.state()
    if not (state and state.attached) then return nil end
    return state.position
end

local function phaseTargets()
    sweepStoppedOwners()
    local position = localBodyPosition()
    if not position then
        -- No body, nothing to anchor to: hand the slots back rather than
        -- leave the plugin projecting points nobody can see.
        if next(anchors) ~= nil then releaseAnchors() end
        lastGather = nil
        return nil, false
    end
    -- Rules first: a match materialised this pass takes part in the very same
    -- arbitration as a hand-written interaction, with no separate path and no
    -- second cycle of latency.
    return { position = position }, resolveTargets(position)
end

-- The ranked eligible set, and whether it was rebuilt this cycle. The anchor
-- frame is read either way: it is what the select phase projects from, and
-- it is also what tells whether an entity entry moved.
local function phaseGather(state)
    readAnchorFrame()
    if gatherStillValid(state.position) then
        stats.gathersSkipped = stats.gathersSkipped + 1
        return lastGather.eligible, false
    end
    return gatherEligible(state.position, Open77.time.monotonic()), true
end

-- Last cycle's winner, reused while the frame, the eligible set and the
-- entries are all unchanged. Only valid with the native card: the page
-- fallback projects in Lua, outside the frame comparison.
local lastCandidate = nil

local function phaseSelect(eligible, gathered)
    local candidate
    if not gathered and not frameChanged and cardSupport == true and lastCandidate and
        entries[lastCandidate.entry.handle] == lastCandidate.entry then
        candidate = lastCandidate
        stats.selectsSkipped = (stats.selectsSkipped or 0) + 1
    else
        candidate = selectCandidate(eligible)
    end
    recheckWinner(candidate)
    lastCandidate = candidate
    return candidate
end

local function phaseInput(candidate)
    -- The winner was chosen a frame or two ago. An entry removed or replaced
    -- since -- another resource's export call runs between resumes -- must
    -- not fire from its ghost.
    if candidate and entries[candidate.entry.handle] ~= candidate.entry then candidate = nil end
    local progress = evaluateInput(candidate)
    pushNativeCard(candidate, progress)
    push(candidate, progress)
end

-- One line per STATS_REPORT_SECONDS, only while there is something to
-- arbitrate, so a bare client stays silent. `work` is the sum of every phase
-- this file ran, on the host's own clock, so it is directly comparable to
-- the per-resource line the host prints (`server/open77_interactions=<us>`
-- per frame): this line says which phase the host's number went to.
local function statsSnapshot(now)
    local elapsed = math.max(now - stats.since, 1e-6)
    local work = 0.0
    local phases = {}
    for name, phase in pairs(stats.phases) do
        phases[name] = { count = phase.count, totalUs = phase.totalUs, maxUs = phase.maxUs,
            avgUs = phase.count > 0 and phase.totalUs / phase.count or 0.0 }
        if name == "targets" or name == "gather" or name == "anchors" or name == "select" or
            name == "input" then work = work + phase.totalUs end
    end
    local entryCount, targetCount, anchorCount = 0, 0, 0
    for _ in pairs(entries) do entryCount = entryCount + 1 end
    for _ in pairs(targets) do targetCount = targetCount + 1 end
    for _ in pairs(anchors) do anchorCount = anchorCount + 1 end
    return {
        seconds = elapsed,
        workMsPerSecond = work / 1000.0 / elapsed,
        cycles = stats.cycles,
        gathersSkipped = stats.gathersSkipped,
        selectsSkipped = stats.selectsSkipped or 0,
        resolves = stats.resolves,
        phases = phases,
        natives = stats.natives,
        entries = entryCount,
        targets = targetCount,
        anchors = anchorCount,
        eligible = lastGather and #lastGather.eligible or 0,
    }
end

local function formatPhase(phases, name)
    local phase = phases[name]
    if not phase or phase.count == 0 then return name .. " -" end
    return string.format("%s %.0f/%.0f", name, phase.avgUs, phase.maxUs)
end

local function reportStats(now)
    if now < nextStatsReport then return end
    nextStatsReport = now + STATS_REPORT_SECONDS
    local snapshot = statsSnapshot(now)
    resetStats(now)
    if snapshot.entries == 0 and snapshot.targets == 0 then return end
    local phases = snapshot.phases
    -- The scan's sources, only those that ran: which native a slow pass is.
    local sources = {}
    for _, name in ipairs({ "scan.world", "scan.puppets", "scan.npcs", "scan.vehicles", "scan.players" }) do
        if phases[name] and phases[name].count > 0 then
            sources[#sources + 1] = formatPhase(phases, name):gsub("^scan%.", "")
        end
    end
    print(string.format(
        "[open77_interactions] cost %.0fs: work=%.2f ms/s cycles=%d (gather reused %d, select reused %d) resolves=%d" ..
        " | avg/max us: %s %s (%s [%s] %s) %s %s %s %s" ..
        " | entries=%d eligible=%d anchors=%d targets=%d" ..
        " | natives: state=%d query=%d lists=%d project=%d anchorUpdates=%d",
        snapshot.seconds, snapshot.workMsPerSecond, snapshot.cycles, snapshot.gathersSkipped,
        snapshot.selectsSkipped, snapshot.resolves,
        formatPhase(phases, "targets"), formatPhase(phases, "resolve"),
        formatPhase(phases, "scan"), table.concat(sources, " "), formatPhase(phases, "predicates"),
        formatPhase(phases, "gather"), formatPhase(phases, "anchors"),
        formatPhase(phases, "select"), formatPhase(phases, "input"),
        snapshot.entries, snapshot.eligible, snapshot.anchors, snapshot.targets,
        snapshot.natives.state or 0, snapshot.natives.query or 0, snapshot.natives.lists or 0,
        snapshot.natives.project or 0, snapshot.natives.anchorUpdates or 0))
end

-- The per-phase cost since the last report (or since `reset`), for tests and
-- the debug bridge. Not owner-scoped: it describes this service, not a caller.
exports("stats", function(reset)
    local now = Open77.time.monotonic()
    local snapshot = statsSnapshot(now)
    if reset == true then resetStats(now) end
    return snapshot
end)

local function startTick()
    tickGeneration = tickGeneration + 1
    local mine = tickGeneration
    CreateThread(function()
        while page and mine == tickGeneration do
            local startedAt = Open77.time.monotonic()
            local yieldedAtStart = yieldedSeconds
            local ok, state, resolved = runPhase("targets", phaseTargets)
            if resolved then
                phaseSample("resolve",
                    Open77.time.monotonic() - startedAt - (yieldedSeconds - yieldedAtStart))
            end
            local candidate
            local gathered = false
            if ok and state then
                if resolved then Wait(0) end
                local eligible
                ok, eligible, gathered = runPhase("gather", phaseGather, state)
                if ok then
                    -- A cycle that rebuilt its set has spent a chunk's worth
                    -- of instructions on this resume already; the anchors and
                    -- the select each get their own. A cycle that reused it
                    -- has read one frame, and runs the select and the input
                    -- on the same resume -- three phases, well under one hook
                    -- interval, and one host resume instead of three.
                    if gathered or anchorsDirty then
                        Wait(0)
                        runPhase("anchors", syncAnchors, eligible)
                    end
                    if gathered or #eligible > SELECT_CHUNK then Wait(0) end
                    ok, candidate = runPhase("select", phaseSelect, eligible, gathered)
                    if not ok then candidate = nil end
                end
            end
            runPhase("input", phaseInput, candidate)
            heartbeat = heartbeat + 1
            stats.cycles = stats.cycles + 1
            local now = Open77.time.monotonic()
            reportStats(now)
            -- Whatever the frames above cost, the next cycle starts FRAME_MS
            -- after this one did, or on the very next tick if they cost more.
            -- A cycle in which nothing could have changed -- the eligible set
            -- was reused, no prompt is active, no key is held -- waits the
            -- idle interval instead.
            local idle = not gathered and hold.token == nil and
                not (candidate and candidate.active)
            local frame = idle and IDLE_FRAME_MS or FRAME_MS
            local elapsed = (now - startedAt) * 1000
            Wait(math.max(0, math.floor(frame - elapsed)))
        end
    end)
end

AddEventHandler("onClientResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    -- Ask for the standing server declarations. This covers the reload of this
    -- resource as well as a late join: the server also pushes on
    -- `onPlayerConnected`, and applying a declaration twice is idempotent
    -- because it retracts that owner's previous set first.
    TriggerServerEvent("open77:interactions:sync")
    local reason
    page, reason = WebUI.create({
        entry = "web/index.html", layer = "hud", width = 1920, height = 1080,
        fps = 60, zIndex = 660, transparent = true, visible = true,
    })
    if not page then
        print("[open77_interactions] WebUI failed: " .. tostring(reason))
        return
    end
    page:on("interactions:ready", function() ready = true end)
    anchorsAvailable = type(Open77.anchors) == "table"
    if not anchorsAvailable then
        print("[open77_interactions] native anchors unavailable; " ..
            "falling back to Lua-tick projection")
    end
    local now = Open77.time.monotonic()
    resetStats(now)
    nextStatsReport = now + STATS_REPORT_SECONDS
    -- Two rates, on purpose. What the marker is *worth* -- which entry wins, what
    -- the card says, whether a key is held far enough -- is content and settles
    -- perfectly well on this tick. Where the marker *is* on screen cannot: the
    -- scheduler samples at ~14 ms against an engine drawing at 60+ fps, so a
    -- Lua-published coordinate is always a frame or more behind the camera and
    -- the prompt visibly swims. That half now lives in the plugin, which projects
    -- every registered anchor on the game thread and pushes it straight to the
    -- page. See docs/writing-a-gamemode.md §3.4.
    startTick()

    -- THE WATCHDOG OUTLIVES THE TICK, deliberately. `ResumeTask` retires a
    -- coroutine that raises, and the instruction hook can fire in the handful
    -- of VM instructions between `pcall` returning and `Wait` yielding --
    -- outside anything `runPhase` can catch. That is a tiny window per error
    -- and the failure it produces is total and silent: every prompt on the
    -- server dead, cards still drawn. One integer compare every five seconds
    -- buys it back. Same defence as open77_cordon_hud/client/wall.lua.
    CreateThread(function()
        local seen = -1
        while page do
            Wait(5000)
            if not page then return end
            if heartbeat == seen then
                tickRestarts = tickRestarts + 1
                if tickRestarts <= 3 then
                    print(("[open77_interactions] the arbitration tick stopped (restart %d); " ..
                        "the host retires a coroutine that raises"):format(tickRestarts))
                end
                startTick()
            end
            seen = heartbeat
        end
    end)
end)

AddEventHandler("onClientResourceStop", function(name)
    if name == GetCurrentResourceName() then
        -- Release the anchors before dropping the page. Generation teardown would
        -- do it anyway, but leaving native anchors pointed at a surface that is
        -- about to be destroyed is exactly the dangling reference worth not
        -- writing.
        releaseAnchors()
        cardSupport, nativeCardHandle, pageHidden = nil, nil, false
        page, ready, entries, identities = nil, false, {}, {}
        ownerGenerations, ownerEnabled, nextOwnerSweep = {}, {}, 0
        targets, targetIdentities, nextTargetResolve = {}, {}, 0
        groupCache, npcFallbackCursor, lastResolvePosition = { at = -math.huge, set = {} }, 0, nil
        lastGather, lastCandidate, anchorsDirty = nil, nil, false
        activeHandle = nil
        touchEntries()
        resetHold()
    else
        removeOwner(name)
    end
end)
