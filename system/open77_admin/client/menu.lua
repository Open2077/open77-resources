-- /admin: keyboard navigation and a Lua-owned submenu stack, independent of
-- all gamemodes. The HUD does not capture gameplay during normal navigation.
-- Text forms alone capture input; cancel, submit, ACL revocation and shutdown
-- release it. The page can submit a form value/nonce, never an action or target.
-- ACL snapshots decide availability; restricted server commands enforce it.

local Config = Open77AdminConfig

local RESOURCE = GetCurrentResourceName()

-- The page reports a viewport-sized row window. Lists are virtualized here
-- to bound payloads and keep every selected item visible at 720p and ultrawide.
local kWindow = 9

-- Edge detection timings. Fire immediately on press, then after
-- `kRepeatDelayMs` repeat at `kRepeatIntervalMs` -- eight a second, which is
-- what makes a 28-entry family list or a 24-vehicle list usable without
-- becoming uncontrollable.
local kRepeatDelayMs = 350
local kRepeatIntervalMs = 125

-- Poll cadence while the menu is up. `Wait(0)` is one frame; anything slower
-- makes the first keypress feel dropped.
local kPollMs = 0

-- Poll cadence while it is down. Nothing is read but the thread must survive.
local kIdleMs = 250

-- How often the open menu re-asks the server for the roster. `admin.read.players`
-- is throttled server-side at `Config.limits.readIntervalMs` (500 ms) and a
-- refused read is silent, so asking faster than this only wastes packets.
local kRosterRefreshMs = 1500

-- Spawn distance bounds for "at aim", in metres.
local kAimMin, kAimMax, kAimStep, kAimDefault = 1.0, 60.0, 1.0, 6.0

local page
local pageReady = false
local open = false
local aimDistance = kAimDefault

-- Yaw applied on top of the direction the operator is facing, so a prop can be
-- turned without turning the operator. Sticky across spawns on purpose: laying
-- a row of barriers all square to a road means choosing the angle once.
--
-- This WRAPS rather than clamps, which is the opposite of `aimDistance`. An
-- angle has no ends -- stopping at 180 would make the shortest route to -165 a
-- journey back through zero -- whereas a distance genuinely does.
local kYawStep = 15.0
local yawOffset = 0.0

local function normaliseYaw(value)
    value = (value + 180.0) % 360.0
    -- Lua's % is non-negative for a positive divisor, so this only guards
    -- against a NaN or an inf arriving from a degenerate camera read.
    if value < 0.0 then value = value + 360.0 end
    return value - 180.0
end

--- Last data the server pushed. Nothing here is authority -- it decides what
--- the menu DRAWS, never what it may do.
local data = {
    access = { commands = {}, roles = {} },
    you = nil,          -- { playerId, name } from the `/admin` command itself
    players = {},       -- roster rows from `admin.read.players`
    locations = {},     -- saved destinations from `admin.read.world`
    rosterAtMs = 0,
}

local status = { text = "", ok = true }

--- When the footer line was last written. Declared here rather than beside the
--- handler that sets it: the polling thread reads it, and a `local` further
--- down the file would be a GLOBAL lookup from anything defined above it --
--- nil at runtime, and arithmetic on nil the first time an action answers.
local expectMs = 0

local function nowMs()
    return math.floor(Open77.time.monotonic() * 1000)
end

local function permitted(command)
    return data.access.commands and data.access.commands[command] == true
end

local function anyPermission(requirement)
    if requirement == nil then return true end
    if type(requirement) == "table" then
        for _, entry in ipairs(requirement) do if anyPermission(entry) then return true end end
        return false
    end
    if requirement:sub(-2) ~= ".*" then return permitted(requirement) end
    local prefix = requirement:sub(1, -2)
    for command, granted in pairs(data.access.commands or {}) do
        if granted and command:sub(1, #prefix) == prefix then return true end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- The command channel
--
-- A local copy rather than a reach into client/main.lua. The two files share a
-- Lua state, but coupling them would mean this menu could be taken down by an
-- edit to the panel and vice versa; the whole point of a second surface is
-- that one of them failing leaves the other working.
-- ---------------------------------------------------------------------------
local function execute(...)
    local clean = {}
    for _, raw in ipairs({...}) do
        local token = tostring(raw or "")
        -- The transport caps a token at 256 UTF-8 bytes and rejects control
        -- characters outright; trimming here turns a silent refusal into a
        -- command that runs.
        if #token > 256 then token = token:sub(1, 256) end
        token = token:gsub("[%c]", " ")
        if token ~= "" then clean[#clean + 1] = token end
    end
    if #clean == 0 or #clean > 32 then return false end
    if not permitted(clean[1]) then
        status = { text = "ACL: no access to /" .. clean[1], ok = false }
        expectMs = nowMs()
        return false
    end
    local sent, reason = TriggerServerEvent("open77:command:execute", table.unpack(clean))
    if not sent then
        status = { text = tostring(reason or "not sent"), ok = false }
        expectMs = nowMs()
    end
    return sent ~= false
end

-- ---------------------------------------------------------------------------
-- Spawn at aim
--
-- There is NO raycast binding on this platform. `Open77.camera.project` goes
-- the wrong way (world point -> screen), `Open77.props.project` likewise, and
-- the debug bridge's `world.lookat` is not a ray either: it calls
-- `gametargetingTargetingSystem::GetLookAtObject`, which answers with an
-- ENTITY under the crosshair or nothing at all. That is useless for placing a
-- prop on an empty pavement, and it is not exposed to Lua in any case.
--
-- So the aim point is computed from `Open77.camera.view()`, which returns
-- `{ position = {x,y,z}, forward = {x,y,z}, fov }` (ResourceHost.cpp,
-- LuaCameraView), in two modes:
--
--   * looking DOWN -- the ordinary "put it there" gesture -- the forward ray
--     is intersected with the horizontal plane through the OPERATOR'S OWN
--     FEET. A prop origin sits at the model's base (see admin.props.here), so
--     that lands it standing on the floor the operator is standing on, which
--     is right in every interior and on any flat street.
--   * otherwise -- level or upward -- a fixed distance along the ray, which
--     the operator tunes with LEFT/RIGHT on the spawn item.
--
-- The plane intersection is honest about its limits: it is a PLANE, not the
-- ground. Aim down a stairwell and the prop lands at your own level, in the
-- air. That is why the fixed-distance mode is still reachable and why the
-- chosen distance is shown on screen.
-- ---------------------------------------------------------------------------
local function aimPoint()
    local view = Open77.camera.view()
    if type(view) ~= "table" or type(view.position) ~= "table" or type(view.forward) ~= "table" then
        return nil, "no camera view right now"
    end
    local origin, forward = view.position, view.forward
    local length = math.sqrt(forward.x * forward.x + forward.y * forward.y + forward.z * forward.z)
    -- The backend hands back a unit vector, but a degenerate read would
    -- otherwise scale the distance by an arbitrary factor instead of failing.
    if length < 1e-4 then return nil, "camera forward is degenerate" end
    local fx, fy, fz = forward.x / length, forward.y / length, forward.z / length

    -- yaw 0 is +Y and forward is (-sin y, cos y), so y = atan2(-dx, dy). This
    -- is the same convention as open77_playerstate and pursuit; a prop spawned
    -- with it is aligned with the direction the operator is looking.
    local yaw = normaliseYaw(math.deg(math.atan(-fx, fy)) + yawOffset)

    local state = Open77.character.state()
    local groundZ = type(state) == "table" and type(state.position) == "table"
        and state.position.z or nil
    if groundZ ~= nil and fz < -0.15 then
        local travel = (groundZ - origin.z) / fz
        -- Bounded both ways: below 0.5 m the prop lands inside the operator,
        -- and a shallow angle over a long distance is a wild extrapolation of
        -- a plane that was only ever true underfoot.
        if travel > 0.5 and travel <= aimDistance * 4.0 then
            return { x = origin.x + fx * travel, y = origin.y + fy * travel, z = groundZ, yaw = yaw },
                "ground"
        end
    end
    -- No ground intersection: the operator is looking level or upward. Do NOT
    -- follow the ray -- `origin.z + fz * aimDistance` is the CAMERA's height,
    -- so looking straight ahead left the prop hanging in the air at eye level,
    -- which is what it did on first use.
    --
    -- Instead take the direction on the horizontal plane only and drop the prop
    -- to the operator's own feet. Distance then means distance along the
    -- ground, which is also what "6 m ahead" reads as. Falling back to the ray
    -- remains the last resort, for when character state is unavailable and
    -- there is no foot height to stand on.
    local hx, hy = fx, fy
    local horizontal = math.sqrt(hx * hx + hy * hy)
    if horizontal > 1e-4 then
        hx, hy = hx / horizontal, hy / horizontal
    else
        -- Straight up or straight down with no ground hit: there is no sensible
        -- horizontal direction, so keep the ray rather than inventing one.
        return {
            x = origin.x + fx * aimDistance,
            y = origin.y + fy * aimDistance,
            z = origin.z + fz * aimDistance,
            yaw = yaw,
        }, "ray"
    end
    if groundZ ~= nil then
        return {
            x = origin.x + hx * aimDistance,
            y = origin.y + hy * aimDistance,
            z = groundZ,
            yaw = yaw,
        }, "level"
    end
    return {
        x = origin.x + fx * aimDistance,
        y = origin.y + fy * aimDistance,
        z = origin.z + fz * aimDistance,
        yaw = yaw,
    }, "ray"
end

--- Round for a command token. `%.2f` and not `tostring`: a Lua float prints as
--- `1669.7500000000001` often enough to matter, and the token limit is bytes.
local function coordinate(value)
    return string.format("%.2f", value)
end

local function runAtAim(command, model)
    local point, mode = aimPoint()
    if point == nil then
        status = { text = mode, ok = false }
        return
    end
    if command == "admin.props.spawn" then
        execute(command, model, coordinate(point.x), coordinate(point.y), coordinate(point.z),
            string.format("%.1f", point.yaw))
    else
        execute(command, model, coordinate(point.x), coordinate(point.y), coordinate(point.z))
    end
end

--- The heading the operator is looking along, in the engine's own convention
--- (0 is +Y, counter-clockwise). Taken from the camera and not from the body,
--- because what an operator means by "over there" is where they are LOOKING.
--- Falls back to the body's heading, then to due north, so a caller always has
--- a number to pass rather than a nil that becomes a default somewhere else.
local function cameraHeading()
    local view = Open77.camera.view()
    if type(view) == "table" and type(view.forward) == "table" then
        local f = view.forward
        if math.abs(f.x) > 1e-4 or math.abs(f.y) > 1e-4 then
            return normaliseYaw(math.deg(math.atan(-f.x, f.y)))
        end
    end
    local state = Open77.character.state()
    if type(state) == "table" and tonumber(state.yaw) ~= nil then
        return normaliseYaw(tonumber(state.yaw))
    end
    return 0.0
end

--- Where a SHOW goes when it is cast from the menu.
---
--- Not `runAtAim`. That one answers the "put it there" gesture: a few metres
--- away, on the floor the operator is standing on -- right for a chair, wrong
--- for fireworks, which then go up from under their feet and read as a bonfire.
--- A display belongs in front of the viewer, far enough to be seen whole: the
--- horizontal direction the camera is facing, `props.showDistance` metres out,
--- at the operator's own ground height. The shells take their altitude from the
--- show itself, so aiming up or down changes the direction, never the height.
local function runShowAtAim(command, token)
    local view = Open77.camera.view()
    local state = Open77.character.state()
    local groundZ = type(state) == "table" and type(state.position) == "table"
        and state.position.z or nil
    if type(view) ~= "table" or type(view.position) ~= "table"
        or type(view.forward) ~= "table" or groundZ == nil then
        -- No camera or no body: fall back to the command's own "where I stand"
        -- form rather than refusing. A show over the operator beats no show.
        execute(command, token)
        return
    end
    local forward = view.forward
    local hx, hy = forward.x, forward.y
    local horizontal = math.sqrt(hx * hx + hy * hy)
    if horizontal < 1e-4 then
        execute(command, token)
        return
    end
    local distance = tonumber((Config.props or {}).showDistance) or 90.0
    hx, hy = hx / horizontal * distance, hy / horizontal * distance
    execute(command, token,
        coordinate(view.position.x + hx), coordinate(view.position.y + hy), coordinate(groundZ))
end

-- ---------------------------------------------------------------------------
-- The menu model
--
-- A frame is `{ node, arg, index }`. `node` names a BUILDER, never a built
-- list: the builder re-runs whenever the data behind it changes, so the Players
-- screen follows the roster without the navigation state being rebuilt around
-- it. `arg` is whatever the builder needs (a player id, a prop family).
--
-- Items are `{ label, value, arrow, run, adjust }`. `run` fires on ENTER;
-- `adjust(delta)` fires on LEFT/RIGHT. Neither ever crosses to the page --
-- only `label`, `value` and `arrow` do.
-- ---------------------------------------------------------------------------
local builders = {}
local stack = {}

--- Forward declaration. The root menu's "Close" item needs it and is built
--- three hundred lines above the body. Declaring it later with `local function`
--- would leave the reference inside that closure a GLOBAL lookup -- nil at
--- runtime, and a dead item that silently does nothing. luac does not catch it.
local closeMenu

local function frame()
    return stack[#stack]
end

local function pushNode(node, arg)
    stack[#stack + 1] = { node = node, arg = arg, index = 1 }
end

local function popNode()
    if #stack > 1 then stack[#stack] = nil return true end
    return false
end

--- The one entry point for "this item opens a screen".
local nodePermissions = {
    players = "admin.read.players", player = "admin.read.players",
    vehicles = "admin.veh.*", vehicleFamily = "admin.veh.spawn", vehicleMakers = "admin.veh.spawn", vehicleMaker = "admin.veh.spawn",
    weapons = "admin.weap.*", weaponClass = "admin.weap.give",
    props = {"admin.props.*", "admin.fx.*"}, propFamily = "admin.props.spawn",
    effects = "admin.fx.play", effectFamily = "admin.fx.play", shows = "admin.fx.show",
    drones = "droneshow",
    celebrations = "fireworks",
    self = "admin.self.*", speed = "admin.veh.speed.*",
    morph = {"admin.self.morph", "admin.self.unmorph", "admin.self.morph.search"},
    morphCategories = "admin.self.morph.search", morphCatalogue = "admin.self.morph.search",
    world = {"admin.world.*", "admin.player.at", "weather.*"},
    developer = "admin.dev.*", developerDoors = "admin.dev.doors.inspect",
    locations = "admin.player.at", time = "weather.time.*", weather = "weather.*",
    ban = "admin.moderate.ban", audit = "admin.read.audit",
    bulk = "admin.bulk.*",
    playtest = "admin.playtest.*",
    targetPlayer = {"admin.player.*", "admin.moderate.*", "admin.read.players"},
    targetVehicle = "admin.veh.*", targetDoor = "admin.dev.doors.control",
}
local pendingPlayers = {}
local function opener(label, node, arg, value)
    local permission = node == "confirm" and arg and arg.tokens and arg.tokens[1] or nodePermissions[node]
    return { label = label, value = value, arrow = true, permission = permission,
        run = function() pushNode(node, arg) end }
end

--- The one entry point for "this item runs a command".
local function action(label, value, ...)
    local tokens = {...}
    return { label = label, value = value, permission = tokens[1], run = function() execute(table.unpack(tokens)) end }
end

-- Keyboard navigation stays non-modal. Only free text temporarily captures
-- input; the page cannot submit a command, only a value for this Lua-owned form.
local form, formSequence = nil, 0
local formLimits = { ["admin.moderate.kick"] = 127, ["admin.moderate.ban"] = 200, ["admin.world.announce"] = 240,
    ["admin.self.morph.search"] = 96 }
local function cancelInput()
    -- Release this surface even without a live form (e.g. focus acquired by
    -- clicking the panel). Otherwise tick() sees its own capture and stops.
    if page then page:setFocus(false, false) end
    if not form then return end
    form = nil
    page:send("menu:input:close", {})
end
local function inputItem(label, spec)
    return { label = label, arrow = true, permission = spec.tokens[1], run = function()
        if not page then return end
        local focused, reason = page:setFocus(true, true)
        if not focused then
            status = { text = tostring(reason or "Input unavailable"), ok = false }
            return
        end
        formSequence = formSequence + 1
        spec.maxBytes = spec.maxBytes or formLimits[spec.tokens[1]] or 256
        form = { id = formSequence, spec = spec, title = label }
        page:send("menu:input", { id = form.id, title = label,
            label = spec.label or "Message", maxBytes = spec.maxBytes,
            hint = (spec.hint or "Visible to the player.") .. " Maximum " .. spec.maxBytes .. " UTF-8 bytes." })
    end }
end

-- ---------------------------------------------------------------------------
-- Lazy tables
--
-- NOTHING below is built at load. `shared/catalog.lua` cost this package a
-- silent whole-resource rollback by spending 13 690 VM instructions at load
-- time, past the host's 10 000-instruction hook stride; the rule that came out
-- of it is that a file may DECLARE work at load and must not DO it. Every
-- builder here therefore runs on first use, inside the input thread, and
-- yields part-way so a long list gets a fresh resume and a fresh deadline.
-- ---------------------------------------------------------------------------
local families = {}     -- cache key -> { order = { name... }, members = { name -> { alias... } } }

local function familyOf(alias)
    local dot = alias:find(".", 1, true)
    return dot and alias:sub(1, dot - 1) or alias
end

--- Group an alias list by the text before its first dot, preserving the order
--- the config declares -- which is what keeps a family's entries together.
local function groupAliases(key, list)
    local cached = families[key]
    if cached ~= nil then return cached end
    local order, members = {}, {}
    for index = 1, #list do
        local alias = tostring(list[index])
        local name = familyOf(alias)
        local bucket = members[name]
        if bucket == nil then
            bucket = {}
            members[name] = bucket
            order[#order + 1] = name
        end
        bucket[#bucket + 1] = alias
        -- 183 aliases is roughly 2 700 instructions, comfortably under the
        -- 10 000 stride on its own -- but it shares a resume with the input
        -- poll that triggered it, so it yields anyway. A yield resets both the
        -- instruction count and the deadline; it costs one frame, once.
        if index % 60 == 0 then Wait(0) end
    end
    cached = { order = order, members = members }
    families[key] = cached
    return cached
end

--- Vehicle aliases grouped by the family in their record: `v_standard2_...`
--- and `v_standard25_...` are both "standard", `v_sportbike1_...` is
--- "sportbike". `pairs` order is undefined, so the keys are sorted -- 24 of
--- them, which is a few hundred comparator calls and safe inline.
local vehicleFamilies
--- The whole shipped catalogue, indexed by manufacturer, BUILT IN THE
--- BACKGROUND.
---
--- The first version of this walked all 1372 records inside the ENTER handler
--- and died on "script execution budget exceeded" every time, aborting the tick
--- so the submenu simply never opened. Chunking the loop with `Wait(0)` was not
--- enough either: a key handler is the wrong place to do a thousand records of
--- work, because every resume it takes is a frame the menu is not responding.
---
--- So the index is built once by its own thread after the resource starts, and
--- the menu only ever reads the finished table. If an operator gets there first
--- they see "indexing" for a moment rather than a stall.
local catalogueMakers = nil
local catalogueIndexing = false

local function buildCatalogueIndex()
    if catalogueMakers ~= nil or catalogueIndexing then return end
    local catalog = Open77AdminCatalog
    if type(catalog) ~= "table" or type(catalog.records) ~= "table"
        or type(catalog.makers) ~= "table" or type(catalog.makerOf) ~= "table" then
        catalogueMakers = { order = {}, members = {}, label = {} }
        return
    end
    catalogueIndexing = true
    CreateThread(function()
        local order, members, label = {}, {}, {}
        for position, record in ipairs(catalog.records) do
            local maker = catalog.makers[catalog.makerOf[position]]
            local key = maker and maker.key or "other"
            local bucket = members[key]
            if bucket == nil then
                bucket = {}
                members[key] = bucket
                order[#order + 1] = key
                label[key] = maker and maker.label or "Other"
            end
            bucket[#bucket + 1] = {
                record = record,
                name = catalog.names[position] or record,
            }
            -- Deliberately small: 25, not 60. This runs while the operator is
            -- playing, so a short slice each frame is better than a long one.
            if position % 25 == 0 then Wait(0) end
        end
        -- `table.sort` is one atomic C call that cannot be interrupted, so it
        -- gets a whole resume to itself rather than the remains of the last
        -- chunk's budget.
        Wait(0)
        table.sort(order, function(a, b) return (label[a] or a) < (label[b] or b) end)
        catalogueMakers = { order = order, members = members, label = label }
        catalogueIndexing = false
    end)
end

local function groupVehicles()
    if vehicleFamilies ~= nil then return vehicleFamilies end
    local names = {}
    for alias in pairs(Config.vehicles.aliases or {}) do names[#names + 1] = alias end
    table.sort(names)
    local order, members = {}, {}
    for _, alias in ipairs(names) do
        local record = Config.vehicles.aliases[alias]
        local name = record:match("^Vehicle%.v_(%a+)") or "other"
        local bucket = members[name]
        if bucket == nil then
            bucket = {}
            members[name] = bucket
            order[#order + 1] = name
        end
        bucket[#bucket + 1] = alias
    end
    table.sort(order)
    vehicleFamilies = { order = order, members = members }
    return vehicleFamilies
end

-- ---------------------------------------------------------------------------
-- Builders
-- ---------------------------------------------------------------------------
--- Trim to a BYTE budget without cutting a UTF-8 sequence in half.
---
--- `sub(1, n)` on a name with an accent lands mid-sequence often enough to
--- matter, and CEF renders the orphan byte as a replacement glyph -- which
--- looks like a corrupted roster rather than a truncated name. Back off over
--- any continuation byte (10xxxxxx) before appending. Same trap, and the same
--- fix, as `trimTo` in server/players.lua.
local function trim(text, limit)
    if #text <= limit then return text end
    local cut = limit
    while cut > 0 do
        local byte = text:byte(cut + 1)
        if byte == nil or byte < 0x80 or byte >= 0xC0 then break end
        cut = cut - 1
    end
    return text:sub(1, cut) .. "…"
end

local function playerLabel(row)
    return string.format("%d %s", row.playerId, trim(tostring(row.name or "?"), 15))
end

local function playerRow(playerId)
    for _, row in ipairs(data.players) do
        if row.playerId == playerId then return row end
    end
    return nil
end

local function meRow()
    local you = data.you
    return you ~= nil and playerRow(you.playerId) or nil
end

builders.root = function()
    return "ADMIN", {
        opener("Players", "players", nil, tostring(#data.players)),
        opener("Vehicles", "vehicles"),
        opener("Weapons", "weapons", nil, "me"),
        opener("Props", "props"),
        opener("Self", "self"),
        opener("World", "world"),
        opener("Developer", "developer"),
        inputItem("Announcement", { tokens = {"admin.world.announce"}, label = "Server announcement",
            hint = "Shown to every connected player. Confirm before broadcasting.", confirm = true }),
        opener("Server actions", "bulk"),
        opener("Freeroam playtest", "playtest"),
        opener("Recent actions", "audit"),
        { label = "Close", run = function() closeMenu("item") end },
    }
end

builders.players = function()
    local items = {}
    for _, row in ipairs(data.players) do
        local hint
        if not row.incarnated then
            hint = "loading"
        elseif row.dead then
            hint = "down"
        elseif row.distance ~= nil then
            hint = string.format("%dm", math.floor(row.distance))
        end
        items[#items + 1] = opener(playerLabel(row), "player", row.playerId, hint)
    end
    if #items == 0 then
        items[1] = { label = "No roster yet", value = "…" }
    end
    items[#items + 1] = opener("TpAll…", "confirm", {
        label = "Gather all ready players", tokens = { "admin.bulk.tpall", "confirm" },
        detail = "All buckets. Ready, alive players only. Spaced rings around your current position; one at a time. Stand on open, level ground.",
    })
    return "PLAYERS", items
end

builders.bulk = function()
    return "SERVER ACTIONS", {
        opener("TpAll…", "confirm", { label = "Gather all ready players",
            tokens = { "admin.bulk.tpall", "confirm" },
            detail = "All buckets. Ready, alive players only. Spaced rings around your current position; one at a time. Stand on open, level ground." }),
        opener("DVAll…", "confirm", { label = "Delete ALL server vehicles",
            tokens = { "admin.bulk.dvall", "confirm" },
            detail = "All network vehicles, all resources and buckets. Occupants exit first; vehicles still occupied are reported and kept. Cannot be undone." }),
        action("Cancel current operation", nil, "admin.bulk.cancel"),
    }
end

builders.playtest = function()
    return "FREEROAM PLAYTEST", {
        action("Everyone → Foot Race queue", nil, "admin.playtest.foot"),
        action("Everyone → Vehicle Race queue", nil, "admin.playtest.race"),
        action("Everyone → Free-for-all", nil, "admin.playtest.ffa"),
        action("Everyone → Blade FFA", nil, "admin.playtest.blade"),
        action("Cancel pending transfers", nil, "admin.playtest.cancel"),
    }
end

builders.player = function(playerId)
    local row = playerRow(playerId)
    local title = row ~= nil and playerLabel(row) or ("PLAYER " .. tostring(playerId))
    local target = tostring(playerId)
    if row == nil then return title, { {label = "Player disconnected", value = "OFFLINE"} } end
    local health
    if row ~= nil and row.health ~= nil and row.maxHealth ~= nil then
        health = string.format("%d/%d", math.floor(row.health), math.floor(row.maxHealth))
    end
    return title, {
        { label = "Identity", value = tostring(row.identifier or "unknown") },
        { label = "Role", value = table.concat(row.roles or {}, ", ") ~= "" and table.concat(row.roles, ", ") or "player" },
        { label = "State", value = not row.incarnated and "loading" or (row.dead and "dead" or "alive") },
        { label = "Routing bucket", value = tostring(row.bucket or 0) },
        { label = "Health / armor", value = (health or "--") .. " / " .. tostring(row.armor or 0) },
        { label = "Position", value = row.position and string.format("%.0f %.0f %.0f", row.position.x, row.position.y, row.position.z) or "unavailable" },
        -- The bucket is disclosed rather than prevented: a player in a non-zero
        -- routing bucket is inside a gamemode's match, this resource cannot ask
        -- that gamemode whether the move is safe, and the server says the same
        -- thing in its reply. `(row.bucket or 0)` because a concatenation
        -- against a nil bucket would take the whole screen down.
        action("Teleport to",
            row ~= nil and (row.bucket or 0) ~= 0 and ("bucket " .. row.bucket) or nil,
            "admin.player.goto", target),
        action("Bring here", nil, "admin.player.bring", target),
        action("Observe", "noclip", "admin.player.observe", target),
        action("Heal", health, "admin.player.heal", target),
        action("Revive", nil, "admin.player.revive", target),
        action("God mode", row and row.godMode and "on" or "off", "admin.player.god", target),
        -- The SAME screen as the root Weapons item, carrying a target instead
        -- of `me`. One builder, so the class list and the slot policy cannot
        -- drift between "arm myself" and "arm them".
        opener("Weapons", "weapons", playerId, target),
        opener("Kill", "confirm", { label = "Kill " .. title, tokens = { "admin.player.kill", target } }),
        inputItem("Kick " .. title, { label = "Kick reason", tokens = {"admin.moderate.kick", target}, confirm = true }),
        opener("Ban", "ban", playerId),
    }
end

--- Ban durations. The command's own grammar: a unit is REQUIRED and `perm` is
--- explicit, because a bare number there is reason text (see server/players.lua).
local kBanDurations = { "30m", "2h", "12h", "7d", "perm" }

builders.ban = function(playerId)
    local row = playerRow(playerId)
    local target = tostring(playerId)
    local items = {}
    for _, duration in ipairs(kBanDurations) do
        items[#items + 1] = inputItem("Ban " .. (row and playerLabel(row) or target) .. " · " .. duration, {
            label = "Ban reason", tokens = { "admin.moderate.ban", target, duration }, confirm = true,
            hint = duration == "perm" and "Permanent server ban. An explicit confirmation follows." or "Temporary server ban: " .. duration,
        })
    end
    return "BAN " .. target, items
end

--- One deliberate keypress between a stray ENTER and a kick. Every destructive
--- item routes through here; nothing else does, because a confirmation on a
--- heal would only teach the operator to press ENTER twice by reflex.
builders.confirm = function(spec)
    return "CONFIRM", {
        { label = "Cancel", run = function() popNode() end },
        { label = tostring(spec.label), value = "CONFIRM", permission = spec.tokens[1], detail = spec.detail, run = function()
            execute(table.unpack(spec.tokens))
            popNode()
        end },
    }
end

builders.audit = function()
    local items = {}
    for index = #(data.audit or {}), 1, -1 do
        local entry = data.audit[index]
        items[#items + 1] = {label = tostring(entry.actorName) .. " / " .. tostring(entry.action),
            value = entry.ok and "OK" or "FAILED", detail = tostring(entry.detail or "")}
    end
    if #items == 0 then items[1] = {label = "No recent actions"} end
    return "RECENT ACTIONS", items
end

builders.vehicles = function()
    local grouped = groupVehicles()
    local items = {}
    -- Shortcuts first: they are the ones an operator reaches for by name, and
    -- burying them under the manufacturer list to be tidy would make the common
    -- case slower than it is today.
    for _, name in ipairs(grouped.order) do
        items[#items + 1] = opener(name, "vehicleFamily", name, tostring(#grouped.members[name]))
    end
    items[#items + 1] = opener("All manufacturers", "vehicleMakers")
    items[#items + 1] = opener("Speed caps", "speed")
    items[#items + 1] = action("Remove mine", nil, "admin.veh.remove", "mine")
    items[#items + 1] = opener("DVAll…", "confirm", { label = "Delete ALL server vehicles",
        tokens = { "admin.bulk.dvall", "confirm" },
        detail = "All network vehicles, all resources and buckets. Occupants exit first. Cannot be undone." })
    return "VEHICLES", items
end

-- ---------------------------------------------------------------------------
-- Speed caps
--
-- One pending value, adjusted with LEFT/RIGHT and only SENT when an apply item
-- is picked. Deliberately not the noclip-speed pattern of one command per
-- adjustment: governor commands are mutations, floored at
-- `Config.limits.actionIntervalMs` (250 ms) per caller, and the menu's
-- auto-repeat runs at 125 ms -- adjusting live would refuse every other step
-- and write an audit line per keypress.
--
-- "My car" resolves SERVER-side (admin.veh.speed.here): the vehicle the
-- operator is aboard, else the nearest Open77 vehicle within
-- `Config.vehicles.nearRadius`. This menu never guesses an id.
-- ---------------------------------------------------------------------------
local speedCapKph = 100.0

builders.speed = function()
    local bounds = (Config.vehicles.governor or {}).topSpeedKph
        or { min = 0.0, max = 300.0, step = 5.0 }
    local capToken = string.format("%.0f", speedCapKph)
    local capLabel = speedCapKph <= 0 and "off" or (capToken .. " km/h")
    local function requireCap()
        if speedCapKph > 0 then return true end
        status = { text = "raise the cap above 0 first (RIGHT on the Cap row)", ok = false }
        expectMs = nowMs()
        return false
    end
    return "SPEED CAPS", {
        { label = "Cap", value = capLabel,
          adjust = function(delta)
              speedCapKph = math.max(bounds.min,
                  math.min(bounds.max, speedCapKph + delta * (bounds.step or 5.0)))
          end },
        { label = "Cap my car", value = capLabel, permission = "admin.veh.speed.here", run = function()
              if requireCap() then execute("admin.veh.speed.here", capToken) end
          end },
        action("Uncap my car", nil, "admin.veh.speed.clear", "here"),
        -- Server-wide, so it goes through the same one-deliberate-keypress
        -- confirmation as a kick. It is reversible, but it moves under every
        -- driver on the server at once.
        opener("Cap ALL spawned", "confirm", {
            label = "Cap every spawned vehicle at " .. capLabel,
            tokens = { "admin.veh.speed.global", capToken },
        }, capLabel),
        action("Uncap ALL spawned", nil, "admin.veh.speed.clear", "global"),
        opener("Clear every cap", "confirm", {
            label = "Return every vehicle to stock",
            tokens = { "admin.veh.speed.clear", "all" },
        }),
    }
end

builders.vehicleMakers = function()
    if catalogueMakers == nil then
        buildCatalogueIndex()
        return "MANUFACTURERS", { { label = "indexing catalogue...", value = "wait" } }
    end
    local items = {}
    for _, key in ipairs(catalogueMakers.order) do
        items[#items + 1] = opener(catalogueMakers.label[key] or key, "vehicleMaker", key,
            tostring(#catalogueMakers.members[key]))
    end
    if #items == 0 then items[1] = { label = "catalogue unavailable" } end
    return "MANUFACTURERS", items
end

builders.vehicleMaker = function(key)
    local grouped = catalogueMakers
    if grouped == nil then return "MANUFACTURER", { { label = "indexing catalogue..." } } end
    local items = {}
    for _, entry in ipairs(grouped.members[key] or {}) do
        items[#items + 1] = action(entry.name, nil, "admin.veh.spawn", entry.record)
    end
    items[#items + 1] = action("Remove mine", nil, "admin.veh.remove", "mine")
    return (grouped.label[key] or key):upper(), items
end

-- ---------------------------------------------------------------------------
-- Weapons
--
-- ===========================================================================
-- THERE IS NO SEARCH HERE, AND THAT IS NOT AN OMISSION
-- ===========================================================================
-- The full console has a search box over the vehicle catalogue (`cat-search`
-- in web/app.js) because it is FOCUSED: it owns the keyboard and can hold a
-- text field. Here catalogue navigation deliberately stays non-modal; only
-- explicit reason/message forms capture typing. The drill-down IS the
-- idiom on this menu: Vehicles goes family -> manufacturer -> record, Props
-- goes family -> model, and Weapons goes class -> weapon. 189 records across
-- twelve classes is a shorter walk than either of them.
--
-- The chosen slot is sticky across gives, exactly like the props yaw offset:
-- an operator filling out a loadout picks the slot once. `auto` is the default
-- and is resolved SERVER-side against a verified snapshot -- this menu never
-- guesses which slot is free, because it cannot see the loadout without asking
-- for it.
-- ---------------------------------------------------------------------------
local kWeaponSlots = { "auto", "1", "2", "3" }
local weaponSlotIndex = 1

local weaponClasses = nil   -- class key -> { { record, name }, ... }

local function groupWeapons()
    if weaponClasses ~= nil then return weaponClasses end
    local catalog = Open77AdminWeapons
    if type(catalog) ~= "table" or type(catalog.records) ~= "table" then
        weaponClasses = {}
        return weaponClasses
    end
    local members = {}
    for position, record in ipairs(catalog.records) do
        local class = catalog.classes[catalog.classOf[position]]
        local key = class ~= nil and class.key or "other"
        local bucket = members[key]
        if bucket == nil then bucket = {} members[key] = bucket end
        bucket[#bucket + 1] = { record = record, name = catalog.names[position] or record }
        -- 189 records is roughly 600 instructions, well under the 10 000
        -- stride on its own -- but it shares a resume with the input poll that
        -- triggered it, so it yields anyway. One frame, once.
        if position % 60 == 0 then Wait(0) end
    end
    weaponClasses = members
    return weaponClasses
end

--- `nil` means the operator; a number means that player. The command grammar
--- takes `me` for the former, which is resolved server-side against `source`.
local function weaponTarget(playerId)
    return playerId == nil and "me" or tostring(playerId)
end

local function weaponTitle(playerId)
    if playerId == nil then return "WEAPONS" end
    local row = playerRow(playerId)
    return "WEAPONS " .. (row ~= nil and playerLabel(row) or tostring(playerId))
end

builders.weapons = function(playerId)
    local catalog = Open77AdminWeapons
    local target = weaponTarget(playerId)
    local slot = kWeaponSlots[weaponSlotIndex]
    local items = {
        { label = "Slot", value = slot,
          -- Wraps, like the menu's own selection: four values is quicker to
          -- reach the end of by going left than by holding right.
          adjust = function(delta)
              weaponSlotIndex = ((weaponSlotIndex - 1 + delta) % #kWeaponSlots) + 1
          end },
        action("Refill ammo", "full", "admin.weap.ammo", target, "all"),
        action("Holster", nil, "admin.weap.holster", target),
        action("Clear slots", nil, "admin.weap.remove", target, "all"),
    }
    if type(catalog) ~= "table" or type(catalog.classes) ~= "table" then
        items[#items + 1] = { label = "catalogue unavailable" }
        return weaponTitle(playerId), items
    end
    for _, class in ipairs(catalog.classes) do
        items[#items + 1] = opener(class.label, "weaponClass",
            { class = class.key, target = playerId }, tostring(class.count))
    end
    return weaponTitle(playerId), items
end

builders.weaponClass = function(spec)
    local catalog = Open77AdminWeapons
    local grouped = groupWeapons()
    local class
    for _, candidate in ipairs((catalog or {}).classes or {}) do
        if candidate.key == spec.class then class = candidate break end
    end
    local target = weaponTarget(spec.target)
    -- Repeated here, not just on the parent screen: this is where the operator
    -- is standing when they change their mind about the slot, and walking back
    -- up to change it is the kind of friction that makes people stop using a
    -- menu.
    local items = {
        { label = "Slot", value = kWeaponSlots[weaponSlotIndex],
          adjust = function(delta)
              weaponSlotIndex = ((weaponSlotIndex - 1 + delta) % #kWeaponSlots) + 1
          end },
    }
    for _, entry in ipairs(grouped[spec.class] or {}) do
        -- The slot token is read INSIDE the closure, so what the row above
        -- says is always what is sent -- a value captured at build time would
        -- go stale the moment the operator adjusted it. `execute` drops empty
        -- tokens, which is why this is always a real word rather than "".
        items[#items + 1] = { label = entry.name, permission = "admin.weap.give",
            value = class ~= nil and class.ammo ~= true and "melee" or nil,
            run = function()
                execute("admin.weap.give", target, entry.record,
                    kWeaponSlots[weaponSlotIndex])
            end }
    end
    if #items == 1 then items[#items + 1] = { label = "no records in this class" } end
    return ((class ~= nil and class.label or spec.class):upper()), items
end

builders.props = function()
    local models = (Config.props or {}).models or {}
    local grouped = groupAliases("models", models)
    local items = {
        { label = "Aim distance", value = string.format("%.0f m", aimDistance),
          adjust = function(delta)
              aimDistance = math.max(kAimMin, math.min(kAimMax, aimDistance + delta * kAimStep))
          end },
        { label = "Yaw offset", value = string.format("%+.0f deg", yawOffset),
          adjust = function(delta)
              yawOffset = normaliseYaw(yawOffset + delta * kYawStep)
          end },
        { label = "Reset yaw", run = function()
              yawOffset = 0.0
              status = { text = "yaw offset reset to 0 deg", ok = true }
          end },
        opener("Effects", "effects"),
        action("Clear my props", nil, "admin.props.clear"),
    }
    for _, name in ipairs(grouped.order) do
        items[#items + 1] = opener(name, "propFamily", name, tostring(#grouped.members[name]))
    end
    return "PROPS", items
end

builders.propFamily = function(name)
    local models = (Config.props or {}).models or {}
    local grouped = groupAliases("models", models)
    local items = {}
    for _, alias in ipairs(grouped.members[name] or {}) do
        -- The family prefix is already the screen title; repeating it in every
        -- row would push the useful half of the name off a 340px strip.
        local short = alias:sub(#name + 2)
        items[#items + 1] = { label = short ~= "" and short or alias, permission = "admin.props.spawn", run = function()
            runAtAim("admin.props.spawn", alias)
        end }
    end
    return name:upper(), items
end

builders.effects = function()
    local effects = (Config.props or {}).effects or {}
    local grouped = groupAliases("effects", effects)
    -- The show is not one of the aliases below and must not be filed under
    -- them: those rows each play ONE effect, and this one runs a timed sequence
    -- the server broadcasts. It sits at the top of the screen, where an
    -- operator reaching for fireworks looks first.
    --
    -- `runAtAim` passes its second argument as the first token, which for this
    -- command is the round count -- so the volleys go off over whatever the
    -- operator is looking at, not over their own head.
    local fireworks = (Config.props or {}).fireworks or {}
    local rounds = tostring(math.floor(tonumber(fireworks.rounds) or 8))
    local items = {
        opener("Scripted shows", "shows"),
        { label = "Fireworks show", value = rounds .. " volleys", permission = "admin.fx.fireworks",
          run = function() runShowAtAim("admin.fx.fireworks", rounds) end },
        action("Stop the show", nil, "admin.fx.show.stop"),
        -- The venue, not a show: looping effects that stay until they are taken
        -- down. Both rows sit here because an operator dressing a place is
        -- thinking about effects, not about a separate screen.
        action("Raise the stage", nil, "admin.fx.stage"),
        action("Take the stage down", nil, "admin.fx.stage.clear"),
    }
    -- The drone adapter, and only when its resource is actually running: an
    -- operator should never be offered a row that cannot work.
    local drones = (Config.props or {}).drones or {}
    if drones.resource ~= nil and GetResourceState(drones.resource) == "running" then
        table.insert(items, 1, opener("Drone shows", "drones"))
    end
    local celebrations = (Config.props or {}).celebrations or {}
    if celebrations.resource ~= nil and GetResourceState(celebrations.resource) == "running" then
        table.insert(items, 1, opener("Fireworks & celebrations", "celebrations"))
    end
    for _, name in ipairs(grouped.order) do
        items[#items + 1] = opener(name, "effectFamily", name, tostring(#grouped.members[name]))
    end
    return "EFFECTS", items
end

--- One row per configured show, with how long it runs. `runAtAim` passes the
--- preset name as the first token, so the show plays over whatever the operator
--- is looking at.
builders.shows = function()
    local shows = (Config.props or {}).shows or {}
    local names = {}
    for name in pairs(shows) do names[#names + 1] = name end
    table.sort(names)
    local items = {}
    for _, name in ipairs(names) do
        local last = 0
        for _, cue in ipairs(shows[name] or {}) do
            last = math.max(last, tonumber(cue.at) or 0)
        end
        items[#items + 1] = {
            label = (name:gsub("^%l", string.upper)),
            value = string.format("%.0fs", last / 1000.0),
            permission = "admin.fx.show",
            run = function() runShowAtAim("admin.fx.show", name) end,
        }
    end
    if #items == 0 then items[1] = { label = "No shows configured" } end
    return "SHOWS", items
end

--- The drone shows, when `rp_drones` is running. An ADAPTER: this package owns
--- none of it, so the rows vanish rather than fail when the resource is absent,
--- and the show names come from config as a convenience -- a wrong one answers
--- with that resource's own usage line.
---
--- The yaw is passed explicitly because a drone show is a PICTURE and it has to
--- face the viewer: `droneshow <show> <yaw>` hangs it on that heading, and the
--- camera's own horizontal heading is the one an operator means.
builders.celebrations = function()
    local config = (Config.props or {}).celebrations or {}
    local command = config.command or "fireworks"
    local items = {}
    for _, show in ipairs(config.shows or {}) do
        items[#items + 1] = {
            label = show.label or show.name,
            permission = command,
            run = function() execute(command, show.name) end,
        }
    end
    items[#items + 1] = action("Stop the celebration", nil, command, "stop")
    return "FIREWORKS & CELEBRATIONS", items
end

builders.drones = function()
    local drones = (Config.props or {}).drones or {}
    local command = drones.command or "droneshow"
    local items = {}
    for _, show in ipairs(drones.shows or {}) do
        items[#items + 1] = {
            label = show.label or show.name,
            permission = command,
            run = function() execute(command, show.name, string.format("%.1f", cameraHeading())) end,
        }
    end
    if #items == 0 then items[1] = { label = "No shows configured" } end
    items[#items + 1] = action("Stop every show", nil, command, "stop")
    return "DRONE SHOWS", items
end

builders.effectFamily = function(name)
    local effects = (Config.props or {}).effects or {}
    local grouped = groupAliases("effects", effects)
    local items = {}
    for _, alias in ipairs(grouped.members[name] or {}) do
        local short = alias:sub(#name + 2)
        items[#items + 1] = { label = short ~= "" and short or alias, permission = "admin.fx.play", run = function()
            runAtAim("admin.fx.play", alias)
        end }
    end
    return name:upper(), items
end

builders.self = function()
    local travel = Open77 ~= nil and Open77.travel or nil
    local noclip
    if type(travel) == "table" and type(travel.isNoclip) == "function" then
        noclip = travel.isNoclip() == true and "on" or "off"
    end
    local me = meRow()
    local speed = Config.travel.speed
    return "SELF", {
        opener("Morph / original character", "morph"),
        action("Noclip", noclip, "admin.self.noclip"),
        action("Fly", nil, "admin.self.fly"),
        { label = "Noclip speed", permission = "admin.self.speed",
          value = string.format("%.0f m/s", data.noclipSpeed or speed.default),
          -- The value is written by the command's own reply, not guessed here:
          -- `admin.self.speed` is the authority and the client half mirrors it
          -- back on `open77_admin:travel`. This row only sends.
          -- Proportional, not fixed. A constant increment cannot serve a
          -- range spanning three orders of magnitude: fine enough to trim 5 m/s
          -- is unusably slow at 300, and coarse enough for 300 cannot express 5.
          -- Stepping by a fraction of the current speed gives both, and the
          -- configured `step` survives as a floor so the low end still moves.
          adjust = function(delta)
              local current = data.noclipSpeed or speed.default
              local increment = math.max(speed.step or 1.0,
                  current * (speed.stepFraction or 0.15))
              local wanted = math.max(speed.min,
                  math.min(speed.max, current + delta * increment))
              data.noclipSpeed = wanted
              execute("admin.self.speed", string.format("%.1f", wanted))
          end },
        action("God mode", me and me.godMode and "on" or "off", "admin.self.god"),
        action("Heal", nil, "admin.self.heal"),
        action("Revive", nil, "admin.self.revive"),
        action("Copy position", nil, "admin.self.pos"),
    }
end

--- Weather preset names belong to `open77_weather`, which owns `weather.set`
--- and validates them. They are listed rather than discovered because there is
--- no cross-resource read on this platform; an unknown name comes back as a
--- usage line from that resource, not as a fault here.
local kWeather = { "sunny", "lightclouds", "cloudy", "rain", "heavyclouds", "fog", "pollution", "sandstorm" }
local kTimes = {
    { label = "Dawn", value = "06:00" },
    { label = "Noon", value = "12:00" },
    { label = "Dusk", value = "18:00" },
    { label = "Night", value = "22:00" },
    { label = "Midnight", value = "00:00" },
}

builders.world = function()
    return "WORLD", {
        opener("Teleport", "locations", nil, tostring(#data.locations)),
        opener("Time", "time"),
        opener("Weather", "weather"),
        inputItem("Announcement", { tokens = {"admin.world.announce"}, label = "Server announcement", confirm = true }),
        opener("Cleanup vehicles", "confirm", {label = "Remove admin vehicles", tokens = {"admin.world.cleanup"}}),
    }
end

builders.developer = function()
    return "DEVELOPER", { opener("Doors", "developerDoors") }
end

local morphAppearance = ""
local morphRequest = {category="all",query="",page=1}
local function searchModels(category, query, page, enter)
    morphRequest = {category=category,query=query,page=page}
    data.morphCatalogue = nil
    if enter then pushNode("morphCatalogue") end
    execute("admin.self.morph.search", category, page, query)
end
builders.morph = function()
    local model = type(GetPlayerModel) == "function" and GetPlayerModel() or nil
    return "MORPH", {
        {label="Current model", value=model and model.record or "Original character"},
        {label="State", value=model and model.status or "original"},
        action("Unmorph — original character", nil, "admin.self.unmorph"),
        inputItem("Search all morphs…", {tokens={"admin.self.morph.search"}, label="Character name, ID or category",
            hint="Extracted records, not guaranteed compatible. Up to 8 words.",
            onSubmit=function(query) searchModels("all", query, 1, true) end}),
        opener("Browse categories", "morphCategories"),
        inputItem("Enter Character.* ID…", {tokens={"admin.self.morph"}, label="Exact record ID",
            hint="Also accepts custom records installed on every client.",
            onSubmit=function(record) execute("admin.self.morph", record, morphAppearance) end}),
        inputItem("Set appearance override…", {tokens={"admin.self.morph"}, maxBytes=128,
            label="Exact appearance name", hint="Optional. Applies to subsequent morph selections.",
            onSubmit=function(appearance) morphAppearance=appearance end}),
        {label="Use record's default appearance", value=morphAppearance=="" and "selected" or morphAppearance,
            permission="admin.self.morph", run=function() morphAppearance="" end},
        action("Rogue", "humanoid", "admin.self.morph", "Character.Rogue", morphAppearance),
        action("Johnny (photo mode)", "humanoid", "admin.self.morph", "Character.JohnnyNPC_Puppet_Photomode", morphAppearance),
        opener("Adam Smasher…", "confirm", {label="Morph into Adam Smasher",
            detail="Special rig: vehicle seat animations are not compatible. Other special actions may differ.",
            tokens={"admin.self.morph","Character.Smasher",morphAppearance}}),
    }
end
builders.morphCategories = function()
    local items = {}
    for _, pair in ipairs({{"all","All records"},{"quest_or_story","Quest / story"},{"gang","Gangs"},
        {"crowd","Crowd"},{"civilian","Civilians"},{"police","Police"},{"vendor","Vendors"},
        {"other_human_or_special","Other / special"},{"robot","Robots"},{"animal","Animals"},
        {"child","Children"},{"player","Player bodies"}}) do
        local category = pair[1]
        items[#items+1] = {label=pair[2],arrow=true,permission="admin.self.morph.search",
            run=function() searchModels(category,"",1,true) end}
    end
    return "MORPH CATEGORIES", items
end
builders.morphCatalogue = function()
    local result = data.morphCatalogue
    local request = morphRequest
    local items = {
        inputItem("Search in this category…", {tokens={"admin.self.morph.search"}, label="Search records",
            hint="Extracted data, not in-game certification. Up to 8 words.",
            onSubmit=function(query) searchModels(request.category,query,1,false) end}),
        {label="Refresh / retry", permission="admin.self.morph.search",
            run=function() searchModels(request.category,request.query,request.page,false) end},
    }
    if not result then items[#items+1]={label="Searching catalogue…",value="please wait"}; return "MORPH CATALOGUE",items end
    items[#items+1] = {label=result.total .. " records",value="Page " .. result.page .. "/" .. result.pages}
    for _, entry in ipairs(result.records or {}) do
        local label = entry.record:sub(11):gsub("_", " ")
        items[#items+1] = opener(label, "confirm", {label="Morph into " .. label,
            detail=entry.record .. " · " .. entry.risk .. ". Compatibility is not guaranteed.",
            tokens={"admin.self.morph",entry.record,morphAppearance}}, entry.category)
    end
    if result.total == 0 then items[#items+1]={label="No matching records"} end
    if result.page > 1 then items[#items+1]={label="Previous page",permission="admin.self.morph.search",
        run=function() searchModels(request.category,request.query,result.page-1,false) end} end
    if result.page < result.pages then items[#items+1]={label="Next page",permission="admin.self.morph.search",
        run=function() searchModels(request.category,request.query,result.page+1,false) end} end
    items[#items+1]=action("Unmorph — original character",nil,"admin.self.unmorph")
    return "MORPH CATALOGUE",items
end

builders.targetPlayer = function(id)
    local target = tostring(id)
    return "PLAYER " .. target, {
        {label="Player ID", value=target},
        opener("Player details", "player", id),
        action("Heal", nil, "admin.player.heal", target),
        action("Revive", nil, "admin.player.revive", target),
        action("Teleport to", nil, "admin.player.goto", target),
        action("Bring here", nil, "admin.player.bring", target),
        inputItem("Kick player…", {label="Kick reason", tokens={"admin.moderate.kick",target}, confirm=true}),
        opener("Ban player…", "ban", id),
    }
end
builders.targetVehicle = function(id)
    local target = tostring(id)
    return "VEHICLE " .. target, {
        {label="Vehicle ID", value=target},
        action("Repair body / glass", "safe when occupied", "admin.veh.repair", target, "visual"),
        action("Full repair", "empty vehicle only", "admin.veh.repair", target, "full"),
        action("Lock", nil, "admin.veh.flag", target, "locked", "on"),
        action("Unlock", nil, "admin.veh.flag", target, "locked", "off"),
        opener("Delete vehicle…", "confirm", {label="Delete vehicle " .. target,
            detail="Only an empty vehicle can be deleted.", tokens={"admin.veh.remove",target}}),
    }
end
builders.targetDoor = function(selected)
    local door = Open77.doors.state(selected.id)
    if not door then return "DOOR", {{label="Door is no longer streamed"}} end
    local items = {
        {label="Door ID", value=door.id},
        {label="State", value=door.sealed and "SEALED" or door.locked and "LOCKED" or door.open and "OPEN" or "CLOSED"},
    }
    if door.lift then
        items[#items+1] = {label="Lift door", value="Controlled by elevator"}
    else
        items[#items+1] = action("Open (manual)", nil, "admin.dev.doors.control", door.id, "open")
        items[#items+1] = action("Close (manual)", nil, "admin.dev.doors.control", door.id, "close")
        items[#items+1] = action("Restore proximity opening", nil, "admin.dev.doors.control", door.id, "automatic")
    end
    for _, entry in ipairs({{"Lock","lock"},{"Unlock","unlock"},{"Seal","seal"},{"Unseal","unseal"}}) do
        items[#items+1] = action(entry[1], nil, "admin.dev.doors.control", door.id, entry[2])
    end
    return "DOOR", items
end

builders.developerDoors = function()
    local state = Open77AdminDoorInspector.state()
    local toggle = action("Door Inspector", state.available and (state.enabled and "ON" or "OFF") or "UNAVAILABLE",
        "admin.dev.doors.inspect", state.enabled and "off" or "on")
    toggle.detail = state.error or "Local / server state. Amber = mismatch; red = locked/sealed; grey = no server state."
    return "DOORS", {
        toggle,
        { label = "Nearby doors", value = string.format("%d shown / %d nearby", state.count, state.nearby),
          detail = "Up to 8 native labels. Hidden/off-screen doors are culled by the renderer." },
        { label = "Inspector radius", value = tostring(state.radius) .. " m", detail = "Read-only and private to you. Closing the menu keeps labels visible." },
    }
end

builders.locations = function()
    local items = {}
    for _, location in ipairs(data.locations) do
        items[#items + 1] = action(tostring(location.label or location.name), nil,
            "admin.player.at", "me", tostring(location.name))
    end
    if #items == 0 then items[1] = { label = "No destinations", value = "…" } end
    return "TELEPORT", items
end

builders.time = function()
    local items = {}
    for _, entry in ipairs(kTimes) do
        items[#items + 1] = action(entry.label, entry.value, "weather.time.set", entry.value)
    end
    items[#items + 1] = action("Freeze", nil, "weather.time.freeze")
    items[#items + 1] = action("Resume", nil, "weather.time.resume")
    return "TIME", items
end

builders.weather = function()
    local items = {}
    for _, name in ipairs(kWeather) do
        items[#items + 1] = action(name, nil, "weather.set", name)
    end
    items[#items + 1] = action("Random on", nil, "weather.random", "on")
    items[#items + 1] = action("Random off", nil, "weather.random", "off")
    return "WEATHER", items
end

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------
local current = { title = "", items = {} }

--- Rebuild the top frame from its builder and clamp the selection.
---
--- Called on every navigation AND whenever the roster or the destination list
--- changes underneath, which is why a frame stores a builder name rather than a
--- built list: a player who disconnects must not leave a phantom row that still
--- targets their recycled id.
local function rebuild()
    local top = frame()
    if top == nil then
        current = { title = "", items = {} }
        return
    end
    local builder = builders[top.node]
    if builder == nil then
        current = { title = "?", items = {} }
        return
    end
    local title, items = builder(top.arg)
    for _, item in ipairs(items or {}) do item.disabled = not anyPermission(item.permission) end
    current = { title = title, items = items or {} }
    if top.index > #current.items then top.index = #current.items end
    if top.index < 1 then top.index = 1 end
end

local function trail()
    local parts = {}
    for _, entry in ipairs(stack) do
        parts[#parts + 1] = entry.node == "developerDoors" and "doors" or entry.node
    end
    return table.concat(parts, " / ")
end

--- Which slice of a long list is on screen. The selection is kept near the
--- middle of the window except at the two ends, so the list scrolls under a
--- roughly stationary cursor instead of the cursor walking to an edge and
--- stopping.
local function windowFirst(index, total)
    if total <= kWindow then return 1 end
    local first = index - (kWindow // 2)
    if first < 1 then first = 1 end
    if first > total - kWindow + 1 then first = total - kWindow + 1 end
    return first
end

local function draw()
    if page == nil or not pageReady then return end
    if not open then
        page:send("menu:hide", {})
        return
    end
    local top = frame()
    if top == nil then return end
    local total = #current.items
    local first = windowFirst(top.index, total)
    local rows = {}
    for index = first, math.min(first + kWindow - 1, total) do
        local item = current.items[index]
        rows[#rows + 1] = {
            label = tostring(item.label or ""),
            value = item.value ~= nil and tostring(item.value) or nil,
            arrow = item.arrow == true or nil,
            on = (index == top.index) or nil,
            disabled = item.disabled or nil,
        }
    end
    -- Nine rows of five fields is ~100 value nodes against the host's 1024-node
    -- ceiling (`kMaximumEventValues`), so this message is never within a factor
    -- of ten of the limit -- which is the whole reason the menu sends a WINDOW
    -- and not a list. The 183 prop aliases would be ~1100 nodes on their own and
    -- would be dropped in silence.
    page:send("menu:frame", {
        title = tostring(current.title or ""),
        trail = trail(),
        rows = rows,
        first = first,
        total = total,
        index = top.index,
        status = status.text ~= "" and status.text or nil,
        ok = status.ok,
        depth = #stack,
        roles = table.concat(data.access.roles or {}, " / "),
        detail = current.items[top.index] and (current.items[top.index].disabled and "Not granted by your ACL role" or current.items[top.index].detail),
    })
end

-- ---------------------------------------------------------------------------
-- Input: edge detection and auto-repeat
--
-- `Open77.input.isDown` is a level read. Two traps follow from that and both
-- have bitten in other codebases:
--
--   * WITHOUT a down-transition test, holding DOWN scrolls at the frame rate.
--   * WITHOUT priming, a key that was ALREADY down when the menu opened fires
--     instantly. That is not hypothetical here: `/admin` is typed into chat and
--     submitted with ENTER, chat releases the keyboard, and the menu opens
--     while ENTER is very probably still physically down -- which would
--     activate the first item of the root menu before the operator's finger
--     came up. `primeKeys` records that key as down WITHOUT firing and marks it
--     `suppressed`; it stays inert until it is released once.
--
-- The same priming runs on every tick where `isCaptured()` is true, so keys
-- pressed into chat or the full panel cannot leak out of them into this menu
-- the moment focus is released.
-- ---------------------------------------------------------------------------
local kKeys = { "up", "down", "left", "right", "enter", "backspace" }
local held = {}
for _, key in ipairs(kKeys) do held[key] = { down = false, suppressed = false, nextAtMs = 0 } end

--- Record the current physical state without firing anything.
local function primeKeys()
    for _, key in ipairs(kKeys) do
        local state = held[key]
        local down = Open77.input.isDown(key) == true
        state.down = down
        state.suppressed = down
        state.nextAtMs = 0
    end
end

--- True on the down-transition, then on the auto-repeat cadence. False while
--- the key is up, and false for a key that was already down when we started
--- listening until it has been released once.
local function pollKey(key, atMs)
    local state = held[key]
    local down = Open77.input.isDown(key) == true
    if not down then
        state.down = false
        state.suppressed = false
        return false
    end
    if not state.down then
        state.down = true
        if state.suppressed then return false end
        state.nextAtMs = atMs + kRepeatDelayMs
        return true
    end
    if state.suppressed then return false end
    if atMs >= state.nextAtMs then
        state.nextAtMs = atMs + kRepeatIntervalMs
        return true
    end
    return false
end

local function move(delta)
    local top = frame()
    if top == nil then return end
    local total = #current.items
    if total == 0 then return end
    -- Wraps. A nine-row window over a 28-family list is much faster to reach
    -- the end of by going up from the top than by holding down.
    top.index = ((top.index - 1 + delta) % total) + 1
end

local function activate()
    local top = frame()
    if top == nil then return end
    local item = current.items[top.index]
    if item == nil or type(item.run) ~= "function" then return end
    if item.disabled then
        status = { text = "This action is not granted by your ACL role.", ok = false }
        expectMs = nowMs()
        return
    end
    status = { text = "", ok = true }
    item.run()
    primeKeys()
    rebuild()
end

local function currentItem()
    local top = frame()
    if top == nil then return nil end
    return current.items[top.index]
end

local function adjust(delta)
    local item = currentItem()
    if item == nil then return end
    if item.disabled then return false end
    if type(item.adjust) == "function" then
        item.adjust(delta)
        rebuild()
        return true
    end
    return false
end

function closeMenu(why)
    cancelInput()
    if not open then return end
    open = false
    stack = {}
    status = { text = "", ok = true }
    draw()
    Open77.log.info("admin: compact menu closed (" .. tostring(why) .. ")")
end

local function openMenu()
    if open then closeMenu("toggle") return end
    cancelInput()
    open = true
    stack = {}
    pushNode("root")
    status = { text = "", ok = true }
    primeKeys()
    rebuild()
    draw()
    -- The two lists the menu draws but does not own. Both are ordinary
    -- ACL-checked read commands; an operator who lacks them gets an empty
    -- Players or Teleport screen and nothing else breaks.
    if permitted("admin.read.players") then execute("admin.read.players") end
    if permitted("admin.read.world") then execute("admin.read.world") end
    if permitted("admin.read.audit") then execute("admin.read.audit") end
end

-- Same-resource handoff after the targeting package has released mouse focus.
-- Targets and command tokens stay in Lua, never in browser-provided payloads.
Open77AdminContextMenu = {}
function Open77AdminContextMenu.open(mode, target)
    if not permitted("admin") or not pageReady then return false end
    cancelInput()
    open, stack = true, {}
    pushNode("root")
    status = {text="",ok=true}
    if mode == "time" or mode == "weather" then pushNode(mode)
    elseif mode == "door" or mode == "open" or mode == "close" then
        pushNode("targetDoor", target)
        if mode ~= "door" then execute("admin.dev.doors.control", target.id, mode) end
    elseif mode == "vehicle" or mode == "repair" or mode == "fullRepair" or mode == "remove" then
        pushNode("targetVehicle", target)
        if mode == "remove" then
            pushNode("confirm", {label="Delete vehicle " .. tostring(target),
                detail="Only an empty vehicle can be deleted.",tokens={"admin.veh.remove",tostring(target)}})
        elseif mode == "repair" or mode == "fullRepair" then
            execute("admin.veh.repair", tostring(target), mode == "repair" and "visual" or "full")
        end
    else
        pushNode("targetPlayer", target)
        if permitted("admin.read.players") then execute("admin.read.players") end
        if mode == "kick" then
            inputItem("Kick player " .. tostring(target), {label="Kick reason",
                tokens={"admin.moderate.kick",tostring(target)},confirm=true}).run()
        elseif mode == "ban" then pushNode("ban", target)
        elseif mode == "heal" or mode == "revive" then execute("admin.player." .. mode, tostring(target)) end
    end
    primeKeys()
    rebuild()
    draw()
    return true
end
AddEventHandler("open77:contextmenu:opened", function() closeMenu("context targeting") end)

-- ---------------------------------------------------------------------------
-- The input thread
--
-- One `CreateThread`, running for the life of the resource. While the menu is
-- down it sleeps at `kIdleMs` and reads nothing at all; while it is up it polls
-- once a frame. A tick is six `isDown` calls plus the edge tests -- a few
-- hundred VM instructions, two orders of magnitude below the 10 000-instruction
-- stride that gets a resume measured at all.
-- ---------------------------------------------------------------------------
local function tick()
    local atMs = nowMs()

    -- Somebody else legitimately owns the keyboard: chat's composer, the full
    -- panel, the pause menu. Stand down completely, and re-prime so nothing
    -- typed into them leaks here when they release.
    if Open77.input.isCaptured() == true then
        primeKeys()
        return
    end

    local moved = false
    if pollKey("down", atMs) then move(1) moved = true end
    if pollKey("up", atMs) then move(-1) moved = true end
    if pollKey("right", atMs) then
        -- RIGHT is the value increment where a value exists, and otherwise the
        -- FiveM habit of "right opens the submenu" -- which is why the `>`
        -- affordance is drawn on exactly the rows where it does something.
        if adjust(1) then
            moved = true
        else
            local item = currentItem()
            if item ~= nil and item.arrow == true then
                activate()
                moved = true
            end
        end
    end
    if pollKey("left", atMs) then
        -- LEFT is the value decrement where a value exists, and the natural
        -- "go back" everywhere else. One key, two jobs, and never ambiguous:
        -- an item either has an `adjust` or it does not.
        if adjust(-1) then
            moved = true
        elseif popNode() then
            rebuild()
            moved = true
        end
    end
    if pollKey("enter", atMs) then
        activate()
        moved = true
    end
    if pollKey("backspace", atMs) then
        if popNode() then
            rebuild()
            moved = true
        else
            closeMenu("backspace")
            return
        end
    end
    if moved then draw() end
end

-- ---------------------------------------------------------------------------
-- Server -> client
-- ---------------------------------------------------------------------------
RegisterNetEvent("open77_admin:data", function(channel, payload)
    if type(payload) ~= "table" then return end
    if channel == "menu" then
        data.access = type(payload.access) == "table" and payload.access or {commands={}, roles={}}
        data.you = type(payload.you) == "table" and payload.you or nil
        if permitted("admin") then openMenu() end
    elseif channel == "access" then
        data.access = payload
        if form and not permitted(form.spec.tokens[1]) then cancelInput() primeKeys() end
        if not permitted("admin.read.players") then data.players = {} end
        if not permitted("admin.read.world") then data.locations = {} end
        if not permitted("admin.read.audit") then data.audit = {} end
        if open and not permitted("admin") then closeMenu("ACL revoked")
        elseif open then rebuild() draw() end
    elseif channel == "players" and permitted("admin.read.players") then
        -- Lua sends an empty array as `{}`; `ipairs` over it is simply empty,
        -- which is the behaviour we want here. The trap that costs a render is
        -- on the JavaScript side, where `{}` is truthy -- see web/menu.js.
        if payload.offset == nil or payload.offset == 0 then pendingPlayers = {} end
        for _, row in ipairs(payload.players or {}) do pendingPlayers[#pendingPlayers + 1] = row end
        if payload.done == false then return end
        data.players = pendingPlayers
        data.rosterAtMs = nowMs()
        if open then rebuild() draw() end
    elseif channel == "world" then
        data.locations = type(payload.locations) == "table" and payload.locations or {}
        if open then rebuild() draw() end
    elseif channel == "audit" and permitted("admin.read.audit") then
        data.audit = type(payload.entries) == "table" and payload.entries or {}
        if open then rebuild() draw() end
    elseif channel == "morphCatalogue" and permitted("admin.self.morph.search") then
        if payload.category ~= morphRequest.category or payload.query ~= morphRequest.query
            or payload.requestedPage ~= morphRequest.page then return end
        data.morphCatalogue = payload
        if open then rebuild() draw() end
    elseif channel == "morphState" then
        status = {text=tostring(payload.message or ""),ok=payload.ok==true}
        expectMs=nowMs()
        if open then rebuild() draw() end
    end
end)

RegisterNetEvent("open77_admin:announcement", function(text)
    if page and pageReady then page:send("menu:announcement", { text = tostring(text or "") }) end
end)
AddEventHandler("open77_admin:doorInspectorChanged", function()
    if open then rebuild() draw() end
end)
AddEventHandler("open77_admin:notice", function(payload)
    if page and pageReady then page:send("menu:announcement", payload) end
end)

--- Command results become the footer line. Every result on the session arrives
--- here, including chat's own, so only the ones this menu asked for are shown.
RegisterNetEvent("open77:command:result", function(raw, accepted, message)
    if not open then return end
    message = tostring(message or "")
    -- The dispatcher acknowledges queueing first and answers properly second;
    -- showing both would flicker the footer on every action.
    if accepted and message:match("^queued by ") then return end
    local name = tostring(raw or ""):match("^%S+") or ""
    -- The menu's own polling reads must never take over the footer -- but only
    -- while they SUCCEED. A refused read leaves a screen permanently empty, and
    -- swallowing that answer too is how "Players is blank" becomes a bug with
    -- no evidence: the operator simply lacks `command.admin.read.players`.
    if accepted and name:match("^admin%.read%.") then return end
    if not name:match("^admin") and not name:match("^weather%.") then return end
    if message:find("permission_denied:", 1, true) == 1 then
        message = "no permission for /" .. name
    end
    if #message > 90 then message = message:sub(1, 89) .. "…" end
    status = { text = message, ok = accepted == true }
    expectMs = nowMs()
    draw()
end)

--- The noclip speed mirror, so the Self screen shows what the server applied
--- rather than what this file guessed. Sent by client/main.lua's travel
--- handler; a second handler on the same event is fine, the host keeps a list.
RegisterNetEvent("open77_admin:travel", function(action_, value)
    if action_ == "noclipSpeed" then
        data.noclipSpeed = tonumber(value) or data.noclipSpeed
        if open then rebuild() draw() end
    end
end)

--- The full panel is going up. It takes the keyboard, so this menu could not
--- be driven anyway, and two admin surfaces on screen at once is noise.
RegisterNetEvent("open77_admin:open", function()
    closeMenu("full panel")
end)

RegisterNetEvent("open77_admin:close", function()
    -- The server closes the full panel when it moves the operator. That is not
    -- a reason to close this one -- it is designed to survive a teleport --
    -- so nothing happens here. Kept as a statement of intent rather than an
    -- omission somebody will later "fix".
end)

-- The plugin swallows Escape in the window procedure and raises this instead,
-- so an Escape handler on the page would never fire even if the page had focus.
AddEventHandler("open77:pauseKey", function()
    if form then cancelInput() primeKeys() else closeMenu("pauseKey") end
end)

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------
AddEventHandler("onClientResourceStart", function(name)
    if name ~= RESOURCE then return end

    -- Start indexing the vehicle catalogue now, in the background, so it is
    -- ready long before anyone opens Vehicles. Doing it on demand made the
    -- first ENTER cost 1372 records inside a key handler, which is what blew
    -- the execution budget and left the submenu refusing to open at all.
    buildCatalogueIndex()

    local reason
    page, reason = WebUI.create({
        entry = "web/menu.html",
        -- Ordinary navigation stays unfocused; explicit forms temporarily focus
        -- this same HUD surface and release it before returning to the list.
        layer = "hud",
        width = 1920,
        height = 1080,
        -- The list only changes on a keypress, but the repeat runs at 8 rows a
        -- second and a 10 fps surface makes that look dropped. 30 matches the
        -- other HUD surfaces.
        fps = 60,
        -- Above chat (700) and the notification toasts (720), below the full
        -- panel, which is on the "menu" layer and therefore above all of these
        -- whatever its zIndex.
        zIndex = 730,
        transparent = true,
        -- Created VISIBLE and never hidden: on this client build a surface
        -- created hidden never uploads a frame once shown. The body class is
        -- the only visibility authority; the page is fully transparent and
        -- `pointer-events: none` until `menu:frame` arrives.
        visible = true,
    })
    if page == nil then
        Open77.log.error("admin: compact menu WebUI failed: " .. tostring(reason))
        return
    end

    page:setFocus(false, false)

    page:on("menu:ready", function()
        pageReady = true
        draw()
    end)

    -- Reuse the existing transparent HUD: no extra browser/surface for flight.
    -- Poll at 10 Hz and send only changes; keyboard ownership remains native.
    CreateThread(function()
        local previous, previousSpeed, previousPaused, previousBoost, previousSlow
        while page ~= nil do
            local travel = Open77.travel
            local active = type(travel) == "table" and type(travel.isNoclip) == "function" and travel.isNoclip() == true
            local speed = type(travel) == "table" and type(travel.getNoclipSpeed) == "function" and travel.getNoclipSpeed() or nil
            if type(speed) ~= "number" then speed = data.noclipSpeed or Config.travel.speed.default end
            local paused = Open77.input.isCaptured() == true or Open77.session.isMenuOpen() == true
            local boost = active and not paused and (Open77.input.isDown("shift") or Open77.input.isDown("padLeftShoulder")) == true
            local slow = active and not paused and (Open77.input.isDown("alt") or Open77.input.isDown("padRightShoulder")) == true
            if pageReady and (active ~= previous or speed ~= previousSpeed or paused ~= previousPaused or boost ~= previousBoost or slow ~= previousSlow) then
                page:send("menu:noclip", { active = active, speed = speed, paused = paused,
                    effective = speed * (boost and 4 or 1) * (slow and 0.25 or 1), boost = boost, slow = slow })
                TriggerEvent("open77_admin:noclipChanged", active, speed)
                -- Only transitions hit the network, never wheel/keyboard samples.
                if previous ~= nil and active ~= previous then
                    TriggerServerEvent("open77_admin:noclipState", active)
                end
                data.noclipSpeed = speed
                if open then rebuild() draw() end
                previous, previousSpeed, previousPaused, previousBoost, previousSlow = active, speed, paused, boost, slow
            end
            Wait(active and 100 or 300)
        end
    end)

    page:on("menu:viewport", function(payload)
        local rows = type(payload) == "table" and tonumber(payload.rows) or nil
        if rows == nil or rows ~= rows then return end
        kWindow = math.max(3, math.min(12, math.floor(rows)))
        if open then rebuild() draw() end
    end)

    page:on("menu:input:cancel", function() cancelInput() primeKeys() end)
    page:on("menu:input:submit", function(payload)
        if not form or type(payload) ~= "table" or payload.id ~= form.id then return end
        local text = tostring(payload.value or ""):gsub("[%c]", " "):gsub("^%s+", ""):gsub("%s+$", "")
        if text == "" or #text > form.spec.maxBytes then
            page:send("menu:input:error", {message = "Enter 1–" .. form.spec.maxBytes .. " UTF-8 bytes."})
            return
        end
        local spec, title = form.spec, form.title
        local tokens = {}
        for _, token in ipairs(spec.tokens) do tokens[#tokens+1] = token end
        tokens[#tokens+1] = text
        cancelInput()
        if spec.onSubmit then spec.onSubmit(text)
        elseif spec.confirm then pushNode("confirm", { label = title, tokens = tokens, detail = text })
        else execute(table.unpack(tokens)) end
        primeKeys() rebuild() draw()
    end)

    page:on("menu:diag", function(payload)
        if type(payload) ~= "table" then return end
        Open77.log.info("adminmenu: " .. tostring(payload.text or ""))
    end)

    CreateThread(function()
        local nextRosterAtMs = 0
        local nextDoorAtMs = 0
        while page ~= nil do
            if open then
                tick()
                local atMs = nowMs()
                local node = frame() and frame().node
                if node == "targetDoor" and atMs >= nextDoorAtMs then
                    nextDoorAtMs = atMs + 500
                    rebuild() draw()
                end
                if atMs >= nextRosterAtMs then
                    nextRosterAtMs = atMs + kRosterRefreshMs
                    if node ~= "targetDoor" and node ~= "targetVehicle" and node ~= "time" and node ~= "weather"
                        and permitted("admin.read.players") then execute("admin.read.players") end
                    if frame() and frame().node == "audit" and permitted("admin.read.audit") then execute("admin.read.audit") end
                end
                -- The footer keeps the last result for a few seconds and then
                -- clears, so a stale "vehicle 4 spawned" does not sit under an
                -- unrelated screen.
                if expectMs ~= 0 and status.text ~= "" and atMs - expectMs > 6000 then
                    status = { text = "", ok = true }
                    draw()
                end
                Wait(kPollMs)
            else
                Wait(kIdleMs)
            end
        end
    end)

    -- Say so ONCE, at start, if the menu can never be driven. Both failures are
    -- otherwise indistinguishable from "the arrow keys do nothing": `isDown`
    -- answers `false, "permission_denied:input.actions"` without raising, and a
    -- client build without the binding has no `Open77.input` at all.
    if type(Open77.input) ~= "table" or type(Open77.input.isDown) ~= "function" then
        Open77.log.error(
            "admin: Open77.input is absent on this client build -- the compact menu cannot be "
            .. "driven and /adminfull is the only panel")
    else
        local _, refusal = Open77.input.isDown("enter")
        if refusal ~= nil then
            Open77.log.error("admin: the compact menu cannot read the keyboard (" ..
                tostring(refusal) .. ") -- the resource manifest must grant input.actions")
        end
    end
end)

AddEventHandler("onClientResourceStop", function(name)
    if name ~= RESOURCE then return end
    cancelInput()
    page, pageReady, open = nil, false, false
    stack = {}
end)
