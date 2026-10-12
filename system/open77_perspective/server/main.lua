-- Operator control of the third-person policy.
--
-- This resource is NOT the policy authority and must not behave like one. The
-- authority is whichever resource calls `Open77.perspective.setPolicy`, and on a
-- real server that is the gamemode: it is the thing that knows whether third
-- person suits its rules. A server with no gamemode, or a gamemode that never
-- calls it, leaves every client on the platform default `allowed`, which is the
-- intended behaviour and needs nothing from this file.
--
-- So nothing here runs at start. `/perspective` exists for the case an operator
-- wants to change the policy live, or to try one on a bare server -- and the
-- moment it is used, THIS resource becomes a second declaring authority. Two
-- authorities both answer a joining client and the last packet wins, so the
-- command says so rather than leaving it to be discovered.
--
-- Restricted: the dedicated server resolves the caller's identity through ACL
-- before the handler runs, exactly as `open77_debug` does for `client.exec`.

local USAGE = "usage: /perspective <disabled|allowed|default|forced> [fpp|tps]"

local suggestions = {
    {
        command = "/perspective",
        help = "Set the third-person policy for every connected player.",
        parameters = {
            { name = "policy", help = "disabled, allowed, default or forced." },
            { name = "perspective", help = "fpp or tps. Required for 'forced', the default for 'default'." },
        }
    },
}

RegisterNetEvent("chat:ready", function()
    TriggerClientEvent("chat:addSuggestions", source, suggestions)
end)

local function reply(player, raw, accepted, text)
    print(("perspective source=%s accepted=%s %s"):format(
        tostring(player), tostring(accepted == true), tostring(text)))
    if player ~= nil and player > 0 then
        TriggerClientEvent("open77:command:result", player, raw or "", accepted == true,
            tostring(text))
    end
end

RegisterCommand("perspective", function(player, args, raw)
    local current, pinned, declared = Open77.perspective.policy()
    if args[1] == nil then
        return reply(player, raw, true, ("policy=%s perspective=%s declaredHere=%s -- %s"):format(
            current, pinned, tostring(declared), USAGE))
    end

    local policy = tostring(args[1]):lower()
    local perspective = args[2] ~= nil and tostring(args[2]):lower() or nil

    local ok, reason = Open77.perspective.setPolicy(policy, perspective)
    if not ok then
        return reply(player, raw, false, tostring(reason) .. " -- " .. USAGE)
    end

    local note = declared and ""
        or " (open77_perspective is now a policy authority; if a gamemode also sets one," ..
           " the last write wins)"
    reply(player, raw, true, ("policy=%s perspective=%s%s"):format(
        policy, perspective or pinned, note))
end, true)
