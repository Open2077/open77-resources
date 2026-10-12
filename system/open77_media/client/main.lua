-- =============================================================================
-- open77_media -- client/main.lua
-- =============================================================================
-- Turns "there is a television at this position, showing this URL" into pixels
-- on that television's screen, for the televisions close enough to matter.
--
-- -----------------------------------------------------------------------------
-- WHY ONLY THE NEAR ONES
-- -----------------------------------------------------------------------------
-- A screen is one CEF surface, and a resource may hold eight
-- (`kMaximumWebSurfaces`). A server may hold sixty-four televisions. So the
-- client must pick, and it is the only party that can: it is the only one that
-- knows where the player is standing.
--
-- The selection runs on a one-second thread. That is deliberate and it is the
-- opposite of the rule this project applies everywhere else -- the rule is that
-- anything whose *smoothness* the player sees must not be on a Lua tick, and
-- materialising a page is not smooth: it is a decision about whether a browser
-- exists, and a second is far below the time it takes to walk into range of a
-- screen. Nothing positional goes through Lua. The screen's rectangle and its
-- screen position are projected natively every game frame by `Api::MediaScreens`;
-- this file only decides which screens exist.
--
-- -----------------------------------------------------------------------------
-- NO TICK FOR ANYTHING ELSE
-- -----------------------------------------------------------------------------
-- A snapshot arrives whole, so binding and unbinding happen when it arrives.
-- There is no polling of server state, no per-frame work, and no accumulation:
-- `screens` is exactly the set the server last sent.

-- A client can receive a newer resource generation before its native plugin has
-- been restarted. Stay inert on that transition rather than failing the VM on
-- every screen.
if type(Open77.media) ~= "table"
    or type(Open77.media.bind) ~= "function"
    or type(Open77.media.unbind) ~= "function" then
    print("[open77_media] native media API unavailable; restart Cyberpunk to activate it")
    return
end

-- How many screens may be materialised at once, and how far away a screen may be
-- to be considered. Six, under the eight-surface ceiling, so the resource never
-- spends its last two surfaces on televisions and has none left for anything
-- else it might want. The radius is generous because a screen is legible long
-- before it is close; the count is what actually binds.
local MAX_MATERIALISED = 6
local MATERIALISE_RADIUS = 90.0

-- Above this, the surface is created at a lower frame rate. A distant screen
-- showing a menu is not worth 30 fps of a compositor this process shares with
-- the game, and the page has no animation that matters at that size.
local NEAR_DISTANCE = 25.0

-- mediaId -> { spec = <server payload>, page = <WebUI page or nil>,
--              native = <screen id string or nil>, materialised = bool }
local screens = {}
local state = { version = 0 }

---How far away a screen is, or nil when the body cannot be read.
---
---`Open77.character.position()` returns THREE NUMBERS, not a table: the native
---pushes x, y and z as three returns (`scripting/src/ResourceHost.cpp`,
---`LuaCharacterPosition`), which is how `open77_cordon` reads it --
---`local x, y, z = Open77.character.position()`.
---
---This function used to bind only the first return (`local character = ...`) and
---then index `.x` on it, so `character` was a number and every call threw
---`attempt to index a number value`. That call is the first thing the one-second
---selection thread does for every screen, so `reselect` never completed:
---no page was ever created, no surface was ever bound, and a spawned television
---showed its cabinet and nothing else. It was written to the log once a second
---(`materialisation failed: ... attempt to index a number value`), while the
---server and the prop registry both reported success -- the set existed, it just
---never drew.
local function distanceTo(position)
    if type(position) ~= "table" then return nil end
    local x, y, z = Open77.character.position()
    if x == nil or y == nil or z == nil then return nil end
    local dx = (tonumber(position.x) or 0.0) - x
    local dy = (tonumber(position.y) or 0.0) - y
    local dz = (tonumber(position.z) or 0.0) - z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

---What the page is told. The page owns no state of its own: everything it shows
---came from the server through here, so two clients watching the same television
---cannot disagree about what is playing.
local function pageState(entry)
    return {
        id = entry.spec.id,
        label = entry.spec.label,
        url = entry.spec.url,
        volume = entry.spec.volume,
        muted = entry.spec.muted,
        paused = entry.spec.paused,
        border = entry.spec.border,
        curtain = entry.spec.curtain or "open",
    }
end

-- -----------------------------------------------------------------------------
-- The reveal: the race start's own effect, at this panel
-- -----------------------------------------------------------------------------
-- `race.firework.burst` with two `race.flare.smoke` columns is what the freeroam
-- race resource plays on the start line -- `freeroam/race/shared/config.lua`
-- `presentation.startVfx` -- and the two sounds are the race's own countdown
-- beats (`DeathmatchConfig.sfx.tick` / `.start`, `sq024_race_countdown` and
-- `sq024_race_start`). A film reveal wants exactly that and nothing new, so this
-- reuses it rather than drawing a second celebration.
--
-- The CLOCK is the page's. It draws the curtain and counts 3-2-1 on the panel and
-- reports each beat; this half plays the game-side effect for the beat it hears.
-- The alternative -- firing the effects from the snapshot transition -- would put
-- the explosions on a different clock from the numbers, and would leave a client
-- that joined mid-countdown watching a silent reveal.
local REVEAL_VFX = {
    -- lateral/forward/z are QUAD-relative, not metres from the prop origin: the
    -- panel's own rectangle is what the effect has to line up with, and the
    -- rectangle is in the prop's local frame (see `panelStage`).
    { effect = "race.flare.smoke", lateral = -0.85, forward = 2.0, z = -0.45, duration = 8.0 },
    { effect = "race.flare.smoke", lateral = 0.85, forward = 2.0, z = -0.45, duration = 8.0 },
    { effect = "race.firework.burst", lateral = 0.0, forward = 6.0, z = 0.15, duration = 7.5 },
}

---Where the panel is, in world space, and which way it looks.
---
---The prop's origin is not the panel: the record's quad carries its own offset,
---and for the cinema records that offset is a hundred feet of panel above the
---origin. So the effects are placed against the rectangle -- its centre, its
---width and its heading -- rather than against the prop.
---@return table|nil
local function panelStage(entry)
    local spec = entry.spec or {}
    local position = spec.position
    local quad = spec.quad
    if type(position) ~= "table" or type(quad) ~= "table" then return nil end
    local offset = type(quad.offset) == "table" and quad.offset or {}
    return {
        position = position,
        yaw = math.rad(tonumber(spec.yaw) or 0.0),
        -- The quad's own offset in the prop's frame: { right, forward, up }.
        forward = tonumber(offset[2]) or 0.0,
        up = tonumber(offset[3]) or 0.0,
        width = tonumber(quad.width) or 0.0,
        height = tonumber(quad.height) or 0.0,
    }
end

---One effect's transform, in the shape `Open77.vfx.play` reads. The arithmetic
---is the race resource's own (`startTransform`), with the panel's rectangle in
---place of a course's start line.
local function placementTransform(stage, placement)
    if stage == nil then return nil end
    local halfWidth = stage.width * 0.5
    local forwardX, forwardY = -math.sin(stage.yaw), math.cos(stage.yaw)
    local rightX, rightY = math.cos(stage.yaw), math.sin(stage.yaw)
    local forward = stage.forward + (tonumber(placement.forward) or 0.0)
    local lateral = (tonumber(placement.lateral) or 0.0) * halfWidth
    local halfYaw = stage.yaw * 0.5
    return {
        position = {
            x = stage.position.x + forwardX * forward + rightX * lateral,
            y = stage.position.y + forwardY * forward + rightY * lateral,
            z = stage.position.z + stage.up + (tonumber(placement.z) or 0.0) * stage.height,
        },
        orientation = { x = 0.0, y = 0.0, z = math.sin(halfYaw), w = math.cos(halfYaw) },
        duration = tonumber(placement.duration) or 5.0,
        ignoreTimeDilation = true,
    }
end

local function playRevealCue(event)
    if type(Open77.sfx) ~= "table" or type(Open77.sfx.play) ~= "function" then return end
    local handle, reason = Open77.sfx.play(event, { unique = true, duration = 3.0 })
    if handle == nil then
        print(string.format("[open77_media] reveal sound %s failed: %s", event, tostring(reason)))
    end
end

local function playRevealVfx(entry)
    if type(Open77.vfx) ~= "table" or type(Open77.vfx.play) ~= "function" then return end
    local stage = panelStage(entry)
    if stage == nil then return end
    for _, placement in ipairs(REVEAL_VFX) do
        local transform = placementTransform(stage, placement)
        if transform ~= nil then
            local handle, reason = Open77.vfx.play(placement.effect, transform)
            if handle == nil then
                print(string.format("[open77_media] reveal effect %s failed: %s",
                    placement.effect, tostring(reason)))
            end
        end
    end
end

---The surface a screen rectangle maps onto, as something comparable.
---
---Used to notice a rectangle that was retuned under a screen that is already
---materialised: the surface is sized from the rectangle, so `media.quad` moving a
---screen from 16:9 to 21:9 changes the surface, and one mapped onto the old one
---would show the new rectangle's picture stretched.
local function surfaceSignature(quad)
    local width, height = Open77MediaSurfaceFor(quad)
    return width .. "x" .. height
end

---One vector in the shape the native reads, from whichever shape arrives.
---
---`ReadVector3` (`scripting/src/ResourceHost.cpp`) accepts ONE shape: a table
---with named x/y/z fields. The catalogue and the server's `copyQuad` both build
---positional arrays -- `offset = { 0.0, 0.115394, 0.42 }` -- which is the shape a
---reader of `records.lua` wants and the shape `media.quad` prints back for
---pasting. Passing one straight to `bind` is what produced, once a second for
---every screen:
---
---    television 1: bind failed: invalid_offset
---
---with the prop spawned, the page created, and nothing on the screen. Converting
---here keeps a single shape in the data files -- the one the console prints and
---the docs quote -- and a single shape at the native boundary, which is the one
---the native reads. Both are accepted on input so a record written either way
---works.
local function nativeVector(value)
    if type(value) ~= "table" then return nil end
    local x = tonumber(value.x) or tonumber(value[1])
    local y = tonumber(value.y) or tonumber(value[2])
    local z = tonumber(value.z) or tonumber(value[3])
    if x == nil or y == nil or z == nil then return nil end
    return { x = x, y = y, z = z }
end

---The rectangle in the shape the native reads.
---
---Nil when a vector is missing or unreadable, which the native would refuse too
----- but with `invalid_offset`, an error that names the field rather than the
---record or the television it came from. Naming the set is the difference
---between "some records are broken" and "this record's quad is".
local function nativeQuad(quad)
    if type(quad) ~= "table" then return nil end
    local offset = nativeVector(quad.offset)
    local right = nativeVector(quad.right)
    local up = nativeVector(quad.up)
    if offset == nil or right == nil or up == nil then return nil end
    return {
        offset = offset,
        right = right,
        up = up,
        width = tonumber(quad.width),
        height = tonumber(quad.height),
    }
end

local function destroyPage(entry)
    if entry.native ~= nil then
        Open77.media.unbind(entry.native)
        entry.native = nil
    end
    if entry.page ~= nil then
        entry.page:destroy()
        entry.page = nil
    end
    entry.materialised = false
end

---Creates the page and binds it to the television's prop.
---
---Order matters: the page must be created before it is bound, because the
---binding names it, and the binding is by *page handle* rather than by surface
---id so the native side can refuse a screen pointing at another resource's page.
local function materialisePage(entry)
    if entry.materialised then return true end

    local near = entry.distance ~= nil and entry.distance <= NEAR_DISTANCE
    -- The surface is created at the rectangle's own aspect rather than at a fixed
    -- 1280x720. The page is mapped 1:1 onto the quad with UVs 0..1, so a surface
    -- of the wrong shape stretches every pixel on it -- and the catalogue's screens
    -- are genuinely 21:9, 4:3, 9:16, 2:1 and square. `Open77MediaSurfaceFor` is in
    -- `shared/records.lua` and takes the rectangle off the wire, so a quad retuned
    -- in game is mapped onto a surface of the same shape.
    local surfaceWidth, surfaceHeight = Open77MediaSurfaceFor(entry.spec.quad)
    local page, reason = WebUI.create({
        entry = "web/tv.html",
        layer = "hud",
        width = surfaceWidth,
        height = surfaceHeight,
        -- A television does not need the compositor's full rate. The screen is
        -- mapped 1:1 onto the quad and most of what it shows is static.
        fps = near and 30 or 15,
        transparent = false,
        visible = true,
        -- The whole reason a television does not also paint itself across the
        -- player's viewport: `Draw` skips a hud-suppressed surface and
        -- `DrawSurfaceQuad` composites it into the world quad instead.
        hudSuppressed = true,
        -- The one page in Open77 that is allowed to reach the network.
        --
        -- Every resource page is served under a strict same-origin policy, and
        -- that policy is what killed playback: `script-src 'self'` refused
        -- YouTube's IFrame API and `frame-src 'none'` then refused the bare
        -- embed the fallback built, so the screen sat on the page's own idle
        -- colour bars and the log said only "the player script refused to
        -- load". A page cannot report a header it never sees, so the fix is to
        -- ask for the policy by name and let the client decide the directives --
        -- see `webui/include/op77/WebUI/PagePolicy.hpp`. Nothing else in the
        -- catalogue changes: this is the only surface that asks.
        policy = "media",
    })
    if page == nil then
        print(string.format(
            "[open77_media] television %s: WebUI.create failed: %s",
            tostring(entry.spec.id), tostring(reason)))
        return false
    end

    local id, bindError = Open77.media.bind({
        prop = entry.spec.prop,
        page = page,
        label = entry.spec.label,
        -- Converted, not passed through: see `nativeQuad`. The catalogue's
        -- rectangle is positional and the native's is named.
        quad = nativeQuad(entry.spec.quad),
    })
    if id == nil then
        print(string.format(
            "[open77_media] television %s: bind failed: %s (record=%s quad=%s)",
            tostring(entry.spec.id), tostring(bindError), tostring(entry.spec.record),
            nativeQuad(entry.spec.quad) == nil and "unreadable" or "ok"))
        page:destroy()
        return false
    end

    entry.page = page
    entry.native = id
    entry.materialised = true

    -- The client-side proof that a screen exists, and the line this feature did
    -- not have while it was failing: every set the server reported as created
    -- was accepted, and nothing anywhere said the page had never been made. One
    -- line per materialisation -- which happens when a set comes into range, not
    -- per frame -- so "the picture is on the wall" is answerable from the log
    -- without a screenshot.
    print(string.format(
        "[open77_media] television %s: screen bound (prop=%s, %dx%d px, %.1f m away)",
        tostring(entry.spec.id), tostring(entry.spec.prop), surfaceWidth, surfaceHeight,
        entry.distance or -1.0))

    -- The page announces itself once its document is live, and the state is sent
    -- then rather than now: `page:send` before the page has run its script is
    -- delivered to nothing. A second send on every later change is the same
    -- path, so there is one route for state and not two.
    page:on("media:ready", function()
        page:send("media:state", pageState(entry))
    end)

    page:on("media:report", function(payload)
        if type(payload) ~= "table" then return end
        -- Only ever logged. The page's own opinion of what it is doing must
        -- never become state: the server is the only writer of a television's
        -- content, so a page that claims a different URL is reporting a bug.
        print(string.format("[open77_media] television %s: %s%s",
            tostring(entry.spec.id), tostring(payload.status),
            payload.detail ~= nil and (" (" .. tostring(payload.detail) .. ")") or ""))
        -- The page's reveal beats, played in the world. The countdown is the
        -- page's clock and the sound is the race's own; the colours go up on the
        -- beat the page calls a start.
        if payload.status == "reveal_tick" then
            playRevealCue("sq024_race_countdown")
        elseif payload.status == "reveal_start" then
            playRevealCue("sq024_race_start")
            playRevealVfx(entry)
        end
    end)

    -- The page's curtain button. Same path as its URL bar and its volume keys:
    -- the request goes to the server, so the curtain every client sees is the one
    -- the server holds.
    page:on("media:curtain", function(payload)
        if type(payload) ~= "table" or type(payload.curtain) ~= "string" then return end
        TriggerServerEvent("open77:media:control", "curtain",
            { id = entry.spec.id, value = payload.curtain })
    end)

    -- The page's URL bar, when someone is driving the television on foot. It goes
    -- to the server like any other change, so the URL policy is applied once, in
    -- one place, and every other client sees the same result.
    page:on("media:url", function(payload)
        if type(payload) ~= "table" or type(payload.url) ~= "string" then return end
        TriggerServerEvent("open77:media:control", "url",
            { id = entry.spec.id, url = payload.url })
    end)

    -- What the page asked for, logged BEFORE it is forwarded.
    --
    -- The page's own controls (the strip on the screen) had no trace on this
    -- side at all: the request went to the server, the server answered, and the
    -- only line in the log was the answer -- which named the television's new
    -- state, never who changed it or what they touched. That makes "my click did
    -- nothing" and "my click worked and you cannot hear it" the same log, and
    -- they are not the same complaint. This line separates them at the moment of
    -- the click, on the client that made it.
    page:on("media:volume", function(payload)
        if type(payload) ~= "table" then return end
        local asked
        if type(payload.volume) == "number" then
            asked = string.format("volume %d", math.floor(payload.volume))
            TriggerServerEvent("open77:media:control", "volume",
                { id = entry.spec.id, volume = math.floor(payload.volume) })
        elseif type(payload.muted) == "boolean" then
            asked = payload.muted and "mute" or "unmute"
            TriggerServerEvent("open77:media:control", "muted",
                { id = entry.spec.id, value = payload.muted })
        elseif type(payload.paused) == "boolean" then
            asked = payload.paused and "pause" or "play"
            TriggerServerEvent("open77:media:control", "paused",
                { id = entry.spec.id, value = payload.paused })
        end
        if asked ~= nil then
            print(string.format("[open77_media] television %s: on-screen control asked for %s",
                tostring(entry.spec.id), asked))
        end
    end)
    return true
end

---Applies a screen's new state to a page that already exists. Cheaper than
---rebinding, and it is the common case: someone changed the URL.
local function refreshPage(entry)
    if not entry.materialised or entry.page == nil then return end
    entry.page:send("media:state", pageState(entry))
end

-- =============================================================================
-- SNAPSHOT
-- =============================================================================

---One whole set, applied as a whole.
---
---Diffs rather than rebuilding: a television that merely changed its URL must not
---lose its page, because destroying and recreating a CEF surface is a visible
---flash and a fresh page load. Only screens that appeared or disappeared change
---their materialisation.
local function applySnapshot(snapshot)
    if type(snapshot) ~= "table" then snapshot = {} end

    local incoming = {}
    for _, spec in ipairs(snapshot) do
        local id = tonumber(spec.id)
        if id ~= nil then incoming[id] = spec end
    end

    for id, entry in pairs(screens) do
        if incoming[id] == nil then
            destroyPage(entry)
            screens[id] = nil
        end
    end

    for id, spec in pairs(incoming) do
        local entry = screens[id]
        if entry == nil then
            screens[id] = { spec = spec, distance = nil, materialised = false }
        else
            local changed = entry.spec.url ~= spec.url or entry.spec.volume ~= spec.volume
                or entry.spec.muted ~= spec.muted or entry.spec.paused ~= spec.paused
                or entry.spec.label ~= spec.label
            local resized = surfaceSignature(entry.spec.quad) ~= surfaceSignature(spec.quad)
            entry.spec = spec
            if resized then
                -- Sending state to a page on the wrong-shaped surface would leave
                -- the picture stretched; the surface has to be rebuilt. The next
                -- `reselect` materialises it again, at the new size.
                destroyPage(entry)
            elseif changed then
                refreshPage(entry)
            end
        end
    end

    state.version = state.version + 1
    TriggerEvent("open77:media:changed", state.version)
end

-- =============================================================================
-- AD BLOCKLIST
-- =============================================================================
-- The server's operator layer, on its way to the process that enforces it.
--
-- This half does three things and nothing else: hand the rules to the browser
-- host, wait for that host to say what it did with them, and report it back. The
-- waiting is the part worth explaining.
--
-- The push and its receipt are on different clocks -- Lua calls into the plugin,
-- the plugin puts a message on a pipe, a different process answers -- so reading
-- the receipt immediately after the push reports the PREVIOUS policy about half
-- the time. That is worse than reporting nothing: a server would see revision 6
-- confirmed when it had just sent revision 7, and conclude a rule was in force
-- when it had not been applied yet. So the receipt is polled, bounded, and only
-- reported once the revision matches or the deadline passes.
local adBlockPending = nil   -- { revision = n, deadline = seconds }

---Sends what the host last said about the blocklist, if it has said anything.
---
---`applied = false` is a real answer and is sent as one: a client whose host
---never took the message -- an older host, a host that failed to start -- reports
---it instead of leaving the server to conclude its rules are live.
---Reports what the host has said about `revision`, or why nothing can be said.
---
---`applied` is true only when the host's own receipt is FOR THIS REVISION or a
---newer one. Anything else -- no receipt at all, a receipt for an older list, a
---plugin without the native -- is reported as not applied, with the reason, which
---is the distinction the whole receipt mechanism exists for.
local function reportBlocklist(revision, detail)
    local payload = {
        revision = revision,
        applied = false,
        detail = detail or "no_blocklist_receipt",
    }
    -- Guarded rather than assumed: a game whose plugin predates this feature has
    -- no `Open77.webui` at all, and the answer for that client is the same one a
    -- host that never replies gets -- nobody confirmed what is in force.
    local state = nil
    if type(Open77.webui) == "table" and type(Open77.webui.blocklistState) == "function" then
        state = select(1, Open77.webui.blocklistState())
    end
    if state ~= nil then
        payload.observed = tonumber(state.revision) or 0
        if payload.observed >= revision then
            payload.applied = true
            payload.revision = payload.observed
            payload.hosts = tonumber(state.hostRules) or 0
            payload.tokens = tonumber(state.tokenRules) or 0
            payload.compiled = tonumber(state.compiledRules) or 0
            payload.refused = state.refused or {}
        end
    end
    TriggerServerEvent("open77:media:adblock:receipt", payload)
    print(string.format("[open77_media] adblock revision %s %s%s", tostring(payload.revision),
        payload.applied and "enforced by the host" or "NOT enforced",
        payload.applied and string.format(" (%d hosts + %d tokens, %d refused)",
            payload.hosts, payload.tokens, #(payload.refused or {})) or
            (string.format(": %s%s", tostring(payload.detail),
                payload.observed ~= nil and string.format(" (host holds revision %d)", payload.observed)
                or ""))))
    return payload.applied
end

RegisterNetEvent("open77:media:adblock", function(payload)
    if type(payload) ~= "table" then return end
    if type(Open77.webui) ~= "table" or type(Open77.webui.blocklist) ~= "function" then
        -- The plugin in this game's directory predates the feature. Said out
        -- loud, because the alternative is a server whose rules are silently
        -- not applied and an operator with no reason to suspect it.
        reportBlocklist(tonumber(payload.revision) or 0, "webui_blocklist_unavailable")
        return
    end
    local ok, reason = Open77.webui.blocklist({
        hosts = payload.hosts or {},
        tokens = payload.tokens or {},
        revision = tonumber(payload.revision) or 0,
        source = tostring(payload.source or ""),
    })
    local revision = tonumber(payload.revision) or 0
    if not ok then
        reportBlocklist(revision, tostring(reason or "blocklist_not_applied"))
        return
    end
    adBlockPending = { revision = revision, deadline = 3.0 }
end)

RegisterNetEvent("open77:media:snapshot", applySnapshot)

-- Logged here and nowhere re-emitted. A resource that wants the answer registers
-- the same net event and receives it from the server directly, exactly as this
-- file does -- re-emitting it locally would deliver it twice to anyone listening
-- on both, and "received the result twice" is how a menu ends up showing the
-- same confirmation twice.
RegisterNetEvent("open77:media:result", function(ok, detail)
    print(string.format("[open77_media] %s %s", ok and "OK" or "ERR", tostring(detail)))
end)

-- =============================================================================
-- MATERIALISATION
-- =============================================================================

---Pushes what this client currently has on screen, locally, to any resource that
---asked by registering the event.
---
---A local event rather than an export, because there is no cross-resource export
---call anywhere in this project and inventing one for a status read would be a
---new mechanism for a convenience. It is one-directional on purpose: nothing
---comes back, so there is no request/response pairing to get wrong.
---
---Sent only when the set actually changes, so a menu open for ten minutes is not
---handed a thousand identical tables.
local lastLocalSignature = ""

local function publishLocal()
    local out = {}
    local signature = {}
    for _, entry in pairs(screens) do
        out[#out + 1] = {
            id = entry.spec.id,
            label = entry.spec.label,
            url = entry.spec.url,
            volume = entry.spec.volume,
            muted = entry.spec.muted,
            paused = entry.spec.paused,
            distance = entry.distance,
            materialised = entry.materialised,
        }
        signature[#signature + 1] = string.format("%s:%s:%s:%s:%s:%s",
            tostring(entry.spec.id), tostring(entry.materialised),
            tostring(entry.spec.url), tostring(entry.spec.volume),
            tostring(entry.spec.muted), tostring(entry.spec.paused))
    end
    table.sort(out, function(a, b) return (tonumber(a.id) or 0) < (tonumber(b.id) or 0) end)
    table.sort(signature)

    local joined = table.concat(signature, "|")
    if joined == lastLocalSignature then return end
    lastLocalSignature = joined
    TriggerEvent("open77:media:local", out)
end

---Why a screen that IS bound is not on the wall.
---
---`Open77.media.list()` reports, per screen the native holds for this resource,
---`drawn`, the `reason` its last game tick refused it with (`prop_not_projected`,
---`behind_camera`, `occluded`, `out_of_range`, `behind_panel` or `drawn`), and
---`facing` -- whether the record declared which side the picture is on and, when
---it did, whether the eye is behind it.
---The resource asked for none of that while it was broken, and that is why
---"blank television" had no answer past the first gate: the page was created, the
---bind was refused for a reason nothing printed, and the only line in the log
---was the refusal. With the rectangle fixed, the next gate that can refuse a
---screen -- projection, camera, occlusion, range -- names itself here.
---
---Logged on CHANGE, not once a second. A screen that is occluded stays occluded,
---and a wall of identical lines is not a diagnostic. Failures of the native call
---itself are swallowed on purpose: a diagnostic must never be the reason the
---render loop stops.
local lastDrawnState = {}

local function reportDrawn()
    if type(Open77.media.list) ~= "function" then return end
    local ok, listed = pcall(Open77.media.list)
    if not ok or type(listed) ~= "table" then return end

    local byNative = {}
    local held = {}
    for _, entry in pairs(screens) do
        if entry.native ~= nil then byNative[tostring(entry.native)] = entry end
    end
    for _, snapshot in ipairs(listed) do held[tostring(snapshot.id)] = true end

    -- Pages the native side no longer has a screen for.
    --
    -- The two halves of this feature have different lifetimes and that mismatch
    -- is what put a television on the loading screen: the native half releases
    -- every screen when the world goes away (its own `OnRunningExit`), while this
    -- resource is *not* stopped by a world change, so every entry stayed
    -- `materialised` across a disconnect and the CEF surface stayed alive with
    -- it. Nothing on the native side can be missed less often than a check this
    -- file already makes once a second, and the check is exact: a screen this
    -- side still believes in and the native registry does not hold is a page with
    -- nothing to be a page on. Destroying it here makes the next pass build it
    -- again, in the world that exists now.
    local stale = {}
    for _, entry in pairs(screens) do
        if entry.materialised and entry.native ~= nil and held[tostring(entry.native)] == nil then
            stale[#stale + 1] = entry
        end
    end
    for _, entry in ipairs(stale) do
        print(string.format(
            "[open77_media] television %s: the native side no longer holds screen %s " ..
            "(world changed under it); dropping the page and rebuilding it",
            tostring(entry.spec.id), tostring(entry.native)))
        destroyPage(entry)
        lastDrawnState[entry.spec.id] = nil
    end

    for _, snapshot in ipairs(listed) do
        local entry = byNative[tostring(snapshot.id)]
        if entry ~= nil then
            -- Keyed by the SET's id, the same number the menu and the server
            -- console use, not by the native screen id the snapshot carries.
            local key = entry.spec.id
            -- `facing` is part of the state on purpose. "The television is
            -- blank" and "the television is blank because I am standing behind
            -- it" are different findings, and so is "this record never said
            -- which side its picture is on, so it is drawn from both" -- which is
            -- what a set still showing video through its own cabinet means.
            local facing = snapshot.facing
            local facingText = "undeclared"
            if type(facing) == "table" and facing.known then
                facingText = facing.away and "behind" or "front"
            end
            local state = string.format("%s:%s:%s", tostring(snapshot.drawn),
                tostring(snapshot.reason), facingText)
            if lastDrawnState[key] ~= state then
                lastDrawnState[key] = state
                local facingNote = facingText == "undeclared"
                    and " (this record declares no front: drawn from both sides)"
                    or (" (facing the picture: " .. facingText .. ")")
                print(string.format("[open77_media] television %s (%s): %s%s",
                    tostring(entry.spec.id), tostring(entry.spec.record),
                    snapshot.drawn and "drawing"
                        or ("not drawing -- " .. tostring(snapshot.reason)),
                    facingNote))
            end
        end
    end
end

---How much closer a screen must be to take the page of one that already has it.
---
---This is the hysteresis, and it is a *margin in metres* rather than a rank
---priority. The difference matters and it is where this file was wrong: ranking
---every materialised screen above every newcomer means the six screens standing
---when the player joins spend the whole budget, and a set spawned at their feet
---afterwards can never win one -- it is created on the server, bound by nothing,
---and the player sees a spawn that does nothing. Five metres is smaller than the
---distance between two rooms and larger than the spacing of screens stacked on
---one wall, so a set brought into the world in front of the player takes a slot
---while a page is not torn down for a screen that is merely a little nearer.
local MATERIALISE_HYSTERESIS = 5.0

---The nearest screens win the budget, and pages are given up by screens that lose
---their place in it.
---
---A television already materialised is ranked as if it stood `MATERIALISE_HYSTERESIS`
---closer than it does, so an existing page is not destroyed for one that is
---marginally nearer; beyond that margin the nearest screen wins. The tie-break is
---by id, ascending, so two screens at the same distance do not swap every second
----- each swap is a page destroyed and a page created.
local function reselect()
    local reachable = {}
    for _, entry in pairs(screens) do
        entry.distance = distanceTo(entry.spec.position)
        if entry.distance ~= nil and entry.distance <= MATERIALISE_RADIUS then
            reachable[#reachable + 1] = entry
        end
    end
    table.sort(reachable, function(a, b)
        local ranked = a.distance - (a.materialised and MATERIALISE_HYSTERESIS or 0.0)
        local other = b.distance - (b.materialised and MATERIALISE_HYSTERESIS or 0.0)
        if math.abs(ranked - other) > 0.5 then return ranked < other end
        if a.materialised ~= b.materialised then return a.materialised end
        return (tonumber(a.spec.id) or 0) < (tonumber(b.spec.id) or 0)
    end)

    -- Out of range entirely.
    for _, entry in pairs(screens) do
        if entry.materialised and (entry.distance == nil or entry.distance > MATERIALISE_RADIUS) then
            destroyPage(entry)
            lastDrawnState[entry.spec.id] = nil
        end
    end

    -- The budget, spent nearest-first, and given back by whoever falls outside
    -- it. Without this second half a full budget is permanent: the six pages
    -- standing when the player joined would keep their slots forever and every
    -- set spawned afterwards would be a prop with no picture.
    local kept = 0
    for _, entry in ipairs(reachable) do
        if kept < MAX_MATERIALISED then
            if entry.materialised or materialisePage(entry) then
                kept = kept + 1
            end
        elseif entry.materialised then
            destroyPage(entry)
            lastDrawnState[entry.spec.id] = nil
        end
    end

    reportDrawn()
    publishLocal()
end

-- =============================================================================
-- LIFECYCLE
-- =============================================================================

local function clearAll()
    for id, entry in pairs(screens) do
        destroyPage(entry)
        screens[id] = nil
    end
    -- Belt and braces, as the props resource does it: an entry orphaned by a
    -- mismatch between this file's bookkeeping and the native registry would
    -- otherwise survive a resource restart as a picture on a wall.
    Open77.media.clear()
end

AddEventHandler("onClientResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    clearAll()
    lastLocalSignature = ""
    TriggerServerEvent("open77:media:ready")

    -- One thread, one second, one job: which screens exist. See the file header
    -- for why this is not a per-frame concern.
    CreateThread(function()
        while true do
            local ok, err = pcall(reselect)
            if not ok then
                print("[open77_media] materialisation failed: " .. tostring(err))
            end
            Wait(1000)
        end
    end)

    -- The blocklist receipt, polled while one is outstanding. Cheap by
    -- construction -- the thread exists only between a push and its answer, and a
    -- policy is pushed on join and when an operator changes the list, so in a
    -- normal session this costs a handful of iterations total.
    CreateThread(function()
        while true do
            if adBlockPending ~= nil then
                local state = nil
                if Open77.webui ~= nil and type(Open77.webui.blocklistState) == "function" then
                    state = select(1, Open77.webui.blocklistState())
                end
                local observed = nil
                if state ~= nil then observed = tonumber(state.revision) or -1 end
                -- `>=` and not `==`: a push superseded by a newer one still has
                -- to be answered, and what is in force is the revision the host
                -- names, not the one this thread was waiting on.
                if observed ~= nil and observed >= adBlockPending.revision then
                    adBlockPending = nil
                    reportBlocklist(observed, nil)
                else
                    adBlockPending.deadline = adBlockPending.deadline - 0.1
                    if adBlockPending.deadline <= 0 then
                        local revision = adBlockPending.revision
                        adBlockPending = nil
                        reportBlocklist(revision, "no_blocklist_receipt")
                    end
                end
            end
            Wait(100)
        end
    end)
end)

AddEventHandler("onClientResourceStop", function(name)
    if name ~= GetCurrentResourceName() then return end
    clearAll()
end)

-- The session ending is not a resource stop, and that difference is exactly why
-- a television could be seen on the next load screen: this resource keeps
-- running while the world is torn down and the server browser comes back, so its
-- pages -- browser surfaces, not world objects -- outlived the session that owned
-- them and were still compositing when the next one was loading.
--
-- Cleared on the event rather than left to the once-a-second staleness check
-- above, because the loading screen appears within a frame or two of this and a
-- second is long enough to see it.
AddEventHandler("open77:session:ended", function(reason)
    if next(screens) == nil then return end
    print(string.format(
        "[open77_media] session ended (%s): releasing %d television page(s)",
        tostring(reason or "unknown"), (function()
            local count = 0
            for _ in pairs(screens) do count = count + 1 end
            return count
        end)()))
    clearAll()
end)

-- =============================================================================
-- SURFACE FOR GAMEPLAY RESOURCES
-- =============================================================================
-- The menu asks this resource rather than talking to the server itself, so the
-- catalogue and the spawn path are reachable through one audited doorway.

-- No exports, and that is a decision rather than an omission. There is no
-- cross-resource export CALL anywhere in this project -- `exports` registers, and
-- nothing invokes another resource's registered function -- so a menu that wanted
-- to drive this feature through an export would be inventing the mechanism first.
-- It does not have to: every mutation is a server event (`open77:media:spawn`,
-- `open77:media:control`) that any resource may send and this one validates, and
-- the current set is pushed locally as `open77:media:local` below. Gameplay
-- resources then talk to the same audited surface a console operator does.

-- =============================================================================
-- WHAT THIS CLIENT HAS ON SCREEN, PUSHED LOCALLY
-- =============================================================================
-- `open77:media:local` carries the sets this client is rendering, with their
-- distance and their materialisation state. Local and deliberately so: it
-- describes THIS client, not the server's set, and a menu that showed the
-- server's set here would claim six screens on a server holding sixty.

print("open77_media client ready")
