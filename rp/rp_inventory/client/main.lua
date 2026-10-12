-- rp_inventory / client: the /inv panel page and the ALT+click actions.
--
-- The client decides nothing. The panel is a WebUI page (web/index.html) created at start and
-- left visible with an empty, transparent document (the proven pattern: a hidden-to-visible
-- surface did not reliably repaint, wiki/webui.md); the page draws itself when the server pushes
-- a state through rp_inventory:panel and clears itself on { open = false } or its own close.
-- Every click on the page becomes a rp_inventory:intent the server re-validates and answers
-- with a fresh state. The ALT+click actions send the canonical target id to the server, which
-- re-checks distance, life, weight and ownership before moving anything.
--
-- Focus (world-interaction row B7, docs/world-interaction/b7-ui.md). There is one focus slot in
-- the whole client, and a focused page takes the keyboard from chat and push-to-talk. So:
--   * browsing takes the CURSOR only: chat, voice and movement keys stay with the game;
--   * the keyboard is taken only while the count field is being typed in (page "typing");
--   * the panel never opens over another menu that holds the keyboard (a kit dialog, the chat):
--     it gives up and the server says so in chat;
--   * every exit releases: the page's close, the server's { open = false }, the pause key,
--     another surface taking the focus (the panel closes rather than fight for it), the
--     session ending, this resource stopping, and a focus that never arrived;
--   * a watchdog releases any focus this page still holds while closed.

local RESOURCE = GetCurrentResourceName()
local Config = RpInventoryConfig or {}
local FOCUS_GRACE_S = (Config.panelFocusGraceMs or 3000) / 1000

local page = nil          -- the WebUI surface, or nil when it could not be created
local pageReason = nil    -- why create() refused, for the chat fallback
local pageReady = false   -- the page raised "ready"
local isOpen = false      -- the panel is shown and holds (or is taking) the cursor
local typing = false      -- the count field has the caret: keyboard taken too
local focusSeen = false   -- hasFocus() answered true at least once since the panel opened
local openedAt = 0        -- monotonic seconds when the panel opened
local lastState = nil     -- the last state shown, replayed when the page document reloads
local wantOpen = false    -- the server's latest word: a state (true) or { open = false } (false)
local opening = false     -- an open is waiting for another menu to release the keyboard

local function now()
    return Open77.time.monotonic()
end

local function send(name, payload)
    if page and pageReady then page:send(name, payload or {}) end
end

-- Idempotent: safe from every path, any number of times. setFocus(false, false) releases only
-- when this page holds the slot, so it can never take focus away from another menu.
local function doClose(reason, tellServer)
    local wasOpen = isOpen
    isOpen, typing, focusSeen, wantOpen = false, false, false, false
    lastState = nil
    if page then
        page:setFocus(false, false)
        send("close", {})
    end
    if tellServer and wasOpen then
        TriggerServerEvent("rp_inventory:intent", { action = "close", reason = reason })
    end
end

local function applyFocus()
    if not page or not isOpen then return end
    if typing then
        page:setFocus(true, true)    -- the count field: keyboard and cursor
    else
        page:setFocus(false, true)   -- browsing: the cursor only, the game keeps the keyboard
    end
end

-- Another WebUI owns the keyboard (Open77.input.isCaptured, permission input.actions). Unknown
-- (no permission, older client) counts as free: the focus watchdog still closes on a conflict.
local function keyboardTakenByOther()
    local ok, captured = pcall(Open77.input.isCaptured)
    return ok and captured == true
end

-- The B1 catalogue (client/catalogue.lua) describes the metadata a unit carries: the page
-- shows "durability 12/20" and the quality scale from it. Absent until the first download:
-- the page then shows the raw values.
local function enrich(container)
    if type(container) ~= "table" or type(container.entries) ~= "table" then return end
    if type(RpInvClientCatalogue) ~= "table" then return end
    for _, e in ipairs(container.entries) do
        local c = RpInvClientCatalogue.item(e.id)
        if type(c) == "table" and type(c.metadata) == "table" then
            local d = {}
            local dur = c.metadata.durability
            if type(dur) == "table" and type(dur.max) == "number" then d.durabilityMax = dur.max end
            local q = c.metadata.quality
            if type(q) == "table" then d.quality = { min = q.min, max = q.max, values = q.values } end
            if c.metadata.serial ~= nil then d.serial = true end
            e.def = d
        end
    end
end

local function render(state)
    enrich(state.pockets)
    enrich(state.stash)
    lastState = state
    send("state", state)
end

local function openNow(state)
    if not page then return end
    if not isOpen then
        isOpen, typing, focusSeen = true, false, false
        openedAt = now()
        applyFocus()
    end
    render(state)
end

-- Opens without ever stealing the keyboard from another menu: wait up to a second for it to
-- let go (the chat closing on the Enter that sent /inv), else give up and tell the server.
local function beginOpen(state)
    lastState = state
    wantOpen = true
    if isOpen then return render(state) end
    if not pageReady then return end              -- the ready handler opens it
    if opening then return end
    opening = true
    CreateThread(function()
        local tries = 0
        while keyboardTakenByOther() and tries < 10 and wantOpen do
            Wait(100)
            tries = tries + 1
        end
        opening = false
        if not wantOpen or not lastState then return end
        if keyboardTakenByOther() then
            wantOpen, lastState = false, nil
            TriggerServerEvent("rp_inventory:intent", { action = "blocked", reason = "panel_blocked" })
            return
        end
        openNow(lastState)
    end)
end

AddEventHandler("onClientResourceStart", function(name)
    if name ~= RESOURCE then return end
    -- Created VISIBLE with an empty, transparent document: the page draws only while a state is
    -- open (see the header). Created far ahead of the first /inv.
    local surface, reason = Open77.webui.create({
        entry = "web/index.html",
        layer = "menu",
        transparent = true,
        visible = true,
    })
    if not surface then
        pageReason = tostring(reason or "webui_unavailable")
        print("[rp_inventory] webui unavailable: " .. pageReason)
    else
        page = surface
        -- Raised on every document load (a reload of the surface included): idempotent.
        page:on("ready", function()
            pageReady = true
            if wantOpen and lastState then
                if isOpen then
                    applyFocus()
                    render(lastState)
                else
                    beginOpen(lastState)
                end
            else
                send("close", {})
            end
        end)
        -- Every page action: forwarded as-is (with the state seq it was made on); the server
        -- re-checks and answers with a fresh state.
        page:on("intent", function(payload)
            if not isOpen then return end
            if type(payload) ~= "table" or type(payload.action) ~= "string" then return end
            TriggerServerEvent("rp_inventory:intent", payload)
        end)
        -- The X button or Escape on the page.
        page:on("close", function()
            doClose("page", true)
        end)
        -- The count field took or lost the caret: keyboard only while typing.
        page:on("typing", function(payload)
            if not isOpen then return end
            local on = type(payload) == "table" and payload.on == true
            if on ~= typing then
                typing = on
                applyFocus()
            end
        end)
    end
    -- A fresh VM has no open panel: tell the server so it forgets any stale one.
    TriggerServerEvent("rp_inventory:intent", { action = "close" })
end)

-- Server -> page. { open = false } closes; anything else is the full state.
RegisterNetEvent("rp_inventory:panel", function(state)
    if type(state) ~= "table" then return end
    if state.open == false then
        doClose("server", false)
        return
    end
    if not page then
        -- No WebUI on this client: the server lists the pockets in chat instead.
        TriggerServerEvent("rp_inventory:intent", { action = "unavailable", reason = pageReason or "webui_unavailable" })
        return
    end
    beginOpen(state)
end)

-- Escape while browsing reaches the game (the page does not hold the keyboard) and is raised as
-- the pause key; while typing, a focused page may swallow it the same way. Either way: close.
AddEventHandler("open77:pauseKey", function()
    if isOpen then doClose("escape", true) end
end)

AddEventHandler("open77:session:ended", function()
    doClose("session_ended", false)
end)

-- The focus watchdog (four times a second, only reads unless something is wrong):
--   open and the focus moved to another surface -> close (never fight for it);
--   open and the focus never arrived within the grace -> close;
--   closed and this page still holds the focus -> release it.
CreateThread(function()
    while true do
        Wait(250)
        if page then
            local ok, has = pcall(function() return page:hasFocus() end)
            if ok then
                if isOpen then
                    if has then
                        focusSeen = true
                    elseif focusSeen then
                        doClose("focus_taken", true)
                    elseif now() - openedAt > FOCUS_GRACE_S then
                        doClose("focus_unavailable", true)
                    end
                elseif has then
                    page:setFocus(false, false)
                end
            end
        end
    end
end)

AddEventHandler("onClientResourceStop", function(name)
    if name ~= RESOURCE then return end
    if page then
        page:setFocus(false, false)
        page:destroy()
        page = nil
    end
    isOpen, typing, wantOpen, pageReady = false, false, false, false
end)

---------------------------------------------------------------------------
-- ALT+click actions on other players (open77_contextmenu)
---------------------------------------------------------------------------

local function menu(method, ...)
    local promise, dispatchError = Open77.exports.call("open77_contextmenu", method, ...)
    if not promise then return nil, dispatchError end
    return promise:await()
end

-- Only another network player: never yourself, never an NPC.
exports("rpInventoryIsOtherPlayer", function(ctx)
    local target = ctx and ctx.target
    if type(target) ~= "table" then return false end
    if target.playerId == nil then return false end
    if target.isLocalPlayer == true then return false end
    return true
end)

exports("rpInventoryGive", function(ctx)
    local target = ctx and ctx.target
    if type(target) ~= "table" or target.playerId == nil then return false end
    TriggerServerEvent("rp_inventory:giveMenu", target.playerId)
    return true
end)

exports("rpInventorySearch", function(ctx)
    local target = ctx and ctx.target
    if type(target) ~= "table" or target.playerId == nil then return false end
    TriggerServerEvent("rp_inventory:search", target.playerId)
    return true
end)

local function registerActions()
    local tokens, err = menu("registerPlayers", {
        {
            id = "rp_inventory_give",
            label = "Give item",
            description = "Hand something from your pockets. The server checks the 3 m and their weight.",
            group = "Inventory",
            icon = "interact",
            networked = true,
            distance = 3.0,
            order = 20,
            canInteract = "rpInventoryIsOtherPlayer",
            onSelect = "rpInventoryGive",
        },
        {
            id = "rp_inventory_search",
            label = "Search pockets",
            description = "Frisk a cuffed or surrendering player.",
            group = "Inventory",
            icon = "person",
            networked = true,
            distance = 3.0,
            order = 21,
            canInteract = "rpInventoryIsOtherPlayer",
            onSelect = "rpInventorySearch",
        },
    })
    if not tokens then
        print("[rp_inventory] context menu registration failed: " .. tostring(err))
        return
    end
    print("[rp_inventory] context menu actions registered")
end

-- Register on our own start and again when the context menu package restarts:
-- a stopped provider loses its registrations.
AddEventHandler("onClientResourceStart", function(name)
    if name == RESOURCE or name == "open77_contextmenu" then
        CreateThread(registerActions)
    end
end)
