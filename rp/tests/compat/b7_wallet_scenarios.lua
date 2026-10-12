-- tests/compat/b7_wallet_scenarios.lua: rp_economy's read-only HUD exports (row B7), offline.
--
-- Loaded by tests/test_b7_ui.py after fakehost.lua (unused here) with ROOT_DIR, COMPAT_DIR and
-- TX_DIR. Boots the B3 world (multihost.lua + wallet_world.lua: the coordinator prototype behind
-- txhost_wallet.lua and the REAL rp_economy server scripts) and reads walletStatus /
-- pendingPlayers while an operation is held in flight (HOST.shared.txPaused), then settled.

dofile(COMPAT_DIR .. "/multihost.lua")
dofile(COMPAT_DIR .. "/wallet_world.lua")

local scenarios = {}
local A = "acct-a"

local function status(id, minAge)
    local s, why = WW.sync("rp_hud", "rp_economy", "walletStatus", id, { minAgeSeconds = minAge or 0 })
    if type(s) ~= "table" then return "nil:" .. tostring(why) end
    if not s.loaded then return "unloaded:" .. tostring(s.reason) end
    local c, b = s.cash, s.bank
    return ("cash=%d in=%d out=%d unc=%d doubt=%d ops=%d bank=%d%s"):format(c.balance, c.incoming, c.outgoing,
        c.unconfirmed, c.inDoubt, c.ops, b.balance, s.reason and (" " .. s.reason) or "")
end

local function pendingStr(minAge)
    local map = WW.sync("rp_hud", "rp_economy", "pendingPlayers", { minAgeSeconds = minAge or 0 })
    if type(map) ~= "table" then return "nil" end
    local keys = {}
    for id, fp in pairs(map) do keys[#keys + 1] = tostring(id) .. "=" .. fp end
    table.sort(keys)
    return #keys > 0 and table.concat(keys, ";") or "none"
end

function scenarios.wallet_status_pending()
    WW.boot({ shims = { WW.shim("rp_nomade"), WW.shim("rp_jobs"), WW.shim("rp_hud") } })
    WW.join(7, A, "V")
    local out = {}
    out.joined = status(7)
    out.unknown_player = status(99)
    out.invalid_id = status("x")
    out.pending_idle = pendingStr()

    -- An atomic credit held in flight: NOT in the balance yet, shown as incoming.
    MH.shared.txPaused = true
    local box = {}
    local env = MH.resources.rp_nomade.env
    MH.task("rp_nomade", function()
        local p = env.Open77.exports.call("rp_economy", "pay", {
            opId = "nomade:pay:b7-contract:1", from = { sys = "client" }, to = { player = 7 }, amount = 300,
            reason = "nomade:delivery",
        })
        box.r, box.why = p:await()
        box.done = true
    end)
    MH.run(1)
    out.in_flight_young = status(7, 1.5)     -- younger than the display threshold: not shown
    MH.run(2)
    out.in_flight = status(7, 1.5)
    -- A write-behind debit while paused: already subtracted, unconfirmed.
    local removed, removeWhy = WW.sync("rp_jobs", "rp_economy", "remove", 7, 100, "fine")
    out.remove = tostring(removed) .. "/" .. tostring(removeWhy)
    MH.run(2)
    out.with_debit = status(7, 1.5)
    -- The caller is told in_doubt after asyncWaitSeconds (20 s): the status says so.
    MH.run(20)
    out.caller = tostring(box.done) .. ":" .. tostring(box.r and "receipt" or box.why)
    out.in_doubt = status(7, 1.5)
    out.pending_players = pendingStr(1.5)
    -- The store answers again: everything settles, nothing stays pending.
    MH.shared.txPaused = false
    WW.settle(60)
    out.settled = status(7, 1.5)
    out.pending_after = pendingStr(1.5)
    out.durable = tostring(WW.balance("cash:" .. A))
    return WW.result(out)
end

function RUN_SCENARIO(name)
    local scenario = assert(scenarios[name], "unknown scenario " .. tostring(name))
    return scenario()
end
