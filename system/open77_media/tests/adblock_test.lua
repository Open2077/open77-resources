-- =============================================================================
-- open77_media -- tests/adblock_test.lua
-- =============================================================================
-- Pins the operator's ad-blocklist policy: the rule grammar, the refusals, the
-- payload, and the store format.
--
-- Why this is a suite and not a handful of assertions: every failure mode here is
-- silent from the server's chair. A rule accepted that should have been refused
-- (`com`, `co.uk`) takes a client's whole browser down and reads from the console
-- as a typo that worked. A rule silently DROPPED looks exactly like a network
-- that kept serving advertising. A payload that carried something other than the
-- rules is a client validating strings the server never meant to send. None of
-- the three throws, and none of them leaves a line anywhere -- so they are pinned
-- here, where the grammar lives, rather than discovered in a session.
--
-- What this suite deliberately does NOT pin: the client's half of the same
-- grammar. The browser host validates every incoming rule again (a client cannot
-- trust a list that arrived over a network), the two implementations are
-- separate on purpose, and the receipt is what catches a disagreement --
-- `server/main.lua` logs it and `media.adblock.status` shows it per player.
--
-- Standalone:  lua tools/lua-test/run.lua <repo-root>
-- =============================================================================

local passed = 0
local failures = {}
local function check(condition, message)
    if condition then
        passed = passed + 1
    else
        failures[#failures + 1] = message or "assertion failed"
    end
end

local AdBlock = MediaAdBlock
check(type(AdBlock) == "table", "the ad blocklist module is published")
if type(AdBlock) ~= "table" then
    TestResult = { passed = passed, failed = #failures, failures = failures }
    return
end

-- =============================================================================
-- The host grammar
-- =============================================================================

-- What an operator is allowed to have meant. Every one of these is a shape a
-- person actually pastes, and every one has to come out as the same kind of rule.
local acceptedHosts = {
    { "example.com", "example.com" },
    { "Ads.Example.COM", "ads.example.com" },
    { "https://tracker.bad.test/pixel.gif?x=1", "tracker.bad.test" },
    { "https://tracker.bad.test:8443/pixel.gif", "tracker.bad.test" },
    { "*.popads.example", "popads.example" },
    { ".example.test/", "example.test" },
    { "  spam.example.test.  ", "spam.example.test" },
    { "10.0.0.7", "10.0.0.7" },
}
for _, case in ipairs(acceptedHosts) do
    local rule, reason = AdBlock.checkHost(case[1])
    check(rule == case[2], string.format("%q must normalise to %q (got %s / %s)",
        case[1], case[2], tostring(rule), tostring(reason)))
end

-- And what it refuses, each with the reason the operator is shown. The reason is
-- the useful half: "refused" alone leaves somebody re-pasting the same entry.
local refusedHosts = {
    { "", "empty" },
    { "   ", "empty" },
    { "com", "needs_a_domain" },
    { "co.uk", "registry_suffix" },
    { "ads example.com", "invalid_character" },
    { "ads.*.example.com", "invalid_character" },
    { "a..b.com", "empty_label" },
    { "-lead.example.com", "invalid_hyphen" },
    { "trail-.example.com", "invalid_hyphen" },
    { "https://", "unreadable_url" },
}
for _, case in ipairs(refusedHosts) do
    local rule, reason = AdBlock.checkHost(case[1])
    check(rule == nil, string.format("%q must be refused", case[1]))
    check(reason == case[2], string.format("%q must be refused with %q (got %q)",
        case[1], case[2], tostring(reason)))
end
check(AdBlock.checkHost(nil) == nil, "a non-string is refused rather than coerced")

-- =============================================================================
-- The token grammar
-- =============================================================================
-- A token matches ANYWHERE inside a host, which is what makes it worth having
-- (a campaign rotates domains faster than a list can be written) and what makes
-- its refusals different from a host rule's.

check(AdBlock.checkToken("PopAds") == "popads", "a token is lowercased")
check(AdBlock.checkToken("newads-7") == "newads-7", "an inner hyphen is fine")

local refusedTokens = {
    { "com", "registry_label" },
    { "www", "registry_label" },
    { "ab", "token_too_short" },
    { "ads.example", "token_is_a_host" },
    { "my token", "invalid_character" },
    { "-lead", "invalid_character" },
    { "", "empty" },
}
for _, case in ipairs(refusedTokens) do
    local token, reason = AdBlock.checkToken(case[1])
    check(token == nil, string.format("token %q must be refused", case[1]))
    check(reason == case[2], string.format("token %q must be refused with %q (got %q)",
        case[1], case[2], tostring(reason)))
end

-- `com` as a token is refused for being a registry, not for being three
-- characters long: the two are both refusals, and only one says why the entry
-- could never work at any length.
check(select(2, AdBlock.checkToken("com")) == "registry_label",
    "a registry label is refused for the reason that matters, not for its length")

-- =============================================================================
-- Adding and removing
-- =============================================================================

local hosts, tokens = {}, {}
check(AdBlock.add(hosts, tokens, "newads.test", "host") == "newads.test", "a host adds")
check(AdBlock.add(hosts, tokens, "newads.test", "host") == "newads.test",
    "adding it twice is the same rule, not a second one")
check(#hosts == 1, "so the list holds it once")
check(AdBlock.add(hosts, tokens, "cdn.newads.test", "host") == "cdn.newads.test",
    "a subdomain is its own rule (rules are not collapsed)")
check(AdBlock.add(hosts, tokens, "newads", "token") == "newads", "a token adds")
check(#tokens == 1, "and lands in the token list, not the host list")

local refusedRule, refusedReason = AdBlock.add(hosts, tokens, "co.uk", "host")
check(refusedRule == nil and refusedReason == "registry_suffix",
    "a refused add reports the grammar's reason and changes nothing")
check(#hosts == 2, "and leaves the list exactly as it was")

check(AdBlock.remove(hosts, tokens, "NEWADS.test") == true,
    "removal normalises the same way acceptance does")
check(#hosts == 1, "the rule is gone")
check(AdBlock.remove(hosts, tokens, "newads") == true, "a token removes by either kind")
check(#tokens == 0, "and is gone from its own list")
check(AdBlock.remove(hosts, tokens, "never.was") == false, "removing what is absent says so")

-- The wire bound. A list this size is already far past hand-maintained, and a
-- server that can push a thousand rules to every client at once is a server that
-- can make joining expensive.
local manyTokens = {}
for index = 1, AdBlock.MAX_TOKENS do
    check(AdBlock.add({}, manyTokens, "token" .. tostring(index), "token") ~= nil,
        "token " .. tostring(index) .. " fits under the bound")
end
check(AdBlock.add({}, manyTokens, "tokenoverflow", "token") == nil,
    "the bound refuses one more")
check(#manyTokens == AdBlock.MAX_TOKENS, "and the list is exactly at the bound")

-- The host bound is its own list: filling the tokens must not have touched it.
local manyHosts = {}
for index = 1, AdBlock.MAX_HOSTS do
    manyHosts[#manyHosts + 1] = "host" .. tostring(index) .. ".test"
end
local kept = 0
for _, rule in ipairs(manyHosts) do
    if AdBlock.checkHost(rule) ~= nil then kept = kept + 1 end
end
check(kept == AdBlock.MAX_HOSTS, "every generated host rule is valid")

-- =============================================================================
-- The payload
-- =============================================================================

local policy = AdBlock.policy({ "NewAds.test", "co.uk", "https://x.test/a" },
                              { "newads", "com" }, 7, "open77_media@127.0.0.1")
check(policy.revision == 7, "the revision travels with the rules")
check(policy.source == "open77_media@127.0.0.1", "so does where they came from")
check(#policy.hosts == 2, "only the rules that pass the grammar are sent")
check(policy.hosts[1] == "newads.test" and policy.hosts[2] == "x.test",
    "normalised on the way out, not just on the way in")
check(#policy.tokens == 1 and policy.tokens[1] == "newads", "and likewise for tokens")
check(#policy.refused == 2, "what was not sent is named rather than dropped")
check(policy.refused[1] == "co.uk:registry_suffix" and policy.refused[2] == "com:registry_label",
    "each refusal carries the rule and the reason")

local empty = AdBlock.policy(nil, nil, nil, nil)
check(type(empty.hosts) == "table" and #empty.hosts == 0, "a nil list is an empty list")
check(empty.revision == 0 and empty.source == "", "and its numbering starts at zero")

check(AdBlock.describe({ "a.test" }, { "b" }) == "1 host(s) + 1 token(s)",
    "the console line counts both kinds")

-- =============================================================================
-- The store
-- =============================================================================
-- What is written to `data/adblock.json` and read back. The round trip matters
-- because the file is what survives a restart; the tolerance matters because a
-- hand-edited file is a normal thing to find and refusing to load it would trade
-- a wrong list for a broken server.

local stored = AdBlock.store({ "newads.test" }, { "newads" }, 4)
check(stored.schemaVersion == 1, "the store is versioned")
local hostsBack, tokensBack, revisionBack = AdBlock.loadStore(stored)
check(#hostsBack == 1 and hostsBack[1] == "newads.test", "hosts survive the round trip")
check(#tokensBack == 1 and tokensBack[1] == "newads", "tokens survive the round trip")
check(revisionBack == 4, "so does the revision, so a receipt stays meaningful across it")

local junkHosts, junkTokens, junkRevision = AdBlock.loadStore({
    hosts = { "co.uk", "good.test", 42 },
    tokens = { "com", "newads" },
    revision = "nonsense",
})
check(#junkHosts == 1 and junkHosts[1] == "good.test",
    "a hand-edited file's invalid entries are dropped, not loaded")
check(#junkTokens == 1 and junkTokens[1] == "newads", "and likewise for tokens")
check(junkRevision == 0, "a revision that is not a number reads as zero")

local noneHosts, noneTokens = AdBlock.loadStore(nil)
check(#noneHosts == 0 and #noneTokens == 0, "a missing store is an empty list, not an error")

-- =============================================================================
-- The config
-- =============================================================================
-- `server/config.lua` is a seed, and a seed with a typo has to be reported at
-- boot rather than at the first client. One bad entry degrades one entry.

local config, problems = AdBlock.buildConfig({
    enabled = true,
    dataFile = "adblock.json",
    hosts = { "good.test", "co.uk", "also.good.test" },
    tokens = { "newads", "com" },
})
check(config.enabled == true, "the flag survives")
check(#config.hosts == 2, "the seed keeps its valid rules")
check(#config.tokens == 1, "and its valid tokens")
check(#problems == 2, "and every dropped entry is reported")
check(problems[1]:find("co.uk", 1, true) ~= nil, "with the entry that was wrong in it")
check(problems[2]:find("com", 1, true) ~= nil, "for both lists")

local defaults, defaultProblems = AdBlock.buildConfig({
    enabled = "yes",
    dataFile = "../../elsewhere.json",
    hosts = "not a table",
})
check(defaults.enabled == AdBlock.DEFAULT_CONFIG.enabled, "a non-boolean flag falls back")
check(defaults.dataFile == AdBlock.DEFAULT_CONFIG.dataFile,
    "a data file with a path in it is refused: the store is confined to data/")
check(type(defaults.hosts) == "table", "a non-table list falls back to empty")
check(#defaultProblems == 3, "three problems, three lines")

-- =============================================================================
-- The command grammar
-- =============================================================================

local spec, specError = AdBlock.parseAddArgs({ n = 1, [1] = "ads.test" })
check(spec ~= nil and spec.kind == "host" and spec.rule == "ads.test",
    "one argument is a host rule")
spec = AdBlock.parseAddArgs({ n = 2, [1] = "token", [2] = "newads" })
check(spec ~= nil and spec.kind == "token" and spec.rule == "newads",
    "`token <rule>` is a token rule")
spec, specError = AdBlock.parseAddArgs({ n = 2, [1] = "nonsense", [2] = "x" })
check(spec == nil and specError ~= nil, "an unknown kind is refused with a usage line")
spec, specError = AdBlock.parseAddArgs({ n = 0 })
check(spec == nil, "no arguments is refused")

TestResult = {
    passed = passed,
    failed = #failures,
    failures = failures,
}
