Open77PedestrianScheduler = {}
Open77PedestrianScheduler.__index = Open77PedestrianScheduler

-- Catalogue rows are positional (build_spot_catalog.py, schema 2): an entry is { record, appearance
-- pool, body bits, periods }, a period { start minute, quantity, sequence, spot indices }.
local E_RECORD, E_POOL, E_BODY, E_PERIODS = 1, 2, 3, 4
local P_START, P_QUANTITY, P_SPOTS = 1, 2, 4

local function activePeriod(entry, minute)
    local selected, chosen
    for _, period in ipairs(entry[E_PERIODS]) do
        local start = period[P_START]
        if not selected or (start <= minute and (chosen > minute or start > chosen)) or
                (chosen > minute and start > chosen) then
            selected, chosen = period, start
        end
    end
    return selected
end

-- The player grid and the queries over it are shared with the walking crowd (spatial.lua).
local S = Open77PedestrianSpatial
local CELL, cellOf, cellKey, addPlayer, query, offer, countGroups =
    S.CELL, S.cellOf, S.cellKey, S.addPlayer, S.query, S.offer, S.countGroups

-- Cheap: the spot and entry indices are built by `index`, in slices, on the scheduler's own thread.
-- The spot columns are the catalogue's own tables, read in place.
function Open77PedestrianScheduler.new(catalog, config, api)
    return setmetatable({
        catalog = catalog, config = config, api = api, enabled = config.enabled,
        spotX = catalog.spotX, spotY = catalog.spotY, spotZ = catalog.spotZ, spotYaw = catalog.spotYaw,
        spotProfile = catalog.spotProfile, entries = catalog.entries,
        spotEnabled = {}, entriesBySpot = {}, grid = {}, clips = {}, bodyClips = {},
        occupants = {}, byNpc = {}, cooldown = {}, failures = {}, spawns = 0,
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
    local xs, ys = self.spotX, self.spotY
    for index = 1, #xs do
        self.spotEnabled[index] = enabled[profiles[index]] == true
        local key = cellKey(cellOf(xs[index]), cellOf(ys[index]))
        local cell = self.grid[key]
        if not cell then cell = {}; self.grid[key] = cell end
        cell[#cell + 1] = index
        step()
    end
    for index, entry in ipairs(self.entries) do
        for _, period in ipairs(entry[E_PERIODS]) do
            for _, spotIndex in ipairs(period[P_SPOTS]) do
                local entries = self.entriesBySpot[spotIndex] or {}
                entries[index] = true
                self.entriesBySpot[spotIndex] = entries
                step()
            end
        end
    end
    self.indexed = true
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
    local function charge(amount)
        budget.work = budget.work + amount
        if budget.work >= config.scanWorkPerSlice and api.yield then
            api.yield()
            budget.work, budget.slices = 0, budget.slices + 1
        end
    end
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
    local function placeOf(v) return math.floor(v / clearance) + 131072 end
    local function take(bucket, spot)
        local places = taken[bucket]
        if not places then places = {}; taken[bucket] = places end
        local key = placeOf(xs[spot]) * 262144 + placeOf(ys[spot])
        local list = places[key]
        if not list then list = {}; places[key] = list end
        list[#list + 1] = spot
    end
    local function clear(bucket, spot)
        local places = taken[bucket]
        if not places then return true end
        local x, y, z = xs[spot], ys[spot], zs[spot]
        local px, py = placeOf(x), placeOf(y)
        for cx = px - 1, px + 1 do
            for cy = py - 1, py + 1 do
                local list = places[cx * 262144 + cy]
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
                local period = activePeriod(self.entries[occupant.entry], minutes[occupant.bucket])
                if period[P_START] ~= occupant.periodStart then retire = true end
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
    local candidates, reserved, keep = {}, {}, config.spawnsPerTick * 4
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
            local inRange, nearby = {}, {}
            for cellId in pairs(cells) do
                local spots = self.grid[cellId]
                for i = 1, spots and #spots or 0 do
                    local spotIndex = spots[i]
                    local cost = 2
                    if self.spotEnabled[spotIndex] then
                        local key = bucket .. ":" .. spotIndex
                        local cooldown = self.cooldown[key]
                        -- An expired cooldown is forgotten here: the table would grow to one entry
                        -- per spot ever panicked, failed or shot at.
                        if cooldown and cooldown <= now then self.cooldown[key], cooldown = nil, nil end
                        if not self.occupants[key] and not cooldown then
                            local nearest, examined = query(set, xs[spotIndex], ys[spotIndex], zs[spotIndex],
                                activate, vertical, true)
                            cost = cost + examined
                            if nearest < math.huge then
                                inRange[spotIndex] = true
                                local entries = self.entriesBySpot[spotIndex]
                                if entries then
                                    for index in pairs(entries) do nearby[index] = true end
                                end
                            end
                        end
                    end
                    charge(cost)
                end
            end
            for entryIndex in pairs(nearby) do
                local period = activePeriod(self.entries[entryIndex], minutes[bucket])
                local want = math.min(period[P_QUANTITY], #period[P_SPOTS])
                local have = self.entryCount[bucket .. ":" .. entryIndex] or 0
                local cost = 3
                -- The catalogue lists a non-sequence period's spots in its fill order already
                -- (build_spot_catalog.py `fill_order`).
                for _, spotIndex in ipairs(period[P_SPOTS]) do
                    if have >= want then break end
                    cost = cost + 1
                    local key = inRange[spotIndex] and bucket .. ":" .. spotIndex
                    if key and not reserved[key] then
                        local x, y, z = xs[spotIndex], ys[spotIndex], zs[spotIndex]
                        local blocked, examined = query(full, x, y, z, streamed, nil, true)
                        cost = cost + examined
                        if blocked == math.huge and clear(bucket, spotIndex) and not self:seatHeld(bucket, spotIndex) then
                            -- Only the `keep` nearest can spawn this tick: past the farthest kept so
                            -- far, the distance is not worth measuring.
                            local worst = #candidates >= keep and candidates[keep]
                            local nearest, who
                            nearest, examined, who = query(set, x, y, z,
                                worst and math.min(activate, worst.distance) or activate, vertical, false)
                            cost = cost + examined + 12
                            local held = crowded and nearest < math.huge and
                                (groupLoad[groupOf[who]] or 0) >= share
                            -- A spot held that way takes neither the place nor its entry's slot.
                            if not held then
                                reserved[key] = true
                                take(bucket, spotIndex)
                                if nearest < math.huge then
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
    for _, candidate in ipairs(candidates) do
        if created >= config.spawnsPerTick then break end
        local spot = candidate.spot
        -- A player may have sat down there while the pass waited between slices.
        if self:seatHeld(candidate.bucket, spot) then goto continue end
        local x, y, z, yaw = xs[spot], ys[spot], zs[spot], self.spotYaw[spot]
        local streaming = {}
        query(players[candidate.bucket], x, y, z, streamed, nil, false, streaming)
        for _, player in ipairs(streaming) do
            if (load[player] or 0) >= maxNear then goto continue end
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
        local entry = self.entries[candidate.entry]
        local pool = self.catalog.appearancePools[entry[E_POOL]]
        local profile = self.spotProfile[spot]
        local clips = self:clipsFor(profile, entry[E_BODY])
        self.spawns = self.spawns + 1
        local npc, reason = api.create({
            record = self.catalog.records[entry[E_RECORD]],
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
                    entry = candidate.entry, periodStart = candidate.period[P_START],
                    state = "seated", bucket = candidate.bucket, spot = candidate.spot, clip = clip }
                self.occupants[candidate.key] = occupant
                self.byNpc[occupant.npc] = candidate.key
                self:count(occupant, 1)
                created = created + 1
                active = active + 1
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
function Open77PedestrianScheduler:panicNeighbours(bucket, origin, exceptNpc)
    local radius2 = self.config.panicRadiusM * self.config.panicRadiusM
    for key, occupant in pairs(self.occupants) do
        if occupant.npc ~= exceptNpc and occupant.bucket == bucket and PANICKABLE[occupant.state] then
            local x, y, z = self:whereabouts(occupant)
            local dx, dy, dz = x - origin.x, y - origin.y, z - origin.z
            if dx * dx + dy * dy + dz * dz <= radius2 then self:panic(key, nil, origin) end
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
    return { enabled = self.enabled, spots = #self.spotX, entries = #self.entries,
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
