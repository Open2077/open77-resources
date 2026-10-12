-- The operator's half of the nameplate policy.
--
-- ---------------------------------------------------------------------------
-- WHY THIS RESOURCE HAS A SERVER SCRIPT AT ALL.
--
-- It did not, and the client half could have shipped alone: `client/policy.lua`
-- recognises a competitive gamemode by the state push that mode already sends,
-- so Cordon and the deathmatch would be covered with nothing here.
--
-- What would be missing is the SWITCH. "Nameplates off in PvP" must not be a
-- hardcoded removal -- a freeroam server, a roleplay server and Cordon's own
-- staging area all want plates, and the shape this project uses for "an
-- operator may retune this without editing Lua" is `Open77.tunables.declare`,
-- which is server-only. So the seven values below are declared here, rendered
-- by Warden as a form, and pushed to each client as one event.
--
-- The default is `auto`, and that is the load-bearing choice: this resource is
-- in the load list of SIX server profiles and FOUR templates, most of which are
-- not competitive at all. `auto` means "competitive as soon as a competitive
-- gamemode identifies itself on this client, open otherwise", so freeroam,
-- pursuit and race are bit-for-bit unchanged and Cordon and the deathmatch need
-- no configuration to get the new behaviour. Neither
-- server.cordon-local.jsonc nor server.deathmatch-local.jsonc could have
-- carried a `startup` command to set it anyway: StartupCommandTests asserts
-- that no shipped configuration except server.pursuit.jsonc has one, and
-- `tunable.set` PERSISTS rather than applying for a run.
-- ---------------------------------------------------------------------------

local RESOURCE = GetCurrentResourceName()

-- Mirrored in client/policy.lua as its fallback, so a client that never hears
-- from this file behaves exactly as it does today.
local DEFAULTS = {
    policy = "auto",
    friendlyPlates = true,
    friendlyDistance = 200,
    friendlyVitals = true,
    enemyVitals = "engaged",
    enemyVitalsSeconds = 2.5,
    enemyVitalsDistance = 120,
}

local DECLARATION = {
    policy = {
        value = "auto", type = "enum", choices = { "auto", "open", "competitive" },
        apply = "live", label = "Nameplate policy", group = "Nameplates", order = 1,
        description = "auto: plates for everyone until a competitive gamemode says otherwise, then squad-only. open: a plate over every player, the platform default. competitive: squad-only always, whatever the gamemode says.",
    },
    friendlyPlates = {
        value = true, type = "boolean",
        apply = "live", label = "Squad plates", group = "Nameplates", order = 2,
        description = "Keep a nameplate over your own squad or team. Deliberately visible through walls: finding your squad is the whole reason a squad battle royale keeps any plate at all.",
    },
    friendlyDistance = {
        value = 200, type = "integer", min = 5, max = 250, step = 5, unit = "m",
        apply = "live", label = "Squad plate range", group = "Nameplates", order = 3,
        description = "How far a squadmate's plate is drawn. The platform default for an ordinary plate is 35 m; a squad needs to find each other across a district.",
    },
    friendlyVitals = {
        value = true, type = "boolean",
        apply = "live", label = "Squad vitals", group = "Nameplates", order = 4,
        description = "Append health and shield to a squadmate's plate. Leaks nothing: your own squad's health is already on your head-up display.",
    },
    enemyVitals = {
        value = "engaged", type = "enum", choices = { "off", "engaged" },
        apply = "live", label = "Enemy vitals", group = "Nameplates", order = 5,
        description = "engaged: an enemy you have just damaged shows a bare health/shield readout over their body. off: nothing at all for enemies. There is deliberately no 'anyone in view' option -- the plate has no occlusion test, so a health bar on an unhit enemy is the same through-wall position leak the name was.",
    },
    enemyVitalsSeconds = {
        value = 2.5, type = "number", min = 0.5, max = 10.0, step = 0.5, unit = "s",
        apply = "live", label = "Enemy vitals window", group = "Nameplates", order = 6,
        description = "How long after your last hit the readout stays up. Short on purpose: it must confirm a hit, not track a target who has broken contact behind cover.",
    },
    enemyVitalsDistance = {
        value = 120, type = "integer", min = 5, max = 250, step = 5, unit = "m",
        apply = "live", label = "Enemy vitals range", group = "Nameplates", order = 7,
        description = "Beyond this the readout is not drawn even for someone you have just hit.",
    },
}

-- `Open77.tunables.declare` RAISES on a rejected declaration rather than
-- returning a reason, and this resource ships in six server profiles: a throw
-- at load would take nameplates down on all of them. A host without tunable
-- support is a supported state and degrades to the declared defaults.
local Tune = nil
if type(Open77) == "table" and type(Open77.tunables) == "table"
    and type(Open77.tunables.declare) == "function" then
    local ok, proxy = pcall(Open77.tunables.declare, DECLARATION)
    if ok then
        Tune = proxy
    else
        print(("[%s] tunables unavailable, using defaults: %s")
            :format(RESOURCE, tostring(proxy)))
    end
end

--- The effective configuration, read at the point of use.
---
--- `Tune.key` is a CALL behind a metatable, not a field: a local taken at file
--- scope freezes the value at load and every later change from Warden does
--- nothing while Warden goes on reporting the new number.
local function payload()
    local out = {}
    for key, fallback in pairs(DEFAULTS) do
        out[key] = fallback
        if Tune ~= nil then
            local ok, value = pcall(function() return Tune[key] end)
            if ok and value ~= nil then out[key] = value end
        end
    end
    return out
end

local function push(target)
    local ok, reason = TriggerClientEvent("open77:nameplates:policy", target, payload())
    if not ok then
        print(("[%s] policy push to %s refused: %s")
            :format(RESOURCE, tostring(target), tostring(reason)))
    end
end

-- Late join, reload, and reconnect, all through one door. The client asks; a
-- server without this file never answers and the client keeps its defaults --
-- the same contract `open77:perspective:ready` uses.
RegisterNetEvent("open77:nameplates:ready", function()
    push(source)
end)

-- Belt and braces. There is no player enumeration API on the server, so the
-- announce above is the only reliable path for a player who was already here
-- when this resource reloaded; this covers the ordinary join.
AddEventHandler("onPlayerConnected", function(playerIdStr)
    local playerId = tonumber(playerIdStr)
    if playerId == nil or playerId <= 0 then return end
    push(playerId)
end)

-- A retune must reach players who are already playing. -1 is the broadcast
-- target (SessionManager.SendNetEvent: target -1 means every active session).
AddEventHandler("onTunableChanged", function()
    push(-1)
end)
