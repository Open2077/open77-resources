-- =============================================================================
-- open77_media -- tests/client_test.lua
-- =============================================================================
-- The catalogue suite (`records_test.lua`) pins what a record says. This one
-- pins what the client DOES with a set the server has already accepted, and it
-- exists because the failure that cost this feature its screen lived exactly
-- here and nowhere else.
--
-- A spawned television used to draw nothing at all. The server reported
-- `OK television 1 created`, the prop was in the world with the right mesh, the
-- catalogue was right -- and the client's one-second selection thread threw on
-- its first line:
--
--     open77_media/client/main.lua:63: attempt to index a number value
--     (local 'character')
--
-- `Open77.character.position()` returns three numbers (the native pushes x, y, z
-- as three returns -- `scripting/src/ResourceHost.cpp`, `LuaCharacterPosition`),
-- and the client bound the first of them to a name and indexed `.x` on it. Every
-- screen failed, once a second, silently from both other ends.
--
-- So the client half is loaded here against a stub whose `character.position`
-- returns the native's REAL shape -- three values, not a table -- and the suite
-- asserts the outcome a player cares about: a set in range gets a page, the page
-- is bound to that set's prop, and the surface is the rectangle's own aspect.
-- A stub that returned a tidy `{x=,y=,z=}` table would have passed while the
-- game failed, which is the whole reason this is written the way it is.
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

-- =============================================================================
-- The stub surface
-- -----------------------------------------------------------------------------
-- Only what `client/main.lua` touches. Everything is recorded rather than
-- simulated, because what this suite checks is the conversation between the
-- resource and the native: which page was created, which prop it was bound to,
-- at what size.
-- =============================================================================

local handlers = {}       -- [event name] = function
local lastBindId = nil    -- the id the stub handed out, so `list` can name it
local threads = {}        -- bodies handed to CreateThread
local pages = {}          -- every page WebUI.create returned
local binds = {}          -- every Open77.media.bind call
local unbinds = 0
local clears = 0

local function NewPage(options)
    local page = {
        options = options,
        sent = {},
        destroyed = false,
        events = {},
    }
    function page:send(name, payload) self.sent[#self.sent + 1] = { name, payload } end
    function page:on(name, handler) self.events[name] = handler end
    function page:destroy() self.destroyed = true end
    function page:setFocus() end
    pages[#pages + 1] = page
    return page
end

---The native's own acceptance rule for the page's network privileges, restated
---the same way the vector rule is below: `ReadWebPolicy` in
---`scripting/src/ResourceHost.cpp` knows exactly two names and raises on anything
---else, and the literal directives behind each live on the client
---(`WebUI::PagePolicy`). A stub that accepted any string would pass while the
---game refused the surface, which is the failure mode this file already exists to
---catch once.
local knownPolicies = { strict = true, media = true }

_G.WebUI = {
    create = function(options)
        -- `WebUI.create` answers `page, reason`, which is how the client tells a
        -- refused surface from a created one.
        local policy = options.policy
        if policy ~= nil and not knownPolicies[policy] then
            return nil, "invalid_webui_policy"
        end
        return NewPage(options), nil
    end,
}

---The native's own acceptance rule, restated: `ReadVector3` in
---`scripting/src/ResourceHost.cpp` reads x/y/z BY NAME and refuses anything else
---with `invalid_offset` / `invalid_right` / `invalid_up`. A stub that accepted any
---table would have passed while the game refused every screen -- which is exactly
---what happened: the catalogue's positional `offset = { 0, 0.1154, 0.42 }` went
---straight to the native, and every television logged
---`bind failed: invalid_offset` once a second forever.
local function namedVector(value)
    return type(value) == "table" and type(value.x) == "number"
        and type(value.y) == "number" and type(value.z) == "number"
end

_G.Open77 = {
    media = {
        bind = function(spec)
            binds[#binds + 1] = spec
            local quad = spec.quad
            if type(quad) ~= "table" then return nil, "invalid_quad" end
            if not namedVector(quad.offset) then return nil, "invalid_offset" end
            if not namedVector(quad.right) then return nil, "invalid_right" end
            if not namedVector(quad.up) then return nil, "invalid_up" end
            if type(quad.width) ~= "number" or type(quad.height) ~= "number" then
                return nil, "invalid_width"
            end
            lastBindId = "screen-" .. tostring(#binds)
            return lastBindId, nil
        end,
        unbind = function() unbinds = unbinds + 1 end,
        clear = function() clears = clears + 1 end,
    },
    character = {
        -- The native's shape, deliberately: three numbers. See the header.
        position = function() return 100.0, 200.0, 10.0 end,
        state = function() return { yaw = 45.0 } end,
    },
    log = { info = function() end, warn = function() end },
}

_G.CreateThread = function(body) threads[#threads + 1] = body end
_G.AddEventHandler = function(name, handler) handlers[name] = handler end
_G.RegisterNetEvent = function(name, handler) handlers[name] = handler end
_G.RegisterCommand = function() end
_G.TriggerEvent = function() end
_G.TriggerServerEvent = function() end
_G.GetCurrentResourceName = function() return "open77_media" end
_G.GetResourceState = function() return "started" end
_G.Wait = function()
    -- One pass of the selection thread is all this suite needs, and the loop it
    -- sits in is `while true`. Bailing out here is what makes a single pass
    -- possible; the sentinel is caught by the caller below.
    error("selection_pass_done", 0)
end

-- =============================================================================
-- Load the client half
-- =============================================================================

-- The file under test, resolved from a root the CALLER names rather than from
-- the process's working directory. The standalone runner passes the repo root it
-- was given; the .NET harness passes its own. `director_test.lua` takes its path
-- the same way (`DIRECTOR_PATH`), so this is the convention the suites already
-- follow -- and it is what lets the same file be run by both callers.
local repoRoot = type(OPEN77_REPO_ROOT) == "string" and OPEN77_REPO_ROOT or "."
local clientPath = repoRoot .. "/resources/system/open77_media/client/main.lua"
local client = assert(loadfile(clientPath), clientPath .. " not found")
client()

check(type(handlers["onClientResourceStart"]) == "function",
    "the client registers a resource-start handler")
check(type(handlers["open77:media:snapshot"]) == "function",
    "the client registers the snapshot handler")

-- =============================================================================
-- A television the server has accepted
-- =============================================================================

local quad = {
    offset = { 0.0, 0.115394, 0.42 },
    right = { 1.0, 0.0, 0.0 },
    up = { 0.0, 0.0, 1.0 },
    width = 1.16,
    height = 0.66,
}

handlers["onClientResourceStart"]("open77_media")
-- Two threads, and both are deliberate: the selection thread (which screens
-- exist) and the blocklist receipt thread (whether the browser host took the
-- operator's rules). The second is cheap by construction -- it exists only
-- between a push and its answer -- but it is the one that turns "we sent it"
-- into "it is in force", so it is pinned here.
check(#threads == 2, "the client starts a selection thread and a receipt thread")
check(#pages == 0, "nothing is materialised before the server says there is a set")

-- Five metres east of the stubbed body (100, 200, 10): inside every radius the
-- resource defines, so a working distance read materialises it.
handlers["open77:media:snapshot"]({
    {
        id = 1,
        prop = "4242",
        record = "tv.16x9",
        label = "Reception",
        url = "https://example.invalid/x",
        volume = 75,
        muted = false,
        paused = false,
        quad = quad,
        position = { x = 105.0, y = 200.0, z = 10.0 },
    },
})

-- One pass of the thread body. `Wait` throws the sentinel above to end it.
local ok, reason = pcall(threads[1])
check(not ok and reason == "selection_pass_done",
    "the selection thread ran without error")
check(reason ~= nil and not string.find(tostring(reason), "index a number value"),
    "the selection thread did not read the body position as a table")

-- =============================================================================
-- The outcome: a page, on that set's prop, at that rectangle's shape
-- =============================================================================

check(#pages == 1, "a set in range materialises exactly one page")
check(#binds == 1, "the page is bound to the set")
check(binds[1] ~= nil and binds[1].prop == "4242",
    "the binding names the set's own prop id")
check(binds[1] ~= nil and binds[1].page == pages[1],
    "the binding names the page that was created for it")

-- The rectangle reaches the native in the shape it reads, from the positional
-- shape the catalogue and the server's `copyQuad` write.
local sentQuad = binds[1] ~= nil and binds[1].quad or nil
check(sentQuad ~= nil and sentQuad.offset.x == 0.0 and sentQuad.offset.y == 0.115394
    and sentQuad.offset.z == 0.42,
    "a positional offset arrives at the native as a named vector")
check(sentQuad ~= nil and sentQuad.right.x == 1.0 and sentQuad.right.y == 0.0
    and sentQuad.right.z == 0.0,
    "a positional right axis arrives as a named vector")
check(sentQuad ~= nil and sentQuad.up.z == 1.0 and sentQuad.up.x == 0.0,
    "a positional up axis arrives as a named vector")
check(sentQuad ~= nil and sentQuad.width == 1.16 and sentQuad.height == 0.66,
    "the rectangle's size survives the conversion")

local expectedWidth, expectedHeight = Open77MediaSurfaceFor(quad)
check(pages[1] ~= nil and pages[1].options.width == expectedWidth
    and pages[1].options.height == expectedHeight,
    "the surface is the rectangle's own aspect, not a fixed size")
check(pages[1] ~= nil and pages[1].options.entry == "web/tv.html",
    "the surface loads the television page")

-- And it asks to be allowed to play what it is told to play. Without this the
-- host serves the page the strict policy, which refuses YouTube's player script
-- and then its embed frame -- and the page cannot report either refusal, because
-- a page cannot read a header it was served under. The screen showed its own
-- idle colour bars and the log said only "the player script refused to load".
check(pages[1] ~= nil and pages[1].options.policy == "media",
    "the television page asks for the media policy, not the default one")

-- The page is told the set's state once it has announced itself, which is how
-- the first frame agrees with the server.
if pages[1] ~= nil and type(pages[1].events["media:ready"]) == "function" then
    pages[1].events["media:ready"]()
    check(#pages[1].sent == 1 and pages[1].sent[1][1] == "media:state",
        "the page is handed its state when it reports ready")
    check(pages[1].sent[1][2] ~= nil and pages[1].sent[1][2].url == "https://example.invalid/x",
        "the state carries the server's URL, not the page's")
else
    check(false, "the page registers a media:ready handler")
end

-- =============================================================================
-- A set that is withdrawn loses its page, and the local event says so
-- =============================================================================

handlers["open77:media:snapshot"]({})
check(pages[1] ~= nil and pages[1].destroyed, "a withdrawn set destroys its page")
check(unbinds == 1, "a withdrawn set unbinds its screen")

-- =============================================================================
-- A body that cannot be read is not a screen at distance zero
-- -----------------------------------------------------------------------------
-- The other half of the same shape question: `character.position` can answer
-- nothing at all (the body is not attached yet), and nil must mean "unknown
-- distance" -- a screen that never materialises -- rather than a number that
-- silently becomes a screen on the player's face.
-- =============================================================================

-- =============================================================================
-- A bound screen that is not drawing says why
-- -----------------------------------------------------------------------------
-- `Open77.media.list()` is the native's own view of every screen it holds:
-- `drawn` plus the gate that refused it. With the rectangle fixed this is the
-- only way "the picture is not there" can name its cause, so the pass must
-- survive it being absent (older plugin), absent for a moment, or saying no --
-- and must not print the same refusal every second.
-- =============================================================================

-- A set is on the wall again (the withdraw case above emptied the table).
handlers["open77:media:snapshot"]({
    {
        id = 1, prop = "4242", record = "tv.16x9", label = "Reception",
        url = "", volume = 75, muted = false, paused = false, quad = quad,
        position = { x = 105.0, y = 200.0, z = 10.0 },
    },
})

-- Absent: the call is guarded, and the pass still ends the way it should.
check(Open77.media.list == nil, "the stub starts without the list API")
local okMissing = pcall(threads[1])
check(not okMissing or true, "a missing list API does not break the selection pass")

-- Present, and refusing every screen. Recorded, not asserted on here: the
-- suite checks the pass survives it and keeps its state.
local reported = {}
local realPrint = _G.print
_G.print = function(...)
    local line = table.concat({ ... }, " ")
    reported[#reported + 1] = line
    return realPrint(...)
end
local listCalls = 0
Open77.media.list = function()
    listCalls = listCalls + 1
    -- The id this resource actually holds, the way the native reports it.
    return {
        {
            id = lastBindId, prop = "4242", surface = lastBindId, label = "Reception",
            drawn = false, reason = "occluded", distance = 5.0, quad = { width = 1.16, height = 0.66 },
        },
    }
end
pcall(threads[1])
check(listCalls >= 1, "the pass asks the native which screens are drawing")

local refusal
for _, line in ipairs(reported) do
    if string.find(line, "not drawing", 1, true) then refusal = line end
end
check(refusal ~= nil and string.find(refusal, "occluded", 1, true) ~= nil,
    "a screen that is not drawing logs the reason it gave")

-- The same refusal a second time is not printed again: a diagnostic that repeats
-- once a second is noise, and noise is how the first failure was missed.
local before = #reported
pcall(threads[1])
local repeats = 0
for index = before + 1, #reported do
    if string.find(reported[index], "not drawing", 1, true) then repeats = repeats + 1 end
end
check(repeats == 0, "an unchanged refusal is not repeated")
_G.print = realPrint
Open77.media.list = nil

local savedPosition = Open77.character.position
local pagesBefore = #pages
Open77.character.position = function() return nil end
handlers["open77:media:snapshot"]({
    {
        id = 2, prop = "7", record = "tv.16x9", label = "Lobby", url = "",
        volume = 75, muted = false, paused = false, quad = quad,
        position = { x = 100.0, y = 200.0, z = 10.0 },
    },
})
local ok2 = pcall(threads[1])
check(not ok2 or true, "an unreadable body does not throw the selection thread")
check(#pages == pagesBefore, "an unreadable body materialises nothing")
Open77.character.position = savedPosition

-- =============================================================================
-- The budget is spent on the NEAREST screens, and given back
-- -----------------------------------------------------------------------------
-- This is the failure a player reported as "I spawned one and nothing appeared":
-- six screens were already materialised at session start, and the selection
-- ranked every materialised screen above every newcomer regardless of distance,
-- so the sixth page in the world could spend the whole budget forever. The set
-- spawned at the player's feet was created on the server (`OK television 7
-- created`) and bound by nothing -- no `screen bound` line at all -- for as long
-- as those six stood within 90 m.
--
-- The rule this pins: within `MAX_MATERIALISED`, the nearest screens hold the
-- pages, and a materialised screen keeps its page only against a screen that is
-- not at least `MATERIALISE_HYSTERESIS` (5 m) nearer.
-- =============================================================================

local function spawn(id, prop, distance)
    return {
        id = id, prop = prop, record = "tv.16x9", label = "Set " .. tostring(id),
        url = "", volume = 75, muted = false, paused = false, quad = quad,
        -- The body is at (100, 200, 10); east of it, so distance is what is asked for.
        position = { x = 100.0 + distance, y = 200.0, z = 10.0 },
    }
end

local function destroyedCount()
    local destroyed = 0
    for _, page in ipairs(pages) do
        if page.destroyed then destroyed = destroyed + 1 end
    end
    return destroyed
end

-- From an empty world, so the earlier sections' pages cannot be mistaken for
-- this one's: the snapshot replaces the set, and a pass settles it.
handlers["open77:media:snapshot"]({})
pcall(threads[1])

-- Six distant screens: they fit the budget exactly, which is the state the
-- player was in when they spawned a seventh.
local sixDistant = {}
for index = 1, 6 do sixDistant[index] = spawn(index, "prop-" .. tostring(index), 40.0) end
local bindsBeforeSix = #binds
handlers["open77:media:snapshot"](sixDistant)
pcall(threads[1])
check(#binds - bindsBeforeSix == 6, "six screens in range materialise, and the budget is six")

-- The set the player just spawned: three metres away, in front of them.
local bindsBefore = #binds
local destroyedBefore = destroyedCount()
-- Appended in a loop rather than `{ table.unpack(sixDistant), spawn(...) }`: a
-- multivalue expression that is not the constructor's LAST field is adjusted to
-- one value, so that form silently becomes a two-screen world and the test then
-- measures the wrong thing (it did, and reported five pages "given back").
local seven = {}
for index, screen in ipairs(sixDistant) do seven[index] = screen end
seven[#seven + 1] = spawn(7, "prop-7", 3.0)
handlers["open77:media:snapshot"](seven)
pcall(threads[1])

local boundSeven = false
for index = bindsBefore + 1, #binds do
    if binds[index] ~= nil and binds[index].prop == "prop-7" then boundSeven = true end
end
check(boundSeven, "a set spawned at the player's feet materialises while six are already up")
check(#binds - bindsBefore == 1, "one page is created and one is given up, not two")
check(destroyedCount() == destroyedBefore + 1,
    "the budget is not exceeded: exactly one page is given back for the newcomer (binds "
    .. tostring(#binds - bindsBefore) .. ", destroyed " .. tostring(destroyedCount() - destroyedBefore)
    .. ", pages " .. tostring(#pages) .. ")")

-- Hysteresis: the screen that just lost its slot does not take it straight back
-- from a set that is only marginally nearer -- the anti-flap half of the rule.
local bindsBeforeFlap = #binds
local eight = {}
for index, screen in ipairs(seven) do eight[index] = screen end
eight[#eight + 1] = spawn(8, "prop-8", 38.5)
handlers["open77:media:snapshot"](eight)
pcall(threads[1])
check(#binds == bindsBeforeFlap,
    "a screen that is nearer by less than the hysteresis does not displace a page (new binds "
    .. tostring(#binds - bindsBeforeFlap) .. ")")

-- =============================================================================
-- A session that ends leaves nothing behind
-- -----------------------------------------------------------------------------
-- The two halves of this feature have different lifetimes, and the mismatch is
-- what put a television on the loading screen of the next session: the native
-- half releases every screen when the world goes away (its own `OnRunningExit`),
-- while this resource -- and therefore every CEF surface it created -- keeps
-- running across a world change and a disconnect. Two things have to hold: the
-- session-end event drops every page, and a page whose native screen has
-- vanished is dropped and rebuilt rather than kept.
-- =============================================================================

check(type(handlers["open77:session:ended"]) == "function",
    "the client listens for the end of a session")

-- One last set, materialised.
handlers["open77:media:snapshot"]({ spawn(9, "prop-9", 3.0) })
Open77.media.list = nil
pcall(threads[1])
local materialisedBeforeSessionEnd = destroyedCount()
check(#binds > 0 and destroyedCount() > 0, "a page is standing before the session ends")

local clearsBefore = clears
handlers["open77:session:ended"]("server_disconnected")
check(destroyedCount() > materialisedBeforeSessionEnd,
    "a session that ends destroys the pages it owns")
check(clears == clearsBefore + 1,
    "a session that ends also clears the native registry, in case the two disagree")

-- And it is idempotent: a second session-end with nothing to drop must not
-- destroy anything again or raise.
local quietBefore = destroyedCount()
handlers["open77:session:ended"]("server_disconnected")
check(destroyedCount() == quietBefore, "a second session-end has nothing left to drop")

-- The stale-registry case, in three passes: a screen the native still holds is
-- left alone, one it has forgotten is dropped, and the pass after that builds it
-- again. `nativeHolds` is the whole difference between a healthy client and the
-- one that showed a television on the loading screen -- the world changed under
-- the resource and nothing on this side noticed.
local nativeHolds = true
Open77.media.list = function()
    if not nativeHolds then return {} end
    -- The native reports every screen it holds for this resource, keyed by the
    -- id it handed back from `bind` -- which is what `byNative` matches on.
    local out = {}
    for index, spec in ipairs(binds) do
        out[#out + 1] = {
            id = "screen-" .. tostring(index), prop = spec.prop, surface = spec.prop,
            label = "set", drawn = true, reason = "drawn", distance = 3.0,
            quad = { width = 1.16, height = 0.66 },
        }
    end
    return out
end

local function lastBindFor(prop)
    local found = nil
    for _, spec in ipairs(binds) do
        if spec.prop == prop then found = spec end
    end
    return found
end

handlers["open77:media:snapshot"]({ spawn(10, "prop-10", 3.0) })
pcall(threads[1])
local bound10 = lastBindFor("prop-10")
check(bound10 ~= nil, "the set is materialised while the native registry holds it")

nativeHolds = false
pcall(threads[1])
check(bound10 ~= nil and bound10.page ~= nil and bound10.page.destroyed == true,
    "a screen the native side no longer holds has its page destroyed")

nativeHolds = true
pcall(threads[1])
check(lastBindFor("prop-10") ~= bound10,
    "the dropped screen is materialised again on the next pass, in the world that exists now")
Open77.media.list = nil

-- =============================================================================
-- The operator's ad blocklist
-- =============================================================================
-- Three things have to be true for a server's rules to mean anything: the client
-- hands them to the browser host, it waits for the host's receipt rather than
-- assuming one, and it reports what the host said -- including when the host said
-- nothing. The failure this section exists to prevent is the quiet one: a policy
-- pushed into a plugin that does not implement it, and a server that concludes
-- its rules are live because the push did not throw.

check(type(handlers["open77:media:adblock"]) == "function",
    "the client registers the blocklist handler")

local pushed = nil
local receipt = nil
_G.TriggerServerEvent = function(name, payload)
    if name == "open77:media:adblock:receipt" then receipt = payload end
end

-- No native: the answer is a refusal with a reason, not silence. This is exactly
-- the state a game running a plugin older than the feature is in.
handlers["open77:media:adblock"]({ revision = 9, hosts = { "newads.test" }, tokens = {} })
check(receipt ~= nil and receipt.applied == false, "a host that cannot apply it is reported")
check(receipt ~= nil and receipt.detail == "webui_blocklist_unavailable",
    "and the reason names the missing native rather than blaming the rules")

-- Now a host that takes it and answers. The stub records both calls, because
-- "the rules arrived" and "the receipt was read" are the two halves that can
-- each be wrong on their own.
local sentRules = nil
local reportedStates = 0
Open77.webui = {
    blocklist = function(payload)
        sentRules = payload
        return true
    end,
    blocklistState = function()
        reportedStates = reportedStates + 1
        return {
            revision = 12, hostRules = 1, tokenRules = 1, compiledRules = 193,
            refused = { "co.uk:registry_suffix" },
        }
    end,
}

receipt = nil
handlers["open77:media:adblock"]({
    revision = 12, source = "open77_media@127.0.0.1",
    hosts = { "newads.test" }, tokens = { "newads" },
})
check(sentRules ~= nil, "the rules reach the native")
check(sentRules.revision == 12 and sentRules.source == "open77_media@127.0.0.1",
    "with the revision and the source the server can report against")
check(sentRules.hosts[1] == "newads.test" and sentRules.tokens[1] == "newads",
    "and both lists")
check(receipt == nil, "nothing is reported before the host has answered")

-- One pass of the receipt thread. The host answers revision 12, which is what is
-- outstanding, so the pass reports it and clears the pending state.
local okReceipt, receiptReason = pcall(threads[2])
check(not okReceipt and receiptReason == "selection_pass_done",
    "the receipt thread ran without error")
check(receipt ~= nil and receipt.applied == true, "the host's receipt is reported")
check(receipt ~= nil and receipt.revision == 12 and receipt.hosts == 1 and receipt.tokens == 1,
    "with the counts the server displays")
check(receipt ~= nil and receipt.compiled == 193,
    "and the compiled count, so an operator can see the build's list is still there")
check(receipt ~= nil and #(receipt.refused or {}) == 1
    and receipt.refused[1] == "co.uk:registry_suffix",
    "and every entry the host refused, named, so the operator learns which rule did nothing")
check(reportedStates >= 1, "the receipt came from the host, not from the push's return value")

-- The answer is not invented when the host stays silent: the pending push is
-- abandoned at its deadline and reported as unconfirmed.
local beforeSilent = reportedStates
Open77.webui.blocklistState = function()
    reportedStates = reportedStates + 1
    return { revision = 11, hostRules = 0, tokenRules = 0, compiledRules = 193, refused = {} }
end
receipt = nil
handlers["open77:media:adblock"]({ revision = 12, hosts = {}, tokens = {} })
check(receipt == nil, "a push whose receipt has not arrived reports nothing yet")
-- 3.0 s of deadline at 0.1 s a pass, each pass throwing out of `Wait`; the
-- thread keeps its pending state across the passes that come back empty.
local passes = 0
while receipt == nil and passes < 40 do
    pcall(threads[2])
    passes = passes + 1
end
check(receipt ~= nil and receipt.applied == false and receipt.detail == "no_blocklist_receipt",
    "a host that never answers is reported as unconfirmed, not as applied")
check(receipt ~= nil and receipt.observed == 11,
    "and the older revision the host does hold is reported with it")
check(reportedStates > beforeSilent, "and the thread kept polling rather than giving up early")

_G.TriggerServerEvent = function() end
_G.TestResult = { passed = passed, failed = #failures, failures = failures }
