-- Player hits pass through this arbiter; scripted damage has its own authority.
local K = Cordon

function K.arbitrateDamage(event)
    if K.match == nil or not K.match.isLive() then return false end
    local victim = K.players[tonumber(event.victim) or 0]
    local attacker = K.players[tonumber(event.attacker) or 0]
    if victim == nil or attacker == nil then return false end
    local downed = victim.state == "dead" and K.squads and K.squads.revivable(victim)
    if (victim.state ~= "alive" and not downed) or attacker.state ~= "alive" then return false end
    if K.shielded(victim.id) then return false end
    if victim.id ~= attacker.id and victim.squad ~= nil and victim.squad == attacker.squad then
        return false
    end

    K.breakShield(attacker.id)

    -- The host event has no verifiedForAttacker field. Only the match's
    -- completed weapon assignments establish ownership, including when empty.
    -- Unarmed melee and environmental damage retain their platform pricing.
    local weapon = K.weaponId(event.weaponTdbId)
    if event.attackKind == "ranged" or weapon ~= "" then
        if not K.weaponVerified(attacker, weapon) then
            K.log(("refused: player %d fired an unverified weapon %s at %d"):format(
                attacker.id, tostring(event.weaponTdbId), victim.id))
            return false
        end
    end
    return nil
end

Open77.combat.onDamage(K.arbitrateDamage)
