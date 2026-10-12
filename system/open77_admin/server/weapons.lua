-- open77_admin -- the Weapons tab's server half: a give that actually arrives
-- loaded, the slot policy, and the ledger of what this package handed out.
--
-- Every handler here is reached only after the C# transport has resolved
-- `command.<name>` against the caller's authenticated identity; nothing in this
-- file re-checks rights, because it cannot. See the header of server/main.lua.
--
-- ===========================================================================
-- WHAT THE SERVER CAN AND CANNOT KNOW, said plainly
-- ===========================================================================
-- A weapon is CLIENT-OWNED REDengine state, further from this VM than a
-- vehicle is. `Open77.weapons.*` on the server is not a native at all: it is
-- Lua in the host prelude (server/src/Open77.Server.Scripting/Runtime/
-- LuaResourceRuntime.cs, `weaponRequest`) that fires `open77:weapons:request`
-- at ONE authenticated session and waits up to ten seconds for that session to
-- answer `open77:weapons:result`. The work is done by the `open77_weapons`
-- client half, inside `EquipmentSystemPlayerData`, on the target's machine.
--
-- So, precisely:
--
--   * The server DECIDES. The catalogue in shared/weapons.lua is an allowlist
--     and `resolveRecord` below is the gate: a client may type any string and
--     only a string in the catalogue is ever forwarded. wiki/weapons-api.md is
--     explicit about this -- "Never forward a client-chosen arbitrary record".
--   * The server CORROBORATES, but only through the same client. Every count
--     printed below came back through `open77:weapons:result` after the client
--     read `GetItemQuantity` and `GetMagazineAmmoCount` for itself. That is a
--     real verification of REDengine's answer and NOT a verification of the
--     client: a modified client can decline the request outright (the relay
--     reports `request_timeout`), answer a plausible lie, or accept the weapon
--     and drop the ammo. There is no second channel to check it against --
--     `PlayerSnapshot` replicates a shot counter, not a loadout.
--   * The server REMEMBERS. `granted` below is the authority for "what did
--     this package hand out", because `addToInventory` creates a local
--     presentation item and persists nothing. If a loadout ever has to survive
--     a reconnect, it is replayed from here, exactly as the vehicle governor
--     mirror is.
--
-- That is the same shape as the vehicle governor next door: balance, not
-- anti-cheat. It is worth saying because the failure mode is quiet -- a
-- refusing client looks identical to a laggy one.
--
-- ===========================================================================
-- WHY A GIVE IS THREE ROUND TRIPS AND NOT ONE
-- ===========================================================================
-- "Give a weapon with ammo" is four engine facts stitched together, and each
-- one costs a trip because the answer to it is only knowable on the client:
--
--   1. WHICH SLOT is free -- `assign` takes an EXACT slot, 1..3, and there is
--      no "first free" primitive anywhere in the API. So `auto` asks for a
--      snapshot first.
--   2. THE ASSIGN itself.
--   3. THE SPARE POOL -- `setAmmo` needs the weapon to exist as a
--      `WeaponObject`, which only happens once the slot is drawn, so this call
--      always carries `activate = true`.
--   4. THE MAGAZINE -- capacity is `WeaponObject.GetMagazineCapacity` on that
--      same instantiated object, unknowable until step 3 answers with it, and
--      asking for more than capacity is refused outright
--      (`magazine_exceeds_capacity`). So the magazine top-up is a fourth call,
--      issued ONCE, from the capacity the engine just reported.
--
-- Each step is a `pending` row keyed by request id and resumed in the one
-- `open77:weapons:completed` handler at the bottom. Nothing loops: step 4 is
-- guarded by `toppedUp` so a weapon whose magazine simply refuses to fill
-- reports the counts it reached instead of chasing them forever.
-- ===========================================================================

local Config = Admin.Config
local Weapons = Config.weapons
local Catalog = Open77AdminWeapons
local output, push = Admin.output, Admin.push
local resolveTarget, actionable = Admin.resolveTarget, Admin.actionable

local kSlots = 3

-- ---------------------------------------------------------------------------
-- Availability
--
-- Two independent things can be missing and they fail differently, so they are
-- reported differently.
--
-- `Open77.weapons` absent means an older SERVER host with no relay in its
-- prelude. Nothing here can work and the operator must be told once, plainly,
-- rather than shown a menu that answers `attempt to index a nil value`.
--
-- The `open77_weapons` RESOURCE missing is the other one, and it is invisible
-- from here: server resources cannot ask each other anything on this platform.
-- Its CLIENT half owns the `open77:weapons:request` handler, so without it
-- every request this file makes is delivered, ignored, and completed ten
-- seconds later as `request_timeout`.
--
-- That is deliberately NOT a manifest `dependency`, and the asymmetry is the
-- reason. A declared dependency is HARD -- `StartRecursive` refuses the
-- resource outright -- so removing open77_weapons from a server's resource
-- list would take the WHOLE admin package down with it: no roster, no
-- teleport, no kick, at exactly the moment somebody is likely to want them.
-- freeroam can afford that trade (it declares the dependency and is a game
-- mode); an operator tool cannot. So one screen degrades instead, and the
-- completion handler at the bottom translates `request_timeout` into the
-- sentence that actually names the cause.
-- ---------------------------------------------------------------------------
local function weaponsReady()
    return Weapons.enabled == true
        and type(Open77.weapons) == "table"
        and type(Open77.weapons.assign) == "function"
end

local function unavailable(source, raw)
    return output(source, raw, false,
        "the weapons relay is not available on this server build -- Open77.weapons is absent")
end

-- ---------------------------------------------------------------------------
-- The ledger and the last verified snapshot
--
-- `granted[playerId][slot]` is what THIS package put there. It is not a
-- permission boundary and it is not the loadout: the loadout is `verified`,
-- which only ever holds counts a client actually read back.
--
-- Both are dropped on disconnect. A recycled player id inheriting the previous
-- occupant's loadout would be worse than an empty screen.
-- ---------------------------------------------------------------------------
local granted = {}          -- [playerId] = { [slot] = { record, name, class, reserve, atMs, by } }
local verified = {}         -- [playerId] = { atMs, slots = { row, ... } }

local function ledgerAdd(playerId, slot, record, class, reserve, by)
    local rows = granted[playerId]
    if rows == nil then rows = {} granted[playerId] = rows end
    rows[slot] = {
        record = record,
        name = Catalog.nameOf(record),
        -- Defensive: a nil class here would be a programming error, and taking
        -- the whole resource's command channel down over one is a poor trade.
        class = class ~= nil and class.label or nil,
        reserve = reserve,
        atMs = Admin.nowMs(),
        by = by or 0,
    }
end

AddEventHandler("onPlayerDisconnected", function(playerIdStr)
    local playerId = tonumber(playerIdStr)
    if playerId == nil then return end
    granted[playerId] = nil
    verified[playerId] = nil
end)

-- ---------------------------------------------------------------------------
-- Pending requests
--
-- The host relay already guarantees exactly one completion per request -- it
-- answers `request_timeout` after ten seconds if the client says nothing -- so
-- there is no timer here. The one case it does NOT cover is a player who
-- disconnects mid-chain: the relay drops its own pending row silently, so
-- these would leak. The sweep below is that backstop.
-- ---------------------------------------------------------------------------
local pending = {}

local function remember(requestId, entry)
    pending[tostring(requestId)] = entry
end

AddEventHandler("onPlayerDisconnected", function(playerIdStr)
    local playerId = tonumber(playerIdStr)
    if playerId == nil then return end
    for key, entry in pairs(pending) do
        if entry.playerId == playerId or entry.source == playerId then
            pending[key] = nil
        end
    end
end)

-- ---------------------------------------------------------------------------
-- Records
-- ---------------------------------------------------------------------------

--- Resolve an operator token to a catalogue record.
---
--- The catalogue IS the allowlist, exactly as `Catalog.position` is for
--- vehicles: a client may name any string and only a string that is in
--- shared/weapons.lua reaches `Open77.weapons.assign`. Anything the generator
--- filtered out -- grenades, the portable HMG, arm cyberware, deprecated
--- records -- is refused here rather than by the engine, so the operator gets
--- a sentence instead of `unsupported_weapon_area`.
local function resolveRecord(token)
    if type(token) ~= "string" or token == "" then return nil, "no weapon named" end
    local alias = Weapons.aliases[token:lower()]
    if alias ~= nil then return alias end
    if Catalog.index[token] ~= nil then return token end
    return nil, string.format(
        "unknown weapon -- name one of the %d catalogue records, or a short alias "
        .. "(/admin.weap.catalog lists them)", Catalog.count)
end

local function classOf(record)
    return Catalog.classOfRecord(record)
end

--- Full load for a class, in SPARE rounds.
---
--- The engine chooses the ammo TYPE (`WeaponItem_Record.Ammo()`); this only
--- says how many. See the note above `weapons` in shared/config.lua.
local function reserveFor(class, override)
    local maximum = math.max(0, math.floor(tonumber(Weapons.maximumReserve) or 5000))
    if override ~= nil then return math.min(maximum, override) end
    local configured = type(Weapons.reserve) == "table" and Weapons.reserve[class.key] or nil
    local wanted = math.floor(tonumber(configured) or class.reserve or 0)
    return math.min(maximum, math.max(0, wanted))
end

-- ---------------------------------------------------------------------------
-- Slots
--
-- ===========================================================================
-- THE SLOT DECISION, and why `auto` is not simply "slot 1"
-- ===========================================================================
-- The three ordinary slots are a loadout, not a bag. `assign` REPLACES what is
-- in the slot it is given -- the displaced weapon stays in inventory
-- (`remove` is documented as clearing a slot "without deleting inventory", and
-- assign is the same shape), but it stops being reachable from the weapon
-- wheel, which for the player is indistinguishable from losing it.
--
-- So a give that always wrote slot 1 would take the operator's pistol away
-- every time they asked for a rifle, and an admin tool that costs you
-- something you did not mention is a tool people stop using.
--
-- `auto` therefore reads a VERIFIED snapshot and:
--   * takes the first EMPTY, unlocked slot if there is one -- the give is
--     purely additive and nothing is displaced;
--   * replaces the ACTIVE slot when all three are full. Deliberately the
--     active one and not slot 3: the operator is holding it, so it is the one
--     weapon they can see change, and swapping the thing in your hands is what
--     "give me that gun" means. Silently rewriting a slot they were not
--     looking at is the surprise this branch exists to avoid.
-- An explicit `1`, `2` or `3` always wins and always replaces -- naming a slot
-- IS asking for the replacement.
--
-- A locked slot is skipped rather than fought: `weapon_slot_locked` is a
-- REDengine state (a quest, a scene) this package has no business overriding.
-- ===========================================================================

local function parseSlot(token)
    if token == nil then return Weapons.defaultSlot or "auto" end
    local text = tostring(token):lower()
    if text == "auto" or text == "free" or text == "next" then return "auto" end
    local slot = tonumber(text)
    if slot == nil or slot % 1 ~= 0 or slot < 1 or slot > kSlots then
        return nil, "slot must be 1, 2, 3 or auto"
    end
    return slot
end

--- Pick a slot out of a verified snapshot. Returns `slot, how`.
local function chooseSlot(rows)
    local free, active
    for _, row in ipairs(rows or {}) do
        local slot = tonumber(row.slot)
        if slot ~= nil and slot >= 1 and slot <= kSlots and row.locked ~= true then
            if row.equipped ~= true and free == nil then free = slot end
            if row.active == true and active == nil then active = slot end
        end
    end
    if free ~= nil then return free, "free slot" end
    if active ~= nil then return active, "replacing the active slot" end
    -- Every slot is full AND none reported active -- or the snapshot came back
    -- empty, which a client build without the relay would also produce. Slot 1
    -- is the honest fallback; the engine refuses it plainly if it is locked.
    return 1, "slot 1"
end

-- ---------------------------------------------------------------------------
-- The chain
-- ---------------------------------------------------------------------------

--- Describe the ammo half of a completion result for the operator.
local function ammoProse(ammo)
    if type(ammo) ~= "table" then return "no ammo reported" end
    local name = type(ammo.record) == "string" and #ammo.record > 0 and ammo.record
        or tostring(ammo.tweakDbId or "unknown")
    -- `record` is empty for an item equipped through another pipeline: shipping
    -- REDengine builds do not always retain the reverse TweakDB name table, so
    -- `TDBID.ToStringDEBUG` answers "". The numeric id is still an identity, so
    -- print that rather than "unknown". Measured on 2.31: an ammo type reported
    -- purely as `0x00000010FE92A980`.
    --
    -- An INACTIVE slot reports its ammo type and shared total but leaves
    -- reserve, magazine and capacity at -1 -- those three live on the
    -- instantiated `WeaponObject`, which does not exist until the slot is
    -- drawn. Print the total in that case rather than three question marks:
    -- "no WeaponObject yet" and "no ammo at all" are very different answers.
    if ammo.magazine == nil and ammo.capacity == nil and ammo.reserve == nil then
        return string.format("%s rounds of %s carried (slot not drawn, so no "
            .. "magazine reading)", tostring(ammo.total or "?"), name)
    end
    return string.format("%s/%s in the magazine, %s spare (%s)",
        tostring(ammo.magazine or "?"), tostring(ammo.capacity or "?"),
        tostring(ammo.reserve or "?"), name)
end

local function finishGive(entry, ammo)
    local class = entry.class
    ledgerAdd(entry.playerId, entry.slot, entry.record, class, entry.reserve, entry.source)
    local who = entry.playerId == entry.source and "you" or ("player " .. entry.playerId)
    local text
    if class.ammo ~= true then
        text = string.format("%s -- %s now holds it in slot %d (melee: no ammo pool)",
            entry.name, who, entry.slot)
    else
        text = string.format("%s -- %s now holds it in slot %d with %s",
            entry.name, who, entry.slot, ammoProse(ammo))
    end
    if entry.how ~= nil then text = text .. " [" .. entry.how .. "]" end
    output(entry.source, entry.raw, true, text)
    if entry.playerId ~= entry.source then
        Admin.announce(entry.playerId,
            "An administrator gave you " .. entry.name .. ".")
    end
end

--- Step 3: the spare pool. Always `activate = true` -- see the header.
local function requestAmmo(entry, magazine)
    local amounts = { reserve = entry.reserve, activate = true }
    if magazine ~= nil then amounts.magazine = magazine end
    local requestId, reason = Open77.weapons.setAmmo(entry.playerId, entry.slot, amounts)
    if requestId == nil then
        -- The weapon IS there; only the ammo failed. Say both, because "give
        -- rejected" would be wrong and would send the operator looking in the
        -- wrong place.
        ledgerAdd(entry.playerId, entry.slot, entry.record, entry.class, 0, entry.source)
        return output(entry.source, entry.raw, false, string.format(
            "%s equipped in slot %d but the ammo request was rejected: %s",
            entry.name, entry.slot, tostring(reason)))
    end
    -- A refill's magazine top-up is still a REFILL. Overwriting the kind here
    -- sent it down the give branch on the way back, and `finishGive` then
    -- indexed the class a refill never has -- a real crash, caught in game on
    -- 2026-08-30 as `attempt to index a nil value (local 'class')`, which took
    -- the whole resource's command channel with it.
    if entry.kind ~= "refill" then
        entry.kind = magazine ~= nil and "topUp" or "ammo"
    end
    remember(requestId, entry)
end

--- Step 2: the assign.
local function requestAssign(entry)
    local requestId, reason = Open77.weapons.assign(
        entry.playerId, entry.record, entry.slot,
        { active = true, addToInventory = true })
    if requestId == nil then
        return output(entry.source, entry.raw, false,
            "weapon assign rejected: " .. tostring(reason))
    end
    entry.kind = "assign"
    remember(requestId, entry)
end

-- ---------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------
Admin.register("admin.weap.give", {
    help = "Give a weapon -- loaded -- to yourself or another player.",
    params = {
        { name = "playerId|me" },
        { name = "record|alias", help = "A catalogue record, or a short alias." },
        { name = "slot", help = "1, 2, 3 or auto.", optional = true },
        { name = "reserve", help = "Spare rounds; the class default otherwise.", optional = true },
    },
    mutation = true,
    handler = function(source, args, raw)
        if not weaponsReady() then return unavailable(source, raw) end
        if args.n < 2 then
            return output(source, raw, false,
                "usage: admin.weap.give <playerId|me> <record|alias> [slot|auto] [reserve]")
        end
        local playerId, targetError = resolveTarget(source, args[1])
        if playerId == nil then return output(source, raw, false, targetError) end

        -- The rule this codebase has already paid for: a session with no life
        -- state is the "continue" screen, and acting on it crashes that
        -- client. Equipping is an action on the body; it waits.
        local live, lifeError = actionable(playerId)
        if not live then return output(source, raw, false, lifeError) end

        local record, recordError = resolveRecord(args[2])
        if record == nil then return output(source, raw, false, recordError) end
        local class = classOf(record)
        if class == nil then
            -- Unreachable while the catalogue and the generator agree; kept so
            -- a hand-edited weapons.lua fails loudly instead of indexing nil.
            return output(source, raw, false, "catalogue is inconsistent for " .. record)
        end

        local slot, slotError = parseSlot(args.n >= 3 and args[3] or nil)
        if slot == nil then return output(source, raw, false, slotError) end

        local reserve
        if args.n >= 4 then
            local wanted = Admin.finiteNumber(args[4])
            if wanted == nil or wanted % 1 ~= 0 or wanted < 0
                or wanted > Weapons.maximumReserve then
                return output(source, raw, false, string.format(
                    "reserve must be a whole number from 0 to %d", Weapons.maximumReserve))
            end
            reserve = math.floor(wanted)
        end

        local entry = {
            source = source, raw = raw, playerId = playerId,
            record = record, name = Catalog.nameOf(record), class = class,
            reserve = reserveFor(class, reserve),
            toppedUp = false,
        }

        if slot == "auto" then
            local requestId, reason = Open77.weapons.requestSnapshot(playerId)
            if requestId == nil then
                return output(source, raw, false,
                    "could not read the target's loadout: " .. tostring(reason))
            end
            entry.kind = "pick"
            remember(requestId, entry)
        else
            entry.slot, entry.how = slot, "slot named"
            requestAssign(entry)
        end
        return true, string.format("%d:%s", playerId, record)
    end,
})

Admin.register("admin.weap.ammo", {
    help = "Refill one slot, or every armed slot, to a full load.",
    params = {
        { name = "playerId|me" },
        { name = "slot", help = "1, 2, 3 or all.", optional = true },
        { name = "reserve", optional = true },
    },
    mutation = true,
    handler = function(source, args, raw)
        if not weaponsReady() then return unavailable(source, raw) end
        local playerId, targetError = resolveTarget(source, args[1])
        if playerId == nil then return output(source, raw, false, targetError) end
        local live, lifeError = actionable(playerId)
        if not live then return output(source, raw, false, lifeError) end

        local token = args.n >= 2 and tostring(args[2]):lower() or "all"
        local slots = {}
        if token == "all" then
            -- Only what this package knows is armed. Asking for ammo on an
            -- empty slot answers `weapon_slot_empty`, and three refusals in a
            -- row read like a broken command rather than an empty loadout.
            for slot in pairs(granted[playerId] or {}) do slots[#slots + 1] = slot end
            table.sort(slots)
            if #slots == 0 then
                return output(source, raw, false, string.format(
                    "this resource has not armed player %d -- name a slot, or give them a weapon first",
                    playerId))
            end
        else
            local slot, slotError = parseSlot(token)
            if slot == nil or slot == "auto" then
                return output(source, raw, false, slotError or "slot must be 1, 2, 3 or all")
            end
            slots[1] = slot
        end

        local reserve
        if args.n >= 3 then
            local wanted = Admin.finiteNumber(args[3])
            if wanted == nil or wanted % 1 ~= 0 or wanted < 0
                or wanted > Weapons.maximumReserve then
                return output(source, raw, false, string.format(
                    "reserve must be a whole number from 0 to %d", Weapons.maximumReserve))
            end
            reserve = math.floor(wanted)
        end

        local sent, skippedMelee = 0, 0
        for _, slot in ipairs(slots) do
            local remembered = (granted[playerId] or {})[slot]
            local class = remembered ~= nil and classOf(remembered.record) or nil
            -- Refuse a melee slot here rather than round-trip for a rejection.
            -- A Katana's pool caps at zero, so any reserve fails the engine's
            -- own verification with `ammo_update_rejected` -- a code that tells
            -- the operator nothing about the actual reason.
            if class ~= nil and class.ammo ~= true then
                skippedMelee = skippedMelee + 1
                goto continue
            end
            -- No memory of the slot means no class, so no per-class default:
            -- fall back to the handgun figure rather than invent one, and let
            -- an explicit `reserve` override it as usual.
            local amount = reserve
                or (class ~= nil and reserveFor(class) or reserveFor({ key = "handgun", reserve = 500 }))
            local requestId, reason = Open77.weapons.setAmmo(
                playerId, slot, { reserve = amount, activate = true })
            if requestId == nil then
                output(source, raw, false, string.format(
                    "slot %d ammo rejected: %s", slot, tostring(reason)))
            else
                sent = sent + 1
                remember(requestId, {
                    kind = "refill", source = source, raw = raw, playerId = playerId,
                    slot = slot, reserve = amount, toppedUp = false,
                    name = remembered ~= nil and remembered.name or ("slot " .. slot),
                    record = remembered ~= nil and remembered.record or nil,
                    class = class,
                })
            end
            ::continue::
        end
        if sent == 0 then
            return output(source, raw, false, skippedMelee > 0
                and string.format("nothing to refill: %d melee slot(s) and no firearm",
                    skippedMelee)
                or "nothing to refill")
        end
        if skippedMelee > 0 then
            output(source, raw, true, string.format(
                "refilling %d slot(s); %d melee slot(s) skipped", sent, skippedMelee))
        end
        return true, string.format("%d:%d slot(s)", playerId, sent)
    end,
})

Admin.register("admin.weap.remove", {
    help = "Clear a weapon slot, or all three. The item stays in inventory.",
    params = { { name = "playerId|me" }, { name = "slot", help = "1, 2, 3 or all.", optional = true } },
    mutation = true,
    handler = function(source, args, raw)
        if not weaponsReady() then return unavailable(source, raw) end
        local playerId, targetError = resolveTarget(source, args[1])
        if playerId == nil then return output(source, raw, false, targetError) end
        local live, lifeError = actionable(playerId)
        if not live then return output(source, raw, false, lifeError) end

        local token = args.n >= 2 and tostring(args[2]):lower() or "all"
        local slots = {}
        if token == "all" then
            for slot = 1, kSlots do slots[#slots + 1] = slot end
        else
            local slot, slotError = parseSlot(token)
            if slot == nil or slot == "auto" then
                return output(source, raw, false, slotError or "slot must be 1, 2, 3 or all")
            end
            slots[1] = slot
        end

        local sent = 0
        for _, slot in ipairs(slots) do
            local requestId = Open77.weapons.remove(playerId, slot)
            if requestId ~= nil then
                sent = sent + 1
                remember(requestId, {
                    kind = "remove", source = source, raw = raw,
                    playerId = playerId, slot = slot,
                    -- `all` fans three requests out and each answers
                    -- separately; announcing per slot would be three chat
                    -- lines for one gesture, so only the named form speaks.
                    quiet = token == "all",
                })
            end
        end
        if sent == 0 then
            return output(source, raw, false, "no slot could be cleared")
        end
        if token == "all" then
            granted[playerId] = nil
            output(source, raw, true, string.format(
                "clearing all %d slots for player %d", sent, playerId))
        end
        return true, string.format("%d:%s", playerId, token)
    end,
})

Admin.register("admin.weap.holster", {
    help = "Put a player's weapon away without changing the loadout.",
    params = { { name = "playerId|me" } },
    mutation = true,
    handler = function(source, args, raw)
        if not weaponsReady() then return unavailable(source, raw) end
        local playerId, targetError = resolveTarget(source, args[1])
        if playerId == nil then return output(source, raw, false, targetError) end
        local live, lifeError = actionable(playerId)
        if not live then return output(source, raw, false, lifeError) end
        local requestId, reason = Open77.weapons.holster(playerId)
        if requestId == nil then
            return output(source, raw, false, "holster rejected: " .. tostring(reason))
        end
        remember(requestId, {
            kind = "holster", source = source, raw = raw, playerId = playerId,
        })
        return true, tostring(playerId)
    end,
})

Admin.register("admin.weap.catalog", {
    help = "List the weapon classes, their sizes and their full loads.",
    mutation = false,
    handler = function(source, _, raw)
        push(source, "weapons", {
            catalog = { count = Catalog.count, build = Catalog.build, classes = Catalog.classes },
            aliases = Weapons.aliases,
            maximumReserve = Weapons.maximumReserve,
            atMs = Admin.nowMs(),
        })
        local lines = { string.format("weapon catalogue (%d records, build %s):",
            Catalog.count, Catalog.build) }
        for _, class in ipairs(Catalog.classes) do
            lines[#lines + 1] = string.format("  %-17s %4d  %s",
                class.label, class.count,
                class.ammo and ("full load " .. reserveFor(class) .. " spare rounds")
                    or "melee, no ammo pool")
        end
        local names = {}
        for alias in pairs(Weapons.aliases) do names[#names + 1] = alias end
        table.sort(names)
        lines[#lines + 1] = "aliases: " .. table.concat(names, " ")
        return output(source, raw, true, table.concat(lines, "\n"))
    end,
})

-- ---------------------------------------------------------------------------
-- Read
--
-- Two grants, exactly as props does it: the panel polls the canonical name and
-- gets structured data in silence, a human typing it also gets prose. The
-- snapshot it asks for is asynchronous, so this always answers from the LAST
-- verified reading and requests a fresh one -- an operator who opens the screen
-- sees the previous state for one poll tick rather than a blank.
-- ---------------------------------------------------------------------------
Admin.register("admin.read.weapons", {
    help = "A player's three weapon slots, as their client last verified them.",
    params = { { name = "playerId|me", optional = true } },
    handler = function(source, args, raw, _record, invokedAs)
        local playerId, targetError = resolveTarget(source, args.n >= 1 and args[1] or nil)
        if playerId == nil then return output(source, raw, false, targetError) end

        local known = verified[playerId]
        push(source, "weapons", {
            playerId = playerId,
            name = Open77.players.name(playerId),
            slots = known ~= nil and known.slots or {},
            verifiedAtMs = known ~= nil and known.atMs or nil,
            granted = granted[playerId] or {},
            available = weaponsReady(),
            atMs = Admin.nowMs(),
        })

        if weaponsReady() then
            local live = select(1, actionable(playerId))
            -- Never ask a non-incarnated session for anything.
            if live then
                local requestId = Open77.weapons.requestSnapshot(playerId)
                if requestId ~= nil then
                    remember(requestId, { kind = "read", playerId = playerId })
                end
            end
        end

        if source <= 0 or invokedAs ~= "admin.read.weapons" then
            local lines = { string.format("weapons for player %d (%s):",
                playerId, Open77.players.name(playerId) or "?") }
            for slot = 1, kSlots do
                local row
                for _, candidate in ipairs(known ~= nil and known.slots or {}) do
                    if tonumber(candidate.slot) == slot then row = candidate break end
                end
                if row == nil or row.equipped ~= true then
                    lines[#lines + 1] = string.format("  %d  empty", slot)
                else
                    local name = (type(row.record) == "string" and #row.record > 0)
                        and Catalog.nameOf(row.record) or tostring(row.tweakDbId or "?")
                    lines[#lines + 1] = string.format("  %d  %s%s  %s", slot, name,
                        row.active and " (active)" or "", ammoProse(row.ammo))
                end
            end
            output(source, raw, true, table.concat(lines, "\n"))
        end
        return true
    end,
})

-- ---------------------------------------------------------------------------
-- The one completion handler
--
-- Every step of every chain lands here. `result` for a mutation carries slot,
-- record, tweakDbId, active, drawn and an `ammo` table; for a snapshot it is an
-- array of slot rows. The relay has already matched the authenticated source
-- and the request id, so a row found in `pending` is genuinely ours.
-- ---------------------------------------------------------------------------
AddEventHandler("open77:weapons:completed", function(
    playerId, requestId, operation, accepted, reason, result)
    local key = tostring(requestId)
    local entry = pending[key]
    if entry == nil then return end
    pending[key] = nil
    playerId = tonumber(playerId)
    if playerId == nil or entry.playerId ~= playerId then return end

    -- A snapshot is worth recording whoever asked for it and whether it was
    -- accepted, because it is the only reading of the loadout that exists.
    if operation == "snapshot" and accepted == true and type(result) == "table" then
        verified[playerId] = { atMs = Admin.nowMs(), slots = result }
    end

    if not accepted then
        if entry.kind == "read" then return end     -- a poll answering badly is not news

        -- An ammo step failing AFTER a successful assign is not a failed give:
        -- the weapon is in the slot and usable, only the exact count was
        -- refused. Say both, ledger it, and point at the reading -- reporting a
        -- bare failure would send the operator looking for a weapon that is
        -- already there.
        --
        -- The commonest cause is a CARRIED-POOL CEILING. Measured on 2.31,
        -- 2026-08-30: asking for 1500 spare rifle rounds on an M2067 Defender
        -- answered `ammo_update_rejected`, and the loadout then read 76/80 in
        -- the magazine with 919 spare -- the engine gave what it could and the
        -- REDscript verification (`total == reserve + magazine`) then failed on
        -- the shortfall. The shipped figures sit under the ceilings that were
        -- measured, so this is the path for an operator-typed reserve.
        -- A failed MAGAZINE top-up is a different animal again, and reporting
        -- it as a failure would be wrong: the reserve step before it already
        -- verified, so the weapon is armed and loaded -- only the last few
        -- rounds of the magazine were refused. Seen on 2.31 when re-arming a
        -- slot that already held a weapon of the same ammo type: the top-up
        -- asked for a full 80-round magazine and the reading settled at 70/80
        -- over 800 spare, which is a perfectly usable gun.
        --
        -- `Open77WeaponReport` fills the ammo fields even on a rejection, so
        -- the counts below are the engine's own reading and not a guess.
        if entry.kind == "topUp" and entry.record ~= nil then
            local ammo = type(result) == "table" and type(result.ammo) == "table"
                and result.ammo or nil
            finishGive(entry, ammo)
            return output(entry.source, entry.raw, true, string.format(
                "(the magazine could not be filled to the brim: %s -- the spare pool is "
                .. "already in and the weapon fires)", tostring(reason)))
        end

        if entry.kind == "ammo" and entry.record ~= nil then
            ledgerAdd(entry.playerId, entry.slot, entry.record, entry.class, 0, entry.source)
            return output(entry.source, entry.raw, false, string.format(
                "%s is equipped in slot %d, but the engine refused %d spare rounds (%s) -- "
                .. "the carried pool for that ammo type is probably capped below it; "
                .. "/weapons %d shows what it actually holds",
                entry.name, entry.slot, entry.reserve,
                tostring(reason or "ammo_request_failed"), playerId))
        end

        local what = entry.kind == "pick" and "reading the loadout" or entry.kind
        return output(entry.source, entry.raw, false, string.format(
            "%s failed for player %d: %s", what, playerId,
            -- `request_timeout` is the relay's own word for "the client never
            -- answered", which on this platform almost always means the
            -- open77_weapons resource is not running on that client.
            tostring(reason) == "request_timeout"
                and "the client did not answer -- is open77_weapons running there?"
                or tostring(reason or "weapon_request_failed")))
    end

    result = type(result) == "table" and result or {}

    if entry.kind == "read" then
        return
    end

    if entry.kind == "pick" then
        local slot, how = chooseSlot(result)
        entry.slot, entry.how = slot, how
        return requestAssign(entry)
    end

    if entry.kind == "assign" then
        -- Trust the slot the ENGINE reports over the one we asked for: they
        -- agree today, and if they ever stop, the ammo must follow the weapon.
        entry.slot = tonumber(result.slot) or entry.slot
        if entry.class.ammo ~= true or entry.reserve <= 0 then
            return finishGive(entry, nil)
        end
        return requestAmmo(entry, nil)
    end

    if entry.kind == "ammo" or entry.kind == "topUp" or entry.kind == "refill" then
        local ammo = type(result.ammo) == "table" and result.ammo or {}
        local capacity = tonumber(ammo.capacity)
        local magazine = tonumber(ammo.magazine)
        -- The whole point of the feature: a full spare pool over an empty
        -- magazine is a weapon that cannot fire until the player reloads. One
        -- top-up, from the capacity the engine just reported -- never a guess,
        -- because `magazine > capacity` is refused outright.
        if Weapons.topUpMagazine ~= false and not entry.toppedUp
            and capacity ~= nil and capacity > 0
            and magazine ~= nil and magazine < capacity then
            entry.toppedUp = true
            return requestAmmo(entry, capacity)
        end
        if entry.kind == "refill" then
            return output(entry.source, entry.raw, true, string.format(
                "player %d slot %d: %s", playerId, entry.slot, ammoProse(ammo)))
        end
        return finishGive(entry, ammo)
    end

    if entry.kind == "remove" then
        local rows = granted[playerId]
        if rows ~= nil then rows[entry.slot] = nil end
        if entry.quiet then return end
        return output(entry.source, entry.raw, true, string.format(
            "player %d slot %d cleared (the item stays in their inventory)",
            playerId, entry.slot))
    end

    if entry.kind == "holster" then
        return output(entry.source, entry.raw, true,
            string.format("player %d holstered", playerId))
    end
end)

-- ---------------------------------------------------------------------------
-- The shared surface, for the other server files.
-- ---------------------------------------------------------------------------
Admin.weapons = {
    granted = granted,
    verified = verified,
    resolveRecord = resolveRecord,
    reserveFor = reserveFor,
    ready = weaponsReady,
}

Admin.log(string.format("weapons ready -- %d records in %d classes, build %s",
    Catalog.count, #Catalog.classes, Catalog.build))
