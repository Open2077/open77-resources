-- open77_admin: gamemode-independent roster, audit, ACL projection and command registry.
-- Every privileged mutation is a restricted command checked by transport AND
-- by this registry at execution. Open77.acl reads the host's compiled ACL using
-- the authenticated session identity; no client role/identity grants authority.
-- Unprivileged hello/rated events report bounded presentation capabilities only.
-- Public self-only /pos and /rot live separately in server/public.lua.

local Config = Open77AdminConfig
local Catalog = Open77AdminCatalog

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------
local function nowMs()
    return math.floor(Open77.time.monotonic() * 1000)
end

local function log(text)
    print("[admin] " .. tostring(text))
end

--- Reply into the caller's terminal and chat.
---
--- Commands that MUTATE call this: an admin action should be visible, and the
--- chat line is the cheapest audit an operator ever reads. Commands that only
--- READ deliberately do not, so a 1 Hz panel poll leaves no trace -- the
--- dispatcher's own "queued by ..." acknowledgement is already filtered out by
--- open77_chat.
local function output(source, raw, ok, text)
    log(text)
    if source ~= nil and source > 0 then
        TriggerClientEvent("open77:command:result", source, raw or "", ok == true, tostring(text))
    end
    return ok == true
end

--- Structured push to one session. Server-initiated, so it is safe: the caller
--- already passed the ACL gate on the command that produced it.
local function push(playerId, channel, payload)
    if playerId == nil or playerId <= 0 then return false end
    return TriggerClientEvent("open77_admin:data", playerId, channel, payload) ~= false
end

local function finiteNumber(value)
    local number = tonumber(value)
    if number == nil or number ~= number or number == math.huge or number == -math.huge then
        return nil
    end
    return number
end

local function clamp(value, low, high)
    if value < low then return low end
    if value > high then return high end
    return value
end

local function round(value, places)
    local factor = 10 ^ (places or 0)
    return math.floor(value * factor + 0.5) / factor
end

-- ---------------------------------------------------------------------------
-- The roster
--
-- Read the host's authenticated sessions on each roster request. Client hello
-- only supplies optional presentation capabilities, never roster membership.
local players = {}

local function ensurePlayer(playerId)
    if playerId == nil or playerId <= 0 then return nil end
    local record = players[playerId]
    if record == nil then
        record = { firstSeenMs = nowMs(), capabilities = {} }
        players[playerId] = record
    end
    record.lastSeenMs = nowMs()
    return record
end

--- Prune ids the host no longer resolves. `Open77.players.name` returning nil
--- is the only disconnect signal that survives a reload, because the
--- `onPlayerDisconnected` for a player who left while this VM was down never
--- arrives.
local function prune()
    -- Read authoritative sessions, including clients that never send hello.
    for _, playerId in ipairs(Open77.players.all()) do ensurePlayer(playerId) end
    for playerId in pairs(players) do
        if Open77.players.name(playerId) == nil then
            players[playerId] = nil
        end
    end
end

AddEventHandler("onPlayerConnected", function(playerIdStr)
    -- Host events carry strings. Skip the tonumber and the table keys silently
    -- diverge from the numeric ids used everywhere else.
    local playerId = tonumber(playerIdStr)
    if playerId == nil or playerId <= 0 then return end
    ensurePlayer(playerId)
end)

AddEventHandler("onPlayerDisconnected", function(playerIdStr)
    local playerId = tonumber(playerIdStr)
    if playerId == nil then return end
    players[playerId] = nil
end)

--- The client's self-announcement. Not privileged -- see the header.
RegisterNetEvent("open77_admin:hello", function(payload)
    local playerId = source
    local record = ensurePlayer(playerId)
    if record == nil then return end
    if type(payload) ~= "table" then return end
    -- Publish only this session's own capabilities. Refresh at most once per
    -- second; ACL changes are also pushed by the existing subscription loop.
    local at = nowMs()
    if not record.contextHelloAt or at - record.contextHelloAt >= 1000 then
        record.contextHelloAt = at
        if Admin and Admin.watchAccess then Admin.watchAccess(playerId) end
    end
    record.capabilities = {
        governor = payload.governor == true,
        travel = payload.travel == true,
        panel = payload.panel == true,
    }
    -- The vehicle governor is CLIENT-LOCAL state, so a player who arrives after
    -- a cap was set would drive an ungoverned car in a world where everybody
    -- else's is capped. Replaying the mirror here is what closes that, and this
    -- handler is the right place because it fires on a fresh join, a reconnect
    -- and a client-side hot reload alike.
    --
    -- `Admin` is assigned at the end of this file and server/vehicles.lua adds
    -- `replayGovernor` after that, so the field is resolved at call time -- it
    -- does not exist while this handler is being registered.
    if record.capabilities.governor and Admin ~= nil and
        type(Admin.replayGovernor) == "function" then
        Admin.replayGovernor(playerId)
    end
end)

-- ---------------------------------------------------------------------------
-- Audit
--
-- A ring buffer for the current uptime. Warden keeps a durable JSONL trail of
-- everything done through the panel, but Lua has no reader for it, so in-game
-- and panel history are two histories today. `Open77.audit.append` writing into
-- the same file is the small C# change that would make them one.
-- ---------------------------------------------------------------------------
local audit = { entries = {}, nextSeq = 1 }

--- Audit entries carried by one `admin:audit` push. See the read handler for
--- why this is not `Config.limits.auditEntries`.
local kAuditPushed = 50

local function record(source, action, detail, ok)
    local entry = {
        seq = audit.nextSeq,
        atMs = nowMs(),
        actor = source ~= nil and source > 0 and source or 0,
        actorName = source ~= nil and source > 0 and (Open77.players.name(source) or "?") or "console",
        action = tostring(action),
        detail = tostring(detail or ""),
        ok = ok ~= false,
    }
    audit.nextSeq = audit.nextSeq + 1
    audit.entries[#audit.entries + 1] = entry
    local overflow = #audit.entries - Config.limits.auditEntries
    if overflow > 0 then
        -- table.move is the cheap shift; rebuilding the array every call would
        -- allocate 200 tables at the exact moment the server is busiest.
        table.move(audit.entries, overflow + 1, #audit.entries, 1)
        for index = #audit.entries, #audit.entries - overflow + 1, -1 do
            audit.entries[index] = nil
        end
    end
    return entry
end

-- ---------------------------------------------------------------------------
-- Rate limiting
--
-- The transport caps 32 events/second per session, but that limits packets,
-- not effect: thirty vehicle spawns a second is inside the budget.
-- ---------------------------------------------------------------------------
local lastRead, lastAction = {}, {}

--- Keyed by caller AND command, deliberately.
---
--- A single per-caller bucket looks tidier and is wrong: the panel issues three
--- different reads in one poll tick, and a shared bucket would let the first
--- one silently starve the other two forever. Per-command still bounds each
--- one, which is what the limit is for.
local function throttled(source, name, bucket, intervalMs)
    if source == nil or source <= 0 then return false end -- console is never throttled
    local key = source .. ":" .. name
    local at = nowMs()
    local previous = bucket[key]
    if previous ~= nil and at - previous < intervalMs then return true end
    bucket[key] = at
    return false
end

-- ---------------------------------------------------------------------------
-- The command registry
--
-- Every registration here is restricted. `register` exists so that cannot be
-- forgotten: there is no argument for "unrestricted" and no code path that
-- reaches RegisterCommand without `true`.
-- ---------------------------------------------------------------------------
local suggestions = {}
local registered = {}
local accessWatch = {}

local function allowed(playerId, command)
    if playerId == 0 then return true end
    return Open77.acl ~= nil and Open77.acl.isAllowed(playerId, "command." .. command) == true
end

local function accessSnapshot(playerId)
    local commands = {}
    for command in pairs(registered) do
        local available = not command:match("^admin%.weap%.") or GetResourceState("open77_weapons") == "running"
        commands[command] = available and allowed(playerId, command)
    end
    for _, command in ipairs({"weather.set", "weather.time.set", "weather.time.freeze", "weather.time.resume", "weather.random"}) do
        commands[command] = GetResourceState("open77_weather") == "running" and allowed(playerId, command)
    end
    -- The drone-show adapter, same rule: the rows exist only while the resource
    -- that owns the swarm is running, and only for an operator the ACL allows.
    -- This package neither implements nor validates the command; it offers it.
    for _, key in ipairs({ "drones", "celebrations" }) do
        local adapter = (Config.props or {})[key] or {}
        local command = adapter.command or (key == "drones" and "droneshow" or "fireworks")
        commands[command] = adapter.resource ~= nil
            and GetResourceState(adapter.resource) == "running"
            and allowed(playerId, command)
    end
    local roles = Open77.acl and Open77.acl.roles(playerId) or {}
    for _, mode in ipairs({ "foot", "race", "ffa", "blade", "cancel" }) do
        local command = "admin.playtest." .. mode
        commands[command] = GetResourceState("freeroam") == "running" and allowed(playerId, command)
    end
    return { commands = commands, roles = type(roles) == "table" and roles or {}, available = Open77.acl ~= nil }
end

local function watchAccess(playerId)
    accessWatch[playerId] = true
    local snapshot = accessSnapshot(playerId)
    push(playerId, "access", snapshot)
    return snapshot
end

--- Declare one privileged command.
---
--- @param name    string   without the leading slash; the ACL permission is
---                         always `command.<name>`
--- @param spec    table    { help, params, mutation, requiresPlayer, handler }
local function register(name, spec)
    if registered[name] ~= nil then
        log("duplicate command refused: " .. name)
        return
    end
    registered[name] = spec

    --- The one wrapper every command goes through. Factored out rather than
    --- written twice so an alias can never end up with different guards --
    --- or, worse, with none.
    local function dispatch(commandName)
        return function(source, args, raw)
            -- Recheck at execution, not just receipt: commands are scheduled and
            -- a role can be revoked between packet validation and this coroutine.
            if source > 0 and not allowed(source, commandName) then
                watchAccess(source)
                return output(source, raw, false, "permission_denied:command." .. commandName)
            end
            local record_ = ensurePlayer(source)
            if spec.requiresPlayer and (source == nil or source <= 0) then
                return output(source, raw, false,
                    commandName .. " targets the sending player and is unavailable from the console")
            end

            local bucket = spec.mutation and lastAction or lastRead
            local interval = spec.mutation and Config.limits.actionIntervalMs
                or Config.limits.readIntervalMs
            if throttled(source, name, bucket, interval) then
                -- Reads answer silently: a throttled poll must not become chat
                -- spam. Throttling is keyed on the canonical `name`, not on the
                -- alias, so /noclip and /admin.self.noclip share one budget.
                if spec.mutation then output(source, raw, false, "slow down") end
                return
            end

            -- The handler is told WHICH name was typed. Read commands use that
            -- to decide whether to answer in prose: the panel always calls the
            -- canonical `admin.read.*`, so a human typing the `/players` alias
            -- gets a chat listing while a 1 Hz poll stays silent.
            local ok, detail = spec.handler(source, args, raw, record_, commandName)
            if spec.mutation then
                record(source, commandName, detail or "", ok)
            end
        end
    end

    RegisterCommand(name, dispatch(name), true) -- <- restricted. Never anything else in this file.

    if spec.help ~= nil then
        suggestions[#suggestions + 1] = {
            command = "/" .. name,
            help = spec.help,
            parameters = spec.params or {},
        }
    end

    -- The short alias, when one is configured for this command: the same
    -- handler and the same guards, under a second name.
    --
    -- Rights are NOT shared. The transport derives the permission from the word
    -- actually typed, so the alias carries its own `command.<alias>` -- which is
    -- exactly right. An operator who may run /admin.self.noclip does not
    -- silently gain /noclip; a server that wants the short form grants it once,
    -- deliberately.
    if Config.aliases.enabled then
        for alias, target in pairs(Config.aliases.map) do
            if target == name and registered[alias] == nil then
                registered[alias] = spec
                RegisterCommand(alias, dispatch(alias), true)
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Target resolution and the two safety gates
--
-- These are the rules this codebase has already paid for. Both are cheap and
-- both are non-negotiable.
-- ---------------------------------------------------------------------------

--- Resolve a target token to a player id. `me` means the caller.
local function resolveTarget(source, token)
    if token == nil or token == "me" or token == "self" then
        if source == nil or source <= 0 then return nil, "console has no player to target" end
        return source
    end
    local playerId = tonumber(token)
    if playerId == nil or playerId <= 0 or playerId % 1 ~= 0 then
        return nil, "invalid playerId (use a number, or 'me')"
    end
    if Open77.players.name(playerId) == nil then
        return nil, "player " .. playerId .. " is not connected"
    end
    return playerId
end

--- May this player be ACTED UPON at all?
---
--- A session reporting no life state is the "continue" screen -- an active
--- session that is not an incarnation. A server-side teleport received there
--- crashes the client; that is measured, not theoretical.
---
--- The phase STRING differs between hosts (`respawn_pending` on the client,
--- `respawnpending` on the server), which is why liveness is asked through
--- `isDead`, resolved natively from the enum and immune to the split.
local function actionable(playerId)
    local life = Open77.players.getLifeState(playerId)
    if life == nil then
        return false, "player " .. playerId .. " is not incarnated (loading, or on the continue screen)"
    end
    return true, life
end

--- May this player be MOVED?
---
--- Placement additionally waits on the readiness barrier. On 2026-08-27
--- enabling the database for the ranked ladder also enabled appearance
--- persistence, and two individually correct resources both acting on the same
--- joiner took the live server down. This resource never HOLDS the gate -- an
--- admin tool has nothing to ask a joiner -- it only respects it.
local function placeable(playerId)
    local ok, detail = actionable(playerId)
    if not ok then return false, detail end
    if type(Open77.ready) == "table" and type(Open77.ready.isReady) == "function" then
        if not Open77.ready.isReady(playerId) then
            return false, "player " .. playerId .. " is still behind the readiness gate"
        end
    end
    return true, detail
end

--- The one placement primitive. Kill -> respawn, never a transform write: a
--- direct teleport over any real distance drops the player into unstreamed
--- world, and only the respawn transaction carries the fade, the streaming
--- preload and the grace window.
local function placeAt(playerId, position, heading, bucket, reason)
    local ok, detail = placeable(playerId)
    if not ok then return false, detail end

    local life = detail
    if not Open77.players.isDead(playerId) then
        local killed, killError = Open77.players.kill(playerId, {
            cause = "script",
            weapon = "open77_admin:" .. tostring(reason or "move"),
        })
        if not killed then return false, "kill rejected: " .. tostring(killError) end
    end

    local respawned, respawnError = Open77.players.respawn(playerId, {
        position = position,
        heading = heading or 0.0,
        bucket = bucket or (life and life.bucket) or 0,
        health = Config.teleport.health,
        graceMs = Config.teleport.graceMs,
    })
    if not respawned then return false, "respawn rejected: " .. tostring(respawnError) end
    return true
end

--- Tell a player something happened to them. Never move somebody silently.
local function announce(playerId, text)
    TriggerClientEvent("chat:addMessage", playerId, {
        type = "system",
        author = "ADMIN",
        text = tostring(text),
        color = { 34, 216, 226 },
    })
end

-- ---------------------------------------------------------------------------
-- The two openers
--
-- `/admin` raises the compact keyboard menu, which does NOT take focus: the
-- operator keeps mouse-look and every gameplay key while using it. `/adminfull`
-- raises the full console, which does take focus, because reading a roster and
-- driving at the same time is not a thing anybody does.
--
-- The full panel used to BE `/admin`. Renaming it moved its permission from
-- `command.admin` to `command.adminfull`, which is a real consequence and not a
-- cosmetic one: an existing role granting `command.admin` now opens the compact
-- menu and no longer opens the console. That is the intended split -- the fast
-- menu is the thing most operators want most of the time -- but a server
-- upgrading must add `command.adminfull` to whoever should keep the console.
-- acl-roles.example.jsonc has been updated to list both.
-- ---------------------------------------------------------------------------
register("admin", {
    help = "Open the compact keyboard admin menu. Arrows to move, Enter to pick.",
    requiresPlayer = true,
    mutation = false,
    handler = function(source, _, raw)
        -- Small on purpose. The menu builds its own screens from the shared
        -- config the client already has; the only thing it cannot know without
        -- being told is which roster row is the operator.
        local access = watchAccess(source)
        push(source, "menu", {
            label = Config.label,
            you = { playerId = source, name = Open77.players.name(source) },
            access = access,
        })
        -- No `TriggerClientEvent` of its own: the push above IS the signal, and
        -- the client toggles on it. One message rather than two, and no way for
        -- the toggle to arrive before the identity it needs.
        return true, "menu toggled"
    end,
})

register("adminfull", {
    help = "Open the full Open77 admin console. Takes the mouse and keyboard.",
    requiresPlayer = true,
    mutation = false,
    handler = function(source, _, raw)
        watchAccess(source)
        push(source, "open", {
            label = Config.label,
            catalog = {
                count = Catalog.count,
                groups = Catalog.groups,
                classes = Catalog.classes,
                build = Catalog.build,
            },
            limits = Config.limits,
            governor = Config.vehicles.governor,
            travel = Config.travel,
            you = {
                playerId = source,
                name = Open77.players.name(source),
            },
        })
        TriggerClientEvent("open77_admin:open", source)
        return true, "panel opened"
    end,
})

-- ---------------------------------------------------------------------------
-- Reads
-- ---------------------------------------------------------------------------
register("admin.read.players", {
    help = "Roster with position, bucket, life state and health.",
    handler = function(source, _, raw, _record, invokedAs)
        prune()
        local origin = source > 0 and Open77.players.position(source) or nil
        local roster, count = {}, 0
        for playerId, entry in pairs(players) do
            local name = Open77.players.name(playerId)
            if name ~= nil then
                count = count + 1
                local position = Open77.players.position(playerId)
                local life = Open77.players.getLifeState(playerId)
                local health = Open77.players.getHealth(playerId)
                local distance
                if origin ~= nil and position ~= nil and origin.bucket == position.bucket then
                    local dx, dy, dz = position.x - origin.x, position.y - origin.y, position.z - origin.z
                    distance = round(math.sqrt(dx * dx + dy * dy + dz * dz), 1)
                end
                roster[#roster + 1] = {
                    playerId = playerId,
                    name = name,
                    roles = Open77.acl and Open77.acl.roles(playerId) or {},
                    identifier = Open77.players.identifier(playerId),
                    bucket = (position and position.bucket) or (life and life.bucket) or 0,
                    phase = life and life.phase or nil,
                    incarnated = life ~= nil,
                    dead = life ~= nil and Open77.players.isDead(playerId) or false,
                    -- Absolute points, and the maximum beside them. `health`
                    -- from getHealth is NOT a fraction, unlike the `health`
                    -- field revive/respawn take -- sending only the number
                    -- would let the panel render "1%" for a player on full
                    -- health of 1/1.
                    health = health and round(health.health or 0, 1) or nil,
                    maxHealth = health and round(health.maxHealth or 100, 1) or nil,
                    armor = health and round(health.armor or 0, 1) or nil,
                    godMode = health and health.godMode == true or false,
                    position = position and {
                        x = round(position.x, 2), y = round(position.y, 2), z = round(position.z, 2),
                    } or nil,
                    distance = distance,
                    governor = entry.capabilities and entry.capabilities.governor == true,
                    -- Ping is deliberately absent. The session layer knows it;
                    -- Lua has no reader. An absent column beats a fabricated one.
                }
            end
        end
        table.sort(roster, function(a, b) return a.playerId < b.playerId end)
        -- Bound each event below the 1024-value-node budget even on a large
        -- server. The client appends ordered chunks; IDs remain server-owned.
        local offset = 0
        repeat
            local chunk = {}
            for index = offset + 1, math.min(offset + 8, count) do chunk[#chunk+1] = roster[index] end
            push(source, "players", { players = chunk, count = count, offset = offset,
                done = offset + #chunk >= count, atMs = nowMs() })
            offset = offset + #chunk
        until offset >= count

        -- Prose only when a human typed it. `invokedAs` is the alias when the
        -- command came in as `/players`; the panel always uses the canonical
        -- name and so gets structured data and complete silence.
        if source <= 0 or invokedAs ~= "admin.read.players" then
            -- ONE output call, not one per row. `output` sends a net event, and
            -- the transport budget is 32 events per second per session -- a
            -- thirty-player roster sent a line at a time would spend the whole
            -- budget in a single tick.
            local lines = { string.format("players online (%d):", count) }
            for _, item in ipairs(roster) do
                lines[#lines + 1] = string.format("  %d  %s  bucket=%d  %s  %s",
                    item.playerId, item.name, item.bucket,
                    item.incarnated and (item.dead and "down" or "alive") or "not incarnated",
                    item.position and string.format("%.0f %.0f %.0f",
                        item.position.x, item.position.y, item.position.z) or "-")
            end
            output(source, raw, true, table.concat(lines, "\n"))
        end
        return true
    end,
})

register("admin.read.audit", {
    help = "Recent admin actions for the current server uptime.",
    handler = function(source, _, _)
        -- The TAIL, not the ring. An audit entry is seven fields, so sixteen
        -- value nodes once it is in an array, and the client surface refuses a
        -- payload over 1024 nodes -- silently, by never delivering it. The full
        -- 200-entry ring is 3200 and would mean the Audit tab simply stopped
        -- filling in once the server had been up a while. Fifty is 806.
        --
        -- The console branch below still walks every entry: that path writes to
        -- the log and is not carrying a payload anywhere.
        local recent, first = {}, math.max(#audit.entries - kAuditPushed + 1, 1)
        for index = first, #audit.entries do recent[#recent + 1] = audit.entries[index] end
        push(source, "audit", { entries = recent, atMs = nowMs(), total = #audit.entries })
        if source <= 0 then
            for _, entry in ipairs(audit.entries) do
                log(string.format("  #%d %s %s %s %s",
                    entry.seq, entry.actorName, entry.action, entry.detail,
                    entry.ok and "ok" or "FAILED"))
            end
        end
        return true
    end,
})

-- ---------------------------------------------------------------------------
-- Chat suggestions
--
-- Registered on `chat:ready` like every other resource. This is also how the
-- panel's Console tab builds its palette: it registers the same net event and
-- harvests what every resource on the server publishes, so the command list is
-- live and coupled to nothing.
-- ---------------------------------------------------------------------------
RegisterNetEvent("chat:ready", function()
    TriggerClientEvent("chat:addSuggestions", source, suggestions)
end)

-- ---------------------------------------------------------------------------
-- The shared surface for the other server files.
--
-- Server resources cannot call each other -- no exports, no cross-resource
-- event bus -- so a package splits by FILE, not by resource, and the files
-- reach each other through one plain global. Manifest order is load order, so
-- main.lua declares this and everything else consumes it.
-- ---------------------------------------------------------------------------
Admin = {
    Config = Config,
    Catalog = Catalog,

    nowMs = nowMs,
    log = log,
    output = output,
    push = push,
    finiteNumber = finiteNumber,
    clamp = clamp,
    round = round,

    players = players,
    ensurePlayer = ensurePlayer,
    prune = prune,

    register = register,
    record = record,

    resolveTarget = resolveTarget,
    actionable = actionable,
    placeable = placeable,
    placeAt = placeAt,
    announce = announce,
    allowed = allowed,
    accessSnapshot = accessSnapshot,
    watchAccess = watchAccess,
}

-- Connected sessions subscribe to their own ACL. No client-defined permissions
-- or identity ever enter this channel. Revocations are pushed without reconnect.
CreateThread(function()
    local previous = {}
    while true do
        for playerId in pairs(accessWatch) do
            if Open77.players.name(playerId) == nil then
                accessWatch[playerId], previous[playerId] = nil, nil
            else
                local snapshot = accessSnapshot(playerId)
                local digest = json.encode(snapshot)
                if previous[playerId] ~= digest then
                    previous[playerId] = digest
                    push(playerId, "access", snapshot)
                end
            end
        end
        Wait(1000)
    end
end)

log(string.format(
    "ready -- %d vehicle records, %d saved locations, aliases %s",
    Catalog.count, #Config.locations, Config.aliases.enabled and "on" or "off"))
