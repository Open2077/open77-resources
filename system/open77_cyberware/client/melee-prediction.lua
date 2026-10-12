-- Presentation admission only. Mirrors the observations sent to the server,
-- including misses; it neither spends stamina nor authorizes a native attack.
CyberwareMeleePrediction = {}
local current
local function finite(n) return type(n)=="number" and n==n and math.abs(n)<math.huge end
function CyberwareMeleePrediction.clear() current=nil end
function CyberwareMeleePrediction.observe(incarnation,grade,attack,stamp,health)
    if not incarnation or type(grade)~="table" or not finite(stamp) then current=nil;return end
    if not current or current.incarnation~=incarnation or current.grade~=grade then
        current={incarnation=incarnation,grade=grade}
    end
    local s=current
    if s.sampleAt and (stamp<s.sampleAt or stamp-s.sampleAt>1500) then
        s.holding=false;s.holdAt=nil;s.accepted=nil
    end
    s.sampleAt=stamp
    if not attack then s.armed=false;s.holding=false;s.holdAt=nil;s.accepted=nil;return end
    if not finite(attack.sequence) or attack.sequence%1~=0 or attack.sequence<0 or attack.sequence>4294967295 then return end
    if not s.armed then
        s.armed=true;s.sequence=attack.sequence;s.holding=attack.holding
        s.holdAt=attack.holding and stamp or nil;s.accepted=nil
        return -- drawing a weapon must not replay its preceding swing
    end
    if attack.sequence==s.sequence then
        if attack.holding and not s.holding then s.holdAt=stamp end
        s.holding=attack.holding
        if not attack.holding then s.holdAt=nil end
        return
    end
    local advance=(attack.sequence-s.sequence)%4294967296
    local held=s.holding and s.holdAt and stamp-s.holdAt or 0
    s.sequence=attack.sequence;s.accepted=nil;s.holding=false;s.holdAt=nil
    if advance>16 or attack.sequence==0 or attack.holding or attack.chargeExpired
        or (attack.variant~=0 and attack.variant~=1 and attack.variant~=2 and attack.variant~=6) then return end
    if not finite(grade.cooldownMs) or grade.cooldownMs<100
        or (s.attackAt and stamp-s.attackAt<grade.cooldownMs) then return end
    local charged=attack.variant==1
    if charged and (not finite(grade.chargeMs) or not finite(grade.maxChargeMs)
        or held<grade.chargeMs or held>grade.maxChargeMs) then return end
    local cost=grade.normalStaminaCost
    if charged then cost=grade.chargedStaminaCost end
    if cost~=nil and (not finite(cost) or cost<0) then return end
    if cost and cost>0 then
        if type(health)~="table" or not finite(health.stamina) or not finite(health.staminaAuthorityRevision) then return end
        -- Do not reuse the same unacknowledged stamina for successive swings.
        -- The server debits each swing separately, without a new authority
        -- revision: a published drop retires, oldest first, only the swings it
        -- accounts for; regeneration retires none. A swing older than 2 s has
        -- been debited or refused by then (review #14, F14).
        if s.staminaRevision~=health.staminaAuthorityRevision then
            s.staminaRevision=health.staminaAuthorityRevision;s.staminaSeen=health.stamina;s.reservations={}
        end
        local reservations=s.reservations or {}
        s.reservations=reservations
        if s.staminaSeen and health.stamina<s.staminaSeen then
            local drop=s.staminaSeen-health.stamina
            while reservations[1] and reservations[1].cost<=drop+0.001 do
                drop=drop-reservations[1].cost;table.remove(reservations,1)
            end
        end
        s.staminaSeen=health.stamina
        while reservations[1] and stamp-reservations[1].at>2000 do table.remove(reservations,1) end
        local reserved=0
        for _,r in ipairs(reservations) do reserved=reserved+r.cost end
        if health.stamina-reserved<cost then return end
        reservations[#reservations+1]={cost=cost,at=stamp}
    end
    s.attackAt=stamp;s.accepted=attack.sequence
end
function CyberwareMeleePrediction.allows(incarnation,grade,attack,stamp,health)
    CyberwareMeleePrediction.observe(incarnation,grade,attack,stamp,health)
    return current and attack and current.accepted==attack.sequence
        and stamp-current.attackAt<=1500 or false
end
