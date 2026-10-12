-- The combat surface: everything that has to answer within a frame of the
-- trigger. Crosshair, hitmarker, directional damage, health, armor, ammo,
-- spawn-protection ring and the kill callouts.
--
-- Split from the match surface on purpose (plan section 9): this page runs at
-- 60 fps and carries no scoreboard, so a responsive hitmarker never drags a
-- standings table through a repaint. client/match.lua owns the other half.
--
-- Reuse note: the event plumbing here started from
-- resources/gamemodes/freeroam/client/killfeed.lua, which already consumed
-- open77:hitConfirmed and open77:localDamaged on its own transparent surface.
-- What is added is the projection of the hit direction to a screen bearing,
-- the authoritative health/armor read, ammo, and the protection ring.
--
-- Authority: nothing here invents a number.
--   * health, armor, godMode  -- Open77.players.getHealthState(), which is the
--     client's mirror of the SERVER damage ledger, not an engine stat pool;
--   * damage taken            -- open77:localDamaged, server-confirmed, and it
--     carries the post-hit health so the bar drops on the same frame;
--   * hits dealt              -- open77:hitConfirmed, the server's credit;
--   * spawn protection        -- the gamemode state push (self.protection);
--   * multi-kill and streak   -- the gamemode (deathmatch:callout);
--   * ammo                    -- Open77.weapons.snapshot(), the only source
--     that exists: the magazine drains inside the engine and the server never
--     sees a round leave the chamber.
-- The single local computation is geometry: turning a world-space hit
-- direction into a screen bearing, which is presentation, not authority.

DeathmatchCombat = {}

local page
local ready = false

-- Match facts, mirrored from the state push handled in client/match.lua.
local matchView = {
    participant = false,
    phase = "waiting",
    alive = true,
    team = 0,
    crosshair = true,
}

-- Health ledger, refreshed from the server mirror and from localDamaged.
local health, maxHealth, armor, maxArmor = 0, 0, 0, 0
local godMode = false

-- Ammo, read from the engine because that is where a magazine lives.
local ammo = { magazine = -1, capacity = -1, reserve = -1, known = false, drawn = false }
local ammoRequestAtMs = 0
local ammoPending = {}

-- Spawn protection, anchored once per push and counted down locally, exactly
-- like the round clock.
local protectionAnchorAt = 0
local protectionRemainingMs = 0
local protectionTotalMs = 0

-- Live directional damage indicators. Each keeps the WORLD direction, so the
-- arc follows the camera while the player turns to find their attacker.
local indicators = {}
local nextIndicatorId = 1
local indicatorTtlMs = 1800

local function nowMs()
    return Open77.time.monotonic() * 1000
end

local function number(value, fallback)
    local n = tonumber(value)
    if n == nil or n ~= n then return fallback or 0 end
    return n
end

-- open77:hitConfirmed sends its lethal flag as "1"/"0" while the rest of the
-- generic client events use "true"/"false". Accept both rather than trust one.
local function truthy(value)
    local text = tostring(value)
    return text == "1" or text == "true"
end

local function send(event, payload)
    if page ~= nil and ready then page:send(event, payload or {}) end
end

-- ---------------------------------------------------------------------------
-- Health and armor
-- ---------------------------------------------------------------------------

local function sampleHealth()
    if Open77.players == nil or Open77.players.getHealthState == nil then return end
    local ok, snapshot = pcall(Open77.players.getHealthState)
    if not ok or type(snapshot) ~= "table" then return end
    health = number(snapshot.health, health)
    maxHealth = number(snapshot.maxHealth, maxHealth)
    armor = number(snapshot.armor, armor)
    if armor > maxArmor then maxArmor = armor end
    godMode = snapshot.godMode == true
end

-- ---------------------------------------------------------------------------
-- Ammunition
--
-- The weapons API is asynchronous: snapshot() returns a request id, the plugin
-- then emits one open77:weapons:state per slot and closes with
-- open77:weapons:completed. Only our own request ids are read, so another
-- resource polling the same API cannot feed this HUD.
-- ---------------------------------------------------------------------------

local function requestAmmo()
    if Open77.weapons == nil or Open77.weapons.snapshot == nil then return end
    local at = nowMs()
    if at - ammoRequestAtMs < 220 then return end
    ammoRequestAtMs = at
    local ok, requestId = pcall(Open77.weapons.snapshot)
    if ok and requestId ~= nil then ammoPending[tostring(requestId)] = at end
end

local function acceptAmmo(requestId, active, drawn, reserve, magazine, capacity)
    if ammoPending[tostring(requestId)] == nil then return end
    if not truthy(active) then return end
    local mag = math.floor(number(magazine, -1))
    local cap = math.floor(number(capacity, -1))
    local res = math.floor(number(reserve, -1))
    -- A slot that is not instanced answers -1 for all three; keep the last
    -- believable read rather than flashing "--" between holster frames.
    if mag < 0 and cap < 0 then return end
    ammo.magazine, ammo.capacity, ammo.reserve = mag, cap, res
    ammo.drawn = truthy(drawn)
    ammo.known = true
end

AddEventHandler("open77:weapons:state", function(requestId, _slot, _record, _tweakDbId,
        active, drawn, _locked, _ammoRecord, _ammoTweakDbId, _ammoTotal, ammoReserve,
        magazine, capacity)
    acceptAmmo(requestId, active, drawn, ammoReserve, magazine, capacity)
end)

AddEventHandler("open77:weapons:completed", function(requestId, _operation, accepted, _reason,
        _slot, _record, _tweakDbId, active, drawn, _ammoRecord, _ammoTweakDbId, _ammoTotal,
        ammoReserve, magazine, capacity)
    -- A completion also carries ammo, so a server-driven resupply updates the
    -- readout with no poll at all.
    if truthy(accepted) then
        acceptAmmo(requestId, active, drawn, ammoReserve, magazine, capacity)
    end
    ammoPending[tostring(requestId)] = nil
end)

-- ---------------------------------------------------------------------------
-- Directional damage
--
-- lastHitDirection is the unit vector from the ATTACKER to the VICTIM -- the
-- way the shot travelled (CombatReplication.cpp builds it as victim minus
-- attacker). The indicator has to point back along it, so the stored vector is
-- negated once, here, and never again.
-- ---------------------------------------------------------------------------

local function bearingFor(dirX, dirY)
    if Open77.camera == nil or Open77.camera.view == nil then return nil end
    local ok, view = pcall(Open77.camera.view)
    if not ok or type(view) ~= "table" or type(view.forward) ~= "table" then return nil end
    local fx, fy = number(view.forward.x), number(view.forward.y)
    local flen = math.sqrt(fx * fx + fy * fy)
    local dlen = math.sqrt(dirX * dirX + dirY * dirY)
    if flen < 1e-4 or dlen < 1e-4 then return nil end
    fx, fy = fx / flen, fy / flen
    local dx, dy = dirX / dlen, dirY / dlen
    -- The world is Z-up and right-handed, so camera right = forward x up,
    -- which reduces to (fy, -fx) in the horizontal plane.
    local ahead = dx * fx + dy * fy
    local lateral = dx * fy + dy * -fx
    -- 0 degrees is straight ahead and positive turns clockwise on screen,
    -- which is exactly what a CSS rotation does to an element parked at twelve
    -- o'clock.
    return math.deg(math.atan(lateral, ahead))
end

local function addIndicator(dirX, dirY, dirZ, amount)
    -- Point back at the attacker.
    local towardX, towardY = -dirX, -dirY
    -- A purely vertical hit vector has no bearing to draw. It becomes a full
    -- ring pulse instead of an arrow aimed at an arbitrary angle.
    local omni = (math.abs(towardX) + math.abs(towardY)) < 1e-4
    local id = nextIndicatorId
    nextIndicatorId = nextIndicatorId + 1
    indicators[#indicators + 1] = {
        id = id,
        x = towardX,
        y = towardY,
        z = dirZ,
        amount = amount,
        bornAt = nowMs(),
        omni = omni,
    }
    if #indicators > 6 then table.remove(indicators, 1) end
    return id
end

local function indicatorPayload()
    local at = nowMs()
    local items = {}
    local index = 1
    while index <= #indicators do
        local item = indicators[index]
        local age = at - item.bornAt
        if age >= indicatorTtlMs then
            table.remove(indicators, index)
        else
            local angle = item.omni and 0 or bearingFor(item.x, item.y)
            items[#items + 1] = {
                id = item.id,
                angle = angle or 0,
                omni = item.omni or angle == nil,
                amount = item.amount,
                life = 1 - (age / indicatorTtlMs),
            }
            index = index + 1
        end
    end
    return items
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

AddEventHandler("open77:hitConfirmed", function(_victimId, amount, bodyPart, lethal)
    send("dm:hit", {
        amount = number(amount),
        bodyPart = tostring(bodyPart or "unknown"),
        lethal = truthy(lethal),
    })
end)

AddEventHandler("open77:localDamaged", function(_attackerId, amount, dirX, dirY, dirZ,
        bodyPart, hitHealth, hitMaxHealth)
    local damage = number(amount)
    -- The event carries the post-hit ledger values, so the bar drops now
    -- instead of at the next sample.
    local reportedHealth = tonumber(hitHealth)
    local reportedMax = tonumber(hitMaxHealth)
    if reportedHealth ~= nil then health = reportedHealth end
    if reportedMax ~= nil and reportedMax > 0 then maxHealth = reportedMax end

    local id = addIndicator(number(dirX), number(dirY), number(dirZ), damage)
    send("dm:damaged", {
        id = id,
        amount = damage,
        bodyPart = tostring(bodyPart or "unknown"),
        health = health,
        maxHealth = maxHealth,
    })
    DeathmatchCombat.push()
end)

-- Multi-kill, streak, first blood, revenge. The server sends a KIND and a
-- COUNT; the wording is chosen from the string table, so no display language
-- ever lives on the server.
RegisterNetEvent("deathmatch:callout", function(payload)
    if type(payload) ~= "table" then return end
    send("dm:callout", {
        kind = tostring(payload.kind or "multi"),
        count = math.floor(number(payload.count, 0)),
    })
end)

-- ---------------------------------------------------------------------------
-- Push
-- ---------------------------------------------------------------------------

local function protectionRemaining()
    if protectionRemainingMs <= 0 then return 0 end
    return math.max(0, protectionRemainingMs - (nowMs() - protectionAnchorAt))
end

function DeathmatchCombat.push()
    if page == nil or not ready then return end
    local remaining = protectionRemaining()
    send("dm:combat", {
        active = matchView.participant == true,
        phase = matchView.phase,
        alive = matchView.alive == true,
        team = matchView.team,
        crosshair = matchView.crosshair ~= false,
        health = health,
        maxHealth = maxHealth,
        armor = armor,
        maxArmor = maxArmor,
        ammoKnown = ammo.known == true,
        magazine = ammo.magazine,
        capacity = ammo.capacity,
        reserve = ammo.reserve,
        protectionMs = remaining,
        protectionTotalMs = protectionTotalMs,
        -- godMode keeps the ring visible on a server that has not wired the
        -- protection window yet: better a ring with no number than protection
        -- the player cannot see, which is the whole reason it is being drawn.
        protected = remaining > 0 or godMode,
        indicators = indicatorPayload(),
    })
end

-- Called by client/match.lua on every authoritative state push.
function DeathmatchCombat.onMatchState(state)
    if type(state) ~= "table" then return end
    local phase = tostring(state.phase or "lobby")
    local mine = type(state.self) == "table" and state.self or {}
    -- `participant` is the server's one word for "in an instance", and it is
    -- what this whole surface hangs on: the vitals dock, the reticle and the
    -- health/ammo sampling thread are all off without it. The phase test is a
    -- NEGATIVE one on purpose -- listing the phases that count meant a player
    -- between free-for-all rounds, or in an arena buy window, lost their
    -- vitals while still standing armed in the world.
    matchView.participant = state.participant == true and phase ~= "lobby"
        and phase ~= "waiting"
    matchView.phase = phase
    -- Two ways to be out of the fight with a body still on the ground: a
    -- free-for-all respawn timer, and an arena elimination.
    local playerState = tostring(state.playerState or "")
    matchView.alive = playerState ~= "respawning" and playerState ~= "eliminated"
    matchView.team = math.floor(number(mine.team, 0))
    matchView.crosshair = state.crosshair ~= false

    local protection = type(mine.protection) == "table" and mine.protection or nil
    if protection ~= nil then
        protectionRemainingMs = math.max(0, number(protection.remainingMs, 0))
        protectionTotalMs = math.max(0, number(protection.totalMs, protectionRemainingMs))
    else
        protectionRemainingMs, protectionTotalMs = 0, 0
    end
    protectionAnchorAt = nowMs()

    local reportedMaxArmor = tonumber(mine.maxArmor)
    if reportedMaxArmor ~= nil and reportedMaxArmor > 0 then maxArmor = reportedMaxArmor end
    DeathmatchCombat.push()
end

function DeathmatchCombat.attach(target, strings)
    page = target
    ready = false
    page:on("dm:ready", function()
        ready = true
        page:send("dm:strings", strings)
        DeathmatchCombat.push()
    end)

    CreateThread(function()
        while page ~= nil do
            if matchView.participant then
                sampleHealth()
                if matchView.alive then requestAmmo() end
                DeathmatchCombat.push()
            elseif #indicators > 0 then
                DeathmatchCombat.push()
            end
            -- 25 Hz. The page interpolates rotation and bar width across the
            -- gap, which is the only local computation the surface is allowed.
            Wait(40)
        end
    end)
end

function DeathmatchCombat.detach()
    page, ready = nil, false
    indicators = {}
    ammoPending = {}
    ammo = { magazine = -1, capacity = -1, reserve = -1, known = false, drawn = false }
    protectionRemainingMs, protectionTotalMs = 0, 0
end
