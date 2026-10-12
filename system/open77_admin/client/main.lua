-- open77_admin -- client half.
--
-- This file holds NO authority and asserts none. Its jobs are:
--
--   * announce that it exists, and what its client build can do;
--   * own the CEF surface and, above all, never trap the player's input;
--   * turn a click into a COMMAND LINE and send it through
--     `open77:command:execute`, which is the only channel on this platform
--     that is checked against the ACL;
--   * apply the two things that are genuinely client-side -- noclip, and the
--     vehicle performance governor -- when an ACL-checked server command tells
--     it to.
--
-- It is worth being explicit about the last one. A player who has patched
-- their own client can already fly; delegation is not what stops them. What
-- the ACL protects is everything an operator can do to SOMEBODY ELSE, and
-- every one of those is a server-side command.

local Config = Open77AdminConfig
local Catalog = Open77AdminCatalog

local RESOURCE = GetCurrentResourceName()

local page
local pageReady = false
local open = false
local access = { commands = {} }
local openedAtMs = 0

local MAX_OPEN_MS = 15 * 60 * 1000
local WATCHDOG_MS = 1000

local function nowMs()
    return math.floor(Open77.time.monotonic() * 1000)
end

--- Send one message to the page, and SAY SO when the host refuses it.
---
--- `page:send` answers `false, "invalid_webui_event_payload"` when the payload
--- is past the host's 1024-node ceiling (see "What this file has to fit inside"
--- below). Throwing that answer away was the most expensive line in this file:
--- an over-sized boot payload then looks exactly like a page that decided not
--- to render, with nothing in the log to say a message was ever dropped. One
--- warning per event name, because a channel that is too big is too big on
--- every push and would otherwise fill the log at the poll rate.
local sendRefused = {}

local function send(name, payload)
    if page == nil or not pageReady then return end
    local sent, reason = page:send(name, payload or {})
    if sent == false and not sendRefused[name] then
        sendRefused[name] = true
        Open77.log.error("admin: the host refused the '" .. tostring(name) .. "' payload ("
            .. tostring(reason) .. "); it is too large for the surface and the page never saw it")
    end
end

-- ---------------------------------------------------------------------------
-- Capability probe
--
-- There is no version table and no capability registry on this platform; the
-- only supported probe is `type(fn) == "function"`. Both halves of a pair are
-- checked, never one: a half-present API would leave the "switch the cap off"
-- path unable to undo what the "switch it on" path did.
--
-- The governor landed after 2.31.0+op77.7, which is the client most people are
-- running. On that build the field is simply nil, a bare call would raise, and
-- a handler that dies takes the panel down over a feature nobody asked about.
-- ---------------------------------------------------------------------------
local function governorApi()
    local vehicles = Open77 ~= nil and Open77.vehicles or nil
    if type(vehicles) ~= "table" then return nil end
    if type(vehicles.setPerformance) ~= "function" then return nil end
    if type(vehicles.clearPerformance) ~= "function" then return nil end
    if type(vehicles.setPerformanceClass) ~= "function" then return nil end
    if type(vehicles.clearPerformanceClass) ~= "function" then return nil end
    return vehicles
end

local function travelApi()
    local travel = Open77 ~= nil and Open77.travel or nil
    if type(travel) ~= "table" then return nil end
    if type(travel.setNoclip) ~= "function" then return nil end
    return travel
end

--- Map-pick travel landed after the noclip pair, so it is probed separately:
--- an older client has `Open77.travel` but no `setMapPick`, and folding it into
--- `travelApi` would take noclip down with it.
local function mapPickApi()
    local travel = Open77 ~= nil and Open77.travel or nil
    if type(travel) ~= "table" then return nil end
    if type(travel.setMapPick) ~= "function" then return nil end
    return travel
end

local absenceNoted = false
local function noteGovernorAbsence()
    if absenceNoted then return end
    absenceNoted = true
    -- Info, not error. An operator on the old client loses nothing he had.
    Open77.log.info(
        "vehicle governor not present in this client build; the Vehicles tuning panel will show as unavailable")
end

local function capabilities()
    return {
        governor = governorApi() ~= nil,
        travel = travelApi() ~= nil,
        mapPick = mapPickApi() ~= nil,
        panel = page ~= nil,
    }
end

local function announce()
    local sent, reason = TriggerServerEvent("open77_admin:hello", capabilities())
    if not sent then
        Open77.log.warn("admin: hello not sent: " .. tostring(reason))
    end
end

-- ---------------------------------------------------------------------------
-- Focus discipline
--
-- A focused surface that never releases leaves the player with no cursor and
-- no gameplay. That is a known failure mode in this codebase, so the release
-- is idempotent, drops focus FIRST, and is reachable from five independent
-- paths: the page's own control, the plugin's pause key, resource stop, a
-- server-sent close, and a watchdog.
--
-- The pause key matters most. The plugin SWALLOWS Escape in the window
-- procedure, so a focused page's own Escape handler never fires in a live
-- session; `open77:pauseKey` is raised instead and is the path that actually
-- runs.
-- ---------------------------------------------------------------------------
-- Forward declaration. `takeFocus` below asks every resource to republish its
-- chat suggestions so the Console tab has a palette; the body lives further
-- down, next to the handler that consumes them.
local requestPalette

local function releaseFocus(why)
    if page ~= nil then
        page:setFocus(false, false)
        page:send("admin:closed", {})
    end
    if open then Open77.log.info("admin: panel closed (" .. tostring(why) .. ")") end
    open = false
end

local function takeFocus()
    if access.commands.adminfull ~= true then return end
    if page == nil then
        Open77.log.error("admin: no surface; /admin cannot open")
        return
    end
    if open then return end
    -- The single most useful line this file can write. `send` drops everything
    -- until the page has reported ready, but `setFocus` below does NOT: an
    -- unready page therefore gets the mouse and shows nothing, which is
    -- indistinguishable from a rendering fault unless somebody says so.
    if not pageReady then
        Open77.log.error(
            "admin: /admin opened before the page reported ready -- the surface will take the "
            .. "mouse and render nothing. The page script did not finish loading.")
    end
    open = true
    openedAtMs = nowMs()
    -- `admin:show`, not `admin:open`: the server's snapshot arrives on
    -- `admin:open` a moment earlier, and one name carrying two meanings is how
    -- a payload ends up overwritten by an empty table.
    send("admin:show", {})
    requestPalette()
    local focused, reason = page:setFocus(true, true)
    if not focused then
        Open77.log.warn("admin: focus refused (" .. tostring(reason) .. ")")
    end
end

-- ---------------------------------------------------------------------------
-- The command channel
--
-- Everything the panel does goes through here. The server derives
-- `command.<tokens[1]>` from the first token and resolves it against the
-- caller's authenticated identity before any handler runs, so this function is
-- not a bypass of anything -- it is the same path the chat box uses.
-- ---------------------------------------------------------------------------
local pending = {}

local function execute(tokens, tag)
    if type(tokens) ~= "table" or tokens[1] == nil then return false end
    local clean = {}
    for index = 1, #tokens do
        local token = tostring(tokens[index] or "")
        -- The transport caps a token at 256 UTF-8 bytes and rejects control
        -- characters and an over-long line outright. Refusing here means the
        -- operator sees why instead of nothing happening.
        if #token > 256 then token = token:sub(1, 256) end
        token = token:gsub("[%c]", " ")
        if token ~= "" then clean[#clean + 1] = token end
    end
    if #clean == 0 or #clean > 32 then return false end

    local raw = table.concat(clean, " ")
    if tag ~= nil then pending[raw] = tag end

    local sent, reason = TriggerServerEvent("open77:command:execute", table.unpack(clean))
    if not sent then
        send("admin:result", { raw = raw, ok = false, message = tostring(reason or "not sent") })
        return false
    end
    return true
end

--- Split a typed console line into tokens, honouring double quotes so a
--- destination label or a ban reason can contain spaces.
local function tokenise(line)
    local tokens, buffer, quoted = {}, {}, false
    for index = 1, #line do
        local char = line:sub(index, index)
        if char == '"' then
            quoted = not quoted
        elseif char == " " and not quoted then
            if #buffer > 0 then tokens[#tokens + 1] = table.concat(buffer) buffer = {} end
        else
            buffer[#buffer + 1] = char
        end
    end
    if #buffer > 0 then tokens[#tokens + 1] = table.concat(buffer) end
    return tokens
end

-- Every command result reaches every client resource that registered the
-- event, so this also sees chat's own commands. That is fine and useful: the
-- panel's log shows the whole session, and `pending` is only used to route a
-- result back to the control that produced it.
RegisterNetEvent("open77:command:result", function(raw, accepted, message)
    raw, message = tostring(raw or ""), tostring(message or "")
    -- The dispatcher acknowledges queueing immediately; the useful answer is a
    -- second result. Showing both would double every line in the log.
    if accepted and message:match("^queued by ") then return end
    local tag = pending[raw]
    pending[raw] = nil
    send("admin:result", { raw = raw, ok = accepted == true, message = message, tag = tag })
end)

-- ---------------------------------------------------------------------------
-- The console palette
--
-- Harvested from `chat:addSuggestions`, which every resource publishes on
-- `chat:ready`. That gives the Console tab a live, complete command list --
-- with help text -- contributed by every resource on the server, coupled to
-- none of them.
--
-- Three things about the shape of this, all of them the host limits described
-- further down rather than taste:
--
--   * ONE `chat:ready` produces a dozen deliveries inside a few milliseconds,
--     one per resource. Publishing on each meant rebuilding and re-sending the
--     whole palette a dozen times per panel open, so the deliveries are
--     coalesced and published once.
--   * The palette is SENT IN WINDOWS. A command is five nodes, and thirty
--     resources currently contribute about 150 of them: past the surface's
--     1024-node ceiling in one message, at which point the page is told
--     nothing at all and the Console tab shows an empty palette.
--   * The ORDER is the page's problem. Sorting 150 entries in Lua is ~1100
--     calls into a comparator inside one uninterruptible `table.sort`, which
--     is most of a resume's budget and grows with every command anybody adds.
--     Sorting them in JavaScript is free.
-- ---------------------------------------------------------------------------
local palette = {}
local paletteDirty = false
local palettePublishing = false

--- Commands carried by one `admin:palette` message. An entry is `{command,
--- help}`, so six nodes with its array index: sixty is 364.
local kPaletteWindow = 60

--- Milliseconds of quiet before the coalesced palette goes out. Long enough to
--- swallow a whole `chat:ready` answer, short enough that an operator who opens
--- the Console tab immediately does not notice.
local kPaletteSettleMs = 250

--- `requestPalette` is forward-declared above `takeFocus`, which calls it.
--- Declaring it here with `local function` would make the reference inside
--- `takeFocus` a GLOBAL lookup -- nil at runtime, and a crash the moment
--- somebody opens the panel. luac does not catch that.
function requestPalette()
    TriggerServerEvent("chat:ready")
end

local function publishPalette()
    if page == nil or not pageReady then return end
    -- Snapshot first, with NO yield inside this loop: `chat:addSuggestions` can
    -- run between two resumes and add a key, and adding a key to a table that
    -- is being walked by `next` is undefined in Lua.
    local flat = {}
    for _, entry in pairs(palette) do flat[#flat + 1] = entry end

    local total = #flat
    local offset = 0
    repeat
        local items = {}
        local last = math.min(offset + kPaletteWindow, total)
        for index = offset + 1, last do items[#items + 1] = flat[index] end
        send("admin:palette", {
            offset = offset, total = total, commands = items, done = last >= total,
        })
        offset = last
        if offset < total then Wait(0) end
    until offset >= total
end

RegisterNetEvent("chat:addSuggestions", function(list)
    if type(list) ~= "table" then return end
    for _, suggestion in ipairs(list) do
        if type(suggestion) == "table" and type(suggestion.command) == "string" then
            -- `parameters` is deliberately dropped. The page renders the name
            -- and the help line and nothing else, and the field is an arbitrary
            -- nested table contributed by another resource -- unbounded input
            -- on a message with a hard node ceiling.
            palette[suggestion.command] = {
                command = suggestion.command,
                help = suggestion.help ~= nil and tostring(suggestion.help) or nil,
            }
        end
    end

    paletteDirty = true
    if palettePublishing then return end
    palettePublishing = true
    CreateThread(function()
        while paletteDirty do
            paletteDirty = false
            Wait(kPaletteSettleMs)
        end
        palettePublishing = false
        publishPalette()
    end)
end)

-- ---------------------------------------------------------------------------
-- Server -> client: data, travel, governor
-- ---------------------------------------------------------------------------
RegisterNetEvent("open77_admin:open", function()
    takeFocus()
end)

RegisterNetEvent("open77_admin:data", function(channel, payload)
    if channel == "access" and type(payload) == "table" then
        access = payload
        if open and not access.commands.adminfull then releaseFocus("ACL revoked") end
    end
    send("admin:" .. tostring(channel), payload or {})
end)

-- ---------------------------------------------------------------------------
-- Map-pick travel
--
-- The world map's own custom-waypoint native is the only cursor -> world
-- conversion in the build, and `client/redscript/Open77MapTravel.reds` borrows
-- it: a double click on the map resolves a world point and the plugin publishes
-- it here as `open77:map:picked`. Nothing about that is authoritative. This
-- file turns the point into the same command line an operator could have typed,
-- and the server's ACL decides exactly as it would have then.
--
-- `mapPickCommand` is the word the SERVER said armed it, not a constant. A
-- command and its alias hold separate permissions on this platform, so echoing
-- back the wrong one would arm a gesture the ACL then refuses.
-- ---------------------------------------------------------------------------
local mapPickCommand = nil

local function setMapPick(enable, command)
    local travel = mapPickApi()
    if travel == nil then
        Open77.log.warn(
            "admin: map-pick travel is not present in this client build; the double-click "
            .. "gesture cannot be armed (needs Open77.travel.setMapPick)")
        return
    end
    local ok, reason = travel.setMapPick(enable == true)
    if not ok then
        Open77.log.warn("admin: setMapPick refused: " .. tostring(reason))
        return
    end
    mapPickCommand = enable and command or nil
end

--- A world point the operator double-clicked on the vanilla map.
---
--- Guarded on `mapPickCommand` rather than trusted: the plugin only publishes
--- while armed, but the arm lives in two processes and this side is the one
--- that knows which command word to spend.
AddEventHandler("open77:map:picked", function(x, y, z)
    if mapPickCommand == nil then return end
    local px, py, pz = tonumber(x), tonumber(y), tonumber(z)
    if px == nil or py == nil or pz == nil then
        Open77.log.warn("admin: map pick carried an unreadable point; ignored")
        return
    end
    -- Six decimals, which is what the plugin sent. Re-formatted rather than
    -- forwarded verbatim because the strings went through `tonumber` above, and
    -- `tostring` would put them back as Lua's `%.14g` -- a coordinate like
    -- -667.14 comes out as `-667.14000000000001`, which is the same metre and
    -- an unreadable audit line.
    execute({
        mapPickCommand,
        string.format("%.6f", px),
        string.format("%.6f", py),
        string.format("%.6f", pz),
    }, "mapPick")
end)

--- Delegated local capabilities. The ACL decided on the server; this applies.
RegisterNetEvent("open77_admin:travel", function(action, value, detail)
    -- Map pick has its own probe: it is newer than the noclip pair, and a
    -- client that has one may not have the other.
    if action == "mapPick" then
        setMapPick(value == true, tostring(detail or "admin.self.maptravel"))
        return
    end
    local travel = travelApi()
    if travel == nil then
        Open77.log.warn("admin: travel API unavailable on this client build")
        return
    end
    if action == "noclip" then
        local ok, reason = travel.setNoclip(value == true)
        local active = type(travel.isNoclip) == "function" and travel.isNoclip() == true
        if not ok then
            Open77.log.warn("admin: setNoclip refused: " .. tostring(reason))
            local explanations = {
                exit_vehicle_before_noclip = "Exit the vehicle before enabling noclip.",
                leave_workspot_or_animation_before_noclip = "Finish the seated animation or interaction before enabling noclip.",
                player_not_alive_in_world = "Noclip is available once you are alive and in the world.",
                noclip_owned_by_other_resource = "Another resource is currently controlling noclip.",
            }
            local message = explanations[reason] or ("Noclip refused: " .. tostring(reason))
            TriggerEvent("open77_admin:notice", { title = "NOCLIP", text = message })
            TriggerEvent("open77:command:result", "admin.self.noclip", false, message)
        end
        TriggerServerEvent("open77_admin:noclipState", active)
        send("admin:self", { noclip = active })
    elseif action == "noclipSpeed" then
        local speed = tonumber(value) or 0
        if type(travel.setNoclipSpeed) == "function" then
            local ok, reason = travel.setNoclipSpeed(speed)
            if not ok then Open77.log.warn("admin: setNoclipSpeed refused: " .. tostring(reason)) end
        end
        send("admin:self", { noclipSpeed = speed })
    elseif action == "copyPosition" then
        local state = Open77.character.state()
        if state == nil or state.position == nil then
            send("admin:result", { raw = "admin.self.pos", ok = false,
                message = "no readable transform right now" })
            return
        end
        local text = string.format("position = { x = %.3f, y = %.3f, z = %.3f }",
            state.position.x, state.position.y, state.position.z)
        local copied = Open77.clipboard.setText(text)
        send("admin:result", { raw = "admin.self.pos", ok = copied == true, message = text })
    end
end)

-- Native wheel changes and automatic safety stops are the source of truth,
-- including while the large panel is closed.
AddEventHandler("open77_admin:noclipChanged", function(active, speed)
    send("admin:self", { noclip = active == true, noclipSpeed = speed })
end)

--- The governor mirror, replayed by the server. Every failure here is reported
--- once and then tolerated: a client that cannot apply a cap should keep
--- playing, not drop out.
---
--- THE GLOBAL TIER IS SYNTHESISED HERE. The native has a real default tier but
--- no Lua binding for it, so a server-wide cap is applied as a record-class
--- profile for every record actually seen in the world: `sweepGlobalGovernor`
--- (called from the watchdog thread, and immediately on a set) registers each
--- new record within a second of its first spawn, well inside the native's own
--- 16-frame discovery sweep for the vehicles behind it. A record nobody has
--- spawned has nothing to govern, so "not yet applied" is indistinguishable
--- from applied.
---
--- The bookkeeping below exists for one reason: an EXPLICIT record profile and
--- the global tier write into the same native map, so precedence between them
--- is decided here, not natively. An explicit record profile always wins, and
--- clearing it re-applies the global underneath instead of going to stock.
local governorGlobal = nil       -- the server-wide profile, or nil
local globalApplied = {}         -- record -> true, written by the global sweep
local explicitClass = {}         -- record -> true, an explicit record profile is in force

local function applyProfile(scope, key, profile)
    local vehicles = governorApi()
    if vehicles == nil then noteGovernorAbsence() return end
    local ok, reason
    if scope == "instance" then
        ok, reason = vehicles.setPerformance(tonumber(key) or 0, profile)
    else
        ok, reason = vehicles.setPerformanceClass(tostring(key), profile)
        if ok then explicitClass[tostring(key)] = true end
    end
    if not ok then
        -- `native_unavailable` means the detour did not attach on this build --
        -- the hook byte-checks the 2.31 prologue and declines rather than
        -- corrupting anything. Treated exactly like a missing export.
        Open77.log.warn("admin: governor " .. tostring(scope) .. " refused: " .. tostring(reason))
    end
end

local function sweepGlobalGovernor()
    if governorGlobal == nil then return end
    local vehicles = governorApi()
    if vehicles == nil then return end
    for _, snapshot in ipairs(vehicles.all() or {}) do
        local record = snapshot.record
        if type(record) == "string" and not globalApplied[record] and not explicitClass[record] then
            -- Marked applied even on refusal: a refusal here is the detour not
            -- being attached, which does not heal mid-session, and retrying it
            -- once a second would only fill the log with the same line.
            globalApplied[record] = true
            local ok, reason = vehicles.setPerformanceClass(record, governorGlobal)
            if not ok then
                Open77.log.warn("admin: global governor refused for " .. record
                    .. ": " .. tostring(reason))
            end
        end
    end
end

local function setGlobalGovernor(profile)
    local vehicles = governorApi()
    if vehicles == nil then noteGovernorAbsence() return end
    governorGlobal = type(profile) == "table" and profile or nil
    -- Re-stamp every record the old global had reached: the sweep only visits
    -- records it has not marked, so a CHANGED global would otherwise leave the
    -- previous ceiling in force on everything already seen.
    local reached = globalApplied
    globalApplied = {}
    if governorGlobal ~= nil then
        for record in pairs(reached) do
            if not explicitClass[record] then
                globalApplied[record] = true
                vehicles.setPerformanceClass(record, governorGlobal)
            end
        end
        sweepGlobalGovernor()
    else
        for record in pairs(reached) do
            if not explicitClass[record] then
                vehicles.clearPerformanceClass(record)
            end
        end
    end
end

RegisterNetEvent("open77_admin:governor", function(action, scope, key, profile)
    local vehicles = governorApi()
    if vehicles == nil then noteGovernorAbsence() return end

    if action == "replay" then
        -- `scope` carries the whole mirror on a replay.
        local mirror = scope
        if type(mirror) ~= "table" then return end
        for record, entry in pairs(mirror.class or {}) do applyProfile("class", record, entry) end
        for vehicleId, entry in pairs(mirror.instance or {}) do applyProfile("instance", vehicleId, entry) end
        setGlobalGovernor(mirror.global)
    elseif action == "set" then
        if scope == "global" then
            setGlobalGovernor(profile)
        else
            applyProfile(scope, key, profile)
        end
    elseif action == "clear" then
        if scope == "instance" then
            vehicles.clearPerformance(tonumber(key) or 0)
        elseif scope == "global" then
            setGlobalGovernor(nil)
        else
            local record = tostring(key)
            explicitClass[record] = nil
            if governorGlobal ~= nil then
                -- The global tier is what an ex-explicit record falls back to,
                -- exactly as the server's reply promises.
                globalApplied[record] = true
                vehicles.setPerformanceClass(record, governorGlobal)
            else
                vehicles.clearPerformanceClass(record)
            end
        end
    elseif action == "clearAll" then
        governorGlobal, globalApplied, explicitClass = nil, {}, {}
        if type(vehicles.clearAllPerformance) == "function" then vehicles.clearAllPerformance() end
    end
end)

-- ---------------------------------------------------------------------------
-- Rated top speed reporting
--
-- `ratedTopSpeed` reads the record's TweakDB gearing but only from a live
-- instance, and only on the client. So the catalogue's speed column fills in
-- as records appear in the world. Reported once per record per session, and
-- only for records that are actually in the catalogue.
-- ---------------------------------------------------------------------------
local reported = {}

local function reportRatedSpeeds()
    local vehicles = Open77 ~= nil and Open77.vehicles or nil
    if type(vehicles) ~= "table" or type(vehicles.ratedTopSpeed) ~= "function" then return end
    for _, snapshot in ipairs(vehicles.all() or {}) do
        local record = snapshot.record
        if type(record) == "string" and not reported[record]
            and Catalog.position(record) ~= nil then
            local rated = vehicles.ratedTopSpeed(snapshot.id)
            if type(rated) == "number" and rated > 0 then
                reported[record] = true
                TriggerServerEvent("open77_admin:rated", record, rated)
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- What this file has to fit inside
--
-- Two host limits govern every message and every handler below, and neither is
-- visible from Lua. Both are in `scripting/src/ResourceHost.cpp`.
--
-- 1. PAYLOAD SIZE, counted in nodes, not bytes. `EncodeLuaJson` walks the table
--    through `ReadValue`, which refuses at `kMaximumEventValues = 1024` VALUE
--    NODES -- and a key is a node of its own, so `{ key = ..., label = ...,
--    count = ... }` costs seven and 149 of them cost 1193. Over the ceiling,
--    `page:send` returns `false, "invalid_webui_event_payload"` and
--    `page:reply` returns `false, "invalid_webui_reply"`. Nothing raises,
--    nothing is logged, and the page simply never hears from us. This is the
--    quietest failure on the surface and the one to suspect first when a tab
--    is inexplicably empty.
--
-- 2. EXECUTION BUDGET, per resume. Every handler here runs on its own
--    coroutine, resumed by the host with a `LUA_MASKCOUNT` hook that fires
--    every 10 000 VM instructions and aborts the resume with `Open77 script
--    execution budget exceeded` if either the instruction cap is reached
--    (1 500 000) or the wall clock is past the resume deadline. That deadline
--    is the frame budget DIVIDED BY the number of running resources, floored
--    at 300 us -- one hook interval on this machine. The floor was 50 us until
--    2026-09-18, which on an RP server running ~70 resources gave 28-85 us
--    slices: ten thousand instructions take far longer, so the instruction
--    cap was never what tripped -- the wall clock was, at the first hook, for
--    every resume that got there. The floor is what makes the first hook
--    survivable whatever the resource count; the global frame deadline still
--    caps the sweep.
--
--    The practical rule that follows is the hook's own granularity. A resume
--    that stays under 10 000 instructions is never measured at all and cannot
--    fail; one that reaches 10 000 survives only the first hook, and only by
--    the floor's margin. So the unit of work here is "a few thousand
--    instructions, then yield" -- and a yield genuinely helps, because the
--    next resume resets both the instruction count and the deadline. A
--    `CreateThread` loop that raises is retired for the session: wrap phases
--    in `pcall`, and yield before doing anything else after a caught error.
--
-- Anything added to this file that loops over the 1372-record catalogue, or
-- that ships a list somebody might grow, has to obey both.
-- ---------------------------------------------------------------------------

--- Rows carried by one `admin:reference` answer. Forty rows of the widest
--- section (`classes`, four fields) is 401 nodes against the 1024 ceiling.
local kReferenceWindow = 40

--- Estimated VM instructions the `admin:catalog` scan will spend before it
--- yields. Half the hook's 10 000-instruction stride, so even a wrong estimate
--- by a factor of two leaves the resume unmeasured.
local kCatalogScanBudget = 5000

--- Rows carried by one `admin:catalog` answer. A row is seven fields, so 16
--- nodes with its array index: forty rows is 641.
local kCatalogWindow = 40

--- Rows the scan will order and keep at most, whatever `limit` is asked for.
--- The panel shows a page of a filtered list, not the catalogue.
local kCatalogCeiling = 150

--- The last catalogue scan, kept so paging through one filtered list does not
--- rescan 1372 records per page. The catalogue is generated and static and the
--- filters are the only input, so an entry is valid for the whole session.
local catalogCache = { signature = nil, rows = {}, total = 0 }

local function nameBefore(a, b) return a.name < b.name end

--- A record with no reading sorts last, always. It is never given a
--- placeholder number: an invented speed in a sortable column is a lie the
--- operator cannot see.
local function speedBefore(a, b)
    local left, right = a.ratedTopSpeed, b.ratedTopSpeed
    if left == nil and right == nil then return a.name < b.name end
    if left == nil then return false end
    if right == nil then return true end
    if left == right then return a.name < b.name end
    return left > right
end

--- Insert `row` into an ordered list that never grows past `kCatalogCeiling`.
---
--- This replaces a `table.sort` over the whole match set, and the reason is the
--- budget rather than taste: `table.sort` is a single C call that would make
--- ~14 000 calls into a Lua comparator without ever returning to the scheduler,
--- so it cannot be sliced and cannot be survived. A binary insertion is ~7
--- comparisons per candidate, in Lua, inside a loop the caller already yields
--- from -- and a candidate worse than the worst row kept costs exactly one.
local function insertOrdered(rows, row, before)
    local count = #rows
    if count >= kCatalogCeiling and not before(row, rows[count]) then return end
    local low, high = 1, count
    while low <= high do
        local middle = (low + high) // 2
        if before(row, rows[middle]) then high = middle - 1 else low = middle + 1 end
    end
    table.insert(rows, low, row)
    if #rows > kCatalogCeiling then rows[#rows] = nil end
end

--- The static lists the page fetches instead of being handed them at boot.
--- `whole` answers in one message; `list` answers a window at a time.
local function referenceSection(name)
    if name == "groups" then return { list = Catalog.groups or {} } end
    if name == "classes" then return { list = Catalog.classes or {} } end
    if name == "makers" then return { list = Catalog.makers or {} } end
    -- `Config.props` is a whole block a server owner could have removed from
    -- their copy of shared/config.lua. Indexing through it unguarded would take
    -- the handler down and leave the page waiting on a reply that never comes.
    local props = Config.props or {}
    if name == "propModels" then return { list = props.models or {} } end
    if name == "propEffects" then return { list = props.effects or {} } end
    if name == "propLight" then return { whole = props.light or {} } end
    return nil
end

-- ---------------------------------------------------------------------------
-- The panel's outbound intents
-- ---------------------------------------------------------------------------
local function bind()
    page:on("admin:ready", function()
        pageReady = true
        -- The surface is created at resource start but the page answers a
        -- moment later. An operator who types /admin inside that window would
        -- otherwise get focus taken with a page that never received the show,
        -- i.e. an invisible modal that eats the mouse.
        if open then send("admin:show", {}) end
        -- SMALL, and it has to stay small. See "What this file has to fit
        -- inside" above: everything here is counted, keys included, against a
        -- 1024-node ceiling, and a payload that crosses it is dropped in
        -- silence. What follows is 79 nodes. The catalogue facets, the vehicle
        -- alias table and the prop alias lists used to ride along here and took
        -- it past 1600; they are fetched on demand now, by `admin:reference`.
        send("admin:boot", {
            label = Config.label,
            resource = RESOURCE,
            capabilities = capabilities(),
            catalog = { build = Catalog.build, count = Catalog.count },
            governor = Config.vehicles.governor,
            travel = Config.travel,
            limits = Config.limits,
        })
        announce()
    end)

    -- -----------------------------------------------------------------------
    -- Reference data, on demand and in slices
    --
    -- Everything here is STATIC: it is the same on the first open and the
    -- hundredth, so it does not belong in a payload that is rebuilt every time
    -- the page loads. The page asks for a section when it first needs one --
    -- the manufacturer list when the Vehicles tab is first shown, the prop
    -- aliases when the Props tab is -- and caches it for the session.
    --
    -- Every answer is a WINDOW, never a whole section. `Catalog.makers` alone
    -- is 149 rows of three fields, which is 1193 nodes: past the ceiling on its
    -- own. `kReferenceWindow` rows of the widest section (classes, four fields)
    -- is 40 * 10 + 1 = 401 nodes, so no answer here is ever within a factor of
    -- two of the limit, and the loop that builds one runs a few hundred
    -- instructions rather than the ten thousand that get a resume measured.
    -- -----------------------------------------------------------------------
    page:on("admin:reference", function(payload, requestId)
        payload = type(payload) == "table" and payload or {}
        local section = tostring(payload.section or "")
        local offset = math.max(math.floor(tonumber(payload.offset) or 0), 0)

        local source = referenceSection(section)
        if source == nil then
            page:reply(requestId, { section = section, error = "unknown_section" }, false)
            return
        end

        -- A section that is a single small table -- the light bounds -- answers
        -- whole; the rest are arrays and answer a window at a time.
        if source.whole ~= nil then
            page:reply(requestId, {
                section = section, offset = 0, total = 1, done = true, value = source.whole,
            }, true)
            return
        end

        local list = source.list
        local total = #list
        local items = {}
        local last = math.min(offset + kReferenceWindow, total)
        for index = offset + 1, last do items[#items + 1] = list[index] end

        page:reply(requestId, {
            section = section,
            offset = offset,
            total = total,
            items = items,
            done = last >= total,
        }, true)
    end)

    -- -----------------------------------------------------------------------
    -- The page's own failures, in the ordinary log
    --
    -- Nothing a CEF page reports reaches `red4ext/logs/open77-*.log` on this
    -- build: `SurfaceClient::OnConsoleMessage` forwards console output through
    -- the webhost's `Trace`, and that level is not written. Worse, the WebUI
    -- bridge catches every exception thrown inside a page handler and sends it
    -- to `console.error` -- so a page that dies half way through renders
    -- nothing and says nothing, while this side sees a perfectly healthy
    -- surface with all its handlers registered.
    --
    -- The page therefore reports to us instead (see the top of web/app.js) and
    -- we write it where somebody will find it. Rate-limited on the page side.
    -- -----------------------------------------------------------------------
    page:on("admin:diag", function(payload)
        if type(payload) ~= "table" then return end
        local text = "panel: " .. tostring(payload.text or "")
        if payload.level == "error" then
            Open77.log.error(text)
        else
            Open77.log.info(text)
        end
    end)

    page:on("admin:close", function() releaseFocus("page") end)

    --- The single outbound verb. The page never names a permission, never
    --- asserts a right, and never sends a record it did not get from the
    --- catalogue this resource shipped.
    page:on("admin:command", function(payload)
        if type(payload) ~= "table" then return end
        local tokens = payload.tokens
        if type(tokens) ~= "table" then
            if type(payload.line) == "string" then
                tokens = tokenise(payload.line:gsub("^/", ""))
            else
                return
            end
        end
        execute(tokens, payload.tag)
    end)

    --- The catalogue is 1372 records, and the obvious implementation breaks
    --- BOTH host limits at once -- see the header block.
    ---
    --- The scan is about 75 000 VM instructions, seven times what gets a resume
    --- killed, so it yields once it has spent `kCatalogScanBudget`: a yield
    --- resets the instruction count and stamps a fresh deadline, which is
    --- exactly what makes the work affordable at all.
    ---
    --- The ordering used to be a `table.sort` over every match, which is one
    --- uninterruptible C call -- 1372 rows is ~14 000 comparator calls and
    --- could not be sliced even in principle. Each match is inserted into an
    --- ordered list of bounded length instead. That is ordinary Lua, so it
    --- lives inside the sliced loop, and it never builds more than
    --- `kCatalogCeiling` rows.
    ---
    --- And the answer is paged, because 150 rows of seven fields is 2400 nodes
    --- against a ceiling of 1024. The page asks for `offset` and gets at most
    --- `kCatalogWindow` rows. The ordered list is kept between requests, keyed
    --- by the filter signature, so only the first page of a given filter pays
    --- for the scan.
    page:on("admin:catalog", function(payload, requestId)
        payload = type(payload) == "table" and payload or {}
        local query = tostring(payload.query or ""):lower()
        local group = payload.group
        local class = payload.class
        local maker = payload.maker
        local police = payload.police == true
        local playerOnly = payload.playerOnly == true
        local sortBySpeed = payload.sort == "speed"
        local offset = math.max(math.floor(tonumber(payload.offset) or 0), 0)
        local limit = math.floor(tonumber(payload.limit) or kCatalogWindow)
        limit = math.min(math.max(limit, 1), kCatalogWindow)

        local signature = table.concat({
            query, tostring(group), tostring(class), tostring(maker),
            tostring(police), tostring(playerOnly), tostring(sortBySpeed),
        }, "\1")

        if catalogCache.signature ~= signature then
            local before = sortBySpeed and speedBefore or nameBefore
            -- Hoisted, and it is not micro-optimisation for its own sake: every
            -- `Catalog.x[position]` in the loop body is two lookups instead of
            -- one, and the body's opcode count is the only thing standing
            -- between this scan and the 10 000 that get a resume measured.
            local records, names, rated = Catalog.records, Catalog.names, Catalog.ratedTopSpeed
            local flagsOf, groupOf = Catalog.flags, Catalog.groupOf
            local classList, classOf = Catalog.classes, Catalog.classOf
            local makerList, makerOf = Catalog.makers, Catalog.makerOf
            local rows, total = {}, 0
            -- Yield on ESTIMATED COST, not on a record count. A rejected record
            -- is ~30 opcodes and a kept one ~200 with its ordered insertion, so
            -- a fixed stride would have to be sized for the all-match case and
            -- would then yield thirty-odd times for a filter that matches
            -- nothing. This bounds the resume either way.
            local cost = 0
            for position = 1, #records do
                local flags = flagsOf[position]
                local isPolice = flags % 2 == 1
                local isPlayer = flags >= 2
                -- Cheapest tests first: these three are arithmetic on values
                -- already in hand, and they reject most of the catalogue before
                -- anything is looked up or lowercased.
                local keep = (group == nil or groupOf[position] == group)
                    and (not police or isPolice)
                    and (not playerOnly or isPlayer)
                local classKey, makerKey
                if keep and class ~= nil then
                    classKey = classList[classOf[position]].key
                    keep = classKey == class
                end
                if keep and maker ~= nil then
                    makerKey = makerList[makerOf[position]].key
                    keep = makerKey == maker
                end
                local record, name
                if keep then
                    record, name = records[position], names[position]
                    if query ~= "" then
                        keep = record:lower():find(query, 1, true) ~= nil
                            or name:lower():find(query, 1, true) ~= nil
                    end
                end
                if keep then
                    total = total + 1
                    insertOrdered(rows, {
                        record = record,
                        name = name,
                        class = classKey or classList[classOf[position]].key,
                        maker = makerKey or makerList[makerOf[position]].key,
                        police = isPolice, player = isPlayer,
                        ratedTopSpeed = rated[record],
                    }, before)
                    cost = cost + 200
                else
                    cost = cost + 30
                end
                if cost >= kCatalogScanBudget then
                    cost = 0
                    Wait(0)
                    if page == nil then return end
                end
            end
            -- The surface can go away across a yield -- a resource stop, a
            -- reload -- and `page` is nil then.
            if page == nil then return end
            -- Two requests for the same filter can overlap across the yields
            -- above; both scans produce the same list, so committing the later
            -- one is harmless. Committing a scan whose filter is no longer the
            -- one being asked about is not, which is what the signature is for.
            catalogCache.signature, catalogCache.rows, catalogCache.total = signature, rows, total
            -- A fresh resume for the window build below, so it never shares a
            -- slice with the tail of the scan.
            Wait(0)
            if page == nil then return end
        end

        local rows = catalogCache.rows
        local shown = #rows
        local window = {}
        local last = math.min(offset + limit, shown)
        for index = offset + 1, last do window[#window + 1] = rows[index] end

        page:reply(requestId, {
            rows = window,
            total = catalogCache.total,
            shown = shown,
            offset = offset,
            done = last >= shown,
        }, true)
    end)
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------
AddEventHandler("onClientResourceStart", function(name)
    if name ~= RESOURCE then return end

    local reason
    page, reason = WebUI.create({
        entry = "web/index.html",
        -- "menu", not "system": the pause menu and the server browser must
        -- still draw above this panel, so they stay the escape hatch of last
        -- resort if anything here goes wrong.
        layer = "menu",
        width = 1920,
        height = 1080,
        fps = 60,
        zIndex = 720,
        transparent = true,
        -- Created VISIBLE and never hidden. On the current client build a
        -- surface created hidden never uploads a frame once shown, so the
        -- <body> class is the only visibility authority and the page is fully
        -- transparent with pointer-events: none until it opens.
        visible = true,
    })
    if page == nil then
        Open77.log.error("admin: WebUI failed: " .. tostring(reason))
        return
    end
    bind()

    if governorApi() == nil then noteGovernorAbsence() end

    -- `open77:worldReady` does not fire after a hot reload -- the world is
    -- already up -- so the announce has to happen from the resource start too,
    -- or a reloaded panel is invisible to the server's roster forever.
    CreateThread(function()
        Wait(500)
        announce()
    end)

    -- Watchdog. Also carries the rated-speed sweep and the global-governor
    -- sweep, both cheap: each walks the handful of live vehicles and acts at
    -- most once per record per session (rated) or per cap change (global).
    CreateThread(function()
        while page ~= nil do
            Wait(WATCHDOG_MS)
            if open and nowMs() - openedAtMs > MAX_OPEN_MS then
                releaseFocus("watchdog")
            end
            reportRatedSpeeds()
            sweepGlobalGovernor()
        end
    end)
end)

AddEventHandler("open77:worldReady", function()
    announce()
end)

-- The plugin swallows Escape and raises this instead. Closing here keeps the
-- panel from being left open and unfocused underneath the pause menu, with the
-- cursor gone.
AddEventHandler("open77:pauseKey", function()
    if open then releaseFocus("pauseKey") end
end)

RegisterNetEvent("open77_admin:close", function()
    releaseFocus("server")
end)

AddEventHandler("onClientResourceStop", function(name)
    if name ~= RESOURCE then return end
    releaseFocus("resourceStop")
    -- Disarm the map gesture with the resource that armed it. This is the ONLY
    -- automatic disarm there is: nothing in the plugin clears the flag on a
    -- world change or a disconnect, so without this line a stopped or reloaded
    -- admin package would leave every double click on the map still dropping a
    -- waypoint, with nobody left to listen for it.
    if mapPickCommand ~= nil then setMapPick(false, nil) end
    page, pageReady, open = nil, false, false
end)
