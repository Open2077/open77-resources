-- open77_braindance server: the braindance editor layers on a player's screen.
--
-- Exports (server):
--   setLayer(playerId, layer, options?)    layer = "off" | "visual" | "thermal" | "audio"
--   setHeat(playerId, target, level)       target = { playerId } | { npcId } (as that client sees it)
--   clearHeat(playerId)
--   layer(playerId) -> last layer the client reported, or "off"
--
-- Server event (AddEventHandler):
--   open77_braindance:layerChanged (playerId, layer, previous, reason?)

local LAYERS = { off = true, visual = true, thermal = true, audio = true }
local LEVELS = { auto = true, none = true, off = true, cool = true, cold = true, warm = true, hot = true, clue = true }
local layers = {} -- playerId -> reported layer
local budget = {}

local function pidOf(value)
    local n = tonumber(value)
    if n == nil or n < 1 or n ~= math.floor(n) then return nil end
    return n
end

-- Only plain data crosses: numbers, booleans, short strings, nested tables.
local function plain(value, depth)
    local kind = type(value)
    if kind == "number" then return value == value and value or nil end
    if kind == "boolean" then return value end
    if kind == "string" then return #value <= 64 and value or nil end
    if kind ~= "table" or depth > 3 then return nil end
    local out, n = {}, 0
    for k, v in pairs(value) do
        n = n + 1
        if n > 32 then return nil end
        if type(k) ~= "string" and type(k) ~= "number" then return nil end
        local copy = plain(v, depth + 1)
        if copy == nil then return nil end
        out[k] = copy
    end
    return out
end

exports("setLayer", function(pid, layer, options)
    pid = pidOf(pid)
    if not pid then return false, "invalid_player" end
    if type(layer) ~= "string" or not LAYERS[layer] then return false, "invalid_layer" end
    local sent = nil
    if options ~= nil then
        sent = plain(options, 0)
        if type(sent) ~= "table" then return false, "invalid_options" end
    end
    TriggerClientEvent("open77_braindance:setLayer", pid, layer, sent)
    return true
end)

exports("setHeat", function(pid, target, level)
    pid = pidOf(pid)
    if not pid then return false, "invalid_player" end
    if type(target) ~= "table" or (target.playerId == nil and target.npcId == nil) then return false, "invalid_target" end
    if type(level) ~= "string" or not LEVELS[level] then return false, "invalid_level" end
    TriggerClientEvent("open77_braindance:setHeat", pid, { playerId = target.playerId, npcId = target.npcId }, level)
    return true
end)

exports("clearHeat", function(pid)
    pid = pidOf(pid)
    if not pid then return false, "invalid_player" end
    TriggerClientEvent("open77_braindance:clearHeat", pid)
    return true
end)

exports("layer", function(pid)
    return layers[pidOf(pid) or 0] or "off"
end)

RegisterNetEvent("open77_braindance:layerReport", function(layer, previous, reason)
    local pid = pidOf(source)
    if not pid or not LAYERS[layer] or not LAYERS[previous] then return end
    local now = GetGameTimer()
    local b = budget[pid]
    if not b or now - b.since > 10000 then b = { since = now, count = 0 } budget[pid] = b end
    b.count = b.count + 1
    if b.count > 40 then return end
    layers[pid] = layer
    TriggerEvent("open77_braindance:layerChanged", pid, layer, previous,
        type(reason) == "string" and reason:sub(1, 64) or nil)
end)

AddEventHandler("playerDropped", function()
    local pid = pidOf(source)
    if pid then layers[pid] = nil budget[pid] = nil end
end)

-- Console: bdlayer <playerId> <off|visual|thermal|audio> | bdlayer <playerId> heat <targetPid> <level>
RegisterCommand("bdlayer", function(_, args)
    local pid, verb = tonumber(args[1]), args[2]
    if not pid or not verb then return print("[open77_braindance] usage: bdlayer <playerId> <layer|heat <targetPid> <level>>") end
    if verb == "heat" then
        TriggerClientEvent("open77_braindance:setHeat", pid, { playerId = tonumber(args[3]) }, args[4] or "hot")
        return print(("[open77_braindance] heat %s=%s for %d"):format(tostring(args[3]), tostring(args[4]), pid))
    end
    if not LAYERS[verb] then return print("[open77_braindance] unknown layer " .. verb) end
    TriggerClientEvent("open77_braindance:setLayer", pid, verb, nil)
    print(("[open77_braindance] layer %s for %d"):format(verb, pid))
end, true)
