-- Rebindable requests only. Inventory, duration, interruption and completion
-- belong to the server; pressing a key never starts an optimistic progress bar.
local state, keys = nil, {}
local pendingUntil = 0
-- F7 is the native perspective switch; F6 is the loaded perspective resource.
-- END has no vanilla mapping or native/Lua action in the shipped Cordon stack.
local actions = {
    plate = { id = "cordon.plate", name = "Cordon - Apply armor plate", key = "END", count = "plates" },
    heal = { id = "cordon.heal", name = "Cordon - Use healing item", key = "F8", count = "heals" },
}
local function now() return Open77.time.monotonic() * 1000 end
local function publishKeys() TriggerEvent("cordon:consumables:keys", { plate = keys.plate, heal = keys.heal }) end
local function request(kind)
    local action = actions[kind]
    local self_ = state and type(state.self) == "table" and state.self or nil
    if not action or not self_ or state.participant ~= true or self_.state ~= "alive" or self_.alive ~= true then return end
    if state.phase ~= "live" and state.phase ~= "extraction" then return end
    if self_.use ~= nil or self_.revive ~= nil or now() < pendingUntil then return end
    if (tonumber(self_[action.count]) or 0) <= 0 then return end
    pendingUntil = now() + 750
    TriggerServerEvent("cordon:use", kind)
end
AddEventHandler("cordon:state:local", function(payload)
    if type(payload) ~= "table" then return end
    if not state or state.matchId ~= payload.matchId then pendingUntil = 0 end
    state = payload
end)
AddEventHandler("cordon:consumables:requestKeys", publishKeys)
AddEventHandler("open77:keybinds:changed", function()
    if Open77.input and type(Open77.input.keyFor) == "function" then
        for kind, action in pairs(actions) do
            local ok, key = pcall(Open77.input.keyFor, action.id)
            keys[kind] = ok and type(key) == "string" and #key > 0 and key or nil
        end
    end
    publishKeys()
end)
for kind, action in pairs(actions) do
    local itemKind = kind
    if type(RegisterKeyMapping) == "function" then
        local ok, effective = RegisterKeyMapping({ id = action.id, name = action.name, key = action.key,
            onPressed = function() request(itemKind) end })
        if ok then keys[kind] = effective
        else Open77.log.warn("cordon consumable key refused: " .. action.id .. " (" .. tostring(effective) .. ")") end
    end
end
publishKeys()
