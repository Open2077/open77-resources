-- open77_containers -- client half.
--
-- The prompts are declared by the server (open77_interactions `define`), so the
-- choice event fires here, in every client resource. This half forwards the
-- minimum intent -- which prompt, which prop, which choice -- and nothing else:
-- the server maps the prop or zone back to a container and re-derives the
-- player's bucket and distance from its own snapshot before telling the
-- container's owner (`open77_containers:used`).

AddEventHandler("open77_containers:prompt", function(payload)
    if type(payload) ~= "table" or payload.owner ~= GetCurrentResourceName() then return end
    local targetId = type(payload.targetId) == "string" and payload.targetId or nil
    local propId = type(payload.propId) == "string" and payload.propId or nil
    local choiceId = type(payload.choiceId) == "string" and payload.choiceId or nil
    if not choiceId or (not targetId and not propId) then return end
    TriggerServerEvent("open77_containers:use", targetId, propId, choiceId)
end)

-- The public summary the server mirrors on a container's prop, for HUDs and
-- other presentation. It is a mirror: anything that decides must ask the
-- server (`exports.open77_containers:summary(id)` there).
exports("summary", function(propId)
    if type(propId) ~= "string" and math.type(propId) ~= "integer" then return nil end
    if type(Open77.state) ~= "table" or type(Open77.state.entity) ~= "function" then return nil end
    local ok, bag = pcall(Open77.state.entity, "prop", tostring(propId))
    if not ok or type(bag) ~= "table" then return nil end
    local okGet, value = pcall(bag.get, bag, "open77.container")
    if not okGet or type(value) ~= "table" then return nil end
    return value
end)
