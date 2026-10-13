-- rp_netrunner / server/service.lua: breach contracts, as hooks of the job libraries.
--
--   post      a fixer (the NPC board, a player fixer, another resource) puts a contract on the
--             board: ONE coordinator operation mints the contract instance `nrc.<id>` into the
--             board stash, its metadata being the contract (site, reward, cut, deadline, state)
--   take      a netrunner takes an open contract: ONE operation patches the instance (taker,
--             state "taken"); one taker wins, a second is refused
--   breach    site target -> action `breach_<site>`: reserve hook = ONE reservation (the breach kit
--             burned, the contract patched, and on a success the shard `nrs.<id>` minted into the
--             runner's pockets); the outcome is rolled from the operation id and the runner's
--             grade before the bar; commit hook = that operation; cancel hook = its release.
--             A failure is a trace: NCPD dispatch, a record entry, native heat
--   deliver   the fixer drop -> action `deliver`, or a consented hand-over to the player fixer
--             (Open77.playerInteractions `give`): ONE rp_economy sale burns the shard, creates the
--             client's money and pays the runner and the fixer's cut; the contract instance is
--             retired right after (and found again at boot if a restart fell in between)
--   expire    the sweep retires contracts past their deadline (a breached one with its shard)
--
-- Durable state lives in the coordinator: the board stash (contracts), the pockets (shards, kits),
-- rp_economy (money). What this file keeps (the cache of the board, offers, site alerts, heat) is
-- rebuilt from the board at boot or is presentation: a restart loses an offer, never a contract,
-- a shard or an eddy.
--
-- Global: NetrunnerService.

NetrunnerService = {}
local S = {}
S.__index = S

local ACTIONS = "open77_actions"
local HOOKS = { validate = "nrValidate", reserve = "nrReserve", commit = "nrCommit", cancel = "nrCancel" }
local PLAIN_HOOKS = { validate = "nrValidate", commit = "nrCommit" }

-- Refusals that say nothing was applied by THIS attempt (open77_actions retries them).
local TRANSIENT = { store_unavailable = true, coordinator_unavailable = true, conflict = true }

function NetrunnerService.new(deps)
    return setmetatable({
        cfg = deps.config, M = deps.model, L = deps.ledger, P = deps.ports, shared = deps.shared,
        resource = deps.resource or "rp_netrunner",
        ready = false,
        sites = {},          -- [siteKey] = site config (enabled)
        fixers = {},         -- [fixerKey] = fixer drop config
        actionKinds = {},    -- [actionId] = { kind = "breach"|"talk"|"deliver"|"gesture", site? }
        contracts = {},      -- [contractId] = record (the board, as last read)
        versions = {},       -- [contractId] = instance version
        byCode = {},         -- [code] = contractId
        activeOf = {},       -- [subject] = contractId (taken or breached)
        siteOf = {},         -- [siteKey] = contractId (a live contract on that site)
        boardLoaded = false,
        skipped = {},        -- [iid] = true: a board instance that is not a valid record (logged once)
        locks = {},          -- [contractId] = what is in flight on it (one operation of ours at a time)
        siteLocks = {},      -- [siteKey] = true while a post on that site is in flight
        work = {},           -- [actions opId] = breach reservation
        doubts = {},         -- [txOpId] = breach reservation whose commit is in doubt
        done = {},           -- [txOpId | saleOpId] = ms (its after-commit step ran)
        sales = {},          -- [saleOpId] = delivery whose sale is in doubt
        attempts = {},       -- [contractId] = delivery attempt (bumped when an attempt was fenced)
        pendingOps = {},     -- [opId] = what an in-doubt transfer was (settled by the sweep)
        retirePending = {},  -- [contractId] = why: a delivered / failed contract still on the board
        reconciled = {},     -- [contractId] = true once a breached contract was checked after boot
        offers = {},         -- [interactionId] = hand-over to a player fixer
        offerOf = {},        -- [runnerPid] = interactionId
        alerts = {},         -- [siteKey] = ms until the site's ICE calms down
        heat = {},           -- [playerId] = { level, before, untilMs }
        notified = {},       -- [playerId] = ms of the last refusal toast
        online = {},         -- [subject] = playerId (best effort, checked before use)
        lastNpcPost = 0,
        stats = { posted = 0, taken = 0, breaches = 0, failures = 0, deliveries = 0, expired = 0, cancelled = 0,
                  abandoned = 0, traces = 0, refusals = 0, doubts = 0 },
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
    if pid and self.P.players.name(pid) then self.P.tell(pid, text, kind) end
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

-- The character name (rp_identity) when it runs, else the account name. Live 2026-10-13: the fixer
-- read "CyberwareA took your contract 5RJ6." for Ada Kovac.
function S:nameOf(pid)
    local ok, full = pcall(Open77.exports.callSync, "rp_identity", "fullName", pid)
    if ok and type(full) == "string" and full ~= "" and full ~= "Unknown citizen" then return full end
    return self.P.players.name(pid) or ("player " .. tostring(pid))
end

-- The connected player of a durable subject, or nil (subjects survive reconnects, ids do not).
function S:pidOf(subject)
    if type(subject) ~= "string" then return nil end
    local pid = self.online[subject]
    if pid and self.P.players.name(pid) and self.L.subjectOf(pid) == subject then return pid end
    self.online[subject] = nil
    for _, id in ipairs(self.P.players.all()) do
        if self.L.subjectOf(id) == subject then
            self.online[subject] = id
            return id
        end
    end
    return nil
end

function S:isSubject(pid, subject)
    return pid ~= nil and subject ~= nil and self.P.players.name(pid) ~= nil and self.L.subjectOf(pid) == subject
end

function S:tellSubject(subject, pid, text, kind)
    if pid and self:isSubject(pid, subject) then return self:tell(pid, text, kind) end
    local now = self:pidOf(subject)
    if now then self:tell(now, text, kind) end
end

-- ---------------------------------------------------------------------------------------------
-- Boot steps (re-run whenever a library restarts)
-- ---------------------------------------------------------------------------------------------
function S:loadConfig()
    self.sites, self.fixers = {}, {}
    for _, site in ipairs(self.cfg.sites) do
        if site.enabled ~= false and self.cfg.tiers[site.tier] and self.cfg.poses[site.pose] then
            self.sites[site.key] = site
        elseif site.enabled ~= false then
            self:warn("site %s skipped: unknown tier %s or pose %s", tostring(site.key), tostring(site.tier), tostring(site.pose))
        end
    end
    for _, fixer in ipairs(self.cfg.fixers) do self.fixers[fixer.key] = fixer end
end

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

-- The board stash (deterministic id: created once, found again after a restart).
function S:openBoard()
    local board, why = self.L.open(self.cfg.accounts.board, { capacityG = self.cfg.boardCapacityG,
        meta = { app = "rp_netrunner", role = "board" } })
    if type(board) ~= "table" then
        self:warn("contract board %s not open: %s", self.cfg.accounts.board, tostring(why))
        return false, why
    end
    return true
end

-- Re-reads the board and rebuilds the cache from it. The coordinator is the truth: every
-- mutation of ours is followed by a refresh, and the sweep refreshes too.
function S:refresh()
    -- The coordinator keeps the board loaded: the synchronous read answers at once (no yield), so
    -- the cache is current before the hook that changed it returns. The asynchronous read is the
    -- fallback when it is not loaded yet (boot, a coordinator restart).
    local snap, why = self.L.readLoaded(self.cfg.accounts.board)
    if type(snap) ~= "table" then snap, why = self.L.read(self.cfg.accounts.board) end
    if type(snap) ~= "table" then return false, why end
    self:rebuild(snap)
    return true
end

function S:rebuild(snap)
    local M = self.M
    local contracts, versions, byCode, activeOf, siteOf = {}, {}, {}, {}, {}
    for iid, inst in pairs(type(snap.instances) == "table" and snap.instances or {}) do
        local id = M.contractIdOfIid(iid)
        local meta = type(inst) == "table" and inst.meta or nil
        if id and inst.item == "nr_contract" and M.validRecord(meta) and meta.id == id then
            contracts[id] = meta
            versions[id] = inst.version
            byCode[meta.code] = id
            if meta.state ~= "open" and type(meta.taker) == "string" then activeOf[meta.taker] = id end
            siteOf[meta.site] = id
        elseif not self.skipped[iid] then
            self.skipped[iid] = true
            self:warn("board instance %s is not a contract record of this version: left alone", tostring(iid))
        end
    end
    self.contracts, self.versions, self.byCode, self.activeOf, self.siteOf = contracts, versions, byCode, activeOf, siteOf
    self.boardLoaded = true
end

function S:actionDefinitions()
    local cfg = self.cfg
    local defs, kinds = {}, {}
    local function add(def, kind)
        defs[#defs + 1] = def
        kinds[def.id] = kind
    end
    local keys = {}
    for key in pairs(self.sites) do keys[#keys + 1] = key end
    table.sort(keys)
    for _, key in ipairs(keys) do
        local site = self.sites[key]
        local tier = cfg.tiers[site.tier]
        local pose = cfg.poses[site.pose]
        add({
            id = "breach_" .. key, label = "Breach the terminal", durationMs = tier.durationMs,
            maxDistance = cfg.maxDistance, reserveTimeoutMs = 20000,
            animation = { profile = pose.profile, at = pose.at or "target", required = pose.required == true,
                arrivalRadius = pose.arrivalRadius },
            progress = { label = "Breaching the ICE" }, hooks = HOOKS,
            eligibility = cfg.eligibility, epochs = cfg.epochs,
        }, { kind = "breach", site = key })
    end
    -- The fixer drop: one prompt. With a shard for that drop it starts the delivery, otherwise
    -- it opens the board (open77_uikit), both from the transition of this short action.
    add({
        id = "talk", label = "Talk to the fixer", durationMs = cfg.board.durationMs, maxDistance = cfg.maxDistance,
        claim = false, progress = false, claims = false, commitRetries = 0,
        animation = cfg.board.animation, hooks = PLAIN_HOOKS,
    }, { kind = "talk" })
    add({
        id = "deliver", label = "Deliver the data shard", durationMs = cfg.deliver.durationMs,
        maxDistance = cfg.maxDistance, animation = cfg.deliver.animation, claim = false,
        progress = { label = "Handing over the shard" }, hooks = HOOKS,
        eligibility = cfg.eligibility, epochs = cfg.epochs,
    }, { kind = "deliver" })
    -- The tap on the deck a ping or a jammer plays (quickhacks): presentation, no value, no bar.
    local g = self.shared and self.shared.gesture
    if g then
        add({
            id = "qh_tap", label = "Quickhack", durationMs = g.durationMs, requiresTarget = false,
            claim = false, progress = false, claims = false, commitRetries = 0,
            animation = { profile = g.profile, at = "self", loop = false, required = false }, hooks = PLAIN_HOOKS,
        }, { kind = "gesture" })
    end
    return defs, kinds
end

function S:declare()
    local cfg = self.cfg
    local defs, kinds = self:actionDefinitions()
    self.actionKinds = kinds
    for _, def in ipairs(defs) do
        local key, why = self.P.actions.define(def)
        if not key then self:warn("action %s refused by open77_actions: %s", def.id, tostring(why)) end
    end
    local targets = 0
    for key, site in pairs(self.sites) do
        local ok, why = self.P.actions.target({
            id = "site_" .. key, position = site.position, yaw = site.yaw, bucket = cfg.bucket,
            label = site.label, description = site.area, distance = cfg.promptDistance,
            actions = { { action = "breach_" .. key, label = "Breach the terminal" } },
            arrivalRadius = cfg.poses[site.pose].arrivalRadius, data = { site = key }, color = "#00E5FF",
            -- The terminals are game work spots: keep the server crowd's office workers off them.
            keepCrowdOff = site.keepCrowdOff ~= false,
        })
        if ok then targets = targets + 1 else self:warn("site target %s refused: %s", key, tostring(why)) end
    end
    for key, fixer in pairs(self.fixers) do
        local ok, why = self.P.actions.target({
            id = "fixer_" .. key, position = fixer.position, yaw = fixer.yaw, bucket = cfg.bucket,
            label = fixer.label, description = "Contracts board, shard drop", distance = cfg.promptDistance,
            actions = { { action = "talk", label = "Talk to the fixer" } }, data = { fixer = key }, color = "#00E5FF",
        })
        if ok then targets = targets + 1 else self:warn("fixer target %s refused: %s", key, tostring(why)) end
    end
    self.targetCount = targets
    return targets
end

-- ---------------------------------------------------------------------------------------------
-- Reading the board
-- ---------------------------------------------------------------------------------------------
function S:find(ref)
    if type(ref) ~= "string" then return nil end
    if self.contracts[ref] then return self.contracts[ref] end
    local code = self.M.normalizeCode(ref)
    local id = code and self.byCode[code]
    return id and self.contracts[id] or nil
end

function S:activeContract(subject)
    local id = subject and self.activeOf[subject]
    return id and self.contracts[id] or nil
end

function S:summaryOf(c)
    return self.M.summary(c, self.sites[c.site], self.cfg.tiers[c.tier], self.P.nowS())
end

-- Contracts sorted for display: open first, then by tier and deadline.
function S:sorted(filter)
    local list = {}
    for _, c in pairs(self.contracts) do
        local keep = true
        if type(filter) == "table" then
            if filter.state and c.state ~= filter.state then keep = false end
            if filter.site and c.site ~= filter.site then keep = false end
            if filter.poster and c.poster ~= filter.poster then keep = false end
            if filter.fixer and c.fixer ~= filter.fixer then keep = false end
        end
        if keep then list[#list + 1] = c end
    end
    local rank = { open = 1, taken = 2, breached = 3 }
    table.sort(list, function(a, b)
        if rank[a.state] ~= rank[b.state] then return rank[a.state] < rank[b.state] end
        if a.tier ~= b.tier then return a.tier < b.tier end
        if a.deadline ~= b.deadline then return a.deadline < b.deadline end
        return a.id < b.id
    end)
    return list
end

function S:emitContract(phase, c, extra)
    local summary = self:summaryOf(c)
    if extra then for k, v in pairs(extra) do summary[k] = v end end
    self.P.emit("rp_netrunner:contract", phase, summary)
end

-- The job event the fixer board listens to (rp:job:completed), one per committed step.
function S:jobCompleted(kind, pid, ref, c, data)
    local payload = { contract = c.id, code = c.code, site = c.site, tier = c.tier, reward = c.reward, cut = c.cut,
        poster = c.poster, fixer = c.fixer, point = c.point }
    for k, v in pairs(data or {}) do payload[k] = v end
    self.P.emit("rp:job:completed", { job = self.cfg.job, kind = kind, playerId = pid, ref = ref, data = payload })
end

-- ---------------------------------------------------------------------------------------------
-- Posting (yields)
-- ---------------------------------------------------------------------------------------------
-- spec = { site, reward?, minutes?, fixer = playerId? (a player fixer), poster = "npc"?, point?,
--          name? (the poster's name for an NPC / a resource) }
function S:post(spec)
    local cfg, M, L, P = self.cfg, self.M, self.L, self.P
    if not self.ready then return nil, "netrunner_unavailable" end
    if type(spec) ~= "table" then return nil, "invalid_spec" end
    local site = type(spec.site) == "string" and self.sites[spec.site] or nil
    if not site then
        local known = false
        for _, s in ipairs(cfg.sites) do if s.key == spec.site then known = true end end
        return nil, known and "site_disabled" or "unknown_site"
    end
    local tier = cfg.tiers[site.tier]
    local poster, fixer, fixerName = "npc", nil, nil
    local fixerPid = spec.fixer ~= nil and M.playerId(spec.fixer) or nil
    if spec.fixer ~= nil then
        if not fixerPid or not P.players.name(fixerPid) then return nil, "player_not_found" end
        local ok, why = P.jobs.eligible(fixerPid, cfg.fixerRequirement)
        if not ok then return nil, (why == "no_job" or why == "wrong_job") and "not_fixer" or (why or "not_fixer") end
        local subject, swhy = L.subjectOf(fixerPid)
        if not subject then return nil, swhy or "no_pockets" end
        poster, fixer, fixerName = "player", subject, self:nameOf(fixerPid)
    end
    local reward, rwhy
    if poster == "npc" and spec.reward == nil then
        reward = M.npcReward(tier, tostring(spec.seed or P.now()) .. site.key, cfg.npcBoard.round)
    else
        reward, rwhy = M.reward(tier, spec.reward)
        if not reward then return nil, rwhy end
    end
    local minutes, mwhy = M.minutes(tier, spec.minutes)
    if not minutes then return nil, mwhy end
    local point = spec.point or cfg.npcBoard.fixer
    if not self.fixers[point] then point = cfg.fixers[1] and cfg.fixers[1].key end
    if not point then return nil, "no_fixer_drop" end
    if poster == "npc" then
        local drop = self.fixers[point]
        fixer, fixerName = point, (type(spec.name) == "string" and spec.name ~= "" and spec.name:sub(1, 48))
            or (drop and drop.name) or point
    end

    self:refresh()
    local open, mine = 0, 0
    for _, c in pairs(self.contracts) do
        open = open + 1
        if poster == "player" and c.poster == "player" and c.fixer == fixer and c.state == "open" then mine = mine + 1 end
    end
    if open >= cfg.contracts.maxOpen then return nil, "board_full" end
    if poster == "player" and mine >= cfg.contracts.maxPerFixer then return nil, "too_many_posted" end
    if cfg.contracts.oneBySite and (self.siteOf[site.key] or self.siteLocks[site.key]) then return nil, "site_busy" end

    local id = L.newId()
    local code = M.codeFor(id, self.byCode)
    local now = P.nowS()
    local record = M.newContract({
        id = id, code = code, site = site.key, tier = site.tier, reward = reward, cut = M.cutOf(reward, cfg.cut.rate),
        poster = poster, fixer = fixer, fixerName = fixerName, point = point,
        posted = now, deadline = now + minutes * 60,
    })
    local opId = M.opId("post", id)
    self.siteLocks[site.key] = true
    local receipt, why = L.transfer({ opId = opId, kind = "netrunner.post", reason = "post " .. code,
        lines = { { instance = M.contractIid(id), item = "nr_contract", from = cfg.accounts.source,
            to = cfg.accounts.board, meta = record, reason = "contract posted" } } })
    self.siteLocks[site.key] = nil
    if not receipt then
        if why == "in_doubt" or why == "busy" then self.pendingOps[opId] = { kind = "post", id = id } end
        self:log("post %s on %s refused: %s", code, site.key, tostring(why))
        return nil, why
    end
    self:refresh()
    self.stats.posted = self.stats.posted + 1
    local c = self.contracts[id] or record
    self:log("contract %s (%s) posted on %s tier %d reward %d cut %d by %s %s, deadline %d min", code, id, site.key,
        site.tier, reward, record.cut, poster, tostring(fixer), minutes)
    self:emitContract("posted", c)
    -- Every netrunner on duty hears about it (bounded by the number of players).
    local text = ("New contract on the board: %s, %s (%s), tier %d, %s. /netrun contracts"):format(code, site.label,
        site.area or "?", site.tier, M.money(reward - record.cut))
    for _, runner in ipairs(P.jobs.listOnDuty(cfg.job)) do self:tell(runner, text, "info") end
    if fixerPid then self:tell(fixerPid, ("Contract %s posted: %s, %s, %d min."):format(code, site.label, M.money(reward), minutes), "success") end
    return self:summaryOf(c)
end

-- ---------------------------------------------------------------------------------------------
-- Taking, abandoning, cancelling (yield)
-- ---------------------------------------------------------------------------------------------
function S:take(pid, ref)
    local cfg, M, L, P = self.cfg, self.M, self.L, self.P
    if not self.ready then return nil, "netrunner_unavailable" end
    local ok, why = P.jobs.eligible(pid, cfg.eligibility.args)
    if not ok then return nil, why or "not_eligible" end
    local subject, swhy = L.subjectOf(pid)
    if not subject then return nil, swhy or "no_pockets" end
    local held = self:activeContract(subject)
    if held then return nil, "already_on_contract" end
    local c = self:find(ref)
    if not c then return nil, "unknown_contract" end
    if c.state ~= "open" then return nil, "contract_taken" end
    if M.expired(c, P.nowS()) then return nil, "contract_expired" end
    if c.poster == "player" and c.fixer == subject then return nil, "own_contract" end
    if self.locks[c.id] then return nil, "contract_busy" end
    self.locks[c.id] = "take"
    local opId = L.newOpId("take")
    local receipt, twhy = L.transfer({ opId = opId, kind = "netrunner.take", actor = L.pocketsOf(subject),
        reason = "take " .. c.code, lines = { { instance = M.contractIid(c.id), at = cfg.accounts.board,
            metaPatch = M.takePatch(subject, self:nameOf(pid), P.nowS()), reason = "contract taken" } } })
    self.locks[c.id] = nil
    if not receipt and (twhy == "in_doubt" or twhy == "busy") then self.pendingOps[opId] = { kind = "take", id = c.id } end
    self:refresh()
    if not receipt then
        local now = self.contracts[c.id]
        if twhy == "instance_unavailable" or twhy == "stale_version" or twhy == "conflict" then
            if now and now.state ~= "open" then return nil, now.taker == subject and "already_on_contract" or "contract_taken" end
            return nil, "contract_busy"
        end
        return nil, twhy
    end
    self.online[subject] = pid
    self.stats.taken = self.stats.taken + 1
    c = self.contracts[c.id] or c
    local site = self.sites[c.site]
    self:log("contract %s taken by %s (player %d)", c.code, subject, pid)
    self:emitContract("taken", c)
    self:tell(pid, ("Contract %s is yours: breach the %s (%s) before %s. Bring a data chip."):format(c.code,
        site and site.label or c.site, site and site.area or "?", M.clock(M.secondsLeft(c, P.nowS()))), "success")
    if c.poster == "player" then
        self:tellSubject(c.fixer, nil, ("%s took your contract %s."):format(self:nameOf(pid), c.code), "info")
    end
    return self:summaryOf(c)
end

-- A taken (not breached) contract goes back to the board.
function S:abandon(pid)
    local M, L, P = self.M, self.L, self.P
    local subject = L.subjectOf(pid)
    local c = self:activeContract(subject)
    if not c then return nil, "no_contract" end
    if c.state == "breached" then return nil, "cannot_abandon" end
    if self.locks[c.id] then return nil, "contract_busy" end
    self.locks[c.id] = "abandon"
    local opId = L.newOpId("abandon")
    local receipt, why = L.transfer({ opId = opId, kind = "netrunner.abandon", actor = L.pocketsOf(subject),
        reason = "abandon " .. c.code, lines = { { instance = M.contractIid(c.id), at = self.cfg.accounts.board,
            metaPatch = M.releasePatch(), reason = "contract abandoned" } } })
    self.locks[c.id] = nil
    if not receipt and (why == "in_doubt" or why == "busy") then self.pendingOps[opId] = { kind = "abandon", id = c.id } end
    self:refresh()
    if not receipt then return nil, self.M.breachRefusal(why) end
    self.stats.abandoned = self.stats.abandoned + 1
    self:emitContract("abandoned", self.contracts[c.id] or c)
    self:log("contract %s abandoned by %s", c.code, tostring(subject))
    if c.poster == "player" then
        self:tellSubject(c.fixer, nil, ("%s dropped your contract %s: it is back on the board."):format(self:nameOf(pid), c.code), "warning")
    end
    return true
end

-- The poster pulls an open contract (a player fixer, or `byResource` for an export caller).
function S:cancelContract(ref, pid, byResource)
    local M, L = self.M, self.L
    local c = self:find(ref)
    if not c then return nil, "unknown_contract" end
    if pid then
        local subject = L.subjectOf(pid)
        if c.poster ~= "player" or c.fixer ~= subject then return nil, "not_your_contract" end
    end
    if c.state ~= "open" then return nil, "contract_not_open" end
    if self.locks[c.id] then return nil, "contract_busy" end
    self.locks[c.id] = "cancel"
    local opId = M.opId("cancel", c.id)
    local receipt, why = L.transfer({ opId = opId, kind = "netrunner.cancel", reason = "cancel " .. c.code,
        lines = { { instance = M.contractIid(c.id), from = self.cfg.accounts.board, to = self.cfg.accounts.sink,
            reason = "contract cancelled" } } })
    self.locks[c.id] = nil
    if not receipt and (why == "in_doubt" or why == "busy") then self.pendingOps[opId] = { kind = "cancel", id = c.id } end
    self:refresh()
    if not receipt then return nil, self.M.breachRefusal(why) end
    self.stats.cancelled = self.stats.cancelled + 1
    self:emitContract("cancelled", c, { by = (pid and self:nameOf(pid)) or byResource or "console" })
    self:log("contract %s cancelled by %s", c.code, tostring(byResource or pid or "console"))
    return true
end

-- ---------------------------------------------------------------------------------------------
-- Hooks: validate (synchronous, never yields)
-- ---------------------------------------------------------------------------------------------
function S:breachProblem(c, siteKey, phase)
    if not c then return "no_contract" end
    if c.state == "breached" then return "already_breached" end
    if c.state ~= "taken" then return "no_contract" end
    if c.site ~= siteKey then return "no_contract_here" end
    if self.M.expired(c, self.P.nowS()) then return "contract_expired" end
    if phase == "begin" then
        if (self.alerts[siteKey] or 0) > self.P.now() then return "site_alert" end
        if self.locks[c.id] then return "contract_busy" end
    end
    return nil
end

-- What stops a drop at `point` (the fixer drop's one E prompt, Talk to the fixer, when it delivers).
function S:dropProblem(c, point)
    if not c then return "no_contract" end
    if c.state ~= "breached" then return "not_breached" end
    if c.point ~= point then return "wrong_drop" end
    if self.M.expired(c, self.P.nowS()) then return "contract_expired" end
    if c.poster == "player" then
        if not self.cfg.deliver.dropWhenFixerAway or self:pidOf(c.fixer) then return "deliver_in_person" end
    end
    return nil
end

function S:validate(ctx)
    if not fromActions() then return false, "not_owner" end
    if not self.ready then return false, "netrunner_unavailable" end
    local kind = self.actionKinds[ctx.actionId]
    if not kind then return false, "unknown_action" end
    if kind.kind == "talk" or kind.kind == "gesture" then return true end
    local subject = self.L.subjectOf(ctx.playerId)
    if not subject then return false, "no_pockets" end
    local c = self:activeContract(subject)
    local why
    if kind.kind == "breach" then
        why = self:breachProblem(c, kind.site, ctx.phase)
    elseif kind.kind == "deliver" then
        local point = type(ctx.target) == "table" and type(ctx.target.data) == "table" and ctx.target.data.fixer or nil
        why = self:dropProblem(c, point)
    end
    if why then
        if ctx.phase == "begin" then self:refuseTo(ctx.playerId, why) end
        return false, why
    end
    return true
end

-- ---------------------------------------------------------------------------------------------
-- Hooks: reserve -> commit, or cancel
-- ---------------------------------------------------------------------------------------------
function S:reserve(ctx)
    if not fromActions() then return nil, "not_owner" end
    if not self.P.actions.verify(ctx.opId, "reserve") then return nil, "not_owner" end
    if not self.ready then return nil, "netrunner_unavailable" end
    local kind = self.actionKinds[ctx.actionId]
    if kind and kind.kind == "breach" then return self:reserveBreach(ctx, kind) end
    if kind and kind.kind == "deliver" then return self:reserveDeliver(ctx) end
    return nil, "unknown_action"
end

function S:gradeOf(pid)
    local summary = self.P.jobs.summary(pid)
    return type(summary) == "table" and self.M.integer(summary.grade) or 0
end

function S:reserveBreach(ctx, kind)
    local cfg, M, L, P = self.cfg, self.M, self.L, self.P
    local pid = ctx.playerId
    local subject, swhy = L.subjectOf(pid)
    if not subject then return nil, swhy or "no_pockets" end
    local c = self:activeContract(subject)
    local problem = self:breachProblem(c, kind.site, "begin")
    if problem then
        self:refuseTo(pid, problem)
        return nil, problem
    end
    local site = self.sites[kind.site]
    local tier = cfg.tiers[site.tier]
    local pockets = L.pocketsOf(subject)
    local grade = self:gradeOf(pid)
    local chance = M.breachChance(tier, cfg.difficulty, grade, c.attempts)
    local txOpId = L.newOpId("breach")
    local success = M.breachSucceeds(txOpId, chance)
    local attemptsAfter = (M.integer(c.attempts) or 0) + 1
    local contractIid = M.contractIid(c.id)
    local lines = {}
    if cfg.breach and cfg.breach.item then
        lines[#lines + 1] = { item = cfg.breach.item, count = cfg.breach.count or 1, from = pockets, to = cfg.accounts.sink,
            reason = "breach kit" }
    end
    local outcome
    if success then
        outcome = "success"
        lines[#lines + 1] = { instance = contractIid, at = cfg.accounts.board, reason = "breached",
            metaPatch = { state = "breached", shard = M.shardIid(c.id), breached = P.nowS(), attempts = attemptsAfter } }
        lines[#lines + 1] = { instance = M.shardIid(c.id), item = "nr_data_shard", from = cfg.accounts.source, to = pockets,
            meta = M.shardMeta(c, site), reason = "data shard" }
    else
        outcome = M.failureOutcome(cfg.failure, attemptsAfter)
        local traces = (M.integer(c.traces) or 0) + 1
        if outcome == "fail" then
            lines[#lines + 1] = { instance = contractIid, from = cfg.accounts.board, to = cfg.accounts.sink, reason = "contract failed" }
        elseif outcome == "reopen" then
            local patch = M.releasePatch()
            patch.attempts, patch.traces = attemptsAfter, traces
            lines[#lines + 1] = { instance = contractIid, at = cfg.accounts.board, metaPatch = patch, reason = "breach failed" }
        else
            lines[#lines + 1] = { instance = contractIid, at = cfg.accounts.board, reason = "breach failed",
                metaPatch = { attempts = attemptsAfter, traces = traces } }
        end
    end
    local held, why = L.reserve({ opId = txOpId, kind = "netrunner.breach", actor = pockets,
        reason = "breach " .. site.key, ttlMs = tier.durationMs + 30000, lines = lines })
    if not held then
        local token = M.breachRefusal(why)
        self:refuseTo(pid, token)
        return nil, token
    end
    local r = {
        txOpId = txOpId, contract = c.id, code = c.code, site = site.key, tier = site.tier, outcome = outcome,
        success = success, chance = chance, grade = grade, attempts = attemptsAfter, subject = subject, pid = pid,
        reward = c.reward, cut = c.cut, poster = c.poster, fixer = c.fixer, point = c.point, deadline = c.deadline,
    }
    self.work[ctx.opId] = r
    self:log("breach %s by %s on %s reserved (chance %d%%, grade %d, attempt %d)", txOpId, subject, site.key, chance, grade,
        attemptsAfter)
    return r
end

function S:reserveDeliver(ctx)
    local L = self.L
    local pid = ctx.playerId
    local subject, swhy = L.subjectOf(pid)
    if not subject then return nil, swhy or "no_pockets" end
    local c = self:activeContract(subject)
    local point = type(ctx.target) == "table" and type(ctx.target.data) == "table" and ctx.target.data.fixer or nil
    local problem = self:dropProblem(c, point)
    if problem then
        self:refuseTo(pid, problem)
        return nil, problem
    end
    local pockets = L.read(L.pocketsOf(subject))
    if not L.hasInstance(pockets, c.shard) then
        self:refuseTo(pid, "no_shard")
        return nil, "no_shard"
    end
    return { contract = c.id, subject = subject, pid = pid }
end

function S:commit(ctx)
    if not fromActions() then return nil, "not_owner" end
    if not self.P.actions.verify(ctx.opId, "commit") then return nil, "not_owner" end
    local kind = self.actionKinds[ctx.actionId]
    if not kind then return nil, "unknown_action" end
    if kind.kind == "breach" then return self:commitBreach(ctx) end
    if kind.kind == "deliver" then return self:commitDeliver(ctx) end
    if kind.kind == "talk" then
        local point = type(ctx.target) == "table" and type(ctx.target.data) == "table" and ctx.target.data.fixer or nil
        return { talk = true, point = point }
    end
    if kind.kind == "gesture" then return { gesture = true } end
    return nil, "unknown_action"
end

function S:commitBreach(ctx)
    local r = ctx.reservation
    if type(r) ~= "table" or not r.txOpId then return nil, "no_reservation" end
    local receipt, why = self.L.commit(r.txOpId)
    if not receipt then
        if why == "in_doubt" or why == "busy" then
            self.doubts[r.txOpId] = r
        elseif TRANSIENT[why] and self.doubts[r.txOpId] then
            why = "in_doubt"     -- an earlier attempt of this op may have landed: still unknown
        end
        return nil, why
    end
    local ok, err = pcall(self.afterBreach, self, r, receipt)
    if not ok then self:warn("after breach %s raised: %s", r.txOpId, tostring(err)) end
    self.work[ctx.opId] = nil
    return { tx = r.txOpId, contract = r.contract, outcome = r.outcome, replay = receipt.replay == true }
end

function S:afterBreach(r, receipt)
    if self.done[r.txOpId] then return end
    self.done[r.txOpId] = self.P.now()
    self.doubts[r.txOpId] = nil
    local cfg, M, P = self.cfg, self.M, self.P
    self:refresh()
    local site = self.sites[r.site]
    local siteLabel = site and site.label or r.site
    local c = self.contracts[r.contract] or { id = r.contract, code = r.code, site = r.site, tier = r.tier,
        reward = r.reward, cut = r.cut, poster = r.poster, fixer = r.fixer, point = r.point, deadline = r.deadline,
        state = "failed", attempts = r.attempts }
    local data = { success = r.success, chance = r.chance, grade = r.grade, attempt = r.attempts,
        replay = receipt and receipt.replay == true }
    if r.success then
        self.stats.breaches = self.stats.breaches + 1
        local drop = self.fixers[r.point]
        self:log("breach %s committed: success on %s, shard %s minted for %s", r.txOpId, r.site, M.shardIid(r.contract), r.subject)
        self:tellSubject(r.subject, r.pid, ("Breach complete (%d%% odds): the data shard is in your pockets. Deliver it at %s within %s."):format(
            r.chance, drop and drop.label or tostring(r.point), M.clock(M.secondsLeft(c, P.nowS()))), "success")
        if r.poster == "player" then
            self:tellSubject(r.fixer, nil, ("Contract %s: %s pulled the data. Expect the shard."):format(r.code,
                self:nameOf(r.pid)), "info")
        end
        self:emitContract("breached", c)
        self:jobCompleted("breach_success", r.pid, r.txOpId, c, data)
        return
    end
    self.stats.failures = self.stats.failures + 1
    self.alerts[r.site] = P.now() + (cfg.failure.siteAlertMs or 0)
    data.outcome = r.outcome
    local after = r.outcome == "fail" and "The contract is burned." or
        (r.outcome == "reopen" and "The contract goes back on the board." or
        ("You may try again (attempt %d of %d)."):format(r.attempts, cfg.failure.maxAttempts or r.attempts))
    self:log("breach %s committed: FAILED on %s (%s), contract %s", r.txOpId, r.site, r.outcome, r.code)
    self:tellSubject(r.subject, r.pid, ("Breach failed (%d%% odds): the ICE traced you. %s"):format(r.chance, after), "warning")
    local traced = false
    if self:isSubject(r.pid, r.subject) then
        traced = self:trace(r.pid, { site = r.site, label = siteLabel, position = site and site.position, contract = r.contract,
            ref = r.txOpId }, { wanted = true })
    end
    data.traced = traced
    if r.outcome == "fail" then
        self.retirePending[r.contract] = nil
        if r.poster == "player" then
            self:tellSubject(r.fixer, nil, ("Contract %s failed: the runner got traced."):format(r.code), "warning")
        end
        self:emitContract("failed", c, { state = "failed" })
    else
        self:emitContract("attempt_failed", c)
    end
    self:jobCompleted("breach_failed", r.pid, r.txOpId, c, data)
end

function S:cancelHook(ctx)
    if not fromActions() then return end
    local kind = self.actionKinds[ctx.actionId]
    if not kind then return end
    if kind.kind == "breach" then
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
        self:log("breach %s released (%s): nothing was used", r.txOpId, tostring(ctx.reason))
    elseif kind.kind == "deliver" and ctx.reason == "in_doubt" then
        -- The sale may have landed: the sweep follows rp_economy's status (self.sales).
        self.stats.doubts = self.stats.doubts + 1
    end
end

function S:settle(r)
    local outcome, receipt = self.L.settle(r.txOpId)
    if outcome == "committed" then
        self:afterBreach(r, receipt)
    elseif outcome == "failed" or outcome == "aborted" then
        self.doubts[r.txOpId] = nil
        self:log("breach %s settled: %s (nothing moved)", r.txOpId, outcome)
        self:tellSubject(r.subject, r.pid, "The board could not confirm that breach: nothing was used, try again.", "warning")
    end
    return outcome
end

-- ---------------------------------------------------------------------------------------------
-- Delivery: ONE rp_economy sale (the shard burned, the client's money, the fixer's cut)
-- ---------------------------------------------------------------------------------------------
function S:commitDeliver(ctx)
    local r = ctx.reservation
    if type(r) ~= "table" or not r.contract then return nil, "no_reservation" end
    local receipt, why = self:sell(r.contract, r.pid, "drop")
    if not receipt then return nil, why end
    return { sale = receipt.opId, contract = r.contract, replay = receipt.replay == true }
end

-- Pays a delivery. Returns the receipt, or nil, reason (in_doubt: the sweep follows it).
function S:sell(id, pid, via)
    local cfg, M, L, P = self.cfg, self.M, self.L, self.P
    local attempt = self.attempts[id] or 1
    local saleOpId = M.deliverOpId(id, attempt)
    -- Already paid (the sweep settled it while open77_actions was retrying the commit hook).
    if self.done[saleOpId] then return { opId = saleOpId, replay = true } end
    local c = self.contracts[id]
    if not c then return nil, "unknown_contract" end
    if c.state ~= "breached" or type(c.shard) ~= "string" then return nil, "not_breached" end
    local cutTo = c.poster == "player" and { subject = c.fixer } or cfg.cut.npcTo
    local spec = M.deliverySale({ opId = saleOpId, taker = c.taker, sellerPid = self:isSubject(pid, c.taker) and pid or nil,
        shard = c.shard, pockets = L.pocketsOf(c.taker), reward = c.reward, cut = c.cut, cutTo = cutTo,
        buyer = cfg.deliver.buyer, reason = cfg.deliver.reason })
    -- No expiry or second delivery of this contract while its sale is in flight.
    if self.locks[id] and self.locks[id] ~= "deliver" then return nil, "contract_busy" end
    self.locks[id] = "deliver"
    local receipt, why, info = P.economy.sale(spec)
    if self.locks[id] == "deliver" then self.locks[id] = nil end
    if type(receipt) == "table" then
        self:finishDelivery(c, saleOpId, receipt, pid, via)
        return receipt
    end
    if why == "in_doubt" then
        self.sales[saleOpId] = { id = id, pid = pid, via = via, since = P.now() }
        self:log("delivery %s in doubt: rp_economy settles it, the sweep follows", saleOpId)
        self:tell(pid, M.textFor("in_doubt"), "info")
        return nil, "in_doubt"
    end
    if why == "store_unavailable" and type(info) == "table" and info.state == "aborted" then
        self.attempts[id] = attempt + 1    -- that id was fenced and can never commit
    end
    local token = M.deliverRefusal(why)
    if token == "no_shard" then self.reconciled[id] = nil end   -- the sweep checks whether it was paid already
    self:log("delivery %s refused: %s", saleOpId, tostring(why))
    return nil, token
end

function S:finishDelivery(c, saleOpId, receipt, pid, via)
    if self.done[saleOpId] then return end
    self.done[saleOpId] = self.P.now()
    self.sales[saleOpId] = nil
    local M = self.M
    local net = c.reward - (c.cut or 0)
    local replay = type(receipt) == "table" and receipt.replay == true
    self.stats.deliveries = self.stats.deliveries + 1
    self:log("delivery %s committed%s: contract %s, %d to %s, cut %d (%s)", saleOpId, replay and " (replay)" or "",
        c.code, net, tostring(c.taker), c.cut or 0, c.poster == "player" and ("fixer " .. tostring(c.fixer)) or "fixer society")
    self:retire(c.id, "delivered")
    self:tellSubject(c.taker, pid, ("Shard delivered: contract %s closed, +%s (the fixer's cut: %s)."):format(c.code,
        M.money(net), M.money(c.cut or 0)), "success")
    if c.poster == "player" then
        self:tellSubject(c.fixer, nil, ("Contract %s delivered by %s: your cut %s."):format(c.code,
            tostring(c.takerName or "the runner"), M.money(c.cut or 0)), "success")
    end
    local closed = {}
    for k, v in pairs(c) do closed[k] = v end
    closed.state = "delivered"
    self:emitContract("delivered", closed, { state = "delivered", via = via })
    self:jobCompleted("deliver", pid or self:pidOf(c.taker), saleOpId, c, { net = net, via = via, replay = replay })
end

-- Retires a contract instance from the board (one operation per contract and reason).
function S:retire(id, why)
    local M, L = self.M, self.L
    if self.locks[id] then
        self.retirePending[id] = why
        return nil, "contract_busy"
    end
    self.locks[id] = "retire"
    local opId = M.opId("close", id)
    local receipt, rwhy = L.transfer({ opId = opId, kind = "netrunner.close", reason = why,
        lines = { { instance = M.contractIid(id), from = self.cfg.accounts.board, to = self.cfg.accounts.sink, reason = why } } })
    self.locks[id] = nil
    self:refresh()
    if receipt or not self.contracts[id] then
        self.retirePending[id] = nil
        return true
    end
    self.retirePending[id] = why
    self:log("contract %s not retired yet (%s): the sweep retries", id, tostring(rwhy))
    return nil, rwhy
end

-- A breached contract whose shard is gone from the taker's pockets: was it paid? (a restart
-- between the sale and the retirement). Checks the delivery attempts rp_economy may know.
function S:reconcile(c)
    if self.reconciled[c.id] or self.locks[c.id] then return end
    local snap = self.L.read(self.L.pocketsOf(c.taker))
    if type(snap) ~= "table" then return end
    self.reconciled[c.id] = true
    if self.L.hasInstance(snap, c.shard) then return end
    for attempt = 1, math.max(3, self.attempts[c.id] or 1) do
        local opId = self.M.deliverOpId(c.id, attempt)
        local st = self.P.economy.status(opId)
        if type(st) == "table" and st.state == "committed" then
            self:log("contract %s was paid by %s before a restart: retiring it", c.code, opId)
            self:finishDelivery(c, opId, type(st.receipt) == "table" and st.receipt or { opId = opId, replay = true }, nil, "recovered")
            return
        end
        if type(st) ~= "table" or st.state == "unknown" then break end
    end
end

-- ---------------------------------------------------------------------------------------------
-- The hand-over to the player fixer who posted the contract (consent, then the same sale)
-- ---------------------------------------------------------------------------------------------
function S:handover(pid, fixerArg)
    local cfg, M, L, P = self.cfg, self.M, self.L, self.P
    if not self.ready then return nil, "netrunner_unavailable" end
    local ok, epoch = P.jobs.eligible(pid, cfg.eligibility.args)
    if not ok then return nil, epoch or "not_eligible" end
    local subject = L.subjectOf(pid)
    local c = self:activeContract(subject)
    if not c then return nil, "no_contract" end
    if c.state ~= "breached" then return nil, "not_breached" end
    if M.expired(c, P.nowS()) then return nil, "contract_expired" end
    if c.poster ~= "player" then return nil, "wrong_drop" end
    local fixer = fixerArg ~= nil and M.playerId(fixerArg) or self:pidOf(c.fixer)
    if not fixer or not P.players.name(fixer) then return nil, "fixer_away" end
    if L.subjectOf(fixer) ~= c.fixer then return nil, "not_the_fixer" end
    if self.offerOf[pid] then return nil, "player_reserved" end
    local pockets = L.read(L.pocketsOf(subject))
    if not L.hasInstance(pockets, c.shard) then return nil, "no_shard" end
    local runnerName = self:nameOf(pid)
    if self.offerOf[pid] then return nil, "player_reserved" end
    local h = cfg.deliver.handover
    -- The offer card says who hands what (Y / N answer it); without a label it read "Someone wants
    -- to give you something.".
    local state, why = P.interactions.request(pid, fixer, "give", { durationMs = h.durationMs,
        startDistance = h.startDistance, breakDistance = h.breakDistance, inviteTimeoutMs = h.inviteTimeoutMs, consent = true,
        label = ("%s: the data shard of contract %s"):format(runnerName, c.code):sub(1, 120) })
    if type(state) ~= "table" or not state.id then
        return nil, (why == "too_far") and "fixer_far" or (why or "interactions_unavailable")
    end
    local now = P.now()
    local o = { id = state.id, contract = c.id, runner = pid, fixer = fixer, epoch = epoch, runnerSubject = subject,
        fixerSubject = c.fixer, at = now, lastSeen = now }
    self.offers[o.id] = o
    self.offerOf[pid] = o.id
    local net = c.reward - (c.cut or 0)
    self:tell(fixer, ("%s hands you the data shard of contract %s. Y to take it and pass it to your client (%s to them, %s to you), N to decline."):format(
        runnerName, c.code, M.money(net), M.money(c.cut or 0)), "info")
    self:tell(pid, ("Hand-over offered to %s: they have to accept."):format(self:nameOf(fixer)), "info")
    self:log("hand-over %s: contract %s, runner %d -> fixer %d", o.id, c.code, pid, fixer)
    return o
end

function S:dropOffer(o, reason)
    self.offers[o.id] = nil
    if self.offerOf[o.runner] == o.id then self.offerOf[o.runner] = nil end
    self:log("hand-over %s dropped: %s (nothing moved)", tostring(o.id), tostring(reason))
    local why = self.M.handoverText(reason)
    local text = reason == "declined" and "The fixer declined the hand-over: you keep the shard." or
        ("The hand-over was cancelled: %s. You keep the shard."):format(why)
    if self:isSubject(o.runner, o.runnerSubject) then self:tell(o.runner, text, "warning") end
    if self:isSubject(o.fixer, o.fixerSubject) and reason ~= "declined" then
        self:tell(o.fixer, ("The hand-over was cancelled: %s."):format(why), "warning")
    end
end

function S:onInteractionCompleted(state)
    local o = type(state) == "table" and self.offers[state.id] or nil
    if not o then return end
    self.offers[o.id] = nil
    if self.offerOf[o.runner] == o.id then self.offerOf[o.runner] = nil end
    local ok, why = self.P.jobs.eligible(o.runner, { job = self.cfg.job, duty = true, epoch = o.epoch })
    if not ok then return self:dropOffer(o, why or "not_eligible") end
    if not self:isSubject(o.runner, o.runnerSubject) then return self:dropOffer(o, "runner_gone") end
    local receipt, swhy = self:sell(o.contract, o.runner, "handover")
    if not receipt and swhy ~= "in_doubt" then
        self:tell(o.runner, self.M.textFor(swhy), "warning")
        if self:isSubject(o.fixer, o.fixerSubject) then self:tell(o.fixer, self.M.textFor(swhy), "warning") end
    end
end

function S:onInteractionCancelled(state)
    local o = type(state) == "table" and self.offers[state.id] or nil
    if not o then return end
    local reason = tostring(state.reason or "cancelled")
    if reason:find("declin") or reason:find("reject") then reason = "declined" end
    self:dropOffer(o, reason)
end

-- The runner's shift moved: a hand-over still waiting for consent is withdrawn at once.
function S:onWorkEpoch(pid, epoch)
    local id = self.offerOf[self.M.playerId(pid) or -1]
    local o = id and self.offers[id]
    if o and o.epoch ~= epoch then
        local _, why = self.P.interactions.cancel(o.id, "stale_job_epoch")
        if why then self:log("hand-over %s: platform cancel answered %s", o.id, tostring(why)) end
    end
end

-- ---------------------------------------------------------------------------------------------
-- The trace: NCPD dispatch, a record entry, the native heat (never lowers a higher one)
-- ---------------------------------------------------------------------------------------------
-- where = { site?, label, position?, contract?, ref? }; opts = { wanted = bool }
function S:trace(pid, where, opts)
    local cfg, P = self.cfg, self.P
    local t = cfg.trace or {}
    local pos = where.position or P.players.position(pid)
    local text = (t.text or "ICE trace at %s"):format(tostring(where.label))
    if t.dispatch ~= false and pos then
        P.emit("rp_ncpd:alert", "netrunner", { x = pos.x, y = pos.y, z = pos.z }, text, t.revealName and pid or 0)
    end
    if t.record ~= false then
        local ok, why = P.ncpd.addRecord(pid, "netrunner", ("Traced: %s"):format(tostring(where.label)), 0)
        if not ok then self:log("rp_ncpd:addRecord refused: %s", tostring(why)) end
    end
    local applied = 0
    if opts and opts.wanted and (t.wantedLevel or 0) > 0 then
        applied = self:raiseHeat(pid, t.wantedLevel, t.wantedMs or 120000)
    end
    self.stats.traces = self.stats.traces + 1
    P.emit("rp_netrunner:traced", { playerId = pid, site = where.site, label = where.label,
        position = pos and { x = pos.x, y = pos.y, z = pos.z } or nil, contract = where.contract, ref = where.ref,
        wantedLevel = applied })
    self:tell(pid, "TRACE: NCPD ICE logged your signature. Dispatch is on its way.", "warning")
    self:log("trace player %d at %s (wanted %d)", pid, tostring(where.label), applied)
    return true
end

function S:raiseHeat(pid, level, durationMs)
    local P = self.P
    local policy = P.players.getWanted(pid)
    local before = type(policy) == "table" and self.M.integer(policy.level) or 0
    if before >= level then return before end
    local res, why = P.players.setWanted(pid, level)
    if not res then
        self:log("native heat refused for player %d: %s", pid, tostring(why))
        return 0
    end
    self.heat[pid] = { level = level, before = before, untilMs = P.now() + durationMs }
    return level
end

-- Heat this resource raised comes back down when its time is up, unless someone raised it further.
function S:coolHeat()
    local P = self.P
    local now = P.now()
    for pid, h in pairs(self.heat) do
        if now >= h.untilMs then
            self.heat[pid] = nil
            local policy = P.players.getWanted(pid)
            if type(policy) == "table" and self.M.integer(policy.level) == h.level then
                P.players.setWanted(pid, h.before)
            end
        end
    end
end

-- ---------------------------------------------------------------------------------------------
-- Expiry and the NPC board (the sweep)
-- ---------------------------------------------------------------------------------------------
function S:expire(c)
    local cfg, M, L = self.cfg, self.M, self.L
    if self.locks[c.id] then return end
    self.locks[c.id] = "expire"
    local retireLine = { instance = M.contractIid(c.id), from = cfg.accounts.board, to = cfg.accounts.sink, reason = "contract expired" }
    local lines = { retireLine }
    if c.state == "breached" and type(c.shard) == "string" and type(c.taker) == "string" then
        lines[#lines + 1] = { instance = c.shard, from = L.pocketsOf(c.taker), to = cfg.accounts.sink, reason = "shard expired" }
    end
    local opId = M.opId("expire", c.id)
    local receipt, why = L.transfer({ opId = opId, kind = "netrunner.expire", reason = "expire " .. c.code, lines = lines })
    if not receipt and why == "instance_unavailable" and #lines > 1 then
        -- The shard is not in the taker's pockets any more (given away): retire the contract alone.
        opId = opId .. ".c"
        receipt, why = L.transfer({ opId = opId, kind = "netrunner.expire", reason = "expire " .. c.code, lines = { retireLine } })
    end
    self.locks[c.id] = nil
    if not receipt and (why == "in_doubt" or why == "busy") then self.pendingOps[opId] = { kind = "expire", id = c.id } end
    self:refresh()
    if not receipt then
        self:log("contract %s not expired yet: %s", c.code, tostring(why))
        return
    end
    self.stats.expired = self.stats.expired + 1
    self:log("contract %s expired (%s)", c.code, c.state)
    local closed = {}
    for k, v in pairs(c) do closed[k] = v end
    closed.state = "expired"
    self:emitContract("expired", closed, { state = "expired" })
    if type(c.taker) == "string" then
        self:tellSubject(c.taker, nil, ("Contract %s expired%s."):format(c.code, c.state == "breached" and ": the shard went stale" or ""), "warning")
    end
    if c.poster == "player" then self:tellSubject(c.fixer, nil, ("Your contract %s expired."):format(c.code), "warning") end
end

function S:npcPost()
    local cfg = self.cfg
    local nb = cfg.npcBoard
    if not nb or not nb.enabled then return end
    local now = self.P.now()
    if now - self.lastNpcPost < (nb.everyMs or 60000) then return end
    self.lastNpcPost = now
    local open = 0
    for _, c in pairs(self.contracts) do
        if c.poster == "npc" and c.state == "open" then open = open + 1 end
    end
    if open >= (nb.open or 0) then return end
    local free = {}
    for key, site in pairs(self.sites) do
        if site.npc and not self.siteOf[key] and not self.siteLocks[key] then free[#free + 1] = key end
    end
    if #free == 0 then return end
    table.sort(free)
    local pick = free[(self.M.hash(tostring(now)) % #free) + 1]
    local summary, why = self:post({ site = pick, poster = "npc", point = nb.fixer, seed = now })
    if not summary then self:log("NPC board: no contract on %s (%s)", pick, tostring(why)) end
end

function S:sweep()
    if not self.ready then return end
    local P, M = self.P, self.M
    self:refresh()
    -- Every loop below may yield (status reads): it walks a copy, other threads may add entries.
    local function copy(t)
        local out = {}
        for k, v in pairs(t) do out[#out + 1] = { k, v } end
        return out
    end
    for _, kv in ipairs(copy(self.doubts)) do
        local r = kv[2]
        if not self.done[r.txOpId] then self:settle(r) end
    end
    for _, kv in ipairs(copy(self.sales)) do
        local opId, s = kv[1], kv[2]
        local st = P.economy.status(opId)
        if type(st) == "table" then
            local c = self.contracts[s.id]
            if st.state == "committed" and c then
                self:finishDelivery(c, opId, type(st.receipt) == "table" and st.receipt or { opId = opId }, s.pid, s.via)
            elseif st.state == "committed" then
                self.sales[opId] = nil
            elseif st.state == "failed" or st.state == "aborted"
                or (st.state == "unknown" and P.now() - s.since > self.cfg.lostOfferMs) then
                -- failed / aborted: nothing was paid; unknown for a minute: the sale never reached the
                -- coordinator (the same id is a fresh attempt). A fenced (aborted) id never commits:
                -- the next attempt uses a new one.
                self.sales[opId] = nil
                if st.state == "aborted" and c then self.attempts[s.id] = (self.attempts[s.id] or 1) + 1 end
                self:tell(s.pid, "The delivery did not go through: nothing was paid, the shard is still yours.", "warning")
            end
        end
    end
    for _, kv in ipairs(copy(self.pendingOps)) do
        local opId = kv[1]
        local outcome = self.L.settle(opId)
        if outcome ~= "pending" then
            self.pendingOps[opId] = nil
            self:refresh()
        end
    end
    for _, kv in ipairs(copy(self.retirePending)) do
        local id, why = kv[1], kv[2]
        if self.contracts[id] then self:retire(id, why) else self.retirePending[id] = nil end
    end
    local now = P.nowS()
    local expiring, checks = 0, 0
    for _, c in ipairs(self:sorted()) do
        if M.expired(c, now) and expiring < 8 then
            expiring = expiring + 1
            self:expire(c)
        elseif c.state == "breached" and not self.reconciled[c.id] and checks < 8 then
            checks = checks + 1
            self:reconcile(c)
        end
    end
    self:npcPost()
    self:coolHeat()
    local nowMs = P.now()
    for _, kv in ipairs(copy(self.offers)) do
        local id, o = kv[1], kv[2]
        local st = P.interactions.get(id)
        if type(st) == "table" then
            o.lastSeen = nowMs
        elseif nowMs - o.lastSeen > self.cfg.lostOfferMs then
            self:dropOffer(o, "lost")
        end
    end
    for site, untilMs in pairs(self.alerts) do
        if untilMs <= nowMs then self.alerts[site] = nil end
    end
    local cutoff = nowMs - 10 * 60 * 1000
    for id, at in pairs(self.done) do
        if at < cutoff then self.done[id] = nil end
    end
end

-- ---------------------------------------------------------------------------------------------
-- Presentation around the lifecycle (open77_actions transitions of this resource)
-- ---------------------------------------------------------------------------------------------
local TERMINAL = { committed = true, cancelled = true, failed = true, in_doubt = true }

function S:onTransition(op)
    if type(op) ~= "table" or op.owner ~= self.resource or not TERMINAL[op.state] then return end
    local pid = op.playerId
    if op.state == "committed" then
        if op.actionId == "talk" then
            self:onTalk(pid, type(op.receipt) == "table" and op.receipt.point or nil)
        end
        return
    end
    if op.reason == "superseded" or op.actionId == "qh_tap" or op.actionId == "talk" then return end
    local kind = self.actionKinds[op.actionId]
    if op.state == "in_doubt" then
        self:tell(pid, self.M.textFor("in_doubt"), "warning")
    elseif op.reason == "cancelled_by_player" then
        if kind and kind.kind == "breach" then
            self:tell(pid, "Breach aborted. The ICE never saw you: nothing was used.", "info")
        elseif kind and kind.kind == "deliver" then
            self:tell(pid, "Hand-over aborted: you keep the shard.", "info")
        end
    else
        self:refuseTo(pid, op.reason)
    end
end

-- ---------------------------------------------------------------------------------------------
-- The fixer drop: the delivery when a shard is due here, otherwise the board
-- ---------------------------------------------------------------------------------------------
function S:onTalk(pid, point)
    local subject = self.L.subjectOf(pid)
    local c = self:activeContract(subject)
    if c and c.state == "breached" and c.point == point then
        if c.poster == "player" and self:pidOf(c.fixer) then
            return self:refuseTo(pid, "deliver_in_person")
        end
        local op, why = self.P.actions.request(pid, "deliver", "fixer_" .. point)
        if not op then self:refuseTo(pid, why) end
        return
    end
    self:showBoard(pid, point)
end

-- Players who are not netrunners on duty may read the board but not take from it; an on-duty
-- fixer also gets "Post a contract". Falls back to chat when the UI kit is not running.
function S:showBoard(pid, point)
    local cfg, M, P = self.cfg, self.M, self.P
    local subject = self.L.subjectOf(pid)
    local runner = P.jobs.eligible(pid, cfg.eligibility.args) == true
    local fixer = P.jobs.eligible(pid, cfg.fixerRequirement) == true
    local mine = self:activeContract(subject)
    local now = P.nowS()
    local options = {}
    if mine then
        local site = self.sites[mine.site]
        options[#options + 1] = { id = "mine", label = ("Your contract %s: %s"):format(mine.code, site and site.label or mine.site),
            description = mine.state == "breached" and "Deliver the shard at the fixer drop." or "Breach the terminal.",
            metadata = { { label = "State", value = mine.state }, { label = "Time left", value = M.clock(M.secondsLeft(mine, now)) } } }
    end
    for _, c in ipairs(self:sorted({ state = "open" })) do
        if #options >= 30 then break end
        local site, tier = self.sites[c.site], cfg.tiers[c.tier]
        options[#options + 1] = {
            id = "c:" .. c.id, label = ("%s  %s"):format(c.code, site and site.label or c.site),
            description = site and site.area or nil, disabled = not runner or mine ~= nil,
            metadata = { { label = "Tier", value = ("%d %s"):format(c.tier, tier and tier.label or "") },
                { label = "Pay", value = M.money(c.reward - (c.cut or 0)) },
                { label = "Time left", value = M.clock(M.secondsLeft(c, now)) },
                { label = "Fixer", value = tostring(c.fixerName or c.fixer):sub(1, 64) } },
        }
    end
    if fixer then
        options[#options + 1] = { id = "post", label = "Post a contract", description = "Pick a site, a reward and a deadline." }
    end
    if #options == 0 then
        return self:tell(pid, "The board is empty right now. Come back later.", "info")
    end
    local answer, why = P.uikit.context(pid, { id = "nr_board", title = "Breach contracts",
        description = runner and "Pick a contract to take it." or "Only a netrunner on duty takes contracts.",
        options = options }, { timeoutMs = 60000 })
    if type(answer) ~= "table" then
        self:log("board menu for player %d unavailable (%s): listing in chat", pid, tostring(why))
        return self:listTo(pid)
    end
    if not answer.ok or type(answer.value) ~= "table" then return end
    local pick = tostring(answer.value.id)
    if pick == "post" then return self:postDialog(pid, point) end
    if pick == "mine" then return self:statusTo(pid) end
    local id = pick:match("^c:(.+)$")
    local c = id and self.contracts[id]
    if not c then return self:refuseTo(pid, "unknown_contract") end
    local site = self.sites[c.site]
    local confirm = P.uikit.alert(pid, { title = ("Take contract %s?"):format(c.code),
        message = ("Breach the %s (%s) and bring the shard back here within %s. Pay %s. A failed breach is traced by NCPD; every attempt burns a data chip."):format(
            site and site.label or c.site, site and site.area or "?", M.clock(M.secondsLeft(c, now)), M.money(c.reward - (c.cut or 0))),
        confirm = "Take it", cancel = "Not now", timeoutMs = 30000 })
    if type(confirm) ~= "table" or not confirm.ok or confirm.value ~= "confirm" then return end
    local summary, twhy = self:take(pid, c.id)
    if not summary then self:refuseTo(pid, twhy) end
end

function S:postDialog(pid, point)
    local cfg, M, P = self.cfg, self.M, self.P
    local options = {}
    local keys = {}
    for key in pairs(self.sites) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b)
        local sa, sb = self.sites[a], self.sites[b]
        if sa.tier ~= sb.tier then return sa.tier < sb.tier end
        return a < b
    end)
    for _, key in ipairs(keys) do
        local site = self.sites[key]
        local tier = cfg.tiers[site.tier]
        options[#options + 1] = { id = "s:" .. key, label = site.label, description = site.area,
            disabled = self.siteOf[key] ~= nil,
            metadata = { { label = "Tier", value = ("%d %s"):format(site.tier, tier.label) },
                { label = "Reward", value = ("%d to %d"):format(tier.reward.min, tier.reward.max) } } }
    end
    local answer = P.uikit.context(pid, { id = "nr_sites", title = "Post a contract", options = options }, { timeoutMs = 60000 })
    if type(answer) ~= "table" or not answer.ok or type(answer.value) ~= "table" then return end
    local key = tostring(answer.value.id):match("^s:(.+)$")
    local site = key and self.sites[key]
    if not site then return end
    local tier = cfg.tiers[site.tier]
    local form = P.uikit.input(pid, { title = ("Contract on the %s"):format(site.label),
        description = ("Tier %d %s. The client pays the reward; your cut is %d%%."):format(site.tier, tier.label,
            math.floor((cfg.cut.rate or 0) * 100 + 0.5)),
        fields = {
            { id = "reward", type = "number", label = "Reward (eddies)", min = tier.reward.min, max = tier.reward.max,
              step = 50, default = tier.reward.default, required = true },
            { id = "minutes", type = "number", label = "Deadline (minutes)", min = tier.minutes.min, max = tier.minutes.max,
              step = 5, default = tier.minutes.default, required = true },
        },
        confirm = "Post", cancel = "Cancel", timeoutMs = 60000 })
    if type(form) ~= "table" or not form.ok or type(form.value) ~= "table" then return end
    local summary, why = self:post({ site = key, fixer = pid, point = point,
        reward = M.integer(form.value.reward), minutes = M.integer(form.value.minutes) })
    if not summary then self:refuseTo(pid, why) end
end

-- ---------------------------------------------------------------------------------------------
-- Chat views
-- ---------------------------------------------------------------------------------------------
function S:listTo(pid)
    local P, M = self.P, self.M
    local now = P.nowS()
    local list = self:sorted()
    if #list == 0 then return P.say(pid, "The board is empty right now.") end
    P.say(pid, ("Contracts on the board (%d):"):format(#list))
    for i, c in ipairs(list) do
        if i > 12 then
            P.say(pid, ("... and %d more."):format(#list - 12))
            break
        end
        P.say(pid, M.line(c, self.sites[c.site], self.cfg.tiers[c.tier], now))
    end
end

function S:sitesTo(pid)
    local P = self.P
    for _, site in ipairs(self.cfg.sites) do
        if self.sites[site.key] then
            local tier = self.cfg.tiers[site.tier]
            P.say(pid, ("%s: %s (%s), tier %d %s, reward %d-%d, deadline %d-%d min%s"):format(site.key, site.label,
                site.area or "?", site.tier, tier.label, tier.reward.min, tier.reward.max, tier.minutes.min, tier.minutes.max,
                self.siteOf[site.key] and ", busy" or ""))
        end
    end
end

-- The contract part of /netrun.
function S:contractLines(pid)
    local M, P = self.M, self.P
    local subject = self.L.subjectOf(pid)
    local c = self:activeContract(subject)
    if not c then
        local open = #self:sorted({ state = "open" })
        return { ("Contract: none. %d open on the board (/netrun contracts)."):format(open) }
    end
    local site = self.sites[c.site]
    local drop = self.fixers[c.point]
    local left = M.clock(M.secondsLeft(c, P.nowS()))
    if c.state == "taken" then
        local pos = site and site.position
        return { ("Contract %s: breach the %s (%s)%s, %s left, %d attempt(s) made."):format(c.code,
            site and site.label or c.site, site and site.area or "?",
            pos and (" at %.0f, %.0f"):format(pos.x, pos.y) or "", left, c.attempts or 0) }
    end
    local where = c.poster == "player" and ("hand it to %s (/netrun deliver)"):format(tostring(c.fixerName))
        or ("drop it at %s"):format(drop and drop.label or tostring(c.point))
    return { ("Contract %s: shard pulled, %s, %s left. Pay %s."):format(c.code, where, left, M.money(c.reward - (c.cut or 0))) }
end

function S:statusTo(pid)
    for _, line in ipairs(self:contractLines(pid)) do self.P.say(pid, line) end
end

-- ---------------------------------------------------------------------------------------------
-- Players leaving, shutdown
-- ---------------------------------------------------------------------------------------------
function S:onDisconnected(pid)
    pid = self.M.playerId(pid)
    if not pid then return end
    self.notified[pid] = nil
    self.heat[pid] = nil
    for subject, id in pairs(self.online) do if id == pid then self.online[subject] = nil end end
end

function S:onReady(pid)
    pid = self.M.playerId(pid)
    if not pid then return end
    local subject = self.L.subjectOf(pid)
    if subject then self.online[subject] = pid end
end

function S:shutdown()
    -- The coordinator cancels this resource's reservations when it stops; the platform cancels its
    -- interactions. Heat this resource raised is lowered back.
    for pid, h in pairs(self.heat) do
        local policy = self.P.players.getWanted(pid)
        if type(policy) == "table" and self.M.integer(policy.level) == h.level then self.P.players.setWanted(pid, h.before) end
    end
    self.heat = {}
end

return S
