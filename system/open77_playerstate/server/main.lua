-- open77_playerstate -- durable world state for a player, across a disconnect.
--
-- Owner, 2026-08-27: "SAVING completely the state of the players -- when we
-- have a db we need a sync resource where the player's position is saved so he
-- respawns at the same position where he disconnected, his life points etc."
--
-- So: remember where somebody was and what condition they were in, and put them
-- back there when they return. open77_appearance already remembers what they
-- LOOK like and this resource does not touch that; the two are keyed the same
-- way and are otherwise independent.
--
-- ============================================================================
-- WHAT IS SAVED, AND WHAT IS DELIBERATELY NOT
-- ============================================================================
--
-- Saved, because restoring it is unambiguously right:
--
--   position (x, y, z)  the whole point.
--   heading             estimated; see the heading note below.
--   health, maxHealth   "his life points". Restored as a fraction, floored.
--   armour              the other half of "what condition were they in".
--   name                for diagnostics only -- never used as a key.
--   updated_at          what makes expiry answerable.
--
-- Recorded but NEVER restored, and the column is there so the question can be
-- asked of the data later:
--
--   bucket   The routing bucket a player was in. Restoration always puts them
--            in bucket 0, and that is not laziness. A non-zero bucket is by
--            convention a gamemode's private network dimension -- a match, an
--            instance -- and dropping somebody back into a match whose match
--            ended is exactly the "worse than a fresh spawn" case. It is also
--            self-consistent: a gamemode that allocates buckets is a gamemode
--            that owns spawn, and this resource stands down entirely for one
--            of those (see "who owns spawn" below), so any bucket it is in a
--            position to restore is bucket 0 already.
--
-- Not saved at all, and this is the decision most worth arguing with:
--
--   the vehicle the player was in, and their seat.
--            The server can answer this -- `Open77.vehicles.all()` carries an
--            occupant ledger of `{ playerId, seat }` -- so the omission is a
--            choice, not a limitation. Three reasons, in increasing weight:
--
--            1. A vehicle id does not survive a server restart. Vehicles are
--               authoritative entities created by a resource at runtime; after
--               a restart the id refers to nothing. So the id is only ever
--               valid for the case persistence matters least.
--            2. Even within one run, the car may have been driven off,
--               destroyed, or taken by somebody else while the player was
--               away. Re-seating them is then either impossible or theft.
--            3. Putting somebody into a seat means a second placement chasing
--               the respawn transaction, which is precisely the race this file
--               spends its length avoiding.
--
--            The behaviour instead: a player who logs out driving comes back
--            standing at that spot, on foot. That is the sane outcome, it
--            needs no `world.vehicles` capability and no per-tick scan of
--            every vehicle on the server, and least privilege is not ceremony
--            here -- the capability would exist solely to populate a column
--            nothing reads.
--
--   inventory, money, progression, quests.
--            Not this resource's job. They belong to whatever owns them, and
--            inventing a schema for them here would put a second claimant on
--            data another resource will want to own properly.
--
-- ============================================================================
-- WHO OWNS SPAWN
-- ============================================================================
--
-- A gamemode owns where its players spawn. `pursuit` teleports joiners to its
-- lobby; `freeroam` has forceOnJoin and autoRespawn and answers every
-- kill -> respawn with a respawn of its own. If this resource also places a
-- player, two things move the same player and the last one wins, without a
-- rule that says which. The project has already paid for that exact bug: the
-- symptom is "placement appears to work and the player is somewhere else a
-- second later", and it is maddening to diagnose because both sides are
-- individually correct.
--
-- They cannot negotiate it between themselves. Server resources are isolated:
-- no `exports`, no `GetInvokingResource`, no cross-resource event bus, and a
-- `TriggerEvent` that walks only its own VM. A gamemode could not be asked
-- whether it claims spawn even if it wanted to answer.
--
-- What IS available is the host, and it exposes two things that are enough:
--
--   1. `GetResourceState(name)` -- the host will say whether a named resource
--      is running, without either resource calling the other. That turns
--      "does a gamemode own spawn here" into an operator-declared list of
--      names plus a fact the host can confirm.
--   2. The join-time readiness gate -- which settles the ORDER question for
--      everything that respects it, and is the subject of the next section.
--
-- Hence `spawnPolicy`:
--
--   auto    (default) Inert -- no saving, no restoring, one log line -- while
--           any resource in `spawnOwners` is running. So installing this
--           alongside Pursuit costs literally nothing and cannot fight it.
--   never   Save, never place. For an operator who wants the data recorded
--           against the day they turn placement on, or who places players
--           with something of their own.
--   always  Restore regardless. Correct only when the operator knows nothing
--           else on the server places players.
--
-- Both knobs are tunable, so an owner who installs a gamemode this list has
-- never heard of fixes it from the Warden panel in ten seconds rather than by
-- editing Lua over SSH. That is the honest shape for a question only the
-- operator can actually answer.
--
-- ----------------------------------------------------------------------------
-- FREEROAM IS THE EXCEPTION, AND IT IS THE POINT
-- ----------------------------------------------------------------------------
--
-- `freeroam` is deliberately NOT in the default `spawnOwners` list, even though
-- it genuinely does own spawn: `forceOnJoin` drives an `applyJoinSpawn` that
-- kill/respawns every joiner at a fixed point, and it RETRIES that for up to
-- thirty seconds. Standing down for it would make this resource useless on the
-- one kind of server it is actually for -- a sandbox, where "log back in where
-- I left off" is precisely what a player expects.
--
-- Standing aside is not an option either: freeroam's retry loop answers
-- `transition_in_progress` while a restore is in flight and simply tries again
-- a quarter of a second later, so it would win any race regardless of who
-- started first.
--
-- So the two cooperate, and the division of labour is the one a sandbox player
-- expects rather than a compromise:
--
--   returning player with a fresh saved position -> this resource places them
--   first-timer, or an expired row, or a failure -> freeroam places them
--
-- The channel is the readiness gate, and specifically the note carried by a
-- release. When the last hold on a player is released, the host passes the
-- releasing resource's note through as the `detail` of `onPlayerReady`, which
-- is emitted into EVERY running resource. So `release(playerId, session,
-- "playerstate:restored")` becomes a fact freeroam can read without either
-- resource knowing the other exists -- which is the only shape available, since
-- server resources cannot call each other.
--
-- Two properties make this safe rather than clever:
--
--   * This resource only ever places a player once no OTHER hold remains (the
--     wait loop in restore.lua breaks on `others == 0`), so whenever it
--     restores somebody it is by construction the last releaser, and its note
--     is the detail freeroam sees.
--   * Every other outcome -- `nothing`, `expired`, `failed`, `abandoned` --
--     releases with a note freeroam does not recognise, so freeroam spawns the
--     player exactly as it always has. The fallback is the old behaviour, not
--     an error path.
--
-- On a server whose binary has no readiness gate, this resource is already in
-- record-only mode (see HAS_READY_GATE below) and freeroam's deferral is
-- skipped, so the pair behaves exactly as freeroam alone does today.
--
-- ============================================================================
-- THE HEADING ESTIMATE
-- ============================================================================
--
-- There is no live heading for a player server-side, and it is worth being
-- precise about why rather than looking for one later. `GetPlayerPosition`
-- resolves a `LootPlayerPosition`, which carries x, y, z and bucket and no
-- rotation at all. `getLifeState` DOES carry `yaw`, which looks like the
-- answer and is not: `PlayerLifeService` only ever writes Yaw as part of a
-- life transition, so it is the heading of the player's last spawn or death,
-- not the direction they are facing now.
--
-- The two remaining options were to have the client report its own heading, or
-- to estimate it. This estimates it, from the displacement between two
-- position samples one second apart: people run forwards, so a second of
-- travel is their facing direction. The conversion is the engine's own, and it
-- is the inverse of the one `resources/gamemodes/pursuit/server/match.lua` already uses:
-- yaw 0 is +Y, forward = (-sin y, cos y), so y = atan2(-dx, dy).
--
-- The estimate is wrong when somebody walks backwards or strafes into the
-- disconnect, and it is unavailable for a player who never moved. It is right
-- the overwhelming majority of the time, it costs one dictionary read per
-- tracked player per second and no database traffic at all, and -- the part
-- that decided it -- it keeps the client out of the loop entirely. This
-- resource accepts nothing from a client and declares no `network.events`,
-- so there is no claim to validate anywhere in it.
--
-- When no estimate is available, `heading_known` is 0 and restoration passes
-- the saved heading through anyway as 0. That is a direction rather than an
-- absence, but a spawn heading is arbitrary in a way a spawn POSITION is not,
-- and it costs a player one flick of the mouse.
--
-- ============================================================================
-- FILES
-- ============================================================================
--
--   server/config.lua    the tunable declaration and the invariants
--   server/main.lua      identity, database, policy, sampling, saving  (here)
--   server/restore.lua   the join path: the readiness gate and the placement
--
-- Split by FILE and not by resource, because server resources cannot call each
-- other; the two files share this VM through the `PlayerState` global built at
-- the bottom of this one. Load order is manifest order.

local Config = Open77PlayerStateConfig

-- Raises rather than returning nil on a malformed declaration, and that is
-- wanted: a resource that comes up on a value its own panel could never
-- restore is worse than one that refuses to start and says why.
local Tune = Open77.tunables.declare(Config.tunables)

local RESOURCE = GetCurrentResourceName()

local function log(text)
    print("[playerstate] " .. text)
end

local function nowMs()
    return math.floor(Open77.time.monotonic() * 1000)
end

-- Identifiers are user GUIDs. They are the right key and the wrong thing to
-- spray through a log, so diagnostics print a short prefix and the readable
-- name instead.
local function shortId(identifier)
    if type(identifier) ~= "string" then return "?" end
    return identifier:sub(1, 8)
end

-- playerId -> record. Rebuilt lazily: a reload gives a fresh VM with an empty
-- roster while the server is still full of connected people, and
-- `onPlayerConnected` does not re-fire for them.
local players = {}

-- ---------------------------------------------------------------- database --

local SCHEMA_SQL = [[
CREATE TABLE IF NOT EXISTS open77_playerstate_positions (
    user_id CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    character_key VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'default',
    name VARCHAR(64) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NOT NULL DEFAULT '',
    pos_x DOUBLE NOT NULL,
    pos_y DOUBLE NOT NULL,
    pos_z DOUBLE NOT NULL,
    heading DOUBLE NOT NULL DEFAULT 0,
    heading_known TINYINT(1) NOT NULL DEFAULT 0,
    bucket INT UNSIGNED NOT NULL DEFAULT 0,
    health DOUBLE NOT NULL DEFAULT 100,
    max_health DOUBLE NOT NULL DEFAULT 100,
    armor DOUBLE NOT NULL DEFAULT 0,
    saved_reason VARCHAR(24) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'autosave',
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (user_id, character_key)
) ENGINE=InnoDB
]]

-- Every statement in this file binds NAMED parameters and never a positional
-- `?`, and that is deliberate rather than stylistic. The bridge rewrites `?`
-- placeholders into real named parameters by scanning the statement, and that
-- scan has to reason about quoting and comments to know which `?` is genuinely
-- a placeholder. Named parameters skip the scan's hard part entirely. For the
-- same reason there is not one comment inside any SQL string here: comments in
-- SQL are exactly where that scan has been wrong before.
local UPSERT_SQL = [[
INSERT INTO open77_playerstate_positions
    (user_id, character_key, name, pos_x, pos_y, pos_z, heading, heading_known,
     bucket, health, max_health, armor, saved_reason)
VALUES
    (@user, @character, @name, @x, @y, @z, @heading, @headingKnown,
     @bucket, @health, @maxHealth, @armor, @reason)
ON DUPLICATE KEY UPDATE
    name = VALUES(name),
    pos_x = VALUES(pos_x), pos_y = VALUES(pos_y), pos_z = VALUES(pos_z),
    heading = VALUES(heading), heading_known = VALUES(heading_known),
    bucket = VALUES(bucket),
    health = VALUES(health), max_health = VALUES(max_health), armor = VALUES(armor),
    saved_reason = VALUES(saved_reason)
]]

local SELECT_SQL = [[
SELECT pos_x, pos_y, pos_z, heading, heading_known, bucket,
       health, max_health, armor, saved_reason,
       TIMESTAMPDIFF(SECOND, updated_at, NOW()) AS age_seconds
  FROM open77_playerstate_positions
 WHERE user_id = @user AND character_key = @character
 LIMIT 1
]]

local DELETE_SQL = [[
DELETE FROM open77_playerstate_positions
 WHERE user_id = @user AND character_key = @character
]]

-- nil until probed, then true or false for the rest of the run.
local dbReady = nil
local dbReason = "not probed"

-- There is no "is the database on?" question to ask. `MySQL` is installed by
-- the bootstrap whether or not the bridge is enabled, so testing the global
-- proves nothing; the first real statement is the probe. Coroutine only --
-- `.await` yields.
local function ensureSchema()
    if dbReady ~= nil then return dbReady end
    local ok, reason = pcall(function() MySQL.update.await(SCHEMA_SQL) end)
    if not ok then
        dbReady = false
        dbReason = tostring(reason)
        return false
    end
    dbReady = true
    dbReason = "ready"
    return true
end

-- ------------------------------------------------------------------ policy --

-- The readiness gate is what makes placing a joining player safe at all: it is
-- the only thing that can tell this resource nobody else still needs them. A
-- server whose binary predates it has no `Open77.ready` table, and calling into
-- one would take this resource down at load with a nil-index error naming a
-- line rather than a cause.
--
-- So it is detected once, here, and its absence downgrades the resource to
-- recording only. That is the same principle as the no-database path: refuse to
-- do the dangerous half, keep doing the useful half, and say which out loud.
-- Placing a player without the gate is exactly the collision that took the live
-- server down on 2026-08-27, so guessing is not an option.
local HAS_READY_GATE = type(Open77.ready) == "table"
    and type(Open77.ready.participate) == "function"
    and type(Open77.ready.status) == "function"
    and type(Open77.ready.hold) == "function"
    and type(Open77.ready.release) == "function"


local suppressedBy = nil     -- resource name currently claiming spawn, or nil
local announcedState = nil   -- last state announced, so the log says it once

local function spawnOwnerRunning()
    local raw = Tune.spawnOwners
    if type(raw) ~= "string" or raw == "" then return nil end
    for name in raw:gmatch("[^,%s]+") do
        if name ~= RESOURCE then
            local state = GetResourceState(name)
            -- "running" is the state string the host produces for a live
            -- resource (ResourceRuntimeState lowercased); "starting" is one
            -- tick away from it and counts, because a gamemode that is coming
            -- up will own spawn a moment from now.
            if state == "running" or state == "starting" then return name end
        end
    end
    return nil
end

-- The single answer to "should this resource do anything at all", recomputed
-- rather than cached because every input is a live tunable.
--
-- Returns: mode, detail
--   "off"      inert. Record nothing, restore nothing.
--   "save"     record state, never place anybody.
--   "full"     record state and restore it on join.
local function mode()
    if Tune.enabled ~= true then return "off", "disabled" end
    if dbReady == false then return "off", "no_database" end
    if not HAS_READY_GATE then return "save", "no_ready_gate" end
    local policy = Tune.spawnPolicy
    if policy == "always" then return "full", "policy_always" end
    if policy == "never" then return "save", "policy_never" end
    local owner = spawnOwnerRunning()
    suppressedBy = owner
    if owner ~= nil then return "off", "spawn_owned_by:" .. owner end
    return "full", "no_spawn_owner"
end

-- Say it once, and say it again only when it actually changes. A resource that
-- is quietly doing nothing is the worst possible failure here, because the
-- symptom -- "my position was not saved" -- is only visible hours later.
local function announce()
    local current, detail = mode()
    -- Before the schema probe has answered, `mode` is optimistic so that a
    -- joiner in the boot window is still handled; but announcing "ready" and
    -- then "no database" a moment later would be two lines that contradict each
    -- other. Stay quiet until the probe has settled the question.
    if dbReady == nil then return current, detail end
    local key = current .. ":" .. detail
    if key == announcedState then return current, detail end
    announcedState = key
    if current == "off" then
        if detail == "no_database" then
            log("no database configured -- saving and restoring are both off for this run (" ..
                dbReason .. ")")
        elseif detail == "disabled" then
            log("disabled by the `enabled` tunable -- nothing is recorded and nothing is restored")
        else
            log(("standing down: %s owns spawn on this server, so player state is neither " ..
                 "recorded nor restored. Change `spawnPolicy` or `spawnOwners` to override.")
                :format(tostring(suppressedBy)))
        end
    elseif current == "save" then
        if detail == "no_ready_gate" then
            log("this server has no join-time readiness gate (Open77.ready), so player " ..
                "state is RECORDED but never restored -- placing a joining player without " ..
                "the gate is not safe. Positions are being kept for when it is available.")
        else
            log("recording player state, but placement is off (`spawnPolicy` is `never`)")
        end
    else
        log(("ready: player state is recorded every %ds and restored on join (%s)")
            :format(Tune.autosaveSeconds, detail))
    end
    return current, detail
end

-- ----------------------------------------------------------------- records --

local function ensurePlayer(playerId)
    if playerId == nil or playerId <= 0 then return nil end
    local record = players[playerId]
    if record ~= nil then return record end
    local identifier = GetPlayerIdentifier(playerId)
    if type(identifier) ~= "string" or #identifier ~= 36 then
        -- Not authenticated, or gone between the event and this call. Nothing
        -- can be keyed, so nothing is tracked; the next event tries again.
        return nil
    end
    record = {
        playerId = playerId,
        identifier = identifier,
        name = GetPlayerName(playerId) or "",
        -- The write gate. FALSE until this resource knows that overwriting the
        -- stored row cannot destroy something it failed to give back. See
        -- setWritable and the table in restore.lua.
        mayWrite = false,
        restoreState = "pending",
        sample = nil,          -- last KNOWN-GOOD state, refreshed ~1 Hz
        lastPos = nil,         -- previous tick's position, for the heading
        lastWrite = nil,       -- position at the last successful database write
        heading = 0.0,
        headingKnown = false,
        joinedAtMs = nowMs(),
    }
    players[playerId] = record
    return record
end

-- The one place `mayWrite` is turned on, so the rule stays in one piece.
local function setWritable(record, why)
    if record == nil or record.mayWrite then return end
    record.mayWrite = true
    record.writableBecause = why
end

-- --------------------------------------------------------------- sampling --
--
-- A snapshot is taken only when the server can genuinely see the player, and a
-- moment when it cannot must FREEZE the last known-good sample rather than
-- overwrite it. During a respawn the replicated position is stale or absent
-- and the life phase is one of the *pending transitions; recording that would
-- mean a player who reconnects lands wherever the fade caught them, or
-- nowhere. Distinguish "here" from "cannot tell", never collapse the two.

local function isSettled(life)
    -- `isDead` is resolved natively from the enum and is immune to the
    -- client/server spelling split (`respawn_pending` vs `respawnpending`),
    -- but it does not separate `alive` from a transition, so the phase is
    -- still read -- with the underscore-free server spelling.
    if life == nil then return false end
    local phase = life.phase or ""
    return phase == "alive" or phase == "recovering"
end

local function sample(record)
    local playerId = record.playerId
    local position = Open77.players.position(playerId)
    local life = Open77.players.getLifeState(playerId)
    if position == nil or not isSettled(life) then
        -- Cannot tell. Freeze: keep the last good sample, and drop the heading
        -- baseline so the next reading is not differenced against a position
        -- from before a teleport.
        record.lastPos = nil
        return false
    end

    if record.lastPos ~= nil then
        local dx = position.x - record.lastPos.x
        local dy = position.y - record.lastPos.y
        if (dx * dx + dy * dy) >= (Config.headingMinMove * Config.headingMinMove) then
            -- yaw 0 = +Y, forward = (-sin y, cos y)  =>  y = atan2(-dx, dy).
            record.heading = math.deg(math.atan(-dx, dy))
            record.headingKnown = true
        end
    end
    record.lastPos = { x = position.x, y = position.y, z = position.z }

    local health = Open77.players.getHealth(playerId)
    record.sample = {
        x = position.x, y = position.y, z = position.z,
        bucket = position.bucket or 0,
        heading = record.heading,
        headingKnown = record.headingKnown,
        -- Absolute, 0..maxHealth, default 100. NOT the same scale as the
        -- fraction `respawn` takes; restore.lua converts.
        health = health and health.health or nil,
        maxHealth = health and health.maxHealth or nil,
        armor = health and health.armor or nil,
        atMs = nowMs(),
    }
    return true
end

-- --------------------------------------------------------------- writing --

local function valuesOf(record, reason)
    local s = record.sample
    local maxHealth = s.maxHealth
    if type(maxHealth) ~= "number" or maxHealth <= 0 then maxHealth = 100.0 end
    local health = s.health
    if type(health) ~= "number" then health = maxHealth end
    return {
        user = record.identifier,
        character = Config.characterKey,
        name = (record.name or ""):sub(1, 64),
        x = s.x, y = s.y, z = s.z,
        heading = s.heading or 0.0,
        headingKnown = s.headingKnown and 1 or 0,
        bucket = math.floor(s.bucket or 0),
        health = health,
        maxHealth = maxHealth,
        armor = type(s.armor) == "number" and s.armor or 0.0,
        reason = reason,
    }
end

local function movedEnough(record)
    local minimum = Tune.minMoveMetres
    if type(minimum) ~= "number" or minimum <= 0 then return true end
    local last = record.lastWrite
    if last == nil then return true end
    local s = record.sample
    local dx, dy, dz = s.x - last.x, s.y - last.y, s.z - last.z
    return (dx * dx + dy * dy + dz * dz) >= (minimum * minimum)
end

-- Batched into transactions because that is the batching primitive the bridge
-- offers: one round trip per chunk instead of one per player. Atomicity is not
-- what is wanted here -- these rows are independent -- but a rolled-back chunk
-- is harmless, because nothing is marked written until the commit reports
-- success and the next interval simply tries again.
local function flush()
    if not ensureSchema() then return 0 end
    local batch = {}
    for playerId, record in pairs(players) do
        if record.mayWrite and record.sample ~= nil and movedEnough(record) then
            batch[#batch + 1] = {
                playerId = playerId,
                identifier = record.identifier,
                mark = { x = record.sample.x, y = record.sample.y, z = record.sample.z },
                statement = { query = UPSERT_SQL, values = valuesOf(record, "autosave") },
            }
        end
    end
    if #batch == 0 then return 0 end

    local written = 0
    local index = 1
    while index <= #batch do
        local statements = {}
        local slice = {}
        for offset = index, math.min(index + Config.flushChunk - 1, #batch) do
            statements[#statements + 1] = batch[offset].statement
            slice[#slice + 1] = batch[offset]
        end
        index = index + #slice

        local ok, committed, reason = pcall(function()
            return MySQL.transaction.await(statements)
        end)
        if not ok then
            log("autosave failed: " .. tostring(committed))
        elseif committed ~= true then
            log("autosave rolled back: " .. tostring(reason))
        else
            for _, entry in ipairs(slice) do
                -- The roster can have changed across the await. Only mark a
                -- record that is still the same player on the same id.
                local record = players[entry.playerId]
                if record ~= nil and record.identifier == entry.identifier then
                    record.lastWrite = entry.mark
                end
                written = written + 1
            end
        end
    end
    return written
end

-- One row, now. Used by the disconnect path and the `playerstate.save` command.
local function writeOne(record, reason)
    if not ensureSchema() then return false, dbReason end
    if record.sample == nil then return false, "no_sample" end
    local ok, err = pcall(function()
        MySQL.update.await(UPSERT_SQL, valuesOf(record, reason))
    end)
    if not ok then return false, tostring(err) end
    record.lastWrite = { x = record.sample.x, y = record.sample.y, z = record.sample.z }
    return true
end

local function dbState()
    return dbReady, dbReason
end

local function loadRow(identifier)
    if not ensureSchema() then return nil, dbReason end
    local ok, row = pcall(function()
        return MySQL.single.await(SELECT_SQL, {
            user = identifier, character = Config.characterKey,
        })
    end)
    if not ok then return nil, tostring(row) end
    return row
end

local function forget(identifier)
    if not ensureSchema() then return false, dbReason end
    local ok, err = pcall(function()
        MySQL.update.await(DELETE_SQL, { user = identifier, character = Config.characterKey })
    end)
    if not ok then return false, tostring(err) end
    return true
end

-- --------------------------------------------------------------- lifecycle --

AddEventHandler("onPlayerConnected", function(playerIdStr, name)
    -- Host events carry strings. Skip the tonumber and the table keys silently
    -- diverge from the numeric ids used everywhere else.
    local playerId = tonumber(playerIdStr)
    if playerId == nil or playerId <= 0 then return end
    if announce() == "off" then return end
    local record = ensurePlayer(playerId)
    if record == nil then return end
    if type(name) == "string" and name ~= "" then record.name = name end
end)

AddEventHandler("onPlayerDisconnected", function(playerIdStr)
    local playerId = tonumber(playerIdStr)
    if playerId == nil then return end
    local record = players[playerId]
    players[playerId] = nil
    if record == nil then return end

    if not record.mayWrite then
        -- The single most important guard in this resource.
        --
        -- A player whose restoration never landed is standing wherever the
        -- default spawn put them, which is NOT where they were when they left
        -- last time. Writing that would overwrite the very row the restore
        -- failed to deliver -- so a bad evening becomes permanent data loss,
        -- and it becomes it silently. When in doubt, keep what is stored.
        log(("%s (%d) left before their state was settled (%s); the saved row is left alone")
            :format(record.name, playerId, tostring(record.restoreState)))
        return
    end

    -- Best-effort last look. At this point the session is usually already gone
    -- and both reads return nil, which is exactly why the ~1 Hz sample above
    -- is the real mechanism: it is at most one second old here.
    sample(record)
    if record.sample == nil then return end

    CreateThread(function()
        local ok, reason = writeOne(record, "disconnect")
        if ok then
            log(("saved %s (%s) at %.1f %.1f %.1f"):format(
                record.name, shortId(record.identifier),
                record.sample.x, record.sample.y, record.sample.z))
        else
            log(("save FAILED for %s (%s): %s"):format(
                record.name, shortId(record.identifier), tostring(reason)))
        end
    end)
end)

-- Re-declaring is how a live change to the hold budget reaches the gate: the
-- declaration is per-resource and the newest one wins.
AddEventHandler("onTunableChanged", function(key)
    if key == "readyTimeoutSeconds" and PlayerState.participate ~= nil then
        PlayerState.participate()
    end
    if key == "enabled" or key == "spawnPolicy" or key == "spawnOwners" then
        announce()
    end
end)

-- ------------------------------------------------------------------ ticker --
--
-- One thread, two cadences. The fast one keeps an in-memory snapshot at most a
-- second old and costs no database traffic at all; the slow one is the only
-- thing that writes. Consequence worth knowing: a graceful disconnect saves a
-- position about a second stale, and only a server that is killed rather than
-- stopped falls back to the last autosave.
CreateThread(function()
    local nextFlushAtMs = nowMs() + 5000
    while true do
        Wait(Config.headingTickMs)
        if announce() ~= "off" then
            for _, record in pairs(players) do
                sample(record)
            end
            if nowMs() >= nextFlushAtMs then
                local interval = Tune.autosaveSeconds
                if type(interval) ~= "number" or interval < 15 then interval = 60 end
                nextFlushAtMs = nowMs() + math.floor(interval * 1000)
                local ok, written = pcall(flush)
                if not ok then log("autosave raised: " .. tostring(written)) end
            end
        end
    end
end)

-- ---------------------------------------------------------------- commands --
--
-- "Nothing happened when I reconnected" is the symptom this feature produces
-- when it goes wrong, and from every other angle it is invisible: the player
-- is connected, the world is up, and every resource is correctly doing what it
-- thinks it should. So print what the SERVER sees, early and in one line.

-- All four are registered restricted, so the dispatcher has already checked a
-- player source against the `command.<name>` ACL by the time a handler runs;
-- the server console is always allowed. They are restricted rather than open
-- because their output names user identifiers, and because two of them write.
RegisterCommand("playerstate", function(source)
    local current, detail = mode()
    print(("[playerstate] mode=%s (%s) database=%s policy=%s autosave=%ds expiry=%dh")
        :format(current, detail,
            dbReady == nil and "unprobed" or (dbReady and "ready" or dbReason),
            tostring(Tune.spawnPolicy), Tune.autosaveSeconds, Tune.expiryHours))
    local count = 0
    for playerId, record in pairs(players) do
        count = count + 1
        local s = record.sample
        print(("[playerstate]   %d %s (%s) restore=%s writable=%s sample=%s")
            :format(playerId, record.name, shortId(record.identifier),
                tostring(record.restoreState), tostring(record.mayWrite),
                s and ("%.1f %.1f %.1f"):format(s.x, s.y, s.z) or "none"))
    end
    if count == 0 then print("[playerstate]   no players tracked") end
end, true)

RegisterCommand("playerstate.where", function(source, args)
    local playerId = tonumber(args and args[1])
    local record = playerId and players[playerId] or nil
    if record == nil then print("[playerstate] usage: playerstate.where <playerId>") return end
    local life = Open77.players.getLifeState(playerId)
    local position = Open77.players.position(playerId)
    print(("[playerstate] %d %s phase=%s settled=%s position=%s heading=%s(%s) restore=%s writable=%s")
        :format(playerId, record.name,
            life and tostring(life.phase) or "nil", tostring(isSettled(life)),
            position and ("%.1f %.1f %.1f b%d"):format(
                position.x, position.y, position.z, position.bucket or 0) or "unreadable",
            ("%.1f"):format(record.heading), tostring(record.headingKnown),
            tostring(record.restoreState), tostring(record.mayWrite)))
    CreateThread(function()
        local row = loadRow(record.identifier)
        if row == nil then print("[playerstate]   stored: nothing") return end
        print(("[playerstate]   stored: %.1f %.1f %.1f heading=%.1f health=%.0f/%.0f armor=%.0f age=%ds reason=%s")
            :format(row.pos_x, row.pos_y, row.pos_z, row.heading or 0,
                row.health or 0, row.max_health or 0, row.armor or 0,
                row.age_seconds or -1, tostring(row.saved_reason)))
    end)
end, true)

RegisterCommand("playerstate.save", function(source, args)
    local playerId = tonumber(args and args[1])
    local record = playerId and players[playerId] or nil
    if record == nil then print("[playerstate] usage: playerstate.save <playerId>") return end
    sample(record)
    setWritable(record, "operator_forced")
    CreateThread(function()
        local ok, reason = writeOne(record, "manual")
        print("[playerstate] manual save " .. (ok and "ok" or ("failed: " .. tostring(reason))))
    end)
end, true)

-- Reload recovery.
--
-- A reload gives a fresh VM with an empty roster while the server is still full
-- of connected people, and `onPlayerConnected` does not re-fire for them. The
-- platform's usual answer -- repopulate lazily from the next event each player
-- produces -- is not available here: this resource subscribes to no client
-- events by design, and there is no way to list players. `Open77.players` has
-- name, identifier, position and life, but no `all()`, and player ids are
-- allocated monotonically per connection rather than from a slot table, so
-- there is no bounded range to sweep either.
--
-- So the gap is real and this is the recovery path: adopt one connected player
-- into the roster by id. An adopted player is writable immediately -- they are
-- already standing somewhere under their own steam, so their current position
-- is genuine and there is no restoration that could have failed to deliver.
RegisterCommand("playerstate.track", function(source, args)
    local playerId = tonumber(args and args[1])
    if playerId == nil then print("[playerstate] usage: playerstate.track <playerId>") return end
    if players[playerId] ~= nil then print("[playerstate] already tracked") return end
    local record = ensurePlayer(playerId)
    if record == nil then print("[playerstate] no such connected player") return end
    record.restoreState = "adopted"
    setWritable(record, "adopted_after_reload")
    sample(record)
    print(("[playerstate] tracking %d %s (%s)"):format(
        playerId, record.name, record.sample and "sampled" or "not yet in world"))
end, true)

RegisterCommand("playerstate.forget", function(source, args)
    local playerId = tonumber(args and args[1])
    local record = playerId and players[playerId] or nil
    if record == nil then print("[playerstate] usage: playerstate.forget <playerId>") return end
    local identifier = record.identifier
    -- Stop the ticker putting it straight back.
    record.mayWrite = false
    record.sample = nil
    CreateThread(function()
        local ok, reason = forget(identifier)
        print("[playerstate] forget " .. (ok and "ok" or ("failed: " .. tostring(reason))))
    end)
end, true)

-- ------------------------------------------------------------------- shared --
--
-- Server resources cannot call each other, so this global is how the two files
-- of THIS resource share a VM. It is not an export and nothing outside this
-- resource can reach it.
PlayerState = {
    Config = Config,
    Tune = Tune,
    resource = RESOURCE,
    players = players,
    log = log,
    nowMs = nowMs,
    shortId = shortId,
    mode = mode,
    announce = announce,
    dbState = dbState,
    hasReadyGate = HAS_READY_GATE,
    ensurePlayer = ensurePlayer,
    setWritable = setWritable,
    isSettled = isSettled,
    sample = sample,
    loadRow = loadRow,
    writeOne = writeOne,
    forget = forget,
}

CreateThread(function()
    -- Probe the bridge by putting the schema up, then say the one line that
    -- tells an operator which of the three modes they are in.
    ensureSchema()
    local current = announce()
    if current ~= "off" then
        log("note: players already connected are not tracked until they reconnect " ..
            "(a fresh VM has an empty roster and onPlayerConnected does not re-fire). " ..
            "`playerstate.track <playerId>` adopts one now.")
    end
end)
