-- =============================================================================
-- DROP-IN FILE -- copy to `resources/gamemodes/pursuit/server/loadout.lua`
-- =============================================================================
--
-- This file is NOT loaded by open77_vehiclepicker. It lives here because the
-- server side of a gamemode cannot call a shared service: the server Lua
-- runtime installs no `exports` and no cross-resource event bus, so
-- `wiki/gamemode-kernel.md` records that "code generation is the sharing
-- mechanism" on that host. This is that generated code, written once so the
-- next gamemode adapts it rather than re-deriving it.
--
-- WHAT IT DOES
--   * listens for the pick a client's picker reports;
--   * VALIDATES it against the gamemode's own copy of the roster, which is the
--     only validation that counts -- the client's copy is advisory;
--   * remembers it per player, and forgets it on disconnect;
--   * hands `server/vehicles.lua` a spec identical in shape to
--     `Config.vehicles[role]`, so the call site changes by two lines.
--
-- INSTALL (four edits, all in `resources/gamemodes/pursuit`)
--   1. copy `resources/system/open77_vehiclepicker/shared/roster.lua`
--         to `resources/gamemodes/pursuit/shared/roster.lua`   (byte-identical copy)
--   2. copy this file
--         to `resources/gamemodes/pursuit/server/loadout.lua`
--   3. in `resources/gamemodes/pursuit/open77.lua` add, in this order:
--         shared_script "shared/roster.lua"     (anywhere among the shared)
--         server_script "server/loadout.lua"    (AFTER server/main.lua --
--                                                load order is manifest order
--                                                and this file needs `Pursuit`)
--   4. in `resources/gamemodes/pursuit/server/vehicles.lua`, in the "countdown" hook:
--         -  fleet.runner = createCar(match, "runner", Config.vehicles.runner)
--         -  fleet.cop    = createCar(match, "cop",    Config.vehicles.cop)
--         +  fleet.runner = createCar(match, "runner", Pursuit.loadout.specFor("runner", match.runnerId))
--         +  fleet.cop    = createCar(match, "cop",    Pursuit.loadout.specFor("cop",    match.copId))
--
-- `specFor` returns `Config.vehicles[role]` UNCHANGED when the player has no
-- valid pick, so edit 4 is behaviour-preserving on its own: install it, change
-- nothing else, and every match spawns exactly the cars it spawns today.
--
-- KEEPING THE COPY HONEST. Two copies of `roster.lua` can drift and nothing in
-- the build stops that. It is the same trade `open77-ui.css` already makes, and
-- the same one-line check applies:
--
--   Get-FileHash resources\system\open77_vehiclepicker\shared\roster.lua,
--                resources\gamemodes\pursuit\shared\roster.lua -Algorithm SHA256 |
--     Select-Object -ExpandProperty Hash -Unique
--
-- One line of output means the copies match.
-- =============================================================================

local Roster = Open77VehicleRoster
local Config = PursuitConfig

-- Which roster list each Pursuit role picks from. The whole mapping between a
-- gamemode's vocabulary and the picker's lives on this one table; a mode with
-- different roles changes it and nothing else.
local LIST_FOR_ROLE = {
    runner = "civilian",
    cop = "police",
}

-- playerId -> { [listId] = key }. Intent only; re-resolved on every read, so a
-- key whose entry is later deleted from the roster degrades to the default
-- instead of spawning nothing.
local picks = {}

local function log(message)
    print("[pursuit] loadout: " .. message)
end

-- ------------------------------------------------------- receiving the pick --
--
-- The client sends a KEY, never a record. That is the security boundary: a key
-- is not a spawnable thing, so the worst a tampered client achieves is naming a
-- key that does not resolve -- and an unresolved key falls through to the
-- default. Accepting a `Vehicle.*` string instead would hand the client the
-- whole 1,376-record catalogue, quest props and trains included.
--
-- THIS FIRES WITHOUT THE PANEL EVER OPENING. A client reports its remembered
-- picks once per session at `worldReady`, which is how a choice made last week
-- reaches the server at all. So this handler must be idempotent and must not
-- assume it is answering a prompt -- it is just a store.
RegisterNetEvent("open77_vehiclepicker:selected", function(payload)
    local playerId = source
    if playerId == nil or playerId <= 0 then return end
    if type(payload) ~= "table" then return end
    if Roster == nil then
        log("roster missing; is shared/roster.lua listed in the manifest?")
        return
    end

    local listId = payload.list
    local key = payload.key
    local entry = Roster.resolve(listId, key)
    if entry == nil then
        -- Loud, because the only ways to get here are a stale client whose
        -- roster still has a car this one dropped, or a tampered one. Both are
        -- worth a line; neither is worth refusing the player a car.
        log(("player %d sent an unusable pick list=%s key=%s; keeping previous"):format(
            playerId, tostring(listId), tostring(key)))
        return
    end

    picks[playerId] = picks[playerId] or {}
    picks[playerId][listId] = key
    log(("player %d picked %s/%s -> %s"):format(playerId, listId, key, entry.record))
end)

-- Forget on disconnect. The client remembers the pick in its own KVP and
-- re-reports it the next time the picker opens, so nothing is lost by dropping
-- it here -- and keeping it would leak a table entry per player who ever joined.
AddEventHandler("onPlayerDisconnected", function(playerIdStr)
    local playerId = tonumber(playerIdStr)
    if playerId == nil then return end
    picks[playerId] = nil
end)

-- ------------------------------------------------------------------- the API --

Pursuit.loadout = {}

--- The roster list a Pursuit role picks from, or nil.
function Pursuit.loadout.listFor(role)
    return LIST_FOR_ROLE[role]
end

--- The spec `createCar` should use for this role and player.
---
--- Returns `Config.vehicles[role]` untouched when there is no valid pick, which
--- is what makes the call-site edit safe to land on its own. When there is one,
--- it returns a SHALLOW COPY with `record` and `fallbackRecord` replaced --
--- deliberately a copy, because mutating the config table would make one
--- player's choice stick to every later match until the resource reloaded.
---
--- Colours, lights and siren are NOT overridden. The picker chooses a chassis;
--- Pursuit still decides that the runner is dark and unmarked and that the cop
--- runs a siren, because those are rules of the mode and not preferences.
function Pursuit.loadout.specFor(role, playerId)
    local base = Config.vehicles[role]
    if base == nil then return nil end

    local listId = LIST_FOR_ROLE[role]
    if listId == nil or Roster == nil or playerId == nil then return base end

    local key = picks[playerId] and picks[playerId][listId] or nil
    local entry = Roster.resolve(listId, key)
    if entry == nil then return base end

    local spec = {}
    for field, value in pairs(base) do spec[field] = value end
    spec.record = entry.record
    -- An entry with no fallback of its own keeps the config's, so a civilian
    -- pick (which needs none) does not inherit the cop's Cortes by accident --
    -- `Config.vehicles.runner` has no `fallbackRecord` to inherit.
    spec.fallbackRecord = entry.fallback or base.fallbackRecord
    return spec
end

--- Ask a player to choose. `deadlineMs` closes the panel on its own if he walks
--- away from the keyboard; pass nil for no clock.
function Pursuit.loadout.offerTo(playerId, role, deadlineMs)
    local listId = LIST_FOR_ROLE[role]
    if listId == nil then return false, "no_list_for_role:" .. tostring(role) end
    return TriggerClientEvent("open77_vehiclepicker:open", playerId, {
        list = listId,
        deadlineMs = deadlineMs,
    })
end

--- The match started: the panel goes read-only and says the pick is for the
--- next one. This is the answer to "what if he chooses after it starts" -- the
--- pick is kept and honestly labelled, rather than silently applied to a car
--- that already exists.
function Pursuit.loadout.lock(playerId)
    return TriggerClientEvent("open77_vehiclepicker:lock", playerId, { locked = true })
end

function Pursuit.loadout.unlock(playerId)
    return TriggerClientEvent("open77_vehiclepicker:lock", playerId, { locked = false })
end

--- What this player would drive right now, for a diagnostic line.
function Pursuit.loadout.describe(playerId, role)
    local spec = Pursuit.loadout.specFor(role, playerId)
    if spec == nil then return "no spec" end
    return ("%s (fallback %s)"):format(
        tostring(spec.record), tostring(spec.fallbackRecord))
end

-- ------------------------------------------------------ the player-facing bit --
--
-- A ROLE IS NOT KNOWN UNTIL THE MATCH STARTS. Pursuit assigns it in
-- `match.roles[playerId]` when a pair is drawn, so a player in the lobby cannot
-- be shown "your" list -- he does not have one yet.
--
-- The design follows from that rather than fighting it: he picks for BOTH roles
-- in advance, the two picks are remembered independently, and the role draw
-- simply decides which of the two applies. Nobody is ever asked to choose under
-- a countdown they did not expect, and a player who never opens the panel gets
-- the roster default for whichever role he draws -- which is the pair Pursuit
-- spawns today.
--
-- `docs/writing-a-gamemode.md` section 6: add the "what does the SERVER see"
-- command early, because nearly every confusing failure this project has hit
-- was answered by one in a single line. `show` is that command.
RegisterCommand("pursuit.vehicle", function(source, args, raw)
    local out = Pursuit.output
    if source == nil or source <= 0 then
        return out(source, raw, false, "pursuit.vehicle must be issued in-game")
    end

    local what = (args and args[1] or "runner"):lower()

    if what == "show" then
        return out(source, raw, true, ("runner -> %s // cop -> %s"):format(
            Pursuit.loadout.describe(source, "runner"),
            Pursuit.loadout.describe(source, "cop")))
    end

    if LIST_FOR_ROLE[what] == nil then
        return out(source, raw, false, "usage: pursuit.vehicle [runner|cop|show]")
    end

    -- No deadline. This is opened on demand, from the lobby, with nothing
    -- waiting on it; a clock here would only add pressure to a decision that
    -- has none. The 45 s deadline is for the automatic offer, if a future
    -- change adds one at queue time.
    local ok, reason = Pursuit.loadout.offerTo(source, what, nil)
    if not ok then
        return out(source, raw, false, "picker unavailable: " .. tostring(reason))
    end
    return out(source, raw, true, "vehicle picker opened for " .. what)
end, false)
