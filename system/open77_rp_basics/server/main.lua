-- =============================================================================
-- open77_rp_basics -- server/main.lua
-- =============================================================================
-- The authoritative half of the role-play kit: four verbs composed out of
-- primitives that already shipped, and the release paths that keep them safe.
--
-- Nothing here is new engine work. `cuff` is the server freeze (B2) plus the
-- client control block (B5) plus a synchronised `handsup`; `escort` is the same
-- minus the freeze, with a leash made of `Open77.players.teleport`; `search` is
-- a timed frisk over `Open77.weapons.get`; `carry` refuses. What the kit adds is
-- the bookkeeping: who holds whom, on whose authority, with what claims, and
-- every way that ends.
--
-- ## The rule this file exists for
--
-- A cuffed player whose cuffing resource errored is a player who cannot move and
-- cannot be freed. So every claim is written into a ledger beside the record
-- that asked for it, every record carries a deadline, and a 2 Hz sweep releases
-- anything past it. The sweep is the backstop under every named path below: if
-- an event is missed, a handler raises, or the world does something nobody
-- enumerated, the hold still ends.
--
-- ## Authority
--
-- An export carries no player identity (`source` is nil inside one, by design),
-- so the officer is an argument and the kit checks him against the ACL rather
-- than trusting the caller. `rp.cuff`, `rp.escort`, `rp.search` and `rp.admin`
-- are ordinary ACL permissions; grant `rp.*` to a police role once. Actor `0`
-- is the server console, the same principal the ACL already treats as local
-- administration.
-- =============================================================================

local Rules = RpBasicsRules
assert(Rules ~= nil, "open77_rp_basics: shared/rules.lua did not load")

local RESOURCE = GetCurrentResourceName()
local WIRE = "open77:rpbasics:apply"
local SWEEP_MS = 500

local config = Rules.config(nil)
local holds = Rules.newLedger()     -- cuff / escort: standing claims
local frisks = Rules.newLedger()    -- search: bounded claims
local tetherState = {}              -- [targetId] = { lastPullMs, pullPending }
local nextTicket = 1

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------
local function nowMs()
    return math.floor(Open77.time.monotonic() * 1000)
end

-- Every platform call the release path makes is wrapped: one refusal must not
-- stop the others, or a player keeps the half of the hold that failed to lift.
local function guard(what, fn, ...)
    local ok, a, b = pcall(fn, ...)
    if not ok then
        Open77.log.error(("rp_basics: %s raised: %s"):format(what, tostring(a)))
        return false, "raised"
    end
    if a == false or a == nil then
        return false, b
    end
    return true, a
end

local function readPlayer(playerId)
    local id = Rules.playerId(playerId)
    if id == nil then return nil end
    local read = Open77.players.get(id)
    if type(read) ~= "table" then return nil end
    read.playerId = id
    return read
end

local function authorised(actorId, permission)
    -- The console is local administration and is not subject to the ACL, the
    -- same exception `RegisterCommand(..., true)` already makes for source 0.
    if actorId == 0 then return true end
    local allowed = Open77.acl.isAllowed(actorId, permission)
    if allowed == true then return true end
    return false
end

-- ---------------------------------------------------------------------------
-- Applying and releasing claims
-- ---------------------------------------------------------------------------
-- `claims` is the truth about what this kit took from the platform. It releases
-- exactly these and nothing else: the freeze and the input block are both
-- per-resource claims, so dropping ours never lifts a jail script's.
local function applyFreeze(record)
    if record.claims.freeze then return end
    local ok, reason = guard("setFrozen", Open77.players.setFrozen, record.target, true)
    if ok then
        record.claims.freeze = true
    else
        Open77.log.warn(("rp_basics: freeze refused for %d (%s)"):format(record.target, tostring(reason)))
    end
end

local function dropFreeze(record)
    if not record.claims.freeze then return end
    record.claims.freeze = false
    guard("setFrozen", Open77.players.setFrozen, record.target, false)
end

local function applyAnimation(record)
    if record.claims.animation then return end
    -- An RP profile is stationary and is cancelled by walking, so `handsup`
    -- belongs to a held body and not to an escorted one. That is a limitation
    -- of the animation system, stated rather than worked around.
    local ok, state = pcall(Open77.animations.play, record.target, "handsup", { loop = true })
    if not ok then
        Open77.log.warn("rp_basics: animations.play raised: " .. tostring(state))
        return
    end
    if type(state) == "table" and state.playbackId ~= nil then
        record.claims.animation = state.playbackId
    elseif state ~= nil and state ~= false then
        record.claims.animation = true
    end
end

local function dropAnimation(record)
    local playback = record.claims.animation
    if not playback then return end
    record.claims.animation = false
    guard("animations.stop", Open77.animations.stop, record.target,
        type(playback) == "string" and playback or nil)
end

local function tellClient(record, payload)
    local ok = guard("TriggerClientEvent", TriggerClientEvent, WIRE, record.target, payload)
    return ok
end

local function applyClient(record, mode)
    record.claims.client = true
    tellClient(record, {
        mode = mode,
        verb = record.verb,
        officer = record.officer,
        target = record.target,
        expiresAt = record.expiresAt,
    })
end

local function dropClient(record)
    if not record.claims.client then return end
    record.claims.client = false
    tellClient(record, { mode = "free", verb = record.verb, target = record.target })
end

-- The single release path. Every named end below funnels here, which is what
-- makes "did we release exactly what we took" one question instead of eleven.
local function releaseRecord(ledger, record, reason)
    if record == nil then return false end
    if not Rules.isEndReason(reason) then reason = "released" end
    ledger:release(record.target)
    tetherState[record.target] = nil
    dropAnimation(record)
    dropFreeze(record)
    dropClient(record)
    TriggerEvent("open77_rp_basics:released", record.target, record.officer, record.verb, reason)
    return true
end

local function releaseHold(targetId, reason)
    return releaseRecord(holds, holds:get(targetId), reason)
end

-- ---------------------------------------------------------------------------
-- The verbs
-- ---------------------------------------------------------------------------
local function beginHold(verb, officerId, targetId, options)
    local definition = Rules.verbs[verb]
    if definition == nil then return false, "unknown_verb" end
    if not definition.supported then return false, definition.reason or "unsupported_verb" end

    local officer = Rules.actorId(officerId)
    local target = Rules.playerId(targetId)
    if officer == nil or target == nil then return false, "invalid_player" end
    if not authorised(officer, definition.permission) then return false, "not_authorised" end

    local officerRead = officer == 0 and nil or readPlayer(officer)
    local targetRead = readPlayer(target)
    if targetRead == nil then return false, "target_unknown" end

    local ledger = definition.holds and holds or frisks
    local standing = ledger:get(target)

    if officer == 0 then
        -- The console has no body, so there is no distance or bucket to check.
        -- It may still not take a target somebody else is holding.
        if standing ~= nil and standing.officer ~= 0 then return false, "held_by_another" end
        if targetRead.ready == false then return false, "target_not_ready" end
        if targetRead.alive ~= true then return false, "target_not_alive" end
    else
        if officerRead == nil then return false, "officer_unknown" end
        local ok, reason = Rules.gate(verb, officerRead, targetRead, standing, config)
        if not ok then return false, reason end
    end

    -- A different verb from the same officer replaces the hold rather than
    -- stacking on it: one body, one hold.
    if standing ~= nil then releaseRecord(ledger, standing, "superseded") end

    local at = nowMs()
    -- A caller may ask for a SHORTER hold than the ceiling, never a longer one:
    -- the ceiling is the operator's protection against a resource that forgets.
    local window = definition.holds and config.maxHoldMs or config.searchMs
    local asked = type(options) == "table" and tonumber(options.holdMs) or nil
    if asked ~= nil and asked >= 1000 and asked < window then window = math.floor(asked) end

    local record = {
        target = target,
        officer = officer,
        verb = verb,
        since = at,
        expiresAt = at + window,
        owner = RESOURCE,
        claims = {},
    }
    ledger:claim(record)
    return record, targetRead
end

local function cuff(officerId, targetId, options)
    local record, reason = beginHold("cuff", officerId, targetId, options)
    if type(record) ~= "table" then return false, reason end
    applyFreeze(record)
    applyAnimation(record)
    applyClient(record, "cuff")
    TriggerEvent("open77_rp_basics:held", record.target, record.officer, "cuff")
    return true
end

local function escort(officerId, targetId, options)
    local record, reason = beginHold("escort", officerId, targetId, options)
    if type(record) ~= "table" then return false, reason end
    -- He walks himself. Nothing freezes him and no animation survives walking;
    -- the tether and the control block are the whole of the hold.
    applyClient(record, "escort")
    tetherState[record.target] = { lastPullMs = -math.huge, pullPending = false }
    TriggerEvent("open77_rp_basics:held", record.target, record.officer, "escort")
    return true
end

local function search(officerId, targetId, options)
    local record, reason = beginHold("search", officerId, targetId, options)
    if type(record) ~= "table" then return false, reason end

    local ticket = ("%s:%d"):format(RESOURCE, nextTicket)
    nextTicket = nextTicket + 1
    if nextTicket > 2147483647 then nextTicket = 1 end
    record.ticket = ticket

    applyFreeze(record)
    applyAnimation(record)
    applyClient(record, "search")
    TriggerEvent("open77_rp_basics:held", record.target, record.officer, "search")

    -- The frisk itself is a read of the weapons cache. It is what the owner
    -- reported, never authority -- `Open77.weapons.get` says so itself, and this
    -- kit passes the freshness fields through rather than hiding them, because
    -- a frisk that reports "unarmed" for a player nobody has heard from is how
    -- an RP server gets an argument it cannot settle.
    CreateThread(function()
        Wait(config.searchMs)
        local live = frisks:get(record.target)
        if live ~= record then return end        -- superseded or already swept
        local weapons = nil
        local ok, answer = pcall(Open77.weapons.get, record.target)
        if ok and type(answer) == "table" then weapons = answer end
        releaseRecord(frisks, record, "released")
        TriggerEvent("open77_rp_basics:searched", record.officer, record.target, ticket, {
            weapons = weapons,
            reason = weapons == nil and "weapons_unreported" or nil,
        })
    end)

    return ticket
end

-- ---------------------------------------------------------------------------
-- Release, from outside
-- ---------------------------------------------------------------------------
-- Who may free a held player: the officer holding him, an `rp.admin`, or the
-- console. That is the answer to "can an admin always free a cuffed player" and
-- it does not depend on the resource that cuffed him still running.
local function release(targetId, byId, reason)
    local target = Rules.playerId(targetId)
    local actor = Rules.actorId(byId)
    if target == nil then return false, "invalid_player" end
    if actor == nil then return false, "invalid_actor" end

    local record = holds:get(target)
    local frisk = frisks:get(target)
    if record == nil and frisk == nil then return false, "not_held" end

    local admin = actor == 0 or authorised(actor, "rp.admin")
    local mine = (record ~= nil and record.officer == actor)
        or (frisk ~= nil and frisk.officer == actor)
    if not admin and not mine then return false, "not_authorised" end

    local ending = admin and not mine and "freed_by_admin" or "released"
    if reason ~= nil and Rules.isEndReason(reason) then ending = reason end

    if record ~= nil then releaseRecord(holds, record, ending) end
    if frisk ~= nil then releaseRecord(frisks, frisk, ending) end
    return true
end

-- ---------------------------------------------------------------------------
-- Exports
-- ---------------------------------------------------------------------------
-- Every one of these validates its own arguments even though the caller is a
-- resource: an export is a resource-to-resource call, not proof of anything.
exports("cuff", function(officerId, targetId, options) return cuff(officerId, targetId, options) end)
exports("escort", function(officerId, targetId, options) return escort(officerId, targetId, options) end)
exports("search", function(officerId, targetId, options) return search(officerId, targetId, options) end)

-- Present, and refuses by name. See README.md, "Why carry is refused".
exports("carry", function()
    return false, Rules.verbs.carry.reason
end)

exports("release", function(targetId, byId, reason) return release(targetId, byId, reason) end)

exports("state", function(targetId)
    local target = Rules.playerId(targetId)
    if target == nil then return nil, "invalid_player" end
    local record = holds:get(target)
    if record == nil then return nil end
    return Rules.publicRecord(record)
end)

exports("held", function()
    local out = {}
    for _, record in ipairs(holds:all()) do out[#out + 1] = Rules.publicRecord(record) end
    return out
end)

-- Read this instead of hard-coding what the kit can do. `carry` is in the list
-- with `supported = false` and its reason, exactly as an unblockable input
-- action is in `Open77.input.blockableActions()`.
exports("capabilities", function() return Rules.capabilities() end)

-- ---------------------------------------------------------------------------
-- Named release paths
-- ---------------------------------------------------------------------------
local function endAllFor(playerId, asOfficer, asTarget)
    local id = Rules.playerId(playerId)
    if id == nil then return end
    for _, ledger in ipairs({ holds, frisks }) do
        local record = ledger:get(id)
        if record ~= nil then releaseRecord(ledger, record, asTarget) end
        for _, owned in ipairs(ledger:byOfficer(id)) do
            releaseRecord(ledger, owned, asOfficer)
        end
    end
end

AddEventHandler("onPlayerDisconnected", function(playerId)
    endAllFor(playerId, "officer_left", "target_left")
end)

AddEventHandler("onPlayerLifeStateChanged", function(playerId, _revision, phase)
    if phase == "alive" then return end
    endAllFor(playerId, "officer_dead", "target_dead")
end)

AddEventHandler("onPlayerBucketChange", function(playerId)
    endAllFor(playerId, "officer_bucket_changed", "target_bucket_changed")
end)

AddEventHandler("onResourceStop", function(name)
    if name ~= RESOURCE then return end
    for _, ledger in ipairs({ holds, frisks }) do
        for _, record in ipairs(ledger:all()) do
            releaseRecord(ledger, record, "resource_stopping")
        end
    end
end)

-- A client that restarted this resource's client half lost its input claim.
-- It says so on start; the server re-issues whatever is still standing.
RegisterNetEvent("open77:rpbasics:sync", function()
    local player = Rules.playerId(source)
    if player == nil then return end
    local record = holds:get(player) or frisks:get(player)
    if record == nil then
        TriggerClientEvent(WIRE, player, { mode = "free" })
        return
    end
    applyClient(record, record.verb)
end)

-- ---------------------------------------------------------------------------
-- The sweep
-- ---------------------------------------------------------------------------
-- Deadlines first, then the tether. Both are wrapped per record: one bad record
-- must not stop the pass that would have released the next one.
local function sweepExpired(at)
    for _, ledger in ipairs({ holds, frisks }) do
        for _, record in ipairs(ledger:expired(at)) do
            local ok, err = pcall(releaseRecord, ledger, record, "expired")
            if not ok then
                Open77.log.error(("rp_basics: expiry release raised: %s"):format(tostring(err)))
                ledger:release(record.target)
            end
        end
    end
end

local function sweepTethers(at)
    for _, record in ipairs(holds:all()) do
        if record.verb == "escort" and record.officer ~= 0 then
            local officer = readPlayer(record.officer)
            local target = readPlayer(record.target)
            local state = tetherState[record.target]
            if state == nil then
                state = { lastPullMs = -math.huge, pullPending = false }
                tetherState[record.target] = state
            end
            local action, payload = Rules.tether(officer, target, state, at, config)
            if action == "end" then
                releaseRecord(holds, record, payload)
            elseif action == "pull" then
                state.pullPending = true
                state.lastPullMs = at
                local pending = Open77.players.teleport(record.target, payload, { fade = false })
                if pending == nil then
                    state.pullPending = false
                else
                    CreateThread(function()
                        local placed, reason = pending:await()
                        state.pullPending = false
                        if placed then return end
                        -- `player_in_vehicle` is the one refusal that means the
                        -- leash has nothing left to hold. Everything else is a
                        -- transient the next pass retries.
                        if reason == "player_in_vehicle" then
                            releaseHold(record.target, "target_mounted")
                        end
                    end)
                end
            end
        end
    end
end

CreateThread(function()
    while true do
        Wait(SWEEP_MS)
        local at = nowMs()
        local ok, err = pcall(sweepExpired, at)
        if not ok then Open77.log.error("rp_basics: expiry sweep raised: " .. tostring(err)) end
        ok, err = pcall(sweepTethers, at)
        if not ok then Open77.log.error("rp_basics: tether sweep raised: " .. tostring(err)) end
    end
end)

-- ---------------------------------------------------------------------------
-- Operator commands
-- ---------------------------------------------------------------------------
-- These exist so an operator is never dependent on the gamemode that cuffed
-- somebody still being able to un-cuff him.
RegisterCommand("rp.free", function(playerId, args)
    local target = Rules.playerId(args and args[1])
    if target == nil then
        print("usage: rp.free <playerId>")
        return
    end
    local ok, reason = release(target, playerId)
    print(ok and ("rp.free: released " .. target) or ("rp.free: " .. tostring(reason)))
end, true)

RegisterCommand("rp.held", function()
    local rows = holds:all()
    if #rows == 0 then
        print("rp.held: nobody is held")
        return
    end
    for _, record in ipairs(rows) do
        print(("rp.held: %d %s by %d, expires in %d ms"):format(
            record.target, record.verb, record.officer, math.max(0, record.expiresAt - nowMs())))
    end
end, true)

AddEventHandler("onResourceStart", function(name)
    if name ~= RESOURCE then return end
    Open77.log.info(
        "rp_basics: cuff/escort/search ready. carry is refused on this build (carry_unsupported); " ..
        "grant rp.cuff / rp.escort / rp.search to the roles that may use them.")
end)
