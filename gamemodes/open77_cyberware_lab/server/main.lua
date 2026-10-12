-- Optional isolated test-server policy. Installation commands exercise public
-- server APIs; native feasibility controls remain explicitly named probes.
local enabled = false
local motions = {}
local attachedEffects = {}
local activityWatches = {}
local stopping = false

local function positivePlayer(value)
    local id = tonumber(value)
    return id and id >= 1 and id <= 9007199254740991 and id % 1 == 0 and id or nil
end
local function clientEvent(event, player, ...)
    local id = positivePlayer(player)
    if not id then return false, "positive_player_required" end
    return TriggerClientEvent(event, id, ...)
end
local function reply(player, raw, ok, reason)
    if positivePlayer(player) then
        local message=tostring(reason or "applied")
        if #message>2048 then
            local boundary=utf8.offset(message,0,2001) or 2001
            message=message:sub(1,boundary-1).." ... [see server log]"
        end
        clientEvent("open77:command:result", player, raw, ok == true, message)
    end
    print(("[cyberware lab] %s accepted=%s reason=%s"):format(raw, tostring(ok), tostring(reason)))
end

local function activityJson(target)
    local state, reason = Open77.cyberware.activity(target)
    return state and json.encode(state) or "null", reason
end

local function watchActivity(issuer, target, duration)
    if stopping then return false, "resource_stopping" end
    if not duration or duration % 1 ~= 0 or duration < 100 or duration > 10000 then
        return false, "durationMs must be an integer from 100 to 10000"
    end
    if activityWatches[target] then return false, "activity_watch_already_running" end
    local count = 0
    for _ in pairs(activityWatches) do count = count + 1 end
    if count >= 4 then return false, "activity_watch_limit" end
    local watch = { issuer=issuer, expires=GetGameTimer()+duration }
    activityWatches[target] = watch
    CreateThread(function()
        while not stopping and activityWatches[target] == watch and GetGameTimer() < watch.expires do
            local state, reason = activityJson(target)
            print(("[cyberware lab] activitywatch player=%s sampledAt=%s state=%s reason=%s")
                :format(target, GetGameTimer(), state, tostring(reason)))
            Wait(100)
        end
        if activityWatches[target] == watch then activityWatches[target] = nil end
    end)
    return true, "activity_watch_started durationMs=" .. duration
end

AddEventHandler("onPlayerDisconnected", function(player)
    player = tonumber(player)
    for target, watch in pairs(activityWatches) do
        if target == player or watch.issuer == player then activityWatches[target] = nil end
    end
end)

AddEventHandler("onCyberwareMeleeBlocked", function(victim, attacker, sequence, amount)
    print(("[cyberware lab] blocked victim=%s attacker=%s sequence=%s chip=%s")
        :format(victim, attacker, sequence, amount))
end)

AddEventHandler("onCyberwareJump", function(player, encodedResult)
    -- Host JSON is {sequence,ok,error}; this is admission, not native consumption.
    print(("[cyberware lab] jump admission player=%s result=%s")
        :format(player, encodedResult))
end)

AddEventHandler("onCyberwareMotionOutcome", function(victim, attacker, outcome)
    -- Public accepted-hit outcome explains a busy/recovering target without
    -- confusing it with refused damage or restarting the existing motion.
    print(("[cyberware lab] motion outcome victim=%s attacker=%s detail=%s")
        :format(victim, attacker, outcome))
end)

AddEventHandler("open77:playerDamaged", function(victim, attacker, amount, kind, weapon, part, health)
    print(("[cyberware lab] contact victim=%s attacker=%s amount=%s kind=%s weapon=%s part=%s health=%s")
        :format(victim, attacker, amount, kind, weapon, part, health))
end)

CreateThread(function()
    local result, reason = Open77.cyberware.define(CyberwareLab.definition)
    print("[cyberware lab] definition=" .. (result and "ready" or tostring(reason)))
    local legs, legsReason = Open77.cyberware.define(CyberwareLab.legsDefinition)
    print("[cyberware lab] legs definition=" .. (legs and "ready" or tostring(legsReason)))
end)

AddEventHandler("onCyberwareOperationCompleted", function(patient, ticket, encoded)
    print(("[cyberware lab] completed patient=%s ticket=%s result=%s"):format(patient, ticket, encoded))
end)

RegisterCommand("cyberlab", function(player, args, raw)
    local action, option = args[1], args[2]
    if action == "dash" then
        local ok, reason = CyberwareLabDash.command(player, {args[2], args[3], args[4], args[5]})
        reply(player, raw, ok == true, reason)
        return
    end
    if action == "slam" then
        local ok, reason = CyberwareLabSlam.command(player, {args[2], args[3], args[4]})
        reply(player, raw, ok == true, reason)
        return
    end
    if action == "reflex" then
        local ok, reason = CyberwareLabReflex.command(player, {args[2], args[3], args[4]})
        reply(player, raw, ok == true, reason)
        return
    end
    if action == nil or action == "ui" then
        local ok, reason = CyberwareLabPanel.open(player, option)
        if not ok then reply(player, raw, false, reason) end
        return
    end
    if (action == 'fx' or action == 'fxoff' or action == 'armsprobe') and not positivePlayer(player) then
        reply(player, raw, false, 'client_issuer_required')
        return
    end
    if action == 'load' then
        local ok, reason = CyberwareLabLoad(player,args)
        reply(player,raw,ok==true,reason)
        return
    end
    local ok, reason
    if action == "bucket" then
        local target, bucket = positivePlayer(option), tonumber(args[3])
        if not target then ok, reason = false, "positive_player_required"
        elseif not bucket or bucket < 0 or bucket > 4294967295 or bucket % 1 ~= 0 then
            ok, reason = false, "bucket_must_be_uint32"
        else
            local previous = GetPlayerRoutingBucket(target)
            ok = SetPlayerRoutingBucket(target, bucket)
            reason = ok and ("player=%s previous=%s bucket=%s"):format(target, previous, GetPlayerRoutingBucket(target))
                or "player_unavailable"
        end
    elseif action == "jacket" then
        ok, reason = CyberwareLabJackets.start(tonumber(option), args[3])
    elseif action == "jacketrestore" then
        ok, reason = CyberwareLabJackets.restore(tonumber(option))
    elseif (action == "activity" or action == "activitywatch") and tonumber(option) then
        local target = tonumber(option)
        if target < 1 or target % 1 ~= 0 then ok, reason = false, "invalid_player"
        elseif action == "activitywatch" then ok, reason = watchActivity(tonumber(player), target, tonumber(args[3]))
        else
            local state, why = activityJson(target)
            ok, reason = true, state
            if why then reason = state .. " reason=" .. tostring(why) end
        end
    elseif action == "state" and tonumber(option) then
        ok, reason = Open77.cyberware.current(tonumber(option))
        if ok then reason = json.encode(ok); ok = true
        else reason = reason or "cyberware_not_ready" end
    elseif (action == "install" or action == "remove" or action == "installlegs" or action == "removelegs") and positivePlayer(option) then
        local installing = action == "install" or action == "installlegs"
        local slot = (action == "installlegs" or action == "removelegs") and "legs" or "arms"
        local record
        record, reason = Open77.cyberware.current(tonumber(option))
        if record then
            local operation
            if installing then operation = args[4] else operation = args[3] end
            local expected = record.operationId == operation and record.revision - 1 or record.revision
            if type(operation) ~= "string" or operation == "" then
                reason = "explicit operation ID required for reproducible retries"
            elseif installing then
                ok, reason = Open77.cyberware.install(tonumber(option),
                    (slot == "legs" and CyberwareLab.legsDefinition or CyberwareLab.definition).id, args[3],
                    { expectedRevision=expected, operationId=operation })
            else
                ok, reason = Open77.cyberware.remove(tonumber(option),
                    { expectedRevision=expected, operationId=operation, slot=slot })
            end
            if type(ok) == "table" then reason = json.encode(ok); ok = ok.ok == true end
        else reason = reason or "cyberware_not_ready" end
    elseif action == "motion" and tonumber(option) then
        local result
        result, reason = Open77.motion.current(tonumber(option))
        ok, reason = true, result and json.encode(result) or reason or "no_active_motion"
    elseif action == "knock" and tonumber(option) then
        local result
        result, reason = Open77.motion.knockdown(tonumber(option), {
            distance=tonumber(args[3]) or 2, x=tonumber(args[4]) or 0, y=tonumber(args[5]) or 1,
        })
        ok = result ~= nil
        if result then motions[tonumber(option)] = result.id; reason = json.encode(result) end
    elseif action == "motionstop" and tonumber(option) then
        local result
        result, reason = Open77.motion.cancel(tonumber(option), motions[tonumber(option)] or "")
        ok = result ~= nil
    elseif action == "profile" and tonumber(option) then
        ok, reason = clientEvent("open77:cyberlab:profile", tonumber(option))
    elseif action == "capabilities" and tonumber(option) then
        ok, reason = clientEvent("open77:cyberlab:capabilities", tonumber(option))
    elseif action == "jumpstate" and positivePlayer(option) then
        ok, reason = clientEvent("open77:cyberlab:jumpstate", tonumber(option))
    elseif action == "action" and tonumber(option) then
        ok, reason = clientEvent("open77:cyberlab:action", tonumber(option))
    elseif action == "heal" and tonumber(option) then
        ok, reason = Open77.players.heal(tonumber(option), 100)
    elseif action == "kill" then
        local target = positivePlayer(option)
        if not target then ok, reason = false, "positive_player_required"
        else
            -- Explicit lifecycle test through canonical server death, no native fallback.
            ok, reason = Open77.players.kill(target, {cause="script"})
        end
    elseif action == "revive" then
        local target = positivePlayer(option)
        if not target then ok, reason = false, "positive_player_required"
        else
            -- The authoritative life service accepts only canonical Dead.
            -- An accepted request still awaits native recovery acknowledgement.
            ok, reason = Open77.players.revive(target, {health=1.0, graceMs=3000})
        end
    elseif action == "health" and tonumber(option) then
        local health = Open77.players.getHealth(tonumber(option))
        ok, reason = health ~= nil, health and json.encode(health) or "player_unavailable"
    elseif action == "stats" and tonumber(option) then
        local stats = Open77.stats.get(tonumber(option))
        ok, reason = stats ~= nil, stats and json.encode(stats) or "player_unavailable"
    elseif action == "stamina" and tonumber(option) and tonumber(args[3]) then
        ok, reason = Open77.stats.set(tonumber(option), "stamina", tonumber(args[3]))
    elseif action == "maxhealth" and positivePlayer(option) and tonumber(args[3]) and tonumber(args[3]) >= 1 and tonumber(args[3]) <= 100000 then
        -- Test-only punching bag: a larger canonical pool keeps knockback and
        -- damage authentic while surviving many more hits.
        ok, reason = SetPlayerMaxHealth(tonumber(option), tonumber(args[3]))
        if ok then ok, reason = Open77.stats.set(tonumber(option), "health", tonumber(args[3])) end
    elseif action == "godmode" and positivePlayer(option) and (args[3] == "on" or args[3] == "off") then
        -- Test-only invulnerability for a punching bag: knockback and downed
        -- reactions still apply, canonical health no longer drops.
        ok, reason = SetPlayerGodMode(tonumber(option), args[3] == "on")
    elseif action == "staminaRegen" and tonumber(option) and (args[3] == "on" or args[3] == "off") then
        ok, reason = Open77.stats.setRegenEnabled(tonumber(option), "stamina", args[3] == "on")
    elseif action == "pvp" and (option == "on" or option == "off") then
        ok, reason = Open77.combat.setFriendlyFire(option == "on")
        if ok then enabled = option == "on" end
    elseif action == "fx" and type(option) == "string" and option:match("^%d+$")
        and type(args[3]) == "string" and type(args[4]) == "string" then
        -- Privileged M0 probe: this is the REQUESTER'S local Open77 handle.
        -- Production effects will use typed network targets, never this form.
        ok, reason = clientEvent("open77:cyberlab:fx", player, option, args[3], args[4], args[5])
    elseif action == "fxworld" then
        local target=positivePlayer(option)
        local effect=args[3]
        local x,y,z=tonumber(args[4]),tonumber(args[5]),tonumber(args[6])
        local function coordinate(v) return v and v==v and math.abs(v)<=1000000 end
        if not target then ok,reason=false,"positive_player_required"
        elseif not GetPlayerName(target) then ok,reason=false,"player_not_found"
        elseif effect~="impact.ground_slam" and effect~="explosion.frag" then ok,reason=false,"effect_not_approved"
        elseif #args~=6 or not coordinate(x) or not coordinate(y) or not coordinate(z) then ok,reason=false,"finite_xyz_required"
        else ok,reason=clientEvent("open77:cyberlab:fxworld",target,effect,{x=x,y=y,z=z}) end
    elseif action == "fxevent" and tonumber(option) and type(args[3]) == "string" and args[3] ~= "" then
        local anchor = args[4] or "body"
        if anchor ~= "body" and anchor ~= "weaponRight" then ok, reason = false, "invalid_anchor"
        else ok, reason = clientEvent("open77:cyberlab:fxevent", tonumber(option), args[3], anchor) end
    elseif action == "fxself" and tonumber(option) then
        local anchor, duration = args[5] or "weaponRight", args[6] == nil and 8 or tonumber(args[6])
        if type(args[3]) ~= "string" or args[3] == "" or type(args[4]) ~= "string" or args[4] == "" then
            ok, reason = false, "effect and explicit slot required"
        elseif anchor ~= "body" and anchor ~= "weaponRight" then
            ok, reason = false, "anchor must be body or weaponRight"
        elseif not duration or duration < 5 or duration > 10 then
            ok, reason = false, "duration must be between 5 and 10 seconds"
        else
            -- Target the selected receiver's own body, including console-driven tests.
            ok, reason = clientEvent("open77:cyberlab:fx", tonumber(option), "1", args[3], args[4], anchor, duration)
        end
    elseif action == "fxplayer" and type(option) == "string" and option:match("^%d+$") then
        ok, reason = Open77.effects.playOn({kind="player", id=option}, args[3] or "fire.small",
            {slot=args[4] or "RightHand", duration=5})
    elseif action == "attachplayer" and type(option) == "string" and option:match("^%d+$") then
        local ttl = args[4] == nil and 5000 or tonumber(args[4])
        if type(args[3]) ~= "string" or args[3] == "" then
            ok, reason = false, "effect name or depot path required"
        elseif not ttl or ttl < 1 or ttl > 600000 or ttl % 1 ~= 0 then
            ok, reason = false, "ttlMs must be an integer from 1 to 600000"
        else
            for id in pairs(attachedEffects) do
                if not Open77.effects.get(id) then attachedEffects[id] = nil end
            end
            local id
            id, reason = Open77.effects.attach({kind="player",id=option}, args[3], {
                slot="RightHand", localAnchor="weaponRight", localSlot="right_hand_start", ttlMs=ttl,
            })
            ok = id ~= nil
            if id then attachedEffects[id] = true; reason = "effect_id=" .. id end
        end
    elseif action == "effectremove" and type(option) == "string" and option:match("^%d+$") then
        if not attachedEffects[option] then ok, reason = false, "effect_not_owned_by_lab"
        else
            ok, reason = Open77.effects.remove(option)
            if ok or reason == "not_found" then attachedEffects[option] = nil end
        end
    elseif action == "soundplayer" and type(option) == "string" and option:match("^%d+$") then
        ok, reason = Open77.effects.sound({kind="player", id=option}, args[3] or "w_cyb_npc_strongarms_whoosh_normal")
    elseif action == "fxoff" then
        ok, reason = clientEvent("open77:cyberlab:fxoff", player)
    elseif action == "localprobe" and tonumber(option) and (args[3] == "on" or args[3] == "off") then
        ok, reason = clientEvent("open77:cyberlab:localprobe", tonumber(option), args[3] == "on")
    elseif action == "armsprobe" and tonumber(option) and (args[3] == "on" or args[3] == "off") then
        ok, reason = clientEvent("open77:cyberlab:armsprobe", player, tonumber(option), args[3] == "on")
    else
        ok, reason = false, "usage: cyberlab reflex <grant|revoke|cancel|inspect|test> <player> <street|combat> | cyberlab bucket <player> <uint32> | jacket <player> [record] | jacketrestore <player> | activity <player> | activitywatch <player> <durationMs:100-10000> | state <player> | install <player> <grade> <operation> | remove <player> <operation> | installlegs <player> <training|athlete> <operation> | removelegs <player> <operation> | jumpstate <player> | pvp <on|off> | heal/revive/kill/health/profile/action/stats/capabilities <player> | stamina <player> <value> | staminaRegen <player> <on|off> | godmode <player> <on|off> | maxhealth <player> <1-100000> | knock <player> [distance] [x] [y] | motion/motionstop <player> | fxworld <player> <impact.ground_slam|explosion.frag> <x> <y> <z> | fxevent <player> <event> [body|weaponRight] | fxself <player> <effect> <slot> [body|weaponRight] [seconds:5-10] | fxplayer <player> [effect] [slot] | attachplayer <player> <effect> [ttlMs] | effectremove <id> | soundplayer <player> [event] | fxoff | localprobe/armsprobe <player> <on|off>"
    end
    reply(player, raw, ok, reason)
end, false)

AddEventHandler("onResourceStop", function(name)
    if name ~= GetCurrentResourceName() then return end
    stopping = true
    activityWatches = {}
    for id in pairs(attachedEffects) do Open77.effects.remove(id) end
    attachedEffects = {}
    if enabled then Open77.combat.setFriendlyFire(false) end
end)
