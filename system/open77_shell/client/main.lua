local MASTERS = {
    alpha = {
        id = "alpha",
        name = "Alpha",
        description = "Open77 public Alpha directory",
        catalog = "https://master.open2077.net/api/v1/servers?page=1&pageSize=100&gameBuild=23100&protocolMajor=1",
        localMaster = false
    },
    development = {
        id = "development",
        name = "Development",
        description = "Local development Master",
        catalog = "http://127.0.0.1:8090/api/v1/servers?page=1&pageSize=100&gameBuild=23100&protocolMajor=1",
        localMaster = true
    }
}
-- Authorities are chosen by the launcher (or the local test harness), never by an in-game directory.
local NETWORK_POLL_MS = 100

-- ---- Transient master-enrollment retry ---------------------------------------
-- The native identity enrollment uses a hard 3-5 s WinHTTP timeout with no
-- retry (networking/src/ClientIdentity.cpp). A single slow master causes
-- identity_http_send_failed:12002 and the shell used to abort autoconnect on
-- the FIRST failure, ending the launch on one hiccup. We retry only the
-- enrollment step (a catalog/identity fetch against the master -- idempotent,
-- resets no server state) a bounded number of times with a short backoff,
-- then fall through to the existing terminal handling. 12002 is
-- WSAETIMEDOUT; treat any identity_http_* send/connect/open/read failure and
-- the 12002 code as transient.
local ENROLLMENT_MAX_ATTEMPTS = 4
local ENROLLMENT_RETRY_BASE_MS = 2000

local function isTransientEnrollmentError(message)
    if message == nil then return false end
    local text = tostring(message)
    return text:find("identity_http_send_failed", 1, true) ~= nil
        or text:find("identity_http_connect_failed", 1, true) ~= nil
        or text:find("identity_http_open_failed", 1, true) ~= nil
        or text:find("identity_http_request_failed", 1, true) ~= nil
        or text:find("identity_http_read_failed", 1, true) ~= nil
        or text:find(":12002", 1, true) ~= nil  -- WSAETIMEDOUT
end

-- The only phases in which a connection attempt is still going somewhere.
--
-- `Open77.network.status().phase` is the native `SessionPhase` rendered by
-- Networking::Describe: offline, resolving, connecting, handshaking, active,
-- disconnecting, rejected, failed -- plus "unknown" for a value Describe does
-- not know. `connectionWorker` used to terminate on the two *named* failures,
-- `failed` and `rejected`, and nothing else. Every other way a session can end
-- left it spinning with `connecting = true` for its whole 18000 x 100 ms
-- budget -- thirty minutes -- during which `startConnection` and the
-- autoconnect handler both refuse the next attempt with
-- `connection_already_in_progress`. A player who left character creation by
-- disconnecting was stranded on the cover with no way back into the game.
--
-- Listing what is still *in flight* rather than what is terminal is the point:
-- a phase this table does not name ends the attempt, so a phase added to the
-- native enum later cannot reintroduce the wedge. `disconnecting` is terminal
-- here on purpose -- the attempt is over the moment a disconnect begins -- and
-- `offline` cannot be seen at the start of an attempt, because
-- `Open77.network.connect` publishes `resolving` synchronously before it
-- returns true and the worker is only created after that.
local CONNECTION_PROGRESS_PHASES = {
    resolving = true,
    connecting = true,
    handshaking = true,
    active = true
}

local shell
-- Session-only, shared by the connection screen and pause menu. Resource KVP
-- is server-scoped and must not carry a reveal choice into another game launch.
local addressesVisible = false
local function publishAddressPrivacy()
    local state = { visible = addressesVisible }
    if shell then shell:send("privacy:state", state) end
    TriggerEvent("open77:privacy:state", state)
end
AddEventHandler("open77:privacy:request", publishAddressPrivacy)
AddEventHandler("open77:privacy:set", function(payload)
    if type(payload) ~= "table" or type(payload.visible) ~= "boolean" then return end
    addressesVisible = payload.visible
    publishAddressPrivacy()
end)
local connecting = false
local enrolling = false
local intentGeneration = 0
local lastTarget = nil
local lastConnection = nil
local lastResourceProgress = nil
local resourcePhase = "idle"
local resourceError = ""
local shellVisible = false
local pendingDisconnectReason = nil
local musicVisible = false
local musicPreferences = { enabled = true, volume = 0.12 }
local function setMusicVisible(visible)
    musicVisible = visible == true
    if shell then shell:send("music:visibility", { visible = musicVisible }) end
end
-- The launcher hands the game the master it took its ticket from
-- (OP77_CONNECT_MASTER, read through Open77.session.launcherContext). That
-- choice outranks the one the page remembered in localStorage: the identity
-- must be enrolled with the master the target server verifies against. The
-- page's "shell:ready" used to flip the master back to its remembered value
-- while the autoconnect enrollment was in flight, so the hello went out with
-- a certificate from the other master (identity_proof_invalid).
local function launcherMasterId()
    local context = Open77.session and Open77.session.launcherContext
        and Open77.session.launcherContext() or nil
    local id = context and tostring(context.master or "") or ""
    if id ~= "" and MASTERS[id] then return id end
    return nil
end
local activeMasterId = launcherMasterId() or "alpha"
-- Held so the loading screen is actually seen. Declared here rather than beside
-- the hide handler because `connectionWorker` sets it far earlier in the file,
-- and a `local` declared after its first use silently becomes a global -- two
-- different variables, and the delay would never fire.
-- Open77.time.monotonic() is expressed in seconds while SetTimeout expects
-- milliseconds. Keep those units explicit: the previous mixed-unit code made
-- the final hide timing needlessly hard to reason about during a world swap.
local MINIMUM_LOADING_SECONDS = 2.5
local loadingSince = nil
local loadingTransitionActive = false
-- Guards the loading-cover teardown so it runs exactly once per handoff, no
-- matter which real-ready signal (loading bar full, bootstrap complete, or the
-- fallback timeout) arrives first. Re-armed when a new pristine load starts.
local loadingHandoffDone = false
local hideRequestGeneration = 0
local lastBootstrapPhase = ""

-- The handful of terminal reasons a player can meet while the creator is open.
-- Anything not listed falls back to the generic sentence; the raw token is never
-- shown here, because this notice is read by someone in the middle of building a
-- character, not by someone reading a diagnostic.
local REASON_TEXT = {
    user_quit = "You left the server while you were creating a character.",
    server_disconnected = "The server ended your session while you were creating a character.",
    connection_lost = "The connection to the server was lost while you were creating a character.",
    character_creation_cancelled = "Character creation was cancelled.",
    kicked = "You were disconnected from the server while creating a character."
}

local function transitionLog(message, ...)
    local rendered = select("#", ...) > 0 and string.format(message, ...) or message
    Open77.log.info("[shell-transition] " .. rendered)
end

local function send(name, payload)
    if name == "connection:begin" then
        lastConnection = { event = name, payload = payload }
        lastResourceProgress = nil
    elseif name == "connection:update" or name == "session:ended" then
        lastConnection = { event = name, payload = payload }
    elseif name == "resources:loading" then
        lastResourceProgress = payload
    end
    if shell then shell:send(name, payload or {}) end
end

-- A connection started by the autoconnect event has no WebUI request to
-- answer, so every reply along the connection path goes through this guard
-- instead of `shell:reply` directly.
local function reply(request, payload)
    if shell and request then shell:reply(request, payload) end
    if payload and payload.accepted == false and not request then
        send("connection:update", { phase = "failed", reason = payload.reason })
    end
end

-- ── server-provided loading screen (FiveM-style) ────────────────────────────
-- If the connected server's downloaded pack declares a `loadscreen`, mount that
-- page as a sandboxed surface ON TOP of the built-in cover (system layer, zIndex
-- 10 -- the native compositor draws by layer then zIndex, higher on top; the
-- surface is confined to the server pack by its own origin, so only the z-order
-- is ours). It becomes the screen the player sees; the built-in OPEN//77 cover
-- stays underneath as the fallback and covers the earlier connect/download phases
-- that run before the pack -- and therefore the loadscreen -- exists. It is driven
-- entirely from here, because the server's own resource Lua is not running yet
-- during the join. Absent the loadScreen native API (older client), the mount is
-- a no-op and the built-in cover stands in.
local loadScreenPage = nil
local loadScreenRealProgress = false
local loadScreenEstimateGeneration = 0

local function loadScreenSend(name, payload)
    if not loadScreenPage then return end
    pcall(function() loadScreenPage:send(name, payload or {}) end)
end

local function unmountServerLoadScreen()
    if not loadScreenPage then return end
    loadScreenEstimateGeneration = loadScreenEstimateGeneration + 1
    local page = loadScreenPage
    loadScreenPage = nil
    pcall(function() page:hide() end)
    pcall(function() page:destroy() end)
    transitionLog("server loadscreen unmounted")
end

local function mountServerLoadScreen(serverName)
    if loadScreenPage then return true end
    local info = Open77.session.loadScreen and Open77.session.loadScreen() or nil
    if not (info and info.available) then return false end
    local page, reason = WebUI.create({
        loadScreen = true,
        layer = "system",
        zIndex = 10,
        width = 1920,
        height = 1080,
        fps = 60,
        transparent = true,
        visible = false
    })
    if not page then
        transitionLog("server loadscreen mount failed reason=%s", tostring(reason))
        return false
    end
    loadScreenPage = page
    setMusicVisible(false) -- the server's custom loadscreen owns its own audio
    loadScreenRealProgress = false
    page:setFocus(false, false)
    page:show()
    loadScreenSend("server", { name = tostring(serverName or "") })
    loadScreenSend("progress", { phase = "world", label = "Loading arena", fraction = 0.0 })
    transitionLog("server loadscreen mounted server=%s", tostring(serverName))
    -- An estimated "Loading arena" fill while the world streams, replaced by the
    -- engine's real fill (open77:loading:progress) the instant it arrives.
    loadScreenEstimateGeneration = loadScreenEstimateGeneration + 1
    local generation = loadScreenEstimateGeneration
    CreateThread(function()
        local started = Open77.time.monotonic()
        while loadScreenPage and generation == loadScreenEstimateGeneration
            and not loadScreenRealProgress do
            local elapsed = Open77.time.monotonic() - started
            loadScreenSend("progress", {
                phase = "world", label = "Loading arena",
                fraction = 0.92 * (1.0 - math.exp(-elapsed / 4.5))
            })
            Wait(150)
        end
    end)
    return true
end

local function activeMaster()
    return MASTERS[activeMasterId] or MASTERS.alpha
end

-- The native refresh currently also enrolls the identity. Use it only for a
-- launcher-requested connection, never to fetch/poll an in-game server directory.
local function requestEnrollment()
    return Open77.network.refresh(activeMaster().catalog)
end

-- The pristine load is accepted long before a world exists, and nothing after
-- that point used to be watching. `Open77.session.loadPristine` returns as soon
-- as the native bridge has queued the request; the real work -- installing the
-- seed into Saved Games, enumerating saves, resolving the folder, streaming the
-- world -- happens afterwards, and every one of those steps can fail silently
-- from this resource's point of view. When one did, `loadingTransitionActive`
-- stayed true forever, the OPEN//77 cover stayed up, the cursor stayed captured
-- and the player had no way out but killing the process. That is the failure
-- mode this watchdog exists to make impossible.
--
-- It is a WATCHDOG ON THE HANDOFF, not a limit on how long a world may take to
-- load. `open77:worldReady` cancels it, so a slow machine streaming Night City
-- for two minutes is unaffected; only a handoff that never arrives at all trips
-- it. On a trip the client is disconnected and the connection screen is brought
-- back with the reason visible, which is the same recoverable outcome as an
-- abandoned character creator -- the player picks a server again instead of
-- staring at a cover.
local WORLD_HANDOFF_TIMEOUT_SECONDS = 150.0
-- Cover-hold fallback: if neither completion signal arrives after the world
-- starts streaming, lift the cover anyway. Tighter than the 150s catastrophic
-- watchdog above; a normal Night City stream finishes well inside this.
local LOADING_HANDOFF_FALLBACK_SECONDS = 30.0
local worldHandoffGeneration = 0

-- Both assigned below, once the shell helpers they need exist. `connectionWorker`
-- and the event handlers only ever call them at run time, so forward locals are
-- enough and they keep the arming call next to the accepted load it guards.
local armWorldHandoffWatchdog
local abandonWorldHandoff
local restoreConnectionScreen
local finishLoadingHandoff

-- Increments on every attempt so an abandoned worker (session ended, then a
-- new connection started before its next tick) can never drive the new
-- attempt alongside the fresh worker.
local connectionGeneration = 0

local function connectionWorker(server, request, generation)
    local lastPhase = ""
    local creatorAnnounced = ""
    transitionLog("worker started server=%s endpoint=%s", tostring(server.name), tostring(server.endpoint))
    for _ = 1, 18000 do
        if generation ~= connectionGeneration or not connecting then
            transitionLog("worker abandoned during phase=%s", tostring(lastPhase))
            -- An obsolete worker must not overwrite the new attempt's screen
            -- (or turn an intentional cancellation into a failure).
            if request then reply(request, { accepted = false, reason = "session_ended" }) end
            return
        end
        local status = Open77.network.status()
        if status then
            if status.phase ~= lastPhase then
                lastPhase = status.phase
                if loadingSince == nil then loadingSince = Open77.time.monotonic() end
                transitionLog(
                    "network phase=%s resources=%s resourcePhase=%s player=%s error=%s",
                    tostring(status.phase), tostring(status.hasResources), tostring(resourcePhase),
                    tostring(status.playerId), tostring(status.error))
                send("connection:update", {
                    phase = status.phase,
                    endpoint = server.endpoint,
                    server = server.name,
                    reason = status.error,
                    ping = status.ping,
                    -- Carried on every phase so the failure screen can name the
                    -- server precisely even on the autoconnect path, which has
                    -- no catalog selection to fall back on. Fields are nil for a
                    -- bare autoconnect target and the shell tolerates that.
                    serverProfile = {
                        version = server.serverVersion,
                        gameBuild = server.gameBuild,
                        protocolMajor = server.protocol and server.protocol.major or nil,
                        protocolMinor = server.protocol and server.protocol.minor or nil,
                        endpoint = server.endpoint
                    }
                })
            end
            if status.phase == "active" then
                if status.hasResources and resourcePhase == "failed" then
                    -- The native coordinator owns retry/backoff and the final
                    -- disconnect. Never abort its first retryable failure here.
                    connecting = false
                    reply(request, {
                        accepted = false,
                        reason = resourceError ~= "" and resourceError or "resource_download_failed"
                    })
                    return
                end
                if not status.hasResources or resourcePhase == "ready" then
                    local bootstrap = Open77.session.characterBootstrap()
                    local bootstrapPhase = bootstrap and tostring(bootstrap.phase) or "missing"
                    if bootstrapPhase ~= lastBootstrapPhase then
                        lastBootstrapPhase = bootstrapPhase
                        transitionLog(
                            "character bootstrap phase=%s family=%s generation=%s error=%s",
                            bootstrapPhase, tostring(bootstrap and bootstrap.family),
                            tostring(bootstrap and bootstrap.generation),
                            tostring(bootstrap and bootstrap.error))
                    end
                    -- Servers without a resource bundle retain the legacy
                    -- development behaviour. A real server resource must
                    -- explicitly resolve an existing character or request the
                    -- vanilla first-character wizard.
                    if not status.hasResources and bootstrap and bootstrap.phase == "waiting" then
                        bootstrap = { phase = "ready", family = "female" }
                    end
                    if bootstrap and bootstrap.phase == "failed" then
                        local failure = bootstrap.error ~= "" and bootstrap.error
                            or "character_bootstrap_failed"
                        transitionLog("worker ended on failed bootstrap reason=%s", tostring(failure))
                        Open77.network.disconnect(failure)
                        connecting = false
                        reply(request, { accepted = false, reason = failure })
                        return
                    end
                    if not bootstrap or bootstrap.phase ~= "ready" then
                        -- Announced on the phase EDGE only. This used to fire on
                        -- every 100 ms tick for as long as the creator was open,
                        -- and the page turns any connection:update into the
                        -- loading cover -- so a reveal delivered while the
                        -- creator was still unwinding was overwritten ten times
                        -- a second by a worker that had not noticed yet.
                        if creatorAnnounced ~= bootstrapPhase and
                            (bootstrapPhase == "creator_requested" or
                             bootstrapPhase == "creator_open" or
                             bootstrapPhase == "awaiting_commit") then
                            creatorAnnounced = bootstrapPhase
                            send("connection:update", {
                                phase = "creating_character",
                                endpoint = server.endpoint,
                                server = server.name,
                                reason = "Complete your character before entering Night City."
                            })
                        end
                        Wait(NETWORK_POLL_MS)
                        goto continue
                    end
                    local family = bootstrap.family == "male" and "male" or "female"
                    loadingTransitionActive = true
                    transitionLog("requesting pristine load family=%s", family)
                    local loaded, loadError = Open77.session.loadPristine(family)
                    if not loaded then
                        loadingTransitionActive = false
                        transitionLog("pristine load rejected family=%s error=%s", family, tostring(loadError))
                        Open77.network.disconnect("pristine_load_failed")
                        connecting = false
                        reply(request, {
                            accepted = false,
                            reason = loadError or "pristine_load_failed"
                        })
                        return
                    end
                    transitionLog("pristine load accepted family=%s; waiting for world handoff", family)
                    armWorldHandoffWatchdog(family)
                    -- The world is now streaming behind the cover. Tell the page
                    -- so it shows the "Loading world" phase with a moving bar
                    -- (estimated until the native real-% capture ships), instead
                    -- of leaving the player on a blind, motionless wait.
                    send("world:loading:begin", {})
                    -- If this server ships its own loadscreen, it is on disk now
                    -- (the pack finished downloading before the pristine load).
                    -- Mount it over the built-in cover for the world-stream phase.
                    mountServerLoadScreen(server.name)
                    connecting = false
                    reply(request, {
                        accepted = true,
                        development = false,
                        reason = "Server resources verified. Entering Night City.",
                        playerId = status.playerId,
                        tickRate = status.serverTickRate,
                        snapshotRate = status.snapshotRate,
                        resources = status.hasResources
                    })
                    return
                end
            end
            if not CONNECTION_PROGRESS_PHASES[status.phase] then
                connecting = false
                loadingTransitionActive = false
                transitionLog(
                    "worker ended on terminal phase=%s error=%s",
                    tostring(status.phase), tostring(status.error))
                reply(request, {
                    accepted = false,
                    reason = status.error ~= "" and status.error or status.phase
                })
                return
            end
        end
        ::continue::
        Wait(NETWORK_POLL_MS)
    end
    Open77.network.disconnect("handshake_timeout")
    connecting = false
    loadingTransitionActive = false
    transitionLog("worker timed out during phase=%s", tostring(lastPhase))
    reply(request, { accepted = false, reason = "handshake_timeout" })
end

-- The single entry into a connection attempt: the WebUI click and the
-- autoconnect event both land here, so the two paths cannot drift apart.
-- `request` is nil for autoconnect; every failure is still visible through
-- the transition log and the bridge's `net.state`.
local function startConnection(server, request)
    if connecting then
        reply(request, { accepted = false, reason = "connection_already_in_progress" })
        transitionLog("connection refused: already in progress endpoint=%s", tostring(server.endpoint))
        return
    end
    local reset, resetReason = Open77.session.resetCharacterBootstrap()
    if not reset then
        reply(request, { accepted = false, reason = resetReason or "character_bootstrap_failed" })
        transitionLog("connection refused: bootstrap reset failed reason=%s", tostring(resetReason))
        return
    end
    local accepted, reason = Open77.network.connect(server.endpoint)
    if not accepted then
        reply(request, { accepted = false, reason = reason or "connection_rejected" })
        transitionLog("connection refused: connect rejected reason=%s", tostring(reason))
        return
    end
    resourcePhase = "idle"
    resourceError = ""
    connecting = true
    connectionGeneration = connectionGeneration + 1
    local generation = connectionGeneration
    CreateThread(function() connectionWorker(server, request, generation) end)
end

AddEventHandler("onClientResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    local errorMessage
    shell, errorMessage = WebUI.create({
        entry = "web/index.html",
        layer = "system",
        width = 1920,
        height = 1080,
        fps = 144,
        -- Transparent so the `notice` view can be drawn OVER the vanilla
        -- character creator without hiding it. The browser and loading views
        -- paint their own opaque background (`body { background: var(--ink) }`),
        -- so nothing else changes: only a view that deliberately paints nothing
        -- lets the game through.
        transparent = true,
        visible = false
    })
    if not shell then
        print("Open77 shell WebUI failed: " .. tostring(errorMessage))
        return
    end
    transitionLog("WebUI created resource=%s", tostring(GetCurrentResourceName()))

    shell:on("shell:ready", function()
        publishAddressPrivacy()
        local stored = Open77.kvp.get("lobby:music", "")
        local prefs = type(stored) == "string" and stored ~= "" and Open77.json.decode(stored) or nil
        if type(prefs) == "table" and type(prefs.enabled) == "boolean" and type(prefs.volume) == "number"
            and prefs.volume == prefs.volume and prefs.volume >= 0 and prefs.volume <= 1 then
            musicPreferences = { enabled = prefs.enabled, volume = prefs.volume }
        end
        shell:send("music:preferences", musicPreferences)
        shell:send("music:visibility", { visible = musicVisible })
        local boot = Open77.session.launcherContext and Open77.session.launcherContext() or {}
        shell:send("shell:state", {
            version = Open77.runtime.version(),
            client = { version = Open77.runtime.version(), protocolMajor = boot.protocolMajor,
                protocolMinor = boot.protocolMinor, gameBuild = boot.gameBuild },
            target = lastTarget,
            canRetry = lastTarget ~= nil
        })
        if lastConnection then
            shell:send(lastConnection.event, lastConnection.payload)
            if lastConnection.event ~= "session:ended" and lastResourceProgress then
                shell:send("resources:loading", lastResourceProgress)
            end
        end
    end)
    -- What the page says it is showing, and why it changed. The Lua side can
    -- prove it SENT a reveal; only the page can prove it ACTED on one, and the
    -- difference between those two is the whole diagnosis of a stuck cover.
    shell:on("shell:trace", function(payload)
        if type(payload) ~= "table" then return end
        transitionLog("page view=%s from=%s source=%s",
            tostring(payload.view), tostring(payload.from), tostring(payload.source))
    end)
    shell:on("privacy:set", function(payload)
        TriggerEvent("open77:privacy:set", payload)
    end)
    shell:on("connection:retry", function(_, request)
        if connecting or enrolling or loadingTransitionActive then
            return reply(request, { accepted = false, reason = "connection_already_in_progress" })
        end
        if not lastTarget then return reply(request, { accepted = false, reason = "launcher_required" }) end
        reply(request, { accepted = true })
        TriggerEvent("open77:shell:autoconnect", lastTarget.endpoint, lastTarget.master)
    end)
    shell:on("connection:cancel", function(_, request)
        local bootstrap = Open77.session.characterBootstrap()
        if loadingTransitionActive or (bootstrap and
            (bootstrap.phase == "creator_requested" or bootstrap.phase == "creator_open" or bootstrap.phase == "awaiting_commit")) then
            return reply(request, { accepted = false, reason = "native_transition_in_progress" })
        end
        intentGeneration = intentGeneration + 1
        connectionGeneration = connectionGeneration + 1
        enrolling = false
        connecting = false
        loadingTransitionActive = false
        worldHandoffGeneration = worldHandoffGeneration + 1
        Open77.network.disconnect("connection_cancelled")
        TriggerEvent("open77:session:ended", "connection_cancelled")
        restoreConnectionScreen("connection_cancelled")
        reply(request, { accepted = true })
    end)
    shell:on("shell:launcher", function(_, request)
        local ok, reason = Open77.session.openLauncher()
        reply(request, { accepted = ok, reason = reason })
        -- Explicit button copy says it closes the game. A failed handoff never
        -- strands the player: retain the screen and its report instead.
        if ok then SetTimeout(600, function()
            local closed, closeReason = Open77.session.quitGame()
            if not closed then send("shell:actionError", { reason = closeReason or "game_window_close_failed" }) end
        end) end
    end)
    shell:on("shell:quit", function(_, request)
        local ok, reason = Open77.session.quitGame()
        reply(request, { accepted = ok, reason = reason })
    end)
    shell:on("music:preferences", function(payload, request)
        if type(payload) ~= "table" or type(payload.enabled) ~= "boolean"
            or type(payload.volume) ~= "number" or payload.volume ~= payload.volume
            or payload.volume < 0 or payload.volume > 1 then
            return reply(request, { accepted = false, reason = "invalid_music_preferences" })
        end
        musicPreferences = { enabled = payload.enabled, volume = payload.volume }
        local ok, reason = Open77.kvp.set("lobby:music", Open77.json.encode(musicPreferences))
        reply(request, { accepted = ok == true, reason = reason })
    end)
    shell:on("music:playback", function(payload)
        if type(payload) ~= "table" then return end
        transitionLog("lobby music playing=%s volume=%s error=%s",
            tostring(payload.playing == true), tostring(payload.volume), tostring(payload.error or ""))
    end)

end)

-- The autonomous test loop's way into a session. An external harness emits
-- this through the debug bridge (`resource.emit open77:shell:autoconnect
-- <endpoint> [master-id]`) and the connection then follows exactly the path
-- a human click takes: master enrollment, bootstrap reset, connect, resource
-- download, pristine load. Progress is observable from outside via
-- `net.state` and the [shell-transition] log lines; there is no WebUI
-- request to answer.
--
-- The optional master id matters because an identity certificate is issued
-- by one Master authority: a client enrolled with Alpha is rejected by a
-- server that verifies against the local Development master. Passing the id
-- refreshes that master's catalog first, which performs the enrollment.
AddEventHandler("open77:shell:autoconnect", function(endpoint, masterId)
    endpoint = tostring(endpoint or "")
    masterId = tostring(masterId or "")
    if connecting or enrolling or loadingTransitionActive then return end
    if endpoint == "" then
        return reply(nil, { accepted = false, reason = "invalid_server_endpoint" })
    end
    if masterId ~= "" and not MASTERS[masterId] then
        return reply(nil, { accepted = false, reason = "unknown_master" })
    end
    lastTarget = { endpoint = endpoint, name = endpoint, master = masterId }
    pendingDisconnectReason = nil
    enrolling = true
    intentGeneration = intentGeneration + 1
    connectionGeneration = connectionGeneration + 1 -- retires delayed restores from the previous session
    local intent = intentGeneration
    send("connection:begin", { target = lastTarget, attempt = intent, phase = "enrolling" })
    transitionLog("connection attempt=%d endpoint=%s master=%s", intent, endpoint, masterId)
    CreateThread(function()
        if masterId ~= "" then
            activeMasterId = masterId
            local enrolled = false
            for attempt = 1, ENROLLMENT_MAX_ATTEMPTS do
                if intent ~= intentGeneration then return end
                local before = Open77.network.catalog()
                local minimumGeneration = ((before and tonumber(before.generation)) or 0) + 1
                local requested, requestError = requestEnrollment()
                local failure = requested and "identity_update_timeout" or requestError
                if requested then
                    for _ = 1, 300 do
                        if intent ~= intentGeneration then return end
                        local snapshot = Open77.network.catalog()
                        if snapshot and (tonumber(snapshot.generation) or 0) >= minimumGeneration then
                            if snapshot.phase == "ready" and tostring(snapshot.url or "") == activeMaster().catalog then
                                enrolled = true
                                break
                            end
                            if snapshot.phase == "failed" then failure = snapshot.error; break end
                        end
                        Wait(NETWORK_POLL_MS)
                    end
                end
                if enrolled then break end
                if not isTransientEnrollmentError(failure) or attempt == ENROLLMENT_MAX_ATTEMPTS then
                    enrolling = false
                    transitionLog("connection attempt=%d enrollment failed reason=%s", intent, tostring(failure))
                    reply(nil, { accepted = false, reason = failure or "identity_update_failed" })
                    return
                end
                send("connection:update", { phase = "enrolling", endpoint = endpoint,
                    detail = ("Retrying identity verification (%d/%d)"):format(attempt + 1, ENROLLMENT_MAX_ATTEMPTS) })
                Wait(ENROLLMENT_RETRY_BASE_MS * attempt)
            end
        end
        if intent ~= intentGeneration then return end
        enrolling = false
        startConnection({ name = endpoint, endpoint = endpoint }, nil)
    end)
end)

AddEventHandler("open77:resources:progress", function(
    phase, received, total, completedFiles, totalFiles, resourceName, message, diagnosticJson)
    resourcePhase = tostring(phase or "idle")
    resourceError = resourcePhase == "failed" and tostring(message or "resource_download_failed") or ""
    send("resources:loading", {
        phase = resourcePhase,
        received = tonumber(received) or 0,
        total = tonumber(total) or 0,
        completedFiles = tonumber(completedFiles) or 0,
        totalFiles = tonumber(totalFiles) or 0,
        resource = tostring(resourceName or ""),
        message = tostring(message or ""),
        diagnostic = Open77.json.decode(tostring(diagnosticJson or "null"))
    })
end)

-- The engine's real world-streaming progress (0..1), captured natively from the
-- vanilla loading-screen fill (see Open77ScriptBridge.reds) and forwarded here.
-- It arrives after the resource download and during the pristine world handoff,
-- so the cover can show a true "Loading world" bar rather than a busy sweep. The
-- page applies it only while the loading view is up and ignores it otherwise.
AddEventHandler("open77:loading:progress", function(progress)
    local value = tonumber(progress) or 0
    send("world:loading", { progress = value })
    -- Feed the same real fill to a mounted server loadscreen, and stop its own
    -- estimate the moment the engine's true value takes over.
    if loadScreenPage then
        loadScreenRealProgress = true
        loadScreenSend("progress", { phase = "world", label = "Loading arena", fraction = value })
    end
    -- A full loading bar is the tightest "the vanilla loading screen is ending"
    -- signal: lift the cover right after it, so the cover masks that screen to
    -- its last frame and no further. Guarded by the transition so a stray
    -- in-world progress tick does nothing.
    if loadingTransitionActive and value >= 0.99 and finishLoadingHandoff then
        finishLoadingHandoff("loading_bar_full")
    end
end)

-- Loading-screen customization seam. A server-side resource can theme the
-- loading screen its players see by emitting this event with a small table
-- ({ id, strap, accent }); it is forwarded verbatim to the shell page, which
-- applies it defensively (see app.js applyLoadingTheme). This is deliberately a
-- thin hook, not a customization system: it proves servers can drive the
-- loading screen without the shell knowing anything server-specific.
-- TODO(open77): widen the payload (background art, tips, operator branding) once
-- a server-authored loading experience is designed.
AddEventHandler("open77:shell:loading-theme", function(theme)
    if type(theme) ~= "table" then theme = {} end
    send("loading:theme", {
        id = theme.id and tostring(theme.id) or nil,
        strap = theme.strap and tostring(theme.strap) or nil,
        accent = theme.accent and tostring(theme.accent) or nil
    })
end)

AddEventHandler("open77:shell:show", function()
    if not shell then return end
    hideRequestGeneration = hideRequestGeneration + 1
    shellVisible = true
    transitionLog("show requested generation=%d loading=%s",
        hideRequestGeneration, tostring(loadingTransitionActive))
    -- The native bridge only asks for the shell back once it has decided this
    -- process is sitting in the pre-game menu again with no load in flight. An
    -- accepted pristine load that reaches this point never took the world away,
    -- so the handoff has already failed -- measured at 147 ms after the accepted
    -- load when the save could not be resolved. Turning that into an error here
    -- rather than waiting out the watchdog is the difference between the player
    -- reading why and the player staring at a cover.
    --
    -- Re-checked on a delay so a benign ordering between the world attaching and
    -- `open77:worldReady` arriving cannot be mistaken for a failure: a real
    -- handoff clears `loadingTransitionActive` well inside this window.
    if loadingTransitionActive then
        SetTimeout(3000, function()
            abandonWorldHandoff("pristine_load_failed", "shell remounted with a load still in flight")
        end)
    end
    shell:send("shell:cover", { active = true })
    shell:show()
    setMusicVisible(true)
    shell:setFocus(true, true)
    shell:send("shell:reveal", { active = true })
    if pendingDisconnectReason then
        send("session:ended", { reason = pendingDisconnectReason })
        pendingDisconnectReason = nil
    end
end)

-- Defined here rather than beside their declarations because they reuse exactly
-- the work `open77:shell:show` does; the two must not drift apart, and the
-- helpers all of them need are declared above this point.
--
-- The player is disconnected first, so the reason reaches the page through the
-- ordinary `session:ended` path rather than through a second mechanism nobody
-- else knows about, and the connection screen comes back the way it comes back after any
-- other lost session.
abandonWorldHandoff = function(reason, detail)
    if not loadingTransitionActive then return end
    if not shell then return end
    loadingTransitionActive = false
    worldHandoffGeneration = worldHandoffGeneration + 1
    connecting = false
    loadingSince = nil
    transitionLog("pristine load abandoned reason=%s detail=%s", reason, tostring(detail))
    Open77.network.disconnect(reason)
    TriggerEvent("open77:session:ended", reason)

    restoreConnectionScreen(reason)
end

-- Puts the connection screen back in front of the player, with the reason, and
-- keeps putting it back for a couple of seconds.
--
-- Re-asserted rather than sent once, and deliberately WITHOUT `shell:cover`.
-- Disconnecting makes the native bridge run its own remount, and it emits
-- `open77:shell:cover` a few milliseconds later -- measured at 6 ms on
-- 2026-08-27 -- which puts the page straight back behind the loading cover.
-- A single restore therefore paints the reason and loses it again in the same
-- frame, which is what the first version of the handoff recovery did: the
-- session was correctly offline with `error=pristine_load_failed`, and the
-- player still saw nothing but the OPEN//77 cover.
--
-- Both page messages are idempotent (each one only sets the browser view), so
-- repeating them across the native churn is safe and needs no knowledge of its
-- exact ordering.
--
-- The focus call is the half that `session:ended` alone cannot supply. A
-- session that ends while the shell is still mounted -- an abandoned character
-- creator is the case that matters -- never makes the native bridge re-emit
-- `open77:shell:show`, because `s_shellRequested` was never cleared: the
-- creator guard in PreGameBridge returns before the unmount. The page would
-- then paint the browser behind a surface still left unfocused by the last
-- `shell:cover`, and the player could see the list but not click it.
restoreConnectionScreen = function(reason)
    local attempt = 0
    local generation = connectionGeneration
    local function restore(refresh)
        if not shell or generation ~= connectionGeneration then return end
        attempt = attempt + 1
        transitionLog("restoring connection screen attempt=%d reason=%s refresh=%s",
            attempt, tostring(reason), tostring(refresh))
        shellVisible = true
        hideRequestGeneration = hideRequestGeneration + 1
        shell:show()
        setMusicVisible(true)
        shell:setFocus(true, true)
        shell:send("shell:reveal", { active = true })
        send("session:ended", { reason = reason })
        pendingDisconnectReason = nil
    end
    restore(true)
    SetTimeout(400, function() restore(false) end)
    SetTimeout(1200, function() restore(false) end)
    SetTimeout(2500, function() restore(false) end)
end

armWorldHandoffWatchdog = function(family)
    -- A fresh pristine load: re-arm the one-shot cover teardown for it.
    loadingHandoffDone = false
    worldHandoffGeneration = worldHandoffGeneration + 1
    local generation = worldHandoffGeneration
    SetTimeout(math.ceil(WORLD_HANDOFF_TIMEOUT_SECONDS * 1000.0), function()
        if generation ~= worldHandoffGeneration then return end
        abandonWorldHandoff("pristine_load_timeout",
            ("no world handoff for family=%s after %.0fs"):format(
                tostring(family), WORLD_HANDOFF_TIMEOUT_SECONDS))
    end)
end

-- The session ended while the vanilla first-character creator owned the
-- pre-game menu. Nothing in this process can take the creator away safely --
-- PreGameBridge.cpp carries the five measurements that say so -- and the three
-- synthesised escape presses that used to stand in for the player were measured
-- on 2026-08-27 to do nothing at all. So say it instead, on screen, over the
-- creator, and let the player press escape themselves: their own press always
-- reaches the engine while the creator owns the menu, the vanilla unwind cancels
-- the bootstrap, and the connection screen comes back with the reason.
--
-- No focus is taken. The creator still needs the keyboard and the mouse, and the
-- notice is a strip of text with `pointer-events: none`, not a screen.
AddEventHandler("open77:pregame:creator_orphaned", function(reason)
    if not shell then return end
    local text = reason and REASON_TEXT[tostring(reason)] or nil
    transitionLog("creator orphaned reason=%s; showing the escape notice", tostring(reason))
    shell:send("shell:notice", {
        message = text or "Your session ended while you were creating a character."
    })
    -- Retire any hide still in flight: this surface must stay up until the
    -- player is out of the creator and the browser takes over.
    hideRequestGeneration = hideRequestGeneration + 1
    shellVisible = true
    shell:setFocus(false, false)
    shell:show()
end)

AddEventHandler("open77:shell:cover", function()
    if not shell then return end
    transitionLog(
        "cover requested visible=%s loading=%s bootstrap=%s",
        tostring(shellVisible), tostring(loadingTransitionActive), tostring(lastBootstrapPhase))
    shell:send("shell:cover", { active = true })
    shell:setFocus(false, false)
    shell:show()
    setMusicVisible(not loadScreenPage)
end)

-- The loading screen is held for a moment before the shell goes away.
--
-- Without it the screen can flash by in a few frames on a fast connect, which
-- reads as a glitch rather than as loading, and the surface is torn down while
-- the game is still streaming the world -- so the player watches a black frame
-- instead of a status. Holding it costs nothing: the game is busy anyway.
local function hideShell(reason, generation)
    if not shell then return end
    if generation ~= nil and generation ~= hideRequestGeneration then
        transitionLog(
            "discarded stale hide reason=%s generation=%s current=%s",
            tostring(reason), tostring(generation), tostring(hideRequestGeneration))
        return
    end
    shellVisible = false
    shell:send("shell:cover", { active = true })
    shell:setFocus(false, false)
    shell:hide()
    setMusicVisible(false)
    transitionLog(
        "WebUI hide applied reason=%s generation=%s loading=%s",
        tostring(reason), tostring(generation or hideRequestGeneration),
        tostring(loadingTransitionActive))
    loadingSince = nil
end

AddEventHandler("open77:shell:hide", function()
    if not shell then return end
    hideRequestGeneration = hideRequestGeneration + 1
    local generation = hideRequestGeneration
    local elapsed = loadingSince and (Open77.time.monotonic() - loadingSince)
        or MINIMUM_LOADING_SECONDS
    local remainingSeconds = MINIMUM_LOADING_SECONDS - elapsed
    transitionLog(
        "hide requested generation=%d elapsed=%.3fs remaining=%.3fs loading=%s",
        generation, elapsed, math.max(remainingSeconds, 0.0), tostring(loadingTransitionActive))
    if remainingSeconds > 0 then
        -- Focus is dropped straight away so the player is never holding input
        -- on a screen that is about to go; only the surface teardown waits.
        -- Keep the loading cover authoritative during that grace period.  A
        -- browser frame may otherwise remain visible over the pristine load
        -- after first-character creation has already been committed.
        shell:send("shell:cover", { active = true })
        shell:setFocus(false, false)
        SetTimeout(math.ceil(remainingSeconds * 1000.0), function()
            hideShell("minimum_loading_elapsed", generation)
        end)
        return
    end
    hideShell("native_hide", generation)
end)

-- Lifts the loading cover once the world is GENUINELY ready, and exactly once
-- per handoff. worldReady is not that moment (see the handler below): the cover
-- has to outlast the whole vanilla loading screen, which keeps rendering for the
-- entire stream. Whichever real-ready signal lands first calls this -- the
-- loading bar completing, or the pristine bootstrap completing -- and the
-- fallback timeout backstops both.
--
-- A REDengine world stream can recreate the CEF render target after the first
-- hide, leaving Chromium showing the last cover frame over a live world; the
-- second, ungated hide repairs that. Both calls are idempotent and scoped to an
-- accepted pristine transition, so an ordinary pre-game world attach cannot
-- dismiss the connection screen.
finishLoadingHandoff = function(reason)
    if not loadingTransitionActive or loadingHandoffDone then return end
    if not shell then return end
    loadingHandoffDone = true
    worldHandoffGeneration = worldHandoffGeneration + 1
    hideRequestGeneration = hideRequestGeneration + 1
    local generation = hideRequestGeneration
    transitionLog("loading handoff complete reason=%s generation=%d",
        tostring(reason), generation)
    shell:setFocus(false, false)
    -- Land the bar full before it goes, so the load reads as completed rather
    -- than cut off wherever the estimate happened to be.
    send("world:loading", { progress = 1.0 })
    loadScreenSend("progress", { phase = "world", label = "Loading arena", fraction = 1.0 })
    -- A short settle so the full bar and the world's first frame are seen.
    SetTimeout(300, function()
        hideShell("handoff:" .. tostring(reason), generation)
        unmountServerLoadScreen()
    end)
    SetTimeout(2500, function()
        if not shell or generation ~= hideRequestGeneration then return end
        shell:setFocus(false, false)
        shell:hide()
        setMusicVisible(false)
        unmountServerLoadScreen()
        loadingTransitionActive = false
        transitionLog("WebUI hide re-applied reason=handoff:%s generation=%d",
            tostring(reason), generation)
    end)
end

-- worldReady is the RuntimeScene attach -- ~0.1s into the load, while the vanilla
-- loading screen still has the whole stream to render (measured 2026-08-29:
-- worldReady at +0.1s, gameplay puppet at +10s). Lifting the cover here exposed
-- that screen for ten seconds. So this only releases input and arms a fallback;
-- the real-ready signals below do the teardown, and the cover keeps masking the
-- vanilla screen until then. The 150s watchdog remains the catastrophic net.
AddEventHandler("open77:worldReady", function()
    if not loadingTransitionActive then
        transitionLog("worldReady observed without an active pristine transition")
        return
    end
    transitionLog("worldReady: streaming started, holding cover for the real handoff")
    shell:setFocus(false, false)
    worldHandoffGeneration = worldHandoffGeneration + 1
    local generation = worldHandoffGeneration
    SetTimeout(math.ceil(LOADING_HANDOFF_FALLBACK_SECONDS * 1000.0), function()
        if generation ~= worldHandoffGeneration then return end
        transitionLog("loading handoff fallback fired after %.0fs",
            LOADING_HANDOFF_FALLBACK_SECONDS)
        finishLoadingHandoff("fallback_timeout")
    end)
end)

-- The pristine player bootstrap finishing is the reliable "the player is in the
-- world" edge (emitted to this host by ClientResourceHost). It lands a beat
-- after the loading screen ends, so it masks the whole screen with no gap and
-- backstops the loading-bar signal on any build where the bar never reads full.
AddEventHandler("open77:playerReset:complete", function()
    if not loadingTransitionActive then return end
    finishLoadingHandoff("player_bootstrap_complete")
end)

AddEventHandler("open77:session:ended", function(reason)
    pendingDisconnectReason = tostring(reason or "server_disconnected")
    intentGeneration = intentGeneration + 1
    enrolling = false
    connecting = false
    resourcePhase = "idle"
    resourceError = ""
    loadingTransitionActive = false
    unmountServerLoadScreen()
    worldHandoffGeneration = worldHandoffGeneration + 1
    hideRequestGeneration = hideRequestGeneration + 1
    transitionLog("session ended reason=%s", pendingDisconnectReason)
    if shellVisible then
        restoreConnectionScreen(pendingDisconnectReason)
        pendingDisconnectReason = nil
    end
end)
