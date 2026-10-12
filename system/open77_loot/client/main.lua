-- Projection client for the server-authoritative loot registry.
-- Physical REDengine objects are visuals only; their vanilla interactions are
-- disabled by the script bridge and pickup always returns to the server.

-- A connected client can receive a newer resource generation before its native
-- plugin has been restarted. Stay inert on that transition instead of failing
-- the VM or exposing a partially active authority layer.
if type(Open77.loot) ~= "table" or type(Open77.loot.setAuthorityEnabled) ~= "function" then
    print("[open77_loot] native loot API unavailable; restart Cyberpunk to activate it")
    return
end

local drops = {}

RegisterNetEvent("open77:command:result", function(raw, accepted, message)
    if type(raw) ~= "string" or string.match(string.lower(raw), "^loot") == nil then return end
    print(string.format(
        "[server command] %s%s%s",
        accepted and "OK" or "ERR",
        type(raw) == "string" and raw ~= "" and (" " .. raw) or "",
        type(message) == "string" and message ~= "" and (": " .. message) or ""))
end)

local function upsert(drop)
    -- This early return used to be silent, and that hid a real failure for a
    -- whole session: a snapshot of eighty-four drops arrived, every one was
    -- discarded here, and nothing was printed -- so the drops looked as though
    -- they had never been sent. Say what was rejected and why.
    if type(drop) ~= "table" or not drop.id then
        print(string.format("[open77_loot] malformed drop discarded: type=%s id=%s",
            type(drop), tostring(type(drop) == "table" and drop.id or nil)))
        return false
    end
    drop.model = drop.visualItem or drop.model
    local ok, reason = Open77.loot.upsert(drop)
    if not ok then
        print(string.format("[open77_loot] drop %s rejected: %s", tostring(drop.id), tostring(reason)))
        return false
    end
    drops[drop.id] = drop
    return true
end

RegisterNetEvent("open77:loot:snapshot", function(snapshot)
    -- Diagnostic, 2026-09-02. The server logs sending eighty-four drops to this
    -- player and the client's table ends up empty, with no rejection printed.
    -- Say what actually arrives: whether the handler runs at all, what type the
    -- argument is, and how many entries `ipairs` can walk.
    local count = 0
    if type(snapshot) == "table" then for _ in ipairs(snapshot) do count = count + 1 end end
    print(string.format("[open77_loot] snapshot received: type=%s ipairs=%d",
        type(snapshot), count))
    Open77.loot.clear()
    drops = {}
    if type(snapshot) ~= "table" then return end
    local applied = 0
    for _, drop in ipairs(snapshot) do if upsert(drop) then applied = applied + 1 end end
    print(string.format("[open77_loot] snapshot applied %d of %d", applied, count))
end)

RegisterNetEvent("open77:loot:upsert", upsert)

RegisterNetEvent("open77:loot:remove", function(id)
    id = tonumber(id)
    if not id then return end
    Open77.loot.remove(id)
    drops[id] = nil
end)

RegisterNetEvent("open77:loot:pickupResult", function(id, accepted, reason, item, quantity)
    id = tonumber(id)
    if accepted and id and type(item) == "string" then
        local ok, grantReason = Open77.loot.acceptPickup(id, item, tonumber(quantity) or 1)
        if not ok then
            print(string.format("[open77_loot] local grant %s failed: %s", tostring(id), tostring(grantReason)))
        end
    elseif id then
        print(string.format("[open77_loot] pickup %s denied: %s", tostring(id), tostring(reason)))
    end
    -- Keep the local gameplay notification distinct from the reserved network
    -- event; re-emitting the same name would invoke this handler recursively.
    TriggerEvent("open77:loot:result", id, accepted == true, reason, item, quantity)
end)

AddEventHandler("onClientResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    local ok, reason = Open77.loot.setAuthorityEnabled(true)
    if not ok then
        print("[open77_loot] authority unavailable: " .. tostring(reason))
        return
    end
    TriggerServerEvent("open77:loot:ready")
end)

AddEventHandler("onClientResourceStop", function(name)
    if name ~= GetCurrentResourceName() then return end
    Open77.loot.clear()
    Open77.loot.setAuthorityEnabled(false)
    drops = {}
end)

-- Read/request API for gameplay resources. Creation and mutation deliberately
-- exist only on the dedicated-server Open77.loot API.
exports("get", function(id) return drops[tonumber(id)] end)
exports("all", function()
    local result = {}
    for _, drop in pairs(drops) do result[#result + 1] = drop end
    table.sort(result, function(a, b) return a.id < b.id end)
    return result
end)
exports("requestPickup", function(id) return Open77.loot.requestPickup(tonumber(id)) end)
