local SCHEMA_SQL = [[
CREATE TABLE IF NOT EXISTS open77_player_appearances (
    user_id CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    character_key VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'default',
    schema_version INT UNSIGNED NOT NULL,
    game_build VARCHAR(32) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    catalog_digest CHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    revision BIGINT UNSIGNED NOT NULL DEFAULT 1,
    logical_json LONGTEXT CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (user_id, character_key),
    CONSTRAINT chk_open77_appearance_schema CHECK (schema_version = 1),
    CONSTRAINT chk_open77_appearance_revision CHECK (revision > 0)
) ENGINE=InnoDB
]]

local CHARACTER_SCHEMA_SQL = [[
CREATE TABLE IF NOT EXISTS open77_characters (
    user_id CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    character_key VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'default',
    character_id CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    body_family VARCHAR(8) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    status VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'active',
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (user_id, character_key),
    UNIQUE KEY uq_open77_character_id (character_id),
    CONSTRAINT chk_open77_character_family CHECK (body_family IN ('female', 'male'))
) ENGINE=InnoDB
]]

local dbReady = false
local dbMode = "starting"
local nonceCounter = 0
local pending = {}
local pendingCreation = {}
local activeCharacter = Presentation.characters
local holding = {}
local sessionBodyFamily = Presentation.families
local pendingBodyFamily = {}
local sessionAppearance = {}
local readinessDiagnostics = {}

-- Nobody may act on a joining player until this resource has had its say.
--
-- Character creation is a modal the PLAYER has to finish, and it is opened from the
-- same client announcement (`open77:worldReady`) that a gamemode uses to place people.
-- On 2026-08-27 that collision made the live Pursuit server unusable: the database was
-- switched on for the ranked ladder, the bridge is per-server rather than per-resource
-- so persistence came on here too, and every fresh player was teleported to a lobby
-- while still standing in the creator.
--
-- Declaring participation makes every joiner arrive with one hold in this resource's
-- name, which is released the instant we know there is nothing to ask -- see the
-- `ready` handler, where the overwhelmingly common answer is "this player already has
-- a character, carry on". A resource that does not consult the gate is unaffected.
--
-- 30 s is a WATCHDOG ON THIS RESOURCE, not a limit on the player. `holdGate` refreshes
-- it and the sweeper at the bottom of this file beats every 10 s for as long as a
-- creation is genuinely in flight -- and "in flight" is itself decided by the client's
-- own 5 s heartbeat, not by a clock. So a player who spends an hour on cheekbones holds
-- the gate for an hour, correctly, while an abandoned creator, a rejected commit, a
-- disconnect or a dead VM all release within 30 s of the last sign of life.
--
-- If a normal join ever trips this deadline, the readiness condition is wrong. Raising
-- the number is not the fix.
Open77.ready.participate({ livenessIntervalMs = 30000, reason = "character_creation" })

-- How long a creation session survives with no beat from the client that owns it. Six
-- missed 5 s beats: long enough to ride out a stall, short enough that a player who
-- alt-F4s out of the creator stops holding anything within half a minute.
local CREATION_LIVENESS_MS = 30000
local EDIT_LIVENESS_MS = 30000

-- `expectedSession`, when given, is the session this decision was made for. Taking a
-- hold is the one thing here that can HURT a stranger -- it would leave whoever
-- inherited a recycled player id waiting on a character creator they never opened --
-- so a hold whose decision predates a reconnect is dropped rather than applied.
local function holdGate(player, reason, expectedSession)
    if expectedSession ~= nil and expectedSession ~= 0 and
        Open77.ready.status(player).session ~= expectedSession then
        print(("[open77_appearance] not holding player=%s: the session moved on since we looked")
            :format(tostring(player)))
        return nil
    end
    local session = Open77.ready.hold(player, reason or "character_creation")
    if session ~= nil then holding[player] = true end
    return session
end

-- Releasing says "APPEARANCE is finished with this player", and nothing more. It is no
-- longer the last word on whether anyone may act on them: the platform keeps a hold of
-- its own until the client reports a puppet that is attached, alive and past the
-- continue screen. That split is the 2026-08-27 fix. Before it, this release WAS the
-- gate opening -- measured at 03:58:54, 154 ms before the client had even asked the
-- engine to load its world -- and Pursuit dutifully killed and respawned someone who
-- was looking at a loading screen.
--
-- `session` is the value the gate reported when this player was last looked at.
-- Passing it back is what stops an answer computed before a disconnect from opening
-- the gate of whoever inherited the player id -- which would be this very bug,
-- reappearing once a month and never reproducing.
local function releaseGate(player, session)
    holding[player] = nil
    return Open77.ready.release(player, session, "appearance_resolved")
end

local function commandResult(player, raw, accepted, message)
    if player and player > 0 then
        TriggerClientEvent("open77:command:result", player, raw or "", accepted == true, message)
    else
        print(message)
    end
end

local function characterKey(value)
    value = tostring(value or "default")
    if #value < 1 or #value > 64 or value:match("^[%w_.:%-]+$") == nil then
        return nil
    end
    return value
end

local function fixedHash(value, allowZero)
    if type(value) ~= "string" or #value ~= 18 or value:sub(1, 2) ~= "0x" or
        value:sub(3):match("^%x+$") == nil then return false end
    return allowZero or value ~= "0x0000000000000000"
end

local function isInteger(value)
    return type(value) == "number" and value == value and value % 1 == 0
end

local function canonicalSnapshot(value)
    if type(value) ~= "table" then return nil, "invalid_snapshot" end
    if value.schemaVersion ~= 1 then return nil, "unsupported_schema" end
    if value.gameBuild ~= "2.31" then return nil, "unsupported_game_build" end
    local digest = type(value.catalogDigest) == "string" and string.lower(value.catalogDigest) or ""
    if #digest ~= 64 or digest:match("^%x+$") == nil then
        return nil, "invalid_catalog_digest"
    end
    if not fixedHash(value.gender, true) then return nil, "invalid_gender" end
    if type(value.options) ~= "table" then return nil, "invalid_options" end
    local count = #value.options
    if count < 1 or count > 256 then return nil, "invalid_option_count" end
    local result = {
        schemaVersion = 1,
        gameBuild = "2.31",
        catalogDigest = digest,
        gender = value.gender,
        options = {}
    }
    local seen = {}
    for index = 1, count do
        local option = value.options[index]
        if type(option) ~= "table" then return nil, "invalid_option" end
        if option.part ~= "head" and option.part ~= "body" and option.part ~= "arms" then
            return nil, "invalid_option_part"
        end
        if not fixedHash(option.name, false) then return nil, "invalid_option_name" end
        if not isInteger(option.value) or option.value < 0 or option.value >= 512 then
            return nil, "invalid_option_value"
        end
        if not isInteger(option.choices) or option.choices < 0 or option.choices > 512 then
            return nil, "invalid_option_choices"
        end
        if option.choices > 0 and option.value >= option.choices then
            return nil, "option_out_of_range"
        end
        local key = option.part .. ":" .. string.lower(option.name)
        if seen[key] then return nil, "duplicate_option" end
        seen[key] = true
        result.options[index] = {
            part = option.part,
            name = string.lower(option.name),
            value = option.value,
            choices = option.choices
        }
    end
    -- Reject sparse arrays and attacker-controlled extra numeric entries.
    for key in pairs(value.options) do
        if type(key) == "number" and (not isInteger(key) or key < 1 or key > count) then
            return nil, "sparse_options"
        end
    end
    return result
end

local function decodeStored(text)
    local value, decodeError = json.decode(tostring(text or ""))
    if value == nil then return nil, decodeError or "invalid_json" end
    return canonicalSnapshot(value)
end

local function loadAppearance(userId, key)
    local row = MySQL.single.await([[
        SELECT schema_version, game_build, catalog_digest, revision, logical_json
        FROM open77_player_appearances
        WHERE user_id = @user AND character_key = @character
        LIMIT 1
    ]], { user = userId, character = key })
    if row == nil then return nil, 0 end
    local snapshot, reason = decodeStored(row.logical_json)
    if not snapshot then
        print(("[open77_appearance] corrupt row user=%s character=%s reason=%s")
            :format(userId, key, tostring(reason)))
        return nil, tonumber(row.revision) or 0, "stored_snapshot_invalid"
    end
    if tonumber(row.schema_version) ~= snapshot.schemaVersion or
        tostring(row.game_build) ~= snapshot.gameBuild or
        string.lower(tostring(row.catalog_digest)) ~= snapshot.catalogDigest then
        return nil, tonumber(row.revision) or 0, "stored_metadata_mismatch"
    end
    return snapshot, tonumber(row.revision) or 0
end

local function safeLoadAppearance(userId, key)
    local ok, snapshot, revision, reason = pcall(loadAppearance, userId, key)
    if ok then return snapshot, revision, reason end
    print("[open77_appearance] load database failure: " .. tostring(snapshot))
    return nil, 0, "database_error"
end

local function loadCharacter(userId, key)
    return MySQL.single.await([[
        SELECT character_id, body_family, status
        FROM open77_characters
        WHERE user_id = @user AND character_key = @character
        LIMIT 1
    ]], { user = userId, character = key })
end

local function safeLoadCharacter(userId, key)
    local ok, row = pcall(loadCharacter, userId, key)
    if ok then return row end
    print("[open77_appearance] character database failure: " .. tostring(row))
    return nil, "database_error"
end

local function currentIdentity(player)
    local userId = GetPlayerIdentifier(player)
    if type(userId) ~= "string" or #userId ~= 36 then return nil, nil end
    local key = activeCharacter[player] or "default"
    return userId, key
end

local function nextNonce(player)
    nonceCounter = nonceCounter + 1
    -- The server scheduler exposes its monotonic clock as a Lua number. It can
    -- carry a fractional component, while Lua 5.4's %d rejects numbers without
    -- an exact integer representation. A nonce is opaque text, so normalize
    -- the clock and stringify every segment instead of relying on integer
    -- formatting.
    local tick = math.floor(tonumber(GetGameTimer()) or 0)
    return table.concat({ tostring(player), tostring(tick), tostring(nonceCounter) }, ":")
end

local function beginEdit(player, mode, gender)
    if not dbReady then
        return false, "database_unavailable"
    end
    if pending[player] ~= nil then return false, "appearance_busy" end
    mode = string.lower(tostring(mode or "ripperdoc"))
    if mode ~= "ripperdoc" and mode ~= "hairdresser" then return false, "invalid_mode" end
    gender = string.lower(tostring(gender or ""))
    if gender ~= "" and gender ~= "keep" and gender ~= "male" and gender ~= "female" then
        return false, "invalid_gender"
    end
    if gender ~= "" and gender ~= "keep" and mode ~= "ripperdoc" then
        return false, "gender_requires_ripperdoc"
    end
    local userId, key = currentIdentity(player)
    if not userId then return false, "player_not_authenticated" end
    local snapshot, revision, loadError = safeLoadAppearance(userId, key)
    if loadError then return false, loadError end
    print(("[open77_appearance] begin edit player=%s user=%s character=%s mode=%s gender=%s revision=%s snapshot=%s options=%d")
        :format(tostring(player), userId, key, mode, gender ~= "" and gender or "keep", tostring(revision),
            snapshot and "yes" or "no",
            snapshot and type(snapshot.options) == "table" and #snapshot.options or 0))
    local nonce = nextNonce(player)
    pending[player] = {
        nonce = nonce,
        userId = userId,
        characterKey = key,
        revision = revision,
        catalogDigest = snapshot and snapshot.catalogDigest or nil,
        family = (gender == "male" or gender == "female") and gender or sessionBodyFamily[player],
        lastSeenMs = GetGameTimer()
    }
    TriggerClientEvent("open77:appearance:beginEdit", player,
        nonce, revision, mode, gender, key, snapshot)
    return true
end

local function sendCurrent(player, session)
    if not dbReady then return false, "database_unavailable" end
    local userId, key = currentIdentity(player)
    if not userId then return false, "player_not_authenticated" end
    local snapshot, revision, reason = safeLoadAppearance(userId, key)
    if reason then
        print(("[open77_appearance] restore load failed player=%s user=%s character=%s reason=%s")
            :format(tostring(player), userId, key, tostring(reason)))
        return false, reason
    end
    print(("[open77_appearance] restore loaded player=%s user=%s character=%s revision=%s snapshot=%s options=%d")
        :format(tostring(player), userId, key, tostring(revision),
            snapshot and "yes" or "no",
            snapshot and type(snapshot.options) == "table" and #snapshot.options or 0))
    local character, characterError = safeLoadCharacter(userId, key)
    if characterError then return false, characterError end
    if GetPlayerIdentifier(player) ~= userId or (activeCharacter[player] or "default") ~= key
        or (session and Open77.ready.status(player).session ~= session) then
        return false, "stale_character_session"
    end
    if character and character.status == "active" then
        -- A playable character is committed in the same transaction as its
        -- canonical appearance. Never let a damaged/partially migrated row
        -- bypass first-character creation and boot a naked default puppet.
        if not snapshot then
            print(("[open77_appearance] character integrity failure player=%s user=%s character=%s")
                :format(tostring(player), userId, key))
            return false, "character_appearance_missing"
        end
        local family = tostring(character.body_family)
        sessionBodyFamily[player] = family
        TriggerClientEvent("open77:appearance:bootstrapReady", player,
            family, key, tostring(character.character_id))
    elseif snapshot then
        -- One-time migration for profiles authored before characters gained an
        -- explicit body-family row. Those builds only shipped a female seed.
        local migrated = MySQL.update.await([[
            INSERT IGNORE INTO open77_characters
                (user_id, character_key, character_id, body_family, status)
            VALUES (@user, @character, UUID(), 'female', 'active')
        ]], { user = userId, character = key })
        print(("[open77_appearance] migrated legacy profile player=%s affected=%s")
            :format(tostring(player), tostring(migrated)))
        sessionBodyFamily[player] = "female"
        TriggerClientEvent("open77:appearance:bootstrapReady", player, "female", key, "")
    else
        local creation = pendingCreation[player]
        if not creation or creation.userId ~= userId or creation.characterKey ~= key then
            creation = {
                nonce = nextNonce(player),
                userId = userId,
                characterKey = key,
                -- Liveness, not expiry. This field used to be `expires =
                -- GetGameTimer() + 300000`, a hard five-minute cap on how long a player
                -- was allowed to build their character; past it the commit came back
                -- `invalid_creation_session` and the client failed its bootstrap. It is
                -- now the timestamp of the last beat from the client, refreshed by
                -- `open77:appearance:creating` every 5 s and checked by the sweeper.
                lastSeenMs = GetGameTimer()
            }
            pendingCreation[player] = creation
        end
        local nonce = creation.nonce
        -- The only branch that makes anyone wait: this player has to build a character
        -- before the world may be allowed to move them. Everything below and above
        -- resolves the gate instead.
        holdGate(player, "character_creation", session)
        TriggerClientEvent("open77:appearance:createRequired", player, nonce, key)
        return true, nil, true
    end
    sessionAppearance[player] = { key=key, revision=revision, snapshot=snapshot }
    if snapshot then
        print(("[open77_appearance] restore sending player=%s revision=%s character=%s")
            :format(tostring(player), tostring(revision), key))
        TriggerClientEvent("open77:appearance:restore", player, snapshot, revision, key)
    end
    return true
end

RegisterNetEvent("open77:appearance:createCommit", function(nonce, family, incoming)
    local player = source
    CreateThread(function()
        local creation = pendingCreation[player]
        if not creation or tostring(nonce or "") ~= creation.nonce then
            return TriggerClientEvent("open77:appearance:createRejected", player,
                tostring(nonce or ""), "invalid_creation_session")
        end
        pendingCreation[player] = nil
        -- No expiry check. A commit arriving from a client that has kept beating is
        -- valid however long it took; a client that stopped beating had its creation
        -- swept below, and its late commit fails the nonce check above instead.
        family = string.lower(tostring(family or ""))
        if family ~= "female" and family ~= "male" then
            return TriggerClientEvent("open77:appearance:createRejected", player,
                creation.nonce, "invalid_body_family")
        end
        local userId, key = currentIdentity(player)
        if userId ~= creation.userId or key ~= creation.characterKey then
            return TriggerClientEvent("open77:appearance:createRejected", player,
                creation.nonce, "identity_changed")
        end
        local snapshot, validationError = canonicalSnapshot(incoming)
        if not snapshot then
            return TriggerClientEvent("open77:appearance:createRejected", player,
                creation.nonce, validationError)
        end
        local payload = json.encode(snapshot)
        if type(payload) ~= "string" or #payload > 49152 then
            return TriggerClientEvent("open77:appearance:createRejected", player,
                creation.nonce, "snapshot_too_large")
        end
        local committed, transactionError = MySQL.transaction.await({
            {
                query = [[
                    INSERT INTO open77_characters
                        (user_id, character_key, character_id, body_family, status)
                    VALUES (?, ?, UUID(), ?, 'active')
                ]],
                values = { userId, key, family }
            },
            {
                query = [[
                    INSERT INTO open77_player_appearances
                        (user_id, character_key, schema_version, game_build,
                         catalog_digest, revision, logical_json)
                    VALUES (?, ?, 1, ?, ?, 1, ?)
                ]],
                values = { userId, key, snapshot.gameBuild, snapshot.catalogDigest, payload }
            }
        })
        if committed ~= true then
            print("[open77_appearance] character creation transaction failed: " ..
                tostring(transactionError))
            return TriggerClientEvent("open77:appearance:createRejected", player,
                creation.nonce, "database_error")
        end
        sessionBodyFamily[player] = family
        sessionAppearance[player] = { key=key, revision=1, snapshot=snapshot }
        TriggerClientEvent("open77:appearance:createAccepted", player,
            creation.nonce, family, 1, snapshot, key)
        TriggerEvent("open77:appearance:characterCreated", player, userId, key, family, snapshot)
        -- The character exists and the client is entering Night City: everyone else may
        -- now do what they were waiting to do. Every OTHER outcome of this handler --
        -- a rejected snapshot, a failed transaction, an abort, a client that walked
        -- away -- also clears `pendingCreation`, and the sweeper below turns that into
        -- a release within ten seconds, so no exit from character creation leaves a
        -- hold standing.
        releaseGate(player)
    end)
end)

-- The client saying "the character creator is still open on my screen". This is the
-- ONLY thing that keeps a creation alive, and it is deliberately a liveness proof
-- rather than a renewal: it carries no duration and grants none. A player deliberating
-- for an hour sends 720 of these and is never cut off; a player who alt-F4s stops
-- sending them and is swept within CREATION_LIVENESS_MS.
RegisterNetEvent("open77:appearance:creating", function(nonce)
    local player = source
    local creation = pendingCreation[player]
    if creation and tostring(nonce or "") == creation.nonce then
        creation.lastSeenMs = GetGameTimer()
    end
end)

RegisterNetEvent("open77:appearance:createAbort", function(nonce)
    local player = source
    local creation = pendingCreation[player]
    if creation and tostring(nonce or "") == creation.nonce then
        pendingCreation[player] = nil
    end
end)

-- Evidence from the client, never authority to release a readiness hold.
-- Whitelisted fields and per-session throttling prevent forged log lines/spam.
RegisterNetEvent("open77:appearance:readinessDiagnostic", function(stage, resetPhase, bootstrapPhase, elapsed)
    local player = source
    local session = Open77.ready.status(player).session
    if not session or session == 0 then return end
    local now = GetGameTimer()
    local previous = readinessDiagnostics[player]
    if previous and previous.session == session and now - previous.time < 15000 then return end
    local stages = { player_reset=true, appearance_record=true, appearance_failed=true,
        appearance_applying=true, alive_or_gameplay_announcement=true }
    local resets = { idle=true, apply=true, complete=true, failed=true }
    local bootstraps = { idle=true, waiting=true, creator_requested=true, creator_open=true,
        awaiting_commit=true, ready=true, failed=true }
    if type(stage) ~= "string" or not stages[stage]
        or type(resetPhase) ~= "string" or not resets[resetPhase]
        or type(bootstrapPhase) ~= "string" or not bootstraps[bootstrapPhase]
        or type(elapsed) ~= "number" or elapsed ~= elapsed or elapsed < 0 or elapsed > 86400 then return end
    readinessDiagnostics[player] = { session=session, time=now }
    print(("[OP77-INIT-002] Client-reported readiness wait player=%s session=%s stage=%s reset=%s bootstrap=%s elapsedSeconds=%d. " ..
        "This is diagnostic only, not proof of readiness. Ask for script.state + webui.status and Diagnostics while the game is open.")
        :format(tostring(player), tostring(session), stage, resetPhase, bootstrapPhase, math.floor(elapsed)))
end)

RegisterNetEvent("open77:appearance:ready", function()
    local player = source
    -- Read BEFORE the thread: everything below can await a database round trip, and
    -- the player could have gone and been replaced on the same id by the time it
    -- returns. The gate discards an answer stamped with a session that has moved on.
    local session = Open77.ready.status(player).session
    print(("[open77_appearance] ready received player=%s"):format(tostring(player)))
    CreateThread(function()
        while dbMode == "starting" do Wait(0) end
        if Open77.ready.status(player).session ~= session then return end
        if dbMode == "failed" then
            TriggerClientEvent("open77:appearance:bootstrapFailed", player, "database_error")
            return
        end
        -- Development fallback: without a database there is no persistent
        -- character, but a player left in `waiting` never enters the world at
        -- all -- the shell worker only defaults the family when the server
        -- ships no resources. Resolve the same default the legacy no-resource
        -- path uses, and say clearly that nothing will be persisted.
        if not dbReady then
            local family = sessionBodyFamily[player] or "female"
            sessionBodyFamily[player] = family
            sessionAppearance[player] = { key=activeCharacter[player] or "default", revision=0 }
            pendingBodyFamily[player] = nil
            print(("[open77_appearance] no database: resolving player=%s with the default character, nothing will persist")
                :format(tostring(player)))
            TriggerClientEvent("open77:appearance:bootstrapReady", player, family, "default", "")
            releaseGate(player, session)
            return
        end
        local ok, reason, creating = sendCurrent(player, session)
        print(("[open77_appearance] restore dispatch completed player=%s ok=%s reason=%s creating=%s (not gameplay readiness)")
            :format(tostring(player), tostring(ok), tostring(reason), tostring(creating == true)))
        if not ok then
            print("[open77_appearance] ready: " .. tostring(reason))
            TriggerClientEvent("open77:appearance:bootstrapFailed", player, reason)
        end
        -- Open the gate for everyone who is not being asked to build a character --
        -- including the failure paths. A player whose row is corrupt or whose database
        -- is down joins with whatever the client can put on screen, which is a bad
        -- evening; a player nothing will ever place is a dead server, which is the
        -- outage this whole mechanism exists to prevent. The reason is already logged
        -- above and `syncAck` already carries it to the client.
        if creating ~= true then releaseGate(player, session) end
    end)
end)

-- The body record: what observers spawn a player's proxy from. The owning
-- client sends it once its appearance for the session is final; it is kept per
-- session, replicated to everyone, and handed to joiners with every other body.
local bodies = {}

local function validBody(body)
    if type(body) ~= "table" or type(body.groups) ~= "table" then return false end
    if body.family ~= "male" and body.family ~= "female" then return false end
    local count = #body.groups
    if count == 0 or count > 64 then return false end
    local seen = {}
    for index, group in pairs(body.groups) do
        if not isInteger(index) or index < 1 or index > count or type(group) ~= "table" then return false end
        if group.part ~= "head" and group.part ~= "body" and group.part ~= "arms" then return false end
        if not fixedHash(group.name, false) or type(group.keys) ~= "table" then return false end
        local id = group.part .. ":" .. string.lower(group.name)
        if seen[id] then return false end
        seen[id] = true
        local keys = #group.keys
        if keys == 0 or keys > 64 then return false end
        for keyIndex, key in pairs(group.keys) do
            if not isInteger(keyIndex) or keyIndex < 1 or keyIndex > keys or type(key) ~= "table"
                or not fixedHash(key[1], false) or not fixedHash(key[2], false) or #key ~= 2 then return false end
        end
    end
    local encoded = json.encode(body)
    return type(encoded) == "string" and #encoded <= 49152
end

local function matchesAppearance(expected, incoming)
    if expected == nil then return true end -- explicit no-database development mode
    local snapshot = canonicalSnapshot(incoming)
    if not snapshot or snapshot.catalogDigest ~= expected.catalogDigest or snapshot.gender ~= expected.gender
        or #snapshot.options ~= #expected.options then return false end
    local values = {}
    for _, option in ipairs(expected.options) do values[option.part .. ":" .. option.name] = option.value end
    for _, option in ipairs(snapshot.options) do
        if values[option.part .. ":" .. option.name] ~= option.value then return false end
    end
    return true
end

-- A player's body is in the world from its publication until the player leaves
-- the world to reload it; while absent, observers hold no proxy of it.
local absent = {}

RegisterNetEvent("open77:appearance:body", function(body, characterKey, revision, logical, sequence)
    local player = tonumber(source)
    local expected = player and sessionAppearance[player]
    if not expected or characterKey ~= expected.key or revision ~= expected.revision
        or not isInteger(sequence) or sequence < 1 or not validBody(body)
        or body.family ~= sessionBodyFamily[player] or not matchesAppearance(expected.snapshot, logical) then return end
    bodies[player] = body
    absent[player] = nil
    Presentation.sendToObservers("open77:appearance:body", player, body)
    TriggerClientEvent("open77:appearance:bodyAck", player, characterKey, revision, sequence)
end)

local function bodyAbsent(player)
    if absent[player] then return end
    absent[player] = true
    Presentation.sendToObservers("open77:appearance:body", player, false)
end

RegisterNetEvent("open77:session:gameplayReady", function()
    local player = tonumber(source)
    if player == nil then return end
    for _, other in ipairs(Open77.players.inScope(player)) do
        local body = bodies[other]
        if other ~= player and body and not absent[other] then
            TriggerClientEvent("open77:appearance:body", player, other, body)
        end
    end
end)

-- The native roster retires replicas on a bucket change. PlayerJoined alone
-- cannot rebuild them: spawn waits for body + equipment + wardrobe, which are
-- authoritative Lua records, not the legacy protocol PlayerAppearance packet.
-- The host queues this local event after the synchronous routing/roster update;
-- native presence is consumed before Lua presentation on the client frame.
local function replayPeer(viewer, player)
    if not Presentation.inScope(viewer, player) then return end
    if bodies[player] and not absent[player] then
        TriggerClientEvent("open77:appearance:body", viewer, player, bodies[player])
    end
    Presentation.sendRecords(viewer, player)
end

-- Distance culling retires the same native proxy as a bucket transfer. Restore
-- all three records on re-entry, not only the legacy wire appearance packet.
-- Host-local only; clients cannot request another bucket's presentation.
AddEventHandler("open77:appearance:scopeEntered", function(viewer, player)
    viewer, player = tonumber(viewer), tonumber(player)
    if not viewer or not player or viewer <= 0 or player <= 0 or viewer == player
        or not GetPlayerName(viewer) or not GetPlayerName(player)
        or GetPlayerRoutingBucket(viewer) ~= GetPlayerRoutingBucket(player) then return end
    replayPeer(viewer, player)
end)

AddEventHandler("onPlayerBucketChange", function(player, bucket, previous)
    player, bucket, previous = tonumber(player), tonumber(bucket), tonumber(previous)
    if not player or player <= 0 or not bucket or bucket == previous
        or not GetPlayerName(player) or GetPlayerRoutingBucket(player) ~= bucket then return end
    -- Use the current authoritative roster, not positions (cleared on transfer)
    -- or client-supplied instance IDs. Ignore superseded moves/disconnected IDs.
    for _, other in ipairs(Open77.players.inScope(player)) do
        if other ~= player then
            replayPeer(player, other)
        end
    end
    for _, other in ipairs(Open77.players.observers(player)) do
        if other ~= player then replayPeer(other, player) end
    end
end)

RegisterNetEvent("open77:appearance:requestOpen", function(mode, gender)
    local player = source
    CreateThread(function()
        local ok, accepted, reason = pcall(beginEdit, player, mode, gender)
        if not ok then
            accepted, reason = false, accepted
            print("[open77_appearance] beginEdit: " .. tostring(reason))
        end
        if not accepted then
            TriggerClientEvent("open77:appearance:rejected", player, "", reason or "edit_failed", 0, nil)
            commandResult(player, "appearance", false, reason or "edit_failed")
        end
    end)
end)

RegisterCommand("gender", function(player, _, raw)
    player = tonumber(player)
    if not player or player <= 0 then
        return commandResult(player, raw, false, "gender is a player command")
    end
    if dbReady then
        return commandResult(player, raw, false,
            "Use /appearance male or /appearance female when persistence is enabled.")
    end
    local current = sessionBodyFamily[player] or "female"
    local target = current == "male" and "female" or "male"
    sessionBodyFamily[player] = target
    pendingBodyFamily[player] = { previous = current, target = target }
    bodyAbsent(player)
    TriggerClientEvent("open77:appearance:switchBodyFamily", player, target)
    commandResult(player, raw, true, "Body type reload requested.")
end, false)

RegisterNetEvent("open77:appearance:bodyFamilyRejected", function(target)
    local player = source
    local transition = pendingBodyFamily[player]
    if transition and tostring(target or "") == transition.target then
        sessionBodyFamily[player] = transition.previous
        pendingBodyFamily[player] = nil
        if absent[player] and bodies[player] then
            absent[player] = nil
            TriggerClientEvent("open77:appearance:body", -1, player, bodies[player])
        end
    end
end)

RegisterNetEvent("open77:appearance:abort", function(nonce, reason)
    local player = source
    local edit = pending[player]
    if edit and tostring(nonce or "") == edit.nonce then pending[player] = nil end
    if reason == "body_family_transition" then bodyAbsent(tonumber(player)) end
end)

-- Only the current authorized editor can prove it is still open. An expired
-- nonce cannot be revived between sweeps, and client input never grants time.
RegisterNetEvent("open77:appearance:editing", function(nonce, characterKey, revision)
    local player = source
    local edit = pending[player]
    if not edit or nonce ~= edit.nonce or characterKey ~= edit.characterKey
        or revision ~= edit.revision then return end
    local now = GetGameTimer()
    if now - edit.lastSeenMs > EDIT_LIVENESS_MS then return end
    local userId, key = currentIdentity(player)
    if userId ~= edit.userId or key ~= edit.characterKey then return end
    edit.lastSeenMs = now
end)

RegisterNetEvent("open77:appearance:commit", function(nonce, expectedRevision, incoming)
    local player = source
    CreateThread(function()
        local edit = pending[player]
        if not edit or tostring(nonce or "") ~= edit.nonce then
            return TriggerClientEvent("open77:appearance:rejected", player,
                tostring(nonce or ""), "invalid_edit_session", 0, nil)
        end
        pending[player] = nil -- one-shot nonce, including database failures
        if GetGameTimer() - edit.lastSeenMs > EDIT_LIVENESS_MS then
            return TriggerClientEvent("open77:appearance:rejected", player,
                edit.nonce, "edit_expired", edit.revision, nil)
        end
        local userId, key = currentIdentity(player)
        if userId ~= edit.userId or key ~= edit.characterKey then
            return TriggerClientEvent("open77:appearance:rejected", player,
                edit.nonce, "identity_changed", edit.revision, nil)
        end
        if not isInteger(expectedRevision) or expectedRevision ~= edit.revision then
            return TriggerClientEvent("open77:appearance:rejected", player,
                edit.nonce, "revision_conflict", edit.revision, nil)
        end
        local snapshot, validationError = canonicalSnapshot(incoming)
        if not snapshot then
            return TriggerClientEvent("open77:appearance:rejected", player,
                edit.nonce, validationError, edit.revision, nil)
        end
        if edit.catalogDigest and edit.catalogDigest ~= snapshot.catalogDigest then
            -- The live united catalogue contains contextual entries (outfit,
            -- censor and editor mode). A newly captured canonical snapshot is
            -- already structurally validated above, so allow it to migrate an
            -- older digest instead of permanently trapping that character on
            -- the previous catalogue.
            print(("[open77_appearance] catalogue migration player=%s revision=%s old=%s new=%s options=%d")
                :format(tostring(player), tostring(edit.revision),
                    tostring(edit.catalogDigest), tostring(snapshot.catalogDigest),
                    #snapshot.options))
        end
        local payload = json.encode(snapshot)
        if type(payload) ~= "string" or #payload > 49152 then
            return TriggerClientEvent("open77:appearance:rejected", player,
                edit.nonce, "snapshot_too_large", edit.revision, nil)
        end

        local ok, affectedOrError = pcall(function()
            if edit.revision == 0 then
                return MySQL.update.await([[
                    INSERT IGNORE INTO open77_player_appearances
                        (user_id, character_key, schema_version, game_build,
                         catalog_digest, revision, logical_json)
                    VALUES (@user, @character, 1, @build, @digest, 1, @json)
                ]], {
                    user = userId, character = key, build = snapshot.gameBuild,
                    digest = snapshot.catalogDigest, json = payload
                })
            end
            return MySQL.update.await([[
                UPDATE open77_player_appearances a
                JOIN open77_characters c ON c.user_id=a.user_id AND c.character_key=a.character_key
                SET a.schema_version = 1, a.game_build = @build,
                    a.catalog_digest = @digest, a.logical_json = @json,
                    a.revision = a.revision + 1, c.body_family = @family
                WHERE a.user_id = @user AND a.character_key = @character
                  AND a.revision = @revision
            ]], {
                user = userId, character = key, revision = edit.revision, family = edit.family,
                build = snapshot.gameBuild, digest = snapshot.catalogDigest, json = payload
            })
        end)
        if not ok then
            print("[open77_appearance] commit database failure: " .. tostring(affectedOrError))
            local canonical, revision = safeLoadAppearance(userId, key)
            return TriggerClientEvent("open77:appearance:rejected", player,
                edit.nonce, "database_error", revision, canonical)
        end
        if tonumber(affectedOrError) ~= 1 and tonumber(affectedOrError) ~= 2 then
            local canonical, revision = safeLoadAppearance(userId, key)
            return TriggerClientEvent("open77:appearance:rejected", player,
                edit.nonce, "revision_conflict", revision, canonical)
        end
        sessionBodyFamily[player] = edit.family
        local nextRevision = edit.revision + 1
        sessionAppearance[player] = { key=key, revision=nextRevision, snapshot=snapshot }
        TriggerClientEvent("open77:appearance:accepted", player,
            edit.nonce, nextRevision, snapshot)
        TriggerEvent("open77:appearance:saved", player, userId, key, nextRevision, snapshot)
    end)
end)

-- Server-owned character selection for RP resources. The client cannot choose
-- another character key; a gamemode calls this local event after authorizing it.
AddEventHandler("open77:appearance:setCharacter", function(player, requestedKey)
    player = tonumber(player)
    local key = characterKey(requestedKey)
    if not player or player <= 0 or not key then return false end
    pending[player] = nil
    pendingCreation[player] = nil
    Presentation.select(player, key)
    sessionAppearance[player] = nil
    bodyAbsent(player)
    local userId = GetPlayerIdentifier(player)
    local epoch = Presentation.epochs[player]
    local session = Open77.ready.status(player).session
    CreateThread(function()
        while dbMode == "starting" do Wait(0) end
        if not userId or GetPlayerIdentifier(player) ~= userId or Presentation.epochs[player] ~= epoch then return end
        if dbMode == "disabled" then
            sessionBodyFamily[player] = sessionBodyFamily[player] or "female"
            sessionAppearance[player] = { key=key, revision=0 }
            TriggerClientEvent("open77:appearance:characterChanged", player, key, nil, 0, sessionBodyFamily[player])
            Presentation.ready(player)
            return
        end
        local snapshot, revision, reason = safeLoadAppearance(userId, key)
        local character, characterError = safeLoadCharacter(userId, key)
        if GetPlayerIdentifier(player) ~= userId or Presentation.epochs[player] ~= epoch then return end
        if reason or characterError then
            TriggerClientEvent("open77:appearance:bootstrapFailed", player, reason or characterError)
            return
        end
        if not character or not snapshot then
            local ok, why = sendCurrent(player, session)
            if not ok then TriggerClientEvent("open77:appearance:bootstrapFailed", player, why) end
            return
        end
        sessionBodyFamily[player] = tostring(character.body_family)
        sessionAppearance[player] = { key=key, revision=revision, snapshot=snapshot }
        TriggerClientEvent("open77:appearance:characterChanged", player, key, snapshot, revision, sessionBodyFamily[player])
        Presentation.ready(player)
    end)
    return true
end)

AddEventHandler("playerDropped", function()
    readinessDiagnostics[source] = nil
    bodies[tonumber(source) or 0] = nil
    sessionAppearance[source] = nil
    pending[source] = nil
    pendingCreation[source] = nil
    activeCharacter[source] = nil
    sessionBodyFamily[source] = nil
    pendingBodyFamily[source] = nil
    absent[source] = nil
    -- The host drops the gate itself when a player leaves; forgetting them here is
    -- what stops the sweeper from chasing an id that may already belong to somebody
    -- else by its next pass.
    holding[source] = nil
end)

RegisterCommand("appearance", function(player, args, raw)
    if not player or player <= 0 then
        return commandResult(player, raw, false, "appearance is a player command")
    end
    CreateThread(function()
        local mode = string.lower(tostring(args[1] or "ripperdoc"))
        local gender = args[2]
        if mode == "male" or mode == "female" then
            gender = mode
            mode = "ripperdoc"
        end
        local ok, accepted, reason = pcall(beginEdit, player, mode, gender)
        if not ok then accepted, reason = false, accepted end
        commandResult(player, raw, accepted, accepted and "Appearance editor opened." or reason)
    end)
end, false)

RegisterCommand("barber", function(player, _, raw)
    if not player or player <= 0 then return end
    CreateThread(function()
        local ok, accepted, reason = pcall(beginEdit, player, "hairdresser", "")
        if not ok then accepted, reason = false, accepted end
        commandResult(player, raw, accepted, accepted and "Hair editor opened." or reason)
    end)
end, false)

CreateThread(function()
    local ok, reason = pcall(function()
        MySQL.update.await(SCHEMA_SQL)
        MySQL.update.await(CHARACTER_SCHEMA_SQL)
    end)
    if not ok then
        dbReady = false
        dbMode = tostring(reason):find("database_unavailable", 1, true) and "disabled" or "failed"
        return print("[open77_appearance] database unavailable: " .. tostring(reason))
    end
    dbReady = true
    dbMode = "ready"
    print("Open77 persistent appearance database ready")
end)

CreateThread(function()
    while true do
        Wait(10000)
        local now = GetGameTimer()
        for player, edit in pairs(pending) do
            if now - edit.lastSeenMs > EDIT_LIVENESS_MS then pending[player] = nil end
        end
        for player, creation in pairs(pendingCreation) do
            local silentMs = now - (creation.lastSeenMs or 0)
            if silentMs > CREATION_LIVENESS_MS then
                print(("[open77_appearance] creation for player=%s dropped: no heartbeat for %dms (the client is gone)")
                    :format(tostring(player), math.floor(silentMs)))
                pendingCreation[player] = nil
            end
        end
        -- The heartbeat that makes the readiness hold honest in both directions.
        --
        -- A creation still in flight refreshes its deadline, so a player deliberating
        -- over cheekbones for four minutes is never cut off. A hold with no creation
        -- behind it any more -- committed, rejected, aborted, expired above, or lost
        -- with a VM -- is released here, so every exit from the character creator ends
        -- the wait within ten seconds instead of leaving it to the platform timeout.
        for player in pairs(holding) do
            if pendingCreation[player] ~= nil then
                holdGate(player, "character_creation")
            else
                print(("[open77_appearance] releasing the readiness gate for player=%s: no creation in flight")
                    :format(tostring(player)))
                releaseGate(player)
            end
        end
    end
end)

print("Open77 persistent appearance server ready")
