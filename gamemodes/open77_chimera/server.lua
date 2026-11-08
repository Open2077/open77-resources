local RECORD = "Character.main_boss_chimera"
local encounters, pending, requests = {}, {}, {}
local serial = 0
local parts = {
    "177194883684", "179728681950", "147767125663", "150622874300", "152049130026",
    "154496208777", "150150235863", "147852334957", "152318278446", "154348890772",
    "156678770485", "158008766361", "157022743029", "158789589220", "155833006152",
    "172154262771", "155685144921",
}
local partIndex = {}
for i, record in ipairs(parts) do partIndex[record] = i end

local function finite(value)
    local n = tonumber(value)
    if not n or n ~= n or n == math.huge or n == -math.huge then return nil end
    return n
end
local function integer(value, minimum, maximum)
    local n = finite(value)
    if not n or n % 1 ~= 0 or n < minimum or n > maximum then return nil end
    return n
end
local function idkey(value)
    local n = integer(value, 1, 9007199254740991)
    return n and tostring(math.floor(n)) or nil
end
local function output(player, raw, ok, text)
    text = "[chimera] " .. text
    print(text)
    if player and player > 0 then TriggerClientEvent("open77:command:result", player, raw or "", ok == true, text) end
end
local function playerPosition(id)
    id = integer(id, 1, 9007199254740991)
    if not id then return nil end
    local read = Open77.players.get(id)
    local life = Open77.players.getLifeState(id)
    if not read or not read.ready or not life or (life.phase ~= "alive" and life.phase ~= "recovering") then return nil end
    return Open77.players.position(id)
end
local function alivePosition(id)
    id = integer(id, 1, 9007199254740991)
    local life = id and Open77.players.getLifeState(id)
    if not life or life.phase ~= "alive" then return nil end
    return playerPosition(id)
end
local function near(position, npc, radius)
    if not position or position.bucket ~= npc.bucket then return false end
    return (position.x-npc.x)^2 + (position.y-npc.y)^2 + (position.z-npc.z)^2 <= radius * radius
end
local function visualPacket(encounter, npc, player, states, reset, seed)
    if not near(playerPosition(player), npc, 250) then return end
    encounter.visualDelivery = (encounter.visualDelivery or 0) + 1
    local packet = { npcId = tostring(encounter.id), epoch = encounter.epoch,
        sequence = encounter.visualDelivery, reset = reset, seed = seed, states = states }
    local encoded = json.encode(packet):gsub('"states":{}', '"states":[]')
    TriggerClientEvent("open77:chimera:visuals", player, encoded)
end
local function visualBroadcast(encounter, npc, states, reset, seed)
    if not npc then return end
    for _, id in ipairs(Open77.players.all()) do
        visualPacket(encounter, npc, tonumber(id), states, reset, seed)
    end
end
local function resetVisuals(encounter, npc)
    encounter.visuals, encounter.visualTombstones, encounter.visualTombOrder = {}, {}, {}
    encounter.visualFloor, encounter.visualCount, encounter.visualSequence = 0, 0, 0
    -- Eight 32-row packets per 100 ms, matching the native sender while
    -- leaving room in the connection-wide 192/s net-event budget.
    encounter.visualTokens, encounter.visualAt = 16, Open77.time.monotonic()
    visualBroadcast(encounter, npc, {}, true, true)
end
local function visualSnapshot(encounter, npc, player)
    if not near(playerPosition(player), npc, 250) then return end
    local ids = {}
    for id in pairs(encounter.visuals) do ids[#ids + 1] = id end
    table.sort(ids)
    local batch, first = {}, true
    for _, id in ipairs(ids) do
        batch[#batch + 1] = encounter.visuals[id].row
        if #batch == 32 then
            visualPacket(encounter, npc, player, batch, first, true)
            batch, first = {}, false
        end
    end
    if first or #batch > 0 then visualPacket(encounter, npc, player, batch, first, true) end
end
local function visualTombstone(encounter, row)
    encounter.visualTombstones[row.id] = { kind = row.kind, phase = row.phase }
    local order = encounter.visualTombOrder
    order[#order + 1] = row.id
    if #order > 512 then
        local oldest = table.remove(order, 1)
        encounter.visualTombstones[oldest] = nil
        encounter.visualFloor = math.max(encounter.visualFloor, oldest)
    end
end
local function expireVisuals(encounter, npc, now)
    local expired = {}
    for id, entry in pairs(encounter.visuals) do
        if now < entry.at or now - entry.at >= 2 then
            local row = entry.row
            local terminal = { id = row.id, kind = row.kind, phase = 3, position = row.position,
                rotation = row.rotation, target = row.target, normal = {0, 0, 0}, trail = false, indicator = false }
            encounter.visuals[id] = nil
            encounter.visualCount = encounter.visualCount - 1
            visualTombstone(encounter, terminal)
            expired[#expired + 1] = terminal
            if #expired == 32 then
                visualBroadcast(encounter, npc, expired, false, false)
                expired = {}
            end
        end
    end
    if #expired > 0 then visualBroadcast(encounter, npc, expired, false, false) end
end
local function current(encounter)
    if not encounter then return nil end
    local npc = Open77.npcs.get(encounter.id)
    if npc and tonumber(npc.authorityEpoch) ~= encounter.epoch then
        encounter.epoch = tonumber(npc.authorityEpoch)
        encounter.frame, encounter.frameSequence, encounter.reportSequence = nil, 0, 0
        encounter.frameTokens, encounter.frameAt = 4, Open77.time.monotonic()
        encounter.victimWindows, encounter.reportWindow, encounter.featureRevisions = {}, nil, {}
        encounter.shots, encounter.shotWindow = {0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0}, nil
        encounter.effectRevisions, encounter.effectCount = {}, 0
        encounter.audio = {{revision=0,active=false},{revision=0,active=false},{revision=0,active=false}}
        resetVisuals(encounter, npc)
        encounter.revision = encounter.revision + 1
    end
    if npc then encounter.lastNpc = npc end
    return npc
end
local function snapshot(encounter, npc)
    return { npcId = tostring(encounter.id), epoch = npc.authorityEpoch, revision = encounter.revision,
        phase = encounter.phase, repairing = encounter.repairing, gas = encounter.gas,
        parts = encounter.parts, frame = encounter.frame }
end
local function encodeSnapshot(encounter, npc)
    -- The runtime encodes an empty Lua table as {}, even when it came from [].
    -- These schema fields are arrays; preserve that wire shape.
    local encoded = json.encode(snapshot(encounter, npc))
    encoded = encoded:gsub('"features":{}', '"features":[]')
    encoded = encoded:gsub('"parameters":{}', '"parameters":[]')
    encoded = encoded:gsub('"effects":{}', '"effects":[]')
    return encoded
end
local function send(encounter, npc, player)
    if near(playerPosition(player), npc, 250) then
        TriggerClientEvent("open77:chimera:state", player, encodeSnapshot(encounter, npc))
    end
end
local function publish(encounter)
    local npc = current(encounter)
    if not npc then return end
    for _, id in ipairs(Open77.players.all()) do send(encounter, npc, tonumber(id)) end
end
local function changed(encounter)
    encounter.revision = encounter.revision + 1
    publish(encounter)
end
local function discard(encounter)
    encounters[tostring(encounter.id)] = nil
    encounter.frame = nil
    resetVisuals(encounter, encounter.lastNpc)
    encounter.repairing = false
end

local profiles = {{id="chimera", label="Chimera", phases={
    {id="armored",label="Armored"}, {id="exposed",label="Exposed"},
    {id="gas",label="Gas"}, {id="core",label="Core"}}}}
local phaseOrder = {armored=1, exposed=2, gas=3, core=4}
local function phaseName(encounter)
    if encounter.phase >= 3 then return "core" end
    if encounter.gas then return "gas" end
    return encounter.phase == 2 and "exposed" or "armored"
end
local function state(encounter)
    local npc = current(encounter)
    if not npc then return nil, "boss_not_found" end
    local target = Open77.npcs.target(encounter.id)
    local actual = target and target.kind == "player" and tonumber(target.id) or nil
    if not actual or actual == 0 then
        actual = encounter.frame and tonumber(encounter.frame.target) or nil
        if actual == 0 then actual = nil end
    end
    local behavior = npc.behavior or {}
    return {id=tostring(encounter.id), profile="chimera", label="Chimera", controller=encounter.controller,
        bucket=npc.bucket, position={x=npc.x,y=npc.y,z=npc.z}, yaw=npc.yaw,
        health=npc.health, maxHealth=npc.maxHealth, healthPercent=npc.health / npc.maxHealth * 100,
        phase=phaseName(encounter), nativePhase=encounter.phase, repairing=encounter.repairing,
        gas=encounter.gas, alive=npc.health > 0, damagePolicy=encounter.damagePolicy,
        aiEnabled=behavior.aiEnabled ~= false, combatEnabled=behavior.combatEnabled ~= false,
        difficulty=Open77.npcs.getDifficulty(encounter.id),
        target={mode=encounter.target and "forced" or "native", playerId=encounter.target, actualPlayerId=actual},
        authority={playerId=npc.authorityPlayerId,epoch=npc.authorityEpoch}, parts=encounter.parts}
end
local function owned(id, controller)
    local encounter = encounters[idkey(id)]
    if not encounter or encounter.controller ~= controller then return nil, "boss_not_owned" end
    return encounter
end
local function validPolicy(policy)
    return policy == Open77.npcs.damage.mortal or policy == Open77.npcs.damage.immortal or
        policy == Open77.npcs.damage.invulnerable
end
local function create(controller, options)
    if type(options) ~= "table" or (options.profile ~= nil and options.profile ~= "chimera") then
        return nil, "boss_profile_invalid"
    end
    local p = options.position
    if type(p) ~= "table" or not finite(p.x) or not finite(p.y) or not finite(p.z) then return nil, "boss_position_invalid" end
    local yaw = options.yaw == nil and 0 or finite(options.yaw)
    local bucket = options.bucket == nil and 0 or integer(options.bucket, 0, 4294967295)
    local maximum = options.maxHealth == nil and 100 or finite(options.maxHealth)
    local health = options.health == nil and maximum or finite(options.health)
    local policy = options.damagePolicy == nil and Open77.npcs.damage.mortal or options.damagePolicy
    if not yaw or not bucket or not maximum or maximum <= 0 or maximum > 100000 or not health or health < 0 or health > maximum then
        return nil, "boss_options_invalid"
    end
    if not validPolicy(policy) or (options.aiEnabled ~= nil and type(options.aiEnabled) ~= "boolean") or
        (options.combatEnabled ~= nil and type(options.combatEnabled) ~= "boolean") then return nil, "boss_options_invalid" end
    local id, why = Open77.npcs.create({ record=RECORD, position={x=finite(p.x),y=finite(p.y),z=finite(p.z)},
        yaw=yaw, bucket=bucket, aiMode=Open77.npcs.ai.native, damagePolicy=policy,
        health=health, maxHealth=maximum, difficulty=options.difficulty, streamingRadius=250,
        loadout={combat={profile="chimera",group="open77_chimera",acquirePlayers=true,authoritativePlayerHits=true}},
        behavior={hitPricing="platform",observerReplay=true,aiEnabled=options.aiEnabled,combatEnabled=options.combatEnabled} })
    if not id then return nil, why end
    local fractions = {}
    for i=1,#parts do fractions[i]=1 end
    local encounter = {id=id, controller=controller, bucket=bucket, phase=1, repairing=false, gas=false,
        damagePolicy=policy, parts=fractions, revision=1, epoch=0, frameSequence=0, reportSequence=0,
        frameTokens=4, frameAt=Open77.time.monotonic(), victimWindows={}, reportWindow=nil}
    encounters[tostring(id)] = encounter
    encounter.lastHealth, encounter.lastMaxHealth = health, maximum
    publish(encounter)
    return encounter
end
local function restorePolicy(encounter, npc)
    if encounter.repairing or (npc and npc.damagePolicy == Open77.npcs.damage.invulnerable and
        encounter.damagePolicy ~= Open77.npcs.damage.invulnerable) then
        encounter.repairing = false
        Open77.npcs.setDamagePolicy(encounter.id, encounter.damagePolicy)
    end
end
local function reconcile(encounter, npc, natural)
    local beforePhase, beforeGas, beforeRepair = encounter.phase, encounter.gas, encounter.repairing
    local ratio = npc.health / npc.maxHealth
    encounter.lastHealth, encounter.lastMaxHealth = npc.health, npc.maxHealth
    if not natural then restorePolicy(encounter, npc) end
    if npc.health <= 0 then
        encounter.phase, encounter.repairing, encounter.frame = 4, false, nil
        if beforePhase ~= 4 then resetVisuals(encounter, npc) end
    elseif encounter.phase ~= 4 then
        if encounter.phase == 1 and ratio <= 0.7000001 then
            encounter.phase = 2
            if natural then
                encounter.repairing = true
                Open77.npcs.setDamagePolicy(encounter.id, Open77.npcs.damage.invulnerable)
                CreateThread(function()
                    Wait(60000)
                    if encounters[tostring(encounter.id)] ~= encounter or not encounter.repairing or encounter.phase == 4 then return end
                    restorePolicy(encounter)
                    changed(encounter)
                end)
            end
        end
        if ratio <= 0.4000001 then encounter.gas = true end
        if ratio <= 0.0100001 then encounter.phase = 3 end
    end
    if beforePhase ~= encounter.phase or beforeGas ~= encounter.gas or beforeRepair ~= encounter.repairing then changed(encounter) end
end
local function setHealth(encounter, health, maximum)
    local npc = current(encounter)
    if not npc then return nil, "boss_not_found" end
    if health == nil and maximum ~= nil then
        maximum = finite(maximum)
        if not maximum or maximum <= 0 then return nil, "boss_health_invalid" end
        health = npc.health / npc.maxHealth * maximum
    else health = finite(health) end
    if maximum ~= nil then maximum = finite(maximum); if not maximum or maximum <= 0 or maximum > 100000 then return nil, "boss_health_invalid" end end
    if not health or health < 0 or health > (maximum or npc.maxHealth) then return nil, "boss_health_invalid" end
    if npc.health <= 0 and health > 0 then return nil, "boss_dead" end
    if npc.health ~= encounter.lastHealth or npc.maxHealth ~= encounter.lastMaxHealth then
        reconcile(encounter, npc, true)
    end
    local ok, why = Open77.npcs.setHealth(encounter.id, health, maximum)
    if not ok then return nil, why or "boss_health_refused" end
    npc = current(encounter)
    if npc then reconcile(encounter, npc, false) end
    return state(encounter)
end
local function setTarget(encounter, player)
    local npc = current(encounter)
    if not npc then return nil, "boss_not_found" end
    if player ~= nil then
        player = integer(player, 1, 9007199254740991)
        local life = player and Open77.players.getLifeState(player)
        if not player or not life or life.phase ~= "alive" or not near(playerPosition(player), npc, 60) then return nil, "boss_target_invalid" end
    end
    if encounter.target == player then return state(encounter) end
    local policy = encounter.savedAttitude
    if policy then
        Open77.npcs.setAttitude(encounter.id, policy.default)
        for id, attitude in pairs(policy.players or {}) do Open77.npcs.setAttitude(encounter.id, attitude, {towards={playerId=tonumber(id)}}) end
        for id, attitude in pairs(policy.npcs or {}) do Open77.npcs.setAttitude(encounter.id, attitude, {towards={npcId=tonumber(id)}}) end
        for group, attitude in pairs(policy.groups or {}) do Open77.npcs.setAttitude(encounter.id, attitude, {towards={group=group}}) end
        for group in pairs(policy.relations or {}) do
            if not (policy.groups or {})[group] then Open77.npcs.setAttitude(encounter.id, nil, {towards={group=group}}) end
        end
        if encounter.target and not (policy.players or {})[tostring(encounter.target)] then
            Open77.npcs.setAttitude(encounter.id, nil, {towards={playerId=encounter.target}})
        end
        encounter.savedAttitude, encounter.target = nil, nil
    end
    if player then
        policy = Open77.npcs.getAttitude(encounter.id)
        if not policy then return nil, "boss_attitude_unavailable" end
        encounter.savedAttitude, encounter.target = policy, player
        local ok, why = Open77.npcs.setAttitude(encounter.id, "friendly")
        local function apply(attitude, towards)
            if not ok then return end
            ok, why = Open77.npcs.setAttitude(encounter.id, attitude, {towards=towards})
        end
        for id in pairs(policy.players or {}) do apply("friendly", {playerId=tonumber(id)}) end
        for id in pairs(policy.npcs or {}) do apply("friendly", {npcId=tonumber(id)}) end
        for group in pairs(policy.groups or {}) do apply("friendly", {group=group}) end
        for group in pairs(policy.relations or {}) do
            if not (policy.groups or {})[group] then apply("friendly", {group=group}) end
        end
        apply("hostile", {playerId=player})
        if not ok then setTarget(encounter, nil); return nil, why or "boss_target_refused" end
    end
    return state(encounter)
end
local function remove(encounter)
    local ok, why = Open77.npcs.remove(encounter.id)
    if ok and encounters[tostring(encounter.id)] then discard(encounter) end
    return ok, why
end
local function phase(encounter, name, forceReplacement)
    local desired = phaseOrder[name]
    if not desired then return nil, "boss_phase_invalid" end
    local npc = current(encounter)
    if not npc then return nil, "boss_not_found" end
    if forceReplacement or npc.health <= 0 or desired < phaseOrder[phaseName(encounter)] then
        local replacement, why = create(encounter.controller, {position={x=npc.x,y=npc.y,z=npc.z},yaw=npc.yaw,
            bucket=npc.bucket,maxHealth=npc.maxHealth,difficulty=Open77.npcs.getDifficulty(encounter.id),
            damagePolicy=encounter.damagePolicy,aiEnabled=(npc.behavior or {}).aiEnabled ~= false,
            combatEnabled=(npc.behavior or {}).combatEnabled ~= false})
        if not replacement then return nil, why end
        local original = encounter.savedAttitude or Open77.npcs.getAttitude(encounter.id)
        if original then
            Open77.npcs.setAttitude(replacement.id, original.default)
            for id, attitude in pairs(original.players or {}) do Open77.npcs.setAttitude(replacement.id, attitude, {towards={playerId=tonumber(id)}}) end
            for id, attitude in pairs(original.npcs or {}) do Open77.npcs.setAttitude(replacement.id, attitude, {towards={npcId=tonumber(id)}}) end
            for group, attitude in pairs(original.groups or {}) do Open77.npcs.setAttitude(replacement.id, attitude, {towards={group=group}}) end
        end
        if encounter.target then
            local result, targetWhy = setTarget(replacement, encounter.target)
            if not result then remove(replacement); return nil, targetWhy end
        end
        local result, phaseWhy = phase(replacement, name)
        if not result then remove(replacement); return nil, phaseWhy end
        local old = tostring(encounter.id)
        local ok, removeWhy = remove(encounter)
        if not ok then remove(replacement); return nil, removeWhy or "boss_remove_refused" end
        if result then result.replacedId = old end
        return result, phaseWhy
    end
    local percent = ({1,0.7,0.39,0.01})[desired]
    local result, why = setHealth(encounter, npc.maxHealth * percent)
    if not result then return nil, why end
    local previousPhase, previousGas = encounter.phase, encounter.gas
    if desired >= 2 then encounter.phase = desired == 4 and 3 or math.max(encounter.phase,2) end
    if desired >= 3 then encounter.gas = true end
    if encounter.phase ~= previousPhase or encounter.gas ~= previousGas then changed(encounter) end
    return state(encounter)
end
local function spawn(controller, player, options, raw)
    local position = alivePosition(player)
    if not position then return nil, "boss_player_invalid" end
    if options ~= nil and type(options) ~= "table" then return nil, "boss_options_invalid" end
    for _, request in pairs(pending) do
        if request.controller == controller and request.player == tonumber(player) then return nil, "boss_spawn_pending" end
    end
    serial = serial + 1
    local request = {player=tonumber(player),raw=raw,position=position,serial=serial,controller=controller,
        options=options or {},status="pending",createdAt=Open77.time.monotonic()}
    pending[serial], requests[serial] = request, request
    TriggerClientEvent("chimera:probePlacement", player, serial, position)
    CreateThread(function()
        Wait(5000)
        if pending[request.serial] == request then
            pending[request.serial] = nil
            request.status, request.reason = "failed", "boss_spawn_timeout"
            if raw then output(player, raw, false, "placement query timed out") end
        end
    end)
    return serial
end
local function caller() return GetInvokingResource() end
exports("profiles", function() return profiles end)
exports("create", function(options)
    local controller = caller()
    if not controller then return nil, "boss_controller_required" end
    local encounter, why = create(controller, options)
    if not encounter then return nil, why end
    local npc = current(encounter)
    reconcile(encounter, npc, false)
    return state(encounter)
end)
exports("spawn", function(player, options)
    local controller = caller()
    if not controller then return nil, "boss_controller_required" end
    return spawn(controller, player, options)
end)
exports("result", function(id)
    local request = requests[integer(id, 1, 9007199254740991)]
    if not request or request.controller ~= caller() then return nil, "boss_not_owned" end
    return {status=request.status,id=request.id,reason=request.reason}
end)
exports("get", function(id) local e, why = owned(id, caller()); if not e then return nil, why end; return state(e) end)
exports("list", function(options)
    if options ~= nil and type(options) ~= "table" then return nil, "boss_options_invalid" end
    local bucket = options and options.bucket
    if bucket ~= nil then bucket=integer(bucket,0,4294967295); if not bucket then return nil, "boss_options_invalid" end end
    local result, controller = {}, caller()
    for _, e in pairs(encounters) do
        if controller and e.controller == controller and (bucket == nil or e.bucket == bucket) then
            local s = state(e); if s then result[#result+1] = s end
        end
    end
    table.sort(result, function(a,b) return tonumber(a.id) < tonumber(b.id) end)
    return result
end)
exports("remove", function(id) local e, why=owned(id,caller()); if not e then return false,why end; return remove(e) end)
exports("kill", function(id)
    local e, why=owned(id,caller()); if not e then return nil,why end
    local ok=Open77.npcs.kill(e.id); if not ok then return nil,"boss_kill_refused" end
    local npc=current(e); if npc then reconcile(e,npc,false) end
    return state(e)
end)
exports("setHealth", function(id, health, maximum)
    local e, why=owned(id,caller()); if not e then return nil,why end
    return setHealth(e,health,maximum)
end)
exports("applyDamage", function(id, amount)
    local e, why=owned(id,caller()); if not e then return nil,why end
    amount=finite(amount); if not amount or amount <= 0 or amount > 1000000 then return nil,"boss_damage_invalid" end
    if not Open77.npcs.applyDamage(e.id,amount) then return nil,"boss_damage_refused" end
    local npc=current(e)
    if npc then reconcile(e,npc,true) end
    return state(e)
end)
exports("setDifficulty", function(id, difficulty)
    local e, why=owned(id,caller()); if not e then return nil,why end
    local ok, err=Open77.npcs.setDifficulty(e.id,difficulty); if not ok then return nil,err end
    return state(e)
end)
exports("setDamagePolicy", function(id, policy)
    local e, why=owned(id,caller()); if not e then return nil,why end
    if not validPolicy(policy) then return nil,"boss_policy_invalid" end
    if not e.repairing then local ok, err=Open77.npcs.setDamagePolicy(e.id,policy); if not ok then return nil,err end end
    e.damagePolicy=policy
    return state(e)
end)
local function setEnabled(id, value, setter)
    local e, why=owned(id,caller()); if not e then return nil,why end
    if type(value) ~= "boolean" then return nil,"boss_options_invalid" end
    local ok, err=setter(e.id,value); if not ok then return nil,err end
    return state(e)
end
exports("setAIEnabled", function(id,value) return setEnabled(id,value,Open77.npcs.setAIEnabled) end)
exports("setCombatEnabled", function(id,value) return setEnabled(id,value,Open77.npcs.setCombatEnabled) end)
exports("setTarget", function(id,player) local e,why=owned(id,caller()); if not e then return nil,why end; return setTarget(e,player) end)
exports("setPhase", function(id,name) local e,why=owned(id,caller()); if not e then return nil,why end; return phase(e,name) end)
exports("reset", function(id) local e,why=owned(id,caller()); if not e then return nil,why end; return phase(e,"armored",true) end)

RegisterCommand("chimera.spawn", function(player,args,raw)
    if args.n ~= 0 then return output(player,raw,false,"usage: chimera.spawn") end
    local id, why=spawn(GetCurrentResourceName(),player,nil,raw)
    if not id then output(player,raw,false,tostring(why)) end
end, true)
RegisterNetEvent("chimera:placement", function(requestId,direction,groundZ,errorText)
    local request=pending[integer(requestId,1,9007199254740991)]
    if not request or request.player ~= tonumber(source) then return end
    pending[request.serial]=nil
    local position, origin=alivePosition(source),request.position
    local function fail(why)
        request.status,request.reason="failed",why
        if request.raw then output(source,request.raw,false,why) end
    end
    if not position or not near(position,{x=origin.x,y=origin.y,z=origin.z,bucket=origin.bucket},2) then return fail("boss_player_moved") end
    direction,groundZ=integer(direction,0,15),finite(groundZ)
    if not direction or not groundZ or math.abs(groundZ-origin.z)>3 then return fail("boss_placement_invalid") end
    local angle=direction*math.pi/8
    local options={}
    for k,v in pairs(request.options) do options[k]=v end
    options.position={x=origin.x+18*math.cos(angle),y=origin.y+18*math.sin(angle),z=groundZ}
    options.bucket=origin.bucket
    local encounter,why=create(request.controller,options)
    if not encounter then return fail(why or "boss_create_refused") end
    reconcile(encounter,current(encounter),false)
    request.status,request.id="created",tostring(encounter.id)
    if request.raw then output(source,request.raw,true,"created Chimera "..request.id.." (placement is not navmesh-verified)") end
end)
local function commandEncounter(player,args)
    if args.n > 1 then return nil,"usage: provide at most one id" end
    local position=playerPosition(player)
    if not position then return nil,"no Chimera in your bucket" end
    if args.n == 1 then
        local e=encounters[idkey(args[1])]
        if e and e.bucket == position.bucket then return e end
        return nil,"no Chimera with that id in your bucket"
    end
    local found
    for _, e in pairs(encounters) do
        if e.bucket == position.bucket then
            if found then return nil,"multiple Chimeras in your bucket; specify an id" end
            found=e
        end
    end
    return found,found and nil or "no Chimera in your bucket"
end
RegisterCommand("chimera.state", function(player,args,raw)
    local e,why=commandEncounter(player,args); if not e then return output(player,raw,false,why) end
    local s=state(e); if not s then return output(player,raw,false,"boss_not_found") end
    output(player,raw,true,string.format("id=%s health=%.2f phase=%d repairing=%s gas=%s epoch=%s owner=%s parts=[%s]",
        s.id,s.health,s.nativePhase,tostring(s.repairing),tostring(s.gas),s.authority.epoch,s.authority.playerId,table.concat(s.parts,",")))
end,true)
RegisterCommand("chimera.remove", function(player,args,raw)
    local e,why=commandEncounter(player,args); if not e then return output(player,raw,false,why) end
    local ok=remove(e); output(player,raw,ok,ok and "removed" or "remove refused")
end,true)

AddEventHandler("onNpcRemoved", function(id)
    local encounter = encounters[idkey(id)]
    if encounter then discard(encounter) end
end)
AddEventHandler("onNpcAuthorityChanged", function(id, owner, epoch)
    local encounter = encounters[idkey(id)]
    local npc = current(encounter)
    if not npc or tonumber(epoch) ~= tonumber(npc.authorityEpoch) then return end
    publish(encounter)
end)
AddEventHandler("onNpcDamaged", function(id, _, _, health)
    local encounter = encounters[idkey(id)]
    local npc = current(encounter)
    health = finite(health)
    if not npc or not health or math.abs(health-npc.health) > math.max(1, npc.maxHealth) * 0.000001 or encounter.phase == 4 then return end
    reconcile(encounter, npc, true)
end)
AddEventHandler("onNpcUpdated", function(id)
    local encounter = encounters[idkey(id)]
    local npc = current(encounter)
    if not npc then return end
    if npc.health ~= encounter.lastHealth or npc.maxHealth ~= encounter.lastMaxHealth then
        reconcile(encounter, npc, true)
    end
end)
AddEventHandler("onNpcDied", function(id)
    local encounter = encounters[idkey(id)]
    if not encounter or encounter.phase == 4 then return end
    encounter.phase, encounter.repairing, encounter.frame = 4, false, nil
    resetVisuals(encounter, current(encounter) or encounter.lastNpc)
    changed(encounter)
end)
AddEventHandler("onNpcPartHit", function(id, shooter, part, fraction)
    local encounter = encounters[idkey(id)]
    local npc = current(encounter)
    local index = partIndex[tostring(part)]
    fraction = finite(fraction)
    if not npc or npc.health <= 0 or npc.damagePolicy ~= Open77.npcs.damage.mortal or
        not index or not fraction or fraction <= 0 or (encounter.phase ~= 1 and encounter.phase ~= 2) or encounter.repairing then return end
    local before = encounter.parts[index]
    if before <= 0 then return end
    encounter.parts[index] = math.max(0, before - fraction)
    changed(encounter)
    -- Part state saturates at zero, but all admitted damage contributes to health.
    local scale = encounter.phase == 1 and 0.02 or 0.05
    Open77.npcs.applyDamage(encounter.id, npc.maxHealth * scale * fraction, "player:" .. tostring(shooter), "chimera_part")
end)

RegisterNetEvent("chimera:ready", function(id)
    local key = idkey(id)
    if key then
        local encounter = encounters[key]
        local npc = current(encounter)
        if npc then
            expireVisuals(encounter, npc, Open77.time.monotonic())
            send(encounter, npc, source)
            visualSnapshot(encounter, npc, source)
        end
    elseif tostring(id) == "0" then
        for _, encounter in pairs(encounters) do
            local npc = current(encounter)
            if npc then
                expireVisuals(encounter, npc, Open77.time.monotonic())
                send(encounter, npc, source)
                visualSnapshot(encounter, npc, source)
            end
        end
    end
end)

RegisterNetEvent("chimera:hit", function(victim, id, epoch, amount, sequence)
    local encounter = encounters[idkey(id)]
    local npc = current(encounter)
    local victimId = integer(victim, 1, 9007199254740991)
    local seq = integer(sequence, 1, 9007199254740991)
    local reportedEpoch = integer(epoch, 1, 4294967295)
    amount = finite(amount)
    if not npc or encounter.phase == 4 or encounter.repairing or npc.health <= 0 or not victimId or not seq or
        not reportedEpoch or reportedEpoch ~= tonumber(npc.authorityEpoch) or tostring(npc.authorityPlayerId) ~= tostring(source) or
        seq <= encounter.reportSequence or not amount or amount <= 0 or amount > 1000 or
        not near(playerPosition(victimId), npc, 120) then return end
    local reporter = Open77.players.getLifeState(source)
    if not reporter or reporter.bucket ~= npc.bucket then return end
    local behavior = npc.behavior
    if behavior and (behavior.aiEnabled == false or behavior.combatEnabled == false) then return end
    local now = Open77.time.monotonic()
    local report = encounter.reportWindow
    if not report or now < report.at or now - report.at >= 1 then report = { at = now, count = 0 } end
    local window = encounter.victimWindows[victimId]
    if not window or now < window.at or now - window.at >= 1 then window = { at = now, amount = 0 } end
    if report.count >= 120 or window.amount + amount > 2000 then return end
    encounter.reportSequence = seq
    report.count = report.count + 1
    window.amount = window.amount + amount
    encounter.reportWindow, encounter.victimWindows[victimId] = report, window
    local scaled = amount * Open77.npcs.getDifficulty(encounter.id).damageMultiplier
    if scaled > 0 then Open77.players.damage(victimId, scaled, { attacker = npc.id, cause = "firearm" }) end
end)

local featureTypes = {
    ActionAnimation = "animAnimFeature_AIActionAnimation", ShootAction = "animAnimFeature_AIAction",
    ShootAttack = "animAnimFeature_AIAction", MeleeAttack = "animAnimFeature_AIAction",
    upperBodyState = "animAnimFeature_NPCState", locomotion = "animAnimFeature_Locomotion",
    RightWeaponData = "gameweaponAnimFeature_WeaponData",
}
local featureFields = {
    ActionAnimation = { state = true, animVariation = true, stateDuration = true, animFeatureName = true },
    ShootAction = { state = true, animVariation = true, stateDuration = true },
    ShootAttack = { state = true, animVariation = true, stateDuration = true },
    MeleeAttack = { state = true, animVariation = true, stateDuration = true },
    upperBodyState = { state = true },
    locomotion = { action = true, style = true, pathCurvature = true, inclineAngle = true, groundAngle = true,
        animDeltaZ = true, animationPlaybackTime = true, footScaleFactor = true, directionalStartAngle = true,
        speedProgress = true, isOnStairs = true, areAnimWrappersUnlocked = true },
    RightWeaponData = { cycleTime = true, chargePercentage = true, timeInMaxCharge = true, ammoRemaining = true,
        triggerMode = true, isMagazineFull = true, isTriggerDown = true },
}
-- TweakDBIDs of the 20 authored AttachmentSlots records; 0 means the boss.
local effectSlots = {
    ["0"]=true, ["164872425163"]=true, ["170781943869"]=true, ["149110779234"]=true,
    ["142661270891"]=true, ["143080473677"]=true, ["140709791448"]=true,
    ["124496781344"]=true, ["124918209719"]=true, ["142851780285"]=true,
    ["140930116648"]=true, ["139043457285"]=true, ["180340847129"]=true,
    ["193453380568"]=true, ["95759055284"]=true, ["118132580004"]=true,
    ["122127764809"]=true, ["93195047309"]=true, ["102855287901"]=true,
    ["134141259435"]=true, ["118070326407"]=true,
}
local parameterNames = { twitch_hit_scale = true, pla_left_hand_attach = true, pla_right_hand_attach = true }
local function scalar(value)
    local kind = type(value)
    if kind == "boolean" then return true end
    if kind == "number" then return finite(value) ~= nil and math.abs(value) <= 1000000 end
    return kind == "string" and #value <= 256 and not value:find("[%c]")
end
local function array(value, maximum)
    if type(value) ~= "table" then return false end
    local count = 0
    for k in pairs(value) do
        if type(k) ~= "number" or k % 1 ~= 0 or k < 1 or k > maximum then return false end
        count = count + 1
    end
    return count <= maximum and count == #value
end
local visualFields = { id = true, kind = true, phase = true, position = true, rotation = true,
    target = true, normal = true, trail = true, indicator = true }
local function visualVector(value, size, limit)
    if not array(value, size) or #value ~= size then return false end
    for _, n in ipairs(value) do
        if type(n) ~= "number" or not finite(n) or math.abs(n) > limit then return false end
    end
    return true
end
local function visualDistance(a, b)
    return (a[1]-b[1])^2 + (a[2]-b[2])^2 + (a[3]-b[3])^2
end
local function validVisuals(payload, npc, encounter)
    if type(payload) ~= "table" or not array(payload.states, 32) then return false end
    for key in pairs(payload) do if key ~= "states" then return false end end
    local seen, count = {}, encounter.visualCount
    local boss = { npc.x, npc.y, npc.z }
    for _, row in ipairs(payload.states) do
        if type(row) ~= "table" then return false end
        for key in pairs(row) do if not visualFields[key] then return false end end
        if type(row.id) ~= "number" or not integer(row.id, 1, 4294967295) or seen[row.id] or
            type(row.kind) ~= "number" or not integer(row.kind, 1, 9) or
            type(row.phase) ~= "number" or not integer(row.phase, 1, 4) or
            type(row.trail) ~= "boolean" or type(row.indicator) ~= "boolean" or
            not visualVector(row.position, 3, 1000000) or not visualVector(row.target, 3, 1000000) or
            not visualVector(row.rotation, 4, 1.5) or not visualVector(row.normal, 3, 1.5) then return false end
        seen[row.id] = true
        local norm = 0
        for _, n in ipairs(row.rotation) do norm = norm + n*n end
        local normal = row.normal[1]^2 + row.normal[2]^2 + row.normal[3]^2
        local bullet, marker = row.kind == 7, row.kind == 9
        if norm < 0.25 or norm > 2.25 or visualDistance(row.position, boss) > 300^2 or
            visualDistance(row.target, boss) > 300^2 or
            (row.kind <= 2 and visualDistance(row.position, row.target) > 250^2) or
            (row.phase == 2 and row.kind ~= 5) or
            (row.phase == 4 and row.kind ~= 4 and row.kind ~= 5 and row.kind ~= 6 and not bullet) or
            (bullet and row.phase < 3) or
            (bullet and row.phase == 4 and (normal < 0.25 or normal > 2.25)) or
            (not (bullet and row.phase == 4) and
                (row.normal[1] ~= 0 or row.normal[2] ~= 0 or row.normal[3] ~= 0)) or
            ((row.kind <= 3 or row.kind == 7 or row.kind == 8 or row.phase >= 3) and (row.trail or row.indicator)) or
            (marker and (row.trail or row.indicator ~= (row.phase == 1) or
                row.position[1] ~= row.target[1] or row.position[2] ~= row.target[2] or row.position[3] ~= row.target[3] or
                row.rotation[1] ~= 0 or row.rotation[2] ~= 0 or row.rotation[3] ~= 0 or row.rotation[4] ~= 1)) then return false end
        local previous = encounter.visuals[row.id]
        local terminal = encounter.visualTombstones[row.id]
        if terminal then
            if row.kind ~= terminal.kind then return false end
        elseif previous then
            if row.kind ~= previous.row.kind or (previous.row.phase == 2 and row.phase == 1) then return false end
            if row.phase >= 3 then count = count - 1 end
        elseif row.id > encounter.visualFloor then
            if row.phase < 3 then count = count + 1 end
        end
    end
    return count <= 128
end
RegisterNetEvent("chimera:visuals", function(id, epoch, sequence, text)
    local encounter = encounters[idkey(id)]
    local npc = current(encounter)
    local seq = integer(sequence, 1, 9007199254740991)
    local reportedEpoch = integer(epoch, 1, 4294967295)
    if not npc or encounter.phase == 4 or npc.health <= 0 or not seq or seq <= encounter.visualSequence or
        not reportedEpoch or reportedEpoch ~= tonumber(npc.authorityEpoch) or
        tostring(npc.authorityPlayerId) ~= tostring(source) or type(text) ~= "string" or #text > 16384 then return end
    local ok, payload = pcall(json.decode, text)
    if not ok or not validVisuals(payload, npc, encounter) then return end
    local now = Open77.time.monotonic()
    local tokens = math.min(16, encounter.visualTokens + math.max(0, now - encounter.visualAt) * 80)
    if tokens < 1 then return end
    local relay = {}
    for _, row in ipairs(payload.states) do
        local previous = encounter.visuals[row.id]
        if not encounter.visualTombstones[row.id] and (previous or row.id > encounter.visualFloor) then
            if row.phase >= 3 then
                if previous then
                    encounter.visuals[row.id] = nil
                    encounter.visualCount = encounter.visualCount - 1
                end
                visualTombstone(encounter, row)
            else
                if not previous then encounter.visualCount = encounter.visualCount + 1 end
                encounter.visuals[row.id] = { row = row, at = now }
            end
            relay[#relay + 1] = row
        end
    end
    encounter.visualSequence, encounter.visualTokens, encounter.visualAt = seq, tokens - 1, now
    if #relay > 0 then visualBroadcast(encounter, npc, relay, false, false) end
end)
local function validFrame(payload, npc)
    if type(payload) ~= "table" or not array(payload.features, 12) or not array(payload.parameters, 16) then return false end
    for k in pairs(payload) do
        if k ~= "target" and k ~= "features" and k ~= "parameters" and k ~= "shots" and k ~= "effects" and k ~= "audio" then return false end
    end
    if not array(payload.audio, 3) or #payload.audio ~= 3 then return false end
    for _, cue in ipairs(payload.audio) do
        if type(cue) ~= "table" or type(cue.revision) ~= "number" or
            not integer(cue.revision, 0, 4294967295) or type(cue.active) ~= "boolean" or
            (cue.revision == 0 and cue.active) then return false end
        for k in pairs(cue) do if k ~= "revision" and k ~= "active" then return false end end
    end
    if payload.shots ~= nil then
        if not array(payload.shots, 19) or #payload.shots ~= 19 then return false end
        for _, count in ipairs(payload.shots) do
            if type(count) ~= "number" or not integer(count, 0, 4294967295) then return false end
        end
    end
    if payload.effects ~= nil then
        if not array(payload.effects, 32) then return false end
        local effects = {}
        for _, effect in ipairs(payload.effects) do
            if type(effect) ~= "table" or type(effect.slot) ~= "string" or not effectSlots[effect.slot] or
                type(effect.name) ~= "string" or #effect.name == 0 or #effect.name > 64 or
                not effect.name:match("^[a-zA-Z0-9_]+$") or type(effect.revision) ~= "number" or
                not integer(effect.revision, 1, 4294967295) or type(effect.active) ~= "boolean" then return false end
            local key = effect.slot .. ":" .. effect.name
            if effects[key] then return false end
            effects[key] = true
            for k in pairs(effect) do
                if k ~= "slot" and k ~= "name" and k ~= "revision" and k ~= "active" then return false end
            end
        end
    end
    local target = integer(payload.target, 0, 9007199254740991)
    if not target or (target ~= 0 and not near(playerPosition(target), npc, 60)) then return false end
    local seen = {}
    for _, feature in ipairs(payload.features) do
        if type(feature) ~= "table" or type(feature.name) ~= "string" or not featureTypes[feature.name] or
            featureTypes[feature.name] ~= feature.type or seen[feature.name] or
            not integer(feature.revision, 1, 9007199254740991) or type(feature.fields) ~= "table" then return false end
        seen[feature.name] = true
        for k in pairs(feature) do if k ~= "name" and k ~= "type" and k ~= "revision" and k ~= "fields" then return false end end
        local count = 0
        for name, value in pairs(feature.fields) do
            count = count + 1
            if count > 32 or type(name) ~= "string" or not featureFields[feature.name][name] or not scalar(value) then return false end
        end
    end
    seen = {}
    for _, parameter in ipairs(payload.parameters) do
        if type(parameter) ~= "table" or not parameterNames[parameter.name] or seen[parameter.name] then return false end
        seen[parameter.name] = true
        for k in pairs(parameter) do if k ~= "name" and k ~= "type" and k ~= "value" then return false end end
        if parameter.type == "bool" then
            if type(parameter.value) ~= "boolean" then return false end
        elseif parameter.type == "float" or parameter.type == "int" then
            if type(parameter.value) ~= "number" or not scalar(parameter.value) or
                (parameter.type == "int" and parameter.value % 1 ~= 0) then return false end
        else return false end
    end
    return true
end
RegisterNetEvent("chimera:frame", function(id, epoch, sequence, text)
    local encounter = encounters[idkey(id)]
    local npc = current(encounter)
    local seq = integer(sequence, 1, 9007199254740991)
    local reportedEpoch = integer(epoch, 1, 4294967295)
    if not npc or encounter.phase == 4 or not seq or seq <= encounter.frameSequence or not reportedEpoch or
        reportedEpoch ~= tonumber(npc.authorityEpoch) or tostring(npc.authorityPlayerId) ~= tostring(source) or
        type(text) ~= "string" or #text > 16384 then return end
    local ok, payload = pcall(json.decode, text)
    if not ok or not validFrame(payload, npc) then return end
    for _, feature in ipairs(payload.features) do
        if feature.revision < (encounter.featureRevisions[feature.name] or 0) then return end
    end
    for i, cue in ipairs(payload.audio) do
        local previous = encounter.audio[i]
        if cue.revision < previous.revision or
            (cue.revision == previous.revision and cue.active ~= previous.active) then return end
    end
    local effects, newEffects = payload.effects or {}, 0
    for _, effect in ipairs(effects) do
        local key = effect.slot .. ":" .. effect.name
        local previous = encounter.effectRevisions[key]
        if previous then
            if effect.revision < previous.revision or
                (effect.revision == previous.revision and effect.active ~= previous.active) then return end
        else
            newEffects = newEffects + 1
        end
    end
    if encounter.effectCount + newEffects > 32 then return end
    local now = Open77.time.monotonic()
    local tokens = math.min(4, encounter.frameTokens + math.max(0, now - encounter.frameAt) * 20)
    if tokens < 1 then return end
    local shots = payload.shots or {0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0}
    local shotCount = 0
    for i = 1, 19 do
        local delta = (shots[i] - encounter.shots[i]) % 4294967296
        shotCount = shotCount + delta
        if shotCount > 120 then return end
    end
    local shotWindow = encounter.shotWindow
    if not shotWindow or now < shotWindow.at or now - shotWindow.at >= 1 then shotWindow = {at = now, count = 0} end
    if shotWindow.count + shotCount > 120 then return end
    local previous = encounter.frame
    encounter.frame = { sequence = seq, serverUs = math.floor(now * 1000000), target = payload.target,
        features = payload.features, parameters = payload.parameters, shots = shots, effects = effects, audio = payload.audio }
    -- TriggerClientEvent also bounds each string argument to 16 KiB. Reserve
    -- room for the revision increment and refuse a frame that cannot be sent.
    local encodable, encoded = pcall(encodeSnapshot, encounter, npc)
    if not encodable or #encoded > 16352 then encounter.frame = previous; return end
    encounter.frameTokens, encounter.frameAt = tokens - 1, now
    shotWindow.count = shotWindow.count + shotCount
    encounter.shots, encounter.shotWindow = shots, shotWindow
    encounter.frameSequence = seq
    encounter.audio = payload.audio
    for _, feature in ipairs(payload.features) do encounter.featureRevisions[feature.name] = feature.revision end
    for _, effect in ipairs(effects) do
        local key = effect.slot .. ":" .. effect.name
        encounter.effectRevisions[key] = { revision = effect.revision, active = effect.active }
    end
    encounter.effectCount = encounter.effectCount + newEffects
    changed(encounter)
end)

AddEventHandler("onPlayerDisconnected", function(player)
    for id, request in pairs(pending) do
        if request.player == tonumber(player) then
            pending[id]=nil
            request.status,request.reason="failed","boss_player_invalid"
        end
    end
    for _, encounter in pairs(encounters) do
        if encounter.target == tonumber(player) then setTarget(encounter,nil) end
    end
end)
local stopped = false
AddEventHandler("onResourceStop", function(name)
    for id, request in pairs(requests) do
        if name == GetCurrentResourceName() or request.controller == name then pending[id],requests[id]=nil,nil end
    end
    if name == GetCurrentResourceName() then stopped = true end
    for _, encounter in pairs(encounters) do
        if stopped or encounter.controller == name then remove(encounter) end
    end
end)
CreateThread(function()
    while not stopped do
        Wait(500)
        if stopped then return end
        local now = Open77.time.monotonic()
        for id, request in pairs(requests) do
            if request.status ~= "pending" and now - request.createdAt >= 60 then requests[id] = nil end
        end
        for _, encounter in pairs(encounters) do
            local npc = current(encounter)
            if npc then
                expireVisuals(encounter, npc, now)
                local life = encounter.target and Open77.players.getLifeState(encounter.target)
                if encounter.target and (not life or life.phase ~= "alive" or not near(playerPosition(encounter.target), npc, 60)) then setTarget(encounter,nil) end
            else discard(encounter) end
        end
    end
end)
print("[chimera] encounter resource ready; no automatic spawn")
