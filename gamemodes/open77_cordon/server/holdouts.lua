-- ============================================================================
-- GANG HOLDOUTS -- the PvE that guards the good loot.
--
-- The map format has stored holdout marks since the survey and the editor has
-- edited them since Phase 2, but nothing ever consumed them: `editor.lua` says
-- so in its own field table (`liveNote = "no holdout spawner exists yet"`), and
-- the `holdoutsEnabled` tunable was audited on 2026-09-03 as NOT IMPLEMENTED and
-- defaulted off so the Warden panel would stop advertising six gang camps that
-- never appeared. This file is that spawner.
--
-- WHERE THEY STAND, and why it is not the `holdouts` array. The design note left
-- on the tunable reads "six sites of four NPCs ON THE HIGH-TIER MARKS", which is
-- the useful reading: a holdout is not a place of its own, it is the thing
-- standing on top of loot worth walking to. Watson's nine surveyed clusters
-- carry tiers 1-4, so tier >= `holdoutMinTier` selects the two tier-3 marks and
-- the single tier-4 one, and no new survey is needed to stand a camp up. A map
-- whose `holdouts` array is authored separately is still free to grow its own
-- placement later; this reads the marks that exist today.
--
-- WHY IT IS OFF BY DEFAULT AND STAYS OFF. Turning tier-4 loot into a fight
-- changes the shape of a match, and that is the owner's call, not this file's.
-- `holdoutsEnabled` keeps its `false`, so a server that never touches the panel
-- behaves exactly as it did before this file existed.
--
-- WHAT MAKES THEM FIGHT. `Open77.npcs.ai.native` runs the record's engine combat
-- AI. The shared camp group keeps guards friendly to each other; the explicit
-- player-hostility policy makes players targets. Actual impacts are reported
-- by the NPC's authority owner and priced by the mode. This file spawns the
-- guards and declares that policy; it does not manufacture shots.
-- ============================================================================

local K = Cordon
local H = {}
K.holdouts = H

-- These records carry their own equipment. Combat metadata below carries no
-- weapon field, so the native client does not enter player-proxy equipment code.
local GANG = "gang_valentinos_ranged_01"

-- [index] = { key, tier, position, ids = {npcId,...}, cleared = bool }
local sites = {}
local armed = false

function H.get(npcId)
    for _, site in ipairs(sites) do
        for _, id in ipairs(site.ids) do
            if tostring(id) == tostring(npcId) then return site end
        end
    end
end

local function number(value, fallback)
    local n = tonumber(value)
    if n == nil then return fallback end
    return n
end

local function enabled()
    return K.tune("holdoutsEnabled", false) == true
end

--- The marks a camp may stand on: surveyed clusters at or above the tier gate,
--- richest first, capped. Sorting by tier descending means a map with more marks
--- than `holdoutSites` guards its BEST loot rather than its first-authored loot.
local function marks()
    local map = K.map
    local clusters = (type(map) == "table" and map.lootClusters) or {}
    local minTier = math.floor(number(K.tune("holdoutMinTier", 3), 3))
    local wanted = math.floor(number(K.tune("holdoutSites", 6), 6))
    local picked = {}
    for _, cluster in ipairs(clusters) do
        if cluster.position ~= nil and math.floor(number(cluster.tier, 1)) >= minTier then
            picked[#picked + 1] = cluster
        end
    end
    table.sort(picked, function(a, b)
        local ta, tb = number(a.tier, 1), number(b.tier, 1)
        if ta ~= tb then return ta > tb end
        return tostring(a.key) < tostring(b.key)
    end)
    while #picked > math.max(0, wanted) do table.remove(picked) end
    return picked
end

--- Remove every NPC this file created. Called before every arm as well as at
--- staging, so a hot reload or a double `live` cannot leave a camp standing in
--- an empty district -- the same belt-and-braces `editor.lua` uses for cars.
function H.clear()
    local removed = 0
    for _, site in ipairs(sites) do
        for _, id in ipairs(site.ids) do
            local ok, result = pcall(Open77.npcs.remove, id)
            if ok and result then removed = removed + 1 end
        end
    end
    sites = {}
    armed = false
    return removed
end

function H.arm()
    H.clear()
    if not enabled() then return end
    if type(Open77.npcs) ~= "table" or type(Open77.npcs.create) ~= "function" then
        return K.warn("holdouts: this server exposes no NPC binding; marks are stored but no camp is spawned")
    end

    local picked = marks()
    if #picked == 0 then
        return K.log("holdouts: enabled, but the map has no surveyed cluster at or above the tier gate -- no camp spawned")
    end

    local size = math.max(1, math.floor(number(K.tune("holdoutSize", 4), 4)))
    local bucket = K.matchBucket()
    local made, failed, vanished = 0, 0, 0

    for index, cluster in ipairs(picked) do
        local site = { key = tostring(cluster.key), tier = number(cluster.tier, 1),
                       position = cluster.position, ids = {}, cleared = false }
        for seat = 1, size do
            -- A ring rather than a stack: spawning four records on one point
            -- lets the engine resolve the overlap by shoving them, and a shoved
            -- NPC walks out of its camp before the first player arrives.
            local angle = (2 * math.pi) * ((seat - 1) / size)
            local radius = 3.5
            local ok, id = pcall(Open77.npcs.create, {
                template = GANG,
                position = {
                    x = cluster.position.x + math.cos(angle) * radius,
                    y = cluster.position.y + math.sin(angle) * radius,
                    z = cluster.position.z,
                },
                yaw = math.random() * 360.0,
                bucket = bucket,
                -- Mirrors server/bots.lua, whose contestants demonstrably fight.
                -- `streamingRadius` is the one that matters: combat AI runs on
                -- the CLIENTS that stream the body in, so a camp nobody streams
                -- is a camp that never shoots.
                health = 100.0, maxHealth = 100.0,
                streamingRadius = 180.0, streamingHysteresis = 40.0,
                persistent = false,
                aiMode = Open77.npcs.ai.native,
                loadout = { combat = { group = "cordon_holdouts", acquirePlayers = true, authoritativePlayerHits = true } },
                -- MORTAL, unlike the reference resource's immortal demo NPC.
                -- A holdout that cannot be cleared is a wall, and the phase gate
                -- is "a real player clears one".
                damagePolicy = Open77.npcs.damage.mortal,
                -- Priced by server/npc-combat.lua (`cordon:npcHit`), never by the platform.
                behavior = { hitPricing = "resource" },
            })
            if ok and id ~= nil then
                site.ids[#site.ids + 1] = id
                made = made + 1
                -- VERIFY, do not trust the id. A create that returns an id and
                -- a body that exists a tick later are different claims, and the
                -- counter is cheap.
                --
                -- It also settles a false alarm worth remembering: the first
                -- camp this file spawned logged "12 spawned, 0 refused" while
                -- `npc.list` reported none, which read as twelve bodies being
                -- culled. They were never missing. `Open77.npcs.all()` is
                -- OWNERSHIP-SCOPED -- the binding filters on `Owns(npc,
                -- resource)` (NpcAuthorityService.cs:196, and bots.lua's
                -- clearing note says so) -- and `npc.list` lives in
                -- open77_npcs, so it can only ever see that resource's NPCs.
                -- These belong to open77_cordon and are invisible to it by
                -- design. Diagnose a camp from THIS log line, never from
                -- `npc.list`.
                local got, record = pcall(Open77.npcs.get, id)
                if not got or record == nil then vanished = vanished + 1 end
            else
                failed = failed + 1
            end
        end
        if #site.ids > 0 then sites[#sites + 1] = site end
    end

    armed = #sites > 0
    K.log(("holdouts: armed %d site(s), %d NPC(s) spawned, %d refused, %d vanished on the same tick (tier>=%d, size=%d)"):format(
        #sites, made, failed, vanished, math.floor(number(K.tune("holdoutMinTier", 3), 3)), size))
end

--- Poll this resource's canonical NPC health and retire camps in closed cells.
function H.tick()
    if not armed then return end
    if not enabled() then H.clear() return end
    local live = {}
    local ok, values = pcall(Open77.npcs.all, K.matchBucket())
    if not ok or type(values) ~= "table" then return end
    for _, npc in ipairs(values) do
        if number(npc.health, 0) > 0 then live[tostring(npc.id)] = true end
    end
    for _, site in ipairs(sites) do
        if not site.cleared and not site.closed then
            local state = K.cordon.state()
            local lattice = state and state.active and state.lattice
            local col, row
            if lattice then col, row = Grid.cellOf(lattice, site.position.x, site.position.y) end
            if lattice and (col == nil or state.open[Grid.key(col, row)] ~= true) then
                local removed = true
                for _, id in ipairs(site.ids) do
                    if live[tostring(id)] and not Open77.npcs.remove(id) then removed = false end
                end
                if removed then
                    site.closed = true
                    K.log("holdouts: site " .. site.key .. " removed by cordon")
                end
            end
            local standing = 0
            for _, id in ipairs(site.ids) do
                if live[tostring(id)] then standing = standing + 1 end
            end
            if standing == 0 and not site.closed then
                site.cleared = true
                K.log(("holdouts: site %s (tier %d) CLEARED -- %d body/bodies, the cache is open"):format(
                    site.key, site.tier, #site.ids))
            end
        end
    end
end

--- What `/br.status` and the tests read.
function H.state()
    local total, cleared = #sites, 0
    for _, site in ipairs(sites) do if site.cleared then cleared = cleared + 1 end end
    return { armed = armed, sites = total, cleared = cleared, enabled = enabled() }
end

AddEventHandler("cordon:phase", function(target)
    if target == "live" then
        local ok, err = pcall(H.arm)
        if not ok then K.warn("holdouts: arm failed -- " .. tostring(err)) end
    elseif target == "staging" then
        pcall(H.clear)
    end
end)

-- Its own thread, at a deliberately lazy 2 s: a camp being cleared is a thing
-- that happens over seconds of shooting, not between frames, and the roster read
-- is the whole cost. Everything inside is pcall'd because an error raised in a
-- CreateThread body kills that thread permanently and silently -- the failure
-- mode documented on the match tick, which cost a match frozen in `deploy`.
CreateThread(function()
    while true do
        Wait(2000)
        local ok, err = pcall(H.tick)
        if not ok then K.warn("holdouts: tick failed: " .. tostring(err)) end
    end
end)
