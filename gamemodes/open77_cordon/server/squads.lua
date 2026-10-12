-- Squads: seats, teams, revive at the body, pings and squad voice.
-- Canonical Dead supplies the immobilized body; this resource owns the finite
-- downed window, teammate rescue and delayed self-recovery.

local K = Cordon
K.squads = {}
local S = K.squads

local reviving = {}       -- [downedId] = { byId, untilMs, startedMs }
local channels = {}       -- [squadId] = voice channel id
local pings = {}          -- [squadId] = { x, y, byId, atMs }

local function cfg()
    return (Config and Config.squads) or {}
end

local function window(record)
    local schedule = cfg().downedWindowSeconds or {60,45,30,20,15}
    local count = math.max(1, tonumber(record and record.downingCount) or 1)
    local stage = tonumber(schedule[math.min(count,#schedule)]) or 15
    local cap = tonumber(K.tune("reviveWindowSeconds", cfg().reviveWindowSeconds or 60)) or 60
    return math.max(15, math.min(cap,stage)) * 1000
end

-- ---------------------------------------------------------------------------
-- A downed window is available in Solo and Squad. A living teammate can
-- perform the existing rescue; self-recovery has a separate delayed unlock.
-- ---------------------------------------------------------------------------
--- Is there a living teammate available for an assisted rescue?
function S.hasLivingSquadmate(record)
    if record == nil or record.squad == nil then return false end
    local match = K.match.current()
    local squad = match.squads[record.squad]
    if squad == nil then return false end
    for _, memberId in ipairs(squad.members) do
        if memberId ~= record.id then
            local member = K.players[memberId]
            if member ~= nil and member.state == "alive" then return true end
        end
    end
    return false
end

function S.onDeath(record)
    if record == nil or record.bot then return end
    if Open77.players.setDownedDamageable then Open77.players.setDownedDamageable(record.id, true) end
    record.downingCount = (record.downingCount or 0) + 1
    local duration = window(record)
    record.selfReadyAtMs = K.nowMs() + math.min(25000,duration-5000)
    record.downedFinished = nil
    record.reviveUntilMs = K.nowMs() + duration
    local position = K.position(record.id)
    -- The body's position is captured HERE, at the moment of death, because a
    -- dead player stops publishing snapshots: ask for it thirty seconds later
    -- and it is gone. This is the marker the squad walks to.
    record.bodyPosition = position
    if position ~= nil then
        S.notifySquad(record.squad, "squadmateDown", {
            playerId = record.id, name = K.name(record.id),
            x = position.x, y = position.y, z = position.z,
            windowMs = duration,
        })
    end
end

function S.revivable(record)
    if record == nil or record.state ~= "dead" or record.downedFinished then return false end
    if record.reviveUntilMs == nil or K.nowMs() > record.reviveUntilMs then return false end
    if record.bodyPosition == nil then return false end
    return true
end

--- Anyone alive in the same squad, standing close enough to the body.
function S.canRevive(healerId, downedId)
    if not K.match.isLive() then return false, "not_live" end
    local healer = K.players[tonumber(healerId) or 0]
    local downed = K.players[tonumber(downedId) or 0]
    if healer == nil or downed == nil then return false, "unknown" end
    if healer.id == downed.id then
        if downed.revivePending ~= nil then return false, "revive_pending" end
        if not S.revivable(downed) then return false, "not_revivable" end
        if K.nowMs() < (downed.selfReadyAtMs or math.huge) then return false, "self_not_ready" end
        return true
    end
    if healer.state ~= "alive" then return false, "healer_not_alive" end
    if healer.squad == nil or healer.squad ~= downed.squad then return false, "not_squadmates" end
    if downed.revivePending ~= nil then return false, "revive_pending" end
    if not S.revivable(downed) then return false, "not_revivable" end
    local at = K.position(healer.id)
    if at == nil then return false, "no_position" end
    local body = downed.bodyPosition
    if at.bucket ~= K.matchBucket() or body.bucket ~= K.matchBucket() then
        return false, "wrong_bucket"
    end
    local dx, dy, dz = at.x - body.x, at.y - body.y, at.z - body.z
    local reach = cfg().reviveReachMetres or 2.5
    -- Re-derived on the SERVER from the healer's own replicated position, with
    -- a little grace. The client's claim that it is standing on the body is a
    -- hint, never proof.
    if (dx * dx) + (dy * dy) + (dz * dz) > (reach + 1.5) * (reach + 1.5) then
        return false, "too_far"
    end
    return true
end

-- One hands-busy action per healer, including the native recovery ACK window.
function S.isRevivingHealer(playerId)
    local id = tonumber(playerId)
    for _, entry in pairs(reviving) do
        if entry.byId == id then return true end
    end
    for _, target in pairs(K.players) do
        local pending = target.revivePending
        if pending and pending.healerId == id and K.nowMs() <= pending.untilMs then return true end
    end
    return false
end

function S.beginRevive(healerId, downedId)
    local ok, why = S.canRevive(healerId, downedId)
    if not ok then return false, why end
    local downed = tonumber(downedId)
    if reviving[downed] ~= nil then return false, "already_reviving" end
    if S.isRevivingHealer(healerId) then return false, "healer_busy" end
    local healer = K.players[tonumber(healerId)]
    if K.loot and K.loot.useView and K.loot.useView(healer) then return false, "healer_busy" end
    local selfRevive = tonumber(healerId) == downed
    local seconds = selfRevive and 3.0 or (cfg().reviveHoldSeconds or 5.0)
    reviving[downed] = {
        byId = tonumber(healerId), untilMs = K.nowMs() + seconds * 1000, startedMs = K.nowMs(),
        selfRevive = selfRevive, pulseUntilMs = selfRevive and (K.nowMs() + 750) or nil,
    }
    K.notice(healerId, "reviving", { target = K.name(downed), seconds = seconds })
    K.notice(downed, "beingRevived", { by = K.name(healerId), seconds = seconds })

    -- ----------------------------------------------------------------------
    -- WHAT A REVIVE LOOKS LIKE TO EVERYBODY ELSE.
    --
    -- The finding that governs this whole block, because it is not obvious and
    -- it was paid for once already: **no player animation replicates in
    -- Open77.** `AvatarPresentation::Continuous::pose` -- the channel that
    -- would carry "this body is held in an authored pose" -- is deliberately
    -- NOT on the wire, and the reason is written out at
    -- `client/src/network/PlayerReplication.cpp:280-320`: it has no producer,
    -- so a wire field would be a producer with no consumer on one side. The
    -- player snapshot's flag bits 0..12 are locomotion, weapon and combat only
    -- (`networking/include/op77/Networking/Protocol.hpp:960-975`). Nor can a
    -- resource route around it: the CLIENT `Open77.players` table exposes life,
    -- health and vehicle seat and carries no playerId -> entity mapping
    -- (`scripting/src/ResourceHost.cpp:10380-10388`), so no observer's client
    -- can ever be told "play a clip on that man's proxy".
    --
    -- An emote is therefore something only the acting player can ever see. In a
    -- battle royale that is half a feature: the point of a revive animation is
    -- that the sniper on the roof can tell you are busy and take the shot.
    --
    -- So the replicated half is not an animation. It is the weapon.
    -- `WeaponEquipped` IS on the wire (bit 7, `Protocol.hpp:970`), the receiving
    -- client mounts it on the proxy through `Puppets::ApplyWeapon`, and
    -- `equipped=false` explicitly means holstered (`client/src/api/Puppets.hpp:296`).
    -- Holstering the healer therefore changes what every other player in the
    -- match sees: a man standing over a body with his gun put away. It is TRUE
    -- rather than decorative -- you cannot shoot while you are picking somebody
    -- up -- it plays the game's own holster animation on the healer's own arms,
    -- which is the one gesture here that needs no asset we do not have, and it
    -- is what every battle royale on the market already does.
    --
    -- It is NOT restored afterwards. Reading the loadout back is an
    -- asynchronous `requestSnapshot` round trip with a ten-second timeout, and
    -- guessing a slot would hand a player the wrong gun at the worst possible
    -- moment. Drawing again is one key, and it is part of the price of the
    -- pick-up. `reviveHolsterHealer = false` switches the whole thing off.
    if cfg().reviveHolsterHealer ~= false then
        pcall(Open77.weapons.holster, tonumber(healerId))
    end

    -- The healer's client is told the hold STARTED and how long it runs.
    -- Until now it was told nothing at all: `client/revive.lua` fires
    -- `cordon:revive` and assumes it worked, so a refusal -- out of reach, not
    -- squadmates, somebody else already holding this body -- was indistinguish-
    -- able from a success. Any presentation has to follow the authority rather
    -- than the button, or it shows a player reviving nobody.
    TriggerClientEvent("cordon:revive:hold", tonumber(healerId), {
        downedId = downed,
        holdMs = seconds * 1000,
        self = selfRevive,
    })
    return true
end

function S.cancelRevive(downedId, why)
    local downed = tonumber(downedId)
    if downed == nil or reviving[downed] == nil then return end
    local healerId = reviving[downed].byId
    reviving[downed] = nil
    K.notice(healerId, "reviveCancelled", { reason = why or "interrupted" })
    K.notice(downed, "reviveCancelled", { reason = why or "interrupted" })
end

--- Called on the mode's tick. Completes revives whose hold has elapsed and
--- expires windows nobody reached in time.
function S.tick()
    local now = K.nowMs()

    for downedId, entry in pairs(reviving) do
        local stillOk, why = S.canRevive(entry.byId, downedId)
        if entry.selfRevive and now > entry.pulseUntilMs then stillOk, why = false, "released" end
        if not stillOk then
            S.cancelRevive(downedId, why)
        elseif now >= entry.untilMs then
            reviving[downedId] = nil
            S.completeRevive(entry.byId, downedId)
        end
    end

    for _, record in pairs(K.players) do
        if record.revivePending ~= nil and now > record.revivePending.untilMs then
            record.revivePending = nil
            K.warn(("revive of %d timed out waiting for client recovery"):format(record.id))
        end
        if record.state == "dead" and record.reviveUntilMs ~= nil and now > record.reviveUntilMs then
            S.cancelRevive(record.id, "bleedout")
            if K.match.finishDowned then K.match.finishDowned(record, nil, "bleedout") end
            S.notifySquad(record.squad, "squadmateLost", { playerId = record.id, name = K.name(record.id) })
        end
    end
end

function S.completeRevive(healerId, downedId)
    local allowed, why = S.canRevive(healerId, downedId)
    if not allowed then return false, why end
    local downed = K.players[tonumber(downedId) or 0]
    local healer = K.players[tonumber(healerId) or 0]
    if downed == nil then return end

    -- THE CONFIG IS A PERCENTAGE, THE API IS A FRACTION, and the mismatch made
    -- every revive fail.
    --
    -- `reviveHealth = 30` means "30 of 100" and says so beside itself, but
    -- `Open77.players.revive` takes health as 0..1. Passing 30 straight through
    -- is out of range and comes back `invalid_argument` -- measured 2026-09-02,
    -- on the first revive ever attempted between two sessions. Everything
    -- upstream had worked: the squad check, the reach re-derived on the server,
    -- the hold, the tick that completes it. The only thing wrong was the unit.
    local health = (tonumber(cfg().reviveHealth) or 30) / 100.0
    local graceMs = tonumber(cfg().reviveGraceMs) or 2000
    local ok, reason = Open77.players.revive(downed.id, { health = health, graceMs = graceMs })
    if not ok then
        K.warn(("revive of %d refused: %s"):format(downed.id, tostring(reason)))
        return
    end
    -- Acceptance starts a transaction. Credit and publish the revive only once
    -- the platform confirms recovery; an unfocused or failed client may never
    -- apply the request. Keep the body available while that transaction runs.
    local deadline = K.nowMs() + 15000
    downed.revivePending = { healerId = healerId, untilMs = deadline }
    downed.reviveUntilMs = math.max(downed.reviveUntilMs or 0, deadline)
    return true
end

local function finishRevive(playerId)
    local downed = K.players[tonumber(playerId) or 0]
    if downed == nil or downed.revivePending == nil then return end
    local healerId = downed.revivePending.healerId
    local healer = K.players[tonumber(healerId) or 0]
    downed.revivePending = nil
    if downed.state ~= "dead" or not K.match.isLive() then return end
    if Open77.players.setDownedDamageable then Open77.players.setDownedDamageable(downed.id, false) end
    downed.state = "alive"
    downed.reviveUntilMs = nil
    downed.bodyPosition = nil
    -- A revived player comes back with a shield, because they come back on the
    -- spot where they died and whoever killed them is very likely still there.
    downed.shieldUntilMs = K.nowMs() +
        (((Config and Config.spawnProtection and Config.spawnProtection.reviveSeconds) or 2) * 1000)
    -- Their weapons were dropped on death; they come back empty and have to
    -- pick something up. That is what makes a revive a rescue rather than an
    -- undo.
    downed.weapons = {}

    downed.selfReadyAtMs = nil
    downed.downedCause = nil
    downed.downedKiller = nil
    downed.deathLootDropped = nil
    downed.cordonBleedOutMs = nil
    if healer ~= nil and healer.id ~= downed.id then healer.revives = (healer.revives or 0) + 1 end

    local match = K.match.current()
    local squad = downed.squad and match.squads[downed.squad] or nil

    -- Team ids are re-applied at every life transition rather than trusted to
    -- survive one; whether setTeam outlives a placement has never been measured.
    if downed.squad ~= nil then pcall(Open77.combat.setTeam, downed.id, downed.squad) end

    S.notifySquad(downed.squad, "squadmateRevived", {
        playerId = downed.id, name = K.name(downed.id), by = K.name(healerId),
    })
    if K.match.checkEnd then K.match.checkEnd() end
end

-- Damage interrupts a revive, on either side.
function S.onDamage(victimId, attackerId, amount, kind, weapon, part, remaining, maximum, lethal, downedHit)
    local id = tonumber(victimId)
    if id == nil then return end
    if tostring(downedHit) == "1" then
        local record = K.players[id]
        if S.revivable(record) and K.match.finishDowned then
            K.match.finishDowned(record, tonumber(attackerId), kind)
        end
    end
    if reviving[id] ~= nil then S.cancelRevive(id, "target_damaged") end
    for downedId, entry in pairs(reviving) do
        if entry.byId == id then S.cancelRevive(downedId, "healer_damaged") end
    end
end
AddEventHandler("open77:playerRevived", finishRevive)
AddEventHandler("open77:playerLifeTransitionFailed", function(playerId)
    local downed = K.players[tonumber(playerId) or 0]
    if downed ~= nil then downed.revivePending = nil end
end)
AddEventHandler("open77:playerDamaged", S.onDamage)

-- ---------------------------------------------------------------------------
-- SQUAD COMMUNICATION.
-- ---------------------------------------------------------------------------
function S.notifySquad(squadId, kind, fields)
    if squadId == nil then return end
    local match = K.match.current()
    local squad = match.squads[squadId]
    if squad == nil then return end
    for _, memberId in ipairs(squad.members) do
        if memberId > 0 then
            TriggerClientEvent("cordon:squad", memberId, { kind = kind, fields = fields or {} })
        end
    end
end

--- A ping is a point, a squad and a timestamp. There is no raycast API, so the
--- client sends the point it computed from its own camera and the server does
--- not pretend to verify it — a ping cannot hurt anybody, and a wrong one only
--- misleads the squad that sent it.
RegisterNetEvent("cordon:ping", function(x, y)
    local record = K.ensure(source)
    if record == nil or record.squad == nil then return end
    local now = K.nowMs()
    local last = pings[record.squad]
    local cooldown = (cfg().pingCooldownMs or 1500)
    if last ~= nil and now - last.atMs < cooldown then return end
    pings[record.squad] = { x = tonumber(x) or 0, y = tonumber(y) or 0, byId = record.id, atMs = now }
    S.notifySquad(record.squad, "ping", { x = x, y = y, by = K.name(record.id) })
end)

function S.downedView(record)
    if not K.match.isLive() or not S.revivable(record) then return nil end
    local now = K.nowMs()
    return { remainingMs = math.max(0, record.reviveUntilMs - now),
        selfReadyInMs = math.max(0, (record.selfReadyAtMs or now) - now),
        selfHoldMs = 3000, downingCount=record.downingCount or 1,
        pending = record.revivePending ~= nil }
end

RegisterNetEvent("cordon:selfRevive", function()
    local ok, why = S.beginRevive(source, source)
    if not ok then K.notice(source, "reviveRefused", { reason = why }) end
end)
function S.pulseSelfRevive(playerId)
    local entry = reviving[tonumber(playerId) or 0]
    if entry and entry.selfRevive and K.nowMs() <= entry.pulseUntilMs then
        entry.pulseUntilMs = K.nowMs() + 750
    end
end
RegisterNetEvent("cordon:selfRevivePulse", function() S.pulseSelfRevive(source) end)
RegisterNetEvent("cordon:selfReviveCancel", function()
    local entry = reviving[tonumber(source) or 0]
    if entry and entry.selfRevive then S.cancelRevive(source, "released") end
end)

RegisterNetEvent("cordon:revive", function(downedId)
    local ok, why = S.beginRevive(source, downedId)
    if not ok then K.notice(source, "reviveRefused", { reason = why }) end
end)

RegisterNetEvent("cordon:reviveCancel", function(downedId)
    local entry = reviving[tonumber(downedId) or 0]
    if entry ~= nil and entry.byId == tonumber(source) then
        S.cancelRevive(downedId, "released")
    end
end)

-- ---------------------------------------------------------------------------
-- SQUAD VOICE. One party channel per squad, rebuilt at every match, torn down
-- at the end. Channels are resource-owned, so nothing else can alter them.
-- ---------------------------------------------------------------------------
function S.openChannels()
    if type(Open77.voice) ~= "table" or type(Open77.voice.createChannel) ~= "function" then return end
    S.closeChannels()
    local match = K.match.current()
    for squadId, squad in pairs(match.squads) do
        local channel, reason = Open77.voice.createChannel({
            name = ("cordon-squad-%d"):format(squadId),
            mode = "party",
            persistent = false,
        })
        if channel ~= nil then
            channels[squadId] = type(channel) == "table" and channel.id or channel
            for _, memberId in ipairs(squad.members) do
                if memberId > 0 then pcall(Open77.voice.addPlayer, channels[squadId], memberId) end
            end
        else
            K.warn(("squad voice channel for %d refused: %s"):format(squadId, tostring(reason)))
        end
    end
end

function S.closeChannels()
    if type(Open77.voice) ~= "table" or type(Open77.voice.removeChannel) ~= "function" then return end
    for squadId, channelId in pairs(channels) do
        pcall(Open77.voice.removeChannel, channelId)
        channels[squadId] = nil
    end
    channels = {}
end

function S.reset()
    reviving = {}
    for _, record in pairs(K.players) do
        record.revivePending = nil
        if Open77.players.setDownedDamageable then Open77.players.setDownedDamageable(record.id, false) end
    end
    pings = {}
    S.closeChannels()
end

--- The squad fragment the per-player state push carries.
function S.reviveView(record)
    if record == nil or not K.match.isLive() then return nil end
    local match = K.match.current()
    local squad = record.squad and match.squads[record.squad] or nil
    if squad == nil then return nil end
    local now = K.nowMs()
    for _, targetId in ipairs(squad.members) do
        local target = K.players[targetId]
        local hold = reviving[targetId]
        local pending = target and target.revivePending
        local healerId = hold and hold.byId or pending and pending.healerId
        if healerId and (record.id == targetId or record.id == healerId)
            and (not pending or now <= pending.untilMs) then
            return { role = healerId == targetId and "self" or (record.id == targetId and "target" or "healer"),
                playerId = targetId, healerId = healerId, name = K.name(targetId),
                pending = pending ~= nil,
                progress = pending and 1 or math.max(0, math.min(1,
                    (now - hold.startedMs) / math.max(1, hold.untilMs - hold.startedMs))) }
        end
    end
    return nil
end

function S.fragmentFor(record)
    local match = K.match.current()
    local squad = record.squad and match.squads[record.squad] or nil
    if squad == nil then return nil end
    local members = {}
    for _, memberId in ipairs(squad.members) do
        local member = K.players[memberId]
        if member ~= nil then
            local entry = {
                playerId = member.id,
                name = K.name(member.id),
                alive = member.state == "alive",
                bot = member.bot,
                downed = S.revivable(member),
            }
            if entry.downed and member.bodyPosition ~= nil then
                -- The physical revive prompt needs the captured 3D body, not
                -- just the tac-map's planar x/y coordinates.
                entry.body = { x = member.bodyPosition.x, y = member.bodyPosition.y, z = member.bodyPosition.z }
                entry.x = member.bodyPosition.x
                entry.y = member.bodyPosition.y
                entry.reviveMs = math.max(0, (member.reviveUntilMs or 0) - K.nowMs())
            elseif entry.alive then
                -- A LIVING SQUADMATE'S POSITION, which nothing sent until now.
                --
                -- The fragment carried coordinates only for a DOWNED member --
                -- a body to revive -- so the tactical overlay, which draws a
                -- marker per member and skips any member with no `x`, drew the
                -- squad's corpses and nobody else. The legend has promised a
                -- SQUAD mark since it was written and the plan asks for "squad
                -- positions" in as many words (section 4, layer 1).
                --
                -- Squad-only, and that is the whole boundary: this is built
                -- from `record.squad`, so a player never receives a coordinate
                -- for anyone outside their own squad. Four members at 2 Hz is
                -- four `Open77.players.position` reads per player per second,
                -- which is the same call `stateFor` already makes for the
                -- cordon containment test.
                local at = K.position(member.id)
                if at ~= nil then
                    entry.x = at.x
                    entry.y = at.y
                end
            end
            local inProgress = reviving[member.id]
            if inProgress ~= nil then
                entry.reviveProgress = math.min(1.0, 1.0 -
                    ((inProgress.untilMs - K.nowMs()) / math.max(1, inProgress.untilMs - inProgress.startedMs)))
            end
            members[#members + 1] = entry
        end
    end
    return {
        id = squad.id,
        alive = K.match.squadAlive(squad),
        members = members,
        ping = pings[squad.id],
    }
end

K.log("squads ready")
