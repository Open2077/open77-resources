local members, scope, scopeRoster, scopeError = {}, nil, "", nil
local ready, stopping = false, false
local grades, gradeNames = {}, {}
for _, grade in ipairs(Cyberarena.definition.grades) do
    grades[grade.id] = true
    gradeNames[#gradeNames+1] = grade.id
end

local function notice(player, message)
    -- State/command notices only, never per-frame positions or identity data.
    print(("[cyberarena] player=%s %s"):format(player, tostring(message):gsub("[\r\n]", " "):sub(1, 256)))
    TriggerClientEvent("chat:addMessage", player, {args={"Cyberarena",message},color={34,216,226}})
end
local function alive(player)
    local state = Open77.players.getLifeState(player)
    return state and state.phase == "alive"
end
local function inside(player)
    local position = Open77.players.position(player)
    if not position then return false end
    local center = Cyberarena.center
    return (position.x-center.x)^2 + (position.y-center.y)^2 <= Cyberarena.radius^2
        and math.abs(position.z-center.z) <= Cyberarena.height
end
local function eligible(player)
    return alive(player) and inside(player) and not Open77.players.getVehicleSeat(player)
end
local function closeScope()
    if scope then Open77.combat.removeScope(scope) end
    scope, scopeRoster = nil, ""
end
local function refreshScope()
    if stopping then return end
    local roster = {}
    for player, member in pairs(members) do
        if member.phase == "active" and eligible(player)
            and Open77.routingBuckets.getPlayer(player) == Cyberarena.bucket then
            roster[#roster+1] = player
        end
    end
    table.sort(roster)
    local key = table.concat(roster, ":")
    if key == scopeRoster and scope then return end
    closeScope()
    if #roster < 2 then return end
    local id, reason = Open77.combat.createScope({bucket=Cyberarena.bucket,players=roster})
    if id then
        scope, scopeRoster, scopeError = id, key, nil
        for _, player in ipairs(roster) do notice(player, "Arena ready. Tap attack for a quick punch; hold and release for a charged strike.") end
    elseif reason ~= scopeError then
        scopeError = reason
        for _, player in ipairs(roster) do notice(player, "Combat waiting: " .. tostring(reason)) end
    end
end

local function leave(player, reason, disconnected)
    local member = members[player]
    if not member then return end
    member.phase = "leaving"
    closeScope()
    members[player] = nil
    if not disconnected and Open77.routingBuckets.getPlayer(player) == Cyberarena.bucket then
        local returned = Open77.routingBuckets.setPlayer(player, member.returnBucket)
        if not returned then
            print("[cyberarena] return bucket refused player=" .. player)
            notice(player, "Arena return bucket failed; contact the server operator.")
        end
    end
    -- Capture the destination bucket before requesting native paid restoration.
    -- The backend also reconciles context changes during resource-stop cleanup.
    if member.lease and not stopping then Open77.cyberware.releaseLease(player, member.lease) end
    if not disconnected then notice(player, "Left arena: " .. reason .. ". The platform restores your paid implants.") end
    refreshScope()
end

local function beginLease(player, member)
    -- Changing routing clears the session's position snapshot. A paid current()
    -- record can still be ready before Usable() has a new destination sample.
    local position = Open77.players.position(player)
    if not position or position.bucket ~= Cyberarena.bucket then return end
    if not Open77.cyberware.current(player) then return end
    local result, reason = Open77.cyberware.lease(player, Cyberarena.definition.id, member.grade,
        {durationMs=Cyberarena.durationMs})
    if not result then
        if reason == "cyberware_not_ready" then
            if member.waitReason ~= reason then
                member.waitReason = reason
                notice(player, "Waiting for destination character readiness.")
            end
            return
        end
        leave(player, "loadout refused: " .. tostring(reason)); return
    end
    member.lease, member.phase = result.lease, "pending"
    member.deadline = GetGameTimer() + Cyberarena.prepareTimeoutMs
    print(("[cyberarena] player=%s phase=pending grade=%s lease=%s ticket=%s")
        :format(player,member.grade,tostring(result.lease),tostring(result.ticket)))
end

CreateThread(function()
    local result, reason = Open77.cyberware.define(Cyberarena.definition)
    ready = result ~= nil
    if not ready then print("[cyberarena] definition unavailable: " .. tostring(reason)) end
end)

RegisterCommand("cyberarena", function(player, args)
    if not player or player <= 0 then return end
    local action, grade = args[1], args[2] or Cyberarena.defaultGrade
    local member = members[player]
    if action == "leave" then
        if member then leave(player, "requested") else notice(player, "You are not in the arena.") end
    elseif action == "join" then
        if not ready or stopping then notice(player, "Arena unavailable."); return end
        if member then notice(player, "Already joined. Use /cyberarena loadout <grade> or leave."); return end
        if not grades[grade] then notice(player, "Unknown loadout grade."); return end
        if not eligible(player) then notice(player, "Walk to the arena site alive and outside a vehicle before joining."); return end
        if not Open77.cyberware.current(player) or Open77.cyberware.leaseState(player) then
            notice(player, "Wait for your character implants to finish restoring."); return
        end
        local count = 0
        for _ in pairs(members) do count = count + 1 end
        if count >= Cyberarena.maxPlayers then notice(player, "Arena full."); return end
        for _, occupant in ipairs(Open77.players.inBucket(Cyberarena.bucket)) do
            if not members[occupant] then notice(player, "Arena bucket occupied by another activity."); return end
        end
        local bucket = Open77.routingBuckets.getPlayer(player)
        if bucket == Cyberarena.bucket then notice(player, "Arena bucket is already your current activity."); return end
        member = {returnBucket=bucket,grade=grade,phase="preparing",deadline=GetGameTimer()+Cyberarena.prepareTimeoutMs,
            nextReset=GetGameTimer()}
        if not Open77.routingBuckets.setPlayer(player, Cyberarena.bucket) then
            notice(player, "Arena routing unavailable."); return
        end
        members[player] = member
        notice(player, "Joining arena with " .. grade .. ". Paid implants remain unchanged. Preparing temporary arms...")
        beginLease(player, member)
    elseif action == "loadout" then
        if not member or member.phase ~= "active" then notice(player, "Wait for an active arena loadout."); return end
        if not grades[grade] then notice(player, "Unknown loadout grade."); return end
        if not eligible(player) then leave(player, "body unavailable"); return end
        member.phase, member.nextGrade = "switching", grade
        member.deadline = GetGameTimer() + Cyberarena.prepareTimeoutMs
        closeScope()
        local result, reason = Open77.cyberware.releaseLease(player, member.lease)
        if not result then leave(player, "release refused: " .. tostring(reason)); return end
        notice(player, "Restoring paid arms before applying the next temporary loadout.")
        refreshScope()
    elseif action == "reset" then
        if not member or member.phase ~= "active" or not eligible(player) then
            notice(player, "Reset requires an active, living arena participant."); return
        end
        local now = GetGameTimer()
        if now < member.nextReset then notice(player, "Reset is on cooldown."); return end
        -- Explicit practice reset; never revive, kill, teleport or change maxima.
        local health, healthError = Open77.stats.restore(player, "health")
        if not health then notice(player, "Health reset refused: " .. tostring(healthError)); return end
        member.nextReset = now + Cyberarena.resetCooldownMs
        local stamina, staminaError = Open77.stats.restore(player, "stamina")
        notice(player, stamina and "Health and stamina restored." or ("Health restored; stamina refused: " .. tostring(staminaError)))
    else
        local c = Cyberarena.center
        notice(player, ("Use /cyberarena join [grade], loadout <grade>, reset, leave. Site %.1f %.1f %.1f; grades %s.")
            :format(c.x,c.y,c.z,table.concat(gradeNames,"/")))
    end
end, false)

-- Observe authoritative lease state; an event/queued ticket alone never enables combat.
local function reconcile(player, member)
    local state = Open77.cyberware.leaseState(player)
    if member.phase == "preparing" then beginLease(player, member); return end
    if member.phase == "switching" then
        if not state and Open77.cyberware.current(player) then
            member.grade, member.nextGrade, member.lease = member.nextGrade, nil, nil
            member.phase = "preparing"
            beginLease(player, member)
        end
        return
    end
    if not state or state.id ~= member.lease then leave(player, "temporary loadout ended"); return end
    if state.phase == "active" and Open77.cyberware.effective(player) then
        if member.phase ~= "active" then
            member.phase = "active"
            notice(player, "Temporary " .. member.grade .. " arms ready. Draw your fists; waiting for another ready participant.")
            refreshScope()
        end
    elseif state.phase == "restoring" or state.phase == "failed" or state.phase == "ended" then
        leave(player, state.reason or "temporary loadout restoring")
    end
end
AddEventHandler("onCyberwareLeaseChanged", function(player, encoded)
    player = tonumber(player)
    local member = members[player]
    local state = type(encoded) == "string" and json.decode(encoded) or nil
    if member and type(state) == "table" and state.id == member.lease then reconcile(player, member) end
end)

Open77.combat.onDamage(function(event)
    local attacker, victim = tonumber(event.attacker), tonumber(event.victim)
    local a, v = members[attacker], members[victim]
    if not a and not v then return end
    if event.attackKind == "fall" or event.attackKind == "environment" then return end
    if not a or not v or a.phase ~= "active" or v.phase ~= "active" or not scope
        or not eligible(attacker) or not eligible(victim)
        or Open77.routingBuckets.getPlayer(attacker) ~= Cyberarena.bucket
        or Open77.routingBuckets.getPlayer(victim) ~= Cyberarena.bucket then return false end
    if event.attackKind ~= "melee" or tonumber(event.weaponTdbId) ~= 70020290049 then return false end
end)

AddEventHandler("onPlayerDisconnected", function(player) leave(tonumber(player), "disconnected", true) end)
AddEventHandler("onResourceStop", function(name)
    if name ~= GetCurrentResourceName() then return end
    stopping = true
    closeScope()
    local players = {}
    for player in pairs(members) do players[#players+1] = player end
    for _, player in ipairs(players) do leave(player, "arena stopped") end
end)
CreateThread(function()
    while true do
        local players = {}
        for player in pairs(members) do players[#players+1] = player end
        for _, player in ipairs(players) do
            local member = members[player]
            if member then
                local position = Open77.players.position(player)
                local waitingForPosition = member.phase == "preparing" and
                    (not position or position.bucket ~= Cyberarena.bucket)
                if not alive(player) or Open77.players.getVehicleSeat(player)
                    or Open77.routingBuckets.getPlayer(player) ~= Cyberarena.bucket
                    or (not waitingForPosition and not inside(player)) then
                    leave(player, "left area or body unavailable")
                elseif member.phase ~= "active" and GetGameTimer() >= member.deadline then
                    leave(player, "loadout preparation timed out")
                else reconcile(player, member) end
            end
        end
        refreshScope()
        Wait(250)
    end
end)
