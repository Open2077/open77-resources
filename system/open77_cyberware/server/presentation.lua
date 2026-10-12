-- A consumer of the same public APIs exposed to server makers. No private
-- event, native handle, damage rule or implant grant belongs in this layer.
local active = {}
local lastNotice = {}
local rejectedHolds = {}
local hitSounds = {}
local function holdIdentity(activity)
    return tostring(activity.incarnation) .. ":" .. tostring(activity.sequence) .. ":" .. tostring(activity.holdAt)
end
local function retire(player)
    local effect = active[player]
    if effect then Open77.effects.remove(effect.id); active[player] = nil end
end

local function preset(activity)
    local config = CyberwarePresentation
    if not config or config.enabled ~= true then return nil end
    local definition = (config.definitions or {})[activity.definition]
    if definition == false then return nil end
    local grade = definition and definition[activity.grade]
    if grade == nil then grade = (config.grades or {})[activity.grade] end
    if type(grade) ~= "table" or grade.enabled ~= true then return nil end
    local result = {}
    for name, value in pairs(config.defaults or {}) do result[name] = value end
    for name, value in pairs(grade) do result[name] = value end
    return result
end

CreateThread(function()
    while true do
        local present = {}
        for _, player in ipairs(Open77.cyberware.activityPlayers() or {}) do
            present[player] = true
            local activity = Open77.cyberware.activity(player)
            local style = activity and preset(activity)
            if not activity or not style or activity.armed ~= true or activity.holding ~= true
                or activity.chargeExpired == true or type(activity.remainingMs) ~= "number"
                or activity.remainingMs <= 0 or (style.chargedOnly and activity.charged ~= true) then
                retire(player)
                rejectedHolds[player] = nil
            else
                local hold = holdIdentity(activity)
                if active[player] and active[player].hold ~= hold then retire(player) end
                if rejectedHolds[player] ~= hold then rejectedHolds[player] = nil end
                if not active[player] and rejectedHolds[player] ~= hold then
                    -- One native graph for this bounded hold; do not refresh a
                    -- short native lease and restart particles every heartbeat.
                    local id = Open77.effects.attach({kind="player",id=tostring(player)}, style.effect, {
                        slot=style.slot, localAnchor=style.localAnchor, localSlot=style.localSlot,
                        localEvent=style.localEvent,
                        soundEvent=type(style.chargeSoundEvent) == 'string' and style.chargeSoundEvent or nil,
                        soundOnOwner=style.soundOnOwner ~= false,
                        ttlMs=math.floor(math.min(activity.remainingMs + 250, 60250)),
                        streamingRadius=style.streamingRadius or 90,
                        streamingHysteresis=style.streamingHysteresis or 20,
                    })
                    if id then active[player] = {id=id,hold=hold} end
                end
            end
        end
        for player in pairs(active) do if not present[player] then retire(player) end end
        for player in pairs(rejectedHolds) do if not present[player] then rejectedHolds[player] = nil end end
        Wait(math.max(50, math.min(500, tonumber(CyberwarePresentation.pollMs) or 100)))
    end
end)

AddEventHandler("playerDropped", function()
    local player=tonumber(source)
    if not player then return end
    retire(player);lastNotice[player]=nil;rejectedHolds[player]=nil
end)

-- Public server-local accepted-contact snapshot; never infer the grade from a
-- later activity sample or accept a client-authored damage/audio assertion.
AddEventHandler("onCyberwareMeleeHit", function(victim, attacker, encoded)
    local ok, hit = pcall(json.decode, encoded)
    if not ok or type(hit) ~= 'table' or type(hit.sequence) ~= 'number'
        or type(hit.incarnation) ~= 'string' or type(hit.instanceId) ~= 'string'
        or type(hit.amount) ~= 'number' then return end
    local style = preset(hit)
    if not style or (hit.amount <= 0 and style.soundOnZeroDamage ~= true) then return end
    local event = type(style.impactSoundsByBodyPart) == 'table' and style.impactSoundsByBodyPart[hit.bodyPart]
        or style.impactSoundEvent
    if type(event) ~= 'string' or event == '' then return end
    local now, count = GetGameTimer(), 0
    for key, at in pairs(hitSounds) do
        if now-at >= 60000 then hitSounds[key] = nil else count=count+1 end
    end
    local key = tostring(attacker)..':'..hit.incarnation..':'..hit.instanceId..':'..hit.sequence..':'..tostring(victim)
    -- Retain a minute of accepted actions at the intended 32-player alpha
    -- population; the generic sound service enforces the same resource bound.
    if hitSounds[key] or count >= 4096 then return end
    local duration = math.max(.05, math.min(60, tonumber(style.impactSoundDuration) or 5))
    local excluded = {}
    if style.impactSoundOnAttacker == false then excluded[#excluded+1] = tostring(attacker) end
    if style.impactSoundOnVictim == false and (tostring(victim) ~= tostring(attacker) or #excluded == 0) then
        excluded[#excluded+1] = tostring(victim)
    end
    if Open77.effects.sound({kind='player',id=tostring(victim)}, event,
        {duration=duration,actionId=key,excludePlayers=excluded}) then
        hitSounds[key] = now
    end
end)

-- Server-local authority event, deliberately not a RegisterNetEvent ingress.
AddEventHandler("onCyberwareActionRejected", function(player, sequence, reason)
    player = tonumber(player)
    if not player or player <= 0 then return end
    local activity = Open77.cyberware.activity(player)
    if activity and activity.holding then rejectedHolds[player] = holdIdentity(activity) end
    retire(player)
    local feedback = CyberwarePresentation.feedback
    local message = feedback and feedback.enabled == true and (feedback.messages or {})[reason]
    if type(message) ~= "string" then return end
    local now = GetGameTimer()
    local interval = math.max(0, tonumber(feedback.intervalMs) or 1000)
    if lastNotice[player] and now - lastNotice[player] < interval then return end
    lastNotice[player] = now
    TriggerClientEvent("chat:addMessage", player, {args={"Cyberware",message},color={34,216,226}})
end)

AddEventHandler("onResourceStop", function(name)
    if name ~= GetCurrentResourceName() then return end
    for player in pairs(active) do retire(player) end
    lastNotice = {}
    rejectedHolds = {}
    hitSounds = {}
end)

-- Car-impact fall cue. PlayerPuppet.OnCarHitPlayer knocks only the victim's
-- own body down; observers play the fall as a pose-only reaction on its proxy.
-- The server decides that a fall happened, not the client: the damage ledger
-- must have reached a verdict on the victim's car-impact report (the host's
-- open77:playerHitByVehicle) for a body that is still alive. That holds
-- whether the hit stayed the victim's own environment hit or was credited to
-- the driver the server found (server option combat.vehicleHitCreditsDriver).
--
-- The fall is physics, the damage is policy. The native knockdown plays on
-- the victim whether or not the ledger lets the 10 HP land, so a safe zone, a
-- "PvP off" arbiter, god mode or a friendly-fire refusal must not leave every
-- other screen -- the driver's first -- with a body that merely slides beside
-- the car. A "damaged" verdict is enough on its own; a verdict that cost the
-- victim nothing is accepted only when the server itself found the vehicle
-- that struck it (impact.vehicle ~= 0), so a free self report next to no car
-- still buys no fall pose.
--
-- The victim's net event carries nothing but the cosmetic fall direction and
-- is paired with that verdict; the two travel separately, so either may
-- arrive first. The cue goes only to players of the victim's routing bucket
-- near it, once per knockdown pose.
local CAR_IMPACT_PAIR_MS = 1000   -- accepted report <-> direction event
local CAR_IMPACT_POSE_MS = 3000   -- the native knockdown pose (vanilla cooldown: 5 s)
local CAR_IMPACT_RADIUS = 150     -- metres around the victim
local carImpacts = {}
local function fresh(at, now) return at ~= nil and now - at <= CAR_IMPACT_PAIR_MS end
local function carImpactCue(player)
    local state, now = carImpacts[player], GetGameTimer()
    if not state or not fresh(state.acceptedAt, now) or not state.direction
        or not fresh(state.direction.at, now) then return end
    if state.cuedAt and now - state.cuedAt < CAR_IMPACT_POSE_MS then return end
    local life = Open77.players.getLifeState(player)
    if type(life) ~= "table" or (life.phase ~= "alive" and life.phase ~= "recovering") then return end
    local direction = state.direction
    state.acceptedAt, state.direction, state.cuedAt = nil, nil, now
    -- Same bucket as the victim by default; the victim itself is excluded.
    local observers = Open77.players.nearby(player, CAR_IMPACT_RADIUS)
    if type(observers) ~= "table" then return end
    local cue = {player=player, directionX=direction.x, directionY=direction.y}
    for _, observer in ipairs(observers) do
        TriggerClientEvent("open77_cyberware:carImpactSeen", observer.playerId, cue)
    end
end
local function carImpactState(player)
    local state = carImpacts[player]
    if not state then state = {}; carImpacts[player] = state end
    return state
end
-- The verdicts DamageAuthorityService.ApplyVehicleImpact records that leave
-- the victim standing: an arbiter's cancel and the three protections.
local CAR_IMPACT_UNHARMED = {cancelled=true, god_mode=true, friendly_fire_disabled=true, same_team=true}
-- Server-local host event (the open77:player* prefix is reserved to the host).
-- A lethal impact ends in a ragdoll and a downed one in the downed pose, not a
-- knockdown.
AddEventHandler("open77:playerHitByVehicle", function(victim, _, vehicle, impact)
    local player = tonumber(victim)
    if not player or player <= 0 or type(impact) ~= "table"
        or impact.lethal == true or impact.downed == true then return end
    local struck = (tonumber(vehicle) or 0) > 0
    if impact.outcome ~= "damaged" and not (struck and CAR_IMPACT_UNHARMED[impact.outcome]) then return end
    carImpactState(player).acceptedAt = GetGameTimer()
    carImpactCue(player)
end)
RegisterNetEvent("open77_cyberware:carImpact", function(value)
    local player = tonumber(source)
    if not player or player <= 0 or type(value) ~= "table" then return end
    local x, y = tonumber(value.directionX), tonumber(value.directionY)
    if not x or not y or x ~= x or y ~= y or math.abs(x) > 1.01 or math.abs(y) > 1.01 then return end
    carImpactState(player).direction = {x=x, y=y, at=GetGameTimer()}
    carImpactCue(player)
end)
AddEventHandler("playerDropped", function() local player = tonumber(source); if player then carImpacts[player] = nil end end)
