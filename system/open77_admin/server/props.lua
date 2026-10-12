-- open77_admin -- world props, lights and effects.
--
-- Every handler here is reached only after the C# transport has resolved
-- `command.<name>` against the caller's authenticated identity; nothing in this
-- file re-checks rights, because it cannot. See the header of server/main.lua.
--
-- ===========================================================================
-- FOUR THINGS ABOUT THE PROP REGISTRY THAT SHAPE THIS FILE
-- ===========================================================================
-- 1. A PROP LIVES IN A ROUTING BUCKET, and a prop created into a bucket nobody
--    occupies is invisible to everybody while `create` still reports success.
--    Defaulting to bucket 0 is therefore a silent failure, not a safe default:
--    `open77_props` shipped exactly that bug in `prop.create` and it looked
--    like a broken spawner. Every command here takes the bucket from
--    `Open77.players.position(source).bucket`, and refuses rather than guess.
--
-- 2. MUTATIONS ARE OWNER-SCOPED BY THE HOST. `setTransform`, `update`, `remove`
--    and `clear` act only on props THIS resource created; anything else answers
--    `owned_by_another_resource`. That is a fact about the platform, not a
--    limitation to work around, so it is reported in plain English instead of
--    being swallowed into "0 removed".
--
-- 3. A PROP ORIGIN SITS AT THE MODEL'S BASE. `z` is the ground, not the centre
--    of the object and not eye height, which is why the "at my position" forms
--    pass the operator's own `z` through unchanged.
--
-- 4. A LIGHT PATCH MUST CARRY THE WHOLE LIGHT TABLE. `Open77.props.update`
--    fills an omitted field with its default, so a patch of `{ enabled = false }`
--    silently resets colour, radius and intensity. Switching a lamp off is the
--    commonest thing anybody does to one, so `admin.props.light.toggle` rebuilds
--    the complete table every time -- from this file's own memo first, then from
--    the record, then from the configured defaults, and it SAYS SO when it had
--    to fall back.
-- ===========================================================================

local Config = Admin.Config
local output, push = Admin.output, Admin.push
local finiteNumber, round = Admin.finiteNumber, Admin.round

local Props = Config.props
local RESOURCE = GetCurrentResourceName()

-- ---------------------------------------------------------------------------
-- Availability
--
-- `Open77.props` and `Open77.effects` are injected by the host. A server built
-- without them, or a resource set loaded on an older host, must cost the
-- operator one clear line -- not a raised handler that takes the panel's whole
-- command channel down with it.
-- ---------------------------------------------------------------------------
local function propsReady()
    return type(Open77.props) == "table" and type(Open77.props.create) == "function"
end

local function effectsReady()
    return type(Open77.effects) == "table" and type(Open77.effects.play) == "function"
end

-- ---------------------------------------------------------------------------
-- The ledger
--
-- Not a permission boundary -- the host already scopes every mutation to the
-- creating resource. It is what feeds the per-operator cap, what lets the panel
-- say "9 of your 64", and what remembers a light's colour so a toggle does not
-- have to reconstruct it from a JSON string.
--
-- Ids are kept as STRINGS. The registry hands out a uint64 as a decimal string
-- precisely because a Lua number is a double and identity would start colliding
-- past 2^53; turning it back into a number here would reintroduce that.
-- ---------------------------------------------------------------------------
local spawned = {}          -- [idString] = { owner, model, kind, atMs }
local lights = {}           -- [idString] = the last light table we wrote
local ownedCount = {}       -- [playerId] = number

local function key(id)
    return tostring(id)
end

local function ledgerAdd(id, owner, model, kind, light)
    local idKey = key(id)
    spawned[idKey] = { owner = owner or 0, model = model, kind = kind, atMs = Admin.nowMs() }
    if light ~= nil then lights[idKey] = light end
    if owner ~= nil and owner > 0 then ownedCount[owner] = (ownedCount[owner] or 0) + 1 end
end

local function ledgerDrop(id)
    local idKey = key(id)
    local entry = spawned[idKey]
    lights[idKey] = nil
    if entry == nil then return end
    if entry.owner > 0 and ownedCount[entry.owner] ~= nil then
        ownedCount[entry.owner] = math.max(0, ownedCount[entry.owner] - 1)
    end
    spawned[idKey] = nil
end

--- A leaving operator's props stay in the world -- removing somebody's set
--- dressing because they reconnected would be its own bug -- but the cap has to
--- be released, and a recycled player id must not inherit the previous
--- occupant's tally.
AddEventHandler("onPlayerDisconnected", function(playerIdStr)
    local playerId = tonumber(playerIdStr)
    if playerId == nil then return end
    for _, entry in pairs(spawned) do
        if entry.owner == playerId then entry.owner = 0 end
    end
    ownedCount[playerId] = nil
end)

-- ---------------------------------------------------------------------------
-- Argument parsing
--
-- Same contract as server/players.lua: a number that does not parse is refused
-- with the usage line, never coerced to zero. `finiteNumber` already rejects
-- NaN and both infinities, which a bare `tonumber` does not.
-- ---------------------------------------------------------------------------
local function coordinates(args, first)
    local x = finiteNumber(args[first])
    local y = finiteNumber(args[first + 1])
    local z = finiteNumber(args[first + 2])
    if x == nil or y == nil or z == nil then return nil end
    return { x = x, y = y, z = z }
end

--- Yaw is optional everywhere it appears. Absent means 0; present and
--- unparseable means refused -- NOT `finiteNumber(...) or 0.0`, which swallows
--- the nil and accepts "north" as due north. players.lua paid for that one.
local function yawAt(args, index)
    if args.n < index or args[index] == nil then return 0.0 end
    return finiteNumber(args[index])
end

local function boundedNumber(args, index, bound, label)
    if args.n < index or args[index] == nil then return bound.default end
    local value = finiteNumber(args[index])
    if value == nil then
        return nil, string.format("%s must be a number", label)
    end
    if value < bound.min or value > bound.max then
        return nil, string.format("%s must be %g..%g (got %g)", label, bound.min, bound.max, value)
    end
    return value
end

--- A model is anything the client can resolve: a curated alias, or a raw depot
--- path. The configured list is a convenience, not a whitelist, so an unknown
--- string is passed through -- but an empty one, or one carrying control
--- characters, is refused here rather than by the transport.
local function resolveModel(token, what)
    what = what or "model"
    local missing = string.format("name %s %s -- /admin.props.catalog lists the curated aliases",
        what == "effect" and "an" or "a", what)
    if token == nil then return nil, missing end
    local model = tostring(token):gsub("[%c]", "")
    if model == "" then return nil, missing end
    if #model > 512 then return nil, what .. " name is longer than 512 bytes" end
    return model
end

--- Ids are decimal strings and stay strings. Refusing anything that is not a
--- run of digits also refuses `me`, `all` and a pasted alias, each of which
--- would otherwise reach the host as a "not_found" nobody can interpret.
local function propId(token, what)
    if token == nil then
        return nil, string.format("name %s id -- /admin.props.list shows them", what)
    end
    local text = tostring(token)
    if text:match("^%d+$") == nil then
        return nil, string.format("invalid %s id '%s' -- ids are whole numbers from /admin.props.list",
            what, text)
    end
    return text
end

--- The host's failure vocabulary, in words an operator can act on. Anything
--- unrecognised is passed through verbatim: inventing prose for a code we have
--- not seen would hide the only clue.
local function rejection(reason, id)
    local text = tostring(reason)
    if text == "owned_by_another_resource" then
        return string.format(
            "%s belongs to another resource -- only the resource that created it may change it "
            .. "(open77_props owns what /prop.* created)", tostring(id))
    end
    if text == "not_found" then
        return string.format("no record %s in the registry", tostring(id))
    end
    if text:match("^permission_denied:") ~= nil then
        return text .. " -- the manifest of this resource does not grant that binding"
    end
    return text
end

-- ---------------------------------------------------------------------------
-- Position and bucket
--
-- The bucket is the whole reason these commands require an in-game caller. The
-- console has no body, therefore no bucket, and a console spawn would have to
-- invent one -- which is the invisible-prop bug in point 1 above.
-- ---------------------------------------------------------------------------
local function callerPosition(source)
    if source == nil or source <= 0 then
        return nil, "this command needs an in-game caller: the routing bucket comes from your own position"
    end
    local position = Open77.players.position(source)
    if position == nil then
        return nil, "your position is not readable yet -- try again in a moment"
    end
    return position
end

-- ---------------------------------------------------------------------------
-- Lights
-- ---------------------------------------------------------------------------
local COLOR_KEYS = { "x", "y", "z" }
local COLOR_LABELS = { "red", "green", "blue" }

--- Fill a light table from `[intensity] [radius] [r] [g] [b]` starting at
--- `first`. Colour channels are 0..1 and are carried as x/y/z, not r/g/b: the
--- host reads them through the shared vector reader, so `{ r = 1 }` reaches the
--- client as black with no error anywhere along the way.
local function lightFrom(args, first)
    local bounds = Props.light
    local intensity, failure = boundedNumber(args, first, bounds.intensity, "intensity")
    if intensity == nil then return nil, failure end

    local radius
    radius, failure = boundedNumber(args, first + 1, bounds.radius, "radius")
    if radius == nil then return nil, failure end

    local color = {}
    for index = 1, 3 do
        local channelKey = COLOR_KEYS[index]
        local bound = {
            min = bounds.color.min,
            max = bounds.color.max,
            default = bounds.color.default[channelKey],
        }
        local value
        value, failure = boundedNumber(args, first + 1 + index, bound, COLOR_LABELS[index])
        if value == nil then return nil, failure end
        color[channelKey] = value
    end

    return { intensity = intensity, radius = radius, color = color, spot = false, enabled = true }
end

--- Every field present, every field a number: this is what goes on the wire for
--- an update, and the whole point is that nothing is left for the host to
--- default.
local function normaliseLight(light)
    light = type(light) == "table" and light or {}
    local color = type(light.color) == "table" and light.color or {}
    local defaults = Props.light
    return {
        intensity = tonumber(light.intensity) or defaults.intensity.default,
        radius = tonumber(light.radius) or defaults.radius.default,
        color = {
            x = tonumber(color.x) or defaults.color.default.x,
            y = tonumber(color.y) or defaults.color.default.y,
            z = tonumber(color.z) or defaults.color.default.z,
        },
        spot = light.spot == true,
        enabled = light.enabled ~= false,
    }
end

--- Recover a light's settings, and say how confident that recovery is.
---
--- The registry stores the light as the JSON STRING it was given, and hands it
--- back on `record.light` in that form -- indexing it like a table yields nil
--- for every field and no error at all, which is exactly how a toggle ends up
--- resetting a lamp to white. So: this file's own memo first (authoritative for
--- anything we created), then a real decode, then defaults with `false` so the
--- caller can warn.
local function lightOf(id, record)
    local memo = lights[key(id)]
    if memo ~= nil then return normaliseLight(memo), true end

    local carried = record ~= nil and record.light or nil
    if type(carried) == "table" then return normaliseLight(carried), true end
    if type(carried) == "string" and carried ~= "" and type(json) == "table"
        and type(json.decode) == "function" then
        local ok, decoded = pcall(json.decode, carried)
        if ok and type(decoded) == "table" then return normaliseLight(decoded), true end
    end
    return normaliseLight(nil), false
end

-- ---------------------------------------------------------------------------
-- Registry reads
-- ---------------------------------------------------------------------------
local function positionOf(record)
    if type(record.position) == "table" then return record.position end
    return { x = record.x, y = record.y, z = record.z }
end

local function propRecord(id)
    if not propsReady() then return nil end
    if type(Open77.props.get) == "function" then
        local record = Open77.props.get(id)
        if type(record) == "table" then return record end
    end
    local wanted = key(id)
    for _, record in ipairs(Open77.props.all() or {}) do
        if key(record.id) == wanted then return record end
    end
    return nil
end

local function distanceFrom(origin, record)
    if origin == nil then return nil end
    if tonumber(record.bucket or 0) ~= tonumber(origin.bucket or 0) then return nil end
    local position = positionOf(record)
    local x, y, z = tonumber(position.x), tonumber(position.y), tonumber(position.z)
    if x == nil or y == nil or z == nil then return nil end
    local dx, dy, dz = x - origin.x, y - origin.y, z - origin.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

--- One snapshot of everything the Props tab draws.
---
--- `radius` filters only what CAN be measured: a prop in another routing bucket
--- has no meaningful distance to the caller, so it is counted in the total and
--- left out of the rows rather than being given a fake one.
local function collect(source, radius)
    local origin = source ~= nil and source > 0 and Open77.players.position(source) or nil

    local rows, total, mine = {}, 0, 0
    for _, record in ipairs(propsReady() and (Open77.props.all() or {}) or {}) do
        total = total + 1
        local idKey = key(record.id)
        local ledger = spawned[idKey]
        if ledger ~= nil then mine = mine + 1 end

        local distance = distanceFrom(origin, record)
        local keep = origin == nil or (distance ~= nil and distance <= radius)
        if keep then
            local position = positionOf(record)
            rows[#rows + 1] = {
                id = idKey,
                model = record.model,
                kind = record.kind or "prop",
                bucket = tonumber(record.bucket) or 0,
                yaw = tonumber(record.yaw) or 0.0,
                resource = record.resource,
                ours = ledger ~= nil,
                mine = ledger ~= nil and ledger.owner == source,
                distance = distance ~= nil and round(distance, 1) or nil,
                position = {
                    x = round(tonumber(position.x) or 0.0, 2),
                    y = round(tonumber(position.y) or 0.0, 2),
                    z = round(tonumber(position.z) or 0.0, 2),
                },
                -- Only ever the memo. A record's own `light` is a JSON string,
                -- and a half-decoded one in a panel row would be a lie the
                -- operator cannot see.
                light = lights[idKey],
            }
        end
    end
    table.sort(rows, function(a, b)
        if a.distance ~= nil and b.distance ~= nil and a.distance ~= b.distance then
            return a.distance < b.distance
        end
        if (a.distance == nil) ~= (b.distance == nil) then return a.distance ~= nil end
        return a.id < b.id
    end)

    local effects, effectTotal = {}, 0
    for _, record in ipairs(effectsReady() and (Open77.effects.all() or {}) or {}) do
        effectTotal = effectTotal + 1
        local position = positionOf(record)
        local distance = distanceFrom(origin, record)
        effects[#effects + 1] = {
            id = key(record.id),
            effect = record.effect or record.name,
            bucket = tonumber(record.bucket) or 0,
            resource = record.resource,
            ours = record.resource == RESOURCE,
            distance = distance ~= nil and round(distance, 1) or nil,
            position = {
                x = round(tonumber(position.x) or 0.0, 2),
                y = round(tonumber(position.y) or 0.0, 2),
                z = round(tonumber(position.z) or 0.0, 2),
            },
        }
    end
    table.sort(effects, function(a, b) return a.id < b.id end)

    local shown = math.min(#rows, Props.maxListed)
    while #rows > shown do rows[#rows] = nil end
    while #effects > Props.maxListed do effects[#effects] = nil end

    return {
        props = rows,
        propTotal = total,
        propsOurs = mine,
        effects = effects,
        effectTotal = effectTotal,
        radius = origin ~= nil and radius or nil,
        bucket = origin ~= nil and (origin.bucket or 0) or nil,
        owned = source ~= nil and source > 0 and (ownedCount[source] or 0) or 0,
        cap = Config.limits.propsPerOperator,
        available = propsReady(),
        effectsAvailable = effectsReady(),
        atMs = Admin.nowMs(),
    }
end

--- Prose for a human, and never one line per row: `output` sends a net event
--- and the transport budget is 32 per second per session, so a sixty-prop
--- listing sent a line at a time would spend the whole budget in one tick.
local function proseFor(payload)
    local lines = {}
    if payload.radius ~= nil then
        lines[#lines + 1] = string.format("props within %.0fm in bucket %d (%d of %d, %d created here):",
            payload.radius, payload.bucket or 0, #payload.props, payload.propTotal, payload.propsOurs)
    else
        lines[#lines + 1] = string.format("props (%d of %d):", #payload.props, payload.propTotal)
    end
    if #payload.props == 0 then
        lines[#lines + 1] = "  none"
    end
    for _, row in ipairs(payload.props) do
        lines[#lines + 1] = string.format("  %s  %s  %s  bucket=%d  %s  %.1f %.1f %.1f  owner=%s",
            row.id, row.kind, tostring(row.model), row.bucket,
            row.distance ~= nil and string.format("%.1fm", row.distance) or "-",
            row.position.x, row.position.y, row.position.z, tostring(row.resource))
    end
    return table.concat(lines, "\n")
end

local function effectProse(payload)
    local lines = { string.format("looping effects (%d):", payload.effectTotal) }
    if #payload.effects == 0 then lines[#lines + 1] = "  none" end
    for _, row in ipairs(payload.effects) do
        lines[#lines + 1] = string.format("  %s  %s  bucket=%d  %.1f %.1f %.1f  owner=%s",
            row.id, tostring(row.effect), row.bucket,
            row.position.x, row.position.y, row.position.z, tostring(row.resource))
    end
    return table.concat(lines, "\n")
end

--- The radius argument, shared by the two listing commands.
local function radiusFrom(args, index)
    if args.n < index or args[index] == nil then return Props.nearRadius end
    local value = finiteNumber(args[index])
    if value == nil or value <= 0 or value > Props.maxRadius then
        return nil, string.format("radius must be a number, 0 < r <= %g", Props.maxRadius)
    end
    return value
end

-- ---------------------------------------------------------------------------
-- Creation
-- ---------------------------------------------------------------------------
local function createProp(source, raw, model, position, yaw, bucket, light)
    if not propsReady() then
        return output(source, raw, false, "the prop registry is unavailable on this host")
    end
    -- Never `bucket or 0`. An absent bucket means the caller's position was
    -- unreadable, and a prop in bucket 0 that nobody occupies is invisible while
    -- reporting success -- the one failure mode this file exists to prevent.
    if bucket == nil then
        return output(source, raw, false, "your routing bucket is not readable yet -- try again in a moment")
    end
    if source > 0 then
        local used = ownedCount[source] or 0
        if used >= Config.limits.propsPerOperator then
            return output(source, raw, false, string.format(
                "you already have %d props out (cap %d) -- /admin.props.clear releases them",
                used, Config.limits.propsPerOperator))
        end
    end

    local kind = light ~= nil and "light" or "prop"
    local id, reason = Open77.props.create({
        model = model,
        position = { x = position.x, y = position.y, z = position.z },
        yaw = yaw or 0.0,
        bucket = bucket,
        kind = kind,
        light = light,
    })
    if id == nil then
        return output(source, raw, false, "prop create rejected: " .. rejection(reason, "(new)"))
    end
    ledgerAdd(id, source, model, kind, light)

    local detail = string.format("%s:%s", tostring(id), model)
    if kind == "light" then
        return output(source, raw, true, string.format(
            "light %s created at %.2f %.2f %.2f (bucket %d, intensity %g, radius %g, rgb %g/%g/%g)",
            tostring(id), position.x, position.y, position.z, bucket,
            light.intensity, light.radius, light.color.x, light.color.y, light.color.z)), detail
    end
    return output(source, raw, true, string.format(
        "prop %s created -- %s at %.2f %.2f %.2f (bucket %d, yaw %.1f)",
        tostring(id), model, position.x, position.y, position.z, bucket, yaw or 0.0)), detail
end

-- ---------------------------------------------------------------------------
-- Props: spawn, move, remove, clear
-- ---------------------------------------------------------------------------
Admin.register("admin.props.spawn", {
    help = "Create a world prop at world coordinates, in your own routing bucket.",
    params = {
        { name = "model", help = "A curated alias or a depot path. /admin.props.catalog lists them." },
        { name = "x" }, { name = "y" }, { name = "z" }, { name = "yaw", optional = true },
    },
    requiresPlayer = true, mutation = true,
    handler = function(source, args, raw)
        if args.n < 4 or args.n > 5 then
            return output(source, raw, false, "usage: admin.props.spawn <model> <x> <y> <z> [yaw]")
        end
        local model, modelError = resolveModel(args[1])
        if model == nil then return output(source, raw, false, modelError) end

        local position = coordinates(args, 2)
        if position == nil then
            return output(source, raw, false,
                "invalid coordinates -- z is the GROUND: a prop origin sits at the model's base")
        end
        local yaw = yawAt(args, 5)
        if yaw == nil then return output(source, raw, false, "invalid yaw") end

        local mine, reason = callerPosition(source)
        if mine == nil then return output(source, raw, false, reason) end
        return createProp(source, raw, model, position, yaw, mine.bucket, nil)
    end,
})

Admin.register("admin.props.here", {
    help = "Create a world prop where you are standing.",
    params = {
        { name = "model", help = "A curated alias or a depot path." },
        { name = "yaw", optional = true },
    },
    requiresPlayer = true, mutation = true,
    handler = function(source, args, raw)
        if args.n < 1 or args.n > 2 then
            return output(source, raw, false, "usage: admin.props.here <model> [yaw]")
        end
        local model, modelError = resolveModel(args[1])
        if model == nil then return output(source, raw, false, modelError) end
        local yaw = yawAt(args, 2)
        if yaw == nil then return output(source, raw, false, "invalid yaw") end

        local mine, reason = callerPosition(source)
        if mine == nil then return output(source, raw, false, reason) end
        -- The operator's own `z`, unadjusted. A prop origin is the model's base,
        -- so the player's feet are exactly where the prop should stand; adding
        -- clearance would leave it hanging.
        return createProp(source, raw, model,
            { x = mine.x, y = mine.y, z = mine.z }, yaw, mine.bucket, nil)
    end,
})

Admin.register("admin.props.move", {
    help = "Move a prop this package created to new coordinates.",
    params = { { name = "id" }, { name = "x" }, { name = "y" }, { name = "z" }, { name = "yaw", optional = true } },
    mutation = true,
    handler = function(source, args, raw)
        if args.n < 4 or args.n > 5 then
            return output(source, raw, false, "usage: admin.props.move <id> <x> <y> <z> [yaw]")
        end
        if not propsReady() then
            return output(source, raw, false, "the prop registry is unavailable on this host")
        end
        local id, idError = propId(args[1], "prop")
        if id == nil then return output(source, raw, false, idError) end
        local position = coordinates(args, 2)
        if position == nil then return output(source, raw, false, "invalid coordinates") end
        local yaw = yawAt(args, 5)
        if yaw == nil then return output(source, raw, false, "invalid yaw") end

        -- A transform patch, not a respawn: the client keeps the same entity and
        -- only its position changes, which is what makes a moved prop look like
        -- one object rather than a flicker of two.
        local ok, reason = Open77.props.setTransform(id, { position = position, yaw = yaw })
        if not ok then
            return output(source, raw, false, "prop move rejected: " .. rejection(reason, id))
        end
        return output(source, raw, true, string.format("prop %s moved to %.2f %.2f %.2f (yaw %.1f)",
            id, position.x, position.y, position.z, yaw)),
            string.format("%s->%.0f,%.0f,%.0f", id, position.x, position.y, position.z)
    end,
})

Admin.register("admin.props.remove", {
    help = "Remove one prop or light by id.",
    params = { { name = "id" } },
    mutation = true,
    handler = function(source, args, raw)
        if args.n ~= 1 then return output(source, raw, false, "usage: admin.props.remove <id>") end
        if not propsReady() then
            return output(source, raw, false, "the prop registry is unavailable on this host")
        end
        local id, idError = propId(args[1], "prop")
        if id == nil then return output(source, raw, false, idError) end

        local ok, reason = Open77.props.remove(id)
        if not ok then
            return output(source, raw, false, "prop remove rejected: " .. rejection(reason, id))
        end
        ledgerDrop(id)
        return output(source, raw, true, "prop " .. id .. " removed"), id
    end,
})

Admin.register("admin.props.clear", {
    help = "Remove every prop and light this admin package created.",
    params = {
        { name = "resource", optional = true,
          help = "Only this resource's own props can be cleared; naming another explains why." },
    },
    mutation = true,
    handler = function(source, args, raw)
        if not propsReady() then
            return output(source, raw, false, "the prop registry is unavailable on this host")
        end
        -- `Open77.props.clear()` releases what the CALLING resource created and
        -- nothing else -- the host has no cross-resource clear, and a command
        -- that appeared to offer one would be lying. So a named resource that is
        -- not us is refused with the reason, not silently reinterpreted.
        if args.n >= 1 then
            local target = tostring(args[1]):lower()
            if target ~= RESOURCE and target ~= "mine" and target ~= "me" then
                return output(source, raw, false, string.format(
                    "only %s's own props can be cleared from here: the registry scopes every mutation "
                    .. "to the resource that created the prop. Use that resource's own command "
                    .. "(open77_props ships /prop.clear).", RESOURCE))
            end
        end

        local removed, reason = Open77.props.clear()
        if type(removed) ~= "number" then
            return output(source, raw, false, "prop clear rejected: " .. rejection(reason, "all"))
        end
        -- Emptied IN PLACE, not rebound. `Admin.props` at the foot of this file
        -- hands these tables to the other server files by reference; assigning
        -- fresh ones here would leave them holding the pre-clear ledger forever.
        for id in pairs(spawned) do spawned[id] = nil end
        for id in pairs(lights) do lights[id] = nil end
        for playerId in pairs(ownedCount) do ownedCount[playerId] = nil end
        return output(source, raw, true, string.format("%d prop(s) removed, all created by %s",
            removed, RESOURCE)), tostring(removed)
    end,
})

-- ---------------------------------------------------------------------------
-- Lights
--
-- A light is a prop of kind "light". It does not use the model at all: the
-- client routes every light to the one host entity that carries a light
-- component, because the per-alias hosts carry geometry and no light. The model
-- string is still required to be non-empty, so "light" is passed as a label.
-- ---------------------------------------------------------------------------
local LIGHT_PARAMS = {
    { name = "intensity", optional = true, help = "0..10000, default 20." },
    { name = "radius", optional = true, help = "Metres, 0.1..500, default 10." },
    { name = "r", optional = true, help = "0..1, default 1." },
    { name = "g", optional = true, help = "0..1, default 1." },
    { name = "b", optional = true, help = "0..1, default 1." },
}

Admin.register("admin.props.light", {
    help = "Place a light at world coordinates, in your own routing bucket.",
    params = {
        { name = "x" }, { name = "y" }, { name = "z" },
        LIGHT_PARAMS[1], LIGHT_PARAMS[2], LIGHT_PARAMS[3], LIGHT_PARAMS[4], LIGHT_PARAMS[5],
    },
    requiresPlayer = true, mutation = true,
    handler = function(source, args, raw)
        if args.n < 3 or args.n > 8 then
            return output(source, raw, false,
                "usage: admin.props.light <x> <y> <z> [intensity] [radius] [r] [g] [b]")
        end
        local position = coordinates(args, 1)
        if position == nil then return output(source, raw, false, "invalid coordinates") end
        local light, failure = lightFrom(args, 4)
        if light == nil then return output(source, raw, false, failure) end

        local mine, reason = callerPosition(source)
        if mine == nil then return output(source, raw, false, reason) end
        return createProp(source, raw, "light", position, 0.0, mine.bucket, light)
    end,
})

Admin.register("admin.props.light.here", {
    help = "Place a light where you are standing.",
    params = LIGHT_PARAMS,
    requiresPlayer = true, mutation = true,
    handler = function(source, args, raw)
        if args.n > 5 then
            return output(source, raw, false,
                "usage: admin.props.light.here [intensity] [radius] [r] [g] [b]")
        end
        local light, failure = lightFrom(args, 1)
        if light == nil then return output(source, raw, false, failure) end

        local mine, reason = callerPosition(source)
        if mine == nil then return output(source, raw, false, reason) end
        return createProp(source, raw, "light",
            { x = mine.x, y = mine.y, z = mine.z }, 0.0, mine.bucket, light)
    end,
})

Admin.register("admin.props.light.toggle", {
    help = "Switch a light off or on without respawning it.",
    params = { { name = "id" }, { name = "on|off" } },
    mutation = true,
    handler = function(source, args, raw)
        if args.n ~= 2 then
            return output(source, raw, false, "usage: admin.props.light.toggle <id> <on|off>")
        end
        if not propsReady() then
            return output(source, raw, false, "the prop registry is unavailable on this host")
        end
        local id, idError = propId(args[1], "light")
        if id == nil then return output(source, raw, false, idError) end

        local token = tostring(args[2]):lower()
        local enable
        if token == "on" or token == "1" or token == "true" then enable = true
        elseif token == "off" or token == "0" or token == "false" then enable = false
        else return output(source, raw, false, "state must be on or off") end

        local record = propRecord(id)
        if record == nil then return output(source, raw, false, "no prop " .. id .. " in the registry") end
        -- Refused, not silently ignored: an update carrying a light table for a
        -- prop of kind "prop" is accepted by the registry and does nothing
        -- visible, which reads to the operator as a broken command.
        if record.kind ~= "light" then
            return output(source, raw, false, string.format(
                "prop %s is a %s, not a light", id, tostring(record.kind or "prop")))
        end

        local light, recovered = lightOf(id, record)
        light.enabled = enable
        local ok, reason = Open77.props.update(id, { light = light })
        if not ok then
            return output(source, raw, false, "light toggle rejected: " .. rejection(reason, id))
        end
        lights[key(id)] = light

        local text = string.format("light %s switched %s", id, enable and "on" or "off")
        if not recovered then
            -- Honest about the one case where the toggle is not lossless: the
            -- whole table must be sent, and for a light this resource did not
            -- create there is nothing to send but the defaults.
            text = text .. string.format(
                " -- its settings were not recoverable, so it is now intensity %g, radius %g, white",
                light.intensity, light.radius)
        end
        return output(source, raw, true, text), string.format("%s=%s", id, enable and "on" or "off")
    end,
})

-- ---------------------------------------------------------------------------
-- Effects
--
-- `play` is fire-and-forget: there is no id and nothing to retire. `create`
-- registers a looping record this resource owns, with `ttlMs = 0` -- "until
-- removed" in the registry's own vocabulary. The field is `effect`, not `name`.
-- ---------------------------------------------------------------------------
local function effectPlacement(source, args, usage)
    if args.n == 1 then
        local mine, reason = callerPosition(source)
        if mine == nil then return nil, reason end
        return { x = mine.x, y = mine.y, z = mine.z, bucket = mine.bucket }
    end
    if args.n ~= 4 then return nil, "usage: " .. usage end
    local position = coordinates(args, 2)
    if position == nil then return nil, "invalid coordinates" end
    local mine, reason = callerPosition(source)
    if mine == nil then return nil, reason end
    position.bucket = mine.bucket
    return position
end

Admin.register("admin.fx.play", {
    help = "Play a one-shot effect at your position, or at world coordinates.",
    params = {
        { name = "effect", help = "A curated alias or a depot path. /admin.props.catalog lists them." },
        { name = "x", optional = true }, { name = "y", optional = true }, { name = "z", optional = true },
    },
    requiresPlayer = true, mutation = true,
    handler = function(source, args, raw)
        if not effectsReady() then
            return output(source, raw, false, "the effect registry is unavailable on this host")
        end
        local effect, effectError = resolveModel(args[1], "effect")
        if effect == nil then return output(source, raw, false, effectError) end

        local placement, failure = effectPlacement(source, args, "admin.fx.play <effect> [x y z]")
        if placement == nil then return output(source, raw, false, failure) end

        local ok, reason = Open77.effects.play(effect, {
            position = { x = placement.x, y = placement.y, z = placement.z },
            bucket = placement.bucket,
        })
        if not ok then
            return output(source, raw, false, "fx play rejected: " .. rejection(reason, effect))
        end
        return output(source, raw, true, string.format("fx %s played at %.2f %.2f %.2f (bucket %d)",
            effect, placement.x, placement.y, placement.z, placement.bucket)), effect
    end,
})

Admin.register("admin.fx.loop", {
    help = "Start a looping effect at your position, or at world coordinates.",
    params = {
        { name = "effect" },
        { name = "x", optional = true }, { name = "y", optional = true }, { name = "z", optional = true },
    },
    requiresPlayer = true, mutation = true,
    handler = function(source, args, raw)
        if not effectsReady() then
            return output(source, raw, false, "the effect registry is unavailable on this host")
        end
        local effect, effectError = resolveModel(args[1], "effect")
        if effect == nil then return output(source, raw, false, effectError) end

        local placement, failure = effectPlacement(source, args, "admin.fx.loop <effect> [x y z]")
        if placement == nil then return output(source, raw, false, failure) end

        local id, reason = Open77.effects.create({
            effect = effect,
            position = { x = placement.x, y = placement.y, z = placement.z },
            bucket = placement.bucket,
            ttlMs = 0,
        })
        if id == nil then
            return output(source, raw, false, "fx loop rejected: " .. rejection(reason, effect))
        end
        return output(source, raw, true, string.format("fx %s looping as %s (bucket %d)",
            effect, tostring(id), placement.bucket)), string.format("%s:%s", tostring(id), effect)
    end,
})

Admin.register("admin.fx.stop", {
    help = "Retire a looping effect by id.",
    params = { { name = "id" } },
    mutation = true,
    handler = function(source, args, raw)
        if args.n ~= 1 then return output(source, raw, false, "usage: admin.fx.stop <id>") end
        if not effectsReady() then
            return output(source, raw, false, "the effect registry is unavailable on this host")
        end
        local id, idError = propId(args[1], "effect")
        if id == nil then return output(source, raw, false, idError) end

        local ok, reason = Open77.effects.remove(id)
        if not ok then
            return output(source, raw, false, "fx stop rejected: " .. rejection(reason, id))
        end
        return output(source, raw, true, "fx " .. id .. " stopped"), id
    end,
})

-- ---------------------------------------------------------------------------
-- The fireworks show
--
-- `admin.fx.play` fires one shell and returns. A show is a timed sequence, and
-- a sequence is the one thing a client-side effect cannot carry: the race start
-- plays its own burst from client Lua because every client already holds the
-- same start line and fires once, but a dozen shells over ten seconds run off
-- each client's own timers and drift apart within a round. So this runs on the
-- server, one shell at a time, through the same broadcast `Open77.effects.play`
-- every other command here uses -- one clock, one authority, the same shell at
-- the same world point for everybody in range.
--
-- ONE SHOW AT A TIME, per server and not per operator: two overlapping shows
-- read as one twitchy show, and the second operator would have no way to stop
-- the first. The epoch is what a stop actually does -- the running thread
-- notices its epoch is stale and gives up at the next shell, which is safe
-- everywhere `Wait` is (a thread cannot be killed from outside).
-- ---------------------------------------------------------------------------
local Fireworks = Props.fireworks or {}
local Shows = Props.shows or {}
local Stage = Props.stage or {}
local ShowEffects = Props.showEffects or {}
local showEpoch, showRunning = 0, nil
local stagePieces = {}

local function showNumber(value, fallback)
    local number = finiteNumber(value)
    return number ~= nil and number or fallback
end

--- A cue names its effect in one of three ways, resolved in this order: a key
--- of `props.showEffects`, a curated alias, or a raw depot path. The map comes
--- first so a preset can say `confetti` instead of repeating a forty-character
--- path in six cues -- and so renaming the asset is one edit, not six.
local function showEffect(name)
    if type(name) ~= "string" or name == "" then return nil end
    local mapped = ShowEffects[name]
    return type(mapped) == "string" and mapped or name
end

--- One beat lands on a disc around `centre`, somewhere in the height band.
--- `math.sqrt` on the radius roll is not decoration: without it the points
--- crowd the middle, because a uniform roll on the radius is not a uniform
--- distribution on the disc.
---
--- Uniform is still not enough on its own. Independent draws clump -- that is
--- what randomness does -- and two shells thirty metres apart in the sky read
--- as one smeared burst rather than as two launches. So a point is redrawn
--- until it clears the previous one by `fireworks.minSeparation`, a handful of
--- tries then take what they get: a show must never stall on geometry.
local lastPoint
local function showPoint(centre, radius, minHeight, maxHeight)
    local separation = showNumber(Fireworks.minSeparation, 28.0)
    local point
    for _ = 1, 8 do
        local angle = math.random() * math.pi * 2.0
        local distance = math.sqrt(math.random()) * radius
        point = {
            x = centre.x + math.cos(angle) * distance,
            y = centre.y + math.sin(angle) * distance,
            z = centre.z + minHeight + math.random() * math.max(0.0, maxHeight - minHeight),
        }
        if lastPoint == nil then break end
        local dx, dy, dz = point.x - lastPoint.x, point.y - lastPoint.y, point.z - lastPoint.z
        if (dx * dx + dy * dy + dz * dz) >= separation * separation then break end
    end
    lastPoint = point
    return point
end

--- Which shell a cue that names none gets. A strict rotation is what a script
--- does, not what a fireworks display looks like: the eye picks the cycle out
--- within two volleys. So the shell is drawn at random, minus the one just
--- used, which keeps the variety without ever firing the same shell twice in a
--- row -- the one repetition that reads as a bug rather than as chance.
local lastShell
local function nextShell()
    local shells = Fireworks.shells
    if type(shells) ~= "table" or #shells == 0 then return nil end
    if #shells == 1 then return shells[1] end
    local pick
    repeat pick = shells[math.random(#shells)] until pick ~= lastShell
    lastShell = pick
    return pick
end

--- Fire one copy of a cue. Returns what the registry returned, so the caller
--- can refuse a whole show on its opening beat.
---
--- A cue with a `ttlMs` is a LOOP that retires itself, not a one-shot, and that
--- distinction is what keeps a show from littering. A burst is authored to play
--- out and vanish; a flare burns, a smoke column pours and an arc crackles for
--- as long as anything lets them, so fired as one-shots they are still there
--- when the show has ended. The registry owns that lifetime -- a looping VFX
--- has no duration of its own -- so those cues go through `create` and are
--- retired on the clock instead.
local function fireCue(cue, centre, bucket, withSound)
    local effect = showEffect(cue.effect) or nextShell()
    if effect == nil then return nil, "no shells are configured" end
    local point = showPoint(centre,
        showNumber(cue.radius, showNumber(Fireworks.radius, 30.0)),
        showNumber(cue.minHeight, showNumber(Fireworks.minHeight, 30.0)),
        showNumber(cue.maxHeight, showNumber(Fireworks.maxHeight, 48.0)))
    local ttl = math.floor(showNumber(cue.ttlMs, 0))
    if ttl > 0 then
        return Open77.effects.create({
            effect = effect,
            position = point,
            bucket = bucket,
            ttlMs = ttl,
            -- A looping effect is streamed, not broadcast: its visibility is
            -- `streamingRadius`, and the 90 m default would hide a column from
            -- anyone across the venue.
            streamingRadius = showNumber(cue.streamingRadius, 400.0),
        })
    end
    local sound
    if withSound and type(cue.sound) == "string" then sound = cue.sound end
    return Open77.effects.play(effect, {
        position = point,
        bucket = bucket,
        range = showNumber(cue.range, showNumber(Fireworks.range, 500.0)),
        sound = sound,
    })
end

--- Walk the cue list on the server clock. `at` is milliseconds from the start
--- of the show, so a preset reads as a score rather than as a pile of sleeps,
--- and two cues can share a beat.
local function runCues(cues, centre, bucket, epoch)
    CreateThread(function()
        local elapsed, failures = 0, 0
        for index, cue in ipairs(cues) do
            local at = math.max(0, math.floor(showNumber(cue.at, elapsed)))
            if at > elapsed then
                Wait(at - elapsed)
                elapsed = at
            end
            local count = math.max(1, math.floor(showNumber(cue.count, 1)))
            local spread = math.max(0, math.floor(showNumber(cue.spreadMs, 0)))
            for copy = 1, count do
                -- The epoch is read before every single beat, so a stop lands
                -- within one effect rather than at the end of the show.
                if epoch ~= showEpoch then return end
                -- The opening beat was fired by the handler, synchronously, so
                -- that a bad effect name reached the operator.
                if index > 1 or copy > 1 then
                    local ok = fireCue(cue, centre, bucket, copy == 1)
                    if not ok then failures = failures + 1 end
                end
                if copy < count and spread > 0 then
                    Wait(spread)
                    elapsed = elapsed + spread
                end
            end
        end
        if epoch == showEpoch then
            showRunning = nil
            if failures > 0 then
                Admin.log(string.format("show: %d beat(s) refused by the effect registry", failures))
            end
        end
    end)
end

--- The fireworks show is not a hand-written preset: it is the `fireworks` block
--- expanded into the same cues every other show uses. One engine, one stop, one
--- place where the timing lives.
--- A display is not a metronome, and it is not a wall either. What reads as
--- fireworks is single launches going off here, then there, a couple together,
--- a pause, then a run of them -- so this builds a STREAM of one to a few
--- shells with its own gap each time, and keeps the wall for the finale, where
--- a wall is the point.
---
--- Two numbers do the work and both are deliberate. `spreadMs` is the gap
--- between shells of the same group and it is wide (a third of a second and
--- up), because shells fired 150 ms apart land as one flash. `intervalJitterMs`
--- is what breaks the pulse between groups; without it the ear hears the
--- metronome even when the eye does not.
local function fireworksCues(rounds)
    local perGroup = math.max(1, math.floor(showNumber(Fireworks.burstsPerRound, 2)))
    local burstJitter = math.max(0, math.floor(showNumber(Fireworks.burstJitter, 2)))
    local spread = math.max(0, math.floor(showNumber(Fireworks.spreadMs, 420)))
    local spreadJitter = math.max(0, math.floor(showNumber(Fireworks.spreadJitterMs, 260)))
    local interval = math.max(0, math.floor(showNumber(Fireworks.intervalMs, 500)))
    local intervalJitter = math.max(0, math.floor(showNumber(Fireworks.intervalJitterMs, 900)))
    local finale = math.max(1, math.floor(showNumber(Fireworks.finaleMultiplier, 4)))
    local radius = showNumber(Fireworks.radius, 60.0)
    local minHeight = showNumber(Fireworks.minHeight, 55.0)
    local maxHeight = showNumber(Fireworks.maxHeight, 95.0)
    local cues, at = {}, 0
    for round = 1, rounds do
        local last = round == rounds
        local count = perGroup + math.random(0, burstJitter)
        local gap = spread + math.random(0, spreadJitter)
        if last then
            count = math.max(count, perGroup * finale)
            gap = math.max(90, math.floor(spread / 4))
        end
        -- Every group claims its own patch of sky and its own altitude band, so
        -- the display walks around instead of stacking over one point. The
        -- bands overlap on purpose: a display has near and far shells at once.
        local span = maxHeight - minHeight
        local floorHeight = minHeight + math.random() * span * 0.5
        cues[#cues + 1] = {
            at = at,
            count = count,
            spreadMs = gap,
            radius = radius * (last and 1.0 or (0.45 + math.random() * 0.55)),
            minHeight = floorHeight,
            maxHeight = floorHeight + span * (0.35 + math.random() * 0.45),
            sound = Fireworks.sound,
        }
        at = at + interval + math.random(0, intervalJitter) + count * gap
    end
    return cues
end

--- The placement ladder the show commands share. A player names nothing (the
--- show happens where they stand) or three coordinates; the console has no
--- position and therefore no routing bucket, so it must name both. The bucket
--- is stated, never guessed: a show fired into a bucket nobody occupies is
--- invisible while every call still reports success.
local function showPlacement(source, args, first, usage)
    local hasCoords = args.n >= first + 2
    if source <= 0 then
        if args.n < first + 3 then
            return nil, nil, "the console has no position: " .. usage .. " <x> <y> <z> <bucket>"
        end
        local centre = coordinates(args, first)
        if centre == nil then return nil, nil, "invalid coordinates" end
        local asked = finiteNumber(args[first + 3])
        if asked == nil or asked < 0 then return nil, nil, "invalid bucket" end
        return centre, math.floor(asked)
    end
    local mine, reason = callerPosition(source)
    if mine == nil then return nil, nil, reason end
    if not hasCoords then return { x = mine.x, y = mine.y, z = mine.z }, mine.bucket end
    local centre = coordinates(args, first)
    if centre == nil then return nil, nil, "invalid coordinates" end
    return centre, mine.bucket
end

--- Start a show. Answers `true` once it is running, or the refusal line.
local function startShow(source, raw, cues, centre, bucket)
    if not effectsReady() then
        return output(source, raw, false, "the effect registry is unavailable on this host")
    end
    if type(cues) ~= "table" or #cues == 0 then
        return output(source, raw, false, "that show has no cues")
    end
    if showRunning ~= nil then
        return output(source, raw, false, "a show is already running -- admin.fx.show.stop ends it")
    end
    -- The opening beat is fired here rather than in the thread, so a bad effect
    -- name or a refused permission answers the operator instead of
    -- disappearing into a background coroutine.
    local ok, failure = fireCue(cues[1], centre, bucket, true)
    if not ok then
        return output(source, raw, false, "show rejected: "
            .. rejection(failure, tostring(cues[1].effect or "shell")))
    end
    showEpoch = showEpoch + 1
    showRunning = showEpoch
    runCues(cues, centre, bucket, showEpoch)
    return true
end

local function showNames()
    local names = {}
    for name in pairs(Shows) do names[#names + 1] = name end
    table.sort(names)
    return names
end

Admin.register("admin.fx.fireworks", {
    help = "Run a synchronized fireworks show, seen by every player in range.",
    params = {
        { name = "rounds", help = "Volleys. Default " .. tostring(Fireworks.rounds or 8) .. ".", optional = true },
        { name = "x", optional = true }, { name = "y", optional = true }, { name = "z", optional = true },
        { name = "bucket", help = "Routing bucket. Required from the console only.", optional = true },
    },
    -- NOT `requiresPlayer`, unlike its `admin.fx.*` neighbours, and that is the
    -- point of a show: a countdown, a new year, a race finish are fired by a
    -- script or by an operator at the console, with nobody standing under the
    -- shells.
    mutation = true,
    handler = function(source, args, raw)
        if type(Fireworks.shells) ~= "table" or #Fireworks.shells == 0 then
            return output(source, raw, false, "no firework shells are configured")
        end

        -- The argument ladder, by count: nothing, rounds, coordinates, both, or
        -- -- from the console -- both plus the bucket.
        local rounds = math.floor(showNumber(Fireworks.rounds, 8))
        local roundsGiven = (args.n == 1 or args.n == 4 or args.n == 5)
        if roundsGiven then
            local asked = finiteNumber(args[1])
            if asked == nil or asked < 1 then
                return output(source, raw, false, "rounds must be a number of 1 or more")
            end
            rounds = math.min(math.floor(asked), math.floor(showNumber(Fireworks.maxRounds, 40)))
        elseif args.n ~= 0 and args.n ~= 3 then
            return output(source, raw, false,
                "usage: admin.fx.fireworks [rounds] [x y z], or <rounds> <x y z> <bucket> from the console")
        end

        local centre, bucket, failure = showPlacement(source, args, roundsGiven and 2 or 1,
            "admin.fx.fireworks <rounds>")
        if centre == nil then return output(source, raw, false, failure) end

        local started = startShow(source, raw, fireworksCues(rounds), centre, bucket)
        if started ~= true then return started end

        return output(source, raw, true, string.format(
            "fireworks: %d rounds of %d over %.2f %.2f %.2f (bucket %d), %d shells, seen up to %dm",
            rounds, math.max(1, math.floor(showNumber(Fireworks.burstsPerRound, 3))),
            centre.x, centre.y, centre.z, bucket, #Fireworks.shells,
            math.floor(showNumber(Fireworks.range, 500.0)))),
            string.format("fireworks %dx%d", rounds,
                math.max(1, math.floor(showNumber(Fireworks.burstsPerRound, 3))))
    end,
})

Admin.register("admin.fx.show", {
    help = "Run a scripted show: flares, confetti, petals and shells on one clock.",
    params = {
        { name = "preset", help = "One of " .. table.concat(showNames(), ", ") },
        { name = "x", optional = true }, { name = "y", optional = true }, { name = "z", optional = true },
        { name = "bucket", help = "Routing bucket. Required from the console only.", optional = true },
    },
    mutation = true,
    handler = function(source, args, raw)
        local names = showNames()
        local listed = #names > 0 and table.concat(names, ", ") or "none configured"
        if args.n < 1 then
            return output(source, raw, false, "usage: admin.fx.show <preset> [x y z] -- " .. listed)
        end
        local preset = tostring(args[1])
        local cues = Shows[preset]
        if type(cues) ~= "table" then
            return output(source, raw, false, "no show called " .. preset .. " -- configured: " .. listed)
        end

        local centre, bucket, failure = showPlacement(source, args, 2, "admin.fx.show " .. preset)
        if centre == nil then return output(source, raw, false, failure) end

        local started = startShow(source, raw, cues, centre, bucket)
        if started ~= true then return started end

        local last = 0
        for _, cue in ipairs(cues) do last = math.max(last, showNumber(cue.at, 0)) end
        return output(source, raw, true, string.format(
            "show %s: %d cues over %.1fs at %.2f %.2f %.2f (bucket %d)",
            preset, #cues, last / 1000.0, centre.x, centre.y, centre.z, bucket)), preset
    end,
})

--- Two names for one stop, deliberately. `admin.fx.fireworks.stop` is what an
--- operator who fired the fireworks reaches for, `admin.fx.show.stop` what one
--- who fired a preset does; both end whichever show is running, because there
--- is only ever one.
local function stopShow(source, args, raw)
    if showRunning == nil then
        return output(source, raw, false, "no show is running")
    end
    -- Bumping the epoch is the stop: the thread reads it before its next beat
    -- and returns. Nothing is left to clean up -- a one-shot effect has no
    -- registry entry and plays itself out.
    showEpoch = showEpoch + 1
    showRunning = nil
    return output(source, raw, true, "show ended"), "stopped"
end

Admin.register("admin.fx.fireworks.stop", {
    help = "End the running show.", mutation = true, handler = stopShow,
})

Admin.register("admin.fx.show.stop", {
    help = "End the running show.", mutation = true, handler = stopShow,
})

-- ---------------------------------------------------------------------------
-- The venue
--
-- A show needs somewhere to happen. `admin.fx.stage` dresses one out of LOOPING
-- effects -- a holographic floor, corner beacons, smoke and steam columns --
-- which is a different lifecycle from the show above: a one-shot plays itself
-- out and is gone, a loop stays until something removes it. So these ids are
-- held here and `admin.fx.stage.clear` is the way back, rather than making the
-- operator copy eight ids out of `admin.fx.list`.
--
-- The pieces are placed on world axes, not on the operator heading. A venue is
-- a place, and an operator who walks around it and re-dresses it should get the
-- same venue, not one rotated by wherever they happened to be looking.
-- ---------------------------------------------------------------------------
--- Take the venue down.
---
--- The known ids first -- and then, if there are none, a sweep, because a
--- resource reload builds a fresh Lua state with an empty list while the venue
--- is still standing in the registry. Without the sweep a reload orphans it
--- permanently: `stage.clear` answers "no stage is up" at a player looking
--- straight at a smoke column. The sweep is narrow on purpose: only looping
--- effects THIS resource owns, and only those whose effect is one the stage is
--- made of, so an operator's own `admin.fx.loop` is left alone.
local function clearStage()
    local removed = 0
    for _, id in ipairs(stagePieces) do
        if Open77.effects.remove(id) then removed = removed + 1 end
    end
    stagePieces = {}
    if removed > 0 or type(Stage.pieces) ~= "table" then return removed end

    local mine = {}
    for _, piece in ipairs(Stage.pieces) do
        local effect = showEffect(piece.effect)
        if effect ~= nil then mine[effect] = true end
    end
    for _, record in ipairs(effectsReady() and (Open77.effects.all() or {}) or {}) do
        local effect = record.effect or record.name
        if record.resource == RESOURCE and effect ~= nil and mine[effect] then
            if Open77.effects.remove(record.id) then removed = removed + 1 end
        end
    end
    return removed
end

Admin.register("admin.fx.stage", {
    help = "Dress a venue with looping holograms, beacons and columns.",
    params = {
        { name = "x", optional = true }, { name = "y", optional = true }, { name = "z", optional = true },
        { name = "bucket", help = "Routing bucket. Required from the console only.", optional = true },
    },
    mutation = true,
    handler = function(source, args, raw)
        if not effectsReady() then
            return output(source, raw, false, "the effect registry is unavailable on this host")
        end
        local pieces = Stage.pieces
        if type(pieces) ~= "table" or #pieces == 0 then
            return output(source, raw, false, "no stage pieces are configured")
        end
        if args.n ~= 0 and args.n ~= 3 and args.n ~= 4 then
            return output(source, raw, false, "usage: admin.fx.stage [x y z]")
        end

        local centre, bucket, failure = showPlacement(source, args, 1, "admin.fx.stage")
        if centre == nil then return output(source, raw, false, failure) end

        -- One venue at a time, for the same reason there is one show: a second
        -- one laid over the first is invisible as such, and the operator would
        -- have no way to take the first one down.
        local replaced = clearStage()
        local failures = 0
        for _, piece in ipairs(pieces) do
            local effect = showEffect(piece.effect)
            local id
            if effect ~= nil then
                id = Open77.effects.create({
                    effect = effect,
                    position = {
                        x = centre.x + showNumber(piece.x, 0.0),
                        y = centre.y + showNumber(piece.y, 0.0),
                        z = centre.z + showNumber(piece.z, 0.0),
                    },
                    bucket = bucket,
                    ttlMs = 0,
                })
            end
            if id ~= nil then
                stagePieces[#stagePieces + 1] = id
            else
                failures = failures + 1
            end
        end
        if #stagePieces == 0 then
            return output(source, raw, false, "the stage was refused by the effect registry")
        end

        return output(source, raw, true, string.format(
            "stage: %d pieces at %.2f %.2f %.2f (bucket %d)%s%s",
            #stagePieces, centre.x, centre.y, centre.z, bucket,
            replaced > 0 and string.format(", %d replaced", replaced) or "",
            failures > 0 and string.format(", %d refused", failures) or "")),
            string.format("stage %d", #stagePieces)
    end,
})

Admin.register("admin.fx.stage.clear", {
    help = "Take the venue down.",
    mutation = true,
    handler = function(source, args, raw)
        local removed = clearStage()
        if removed == 0 then
            return output(source, raw, false, "no stage is up")
        end
        return output(source, raw, true, string.format("stage cleared (%d pieces)", removed)), tostring(removed)
    end,
})

-- ---------------------------------------------------------------------------
-- Reads
--
-- Three, and each is its own grant. `admin.read.props` is what the panel polls
-- once a second and it answers in structured data only; the two `list` forms are
-- what a human types and they answer in prose as well. Sharing one command
-- would mean the panel's poll printing a sixty-line listing into the operator's
-- chat every second.
-- ---------------------------------------------------------------------------
Admin.register("admin.read.props", {
    help = "Props and looping effects near you, with the ledger and the caps.",
    params = { { name = "radius", optional = true } },
    handler = function(source, args, raw, _record, invokedAs)
        local radius, failure = radiusFrom(args, 1)
        if radius == nil then return output(source, raw, false, failure) end
        local payload = collect(source, radius)
        push(source, "props", payload)
        if source <= 0 or invokedAs ~= "admin.read.props" then
            output(source, raw, true, proseFor(payload))
        end
        return true
    end,
})

Admin.register("admin.props.list", {
    help = "List the props around you: id, model, kind, distance and bucket.",
    params = { { name = "radius", help = "Metres. Default " .. tostring(Props.nearRadius) .. ".", optional = true } },
    mutation = false,
    handler = function(source, args, raw)
        local radius, failure = radiusFrom(args, 1)
        if radius == nil then return output(source, raw, false, failure) end
        local payload = collect(source, radius)
        push(source, "props", payload)
        return output(source, raw, true, proseFor(payload))
    end,
})

Admin.register("admin.fx.list", {
    help = "List every looping effect in the registry.",
    mutation = false,
    handler = function(source, _, raw)
        local payload = collect(source, Props.nearRadius)
        push(source, "props", payload)
        return output(source, raw, true, effectProse(payload))
    end,
})

Admin.register("admin.props.catalog", {
    help = "List the curated prop model aliases and effect aliases.",
    mutation = false,
    handler = function(source, _, raw)
        -- The host's own catalogue is authoritative when it answers; on the
        -- dedicated server it deliberately returns an empty list, because the
        -- curated table lives on the CLIENT next to the depot paths it resolves.
        -- The configured list is the mirror of that table, and it is what makes
        -- this command useful today.
        local hosted = {}
        if propsReady() and type(Open77.props.catalog) == "function" then
            for _, entry in ipairs(Open77.props.catalog() or {}) do
                if type(entry) == "table" then
                    hosted[#hosted + 1] = tostring(entry.alias or entry.name or entry.model or "?")
                else
                    hosted[#hosted + 1] = tostring(entry)
                end
            end
        end

        push(source, "props", {
            catalog = { models = Props.models, effects = Props.effects, hosted = hosted },
            light = Props.light,
            atMs = Admin.nowMs(),
        })

        local lines = { string.format("prop model aliases (%d):", #Props.models) }
        lines[#lines + 1] = "  " .. table.concat(Props.models, "  ")
        lines[#lines + 1] = string.format("effect aliases (%d):", #Props.effects)
        lines[#lines + 1] = "  " .. table.concat(Props.effects, "  ")
        if #hosted > 0 then
            lines[#lines + 1] = string.format("host catalogue (%d):", #hosted)
            lines[#lines + 1] = "  " .. table.concat(hosted, "  ")
        end
        -- Said once, here, because it is the difference between "this alias is
        -- broken" and "this alias was never tried": the client's own table
        -- records `discoverable_not_individually_validated` for every row.
        lines[#lines + 1] = "a raw depot path is accepted too; no alias is individually validated in game"
        return output(source, raw, true, table.concat(lines, "\n"))
    end,
})

-- ---------------------------------------------------------------------------
-- The shared surface, for the other server files.
-- ---------------------------------------------------------------------------
Admin.props = {
    spawned = spawned,
    lights = lights,
    ownedCount = ownedCount,
    ledgerDrop = ledgerDrop,
    collect = collect,
}
