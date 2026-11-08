-- open77_braindance vision layers: the braindance editor's VISUAL / THERMAL /
-- AUDIO layers rendered on the live world with the game's native render.
--
-- A real braindance draws its layers from a rewindable quest scene. Outside one,
-- the client composes the same read from native pieces:
--   * Open77.braindance.setHeatmap  every body in range painted with the
--     engine highlight (fill + outline, through walls) in a palette colour;
--   * focusWorld                    the world in the engine's focus vision
--     mode -- the scanner's dark, cold render -- under the heat silhouettes;
--   * braindance_sound_vision_mode  the authored braindance shimmer on the
--     player camera (VISUAL and AUDIO layers).
-- No interface: resources draw their own from the exports and the event.
--
-- Exports (client):  setLayer(layer, options?) -> true | nil, reason
--                    layer() -> name, nextLayer(options?), layers()
--                    setHeat(target, level), clearHeat(), heatmap()
-- Local event:       open77_braindance:layer (layer, previous)
-- Server is told:    open77_braindance:layerReport (layer, previous)

local LAYER_ORDER = { "visual", "thermal", "audio" }
local SHIMMER = "braindance_sound_vision_mode"

-- Defaults per layer. `heat` is passed to Open77.braindance.setHeatmap (after
-- the caller's own `heat` options are laid over it); nil turns the heatmap off.
local LAYERS = {
    off = { effect = nil, heat = nil },
    visual = { effect = SHIMMER, heat = nil },
    thermal = {
        effect = nil,
        heat = {
            focusWorld = true, seeThroughWalls = true, radius = 60, opacity = 1,
            colors = { npc = "hostile", player = "quest", vehicle = "neutral",
                       cool = "neutral", warm = "quest", hot = "hostile", clue = "clue" },
        },
    },
    audio = {
        effect = SHIMMER,
        heat = {
            focusWorld = false, seeThroughWalls = true, radius = 40, opacity = 0.8,
            colors = { npc = "friendly", player = "friendly", vehicle = "neutral",
                       cool = "neutral", warm = "friendly", hot = "aoe", clue = "clue" },
        },
    },
}

local state = { layer = "off", options = {}, effectHandle = nil, effectName = nil }

local function log(fmt, ...) print(("[open77_braindance] " .. fmt):format(...)) end

local function copy(t)
    if type(t) ~= "table" then return t end
    local out = {}
    for k, v in pairs(t) do out[k] = copy(v) end
    return out
end

-- `over` laid on `base`, one level deep for `colors`.
local function merge(base, over)
    local out = copy(base) or {}
    if type(over) ~= "table" then return out end
    for k, v in pairs(over) do
        if k == "colors" and type(v) == "table" then
            out.colors = out.colors or {}
            for ck, cv in pairs(v) do out.colors[ck] = cv end
        else
            out[k] = copy(v)
        end
    end
    return out
end

-- ---- layers -----------------------------------------------------------------

local function stopEffect()
    if state.effectHandle then pcall(Open77.vfx.stop, state.effectHandle) end
    state.effectHandle, state.effectName = nil, nil
end

local function startEffect(name)
    if state.effectName == name and state.effectHandle then return end
    stopEffect()
    if not name then return end
    local handle, reason = Open77.vfx.playEntity(name, { entity = "1", breakAllLoops = false })
    if handle then state.effectHandle, state.effectName = handle, name
    else log("layer effect %s refused: %s", name, tostring(reason)) end
end

local function setLayer(layer, options)
    if type(layer) ~= "string" or not LAYERS[layer] then return nil, "invalid_layer" end
    if options ~= nil and type(options) ~= "table" then return nil, "invalid_options" end
    options = options or {}
    if options.heat ~= nil and type(options.heat) ~= "table" then return nil, "invalid_heat" end
    local def = LAYERS[layer]

    -- Heat first: it is the one step that can refuse (bad options, another
    -- resource owning the heatmap), and a refusal must leave the layer as it was.
    if def.heat then
        local ok, reason = Open77.braindance.setHeatmap(true, merge(def.heat, options.heat))
        if not ok then return nil, reason end
    else
        local current = Open77.braindance.heatmap()
        if current and current.mine then Open77.braindance.setHeatmap(false) end
    end

    if options.effect == false then stopEffect() else startEffect(def.effect) end

    local previous = state.layer
    state.layer, state.options = layer, copy(options)

    if previous ~= layer then
        log("layer %s -> %s", previous, layer)
        if def.heat then
            CreateThread(function()
                Wait(1500)
                local heat = Open77.braindance.heatmap() or {}
                log("heatmap: painted %s of %s bodies%s", tostring(heat.painted), tostring(heat.candidates),
                    heat.lastError and (" (" .. heat.lastError .. ")") or "")
            end)
        end
        TriggerEvent("open77_braindance:layer", layer, previous)
        pcall(TriggerServerEvent, "open77_braindance:layerReport", layer, previous)
    end
    return true
end

local function nextLayer(options)
    local index = 0
    for i, name in ipairs(LAYER_ORDER) do if name == state.layer then index = i end end
    return setLayer(LAYER_ORDER[index % #LAYER_ORDER + 1], options or state.options)
end

-- A target is an entity integer, { engineEntity }, { playerId } or { npcId }.
local function resolveTarget(target)
    if type(target) == "table" then
        if target.playerId ~= nil then
            local entity = Open77.players.entity(target.playerId)
            if not entity then return nil, "player_unavailable" end
            return entity
        elseif target.npcId ~= nil then
            local entity = Open77.npcs.entity(target.npcId)
            if not entity then return nil, "npc_unavailable" end
            return entity
        end
    end
    return target
end

local function setHeat(target, level)
    local resolved, reason = resolveTarget(target)
    if not resolved then return nil, reason end
    return Open77.braindance.setHeat(resolved, level)
end

exports("setLayer", setLayer)
exports("layer", function() return state.layer end)
exports("layers", function() return copy(LAYER_ORDER) end)
exports("nextLayer", nextLayer)
exports("setHeat", setHeat)
exports("clearHeat", function() return Open77.braindance.clearHeat() end)
exports("heatmap", function() return Open77.braindance.heatmap() end)

-- Server-driven layers (exports on the server name the player).
RegisterNetEvent("open77_braindance:setLayer", function(layer, options)
    local ok, reason = setLayer(layer, type(options) == "table" and options or nil)
    if not ok then pcall(TriggerServerEvent, "open77_braindance:layerReport", state.layer, state.layer, reason) end
end)
RegisterNetEvent("open77_braindance:setHeat", function(target, level)
    local ok, reason = setHeat(target, level)
    if not ok then log("server setHeat refused: %s", tostring(reason)) end
end)
RegisterNetEvent("open77_braindance:clearHeat", function() Open77.braindance.clearHeat() end)

AddEventHandler("onClientResourceStop", function(name)
    if name ~= GetCurrentResourceName() then return end
    stopEffect() -- the host releases the heatmap with the resource
end)

-- Developer console: `bdlayer <off|visual|thermal|audio|next> [noeffect]`.
RegisterCommand("bdlayer", function(_, args)
    local verb = args[1] or "next"
    local options = args[2] == "noeffect" and { effect = false } or nil
    local ok, reason
    if verb == "next" then ok, reason = nextLayer(options) else ok, reason = setLayer(verb, options) end
    local heat = Open77.braindance.heatmap() or {}
    log("bdlayer %s -> %s %s (painted %s, candidates %s, err %s)", verb, tostring(ok), tostring(reason),
        tostring(heat.painted), tostring(heat.candidates), tostring(heat.lastError))
end, false)
