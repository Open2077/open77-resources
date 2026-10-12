-- tests/compat/b7_ui_scenarios.lua: world-interaction row B7 (job/inventory/wallet UI), offline.
--
-- Loaded after fakehost.lua with the string globals REPO (pack root), HARNESS (tests/compat)
-- and TX_ROOT (an open77_transactions prototype, read-only). The rp_inventory scenarios run the
-- REAL rp_inventory server scripts (transactions backend) against the REAL A13 prototype through
-- txhost.lua and drive the panel exactly as a client would: the /inv command and the
-- rp_inventory:intent net event, with `source` set. The rp_hud scenarios run the REAL rp_hud
-- server script with stand-in B3/B4 providers. Each scenario returns flat key=value lines.
--
-- What this cannot show: the WebUI page, focus, chat or voice in a game client; real tick
-- ordering; the coordinator's wave-1 wiring. Nothing here is in-game evidence.

dofile(HARNESS .. "/txhost.lua")

local A, B = 7, 8
local CHAR_A = "char:acct-a"

local function players(extra)
    local p = {
        [A] = { identifier = "acct-a", name = "Alice", pos = { x = 0, y = 0, z = 0, bucket = 0 } },
        [B] = { identifier = "acct-b", name = "Bob", pos = { x = 1, y = 0, z = 0, bucket = 0 } },
    }
    for k, v in pairs(extra or {}) do p[k] = v end
    return p
end

local function bootTx(opts)
    opts = opts or {}
    TX.start({})
    return H.bootInventory({ backend = "transactions", players = opts.players or players(), config = opts.config })
end

-- Runs fn as a managed task and drives the clock until it finishes.
local function await(fn, maxSeconds)
    local box = H.task(fn)
    local waited = 0
    while not box.done and waited < (maxSeconds or 120) do
        H.run(0.5)
        waited = waited + 0.5
    end
    if not box.done then return "timeout" end
    return box[1], box[2], box[3]
end

-- A client net event: the registered handlers run as one task with `source` = the sender.
local function net(name, from, ...)
    local args = table.pack(...)
    return H.task(function()
        source = from
        for _, fn in ipairs(H.handlers[name] or {}) do fn(table.unpack(args, 1, args.n)) end
    end)
end
local function intent(from, payload) return net("rp_inventory:intent", from, payload) end
local function openInv(from)
    return H.task(function() source = from; H.commands.inv(from, {}) end)
end

-- A transfer by ANOTHER resource straight on the coordinator (a foreign writer).
local function foreign(spec)
    local box = {}
    TX.co:transfer(spec, "rp_other", function(r, reason) box.done, box.r, box.reason = true, r, reason end)
    return box
end

local function res(v, reason)
    if v == nil or v == false then return (v == false and "false" or "nil") .. ":" .. tostring(reason) end
    if type(v) == "table" then return "table" end
    return tostring(v)
end

-- Every rp_inventory:panel push to `target`, in order.
local function panelsOf(target)
    local out = {}
    for _, e in ipairs(H.client) do
        if e.name == "rp_inventory:panel" and e.target == target then out[#out + 1] = e.args[1] end
    end
    return out
end
local function lastPanel(target)
    local list = panelsOf(target)
    return list[#list]
end
-- "7x3,8x1": how many panel pushes went to each target (a -1 would be a broadcast).
local function panelTargets()
    local counts, keys = {}, {}
    for _, e in ipairs(H.client) do
        if e.name == "rp_inventory:panel" then
            local k = tostring(e.target)
            if not counts[k] then keys[#keys + 1] = k end
            counts[k] = (counts[k] or 0) + 1
        end
    end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = k .. "x" .. counts[k] end
    return table.concat(parts, ",")
end
local function entry(state, side, id)
    local c = state and state[side]
    for _, e in ipairs(c and c.entries or {}) do
        if e.id == id then return e end
    end
    return nil
end
-- The last notice pushed to `target` that matches `pred`.
local function noticeWhere(target, pred)
    local found
    for _, st in ipairs(panelsOf(target)) do
        if st.notice and pred(st.notice) then found = st.notice end
    end
    return found
end
local function noticeStr(n)
    if not n then return "none" end
    return ("%s|%s|%s|%s"):format(tostring(n.kind), tostring(n.reason), tostring(n.code), tostring(n.stale))
end
local function chatTo(target, prefix)
    for _, m in ipairs(H.chat) do
        if m.playerId == target and m.text:sub(1, #prefix) == prefix then return m.text end
    end
    return "none"
end

local scenarios = {}

-- ===========================================================================
-- Private, per-player refresh driven by the coordinator's committed event
-- ===========================================================================
function scenarios.panel_private_refresh()
    local out = {}
    bootTx()
    openInv(A)
    openInv(B)
    H.run(1)
    out.a_open = res(lastPanel(A) and lastPanel(A).open)
    out.b_open = res(lastPanel(B) and lastPanel(B).open)
    local seqBefore = lastPanel(A).seq
    H.client = {}
    -- Another resource credits A's pockets directly at the coordinator: rp_inventory hears of it
    -- only through open77_transactions:committed.
    local f = foreign({ opId = "foreign-b7-credit-01", kind = "rp_other",
        lines = { { item = "scrap", count = 3, from = "sys:rp_other", to = CHAR_A } } })
    H.run(2)
    out.foreign = res(f.r, f.reason)
    local st = lastPanel(A)
    local scrap = entry(st, "pockets", "scrap")
    out.a_scrap = scrap and tostring(scrap.count) or "none"
    out.targets = panelTargets()                -- only A, never B, never -1
    out.a_state_owner = tostring(st and st.playerId)
    out.seq_moved = tostring(st and st.seq > seqBefore)
    out.backend = tostring(st and st.backend)
    -- B's panel was not touched by A's change.
    out.b_pushes = tostring(#panelsOf(B))
    -- Nothing panel-shaped is broadcast: any rp_inventory:* client event with target -1 must be
    -- the catalogue head (public definitions), never a panel.
    local broadcast = {}
    for _, e in ipairs(H.client) do
        if e.target == -1 and e.name ~= "rp_inventory:catalogue" then broadcast[#broadcast + 1] = e.name end
    end
    out.broadcast = #broadcast == 0 and "none" or table.concat(broadcast, ",")
    return out
end

-- ===========================================================================
-- B1 metadata on the panel: stack variants (quality) and unique units (durability, serial)
-- ===========================================================================
function scenarios.panel_metadata()
    local out = {}
    local ex = bootTx()
    local reg, rej = H.as("c1_test", ex.define, {
        ore = { label = "Ore", weight = 1.0, quality = { min = 1, max = 3 } },
        tool = { label = "Tool", weight = 1.5, durability = 20, serial = true },
    })
    out.define = tostring(reg) .. "/" .. tostring(rej)
    H.run(1)
    out.add_q3 = res(ex.add(A, "ore", 2, { quality = 3 }))
    out.add_q1 = res(ex.add(A, "ore", 1))
    out.add_tool = res(ex.add(A, "tool", 2))
    H.run(2)
    local worn = await(function() return ex.wearAsync(A, "tool", 5) end)
    out.wear = type(worn) == "table" and ("dur=" .. tostring(worn.durability)) or res(worn)
    openInv(A)
    H.run(1)
    local st = lastPanel(A)
    local ore = entry(st, "pockets", "ore")
    out.ore_count = ore and tostring(ore.count) or "none"
    local variants = {}
    for _, v in ipairs(ore and ore.variants or {}) do
        variants[#variants + 1] = ("%s=%d@q%s"):format(v.asset, v.count, tostring(v.meta and v.meta.quality))
    end
    out.ore_variants = table.concat(variants, ",")
    local tool = entry(st, "pockets", "tool")
    out.tool_count = tool and tostring(tool.count) or "none"
    local durs, serialOk = {}, true
    for _, u in ipairs(tool and tool.units or {}) do
        durs[#durs + 1] = tostring(u.meta and u.meta.durability)
        if not (u.meta and u.meta.serial == u.id) then serialOk = false end
    end
    out.tool_durability = table.concat(durs, ",")    -- most worn first
    out.tool_serial_is_unit_id = tostring(serialOk and #durs > 0)
    out.tool_unique = tostring(tool and tool.unique)
    out.held = tostring((ore and ore.held) or 0) .. "/" .. tostring((tool and tool.held) or 0)
    return out
end

-- The unit lists are bounded per container (payload size), the rest counted.
function scenarios.panel_units_budget()
    local out = {}
    local ex = bootTx({ config = { panelUnitsBudget = 3 } })
    H.as("c1_test", ex.define, {
        tool = { label = "Tool", weight = 1.0, durability = 20, serial = true },
        knife = { label = "Knife", weight = 0.5, durability = 10 },
    })
    H.run(1)
    ex.add(A, "tool", 4)
    ex.add(A, "knife", 2)
    H.run(2)
    openInv(A)
    H.run(1)
    local st = lastPanel(A)
    local knife, tool = entry(st, "pockets", "knife"), entry(st, "pockets", "tool")
    out.knife = knife and (#(knife.units or {}) .. "+" .. tostring(knife.moreUnits)) or "none"
    out.tool = tool and (#(tool.units or {}) .. "+" .. tostring(tool.moreUnits) .. " count=" .. tool.count) or "none"
    return out
end

-- ===========================================================================
-- Refusals keep their reason; a stale click says so; the state is always the current one
-- ===========================================================================
function scenarios.panel_refusals()
    local out = {}
    local ex = bootTx()
    ex.add(A, "scrap", 5)
    H.run(2)
    H.task(function() ex.openStash(A, "home:b7", 1) end)     -- a 1 kg stash
    H.run(2)
    local st0 = lastPanel(A)
    out.stash_open = tostring(st0 and st0.stash and st0.stash.id)

    -- (a) refused locally: the stash cannot take 2 kg.
    H.client = {}
    intent(A, { action = "store", item = "scrap", count = 2, seq = st0.seq })
    H.run(1)
    local st1 = lastPanel(A)
    out.local_capacity = noticeStr(st1 and st1.notice)
    out.local_capacity_scrap = tostring(entry(st1, "pockets", "scrap").count)

    -- (b) refused by the coordinator: another resource filled the stash a moment before, and the
    -- panel's view has not heard of it yet (the committed event is queued to the next tick).
    local f = foreign({ opId = "foreign-b7-fill-01", kind = "rp_other",
        lines = { { item = "chip", count = 4, from = "sys:rp_other", to = "stash:home:b7" } } })
    out.fill = res(f.r, f.reason)
    local opsBefore = TX.ops("inv.store")
    H.client = {}
    intent(A, { action = "store", item = "scrap", count = 1, seq = st1.seq })
    H.run(1)
    local st2 = lastPanel(A)
    out.coordinator_capacity = noticeStr(st2 and st2.notice)
    out.coordinator_capacity_moved = tostring(TX.ops("inv.store") - opsBefore)
    out.after_refusal_pockets = tostring(TX.count(CHAR_A, "scrap")) .. "/" .. tostring(entry(st2, "pockets", "scrap").count)
    local chip = entry(st2, "stash", "chip")
    out.after_refusal_stash_shows_fill = chip and tostring(chip.count) or "none"

    -- (c) a click made on an old picture: the refusal says it changed meanwhile.
    H.client = {}
    intent(A, { action = "take", item = "water", count = 1, seq = 1 })
    H.run(1)
    local st3 = lastPanel(A)
    out.stale = noticeStr(st3 and st3.notice)
    out.stale_text = st3 and st3.notice and st3.notice.text or "none"

    -- (d) the coordinator is gone: nothing moved, try again.
    TX.stop()
    H.client = {}
    intent(A, { action = "take", item = "chip", count = 1, seq = st3.seq })
    H.run(1)
    local st4 = lastPanel(A)
    out.store_unavailable = noticeStr(st4 and st4.notice)
    out.store_unavailable_moved = tostring(TX.count(CHAR_A, "chip")) .. "/" .. tostring(TX.count("stash:home:b7", "chip"))

    -- (e) an unknown action and a forged item never reach a mutation.
    H.client = {}
    intent(A, { action = "sell", item = "scrap", count = 1 })
    H.run(1)
    out.unknown_action = noticeStr(lastPanel(A) and lastPanel(A).notice)
    return out
end

-- ===========================================================================
-- In doubt: pending, never lost; one action at a time; confirmed when the store settles
-- ===========================================================================

-- The coordinator commits but its answer is lost (export_timeout), and status keeps saying
-- in_doubt while `ctl.hold` is true: the facade answers in_doubt after its 20 s deadline and
-- keeps settling in the background.
local function loseAnswers()
    local resx = H.resources.open77_transactions
    local realTransfer, realStatus = resx.transfer, resx.status
    local ctl = { hold = true }
    resx.transfer = { cps = function(done, spec)
        realTransfer.cps(function() end, spec)
        done(nil, "export_timeout")
    end }
    resx.status = { cps = function(done, opId, opts)
        if ctl.hold then return done({ state = "in_doubt" }) end
        realStatus.cps(done, opId, opts)
    end }
    return ctl
end

function scenarios.panel_in_doubt()
    local out = {}
    local ex = bootTx()
    ex.add(A, "scrap", 4)
    H.run(2)
    H.task(function() ex.openStash(A, "home:b7d", 50) end)
    H.run(2)
    local ctl = loseAnswers()
    local seq0 = lastPanel(A).seq
    H.client = {}
    local box = intent(A, { action = "store", item = "scrap", count = 2, seq = seq0 })
    H.run(1)
    -- (1) a second click while the first is unsettled is refused, and the state it carries shows
    -- the two units in transit, not gone.
    intent(A, { action = "take", item = "scrap", count = 1 })
    H.run(1)
    local during = lastPanel(A)
    out.second_click = noticeStr(during and during.notice)
    local s = entry(during, "pockets", "scrap")
    out.during_pockets = s and (tostring(s.count) .. "+" .. tostring(s.held) .. " in transit") or "none"
    out.during_stash = tostring(entry(during, "stash", "scrap") and entry(during, "stash", "scrap").count or 0)
    out.during_incoming = tostring(during and during.stash and during.stash.sync and during.stash.sync.incomingKg)
    -- (2) the answer after the facade's settle deadline (20 s, checked between backoff steps,
    -- so about 30 s here): pending, with the operation listed.
    H.run(35)
    out.intent_done = tostring(box.done)
    local pend = noticeWhere(A, function(n) return n.reason == "in_doubt" end)
    out.pending_notice = noticeStr(pend)
    local st = lastPanel(A)
    local p1 = st and st.pending and st.pending[1]
    out.pending_list = p1 and (p1.action .. ":" .. p1.item .. "x" .. p1.count) or "none"
    out.pending_has_op = tostring(p1 ~= nil and type(p1.opId) == "string")
    -- (3) the store answers again: the operation is confirmed, the units land, the list empties.
    ctl.hold = false
    H.run(40)
    local final = lastPanel(A)
    local confirmed = noticeWhere(A, function(n) return n.kind == "ok" and n.text:find("^Confirmed") ~= nil end)
    out.confirmed = confirmed and confirmed.text or "none"
    out.final_pending = tostring(final and final.pending)
    local fp = entry(final, "pockets", "scrap")
    out.final_pockets = fp and (tostring(fp.count) .. "+" .. tostring(fp.held or 0)) or "none"
    out.final_stash = tostring(entry(final, "stash", "scrap") and entry(final, "stash", "scrap").count or 0)
    out.store_counts = TX.count(CHAR_A, "scrap") .. "/" .. TX.count("stash:home:b7d", "scrap")
    -- (4) closed while pending: the answer reaches the chat instead.
    ctl.hold = true
    intent(A, { action = "store", item = "scrap", count = 1, seq = final.seq })
    H.run(35)
    out.second_pending = tostring(lastPanel(A).pending and #lastPanel(A).pending or 0)
    intent(A, { action = "close" })
    H.run(1)
    ctl.hold = false
    H.run(40)
    out.closed_confirmation = chatTo(A, "Confirmed")
    out.closed_counts = TX.count(CHAR_A, "scrap") .. "/" .. TX.count("stash:home:b7d", "scrap")
    return out
end

-- ===========================================================================
-- The read-only cargo view: authorized by rp_garage, listed by rp_cargo, private, closes on
-- revocation and distance
-- ===========================================================================
function scenarios.cargo_view()
    local out = {}
    local access = { [A] = true }
    local near = { [A] = { { id = 501, distance = 2.0 } }, [B] = { { id = 501, distance = 2.5 } } }
    local contentsCalls = {}
    Open77.vehicles = {
        getPlayerSeat = function() return nil end,
        nearby = function(playerId) return near[playerId] or {} end,
    }
    H.resources.rp_garage = {
        plateOf = function(id) return id == 501 and "B7TRUCK" or nil end,
        canAccessVehicle = function(playerId, vehicleId, part, action)
            if vehicleId ~= 501 or part ~= "cargo" or action ~= "view" then return false, "invalid_action" end
            if access[playerId] then return true, "owner" end
            return false, "no_access"
        end,
    }
    H.resources.rp_cargo = {
        contents = function(playerId, vehicleId)
            contentsCalls[#contentsCalls + 1] = playerId
            if not access[playerId] then return nil, "no_access" end
            return { plate = "B7TRUCK", account = "veh:B7TRUCK:cargo", record = "Vehicle.v_standard3_thorton_mackinaw_player",
                capacityKg = 300, objects = 1, free = 7,
                slots = { { slot = "bed_1", maxStack = 2, objects = { { instance = "crate-0001", item = "scrap", rank = 1 } } },
                          { slot = "bed_2", maxStack = 2, objects = {} } } }
        end,
    }
    bootTx()
    openInv(A)
    openInv(B)
    H.run(1)
    H.client = {}
    intent(A, { action = "cargo" })
    intent(B, { action = "cargo" })
    H.run(1)
    local sa, sb = lastPanel(A), lastPanel(B)
    out.a_cargo = sa and sa.cargo and (sa.cargo.plate .. ":" .. sa.cargo.objects .. "/" .. sa.cargo.free) or "none"
    out.a_object = sa and sa.cargo and sa.cargo.slots[1].objects[1].label or "none"
    out.a_read_only = tostring(sa and sa.cargo and sa.cargo.readOnly)
    out.b_cargo = tostring(sb and sb.cargo)
    out.b_notice = noticeStr(sb and sb.notice)
    out.contents_asked_for = table.concat((function()
        local t = {} for _, p in ipairs(contentsCalls) do t[#t + 1] = tostring(p) end return t end)(), ",")
    out.targets = panelTargets()
    -- A commit on the cargo account (rp_cargo loading, another writer) re-reads the view.
    local before = #contentsCalls
    TriggerEvent("open77_transactions:committed", "cargo-op-01", "cargo.load", { "veh:B7TRUCK:cargo" })
    H.run(1)
    out.reread_on_commit = tostring(#contentsCalls - before)
    -- Keys revoked while the view is open: the next read is refused and the view closes.
    access[A] = false
    TriggerEvent("rp_garage:changed", "acct-a", "B7TRUCK", "keys_revoked")
    H.run(1)
    local sr = lastPanel(A)
    out.after_revoke = tostring(sr and sr.cargo)
    out.after_revoke_notice = noticeStr(sr and sr.notice)
    -- Access back, view reopened, then A walks away: the reach watch closes it.
    access[A] = true
    intent(A, { action = "cargo" })
    H.run(1)
    out.reopened = tostring(lastPanel(A).cargo ~= nil)
    near[A] = {}
    H.run(2)
    local sw = lastPanel(A)
    out.after_walk = tostring(sw and sw.cargo)
    out.after_walk_notice = noticeStr(sw and sw.notice)
    -- Garage registry not running: refused as a retry, never shown.
    near[A] = { { id = 501, distance = 2.0 } }
    H.resources.rp_garage = nil
    intent(A, { action = "cargo" })
    H.run(1)
    out.no_garage = noticeStr(lastPanel(A).notice)
    return out
end

-- ===========================================================================
-- Exits: death, a menu holding the keyboard, walking away from a stash, a stale page
-- ===========================================================================
function scenarios.panel_exits()
    local out = {}
    local ex = bootTx()
    openInv(A)
    H.run(1)
    H.client = {}
    TriggerEvent("onPlayerLifeStateChanged", A, 12, "dead")
    H.run(1)
    local closes = 0
    for _, st in ipairs(panelsOf(A)) do if st.open == false then closes = closes + 1 end end
    out.death_closes = tostring(closes)
    H.client = {}
    intent(A, { action = "refresh" })
    H.run(1)
    out.after_death_refresh = tostring(lastPanel(A) and lastPanel(A).open)   -- the stale page is put away
    -- The client refused to open over a menu holding the keyboard.
    openInv(A)
    H.run(1)
    intent(A, { action = "blocked", reason = "panel_blocked" })
    H.run(1)
    out.blocked_chat = chatTo(A, "Another menu")
    H.client = {}
    intent(A, { action = "refresh" })
    H.run(1)
    out.after_blocked = tostring(lastPanel(A) and lastPanel(A).open)
    -- A stash panel closes its stash column when the player walks away.
    H.task(function() ex.openStash(A, "home:b7r", 50) end)
    H.run(2)
    out.stash_before = tostring(lastPanel(A).stash and lastPanel(A).stash.id)
    H.players[A].pos = { x = 12, y = 0, z = 0, bucket = 0 }
    H.run(2)
    local sw = lastPanel(A)
    out.stash_after_walk = tostring(sw.stash)
    out.stash_after_walk_notice = noticeStr(sw.notice)
    H.client = {}
    intent(A, { action = "store", item = "scrap", count = 1 })
    H.run(1)
    out.store_after_walk = lastPanel(A).notice and lastPanel(A).notice.text or "none"
    return out
end

-- ===========================================================================
-- rp_hud: B3 wallet (balances, pending, unknown != 0) and B4 job summary, pushed privately
-- ===========================================================================
local function bootHud(providers)
    H.client = {}
    for name, p in pairs(providers) do H.remote[name] = p end
    H.boot("rp_hud", { REPO .. "/rp_hud/shared/config.lua", REPO .. "/rp_hud/server/main.lua" }, "none", {
        [1] = { identifier = "acct-1", name = "Vince" },
        [2] = { identifier = "acct-2", name = "Judy" },
    }, 7)   -- past the join re-push (joinRepushMs = 6 s), before the 30 s keepalive
end
local function hudOf(target)
    local last
    for _, e in ipairs(H.client) do
        if e.name == "rp_hud:state" and e.target == target then last = e.args[1] end
    end
    return last
end
local function hudPushes(target)
    local n = 0
    for _, e in ipairs(H.client) do if e.name == "rp_hud:state" and e.target == target then n = n + 1 end end
    return n
end

function scenarios.hud_wallet_and_job()
    local out = {}
    local pendingMap = {}
    local status = {
        [1] = { loaded = true, cash = { balance = 1200, incoming = 300, outgoing = 0, unconfirmed = 0, inDoubt = 1, ops = 1 },
                bank = { balance = 5000, incoming = 0, outgoing = 0, unconfirmed = 0, inDoubt = 0, ops = 0 } },
        [2] = { loaded = false, reason = "store_unavailable" },
    }
    local summaries = {
        [1] = { job = "ncpd", label = "NCPD", grade = 2, gradeLabel = "senior", onDuty = true },
    }
    bootHud({
        rp_economy = {
            walletStatus = function(playerId) return status[playerId] end,
            pendingPlayers = function() return pendingMap end,
            getBalance = function() return 0 end,
        },
        rp_jobs = {
            summary = function(playerId)
                if summaries[playerId] then return summaries[playerId] end
                return nil, "store_unavailable"
            end,
        },
    })
    local s1, s2 = hudOf(1), hudOf(2)
    out.p1_cash = tostring(s1 and s1.cash)
    out.p1_account = tostring(s1 and s1.account)
    local w = s1 and s1.wallet
    out.p1_wallet = w and (tostring(w.state) .. " incoming=" .. tostring(w.cash and w.cash.incoming)
        .. " inDoubt=" .. tostring(w.cash and w.cash.inDoubt) .. " bank=" .. tostring(w.account)) or "none"
    out.p1_job = s1 and s1.job and (s1.job.label .. " " .. tostring(s1.job.grade) .. " " .. tostring(s1.job.gradeLabel)
        .. " duty=" .. tostring(s1.job.onDuty)) or "none"
    out.p1_job_state = tostring(s1 and s1.jobState)
    out.p2_cash = tostring(s2 and s2.cash)             -- unknown, never 0
    out.p2_wallet = tostring(s2 and s2.wallet and s2.wallet.state)
    out.p2_job = tostring(s2 and s2.job)
    out.p2_job_state = tostring(s2 and s2.jobState)
    -- Pending watch: an operation appears for player 1, then settles; player 2 is not pushed.
    local p1Before, p2Before = hudPushes(1), hudPushes(2)
    pendingMap = { [1] = "cash:300:0:0:1" }
    H.run(2.5)
    out.pushed_on_pending = tostring(hudPushes(1) - p1Before)
    pendingMap = {}
    status[1].cash.incoming, status[1].cash.inDoubt, status[1].cash.ops, status[1].cash.balance = 0, 0, 0, 1500
    H.run(2.5)
    out.pushed_on_settle = tostring(hudPushes(1) - p1Before)   -- cumulative: appeared + settled
    out.p1_cash_after = tostring(hudOf(1).cash) .. " pending=" .. tostring(hudOf(1).wallet.cash)
    out.p2_untouched = tostring(hudPushes(2) - p2Before)
    -- B3/B4 events refresh only the player they name.
    local before = hudPushes(2)
    TriggerEvent("rp_jobs:workEpoch", 2, 77, "duty_on")
    TriggerEvent("rp_economy:walletChanged", "soc", nil, "ncpd", 10, 10, "x")   -- a society: nobody
    H.run(1)
    out.epoch_push = tostring(hudPushes(2) - before)
    -- A coordinator health transition redraws every connected panel at once (not on the keepalive).
    local h1, h2 = hudPushes(1), hudPushes(2)
    TriggerEvent("rp_economy:healthChanged", false, "store_unavailable")
    H.run(1)
    out.health_push = tostring(hudPushes(1) - h1) .. "," .. tostring(hudPushes(2) - h2)
    local targets = {}
    for _, e in ipairs(H.client) do
        if e.name == "rp_hud:state" then targets[tostring(e.target)] = true end
    end
    out.broadcast = tostring(targets["-1"] == true)
    return out
end

function scenarios.hud_fallback()
    local out = {}
    bootHud({
        rp_economy = { getBalance = function() return 250 end },
        rp_bank = { getAccount = function() return { balance = 900 } end },
        rp_jobs = {
            getJob = function() return "mecano" end,
            getGrade = function() return { level = 1, label = "employee" } end,
            onDuty = function() return false end,
        },
    })
    local s = hudOf(1)
    out.cash = tostring(s and s.cash)
    out.account = tostring(s and s.account)
    out.wallet = tostring(s and s.wallet)
    out.job = s and s.job and (s.job.label .. " " .. tostring(s.job.grade) .. " duty=" .. tostring(s.job.onDuty)) or "none"
    return out
end

function RUN_SCENARIO(name)
    local scenario = assert(scenarios[name], "unknown scenario " .. tostring(name))
    local out = scenario()
    local lines = {}
    for k, v in pairs(out) do lines[#lines + 1] = k .. "=" .. tostring(v):gsub("\n", " ") end
    table.sort(lines)
    return table.concat(lines, "\n")
end
