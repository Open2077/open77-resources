-- =============================================================================
-- open77_vehiclepicker -- client
-- =============================================================================
--
-- A gamemode-agnostic vehicle picker. It owns one WebUI surface, one roster
-- (`shared/roster.lua`), and the player's remembered choice. It owns NO
-- gameplay: it never spawns a car, never decides when a match starts, and never
-- claims a choice was applied. It reports intent and draws state.
--
-- WHY THIS IS A CLIENT RESOURCE AND HAS NO SERVER SCRIPT
--
-- Because a shared server service is impossible on this platform, not because
-- one was not wanted. `wiki/gamemode-kernel.md` is the reference: the server
-- Lua runtime installs no `exports` and no cross-resource event bus, so a
-- second server resource "could not be asked for anything". The client runtime
-- DOES have `exports` and `GetInvokingResource()`, which is exactly why
-- `open77_zones` and `open77_worldui` are client-only shared services and why
-- this one is too.
--
-- The consequence for a gamemode: the picker's client half is called through
-- exports, and its server half is a FILE THE GAMEMODE COPIES -- `shared/roster.lua`
-- into its own `server/`. That is the platform's own stated sharing mechanism
-- ("on the server, code generation is the sharing mechanism"), not a shortcut.
-- README.md, "Integrating", is the exact recipe.
--
-- THE INPUT-TRAP RULE
--
-- A modal that owns the keyboard and cannot be dismissed is a known hazard in
-- this codebase, so the close paths are deliberately redundant. FIVE of them
-- release focus, and none depends on any other working:
--
--   1. the page's own ESC key and its close button (page -> `picker:close`);
--   2. `open77:pauseKey`, which the plugin raises because it SWALLOWS Escape in
--      the window procedure while the pause menu is armed -- so the page-side
--      handler in (1) can never fire during a real session and would be the
--      only path if this one did not exist;
--   3. `onClientResourceStop`, so a reload cannot leave focus behind;
--   4. the gamemode's own `open77_vehiclepicker:close` net event;
--   5. a WATCHDOG. `openedAt` is stamped on open and a thread force-closes the
--      surface after `MAX_OPEN_MS`. If every other path is broken, the picker
--      still lets go of the keyboard within a minute. This is the one that is
--      not there for the player -- it is there for the bug nobody found yet.
--
-- `releaseFocus()` is idempotent and is what all five call. It sets focus false
-- BEFORE it touches any other state, so an error later in a close path can
-- never strand the cursor.
-- =============================================================================

-- Load order is manifest order, and `shared/roster.lua` is listed first, so
-- this is populated. The guard is not paranoia about that -- it is what turns
-- "somebody reordered the manifest" from a stack trace on the first click into
-- one legible line at start.
local Roster = Open77VehicleRoster
if type(Roster) ~= "table" or type(Roster.resolve) ~= "function" then
    Open77.log.error(
        "vehiclepicker: Open77VehicleRoster missing -- is shared/roster.lua " ..
        "listed BEFORE client/main.lua in open77.lua? The picker will not start.")
    return
end

-- --------------------------------------------------------------------- state --

local page                 -- WebUI page handle, created once at resource start
local pageReady = false    -- the page has answered `picker:ready`
local open = false         -- the panel is up AND holding focus
local openedAt = 0         -- Open77.time.monotonic() when it went up
local locked = false       -- the match started; picks apply to the NEXT one
local listId = nil         -- which roster list is on screen
local deadlineAt = nil     -- monotonic seconds, or nil for "no clock"

-- The remembered pick, per list. Authoritative only as an INTENT: the gamemode
-- server re-resolves the key against its own copy of the roster and may ignore
-- it entirely.
--
-- `loaded` records that a list's KVP entry has been CONSULTED, which is not the
-- same as it having a value. Without it, a player who has never chosen anything
-- re-reads the store on every repaint -- twice a second while a deadline is
-- counting down -- because "no entry" and "not looked yet" are both nil.
local chosen = {}
local loaded = {}

-- A picker that cannot be dismissed is worse than a picker that closes itself
-- at a bad moment. Sixty seconds is far longer than any sane pre-match window
-- and far shorter than an evening spent unable to steer.
local MAX_OPEN_MS = 60000
local WATCHDOG_MS = 500

local function nowSeconds()
    return Open77.time.monotonic()
end

local function kvpKey(id)
    return "pick:" .. tostring(id)
end

-- --------------------------------------------------------------- persistence --
--
-- `Open77.kvp` needs no permission and is namespaced by connection address and
-- resource, so a pick made on one server never leaks to another. A player who
-- chose a car last night gets it back tonight without opening the panel at all,
-- which is the entire point of remembering it.
--
-- Every read is re-validated through `Roster.resolve`: a stored key whose entry
-- was later removed from the roster must degrade to the default, not to a
-- dangling reference.

local function loadChoice(id)
    if type(Open77.kvp) ~= "table" then return nil end
    local stored = Open77.kvp.get(kvpKey(id), nil)
    if type(stored) ~= "string" then return nil end
    if Roster.resolve(id, stored) == nil then
        Open77.kvp.delete(kvpKey(id))
        return nil
    end
    return stored
end

local function saveChoice(id, key)
    if type(Open77.kvp) ~= "table" then return end
    local ok, reason = Open77.kvp.set(kvpKey(id), key)
    if not ok then
        Open77.log.warn(("vehiclepicker: could not remember '%s': %s"):format(
            tostring(key), tostring(reason)))
    end
end

--- The remembered key for a list, or the list default. Never nil for a list
--- that exists.
local function currentKey(id)
    if not loaded[id] then
        loaded[id] = true
        chosen[id] = loadChoice(id)
    end
    if chosen[id] ~= nil then return chosen[id] end
    local fallback = Roster.default(id)
    return fallback and fallback.key or nil
end

-- ---------------------------------------------------------------- the surface --

--- Everything the page needs to draw itself, built from the roster each time so
--- a roster edit reaches the UI on reload with no other change.
local function viewState()
    local list = Roster.list(listId)
    if list == nil then return nil end

    local selected = currentKey(listId)
    local entries = {}
    for index, entry in ipairs(list.entries) do
        entries[index] = {
            key = entry.key,
            name = entry.name,
            maker = entry.maker,
            note = entry.note,
            unverified = entry.unverified == true,
            isDefault = entry.key == list.default,
            -- Sent only when a real measurement exists. The page draws "not
            -- measured" for the rest rather than inventing a bar, because a
            -- fabricated performance figure is exactly the thing this roster's
            -- rationale is at pains not to produce.
            launch5s = entry.measured and entry.measured.launch5s or nil,
        }
    end

    local remainingMs = nil
    if deadlineAt ~= nil then
        remainingMs = math.max(0, (deadlineAt - nowSeconds()) * 1000.0)
    end

    return {
        listId = list.id,
        eyebrow = list.eyebrow,
        title = list.title,
        band = Roster.band.label,
        bandNote = Roster.band.note,
        entries = entries,
        selected = selected,
        locked = locked,
        remainingMs = remainingMs,
    }
end

local function push()
    if page == nil or not pageReady then return end
    local state = viewState()
    if state == nil then return end
    page:send("picker:state", state)
end

--- Idempotent, and the ONLY place focus is dropped. Called by all five close
--- paths. Focus first, then everything else.
local function releaseFocus(why)
    if page ~= nil then
        page:setFocus(false, false)
        page:send("picker:closed", {})
    end
    if open then
        Open77.log.info("vehiclepicker: closed (" .. tostring(why) .. ")")
    end
    open = false
    deadlineAt = nil
end

--- Open the panel on a list. Refuses rather than half-opens.
--- @param options table  { list = "civilian", locked = bool, deadlineMs = number }
--- @return boolean, string?
local function openPicker(options)
    options = type(options) == "table" and options or {}

    local id = options.list or options.listId
    if Roster.list(id) == nil then
        return false, "unknown_list:" .. tostring(id)
    end
    if page == nil then
        return false, "surface_unavailable"
    end

    listId = id
    locked = options.locked == true
    deadlineAt = nil
    local deadlineMs = tonumber(options.deadlineMs)
    if deadlineMs ~= nil and deadlineMs > 0 then
        deadlineAt = nowSeconds() + (deadlineMs / 1000.0)
    end

    -- Prime the page BEFORE taking focus, so it is never up and blank.
    push()
    page:send("picker:open", {})

    local focused, reason = page:setFocus(true, true)
    open = true
    openedAt = nowSeconds()
    if not focused then
        -- Still "open": the panel is drawn and readable. Without focus it takes
        -- no clicks, so say so loudly rather than leaving a dead panel up.
        Open77.log.warn("vehiclepicker: focus refused (" .. tostring(reason) ..
            "); panel is visible but not interactive")
    end
    return true
end

--- Record a pick. Local + KVP + a report to the server. Returns the key that
--- is now current, which is NOT necessarily the one asked for.
local function choose(id, key)
    if Roster.resolve(id, key) == nil then
        return nil, "unknown_key"
    end
    chosen[id] = key
    saveChoice(id, key)

    -- Intent, not a claim. The key travels; the record never does. See
    -- shared/roster.lua section 5 for why that distinction is the security
    -- boundary and not a stylistic one.
    local sent, reason = TriggerServerEvent("open77_vehiclepicker:selected", {
        list = id,
        key = key,
    })
    if not sent then
        Open77.log.warn("vehiclepicker: selection not sent: " .. tostring(reason))
        if page ~= nil and pageReady then
            page:send("picker:result", { ok = false, text = "NETWORK REFUSED" })
        end
        return key
    end

    if page ~= nil and pageReady then
        page:send("picker:result", {
            ok = true,
            text = locked and "SAVED FOR NEXT MATCH" or "SAVED",
        })
    end
    return key
end

-- ---------------------------------------------------- announcing what is kept --
--
-- WITHOUT THIS, REMEMBERING DOES NOT ACTUALLY WORK. The pick lives in the
-- player's client KVP, and the gamemode server learns it only from
-- `open77_vehiclepicker:selected` -- which is sent when he CLICKS. So a player
-- who chose the Thrax last night, reconnects, and never opens the panel would
-- silently get the roster default, while his own picker still showed the Thrax
-- as selected. The UI and the car would disagree and nothing would say why.
--
-- So the remembered picks are reported once per session, unprompted. It is the
-- same shape of message the click sends, so the server needs no extra handler,
-- and it is idempotent: the server stores a key it may already hold.

local announced = false

local function announceRemembered()
    if announced then return end
    announced = true

    local sent = 0
    for id in pairs(Roster.lists) do
        -- Only a REAL stored pick is announced. Announcing the default would be
        -- indistinguishable from a deliberate choice, and would overwrite
        -- nothing -- the server resolves an absent key to the same default
        -- anyway -- so it would be noise that looks like intent.
        if not loaded[id] then
            loaded[id] = true
            chosen[id] = loadChoice(id)
        end
        if chosen[id] ~= nil then
            local ok = TriggerServerEvent("open77_vehiclepicker:selected", {
                list = id,
                key = chosen[id],
            })
            if ok then sent = sent + 1 end
        end
    end

    if sent > 0 then
        Open77.log.info(("vehiclepicker: reported %d remembered pick(s)"):format(sent))
    end
end

-- `open77:worldReady` fires more than once per session and NOT AT ALL after a
-- hot reload, because the world is already up. A resource that only listened
-- here would lose the announce on every reload -- the exact trap
-- `docs/writing-a-gamemode.md` 3.1 documents -- so the reload case is covered
-- by a short-delayed check for an already-attached character.
AddEventHandler("open77:worldReady", announceRemembered)

-- --------------------------------------------------------------- net triggers --
--
-- The gamemode's server drives all three. A gamemode that wants nothing to do
-- with events can drive the same three through the exports below instead.

RegisterNetEvent("open77_vehiclepicker:open", function(payload)
    if type(payload) ~= "table" then payload = {} end
    local ok, reason = openPicker(payload)
    if not ok then
        Open77.log.warn("vehiclepicker: open refused: " .. tostring(reason))
    end
end)

RegisterNetEvent("open77_vehiclepicker:close", function()
    releaseFocus("server")
end)

--- The match started. The panel does not vanish -- a player mid-decision would
--- have it yanked away with no explanation -- it goes read-only with a banner
--- saying the pick applies next time. That is also the answer to "what if he
--- chooses after the match starts": the pick is kept, and it is honestly
--- labelled as being for the next match.
RegisterNetEvent("open77_vehiclepicker:lock", function(payload)
    locked = not (type(payload) == "table" and payload.locked == false)
    deadlineAt = nil
    push()
end)

-- ------------------------------------------------------------------- exports --
--
-- For a gamemode's CLIENT half. Ownership is not taken from an argument -- see
-- `docs/writing-a-gamemode.md` 3.2 -- but none of these mutate per-owner state,
-- so there is no ownership ledger to sweep and no impersonation to prevent.
-- They are open/close/read.

exports("open", function(options)
    return openPicker(options)
end)

exports("close", function()
    releaseFocus("export")
    return true
end)

--- The player's current key for a list, applying the default. A gamemode client
--- can use this to show the pick in its own HUD without duplicating the KVP.
exports("selection", function(id)
    if Roster.list(id) == nil then return nil, "unknown_list" end
    return currentKey(id)
end)

--- The roster as data, for a gamemode that wants to draw its own list.
exports("roster", function(id)
    local list = Roster.list(id)
    if list == nil then return nil, "unknown_list" end
    local out = {}
    for index, entry in ipairs(list.entries) do
        out[index] = {
            key = entry.key,
            record = entry.record,
            fallback = entry.fallback,
            name = entry.name,
            maker = entry.maker,
            unverified = entry.unverified == true,
        }
    end
    return { id = list.id, label = list.label, default = list.default, entries = out }
end)

exports("isOpen", function()
    return open
end)

-- ----------------------------------------------------------------- lifecycle --

AddEventHandler("onClientResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end

    local reason
    page, reason = WebUI.create({
        entry = "web/index.html",
        layer = "menu",
        width = 1920,
        height = 1080,
        fps = 30,
        -- LAYER does the ordering that matters, not zIndex. `menu` sits above
        -- `hud`, so the panel is over the Pursuit HUD (hud/640), the interaction
        -- prompts (hud/660) and the toasts (hud/720) without competing with any
        -- of them on a number -- and BELOW `system`, which is where the pause
        -- menu and the server browser live. That ordering is the reason
        -- `open77:pauseKey` can close this panel with the pause menu drawing
        -- cleanly on top of it rather than behind it.
        --
        -- zIndex only orders surfaces WITHIN `menu`; 700 leaves room beneath.
        --
        -- Being on top is also the claim section 6.2 of the design system makes
        -- a modal earn: it is exempt from the screen-region map because it dims
        -- what is behind it and takes the screen. The body is fully transparent
        -- and `pointer-events: none` while closed, so the exemption is never
        -- claimed while it is not true.
        zIndex = 700,
        transparent = true,
        -- Created VISIBLE and left visible for the whole generation. A surface
        -- created hidden never uploads a frame once shown on the current client
        -- build -- the same trap `freeroam/client/main.lua` documents. The BODY
        -- is what opens and closes.
        visible = true,
    })
    if page == nil then
        Open77.log.error("vehiclepicker: WebUI failed: " .. tostring(reason))
        return
    end

    page:on("picker:ready", function()
        pageReady = true
        push()
    end)

    page:on("picker:choose", function(payload)
        if type(payload) ~= "table" or type(payload.key) ~= "string" then return end
        -- Accepted even while locked, deliberately: `choose` labels the result
        -- "SAVED FOR NEXT MATCH" and the pick is kept. Refusing it here would
        -- leave a player clicking a card that does nothing and says nothing.
        choose(listId, payload.key)
        push()
    end)

    page:on("picker:close", function()
        releaseFocus("page")
    end)

    -- ------------------------------------------------------------ watchdogs --
    --
    -- One thread, two jobs, both cheap at 2 Hz: refresh the deadline readout,
    -- and enforce the maximum open time. It deliberately does NOT repaint when
    -- the panel is closed -- a closed picker should cost nothing.
    CreateThread(function()
        while page ~= nil do
            if open then
                if (nowSeconds() - openedAt) * 1000.0 >= MAX_OPEN_MS then
                    -- The safety net firing is always a bug somewhere else, so
                    -- it says so at warn level rather than closing quietly.
                    Open77.log.warn(("vehiclepicker: watchdog closed the panel after %d ms")
                        :format(MAX_OPEN_MS))
                    releaseFocus("watchdog")
                elseif deadlineAt ~= nil then
                    push()
                    if nowSeconds() >= deadlineAt then
                        releaseFocus("deadline")
                    end
                end
            end
            Wait(WATCHDOG_MS)
        end
    end)

    -- The reload half of the announce pattern. On a fresh session `worldReady`
    -- gets there first and `announced` makes this a no-op; on a hot reload into
    -- a live world it is the only path. `attached` is the test for "there is
    -- really a world", so a reload in the menu does not announce into nothing.
    CreateThread(function()
        Wait(500)
        if announced then return end
        local state = Open77.character.state()
        if state == nil or not state.attached then return end
        announceRemembered()
    end)

    Open77.log.info("vehiclepicker ready")
end)

-- Escape is owned by the plugin while the pause menu is armed: it is swallowed
-- in the window procedure and never reaches a focused page, so the page's own
-- Escape handler cannot fire in a live session. The plugin raises this instead.
-- Without this handler the panel would be dismissible only by mouse.
AddEventHandler("open77:pauseKey", function()
    if open then releaseFocus("pause") end
end)

AddEventHandler("onClientResourceStop", function(name)
    if name ~= GetCurrentResourceName() then return end
    -- Focus is released before the handle is dropped. A generation teardown
    -- destroys the surface anyway, but the ordering costs nothing and the
    -- failure it prevents -- a session with no cursor and no keyboard -- is the
    -- worst one this resource can cause.
    releaseFocus("stop")
    page, pageReady, open = nil, false, false
end)
