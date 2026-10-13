-- rp_streetfood / server/service.lua: the stall, as hooks of the wave-1 libraries.
--
--   cook      grill target -> action `cook_<recipe>` (station claim: one cook per grill);
--             reserve hook = ONE coordinator reservation (inputs out of the pantry, the dish onto
--             the pass, capacity held); commit hook = that operation; cancel hook = its release
--   order     counter target -> action `order_<dish>` (a gesture, no value): an order ticket
--   serve     grill target -> action `serve` (a prompt); its commit starts a CONSENTED hand-over
--             (Open77.playerInteractions `give`), a two-player step open77_actions does not run:
--             this file reserves the portion, re-checks the cook's shift (rp_jobs epoch) and, on
--             completion, pays through ONE rp_economy sale (portion + price + tip, receipt)
--   eat       counter target `eat_counter`, seat targets `eat_seat_<profile>`, or on the go
--             (`eat_go`, `drink_go`): reserve hook = one portion out of the pockets; commit = that
--             operation, then the rp_needs effect once
--   stock     grill target -> action `stock`: the cook's ingredients into the pantry, one
--             rp_inventory moveAsync operation
--
-- Durable state lives in the coordinator (pantry, pass, pockets) and in rp_economy (money). What
-- this file keeps (tickets, offers, the hand items) is presentation and intent: a restart loses
-- an order or an offer, never an ingredient, a dish or an eddy.
--
-- Global: StreetfoodService.

StreetfoodService = {}
local S = {}
S.__index = S

local ACTIONS = "open77_actions"
local HOOKS = { validate = "sfValidate", reserve = "sfReserve", commit = "sfCommit", cancel = "sfCancel" }
local PLAIN_HOOKS = { validate = "sfValidate", commit = "sfCommit" }

-- Transient refusals open77_actions would retry (or end `in_doubt`): an offer that was not made
-- has nothing in doubt, so they are reported as the stall being unavailable.
local NOT_MADE = { store_unavailable = true, coordinator_unavailable = true, in_doubt = true, busy = true,
    conflict = true, export_timeout = true, export_resource_stopped = true, export_target_busy = true }

function StreetfoodService.new(deps)
    return setmetatable({
        cfg = deps.config, M = deps.model, L = deps.ledger, P = deps.ports,
        resource = deps.resource or "rp_streetfood",
        stalls = {},         -- [stallKey] = { key, cfg, pantry, pass, opened }
        seats = {},          -- [targetId] = { stall, index, label, position, yaw, profile, furniture, source }
        actionKinds = {},    -- [actionId] = { kind = "cook"|"serve"|"stock"|"order"|"eat", ... }
        tickets = {},        -- [stallKey] = { [subject] = ticket }
        ticketSeq = 0,
        tips = {},           -- [subject] = tip for the next order
        offers = {},         -- [interactionId] = offer (hand-over in progress)
        offerOf = {},        -- [cookPid] = interactionId
        promised = {},       -- ["<container>|<item>"] = portions promised to open offers
        sales = {},          -- [saleOpId] = offer whose sale is in doubt (the sweep asks rp_economy)
        work = {},           -- [actions opId] = reservation (cook or meal)
        doubts = {},         -- [txOpId] = reservation whose commit is in doubt
        done = {},           -- [txOpId | saleOpId] = ms (its after-commit step ran)
        needsApplied = {},   -- [txOpId] = true
        hands = {},          -- [playerId] = { item, record, request }
        opIds = {},          -- [actions opId] = stock op id (retries reuse it)
        receipts = {},       -- [subject] = ring of { kind, opId, text, at }
        notified = {},       -- [playerId] = ms of the last refusal toast
        ready = false,
        stats = { cooks = 0, sales = 0, meals = 0, orders = 0, refusals = 0, doubts = 0, declined = 0,
                  stocked = 0, restocks = 0, needs = 0, dropped = 0 },
    }, S)
end

function S:log(fmt, ...) self.P.log(fmt:format(...)) end
function S:warn(fmt, ...) self.P.warn(fmt:format(...)) end

local function fromActions() return GetInvokingResource() == ACTIONS end
S.fromActions = fromActions

-- ---------------------------------------------------------------------------------------------
-- Telling players
-- ---------------------------------------------------------------------------------------------
function S:tell(pid, text, kind)
    pid = self.M.playerId(pid)
    if pid then self.P.tell(pid, text, kind) end
end

function S:refuseTo(pid, reason)
    self.stats.refusals = self.stats.refusals + 1
    pid = self.M.playerId(pid)
    if not pid then return end
    local now = self.P.now()
    if (self.notified[pid] or 0) + self.cfg.notifyCooldownMs > now then return end
    self.notified[pid] = now
    self.P.tell(pid, self.M.textFor(reason), "warning")
end

-- The player still is the subject a deferred message is about (seats are reused).
function S:isSubject(pid, subject)
    return pid ~= nil and subject ~= nil and self.L.subjectOf(pid) == subject
end

function S:record(subject, entry)
    if not subject then return end
    local ring = self.receipts[subject] or {}
    entry.at = self.P.now()
    ring[#ring + 1] = entry
    while #ring > self.cfg.receiptsKept do table.remove(ring, 1) end
    self.receipts[subject] = ring
end

-- The character name (rp_identity) when it runs, else the account name: what other players read.
function S:nameOf(pid)
    local ok, full = pcall(Open77.exports.callSync, "rp_identity", "fullName", pid)
    if ok and type(full) == "string" and full ~= "" and full ~= "Unknown citizen" then return full end
    return self.P.players.name(pid) or ("player " .. tostring(pid))
end

-- ---------------------------------------------------------------------------------------------
-- Boot steps (re-run whenever a library restarts)
-- ---------------------------------------------------------------------------------------------
function S:defineItems()
    local registered, rejected, details = self.P.inventory.define(self.cfg.items)
    if registered == nil then
        self:warn("rp_inventory:define unavailable (%s): items not defined yet", tostring(rejected))
        return false
    end
    if (tonumber(rejected) or 0) > 0 then
        local names = {}
        for _, c in ipairs(type(details) == "table" and details.collisions or {}) do names[#names + 1] = tostring(c) end
        self:warn("items: %s registered, %s refused %s (another definer owns them?)", tostring(registered),
            tostring(rejected), table.concat(names, ","))
    else
        self:log("items defined through rp_inventory: %s", tostring(registered))
    end
    return true
end

-- Opens (creates or re-capacities) every enabled stall's pantry and pass. Deterministic ids: a
-- restart finds the same goods. Returns the number of stalls whose containers are open.
function S:openStalls()
    local opened = 0
    for _, key in ipairs(self.cfg.stallOrder) do
        local sc = self.cfg.stalls[key]
        if sc and sc.enabled and self.M.validStallKey(key) then
            local pantry, pass = self.M.stallAccounts(key)
            local stall = self.stalls[key] or { key = key, cfg = sc, pantry = pantry, pass = pass }
            self.stalls[key] = stall
            if not stall.opened then
                local a, awhy = self.L.open(pantry, { capacityG = sc.pantryCapacityG,
                    meta = { app = "rp_streetfood", stall = key, role = "pantry" } })
                local b, bwhy = self.L.open(pass, { capacityG = sc.passCapacityG,
                    meta = { app = "rp_streetfood", stall = key, role = "pass" } })
                if type(a) == "table" and type(b) == "table" then
                    stall.opened = true
                else
                    self:warn("stall %s: containers not open (%s / %s)", key, tostring(awhy), tostring(bwhy))
                end
            end
            if stall.opened then opened = opened + 1 end
        end
    end
    return opened
end

-- A seat's pose: the configured one, refreshed from open77_furniture (A1) when it runs and knows
-- the spot. The profile stays the configured one (A1 lists no player profile for barstools; the
-- barstool twin is A2's).
function S:resolveSeat(seat)
    local pose = { position = seat.position, yaw = seat.yaw, source = "config" }
    if not self.cfg.seating.furnitureLookup or not self.P.running("open77_furniture") then return pose end
    local f, why = self.P.furniture.get(seat.furniture)
    if type(f) ~= "table" then
        self:log("seat %s: open77_furniture answers %s; using the configured pose", tostring(seat.furniture), tostring(why))
        return pose
    end
    for _, p in ipairs(type(f.poseList) == "table" and f.poseList or {}) do
        if tostring(p.spot) == tostring(seat.spot) and p.x then
            local moved = self.M.distance(p, seat.position) or 0
            if moved > 0.05 then
                self:warn("seat %s: catalogue pose is %.2f m from the configured one; using the catalogue's", seat.spot, moved)
            end
            local flags = tonumber(f.flags) or 0
            if flags & (512 | 1024) ~= 0 then
                self:log("seat %s: the crowd may use it too (npcSeated/npcCrowd): B6 coordinates NPC occupancy, this resource does not", seat.furniture)
            end
            return { position = { x = p.x, y = p.y, z = p.z }, yaw = p.yaw, source = "open77_furniture " .. tostring(f.version) }
        end
    end
    return pose
end

local function seatProfileKey(profile)
    return (tostring(profile):gsub("[^%w_]", "_")):sub(1, 38)
end

function S:actionDefinitions()
    local cfg, M = self.cfg, self.M
    local defs, kinds = {}, {}
    local function add(def, kind)
        defs[#defs + 1] = def
        kinds[def.id] = kind
    end
    for _, key in ipairs(cfg.recipeOrder) do
        local r = cfg.recipes[key]
        add({
            id = "cook_" .. key, label = r.label, durationMs = r.durationMs, maxDistance = cfg.maxDistance,
            reserveTimeoutMs = 20000,
            animation = { profile = cfg.stationProfiles[r.station], at = "target" },
            progress = { label = r.progress }, hooks = HOOKS,
            eligibility = cfg.eligibility, epochs = cfg.epochs,
        }, { kind = "cook", recipe = key, station = r.station })
    end
    -- The prompt that starts a hand-over. The hand-over itself is two players under consent:
    -- Open77.playerInteractions, not this library (its lifecycle is single-actor).
    add({
        id = "serve", label = "Serve the next order", durationMs = 750, maxDistance = cfg.maxDistance,
        claim = false, progress = false, claims = false, commitRetries = 0, hooks = PLAIN_HOOKS,
        eligibility = cfg.eligibility, epochs = cfg.epochs,
    }, { kind = "serve" })
    add({
        id = "stock", label = "Stock the pantry from your pockets", durationMs = 2000, maxDistance = cfg.maxDistance,
        claim = false, progress = { label = "Stocking the pantry" }, hooks = PLAIN_HOOKS,
        eligibility = cfg.eligibility, epochs = cfg.epochs,
    }, { kind = "stock" })
    for _, key in ipairs(cfg.menuOrder) do
        local m = cfg.menu[key]
        add({
            id = "order_" .. key, label = ("Order %s (%s)"):format(m.label, M.money(m.price)), durationMs = 2000,
            maxDistance = cfg.maxDistance, claim = false, progress = false, claims = false,
            animation = { profile = cfg.orderProfile, at = "self", loop = false, required = false },
            hooks = PLAIN_HOOKS,
        }, { kind = "order", dish = key })
    end
    local c = cfg.consume
    add({
        id = "eat_counter", label = c.counter.label, durationMs = c.counter.durationMs, maxDistance = cfg.maxDistance,
        animation = { profile = c.counter.profile, at = "target" }, progress = { label = c.counter.progress },
        hooks = HOOKS,
    }, { kind = "eat", place = "counter", dish = "food" })
    add({
        id = "eat_go", label = c.food.label, durationMs = c.food.durationMs, requiresTarget = false,
        animation = { profile = c.food.profile, at = "self" }, progress = { label = c.food.progress },
        hooks = HOOKS,
    }, { kind = "eat", place = "go", dish = "food" })
    add({
        id = "drink_go", label = c.drink.label, durationMs = c.drink.durationMs, requiresTarget = false,
        animation = { profile = c.drink.profile, at = "self" }, progress = { label = c.drink.progress },
        cancelOn = { moved = false }, claims = { attack = true },
        hooks = HOOKS,
    }, { kind = "eat", place = "go", dish = "drink" })
    if cfg.seating.enabled then
        local seen = {}
        for _, stallKey in ipairs(cfg.stallOrder) do
            local sc = cfg.stalls[stallKey]
            for _, seat in ipairs(sc and sc.enabled and sc.seats or {}) do
                if seat.enabled and not seen[seat.profile] then
                    seen[seat.profile] = true
                    add({
                        id = "eat_seat_" .. seatProfileKey(seat.profile), label = c.seat.label,
                        durationMs = c.seat.durationMs, maxDistance = cfg.seating.maxDistance,
                        animation = { profile = seat.profile, at = "target" }, progress = { label = c.seat.progress },
                        hooks = HOOKS,
                    }, { kind = "eat", place = "seat", dish = "any" })
                end
            end
        end
    end
    return defs, kinds
end

local function choices(list, limit, warnFn)
    if #list <= limit then return list end
    warnFn(#list)
    local out = {}
    for i = 1, limit do out[i] = list[i] end
    return out
end

function S:declare()
    local cfg = self.cfg
    local defs, kinds = self:actionDefinitions()
    self.actionKinds = kinds
    for _, def in ipairs(defs) do
        local key, why = self.P.actions.define(def)
        if not key then self:warn("action %s refused by open77_actions: %s", def.id, tostring(why)) end
    end
    self.seats = {}
    local targets = 0
    for _, stallKey in ipairs(cfg.stallOrder) do
        local stall = self.stalls[stallKey]
        if stall and stall.opened then
            local sc = stall.cfg
            local grill = {}
            for _, key in ipairs(cfg.recipeOrder) do
                if cfg.recipes[key].station == sc.grill.station then grill[#grill + 1] = "cook_" .. key end
            end
            grill[#grill + 1] = "serve"
            grill[#grill + 1] = "stock"
            grill = choices(grill, 4, function(n)
                self:warn("stall %s: %d grill choices, a target shows 4 (use /streetfood or the lab for the rest)", stallKey, n)
            end)
            local ok, why = self.P.actions.target({
                id = stallKey .. "_grill", position = sc.grill.position, yaw = sc.grill.yaw, bucket = cfg.bucket,
                label = sc.label, distance = 1.0, actions = grill, data = { stall = stallKey, role = "grill" },
                arrivalRadius = sc.grill.arrivalRadius,
            })
            if ok then targets = targets + 1 else self:warn("grill target %s refused: %s", stallKey, tostring(why)) end
            local counter = {}
            for _, key in ipairs(cfg.menuOrder) do counter[#counter + 1] = "order_" .. key end
            counter = choices(counter, 3, function(n)
                self:warn("stall %s: %d dishes, the counter prompt shows 3 (/streetfood order <dish> for the rest)", stallKey, n)
            end)
            counter[#counter + 1] = "eat_counter"
            ok, why = self.P.actions.target({
                id = stallKey .. "_counter", position = sc.counter.position, yaw = sc.counter.yaw, bucket = cfg.bucket,
                label = sc.label .. " counter", distance = 1.0, actions = counter,
                arrivalRadius = sc.counter.arrivalRadius,
                data = { stall = stallKey, role = "counter" },
            })
            if ok then targets = targets + 1 else self:warn("counter target %s refused: %s", stallKey, tostring(why)) end
            if cfg.seating.enabled then
                for index, seat in ipairs(sc.seats or {}) do
                    if seat.enabled then
                        local pose = self:resolveSeat(seat)
                        local id = ("%s_seat_%d"):format(stallKey, index)
                        local tok, twhy = self.P.actions.target({
                            id = id, position = pose.position, yaw = pose.yaw, bucket = cfg.bucket, label = seat.label,
                            distance = 1.5, actions = { "eat_seat_" .. seatProfileKey(seat.profile) },
                            data = { stall = stallKey, role = "seat", seat = index, furniture = seat.furniture },
                        })
                        if tok then
                            targets = targets + 1
                            self.seats[id] = { stall = stallKey, index = index, label = seat.label, position = pose.position,
                                yaw = pose.yaw, profile = seat.profile, furniture = seat.furniture, source = pose.source }
                        else
                            self:warn("seat target %s refused: %s", id, tostring(twhy))
                        end
                    end
                end
            end
        end
    end
    self.targetCount = targets
    return targets
end

function S:stallOf(ctx)
    local key = type(ctx.target) == "table" and type(ctx.target.data) == "table" and ctx.target.data.stall or nil
    return key and self.stalls[key] or nil
end

-- ---------------------------------------------------------------------------------------------
-- Hooks: validate (synchronous, never yields)
-- ---------------------------------------------------------------------------------------------
function S:validate(ctx)
    if not fromActions() then return false, "not_owner" end
    if not self.ready then return false, "streetfood_unavailable" end
    local kind = self.actionKinds[ctx.actionId]
    if not kind then return false, "unknown_action" end
    local stall = self:stallOf(ctx)
    if kind.kind == "cook" then
        if not stall then return false, "unknown_stall" end
        if stall.cfg.grill.station ~= kind.station then return false, "wrong_station" end
    elseif kind.kind == "serve" and ctx.phase == "begin" then
        if not stall then return false, "unknown_stall" end
        if self.offerOf[ctx.playerId] then
            self:refuseTo(ctx.playerId, "player_reserved")
            return false, "player_reserved"
        end
        if next(self.tickets[stall.key] or {}) == nil then
            self:refuseTo(ctx.playerId, "no_order")
            return false, "no_order"
        end
    elseif kind.kind == "eat" and kind.place == "seat" and not self.cfg.seating.enabled then
        return false, "seating_off"
    end
    return true
end

-- ---------------------------------------------------------------------------------------------
-- Hooks: reserve -> commit, or cancel (cooks and meals)
-- ---------------------------------------------------------------------------------------------
function S:reserve(ctx)
    if not fromActions() then return nil, "not_owner" end
    if not self.P.actions.verify(ctx.opId, "reserve") then return nil, "not_owner" end
    if not self.ready then return nil, "streetfood_unavailable" end
    local kind = self.actionKinds[ctx.actionId]
    if kind and kind.kind == "cook" then return self:reserveCook(ctx, kind) end
    if kind and kind.kind == "eat" then return self:reserveMeal(ctx, kind) end
    return nil, "unknown_action"
end

function S:reserveCook(ctx, kind)
    local cfg, M, L = self.cfg, self.M, self.L
    local stall = self:stallOf(ctx)
    if not stall then return nil, "unknown_stall" end
    local recipe = cfg.recipes[kind.recipe]
    local subject = L.subjectOf(ctx.playerId)
    local txOpId = L.newOpId("cook")
    local held, why = L.reserve({
        opId = txOpId, kind = "streetfood.cook", actor = subject and ("char:" .. subject) or nil,
        reason = ("cook %s at %s"):format(kind.recipe, stall.key), ttlMs = recipe.durationMs + 30000,
        lines = M.cookLines(recipe, stall.pantry, stall.pass, cfg.accounts.kitchen, "cook " .. kind.recipe),
    })
    if not held then
        local token = M.cookRefusal(why)
        self:refuseTo(ctx.playerId, token)
        return nil, token
    end
    local r = { txOpId = txOpId, kind = "cook", recipe = kind.recipe, stall = stall.key, subject = subject,
        pid = ctx.playerId }
    self.work[ctx.opId] = r
    return r
end

function S:reserveMeal(ctx, kind)
    local cfg, M, L = self.cfg, self.M, self.L
    local pid = ctx.playerId
    local subject, swhy = L.subjectOf(pid)
    if not subject then return nil, swhy or "subject_unavailable" end
    local pockets, rwhy = L.read("char:" .. subject)
    if type(pockets) ~= "table" then
        local token = rwhy == "unknown_account" and "no_dish" or (rwhy or "streetfood_unavailable")
        self:refuseTo(pid, token)
        return nil, token
    end
    local available = {}
    for item in pairs(type(pockets.items) == "table" and pockets.items or {}) do available[item] = L.available(pockets, item) end
    local hand = self.hands[pid]
    local wanted = type(ctx.data) == "table" and ctx.data.dish or nil
    local menuKey = M.pickDish(cfg.menu, cfg.menuOrder, kind.dish, available, hand and hand.item, wanted)
    if not menuKey then
        self:refuseTo(pid, "no_dish")
        return nil, "no_dish"
    end
    local entry = cfg.menu[menuKey]
    local txOpId = L.newOpId("meal")
    local held, why = L.reserve({
        opId = txOpId, kind = "streetfood.meal", actor = "char:" .. subject, reason = "eat " .. menuKey,
        ttlMs = (cfg.consume.seat.durationMs or 15000) + 30000,
        lines = { M.eatLine(entry.item, subject, cfg.accounts.eaten) },
    })
    if not held then
        local token = M.eatRefusal(why)
        self:refuseTo(pid, token)
        return nil, token
    end
    -- Presentation: a stationary meal plays its own pose (the takeout workspot brings its own box);
    -- the drink in the hand is put away first. A drink on the go keeps it: the walking layer uses
    -- the item already held (wiki/attachments.md, native hand items).
    local keepsHand = kind.place == "go" and kind.dish == "drink"
    if not keepsHand then self:releaseHand(pid) end
    local r = { txOpId = txOpId, kind = "meal", menu = menuKey, item = entry.item, subject = subject, pid = pid,
        place = kind.place }
    self.work[ctx.opId] = r
    return r
end

function S:commitReserved(ctx)
    local r = ctx.reservation
    if type(r) ~= "table" or not r.txOpId then return nil, "no_reservation" end
    local receipt, why = self.L.commit(r.txOpId)
    if not receipt then
        -- A reservation exists: a coordinator that went away mid-flight leaves the outcome unknown.
        if why == "coordinator_unavailable" then why = "in_doubt" end
        if why == "in_doubt" or why == "busy" then self.doubts[r.txOpId] = r end
        return nil, why
    end
    local ok, err = pcall(self.afterCommit, self, r, receipt)
    if not ok then self:warn("after commit %s raised: %s", r.txOpId, tostring(err)) end
    self.work[ctx.opId] = nil
    return { tx = r.txOpId, kind = r.kind, replay = receipt.replay == true }
end

function S:afterCommit(r, receipt)
    if self.done[r.txOpId] then return end
    self.done[r.txOpId] = self.P.now()
    self.doubts[r.txOpId] = nil
    local cfg = self.cfg
    if r.kind == "cook" then
        self.stats.cooks = self.stats.cooks + 1
        local recipe = cfg.recipes[r.recipe]
        local label = cfg.items[recipe.output.item].label
        local text = ("%s on the pass at %s."):format(label, cfg.stalls[r.stall].label)
        self:record(r.subject, { kind = "cook", opId = r.txOpId, text = text, replay = receipt and receipt.replay == true })
        self:log("cook %s by %s at %s committed: %s", r.txOpId, tostring(r.subject), r.stall, recipe.output.item)
        if self:isSubject(r.pid, r.subject) then self:tell(r.pid, text, "success") end
        return
    end
    -- A meal: the portion is gone. Its needs effect follows once (at most once: a restart between
    -- the commit and this line skips it; it is never applied twice).
    self.stats.meals = self.stats.meals + 1
    local entry = cfg.menu[r.menu]
    local here = self:isSubject(r.pid, r.subject)
    if here then
        self:applyNeeds(r, entry)
        local hand = self.hands[r.pid]
        if hand and hand.item == r.item then self:releaseHand(r.pid) end
    end
    self.P.emit("rp_streetfood:consumed", r.pid, r.item, r.txOpId)
    local text = ("%s: done. %s"):format(entry.label, entry.kind == "drink" and "Refreshing." or "Delicious.")
    self:record(r.subject, { kind = "meal", opId = r.txOpId, text = text, replay = receipt and receipt.replay == true })
    self:log("meal %s by %s committed: %s (%s)", r.txOpId, tostring(r.subject), r.item, tostring(r.place))
    if here then self:tell(r.pid, text, "success") end
end

-- rp_needs:apply when it runs; otherwise the documented hook is the host event alone.
function S:applyNeeds(r, entry)
    if self.needsApplied[r.txOpId] then return end
    self.needsApplied[r.txOpId] = true
    if not entry.needs or not self.P.running("rp_needs") then
        if not self.needsSkipLogged then
            self.needsSkipLogged = true
            self:log("rp_needs is not running: meals move the portion and raise rp_streetfood:consumed only")
        end
        return
    end
    local ok, why = self.P.needs.apply(r.pid, entry.needs, entry.label)
    if ok then
        self.stats.needs = self.stats.needs + 1
    else
        self:warn("rp_needs:apply for %s answered %s", r.txOpId, tostring(why))
    end
end

function S:cancelReserved(ctx)
    self.work[ctx.opId] = nil
    local r = ctx.reservation
    if type(r) ~= "table" or not r.txOpId then return end
    if ctx.reason == "in_doubt" then
        -- The commit may have happened: never cancel; settle with the coordinator's fence.
        self.doubts[r.txOpId] = r
        self.stats.doubts = self.stats.doubts + 1
        self:settle(r)
        return
    end
    self.L.cancel(r.txOpId, ctx.reason)
end

function S:settle(r)
    local outcome, receipt = self.L.settle(r.txOpId)
    if outcome == "committed" then
        self:afterCommit(r, receipt)
    elseif outcome == "failed" or outcome == "aborted" then
        self.doubts[r.txOpId] = nil
        self:log("%s %s settled: %s (nothing moved)", r.kind, r.txOpId, outcome)
        if self:isSubject(r.pid, r.subject) then
            self:tell(r.pid, "The stall could not confirm that: nothing was used, try again.", "warning")
        end
    end
    return outcome
end

-- ---------------------------------------------------------------------------------------------
-- Hooks: commit (every action) and cancel
-- ---------------------------------------------------------------------------------------------
function S:commit(ctx)
    if not fromActions() then return nil, "not_owner" end
    if not self.P.actions.verify(ctx.opId, "commit") then return nil, "not_owner" end
    local kind = self.actionKinds[ctx.actionId]
    if not kind then return nil, "unknown_action" end
    if kind.kind == "cook" or kind.kind == "eat" then return self:commitReserved(ctx) end
    if kind.kind == "order" then return self:placeOrder(ctx, kind) end
    if kind.kind == "serve" then return self:serveNext(ctx) end
    if kind.kind == "stock" then return self:stock(ctx) end
    return nil, "unknown_action"
end

function S:cancelHook(ctx)
    if not fromActions() then return end
    self.opIds[ctx.opId] = nil
    local kind = self.actionKinds[ctx.actionId]
    if kind and (kind.kind == "cook" or kind.kind == "eat") then self:cancelReserved(ctx) end
end

-- ---------------------------------------------------------------------------------------------
-- Orders (no value moves: a ticket in memory)
-- ---------------------------------------------------------------------------------------------
function S:openTicket(stallKey, pid, subject, dish)
    self.ticketSeq = self.ticketSeq + 1
    local t = { stall = stallKey, pid = pid, subject = subject, dish = dish, tip = self.tips[subject] or 0,
        at = self.P.now(), seq = self.ticketSeq }
    self.tickets[stallKey] = self.tickets[stallKey] or {}
    self.tickets[stallKey][subject] = t     -- one open order per customer and stall: a new one replaces it
    self.stats.orders = self.stats.orders + 1
    return t
end

function S:dropTicket(t)
    if not t then return end
    local list = self.tickets[t.stall]
    if list and list[t.subject] and list[t.subject].seq == t.seq then list[t.subject] = nil end
end

function S:placeOrder(ctx, kind)
    local stall = self:stallOf(ctx)
    if not stall then return nil, "unknown_stall" end
    local subject, why = self.L.subjectOf(ctx.playerId)
    if not subject then return nil, NOT_MADE[why] and "streetfood_unavailable" or (why or "subject_unavailable") end
    local entry = self.cfg.menu[kind.dish]
    local t = self:openTicket(stall.key, ctx.playerId, subject, kind.dish)
    local tipText = t.tip > 0 and (" + tip " .. self.M.money(t.tip)) or ""
    self:tell(ctx.playerId, ("Order taken: %s, %s%s. Wait at the counter for the cook."):format(entry.label,
        self.M.money(entry.price), tipText), "info")
    self:log("order %d at %s: %s by %s (tip %d)", t.seq, stall.key, kind.dish, subject, t.tip)
    return { ticket = t.seq, dish = kind.dish }
end

function S:setTip(pid, amount)
    local tip = self.M.validTip(amount, self.cfg.serve.maxTip)
    if not tip then return nil, "invalid_tip" end
    local subject, why = self.L.subjectOf(pid)
    if not subject then return nil, why end
    self.tips[subject] = tip
    for _, list in pairs(self.tickets) do
        if list[subject] then list[subject].tip = tip end
    end
    return tip
end

-- ---------------------------------------------------------------------------------------------
-- The hand-over: a consented two-player step, then ONE rp_economy sale
-- ---------------------------------------------------------------------------------------------
function S:promise(key, delta)
    local n = (self.promised[key] or 0) + delta
    self.promised[key] = n > 0 and n or nil
end

-- Starts a hand-over from `cook` at `stall`: the oldest order whose customer stands within reach
-- and whose portion is ready (on the pass, or in the pantry for resold stock), or `opts.ticket`.
-- Returns the offer, or nil, reason. May yield (reads the stall's containers).
function S:offer(cook, stall, opts)
    opts = opts or {}
    local cfg, M, L, P = self.cfg, self.M, self.L, self.P
    if self.offerOf[cook] then return nil, "player_reserved" end
    local eligible, epoch = P.jobs.eligible(cook, cfg.eligibility.args)
    if not eligible then return nil, epoch or "not_eligible" end
    local cookPos = P.players.position(cook)
    if type(cookPos) ~= "table" then return nil, "position_unavailable" end
    local candidates = opts.ticket and { opts.ticket } or M.ticketsInOrder(self.tickets[stall.key])
    local chosen, entry, source
    for _, t in ipairs(candidates) do
        local e = cfg.menu[t.dish]
        if e and t.pid ~= cook and not t.offerId and self:isSubject(t.pid, t.subject) then
            local pos = P.players.position(t.pid)
            local d = M.distance(cookPos, pos)
            if d and d <= cfg.serve.startDistance and (pos.bucket or 0) == (cookPos.bucket or 0) then
                local from = e.from == "pass" and stall.pass or stall.pantry
                local snap = L.read(from)
                local free = L.available(snap, e.item) - (self.promised[from .. "|" .. e.item] or 0)
                if free >= 1 then
                    chosen, entry, source = t, e, from
                    break
                end
            end
        end
    end
    if not chosen then return nil, "no_order_ready" end
    local cookName = self:nameOf(cook)
    if self.offerOf[cook] then return nil, "player_reserved" end   -- a concurrent offer won while reading
    local customer = chosen.pid
    local holdKey = source .. "|" .. entry.item
    self:promise(holdKey, 1)
    -- The portion in the cook's hand while offered: drinks only (a native record the platform
    -- documents); this resource owns that hand item, the coordinator owns the portion.
    if entry.hand then self:hold(cook, entry.item, entry.hand) end
    -- The offer card says who offers what for how much (Y / N answer it); without a label it read
    -- "Someone wants to give you something.".
    local state, why = P.interactions.request(cook, customer, "give", {
        durationMs = cfg.serve.durationMs, startDistance = cfg.serve.startDistance,
        breakDistance = cfg.serve.breakDistance, inviteTimeoutMs = cfg.serve.inviteTimeoutMs, consent = true,
        label = ("%s: a %s for %s"):format(cookName, entry.label, M.money(entry.price + (chosen.tip or 0))):sub(1, 120),
    })
    if type(state) ~= "table" or not state.id then
        self:promise(holdKey, -1)
        if entry.hand then self:releaseHand(cook) end
        return nil, why or "interactions_unavailable"
    end
    local now = P.now()
    local o = {
        id = state.id, cook = cook, customer = customer, stall = stall.key, menu = chosen.dish, item = entry.item,
        source = source, holdKey = holdKey, price = entry.price, tip = chosen.tip or 0,
        opId = L.newOpId("sale"), epoch = epoch, cookSubject = L.subjectOf(cook), customerSubject = chosen.subject,
        ticket = chosen, at = now, lastSeen = now,
    }
    self.offers[o.id] = o
    self.offerOf[cook] = o.id
    chosen.offerId = o.id            -- no second cook offers this order meanwhile
    local total = o.price + o.tip
    self:tell(customer, ("%s offers you a %s: %s%s = %s. Y to take it and pay, N to decline.")
        :format(cookName, entry.label, M.money(o.price), o.tip > 0 and (" + tip " .. M.money(o.tip)) or "",
        M.money(total)), "info")
    self:tell(cook, ("Offer sent to %s: %s for %s."):format(self:nameOf(customer), entry.label, M.money(total)), "info")
    self:log("offer %s: %s -> %s, %s %d+%d, sale %s", o.id, tostring(o.cookSubject), tostring(o.customerSubject),
        o.item, o.price, o.tip, o.opId)
    return o
end

function S:serveNext(ctx)
    local stall = self:stallOf(ctx)
    if not stall then return nil, "unknown_stall" end
    local o, why = self:offer(ctx.playerId, stall)
    if not o then
        if NOT_MADE[why] then why = "streetfood_unavailable" end
        self:refuseTo(ctx.playerId, why)
        return nil, why
    end
    return { interaction = o.id, sale = o.opId }
end

-- The platform's completion: re-check the cook's shift (same epoch), then pay.
function S:onInteractionCompleted(state)
    local o = type(state) == "table" and self.offers[state.id] or nil
    if not o then return end
    self.offers[o.id] = nil
    if self.offerOf[o.cook] == o.id then self.offerOf[o.cook] = nil end
    self:completeOffer(o)
end

function S:onInteractionCancelled(state)
    local o = type(state) == "table" and self.offers[state.id] or nil
    if not o then return end
    self.offers[o.id] = nil
    if self.offerOf[o.cook] == o.id then self.offerOf[o.cook] = nil end
    local reason = tostring(state.reason or "cancelled")
    if reason:find("declin") or reason:find("reject") then reason = "declined" end
    self:dropOffer(o, reason)
end

function S:completeOffer(o)
    local cfg, M, L, P = self.cfg, self.M, self.L, self.P
    local ok, why = P.jobs.eligible(o.cook, { job = cfg.job, duty = true, epoch = o.epoch })
    if not ok then return self:dropOffer(o, why or "not_eligible") end
    if not self:isSubject(o.customer, o.customerSubject) then return self:dropOffer(o, "customer_gone") end
    -- rp_economy moves the portion out of the stall and into the buyer's pockets inside its own one
    -- operation: this resource (allowed to write both) grants it exactly those two accounts.
    local granted, gwhy = L.authorize(o.opId, "rp_economy", { o.source, "char:" .. o.customerSubject }, 60000)
    if not granted then self:warn("grant for sale %s refused: %s (the sale needs writers for rp_economy)", o.opId, tostring(gwhy)) end
    o.spec = M.saleSpec({
        opId = o.opId, cook = o.cook, customer = o.customer, instrument = cfg.serve.instrument, item = o.item,
        source = o.source, price = o.price, tip = o.tip, society = cfg.society, reason = cfg.serve.reason,
    })
    local receipt, reason = P.economy.sale(o.spec)
    if type(receipt) == "table" then return self:finishSale(o, receipt) end
    if reason == "in_doubt" then
        o.since = P.now()
        self.sales[o.opId] = o
        self.stats.doubts = self.stats.doubts + 1
        self:log("sale %s in doubt: rp_economy settles it, the sweep follows", o.opId)
        self:tell(o.customer, "The payment is still settling: one moment.", "info")
        return
    end
    return self:dropOffer(o, M.saleRefusal(reason), reason)
end

function S:finishSale(o, receipt)
    if self.done[o.opId] then return end
    self.done[o.opId] = self.P.now()
    self.sales[o.opId] = nil
    local cfg, M = self.cfg, self.M
    local entry = cfg.menu[o.menu]
    self:promise(o.holdKey, -1)
    self:dropTicket(o.ticket)
    if self.tips[o.customerSubject] == o.tip then self.tips[o.customerSubject] = nil end   -- a tip is for one order
    -- The hand item follows the portion: out of the cook's hand, into the customer's.
    if entry.hand then
        self:releaseHand(o.cook)
        if self:isSubject(o.customer, o.customerSubject) then self:hold(o.customer, o.item, entry.hand) end
    end
    self.stats.sales = self.stats.sales + 1
    local replay = type(receipt) == "table" and receipt.replay == true
    local total = o.price + o.tip
    self:record(o.customerSubject, { kind = "purchase", opId = o.opId, replay = replay,
        text = ("%s for %s"):format(entry.label, M.money(total)) })
    self:record(o.cookSubject, { kind = "sale", opId = o.opId, replay = replay,
        text = ("%s sold for %s (tip %s)"):format(entry.label, M.money(o.price), M.money(o.tip)) })
    self:log("sale %s committed%s: %s to %s, price %d to soc:%s, tip %d to the cook", o.opId, replay and " (replay)" or "",
        o.item, tostring(o.customerSubject), o.price, cfg.society, o.tip)
    local how = entry.kind == "drink" and "Drink it with /streetfood drink, or sit down."
        or "Eat it at the counter (E), with /streetfood eat, or sit down."
    if self:isSubject(o.customer, o.customerSubject) then
        self:tell(o.customer, ("You paid %s for a %s. %s"):format(M.money(total), entry.label, how), "success")
    end
    if self:isSubject(o.cook, o.cookSubject) then
        self:tell(o.cook, ("Sold: %s, %s to the till%s."):format(entry.label, M.money(o.price),
            o.tip > 0 and (", " .. M.money(o.tip) .. " tip for you") or ""), "success")
    end
    self.P.emit("rp_streetfood:sold", o.cook, o.customer, o.item, o.opId)
end

-- An offer that will not be paid: release the promised portion and the hand item. The order is
-- kept when the failure was the stall's (the cook may offer again, under a new sale id), dropped
-- when the customer declined, left or cannot pay.
function S:dropOffer(o, reason, detail)
    self.sales[o.opId] = nil
    self:promise(o.holdKey, -1)
    local entry = self.cfg.menu[o.menu]
    if entry and entry.hand then self:releaseHand(o.cook) end
    if reason == "declined" then self.stats.declined = self.stats.declined + 1 end
    self.stats.dropped = self.stats.dropped + 1
    if reason == "declined" or reason == "insufficient_funds" or reason == "customer_gone" or reason == "timeout" then
        self:dropTicket(o.ticket)
    elseif o.ticket and o.ticket.offerId == o.id then
        o.ticket.offerId = nil       -- the order waits for another offer
    end
    self:log("offer %s dropped: %s%s (nothing was paid)", tostring(o.id), tostring(reason),
        detail and (" (" .. tostring(detail) .. ")") or "")
    local M = self.M
    if reason == "declined" then
        self:tell(o.cook, ("%s declined the %s."):format(self:nameOf(o.customer), entry and entry.label or "order"), "warning")
    else
        self:tell(o.cook, M.textFor(reason), "warning")
        if self:isSubject(o.customer, o.customerSubject) then self:tell(o.customer, M.textFor(reason), "warning") end
    end
end

-- The cook's shift moved (job, grade, duty): an offer still waiting for consent is withdrawn at
-- once; one already completing is re-checked by completeOffer (epoch in the requirement).
function S:onWorkEpoch(pid, epoch)
    local id = self.offerOf[self.M.playerId(pid) or -1]
    local o = id and self.offers[id]
    if o and o.epoch ~= epoch then
        local _, why = self.P.interactions.cancel(o.id, "stale_job_epoch")
        if why then self:log("offer %s: platform cancel answered %s", o.id, tostring(why)) end
    end
end

-- ---------------------------------------------------------------------------------------------
-- Stocking (rp_inventory moveAsync: pockets -> pantry, one operation)
-- ---------------------------------------------------------------------------------------------
function S:stock(ctx)
    local stall = self:stallOf(ctx)
    if not stall then return nil, "unknown_stall" end
    local pid = ctx.playerId
    local subject, why = self.L.subjectOf(pid)
    if not subject then return nil, why end
    local opId = self.opIds[ctx.opId] or self.L.newOpId("stock")
    self.opIds[ctx.opId] = opId
    local pockets = self.L.read("char:" .. subject)
    local moves = {}
    for _, item in ipairs(self.cfg.stockable) do
        local n = self.L.available(pockets, item)
        if n > 0 then moves[#moves + 1] = { item = item, count = n, from = "char:" .. subject, to = stall.pantry } end
    end
    if #moves == 0 then
        self.opIds[ctx.opId] = nil
        self:refuseTo(pid, "nothing_to_stock")
        return nil, "nothing_to_stock"
    end
    local receipt, mwhy = self.P.inventory.moveAsync(moves, { opId = opId, actor = "char:" .. subject })
    if not receipt then
        if mwhy == "in_doubt" or mwhy == "busy" then return nil, mwhy end    -- retried with the same id
        self.opIds[ctx.opId] = nil
        self:refuseTo(pid, mwhy)
        return nil, mwhy
    end
    self.opIds[ctx.opId] = nil
    self.stats.stocked = self.stats.stocked + 1
    local parts = {}
    for _, m in ipairs(moves) do parts[#parts + 1] = ("%d %s"):format(m.count, self.cfg.items[m.item].label) end
    local text = "Into the pantry: " .. table.concat(parts, ", ") .. "."
    self:record(subject, { kind = "stock", opId = opId, text = text })
    self:tell(pid, text, "success")
    self:log("stock %s by %s at %s: %s", opId, subject, stall.key, table.concat(parts, ", "))
    return { tx = opId, moved = #moves }
end

-- Operator / lab restock: minted from the supplier (a mint rule caps it per hour).
function S:restock(stallKey, amounts)
    local stall = self.stalls[stallKey]
    if not stall or not stall.opened then return nil, "unknown_stall" end
    local lines = self.M.restockLines(amounts or self.cfg.seed, self.cfg.accounts.supplier, stall.pantry, self.cfg.stockable)
    if #lines == 0 then return nil, "nothing_to_stock" end
    local receipt, why = self.L.transfer({ opId = self.L.newOpId("restock"), kind = "streetfood.restock",
        reason = "restock " .. stallKey, lines = lines })
    if receipt then self.stats.restocks = self.stats.restocks + 1 end
    return receipt, why
end

-- ---------------------------------------------------------------------------------------------
-- Hand items (presentation owned by this resource; custody is the coordinator's)
-- ---------------------------------------------------------------------------------------------
function S:hold(pid, item, record)
    local request, why = self.P.held.hold(pid, record)
    if request then
        self.hands[pid] = { item = item, record = record, request = request }
    else
        self:log("hand item %s for player %s refused: %s (presentation only)", tostring(record), tostring(pid), tostring(why))
    end
    return request, why
end

function S:releaseHand(pid)
    if not self.hands[pid] then return end
    self.hands[pid] = nil
    local _, why = self.P.held.release(pid)
    if why then self:log("hand release for player %s answered %s", tostring(pid), tostring(why)) end
end

-- ---------------------------------------------------------------------------------------------
-- Players leaving, the sweep, shutdown
-- ---------------------------------------------------------------------------------------------
function S:onDisconnected(pid)
    pid = self.M.playerId(pid)
    if not pid then return end
    self.hands[pid] = nil            -- the platform removes native hand items on disconnect
    self.notified[pid] = nil
    for _, list in pairs(self.tickets) do
        for subject, t in pairs(list) do if t.pid == pid then list[subject] = nil end end
    end
end

function S:sweep()
    local now = self.P.now()
    for _, r in pairs(self.doubts) do self:settle(r) end
    for opId, o in pairs(self.sales) do
        local st = self.P.economy.status(opId)
        if type(st) == "table" then
            if st.state == "committed" then
                self:finishSale(o, type(st.receipt) == "table" and st.receipt or { opId = opId })
            elseif st.state == "failed" or st.state == "aborted" then
                self:dropOffer(o, "store_unavailable", st.state)
            end
        end
    end
    for _, list in pairs(self.tickets) do
        for subject, t in pairs(list) do
            if now - t.at > self.cfg.serve.ticketTtlMs then list[subject] = nil end
        end
    end
    for id, o in pairs(self.offers) do
        local st = self.P.interactions.get(id)
        if type(st) == "table" then
            o.lastSeen = now
        elseif now - o.lastSeen > self.cfg.lostOfferMs then
            self.offers[id] = nil
            if self.offerOf[o.cook] == id then self.offerOf[o.cook] = nil end
            self:dropOffer(o, "lost")
        end
    end
    for id, at in pairs(self.done) do
        if now - at > 600000 then self.done[id] = nil; self.needsApplied[id] = nil end
    end
end

function S:shutdown()
    -- The coordinator cancels this resource's reservations when it stops; the platform cancels its
    -- interactions and removes its hand items. Nothing durable is held here.
    for pid in pairs(self.hands) do pcall(self.P.held.release, pid) end
    self.hands = {}
end

-- Counts for the console: { items } of a container, with what open offers promised.
function S:stallSnapshot(stall)
    local pantry = self.L.read(stall.pantry)
    local pass = self.L.read(stall.pass)
    return pantry, pass
end

return S
