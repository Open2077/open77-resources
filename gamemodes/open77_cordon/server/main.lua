-- Cordon: lifecycle, commands, the damage arbiter and the state push.
--
-- LAST in the manifest, deliberately. Everything below wires parts that the
-- earlier files defined, and registering a host event handler before the thing
-- it calls exists is the one ordering mistake this layout can still make.

local K = Cordon
local M = K.match
local C = K.cordon

-- ---------------------------------------------------------------------------
-- THE MAP. `K.map` is what every consumer reads, at the point of use, never
-- cached across a call: the runtime map store replaces these tables wholesale
-- when the operator selects a different map, and a file-scope reference taken
-- at load would pin the mode to whichever map was active when it started.
-- ---------------------------------------------------------------------------
--- The BUILT-IN maps, by the name the `activeMap` tunable uses. A map that is
--- not in this table simply is not a built-in; the runtime store owns the rest.
---
--- Historical surveyed presets stay read-only. Dogtown is an editable seed
--- loaded separately by the editor; it must never reserve an immutable name.
K.builtinMaps = { pacifica = Pacifica, watson = Watson, chinatown = Chinatown }

--- Resolves the active built-in. Falls back to Pacifica rather than to nil,
--- because a nil map is the one state that starts cleanly and then cannot
--- place anybody.
function K.resolveMap()
    local wanted = tostring(K.tune("activeMap", "dogtown"))
    if wanted == "dogtown" then return K.builtinMaps[wanted] or Dogtown end
    local chosen = K.builtinMaps[wanted]
    if chosen == nil then
        K.warn(("activeMap=%q is not a built-in; playing pacifica instead"):format(wanted))
        return Pacifica
    end
    return chosen
end

K.map = K.resolveMap()

--- Recomputed rather than asserted: a map that CLAIMS to be surveyed and is not
--- produces a mode that starts and then cannot place anybody, which is the
--- worst of the three possible states because it looks like it worked.
---
--- `surveyed` and `provisional` are deliberately SEPARATE questions. Surveyed
--- asks "can the mode place a player and close a block", which is what the loop
--- needs. Provisional asks "were these coordinates walked or derived", which is
--- what a playtest needs. A provisional map runs â€” that is the point of it â€”
--- but it says so in every readout, so nobody mistakes a loop test for a map.
function K.recomputeSurveyed()
    local map = K.map
    local grid = map.grid or {}
    local ok = grid.origin ~= nil and grid.groundDefault ~= nil
        and map.staging ~= nil and map.staging.position ~= nil
        and #(map.landings or {}) > 0 and #(map.finalBlocks or {}) > 0
    map.surveyed = ok and true or false
    return map.surveyed
end

function K.mapProvisional()
    return K.map.provisional == true
end

-- ---------------------------------------------------------------------------
-- COMBAT POLICY is HOST-GLOBAL â€” friendly fire and the damage multipliers are
-- shared by every bucket on the server. That is acceptable here only because
-- the mode runs one match per server (decision 1).
--
-- Applied twice on purpose: once at load and once on the first tick. A hot
-- reload prepares the incoming VM before the outgoing one is stopped, so a
-- policy set only at load can be silently cancelled by the VM being replaced â€”
-- which is how the deathmatch once spent a session with PvP quietly disabled.
-- ---------------------------------------------------------------------------
local policyApplied = false

local function applyCombatPolicy()
    -- TRUE, and this is the single most important line in the file.
    --
    -- The platform ships friendly fire OFF and says so: player-versus-player is
    -- a gamemode decision, opted into. With it off NOTHING a player does can
    -- hurt another player -- a bullet fired at four metres, crosshair on the
    -- head, spends its round, plays its impact and produces no damage event at
    -- all. There is no refusal to read anywhere. Measured 2026-09-02, and it is
    -- what made a whole afternoon of "the weapon must not really be firing"
    -- look like a weapon problem when the round counter had been falling the
    -- entire time.
    --
    -- Squadmates are NOT protected by this flag. They are protected by the team
    -- id the mode applies at every placement, which is the platform's own rule:
    -- the same non-zero team never damages itself. Turning the flag off to
    -- protect a squad would disarm the whole match to protect three people.
    pcall(Open77.combat.setFriendlyFire, true)
    policyApplied = true
end

applyCombatPolicy()

-- ---------------------------------------------------------------------------
-- LIFECYCLE. Every handler calls K.ensure() first â€” that is the lazy roster
-- adoption the platform forces, and missing one door makes that player
-- invisible to the mode for the rest of their session.
-- ---------------------------------------------------------------------------
AddEventHandler("onPlayerConnected", function(playerIdStr)
    local record = K.ensure(playerIdStr)
    if record == nil then return end
    record.state = "lobby"
end)

AddEventHandler("onPlayerReady", function(playerIdStr, detail)
    local record = K.ensure(playerIdStr)
    if record == nil then return end
    local staging = K.map.staging
    if staging ~= nil and staging.position ~= nil then
        K.placeAt(record.id, staging.position, K.stagingBucket(), {
            heading = staging.heading, reason = "join", graceMs = 3000,
        })
    end
    record.state = "staging"
    M.armCountdown()
    -- The survey, once, here. This is the earliest moment the player has a HUD
    -- that can receive it, and the map cannot change under them without another
    -- publish, so one send per session is the whole cost of a drawable overlay.
    K.publishSurvey(record.id)
    K.log(("player %d ready (%s)"):format(record.id, tostring(detail)))
end)

AddEventHandler("onPlayerDisconnected", function(playerIdStr)
    local id = tonumber(playerIdStr)
    if id == nil then return end
    local record = K.players[id]
    -- A disconnect is an elimination in v1 (decision: rejoin-in-place is v2,
    -- because it needs the mode to store verified weapons and ammo per player
    -- and that store only exists once loot inventory is stable).
    if record ~= nil and record.state == "alive" then
        M.onDeath(record, nil, "disconnect")
    end
    K.forget(id)
    M.armCountdown()
end)

AddEventHandler("open77:playerDamaged", function(victimId, attackerId, amount)
    local attacker = attackerId and K.players[K.bots.attackerId(attackerId) or 0] or nil
    if attacker ~= nil then
        attacker.damage = (attacker.damage or 0) + (tonumber(amount) or 0)
    end
end)

-- ---------------------------------------------------------------------------
-- THE SURVEY PUSH â€” the map itself, sent ONCE and never on the tick.
--
-- WHY THIS EXISTS. The tactical overlay reads `map.landmarks` and `map.supply`
-- and has since it was written, and NOTHING HAS EVER SENT A `map` FIELD: the
-- state push carries phase, self, squad and cordon, and that is all. So the
-- overlay drew a grid, a boundary and the player's own arrow over an otherwise
-- empty district â€” no landing zones, no loot, no landmarks, no supply â€” and on
-- the 2x2 Watson test map that is four cells and a triangle. Reported by the
-- owner 2026-09-02 ("wtf is that grid"), and it was never a renderer fault: the
-- renderer had nothing to render.
--
-- IT IS A SEPARATE EVENT FOR THE SAME REASON `cordon:bounds` IS. The survey is
-- STATIC for the life of a map â€” twelve landings, nine loot anchors, five
-- landmarks, three supply points on Watson â€” so putting it on a 2 Hz push to 64
-- players would spend a couple of kilobytes a second each re-sending numbers
-- that cannot change. It rides its own event, sent when a player becomes ready
-- and when the map changes, exactly as `C.publish()` does for the block grid.
--
-- WHAT IS DELIBERATELY NOT HERE: the loot the mode has actually spawned. Loot
-- anchors are SURVEY (where the map says loot belongs); spawned drops are match
-- state and would have to ride the tick. The overlay shows the anchors, which
-- is what a player picks a drop from, and says nothing about what is still on
-- the ground â€” a live loot radar is a different feature and a much bigger one.
-- ---------------------------------------------------------------------------

--- Flattens one surveyed point list into `{ key, label, x, y }` rows. The
--- survey tables nest the coordinates under `position`; the overlay reads them
--- flat, and flattening HERE keeps the browser from carrying a shape it would
--- only have to unwrap.
local function surveyPoints(list, extra)
    local rows = {}
    for _, entry in ipairs(list or {}) do
        local position = entry.position
        if position ~= nil and position.x ~= nil and position.y ~= nil then
            local row = {
                key = entry.key,
                label = entry.label,
                x = position.x,
                y = position.y,
            }
            if extra ~= nil then extra(row, entry) end
            rows[#rows + 1] = row
        end
    end
    return rows
end

--- The whole survey, shaped for the overlay. Rebuilt on every publish rather
--- than cached: a publish happens a handful of times per session, and a cache
--- here would be one more thing that has to notice the operator changing maps.
function K.surveyPayload()
    local map = K.map
    if map == nil then return nil end
    -- THE LATTICE, NOT THE SURVEY GRID, and this is the one place the choice has
    -- to be made deliberately rather than inherited.
    --
    -- The cordon closes lattice cells (`Config.cordon.lattice`) and publishes
    -- lattice geometry on `cordon:bounds` and in `C.fragment()`. The tac-map
    -- MERGES this survey with that fragment and lets the cordon win on the
    -- geometry -- so if the survey shipped block coordinates, everything on it
    -- that is keyed by CELL rather than by world position would land in the
    -- wrong square: the final-block hint would draw a 25 m patch where a 100 m
    -- block belongs, and the in-world edge would look up a walkway height from
    -- `ground` under a key that means somewhere else entirely.
    --
    -- So the survey is restated in lattice terms here, once, at the point it
    -- leaves the server. `map.grid` is untouched -- the survey is authored in
    -- blocks and `/br.map` still reads and writes blocks -- and
    -- `Grid.expandKeys` / `Grid.expandCellTable` do the translation. At
    -- factor 1 (any map already 8 cells on its short side) this is a copy.
    local grid = C.lattice(map.grid or {}) or map.grid or {}
    local factor = math.max(1, math.floor(tonumber(grid.subdivide) or 1))
    return {
        name = map.name,
        title = map.title,
        surveyed = map.surveyed == true,
        provisional = map.provisional == true,
        -- The grid rides here TOO, in the same two spellings `C.fragment()`
        -- uses. It is redundant with the fragment on purpose: the survey is the
        -- one message that is complete on its own, so a map that arrives before
        -- the first state push can still be drawn.
        gridCols = grid.cols, gridRows = grid.rows,
        cols = grid.cols, rows = grid.rows,
        blockMetres = grid.blockMetres, blockSize = grid.blockMetres,
        -- How many lattice cells make one surveyed block, so a consumer holding
        -- block-keyed data of its own can still find its way. 1 on a map that
        -- was never subdivided.
        subdivide = factor,
        originX = grid.origin and grid.origin.x or nil,
        originY = grid.origin and grid.origin.y or nil,
        -- HEIGHT, WHICH THE OVERLAY DOES NOT NEED AND THE WORLD EDGE CANNOT DO
        -- WITHOUT. The tac-map is a plan view and has never wanted a z; the
        -- in-world boundary (client/edge.lua) has to stand its posts on the
        -- ground, and the only height a client has otherwise is its own feet --
        -- the wrong storey for a post a hundred metres away.
        --
        -- It rides the SURVEY rather than the state push because none of it
        -- changes while a map is active, which is the same reason the landing
        -- zones and loot marks are here.
        --
        -- `groundDefault` is the surveyed street plane (Watson: the median of
        -- fourteen walked spawns) and is the number to prefer; `originZ` is the
        -- corner the grid was anchored from and is the fallback. `ground` is the
        -- per-cell override table, which on a multi-level map is the difference
        -- between a post on the walkway and a post four metres inside it.
        originZ = grid.origin and grid.origin.z or nil,
        groundDefault = grid.groundDefault,
        ground = grid.ground,
        indexBase = 1,
        -- The cells the cordon collapses into. It is a HINT, not a promise: the
        -- schedule picks ONE of them as the final cell at `C.begin`, and until
        -- then the honest statement is "the last fight will be in one of these".
        -- Expanded to lattice cells, so the hint covers the same GROUND it
        -- always did: one whitelisted block becomes the factor^2 cells inside
        -- it. Sending the block keys unexpanded would have drawn the hint in the
        -- corner of the map at a sixteenth of its size.
        finalBlocks = Grid.expandKeys(map.finalBlocks, factor),
        staging = map.staging and map.staging.position and {
            x = map.staging.position.x, y = map.staging.position.y,
        } or nil,
        landings = surveyPoints(map.landings, function(row, zone)
            row.hot = zone.hot == true
        end),
        lootClusters = surveyPoints(map.lootClusters, function(row, cluster)
            row.tier = cluster.tier
        end),
        -- `name`, not `label`: the overlay has read `landmark.name` since it was
        -- written and the survey tables spell it `label`. Renaming the survey
        -- would touch two maps and every future one; renaming it here touches
        -- one line.
        landmarks = surveyPoints(map.landmarks, function(row, landmark)
            row.name = landmark.label or landmark.key
        end),
        supply = surveyPoints(map.supply),
    }
end

--- Sends the survey to one player, or to everyone when `playerId` is nil.
function K.publishSurvey(playerId)
    local payload = K.surveyPayload()
    if payload == nil then return end
    if playerId ~= nil then
        TriggerClientEvent("cordon:survey", playerId, payload)
        return
    end
    for _, record in ipairs(K.humans()) do
        TriggerClientEvent("cordon:survey", record.id, payload)
    end
end

-- ---------------------------------------------------------------------------
-- THE STATE PUSH. One event, per player, shaped HERE rather than re-derived on
-- the client â€” the deathmatch measured what happens otherwise: a player armed
-- and fighting was shown the lobby dock because the HUD gated its whole layout
-- on one boolean nothing had ever sent.
-- ---------------------------------------------------------------------------

--- This player's squad drop pin, as the interface needs to READ it.
---
--- WHY THIS IS HERE AT ALL. `cordon:pin` has been accepted and stored on the
--- squad since it was written, and nothing ever sent it back â€” so `renderDeploy`
--- in the HUD, which has always read `self.pin`, always drew NO PIN SET. A pin
--- that lands correctly and is never acknowledged is indistinguishable from a
--- click that did nothing, and that is exactly what the owner reported
--- (2026-09-02, "i cannot set a point anywhere by left clicking on it").
---
--- The BLOCK is computed here rather than on the client for the usual reason:
--- the grid is the server's and a second opinion about which cell a point falls
--- in is a second bug.
local function pinFor(record)
    local squad = record.squad and M.current().squads[record.squad] or nil
    if squad == nil or squad.pin == nil then return nil end
    local block = nil
    -- Named in LATTICE cells, because that is what the tac-map labels its
    -- squares with. A pin confirmed as "block 1,1" over a map whose cells read
    -- 1,1 to 8,8 is a readout disagreeing with the picture beside it.
    local grid = K.map and C.lattice(K.map.grid) or nil
    if grid ~= nil then
        local col, row = Grid.cellOf(grid, squad.pin.x, squad.pin.y)
        if col ~= nil then block = Grid.key(col, row) end
    end
    return {
        x = squad.pin.x,
        y = squad.pin.y,
        block = block,
        -- The zone's own name when the pin was snapped to one, which is every
        -- pin a player set and every pin the drop chose for them. Absent only
        -- for a map with no landing zones at all.
        name = squad.pinLabel,
        -- True when the squad never chose and `M.landingFor` picked for them,
        -- so the panel can say so instead of claiming a decision nobody made.
        auto = squad.pinAuto == true,
    }
end

local function stateFor(record, shared)
    local match = M.current()
    local position = K.position(record.id)
    local outside = false
    local nearest = nil
    -- ONE PHASE EARLIER THAN `outside`: the player is inside, but on ground
    -- the announced phase is going to take. `C.evaluate` has just refreshed
    -- `record.lastCell`, so the three lookups below are current. Nil/false for
    -- everybody else, and the HUD draws nothing for nil -- see the block at
    -- `C.isDoomed` in server/cordon.lua for why this exists.
    local doomed = false
    local nextSafe = nil
    local cellClosesInMs = nil
    local boundaryReachesInMs = nil
    if M.isLive() and record.state == "alive" then
        local inside = C.evaluate(record)
        outside = inside == false
        if outside then
            nearest = C.nearestOpen(position)
        elseif inside == true and C.isDoomed(record.lastCell) then
            doomed = true
            nextSafe = C.nearestSafe(position)
            cellClosesInMs = C.cellClosesInMs(record.lastCell)
            boundaryReachesInMs = C.positionClosesInMs(position)
        end
    end

    -- HEALTH IS READ HERE, because the mode never stores it.
    --
    -- `record.health` was sent in the squad fragment and never assigned
    -- anywhere, so every push carried nil and the interface rendered it as
    -- `HP 0` -- for a player the same interface's squad panel listed as UP and
    -- `char.state` reported alive at a hundred. Measured 2026-09-02 on two real
    -- clients standing three metres apart.
    --
    -- The mode has no business keeping its own copy of a number the platform
    -- owns and updates every tick, so it asks.
    local function healthOf(playerId)
        local ok, state = pcall(Open77.players.getHealth, playerId)
        if not ok or type(state) ~= "table" then return nil end
        return state.health
    end

    local squad = record.squad and match.squads[record.squad] or nil
    local members = {}
    if squad ~= nil and K.squads == nil then
        for _, memberId in ipairs(squad.members) do
            local member = K.players[memberId]
            if member ~= nil then
                -- `alive` alone cannot drive a revive prompt: it is false for a
                -- squadmate who is DOWN and still saveable and equally false for
                -- one who has bled out, and those two demand opposite things of
                -- the player. So send the distinction, and the body, because a
                -- client that does not know where the body is cannot offer to
                -- walk to it -- the downed player stops publishing snapshots the
                -- moment he goes down (PlayerReplication.cpp:1735), so his live
                -- position is not an answer and `bodyPosition`, captured once at
                -- death, is the only one there is.
                local revivable = K.squads ~= nil and K.squads.revivable ~= nil
                    and K.squads.revivable(member) or false
                members[#members + 1] = {
                    playerId = member.id,
                    name = K.name(member.id),
                    alive = member.state == "alive",
                    bot = member.bot,
                    health = healthOf(member.id),
                    downed = revivable,
                    -- Only while revivable. Sending a body nobody can reach any
                    -- more would leave a prompt hanging over a corpse.
                    body = revivable and member.bodyPosition
                        and { x = member.bodyPosition.x, y = member.bodyPosition.y,
                              z = member.bodyPosition.z } or nil,
                    reviveUntilMs = revivable and member.reviveUntilMs or nil,
                }
            end
        end
    end

    local inventorySlots = {}
    for tweakDbId, slot in pairs(record.weapons or {}) do
        -- Older reload carry records have boolean values; those prove ownership
        -- but cannot identify a slot and must not be displayed in slot 1.
        if type(slot) == "number" and slot >= 1 and slot <= 3 then
            inventorySlots[#inventorySlots + 1] = {
                slot = slot, tweakDbId = tweakDbId,
                label = record.weaponLabels and record.weaponLabels[tweakDbId] or nil,
            }
        end
    end
    table.sort(inventorySlots, function(a,b) return a.slot < b.slot end)

    return {
        -- Not "has a roster row" but "is in THIS match": a player who has not
        -- joined the queue stands in staging and watches, and the interface has
        -- to be able to tell the difference. M.isParticipant() is the one
        -- answer; server/match.lua explains what it turns on and off.
        participant = M.isParticipant(record),
        inventory = M.isParticipant(record) and {
            slots = inventorySlots, plates = record.plates, heals = record.heals,
        } or nil,
        phase = match.phase,
        matchId = match.id,
        -- Dedicated-server elapsed time gives late arrivals the same Dogtown night.
        night = K.map.name == "dogtown" and match.phase ~= "staging" and match.deployedAtMs ~= nil and {
            matchId = match.id,
            secondsOfDay = (22 * 3600 + math.max(0, K.nowMs() - match.deployedAtMs) / 1000 * 8) % 86400,
            rate = 8,
        } or nil,
        format = match.format,
        remainingMs = match.phaseEndsAtMs and math.max(0, match.phaseEndsAtMs - K.nowMs()) or nil,
        alivePlayers = shared.alivePlayers,
        aliveSquads = shared.aliveSquads,
        totalPlayers = K.count,
        -- LIVING bots, not every bot row the match ever had.
        --
        -- `#K.botRecords()` counts dead ones too, so the tag beside the alive
        -- count read "40 bots" from the drop to the result card while the number
        -- next to it fell. The two halves of one band disagreed by construction,
        -- and with kills not registering at all there was no way for the owner
        -- to tell which half was lying. See match.html: bots sit BESIDE the
        -- alive count, and a figure that never moves is not beside anything.
        botCount = shared.botCount,
        rated = not M.tainted(),
        self = {
            playerId = record.id,
            -- Physical routing, not match membership: an eliminated player can
            -- be back in staging while everyone else is still fighting.
            inLobby = position ~= nil and position.bucket == K.stagingBucket(),
            revive = K.squads and K.squads.reviveView(record) or nil,
            downed = K.squads and K.squads.downedView(record) or nil,
            use = K.loot and K.loot.useView and K.loot.useView(record) or nil,
            alive = record.state == "alive",
            state = record.state,
            kills = record.kills,
            placement = record.placement,
            plates = record.plates,
            heals = record.heals,
            health = healthOf(record.id),
            -- THE SHIELD POOL, AND IT IS THE MODE'S NUMBER, NOT THE PLATFORM'S.
            --
            -- `healthOf` cannot supply this. server/loot.lua keeps the battle
            -- royale armour pool on the player record and deliberately leaves
            -- the engine's own `armor` at zero, because the engine's armour is
            -- absorbed out of SCRIPTED damage as well as real hits -- and
            -- scripted damage is how the cordon bleeds people. A pool the
            -- engine owned would make the cordon survivable. The long version
            -- is in the header of server/loot.lua.
            --
            -- The HUD has been ready for this the whole time and has never
            -- received it: open77_cordon_hud/client/combat.lua:479 reads
            -- `self.armor` and defaults it to zero, so the armour bar has been
            -- pinned at empty for every player in every match so far.
            --
            -- `maxArmor` is what the worn carrier is worth. combat.js still
            -- scales the bar against a hard-coded 75, which is the heaviest
            -- tier exactly -- so this field changes nothing today and is what
            -- the HUD needs the day a tier moves.
            armor = record.armor or 0,
            maxArmor = (K.loot ~= nil and type(K.loot.shieldCapacity) == "function")
                and K.loot.shieldCapacity(record) or 0,
            shieldMs = math.max(0, (record.shieldUntilMs or 0) - K.nowMs()),
            outside = outside,
            -- HOW LONG THEY HAVE BEEN OUT THERE, in milliseconds, and only
            -- while they are. It is what the screen-side edge grades on: the
            -- vignette used to be a boolean, equally loud at 2 HP/s in Cordon 1
            -- when a player has half a minute to walk back and at 40 HP/s in
            -- Cordon 7 when they have two seconds.
            --
            -- `outsideSinceMs` is set by the containment tick and cleared the
            -- moment a player reads as inside. It is deliberately NOT cleared
            -- by a cannot-tell sample -- see `C.tick` -- so a player who
            -- interrupts their own replication does not get a fresh ramp along
            -- with a frozen damage accumulator.
            outsideMs = (outside and record.outsideSinceMs)
                and math.max(0, K.nowMs() - record.outsideSinceMs) or nil,
            nearestOpen = nearest,
            -- STANDING ON DOOMED GROUND. `doomed` is true while this player's
            -- cell is announced and not yet closed; `cellClosesInMs` is that
            -- cell's own deadline (not the phase's first closure -- cells close
            -- one at a time across the window, farthest from the final first,
            -- so two players in the same doomed ring can have deadlines
            -- twenty seconds apart); `nextSafe` is the nearest cell that
            -- survives the announced phase, in the same shape as
            -- `nearestOpen`. All three absent when not doomed, so an older HUD
            -- and a player standing safely see nothing new.
            doomed = doomed or nil,
            cellClosesInMs = cellClosesInMs,
            boundaryReachesInMs = boundaryReachesInMs,
            nextSafe = nextSafe,
            cell = record.lastCell,
            -- The squad's drop pin, so the deploy panel and the tactical
            -- overlay can both acknowledge a click. See `pinFor`.
            pin = pinFor(record),
        },
        squad = K.squads ~= nil and K.squads.fragmentFor(record) or
            (squad and { id = squad.id, alive = M.squadAlive(squad), members = members } or nil),
        cordon = shared.cordon,
        -- WHO KILLED WHO, newest first. The page has read this field since it
        -- was written and the server has never sent it; see M.feed.
        feed = shared.feed,
        -- Absent until the match has an outcome; see M.resultFor.
        result = M.resultFor(record),
        -- THE QUEUE, not a ready ledger. `queued` is how many have asked for the
        -- next match, `lobby` how many are standing here, `needed` the floor the
        -- countdown waits for. `inQueue` is this player's own answer and is the
        -- authority the HUD reconciles its optimistic key press against.
        staging = match.phase == "staging" and {
            queued = shared.queued,
            lobby = shared.lobby,
            needed = (Config and Config.match and Config.match.minPlayers) or 2,
            inQueue = record.queued == true,
            canQueue = record.state ~= "lobby",
            countdownMs = match.phaseEndsAtMs and math.max(0, match.phaseEndsAtMs - K.nowMs()) or nil,
        } or nil,
    }
end

local function pushState()
    local roster = K.humans()
    local shared, warned
    for index, record in ipairs(roster) do
        if (index - 1) % 8 == 0 then
            if index > 1 then Wait(0) end
            shared = { cordon = C.fragment(), alivePlayers = M.aliveCount(),
                aliveSquads = M.remainingSquads(), botCount = K.aliveBotCount(),
                feed = M.feed(), queued = M.queuedCount(), lobby = #roster }
        end
        -- A disconnected row must not be published into a replacement session.
        if K.players[record.id] == record then
            local ok, why = pcall(function()
                TriggerClientEvent("cordon:state", record.id, stateFor(record, shared))
            end)
            if not ok and not warned then
                warned = true
                K.warn("state push failed for player " .. record.id .. ": " .. tostring(why))
            end
        end
    end
end

-- Spread the roster across server frames. A single 64-player push used to
-- consume the resource's whole instruction allowance and silently omit later
-- players. This publisher yields independently of the match/damage tick.
CreateThread(function()
    Wait(0) -- Let the match thread prepare buckets and publish the survey first.
    while true do
        local started = K.nowMs()
        local ok, why = pcall(pushState)
        if not ok then K.warn("state publisher failed: " .. tostring(why)) end
        Wait(math.max(1, 500 - (K.nowMs() - started)))
    end
end)

-- ---------------------------------------------------------------------------
-- THE TICK. Match/cordon logic runs at the cordon's rate; the independent
-- publisher above spreads state delivery across frames.
--
-- Diagnostics are BUFFERED and logged once rather than per sample. An unbuffered
-- probe in the arena once reported a 291 ms tick where the truth was 14 ms â€”
-- the probe's own logging was the cost it was measuring.
-- ---------------------------------------------------------------------------
CreateThread(function()
    local tickMs = math.floor(1000 / math.max(1, (Config and Config.cordon and Config.cordon.tickHz) or 4))
    local nextCarry = 0
    K.prepareBucket(K.stagingBucket())
    K.prepareBucket(K.matchBucket())
    K.recomputeSurveyed()
    -- Once, to whoever is already here. `onPlayerReady` covers everybody who
    -- joins later, but a hot reload of this resource (policy "local") re-runs
    -- this VM under players who became ready minutes ago and will never fire
    -- that handler again â€” and an overlay with no survey is the empty grid this
    -- publish exists to prevent.
    K.publishSurvey()
    if not K.map.surveyed then
        K.warn("map is NOT surveyed: staging and deploy will refuse. Run the survey (see Phase 2).")
    elseif K.mapProvisional() then
        K.warn("map is PROVISIONAL: coordinates are derived from one sampled point, not walked. " ..
            "The loop runs; the map is not real. See shared/pacifica.lua.")
    end
    -- The WHOLE body is wrapped, not just the calls inside it. An error raised
    -- anywhere in a CreateThread body terminates that thread permanently and
    -- silently â€” no log, no retry, and every symptom appears somewhere else
    -- (a match frozen in one phase, a cordon that never closes, a HUD that
    -- stops updating) hours later. Losing one tick is survivable; losing the
    -- thread is the mode.
    while true do
        Wait(tickMs)
        local tickOk, tickErr = pcall(function()
        if not policyApplied then applyCombatPolicy() end
        local ok, err = pcall(M.tick)
        if not ok then K.warn("match tick failed: " .. tostring(err)) end
        if K.loot ~= nil then pcall(K.loot.tick) end
        if K.squads ~= nil then pcall(K.squads.tick) end
        if K.bots ~= nil then pcall(K.bots.tick) end
        -- `now` is read ONCE here and used by both schedules below. It was
        -- briefly read after the carry block that uses it, which made `now` nil
        -- on the first iteration â€” and an error raised in a CreateThread body
        -- is not caught by anything: the thread simply stops, with no log line
        -- and no failed call. The match then sat in `deploy` forever while the
        -- server looked perfectly healthy. Keep every use of `now` below it.
        local now = K.nowMs()
        -- Carried every few seconds rather than only on stop: a hot reload
        -- driven by the file watcher does not always give the outgoing VM a
        -- clean onResourceStop, and a roster that is five seconds stale is
        -- worth immeasurably more than one that is gone.
        if now >= nextCarry then
            nextCarry = now + 5000
            pcall(K.carry)
        end
        end)
        if not tickOk then K.warn("tick body failed: " .. tostring(tickErr)) end
    end
end)

-- ---------------------------------------------------------------------------
-- COMMANDS. Restriction is per COMMAND, not per invocation, which is why the
-- self and other forms of a query are two commands rather than one with an
-- argument.
-- ---------------------------------------------------------------------------
local function reply(source, raw, text)
    K.log(text)
    if source ~= nil and source > 0 then
        TriggerClientEvent("open77:command:result", source, raw or "", true, text)
    end
end

RegisterCommand("br.status", function(source, _, raw)
    local match = M.current()
    -- `bots` is LIVING/TOTAL. One number could not answer the question this
    -- command is run to answer -- "is killing a bot registering?" -- because a
    -- total that never moves and an alive count that never moves look the same.
    reply(source, raw, ("cordon: phase=%s match=%s format=%s players=%d alive=%d squads=%d bots=%d/%d rated=%s map=%s%s openCells=%d"):format(
        match.phase, tostring(match.id), match.format, K.count, M.aliveCount(),
        M.remainingSquads(), K.aliveBotCount(), #K.botRecords(), tostring(not M.tainted()),
        tostring(K.map.surveyed and "surveyed" or "UNSURVEYED"),
        K.mapProvisional() and " (PROVISIONAL)" or "", C.openCount()))
end, false)

RegisterCommand("br.where", function(source, args, raw)
    -- The optional player argument is what lets the SERVER CONSOLE use this,
    -- and that matters for more than convenience: reloading the resource empties
    -- the roster, and the platform gives no way to enumerate players, so lazy
    -- adoption has no door left until each player next crosses a lifecycle
    -- event. Naming one here re-adopts them.
    --
    -- THE COST OF THAT, and it is easy to trip over: `K.ensure` CREATES a record
    -- for an id nobody is using, so probing a range of ids to find out who is
    -- who leaves one lobby record per probe behind. Measured 2026-09-03 -- eight
    -- `br.where` probes took `players=16` to `players=24`, and a longer session
    -- of the same reached 79 against 16 live sessions, which then made every
    -- headcount in the log wrong and inflated what `br.queue all` enrolled.
    --
    -- It is left as it is because the adoption is the point and the platform
    -- offers no "does this id exist" to gate it on. Probe deliberately, one id
    -- you have reason to believe in, not a range; a server restart clears them.
    local record = K.ensure(tonumber(args and args[1]) or source)
    if record == nil then return reply(source, raw, "player only (or pass a playerId)") end

    -- ADOPTING DURING STAGING ALSO PLACES, and that is a rescue, not a
    -- convenience.
    --
    -- `toStaging` places every player the roster holds at the time it runs. A
    -- player adopted afterwards -- because the resource reloaded, or because
    -- their own lifecycle event was missed -- is left in `lobby` wherever they
    -- happened to be standing, and nothing ever moves them again. Measured
    -- 2026-09-02: a client stranded that way sat at one health at an old
    -- landing through the end of a match and into the next staging, and neither
    -- ending the match nor re-adopting it by hand brought it back.
    --
    -- Placing here closes that door, because a placement is a respawn and a
    -- respawn restores health. It is deliberately limited to the staging phase:
    -- teleporting somebody to the lobby in the middle of a live match would be
    -- a far worse bug than the one it fixes.
    if record.state == "lobby" and M.phase() == "staging" then
        local staging = K.map and K.map.staging or nil
        if staging ~= nil and staging.position ~= nil then
            record.state = "staging"
            K.placeAt(record.id, staging.position, K.stagingBucket(), {
                heading = staging.heading, reason = "adopt", graceMs = 3000,
            })
            K.log(("player %d adopted into staging and placed"):format(record.id))
        end
    end

    local position = K.position(record.id)
    local inside = C.evaluate(record)
    -- THE KIT, because a crate grant had no text readout at all and so no
    -- automated test could assert one. The street tier gives a weapon in about
    -- one roll in five; everything else it grants -- ammo, a heal, a plate, a
    -- vest, eddies -- moves a number that nothing outside the head-up display
    -- could see. `guns` is the count of the mode's own weapon ledger, not the
    -- engine's, which is the same ledger the arbiter prices damage against.
    local guns = 0
    for _ in pairs(record.weapons or {}) do guns = guns + 1 end
    reply(source, raw, ("where player=%d state=%s pos=%s cell=%s inside=%s squad=%s shield=%dms " ..
        "kit crates=%d guns=%d plates=%d heals=%d armor=%d eddies=%d"):format(
        record.id, record.state,
        position and ("%.1f,%.1f,%.1f"):format(position.x, position.y, position.z) or "?",
        tostring(record.lastCell), tostring(inside), tostring(record.squad),
        math.max(0, (record.shieldUntilMs or 0) - K.nowMs()),
        record.cratesOpened or 0, guns, record.plates or 0, record.heals or 0,
        record.armor or 0, record.eddies or 0))
end, false)

-- br.edge [off|hud|world] -- OPERATOR.
--
-- It exists because the world edge is drawn on the CLIENT from a config file
-- the client loaded at connect, so the only two ways to change it are a
-- resource reload -- which empties the roster mid-match, see K.tune's header --
-- and this. With no argument it reports; with one it writes the tunable and
-- republishes the bounds, which is the message the client reads the style off.
--
-- Republishing is the whole point of the write path: `C.publish` is otherwise
-- only called when a block closes, so without it a style change would sit
-- unapplied until the next closure, which at Cordon 1 is three minutes away.
RegisterCommand("br.edge", function(source, args, raw)
    local wanted = args and args[1] and tostring(args[1]):lower() or nil
    if wanted ~= nil then
        if wanted ~= "off" and wanted ~= "hud" and wanted ~= "world" then
            return reply(source, raw, "br.edge <off|hud|world>")
        end
        if type(Open77.tunables) ~= "table" or type(Open77.tunables.set) ~= "function" then
            return reply(source, raw, "edge: this server exposes no tunable store")
        end
        -- `set` reports a REFUSAL as a return value, not a raise -- the same
        -- shape open77_deathmatch's map store handles at `persistActiveName`.
        -- A pcall alone would call a refused write a success and then report a
        -- style the server never adopted.
        local called, result, message = pcall(Open77.tunables.set, "cordonEdge", wanted)
        if not called then return reply(source, raw, "edge: refused -- " .. tostring(result)) end
        if result == false then return reply(source, raw, "edge: refused -- " .. tostring(message)) end
        C.publish()
    end
    local edge = (Config and Config.cordon and Config.cordon.edge) or {}
    local column = edge.column or {}
    local light = edge.light or {}
    reply(source, raw, ("edge: style=%s column=%s(%s) light=%s(i=%s r=%s out=%.0fm) posts<=%d radius=%.0fm"):format(
        C.edgeStyle(),
        tostring(column.enabled ~= false), tostring(column.effect),
        tostring(light.enabled ~= false), tostring(light.intensity), tostring(light.radius),
        tonumber(light.outsetMetres) or 0.0,
        math.floor(tonumber(edge.maxPosts) or 0),
        tonumber(edge.drawRadiusMetres) or 0.0))
end, true)

RegisterCommand("br.start", function(source, _, raw)
    if M.phase() ~= "staging" then
        return reply(source, raw, "refused: stop the current match with /br.stop first")
    end
    if not K.recomputeSurveyed() then
        return reply(source, raw, "refused: the map is not surveyed (needs origin, ground, staging, a landing zone and a final-block whitelist)")
    end
    M.toDeploy("operator")
    reply(source, raw, "match starting: deploy")
end, true)

-- br.queue <all|none> -- OPERATOR, and a LOAD-HARNESS entry only.
--
-- The queue is normally entered from the client, through the `cordon:queue` net
-- event behind the Y key. Harness phantoms live BELOW the transport seam: they
-- replay movement and appearance but originate no net events, so they can never
-- press Y and a 64-session match can never reach the two-sides minimum.
--
-- This is the server-side door for exactly that, and it is deliberately not a
-- shortcut around the rules: it calls the same `M.setQueued` the net event
-- calls, so staging-only, the lobby guard and the countdown all behave
-- identically. It is RESTRICTED, so no ordinary player can reach it.
RegisterCommand("br.queue", function(source, args, raw)
    local wanted = (args[1] or "all"):lower() ~= "none"
    local touched, refused = 0, {}
    -- `K.humans()` is the same list the countdown counts, so this cannot enrol
    -- a bot or a record the mode does not already consider a player.
    for _, record in ipairs(K.humans()) do
        local ok, why = M.setQueued(record.id, wanted)
        if ok then touched = touched + 1
        elseif why ~= nil then refused[why] = (refused[why] or 0) + 1 end
    end
    local detail = {}
    for why, count in pairs(refused) do detail[#detail + 1] = ("%s=%d"):format(why, count) end
    reply(source, raw, ("queue %s: %d player(s)%s"):format(
        wanted and "joined" or "left", touched,
        #detail > 0 and (" refused " .. table.concat(detail, " ")) or ""))
end, true)

local function stopMatch(source, _, raw)
    if M.phase() ~= "staging" then M.toStaging("operator") end
    if M.phase() ~= "staging" then
        return reply(source, raw, "refused: match could not return to staging")
    end
    -- A manual stop must stay stopped. Returning to staging alone retains the
    -- queue and immediately arms another countdown on the next match tick.
    for _, record in ipairs(K.humans()) do M.setQueued(record.id, false) end
    reply(source, raw, "match stopped, everybody to staging; queue cleared")
end
RegisterCommand("br.stop", stopMatch, true)
RegisterCommand("br.end", stopMatch, true)

-- br.beside <healerId> <downedId> -- OPERATOR, and a TEST ENTRY only.
--
-- Puts a healer at arm's length from a downed squadmate so a revive can
-- actually be attempted. It exists because proving a revive from the agent loop
-- kept failing on geography rather than on code: teleporting the healer to the
-- BODY's coordinates puts him wherever the body fell, which for a cordon death
-- is by definition outside the cordon, so the healer starts bleeding and the
-- next command answers `healer_not_alive`. That happened twice.
--
-- So: offset toward the map centre, at 60% of the reach, and lift the healer to
-- the body's own z rather than trusting a guessed one. It does NOT revive, does
-- NOT relax the reach check and does NOT touch either state -- `br.revive` still
-- runs every guard afterwards, which is the point. This verb only removes the
-- travel, which is the part a person does trivially and this loop cannot.
-- br.tp <x> <y> <z> -- OPERATOR, and a TEST-LOOP verb only.
--
-- THERE IS NO WAY TO MOVE A PLAYER DURING A LIVE SESSION, and that gap cost
-- seven failed attempts to photograph the boundary on 2026-09-04:
--
--   * the debug bridge refuses its own teleport in-session --
--     `ERR session_active local_lab_command_disabled`;
--   * `tpc` belongs to freeroam and is NOT registered on a cordon-only server
--     ("no running resource registers command 'tpc'");
--   * `br.beside` needs a real body, and a bot corpse has none, which the
--     command says out loud -- "player -4 has no body";
--   * and walking runs into Watson's covered market in every direction, which
--     is why four captures spanning 360 degrees at 18 m from the edge showed a
--     food stall, an arcade and two walls.
--
-- So the boundary could be measured but never SEEN, which is exactly the shape
-- of bug this mode has already shipped twice.
--
-- It is RESTRICTED. It uses the same `K.placeAt` every legitimate placement in
-- this mode uses, so the kill it causes is suppressed exactly as a drop's is,
-- and it places into the player's CURRENT bucket, so it cannot be used to step
-- out of the match dimension into staging or vice versa.
--
-- KNOWN LIMIT, measured immediately after writing it: TELEPORTING SOMEWHERE
-- NOBODY IS STANDING DROPS YOU THROUGH THE WORLD. Two hops toward a boundary
-- post whose own reported ground was z=7.9 landed the player at z=-63.4 and
-- then z=-60.9. The destination's collision had not streamed in -- this command
-- moves a body faster than the engine loads the floor under it, and it is the
-- same symptom already recorded for Dogtown, where the owner "falls through
-- roads and stairs that a third party confirmed are solid in VANILLA".
--
-- So this is reliable for short hops inside the area the player is already
-- standing in, and NOT a way to visit the far side of the map. For a distant
-- target either walk the last stretch, or wait for the cordon to close toward
-- you, which streams the ground in ahead of the boundary.
RegisterCommand("br.tp", function(source, args, raw)
    local id = tonumber(source) or 0
    if id <= 0 then
        return reply(source, raw, "br.tp places YOUR body and cannot answer for the console")
    end
    local x = tonumber(args and args[1])
    local y = tonumber(args and args[2])
    local z = tonumber(args and args[3])
    if x == nil or y == nil or z == nil then
        return reply(source, raw, "usage: br.tp <x> <y> <z>")
    end
    local record = K.ensure(id)
    if record == nil then return reply(source, raw, "br.tp: not enrolled") end
    local bucket = (record.state == "staging") and K.stagingBucket() or K.matchBucket()
    local ok, why = K.placeAt(id, { x = x, y = y, z = z }, bucket, {
        reason = "lua:br.tp",
        graceMs = 3000,
    })
    if not ok then return reply(source, raw, "br.tp refused: " .. tostring(why)) end
    reply(source, raw, ("br.tp -> %.1f,%.1f,%.1f (bucket %s)"):format(x, y, z, tostring(bucket)))
end, true)

RegisterCommand("br.beside", function(source, args, raw)
    local healer = K.ensure(tonumber(args and args[1]) or source)
    local downed = tonumber(args and args[2])
    if healer == nil or downed == nil then
        return reply(source, raw, "usage: br.beside <healerId> <downedId>")
    end
    local record = K.players[downed]
    local body = record ~= nil and record.bodyPosition or nil
    if body == nil then return reply(source, raw, ("player %d has no body"):format(downed)) end

    -- Toward the map centre, so the healer lands on the inside of the boundary
    -- the body is lying beyond.
    local grid = K.map and K.map.grid or nil
    local cx = grid and (grid.origin.x + (grid.cols * grid.blockMetres * 0.5)) or body.x
    local cy = grid and (grid.origin.y + (grid.rows * grid.blockMetres * 0.5)) or body.y
    local dx, dy = cx - body.x, cy - body.y
    local length = math.sqrt((dx * dx) + (dy * dy))
    local reach = (Config and Config.squads and Config.squads.reviveReachMetres) or 2.5
    local step = reach * 0.6
    if length > 0.01 then dx, dy = (dx / length) * step, (dy / length) * step else dx, dy = step, 0 end

    local ok, why = K.placeAt(healer.id,
        { x = body.x + dx, y = body.y + dy, z = body.z }, K.matchBucket(), {})
    reply(source, raw, ("beside %d: placed %s at %.1f,%.1f%s"):format(
        downed, tostring(ok), body.x + dx, body.y + dy,
        why ~= nil and (" (" .. tostring(why) .. ")") or ""))
end, true)

-- br.revive <healerId> <downedId> -- OPERATOR, and a test entry only.
--
-- It calls the same `S.beginRevive` a client's hold calls, so it exercises the
-- whole mechanism: the squad check, the reach re-derived on the server from the
-- healer's own replicated position, the hold timer in the tick, and the
-- platform revive at reduced health with an empty weapon list.
--
-- It exists because the hold itself lives in the head-up display, and proving a
-- revive between two players should not require the interface to be up. It is
-- RESTRICTED, so it needs an ACL principal that no ordinary player has.
RegisterCommand("br.revive", function(source, args, raw)
    local healer, downed = tonumber(args[1]), tonumber(args[2])
    if healer == nil or downed == nil then
        return reply(source, raw, "usage: br.revive <healerId> <downedId>")
    end
    local ok, why = K.squads.beginRevive(healer, downed)
    reply(source, raw, ("revive %d -> %d: %s %s"):format(healer, downed, tostring(ok), tostring(why)))
end, true)

-- br.loot.here [tierKey] [count] [playerId] -- seed real mode drops AT a player.
--
-- It exists because the CONTAINER under a drop had never been seen. Containers
-- are attached by `L.spawnOne`, which only ever runs from `L.seed` during a
-- live match at surveyed map coordinates -- so verifying that a crate actually
-- renders meant running a whole match and walking to a cluster. This calls the
-- same `spawnOne`, and therefore the same container path, at the operator's
-- feet: what appears here is exactly what appears in a match.
--
-- Operator-only, like every br.* verb, and it seeds into the caller's own
-- bucket so it can never litter a running match from staging.
-- br.loot.take [playerId] -- OPERATOR, and a TEST ENTRY only.
--
-- Opens the crate nearest that player, through `L.openCrate` -- the same
-- function the player's own key press reaches through `cordon:loot:open`. It is
-- deliberately not a shortcut: the phase gate, the reach check, the
-- claim-before-grant and the publish all run exactly as they do for a player.
--
-- It exists because the prompt's ACTIVATION cannot be driven from the agent
-- test loop. `client/src/api/Interactions.hpp` binds a prompt to a game ACTION
-- (Interact/Talk/Open/Loot), not to a keyboard key -- the "E" on the badge is a
-- label -- so a synthetic key press can never fire it, and the whole loot chain
-- was stuck at "the prompt renders and we cannot prove what happens next".
-- This closes everything from the take onwards; what it deliberately does NOT
-- prove is the vanilla interaction binding, which is a platform concern and has
-- to be checked by a person pressing the key.
RegisterCommand("br.loot.take", function(source, args, raw)
    if K.loot == nil or type(K.loot.openCrate) ~= "function" then
        return reply(source, raw, "loot module unavailable")
    end
    local record = K.ensure(tonumber(args and args[1]) or source)
    if record == nil then return reply(source, raw, "player only (or pass a playerId)") end

    local propId, distance = K.loot.nearestCrate(record)
    if propId == nil then
        return reply(source, raw, ("no crate anywhere for player %d"):format(record.id))
    end

    local ok, why = K.loot.openCrate(record, propId)
    reply(source, raw, ("crate %s at %.1fm -> %s%s"):format(
        tostring(propId), distance or -1, tostring(ok),
        why ~= nil and (" (" .. tostring(why) .. ")") or ""))
end, true)

RegisterCommand("br.loot.here", function(source, args, raw)
    if K.loot == nil or type(K.loot.spawnOne) ~= "function" then
        return reply(source, raw, "loot module unavailable")
    end
    local record = K.ensure(tonumber(args and args[3]) or source)
    if record == nil then return reply(source, raw, "player only (or pass a playerId)") end

    local wanted = tostring((args and args[1]) or "street")
    local count = math.max(1, math.min(tonumber(args and args[2]) or 3, 12))
    -- `kind=<k>` ANYWHERE in the arguments forces every crate this call makes to
    -- carry that kind instead of rolling one. It exists for one reason: the
    -- automated check of the loot affordance has to assert on something, and the
    -- only channel a scenario can read is a BRIDGE command -- a server slash
    -- command's reply goes to the head-up display and comes back to the bridge
    -- as `server_command_sent` and nothing else. So the assertion has to be
    -- `char.state armed=yes`, and that is only honest if the crate is certain to
    -- hold a gun. A street crate is a weapon about one roll in five.
    local forcedKind = nil
    -- `at=<metres>` sets the ring radius, default 2.5. The automated check of
    -- the loot affordance needs it for the same reason it needs `kind=`: the
    -- card only draws inside 2.0 m, so a ring at 2.5 requires a step forward,
    -- and a step forward is exactly the part of a scenario that cannot be
    -- trusted. Measured 2026-09-03: the walk was blocked by geometry, moved the
    -- player 0.45 m instead of 1.1, left the nearest crate at 2.1 m, and twelve
    -- presses swept a full half-turn against a prompt that was never drawn --
    -- while `br.loot.take` reported `crate 1019 at 2.1m -> true` from the
    -- server's own view. Seeding inside the threshold removes the walk from the
    -- thing under test, which is the ACTIVATION.
    local radius = 2.5
    for _, token in ipairs(args or {}) do
        local named = tostring(token):match("^kind=(%w+)$")
        if named ~= nil then forcedKind = named end
        local metres = tonumber(tostring(token):match("^at=([%d%.]+)$"))
        if metres ~= nil then radius = math.max(0.5, math.min(metres, 12.0)) end
    end
    local tiers = (Config and Config.loot and Config.loot.tiers) or {}
    local tier = nil
    for _, candidate in ipairs(tiers) do
        if tostring(candidate.key) == wanted then tier = candidate break end
    end
    if tier == nil then
        local keys = {}
        for _, candidate in ipairs(tiers) do keys[#keys + 1] = tostring(candidate.key) end
        return reply(source, raw, ("unknown tier %q; have: %s"):format(wanted, table.concat(keys, " ")))
    end

    local position = K.position(record.id)
    if position == nil then return reply(source, raw, "no position for that player") end

    -- Spread them so the crates do not intersect each other; the interaction
    -- ray needs a clear line to each item sitting on its own lid.
    local made, failed = 0, 0
    for index = 1, count do
        local angle = (index / count) * math.pi * 2.0
        local spot = {
            x = position.x + math.cos(angle) * radius,
            y = position.y + math.sin(angle) * radius,
            z = position.z,
        }
        local ok, dropId = pcall(K.loot.spawnOne, tier, spot, position.bucket, forcedKind)
        if ok and dropId ~= nil then made = made + 1 else failed = failed + 1 end
    end
    -- AND THEN TELL THE CLIENTS, which this verb never did.
    --
    -- `spawnOne` registers the crate server-side and stops there. What lets a
    -- client draw a prompt on it is `L.publishCrates`, and until now it had
    -- exactly two callers: the match seed (match.lua) and a successful grant.
    -- So every crate this verb made was invisible to the mode's own prompt --
    -- `client/main.lua` builds its POIs from the `cordon:crates` table and was
    -- never told these existed.
    --
    -- That is the whole reason the loot prompt "never appeared", and why
    -- synthetic key presses looked like the culprit for days: there was no
    -- prompt on screen to activate, so every measurement of the key path was
    -- measuring an empty screen. Found 2026-09-03: four crates seeded at 2.5 m,
    -- `made=4 failed=0`, and not one ring drawn anywhere around the player.
    local published = false
    if type(K.loot.publishCrates) == "function" then
        published = pcall(K.loot.publishCrates)
    end

    -- REPORT THE CONTAINER STATE, not just the drop count. The first run of
    -- this verb answered `made=5 failed=0` while the client saw `props=0`, and
    -- nothing in the reply could tell "containers are switched off" from
    -- "containers were made and did not replicate". These two numbers do.
    local containers = (Config and Config.loot and Config.loot.containers) or {}
    local serverProps = 0
    if type(Open77) == "table" and type(Open77.props) == "table"
        and type(Open77.props.all) == "function" then
        local ok, all = pcall(Open77.props.all, K.matchBucket())
        if ok and type(all) == "table" then serverProps = #all end
    end
    reply(source, raw, ("seeded tier=%s kind=%s at=%.1fm made=%d failed=%d published=%s player=%d " ..
        "| containers.enabled=%s propsApi=%s serverPropsInBucket=%d bucket=%s"):format(
        tier.key, tostring(forcedKind or "rolled"), radius, made, failed, tostring(published), record.id,
        tostring(containers.enabled),
        (type(Open77) == "table" and type(Open77.props) == "table")
            and type(Open77.props.create) or "missing",
        serverProps, tostring(K.matchBucket())))
end, false)

RegisterCommand("br.map.check", function(source, _, raw)
    local map = K.map
    local lines = {}
    for _, item in ipairs(map.progress or {}) do
        local have = 0
        if item.key == "origin" then have = (map.grid and map.grid.origin) and 1 or 0
        elseif item.key == "ground" then have = (map.grid and map.grid.groundDefault) and 1 or 0
        elseif item.key == "staging" then have = (map.staging and map.staging.position) and 1 or 0
        else
            local list = map[item.key]
            if type(list) == "table" then have = #list end
        end
        lines[#lines + 1] = ("%s %d/%d"):format(item.key, have, item.need)
    end
    reply(source, raw, ("map=%s surveyed=%s provisional=%s | %s"):format(
        tostring(map.name), tostring(map.surveyed), tostring(K.mapProvisional()),
        table.concat(lines, "  ")))
end, true)

K.log("cordon loaded: /br.status /br.where /br.start /br.end /br.bots /br.map.check /br.revive")
