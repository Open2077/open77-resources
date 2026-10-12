-- Phase 0 laboratory for the Cordon plan (docs/gamemode-cordon-plan.md §14).
--
-- Each command answers one experiment. The point is to MEASURE, so every command
-- prints what it asked for and what it got back, including refusal reasons, and
-- the event log below prints every life, damage, weapon and loot event with its
-- full context. Readouts land in the server log ([cordonlab] prefix) and are
-- echoed to the caller through open77:command:result.

local lights = {}      -- [propId] = true
local vehicles = {}    -- [vehicleId] = { record, av }
local drops = {}       -- [dropId] = item
local avFlight = nil   -- { id, x, y, z, yaw, dx, dy, remaining, hz, player }
local verified = {}    -- [playerId] = { [tweakDbId] = slot }

local function log(text)
    print("[cordonlab] " .. tostring(text))
end

local function reply(source, raw, ok, text)
    log(text)
    if source ~= nil and source > 0 then
        TriggerClientEvent("open77:command:result", source, raw or "", ok == true, text)
    end
end

--- Resolves which player a laboratory verb acts on: an explicit id first,
--- then the caller, then nothing.
---
--- PASSING THE EXPLICIT ID IS NOT OPTIONAL FOR A CONSOLE-DRIVEN VERB. The
--- Warden console issues commands with `source = 0`, so a verb that calls this
--- with a nil token can only ever be used by a player typing in chat -- and the
--- console is how this laboratory is actually driven. Nine verbs shipped that
--- way and answered "player only" to every console call: the three probe verbs,
--- which cost a diagnosis during the survey on 2026-09-02, and lights, car, av,
--- loot, tp and mark, of which `lab.tp` cost a second one the same evening
--- while trying to teleport to a collision hole.
local function targetOf(source, token)
    local id = tonumber(token)
    if id ~= nil and id > 0 then return id end
    if source ~= nil and source > 0 then return source end
    return nil
end

local function positionOf(playerId)
    local ok, position = pcall(Open77.players.position, playerId)
    if not ok or position == nil then return nil, "position_unknown" end
    return {
        x = tonumber(position.x) or 0.0,
        y = tonumber(position.y) or 0.0,
        z = tonumber(position.z) or 0.0,
        bucket = tonumber(position.bucket) or 0,
    }
end

local function lifeOf(playerId)
    local ok, life = pcall(Open77.players.getLifeState, playerId)
    if not ok or life == nil then return "unknown" end
    return tostring(life.phase)
end

local function healthOf(playerId)
    local ok, health = pcall(Open77.players.getHealth, playerId)
    if not ok or health == nil then return "hp=?" end
    return ("hp=%s/%s armor=%s god=%s"):format(tostring(health.health), tostring(health.maxHealth),
        tostring(health.armor), tostring(health.godMode))
end

-- ------------------------------------------------------------- event log ---

AddEventHandler("open77:playerDamaged", function(victim, attacker, amount, kind, weapon, bodyPart, remaining, maxHealth, lethal)
    log(("EVENT playerDamaged victim=%s attacker=%s amount=%s kind=%s weapon=%s part=%s remaining=%s/%s lethal=%s"):format(
        tostring(victim), tostring(attacker), tostring(amount), tostring(kind), tostring(weapon),
        tostring(bodyPart), tostring(remaining), tostring(maxHealth), tostring(lethal)))
end)

AddEventHandler("open77:playerKilled", function(victim, killer, context)
    local detail = ""
    if type(context) == "table" then
        local parts = {}
        for key, value in pairs(context) do parts[#parts + 1] = tostring(key) .. "=" .. tostring(value) end
        table.sort(parts)
        detail = table.concat(parts, " ")
    else
        detail = tostring(context)
    end
    log(("EVENT playerKilled victim=%s killer=%s %s"):format(tostring(victim), tostring(killer), detail))
end)

AddEventHandler("open77:playerDied", function(...)
    local parts = {}
    for index = 1, select("#", ...) do parts[#parts + 1] = tostring((select(index, ...))) end
    log("EVENT playerDied " .. table.concat(parts, " "))
end)

AddEventHandler("open77:playerLifeStateChanged", function(...)
    local parts = {}
    for index = 1, select("#", ...) do
        local value = select(index, ...)
        if type(value) == "table" then
            local inner = {}
            for key, field in pairs(value) do inner[#inner + 1] = tostring(key) .. "=" .. tostring(field) end
            table.sort(inner)
            parts[#parts + 1] = "{" .. table.concat(inner, " ") .. "}"
        else
            parts[#parts + 1] = tostring(value)
        end
    end
    log("EVENT lifeStateChanged " .. table.concat(parts, " "))
end)

AddEventHandler("open77:playerRespawned", function(...)
    local parts = {}
    for index = 1, select("#", ...) do parts[#parts + 1] = tostring((select(index, ...))) end
    log("EVENT playerRespawned " .. table.concat(parts, " "))
end)

AddEventHandler("open77:playerRevived", function(...)
    local parts = {}
    for index = 1, select("#", ...) do parts[#parts + 1] = tostring((select(index, ...))) end
    log("EVENT playerRevived " .. table.concat(parts, " "))
end)

AddEventHandler("open77:weapons:completed", function(playerId, requestId, operation, accepted, reason, result)
    local tweak = type(result) == "table" and tostring(result.tweakDbId) or tostring(result)
    log(("EVENT weapons:completed player=%s request=%s op=%s accepted=%s reason=%s tweakDbId=%s"):format(
        tostring(playerId), tostring(requestId), tostring(operation), tostring(accepted), tostring(reason), tweak))
    local id = tonumber(playerId)
    if accepted and id ~= nil and type(result) == "table" and result.tweakDbId ~= nil then
        verified[id] = verified[id] or {}
        verified[id][tostring(result.tweakDbId)] = result.slot or true
    end
end)

AddEventHandler("onLootPickup", function(playerId, dropId, item, quantity, owner)
    log(("EVENT lootPickup player=%s drop=%s item=%s qty=%s owner=%s"):format(
        tostring(playerId), tostring(dropId), tostring(item), tostring(quantity), tostring(owner)))
    local id = tonumber(playerId)
    if id == nil or type(item) ~= "string" then return end
    -- E6: a weapon on the ground becomes a verified weapon in the hand. The
    -- verdict arrives on open77:weapons:completed with the id the arbiter needs.
    if item:find("^Items%.Preset_") then
        local request, refusal = Open77.weapons.assign(id, item, 1, { active = true, addToInventory = true })
        log(("E6 assign %s to player %s slot 1 -> request=%s refusal=%s"):format(item, tostring(id),
            tostring(request), tostring(refusal)))
    end
end)

Open77.combat.onDamage(function(event)
    local set = verified[tonumber(event.attacker) or -1]
    local known = set ~= nil and set[tostring(event.weaponTdbId)] ~= nil
    log(("ARBITER victim=%s attacker=%s amount=%s kind=%s weapon=%s verifiedForAttacker=%s distance=%s"):format(
        tostring(event.victim), tostring(event.attacker), tostring(event.amount), tostring(event.attackKind),
        tostring(event.weaponTdbId), tostring(known), tostring(event.distance)))
    return nil
end)

-- ------------------------------------------------------------ commands ----

-- lab.where [playerId]
RegisterCommand("lab.where", function(source, args, raw)
    local id = targetOf(source, args[1])
    if id == nil then return reply(source, raw, false, "player only") end
    local position, reason = positionOf(id)
    if position == nil then return reply(source, raw, false, "no position: " .. tostring(reason)) end
    local ghosted = select(2, pcall(Open77.players.isGhosted, id))
    reply(source, raw, true, ("where player=%d pos=%.2f,%.2f,%.2f bucket=%d life=%s %s ghosted=%s"):format(
        id, position.x, position.y, position.z, position.bucket, lifeOf(id), healthOf(id), tostring(ghosted)))
end, false)

-- lab.drop <height> [god 0|1] [playerId] -- E3: respawn the player `height`
-- metres above where they stand and sample the fall for 15 s.
RegisterCommand("lab.drop", function(source, args, raw)
    local height = tonumber(args[1]) or 120.0
    local god = (args[2] or "1") ~= "0"
    local id = targetOf(source, args[3])
    if id == nil then return reply(source, raw, false, "player only") end
    local origin, reason = positionOf(id)
    if origin == nil then return reply(source, raw, false, "no position: " .. tostring(reason)) end
    local phase = lifeOf(id)
    if god then Open77.players.setGodMode(id, true) end
    if phase == "alive" or phase == "recovering" then
        local killed, killReason = Open77.players.kill(id, { cause = "script", weapon = "cordonlab:drop" })
        log(("E3 kill -> %s %s"):format(tostring(killed), tostring(killReason)))
    end
    local ok, respawnReason = Open77.players.respawn(id, {
        position = { x = origin.x, y = origin.y, z = origin.z + height },
        heading = 0.0, bucket = origin.bucket, health = 1.0, graceMs = 500,
    })
    reply(source, raw, ok == true, ("E3 drop player=%d from z=%.2f to z=%.2f god=%s -> respawn=%s %s"):format(
        id, origin.z, origin.z + height, tostring(god), tostring(ok), tostring(respawnReason)))
    if not ok then return end
    CreateThread(function()
        local startedAt = GetGameTimer()
        local lowest = origin.z + height
        local landedAt = nil
        for sample = 1, 60 do
            Wait(250)
            local now = positionOf(id)
            local elapsed = (GetGameTimer() - startedAt) / 1000.0
            if now ~= nil then
                if now.z < lowest then lowest = now.z end
                if landedAt == nil and sample > 4 and math.abs(now.z - origin.z) < 2.5 then landedAt = elapsed end
                log(("E3 t=%.2fs z=%.2f dz=%.2f life=%s %s"):format(elapsed, now.z, now.z - origin.z, lifeOf(id), healthOf(id)))
            else
                log(("E3 t=%.2fs position unreadable life=%s"):format(elapsed, lifeOf(id)))
            end
        end
        if god then Open77.players.setGodMode(id, false) end
        local final = positionOf(id)
        reply(source, raw, true, ("E3 result player=%d landedAt=%s lowestZ=%.2f finalZ=%s finalLife=%s %s"):format(
            id, tostring(landedAt), lowest, final and ("%.2f"):format(final.z) or "?", lifeOf(id), healthOf(id)))
    end)
end, false)

-- lab.ghost <0|1> [playerId] -- E4: ghosted + god mode + weapons off + client noclip.
RegisterCommand("lab.ghost", function(source, args, raw)
    local enabled = (args[1] or "1") ~= "0"
    local id = targetOf(source, args[2])
    if id == nil then return reply(source, raw, false, "player only") end
    local ghostOk, ghostReason = Open77.players.setGhosted(id, enabled)
    local godOk, godReason = Open77.players.setGodMode(id, enabled)
    if enabled then
        Open77.weapons.holster(id)
        for slot = 1, 3 do Open77.weapons.remove(id, slot) end
    end
    TriggerClientEvent("cordonlab:noclip", id, enabled)
    reply(source, raw, ghostOk ~= false, ("E4 ghost player=%d enabled=%s -> ghosted=%s %s god=%s %s (noclip sent to client)"):format(
        id, tostring(enabled), tostring(ghostOk), tostring(ghostReason), tostring(godOk), tostring(godReason)))
end, false)

-- lab.hurt <amount> [playerId] -- E5: cordon damage with no attacker.
RegisterCommand("lab.hurt", function(source, args, raw)
    local amount = tonumber(args[1]) or 10.0
    local id = targetOf(source, args[2])
    if id == nil then return reply(source, raw, false, "player only") end
    local before = healthOf(id)
    local ok, reason = Open77.players.damage(id, amount, { kind = "environment" })
    reply(source, raw, ok ~= false, ("E5 hurt player=%d amount=%.1f cause=cordon -> %s %s | before %s | after %s"):format(
        id, amount, tostring(ok), tostring(reason), before, healthOf(id)))
end, false)

-- lab.shoot <victimId> <attackerId> [amount] [weaponRecord] -- E6: damage that
-- one player deals to another, ATTRIBUTED, so it travels the arbiter's real
-- player-versus-player path: both roster lookups, the spawn shield, the shield
-- break on the aggressor, and the verified weapon set.
--
-- It exists because driving a real bullet from an agent is not always
-- reachable. A weapon assigned by `lab.arm` lands in the inventory and
-- `char.state` reports armed=yes, yet the character keeps the bare-handed
-- prompts and the magazine never moves. This verb reaches the same arbiter the
-- bullet would, with the same fields, and states what it decided.
--
-- The cause is `gunshot`, never `script`: the mode exempts `script` as a
-- development placement, so a kill dealt under it would be ignored on purpose.
RegisterCommand("lab.shoot", function(source, args, raw)
    local victim = tonumber(args[1])
    local attacker = tonumber(args[2]) or (source and source > 0 and source or nil)
    if victim == nil or attacker == nil then
        return reply(source, raw, false, "usage: lab.shoot <victimId> <attackerId> [amount] [weaponRecord]")
    end
    local amount = tonumber(args[3]) or 25.0
    -- The kind is a CLOSED SET, and anything outside it is rejected as
    -- `invalid_argument` with nothing to say which argument was wrong:
    --   ranged | firearm | melee | explosion | quickhack | environment | fall
    --   | unknown | script
    -- `bullet`, `gunshot` and `physical` are all refusals. Either `cause` or
    -- `kind` names it; the shim reads whichever is present.
    local kind = args[4] or "ranged"
    local weapon = args[5]
    local before = healthOf(victim)
    local ok, reason = Open77.players.damage(victim, amount, {
        attacker = attacker, kind = kind, weapon = weapon,
    })
    reply(source, raw, ok ~= false, ("E6 shoot victim=%d attacker=%d amount=%.1f kind=%s weapon=%s -> %s %s | before %s | after %s"):format(
        victim, attacker, amount, kind, tostring(weapon), tostring(ok), tostring(reason), before, healthOf(victim)))
end, false)

-- lab.hurt.tick <dps> <seconds> [playerId] -- E5: a cordon bleed at 4 Hz.
RegisterCommand("lab.hurt.tick", function(source, args, raw)
    local dps = tonumber(args[1]) or 5.0
    local seconds = tonumber(args[2]) or 5.0
    local id = targetOf(source, args[3])
    if id == nil then return reply(source, raw, false, "player only") end
    reply(source, raw, true, ("E5 bleed player=%d %.1f HP/s for %.1fs"):format(id, dps, seconds))
    CreateThread(function()
        local steps = math.floor(seconds * 4)
        for _ = 1, steps do
            Wait(250)
            if lifeOf(id) ~= "alive" then break end
            Open77.players.damage(id, dps / 4.0, { kind = "environment" })
        end
        reply(source, raw, true, ("E5 bleed done player=%d life=%s %s"):format(id, lifeOf(id), healthOf(id)))
    end)
end, false)

-- lab.kill [playerId] / lab.revive [health] [playerId] -- E7.
RegisterCommand("lab.kill", function(source, args, raw)
    local id = targetOf(source, args[1])
    if id == nil then return reply(source, raw, false, "player only") end
    local position = positionOf(id)
    local ok, reason = Open77.players.kill(id, { cause = "script", weapon = "cordonlab:kill" })
    reply(source, raw, ok ~= false, ("E7 kill player=%d at %s -> %s %s"):format(id,
        position and ("%.2f,%.2f,%.2f"):format(position.x, position.y, position.z) or "?", tostring(ok), tostring(reason)))
end, false)

RegisterCommand("lab.revive", function(source, args, raw)
    local health = tonumber(args[1]) or 0.3
    local id = targetOf(source, args[2])
    if id == nil then return reply(source, raw, false, "player only") end
    local position = positionOf(id)
    local ok, reason = Open77.players.revive(id, { health = health, graceMs = 2000 })
    reply(source, raw, ok ~= false, ("E7 revive player=%d health=%.2f bodyPos=%s life=%s -> %s %s"):format(id, health,
        position and ("%.2f,%.2f,%.2f"):format(position.x, position.y, position.z) or "?", lifeOf(id),
        tostring(ok), tostring(reason)))
end, false)

-- lab.lights <count> <spacing> [r g b] [intensity] [radius] -- E8: a line of
-- red lights along +X from the caller, 1.5 m up. lab.lights.clear removes them.
RegisterCommand("lab.lights", function(source, args, raw)
    local count = math.min(tonumber(args[1]) or 20, 600)
    local spacing = tonumber(args[2]) or 20.0
    local color = { x = tonumber(args[3]) or 1.0, y = tonumber(args[4]) or 0.1, z = tonumber(args[5]) or 0.05 }
    local intensity = tonumber(args[6]) or 60.0
    local radius = tonumber(args[7]) or 15.0
    local id = targetOf(source, args[8])
    if id == nil then return reply(source, raw, false, "player only") end
    local origin, reason = positionOf(id)
    if origin == nil then return reply(source, raw, false, "no position: " .. tostring(reason)) end
    local created, refused, firstReason = 0, 0, nil
    for index = 1, count do
        local propId, refusal = Open77.props.create({
            kind = "light",
            model = "light.spot",
            position = { x = origin.x + index * spacing, y = origin.y, z = origin.z + 1.5 },
            yaw = 0.0,
            bucket = origin.bucket,
            streamingRadius = 2000,
            light = { spot = false, color = color, intensity = intensity, radius = radius, enabled = true },
        })
        if propId ~= nil then
            lights[propId] = true
            created = created + 1
        else
            refused = refused + 1
            firstReason = firstReason or refusal
        end
    end
    reply(source, raw, created > 0, ("E8 lights count=%d spacing=%.1f -> created=%d refused=%d reason=%s span=%.0fm from %.1f,%.1f"):format(
        count, spacing, created, refused, tostring(firstReason), count * spacing, origin.x, origin.y))
end, false)

RegisterCommand("lab.lights.clear", function(source, _, raw)
    local removed = 0
    for _, prop in ipairs(Open77.props.all() or {}) do
        if Open77.props.remove(prop.id) then removed = removed + 1 end
    end
    lights = {}
    reply(source, raw, true, ("E8 cleared %d props"):format(removed))
end, false)

-- lab.car [record] [offset] -- E9: a car `offset` metres along +X from the caller.
RegisterCommand("lab.car", function(source, args, raw)
    local record = args[1] or "Vehicle.v_standard2_archer_hella_player"
    local offset = tonumber(args[2]) or 6.0
    local id = targetOf(source, args[3])
    if id == nil then return reply(source, raw, false, "player only") end
    local origin, reason = positionOf(id)
    if origin == nil then return reply(source, raw, false, "no position: " .. tostring(reason)) end
    local vehicleId, refusal = Open77.vehicles.create({
        record = record, position = { x = origin.x + offset, y = origin.y, z = origin.z + 0.5 },
        yaw = 0.0, bucket = origin.bucket, health = 1.0,
    })
    if vehicleId ~= nil then vehicles[vehicleId] = { record = record } end
    reply(source, raw, vehicleId ~= nil, ("E9 car record=%s -> id=%s refusal=%s"):format(record, tostring(vehicleId), tostring(refusal)))
end, false)

-- lab.av <altitude> <length> <hz> [speed] [record] -- E10: spawn an AV above the
-- caller, warp them in as a passenger, then fly it along +Y with setTransform.
RegisterCommand("lab.av", function(source, args, raw)
    local altitude = tonumber(args[1]) or 120.0
    local length = tonumber(args[2]) or 600.0
    local hz = math.max(1, math.min(tonumber(args[3]) or 10, 30))
    local speed = tonumber(args[4]) or 30.0
    local record = args[5] or "Vehicle.av_militech_manticore"
    local id = targetOf(source, args[6])
    if id == nil then return reply(source, raw, false, "player only") end
    local origin, reason = positionOf(id)
    if origin == nil then return reply(source, raw, false, "no position: " .. tostring(reason)) end
    local avId, refusal = Open77.vehicles.create({
        record = record, position = { x = origin.x, y = origin.y, z = origin.z + altitude },
        yaw = 0.0, bucket = origin.bucket, health = 1.0,
    })
    if avId == nil then return reply(source, raw, false, ("E10 av create %s refused: %s"):format(record, tostring(refusal))) end
    vehicles[avId] = { record = record, av = true }
    local seatOk, seatReason = Open77.vehicles.warpPlayerIntoVehicle(id, avId, "frontPassenger")
    avFlight = { id = avId, x = origin.x, y = origin.y, z = origin.z + altitude, yaw = 0.0,
        remaining = length, hz = hz, speed = speed, player = id, steps = 0 }
    reply(source, raw, true, ("E10 av id=%s record=%s at alt=%.0f warp=%s %s; flying +Y %.0fm at %.0f m/s, %d Hz (lab.av.eject to jump, lab.av.stop to end)"):format(
        tostring(avId), record, altitude, tostring(seatOk), tostring(seatReason), length, speed, hz))
    CreateThread(function()
        Wait(4000) -- let the warp settle before moving the body under the passenger
        local interval = math.floor(1000 / hz)
        while avFlight ~= nil and avFlight.id == avId and avFlight.remaining > 0 do
            Wait(interval)
            local step = speed * (interval / 1000.0)
            avFlight.y = avFlight.y + step
            avFlight.remaining = avFlight.remaining - step
            avFlight.steps = avFlight.steps + 1
            local ok = Open77.vehicles.setTransform(avId, { x = avFlight.x, y = avFlight.y, z = avFlight.z, yaw = avFlight.yaw })
            if avFlight.steps % hz == 0 then
                local p = positionOf(id)
                log(("E10 step=%d av y=%.1f setTransform=%s passengerPos=%s"):format(avFlight.steps, avFlight.y, tostring(ok),
                    p and ("%.1f,%.1f,%.1f"):format(p.x, p.y, p.z) or "?"))
            end
        end
        log("E10 flight ended")
    end)
end, false)

RegisterCommand("lab.av.eject", function(source, args, raw)
    local id = targetOf(source, args[1])
    if id == nil or avFlight == nil then return reply(source, raw, false, "no flight") end
    Open77.players.setGodMode(id, true)
    local ok, reason = Open77.vehicles.forcePlayerOutOfVehicle(id, avFlight.id)
    reply(source, raw, ok ~= false, ("E10 eject player=%d from av=%s -> %s %s (god on; sampling fall)"):format(id, tostring(avFlight.id), tostring(ok), tostring(reason)))
    CreateThread(function()
        for sample = 1, 60 do
            Wait(250)
            local p = positionOf(id)
            log(("E10 fall t=%.2fs z=%s life=%s %s"):format(sample * 0.25, p and ("%.2f"):format(p.z) or "?", lifeOf(id), healthOf(id)))
        end
        Open77.players.setGodMode(id, false)
    end)
end, false)

RegisterCommand("lab.av.stop", function(source, _, raw)
    local id = avFlight and avFlight.id
    avFlight = nil
    if id ~= nil then Open77.vehicles.remove(id) end
    reply(source, raw, true, ("E10 flight stopped, av %s removed"):format(tostring(id)))
end, false)

RegisterCommand("lab.vehicles.clear", function(source, _, raw)
    local removed = 0
    for _, vehicle in ipairs(Open77.vehicles.all() or {}) do
        if Open77.vehicles.remove(vehicle.id) then removed = removed + 1 end
    end
    vehicles = {}
    avFlight = nil
    reply(source, raw, true, ("cleared %d vehicles"):format(removed))
end, false)

-- lab.team <team> [playerId] and lab.place [playerId] -- E12.
RegisterCommand("lab.team", function(source, args, raw)
    local team = tonumber(args[1]) or 1
    local id = targetOf(source, args[2])
    if id == nil then return reply(source, raw, false, "player only") end
    local ok, reason = Open77.combat.setTeam(id, team)
    reply(source, raw, ok ~= false, ("E12 setTeam player=%d team=%d -> %s %s"):format(id, team, tostring(ok), tostring(reason)))
end, false)

RegisterCommand("lab.place", function(source, args, raw)
    local id = targetOf(source, args[1])
    if id == nil then return reply(source, raw, false, "player only") end
    local origin, reason = positionOf(id)
    if origin == nil then return reply(source, raw, false, "no position: " .. tostring(reason)) end
    local phase = lifeOf(id)
    if phase == "alive" or phase == "recovering" then
        Open77.players.kill(id, { cause = "script", weapon = "cordonlab:place" })
    end
    local ok, respawnReason = Open77.players.respawn(id, {
        position = { x = origin.x, y = origin.y, z = origin.z }, heading = 0.0, bucket = origin.bucket,
        health = 1.0, graceMs = 1500,
    })
    reply(source, raw, ok ~= false, ("E12 place player=%d (kill->respawn in place) -> %s %s"):format(id, tostring(ok), tostring(respawnReason)))
end, false)

-- lab.loot <item> [qty] [offset] -- E6: a ground drop in front of the caller.
-- lab.drops [playerId] [bucket] -- what the PLATFORM's loot registry actually
-- holds, and how far the nearest one is from a player.
--
-- It exists because "the player found nothing on the ground" has at least three
-- causes that look identical from inside the game: no drop was ever created,
-- the drops are in a routing bucket the player is not in, or they are there and
-- simply out of reach. This separates them.
RegisterCommand("lab.drops", function(source, args, raw)
    local id = targetOf(source, args[1])
    local bucket = tonumber(args[2])
    local at = id and positionOf(id) or nil
    if bucket == nil and at ~= nil then bucket = at.bucket end
    local all = Open77.loot.all(bucket) or {}
    local nearest, nearestId, nearestPos = nil, nil, nil
    if at ~= nil then
        for _, drop in ipairs(all) do
            local dx, dy = (drop.x or 0) - at.x, (drop.y or 0) - at.y
            local d = math.sqrt(dx * dx + dy * dy)
            if nearest == nil or d < nearest then
                nearest, nearestId = d, drop.id
                nearestPos = { x = drop.x or 0, y = drop.y or 0, z = drop.z or 0 }
            end
        end
    end
    -- The BEARING matters as much as the distance. Walking to a drop needs a
    -- heading, and the game's yaw runs 0 = +Y with 90 = -X, so the bearing is
    -- atan2(-dx, dy) in degrees. Print it and the walk is two commands instead
    -- of a search.
    local bearing = nil
    if nearestPos ~= nil and at ~= nil then
        bearing = math.deg(math.atan(-(nearestPos.x - at.x), nearestPos.y - at.y))
    end
    reply(source, raw, true, ("drops in bucket %s: %d | player %s at bucket %s | nearest %s at %s m bearing %s | drop at %s"):format(
        tostring(bucket), #all, tostring(id), at and tostring(at.bucket) or "?",
        tostring(nearestId), nearest and ("%.1f"):format(nearest) or "n/a",
        bearing and ("%.0f"):format(bearing) or "n/a",
        nearestPos and ("%.1f,%.1f,%.1f"):format(nearestPos.x, nearestPos.y, nearestPos.z or 0) or "?"))
end, false)

-- lab.heal [amount] [playerId] -- put a player back on their feet.
--
-- It exists because a player at one health has NO READABLE SERVER-SIDE
-- POSITION: `Open77.players.position` returns nothing for them, and every verb
-- that needs a position -- the hop, the drop inspector, the pickup request --
-- refuses. That gate blocked four separate measurements in one session, each
-- time costing a match restart to work around.
--
-- This needs no position of its own, so it works on exactly the players
-- everything else has given up on.
RegisterCommand("lab.heal", function(source, args, raw)
    local amount = tonumber(args[1]) or 100.0
    local id = targetOf(source, args[2])
    if id == nil then return reply(source, raw, false, "player only (or pass a playerId)") end
    local before = healthOf(id)
    -- Three attempts, because "one health" is usually a LIE told by the client.
    -- Measured 2026-09-02: a player whose `char.state` reads
    -- `alive=yes health=1` can be at `hp=0.0` on the server, and `setHealth`
    -- refuses such a player with `invalid_state`. The server's view is the one
    -- that matters, so a revive has to be in the ladder.
    local ok, reason = Open77.players.setHealth(id, amount)
    if ok == false then
        ok, reason = Open77.players.heal(id, amount)
    end
    if ok == false then
        ok, reason = Open77.players.revive(id, { health = amount / 100.0, graceMs = 2000 })
    end
    reply(source, raw, ok ~= false, ("heal player=%d to %.0f -> %s %s | before %s | after %s"):format(
        id, amount, tostring(ok), tostring(reason), before, healthOf(id)))
end, false)

-- lab.pickup [playerId] -- send the pickup request for the nearest drop, which
-- is the same network event the in-world interaction produces.
--
-- The server has no pickup API at all: `Open77.loot` on the dedicated server is
-- create / update / remove / get / all, and a grant only ever begins as a
-- CLIENT request that `LootAuthorityService.TryPickup` then validates. So the
-- only way to exercise the grant without a camera is to ask the client half to
-- send that request, which is what this does through `cordonlab:pickup`.
--
-- It leaves exactly one thing unproven -- whether the in-world prompt appears --
-- and proves everything behind it: the request, the distance and bucket
-- validation, the grant, and the mode's `onLootPickup`.
RegisterCommand("lab.pickup", function(source, args, raw)
    local id = targetOf(source, args[1])
    if id == nil then return reply(source, raw, false, "player only (or pass a playerId)") end
    local at = positionOf(id)
    if at == nil then return reply(source, raw, false, "no position") end
    local nearest, nearestId = nil, nil
    for _, drop in ipairs(Open77.loot.all(at.bucket) or {}) do
        local dx, dy, dz = (drop.x or 0) - at.x, (drop.y or 0) - at.y, (drop.z or 0) - at.z
        local d = math.sqrt(dx * dx + dy * dy + dz * dz)
        if nearest == nil or d < nearest then nearest, nearestId = d, drop.id end
    end
    if nearestId == nil then return reply(source, raw, false, "no drop in bucket " .. tostring(at.bucket)) end
    TriggerClientEvent("cordonlab:pickup", id, nearestId)
    reply(source, raw, true, ("pickup requested: player=%d drop=%s at %.1f m"):format(id, tostring(nearestId), nearest))
end, false)

RegisterCommand("lab.loot", function(source, args, raw)
    local item = args[1] or "Items.Preset_Lexington_Default"
    local quantity = tonumber(args[2]) or 1
    local offset = tonumber(args[3]) or 1.5
    local id = targetOf(source, args[4])
    if id == nil then return reply(source, raw, false, "player only") end
    local origin, reason = positionOf(id)
    if origin == nil then return reply(source, raw, false, "no position: " .. tostring(reason)) end
    local dropId, refusal = Open77.loot.create({
        item = item, quantity = quantity,
        position = { x = origin.x + offset, y = origin.y, z = origin.z },
        bucket = origin.bucket, radius = 2.0, label = "lab " .. item,
    })
    if dropId ~= nil then drops[dropId] = item end
    reply(source, raw, dropId ~= nil, ("E6 loot item=%s qty=%d -> drop=%s refusal=%s"):format(item, quantity, tostring(dropId), tostring(refusal)))
end, false)

RegisterCommand("lab.verified", function(source, args, raw)
    local id = targetOf(source, args[1])
    if id == nil then return reply(source, raw, false, "player only") end
    local parts = {}
    for tweak, slot in pairs(verified[id] or {}) do parts[#parts + 1] = tweak .. ":" .. tostring(slot) end
    reply(source, raw, true, ("verified weapons player=%d -> %s"):format(id, #parts > 0 and table.concat(parts, " ") or "none"))
end, false)

-- lab.arm [record] [playerId] -- issue a weapon and reserve ammo.
--
-- Purely server-side, so unlike the noclip tools this survives a lab reload
-- without a reconnect. The verdict arrives asynchronously on
-- open77:weapons:completed carrying the id the client ACTUALLY ended up
-- holding, and it is that id — never the record asked for — that the gamemode
-- writes into the verified set its damage arbiter matches.
-- The pending arms, keyed by the assign's request id. The verdict for an
-- assign arrives LATER, on `open77:weapons:completed`, and everything that
-- depends on the weapon actually being in the slot has to wait for it.
local pendingArm = {}

RegisterCommand("lab.arm", function(source, args, raw)
    local record = args[1] or "Items.Preset_Lexington_Default"
    local id = targetOf(source, args[2])
    if id == nil then return reply(source, raw, false, "player only") end
    local request, refusal = Open77.weapons.assign(id, record, 1, { active = true, addToInventory = true })
    if request ~= nil then
        pendingArm[tostring(request)] = { playerId = id, source = source, raw = raw, record = record }
    end
    reply(source, raw, request ~= nil, ("arm player=%d record=%s -> request=%s refusal=%s (waiting for the assign to land)"):format(
        id, record, tostring(request), tostring(refusal)))
end, false)

-- ASSIGNING IS NOT DRAWING, AND THE ORDER IS THE WHOLE TRICK.
--
-- `Open77.weapons.assign` returns a request id, not a result: the weapon is not
-- in the slot when the call returns. Calling `setActive` on the next line
-- therefore acts on a slot that is still being filled, and it is accepted --
-- the completion event even says `op=setActive accepted=true` -- while the
-- character goes on standing there empty-handed with the bare-handed prompts.
-- `char.state` reports `armed=yes` with a weapon category throughout, so
-- nothing in any readout says the gun is not in hand. Measured 2026-09-02.
--
-- The deathmatch has always done this correctly and says so in
-- `open77_deathmatch/server/loadout.lua`: draw the weapon from INSIDE the
-- completion handler, once the assign has actually landed. The ammunition
-- follows for the same reason.
AddEventHandler("open77:weapons:completed", function(playerId, requestId, operation, accepted, reason, result)
    if tostring(operation) ~= "assign" then return end
    local key = tostring(requestId)
    local entry = pendingArm[key]
    if entry == nil then return end
    pendingArm[key] = nil
    if not accepted then
        return reply(entry.source, entry.raw, false, ("arm player=%d refused: %s"):format(
            entry.playerId, tostring(reason)))
    end
    local drawn, drawRefusal = Open77.weapons.setActive(entry.playerId, 1)
    local ammoOk, ammoRefusal = pcall(Open77.weapons.setAmmo, entry.playerId, 1, { reserve = 120, activate = true })
    log(("arm landed player=%d record=%s verifiedId=%s draw=%s %s ammo=%s %s"):format(
        entry.playerId, entry.record,
        tostring(type(result) == "table" and result.tweakDbId or result),
        tostring(drawn), tostring(drawRefusal), tostring(ammoOk), tostring(ammoRefusal)))
end)

-- lab.god <0|1> [playerId]
RegisterCommand("lab.god", function(source, args, raw)
    local enabled = (args[1] or "1") ~= "0"
    local id = targetOf(source, args[2])
    if id == nil then return reply(source, raw, false, "player only") end
    local ok, reason = Open77.players.setGodMode(id, enabled)
    reply(source, raw, ok ~= false, ("god player=%d enabled=%s -> %s %s"):format(id, tostring(enabled), tostring(ok), tostring(reason)))
end, false)

-- --------------------------------------------------------------- survey ---
--
-- Phase 2's tool, living here rather than in the mode because the mode has no
-- server scripts yet and because a laboratory is exactly where a tool that
-- teleports the operator around Night City belongs.
--
-- Two rules it inherits from the deathmatch surveyor, both paid for:
--   * Nothing is ever written under resources/. The dev server watches that
--     tree at 1 Hz and any write hot-swaps the whole resource set, despawning
--     everything and dropping every player. Marks live in memory and are
--     printed as pasteable Lua by `lab.marks`.
--   * Every placement is a kill -> respawn, never a raw transform write, so it
--     carries the fade and the streaming preload a teleport skips.

local marks = { landmarks = {}, landings = {}, loot = {}, vehicles = {},
                holdouts = {}, supply = {}, misc = {} }
local gridOrigin = nil
local groundDefault = nil

local function placeAt(playerId, x, y, z, heading)
    local life = Open77.players.getLifeState(playerId)
    if life == nil then return false, "player_not_found" end
    if life.phase == "alive" or life.phase == "recovering" then
        local ok, reason = Open77.players.kill(playerId, { cause = "script", weapon = "cordonlab:survey" })
        if not ok then return false, reason end
    elseif life.phase ~= "dead" then
        return false, "transition_in_progress:" .. tostring(life.phase)
    end
    return Open77.players.respawn(playerId, {
        position = { x = x, y = y, z = z }, heading = heading or 0.0,
        bucket = life.bucket or 0, health = 1.0, graceMs = 2500,
    })
end

-- lab.tp <x> <y> <z> [heading]
RegisterCommand("lab.tp", function(source, args, raw)
    local id = targetOf(source, args[5])
    if id == nil then return reply(source, raw, false, "player only") end
    local x, y, z = tonumber(args[1]), tonumber(args[2]), tonumber(args[3])
    if x == nil or y == nil or z == nil then
        return reply(source, raw, false, "usage: lab.tp <x> <y> <z> [heading]")
    end
    local ok, reason = placeAt(id, x, y, z, tonumber(args[4]) or 0.0)
    reply(source, raw, ok ~= false, ("tp player=%d -> %.1f,%.1f,%.1f = %s %s"):format(
        id, x, y, z, tostring(ok), tostring(reason)))
end, false)

-- lab.hop <x> <y> <z> [stepMetres] -- move in SHORT HOPS so the world keeps up.
--
-- MEASURED 2026-09-02: a single long teleport kills the player it moves. The
-- placement puts them somewhere the world has not streamed, the client cannot
-- apply the life transition, and `PlayerLifeService` fails it CLOSED TO DEAD
-- after ten seconds — the life event carries `reason=transition_timeout`. In a
-- live match that is a real elimination, which is why moving one of two players
-- kept ending matches before anyone fired.
--
-- Hopping in short steps with a pause between them keeps each placement inside
-- already-streamed world, so every transition is acknowledged and nobody dies.
RegisterCommand("lab.hop", function(source, args, raw)
    -- The player argument is LAST, and it is what lets the server console drive
    -- this. A console source is 0, so `targetOf` alone returns nothing and the
    -- command refuses -- which is how a whole afternoon went into wondering why
    -- the laboratory looked dead while the mode answered fine.
    local id = targetOf(source, args[5])
    if id == nil then return reply(source, raw, false, "player only (or pass a playerId as the fifth argument)") end
    local tx, ty, tz = tonumber(args[1]), tonumber(args[2]), tonumber(args[3])
    if tx == nil or ty == nil or tz == nil then
        return reply(source, raw, false, "usage: lab.hop <x> <y> <z> [stepMetres] [playerId]")
    end
    local step = math.max(10.0, tonumber(args[4]) or 60.0)
    local from = positionOf(id)
    if from == nil then return reply(source, raw, false, "no position") end
    local dx, dy, dz = tx - from.x, ty - from.y, tz - from.z
    local distance = math.sqrt(dx * dx + dy * dy)
    local hops = math.max(1, math.ceil(distance / step))
    reply(source, raw, true, ("hop %.0fm in %d step(s) of <=%.0fm"):format(distance, hops, step))
    CreateThread(function()
        for index = 1, hops do
            local t = index / hops
            local ok, why = placeAt(id, from.x + dx * t, from.y + dy * t, from.z + dz * t, 0.0)
            if not ok then
                return reply(source, raw, false, ("hop %d/%d refused: %s"):format(index, hops, tostring(why)))
            end
            -- WAIT FOR THE LIFE STATE, do not guess at a delay. A placement is
            -- a kill and a respawn, and how long that takes depends on how much
            -- world has to stream in at the destination -- which is exactly what
            -- varies along a route. A fixed 3500 ms was enough at the staging
            -- point and not enough two hops out: the next placement came back
            -- `transition_in_progress:respawnpending` and the walk stopped in
            -- the middle of the map. Measured 2026-09-02.
            local settled = false
            for _ = 1, 40 do
                Wait(500)
                -- The phase to wait OUT is `respawnpending`, which is what the
                -- next placement refuses on. It settles into `recovering` and
                -- lingers there, so waiting for the literal string "alive" waits
                -- for something that does not arrive in any useful time.
                local life = lifeOf(id)
                if life ~= "respawnpending" and life ~= "dead" and life ~= "unknown" then
                    settled = true break
                end
            end
            if not settled then
                return reply(source, raw, false, ("hop %d/%d: never came back alive"):format(index, hops))
            end
            -- A REAL breath after the life state says alive, because it says
            -- alive before the placement has finished settling: with only 600 ms
            -- here the next placement still came back
            -- `transition_in_progress:respawnpending`. Three seconds on top of
            -- the wait is what actually holds.
            Wait(3000)
        end
        local at = positionOf(id)
        reply(source, raw, true, ("hop done -> %s life=%s"):format(
            at and ("%.1f,%.1f,%.1f"):format(at.x, at.y, at.z) or "?", lifeOf(id)))
    end)
end, false)

-- lab.mark <kind> [key] [extra...] -- capture where the caller stands.
--   origin | ground | staging | landmark <key> | landing <key> [hot]
--   loot <tier> [count] [radius] | vehicle <record> | holdout | supply
RegisterCommand("lab.mark", function(source, args, raw)
    local id = targetOf(source, args[5])
    if id == nil then return reply(source, raw, false, "player only") end
    local at, reason = positionOf(id)
    if at == nil then return reply(source, raw, false, "no position: " .. tostring(reason)) end
    local kind = (args[1] or ""):lower()

    if kind == "origin" then
        gridOrigin = { x = at.x, y = at.y }
        return reply(source, raw, true, ("origin = { x = %.3f, y = %.3f }"):format(at.x, at.y))
    elseif kind == "ground" then
        groundDefault = at.z
        return reply(source, raw, true, ("groundDefault = %.3f"):format(at.z))
    elseif kind == "staging" then
        marks.misc.staging = { x = at.x, y = at.y, z = at.z }
        return reply(source, raw, true, ("staging = %.2f,%.2f,%.2f"):format(at.x, at.y, at.z))
    elseif kind == "landmark" then
        local key = args[2] or ("lm" .. tostring(#marks.landmarks + 1))
        marks.landmarks[#marks.landmarks + 1] = { key = key, x = at.x, y = at.y, z = at.z }
        return reply(source, raw, true, ("landmark %s captured (%d total)"):format(key, #marks.landmarks))
    elseif kind == "landing" then
        local key = args[2] or ("lz" .. tostring(#marks.landings + 1))
        marks.landings[#marks.landings + 1] = { key = key, x = at.x, y = at.y, z = at.z,
            hot = (args[3] or ""):lower() == "hot" }
        return reply(source, raw, true, ("landing %s captured (%d total)"):format(key, #marks.landings))
    elseif kind == "loot" then
        marks.loot[#marks.loot + 1] = { tier = tonumber(args[2]) or 1, count = tonumber(args[3]) or 12,
            radius = tonumber(args[4]) or 18.0, x = at.x, y = at.y, z = at.z }
        return reply(source, raw, true, ("loot cluster tier=%s captured (%d total)"):format(
            tostring(args[2] or 1), #marks.loot))
    elseif kind == "vehicle" then
        marks.vehicles[#marks.vehicles + 1] = { record = args[2] or "Vehicle.v_standard2_archer_hella_player",
            x = at.x, y = at.y, z = at.z }
        return reply(source, raw, true, ("vehicle spot captured (%d total)"):format(#marks.vehicles))
    elseif kind == "holdout" then
        marks.holdouts[#marks.holdouts + 1] = { x = at.x, y = at.y, z = at.z,
            radius = tonumber(args[2]) or 12.0, count = tonumber(args[3]) or 4 }
        return reply(source, raw, true, ("holdout site captured (%d total)"):format(#marks.holdouts))
    elseif kind == "supply" then
        marks.supply[#marks.supply + 1] = { x = at.x, y = at.y, z = at.z }
        return reply(source, raw, true, ("supply point captured (%d total)"):format(#marks.supply))
    end
    reply(source, raw, false, "usage: lab.mark origin|ground|staging|landmark <key>|landing <key> [hot]|loot <tier> [count] [radius]|vehicle <record>|holdout|supply")
end, false)

-- ---------------------------------------------------------------------------
-- THE GROUND PROBE, and why the survey needed one.
--
-- A mark is useless without its z. Place a player above the ground and they
-- fall — and a fall is fatal from height even under god mode (E3). Place them
-- below it and they are inside the world. So every mark needs the real ground,
-- and there is no ground-query API.
--
-- The trick is noclip. With it on the player floats wherever they are put; turn
-- it off and they fall exactly once, land, and their settled z IS the ground.
-- Measured 2026-09-02: dropped from 30 m onto Pacifica's coast, the player
-- landed at 5.78756 and survived — `char.state` even reports `landing=death`
-- while health stays full, so the landing state is not a life verdict.
--
-- `lab.probe <x> <y> [from]` automates the whole cycle so a surveyor captures a
-- point in one command instead of four.
-- ---------------------------------------------------------------------------
local probing = false

RegisterCommand("lab.probe", function(source, args, raw)
    -- args[6] is the surveyor. Without it a survey driven from the Warden
    -- console (source = 0, no player) always answered "player only" -- which is
    -- exactly how the whole survey is driven, so the verb was unusable there.
    local id = targetOf(source, args[6])
    if id == nil then return reply(source, raw, false, "player only") end
    if probing then return reply(source, raw, false, "a probe is already running") end
    local x, y = tonumber(args[1]), tonumber(args[2])
    if x == nil or y == nil then
        return reply(source, raw, false, "usage: lab.probe <x> <y> [dropFrom] [markKind] [markKey] [playerId]")
    end
    local from = tonumber(args[3]) or 60.0
    local markKind, markKey = args[4], args[5]

    probing = true
    CreateThread(function()
        TriggerClientEvent("cordonlab:noclip", id, true)
        Wait(400)
        placeAt(id, x, y, from, 0.0)
        Wait(2500)
        TriggerClientEvent("cordonlab:noclip", id, false)
        -- Long enough for a 60 m fall plus the landing settle. A probe that
        -- reads too early reports the air it was falling through.
        Wait(5000)
        local at = positionOf(id)
        probing = false
        if at == nil then
            return reply(source, raw, false, ("probe %.1f,%.1f: position unreadable"):format(x, y))
        end
        local drifted = math.sqrt((at.x - x) ^ 2 + (at.y - y) ^ 2)
        local note = ""
        if drifted > 6.0 then
            -- The lander slid. Common on a slope or a roof edge, and it means
            -- the z belongs to where they ENDED, not where they were aimed.
            note = (" DRIFTED %.1fm — re-probe or accept %.1f,%.1f"):format(drifted, at.x, at.y)
        end
        if markKind ~= nil then
            -- Capture straight into the mark tables, so a probe and a mark are
            -- one action rather than two that can disagree.
            local saved = { x = at.x, y = at.y, z = at.z }
            if markKind == "landing" then
                marks.landings[#marks.landings + 1] = { key = markKey or ("lz" .. tostring(#marks.landings + 1)),
                    x = at.x, y = at.y, z = at.z, hot = false }
            elseif markKind == "landmark" then
                marks.landmarks[#marks.landmarks + 1] = { key = markKey or ("lm" .. tostring(#marks.landmarks + 1)),
                    x = at.x, y = at.y, z = at.z }
            elseif markKind == "loot" then
                marks.loot[#marks.loot + 1] = { tier = tonumber(markKey) or 1, count = 12, radius = 18.0,
                    x = at.x, y = at.y, z = at.z }
            elseif markKind == "staging" then
                marks.misc.staging = saved
            end
        end
        reply(source, raw, true, ("probe %.1f,%.1f -> ground z=%.3f life=%s%s%s"):format(
            x, y, at.z, lifeOf(id), note,
            markKind and (" [captured as " .. tostring(markKind) .. "]") or ""))
    end)
end, false)

-- lab.probe.line <x> <y> <dx> <dy> <count> -- probe a row of points, one every
-- `dx,dy`, capturing each ground z. This is how a district gets surveyed in
-- minutes instead of an afternoon.
RegisterCommand("lab.probe.line", function(source, args, raw)
    local id = targetOf(source, args[6])
    if id == nil then return reply(source, raw, false, "player only") end
    local x, y = tonumber(args[1]), tonumber(args[2])
    local dx, dy = tonumber(args[3]) or 100.0, tonumber(args[4]) or 0.0
    local count = math.min(tonumber(args[5]) or 5, 20)
    if x == nil or y == nil then
        return reply(source, raw, false, "usage: lab.probe.line <x> <y> <dx> <dy> <count> [playerId]")
    end
    reply(source, raw, true, ("probing %d points from %.0f,%.0f step %.0f,%.0f"):format(count, x, y, dx, dy))
    CreateThread(function()
        local results = {}
        for index = 0, count - 1 do
            local px, py = x + dx * index, y + dy * index
            TriggerClientEvent("cordonlab:noclip", id, true)
            Wait(400)
            placeAt(id, px, py, 60.0, 0.0)
            Wait(2200)
            TriggerClientEvent("cordonlab:noclip", id, false)
            Wait(4500)
            local at = positionOf(id)
            if at ~= nil then
                results[#results + 1] = ("%.0f,%.0f=%.2f"):format(px, py, at.z)
                log(("probe.line %.1f,%.1f -> z=%.3f (landed %.1f,%.1f)"):format(px, py, at.z, at.x, at.y))
            else
                results[#results + 1] = ("%.0f,%.0f=?"):format(px, py)
            end
        end
        reply(source, raw, true, "probe.line done: " .. table.concat(results, "  "))
    end)
end, false)

-- lab.probe.grid <x0> <y0> <step> <cols> <rows> -- probe a whole rectangle and
-- classify every point. This is the survey: one command, and what comes back is
-- a ground map with the water and the voids already named.
--
-- Classification, from the measurements of pass 1:
--   z between -1.5 and -0.4, repeated  -> WATER (a sea surface is flat; no
--                                        street in Night City is that flat over
--                                        hundreds of metres)
--   position unreadable                -> VOID (fell out of the world; no
--                                        collision at all)
--   anything else                      -> LAND, and the z is the ground
RegisterCommand("lab.probe.grid", function(source, args, raw)
    local id = targetOf(source, args[6])
    if id == nil then return reply(source, raw, false, "player only") end
    local x0, y0 = tonumber(args[1]), tonumber(args[2])
    local step = tonumber(args[3]) or 100.0
    local cols = math.min(tonumber(args[4]) or 5, 12)
    local rows = math.min(tonumber(args[5]) or 5, 12)
    if x0 == nil or y0 == nil then
        return reply(source, raw, false, "usage: lab.probe.grid <x0> <y0> <step> <cols> <rows> [playerId]")
    end
    reply(source, raw, true, ("probing %dx%d grid from %.0f,%.0f step %.0f — about %d s"):format(
        cols, rows, x0, y0, step, cols * rows * 7))
    CreateThread(function()
        local land, water, void, stuck = 0, 0, 0, 0
        -- SERPENTINE ORDER, and it is the fix for the false voids.
        --
        -- Probing left-to-right on every row means each new row begins with a
        -- jump back across the whole row — up to 750 m in these sweeps. After a
        -- jump that long the world has not finished streaming, the surveyor
        -- falls through terrain that is genuinely there, and the point is
        -- recorded as a void. That is exactly the pattern the data showed: the
        -- first point of a row voided while the same coordinate read LAND when
        -- it was reached from next door.
        --
        -- Alternating the direction makes every step one `step` long, so the
        -- world is never asked to load more than it already has.
        for row = 0, rows - 1 do
            for index = 0, cols - 1 do
                local col = (row % 2 == 0) and index or (cols - 1 - index)
                local px, py = x0 + col * step, y0 + row * step

                -- EVERY POINT STARTS BY HEALING THE SURVEYOR.
                --
                -- Measured twice: once the surveyor dies in a void, the noclip
                -- RELEASE stops taking effect for the rest of the session, and
                -- every later point then floats at the drop altitude. The cause
                -- is that a dead or mid-transition client does not act on the
                -- travel call — so the fix is not to send it more carefully, it
                -- is to guarantee a living, grounded surveyor before each probe.
                if lifeOf(id) ~= "alive" then
                    placeAt(id, px, py, 5.0, 0.0)
                    Wait(3000)
                end

                TriggerClientEvent("cordonlab:noclip", id, true)
                Wait(350)
                placeAt(id, px, py, 60.0, 0.0)
                Wait(2000)
                TriggerClientEvent("cordonlab:noclip", id, false)
                Wait(4200)
                local at = positionOf(id)

                -- One retry, because the release is the step that fails. If the
                -- surveyor is still at the drop altitude, ask again now that
                -- they are certainly alive and settled.
                if at ~= nil and math.abs(at.z - 60.0) < 0.5 and lifeOf(id) == "alive" then
                    TriggerClientEvent("cordonlab:noclip", id, false)
                    Wait(3500)
                    at = positionOf(id)
                end
                -- A probe that reports the DROP ALTITUDE never fell. It happens
                -- once the surveyor has died: the placement lands a corpse, the
                -- noclip release does nothing, and every later point then reads
                -- 60.000 and looks like a plateau of perfectly flat ground.
                -- Measured 2026-09-02, and it silently poisoned 28 of 42 points
                -- before the repeated identical z gave it away. Treat it as a
                -- FAILED probe, not as terrain.
                local phase = lifeOf(id)
                if at ~= nil and math.abs(at.z - 60.0) < 0.5 then
                    stuck = stuck + 1
                    log(("GRID %.0f,%.0f NO-LANDING (still at drop altitude, life=%s)"):format(px, py, phase))
                    -- Recover before the next point rather than carrying the
                    -- fault forward: a dead surveyor measures nothing.
                    placeAt(id, px, py, 5.0, 0.0)
                    Wait(2500)
                elseif at == nil then
                    void = void + 1
                    log(("GRID %.0f,%.0f VOID (unreadable, life=%s)"):format(px, py, phase))
                    placeAt(id, px, py, 5.0, 0.0)
                    Wait(2500)
                elseif at.z < -60.0 then
                    void = void + 1
                    log(("GRID %.0f,%.0f VOID (fell to %.1f)"):format(px, py, at.z))
                    placeAt(id, px, py, 5.0, 0.0)
                    Wait(2500)
                elseif at.z > -1.5 and at.z < -0.4 then
                    water = water + 1
                    log(("GRID %.0f,%.0f WATER z=%.2f"):format(px, py, at.z))
                else
                    land = land + 1
                    log(("GRID %.0f,%.0f LAND z=%.3f"):format(px, py, at.z))
                end
            end
        end
        reply(source, raw, true, ("probe.grid done: land=%d water=%d void=%d failed=%d of %d"):format(
            land, water, void, stuck, cols * rows))
    end)
end, false)

-- lab.marks -- print everything captured, as pasteable Lua, and the cell each
-- mark falls in so the surveyor can see the coverage without a map.
RegisterCommand("lab.marks", function(source, _, raw)
    local function cell(x, y)
        if gridOrigin == nil then return "?" end
        local col = math.floor((x - gridOrigin.x) / 100.0) + 1
        local row = math.floor((y - gridOrigin.y) / 100.0) + 1
        return ("%d:%d"):format(col, row)
    end
    log("---- survey dump ----")
    if gridOrigin ~= nil then
        log(("Pacifica.grid.origin = { x = %.3f, y = %.3f }"):format(gridOrigin.x, gridOrigin.y))
    end
    if groundDefault ~= nil then
        log(("Pacifica.grid.groundDefault = %.3f"):format(groundDefault))
    end
    if marks.misc.staging ~= nil then
        local s = marks.misc.staging
        log(("Pacifica.staging.position = { x = %.3f, y = %.3f, z = %.3f }"):format(s.x, s.y, s.z))
    end
    for _, m in ipairs(marks.landmarks) do
        log(('  { key = "%s", position = { x = %.3f, y = %.3f, z = %.3f } },  -- cell %s'):format(
            m.key, m.x, m.y, m.z, cell(m.x, m.y)))
    end
    for _, m in ipairs(marks.landings) do
        log(('  { key = "%s", position = { x = %.3f, y = %.3f, z = %.3f }, hot = %s },  -- cell %s'):format(
            m.key, m.x, m.y, m.z, tostring(m.hot), cell(m.x, m.y)))
    end
    for index, m in ipairs(marks.loot) do
        log(('  { key = "c%d", tier = %d, count = %d, radius = %.1f, position = { x = %.3f, y = %.3f, z = %.3f } },  -- cell %s'):format(
            index, m.tier, m.count, m.radius, m.x, m.y, m.z, cell(m.x, m.y)))
    end
    for index, m in ipairs(marks.vehicles) do
        log(('  { key = "v%d", record = "%s", position = { x = %.3f, y = %.3f, z = %.3f } },  -- cell %s'):format(
            index, m.record, m.x, m.y, m.z, cell(m.x, m.y)))
    end
    for index, m in ipairs(marks.holdouts) do
        log(('  { key = "h%d", radius = %.1f, count = %d, position = { x = %.3f, y = %.3f, z = %.3f } },  -- cell %s'):format(
            index, m.radius, m.count, m.x, m.y, m.z, cell(m.x, m.y)))
    end
    for index, m in ipairs(marks.supply) do
        log(('  { key = "s%d", position = { x = %.3f, y = %.3f, z = %.3f } },  -- cell %s'):format(
            index, m.x, m.y, m.z, cell(m.x, m.y)))
    end
    reply(source, raw, true, ("survey: origin=%s ground=%s staging=%s landmarks=%d landings=%d loot=%d vehicles=%d holdouts=%d supply=%d (dump in the server log)"):format(
        gridOrigin ~= nil and "yes" or "NO", groundDefault ~= nil and "yes" or "NO",
        marks.misc.staging ~= nil and "yes" or "NO",
        #marks.landmarks, #marks.landings, #marks.loot, #marks.vehicles, #marks.holdouts, #marks.supply))
end, false)

-- ------------------------------------------------------------ join spawn --
-- This profile carries no gamemode and excludes freeroam, so nobody would place
-- a joining player: the client then sits in the pristine save's life loop
-- (resync requests, movement suppressed, no snapshots). The laboratory takes
-- freeroam's join placement verbatim so a test client lands somewhere real.

local LAB_SPAWN = { position = { x = -1160.499, y = 2019.064, z = 7.763 }, heading = 104.0 } -- Kabuki FFA mark 01
local joinSpawns = {}

local function forceSpawnAt(playerId, point)
    local life = Open77.players.getLifeState(playerId)
    if life == nil then return false, "player_not_found" end
    if life.phase == "alive" or life.phase == "recovering" then
        local ok, reason = Open77.players.kill(playerId, { cause = "script", weapon = "cordonlab:join_spawn" })
        if not ok then return false, reason end
    elseif life.phase ~= "dead" then
        return false, "transition_in_progress"
    end
    return Open77.players.respawn(playerId, {
        position = point.position, heading = point.heading or 0,
        bucket = life.bucket or 0, health = 1.0, graceMs = 3000,
    })
end

local function joinSpawn(playerId, why)
    if joinSpawns[playerId] == "pending" then return end
    joinSpawns[playerId] = "pending"
    local startedAt = GetGameTimer()
    local function attempt()
        if joinSpawns[playerId] ~= "pending" then return end
        local ok, reason = forceSpawnAt(playerId, LAB_SPAWN)
        if ok then
            joinSpawns[playerId] = "complete"
            log(("join spawn player=%d placed at Kabuki mark (%s)"):format(playerId, tostring(why)))
            return
        end
        if (reason == "player_not_found" or reason == "transition_in_progress") and GetGameTimer() - startedAt < 30000 then
            SetTimeout(250, attempt)
            return
        end
        joinSpawns[playerId] = nil
        log(("join spawn player=%d rejected: %s"):format(playerId, tostring(reason)))
    end
    attempt()
end

-- ---------------------------------------------------------------------------
-- THE JOIN SPAWN IS OFF WHEN A GAMEMODE OWNS SPAWN.
--
-- This laboratory placed every joining player at a Kabuki mark, which was
-- correct while the profile carried no gamemode. It is WRONG now that
-- open77_cordon is loaded: two resources placing the same player is the
-- one-gamemode-per-server trap, and the observed symptom was a client landing
-- in Kabuki instead of Cordon's staging area.
--
-- The lab cannot ask the mode whether it exists — server resources cannot link,
-- and TriggerEvent walks one VM — so this is a flag, defaulting OFF, and
-- `lab.spawn` remains as the manual verb for a profile with no gamemode.
-- ---------------------------------------------------------------------------
local autoJoinSpawn = false

RegisterCommand("lab.autospawn", function(source, args, raw)
    autoJoinSpawn = (args[1] or "on"):lower() ~= "off"
    reply(source, raw, true, ("lab auto join-spawn %s"):format(autoJoinSpawn and "ON" or "OFF"))
end, false)

AddEventHandler("onPlayerReady", function(playerIdStr, detail)
    local playerId = tonumber(playerIdStr)
    if playerId == nil then return end
    log(("EVENT onPlayerReady player=%d detail=%s"):format(playerId, tostring(detail)))
    if autoJoinSpawn then joinSpawn(playerId, detail) end
end)

AddEventHandler("onPlayerDisconnected", function(playerIdStr)
    local playerId = tonumber(playerIdStr)
    if playerId ~= nil then joinSpawns[playerId] = nil; verified[playerId] = nil end
end)

-- lab.spawn [playerId] -- place now (for a player who joined before this loaded).
RegisterCommand("lab.spawn", function(source, args, raw)
    local id = targetOf(source, args[1])
    if id == nil then return reply(source, raw, false, "player only") end
    joinSpawns[id] = nil
    joinSpawn(id, "lab.spawn")
    reply(source, raw, true, ("join spawn requested for player=%d"):format(id))
end, false)

log("laboratory ready: lab.spawn lab.where lab.drop lab.ghost lab.hurt lab.hurt.tick lab.kill lab.revive lab.lights lab.lights.clear lab.car lab.av lab.av.eject lab.av.stop lab.vehicles.clear lab.team lab.place lab.loot lab.verified lab.god")

-- lab.exec <playerId> <lua...> -- run Lua inside the player's BUNDLED open77_debug
-- VM, which is the only place a bridge command can run while a session is
-- active (`session.fact`, `world.around`, ... are lab-only and refuse over the
-- ordinary bridge with `local_lab_command_disabled`). Inside the code,
-- `Open77.debug.command('<bridge command>')` runs the privileged path.
--
-- The reply arrives on `open77:debug:result`. It is logged HERE because the
-- open77_debug SERVER resource is not on this server's load list, so nothing
-- else would hear it. Loopback laboratory only, like everything in this file.
local execSerial = 0

RegisterNetEvent("open77:debug:result", function(requestId, ok, text)
    log(("exec result request=%s ok=%s %s"):format(tostring(requestId), tostring(ok), tostring(text)))
end)

local function execOn(target, code)
    execSerial = execSerial + 1
    local requestId = ("lab:%d:%d"):format(target, execSerial)
    local sent, reason = TriggerClientEvent("open77:debug:exec", target, requestId, code)
    if sent == false then return nil, tostring(reason) end
    return requestId
end

RegisterCommand("lab.exec", function(source, args, raw)
    local target = tonumber(args[1])
    if target == nil or target <= 0 then
        return reply(source, raw, false, "usage: lab.exec <playerId> <lua>")
    end
    local parts = {}
    for index = 2, (args.n or #args) do parts[#parts + 1] = tostring(args[index] or "") end
    local code = table.concat(parts, " ")
    if code == "" then return reply(source, raw, false, "usage: lab.exec <playerId> <lua>") end
    local requestId, reason = execOn(target, code)
    if requestId == nil then return reply(source, raw, false, "dispatch failed: " .. reason) end
    reply(source, raw, true, "queued request=" .. requestId)
end, false)

-- lab.bridge <playerId> <bridge command...> -- one privileged bridge command.
RegisterCommand("lab.bridge", function(source, args, raw)
    local target = tonumber(args[1])
    if target == nil or target <= 0 then
        return reply(source, raw, false, "usage: lab.bridge <playerId> <command...>")
    end
    local parts = {}
    for index = 2, (args.n or #args) do parts[#parts + 1] = tostring(args[index] or "") end
    local command = table.concat(parts, " ")
    if command == "" then return reply(source, raw, false, "usage: lab.bridge <playerId> <command...>") end
    local requestId, reason = execOn(target, ("return Open77.debug.command(%q)"):format(command))
    if requestId == nil then return reply(source, raw, false, "dispatch failed: " .. reason) end
    reply(source, raw, true, ("queued request=%s command=%s"):format(requestId, command))
end, false)

-- lab.facts <playerId> <name>... -- read several quest facts on the player's client.
RegisterCommand("lab.facts", function(source, args, raw)
    local target = tonumber(args[1])
    if target == nil or target <= 0 or args[2] == nil then
        return reply(source, raw, false, "usage: lab.facts <playerId> <name>...")
    end
    local queued = 0
    for index = 2, (args.n or #args) do
        local name = tostring(args[index] or "")
        if name ~= "" then
            local requestId = execOn(target, ("return Open77.debug.command(%q)"):format("session.fact " .. name))
            if requestId ~= nil then queued = queued + 1 end
        end
    end
    reply(source, raw, true, ("queued %d fact reads on player=%d"):format(queued, target))
end, false)
