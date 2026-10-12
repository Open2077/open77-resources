-- The two lobby stations -- the way into the mode (decision 10).
--
-- `/dm` works and stays as the admin and power-user fallback. It is not how
-- anybody FINDS a mode. This file is the other half of section 5 of
-- docs/gamemode-pvp-arena-plan.md: a ring on the ground and a held key, so a
-- player who has never read a command list can still walk into a fight.
--
-- WHAT IS ALREADY BUILT ELSEWHERE, and is not repeated here:
--
--   * the descriptors     `Config.stations.enter` / `.queue` -- radius, style,
--                         colour, key, hold, marker, icon, event.
--   * the copy            `Config.strings.station` -- every player-facing word,
--                         English, in the shared table like the rest of the mode.
--   * the marks           `DeathmatchKabuki.stations`, captured by
--                         `/dm.survey start station`.
--   * the server half     `deathmatch:stationEnter` joins a free-for-all
--                         instance outright (free-for-all is a place and never
--                         queues -- decision 1); `deathmatch:stationQueue`
--                         opens the format panel, which sends `deathmatch:queue`.
--
-- So this file only DRAWS, and it is the last missing piece: nothing in either
-- resource called `open77_worldui`, `open77_groundcircle` or `open77_zones`
-- before it existed, which is why `/dm` was the only way in.
--
--
-- FIVE THINGS PURSUIT PAID FOR ONCE ALREADY, all of them load-bearing here.
--
-- 1. ON 2.31 THE NATIVE 3D RING DOES NOT DRAW AT ALL. `entMeshComponent::mesh`
--    is a bare RaRef and nothing in the build re-resolves it, so the marker
--    `open77_worldui` creates is invisible. What the player actually sees is
--    `open77_groundcircle`, which follows the real ground per vertex. The
--    worldui POI is still created from the SAME table, because it owns the half
--    that does work -- the hold-E prompt. If the native ring ever comes back,
--    two rings is the unambiguous signal that `drawGroundCircle` can go.
--
-- 2. `open77_worldui` GIVES A PROMPT `radius + 0.5 m` OF ACTIVATION. Two
--    stations closer than the sum of their activations leave a dead band in
--    which NEITHER prompt is live -- worse than an overlap, because an overlap
--    is arbitrated and a dead band just looks broken. `Config.stations.
--    minSeparationMetres` is checked against the surveyed marks below, and a
--    violation is logged loudly rather than drawn quietly.
--
-- 3. THE PROMPT COLOUR DEFAULTS TO `#00E5FF` REGARDLESS OF STYLE. Both
--    descriptors pass `color` explicitly; without it the queue station's green
--    ring would carry a cyan card.
--
-- 4. OWNERSHIP, NOT `maxDistance`, IS THE TEARDOWN LEVER. Pursuit shipped a bug
--    where the ready-up prompt followed the player into a match and offered to
--    queue "at 6.1 M" from another routing dimension. The rule is CONTEXT: the
--    lobby's furniture exists exactly while the player is in the lobby. The
--    edge here is `deathmatch:state` -- `participant` is true the moment the
--    player is in an instance, and the stations come down on that transition
--    and go back up when they return.
--
-- 5. THE ARBITER RENDERS ONE CARD AT A TIME, so both stations share `E`. They
--    are separated by the marker glyph and the card badge, not by two keys.
--
--
-- AND ONE THIS FILE ADDS: THE MARKS MAY NOT EXIST YET.
--
-- `DeathmatchKabuki.stations` ships with `position = nil` twice, and this file
-- draws NOTHING when that is still true. It does not fall back to
-- `Config.lobby.center`, which is what the config comment used to promise:
-- both stations would land on one point, which is exactly the dead band rule 2
-- forbids, and a ring on ground nobody chose is indistinguishable to a player
-- from a surveyed one. An absence that says so in one log line is honest; a
-- guess that looks right is not. `/dm` is the way in until the survey exists.

local Config = DeathmatchConfig
local Kabuki = DeathmatchKabuki

-- Handles are per station id, because the two are created and destroyed
-- together but refreshed independently: only the card TEXT changes at runtime,
-- and only for the station whose numbers moved.
local stations = {}       -- id -> { poi, circle, zone, description }
local built = false
local inLobby = false
local lastState = nil
local nearby = {}         -- id -> true while the player is inside its zone
local lastRefreshMs = {}  -- id -> monotonic seconds of the last recreate

-- `open77_worldui` has no `update` -- "remove and recreate under the same id"
-- is its documented way to change a POI -- so a description refresh destroys
-- and rebuilds the prompt. Do that at the 2 Hz the state push arrives at and a
-- player holding E would have the prompt pulled out from under them twice a
-- second. Two guards: the text has to have actually changed, and no more than
-- one recreate every REFRESH_INTERVAL.
local REFRESH_INTERVAL_S = 3.0

-- Whether the survey gap has already been explained. Logged once per lobby
-- entry rather than every push: the operator needs to be told, not nagged.
local explained = false


-- --------------------------------------------------------------- exports ---

-- Written for `open77_worldui`, `open77_groundcircle` and `open77_zones`, which
-- all answer with an `{ ok = ... }` response table. Never raises: a resource set
-- missing one of them answers `nil` plus a reason, and every caller below treats
-- that as "this piece is not drawn" rather than as a fault.
local function callExport(resource, name, ...)
    local promise, reason = Open77.exports.call(resource, name, ...)
    if not promise then return nil, reason end
    local result, callError = promise:await()
    if not result or not result.ok then
        return nil, callError or (result and result.error) or "export_failed"
    end
    return result
end


-- ------------------------------------------------------------------ copy ---
--
-- Every word comes from `Config.strings.station`. A station that cannot tell
-- you whether anybody is playing is a sign, not an invitation -- so the card
-- carries live numbers, and those numbers are the lobby fragment's, unmodified.

local function stationStrings()
    local strings = Config.strings and Config.strings.station
    return type(strings) == "table" and strings or {}
end

local function number(value)
    local parsed = tonumber(value)
    return parsed ~= nil and math.floor(parsed) or 0
end

--- "12 playing across 2 instance(s). You land in a 5/12 fight."
---
--- `target` is the instance the kernel would actually put this player in --
--- the fullest one with room -- so the fraction describes the fight they are
--- about to walk into rather than an average of every instance. When there is
--- no such instance the copy says so instead of printing "0/12", which reads
--- as a broken counter rather than as an empty server.
local function enterDescription(state)
    local strings = stationStrings()
    if state == nil then return strings.enterIdle end

    local instances = number(state.instanceCount)
    if instances <= 0 or state.target == nil then
        return strings.enterIdle
    end
    if type(strings.enterSummary) ~= "string" then return strings.enterIdle end
    return strings.enterSummary:format(
        number(state.instancePlayers), instances,
        number(state.targetCount), number(state.instanceCapacity))
end

--- "1v1 0 queued  -  2v2 2 queued  -  3v3 0 queued", or this player's own
--- position when they are already standing in one of them.
local function queueDescription(state)
    local strings = stationStrings()
    if state == nil then return strings.queueSummary and strings.queueSummary:format(0, 0, 0) end

    if state.queueFormat ~= nil and type(strings.queueQueued) == "string" then
        return strings.queueQueued:format(
            number(state.queuePosition), tostring(state.queueFormat))
    end

    local counts = type(state.arenaQueue) == "table" and state.arenaQueue or {}
    if type(strings.queueSummary) ~= "string" then return nil end
    return strings.queueSummary:format(
        number(counts["1v1"]), number(counts["2v2"]), number(counts["3v3"]))
end

local DESCRIPTION = {
    enter = enterDescription,
    queue = queueDescription,
}


-- ----------------------------------------------------------- descriptors ---

--- The worldui POI table for one station, or nil plus a reason.
---
--- The SAME table is handed to `open77_groundcircle`: `create` reads worldui's
--- field names and IGNORES the prompt half rather than rejecting it, so passing
--- the table itself instead of a hand-copied subset is what keeps the ring and
--- the prompt from silently drifting apart.
local function definitionFor(id, state)
    local descriptor = Config.stations and Config.stations[id]
    if type(descriptor) ~= "table" then return nil, "no_descriptor" end

    local mark = Kabuki.station(id)
    if mark == nil then return nil, "not_surveyed" end

    local strings = stationStrings()
    local label = id == "enter" and strings.enterLabel or strings.queueLabel
    local describe = DESCRIPTION[id]

    return {
        id = descriptor.id,
        position = mark.position,
        radius = descriptor.radius,
        style = descriptor.style,
        color = descriptor.color,
        maxDistance = Config.stations.maxDistance,
        label = label,
        description = describe and describe(state) or nil,
        key = descriptor.key,
        -- `hold` is the descriptor's intent; `holdSeconds` is what the
        -- interactions service actually reads. A hold of zero is a press, so a
        -- descriptor that says `hold = true` and forgets the duration would
        -- silently become a tap -- which is the one thing the entry station
        -- must not be. Hold for a commitment, press for something reversible.
        holdSeconds = descriptor.hold and (tonumber(descriptor.holdSeconds) or 0.9) or 0,
        marker = descriptor.marker,
        icon = descriptor.icon,
        event = descriptor.event,
    }
end


-- ------------------------------------------------------------ build/tear ---

local function removeStation(id)
    local entry = stations[id]
    if entry == nil then return end
    if entry.poi then callExport("open77_worldui", "remove", entry.poi) end
    if entry.circle then callExport("open77_groundcircle", "remove", entry.circle) end
    if entry.zone then callExport("open77_zones", "remove", entry.zone) end
    stations[id] = nil
    nearby[id] = nil
    lastRefreshMs[id] = nil
end

local function teardown()
    for id in pairs(stations) do removeStation(id) end
    built = false
end

--- The ground ring, through `open77_groundcircle`.
---
--- Best-effort by construction even though the manifest declares the resource:
--- `callExport` answers nil plus a reason and never raises, so a set that has
--- lost it degrades to "prompt with no circle" rather than to no station at all.
--- Logged at INFO, because an absent fallback is a configuration and not a fault.
local function drawGroundCircle(id, definition)
    local circle, reason = callExport("open77_groundcircle", "create", definition)
    if not circle then
        Open77.log.info(("deathmatch: %s station ring not drawn: %s"):format(
            id, tostring(reason)))
        return nil
    end
    return circle.handle
end

local function buildStation(id, state)
    local definition, reason = definitionFor(id, state)
    if definition == nil then return false, reason end

    local poi, poiError = callExport("open77_worldui", "create", definition)
    if not poi then
        Open77.log.error(("deathmatch: %s station POI failed: %s"):format(
            id, tostring(poiError)))
        return false, "poi_failed"
    end

    local entry = {
        poi = poi.handle,
        circle = drawGroundCircle(id, definition),
        description = definition.description,
    }

    -- The proximity zone is presentation only, and it earns its place by
    -- bounding the refresh: the card's live numbers are only worth recreating a
    -- prompt for while somebody is standing close enough to read them. The
    -- server re-derives every containment claim it acts on; this one is never
    -- acted on at all.
    local zone, zoneError = callExport("open77_zones", "create", {
        id = definition.id .. "_zone",
        position = definition.position,
        radius = math.max(definition.radius, 8.0),
        enterEvent = "deathmatch:stationNear:" .. id,
        exitEvent = "deathmatch:stationFar:" .. id,
    })
    if zone then
        entry.zone = zone.handle
    else
        -- No zone means no proximity signal, so the refresh has to assume the
        -- player is always near rather than never: a card frozen on the numbers
        -- it was built with is the failure this whole block exists to avoid.
        nearby[id] = true
        Open77.log.info(("deathmatch: %s station zone not created (%s); refreshing unconditionally")
            :format(id, tostring(zoneError)))
    end

    stations[id] = entry
    return true
end

--- Draws both stations, or explains once why it cannot.
local function build(state)
    teardown()

    local enterMark, queueMark = Kabuki.station("enter"), Kabuki.station("queue")
    if enterMark == nil or queueMark == nil then
        if not explained then
            explained = true
            -- ONE line, and it names the exact command, because the reader of
            -- this line is the person who can fix it in ninety seconds.
            Open77.log.warn(
                ("deathmatch: entry stations not drawn -- %s unsurveyed in DeathmatchKabuki.stations. " ..
                 "Capture them with: /dm.survey start station -> mark (enter) -> mark (queue) -> dump, " ..
                 "then paste the emitted block into shared/kabuki.lua. /dm is the way in until then."):format(
                    enterMark == nil and (queueMark == nil and "both marks are" or "'enter' is")
                        or "'queue' is"))
        end
        return
    end

    -- Both are surveyed, so the separation is measurable, and a violation is
    -- worth saying out loud: two prompts inside each other's activation leave a
    -- band where neither fires, and the symptom is a station that ignores you
    -- rather than one that is missing.
    local separation = Kabuki.stationSeparation()
    local minimum = tonumber(Config.stations.minSeparationMetres) or 6.0
    if separation ~= nil and separation < minimum then
        Open77.log.warn(("deathmatch: the two entry stations are %.2f m apart and the minimum is %.2f m -- " ..
            "re-survey them further apart or one of the two prompts will not fire."):format(
            separation, minimum))
    end

    local drawn = 0
    for _, id in ipairs({ "enter", "queue" }) do
        local ok, reason = buildStation(id, state)
        if ok then
            drawn = drawn + 1
        else
            Open77.log.error(("deathmatch: %s station not built: %s"):format(id, tostring(reason)))
        end
    end

    built = drawn > 0
    if built then
        Open77.log.info(("deathmatch: %d entry station(s) drawn -- enter at %.1f %.1f %.1f, queue %.1f m away")
            :format(drawn, enterMark.position.x, enterMark.position.y, enterMark.position.z,
                separation or 0.0))
    end
end

--- Repaint one station's card with the numbers it is showing now.
---
--- Both guards matter and neither is cosmetic: recreating a prompt a player is
--- holding cancels the hold, so the text has to have genuinely changed AND the
--- last recreate has to be old enough that a hold started after it has finished.
local function refresh(id, state)
    local entry = stations[id]
    if entry == nil then return end
    if nearby[id] ~= true then return end

    local definition = definitionFor(id, state)
    if definition == nil then return end
    if definition.description == entry.description then return end

    local now = Open77.time.monotonic()
    local last = lastRefreshMs[id] or 0
    if now - last < REFRESH_INTERVAL_S then return end
    lastRefreshMs[id] = now

    -- Remove and recreate under the same id: worldui's documented way to change
    -- a POI. The ring and the zone are untouched -- their geometry did not move,
    -- and destroying them would make the card flicker AND the circle blink.
    callExport("open77_worldui", "remove", entry.poi)
    local poi, poiError = callExport("open77_worldui", "create", definition)
    if not poi then
        -- A station with a ring and no prompt is the half-built state the
        -- worldui facade exists to prevent, so say so rather than leave a ring
        -- the player can walk into and nothing happens.
        entry.poi = nil
        -- Cleared so the next refresh cannot decide the text is unchanged and
        -- skip: this station now has a ring and no prompt, and the only way out
        -- of that is to try again. `remove` on a nil handle answers
        -- `poi_not_found` and is ignored, which is why retrying is safe.
        entry.description = nil
        Open77.log.error(("deathmatch: %s station card refresh failed: %s"):format(
            id, tostring(poiError)))
        return
    end
    entry.poi = poi.handle
    entry.description = definition.description
end


-- -------------------------------------------------------------- lifecycle ---
--
-- ONE edge drives the whole thing, and it is the ownership rule of note 4:
-- `participant` is the server's own word for "this player is in an instance".
-- True means the lobby's furniture belongs to a world they have left, and it
-- comes down; false means they are standing in the lobby and it goes back up.

-- Bumped on every lobby/instance transition. A build is scheduled rather than
-- run inline (see SETTLE below), so by the time it runs the player may already
-- have left; the token is what stops that build drawing lobby furniture into a
-- match bucket, which is the exact bug note 4 describes.
local generation = 0

-- The marker and prompt backends follow the STREAMED world, and a placement is
-- a kill -> respawn carrying a fade and a streaming preload. Creating a station
-- into a half-built scene is how pursuit learned to wait; it settles for two
-- seconds and so does this. The cost is that the rings appear a beat after the
-- fade lifts, which is also when the player can first see them.
local SETTLE_MS = 2000

RegisterNetEvent("deathmatch:state", function(payload)
    if type(payload) ~= "table" then return end
    lastState = payload

    local lobby = payload.participant ~= true
    if lobby ~= inLobby then
        inLobby = lobby
        generation = generation + 1
        local token = generation
        if not lobby then
            teardown()
            return
        end
        explained = false
        CreateThread(function()
            Wait(SETTLE_MS)
            -- Still in the lobby, and still THIS trip into it. `lastState` is
            -- read rather than the captured payload so the card is built from
            -- the freshest numbers rather than from two-second-old ones.
            if token ~= generation or not inLobby then return end
            build(lastState)
        end)
        return
    end

    if not built then return end
    for id in pairs(stations) do refresh(id, payload) end
end)

-- THE MARKS CAN MOVE NOW, and this client would never know.
--
-- `shared/kabuki.lua` is downloaded per client and read locally, so the two
-- station marks this file draws are whatever the resource SHIPPED with. The
-- live map editor (`server/mapstore.lua`) changes them on the server, and the
-- rings are the only way into the mode that is not a command -- so a station
-- the editor moved and this client never heard about is the mode's front door
-- pointing at somewhere nobody stands.
--
-- The server pushes on every apply and on every station capture; this handler
-- overwrites the local copy and redraws. `explained` is reset so a map that
-- fixes a missing station gets a fresh log line rather than inheriting the
-- silence of the one that did not have it.
RegisterNetEvent("deathmatch:mapStations", function(payload)
    if type(payload) ~= "table" then return end

    -- REVALIDATED, not trusted: this is server data, but a half-written mark
    -- ({ x = 1 }) drawn as a ring is a ring on the origin. `Kabuki.station`
    -- already rejects one; keeping the same shape here means it still can.
    local marks = {}
    for _, entry in ipairs(payload) do
        if type(entry) == "table" and type(entry.id) == "string" then
            marks[#marks + 1] = {
                id = entry.id,
                position = entry.position,
                heading = tonumber(entry.heading) or 0.0,
            }
        end
    end
    if #marks == 0 then return end

    Kabuki.stations = marks
    explained = false
    if inLobby then build(lastState) end
end)

-- A client that connects after a map was selected holds the SHIPPED marks and
-- has been told nothing, because the push happens on a change. One request at
-- load closes that window; the server answers with the active map's stations,
-- and a server with no map store simply never replies -- which leaves this
-- client on the shipped marks, the correct answer for that server.
CreateThread(function()
    Wait(SETTLE_MS)
    TriggerServerEvent("deathmatch:requestStations")
end)

-- `open77_zones` raises its enter/exit with `TriggerEvent`, which the host
-- queues onto EVERY running resource -- not just the one that called it. So
-- these are plain local handlers and deliberately NOT `RegisterNetEvent`: the
-- signal never crosses the wire, and treating it as a net event would be
-- claiming the server said something it never said.
for _, id in ipairs({ "enter", "queue" }) do
    AddEventHandler("deathmatch:stationNear:" .. id, function() nearby[id] = true end)
    AddEventHandler("deathmatch:stationFar:" .. id, function() nearby[id] = nil end)
end


-- ------------------------------------------------------------- the relay ---
--
-- THE ONE THING A READER OF `Config.stations` WILL GET WRONG.
--
-- Each descriptor carries `event = "deathmatch:stationEnter"`, and that is the
-- name of a SERVER net event -- `server/main.lua` registers it. It looks, from
-- the config alone, as though holding E reaches the server on its own. It does
-- not: `open77_interactions/client/main.lua:743` completes an interaction with
-- `TriggerEvent(event, payload)`, which is a LOCAL dispatch onto every running
-- client resource and never touches the wire. Without the two handlers below
-- the prompt would fill, click, and do nothing at all -- with no error anywhere,
-- because from the interaction service's point of view it worked.
--
-- So the names are kept identical on both sides on purpose. The descriptor
-- names the act; this is the one hop that carries it there.

local lastFireAt = {}
local REFIRE_GUARD_S = 1.0

local function relay(event)
    -- A hold that completes fires once, but a press does not have that
    -- protection and neither does a prompt recreated under a held key. One
    -- second is far below any legitimate repeat of either act and far above the
    -- window in which a double-fire could produce two joins.
    local now = Open77.time.monotonic()
    if now - (lastFireAt[event] or 0) < REFIRE_GUARD_S then return end
    lastFireAt[event] = now

    -- Refused from inside a match rather than sent and rejected. The stations
    -- are torn down on that edge, so reaching here means a stale prompt fired --
    -- and joining a fight you are already in is the one outcome nobody wants.
    if not inLobby then
        Open77.log.info("deathmatch: ignored a station fire from inside an instance")
        return
    end

    local sent, reason = TriggerServerEvent(event)
    if not sent then
        Open77.log.error(("deathmatch: %s not sent: %s"):format(event, tostring(reason)))
    end
end

AddEventHandler("deathmatch:stationEnter", function() relay("deathmatch:stationEnter") end)
AddEventHandler("deathmatch:stationQueue", function() relay("deathmatch:stationQueue") end)

AddEventHandler("onClientResourceStop", function(name)
    if name ~= GetCurrentResourceName() then return end
    -- A reload replaces this VM and the handles die with it, but a ring left
    -- behind by a resource that is gone is a marker with nothing to update it --
    -- the worst possible state for furniture a player is meant to trust.
    teardown()
    inLobby, lastState, explained = false, nil, false
end)

-- The stations are lobby furniture and the lobby is where a player lands, so
-- the first state push after `worldReady` builds them. Nothing is drawn before
-- one arrives: this side has no authoritative idea whether the player is in an
-- instance, and guessing "lobby" would put a ring in front of somebody who is
-- already fighting.
