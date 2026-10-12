-- Official local-player weapon loadout facade. REDengine equipment handlers
-- are asynchronous, so every mutation returns a native request id and reports
-- its verified result through open77:weapons:completed.

if type(Open77.weapons) ~= "table" then
    print("[open77_weapons] native weapons API unavailable; restart Cyberpunk")
    return
end

local function invoke(operation, ...)
    local method = Open77.weapons[operation]
    if type(method) ~= "function" then return nil, "unsupported_operation" end
    return method(...)
end

-- Declared before the exports so `clear` can name it; defined below, next to the
-- loadout reporter it shares its snapshot machinery with.
local Weapons = {}

exports("slots", function() return invoke("slots") end)
exports("assign", function(record, slot, options)
    return invoke("assign", record, slot, options)
end)
exports("setActive", function(target, options) return invoke("setActive", target, options) end)
exports("activate", function(target, options) return invoke("setActive", target, options) end)
exports("remove", function(slot) return invoke("remove", slot) end)
exports("unequip", function(slot) return invoke("remove", slot) end)
exports("holster", function() return invoke("holster") end)
exports("setAmmo", function(slot, amounts) return invoke("setAmmo", slot, amounts) end)
exports("snapshot", function() return invoke("snapshot") end)
exports("all", function() return invoke("snapshot") end)
exports("clear", function() return Weapons.clear() end)
-- W6-C: parts in the weapon's attachment slots (E3) and quick-slot gadgets (E4).
exports("setComponent", function(slot, record, options)
    return invoke("setComponent", slot, record, options)
end)
exports("removeComponent", function(slot, attachmentSlot)
    return invoke("removeComponent", slot, attachmentSlot)
end)
exports("components", function(slot) return invoke("components", slot) end)
exports("giveGadget", function(record, count, options)
    return invoke("giveGadget", record, count, options)
end)
exports("takeGadget", function(record, count) return invoke("takeGadget", record, count) end)
exports("gadgets", function() return invoke("gadgets") end)

local pending = {}

-- ---------------------------------------------------------------------------
-- Clearing every slot, and telling the server what is in them.
--
-- These two live together because they share one piece of machinery: a native
-- request whose completion is interesting to somebody other than the caller.
-- ---------------------------------------------------------------------------

local SLOTS = { 1, 2, 3 }

-- One `clear` in flight, aggregating three native removals.
--
-- Three removals rather than a snapshot-then-remove pass on purpose: an empty
-- slot answers `weapon_slot_empty`, which is not a failure of "remove every
-- weapon" and is treated as success below. Asking first would cost an extra
-- REDengine round trip to learn something the removals report anyway.
local clearing = nil

-- The last loadout pushed to the server, by slot, and the drawn id it implied.
-- Used to keep the push idempotent and to notice an out-of-band change.
local reported = { records = { "", "", "" }, ids = { 0, 0, 0 }, sent = false }

local function pushLoadout(states)
    local rows = {}
    for index = 1, #states do
        local state = states[index]
        if type(state) == "table" and state.slot ~= nil then
            rows[#rows + 1] = {
                slot = state.slot,
                record = state.record or "",
                tweakDbId = state.tweakDbId or "",
                equipped = state.equipped == true,
                active = state.active == true,
                drawn = state.drawn == true,
                locked = state.locked == true,
                ammo = state.ammo,
                -- W6-C (E3): the installed mods, so the server cache can answer
                -- Open77.weapons.components without a round trip. Base parts
                -- (receiver, barrel, magazine) are not reported: they are the
                -- weapon, not something a resource installed.
                parts = state.parts,
            }
        end
    end
    for index = 1, 3 do reported.records[index], reported.ids[index] = "", 0 end
    for index = 1, #rows do
        local row = rows[index]
        if row.slot >= 1 and row.slot <= 3 then
            reported.records[row.slot] = row.record
            reported.ids[row.slot] = tonumber(row.tweakDbId) or 0
        end
    end
    reported.sent = true
    -- Reserved transport: the host consumes `open77:weapons:report` and never
    -- forwards it to a resource VM, so no resource can forge a loadout for a
    -- player it does not own.
    TriggerServerEvent("open77:weapons:report", rows)
end

-- A snapshot whose only purpose is to feed the server cache. It carries no
-- server request id, so its completion is not relayed anywhere.
local function refreshLoadout()
    local nativeId = invoke("snapshot")
    if nativeId == nil then return end
    pending[tostring(nativeId)] = { operation = "snapshot", states = {}, reportOnly = true }
end

-- ---------------------------------------------------------------------------
-- W6-C (E4): the server's picture of the quick slots.
--
-- Same idea as the loadout push. Gadget membership and counts have no wire
-- field, so the owner reports them on a reserved transport the host consumes
-- and never forwards to a resource VM (`open77:weapons:gadgets`). A throw is
-- reported the moment the bridge's inventory listener sees the stack shrink,
-- as `consumed = { record, tweakDbId, remaining }` riding the same report, and
-- the host republishes that one as `onGadgetConsumed(playerId, record,
-- remaining)`. Give/take requests this resource itself is running are not
-- consumption, and are told apart by the pending table below.
-- ---------------------------------------------------------------------------
local knownGadgets = {}

local function pushGadgets(rows, consumed)
    knownGadgets = rows
    TriggerServerEvent("open77:weapons:gadgets", rows, consumed)
end

local function refreshGadgets(consumed)
    local nativeId = invoke("gadgets")
    if nativeId == nil then
        -- Nothing to snapshot with (no player, no bridge): still say what
        -- was consumed, against whatever the last snapshot said.
        if consumed ~= nil then pushGadgets(knownGadgets, consumed) end
        return
    end
    pending[tostring(nativeId)] = {
        operation = "gadgets", states = {}, gadgets = {}, reportOnly = true, consumed = consumed,
    }
end

-- A give or take this resource ran recently, by record. The engine's inventory
-- listener may report the stack change before OR after the request's own
-- completion is processed, so a pending entry alone is not enough to recognise
-- our own change; a short memory after completion closes that gap.
local recentGadgetOps = {}

-- A stack the server was already told about. The session bootstrap strips
-- the vanilla loadout before the first snapshot goes out, and the engine
-- reports every one of those removals through the same listener: measured on
-- the wave-6 proof as three phantom `onGadgetConsumed` on connect, one of them
-- the frag grenade of the pristine save. A shrink of a stack the last report
-- never carried is not a throw the server can count. The count the last
-- report carried is returned so the caller can ask for a real shrink: a death
-- and respawn fires the removal callback for a stack the body keeps, and the
-- quantity it reads back is the one it already had (measured: `remaining=3`
-- on a stack of 3, twice, once per respawn).
local function gadgetKnownQuantity(record)
    for _, row in ipairs(knownGadgets) do
        if row.record == record and (tonumber(row.quantity) or 0) > 0 then return tonumber(row.quantity) end
    end
    return nil
end

-- The engine announces the last unit twice -- a quantity change to zero, then
-- the removal -- so the same observation inside a short window is one throw.
local lastConsumed = { record = nil, remaining = nil, at = 0 }

local function gadgetRequestPending(record)
    for _, request in pairs(pending) do
        if (request.operation == "giveGadget" or request.operation == "takeGadget")
            and (request.record == nil or request.record == "" or request.record == record) then
            return true
        end
    end
    local now = GetGameTimer()
    for key, until_ in pairs(recentGadgetOps) do
        if until_ < now then
            recentGadgetOps[key] = nil
        elseif key == "" or key == record then
            return true
        end
    end
    return false
end

function Weapons.clear(requestId)
    if clearing ~= nil then return nil, "clear_in_progress" end
    local batch = { requestId = requestId, remaining = 0, slots = {}, failures = 0 }
    for index = 1, #SLOTS do
        local slot = SLOTS[index]
        local nativeId, reason = invoke("remove", slot)
        if nativeId == nil then
            batch.slots[#batch.slots + 1] =
                { slot = slot, accepted = false, reason = reason or "weapon_request_failed" }
            batch.failures = batch.failures + 1
        else
            batch.remaining = batch.remaining + 1
            pending[tostring(nativeId)] = { operation = "remove", clearSlot = slot }
        end
    end
    if batch.remaining == 0 then
        -- Nothing was even queued: answer now rather than leave the caller waiting
        -- for completions that will never arrive.
        return nil, batch.slots[1] and batch.slots[1].reason or "weapon_request_failed"
    end
    clearing = batch
    return requestId or true
end

local function finishClear()
    local batch = clearing
    clearing = nil
    table.sort(batch.slots, function(left, right) return left.slot < right.slot end)
    if batch.requestId ~= nil then
        TriggerServerEvent("open77:weapons:result", batch.requestId, "clear",
            batch.failures == 0, batch.failures == 0 and "" or "clear_partial",
            { slots = batch.slots, cleared = #batch.slots - batch.failures })
    end
    -- Whatever the outcome, the server's picture of this loadout just changed.
    refreshLoadout()
end

local function validRemoteRequestId(requestId)
    if type(requestId) == "number" then
        return requestId % 1 == 0 and requestId > 0
    end
    return type(requestId) == "string" and #requestId > 0 and #requestId <= 96
end

local function report(requestId, operation, accepted, reason, result)
    TriggerServerEvent(
        "open77:weapons:result", requestId, operation, accepted == true,
        tostring(reason or ""), result)
end

RegisterNetEvent("open77:weapons:request", function(requestId, operation, payload, options)
    if not validRemoteRequestId(requestId) or type(operation) ~= "string" then return end

    local nativeId, reason
    if operation == "assign" and type(payload) == "table" then
        nativeId, reason = invoke("assign", payload.record, payload.slot, options)
    elseif operation == "setActive" then
        nativeId, reason = invoke("setActive", payload, options)
    elseif operation == "remove" then
        nativeId, reason = invoke("remove", payload)
    elseif operation == "holster" then
        nativeId, reason = invoke("holster")
    elseif operation == "setAmmo" then
        nativeId, reason = invoke("setAmmo", payload, options)
    elseif operation == "snapshot" then
        nativeId, reason = invoke("snapshot")
    elseif operation == "clear" then
        -- Aggregated locally: `clear` is three native removals answered once.
        -- It owns the server reply, so nothing is registered in `pending` here.
        nativeId, reason = Weapons.clear(requestId)
        if nativeId ~= nil then return end
    -- W6-C: parts (E3) and gadgets (E4). The payload shapes mirror the server
    -- facade one to one; the native call does the real validation.
    elseif operation == "setComponent" and type(payload) == "table" then
        nativeId, reason = invoke("setComponent", payload.slot, payload.record, options)
    elseif operation == "removeComponent" and type(payload) == "table" then
        nativeId, reason = invoke("removeComponent", payload.slot, payload.attachmentSlot)
    elseif operation == "components" then
        nativeId, reason = invoke("components", payload)
    elseif operation == "giveGadget" and type(payload) == "table" then
        nativeId, reason = invoke("giveGadget", payload.record, payload.count, options)
    elseif operation == "takeGadget" and type(payload) == "table" then
        nativeId, reason = invoke("takeGadget", payload.record, payload.count)
    elseif operation == "gadgets" then
        nativeId, reason = invoke("gadgets")
    elseif operation == "consumable" and type(payload) == "table" then
        local api = Open77.consumables
        if type(api) ~= "table" then
            reason = "consumables_unavailable_on_this_client"
        elseif payload.method == "configure" then
            nativeId, reason = api.configure(payload.kind, payload.options)
        elseif payload.method == "snapshot" or payload.method == "reset" then
            nativeId, reason = api[payload.method](payload.kind)
        else
            reason = "unsupported_operation"
        end
    else
        reason = "unsupported_operation"
    end
    if nativeId == nil then
        report(requestId, operation, false, reason or "weapon_request_failed", nil)
        return
    end
    pending[tostring(nativeId)] = {
        requestId = requestId,
        operation = operation,
        states = {},
        parts = {},
        gadgets = {},
        record = type(payload) == "table" and payload.record or nil,
    }
end)

-- W6-C (E3): one attachment slot of one weapon. Rows arrive for `components`
-- (every slot), for a completed setComponent/removeComponent (the slot it
-- changed) and inside a `snapshot` (the installed mods of each weapon, for the
-- loadout push).
AddEventHandler("open77:weapons:part", function(
    nativeId, slot, attachmentSlot, attachmentSlotId, taken, base, record, tweakDbId)
    local request = pending[tostring(nativeId)]
    if request == nil then return end
    local row = {
        slot = tonumber(slot),
        attachmentSlot = attachmentSlot,
        attachmentSlotId = attachmentSlotId,
        taken = taken == "true",
        base = base == "true",
        record = record,
        tweakDbId = tweakDbId,
    }
    if request.operation == "snapshot" then
        -- Only installed, non-base parts travel with the loadout.
        if not row.taken or row.base then return end
        for index = 1, #request.states do
            local state = request.states[index]
            if state.slot == row.slot then
                state.parts = state.parts or {}
                if #state.parts < 8 then state.parts[#state.parts + 1] = row end
                return
            end
        end
        return
    end
    request.parts = request.parts or {}
    if #request.parts < 32 then request.parts[#request.parts + 1] = row end
end)

-- W6-C (E4): one quick slot, or -- request id 0 -- the engine consuming a
-- gadget the player threw (the bridge's inventory listener).
AddEventHandler("open77:weapons:gadget", function(
    nativeId, quickSlot, record, tweakDbId, quantity, active, difference)
    local row = {
        slot = tonumber(quickSlot),
        record = record,
        tweakDbId = tweakDbId,
        quantity = tonumber(quantity),
        active = active == "true",
        difference = tonumber(difference) or 0,
    }
    if tostring(nativeId) == "0" then
        -- Unsolicited. A shrink that is not one of this resource's own take
        -- requests is a throw (or a drop); either way the count moved out
        -- from under the server. Anything else (a pickup, a give) only means
        -- the snapshot is stale.
        local consumed = nil
        local known = gadgetKnownQuantity(row.record)
        local remaining = row.quantity ~= nil and row.quantity >= 0 and row.quantity or 0
        if row.difference < 0 and not gadgetRequestPending(row.record)
            and known ~= nil and remaining < known then
            local now = GetGameTimer()
            local duplicate = lastConsumed.record == row.record
                and lastConsumed.remaining == remaining and now - lastConsumed.at < 250
            if not duplicate then
                consumed = { record = row.record, tweakDbId = row.tweakDbId, remaining = remaining }
                lastConsumed = { record = row.record, remaining = remaining, at = now }
                TriggerEvent("open77:weapons:gadgetConsumed", consumed.record,
                    consumed.tweakDbId, consumed.remaining)
            end
        end
        refreshGadgets(consumed)
        return
    end
    local request = pending[tostring(nativeId)]
    if request == nil then return end
    request.gadgets = request.gadgets or {}
    if #request.gadgets < 8 then request.gadgets[#request.gadgets + 1] = row end
end)

local function ammoState(record, tweakDbId, total, reserve, magazine, capacity)
    total, reserve = tonumber(total), tonumber(reserve)
    magazine, capacity = tonumber(magazine), tonumber(capacity)
    if total == nil or total < 0 then return nil end
    return {
        record = record,
        tweakDbId = tweakDbId,
        total = total,
        reserve = reserve ~= nil and reserve >= 0 and reserve or nil,
        magazine = magazine ~= nil and magazine >= 0 and magazine or nil,
        capacity = capacity ~= nil and capacity >= 0 and capacity or nil,
    }
end

AddEventHandler("open77:weapons:state", function(
    nativeId, slot, record, tweakDbId, active, drawn, locked,
    ammoRecord, ammoTweakDbId, ammoTotal, ammoReserve, magazine, capacity)
    local request = pending[tostring(nativeId)]
    if request == nil or request.operation ~= "snapshot" then return end
    request.states[#request.states + 1] = {
        slot = tonumber(slot),
        equipped = (type(record) == "string" and #record > 0)
            or (type(tweakDbId) == "string" and #tweakDbId > 0),
        record = record,
        tweakDbId = tweakDbId,
        active = active == "true",
        drawn = drawn == "true",
        locked = locked == "true",
        ammo = ammoState(
            ammoRecord, ammoTweakDbId, ammoTotal, ammoReserve, magazine, capacity),
    }
end)

-- Native charge readbacks have their own row; legacy gadget inventory counts
-- retain their original meaning. The host consumes the reserved report name.
local consumables = {}
exports("getConsumable", function(kind) return consumables[kind] end)
AddEventHandler("open77:consumables:state", function(
    nativeId, kind, record, tweakDbId, count, capacity, equipped, recharge, managed, sequence, uses, change)
    if kind ~= "grenade" and kind ~= "healing" then return end
    local row = { kind = kind, record = record, tweakDbId = tweakDbId,
        count = tonumber(count), capacity = tonumber(capacity), equipped = equipped == "true",
        recharge = recharge == "true", managed = managed == "true",
        sequence = tonumber(sequence), uses = tonumber(uses) or 0, change = change }
    if not row.count or not row.capacity or not row.sequence then return end
    consumables[kind] = row
    local request = pending[tostring(nativeId)]
    if request and request.operation == "consumable" then request.consumable = row end
    TriggerServerEvent("open77:consumables:report", row)
end)

AddEventHandler("open77:weapons:completed", function(
    nativeId, operation, accepted, reason, slot, record, tweakDbId, active, drawn,
    ammoRecord, ammoTweakDbId, ammoTotal, ammoReserve, magazine, capacity)
    local key = tostring(nativeId)
    local request = pending[key]
    if request == nil then return end
    pending[key] = nil
    -- One leg of an aggregated `clear`. An already-empty slot is not a failure:
    -- "remove every weapon" succeeded on a slot that had none.
    if request.clearSlot ~= nil then
        if clearing == nil then return end
        local ok = accepted == "true" or reason == "weapon_slot_empty"
        clearing.slots[#clearing.slots + 1] =
            { slot = request.clearSlot, accepted = ok, reason = ok and "" or tostring(reason or "") }
        if not ok then clearing.failures = clearing.failures + 1 end
        clearing.remaining = clearing.remaining - 1
        if clearing.remaining <= 0 then finishClear() end
        return
    end
    if request.operation ~= operation then
        if not request.reportOnly then
            report(request.requestId, request.operation, false, "operation_mismatch", nil)
        end
        return
    end
    -- A snapshot taken purely to refresh the server cache answers nobody else.
    if request.reportOnly then
        if operation == "snapshot" then pushLoadout(request.states) end
        if operation == "gadgets" then pushGadgets(request.gadgets or {}, request.consumed) end
        return
    end
    local result
    if operation == "snapshot" then
        result = request.states
        -- Somebody asked for the truth and got it; the server may as well have it.
        pushLoadout(request.states)
    elseif operation == "consumable" then
        result = request.consumable
    elseif operation == "components" then
        result = { slot = tonumber(slot), record = record, tweakDbId = tweakDbId,
            parts = request.parts or {} }
    elseif operation == "setComponent" or operation == "removeComponent" then
        result = { slot = tonumber(slot), record = record, tweakDbId = tweakDbId,
            part = (request.parts or {})[1] }
    elseif operation == "gadgets" then
        result = request.gadgets or {}
        pushGadgets(result, nil)
    elseif operation == "giveGadget" or operation == "takeGadget" then
        result = { slot = tonumber(slot), record = record, tweakDbId = tweakDbId,
            gadget = (request.gadgets or {})[1] }
    else
        result = {
            slot = tonumber(slot),
            record = record,
            tweakDbId = tweakDbId,
            active = active == "true",
            drawn = drawn == "true",
            ammo = ammoState(
                ammoRecord, ammoTweakDbId, ammoTotal, ammoReserve, magazine, capacity),
        }
    end
    report(request.requestId, operation, accepted == "true", reason, result)
    -- Any accepted mutation moved the loadout out from under the last report.
    if accepted == "true" then
        if operation == "giveGadget" or operation == "takeGadget" then
            recentGadgetOps[request.record or ""] = GetGameTimer() + 1500
            refreshGadgets(nil)
        elseif operation ~= "snapshot" and operation ~= "gadgets" and operation ~= "components" and operation ~= "consumable" then
            refreshLoadout()
        end
    end
end)

-- ---------------------------------------------------------------------------
-- Keeping the server's weapon cache honest, without polling the engine.
--
-- Slot MEMBERSHIP has no wire field, so it can only reach the server from here.
-- The naive way to keep it current is to snapshot on a timer, and that is a real
-- REDengine round trip per tick per client for a thing that changes a few times
-- an hour.
--
-- It is not necessary, because the DRAWN weapon already travels: the ordinary
-- 20 Hz player snapshot carries its TweakDBID and whether it is in hand, and the
-- server reads both straight out of the packet. So this loop only has to catch
-- the case the server cannot see -- a slot whose CONTENTS changed without going
-- through this API, which is what happens when the player loots a gun or the
-- vanilla UI swaps one.
--
-- `Open77.character.weapon()` is a local field read, no engine call and no
-- allocation. When the id it reports is one the last report already accounted
-- for, there is nothing to do and nothing is sent. A snapshot is only requested
-- when the two genuinely disagree, so an untouched loadout costs one table read
-- a second and zero traffic.
-- ---------------------------------------------------------------------------
CreateThread(function()
    -- Report once at start so the server has a baseline before anything changes.
    -- Waiting first: the equipment system is not ready the instant a resource is.
    Wait(3000)
    refreshLoadout()
    refreshGadgets(nil)
    -- A native baseline may have been emitted before this resource started.
    -- Retry only missing kinds until the server has both initial readbacks.
    local function refreshMissingConsumables()
        local api = Open77.consumables
        if type(api) ~= "table" or type(api.snapshot) ~= "function" then return end
        for _, kind in ipairs({ "grenade", "healing" }) do
            if consumables[kind] == nil then api.snapshot(kind) end
        end
    end
    refreshMissingConsumables()
    local nextConsumableRefresh = GetGameTimer() + 5000
    local unknownSince = 0
    while true do
        Wait(1000)
        if GetGameTimer() >= nextConsumableRefresh then
            refreshMissingConsumables()
            nextConsumableRefresh = GetGameTimer() + 5000
        end
        if clearing == nil and reported.sent then
            local drawn = Open77.character.weapon()
            local id = drawn ~= nil and tonumber(drawn.itemId) or 0
            local known = id == 0
            if not known then
                for index = 1, 3 do
                    if reported.ids[index] == id then known = true break end
                end
            end
            if known then
                unknownSince = 0
            else
                -- Two consecutive disagreements, not one: a snapshot taken during
                -- an equip transition legitimately reports an id no slot claims yet,
                -- and re-snapshotting on that would be a request per swap.
                unknownSince = unknownSince + 1
                if unknownSince >= 2 then
                    unknownSince = 0
                    refreshLoadout()
                end
            end
        end
    end
end)

print("client weapon loadout facade ready")
