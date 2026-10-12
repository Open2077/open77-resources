-- /traffic -- the operator's panel for the server-owned ambient traffic.
--
-- This file owns a surface and a transport, and nothing else: there is no
-- setting, no car and no reset in it. Every control the page offers becomes one
-- line of the restricted `traffic` command, submitted through
-- `open77:command:execute` -- the same path the chat box uses -- so the same
-- ACL check guards both, and this half cannot grant itself anything.
--
-- The command line is rebuilt here from a whitelist rather than forwarded, so
-- nothing the page typed reaches the command line. The page is corrected by
-- snapshots rather than by its own optimism: the server pushes
-- `open77_traffic:panel:data` for every state request, and this file asks for
-- one every two seconds while the panel is open. That cadence is also the
-- recovery path -- a dropped result cannot wedge a control, because the next
-- snapshot shows the truth, which is why there is no client-side timeout here.
--
-- A snapshot carries only the values in force. The setting declarations are
-- shared/config.lua, which this half loads too, so they reach the page once per
-- opening (`traffic:settings`) and every push after that is the server's
-- snapshot, forwarded as received.
local RESOURCE = GetCurrentResourceName()
-- The server's own channel, name and all: the panel is one transport in front
-- of one resource, and `open77_traffic:panel:open|data|result` is what the
-- server half pushes. There is no second spelling of it anywhere.
local CHANNEL = "open77_traffic:panel:"

local page, snapshot
local ready, open = false, false
-- The radius the operator last asked for: the panel's memory of a viewport, not
-- a generator setting. The server clamps it and echoes back the value it
-- actually used in `nearby.radius`, which is what this tracks.
local radius = 100
local openedAt, lastPollAt = 0, 0
local pollRefusals = 0
-- raw command line -> {operation, poll}, so an `open77:command:result` is only
-- ever read as the answer to a line this panel sent.
local inflight, refused = {}, {}

local POLL_SECONDS = 2
local WATCHDOG_SECONDS = 15 * 60
local MIN_RADIUS, MAX_RADIUS = 1, 500

local function now() return Open77.time.monotonic() end

-- The server's own order: group first, then the key's order inside it, so the
-- form reads the same as before the declarations stopped travelling.
local SETTING_KEYS = {}
for key in pairs(TrafficSettings) do SETTING_KEYS[#SETTING_KEYS + 1] = key end
table.sort(SETTING_KEYS, function(left, right)
    local a, b = TrafficSettings[left], TrafficSettings[right]
    if a.group ~= b.group then return a.group < b.group end
    if a.order ~= b.order then return a.order < b.order end
    return left < right
end)

-- What the page needs to render every control, minus the value. `defaults`
-- holds the declarations the server rewrote at start-up, which this copy of
-- config.lua cannot know; a default may be `false`, so it is not `and/or`-ed.
local function declarations(defaults)
    defaults = type(defaults) == "table" and defaults or {}
    local list = {}
    for index = 1, #SETTING_KEYS do
        local key = SETTING_KEYS[index]
        local spec = TrafficSettings[key]
        local default = defaults[key]
        if default == nil then default = spec.value end
        list[index] = {
            key = key,
            label = spec.label,
            description = spec.description,
            type = spec.type,
            min = spec.min,
            max = spec.max,
            unit = spec.unit,
            group = spec.group,
            default = default,
        }
    end
    return list
end

local function send(event, payload)
    if not page or not ready then return false, "not_ready" end
    -- Once per event name: a page that cannot receive is one bug, not a line of
    -- log per poll.
    local ok, reason = page:send("traffic:" .. event, payload or {})
    if ok == false and not refused[event] then
        refused[event] = true
        Open77.log.warn("traffic panel: " .. event .. " refused: " .. tostring(reason))
    end
    return ok, reason
end

-- `send` on its own never reaches the page, so the answer to a refused
-- submission is a result push. The page treats a missing answer as "still
-- working" and keeps polling, so this costs it nothing when it is wrong.
local function report(operation, message)
    send("result", {ok = false, operation = operation, message = tostring(message)})
end

local function close()
    open = false
    inflight = {}
    pollRefusals = 0
    if page then page:setFocus(false, false) end
    send("close")
end

-- ---------------------------------------------------------------------------
-- The command line
--
-- The whitelist IS the transport rule: the page may only ever produce these
-- lines, and a token that is not exactly one of them is refused here rather
-- than handed to a command parser that would have to be strict about
-- everything forever.
-- ---------------------------------------------------------------------------
local function token(value, limit)
    if type(value) ~= "string" then return nil end
    if #value == 0 or #value > limit then return nil end
    -- A token is one command-line word. Whitespace would silently become two
    -- words on the way in, so it is a refusal, not a trimming.
    if value:find("[%s%c]") then return nil end
    return value
end

local function radiusToken(value)
    local metres = tonumber(token(value, 8) or "")
    if not metres then return nil end
    if metres % 1 ~= 0 or metres < MIN_RADIUS or metres > MAX_RADIUS then return nil end
    return ("%d"):format(metres)
end

-- The keys are the server's, not this file's: a setting the panel was not told
-- about is not a setting it may write. The snapshot is the authority, and the
-- syntactic form is the fallback for the moment before one has arrived.
local function knownKey(key)
    local settings = snapshot and snapshot.settings
    if type(settings) ~= "table" then return true end
    return settings[key] ~= nil
end

local function normalise(payload)
    if type(payload) ~= "table" or type(payload.tokens) ~= "table" then return nil end
    local tokens = payload.tokens
    local count = #tokens
    if count < 1 or count > 4 then return nil end
    if token(tokens[1], 32) ~= "traffic" then return nil end

    local sub = tokens[2]
    if sub == nil then return {"traffic"} end
    sub = token(sub, 16)

    if sub == "open" and count == 2 then
        return {"traffic", "open"}
    end
    if sub == "state" and count == 3 then
        local metres = radiusToken(tokens[3])
        if not metres then return nil end
        return {"traffic", "state", metres}
    end
    if sub == "set" and count == 4 then
        local key = token(tokens[3], 48)
        local value = token(tokens[4], 32)
        if not key or not key:match("^[A-Za-z_][A-Za-z0-9_]*$") then return nil end
        -- Numbers in any notation the page may print, and words: the domain of
        -- a value (a range, a bound, true/false) belongs to the server's
        -- validation, not to this pattern.
        if not value or not value:match("^[%w%._%+%-]+$") then return nil end
        if not knownKey(key) then return nil end
        return {"traffic", "set", key, value}
    end
    if sub == "pattern" and count == 4 then
        local pattern = token(tokens[3], 8)
        if pattern ~= "default" and pattern ~= "stop" then return nil end
        local metres = radiusToken(tokens[4])
        if not metres then return nil end
        return {"traffic", "pattern", pattern, metres}
    end
    if sub == "panic" and count == 3 then
        local metres = radiusToken(tokens[3])
        if not metres then return nil end
        return {"traffic", "panic", metres}
    end
    if sub == "reset" and count == 3 and tokens[3] == "confirm" then
        return {"traffic", "reset", "confirm"}
    end
    return nil
end

local function submit(tokens, poll)
    local raw = table.concat(tokens, " ")
    inflight[raw] = {operation = tokens[2] or "open", poll = poll == true}
    local sent, reason = TriggerServerEvent("open77:command:execute", table.unpack(tokens))
    if sent == false then
        inflight[raw] = nil
        return false, tostring(reason or "not_sent")
    end
    return true
end

local function poll()
    if not open then return end
    lastPollAt = now()
    local sent, reason = submit({"traffic", "state", ("%d"):format(radius)}, true)
    -- A poll the transport refuses is worth saying once: if it persists the
    -- panel is showing stale numbers, and silence would make them look live.
    if not sent and pollRefusals < 1 then
        pollRefusals = pollRefusals + 1
        report("state", reason)
    end
end

local function show()
    if not open or not ready then return end
    -- A refused push leaves an empty full-screen surface behind; focusing it
    -- locked mouse and keyboard with nothing on screen to close it. Said every
    -- time, because each one is an operator left without a panel.
    local sent, reason = send("settings", declarations(snapshot and snapshot.defaults))
    if sent == true then sent, reason = send("open", snapshot) end
    if sent ~= true then
        Open77.log.warn("traffic panel: not opened, the page refused the snapshot: " .. tostring(reason))
        close()
        return
    end
    local ok, focusReason = page:setFocus(true, true)
    if ok == false then
        Open77.log.warn("traffic panel: focus refused: " .. tostring(focusReason))
        close()
    end
end

local function createPage()
    if page then return true end
    local reason
    -- Native hidden surfaces currently fail to upload their first frame after
    -- being shown, so this one is created visible and CSS is the only
    -- visibility authority (same convention as /admin and the cyberlab panel).
    page, reason = WebUI.create({entry = "web/index.html", layer = "menu", width = 1920,
        height = 1080, fps = 30, zIndex = 722, transparent = true, visible = true})
    if not page then
        Open77.log.error("traffic panel: WebUI failed: " .. tostring(reason))
        return false
    end

    page:on("traffic:ready", function()
        ready = true
        show()
    end)
    page:on("traffic:close", close)
    page:on("traffic:refresh", poll)
    page:on("traffic:command", function(payload)
        if not open then return end
        local tokens = normalise(payload)
        if not tokens then
            report("command", "invalid_command")
            return
        end
        -- A bare `/traffic` from the page is a refresh; only the chat box has a
        -- reason to send one.
        if tokens[2] == nil then tokens = {"traffic", "state", ("%d"):format(radius)} end
        if tokens[2] == "state" then
            radius = tonumber(tokens[3])
            lastPollAt = now()
        elseif tokens[2] == "pattern" or tokens[2] == "panic" then
            -- A sweep is asked for at the radius it is aimed at, which is also
            -- the viewport the table below it will describe next.
            radius = tonumber(tokens[#tokens])
        end
        local sent, reason = submit(tokens, false)
        if not sent then report(tokens[2], reason) end
    end)
    -- The page's own failure channel. It carries log lines, never commands: a
    -- page that dies mid-render reports nothing at all otherwise.
    page:on("traffic:diag", function(payload)
        if type(payload) == "table" then
            Open77.log.warn("traffic panel: " .. tostring(payload.message or "unknown page error"):sub(1, 500))
        end
    end)

    CreateThread(function()
        while page do
            Wait(500)
            if open then
                if now() - openedAt > WATCHDOG_SECONDS then
                    close()
                elseif now() - lastPollAt >= POLL_SECONDS then
                    poll()
                end
            end
        end
    end)
    return true
end

-- ---------------------------------------------------------------------------
-- The server's half
-- ---------------------------------------------------------------------------
RegisterNetEvent(CHANNEL .. "open", function(payload)
    if type(payload) ~= "table" then return end
    snapshot = payload
    open, openedAt, lastPollAt = true, now(), 0
    inflight, pollRefusals = {}, 0
    if not createPage() then
        close()
        return
    end
    show()
    poll()
end)
RegisterNetEvent(CHANNEL .. "data", function(payload)
    if not open or type(payload) ~= "table" then return end
    snapshot = payload
    -- The server clamps the radius and reports what it used; following it here
    -- keeps the poll asking for the viewport the table is actually showing.
    local metres = type(payload.nearby) == "table" and payload.nearby.radius
    if type(metres) == "number" and metres % 1 == 0
        and metres >= MIN_RADIUS and metres <= MAX_RADIUS then
        radius = metres
    end
    send("data", payload)
end)
RegisterNetEvent(CHANNEL .. "result", function(payload)
    if type(payload) ~= "table" then return end
    send("result", payload)
end)
RegisterNetEvent(CHANNEL .. "close", close)

-- Every command result reaches every client resource, including chat's own
-- commands. Only a line this panel sent is interesting here, and only a refusal
-- is worth repeating to the page: an accepted line is answered by the resource
-- itself, with a result and a fresh snapshot.
RegisterNetEvent("open77:command:result", function(raw, accepted, message)
    raw, message = tostring(raw or ""), tostring(message or "")
    -- The dispatcher acknowledges queueing immediately; the useful answer is a
    -- second result. Showing both would double every line in the panel.
    if accepted and message:match("^queued by ") then return end
    local entry = inflight[raw]
    if not entry then return end
    inflight[raw] = nil
    if accepted == true then return end
    if entry.poll then
        if pollRefusals < 1 then
            pollRefusals = pollRefusals + 1
            report("state", message)
        end
        return
    end
    report(entry.operation, message)
end)

-- Escape: the plugin consumes Escape before the focused page's own handler can
-- run, so this event -- not the page -- is the path that actually closes a
-- focused surface in a live session. The page still handles Escape for the
-- cases where it does receive the key.
AddEventHandler("open77:pauseKey", function()
    if open then close() end
end)

AddEventHandler("onClientResourceStop", function(name)
    if name ~= RESOURCE then return end
    close()
    page, snapshot, ready, open = nil, nil, false, false
    inflight, refused = {}, {}
end)
