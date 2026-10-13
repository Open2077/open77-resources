-- open77_uikit -- the shared dialog and HUD-widget kit.
--
-- ===========================================================================
-- Focus discipline
-- ===========================================================================
--
-- Taking keyboard and cursor focus stops game input wholesale. A player left
-- with a dead dialog and no input cannot move, cannot shoot, and cannot type to
-- say so. So the rule in this file is not "release focus when the dialog
-- closes"; it is:
--
--   * focus is a LEDGER, not a flag. `focusHolders` is the set of open widgets
--     that asked for it. `syncFocus()` is the ONLY place `page:setFocus` is
--     called, and it derives the real state from whether that set is empty.
--     There is no path that sets focus without adding to the ledger and no
--     path that clears the ledger without calling `syncFocus`.
--   * every exit funnels through ONE function, `settle()`. Confirm, cancel,
--     Escape, timeout, owner stop, owner reload, our own stop, death and
--     disconnect are nine doors into the same room.
--   * a watchdog runs every tick and releases focus when the ledger is empty
--     but focus is still held. If a future edit adds a tenth door and forgets
--     to close it, the player is free again within one frame instead of
--     permanently stranded.
--
-- The tenth path is the platform's: page handles belong to the resource
-- generation and the host destroys the surface on stop or reload, which drops
-- focus even if this VM never runs another line.
--
-- Control blocking is DELIBERATELY NOT focus. A progress bar that stops the
-- player moving claims `Movement` through `Open77.input.setActionBlocked`,
-- which leaves chat and voice working -- see wiki/input-blocking.md, "a player
-- who cannot act must still be able to say so". Holding focus to achieve the
-- same thing would take the keyboard away from chat as well.
--
-- ===========================================================================
-- Message routing -- one page, eight widgets
-- ===========================================================================
--
-- The per-resource surface budget is 8. One page serves every widget, and two
-- channels carry everything:
--
--   Lua -> page   "uikit:apply"  { widget, action, token, spec }
--   page -> Lua   "uikit:event"  { widget, token, type, payload }
--
-- `widget` selects the component ("progress", "text", "dialog"); `action` and
-- `type` are that component's verbs. `token` is a monotonic integer stamped on
-- every open. The page echoes it back on every event and `settle()` refuses a
-- token that is not the live one, so a click that raced a close cannot resolve
-- the dialog that replaced it. That stale-token check is the same discipline
-- the Cordon tac-map uses and it is covered by the test suite.
--
-- Ownership comes from `GetInvokingResource()`, never from an argument.
-- ===========================================================================

local RESOURCE = GetCurrentResourceName()

local MAX_TEXT_SLOTS = 4
local MAX_MENUS_PER_OWNER = 32
local MAX_OPTIONS = 64
local MAX_FIELDS = 24
local MAX_RADIAL_ITEMS = 8
local MIN_TIMEOUT_MS = 1000
local MAX_TIMEOUT_MS = 120000        -- the callback transport's own ceiling
local DEFAULT_TIMEOUT_MS = 60000
local MIN_PROGRESS_MS = 100
local MAX_PROGRESS_MS = 600000
local POLL_MS = 16
local SWEEP_SECONDS = 1

-- 3D text rides `Open77.anchors`, and the anchors this kit creates are owned by
-- THIS resource as far as the host is concerned: the per-resource quota is 32
-- (`WorldAnchors.cpp`, `kPerOwnerLimit`) and it is shared by every caller of
-- `drawText3D`. So the kit budgets it itself -- eight per owner, twenty-four in
-- all -- and refuses by name before the host ever answers `quota_exceeded`,
-- which would otherwise read as a fault in a caller that did nothing wrong.
-- The remaining eight of the 32 are headroom, not a reserve for anything.
local MAX_TEXT3D_PER_OWNER = 8
local MAX_TEXT3D_TOTAL = 24
local MAX_TEXT3D_BYTES = 96
local MIN_TEXT3D_TTL_MS = 100
local MAX_TEXT3D_TTL_MS = 600000
local DEFAULT_TEXT3D_DISTANCE = 50.0
local MIN_TEXT3D_DISTANCE = 1.0
local MAX_TEXT3D_DISTANCE = 1000.0    -- the anchor's own ceiling

-- Letterbox bars. Height is per bar, as a percentage of the viewport; the ease
-- is the slide in and out. 40 % per bar leaves a fifth of the screen -- past
-- that the "cinematic" is a black screen with a slot in it, which is a fade
-- and `Open77.screen` already does fades.
local CINEMATIC_DEFAULT_HEIGHT_PCT = 12
local CINEMATIC_MAX_HEIGHT_PCT = 40
local CINEMATIC_DEFAULT_EASE_MS = 350
local CINEMATIC_MAX_EASE_MS = 5000

-- `Movement` and the combat pair are the ones that matter for a progress bar;
-- the rest are there so a dialog can also take the map and the RPG hub away.
-- `combat` is firing AND melee: since 2026-10-12 `Attack` names firing only and
-- `Melee` is its own lever, and a bar that stops shooting but lets the player
-- punch would read as a bug. Every name is from `Open77.input.blockableActions()`;
-- an unblockable one is refused by the platform with `action_not_blockable`
-- rather than silently ignored (an older client answers that for `Melee`).
local DISABLE_ACTIONS = {
    move = { "Movement" },
    combat = { "Attack", "Melee" },
    map = { "Map" },
    hub = { "Hub" },
    fastTravel = { "FastTravel" },
}

local POSITIONS = { top = true, center = true, bottom = true }
local FIELD_TYPES = {
    text = true, number = true, password = true, textarea = true,
    checkbox = true, slider = true, select = true,
}

local running = true
local page, pageReady, pageVisible = nil, false, false
local nextToken = 1
local focusHeld = false

-- token -> live widget record. `settle()` moves a record to `settled`, the
-- awaiting export task reads it there and clears it.
local live = {}
local settled = {}

-- token set of widgets that asked for keyboard+cursor. Never written except
-- through `claimFocus` / `releaseFocus`.
local focusHolders = {}

-- Refcount per vocabulary action. Blocking is a loan and Open77 releases only
-- the CALLING resource's claim, so two bars that both blocked `Movement` would
-- otherwise free the player when the first finished.
local blockCounts = {}
local blockAllCount = 0

local ownerGenerations = {}
local menus = {}                      -- owner -> id -> definition
local textSlots = {}                  -- owner -> slot
local textOrder = {}
local progressToken = nil
local dialogToken = nil               -- the one focus-taking dialog, if any
local nextSweep = 0
local cancelKeyWasDown = false

-- handle -> { handle, owner, anchor, spec, deadline }. `spec` is the whole
-- presentation, kept because an anchor's presentation is patched WHOLE: an
-- update that only changed the text still has to resend the colour.
local texts3d = {}
local text3dCounts = {}               -- owner -> live count
local text3dTotal = 0
local nextText3d = 1

-- owner -> the look that owner asked for. Bars are a CLAIM per owner, like a
-- HUD hide: they show while any claim stands and go when the last is released,
-- so two resources composing a scene cannot pull the bars out from under each
-- other. The most recent claim decides the look.
local cinematicClaims = {}
local cinematicOrder = {}
local cinematicShown = false
local cinematicHudHeld = false
local cinematicHideAt = nil           -- when the slide-out has played
local cinematicEase = CINEMATIC_DEFAULT_EASE_MS

-- ---------------------------------------------------------------------------
-- Validation. Same shapes as open77_notifications so a caller that already
-- talks to one shared service does not have to learn a second vocabulary.
-- ---------------------------------------------------------------------------

local function finite(value)
    return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function validName(value, maximum)
    return type(value) == "string" and #value > 0 and #value <= maximum and
        value:match("^[%w_:%-%.]+$") ~= nil
end

local function validText(value, maximum, allowEmpty)
    return type(value) == "string" and #value <= maximum and
        (allowEmpty or #value > 0) and not value:find("[%c]")
end

local function normalizeColor(value, fallback)
    if value == nil then return fallback end
    if type(value) ~= "string" or not value:match(
        "^#[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]$") then
        return nil
    end
    return value:upper()
end

-- The native overlay takes `#RRGGBB` or `#RRGGBBAA`; `"none"` is accepted for
-- a background so a caller can ask for bare text without knowing the alpha
-- spelling. Refused, never coerced, for the same reason as `normalizeColor`.
local function normalizeColorAlpha(value, fallback)
    if value == nil then return fallback end
    if value == "none" then return "#00000000" end
    if type(value) ~= "string" then return nil end
    if value:match("^#%x%x%x%x%x%x$") or value:match("^#%x%x%x%x%x%x%x%x$") then
        return value:upper()
    end
    return nil
end

local function integerIn(value, fallback, low, high)
    if value == nil then return fallback end
    if not finite(value) or value % 1 ~= 0 or value < low or value > high then return nil end
    return value
end

local function timeoutOf(definition)
    local value = definition.timeoutMs
    if value == nil then value = definition.timeout end
    return integerIn(value, DEFAULT_TIMEOUT_MS, MIN_TIMEOUT_MS, MAX_TIMEOUT_MS)
end

local function now()
    return Open77.time.monotonic()
end

local function warn(message)
    if Open77 and Open77.log and Open77.log.warn then Open77.log.warn("uikit: " .. message) end
end

-- ---------------------------------------------------------------------------
-- Ownership
-- ---------------------------------------------------------------------------

-- Forward declaration: `invokingOwner` has to be able to evict a reloaded
-- owner, and `closeOwner` needs the ledger primitives declared further down.
local closeOwner

-- MUST be called before the first yield of an export: the invocation context is
-- cleared across yields, so `GetInvokingResource()` after a `Wait` is nil.
local function invokingOwner()
    local owner = GetInvokingResource()
    local generation = GetInvokingResourceGeneration()
    if not validName(owner, 64) or type(generation) ~= "number" then
        return nil, "export_call_required"
    end
    if ownerGenerations[owner] ~= nil and ownerGenerations[owner] ~= generation then
        -- 5b. The owner reloaded between two calls. Everything it held belongs
        -- to a generation that no longer exists, and the new generation must
        -- not inherit a dialog it never opened.
        closeOwner(owner, "cancelled")
    end
    ownerGenerations[owner] = generation
    return owner
end

-- ---------------------------------------------------------------------------
-- The page
-- ---------------------------------------------------------------------------

local function send(payload)
    if page and pageReady then page:send("uikit:apply", payload) end
end

-- A page that shows nothing is hidden, not transparent: CSS opacity does not
-- suspend CEF or stop native composition, so an always-visible full-screen
-- surface costs a composite every frame for nothing.
local function syncVisible()
    if not page then return end
    local wanted = progressToken ~= nil or dialogToken ~= nil or next(textSlots) ~= nil or
        cinematicShown
    if wanted == pageVisible then return end
    pageVisible = wanted
    if wanted then page:show() else page:hide() end
end

-- THE ONLY PLACE `setFocus` IS CALLED.
--
-- `setFocus` returns whether it CHANGED anything, so `false` from a release is
-- "already released", not a failure. Treating it as a failure here would make
-- the release path log noise on every second call.
local function syncFocus()
    if not page then focusHeld = false return end
    local wanted = next(focusHolders) ~= nil
    if wanted == focusHeld then return end
    if wanted then
        local ok, reason = page:setFocus(true, true)
        -- An unready page still TAKES the mouse even though `send` is dropped,
        -- so refusing to claim before ready is a correctness rule, not polish.
        focusHeld = true
        if ok == false and reason ~= nil then warn("focus refused (" .. tostring(reason) .. ")") end
    else
        page:setFocus(false, false)
        focusHeld = false
    end
end

local function claimFocus(token)
    focusHolders[token] = true
    syncFocus()
end

local function releaseFocus(token)
    focusHolders[token] = nil
    syncFocus()
end

-- ---------------------------------------------------------------------------
-- Control blocking, refcounted
-- ---------------------------------------------------------------------------

local function applyBlocks(spec, delta)
    if spec == nil then return end
    if spec.all then
        blockAllCount = blockAllCount + delta
        if blockAllCount == delta and delta > 0 then
            local ok, reason = Open77.input.blockAll({ except = spec.except })
            if not ok then
                blockAllCount = blockAllCount - delta
                warn("blockAll refused (" .. tostring(reason) .. ")")
            end
        elseif blockAllCount <= 0 then
            blockAllCount = 0
            Open77.input.blockAll(false)
        end
        return
    end
    for key, actions in pairs(DISABLE_ACTIONS) do
        if spec[key] then
            for _, action in ipairs(actions) do
                local count = (blockCounts[action] or 0) + delta
                if count < 0 then count = 0 end
                if count > 0 and (blockCounts[action] or 0) == 0 then
                    local ok, reason = Open77.input.setActionBlocked(action, true)
                    if not ok then
                        -- `Attack` and `Melee` are `inferred` on 2.31 and
                        -- `action_already_enforced` is a normal answer for
                        -- something Open77 blocks anyway. Neither is fatal; the
                        -- caller is told through `state()`.
                        count = 0
                        warn("block " .. action .. " refused (" .. tostring(reason) .. ")")
                    end
                elseif count == 0 and (blockCounts[action] or 0) > 0 then
                    Open77.input.setActionBlocked(action, false)
                end
                blockCounts[action] = count
            end
        end
    end
end

-- The invariant, asserted every tick: no widget wants a block, so nothing may
-- still be blocked. This is what makes a missed release path survivable.
local function auditBlocks()
    if next(live) ~= nil then return end
    if blockAllCount ~= 0 then
        blockAllCount = 0
        Open77.input.blockAll(false)
    end
    for action, count in pairs(blockCounts) do
        if count ~= 0 then
            blockCounts[action] = 0
            Open77.input.setActionBlocked(action, false)
        end
    end
end

local function readDisable(value)
    if value == nil then return nil end
    if value == "all" or value == true then return { all = true } end
    if type(value) ~= "table" then return nil, "invalid_disable" end
    local spec = {}
    for key in pairs(DISABLE_ACTIONS) do
        if value[key] ~= nil then
            if type(value[key]) ~= "boolean" then return nil, "invalid_disable" end
            spec[key] = value[key]
        end
    end
    if value.all == true then
        spec = { all = true }
        if value.except ~= nil then
            if type(value.except) ~= "table" then return nil, "invalid_disable" end
            local except = {}
            for index = 1, #value.except do
                if not validName(value.except[index], 32) then return nil, "invalid_disable" end
                except[index] = value.except[index]
            end
            spec.except = except
        end
    elseif next(spec) == nil then
        return nil
    end
    return spec
end

-- ---------------------------------------------------------------------------
-- The widget ledger
--
-- `open(...)` mints a token, `settle(...)` is the single exit, `await(...)` is
-- what a yielding export parks on.
-- ---------------------------------------------------------------------------

local function open(owner, widget, wantsFocus, options)
    local token = nextToken
    nextToken = nextToken + 1
    local record = {
        token = token,
        owner = owner,
        generation = ownerGenerations[owner],
        widget = widget,
        focus = wantsFocus == true,
        disable = options and options.disable or nil,
        deadline = options and options.deadline or nil,
        useWhileDead = options and options.useWhileDead == true,
        trail = {},
        values = options and options.values or nil,
    }
    live[token] = record
    if record.disable then applyBlocks(record.disable, 1) end
    if record.focus then claimFocus(token) end
    return record
end

-- outcome: "ok" | "cancelled" | "timeout"
-- A cancel is a NORMAL outcome and never a rejection: `{ ok = false,
-- outcome = "cancelled" }` is the resolved value, so a caller does not need a
-- pcall around ordinary user behaviour.
local function settle(token, outcome, value, extra)
    local record = live[token]
    if record == nil then return false end
    live[token] = nil
    if record.focus then releaseFocus(token) end
    if record.disable then applyBlocks(record.disable, -1) end
    if progressToken == token then progressToken = nil end
    if dialogToken == token then dialogToken = nil end
    send({ widget = record.widget, action = "close", token = token })
    syncVisible()
    local result = { ok = outcome == "ok", outcome = outcome, value = value }
    if type(extra) == "table" then
        for key, item in pairs(extra) do result[key] = item end
    end
    result.settledAt = now()
    settled[token] = result
    TriggerEvent("open77:uikit:closed", {
        owner = record.owner, widget = record.widget, outcome = outcome,
    })
    return true
end

-- Parks the export task until `settle` produces an answer. This is why the kit
-- is called through `Open77.exports.call` and not through the synchronous
-- `exports.open77_uikit:alert(...)` form: a synchronous callee has no scheduler
-- to yield to and fails with `export_yielded`.
local function await(token)
    while true do
        local answer = settled[token]
        if answer ~= nil then
            settled[token] = nil
            return answer
        end
        if not running then return { ok = false, outcome = "cancelled", reason = "resource_stopped" } end
        if live[token] == nil then
            -- Settled and collected by somebody else, or lost. Never spin.
            return { ok = false, outcome = "cancelled", reason = "dialog_lost" }
        end
        Wait(POLL_MS)
    end
end

-- Every bulk exit path in the focus matrix funnels here.
local function settleWhere(predicate, outcome)
    local victims = {}
    for token, record in pairs(live) do
        if predicate(record) then victims[#victims + 1] = token end
    end
    table.sort(victims)
    for _, token in ipairs(victims) do settle(token, outcome) end
    return #victims
end

local pushText
local clearText3dOwner
local releaseCinematic

closeOwner = function(owner, outcome)
    local count = settleWhere(function(record) return record.owner == owner end, outcome or "cancelled")
    if textSlots[owner] then
        textSlots[owner] = nil
        for index = #textOrder, 1, -1 do
            if textOrder[index] == owner then table.remove(textOrder, index) end
        end
        pushText()
    end
    menus[owner] = nil
    count = count + clearText3dOwner(owner)
    if releaseCinematic(owner) then count = count + 1 end
    return count
end

-- ---------------------------------------------------------------------------
-- progress
-- ---------------------------------------------------------------------------

local function normalizeProgress(definition)
    if type(definition) ~= "table" then return nil, "definition_must_be_a_table" end
    local label = definition.label or definition.text or ""
    if not validText(label, 120, true) then return nil, "invalid_label" end
    local duration = integerIn(definition.duration or definition.durationMs, nil,
        MIN_PROGRESS_MS, MAX_PROGRESS_MS)
    if duration == nil then return nil, "invalid_duration" end
    local position = definition.position or "bottom"
    if not POSITIONS[position] then return nil, "invalid_position" end
    local style = definition.style or "bar"
    if style ~= "bar" and style ~= "circle" then return nil, "invalid_style" end
    local color = normalizeColor(definition.color, "#22D8E2")
    if color == nil then return nil, "invalid_color" end
    local cancelKey = definition.cancelKey or "X"
    if not validName(cancelKey, 8) then return nil, "invalid_cancel_key" end
    local disable, disableReason = readDisable(definition.disable)
    if disableReason then return nil, disableReason end
    return {
        label = label, duration = duration, position = position, style = style,
        color = color, cancellable = definition.cancellable ~= false,
        cancelKey = cancelKey:upper(), disable = disable,
        useWhileDead = definition.useWhileDead == true,
    }
end

-- ---------------------------------------------------------------------------
-- textUI
-- ---------------------------------------------------------------------------

local function normalizeText(definition)
    if type(definition) == "string" then definition = { text = definition } end
    if type(definition) ~= "table" then return nil, "definition_must_be_a_table" end
    local text = definition.text or definition.label
    if not validText(text, 240, false) then return nil, "invalid_text" end
    local position = definition.position or "bottom"
    if not POSITIONS[position] then return nil, "invalid_position" end
    local color = normalizeColor(definition.color, "#22D8E2")
    if color == nil then return nil, "invalid_color" end
    if definition.key ~= nil and not validText(definition.key, 8, true) then return nil, "invalid_key" end
    if definition.icon ~= nil and not validText(definition.icon, 16, true) then return nil, "invalid_icon" end
    -- Refused rather than silently dropped, for the same reason as `color`: a
    -- field that quietly disappears is how a surface ends up missing a label
    -- nobody notices until a player asks what the hint was supposed to say.
    if definition.eyebrow ~= nil and not validText(definition.eyebrow, 24, true) then
        return nil, "invalid_eyebrow"
    end
    -- Up to three key + label pairs under the text ("Y Accept  N Decline"). They only draw the keys:
    -- the owner binds them (Open77.input.registerKeyMapping), as it does for `key`.
    local actions
    if definition.actions ~= nil then
        if type(definition.actions) ~= "table" or #definition.actions < 1 or #definition.actions > 3 then
            return nil, "invalid_actions"
        end
        actions = {}
        for index, action in ipairs(definition.actions) do
            if type(action) ~= "table" or not validText(action.key, 8, false) or not validText(action.label, 24, false) then
                return nil, "invalid_actions"
            end
            actions[index] = { key = action.key, label = action.label }
        end
    end
    return {
        text = text, position = position, color = color,
        key = definition.key or "", icon = definition.icon or "",
        eyebrow = definition.eyebrow, actions = actions,
    }
end

pushText = function()
    local slots = {}
    for index = 1, #textOrder do
        local slot = textSlots[textOrder[index]]
        if slot then slots[#slots + 1] = slot end
    end
    send({ widget = "text", action = "set", spec = { slots = slots } })
    syncVisible()
end

-- ---------------------------------------------------------------------------
-- drawText3D / updateText3D / clearText3D
--
-- FiveM's `DrawText3D` is a per-frame call: a resource projects a world point
-- itself, every tick, and draws a string at the result. Here the projection is
-- the host's -- `Open77.anchors` samples the point on the game thread each
-- frame, with the distance band, the occlusion test and the camera-plane cull
-- the interaction prompts already pay for -- so the loop becomes ONE handle:
-- create it, change its text when the text changes, clear it when done.
--
-- A native `card` with a label and no keycap is what a floating string looks
-- like, so that is what this is. No page, no CEF hop: the card is drawn in the
-- frame that presents it (`WorldOverlay`), which is why it does not trail the
-- world the way a web-page billboard does.
-- ---------------------------------------------------------------------------

local function readPoint(value)
    if type(value) ~= "table" then return nil end
    local x, y, z = value.x, value.y, value.z
    if x == nil and value[1] ~= nil then x, y, z = value[1], value[2], value[3] end
    if not finite(x) or not finite(y) or not finite(z) then return nil end
    return { x = x, y = y, z = z }
end

-- The look the anchor is given. Kept whole on the record because the anchor's
-- `presentation` is patched whole, so every update resends all of it.
local function presentationOf(spec)
    return {
        label = spec.text, sublabel = spec.sublabel,
        color = spec.color, accent = spec.accent, background = spec.background,
        scale = spec.scale, showDistance = spec.showDistance,
    }
end

local function normalizeText3D(definition)
    if type(definition) ~= "table" then return nil, "definition_must_be_a_table" end
    local text = definition.text or definition.label
    if not validText(text, MAX_TEXT3D_BYTES, false) then return nil, "invalid_text" end
    if definition.sublabel ~= nil and not validText(definition.sublabel, MAX_TEXT3D_BYTES, true) then
        return nil, "invalid_sublabel"
    end
    local position = definition.position
    local point
    if position ~= nil then
        point = readPoint(position)
        if point == nil then return nil, "invalid_position" end
    end
    local entity = definition.entity
    if entity ~= nil and type(entity) ~= "string" and type(entity) ~= "number" then
        return nil, "invalid_entity"
    end
    -- Exactly one of the two, the same rule the anchor applies and for the
    -- same reason: with both, a caller cannot tell which one the text follows.
    if (point == nil) == (entity == nil) then return nil, "position_or_entity_required" end
    local offset
    if definition.offset ~= nil then
        offset = readPoint(definition.offset)
        if offset == nil then return nil, "invalid_offset" end
    end
    local color = normalizeColorAlpha(definition.color, "#F2F6F8")
    if color == nil then return nil, "invalid_color" end
    -- No accent by default: the accent is the card's border, and a floating
    -- string has none. A caller who wants the prompt look asks for one.
    local accent = normalizeColorAlpha(definition.accent, "#00000000")
    if accent == nil then return nil, "invalid_accent" end
    local background = normalizeColorAlpha(definition.background, "#0A1220B8")
    if background == nil then return nil, "invalid_background" end
    local scale = definition.scale
    if scale == nil then scale = 1.0 end
    if not finite(scale) or scale < 0.25 or scale > 4.0 then return nil, "invalid_scale" end
    local ttl = definition.ttl
    if ttl == nil then ttl = definition.ttlMs end
    ttl = integerIn(ttl, nil, MIN_TEXT3D_TTL_MS, MAX_TEXT3D_TTL_MS)
    if ttl == nil and (definition.ttl ~= nil or definition.ttlMs ~= nil) then
        return nil, "invalid_ttl"
    end
    local maxDistance = definition.maxDistance
    if maxDistance == nil then maxDistance = DEFAULT_TEXT3D_DISTANCE end
    if not finite(maxDistance) or maxDistance < MIN_TEXT3D_DISTANCE or
        maxDistance > MAX_TEXT3D_DISTANCE then
        return nil, "invalid_max_distance"
    end
    if definition.showDistance ~= nil and type(definition.showDistance) ~= "boolean" then
        return nil, "invalid_show_distance"
    end
    return {
        text = text, sublabel = definition.sublabel,
        position = point, entity = entity, offset = offset,
        color = color, accent = accent, background = background, scale = scale,
        ttl = ttl, maxDistance = maxDistance, showDistance = definition.showDistance == true,
    }
end

local function removeText3D(record)
    if texts3d[record.handle] == nil then return false end
    texts3d[record.handle] = nil
    text3dCounts[record.owner] = (text3dCounts[record.owner] or 1) - 1
    if text3dCounts[record.owner] <= 0 then text3dCounts[record.owner] = nil end
    text3dTotal = text3dTotal - 1
    if record.anchor and Open77.anchors and Open77.anchors.remove then
        Open77.anchors.remove(record.anchor)
    end
    return true
end

clearText3dOwner = function(owner)
    local victims = {}
    for _, record in pairs(texts3d) do
        if record.owner == owner then victims[#victims + 1] = record end
    end
    table.sort(victims, function(left, right) return left.handle < right.handle end)
    for _, record in ipairs(victims) do removeText3D(record) end
    return #victims
end

local function createText3D(owner, definition)
    local spec, reason = normalizeText3D(definition)
    if not spec then return nil, reason end
    if Open77.anchors == nil or Open77.anchors.create == nil then
        return nil, "anchors_unavailable"
    end
    if (text3dCounts[owner] or 0) >= MAX_TEXT3D_PER_OWNER then return nil, "text3d_owner_limit" end
    if text3dTotal >= MAX_TEXT3D_TOTAL then return nil, "text3d_limit" end
    local anchor, refusal = Open77.anchors.create({
        render = "card",
        position = spec.position, entity = spec.entity, offset = spec.offset,
        maxDistance = spec.maxDistance,
        tag = "uikit.text3d",
        presentation = presentationOf(spec),
    })
    if anchor == nil then return nil, refusal or "anchor_refused" end
    local record = {
        handle = "text3d:" .. nextText3d, owner = owner, anchor = anchor, spec = spec,
        deadline = spec.ttl and (now() + spec.ttl / 1000) or nil,
    }
    nextText3d = nextText3d + 1
    texts3d[record.handle] = record
    text3dCounts[owner] = (text3dCounts[owner] or 0) + 1
    text3dTotal = text3dTotal + 1
    return record.handle
end

-- Only the fields a moving string changes. Colour and scale are here because a
-- countdown that turns red at ten seconds is the common case; the follow
-- target is not, because switching a text from a point to an entity is
-- indistinguishable from clearing it and drawing another.
local function updateText3D(owner, handle, patch)
    local record = type(handle) == "string" and texts3d[handle] or nil
    if record == nil then return nil, "text3d_not_found" end
    if record.owner ~= owner then return nil, "not_owner" end
    if type(patch) ~= "table" then return nil, "patch_must_be_a_table" end
    local spec = record.spec
    local look = {
        text = spec.text, sublabel = spec.sublabel, color = spec.color, accent = spec.accent,
        background = spec.background, scale = spec.scale, showDistance = spec.showDistance,
    }
    local anchorPatch = {}
    local text = patch.text or patch.label
    if text ~= nil then
        if not validText(text, MAX_TEXT3D_BYTES, false) then return nil, "invalid_text" end
        look.text = text
    end
    if patch.sublabel ~= nil then
        if not validText(patch.sublabel, MAX_TEXT3D_BYTES, true) then return nil, "invalid_sublabel" end
        look.sublabel = patch.sublabel
    end
    if patch.color ~= nil then
        look.color = normalizeColorAlpha(patch.color, nil)
        if look.color == nil then return nil, "invalid_color" end
    end
    if patch.accent ~= nil then
        look.accent = normalizeColorAlpha(patch.accent, nil)
        if look.accent == nil then return nil, "invalid_accent" end
    end
    if patch.background ~= nil then
        look.background = normalizeColorAlpha(patch.background, nil)
        if look.background == nil then return nil, "invalid_background" end
    end
    if patch.scale ~= nil then
        if not finite(patch.scale) or patch.scale < 0.25 or patch.scale > 4.0 then
            return nil, "invalid_scale"
        end
        look.scale = patch.scale
    end
    if patch.showDistance ~= nil then
        if type(patch.showDistance) ~= "boolean" then return nil, "invalid_show_distance" end
        look.showDistance = patch.showDistance
    end
    if patch.position ~= nil then
        if spec.entity ~= nil then return nil, "text3d_follows_entity" end
        local point = readPoint(patch.position)
        if point == nil then return nil, "invalid_position" end
        anchorPatch.position = point
    end
    if patch.offset ~= nil then
        if spec.entity == nil then return nil, "text3d_has_no_entity" end
        local offset = readPoint(patch.offset)
        if offset == nil then return nil, "invalid_offset" end
        anchorPatch.offset = offset
    end
    if patch.maxDistance ~= nil then
        if not finite(patch.maxDistance) or patch.maxDistance < MIN_TEXT3D_DISTANCE or
            patch.maxDistance > MAX_TEXT3D_DISTANCE then
            return nil, "invalid_max_distance"
        end
        anchorPatch.maxDistance = patch.maxDistance
    end
    if patch.visible ~= nil then
        if type(patch.visible) ~= "boolean" then return nil, "invalid_visible" end
        anchorPatch.visible = patch.visible
    end
    anchorPatch.presentation = presentationOf(look)
    if Open77.anchors == nil or Open77.anchors.update == nil then return nil, "anchors_unavailable" end
    local ok, refusal = Open77.anchors.update(record.anchor, anchorPatch)
    if ok == false then return nil, refusal or "anchor_refused" end
    for key, value in pairs(look) do spec[key] = value end
    if anchorPatch.position then spec.position = anchorPatch.position end
    if anchorPatch.offset then spec.offset = anchorPatch.offset end
    if anchorPatch.maxDistance then spec.maxDistance = anchorPatch.maxDistance end
    return true
end

-- The caller's texts with the host's last projection joined in, so a resource
-- (or a probe) can ask "is it on screen, how far" without touching anchors.
local function listText3D(owner)
    local projections = {}
    if Open77.anchors and Open77.anchors.list then
        for _, anchor in ipairs(Open77.anchors.list() or {}) do
            projections[anchor.id] = anchor
        end
    end
    local out = {}
    for _, record in pairs(texts3d) do
        if record.owner == owner then
            local projection = projections[record.anchor]
            out[#out + 1] = {
                handle = record.handle, text = record.spec.text,
                maxDistance = record.spec.maxDistance,
                expiresIn = record.deadline and math.max(0, record.deadline - now()) or nil,
                distance = projection and projection.distance or nil,
                onScreen = projection and projection.onScreen or false,
                projected = projection and projection.projected or false,
                inRange = projection ~= nil and projection.projected and
                    projection.distance <= record.spec.maxDistance or false,
            }
        end
    end
    table.sort(out, function(left, right) return left.handle < right.handle end)
    return out
end

-- Expired texts go on the tick, not on the next call: a `ttl` is a promise that
-- the string disappears on its own, including from a resource that never calls
-- the kit again.
local function sweepText3D(current)
    local expired = {}
    for _, record in pairs(texts3d) do
        if record.deadline and current >= record.deadline then expired[#expired + 1] = record end
    end
    for _, record in ipairs(expired) do removeText3D(record) end
end

-- ---------------------------------------------------------------------------
-- showCinematicBars
--
-- The HUD-off half already ships: `Open77.hud.setVisible("all", false)` is a
-- per-owner loan the host releases when the owner stops. What did not exist
-- was the letterbox, and a letterbox is two black divs on a page this kit
-- already owns. The two are composed here, under ONE claim per caller, so a
-- cutscene resource writes one line and gets both -- and gets both BACK on
-- every path this file already guards: its own release, its stop, its reload,
-- the session ending, the kit stopping.
--
-- The camera is deliberately not part of this. `Open77.camera` handles belong
-- to the resource that created them and a kit that activated a caller's camera
-- would own the one thing it cannot release. Activate the camera, then the
-- bars; deactivate in the other order.
-- ---------------------------------------------------------------------------

local function normalizeCinematic(options)
    if options == nil then options = {} end
    if type(options) ~= "table" then return nil, "options_must_be_a_table" end
    local height = options.heightPct
    if height == nil then height = options.height end
    if height == nil then height = CINEMATIC_DEFAULT_HEIGHT_PCT end
    if not finite(height) or height < 1 or height > CINEMATIC_MAX_HEIGHT_PCT then
        return nil, "invalid_height"
    end
    local ease = options.durationMs
    if ease == nil then ease = options.duration end
    ease = integerIn(ease, CINEMATIC_DEFAULT_EASE_MS, 0, CINEMATIC_MAX_EASE_MS)
    if ease == nil then return nil, "invalid_duration" end
    local color = normalizeColor(options.color, "#000000")
    if color == nil then return nil, "invalid_color" end
    if options.hideHud ~= nil and type(options.hideHud) ~= "boolean" then
        return nil, "invalid_hide_hud"
    end
    return {
        heightPct = height, durationMs = ease, color = color,
        hideHud = options.hideHud ~= false,
    }
end

-- Derives the real state from the claim set, the same way `syncFocus` derives
-- focus from the ledger: nothing in this file shows or hides the bars, or
-- touches the HUD loan, except through here.
local function syncCinematic()
    local owner = cinematicOrder[#cinematicOrder]
    local spec = owner and cinematicClaims[owner] or nil
    local wanted = spec ~= nil
    local hudWanted = false
    for _, claim in pairs(cinematicClaims) do
        if claim.hideHud then hudWanted = true break end
    end
    if hudWanted ~= cinematicHudHeld then
        if Open77.hud and Open77.hud.setVisible then
            local ok, reason = Open77.hud.setVisible("all", not hudWanted)
            if ok then
                cinematicHudHeld = hudWanted
            else
                -- The bars still show: a missing `ui.vanilla.hud` on this host
                -- is a configuration fault worth a log line, not a reason to
                -- refuse the caller a letterbox.
                warn("hud " .. (hudWanted and "hide" or "restore") .. " refused (" .. tostring(reason) .. ")")
                if not hudWanted then cinematicHudHeld = false end
            end
        else
            cinematicHudHeld = false
        end
    end
    if wanted then
        cinematicHideAt = nil
        cinematicEase = spec.durationMs
        send({ widget = "cinematic", action = "show", spec = spec })
        cinematicShown = true
    elseif cinematicShown and cinematicHideAt == nil then
        -- The page stays up for the length of the ease so the slide out is
        -- seen; the tick flips `cinematicShown` once it has played. A hide of
        -- the whole surface here would cut the bars off mid-frame.
        send({ widget = "cinematic", action = "hide" })
        cinematicHideAt = now() + cinematicEase / 1000 + 0.1
    end
    syncVisible()
end

local function claimCinematic(owner, options)
    local spec, reason = normalizeCinematic(options)
    if not spec then return nil, reason end
    if page == nil then return nil, "surface_unavailable" end
    if cinematicClaims[owner] == nil then
        cinematicOrder[#cinematicOrder + 1] = owner
    else
        -- A re-claim moves the owner to the front: the caller who spoke last
        -- decides the look, even if it had already spoken before.
        for index = #cinematicOrder, 1, -1 do
            if cinematicOrder[index] == owner then table.remove(cinematicOrder, index) end
        end
        cinematicOrder[#cinematicOrder + 1] = owner
    end
    cinematicClaims[owner] = spec
    syncCinematic()
    return true
end

releaseCinematic = function(owner)
    if cinematicClaims[owner] == nil then return false end
    cinematicClaims[owner] = nil
    for index = #cinematicOrder, 1, -1 do
        if cinematicOrder[index] == owner then table.remove(cinematicOrder, index) end
    end
    syncCinematic()
    return true
end

local function cinematicState(owner)
    local holders = {}
    for index = 1, #cinematicOrder do holders[index] = cinematicOrder[index] end
    local top = cinematicOrder[#cinematicOrder]
    local spec = top and cinematicClaims[top] or nil
    return {
        active = cinematicShown, hudHidden = cinematicHudHeld,
        mine = owner ~= nil and cinematicClaims[owner] ~= nil,
        holders = holders,
        heightPct = spec and spec.heightPct or nil,
        color = spec and spec.color or nil,
    }
end

-- ---------------------------------------------------------------------------
-- alert / input / context / menu / radial
-- ---------------------------------------------------------------------------

local function normalizeAlert(definition)
    if type(definition) ~= "table" then return nil, "definition_must_be_a_table" end
    if not validText(definition.title, 96, false) then return nil, "invalid_title" end
    if definition.message ~= nil and type(definition.message) ~= "string" then
        return nil, "invalid_message"
    end
    if definition.message ~= nil and #definition.message > 1024 then return nil, "invalid_message" end
    local confirm = definition.confirm or "Confirm"
    local cancel = definition.cancel
    if not validText(confirm, 32, false) then return nil, "invalid_confirm" end
    if cancel ~= nil and not validText(cancel, 32, false) then return nil, "invalid_cancel" end
    local timeout = timeoutOf(definition)
    if timeout == nil then return nil, "invalid_timeout" end
    local tone = definition.tone or "info"
    if tone ~= "info" and tone ~= "warning" and tone ~= "danger" and tone ~= "success" then
        return nil, "invalid_tone"
    end
    return {
        kind = "alert", title = definition.title, message = definition.message or "",
        confirm = confirm, cancel = cancel, tone = tone, timeout = timeout,
        size = definition.size == "large" and "large" or "normal",
    }
end

local function normalizeField(field, index)
    if type(field) ~= "table" then return nil, "invalid_field" end
    local kind = field.type or "text"
    if not FIELD_TYPES[kind] then return nil, "invalid_field_type" end
    local id = field.id or ("field" .. index)
    if not validName(id, 48) then return nil, "invalid_field_id" end
    if not validText(field.label, 96, false) then return nil, "invalid_field_label" end
    local out = {
        id = id, type = kind, label = field.label,
        description = validText(field.description, 240, true) and field.description or nil,
        required = field.required == true,
        placeholder = validText(field.placeholder, 96, true) and field.placeholder or nil,
    }
    if kind == "text" or kind == "password" or kind == "textarea" then
        out.min = integerIn(field.min, 0, 0, 4096)
        out.max = integerIn(field.max, 512, 1, 4096)
        if out.min == nil or out.max == nil then return nil, "invalid_field_range" end
        if field.default ~= nil then
            if not validText(field.default, out.max, true) then return nil, "invalid_field_default" end
            out.default = field.default
        end
    elseif kind == "number" or kind == "slider" then
        if field.min ~= nil and not finite(field.min) then return nil, "invalid_field_range" end
        if field.max ~= nil and not finite(field.max) then return nil, "invalid_field_range" end
        out.min = field.min or 0
        out.max = field.max or 100
        if out.max <= out.min then return nil, "invalid_field_range" end
        out.step = finite(field.step) and field.step > 0 and field.step or 1
        if field.default ~= nil then
            if not finite(field.default) then return nil, "invalid_field_default" end
            out.default = field.default
        end
    elseif kind == "checkbox" then
        out.default = field.default == true
    elseif kind == "select" then
        if type(field.options) ~= "table" or #field.options == 0 or #field.options > MAX_OPTIONS then
            return nil, "invalid_field_options"
        end
        local options = {}
        for position = 1, #field.options do
            local option = field.options[position]
            if type(option) == "string" then option = { value = option, label = option } end
            if type(option) ~= "table" then return nil, "invalid_field_options" end
            local value = option.value
            if not validText(value, 96, false) then return nil, "invalid_field_options" end
            local label = option.label or value
            if not validText(label, 96, false) then return nil, "invalid_field_options" end
            options[position] = { value = value, label = label }
        end
        out.options = options
        out.default = validText(field.default, 96, false) and field.default or options[1].value
    end
    return out
end

local function normalizeInput(definition)
    if type(definition) ~= "table" then return nil, "definition_must_be_a_table" end
    if not validText(definition.title, 96, false) then return nil, "invalid_title" end
    local source = definition.fields or definition.rows
    if type(source) ~= "table" or #source == 0 or #source > MAX_FIELDS then
        return nil, "invalid_fields"
    end
    local fields, seen = {}, {}
    for index = 1, #source do
        local field, reason = normalizeField(source[index], index)
        if not field then return nil, reason end
        if seen[field.id] then return nil, "duplicate_field_id" end
        seen[field.id] = true
        fields[index] = field
    end
    local timeout = timeoutOf(definition)
    if timeout == nil then return nil, "invalid_timeout" end
    return {
        kind = "input", title = definition.title, fields = fields, timeout = timeout,
        confirm = validText(definition.confirm, 32, false) and definition.confirm or "Confirm",
        cancel = validText(definition.cancel, 32, false) and definition.cancel or "Cancel",
        description = validText(definition.description, 240, true) and definition.description or nil,
    }
end

local function normalizeOption(option, index, allowNavigate)
    if type(option) ~= "table" then return nil, "invalid_option" end
    local id = option.id or ("option" .. index)
    if not validName(id, 48) then return nil, "invalid_option_id" end
    if not validText(option.label, 96, false) then return nil, "invalid_option_label" end
    local out = {
        id = id, label = option.label,
        description = validText(option.description, 240, true) and option.description or nil,
        icon = validText(option.icon, 16, true) and option.icon or nil,
        disabled = option.disabled == true,
        tone = option.tone == "danger" and "danger" or (option.tone == "success" and "success" or nil),
    }
    if allowNavigate and option.menu ~= nil then
        if not validName(option.menu, 64) then return nil, "invalid_option_menu" end
        out.menu = option.menu
    end
    if option.values ~= nil then
        if type(option.values) ~= "table" or #option.values == 0 or #option.values > MAX_OPTIONS then
            return nil, "invalid_option_values"
        end
        local values = {}
        for position = 1, #option.values do
            if not validText(option.values[position], 64, false) then return nil, "invalid_option_values" end
            values[position] = option.values[position]
        end
        out.values = values
        out.index = integerIn(option.defaultIndex, 1, 1, #values)
        if out.index == nil then return nil, "invalid_option_values" end
    end
    if option.checked ~= nil then
        if type(option.checked) ~= "boolean" then return nil, "invalid_option_checked" end
        out.checked = option.checked
    end
    if option.metadata ~= nil then
        if type(option.metadata) ~= "table" then return nil, "invalid_option_metadata" end
        local rows = {}
        for position = 1, math.min(#option.metadata, 8) do
            local row = option.metadata[position]
            if type(row) == "string" then row = { label = row } end
            if type(row) ~= "table" or not validText(row.label, 64, false) then
                return nil, "invalid_option_metadata"
            end
            rows[position] = {
                label = row.label,
                value = validText(row.value, 64, true) and row.value or nil,
            }
        end
        out.metadata = rows
    end
    return out
end

local function normalizeMenu(definition, kind)
    if type(definition) ~= "table" then return nil, "definition_must_be_a_table" end
    local id = definition.id
    if not validName(id, 64) then return nil, "invalid_menu_id" end
    if not validText(definition.title, 96, false) then return nil, "invalid_title" end
    local source = definition.options or definition.items
    if type(source) ~= "table" or #source == 0 then return nil, "invalid_options" end
    local limit = kind == "radial" and MAX_RADIAL_ITEMS or MAX_OPTIONS
    if #source > limit then return nil, "too_many_options" end
    local options, seen = {}, {}
    for index = 1, #source do
        local option, reason = normalizeOption(source[index], index, true)
        if not option then return nil, reason end
        if seen[option.id] then return nil, "duplicate_option_id" end
        seen[option.id] = true
        options[index] = option
    end
    return {
        kind = kind, id = id, title = definition.title, options = options,
        description = validText(definition.description, 240, true) and definition.description or nil,
        position = POSITIONS[definition.position] and definition.position or "center",
    }
end

-- The registry is owner-scoped, so two resources may both register "main".
local function registerMenu(owner, definition, kind)
    local normalized, reason = normalizeMenu(definition, kind)
    if not normalized then return nil, reason end
    local bucket = menus[owner]
    if bucket == nil then bucket = {} menus[owner] = bucket end
    if bucket[normalized.id] == nil then
        local count = 0
        for _ in pairs(bucket) do count = count + 1 end
        if count >= MAX_MENUS_PER_OWNER then return nil, "menu_limit" end
    end
    bucket[normalized.id] = normalized
    return true
end

local function specForMenu(owner, id, trail)
    local bucket = menus[owner]
    local definition = bucket and bucket[id] or nil
    if definition == nil then return nil, "menu_not_found" end
    -- Navigation is one-way: an option's `menu` field pushes onto the caller's
    -- trail and "back" pops it. There is deliberately no `parent` field -- a
    -- declared parent and a real trail can disagree, and the disagreement shows
    -- up as a back button that cancels instead of going back.
    return {
        kind = definition.kind, id = definition.id, title = definition.title,
        description = definition.description, position = definition.position,
        options = definition.options,
        canGoBack = #trail > 0,
    }
end

-- ---------------------------------------------------------------------------
-- Opening a focus dialog
--
-- Strictly one at a time, across every resource. A second request is REFUSED
-- with `dialog_active` rather than queued: a queued dialog that appears
-- seconds later, over a scene the player has moved on from, is worse than an
-- honest refusal -- and two resources fighting for one keyboard is the exact
-- failure this kit exists to prevent.
-- ---------------------------------------------------------------------------

local function beginDialog(owner, spec, timeout, extra)
    if page == nil then return nil, "surface_unavailable" end
    if not pageReady then return nil, "surface_not_ready" end
    if dialogToken ~= nil then return nil, "dialog_active" end
    local record = open(owner, "dialog", true, {
        deadline = now() + timeout / 1000,
        values = extra and extra.values or nil,
        useWhileDead = extra and extra.useWhileDead or false,
    })
    record.kind = spec.kind
    record.menuId = spec.id
    dialogToken = record.token
    send({ widget = "dialog", action = "open", token = record.token, spec = spec })
    syncVisible()
    return record
end

-- ---------------------------------------------------------------------------
-- Page events -- the single inbound channel
-- ---------------------------------------------------------------------------

local function onPageEvent(payload)
    if type(payload) ~= "table" then return end
    local token = tonumber(payload.token)
    local kind = payload.type
    if kind == "ready" then
        pageReady = true
        -- A claim that arrived before the page reported ready was dropped by
        -- `send`; the bars are a standing state, so they are simply told again.
        local top = cinematicOrder[#cinematicOrder]
        if top ~= nil and cinematicClaims[top] ~= nil then
            send({ widget = "cinematic", action = "show", spec = cinematicClaims[top] })
        end
        return
    end
    if token == nil then return end
    local record = live[token]
    -- A click that raced a close carries a token that is no longer live. It is
    -- dropped here rather than resolving whatever replaced it.
    if record == nil then return end

    if kind == "cancel" then
        -- A row menu carries its checkbox and side-scroll state out with it, so
        -- a settings menu made only of toggles is still readable after a close.
        settle(token, "cancelled", nil,
            type(payload.values) == "table" and { values = payload.values } or nil)
    elseif kind == "confirm" and record.widget == "dialog" and record.kind == "alert" then
        settle(token, "ok", "confirm")
    elseif kind == "submit" and record.widget == "dialog" and record.kind == "input" then
        settle(token, "ok", type(payload.values) == "table" and payload.values or {})
    elseif kind == "select" and record.widget == "dialog" then
        local optionId = payload.optionId
        local bucket = menus[record.owner]
        local definition = bucket and bucket[record.menuId] or nil
        local chosen
        if definition then
            for _, option in ipairs(definition.options) do
                if option.id == optionId then chosen = option break end
            end
        end
        if chosen == nil then return end
        if chosen.menu ~= nil then
            local spec, reason = specForMenu(record.owner, chosen.menu, record.trail)
            if not spec then warn("navigate: " .. tostring(reason)) return end
            record.trail[#record.trail + 1] = record.menuId
            record.menuId = chosen.menu
            spec.canGoBack = true
            send({ widget = "dialog", action = "open", token = token, spec = spec })
            return
        end
        settle(token, "ok", { id = optionId, menu = record.menuId },
            { values = type(payload.values) == "table" and payload.values or nil })
    elseif kind == "back" and record.widget == "dialog" then
        local previous = table.remove(record.trail)
        if previous == nil then settle(token, "cancelled") return end
        local spec, reason = specForMenu(record.owner, previous, record.trail)
        if not spec then settle(token, "cancelled") warn("back: " .. tostring(reason)) return end
        record.menuId = previous
        send({ widget = "dialog", action = "open", token = token, spec = spec })
    elseif kind == "progressDone" and record.widget == "progress" then
        settle(token, "ok")
    end
end

-- ---------------------------------------------------------------------------
-- Exports
-- ---------------------------------------------------------------------------

exports("progress", function(definition)
    local owner, reason = invokingOwner()
    if not owner then return nil, reason end
    local spec, badSpec = normalizeProgress(definition)
    if not spec then return nil, badSpec end
    if page == nil then return nil, "surface_unavailable" end
    if not pageReady then return nil, "surface_not_ready" end
    if progressToken ~= nil then return nil, "progress_active" end
    local record = open(owner, "progress", false, {
        disable = spec.disable,
        deadline = now() + spec.duration / 1000,
        useWhileDead = spec.useWhileDead,
    })
    record.cancellable = spec.cancellable
    record.cancelKey = spec.cancelKey
    progressToken = record.token
    send({ widget = "progress", action = "open", token = record.token, spec = spec })
    syncVisible()
    local answer = await(record.token)
    answer.value = nil
    return answer
end)

exports("progressActive", function()
    if progressToken == nil then return false end
    local record = live[progressToken]
    return record ~= nil, record and record.owner or nil
end)

exports("cancelProgress", function()
    local owner, reason = invokingOwner()
    if not owner then return nil, reason end
    if progressToken == nil then return nil, "progress_not_active" end
    local record = live[progressToken]
    if record and record.owner ~= owner then return nil, "not_owner" end
    settle(progressToken, "cancelled")
    return true
end)

exports("textUI", function(definition)
    local owner, reason = invokingOwner()
    if not owner then return nil, reason end
    local slot, badSlot = normalizeText(definition)
    if not slot then return nil, badSlot end
    if page == nil then return nil, "surface_unavailable" end
    if textSlots[owner] == nil then
        if #textOrder >= MAX_TEXT_SLOTS then return nil, "text_slot_limit" end
        textOrder[#textOrder + 1] = owner
    end
    slot.owner = owner
    textSlots[owner] = slot
    pushText()
    return true
end)

exports("hideTextUI", function()
    local owner, reason = invokingOwner()
    if not owner then return nil, reason end
    if textSlots[owner] == nil then return true end
    textSlots[owner] = nil
    for index = #textOrder, 1, -1 do
        if textOrder[index] == owner then table.remove(textOrder, index) end
    end
    pushText()
    return true
end)

exports("textUIState", function()
    local owner = invokingOwner()
    if not owner then return { open = false } end
    local slot = textSlots[owner]
    if slot == nil then return { open = false, total = #textOrder } end
    return { open = true, text = slot.text, position = slot.position, total = #textOrder }
end)

-- None of these wait, so the synchronous `exports.open77_uikit:drawText3D(...)`
-- spelling works -- which is the point for a ported per-frame loop: the call
-- that used to run every tick now runs once, inline, and returns a handle.
exports("drawText3D", function(definition)
    local owner, reason = invokingOwner()
    if not owner then return nil, reason end
    return createText3D(owner, definition)
end)

exports("updateText3D", function(handle, patch)
    local owner, reason = invokingOwner()
    if not owner then return nil, reason end
    return updateText3D(owner, handle, patch)
end)

-- `clearText3D(handle)` clears one; `clearText3D()` clears everything the
-- caller drew and returns the count. Clearing a handle that is already gone is
-- `true`, so a resource that tidies on every path can do so unconditionally.
exports("clearText3D", function(handle)
    local owner, reason = invokingOwner()
    if not owner then return nil, reason end
    if handle == nil then return true, clearText3dOwner(owner) end
    if type(handle) ~= "string" then return nil, "invalid_handle" end
    local record = texts3d[handle]
    if record == nil then return true end
    if record.owner ~= owner then return nil, "not_owner" end
    removeText3D(record)
    return true
end)

exports("listText3D", function()
    local owner = invokingOwner()
    if not owner then return {} end
    return listText3D(owner)
end)

-- `showCinematicBars(true, opts)` claims; `showCinematicBars(false)` releases
-- the caller's claim. `setCinematic` is the same function under the name the
-- parity ledger gives it (`hud.setCinematic(bool)`), for ports.
local function showCinematicBars(enabled, options)
    local owner, reason = invokingOwner()
    if not owner then return nil, reason end
    if type(enabled) ~= "boolean" then return nil, "enabled_must_be_a_boolean" end
    if enabled then return claimCinematic(owner, options) end
    releaseCinematic(owner)
    return true
end

exports("showCinematicBars", showCinematicBars)
exports("setCinematic", showCinematicBars)

exports("cinematicState", function()
    local owner = invokingOwner()
    return cinematicState(owner)
end)

exports("alert", function(definition)
    local owner, reason = invokingOwner()
    if not owner then return nil, reason end
    local spec, badSpec = normalizeAlert(definition)
    if not spec then return nil, badSpec end
    local record, refusal = beginDialog(owner, spec, spec.timeout, {
        useWhileDead = definition.useWhileDead == true,
    })
    if not record then return nil, refusal end
    return await(record.token)
end)

exports("input", function(definition)
    local owner, reason = invokingOwner()
    if not owner then return nil, reason end
    local spec, badSpec = normalizeInput(definition)
    if not spec then return nil, badSpec end
    local record, refusal = beginDialog(owner, spec, spec.timeout, {
        useWhileDead = definition.useWhileDead == true,
    })
    if not record then return nil, refusal end
    return await(record.token)
end)

exports("context", function(definition)
    local owner, reason = invokingOwner()
    if not owner then return nil, reason end
    return registerMenu(owner, definition, "context")
end)

exports("menu", function(definition)
    local owner, reason = invokingOwner()
    if not owner then return nil, reason end
    return registerMenu(owner, definition, "menu")
end)

exports("radial", function(definition)
    local owner, reason = invokingOwner()
    if not owner then return nil, reason end
    return registerMenu(owner, definition, "radial")
end)

local function showRegistered(owner, id, options, expectKind)
    if not validName(id, 64) then return nil, "invalid_menu_id" end
    local spec, reason = specForMenu(owner, id, {})
    if not spec then return nil, reason end
    if expectKind and spec.kind ~= expectKind then return nil, "menu_kind_mismatch" end
    local timeout = timeoutOf(type(options) == "table" and options or {})
    if timeout == nil then return nil, "invalid_timeout" end
    local record, refusal = beginDialog(owner, spec, timeout, {
        useWhileDead = type(options) == "table" and options.useWhileDead == true,
    })
    if not record then return nil, refusal end
    return await(record.token)
end

exports("showContext", function(id, options)
    local owner, reason = invokingOwner()
    if not owner then return nil, reason end
    return showRegistered(owner, id, options, "context")
end)

exports("showMenu", function(id, options)
    local owner, reason = invokingOwner()
    if not owner then return nil, reason end
    return showRegistered(owner, id, options, "menu")
end)

exports("showRadial", function(id, options)
    local owner, reason = invokingOwner()
    if not owner then return nil, reason end
    return showRegistered(owner, id, options, "radial")
end)

exports("hideContext", function()
    local owner, reason = invokingOwner()
    if not owner then return nil, reason end
    if dialogToken == nil then return true end
    local record = live[dialogToken]
    if record and record.owner ~= owner then return nil, "not_owner" end
    settle(dialogToken, "cancelled")
    return true
end)

exports("hideMenu", function()
    local owner, reason = invokingOwner()
    if not owner then return nil, reason end
    if dialogToken == nil then return true end
    local record = live[dialogToken]
    if record and record.owner ~= owner then return nil, "not_owner" end
    settle(dialogToken, "cancelled")
    return true
end)

exports("hideRadial", function()
    local owner, reason = invokingOwner()
    if not owner then return nil, reason end
    if dialogToken == nil then return true end
    local record = live[dialogToken]
    if record and record.owner ~= owner then return nil, "not_owner" end
    settle(dialogToken, "cancelled")
    return true
end)

exports("close", function()
    local owner, reason = invokingOwner()
    if not owner then return nil, reason end
    return true, closeOwner(owner, "cancelled")
end)

-- Diagnostic, not steady-state API. It is what an integrator reads when a
-- dialog "did nothing": it separates "the surface never reported ready" from
-- "another resource holds the dialog" from "focus is stuck".
exports("state", function()
    local blocks = {}
    for action, count in pairs(blockCounts) do
        if count > 0 then blocks[#blocks + 1] = { action = action, holders = count } end
    end
    table.sort(blocks, function(left, right) return left.action < right.action end)
    local widgets = {}
    for token, record in pairs(live) do
        widgets[#widgets + 1] = {
            token = token, owner = record.owner, widget = record.widget,
            kind = record.kind, focus = record.focus,
        }
    end
    table.sort(widgets, function(left, right) return left.token < right.token end)
    return {
        ready = pageReady, visible = pageVisible, focusHeld = focusHeld,
        dialog = dialogToken, progress = progressToken,
        textSlots = #textOrder, blockAll = blockAllCount > 0,
        blocks = blocks, widgets = widgets,
        texts3d = text3dTotal, cinematic = cinematicShown, cinematicHudHidden = cinematicHudHeld,
    }
end)

-- ---------------------------------------------------------------------------
-- The server twin
--
-- A server asking a client a question is a REQUEST, not a command. It arrives
-- as a callback, so it already carries a deadline the asker chose; this side
-- adds nothing but a bound of its own. The answer is the same table the client
-- export resolves with, so a job step reads one shape wherever it runs.
--
-- `owner` is the calling SERVER resource, prefixed so it can never collide with
-- a local client resource name -- the same trick `open77_notifications` uses.
-- ---------------------------------------------------------------------------

local KINDS = {
    alert = normalizeAlert,
    input = normalizeInput,
}

local function serverOwner(value)
    if not validName(value, 64) then return nil end
    return "@server:" .. value
end

local function answerServer(envelope)
    if type(envelope) ~= "table" then return { ok = false, outcome = "cancelled", reason = "invalid_request" } end
    local owner = serverOwner(envelope.owner)
    if owner == nil then return { ok = false, outcome = "cancelled", reason = "invalid_owner" } end
    ownerGenerations[owner] = ownerGenerations[owner] or 0
    local kind = envelope.kind

    if kind == "textUI" then
        local slot, reason = normalizeText(envelope.definition)
        if not slot then return { ok = false, outcome = "cancelled", reason = reason } end
        if textSlots[owner] == nil then
            if #textOrder >= MAX_TEXT_SLOTS then
                return { ok = false, outcome = "cancelled", reason = "text_slot_limit" }
            end
            textOrder[#textOrder + 1] = owner
        end
        slot.owner = owner
        textSlots[owner] = slot
        pushText()
        return { ok = true, outcome = "ok" }
    end
    if kind == "hideTextUI" then
        if textSlots[owner] ~= nil then
            textSlots[owner] = nil
            for index = #textOrder, 1, -1 do
                if textOrder[index] == owner then table.remove(textOrder, index) end
            end
            pushText()
        end
        return { ok = true, outcome = "ok" }
    end
    if kind == "close" then
        return { ok = true, outcome = "ok", closed = closeOwner(owner, "cancelled") }
    end
    -- The world-text and letterbox twins. None of them waits on the player, so
    -- the answer is the export's own `value | nil, reason` folded into the one
    -- table shape every twin resolves with: `value` carries the handle.
    if kind == "text3d" then
        local handle, reason = createText3D(owner, envelope.definition)
        if handle == nil then return { ok = false, outcome = "cancelled", reason = reason } end
        return { ok = true, outcome = "ok", value = handle }
    end
    if kind == "updateText3d" then
        local ok, reason = updateText3D(owner, envelope.handle, envelope.definition)
        if not ok then return { ok = false, outcome = "cancelled", reason = reason } end
        return { ok = true, outcome = "ok" }
    end
    if kind == "clearText3d" then
        if envelope.handle == nil then
            return { ok = true, outcome = "ok", value = clearText3dOwner(owner) }
        end
        local record = type(envelope.handle) == "string" and texts3d[envelope.handle] or nil
        if record ~= nil and record.owner ~= owner then
            return { ok = false, outcome = "cancelled", reason = "not_owner" }
        end
        if record ~= nil then removeText3D(record) end
        return { ok = true, outcome = "ok" }
    end
    if kind == "cinematic" then
        if type(envelope.enabled) ~= "boolean" then
            return { ok = false, outcome = "cancelled", reason = "enabled_must_be_a_boolean" }
        end
        if envelope.enabled then
            local ok, reason = claimCinematic(owner, envelope.definition)
            if not ok then return { ok = false, outcome = "cancelled", reason = reason } end
        else
            releaseCinematic(owner)
        end
        return { ok = true, outcome = "ok", value = cinematicState(owner) }
    end
    if kind == "progress" then
        local spec, reason = normalizeProgress(envelope.definition)
        if not spec then return { ok = false, outcome = "cancelled", reason = reason } end
        if page == nil or not pageReady then
            return { ok = false, outcome = "cancelled", reason = "surface_not_ready" }
        end
        if progressToken ~= nil then
            return { ok = false, outcome = "cancelled", reason = "progress_active" }
        end
        local record = open(owner, "progress", false, {
            disable = spec.disable, deadline = now() + spec.duration / 1000,
            useWhileDead = spec.useWhileDead,
        })
        record.cancellable = spec.cancellable
        record.cancelKey = spec.cancelKey
        progressToken = record.token
        send({ widget = "progress", action = "open", token = record.token, spec = spec })
        syncVisible()
        local answer = await(record.token)
        answer.value = nil
        return answer
    end
    if kind == "menu" or kind == "context" or kind == "radial" then
        local ok, reason = registerMenu(owner, envelope.definition, kind)
        if not ok then return { ok = false, outcome = "cancelled", reason = reason } end
        -- `show = false` registers without opening, so a server can publish a
        -- menu once and open it later from either side.
        local options = type(envelope.options) == "table" and envelope.options or nil
        if envelope.show == false or (options and options.show == false) then
            return { ok = true, outcome = "ok" }
        end
        local answer, refusal = showRegistered(owner, envelope.definition.id, envelope.options, kind)
        if answer == nil then return { ok = false, outcome = "cancelled", reason = refusal } end
        return answer
    end

    local normalize = KINDS[kind]
    if normalize == nil then return { ok = false, outcome = "cancelled", reason = "unknown_widget" } end
    local spec, reason = normalize(envelope.definition)
    if not spec then return { ok = false, outcome = "cancelled", reason = reason } end
    local record, refusal = beginDialog(owner, spec, spec.timeout, {
        useWhileDead = type(envelope.definition) == "table" and envelope.definition.useWhileDead == true,
    })
    if not record then return { ok = false, outcome = "cancelled", reason = refusal } end
    return await(record.token)
end

-- Exposed for the test harness and for `open77_uikit`'s own server half.
Open77UiKitAnswerServer = answerServer

-- ---------------------------------------------------------------------------
-- The focus release matrix
-- ---------------------------------------------------------------------------

-- 3. Escape. The plugin swallows Escape in the window procedure, so a focused
--    page's own key handler never fires in a live session; this is the path
--    that actually runs.
AddEventHandler("open77:pauseKey", function()
    if dialogToken ~= nil then settle(dialogToken, "cancelled") return end
    if progressToken ~= nil then
        local record = live[progressToken]
        if record and record.cancellable then settle(progressToken, "cancelled") end
    end
end)

-- 7. The player died. A dialog that survives death leaves a respawn screen the
--    player cannot click through. `useWhileDead` opts one widget out.
AddEventHandler("open77:playerLifeStateChanged", function(playerId, phase)
    local session = Open77.network and Open77.network.status and Open77.network.status() or nil
    if session and tonumber(session.playerId) ~= tonumber(playerId) then return end
    if phase == "alive" then return end
    settleWhere(function(record) return not record.useWhileDead end, "cancelled")
end)

-- 8. The session ended. Nothing survives a disconnect.
AddEventHandler("open77:session:ended", function()
    settleWhere(function() return true end, "cancelled")
    for owner in pairs(textSlots) do textSlots[owner] = nil end
    textOrder = {}
    pushText()
    -- World text has no world to sit in, and a letterbox over the main menu
    -- would be a black frame the player cannot explain.
    for handle in pairs(texts3d) do removeText3D(texts3d[handle]) end
    for owner in pairs(cinematicClaims) do cinematicClaims[owner] = nil end
    cinematicOrder = {}
    syncCinematic()
    cinematicHideAt, cinematicShown = nil, false
    syncVisible()
end)

-- 5/6. A resource stopped: either an owner, or us.
AddEventHandler("onClientResourceStop", function(name)
    if name == RESOURCE then
        running = false
        -- Focus FIRST, before anything can raise. The host would drop the
        -- surface anyway, but a release that depends on the platform noticing
        -- is not a release path, it is a hope.
        focusHolders = {}
        if page then page:setFocus(false, false) end
        focusHeld = false
        live = {}
        auditBlocks()
        settled, menus, textSlots, textOrder = {}, {}, {}, {}
        -- The host drops this resource's anchors and HUD loan with the
        -- generation; releasing them here as well is the same rule as focus:
        -- a release that depends on the platform noticing is a hope.
        for handle in pairs(texts3d) do removeText3D(texts3d[handle]) end
        for owner in pairs(cinematicClaims) do cinematicClaims[owner] = nil end
        cinematicOrder = {}
        if cinematicHudHeld and Open77.hud and Open77.hud.setVisible then
            Open77.hud.setVisible("all", true)
        end
        cinematicHudHeld, cinematicShown, cinematicHideAt = false, false, nil
        progressToken, dialogToken, page, pageReady = nil, nil, nil, false
        return
    end
    closeOwner(name, "cancelled")
    ownerGenerations[name] = nil
end)

AddEventHandler("onClientResourceStart", function(name)
    if name ~= RESOURCE then return end
    local reason
    page, reason = WebUI.create({
        entry = "web/index.html",
        -- `menu`, not `modal`: the modal layer needs `webui.modal` and would put
        -- this surface above the shell. 690 leaves chat (700) and the admin
        -- panel (720) drawing ABOVE a dialog on purpose -- a player must always
        -- be able to reach the thing he uses to complain.
        layer = "menu", zIndex = 690,
        width = 1920, height = 1080, fps = 30,
        transparent = true, visible = false,
    })
    if not page then
        warn("WebUI failed: " .. tostring(reason))
        return
    end
    page:on("uikit:event", onPageEvent)

    CreateThread(function()
        while running and page do
            local current = now()

            -- 4. Timeout. Every dialog carries a deadline; a widget nobody ever
            --    answers is not allowed to hold the keyboard forever.
            local expired = {}
            for token, record in pairs(live) do
                if record.deadline and current >= record.deadline then
                    expired[#expired + 1] = token
                end
            end
            table.sort(expired)
            for _, token in ipairs(expired) do
                local record = live[token]
                -- A progress bar that reaches its deadline SUCCEEDED. Everything
                -- else that reaches one timed out.
                settle(token, record and record.widget == "progress" and "ok" or "timeout")
            end

            -- The progress cancel key. Polled rather than focused, because a
            -- focused progress bar would eat the keyboard -- level read, so the
            -- edge is derived here; `isCaptured` stands the key down while chat
            -- or another surface legitimately owns the keyboard.
            if progressToken ~= nil then
                local record = live[progressToken]
                local captured = Open77.input.isCaptured and Open77.input.isCaptured() == true
                local down = false
                if record and record.cancellable and not captured then
                    down = Open77.input.isDown(record.cancelKey) == true
                end
                if down and not cancelKeyWasDown then settle(progressToken, "cancelled") end
                cancelKeyWasDown = down
            else
                cancelKeyWasDown = false
            end

            -- A 3D text past its ttl goes on its own, whether or not its owner
            -- ever calls the kit again.
            if text3dTotal > 0 then sweepText3D(current) end

            -- The letterbox has finished sliding out: now the surface may go.
            if cinematicHideAt ~= nil and current >= cinematicHideAt then
                cinematicHideAt = nil
                cinematicShown = false
            end

            -- 5c. An owner whose resource went away between two ticks, and any
            --     answer nobody ever collected. A settled record is normally
            --     taken by the awaiting export task on its next poll; one that
            --     is still here 30 s later belongs to a task that died with its
            --     resource, and it is a leak, not a result.
            if current >= nextSweep then
                nextSweep = current + SWEEP_SECONDS
                for token, answer in pairs(settled) do
                    if answer.settledAt and current - answer.settledAt > 30 then
                        settled[token] = nil
                    end
                end
                for owner, generation in pairs(ownerGenerations) do
                    if owner:sub(1, 8) ~= "@server:" and
                        (GetResourceState(owner) ~= "running" or
                         Open77.resource.generation(owner) ~= generation) then
                        closeOwner(owner, "cancelled")
                        ownerGenerations[owner] = nil
                    end
                end
            end

            -- The watchdog. If the ledger is empty, nothing may still be held:
            -- not focus, not a control block, not the surface.
            if next(focusHolders) == nil and focusHeld then syncFocus() end
            auditBlocks()
            syncVisible()

            Wait(POLL_MS)
        end
    end)
end)

-- The client half of the server twin. Registered defensively: `Open77.net` is
-- the callback transport and a host without it must fail loudly on the server
-- rather than hang until the deadline.
if Open77 and Open77.net and Open77.net.register then
    Open77.net.register("ask", function(envelope)
        return answerServer(envelope)
    end)
end
