-- The open77_remote_camera provider's adapter: it turns the pure authority's records and
-- effects into the two things only a server can do -- hold a replication point
-- for a viewer and tell that viewer's client to draw a panel -- and it is the
-- only place the platform's calling resource ever appears.
--
-- The 19 exports are the public surface, and every one of them resolves its
-- owner from the platform (`GetInvokingResource`/`GetInvokingResourceGeneration`),
-- never from an argument. `RemoteCameraService` is the same surface for code running in
-- this resource (the placement editor): it takes the owner and generation
-- explicitly because there is no invoking resource to ask for.
local epoch = GetCurrentResourceGeneration()
local authority
local journal, cursor = {}, 0
local RECONCILE_MS = 250
local JOURNAL_LIMIT = 256

-- How many capture slots this client hands out, in total, across every resource
-- on it -- panels, HUD views and any other consumer. The native default is 8 and
-- the arrays hold 64; the ceiling here is the client's own, so a value it cannot
-- honour is refused by the client rather than silently rounded.
--
-- Declared like every other operator setting in this tree: the panel can only
-- move it inside this range, and a host without tunable support keeps the
-- default. It is pushed to clients, never read from them: the number is policy,
-- and the client's own report of what it holds is a separate fact. The push is a
-- native transport frame -- `open77:remoteCamera:policy` carrying the integer --
-- so it lands on the client's capture budget before any Lua resource sees it and
-- no resource on that client can raise its own ceiling.
local SLOTS_DEFAULT = 8
local SLOTS_MIN = 1
local SLOTS_MAX = 64
local slotsPolicy = SLOTS_DEFAULT
local slotsPushed = {}

local SLOTS_DECLARATION = {
    slotsPerClient = {
        value = SLOTS_DEFAULT, type = "integer", min = SLOTS_MIN, max = SLOTS_MAX, step = 1,
        apply = "live", label = "Capture slots per client", group = "Remote Camera", order = 1,
        description = "How many camera views one client renders at once, shared by every resource on " ..
            "that client: world screens, HUD views, anything else holding a slot. Each one is a full " ..
            "extra scene render, so this is a budget, not a promise -- beyond it the client refuses " ..
            "the view and the server's log says only that it asked. The ceiling is the native slot " ..
            "table (64) and, in practice, how many slot assets are packed in the archive.",
    },
}

-- `Open77.tunables.declare` raises on a rejected declaration, and a host without
-- tunable support is a supported state -- this resource ships in server profiles
-- that never load the panel. Both degrade to the defaults.
local Tune = nil
if type(Open77) == "table" and type(Open77.tunables) == "table"
    and type(Open77.tunables.declare) == "function" then
    local ok, proxy = pcall(Open77.tunables.declare, SLOTS_DECLARATION)
    if ok then
        Tune = proxy
    else
        print("[remote-camera] tunables unavailable, using defaults: " .. tostring(proxy))
    end
end

-- Read at the point of use: the proxy is a call, and a value hoisted into a
-- local at load time would never move again while the panel reported the new
-- number.
local function slotsPolicyNow()
    if Tune == nil then return SLOTS_DEFAULT end
    local ok, value = pcall(function() return Tune.slotsPerClient end)
    if ok and type(value) == "number" then return math.floor(value) end
    return SLOTS_DEFAULT
end

-- One path for both cases a client needs the number: it just connected, or the
-- operator changed it. A client that already holds the current value is skipped,
-- which is what makes this cheap enough to run every tick.
local function pushPolicy(policy)
    local delivered = 0
    for _, playerId in ipairs(Open77.players.all()) do
        local player = tonumber(playerId)
        if player and slotsPushed[player] ~= policy then
            TriggerClientEvent("open77:remoteCamera:policy", player, policy)
            slotsPushed[player] = policy
            delivered = delivered + 1
        end
    end
    return delivered
end

-- The same policy, reachable from this resource's command file: the Warden panel
-- is the documented way to move a tunable, and a live server also has a chat box.
-- A write goes through `Open77.tunables.set`, so it is validated and persisted
-- exactly like a panel write, and the next tick pushes the new number out.
RemoteCameraSlots = {
    get = slotsPolicyNow,
    default = SLOTS_DEFAULT,
    minimum = SLOTS_MIN,
    maximum = SLOTS_MAX,
    set = function(value)
        if Tune == nil then
            return false, "this server exposes no tunable store; the policy stays at " .. tostring(SLOTS_DEFAULT)
        end
        local called, result, message = pcall(Open77.tunables.set, "slotsPerClient", value)
        if not called then return false, tostring(result) end
        if result == false then return false, tostring(message) end
        return true, tostring(message or "")
    end,
}

-- `Open77.time.monotonic()` returns SECONDS (the runtime divides its millisecond
-- clock by 1000, and other resources multiply it back -- see open77_admin). Every
-- constant here is named `_MS` and meant as milliseconds, so the helper converts
-- instead of quietly shrinking each timeout by a factor of 1000.
local function nowMs()
    return Open77.time.monotonic() * 1000.0
end

local function caller()
    local name, generation = GetInvokingResource(), GetInvokingResourceGeneration()
    if not name or not generation then return nil, "resource_caller_required" end
    return name, generation
end

local function appendJournal(event)
    cursor = cursor + 1
    local entry = {
        cursor = cursor, epoch = epoch, kind = event.kind, action = event.action,
        owner = event.owner, generation = event.generation, revision = event.revision,
    }
    for _, field in ipairs({
        "cameraId", "screenId", "viewId", "leaseId", "playerId", "state", "reason", "key",
    }) do
        local value = event[field]
        if value ~= nil then entry[field] = value end
    end
    journal[#journal + 1] = entry
    if #journal > JOURNAL_LIMIT then table.remove(journal, 1) end
end

-- One replication point per (camera, viewer) pair, whatever asked for it: the
-- panel a player is standing at, the HUD rectangle they opened, and an
-- interest-only lease all name the same point, so three of them cost one.
local function interestKey(player, cameraId)
    return "remote-camera:" .. tostring(cameraId) .. ":" .. tostring(player)
end

-- Platform facts the authority asks for. Readiness is the join-time gate ("this
-- player is not ready to be acted upon yet") and a host without it is a supported
-- state, so its absence means ready.
local function playerReady(player)
    if type(Open77.ready) ~= "table" or type(Open77.ready.isReady) ~= "function" then
        return true
    end
    local ok, ready = pcall(Open77.ready.isReady, player)
    return ok and ready == true
end

-- Where a canonical parent is right now, in the same shape the roster uses.
-- Only the platform's own replicated objects are consultable: a prop or vehicle
-- the world registry owns, or a player. A local entity handle means nothing on
-- the server, and an id nobody recognises is simply `parent_unavailable` -- the
-- panel is then not presented rather than placed at its offset.
local function finiteNumber(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function parentPose(parent)
    if type(parent) ~= "table" then return nil, "invalid_parent" end
    if parent.type == "player" then
        -- `players.get` is the read that always carries the heading; `position`
        -- is the narrower one and only sometimes has it. A missing heading is
        -- `parent_unavailable` rather than zero: the offset would be placed
        -- somewhere the player never was.
        local x, y, z, bucket, yaw
        if type(Open77.players.get) == "function" then
            local read = Open77.players.get(parent.id)
            if type(read) == "table" and type(read.position) == "table" then
                x, y, z, bucket = read.position.x, read.position.y, read.position.z, read.bucket
                yaw = read.yaw or read.heading
            end
        end
        if x == nil then
            local position = Open77.players.position(parent.id)
            if type(position) == "table" then
                x, y, z, bucket, yaw = position.x, position.y, position.z, position.bucket, position.yaw
            end
        end
        if x == nil or not finiteNumber(yaw) then return nil, "parent_unavailable" end
        return { x = x, y = y, z = z, yaw = yaw, bucket = bucket }
    end
    if parent.type == "prop" then
        if type(Open77.props) ~= "table" or type(Open77.props.get) ~= "function" then
            return nil, "parent_unavailable"
        end
        local prop = Open77.props.get(parent.id)
        if type(prop) ~= "table" or type(prop.position) ~= "table"
            or not finiteNumber(prop.yaw) then
            return nil, "parent_unavailable"
        end
        -- A prop's frame is its authored root: a heading, and (PropAttachments.FollowParent)
        -- the transform behind an attached prop is the parent's composed with the
        -- offset, refreshed there. The server transform is an anchor -- an interest
        -- and drop point, not the animated skeleton -- and the authority composes the
        -- panel offset the same way, so this is the platform's own convention rather
        -- than a reading of it.
        return { x = prop.position.x, y = prop.position.y, z = prop.position.z,
            yaw = prop.yaw, bucket = prop.bucket }
    end
    if parent.type == "vehicle" then
        if type(Open77.vehicles) ~= "table" or type(Open77.vehicles.get) ~= "function" then
            return nil, "parent_unavailable"
        end
        local vehicle = Open77.vehicles.get(parent.id)
        if type(vehicle) ~= "table" or type(vehicle.position) ~= "table"
            or type(vehicle.orientation) ~= "table" then
            return nil, "parent_unavailable"
        end
        -- A vehicle reports the frame it is actually in, so it is used in full
        -- (the authority refuses a degenerate quaternion rather than falling
        -- back to the heading).
        return { x = vehicle.position.x, y = vehicle.position.y, z = vehicle.position.z,
            yaw = vehicle.yaw, bucket = vehicle.bucket,
            orientation = { x = vehicle.orientation.x, y = vehicle.orientation.y,
                z = vehicle.orientation.z, w = vehicle.orientation.w } }
    end
    return nil, "invalid_parent"
end

local function readRoster()
    local roster = {}
    local ids = Open77.players.all()
    local positions = nil
    if type(Open77.players.positions) == "function" then
        local ok, value = pcall(Open77.players.positions)
        if ok and type(value) == "table" then positions = value end
    end
    for _, entry in ipairs(ids) do
        local player = tonumber(entry)
        if player then
            local position
            if positions then position = positions[player]
            else position = Open77.players.position(player) end
            if position then
                roster[player] = {
                    x = position.x, y = position.y, z = position.z, bucket = position.bucket,
                    ready = playerReady(player),
                }
            end
        end
    end
    return roster
end

local function applyEffect(effect)
    if effect.op == "interest.set" then
        local ok, reason = Open77.interest.set(effect.player, interestKey(effect.player, effect.cameraId), {
            position = effect.position, radius = effect.radius, bucket = effect.bucket,
        })
        return { player = effect.player, cameraId = effect.cameraId, op = "set",
            ok = ok == true, reason = reason }
    end
    if effect.op == "interest.remove" then
        local ok, reason = Open77.interest.remove(effect.player, interestKey(effect.player, effect.cameraId))
        return { player = effect.player, cameraId = effect.cameraId, op = "remove",
            ok = ok == true, reason = reason }
    end
    if effect.op == "present" then
        TriggerClientEvent("open77:remoteCamera:present", effect.player, effect.presentation)
        return nil
    end
    if effect.op == "dismiss" then
        TriggerClientEvent("open77:remoteCamera:dismiss", effect.player, effect.id)
        return nil
    end
    return nil
end

-- One pass: the authority decides what reality should look like, this applies it,
-- and the interest answers go back in. They are fed back after the loop because
-- they move records -- a refused point makes its presentations unavailable -- and
-- the next pass is the one that acts on the new state.
local function flush()
    local effects = authority.reconcile({ now = nowMs() })
    local results
    for _, effect in ipairs(effects) do
        local result = applyEffect(effect)
        if result then
            results = results or {}
            results[#results + 1] = result
        end
    end
    for _, result in ipairs(results or {}) do
        authority.interestResult(result.player, result.cameraId, result.op, result.ok, result.reason)
    end
end

authority = RemoteCameraAuthority.new({
    generation = Open77.resource.generation,
    roster = readRoster,
    parentPose = parentPose,
    event = appendJournal,
})

-- The trusted surface for code inside this resource. Same arguments as the
-- exports, with the owner and generation named explicitly because there is no
-- invoking resource to read them from.
local function mutate(method)
    return function(owner, generation, ...)
        local result, reason = method(owner, generation, ...)
        if result ~= nil and result ~= false then flush() end
        return result, reason
    end
end

local function changes(owner, generation, since)
    if type(since) ~= "number" or since ~= since or since < 0 or since % 1 ~= 0 or since > cursor then
        return nil, "invalid_cursor"
    end
    local events = {}
    for _, entry in ipairs(journal) do
        if entry.cursor > since and entry.owner == owner and entry.generation == generation then
            local copy = {}
            for key, value in next, entry, nil do
                if key ~= "owner" and key ~= "generation" and key ~= "epoch" then copy[key] = value end
            end
            events[#events + 1] = copy
        end
    end
    return { epoch = epoch, cursor = cursor, events = events,
        reset = #journal > 0 and since < journal[1].cursor - 1 }
end

RemoteCameraService = {
    create = mutate(authority.create),
    configure = mutate(authority.configure),
    get = authority.get,
    list = authority.list,
    remove = mutate(authority.remove),
    setAccess = mutate(authority.setAccess),
    acquire = mutate(authority.acquire),
    release = mutate(authority.release),
    createScreen = mutate(authority.createScreen),
    updateScreen = mutate(authority.updateScreen),
    getScreen = authority.getScreen,
    listScreens = authority.listScreens,
    removeScreen = mutate(authority.removeScreen),
    openView = mutate(authority.openView),
    updateView = mutate(authority.updateView),
    getView = authority.getView,
    listViews = authority.listViews,
    closeView = mutate(authority.closeView),
    changes = changes,
}

-- `kind` says what a refused call looks like: getters and creators answer
-- `nil, reason`, mutators answer `false, reason`. `ids` are the positions
-- (after owner/generation) of id-shaped arguments, coerced so a caller that
-- passes "12" over a wire boundary is not refused for quoting a number.
local EXPORTS = {
    create = { kind = "value" },
    configure = { kind = "ok", ids = { 1 } },
    get = { kind = "value", ids = { 1 } },
    list = { kind = "value" },
    remove = { kind = "ok", ids = { 1 } },
    setAccess = { kind = "ok", ids = { 1, 2 } },
    acquire = { kind = "value", ids = { 1, 2 } },
    release = { kind = "ok", ids = { 1 } },
    createScreen = { kind = "value", ids = { 1 } },
    updateScreen = { kind = "ok", ids = { 1 } },
    getScreen = { kind = "value", ids = { 1 } },
    listScreens = { kind = "value", ids = { 1 } },
    removeScreen = { kind = "ok", ids = { 1 } },
    openView = { kind = "value", ids = { 1, 2 } },
    updateView = { kind = "ok", ids = { 1 } },
    getView = { kind = "value", ids = { 1 } },
    listViews = { kind = "value", ids = { 1 } },
    closeView = { kind = "ok", ids = { 1 } },
    changes = { kind = "value", ids = { 1 } },
}

for name, spec in next, EXPORTS, nil do
    local method = RemoteCameraService[name]
    exports(name, function(...)
        local owner, generation = caller()
        if not owner then
            if spec.kind == "value" then return nil, generation end
            return false, generation
        end
        local args = table.pack(...)
        for _, index in ipairs(spec.ids or {}) do
            if type(args[index]) == "string" then args[index] = tonumber(args[index]) end
        end
        return method(owner, generation, table.unpack(args, 1, args.n))
    end)
end

-- The client's answer to one binding attempt. The attempt id is the whole
-- correlation: a client that answers late -- or answers twice -- for an attempt
-- this record is no longer waiting on changes nothing here. A client can never
-- name a record it was not asked about, and can never move one.
RegisterNetEvent("open77:remoteCamera:present-result", function(id, attempt, ok, reason)
    local player = tonumber(source)
    if not player or player <= 0 or type(ok) ~= "boolean" then return end
    id, attempt = tonumber(id), tonumber(attempt)
    if not id or not attempt then return end
    authority.presentResult(player, id, attempt, ok, type(reason) == "string" and reason or nil)
    flush()
end)

-- A client resource that reloaded lost every native object it was drawing and
-- cannot name them afterwards. The server has no way to see that -- it still
-- holds the bindings it sent -- so the client says so and every presentation it
-- owns is asked for again, which is what brings the panels back without the
-- player walking out of the radius and back in.
RegisterNetEvent("open77:remoteCamera:client-reset", function()
    local player = tonumber(source)
    if not player or player <= 0 then return end
    local forgotten = authority.forgetPlayer(player)
    if forgotten > 0 then
        print(("[remote-camera] client reset player=%d, rebinding %d presentation(s)"):format(player, forgotten))
    end
    flush()
end)

-- A binding that the client had already reported established and then lost (a
-- native teardown, a failed rebind). It carries no attempt and no authority: the
-- server only moves that one record back to `pending`, so the next pass asks
-- again. A client naming a record it does not own changes nothing.
RegisterNetEvent("open77:remoteCamera:present-lost", function(id)
    local player = tonumber(source)
    if not player or player <= 0 then return end
    id = tonumber(id)
    if not id then return end
    if authority.presentationLost(player, id) then flush() end
end)

-- A client that has just loaded this resource asks for the operator's budget
-- rather than waiting to be found by the roster walk: same value, same door as
-- the change push, and it works even when the client is the only one online.
RegisterNetEvent("open77:remoteCamera:policy-request", function()
    local player = tonumber(source)
    if not player or player <= 0 then return end
    slotsPushed[player] = nil
    pushPolicy(slotsPolicyNow())
end)

AddEventHandler("playerDropped", function()
    local player = tonumber(source)
    if not player then return end
    authority.dropPlayer(player, "player_dropped")
    slotsPushed[player] = nil
    flush()
end)

AddEventHandler("onPlayerBucketChange", function(player)
    player = tonumber(player)
    if not player then return end
    -- Views and leases were authorized in the bucket they were opened in, and a
    -- panel's audience is decided per bucket; leaving every record to the next
    -- pass would leave a viewer watching from an instance they are no longer in.
    authority.dropPlayer(player, "bucket_changed")
    flush()
end)

AddEventHandler("onResourceStop", function(name)
    if name ~= GetCurrentResourceName() then return end
    -- Take every presentation off the clients that were drawing them and every
    -- interest point off the host. The host clears this resource's points by
    -- generation, but doing it here means the world and the registry agree at
    -- the moment we stop rather than at the next sweep.
    for _, entry in ipairs(authority.presentations()) do
        TriggerClientEvent("open77:remoteCamera:dismiss", entry.player, entry.id)
    end
    for _, entry in ipairs(authority.interests()) do
        Open77.interest.remove(entry.player, interestKey(entry.player, entry.cameraId))
    end
end)

CreateThread(function()
    while true do
        Wait(RECONCILE_MS)
        flush()
        -- The budget goes out on change and to whoever is new; a client that
        -- already has the current value is skipped, so this costs a roster walk.
        local policy = slotsPolicyNow()
        if policy ~= slotsPolicy then
            slotsPolicy = policy
            print(("[remote-camera] capture slots per client set to %d (pushed to %d)")
                :format(policy, pushPolicy(policy)))
        else
            pushPolicy(policy)
        end
    end
end)
