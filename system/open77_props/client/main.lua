-- Projection client for the server-authoritative world prop registry.
--
-- The server owns every prop; this resource only mirrors the registry into the
-- native projection layer and acknowledges the result. Nothing here runs on a
-- tick: a prop is projected once, when its record arrives, and never polled.

-- A connected client can receive a newer resource generation before its native
-- plugin has been restarted. Stay inert on that transition instead of failing
-- the VM or exposing a partially active projection layer.
if type(Open77.props) ~= "table"
    or type(Open77.props.project) ~= "function"
    or type(Open77.props.unproject) ~= "function" then
    print("[open77_props] native prop API unavailable; restart Cyberpunk to activate it")
    return
end

-- serverId -> last received record.
--
-- There is no handle map: the native projection layer is itself keyed by the
-- server's id, which is what lets an upsert mutate the live entity instead of
-- destroying and rebuilding it. Keeping a second identity here would only
-- reintroduce the mapping the native side already owns.
local props = {}

RegisterNetEvent("open77:command:result", function(raw, accepted, message)
    if type(raw) ~= "string" or string.match(string.lower(raw), "^prop") == nil then return end
    print(string.format(
        "[server command] %s%s%s",
        accepted and "OK" or "ERR",
        raw ~= "" and (" " .. raw) or "",
        type(message) == "string" and message ~= "" and (": " .. message) or ""))
end)

-- Server records may carry a nested position or the flattened x/y/z the
-- registry uses on the wire; accept both rather than trusting one shape.
local function positionOf(record)
    if type(record.position) == "table" then return record.position end
    return { x = record.x, y = record.y, z = record.z }
end

-- Only the fields the native layer draws are forwarded. Routing and lifetime
-- fields (bucket, ttlMs, persistent) are server bookkeeping and stay there.
local function definitionOf(record)
    return {
        model = record.model,
        position = positionOf(record),
        yaw = record.yaw,
        scale = record.scale,
        appearance = record.appearance,
        physics = record.physics,
        collision = record.collision,
        visible = record.visible,
        attachment = record.attachment or false,
        kind = record.kind,
        light = record.light,
        streamingRadius = record.streamingRadius,
        streamingHysteresis = record.streamingHysteresis,
    }
end

--- Reports a projection FAILURE. Successes are deliberately silent.
---
--- This used to answer every projection, success included, and that burst is
--- enough to get the client disconnected. The server rate-limits inbound net
--- events to 32 per second per session and drops the connection past it
--- (SessionManager.cs, "network_event_rate_limit"). A gamemode that seeds a
--- couple of hundred props -- Cordon puts a lootable crate under every ground
--- drop, 88 of them in one match -- therefore hands a joining client 88 acks to
--- send in one tick, and the client is kicked while doing exactly what it was
--- told to do. Measured 2026-09-02: the owner was disconnected on join, twice,
--- with the game still running and nothing crashed.
---
--- Nothing ever read the successes. Both consumers discard them at their first
--- line: the bundled server resource does `if ok then return end`, and
--- ServerApplication.LogProjectionResult returns unless the payload's second
--- element is literally `false`. So this is not a throttle or a sampling
--- compromise -- the quiet path was always dead weight, and a failure, which is
--- rare and genuinely useful, still reports immediately and individually.
local function acknowledge(id, ok, reason)
    if ok == true then return end
    TriggerServerEvent("open77:props:projected", id, false, reason)
end

-- Drops the native object without notifying the server or other resources.
local function unproject(id)
    if props[id] == nil then return false end
    Open77.props.unproject(id)
    return true
end

local function forget(id, reason)
    local existed = unproject(id)
    props[id] = nil
    if existed then TriggerEvent("open77:props:removed", id, reason) end
end

local function upsert(record)
    if type(record) ~= "table" then return false end
    local id = tonumber(record.id)
    if id == nil then return false end

    -- An upsert, not a rebuild. The native layer is keyed by the server id, so
    -- a prop that only moved is transformed in place and never pops; only a
    -- change the render proxy reads at build time costs a respawn.
    local existed = props[id] ~= nil
    local definition = definitionOf(record)
    local ok, reason = Open77.props.project(id, definition)
    -- Optional presentation fields were introduced in successive client builds.
    -- Preserve the binding on older clients, dropping the newest field first.
    for _, optional in ipairs({ "contact", "firstPerson" }) do
        if not ok and reason == "invalid_attachment" and type(definition.attachment) == "table"
            and definition.attachment[optional] ~= nil then
            local stripped = {}
            for key, value in pairs(definition.attachment) do
                if key ~= optional then stripped[key] = value end
            end
            definition.attachment = stripped
            ok, reason = Open77.props.project(id, definition)
        end
    end
    if not ok then
        props[id] = nil
        print(string.format("[open77_props] prop %d rejected: %s", id, tostring(reason)))
        acknowledge(id, false, reason)
        if existed then TriggerEvent("open77:props:removed", id, "projection_failed") end
        return false
    end

    props[id] = record
    acknowledge(id, true, nil)
    if not existed then TriggerEvent("open77:props:added", id, record) end
    return true
end

RegisterNetEvent("open77:props:snapshot", function(snapshot)
    if type(snapshot) ~= "table" then snapshot = {} end

    local incoming = {}
    for _, record in ipairs(snapshot) do
        local id = type(record) == "table" and tonumber(record.id) or nil
        if id ~= nil then incoming[id] = true end
    end

    -- Retire what the snapshot no longer carries before projecting the rest, so
    -- other resources never see a stale prop and its replacement at once.
    local stale = {}
    for id in pairs(props) do
        if not incoming[id] then stale[#stale + 1] = id end
    end
    for _, id in ipairs(stale) do forget(id, "snapshot") end

    for _, record in ipairs(snapshot) do upsert(record) end
end)

RegisterNetEvent("open77:props:upsert", upsert)

RegisterNetEvent("open77:props:remove", function(id, reason)
    id = tonumber(id)
    if id == nil then return end
    forget(id, reason or "removed")
end)

local function clearAll(reason)
    local ids = {}
    for id in pairs(props) do ids[#ids + 1] = id end
    for _, id in ipairs(ids) do forget(id, reason) end
    props = {}
    -- Belt and braces: `forget` unprojects each id individually, but a native
    -- entry orphaned by a mismatch would otherwise survive a resource restart.
    Open77.props.unprojectAll()
end

AddEventHandler("onClientResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    clearAll("restart")
    TriggerServerEvent("open77:props:ready")
end)

AddEventHandler("onClientResourceStop", function(name)
    if name ~= GetCurrentResourceName() then return end
    clearAll("stopped")
end)

-- Read-only surface for gameplay resources. Creation and mutation deliberately
-- exist only on the dedicated-server Open77.props API.
exports("get", function(id) return props[tonumber(id)] end)
exports("all", function()
    local result = {}
    for _, record in pairs(props) do result[#result + 1] = record end
    table.sort(result, function(a, b) return tonumber(a.id) < tonumber(b.id) end)
    return result
end)
-- No `handle` export: the projection layer is keyed by the server id, so the
-- server id IS the handle and a second identity would only be a way to get
-- them out of step.
--
-- No `list` export either. `Open77.props.list()` is scoped to the calling
-- resource's own local props, and projected props are owned by the session, so
-- calling it here would return an empty table and read as "no props" rather
-- than "wrong question". `all()` above is the answer, and it is exact.

print("world prop projection ready")
