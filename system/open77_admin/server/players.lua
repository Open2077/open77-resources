-- Self, player and moderation commands. Admin.register rechecks the host ACL
-- at execution; each handler validates its target and state before mutation.
-- No gamemode-specific lifecycle hooks or spawn/death ownership.
local Config = Admin.Config
local output, push = Admin.output, Admin.push
local finiteNumber, clamp = Admin.finiteNumber, Admin.clamp
local resolveTarget, actionable, placeable = Admin.resolveTarget, Admin.actionable, Admin.placeable
local placeAt, announce = Admin.placeAt, Admin.announce

-- ---------------------------------------------------------------------------
-- Self: noclip, fly, godmode, health
--
-- Noclip is a CLIENT capability, so authority works by delegation: the ACL
-- decides here, then the trusted client half flips the switch through its
-- `player.travel` permission. The native lab commands (noclip, fly, tp) are
-- refused by the client while a multiplayer session is active, so this is the
-- only online path.
--
-- This is not a security boundary and should not be mistaken for one: a player
-- who has patched their own client can already fly. What the ACL protects is
-- everything an operator can do to SOMEBODY ELSE.
-- ---------------------------------------------------------------------------
local noclipOn = {}
local noclipGrant = {}

local function toggleArgument(args, current)
    if args.n == 0 or args[1] == nil then return not current end
    local token = tostring(args[1]):lower()
    if token == "on" or token == "1" or token == "true" then return true end
    if token == "off" or token == "0" or token == "false" then return false end
    return nil
end

-- Speeds the operator picked by hand, so the enable-time default never
-- overwrites a deliberate choice.
local chosenSpeed = {}

local function setNoclip(source, args, raw, label)
    local enable = toggleArgument(args, noclipOn[source] == true)
    if enable == nil then
        return output(source, raw, false, "usage: " .. label .. " [on|off]")
    end
    noclipOn[source] = enable or nil
    noclipGrant[source] = enable and label or nil
    TriggerClientEvent("open77_admin:travel", source, "noclip", enable)

    -- Apply the configured default the first time this player switches noclip
    -- on. Until now `default` was only the number the menu DISPLAYED when it
    -- had nothing else to show -- nothing ever sent it -- so enabling noclip
    -- left the native on its own speed and the setting read as a lie. Once the
    -- operator has chosen a speed we never override it again, because a
    -- toggle that resets your preference is worse than one that starts slow.
    if enable and chosenSpeed[source] == nil then
        local default = Config.travel.speed and Config.travel.speed.default
        if type(default) == "number" then
            chosenSpeed[source] = default
            TriggerClientEvent("open77_admin:travel", source, "noclipSpeed", default)
        end
    end

    return output(source, raw, true, enable and "noclip requested" or "noclip disabled"),
        (enable and "on" or "off")
end

-- Feedback can correct a rejected activation or a native death/vehicle stop.
-- It never grants permission: an `on` without an existing ACL delegation is
-- ignored. A resource cannot use this event as a second enable command.
RegisterNetEvent("open77_admin:noclipState", function(active)
    local playerId = tonumber(source)
    if not playerId or playerId <= 0 or type(active) ~= "boolean" then return end
    if active then
        local grant = noclipGrant[playerId]
        if grant and Admin.allowed(playerId, grant) then noclipOn[playerId] = true end
    else
        noclipOn[playerId], noclipGrant[playerId] = nil, nil
    end
end)

Admin.register("admin.self.noclip", {
    help = "Toggle noclip for yourself.",
    params = { { name = "on|off", help = "Omit to toggle.", optional = true } },
    requiresPlayer = true, mutation = true,
    handler = function(source, args, raw, _, invokedAs) return setNoclip(source, args, raw, invokedAs) end,
})

Admin.register("admin.self.fly", {
    help = "Toggle fly for yourself. Same switch as noclip, granted separately.",
    params = { { name = "on|off", help = "Omit to toggle.", optional = true } },
    requiresPlayer = true, mutation = true,
    handler = function(source, args, raw, _, invokedAs) return setNoclip(source, args, raw, invokedAs) end,
})

Admin.register("admin.self.speed", {
    help = "Noclip speed in metres per second. " .. Config.travel.modifiers,
    params = { { name = "metresPerSecond", help = "0.1 to 500." } },
    requiresPlayer = true, mutation = true,
    handler = function(source, args, raw)
        local speed = args.n == 1 and finiteNumber(args[1]) or nil
        -- The native clamps 0.1..500 and refuses anything outside; refusing it
        -- here too means the operator gets a usage line instead of silence.
        if speed == nil or speed < 0.1 or speed > 500.0 then
            return output(source, raw, false, "usage: admin.self.speed <0.1..500 m/s>")
        end
        chosenSpeed[source] = speed
        TriggerClientEvent("open77_admin:travel", source, "noclipSpeed", speed)
        return output(source, raw, true, string.format("noclip speed %.1f m/s", speed)),
            string.format("%.1f", speed)
    end,
})

Admin.register("admin.self.pos", {
    help = "Copy your world position to the clipboard as Lua.",
    requiresPlayer = true, mutation = false,
    handler = function(source, _, raw)
        TriggerClientEvent("open77_admin:travel", source, "copyPosition", true)
        return output(source, raw, true, "copying your position")
    end,
})

-- ---------------------------------------------------------------------------
-- Life and health, on yourself or on somebody else.
--
-- The self and player forms are separate COMMANDS rather than one command with
-- a target argument, because the permission is derived from the command name:
-- one command means one grant, and "may heal himself" and "may heal anybody"
-- have to be separable.
-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- HEALTH HAS TWO SCALES ON TWO NEIGHBOURING APIS, and mixing them is quiet.
--
--   getHealth / setHealth / setArmor  -- ABSOLUTE points, out of maxHealth
--                                        (which defaults to 100)
--   revive / respawn { health = ... } -- a FRACTION, validated 0.01..1.0
--
-- So `setHealth(id, 1.0)` does not heal anybody: it leaves them on one hit
-- point. Everything below works in absolute points and converts once, here.
-- ---------------------------------------------------------------------------
local function maxHealthOf(playerId)
    local health = Open77.players.getHealth(playerId)
    local maximum = health ~= nil and tonumber(health.maxHealth) or nil
    if maximum == nil or maximum <= 0 then maximum = 100.0 end
    return maximum, health
end

local function healTarget(source, playerId, raw)
    local ok, detail = actionable(playerId)
    if not ok then return output(source, raw, false, detail) end
    local maximum = maxHealthOf(playerId)
    local applied, reason = Open77.players.setHealth(playerId, maximum)
    if not applied then return output(source, raw, false, "rejected: " .. tostring(reason)) end
    if playerId ~= source then announce(playerId, "An administrator healed you.") end
    return output(source, raw, true,
        string.format("player %d healed to %.0f", playerId, maximum)), tostring(playerId)
end

local function reviveTarget(source, playerId, raw)
    local ok, detail = actionable(playerId)
    if not ok then return output(source, raw, false, detail) end
    local revived, reason = Open77.players.revive(playerId, {
        health = Config.teleport.health,
        graceMs = Config.teleport.graceMs,
    })
    if not revived then return output(source, raw, false, "rejected: " .. tostring(reason)) end
    if playerId ~= source then announce(playerId, "An administrator revived you.") end
    return output(source, raw, true, "player " .. playerId .. " revived"), tostring(playerId)
end

local function setGod(source, playerId, args, raw, argIndex)
    local health = Open77.players.getHealth(playerId)
    local current = health ~= nil and health.godMode == true
    local packed = { n = args.n - argIndex + 1 }
    for index = argIndex, args.n do packed[index - argIndex + 1] = args[index] end
    local enable = toggleArgument(packed, current)
    if enable == nil then return output(source, raw, false, "usage: ... [on|off]") end
    local ok, detail = actionable(playerId)
    if not ok then return output(source, raw, false, detail) end
    local applied, reason = Open77.players.setGodMode(playerId, enable)
    if not applied then return output(source, raw, false, "rejected: " .. tostring(reason)) end
    return output(source, raw, true,
        string.format("player %d god mode %s", playerId, enable and "on" or "off")),
        string.format("%d=%s", playerId, enable and "on" or "off")
end

Admin.register("admin.self.heal", {
    help = "Restore your own health.",
    requiresPlayer = true, mutation = true,
    handler = function(source, _, raw) return healTarget(source, source, raw) end,
})

Admin.register("admin.self.revive", {
    help = "Revive yourself in place.",
    requiresPlayer = true, mutation = true,
    handler = function(source, _, raw) return reviveTarget(source, source, raw) end,
})

Admin.register("admin.self.god", {
    help = "Toggle your own damage immunity.",
    params = { { name = "on|off", help = "Omit to toggle.", optional = true } },
    requiresPlayer = true, mutation = true,
    handler = function(source, args, raw) return setGod(source, source, args, raw, 1) end,
})

Admin.register("admin.player.heal", {
    help = "Restore another player's health.",
    params = { { name = "playerId" } },
    mutation = true,
    handler = function(source, args, raw)
        local playerId, reason = resolveTarget(source, args[1])
        if playerId == nil then return output(source, raw, false, reason) end
        return healTarget(source, playerId, raw)
    end,
})

Admin.register("admin.player.revive", {
    help = "Revive another player in place.",
    params = { { name = "playerId" } },
    mutation = true,
    handler = function(source, args, raw)
        local playerId, reason = resolveTarget(source, args[1])
        if playerId == nil then return output(source, raw, false, reason) end
        return reviveTarget(source, playerId, raw)
    end,
})

Admin.register("admin.player.god", {
    help = "Toggle another player's damage immunity.",
    params = { { name = "playerId" }, { name = "on|off", optional = true } },
    mutation = true,
    handler = function(source, args, raw)
        local playerId, reason = resolveTarget(source, args[1])
        if playerId == nil then return output(source, raw, false, reason) end
        return setGod(source, playerId, args, raw, 2)
    end,
})

Admin.register("admin.player.health", {
    help = "Set another player's health, in absolute points out of their maximum.",
    params = { { name = "playerId" }, { name = "points", help = "0 to maxHealth (usually 100)." } },
    mutation = true,
    handler = function(source, args, raw)
        local playerId, reason = resolveTarget(source, args[1])
        if playerId == nil then return output(source, raw, false, reason) end
        local ok, detail = actionable(playerId)
        if not ok then return output(source, raw, false, detail) end

        local maximum = maxHealthOf(playerId)
        local value = args.n >= 2 and finiteNumber(args[2]) or nil
        if value == nil then
            return output(source, raw, false, string.format(
                "usage: admin.player.health <playerId> <0..%.0f>  -- absolute points, not a fraction",
                maximum))
        end
        value = clamp(value, 0.0, maximum)
        -- Zero passes through life authority rather than bypassing it, which is
        -- why this is safe to expose next to a separate kill command.
        local applied, failure = Open77.players.setHealth(playerId, value)
        if not applied then return output(source, raw, false, "rejected: " .. tostring(failure)) end
        return output(source, raw, true,
            string.format("player %d health %.0f/%.0f", playerId, value, maximum)),
            string.format("%d=%.0f", playerId, value)
    end,
})

Admin.register("admin.player.armor", {
    help = "Set another player's armor.",
    params = { { name = "playerId" }, { name = "armor" } },
    mutation = true,
    handler = function(source, args, raw)
        local playerId, reason = resolveTarget(source, args[1])
        if playerId == nil then return output(source, raw, false, reason) end
        local value = args.n >= 2 and finiteNumber(args[2]) or nil
        if value == nil or value < 0 then
            return output(source, raw, false, "usage: admin.player.armor <playerId> <armor>")
        end
        local ok, detail = actionable(playerId)
        if not ok then return output(source, raw, false, detail) end
        local applied, failure = Open77.players.setArmor(playerId, value)
        if not applied then return output(source, raw, false, "rejected: " .. tostring(failure)) end
        return output(source, raw, true, string.format("player %d armor %.0f", playerId, value)),
            string.format("%d=%.0f", playerId, value)
    end,
})

Admin.register("admin.player.kill", {
    help = "Kill another player.",
    params = { { name = "playerId" }, { name = "reason", optional = true } },
    mutation = true,
    handler = function(source, args, raw)
        local playerId, reason = resolveTarget(source, args[1])
        if playerId == nil then return output(source, raw, false, reason) end
        local ok, detail = actionable(playerId)
        if not ok then return output(source, raw, false, detail) end
        local killed, failure = Open77.players.kill(playerId, {
            killer = source > 0 and source or nil,
            cause = "script",
            weapon = "open77_admin:kill",
        })
        if not killed then return output(source, raw, false, "rejected: " .. tostring(failure)) end
        announce(playerId, "An administrator killed you.")
        return output(source, raw, true, "player " .. playerId .. " killed"), tostring(playerId)
    end,
})

-- ---------------------------------------------------------------------------
-- Movement
--
-- `goto` moves the CALLER and is listed first on purpose: it is the safest of
-- the three and the one an operator reaches for first. Moving somebody else is
-- always announced to them.
--
-- A player in a non-zero routing bucket is in a gamemode's match. This resource
-- cannot ask that gamemode whether the move is safe -- server resources cannot
-- talk to each other -- so the answer is disclosure, not prevention: the bucket
-- is reported back in the result line and the panel flags it before the click.
-- ---------------------------------------------------------------------------
--- Close the caller's panel.
---
--- Used by the three commands that move the OPERATOR. Landing somewhere with a
--- full-screen modal still over the world is exactly the wrong moment to be
--- reading a table, and it is also what makes the client's server-sent close a
--- real exit rather than a hook nothing uses.
local function dismissPanel(source)
    if source ~= nil and source > 0 then
        TriggerClientEvent("open77_admin:close", source)
    end
end

local function bucketNote(playerId)
    local position = Open77.players.position(playerId)
    local bucket = position and position.bucket or 0
    if bucket == 0 then return "" end
    return string.format(" (bucket %d -- they are in a match)", bucket)
end

-- ---------------------------------------------------------------------------
-- Map travel: double-click the world map to be placed there
--
-- It sits down here, among the commands that move people, because it needs
-- `dismissPanel` and the placement helpers -- not because it acts on anyone but
-- the caller. It cannot: there is no target token and no way to spell one.
--
-- ONE command carries both halves on purpose, and the arity tells them apart:
--
--     /maptravel            toggle the gesture
--     /maptravel on|off     set it
--     /maptravel x y z      go there -- this is what a double click sends
--
-- That is one permission (`command.admin.self.maptravel`, or `command.maptp`
-- for the alias) to grant and one name in the audit trail, and it means the
-- ACL is consulted again on every single placement rather than once at arming
-- time. An operator whose grant is revoked mid-session stops travelling on the
-- next double click, not on the next reconnect.
--
-- The arm is deliberately NOT re-checked on the coordinate form. It lives on
-- the client, where it decides whether a double click asks at all; mirroring it
-- here would buy no security -- anyone who can send coordinates can send
-- `on` first -- and would add a state that a resource reload desynchronises,
-- turning a working gesture into a confusing refusal.
--
-- Where the coordinates come from is the interesting half, and it is not this
-- file: `client/redscript/Open77MapTravel.reds` borrows the vanilla world
-- map's own custom-waypoint native, which is the only cursor -> world
-- conversion in the build.
-- ---------------------------------------------------------------------------
local mapTravelOn = {}
local mapTravelGrant = {}

Admin.register("admin.self.maptravel", {
    help = "Arm the world map: double-click a spot to be placed there.",
    params = {
        { name = "on|off|x", help = "Omit to toggle. Three numbers travel there.", optional = true },
        { name = "y", optional = true },
        { name = "z", optional = true },
    },
    requiresPlayer = true, mutation = true,
    handler = function(source, args, raw, _record, invokedAs)
        if args.n == 3 then
            local x, y, z = finiteNumber(args[1]), finiteNumber(args[2]), finiteNumber(args[3])
            if x == nil or y == nil or z == nil then
                return output(source, raw, false, "invalid map destination")
            end
            -- Carry the last heading forward instead of snapping north on
            -- every hop. It is NOT the direction the operator is looking:
            -- `life.yaw` is written only at a kill or a respawn, so it is the
            -- direction they were last PLACED facing -- measured while building
            -- `dm.survey mark`, which had to ask the client for a real heading
            -- for exactly this reason. That makes it the wrong number for
            -- recording a landmark and the right one here, where all it has to
            -- do is stay put across a run of map jumps. The units match: every
            -- resource in the tree passes a `heading` straight into a `yaw`.
            local life = Open77.players.getLifeState(source)
            local heading = life ~= nil and finiteNumber(life.yaw) or nil
            local note = bucketNote(source)
            local ok, detail = placeAt(source, { x = x, y = y, z = z }, heading or 0.0,
                nil, "maptravel")
            if not ok then return output(source, raw, false, detail) end
            dismissPanel(source)
            return output(source, raw, true,
                string.format("map travel -> %.1f %.1f %.1f%s", x, y, z, note)),
                string.format("%.0f,%.0f,%.0f", x, y, z)
        end

        local enable = toggleArgument(args, mapTravelOn[source] == true)
        if enable == nil then
            return output(source, raw, false,
                "usage: admin.self.maptravel [on|off] | admin.self.maptravel <x> <y> <z>")
        end
        mapTravelOn[source] = enable or nil
        mapTravelGrant[source] = enable and invokedAs or nil
        -- The word the operator actually typed goes with the arm. A name and
        -- its alias carry SEPARATE permissions (see `register` in main.lua), so
        -- the double click has to come back under the same one that armed it or
        -- an operator holding only `command.maptp` would arm a gesture the ACL
        -- then refuses.
        TriggerClientEvent("open77_admin:travel", source, "mapPick", enable,
            tostring(invokedAs or "admin.self.maptravel"))
        return output(source, raw, true, enable
                and "map travel armed -- open the map and double-click a spot"
                or "map travel disarmed"),
            (enable and "on" or "off")
    end,
})

Admin.register("admin.player.goto", {
    help = "Teleport yourself to another player.",
    params = { { name = "playerId" } },
    requiresPlayer = true, mutation = true,
    handler = function(source, args, raw)
        local playerId, reason = resolveTarget(source, args[1])
        if playerId == nil then return output(source, raw, false, reason) end
        if playerId == source then return output(source, raw, false, "you are already there") end
        local position = Open77.players.position(playerId)
        if position == nil then
            return output(source, raw, false, "player " .. playerId .. " has no readable position yet")
        end
        local ok, detail = placeAt(source, {
            x = position.x + Config.teleport.bringOffset.x,
            y = position.y + Config.teleport.bringOffset.y,
            z = position.z + Config.teleport.bringOffset.z,
        }, 0.0, position.bucket, "goto")
        if not ok then return output(source, raw, false, detail) end
        dismissPanel(source)
        return output(source, raw, true,
            string.format("teleporting to player %d%s", playerId, bucketNote(playerId))),
            tostring(playerId)
    end,
})

Admin.register("admin.player.bring", {
    help = "Teleport another player to you.",
    params = { { name = "playerId" } },
    requiresPlayer = true, mutation = true,
    handler = function(source, args, raw)
        local playerId, reason = resolveTarget(source, args[1])
        if playerId == nil then return output(source, raw, false, reason) end
        if playerId == source then return output(source, raw, false, "you are already here") end
        local note = bucketNote(playerId)
        local position = Open77.players.position(source)
        if position == nil then return output(source, raw, false, "your own position is not readable yet") end
        local ok, detail = placeAt(playerId, {
            x = position.x + Config.teleport.bringOffset.x,
            y = position.y + Config.teleport.bringOffset.y,
            z = position.z + Config.teleport.bringOffset.z,
        }, 0.0, position.bucket, "bring")
        if not ok then return output(source, raw, false, detail) end
        announce(playerId, "An administrator brought you to them.")
        return output(source, raw, true,
            string.format("player %d brought to you%s", playerId, note)), tostring(playerId)
    end,
})

Admin.register("admin.player.tp", {
    help = "Teleport a player to world coordinates.",
    params = {
        { name = "playerId|me" }, { name = "x" }, { name = "y" }, { name = "z" },
        { name = "heading", optional = true },
    },
    mutation = true,
    handler = function(source, args, raw)
        if args.n < 4 or args.n > 5 then
            return output(source, raw, false, "usage: admin.player.tp <playerId|me> <x> <y> <z> [heading]")
        end
        local playerId, reason = resolveTarget(source, args[1])
        if playerId == nil then return output(source, raw, false, reason) end
        local x, y, z = finiteNumber(args[2]), finiteNumber(args[3]), finiteNumber(args[4])
        -- NOT `args.n == 5 and finiteNumber(args[5]) or 0.0`: the `or` swallows
        -- a nil from finiteNumber, so the guard below could never fire and a
        -- non-numeric heading was silently accepted as 0 degrees.
        local heading = 0.0
        if args.n == 5 then heading = finiteNumber(args[5]) end
        if x == nil or y == nil or z == nil or heading == nil then
            return output(source, raw, false, "invalid coordinates")
        end
        local note = bucketNote(playerId)
        local ok, detail = placeAt(playerId, { x = x, y = y, z = z }, heading, nil, "tp")
        if not ok then return output(source, raw, false, detail) end
        if playerId ~= source then
            announce(playerId, "An administrator teleported you.")
        else
            dismissPanel(source)
        end
        return output(source, raw, true,
            string.format("player %d moved to %.1f %.1f %.1f%s", playerId, x, y, z, note)),
            string.format("%d->%.0f,%.0f,%.0f", playerId, x, y, z)
    end,
})

Admin.register("admin.player.observe", {
    help = "Teleport to a player and enable noclip in one step.",
    params = { { name = "playerId" } },
    requiresPlayer = true, mutation = true,
    handler = function(source, args, raw)
        local playerId, reason = resolveTarget(source, args[1])
        if playerId == nil then return output(source, raw, false, reason) end
        local position = Open77.players.position(playerId)
        if position == nil then
            return output(source, raw, false, "player " .. playerId .. " has no readable position yet")
        end
        local ok, detail = placeAt(source, {
            x = position.x, y = position.y, z = position.z + 2.0,
        }, 0.0, position.bucket, "observe")
        if not ok then return output(source, raw, false, detail) end
        noclipOn[source] = true
        noclipGrant[source] = "admin.player.observe"
        TriggerClientEvent("open77_admin:travel", source, "noclip", true)
        dismissPanel(source)
        -- Honest naming: this is not spectate. There is no camera-attach API,
        -- so the target can see you standing there. See README, "Not built".
        return output(source, raw, true,
            string.format("observing player %d -- noclip on, and they can see you", playerId)),
            tostring(playerId)
    end,
})

-- ---------------------------------------------------------------------------
-- Moderation
-- ---------------------------------------------------------------------------
local function joinFrom(args, index)
    local parts = {}
    for position = index, args.n do parts[#parts + 1] = tostring(args[position] or "") end
    local text = table.concat(parts, " ")
    return text ~= "" and text or nil
end

--- Trim to a BYTE limit without producing invalid UTF-8, and without
--- overshooting the limit the trim exists to respect.
---
--- Two traps here, both of which defeat the obvious implementation:
---   * `"…"` is THREE UTF-8 bytes, so `sub(1, limit - 1) .. "…"` lands at
---     `limit + 2`. The transport caps a disconnect reason at 127 bytes and
---     answers `invalid_reason` above it -- so the naive trim makes the kick
---     fail entirely, which is the exact failure it was written to prevent.
---   * a byte cut can land inside a multi-byte sequence. Back off over any
---     continuation byte (10xxxxxx) before appending.
local function trimTo(text, limit)
    if #text <= limit then return text end
    local cut = limit - 3                       -- room for the ellipsis
    while cut > 0 do
        local byte = text:byte(cut + 1)
        if byte == nil or byte < 0x80 or byte >= 0xC0 then break end
        cut = cut - 1                           -- we are inside a sequence
    end
    return text:sub(1, cut) .. "…"
end

--- The transport limits a disconnect reason to 127 UTF-8 bytes so GNS can
--- deliver it without truncation. Trim here rather than letting the platform
--- refuse the whole call over a long sentence.
local function trimReason(text, limit)
    if text == nil then return nil end
    text = text:gsub("[%c]", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then return nil end
    return trimTo(text, limit)
end

Admin.trimTo = trimTo

Admin.register("admin.moderate.kick", {
    help = "Disconnect a player with a reason they will see.",
    params = { { name = "playerId" }, { name = "reason", optional = true } },
    mutation = true,
    handler = function(source, args, raw)
        local playerId, reason = resolveTarget(source, args[1])
        if playerId == nil then return output(source, raw, false, reason) end
        local text = trimReason(joinFrom(args, 2), 127) or "Kicked by an administrator."
        local ok, failure = Open77.players.kick(playerId, text)
        if not ok then return output(source, raw, false, "rejected: " .. tostring(failure)) end
        return output(source, raw, true, string.format("player %d kicked -- %s", playerId, text)),
            string.format("%d:%s", playerId, text)
    end,
})

--- Durations carry a unit -- `30m`, `12h`, `7d`, `3600s` -- and `perm` is
--- explicit. A BARE NUMBER IS REASON TEXT, deliberately.
---
--- The obvious design, "slot 2 is the duration if it parses as a number", is
--- ambiguous against free text and fails in a way an operator cannot see:
--- `/ban 7 3 strikes` bans for seven seconds, and `/ban 7 0 tolerance` refuses
--- the whole command with a complaint about durations to somebody who typed a
--- sentence. Requiring a unit removes the ambiguity in both directions.
local DURATION_UNITS = { s = 1, m = 60, h = 3600, d = 86400 }

local function parseDuration(token)
    if type(token) ~= "string" then return nil end
    local lowered = token:lower()
    if lowered == "perm" or lowered == "permanent" then return false end   -- explicit, not "absent"
    local value, unit = lowered:match("^(%d+)([smhd])$")
    if value == nil then return nil end
    local seconds = tonumber(value) * DURATION_UNITS[unit]
    if seconds <= 0 or seconds > 315360000 then return nil end
    return seconds
end

Admin.register("admin.moderate.ban", {
    help = "Persist a server-local identity ban and disconnect that player's sessions.",
    params = {
        { name = "playerId" },
        { name = "duration", help = "30m, 12h, 7d, 3600s, or perm. Omit for permanent.", optional = true },
        { name = "reason", optional = true },
    },
    mutation = true,
    handler = function(source, args, raw)
        local playerId, reason = resolveTarget(source, args[1])
        if playerId == nil then return output(source, raw, false, reason) end

        local duration, reasonIndex = nil, 2
        if args.n >= 2 then
            local parsed = parseDuration(args[2])
            if parsed == false then
                duration, reasonIndex = nil, 3          -- "perm", stated out loud
            elseif parsed ~= nil then
                duration, reasonIndex = parsed, 3
            elseif tostring(args[2]):lower():match("^%-?%d+[smhd]$") then
                return output(source, raw, false, "duration must be positive, at most 3650d, or perm")
            end
            -- Anything else is the first word of the reason, and that includes
            -- a bare number. Nothing is refused here.
        end
        local text = trimReason(joinFrom(args, reasonIndex), 200) or "Banned by an administrator."
        local identifier = Open77.players.identifier(playerId)

        -- The server's persistent admission list is independent of master
        -- availability and of every gamemode. The host saves before kicking.
        local ok, failure = Open77.access.ban(identifier, text, duration, Open77.players.name(playerId))
        if not ok then return output(source, raw, false, "rejected: " .. tostring(failure)) end
        return output(source, raw, true, string.format(
            "player %d (%s) banned %s -- %s", playerId, tostring(identifier),
            duration and string.format("for %d s", duration) or "permanently", text)),
            string.format("%s:%s", tostring(identifier), text)
    end,
})

-- Disconnect clears the noclip memo. A recycled player id must not inherit the
-- previous occupant's toggle state -- freeroam leaks exactly this.
AddEventHandler("onPlayerDisconnected", function(playerIdStr)
    local playerId = tonumber(playerIdStr)
    if playerId ~= nil then
        noclipOn[playerId], noclipGrant[playerId], chosenSpeed[playerId] = nil, nil, nil
        mapTravelOn[playerId], mapTravelGrant[playerId] = nil, nil
    end
end)

-- A revoked role must not leave an already-enabled delegated travel mode on.
-- Track the exact granting command, including aliases with independent ACLs.
local function releaseTravel(all)
    for playerId, command in pairs(noclipGrant) do
        if all or not Admin.allowed(playerId, command) then
            TriggerClientEvent("open77_admin:travel", playerId, "noclip", false)
            noclipOn[playerId], noclipGrant[playerId] = nil, nil
        end
    end
    for playerId, command in pairs(mapTravelGrant) do
        if all or not Admin.allowed(playerId, command) then
            TriggerClientEvent("open77_admin:travel", playerId, "mapPick", false)
            mapTravelOn[playerId], mapTravelGrant[playerId] = nil, nil
        end
    end
end
CreateThread(function() while true do Wait(1000) releaseTravel(false) end end)
AddEventHandler("onResourceStop", function(name)
    if name == GetCurrentResourceName() then releaseTravel(true) end
end)

Admin.noclipOn = noclipOn
