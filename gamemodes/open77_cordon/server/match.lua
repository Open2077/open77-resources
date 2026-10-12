-- The match state machine.
--
--   staging -> deploy -> live -> extraction -> resolved -> (back to staging)
--
-- One server runs ONE match. There is no instance registry here and that is a
-- decision, not an omission: combat policy (friendly fire, damage multipliers)
-- is host-global, so two matches on one server would share it. A second match
-- is a second server.
--
-- Every transition goes through `transition()`, which checks an explicit table
-- of allowed edges and LOGS A REFUSAL rather than corrupting state. An invalid
-- transition is far more useful as a log line than as a silently wrong phase.

local K = Cordon
K.match = {}
local M = K.match

local ALLOWED = {
    staging    = { deploy = true, staging = true },
    deploy     = { live = true, staging = true },
    live       = { extraction = true, resolved = true, staging = true },
    extraction = { resolved = true, staging = true },
    resolved   = { staging = true },
}

local current = {
    phase = "staging",
    id = nil,
    number = 0,
    startedAtMs = nil,
    phaseEndsAtMs = nil,
    format = "squad",
    squads = {},        -- [squadId] = { id, members = {playerId,...}, alive = n, placement = nil }
    nextSquadId = 1,
    standings = {},     -- resolved placements, worst-first as they are eliminated
    aliveCount = 0,
    tainted = false,    -- any bot took part -> never rated
    winner = nil,
}

function M.current() return current end

-- ---------------------------------------------------------------------------
-- THE KILL FEED.
--
-- Asked for by the owner, 2026-09-02: "y'a pas d'historique de qui a tuer qui
-- fin je le vois pas en tout cas ca serait cool a ajouter en live pour tout les
-- joueurs". The interface half has existed the whole time and has never had
-- anything to draw -- open77_cordon_hud/web/match.js reads `payload.feed` and
-- renders three kinds -- while the server's only elimination signal was
-- `TriggerEvent("cordon:eliminated", ...)`, which walks one VM and reaches no
-- client at all.
--
-- A LIST IN THE STATE PUSH, NOT AN EDGE EVENT, because that is the contract the
-- page documents and it is the right one: a client that joins mid-match, or one
-- that missed a push, still sees the last few seconds of the match rather than
-- an empty column, and the page works out for itself which rows are new.
--
-- NEWEST FIRST -- `feed[1]` is the most recent -- which is what match.js walks
-- in reverse so that two events in one push land in the order they happened.
local FEED_WINDOW_MS = 25000
local FEED_MAX = 12

local feed = {}

local function feedPush(entry)
    entry.atMs = K.nowMs()
    table.insert(feed, 1, entry)
    -- The page caps its own column at six; this cap is the server's, and it is
    -- the one that bounds the payload every push carries to every client.
    while #feed > FEED_MAX do table.remove(feed) end
end

--- What the state push sends. The window is the server's decision, as the page
--- says it is: an entry older than it simply stops being sent and the row
--- retires itself on the next push.
function M.feed()
    local now, out = K.nowMs(), {}
    for _, entry in ipairs(feed) do
        if now - entry.atMs <= FEED_WINDOW_MS then out[#out + 1] = entry end
    end
    return out
end

function M.clearFeed() feed = {} end

-- ---------------------------------------------------------------------------
-- PLACEMENTS THAT WERE REFUSED, kept so the tick can ask again.
--
-- `K.placeAt` returns `ok, reason` and every caller in this file used to throw
-- both away. A refusal is not exotic — it is exactly what a player caught in a
-- life transition produces (`transition_in_progress:revivepending`,
-- `respawnpending`), and a respawn can be refused outright — and the cost of
-- ignoring it is the worst failure this mode has:
--
--   the record says "staging", the body is still a corpse in the match bucket,
--   the local client is still holding the ragdoll `ForceRagdoll` put it in, and
--   NOTHING WILL EVER ASK AGAIN.
--
-- That is the "camera never comes back" report, exactly. The camera comes back
-- when the body is respawned, because a respawn is DisableRagdoll +
-- ResurrectLocal + Teleport on the client (client/src/network/LifeReplication.cpp,
-- `IssueLocalRecovery`); a placement that was refused and forgotten is a camera
-- that is never asked to come back.
--
-- So every placement this file issues is now checked, and a refusal is retried
-- on the tick until it takes. Two entries, both keyed by player id:
--   * `restaging` — the end-of-match sweep back to the lobby;
--   * `record.spectateAttempts` — the elimination sweep, which retries on its
--     own because the record stays `dead` until it succeeds.
-- ---------------------------------------------------------------------------
local restaging = {}     -- [playerId] = { attempts = n, nextAtMs = t }
local deployments = nil  -- One generation's placement transactions, before combat opens.
local RESTAGE_ATTEMPTS = 40      -- ~10 s at the 250 ms tick
local RESTAGE_RETRY_MS = 250

--- The alive count is DERIVED, never maintained.
---
--- It used to be a counter incremented in three places — the deploy placement
--- loop, the bot squad assignment, and the revive — and the moment bots joined
--- it read 74 for a match of 40. A counter that several writers touch is a
--- counter that is wrong; counting the roster is O(players) on a table that is
--- at most 64 entries, which is nothing against being right.
function M.aliveCount()
    local n = 0
    for _, record in pairs(K.players) do
        if record.state == "alive" then n = n + 1 end
    end
    return n
end
function M.phase() return current.phase end
function M.isLive() return current.phase == "live" or current.phase == "extraction" end

local function cfg()
    return (Config and Config.match) or {}
end

-- Read through the tunable first so an operator retuning a running server is
-- obeyed, then the config default, then the caller's fallback.
local function seconds(key, fallback)
    local tuned = K.tune(key, nil)
    if type(tuned) == "number" then return tuned end
    local value = cfg()[key]
    if type(value) == "number" then return value end
    return fallback
end

function M.transition(target, reason)
    local from = current.phase
    if from == target then return true end
    if ALLOWED[from] == nil or ALLOWED[from][target] ~= true then
        K.warn(("refused transition %s -> %s (%s)"):format(from, target, tostring(reason)))
        return false
    end
    current.phase = target
    K.log(("match %s: %s -> %s (%s)"):format(tostring(current.id), from, target, tostring(reason)))
    TriggerEvent("cordon:phase", target, from, reason)
    return true
end

-- ---------------------------------------------------------------------------
-- STAGING. Players wait here between matches, in their own bucket, invulnerable
-- and unarmed. This is also where a player who joins mid-match lands: the mode
-- never drops somebody into a fight already in progress, because a battle royale
-- with a late joiner is not one.
-- ---------------------------------------------------------------------------
function M.toStaging(reason)
    local preplacementAbort = current.phase == "deploy" and deployments == nil
    if not M.transition("staging", reason or "return") then return end
    -- Clear the deadline BEFORE re-arming. `armCountdown` deliberately refuses
    -- to re-arm a clock that is already running, and the one left behind by the
    -- result card has already elapsed — so without this the next staging opens
    -- with a countdown in the past and the tick drops straight back into deploy.
    current.phaseEndsAtMs = nil
    -- RESOLVE THE FORMAT FOR STAGING TOO, not only at match creation.
    --
    -- `current.format` was seeded from the table literal at the top of this file
    -- ("squad") and only replaced in `M.begin`. Everything that reads the format
    -- BEFORE a match exists -- `br.status`, and the staging card's FORMAT field
    -- in open77_cordon_hud -- therefore reported "SQUAD" no matter what the
    -- `format` tunable said, and only told the truth once the match had already
    -- started. Measured 2026-09-03: the tunable was set to solo, the lobby still
    -- advertised SQUAD, and the value was correct all along.
    --
    -- Re-resolving here is also what makes the tunable feel live: staging is
    -- exactly the moment an operator changes it for the next match.
    current.format = M.resolveFormat()
    current.squads = {}
    current.nextSquadId = 1
    current.standings = {}
    current.winner = nil
    current.initialSides, current.resolvingVictory = 0, false
    current.tainted = false
    -- A new match starts with an empty column; the previous match's last
    -- eliminations are not this one's.
    M.clearFeed()
    -- Whatever the last sweep could not place is superseded by this one.
    restaging = {}
    deployments = nil
    K.cordon.stop()
    if K.loot ~= nil then pcall(K.loot.clear) end
    if K.bots ~= nil then pcall(K.bots.clear) end
    if K.squads ~= nil then pcall(K.squads.reset) end

    local staging = K.map and K.map.staging or nil
    for _, record in ipairs(K.humans()) do
        -- Deploy is a planning phase: nobody has been moved yet. An aborted
        -- start must not kill/respawn a living player still moving in the
        -- lobby. Require current placement evidence; uncertain or displaced
        -- bodies still take the normal checked placement/retry path.
        local keepLobbyBody = false
        if preplacementAbort and record.state == "staging" and record.drop == nil then
            local position = K.position(record.id)
            local life = K.lifePhase(record.id)
            keepLobbyBody = position ~= nil and position.bucket == K.stagingBucket()
                and (life == "alive" or life == "recovering")
        end
        -- A match can end while somebody is still under a chute — the last
        -- squad can be wiped before the last dropper touches down. Close the
        -- descent before the staging placement, or that player keeps the
        -- authoritative shield and the client keeps a chute it will never be
        -- told to fold.
        if record.drop ~= nil then K.endDrop(record.id, "match_reset") end
        record.state = "staging"
        record.squad = nil
        record.placement = nil
        record.kills = 0
        record.plates = 0
        record.heals = 0
        -- THE ELIMINATION BOOKKEEPING, cleared with everything else. A record
        -- that carried `deathAtMs`, a revive window or a body position into the
        -- next match would make `resultFor` measure the wrong life and
        -- `tickEliminations` sweep somebody who is standing in the lobby.
        record.deathAtMs = nil
        record.reviveUntilMs = nil
        if Open77.players.setDownedDamageable then Open77.players.setDownedDamageable(record.id, false) end
        record.selfReadyAtMs, record.downedFinished = nil, nil
        record.downingCount = 0
        record.downedKiller, record.downedCause, record.deathLootDropped = nil, nil, nil
        record.bodyPosition = nil
        record.eliminatedAtMs = nil
        record.spectateAttempts = nil
        -- Clearing the ledger is not the same as taking the guns away; see
        -- `L.stripWeapons`. Without this a player carried last match's loadout
        -- into the next one, and the arbiter refused to let it fire.
        if K.loot ~= nil and type(K.loot.stripWeapons) == "function" then
            pcall(K.loot.stripWeapons, record)
        else
            record.weapons = {}
        end
        -- CHECKED, and retried on the tick when it is refused. See `restaging`
        -- above for why a discarded refusal is the camera bug rather than a
        -- cosmetic one.
        if not keepLobbyBody and staging ~= nil and staging.position ~= nil then
            local placed, why = M.placeInStaging(record, "staging")
            if not placed then
                restaging[record.id] = { attempts = 1, nextAtMs = K.nowMs() + RESTAGE_RETRY_MS }
                K.warn(("staging placement refused for player %d (%s) — retrying on the tick"):format(
                    record.id, tostring(why)))
            end
        end
    end
    M.armCountdown()
end

--- The one placement that puts a human in the lobby, used by the end-of-match
--- sweep, by the elimination sweep and by the retry. One function so the three
--- of them cannot drift apart, and so the retry is provably the same call that
--- was refused rather than a second opinion about where the lobby is.
function M.placeInStaging(record, reason)
    if record == nil or record.id <= 0 then return false, "not_a_player" end
    local staging = K.map and K.map.staging or nil
    if staging == nil or staging.position == nil then return false, "no_staging_point" end
    return K.placeAt(record.id, staging.position, K.stagingBucket(), {
        heading = staging.heading, reason = reason or "staging", graceMs = 3000,
    })
end

--- Re-issue the placements the lobby sweep could not make. Runs in EVERY phase,
--- deliberately: a refusal caused by a life transition clears itself a second
--- later, and by then the match may already have opened its next staging.
function M.tickRestaging()
    local now = K.nowMs()
    for playerId, entry in pairs(restaging) do
        local record = K.players[playerId]
        if record == nil then
            restaging[playerId] = nil
        elseif now >= entry.nextAtMs then
            local placed, why = M.placeInStaging(record, "staging_retry")
            if placed then
                restaging[playerId] = nil
                K.log(("staging placement for player %d succeeded on attempt %d"):format(
                    playerId, entry.attempts + 1))
            else
                entry.attempts = entry.attempts + 1
                entry.nextAtMs = now + RESTAGE_RETRY_MS
                if entry.attempts >= RESTAGE_ATTEMPTS then
                    restaging[playerId] = nil
                    -- LOUD, because this is the one state the mode cannot fix
                    -- for the player: a body left in the match bucket with the
                    -- death camera on it. Naming the refusal is the difference
                    -- between a bug report and a mystery.
                    K.warn(("staging placement for player %d gave up after %d attempts (%s) — " ..
                        "that player's body is NOT in the lobby"):format(
                        playerId, entry.attempts, tostring(why)))
                end
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- THE QUEUE, and why there is no ready gate.
--
-- Staging used to end on a countdown while the HUD asked every player to press
-- a key to declare themselves ready. That gate did nothing — no server ever
-- held a ready ledger, `armCountdown` counted heads and the countdown started
-- the match regardless — and it could not have been made to work: unanimity
-- across sixty-four strangers is not a thing a lobby produces, and one player
-- reading their phone would have held everybody.
--
-- What replaces it is the one decision a player genuinely has to make: am I in
-- this match or am I watching it. `record.queued` is that answer and nothing
-- else. Staging is open to everybody; the countdown runs for everybody; only
-- the queued are dropped.
--
-- The flag is NOT cleared between matches. Somebody who queued once has said
-- they came here to play, and asking them to say it again every three minutes
-- is the ready gate wearing a different hat. Leaving is a key press away, and a
-- disconnect forgets the record entirely.
--
-- `queued` is absent from `newRecord` in kernel.lua on purpose: nil reads as
-- "not queued", so a roster row adopted lazily mid-staging is a spectator until
-- it asks to be otherwise, which is the safe default.
-- ---------------------------------------------------------------------------

--- Everybody who has asked for the next match AND is far enough into their
--- connection to be dropped into it. A record still in `lobby` has no world yet;
--- counting it toward the countdown would start a match its owner cannot join.
function M.queuedHumans()
    local list = {}
    for _, record in ipairs(K.humans()) do
        if record.queued == true and record.state ~= "lobby" then
            list[#list + 1] = record
        end
    end
    return list
end

function M.queuedCount() return #M.queuedHumans() end

--- Join or leave the queue. Refuses with a reason rather than half-succeeding,
--- because every refusal here has a sentence the HUD can already say.
function M.setQueued(playerId, wanted)
    local record = K.ensure(playerId)
    if record == nil or record.id <= 0 then return false, "unknown" end
    -- Only in staging. A queue that accepted entries mid-match would be a
    -- promise the deploy cannot keep: squads are built once, at deploy.
    if current.phase ~= "staging" then return false, "matchInProgress" end
    if record.state == "lobby" then return false, "notReady" end
    local target = wanted ~= false
    if record.queued == target then return true end
    record.queued = target
    K.log(("player %d %s the queue (%d queued)"):format(
        record.id, target and "joined" or "left", M.queuedCount()))
    M.armCountdown()
    return true
end

--- Is this player in the CURRENT match, as opposed to watching it from staging?
---
--- In staging the question has no meaning yet and everybody gets the full panel.
--- Once squads are built it is exactly one thing: whether the player has one.
--- A spectator answering `false` here is what turns off their squad panel, their
--- kit strip and the tac-map's auto-open, and turns on the block that tells them
--- which match they are waiting for.
function M.isParticipant(record)
    if record == nil or record.state == "lobby" then return false end
    if current.phase == "staging" then return true end
    -- AN ELIMINATED PLAYER IS A SPECTATOR, and this line is what turns the
    -- watch panel on for them.
    --
    -- `web/match.html` has carried a `stagingWatch` block since staging existed
    -- -- "watching a match rather than playing it", the spectate fallback of
    -- plan section 6.1 -- and `web/match.js` shows it on exactly one condition:
    -- `participant !== true` in a phase that is not staging. Until now the only
    -- thing that could satisfy it was a player who never queued, so somebody who
    -- died had no state at all: still `participant`, still shown a squad panel
    -- and a kit strip for a life that had ended, and told nothing.
    --
    -- The state is deliberately checked AFTER the staging branch above: a
    -- `spectating` record that survives into the next staging (a hot reload
    -- between matches) must not be a spectator of the lobby it is standing in.
    if record.state == "spectating" then return false end
    return record.squad ~= nil
end

--- The countdown starts when enough QUEUED players are present, and once armed
--- it is not re-armed. Re-arming on every join was survivable when the trigger
--- was a connection; with a join key it would be a lobby whose clock resets
--- every time somebody presses it — a countdown that never expires reads as a
--- broken mode, and it is the exact failure the ready gate was accused of.
function M.armCountdown()
    -- STAGING ONLY, and this guard is the difference between a mode that
    -- recovers and one that parks forever.
    --
    -- `current.phaseEndsAtMs` is a SINGLE field shared by four phases: staging's
    -- countdown, deploy's drop window, extraction's card and resolved's card.
    -- This function is called from `onPlayerReady` and `onPlayerDisconnected`
    -- (main.lua), both of which fire in EVERY phase -- and without this line its
    -- else branch below nils that field wherever it happens to be pointing.
    --
    -- The tick refuses to advance deploy, extraction or resolved without a
    -- deadline, so one player quitting the tac-map while the queue is one under
    -- `minPlayers` freezes the match with no in-game way out. The worst shape is
    -- the quiet one: the last players leave during the twelve-second result
    -- card, the deadline is nilled, `toResolved` and `toStaging` never run, and
    -- the server sits in `extraction` with nobody in it -- while every player
    -- who joins afterwards is refused with `matchInProgress` (M.setQueued), so
    -- the server can never start another match until an operator runs `br.end`.
    -- With the dev `minPlayers = 1` it fires the moment the last tester leaves.
    --
    -- Found by the 2026-09-02 audit, confirmed 3/3 by adversarial review.
    if current.phase ~= "staging" then return end

    local need = seconds("minPlayers", 2)
    local queued = M.queuedCount()
    if queued >= need then
        if current.phaseEndsAtMs == nil then
            current.phaseEndsAtMs = K.nowMs() + seconds("stagingSeconds", 150) * 1000
        end

        -- FAST FILL. `minPlayers` decides whether a match may start; this
        -- decides when waiting any longer stops being worth it. Once the queue
        -- reaches `startAtPlayers`, collapse whatever is left of the long wait
        -- down to `countdownSeconds`.
        --
        -- The `>` test is the whole safety of it: this only ever moves the
        -- deadline FORWARD. Without it, a player leaving and rejoining would
        -- re-arm the short countdown and push back a clock that everybody else
        -- in the lobby is already watching -- and on a busy server that is an
        -- infinite staging phase, because somebody is always joining.
        --
        -- Plan section 2 asked for exactly this ("fills to 64 or 60 s,
        -- whichever first") and `countdownSeconds` was written for it, but the
        -- cut itself was never implemented: a full lobby sat out the whole of
        -- `stagingSeconds` anyway.
        local fast = seconds("startAtPlayers", 5)
        if fast > 0 and queued >= fast then
            local soon = K.nowMs() + seconds("countdownSeconds", 60) * 1000
            if current.phaseEndsAtMs > soon then current.phaseEndsAtMs = soon end
        end
    else
        current.phaseEndsAtMs = nil
    end
end

RegisterNetEvent("cordon:queue", function(wanted)
    local ok, why = M.setQueued(source, wanted ~= false)
    -- The refusal kinds are named after strings the HUD already carries, so a
    -- refused join says why instead of doing nothing visible.
    if not ok and why ~= nil and why ~= "unknown" then
        K.notice(source, why, {})
    end
end)

-- ---------------------------------------------------------------------------
-- DEPLOY. The tac-map opens, squads pin a landing zone, and bots are added to
-- fill the slots players did not — at the END of staging so the drop map shows
-- a real headcount, and never mid-match.
-- ---------------------------------------------------------------------------
function M.toDeploy(reason)
    if not M.transition("deploy", reason or "countdown") then return end
    current.deployedAtMs = K.nowMs()
    current.number = current.number + 1
    current.id = ("m%d:%d"):format(K.nowMs(), current.number)
    current.format = M.resolveFormat()
    current.phaseEndsAtMs = K.nowMs() + seconds("deploySeconds", 45) * 1000
    M.buildSquads()
    if K.bots ~= nil then pcall(K.bots.fill, current) end
    -- The survey again, at the one moment it has to be right. It is normally
    -- already there from `onPlayerReady`, and re-sending a couple of kilobytes
    -- once per match is a trivial price for never showing a player an empty
    -- district in the forty-five seconds they have to choose a drop.
    if K.publishSurvey ~= nil then pcall(K.publishSurvey) end
end

function M.resolveFormat()
    local format = K.tune("format", cfg().defaultFormat or "squad")
    if format ~= "solo" and format ~= "duo" and format ~= "squad" then format = "squad" end
    return format
end

function M.squadSize()
    if current.format == "solo" then return 1 end
    if current.format == "duo" then return 2 end
    return 4
end

--- Squads are built once, at deploy, FROM THE QUEUE. A party stays together;
--- singles fill the emptiest squad, which keeps the sizes even without any
--- matchmaking. Everybody else stays in staging and watches — they are already
--- standing in the right bucket, so a spectator costs nothing to make.
function M.buildSquads()
    current.squads = {}
    current.nextSquadId = 1
    local size = M.squadSize()
    local pool = M.queuedHumans()
    table.sort(pool, function(a, b) return a.id < b.id end)

    local function emptiest()
        local best = nil
        for _, squad in pairs(current.squads) do
            if #squad.members < size and (best == nil or #squad.members < #best.members) then
                best = squad
            end
        end
        if best == nil then
            best = { id = current.nextSquadId, members = {}, alive = 0, placement = nil, bot = false }
            current.squads[best.id] = best
            current.nextSquadId = current.nextSquadId + 1
        end
        return best
    end

    for _, record in ipairs(pool) do
        local squad = emptiest()
        squad.members[#squad.members + 1] = record.id
        record.squad = squad.id
        -- Team ids are the PLATFORM's friendly-fire mechanism, and they are
        -- re-applied at every placement rather than trusted to survive one:
        -- whether setTeam outlives a kill -> respawn has never been measured
        -- (arena E5, still open), and re-applying costs one call.
        pcall(Open77.combat.setTeam, record.id, squad.id)
    end
end

-- ---------------------------------------------------------------------------
-- LIVE. Squads are placed at their pin — ON THE GROUND, standing.
--
-- Measured 2026-09-02 (E3): a player respawned 120 m up falls and DIES on
-- landing, and god mode does not prevent it because fall damage bypasses the
-- arbiter god mode gates. So there is no drop from altitude and no free-fall;
-- the landing choice is made on the map, which is where it was always made,
-- and the descent was only ever spectacle. Decision 18.
--
-- Placement is STAGGERED. Each placement is a kill -> respawn carrying a
-- streaming preload, and 64 of them in one tick is a stampede; 50 ms apart is
-- 3.2 s for a full lobby and invisible to a player watching a countdown.
-- ---------------------------------------------------------------------------
function M.toLive(reason)
    if current.phase ~= "deploy" then return end
    -- A MATCH NEEDS TWO SIDES. Measured 2026-09-02: two players in Squad format
    -- land in ONE squad, `remainingSquads()` is 1 from the first tick, and
    -- `checkEnd` resolves the match to an extraction before anybody has moved.
    -- The symptom is a match that "runs" and is back in staging seconds later,
    -- which reads as the mode being broken rather than as a lobby being too
    -- small for its format.
    --
    -- Refusing here rather than in checkEnd is deliberate: the honest failure is
    -- "this lobby cannot play this format", stated before the drop, not a match
    -- that starts and instantly ends.
    if M.remainingSquadSeats() < 2 then
        local names = {}
        for _, record in ipairs(K.humans()) do
            names[#names + 1] = ("%d:%s%s"):format(
                record.id, tostring(record.state), record.queued == true and ":queued" or "")
        end
        K.warn(("refusing to start: %d squad(s) for format %s (size %d) with %d queued of %d " ..
            "human(s) [%s] — a battle royale needs at least two sides."):format(
            M.remainingSquadSeats(), tostring(current.format), M.squadSize(),
            M.queuedCount(), #K.humans(), table.concat(names, " ")))
        M.toStaging("too_few_squads")
        return
    end
    if not M.transition("live", reason or "deploy_elapsed") then return end
    current.startedAtMs = nil -- Set when the placement wave actually opens combat.

    -- EVERY CONTESTANT STARTS EMPTY, and this is the belt to toStaging's braces.
    -- A player adopted mid-staging, or one whose strip was refused because the
    -- weapon request was still in flight, would otherwise reach the drop armed.
    -- Loot is the entire economy of this mode; starting with a gun is not a
    -- small advantage, it is the whole first fight.
    if K.loot ~= nil and type(K.loot.stripWeapons) == "function" then
        for _, record in ipairs(K.humans()) do pcall(K.loot.stripWeapons, record) end
    end
    current.phaseEndsAtMs = nil

    deployments = { matchId = current.id, entries = {}, deadlineMs = K.nowMs() + 30000 }
    local wave = deployments

    local shieldMs = ((Config and Config.spawnProtection and Config.spawnProtection.deploySeconds) or 4) * 1000
    local index = 0
    for _, squad in pairs(current.squads) do
        for _, playerId in ipairs(squad.members) do
            local record = K.players[playerId]
            if record ~= nil then
                index = index + 1
                local at = M.landingFor(squad)

                -- HAND-PLACED GROUND SPAWNS. Walked with `/br.map add spawn`
                -- and stored on the map, these are the per-PLAYER placement --
                -- the landing zone stays the per-SQUAD one, because that is
                -- what the drop needs and a drop has no use for 64 separate
                -- points.
                --
                -- Only when the drop is OFF. With the chute armed everybody
                -- comes down on the squad's zone by design, and reading a
                -- spawn list there would put players on the ground under the
                -- squad they are supposed to be falling with.
                --
                -- An empty list changes nothing, which is what makes this safe
                -- to leave in: a map nobody has edited behaves exactly as it
                -- did before.
                if not K.dropEnabled() then
                    local spawns = K.map and K.map.spawns or nil
                    if type(spawns) == "table" and #spawns > 0 then
                        at = spawns[((index - 1) % #spawns) + 1].position
                    end
                end

                record.state = "deploying"
                wave.entries[playerId] = {
                    record = record, squad = squad, position = at,
                    nextAtMs = K.nowMs() + index * 50, shieldMs = shieldMs,
                    applied = playerId < 0,
                }
            end
        end
    end
end

-- API acceptance is not placement. Track the accepted revision until the
-- canonical life state proves the client applied that very respawn. A previous
-- lobby transition, stale callback or unrelated revive must not open combat.
local function deploymentLife(id)
    local ok, life = pcall(Open77.players.getLifeState, id)
    return ok and type(life) == "table" and life or nil
end

local function deploymentGroundFallback(id, reason)
    local entry = deployments and deployments.entries[id] or nil
    if entry == nil or K.players[id] ~= entry.record then return false end
    K.endDrop(id, reason)
    entry.groundOnly, entry.applied, entry.revision = true, false, nil
    entry.nextAtMs = K.nowMs()
    return true
end

local function excludeDeployment(id, entry, reason)
    deployments.entries[id] = nil
    local squad = entry.squad
    for index = #squad.members, 1, -1 do
        if squad.members[index] == id then table.remove(squad.members, index) end
    end
    if #squad.members == 0 then current.squads[squad.id] = nil end
    M.taint("deployment_failed")
    local record = K.players[id]
    if record == entry.record then
        K.endDrop(id, "deployment_failed")
        record.state, record.squad, record.queued = "spectating", nil, false
        record.placement = nil
        if not M.placeInStaging(record, "deployment_failed") then
            restaging[id] = { attempts = 1, nextAtMs = K.nowMs() + RESTAGE_RETRY_MS }
        end
    end
    K.warn(("deployment excluded player %d (%s)"):format(id, tostring(reason)))
end

function M.tickDeployments()
    local wave = deployments
    if wave == nil then return end
    if current.phase ~= "live" or current.id ~= wave.matchId then
        deployments = nil
        return
    end
    local now = K.nowMs()
    local waiting = false
    for id, entry in pairs(wave.entries) do
        if K.players[id] ~= entry.record or entry.record.squad ~= entry.squad.id then
            excludeDeployment(id, entry, "participant_left")
        else
            local drop = entry.record.drop
            if drop ~= nil and now >= drop.deadlineMs then
                deploymentGroundFallback(id, "deployment_drop_timeout")
            end
            local life = id > 0 and deploymentLife(id) or nil
            -- Recheck even an acknowledged placement while the other clients
            -- catch up: Recovering itself can time out into Dead.
            if id > 0 and entry.revision ~= nil then
                entry.applied = life ~= nil and life.bucket == entry.bucket and
                    ((life.phase == "recovering" and life.revision == entry.revision + 1) or
                     (life.phase == "alive" and life.revision == entry.revision + 2))
                if life ~= nil and life.phase == "dead" then
                    K.endDrop(id, "deployment_retry")
                    entry.revision = nil
                    entry.nextAtMs = now + RESTAGE_RETRY_MS
                end
            end
            if not entry.applied and now >= wave.deadlineMs then
                excludeDeployment(id, entry, "placement_timeout")
            elseif not entry.applied then
                waiting = true
                if entry.revision == nil and now >= entry.nextAtMs then
                    entry.bucket = K.matchBucket()
                    local options = { reason = "deploy", graceMs = 2500, shieldMs = entry.shieldMs }
                    local accepted, why
                    if entry.position == nil then
                        accepted, why = false, "no_position"
                    elseif K.dropEnabled() and not entry.groundOnly then
                        accepted, why = K.dropTo(id, entry.position, entry.bucket, options)
                    else
                        accepted, why = K.placeAt(id, entry.position, entry.bucket, options)
                    end
                    entry.nextAtMs = now + RESTAGE_RETRY_MS
                    if accepted then
                        life = deploymentLife(id)
                        if life ~= nil and life.phase == "respawnpending" then
                            entry.revision = life.revision
                        else
                            -- An accepted request must expose its pending state.
                            -- Do not repeatedly kill a player when it cannot be read.
                            entry.nextAtMs = wave.deadlineMs
                        end
                    else
                        entry.reason = why
                    end
                end
            end
        end
    end
    if waiting then return end
    deployments = nil
    if M.remainingSquadSeats() < 2 then
        M.toStaging("too_few_deployed_squads")
        return
    end
    local ok, why = K.cordon.begin(K.map, M.schedulePreset())
    if not ok then
        K.warn("cordon could not start: " .. tostring(why))
        M.toStaging("cordon_failed")
        return
    end
    current.startedAtMs = now
    current.initialSides = M.remainingSquadSeats()
    for id, entry in pairs(wave.entries) do
        entry.record.state = "alive"
        if entry.record.drop == nil then entry.record.shieldUntilMs = now + entry.shieldMs end
        pcall(Open77.combat.setTeam, id, entry.squad.id)
    end
    -- Each client has now entered the bucket. Seed the small individual upserts
    -- after placement rather than relying on the oversized bucket catch-up.
    if K.loot ~= nil then
        pcall(K.loot.seed, K.map)
        if type(K.loot.publishCrates) == "function" then pcall(K.loot.publishCrates) end
    end
    K.cordon.publish()
    if K.squads ~= nil then pcall(K.squads.openChannels) end
end

function M.schedulePreset()
    local preset = K.tune("schedule", "standard")
    if type(preset) ~= "string" or preset == "" then return "standard" end
    return preset
end

--- THE DROP PIN. The tactical overlay has always sent `cordon:pin` when a
--- player clicks a block, and until now NOTHING LISTENED -- the map said "click
--- a block to set your drop pin", the click travelled, and the server dropped
--- it on the floor. Reported by the owner the first time the map had a grid to
--- click on at all.
---
--- The pin is snapped to the nearest SURVEYED LANDING ZONE rather than honoured
--- as a raw point, and that is the whole design of it. A click lands anywhere in
--- a hundred-metre block, including on ground nobody has walked; a landing zone
--- is a probed point with a known height. So the click chooses a place, and the
--- survey chooses the metre.
--- EVERY EXIT FROM HERE IS NOW AUDIBLE, and that is the second half of the fix.
--- The refusals used to leave as one kind, `pinRefused`, carrying the reason in
--- a FIELD -- and the HUD draws nothing for a notice kind its string table does
--- not name (`web/match.js`, "a toast reading `notice.somethingNew` would be
--- worse than silence"). There was no such string, so every refusal was silent
--- and a click into a phase that cannot take a pin looked exactly like a click
--- that never travelled. The kinds below are named after strings the HUD
--- carries, which is the same rule `cordon:queue` above already follows.
RegisterNetEvent("cordon:pin", function(x, y)
    local record = K.ensure(source)
    if record == nil then return end
    local px, py = tonumber(x), tonumber(y)
    if px == nil or py == nil then return end

    -- Deploy only. A pin set mid-match would move a squad that has already
    -- landed, and a pin set in staging would not survive squad assignment.
    if M.phase() ~= "deploy" then
        K.log(("pin: player %d clicked in phase %s -- refused"):format(record.id, M.phase()))
        K.notice(record.id, "pinNotDeploying", {})
        return
    end
    local squad = record.squad and M.current().squads[record.squad] or nil
    if squad == nil then
        K.log(("pin: player %d has no squad -- refused"):format(record.id))
        K.notice(record.id, "pinNoSquad", {})
        return
    end

    local best, bestDistance = nil, nil
    for _, zone in ipairs((K.map and K.map.landings) or {}) do
        if zone.position ~= nil then
            local dx, dy = zone.position.x - px, zone.position.y - py
            local distance = (dx * dx) + (dy * dy)
            if bestDistance == nil or distance < bestDistance then
                best, bestDistance = zone, distance
            end
        end
    end
    if best == nil then
        K.log(("pin: player %d clicked but the map has no landing zones"):format(record.id))
        K.notice(record.id, "pinNoZone", {})
        return
    end

    squad.pin = best.position
    -- The KEY and the LABEL, kept beside the position. The position alone is
    -- what the drop needs; the label is what the deploy panel and the tac-map
    -- have to print, and re-deriving it from a coordinate later would mean
    -- searching the survey for a float match.
    squad.pinKey = best.key
    squad.pinLabel = best.label or best.key
    squad.pinAuto = false
    K.log(("pin: player %d set squad %d to %s"):format(record.id, squad.id, tostring(best.key)))
    -- Two acknowledgements, deliberately. The notice is immediate and reaches
    -- the whole squad; `self.pin` on the next state push is the authoritative
    -- one and is what the panel keeps showing. Either alone would be a worse
    -- feature: a toast that vanishes, or a half-second of nothing after a click.
    if K.squads ~= nil then
        pcall(K.squads.notifySquad, squad.id, "dropPin",
            { label = squad.pinLabel, x = best.position.x, y = best.position.y })
    end
end)

--- THE TOUCHDOWN REPORT. The client says it has landed; the server closes the
--- descent, drops the authoritative shield and starts the landing grace.
---
--- What this event can and cannot do is worth being precise about, because it
--- is a client claim like any other. It can only make a descent end EARLIER
--- than the timeout would have ended it, and the only thing it buys the player
--- is `spawnProtection.landingGraceSeconds` — which the timeout path grants
--- too. So the plausibility check is a courtesy, not a security boundary: a
--- client that lies about its height merely gets its grace a few seconds early
--- and loses its shield a few seconds early with it.
RegisterNetEvent("cordon:landed", function(x, y, z)
    local record = K.ensure(source)
    if record == nil or record.drop == nil then return end
    if not K.dropLandingPlausible(record, z) then
        K.log(("drop: player %d reported a landing at z=%s while released above z=%.1f — " ..
            "ignored, the timeout still owns this descent"):format(
            record.id, tostring(z), record.drop.ground.z))
        return
    end
    K.endDrop(record.id, "reported")
end)

--- The client says it cannot fly: no chute binding, a refused arm, a perspective
--- the arbiter would not give. Land it now rather than let the player free-fall
--- for the whole of `landingTimeoutSeconds` — the outcome is the same ground
--- placement either way, and the difference is a second instead of a minute.
RegisterNetEvent("cordon:chuteFailed", function(reason)
    local record = K.ensure(source)
    if record == nil or record.drop == nil then return end
    if deploymentGroundFallback(record.id, "client:" .. tostring(reason)) then return end
    K.dropFallback(record.id, "client:" .. tostring(reason))
end)

--- Where a squad lands. The pin if they set one, otherwise a surveyed landing
--- zone chosen at random so an unpinned squad still starts somewhere sensible.
function M.landingFor(squad)
    if squad.pin ~= nil then return squad.pin end
    local landings = K.map and K.map.landings or {}
    local usable = {}
    -- The ZONES, not their positions. The position is all the drop needs, but
    -- the label is what the interface prints, and a squad that never pinned is
    -- exactly the squad that most needs to be told where it is going.
    for _, zone in ipairs(landings) do
        if zone.position ~= nil then usable[#usable + 1] = zone end
    end
    if #usable == 0 then
        -- No surveyed landing zones: fall back to staging so the mode fails
        -- visibly in one place rather than scattering players at (0,0,0),
        -- which is a real location in Night City and a confusing one to debug.
        return K.map and K.map.staging and K.map.staging.position or nil
    end
    -- PICK ONCE PER SQUAD, AND REMEMBER IT. Without this the choice is made
    -- afresh for every member, because the deploy loop calls this inside its
    -- per-player loop -- so a squad of four lands in four different places.
    --
    -- Measured 2026-09-02: two real clients in the same squad deployed 350
    -- metres apart, on opposite sides of the district. In a mode whose whole
    -- shape is "your squad has a reason to come to you", that is not a rough
    -- edge, it is the mode not working. Reviving a squadmate, sharing loot and
    -- fighting as a pair all assume you started together.
    --
    -- `squad.pin` already existed and was already honoured on the first line of
    -- this function; nothing ever set it. This is that missing half.
    local zone = usable[math.random(1, #usable)]
    squad.pin = zone.position
    squad.pinKey = zone.key
    squad.pinLabel = zone.label or zone.key
    -- Flagged as automatic so the interface says "assigned" rather than
    -- claiming the squad chose it. A pin nobody set that reads like a decision
    -- is a small lie the player finds out about on the way down.
    squad.pinAuto = true
    return squad.pin
end

-- ---------------------------------------------------------------------------
-- ELIMINATION AND THE END.
-- ---------------------------------------------------------------------------
function M.onDeath(record, killerId, cause, terminal)
    if not M.isLive() then return end
    if not terminal and cause == "disconnect" and record.state == "dead" then
        return M.finishDowned(record, killerId, cause)
    end
    if terminal then
        if record.state ~= "dead" or record.downedFinished then return end
        record.downedFinished = true
        if Open77.players.setDownedDamageable then Open77.players.setDownedDamageable(record.id, false) end
        record.reviveUntilMs = nil
        record.revivePending = nil
    elseif record.state ~= "alive" then return end
    -- One line per elimination, kept because it is the join between a damage
    -- event and a match state change: without it, an elimination that does not
    -- happen looks identical to a death the mode never saw.
    K.log(("onDeath player=%d cause=%s killer=%s"):format(record.id, tostring(cause), tostring(killerId)))
    record.state = "dead"
    record.deathAtMs = K.nowMs()
    record.spectateAttempts = nil
    if record.drop ~= nil then K.endDrop(record.id, "death") end
    if not terminal and not record.bot and cause ~= "disconnect" and K.squads then
        record.downedKiller, record.downedCause = killerId, cause
        K.squads.onDeath(record)
        if K.loot then
            pcall(K.loot.dropOnDeath, record)
            if K.loot.stripWeapons then pcall(K.loot.stripWeapons, record) end
        end
        record.weapons = {}
        record.deathLootDropped = true
        M.armBleedOut(record)
        TriggerEvent("cordon:downed", record.id, killerId, cause)
        M.checkEnd()
        return
    end

    -- A DESCENT CAN END IN A DEATH, and the descent's god mode is released by
    -- exactly one function. The cordon bleed reaches a falling player and so
    -- does a client-reported death; without this the corpse keeps the
    -- authoritative shield for the rest of the match, and a revived squadmate
    -- comes back invulnerable. `K.endDrop` is idempotent and returns nil when
    -- nothing is armed.
    if record.drop ~= nil then K.endDrop(record.id, "death") end

    -- KILL CREDIT LIVES HERE, and for bots it did not exist anywhere.
    --
    -- It used to live in main.lua's `open77:playerKilled` handler, which was the
    -- ONLY place in the mode that ever incremented it -- and that event fires
    -- for a PLAYER victim with an attributed killer. A bot elimination arrives
    -- by a different road entirely (`onNpcDied` -> server/bots.lua -> here) and
    -- never touched the counter, so the owner spent an afternoon killing bots
    -- with the HUD's KILLS pinned at zero. That was a SEPARATE symptom from the
    -- ALIVE count standing still, with a separate cause, and fixing the hit
    -- bridge alone would not have moved it.
    --
    -- Here rather than at each caller because this function is already the
    -- exactly-once point per life: the `state ~= "alive"` guard above returns on
    -- the second event for the same death -- `playerKilled` and `playerDied`
    -- both arrive for a PvP kill -- so a credit written below that guard is
    -- written once however many handlers converge on it.
    local killer = killerId ~= nil and K.players[tonumber(killerId) or 0] or nil
    -- Camp guards are world NPCs, never contestants or rating-bearing bots.
    local holdout = killer == nil and killerId ~= nil and K.holdouts ~= nil
        and K.holdouts.get(killerId) ~= nil
    if killer ~= nil and killer.id ~= record.id then
        killer.kills = (killer.kills or 0) + 1
    end

    -- THE FEED ROW, written here for the same reason the credit above is: this
    -- is the exactly-once point per life, and both victim kinds pass through it.
    --
    -- No weapon is sent, deliberately. The only weapon name reachable at this
    -- point is the engine's record id -- `Items.Preset_Lexington_Default` and
    -- the like -- and a feed that prints those reads as a debug log rather than
    -- a kill feed. match.js already falls back to its own verb when `weapon` is
    -- absent, so the column is correct today and the field is there the day the
    -- mode can name a gun the way a player would.
    -- WHAT KILLED THEM, and the cause string alone cannot answer it.
    --
    -- The cordon damages with `kind = "environment"` -- it has to, the engine's
    -- attack-kind parser rejects a free-text "cordon" (server/cordon.lua) -- so
    -- the cause reaching here for a cordon death is "environment", while
    -- server/bots.lua defaults its own to "cordon" and a fall arrives as
    -- something else again. Measured 2026-09-03: three bots bled out inside
    -- Cordon 2 and all three rows rendered as a kill by "PLAYER", which is
    -- match.js's fallback name for a kill entry with no killer.
    --
    -- So classify on the KILLER, which is what the row is actually about: a
    -- a known camp guard is a firearm source even without contestant credit.
    -- A cordon death WITH a credited attacker keeps him and still renders with
    -- the cordon's verb, which is the distinction plan section 4 asks for.
    local environmental = cause == "environment" or cause == "cordon"
        or cause == "bleed" or cause == "unknown"
    local feedKind = nil
    if killer ~= nil then
        feedKind = environmental and "cordon" or "kill"
    elseif holdout then
        feedKind = "kill"
    elseif cause ~= "disconnect" then
        feedKind = "cordon"
    end
    -- A disconnect gets no row. Owner answer Q4 makes it an elimination and the
    -- roster shrinks accordingly, but the feed has three kinds and not one of
    -- them can say "left the match" without naming a killer who does not exist.
    if feedKind ~= nil then
        feedPush({
            kind = feedKind,
            killer = killer ~= nil and K.name(killer.id) or nil,
            killerKind = holdout and "holdout" or nil,
            killerBot = killer ~= nil and killer.bot == true or nil,
            victim = K.name(record.id),
            victimBot = record.bot == true or nil,
        })
    end

    local squad = record.squad and current.squads[record.squad] or nil
    -- Set only when THIS death is the one that emptied the squad. Reading
    -- `squad.placement ~= nil` afterwards would also be true for a squad wiped
    -- earlier, and a revived member dying a second time would then announce the
    -- same wipe twice.
    local wipedNow = false
    if squad ~= nil and M.squadAlive(squad) <= 0 and squad.placement == nil then
        wipedNow = true
        squad.placement = M.remainingSquads() + 1
        current.standings[#current.standings + 1] = squad.id
        -- COPIED ONTO THE RECORD as well as the squad. The state push has sent
        -- `self.placement` since it was written and it has always been nil --
        -- the field is declared in `newRecord` and was assigned nowhere -- so
        -- the one number a player wants at the moment of death was the one
        -- number the interface could not read. Placement lives on the squad
        -- (that is the mode's shape); this is the per-player copy the card and
        -- the band read before the match has a winner.
        for _, memberId in ipairs(squad.members) do
            local member = K.players[memberId]
            if member ~= nil then member.placement = squad.placement end
        end
    end

    -- AND THE WIPE, pushed after the kill so it sits above it in a column that
    -- reads newest first.
    --
    -- Only for a squad that was actually a squad. In Solo every elimination
    -- wipes a squad of one, and announcing that beside the kill line would
    -- double every row in the feed with no information in the second half.
    if wipedNow and #squad.members > 1 then
        feedPush({ kind = "squadwipe", squad = squad.id })
    end

    -- The loser's guns hit the ground where they fell: it is what makes a kill
    -- worth taking rather than avoiding.
    if K.loot ~= nil and not record.deathLootDropped then pcall(K.loot.dropOnDeath, record) end

    -- AND THEN THEY COME OUT OF HIS HANDS, which until now they did not.
    --
    -- `dropOnDeath` COPIES the ledger onto the ground -- it calls
    -- `Open77.loot.create` once per entry and never touches the player's own
    -- inventory (loot.lua:698-726) -- and the line below it cleared
    -- `record.weapons`, the mode's bookkeeping. Neither takes the rifle out of
    -- the corpse's hands. The only call that does is `L.stripWeapons`
    -- (loot.lua:817-825, `Open77.weapons.remove` per slot then `holster`), and
    -- it was reached only from `M.toSpectate` and `M.toStaging` -- that is,
    -- AFTER the whole downed window had already run.
    --
    -- So for the entire time a player lay "downed" he was still holding, and
    -- still able to fire, the gun he died with. Nothing refused those hits
    -- either: the arbiter tests `victim.state ~= "alive"` and has no test at all
    -- on the ATTACKER's state (main.lua:133), and its second gate is skipped
    -- outright on an empty ledger (`next(attacker.weapons) ~= nil`,
    -- main.lua:201) -- which is exactly what the line above had just made it.
    -- Clearing the ledger did not disarm him, it disarmed the CHECK.
    --
    -- Ordered AFTER `dropOnDeath`, which reads `record.weapons` to know what to
    -- put on the ground. `stripWeapons` clears the ledger itself; the explicit
    -- assignment stays as the fallback for a mode running without loot. It is
    -- already called on a `dead` record by `M.toSpectate`, so this is the same
    -- call in the same state, only earlier.
    if K.loot ~= nil and type(K.loot.stripWeapons) == "function" then
        pcall(K.loot.stripWeapons, record)
    end
    record.weapons = {}

    -- A human death opens a revive window on the body; a bot's does not, because
    -- there is nobody to come for it and a revivable bot would make a squad
    -- unkillable by attrition.
    -- Revive windows open only on initial downing, never terminal elimination.
    -- Armed AFTER the window exists, because all it can do is shorten one.
    if not record.bot then M.armBleedOut(record) end
    TriggerEvent("cordon:eliminated", record.id, killerId, cause)
    M.checkEnd()
end

-- A finishing hit or bleedout consumes the body once. The original downer
-- receives the credit unless a validated finishing attacker supersedes them.
function M.finishDowned(record, killerId, cause)
    if record == nil or record.state ~= "dead" or record.downedFinished then return false end
    if K.squads then K.squads.cancelRevive(record.id, "finished") end
    M.onDeath(record, killerId or record.downedKiller, cause or record.downedCause, true)
    return record.downedFinished == true
end

-- ---------------------------------------------------------------------------
-- WHAT HAPPENS BETWEEN DYING AND THE END OF THE MATCH.
--
-- Reported by the owner, 2026-09-02: "quand on meurs on est TP direct au
-- lobby?" -- and that sentence describes the whole of it, because until now
-- there was NOTHING between those two events. `M.onDeath` marked the record
-- dead and returned. The body stayed where it fell, ragdolled by the client
-- (`ForceRagdoll` in client/src/network/LifeReplication.cpp) with the
-- perspective arbiter pinned by its `dead` and `ragdoll` rows, and no code
-- anywhere would resurrect it. The next thing that ever touched that player was
-- `M.toStaging`, at the end of the result card. Die, then nothing, then the
-- lobby -- which is exactly what it looks like from inside.
--
-- A battle royale needs the middle. What goes there, and why it is this and not
-- something better:
--
--   * FREE-FLIGHT SPECTATING -- plan 6.1's first option -- needs a ghosted,
--     god-moded, NOCLIPPING body. `Open77.travel.setNoclip` is operator-only and
--     this resource holds no `player.travel` grant at all (open77.lua lists what
--     it does hold), so it is not reachable without a platform change. And
--     experiment E4, which was to measure whether such a body is invisible and
--     harmless to the players still fighting, has never been run: an unmeasured
--     ghost in a live match risks a spectator who can be shot, who blocks a
--     round, or who scouts for his squad over voice.
--   * STAGING WATCH is plan 6.1's own stated fallback, "needs no platform
--     change", and its interface already exists: the `stagingWatch` block in
--     web/match.html, which `M.isParticipant` above now turns on. So that is
--     what this builds.
--
-- The transition is DELAYED, and the delay is the answer to the "direct" in the
-- owner's sentence. A death is not immediately an elimination:
--
--   * with a living squadmate, the body is a revive target and stays exactly
--     where it fell for the whole revive window -- moving it would delete the
--     mechanic squads.lua exists for;
--   * with nobody left to come (solo format, or the whole squad down), the body
--     still holds for `eliminationHoldSeconds` so the player reads their own
--     elimination where they died instead of being snatched out of it.
--
-- Only then are they placed in the lobby bucket, standing, unarmed and
-- watching. THAT placement is also what gives them their camera back, because a
-- placement is a respawn and a respawn is DisableRagdoll + ResurrectLocal on the
-- client. Before this, the earliest a dead player could be resurrected was the
-- end of the match.
-- ---------------------------------------------------------------------------

--- How long a body nobody is coming for stays where it fell. Long enough to
--- read a card, short enough not to be a punishment. Clamped because it is a
--- tunable an operator can set to anything.
function M.eliminationHoldMs()
    local hold = seconds("eliminationHoldSeconds", 8)
    if type(hold) ~= "number" or hold < 0 then hold = 8 end
    if hold > 60 then hold = 60 end
    return math.floor(hold * 1000)
end

--- How long the player's own elimination card stays up once they are standing
--- in the lobby. Clamped like the hold, and for the same reason: it is an
--- operator value and zero is a legitimate answer (never show the card).
---
--- Deliberately independent of `eliminationHoldSeconds`. The hold is about the
--- BODY -- how long a corpse is left where it fell -- and the cordon shortens it
--- for a body out in the bleed (`M.armBleedOut`), which must not also cut short
--- the card the player is reading. Two clocks because they answer two questions.
function M.eliminationCardMs()
    local shown = seconds("eliminationCardSeconds", 12)
    if type(shown) ~= "number" or shown < 0 then shown = 12 end
    if shown > 300 then shown = 300 end
    return math.floor(shown * 1000)
end

-- ---------------------------------------------------------------------------
-- THE CORDON REACHES A BODY, AND IT IS ONE CLOCK, NOT TWO.
--
-- `C.tick` iterates `K.alive()` (cordon.lua:786), so a downed player took NO
-- cordon damage at all: going down inside the bleed was the one reliable way to
-- stop bleeding. A battle royale cannot have that -- the ring has to mean
-- something to a body lying in it, or being downed out there is safer than
-- staying up.
--
-- It is deliberately NOT a second stream of `Open77.players.damage` on a corpse
-- whose health the platform already floors at 0.01 (LifeReplication.cpp:531).
-- Two independent things counting down one life is precisely the double-count
-- to avoid, and it would also make the HUD's revive bar and the real deadline
-- disagree. Instead the cordon SHORTENS the one clock that already exists:
-- there is exactly one deadline per body, everything reads it, and the bar
-- stays honest because `reviveUntilMs` is moved with it.
--
-- DECIDED ONCE, AT DEATH, and that is a real limitation stated out loud rather
-- than hidden. A body cannot walk, so where it fell is where it is -- but the
-- cordon CLOSES, so a body that was inside at death can be outside it twenty
-- seconds later and this will not notice. The case that matters is the one the
-- owner will actually hit -- going down while already out in the bleed -- and
-- that one is caught exactly. Re-testing every tick was rejected because
-- scaling a shrinking remainder at 4 Hz compounds into a deadline nobody can
-- predict or explain.
--
-- The verdict is `C.evaluate`'s three-answer contract: true inside, false
-- outside, nil cannot-tell. Only an explicit `false` shortens anything. Which
-- way it resolves for a body is UNVERIFIED: the client stops publishing
-- snapshots while soft-dead (PlayerReplication.cpp:1735), so the server's
-- position for a corpse is frozen at the spot it died on -- the same point
-- `bodyPosition` captured -- and if the platform stops answering for a dead
-- player at all, `evaluate` returns nil and this changes nothing. Both
-- outcomes are safe; only the first is useful.
-- ---------------------------------------------------------------------------

--- How much faster a body out in the bleed runs out of time. 1.0 disables it.
local function bleedOutCordonFactor()
    local squads = (Config and Config.squads) or {}
    local factor = tonumber(K.tune("bleedOutCordonFactor", squads.bleedOutCordonFactor)) or 3.0
    if factor < 1.0 then factor = 1.0 end
    if factor > 20.0 then factor = 20.0 end
    return factor
end

--- Arm the ceiling the cordon puts on this body. Sets nothing when the body is
--- inside, or when containment cannot be decided, so the ABSENCE of the field is
--- itself the "no ceiling" answer and no reader needs to know a default.
function M.armBleedOut(record)
    if record == nil or K.cordon == nil or type(K.cordon.evaluate) ~= "function" then return end
    local ok, inside = pcall(K.cordon.evaluate, record)
    if not ok or inside ~= false then return end

    local factor = bleedOutCordonFactor()
    if factor <= 1.0 then return end

    local deathAt = record.deathAtMs or K.nowMs()
    -- The budget this body would otherwise have had: the hold, or the revive
    -- window when one was opened, whichever is longer.
    local budget = M.eliminationHoldMs()
    if record.reviveUntilMs ~= nil and record.reviveUntilMs > deathAt then
        budget = math.max(budget, record.reviveUntilMs - deathAt)
    end
    budget = math.floor(budget / factor)
    record.cordonBleedOutMs = deathAt + budget
    -- Moved WITH the deadline, so `S.revivable`, the reach check and the HUD's
    -- revive bar all count down the same number the sweep is watching.
    if record.reviveUntilMs ~= nil then
        record.reviveUntilMs = math.min(record.reviveUntilMs, record.cordonBleedOutMs)
    end
    K.log(("player %d went down outside the cordon: %d ms to bleed out (x%.1f)"):format(
        record.id, budget, factor))
end

--- IS SOMEBODY STILL ABLE TO COME FOR THIS BODY?
---
--- THE ONE PREDICATE THAT SEPARATES "DOWN" FROM "OUT", and it exists as a
--- function rather than as two copies of the same four lines because two
--- readers now depend on it and they must never disagree.
---
--- `record.state == "dead"` is NOT elimination. In Squad format a dead player
--- is a revive target for as long as `reviveUntilMs` runs AND a squadmate is
--- alive to answer it (server/squads.lua), and `S.completeRevive` puts them
--- straight back to `alive`. Anything that treats `dead` as final would, in
--- that window:
---
---   * show a player their own result card while a squadmate is sprinting to
---     pick them up -- and then have to take it away again, which reads as the
---     mode changing its mind about whether the match is over for them;
---   * and, if the elimination sweep believed it, move the body to the lobby
---     and DELETE the mechanic squads.lua exists for.
---
--- So: down is `dead` with a rescuer; out is everything else. The two callers
--- are `M.eliminationDueAtMs` (how long the body holds) and `M.resultFor` (when
--- the card is shaped), and they now answer the question the same way by
--- construction.
---
--- Both halves are required and `revivable` alone is not enough: it is true for
--- a solo player too -- it only tests the window and the body -- so asking it
--- by itself would hold every solo corpse for a rescuer who cannot exist.
function M.rescuePending(record)
    if record == nil or record.state ~= "dead" then return false end
    if K.squads == nil then return false end
    if type(K.squads.revivable) ~= "function" then return false end
    local ok, revivable = pcall(K.squads.revivable, record)
    return ok and revivable == true
end

--- When this dead record stops being a body and becomes a spectator.
function M.eliminationDueAtMs(record)
    if record == nil or record.state ~= "dead" then return nil end
    local hold = (record.deathAtMs or K.nowMs()) + M.eliminationHoldMs()
    -- A revive window somebody can actually answer outranks the hold, because
    -- the body IS the mechanic and a body that walked away is not revivable.
    -- Asked through `M.rescuePending` so the card above and this sweep cannot
    -- drift apart on what "still saveable" means.
    if M.rescuePending(record) then
        hold = math.max(record.reviveUntilMs or 0, hold)
    end
    -- The cordon's ceiling is applied LAST and only ever brings the deadline
    -- FORWARD. Kept as a clamp rather than as the answer so that the rescuer
    -- test above still runs every tick: when the last squadmate falls, the
    -- window collapses back to the hold on its own, which a value frozen at
    -- death could not do.
    if record.cordonBleedOutMs ~= nil then
        hold = math.min(hold, record.cordonBleedOutMs)
    end
    return hold
end

-- ---------------------------------------------------------------------------
-- THE `spectateMode` TUNABLE, READ FOR THE FIRST TIME.
--
-- It has been declared in `Config.tunables` since spectating was designed
-- (shared/config.lua, group Squads) with two choices, `staging` and `ghost`,
-- and NOTHING HAS EVER READ IT: `M.toSpectate` placed in the lobby
-- unconditionally, so an operator who set it to `ghost` got the staging
-- behaviour and no word about why. A tunable that silently does nothing is
-- worse than one that is absent, because the operator believes it worked.
--
-- `ghost` STILL DOES NOTHING, and that is deliberate rather than unfinished --
-- but it now says so once, in the log, instead of being swallowed:
--
--   * free-flight spectating needs `Open77.travel.setNoclip`, which is
--     operator-only and sits behind a `player.travel` grant this resource does
--     not hold (open77.lua lists every permission it does). `players.life.ghost`
--     is there and is not enough: a ghost that cannot fly is a corpse standing
--     in the middle of a firefight;
--   * experiment E4 -- is such a body invisible, non-collidable and unable to
--     shoot for the players still fighting -- has never been run (plan §6.1,
--     table row E4). Shipping it unmeasured risks a spectator who can be shot,
--     who blocks a doorway, or who scouts for his squad over voice.
--
-- So this resolves the EFFECTIVE mode, which is what the state push sends the
-- HUD and what `M.toSpectate` acts on. The day E4 is measured, this function is
-- where `ghost` stops degrading.
-- ---------------------------------------------------------------------------
local warnedGhost = false

function M.spectateMode()
    local squads = (Config and Config.squads) or {}
    local mode = K.tune("spectateMode", squads.spectateMode or "staging")
    if mode == "ghost" then
        -- ONCE per resource load, not once per elimination: this runs on the
        -- sweep, and a per-body warning would put one line per dead player per
        -- match in the file for a setting the operator changed on purpose.
        if not warnedGhost then
            warnedGhost = true
            K.warn("spectateMode is set to 'ghost', which is not reachable: this resource holds " ..
                "no 'player.travel' grant and experiment E4 has never been run. Eliminated " ..
                "players are watching from staging instead.")
        end
        return "staging"
    end
    if mode ~= "staging" then return "staging" end
    return mode
end

--- Turn an eliminated body into a spectator standing in the lobby bucket.
--- Returns ok, reason; a refusal is expected and is retried by the sweep.
function M.toSpectate(record)
    if record == nil or record.id <= 0 then return false, "not_a_player" end
    if record.state ~= "dead" then return false, "not_dead" end

    -- Everything armed comes off BEFORE the placement, so a refused placement
    -- leaves nothing behind either.
    if record.drop ~= nil then K.endDrop(record.id, "eliminated") end
    if K.squads ~= nil and type(K.squads.cancelRevive) == "function" then
        pcall(K.squads.cancelRevive, record.id, "eliminated")
    end
    record.reviveUntilMs = nil
    record.bodyPosition = nil
    record.shieldUntilMs = 0
    -- The guns were dropped where they fell by `onDeath`; this takes the slots
    -- as well, so nobody watches a match holding a rifle. `L.stripWeapons` is
    -- the same call `toStaging` makes, for the same reason.
    if K.loot ~= nil and type(K.loot.stripWeapons) == "function" then
        pcall(K.loot.stripWeapons, record)
    else
        record.weapons = {}
    end

    -- Resolved rather than assumed, so a `ghost` setting is named in the log at
    -- the moment it fails to apply. The call also has a side effect worth
    -- knowing about: it is what emits the one-time warning above.
    local mode = M.spectateMode()

    local placed, why = M.placeInStaging(record, "spectate")
    if not placed then return false, why end

    record.state = "spectating"
    record.eliminatedAtMs = K.nowMs()
    record.spectateAttempts = nil
    -- THE LINE THAT PROVES THE FEATURE. It names the four things a verification
    -- run has to see -- who, where they went, the placement the card is showing
    -- and the kills beside it -- so an elimination that landed and one that only
    -- looks like it did are distinguishable from the log alone.
    K.log(("eliminated: player %d is watching from %s (placement=%s kills=%d survived=%dms)"):format(
        record.id, mode, tostring(record.placement), record.kills or 0,
        (record.deathAtMs ~= nil and current.startedAtMs ~= nil)
            and math.max(0, record.deathAtMs - current.startedAtMs) or -1))
    return true
end

--- The sweep. Live phases only: once the match resolves, `M.toStaging` is a few
--- seconds away and it sweeps everybody, spectators included.
function M.tickEliminations()
    if not M.isLive() then return end
    local now = K.nowMs()
    for _, record in ipairs(K.humans()) do
        -- `squad ~= nil` is what distinguishes a contestant who died from a
        -- record that is merely not alive: somebody who never joined this match
        -- has no elimination to resolve.
        if record.state == "dead" and record.squad ~= nil then
            if not record.downedFinished and record.reviveUntilMs ~= nil
                and now >= record.reviveUntilMs and record.revivePending == nil then
                M.finishDowned(record, nil, "bleedout")
            end
            local due = M.eliminationDueAtMs(record)
            if due ~= nil and now >= due then
                local ok, why = M.toSpectate(record)
                if not ok then
                    -- The record stays `dead`, so the next tick asks again. The
                    -- refusals here are life transitions that clear themselves
                    -- within a second; the log is throttled because the tick is
                    -- four times a second and a stuck player would fill the file.
                    local attempts = (record.spectateAttempts or 0) + 1
                    record.spectateAttempts = attempts
                    if attempts == 1 or attempts % 20 == 0 then
                        K.warn(("spectate placement refused for player %d (%s), attempt %d"):format(
                            record.id, tostring(why), attempts))
                    end
                end
            end
        end
    end
end

--- How many squads the roster was actually split into. Distinct from
--- `remainingSquads`, which counts squads with somebody still alive and is only
--- meaningful once a match is running.
function M.remainingSquadSeats()
    local n = 0
    for _ in pairs(current.squads) do n = n + 1 end
    return n
end

--- Squads with at least one living member — DERIVED from the roster, never from
--- a maintained counter.
---
--- `squad.alive` was a counter set to 0 in `toLive` and incremented inside a
--- per-player deferred callback. If those callbacks did not run, every squad sat
--- at zero and the FIRST death of any kind made this return 0, so `checkEnd`
--- resolved the match with no winner — a two-player match ended within ten
--- seconds, before anyone fired, with the status line still reading `alive=2`
--- because THAT number was already derived and therefore right.
---
--- Three writers and one of them deferred is the same mistake `M.aliveCount()`
--- was fixed for earlier in the same file. Read the roster; it is 64 entries.
function M.remainingSquads()
    local n = 0
    for _, squad in pairs(current.squads) do
        local living = false
        for _, memberId in ipairs(squad.members) do
            local record = K.players[memberId]
            if record ~= nil and (record.state == "alive" or (record.state == "dead" and record.reviveUntilMs ~= nil and not record.downedFinished)) then living = true break end
        end
        if living then n = n + 1 end
    end
    return n
end

--- Living members of one squad, derived for the same reason.
function M.squadAlive(squad)
    if squad == nil then return 0 end
    local n = 0
    for _, memberId in ipairs(squad.members) do
        local record = K.players[memberId]
        if record ~= nil and (record.state == "alive" or (record.state == "dead" and record.reviveUntilMs ~= nil and not record.downedFinished)) then n = n + 1 end
    end
    return n
end

function M.checkEnd()
    if not M.isLive() or deployments ~= nil or current.resolvingVictory
        or (current.initialSides or 0) < 2 then return end
    local standing, winner = 0, nil
    for _, squad in pairs(current.squads) do
        for _, memberId in ipairs(squad.members) do
            local record = K.players[memberId]
            if record ~= nil and record.state == "alive" then
                standing, winner = standing + 1, squad
                break
            end
        end
    end
    if standing > 1 then return end
    -- With no standing side, a recoverable body can still decide the match.
    -- Do not manufacture a winner from iteration order or a pending revive.
    if standing == 0 and M.remainingSquads() > 0 then return end
    if standing == 0 then winner = nil end
    current.resolvingVictory = true
    -- Finish losing downed bodies through the existing exactly-once credit,
    -- placement, loot and event path before persisting the result. Suppress its
    -- recursive checkEnd; earlier downings rank below later ones.
    local losers = {}
    for _, record in pairs(K.players) do
        if record.state == "dead" and record.reviveUntilMs ~= nil and not record.downedFinished
            and record.squad ~= nil and (winner == nil or record.squad ~= winner.id) then
            losers[#losers+1] = record
        end
    end
    table.sort(losers,function(a,b)
        if (a.deathAtMs or 0) ~= (b.deathAtMs or 0) then return (a.deathAtMs or 0)<(b.deathAtMs or 0) end
        return a.id<b.id
    end)
    for _, record in ipairs(losers) do M.finishDowned(record) end
    current.winner = winner and winner.id or nil
    if winner ~= nil then
        winner.placement = 1
        for _, memberId in ipairs(winner.members) do
            local record=K.players[memberId]
            if record then
                record.placement=1
                if K.squads then K.squads.cancelRevive(record.id,"match_resolved") end
                record.revivePending,record.reviveUntilMs=nil,nil
                if Open77.players.setDownedDamageable then Open77.players.setDownedDamageable(record.id,false) end
            end
        end
    end
    -- Preserve extraction notification/protection, but consume no extraction
    -- countdown when the contest already has a last standing side.
    M.toExtraction("last_squad")
    M.toResolved(winner and "last_standing" or "no_survivors")
    current.resolvingVictory = false
end

--- The result card and the standings table, shaped only once the match has an
--- outcome. Nil in every earlier phase so the card is ABSENT rather than empty
--- (web/match.js renderResult explains why an empty card is a lie). Placement
--- lives on the SQUAD -- `record.placement` was reset every match and assigned
--- nowhere, which is why the card and the table showed nothing until 2026-09-02.
function M.resultFor(record)
    local final = current.phase == "extraction" or current.phase == "resolved"
    -- THE ELIMINATION CARD IS THIS CARD, SHAPED EARLY.
    --
    -- A player who has just died wants the same three numbers the result card
    -- already draws -- placement, kills, time survived -- and the mode now knows
    -- all three at the moment of death (`squad.placement` is assigned in
    -- `onDeath`, and `record.placement` with it). Building a second card would
    -- be a second thing to keep true.
    --
    -- `final` says which one this is, and the difference is not cosmetic: a
    -- mid-match card has NO WINNER and no standings, because neither exists yet,
    -- and a card that claimed either would be the mode lying. The winner block
    -- and the standings table are therefore absent rather than empty -- the same
    -- rule `renderResult` already applies to the card as a whole.
    --
    -- THE HUD DRAWS IT NOW. This payload was shipped inert on 2026-09-03 --
    -- web/match.css showed `.result[data-ready="true"]` only under
    -- `body[data-phase="resolved"]` and `body[data-phase="extraction"]` -- and
    -- the matching `live` rule now exists beside them, so the card the owner
    -- asked for ("quand je meurs si la game tourne tjrs, moi je devrais voir mon
    -- tableau de score direct") actually appears.
    --
    -- DOWN IS NOT OUT, and this is the one condition that has to be right.
    --
    -- The gate used to be `state == "dead" or state == "spectating"`, and
    -- `dead` is ALSO the state of a Squad player lying in his revive window
    -- with a squadmate running at him. Drawing an elimination card over a life
    -- that is not over is worse than drawing nothing: it tells the player the
    -- match is finished for them, and then takes it back when `S.completeRevive`
    -- puts them on their feet. `M.rescuePending` is the predicate the
    -- elimination sweep itself uses, so the card cannot appear before the sweep
    -- would fire and cannot linger past a revive.
    --
    -- In Solo it is true the instant they die (no squadmate can exist); in Squad
    -- it is true when the squad is wiped, or when the window ran out with nobody
    -- coming. That is exactly "genuinely eliminated".
    local eliminated = current.phase == "live"
        and record.squad ~= nil
        and (record.state == "spectating"
            or (record.state == "dead" and not M.rescuePending(record)))
    -- AND IT RETIRES. A hero-sized card pinned over the middle of the screen for
    -- the remaining four minutes of a match is not a result card, it is an
    -- obstruction -- and a spectator still has a band, a kill feed and the watch
    -- panel to read. So the card runs for `eliminationCardSeconds` from the
    -- moment the body reached the lobby, the same rhythm as the end-of-match
    -- card's `resultSeconds`, and then the surface hands itself back.
    --
    -- Measured from `eliminatedAtMs` rather than `deathAtMs` on purpose: the
    -- hold before the body moves is part of reading the card, not part of its
    -- lifetime, and a body whose placement is being retried has not started its
    -- clock yet.
    if eliminated and record.state == "spectating" and record.eliminatedAtMs ~= nil then
        if K.nowMs() - record.eliminatedAtMs >= M.eliminationCardMs() then
            eliminated = false
        end
    end
    if not final and not eliminated then return nil end
    local winner = current.winner and current.squads[current.winner] or nil
    local function placementOf(squad)
        if squad == nil then return nil end
        if squad.placement ~= nil then return squad.placement end
        if winner ~= nil and squad.id == winner.id then return 1 end
        return nil
    end

    -- `deathAtMs` is only meaningful for THIS match's death: a survivor carries
    -- last match's stamp until they die again, so the living are measured now.
    local endAt = (record.state == "alive" or record.deathAtMs == nil)
        and K.nowMs() or record.deathAtMs
    local survivedMs = current.startedAtMs and math.max(0, endAt - current.startedAtMs) or nil

    if not final then
        -- WHAT HAPPENS NEXT, which is the second half of the owner's sentence
        -- ("me dire que je suis mort retour lobby"). Two mutually exclusive
        -- answers, and the card says one of them rather than leaving the player
        -- to work out why their corpse is still lying in a street:
        --
        --   * `lobbyInMs` -- the body is still where it fell and this is how
        --     long until the sweep moves it. It is the SAME deadline
        --     `tickEliminations` is watching (`M.eliminationDueAtMs`), never a
        --     second countdown, so the number on the card is the number that
        --     fires;
        --   * `watching` -- they are already standing in the lobby.
        --
        -- Sent as a REMAINING duration like every other clock in this payload:
        -- the client shares no wall clock with the server, so an absolute
        -- deadline would be unusable (see the top of the HUD's client/match.lua).
        local lobbyInMs = nil
        if record.state == "dead" then
            local due = M.eliminationDueAtMs(record)
            if due ~= nil then lobbyInMs = math.max(0, due - K.nowMs()) end
        end

        -- Shaped and returned WITHOUT the standings loop. This runs for every
        -- eliminated player on every 500 ms push, and late in a 64-player match
        -- that is fifty players times a sixty-four-row build and a sort, twice a
        -- second, for a table that does not exist yet.
        return {
            final = false,
            placement = placementOf(record.squad and current.squads[record.squad] or nil),
            kills = record.kills or 0,
            survivedMs = survivedMs,
            lobbyInMs = lobbyInMs,
            watching = record.state == "spectating" or nil,
            -- The EFFECTIVE mode, after `ghost` has degraded, so the HUD names
            -- the place the player actually is. Sending the raw tunable would
            -- have the card promise a flight the server is not giving.
            --
            -- Resolved only for a player who is ALREADY watching, because that
            -- is the only state the HUD reads it in -- and this function runs
            -- for every eliminated player on every 500 ms push, so a tunable
            -- lookup here is fifty host calls a second late in a full match for
            -- a field nobody would read.
            spectate = record.state == "spectating" and M.spectateMode() or nil,
        }
    end

    local winnerNames = {}
    if winner ~= nil then
        for _, memberId in ipairs(winner.members) do
            local member = K.players[memberId]
            if member ~= nil then
                winnerNames[#winnerNames + 1] = { name = K.name(member.id), bot = member.bot == true }
            end
        end
    end

    local rows = {}
    for _, squad in pairs(current.squads) do
        local placement = placementOf(squad) or 0
        for _, memberId in ipairs(squad.members) do
            local member = K.players[memberId]
            if member ~= nil then
                rows[#rows + 1] = {
                    placement = placement,
                    name = K.name(member.id),
                    bot = member.bot == true,
                    squad = squad.id,
                    kills = member.kills or 0,
                    self = member.id == record.id,
                }
            end
        end
    end
    -- Winners first, the unplaced (a match cut short) last, kills as the tie-break.
    table.sort(rows, function(a, b)
        if a.placement ~= b.placement then
            if a.placement == 0 then return false end
            if b.placement == 0 then return true end
            return a.placement < b.placement
        end
        if a.kills ~= b.kills then return a.kills > b.kills end
        return tostring(a.name) < tostring(b.name)
    end)

    return {
        final = true,
        placement = placementOf(record.squad and current.squads[record.squad] or nil),
        kills = record.kills or 0,
        survivedMs = survivedMs,
        winnerNames = winnerNames,
        standings = rows,
    }
end

function M.toExtraction(reason)
    if not M.transition("extraction", reason or "last_squad") then return end
    current.phaseEndsAtMs = K.nowMs() + seconds("extractionSeconds", 12) * 1000
    -- Bots do not know the match is over and will keep shooting through the
    -- result card, so the winners are shielded for the whole of it. The shield
    -- is the only lever that stops them, because it is the one the arbiter
    -- honours.
    local winner = current.winner and current.squads[current.winner] or nil
    if winner ~= nil then
        for _, playerId in ipairs(winner.members) do
            local record = K.players[playerId]
            if record ~= nil then
                record.shieldUntilMs = K.nowMs() + seconds("extractionSeconds", 12) * 1000 + 2000
            end
        end
    end
    TriggerEvent("cordon:extraction", current.winner)
end

function M.toResolved(reason)
    if not M.transition("resolved", reason or "extraction_elapsed") then return end
    current.phaseEndsAtMs = K.nowMs() + seconds("resultSeconds", 12) * 1000
    if K.cordon and K.cordon.stop then K.cordon.stop() end
    -- The ladder is consulted ONCE, here, before a single standings row is
    -- read: a match containing a bot produces no snapshot, no queue entry and
    -- no announcement, and the rating model is never called at all.
    if K.ranked ~= nil and type(K.ranked.recordMatch) == "function" then
        -- READ THE ANSWER. This used to be a bare `pcall(...)` whose return was
        -- discarded, and that is how a type mismatch in `recordMatch` -- a
        -- string match id handed to `tonumber` -- stayed invisible for the whole
        -- life of the mode: every rated match refused itself with `no_match` and
        -- the refusal went into the bin. A ladder that silently writes nothing
        -- is worse than one that is switched off, because the switched-off one
        -- says so on every readout.
        --
        -- `pcall` stays, because a ladder must never take a match down with it.
        -- What changes is that its answer is logged, and a refusal is named.
        local ok, wrote, why = pcall(K.ranked.recordMatch, current)
        if not ok then
            K.warn(("ranked: recordMatch RAISED for %s -- %s"):format(
                tostring(current.id), tostring(wrote)))
        elseif wrote == false then
            K.warn(("ranked: match %s was NOT recorded -- %s"):format(
                tostring(current.id), tostring(why)))
        end
    end
end

--- Marks this match unrateable. Sticky, and set the moment a bot is added.
function M.taint(why)
    if not current.tainted then
        current.tainted = true
        K.log("match is unrateable: " .. tostring(why))
    end
end

function M.tainted() return current.tainted end

-- ---------------------------------------------------------------------------
-- The clock. One place decides when a phase is over.
-- ---------------------------------------------------------------------------
function M.tick()
    local now = K.nowMs()
    -- During initial deployment, chute failures belong to the same tracked
    -- transaction as the drop. Resolve them before the generic descent sweep.
    M.tickDeployments()
    -- Before anything phase-dependent, and deliberately outside the phase
    -- branches: a descent that outlives its match still has to end. This is the
    -- one guarantee the drop makes — the mode never waits on a client.
    K.tickDrops()
    -- Both sweeps sit OUTSIDE the phase branches for the same reason
    -- `K.tickDrops` does: a placement that was refused, and a body waiting to
    -- become a spectator, must still resolve when the phase moves under them.
    -- Each one guards its own phase; neither may be conditional on this one.
    M.tickRestaging()
    M.tickEliminations()
    if current.phase == "staging" then
        if current.phaseEndsAtMs == nil then
            M.armCountdown()
        elseif now >= current.phaseEndsAtMs then
            M.toDeploy("countdown_elapsed")
        end
    elseif current.phase == "deploy" then
        if current.phaseEndsAtMs ~= nil and now >= current.phaseEndsAtMs then
            M.toLive("deploy_elapsed")
        end
    elseif current.phase == "live" then
        if deployments == nil then K.cordon.tick() end
    elseif current.phase == "extraction" then
        if current.phaseEndsAtMs ~= nil and now >= current.phaseEndsAtMs then
            M.toResolved("extraction_elapsed")
        end
    elseif current.phase == "resolved" then
        if current.phaseEndsAtMs ~= nil and now >= current.phaseEndsAtMs then
            M.toStaging("result_elapsed")
        end
    end
end

-- RESOLVE THE FORMAT AT LOAD, the other half of the fix in `M.toStaging`.
--
-- A resource LOAD does not transition into staging -- `current.phase` is
-- initialised to "staging" by the table literal at the top of this file rather
-- than transitioned into it (the same asymmetry `bots.lua` documents for its
-- own sweep). So `M.toStaging` never runs for the first staging of a fresh
-- server, and `current.format` kept the literal "squad" until the SECOND match.
--
-- Measured 2026-09-03: with the `format` tunable set to solo and the server
-- freshly restarted, `br.status` and the staging card both still advertised
-- SQUAD. Resolving here makes the first lobby of a server tell the truth.
current.format = M.resolveFormat()

K.log(("match ready (format=%s)"):format(current.format))
