-- The host emits JSON context strings and sends playerDied before playerKilled.
-- Consume the killer from the first event so the idempotent death transition
-- cannot erase attribution while waiting for the second notification.
local K = Cordon

function K.handleDeath(victimId, killerId, context)
    local victim = K.ensure(victimId)
    if not victim or victim.state ~= "alive" or K.deathSuppressed(victim.id) then return end
    if type(context) == "string" then
        local ok, decoded = pcall(json.decode, context)
        context = ok and decoded or nil
    end
    if type(context) ~= "table" then
        local ok, life = pcall(Open77.players.getLifeState, victim.id)
        context = ok and type(life) == "table" and life or {}
    end
    local cause = tostring(context.cause or "unknown")
    local weapon = tostring(context.weapon or "")
    if cause == "script" or weapon:find("^cordon:") or weapon:find("^cordonlab:") then return end
    local rawKiller = killerId or context.killer
    local killer = rawKiller and K.bots.attackerId(rawKiller)
    if killer == 0 or not K.players[killer] then killer = nil end
    K.match.onDeath(victim, killer, cause)
end

AddEventHandler("open77:playerDied", function(victimId, context)
    K.handleDeath(victimId, nil, context)
end)
AddEventHandler("open77:playerKilled", K.handleDeath)
