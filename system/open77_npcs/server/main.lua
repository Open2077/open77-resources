-- Reference resource for the canonical server-owned NPC API.
local TEMPLATE = "civilian_female_relaxed_01"

local function number(value)
    local parsed = tonumber(value)
    if parsed == nil then error("number expected: " .. tostring(value), 0) end
    return parsed
end

local function integer(value)
    local parsed = number(value)
    if parsed % 1 ~= 0 then error("integer expected: " .. tostring(value), 0) end
    return parsed
end

local function output(source, raw, success, text)
    print(text)
    if source and source > 0 then
        TriggerClientEvent("open77:command:result", source, raw or "", success == true, text)
    end
end

local suggestions = {
    { command = "/npc.create", help = "Create a server-owned NPC beside a player.", parameters = {
        { name = "playerId" }, { name = "Character.record|legacyAlias", optional = true }
    } },
    { command = "/npc.list", help = "List canonical NPCs.", parameters = {{ name = "bucket", optional = true }} },
    { command = "/npc.move", help = "Queue a native move command.", parameters = {
        { name = "npcId" }, { name = "x" }, { name = "y" }, { name = "z" }, { name = "walk|run|sprint", optional = true }
    } },
    { command = "/npc.face", help = "Rotate an NPC toward a point.", parameters = {
        { name = "npcId" }, { name = "x" }, { name = "y" }, { name = "z" }
    } },
    { command = "/npc.look", help = "Make an NPC look at a point.", parameters = {
        { name = "npcId" }, { name = "x" }, { name = "y" }, { name = "z" }
    } },
    { command = "/npc.wait", help = "Queue a server-timed wait.", parameters = {{ name = "npcId" }, { name = "milliseconds" }} },
    { command = "/npc.cancel", help = "Cancel an NPC task.", parameters = {{ name = "npcId" }, { name = "taskId" }} },
    { command = "/npc.remove", help = "Remove an NPC owned by this resource.", parameters = {{ name = "npcId" }} },
    { command = "/npc.follow", help = "Follow a streamed player.", parameters = {
        { name = "npcId" }, { name = "playerId" }, { name = "walk|run|sprint", optional = true }
    } },
    { command = "/npc.patrol", help = "Patrol around the issuing player.", parameters = {{ name = "npcId" }} },
    { command = "/npc.wander", help = "Wander around the NPC spawn area.", parameters = {
        { name = "npcId" }, { name = "radius", optional = true }
    } },
    { command = "/npc.damage", help = "Apply authoritative scripted damage.", parameters = {
        { name = "npcId" }, { name = "amount" }
    } },
    { command = "/npc.hold", help = "Hold the current position.", parameters = {
        { name = "npcId" }, { name = "milliseconds", optional = true }
    } },
    { command = "/npc.anim", help = "Play a reviewed full-body animation.", parameters = {
        { name = "npcId" }, { name = "animation" }, { name = "timeoutMs", optional = true }
    } },
    { command = "/npc.freeze", help = "Freeze or resume every NPC task channel.", parameters = {
        { name = "npcId" }, { name = "on|off" }
    } },
    { command = "/npc.revive", help = "Revive a dead NPC.", parameters = {
        { name = "npcId" }, { name = "health", optional = true }
    } },
    { command = "/npc.diag", help = "Report authority, lease and every task of an NPC.",
        parameters = {{ name = "npcId" }} },
}

RegisterNetEvent("chat:ready", function() TriggerClientEvent("chat:addSuggestions", source, suggestions) end)

RegisterCommand("npc.create", function(source, args, raw)
    if args.n < 1 or args.n > 2 then return output(source, raw, false, "usage: npc.create <playerId> [Character.record|legacyAlias]") end
    local playerId = integer(args[1])
    local player = Open77.players.position(playerId)
    if player == nil then return output(source, raw, false, "player has no fresh position") end
    local id, reason = Open77.npcs.create({
        template = args[2] or TEMPLATE,
        position = { x = player.x + 2.0, y = player.y, z = player.z },
        yaw = 0, bucket = player.bucket, aiMode = Open77.npcs.ai.tasks,
        damagePolicy = Open77.npcs.damage.immortal,
    })
    output(source, raw, id ~= nil, id and string.format("npc %d created", id)
        or "npc create failed: " .. tostring(reason))
end, true)

RegisterCommand("npc.list", function(source, args, raw)
    if args.n > 1 then return output(source, raw, false, "usage: npc.list [bucket]") end
    local values = Open77.npcs.all(args[1] and integer(args[1]) or nil)
    output(source, raw, true, string.format("npcs (%d)", #values))
    for index, npc in ipairs(values) do
        if index > 100 then return output(source, raw, true, "... output limited to 100") end
        output(source, raw, true, string.format(
            "id=%d template=%s bucket=%d pos=%.2f,%.2f,%.2f health=%.1f/%.1f task=%d authority=%d epoch=%d",
            npc.id, npc.template, npc.bucket, npc.x, npc.y, npc.z, npc.health,
            npc.maxHealth, npc.currentTaskId, npc.authorityPlayerId, npc.authorityEpoch))
    end
end, false)

RegisterCommand("npc.move", function(source, args, raw)
    if args.n < 4 or args.n > 5 then return output(source, raw, false, "usage: npc.move <id> <x> <y> <z> [walk|run|sprint]") end
    local task = Open77.npcs.tasks.moveTo(integer(args[1]),
        { x = number(args[2]), y = number(args[3]), z = number(args[4]) },
        { speed = args[5] or "walk", timeoutMs = 30000 })
    output(source, raw, task ~= nil, task and string.format("task %d queued", task) or "task rejected")
end, true)

local function pointTask(name, enqueue)
    RegisterCommand(name, function(source, args, raw)
        if args.n ~= 4 then return output(source, raw, false, "usage: " .. name .. " <id> <x> <y> <z>") end
        local task = enqueue(integer(args[1]),
            { x = number(args[2]), y = number(args[3]), z = number(args[4]) })
        output(source, raw, task ~= nil, task and string.format("task %d queued", task) or "task rejected")
    end, true)
end
pointTask("npc.face", Open77.npcs.tasks.face)
pointTask("npc.look", Open77.npcs.tasks.lookAt)

RegisterCommand("npc.wait", function(source, args, raw)
    if args.n ~= 2 then return output(source, raw, false, "usage: npc.wait <id> <milliseconds>") end
    local task = Open77.npcs.tasks.wait(integer(args[1]), integer(args[2]))
    output(source, raw, task ~= nil, task and string.format("task %d queued", task) or "task rejected")
end, true)

RegisterCommand("npc.cancel", function(source, args, raw)
    if args.n ~= 2 then return output(source, raw, false, "usage: npc.cancel <id> <taskId>") end
    local ok = Open77.npcs.tasks.cancel(integer(args[1]), integer(args[2]), "operator_cancel")
    output(source, raw, ok, ok and "task cancelled" or "task not found or not owned")
end, true)

RegisterCommand("npc.remove", function(source, args, raw)
    if args.n ~= 1 then return output(source, raw, false, "usage: npc.remove <id>") end
    local id = integer(args[1]); local ok = Open77.npcs.remove(id)
    output(source, raw, ok, ok and string.format("npc %d removed", id) or "npc not found or not owned")
end, true)

RegisterCommand("npc.follow", function(source, args, raw)
    if args.n < 2 or args.n > 3 then return output(source, raw, false, "usage: npc.follow <npcId> <playerId> [walk|run|sprint]") end
    local id, playerId = integer(args[1]), integer(args[2])
    local task = Open77.npcs.tasks.follow(id, { type = "player", id = playerId }, { speed = args[3] or "walk" })
    output(source, raw, task ~= nil, task and string.format("npc %d follows player %d task=%d", id, playerId, task) or "follow failed")
end, true)

RegisterCommand("npc.patrol", function(source, args, raw)
    if args.n ~= 1 then return output(source, raw, false, "usage: npc.patrol <npcId>") end
    local id = integer(args[1])
    local player = Open77.players.position(source)
    if player == nil then return output(source, raw, false, "player has no fresh position") end
    local task = Open77.npcs.tasks.patrol(id, {
        { x = player.x + 3.0, y = player.y, z = player.z, waitMs = 750 },
        { x = player.x, y = player.y + 3.0, z = player.z, waitMs = 750 },
        { x = player.x - 3.0, y = player.y, z = player.z, waitMs = 750 },
    }, { loop = true, speed = "walk" })
    output(source, raw, task ~= nil, task and string.format("npc %d patrol task=%d", id, task) or "patrol failed")
end, true)

RegisterCommand("npc.wander", function(source, args, raw)
    if args.n < 1 or args.n > 2 then return output(source, raw, false, "usage: npc.wander <npcId> [radius]") end
    local id = integer(args[1])
    local npc = Open77.npcs.get(id)
    if npc == nil then return output(source, raw, false, "npc not found or not owned") end
    local task = Open77.npcs.tasks.wander(id, {
        x = npc.x, y = npc.y, z = npc.z, radius = tonumber(args[2]) or 12.0, speed = "walk", seed = id,
    })
    output(source, raw, task ~= nil, task and string.format("npc %d wander task=%d", id, task) or "wander failed")
end, true)

RegisterCommand("npc.damage", function(source, args, raw)
    if args.n ~= 2 then return output(source, raw, false, "usage: npc.damage <npcId> <amount>") end
    local id, amount = integer(args[1]), tonumber(args[2])
    local ok = amount ~= nil and Open77.npcs.applyDamage(id, amount, "command:" .. tostring(source), "debug")
    output(source, raw, ok, ok and string.format("npc %d damaged by %.1f", id, amount) or "damage rejected")
end, true)

RegisterCommand("npc.hold", function(source, args, raw)
    if args.n < 1 or args.n > 2 then return output(source, raw, false, "usage: npc.hold <npcId> [milliseconds]") end
    local id = integer(args[1])
    local task = Open77.npcs.tasks.hold(id, { durationMs = args[2] and integer(args[2]) or nil })
    output(source, raw, task ~= nil, task and string.format("npc %d hold task=%d", id, task) or "hold failed")
end, true)

RegisterCommand("npc.anim", function(source, args, raw)
    if args.n < 2 or args.n > 3 then return output(source, raw, false, "usage: npc.anim <npcId> <animation> [timeoutMs]") end
    local id = integer(args[1])
    local task = Open77.npcs.tasks.playAnimation(id, args[2], {
        timeoutMs = args[3] and integer(args[3]) or 0,
    })
    output(source, raw, task ~= nil, task and string.format("npc %d animation task=%d", id, task)
        or "animation failed")
end, true)

RegisterCommand("npc.freeze", function(source, args, raw)
    if args.n ~= 2 or (args[2] ~= "on" and args[2] ~= "off") then
        return output(source, raw, false, "usage: npc.freeze <npcId> <on|off>")
    end
    local id = integer(args[1])
    local ok = Open77.npcs.setAiMode(id,
        args[2] == "on" and Open77.npcs.ai.frozen or Open77.npcs.ai.tasks)
    output(source, raw, ok, ok and string.format("npc %d freeze=%s", id, args[2])
        or "NPC not found or not owned")
end, true)

RegisterCommand("npc.revive", function(source, args, raw)
    if args.n < 1 or args.n > 2 then return output(source, raw, false, "usage: npc.revive <npcId> [health]") end
    local id = integer(args[1])
    local ok = Open77.npcs.revive(id, args[2] and number(args[2]) or 100)
    output(source, raw, ok, ok and string.format("npc %d revived", id) or "revive rejected")
end, true)

-- `npc.diag` is the answer to a failure mode that cost a full investigation:
-- every layer of the chain reported success -- the slash command, the task
-- queue, the wire -- while the NPC never moved, and none of that state was
-- reachable from the caller. A queued task that is `suspended` (no authority
-- client) and one that is `executing` (a client is driving it) look identical
-- from `task N queued`, and they are completely different defects.
RegisterCommand("npc.diag", function(source, args, raw)
    if args.n ~= 1 then return output(source, raw, false, "usage: npc.diag <npcId>") end
    local id = integer(args[1])
    local npc = Open77.npcs.get(id)
    if npc == nil then return output(source, raw, false, "npc not found or not owned") end
    output(source, raw, true, string.format(
        "npc %d template=%s bucket=%d pos=%.2f,%.2f,%.2f health=%.1f/%.1f aiMode=%s " ..
        "authority=%d epoch=%d currentTask=%d",
        npc.id, npc.template, npc.bucket, npc.x, npc.y, npc.z, npc.health, npc.maxHealth,
        tostring(npc.aiMode), npc.authorityPlayerId, npc.authorityEpoch, npc.currentTaskId))
    if npc.authorityPlayerId == 0 then
        output(source, raw, true,
            "no authority client: nothing can execute a native command, tasks stay suspended")
    end
    local tasks = Open77.npcs.tasks.all(id)
    output(source, raw, true, string.format("tasks (%d)", #tasks))
    for index, task in ipairs(tasks) do
        if index > 32 then return output(source, raw, true, "... output limited to 32") end
        output(source, raw, true, string.format(
            "  task=%d type=%s channel=%d status=%s reason=%s revision=%d timeoutMs=%d params=%s",
            task.id, task.type, task.channel, task.status,
            task.reason ~= "" and task.reason or "-", task.revision, task.timeoutMs, task.parameters))
    end
end, true)

AddEventHandler("onNpcTaskState", function(npcId, taskId, status, reason)
    print(string.format("npc task npc=%s task=%s status=%s reason=%s", npcId, taskId, status, reason or ""))
end)

AddEventHandler("onNpcDied", function(npcId, source, cause)
    print(string.format("npc died npc=%s source=%s cause=%s", npcId, source, cause))
end)

AddEventHandler("onNpcDamaged", function(npcId, source, amount, health, cause)
    print(string.format("npc damaged npc=%s source=%s amount=%s health=%s cause=%s",
        npcId, source, amount, health, cause))
end)

AddEventHandler("onNpcAuthorityChanged", function(npcId, playerId, epoch, reason)
    print(string.format("npc authority npc=%s player=%s epoch=%s reason=%s",
        npcId, playerId, epoch, reason or ""))
end)

print("Open77 NPC reference resource ready")
