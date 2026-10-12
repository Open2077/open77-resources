-- Engine hit reports, validated against this match's NPC and player ledgers.
-- These are reports of resolved hits, never a timer that invents attacks.
local K = Cordon
local windows, pairsAt = {}, {}

local function finite(value)
    local n = tonumber(value)
    if n == nil or n ~= n or n == math.huge or n == -math.huge then return nil end
    return n
end

local function livePlayer(id)
    local record = K.players[tonumber(id) or 0]
    if not K.match or not K.match.isLive() or not record or record.state ~= "alive" then return nil end
    local position = K.position(record.id)
    if not position or position.bucket ~= K.matchBucket() then return nil end
    return record, position
end

local function npc(id)
    local bot, participant = K.bots.get(id)
    local camp = K.holdouts.get(id)
    if not bot and not camp then return nil end
    local ok, state = pcall(Open77.npcs.get, id)
    if not ok or not state or state.bucket ~= K.matchBucket() or state.health <= 0 then return nil end
    return state, participant, camp
end

local function near(a, b, radius)
    local ax, ay, az = finite(a.x), finite(a.y), finite(a.z)
    local bx, by, bz = finite(b.x), finite(b.y), finite(b.z)
    if not ax or not ay or not az or not bx or not by or not bz then return false end
    return (ax-bx)^2 + (ay-by)^2 + (az-bz)^2 <= radius^2
end

local function sameSquad(a, b)
    local left, right = K.players[a], K.players[b]
    return left and right and left.squad ~= nil and left.squad == right.squad
end

local function bounded(key, pair, amount, ceiling, interval)
    local now = K.nowMs()
    if pairsAt[pair] and now - pairsAt[pair] < interval then return false end
    local window = windows[key]
    if not window or now - window.at >= 1000 then
        window = { at = now, amount = 0 }
        windows[key] = window
    end
    if window.amount + amount > ceiling then return false end
    window.amount = window.amount + amount
    pairsAt[pair] = now
    return true
end

RegisterNetEvent("cordon:npcHit", function(npcId, damage, hitZ, weaponTdbId)
    local player, position = livePlayer(source)
    if not player then return end
    local target, participant = npc(npcId)
    if not target or not near(position, target, 120) or sameSquad(player.id, participant) then return end
    if not K.weaponVerified(player, weaponTdbId) then return end
    local reported = finite(damage)
    if not reported or reported < 0 then return end
    local config = Config.bots or {}
    local amount = tonumber(config.hitDamage) or 34
    local z = finite(hitZ)
    if z and z - target.z >= (tonumber(config.headHeight) or 1.5) then
        amount = amount * (tonumber(config.headshotMultiplier) or 2)
    end
    amount = math.min(amount, tonumber(config.maxHitDamage) or 200)
    if not bounded("npc:" .. tostring(npcId), "shot:" .. player.id .. ":" .. tostring(npcId), amount, 300, 90) then return end
    K.breakShield(player.id)
    K.bots.noteHit(npcId, player.id)
    Open77.npcs.applyDamage(target.id, amount, tostring(player.id), "player")
end)

local function authoritativePlayerHits(attacker)
    local ok, loadout = pcall(json.decode, tostring(attacker.loadout or ""))
    return ok and type(loadout) == "table" and type(loadout.combat) == "table"
        and loadout.combat.authoritativePlayerHits == true
end

local function damagePlayer(player, attacker, participant, damage)
    local behavior = attacker.behavior
    if behavior and (behavior.aiEnabled == false or behavior.combatEnabled == false) then return end
    if K.shielded(player.id) or sameSquad(player.id, participant) then return end
    local amount = finite(damage)
    if not amount or amount < 0 then return end
    local config = ((Config.bots or {}).combat or {}).incoming or {}
    if amount == 0 or config.useEngineAmount == false then amount = tonumber(config.fallbackDamage) or 18 end
    amount = math.min(amount * (tonumber(config.scale) or 1), tonumber(config.maxPerHit) or 34)
    if amount <= 0 or not bounded("player:" .. player.id, "incoming:" .. player.id .. ":" .. tostring(attacker.id),
        amount, tonumber(config.maxDamagePerSecond) or 90, tonumber(config.minIntervalMs) or 90) then return end
    amount = K.loot.absorbWithShield({ victim = player.id, attacker = participant, amount = amount }) or amount
    if amount <= 0 then return end
    local ok, reason = Open77.players.damage(player.id, amount, { attacker = attacker.id, cause = "firearm" })
    if not ok then K.warn("npc damage refused: " .. tostring(reason)) end
end

RegisterNetEvent("cordon:npcHurtMe", function(npcId, damage)
    local player, position = livePlayer(source)
    if not player then return end
    local attacker, participant = npc(npcId)
    -- Old clients/witnesses cannot add a second report for an opted-in camp.
    if not attacker or authoritativePlayerHits(attacker) or not near(position, attacker, 120) then return end
    damagePlayer(player, attacker, participant, damage)
end)

RegisterNetEvent("cordon:npcPlayerHit", function(victimId, npcId, epoch, damage)
    local id = finite(victimId)
    if not id or id <= 0 or id % 1 ~= 0 then return end
    local player, position = livePlayer(id)
    if not player then return end
    local attacker, participant, camp = npc(npcId)
    if not attacker or not camp or not authoritativePlayerHits(attacker) then return end
    local reportedEpoch = finite(epoch)
    if not reportedEpoch or reportedEpoch % 1 ~= 0 or reportedEpoch <= 0 or
        reportedEpoch ~= tonumber(attacker.authorityEpoch) or
        tostring(attacker.authorityPlayerId) ~= tostring(source) then return end
    -- A lease owner can observe while downed. Its current bucket must still
    -- contain the camp, but its own combat state does not own the victim's life.
    if K.players[tonumber(source) or 0] == nil then return end
    local ok, reporterLife = pcall(Open77.players.getLifeState, source)
    if not ok or not reporterLife or reporterLife.bucket ~= attacker.bucket then return end
    local gotLife, life = pcall(Open77.players.getLifeState, id)
    if not gotLife or not life or life.bucket ~= attacker.bucket or
        (life.phase ~= "alive" and life.phase ~= "recovering") then return end
    if not near(position, attacker, 120) then return end
    damagePlayer(player, attacker, participant, damage)
end)

RegisterNetEvent("cordon:npcCrossfire", function(victimId, attackerId, damage)
    local player = livePlayer(source)
    if not player or tostring(victimId) == tostring(attackerId) then return end
    local victim, victimParticipant, victimCamp = npc(victimId)
    local attacker, attackerParticipant, attackerCamp = npc(attackerId)
    if not victim or not attacker or not near(victim, attacker, 120) then return end
    -- Exactly one client owns this victim's simulation. A stale lease report
    -- is dropped rather than crediting the same burst from every observer.
    if tostring(victim.authorityPlayerId) ~= tostring(player.id) then return end
    if (victimCamp and attackerCamp) or sameSquad(victimParticipant, attackerParticipant) then return end
    local amount = finite(damage)
    if not amount or amount < 0 then return end
    if amount == 0 then amount = 18 end
    amount = math.min(amount, 34)
    if not bounded("npc:" .. tostring(victimId), "cross:" .. tostring(attackerId) .. ":" .. tostring(victimId), amount, 90, 90) then return end
    if attackerParticipant then K.bots.noteHit(victimId, attackerParticipant) end
    Open77.npcs.applyDamage(victim.id, amount, tostring(attacker.id), "firearm")
end)

AddEventHandler("cordon:phase", function()
    windows, pairsAt = {}, {}
end)
