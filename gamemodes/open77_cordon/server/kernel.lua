-- The Cordon kernel: the global every other server file reaches through, the
-- roster, the buckets, and the one placement primitive.
--
-- Server resources cannot link to each other, so this global IS the module
-- system. Every file adds to it; nothing outside this resource can see it.

Cordon = Cordon or {}

local K = Cordon

K.version = "0.1.0"

-- ---------------------------------------------------------------------------
-- Time. Open77.time.monotonic() is seconds as a float; everything in the mode
-- reasons in integer milliseconds, so there is exactly one conversion and it
-- lives here.
-- ---------------------------------------------------------------------------
function K.nowMs()
    local ok, seconds = pcall(Open77.time.monotonic)
    if not ok or type(seconds) ~= "number" then return 0 end
    return math.floor(seconds * 1000.0)
end

function K.log(text)
    print("[cordon] " .. tostring(text))
end

function K.warn(text)
    print("[cordon] WARN " .. tostring(text))
end

-- ---------------------------------------------------------------------------
-- THE ROSTER, AND WHY IT IS REPOPULATED LAZILY.
--
-- There is no player enumeration API: `Open77.players` has name, identifier and
-- position but no all()/list(). A resource reload gives a fresh Lua VM with an
-- empty roster while the server is still full, and `onPlayerConnected` does NOT
-- re-fire for players who were already here. So the roster is rebuilt from the
-- NEXT event each player produces: every entry point that carries a player id
-- calls ensure() first. Miss one and that player is invisible to the mode for
-- the rest of their session.
--
-- Player ids arrive from host events as STRINGS. tonumber at every door, or a
-- string key silently diverges from the numeric ids used everywhere else and
-- the same player occupies two rows.
-- ---------------------------------------------------------------------------
K.players = {}    -- [playerId] = record
K.count = 0

local function newRecord(playerId)
    return {
        id = playerId,
        bot = playerId < 0,
        joinedAtMs = K.nowMs(),
        identifier = nil,       -- captured eagerly; see below
        name = nil,
        state = "lobby",        -- lobby | staging | deploying | alive | dead | spectating
        squad = nil,
        placement = nil,
        kills = 0,
        assists = 0,
        damage = 0.0,
        revives = 0,
        plates = 0,
        heals = 0,
        shieldUntilMs = 0,
        outsideSamples = 0,
        outsideSinceMs = nil,
        lastCell = nil,
        deathAtMs = nil,
        -- THE ELIMINATION. `dead` is the body, still where it fell and possibly
        -- revivable; `spectating` is what it becomes once nobody is coming --
        -- standing in the lobby bucket, unarmed, watching the match it is no
        -- longer in. server/match.lua owns the transition and explains why the
        -- watch is in staging rather than in the air.
        eliminatedAtMs = nil,   -- when the watch began; nil until it does
        spectateAttempts = nil, -- refused placements, so the retry can be throttled
        weapons = {},           -- [tweakDbId] = slot, the VERIFIED set the arbiter honours
        -- THE DROP. `drop` is nil except between the release and the touchdown;
        -- it is a whole table rather than three fields so that "is this player
        -- falling" is one nil test, and so that clearing it is one assignment
        -- that cannot half-clear.
        drop = nil,             -- { id, ground, deadlineMs, releasedAtMs }
        dropSequence = 0,       -- monotonic; a late callback for drop n-1 is ignored
    }
end

--- The lazy-adoption door. Call it at EVERY entry point that carries an id.
function K.ensure(playerId)
    local id = tonumber(playerId)
    if id == nil or id == 0 then return nil end
    local record = K.players[id]
    if record == nil then
        record = newRecord(id)
        K.players[id] = record
        K.count = K.count + 1
        -- Identity is captured EAGERLY, here, because Open77.players.identifier
        -- returns nil for somebody who has already left — and a player who
        -- disconnects mid-match is exactly the case the ladder most needs to
        -- attribute. Bots have no identity and must never be asked: five player
        -- bindings RAISE on a non-positive id rather than returning nil.
        if id > 0 then
            local ok, identifier = pcall(Open77.players.identifier, id)
            if ok then record.identifier = identifier end
            local named, name = pcall(Open77.players.name, id)
            if named then record.name = name end
        else
            record.name = "BOT-" .. tostring(-id)
        end
    end
    return record
end

function K.forget(playerId)
    local id = tonumber(playerId)
    if id == nil then return end
    if K.players[id] ~= nil then
        -- A player who disconnects mid-descent still owns a god-mode entry in
        -- the combat ledger. The platform drops it with the session, but a
        -- reconnect that lands on the same player id would inherit it, so the
        -- drop is closed here rather than trusted to the teardown.
        if K.players[id].drop ~= nil then K.endDrop(id, "forgotten") end
        K.players[id] = nil
        K.count = math.max(0, K.count - 1)
    end
end

--- Every human in the roster. Kept separate from `K.players` on purpose: bot
--- ids are NEGATIVE and five player bindings raise on a non-positive id, so any
--- loop that touches a player API must iterate this and not the roster.
function K.humans()
    local list = {}
    for id, record in pairs(K.players) do
        if id > 0 then list[#list + 1] = record end
    end
    return list
end

--- Every bot in the roster. Named `botRecords` and NOT `bots`, because
--- `K.bots` is the bots MODULE — server/bots.lua assigns a table there, and a
--- function of the same name is silently replaced at load. The symptom was
--- `attempt to call a table value (field 'bots')` from the state push, one
--- level away from the collision that caused it.
function K.botRecords()
    local list = {}
    for id, record in pairs(K.players) do
        if id < 0 then list[#list + 1] = record end
    end
    return list
end

--- Bots still standing. Distinct from `#K.botRecords()`, which counts every bot
--- row the match ever had, dead ones included — see the state push in main.lua
--- for the symptom that distinction fixed.
function K.aliveBotCount()
    local n = 0
    for id, record in pairs(K.players) do
        if id < 0 and record.state == "alive" then n = n + 1 end
    end
    return n
end

-- ---------------------------------------------------------------------------
-- WEAPON IDS: ONE SPELLING, BECAUSE THE PLATFORM SHIPS THREE.
--
-- A TweakDB id is a 64-bit hash and a Lua number holds 53 integer bits, so it
-- travels as a STRING — and every producer spells that string differently.
-- Measured 2026-09-02, all three arriving in THIS resource for one Lexington:
--
--   open77:weapons:completed -> result.tweakDbId     0x0000001C5520EA68
--       client/src/api/ScriptBridge.cpp:439  std::format("0x{:016X}")
--   cordon:npcHit            -> weaponTdbId          0x1C5520EA68
--       client/src/network/CombatReplication.cpp:882  snprintf("0x%llX")
--   the damage arbiter       -> event.weaponTdbId    0x1c5520ea68
--       Open77.Server.Scripting/Runtime/LuaResourceRuntime.cs:2592  $"0x{..:x}"
--
-- The mode stored the FIRST and looked the second and third up in that table
-- with a raw key, so nothing could ever match. Both gates that depend on it are
-- fail-closed, which is right, and both were therefore silently closed for
-- every player carrying a looted gun: `bots.lua` refused every shot at a bot
-- with `weapon_unverified 0x1C5520EA68`, and the arbiter refused every
-- player-versus-player hit the moment a player picked anything up.
--
-- The canonical form is open77_deathmatch's, adopted unchanged from
-- `open77_deathmatch/server/loadout.lua:129`: lowercase, "0x", leading zeroes
-- stripped. Comparing two strings only works if ONE function decides how they
-- are spelled.
-- ---------------------------------------------------------------------------
function K.weaponId(value)
    if value == nil then return "" end
    local digits = string.lower(tostring(value)):match("^0x([0-9a-f]+)$")
    if digits == nil then return "" end
    digits = digits:gsub("^0+", "")
    -- "0x0" is what the client emits for a hit that named no weapon — a fist, a
    -- melee swing, an explosion. It is a real report, but it is not a weapon
    -- this mode issued, so it normalises to nothing and every ledger lookup on
    -- it fails closed rather than matching some other player's empty slot.
    if digits == "" then return "" end
    return "0x" .. digits
end

--- Whether `reported` names a weapon this match verified for `record`.
---
--- Both sides are normalised AT THE POINT OF COMPARISON rather than trusting
--- the ledger's spelling. The set can be rebuilt from a carry written by an
--- older VM, or by a future platform build that changes one of the three
--- formats above, and a gate whose correctness depends on how somebody else
--- spelled a key is a gate that breaks on the next hot reload. Three entries is
--- the whole set; scanning it costs nothing.
---
--- FAIL-CLOSED: an empty set matches nothing, and an unreadable id matches
--- nothing. Whether an EMPTY set should be allowed to fire at all is the
--- caller's decision, not this function's — the arbiter and the bot bridge
--- answer it differently and both are documented where they do.
function K.weaponVerified(record, reported)
    if record == nil then return false end
    local wanted = K.weaponId(reported)
    if wanted == "" then return false end
    for key in pairs(record.weapons or {}) do
        if K.weaponId(key) == wanted then return true end
    end
    return false
end

function K.alive()
    local list = {}
    for _, record in pairs(K.players) do
        if record.state == "alive" then list[#list + 1] = record end
    end
    return list
end

-- ---------------------------------------------------------------------------
-- READS THAT NEVER RAISE.
--
-- `players.name`, `.position`, `.identifier`, `ready.isReady` and the routing
-- bucket setters all raise on a non-positive id. The mode is full of negative
-- bot ids, so every one of those calls is wrapped exactly once, here, and
-- nowhere else in the resource reaches the raw binding.
-- ---------------------------------------------------------------------------
function K.position(playerId)
    local id = tonumber(playerId)
    if id == nil or id <= 0 then
        local record = K.players[id or 0]
        -- A bot's position is whatever the NPC layer last published for it.
        if record ~= nil and record.botPosition ~= nil then return record.botPosition end
        return nil
    end
    local ok, position = pcall(Open77.players.position, id)
    if not ok or position == nil then return nil end
    return {
        x = tonumber(position.x) or 0.0,
        y = tonumber(position.y) or 0.0,
        z = tonumber(position.z) or 0.0,
        bucket = tonumber(position.bucket) or 0,
        yaw = tonumber(position.yaw),
    }
end

function K.name(playerId)
    local id = tonumber(playerId)
    local record = K.players[id or 0]
    if record ~= nil and record.name ~= nil then return record.name end
    if id == nil or id <= 0 then return "BOT" end
    local ok, name = pcall(Open77.players.name, id)
    if ok and name ~= nil then return name end
    return "player " .. tostring(id)
end

function K.isReady(playerId)
    local id = tonumber(playerId)
    if id == nil or id <= 0 then return true end   -- a bot is always ready
    if type(Open77.ready) ~= "table" or type(Open77.ready.isReady) ~= "function" then return true end
    local ok, ready = pcall(Open77.ready.isReady, id)
    return ok and ready == true
end

function K.lifePhase(playerId)
    local id = tonumber(playerId)
    if id == nil or id <= 0 then return "alive" end
    local ok, life = pcall(Open77.players.getLifeState, id)
    if not ok or life == nil then return "unknown" end
    -- The phase is spelled differently by the two hosts (respawn_pending on the
    -- client, respawnpending on the server), so never compare the string when
    -- isDead() answers the question.
    return tostring(life.phase)
end

function K.setBucket(playerId, bucket)
    local id = tonumber(playerId)
    if id == nil or id <= 0 then return false end
    local ok, moved = pcall(SetPlayerRoutingBucket, id, bucket)
    return ok and moved ~= false
end

-- ---------------------------------------------------------------------------
-- BUCKETS. Staging and the match are separate network dimensions so a staging
-- player cannot see, hear or shoot into a live match. Population is disabled
-- and entity lockdown relaxed in both, which is what empties Pacifica of
-- ambient traffic and crowds — and in Pacifica an empty street reads as canon
-- rather than as a broken server, which is half the reason for the district.
-- ---------------------------------------------------------------------------
function K.prepareBucket(bucket)
    pcall(SetRoutingBucketPopulationEnabled, bucket, false)
    pcall(SetRoutingBucketEntityLockdownMode, bucket, "relaxed")
end

function K.stagingBucket()
    return (Config and Config.buckets and Config.buckets.staging) or 4300
end

function K.matchBucket()
    return (Config and Config.buckets and Config.buckets.match) or 4301
end

-- ---------------------------------------------------------------------------
-- THE PLACEMENT PRIMITIVE. Every move a player makes in this mode goes through
-- here, and it is a kill followed by a respawn — never a raw transform write.
--
-- The reason is not ceremony: a direct teleport over distance drops the player
-- into unstreamed world, while the respawn transaction carries the fade and the
-- streaming preload. The cost is that EVERY PLACEMENT IS A DEATH, so the death
-- rule must reject its own tag, and both ledgers are told to ignore it first.
--
-- Measured 2026-09-02 (E3): a player respawned above the ground FALLS AND DIES,
-- and god mode did not save them. The reason was NOT that "fall damage bypasses
-- the god mode gates" — that reading was wrong and cost the mode its aerial
-- insertion for a week. Fall damage is a self-targeted ATTACK resolved by the
-- ordinary DamageSystem, and the client's shield was `Immortal`, which does not
-- block an attack: it floors the health pool at ~1%, which the server's
-- lethality test reads as a death the client then reported itself.
--
-- Both halves are closed now (`Api::Life::SetFallShield` installs
-- `Invulnerable`; `ObserveDeathIntent` refuses an intent from a god-moded
-- player), and `K.dropTo` below is the one sanctioned way to place somebody in
-- the air. THIS function still places at ground level and nothing else: an
-- ordinary placement that happens to be above the floor is still a bug.
-- ---------------------------------------------------------------------------
K.suppressedDeaths = {}   -- [playerId] = untilMs

function K.suppressDeath(playerId, forMs)
    local id = tonumber(playerId)
    if id == nil then return end
    K.suppressedDeaths[id] = K.nowMs() + (forMs or 2500)
end

function K.deathSuppressed(playerId)
    local id = tonumber(playerId)
    if id == nil then return false end
    local until_ = K.suppressedDeaths[id]
    if until_ == nil then return false end
    if K.nowMs() > until_ then
        K.suppressedDeaths[id] = nil
        return false
    end
    return true
end

--- Place a player at a point. Returns ok, reason.
function K.placeAt(playerId, position, bucket, options)
    local id = tonumber(playerId)
    if id == nil or id <= 0 then return false, "not_a_player" end
    if position == nil then return false, "no_position" end
    options = options or {}

    local graceMs = options.graceMs or 3000
    K.suppressDeath(id, graceMs + 1500)

    local phase = K.lifePhase(id)
    if phase == "alive" or phase == "recovering" then
        local killed, reason = Open77.players.kill(id, {
            cause = "script",
            weapon = "cordon:" .. tostring(options.reason or "place"),
        })
        if not killed then return false, tostring(reason) end
    elseif phase ~= "dead" then
        return false, "transition_in_progress:" .. phase
    end

    local ok, reason = Open77.players.respawn(id, {
        position = { x = position.x, y = position.y, z = position.z },
        heading = options.heading or 0.0,
        bucket = bucket,
        health = 1.0,
        graceMs = graceMs,
    })
    if not ok then return false, tostring(reason) end

    -- Armor and regeneration are the mode's to grant, never the save's.
    pcall(Open77.players.setArmor, id, options.armor or 0)
    pcall(Open77.players.setRegen, id, 0)

    local record = K.ensure(id)
    if record ~= nil then
        record.lastCell = nil
        record.outsideSamples = 0
        record.outsideSinceMs = nil
        if options.shieldMs ~= nil and options.shieldMs > 0 then
            -- Spawn protection is the GAMEMODE'S to enforce. `Recovering` is
            -- NOT invulnerable — IsCombatCapable treats it as Alive and Kill
            -- permits it — and the platform's only real shield is god mode,
            -- which this mode reserves for nothing. So the arbiter checks this
            -- timestamp, and any shield the HUD advertises is this one.
            record.shieldUntilMs = K.nowMs() + options.shieldMs
        end
    end
    return true
end

function K.shielded(playerId)
    local record = K.players[tonumber(playerId) or 0]
    if record == nil then return false end
    return K.nowMs() < (record.shieldUntilMs or 0)
end

--- Break a player's own shield when they act aggressively. A shield that
--- survives your first shot is a shield you can camp behind.
function K.breakShield(playerId)
    local record = K.players[tonumber(playerId) or 0]
    if record ~= nil then record.shieldUntilMs = 0 end
end

-- ---------------------------------------------------------------------------
-- THE DROP. The aerial insertion, and the guard that makes it safe to ship.
--
-- Two shields ride a descent and they answer different questions:
--
--   * the SERVER'S god mode is the authoritative one. It is what stops the
--     landing attack from ever being credited, and — since the platform fix of
--     2026-09-02 — what makes the server refuse a death intent the falling
--     client reports about itself. Without that second half a god-moded player
--     still died: the client's `Immortal` barrier floored health at ~1%, which
--     the lethality test accepted;
--   * the CLIENT'S chute is what makes the descent survivable in the first
--     place, by lowering the real impact speed under the engine's own landing
--     thresholds so no attack is fired at all.
--
-- THE MODE MUST NEVER WAIT ON A CLIENT, and that is what `deadlineMs` is for.
-- A client that never reports its touchdown — an old build, a resource that
-- failed to start, a player who alt-tabbed for the whole descent — is placed on
-- the ground by `K.tickDrops` and the match carries on. That fallback is not a
-- new code path: it is `K.placeAt` on the same landing zone, which is exactly
-- what the mode did before the drop existed.
-- ---------------------------------------------------------------------------
local function dropConfig()
    return (Config and Config.match and Config.match.drop) or {}
end

local function number(value, fallback)
    local n = tonumber(value)
    if n == nil or n ~= n then return fallback end
    return n
end

--- The landing grace, in milliseconds. Declared since the first draft of the
--- config and finally reachable: it is what a player is granted at touchdown,
--- on top of whatever remains of the deploy shield.
function K.landingGraceMs()
    local seconds = number(
        Config and Config.spawnProtection and Config.spawnProtection.landingGraceSeconds, 1.0)
    if seconds < 0 then seconds = 0 end
    if seconds > 30 then seconds = 30 end
    return math.floor(seconds * 1000)
end

--- Whether this match drops or stands. The tunable wins so an operator can turn
--- the drop off from the panel without a redeploy; a non-positive altitude
--- turns it off too, because a drop from zero metres is a placement with extra
--- machinery and a landing report that may never come.
function K.dropEnabled()
    local cfg = dropConfig()
    if K.tune("drop", cfg.enabled == true) ~= true then return false end
    return number(cfg.altitudeMetres, 0) > 0
end

--- Release a player into the air above `ground`. Returns ok, reason.
---
--- `ground` is the point the fallback will use, so it must be the surveyed
--- landing zone and not the raised point: everything the guard needs is
--- captured here, at the one moment we are certain of it.
function K.dropTo(playerId, ground, bucket, options)
    local id = tonumber(playerId)
    if id == nil or id <= 0 then return false, "not_a_player" end
    if ground == nil then return false, "no_position" end
    options = options or {}
    local cfg = dropConfig()

    local timeout = number(cfg.landingTimeoutSeconds, 60.0)
    if timeout < 5 then timeout = 5 end
    if timeout > 300 then timeout = 300 end
    local timeoutMs = math.floor(timeout * 1000)

    local altitude = number(cfg.altitudeMetres, 250.0)
    local above = { x = ground.x, y = ground.y, z = ground.z + altitude }
    -- The deploy shield is stretched to cover the WHOLE descent rather than the
    -- four seconds it was sized for on a stand-up spawn. `Config.spawnProtection`
    -- has always read "4 s at deploy, OR until landing + 1 s"; on the ground
    -- those were the same sentence, and in the air they are not. Without this
    -- the HUD's shield indicator would blink out halfway down for no reason a
    -- player could name.
    local shieldMs = math.max(tonumber(options.shieldMs) or 0, timeoutMs)
    local ok, reason = K.placeAt(id, above, bucket, {
        reason = options.reason or "drop",
        graceMs = options.graceMs or 3000,
        shieldMs = shieldMs,
        heading = options.heading,
        armor = options.armor,
    })
    if not ok then return false, reason end

    local record = K.ensure(id)
    if record == nil then return false, "no_record" end

    -- The authoritative shield goes on AFTER the placement, never before: a
    -- placement that failed must not leave a god-moded player standing in the
    -- lobby, and the placement itself is a kill/respawn transaction that god
    -- mode does not gate (only client-reported deaths are refused).
    pcall(Open77.players.setGodMode, id, true)

    record.dropSequence = (record.dropSequence or 0) + 1
    record.drop = {
        id = record.dropSequence,
        ground = { x = ground.x, y = ground.y, z = ground.z },
        bucket = bucket,
        releasedAtMs = K.nowMs(),
        deadlineMs = K.nowMs() + timeoutMs,
    }

    TriggerClientEvent("cordon:chute", id, {
        armed = true,
        gravity = number(cfg.gravity, -4.0),
        descentRate = number(cfg.descentRateMetresPerSecond, 8.0),
        glideSpeed = number(cfg.glideSpeedMetresPerSecond, 0.0),
        ground = record.drop.ground,
        -- The client runs its own copy of the deadline so that a client whose
        -- touchdown detection never fires still disarms its chute and gives the
        -- player back a normal body, instead of gliding for the rest of the
        -- match. Slightly shorter than ours on purpose: the client should be
        -- the one to give up first, so its report still arrives before the
        -- server stops listening.
        timeoutMs = math.max(1000, timeoutMs - 2000),
    })
    return true
end

--- Close a descent, whatever ended it. Idempotent, and the ONLY place the
--- authoritative shield comes off, so every exit — a touchdown, the timeout, a
--- disconnect, an aborted match — leaves the same state behind.
function K.endDrop(playerId, reason)
    local id = tonumber(playerId)
    if id == nil then return nil end
    local record = K.players[id]
    if record == nil or record.drop == nil then return nil end
    local drop = record.drop
    record.drop = nil

    pcall(Open77.players.setGodMode, id, false)
    -- SET, not extend. The descent shield was stretched to the landing deadline
    -- in `K.dropTo`, and carrying that remainder past the touchdown would hand a
    -- player who landed fast a minute of invulnerability. The config's rule is
    -- "until landing + 1 s", so landing is where the descent shield ends and the
    -- landing grace — the whole of it, however early the touchdown — begins.
    record.shieldUntilMs = K.nowMs() + K.landingGraceMs()
    TriggerClientEvent("cordon:chute", id, { armed = false })
    K.log(("drop: player %d ended after %d ms (%s)"):format(
        id, K.nowMs() - (drop.releasedAtMs or K.nowMs()), tostring(reason)))
    return drop
end

--- Abandon a descent and stand the player on the ground themselves.
---
--- Today's behaviour, unchanged and deliberately so: this is the same call the
--- mode made before the drop existed, on the same surveyed point. The worst
--- outcome of the whole feature is a player who is simply standing where they
--- would have stood. Both failure routes — the deadline, and a client that says
--- outright that it cannot fly — end here, so there is one fallback to test.
function K.dropFallback(playerId, reason)
    local id = tonumber(playerId)
    if id == nil then return false end
    local record = K.players[id]
    if record == nil or record.drop == nil then return false end
    local drop = record.drop
    K.warn(("drop: player %d did not land under its own power after %d ms (%s) — placing on " ..
        "the ground at the landing zone"):format(
        id, K.nowMs() - (drop.releasedAtMs or K.nowMs()), tostring(reason)))
    K.endDrop(id, reason)
    return K.placeAt(id, drop.ground, drop.bucket, {
        reason = "drop_fallback",
        graceMs = 3000,
        shieldMs = K.landingGraceMs(),
    })
end

--- The guard. Runs every tick, in every phase — a match aborted mid-descent
--- must still land its players rather than leave them falling with god mode on.
function K.tickDrops()
    local now = K.nowMs()
    for id, record in pairs(K.players) do
        local drop = record.drop
        if drop ~= nil and now >= drop.deadlineMs then
            K.dropFallback(id, "timeout")
        end
    end
end

--- Whether a reported touchdown is plausible. A client claiming to have landed
--- while still at altitude would be claiming its landing grace early, and the
--- grace is the only thing the report buys — so it is the only thing worth
--- checking. Generous on purpose: the landing zone's surveyed z and the real
--- ground under a player who glided two blocks are not the same metre.
function K.dropLandingPlausible(record, z)
    if record == nil or record.drop == nil then return false end
    local height = tonumber(z)
    if height == nil then return true end
    local tolerance = number(dropConfig().landedToleranceMetres, 25.0)
    return height <= (record.drop.ground.z + tolerance)
end

-- ---------------------------------------------------------------------------
-- Notices. The server sends a KIND and its fields, never display text: the
-- strings live in the HUD's own table so one language change is one file.
-- ---------------------------------------------------------------------------
function K.notice(playerId, kind, fields)
    local id = tonumber(playerId)
    if id == nil or id <= 0 then return end
    TriggerClientEvent("cordon:notice", id, { kind = kind, fields = fields or {} })
end

function K.broadcastNotice(kind, fields)
    for _, record in ipairs(K.humans()) do
        K.notice(record.id, kind, fields)
    end
end

-- ---------------------------------------------------------------------------
-- TUNABLES. Declared EXACTLY ONCE, in the FIRST server script, and server-only.
--
-- Three constraints, each of which has cost somebody a session:
--   * `Open77.tunables` is nil on the client, so a shared_script that calls
--     declare refuses the whole resource set and nobody can connect.
--   * Declaring twice is not idempotent.
--   * A tunable read into a file-scope local freezes at load. `K.tune()` is a
--     call, so it is always read at the point of use.
-- ---------------------------------------------------------------------------
if type(Open77.tunables) == "table" and type(Open77.tunables.declare) == "function"
    and type(Config) == "table" and type(Config.tunables) == "table" then
    local ok, err = pcall(Open77.tunables.declare, Config.tunables)
    if ok then
        local count = 0
        for _ in pairs(Config.tunables) do count = count + 1 end
        K.log(("declared %d tunables"):format(count))
    else
        K.warn("tunable declaration refused: " .. tostring(err))
    end
end

--- Read a tunable at the point of use, falling back to the declared default and
--- then to `fallback`. Never cache the result across a call.
function K.tune(key, fallback)
    if type(Open77.tunables) == "table" and type(Open77.tunables.get) == "function" then
        local ok, value = pcall(Open77.tunables.get, key)
        if ok and value ~= nil then return value end
    end
    local declared = Config and Config.tunables and Config.tunables[key]
    if type(declared) == "table" and declared.value ~= nil then return declared.value end
    return fallback
end

-- ---------------------------------------------------------------------------
-- SURVIVING A HOT RELOAD.
--
-- Measured 2026-09-02, mid-run: editing any file under resources/ hot-swaps the
-- resource, the new VM starts with an EMPTY roster, and — because there is no
-- player enumeration API and `onPlayerReady` does not re-fire — a live 64-player
-- match simply vanished. The players were still connected and still in the
-- match bucket; the mode had forgotten all of them.
--
-- Lazy adoption alone does not save this. It repopulates a player from the next
-- event THEY produce, which for somebody standing still inside the cordon may
-- be minutes away, and by then the match they were in has been replaced.
--
-- So the roster and the match ride the host's carried-state bag, which is what
-- it exists for. Two rules, both load-bearing:
--   * The bag is ONE 64 KiB string shared by every module in the resource, so
--     this READ-MODIFY-WRITES it. A writer that overwrites silently deletes
--     ranked.lua's pending career writes.
--   * Only what cannot be re-derived is saved. Positions come back from the
--     platform; verified weapon sets do not, and a player whose weapons were
--     forgotten would be unable to shoot until they picked up another gun.
-- ---------------------------------------------------------------------------
local CARRY_KEY = "cordonKernel"

function K.carry()
    if type(Open77.state) ~= "table" or type(Open77.state.save) ~= "function" then return end
    local bag = {}
    if type(Open77.state.load) == "function" then
        local ok, loaded = pcall(Open77.state.load)
        if ok and type(loaded) == "table" then bag = loaded end
    end
    -- THE BAG IS 64 KiB FOR THE WHOLE RESOURCE, shared with ranked.lua's pending
    -- career writes. Sixty-four players is exactly the size at which a careless
    -- roster fills it, and an over-large save is not a warning — it takes the
    -- whole write with it, including somebody else's data.
    --
    -- So the roster is carried COMPACTLY (short keys, no names — a name is
    -- re-read from the platform in one call) and BUDGETED: if the estimate
    -- exceeds the reserve, the roster is dropped and the mode says so, because
    -- losing the roster is survivable and losing ranked.lua's queue is not.
    local roster = {}
    local estimate = 0
    local labelBudget = 4096 -- part of the existing 24 KiB roster reserve
    for id, record in pairs(K.players) do
        if id > 0 then
            local weapons, weaponBytes = {}, 0
            for tweakId, slot in pairs(record.weapons or {}) do
                local key = K.weaponId(tweakId)
                if key ~= "" and type(slot) == "number" and slot % 1 == 0 and slot >= 1 and slot <= 3 then
                    local entry = { key, slot }
                    weaponBytes = weaponBytes + #key + 16
                    local label = record.weaponLabels and record.weaponLabels[key]
                    -- JSON can expand one control byte to six bytes. Labels are
                    -- optional presentation; reserve room for the actual kit first.
                    local cost = type(label) == "string" and (#label * 6 + 4) or 0
                    if cost > 0 and #label <= 48 and cost <= labelBudget then
                        entry[3] = label
                        labelBudget = labelBudget - cost
                        weaponBytes = weaponBytes + cost
                    end
                    weapons[#weapons + 1] = entry
                    local template = record.weaponTemplates and record.weaponTemplates[key]
                    if type(template) == "string" and #template <= 160
                        and template:match("^[%w_.%-]+$") then
                        -- Preserve positional JSON slots even when the optional
                        -- label was omitted to stay within its budget.
                        entry[3] = entry[3] or false
                        entry[4] = template
                        weaponBytes = weaponBytes + #template + 4
                    end
                end
            end
            local row = {
                i = record.identifier, s = record.state, q = record.squad,
                k = record.kills, p = record.plates, h = record.heals,
                w = weapons, pl = record.placement,
                -- THE DESCENT, and it is carried because GOD MODE CANNOT BE READ
                -- BACK.
                --
                -- `K.dropTo` arms `setGodMode(id, true)` and exactly one function
                -- takes it off again -- `K.endDrop` -- which needs `record.drop`
                -- to know there is anything to close. A hot reload used to lose
                -- that table (it was not in this row), so `K.tickDrops` saw
                -- nothing, `endDrop` was never called, and the player kept
                -- server-side invulnerability for the REST OF THE MATCH. The
                -- platform holds the flag, so there is no way to notice
                -- afterwards and no way to ask.
                --
                -- Only the ground and the bucket are kept: `K.restore` rebuilds
                -- the rest with a short deadline, so the ordinary timeout path
                -- closes it. One exit, as everywhere else in this block.
                d = record.drop ~= nil and {
                    x = record.drop.ground.x, y = record.drop.ground.y,
                    z = record.drop.ground.z, b = record.drop.bucket,
                } or nil,
            }
            -- ~40 bytes of scaffolding plus the identifier plus the weapon ids,
            -- plus ~70 for a descent when one is in flight.
            estimate = estimate + 40 + #tostring(record.identifier or "") + weaponBytes
                + (record.drop ~= nil and 70 or 0)
            roster[tostring(id)] = row
        end
    end
    if estimate > 24 * 1024 then
        K.warn(("carry: roster estimate %d B exceeds its 24 KiB reserve — dropping it rather than " ..
            "risking the shared 64 KiB bag. The roster will rebuild lazily."):format(estimate))
        roster = nil
    end
    bag[CARRY_KEY] = { version = 2, roster = roster, savedAtMs = K.nowMs() }
    local ok, err = pcall(Open77.state.save, bag)
    if not ok then K.warn("carry refused: " .. tostring(err)) end
end

function K.restore()
    if type(Open77.state) ~= "table" or type(Open77.state.load) ~= "function" then return 0 end
    local ok, bag = pcall(Open77.state.load)
    if not ok or type(bag) ~= "table" then return 0 end
    local carried = bag[CARRY_KEY]
    if type(carried) ~= "table" or type(carried.roster) ~= "table" then return 0 end
    local restored = 0
    local dropped = 0
    for idStr, saved in pairs(carried.roster) do
        local id = tonumber(idStr)
        -- LIVENESS CHECK, and it is not optional. The bag is written every five
        -- seconds and restored on every reload, so without this it RESURRECTS
        -- players who have since disconnected: a match reported 40 players and
        -- 32 bots when only two humans were connected, because six departed
        -- phantoms kept being restored on each reload.
        --
        -- `players.position` returning nil is the liveness test the platform
        -- gives us — there is no enumeration API to ask "who is here". A player
        -- who IS connected but not yet publishing is simply re-adopted lazily
        -- by their next event, which costs nothing.
        local live = false
        if id ~= nil and id > 0 then
            local ok, position = pcall(Open77.players.position, id)
            live = ok and position ~= nil
        end
        if not live then dropped = dropped + 1 end
        if id ~= nil and id > 0 and live then
            local record = K.ensure(id)
            if record ~= nil then
                record.identifier = saved.i or record.identifier
                record.state = saved.s or record.state
                record.squad = saved.q
                record.kills = saved.k or 0
                record.plates = saved.p or 0
                record.heals = saved.h or 0
                record.placement = saved.pl
                -- Version 2 entries keep {id, slot, optional label, optional
                -- assignment template}. Slot is
                -- inventory authority: allocation/replacement and HUD both use it.
                -- Old bags held only ids. Restore the player but refuse those
                -- weapons until reissued; inventing slots would overwrite an
                -- arbitrary gun and make its old id remain shootable.
                record.weapons, record.weaponLabels, record.weaponTemplates = {}, {}, {}
                local usedSlots, legacyWeapons = {}, 0
                for _, entry in ipairs(type(saved.w) == "table" and saved.w or {}) do
                    if type(entry) == "table" then
                        local key, slot = K.weaponId(entry[1]), entry[2]
                        if key ~= "" and type(slot) == "number" and slot % 1 == 0
                            and slot >= 1 and slot <= 3 and not usedSlots[slot]
                            and record.weapons[key] == nil then
                            record.weapons[key] = slot
                            usedSlots[slot] = true
                            if type(entry[3]) == "string" and #entry[3] <= 48 then
                                record.weaponLabels[key] = entry[3]
                            end
                            if type(entry[4]) == "string" and #entry[4] <= 160
                                and entry[4]:match("^[%w_.%-]+$") then
                                record.weaponTemplates[key] = entry[4]
                            end
                        end
                    elseif type(entry) == "string" then
                        legacyWeapons = legacyWeapons + 1
                    end
                end
                if legacyWeapons > 0 then
                    K.warn(("carry: player %d has %d legacy weapon ids without slots; " ..
                        "these weapons require reissuing before firing"):format(id, legacyWeapons))
                end
                -- A DESCENT THAT OUTLIVED THE RELOAD is re-armed with a short
                -- deadline rather than resumed. The new VM cannot know how far
                -- the player has fallen and the client's own chute has its own
                -- (shorter) deadline, so the honest move is to let
                -- `K.tickDrops` take the fallback within a couple of seconds:
                -- `dropFallback` -> `endDrop` clears the god mode and stands the
                -- player on the surveyed landing zone. That is the same exit an
                -- ordinary landing timeout takes, which is the whole point of
                -- having one exit.
                if type(saved.d) == "table" and saved.d.x ~= nil then
                    record.dropSequence = (record.dropSequence or 0) + 1
                    record.drop = {
                        id = record.dropSequence,
                        ground = { x = saved.d.x, y = saved.d.y, z = saved.d.z },
                        bucket = saved.d.b or K.matchBucket(),
                        releasedAtMs = K.nowMs(),
                        deadlineMs = K.nowMs() + 2000,
                    }
                    K.warn(("player %d was mid-descent across a hot reload — landing them and " ..
                        "releasing god mode within 2 s"):format(id))
                end
                restored = restored + 1
            end
        end
    end
    if restored > 0 or dropped > 0 then
        K.log(("restored %d players across a hot reload, dropped %d who are no longer connected"):format(
            restored, dropped))
    end
    return restored
end

AddEventHandler("onResourceStop", function(name)
    if name == GetCurrentResourceName() then K.carry() end
end)

K.restore()

K.log("kernel ready")
