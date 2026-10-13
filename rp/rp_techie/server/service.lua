-- rp_techie / server/service.lua: the techie's workshop, as hooks of the wave-1 libraries.
--
--   stage     bench target -> action `craft_<recipe>` (bench claim: one techie per bench);
--             reserve hook = ONE coordinator reservation (the inputs out of the pockets or the
--             tray, the room for the outputs in the tray or the pockets); commit hook = that
--             operation (inputs burned, outputs minted); cancel hook = its release
--   menu      bench target -> action `bench_menu` (no claim, no value): the bench's recipes in an
--             open77_uikit menu; the pick is requested as `craft_<recipe>` at that bench
--   buy       dealer target -> action `buy_<dealer>_<item>`: reserve = the lot minted into the
--             pockets + the price burned, ONE reservation; commit; cancel
--   shop      shop target -> action `sell_<shop>`: commit = ONE rp_economy sale (every product of
--             the shop's kind out of the pockets, the price split with the society), quote kept
--             per action so a retried commit asks for exactly the same sale
--   trade     /techie sell | buy, exports.rp_techie:offer: a CONSENTED hand-over
--             (Open77.playerInteractions `give`), a two-player step open77_actions does not run:
--             this file checks the techie's shift (rp_jobs epoch) and, on completion, moves the
--             goods and the price in ONE coordinator operation under the id minted at the offer
--
-- Durable state lives in the coordinator (trays, pockets, wallets). What this file keeps (offers,
-- quotes, in-doubt watchers) is intent: a restart loses an offer, never a part, a component, a
-- product or an eddy.
--
-- Global: TechieService.

TechieService = {}
local S = {}
S.__index = S

local ACTIONS = "open77_actions"
local HOOKS = { validate = "tchValidate", reserve = "tchReserve", commit = "tchCommit", cancel = "tchCancel" }
local PLAIN_HOOKS = { validate = "tchValidate", commit = "tchCommit", cancel = "tchCancel" }

-- Answers that say "the operation may have landed, ask again with the same id".
local DOUBT = { in_doubt = true, busy = true }

function TechieService.new(deps)
    return setmetatable({
        cfg = deps.config, M = deps.model, L = deps.ledger, P = deps.ports,
        resource = deps.resource or "rp_techie",
        workshops = {},      -- [key] = { key, cfg, tray, opened }
        benches = {},        -- [targetId] = { targetId, workshop, key, type, label, position, yaw }
        dealers = {},        -- [key] = { key, cfg, targetId }
        shops = {},          -- [key] = { key, cfg, targetId }
        actionKinds = {},    -- [actionId] = { kind = "craft"|"menu"|"buy"|"shop", ... }
        work = {},           -- [actions opId] = reservation (stage or lot)
        doubts = {},         -- [txOpId] = reservation whose commit is in doubt
        done = {},           -- [txOpId | saleOpId] = ms (its after-commit step ran)
        quotes = {},         -- [actions opId] = shop sale record (retries reuse it)
        sales = {},          -- [saleOpId] = shop sale or trade whose outcome is in doubt
        offers = {},         -- [interactionId] = trade offer
        offerOf = {},        -- [playerId] = interactionId (seller and buyer)
        promised = {},       -- ["<subject>|<item>"] = units promised to open offers
        receipts = {},       -- [subject] = ring of { kind, opId, text, at }
        notified = {},       -- [playerId] = ms of the last refusal toast
        partsDefinedHere = {},
        ready = false,
        stats = { strips = 0, assembles = 0, buys = 0, shopSales = 0, trades = 0, refusals = 0, doubts = 0,
                  declined = 0, dropped = 0, menus = 0 },
    }, S)
end

function S:log(fmt, ...) self.P.log(fmt:format(...)) end
function S:warn(fmt, ...) self.P.warn(fmt:format(...)) end

local function fromActions() return GetInvokingResource() == ACTIONS end
S.fromActions = fromActions

function S:labelOf(item)
    local def = self.cfg.items[item]
    if def then return def.label end
    return self.cfg.partLabels[item] or tostring(item)
end

-- ---------------------------------------------------------------------------------------------
-- Telling players
-- ---------------------------------------------------------------------------------------------
function S:tell(pid, text, kind)
    pid = self.M.playerId(pid)
    if pid then self.P.tell(pid, text, kind) end
end

function S:refuseTo(pid, reason, extra)
    self.stats.refusals = self.stats.refusals + 1
    pid = self.M.playerId(pid)
    if not pid then return end
    local now = self.P.now()
    if (self.notified[pid] or 0) + self.cfg.notifyCooldownMs > now then return end
    self.notified[pid] = now
    local text = self.M.textFor(reason)
    if extra and extra ~= "" then text = text .. " " .. extra end
    self.P.tell(pid, text, "warning")
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

-- The fixer board's hook: one event per committed job step (`ref` is the coordinator op id, so a
-- replayed commit never counts twice: afterCommit runs once per id).
function S:jobCompleted(kind, pid, ref, data)
    self.P.emit("rp:job:completed", { job = self.cfg.jobId, kind = kind, playerId = pid, ref = ref, data = data })
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

-- The salvage parts rp_salvage owns: defined here only when rp_inventory does not know them
-- (a server without rp_salvage), with rp_salvage's own definition.
function S:defineParts()
    local missing, n = {}, 0
    for item, def in pairs(self.cfg.partDefinitions) do
        local known = self.P.inventory.itemDefinition(item)
        if type(known) ~= "table" then
            missing[item] = def
            n = n + 1
        end
    end
    if n == 0 then return 0 end
    local registered = self.P.inventory.define(missing)
    for item in pairs(missing) do self.partsDefinedHere[item] = true end
    self:log("salvage parts defined here (no other definer): %s registered", tostring(registered))
    return n
end

-- Opens (creates or re-capacities) every enabled workshop's tray. Deterministic ids: a restart
-- finds the same components. Returns the number of workshops whose tray is open.
function S:openWorkshops()
    local opened = 0
    for _, key in ipairs(self.cfg.workshopOrder) do
        local wc = self.cfg.workshops[key]
        if wc and wc.enabled and self.M.validKey(key) then
            local ws = self.workshops[key] or { key = key, cfg = wc, tray = self.M.trayAccount(key) }
            self.workshops[key] = ws
            if not ws.opened then
                local snap, why = self.L.open(ws.tray, { capacityG = wc.trayCapacityG,
                    meta = { app = "rp_techie", workshop = key, role = "tray" } })
                if type(snap) == "table" then
                    ws.opened = true
                else
                    self:warn("workshop %s: tray not open (%s)", key, tostring(why))
                end
            end
            if ws.opened then opened = opened + 1 end
        end
    end
    return opened
end

function S:enabledWorkshops()
    local n = 0
    for _, key in ipairs(self.cfg.workshopOrder) do
        local wc = self.cfg.workshops[key]
        if wc and wc.enabled then n = n + 1 end
    end
    return n
end

function S:eligibilityFor(minGrade)
    local args = { job = self.cfg.job, duty = true }
    if (minGrade or 0) > 0 then args.minGrade = minGrade end
    return { resource = self.cfg.eligibility.resource, export = self.cfg.eligibility.export, args = args }
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
        if r then
            add({
                id = "craft_" .. key, label = r.label, durationMs = r.durationMs, maxDistance = cfg.maxDistance,
                reserveTimeoutMs = 20000,
                animation = { profile = cfg.animations[r.animation], at = "target" },
                progress = { label = r.progress or r.label }, hooks = HOOKS,
                eligibility = self:eligibilityFor(r.minGrade), epochs = cfg.epochs,
            }, { kind = "craft", recipe = key })
        end
    end
    -- The bench menu: no claim, no value; the recipe picked in it is requested as its own action.
    add({
        id = "bench_menu", label = "Work at the bench", durationMs = 250, maxDistance = cfg.maxDistance,
        claim = false, progress = false, claims = false, commitRetries = 0, hooks = PLAIN_HOOKS,
        eligibility = self:eligibilityFor(0), epochs = cfg.epochs,
    }, { kind = "menu" })
    for _, dealerKey in ipairs(cfg.dealerOrder) do
        local d = cfg.dealers[dealerKey]
        if d and d.enabled then
            for index, lot in ipairs(d.lots) do
                add({
                    id = ("buy_%s_%s"):format(dealerKey, lot.item),
                    label = ("Buy %d %s (%s)"):format(lot.count, self:labelOf(lot.item), M.money(lot.price)),
                    durationMs = 2000, maxDistance = cfg.maxDistance, claim = false,
                    animation = { profile = cfg.tradeProfile, at = "self", loop = false, required = false },
                    progress = { label = "Buying parts" }, hooks = HOOKS,
                    eligibility = self:eligibilityFor(0), epochs = cfg.epochs,
                }, { kind = "buy", dealer = dealerKey, lot = index })
            end
        end
    end
    for _, shopKey in ipairs(cfg.shopOrder) do
        local sc = cfg.shops[shopKey]
        if sc and sc.enabled then
            add({
                id = "sell_" .. shopKey, label = ("Sell to %s"):format(sc.buyer), durationMs = 2000,
                maxDistance = cfg.maxDistance, claim = false,
                animation = { profile = cfg.tradeProfile, at = "self", loop = false, required = false },
                progress = { label = "Selling" }, hooks = PLAIN_HOOKS,
                eligibility = self:eligibilityFor(0), epochs = cfg.epochs,
            }, { kind = "shop", shop = shopKey })
        end
    end
    return defs, kinds
end

function S:declare()
    local cfg, M = self.cfg, self.M
    local defs, kinds = self:actionDefinitions()
    self.actionKinds = kinds
    for _, def in ipairs(defs) do
        local key, why = self.P.actions.define(def)
        if not key then self:warn("action %s refused by open77_actions: %s", def.id, tostring(why)) end
    end
    self.benches, self.dealers, self.shops = {}, {}, {}
    local targets = 0
    for _, wsKey in ipairs(cfg.workshopOrder) do
        local ws = self.workshops[wsKey]
        if ws and ws.opened then
            for _, b in ipairs(ws.cfg.benches or {}) do
                local id = M.benchTargetId(wsKey, b.key)
                local choices = { "bench_menu" }
                for _, key in ipairs(cfg.recipeOrder) do
                    local r = cfg.recipes[key]
                    if r and r.bench == b.type and #choices < 4 then choices[#choices + 1] = "craft_" .. key end
                end
                local ok, why = self.P.actions.target({
                    id = id, position = b.position, yaw = b.yaw, bucket = cfg.bucket,
                    label = b.label, description = ws.cfg.label, distance = 1.5, actions = choices,
                    arrivalRadius = b.arrivalRadius, data = { workshop = wsKey, bench = b.key, role = "bench" },
                    -- The benches are game workspots: the crowd's workers kneel there too otherwise.
                    keepCrowdOff = b.keepCrowdOff ~= false,
                })
                if ok then
                    targets = targets + 1
                    self.benches[id] = { targetId = id, workshop = wsKey, key = b.key, type = b.type,
                        label = b.label, position = b.position, yaw = b.yaw }
                else
                    self:warn("bench target %s refused: %s", id, tostring(why))
                end
            end
        end
    end
    for _, key in ipairs(cfg.dealerOrder) do
        local d = cfg.dealers[key]
        if d and d.enabled then
            local choices = {}
            for _, lot in ipairs(d.lots) do
                if #choices < 4 then choices[#choices + 1] = ("buy_%s_%s"):format(key, lot.item) end
            end
            local id = "dealer_" .. key
            local ok, why = self.P.actions.target({
                id = id, position = d.position, yaw = d.yaw, bucket = cfg.bucket, label = d.label,
                distance = 2.0, actions = choices, data = { dealer = key, role = "dealer" },
                keepCrowdOff = d.keepCrowdOff ~= false,
            })
            if ok then
                targets = targets + 1
                self.dealers[key] = { key = key, cfg = d, targetId = id }
            else
                self:warn("dealer target %s refused: %s", id, tostring(why))
            end
        end
    end
    for _, key in ipairs(cfg.shopOrder) do
        local sc = cfg.shops[key]
        if sc and sc.enabled then
            local id = "shop_" .. key
            local ok, why = self.P.actions.target({
                id = id, position = sc.position, yaw = sc.yaw, bucket = cfg.bucket, label = sc.label,
                distance = 2.0, actions = { "sell_" .. key }, data = { shop = key, role = "shop" },
            })
            if ok then
                targets = targets + 1
                self.shops[key] = { key = key, cfg = sc, targetId = id }
            else
                self:warn("shop target %s refused: %s", id, tostring(why))
            end
        end
    end
    self.targetCount = targets
    return targets
end

local function targetData(ctx)
    return type(ctx.target) == "table" and type(ctx.target.data) == "table" and ctx.target.data or nil
end

function S:benchOf(ctx)
    local data = targetData(ctx)
    if not data or data.role ~= "bench" then return nil end
    local bench = self.benches[self.M.benchTargetId(tostring(data.workshop), tostring(data.bench))]
    if not bench then return nil end
    local ws = self.workshops[bench.workshop]
    if not ws or not ws.opened then return nil end
    return bench, ws
end

-- ---------------------------------------------------------------------------------------------
-- Hooks: validate (synchronous, never yields)
-- ---------------------------------------------------------------------------------------------
function S:validate(ctx)
    if not fromActions() then return false, "not_owner" end
    if not self.ready then return false, "techie_unavailable" end
    local kind = self.actionKinds[ctx.actionId]
    if not kind then return false, "unknown_action" end
    local data = targetData(ctx)
    if kind.kind == "craft" then
        local bench = self:benchOf(ctx)
        if not bench then return false, "unknown_bench" end
        local recipe = self.cfg.recipes[kind.recipe]
        if not recipe then return false, "unknown_recipe" end
        if recipe.bench ~= bench.type then
            if ctx.phase == "begin" then self:refuseTo(ctx.playerId, "wrong_bench") end
            return false, "wrong_bench"
        end
    elseif kind.kind == "menu" then
        if not self:benchOf(ctx) then return false, "unknown_bench" end
    elseif kind.kind == "buy" then
        if not data or data.role ~= "dealer" or data.dealer ~= kind.dealer or not self.dealers[kind.dealer] then
            return false, "unknown_dealer"
        end
    elseif kind.kind == "shop" then
        if not data or data.role ~= "shop" or data.shop ~= kind.shop or not self.shops[kind.shop] then
            return false, "unknown_shop"
        end
    end
    return true
end

-- ---------------------------------------------------------------------------------------------
-- Hooks: reserve -> commit, or cancel (stages and dealer lots)
-- ---------------------------------------------------------------------------------------------
function S:reserve(ctx)
    if not fromActions() then return nil, "not_owner" end
    if not self.P.actions.verify(ctx.opId, "reserve") then return nil, "not_owner" end
    if not self.ready then return nil, "techie_unavailable" end
    local kind = self.actionKinds[ctx.actionId]
    if kind and kind.kind == "craft" then return self:reserveStage(ctx, kind) end
    if kind and kind.kind == "buy" then return self:reserveLot(ctx, kind) end
    return nil, "unknown_action"
end

function S:reserveStage(ctx, kind)
    local cfg, M, L = self.cfg, self.M, self.L
    local bench, ws = self:benchOf(ctx)
    if not bench then return nil, "unknown_bench" end
    local recipe = cfg.recipes[kind.recipe]
    local pid = ctx.playerId
    local subject, swhy = L.subjectOf(pid)
    if not subject then return nil, swhy or "subject_unavailable" end
    local accounts = { pockets = "char:" .. subject, tray = ws.tray }
    local txOpId = L.newOpId(recipe.stage)
    local held, why = L.reserve({
        opId = txOpId, kind = "techie." .. recipe.stage, actor = accounts.pockets,
        reason = ("%s at %s"):format(kind.recipe, bench.targetId), ttlMs = recipe.durationMs + 30000,
        lines = M.stageLines(recipe, accounts, cfg.accounts.workshop, kind.recipe),
    })
    if not held then
        local lacks
        if why == "insufficient_items" then
            local pockets = L.read(accounts.pockets)
            local tray = L.read(accounts.tray)
            lacks = M.missing(recipe, { pockets = type(pockets) == "table" and pockets or nil,
                tray = type(tray) == "table" and tray or nil })
        end
        local token = M.stageRefusal(why, recipe, lacks)
        local extra = lacks and #lacks > 0 and ("Missing: " .. M.lackText(lacks, function(i) return self:labelOf(i) end) .. ".") or nil
        self:refuseTo(pid, token, extra)
        return nil, token
    end
    local r = { txOpId = txOpId, kind = "craft", recipe = kind.recipe, stage = recipe.stage, bench = bench.targetId,
        workshop = ws.key, subject = subject, pid = pid, ref = ctx.opId }
    self.work[ctx.opId] = r
    return r
end

function S:reserveLot(ctx, kind)
    local cfg, M, L = self.cfg, self.M, self.L
    local dealer = self.dealers[kind.dealer]
    local lot = dealer and dealer.cfg.lots[kind.lot]
    if not lot then return nil, "unknown_dealer" end
    local pid = ctx.playerId
    local subject, swhy = L.subjectOf(pid)
    if not subject then return nil, swhy or "subject_unavailable" end
    local pockets, cash = "char:" .. subject, "cash:" .. subject
    local txOpId = L.newOpId("buy")
    local held, why = L.reserve({
        opId = txOpId, kind = "techie.buy", actor = pockets, reason = "parts from " .. dealer.key, ttlMs = 32000,
        lines = M.dealerLines(lot, pockets, cash, cfg.accounts.dealer, "parts lot"),
    })
    if not held then
        local token = M.dealerRefusal(why)
        self:refuseTo(pid, token)
        return nil, token
    end
    local r = { txOpId = txOpId, kind = "buy", dealer = dealer.key, item = lot.item, count = lot.count, price = lot.price,
        subject = subject, pid = pid, ref = ctx.opId }
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
        if DOUBT[why] then self.doubts[r.txOpId] = r end
        return nil, why
    end
    local ok, err = pcall(self.afterCommit, self, r, receipt)
    if not ok then self:warn("after commit %s raised: %s", r.txOpId, tostring(err)) end
    self.work[ctx.opId] = nil
    return { tx = r.txOpId, kind = r.kind, replay = receipt.replay == true }
end

local function countsOf(list)
    local out = {}
    for _, e in ipairs(list or {}) do out[e.item] = (out[e.item] or 0) + (e.count or 1) end
    return out
end

function S:afterCommit(r, receipt)
    if self.done[r.txOpId] then return end
    self.done[r.txOpId] = self.P.now()
    self.doubts[r.txOpId] = nil
    local cfg, M = self.cfg, self.M
    local here = self:isSubject(r.pid, r.subject)
    local replay = receipt and receipt.replay == true
    if r.kind == "buy" then
        self.stats.buys = self.stats.buys + 1
        local text = ("Bought %d %s for %s."):format(r.count, self:labelOf(r.item), M.money(r.price))
        self:record(r.subject, { kind = "buy", opId = r.txOpId, text = text, replay = replay })
        self:log("buy %s by %s at %s committed: %d %s for %d", r.txOpId, tostring(r.subject), r.dealer, r.count, r.item, r.price)
        if here then self:tell(r.pid, text, "success") end
        self:jobCompleted("buy_parts", r.pid, r.txOpId, { dealer = r.dealer, item = r.item, count = r.count, price = r.price })
        return
    end
    local recipe = cfg.recipes[r.recipe]
    if recipe.stage == "strip" then self.stats.strips = self.stats.strips + 1 else self.stats.assembles = self.stats.assembles + 1 end
    local ws = cfg.workshops[r.workshop]
    local parts = {}
    for _, o in ipairs(recipe.outputs) do
        parts[#parts + 1] = ("%d %s %s"):format(o.count or 1, self:labelOf(o.item),
            (o.to or "pockets") == "tray" and ("on the tray of " .. ws.label) or "in your pockets")
    end
    local text = ("%s: %s."):format(recipe.label, table.concat(parts, ", "))
    self:record(r.subject, { kind = recipe.stage, opId = r.txOpId, text = text, replay = replay })
    self:log("%s %s by %s at %s committed: %s", recipe.stage, r.txOpId, tostring(r.subject), r.bench, r.recipe)
    if here then self:tell(r.pid, text, "success") end
    local outputs, inputs = countsOf(recipe.outputs), countsOf(recipe.inputs)
    self.P.emit("rp_techie:crafted", r.pid, r.recipe, outputs, r.txOpId)
    self:jobCompleted(recipe.stage, r.pid, r.txOpId, { recipe = r.recipe, bench = r.bench, workshop = r.workshop,
        inputs = inputs, outputs = outputs })
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
            self:tell(r.pid, "The workshop could not confirm that: nothing was used, try again.", "warning")
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
    if kind.kind == "craft" or kind.kind == "buy" then return self:commitReserved(ctx) end
    if kind.kind == "menu" then return self:openMenu(ctx) end
    if kind.kind == "shop" then return self:shopSale(ctx, kind) end
    return nil, "unknown_action"
end

function S:cancelHook(ctx)
    if not fromActions() then return end
    local kind = self.actionKinds[ctx.actionId]
    if kind and (kind.kind == "craft" or kind.kind == "buy") then return self:cancelReserved(ctx) end
    if kind and kind.kind == "shop" then
        local rec = self.quotes[ctx.opId]
        self.quotes[ctx.opId] = nil
        if rec and ctx.reason == "in_doubt" and not self.done[rec.opId] then
            -- The sale may have landed: follow it until rp_economy (or the coordinator) knows.
            rec.since = self.P.now()
            self.sales[rec.opId] = rec
            self.stats.doubts = self.stats.doubts + 1
            self:tell(rec.seller, "The shop is still settling the payment: one moment.", "info")
        end
    end
end

-- ---------------------------------------------------------------------------------------------
-- The bench menu (open77_uikit when it runs; a chat list otherwise)
-- ---------------------------------------------------------------------------------------------
function S:openMenu(ctx)
    local bench = self:benchOf(ctx)
    if not bench then return nil, "unknown_bench" end
    local pid = ctx.playerId
    self.stats.menus = self.stats.menus + 1
    self.P.spawn(function()
        local ok, err = pcall(self.showMenu, self, pid, bench)
        if not ok then self:warn("bench menu for %s raised: %s", tostring(pid), tostring(err)) end
    end)
    return { menu = bench.targetId }
end

function S:trayText(ws, snap)
    local parts = {}
    for _, item in ipairs({ "tch_alloy_plate", "tch_wire_loom", "tch_logic_board" }) do
        local n = self.M.available(snap, item)
        if n > 0 then parts[#parts + 1] = ("%d %s"):format(n, self:labelOf(item)) end
    end
    for item, n in pairs(type(snap) == "table" and snap.items or {}) do
        if n > 0 and item ~= "tch_alloy_plate" and item ~= "tch_wire_loom" and item ~= "tch_logic_board" then
            parts[#parts + 1] = ("%d %s"):format(n, self:labelOf(item))
        end
    end
    return #parts > 0 and table.concat(parts, ", ") or "empty"
end

function S:recipesFor(benchType)
    local out = {}
    for _, key in ipairs(self.cfg.recipeOrder) do
        local r = self.cfg.recipes[key]
        if r and (benchType == nil or r.bench == benchType) then out[#out + 1] = key end
    end
    return out
end

function S:showMenu(pid, bench)
    local cfg, M, L, P = self.cfg, self.M, self.L, self.P
    local ws = self.workshops[bench.workshop]
    local subject = L.subjectOf(pid)
    local pockets = subject and L.read("char:" .. subject) or nil
    local tray = L.read(ws.tray)
    local snaps = { pockets = type(pockets) == "table" and pockets or nil, tray = type(tray) == "table" and tray or nil }
    local labelOf = function(i) return self:labelOf(i) end
    local options, lines = {}, {}
    for _, key in ipairs(self:recipesFor(bench.type)) do
        local r = cfg.recipes[key]
        local lacks = M.missing(r, snaps)
        local desc = M.recipeText(r, labelOf)
        if (r.minGrade or 0) > 0 then desc = desc .. (" (grade %d)"):format(r.minGrade) end
        if #lacks > 0 then desc = desc .. ". Missing: " .. M.lackText(lacks, labelOf) end
        options[#options + 1] = { id = key, label = r.label:sub(1, 96), description = desc:sub(1, 240) }
        lines[#lines + 1] = ("%s: %s"):format(key, M.recipeText(r, labelOf))
    end
    local trayLine = ("Tray: %s."):format(self:trayText(ws, snaps.tray))
    if #options > 0 and P.running("open77_uikit") then
        local answer, why = P.uikit.context(pid, {
            id = "rp_techie_bench", title = (("%s, %s"):format(bench.label, ws.cfg.label)):sub(1, 96),
            description = trayLine:sub(1, 240), options = options,
        }, { timeoutMs = cfg.menuTimeoutMs })
        if type(answer) == "table" then
            local pick = answer.ok and type(answer.value) == "table" and answer.value.id or nil
            if pick and cfg.recipes[pick] and cfg.recipes[pick].bench == bench.type then
                -- The player chose; the server checks everything again (distance, claim, job, grade).
                local op, rwhy = P.actions.request(pid, "craft_" .. pick, bench.targetId)
                if not op then self:refuseTo(pid, rwhy) end
            end
            return
        end
        self:log("bench menu for player %s not shown (%s): chat list instead", tostring(pid), tostring(why))
    end
    self:tell(pid, ("%s. %s Recipes: %s. Use /techie craft <recipe>."):format(bench.label, trayLine,
        table.concat(lines, "; ")), "info")
end

-- ---------------------------------------------------------------------------------------------
-- Shop sales: one rp_economy sale (or one coordinator transfer in ledger mode)
-- ---------------------------------------------------------------------------------------------
function S:promiseOf(subject, item) return self.promised[subject .. "|" .. item] or 0 end

function S:shopSale(ctx, kind)
    local cfg, M, L = self.cfg, self.M, self.L
    local shop = self.shops[kind.shop]
    if not shop then return nil, "unknown_shop" end
    local pid = ctx.playerId
    local rec = self.quotes[ctx.opId]
    if rec and self.done[rec.opId] then
        return { sale = rec.opId, total = rec.quote.total, replay = true }
    end
    if not rec then
        local subject, swhy = L.subjectOf(pid)
        if not subject then return nil, swhy or "subject_unavailable" end
        local snap, rwhy = L.read("char:" .. subject)
        if type(snap) ~= "table" then
            local token = rwhy == "unknown_account" and "nothing_to_sell" or (rwhy or "techie_unavailable")
            self:refuseTo(pid, token)
            return nil, token
        end
        local available = {}
        for _, item in ipairs(shop.cfg.accepts or {}) do
            available[item] = math.max(0, M.available(snap, item) - self:promiseOf(subject, item))
        end
        local quote, qwhy = M.shopQuote(shop.cfg, available, cfg.prices, cfg.societyShare, cfg.shopMaxLines)
        if not quote then
            self:refuseTo(pid, qwhy)
            return nil, qwhy
        end
        rec = { opId = L.newOpId("shop"), shop = shop.key, quote = quote, seller = pid, subject = subject,
            mode = cfg.shopPayment == "ledger" and "ledger" or "economy", ref = ctx.opId }
        self.quotes[ctx.opId] = rec
    end
    local receipt, why = self:payShop(rec)
    if type(receipt) == "table" then
        self.quotes[ctx.opId] = nil
        self:finishShopSale(rec, receipt)
        return { sale = rec.opId, total = rec.quote.total, replay = receipt.replay == true }
    end
    if why == "coordinator_unavailable" and rec.mode == "ledger" then why = "in_doubt" end
    if DOUBT[why] then return nil, why end      -- retried with the same record (same id, same lines)
    self.quotes[ctx.opId] = nil
    local token = M.shopRefusal(why)
    self:log("shop sale %s by %s at %s refused: %s", rec.opId, tostring(rec.subject), rec.shop, tostring(why))
    self:refuseTo(pid, token)
    return nil, token
end

function S:payShop(rec)
    local cfg, M = self.cfg, self.M
    if rec.mode == "ledger" then
        return self.L.transfer({
            opId = rec.opId, kind = "techie.shop", actor = "char:" .. rec.subject, reason = "sold to " .. rec.shop,
            lines = M.shopLedgerLines({ quote = rec.quote, pockets = "char:" .. rec.subject, cash = "cash:" .. rec.subject,
                sink = cfg.accounts.shop, society = cfg.society, reason = "techie shop sale" }),
        })
    end
    rec.spec = rec.spec or M.shopSaleSpec({ opId = rec.opId, seller = rec.seller, shop = rec.shop, quote = rec.quote,
        society = cfg.society, reason = "techie shop sale" })
    return self.P.economy.sale(rec.spec)
end

function S:finishShopSale(rec, receipt)
    if self.done[rec.opId] then return end
    self.done[rec.opId] = self.P.now()
    self.sales[rec.opId] = nil
    self.stats.shopSales = self.stats.shopSales + 1
    local cfg, M = self.cfg, self.M
    local shop = cfg.shops[rec.shop]
    local parts, items = {}, {}
    for _, it in ipairs(rec.quote.items) do
        parts[#parts + 1] = ("%d %s"):format(it.count, self:labelOf(it.item))
        items[it.item] = it.count
    end
    local text = ("Sold to %s: %s for %s (%s to you, %s to the %s society)."):format(shop.buyer, table.concat(parts, ", "),
        M.money(rec.quote.total), M.money(rec.quote.seller), M.money(rec.quote.society), cfg.society)
    local replay = type(receipt) == "table" and receipt.replay == true
    self:record(rec.subject, { kind = "shop", opId = rec.opId, text = text, replay = replay })
    self:log("shop sale %s by %s at %s committed%s: total=%d seller=%d society=%d (%s)", rec.opId, tostring(rec.subject),
        rec.shop, replay and " (replay)" or "", rec.quote.total, rec.quote.seller, rec.quote.society, rec.mode)
    if self:isSubject(rec.seller, rec.subject) then self:tell(rec.seller, text, "success") end
    self.P.emit("rp_techie:sold", { kind = "shop", shop = rec.shop, seller = rec.seller, items = items,
        total = rec.quote.total, opId = rec.opId })
    self:jobCompleted("sell", rec.seller, rec.opId, { buyer = "shop:" .. rec.shop, items = items, total = rec.quote.total,
        seller = rec.quote.seller, society = rec.quote.society })
end

-- ---------------------------------------------------------------------------------------------
-- Trades between players: a consented hand-over, then ONE coordinator operation
-- ---------------------------------------------------------------------------------------------
function S:promise(subject, item, delta)
    local key = subject .. "|" .. item
    local n = (self.promised[key] or 0) + delta
    self.promised[key] = n > 0 and n or nil
end

-- spec = { seller, buyer, item, count?, price?, initiator = "seller" | "buyer", via? }. The
-- initiator asked for the trade; the other player (the responder) must accept it. Returns the
-- offer, or nil, reason. May yield (reads the seller's pockets).
function S:startTrade(spec)
    local cfg, M, L, P = self.cfg, self.M, self.L, self.P
    if type(spec) ~= "table" then return nil, "invalid_spec" end
    local seller, buyer = M.playerId(spec.seller), M.playerId(spec.buyer)
    if not seller or not buyer or not P.players.name(seller) or not P.players.name(buyer) then return nil, "unknown_player" end
    if seller == buyer then return nil, "self_trade" end
    local item = spec.item
    local role = M.tradeRole(cfg, item)
    if not role then return nil, "not_tradeable" end
    local count = M.count(spec.count or 1, cfg.trade.maxCount)
    if not count then return nil, "invalid_count" end
    local price
    if spec.price == nil then
        price = ((cfg.prices[item] or {}).suggested or 0) * count
    else
        price = M.price(spec.price, cfg.trade.maxUnitPrice * count)
    end
    if not price then return nil, "invalid_price" end
    local techie = role == "part" and buyer or seller
    local eligible, epoch = P.jobs.eligible(techie, cfg.eligibility.args)
    if not eligible then
        self:log("trade refused: player %d is not an on-duty techie (%s)", techie, tostring(epoch))
        return nil, "techie_required"
    end
    if self.offerOf[seller] or self.offerOf[buyer] then return nil, "player_reserved" end
    local sp, bp = P.players.position(seller), P.players.position(buyer)
    if type(sp) ~= "table" or type(bp) ~= "table" then return nil, "position_unavailable" end
    local d = M.distance(sp, bp)
    if not d or d > cfg.trade.startDistance or (sp.bucket or 0) ~= (bp.bucket or 0) then return nil, "too_far" end
    local sellerSubject, swhy = L.subjectOf(seller)
    local buyerSubject, bwhy = L.subjectOf(buyer)
    if not sellerSubject or not buyerSubject then return nil, swhy or bwhy or "subject_unavailable" end
    local snap = L.read("char:" .. sellerSubject)
    if M.available(snap, item) - self:promiseOf(sellerSubject, item) < count then return nil, "seller_lacks_items" end
    local goods, money = ("%d %s"):format(count, self:labelOf(item)), M.money(price)
    local sellerName, buyerName = self:nameOf(seller), self:nameOf(buyer)
    if self.offerOf[seller] or self.offerOf[buyer] then return nil, "player_reserved" end   -- a concurrent offer won
    local initiator = spec.initiator == "buyer" and buyer or seller
    local responder = initiator == seller and buyer or seller
    -- The offer card says who offers what for how much (Y / N answer it); without a label it read
    -- "Someone wants to give you something.".
    local label = responder == buyer and ("%s: %s for %s"):format(sellerName, goods, money)
        or ("%s: buys %s from you for %s"):format(buyerName, goods, money)
    local state, why = P.interactions.request(initiator, responder, "give", {
        durationMs = cfg.trade.durationMs, startDistance = cfg.trade.startDistance,
        breakDistance = cfg.trade.breakDistance, inviteTimeoutMs = cfg.trade.inviteTimeoutMs, consent = true,
        label = label:sub(1, 120),
    })
    if type(state) ~= "table" or not state.id then return nil, why or "interactions_unavailable" end
    local now = P.now()
    local o = {
        id = state.id, seller = seller, buyer = buyer, techie = techie, role = role, item = item, count = count,
        price = price, initiator = initiator, responder = responder, opId = L.newOpId("trade"), epoch = epoch,
        sellerSubject = sellerSubject, buyerSubject = buyerSubject, at = now, lastSeen = now, via = spec.via or "command",
    }
    self.offers[o.id] = o
    self.offerOf[seller], self.offerOf[buyer] = o.id, o.id
    self:promise(sellerSubject, item, count)
    if responder == buyer then
        self:tell(buyer, ("%s offers to sell you %s for %s. Y to take it and pay, N to decline.")
            :format(sellerName, goods, money), "info")
    else
        self:tell(seller, ("%s wants to buy %s from you for %s. Y to sell, N to decline.")
            :format(buyerName, goods, money), "info")
    end
    self:tell(initiator, ("Offer sent to %s: %s for %s."):format(self:nameOf(responder), goods, money), "info")
    self:log("trade offer %s: %s -> %s, %d %s for %d (%s, techie %d), sale %s", o.id, tostring(sellerSubject),
        tostring(buyerSubject), count, item, price, role, techie, o.opId)
    return o
end

function S:releaseOffer(o)
    self.offers[o.id] = nil
    if self.offerOf[o.seller] == o.id then self.offerOf[o.seller] = nil end
    if self.offerOf[o.buyer] == o.id then self.offerOf[o.buyer] = nil end
end

function S:onInteractionCompleted(state)
    local o = type(state) == "table" and self.offers[state.id] or nil
    if not o then return end
    self:releaseOffer(o)
    self:completeTrade(o)
end

function S:onInteractionCancelled(state)
    local o = type(state) == "table" and self.offers[state.id] or nil
    if not o then return end
    self:releaseOffer(o)
    local reason = tostring(state.reason or "cancelled")
    if reason:find("declin") or reason:find("reject") then reason = "declined" end
    if reason == "disconnected" then reason = "gone" end
    self:dropTrade(o, reason)
end

-- The platform's completion: re-check the techie's shift (same epoch) and both players, then move
-- the goods and the price in ONE coordinator operation under the id minted at the offer.
function S:completeTrade(o)
    local cfg, M, L, P = self.cfg, self.M, self.L, self.P
    local ok, why = P.jobs.eligible(o.techie, { job = cfg.job, duty = true, epoch = o.epoch })
    if not ok then return self:dropTrade(o, why or "not_eligible") end
    if not self:isSubject(o.seller, o.sellerSubject) or not self:isSubject(o.buyer, o.buyerSubject) then
        return self:dropTrade(o, "gone")
    end
    local receipt, reason = L.transfer({
        opId = o.opId, kind = "techie.trade", actor = "char:" .. o.sellerSubject,
        reason = ("trade %s"):format(o.item), lines = M.tradeLines(o),
    })
    if type(receipt) == "table" then return self:finishTrade(o, receipt) end
    if reason == "coordinator_unavailable" then reason = "in_doubt" end
    if DOUBT[reason] then
        o.since = P.now()
        o.kind = "trade"
        self.sales[o.opId] = o
        self.stats.doubts = self.stats.doubts + 1
        self:log("trade %s in doubt: the sweep settles it", o.opId)
        self:tell(o.buyer, "The payment is still settling: one moment.", "info")
        self:tell(o.seller, "The payment is still settling: one moment.", "info")
        return
    end
    return self:dropTrade(o, M.tradeRefusal(reason), reason)
end

function S:finishTrade(o, receipt)
    if self.done[o.opId] then return end
    self.done[o.opId] = self.P.now()
    self.sales[o.opId] = nil
    self:promise(o.sellerSubject, o.item, -o.count)
    self.stats.trades = self.stats.trades + 1
    local M = self.M
    local replay = type(receipt) == "table" and receipt.replay == true
    local what = ("%d %s for %s"):format(o.count, self:labelOf(o.item), M.money(o.price))
    self:record(o.buyerSubject, { kind = "bought", opId = o.opId, text = "Bought " .. what, replay = replay })
    self:record(o.sellerSubject, { kind = "sold", opId = o.opId, text = "Sold " .. what, replay = replay })
    self:log("trade %s committed%s: %d %s from %s to %s for %d", o.opId, replay and " (replay)" or "", o.count, o.item,
        tostring(o.sellerSubject), tostring(o.buyerSubject), o.price)
    if self:isSubject(o.buyer, o.buyerSubject) then
        self:tell(o.buyer, ("You bought %s from %s."):format(what, self:nameOf(o.seller)), "success")
    end
    if self:isSubject(o.seller, o.sellerSubject) then
        self:tell(o.seller, ("You sold %s to %s."):format(what, self:nameOf(o.buyer)), "success")
    end
    self.P.emit("rp_techie:sold", { kind = "player", seller = o.seller, buyer = o.buyer, items = { [o.item] = o.count },
        total = o.price, opId = o.opId, role = o.role })
    if o.role == "product" then
        self:jobCompleted("sell", o.seller, o.opId, { buyer = "player", buyerId = o.buyer, items = { [o.item] = o.count },
            total = o.price })
    else
        self:jobCompleted("buy_parts", o.buyer, o.opId, { seller = "player", sellerId = o.seller, item = o.item,
            count = o.count, price = o.price })
    end
end

-- An offer that will not be paid: release the promised goods and tell both sides.
function S:dropTrade(o, reason, detail)
    self.sales[o.opId] = nil
    self:promise(o.sellerSubject, o.item, -o.count)
    if reason == "declined" then self.stats.declined = self.stats.declined + 1 end
    self.stats.dropped = self.stats.dropped + 1
    self:log("trade offer %s dropped: %s%s (nothing was paid)", tostring(o.id), tostring(reason),
        detail and (" (" .. tostring(detail) .. ")") or "")
    if reason == "declined" then
        self:tell(o.initiator, ("%s declined the trade."):format(self:nameOf(o.responder)), "warning")
        return
    end
    local text = self.M.textFor(reason)
    if self:isSubject(o.seller, o.sellerSubject) then self:tell(o.seller, text, "warning") end
    if self:isSubject(o.buyer, o.buyerSubject) then self:tell(o.buyer, text, "warning") end
end

-- Withdraws the pending offer `pid` takes part in (the initiator changed their mind).
function S:withdraw(pid)
    local id = self.offerOf[self.M.playerId(pid) or -1]
    if not id then return nil, "no_offer" end
    local _, why = self.P.interactions.cancel(id, "withdrawn")
    return true, why
end

-- The techie's shift moved (job, grade, duty): an offer still waiting for consent is withdrawn at
-- once; one already completing is re-checked by completeTrade (epoch in the requirement).
function S:onWorkEpoch(pid, epoch)
    local id = self.offerOf[self.M.playerId(pid) or -1]
    local o = id and self.offers[id]
    if o and o.techie == pid and o.epoch ~= epoch then
        local _, why = self.P.interactions.cancel(o.id, "stale_job_epoch")
        if why then self:log("offer %s: platform cancel answered %s", o.id, tostring(why)) end
    end
end

-- ---------------------------------------------------------------------------------------------
-- Players leaving, the sweep, shutdown
-- ---------------------------------------------------------------------------------------------
function S:onDisconnected(pid)
    pid = self.M.playerId(pid)
    if not pid then return end
    self.notified[pid] = nil
    -- The platform cancels the interaction (onPlayerInteractionCancelled drops the offer).
end

function S:settleSale(rec)
    if rec.kind == "trade" or rec.mode == "ledger" then
        local outcome, receipt = self.L.settle(rec.opId)
        if outcome == "committed" then
            if rec.kind == "trade" then self:finishTrade(rec, receipt) else self:finishShopSale(rec, receipt) end
        elseif outcome == "failed" or outcome == "aborted" then
            self.sales[rec.opId] = nil
            if rec.kind == "trade" then
                self:dropTrade(rec, "techie_unavailable", outcome)
            else
                self:tell(rec.seller, "The shop could not confirm the sale: nothing was sold.", "warning")
            end
        end
        return outcome
    end
    local st = self.P.economy.status(rec.opId)
    if type(st) == "table" then
        if st.state == "committed" then
            self:finishShopSale(rec, type(st.receipt) == "table" and st.receipt or { opId = rec.opId })
        elseif st.state == "failed" or st.state == "aborted" then
            self.sales[rec.opId] = nil
            self:tell(rec.seller, "The shop could not confirm the sale: nothing was sold.", "warning")
        end
        return st.state
    end
    return "pending"
end

-- The values of a table, copied first: settling yields, and other threads may add entries meanwhile.
local function valuesOf(t)
    local out = {}
    for _, v in pairs(t) do out[#out + 1] = v end
    return out
end

function S:sweep()
    local now = self.P.now()
    for _, r in ipairs(valuesOf(self.doubts)) do
        if self.doubts[r.txOpId] == r then self:settle(r) end
    end
    for _, rec in ipairs(valuesOf(self.sales)) do
        if self.sales[rec.opId] == rec then self:settleSale(rec) end
    end
    for _, o in ipairs(valuesOf(self.offers)) do
        local st = self.P.interactions.get(o.id)
        if type(st) == "table" then
            o.lastSeen = now
        elseif self.offers[o.id] == o and now - o.lastSeen > self.cfg.lostOfferMs then
            self:releaseOffer(o)
            self:dropTrade(o, "lost")
        end
    end
    for id, at in pairs(self.done) do
        if now - at > 600000 then self.done[id] = nil end
    end
end

function S:shutdown()
    -- The coordinator cancels this resource's reservations when it stops; the platform cancels its
    -- interactions. Nothing durable is held here.
    self.ready = false
end

-- ---------------------------------------------------------------------------------------------
-- Read helpers for exports and the console
-- ---------------------------------------------------------------------------------------------
function S:itemInfo(item)
    local cfg = self.cfg
    local def = cfg.items[item]
    local price = cfg.prices[item] or {}
    return { id = item, label = self:labelOf(item), category = def and def.category or "material",
        weightG = cfg.weightsG[item], shopPrice = price.shop, suggestedPrice = price.suggested }
end

function S:listInfo(list)
    local out = {}
    for _, item in ipairs(list) do out[#out + 1] = self:itemInfo(item) end
    return out
end

function S:catalogue()
    local cfg = self.cfg
    local recipes = {}
    for _, key in ipairs(cfg.recipeOrder) do
        local r = cfg.recipes[key]
        if r then
            recipes[#recipes + 1] = { id = key, stage = r.stage, bench = r.bench, minGrade = r.minGrade or 0,
                durationMs = r.durationMs, inputs = countsOf(r.inputs), outputs = countsOf(r.outputs) }
        end
    end
    local components = {}
    for item, def in pairs(cfg.items) do
        if def.category == "component" then components[#components + 1] = item end
    end
    table.sort(components)
    return { parts = self:listInfo(cfg.parts), intermediates = self:listInfo(components),
        products = self:listInfo(cfg.products), cyberware = self:listInfo(cfg.cyberwareComponents), recipes = recipes }
end

-- The bench of `benchType` nearest to the player, within `radius`.
function S:nearestBench(pid, benchType, radius)
    local pos = self.P.players.position(pid)
    local best, bestD
    for _, bench in pairs(self.benches) do
        if benchType == nil or bench.type == benchType then
            local d = self.M.distance(pos, bench.position)
            if d and d <= radius and (not bestD or d < bestD) then best, bestD = bench, d end
        end
    end
    return best
end

function S:nearestWorkshop(pid, radius)
    local bench = self:nearestBench(pid, nil, radius)
    return bench and self.workshops[bench.workshop] or nil
end

return S
