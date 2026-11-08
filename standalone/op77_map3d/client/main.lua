-- op77_map3d client: the pages (the minimap's small surface and the full map's surface,
-- the same web page with a role each), the player feed, the blips of every resource,
-- the waypoint and its GPS route. README.md has the API.
local C = Map3DConfig
local B = Map3DBlip

-- Two surfaces. The minimap's is cropped to its corner (drawBounds) and redrawn at a low
-- rate; the map's is full screen at 60 fps and hidden while closed, so it costs nothing
-- until opened. One full-screen page doing both made the game recompose the whole
-- overlay 30 times a second for a corner.
local surfaces = {}        -- role ("mini" | "full" | "holo") -> { page, ready }
-- The holographic GPS (its own small surface at the bottom of the view): shown while a
-- route runs, the map is closed and the player has not switched it off on the map.
local holoEnabled = ((C.page or {}).holo or {}).enabled ~= false
-- Jamming (shared/jam.lua): direct jams and zones of any resource, and the server's.
local jams = {}            -- id -> jam (normalized) + owner
local serverJams = {}      -- id -> jam from the server
local jamSent = { strength = -1 }
local lastPos = nil        -- { x, y } of the player, for the zones
local userMinimap = true   -- the player's own switch on the map (prefs.hud.minimap)
local uiBusy = false       -- another interface holds the cursor (inventory, F1 menu, phone...)
local prefs = nil          -- the map page's display choices, replayed to the minimap
local holoRoute = nil
local pageReady = false    -- a surface has answered
local open = false
local blips = {}          -- id -> blip (normalized) + owner
local serverBlips = {}    -- id -> blip from the server
local waypoint = nil      -- { x, y, z }
local route = { active = false }
local pageConfig = C.page
local configPatches = {}   -- setConfig / setTheme at runtime, replayed when the page reloads
local minimapVisible = true
local warned = {}
local seq = 0
local nativeWaypointSeen = nil
-- The native waypoint has been read back equal to ours: only then does its absence mean
-- someone cleared it (a refused or not yet applied set must not wipe our route).
local nativeConfirmed = false
-- The native waypoint we just replaced: reads of it are the game catching up (or refusing
-- the new one), never someone choosing it again.
local nativeStale = nil
-- Who chose the current waypoint: "native" = another resource through Open77.blips.
local waypointOrigin = nil

local function warn(key, text)
    if warned[key] then return end
    warned[key] = true
    print("[map3d] " .. text)
end
local function dbg(fmt, ...) if C.debug then print("[map3d] " .. string.format(fmt, ...)) end end

local function sendTo(role, name, payload)
    local s = surfaces[role]
    if s and s.ready then s.page:send(name, payload) end
end
local function send(name, payload) for role in pairs(surfaces) do sendTo(role, name, payload) end end
-- Both surfaces follow the route; its events come from one: the minimap's, always running.
local function gpsRole() return surfaces.mini and "mini" or "full" end

-- The minimap's surface rests while the map is open or the player switched it off.
local function syncMini()
    local s = surfaces.mini
    if not s then return end
    local want = userMinimap and not open and not uiBusy
    if want ~= s.shown then
        s.shown = want
        pcall(want and s.page.show or s.page.hide, s.page)
    end
end

local function syncHolo()
    local s = surfaces.holo
    if not s then return end
    local want = holoEnabled and holoRoute ~= nil and not open and not uiBusy and jamSent.strength < 0.99
    if want ~= s.shown then
        s.shown = want
        pcall(want and s.page.show or s.page.hide, s.page)
    end
end
local function caller() return GetInvokingResource() or GetCurrentResourceName() end
local function same(a, b) return a and b and math.abs(a.x - b.x) < 0.5 and math.abs(a.y - b.y) < 0.5 end

-- ---------------------------------------------------------------------------
-- Blips

local function pageBlip(id, b)
    local out = {}
    for k, v in pairs(b) do if k ~= "owner" then out[k] = v end end
    out.id = id
    return out
end

local function allBlips()
    local list = {}
    for id, b in pairs(blips) do list[#list + 1] = pageBlip(id, b) end
    for id, b in pairs(serverBlips) do list[#list + 1] = pageBlip(id, b) end
    return list
end

local function addBlip(def, owner)
    local b, why = B.normalize(def)
    if not b then return nil, why end
    seq = seq + 1
    local id = (type(def) == "table" and type(def.id) == "string" and def.id ~= "" and (owner .. ":" .. def.id)) or (owner .. "#" .. seq)
    b.owner = owner
    blips[id] = b
    send("map3d:blip", pageBlip(id, b))
    return id
end

local function updateBlip(id, patch, owner)
    local b = blips[id]
    if not b then return false, "unknown blip" end
    if owner and b.owner ~= owner and owner ~= GetCurrentResourceName() then return false, "not your blip" end
    local nb, why = B.patch(b, patch)
    if not nb then return false, why end
    nb.owner = b.owner
    blips[id] = nb
    send("map3d:blip", pageBlip(id, nb))
    return true
end

local function removeBlip(id, owner)
    local b = blips[id]
    if not b then return false end
    if owner and b.owner ~= owner and owner ~= GetCurrentResourceName() then return false end
    blips[id] = nil
    send("map3d:blipRemove", { id = id })
    return true
end

local function clearOwner(owner)
    local gone = {}
    for id, b in pairs(blips) do if b.owner == owner then gone[#gone + 1] = id end end
    for _, id in ipairs(gone) do blips[id] = nil end
    if #gone > 0 then send("map3d:blips", { remove = gone }) end
    return #gone
end

-- ---------------------------------------------------------------------------
-- Waypoint (shared with the game's own waypoint when mirrorNativeWaypoint)

local function nativeBlips() return type(Open77.blips) == "table" and C.mirrorNativeWaypoint end

local function setWaypoint(p, origin, fromRole)
    if p and (type(p.x) ~= "number" or type(p.y) ~= "number") then return false, "position {x, y[, z]} required" end
    if p then waypoint = { x = p.x, y = p.y, z = tonumber(p.z) or 0 } else waypoint = nil end
    waypointOrigin = waypoint and origin or nil
    dbg("waypoint %s from %s", waypoint and string.format("%.1f, %.1f", waypoint.x, waypoint.y) or "cleared", tostring(origin or caller()))
    -- every surface follows the route, except the one it came from (it already has it)
    for role in pairs(surfaces) do
        if role ~= fromRole then sendTo(role, waypoint and "map3d:route" or "map3d:waypoint", waypoint or {}) end
    end
    if nativeBlips() and origin ~= "native" then
        if type(Open77.blips.waypoint) == "function" then
            local okr, cur = pcall(Open77.blips.waypoint)
            nativeStale = okr and type(cur) == "table" and type(cur.x) == "number" and not same(cur, waypoint) and cur or nil
        end
        if waypoint then
            local ok, done, why = pcall(Open77.blips.setWaypoint, waypoint)
            if not ok or not done then warn("wp", "native waypoint refused: " .. tostring(ok and why or done)) end
        else
            pcall(Open77.blips.clearWaypoint)
        end
        nativeWaypointSeen = waypoint
        nativeConfirmed = false
    end
    TriggerEvent("op77_map3d:waypointChanged", waypoint)
    return true
end

-- Another resource (or the game) placed the native waypoint: follow it.
CreateThread(function()
    while true do
        Wait(1000)
        if pageReady and nativeBlips() and type(Open77.blips.waypoint) == "function" then
            local ok, wp, why = pcall(Open77.blips.waypoint)
            if ok and why == nil then -- nil WITH a reason means the question could not be asked
                wp = type(wp) == "table" and type(wp.x) == "number" and wp or nil
                if wp and same(wp, waypoint) then
                    nativeConfirmed = true
                    nativeStale = nil
                elseif wp and same(wp, nativeStale) then
                    -- the old one, still there for a moment: not a new choice
                elseif wp and not same(wp, nativeWaypointSeen) then
                    nativeStale = nil
                    nativeWaypointSeen = wp
                    setWaypoint(wp, "native")
                    nativeConfirmed = true
                elseif not wp and nativeConfirmed and waypoint then
                    if waypointOrigin == "native" then
                        -- the resource that placed it took it away
                        print("[map3d] the native waypoint was cleared: route cleared")
                        nativeWaypointSeen = nil
                        setWaypoint(nil, "native")
                    else
                        -- ours, gone without anyone asking (the game drops it, e.g. while
                        -- driving): put it back rather than lose the player's route
                        print("[map3d] the game dropped the waypoint: placed again")
                        nativeConfirmed = false
                        pcall(Open77.blips.setWaypoint, waypoint)
                    end
                end
            end
        end
    end
end)

-- ---------------------------------------------------------------------------
-- Jamming

local function jamState()
    local strength, label = 0, nil
    local px, py = lastPos and lastPos.x, lastPos and lastPos.y
    for _, list in ipairs({ jams, serverJams }) do
        for _, j in pairs(list) do
            local s = Map3DJam.at(j, px, py)
            if s > strength then strength, label = s, j.label end
        end
    end
    return math.floor(strength * 50 + 0.5) / 50, label
end

-- Tell the pages when the strongest jam changes (the zones follow the player feed).
local function syncJam()
    local strength, label = jamState()
    if strength == jamSent.strength and label == jamSent.label then return end
    local wasJammed = jamSent.strength > 0
    jamSent = { strength = strength, label = label }
    send("map3d:jam", { strength = strength, label = label })
    if (strength > 0) ~= wasJammed then TriggerEvent("op77_map3d:jammed", strength > 0, strength) end
    syncHolo()
end

local function addJam(def, owner, wantZone)
    local j, why = Map3DJam.normalize(def)
    if not j then return nil, why end
    if wantZone and not j.zone then return nil, "a jam zone needs a position {x, y} and a radius" end
    seq = seq + 1
    local id = (type(def) == "table" and type(def.id) == "string" and def.id ~= "" and (owner .. ":" .. def.id)) or (owner .. "#jam" .. seq)
    j.owner = owner
    jams[id] = j
    syncJam()
    return id
end

local function removeJam(id, owner)
    local j = jams[id]
    if not j or (owner and j.owner ~= owner and owner ~= GetCurrentResourceName()) then return false end
    jams[id] = nil
    syncJam()
    return true
end

local function clearJams(owner)
    local n = 0
    for id, j in pairs(jams) do if j.owner == owner then jams[id] = nil; n = n + 1 end end
    if n > 0 then syncJam() end
    return n
end

-- ---------------------------------------------------------------------------
-- Open / close

local lastToggle, typing = -1e9, false
local function clock() return type(GetGameTimer) == "function" and GetGameTimer() or os.clock() * 1000 end

local closeSeq = 0
local function setOpen(v, focus)
    v = v == true
    local s = surfaces.full
    if v == open or not s then return open end
    open = v
    lastToggle = clock()
    if not open then typing = false end
    dbg("map %s", open and "open" or "closed")
    local page, mini = s.page, surfaces.mini and surfaces.mini.page
    if open then
        -- Escape closes the map; without this it would also reach the game and open the pause menu.
        if type(page.setConsumedKeys) == "function" then
            local ok, done, why = pcall(page.setConsumedKeys, page, { "escape" })
            if not ok or not done then warn("keys", "escape not consumed: " .. tostring(ok and why or done)) end
        else
            warn("keys", "this client cannot consume escape (page:setConsumedKeys missing)")
        end
        syncMini()
        pcall(page.show, page)
        syncHolo()
        page:setFocus(true, true)
        sendTo("full", "map3d:open", focus or {})
        TriggerEvent("op77_map3d:opened")
    else
        page:setFocus(false, false)
        sendTo("full", "map3d:close", {})
        -- the page plays its closing animation before its surface goes away (the minimap
        -- is back right away); a reopen in between keeps it
        closeSeq = closeSeq + 1
        local seq, delay = closeSeq, tonumber(C.closeAnimationMs) or 0
        if delay > 0 then
            CreateThread(function()
                Wait(delay)
                if not open and seq == closeSeq then pcall(page.hide, page) end
            end)
        else
            pcall(page.hide, page)
        end
        syncMini()
        syncHolo()
        TriggerEvent("op77_map3d:closed")
    end
    return open
end

local takenOver = false
local function takeOver(active)
    takenOver = active
    if C.replaceNativeMap and type(Open77.input) == "table" then
        local ok = type(Open77.input.setActionBlocked) == "function" and pcall(Open77.input.setActionBlocked, "Map", active)
        if not ok and type(Open77.input.setNativeActionBlocked) == "function" then pcall(Open77.input.setNativeActionBlocked, "OpenMapMenu", active) end
    end
    if C.hideNativeMinimap and type(Open77.hud) == "table" and type(Open77.hud.setVisible) == "function" then
        local ok, why = pcall(Open77.hud.setVisible, "minimap", not active)
        if not ok then warn("hud", "cannot hide the native minimap: " .. tostring(why)) end
    end
end

-- While another interface holds the cursor (an inventory, a menu, a phone), the minimap
-- and the holo GPS step aside, and come back when it closes.
CreateThread(function()
    while true do
        Wait(150)
        local busy = false
        if C.hideUnderMenus ~= false and not open and type(Open77.input) == "table" and type(Open77.input.isCaptured) == "function" then
            local ok, _, cursor = pcall(Open77.input.isCaptured)
            busy = ok and cursor == true
        end
        if busy ~= uiBusy then
            uiBusy = busy
            syncMini()
            syncHolo()
        end
    end
end)

-- Another resource giving the whole vanilla HUD back (setVisible("all", true) after a
-- cutscene) also brings the native minimap back: hide it again, on its signal and every
-- few seconds.
local function reassertMinimap()
    if takenOver and C.hideNativeMinimap and type(Open77.hud) == "table" and type(Open77.hud.setVisible) == "function" then
        pcall(Open77.hud.setVisible, "minimap", false)
    end
end
AddEventHandler("op77:hud:vanillaRestored", reassertMinimap)
CreateThread(function()
    while true do
        Wait(3000)
        reassertMinimap()
    end
end)

-- ---------------------------------------------------------------------------
-- Player feed

-- Where the visible body faces. In first person that is the player's forward. In third
-- person the body you see is a proxy and the player's forward/yaw follow the camera, so
-- the body's facing is the way it moves (it turns toward its motion), kept when it stops,
-- and the camera's while aiming (it turns to the aim).
local bodyYaw = nil
local function yawOf(v) return (v and (math.abs(v.x or 0) + math.abs(v.y or 0)) > 1e-3) and math.deg(math.atan(-v.x, v.y)) or nil end
local function thirdPerson()
    if type(Open77.perspective) ~= "table" or type(Open77.perspective.get) ~= "function" then return false end
    local ok, mode = pcall(Open77.perspective.get)
    return ok and mode == "tps"
end
-- The heading of the car the player sits in (Open77 vehicles), or nil.
local function vehicleHeading()
    local V = Open77.vehicles
    if type(V) ~= "table" or type(V.getPlayerSeat) ~= "function" or type(V.get) ~= "function" then return nil end
    local ok, seat = pcall(V.getPlayerSeat)
    if not ok or type(seat) ~= "table" or not seat.vehicleId then return nil end
    local okv, car = pcall(V.get, seat.vehicleId)
    return okv and type(car) == "table" and tonumber(car.heading or car.yaw) or nil
end

local function bodyHeading(s, camYaw, vehicle)
    local forward = yawOf(type(s.forward) == "table" and s.forward) or tonumber(s.yaw)
    -- in a car the arrow is the car's nose, never its motion: reversing must not turn it
    if vehicle then bodyYaw = vehicleHeading() or forward or bodyYaw; return bodyYaw or 0 end
    if not thirdPerson() then bodyYaw = forward; return forward or 0 end
    local v = type(s.velocity) == "table" and s.velocity
    local speed = tonumber(s.groundSpeed or s.speed) or 0
    local aiming = type(Open77.character.isAiming) == "function" and select(2, pcall(Open77.character.isAiming)) == true
    if aiming and camYaw then bodyYaw = camYaw
    elseif v and speed > 0.6 and yawOf(v) then bodyYaw = yawOf(v) end
    return bodyYaw or forward or camYaw or 0
end

local function cameraYaw()
    if type(Open77.camera) ~= "table" or type(Open77.camera.view) ~= "function" then return nil end
    local ok, v = pcall(Open77.camera.view)
    local f = ok and type(v) == "table" and v.forward
    if not f or (math.abs(f.x or 0) + math.abs(f.y or 0)) < 1e-3 then return nil end
    return math.deg(math.atan(-f.x, f.y))
end

CreateThread(function()
    local interval = math.floor(1000 / math.max(1, C.playerRate or 15))
    while true do
        Wait(interval)
        if pageReady then
            local ok, s = pcall(Open77.character.state)
            if ok and type(s) == "table" and s.position and s.attached ~= false then
                local vehicle = false
                if type(Open77.character.isInVehicle) == "function" then
                    local okv, inv = pcall(Open77.character.isInVehicle)
                    vehicle = okv and inv == true
                end
                local camYaw = cameraYaw()
                local yaw = bodyHeading(s, camYaw, vehicle)
                lastPos = { x = s.position.x, y = s.position.y }
                syncJam()
                send("map3d:player", {
                    x = s.position.x, y = s.position.y, z = s.position.z,
                    yaw = yaw, camYaw = camYaw or yaw,
                    speed = tonumber(s.groundSpeed or s.speed) or 0, vehicle = vehicle,
                })
            end
        end
    end
end)

-- Other players around you.
CreateThread(function()
    local cfg = C.nearbyPlayers or {}
    local shown = {}
    while true do
        Wait(math.floor((cfg.interval or 1) * 1000))
        if pageReady and cfg.enabled and type(Open77.players.nearby) == "function" then
            local ok, list = pcall(Open77.players.nearby, cfg.radius or 350, { includeSelf = false, limit = 64 })
            local now = {}
            if ok and type(list) == "table" then
                for _, p in ipairs(list) do
                    if not p.isLocal and type(p.position) == "table" then
                        local id = "player:" .. tostring(p.id or p.playerId)
                        now[id] = true
                        send("map3d:blip", { id = id, x = p.position.x, y = p.position.y, z = p.position.z or 0,
                            icon = "user", label = p.name or ("#" .. tostring(p.id or "?")), category = "player",
                            color = cfg.color, routable = true, scale = 0.85 })
                    end
                end
            end
            local gone = {}
            for id in pairs(shown) do if not now[id] then gone[#gone + 1] = id end end
            if #gone > 0 then send("map3d:blips", { remove = gone }) end
            shown = now
        end
    end
end)

-- ---------------------------------------------------------------------------
-- The page

-- A minimap setting as it stands after the runtime patches.
local function minimapSetting(key, default)
    local v = (pageConfig.minimap or {})[key]
    for _, patch in ipairs(configPatches) do
        if type(patch.minimap) == "table" and patch.minimap[key] ~= nil then v = patch.minimap[key] end
    end
    if v == nil then return default end
    return v
end

-- The minimap's corner, with room for the district line and a toast under it (CSS units
-- of the 1920 x 1080 reference; negative = from the right / bottom edge).
local function miniBounds()
    local size = tonumber(minimapSetting("size", 264)) or 264
    local margin = minimapSetting("margin", { 32, 26 })
    local w = (tonumber(margin[1]) or 32) + size + 24
    local h = (tonumber(margin[2]) or 26) + size + 100
    local anchor = tostring(minimapSetting("anchor", "top-right"))
    return { x = anchor:find("right") and -w or 0, y = anchor:find("bottom") and -h or 0, width = w, height = h }
end

-- Bottom centre, where the holo screen rises: the CSS width follows the screen's aspect
-- (1080 CSS px high), so read the back buffer to centre the crop.
-- The screen's aspect as a page sees it (map3d:ready carries its viewport): the holo
-- crop is centred, so it needs the width. Open77.screen.surface would tell too, but it
-- requires screen.capture, which this map has no business asking for.
local viewAspect = nil
local function holoBounds()
    local w, h = 780, 320
    local aspect = viewAspect
    if not aspect then
        local okS, surface = pcall(function() return Open77.screen.surface() end)
        local px, py = okS and type(surface) == "table" and tonumber(surface.width), okS and type(surface) == "table" and tonumber(surface.height)
        if px and py and py > 0 then aspect = px / py end
    end
    if not aspect then return nil end
    local cssWidth = 1080 * aspect
    return { x = math.floor((cssWidth - w) / 2), y = -h, width = w, height = h }
end

local function createSurface(role)
    local fps = C.fps or {}
    local options = {
        entry = "web/index.html", layer = "hud", width = 1920, height = 1080, transparent = true,
        -- above LightRP (720) and the voice HUD (760)
        fps = role == "mini" and (fps.minimap or 30) or role == "holo" and (fps.holo or 30) or (fps.map or 60),
        -- the minimap and the holo GPS sit under the gamemode's interfaces (LightRP: 720),
        -- the open map above them
        zIndex = (C.zIndex or {})[role == "full" and "map" or role == "mini" and "minimap" or "holo"]
            or (role == "mini" and 700 or role == "holo" and 699 or 781),
        visible = role == "mini" or (role == "full" and open),
        drawBounds = role == "mini" and miniBounds() or role == "holo" and holoBounds() or nil,
    }
    local created, why
    for _ = 1, 120 do
        created, why = WebUI.create(options)
        if created or why ~= "resource_preparing" then break end
        Wait(250)
    end
    if not created and why == "invalid_webui_draw_bounds" then
        warn("bounds", "minimap crop refused: drawn on a full-screen surface")
        options.drawBounds = nil
        created, why = WebUI.create(options)
    end
    if not created then print("[map3d] no " .. role .. " WebUI surface: " .. tostring(why)) return end
    local s = { page = created, ready = false, shown = options.visible, cropped = options.drawBounds ~= nil }
    surfaces[role] = s
    local page = created
    local function hello()
        s.ready, pageReady = true, true
        page:send("map3d:role", { role = role })
        page:send("map3d:config", pageConfig)
        for _, patch in ipairs(configPatches) do page:send("map3d:config", patch) end
        page:send("map3d:minimap", { visible = minimapVisible })
        page:send("map3d:blips", { set = allBlips() })
        if waypoint then page:send("map3d:route", waypoint) end
        if role == "full" and open then page:send("map3d:open", {}) end
        if jamSent.strength > 0 then page:send("map3d:jam", jamSent) end
        if role == "holo" then page:send("map3d:holo", holoRoute or { clear = true, pts = {} }); syncHolo() end
        if role == "mini" then
            if prefs then page:send("map3d:prefs", prefs) end
            syncMini()
        end
    end
    page:on("map3d:hello", hello)
    page:on("map3d:ready", function(info)
        hello()
        if role == gpsRole() then TriggerEvent("op77_map3d:ready", info) end
        -- the first page to know the screen's aspect lets the holo GPS be cropped
        local vw, vh = type(info) == "table" and tonumber(info.vw), type(info) == "table" and tonumber(info.vh)
        if not viewAspect and vw and vh and vw > 0 and vh > 0 then
            viewAspect = vw / vh
            local holo = surfaces.holo
            if holo and not holo.cropped and role ~= "holo" then
                CreateThread(function()
                    pcall(holo.page.destroy, holo.page)
                    surfaces.holo = nil
                    createSurface("holo")
                end)
            end
        end
    end)
    page:on("map3d:error", function(p) print("[map3d] " .. role .. " page error: " .. tostring(p and p.message)) end)
    page:on("map3d:close", function() setOpen(false) end)
    page:on("map3d:typing", function(p) typing = role == "full" and p and p.active == true or false end)
    page:on("map3d:holo", function(p)
        if role ~= gpsRole() then return end
        holoRoute = type(p) == "table" and not p.clear and p or nil
        sendTo("holo", "map3d:holo", p)
        syncHolo()
    end)
    page:on("map3d:prefs", function(p)
        if role ~= "full" or type(p) ~= "table" then return end
        prefs = p
        local hud = type(p.hud) == "table" and p.hud or {}
        holoEnabled = hud.holo ~= false
        userMinimap = hud.minimap ~= false
        sendTo("mini", "map3d:prefs", p)
        syncMini()
        syncHolo()
    end)
    page:on("map3d:holoPref", function(p)
        if role ~= "full" then return end
        holoEnabled = p and p.enabled ~= false
        syncHolo()
    end)
    page:on("map3d:log", function(p) dbg("%s page: %s", role, tostring(p and p.message)) end)
    page:on("map3d:waypoint", function(p)
        if p and p.clear then setWaypoint(nil, "page", role) else setWaypoint(p, "page", role) end
    end)
    page:on("map3d:routeInfo", function(info)
        if role ~= gpsRole() then return end
        route = type(info) == "table" and info or { active = false }
        TriggerEvent("op77_map3d:route", route)
    end)
    page:on("map3d:arrived", function(p)
        if role ~= gpsRole() then return end
        print(string.format("[map3d] arrived (%.0f m from the waypoint)", tonumber(p and p.distance) or -1))
        TriggerEvent("op77_map3d:arrived", p)
    end)
    page:on("map3d:blipClick", function(p) TriggerEvent("op77_map3d:blipClicked", p and p.id) end)
end

-- The minimap's surface follows its settings: off, or recreated when its corner moves.
local miniShape = nil
local function syncMinimapSurface()
    local want = minimapSetting("enabled", true) ~= false
    local shape = want and table.concat({ minimapSetting("anchor", "top-right"), tostring(minimapSetting("size", 264)),
        tostring((minimapSetting("margin", { 32, 26 }))[1]), tostring((minimapSetting("margin", { 32, 26 }))[2]) }, ":") or nil
    if shape == miniShape and (surfaces.mini ~= nil) == want then return end
    miniShape = shape
    if surfaces.mini then pcall(surfaces.mini.page.destroy, surfaces.mini.page); surfaces.mini = nil end
    if want then createSurface("mini") end
end

-- The open map sees the same press: its page closes it and this mapping fires too, so a
-- press right after a toggle is the same press (it reopened the map), and letters typed in
-- the search box are not a map key.
local ok, effective = pcall(RegisterKeyMapping, C.key.id, C.key.name, C.key.key, function()
    if not pageReady or (open and typing) or clock() - lastToggle < 350 then return end
    setOpen(not open)
end)
if not ok then warn("key", "key mapping refused: " .. tostring(effective)) end

-- Minimap zoom: held keys, the page zooms while one is down (and remembers the level).
-- A client that does not know the key (the numpad before Unstable 167) gets the fallback
-- key under its own id, so the player's binding of the first one is kept for later.
local function mapZoomKey(dir, id, name, key)
    local okz, effective, why = pcall(RegisterKeyMapping, {
        id = id, name = name, key = key, hold = true,
        onPressed = function() sendTo("mini", "map3d:miniZoom", { dir = dir, down = true }) end,
        onReleased = function() sendTo("mini", "map3d:miniZoom", { dir = dir, down = false }) end,
    })
    if okz and effective then return true end
    return false, tostring(okz and why or effective)
end
for dir, def in pairs({ [1] = (C.zoomKeys or {}).zoomIn, [-1] = (C.zoomKeys or {}).zoomOut }) do
    if def then
        local okz, why = mapZoomKey(dir, def.id, def.name, def.key)
        if not okz and def.fallback and why:find("unsupported", 1, true) then
            okz, why = mapZoomKey(dir, def.id .. ".fallback", def.name, def.fallback)
            if okz then print(("[map3d] %s unknown to this client, minimap zoom on %s"):format(def.key, def.fallback)) end
        end
        if not okz then warn("zoom" .. dir, "zoom key mapping refused: " .. why) end
    end
end

-- The pause menu's CITY MAP opens this map (open77_pause map providers): announce
-- ourselves at start and whenever the menu asks, answer its open requests.
local function announceMapProvider()
    if C.pauseMenuMap == false then return end
    TriggerEvent("open77:mapProvider:register", { resource = GetCurrentResourceName(), label = C.key.name, priority = C.pauseMenuPriority or 100 })
end
AddEventHandler("open77:mapProvider:query", announceMapProvider)
AddEventHandler("open77:mapProvider:show", function(request)
    if type(request) ~= "table" or request.provider ~= GetCurrentResourceName() or not pageReady then return end
    setOpen(true)
    TriggerEvent("open77:mapProvider:shown", { requestId = request.requestId })
end)

AddEventHandler("onClientResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    takeOver(true)
    announceMapProvider()
    TriggerServerEvent("op77_map3d:hello")
    CreateThread(function()
        syncMinimapSurface()
        createSurface("full")
        createSurface("holo")
    end)
end)

AddEventHandler("onClientResourceStop", function(name)
    if name == GetCurrentResourceName() then
        takeOver(false)
        -- the pause menu lives in the client's other host and cannot see this resource stop
        TriggerEvent("open77:mapProvider:withdraw", { resource = name })
        local s = surfaces.full
        if s and open then pcall(s.page.setFocus, s.page, false, false) end
        return
    end
    clearOwner(name)
    clearJams(name)
end)

-- ---------------------------------------------------------------------------
-- From the server (server/main.lua)

RegisterNetEvent("op77_map3d:blips", function(payload)
    if type(payload) ~= "table" then return end
    local out = { upsert = {}, remove = {} }
    if payload.set then
        for id in pairs(serverBlips) do out.remove[#out.remove + 1] = id end
        serverBlips = {}
    end
    for _, def in ipairs(payload.set or payload.upsert or {}) do
        local b = B.normalize(def)
        if b and def.id then serverBlips[def.id] = b; out.upsert[#out.upsert + 1] = pageBlip(def.id, b) end
    end
    for _, id in ipairs(payload.remove or {}) do serverBlips[id] = nil; out.remove[#out.remove + 1] = id end
    send("map3d:blips", out)
end)
RegisterNetEvent("op77_map3d:jams", function(payload)
    if type(payload) ~= "table" then return end
    if payload.set then serverJams = {} end
    for _, def in ipairs(payload.set or payload.upsert or {}) do
        local j = Map3DJam.normalize(def)
        if j and type(def.id) == "string" then serverJams[def.id] = j end
    end
    for _, id in ipairs(payload.remove or {}) do serverJams[id] = nil end
    syncJam()
end)
RegisterNetEvent("op77_map3d:waypoint", function(p) setWaypoint(type(p) == "table" and p.x and p or nil, "server") end)
RegisterNetEvent("op77_map3d:open", function(focus) setOpen(true, focus) end)

-- ---------------------------------------------------------------------------
-- Exports (any client resource)

exports("open", function(focus) return setOpen(true, focus) end)
exports("close", function() return setOpen(false) end)
exports("toggle", function() return setOpen(not open) end)
exports("isOpen", function() return open end)
exports("isReady", function() return pageReady end)
exports("focus", function(pos, distance) if type(pos) == "table" then send("map3d:focus", { x = pos.x, y = pos.y, z = pos.z, distance = distance }) end end)

exports("addBlip", function(def) return addBlip(def, caller()) end)
exports("updateBlip", function(id, patch) return updateBlip(id, patch, caller()) end)
exports("removeBlip", function(id) return removeBlip(id, caller()) end)
exports("clearBlips", function() return clearOwner(caller()) end)
exports("getBlip", function(id) local b = blips[id] or serverBlips[id]; return b and pageBlip(id, b) or nil end)

-- Jamming: the map and minimap drown in static (strength 1: nothing of them is left).
exports("jam", function(def) return addJam(def, caller(), false) end)        -- { strength?, label?, id? }
exports("unjam", function(id) return removeJam(id, caller()) end)
exports("addJamZone", function(def) return addJam(def, caller(), true) end) -- { position, radius, fade?, strength?, label?, id? }
exports("removeJamZone", function(id) return removeJam(id, caller()) end)
exports("clearJams", function() return clearJams(caller()) end)
exports("getJam", function() local s, l = jamState(); return { strength = s, label = l } end)
exports("isJammed", function() return jamSent.strength > 0 end)

exports("setWaypoint", function(pos) return setWaypoint(pos, "export") end)
exports("clearWaypoint", function() return setWaypoint(nil, "export") end)
exports("getWaypoint", function() return waypoint end)
exports("getRoute", function() return route end)

exports("setConfig", function(patch)
    if type(patch) ~= "table" then return false end
    configPatches[#configPatches + 1] = patch
    send("map3d:config", patch)
    if type(patch.minimap) == "table" then CreateThread(syncMinimapSurface) end
    return true
end)
exports("setTheme", function(theme)
    if type(theme) ~= "table" then return false end
    configPatches[#configPatches + 1] = { theme = theme }
    send("map3d:theme", theme)
    return true
end)
exports("setMinimapVisible", function(visible)
    minimapVisible = visible ~= false
    send("map3d:minimap", { visible = minimapVisible })
    return true
end)
