-- Who gets a plate, and what it says.
--
-- ---------------------------------------------------------------------------
-- WHY THIS FILE EXISTS: A NAMEPLATE IS A WALLHACK.
--
-- `client/main.lua` beside this one turns the native drawer on and then leaves
-- it alone, and the native drawer labels EVERY attached remote player within
-- `maximumDistance` (35 m by default, client/src/api/Nameplates.hpp). Its
-- culling is depth and viewport only -- `Api::Nameplates::Snapshot` tests the
-- camera plane, the distance and the NDC box, and NOTHING ELSE. There is no
-- occlusion test anywhere in the path, so the plate is drawn through walls,
-- floors and buildings.
--
-- In a free-for-all, and worse in a battle royale, that is not a label. It is a
-- position broadcast with the geometry taken out, and it is widest exactly
-- where a fight is decided: 35 m is inside a room, around a corner, one floor
-- up. `resources/gamemodes/pursuit` reached the same conclusion first and switched the
-- whole thing off for the length of a match (shared/config.lua,
-- `hideOpponentNameplates`, with the measurement written out).
--
-- Off is right for a duel. It is wrong for a SQUAD battle royale: Cordon's
-- default format is Squad(4), it already colours squads and draws a squad
-- panel, and a player who cannot pick their own squad out of a street is
-- playing four solos. So the answer is not "no plates", it is:
--
--     squadmates      keep a plate, deliberately through walls
--     everyone else   no plate at all
--     someone you
--     have just hit   a bare HP/shield readout over the body, briefly
--
-- ---------------------------------------------------------------------------
-- WHY THE ENEMY READOUT IS GATED ON DAMAGE AND NOT ON AIM.
--
-- The obvious reading of the request -- "like the NPCs" -- is vanilla's
-- behaviour: aim at somebody, see their health. Vanilla can do that because the
-- engine's targeting ray is LOS-tested. We cannot reach it from here:
-- `gametargetingTargetingSystem::GetLookAtObject` is wrapped by
-- `Api::Inspector`, and the only thing it hands Lua is an ENGINE entity id
-- (`Open77.inspector.target().engineId`). There is no engine-entity-to-player
-- mapping in the client Lua API, so an aim gate would need a C++ change.
--
-- The cheap substitute -- "is the projected plate near the middle of the
-- screen" -- is worse than useless. It is aim-shaped but not occlusion-tested,
-- so sweeping the crosshair across a building would still read the health of
-- everyone inside it. That is the same wallhack with a smaller cone.
--
-- Damage is the gate that leaks nothing at all. If you have just hit somebody
-- you already know exactly where they are; the readout tells you only how much
-- of them is left, which is what the hitmarker was already implying. It is also
-- what the genre does. The window is short and refreshed by each hit, so it
-- cannot be used to TRACK a target who breaks contact -- see `enemyVitalsSeconds`.
--
-- ---------------------------------------------------------------------------
-- WHAT THE CLIENT ALREADY KNOWS, AND WHY THIS IS NOT A SECRECY FEATURE.
--
-- Every client is already told every other player's exact health.
-- `SessionManager.AuthenticateAndWelcome` seeds a joining player with
-- `SendHealthStateAction` for every existing player in the bucket ("A joining
-- player is given the whole bucket regardless of distance"), and
-- `ServerApplication` then broadcasts `SendHealthState(-1, ...)` on every
-- change. `CombatReplication` keeps the lot in `s_healthStates`, and this file
-- reads it back through `Open77.players.allHealthStates()`.
--
-- So a modified client can already draw a perfect health bar on everyone, with
-- or without this file. NOTHING here is an anti-cheat measure. What it changes
-- is the HONEST player's screen: today the platform hands him a through-wall
-- position marker whether he wants one or not, and after this it does not.
-- Making enemy health genuinely secret would be a server change (health states
-- culled to the interest set), not a client one.
--
-- ---------------------------------------------------------------------------
-- WHY THE NAMEPLATE API AND NOT open77_worldui / open77_markers.
--
-- Both of those anchor to a WORLD POINT, so following a running player means
-- pushing a new position from Lua every frame -- precisely the path
-- `Api::Nameplates` was rewritten to escape (the 418 px lag measured in
-- client/src/webui/WorldOverlay.hpp). A nameplate override anchors to the
-- player's HEAD and is re-projected natively in the frame that presents it.
--
-- The cost of this file is therefore one `Open77.nameplates.set` per player
-- PER CHANGE, not per frame. In a steady state -- nobody shooting, nobody
-- joining -- the loop below calls nothing at all. The drawing stays where it
-- already was: native, in the present hook, with no CEF surface. That matters
-- at 64: docs/research/battle-royale-and-scale.md, 2026-09-02, records two
-- clients falling to 0.2 Hz and then vanishing under three full-screen HUD
-- surfaces each. This adds none.
-- ---------------------------------------------------------------------------

local RESOURCE = "open77_nameplates"

-- The native default, so "no override" and "an override that looks like the
-- default" are visibly the same thing.
local OPEN_COLOR = "#EAFBFF"
-- Squad cyan, amber for a body worth walking to, red for someone bleeding.
local FRIEND_COLOR = "#5AD1FF"
local DOWNED_COLOR = "#FFB020"
local ENEMY_COLOR = "#FF5A4A"

-- What a server that never answers gets: today's behaviour, exactly.
local DEFAULTS = {
    policy = "auto",
    friendlyPlates = true,
    friendlyDistance = 200,
    friendlyVitals = true,
    enemyVitals = "engaged",
    enemyVitalsSeconds = 2.5,
    enemyVitalsDistance = 120,
}

local config = {}
for key, value in pairs(DEFAULTS) do config[key] = value end

-- `competitive` latches. Once a gamemode on this server has identified itself
-- as competitive, it stays competitive for the session even if its state push
-- stops, because the failure direction matters: losing squad plates is an
-- annoyance, silently restoring a through-wall plate on every enemy because a
-- mode hiccuped is the bug this file exists to prevent. Only an explicit signal
-- -- a lobby phase, leaving an instance, `setPolicy("open")` -- widens it again.
local competitive = false
local inFight = false
local friends = {}        -- [playerId] = { name = , alive = , downed = }
local applied = {}        -- [playerId] = signature of the override we last set
local engagedUntil = {}   -- [playerId] = monotonic seconds
local lastRevision = {}   -- [playerId] = health revision last seen
local primed = false      -- first pass seeds revisions without opening windows
local selfId = 0
local running = true
local complained = false

local function available()
    return type(Open77) == "table"
        and type(Open77.nameplates) == "table"
        and type(Open77.nameplates.set) == "function"
        and type(Open77.nameplates.remove) == "function"
        and type(Open77.players) == "table"
        and type(Open77.players.allHealthStates) == "function"
        and type(Open77.players.getHealthState) == "function"
        and type(Open77.time) == "table"
        and type(Open77.time.monotonic) == "function"
end

-- Seconds, monotonic, as a double. There is deliberately no `os.clock`
-- fallback: the sandboxed client Lua does not publish `os`, so a fallback would
-- turn a missing clock into a nil-index error instead of the clean "this client
-- is too old" path `available()` already gives.
local function now()
    return Open77.time.monotonic()
end

local function id(value)
    local number = tonumber(value)
    if number == nil then return nil end
    number = math.floor(number)
    if number <= 0 then return nil end
    return number
end

local function clampNumber(value, low, high, fallback)
    local number = tonumber(value)
    if number == nil then return fallback end
    if number < low then return low end
    if number > high then return high end
    return number
end

-- ---------------------------------------------------------------------------
-- CONFIGURATION, as pushed by server/main.lua from its declared tunables.
-- Every field is clamped HERE as well as there: a client must not be able to
-- refuse a plate because a server sent it a maxDistance of 400, which
-- `Api::Nameplates::Set` rejects outright (1..250).
-- ---------------------------------------------------------------------------
local function applyConfig(payload)
    if type(payload) ~= "table" then return end
    local policy = tostring(payload.policy or config.policy)
    if policy ~= "auto" and policy ~= "open" and policy ~= "competitive" then
        policy = DEFAULTS.policy
    end
    config.policy = policy
    config.friendlyPlates = payload.friendlyPlates ~= false
    config.friendlyVitals = payload.friendlyVitals ~= false
    config.friendlyDistance =
        math.floor(clampNumber(payload.friendlyDistance, 5, 250, DEFAULTS.friendlyDistance))
    local enemyVitals = tostring(payload.enemyVitals or config.enemyVitals)
    -- Deliberately only two choices. "Anyone in view" is not offered because it
    -- is the wallhack this file removes, wearing a different hat: a health bar
    -- drawn through a wall gives away the position just as completely as a name
    -- drawn through the same wall. A configuration that cannot express the
    -- unsafe option cannot be misconfigured into it.
    if enemyVitals ~= "off" and enemyVitals ~= "engaged" then
        enemyVitals = DEFAULTS.enemyVitals
    end
    config.enemyVitals = enemyVitals
    config.enemyVitalsSeconds =
        clampNumber(payload.enemyVitalsSeconds, 0.5, 10.0, DEFAULTS.enemyVitalsSeconds)
    config.enemyVitalsDistance =
        math.floor(clampNumber(payload.enemyVitalsDistance, 5, 250, DEFAULTS.enemyVitalsDistance))
end

-- ---------------------------------------------------------------------------
-- OVERRIDES. One `set` per player per CHANGE, never per frame: the signature
-- below is what makes a settled match cost nothing.
-- ---------------------------------------------------------------------------
local function signatureOf(options)
    if options == nil then return "-" end
    return table.concat({
        options.label, options.color, tostring(options.maxDistance),
        options.visible and "1" or "0", options.showDistance and "1" or "0",
    }, "\1")
end

local function apply(playerId, options)
    local signature = signatureOf(options)
    if applied[playerId] == signature then return end
    local ok, reason
    if options == nil then
        ok, reason = Open77.nameplates.remove(playerId)
    else
        ok, reason = Open77.nameplates.set(playerId, options)
    end
    if not ok then
        -- Once, not per tick: a refused override repeats every 250 ms and would
        -- otherwise be the loudest thing in the log.
        if not complained then
            complained = true
            print(("[%s] override for %d refused: %s")
                :format(RESOURCE, playerId, tostring(reason)))
        end
        return
    end
    applied[playerId] = signature
end

--- Drop every override this resource holds, one at a time.
---
--- NOT `Open77.nameplates.clear()`. That is `Api::Nameplates::Release`, which
--- also calls `StopStream` and `Render(owner, false)` for the same owner -- and
--- the owner is this very resource, so clearing the overrides would switch the
--- native drawer OFF and leave the world with no plates at all.
local function restore()
    for playerId in pairs(applied) do
        pcall(Open77.nameplates.remove, playerId)
    end
    applied = {}
end

-- ---------------------------------------------------------------------------
-- LABELS. Latin-1 only, one line, at most 96 bytes.
--
-- `WorldOverlay` bakes its atlas with `GetGlyphRangesDefault()` (U+0020-U+00FF)
-- so a block-drawing bar would render as the fallback glyph, and
-- `Api::Nameplates::Set` REFUSES any label containing a byte below 0x20, so a
-- two-line plate is not a layout choice -- it is an `invalid_argument`.
-- Numbers it is.
-- ---------------------------------------------------------------------------
local function vitalsText(state)
    if type(state) ~= "table" then return nil end
    local health = math.floor((tonumber(state.health) or 0) + 0.5)
    if health < 0 then health = 0 end
    local armor = math.floor((tonumber(state.armor) or 0) + 0.5)
    if armor > 0 then
        return ("%d +%d"):format(health, armor)
    end
    return tostring(health)
end

local function safeName(name)
    local text = tostring(name or "")
    text = text:gsub("%c", " ")
    if #text > 32 then text = text:sub(1, 32) end
    if #text == 0 then text = "?" end
    return text
end

-- ---------------------------------------------------------------------------
-- THE PASS.
-- ---------------------------------------------------------------------------
local function healthByPlayer()
    local ok, list = pcall(Open77.players.allHealthStates)
    if not ok or type(list) ~= "table" then return nil end
    local map = {}
    for _, entry in ipairs(list) do
        local playerId = type(entry) == "table" and id(entry.playerId) or nil
        if playerId ~= nil then map[playerId] = entry end
    end
    return map
end

local function resolveSelf(states)
    if selfId ~= 0 and states[selfId] ~= nil then return end
    local ok, mine = pcall(Open77.players.getHealthState)
    if ok and type(mine) == "table" then
        selfId = id(mine.playerId) or 0
    end
end

local HIDDEN = {
    label = "", color = OPEN_COLOR, maxDistance = 250,
    visible = false, showDistance = false,
}

local function friendlyOverride(playerId, entry, states)
    -- HIDDEN, not nil. `nil` means "hold no override", which hands the player
    -- back to the native default -- their NAME, through walls, at 35 m. An
    -- operator turning squad plates off in a competitive mode is asking for
    -- fewer plates, not for the platform default to come back on his own squad.
    if not config.friendlyPlates then return HIDDEN end
    if entry.downed == true then
        return {
            label = safeName(entry.name) .. "  DOWN",
            color = DOWNED_COLOR, maxDistance = config.friendlyDistance,
            visible = true, showDistance = true,
        }
    end
    -- A squadmate who is dead and past their revive window is not somewhere you
    -- need to go; the mode's own panel still lists them.
    if entry.alive == false then return HIDDEN end
    local label = safeName(entry.name)
    if config.friendlyVitals then
        local text = vitalsText(states[playerId])
        if text ~= nil then label = label .. "  " .. text end
    end
    return {
        label = label, color = FRIEND_COLOR, maxDistance = config.friendlyDistance,
        visible = true, showDistance = true,
    }
end

local function enemyOverride(playerId, states, nowSeconds)
    if config.enemyVitals ~= "engaged" then return HIDDEN end
    local until_ = engagedUntil[playerId]
    if until_ == nil or nowSeconds > until_ then return HIDDEN end
    local text = vitalsText(states[playerId])
    if text == nil then return HIDDEN end
    return {
        -- NO NAME. The identity is the half that was removed; what is left is
        -- the readout, which is why an enemy plate does not look like a
        -- nameplate with extra text on it. The distance line is off for the
        -- same reason: a metre count is a range-finder.
        label = text, color = ENEMY_COLOR,
        -- The distance gate is the NATIVE one. `Api::Nameplates::Snapshot`
        -- culls on `maximumDistance` before projecting, so setting it here is
        -- both the gate and its enforcement -- and it is why this file never
        -- needs a position or a distance from Lua at all.
        maxDistance = config.enemyVitalsDistance,
        visible = true, showDistance = false,
    }
end

local function pass()
    local states = healthByPlayer()
    if states == nil then return end
    resolveSelf(states)
    local nowSeconds = now()
    local window = config.enemyVitalsSeconds

    -- ENGAGEMENT. `PlayerHealthState.LastAttackerId` is documented as zero when
    -- the latest change was not damage (heal, resync, respawn), so
    -- "lastAttacker is me AND the revision moved" is exactly "I just hit them".
    -- The first pass seeds revisions without opening a window, otherwise a hot
    -- reload in the middle of a fight would resurrect a stale attribution.
    for playerId, state in pairs(states) do
        local revision = tonumber(state.revision) or 0
        if primed and playerId ~= selfId and selfId ~= 0
            and revision ~= lastRevision[playerId]
            and id(state.lastAttacker) == selfId then
            engagedUntil[playerId] = nowSeconds + window
        end
        lastRevision[playerId] = revision
    end
    primed = true

    -- The union of everyone we know about and everyone we have already touched,
    -- so a player who leaves the roster has their override withdrawn instead of
    -- being hidden forever on a recycled id.
    local seen = {}
    for playerId in pairs(states) do seen[playerId] = true end
    for playerId in pairs(friends) do seen[playerId] = true end
    local stale = {}
    for playerId in pairs(applied) do
        if not seen[playerId] then stale[#stale + 1] = playerId end
    end

    for playerId in pairs(seen) do
        if playerId ~= selfId then
            local friend = friends[playerId]
            local options
            if friend ~= nil then
                options = friendlyOverride(playerId, friend, states)
            else
                options = enemyOverride(playerId, states, nowSeconds)
            end
            apply(playerId, options)
        end
    end
    for _, playerId in ipairs(stale) do
        apply(playerId, nil)
        applied[playerId] = nil
        engagedUntil[playerId] = nil
        lastRevision[playerId] = nil
    end
end

-- ---------------------------------------------------------------------------
-- THE LOOP. 4 Hz while a fight is on, 1 Hz while it is not, and on a server
-- with no competitive mode it wakes once a second, finds nothing to do and
-- sleeps again. Nothing here is per-frame; the DRAWING is per-frame and it is
-- native (see the header).
-- ---------------------------------------------------------------------------
CreateThread(function()
    while running do
        if competitive and inFight then
            local ok, err = pcall(pass)
            if not ok and not complained then
                complained = true
                print(("[%s] policy pass failed: %s"):format(RESOURCE, tostring(err)))
            end
            Wait(250)
        else
            if next(applied) ~= nil then pcall(restore) end
            Wait(1000)
        end
    end
end)

-- ---------------------------------------------------------------------------
-- THE CONTRACT. A gamemode's CLIENT drives this directly; the two adapters
-- below are shipped defaults for the two modes that exist, not the mechanism.
--
-- `pursuit` already reaches for `setEnabled` through `callExport`, so this is
-- the same shape it already knows.
-- ---------------------------------------------------------------------------
local function setFriends(list)
    local next_ = {}
    if type(list) == "table" then
        for key, value in pairs(list) do
            -- Accepts both { 4, 7, 9 } and { [4] = { name = "Vik" }, ... }.
            local playerId, entry
            if type(value) == "table" then
                playerId = id(value.playerId) or id(key)
                entry = value
            else
                playerId = id(value) or id(key)
                entry = { name = tostring(value) }
            end
            if playerId ~= nil and playerId ~= selfId then
                next_[playerId] = {
                    name = entry.name,
                    alive = entry.alive,
                    downed = entry.downed,
                }
            end
        end
    end
    friends = next_
end

exports("setPolicy", function(policy)
    policy = tostring(policy or "auto")
    if policy ~= "auto" and policy ~= "open" and policy ~= "competitive" then
        return false, "invalid_policy"
    end
    config.policy = policy
    if policy == "open" then
        competitive, inFight = false, false
    elseif policy == "competitive" then
        competitive, inFight = true, true
    end
    return true
end)

--- Declare the set of players who may keep a plate, and put the client in the
--- competitive shape. `inFight` false restores open plates without forgetting
--- that this server is competitive -- that is the lobby.
exports("setFriendlies", function(list, options)
    if config.policy == "open" then return false, "policy_open" end
    setFriends(list)
    competitive = true
    if type(options) == "table" and options.inFight ~= nil then
        inFight = options.inFight ~= false
    else
        inFight = true
    end
    return true
end)

--- Introspection, for a console command or a test. Counts and a COPY of the
--- configuration -- handing out `applied` or `config` by reference would let a
--- caller edit this resource's state through a getter.
exports("policy", function()
    local friendCount, overrideCount = 0, 0
    for _ in pairs(friends) do friendCount = friendCount + 1 end
    for _ in pairs(applied) do overrideCount = overrideCount + 1 end
    local snapshot = {}
    for key, value in pairs(config) do snapshot[key] = value end
    return {
        policy = config.policy,
        competitive = competitive,
        inFight = inFight,
        friendlies = friendCount,
        overrides = overrideCount,
        config = snapshot,
    }
end)

-- ---------------------------------------------------------------------------
-- SHIPPED ADAPTERS.
--
-- Neither Cordon nor the deathmatch is edited by this resource, and neither had
-- to be: `ResourceHost::Tick` fans a network event to EVERY running resource
-- holding `network.events` that registered a handler for that name (the loop
-- around `DispatchNetworkToInstance`). So the state push each mode already
-- sends to its own HUD arrives here as well, and the squad/team it already
-- computed is reused rather than re-invented.
--
-- The cost is one extra handler per push, at the mode's own rate (~2 Hz), on a
-- payload that was going to be decoded anyway.
-- ---------------------------------------------------------------------------

--- CORDON. `server/main.lua` -> `stateFor` -> `TriggerClientEvent("cordon:state")`.
--- `squad.members` is built from `record.squad`, so a player never receives a
--- member list for anyone outside their own squad -- the boundary this needs is
--- already enforced on the server.
---
--- Plates stay OPEN in staging and once the match resolves, and close for the
--- three phases where the map is contested. That is pursuit's rule (lobby yes,
--- match no) applied to Cordon's phase machine (server/match.lua).
RegisterNetEvent("cordon:state", function(state)
    if config.policy == "open" or type(state) ~= "table" then return end
    competitive = true
    local phase = tostring(state.phase or "")
    local wasFighting = inFight
    local mine = type(state.self) == "table" and state.self or {}
    if id(mine.playerId) ~= nil then selfId = id(mine.playerId) end
    if mine.inLobby == true or phase == "staging" or phase == "resolved" then
        inFight = false
    elseif phase == "deploy" or phase == "live" or phase == "extraction" then
        inFight = true
    end -- Unknown/missing phase must not widen an existing combat policy.
    if wasFighting and not inFight then
        pcall(restore)
        engagedUntil, lastRevision, primed = {}, {}, false
    end
    local squad = type(state.squad) == "table" and state.squad or nil
    local members = squad ~= nil and type(squad.members) == "table" and squad.members or {}
    local next_ = {}
    for _, member in ipairs(members) do
        local playerId = type(member) == "table" and id(member.playerId) or nil
        -- Bots are NPCs, not replicated players: they never had a plate and
        -- cannot be given one. Skipping them keeps the roster honest.
        if playerId ~= nil and playerId ~= selfId and member.bot ~= true then
            next_[playerId] = {
                name = member.name, alive = member.alive, downed = member.downed,
            }
        end
    end
    friends = next_
    if inFight and not wasFighting then pcall(pass) end
end)

--- DEATHMATCH. `server/main.lua` -> `stateFor` -> `TriggerClientEvent("deathmatch:state")`.
---
--- The team model is `server/round.lua`: `DM.setTeam(id, 0)` for free-for-all
--- and `DM.setTeam(id, side)` for the queued 1v1/2v2/3v3, and the scoreboard
--- row carries that number. So `team > 0 and team == mine` is the whole rule,
--- and FREE-FOR-ALL FALLS OUT OF IT: every row is team 0, no row matches, and
--- nobody in a free-for-all has a plate. That is the owner's "aussi dans le
--- mode ffa pvp", derived from the mode's own notion of a side rather than
--- from a second one invented here.
---
--- `participant` is membership of an instance, so the lobby keeps its plates:
--- seeing who you are queueing against is the point of standing in a lobby.
RegisterNetEvent("deathmatch:state", function(state)
    if config.policy == "open" or type(state) ~= "table" then return end
    competitive = true
    inFight = state.participant == true
    local mine = type(state.self) == "table" and math.floor(tonumber(state.self.team) or 0) or 0
    if id(state.playerId) ~= nil then selfId = id(state.playerId) end
    local next_ = {}
    if mine > 0 and type(state.rows) == "table" then
        for _, row in ipairs(state.rows) do
            local playerId = type(row) == "table" and id(row.id) or nil
            local team = type(row) == "table" and math.floor(tonumber(row.team) or 0) or 0
            if playerId ~= nil and playerId ~= selfId and row.bot ~= true and team == mine then
                next_[playerId] = { name = row.name, alive = true }
            end
        end
    end
    friends = next_
end)

-- ---------------------------------------------------------------------------
-- LIFECYCLE.
-- ---------------------------------------------------------------------------

--- Ask the server for its policy. The perspective service uses the same shape
--- (`open77:perspective:ready`): the client announces itself and a server that
--- has nothing to say stays silent, so a server without this resource's server
--- half simply leaves the defaults in place.
local function announce()
    pcall(TriggerServerEvent, "open77:nameplates:ready")
end

RegisterNetEvent("open77:nameplates:policy", function(payload)
    applyConfig(payload)
    if config.policy == "open" then
        competitive, inFight = false, false
        -- Withdraw the overrides HERE rather than leaving it to the loop. The
        -- loop's idle branch calls `restore` only while `applied` is non-empty,
        -- so emptying the cache first would strand every override that is
        -- already set and the plates would never come back.
        pcall(restore)
        return
    end
    if config.policy == "competitive" then
        competitive, inFight = true, true
    end
    -- A live retune must reach the plates that are already drawn, and the
    -- signature cache would otherwise swallow it: the desired override changed
    -- because the CONFIG changed, not because the player did. A sentinel rather
    -- than an empty table, so the keys survive and a player who has since left
    -- is still recognised as stale on the next pass.
    for playerId in pairs(applied) do applied[playerId] = "!" end
end)

AddEventHandler("onClientResourceStart", function(name)
    if name ~= GetCurrentResourceName() then return end
    if not available() then
        print(("[%s] policy inactive: this client has no nameplate or health API")
            :format(RESOURCE))
        running = false
        return
    end
    announce()
end)

-- A world transition invalidates every id and every attribution.
--
-- `Api::Nameplates::OnRunningExit` clears the streams, the render set and the
-- talking assertions but NOT `s_overrides`, so an override taken out in the
-- previous world is still in the map when the next one comes up. Withdraw them
-- before forgetting which ones we hold.
AddEventHandler("open77:worldReady", function()
    pcall(restore)
    friends, engagedUntil, lastRevision = {}, {}, {}
    primed, selfId = false, 0
    announce()
end)

AddEventHandler("onClientResourceStop", function(name)
    if name ~= GetCurrentResourceName() then return end
    running = false
    -- Leave the world as we found it. The host would release the overrides with
    -- the resource anyway; doing it here is what keeps a RELOAD from leaving one
    -- frame of stale plates between the two generations.
    pcall(restore)
end)
