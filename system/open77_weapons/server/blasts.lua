-- Open77 blast relay: the platform's authoritative physical blast (V4).
--
-- Only the client that simulates a car can move it, and every client presents
-- its own copy of each network NPC. A vanilla explosion runs its physics on
-- ONE client -- the grenade thrower's, the missile shooter's, the simulator of
-- the car that blew up -- so without a relay only that screen sees cars jump
-- and NPCs fall. This file turns an explosion the server can vouch for into:
--
--   * one `open77_weapons:blast` per physics owner of every other car in reach,
--     listing that owner's cars (its client pushes them from its own poses);
--   * `characters = true` for every player near enough to hold a copy of an
--     NPC in reach (each client knocks down its own copies);
--   * optionally, a server-authorized launch of each living player in reach,
--     when the gamemode's policy asks for it (setBlastPolicy).
--
-- Nothing here prices damage. The engine's own explosion still reports its
-- hits to the damage arbiter; this only moves bodies, with magnitudes taken
-- from the server tables below, never from a client.
--
-- Sources (each validated before anything moves):
--   grenade        onPlayerExplosion (snapshot detonation) paired with a credit
--                  for a grenade with a physical blast: onConsumableUsed (a 2.x
--                  recharging charge spent) or onGadgetConsumed (a stack shrank)
--   vehicle        a car's canonical `exploded` flag rising (onVehicleDamageChanged)
--   vehicleWeapon  onVehicleWeaponExplosion (VehicleWeaponAuthorityService ticket)
--   tuned/scripted exports.relayBlast from another server resource (labs)

local monotonic = function() return Open77.time.monotonic() end

-- ---------------------------------------------------------------------------
-- Configuration. Magnitudes are velocity changes in m/s at the centre, scaled
-- by (1 - distance / radius) ^ falloff on each client (Core::WeaponBlastWeight).
-- ---------------------------------------------------------------------------
local Config = {
    event = "open77_weapons:blast",
    -- Core::ValidWeaponBlastRelay refuses anything outside these on the client.
    limits = { radius = 60, push = 40, lift = 40, falloff = 4 },
    vehicleReach = 4,            -- metres of pose lag between this server and an owner
    vehicleLimit = 48,
    characterReach = 150,        -- metres: an NPC's authority and observers stream it from here
    characterRecipients = 64,    -- nearest NPC holders told per blast
    playerTargets = 32,
    playerPushCap = 20,          -- ForcedMotionService.Launch ceilings
    playerLiftCap = 14,
    playerMinimumWeight = 0.2,   -- a body at the rim is not knocked down (kinds may override)
    launchWindow = 0.75,         -- seconds a launch may wait on the ambient-crowd stop
    globalRate = { burst = 120, perSecond = 60 },
    -- Characters-only messages per recipient. Car messages are never dropped here:
    -- a car one owner does not push is exactly the desync this file exists to remove.
    recipientRate = { burst = 16, perSecond = 8 },
    kinds = {
        -- When the source's own engine already ran this explosion (`localApplied`),
        -- the cars it simulates and the NPC copies it presents moved there, and
        -- relaying them back to it would double the push. `sourceVehicles` and
        -- `sourceCharacters` say whether the source still gets them. For vanilla
        -- explosions both are inferences to confirm live (see the V4 research
        -- entry): flip `sourceVehicles` if a thrower's own car stays still.
        grenade = { rate = { burst = 3, perSecond = 0.5 }, sourceVehicles = false, sourceCharacters = false,
            launchSource = false, attacker = true },
        vehicle = { rate = { burst = 4, perSecond = 1 }, sourceVehicles = false, sourceCharacters = false,
            launchSource = true, attacker = false },
        vehicleWeapon = { rate = { burst = 16, perSecond = 8 }, sourceVehicles = false, sourceCharacters = false,
            launchSource = false, attacker = true },
        -- rp_weapons_effect: its client's local Blast() already pushed its own cars
        -- and knocked its own NPC copies down; the relay finds them reacting and
        -- leaves them be (measured 2026-09-26), so characters still go to it.
        tuned = { rate = { burst = 10, perSecond = 10 }, sourceVehicles = false, sourceCharacters = true,
            launchSource = false, attacker = true, maxRange = 250, requireAlive = true, minimumWeight = 0 },
        scripted = { rate = { burst = 10, perSecond = 5 }, sourceVehicles = false, sourceCharacters = true,
            launchSource = false, attacker = false, maxRange = 250 },
    },
    grenade = {
        creditSeconds = 12,      -- a consumed grenade may detonate this long after the report
        pairSeconds = 1.5,       -- a detonation may wait this long for its consumption report
        throwRange = 80,         -- metres from where it was thrown
        stickyRange = 160,       -- a sticky grenade rides whatever it stuck to
        reporterRange = 160,     -- metres from where the thrower is now
        maxCredits = 4,
        maxParked = 2,
        creditRate = { burst = 3, perSecond = 1 },
        reportRate = { burst = 4, perSecond = 2 },
        -- Off: a quick-slot grenade without a consumption report does not authorize a
        -- detonation. See docs/research/weapons-and-item-records.md (V4) before enabling.
        acceptHeld = false,
        heldRate = { burst = 2, perSecond = 1 / 3 },
    },
    -- Explosion families. `recordRadius` is the attack radius of the item's own
    -- record where it was measured (Items.GrenadeFragRegular: radius 4, live
    -- 2026-09-05); the relay radius adds a body allowance because each client
    -- measures to a car's or body's root, not to its surface.
    profiles = {
        frag = { recordRadius = 4, radius = 5.5, push = 9, lift = 7, falloff = 1 },
        incendiary = { recordRadius = 4, radius = 5, push = 6, lift = 5, falloff = 1 },
        cutting = { recordRadius = 4, radius = 5, push = 5, lift = 3, falloff = 1 },
        car = { radius = 8, push = 10, lift = 9, falloff = 1 },
        missile = { recordRadius = 3, radius = 5.5, push = 12, lift = 9, falloff = 1 },
        cannon = { radius = 4, push = 10, lift = 6, falloff = 1 },
        explodingRound = { radius = 2.5, push = 4, lift = 2, falloff = 1 },
    },
}

-- Grenade records whose attack is a physical explosion, by TweakDB id (the spelling
-- onGadgetConsumed carries when a shipping build lost the name table) and by name.
-- Generated from server/src/Open77.Server.Core/Data/weapons-2.31.tsv. EMP, flash,
-- smoke, recon and biohazard grenades are absent on purpose: no physical blast.
-- Items.Preset_Grenade_*_Default are absent too: their attack record is null
-- (2026-09-05 fixture), so they never explode.
local GRENADES = {
    frag = {
        ["Items.CPO_Grenade_Frag"] = "0x00000016d4a23b0a", ["Items.FactionGadget"] = "0x0000001397a5e880",
        ["Items.FragGrenades"] = "0x0000001254f69315", ["Items.GrenadeFragCommonPlus"] = "0x0000001b30cd73c0",
        ["Items.GrenadeFragEpic"] = "0x00000015fcf11bbb", ["Items.GrenadeFragEpicPlus"] = "0x00000019536ca40e",
        ["Items.GrenadeFragLegendary"] = "0x0000001adb3f6207",
        ["Items.GrenadeFragLegendaryPlus"] = "0x0000001eaf9b4958",
        ["Items.GrenadeFragRarePlus"] = "0x0000001902ea0cbe", ["Items.GrenadeFragRegular"] = "0x00000018edc63ef7",
        ["Items.GrenadeFragRegularHack"] = "0x0000001cd41e86e4",
        ["Items.GrenadeFragRegular_VeryHard"] = "0x0000002194a90f7f",
        ["Items.GrenadeFragSticky"] = "0x0000001743526c23", ["Items.GrenadeFragUncommon"] = "0x00000019acf56098",
        ["Items.GrenadeFragUncommonPlus"] = "0x0000001db648b79f", ["Items.GrenadeOzobsNose"] = "0x00000016bcfb0a12",
        ["Items.NPCGrenadeFragRegular"] = "0x0000001b6a1435ab",
    },
    incendiary = {
        ["Items.GrenadeIncendiaryEpicPlus"] = "0x0000001f1dcc8836",
        ["Items.GrenadeIncendiaryLegendary"] = "0x00000020f3737ab5",
        ["Items.GrenadeIncendiaryLegendaryPlus"] = "0x0000002463ac9572",
        ["Items.GrenadeIncendiaryRare"] = "0x0000001bf363afe3",
        ["Items.GrenadeIncendiaryRarePlus"] = "0x0000001f4c4a2086",
        ["Items.GrenadeIncendiaryRegular"] = "0x0000001e49695215",
        ["Items.GrenadeIncendiaryRegularHack"] = "0x000000221181fac4",
        ["Items.GrenadeIncendiaryRegular_VeryHard"] = "0x000000273443e399",
        ["Items.GrenadeIncendiarySticky"] = "0x0000001d3dfae345",
        ["Items.GrenadeIncendiaryUncommonPlus"] = "0x000000238de3082b",
    },
    cutting = {
        ["Items.CuttingGrenadeLegendaryPlus"] = "0x000000213330dac7",
        ["Items.GrenadeCuttingRegular"] = "0x0000001b88939422",
        ["Items.GrenadeCuttingRegularHack"] = "0x0000001feb6f2b3f",
    },
}
local grenadeByName, grenadeById = {}, {}
for family, records in pairs(GRENADES) do
    for record, id in pairs(records) do
        local entry = { family = family, record = record, sticky = record:find("Sticky", 1, true) ~= nil }
        grenadeByName[record] = entry
        grenadeById[id] = entry
    end
end

local function grenadeEntry(record, tweakDbId)
    if type(tweakDbId) == "string" and #tweakDbId > 0 then
        local entry = grenadeById[tweakDbId:lower()]
        if entry then return entry end
    end
    if type(record) == "string" then return grenadeByName[record] end
    return nil
end

-- ---------------------------------------------------------------------------
-- State. Every table is keyed by a connected player or a live vehicle and is
-- released on playerDropped / onVehicleRemoved; nothing grows with time.
-- ---------------------------------------------------------------------------
local policy = { owner = nil, players = false, safeZones = {}, buckets = nil }
local sourceRates, recipientRates, globalRate = {}, {}, {}
local credits, parked, creditRates, reportRates, heldRates = {}, {}, {}, {}, {}
local vehicleStates = {}
local stats = { blasts = 0, byKind = {}, vehicles = 0, carMessages = 0, characterMessages = 0,
    droppedMessages = 0, launches = 0, launchRefusals = 0, refused = {} }
local logTokens = { tokens = 5, at = nil }

local function enabled()
    local value = type(GetConvar) == "function" and tostring(GetConvar("open77_blasts", "on")):lower() or "on"
    return value ~= "off" and value ~= "0" and value ~= "false"
end

local function take(bucket, rate, now)
    if bucket.at == nil then bucket.tokens, bucket.at = rate.burst, now end
    if now > bucket.at then
        bucket.tokens = math.min(rate.burst, bucket.tokens + (now - bucket.at) * rate.perSecond)
        bucket.at = now
    end
    if bucket.tokens < 1 then return false end
    bucket.tokens = bucket.tokens - 1
    return true
end

local function slot(tableOfBuckets, key)
    local bucket = tableOfBuckets[key]
    if bucket == nil then bucket = {}; tableOfBuckets[key] = bucket end
    return bucket
end

local function refuse(kind, reason)
    local key = tostring(kind) .. ":" .. tostring(reason)
    stats.refused[key] = (stats.refused[key] or 0) + 1
    return nil, reason
end

local function log(message)
    if not take(logTokens, { burst = 5, perSecond = 1 }, monotonic()) then return end
    print("[open77-blast] " .. message)
end

local function finite(value, limit)
    return type(value) == "number" and value == value and math.abs(value) <= (limit or 1000000)
end

local function distanceSquared(a, x, y, z)
    local dx, dy, dz = a.x - x, a.y - y, a.z - z
    return dx * dx + dy * dy + dz * dz
end

local function insideSafeZone(position)
    if position == nil then return false end
    for _, zone in ipairs(policy.safeZones) do
        if distanceSquared(position, zone.x, zone.y, zone.z) <= zone.radius * zone.radius then return true end
    end
    return false
end

-- Automatic sources launch players only when the gamemode turned it on. An
-- explicit `players = true` from another server resource (the ACL-gated lab)
-- launches unless the gamemode turned it off. Buckets and safe zones bind both.
local function launchAllowed(bucket, requested)
    if policy.buckets ~= nil and not policy.buckets[bucket] then return false end
    if requested == true then return policy.players ~= "off" end
    return policy.players == true
end

local function alive(player)
    local life = Open77.players.getLifeState(player)
    return life ~= nil and life.phase == "alive", life
end

local function weightAt(distance, radius, falloff)
    if not (distance >= 0) or not (radius > 0) or distance >= radius then return 0 end
    if falloff == 0 then return 1 end
    return (1 - distance / radius) ^ falloff
end

-- ---------------------------------------------------------------------------
-- Player launches. May yield (the ambient-crowd stop is an awaited export), so
-- a caller that is not already a scheduler task runs it in CreateThread.
-- ---------------------------------------------------------------------------
local function diagnosticReason(reason)
    if type(reason) == "string" and #reason <= 48 and reason:match("^[a-z_]+$") then return reason end
    return "unknown"
end

local function launchPlayers(blast, summary)
    local kind = Config.kinds[blast.kind]
    local started = monotonic()
    local minimumWeight = kind.minimumWeight or Config.playerMinimumWeight
    if kind.attacker and blast.source > 0 and insideSafeZone(Open77.players.position(blast.source)) then
        summary.launchReason = "source_protected"
        return
    end
    local targets = {}
    for _, target in ipairs(GetPlayers()) do
        local id = tonumber(target)
        if id and (id ~= blast.source or kind.launchSource) then
            local p = Open77.players.position(id)
            if p and p.bucket == blast.bucket and not insideSafeZone(p) then
                local d = math.sqrt(distanceSquared(p, blast.x, blast.y, blast.z))
                local weight = weightAt(d, blast.radius, blast.falloff)
                if weight > 0 and weight >= minimumWeight then
                    targets[#targets + 1] = { id = id, distance = d }
                end
            end
        end
    end
    if #targets == 0 then return end
    table.sort(targets, function(a, b) return a.distance < b.distance end)
    while #targets > Config.playerTargets do table.remove(targets) end
    local ids = {}
    for index, target in ipairs(targets) do ids[index] = target.id end
    -- A player in an ambient workspot refuses the launch; open77_crowd_ambient
    -- stops them in one awaited batch first. Absent, it costs one refusal.
    if Open77.exports and type(Open77.exports.call) == "function" then
        local pending, reason = Open77.exports.call("open77_crowd_ambient", "stopForBlastTargets", ids)
        if pending then
            local ok, stopped = pcall(function() return pending:await() end)
            if not ok or stopped ~= true then summary.launchReason = "ambient_stop_failed"; return end
        elseif reason ~= "export_resource_unavailable" then
            summary.launchReason = "ambient_stop_" .. diagnosticReason(reason)
            return
        end
    end
    -- The export yielded (up to launchWindow): everything decided before it is
    -- decided again on the world as it is now. A late admission never becomes a
    -- surprise impulse, a policy turned off meanwhile launches nobody (F19), and
    -- a source or target that walked into a safe zone meanwhile is protected.
    if monotonic() - started > Config.launchWindow then summary.launchReason = "launch_window"; return end
    if not launchAllowed(blast.bucket, blast.playersRequested) then
        summary.launchReason = "policy_changed"; return
    end
    if blast.source > 0 then
        local current = Open77.players.position(blast.source)
        if kind.requireAlive and not alive(blast.source) then summary.launchReason = "source_unavailable"; return end
        if kind.attacker and (current == nil or current.bucket ~= blast.bucket) then
            summary.launchReason = "source_moved"; return
        end
        if kind.attacker and insideSafeZone(current) then summary.launchReason = "source_protected"; return end
    end
    for _, target in ipairs(targets) do
        local p = Open77.players.position(target.id)
        -- Read immediately before the launch: this position is the one it is aimed from.
        if p and insideSafeZone(p) then
            summary.protected = (summary.protected or 0) + 1
            refuse(blast.kind, "target_protected")
            p = nil
        end
        if p and p.bucket == blast.bucket then
            local x, y, z = p.x - blast.x, p.y - blast.y, p.z - blast.z
            local distance = math.sqrt(x * x + y * y + z * z)
            local weight = weightAt(distance, blast.radius, blast.falloff)
            local push = math.min(Config.playerPushCap, blast.push * weight)
            local lift = math.min(Config.playerLiftCap, blast.lift * weight)
            if weight > 0 and weight >= minimumWeight and push + lift > 0 then
                if x * x + y * y < 0.000001 then x, y = 0, 1 end
                local detailed = blast.diagnostics and #summary.closest < 8
                local life = detailed and select(2, alive(target.id)) or nil
                local previous = detailed and Open77.motion.current and Open77.motion.current(target.id) or nil
                local result, reason = Open77.motion.launch(target.id, { x = x, y = y, push = push, lift = lift })
                reason = result and "granted" or diagnosticReason(reason)
                if result then
                    summary.accepted = summary.accepted + 1
                    stats.launches = stats.launches + 1
                else
                    summary.rejected = summary.rejected + 1
                    summary.reasons[reason] = (summary.reasons[reason] or 0) + 1
                    stats.launchRefusals = stats.launchRefusals + 1
                end
                if detailed then
                    summary.closest[#summary.closest + 1] = {
                        player = target.id, distance = distance, reason = reason,
                        life = life and diagnosticReason(life.phase) or "unavailable",
                        lifeRevision = life and life.revision or 0,
                        previous = previous and diagnosticReason(previous.phase) or "none",
                        push = push, lift = lift,
                        lease = result and type(result.id) == "string" and result.id or nil,
                    }
                end
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- The relay. `blast` is already validated and clamped by its source adapter.
-- ---------------------------------------------------------------------------
local function relay(blast)
    local now = monotonic()
    local kind = Config.kinds[blast.kind]
    if not take(globalRate, Config.globalRate, now) then return refuse(blast.kind, "global_rate") end
    -- Per source player; a world blast (no source) is rated per invoking resource,
    -- or as one shared "world" source for ownerless car explosions.
    local rateKey = blast.source > 0 and blast.source or blast.rateKey or "world"
    if not take(slot(slot(sourceRates, blast.kind), rateKey), kind.rate, now) then
        return refuse(blast.kind, "source_rate")
    end
    stats.blasts = stats.blasts + 1
    stats.byKind[blast.kind] = (stats.byKind[blast.kind] or 0) + 1

    local recipients = {}
    local function recipient(id)
        local entry = recipients[id]
        if not entry then entry = { vehicles = {}, characters = false }; recipients[id] = entry end
        return entry
    end
    local summary = { kind = blast.kind, source = blast.source, sequence = blast.sequence, vehicles = 0,
        owners = 0, characterHolders = 0, accepted = 0, rejected = 0, reasons = {}, closest = {} }

    local vehicles = Open77.vehicles
    if type(vehicles) ~= "table" or type(vehicles.nearby) ~= "function" or type(vehicles.owner) ~= "function" then
        summary.vehicleReason = "vehicles_unavailable"
    else
        local found = vehicles.nearby({ x = blast.x, y = blast.y, z = blast.z }, blast.radius + Config.vehicleReach,
            { bucket = blast.bucket, limit = Config.vehicleLimit })
        if type(found) ~= "table" then summary.vehicleReason = "vehicles_unavailable" else
            for _, vehicle in ipairs(found) do
                if vehicle.id ~= blast.excludeVehicle then
                    local owner = vehicles.owner(vehicle.id)
                    local physics = owner and tonumber(owner.physicsOwner) or 0
                    local simulator = physics
                    -- An ownerless car is simulated by nobody. The source is the one
                    -- client that can take it now; its grant is the only ownership
                    -- change this relay ever makes.
                    if simulator == 0 and blast.source > 0 and type(vehicles.requestAuthority) == "function"
                        and vehicles.requestAuthority(vehicle.id, blast.source) then
                        simulator = blast.source
                    end
                    -- The source's own cars moved in its own explosion, unless the
                    -- blast never ran on its client or it only just became their owner.
                    if simulator > 0 and not (blast.localApplied and not kind.sourceVehicles
                        and simulator == blast.source and physics == blast.source) then
                        local ids = recipient(simulator).vehicles
                        ids[#ids + 1] = vehicle.id
                        summary.vehicles = summary.vehicles + 1
                    end
                end
            end
        end
    end

    -- NPC holders. The server cannot enumerate other resources' NPCs, so every
    -- player close enough to stream one in reach is told; each client acts on
    -- the living copies it presents inside the radius.
    local holders = {}
    local reach = blast.radius + Config.characterReach
    for _, target in ipairs(GetPlayers()) do
        local id = tonumber(target)
        if id and (id ~= blast.source or kind.sourceCharacters or not blast.localApplied) then
            local p = Open77.players.position(id)
            if p and p.bucket == blast.bucket then
                local d2 = distanceSquared(p, blast.x, blast.y, blast.z)
                if d2 <= reach * reach then holders[#holders + 1] = { id = id, d2 = d2 } end
            end
        end
    end
    table.sort(holders, function(a, b) return a.d2 < b.d2 end)
    for index = 1, math.min(#holders, Config.characterRecipients) do
        recipient(holders[index].id).characters = true
    end

    for id, entry in pairs(recipients) do
        local cars = #entry.vehicles > 0
        if cars or entry.characters then
            -- Characters-only messages are bounded per recipient; car messages never are.
            if cars or take(slot(recipientRates, id), Config.recipientRate, now) then
                TriggerClientEvent(Config.event, id, { source = blast.source, kind = blast.kind,
                    sequence = blast.sequence, x = blast.x, y = blast.y, z = blast.z, radius = blast.radius,
                    push = blast.push, lift = blast.lift, falloff = blast.falloff,
                    vehicles = entry.vehicles, characters = entry.characters })
                if cars then
                    summary.owners = summary.owners + 1
                    stats.carMessages = stats.carMessages + 1
                else stats.characterMessages = stats.characterMessages + 1 end
                if entry.characters then summary.characterHolders = summary.characterHolders + 1 end
            else stats.droppedMessages = stats.droppedMessages + 1 end
        end
    end
    stats.vehicles = stats.vehicles + summary.vehicles
    summary.launch = blast.players == true
    return summary
end

local function describe(summary, blast)
    return ("kind=%s source=%s sequence=%s vehicles=%d owners=%d holders=%d%s position=%.2f,%.2f,%.2f radius=%.1f")
        :format(summary.kind, summary.source, tostring(summary.sequence), summary.vehicles, summary.owners,
            summary.characterHolders, summary.vehicleReason and (" vehicleReason=" .. summary.vehicleReason) or "",
            blast.x, blast.y, blast.z, blast.radius)
end

-- An explosion the server itself vouched for (grenade, car, mounted weapon):
-- relay now, launch on a scheduler task so the ambient export can be awaited.
local function relayAutomatic(blast)
    if not enabled() then return refuse(blast.kind, "disabled") end
    blast.players = launchAllowed(blast.bucket, nil)
    local summary, reason = relay(blast)
    if not summary then return nil, reason end
    log(describe(summary, blast))
    if blast.players then
        -- Host events already run on a scheduler task, where the ambient export can
        -- be awaited in place; anything else gets one.
        local run = coroutine.isyieldable() and function(fn) fn() end or CreateThread
        run(function()
            launchPlayers(blast, summary)
            if summary.accepted + summary.rejected > 0 or summary.launchReason then
                log(("launch kind=%s source=%s sequence=%s accepted=%d rejected=%d%s"):format(blast.kind,
                    blast.source, tostring(blast.sequence), summary.accepted, summary.rejected,
                    summary.launchReason and (" reason=" .. summary.launchReason) or ""))
            end
        end)
    end
    return summary
end

local function profileBlast(kind, source, localApplied, bucket, x, y, z, profile, extra)
    local blast = { kind = kind, source = source, localApplied = localApplied, bucket = bucket,
        x = x, y = y, z = z, radius = profile.radius, push = profile.push, lift = profile.lift,
        falloff = profile.falloff }
    for key, value in pairs(extra or {}) do blast[key] = value end
    return blast
end

-- ---------------------------------------------------------------------------
-- Source 1: grenades. A detonation is relayed only when the reporter consumed
-- a grenade with a physical blast (one detonation per unit), from a point it
-- could have thrown to, in its own bucket, at the rate grenades can be thrown.
-- ---------------------------------------------------------------------------
local function purge(list, now, seconds, kind, reason)
    for index = #list, 1, -1 do
        if now - list[index].at > seconds then
            table.remove(list, index)
            if reason then refuse(kind, reason) end
        end
    end
end

local function pair(player, observation, now)
    local list = credits[player]
    if list == nil then return false end
    purge(list, now, Config.grenade.creditSeconds, "grenade", "credit_expired")
    for index, credit in ipairs(list) do
        local range = credit.sticky and Config.grenade.stickyRange or Config.grenade.throwRange
        if credit.bucket == observation.bucket
            and distanceSquared(credit, observation.x, observation.y, observation.z) <= range * range then
            table.remove(list, index)
            local profile = Config.profiles[credit.family]
            relayAutomatic(profileBlast("grenade", player, true, observation.bucket, observation.x,
                observation.y, observation.z, profile, { sequence = observation.sequence,
                    evidence = credit.evidence, record = credit.record }))
            return true
        end
    end
    return false
end

-- The reporter's own gadget cache, only when Config.grenade.acceptHeld is on.
local function heldCredit(player, observation, now)
    if not Config.grenade.acceptHeld or type(Open77.weapons) ~= "table"
        or type(Open77.weapons.get) ~= "function" then return nil end
    local read = Open77.weapons.get(player)
    if type(read) ~= "table" then return nil end
    for _, row in ipairs(read.gadgets or {}) do
        local entry = grenadeEntry(row.record, row.tweakDbId)
        if entry and row.active and (tonumber(row.quantity) or 0) > 0 then
            if not take(slot(heldRates, player), Config.grenade.heldRate, now) then return nil end
            local p = Open77.players.position(player)
            if not p then return nil end
            return { family = entry.family, record = entry.record, sticky = entry.sticky, at = now,
                x = p.x, y = p.y, z = p.z, bucket = p.bucket, evidence = "held" }
        end
    end
    return nil
end

local function admitDetonation(player, observation, now)
    local p = Open77.players.position(player)
    if not p then refuse("grenade", "position_unavailable"); return true end
    if p.bucket ~= observation.bucket then refuse("grenade", "bucket_mismatch"); return true end
    local range = Config.grenade.reporterRange
    if distanceSquared(p, observation.x, observation.y, observation.z) > range * range then
        refuse("grenade", "out_of_range"); return true
    end
    if pair(player, observation, now) then return true end
    local held = heldCredit(player, observation, now)
    if held then
        credits[player] = credits[player] or {}
        table.insert(credits[player], 1, held)
        return pair(player, observation, now)
    end
    return false
end

-- The last credit each source granted a player: 2.x grenades are charge based,
-- so one throw is reported by the consumables API (`onConsumableUsed`, a charge
-- spent) and, only for a stack-based grenade, also by the quick-slot inventory
-- (`onGadgetConsumed`, the stack shrank). Whichever arrives second within this
-- window is the same throw and adds nothing.
local lastCredit = {}
local SAME_THROW_SECONDS = 0.75

local function creditGrenade(player, record, tweakDbId, evidence, anotherThrow)
    local entry = grenadeEntry(record, tweakDbId)
    if entry == nil then return end -- not a grenade with a physical blast
    local now = monotonic()
    local previous = lastCredit[player]
    if not anotherThrow and previous and previous.evidence ~= evidence and previous.record == entry.record
        and now - previous.at < SAME_THROW_SECONDS then
        previous.evidence = evidence -- one more report of that throw, not another throw
        return
    end
    if not take(slot(creditRates, player), Config.grenade.creditRate, now) then
        return refuse("grenade", "credit_rate")
    end
    local p = Open77.players.position(player)
    if not p then return refuse("grenade", "position_unavailable") end
    local list = credits[player] or {}
    credits[player] = list
    purge(list, now, Config.grenade.creditSeconds, "grenade", "credit_expired")
    if #list >= Config.grenade.maxCredits then table.remove(list, 1); refuse("grenade", "credit_overflow") end
    list[#list + 1] = { family = entry.family, record = entry.record, sticky = entry.sticky, at = now,
        x = p.x, y = p.y, z = p.z, bucket = p.bucket, evidence = evidence }
    lastCredit[player] = { at = now, record = entry.record, evidence = evidence }
    -- A detonation that reached the server before its consumption report.
    local waiting = parked[player]
    if waiting then
        purge(waiting, now, Config.grenade.pairSeconds, "grenade", "no_grenade_consumed")
        for index = 1, #waiting do
            if pair(player, waiting[index], now) then table.remove(waiting, index); break end
        end
        if #waiting == 0 then parked[player] = nil end
    end
end

AddEventHandler("onGadgetConsumed", function(playerId, record, remaining, tweakDbId)
    local player = tonumber(playerId)
    if not player or player <= 0 then return end
    creditGrenade(player, record, tweakDbId, "consumed")
end)

-- B9 (live 2026-09-30): a 2.x grenade spends a recharging CHARGE; its quick-slot
-- stack never shrinks, so `onGadgetConsumed` never fires and every real grenade
-- was refused `no_grenade_consumed`. The consumables API reports each charge the
-- owner spent (count/sequence validated by PlayerWeaponStateService).
AddEventHandler("onConsumableUsed", function(playerId, kind, record, count, uses, sequence, tweakDbId)
    local player = tonumber(playerId)
    if not player or player <= 0 or kind ~= "grenade" then return end
    local spent = math.tointeger(tonumber(uses)) or 1
    if spent < 1 then return end
    -- Several charges in one report are several throws.
    for index = 1, math.min(spent, Config.grenade.maxCredits) do
        creditGrenade(player, record, tweakDbId, "charge", index > 1)
    end
end)

AddEventHandler("onPlayerExplosion", function(playerId, sequence, x, y, z, count, bucket)
    local player = tonumber(playerId)
    x, y, z = tonumber(x), tonumber(y), tonumber(z)
    if not player or player <= 0 or not finite(x) or not finite(y) or not finite(z) then return end
    local now = monotonic()
    if not enabled() then return refuse("grenade", "disabled") end
    if not take(slot(reportRates, player), Config.grenade.reportRate, now) then
        return refuse("grenade", "report_rate")
    end
    local reportedBucket = tonumber(bucket)
    if reportedBucket == nil then
        local p = Open77.players.position(player)
        reportedBucket = p and p.bucket
    end
    if reportedBucket == nil then return refuse("grenade", "position_unavailable") end
    local observation = { sequence = tonumber(sequence), x = x, y = y, z = z, bucket = reportedBucket, at = now }
    if admitDetonation(player, observation, now) then return end
    local waiting = parked[player] or {}
    parked[player] = waiting
    purge(waiting, now, Config.grenade.pairSeconds, "grenade", "no_grenade_consumed")
    if #waiting >= Config.grenade.maxParked then table.remove(waiting, 1); refuse("grenade", "no_grenade_consumed") end
    waiting[#waiting + 1] = observation
end)

-- ---------------------------------------------------------------------------
-- Source 2: a car blowing up. Its simulator ran vanilla ExplodeVehicle (the
-- only client that does: every other copy replays the wreck without an
-- attack), so the simulator is the source whose own world already moved.
-- ---------------------------------------------------------------------------
local function vehicleExploded(current)
    local names = Open77.vehicles.flags or {}
    return type(current.flags) == "number" and type(names.exploded) == "number"
        and (current.flags & names.exploded) ~= 0
end

AddEventHandler("onVehicleCreated", function(vehicleId)
    local id = tonumber(vehicleId)
    if not id or type(Open77.vehicles) ~= "table" then return end
    local current = Open77.vehicles.get(id)
    -- A wreck restored as a wreck is not an explosion happening now.
    vehicleStates[id] = { exploded = current ~= nil and vehicleExploded(current), created = monotonic() }
end)

AddEventHandler("onVehicleRemoved", function(vehicleId) vehicleStates[tonumber(vehicleId) or -1] = nil end)

-- A (re)start must not mistake a wreck that already exists for a fresh explosion
-- the first time its damage record changes again.
if type(Open77.vehicles) == "table" and type(Open77.vehicles.all) == "function" then
    local seeded = monotonic() - 60
    for _, current in ipairs(Open77.vehicles.all() or {}) do
        if type(current) == "table" and current.id then
            vehicleStates[current.id] = { exploded = vehicleExploded(current), created = seeded }
        end
    end
end

AddEventHandler("onVehicleDamageChanged", function(vehicleId, revision)
    local id = tonumber(vehicleId)
    if not id or type(Open77.vehicles) ~= "table" or type(Open77.vehicles.get) ~= "function" then return end
    local current = Open77.vehicles.get(id)
    if current == nil then vehicleStates[id] = nil; return end
    local now = monotonic()
    local state = vehicleStates[id]
    local exploded = vehicleExploded(current)
    if state == nil then state = { exploded = false, created = now - 60 }; vehicleStates[id] = state end
    local rising = exploded and not state.exploded
    state.exploded = exploded
    if not rising then return end
    if now - state.created < 1 then return refuse("vehicle", "restored_wreck") end
    local owner = Open77.vehicles.owner(id)
    local simulator = owner and tonumber(owner.physicsOwner) or 0
    relayAutomatic(profileBlast("vehicle", simulator, simulator > 0, current.bucket, current.x, current.y,
        current.z + 0.5, Config.profiles.car, { sequence = tonumber(revision), excludeVehicle = id }))
end)

-- ---------------------------------------------------------------------------
-- Source 3: a mounted weapon's projectile detonating. The host publishes only
-- what VehicleWeaponAuthorityService admitted against a live shot ticket.
-- ---------------------------------------------------------------------------
local function mountedProfile(weapon)
    -- Countermeasure flares (Items.Panzer_Counter_Measures_Launcher) fall through:
    -- they may report a terminal phase but carry no physical blast.
    if type(weapon) ~= "string" then return nil end
    if weapon:find("Missile", 1, true) then return Config.profiles.missile end
    if weapon:find("Cannon", 1, true) then return Config.profiles.cannon end
    if weapon:find("Power_Weapon", 1, true) then return Config.profiles.explodingRound end
    return nil
end

AddEventHandler("onVehicleWeaponExplosion", function(playerId, vehicleId, weapon, x, y, z, bucket, radius, projectile)
    local player = tonumber(playerId)
    x, y, z, bucket = tonumber(x), tonumber(y), tonumber(z), tonumber(bucket)
    if not player or player <= 0 or not finite(x) or not finite(y) or not finite(z) or not bucket then return end
    local profile = mountedProfile(weapon)
    if profile == nil then return refuse("vehicleWeapon", "not_physical") end
    local recordRadius = tonumber(radius) or 0
    local blast = profileBlast("vehicleWeapon", player, true, bucket, x, y, z, profile,
        { sequence = tonumber(projectile), weapon = weapon })
    -- The record's own radius may only widen the default by the same body allowance.
    if recordRadius > 0 and profile.recordRadius and recordRadius > profile.recordRadius then
        blast.radius = math.min(Config.limits.radius, recordRadius + (profile.radius - profile.recordRadius))
    end
    relayAutomatic(blast)
end)

-- ---------------------------------------------------------------------------
-- Server-to-server: a blast another resource already admitted (rp_weapons_effect
-- relays its tuned-weapon receipts here). Bounded by the same client limits and
-- rates; an invoker can neither exceed them nor pick recipients or victims.
-- ---------------------------------------------------------------------------
exports("relayBlast", function(request)
    local invoker = type(GetInvokingResource) == "function" and GetInvokingResource() or "unknown"
    if type(request) ~= "table" then return nil, "invalid_blast" end
    local kindName = request.kind == "tuned" and "tuned" or "scripted"
    local kind = Config.kinds[kindName]
    if not enabled() then return refuse(kindName, "disabled") end
    local x, y, z = tonumber(request.x), tonumber(request.y), tonumber(request.z)
    local radius, push, lift = tonumber(request.radius), tonumber(request.push), tonumber(request.lift)
    local falloff = request.falloff == nil and 1 or tonumber(request.falloff)
    local limits = Config.limits
    if not finite(x) or not finite(y) or not finite(z) or not finite(radius) or not finite(push)
        or not finite(lift) or not finite(falloff) or radius <= 0 or radius > limits.radius or push < 0
        or push > limits.push or lift < 0 or lift > limits.lift or push + lift <= 0 or falloff < 0
        or falloff > limits.falloff then
        return refuse(kindName, "invalid_blast")
    end
    local source = tonumber(request.source) or 0
    if source < 0 or source % 1 ~= 0 then return refuse(kindName, "invalid_source") end
    local bucket
    if source > 0 then
        local p = Open77.players.position(source)
        if not p then return refuse(kindName, "position_unavailable") end
        if kind.requireAlive and not alive(source) then return refuse(kindName, "body_unavailable") end
        if distanceSquared(p, x, y, z) > kind.maxRange * kind.maxRange then return refuse(kindName, "out_of_range") end
        bucket = p.bucket
    else
        bucket = tonumber(request.bucket)
        if bucket == nil or bucket < 0 or bucket % 1 ~= 0 then return refuse(kindName, "invalid_bucket") end
    end
    local blast = { kind = kindName, source = source, localApplied = source > 0 and request.serverSide ~= true,
        bucket = bucket, x = x, y = y, z = z, radius = radius, push = push, lift = lift, falloff = falloff,
        sequence = tonumber(request.sequence), diagnostics = request.diagnostics == true,
        players = request.players == true and launchAllowed(bucket, true),
        -- Re-evaluated against the policy after the awaited ambient stop (F19).
        playersRequested = request.players == true or nil,
        rateKey = "resource:" .. tostring(invoker) }
    local summary, reason = relay(blast)
    if not summary then return nil, reason end
    summary.invoker = invoker
    if blast.players then launchPlayers(blast, summary) end
    return summary
end)

-- ---------------------------------------------------------------------------
-- Gamemode policy. One owner at a time (one gamemode per server); it lapses
-- when that resource stops. Cars and NPCs are relayed regardless: they are the
-- consistency fix. Launching players is a gameplay rule and is off until a
-- gamemode asks for it.
-- ---------------------------------------------------------------------------
local function resetPolicy() policy = { owner = nil, players = false, safeZones = {}, buckets = nil } end

exports("setBlastPolicy", function(value)
    local invoker = type(GetInvokingResource) == "function" and GetInvokingResource() or nil
    if type(value) ~= "table" then return false, "invalid_policy" end
    local zones = {}
    if value.safeZones ~= nil and type(value.safeZones) ~= "table" then return false, "invalid_safe_zones" end
    for _, zone in ipairs(value.safeZones or {}) do
        if #zones >= 64 then break end
        local zx, zy, zz, zr = tonumber(zone.x), tonumber(zone.y), tonumber(zone.z), tonumber(zone.radius)
        if not finite(zx) or not finite(zy) or not finite(zz) or not finite(zr, 5000) or zr < 0 then
            return false, "invalid_safe_zones"
        end
        if zr > 0 then zones[#zones + 1] = { x = zx, y = zy, z = zz, radius = zr } end
    end
    local buckets = nil
    if value.buckets ~= nil then
        if type(value.buckets) ~= "table" then return false, "invalid_buckets" end
        buckets = {}
        for _, bucket in ipairs(value.buckets) do
            bucket = tonumber(bucket)
            if bucket == nil or bucket < 0 or bucket % 1 ~= 0 then return false, "invalid_buckets" end
            buckets[bucket] = true
        end
    end
    if policy.owner ~= nil and invoker ~= nil and policy.owner ~= invoker then
        print(("[open77-blast] policy owner %s replaced by %s"):format(policy.owner, invoker))
    end
    policy = { owner = invoker, players = value.players == true and true or (value.players == false and "off" or false),
        safeZones = zones, buckets = buckets }
    print(("[open77-blast] policy owner=%s players=%s safeZones=%d buckets=%s"):format(tostring(invoker),
        tostring(value.players == true), #zones, buckets and "listed" or "all"))
    return true
end)

exports("blastStats", function() return stats end)

AddEventHandler("onResourceStop", function(name)
    if policy.owner ~= nil and name == policy.owner then resetPolicy() end
end)

AddEventHandler("playerDropped", function(playerId)
    local dropped = tonumber(source) or tonumber(playerId)
    if dropped == nil then return end
    credits[dropped], parked[dropped], creditRates[dropped], lastCredit[dropped] = nil, nil, nil, nil
    reportRates[dropped], heldRates[dropped], recipientRates[dropped] = nil, nil, nil
    for _, perKind in pairs(sourceRates) do perKind[dropped] = nil end
end)

RegisterCommand("weapon.blasts", function(sourcePlayer, _, raw)
    local refused = {}
    for key, count in pairs(stats.refused) do refused[#refused + 1] = key .. "=" .. count end
    table.sort(refused)
    local kinds = {}
    for key, count in pairs(stats.byKind) do kinds[#kinds + 1] = key .. "=" .. count end
    table.sort(kinds)
    local text = ("weapon.blasts enabled=%s blasts=%d {%s} vehicles=%d carMessages=%d characterMessages=%d "
        .. "dropped=%d launches=%d launchRefusals=%d policy=%s/%s refused{%s}"):format(tostring(enabled()),
        stats.blasts, table.concat(kinds, " "), stats.vehicles, stats.carMessages, stats.characterMessages,
        stats.droppedMessages, stats.launches, stats.launchRefusals, tostring(policy.owner),
        tostring(policy.players), table.concat(refused, " "))
    print(text)
    if sourcePlayer ~= nil and sourcePlayer > 0 then
        TriggerClientEvent("open77:command:result", sourcePlayer, raw or "", true, text)
    end
end, true)
