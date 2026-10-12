-- Bots: contestants that fill a match players did not fill.
--
-- ---------------------------------------------------------------------------
-- Optional backfill for an operator's test or small roster. Disabled by
-- default; no bots enter a match unless an operator enables the policy.
--
-- Everything about how a bot FIGHTS is inherited wholesale from
-- open77_deathmatch/server/bots.lua, and every line of that was paid for:
--
--   * THE ENGINE FIGHTS. A spawned hostile record runs full vanilla combat AI
--     on every client that streams it. That is not opt-in and cannot be
--     disabled from Lua. Any scripted damage layer on top is a SECOND combat
--     system on one body — the measured symptom was hits through walls with no
--     animation while other engagements looked normal. Never add one.
--   * THE OWNING CLIENT REPORTS THE HIT. Every client streaming a bot runs its
--     own copy of that bot's AI, so a witness report credits one burst once per
--     spectator. The shooter's client reports player->bot; the victim's reports
--     bot->player.
--   * THREE MUTUALLY HOSTILE GANGS, round-robined. One faction is one side, and
--     one side does not fight: a single-gang roster gives the engine's attitude
--     matrix nothing to resolve and the bots ignore each other.
--   * civilian_female_relaxed_01 IS PERMANENTLY EXCLUDED. It resolves to
--     Character.Panam, tagged Invulnerable, and while it was in the deathmatch
--     roster half of every round-robin was unshootable.
--   * NEGATIVE PARTICIPANT IDS, so scoring and standings need no special case —
--     but five player bindings RAISE on a non-positive id, which is why the
--     kernel's guarded reads exist and why nothing here calls them directly.
-- ---------------------------------------------------------------------------

local K = Cordon
K.bots = {}
local B = K.bots

local bots = {}           -- [participantId] = { npcId, squad, template, alive, lastCell }
local aliases = {}        -- [npcId as string] = participantId
local nextParticipant = -1
local spawnQueue = {}
local requestedBots = 0 -- explicit additions, consumed at the next deployment
local lastSpawnMs = 0
local settleUntilMs = 0

local function cfg()
    return (Config and Config.bots) or {}
end

function B.count()
    local n = 0
    for _ in pairs(bots) do n = n + 1 end
    return n
end

--- A bot's shots arrive under its uint64 NPC id, which `tonumber` corrupts past
--- 2^53. Every attacker id from an NPC path goes through here first.
function B.attackerId(raw)
    local key = tostring(raw)
    if aliases[key] ~= nil then return aliases[key] end
    return tonumber(raw)
end

function B.get(npcId)
    local participant = aliases[tostring(npcId)]
    return participant and bots[participant], participant
end

-- ---------------------------------------------------------------------------
-- FILL POLICY. Computed once, at the end of staging, so the drop map shows a
-- real headcount — and never mid-match, because a battle royale that adds
-- contestants after the drop is not one.
-- ---------------------------------------------------------------------------
function B.wanted(humanCount)
    local mode = tostring(K.tune("botFill", cfg().botFill or "off"))
    if mode == "off" then return 0 end
    local capacity = (Config and Config.match and Config.match.maxPlayers) or 64
    if mode == "always" then return math.max(0, capacity - humanCount) end
    -- "threshold": fill to `botFillTarget` only when humans are below the floor.
    local floor = tonumber(K.tune("botFillFloor", cfg().botFillFloor or 24)) or 24
    if humanCount >= floor then return 0 end
    local target = tonumber(K.tune("botFillTarget", cfg().botFillTarget or 40)) or 40
    return math.max(0, math.min(target, capacity) - humanCount)
end

function B.fill(match)
    local humans = #K.humans()
    local capacity = (Config and Config.match and Config.match.maxPlayers) or 64
    local wanted = math.min(math.max(0, capacity - humans), B.wanted(humans) + requestedBots)
    requestedBots = 0
    if wanted <= 0 then
        K.log(("bots: fill not required (humans=%d)"):format(humans))
        return 0
    end
    K.log(("bots: filling %d slots (humans=%d)"):format(wanted, humans))
    -- The taint is set the moment the FIRST bot is requested, not when one
    -- spawns: a match that asked for bots is unrateable even if every spawn
    -- were refused, because the fill changed how it was played.
    K.match.taint("bots joined the match")
    for _ = 1, wanted do
        spawnQueue[#spawnQueue + 1] = true
    end
    settleUntilMs = K.nowMs() + (cfg().settleMs or 5000)
    return wanted
end

-- ---------------------------------------------------------------------------
-- SPAWNING IS PACED AND GATED. Forty bodies is six times what the arena ever
-- created at once; the gate is not optional at this scale.
-- ---------------------------------------------------------------------------
local function templateFor(index)
    local roster = cfg().templates or {
        "hostile_female_ranged_lab", "gang_valentinos_ranged_01", "gang_tygerclaws_ranged_01",
    }
    if #roster == 0 then return nil end
    return roster[((index - 1) % #roster) + 1]
end

function B.drainQueue()
    if #spawnQueue == 0 then return end
    local now = K.nowMs()
    if now < settleUntilMs then return end
    if now - lastSpawnMs < (cfg().spawnSpacingMs or 400) then return end
    table.remove(spawnQueue, 1)
    lastSpawnMs = now
    B.spawnOne()
end

function B.spawnOne()
    local match = K.match.current()
    local participant = nextParticipant
    nextParticipant = nextParticipant - 1

    local mark = B.chooseSpawn()
    if mark == nil then
        K.warn("bots: no landing zone to spawn at")
        return nil
    end
    local template = templateFor(B.count() + 1)
    local npcId, refusal = Open77.npcs.create({
        template = template,
        position = { x = mark.x, y = mark.y, z = mark.z + 0.2 },
        yaw = math.random() * 360.0,
        bucket = K.matchBucket(),
        -- `aiMode` reaches no engine call at all: it rides the replica and gates
        -- server-side task scheduling, nothing more. A spawned hostile record
        -- has full vanilla combat AI on every client either way. It is set for
        -- the server's own bookkeeping, not because it changes the fight.
        aiMode = Open77.npcs.ai and Open77.npcs.ai.native or nil,
        damagePolicy = Open77.npcs.damage and Open77.npcs.damage.mortal or nil,
        -- server/npc-combat.lua prices every player hit (`cordon:npcHit`). Stated
        -- although it is the default, so platform pricing never counts a shot twice.
        behavior = { hitPricing = "resource" },
        health = 100.0, maxHealth = 100.0,
        streamingRadius = 180.0, streamingHysteresis = 40.0,
        persistent = false,
    })
    if npcId == nil then
        K.warn("bots: create refused: " .. tostring(refusal))
        return nil
    end

    bots[participant] = {
        npcId = npcId, template = template, alive = true,
        squad = nil, lastCell = nil, position = { x = mark.x, y = mark.y, z = mark.z },
    }
    -- Bound TWICE: the negative participant id the scoreboard uses, and the
    -- uint64 npc id the damage paths arrive under. Sharing one table made every
    -- bot count as two in the deathmatch.
    aliases[tostring(npcId)] = participant

    local record = K.ensure(participant)
    if record ~= nil then
        record.state = "alive"
        record.botPosition = { x = mark.x, y = mark.y, z = mark.z }
        record.name = "BOT-" .. tostring(-participant)
        B.assignSquad(record, match)
    end
    return participant
end

function B.chooseSpawn()
    local landings = K.map and K.map.landings or {}
    local usable = {}
    for _, zone in ipairs(landings) do
        if zone.position ~= nil then usable[#usable + 1] = zone.position end
    end
    if #usable == 0 then return nil end
    local base = usable[math.random(1, #usable)]
    local angle = math.random() * math.pi * 2
    local distance = math.sqrt(math.random()) * 25.0
    return { x = base.x + math.cos(angle) * distance, y = base.y + math.sin(angle) * distance, z = base.z }
end

--- A bot fills an empty seat in a human squad first, so a short squad becomes a
--- full one; only then does it start a bot-only squad.
function B.assignSquad(record, match)
    local size = K.match.squadSize()
    local target = nil
    for _, squad in pairs(match.squads) do
        if #squad.members < size then
            if target == nil or #squad.members > #target.members then target = squad end
        end
    end
    if target == nil then
        target = { id = match.nextSquadId, members = {}, alive = 0, placement = nil, bot = true }
        match.squads[target.id] = target
        match.nextSquadId = match.nextSquadId + 1
    end
    target.members[#target.members + 1] = record.id
    record.squad = target.id
end

-- ---------------------------------------------------------------------------
-- THE CORDON APPLIES TO BOTS. They bleed and they die like anybody else — a
-- cordon that only closes on players is a cordon the bots win.
--
-- Movement is ONE `moveTo` PER CLOSURE, never a stream. Re-issuing movement on
-- a tick cancels whatever the behaviour tree had running, and a body told twice
-- a second where to walk cannot take cover, strafe or hold a firing line.
-- ---------------------------------------------------------------------------
function B.onCordonClosed()
    local C = K.cordon
    for participant, bot in pairs(bots) do
        if bot.alive then
            local record = K.players[participant]
            local position = record and record.botPosition or bot.position
            if position ~= nil and C.evaluate(record) == false then
                local safe = C.nearestOpen(position)
                if safe ~= nil then
                    pcall(function()
                        Open77.npcs.tasks.moveTo(bot.npcId, { x = safe.x, y = safe.y, z = position.z },
                            { speed = "run" })
                    end)
                end
            end
        end
    end
end

local nextRefreshMs = 0

-- The bot refresh runs at 1 Hz, NOT on the mode's 4 Hz tick.
--
-- Measured 2026-09-02: with 28 bots and 12 sessions, refreshing every tick
-- marshalled 28 NPC snapshots out of C# four times a second and the server
-- logged "tick fell behind" continuously before dying. Nothing about
-- containment needs 4 Hz for a body that walks: a bot's position one second old
-- is a bot's position, and the cordon's own hold rule already refuses to judge
-- a single sample.
function B.tick()
    B.drainQueue()
    local now = K.nowMs()
    if now < nextRefreshMs then return end
    nextRefreshMs = now + 1000
    -- Iterate the PLATFORM's registry, never this VM's table: a hot reload
    -- empties the table while every body lives on.
    for _, npc in ipairs(Open77.npcs.all(K.matchBucket()) or {}) do
        local participant = aliases[tostring(npc.id)]
        if participant ~= nil then
            local record = K.players[participant]
            local bot = bots[participant]
            -- THE SNAPSHOT HAS NO `position` TABLE, and reading one cost this
            -- mode every bot position it ever took.
            --
            -- `PushNpc` (LuaResourceRuntime.cs:1875-1889) sets `x`, `y`, `z` and
            -- `yaw` as TOP-LEVEL fields and never calls `PushVector`, unlike the
            -- effect and player snapshots beside it -- so the old guard
            -- `npc.position ~= nil` was false on every row of every tick and
            -- `record.botPosition` never moved off the spawn point. Three things
            -- read it and all three were wrong for the whole match: the cordon
            -- judged a bot at the coordinates it landed on, `B.onCordonClosed`
            -- walked it back towards a boundary computed from those, and the
            -- head-shot test in the hit bridge subtracted a stale
            -- `bot.position.z`, so no shot could ever read as a head shot.
            local x, y, z = tonumber(npc.x), tonumber(npc.y), tonumber(npc.z)
            if x ~= nil and y ~= nil and z ~= nil then
                if record ~= nil then
                    record.botPosition = { x = x, y = y, z = z, bucket = K.matchBucket() }
                end
                if bot ~= nil then bot.position = { x = x, y = y, z = z } end
            end
            -- A per-tick health backstop, because onNpcDied has been seen to
            -- go missing and a bot that is dead in the engine but alive on the
            -- scoreboard stops a match ending.
            if record ~= nil and record.state == "alive" and npc.health ~= nil and npc.health <= 0 then
                -- The engine names no cause on this path, so the shooter is
                -- resolved exactly as `onNpcDied` resolves it. A backstop that
                -- credits nobody turns a real kill into an anonymous one.
                B.onBotDied(participant, "player")
            end
        end
    end
end

--- The cordon bleeds bots through the NPC damage path rather than the player
--- one, because they are NPCs; everything else about the elimination is the
--- same code the players use.
---
--- Applied at 1 Hz in one larger bite rather than at the cordon's 4 Hz, for the
--- same reason the refresh is throttled: `applyDamage` is a call across the
--- Lua/C# boundary per bot per tick, and forty bots at 4 Hz is a hundred and
--- sixty of them a second for damage nobody can perceive at that resolution.
local nextBleedMs = 0

function B.applyCordonDamage(perSecond)
    local now = K.nowMs()
    if now < nextBleedMs then return end
    local elapsed = nextBleedMs == 0 and 1.0 or math.min(2.0, (now - (nextBleedMs - 1000)) / 1000.0)
    nextBleedMs = now + 1000
    local amount = perSecond * elapsed
    if amount <= 0 then return end
    for participant, bot in pairs(bots) do
        if bot.alive then
            local record = K.players[participant]
            if record ~= nil and K.cordon.evaluate(record) == false then
                -- The source is a free-form string THIS resource chooses and
                -- gets handed back by `onNpcDied`; it named `0`, which
                -- `tonumber` turned into the player id zero and which then beat
                -- the real attribution to the punch. Name it.
                pcall(Open77.npcs.applyDamage, bot.npcId, amount, "cordon", "environment")
            end
        end
    end
end

function B.onBotDied(participant, cause)
    local bot = bots[participant]
    if bot == nil or not bot.alive then return end
    bot.alive = false
    local record = K.players[participant]
    if record == nil then return end
    local reason = tostring(cause or "cordon")
    K.match.onDeath(record, B.killerOf(participant, reason), reason)
end

-- ---------------------------------------------------------------------------
-- SHOOTING A BOT. The missing half of the combat loop.
--
-- `client/main.lua` has always reported engine hits on NPCs with
-- `cordon:npcHit`, and NOTHING ON THE SERVER LISTENED. So a player could empty
-- a magazine into a bot and nothing happened anywhere: no damage was applied,
-- the NPC never reached zero health, `onNpcDied` never fired, the bot was never
-- marked eliminated, and the HUD's ALIVE count sat still. Measured 2026-09-02
-- across a whole match -- `onNpcDied` fired ZERO times while the owner was
-- killing bots, and the only two `onDeath` lines in the log were humans. The
-- owner reported it twice.
--
-- FAIL-CLOSED ON THE WEAPON, exactly like the player arbiter: a hit whose
-- weapon this mode has not seen verified is dropped rather than trusted. A
-- fault must mean "cannot shoot", never "free damage" -- the client is the one
-- reporting both the target and the amount here, so it is the one place a
-- compromised client could invent a kill.
-- ---------------------------------------------------------------------------

--- [participantId] = { id = playerId, atMs }. Written by the hit bridge below,
--- read by every elimination path, and TIME-BOUNDED: a bot shot once and then
--- left to bleed out in the cordon four minutes later is not that shooter's
--- kill, and an unbounded table would say it was.
local lastAttacker = {}
local ATTRIBUTION_WINDOW_MS = 10000

function B.noteHit(npcId, attackerId)
    local participant = aliases[tostring(npcId)]
    if participant ~= nil then
        lastAttacker[participant] = { id = attackerId, atMs = K.nowMs() }
    end
end

--- Who gets the kill for `participant`, given the cause the engine reported.
---
--- THE HIT BRIDGE IS THE AUTHORITY AND THE ENGINE IS THE FALLBACK, which is the
--- reverse of what this file used to do -- and that reversal is the whole of the
--- KILLS-stuck-at-zero symptom. `onNpcDied` hands back the `source` string that
--- was passed to `applyDamage`, and both call sites in this file passed the
--- NUMBER 0. `B.attackerId("0")` finds no alias, falls through to
--- `tonumber("0")` and returns 0 -- a truthy Lua value -- so the `lastAttacker`
--- fallback was never once reached and `M.onDeath` was handed killer id 0,
--- which resolves to no roster row and credits nobody. Measured 2026-09-02.
function B.killerOf(participant, cause)
    local recent = lastAttacker[participant]
    lastAttacker[participant] = nil
    -- A cordon death is nobody's kill, however recently the victim was shot.
    if cause ~= "environment" and recent ~= nil
        and (K.nowMs() - (recent.atMs or 0)) <= ATTRIBUTION_WINDOW_MS then
        return recent.id
    end
    return nil
end

AddEventHandler("onNpcDied", function(npcId, source_, cause)
    local participant = aliases[tostring(npcId)]
    if participant == nil then return end
    local bot = bots[participant]
    if bot == nil then return end
    bot.alive = false
    local record = K.players[participant]
    if record == nil then return end
    local reason = tostring(cause or "unknown")
    local killer = B.killerOf(participant, reason)
    if killer == nil then
        -- The engine's own naming, last, and only when it names something that
        -- resolves. `B.attackerId` falls through to `tonumber` for anything it
        -- holds no alias for, so "cordon" and "script" become nil while "0"
        -- becomes zero -- and zero is not a roster id and must never be passed
        -- off as one.
        local named = source_ ~= nil and B.attackerId(source_) or nil
        if type(named) == "number" and named ~= 0 then killer = named end
    end
    K.match.onDeath(record, killer, reason)
end)

-- ---------------------------------------------------------------------------
-- CLEARING, AND WHY IT IS NOT RE-ADOPTION.
--
-- `Open77.npcs.all()` IS ALREADY OWNERSHIP-SCOPED. The binding passes this
-- resource's manifest name down to `NpcAuthorityService.Snapshot`, which filters
-- on `Owns(npc, resource)` (NpcAuthorityService.cs:196) -- so every row it
-- returns was created by open77_cordon, and this file is the only thing in the
-- resource that creates one. There is therefore no need to consult `aliases` to
-- learn whether a body is ours: the platform has already answered.
--
-- That matters because the old filter did consult it, and `aliases` lives in
-- THIS VM. A hot reload hands the resource a fresh Lua state while every body it
-- spawned lives on in the world, so after one reload the filter matched nothing
-- and `B.clear()` removed NOTHING. Measured 2026-09-02: roughly twenty reloads
-- in one session left twenty generations of unowned bots standing in Pacifica,
-- and the newest generation's `cordon:npcHit` reports came back
-- `not_our_npc 25769803800` -- the body the owner was shooting belonged to a VM
-- that no longer existed.
--
-- RE-ADOPTING those bodies was considered and rejected. A re-adopted bot cannot
-- be scored, and an unscoreable contestant is worse than no contestant:
--
--   * it has no participant id. The negative allocator restarts at -1 in every
--     VM, so any id invented for an orphan collides with the ids the next fill
--     is about to hand out;
--   * it has no squad, and `M.remainingSquads()` -- the win condition -- reads
--     squad membership. A squadless "alive" row inflates `M.aliveCount()` and
--     can never be eliminated out of the match, so the match cannot end;
--   * the match it belonged to is gone. `current` is a fresh table sitting at
--     `phase = "staging"`, so its placement, its standings row and its taint
--     went with the old VM.
--
-- Clearing is honest and costs one staging countdown. The bodies go, the mode
-- fills again at the next deploy, and every bot in the world then belongs to the
-- generation that is scoring it.
--
-- The sweep is deliberately NOT bucket-scoped: a body that ended up in an
-- unexpected bucket is exactly the body nothing else will ever collect.
-- ---------------------------------------------------------------------------
function B.clear(sweepPreviousGeneration)
    local removed = 0
    local ok, all = pcall(Open77.npcs.all)
    for _, npc in ipairs((ok and all) or {}) do
        if (sweepPreviousGeneration or aliases[tostring(npc.id)] ~= nil)
            and Open77.npcs.remove(npc.id) then removed = removed + 1 end
    end
    for participant in pairs(bots) do K.forget(participant) end
    bots = {}
    aliases = {}
    spawnQueue = {}
    nextParticipant = -1
    lastAttacker = {}
    return removed
end

RegisterCommand("br.bots", function(source, args, raw)
    local verb = (args[1] or "status"):lower()
    local text
    local capacity = (Config and Config.match and Config.match.maxPlayers) or 64
    if verb == "clear" and args[2] == nil then
        requestedBots = 0
        text = ("bots: cleared %d; pending additions cancelled"):format(B.clear())
    elseif verb == "off" and args[2] == nil then
        local ok, accepted = pcall(Open77.tunables.set, "botFill", "off")
        if ok and accepted ~= false then
            requestedBots = 0
            text = "bots: automatic fill off; pending additions cancelled; existing contestants unchanged (use clear to remove)"
        else
            text = "bots: could not disable automatic fill"
        end
    elseif verb == "add" then
        local n = tonumber(args[2])
        if n == nil or n ~= math.floor(n) or n < 1 or n > capacity or args[3] ~= nil then
            text = ("usage: /br.bots add <integer 1..%d>"):format(capacity)
        elseif requestedBots + n > capacity then
            text = ("bots: refused; at most %d pending additions"):format(capacity)
        else
            requestedBots = requestedBots + n
            text = ("bots: %d requested for NEXT deployment; clipped to free slots at deployment; no current-match spawn"):format(requestedBots)
        end
    elseif verb == "status" and args[2] == nil then
        text = ("bots: %d registered, %d spawning, %d requested next deployment, fill=%s target=%s floor=%s"):format(
            B.count(), #spawnQueue, requestedBots, tostring(K.tune("botFill", "off")),
            tostring(K.tune("botFillTarget", 40)), tostring(K.tune("botFillFloor", 24)))
    else
        text = "usage: /br.bots [status|add <count>|off|clear]"
    end
    K.log(text)
    if source ~= nil and source > 0 then
        TriggerClientEvent("open77:command:result", source, raw or "", true, text)
    end
end, true)

-- ---------------------------------------------------------------------------
-- ONE SWEEP AT LOAD, the other half of the reload story above.
--
-- `M.toStaging` is the only caller of `B.clear`, and a reload does NOT pass
-- through it: `current.phase` is INITIALISED to "staging" rather than
-- transitioned into it, so `M.tick` simply arms a countdown and walks on to
-- deploy. Nothing ever collected the previous generation. Load is the one moment
-- at which "this VM owns no bots" is true by construction, so removing
-- everything the platform says we own is exactly right here and nowhere else.
-- ---------------------------------------------------------------------------
do
    local swept, removed = pcall(B.clear, true)
    if swept and (removed or 0) > 0 then
        K.log(("bots: swept %d body/bodies left behind by a previous load"):format(removed))
    end
end

K.log("bots ready")
