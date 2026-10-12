-- The combat surface: everything that has to answer within a frame of the
-- trigger. Crosshair, hitmarker, directional damage, health/armor, ammo, the
-- spawn-shield ring, the OUTSIDE-THE-CORDON vignette and compass, and revive
-- progress.
--
-- Split from the match surface on purpose (plan section 10): this page runs at
-- 60 fps and carries no standings table, so a responsive hitmarker never drags
-- a scoreboard repaint behind it.
--
-- WHERE EVERY NUMBER COMES FROM. Nothing here invents one.
--
--   health, armor, plates, heals   the state push (`self`). NOT
--                                  `Open77.players.getHealthState`, which the
--                                  deathmatch HUD uses -- that needs
--                                  `players.life.read` and this resource holds
--                                  only `network.events`. The server ledger is
--                                  the authority either way; this route just
--                                  arrives at 2 Hz instead of on demand, which
--                                  is why `open77:localDamaged` below is what
--                                  actually drops the bar.
--   ammo                           read-only local weapon snapshots, matched
--                                  to the server's issued inventory slots.
--   damage taken                   `open77:localDamaged`, server-confirmed,
--                                  carrying the post-hit health so the bar
--                                  drops on the same frame.
--   cordon damage                  `cordon:hurt`, the mode's own event. See the
--                                  block at its handler: this is a MEASURED
--                                  finding, not a preference.
--   hits dealt                     `open77:hitConfirmed`, the server's credit.
--                                  Player victims only -- see its handler.
--   life state                     `open77:playerLifeStateChanged` as a hint,
--                                  `self.alive` as the authority.
--   shield, outside, nearestOpen   the state push. Containment is decided on
--                                  the server and is never re-derived here:
--                                  the client does not own the block list and
--                                  a second opinion about whether the player is
--                                  bleeding would be a second bug.
--
-- The single local computation is geometry: turning a world-space direction
-- into a screen bearing, for the damage chevrons and for the cordon compass.
-- That is presentation, not authority.

CordonCombat = {}

local page
local ready = false
local stockHudClaims = {}
local stockHudHidden = false
local stockHudAttemptAt = -1000

-- Match freeroam's visibility ownership: hide only the readouts this surface
-- replaces, after its browser is ready. Other resources retain their claims.
local function stockHud(hidden)
    if type(Open77.hud) ~= "table" or type(Open77.hud.setVisible) ~= "function" then return end
    local at = Open77.time.monotonic() * 1000
    if hidden == stockHudHidden and (hidden or next(stockHudClaims) == nil) then return end
    if hidden and at - stockHudAttemptAt < 1000 then return end
    stockHudAttemptAt = at
    local complete = true
    for _, component in ipairs({ "health", "weapon" }) do
        if hidden or stockHudClaims[component] then
            local ok, accepted = pcall(Open77.hud.setVisible, component, not hidden)
            if ok and accepted then
                stockHudClaims[component] = hidden or nil
            else
                complete = false
            end
        end
    end
    stockHudHidden = hidden and complete
    -- A partial acquisition leaves the stock UI intact until both replacements
    -- are ready. Release remains resource-scoped in the native HUD service.
    if hidden and not complete then
        for component in pairs(stockHudClaims) do
            local ok, accepted = pcall(Open77.hud.setVisible, component, true)
            if ok and accepted then stockHudClaims[component] = nil end
        end
    end
end

-- Match facts, mirrored from the state push.
local view = {
    participant = false,
    phase = "unknown",
    alive = true,
    squad = 0,
    outside = false,
    -- Standing on ground the announced phase is going to take. One phase
    -- before `outside`; see the MOVE block below.
    doomed = false,
}

-- The self block, kept whole so a field the server adds later needs no edit
-- here to reach the page.
local mine = {}

-- The active inventory slot, resolved once per push.
local ammoLabel, ammoCount, ammoReserve = nil, -1, -1

-- Nearest open block, world-space, so the compass can be re-aimed against the
-- live camera between pushes instead of freezing while the player turns.
local nearestOpen = nil

-- Nearest cell that SURVIVES the announced phase, same shape, for the MOVE
-- strip's arrow. Absent when nothing survives (the terminal phase), in which
-- case the strip shows the clock without an arrow rather than pointing at
-- nothing.
local nextSafe = nil

-- The MOVE pulse: one amber frame on the edge INTO the doomed state, the
-- counterpart of the cordon pulse on the edge into the outside state.
local movePulseAt = 0

-- Live directional damage indicators. Each keeps the WORLD direction for the
-- same reason.
local indicators = {}
local nextIndicatorId = 1
local INDICATOR_TTL_MS = 1800

-- The cordon pulse. Separate from the hit flash: one says "somebody shot you",
-- the other says "the city is killing you", and they must not look alike.
local cordonPulseAt = 0

local function nowMs()
    return Open77.time.monotonic() * 1000
end

local function number(value, fallback)
    local n = tonumber(value)
    if n == nil or n ~= n then return fallback or 0 end
    return n
end

-- MEASURED, and it costs a wrong hitmarker every time it is forgotten:
-- `open77:hitConfirmed` sends its `lethal` flag as "1"/"0" while the generic
-- client events use "true"/"false". Accept both rather than trust one.
local function truthy(value)
    local text = tostring(value)
    return text == "1" or text == "true"
end

local function send(event, payload)
    if page ~= nil and ready then page:send(event, payload or {}) end
end

-- ---------------------------------------------------------------------------
-- Bearings
--
-- The world is Z-up and right-handed, so camera right = forward x up, which
-- reduces to (fy, -fx) in the horizontal plane. 0 degrees is straight ahead and
-- positive turns clockwise on screen -- exactly what a CSS rotation does to an
-- element parked at twelve o'clock.
--
-- `Open77.camera` is ungated (docs/lua-resources.md: permission "None"), which
-- is why this works on a manifest holding only network.events.
-- ---------------------------------------------------------------------------

local function bearingFor(dirX, dirY)
    if Open77.camera == nil or Open77.camera.view == nil then return nil end
    local ok, camera = pcall(Open77.camera.view)
    if not ok or type(camera) ~= "table" or type(camera.forward) ~= "table" then return nil end
    local fx, fy = number(camera.forward.x), number(camera.forward.y)
    local flen = math.sqrt(fx * fx + fy * fy)
    local dlen = math.sqrt(dirX * dirX + dirY * dirY)
    if flen < 1e-4 or dlen < 1e-4 then return nil end
    fx, fy = fx / flen, fy / flen
    local dx, dy = dirX / dlen, dirY / dlen
    local ahead = dx * fx + dy * fy
    local lateral = dx * fy + dy * -fx
    return math.deg(math.atan(lateral, ahead))
end

local function selfPosition()
    if Open77.character == nil or Open77.character.state == nil then return nil end
    local ok, snapshot = pcall(Open77.character.state)
    if not ok or type(snapshot) ~= "table" or type(snapshot.position) ~= "table" then
        return nil
    end
    return snapshot.position
end

-- The compass to the nearest open block. The SERVER supplies the target and the
-- distance (`self.nearestOpen`); the only thing computed here is which way it
-- is from where the camera is pointing, which is the same geometry the damage
-- chevrons use and for the same reason.
local function compassPayload()
    if nearestOpen == nil then return nil end
    local target = nearestOpen
    local origin = selfPosition()
    local dirX, dirY
    if origin ~= nil then
        dirX = number(target.x) - number(origin.x)
        dirY = number(target.y) - number(origin.y)
    else
        -- No readable position. The distance the server sent is still true, so
        -- the strip shows it without an arrow rather than pointing at random --
        -- an arrow that is wrong is worse than no arrow when it is the only
        -- thing telling a bleeding player which way to run.
        dirX, dirY = 0, 0
    end
    local angle = bearingFor(dirX, dirY)
    return {
        distance = math.max(0, number(target.distance, 0)),
        angle = angle or 0,
        aimed = angle ~= nil,
    }
end

-- ---------------------------------------------------------------------------
-- MOVE -- standing on doomed ground
--
-- The owner's verdict on 2026-09-04, after playing with a visible boundary:
-- "le principe de voir la zone ... c'est de savoir que la zone s'approche au
-- fur et a mesure et qu'il faut avancer vers la prochaine zone a la apex, la
-- on a pas du tout cette impression". The HUD spoke only once the player was
-- already outside and bleeding. That is a coin flip, not a decision: the
-- moment that matters is the thirty seconds BEFORE, standing on a block the
-- match strip says is closing, with no idea whether "closing" means here.
--
-- Three server facts on the push, all in `self` and all absent unless they
-- apply (see `stateFor` in open77_cordon/server/main.lua):
--
--   doomed          this player's cell is announced and not yet closed
--   cellClosesInMs  that cell's OWN deadline -- not the phase's first closure;
--                   cells close one at a time across the window, farthest
--                   from the final first, so two players in the same ring can
--                   be twenty seconds apart
--   nextSafe        the nearest cell that survives the announced phase, in
--                   the same shape as `nearestOpen`
--
-- The countdown is EXTRAPOLATED between pushes from the local clock, like
-- `outsideMs` and the flatline figure, so it runs smoothly instead of
-- stepping twice a second. The arrow is the same bearing geometry the compass
-- and the damage chevrons use. Nothing is invented: the server decides who is
-- doomed and when, and the page renders what it is told.
-- ---------------------------------------------------------------------------

local function movePayload()
    -- Outside wins. A player who has already crossed the line is bleeding,
    -- and the OUTSIDE banner is the louder of the two; the server never sends
    -- both anyway, but the page must not be able to draw both either.
    if not view.doomed or view.outside then return nil end
    local seconds = nil
    if mine.cellClosesMs ~= nil then
        local remaining = number(mine.cellClosesMs, 0)
        if mine.cellClosesAtMs ~= nil then
            remaining = remaining - math.max(0, nowMs() - mine.cellClosesAtMs)
        end
        seconds = math.max(0, remaining / 1000)
    end
    local compass = nil
    if nextSafe ~= nil then
        local origin = selfPosition()
        local dirX, dirY = 0, 0
        if origin ~= nil then
            dirX = number(nextSafe.x) - number(origin.x)
            dirY = number(nextSafe.y) - number(origin.y)
        end
        local angle = bearingFor(dirX, dirY)
        compass = {
            distance = math.max(0, number(nextSafe.distance, 0)),
            angle = angle or 0,
            aimed = angle ~= nil,
        }
    end
    return { seconds = seconds, compass = compass }
end

-- ---------------------------------------------------------------------------
-- Directional damage
--
-- `lastHitDirection` is the unit vector from the ATTACKER to the VICTIM -- the
-- way the shot travelled (CombatReplication.cpp builds it as victim minus
-- attacker). The indicator has to point BACK along it, so the stored vector is
-- negated ONCE, here, and never again. Negating it twice puts every chevron
-- behind the player, which reads as working until somebody checks.
-- ---------------------------------------------------------------------------

local function addIndicator(dirX, dirY, dirZ, amount, cause)
    local towardX, towardY = -dirX, -dirY
    -- A purely vertical hit vector has no bearing to draw. It becomes a ring
    -- pulse instead of an arrow aimed at an arbitrary angle.
    local omni = (math.abs(towardX) + math.abs(towardY)) < 1e-4
    local id = nextIndicatorId
    nextIndicatorId = nextIndicatorId + 1
    indicators[#indicators + 1] = {
        id = id,
        x = towardX,
        y = towardY,
        z = dirZ,
        amount = amount,
        cause = cause or "hit",
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
        if age >= INDICATOR_TTL_MS then
            table.remove(indicators, index)
        else
            local angle = item.omni and 0 or bearingFor(item.x, item.y)
            items[#items + 1] = {
                id = item.id,
                angle = angle or 0,
                omni = item.omni or angle == nil,
                amount = item.amount,
                cause = item.cause,
                life = 1 - (age / INDICATOR_TTL_MS),
            }
            index = index + 1
        end
    end
    return items
end

-- ---------------------------------------------------------------------------
-- Platform events
-- ---------------------------------------------------------------------------

-- MEASURED, and it is the reason the mode pushes its own hit event too:
-- `open77:hitConfirmed` fires ONLY when the victim is a PLAYER. A bot is an
-- NPC, so every hit on a bot -- which in a `botFill = threshold` match is most
-- of them -- would produce no hitmarker at all. The mode reports those itself
-- through `cordon:hit`, built from the owner-reported NPC damage bridge, and
-- both land on the same handler here so the player cannot tell the difference.
AddEventHandler("open77:hitConfirmed", function(_victimId, amount, bodyPart, lethal)
    send("cordon:hit", {
        amount = number(amount),
        bodyPart = tostring(bodyPart or "unknown"),
        lethal = truthy(lethal),
        victim = "player",
    })
end)

RegisterNetEvent("cordon:hit", function(payload)
    if type(payload) ~= "table" then return end
    send("cordon:hit", {
        amount = number(payload.amount),
        bodyPart = tostring(payload.bodyPart or "unknown"),
        lethal = payload.lethal == true or truthy(payload.lethal),
        victim = "bot",
    })
end)

AddEventHandler("open77:localDamaged", function(_attackerId, amount, dirX, dirY, dirZ,
        bodyPart, hitHealth, hitMaxHealth)
    local damage = number(amount)
    -- The event carries the post-hit ledger values, so the bar drops now
    -- instead of at the next 500 ms push.
    local reportedHealth = tonumber(hitHealth)
    local reportedMax = tonumber(hitMaxHealth)
    if reportedHealth ~= nil then
        mine.health = reportedHealth
        mine.healthKnown = true
        mine.healthAtMs = nowMs()
    end
    if reportedMax ~= nil and reportedMax > 0 then mine.maxHealth = reportedMax end

    local id = addIndicator(number(dirX), number(dirY), number(dirZ), damage, "hit")
    send("cordon:damaged", {
        id = id,
        amount = damage,
        cause = "hit",
        bodyPart = tostring(bodyPart or "unknown"),
        health = number(mine.health),
        maxHealth = number(mine.maxHealth, 100),
    })
    CordonCombat.push()
end)

-- THE CORDON'S OWN EVENT, and the measurement behind it.
--
-- `open77:localDamaged` requires an ATTRIBUTED ATTACKER. Cordon damage has
-- none: the server applies it with `kind = "environment"` and no attacker id
-- (plan decision 19 -- `players.damage`'s `cause` option is really the engine
-- attack KIND and rejects anything outside its enum), so `localDamaged` NEVER
-- FIRES FOR IT. E5 measured exactly this on 2026-09-02, and the mode's own
-- client (open77_cordon/client/main.lua) says so at the point it raises this
-- event: "the red edge and the compass would silently do nothing if the HUD
-- waited for it."
--
-- Without this handler a player bleeding out at 25 HP/s gets no feedback at
-- all, which is the failure the plan calls unmissable-or-it-reads-as-a-bug. DO
-- NOT DELETE IT because `localDamaged` "already covers damage": it does not,
-- and the symptom is silent.
--
-- IT IS A LOCAL EVENT, NOT A NET EVENT. The gamemode's client raises it with
-- `TriggerEvent` off its own copy of the state push, so `AddEventHandler` is
-- the right subscription and `RegisterNetEvent` would never fire.
--
-- It is also EDGE-triggered: it fires when `outside` CHANGES, not once per
-- damage tick. So it flips the vignette immediately -- half a second before the
-- HUD's own copy of the push would -- and fires one pulse. The continuous
-- "still bleeding" motion is the CSS breathe on the vignette, not a stream of
-- events, because a 4 Hz event stream to animate a rim is exactly the per-frame
-- work that must not go through a Lua tick.
AddEventHandler("cordon:hurt", function(payload)
    if type(payload) ~= "table" then return end
    view.outside = payload.outside == true
    if type(payload.nearest) == "table" then nearestOpen = payload.nearest end
    mine.dps = number(payload.damagePerSecond, number(mine.dps))
    -- START THE RAMP HERE, not at the next state push. This event is
    -- edge-triggered and arrives up to half a second earlier, and the ramp is
    -- measured from the moment the player crossed the line -- so seeding it at
    -- zero now, rather than waiting to be told a number that will already be
    -- 500 ms stale, is both sooner and more accurate. Crossing back clears it,
    -- so re-entering and leaving again does not resume a half-climbed ramp.
    mine.outsideMs = 0
    mine.outsideAtMs = view.outside and nowMs() or nil
    if view.outside then
        cordonPulseAt = nowMs()
        send("cordon:damaged", { id = 0, amount = 0, cause = "cordon" })
    end
    CordonCombat.push()
end)

-- A hint only. The authority for "am I alive" is `self.alive` in the push,
-- because that is the ledger the server actually scores. This event arrives
-- sooner, so it is used to flip the surface a few hundred milliseconds early --
-- and only when the payload told us our own player id, since the event fires
-- for EVERY player and this resource cannot read the session id (that needs
-- `network.client`).
AddEventHandler("open77:playerLifeStateChanged", function(playerId, phase)
    local selfId = mine.playerId
    if selfId == nil then return end
    if tostring(playerId) ~= tostring(selfId) then return end
    view.alive = tostring(phase) == "alive"
    CordonCombat.push()
end)

-- ---------------------------------------------------------------------------
-- HOW LOUD THE RIM IS
--
-- The vignette used to be a BOOLEAN, and that was wrong in both directions. It
-- was equally loud at 2 HP/s in Cordon 1, when a player has half a minute to
-- stroll back inside, and at 40 HP/s in Cordon 7, when they have two seconds --
-- so it read as a mode indicator rather than as danger, which is the one thing
-- it must not be. Plan section 4: the outside state is "unmissable, because a
-- boundary you cannot see reads as a bug".
--
-- It now grades on the WORSE of two measures, never the average:
--
--   * TIME OUTSIDE, against `rampMs`. This is the one that matters early: at
--     2 HP/s the rate says nothing, and how long you have been out there is
--     exactly the fact you are failing to notice.
--   * THE PHASE'S BLEED RATE, against `fullRateDps`. This is the one that
--     matters late: at 25 HP/s a twelve-second ramp would still be climbing
--     when the player is already dead, so the rate skips it straight to full.
--
-- The tuning is the SERVER'S (`Config.cordon.edge.vignette`, arriving in the
-- cordon fragment) because this resource has its own Lua state and cannot read
-- the mode's config. A server that sends none is an older server, and gets the
-- old binary behaviour rather than a rim that never lights.
--
-- `outsideMs` arrives at 2 Hz and is EXTRAPOLATED between pushes from the local
-- clock. That is presentation, not authority -- the same licence the compass
-- takes when it re-aims against the live camera -- and it is what makes the ramp
-- smooth instead of stepping four times.
-- ---------------------------------------------------------------------------

local function outsideLevel()
    if not view.outside then return 0 end
    -- THE OPERATOR'S OFF SWITCH, and it stops HERE rather than at the banner.
    -- `cordonEdge = "off"` removes the rim and the world edge; it does NOT
    -- remove the OUTSIDE THE CORDON banner or the compass, because those are
    -- the readout rather than the decoration, and the compass is the only thing
    -- on screen telling a bleeding player which way to run. Turning off a
    -- visual effect must never be able to strip a player of the information
    -- they need to survive it.
    if mine.edgeStyle == "off" then return 0 end
    local tuning = mine.vignette
    -- No tuning at all: an older server, from before the fragment carried it.
    -- Full, which is the behaviour that shipped, rather than a rim that never
    -- lights.
    if type(tuning) ~= "table" then return 1 end

    local elapsed = number(mine.outsideMs, 0)
    if mine.outsideAtMs ~= nil then
        elapsed = elapsed + math.max(0, nowMs() - mine.outsideAtMs)
    end
    local ramp = math.max(1, number(tuning.rampMs, 12000))
    local level = elapsed / ramp

    local full = number(tuning.fullRateDps, 25)
    if full > 0 then
        local byRate = number(mine.dps, 0) / full
        if byRate > level then level = byRate end
    end

    local floor = number(tuning.minimum, 0.35)
    if level < floor then level = floor end
    if level > 1 then level = 1 end
    return level
end

-- ---------------------------------------------------------------------------
-- TIME TO FLATLINE
--
-- The owner's second ask on 2026-09-04: "if you're outside why not adding some
-- kind of effect over the full game to know we're out of the zone, maybe a hit
-- effect?" The rim, the thump and the static in combat.css are the effect; this
-- is the NUMBER that goes with it, because "12 HP/S" asks a bleeding player to
-- do arithmetic and "FLATLINE IN 8s" does not.
--
-- It is derived, not invented: `health` is the server ledger (the push, or the
-- post-hit value `localDamaged` carries) and `dps` is the phase rate in the
-- cordon fragment. Dividing one by the other is the same licence the compass
-- takes when it turns a server position into a screen bearing.
--
-- Health is EXTRAPOLATED between pushes at the phase rate, for the same reason
-- `outsideMs` is: the push is 2 Hz and the bleed is 4 Hz, and a countdown that
-- steps twice a second reads as a HUD that is lagging. The extrapolation is
-- clamped at zero and only ever runs while outside, so it cannot show a death
-- the server has not yet confirmed -- at zero the page says FLATLINING, which
-- is true either way.
-- ---------------------------------------------------------------------------

local function flatlinePayload()
    if not view.outside or not mine.healthKnown then return nil end
    local dps = number(mine.dps, 0)
    if dps <= 0 then return nil end
    local health = number(mine.health, 0)
    if mine.healthAtMs ~= nil then
        health = health - dps * (math.max(0, nowMs() - mine.healthAtMs) / 1000)
    end
    if health < 0 then health = 0 end
    return { seconds = health / dps }
end

-- ---------------------------------------------------------------------------
-- Push
-- ---------------------------------------------------------------------------

local function usePayload()
    if not view.participant or mine.use == nil then return nil end
    local remaining = math.max(0, number(mine.use.remainingMs) - math.max(0, nowMs() - number(mine.useAtMs)))
    return { kind = mine.use.kind, remainingMs = remaining, durationMs = math.max(1, number(mine.use.durationMs, 1)) }
end

local function downedPayload()
    if mine.downed == nil then return nil end
    local elapsed = math.max(0, nowMs() - number(mine.downedAtMs))
    return { remainingMs = math.max(0, number(mine.downed.remainingMs) - elapsed),
        selfReadyInMs = math.max(0, number(mine.downed.selfReadyInMs) - elapsed),
        selfHoldMs = number(mine.downed.selfHoldMs, 3000), pending = mine.downed.pending == true }
end

function CordonCombat.push()
    if CordonHud and CordonHud.canPresent and not CordonHud.canPresent() then
        stockHud(false)
        return
    end
    if page == nil or not ready then return end
    stockHud(view.participant == true)
    local at = nowMs()
    ammoLabel, ammoCount, ammoReserve = nil, -1, -1
    local kit = CordonInventory.snapshot()
    for _, slot in ipairs(kit and kit.slots or {}) do
        if slot.active then
            ammoLabel, ammoCount, ammoReserve = slot.label, slot.ammo, slot.reserve
            break
        end
    end
    send("cordon:combat", {
        active = view.participant == true,
        mapOpen = CordonTacmap and CordonTacmap.isOpen and CordonTacmap.isOpen() == true or false,
        phase = view.phase,
        alive = view.alive == true,
        squad = view.squad,

        health = number(mine.health),
        maxHealth = math.max(1, number(mine.maxHealth, 100)),
        armor = number(mine.armor),
        plates = math.floor(number(mine.plates)),
        heals = math.floor(number(mine.heals)),

        ammoLabel = ammoLabel,
        ammo = ammoCount,
        ammoReserve = ammoReserve,

        shieldMs = math.max(0, number(mine.shieldMs)),

        outside = view.outside == true,
        -- 0..1. The page turns it into opacity and nothing else -- see the
        -- vignette rule in combat.css, which animates opacity ONLY so the
        -- compositor can carry it. A full-screen gradient recomputed per frame
        -- is the cost that took two clients' frame rate in
        -- docs/research/battle-royale-and-scale.md, and it is not paid here.
        outsideLevel = outsideLevel(),
        compass = compassPayload(),
        dps = number(mine.dps),
        -- `{ seconds }` while outside and bleeding, else absent. See
        -- flatlinePayload() for what it is derived from.
        flatline = flatlinePayload(),
        -- `{ seconds?, compass? }` while standing on doomed ground and not yet
        -- outside, else absent. See movePayload().
        move = movePayload(),
        movePulse = movePulseAt > 0 and (at - movePulseAt) < 900,

        -- Revive progress is a server-owned 0..1: the hold is timed on the
        -- server (plan section 6) and a client-side timer would let a lagged
        -- player see a bar complete on a revive that never happened.
        revive = mine.revive,
        downed = downedPayload(),
        use = usePayload(),

        cordonPulse = cordonPulseAt > 0 and (at - cordonPulseAt) < 900,
        indicators = indicatorPayload(),
    })
end

-- Called by client/main.lua on every authoritative state push.
function CordonCombat.onState(state)
    if type(state) ~= "table" then return end
    local phase = tostring(state.phase or "unknown")
    local self_ = type(state.self) == "table" and state.self or {}

    -- `participant` is the server's one word for "in this match", and the whole
    -- surface hangs on it: the vitals dock, the reticle and the cordon vignette
    -- are all off without it. A participant awaiting deployment placement is
    -- not combat-ready: canonical mode state must be alive before claiming
    -- native readouts or presenting weapons and vitals.
    local combatPhase = phase == "live" or phase == "extraction"
    view.participant = state.participant == true
        and combatPhase
        and (self_.state == "alive" or (self_.state == nil and self_.alive == true))
    view.phase = phase
    view.squad = type(state.squad) == "table" and math.floor(number(state.squad.id)) or 0

    -- Merge rather than replace: `open77:localDamaged` writes `health` between
    -- pushes, and a wholesale replace would undo it on the next snapshot -- a
    -- bar that jumps back up after a hit.
    mine.playerId = self_.playerId
    mine.maxHealth = math.max(1, number(self_.maxHealth, number(mine.maxHealth, 100)))
    -- HEALTH IS OPTIONAL IN THE PUSH AND HAS TO BE. The server shapes it into
    -- `self` when it has it, but a player who has not been hit yet has never
    -- produced a `localDamaged` either, so there are legitimately three states:
    -- told, inferred-from-a-hit, and not-yet-known.
    --
    -- Not-yet-known renders as FULL, not as zero. Defaulting to zero would put
    -- a red critical bar on the screen of every player who has taken no damage,
    -- which is the loudest possible way to be wrong.
    if self_.health ~= nil then
        mine.health = number(self_.health)
        mine.healthKnown = true
        -- Stamped from the LOCAL clock, like `outsideAtMs`: the flatline
        -- countdown extrapolates from here at the phase rate until the next
        -- authoritative figure lands.
        mine.healthAtMs = nowMs()
    elseif not mine.healthKnown then
        mine.health = mine.maxHealth
    end
    mine.armor = number(self_.armor, 0)
    mine.plates = number(self_.plates, 0)
    mine.heals = number(self_.heals, 0)
    mine.shieldMs = number(self_.shieldMs, 0)
    mine.downed = combatPhase and type(self_.downed) == "table" and self_.downed or nil
    mine.downedAtMs = nowMs()
    mine.revive = combatPhase and type(self_.revive) == "table" and self_.revive or nil
    mine.use = combatPhase and type(self_.use) == "table" and self_.use or nil
    mine.useAtMs = nowMs()
    view.alive = self_.alive ~= false
    view.outside = combatPhase and self_.outside == true

    nearestOpen = type(self_.nearestOpen) == "table" and self_.nearestOpen or nil

    -- DOOMED GROUND. Edge-triggered into the state for the pulse, level for
    -- everything else; the countdown is stamped against the local clock like
    -- the health figure so it can be extrapolated between pushes.
    local wasDoomed = view.doomed
    view.doomed = combatPhase and self_.doomed == true
    nextSafe = type(self_.nextSafe) == "table" and self_.nextSafe or nil
    local reachesInMs = self_.boundaryReachesInMs
    if reachesInMs == nil then reachesInMs = self_.cellClosesInMs end
    if reachesInMs ~= nil then
        mine.cellClosesMs = number(reachesInMs, 0)
        mine.cellClosesAtMs = nowMs()
    else
        mine.cellClosesMs = nil
        mine.cellClosesAtMs = nil
    end
    if view.doomed and not wasDoomed and not view.outside then
        movePulseAt = nowMs()
        send("cordon:move", { enter = true })
    end
    local cordon = type(state.cordon) == "table" and state.cordon or nil
    mine.dps = cordon ~= nil and number(cordon.damagePerSecond, 0) or 0

    -- The vignette's tuning and this player's own time outside. Both are
    -- OPTIONAL: `vignette` is absent when the operator has set the cordon edge
    -- to "off", and `outsideMs` is absent whenever the player is inside, which
    -- is most of a match.
    --
    -- `outsideAtMs` is stamped from the LOCAL clock rather than carried on the
    -- wire, because the two clocks are not the same clock and the difference is
    -- exactly the quantity being extrapolated. Only the elapsed time since this
    -- push is added; the server's own figure is trusted for everything before
    -- it.
    mine.vignette = cordon ~= nil and type(cordon.vignette) == "table" and cordon.vignette or nil
    mine.edgeStyle = cordon ~= nil and type(cordon.edgeStyle) == "string" and cordon.edgeStyle or nil
    if self_.outsideMs ~= nil then
        mine.outsideMs = number(self_.outsideMs, 0)
        mine.outsideAtMs = nowMs()
    elseif self_.outside ~= true then
        mine.outsideMs = 0
        mine.outsideAtMs = nil
    end


    CordonCombat.push()
end

function CordonCombat.attach(target, strings)
    page = target
    ready = false
    page:on("cordon:ready", function()
        ready = true
        page:send("cordon:strings", strings)
        CordonCombat.push()
    end)

    CreateThread(function()
        while page ~= nil do
            -- 25 Hz, and the page interpolates across the gap with a 40 ms
            -- linear transition. That interpolation is the ONLY local
            -- computation the surface is allowed, and 25 Hz is where it belongs:
            -- anything genuinely per-frame -- a nameplate, a world anchor -- must
            -- NOT go through a Lua tick at all. `Open77.anchors` exists because
            -- a projection sampled on the Lua tick was computed against an older
            -- camera than the frame that draws it, and the element visibly
            -- trails the view. Nothing on this surface follows a world object,
            -- which is why 25 Hz plus a CSS transition is enough here.
            if view.participant or mine.downed ~= nil or #indicators > 0 then
                CordonCombat.push()
            end
            Wait(40)
        end
    end)
end

function CordonCombat.detach()
    stockHud(false)
    page, ready = nil, false
    indicators = {}
    mine = {}
    nearestOpen = nil
    nextSafe = nil
    view.doomed = false
    ammoLabel, ammoCount = nil, -1
    cordonPulseAt = 0
    movePulseAt = 0
end
