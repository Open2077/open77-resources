-- Cordon, client half. Deliberately small: this resource owns rules, and the
-- HUD is its own resource (open77_cordon_hud) because a WebUI surface needs
-- reload_policy "reconnect" while these rules need "local", and one manifest
-- declares one policy.
--
-- What lives here is only what MUST be on the client: the engine hit reports
-- the server cannot see, the outside-the-cordon signal the HUD cannot derive,
-- and the grav-chute, whose levers (locomotion gravity, the local camera) exist
-- nowhere but on the machine the player is sitting at.

local bounds = nil       -- the last cordon:bounds payload
local outside = false

-- ---------------------------------------------------------------------------
-- THE ALARM. One sound, on the local player, the instant `outside` flips on.
--
-- It lives HERE and not in the HUD because of permissions: `Open77.sfx` needs
-- `world.effects`, which this manifest declares and the HUD's does not (that
-- resource holds only `network.events`). It rides the same edge as
-- `cordon:hurt` below, so the ear and the eye are told in the same frame.
--
-- UNVERIFIED, and harmless when wrong. The event name comes from
-- `Config.cordon.edge.alarm` and is a 1.6-seed Wwise id that nobody has
-- confirmed on 2.31; an unknown id is discarded by Wwise without a log line
-- (docs/research/vfx-sfx-runtime.md), so the failure mode is silence. The
-- duration is what makes even a WRONG name safe: Open77 queues a
-- `SoundStopEvent` for it when the handle expires, so a name that turned out
-- to loop is cut in two seconds. `enabled = false` in the config removes it.
-- ---------------------------------------------------------------------------
local alarmHandle = nil

local function soundAlarm()
    local edge = (Config and Config.cordon and Config.cordon.edge) or {}
    local alarm = edge.alarm or {}
    if alarm.enabled == false then return end
    if type(Open77.sfx) ~= "table" or type(Open77.sfx.play) ~= "function" then return end
    local event = type(alarm.event) == "string" and alarm.event or "ui_hacking_access_denied"
    local seconds = tonumber(alarm.durationSeconds) or 2.0
    if seconds < 0.5 then seconds = 0.5 elseif seconds > 10.0 then seconds = 10.0 end
    -- Stop the previous one first: a player dancing on the line would
    -- otherwise stack the buzzer on itself, and `stop` is by NAME, so one
    -- handle is all that can ever be outstanding anyway.
    if alarmHandle ~= nil and type(Open77.sfx.stop) == "function" then
        pcall(Open77.sfx.stop, alarmHandle)
        alarmHandle = nil
    end
    local ok, handle = pcall(Open77.sfx.play, event, { unique = true, duration = seconds })
    if ok and handle ~= nil then alarmHandle = handle end
end

-- ---------------------------------------------------------------------------
-- THE CORDON VIGNETTE SIGNAL.
--
-- Measured 2026-09-02 (E5): cordon damage is applied with no attributed
-- attacker, and `open77:localDamaged` requires one — so the platform's own
-- damage-direction event NEVER fires for the bleed. The red edge and the
-- compass would silently do nothing if the HUD waited for it.
--
-- So the server tells the client it is outside in the state push, and this
-- forwards a dedicated event the fast HUD surface can consume at 60 Hz without
-- waiting for the next 500 ms push.
-- ---------------------------------------------------------------------------
RegisterNetEvent("cordon:state", function(payload)
    if type(payload) ~= "table" then return end

    -- RE-BROADCAST LOCALLY, for the same reason `cordon:bounds` is: a second
    -- `RegisterNetEvent("cordon:state")` in client/edge.lua would subscribe the
    -- same resource to the same wire message twice, and the in-world edge needs
    -- exactly two facts out of it -- am I in this match, and is the cordon
    -- armed. This is the cheaper subscription and it keeps the net handler in
    -- one place.
    TriggerEvent("cordon:state:local", payload)

    local self_ = payload.self
    local nowOutside = type(self_) == "table" and self_.outside == true
    if nowOutside ~= outside then
        outside = nowOutside
        TriggerEvent("cordon:hurt", {
            outside = outside,
            nearest = type(self_) == "table" and self_.nearestOpen or nil,
            damagePerSecond = type(payload.cordon) == "table" and payload.cordon.damagePerSecond or 0,
        })
        -- The sound, on the way OUT only. Coming back in is relief, and relief
        -- is the rim fading -- not a second buzzer.
        if outside then soundAlarm() end
    end
end)

RegisterNetEvent("cordon:bounds", function(payload)
    if type(payload) ~= "table" then return end
    bounds = payload
    -- Re-broadcast locally so the tac-map surface can redraw without the HUD
    -- resource having to subscribe to a net event this resource already holds.
    TriggerEvent("cordon:bounds:local", payload)
end)

-- THE SURVEY: landings, loot anchors, landmarks, supply, the final-block hint.
-- Sent once per player rather than on the tick, because none of it changes
-- while a map is active — the server says why at `K.publishSurvey`.
--
-- KEPT, not just forwarded. The HUD is a separate resource on reload_policy
-- "reconnect": editing a stylesheet restarts it, and a restarted HUD would
-- otherwise draw an empty district until the next match reached deploy. This
-- resource is on "local" and survives that, so it re-broadcasts what it holds
-- as soon as the HUD asks.
local survey = nil

RegisterNetEvent("cordon:survey", function(payload)
    if type(payload) ~= "table" then return end
    survey = payload
    TriggerEvent("cordon:survey:local", payload)
end)

AddEventHandler("cordon:survey:request", function()
    if survey ~= nil then TriggerEvent("cordon:survey:local", survey) end
    if bounds ~= nil then TriggerEvent("cordon:bounds:local", bounds) end
end)

-- ---------------------------------------------------------------------------
-- ENGINE HIT REPORTS. A spawned hostile NPC fights with the engine's own AI on
-- every client that streams it, and the server sees none of it. The client that
-- OWNS the body reports the hit — owner-reports, never witness-reports, because
-- every client streaming a bot runs its own copy of that bot's AI and a witness
-- report would credit one burst once per spectator.
-- ---------------------------------------------------------------------------
-- `AddEventHandler`, NOT `RegisterNetEvent`, and the difference was the whole
-- bug. These three are LOCAL events raised by the plugin itself --
-- `CombatReplication.cpp:895` does `emit("open77:npcHit", ...)` on the client
-- that owns the shot. `RegisterNetEvent` subscribes to the SERVER-to-client
-- channel, so these handlers sat on a channel nothing ever published to and
-- were never once called.
--
-- The effect was total and completely silent: a player could empty magazines
-- into a bot and nothing happened anywhere. Measured 2026-09-02 -- the client's
-- own combat oracle counted `npcHits=76` while reporting `reports=0`, and the
-- server logged `onNpcDied` zero times across an entire match. The owner
-- reported it twice ("i still do not see the numbers of players decreasing
-- when killing a bot") and named the decisive clue himself: "pourtant sur le
-- mode pvp ca marche". It does -- open77_deathmatch/client/main.lua:288 and
-- open77_pvplab/client/main.lua:70 both use `AddEventHandler` for exactly
-- these events. This resource was the odd one out.
AddEventHandler("open77:npcHit", function(npcId, damage, hitZ, weaponTdbId, attackKind)
    TriggerServerEvent("cordon:npcHit", npcId, damage, hitZ, weaponTdbId, attackKind)
end)

AddEventHandler("open77:npcAttackedMe", function(npcId, damage, hitZ, weaponTdbId, attackKind)
    TriggerServerEvent("cordon:npcHurtMe", npcId, damage, hitZ, weaponTdbId, attackKind)
end)

AddEventHandler("open77:npcCrossfire", function(victimNpcId, attackerNpcId, damage)
    TriggerServerEvent("cordon:npcCrossfire", victimNpcId, attackerNpcId, damage)
end)

-- ---------------------------------------------------------------------------
-- THE GRAV-CHUTE. The client half of the aerial insertion.
--
-- The server releases the player 250 m above the surveyed landing zone and asks
-- for a chute; this arms it, watches for the touchdown, and reports it back.
--
-- WHAT THIS IS NOT ALLOWED TO DO IS HANG. Every exit from a descent — the
-- touchdown, the local deadline, a refused arm, a server disarm, the resource
-- stopping — folds the chute and restores the perspective, and the server has
-- its own longer deadline behind all of them. A client that goes quiet costs
-- one player a stand-up placement, never the match.
--
-- Third person is not decoration either. The drop is the only moment in Cordon
-- where a player has to read the ground *and* their own drift, and first person
-- shows neither. It is asked of the ARBITER (`Open77.perspective.set`) and not
-- of `Open77.camera.thirdPerson`: "first or third person" is six ownership
-- values — camera, body, input, weapon, effects, audio — and reaching past the
-- arbiter would move one of them and leave five behind. The arbiter may also
-- say no, which is a legitimate answer here: a vehicle, photo mode or a
-- workspot outranks a gamemode, and the descent works perfectly in first
-- person, it is merely worse.
-- ---------------------------------------------------------------------------
local chute = {
    active = false,
    generation = 0,
    restorePerspective = false,
}

local function chuteAvailable()
    return type(Open77.chute) == "table" and type(Open77.chute.arm) == "function"
end

local function perspectiveAvailable()
    return type(Open77.perspective) == "table" and type(Open77.perspective.set) == "function"
end

--- Fold the chute and give the body back. Safe to call when nothing is armed,
--- and called from every exit for exactly that reason.
---
--- THE EARLY RETURN THAT USED TO BE HERE WAS THE LEAK. `if not chute.active
--- then return end` reads as an optimisation and is not one: the armed state
--- lives in the PLUGIN, not in this Lua VM, so the one case where the two
--- disagree is precisely the case that matters -- a hot reload during a descent
--- hands the new VM a table that says `active = false` over a body that is still
--- flying. Every later disarm (the server's `cordon:chute armed=false`, the
--- resource stop, this file's own timeout) then returned on the first line and
--- the native chute stayed on: a player invulnerable and floating, which the
--- comment below already calls the one failure they cannot recover from alone.
---
--- So the disarm is issued unconditionally and the log is what is conditional.
--- `disarm()` on nothing is a refusal, not a fault.
local function chuteStop()
    chute.generation = chute.generation + 1
    local wasActive = chute.active
    chute.active = false
    if chuteAvailable() then
        local ok, reason = Open77.chute.disarm()
        if not ok and wasActive then
            -- Loud: a chute that will not disarm leaves the player invulnerable
            -- and floating, which is the one failure of this feature that a
            -- player cannot recover from on their own.
            Open77.log.warn("[cordon] chute disarm refused: " .. tostring(reason))
        end
    end
    if chute.restorePerspective then
        chute.restorePerspective = false
        if perspectiveAvailable() then pcall(Open77.perspective.set, "fpp") end
    end
end

--- The reload backstop, and the only place this file touches the arbiter
--- without having asked it for anything first.
---
--- A descent that outlives a hot reload leaves TWO things behind, in two
--- different places: an armed chute in the plugin, and a third-person view the
--- old VM asked the arbiter for and can no longer give back -- `restorePerspective`
--- died with that VM. `chuteStop` above fixes the first for every caller; only
--- this one can fix the second, and only because `isArmed()` is proof that the
--- lost VM had armed a descent and therefore had asked for `tps`.
---
--- It is still an ASK. `Open77.perspective.set` is the arbiter's door and it may
--- answer no -- a vehicle, photo mode or a workspot outranks a gamemode -- which
--- is the correct answer and is why nothing here checks the result.
--- `Open77.camera.thirdPerson` is not reached for: "first or third person" is six
--- ownership values and moving one of them leaves five behind (docs/perspective.md).
local function releaseChuteAcrossReload()
    if not chuteAvailable() then return end
    local ok, armed = pcall(Open77.chute.isArmed)
    if not ok or armed ~= true then return end
    Open77.log.warn("[cordon] a grav-chute survived a resource reload — folding it and " ..
        "restoring first person")
    chute.restorePerspective = true
    chuteStop()
end

AddEventHandler("onClientResourceStart", function(name)
    if name == GetCurrentResourceName() then releaseChuteAcrossReload() end
end)

RegisterNetEvent("cordon:chute", function(payload)
    if type(payload) ~= "table" then return end
    if payload.armed ~= true then
        chuteStop()
        return
    end
    if chute.active then return end

    if not chuteAvailable() then
        -- An older client, or one whose resource was refused `player.chute`.
        -- Say so immediately: the server then stands us on the landing zone in
        -- a second instead of after its own minute-long deadline.
        Open77.log.warn("[cordon] no chute binding on this client — asking for a ground placement")
        TriggerServerEvent("cordon:chuteFailed", "no_binding")
        return
    end

    local gravity = tonumber(payload.gravity) or -4.0
    local descentRate = tonumber(payload.descentRate) or 8.0
    local glideSpeed = tonumber(payload.glideSpeed) or 0.0
    local ok, reason = Open77.chute.arm(gravity, descentRate, glideSpeed)
    if not ok then
        Open77.log.warn("[cordon] chute arm refused: " .. tostring(reason))
        TriggerServerEvent("cordon:chuteFailed", tostring(reason))
        return
    end

    chute.active = true
    chute.generation = chute.generation + 1
    local generation = chute.generation
    -- Only restore what we changed, and only if the arbiter actually agreed.
    -- A player who was already in third person — because they prefer it, or
    -- because a server policy pins it — must be left there at touchdown, and an
    -- arbiter that refused the switch has left nothing to undo. `pcall` alone
    -- would not tell us apart: `set` reports a refusal as a RETURN VALUE, so a
    -- refused switch is a successful call.
    if perspectiveAvailable() and Open77.perspective.get() ~= "tps" then
        local called, applied = pcall(Open77.perspective.set, "tps")
        chute.restorePerspective = called and applied == true
    end

    local deadline = tonumber(payload.timeoutMs) or 45000
    if deadline < 1000 then deadline = 1000 end

    CreateThread(function()
        local waited = 0
        -- The first samples are discarded on purpose. A respawn lands the body
        -- on the ground for a frame before the world streams in under it, so a
        -- naive `isGrounded` at t=0 reports a touchdown that never happened and
        -- the descent ends before it starts.
        local settle = 750
        while chute.generation == generation and chute.active do
            Wait(100)
            waited = waited + 100
            local state = Open77.character.state()
            if waited >= settle and type(state) == "table" and state.grounded == true then
                local x, y, z = Open77.character.position()
                chuteStop()
                TriggerServerEvent("cordon:landed", x, y, z)
                return
            end
            if waited >= deadline then
                -- We never saw the ground. Fold anyway — a player still gliding
                -- when the server's own deadline fires would be placed on the
                -- ground under an armed chute, which is a player who cannot
                -- walk normally for the rest of the match.
                Open77.log.warn("[cordon] chute timed out without a touchdown after " ..
                    tostring(waited) .. " ms")
                chuteStop()
                TriggerServerEvent("cordon:chuteFailed", "no_touchdown")
                return
            end
        end
    end)
end)

-- A resource stop must not leave a chute armed: the native state lives in the
-- plugin, not in this VM, so it would survive the reload that removed the only
-- code able to fold it.
AddEventHandler("onClientResourceStop", function(name)
    if name == GetCurrentResourceName() then chuteStop() end
end)

-- THE CHUTE'S LAST BACKSTOP, and it hangs off the state push because that is the
-- only signal arriving twice a second whatever else has gone wrong.
--
-- A descent is ended by the server's `cordon:chute armed=false`, by this file's
-- own deadline, or by the resource stopping. All three are MESSAGES, and a
-- message can be missed -- which leaves a player invulnerable and floating for
-- the rest of the match with no way back. The state push is not a message about
-- the chute at all; it is the mode saying which phase it is in. A phase in which
-- nobody can be falling is therefore proof that anything still armed here is a
-- leak, and folding it costs two string compares per push.
--
-- The test is deliberately NARROW. `staging` and `resolved` are phases a descent
-- cannot overlap, and `spectating` is a body standing in the lobby bucket.
-- `deploy` and `live` are not tested and must not be: the deploy placement arms
-- the chute and marks the record alive inside one synchronous server block, and
-- a test that raced that block would fold the chute of a player who had just
-- been released 250 m above the map.
--
-- It subscribes to `cordon:state:local` rather than to the wire event because
-- the wire handler is registered above this line -- and because two
-- `RegisterNetEvent("cordon:state")` in one resource would subscribe it to the
-- same message twice, which the header of that handler already explains.
AddEventHandler("cordon:state:local", function(payload)
    if not chute.active or type(payload) ~= "table" then return end
    local phase = payload.phase
    local mine = type(payload.self) == "table" and payload.self.state or nil
    if phase == "staging" or phase == "resolved" or mine == "spectating" then
        Open77.log.warn(("[cordon] chute still armed in phase %s (self %s) — folding it"):format(
            tostring(phase), tostring(mine)))
        chuteStop()
    end
end)

-- The readiness handshake. The world is up and this client can be placed.
AddEventHandler("open77:worldReady", function()
    TriggerServerEvent("cordon:ready")
end)


-- ---------------------------------------------------------------------------
-- THE LOOT PROMPT, AND WHY THE MODE HAS TO DRAW IT ITSELF.
--
-- `open77_loot` says it in its own header: "Physical REDengine objects are
-- visuals only; their vanilla interactions are DISABLED by the script bridge
-- and pickup always returns to the server." So a ground drop has no native
-- prompt by design -- the gamemode owns the affordance, and Cordon never
-- supplied one. The owner reported it exactly: "je vois le drop, mais on peux
-- pas le select et rien faire du tout", and before that "j'ai pas d'interact en
-- m'approchant et F fais rien". Every pickup proven until now went through the
-- laboratory verb, which calls the API directly and never needed a prompt.
--
-- An earlier attempt made the container crates collision-free, on the theory
-- that the interaction ray was hitting the box instead of the item on its lid.
-- That was wrong and is kept anyway for its own reasons (see loot.lua): there
-- was never a ray to block, because there was never a native interaction.
--
-- So the prompt is built from the services the mode already depends on:
-- `open77_worldui` renders a POI (a ground ring plus a prompt card) and
-- `open77_interactions` owns the key and fires an event on activation. Both are
-- in this mode's dependency list already, and this is the same pair the revive
-- prompt uses.
-- ---------------------------------------------------------------------------

local LOOT_POI_RADIUS = 1.0           -- the ring on the ground
-- WHERE THE CARD APPEARS, and it is deliberately short.
--
-- `open77_worldui` defaults this to `radius + 0.5`, and the first build showed
-- "Open 5.2 m" floating over a crate from across the street. The owner called
-- it immediately: "the Open should display only if we are closeby". A prompt
-- you can read from five metres turns a looting decision into a shopping list
-- read from cover, and with eighty-eight crates on a 200 m map it also means
-- several cards competing on screen at once. 1.6 m is about an arm's reach.
local LOOT_PROMPT_DISTANCE = 2.0
local LOOT_POLL_MS = 700
-- Only crates this close get a POI at all. It was 28 m, which is a quarter of
-- the map: the ring was drawn for boxes nobody could reach and the POI budget
-- was spent on them.
-- 5 m, at the owner's calibration ("je pense 5m ca suffit pour les crates").
-- It was 28 m, then 12: at 28 the ring was drawn for boxes nobody could reach
-- and the POI budget went to them. Five metres is the range at which a crate is
-- a decision rather than scenery, and with eighty-eight of them on a 200 m map
-- it also keeps the cards from stacking on screen.
local LOOT_NEAR_METRES = 5.0
local LOOT_MAX_POIS = 6               -- worldui caps POIs; stay well inside it

local lootPois = {}                   -- [dropId] = handle
local lootEligible, lootGeneration = false, 0

local function lootCall(resource, name, ...)
    if type(Open77.exports) ~= "table" or type(Open77.exports.call) ~= "function" then
        return nil, "exports_unavailable"
    end
    local promise, reason = Open77.exports.call(resource, name, ...)
    if not promise then return nil, reason end
    local ok, result = pcall(function() return promise:await() end)
    if not ok then return nil, "await_failed" end
    if type(result) ~= "table" or result.ok ~= true then
        return nil, (type(result) == "table" and result.error) or "call_failed"
    end
    return result
end

local function removeLootPoi(dropId)
    local handle = lootPois[dropId]
    if handle == nil then return end
    lootPois[dropId] = nil
    lootCall("open77_worldui", "remove", handle)
end

AddEventHandler("cordon:state:local", function(payload)
    local eligible = type(payload) == "table" and payload.participant == true
        and type(payload.self) == "table" and payload.self.alive == true
    if eligible ~= lootEligible then lootGeneration = lootGeneration + 1 end
    lootEligible = eligible
    if not eligible then
        for dropId in pairs(lootPois) do removeLootPoi(dropId) end
    end
end)

--- The key press. `open77_interactions` hands back the interaction id it was
--- created with, and worldui prefixes it with the owning resource, so the drop
--- id travels in the id itself rather than in a side table that a reload would
--- lose.
--- The crates the server has published, `[id] = {x,y,z}`. Positions only --
--- the contents stay on the server, so a client cannot read the map for the
--- good boxes.
local crates = {}

local catalogueParts
RegisterNetEvent("cordon:crates", function(items, revision)
    if type(revision) == "table" then
        local part,total = tonumber(revision.part),tonumber(revision.total)
        if not part or not total or part<1 or part>total or total>256 then return end
        if not catalogueParts or catalogueParts.generation ~= revision.generation then
            catalogueParts={generation=revision.generation,total=total,parts={},received=0}
        end
        if total ~= catalogueParts.total or type(items) ~= "table" then return end
        if not catalogueParts.parts[part] then catalogueParts.received=catalogueParts.received+1 end
        catalogueParts.parts[part]=items
        if catalogueParts.received<total then return end
        items={}
        for n=1,total do
            for _,item in ipairs(catalogueParts.parts[n]) do items[#items+1]=item end
        end
        catalogueParts=nil
    end
    crates = {}
    if type(items) ~= "table" then return end
    for _, crate in ipairs(items) do
        local id = crate.id ~= nil and tostring(crate.id) or nil
        local x, y, z = tonumber(crate.x), tonumber(crate.y), tonumber(crate.z)
        if id ~= nil and x ~= nil and y ~= nil and z ~= nil then
            crates[id] = { x = x, y = y, z = z, kind=crate.kind, labelHeight=tonumber(crate.labelHeight) }
        end
    end
end)

-- Native fallback TTL/removal messages retire their prompts immediately too.
RegisterNetEvent("open77:loot:remove", function(id)
    local key = "d" .. tostring(id)
    crates[key] = nil
    removeLootPoi(key)
end)

--- The key press. The interaction id carries the crate id, so nothing has to be
--- looked up in a table a reload could lose.
AddEventHandler("cordon:loot:take", function(payload)
    if not lootEligible or type(payload) ~= "table" then return end
    local id = tostring(payload.interactionId or ""):match("loot_(d?%d+)$")
    if id == nil or lootPois[id] == nil or crates[id] == nil then return end
    -- ASKS, never decides. The server owns the crate, checks the match phase,
    -- that the player is alive and within reach, and claims the crate before
    -- granting so two players pressing together cannot both be served.
    if id:sub(1,1) == "d" then
        lootCall("open77_loot", "requestPickup", tonumber(id:sub(2)))
    else
        TriggerServerEvent("cordon:loot:open", id)
    end
end)

CreateThread(function()
    while true do
        Wait(LOOT_POLL_MS)

        -- `Open77.character.state()` is the same call the rest of this file
        -- already uses (see the chute touchdown loop above); it returns the
        -- state table and a reason, and answers before the player exists.
        local ok, me = pcall(Open77.character.state)
        local here = ok and type(me) == "table" and me.position or nil
        local drops = lootEligible and here ~= nil and crates or nil

        if type(drops) ~= "table" then
            -- No drops readable: retire everything rather than leaving rings
            -- floating over loot that is gone.
            for dropId in pairs(lootPois) do removeLootPoi(dropId) end
        else
            local wanted, ranked = {}, {}
            for id, drop in pairs(drops) do
                local x, y, z = drop.x, drop.y, drop.z
                if x ~= nil and y ~= nil and z ~= nil then
                    local dx, dy, dz = x - here.x, y - here.y, z - here.z
                    local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
                    if distance <= LOOT_NEAR_METRES then
                        ranked[#ranked + 1] =
                            { id = id, x = x, y = y, z = z, d = distance, kind=drop.kind, labelHeight=drop.labelHeight }
                    end
                end
            end
            -- NEAREST FIRST, then capped. A cluster holds more drops than the
            -- POI budget, and a player can only reach one of them at a time.
            table.sort(ranked, function(a, b) return a.d < b.d end)
            for index = 1, math.min(#ranked, LOOT_MAX_POIS) do
                wanted[ranked[index].id] = ranked[index]
            end

            for dropId in pairs(lootPois) do
                if wanted[dropId] == nil then removeLootPoi(dropId) end
            end

            for dropId, drop in pairs(wanted) do
                if lootEligible and lootPois[dropId] == nil then
                    local generation = lootGeneration
                    local created = lootCall("open77_worldui", "create", {
                        id = "loot_" .. tostring(dropId),
                        position = { x = drop.x, y = drop.y, z = drop.z },
                        labelHeight = tonumber(drop.labelHeight) or 1.0,
                        -- `interaction`, not `loot`: worldui accepts only
                        -- interaction/objective/spawn/danger and refuses the
                        -- rest, so an invented style is a POI that never
                        -- appears.
                        style = "interaction",
                        radius = LOOT_POI_RADIUS,
                        maxDistance = LOOT_NEAR_METRES + 4.0,
                        promptDistance = LOOT_PROMPT_DISTANCE,
                        -- The strings table lives in the HUD resource, which
                        -- is a separate VM; this one has no i18n of its own, so
                        -- the label is literal here and deliberately short --
                        -- `open77_interactions` caps icon and label text.
                        label = ({weapon="Weapon",ammo="Ammo",heal="Medkit",
                            shield="Armor",plate="Armor plate",money="Credits"})[drop.kind] or "Loot",
                        -- "F", not "E", and this is a real player-facing bug
                        -- rather than a style choice. The game binds its first
                        -- interaction choice to IK_F:
                        --   r6/config/inputUserMappings.xml:1175
                        --     <mapping name="Choice1" type="Button">
                        --       <button id="IK_F" overridableUI="selectChoice"/>
                        -- The badge is a LABEL -- `open77_interactions` draws
                        -- whatever string it is handed and binds nothing -- so a
                        -- badge reading "E" tells the player to press a key that
                        -- does nothing, and the crate looks broken. Found
                        -- 2026-09-03 while establishing why synthetic presses
                        -- never reach the interaction system; that turned out to
                        -- be a harness limit, but this was underneath it.
                        key = "F",
                        icon = "DIALOG",
                        event = "cordon:loot:take",
                    })
                    if created ~= nil then
                        -- Exports may yield. A death, spectator transition or
                        -- crate update while creating must not resurrect a POI.
                        if lootEligible and lootGeneration == generation and crates[dropId] ~= nil then
                            lootPois[dropId] = created.handle
                        else
                            lootCall("open77_worldui", "remove", created.handle)
                        end
                    end
                end
            end
        end
    end
end)

AddEventHandler("onClientResourceStop", function(name)
    if name ~= GetCurrentResourceName() then return end
    for dropId in pairs(lootPois) do removeLootPoi(dropId) end
end)

print("[cordon] client ready")

-- One reporter per attacking camp NPC, including hits against remote proxies.
AddEventHandler("open77:npcPlayerHit", function(victimId, npcId, epoch, damage)
    TriggerServerEvent("cordon:npcPlayerHit", victimId, npcId, epoch, damage)
end)
