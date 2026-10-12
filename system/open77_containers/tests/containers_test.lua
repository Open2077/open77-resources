-- =============================================================================
-- open77_containers -- tests/containers_test.lua
-- =============================================================================
-- Offline suite of the container service over the REAL, final A13 coordinator
-- (resources/system/open77_transactions: model, policy, memory store,
-- coordinator) and the container registry's memory store. The coordinator's
-- `allowed` export is reproduced over its real policy object (same rules as
-- server/main.lua there); its `world` and `committed` callbacks drive the
-- service as the host events do. Platform natives (props, bags, interactions,
-- player positions) are recording stubs.
--
-- Loaded after, in this order: open77_transactions shared/model.lua,
-- server/policy.lua, server/memory_store.lua, server/coordinator.lua;
-- open77_containers shared/model.lua, server/store.lua, server/service.lua.
-- Sets TestResult (KeraLua harness) and TestSummary.
-- =============================================================================

local passed, failed, failures = 0, 0, {}
local function check(condition, message)
    if condition then
        passed = passed + 1
    else
        failed = failed + 1
        failures[#failures + 1] = message
    end
end
local function eq(actual, expected, message)
    check(actual == expected, ("%s (expected %s, got %s)"):format(message, tostring(expected), tostring(actual)))
end

local Model = Open77ContainersModel
local TxModel = Open77TxModel
local clock = 1700000000000
local function nowMs() return clock end

-- ---------------------------------------------------------------------------
-- World: a fresh props registry and bag store per "server process".
-- ---------------------------------------------------------------------------
local function newWorld()
    local world = { props = {}, nextProp = 5000, bags = {}, events = {}, defines = {}, grants = {},
        revokes = {}, clears = 0, attaches = {}, positions = {}, failCreate = false }
    world.propsApi = {
        create = function(def)
            if world.failCreate then return nil, "quota_exceeded" end
            world.nextProp = world.nextProp + 1
            local id = tostring(world.nextProp)
            world.props[id] = { id = id, resource = "open77_containers", model = def.model,
                position = Model.deepCopy(def.position), yaw = def.yaw, bucket = def.bucket }
            return id
        end,
        get = function(id) return world.props[id] end,
        remove = function(id)
            if not world.props[id] then return nil, "not_found" end
            world.props[id] = nil
            world.bags[id] = nil
            return true
        end,
        setTransform = function(id, transform)
            local prop = world.props[id]
            if not prop then return nil, "not_found" end
            prop.position = Model.deepCopy(transform.position)
            return true
        end,
        attach = function(id, binding)
            local prop = world.props[id]
            if not prop then return nil, "not_found" end
            prop.attachment = Model.deepCopy(binding)
            world.attaches[#world.attaches + 1] = id
            return true
        end,
        detach = function(id)
            local prop = world.props[id]
            if prop then prop.attachment = nil end
            return true
        end,
    }
    world.bagsApi = {
        set = function(propId, key, value)
            if not world.props[propId] then return nil, "not_found" end
            world.bags[propId] = world.bags[propId] or {}
            world.bags[propId][key] = Model.deepCopy(value)
            return true
        end,
        get = function(propId, key)
            return world.bags[propId] and Model.deepCopy(world.bags[propId][key]) or nil
        end,
    }
    world.interactionsApi = {
        define = function(list)
            world.defines[#world.defines + 1] = Model.deepCopy(list)
            return true
        end,
        clear = function() world.clears = world.clears + 1; world.defines[#world.defines + 1] = {}; return true end,
        grantProp = function(propId, grantee, options)
            world.grants[#world.grants + 1] = { propId = propId, grantee = grantee, options = options }
            return true
        end,
        revokeProp = function(propId, grantee)
            world.revokes[#world.revokes + 1] = { propId = propId, grantee = grantee }
            return true
        end,
    }
    world.playersApi = { position = function(id) return world.positions[id] end }
    return world
end

local function lastDefine(world) return world.defines[#world.defines] end
local function declaredProps(world)
    local set = {}
    for _, definition in ipairs(lastDefine(world) or {}) do
        for _, propId in ipairs(definition.props or {}) do set[propId] = true end
    end
    return set
end
local function eventsNamed(world, name)
    local out = {}
    for _, event in ipairs(world.events) do
        if event.name == name then out[#out + 1] = event end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- One "server process": coordinator + service over the shared durable stores.
-- ---------------------------------------------------------------------------
local txStore = Open77TxMemoryStore.new({ deferred = false })
local registryStore = Open77ContainersStore.memory()
local RESOURCE = "open77_containers"

-- The coordinator's policy tunables. open77_containers forwards every
-- container operation, so the coordinator sees it as the writer and minter:
-- it needs every namespace it forwards and its own mint rules. The real
-- callers are checked by the service through `allowed`.
local WRITERS = "open77_containers, rp_salvage:char+veh/cargo, rp_thief:char"
local MINTS = { "rp_salvage sys:salvage * 1000; open77_containers sys:* * 100000" }

local switches = { allowedDown = false, failClose = false }

-- server/main.lua's `allowed` export of open77_transactions, over its policy.
local function allowedOver(policy)
    return function(resource, target, asset)
        if switches.allowedDown then return false, "coordinator_unavailable" end
        local ns = target:match("^([a-z]+)")
        if ns == nil or TxModel.NAMESPACES[ns] == nil then return false, "invalid_account" end
        if ns == "sys" then
            local mint = asset == nil and { from = target, envelope = true, amount = 0 }
                or { from = target, asset = asset, amount = 0 }
            local ok, why = policy:check(resource, { mint }, nowMs())
            if ok then return true end
            return false, why
        end
        local account = target:find(":", 1, true) and target or nil
        if policy:canWrite(resource, ns, account) then return true end
        return false, "namespace_denied"
    end
end

local function boot(world)
    local service
    local policy = Open77TxPolicy.new({ writers = WRITERS, rules = MINTS })
    local coordinator = Open77TxCoordinator.new({
        store = txStore, now = nowMs, serverTag = "t", policy = policy,
        acl = function(resource, namespace, account) return policy:canWrite(resource, namespace, account) end,
        onCommitted = function(receipt, accounts)
            if service then service:onCommitted(receipt.opId, receipt.kind, accounts) end
        end,
        onWorld = function(id, change, meta)
            if service then service:onWorld(id, change, meta) end
        end,
    })
    coordinator:define({
        scrap = { weightG = 1000 },
        copper = { weightG = 500 },
        crowbar = { weightG = 2000, unique = true },
    }, "rp_items")
    -- The exports as open77_containers calls them (A13 §7.2 signatures).
    local tx = {
        openWorld = function(props, cb) coordinator:openWorld(props, RESOURCE, cb) end,
        read = function(id, cb) coordinator:readAccount(id, cb) end,
        setMeta = function(id, meta, cb) coordinator:setMeta(id, meta, RESOURCE, cb) end,
        close = function(id, cb)
            if switches.failClose then return cb(nil, "store_unavailable", { retryable = true }) end
            coordinator:close(id, RESOURCE, cb)
        end,
        listWorld = function(after, limit, cb) coordinator:listWorld(after, limit, cb) end,
        reserve = function(spec, cb) coordinator:reserve(spec, RESOURCE, cb) end,
        commit = function(opId, final, cb) coordinator:commit(opId, final, RESOURCE, cb) end,
        cancel = function(opId, reason, cb) cb(coordinator:cancel(opId, reason, RESOURCE)) end,
        transfer = function(spec, cb) coordinator:transfer(spec, RESOURCE, cb) end,
        status = function(opId, options, cb) coordinator:status(opId, options, cb) end,
    }
    service = Open77ContainersService.new({
        store = registryStore, tx = tx, props = world.propsApi, bags = world.bagsApi,
        interactions = world.interactionsApi, players = world.playersApi,
        allowed = allowedOver(policy),
        subjectOf = function(playerId) return "acct-" .. tostring(playerId) end,
        emit = function(name, ...) world.events[#world.events + 1] = { name = name, args = { ... } } end,
        nowMs = nowMs, resourceName = RESOURCE,
    })
    local started, startWhy
    service:start(function(count, why) started, startWhy = count, why end)
    return service, coordinator, started, startWhy
end

-- Synchronous wrapper over the callback API (every store here is immediate).
local function call(fn, ...)
    local result, reason, info
    local args = table.pack(...)
    args[args.n + 1] = function(a, b, c) result, reason, info = a, b, c end
    fn(table.unpack(args, 1, args.n + 1))
    return result, reason, info
end

-- World rows of ours with no registry row (orphans), by key or keyless.
local function orphanRows(key)
    local out = {}
    for id, row in pairs(txStore.containers) do
        if row.meta and row.meta.by == "open77_containers" and not registryStore.rows[id] and row.meta.key == key then
            out[#out + 1] = id
        end
    end
    table.sort(out)
    return out
end

local worldA = newWorld()
local service, coordinator, startedCount, startWhy = boot(worldA)
eq(startedCount, 0, "empty stores boot with zero containers: " .. tostring(startWhy))
-- Player pockets exist in the coordinator (the B2 adapter opens them).
check(call(coordinator.open, coordinator, "char:acct-bbbb", { capacityG = 40000 }, nil), "pocket account opened")

local here = { x = 1370.0, y = -1675.0, z = 49.4 }
worldA.positions[7] = { x = 1371.0, y = -1675.0, z = 49.4, bucket = 0 }    -- A, next to the crate
worldA.positions[8] = { x = 1390.0, y = -1675.0, z = 49.4, bucket = 0 }    -- B, 20 m away
worldA.positions[9] = { x = 1370.5, y = -1675.0, z = 49.4, bucket = 3 }    -- C, other bucket

-- ---------------------------------------------------------------------------
-- 1. Create: the coordinator mints the id; placement goes to its world row,
--    policy to the registry; a prop and a prompt project it.
-- ---------------------------------------------------------------------------
local summary, why = call(service.create, service, "rp_salvage", {
    key = "junkyard-crate-1", kind = "crate", model = "crate.cargo", position = here, yaw = 90, bucket = 0,
    capacityG = 20000, label = "Salvage crate", public = { yard = "rancho" }, private = { lot = 42 },
    prompt = { label = "Open crate", key = "E", distance = 2.0 },
})
check(summary ~= nil, "create returned a summary: " .. tostring(why))
service:sweep() -- prompts are (re)declared by the sweep, debounced
local CRATE = summary and summary.id
check(type(CRATE) == "string" and CRATE:match("^world:t%.") ~= nil, "the coordinator minted the id: " .. tostring(CRATE))
eq(summary and summary.owner, "rp_salvage", "the owner is the calling resource")
check(summary and summary.private == nil, "the public summary never carries private metadata")
local firstProp = summary and summary.propId
check(firstProp ~= nil and worldA.props[firstProp] ~= nil, "a prop projects the container")
eq(worldA.props[firstProp].model, "crate.cargo", "the prop uses the host alias")
local bag = worldA.bags[firstProp] and worldA.bags[firstProp]["open77.container"]
check(bag and bag.id == CRATE and bag.label == "Salvage crate" and bag.public.yard == "rancho",
    "the bag mirrors the server summary")
check(bag and bag.private == nil, "the bag carries no private metadata")
check(declaredProps(worldA)[firstProp], "the prompt is declared as a prop target on the prop")
local definition = lastDefine(worldA)[1]
eq(definition.kind, "prop", "prompt kind")
eq(definition.event, "open77_containers:prompt", "prompt event")
check(definition.maxMatches <= 4 and definition.markerDistance <= 40, "the prompt is interest-limited")
local worldRow = txStore.containers[CRATE]
eq(worldRow and worldRow.capacityG, 20000, "the coordinator's world row holds the capacity")
check(worldRow and worldRow.meta and worldRow.meta.by == "open77_containers" and worldRow.meta.owner == "rp_salvage"
    and worldRow.meta.key == "junkyard-crate-1" and worldRow.meta.kind == "crate" and worldRow.meta.x == here.x
    and worldRow.meta.model == "crate.cargo" and worldRow.meta.bucket == 0,
    "its metadata holds identity and placement (what a restart re-projects)")
local record = registryStore.rows[CRATE]
check(record and record.state == "open" and record.key == "junkyard-crate-1" and record.owner == "rp_salvage",
    "the registry row is durable")
check(record and record.position == nil and record.model == nil and record.capacityG == nil and record.expiresAt == nil,
    "the registry keeps nothing the coordinator holds")
check(record and record.private and record.private.lot == 42 and record.prompt ~= nil and record.label == "Salvage crate",
    "policy, metadata and prompt are the registry's")
eq(#eventsNamed(worldA, "open77_containers:created"), 1, "created announced")

do -- idempotency and validation
-- Idempotent keyed create; a different spec is refused; keys are per owner.
local again, _, againInfo = call(service.create, service, "rp_salvage", {
    key = "junkyard-crate-1", kind = "crate", model = "crate.cargo", position = here, yaw = 90, bucket = 0,
    capacityG = 20000,
})
check(again and again.id == CRATE and againInfo and againInfo.existing == true,
    "same owner, same key, same spec: the existing container")
local _, conflictWhy = call(service.create, service, "rp_salvage", {
    key = "junkyard-crate-1", kind = "crate", model = "crate.small", position = here, bucket = 0, capacityG = 20000,
})
eq(conflictWhy, "already_exists", "a different spec under the same key")
local other = call(service.create, service, "rp_thief", {
    key = "junkyard-crate-1", kind = "crate", model = "crate.cargo", position = here, bucket = 0, capacityG = 1000,
})
check(other and other.id ~= CRATE and other.owner == "rp_thief", "keys are per owner: another resource gets its own")
local otherClosed = other and call(service.close, service, "rp_thief", other.id, {})
check(otherClosed, "an empty crate closes without force")
eq(other and txStore.containers[other.id], nil, "closing deletes the empty coordinator world row")
eq(other and registryStore.rows[other.id].state, "closed", "and leaves a registry tombstone")
local _, closedKey = call(service.create, service, "rp_thief", {
    key = "junkyard-crate-1", kind = "crate", model = "crate.cargo", position = here, bucket = 0, capacityG = 1000,
})
eq(closedKey, "container_closed", "a closed key is never reused")
eq(service:findByKey("rp_salvage", "junkyard-crate-1").id, CRATE, "find by key")
eq(select(2, service:findByKey("rp_thief", "junkyard-crate-1")), "unknown_container", "a closed key is not found")
eq(service:resolve("junkyard-crate-1"), CRATE, "the console resolves a key")

-- Validation.
local _, explicitId = call(service.create, service, "rp_salvage", { id = "world:junkyard-crate-9", position = here })
eq(explicitId, "invalid_id", "world ids are minted by the coordinator, never chosen")
local _, badKey = call(service.create, service, "rp_salvage", { key = "bad key!", position = here })
eq(badKey, "invalid_key", "keys are validated")
local _, badEnt = call(service.create, service, "rp_salvage", { model = "base\\x\\crate.ent", position = here })
eq(badEnt, "invalid_model", "a raw .ent template is refused")
local big = {}
for index = 1, 15 do big["k" .. index] = string.rep("x", 80) end
local _, tooBig = call(service.create, service, "rp_salvage", { position = here, public = big })
eq(tooBig, "public_too_large", "public metadata is bounded")
local _, badMetaKey = call(service.create, service, "rp_salvage", { position = here, public = { ["1bad"] = 1 } })
eq(badMetaKey, "invalid_public", "metadata keys are validated")
local _, noPos = call(service.create, service, "rp_salvage", { kind = "crate" })
eq(noPos, "invalid_position", "a position is required")
local _, nodeOnCrate = call(service.create, service, "rp_salvage", { position = here, node = { charges = 2 } })
eq(nodeOnCrate, "node_requires_node_kind", "charges only on nodes")

end

-- ---------------------------------------------------------------------------
-- 2. The owner seeds it (sys -> world) with a player in reach.
-- ---------------------------------------------------------------------------
local receipt, seedWhy = call(service.transfer, service, "rp_salvage", {
    opId = "seed:crate-1:0001", kind = "seed", player = 7,
    lines = { { item = "scrap", count = 6, from = "sys:salvage", to = CRATE },
              { instance = "crowbar-0001", item = "crowbar", from = "sys:salvage", to = CRATE } },
})
check(receipt ~= nil, "owner seed committed: " .. tostring(seedWhy))
eq(receipt and receipt.actor, "char:acct-7", "a spec naming only a player is attributed to its subject (subjectOf)")
eq(txStore:count(CRATE, "scrap"), 6, "the coordinator holds the contents")
bag = worldA.bags[firstProp]["open77.container"]
check(bag.empty == false and bag.fill > 0, "the summary followed the commit (empty=false, coarse fill)")
check(bag.items == nil, "contents never reach the bag")

-- ---------------------------------------------------------------------------
-- 3. Authorization refusals.
-- ---------------------------------------------------------------------------
local take = function(opId, count, player, to)
    return { opId = opId, kind = "loot", player = player,
        lines = { { item = "scrap", count = count, from = CRATE, to = to or "char:acct-bbbb" } } }
end
do -- refusals, reservations, prompt use
local _, r1 = call(service.transfer, service, "rp_thief", take("thief:0000001", 1, 7))
eq(r1, "not_authorized", "no grant, no take")
local _, r2 = call(service.grant, service, "rp_thief", CRATE, "rp_other", { "take" }, nil)
eq(r2, "not_owner", "only the owner grants")
local granted, r3 = call(service.grant, service, "rp_salvage", CRATE, "rp_thief", { "take", "target" }, nil)
check(granted, "owner grants take+target: " .. tostring(r3))
check(#worldA.grants == 1 and worldA.grants[1].grantee == "rp_thief" and worldA.grants[1].propId == firstProp,
    "a `target` right becomes an open77_interactions prop grant on the current prop")
local _, r4 = call(service.transfer, service, "rp_thief", take("thief:0000002", 1, nil))
eq(r4, "player_required", "a reach-checked container needs the acting player")
local _, r5 = call(service.transfer, service, "rp_thief", take("thief:0000003", 1, 8))
eq(r5, "out_of_reach", "20 m is out of reach")
local _, r6 = call(service.transfer, service, "rp_thief", take("thief:0000004", 1, 9))
eq(r6, "wrong_bucket", "another routing bucket")
local _, r7, r7info = call(service.transfer, service, "rp_thief", take("thief:0000005", 1, 7, "veh:NC-1:cargo"))
eq(r7, "namespace_denied", "the coordinator's writers list denies the grantee the vehicle namespace")
eq(r7info and r7info.account, "veh:NC-1:cargo", "the refusal names the account")
local _, r8 = call(service.transfer, service, "rp_thief", {
    opId = "thief:0000006", player = 7,
    lines = { { item = "scrap", count = 1, from = "char:acct-bbbb", to = CRATE } } })
eq(r8, "not_authorized", "take does not imply put")
local _, r9 = call(service.transfer, service, "rp_thief", {
    opId = "thief:0000007", lines = { { item = "scrap", count = 1, from = "char:acct-aaaa", to = "char:acct-bbbb" } } })
eq(r9, "not_a_container_operation", "operations without a container are not proxied")
local _, r10 = call(service.transfer, service, "rp_thief", {
    opId = "thief:0000008", player = 7,
    lines = { { item = "scrap", count = 1, from = "world:no-such-box", to = "char:acct-bbbb" } } })
eq(r10, "unknown_container", "an unregistered world account is refused")
local _, r11 = call(service.close, service, "rp_thief", CRATE, {})
eq(r11, "not_authorized", "a grantee without `close` cannot close")
local _, r12 = call(service.consume, service, "rp_thief", CRATE, { ref = "x" })
eq(r12, "not_a_node", "a crate has no charges")

-- The real caller's own mint right, not open77_containers' (which the
-- coordinator would accept): a `put` grant does not let a grantee create value.
check(call(service.grant, service, "rp_salvage", CRATE, "rp_thief", { "take", "target", "put" }, nil), "grant put too")
local _, mintWhy = call(service.transfer, service, "rp_thief", {
    opId = "thief:mint:0001", player = 7, lines = { { item = "scrap", count = 1, from = "sys:salvage", to = CRATE } } })
eq(mintWhy, "mint_denied", "a grantee needs its own mint rule to put new value into a container")
local _, moneyWhy = call(service.transfer, service, "rp_salvage", {
    opId = "salv:money:0001", player = 7, lines = {
        { item = "scrap", count = 1, from = CRATE, to = "char:acct-bbbb" },
        { money = 10, from = "sys:salvage", to = "cash:acct-bbbb" } } })
eq(moneyWhy, "mint_denied", "a mint rule for items does not cover money")
switches.allowedDown = true
local _, downWhy, downInfo = call(service.transfer, service, "rp_thief", take("thief:down:0001", 1, 7))
eq(downWhy, "coordinator_unavailable", "no policy answer, no forwarding")
check(downInfo and downInfo.retryable == true, "and the refusal is retryable")
switches.allowedDown = false
eq(txStore:count(CRATE, "scrap"), 6, "no refusal moved anything")

-- The bag is not authority: forge it, nothing changes.
worldA.bags[firstProp]["open77.container"].owner = "rp_thief"
local allowed = service:access(CRATE, "rp_thief", "close")
eq(allowed, false, "a forged bag grants nothing")

-- Per-part writers (`rp_salvage:veh/cargo`), through the coordinator's policy.
check(call(coordinator.open, coordinator, "veh:NC-1:cargo", { capacityG = 50000 }, nil), "a vehicle cargo part")
check(call(coordinator.open, coordinator, "veh:NC-1:trunk", { capacityG = 50000 }, nil), "and its trunk")
local cargoHeld, cargoWhy = call(service.reserve, service, "rp_salvage", { opId = "salv:cargo:0001", player = 7,
    lines = { { item = "scrap", count = 1, from = CRATE, to = "veh:NC-1:cargo" } } })
check(cargoHeld, "a per-part writer may load its part: " .. tostring(cargoWhy))
check(call(service.cancel, service, "rp_salvage", "salv:cargo:0001", "test"), "and cancel it")
local _, trunkWhy = call(service.reserve, service, "rp_salvage", { opId = "salv:trunk:0001", player = 7,
    lines = { { item = "scrap", count = 1, from = CRATE, to = "veh:NC-1:trunk" } } })
eq(trunkWhy, "namespace_denied", "but not another part of the same vehicle")

-- The grantee's take, in reach, with its own namespace: one winner.
local got, gotWhy = call(service.transfer, service, "rp_thief", take("thief:0000009", 2, 7))
check(got ~= nil, "a granted take in reach commits: " .. tostring(gotWhy))
eq(txStore:count(CRATE, "scrap"), 4, "two scrap left the crate")
eq(txStore:count("char:acct-bbbb", "scrap"), 2, "and reached the thief's pockets")

-- Reservations belong to their caller.
local reserved, resWhy = call(service.reserve, service, "rp_salvage", {
    opId = "salv:res:0001", player = 7, lines = { { item = "scrap", count = 1, from = CRATE, to = "sys:dealer" } } })
check(reserved, "owner reserves: " .. tostring(resWhy))
local _, notOwner = call(service.commit, service, "rp_thief", "salv:res:0001", nil)
eq(notOwner, "not_owner", "another resource cannot commit it")
local _, notOwner2 = call(service.cancel, service, "rp_thief", "salv:res:0001", nil)
eq(notOwner2, "not_owner", "nor cancel it")
local _, stolenSame = call(service.reserve, service, "rp_thief", {
    opId = "salv:res:0001", player = 7, lines = { { item = "scrap", count = 1, from = CRATE, to = "char:acct-bbbb" } } })
eq(stolenSame, "not_owner", "nor reuse its opId")
local committed = call(service.commit, service, "rp_salvage", "salv:res:0001", nil)
check(committed and committed.state == "committed", "the owner commits its reservation")
local replay = call(service.commit, service, "rp_salvage", "salv:res:0001", nil)
check(replay and replay.replay == true, "a retried commit replays the receipt")
eq(txStore:count(CRATE, "scrap"), 3, "paid once")

-- A stopping caller loses its reservations.
check(call(service.reserve, service, "rp_salvage", {
    opId = "salv:res:0002", player = 7, lines = { { item = "scrap", count = 3, from = CRATE, to = "sys:dealer" } } }),
    "a second reservation")
service:onResourceStop("rp_salvage")
local _, afterStop = call(service.commit, service, "rp_salvage", "salv:res:0002", nil)
eq(afterStop, "unknown_operation", "a stopped caller's reservation is cancelled")
eq(txStore:count(CRATE, "scrap"), 3, "nothing moved")

-- Prompt use: everything recomputed from the server's own snapshot.
local used, useWhy = service:use(7, nil, firstProp, "use")
check(used, "a player in reach uses the prompt: " .. tostring(useWhy))
local usedEvent = eventsNamed(worldA, "open77_containers:used")[1]
check(usedEvent and usedEvent.args[1] == CRATE and usedEvent.args[2] == 7 and usedEvent.args[4].owner == "rp_salvage",
    "the owner hears which container and which player")
eq(select(2, service:use(8, nil, firstProp, "use")), "out_of_reach", "a far player's claim is refused")
eq(select(2, service:use(7, nil, firstProp, "steal")), "invalid_choice", "an unknown choice is refused")
eq(select(2, service:use(7, nil, "999999", "use")), "unknown_container", "an unknown prop is refused")
service:use(7, nil, firstProp, "use"); service:use(7, nil, firstProp, "use"); service:use(7, nil, firstProp, "use")
eq(select(2, service:use(7, nil, firstProp, "use")), "rate_limited", "prompt use is rate limited")

end

-- ---------------------------------------------------------------------------
-- 4. A node: depletion, idempotent refs, regrowth.
-- ---------------------------------------------------------------------------
local NODE
do -- node
local node = call(service.create, service, "rp_salvage", {
    key = "junkyard-wreck-3", kind = "node", model = false, position = { x = 1388.0, y = -1664.0, z = 49.4 },
    node = { charges = 3, regrowMs = 60000 }, prompt = { label = "Search wreck", key = "E", distance = 3.0 },
})
NODE = node and node.id
check(node and node.charges == 3 and node.maxCharges == 3 and node.propId == nil, "a point node, no prop")
service:sweep()
check(NODE and txStore.containers[NODE] and txStore.containers[NODE].capacityG == 0
    and txStore.containers[NODE].meta.model == false,
    "a node without capacity has a zero-capacity world row: its placement lives there too")
local _, noContents = call(service.transfer, service, "rp_salvage", { opId = "node:put:0001", player = 7,
    lines = { { item = "scrap", count = 1, from = "sys:salvage", to = NODE } } })
eq(noContents, "container_has_no_contents", "value never moves into a node without capacity")
local zoneDeclared = false
for _, def in ipairs(lastDefine(worldA)) do
    if def.kind == "zone" and def.zone.position.x == 1388.0 then zoneDeclared = true end
end
check(zoneDeclared, "a point container's prompt is a zone target")
local c1 = call(service.consume, service, "rp_salvage", NODE, { ref = "salvage:claim-1" })
eq(c1 and c1.charges, 2, "one charge spent")
local c1b = call(service.consume, service, "rp_salvage", NODE, { ref = "salvage:claim-1" })
check(c1b and c1b.replay == true and c1b.charges == 2, "the same ref replays, spends nothing")
local _, unauth = call(service.consume, service, "rp_thief", NODE, { ref = "salvage:claim-9" })
eq(unauth, "not_authorized", "consume needs the right")
local c2 = call(service.consume, service, "rp_salvage", NODE, { ref = "salvage:claim-2", count = 2 })
check(c2 and c2.charges == 0 and c2.depleted == true, "depleted")
local _, empty = call(service.consume, service, "rp_salvage", NODE, { ref = "salvage:claim-3" })
eq(empty, "depleted", "a depleted node refuses")
service:sweep()
local zoneStill = false
for _, def in ipairs(lastDefine(worldA)) do
    if def.kind == "zone" and def.zone.position.x == 1388.0 then zoneStill = true end
end
check(not zoneStill, "a depleted node's prompt is withdrawn")
check(#eventsNamed(worldA, "open77_containers:depleted") == 1, "depletion announced once")
clock = clock + 61000
service:sweep()
local regrown = eventsNamed(worldA, "open77_containers:regrown")
check(#regrown == 1 and regrown[1].args[2] == 1, "one charge regrew after regrowMs")
eq(service:summary(NODE).charges, 1, "summary shows the regrown charge")
-- Refill (operator / lab reset) without closing the node.
eq(select(2, call(service.refill, service, "rp_thief", NODE, nil)), "not_owner", "only the owner refills")
local r0 = call(service.refill, service, "rp_salvage", NODE, { charges = 0 })
check(r0 and r0.charges == 0 and r0.depleted == true, "a refill may also empty a node (lab)")
eq(#eventsNamed(worldA, "open77_containers:depleted"), 2, "and announces the depletion")
local rFull = call(service.refill, service, "rp_salvage", NODE, nil)
check(rFull and rFull.charges == 3 and rFull.depleted == false and rFull.regrowAt == nil, "refill to full by default")
eq(#eventsNamed(worldA, "open77_containers:regrown"), 2, "and announces the charges")
eq(select(2, call(service.refill, service, "rp_salvage", NODE, { charges = 9 })), "invalid_count",
    "no more than maxCharges")
eq(select(2, call(service.refill, service, "rp_salvage", CRATE, nil)), "not_a_node", "only nodes refill")
local oldRef = call(service.consume, service, "rp_salvage", NODE, { ref = "salvage:claim-1" })
check(oldRef and oldRef.replay == true and oldRef.charges == 3, "a refill keeps the refs: an old consume replays")
eq(service:summary(NODE).id, NODE, "the node keeps its id through a refill")
service:sweep()
local zoneBack = false
for _, def in ipairs(lastDefine(worldA)) do
    if def.kind == "zone" and def.zone.position.x == 1388.0 then zoneBack = true end
end
check(zoneBack, "a refilled node offers its prompt again")

end

-- ---------------------------------------------------------------------------
-- 5. A pile: expiry (the coordinator's expiresAt) drains it and closes it.
-- ---------------------------------------------------------------------------
local PILE
do -- pile expiry
local pile = call(service.create, service, "rp_salvage", {
    key = "drop-pile-77", kind = "pile", model = "garbage.bag", position = { x = 1372.0, y = -1675.0, z = 49.4 },
    capacityG = 10000, ttlMs = 120000, prompt = { label = "Pick up", key = "E" },
})
PILE = pile and pile.id
check(pile and pile.expiresAt == clock + 120000, "a pile with a ttl")
eq(PILE and txStore.containers[PILE].expiresAt, clock + 120000, "its expiry is the coordinator's world-row expiresAt")
check(call(service.transfer, service, "rp_salvage", {
    opId = "seed:pile:0001", player = 7, lines = { { item = "copper", count = 4, from = "sys:salvage", to = PILE } } }),
    "pile seeded")
local pileProp = service:summary(PILE).propId
txStore.down = true
clock = clock + 121000
service:sweep()
check(service.rows[PILE] ~= nil and service.rows[PILE].state == "open", "with the store down the pile is not closed")
eq(select(2, service:access(PILE, "rp_salvage", "take")), "owner", "rights are unchanged meanwhile")
local _, expiredTake = call(service.transfer, service, "rp_salvage", {
    opId = "late:pile:0001", player = 7, lines = { { item = "copper", count = 1, from = PILE, to = "sys:dealer" } } })
eq(expiredTake, "container_expired", "an expired container refuses value movement")
txStore.down = false
-- The coordinator settles the in-doubt drain with its fence (aborted: the
-- store never saw it); the next sweep plans the drain again under a new
-- attempt number and completes it.
clock = clock + 2000
coordinator:tick()
service:sweep()
eq(service.rows[PILE], nil, "the expired pile left the live registry")
eq(registryStore.rows[PILE].state, "closed", "its row is a durable tombstone")
eq(registryStore.rows[PILE].closeReason, "expired", "closed as expired")
eq(txStore.containers[PILE], nil, "its drained world row is deleted after the tombstone")
local drained = 0
for _, entry in ipairs(txStore.journal) do
    if entry.account == "sys:expired" and entry.asset == "copper" then drained = drained + entry.delta end
end
eq(drained, 4, "the drain is journaled to sys:expired (conservation)")
eq(worldA.props[pileProp], nil, "its prop despawned")
local _, reuse = call(service.create, service, "rp_salvage", {
    key = "drop-pile-77", kind = "pile", model = "garbage.bag", position = here, capacityG = 10000 })
eq(reuse, "container_closed", "a closed key is never resurrected")

end

-- ---------------------------------------------------------------------------
-- 6. Emptied piles despawn; forced close drains; non-empty close refuses.
-- ---------------------------------------------------------------------------
do -- emptied pile, non-empty close
local bag2 = call(service.create, service, "rp_salvage", {
    kind = "pile", model = "garbage.bag", position = here, capacityG = 5000 })
local BAG2 = bag2 and bag2.id
check(BAG2 and bag2.id ~= PILE, "a second (keyless) pile")
check(call(service.transfer, service, "rp_salvage", {
    opId = "seed:pile:0002", player = 7, lines = { { item = "copper", count = 2, from = "sys:salvage", to = BAG2 } } }),
    "second pile seeded")
check(call(service.grant, service, "rp_salvage", BAG2, "rp_thief", { "take" }, nil), "grant take on the pile")
check(call(service.transfer, service, "rp_thief", {
    opId = "thief:pile:0001", player = 7, lines = { { item = "copper", count = 2, from = BAG2, to = "char:acct-bbbb" } } }),
    "the thief empties the pile")
eq(service.rows[BAG2], nil, "an emptied despawn-when-empty pile closes itself")
eq(registryStore.rows[BAG2].closeReason, "emptied", "closed as emptied")
eq(txStore.containers[BAG2], nil, "and its world row is gone")
local retried = call(service.transfer, service, "rp_thief", {
    opId = "thief:pile:0001", player = 7, lines = { { item = "copper", count = 2, from = BAG2, to = "char:acct-bbbb" } } })
check(retried and retried.replay == true, "a retry of the pickup that closed the pile replays its receipt")
local _, gone = call(service.transfer, service, "rp_thief", {
    opId = "thief:pile:0002", player = 7, lines = { { item = "copper", count = 1, from = BAG2, to = "char:acct-bbbb" } } })
eq(gone, "unknown_container", "a new operation on the closed pile is refused")
eq(txStore:count("char:acct-bbbb", "copper"), 2, "the pile was paid out once")

local _, notEmpty = call(service.close, service, "rp_salvage", CRATE, {})
eq(notEmpty, "not_empty", "closing a non-empty crate needs force")

end

-- ---------------------------------------------------------------------------
-- 7. Bag drift is repaired; a lost prop is reprojected; carry and drop.
-- ---------------------------------------------------------------------------
do -- bag drift, prop loss, carry
worldA.bags[firstProp]["open77.container"] = { empty = true, owner = "rp_thief" }
service:sweep({ verifyBags = true })
eq(service.stats.tamperRepairs, 1, "one drifted bag repaired")
eq(worldA.bags[firstProp]["open77.container"].owner, "rp_salvage", "the mirror is the server summary again")
worldA.props[firstProp] = nil
service:onPropRemoved(firstProp, "removed")
service:sweep()
local secondProp = service:summary(CRATE).propId
check(secondProp ~= nil and secondProp ~= firstProp and worldA.props[secondProp], "a lost prop is reprojected")
check(declaredProps(worldA)[secondProp] and not declaredProps(worldA)[firstProp], "the prompt follows the new prop")
check(worldA.grants[#worldA.grants].propId == secondProp, "target grants are reissued on the new prop")

check(call(service.carryStart, service, "rp_salvage", CRATE,
    { parentType = "player", parentId = 7, bone = "Chest" }), "carry attaches the prop")
service:sweep()
check(not declaredProps(worldA)[secondProp], "a carried crate offers no prompt")
local _, carriedReach = call(service.transfer, service, "rp_thief", take("thief:carry:01", 1, 8))
eq(carriedReach, "out_of_reach", "reach follows the carrier")
local dropped = call(service.drop, service, "rp_salvage", CRATE,
    { position = { x = 1380.0, y = -1680.0, z = 49.4 }, yaw = 10 })
check(dropped and dropped.position.x == 1380.0, "dropped at the new placement")
eq(txStore.containers[CRATE].meta.x, 1380.0, "the placement is durable in the coordinator's world-row metadata")
eq(txStore.containers[CRATE].meta.yaw, 10.0, "with its yaw")
eq(registryStore.rows[CRATE].position, nil, "and never in the registry")
eq(worldA.props[secondProp].position.x, 1380.0, "the prop stands at the drop")
eq(service.stats.externalChanges, 0, "own metadata writes are recognised by their world event")

end

-- ---------------------------------------------------------------------------
-- 8. Changes made at the coordinator by another writer (world events).
-- ---------------------------------------------------------------------------
do -- outside changes
local ext = call(service.create, service, "rp_salvage", {
    key = "ext-crate", kind = "crate", model = "crate.small", position = { x = 1360.0, y = -1675.0, z = 49.4 },
    capacityG = 3000 })
local EXT = ext and ext.id
local extProp = ext and ext.propId
local moved = Model.deepCopy(txStore.containers[EXT].meta)
moved.x = 1361.5
check(call(coordinator.setMeta, coordinator, EXT, moved, nil), "another world writer moves it")
eq(service.rows[EXT].position.x, 1361.5, "the container follows the coordinator's placement")
eq(worldA.props[extProp].position.x, 1361.5, "and so does its prop")
eq(service.stats.externalChanges, 1, "counted as an outside change")
check(call(coordinator.setMeta, coordinator, EXT, { note = "junk" }, nil), "another writer replaces the metadata")
local restoredMeta = txStore.containers[EXT].meta
check(restoredMeta.by == "open77_containers" and restoredMeta.x == 1361.5 and restoredMeta.key == "ext-crate",
    "metadata a restart could not rebuild from is restored from memory")
check(call(coordinator.close, coordinator, EXT, nil), "another writer closes the empty world row")
eq(service.rows[EXT], nil, "the container closes with it")
eq(registryStore.rows[EXT].closeReason, "account_closed", "tombstoned as account_closed")
eq(worldA.props[extProp], nil, "its prop despawned")

end

-- ---------------------------------------------------------------------------
-- 8b. An externally presented (carriable) container: open77_actions' carry
--     helper owns the prop; this resource keeps identity, custody and policy.
-- ---------------------------------------------------------------------------
local CARRIED
do -- external projection
local before = 0
for _ in pairs(worldA.props) do before = before + 1 end
local _, promptRefused = call(service.create, service, "rp_salvage", { key = "c1-crate-x", projection = "external",
    position = here, capacityG = 8000, prompt = { label = "Open" } })
eq(promptRefused, "invalid_prompt", "an external container has no prompt here (the carry helper offers its own)")
local _, badProjection = call(service.create, service, "rp_salvage", { projection = "hologram", position = here })
eq(badProjection, "invalid_projection", "projection is validated")
local carried = call(service.create, service, "rp_salvage", { key = "c1-crate-1", kind = "crate",
    model = "crate.ammo_box", projection = "external", position = { x = 1342.0, y = -1675.0, z = 49.4 },
    capacityG = 8000 })
CARRIED = carried and carried.id
check(carried and carried.propId == nil and carried.projection == "external", "no prop of its own")
local after = 0
for _ in pairs(worldA.props) do after = after + 1 end
eq(after, before, "nothing projected here")
eq(service:projectionOf(CARRIED).projection, "external", "projection() says who presents it")
eq(service.rows[CARRIED].reachM, 0.0, "reach defaults to off: proximity is the carry helper's")
check(txStore.containers[CARRIED] and txStore.containers[CARRIED].meta.model == "crate.ammo_box",
    "minted through openWorld like any container")
check(call(service.transfer, service, "rp_salvage", { opId = "c1:seed:0001",
    lines = { { item = "scrap", count = 3, from = "sys:salvage", to = CARRIED } } }), "custody stays the container's")
eq(select(2, call(service.carryStart, service, "rp_salvage", CARRIED, { parentType = "player", parentId = 7 })),
    "external_projection", "this resource's own carry hooks do not apply")
local moved = call(service.place, service, "rp_salvage", CARRIED, { position = { x = 1345.0, y = -1675.0, z = 49.4 } })
check(moved and moved.position.x == 1345.0 and moved.propId == nil, "the presenter reports a durable move")
eq(txStore.containers[CARRIED].meta.x, 1345.0, "into the world row's metadata")
service:sweep()
eq(service:projectionOf(CARRIED).propId, nil, "the sweep never projects it")
end

-- ---------------------------------------------------------------------------
-- 9. Interrupted states a restart must settle.
-- ---------------------------------------------------------------------------
local TOMB, KEYLESS, ORPHAN, LOST, FOREIGN, JUNK
do -- interrupted states
-- (a) A close interrupted after its tombstone: the world row is still there.
local tomb = call(service.create, service, "rp_salvage", { model = "crate.small", position = here, capacityG = 2000 })
TOMB = tomb and tomb.id
switches.failClose = true
check(call(service.close, service, "rp_salvage", TOMB, {}), "close answers once the tombstone is written")
check(txStore.containers[TOMB] ~= nil and registryStore.rows[TOMB].state == "closed",
    "a failed world-row delete leaves the tombstone and the row")
-- (b) A keyless create interrupted after openWorld (and its cleanup failing too).
registryStore.faults = { "store_unavailable" }
local _, keylessWhy = call(service.create, service, "rp_salvage", { model = "crate.small", position = here, capacityG = 2000 })
eq(keylessWhy, "store_unavailable", "a failed registry insert is reported")
local keyless = orphanRows(nil)
eq(#keyless, 1, "one keyless orphan world row")
KEYLESS = keyless[1]
switches.failClose = false
-- (c) A keyed create interrupted after openWorld.
registryStore.faults = { "store_unavailable" }
local _, keyedWhy = call(service.create, service, "rp_salvage", {
    key = "orphan-crate-1", model = "crate.small", position = here, capacityG = 3000 })
eq(keyedWhy, "store_unavailable", "a failed keyed insert is reported")
ORPHAN = orphanRows("orphan-crate-1")[1]
check(ORPHAN ~= nil and service.rows[ORPHAN] == nil, "an empty keyed orphan, no container")
-- (d) A world row lost behind the service's back (a coordinator database reset).
local lost = call(service.create, service, "rp_salvage", { model = "crate.small", position = here, capacityG = 2000 })
LOST = lost and lost.id
txStore.containers[LOST] = nil
-- (e) A world row whose metadata was replaced behind the service's back.
local junk = call(service.create, service, "rp_salvage", { model = "crate.small", position = here, capacityG = 2000 })
JUNK = junk and junk.id
txStore.containers[JUNK].meta = { note = "junk" }
-- (f) Another resource's own world container.
local foreign = call(coordinator.openWorld, coordinator, { capacityG = 1000,
    meta = { x = 1, y = 2, z = 3, bucket = 0, model = "crate" } }, nil)
FOREIGN = foreign and foreign.id
check(FOREIGN ~= nil, "a foreign world row")

end

-- ---------------------------------------------------------------------------
-- 10. Restart: a new coordinator and service over the same durable stores,
--     an empty prop registry (the props died with the old process).
-- ---------------------------------------------------------------------------
do -- restart
local worldB = newWorld()
worldB.positions[7] = { x = 1380.5, y = -1680.0, z = 49.4, bucket = 0 }
clock = clock + 120000
local service2, coordinator2, restored, restoreWhy = boot(worldB)
eq(restored, 3, "three open containers rebuilt (crate, node, carried crate): " .. tostring(restoreWhy))
local carriedAfter = service2:summary(CARRIED)
check(carriedAfter and carriedAfter.propId == nil and carriedAfter.projection == "external"
    and carriedAfter.position.x == 1345.0 and carriedAfter.empty == false,
    "an external container comes back without a prop, at its last durable placement, with its contents")
eq(txStore.containers[TOMB], nil, "the boot join deletes the world row a tombstoned close left behind")
eq(txStore.containers[KEYLESS], nil, "and an empty keyless orphan nobody can reach")
eq(service2.stats.orphansClosed, 1, "one orphan closed")
check(txStore.containers[ORPHAN] ~= nil and service2.orphans["rp_salvage/orphan-crate-1"] ~= nil,
    "a keyed orphan is kept for its creator's retry")
eq(registryStore.rows[LOST].state, "closed", "a container whose world row is gone is tombstoned")
eq(registryStore.rows[LOST].closeReason, "account_missing", "as account_missing")
eq(service2.rows[LOST], nil, "and not projected")
check(registryStore.rows[JUNK].state == "open" and service2.rows[JUNK] == nil and txStore.containers[JUNK] ~= nil,
    "a world row with unusable metadata is left inert, neither tombstoned nor deleted")
check(txStore.containers[FOREIGN] ~= nil and service2:summary(FOREIGN) == nil,
    "another resource's world row is neither adopted nor touched")

local crateAfter = service2:summary(CRATE)
check(crateAfter and crateAfter.id == CRATE and crateAfter.owner == "rp_salvage", "same identity after restart")
eq(crateAfter.position.x, 1380.0, "same placement after restart (the coordinator's metadata)")
eq(crateAfter.yaw, 10.0, "same yaw")
check(crateAfter.empty == false and crateAfter.fill > 0, "the listing's weight gives the summary its fill, no read")
check(crateAfter.propId ~= nil and worldB.props[crateAfter.propId], "a fresh prop projects it")
eq(worldB.props[crateAfter.propId].position.x, 1380.0, "where it was dropped")
eq(worldB.bags[crateAfter.propId]["open77.container"].id, CRATE, "the bag is rewritten on the new prop")
check(declaredProps(worldB)[crateAfter.propId], "the prompt is redeclared on the new prop")
check(#worldB.grants == 1 and worldB.grants[1].grantee == "rp_thief" and worldB.grants[1].propId == crateAfter.propId,
    "the durable target grant is reissued for the new prop")
eq(service2:findByKey("rp_salvage", "junkyard-crate-1").id, CRATE, "the key finds it again")
local detail = call(service2.get, service2, "rp_salvage", CRATE)
check(detail and detail.items.scrap == 3 and detail.instances["crowbar-0001"], "contents survive (coordinator store)")
eq(detail and detail.private.lot, 42, "private metadata survives (registry)")
local _, readDenied = call(service2.get, service2, "rp_thief", CRATE)
eq(readDenied, "not_authorized", "private detail needs `read`")
local afterGrant = call(service2.transfer, service2, "rp_thief", {
    opId = "thief:after:0001", player = 7, lines = { { item = "scrap", count = 1, from = CRATE, to = "char:acct-bbbb" } } })
check(afterGrant ~= nil, "a durable grant still authorizes after restart")
local nodeAfter = service2:summary(NODE)
eq(nodeAfter.charges, 3, "node charges regrew across the restart from the persisted regrowFrom")
eq(nodeAfter.position.x, 1388.0, "a point node's placement comes back from its zero-capacity world row")
local replayAfter = call(service2.consume, service2, "rp_salvage", NODE, { ref = "salvage:claim-2" })
check(replayAfter and replayAfter.replay == true, "consume refs survive the restart")
eq(service2:summary(PILE), nil, "a closed container stays closed")
local replayed = call(service2.commit, service2, "rp_salvage", "salv:res:0001", nil)
check(replayed and replayed.replay == true, "a committed op from the previous process replays its receipt")
eq(txStore:count(CRATE, "scrap"), 2, "3 after restart, minus the thief's 1")

-- The keyed orphan: the creator's retry adopts it; another spec does not.
local _, wrongSpec = call(service2.create, service2, "rp_salvage", {
    key = "orphan-crate-1", model = "crate.cargo", position = here, capacityG = 3000 })
eq(wrongSpec, "already_exists", "an orphan is adopted only by the same spec")
local adopted = call(service2.create, service2, "rp_salvage", {
    key = "orphan-crate-1", model = "crate.small", position = here, capacityG = 3000 })
check(adopted and adopted.id == ORPHAN, "the retry with the same key adopts the orphan world row")
eq(service2.stats.adopted, 1, "one adoption")

-- Forced close drains through the coordinator, leaves a tombstone and
-- deletes the world row.
local closed, closeWhy = call(service2.close, service2, "rp_salvage", CRATE, { force = true, reason = "yard_reset" })
check(closed, "forced close: " .. tostring(closeWhy))
eq(registryStore.rows[CRATE].state, "closed", "tombstone")
eq(txStore.containers[CRATE], nil, "world row deleted")
local discarded = 0
for _, entry in ipairs(txStore.journal) do
    if entry.account == "sys:discarded" and entry.asset == "scrap" then discarded = discarded + entry.delta end
end
eq(discarded, 2, "the forced drain is journaled to sys:discarded")
service2:sweep()
check(not declaredProps(worldB)[crateAfter.propId], "its prompt is withdrawn")
local closedEvents = eventsNamed(worldB, "open77_containers:closed")
check(closedEvents[#closedEvents].args[2] == "yard_reset", "closed with the caller's reason")

end

-- ---------------------------------------------------------------------------
-- 11. Model unit checks.
-- ---------------------------------------------------------------------------
do -- model
check(Model.validKey("junkyard-crate-1") and Model.validKey("12345") and not Model.validKey("bad key")
    and not Model.validKey(string.rep("k", 65)) and not Model.validKey(""), "key validation")
check(Model.validId("world:srv.lq2x8k3z.1") and not Model.validId("world:session12") and
    not Model.validId("char:abc") and not Model.validId("world:"), "id validation")
local sample = { id = "world:t.x.1", owner = "o", kind = "crate", key = "k-1", model = "crate.small",
    position = { x = 1.5, y = 2.0, z = 3.0 }, yaw = 45.0, bucket = 2, capacityG = 900, expiresAt = 77,
    label = "L", private = { a = 1 }, version = 3, state = "open" }
local meta = Model.coordinatorMeta(sample)
local back = Model.fromCoordinator({ id = sample.id, meta = meta, capacityG = 900, expiresAt = 77, weightG = 12 })
check(back and back.owner == "o" and back.key == "k-1" and back.position.x == 1.5 and back.bucket == 2
    and back.yaw == 45.0 and back.capacityG == 900 and back.expiresAt == 77 and back.weightG == 12,
    "coordinator metadata round-trips")
eq(select(2, Model.fromCoordinator({ id = sample.id, meta = { x = 1, y = 2, z = 3 } })), "foreign",
    "a world row without our marker is foreign")
local rec = Model.registryRecord(sample)
check(rec.position == nil and rec.model == nil and rec.capacityG == nil and rec.expiresAt == nil and rec.yaw == nil
    and rec.bucket == nil and rec.owner == "o" and rec.key == "k-1" and rec.private.a == 1, "registry record split")
local joined = Model.join(rec, back)
check(Model.samePlacement(joined, sample) and joined.capacityG == 900 and joined.weightG == nil, "join")
local state = Model.nodeState({ charges = 0, maxCharges = 5, regrowMs = 1000, regrowFrom = 0 }, 2500)
check(state.charges == 2 and state.regrowAt == 3000, "lazy regrowth: 2 charges after 2.5 regrow periods")
local summaryOnly = Model.summary({ id = "world:x-1", kind = "crate", capacityG = 1000, version = 1,
    private = { secret = 1 }, position = here, bucket = 0, owner = "o", state = "open" },
    { empty = false, weightG = 333 }, 0)
check(summaryOnly.private == nil and summaryOnly.fill == 0.35, "summary: no private, fill rounded to 5 %")
local unknownEmpty = Model.summary({ id = "world:x-1", kind = "crate", capacityG = 1000, version = 1,
    position = here, bucket = 0, owner = "o", state = "open" }, Model.contentsFromWeight(0), 0)
check(unknownEmpty.empty == nil and unknownEmpty.fill == 0, "a zero listing weight leaves `empty` unknown")

end

TestSummary = ("[open77_containers tests] %d passed, %d failed"):format(passed, failed)
print(TestSummary)
for _, failure in ipairs(failures) do print("  FAIL " .. failure) end
TestResult = { passed = passed, failed = failed, failures = failures }
