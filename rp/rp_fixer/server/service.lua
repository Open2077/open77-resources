-- rp_fixer / server/service.lua: the contract board.
--
--   post        a fixer NPC (from its `offers`) or a fixer on duty (board menu) posts a contract;
--               the record is saved, then ONE rp_economy operation escrows the reward
--               (poster's wallet, or sys:rp_fixer:board for an NPC) into soc:fixer_escrow
--   take        a runner takes it at any fixer point (rep gate, one claim); a delivery sets its
--               crate at the pickup, a claimed bounty spawns its cyberpsycho
--   work        delivery: carry the crate to the drop and put it down there (open77_actions carry)
--               retrieval: hand the goods over at the fixer point (open77_actions action: reserve
--               the goods before the bar, commit after it, one coordinator operation)
--               job order: `rp:job:completed` events of the runner, each `ref` counted once
--               bounty: the cyberpsycho's death credited to the player who killed it
--   pay         state `paying` saved first, then ONE rp_economy operation out of escrow: the net to
--               the runner, the cut to the fixers' society; then reputation (exactly once, keyed)
--   refund      expiry, cancellation or a spoiled bounty: state `refunding` saved, then ONE
--               operation gives the whole escrow back to the poster
--
-- Durable truth: SQL (server/store.lua) for the contracts and reputation, rp_economy /
-- open77_transactions for money and goods. Every money operation id is derived from the
-- contract id, so a retry, a double press or a restart replays the first receipt. Runtime
-- handles (crate item, NPC ids) live in `self.rt` and are rebuilt at every start.
--
-- Global: FixerService.

FixerService = {}
local S = {}
S.__index = S

local ACTIONS = "open77_actions"
local KIND_CRATE = "fx_crate"
local TRANSIENT = { in_doubt = true, busy = true, store_unavailable = true, coordinator_unavailable = true,
    rp_economy_unavailable = true, conflict = true, export_timeout = true }

function FixerService.new(deps)
    local self = setmetatable({
        cfg = deps.config, M = deps.model, L = deps.ledger, P = deps.ports, St = deps.store,
        resource = deps.resource or "rp_fixer",
        ready = false, declared = false,
        contracts = {},   -- [id] = contract: every live one, plus the recently settled
        bySeq = {},       -- [seq] = id
        recent = {},      -- settled ids, oldest first (bounded)
        rt = {},          -- [id] = { crate = itemId, npc = npcId, engaged = pid, respawnAt = ms, itemsDone }
        players = {},     -- [pid] = { subject, name }
        pidOf = {},       -- [subject] = pid
        reps = {},        -- [subject] = { score, completed, failed }
        psychos = {},     -- [tostring(npcId)] = contract id
        crates = {},      -- [itemId] = contract id
        contacts = {},    -- [hub] = npc id
        locks = {}, driving = {}, nextTry = {}, notified = {}, lastHit = {},
        templates = {},   -- [id] = template that passed the start-up check
        seq = 0, refillAt = 0,
        stats = { posted = 0, voided = 0, taken = 0, completed = 0, refunded = 0, abandoned = 0,
                  jobEvents = 0, kills = 0, handovers = 0, deliveries = 0 },
    }, S)
    return self
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

function S:tellSubject(subject, text, kind)
    local pid = subject and self.pidOf[subject]
    if pid then self:tell(pid, text, kind) end
end

function S:refuse(pid, reason)
    pid = self.M.playerId(pid)
    if not pid then return end
    local now, key = self.P.now(), pid .. ":" .. tostring(reason)
    if (self.notified[key] or 0) + self.cfg.notifyCooldownMs > now then return end
    self.notified[key] = now
    self.P.tell(pid, self.M.textFor(reason), "warning")
end

-- ---------------------------------------------------------------------------------------------
-- Records, locks, persistence
-- ---------------------------------------------------------------------------------------------
function S:runtime(id)
    local r = self.rt[id]
    if not r then
        r = {}
        self.rt[id] = r
    end
    return r
end

function S:lock(id, timeoutMs)
    local deadline = self.P.now() + (timeoutMs or 30000)
    while self.locks[id] do
        if self.P.now() > deadline then return false end
        self.P.wait(50)
    end
    self.locks[id] = true
    return true
end

function S:unlock(id) self.locks[id] = nil end

-- Runs fn() while holding the contract's lock. Answers fn's values, or nil, "busy".
function S:withLock(id, fn)
    if not self:lock(id) then return nil, "busy" end
    local r = table.pack(pcall(fn))
    self:unlock(id)
    if not r[1] then
        self:warn("contract %s: %s", tostring(id), tostring(r[2]))
        return nil, "internal_error"
    end
    return table.unpack(r, 2, r.n)
end

-- Applies `mutate` to the record and saves it. A refused save puts the record back as it was.
function S:change(c, mutate)
    local before = self.M.copy(c)
    mutate(c)
    local ok, why = self.St.save(c, self.P.unix())
    if not ok then
        for k in pairs(c) do c[k] = nil end
        for k, v in pairs(before) do c[k] = v end
        self:warn("contract %s not saved (%s): change undone", tostring(c.id), tostring(why))
        return nil, why or "database_unavailable"
    end
    return true
end

function S:remember(c)
    self.contracts[c.id] = c
    self.bySeq[c.seq] = c.id
end

-- A settled contract stays readable for a while (/contract, the board's "mine" rows).
function S:settled(c)
    self.recent[#self.recent + 1] = c.id
    while #self.recent > self.cfg.recentKept do
        local old = table.remove(self.recent, 1)
        local oc = self.contracts[old]
        if oc and self.M.FINAL[oc.state] then
            self.contracts[old] = nil
            self.bySeq[oc.seq] = nil
            self.rt[old] = nil
        end
    end
end

function S:find(ref)
    if type(ref) == "string" and self.contracts[ref] then return self.contracts[ref] end
    local text = type(ref) == "string" and (ref:gsub("^#", "")) or ref
    local n = tonumber(text)
    local id = n and self.bySeq[math.tointeger(n) or -1]
    return id and self.contracts[id] or nil
end

function S:liveCount()
    local n = 0
    for _, c in pairs(self.contracts) do if self.M.LIVE[c.state] then n = n + 1 end end
    return n
end

local function bySeq(a, b) return a.seq < b.seq end

function S:held(subject)
    local out = {}
    for _, c in pairs(self.contracts) do
        if c.state == "taken" and c.runner and c.runner.subject == subject then out[#out + 1] = c end
    end
    table.sort(out, bySeq)
    return out
end

function S:postedBy(subject)
    local out = {}
    for _, c in pairs(self.contracts) do
        if c.poster and c.poster.subject == subject and (self.M.LIVE[c.state]) then out[#out + 1] = c end
    end
    table.sort(out, bySeq)
    return out
end

-- ---------------------------------------------------------------------------------------------
-- Players
-- ---------------------------------------------------------------------------------------------
function S:viewer(pid)
    pid = self.M.playerId(pid)
    local p = pid and self.players[pid]
    if not p then return nil, "not_loaded" end
    local rep = self.reps[p.subject]
    if not rep then return nil, "not_loaded" end
    -- The character name is read again here: at the join rp_identity may not have the citizen
    -- yet, and the board then named a player by their account (live 2026-10-13: "Posted by
    -- WiFem", "taken by CyberwareA" for Mira Sato and Ada Kovac).
    local okName, name = pcall(self.P.players.rpName, pid)
    if okName and type(name) == "string" and name ~= "" then p.name = name end
    return { pid = pid, subject = p.subject, name = p.name, score = rep.score, held = #self:held(p.subject) }
end

-- The name to show for a contract party: the character name when that player is here now, else
-- the one stored on the contract (a contract keeps the name it was taken under).
function S:liveName(party)
    if type(party) ~= "table" then return "?" end
    local pid = party.subject and self.pidOf[party.subject]
    local v = pid and self:viewer(pid)
    return (v and v.name) or party.name or "?"
end

-- Loads the reputation of a player when it is missing (yields).
function S:ensureViewer(pid)
    local v, why = self:viewer(pid)
    if v then return v end
    pid = self.M.playerId(pid)
    if not pid then return nil, why end
    local p = self.players[pid]
    if not p then
        self:playerJoined(pid)
    elseif not self.reps[p.subject] then
        local rep = self.St.loadRep(p.subject)
        if rep then self.reps[p.subject] = rep end
    end
    return self:viewer(pid)
end

function S:playerJoined(pid)
    pid = self.M.playerId(pid)
    if not pid then return end
    local subject, why = self.L.subjectOf(pid)
    if not subject then
        self:warn("player %d has no durable subject (%s): the board ignores them", pid, tostring(why))
        return
    end
    self.players[pid] = { subject = subject, name = self.P.players.rpName(pid) or ("player " .. pid) }
    self.pidOf[subject] = pid
    if not self.reps[subject] then
        local rep, rwhy = self.St.loadRep(subject)
        if rep then
            self.reps[subject] = rep
            local _, tier = self.M.tierOf(rep.score, self.cfg.tiers)
            self:log("player %d reputation %d (%s)", pid, rep.score, tier.name)
        else
            self:warn("player %d reputation not readable (%s): asked again on their next request", pid, tostring(rwhy))
        end
    end
    self:sendHubs(pid)
    self:sendObjectives(subject)
    -- Once more a little later, for a client whose script was still loading.
    self.P.spawn(function()
        self.P.wait(10000)
        if self.players[pid] and self.players[pid].subject == subject then
            self:sendHubs(pid)
            self:sendObjectives(subject)
        end
    end)
    if self.ready then
        for _, c in ipairs(self:held(subject)) do
            self:tell(pid, "Your contract " .. self.M.progressLine(c, self.cfg, self.P.unix()), "info")
        end
    end
end

function S:playerLeft(pid)
    pid = self.M.playerId(pid)
    local p = pid and self.players[pid]
    if not p then return end
    self.players[pid] = nil
    if self.pidOf[p.subject] == pid then self.pidOf[p.subject] = nil end
    for key in pairs(self.notified) do
        if key:sub(1, #tostring(pid) + 1) == pid .. ":" then self.notified[key] = nil end
    end
end

function S:hubList()
    local list = {}
    for _, key in ipairs(self.cfg.hubOrder) do
        local h = self.cfg.hubs[key]
        if h then
            list[#list + 1] = { key = key, label = h.label, fixer = h.fixer, district = h.district,
                position = self.M.copy(h.position) }
        end
    end
    return list
end

function S:sendHubs(pid) self.P.toClient(pid, "rp_fixer:hubs", self:hubList()) end

-- The runner's objectives: map pins, the first one routed (client/main.lua).
function S:sendObjectives(subject)
    local pid = subject and self.pidOf[subject]
    if not pid then return end
    local list = {}
    for _, c in ipairs(self:held(subject)) do
        local o = self.M.objectiveOf(c, self.cfg)
        if o then
            o.title = self.M.code(c) .. " " .. c.title
            list[#list + 1] = o
        end
    end
    self.P.toClient(pid, "rp_fixer:objectives", list)
end

-- ---------------------------------------------------------------------------------------------
-- Declarations (re-run whenever open77_actions restarts)
-- ---------------------------------------------------------------------------------------------
function S:checkTemplates()
    for id, t in pairs(self.cfg.templates) do
        local problem = self.M.checkTemplate(id, t, self.cfg)
        if problem then
            self:warn("template %s left out: %s", id, problem)
        else
            self.templates[id] = t
        end
    end
end

function S:hubTarget(key, hub)
    return {
        id = "hub_" .. key, position = hub.position, yaw = hub.yaw, bucket = self.cfg.bucket,
        label = hub.label, description = hub.fixer .. "'s contracts", distance = 2.0, markerDistance = 25.0,
        requires = "empty", data = { hub = key },
        actions = { { action = "board", label = "Contract board" }, { action = "handover", label = "Hand over the goods" } },
    }
end

function S:dropTarget(key, drop)
    return {
        id = "drop_" .. key, position = drop.position, bucket = self.cfg.bucket,
        label = "Fixer drop: " .. drop.label, distance = 2.5, markerDistance = 15.0, requires = "carrying",
        data = { drop = key }, actions = { { action = "open77_actions:carry_putdown", label = "Deliver the crate" } },
    }
end

function S:declare()
    local cfg, A = self.cfg, self.P.actions
    local defs = {
        { id = "board", label = cfg.actions.board.label, durationMs = cfg.actions.board.durationMs,
          maxDistance = cfg.actions.maxDistance, claim = false, progress = false, claims = false,
          hooks = { commit = "fxBoard" } },
        { id = "handover", label = cfg.actions.handover.label, durationMs = cfg.actions.handover.durationMs,
          maxDistance = cfg.actions.maxDistance, animation = cfg.actions.handover.animation,
          progress = { label = cfg.actions.handover.progress }, reserveTimeoutMs = 20000,
          hooks = { validate = "fxHandValidate", reserve = "fxHandReserve", commit = "fxHandCommit",
                    cancel = "fxHandCancel" } },
    }
    for _, def in ipairs(defs) do
        local key, why = A.define(def)
        if not key then
            self:warn("action %s refused by open77_actions: %s", def.id, tostring(why))
            return false
        end
    end
    local kind, kwhy = A.carryDefine({
        id = KIND_CRATE, model = cfg.crate.model, label = cfg.crate.label, reach = cfg.crate.reach,
        dropMessage = false,     -- crateDropped tells the runner, with the contract
        hooks = { validate = "fxCrateValidate", pickup = "fxCratePickup", putdown = "fxCratePutdown",
                  dropped = "fxCrateDropped" },
    })
    if not kind then
        self:warn("carry kind refused by open77_actions: %s", tostring(kwhy))
        return false
    end
    for _, key in ipairs(cfg.hubOrder) do
        local hub = cfg.hubs[key]
        local ok, why = A.target(self:hubTarget(key, hub))
        if not ok then self:warn("fixer point %s refused: %s", key, tostring(why)) end
        ok, why = A.target(self:dropTarget(key, hub))
        if not ok then self:warn("drop %s refused: %s", key, tostring(why)) end
    end
    for key, drop in pairs(cfg.drops) do
        local ok, why = A.target(self:dropTarget(key, drop))
        if not ok then self:warn("drop %s refused: %s", key, tostring(why)) end
    end
    self.declared = true
    return true
end

-- The contact NPC standing at each board (presentation only).
function S:spawnContacts()
    local cfg = self.cfg.contactNpc
    if not cfg.enabled then return end
    for _, key in ipairs(self.cfg.hubOrder) do
        local hub = self.cfg.hubs[key]
        if hub.contact and not self.contacts[key] then
            local def = { position = hub.contact.position, yaw = hub.contact.yaw, bucket = self.cfg.bucket,
                damagePolicy = cfg.damagePolicy, behavior = { combatEnabled = false, voiceEnabled = false },
                streamingRadius = 120, despawnWhenUnobserved = false, persistent = false }
            if cfg.record then def.record = cfg.record else def.template = cfg.template end
            local ok, id, why = pcall(self.P.npcs.create, def)
            if ok and id then
                self.contacts[key] = id
                pcall(self.P.npcs.hold, id)
            else
                self:warn("contact at %s not spawned: %s", key, tostring(ok and why or id))
            end
        end
    end
end

-- ---------------------------------------------------------------------------------------------
-- World state of a contract: the crate, the cyberpsycho
-- ---------------------------------------------------------------------------------------------
function S:placeCrate(c)
    local rt = self:runtime(c.id)
    if rt.crate and self.P.actions.carryGet(rt.crate) then return true end
    local itemId, why = self.P.actions.carryPlace(KIND_CRATE, { position = c.crate.position, yaw = c.crate.yaw or 0.0,
        bucket = self.cfg.bucket, data = { contract = c.id } })
    if not itemId then
        self:warn("contract %s crate not placed: %s (asked again by the sweep)", c.id, tostring(why))
        return false
    end
    rt.crate = itemId
    self.crates[itemId] = c.id
    return true
end

function S:removeCrate(c)
    local rt = self.rt[c.id]
    if rt and rt.crate then
        self.P.actions.carryRemove(rt.crate)
        self.crates[rt.crate] = nil
        rt.crate = nil
    end
end

function S:spawnPsycho(c)
    local rt = self:runtime(c.id)
    if rt.npc then return true end
    local spot, sighting = self.M.sighting(c, self.cfg)
    local p = self.cfg.psycho
    if not spot then
        -- A saved bounty whose sighting is gone from the config: nothing to spawn. It stays on
        -- the board and runs out (refunded) unless the sighting comes back.
        if not rt.noSighting then
            self:warn("contract %s: sighting %s is not configured; no cyberpsycho", c.id, tostring(c.target.sighting))
            rt.noSighting = true
        end
        rt.respawnAt = self.P.now() + p.respawnMs
        return false
    end
    rt.noSighting = nil
    -- Never on top of someone: a body spawned inside a player has been credited to that player
    -- as hits nobody fired. Asked again by the sweep once the spot is clear.
    local clear = p.clearRadius or 0
    if clear > 0 then
        for _, pos in pairs(self.P.players.positions() or {}) do
            local d = type(pos) == "table" and (pos.bucket or 0) == self.cfg.bucket and self.M.distance(pos, spot.position)
            if d and d <= clear then
                rt.respawnAt = self.P.now() + (p.clearRetryMs or 5000)
                return false
            end
        end
    end
    local def = {
        record = p.record, position = spot.position, yaw = spot.yaw or 0.0, bucket = self.cfg.bucket,
        health = p.health, maxHealth = p.health, damagePolicy = self.P.npcs.mortal(),
        behavior = { hitPricing = "platform" },
        loadout = { combat = { group = p.group, acquirePlayers = true } },
        streamingRadius = 200, despawnWhenUnobserved = false, persistent = false,
    }
    local ok, id, why = pcall(self.P.npcs.create, def)
    if ok and not id and tostring(why):find("behavior") then
        -- A host without platform hit pricing: players could only kill it if a resource priced
        -- their hits. Spawn it anyway and say so once.
        def.behavior = nil
        self:warn("contract %s: hitPricing refused (%s); kills will not be credited on this host", c.id, tostring(why))
        ok, id, why = pcall(self.P.npcs.create, def)
    end
    if not ok or not id then
        self:warn("contract %s cyberpsycho not spawned: %s (asked again in %d s)", c.id, tostring(ok and why or id),
            self.cfg.psycho.respawnMs // 1000)
        rt.respawnAt = self.P.now() + self.cfg.psycho.respawnMs
        return false
    end
    rt.npc, rt.engaged, rt.respawnAt = id, nil, nil
    self.psychos[tostring(id)] = c.id
    local okAtt, whyAtt = self.P.npcs.setAttitude(id, "hostile")
    if not okAtt then self:warn("contract %s psycho attitude refused: %s", c.id, tostring(whyAtt)) end
    local task, whyTask = self.P.npcs.guard(id, spot.position, p.leash)
    if not task then self:warn("contract %s psycho leash refused: %s", c.id, tostring(whyTask)) end
    self:log("contract %s cyberpsycho %s at %s", c.id, tostring(id), sighting)
    return true
end

function S:despawnPsycho(c)
    local rt = self.rt[c.id]
    if rt and rt.npc then
        self.psychos[tostring(rt.npc)] = nil
        self.lastHit[tostring(rt.npc)] = nil
        pcall(self.P.npcs.remove, rt.npc)
        rt.npc, rt.engaged = nil, nil
    end
    if rt then rt.respawnAt = nil end
end

function S:teardown(c)
    self:removeCrate(c)
    self:despawnPsycho(c)
end

-- What exists in the world for a contract in its state (start, take, restart).
function S:materialize(c)
    if c.kind == "delivery" and c.state == "taken" then
        self:placeCrate(c)
    elseif c.kind == "bounty" and ((c.state == "open" and c.mode == "open") or c.state == "taken") then
        self:spawnPsycho(c)
    end
end

-- ---------------------------------------------------------------------------------------------
-- Posting
-- ---------------------------------------------------------------------------------------------
function S:nextSeq()
    self.seq = self.seq + 1
    return self.seq
end

function S:escrowSpec(c)
    local cfg = self.cfg
    if c.poster.kind == "npc" then
        return "pay", { opId = c.ops.escrow, from = { sys = cfg.npcFunding }, to = { society = cfg.escrowSociety },
            amount = c.reward, reason = ("fixer contract %d escrow"):format(c.seq) }
    end
    return "charge", { opId = c.ops.escrow, from = { subject = c.poster.subject }, amount = c.reward,
        instrument = cfg.escrowInstrument, to = { society = cfg.escrowSociety },
        reason = ("fixer contract %d escrow"):format(c.seq) }
end

-- spec = { template, hub, kind = "npc" | "player", pid?, reward?, hours?, brief?, mode? }.
-- Yields. Answers the contract once it is open, or nil, reason ("escrow_pending": the escrow
-- answer did not come yet, the sweep settles it).
function S:post(spec)
    local cfg, M = self.cfg, self.M
    if not self.ready then return nil, "not_ready" end
    local t = self.templates[spec.template or ""]
    if not t then return nil, "unknown_template" end
    local hub = cfg.hubs[spec.hub or ""]
    if not hub then return nil, "unknown_hub" end
    if not (t.posters and t.posters[spec.kind]) then return nil, "not_posted_here" end
    if self:liveCount() >= cfg.maxLive then return nil, "board_full" end
    local poster, reward, hours = nil, nil, t.hours
    if spec.kind == "player" then
        local v, why = self:ensureViewer(spec.pid)
        if not v then return nil, why end
        local eligible, ewhy = self.P.jobs.eligible(v.pid, cfg.fixerJob)
        if not eligible then return nil, ewhy or "not_a_fixer" end
        if #self:postedBy(v.subject) >= cfg.maxPerPoster then return nil, "poster_limit" end
        local why2
        reward, why2 = M.chooseReward(t, spec.reward, cfg.rewardStep)
        if not reward then return nil, why2 end
        if spec.hours ~= nil then
            local okHours = tonumber(spec.hours) == t.hours
            for _, h in ipairs(cfg.postHours) do if tonumber(spec.hours) == h then okHours = true end end
            if not okHours then return nil, "invalid_hours" end
            hours = tonumber(spec.hours)
        end
        poster = { kind = "player", subject = v.subject, name = v.name }
    else
        if spec.reward ~= nil then
            local why2
            reward, why2 = M.chooseReward(t, spec.reward, 1)
            if not reward then return nil, why2 end
        else
            reward = M.npcReward(t, math.random(), cfg.rewardStep)
        end
        poster = { kind = "npc", name = hub.fixer }
    end
    local itemLabel
    if t.kind == "retrieval" and self.P.running("rp_inventory") then
        local def = self.P.inventory.itemDefinition(t.item)
        if type(def) ~= "table" then return nil, "unknown_item" end
        itemLabel = type(def.label) == "string" and M.ascii(def.label, 40) or nil
    end
    local mode = nil
    if t.kind == "bounty" and spec.kind == "player" and (spec.mode == "open" or spec.mode == "claimed") then
        mode = spec.mode
    end
    local seq = self:nextSeq()
    local id = ("%s.fx%d"):format(self.serverTag, seq)
    local c = M.newContract({
        id = id, seq = seq, templateId = spec.template, template = t, hub = spec.hub, poster = poster,
        reward = reward, hours = hours, brief = spec.brief and M.ascii(spec.brief, cfg.briefMax) or nil,
        mode = mode, now = self.P.unix(), cutRate = cfg.cutRate[poster.kind] or 0, cfg = cfg,
    })
    if c.want and itemLabel and itemLabel ~= "" then c.want.label = itemLabel end
    -- A player-posted retrieval delivers the goods into the poster's drop box: it must exist.
    if c.kind == "retrieval" and poster.kind == "player" then
        local opened, owhy = self.L.open(self.L.box(poster.subject), { capacityG = 200000 })
        if not opened and owhy ~= "already_exists" then
            self:warn("drop box of %s not opened: %s", poster.subject, tostring(owhy))
        end
    end
    local saved, swhy = self.St.save(c, self.P.unix())
    if not saved then return nil, swhy or "database_unavailable" end
    self:remember(c)
    return self:escrow(c)
end

-- Sends the escrow of a `posting` contract (also the sweep's retry: same id, replay-safe).
function S:escrow(c)
    local method, spec = self:escrowSpec(c)
    local receipt, why, info = self.P.economy[method](spec)
    return self:afterEscrow(c, receipt, why, info)
end

function S:afterEscrow(c, receipt, why, info)
    if receipt then
        local opened = false
        local ok, swhy = self:withLock(c.id, function()
            if c.state ~= "posting" then return true end
            local done, w = self:change(c, function(x) x.state = "open"; x.escrowedAt = self.P.unix() end)
            opened = done == true
            return done, w
        end)
        if not ok then
            -- Escrowed but not saved: the sweep finds the committed escrow and opens it.
            return nil, swhy or "escrow_pending"
        end
        if opened then self:opened(c) end
        return c
    end
    if TRANSIENT[why] or (type(info) == "table" and info.retryable) then
        self:log("contract %s escrow %s not settled yet (%s): the sweep follows it", c.id, c.ops.escrow, tostring(why))
        return nil, "escrow_pending"
    end
    self:void(c, why)
    return nil, why
end

function S:void(c, why)
    self:withLock(c.id, function()
        if c.state ~= "posting" then return end
        self:change(c, function(x) x.state = "void"; x.reason = tostring(why); x.settledAt = self.P.unix() end)
    end)
    self.stats.voided = self.stats.voided + 1
    self:log("contract %s void: escrow refused (%s)", c.id, tostring(why))
    self:tellSubject(c.poster.subject, ("Contract %s not posted: %s"):format(self.M.code(c), self.M.textFor(why)), "warning")
    self:settled(c)
end

function S:opened(c)
    local M = self.M
    self.stats.posted = self.stats.posted + 1
    self:log("contract %s open: %s %s reward=%d net=%d cut=%d by %s at %s expires in %s", c.id, c.kind, c.template,
        c.reward, c.net, c.cut, c.poster.kind == "npc" and ("npc " .. c.poster.name) or c.poster.subject, c.hub,
        M.duration(c.expiresAt - self.P.unix()))
    self:materialize(c)
    self.P.emit("rp_fixer:contract", c.id, "open", 0, M.summary(c))
    self.P.emit("rp_fixer:gig", c.seq, "published", c.poster.subject and self.pidOf[c.poster.subject] or 0)
    local hub = self.cfg.hubs[c.hub]
    self:tellSubject(c.poster.subject, ("Contract %s is up at %s: %s, %s escrowed (%s to the runner, %s to the fixers)."):format(
        M.code(c), hub.label, c.title, M.money(c.reward), M.money(c.net), M.money(c.cut)), "success")
    if self.cfg.announce then
        local line = ("New contract at %s: %s %s, pays %s%s."):format(hub.label, M.code(c), c.title, M.money(c.net),
            c.mode == "open" and " (open bounty)" or "")
        for pid, p in pairs(self.players) do
            local rep = self.reps[p.subject]
            if p.subject ~= c.poster.subject and (c.mode == "open" or (rep and rep.score >= (c.minRep or 0))) then
                self:tell(pid, line, "info")
            end
        end
    end
end

-- ---------------------------------------------------------------------------------------------
-- Taking, abandoning, cancelling
-- ---------------------------------------------------------------------------------------------
function S:take(pid, ref)
    local v, why = self:ensureViewer(pid)
    if not v then return nil, why end
    local c = self:find(ref)
    if not c then return nil, "contract_unavailable" end
    local ok, reason = self:withLock(c.id, function()
        local refusal = self.M.takeRefusal(c, { subject = v.subject, score = self.reps[v.subject].score,
            held = #self:held(v.subject) }, self.cfg, self.P.unix())
        if refusal then return nil, refusal end
        return self:change(c, function(x)
            x.state = "taken"
            x.runner = { subject = v.subject, name = v.name }
            x.takenAt = self.P.unix()
            x.takes = (x.takes or 0) + 1
            if x.crate then x.crate.carried = false end
        end)
    end)
    if not ok then return nil, reason end
    self.stats.taken = self.stats.taken + 1
    self:materialize(c)
    local M = self.M
    self:log("contract %s taken by player %d (%s)", c.id, v.pid, v.subject)
    self:tell(v.pid, ("Contract taken: %s"):format(M.progressLine(c, self.cfg, self.P.unix())), "success")
    self:sendObjectives(v.subject)
    self:tellSubject(c.poster.subject, ("Your contract %s was taken by %s."):format(M.code(c), self:liveName(v)), "info")
    self.P.emit("rp_fixer:contract", c.id, "taken", v.pid, M.summary(c))
    self.P.emit("rp_fixer:gig", c.seq, "accepted", v.pid)
    return c
end

-- A reputation change, exactly once per key, mirrored into the cache.
function S:reputation(subject, key, delta, completed, failed)
    if not subject then return nil, "no_subject" end
    local floor = self.cfg.reputation.floor or 0
    local result, why = self.St.applyRep(subject, key, delta, completed or 0, failed or 0, floor, self.P.unix())
    if not result then
        self:warn("reputation of %s not changed (%s, key %s)", subject, tostring(why), key)
        return nil, why
    end
    if result == "applied" then
        local rep = self.reps[subject]
        if rep then
            rep.score = self.M.applyDelta(rep.score, delta, floor)
            rep.completed = rep.completed + (completed or 0)
            rep.failed = rep.failed + (failed or 0)
        else
            self.reps[subject] = self.St.loadRep(subject)
        end
    end
    return result
end

function S:abandon(pid, ref)
    local v, why = self:ensureViewer(pid)
    if not v then return nil, why end
    local c = self:find(ref)
    if not c then return nil, "contract_unavailable" end
    local takes
    local ok, reason = self:withLock(c.id, function()
        if c.state ~= "taken" or not c.runner or c.runner.subject ~= v.subject then return nil, "not_your_contract" end
        takes = c.takes or 1
        self:teardown(c)
        return self:change(c, function(x)
            x.state = "open"
            x.runner = nil
            x.takenAt = nil
            if x.order then x.order.progress, x.order.refs = 0, {} end
            if x.crate then
                local from = self.cfg.points[x.route.from]
                x.crate.position, x.crate.yaw, x.crate.carried = self.M.copy(from.position), from.yaw or 0.0, false
            end
        end)
    end)
    if not ok then
        if c.state == "taken" then self:materialize(c) end
        return nil, reason
    end
    self.stats.abandoned = self.stats.abandoned + 1
    self:reputation(v.subject, ("%s:abandon:%d"):format(c.id, takes), self.cfg.reputation.abandon, 0, 1)
    self:materialize(c)
    self:sendObjectives(v.subject)
    local rep = self.reps[v.subject]
    self:tell(v.pid, ("You walked away from %s. Reputation %d."):format(self.M.code(c), rep and rep.score or 0), "warning")
    self:tellSubject(c.poster.subject, ("Your contract %s is back on the board: the runner walked."):format(self.M.code(c)), "info")
    self.P.emit("rp_fixer:contract", c.id, "abandoned", v.pid, self.M.summary(c))
    self.P.emit("rp_fixer:gig", c.seq, "abandoned", v.pid)
    return c
end

function S:cancel(pid, ref)
    local v, why = self:ensureViewer(pid)
    if not v then return nil, why end
    local c = self:find(ref)
    if not c then return nil, "contract_unavailable" end
    if not c.poster.subject or c.poster.subject ~= v.subject then return nil, "not_your_contract" end
    if c.state == "taken" then return nil, "contract_taken" end
    if c.state ~= "open" then return nil, "contract_unavailable" end
    return self:startRefund(c, "cancelled", nil, "open")
end

-- ---------------------------------------------------------------------------------------------
-- Settling: payout and refund
-- ---------------------------------------------------------------------------------------------
-- Moves a taken contract (or an open bounty) to `paying` for `payee`. Saved before any money
-- moves. Call with the contract's lock held.
function S:beginPayout(c, payee)
    if c.state ~= "taken" and not (c.state == "open" and c.mode == "open") then return nil, "contract_unavailable" end
    local ok, why = self:change(c, function(x)
        x.state = "paying"
        x.outcome = "completed"
        x.payee = { subject = payee.subject, name = payee.name }
    end)
    if not ok then return nil, why end
    self:teardown(c)
    self.P.spawn(function() self:drive(c.id) end)
    return true
end

-- Refunds the poster. Takes the contract's lock itself; `onlyIn` limits it to one state (a
-- cancellation must not refund a contract a runner took in the meantime).
function S:startRefund(c, outcome, note, onlyIn)
    local runner
    local ok, why = self:withLock(c.id, function()
        if c.state ~= "open" and c.state ~= "taken" then return nil, "contract_unavailable" end
        if onlyIn and c.state ~= onlyIn then return nil, c.state == "taken" and "contract_taken" or "contract_unavailable" end
        runner = c.state == "taken" and c.runner or nil
        return self:change(c, function(x)
            x.state = "refunding"
            x.outcome = outcome
            x.note = note
        end)
    end)
    if not ok then return nil, why end
    self:teardown(c)
    if runner then
        self:sendObjectives(runner.subject)
        if outcome == "expired" then
            self:reputation(runner.subject, c.id .. ":expire", self.cfg.reputation.expire, 0, 1)
            local rep = self.reps[runner.subject]
            self:tellSubject(runner.subject, ("Too slow: contract %s ran out. Reputation %d."):format(self.M.code(c),
                rep and rep.score or 0), "warning")
            self.P.emit("rp_fixer:gig", c.seq, "timeout", self.pidOf[runner.subject] or 0)
        end
    end
    self.P.spawn(function() self:drive(c.id) end)
    return c
end

function S:payoutSpec(c)
    local payees = { { subject = c.payee.subject, amount = c.net } }
    if c.cut > 0 then payees[#payees + 1] = { society = self.cfg.cutSociety, amount = c.cut } end
    return { opId = self.M.payOpId(c), from = { society = self.cfg.escrowSociety }, payees = payees,
        reason = ("fixer contract %d payout"):format(c.seq) }
end

function S:refundSpec(c)
    local to = c.poster.kind == "npc" and { sys = self.cfg.npcFunding } or { subject = c.poster.subject }
    return { opId = self.M.payOpId(c), from = { society = self.cfg.escrowSociety }, to = to, amount = c.reward,
        reason = ("fixer contract %d refund (%s)"):format(c.seq, tostring(c.outcome)) }
end

-- Sends the payout or the refund of a settling contract until it commits. One driver per
-- contract at a time; the sweep calls it again after `retryMs`.
function S:drive(id)
    if self.driving[id] then return end
    local c = self.contracts[id]
    if not c or (c.state ~= "paying" and c.state ~= "refunding") then return end
    self.driving[id] = true
    local ok, err = pcall(function()
        local spec = c.state == "paying" and self:payoutSpec(c) or self:refundSpec(c)
        local receipt, why, info = self.P.economy.pay(spec)
        if receipt then
            self:finish(c, receipt)
            return
        end
        self.nextTry[id] = self.P.now() + self.cfg.retryMs
        if type(info) == "table" and info.state == "aborted" then
            -- The id was fenced (settled as never committed): the next attempt uses a new one.
            self:withLock(id, function()
                self:change(c, function(x) x.ops.attempt = self.M.int(x.ops.attempt, 1) + 1 end)
            end)
            self.nextTry[id] = self.P.now()
            self:warn("contract %s %s fenced: next attempt %s", id, spec.opId, self.M.payOpId(c))
        elseif TRANSIENT[why] or (type(info) == "table" and info.retryable) then
            self:log("contract %s %s not settled yet (%s): retried", id, spec.opId, tostring(why))
        else
            self:warn("contract %s %s refused (%s): retried every %d s until an operator fixes it", id, spec.opId,
                tostring(why), self.cfg.retryMs // 1000)
        end
    end)
    self.driving[id] = nil
    if not ok then self:warn("contract %s settle raised: %s", id, tostring(err)) end
end

function S:finish(c, receipt)
    local M = self.M
    local wasPaying = c.state == "paying"
    if wasPaying then
        local applied, why = self:reputation(c.payee.subject, c.id .. ":done", c.repGain, 1, 0)
        if not applied then
            self.nextTry[c.id] = self.P.now() + self.cfg.retryMs
            self:warn("contract %s paid, reputation pending (%s): retried", c.id, tostring(why))
            return
        end
    end
    local final = M.OUTCOME_STATE[c.outcome] or "completed"
    local ok = self:withLock(c.id, function()
        if c.state ~= "paying" and c.state ~= "refunding" then return true end
        return self:change(c, function(x) x.state = final; x.settledAt = self.P.unix() end)
    end)
    if not ok then
        self.nextTry[c.id] = self.P.now() + self.cfg.retryMs
        return
    end
    self.nextTry[c.id] = nil
    self.St.history(c, self.P.unix())
    self:settled(c)
    local hub = self.cfg.hubs[c.hub]
    if wasPaying then
        self.stats.completed = self.stats.completed + 1
        local pid = self.pidOf[c.payee.subject]
        local rep = self.reps[c.payee.subject]
        local _, tier = M.tierOf(rep and rep.score or 0, self.cfg.tiers)
        self:log("contract %s completed: %s paid %d to %s, cut %d to %s (op %s%s)", c.id, c.kind, c.net,
            c.payee.subject, c.cut, self.cfg.cutSociety, tostring(receipt.opId), receipt.replay and ", replay" or "")
        self:tellSubject(c.payee.subject, ("Contract %s done: %s in cash. Reputation %d (%s)."):format(M.code(c),
            M.money(c.net), rep and rep.score or 0, tier.name), "success")
        self:tellSubject(c.poster.subject, ("Your contract %s was completed by %s."):format(M.code(c), self:liveName(c.payee)), "info")
        self:sendObjectives(c.payee.subject)
        self.P.emit("rp:job:completed", { job = "fixer", kind = "contract_completed", playerId = pid or 0,
            ref = M.payOpId(c), data = { contract = c.id, seq = c.seq, contractKind = c.kind, template = c.template,
            hub = c.hub, reward = c.reward, net = c.net, cut = c.cut, poster = c.poster.subject or ("npc:" .. c.hub) } })
        self.P.emit("rp_fixer:contract", c.id, "completed", pid or 0, M.summary(c))
        self.P.emit("rp_fixer:gig", c.seq, "success", pid or 0)
    else
        self.stats.refunded = self.stats.refunded + 1
        self:log("contract %s %s: %d refunded to %s (op %s)", c.id, c.state, c.reward,
            c.poster.subject or ("npc " .. tostring(c.poster.name)), tostring(receipt.opId))
        self:tellSubject(c.poster.subject, ("Contract %s %s: %s back in your wallet."):format(M.code(c), c.state,
            M.money(c.reward)), "info")
        self.P.emit("rp_fixer:contract", c.id, c.state, 0, M.summary(c))
        if c.poster.kind == "npc" and hub then self.refillAt = math.min(self.refillAt, self.P.now() + 60000) end
    end
end

-- ---------------------------------------------------------------------------------------------
-- Delivery: the crate (open77_actions carry hooks)
-- ---------------------------------------------------------------------------------------------
function S:crateValidate(ctx)
    if not fromActions() then return false, "not_owner" end
    if ctx.kind ~= "carry_pickup" then return true end
    local c = self.contracts[ctx.carry and ctx.carry.data and ctx.carry.data.contract or ""]
    local reason
    if not c or c.state ~= "taken" then
        reason = "contract_closed"
    else
        local p = self.players[ctx.playerId]
        if not p or not c.runner or p.subject ~= c.runner.subject then reason = "not_your_crate" end
    end
    if reason then
        if ctx.phase == "begin" then self:refuse(ctx.playerId, reason) end
        return false, reason
    end
    return true
end

function S:cratePickup(ctx)
    if not fromActions() then return nil, "not_owner" end
    if not self.P.actions.verify(ctx.opId, "commit") then return nil, "not_owner" end
    local id = ctx.carry.data.contract
    local c = self.contracts[id]
    if c and c.crate then
        c.crate.carried = true
        self:sendObjectives(c.runner and c.runner.subject)
    end
    return { contract = id }
end

function S:cratePutdown(ctx)
    if not fromActions() then return nil, "not_owner" end
    if not self.P.actions.verify(ctx.opId, "commit") then return nil, "not_owner" end
    local id = ctx.carry.data.contract
    local c = self.contracts[id]
    local drop = ctx.target and ctx.target.data and ctx.target.data.drop
    if drop == nil then
        -- An ordinary put-down (G): the crate stays where it lands; the carry event records it.
        if c and c.crate then c.crate.carried = false end
        return { contract = id }
    end
    if not c then return nil, "contract_closed" end
    local ok, why = self:withLock(id, function()
        if c.state ~= "taken" then return nil, "contract_closed" end
        if drop ~= c.route.to then return nil, "wrong_drop" end
        local p = self.players[ctx.playerId]
        if not p or p.subject ~= c.runner.subject then return nil, "not_your_crate" end
        local rt = self:runtime(id)
        if rt.crate then self.crates[rt.crate] = nil end
        rt.crate = nil       -- the library removes the prop after this commit
        return self:beginPayout(c, c.runner)
    end)
    if not ok then
        self:refuse(ctx.playerId, why)
        return nil, why
    end
    self.stats.deliveries = self.stats.deliveries + 1
    self:log("contract %s crate delivered at %s by player %s", id, drop, tostring(ctx.playerId))
    return { contract = id, delivered = true, placement = { kind = "remove" } }
end

function S:crateDropped(ctx)
    if not fromActions() then return end
    local c = self.contracts[ctx.data and ctx.data.contract or ""]
    if not c or c.state ~= "taken" or type(ctx.position) ~= "table" then return end
    self:withLock(c.id, function()
        self:change(c, function(x)
            x.crate.position = { x = ctx.position.x, y = ctx.position.y, z = ctx.position.z }
            x.crate.carried = false
        end)
    end)
    self:sendObjectives(c.runner.subject)
    self:tellSubject(c.runner.subject, ("The crate of %s fell from your hands, at your feet. Pick it up again."):format(
        self.M.code(c)), "warning")
end

-- The open77_actions:carry event of one of our crates: where a put-down landed.
function S:onCarry(payload)
    if type(payload) ~= "table" or payload.owner ~= self.resource then return end
    local id = self.crates[payload.itemId or ""]
    local c = id and self.contracts[id]
    if not c or c.state ~= "taken" then return end
    if payload.phase == "put_down" and payload.placement ~= "remove" then
        local item = self.P.actions.carryGet(payload.itemId)
        if type(item) == "table" and type(item.position) == "table" then
            self:withLock(id, function()
                self:change(c, function(x)
                    x.crate.position = { x = item.position.x, y = item.position.y, z = item.position.z }
                    x.crate.yaw = item.yaw or x.crate.yaw
                    x.crate.carried = false
                end)
            end)
            self:sendObjectives(c.runner.subject)
        end
    elseif payload.phase == "removed" then
        self.crates[payload.itemId] = nil
        local rt = self.rt[id]
        if rt and rt.crate == payload.itemId then rt.crate = nil end
    end
end

-- ---------------------------------------------------------------------------------------------
-- Retrieval: the hand-over at a fixer point (open77_actions action hooks)
-- ---------------------------------------------------------------------------------------------
-- The runner's retrieval contract handed over at this fixer point, or nil.
function S:retrievalAt(pid, hubKey)
    local p = self.players[pid]
    if not p then return nil end
    for _, c in ipairs(self:held(p.subject)) do
        if c.kind == "retrieval" and c.want.drop == hubKey then return c end
    end
    return nil
end

function S:handValidate(ctx)
    if not fromActions() then return false, "not_owner" end
    local hubKey = ctx.target and ctx.target.data and ctx.target.data.hub
    local c = self:retrievalAt(ctx.playerId, hubKey)
    local reason
    if not c then
        reason = "no_retrieval_here"
    else
        local rt = self.rt[c.id]
        if rt and rt.itemsDone then reason = "already_handed" end
    end
    if reason then
        if ctx.phase == "begin" then self:refuse(ctx.playerId, reason) end
        return false, reason
    end
    return true
end

function S:handReserve(ctx)
    if not fromActions() then return nil, "not_owner" end
    if not self.P.actions.verify(ctx.opId, "reserve") then return nil, "not_owner" end
    local hubKey = ctx.target and ctx.target.data and ctx.target.data.hub
    local c = self:retrievalAt(ctx.playerId, hubKey)
    if not c then return nil, "no_retrieval_here" end
    local L = self.L
    local pockets = L.pockets(c.runner.subject)
    local to = c.poster.kind == "player" and L.box(c.poster.subject) or "sys:fixer.retrieval"
    local spec = { opId = c.ops.items, kind = "fixer.retrieval", actor = pockets, ttlMs = 60000,
        reason = ("fixer contract %d"):format(c.seq),
        lines = { { item = c.want.item, count = c.want.count, from = pockets, to = to } } }
    local held, why, info = L.reserve(spec)
    if not held and why == "unknown_account" and c.poster.kind == "player" then
        L.open(to, { capacityG = 200000 })
        held, why, info = L.reserve(spec)
    end
    if not held then
        if why == "already_committed" then
            return { contract = c.id, txOpId = c.ops.items, already = true }
        end
        return nil, why, info
    end
    return { contract = c.id, txOpId = c.ops.items }
end

function S:handCommit(ctx)
    if not fromActions() then return nil, "not_owner" end
    if not self.P.actions.verify(ctx.opId, "commit") then return nil, "not_owner" end
    local r = ctx.reservation or {}
    local c = self.contracts[r.contract or ""]
    if not c then return nil, "contract_closed" end
    if not r.already then
        local receipt, why = self.L.commit(r.txOpId)
        if not receipt then return nil, why end
    end
    self:runtime(c.id).itemsDone = true
    self.stats.handovers = self.stats.handovers + 1
    local ok, why = self:withLock(c.id, function()
        if c.state ~= "taken" then return true end
        return self:beginPayout(c, c.runner)
    end)
    if not ok then
        -- The goods are in; the payout state is not saved yet: the sweep tries again.
        self:warn("contract %s goods in, payout not started (%s): the sweep retries", c.id, tostring(why))
    end
    return { contract = c.id, txOpId = r.txOpId, handed = true }
end

function S:handCancel(ctx)
    if not fromActions() then return end
    local r = ctx.reservation
    if not r or not r.txOpId or r.already then return end
    if ctx.reason ~= "in_doubt" then
        self.L.cancel(r.txOpId, ctx.reason)
        return
    end
    -- In doubt: the sweep asks the coordinator (this contract's goods op) until it knows.
    local c = self.contracts[r.contract or ""]
    if c then self:runtime(c.id).checkItems = true end
end

-- A taken retrieval whose goods may already be in (in doubt, or a restart between the goods
-- commit and the payout state): ask the coordinator, without fencing the id.
function S:checkItems(c)
    local state = self.L.peek(c.ops.items)
    if state == "committed" then
        self:runtime(c.id).itemsDone = true
        self:withLock(c.id, function()
            if c.state == "taken" then return self:beginPayout(c, c.runner) end
        end)
        return true
    end
    if state == "none" then self:runtime(c.id).checkItems = nil end
    return false
end

-- ---------------------------------------------------------------------------------------------
-- Job orders: other jobs report their committed steps
-- ---------------------------------------------------------------------------------------------
function S:onJobCompleted(payload)
    if not self.ready then return end
    local ev, why = self.M.normalizeJobEvent(payload)
    if not ev then return end
    local p = self.players[ev.playerId]
    if not p then return end
    for _, c in ipairs(self:held(p.subject)) do
        local inc = self.M.jobIncrement(c, ev)
        if inc then
            self.stats.jobEvents = self.stats.jobEvents + 1
            local done
            self:withLock(c.id, function()
                inc = self.M.jobIncrement(c, ev)       -- again, under the lock
                if not inc then return end
                local ok = self:change(c, function(x)
                    x.order.progress = math.min(x.order.count, (x.order.progress or 0) + inc)
                    x.order.refs[#x.order.refs + 1] = ev.ref
                    while #x.order.refs > 128 do table.remove(x.order.refs, 1) end
                end)
                if not ok then return end
                if c.order.progress >= c.order.count then
                    done = self:beginPayout(c, c.runner)
                end
            end)
            if inc and not done then
                self:tell(ev.playerId, ("Contract %s: %d / %d."):format(self.M.code(c), c.order.progress, c.order.count), "info")
            end
            return
        end
    end
end

-- ---------------------------------------------------------------------------------------------
-- Bounties: the cyberpsycho's death
-- ---------------------------------------------------------------------------------------------
function S:onNpcDamaged(npcId, source, amount)
    local key = tostring(npcId)
    if not self.psychos[key] then return end
    local pid = self.M.playerId(tostring(source or ""):match("^player:(%d+)$"))
    if pid then self.lastHit[key] = { pid = pid, at = self.P.now() } end
end

function S:killerOf(key, source)
    local pid = self.M.playerId(tostring(source or ""):match("^player:(%d+)$"))
    if pid then return pid end
    local hit = self.lastHit[key]
    if hit and self.P.now() - hit.at <= self.cfg.psycho.creditWindowMs then return hit.pid end
    return nil
end

function S:onNpcDied(npcId, source, cause)
    local key = tostring(npcId)
    local id = self.psychos[key]
    if not id then return end
    local killer = self:killerOf(key, source)
    self.psychos[key] = nil
    self.lastHit[key] = nil
    self.stats.kills = self.stats.kills + 1
    self:log("contract %s cyberpsycho %s died (source %s, cause %s): credited to %s", id, key, tostring(source),
        tostring(cause), killer and ("player " .. killer) or "nobody")
    -- The body stays a while for everyone to see, then goes.
    local body = math.tointeger(tonumber(key))
    if body then
        self.P.spawn(function()
            self.P.wait(self.cfg.psycho.corpseMs or 30000)
            pcall(self.P.npcs.remove, body)
        end)
    end
    self:bountyKilled(id, killer)
end

function S:bountyKilled(id, killerPid)
    local c = self.contracts[id]
    if not c or c.kind ~= "bounty" then return end
    local rt = self:runtime(id)
    rt.npc, rt.engaged = nil, nil
    local killer = killerPid and self.players[killerPid] or nil
    local M = self.M
    if c.state == "open" and c.mode == "open" then
        if killer and killer.subject ~= c.poster.subject then
            local ok, why = self:withLock(id, function() return self:beginPayout(c, killer) end)
            if not ok then self:warn("contract %s kill not paid yet (%s)", id, tostring(why)) end
            return
        end
        rt.respawnAt = self.P.now() + self.cfg.psycho.respawnMs
        return
    end
    if c.state ~= "taken" then return end
    if killer and killer.subject == c.runner.subject then
        local ok, why = self:withLock(id, function() return self:beginPayout(c, c.runner) end)
        if not ok then self:warn("contract %s kill not paid yet (%s)", id, tostring(why)) end
        return
    end
    if killer and c.target.onForeignKill ~= "respawn" then
        self:tellSubject(c.runner.subject, ("Someone else put down the psycho of %s. The contract is void, nobody gets paid."):format(
            M.code(c)), "warning")
        self:startRefund(c, "spoiled", "killed by another player")
        return
    end
    if killer then
        self:tellSubject(c.runner.subject, ("Someone else killed your target of %s. Regina says another one is out there."):format(
            M.code(c)), "warning")
    end
    rt.respawnAt = self.P.now() + self.cfg.psycho.respawnMs
end

-- Orders each cyberpsycho at the nearest player in range (once per second; bounded by the
-- number of bounties, one positions read for all).
function S:engage()
    local any = false
    for _ in pairs(self.psychos) do any = true break end
    if not any then return end
    local now = self.P.now()
    local positions = self.P.players.positions()
    for key, id in pairs(self.psychos) do
        local c = self.contracts[id]
        local rt = c and self.rt[id]
        if rt and rt.npc then
            local sighting = self.M.sighting(c, self.cfg)
            local spot = sighting and sighting.position
            local best, bestD
            for pid, pos in pairs(spot and positions or {}) do
                pid = self.M.playerId(pid)
                if pid and type(pos) == "table" and (pos.bucket or 0) == self.cfg.bucket then
                    local d = self.M.distance(pos, spot)
                    if d and d <= self.cfg.psycho.engageDistance and (not bestD or d < bestD) then best, bestD = pid, d end
                end
            end
            -- A new nearest player, or the same one again every 10 s (an attack the engine
            -- refused on a mounted player fails without telling us).
            if best and (rt.engaged ~= best or now - (rt.engagedAt or 0) >= 10000) then
                local task, why = self.P.npcs.attack(rt.npc, best)
                if task then
                    rt.engaged, rt.engagedAt = best, now
                else
                    self:warn("contract %s attack refused: %s", id, tostring(why))
                end
            elseif not best then
                rt.engaged, rt.engagedAt = nil, nil
            end
        end
    end
end

-- ---------------------------------------------------------------------------------------------
-- The board (UI kit)
-- ---------------------------------------------------------------------------------------------
-- The board prompt's commit hook: nothing moves, the receipt names the fixer point and the
-- transition handler opens the menu.
function S:boardCommit(ctx)
    if not fromActions() then return nil, "not_owner" end
    if not self.P.actions.verify(ctx.opId, "commit") then return nil, "not_owner" end
    return { hub = ctx.target and ctx.target.data and ctx.target.data.hub or nil }
end

function S:nearestHub(pid)
    pid = self.M.playerId(pid)
    if not pid then return nil, nil end
    local pos = self.P.players.position(pid)
    if type(pos) ~= "table" then return nil, nil end
    local best, bestD
    for _, key in ipairs(self.cfg.hubOrder) do
        local d = self.M.distance(pos, self.cfg.hubs[key].position)
        if d and (not bestD or d < bestD) then best, bestD = key, d end
    end
    return best, bestD
end

-- The fixer point a player stands at (within boardReach), or nil, the nearest one and its distance.
function S:atHub(pid)
    local hub, d = self:nearestHub(pid)
    if hub and d and d <= self.cfg.boardReach then return hub end
    return nil, hub, d
end

function S:isFixer(pid)
    local ok = self.P.jobs.eligible(pid, self.cfg.fixerJob)
    return ok == true
end

function S:boxItems(subject)
    local snap = self.L.read(self.L.box(subject))
    if type(snap) ~= "table" or type(snap.items) ~= "table" then return {} end
    local out = {}
    for item, count in pairs(snap.items) do
        count = self.M.int(count, 0)
        if count > 0 then out[#out + 1] = { item = item, count = count } end
    end
    table.sort(out, function(a, b) return a.item < b.item end)
    return out
end

function S:boardRows(v, hubKey)
    local cfg, M, now = self.cfg, self.M, self.P.unix()
    local list = {}
    for _, c in pairs(self.contracts) do
        if M.visibleTo(c, v.subject) then list[#list + 1] = c end
    end
    table.sort(list, function(a, b)
        local ma = (a.runner and a.runner.subject == v.subject) and 0 or 1
        local mb = (b.runner and b.runner.subject == v.subject) and 0 or 1
        if ma ~= mb then return ma < mb end
        local ha, hb = a.hub == hubKey and 0 or 1, b.hub == hubKey and 0 or 1
        if ha ~= hb then return ha < hb end
        return a.seq < b.seq
    end)
    local rows = {}
    for _, c in ipairs(list) do
        if #rows >= 56 then break end
        local hub = cfg.hubs[c.hub]
        local mine = c.runner and c.runner.subject == v.subject
        local posted = c.poster.subject == v.subject
        local locked = c.state == "open" and not posted and c.mode ~= "open" and v.score < (c.minRep or 0)
        local status
        if mine then status = "Yours: " .. M.progressLine(c, cfg, now):gsub("^#%d+ ", ""):sub(1, 60)
        elseif posted then status = c.state == "taken" and ("Posted by you, taken by " .. self:liveName(c.runner)) or ("Posted by you (" .. c.state .. ")")
        elseif c.mode == "open" then status = "Open bounty: the kill pays"
        else status = "Open" end
        local tier = M.tierFor(c.minRep, cfg.tiers)
        rows[#rows + 1] = {
            id = "c:" .. c.id, icon = M.KIND_ICON[c.kind],
            label = M.ascii(("%s %s: %s"):format(M.code(c), M.KIND_LABEL[c.kind], c.title), 96),
            description = M.ascii(c.brief, 240), disabled = locked or nil, tone = mine and "success" or nil,
            metadata = {
                { label = "Pays", value = M.money(c.net) },
                { label = "Fixer", value = M.ascii(("%s, %s"):format(c.poster.kind == "npc" and (c.poster.name or "?") or self:liveName(c.poster), hub and hub.label or "?"), 64) },
                { label = "Time left", value = M.duration(c.expiresAt - now) },
                { label = locked and "Rep needed" or "Status",
                  value = M.ascii(locked and ("%s (%d+)"):format(tier.name, c.minRep) or status, 64) },
            },
        }
    end
    if self:isFixer(v.pid) then
        rows[#rows + 1] = { id = "post", icon = "+", label = "Post a contract",
            description = "Your eddies back the reward: they wait in escrow until the job is done or the contract ends." }
    end
    local box = self:boxItems(v.subject)
    if #box > 0 then
        local parts = {}
        for _, e in ipairs(box) do parts[#parts + 1] = ("%d x %s"):format(e.count, e.item) end
        rows[#rows + 1] = { id = "box", icon = "B", label = "Collect your drop box",
            description = M.ascii(table.concat(parts, ", "), 240) }
    end
    if #rows == 0 then rows[1] = { id = "none", label = "No contract on the board right now", disabled = true } end
    return rows
end

-- Opens the board for a player at a fixer point (yields: the player answers).
function S:openBoard(pid, hubKey)
    local v, why = self:ensureViewer(pid)
    if not v then return self:refuse(pid, why) end
    local hub = self.cfg.hubs[hubKey or ""]
    if not hub then return end
    local _, tier = self.M.tierOf(v.score, self.cfg.tiers)
    local answer, uwhy = self.P.ui.context(v.pid, {
        id = "fx_board", title = self.M.ascii(("%s - %s"):format(hub.label, hub.fixer), 96),
        description = self.M.ascii(("Reputation %d (%s). Contracts pay in cash on completion."):format(v.score, tier.name), 240),
        options = self:boardRows(v, hubKey),
    })
    if not answer then
        self:log("board for player %d refused by the UI kit (%s): chat fallback", v.pid, tostring(uwhy))
        return self:chatBoard(v.pid)
    end
    if not answer.ok or type(answer.value) ~= "table" then return end
    local choice = tostring(answer.value.id or "")
    if choice:sub(1, 2) == "c:" then return self:contractDialog(v.pid, choice:sub(3), hubKey) end
    if choice == "post" then return self:postDialog(v.pid, hubKey) end
    if choice == "box" then return self:collectBox(v.pid) end
end

function S:contractDialog(pid, id, hubKey)
    local v = self:viewer(pid)
    local c = self.contracts[id]
    if not v or not c then return self:refuse(pid, "contract_unavailable") end
    local M, cfg, now = self.M, self.cfg, self.P.unix()
    local hub = cfg.hubs[c.hub]
    local lines = { c.brief, "", ("Pays %s (reward %s, the fixers keep %s)."):format(M.money(c.net), M.money(c.reward), M.money(c.cut)),
        ("Posted by %s at %s. Time left: %s."):format(c.poster.kind == "npc" and (c.poster.name or "?") or self:liveName(c.poster), hub.label, M.duration(c.expiresAt - now)) }
    if c.kind == "delivery" then
        local drop = cfg.hubs[c.route.to] or cfg.drops[c.route.to]
        lines[#lines + 1] = ("Pick the crate up at %s, carry it on foot to %s."):format(cfg.points[c.route.from].label, drop.label)
    elseif c.kind == "retrieval" then
        lines[#lines + 1] = ("Bring %d x %s to %s."):format(c.want.count, c.want.label or c.want.item,
            cfg.hubs[c.want.drop].label)
    elseif c.kind == "job" then
        lines[#lines + 1] = ("Job order: %d x %s (%s). Progress %d / %d."):format(c.order.count,
            table.concat(c.order.kinds, "/"), c.order.job, c.order.progress or 0, c.order.count)
    elseif c.kind == "bounty" then
        local sighting = M.sighting(c, cfg)
        lines[#lines + 1] = ("Sighting: %s. %s"):format(sighting and sighting.label or "unknown",
            c.mode == "open" and "Open bounty: whoever kills it is paid." or "Claimed bounty: only the runner who took it is paid.")
    end
    local message = table.concat(lines, "\n")
    local mine = c.runner and c.runner.subject == v.subject
    local posted = c.poster.subject == v.subject
    local def
    if mine then
        def = { title = M.ascii(M.code(c) .. " " .. c.title, 96), message = message, confirm = "Abandon it",
            cancel = "Keep at it", tone = "danger" }
    elseif posted and c.state == "open" then
        def = { title = M.ascii(M.code(c) .. " " .. c.title, 96), message = message, confirm = "Cancel, refund me",
            cancel = "Keep it up", tone = "warning" }
    elseif c.state == "open" and c.mode ~= "open" and not posted then
        def = { title = M.ascii(M.code(c) .. " " .. c.title, 96), message = message, confirm = "Take the contract",
            cancel = "Not now" }
    else
        def = { title = M.ascii(M.code(c) .. " " .. c.title, 96), message = message, confirm = "Close" }
    end
    def.timeoutMs = 60000
    local answer = self.P.ui.alert(pid, def)
    if type(answer) ~= "table" or not answer.ok or answer.value ~= "confirm" or def.confirm == "Close" then return end
    local ok, why
    if mine then
        ok, why = self:abandon(pid, c.id)
    elseif posted then
        ok, why = self:cancel(pid, c.id)
        if ok then self:tell(pid, ("Contract %s cancelled: the refund is on its way."):format(M.code(c)), "info") end
    else
        if self:atHub(pid) ~= hubKey then return self:refuse(pid, "too_far") end
        ok, why = self:take(pid, c.id)
    end
    if not ok then self:refuse(pid, why) end
end

function S:postDialog(pid, hubKey)
    local M, cfg = self.M, self.cfg
    if not self:isFixer(pid) then return self:refuse(pid, "not_a_fixer") end
    local options = {}
    for _, id in ipairs(cfg.templateOrder) do
        local t = self.templates[id]
        if t and t.posters.player then
            options[#options + 1] = { id = "t:" .. id, icon = M.KIND_ICON[t.kind],
                label = M.ascii(("%s: %s"):format(M.KIND_LABEL[t.kind], t.title), 96), description = M.ascii(t.brief, 240),
                metadata = {
                    { label = "Reward", value = ("%s to %s"):format(M.money(t.reward.min), M.money(t.reward.max)) },
                    { label = "Rep needed", value = ("%s (%d+)"):format(M.tierFor(t.minRep, cfg.tiers).name, t.minRep or 0) },
                } }
        end
    end
    if #options == 0 then return end
    local answer = self.P.ui.context(pid, { id = "fx_post", title = "Post a contract", options = options })
    if type(answer) ~= "table" or not answer.ok or type(answer.value) ~= "table" then return end
    local templateId = tostring(answer.value.id or ""):match("^t:(.+)$")
    local t = templateId and self.templates[templateId]
    if not t then return end
    -- The offered durations, with the template's own (the default) among them.
    local hourList, seen = {}, {}
    for _, h in ipairs(cfg.postHours) do hourList[#hourList + 1] = h; seen[h] = true end
    if not seen[t.hours] then hourList[#hourList + 1] = t.hours end
    table.sort(hourList)
    local hours = {}
    for _, h in ipairs(hourList) do hours[#hours + 1] = { value = tostring(h), label = ("%d h"):format(h) } end
    local fields = {
        { id = "reward", type = "slider", label = "Reward (eddies, escrowed now)", min = t.reward.min, max = t.reward.max,
          step = cfg.rewardStep, default = t.reward.min },
        { id = "hours", type = "select", label = "Expires in", options = hours, default = tostring(t.hours) },
        { id = "brief", type = "textarea", label = "Your brief (optional)", max = cfg.briefMax, placeholder = t.brief:sub(1, 96) },
    }
    if t.kind == "bounty" then
        fields[#fields + 1] = { id = "mode", type = "select", label = "Who gets paid",
            options = { { value = "claimed", label = "Only the runner who takes it" }, { value = "open", label = "Whoever kills it" } },
            default = t.mode }
    end
    local form = self.P.ui.input(pid, { title = M.ascii(t.title, 96), fields = fields, confirm = "Post it", cancel = "Back",
        timeoutMs = 90000 })
    if type(form) ~= "table" or not form.ok or type(form.value) ~= "table" then return end
    local reward = M.chooseReward(t, form.value.reward, cfg.rewardStep)
    if not reward then return self:refuse(pid, "reward_out_of_range") end
    local net, cut = M.split(reward, cfg.cutRate.player)
    local confirm = self.P.ui.alert(pid, { title = "Escrow " .. M.money(reward),
        message = ("%s leaves your wallet now (cash, then bank) and waits in escrow.\nThe runner gets %s, the fixers keep %s.\nIf nobody finishes it in time, or you cancel it while it is open, all of it comes back."):format(
            M.money(reward), M.money(net), M.money(cut)), confirm = "Post it", cancel = "Not now", timeoutMs = 60000 })
    if type(confirm) ~= "table" or not confirm.ok then return end
    if self:atHub(pid) ~= hubKey then return self:refuse(pid, "too_far") end
    local c, why = self:post({ template = templateId, hub = hubKey, kind = "player", pid = pid, reward = reward,
        hours = tonumber(form.value.hours), brief = form.value.brief, mode = form.value.mode })
    if not c then
        if why == "escrow_pending" then return self:tell(pid, M.textFor(why), "info") end
        return self:refuse(pid, why)
    end
end

-- Empties the player's drop box into their pockets, in one operation.
function S:collectBox(pid)
    local v, why = self:ensureViewer(pid)
    if not v then return self:refuse(pid, why) end
    local items = self:boxItems(v.subject)
    if #items == 0 then return self:tell(pid, "Your drop box is empty.", "info") end
    local box, pockets = self.L.box(v.subject), self.L.pockets(v.subject)
    local lines = {}
    for i, e in ipairs(items) do
        if i > 48 then break end
        lines[#lines + 1] = { item = e.item, count = e.count, from = box, to = pockets }
    end
    local receipt, twhy = self.L.transfer({ opId = self.L.newOpId("box"), kind = "fixer.box", actor = pockets, lines = lines })
    if not receipt then return self:refuse(pid, twhy) end
    local parts = {}
    for _, l in ipairs(lines) do
        local def = self.P.inventory.itemDefinition(l.item)
        parts[#parts + 1] = ("%d x %s"):format(l.count, type(def) == "table" and def.label or l.item)
    end
    self:tell(pid, "You collect your drop box: " .. table.concat(parts, ", ") .. ".", "success")
end

-- The board in chat, when the UI kit is not there.
function S:chatBoard(pid)
    local v = self:viewer(pid)
    if not v then return end
    local M, now, n = self.M, self.P.unix(), 0
    local list = {}
    for _, c in pairs(self.contracts) do if M.visibleTo(c, v.subject) then list[#list + 1] = c end end
    table.sort(list, bySeq)
    for _, c in ipairs(list) do
        n = n + 1
        if n > 12 then break end
        self:tell(pid, ("%s %s at %s: pays %s, %s left%s%s"):format(M.code(c), c.title, self.cfg.hubs[c.hub].label,
            M.money(c.net), M.duration(c.expiresAt - now), c.mode == "open" and ", open bounty" or "",
            v.score < (c.minRep or 0) and (", rep " .. c.minRep .. "+") or ""), "chat")
    end
    if n == 0 then self:tell(pid, "No contract on the board right now.", "info") end
    self:tell(pid, "/contract take <number> at a fixer point. /contract for yours.", "chat")
end

-- ---------------------------------------------------------------------------------------------
-- NPC fixers keep their boards stocked
-- ---------------------------------------------------------------------------------------------
function S:refill()
    if not self.cfg.npcBoard.enabled then return end
    for _, key in ipairs(self.cfg.hubOrder) do
        local hub = self.cfg.hubs[key]
        local open, live = 0, {}
        for _, c in pairs(self.contracts) do
            if c.hub == key and c.poster.kind == "npc" and self.M.LIVE[c.state] then
                live[c.template] = true
                if c.state == "open" or c.state == "posting" then open = open + 1 end
            end
        end
        local candidates = {}
        for _, id in ipairs(hub.offers or {}) do
            local t = self.templates[id]
            if t and t.posters.npc and not live[id] then candidates[#candidates + 1] = id end
        end
        while open < (hub.keepOpen or 0) and #candidates > 0 and self:liveCount() < self.cfg.maxLive do
            local pick = table.remove(candidates, math.random(1, #candidates))
            local c, why = self:post({ template = pick, hub = key, kind = "npc" })
            if c or why == "escrow_pending" then
                open = open + 1
            elseif why == "unknown_item" then
                -- The item belongs to a job resource that is not running (an rp_ripperdoc box):
                -- this template waits, the others are posted. Nothing was written.
                self:log("%s skips %s: its item is not defined on this server", hub.fixer, pick)
            else
                -- A refusal that will not fix itself (a missing mint rule, a writers list): back
                -- off for half an hour instead of writing a void contract every refill.
                self:warn("%s could not post %s: %s (the NPC boards wait %d min)", hub.fixer, pick, tostring(why),
                    self.cfg.npcBoard.refillMs * 6 // 60000)
                self.refillAt = self.P.now() + self.cfg.npcBoard.refillMs * 6
                return
            end
        end
    end
end

-- ---------------------------------------------------------------------------------------------
-- Start and the sweep
-- ---------------------------------------------------------------------------------------------
-- Reloads every live contract and rebuilds what it needs in the world. Yields.
function S:load()
    local seq, why = self.St.maxSeq()
    if not seq then return nil, why end
    self.seq = math.max(self.seq, seq)
    local list, lwhy, bad = self.St.loadLive(self.cfg.maxLive * 4)
    if not list then return nil, lwhy end
    for _, id in ipairs(bad or {}) do self:warn("contract row %s does not decode: left as it is for an operator", id) end
    local counts = {}
    for _, c in ipairs(list) do
        c.seq = self.M.int(c.seq, 0)
        if c.crate then c.crate.carried = false end
        self:remember(c)
        counts[c.state] = (counts[c.state] or 0) + 1
    end
    for _, c in ipairs(list) do
        self:materialize(c)
        if c.state == "taken" and c.kind == "retrieval" then self:runtime(c.id).checkItems = true end
        if c.state == "paying" or c.state == "refunding" then self.nextTry[c.id] = 0 end
    end
    local parts = {}
    for state, n in pairs(counts) do parts[#parts + 1] = state .. "=" .. n end
    table.sort(parts)
    self:log("loaded %d live contracts (%s), next number %d", #list, table.concat(parts, " "), self.seq + 1)
    return true
end

function S:sweep()
    if not self.ready then return end
    local now, unix = self.P.now(), self.P.unix()
    local list = {}
    for _, c in pairs(self.contracts) do if self.M.LIVE[c.state] then list[#list + 1] = c end end
    table.sort(list, bySeq)
    for _, c in ipairs(list) do
        if not self.locks[c.id] then
            if (c.state == "open" or c.state == "taken") and unix >= c.expiresAt then
                self:startRefund(c, "expired")
            elseif c.state == "posting" and (unix - (c.postedAt or unix)) * 1000 >= self.cfg.postingSettleMs then
                self:settlePosting(c)
            elseif (c.state == "paying" or c.state == "refunding") and (self.nextTry[c.id] or 0) <= now
                and not self.driving[c.id] then
                self.nextTry[c.id] = now + self.cfg.retryMs
                self.P.spawn(function() self:drive(c.id) end)
            elseif c.state == "taken" then
                local rt = self:runtime(c.id)
                if c.kind == "delivery" and not rt.crate then self:placeCrate(c) end
                if c.kind == "retrieval" and (rt.checkItems or rt.itemsDone) then
                    if rt.itemsDone then
                        self:withLock(c.id, function() if c.state == "taken" then return self:beginPayout(c, c.runner) end end)
                    else
                        self:checkItems(c)
                    end
                end
            end
            if c.kind == "bounty" and self.M.LIVE[c.state] then self:watchPsycho(c, now) end
        end
    end
    if self.refillAt <= now then
        self.refillAt = now + self.cfg.npcBoard.refillMs
        self:refill()
    end
end

-- A posting whose escrow answer never came: ask rp_economy (which settles an unknown id for
-- good, so it can never commit later), then open or void.
function S:settlePosting(c)
    local st, why = self.P.economy.status(c.ops.escrow)
    if type(st) ~= "table" then
        self:log("contract %s escrow status unavailable (%s)", c.id, tostring(why))
        return
    end
    if st.state == "committed" then
        self:afterEscrow(c, st.receipt or { opId = c.ops.escrow })
    elseif st.state == "in_doubt" or st.state == "committing" or st.state == "reserved" then
        return
    else
        self:void(c, "escrow_" .. tostring(st.state))
    end
end

function S:watchPsycho(c, now)
    local rt = self:runtime(c.id)
    local wants = (c.state == "open" and c.mode == "open") or c.state == "taken"
    if not wants then return end
    if rt.npc then
        local npc = self.P.npcs.get(rt.npc)
        if npc == nil then
            -- Removed by someone else (an operator): it comes back.
            self.psychos[tostring(rt.npc)] = nil
            rt.npc, rt.engaged = nil, nil
            rt.respawnAt = now + self.cfg.psycho.respawnMs
        elseif (tonumber(npc.health) or 1) <= 0 then
            -- Health backstop: dead without an onNpcDied (it has been seen not to arrive).
            local key = tostring(rt.npc)
            if self.psychos[key] then self:onNpcDied(key, "", "health_backstop") end
        end
    elseif rt.respawnAt and rt.respawnAt <= now then
        self:spawnPsycho(c)
    elseif not rt.respawnAt then
        rt.respawnAt = now
    end
end

-- Escrow audit: the escrow society's balance against the contracts that hold escrow.
function S:audit()
    local held = 0
    for _, c in pairs(self.contracts) do
        if c.state == "open" or c.state == "taken" or c.state == "paying" or c.state == "refunding" then
            held = held + c.reward
        end
    end
    local bal, why = self.P.economy.balanceOf({ society = self.cfg.escrowSociety })
    return held, type(bal) == "table" and bal.balance or nil, why
end

function S:shutdown()
    self.ready = false
end

return S
