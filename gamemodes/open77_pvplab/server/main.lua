-- Phase 0 laboratory for the PvP arena plan.
--
-- Every command here answers one experiment from
-- docs/gamemode-pvp-arena-plan.md section 11, Phase 0. The point is to
-- MEASURE, so each command prints what it asked for and what it got back,
-- including the refusal reason, rather than succeeding quietly.
--
-- The wall experiments all go through one primitive: a ring of props around
-- the caller. A ring rather than a single prop in front, because
-- Open77.players.position does not carry a heading, and because a ring is
-- what the real wall is anyway -- so E1 is already a rehearsal of Phase 4.

local props = {}   -- [id] = { model, visible, scale, bucket, at }
local npcs = {}    -- [id] = { template, bucket, at }
local damageLog = {}
local armRequests = {}

local function log(text)
    print("[pvplab] " .. tostring(text))
end

local function reply(source, raw, ok, text)
    log(text)
    if source ~= nil and source > 0 then
        TriggerClientEvent("open77:command:result", source, raw or "", ok == true, text)
    end
end

local function callerPosition(playerId)
    local position = Open77.players.position(playerId)
    if position == nil then return nil, "position_unknown" end
    return {
        x = tonumber(position.x) or 0.0,
        y = tonumber(position.y) or 0.0,
        z = tonumber(position.z) or 0.0,
        bucket = tonumber(position.bucket) or 0,
    }
end

-- ---------------------------------------------------------------- E1-E4 ---

-- One ring of props around a centre. Returns created, refused, firstReason.
local function ring(centre, options)
    local count = options.count or 8
    local radius = options.radius or 4.0
    local created, refused, firstReason = 0, 0, nil

    for index = 0, count - 1 do
        local angle = (index / count) * math.pi * 2.0
        local definition = {
            model = options.model,
            position = {
                x = centre.x + math.cos(angle) * radius,
                y = centre.y + math.sin(angle) * radius,
                z = centre.z,
            },
            -- Face the panel tangentially so a flat mesh presents its width to
            -- the player walking outward, not its edge.
            yaw = (angle * 180.0 / math.pi) + 90.0,
            bucket = options.bucket or centre.bucket,
            collision = true,
            visible = options.visible ~= false,
            streamingRadius = 200.0,
        }
        if options.scale ~= nil then definition.scale = options.scale end

        local id, reason = Open77.props.create(definition)
        if id == nil then
            refused = refused + 1
            firstReason = firstReason or tostring(reason)
        else
            created = created + 1
            props[id] = {
                model = options.model,
                visible = definition.visible,
                scale = options.scale,
                bucket = definition.bucket,
                at = definition.position,
            }
        end
    end
    return created, refused, firstReason
end

-- pvplab.ring <model> <radius> <visible 0|1> [scaleX scaleY scaleZ] [count]
--
-- E1 = visible 1, no scale.  E2 = visible 0, no scale.  E3 = any visibility
-- with a scale. The caller then walks outward and reads pvplab.where.
RegisterCommand("pvplab.ring", function(source, args, raw)
    if source == nil or source <= 0 then return reply(source, raw, false, "player only") end
    local model = args[1] or "barrier.concrete"
    local radius = tonumber(args[2]) or 4.0
    local visible = (args[3] or "1") ~= "0"
    local scale = nil
    if args[4] ~= nil and args[5] ~= nil and args[6] ~= nil then
        scale = { x = tonumber(args[4]) or 1.0, y = tonumber(args[5]) or 1.0, z = tonumber(args[6]) or 1.0 }
    end
    local count = tonumber(args[7]) or 8

    local centre, reason = callerPosition(source)
    if centre == nil then return reply(source, raw, false, "no position: " .. tostring(reason)) end

    local created, refused, firstReason = ring(centre, {
        model = model, radius = radius, visible = visible, scale = scale,
        count = count, bucket = centre.bucket,
    })

    reply(source, raw, created > 0, ("ring model=%s radius=%.1f visible=%s scale=%s count=%d -> created=%d refused=%d reason=%s centre=%.2f,%.2f,%.2f bucket=%d"):format(
        model, radius, tostring(visible),
        scale and ("%.1fx%.1fx%.1f"):format(scale.x, scale.y, scale.z) or "unit",
        count, created, refused, tostring(firstReason), centre.x, centre.y, centre.z, centre.bucket))
end, false)

-- pvplab.bucketring <model> — E4: one ring here, one ring in bucket+1.
-- The caller should see exactly one of them.
RegisterCommand("pvplab.bucketring", function(source, args, raw)
    if source == nil or source <= 0 then return reply(source, raw, false, "player only") end
    local model = args[1] or "barrier.concrete"
    local centre, reason = callerPosition(source)
    if centre == nil then return reply(source, raw, false, "no position: " .. tostring(reason)) end

    local here = ring(centre, { model = model, radius = 4.0, bucket = centre.bucket, count = 6 })
    local there = ring(centre, { model = model, radius = 7.0, bucket = centre.bucket + 1, count = 6 })

    reply(source, raw, true, ("bucketring bucket=%d created=%d, bucket=%d created=%d -- you must see ONLY the inner ring"):format(
        centre.bucket, here, centre.bucket + 1, there))
end, false)

-- pvplab.quota <model> <count> — how many props this resource can hold before
-- the 256 per-owner ceiling refuses one. Sets the instance budget in the plan.
RegisterCommand("pvplab.quota", function(source, args, raw)
    if source == nil or source <= 0 then return reply(source, raw, false, "player only") end
    local model = args[1] or "barrier.concrete"
    local target = math.min(tonumber(args[2]) or 300, 400)
    local centre, reason = callerPosition(source)
    if centre == nil then return reply(source, raw, false, "no position: " .. tostring(reason)) end

    local created, firstReason = 0, nil
    for index = 1, target do
        -- Stacked far below the world so nothing is visible or walkable; this
        -- measures the ceiling, not the geometry.
        local id, failure = Open77.props.create({
            model = model,
            position = { x = centre.x, y = centre.y, z = centre.z - 400.0 - index },
            bucket = centre.bucket,
            streamingRadius = 10.0,
        })
        if id == nil then firstReason = tostring(failure) break end
        created = created + 1
        props[id] = { model = model, bucket = centre.bucket, at = "quota" }
    end
    reply(source, raw, true, ("quota model=%s created=%d of %d, first refusal=%s"):format(
        model, created, target, tostring(firstReason)))
end, false)

-- Both loops read the AUTHORITATIVE registry rather than this VM's tables.
-- A hot reload hands the successor an empty `props`/`npcs` table while the
-- objects themselves are still alive in the world, so anything that iterates
-- the local table silently becomes a no-op after the first edit -- and then
-- leaks every object it was supposed to own. Open77.props.all/Open77.npcs.all
-- are already filtered to this resource.
RegisterCommand("pvplab.clear", function(source, _, raw)
    local removedProps, removedNpcs = 0, 0
    for _, prop in ipairs(Open77.props.all() or {}) do
        if Open77.props.remove(prop.id) then removedProps = removedProps + 1 end
    end
    for _, npc in ipairs(Open77.npcs.all() or {}) do
        if Open77.npcs.remove(npc.id) then removedNpcs = removedNpcs + 1 end
    end
    props, npcs = {}, {}
    reply(source, raw, true, ("cleared props=%d npcs=%d"):format(removedProps, removedNpcs))
end, false)

-- ---------------------------------------------------------------- E6-E8 ---

-- The one primitive both spawn commands share: a body in front of the caller.
-- `Open77.players.position` carries no heading, so "in front of me" is only
-- expressible when the caller supplies their yaw (the debug bridge's `position`
-- prints it). Heading maps to a direction as (-sin, cos), measured against this
-- build by walking a known yaw and differencing the positions.
--
-- `damagePolicy` matters more than it looks. `NpcReplication::ApplyState`
-- installs a `gameGodModeSystem` Immortal source keyed `Open77.ProxyDamageBarrier`
-- on the projected puppet for ANY policy other than `mortal`, so an experiment
-- about native damage that spawns non-mortal measures the barrier, not the engine.
local function spawnInFront(source, template, distance, yaw, options)
    options = options or {}
    local centre, reason = callerPosition(source)
    if centre == nil then return nil, "no position: " .. tostring(reason) end

    local offsetX, offsetY = distance, 0.0
    if yaw ~= nil then
        local radians = math.rad(yaw)
        offsetX = -math.sin(radians) * distance
        offsetY = math.cos(radians) * distance
    end

    local definition = {
        template = template,
        position = { x = centre.x + offsetX, y = centre.y + offsetY, z = centre.z },
        yaw = (yaw or 0.0) + 180.0,
        bucket = centre.bucket,
        aiMode = options.aiMode or Open77.npcs.ai.tasks,
        damagePolicy = options.damagePolicy or Open77.npcs.damage.mortal,
        health = 100,
        maxHealth = 100,
        streamingRadius = 180,
    }
    if options.loadout ~= nil then definition.loadout = options.loadout end

    local id, failure = Open77.npcs.create(definition)
    if id == nil then
        return nil, ("npc create refused template=%s reason=%s"):format(template, tostring(failure))
    end
    npcs[id] = { template = template, bucket = centre.bucket, at = definition.position }
    return id, ("npc id=%s template=%s policy=%s ai=%s bucket=%d at %.2f,%.2f,%.2f (yaw=%s)"):format(
        tostring(id), template, tostring(definition.damagePolicy), tostring(definition.aiMode),
        centre.bucket, definition.position.x, definition.position.y, definition.position.z,
        yaw and ("%.1f"):format(yaw) or "none")
end

-- pvplab.npc [template] [distance] [yaw] -- a mortal NPC in front of the caller.
-- E6 was then: shoot it, and watch onNpcDamaged / onNpcDied below. What that
-- measurement is actually worth is reconsidered under E9-E12, next block.
RegisterCommand("pvplab.npc", function(source, args, raw)
    if source == nil or source <= 0 then return reply(source, raw, false, "player only") end
    local id, message = spawnInFront(source, args[1] or "hostile_female_ranged_lab",
        tonumber(args[2]) or 5.0, tonumber(args[3]))
    reply(source, raw, id ~= nil, id ~= nil and (message .. " -- now shoot it") or message)
end, false)

-- ----------------------------------------------------------------- E9-E12 ---
--
-- E6 concluded "a player's gunfire does not damage a server-owned NPC" from two
-- NPCs still reading `hp=100/100` afterwards. Two independent defects make that
-- conclusion unsafe, and this block exists to separate them.
--
-- 1. THE SUBJECT. One of the two aliases resolves to `Character.Panam`, whose
--    TweakDB record carries the tag `Invulnerable`
--    (docs/generated/npc-records-2.31.csv) and which was already measured in
--    game on 2026-08-03 as "PNJ protege: impossible a viser/frapper"
--    (docs/research/player-proxy-and-tweakdb.md). Shooting her measures a quest
--    protection, not the engine.
-- 2. THE READOUT. `Open77.npcs.get(id).health` is the SERVER ledger. No wire
--    message exists by which a client could report an NPC hit -- there is no
--    `SubmitNpcHit` in the protocol -- so that number reads 100 whatever the
--    engine did on the shooter's screen. The old readout could not have
--    detected a successful native hit even if one had happened.
--
-- The replacement readouts are all client-side, and all already exist:
--   pvplab.ids                       -> the puppet's Open77 cyber id, per NPC
--   godmode state <cyberId>          -> invulnerable=yes|no immortal=yes|no
--   world.around <r> 64 | 32 | 128   -> engine attitude: hostile | friendly | neutral
--   world.around <r> 2048 | 4096     -> engine liveness: alive | dead
--   world.attitude <cyberId> <group> -> change the attitude, then re-shoot
-- The last four are debug-bridge commands; `pvplab.ids` hands over the id they
-- need. One bit in a `world.around` filter mask makes "any" and "all" coincide,
-- so a single-bit query is a clean classification rather than a widened search.

-- pvplab.solo [template] [distance] [yaw] -- clear the lab, then spawn EXACTLY
-- one NPC. Exactly one, because every client-side readout above identifies a
-- puppet by proximity or by crosshair, and two bodies make each of them
-- ambiguous. This is the command E9-E12 all start from.
RegisterCommand("pvplab.solo", function(source, args, raw)
    if source == nil or source <= 0 then return reply(source, raw, false, "player only") end
    local removed = 0
    for _, npc in ipairs(Open77.npcs.all() or {}) do
        if Open77.npcs.remove(npc.id) then removed = removed + 1 end
    end
    npcs = {}
    local id, message = spawnInFront(source, args[1] or "hostile_female_ranged_lab",
        tonumber(args[2]) or 5.0, tonumber(args[3]))
    reply(source, raw, id ~= nil, ("solo removed=%d %s"):format(removed, message))
end, false)

-- pvplab.ids -- the bridge between the two halves of every E9-E12 measurement.
-- Neutral from creation, with native AI and reaction components left enabled.
-- A dodge is still possible and must invalidate the trial rather than pass it.
RegisterCommand("pvplab.contact", function(source, args, raw)
    if source == nil or source <= 0 then return reply(source, raw, false, "player only") end
    for id in pairs(npcs) do Open77.npcs.remove(id) end
    npcs = {}
    local id, message = spawnInFront(source, "hostile_female_ranged_lab",
        tonumber(args[1]) or 4.0, tonumber(args[2]) or 0.0,
        { loadout = { combat = { attitude = { default = "neutral" } } } })
    reply(source, raw, id ~= nil, "contact " .. message)
end, false)

-- pvplab.ids -- the bridge between the two halves of every E9-E12 measurement.
--
-- The server knows the canonical NPC id; the debug bridge only speaks Open77
-- cyber ids, which exist on the client. `Open77.npcs.entity(npcId)` is exactly
-- that id (`ClientResourceHost` copies `npc.entity.value` straight into the
-- client snapshot), so the client script answers with the mapping and the
-- handler below prints it. Feed the `entity=` value to `godmode state` and to
-- `world.attitude`.
RegisterCommand("pvplab.ids", function(source, _, raw)
    if source == nil or source <= 0 then return reply(source, raw, false, "player only") end
    local sent, reason = TriggerClientEvent("pvplab:ids", source)
    reply(source, raw, sent ~= false, ("ids requested sent=%s reason=%s -- answer follows"):format(
        tostring(sent), tostring(reason)))
end, false)

-- The client formats and this only prints: see the header of client/main.lua
-- for why the payload is one string rather than an array of tables.
RegisterNetEvent("pvplab:ids:result", function(description)
    reply(source, "pvplab.ids", true, "ids " .. tostring(description))
end)

-- pvplab.npcpolicy <mortal|immortal|invulnerable> -- the client installs an
-- Immortal god-mode source for every policy except `mortal`, so this is the
-- switch that decides whether Open77 itself is protecting the body.
RegisterCommand("pvplab.npcpolicy", function(source, args, raw)
    local wanted = tostring(args[1] or "mortal")
    local policy = Open77.npcs.damage[wanted]
    if policy == nil then
        return reply(source, raw, false, "usage: pvplab.npcpolicy <mortal|immortal|invulnerable>")
    end
    local changed = 0
    for _, npc in ipairs(Open77.npcs.all() or {}) do
        if Open77.npcs.setDamagePolicy(npc.id, policy) then changed = changed + 1 end
    end
    reply(source, raw, changed > 0, ("npcpolicy %s applied=%d"):format(wanted, changed))
end, false)

-- pvplab.npcpricing <platform|resource> -- G (V5): who prices a player's hit on
-- this lab's Mortal NPCs. `resource` (the default) means nobody here does: the
-- lab only logs engine hits, so a shot plays its reaction and changes nothing.
-- `platform` opts in to the platform's bounded pricing of the shooter's own
-- engine price (open77:npcs:hit). Read back with `npc.life <id>` on a client.
RegisterCommand("pvplab.npcpricing", function(source, args, raw)
    local wanted = args[1]
    if wanted ~= "platform" and wanted ~= "resource" then
        return reply(source, raw, false, "usage: pvplab.npcpricing <platform|resource>")
    end
    local changed = 0
    for _, npc in ipairs(Open77.npcs.all() or {}) do
        if Open77.npcs.setBehavior(npc.id, { hitPricing = wanted }) then changed = changed + 1 end
    end
    reply(source, raw, changed > 0, ("npcpricing %s applied=%d"):format(wanted, changed))
end, false)

RegisterCommand("pvplab.npccontact", function(source, args, raw)
    local wanted = args[1]
    if wanted ~= "on" and wanted ~= "off" then
        return reply(source, raw, false, "usage: pvplab.npccontact <on|off>")
    end
    local changed = 0
    for _, npc in ipairs(Open77.npcs.all() or {}) do
        if Open77.npcs.update(npc.id, { behavior = { vehicleContactEnabled = wanted == "on" } }) then
            changed = changed + 1
        end
    end
    reply(source, raw, changed > 0, ("npccontact %s applied=%d"):format(wanted, changed))
end, false)

-- pvplab.npcai <tasks|frozen|native> -- recorded for completeness, and expected
-- to change nothing visible. `aiMode` never reaches an engine call: the client
-- carries it into the Lua snapshot and branches on it nowhere. `frozen` is a
-- SERVER-side gate on tasks and leases only. So if a Maelstrom fights back in
-- `tasks` mode, that is not a defect in this command -- it is the vanilla
-- behaviour tree, which Open77 does not suppress.
RegisterCommand("pvplab.npcai", function(source, args, raw)
    local wanted = tostring(args[1] or "tasks")
    local mode = Open77.npcs.ai[wanted]
    if mode == nil then
        return reply(source, raw, false, "usage: pvplab.npcai <tasks|frozen|native>")
    end
    local changed = 0
    for _, npc in ipairs(Open77.npcs.all() or {}) do
        if Open77.npcs.setAiMode(npc.id, mode) then changed = changed + 1 end
    end
    reply(source, raw, changed > 0, ("npcai %s applied=%d"):format(wanted, changed))
end, false)

-- A stationary yaw change isolates observer turning from pathfinding/contact.
RegisterCommand("pvplab.npcface", function(source, args, raw)
    local x, y, z = tonumber(args[1]), tonumber(args[2]), tonumber(args[3])
    if not x or not y or not z then
        return reply(source, raw, false, "usage: pvplab.npcface <x> <y> <z>")
    end
    local changed = 0
    for _, npc in ipairs(Open77.npcs.all() or {}) do
        if Open77.npcs.tasks.face(npc.id, {x=x, y=y, z=z}) then changed = changed + 1 end
    end
    reply(source, raw, changed > 0, ("npcface queued=%d"):format(changed))
end, false)

-- pvplab.npcgun [record] -- E12 needs the bot holding something before native
-- combat can be observed at all. An empty canonical loadout is deliberately a
-- no-op in the client, so a bot without this command has no weapon to draw.
RegisterCommand("pvplab.npcgun", function(source, args, raw)
    local record = args[1] or "Items.Preset_Lexington_Default"
    local changed = 0
    for _, npc in ipairs(Open77.npcs.all() or {}) do
        if Open77.npcs.setLoadout(npc.id, { weapon = record }) then changed = changed + 1 end
    end
    reply(source, raw, changed > 0, ("npcgun %s applied=%d"):format(record, changed))
end, false)

-- pvplab.npchurt [amount] -- the CONTROL for E10. It exercises the scripted
-- damage path the gamemode uses today, so `onNpcDamaged` firing here and not
-- after gunfire distinguishes "the event plumbing is broken" from "the report
-- never happens" -- which is the whole point of reinterpreting E6.
RegisterCommand("pvplab.npchurt", function(source, args, raw)
    local amount = tonumber(args[1]) or 25
    local applied = 0
    for _, npc in ipairs(Open77.npcs.all() or {}) do
        if Open77.npcs.applyDamage(npc.id, amount, "resource:pvplab", "firearm") then
            applied = applied + 1
        end
    end
    reply(source, raw, applied > 0, ("npchurt amount=%s applied=%d -- expect onNpcDamaged"):format(
        tostring(amount), applied))
end, false)

-- pvplab.npcwatch [seconds] -- watches CANONICAL health for the duration and
-- reports every change. It is expected to report none while the player empties
-- a magazine: that is not a defect, it is the missing wire path, and having it
-- stated as a measurement is worth more than inferring it from a static read.
RegisterCommand("pvplab.npcwatch", function(source, args, raw)
    local seconds = math.min(math.max(tonumber(args[1]) or 10, 1), 120)
    local before = {}
    for _, npc in ipairs(Open77.npcs.all() or {}) do before[npc.id] = npc.health end
    reply(source, raw, true, ("npcwatch %ds started -- shoot now"):format(seconds))

    CreateThread(function()
        local deadline = seconds * 1000
        local elapsed, changes = 0, 0
        while elapsed < deadline do
            Wait(250)
            elapsed = elapsed + 250
            for _, npc in ipairs(Open77.npcs.all() or {}) do
                local previous = before[npc.id]
                if previous ~= nil and npc.health ~= previous then
                    changes = changes + 1
                    log(("npcwatch change npc=%s %s -> %s at %dms"):format(
                        tostring(npc.id), tostring(previous), tostring(npc.health), elapsed))
                end
                before[npc.id] = npc.health
            end
        end
        reply(source, "pvplab.npcwatch", true, ("npcwatch finished changes=%d"):format(changes))
    end)
end, false)

-- pvplab.templates — what the allowlist actually contains on this build.
RegisterCommand("pvplab.templates", function(source, _, raw)
    local list = Open77.npcs.templates()
    if type(list) ~= "table" then
        return reply(source, raw, false, "templates() returned " .. type(list))
    end
    local names = {}
    for _, template in ipairs(list) do
        names[#names + 1] = ("%s(%s)"):format(tostring(template.name), tostring(template.record))
    end
    reply(source, raw, true, ("templates n=%d: %s"):format(#names, table.concat(names, ", ")))
end, false)

-- pvplab.botshot <amount> — E7. Can an NPC be the attacker on a player?
-- If this is refused, bot damage has to attribute through attacker = 0.
RegisterCommand("pvplab.botshot", function(source, args, raw)
    if source == nil or source <= 0 then return reply(source, raw, false, "player only") end
    local amount = tonumber(args[1]) or 10
    local npcId
    for _, owned in ipairs(Open77.npcs.all() or {}) do npcId = owned.id break end
    if npcId == nil then return reply(source, raw, false, "spawn one with pvplab.npc first") end

    local before = Open77.players.getHealth(source)
    local ok, reason = Open77.players.damage(source, amount, {
        attacker = npcId, cause = "firearm",
    })
    local after = Open77.players.getHealth(source)
    reply(source, raw, ok == true, ("botshot attacker=%s amount=%d -> ok=%s reason=%s health %s -> %s"):format(
        tostring(npcId), amount, tostring(ok), tostring(reason),
        tostring(before), tostring(after)))
end, false)

-- pvplab.tasks — E8. Does the NPC actually path? Sends it to the caller.
RegisterCommand("pvplab.tasks", function(source, _, raw)
    if source == nil or source <= 0 then return reply(source, raw, false, "player only") end
    local npcId
    for _, owned in ipairs(Open77.npcs.all() or {}) do npcId = owned.id break end
    if npcId == nil then return reply(source, raw, false, "spawn one with pvplab.npc first") end

    local followId, followReason = Open77.npcs.tasks.follow(npcId, { type = "player", id = source }, {
        speed = "run", distance = 2.0,
    })
    local lookId = Open77.npcs.tasks.lookAt(npcId, { type = "player", id = source })
    reply(source, raw, followId ~= nil, ("tasks npc=%s follow=%s reason=%s lookAt=%s"):format(
        tostring(npcId), tostring(followId), tostring(followReason), tostring(lookId)))
end, false)

-- pvplab.npcstate — health, ai mode, task statuses. The read side of E6/E8.
RegisterCommand("pvplab.npcstate", function(source, _, raw)
    local lines = {}
    for _, owned in ipairs(Open77.npcs.all() or {}) do
        local id = owned.id
        local snapshot = Open77.npcs.get(id)
        if snapshot == nil then
            lines[#lines + 1] = ("%s=<gone>"):format(tostring(id))
        else
            local tasks = Open77.npcs.tasks.all(id) or {}
            local statuses = {}
            for _, task in ipairs(tasks) do
                statuses[#statuses + 1] = ("%s:%s"):format(tostring(task.type), tostring(task.status))
            end
            lines[#lines + 1] = ("%s hp=%s/%s ai=%s policy=%s tasks=[%s]"):format(
                tostring(id), tostring(snapshot.health), tostring(snapshot.maxHealth),
                tostring(snapshot.aiMode), tostring(snapshot.damagePolicy),
                table.concat(statuses, " "))
        end
    end
    reply(source, raw, true, #lines > 0 and table.concat(lines, " | ") or "no npcs")
end, false)


-- pvplab.arm [record] -- E6 needs the player holding a gun. The weapon API is
-- asynchronous and answers on open77:weapons:completed, so this reports the
-- request id and the completion handler below reports the verdict.
RegisterCommand("pvplab.arm", function(source, args, raw)
    if source == nil or source <= 0 then return reply(source, raw, false, "player only") end
    local record = args[1] or "Items.Preset_Lexington_Default"
    local requestId, reason = Open77.weapons.assign(source, record, 1,
        { active = true, addToInventory = true })
    if requestId == nil then
        return reply(source, raw, false, ("arm refused record=%s reason=%s"):format(
            record, tostring(reason)))
    end
    armRequests[tostring(requestId)] = { playerId = source, record = record }
    reply(source, raw, true, ("arm requested record=%s request=%s"):format(record, tostring(requestId)))
end, false)

AddEventHandler("open77:weapons:completed", function(
        playerId, requestId, operation, accepted, reason, result)
    local pending = armRequests[tostring(requestId)]
    if pending == nil then return end
    armRequests[tostring(requestId)] = nil
    result = type(result) == "table" and result or {}
    log(("arm %s player=%s accepted=%s reason=%s tweakDbId=%s"):format(
        tostring(operation), tostring(playerId), tostring(accepted),
        tostring(reason), tostring(result.tweakDbId)))
    if operation == "assign" and accepted == true then
        local ammoId = Open77.weapons.setAmmo(pending.playerId, 1,
            { reserve = 300, activate = true })
        log("arm ammo request=" .. tostring(ammoId))
    end
end)

-- ------------------------------------------------------------------- E5 ---

-- pvplab.team <teamId> — assign, then kill/respawn, so a second client can
-- test whether the assignment survived the placement.
RegisterCommand("pvplab.team", function(source, args, raw)
    if source == nil or source <= 0 then return reply(source, raw, false, "player only") end
    local teamId = tonumber(args[1]) or 1
    local ok, reason = Open77.combat.setTeam(source, teamId)
    reply(source, raw, ok == true, ("setTeam player=%d team=%d -> ok=%s reason=%s"):format(
        source, teamId, tostring(ok), tostring(reason)))
end, false)


-- pvplab.tp <x> <y> <z> [heading] -- Phase 1 reconnaissance.
--
-- Movement goes through kill -> respawn, never a transform write, which is the
-- same primitive the gamemode uses for every placement. That is deliberate
-- here rather than incidental: a raw teleport over any real distance drops the
-- player into unstreamed world, while the respawn transaction carries the
-- fade, the streaming preload and a grace window. Scouting a district on the
-- other side of the city is exactly the case that punishes the shortcut.
RegisterCommand("pvplab.tp", function(source, args, raw)
    if source == nil or source <= 0 then return reply(source, raw, false, "player only") end
    local x, y, z = tonumber(args[1]), tonumber(args[2]), tonumber(args[3])
    if x == nil or y == nil or z == nil then
        return reply(source, raw, false, "usage: pvplab.tp <x> <y> <z> [heading]")
    end
    local heading = tonumber(args[4]) or 0.0

    local life = Open77.players.getLifeState(source)
    if life == nil then return reply(source, raw, false, "player_not_found") end

    -- Only kill when actually alive; killing a player mid-transition is the
    -- refusal `transition_in_progress`, not a no-op.
    local phase = tostring(life.phase or ""):gsub("_", "")
    if phase == "alive" or phase == "recovering" then
        local killed, killReason = Open77.players.kill(source, {
            cause = "script", weapon = "pvplab:tp",
        })
        if not killed then return reply(source, raw, false, "kill: " .. tostring(killReason)) end
    end

    local ok, reason = Open77.players.respawn(source, {
        position = { x = x, y = y, z = z },
        heading = heading,
        health = 1.0,
        graceMs = 5000,
    })
    reply(source, raw, ok == true, ("tp -> %.2f %.2f %.2f heading=%.1f ok=%s reason=%s"):format(
        x, y, z, heading, tostring(ok), tostring(reason)))
end, false)

-- -------------------------------------------------------------- readouts ---

RegisterCommand("pvplab.where", function(source, _, raw)
    if source == nil or source <= 0 then return reply(source, raw, false, "player only") end
    local centre, reason = callerPosition(source)
    if centre == nil then return reply(source, raw, false, "no position: " .. tostring(reason)) end
    reply(source, raw, true, ("where %.3f %.3f %.3f bucket=%d health=%s"):format(
        centre.x, centre.y, centre.z, centre.bucket,
        tostring(Open77.players.getHealth(source))))
end, false)

RegisterCommand("pvplab.status", function(source, _, raw)
    local propCount, npcCount = 0, 0
    for _ in pairs(props) do propCount = propCount + 1 end
    for _ in pairs(npcs) do npcCount = npcCount + 1 end
    reply(source, raw, true, ("status props=%d npcs=%d damageEvents=%d"):format(
        propCount, npcCount, #damageLog))
end, false)

RegisterCommand("pvplab.damagelog", function(source, _, raw)
    if #damageLog == 0 then return reply(source, raw, true, "damagelog empty") end
    local from = math.max(1, #damageLog - 9)
    reply(source, raw, true, "damagelog " .. table.concat(damageLog, " | ", from, #damageLog))
end, false)

-- ---------------------------------------------------------------- events ---

AddEventHandler("onNpcDamaged", function(npcId, sourceId, amount, health, cause)
    local line = ("npcDamaged npc=%s source=%s amount=%s health=%s cause=%s"):format(
        tostring(npcId), tostring(sourceId), tostring(amount), tostring(health), tostring(cause))
    damageLog[#damageLog + 1] = line
    log(line)
end)

AddEventHandler("onNpcDied", function(npcId, sourceId, cause)
    local line = ("npcDied npc=%s source=%s cause=%s"):format(
        tostring(npcId), tostring(sourceId), tostring(cause))
    damageLog[#damageLog + 1] = line
    log(line)
end)

AddEventHandler("open77:playerDamaged", function(victimId, attackerId, amount,
        attackKind, weaponTdbId, bodyPart, remainingHealth)
    local line = ("playerDamaged victim=%s attacker=%s amount=%s kind=%s body=%s hp=%s"):format(
        tostring(victimId), tostring(attackerId), tostring(amount),
        tostring(attackKind), tostring(bodyPart), tostring(remainingHealth))
    damageLog[#damageLog + 1] = line
    log(line)
end)

AddEventHandler("onNpcCreated", function(npcId, resource, template)
    log(("npcCreated npc=%s resource=%s template=%s"):format(
        tostring(npcId), tostring(resource), tostring(template)))
end)

-- ------------------------------------------------------------------ E13 ---
--
-- E9-E12 asked whether native combat happens. It does -- observed in game on
-- 2026-09-01: the minimap read COMBAT, the engine drew its own enemy health bar
-- over a bot at 206 points, and a bot closed to melee. E13 asks the questions
-- that are left once that is settled, and every one of them decides something
-- in `open77_deathmatch/server/bots.lua`.

-- pvplab.gangs [distance] -- one body from EACH allowlisted gang, in an arc in
-- front of the caller. THE bot-versus-bot experiment.
--
-- REWRITTEN 2026-09-01, and the rewrite is itself the finding. This command
-- used to spawn its three bodies with the DEFAULT `aiMode` -- `tasks` -- on the
-- theory that `aiMode` reached no engine call so it could not matter. It does
-- now: `NpcAiMode.Native` is the selector that puts a body into
-- `NpcReplication`'s hostility sweep, which STATES the hostility instead of
-- hoping the vanilla attitude matrix supplies it. Left as `tasks`, this command
-- would have tested the exact configuration already measured to do nothing.
--
-- What it now measures, from the CLIENT log rather than from this file:
--   [npc] hostility npc=... vs npc=... before=... after=...
--     before=neutral -- the three-gang roster never made them enemies (F19),
--                       which is the assumption the whole roster rested on;
--     before=hostile -- it did, and the blocker was acquisition alone (F20).
-- Then simply watch. Three bodies nine metres apart, explicitly hostile, with
-- the nearest opponent seeded into each idle target tracker, is the smallest
-- possible reproduction of the arena.
RegisterCommand("pvplab.gangs", function(source, args, raw)
    if source == nil or source <= 0 then return reply(source, raw, false, "player only") end
    local distance = tonumber(args[1]) or 9.0
    local yaw = tonumber(args[2])

    local removed = 0
    for _, npc in ipairs(Open77.npcs.all() or {}) do
        if Open77.npcs.remove(npc.id) then removed = removed + 1 end
    end
    npcs = {}

    -- Spread them across an arc rather than stacking them on one bearing: three
    -- bodies at the same point cannot be told apart by any client-side readout,
    -- and `world.around` reports by distance.
    local spawned, messages = 0, {}
    local aliases = {
        "hostile_female_ranged_lab",
        "gang_valentinos_ranged_01",
        "gang_tygerclaws_ranged_01",
    }
    for index, alias in ipairs(aliases) do
        local bearing = (yaw or 0.0) + (index - 2) * 35.0
        -- `native`, and it is load-bearing: it is the selector the client's
        -- hostility sweep reads. See the header above.
        local id, message = spawnInFront(source, alias, distance, bearing,
            { aiMode = Open77.npcs.ai.native })
        if id ~= nil then spawned = spawned + 1 end
        messages[#messages + 1] = alias .. ": " .. tostring(message)
    end
    reply(source, raw, spawned > 0, ("gangs removed=%d spawned=%d -- %s"):format(
        removed, spawned, table.concat(messages, " | ")))
end, false)

-- pvplab.enginewatch [seconds] -- does the ENGINE hit path report at all?
--
-- The readout E10 could not have: it counts the two client Lua events the
-- combat bridge now emits, `open77:npcHit` and `open77:npcAttackedMe`, as they
-- are forwarded. Both are the whole feature, so this is the one command that
-- distinguishes "the client rebuild did not take" from "the report is sent and
-- the server refuses it".
--
-- Reading it:
--   npcHit=0 and npcAttackedMe=0  -- nothing is being observed. Either the DLL
--        predates the change, or `Open77CombatIsManagedNpc` is answering false,
--        which means `RefreshNpcMirror` found no attached body. Check the
--        client log for `Combat oracle: ... npcBodies=`.
--   npcHit>0                      -- the shooter side works end to end.
--   npcAttackedMe>0               -- the victim side works, which also proves
--        `gameHitEvent` reaches the local player through Open77's own
--        god-mode source rather than being swallowed by it.
local engineHits, engineIncoming = 0, 0

RegisterNetEvent("pvplab:enginehit", function(kind, npcId, amount)
    if tostring(kind) == "incoming" then
        engineIncoming = engineIncoming + 1
    else
        engineHits = engineHits + 1
    end
    local line = ("engine %s npc=%s amount=%s"):format(
        tostring(kind), tostring(npcId), tostring(amount))
    damageLog[#damageLog + 1] = line
    log(line)
end)

RegisterCommand("pvplab.enginewatch", function(source, args, raw)
    local seconds = math.min(math.max(tonumber(args[1]) or 15, 1), 120)
    engineHits, engineIncoming = 0, 0
    reply(source, raw, true,
        ("enginewatch %ds started -- shoot a bot, then let it shoot you"):format(seconds))
    CreateThread(function()
        Wait(seconds * 1000)
        reply(source, "pvplab.enginewatch", true,
            ("enginewatch finished npcHit=%d npcAttackedMe=%d"):format(
                engineHits, engineIncoming))
    end)
end, false)

-- pvplab.npcowner -- who holds the simulation lease on each body, and is it me?
--
-- The multiplayer question in one readout. There is exactly one authority
-- client per NPC per epoch and it owns TASKS -- it does NOT own the AI, which
-- runs on every client that streams the body in. So with two clients connected
-- this should show ONE owner and the other client should show none, while both
-- see the bot fighting. If both clients claim ownership, the lease is broken
-- and every conclusion about task delivery is unsafe.
RegisterCommand("pvplab.npcowner", function(source, _, raw)
    if source == nil or source <= 0 then return reply(source, raw, false, "player only") end
    local sent, reason = TriggerClientEvent("pvplab:owner", source)
    reply(source, raw, sent ~= false, ("owner requested sent=%s reason=%s -- answer follows"):format(
        tostring(sent), tostring(reason)))
end, false)

RegisterNetEvent("pvplab:owner:result", function(description)
    reply(source, "pvplab.npcowner", true, "owner " .. tostring(description))
end)

log("phase 0 laboratory ready -- ring / bucketring / quota / npc / solo / ids / npcpolicy / npcai / npcgun / npchurt / npcwatch / botshot / tasks / team / where / clear"
    .. " -- E13: gangs / enginewatch / npcowner")
