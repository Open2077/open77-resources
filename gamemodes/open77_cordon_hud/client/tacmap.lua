-- The tactical map surface.
--
-- Plan section 4, layer 1: "the block grid, closed blocks hatched red, the next
-- closure flashing, squad positions, own position and heading, pings, the
-- supply drop. Schematic: labels and street lines from the survey, NO GAME MAP
-- TEXTURES -- redistributing game assets is forbidden."
--
-- That last clause is a hard constraint, not a style note (plan section 17:
-- "Game map textures are game assets"). Everything the map draws is either
-- survey data the server published (`cordon` and `map` in the state push) or a
-- shape this resource painted itself on a canvas. There is no image file in
-- this resource and there must never be one.
--
-- THE ONLY SURFACE THAT TAKES FOCUS. It has to: the map is clicked, to pin a
-- drop during deploy and to ping during the match. `webui.keep_input` is NOT
-- held by this resource, so while the map is up the player loses gameplay
-- input -- which is the correct trade for a full-screen map and is exactly what
-- plan section 10 specifies ("12, focused, `webui.keep_input` off"). It is also
-- why the map is hidden by default, why ESC closes it, and why it force-closes
-- itself the moment the deploy window ends: a map that trapped the player at
-- the drop would be indistinguishable from a hang.

CordonTacmap = {}

local page
local ready = false
local open = false
local openToken = 0
local awaitingRenderUntil = nil
local sentSurvey, sentBounds, sentFragment = nil, nil, nil
local strings = nil

-- The last state push, kept whole. The map re-renders from it on every tick
-- while it is open and not at all while it is shut -- a hidden CEF surface
-- still costs to repaint, and this one draws a canvas.
local state = nil

-- Set when the deploy phase opened the map by itself. Only an auto-opened map
-- closes itself; a map the player opened stays until they close it.
local autoOpened = false
local lastPhase = "unknown"

-- THE BLOCK LIST DOES NOT RIDE THE STATE PUSH, and that is a deliberate server
-- decision this surface has to honour. `open77_cordon/server/cordon.lua` says
-- why at `C.publish()`: "a 196-cell set at 2 Hz to 64 players is a needless
-- kilobyte a second each, and the client only needs it when it moves." So the
-- geometry is published on CHANGE over `cordon:bounds`, and the gamemode's own
-- client re-broadcasts it locally as `cordon:bounds:local` -- its comment names
-- this surface as the reason it bothers.
--
-- The two are therefore MERGED here rather than one replacing the other: the
-- 500 ms push carries the phase, the squad and the damage rate, and this carries
-- the cells. Neither is complete on its own and neither is ever re-derived.
local bounds = nil
local boundsReceivedMs = 0

-- THE SURVEY: landing zones, loot anchors, landmarks, supply points, the
-- final-block hint. It does not ride the state push either, and for a stronger
-- reason than the cell list: NONE OF IT CHANGES while a map is active. Twelve
-- landings, nine loot anchors, five landmarks and three supply points is a
-- couple of kilobytes, and sending it twice a second to sixty-four players
-- would be the most expensive constant in the mode.
--
-- Until 2026-09-02 nothing sent it AT ALL, which is why the overlay drew a bare
-- grid: it has read `map.landmarks` and `map.supply` since it was written and
-- the server had no `map` field. `open77_cordon` publishes `cordon:survey` on
-- join and at deploy, and its client re-broadcasts it here exactly as it does
-- for the bounds.
local survey = nil

-- The pin the player just clicked, held only until the server's own answer
-- arrives in the state push. It is drawn in a PENDING style, never as a
-- confirmed pin: the server snaps a click to the nearest surveyed landing zone,
-- so the point the player pressed is a request and not the outcome.
-- Rate limiter for map clicks; see the cordon:click handler.
local lastEditorAtMs
local lastClickAtMs

local pendingPin = nil
local PENDING_PIN_TTL_MS = 3000

-- Locally rendered pings, so a squadmate's ping appears the instant it arrives
-- rather than on the next 500 ms push.
local pings = {}
local PING_TTL_MS = 12000

local mapKey = nil

local function nowMs()
    return Open77.time.monotonic() * 1000
end

local function number(value, fallback)
    local n = tonumber(value)
    if n == nil or n ~= n then return fallback or 0 end
    return n
end

function CordonTacmap.keyLabel()
    return mapKey or CordonHudStrings.keys.unbound
end

function CordonTacmap.isOpen()
    return open
end

-- ---------------------------------------------------------------------------
-- Own position and heading
--
-- `Open77.character.state()` is ungated (docs/lua-resources.md lists
-- `Open77.character` with permission "None", and wiki/zones.md says so in as
-- many words), so this works on a manifest holding only network.events and
-- input.actions. It gives `position`, `forward` and `yaw` in one snapshot.
--
-- The heading drawn on the map is the CAMERA's, not the body's, when a camera
-- is readable: a player reading a map wants to know which way they are LOOKING.
-- `yaw` is the fallback, because a detached or scripted camera can disagree
-- with the body and the body is the thing that will walk.
-- ---------------------------------------------------------------------------

local function selfMarker()
    if Open77.character == nil or Open77.character.state == nil then return nil end
    local ok, snapshot = pcall(Open77.character.state)
    if not ok or type(snapshot) ~= "table" or type(snapshot.position) ~= "table" then
        return nil
    end

    local heading = nil
    if Open77.camera ~= nil and Open77.camera.view ~= nil then
        local okCamera, camera = pcall(Open77.camera.view)
        if okCamera and type(camera) == "table" and type(camera.forward) == "table" then
            local fx, fy = number(camera.forward.x), number(camera.forward.y)
            if (fx * fx + fy * fy) > 1e-6 then
                -- Bearing in map space: 0 is +Y (north on this projection),
                -- growing clockwise, which is what the canvas rotation wants.
                -- `math.atan(fx, fy)` is atan2(fx, fy), so a forward vector
                -- pointing east (+X) gives +90 and the marker turns right.
                heading = math.deg(math.atan(fx, fy))
            end
        end
    end
    -- THE YAW FALLBACK IS NEGATED, AND THAT IS NOT A TASTE.
    --
    -- The game's yaw runs 0 = +Y with 90 = -X -- it grows ANTI-clockwise seen
    -- from above, which `open77_cordonlab/server/main.lua` states at `lab.drops`
    -- and uses as `atan2(-dx, dy)` to turn a world delta into a heading. The
    -- canvas rotation grows clockwise, because canvas y grows downward. So a
    -- yaw handed straight to the page is MIRRORED: a player facing west was
    -- drawn facing east, and the marker still looked entirely plausible --
    -- it turned when the player turned, just the wrong way. That is the worst
    -- shape a bug can have on a map, because it is only discovered by a squad
    -- that has already run the wrong way.
    --
    -- The camera path above is unaffected: it is built from a vector, not from
    -- an engine angle, so it never went through this convention at all -- which
    -- is exactly why the error survived. The fallback only runs when the camera
    -- is unreadable, which is rare and is where nobody looked.
    if heading == nil and snapshot.yaw ~= nil then heading = -number(snapshot.yaw) end

    return {
        x = number(snapshot.position.x),
        y = number(snapshot.position.y),
        z = number(snapshot.position.z),
        heading = heading or 0,
        headingKnown = heading ~= nil,
    }
end

-- ---------------------------------------------------------------------------
-- Push
-- ---------------------------------------------------------------------------

local function livePings()
    local at = nowMs()
    local items = {}
    local index = 1
    while index <= #pings do
        local ping = pings[index]
        local age = at - ping.bornAt
        if age >= PING_TTL_MS then
            table.remove(pings, index)
        else
            items[#items + 1] = {
                x = ping.x,
                y = ping.y,
                by = ping.by,
                life = 1 - (age / PING_TTL_MS),
            }
            index = index + 1
        end
    end
    return items
end

-- What the map may be clicked for, decided from the phase the SERVER published.
-- `deploy` pins; `live` and `extraction` ping; everything else is read-only.
local function clickMode()
    local phase = state ~= nil and tostring(state.phase or "unknown") or "unknown"
    if phase == "deploy" then return "pin" end
    if phase == "live" or phase == "extraction" then return "ping" end
    return "none"
end

--- The cordon block the page draws from: the state push's fragment, overlaid
--- with whatever the last `cordon:bounds` carried. Written into a fresh table so
--- neither source is mutated -- `state` is the snapshot the other two surfaces
--- are reading at the same moment.
local function cordonView()
    local fragment = state ~= nil and type(state.cordon) == "table" and state.cordon or nil
    if fragment == nil and bounds == nil then return nil end
    local merged = {}
    if fragment ~= nil then
        for key, value in pairs(fragment) do merged[key] = value end
    end
    if bounds ~= nil then
        for key, value in pairs(bounds) do merged[key] = value end
        if type(bounds.sweep) == "table" then
            merged.sweepElapsedMs = math.max(0, nowMs() - boundsReceivedMs)
        end
    end
    return merged
end

--- The confirmed pin, from the state push, and the unconfirmed one the player
--- just clicked. Both are sent; the page draws the confirmed one as a pin and
--- the pending one as a request, and drops the request the moment a confirmed
--- pin arrives at the same place.
local function pinView()
    local confirmed = nil
    if state ~= nil and type(state.self) == "table" and type(state.self.pin) == "table" then
        confirmed = state.self.pin
    end
    if pendingPin ~= nil then
        -- Two ways a request is over, and both have to be checked because the
        -- push carries no timestamp to compare against.
        --
        --   * the server's pin MOVED from whatever it was when the click left.
        --     That answer is this click's, so the request has been honoured;
        --   * the deadline passed. The click was refused, or lost, and a mark
        --     that never resolves is worse than no mark -- it would sit on the
        --     map claiming a pin the squad does not have.
        local answered = false
        if confirmed ~= nil then
            answered = number(confirmed.x) ~= pendingPin.wasX
                or number(confirmed.y) ~= pendingPin.wasY
        end
        if answered or (nowMs() - pendingPin.bornAt) >= PENDING_PIN_TTL_MS then
            pendingPin = nil
        end
    end
    return confirmed, pendingPin
end

local function push()
    if page == nil or not ready or not open then return end
    local pin, pending = pinView()
    local function checkedSend(event, payload)
        local ok, reason = page:send(event, payload)
        if ok == false then
            CordonTacmap.setOpen(false)
            error("cordon tacmap: " .. event .. " refused: " .. tostring(reason))
        end
    end
    -- Survey and geometry each already fit a network event. Combining both
    -- with the roster crossed the WebUI serializer's 1024 key/value-node limit.
    -- Keep their lifetimes separate and send only changes, before dynamic state.
    local fragment = state and state.cordon or nil
    if survey ~= sentSurvey then
        checkedSend("cordon:map:survey", survey or {})
        sentSurvey = survey
    end
    if bounds ~= sentBounds or fragment ~= sentFragment then
        checkedSend("cordon:map:bounds", cordonView() or {})
        sentBounds, sentFragment = bounds, fragment
    end
    checkedSend("cordon:map", {
        openToken = openToken,
        phase = state ~= nil and tostring(state.phase or "unknown") or "unknown",
        participant = state ~= nil and state.participant == true,
        format = state ~= nil and state.format or nil,
        remainingMs = state ~= nil and number(state.remainingMs) or 0,
        sweepElapsedMs = bounds and math.max(0, nowMs() - boundsReceivedMs) or 0,
        squad = state ~= nil and state.squad or nil,
        pin = pin,
        pendingPin = pending,
        marker = selfMarker(),
        pings = livePings(),
        mode = clickMode(),
        keyClose = CordonHudStrings.keys.close,
        keyToggle = mapKey,
    })
end

-- ---------------------------------------------------------------------------
-- Open / close
-- ---------------------------------------------------------------------------

function CordonTacmap.setOpen(value, auto)
    value = value == true
    if value and CordonHud and CordonHud.canPresent and not CordonHud.canPresent() then value = false end
    if page == nil then return end
    if not value then
        openToken = openToken + 1
        open, autoOpened, awaitingRenderUntil = false, false, nil
        pcall(page.setFocus, page, false, false)
        pcall(page.hide, page)
        if CordonHud and CordonHud.refreshPresentation then CordonHud.refreshPresentation() end
        return
    end
    if not ready then
        Open77.log.warn("cordon tacmap: application not ready; input remains available")
        return
    end
    if open then return end
    openToken = openToken + 1
    open, autoOpened = true, auto == true
    awaitingRenderUntil = nowMs() + 2000
    if CordonHud and CordonHud.refreshPresentation then CordonHud.refreshPresentation() end
    Open77.log.info("cordon tacmap: opening token=" .. tostring(openToken))
    -- Reserve keyboard input synchronously so the physical M press cannot also
    -- open the native map while this 6 fps page paints. Cursor capture waits for
    -- the render acknowledgement; the two-second watchdog releases both on failure.
    local ok, result = pcall(page.show, page)
    if ok and result ~= false then
        local focused
        ok, focused = pcall(page.setFocus, page, true, false)
        if not ok or not focused then
            CordonTacmap.setOpen(false)
            Open77.log.warn("cordon tacmap: keyboard reservation refused; input released")
            return
        end
        local sendError
        ok, sendError = pcall(function()
            if survey == nil then TriggerEvent("cordon:survey:request") end
            push()
        end)
        if not ok then Open77.log.warn(tostring(sendError)) end
    end
    if not ok or result == false then
        CordonTacmap.setOpen(false)
        Open77.log.warn("cordon tacmap: opening failed; gameplay input released")
    end
end

function CordonTacmap.toggle()
    CordonTacmap.setOpen(not open, false)
end

-- A local event so the gamemode's own client -- or a deployment that stripped
-- `input.actions` -- can still drive the map.
AddEventHandler("cordon:tacmap:toggle", function()
    CordonTacmap.toggle()
end)

-- ESC. The platform raises this for the pause key; a full-screen map that only
-- closed on its own key would be one more thing to learn.
AddEventHandler("open77:pauseKey", function()
    if open then CordonTacmap.setOpen(false) end
end)

-- The cordon geometry, re-broadcast locally by the gamemode's client. Stored
-- and merged; never interpreted. Which blocks are open is the server's answer
-- and a second opinion here would be a second bug.
AddEventHandler("cordon:bounds:local", function(payload)
    if type(payload) ~= "table" then return end
    local incoming = type(payload.sweep) == "table" and payload.sweep or nil
    local previous = bounds and type(bounds.sweep) == "table" and bounds.sweep or nil
    if incoming and previous then
        if number(incoming.generation) < number(previous.generation) then return end
        if incoming.generation == previous.generation
            and number(incoming.revision) < number(previous.revision) then return end
    end
    bounds = payload
    boundsReceivedMs = nowMs()
    push()
end)

-- The survey, by the same route and for the same reason. Stored whole and never
-- merged with the cordon fragment: one is the map, the other is what the cordon
-- has done to it, and conflating them is how a landing zone would inherit a
-- block's state.
AddEventHandler("cordon:survey:local", function(payload)
    if type(payload) ~= "table" then return end
    survey = payload
    push()
end)

-- Pings arriving from the squad. Rendered locally on receipt AND carried in the
-- next state push if the server chooses to publish them; either route paints
-- the same marker, and neither is required for the other to work.
local function addPing(x, y, by)
    pings[#pings + 1] = {
        x = number(x),
        y = number(y),
        by = by ~= nil and tostring(by) or nil,
        bornAt = nowMs(),
    }
    while #pings > 8 do table.remove(pings, 1) end
    push()
end

RegisterNetEvent("cordon:ping", function(payload)
    if type(payload) ~= "table" then return end
    addPing(payload.x, payload.y, payload.name)
end)

-- AND THE CHANNEL THE SERVER ACTUALLY USES. `squads.lua` announces a ping
-- through `S.notifySquad`, which sends `cordon:squad` with
-- `{ kind = "ping", fields = { x, y, by } }` -- not `cordon:ping` above, which
-- nothing has ever triggered. So a squadmate's ping reached this client and was
-- dropped, and the PING entry in the legend named a mark the map could not
-- draw. Both are handled rather than one being deleted: the server is free to
-- use either, and a ping is cheap enough that hearing it twice would only
-- refresh the same mark.
RegisterNetEvent("cordon:squad", function(payload)
    if type(payload) ~= "table" then return end
    if tostring(payload.kind) ~= "ping" then return end
    local fields = type(payload.fields) == "table" and payload.fields or {}
    addPing(fields.x, fields.y, fields.by)
end)

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

function CordonTacmap.onState(next_)
    if type(next_) ~= "table" then return end
    state = next_
    if CordonHud and CordonHud.canPresent and not CordonHud.canPresent() then
        lastPhase = nil
        if open then CordonTacmap.setOpen(false) end
        return
    end
    local phase = tostring(next_.phase or "unknown")

    if phase ~= lastPhase then
        -- The deploy window IS the map: plan section 2, "-0:45 Deploy -- the
        -- tac-map opens." Opening it for the player is the difference between a
        -- pin they chose and a pin they missed.
        if phase == "deploy" and next_.participant == true then
            CordonTacmap.setOpen(true, true)
        elseif lastPhase == "deploy" and autoOpened then
            -- And it force-closes when the window ends, even though a
            -- player-opened map would not: the drop happens with or without a
            -- pin, and a player still reading a map while their squad lands is
            -- a player who cannot see the ground.
            CordonTacmap.setOpen(false)
        end
        lastPhase = phase
    end

    push()
end

-- ---------------------------------------------------------------------------
-- Attach
-- ---------------------------------------------------------------------------

local function registerMapKey()
    if type(RegisterKeyMapping) ~= "function" then
        Open77.log.warn("cordon HUD: RegisterKeyMapping unavailable, tac-map is event-only")
        return
    end
    local ok, effective = RegisterKeyMapping({
        id = "cordon.tacmap",
        name = "Cordon - Tactical map",
        key = CordonHudStrings.keys.tacmap,
        onPressed = function() CordonTacmap.toggle() end,
    })
    if ok then
        -- The EFFECTIVE key: the player may have rebound it in
        -- Pause > Settings > KEY BINDINGS, and every hint on this HUD that
        -- names a key names this value rather than the default above.
        mapKey = tostring(effective)
    else
        Open77.log.warn("cordon HUD: tac-map key refused (" .. tostring(effective)
            .. ") -- check the input.actions permission")
    end
end

AddEventHandler("open77:keybinds:changed", function()
    if Open77.input ~= nil and Open77.input.keyFor ~= nil then
        local ok, key = pcall(Open77.input.keyFor, "cordon.tacmap")
        if ok and type(key) == "string" and #key > 0 then mapKey = key end
    end
end)

local function blockNativeMap(blocked)
    local setBlocked = Open77.input and Open77.input.setNativeActionBlocked
    if type(setBlocked) ~= "function" then
        if blocked then Open77.log.warn("cordon tacmap: native map suppression unavailable on this client") end
        return
    end
    local called, accepted, reason = pcall(setBlocked, "OpenMapMenu", blocked)
    if not called or accepted ~= true then
        Open77.log.warn("cordon tacmap: native map suppression failed: " .. tostring(called and reason or accepted))
    end
end

function CordonTacmap.attach(target, table_)
    blockNativeMap(true)
    page = target
    strings = table_
    ready = false
    sentSurvey, sentBounds, sentFragment = nil, nil, nil

    page:on("cordon:ready", function()
        ready = true
        page:send("cordon:strings", strings)
        if state and state.phase == "deploy" and state.participant == true then
            CordonTacmap.setOpen(true, true)
        end
        push()
    end)

    page:on("cordon:map:received", function(payload)
        if type(payload) ~= "table" then return end
        Open77.log.info(("cordon tacmap: page received token=%s current=%s open=%s hidden=%s canvas=%sx%s"):format(
            tostring(payload.openToken), tostring(openToken), tostring(open), tostring(payload.hidden),
            tostring(payload.canvasWidth), tostring(payload.canvasHeight)))
    end)

    page:on("cordon:rendered", function(payload)
        if not open or awaitingRenderUntil == nil or type(payload) ~= "table"
            or payload.openToken ~= openToken then return end
        if nowMs() >= awaitingRenderUntil then CordonTacmap.setOpen(false); return end
        local ok, focused = pcall(page.setFocus, page, true, true)
        if not ok or not focused then
            CordonTacmap.setOpen(false)
            Open77.log.warn("cordon tacmap: focus refused; input released")
            return
        end
        awaitingRenderUntil = nil
        Open77.log.info("cordon tacmap: rendered opening acknowledged, input focused")
    end)

    -- THE MAP EDITOR'S ONE WAY OUT, and it is deliberately the dullest path
    -- available: the page hands over the tokens of a `/br.map` command and this
    -- submits them exactly as the chat box would.
    --
    -- WHY NOT A NET EVENT OF ITS OWN. `RegisterCommand`'s third argument is the
    -- ONLY permission gate a server resource has -- nothing in the Lua surface
    -- lets a resource ask whether a caller is an admin -- so a bespoke
    -- `cordon:editor` net event would have been an unauthenticated way into the
    -- editor for every player on the server. `open77:command:execute` is the
    -- platform's own command route (open77_chat/client/main.lua sends exactly
    -- this), so a non-admin pressing the buttons is refused by the same gate
    -- that refuses them typing it. The panel is visible to everyone and useful
    -- to nobody who lacks the right, which is the honest failure.
    --
    -- Nothing is validated here beyond shape. A second opinion about which
    -- verbs exist or which map is loaded is a second bug; the server owns both.
    page:on("cordon:editor", function(payload)
        if type(payload) ~= "table" or type(payload.tokens) ~= "table" then return end
        local tokens, count = {}, 0
        for index = 1, 12 do
            local token = payload.tokens[index]
            if token == nil then break end
            if type(token) ~= "string" and type(token) ~= "number" then return end
            local text = tostring(token)
            -- A token longer than this is not a map name or a tier, it is
            -- someone probing the command line.
            if #text > 96 then return end
            count = count + 1
            tokens[count] = text
        end
        if count == 0 or tokens[1] ~= "br.map" then return end

        -- The same disconnect guard the click path carries, for the same
        -- reason: the server drops a session over thirty-two events a second
        -- and a button is easier to hold down than a map click. The page
        -- rate-limits too; this is the half that cannot be edited by the page.
        local now = nowMs()
        if lastEditorAtMs ~= nil and (now - lastEditorAtMs) < 600 then return end
        lastEditorAtMs = now

        Open77.log.info(("cordon tacmap: editor %s"):format(table.concat(tokens, " ")))
        local accepted, reason = TriggerServerEvent("open77:command:execute", table.unpack(tokens))
        if not accepted then
            page:send("cordon:editor:reply", { text = tostring(reason or "refused") })
        end
    end)

    -- THE SERVER'S OWN ANSWER, mirrored into the panel.
    --
    -- `editor.lua` replies with `open77:command:result` carrying the raw
    -- command, an ok flag and one line of text -- the same event the chat box
    -- prints. Listening for it here means the operator reads the outcome beside
    -- the button they pressed instead of hunting for it in the chat log, and it
    -- costs nothing: the event is already being sent.
    --
    -- FILTERED TO `br.map`, because this panel has no business narrating
    -- somebody's `/tpc`. The text is shown VERBATIM -- a refusal is the useful
    -- half and rewording it here would be a second account of what happened.
    AddEventHandler("open77:command:result", function(raw, ok, text)
        if page == nil then return end
        local command = tostring(raw or "")
        if command:find("br.map", 1, true) == nil then return end
        page:send("cordon:editor:reply", {
            text = tostring(text or ""),
            ok = ok == true,
        })
    end)

    page:on("cordon:close", function()
        CordonTacmap.setOpen(false)
    end)

    -- The one place a player action leaves this surface. The page sends a BLOCK
    -- and a WORLD POINT; the server validates both and owns the outcome. It is
    -- forwarded verbatim and never checked against a local copy of the grid,
    -- because a second opinion about which blocks are open is a second bug.
    page:on("cordon:click", function(payload)
        if type(payload) ~= "table" then return end
        local mode = clickMode()
        local x, y = tonumber(payload.x), tonumber(payload.y)
        if x == nil or y == nil then return end

        -- ONE CLICK PER COOLDOWN, and this is a disconnect guard rather than a
        -- nicety.
        --
        -- Every click here sends a net event, and the server drops a session
        -- that sends more than THIRTY-TWO in one second
        -- (SessionManager.cs, "network_event_rate_limit"). Nothing stopped a
        -- player holding the mouse down or clicking fast, so the map was a way
        -- to kick yourself out of the match -- and the owner hit exactly that
        -- on 2026-09-02, reporting "i can click an infinite amount of times"
        -- and "its just adding circle everywhere" after the same guard had
        -- already disconnected them once through a different resource.
        --
        -- The cooldown is deliberately shorter for a pin than a ping: changing
        -- your mind about where to drop is normal and the server keeps only the
        -- latest, while a ping paints a marker for the whole squad and is the
        -- one a player can spam at other people.
        local cooldown = mode == "pin" and 250 or 700
        local now = nowMs()
        if lastClickAtMs ~= nil and (now - lastClickAtMs) < cooldown then return end
        lastClickAtMs = now
        -- ONE LINE PER CLICK, at info, and it earns its place. A click on this
        -- map crosses a canvas, a CEF query, the WebUI bridge, this VM and a net
        -- event before anything visible happens, and when the owner reported
        -- "the click isn't working" there was no way to tell which of those five
        -- had dropped it. Clicks are a handful per match; the log line is the
        -- cheapest possible answer to that question.
        Open77.log.info(("cordon tacmap: click mode=%s at %.1f,%.1f (block %s,%s)"):format(
            mode, x, y, tostring(payload.col), tostring(payload.row)))
        if mode == "pin" then
            TriggerServerEvent("cordon:pin", x, y)
            -- Painted at once, in a PENDING style, for the same reason the ping
            -- below is: a click with no mark until the next 500 ms push reads as
            -- a click that did nothing. It is not drawn as a confirmed pin --
            -- the server snaps to the nearest surveyed landing zone and may
            -- refuse outright -- and it clears itself either way.
            local confirmed = state ~= nil and type(state.self) == "table"
                and type(state.self.pin) == "table" and state.self.pin or nil
            pendingPin = {
                x = x, y = y,
                bornAt = nowMs(),
                wasX = confirmed ~= nil and number(confirmed.x) or nil,
                wasY = confirmed ~= nil and number(confirmed.y) or nil,
            }
        elseif mode == "ping" then
            TriggerServerEvent("cordon:ping", x, y)
            -- Painted locally at once. The server will confirm it to the whole
            -- squad; showing the player their own ping immediately is what makes
            -- the click feel like it landed.
            pings[#pings + 1] = { x = x, y = y, bornAt = nowMs(), by = nil }
            while #pings > 8 do table.remove(pings, 1) end
        end
        push()
    end)

    registerMapKey()
    -- Ask once at attach as well as at open, so the very first deploy window
    -- does not have to wait for its own publish.
    TriggerEvent("cordon:survey:request")

    CreateThread(function()
        while page ~= nil do
            -- Only while open. A closed canvas surface repaints nothing and
            -- costs nothing, and the own-position read is the one thing here
            -- that touches the engine every tick.
            if open then
                if awaitingRenderUntil and nowMs() >= awaitingRenderUntil then
                    CordonTacmap.setOpen(false)
                    Open77.log.warn("cordon tacmap: render acknowledgement timed out; input released")
                else
                    local ok, reason = pcall(push)
                    if not ok then
                        Open77.log.warn(tostring(reason))
                        CordonTacmap.setOpen(false)
                    end
                end
            end
            -- 10 Hz. The player marker interpolates across the gap in CSS; a
            -- map is read, not aimed.
            Wait(100)
        end
    end)
end

function CordonTacmap.detach()
    blockNativeMap(false)
    if page ~= nil then CordonTacmap.setOpen(false) end
    page, state, strings = nil, nil, nil
    ready, open, autoOpened = false, false, false
    lastPhase = "unknown"
    bounds = nil
    survey = nil
    pendingPin = nil
    pings = {}
    if type(Open77.input) == "table" and Open77.input.unregisterKeyMapping ~= nil then
        pcall(Open77.input.unregisterKeyMapping, "cordon.tacmap")
    end
end
