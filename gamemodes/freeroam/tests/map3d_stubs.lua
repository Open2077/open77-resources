-- Client globals client/map3d.lua needs at load time (loaded before it by
-- FreeroamMap3DLuaTests). map3d_test.lua drives them.
Map3DTest = {
    handlers = {},
    state = "missing",
    calls = {},
    printed = {},
}
local T = Map3DTest

function AddEventHandler(name, fn)
    T.handlers[name] = T.handlers[name] or {}
    table.insert(T.handlers[name], fn)
end
function T.fire(name, ...)
    for _, fn in ipairs(T.handlers[name] or {}) do fn(...) end
end
function GetCurrentResourceName() return "freeroam" end
function GetResourceState(name)
    assert(name == "op77_map3d", "only the map is asked about")
    return T.state
end
function print(text) table.insert(T.printed, text) end

-- exports.op77_map3d:method(...) as the runtime exposes it.
local map = {}
setmetatable(map, { __index = function(_, method)
    return function(self, ...)
        assert(self == map, method .. " called without the export table")
        table.insert(T.calls, { method = method, args = { ... } })
        if T.fail then error("export failed") end
        if method == "addBlip" then return "freeroam:" .. tostring((...).id) end
        return true
    end
end })
exports = setmetatable({}, { __index = function(_, name)
    assert(name == "op77_map3d", "unexpected export " .. tostring(name))
    return map
end })
