-- Pursuit -- client presentation.
--
-- This half draws things and reports intent. It decides nothing: the ring is a
-- hint about where the server will accept a queue request, not the rule
-- itself. The server re-derives containment from replicated state, so a
-- tampered client gets a refusal rather than a queue slot.

local Config = PursuitConfig

local readyUpPoi
local lobbyRing
local readyUpZone
local queued = false

-- The vehicle-picker station: its own POI, its own proximity zone, and the
-- roster key its label is currently advertising.
--
-- IT EXISTS BECAUSE `/pursuit.vehicle` IS NOT AN ENTRY POINT. Nobody types a
-- command he does not already know exists, so the picker shipped invisible: a
-- player joined, saw the ready-up circle, queued, and never learned he could
-- have chosen a car. The fix is the same shape as the thing he DID find --
-- a circle on the ground with a prompt on it. The command still works; this is
-- an addition, not a replacement.
--
-- WHY A SECOND STATION RATHER THAN A SECOND CHOICE ON THE READY-UP CIRCLE.
-- `open77_interactions` does support up to four choices per card, but
-- `open77_worldui` builds its prompt from the single-choice shorthand and never
-- passes `choices` through -- so a two-choice card at the queue circle is not
-- reachable from this side of the facade, and reaching past it to
-- `open77_interactions` directly would mean a new hard dependency and a
-- permission Pursuit does not otherwise need. A separate station is the honest
-- shape anyway: choosing a car and committing to a match are two different
-- acts and must not share one key press.
local vehiclePoi
local vehicleZone
local vehicleKey            -- roster key the label was built from, or nil
local vehicleWatching = false

-- Which roster list the station opens.
--
-- A Pursuit player carries TWO picks -- the civilian car he runs in and the
-- NCPD car he chases in -- and has no role at all until a pair is drawn
-- (server/loadout.lua explains why at length). The panel shows one list per
-- open and has no in-panel switcher, so a single station has to choose one, and
-- it chooses the runner's list: eight records, every one of them a proven
-- `*_player` variant, and the list a player actually shops in. The NCPD list is
-- four records, three of them labelled UNTESTED and all four the same liveried
-- saloon.
--
-- The second list is not left invisible: the station's DESCRIPTION names the
-- NCPD car the player currently holds and the command that changes it. That is
-- strictly more discoverable than today, without putting a third ring in a
-- lobby whose boundary ring was removed for being clutter.
local VEHICLE_LIST = "civilian"
local VEHICLE_ID = "vehicle_pick"
local VEHICLE_RESOURCE = "open77_vehiclepicker"

-- How much clear ground to keep between the two stations, in metres.
--
-- `open77_worldui` gives a prompt `radius + 0.5` m of activation, so the queue
-- circle claims 2.5 m and this one claims 2.1 m: 4.6 m in total. 5.5 m leaves
-- nearly a metre of dead band in which NEITHER prompt is active, which is what
-- keeps a player aiming for one from tripping the other. The zones are looser
-- still -- 2.25 m and 1.85 m of exit radius, 4.1 m together -- so they clear
-- the same band with room to spare and can never both hold the player at once.
--
-- (Even overlapped, the two would not "fight": the interaction arbiter renders
-- one target at a time, active over merely visible, then priority, then
-- distance. The separation is so the player is never asked to resolve it.)
local MIN_VEHICLE_SEPARATION = 5.5

-- Handles from open77_groundcircle, the HUD-drawn fallback for the ground
-- rings. Held in a list rather than one field per ring because this half is
-- optional: whichever ones were created are the ones to remove.
local groundCircles = {}

-- Forward-declared so `teardown` below can drop the scanner blip. The scanner
-- itself lives further down, next to the events that drive it; only the handle
-- and the cleanup have to be reachable from up here.
local scannerBlip
local clearScannerBlip

-- worldReady fires more than once per session, and after a hot reload it does
-- not fire at all. Both cases are handled through this one flag.
local announced = false

-- Is the player in a match right now, as far as this VM knows?
--
-- The lobby's furniture -- the ready-up ring, its hold-E prompt, the boundary
-- ring, the proximity zone -- is drawn once and was then kept for the whole
-- session, so during a match it was still on screen with the player 1.3 km
-- away in another routing bucket, the prompt offering to queue at "6.1 M" and
-- ignoring its own 90 m `maxDistance`.
--
-- `maxDistance` was never the right lever. The prompt is not too far away; it
-- belongs to a world the player has left, and it would be equally wrong at
-- 10 m if that 10 m were in the match bucket. The rule is CONTEXT: the lobby's
-- props exist exactly while the player is in the lobby. Two edges drive it --
-- the first `pursuit:matchState` of a match tears them down, and
-- `pursuit:lobbyState` on the return puts them back.
local inMatch = false

local function callExport(resource, name, ...)
    local promise, reason = Open77.exports.call(resource, name, ...)
    if not promise then return nil, reason end
    local result, callError = promise:await()
    if not result or not result.ok then
        return nil, callError or (result and result.error) or "export_failed"
    end
    return result
end

-- The same call for an export that returns a PLAIN VALUE rather than an
-- `{ ok = ... }` response table.
--
-- `callExport` above is written for `open77_worldui` and `open77_zones`, which
-- both answer with a response table; `open77_vehiclepicker` answers with a
-- string, a boolean, or `nil, reason`, so putting its returns through
-- `callExport` would read every successful call as a failure. `promise:await()`
-- hands back the export's own return values verbatim, so this is just the
-- promise plumbing with no interpretation on top -- and a rejection arrives as
-- `nil, error`, which is the same shape as the export's own refusals.
local function callExportValue(resource, name, ...)
    local promise, reason = Open77.exports.call(resource, name, ...)
    if not promise then return nil, reason end
    return promise:await()
end

-- Nameplates off for the duration of a match, on again in the lobby.
--
-- The scanner rations the cop a stale fix; the nameplate handed him a live one.
-- `open77_nameplates` draws a plate over every attached remote player within
-- 35 m (`maximumDistance`, client/src/api/Nameplates.hpp) every frame, and its
-- draw path culls on depth and viewport only -- there is no occlusion test, so
-- the plate renders through walls. 35 m is inside the 45 m pressure band, which
-- means the leak was widest exactly where the chase is decided.
--
-- `setEnabled(false)` and not `set(opponentId, {visible=false})`, for a plain
-- reason: this client is never told the opponent's player id. `matchState`
-- carries `opponentName`, a string. The global switch is also the right shape
-- here anyway -- a match bucket holds the two players in the match, so "hide
-- every plate" and "hide the opponent's plate" are the same set.
--
-- Best-effort by construction, like drawGroundCircle: `open77_nameplates` is
-- not a declared dependency, so `callExport` answers nil plus a reason on a
-- server that omits it and this degrades to "no plates to hide".
local function setNameplates(visible)
    if Config.scanner == nil or not Config.scanner.hideOpponentNameplates then return end
    local ok, reason = callExport("open77_nameplates", "setEnabled", visible)
    if not ok then
        Open77.log.info(("nameplates %s not applied: %s"):format(
            visible and "restore" or "suppress", tostring(reason)))
        return
    end
    Open77.log.info(visible
        and "nameplates restored for the lobby"
        or "nameplates suppressed for the match")
end

local function readyUpPosition()
    local centre = Config.lobby.center
    local offset = Config.lobby.readyUp.offset
    return {
        x = centre.x + offset.x,
        y = centre.y + offset.y,
        z = centre.z + offset.z,
    }
end

-- Where the vehicle station stands -- DERIVED, not configured.
--
-- It sits on the SAME circle around the lobby centre as the ready-up ring, one
-- arc step further around it, so the two read as a matched pair of stations
-- flanking the spawn point rather than one marker with a stray twin. Deriving
-- it from `Config.lobby.readyUp.offset` rather than declaring a second offset
-- has a property a hand-written pair of coordinates cannot have: move the queue
-- circle and this one moves with it, still on the same circle, still the same
-- distance away. They cannot drift into each other's laps.
--
-- The arc step is 60 degrees, widened when the queue circle sits closer to the
-- centre than about 5.5 m. The chord between two points on a circle of radius
-- `r` subtending `theta` is `2*r*sin(theta/2)`, and that chord -- the ground
-- distance between the two stations -- is the only number that matters here, so
-- the angle is solved from the separation rather than picked and hoped for. At
-- the shipped 6 m offset the solve yields 54.6 degrees, the 60 degree floor
-- wins, and the stations end up exactly 6 m apart: as far from each other as
-- the queue circle is from the spawn point.
--
-- `Config.lobby.vehiclePicker.offset` overrides the whole derivation if a
-- future config ever declares one. Nothing declares it today and nothing has
-- to -- which is the point, since this needed no config edit at all.
local function vehiclePickerOffset()
    local override = Config.lobby.vehiclePicker
    if type(override) == "table" and type(override.offset) == "table" then
        return override.offset
    end

    local ready = Config.lobby.readyUp.offset
    local radius = math.sqrt(ready.x * ready.x + ready.y * ready.y)
    if radius < 0.01 then
        -- The queue circle is ON the spawn point, so there is no arc to walk
        -- around it. Step out along +x instead.
        return { x = MIN_VEHICLE_SEPARATION, y = 0.0, z = ready.z or 0.0 }
    end

    local angle = math.rad(60.0)
    local half = MIN_VEHICLE_SEPARATION / (2.0 * radius)
    if half >= 1.0 then
        -- No angle on this circle can open up the separation: the two are as
        -- far apart as they can be on opposite sides of the centre.
        angle = math.pi
    else
        angle = math.max(angle, 2.0 * math.asin(half))
    end

    local cosine, sine = math.cos(angle), math.sin(angle)
    return {
        x = ready.x * cosine - ready.y * sine,
        y = ready.x * sine + ready.y * cosine,
        z = ready.z or 0.0,
    }
end

-- Same z as the ready-up circle, and deliberately so.
--
-- The lobby's authored `z` is 14.8 while the measured collision surface here is
-- about 15.36, so every marker in this lobby is placed ~0.55 m below the ground
-- the player stands on. Nothing here corrects for that, because the ready-up
-- circle does not correct for it either and it works: the ring is drawn by
-- `open77_groundcircle`, which follows the real ground per vertex; the prompt
-- is anchored a metre above `position.z` and is a floating card that never
-- touches the floor; and the zone carries a 6 m vertical tolerance either side
-- of `position.z`, which swallows half a metre without noticing. Matching the
-- ready-up circle exactly is what makes that a MEASURED fact about this lobby
-- rather than a fresh assumption.
local function vehiclePickerPosition()
    local centre = Config.lobby.center
    local offset = vehiclePickerOffset()
    return {
        x = centre.x + offset.x,
        y = centre.y + offset.y,
        z = centre.z + (offset.z or 0.0),
    }
end

-- What this player currently drives on a roster list: the key, and its display
-- name.
--
-- The KEY comes from `open77_vehiclepicker`, which owns it -- it lives in the
-- player's own client KVP, namespaced per server and per resource, and the
-- picker applies the list default when he has never chosen. So yes, the current
-- selection IS readable from this side, and it is readable before the panel has
-- ever been opened, which is exactly the returning player the label is for.
--
-- The NAME comes from `Open77VehicleRoster`, the byte-identical roster copy
-- this resource already loads as a `shared_script` for server/loadout.lua, so
-- turning the key into words costs no round trip at all. The picker exports a
-- `roster` too; using the local copy instead is the same trade server/loadout.lua
-- already makes, drift risk included, and the drift is handled below by
-- degrading to a nameless label rather than by trusting the copy blindly.
--
-- Every step degrades to nil rather than to a guess: no picker on this server,
-- a list that was renamed, a key whose roster entry has since been dropped. A
-- nil name means the label carries no car -- never that it carries the wrong
-- one.
local function vehicleSelection(listId)
    local key = callExportValue(VEHICLE_RESOURCE, "selection", listId)
    if type(key) ~= "string" then return nil, nil end

    local roster = Open77VehicleRoster
    if type(roster) ~= "table" or type(roster.resolve) ~= "function" then
        return key, nil
    end
    local entry = roster.resolve(listId, key)
    return key, entry and entry.name or nil
end

-- The station's definition, or nil when there is no picker to open.
--
-- Returning nil is the whole graceful-degradation story, and it is the same one
-- `drawGroundCircle` tells: `open77_vehiclepicker` is NOT a declared dependency
-- of this resource, so a server whose resource set omits it must still run a
-- playable Pursuit. `Open77.exports.call` answers with
-- `export_resource_unavailable` there, `vehicleSelection` turns that into a nil
-- key, and the lobby is drawn with no station at all. A circle offering to open
-- a panel that does not exist would be worse than no circle.
local function vehicleDefinition()
    local key, name = vehicleSelection(VEHICLE_LIST)
    if key == nil then return nil end

    -- Best-effort second read, purely for the description. A nil here costs one
    -- sentence, not the station.
    local _, copName = vehicleSelection("police")

    -- The label answers BOTH questions a returning player has -- what is this,
    -- and what have I got -- because the second one is the question he actually
    -- walked over to ask. `//` is the separator the picker's own panel uses for
    -- exactly this kind of pairing.
    local label = name
        and ("Choose your vehicle // " .. name)
        or "Choose your vehicle"

    -- Naming the NCPD car here is what keeps the police list from being as
    -- invisible as the whole picker used to be. The command is spelled out
    -- because it is currently the only way to reach that list, and a command a
    -- player can read off a prompt is not the same thing as a command nobody
    -- mentioned.
    local description = copName
        and ("Your runner's car. NCPD car: " .. copName .. " -- /pursuit.vehicle cop")
        or "The car you drive as the runner."

    return {
        id = VEHICLE_ID,
        position = vehiclePickerPosition(),

        -- Smaller than the queue circle's 2.0 m, on purpose. Queueing is the
        -- point of the lobby and choosing a car is optional, so the objective
        -- stays the visually dominant ring and this one reads as its companion.
        -- 1.6 m still gives the prompt 2.1 m of activation, which is a
        -- comfortable walk-into target.
        radius = 1.6,

        -- STYLE, and why not `objective`.
        --
        -- The four presets are `interaction`, `objective`, `spawn`, `danger`,
        -- and on 2.31 the style that matters is the one the HUD fallback reads,
        -- because the native 3D ring does not draw at all. `open77_groundcircle`
        -- maps them to the OPEN//77 signal tokens: interaction #22D8E2,
        -- objective #F5C95C, spawn #4FE3A9, danger #FF5964 -- and it prefers an
        -- explicit `color` over the style's token when one is given.
        --
        -- The queue circle is `objective` but overrides its colour to #00E5FF,
        -- so what is actually on the ground next to this is a BRIGHT CYAN ring.
        -- That rules out `interaction`: #22D8E2 against #00E5FF is two cyans a
        -- metre apart and no player would ever tell them apart at a glance,
        -- which is the entire requirement. `danger` red is reserved for hazards
        -- and would read as a threat.
        --
        -- `spawn` green it is, and the semantics fit rather than merely being
        -- what was left: this is the marker that decides which vehicle gets
        -- SPAWNED for you at countdown, and green is the design system's
        -- preparation/ok token against the objective's signal cyan. The colour
        -- is passed explicitly as well, because `open77_worldui` defaults the
        -- PROMPT colour to #00E5FF regardless of style -- without this the card
        -- would be cyan over a green ring.
        style = "spawn",
        color = "#4FE3A9",

        -- Same visibility distance as the queue circle, taken from it rather
        -- than restated, so the pair appears and fades together from anywhere
        -- in the 50 m lobby.
        maxDistance = Config.lobby.readyUp.maxDistance,

        label = label,
        description = description,

        -- Press, not hold. The queue circle holds for a second because queueing
        -- is a commitment; opening a panel is reversible and cheap, and asking
        -- a player to hold a key to read a menu is friction with nothing behind
        -- it. Same key on both -- E is THE interact key, and the arbiter renders
        -- only one card at a time, so there is nothing here for two keys to
        -- disambiguate.
        key = "E",

        -- The two cues that separate the stations at a glance before a word is
        -- read: a car glyph on the floating marker instead of the queue
        -- circle's chevron, and a CAR badge on the card instead of DIALOG.
        marker = "vehicle",
        icon = "CAR",

        event = "pursuit:vehiclePickSelected",
    }, key
end

local function teardown()
    if readyUpPoi then
        callExport("open77_worldui", "remove", readyUpPoi)
        readyUpPoi = nil
    end
    if lobbyRing then
        callExport("open77_worldui", "remove", lobbyRing)
        lobbyRing = nil
    end
    if readyUpZone then
        callExport("open77_zones", "remove", readyUpZone)
        readyUpZone = nil
    end
    if vehiclePoi then
        callExport("open77_worldui", "remove", vehiclePoi)
        vehiclePoi = nil
    end
    if vehicleZone then
        callExport("open77_zones", "remove", vehicleZone)
        vehicleZone = nil
    end
    -- Cleared with the POI it described. A key left behind would make the next
    -- `refreshVehicleLabel` compare against a label that no longer exists and
    -- decide, wrongly, that nothing had changed.
    vehicleKey = nil
    for index = #groundCircles, 1, -1 do
        callExport("open77_groundcircle", "remove", groundCircles[index])
        groundCircles[index] = nil
    end
    -- A reload replaces this VM and destroys everything the old generation
    -- owned, but a blip that survived would be a stale marker with nothing left
    -- to update it -- the worst possible state for a mechanic built on the
    -- reader not being able to tell fresh from stale.
    clearScannerBlip()
end

-- Draw the same ring again on the HUD, through open77_groundcircle.
--
-- ADDED alongside the native marker, not instead of it, and that is a
-- deliberate choice with an end date. The native 3D ring does not draw on 2.31:
-- `entMeshComponent::mesh` is a bare RaRef and nothing in the build re-resolves
-- it, so a runtime mesh swap cannot work at all -- appearance, chunkMask,
-- lighting, component state and a shadowing archive were each eliminated first.
-- The worldui POI is still needed for the half that DOES work: it owns the
-- hold-E prompt, and dropping it to save a ring would take the interaction with
-- it. So both are created from the SAME definition table, and if the native ring
-- ever comes back, seeing TWO rings is the unambiguous signal that these calls
-- can be deleted.
--
-- `create` reads worldui's field names and IGNORES the prompt half (label, key,
-- event, icon, shape) rather than rejecting it, so the identical table works on
-- both. Passing the table itself, rather than a hand-copied subset, is what
-- keeps the two rings from silently drifting apart.
--
-- Best-effort by construction. `callExport` returns nil plus a reason and never
-- raises, so a server whose resource set has no open77_groundcircle degrades to
-- "no HUD ring" and the rest of build() is unaffected. Logged at info rather
-- than error for the same reason: an absent fallback is a configuration, not a
-- fault.
local function drawGroundCircle(definition, label)
    local circle, reason = callExport("open77_groundcircle", "create", definition)
    if not circle then
        Open77.log.info(("%s HUD ring not drawn: %s"):format(label, tostring(reason)))
        return
    end
    groundCircles[#groundCircles + 1] = circle.handle
end

local function build()
    teardown()

    local ready = Config.lobby.readyUp

    -- The ready-up circle: ring plus a hold-E prompt, created as one owned
    -- handle so a failure cannot leave half of it behind.
    local readyDefinition = {
        id = ready.id,
        position = readyUpPosition(),
        radius = ready.radius,
        shape = ready.shape,
        style = ready.style,
        maxDistance = ready.maxDistance,
        label = ready.label,
        description = ready.description,
        key = ready.key,
        holdSeconds = ready.holdSeconds,
        color = ready.color,
        icon = "DIALOG",
        event = "pursuit:readyUpSelected",
    }
    local poi, poiError = callExport("open77_worldui", "create", readyDefinition)
    if not poi then
        Open77.log.error("ready-up POI failed: " .. tostring(poiError))
    else
        readyUpPoi = poi.handle
    end
    drawGroundCircle(readyDefinition, "ready-up")

    -- The lobby boundary ring.
    --
    -- OFF by default since 2026-08-26. The owner played the lobby and asked for
    -- the outline gone while the limit stays: "laisse la limitation je veux
    -- dire mais on doit plus voir le contour, pas besoin, ça te prévient juste
    -- que tu sors du lobby". The leash's own warning is the teaching; the ring
    -- was decoration on top of it.
    --
    -- WHAT THIS DOES NOT DO: it does not relax the leash by one metre. The
    -- leash lives entirely in server/main.lua and reads `lobby.radius`,
    -- `leashWarnSeconds` and `leashReturnSeconds` straight from config. It has
    -- never consulted this ring and cannot: the client draws, the server
    -- judges. A player who wanders out is still warned at 4 s and returned at
    -- 10 s with nothing drawn at all.
    --
    -- The machinery below is deliberately LEFT INTACT rather than deleted. This
    -- is the native world-anchor path with occlusion and ground-following, and
    -- it only started drawing correctly on 2026-08-26 after a long
    -- investigation. `lobby.drawBoundary = true` brings the ring back and
    -- exercises that path again; deleting the code would have thrown the
    -- investigation away to satisfy a presentation note.
    --
    -- NOTE the 50 m clamp, still true and still worth knowing if the ring is
    -- ever switched back on: that is the radius ceiling both marker backends
    -- impose. `lobby.radius` is now 50.0 to match it exactly, so the drawn ring
    -- and the enforced rule are the same circle.
    if Config.lobby.drawBoundary then
        local boundsDefinition = {
            id = "lobby_bounds",
            position = Config.lobby.center,
            radius = math.min(50.0, Config.lobby.radius),
            style = "spawn",
            maxDistance = 300.0,
        }
        local ring, ringError = callExport("open77_worldui", "create", boundsDefinition)
        if not ring then
            Open77.log.error("lobby ring failed: " .. tostring(ringError))
        else
            lobbyRing = ring.handle
        end
        -- The boundary ring gets the fallback too, and the cost was measured
        -- rather than assumed. open77_groundcircle charges per POINT, not per
        -- circle, and picks a segment count from APPARENT size -- radius over
        -- view distance -- so a 50 m ring seen from inside it saturates at the
        -- same MAX_SEGMENTS as a 2 m ring seen from 6 m. Measured offline from
        -- the lobby centre: the two rings together are 50 points and 239
        -- payload nodes of the host's 1024, i.e. 23% of the cap, against a
        -- 96-point budget and a 6-circle limit.
        drawGroundCircle(boundsDefinition, "lobby boundary")
    end

    -- The vehicle station: ring, prompt and zone, built exactly the way the
    -- ready-up circle above is built and torn down on exactly the same edges.
    -- It is lobby furniture, so it belongs to the lobby's lifetime -- a prompt
    -- offering to choose a car would be noise mid-chase, and a choice made mid-
    -- match cannot be applied to a car that already exists anyway (the picker
    -- goes read-only and says so).
    local vehicleDef, selectedKey = vehicleDefinition()
    if vehicleDef == nil then
        Open77.log.info(
            "vehicle station not drawn: " .. VEHICLE_RESOURCE .. " unavailable")
    else
        local vehicle, vehicleError = callExport("open77_worldui", "create", vehicleDef)
        if not vehicle then
            Open77.log.error("vehicle POI failed: " .. tostring(vehicleError))
        else
            vehiclePoi = vehicle.handle
            vehicleKey = selectedKey
        end
        -- Same reason as the ready-up ring, and not optional in practice: the
        -- native 3D ring does not draw on 2.31, so without this the station is
        -- a prompt with no circle under it -- which is the discoverability
        -- problem all over again.
        drawGroundCircle(vehicleDef, "vehicle station")

        local vehicleProximity, vehicleZoneError = callExport("open77_zones", "create", {
            id = "vehicle_pick_zone",
            position = vehicleDef.position,
            radius = vehicleDef.radius,
            enterEvent = "pursuit:vehiclePickEnter",
            exitEvent = "pursuit:vehiclePickExit",
        })
        if not vehicleProximity then
            Open77.log.error("vehicle zone failed: " .. tostring(vehicleZoneError))
        else
            vehicleZone = vehicleProximity.handle
        end
    end

    -- Local proximity signal, used only for presentation.
    local zone, zoneError = callExport("open77_zones", "create", {
        id = "ready_up_zone",
        position = readyUpPosition(),
        radius = ready.radius,
        enterEvent = "pursuit:readyUpEnter",
        exitEvent = "pursuit:readyUpExit",
    })
    if not zone then
        Open77.log.error("ready-up zone failed: " .. tostring(zoneError))
    else
        readyUpZone = zone.handle
    end

    Open77.log.info(("pursuit lobby drawn at %.1f, %.1f, %.1f -- %d HUD ring(s) via open77_groundcircle"):format(
        Config.lobby.center.x, Config.lobby.center.y, Config.lobby.center.z,
        #groundCircles))

    -- Logged separately and with the geometry spelled out, because "the two
    -- circles are far enough apart" is the one claim about this station that
    -- cannot be checked by looking at the source: it depends on where the
    -- ready-up offset points today.
    if vehiclePoi ~= nil then
        local readyPoint = readyUpPosition()
        local station = vehiclePickerPosition()
        local dx, dy = station.x - readyPoint.x, station.y - readyPoint.y
        Open77.log.info(("vehicle station at %.1f, %.1f, %.1f -- %.1f m from the ready-up circle, showing %s"):format(
            station.x, station.y, station.z,
            math.sqrt(dx * dx + dy * dy), tostring(vehicleKey)))
    end
end

-- The shell observes worldReady during its own transition as well as on the
-- real handoff, so announcing twice would make the server issue a second
-- placement into a live respawn -- rejected with `transition_in_progress`.
AddEventHandler("open77:worldReady", function()
    if announced then
        Open77.log.debug("worldReady again; already announced")
        return
    end
    announced = true
    CreateThread(function()
        -- The world exists but the marker backend follows the streamed world;
        -- a short settle avoids creating effects into a half-built scene.
        Wait(2000)
        build()
        local sent, reason = TriggerServerEvent("pursuit:ready")
        if not sent then
            announced = false
            Open77.log.error("pursuit:ready not sent: " .. tostring(reason))
        end
    end)
end)

RegisterNetEvent("pursuit:lobbyState", function(state)
    if type(state) ~= "table" then return end
    Open77.log.info(("lobby state received: radius=%s"):format(tostring(state.radius)))
    -- Back in the lobby: its furniture comes back with it. The edge only --
    -- this event is also the reply to a redundant `pursuit:ready`, and a
    -- rebuild there would drop and recreate the rings for no reason.
    if inMatch then
        inMatch = false
        build()
        -- Back among people rather than hunting one: knowing who you are
        -- queuing against is the whole social point of a lobby.
        setNameplates(true)
    end
end)

RegisterNetEvent("pursuit:queueState", function(state)
    if type(state) ~= "table" then return end
    queued = state.queued == true
    if queued then
        Open77.log.info(("queued: %s/%s"):format(
            tostring(state.position), tostring(state.total)))
    else
        Open77.log.info("not queued")
    end
end)

-- --------------------------------------------------------------- scanner ---
--
-- The client half of design §5.5 items 1-3. It DRAWS; it decides nothing. The
-- server chose the moment and the position, and this file has no idea where the
-- runner actually is -- which is the point: there is nothing here for a
-- tampered client to read.
--
-- The blip is POSITION-attached, never entity-attached. `Open77.blips` supports
-- both, and the entity form is the obvious one to reach for -- it would also
-- delete the entire mechanic, because it would track the runner live. The blip
-- is supposed to be wrong most of the time.

-- When the displayed fix was taken, on this client's monotonic clock, and which
-- visual stage the blip is currently wearing. `Open77.time.monotonic()` returns
-- SECONDS as a float (see the projtest below, which multiplies its deltas by
-- 1000), so both of these are in seconds.
local scannerFixAt
local scannerStale = false

function clearScannerBlip()
    scannerFixAt = nil
    scannerStale = false
    if scannerBlip == nil then return end
    local ok, reason = pcall(Open77.blips.remove, scannerBlip)
    if not ok then
        Open77.log.debug("scanner blip removal failed: " .. tostring(reason))
    end
    scannerBlip = nil
end

-- Make the fix look its age.
--
-- The cop should be able to tell a fresh fix from a rotting one WITHOUT reading
-- a number, so that "the marker is a memory" is legible from the map itself.
--
-- The lever is the sprite, and that is forced by the engine rather than chosen.
-- wiki/blips.md: "gamemappinsMappinData carries neither colour nor scale. Those
-- properties belong to the UI/TweakDB profile the game picks. The API therefore
-- offers no fake `color` or `scale` that would do nothing." So there is no alpha
-- to fade and no radius to grow -- the icon and its tooltip text are the whole
-- available vocabulary, and this uses both.
--
-- Idempotent on the sprite: `setSprite` is called only when the STAGE changes,
-- not once a second. The description is refreshed while stale because it
-- carries a live number and would otherwise freeze at the threshold value,
-- claiming 6 s forever on a fix that is twelve seconds old.
local function applyScannerStage(stale, ageSeconds)
    if scannerBlip == nil then return end
    local blipConfig = Config.scanner and Config.scanner.blip or {}

    if stale ~= scannerStale then
        scannerStale = stale
        local sprite = stale
            and (blipConfig.staleSprite or "quest")
            or (blipConfig.sprite or "objective")
        local ok, reason = Open77.blips.setSprite(scannerBlip, sprite)
        if not ok then
            Open77.log.debug("scanner blip sprite change failed: " .. tostring(reason))
        end
        if not stale then
            Open77.blips.setDescription(scannerBlip,
                blipConfig.description or "Last known position of the runner.")
        end
    end

    if stale then
        local template = blipConfig.staleDescription
            or "Runner was here %.0fs ago. He has moved."
        Open77.blips.setDescription(scannerBlip, template:format(ageSeconds))
    end
end

-- One 1 Hz thread for the whole session.
--
-- Started here rather than per-ping so there is exactly one of them: a thread
-- spawned on every sweep would accumulate one per fix for the length of a
-- match. It costs nothing when there is no blip, which is most of the time --
-- the lobby, the countdown, and every player who is not the cop.
CreateThread(function()
    while true do
        Wait(1000)
        if scannerBlip ~= nil and scannerFixAt ~= nil then
            local threshold = (Config.scanner and Config.scanner.blip
                and Config.scanner.blip.staleAfterSeconds) or 6.0
            local age = Open77.time.monotonic() - scannerFixAt
            applyScannerStage(age >= threshold, age)
        end
    end
end)

RegisterNetEvent("pursuit:scannerPing", function(payload)
    if type(payload) ~= "table" or type(payload.position) ~= "table" then return end
    local blipConfig = Config.scanner and Config.scanner.blip or {}
    local position = {
        x = payload.position.x,
        y = payload.position.y,
        z = payload.position.z,
    }

    if scannerBlip == nil then
        local id, reason = Open77.blips.create({
            position = position,
            sprite = blipConfig.sprite or "ActionScanVariant",
            title = blipConfig.title or "Scanner contact",
            description = blipConfig.description or "Last known position of the runner.",
            active = true,
            visibleThroughWalls = blipConfig.visibleThroughWalls ~= false,
        })
        if id == nil then
            -- Not fatal. The mode is still playable from the HUD's numeric
            -- staleness readout, which comes from the same server push.
            Open77.log.error("scanner blip create failed: " .. tostring(reason))
            return
        end
        -- Blip ids are 64-bit decimal STRINGS. wiki/blips.md is explicit: never
        -- convert them with tonumber. Keep the value exactly as returned.
        scannerBlip = id
        scannerStale = false
    else
        -- setPosition, not a recreate. It also guarantees the blip stays
        -- positional even if something else ever attaches it.
        local ok, reason = Open77.blips.setPosition(scannerBlip, position)
        if not ok then
            Open77.log.debug("scanner blip move failed: " .. tostring(reason))
            clearScannerBlip()
        end
    end

    -- The fix is new as of NOW, so the ageing clock restarts and the blip goes
    -- back to its fresh icon. Taken on arrival rather than from a server
    -- timestamp: the two clocks are unrelated, and the flight time is a few
    -- tens of milliseconds against a six-second threshold.
    --
    -- `repushScannerTo` on the server is the one case this is deliberately
    -- WRONG about, and it is wrong in the honest direction. A republish
    -- re-sends the OLD sample, and this resets the age to zero, so the icon
    -- looks fresher than the fix is for one cycle. The server's own
    -- `scannerAgeMs` -- which is what the HUD number reads -- is untouched by a
    -- republish and keeps telling the truth, so the two disagree only until the
    -- next sweep, and only after a resource reload.
    scannerFixAt = Open77.time.monotonic()
    applyScannerStage(false, 0)

    Open77.log.info(("SCAN #%s%s -> %.1f, %.1f, %.1f (next in %sms)"):format(
        tostring(payload.sequence), payload.pressure and " PRESSURE" or "",
        position.x, position.y, position.z, tostring(payload.nextInMs)))
end)

RegisterNetEvent("pursuit:scannerClear", function()
    clearScannerBlip()
end)

-- The runner's half. He does not see the blip -- he FEELS the sweep.
--
-- Both effects are best-effort and the failures are informative rather than
-- fatal. `vfx` takes a curated alias; `sfx` takes a Wwise event name whose
-- catalogue is seeded from game version 1.6 and flagged as requiring 2.31
-- runtime validation, so a silent cue means "unvalidated event name", not
-- "broken pipeline".
RegisterNetEvent("pursuit:scanned", function(payload)
    if type(payload) ~= "table" then return end

    if payload.vfx ~= nil then
        local state = Open77.character.state()
        local position = state and state.position
        if position ~= nil then
            local handle, reason = Open77.vfx.play(payload.vfx, {
                position = { x = position.x, y = position.y, z = position.z },
                duration = payload.vfxDurationSeconds or 1.2,
            })
            if handle == nil then
                Open77.log.debug("scan vfx failed: " .. tostring(reason))
            end
        end
    end

    if payload.sfx ~= nil then
        -- No `entity`, so it emits from the local player and follows him.
        local handle, reason = Open77.sfx.play(payload.sfx, {
            tag = "pursuit_scan",
            unique = true,
            duration = payload.sfxDurationSeconds or 2.0,
        })
        if handle == nil then
            Open77.log.debug("scan sfx failed: " .. tostring(reason))
        end
    end

    Open77.log.info(("SCANNED #%s%s"):format(
        tostring(payload.sequence), payload.pressure and " PRESSURE" or ""))
end)

RegisterNetEvent("pursuit:matchState", function(state)
    if type(state) ~= "table" then return end
    -- The lobby is not where he is any more. Drop its furniture on the edge
    -- only: this event arrives at 2 Hz while a match is active, and `teardown`
    -- also drops the scanner blip -- running it on every push would delete the
    -- cop's blip twice a second, which is the one marker a match owns.
    --
    -- Doing it here rather than on a dedicated "transferred" event is what
    -- makes a mid-match resource reload self-correct: the reloaded VM draws the
    -- lobby again from onClientResourceStart and the next push, at most 500 ms
    -- later, takes it back down.
    if not inMatch and state.state ~= "resolved" then
        inMatch = true
        teardown()
        -- Same edge as the lobby furniture, and for the same reason: this event
        -- arrives at ~1.5 Hz, so doing it on every push would be an export call
        -- and a native render toggle twice a second for the whole match.
        setNameplates(false)
    end
    if state.state == "resolved" then
        -- The server also sends `pursuit:scannerClear`, but a marker whose
        -- entire job is to be stale must not be the thing left behind when the
        -- match that owned it ends.
        clearScannerBlip()
        Open77.log.info(("MATCH resolved: outcome=%s won=%s role=%s"):format(
            tostring(state.outcome), tostring(state.won), tostring(state.role)))
        -- Deliberately NOT rebuilding here. Resolution precedes the bucket
        -- transfer by about five seconds, and drawing the lobby now would put
        -- the ready-up prompt back on screen while the player is still standing
        -- in the match world. `pursuit:lobbyState` is the correct edge, and the
        -- server sends it from `sendToLobby` -- the one function every path
        -- into the lobby goes through -- so there is nothing here to hedge
        -- against with a timer.
        return
    end
    Open77.log.info(("MATCH %s: id=%s mode=%s role=%s opponent=%s duration=%ss"):format(
        tostring(state.state), tostring(state.matchId), tostring(state.mode),
        tostring(state.role), tostring(state.opponentName),
        tostring(state.durationSeconds)))
end)

-- Latency probe.
--
-- Samples camera yaw and the projected screen X of one fixed world point in the
-- SAME tick. Both numbers come from the same instant, so comparing their traces
-- separates two very different faults:
--   * projection already lags the camera  -> the fault is in camera.project or
--     the camera transform it reads, and no amount of UI work will fix it;
--   * projection tracks the camera exactly -> the fault is downstream, in the
--     Lua->CEF->composite presentation path.
RegisterNetEvent("pursuit:projtest", function()
    CreateThread(function()
        -- Buffer the samples and log ONCE at the end. Logging inside the loop
        -- is file I/O on the Lua frame budget, which slows the very scheduler
        -- being measured -- an earlier run with per-sample logging reported
        -- 291ms intervals that were largely the instrument's own cost.
        local anchor = readyUpPosition()
        local samples = {}
        for index = 1, 120 do
            local view = Open77.camera.view()
            local projected = Open77.camera.project(anchor)
            samples[index] = {
                t = Open77.time.monotonic(),
                fx = view and view.forward.x or 0,
                px = projected and projected.x or 0,
            }
            Wait(0)
        end

        local deltas, sum, worst, best = {}, 0, 0, math.huge
        for index = 2, #samples do
            local ms = (samples[index].t - samples[index - 1].t) * 1000
            deltas[#deltas + 1] = ("%.0f"):format(ms)
            sum = sum + ms
            if ms > worst then worst = ms end
            if ms < best then best = ms end
        end
        Open77.log.info(("PROJTEST Wait(0) servicing: n=%d avg=%.1fms min=%.0fms max=%.0fms")
            :format(#deltas, sum / math.max(1, #deltas), best, worst))
        Open77.log.info("PROJTEST intervals: " .. table.concat(deltas, " "))
    end)
end)

-- The prompt fired. Report intent only; the server decides.
AddEventHandler("pursuit:readyUpSelected", function()
    CreateThread(function()
        local sent, reason = TriggerServerEvent("pursuit:queueIntent")
        if not sent then
            Open77.log.error("queue intent not sent: " .. tostring(reason))
        end
    end)
end)

-- Rebuild the station's label around the pick the player just made.
--
-- `open77_worldui` has no `update` -- "remove and recreate under the same id"
-- is its documented way to change a POI -- so this drops and recreates the POI
-- ONLY. The HUD ring carries no copy and has not moved, and neither has the
-- zone, so churning either would be two more export calls to draw the same
-- circle in the same place.
--
-- Guarded three ways, because it runs on a thread that started before the
-- player's last few seconds happened: no POI means the lobby was torn down
-- underneath it (a match started, or the resource reloaded); a nil definition
-- means the picker went away; an unchanged key means he opened the panel and
-- closed it without picking anything, which is most of the time.
local function refreshVehicleLabel()
    if vehiclePoi == nil then return end

    local definition, selectedKey = vehicleDefinition()
    if definition == nil or selectedKey == vehicleKey then return end

    callExport("open77_worldui", "remove", vehiclePoi)
    vehiclePoi = nil
    local vehicle, vehicleError = callExport("open77_worldui", "create", definition)
    if not vehicle then
        -- The ring and the zone are still there, so the station has not
        -- vanished -- it has lost its prompt. Loud, because that is exactly the
        -- half-a-station state the worldui facade exists to prevent, and the
        -- next `build()` is what puts it right.
        Open77.log.error("vehicle POI refresh failed: " .. tostring(vehicleError))
        return
    end
    vehiclePoi = vehicle.handle
    vehicleKey = selectedKey
    Open77.log.info("vehicle station now showing " .. tostring(selectedKey))
end

-- The station's prompt fired: open the panel, then watch for it to close.
--
-- The watch is a POLL rather than a subscription because there is nothing to
-- subscribe to. The picker reports a pick to the SERVER
-- (`open77_vehiclepicker:selected`) and raises no client-side event at all, so
-- the only client-visible edge is its `isOpen` export going false -- and it can
-- go false through any of the picker's five close paths, including its own
-- watchdog. Polling that one fact covers all five without knowing about any of
-- them.
--
-- 300 ticks at 500 ms is 150 s, comfortably past the picker's own 60 s maximum
-- open time, so the loop ends because the panel closed rather than because the
-- loop gave up. `vehicleWatching` keeps a second press from stacking a second
-- watcher; the picker itself is happy to be re-opened, but two threads racing
-- to recreate one POI is not something to find out about later.
AddEventHandler("pursuit:vehiclePickSelected", function()
    if vehicleWatching then return end
    vehicleWatching = true
    CreateThread(function()
        local opened, reason = callExportValue(VEHICLE_RESOURCE, "open", {
            list = VEHICLE_LIST,
            -- No deadline, deliberately, and for the same reason the command
            -- passes none: this is opened on demand, from the lobby, with
            -- nothing waiting on it. A clock would add pressure to a decision
            -- that has none.
        })
        if opened ~= true then
            vehicleWatching = false
            Open77.log.error("vehicle picker did not open: " .. tostring(reason))
            return
        end

        for _ = 1, 300 do
            Wait(500)
            if callExportValue(VEHICLE_RESOURCE, "isOpen") ~= true then break end
        end
        vehicleWatching = false
        refreshVehicleLabel()
    end)
end)

-- Diagnostic. `rendered` comes from the native marker registry, so it
-- separates "the Lua handle exists" from "the REDengine effect is actually
-- alive" -- the two failure modes look identical from Lua otherwise.
RegisterNetEvent("pursuit:dumpMarkers", function()
    CreateThread(function()
        -- pursuit holds no world.markers on purpose; the registry is read
        -- through the resource that owns the permission.
        local result, reason = callExport("open77_worldui", "dump")
        if not result then
            Open77.log.error("marker dump failed: " .. tostring(reason))
        end
    end)

    local state = Open77.character.state()
    if state and state.position then
        Open77.log.info(("MARKER player at %.1f,%.1f,%.1f"):format(
            state.position.x, state.position.y, state.position.z))
    end
end)

AddEventHandler("pursuit:readyUpEnter", function()
    Open77.log.debug("entered the ready-up circle")
end)

AddEventHandler("pursuit:readyUpExit", function()
    Open77.log.debug("left the ready-up circle")
end)

-- Presentation only, exactly like the ready-up pair above: the zone proves
-- nothing and grants nothing. It is here so the separation between the two
-- stations is OBSERVABLE from the log -- walking from one circle to the other
-- should produce an exit line before the next enter line, never two "inside"
-- states at once.
AddEventHandler("pursuit:vehiclePickEnter", function()
    Open77.log.debug("entered the vehicle station")
end)

AddEventHandler("pursuit:vehiclePickExit", function()
    Open77.log.debug("left the vehicle station")
end)

AddEventHandler("onClientResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    Open77.log.info(("pursuit client ready, generation %d"):format(
        Open77.resource.generation()))

    -- Hot reload is the point of this resource being separate, so it has to
    -- work. A reload replaces the VM while the world is already up, and
    -- `open77:worldReady` has long since fired -- waiting for it again means
    -- the POIs are destroyed with the old generation and never recreated.
    -- Detect an already-live world and rebuild immediately instead.
    CreateThread(function()
        Wait(500)
        if announced then return end
        local state = Open77.character.state()
        if not state or not state.attached then
            -- Fresh session: worldReady will drive the build.
            return
        end
        Open77.log.info("world already live at start; rebuilding after reload")
        announced = true
        build()
        local sent, reason = TriggerServerEvent("pursuit:ready")
        if not sent then
            Open77.log.error("pursuit:ready not sent after reload: " .. tostring(reason))
        end
    end)
end)

AddEventHandler("onClientResourceStop", function(name)
    if name ~= GetCurrentResourceName() then return end
    announced = false
    teardown()
    -- Hand the plates back before this VM dies.
    --
    -- `enabled` lives in open77_nameplates' OWN VM and survives a reload of
    -- this resource, so a pursuit reload taken mid-match would otherwise leave
    -- every nameplate on the server switched off with nothing left alive that
    -- remembers why. Restoring here is self-correcting in the other direction
    -- too: if the match is still running, the next `matchState` push -- at most
    -- ~700 ms away -- turns them straight back off.
    setNameplates(true)
end)







