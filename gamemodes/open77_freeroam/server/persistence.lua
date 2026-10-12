-- open77_freeroam — MySQL-backed player persistence + admin moderation.
--
-- The reference "server-owner database" resource: it owns tables in the
-- operator's own MySQL (not the platform master DB) and shows the intended
-- shape of an Open77 gamemode's persistence layer. Every player is keyed by
-- GetPlayerIdentifier(), the master-backed GUID, which is cryptographically
-- bound to the client's identity certificate — stronger than a name.
--
-- Degrades gracefully: with no database configured the resource still loads and
-- simply logs that persistence is disabled, so a freeroam server runs either way.
--
-- Read the two flags below before touching anything here. `MySQL` is injected by
-- the `database.access` permission, NOT by whether the operator configured a
-- database: on a server running with `database.enabled = false` the global is
-- present and every call through it raises `database_unavailable`. Testing the
-- global therefore proves only that we are allowed to ask. That mistake cost the
-- live freeroam server on 2026-09-03 -- `onPlayerConnected` raised on every join,
-- and a raising connect handler is not a local failure, it takes the join with it.
-- Readiness is proven by the boot probe at the bottom of this file and by nothing
-- else, and every round trip goes through dbThread() so a database that dies mid
-- session degrades to "no persistence" instead of to an error out of a handler.
local DB_GRANTED = MySQL ~= nil
local dbReady = false

local sessions = {}   -- playerId -> { identifier, name, startedAtMs }
local admins = {}     -- identifier -> true (loaded from the admin_groups table)

local function nowMs()
    return math.floor(Open77.time.monotonic() * 1000)
end

local function log(text)
    print("[freeroam-db] " .. text)
end

-- The single door to the database. Runs `fn` off the caller's stack so an event
-- handler never blocks on a round trip, and under pcall so a failure ends here
-- rather than unwinding into the handler that started it. The first failure also
-- latches persistence off: once the database has said no, every later call would
-- say the same, and a log line per player per join is how a small outage becomes
-- an unreadable journal.
local function dbThread(what, fn)
    if not dbReady then return end
    CreateThread(function()
        local ok, err = pcall(fn)
        if ok then return end
        dbReady = false
        log(string.format("%s failed; persistence disabled this run: %s", what, tostring(err)))
    end)
end

-- ---------------------------------------------------------------------------
-- Schema — created on first start. Kept tiny and self-contained.
-- ---------------------------------------------------------------------------
local function ensureSchema()
    if not dbReady then return end
    MySQL.update.await([[
        CREATE TABLE IF NOT EXISTS players (
            identifier   VARCHAR(64) NOT NULL PRIMARY KEY,
            name         VARCHAR(64) NOT NULL,
            money        BIGINT NOT NULL DEFAULT 0,
            playtime_ms  BIGINT NOT NULL DEFAULT 0,
            last_x       DOUBLE NULL,
            last_y       DOUBLE NULL,
            last_z       DOUBLE NULL,
            first_seen   DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
            last_seen    DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
        )
    ]])
    MySQL.update.await([[
        CREATE TABLE IF NOT EXISTS admin_groups (
            identifier VARCHAR(64) NOT NULL PRIMARY KEY,
            role       VARCHAR(32) NOT NULL DEFAULT 'admin'
        )
    ]])
    MySQL.update.await([[
        CREATE TABLE IF NOT EXISTS bans (
            identifier VARCHAR(64) NOT NULL PRIMARY KEY,
            reason     VARCHAR(255) NOT NULL,
            banned_at  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
        )
    ]])
end

local function loadAdmins()
    if not dbReady then return end
    local rows = MySQL.query.await("SELECT identifier FROM admin_groups") or {}
    admins = {}
    for _, row in ipairs(rows) do admins[row.identifier] = true end
    log(string.format("%d admin(s) loaded", #rows))
end

local function isBanned(identifier)
    if not dbReady then return nil end
    local row = MySQL.single.await("SELECT reason FROM bans WHERE identifier = ?", { identifier })
    return row and row.reason or nil
end

-- ---------------------------------------------------------------------------
-- Lifecycle: onPlayerConnected(playerId, name), onPlayerDisconnected(playerId)
-- ---------------------------------------------------------------------------
AddEventHandler("onPlayerConnected", function(playerIdStr, name)
    local playerId = tonumber(playerIdStr)
    if playerId == nil then return end
    local identifier = GetPlayerIdentifier(playerId)
    if identifier == nil then
        log("player " .. tostring(playerId) .. " has no identifier; skipping persistence")
        return
    end
    sessions[playerId] = { identifier = identifier, name = name or "player", startedAtMs = nowMs() }

    dbThread("player join", function()
        -- Ban gate: a banned identity is dropped immediately. (Platform-level
        -- bans are also enforced at ticket time by the master; this is the
        -- owner's own server-local ban list.)
        local banReason = isBanned(identifier)
        if banReason ~= nil then
            log(string.format("dropping banned player %s (%s)", identifier, banReason))
            DropPlayer(playerId, "Banned: " .. banReason)
            return
        end
        -- Upsert the player row and restore last position if we have it.
        MySQL.update.await([[
            INSERT INTO players (identifier, name, last_seen)
            VALUES (?, ?, CURRENT_TIMESTAMP)
            ON DUPLICATE KEY UPDATE name = VALUES(name), last_seen = CURRENT_TIMESTAMP
        ]], { identifier, name or "player" })
        local row = MySQL.single.await(
            "SELECT money, last_x, last_y, last_z FROM players WHERE identifier = ?", { identifier })
        if row ~= nil then
            log(string.format("%s joined (money=%d)", name or identifier, math.floor(row.money or 0)))
        end
    end)
end)

AddEventHandler("onPlayerDisconnected", function(playerIdStr)
    local playerId = tonumber(playerIdStr)
    if playerId == nil then return end
    local session = sessions[playerId]
    sessions[playerId] = nil
    if session == nil then return end

    local playedMs = nowMs() - session.startedAtMs
    local pos = Open77.players and Open77.players.position and Open77.players.position(playerId) or nil
    dbThread("player leave", function()
        if pos ~= nil then
            MySQL.update.await([[
                UPDATE players SET playtime_ms = playtime_ms + @dt,
                    last_x = @x, last_y = @y, last_z = @z, last_seen = CURRENT_TIMESTAMP
                WHERE identifier = @id
            ]], { dt = playedMs, x = pos.x, y = pos.y, z = pos.z, id = session.identifier })
        else
            MySQL.update.await(
                "UPDATE players SET playtime_ms = playtime_ms + ?, last_seen = CURRENT_TIMESTAMP WHERE identifier = ?",
                { playedMs, session.identifier })
        end
    end)
end)

-- ---------------------------------------------------------------------------
-- Admin commands. `source` 0 is the server console (always allowed); a player
-- source must be in the admin_groups table.
-- ---------------------------------------------------------------------------
local function findSessionByPlayerId(playerId)
    return sessions[playerId]
end

local function requireAdmin(source)
    if source == nil or source <= 0 then return true end               -- console
    local session = sessions[source]
    return session ~= nil and admins[session.identifier] == true
end

RegisterCommand("kick", function(source, args, raw)
    if not requireAdmin(source) then print("[freeroam-db] kick denied: not an admin") return end
    local target = tonumber(args[1])
    if target == nil then print("[freeroam-db] usage: kick <playerId> [reason]") return end
    local reason = table.concat(args, " ", 2)
    if reason == "" then reason = "Kicked by an administrator." end
    DropPlayer(target, reason)
    print(string.format("[freeroam-db] kicked %d (%s)", target, reason))
end, true)

RegisterCommand("ban", function(source, args, raw)
    if not requireAdmin(source) then print("[freeroam-db] ban denied: not an admin") return end
    local target = tonumber(args[1])
    if target == nil then print("[freeroam-db] usage: ban <playerId> [reason]") return end
    local reason = table.concat(args, " ", 2)
    if reason == "" then reason = "Banned by an administrator." end
    local session = findSessionByPlayerId(target)
    if session == nil then print("[freeroam-db] ban: player not found") return end
    dbThread("ban write", function()
        MySQL.update.await(
            "INSERT INTO bans (identifier, reason) VALUES (?, ?) ON DUPLICATE KEY UPDATE reason = VALUES(reason)",
            { session.identifier, reason })
    end)
    -- Note: this bans on the owner's server only. A platform-wide ban that
    -- blocks the identity from every server (enforced at connect-ticket time)
    -- is issued through the master; a future Open77.players.ban() binding will
    -- forward this there automatically.
    DropPlayer(target, "Banned: " .. reason)
    print(string.format("[freeroam-db] banned %s (%s)", session.identifier, reason))
end, true)

RegisterCommand("makeadmin", function(source, args, raw)
    -- Console-only: promote an online player to admin by player id.
    if source ~= nil and source > 0 then print("[freeroam-db] makeadmin is console-only") return end
    local target = tonumber(args[1])
    local session = target and sessions[target] or nil
    if session == nil then print("[freeroam-db] makeadmin: player not found") return end
    admins[session.identifier] = true
    dbThread("admin write", function()
        MySQL.update.await(
            "INSERT INTO admin_groups (identifier, role) VALUES (?, 'admin') ON DUPLICATE KEY UPDATE role = 'admin'",
            { session.identifier })
    end)
    print(string.format("[freeroam-db] %s is now an admin", session.identifier))
end, true)

-- ---------------------------------------------------------------------------
-- Boot.
-- ---------------------------------------------------------------------------
-- The probe. `dbReady` is raised optimistically only so ensureSchema/loadAdmins
-- are allowed to speak; the two of them together are the actual test, and the
-- first statement to come back `database_unavailable` lowers it again. Nothing
-- outside this thread may set it true.
if DB_GRANTED then
    CreateThread(function()
        dbReady = true
        local ok, err = pcall(function()
            ensureSchema()
            loadAdmins()
        end)
        if ok then
            log("player persistence ready (players / admin_groups / bans)")
        else
            dbReady = false
            log("no database available; persistence disabled this run: " .. tostring(err))
        end
    end)
else
    log("no database access granted — running without persistence (kick still works)")
end
