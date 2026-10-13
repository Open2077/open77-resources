-- =============================================================================
-- open77_actions -- tests/claims_test.lua
-- =============================================================================
-- The claims service on its own: bucket scoping, one winner, expiry, renewal,
-- release by token / holder / owner. Load order: shared/model.lua,
-- server/claims.lua, this file.
-- =============================================================================

local Claims = Open77ActionsClaims
assert(Claims ~= nil, "server/claims.lua did not load")

local passed, failures = 0, {}
local function check(cond, msg)
    if cond then passed = passed + 1 else failures[#failures + 1] = msg or "assertion failed" end
end
local function run(name, fn)
    local ok, err = pcall(fn)
    if not ok then failures[#failures + 1] = name .. ": runtime error: " .. tostring(err) end
end

local clock = 1000
local function fresh() clock = 1000; return Claims.new({ now = function() return clock end }) end

run("one winner per bucket and key", function()
    local c = fresh()
    local a = c:acquire(0, "target:node1", "opA", 5000, "job")
    check(a ~= nil, "first claim wins")
    local b, why, holder = c:acquire(0, "target:node1", "opB", 5000, "job")
    check(b == nil and why == "target_claimed", "second claimant refused with target_claimed")
    check(holder ~= nil and holder.holder == "opA", "refusal names the holder")
    local other = c:acquire(1, "target:node1", "opB", 5000, "job")
    check(other ~= nil, "the same key in another bucket is another claim")
    check(c:count() == 2, "two live claims")
end)

run("re-acquire by the same holder renews, never duplicates", function()
    local c = fresh()
    local a = c:acquire(0, "k", "opA", 1000)
    clock = clock + 900
    local again = c:acquire(0, "k", "opA", 1000)
    check(again == a, "same token returned")
    clock = clock + 900
    check(c:holder(0, "k") ~= nil, "renewed claim still held after the original deadline")
    check(c:count() == 1, "still one claim")
end)

run("expiry frees the key and the sweep reports it", function()
    local c = fresh()
    c:acquire(0, "k", "opA", 1000)
    clock = clock + 1001
    local lapsed = c:sweep()
    check(#lapsed == 1 and lapsed[1].holder == "opA", "sweep reports the lapsed claim")
    check(c:acquire(0, "k", "opB", 1000) ~= nil, "a lapsed key can be claimed again")
    clock = clock + 2000
    check(c:holder(0, "k") == nil, "holder() drops an expired claim on read")
end)

run("renew and release by token", function()
    local c = fresh()
    local t = c:acquire(0, "k", "opA", 1000)
    check(c:renew(t, 5000) == true, "renew a live token")
    clock = clock + 3000
    check(c:get(t) ~= nil, "renewed token alive")
    check(c:release(t) == true, "release by token")
    check(c:release(t) == false, "double release is a no-op")
    local _, why = c:renew(t, 1000)
    check(why == "claim_lost", "renewing a released token answers claim_lost")
end)

run("release by holder and by owner", function()
    local c = fresh()
    c:acquire(0, "a", "opA", 1000, "job")
    c:acquire(0, "b", "opA", 1000, "job")
    c:acquire(0, "c", "opB", 1000, "other")
    check(c:releaseHolder("opA") == 2, "releaseHolder drops every claim of an operation")
    check(c:releaseOwner("other") == 1, "releaseOwner drops a resource's claims")
    check(c:count() == 0, "nothing left")
end)

run("invalid keys and holders are refused", function()
    local c = fresh()
    local _, why = c:acquire(0, "", "opA", 1000)
    check(why == "invalid_target", "empty key refused")
    _, why = c:acquire(0, "k", nil, 1000)
    check(why == "invalid_target", "missing holder refused")
end)

TestResult = { passed = passed, failed = #failures, failures = failures }
