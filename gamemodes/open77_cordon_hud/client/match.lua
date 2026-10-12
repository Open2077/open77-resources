-- The match surface: staging panel, deploy panel, phase band, kill feed,
-- notices, squad panel, inventory strip, result card and standings.
--
-- Everything here changes on a human timescale, so the page runs at 12 fps and
-- this file pushes at 10 Hz. The fast half lives in client/combat.lua and the
-- map in client/tacmap.lua.
--
-- Presentation only. Plan section 10 is explicit: "Everything player-facing
-- comes from the state push (`cordon:state`, 500 ms, shaped on the server)".
-- The payload is shaped SERVER-SIDE and is never re-derived here -- this file
-- does not decide who is alive, how many squads are left, what a placement is,
-- or which block is closing. The single local computation is counting a pushed
-- millisecond value down between snapshots, because a clock that only moved
-- twice a second reads as a hung server.
--
-- THE STATE CONTRACT, and why every field is optional.
--
-- The first push arrives before anything is set: a player who connects during
-- staging gets a payload with no `cordon`, no `inventory` and no `result`, and
-- a player watching from staging gets one with `participant = false`. Every
-- reader on both sides of the bridge therefore tolerates a missing field rather
-- than testing for one, and the page renders a sensible empty state instead of
-- throwing halfway through a paint. This is not defensive style; it is the
-- normal case for the first two seconds of every connection.

CordonMatch = {}

local page
local ready = false
local strings = nil

-- The last full snapshot. `nil` until the first push, which the page renders as
-- the "standby" state rather than as a match with zero players in it.
local state = nil
local consumableKeys = {}

-- Clock anchors. The server sends a REMAINING duration, not a timestamp: the
-- client has no shared clock with the server, so an absolute deadline would be
-- unusable. Each one is anchored on arrival and counted down locally.
local anchoredAt = 0
local anchoredPhaseMs = 0
local anchoredCountdownMs = 0
local anchoredCloseMs = 0

-- Local QUEUE intent, so the panel flips on the key press instead of 500 ms
-- later. The server holds the real ledger (`staging.inQueue`) and wins as soon
-- as the optimistic window closes -- so a refused join reverts on its own after
-- a second and a half rather than lying for the rest of staging.
local queueIntent = false
local queueIntentAt = 0
local QUEUE_INTENT_MS = 1500

local function nowSeconds()
    return Open77.time.monotonic()
end

local function number(value, fallback)
    local n = tonumber(value)
    if n == nil or n ~= n then return fallback or 0 end
    return n
end

local function countdown(anchored)
    if anchored <= 0 then return 0 end
    local elapsed = (nowSeconds() - anchoredAt) * 1000
    return math.max(0, anchored - elapsed)
end

local function push()
    if page == nil or not ready then return end
    if state == nil then
        page:send("cordon:state", { phase = "unknown", participant = false })
        return
    end

    -- Interpolated clocks are written back onto the snapshot rather than sent
    -- beside it, so the page reads one shape whether the value came from the
    -- server this instant or was counted down locally since.
    state.remainingMs = countdown(anchoredPhaseMs)
    if type(state.staging) == "table" then
        state.staging.countdownMs = countdown(anchoredCountdownMs)
    end
    if type(state.cordon) == "table" then
        -- Normalised to the contract's name so the page reads one field.
        state.cordon.closeAtMs = countdown(anchoredCloseMs)
    end

    -- Purely local presentation state, namespaced so it can never be confused
    -- with something the server said.
    state.hud = {
        queueIntent = queueIntent,
        tacmapKey = CordonTacmap.keyLabel(),
        queueKey = CordonMatch.joinKeyLabel(),
        tacmapOpen = CordonTacmap.isOpen(),
        useKeys = consumableKeys,
    }

    state.inventory = CordonInventory.snapshot()
    page:send("cordon:state", state)
end

AddEventHandler("cordon:consumables:keys", function(keys)
    consumableKeys = type(keys) == "table" and keys or {}
    push()
end)

function CordonMatch.phase()
    if state == nil then return "unknown" end
    return tostring(state.phase or "unknown")
end

function CordonMatch.snapshot()
    return state
end

-- ---------------------------------------------------------------------------
-- The one state push
-- ---------------------------------------------------------------------------

RegisterNetEvent("cordon:state", function(payload)
    if type(payload) ~= "table" then return end
    state = payload
    CordonInventory.adopt(payload)
    anchoredAt = nowSeconds()
    anchoredPhaseMs = math.max(0, number(payload.remainingMs, 0))
    anchoredCountdownMs = type(payload.staging) == "table"
        and math.max(0, number(payload.staging.countdownMs, 0)) or 0
    -- TWO SPELLINGS, ON PURPOSE. The HUD contract calls the next-closure
    -- countdown `closeAtMs`; the gamemode's `C.fragment()` currently emits it
    -- as `closeInMs`. Both mean the same thing -- MILLISECONDS REMAINING, never
    -- an absolute timestamp, because the client shares no clock with the server
    -- -- so both are read and whichever arrives is anchored. Delete the fallback
    -- only when the server has settled on one name.
    anchoredCloseMs = type(payload.cordon) == "table"
        and math.max(0, number(payload.cordon.closeAtMs,
            number(payload.cordon.closeInMs, 0))) or 0

    -- THE SERVER IS THE LEDGER. The local flag only covers the gap between the
    -- key press and the next push; once that window has passed, whatever the
    -- server says is what the panel shows -- including a join it refused, which
    -- would otherwise leave the player believing they are in a match they are
    -- not in.
    local stagingFragment = type(payload.staging) == "table" and payload.staging or nil
    local fresh = (nowSeconds() - queueIntentAt) * 1000 < QUEUE_INTENT_MS
    if stagingFragment ~= nil then
        if type(stagingFragment.inQueue) == "boolean" and not fresh then
            queueIntent = stagingFragment.inQueue
        end
    else
        -- No staging fragment means no staging phase, so there is no queue to be
        -- in; the panel must not keep claiming otherwise.
        queueIntent = false
    end

    push()
    -- The fast surface and the map need the same truth. Routed through
    -- client/main.lua so the fan-out order is stated in one place.
    CordonHud.route(payload)
end)

-- Transient notices. The ONE extra event beyond the state push, and it exists
-- for the same reason the deathmatch has `deathmatch:notice`: a toast is an
-- edge, not a level. Folding "the cordon is closing" into a 500 ms level push
-- would make the client diff two snapshots to find the moment, which is
-- exactly the sort of re-derivation the state contract exists to forbid.
--
-- The payload is a KIND and optional counts, never display text.
RegisterNetEvent("cordon:notice", function(payload)
    if CordonHud and CordonHud.canPresent and not CordonHud.canPresent() then return end
    if page == nil or not ready or type(payload) ~= "table" then return end
    -- `fields` is the gamemode's shape (`{ kind = kind, fields = {...} }`) and
    -- is forwarded whole: it is the substitution table for the `{placeholder}`
    -- in whichever string the kind names. Nothing in it is display text, and
    -- nothing here inspects it -- a notice this HUD has no string for is simply
    -- not drawn, which is the correct answer to a kind it does not know.
    page:send("cordon:notice", {
        kind = tostring(payload.kind or "generic"),
        fields = type(payload.fields) == "table" and payload.fields or {},
    })
end)

-- SQUAD EVENTS ARE NOTICES TOO, and until now nothing listened for them at all.
-- `K.squads.notifySquad` has been sending `cordon:squad` since squads existed --
-- the drop pin announcement among them -- and no surface subscribed, so a pin
-- the server accepted and told the whole squad about was heard by nobody. It
-- carries the same `{ kind, fields }` shape as `cordon:notice` for exactly this
-- reason, so it goes down the same pipe: the string table decides whether a
-- kind is drawn, here as everywhere.
RegisterNetEvent("cordon:squad", function(payload)
    if page == nil or not ready or type(payload) ~= "table" then return end
    page:send("cordon:notice", {
        kind = tostring(payload.kind or "generic"),
        fields = type(payload.fields) == "table" and payload.fields or {},
    })
end)

-- ---------------------------------------------------------------------------
-- JOINING THE NEXT MATCH
--
-- One key, one decision, and it replaces the ready gate outright. Staging shows
-- a countdown that starts the match on its own; this says whether the player is
-- in that match or watching it. Nothing is unanimous, so nothing waits on
-- anybody.
--
-- A key, not a button: see the focus note at the top of client/main.lua. The
-- server owns the queue; this only asks.
-- ---------------------------------------------------------------------------

local joinKey = nil

function CordonMatch.joinKeyLabel()
    return joinKey or CordonHudStrings.keys.unbound
end

function CordonMatch.toggleQueue()
    if CordonHud and CordonHud.canPresent and not CordonHud.canPresent() then return end
    if state == nil then return end
    -- The queue only exists in staging. Outside it the key is inert rather than
    -- sending a request the server would refuse anyway.
    if tostring(state.phase or "") ~= "staging" then return end
    local staging = type(state.staging) == "table" and state.staging or nil
    if staging ~= nil and staging.canQueue == false then return end

    queueIntent = not queueIntent
    queueIntentAt = nowSeconds()
    -- `cordon:queue`, NOT `cordon:ready`. The gamemode's own client already owns
    -- `cordon:ready` for the world-ready handshake it fires on
    -- `open77:worldReady`; reusing that name would make every join look like a
    -- client announcing it can be placed. Verbatim boolean beyond that, no
    -- negotiation: the server decides and answers on the next push.
    TriggerServerEvent("cordon:queue", queueIntent)
    push()
end

-- A local event so the gamemode's own client script -- or a deployment that
-- stripped `input.actions` -- can still drive the toggle.
AddEventHandler("cordon:queue:toggle", function()
    CordonMatch.toggleQueue()
end)

local function registerJoinKey()
    if type(RegisterKeyMapping) ~= "function" then
        Open77.log.warn("cordon HUD: RegisterKeyMapping unavailable, joining is event-only")
        return
    end
    local ok, effective = RegisterKeyMapping({
        id = "cordon.join",
        name = "Cordon - Join the next match",
        key = CordonHudStrings.keys.join,
        onPressed = function() CordonMatch.toggleQueue() end,
    })
    if ok then
        -- The EFFECTIVE key, not the default: the player may have rebound it in
        -- Pause > Settings > KEY BINDINGS, and a hint that names the wrong key
        -- is worse than no hint.
        joinKey = tostring(effective)
    else
        Open77.log.warn("cordon HUD: join key refused (" .. tostring(effective)
            .. ") -- check the input.actions permission")
    end
end

-- The engine raises this after any register / rebind / reset, so a hint painted
-- with the old key is corrected without waiting for a reconnect.
AddEventHandler("open77:keybinds:changed", function()
    if Open77.input ~= nil and Open77.input.keyFor ~= nil then
        local ok, key = pcall(Open77.input.keyFor, "cordon.join")
        if ok and type(key) == "string" and #key > 0 then joinKey = key end
    end
    push()
end)

-- ---------------------------------------------------------------------------
-- Attach
-- ---------------------------------------------------------------------------

function CordonMatch.attach(target, table_)
    page = target
    strings = table_
    ready = false

    page:on("cordon:ready", function()
        TriggerEvent("cordon:consumables:requestKeys")
        ready = true
        page:send("cordon:strings", strings)
        -- Ask for a snapshot rather than waiting up to 500 ms for the next
        -- scheduled one. A HUD that is blank for half a second on every
        -- reconnect looks broken to the person it just happened to.
        TriggerServerEvent("cordon:requestState")
        push()
    end)

    registerJoinKey()

    CreateThread(function()
        while page ~= nil do
            -- Only phases with a running clock need interpolation. `staging`
            -- counts down to the drop, `deploy` to the placement, `live` and
            -- `extraction` to the next closure, and `resolved` counts the
            -- standings interval down to the next match -- a frozen number
            -- there reads as a hung server rather than as a pause.
            CordonInventory.poll()
            if state ~= nil then push() end
            -- 10 Hz. Enough for a clock quoted in seconds; far too slow to be a
            -- frame cost. Per-frame work never goes through a Lua tick -- that
            -- is what `Open77.anchors` and the plugin projection exist for, and
            -- it is why nothing on this HUD follows a world object.
            Wait(100)
        end
    end)
end

function CordonMatch.detach()
    page, state, strings = nil, nil, nil
    ready = false
    queueIntent = false
    anchoredPhaseMs, anchoredCountdownMs, anchoredCloseMs = 0, 0, 0
    if type(Open77.input) == "table" and Open77.input.unregisterKeyMapping ~= nil then
        pcall(Open77.input.unregisterKeyMapping, "cordon.join")
    end
end
