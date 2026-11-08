Open77PedestrianScheduler = {}
Open77PedestrianScheduler.__index = Open77PedestrianScheduler

-- Catalogue rows are positional (build_spot_catalog.py, schema 2): an entry is { record, appearance
-- pool, body bits, periods }, a period { start minute, quantity, sequence, spot indices }.
local E_RECORD, E_POOL, E_BODY, E_PERIODS = 1, 2, 3, 4
local P_START, P_QUANTITY, P_SPOTS = 1, 2, 4

-- The active period of entry `e` at `minute`, as an index into the flat period columns built by `index`.
local function activePeriod(self, e, minute)
    local first, starts = self.entryPeriodFirst[e], self.periodStart
    local selected, chosen
    for p = first, first + self.entryPeriodCount[e] - 1 do
        local start = starts[p]
        if not selected or (start <= minute and (chosen > minute or start > chosen)) or
                (chosen > minute and start > chosen) then
            selected, chosen = p, start
        end
    end
    return selected
end

-- The player grid and the queries over it are shared with the walking crowd (spatial.lua).
local S = Open77PedestrianSpatial
local CELL, cellOf, cellKey, addPlayer, query, offer, countGroups, playersNear =
    S.CELL, S.cellOf, S.cellKey, S.addPlayer, S.query, S.offer, S.countGroups, S.candidates

-- Cheap: the spot and entry indices are built by `index`, in slices, on the scheduler's own thread.
-- The spot columns are the catalogue's own tables, read in place.
function Open77PedestrianScheduler.new(catalog, config, api)
    return setmetatable({
        catalog = catalog, config = config, api = api, enabled = config.enabled,
        spotX = catalog.spotX, spotY = catalog.spotY, spotZ = catalog.spotZ, spotYaw = catalog.spotYaw,
        spotProfile = catalog.spotProfile, entries = catalog.entries, entryTotal = #(catalog.entries or {}),
        spotEnabled = {}, grid = {}, clips = {}, bodyClips = {},
        occupants = {}, byNpc = {}, cooldown = {}, failures = {}, spawns = 0, spotPlace = {}, cellZ = {},
        inRangeAt = {}, reservedAt = {}, scanStamp = 0,
        disabledSpots = 0, panicChoices = {}, entryCount = {}, indexed = false, contended = false,
    }, Open77PedestrianScheduler)
end

-- The catalogue holds ~40 k spots: one pass over it exceeds a resource's per-call instruction
-- quota, so `api.yield` (a Wait on the scheduler thread) hands the rest of the pass to the next
-- server tick every few thousand rows.
function Open77PedestrianScheduler:index()
    local catalog, api, steps = self.catalog, self.api, 0
    local function step()
        steps = steps + 1
        if api.yield and steps % 2000 == 0 then api.yield() end
    end
    local perProfile, profiles, enabled = {}, self.spotProfile, {}
    for index = 1, #profiles do
        perProfile[profiles[index]] = (perProfile[profiles[index]] or 0) + 1
        step()
    end
    for index, profile in ipairs(catalog.profiles) do
        local clips = api.clips(profile)
        self.clips[index] = clips
        enabled[index] = clips ~= nil and #clips > 0
        if not enabled[index] then
            self.disabledSpots = self.disabledSpots + (perProfile[index] or 0)
            api.log("pedestrians: profile %s has no clips; %d spots disabled", profile, perProfile[index] or 0)
        end
        step()
    end
    for _, profile in ipairs(self.config.panicProfiles or {}) do
        local clips = api.clips(profile)
        if clips and #clips > 0 then
            self.panicChoices[#self.panicChoices + 1] = { profile = profile, clips = clips }
        else
            api.log("pedestrians: panic profile %s has no clips", profile)
        end
    end
    -- Per cell, its spots and the height they span (the scan passes whole cells a player covers).
    local xs, ys, zs = self.spotX, self.spotY, self.spotZ
    for index = 1, #xs do
        self.spotEnabled[index] = enabled[profiles[index]] == true
        local key = cellKey(cellOf(xs[index]), cellOf(ys[index]))
        local cell = self.grid[key]
        if not cell then cell = {}; self.grid[key] = cell; self.cellZ[key] = { zs[index], zs[index] } end
        cell[#cell + 1] = index
        local span = self.cellZ[key]
        if zs[index] < span[1] then span[1] = zs[index] end
        if zs[index] > span[2] then span[2] = zs[index] end
        step()
    end
    -- The entries as flat columns: an entry's record, pool, body and its periods (first, count); a period's start,
    -- quantity and spots (first, count into periodSpots); a spot's distinct entries (first, count into spotEntries).
    -- The catalogue's rows are tables of tables, 67 k of them, that every major collection would walk again: once
    -- copied, main.lua lets them go.
    local eRecord, ePool, eBody, ePFirst, ePCount = {}, {}, {}, {}, {}
    local pStart, pQuantity, pSFirst, pSCount, pSpots = {}, {}, {}, {}, {}
    local perSpot, last = {}, {}
    local np, ns = 0, 0
    for e, entry in ipairs(self.entries) do
        eRecord[e], ePool[e], eBody[e], ePFirst[e] = entry[E_RECORD], entry[E_POOL], entry[E_BODY], np + 1
        for _, period in ipairs(entry[E_PERIODS]) do
            np = np + 1
            local spots = period[P_SPOTS]
            pStart[np], pQuantity[np], pSFirst[np], pSCount[np] = period[P_START], period[P_QUANTITY], ns + 1, #spots
            for i = 1, #spots do
                local spotIndex = spots[i]
                ns = ns + 1
                pSpots[ns] = spotIndex
                if last[spotIndex] ~= e then last[spotIndex], perSpot[spotIndex] = e, (perSpot[spotIndex] or 0) + 1 end
                step()
            end
        end
        ePCount[e] = np - ePFirst[e] + 1
    end
    local seFirst, seCount, seList, fill = {}, {}, {}, 0
    for spotIndex = 1, #xs do
        local n = perSpot[spotIndex]
        if n then seFirst[spotIndex], seCount[spotIndex], fill = fill + 1, 0, fill + n end
        step()
    end
    last = {}
    for e = 1, #eRecord do
        for p = ePFirst[e], ePFirst[e] + ePCount[e] - 1 do
            for k = pSFirst[p], pSFirst[p] + pSCount[p] - 1 do
                local spotIndex = pSpots[k]
                if last[spotIndex] ~= e then
                    last[spotIndex] = e
                    seList[seFirst[spotIndex] + seCount[spotIndex]] = e
                    seCount[spotIndex] = seCount[spotIndex] + 1
                end
                step()
            end
        end
    end
    self.entryRecord, self.entryPool, self.entryBody = eRecord, ePool, eBody
    self.entryPeriodFirst, self.entryPeriodCount, self.entryTotal = ePFirst, ePCount, #eRecord
    self.periodStart, self.periodQuantity, self.periodSpotFirst, self.periodSpotCount, self.periodSpots =
        pStart, pQuantity, pSFirst, pSCount, pSpots
    self.spotEntryFirst, self.spotEntryCount, self.spotEntries = seFirst, seCount, seList
    self.entries = nil
    self.indexed = true
end

-- The key of a spot (or an entry) in a bucket, "bucket:index": the scan asks for thousands a pass, and
-- each new string was garbage the collector swept again. They are kept per bucket, and forgotten
-- all together past KEYS_KEPT.
local KEYS_KEPT = 120000
function Open77PedestrianScheduler:keyOf(bucket, index)
    local byBucket = self.keys
    if not byBucket or self.keyCount > KEYS_KEPT then
        byBucket = {}
        self.keys, self.keyCount = byBucket, 0
    end
    local keys = byBucket[bucket]
    if not keys then keys = {}; byBucket[bucket] = keys end
    local key = keys[index]
    if not key then
        key = bucket .. ":" .. index
        keys[index] = key
        self.keyCount = self.keyCount + 1
    end
    return key
end

-- The clips of a profile an NPC of `body` (its entry's body bits) plays; see Open77PedestrianSpatial.clipsFor.
function Open77PedestrianScheduler:clipsFor(profile, body)
    return S.clipsFor(self.bodyClips, self.catalog.clipBodies, profile, body, self.clips[profile])
end

-- Living occupants per bucket and entry: a panicked pedestrian comes back to its spot, so only
-- the dead free a place. Kept as a count because scanning every occupant for every nearby entry
-- each tick does not fit the instruction quota near a dense market.
function Open77PedestrianScheduler:count(occupant, delta)
    local key = occupant.bucket .. ":" .. occupant.entry
    self.entryCount[key] = (self.entryCount[key] or 0) + delta
end

function Open77PedestrianScheduler:drop(key, remove)
    local occupant = self.occupants[key]
    if not occupant then return end
    self.occupants[key] = nil
    self.byNpc[occupant.npc] = nil
    if occupant.state ~= "dead" then self:count(occupant, -1) end
    if remove then self.api.remove(occupant.npc) end
end

-- Where a pedestrian is now (x, y, z, yaw): its spot while seated, else the server's position of it.
function Open77PedestrianScheduler:whereabouts(occupant)
    if occupant.state ~= "seated" then
        local at = self.api.position(occupant.npc)
        if at then return at.x, at.y, at.z, at.yaw end
    end
    local i = occupant.spot
    return self.spotX[i], self.spotY[i], self.spotZ[i], self.spotYaw[i]
end

-- Its flee is over: it freezes at the server's position (every client shows it in one
-- place, with no authority left to churn) and cowers there until it is time to go back.
function Open77PedestrianScheduler:cower(key)
    local occupant = self.occupants[key]
    self.api.setAiMode(occupant.npc, "frozen")
    occupant.state, occupant.flee, occupant.move, occupant.cower = "cowering", nil, nil, nil
    occupant.returnAt = (occupant.attempts or 0) < self.config.returnAttempts and
        self.api.now() + self.api.random(self.config.cowerMinS, self.config.cowerMaxS) or nil
    -- Out of walk-back attempts: it cowers here until the occupant pass retires it.
    if not occupant.returnAt then occupant.strandedAt = self.api.now() end
    local at = self.api.position(occupant.npc)
    if not at or #self.panicChoices == 0 then return end
    local choice = self.panicChoices[self.api.random(1, #self.panicChoices)]
    local task = self.api.workspot(occupant.npc, choice.profile, {
        loop = true, clip = choice.clips[self.api.random(1, #choice.clips)],
        anchor = { x = at.x, y = at.y, z = at.z, yaw = at.yaw or 0 },
    })
    occupant.cower = task and tostring(task) or nil
end

-- Whether a player holds a seat over spot `spot` (open77_seating through the seat guard, row B6):
-- no pedestrian spawns on it, and none walks back or sits down on it.
function Open77PedestrianScheduler:seatHeld(bucket, spot)
    local held = self.api.seatBlocked
    return held ~= nil and held(bucket, self.spotX[spot], self.spotY[spot], self.spotZ[spot]) == true
end

-- The pedestrian holding a seat within `radius` (on the ground, 1 m in height) of (x, y, z) in `bucket`,
-- or nil: a player may not sit there (row B6). A seated pedestrian counts at its spot, as does one walking
-- back to it; a corpse where it lies. A fleeing or cowering one is away, and its walk back checks the
-- seat guard (`goHome`, `sit`), so a player may take the seat it fled.
local HOLDING = { seated = true, returning = true }
function Open77PedestrianScheduler:occupantNear(bucket, x, y, z, radius)
    local r2 = radius * radius
    for _, occupant in pairs(self.occupants) do
        if occupant.bucket == bucket then
            local ox, oy, oz
            if HOLDING[occupant.state] then
                local i = occupant.spot
                ox, oy, oz = self.spotX[i], self.spotY[i], self.spotZ[i]
            elseif occupant.state == "dead" then
                local at = self.api.position(occupant.npc)
                if at then ox, oy, oz = at.x, at.y, at.z end
            end
            if ox then
                local dx, dy = ox - x, oy - y
                local d2 = dx * dx + dy * dy
                if d2 <= r2 and math.abs(oz - z) <= 1.0 then
                    return { npc = occupant.npc, state = occupant.state, source = "seated", spot = occupant.spot,
                        distance = math.floor(math.sqrt(d2) * 1000 + 0.5) / 1000 }
                end
            end
        end
    end
    return nil
end

function Open77PedestrianScheduler:goHome(key)
    local occupant = self.occupants[key]
    local i = occupant.spot
    if self:seatHeld(occupant.bucket, i) then
        -- A player sat down on the seat it fled: it does not walk back onto them. It keeps cowering, and
        -- the walk back costs an attempt, so a seat held for long strands it (and the stranded rule
        -- retires it once nobody stands close).
        local now = self.api.now()
        occupant.attempts = (occupant.attempts or 0) + 1
        occupant.returnAt = occupant.attempts < self.config.returnAttempts and
            now + self.api.random(self.config.cowerMinS, self.config.cowerMaxS) or nil
        if not occupant.returnAt then occupant.strandedAt = now end
        self.failures.seat_held = (self.failures.seat_held or 0) + 1
        return
    end
    local cowering = occupant.cower
    occupant.state, occupant.cower, occupant.returnAt = "returning", nil, nil
    occupant.attempts = (occupant.attempts or 0) + 1
    if cowering then self.api.cancel(occupant.npc, cowering, "return") end
    self.api.setAiMode(occupant.npc, "tasks")
    local move = self.api.moveTo(occupant.npc, { x = self.spotX[i], y = self.spotY[i], z = self.spotZ[i] }, {
        speed = "walk", acceptanceRadius = self.config.returnAcceptanceM,
        timeoutMs = self.config.returnTimeoutMs,
    })
    if move then occupant.move = tostring(move) else self:cower(key) end
end

-- Back at its spot: the seated workspot and clip it had before the panic.
function Open77PedestrianScheduler:sit(key)
    local occupant = self.occupants[key]
    local i = occupant.spot
    occupant.move = nil
    if self:seatHeld(occupant.bucket, i) then
        -- A player sat down while it walked back: it cowers where it arrived instead, out of attempts.
        self.failures.seat_held = (self.failures.seat_held or 0) + 1
        occupant.attempts = self.config.returnAttempts
        self:cower(key)
        return
    end
    self.api.setAiMode(occupant.npc, "frozen")
    local task = self.api.workspot(occupant.npc, self.catalog.profiles[self.spotProfile[i]], {
        loop = true, clip = occupant.clip,
        anchor = { x = self.spotX[i], y = self.spotY[i], z = self.spotZ[i], yaw = self.spotYaw[i] },
    })
    if task then
        occupant.state, occupant.task, occupant.attempts = "seated", tostring(task), nil
    else
        occupant.attempts = self.config.returnAttempts
        self:cower(key)
    end
end

-- `budget` ({ work, slices }) is shared with the walking crowd's tick of the same server tick: the
-- two passes together stay within one slice's worth of work between yields. Without one (tests)
-- the pass has its own.
function Open77PedestrianScheduler:tick(budget)
    if not self.indexed then self:index() end
    if not self.enabled then
        for key in pairs(self.occupants) do self:drop(key, true) end
        return
    end
    local api, config = self.api, self.config
    local now = api.now()
    -- The scan forgets the expired cooldowns of the spots it reaches; the others once a minute.
    if not self.cooldownSweptAt or now - self.cooldownSweptAt >= 60 then
        for key, expires in pairs(self.cooldown) do
            if expires <= now then self.cooldown[key] = nil end
        end
        self.cooldownSweptAt = now
    end
    -- Hits read the shooter from here: rebuilding every player row per reported shot cost a pass over
    -- all players for each bullet of a firefight.
    -- `players` holds everyone a client streams NPCs for (the dead and dying included): load and
    -- retirement count them. Only the living (`alive`) bring pedestrians in.
    local players, alive, byId = {}, {}, {}
    for _, player in ipairs(api.players()) do
        byId[player.id] = player
        if config.buckets[player.bucket] then
            addPlayer(players, player.bucket, player)
            if player.alive ~= false then addPlayer(alive, player.bucket, player) end
        end
    end
    self.playersById = byId
    local minutes = {}
    for bucket in pairs(players) do
        minutes[bucket] = math.floor(((api.secondsOfDay(bucket) or
            config.fallbackSecondsOfDay) % 86400) / 60)
    end
    -- The pass is sliced: once it has examined scanWorkPerSlice cells and players, the rest waits for
    -- the next server tick. Every coroutine resumed in one server tick shares one instruction quota,
    -- and the scan near a dense market crowded with players is many times that quota.
    budget = budget or { work = 0, slices = 0 }
    local startSlices = budget.slices
    local charge = S.slicer(budget, config, api)
    local vertical, streamed = config.verticalRangeM, config.streamingRadiusM
    local xs, ys, zs = self.spotX, self.spotY, self.spotZ
    -- The global cap is shared between groups of players, but only once a group is refused for it:
    -- a crowd that arrived first holds every pedestrian until then, and takes every free slot as
    -- long as nobody else wants one (a group's share is its fair part of the cap, not a limit).
    local groups, cost, groupOf = countGroups(players, streamed)
    local maxNear = config.maxNearPlayer
    local share = math.max(1, math.floor(config.maxActive / math.max(1, groups)))
    self.groups, self.share = groups, share
    charge(cost)

    -- Vanilla authors several spots on one place for entries it never runs together (a guitarist and
    -- a handpan player in two communities): 1,474 catalogue pairs lie within 0.5 m, and filling both
    -- stacked two bodies in one seat. A spot waits while a pedestrian holds one that close.
    local clearance = config.spotClearanceM
    local taken = {}
    -- A spot's place never moves: its key is worked out the first time it is asked for.
    local placeOfSpot = self.spotPlace
    local function place(spot)
        local key = placeOfSpot[spot]
        if not key then
            key = (math.floor(xs[spot] / clearance) + 131072) * 262144 + math.floor(ys[spot] / clearance) + 131072
            placeOfSpot[spot] = key
        end
        return key
    end
    local function take(bucket, spot)
        local places = taken[bucket]
        if not places then places = {}; taken[bucket] = places end
        local key = place(spot)
        local list = places[key]
        if not list then list = {}; places[key] = list end
        list[#list + 1] = spot
    end
    local function clear(bucket, spot)
        local places = taken[bucket]
        if not places then return true end
        local x, y, z = xs[spot], ys[spot], zs[spot]
        local key = place(spot)
        for row = key - 262144, key + 262144, 262144 do
            for cell = row - 1, row + 1 do
                local list = places[cell]
                if list then
                    for i = 1, #list do
                        local other = list[i]
                        local dx, dy = xs[other] - x, ys[other] - y
                        if dx * dx + dy * dy < clearance * clearance and math.abs(zs[other] - z) < 1 then return false end
                    end
                end
            end
        end
        return true
    end

    -- Per player, the pedestrians its client streams (within the streaming radius): a dense market
    -- holds several hundred catalogue spots within reach, more than one client should animate.
    -- Stream bubbles overlap, so a pedestrian counts against every player that streams it, where it
    -- is now (a fleeing one is no longer at its spot), and against every group one of them is in.
    -- `seats` lists, per group, its seated pedestrians with the distance to their nearest player:
    -- the ones a group over its share gives up first are the farthest.
    local load, groupLoad, seats, active, watchers = {}, {}, {}, 0, {}
    local counted, counting = {}, 0
    -- Event handlers run while the pass waits between slices and may drop occupants.
    local keys = {}
    for key in pairs(self.occupants) do keys[#keys + 1] = key end
    for _, key in ipairs(keys) do
        local occupant = self.occupants[key]
        if occupant then
            local set = players[occupant.bucket]
            local spot = occupant.spot
            local x, y, z = xs[spot], ys[spot], zs[spot]
            if occupant.state ~= "seated" then
                local at = api.position(occupant.npc)
                if at then x, y, z = at.x, at.y, at.z end
            end
            local retire, cost = true, 6
            if set and occupant.state == "seated" then
                local nearest, examined = query(set, x, y, z, config.retireRadiusM, nil, true)
                retire, cost = nearest == math.huge, cost + examined
                -- An entry has one period per start minute and the catalogue never changes: the spot
                -- belongs to the period that seated this pedestrian for as long as it is the active one.
                local period = activePeriod(self, occupant.entry, minutes[occupant.bucket])
                if self.periodStart[period] ~= occupant.periodStart then retire = true end
            elseif set then
                -- A panicked, cowering, returning or dead pedestrian stays until every player
                -- is past the range that streams it out, so nobody watches it vanish.
                local nearest, examined = query(set, x, y, z, streamed + config.streamingHysteresisM, nil, true)
                retire, cost = nearest == math.huge, cost + examined
                -- A corpse or a stranded cowerer would hold its slot and its watchers' share for as
                -- long as anyone stays in range: past its delay it goes once nobody stands close,
                -- past the hard limit regardless.
                local since, delay, limit
                if occupant.state == "dead" then
                    since, delay, limit = occupant.diedAt, config.deadRetireS, config.deadRetireMaxS
                elseif occupant.state == "cowering" then
                    since, delay, limit = occupant.strandedAt, config.strandedRetireS, config.strandedRetireMaxS
                end
                if not retire and since and now - since >= delay then
                    if now - since >= limit then
                        retire = true
                    else
                        nearest, examined = query(set, x, y, z, config.corpseQuietM, nil, true)
                        retire, cost = nearest == math.huge, cost + examined
                    end
                end
            end
            if retire then
                self:drop(key, true)
            else
                if occupant.state == "cowering" and occupant.returnAt and now >= occupant.returnAt then
                    self:goHome(key)
                end
                take(occupant.bucket, spot)
                active = active + 1
                local nearest, examined = query(set, x, y, z, streamed, nil, false, watchers)
                cost = cost + examined + 2 * #watchers
                local seat = #watchers > 0 and occupant.state == "seated" and { key = key, distance = nearest }
                counting = counting + 1
                for i = #watchers, 1, -1 do
                    local player = watchers[i]
                    load[player] = (load[player] or 0) + 1
                    local group = groupOf[player]
                    if counted[group] ~= counting then
                        counted[group] = counting
                        groupLoad[group] = (groupLoad[group] or 0) + 1
                        if seat then
                            local list = seats[group]
                            if not list then list = {}; seats[group] = list end
                            list[#list + 1] = seat
                        end
                    end
                    watchers[i] = nil
                end
            end
            charge(cost)
        end
    end

    -- Once the cap is reached, or a group was refused for it, only the groups under their share
    -- can spawn (below). The spots another group brings in stay out of the list, or the nearest
    -- `keep` of them would keep a starved group's spots out of it.
    local crowded = self.contended or active >= config.maxActive
    local candidates, keep = {}, math.max(config.spawnsPerTick, math.min(config.spawnsPerTick * 4, 32))
    -- Per bucket scanned, the spots in reach and those reserved this pass, marked with a number of
    -- the scan instead of collected in fresh sets: thousands of entries a pass were garbage.
    local inRangeAt, reservedAt = self.inRangeAt, self.reservedAt
    local activate = config.activateRadiusM
    -- Enough 64 m cells around a player's own to cover the whole spawn radius.
    local span = math.ceil(activate / CELL)
    for bucket, set in pairs(alive) do
        -- Players already showing their cap: a spot one of them streams would be refused below,
        -- so it does not take a candidate's place.
        local saturated, open = {}, false
        for _, player in ipairs(players[bucket].list) do
            if (load[player] or 0) >= maxNear then addPlayer(saturated, bucket, player) end
        end
        for _, player in ipairs(set.list) do
            if (load[player] or 0) < maxNear then
                open = true
                break
            end
        end
        local full = saturated[bucket]
        if open then
            local cells = {}
            for cellId in pairs(set.cells) do
                local cx, cy = cellId // 65536 - 32768, cellId % 65536 - 32768
                for gx = cx - span, cx + span do
                    for gy = cy - span, cy + span do cells[cellKey(gx, gy)] = true end
                end
            end
            local nearby = {}
            local stamp = self.scanStamp + 1
            self.scanStamp = stamp
            local grid, spotEnabled, cooldowns, occupants = self.grid, self.spotEnabled, self.cooldown, self.occupants
            -- At most seatedCellsPerPass cells of the window are scanned a pass, the next ones on the next pass: with
            -- hundreds of players spread over the city the whole window is tens of thousands of spots, and spawning
            -- only takes a few of them a pass anyway. A small window is scanned whole every pass.
            local order = {}
            for cellId in pairs(cells) do order[#order + 1] = cellId end
            local limit = config.seatedCellsPerPass or #order
            if #order > limit then
                table.sort(order)
                local cursors = self.cellCursor
                if not cursors then cursors = {}; self.cellCursor = cursors end
                local from = (cursors[bucket] or 0) % #order
                local window = {}
                for i = 1, limit do window[i] = order[(from + i - 1) % #order + 1] end
                cursors[bucket] = from + limit
                order = window
            end
            charge(#order)
            for _, cellId in ipairs(order) do
                local spots = grid[cellId]
                -- The window around every player cell is mostly out of reach: a cell no living player
                -- can activate from is passed whole (most of the spots this scan used to measure).
                local near, built = nil, 0
                if spots then
                    near, built = playersNear(set, cellId // 65536 - 32768, cellId % 65536 - 32768, activate)
                end
                if not spots or #near == 0 then
                    charge(1 + built)
                    spots = nil
                end
                -- A living player within reach of the cell's four corners and of the height its spots
                -- span has every spot of it in reach: none of them is measured.
                local covered, cost = false, built
                if spots then
                    local left, bottom = (cellId // 65536 - 32768) * CELL, (cellId % 65536 - 32768) * CELL
                    local heights, reach2 = self.cellZ[cellId], activate * activate
                    for i = 1, #near do
                        local player = near[i]
                        local fx = math.max(math.abs(player.x - left), math.abs(player.x - left - CELL))
                        local fy = math.max(math.abs(player.y - bottom), math.abs(player.y - bottom - CELL))
                        if fx * fx + fy * fy <= reach2 and player.z - heights[1] <= vertical and
                            heights[2] - player.z <= vertical then
                            covered = true
                            break
                        end
                    end
                    cost = cost + #near
                end
                for i = 1, spots and #spots or 0 do
                    local spotIndex = spots[i]
                    cost = cost + 2
                    -- In reach first: a spot out of it needs no key.
                    if spotEnabled[spotIndex] then
                        local nearest, examined = 0, 0
                        if not covered then
                            nearest, examined = query(set, xs[spotIndex], ys[spotIndex], zs[spotIndex],
                                activate, vertical, true)
                        end
                        cost = cost + examined
                        if nearest < math.huge then
                            local key = self:keyOf(bucket, spotIndex)
                            local cooldown = cooldowns[key]
                            -- An expired cooldown is forgotten here (and by the sweep below): the table
                            -- would grow to one entry per spot ever panicked, failed or shot at.
                            if cooldown and cooldown <= now then cooldowns[key], cooldown = nil, nil end
                            if not occupants[key] and not cooldown then
                                inRangeAt[spotIndex] = stamp
                                local first = self.spotEntryFirst[spotIndex]
                                if first then
                                    local list = self.spotEntries
                                    for k = first, first + self.spotEntryCount[spotIndex] - 1 do nearby[list[k]] = true end
                                end
                            end
                        end
                    end
                    -- Charged in runs: one call per spot was a fifth of the scan.
                    if cost >= 256 then
                        charge(cost)
                        cost = 0
                    end
                end
                if spots then charge(cost) end
            end
            for entryIndex in pairs(nearby) do
                local period = activePeriod(self, entryIndex, minutes[bucket])
                local spotFirst, spotCount, periodSpots = self.periodSpotFirst[period], self.periodSpotCount[period], self.periodSpots
                local want = math.min(self.periodQuantity[period], spotCount)
                local have = self.entryCount[self:keyOf(bucket, entryIndex)] or 0
                local cost = 3
                -- The catalogue lists a non-sequence period's spots in its fill order already
                -- (build_spot_catalog.py `fill_order`).
                for k = spotFirst, spotFirst + spotCount - 1 do
                    local spotIndex = periodSpots[k]
                    if have >= want then break end
                    cost = cost + 1
                    local key = inRangeAt[spotIndex] == stamp and self:keyOf(bucket, spotIndex)
                    if key and reservedAt[spotIndex] ~= stamp then
                        local x, y, z = xs[spotIndex], ys[spotIndex], zs[spotIndex]
                        local blocked, examined = query(full, x, y, z, streamed, nil, true)
                        cost = cost + examined
                        if blocked == math.huge and clear(bucket, spotIndex) and not self:seatHeld(bucket, spotIndex) then
                            -- Only the `keep` nearest can spawn this tick: past the farthest kept so
                            -- far, the distance is not worth measuring.
                            local worst = #candidates >= keep and candidates[keep]
                            local nearest, who
                            nearest, examined, who = query(set, x, y, z,
                                worst and math.min(activate, worst.distance) or activate, vertical, false, nil, activate)
                            cost = cost + examined + 12
                            local held = crowded and nearest < math.huge and
                                (groupLoad[groupOf[who]] or 0) >= share
                            -- A spot held that way takes neither the place nor its entry's slot.
                            if not held then
                                reservedAt[spotIndex] = stamp
                                take(bucket, spotIndex)
                                if nearest < math.huge then
                                    -- The insertion walks the kept list: its length is the work.
                                    cost = cost + #candidates // 4
                                    offer(candidates, { bucket = bucket, spot = spotIndex, entry = entryIndex,
                                        period = period, distance = nearest, key = key }, keep)
                                end
                                have = have + 1
                            end
                        end
                    end
                    -- Per spot, not per entry: a period lists up to 719 spots, and one entry's
                    -- loop alone passed the instruction quota before the pass could pause.
                    charge(cost)
                    cost = 0
                end
                charge(cost)
            end
        end
    end

    -- `pedestrians.enable off` may have landed while the pass waited between slices.
    if not self.enabled then return end
    local created, starved = 0, false
    -- New bodies this pass per player streaming them: at most spawnsPerPlayerTick each, so a
    -- client entering the world builds its neighbourhood over seconds, not in one burst.
    local fresh, perPlayer = {}, config.spawnsPerPlayerTick or config.spawnsPerTick
    for _, candidate in ipairs(candidates) do
        if created >= config.spawnsPerTick then break end
        local spot = candidate.spot
        -- A player may have sat down there while the pass waited between slices.
        if self:seatHeld(candidate.bucket, spot) then goto continue end
        -- A spawn: its Lua side, a few dozen instructions (the platform call runs natively).
        charge(60)
        local x, y, z, yaw = xs[spot], ys[spot], zs[spot], self.spotYaw[spot]
        local streaming = {}
        query(players[candidate.bucket], x, y, z, streamed, nil, false, streaming)
        for _, player in ipairs(streaming) do
            if (load[player] or 0) >= maxNear then goto continue end
            if (fresh[player] or 0) >= perPlayer then goto continue end
        end
        -- Each group that streams it, once; `room` when one of them is under its share of the cap.
        local watching, room = {}, false
        for _, player in ipairs(streaming) do
            local group = groupOf[player]
            if not watching[group] then
                watching[group] = true
                if (groupLoad[group] or 0) < share then room = true end
            end
        end
        if active >= config.maxActive then
            -- Refused for the global cap: a group under its share is starved of it, one at its share
            -- or over it is not (and a later candidate may still be one that is).
            if not room then goto continue end
            starved = true
            break
        end
        if self.contended and not room then goto continue end
        for _, player in ipairs(streaming) do load[player] = (load[player] or 0) + 1 end
        for group in pairs(watching) do groupLoad[group] = (groupLoad[group] or 0) + 1 end
        local pool = self.catalog.appearancePools[self.entryPool[candidate.entry]]
        local profile = self.spotProfile[spot]
        local clips = self:clipsFor(profile, self.entryBody[candidate.entry])
        self.spawns = self.spawns + 1
        local npc, reason = api.create({
            record = self.catalog.records[self.entryRecord[candidate.entry]],
            appearance = pool[(self.spawns - 1) % #pool + 1],
            position = { x = x, y = y, z = z }, yaw = yaw,
            bucket = candidate.bucket, aiMode = "frozen",
            damagePolicy = config.mortal and "mortal" or "immortal",
            streamingRadius = config.streamingRadiusM,
            streamingHysteresis = config.streamingHysteresisM,
            behavior = { aiEnabled = true, combatEnabled = false,
                perceptionEnabled = false, voiceEnabled = false },
        })
        if npc then
            local task
            local clip = clips[(self.spawns - 1) % #clips + 1]
            task, reason = api.workspot(npc, self.catalog.profiles[profile], {
                loop = true, clip = clip,
                anchor = { x = x, y = y, z = z, yaw = yaw },
            })
            if task then
                local occupant = { npc = tostring(npc), task = tostring(task),
                    entry = candidate.entry, periodStart = self.periodStart[candidate.period],
                    state = "seated", bucket = candidate.bucket, spot = candidate.spot, clip = clip }
                self.occupants[candidate.key] = occupant
                self.byNpc[occupant.npc] = candidate.key
                self:count(occupant, 1)
                created = created + 1
                active = active + 1
                for _, player in ipairs(streaming) do fresh[player] = (fresh[player] or 0) + 1 end
            else
                api.remove(npc)
            end
        end
        if not npc or not self.occupants[candidate.key] then
            reason = tostring(reason or "unknown")
            self.failures[reason] = (self.failures[reason] or 0) + 1
            self.cooldown[candidate.key] = now + config.failureCooldownS
        end
        ::continue::
    end
    if starved then
        self.contended = true
        self:rebalance(players, groupOf, groupLoad, seats, share, charge)
    elseif active < config.maxActive then
        self.contended = false
    end
    self.lastSlices = budget.slices - startSlices
end

-- A group refused for the global cap takes slots back from the groups over their share: each gives
-- up its seated pedestrians farthest from every player, until it is at its share, spawnsPerTick a
-- pass in all; the freed slots fill on the next pass, nearest first, groups under their share only.
function Open77PedestrianScheduler:rebalance(players, groupOf, groupLoad, seats, share, charge)
    local config = self.config
    local budget, streamed = config.spawnsPerTick, config.streamingRadiusM
    local over, watchers = {}, {}
    for group, load in pairs(groupLoad) do
        if load > share then over[#over + 1] = group end
    end
    table.sort(over, function(a, b)
        if groupLoad[a] == groupLoad[b] then return a < b end
        return groupLoad[a] > groupLoad[b]
    end)
    for _, group in ipairs(over) do
        local list, cost = seats[group] or {}, 0
        while budget > 0 and groupLoad[group] > share do
            local farthest
            for i = 1, #list do
                local seat = list[i]
                if not seat.dropped and (not farthest or seat.distance > farthest.distance or
                    seat.distance == farthest.distance and seat.key > farthest.key) then
                    farthest = seat
                end
            end
            cost = cost + #list
            if not farthest then break end
            farthest.dropped = true
            local occupant = self.occupants[farthest.key]
            if occupant and occupant.state == "seated" then
                local spot = occupant.spot
                local _, examined = query(players[occupant.bucket], self.spotX[spot], self.spotY[spot],
                    self.spotZ[spot], streamed, nil, false, watchers)
                cost = cost + examined
                local released = {}
                for i = #watchers, 1, -1 do
                    local watching = groupOf[watchers[i]]
                    if not released[watching] then
                        released[watching] = true
                        groupLoad[watching] = math.max(0, (groupLoad[watching] or 0) - 1)
                    end
                    watchers[i] = nil
                end
                self:drop(farthest.key, true)
                budget = budget - 1
            end
        end
        charge(cost)
    end
end

-- A seated, cowering or returning pedestrian flees; one already fleeing keeps its flight.
local PANICKABLE = { seated = true, cowering = true, returning = true }

function Open77PedestrianScheduler:panic(key, source, origin)
    local occupant = self.occupants[key]
    if not occupant or not PANICKABLE[occupant.state] then return end
    local current = occupant.state == "seated" and occupant.task or occupant.cower or occupant.move
    local x, y = self:whereabouts(occupant)
    occupant.state, occupant.cower, occupant.move, occupant.returnAt, occupant.attempts, occupant.strandedAt =
        "panicking", nil, nil, nil, nil, nil
    self.cooldown[key] = self.api.now() + self.config.spotCooldownS
    if current then self.api.cancel(occupant.npc, current, "panic") end
    self.api.setAiMode(occupant.npc, "tasks")
    -- Every neighbour fled exactly fleeDistanceM straight away from one point, so they all stopped on
    -- the same line and cowered there in a row. Each one now runs its own distance, and its bearing
    -- turns up to fleeFanDeg off straight-away: the point it flees is the panic rotated about the
    -- neighbour, so flight never points back past the victim (the client flees along body - point).
    -- A shooter stays the exact point its victim flees.
    local from = tonumber(tostring(source or ""):match("^player:(%d+)$"))
    if not from then
        local ax, ay = x - origin.x, y - origin.y
        local length = math.sqrt(ax * ax + ay * ay)
        if length < 0.5 then ax, ay, length = 1, 0, 1 end
        local turn = math.rad(self.api.random(-self.config.fleeFanDeg, self.config.fleeFanDeg))
        local rx = ax * math.cos(turn) - ay * math.sin(turn)
        local ry = ax * math.sin(turn) + ay * math.cos(turn)
        from = { x = x - rx, y = y - ry, z = origin.z }
    end
    local flee = self.api.flee(occupant.npc, from, {
        distance = self.api.random(self.config.fleeDistanceMinM, self.config.fleeDistanceM),
        timeoutMs = self.config.fleeTimeoutMs,
    })
    occupant.flee = flee and tostring(flee) or nil
    if not occupant.flee then self:drop(key, true) end
end

-- Every other pedestrian of the bucket within panicRadiusM of `origin` flees (`exceptNpc` is the
-- victim). Hits and deaths reach it through `api.panicNear`, which also scares the walking crowd.
-- `radius` (default panicRadiusM) and `source` (a `player:<id>` they flee from, gunfire) are optional.
function Open77PedestrianScheduler:panicNeighbours(bucket, origin, exceptNpc, radius, source)
    radius = radius or self.config.panicRadiusM
    local radius2 = radius * radius
    for key, occupant in pairs(self.occupants) do
        if occupant.npc ~= exceptNpc and occupant.bucket == bucket and PANICKABLE[occupant.state] then
            local x, y, z = self:whereabouts(occupant)
            local dx, dy, dz = x - origin.x, y - origin.y, z - origin.z
            if dx * dx + dy * dy + dz * dz <= radius2 then self:panic(key, source, origin) end
        end
    end
end

-- Player -> NPC hits reach the server only as the shooter's own report
-- (`open77:npcHit`), so accept one only for a live pedestrian that player can
-- actually be looking at: same bucket, inside the streaming range of where it is.
function Open77PedestrianScheduler:admitHit(npcId, playerId)
    local key = self.byNpc[tostring(npcId)]
    local occupant = key and self.occupants[key]
    if not occupant or occupant.state == "dead" then return false end
    local player = self.playersById[playerId]
    if not player or player.alive == false then return false end
    local x, y, z = self:whereabouts(occupant)
    local range = self.config.streamingRadiusM + self.config.streamingHysteresisM
    local dx, dy, dz = player.x - x, player.y - y, player.z - z
    return player.bucket == occupant.bucket and dx * dx + dy * dy + dz * dz <= range * range
end

-- A shot the shooter's client reported: a mortal pedestrian takes the damage (the platform's
-- onNpcDamaged then panics it), an immortal one is only startled.
function Open77PedestrianScheduler:onHit(npcId, playerId)
    if not self:admitHit(npcId, playerId) then return end
    local source = "player:" .. playerId
    if self.config.mortal then self.api.damage(npcId, self.config.hitDamage, source)
    else self:onDamaged(npcId, source) end
end

function Open77PedestrianScheduler:onDamaged(npcId, source)
    if not self.config.panic then return end
    local key = self.byNpc[tostring(npcId)]
    local occupant = key and self.occupants[key]
    if not occupant or not PANICKABLE[occupant.state] then return end
    local x, y, z = self:whereabouts(occupant)
    local origin = { x = x, y = y, z = z }
    self:panic(key, source, origin)
    self.api.panicNear(occupant.bucket, origin, occupant.npc)
end

function Open77PedestrianScheduler:onDied(npcId)
    local key = self.byNpc[tostring(npcId)]
    local occupant = key and self.occupants[key]
    if not occupant or occupant.state == "dead" then return end
    local x, y, z = self:whereabouts(occupant)
    local origin = { x = x, y = y, z = z }
    self:count(occupant, -1)
    occupant.state, occupant.diedAt = "dead", self.api.now()
    self.cooldown[key] = self.api.now() + self.config.spotCooldownS
    if self.config.panic then self.api.panicNear(occupant.bucket, origin, occupant.npc) end
end

function Open77PedestrianScheduler:onTaskState(npcId, taskId, status)
    if status ~= "success" and status ~= "failure" and status ~= "cancelled" and status ~= "interrupted" then return end
    local key = self.byNpc[tostring(npcId)]
    local occupant = key and self.occupants[key]
    if not occupant then return end
    local id = tostring(taskId)
    if occupant.state == "panicking" and occupant.flee == id then
        self:cower(key)
    elseif occupant.state == "returning" and occupant.move == id then
        -- A walk back that could not get there cowers again; `cower` bounds the retries.
        if status == "success" then self:sit(key) else self:cower(key) end
    elseif occupant.state == "seated" and occupant.task == id then
        self:drop(key, true)
        self.failures.task_ended = (self.failures.task_ended or 0) + 1
        self.cooldown[key] = self.api.now() + self.config.failureCooldownS
    end
end

function Open77PedestrianScheduler:onRemoved(npcId)
    local key = self.byNpc[tostring(npcId)]
    if key then self:drop(key, false) end
end

function Open77PedestrianScheduler:status()
    local active, cooldowns, now = {}, 0, self.api.now()
    for _, occupant in pairs(self.occupants) do
        local bucket = active[occupant.bucket] or
            { seated = 0, panicking = 0, cowering = 0, returning = 0, dead = 0 }
        bucket[occupant.state] = bucket[occupant.state] + 1
        active[occupant.bucket] = bucket
    end
    for _, expires in pairs(self.cooldown) do
        if expires > now then cooldowns = cooldowns + 1 end
    end
    return { enabled = self.enabled, spots = #self.spotX, entries = self.entryTotal,
        profiles = #self.catalog.profiles, disabledSpots = self.disabledSpots,
        active = active, cooldowns = cooldowns, failures = self.failures, slices = self.lastSlices or 0,
        groups = self.groups or 0, share = self.share or 0 }
end

function Open77PedestrianScheduler:reset()
    for key in pairs(self.occupants) do self:drop(key, true) end
    self.cooldown, self.failures = {}, {}
end

function Open77PedestrianScheduler:setEnabled(flag)
    self.enabled = flag
end

-- Runtime switches behind `pedestrians.mortal` / `pedestrians.panic`: living pedestrians take the
-- new damage policy at once; new spawns, hits and deaths read the config.
function Open77PedestrianScheduler:setMortal(flag)
    self.config.mortal = flag
    local policy = flag and "mortal" or "immortal"
    for _, occupant in pairs(self.occupants) do
        if occupant.state ~= "dead" then self.api.setDamagePolicy(occupant.npc, policy) end
    end
end

function Open77PedestrianScheduler:setPanic(flag)
    self.config.panic = flag
end
