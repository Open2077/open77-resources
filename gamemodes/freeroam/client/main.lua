-- Freeroam client: presence announce, map blips and the /freeroam menu page.
-- No authority logic lives here — spawns, respawns, vehicles and teleports are
-- decided by server/main.lua; the menu only forwards button presses to it.

local Config = FreeroamConfig

local blipsCreated = false
local menu
local menuOpen = false
local canManageTv = false
local hud
local hudReady = false
local hudClaimsActive = false
local lastHudClaimAttemptAt = -1000

-- The freeroam HUD replaces every supported vanilla gameplay readout except
-- the map cluster.  The minimap, compass and clock deliberately remain native:
-- unlike the other widgets they own the GPS route and in-world mappin bridge.
local hiddenHudComponents = { "health", "stamina", "weapon", "speedometer" }
local hiddenHudClaims = {}

local hudView = {
    ready = false,
    armor = 0,
    health = { value = 0, maximum = 100 },
    stamina = { value = 0, maximum = 100 },
    weapon = { equipped = false },
    vehicle = { active = false },
}

local weaponRequests = {}
local lastWeaponRequestAt = 0

local weaponCatalog = {}
for _, item in ipairs((Config.weapons and Config.weapons.catalog) or {}) do
    if item.record then weaponCatalog[tostring(item.record)] = item end
end
for _, item in ipairs((DeathmatchConfig.blade or {}).weapons or {}) do
    weaponCatalog[item.record] = { label=item.label, category=item.category, melee=true }
end

local vehicleCatalog = {}
for _, item in ipairs((Config.vehicles and Config.vehicles.catalog) or {}) do
    if item.record then vehicleCatalog[tostring(item.record)] = item end
end

local function number(value, fallback)
    local parsed = tonumber(value)
    if parsed == nil or parsed ~= parsed then return fallback or 0 end
    return parsed
end

local function truthy(value)
    return value == true or tostring(value) == "true" or tostring(value) == "1"
end

local function nowMs()
    if Open77.time and Open77.time.monotonic then
        return number(Open77.time.monotonic(), 0) * 1000
    end
    return 0
end

local function recordLabel(record, fallback)
    local text = tostring(record or "")
    if text == "" then return fallback end
    text = text:gsub("^[^.]+%.", ""):gsub("^Preset_", ""):gsub("_player$", "")
        :gsub("_", " ")
    return text
end

local function pushHud()
    hudView.hintsVisible = not menuOpen
        and not (FreeroamRaceClient and FreeroamRaceClient.ownsHud())
        and not (FreeroamPvpClient and FreeroamPvpClient.hasActivity())
    if hud and hudReady then hud:send("freeroam:hud", hudView) end
end

local function setVanillaHudHidden(hidden)
    if type(Open77.hud) ~= "table" or type(Open77.hud.setVisible) ~= "function" then
        print("[freeroam] vanilla HUD API unavailable; stock readouts left visible")
        return false
    end

    local allAccepted = true
    for _, component in ipairs(hiddenHudComponents) do
        if hidden or hiddenHudClaims[component] then
            local ok, accepted, result = pcall(Open77.hud.setVisible, component, not hidden)
            if ok and accepted then
                hiddenHudClaims[component] = hidden or nil
            else
                allAccepted = false
                print(string.format("[freeroam] HUD %s %s failed: %s", component,
                    hidden and "hide" or "restore", tostring(ok and result or accepted)))
            end
        end
    end
    hudClaimsActive = hidden and allAccepted or false
    return allAccepted
end

local function activateCustomHudIfReady()
    if not hudReady or not hudView.ready or hudClaimsActive then return end
    local at = nowMs()
    if at - lastHudClaimAttemptAt < 1000 then return end
    lastHudClaimAttemptAt = at
    if setVanillaHudHidden(true) then
        print("[freeroam] design-system HUD active; vanilla combat readouts hidden")
    end
end

local function sampleStats()
    if type(Open77.stats) ~= "table" or type(Open77.stats.get) ~= "function" then return end
    local ok, state = pcall(Open77.stats.get)
    if not ok or type(state) ~= "table" then return end
    local health = type(state.health) == "table" and state.health or {}
    local stamina = type(state.stamina) == "table" and state.stamina or {}
    local maxHealth = math.max(1, number(health.maximum or health.max, 100))
    local maxStamina = math.max(1, number(stamina.maximum or stamina.max, 100))
    hudView.health = {
        value = math.max(0, number(health.value or health.current, 0)),
        maximum = maxHealth,
    }
    hudView.stamina = {
        value = math.max(0, number(stamina.value or stamina.current, 0)),
        maximum = maxStamina,
    }
    hudView.armor = math.max(0, number(state.armor, 0))
    hudView.ready = true
end

local function sampleVehicle()
    if type(Open77.vehicles) ~= "table"
        or type(Open77.vehicles.getPlayerSeat) ~= "function"
        or type(Open77.vehicles.get) ~= "function" then
        hudView.vehicle = { active = false }
        return
    end

    local seatOk, seat = pcall(Open77.vehicles.getPlayerSeat)
    if not seatOk or type(seat) ~= "table" or seat.vehicleId == nil then
        hudView.vehicle = { active = false }
        return
    end
    local vehicleOk, vehicle = pcall(Open77.vehicles.get, seat.vehicleId)
    if not vehicleOk or type(vehicle) ~= "table" then
        hudView.vehicle = { active = false }
        return
    end

    local record = tostring(vehicle.record or "")
    local configured = vehicleCatalog[record]
    local gear = math.floor(number(vehicle.gear, 0))
    local reversing = vehicle.reversing == true or gear < 0
    hudView.vehicle = {
        active = true,
        id = seat.vehicleId,
        record = record,
        label = configured and configured.label or recordLabel(record, "VEHICLE"),
        speedKph = math.abs(number(vehicle.speed, 0)) * 3.6,
        rpm = math.max(0, number(vehicle.rpm, 0)),
        rpmMax = math.max(1, number(vehicle.rpmMax, 1)),
        gearLabel = reversing and "R" or (gear == 0 and "N" or tostring(gear)),
        health = math.max(0, math.min(1, number(vehicle.health, 1))),
        onGround = vehicle.onGround ~= false,
    }
end

local function requestWeaponSnapshot()
    if type(Open77.weapons) ~= "table" or type(Open77.weapons.snapshot) ~= "function" then return end
    local at = nowMs()
    if at - lastWeaponRequestAt < 180 then return end
    -- Do not fill the shared script bridge with HUD reads while streaming
    -- stalls the previous read. Equipment mutations use that same queue.
    for id, pending in pairs(weaponRequests) do
        if at - pending.at <= 5000 then return end
        weaponRequests[id] = nil
    end
    lastWeaponRequestAt = at
    local ok, requestId = pcall(Open77.weapons.snapshot)
    if ok and requestId ~= nil then
        weaponRequests[tostring(requestId)] = { at = at, sawActive = false }
    end
    for id, pending in pairs(weaponRequests) do
        if at - pending.at > 5000 then weaponRequests[id] = nil end
    end
end

AddEventHandler("open77:weapons:state", function(requestId, slot, record, tweakDbId,
        active, drawn, _locked, _ammoRecord, _ammoTweakDbId, _ammoTotal, ammoReserve,
        magazine, capacity)
    local pending = weaponRequests[tostring(requestId)]
    if pending == nil or not truthy(active) then return end
    pending.sawActive = true
    local recordName = tostring(record or "")
    local configured = weaponCatalog[recordName]
    local mag = math.floor(number(magazine, -1))
    local cap = math.floor(number(capacity, -1))
    local reserve = math.floor(number(ammoReserve, -1))
    hudView.weapon = {
        equipped = recordName ~= "" or tostring(tweakDbId or "") ~= "",
        drawn = truthy(drawn),
        slot = math.max(1, math.floor(number(slot, 1))),
        record = recordName,
        label = configured and configured.label or recordLabel(recordName, "WEAPON"),
        category = configured and configured.category or "WEAPON",
        ammoKnown = mag >= 0 and cap >= 0,
        magazine = math.max(0, mag),
        capacity = math.max(0, cap),
        reserve = math.max(0, reserve),
    }
end)

AddEventHandler("open77:weapons:completed", function(requestId, operation, accepted)
    local id = tostring(requestId)
    local pending = weaponRequests[id]
    if pending == nil then return end
    if tostring(operation) == "snapshot" and truthy(accepted) and not pending.sawActive then
        hudView.weapon = { equipped = false }
    end
    weaponRequests[id] = nil
end)

AddEventHandler("open77:playerStatsChanged", function()
    sampleStats()
    activateCustomHudIfReady()
    pushHud()
end)

-- Menu state pushed to the page. Built once from the shared config: the page
-- renders whatever it receives, so config edits reach the UI on reload.
local function menuState()
    return {
        locations = Config.teleport.locations,
        canManageTv = canManageTv,
        spawns = Config.spawn.points,
        vehicles = {
            catalog = Config.vehicles.catalog,
            allowCustomModels = Config.vehicles.allowCustomModels == true,
            maxPerPlayer = Config.vehicles.maxPerPlayer,
            defaultModel = Config.vehicles.defaultModel,
        },
        weapons = {
            enabled = Config.weapons.enabled == true,
            catalog = Config.weapons.catalog,
            defaultReserve = Config.weapons.defaultReserve,
            maximumReserve = Config.weapons.maximumReserve,
        },
        player = {
            allowRestore = Config.player.allowRestore == true,
            allowGodMode = Config.player.allowGodMode == true,
        },
    }
end

-- The surface itself stays permanently visible: the page body is fully
-- transparent until the JS applies its "open" class, so DOM state is the only
-- visibility authority. This deliberately avoids the surface hide->show path,
-- which stopped painting on the current client build (surfaces created hidden
-- never upload a frame once shown; always-visible surfaces are unaffected).
local function setMenuOpen(value)
    if value and FreeroamRaceClient then FreeroamRaceClient.close() end
    if not menu then
        print("[freeroam] menu page unavailable; /freeroam cannot open")
        return
    end
    if menuOpen == value then return end
    menuOpen = value
    pushHud()
    if value then
        menu:send("freeroam:state", menuState())
        local focused, focusReason = menu:setFocus(true, true)
        menu:send("freeroam:open", {})
        print(string.format("[freeroam] menu open focus=%s(%s)",
            tostring(focused), tostring(focusReason)))
    else
        menu:send("freeroam:closed", {})
        menu:setFocus(false, false)
        print("[freeroam] menu closed")
    end
end

-- The activity and sandbox views share one WebUI surface and one focus owner.
FreeroamMenu = {
    surface = function() return menu end,
    close = function() setMenuOpen(false) end,
    open = function() setMenuOpen(true) end,
}

local function createBlips()
    if blipsCreated or not Config.blips.enabled then return end

    local created = 0
    for _, location in ipairs(Config.teleport.locations) do
        local id = Open77.blips.create({
            position = location.position,
            sprite = Config.blips.locationSprite,
            title = location.label,
            description = ("Freeroam destination. /goto %s"):format(location.name),
        })
        if id ~= nil then created = created + 1 end
    end

    if Config.blips.showSpawns then
        for _, point in ipairs(Config.spawn.points) do
            local id = Open77.blips.create({
                position = point.position,
                sprite = Config.blips.spawnSprite,
                title = point.label or point.name,
                description = ("Freeroam spawn point. /spawn %s"):format(point.name),
            })
            if id ~= nil then created = created + 1 end
        end
    end

    -- A global failure (world not attached yet) is retried on the next signal.
    if created > 0 then
        blipsCreated = true
        print(string.format("[freeroam] %d blip(s) created", created))
    end
end

AddEventHandler("open77:worldReady", function()
    createBlips()
    activateCustomHudIfReady()
end)

-- The server answers /freeroam with this event.
RegisterNetEvent("freeroam:menu:open", function(access)
    print("[freeroam] freeroam:menu:open received")
    canManageTv = type(access) == "table" and access.canManageTv == true
    local wasOpen = menuOpen
    setMenuOpen(true)
    if menu then
        if wasOpen then menu:send("freeroam:state", menuState()) end
        if canManageTv and access.page == "tv" then menu:send("freeroam:tv:open", {}) end
    end
end)

-- Local diagnostic hook: `resource emit freeroam:menu:toggle` in the developer
-- console toggles the menu without any server round-trip, which separates a
-- network-delivery failure from a surface/page failure.
AddEventHandler("freeroam:menu:toggle", function()
    print("[freeroam] local menu toggle")
    setMenuOpen(not menuOpen)
end)

-- Escape is owned by the plugin while the pause menu is armed: the key is
-- swallowed in the window procedure and never reaches the focused page, so
-- the page-side Escape handler cannot fire in a session. The plugin raises
-- open77:pauseKey instead; closing here keeps this menu from being left open
-- and unfocused (cursor gone) underneath the pause panel.
AddEventHandler("open77:pauseKey", function()
    if menuOpen then setMenuOpen(false) end
end)

-- Server-side outcome of a menu action, surfaced as a toast in the page.
RegisterNetEvent("freeroam:menu:result", function(ok, text)
    if menu then
        menu:send("freeroam:result", { ok = ok == true, text = tostring(text or "") })
    end
end)

RegisterNetEvent("freeroam:menu:weaponState", function(slots)
    if menu then
        menu:send("freeroam:weapons", { slots = type(slots) == "table" and slots or {} })
    end
end)

RegisterNetEvent("freeroam:menu:garageState", function(state)
    if menu then
        menu:send("freeroam:garage", type(state) == "table" and state or {})
    end
end)

RegisterNetEvent("freeroam:menu:playerState", function(state)
    if menu then
        menu:send("freeroam:player", type(state) == "table" and state or {})
    end
end)

-- Flight is owned by open77_admin for both its menu and short chat commands.

-- Tab scoreboard. The plugin forwards the Tab key as open77:scoreboardShow /
-- open77:scoreboardHide while a Open77 session is active (single-player Tab is
-- untouched). Rows come from the SERVER roster (freeroam:roster): every player
-- on the server is listed, whether or not the local client streams them. The
-- nameplate snapshot only contributes a live distance for the players that are
-- streamed nearby; the others show as far. The local player is listed too and
-- marked, so the count is the server's player count.
local scoreboard
local scoreboardOpen = false
local scoreboardDistanceRevision = 0
local scoreboardDistancesDirty = false
local rosterPages, rosterPageHead, rosterPageTail = {}, 1, 0
local rosterRequestPending = false

local function requestRoster()
    if rosterRequestPending then return end
    if type(TriggerServerEvent) == "function" then
        rosterRequestPending = true
        SetTimeout(1000, function() rosterRequestPending = false end)
        pcall(TriggerServerEvent, "freeroam:roster:request")
    end
end

local function localPlayerId()
    if type(Open77.players) ~= "table" or type(Open77.players.localId) ~= "function" then return nil end
    local ok, id = pcall(Open77.players.localId)
    if ok then return tonumber(id) end
    return nil
end

local function streamedDistances()
    local distances = {}
    if type(Open77.nameplates) ~= "table" or type(Open77.nameplates.snapshot) ~= "function" then
        return distances
    end
    local ok, players = pcall(Open77.nameplates.snapshot)
    if not ok or type(players) ~= "table" then return distances end
    for _, player in ipairs(players) do
        local id = tonumber(player.id)
        if id ~= nil then distances[id] = tonumber(player.distance) end
    end
    return distances
end

local function pushScoreboard() scoreboardDistancesDirty = true end

local function sendScoreboardDistances()
    if not scoreboard then return end
    -- The browser owns the global roster and sorting. Send only nearby distance
    -- information here; never rebuild thousands of rows on the game thread.
    local distances = streamedDistances()
    local rows = {}
    for id, distance in pairs(distances) do rows[#rows+1] = {id=id,distance=distance} end
    local pages = math.max(1, math.ceil(#rows / 64))
    scoreboardDistanceRevision = scoreboardDistanceRevision + 1
    local selfId = localPlayerId()
    for page=1,pages do
        local chunk = {}
        for index=(page-1)*64+1,math.min(page*64,#rows) do chunk[#chunk+1] = rows[index] end
        scoreboard:send("scoreboard:distances", { revision=scoreboardDistanceRevision,
            page=page, pages=pages, players=chunk, selfId=selfId })
        Wait(0)
    end
end

local function setScoreboardOpen(value)
    if value and FreeroamPvpClient and FreeroamPvpClient.ownsHud() then return end
    if value and FreeroamRaceClient and FreeroamRaceClient.ownsHud() then return end
    if not scoreboard or scoreboardOpen == value then return end
    scoreboardOpen = value
    if value then
        requestRoster()
        pushScoreboard()
        scoreboard:send("scoreboard:open", {})
    else
        scoreboard:send("scoreboard:closed", {})
    end
end

RegisterNetEvent("freeroam:roster:page", function(payload)
    if rosterPageTail - rosterPageHead >= 128 then
        rosterPages, rosterPageHead, rosterPageTail = {}, 1, 0
        requestRoster()
        return
    end
    rosterPageTail = rosterPageTail + 1
    rosterPages[rosterPageTail] = payload
end)

CreateThread(function()
    while true do
        Wait(0)
        if scoreboard and rosterPageHead <= rosterPageTail then
            local payload = rosterPages[rosterPageHead]
            rosterPages[rosterPageHead], rosterPageHead = nil, rosterPageHead + 1
            scoreboard:send("scoreboard:rosterPage", payload)
            if rosterPageHead > rosterPageTail then rosterPageHead, rosterPageTail = 1, 0 end
        elseif scoreboardOpen and scoreboardDistancesDirty then
            scoreboardDistancesDirty = false
            sendScoreboardDistances()
        end
    end
end)

FreeroamMenu.hideScoreboard = function() setScoreboardOpen(false) end

AddEventHandler("open77:scoreboardShow", function() setScoreboardOpen(true) end)
AddEventHandler("open77:scoreboardHide", function() setScoreboardOpen(false) end)

-- Keep distances live while the board is held open.
CreateThread(function()
    while true do
        if scoreboardOpen then pushScoreboard() end
        Wait(300)
    end
end)

-- The last television list this client was told about, and the position a
-- spawn was requested from. Both are declared before the menu exists because the
-- handlers below can fire before `onClientResourceStart` has built it -- a
-- snapshot that arrived during the resource's own start, for instance.
local lastMediaScreens = {}

RegisterNetEvent("open77:media:catalogue", function(records)
    if menu ~= nil then menu:send("freeroam:tv", { catalogue = records }) end
end)

RegisterNetEvent("open77:media:result", function(ok, detail)
    if ok ~= true and tostring(detail):find("permission_denied", 1, true) then
        canManageTv = false
        if menu then
            menu:send("freeroam:state", menuState())
            menu:send("freeroam:result", { ok = false,
                text = "Television controls are reserved for authorized administrators." })
        end
    end
    if menu ~= nil then
        menu:send("freeroam:tv", { ok = ok == true, text = tostring(detail or "") })
    end
end)

AddEventHandler("open77:media:local", function(screens)
    lastMediaScreens = type(screens) == "table" and screens or {}
    -- `screens`, not `local`: `local` is a reserved word in Lua and cannot be a
    -- bare table key. It cost one parse error to remember, and the page reads
    -- the same key.
    if menu ~= nil then menu:send("freeroam:tv", { screens = lastMediaScreens }) end
end)

AddEventHandler("onClientResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end

    local errorMessage
    menu, errorMessage = WebUI.create({
        entry = "web/index.html",
        layer = "menu",
        width = 1920,
        height = 1080,
        fps = 60,
        transparent = true,
        -- Kept visible on purpose; the page is transparent while closed. See
        -- the note above setMenuOpen.
        visible = true,
    })
    if menu == nil then
        print("[freeroam] menu WebUI failed: " .. tostring(errorMessage))
    else
        print("[freeroam] menu surface created")
        menu:on("freeroam:ready", function()
            print("[freeroam] menu page loaded and ready")
            menu:send("freeroam:state", menuState())
        end)
        menu:on("freeroam:close", function()
            setMenuOpen(false)
        end)
        menu:on("freeroam:action", function(payload)
            if type(payload) ~= "table" or type(payload.type) ~= "string" then return end
            if payload.type == "wardrobe" or payload.type == "cyberlab" then
                setMenuOpen(false)
                TriggerServerEvent("open77:command:execute", payload.type)
                return
            end
            local accepted2, reason2 = TriggerServerEvent("freeroam:menu", payload.type, payload)
            if not accepted2 then
                menu:send("freeroam:result", {
                    ok = false,
                    text = "network refused: " .. tostring(reason2),
                })
                return
            end
            -- Teleport-style actions fade the screen; keep the vehicle tabs
            -- open so several models can be tried in a row.
            if payload.type == "goto" or payload.type == "tpc" or payload.type == "spawn"
                or payload.type == "suicide" then
                setMenuOpen(false)
            end
        end)

        -- TELEVISIONS ---------------------------------------------------------
        --
        -- The catalogue, the spawn path and every setting live in the
        -- `open77_media` resource. This is a client of that resource, not a
        -- second implementation of it: the page asks, these handlers forward,
        -- and the answers are relayed back. Changing a URL from here therefore
        -- changes it for everyone watching the same set, because the change goes
        -- through the server like any other.
        --
        -- The catalogue and the action results arrive as net events addressed to
        -- this player and are handled straight from the server, which is why
        -- there is no re-emission anywhere: a resource that re-emitted them
        -- locally would deliver each one twice.
        --
        -- The nearby-set list is different -- it is this CLIENT's rendering
        -- state, which the server cannot know -- so the media resource pushes it
        -- locally as `open77:media:local` when it changes, and the last one is
        -- cached here so REFRESH can redraw without waiting for a change that is
        -- not coming.
        menu:on("freeroam:tv", function(payload)
            if not canManageTv then return end
            if type(payload) ~= "table" or type(payload.action) ~= "string" then return end
            local action = payload.action
            if action == "catalogue" then
                TriggerServerEvent("open77:media:catalogue")
            elseif action == "local" then
                menu:send("freeroam:tv", { screens = lastMediaScreens })
            elseif action == "spawn" then
                -- The facing is offered, not asserted: the server has no way to
                -- read a player's heading (`Open77.players.position` publishes
                -- x, y, z and bucket only) and clamps whatever arrives. The
                -- position is never sent -- the server reads that itself.
                --
                -- `character.state()` is where a heading lives on this side, and
                -- it can be absent while the body is still streaming in, so the
                -- field is optional and the server treats its absence as zero
                -- rather than as an error.
                local character = Open77.character.state()
                TriggerServerEvent("open77:media:spawn", {
                    record = tostring(payload.record or ""),
                    url = payload.url,
                    yaw = type(character) == "table" and character.yaw or nil,
                })
            elseif action == "url" then
                TriggerServerEvent("open77:media:control", "url",
                    { id = tonumber(payload.id), url = payload.url })
            elseif action == "volume" then
                TriggerServerEvent("open77:media:control", "volume",
                    { id = tonumber(payload.id), volume = tonumber(payload.volume) })
            elseif action == "muted" then
                TriggerServerEvent("open77:media:control", "muted",
                    { id = tonumber(payload.id), value = payload.value == true })
            elseif action == "paused" then
                TriggerServerEvent("open77:media:control", "paused",
                    { id = tonumber(payload.id), value = payload.value == true })
            elseif action == "move" then
                -- A nudge along the set's own axes. The direction is forwarded as
                -- written and validated on the server, which owns the axis
                -- convention (`shared/placement.lua` in the media resource): a
                -- client that invents a direction gets `unknown_direction` back
                -- rather than moving a set the wrong way.
                TriggerServerEvent("open77:media:control", "move",
                    { id = tonumber(payload.id), direction = tostring(payload.direction or ""),
                        metres = tonumber(payload.metres) })
            elseif action == "rotate" then
                TriggerServerEvent("open77:media:control", "rotate",
                    { id = tonumber(payload.id), direction = tostring(payload.direction or ""),
                        degrees = tonumber(payload.degrees) })
            elseif action == "remove" then
                TriggerServerEvent("open77:media:control", "remove",
                    { id = tonumber(payload.id) })
            end
        end)
    end

    local hudError
    hud, hudError = WebUI.create({
        entry = "web/hud.html",
        layer = "hud",
        width = 1920,
        height = 1080,
        fps = 60,
        zIndex = 620,
        transparent = true,
        visible = true,
    })
    if hud == nil then
        -- The vanilla readouts stay visible if the replacement cannot paint.
        print("[freeroam] HUD WebUI failed; vanilla HUD retained: " .. tostring(hudError))
    else
        hud:on("freeroam:hud:ready", function()
            hudReady = true
            sampleStats()
            sampleVehicle()
            activateCustomHudIfReady()
            pushHud()
            if not hudView.ready then
                print("[freeroam] design-system HUD ready; waiting for stats before hiding stock readouts")
            end
        end)

        CreateThread(function()
            while hud ~= nil do
                sampleStats()
                sampleVehicle()
                activateCustomHudIfReady()
                requestWeaponSnapshot()
                pushHud()
                Wait(50)
            end
        end)
    end

    local scoreboardError
    scoreboard, scoreboardError = WebUI.create({
        entry = "web/scoreboard.html",
        layer = "hud",
        width = 1920,
        height = 1080,
        fps = 10,
        zIndex = 800,
        transparent = true,
        visible = true,
    })
    if scoreboard == nil then
        print("[freeroam] scoreboard WebUI failed: " .. tostring(scoreboardError))
    else
        scoreboard:on("scoreboard:requestRoster", requestRoster)
        scoreboard:on("scoreboard:ready", function()
            requestRoster()
            pushScoreboard()
        end)
    end

    -- The world may already be attached when the server generation starts this
    -- resource; try right away, then once more in case the blip API was not
    -- available yet.
    CreateThread(function()
        Wait(1000)
        createBlips()
        if not blipsCreated then
            Wait(5000)
            createBlips()
        end
    end)
end)

AddEventHandler("onClientResourceStop", function(name)
    if name ~= GetCurrentResourceName() then return end
    setVanillaHudHidden(false)
    blipsCreated = false
    menu = nil
    menuOpen = false
    hud = nil
    hudReady = false
    hudClaimsActive = false
    lastHudClaimAttemptAt = -1000
    weaponRequests = {}
    scoreboard = nil
    scoreboardOpen = false
end)
