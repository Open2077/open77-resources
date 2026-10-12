-- Server-authorized client Lua laboratory.
--
-- `client.exec` is restricted, so the dedicated server resolves the caller's
-- authenticated identity through ACL before this handler ever runs. Code is
-- sent to one explicit session id and executes only inside the bundled local
-- open77_debug VM; downloaded server resources do not receive Open77.debug.

local EVENT_EXEC = "open77:debug:exec"
local EVENT_RESULT = "open77:debug:result"
local MAX_SOURCE_BYTES = 32 * 1024
local MAX_RESULT_BYTES = 8 * 1024
local REQUEST_TIMEOUT_MS = 10000
local nextRequest = 1
local pending = {}

local suggestions = {
    {
        command = "/client.exec",
        help = "Run bounded Lua in one player's privileged Open77 debug VM.",
        parameters = {
            { name = "playerId", help = "Target session ID." },
            { name = "lua", help = "Lua source, for example: return Open77.debug.command('vehicle.list')" }
        }
    },
    {
        command = "/hud",
        help = "Show, hide or toggle one vanilla HUD component (or all).",
        parameters = {
            { name = "component", help = "minimap, compass, clock, health, stamina, weapon, speedometer, questTracker, phone, scanner, vanillaNotifications, crosshair, hubMenu, all or state" },
            { name = "action", help = "show, hide or toggle" }
        }
    },
    {
        command = "/hudtest",
        help = "Show, hide or toggle every vanilla HUD component at once.",
        parameters = {
            { name = "action", help = "show, hide or toggle (default: toggle)" }
        }
    },
}

local function output(player, raw, accepted, text)
    text = tostring(text or "")
    if #text > MAX_RESULT_BYTES then text = text:sub(1, MAX_RESULT_BYTES) end
    print(string.format("client.exec source=%s accepted=%s %s",
        tostring(player), tostring(accepted == true), text))
    if player ~= nil and player > 0 then
        TriggerClientEvent("open77:command:result", player, raw or "", accepted == true, text)
    end
end

local function joinSource(args)
    local parts = {}
    for index = 2, args.n or #args do parts[#parts + 1] = tostring(args[index] or "") end
    return table.concat(parts, " ")
end

RegisterNetEvent("chat:ready", function()
    TriggerClientEvent("chat:addSuggestions", source, suggestions)
end)

RegisterCommand("client.exec", function(player, args, raw)
    if player == nil or player <= 0 then
        return output(player, raw, false, "client.exec must be issued by an authenticated in-game admin")
    end
    local target = tonumber(args[1])
    local code = joinSource(args)
    if target == nil or target <= 0 or target % 1 ~= 0 then
        return output(player, raw, false, "usage: client.exec <playerId> <lua>")
    end
    if code == "" or #code > MAX_SOURCE_BYTES then
        return output(player, raw, false, "invalid Lua source size (1..32768 bytes)")
    end

    local requestId = string.format("%d:%d:%d", player, target, nextRequest)
    nextRequest = nextRequest + 1
    pending[requestId] = { issuer = player, target = target, raw = raw }
    local sent, reason = TriggerClientEvent(EVENT_EXEC, target, requestId, code)
    if sent == false then
        pending[requestId] = nil
        return output(player, raw, false, "dispatch failed: " .. tostring(reason))
    end
    output(player, raw, true, "queued request=" .. requestId .. " target=" .. tostring(target))
    SetTimeout(REQUEST_TIMEOUT_MS, function()
        local request = pending[requestId]
        if request == nil then return end
        pending[requestId] = nil
        output(request.issuer, request.raw, false,
            "timeout request=" .. requestId .. " target=" .. tostring(request.target))
    end)
end, true)

-- /pos and /rot are public utilities in open77_admin, not debug commands.

-- Every public component, in Open77.hud.components() order. One list so the
-- console cannot drift from the client vocabulary.
local ALL_HUD_COMPONENTS = [[{"minimap","compass","clock","health","stamina","weapon",]] ..
    [["speedometer","questTracker","phone","scanner","vanillaNotifications",]] ..
    [["crosshair","hubMenu"}]]

local function requestHud(player, raw, component, action)
    if player == nil or player <= 0 then
        return output(player, raw, false, "HUD commands are only available to an in-game admin")
    end

    component = string.lower(tostring(component or ""))
    action = string.lower(tostring(action or ""))
    local componentSource = {
        minimap = [[{"minimap"}]],
        compass = [[{"compass"}]],
        clock = [[{"clock"}]],
        health = [[{"health"}]],
        stamina = [[{"stamina"}]],
        weapon = [[{"weapon"}]],
        speedometer = [[{"speedometer"}]],
        questtracker = [[{"questTracker"}]],
        phone = [[{"phone"}]],
        scanner = [[{"scanner"}]],
        vanillanotifications = [[{"vanillaNotifications"}]],
        crosshair = [[{"crosshair"}]],
        hubmenu = [[{"hubMenu"}]],
        -- "all" is a real selector on the client side, but this console command
        -- also has to report per-component state, so it keeps listing them.
        all = ALL_HUD_COMPONENTS,
        state = ALL_HUD_COMPONENTS,
    }
    if component == "state" then
        action = "state"
    elseif component == "" then
        return output(player, raw, false,
            "usage: hud <minimap|compass|clock|health|stamina|weapon|questTracker|phone|" ..
            "scanner|vanillaNotifications|crosshair|hubMenu|speedometer|all|state> <show|hide|toggle>")
    elseif action ~= "show" and action ~= "hide" and action ~= "toggle" then
        return output(player, raw, false, "HUD action must be show, hide or toggle")
    end
    if componentSource[component] == nil then
        return output(player, raw, false, "unknown HUD component: " .. component)
    end

    local requestId = string.format("hud:%d:%d", player, nextRequest)
    nextRequest = nextRequest + 1
    pending[requestId] = { issuer = player, target = player, raw = raw }
    local code = string.format([[
local components=%s
local action=%q
local parts={}
for index=1,#components do
    local name=components[index]
    local current,reason=Open77.hud.isVisible(name)
    if current==nil then return "HUD read failed: "..name..": "..tostring(reason) end
    local effective=current
    if action~="state" then
        local visible=action=="show" or (action=="toggle" and not current)
        local accepted,result=Open77.hud.setVisible(name,visible)
        if accepted~=true then return "HUD update failed: "..name..": "..tostring(result) end
        effective=result==true
    end
    parts[#parts+1]=name.."="..(effective and "shown" or "hidden")
end
return table.concat(parts,", ")]], componentSource[component], action)
    local sent, reason = TriggerClientEvent(EVENT_EXEC, player, requestId, code)
    if sent == false then
        pending[requestId] = nil
        return output(player, raw, false, "HUD dispatch failed: " .. tostring(reason))
    end
    output(player, raw, true, "queued HUD request=" .. requestId)
    SetTimeout(REQUEST_TIMEOUT_MS, function()
        local request = pending[requestId]
        if request == nil then return end
        pending[requestId] = nil
        output(request.issuer, request.raw, false, "HUD request timed out")
    end)
end

RegisterCommand("hud", function(player, args, raw)
    requestHud(player, raw, args[1], args[2])
end, true)

RegisterCommand("hudtest", function(player, args, raw)
    requestHud(player, raw, "all", args[1] or "toggle")
end, true)

RegisterNetEvent(EVENT_RESULT, function(requestId, accepted, result)
    requestId = tostring(requestId or "")
    local request = pending[requestId]
    if request == nil or source ~= request.target then return end
    pending[requestId] = nil
    output(request.issuer, request.raw, accepted == true,
        string.format("result request=%s target=%d: %s",
            requestId, request.target, tostring(result or "")))
end)

print("privileged debug runtime ready; restricted commands: client.exec <playerId> <lua>, hud, hudtest")
