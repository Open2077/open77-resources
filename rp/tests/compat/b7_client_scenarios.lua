-- tests/compat/b7_client_scenarios.lua: the rp_inventory panel's CLIENT focus contract (row B7).
--
-- Loaded after fakehost.lua with REPO set. It runs the REAL rp_inventory client scripts
-- (shared/items.lua, shared/schema.lua, client/main.lua, client/catalogue.lua) against a fake
-- WebUI surface that models the platform's ONE focus slot (wiki/webui.md: the last setFocus with
-- keyboard or cursor takes it from any holder; setFocus(false, false) releases only for the
-- holder; destroy releases), and checks every exit path releases it. A fake cannot show what the
-- game client does with the keys: this is the contract, not in-game evidence.

local C = {}          -- the fake client: focus slot, server events, capture flag
local scenarios = {}

local function newPage()
    local p = { handlers = {}, sent = {}, kb = false, cur = false, destroyed = false, refuseFocus = false }
    function p:on(name, fn) self.handlers[name] = fn return #self.handlers end
    function p:send(name, payload)
        self.sent[#self.sent + 1] = { name = name, payload = payload }
        return true
    end
    function p:setFocus(keyboard, cursor)
        if keyboard or cursor then
            if self.refuseFocus then return false end
            C.owner, self.kb, self.cur = self, keyboard == true, cursor == true
            C.focusCalls[#C.focusCalls + 1] = (keyboard and "K" or "-") .. (cursor and "C" or "-")
        elseif C.owner == self then
            C.owner, self.kb, self.cur = nil, false, false
            C.focusCalls[#C.focusCalls + 1] = "release"
        end
        return true
    end
    function p:hasFocus() return C.owner == self end
    function p:show() return true end
    function p:hide() if C.owner == self then C.owner = nil end return true end
    function p:destroy()
        self.destroyed = true
        if C.owner == self then C.owner = nil end
        return true
    end
    return p
end

local function boot()
    C.page, C.owner, C.server, C.captured, C.focusCalls = nil, nil, {}, false, {}
    function TriggerServerEvent(name, payload)
        C.server[#C.server + 1] = { name = name, payload = payload }
        return true
    end
    Open77.webui = { create = function() C.page = newPage() return C.page end }
    Open77.input = { isCaptured = function() return C.captured end }
    local root = REPO .. "/rp_inventory/"
    H.boot("rp_inventory", { root .. "shared/items.lua", root .. "shared/schema.lua", root .. "client/main.lua",
        root .. "client/catalogue.lua" }, "none", {}, 0)
    H.emit("onClientResourceStart", "rp_inventory")
    H.run(0.5)
    C.page.handlers.ready()                      -- the document loaded
    H.run(0.5)
end

local function push(state)
    for _, fn in ipairs(H.handlers["rp_inventory:panel"] or {}) do fn(state) end
end
local function state(seq) return { open = true, seq = seq or 1, pockets = { id = 7, entries = {} } } end
local function focusStr()
    if C.owner == nil then return "none" end
    if C.owner == C.page then return (C.page.kb and "K" or "-") .. (C.page.cur and "C" or "-") end
    return tostring(C.owner)
end
local function lastIntent()
    for i = #C.server, 1, -1 do
        local e = C.server[i]
        if e.name == "rp_inventory:intent" then
            return tostring(e.payload.action) .. (e.payload.reason and (":" .. e.payload.reason) or "")
        end
    end
    return "none"
end
local function lastSent()
    local e = C.page.sent[#C.page.sent]
    return e and e.name or "none"
end
local function event(name, ...)
    for _, fn in ipairs(H.handlers[name] or {}) do fn(...) end
end

function scenarios.client_focus()
    local out = {}
    boot()
    out.boot_intent = lastIntent()                       -- a fresh VM tells the server to forget
    out.boot_focus = focusStr()

    -- Browsing holds the cursor only; typing adds the keyboard; leaving the field gives it back.
    push(state(1))
    H.run(0.5)
    out.open_focus = focusStr()
    out.open_sent = lastSent()
    C.page.handlers.typing({ on = true })
    out.typing_focus = focusStr()
    C.page.handlers.typing({ on = false })
    out.typed_focus = focusStr()

    -- 1. the page's own close (X, Escape while typing)
    C.page.handlers.close()
    out.page_close = focusStr() .. " " .. lastIntent() .. " " .. lastSent()

    -- 2. the server's { open = false } (death, resource stop on the server, closePanel)
    push(state(2)); H.run(0.5)
    push({ open = false })
    out.server_close = focusStr() .. " " .. lastSent()

    -- 3. the pause key (Escape while browsing reaches the game)
    push(state(3)); H.run(0.5)
    event("open77:pauseKey")
    out.pause_close = focusStr() .. " " .. lastIntent()

    -- 4. another surface (the chat, a kit dialog) takes the focus: close, never fight back
    push(state(4)); H.run(0.5)
    C.owner = "chat"
    H.run(0.5)
    out.taken = focusStr() .. " " .. lastIntent()
    C.owner = nil                                         -- the chat closes
    H.run(1)
    out.taken_no_regrab = focusStr()

    -- 5. opening while another menu holds the keyboard: wait a second, then give up
    C.captured = true
    local before = #C.focusCalls
    push(state(5))
    H.run(3)          -- ten 100 ms polls; the fake scheduler steps in 250 ms
    out.blocked = focusStr() .. " " .. lastIntent() .. " focusCalls=" .. (#C.focusCalls - before)
    -- ...and when it lets go in time, open normally
    push(state(6))
    H.run(0.25)
    C.captured = false
    H.run(1)
    out.unblocked = focusStr()
    push({ open = false })

    -- 6. a focus that never arrives (surface cannot present): closed after the grace
    C.page.refuseFocus = true
    push(state(7))
    H.run(4)
    out.never_focused = focusStr() .. " " .. lastIntent()
    C.page.refuseFocus = false

    -- 7. a stray focus while closed is released by the watchdog
    C.owner, C.page.cur = C.page, true
    H.run(0.5)
    out.stray = focusStr()

    -- 8. the page document reloads: closed -> told to stay clear; open -> state and focus again
    C.page.handlers.ready()
    out.reload_closed = lastSent()
    push(state(8)); H.run(0.5)
    C.owner = nil                                         -- a reload dropped the browser-side focus
    C.page.handlers.ready()
    out.reload_open = focusStr() .. " " .. lastSent()

    -- 9. the session ends
    event("open77:session:ended", "disconnect")
    out.session_end = focusStr() .. " " .. lastSent()

    -- 10. intents from a closed panel are not forwarded
    local n = #C.server
    C.page.handlers.intent({ action = "store", item = "scrap", count = 1 })
    out.closed_intent_forwarded = tostring(#C.server - n)

    -- 11. the resource stops while open
    push(state(9)); H.run(0.5)
    event("onClientResourceStop", "rp_inventory")
    out.stop = focusStr() .. " destroyed=" .. tostring(C.page.destroyed)
    return out
end

function RUN_SCENARIO(name)
    local scenario = assert(scenarios[name], "unknown scenario " .. tostring(name))
    local out = scenario()
    local lines = {}
    for k, v in pairs(out) do lines[#lines + 1] = k .. "=" .. tostring(v) end
    table.sort(lines)
    return table.concat(lines, "\n")
end
