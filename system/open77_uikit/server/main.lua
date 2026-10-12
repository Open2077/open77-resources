-- open77_uikit -- server twins.
--
-- ===========================================================================
-- A server twin is a REQUEST, not a command
-- ===========================================================================
--
-- Every function here asks one client a question and waits for the answer. The
-- client may never answer: it may be loading, dead, already holding a dialog
-- for another resource, or gone. So there are exactly two result shapes and
-- they are never confused:
--
--   nil, reason   the question never reached an answer. `reason` is a stable
--                 snake_case token from the callback transport
--                 (`callback_timeout`, `callback_not_found`,
--                 `callback_resource_unavailable`, `network_unavailable`,
--                 `callback_target_stopped`, ...) or one of this file's own
--                 argument refusals. Nothing was shown to the player, or if it
--                 was, this side can no longer say what happened to it.
--
--   a table       the client answered. `{ ok, outcome, value }`, exactly the
--                 table the client export resolves with, so a job step reads
--                 one shape whether the bar was driven from the client or from
--                 here. `outcome` is "ok", "cancelled" or "timeout".
--
-- A cancel is a table with `ok = false`, never a `nil, reason`: the player
-- pressing Escape is ordinary behaviour and a caller should not need a pcall
-- around it.
--
-- The transport deadline is deliberately LONGER than the dialog's own. If they
-- were equal the server would give up in the same instant the player was still
-- reading, and the client would be left holding focus for a question nobody is
-- listening to any more.
-- ===========================================================================

local RESOURCE = GetCurrentResourceName()

local CALLBACK_SLACK_MS = 5000
local MAX_CALLBACK_MS = 120000       -- the transport's own ceiling
local MIN_CALLBACK_MS = 1000
local DEFAULT_DIALOG_MS = 60000

local function validName(value, maximum)
    return type(value) == "string" and #value > 0 and #value <= maximum and
        value:match("^[%w_:%-%.]+$") ~= nil
end

local function validPlayer(value)
    return type(value) == "number" and value % 1 == 0 and value >= 1
end

-- The client's own deadline plus slack, clamped into the transport's range.
--
-- Read explicitly rather than by looping over `{ options, definition }`:
-- `options` is usually nil and `ipairs` stops at the first hole, so the loop
-- would silently never look at `definition` and every dialog would get the
-- default deadline. That is the kind of bug that only shows up as "the server
-- gave up while the player was still reading".
local function declaredTimeout(source)
    if type(source) ~= "table" then return nil end
    local value = source.timeoutMs
    if value == nil then value = source.timeout end
    if type(value) ~= "number" then return nil end
    return value
end

local function callbackTimeout(definition, options)
    local wanted = declaredTimeout(options)
    if wanted == nil then wanted = declaredTimeout(definition) end
    if wanted == nil then wanted = DEFAULT_DIALOG_MS end
    local total = wanted + CALLBACK_SLACK_MS
    if total < MIN_CALLBACK_MS then total = MIN_CALLBACK_MS end
    if total > MAX_CALLBACK_MS then total = MAX_CALLBACK_MS end
    return math.floor(total)
end

-- `owner` MUST be captured before the first yield: the invocation context is
-- cleared across yields, exactly as on the client.
local function ask(owner, playerId, envelope, timeout)
    if not validPlayer(playerId) then return nil, "invalid_player" end
    if Open77.net == nil or Open77.net.callClientAwait == nil then
        return nil, "callbacks_unavailable"
    end
    envelope.owner = owner
    local answer, reason = Open77.net.callClientAwait(
        playerId, { name = "ask", timeout = timeout }, envelope)
    if answer == nil then return nil, reason or "callback_failed" end
    if type(answer) ~= "table" then return nil, "invalid_client_answer" end
    return answer
end

local function owned()
    local owner = GetInvokingResource()
    if not validName(owner, 64) then return nil, "export_call_required" end
    return owner
end

local function run(owner, kind, playerId, definition, options)
    if type(definition) ~= "table" and type(definition) ~= "string" then
        return nil, "definition_must_be_a_table"
    end
    return ask(owner, playerId, {
        kind = kind, definition = definition, options = options,
    }, callbackTimeout(definition, options))
end

local function widget(kind)
    return function(playerId, definition, options)
        local owner, reason = owned()
        if not owner then return nil, reason end
        return run(owner, kind, playerId, definition, options)
    end
end

exports("progress", widget("progress"))
exports("alert", widget("alert"))
exports("input", widget("input"))
exports("textUI", widget("textUI"))
exports("context", widget("context"))
exports("menu", widget("menu"))
exports("radial", widget("radial"))

exports("hideTextUI", function(playerId)
    local owner, reason = owned()
    if not owner then return nil, reason end
    return ask(owner, playerId, { kind = "hideTextUI" }, MIN_CALLBACK_MS * 5)
end)

exports("close", function(playerId)
    local owner, reason = owned()
    if not owner then return nil, reason end
    return ask(owner, playerId, { kind = "close" }, MIN_CALLBACK_MS * 5)
end)

-- ---------------------------------------------------------------------------
-- World text and the letterbox
--
-- Neither waits on the player, so the deadline is the short one every
-- fire-and-confirm twin uses. The answer is still the one table shape:
-- `value` carries the text handle (a string the client minted, opaque here)
-- or, for the bars, the client's `cinematicState()`.
-- ---------------------------------------------------------------------------

exports("drawText3D", function(playerId, definition)
    local owner, reason = owned()
    if not owner then return nil, reason end
    if type(definition) ~= "table" then return nil, "definition_must_be_a_table" end
    return ask(owner, playerId, { kind = "text3d", definition = definition }, MIN_CALLBACK_MS * 5)
end)

exports("updateText3D", function(playerId, handle, patch)
    local owner, reason = owned()
    if not owner then return nil, reason end
    if type(handle) ~= "string" then return nil, "invalid_handle" end
    if type(patch) ~= "table" then return nil, "patch_must_be_a_table" end
    return ask(owner, playerId, { kind = "updateText3d", handle = handle, definition = patch },
        MIN_CALLBACK_MS * 5)
end)

exports("clearText3D", function(playerId, handle)
    local owner, reason = owned()
    if not owner then return nil, reason end
    if handle ~= nil and type(handle) ~= "string" then return nil, "invalid_handle" end
    return ask(owner, playerId, { kind = "clearText3d", handle = handle }, MIN_CALLBACK_MS * 5)
end)

local function showCinematicBars(playerId, enabled, options)
    local owner, reason = owned()
    if not owner then return nil, reason end
    if type(enabled) ~= "boolean" then return nil, "enabled_must_be_a_boolean" end
    if options ~= nil and type(options) ~= "table" then return nil, "options_must_be_a_table" end
    return ask(owner, playerId, { kind = "cinematic", enabled = enabled, definition = options },
        MIN_CALLBACK_MS * 5)
end

exports("showCinematicBars", showCinematicBars)
exports("setCinematic", showCinematicBars)

-- ---------------------------------------------------------------------------
-- The three-minute integrator demo
--
-- `/uikit.demo <widget>` drives one widget on the caller's own client through
-- the server twin, so the checklist in wiki/ui-kit.md exercises the REAL
-- server-to-client path rather than a client-only shortcut. Restricted: it is
-- an operator tool, not a player command.
-- ---------------------------------------------------------------------------

-- These call `run` directly rather than through `exports.open77_uikit:...`.
-- The synchronous export proxy has no scheduler underneath it and every twin
-- here yields on the callback, so the sugar would fail with `export_yielded`.
local DEMOS = {
    progress = function(source)
        return run(RESOURCE, "progress", source, {
            label = "Hotwiring the door", duration = 4000,
            disable = { move = true, combat = true },
        })
    end,
    text = function(source)
        return run(RESOURCE, "textUI", source, {
            text = "Hold to hotwire", key = "E", eyebrow = "Door",
        })
    end,
    hidetext = function(source)
        return ask(RESOURCE, source, { kind = "hideTextUI" }, MIN_CALLBACK_MS * 5)
    end,
    alert = function(source)
        return run(RESOURCE, "alert", source, {
            title = "Sell the vehicle?",
            message = "The Quadra will be gone for good. 12 400 eddies, paid on hand-over.",
            confirm = "Sell it", cancel = "Keep it", tone = "warning", timeoutMs = 30000,
        })
    end,
    input = function(source)
        return run(RESOURCE, "input", source, {
            title = "Register the plate",
            fields = {
                { id = "plate", type = "text", label = "Plate", max = 8, required = true },
                { id = "colour", type = "select", label = "Colour",
                  options = { "Chrome", "Matte black", "Samurai red" } },
                { id = "tint", type = "slider", label = "Window tint", min = 0, max = 100, default = 40 },
                { id = "insured", type = "checkbox", label = "Insure it" },
            },
            timeoutMs = 60000,
        })
    end,
    context = function(source)
        return run(RESOURCE, "context", source, {
            id = "demo_garage", title = "Northside garage",
            description = "Three bays, one owner.",
            options = {
                { id = "retrieve", label = "Retrieve a vehicle", icon = "V",
                  description = "Bring it up to the ramp." },
                { id = "store", label = "Store this vehicle", icon = "S" },
                { id = "impound", label = "Pay the impound fee", icon = "!", tone = "danger",
                  metadata = { { label = "Fee", value = "2 000" } } },
            },
        })
    end,
    menu = function(source)
        return run(RESOURCE, "menu", source, {
            id = "demo_settings", title = "Squad settings",
            options = {
                { id = "voice", label = "Squad voice", checked = true },
                { id = "range", label = "Radio range", values = { "Short", "Medium", "Long" }, defaultIndex = 2 },
                { id = "leave", label = "Leave the squad", tone = "danger" },
            },
        })
    end,
    radial = function(source)
        return run(RESOURCE, "radial", source, {
            id = "demo_radial", title = "Quick actions",
            options = {
                { id = "hands", label = "Hands up", icon = "H" },
                { id = "point", label = "Point", icon = "P" },
                { id = "sit", label = "Sit", icon = "S" },
                { id = "cuff", label = "Cuff", icon = "C" },
            },
        })
    end,
    -- A string floating five metres north of the caller for a minute, with a
    -- 50 m band: walk 60 m away and it is gone, walk behind a wall and the
    -- occlusion test drops it, come back and it is there again.
    text3d = function(source)
        local player = Open77.players and Open77.players.get and Open77.players.get(source) or nil
        local at = player and player.position or nil
        if at == nil then return nil, "player_position_unavailable" end
        return ask(RESOURCE, source, {
            kind = "text3d",
            definition = {
                position = { x = at.x, y = at.y + 5.0, z = at.z + 1.2 },
                text = "Delivery point", sublabel = "uikit.demo text3d",
                maxDistance = 50, ttl = 60000, showDistance = true,
            },
        }, MIN_CALLBACK_MS * 5)
    end,
    cinematic = function(source)
        return ask(RESOURCE, source, { kind = "cinematic", enabled = true,
            definition = { heightPct = 12, durationMs = 400 } }, MIN_CALLBACK_MS * 5)
    end,
    nocinematic = function(source)
        return ask(RESOURCE, source, { kind = "cinematic", enabled = false }, MIN_CALLBACK_MS * 5)
    end,
}

RegisterCommand("uikit.demo", function(source, args, raw)
    if source == nil or source <= 0 then
        print("uikit.demo must be issued by an authenticated in-game operator")
        return
    end
    local name = tostring(args[1] or "alert"):lower()
    local demo = DEMOS[name]
    if demo == nil then
        local names = {}
        for key in pairs(DEMOS) do names[#names + 1] = key end
        table.sort(names)
        TriggerClientEvent("open77:command:result", source, raw or "uikit.demo", false,
            "unknown widget; try one of: " .. table.concat(names, ", "))
        return
    end
    -- The twin yields on a callback that can take a minute; a command handler
    -- is not guaranteed to be a scheduler coroutine, and `await` outside one
    -- answers `await_requires_scheduler_coroutine` instead of waiting.
    CreateThread(function()
        local answer, reason = demo(source)
        if answer == nil then
            TriggerClientEvent("open77:command:result", source, raw or "uikit.demo", false,
                "the client never answered: " .. tostring(reason))
            return
        end
        local detail = tostring(answer.outcome)
        if answer.reason then detail = detail .. " (" .. tostring(answer.reason) .. ")" end
        if type(answer.value) == "string" then
            detail = detail .. " -> " .. answer.value
        elseif type(answer.value) == "table" then
            local parts = {}
            for key, value in pairs(answer.value) do
                if type(key) == "string" and type(value) ~= "table" then
                    parts[#parts + 1] = key .. "=" .. tostring(value)
                end
            end
            table.sort(parts)
            if #parts > 0 then detail = detail .. " -> " .. table.concat(parts, " ") end
        end
        TriggerClientEvent("open77:command:result", source, raw or "uikit.demo",
            answer.ok == true, detail)
    end)
end, true)

RegisterNetEvent("chat:ready", function()
    TriggerClientEvent("chat:addSuggestions", source, {{
        command = "/uikit.demo",
        help = "Drive one open77_uikit widget through the server twin.",
        parameters = {{
            name = "progress|text|hidetext|alert|input|context|menu|radial|text3d|cinematic|nocinematic",
            optional = true,
        }},
    }})
end)

print("Open77 UI kit ready; " .. RESOURCE .. " server twins published, try /uikit.demo alert")
