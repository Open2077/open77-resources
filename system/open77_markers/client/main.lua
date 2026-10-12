local showcase = {}

local function clearShowcase()
    for _, id in ipairs(showcase) do Open77.markers.remove(id) end
    showcase = {}
end

local function create(options)
    return Open77.markers.create(options)
end

exports("create", create)
exports("update", function(id, patch) return Open77.markers.update(id, patch) end)
exports("remove", function(id) return Open77.markers.remove(id) end)
exports("clear", function() return Open77.markers.clear() end)
exports("list", function() return Open77.markers.list() end)
exports("get", function(id) return Open77.markers.get(id) end)
exports("shapes", function() return Open77.markers.shapes() end)

-- Development-only visual sampler. It is dormant until the local debug bridge
-- emits `open77:markers:showcase`; normal players never receive test markers.
AddEventHandler("open77:markers:showcase", function()
    clearShowcase()
    local state, reason = Open77.character.state()
    if not state then
        Open77.log.error("marker showcase: " .. tostring(reason))
        return
    end
    local x, y, z = state.position.x, state.position.y, state.position.z
    local samples = {
        { x = x + 3.0, y = y,       z = z, style = "interaction", shape = "ring" },
        { x = x + 7.0, y = y,       z = z, style = "objective",   shape = "cylinder" },
        { x = x + 3.0, y = y + 4.0, z = z, style = "spawn",       shape = "ring" },
        { x = x + 7.0, y = y + 4.0, z = z, style = "danger",      shape = "cylinder" },
    }
    for _, sample in ipairs(samples) do
        local id, error = create({
            position = { x = sample.x, y = sample.y, z = sample.z },
            shape = sample.shape,
            style = sample.style,
            radius = 1.0,
            maxDistance = 80.0,
        })
        if id then table.insert(showcase, id)
        else Open77.log.error("marker showcase: " .. tostring(error)) end
    end
    Open77.log.info(("marker showcase: %d world primitives created"):format(#showcase))
end)

AddEventHandler("open77:markers:clear", clearShowcase)
