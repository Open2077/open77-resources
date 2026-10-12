-- Cordon -- career, match rows and the ladder gate. Plan section 11.
--
-- This file is the `... write ...` half of the progression pair. `rating.lua`
-- next door is pure arithmetic and cannot find a match on its own; this file
-- owns everything durable: the identity capture, the gate, the write queue, the
-- schema, the hot-reload carry and the two readout commands.
--
-- It persists what the match ALREADY KNOWS -- placement, squad, kills, assists,
-- damage, revives, cordon deaths, survival time -- rather than recomputing any
-- of it from a ledger this mode keeps for the scoreboard. A career that
-- disagreed with the result card the player just read would be worse than no
-- career at all.
--
-- ===========================================================================
-- WHERE THE STATS LIVE, AND WHY THERE
-- ===========================================================================
--
-- 1. A PER-SERVER LADDER OWNED BY THE GAMEMODE, not a platform-wide profile
--    owned by the master.
--
--    The master (`Open77.Master`) owns accounts, licensing and leases, and it
--    is not reachable from server Lua at all -- there is no binding for it, so
--    a global profile would mean a new C# surface, a new master schema and a
--    production deployment, for numbers that are only meaningful relative to
--    ONE server's tuning. A win rate earned at 64 slots, `botFill = threshold`
--    and the shipped cordon schedule is not the same measurement as one earned
--    under an operator's own settings, and averaging them would produce a
--    number that describes nothing.
--
--    Decision 14 makes this cheap to be wrong about in one direction only:
--    PROGRESSION GATES NOTHING, so no other system has to read these rows. And
--    the key below is the master-backed GUID, so promoting this to a global
--    profile later is a migration of rows that are already keyed correctly --
--    not a re-keying. Starting global and discovering the numbers are not
--    comparable is the expensive mistake; starting local is not.
--
-- 2. MySQL THROUGH `Open77.database`, BECAUSE IT IS THE ONLY DURABLE STORE
--    SERVER LUA HAS.
--
--    The Lua sandbox nils out `io`, `os`, `package`, `dofile`, `loadfile`,
--    `load` and `require`. A resource cannot open a file, cannot write one, and
--    cannot even load a chunk from a string. `server/.open77/` is host-owned
--    and written only by C# -- and two of the files in it
--    (`master-identity.json`, `resource-signing-key.json`) are registration
--    SECRETS rather than cache, so it is not somewhere a gamemode has any
--    business writing even if it could. `Open77.tunables.set` does reach disk,
--    but it is a form's worth of declared scalars, not a table.
--
--    So: the database bridge, exactly as `open77_deathmatch`, `pursuit`,
--    `open77_appearance` and `open77_playerstate` use it. The manifest must
--    declare `database.access` or every call here fails with
--    `permission_denied:database.access` -- which lands in the degraded path
--    below and is reported, not swallowed.
--
-- 3. NO DATABASE IS A SUPPORTED STATE, NOT A FAILURE.
--
--    The dev profile ships with the bridge OFF on purpose: turning it on makes
--    the credential mandatory and it also wakes `open77_appearance`, which then
--    demands character creation the autonomous test loop cannot drive. So the
--    career degrades to a LOUDLY LABELLED in-memory table for the run, and
--    every readout says which store answered. A silent volatile ladder is
--    indistinguishable from a broken one -- and on a 64-slot mode where a match
--    takes twenty minutes, "did that count?" is a question the mode has to be
--    able to answer without anybody opening a SQL client.
--
-- ===========================================================================
-- THE FIVE THINGS THAT WOULD HAVE BROKEN THIS
-- ===========================================================================
--
-- 1. THE LADDER GATE IS AT THE WRITE, AND IT IS THE FIRST THING THIS FILE DOES.
--    `recordMatch` consults `ladderEligible` before it reads a single standings
--    row. A match containing a bot produces NO snapshot, NO queue entry, NO
--    announcement, NO statement -- and the rating model is never called at all.
--    There is nothing left behind for a later query, export or migration to
--    remember to filter out, because nothing was written.
--
--    Decision 21 makes this load-bearing rather than theoretical: in THIS mode
--    bots are contestants, they fill a match players did not fill, they occupy
--    a slot, they count as alive and THEY CAN WIN. On a young server most
--    matches will contain one. A ladder that rated them would be a ladder of
--    who got the emptiest lobby.
--
--    (Gang holdout NPCs are a different thing entirely and never taint: they
--    are not contestants, they hold no slot and they appear in no standings
--    row. Only `taintMatch` taints, and only the bot-fill code calls it.)
--
-- 2. PLAYER IDS ARE REISSUED; THE IDENTIFIER IS NOT. Every row is keyed on
--    `Open77.players.identifier` -- the 36-character master-backed GUID bound
--    to the client's identity certificate. Keying on a player id would arm the
--    next arrival on that id with the last occupant's career.
--
--    That binding is one of the FIVE that RAISE from inside the C function on a
--    non-positive id (`players.name`, `players.position`, `players.identifier`,
--    `ready.isReady`, `SetPlayerRoutingBucket`), and the CLR exception unwinds
--    past every `pcall` and STOPS the resource -- the crash that killed every
--    bot round in the deathmatch four seconds in. A bot is a participant with a
--    NEGATIVE id and bots are in the standings rows this file iterates. So the
--    id is gated by this file's own `positiveId` (which returns nil for
--    anything below 1) BEFORE any of those five is touched, and never after.
--
-- 3. IDENTITY IS CAPTURED EAGERLY, because `Open77.players.identifier` returns
--    nil for somebody who has already left -- and a player who disconnected is
--    exactly the case that most needs attributing. Decision 10 makes a
--    disconnect an ELIMINATION: the leaver has a placement, that placement is
--    part of everybody else's pairwise result, and a match resolves at exactly
--    the moment somebody may have gone. So identity is snapshotted on connect
--    and again at match start, and the write uses the snapshot.
--
-- 4. NOTHING ACCUMULATES ACROSS MATCHES IN LUA. The unit of persistence is ONE
--    MATCH. A hot reload hands the successor VM a fresh everything, so a module
--    that banked a session total and flushed it "later" would lose whatever it
--    was holding on every Lua save -- and this mode is edited while it runs.
--    Recording at match end means a reload can cost at most the match that is
--    live, which is unavoidable and honest; the pending queue itself rides
--    across the reload in `Open77.state`.
--
-- 5. THE CARRIED-STATE BAG IS SHARED AND MUST BE READ-MODIFY-WRITTEN. It is ONE
--    64 KiB string per RESOURCE, and `server/mapstore.lua`, the kernel and
--    anybody else in `open77_cordon` write into the same one. A second writer
--    that builds its payload from scratch SILENTLY DELETES the first's data --
--    no error, no log line, just a surveyor's afternoon of walking gone. So
--    everything this file carries lives under ONE top-level key
--    (`CARRY_KEY` below), and `carry()` loads the bag, keeps every key that is
--    not that one, and writes the merge. Every other writer must do the mirror
--    image. Nobody owns the bag; each owns its own key.
-- ===========================================================================

CordonRanked = CordonRanked or {}

local Ranked = CordonRanked

-- Server resources cannot link, so the `Cordon` global IS the module system and
-- `server/match.lua` reaches this file as `K.ranked.recordMatch`. Published
-- here, at the top, rather than at `onResourceStart`: the manifest loads
-- `match.lua` after this file but a hot reload can re-enter in any order, and a
-- nil `K.ranked` at the one moment a match resolves is a match that is silently
-- never written. `Cordon` is created by `kernel.lua`; if it has not run yet
-- (unit test, or a manifest edit), this file still works standalone through the
-- `CordonRanked` global and simply publishes nothing.
do
    local ok, root = pcall(function() return _ENV["Cordon"] end)
    if ok and type(root) == "table" then root.ranked = Ranked end
end


-- ------------------------------------------------------------------ config --

-- Defaults spelled out so a server whose config predates this file still runs.
local DEFAULTS = {
    enabled = true,
    -- The per-player-per-match rows. On at all times in practice; the switch
    -- exists for an operator running a career-only ladder on a small disk.
    recordMatches = true,
    tablePrefix = "open77_br_",
    -- Plan section 11: matches with fewer than this many HUMANS are recorded
    -- but not rated. 16 because a battle-royale placement is a statement about
    -- a field, and a field of five is a skirmish -- rating it would let four
    -- people at 3 a.m. move a ladder more than sixty-four people at peak.
    ratedMinPlayers = 16,
    announceOnJoin = true,
    -- 64 slots, so the carry budget is sized for a full lobby rather than the
    -- deathmatch's twelve.
    maxCarriedIdentities = 72,
    maxCarriedMatches = 8,
    maxPendingMatches = 64,
    maxTaints = 512,
    statementChunk = 48,        -- the bridge refuses more than 64 per transaction
}

local function globalTable(name)
    local ok, value = pcall(function() return _ENV[name] end)
    if not ok or type(value) ~= "table" then return nil end
    return value
end

-- `Cordon.tune.<key>` is a call behind the kernel's tunable metatable, so it is
-- read at the point of use and never captured: the Warden panel can move
-- `ratedMinPlayers` between two matches. Wrapped because the kernel may not
-- have started, and because a server that never declared the tunable has no
-- registry entry at all.
local function liveTune(key)
    local root = globalTable("Cordon")
    if root == nil then return nil end
    local tune = root.tune
    if type(tune) ~= "table" then return nil end
    local ok, value = pcall(function() return tune[key] end)
    if not ok then return nil end
    return value
end

local function setting(key)
    local live = liveTune(key)
    if live ~= nil then return live end
    local config = globalTable("CordonConfig")
    local block = config ~= nil and config.career or nil
    if type(block) == "table" and block[key] ~= nil then return block[key] end
    return DEFAULTS[key]
end

local function enabled()
    return setting("enabled") ~= false
end

local function tableName(suffix)
    local prefix = tostring(setting("tablePrefix") or "open77_br_")
    -- The prefix reaches SQL as an IDENTIFIER, and identifiers cannot be bound
    -- as parameters. It is operator-supplied config, so it is whitelisted here
    -- rather than trusted: anything outside [A-Za-z0-9_] falls back to the
    -- default instead of being concatenated into a statement.
    if prefix:match("^[A-Za-z_][A-Za-z0-9_]*$") == nil then prefix = "open77_br_" end
    return prefix .. suffix
end

local function log(text)
    local root = globalTable("Cordon")
    if root ~= nil and type(root.log) == "function" then
        local ok = pcall(root.log, "ranked: " .. tostring(text))
        if ok then return end
    end
    print("[cordon] ranked: " .. tostring(text))
end


-- ------------------------------------------------------------- id hygiene --
--
-- These two are DELIBERATELY LOCAL rather than borrowed from the kernel.
--
-- `positiveId` is the guard in front of the five bindings that raise from
-- inside the C function and stop the whole resource. A gate that lives in a
-- neighbouring file can be relaxed by somebody editing that file for an
-- unrelated reason, and the failure it prevents has no Lua frame and no stack:
-- the CLR exception unwinds past every `pcall`, out of the Lua host, and
-- `ServerResourceHost.Tick` logs the message bare and stops the resource. So it
-- lives here, where the calls it protects also live.

--- Player ids arrive from every handler and command as STRINGS. `tonumber` at
--- every entry point, or the table keys silently diverge and one player ends up
--- with two records that never meet.
--- Returns nil for anything that is not a positive integer -- which includes a
--- bot's negative participant id, and that is the whole point.
local function positiveId(value)
    local parsed = tonumber(value)
    if parsed == nil or parsed ~= parsed or parsed <= 0 then return nil end
    return math.floor(parsed)
end

--- Command arguments and event payloads may be anything at all; NaN and the
--- infinities pass `tonumber` and poison every comparison downstream.
local function finite(value)
    local parsed = tonumber(value)
    if parsed == nil or parsed ~= parsed
        or parsed == math.huge or parsed == -math.huge then
        return nil
    end
    return parsed
end

local function nowMs()
    local root = globalTable("Open77")
    local time = root ~= nil and root.time or nil
    if type(time) ~= "table" or type(time.monotonic) ~= "function" then return 0 end
    local ok, seconds = pcall(time.monotonic)
    if not ok or type(seconds) ~= "number" then return 0 end
    return math.floor(seconds * 1000)
end

--- A name, for a readout only. Guarded: `Open77.players.name` is one of the
--- five that raise on a non-positive id.
local function playerName(value)
    local id = positiveId(value)
    if id == nil then return "?" end
    local root = globalTable("Open77")
    local players = root ~= nil and root.players or nil
    if type(players) ~= "table" or type(players.name) ~= "function" then
        return "Player " .. tostring(id)
    end
    local ok, name = pcall(players.name, id)
    if not ok or name == nil then return "Player " .. tostring(id) end
    return tostring(name)
end


-- ---------------------------------------------------------- career fields --
--
-- One definition of what a career is made of, used by the blank record, the
-- match delta, the database read, the carry and the readout, so the five cannot
-- drift apart.
--
-- Three kinds, because a battle-royale career has three kinds of number and
-- collapsing them is how a "best placement" ends up reading 0 forever:
--
--   SUM  accumulates            matches, wins, top4, kills, ...
--   MAX  keeps the largest      longestSurvivalMs
--   MIN  keeps the SMALLEST     bestPlacement -- placement 1 is the best result
--
-- `bestPlacement` uses 0 AS THE "NO DATA" SENTINEL, in Lua and in SQL alike. A
-- minimum column cannot default to 0 and also mean it, because 0 would then win
-- every comparison and the column would read "best placement: none" forever
-- after the first row. Every read and every upsert therefore tests for 0
-- explicitly; see `minInto` and the `IF(...)` ladder in `statementsFor`.
local SUM_FIELDS = {
    "matches", "wins", "top4", "kills", "assists", "damage", "revives", "cordonDeaths",
}
local MAX_FIELDS = { "longestSurvivalMs" }
local MIN_FIELDS = { "bestPlacement" }

local function blankTotals()
    local totals = {}
    for _, field in ipairs(SUM_FIELDS) do totals[field] = 0 end
    for _, field in ipairs(MAX_FIELDS) do totals[field] = 0 end
    for _, field in ipairs(MIN_FIELDS) do totals[field] = 0 end
    return totals
end

-- 0 means "no placement recorded", so it must never win the comparison.
local function minInto(current, candidate)
    current = math.floor(tonumber(current) or 0)
    candidate = math.floor(tonumber(candidate) or 0)
    if candidate <= 0 then return current end
    if current <= 0 then return candidate end
    return math.min(current, candidate)
end

local function addTotals(into, delta)
    for _, field in ipairs(SUM_FIELDS) do
        into[field] = (into[field] or 0) + math.floor(tonumber(delta[field]) or 0)
    end
    for _, field in ipairs(MAX_FIELDS) do
        into[field] = math.max(into[field] or 0, math.floor(tonumber(delta[field]) or 0))
    end
    for _, field in ipairs(MIN_FIELDS) do
        into[field] = minInto(into[field], delta[field])
    end
    return into
end

-- `stored` is what the durable store last said; `session` is what has been
-- recorded since and is not yet reflected in it. The readout is the sum, so a
-- player who just finished a match sees it immediately whether or not the
-- transaction has landed.
local function combine(stored, session)
    local out = blankTotals()
    addTotals(out, stored)
    addTotals(out, session)
    return out
end


-- ------------------------------------------------------------------- state --

-- identifier -> { identifier, loaded, requested, modes = { <format> = slot } }
--
-- The authoritative copy while the server runs. The database is where it goes
-- to survive a restart, not where it is read from during a match.
local careers = {}

-- Matches recorded and not yet durably written. Carried across a hot reload.
local pending = {}

-- Tri-state, exactly as the deathmatch and `open77_appearance` do it. There is
-- no "is the database on?" question to ask -- `MySQL` is installed by the
-- bootstrap whether or not the bridge is enabled and whether or not this
-- resource holds `database.access`, so testing the global proves nothing. The
-- first real statement is the probe.
--   nil   = not probed yet
--   true  = schema is up, rows persist
--   false = degraded to memory for this run
local dbReady = nil
local dbReason = "not probed"

-- playerId -> true when THIS Lua generation saw them connect. The durable
-- marker is the ABSENCE of `onPlayerConnected`, which does not re-fire for a
-- client that is already connected: no connect in this generation means the
-- player was in the world before the reload. `announced` is empty for exactly
-- the same reason, so the two absences cancel and a reload survivor is marked
-- announced and left alone. A Lua save must not print a career card in front of
-- somebody who is mid-drop.
local connected = {}
local announced = {}

local function storageLine()
    if not enabled() then return "career DISABLED in config" end
    if dbReady == true then return "database (" .. tableName("career") .. ")" end
    if dbReady == false then return "MEMORY ONLY -- volatile (" .. dbReason .. ")" end
    return "not probed yet"
end
Ranked.storageLine = storageLine


-- ========================================================================
-- THE LADDER GATE
-- ========================================================================
--
-- A STICKY PER-MATCH TAINT. Set once by whoever adds a bot; never cleared for
-- the life of that match id. Sticky matters because bot fill is not a decision
-- taken once at staging: `botFill = threshold` tops a match up as humans leave,
-- so a match can be all-human at minute 0 and hold four bots at minute 12. A
-- taint that could be re-evaluated at the end would rate that match if the bots
-- happened to die first, which is precisely the lobby a ladder must not reward.
--
-- matchId -> reason string.
local tainted = {}
local taintCount = 0

local function pruneTaints()
    local ceiling = math.floor(tonumber(setting("maxTaints")) or 512)
    if taintCount <= ceiling then return end
    -- Drop the LOWEST match ids. Match ids increase, and a match is recorded
    -- within seconds of resolving, so anything this far behind the current one
    -- was written or dropped long ago. The cap exists only so a server that
    -- runs for a month does not accumulate an unbounded table; it is set two
    -- orders of magnitude above the window in which a taint can still matter.
    local ids = {}
    for id in pairs(tainted) do ids[#ids + 1] = id end
    table.sort(ids)
    for index = 1, #ids - ceiling do
        tainted[ids[index]] = nil
        taintCount = taintCount - 1
    end
end

--- Mark a match as containing a bot. IDEMPOTENT and one-way.
---
--- Called by the bot-fill code every time a bot is added to a match. It is
--- deliberately a positive action rather than something inferred at the write
--- from the standings: a bot that was added and then removed before the end
--- still made the match a filled one, and inference from the final roster would
--- miss it.
function Ranked.taintMatch(matchId, reason)
    local id = finite(matchId)
    if id == nil then
        -- A taint that cannot be keyed is the one failure that must not pass
        -- quietly, because the consequence is a bot match being rated. There is
        -- no match to attach it to, so say so loudly and let the caller's own
        -- log show the missing id.
        log("taintMatch called with an unusable match id -- THE MATCH IT MEANT IS NOT GATED")
        return false
    end
    id = math.floor(id)
    if tainted[id] == nil then
        taintCount = taintCount + 1
        tainted[id] = tostring(reason or "bots")
        pruneTaints()
    end
    return true
end

--- Is this match allowed to touch the ladder at all?
---
--- Returns `true` only when nothing has tainted it and no independent bot
--- module disagrees. FAILS CLOSED in every ambiguous case: an unusable match
--- id, a bot module that raises, a bot module that answers anything other than
--- `true`. The cost of a false negative is one unrated match; the cost of a
--- false positive is a corrupted ladder that nobody can retroactively clean,
--- because the rows are indistinguishable once written.
---
--- The two taints are INDEPENDENT and AND-ed, exactly as the deathmatch does
--- it: this file's own sticky set, and the bot module's own per-match record if
--- it publishes one. Losing either file mid-match refuses the write rather than
--- laundering it.
function Ranked.ladderEligible(matchId)
    local id = finite(matchId)
    if id == nil then return false end
    id = math.floor(id)
    if tainted[id] ~= nil then return false end

    local root = globalTable("Cordon")

    -- THE SECOND, INDEPENDENT TAINT. `server/match.lua` keeps its own
    -- `current.tainted`, set by `M.taint(why)` the moment a bot is added, and
    -- the two are AND-ed rather than one deferring to the other: losing either
    -- file mid-match must refuse the write, not launder it.
    --
    -- It is only consulted for the CURRENT match, because that flag lives on
    -- the live match table and says nothing about a past one -- and a past
    -- match's verdict is already frozen in the sticky set above. Asking it
    -- about the wrong match would be worse than not asking.
    local match = root ~= nil and root.match or nil
    if type(match) == "table" and type(match.current) == "function" then
        local read, live = pcall(match.current)
        if not read then
            log(("match module raised while asked about match %d -- refusing the write"):format(id))
            return false
        end
        if type(live) == "table" then
            local liveId = finite(live.id)
            if liveId ~= nil and math.floor(liveId) == id and live.tainted == true then
                return false
            end
        end
    end

    local bots = root ~= nil and root.bots or nil
    if type(bots) == "table" and type(bots.ladderEligible) == "function" then
        local ok, verdict = pcall(bots.ladderEligible, id)
        if not ok then
            log(("bot module raised while asked about match %d -- refusing the write"):format(id))
            return false
        end
        if verdict ~= true then return false end
    end
    return true
end

--- Why a match was refused, for the operator readout and the exclusion notice.
function Ranked.taintReason(matchId)
    local id = finite(matchId)
    if id == nil then return "unusable match id" end
    return tainted[math.floor(id)]
end


-- --------------------------------------------------------------- identity --

--- The one safe door onto `Open77.players.identifier`.
---
--- `positiveId` returns nil for anything below 1, so a bot's negative
--- participant id -- which IS in the standings rows this file walks -- never
--- reaches the binding that would stop the resource. A valid but departed
--- player answers nil, which is a refusal, not an error.
local function identifierOf(value)
    local id = positiveId(value)
    if id == nil then return nil end
    local root = globalTable("Open77")
    local players = root ~= nil and root.players or nil
    if type(players) ~= "table" or type(players.identifier) ~= "function" then return nil end
    local ok, identifier = pcall(players.identifier, id)
    if not ok or type(identifier) ~= "string" then return nil end
    -- The master formats it "D", so it is exactly 36 characters. Anything else
    -- is refused outright rather than written as a career nobody can be matched
    -- back to. `open77_appearance` and `open77_playerstate` gate on the same
    -- length for the same reason.
    if #identifier ~= 36 then return nil end
    if identifier:find("[^0-9A-Fa-f%-]") ~= nil then return nil end
    return identifier
end

-- playerId -> identifier, captured while the player is certainly present.
local identities = {}

local function rememberIdentity(value)
    local id = positiveId(value)
    if id == nil then return nil end
    local identifier = identifierOf(id)
    -- Never overwrite a known identity with a miss: the miss is exactly what a
    -- departed player produces, and a departed player is the one this snapshot
    -- exists for.
    if identifier ~= nil then identities[id] = identifier end
    return identities[id]
end

local function careerFor(identifier)
    local record = careers[identifier]
    if record == nil then
        record = { identifier = identifier, loaded = false, requested = false, modes = {} }
        careers[identifier] = record
    end
    return record
end

-- THE RATING RIDES IN THE SAME SLOT AS THE CAREER, and it deliberately does NOT
-- ride in `stored` / `session`. Those are counters and extrema: `addTotals`
-- treats every field in them as a sum, a maximum or a minimum, and the SQL
-- upsert accumulates them as deltas so two servers sharing one database cannot
-- overwrite each other. A rating is none of those things -- it is a GAUGE, it
-- can go down, and it is computed FROM its current value rather than added to
-- it. Folding it into `SUM_FIELDS` would have `combine` add a stored 1200 to a
-- session 1200 and report 2400.
--
--   rating         the last settled value; nil until the store has answered, at
--                  which point `settings.start` is what an absent row means
--   ratingMatches  rated matches in THIS format, which is what picks the K
--   ratingPending  deltas computed for matches whose write has not landed yet
--   peak           the high-water mark, never lowered
local function modeSlot(record, mode)
    local slot = record.modes[mode]
    if slot == nil then
        slot = {
            stored = blankTotals(), session = blankTotals(),
            rating = nil, ratingMatches = 0, ratingPending = 0,
            peak = nil, lastDelta = 0,
        }
        record.modes[mode] = slot
    end
    -- A slot built by an older generation of this file and adopted across a hot
    -- reload may have the career fields and not these; default them in place
    -- rather than anywhere the arithmetic would have to test for nil.
    if slot.ratingMatches == nil then slot.ratingMatches = 0 end
    if slot.ratingPending == nil then slot.ratingPending = 0 end
    if slot.lastDelta == nil then slot.lastDelta = 0 end
    return slot
end

-- Resolved at CALL time, never captured: `server/rating.lua` can be reloaded
-- under this one, and a server that drops it from the manifest keeps its career
-- and simply stops rating.
local function ratingModule()
    local module = globalTable("CordonRating")
    if module == nil or type(module.placement) ~= "function" then return nil end
    return module
end

local function ratingSettings(format)
    local module = ratingModule()
    if module == nil then return nil end
    local ok, settings = pcall(module.settings, format)
    if not ok or type(settings) ~= "table" then return nil end
    return settings
end

--- What a player's rating READS as right now: the last settled value, plus any
--- delta computed for a match whose write has not landed. Same rule as the
--- career numbers, which already include the unwritten matches -- one readout
--- cannot be honest about the kills and coy about the rating.
local function ratingValue(slot, settings)
    local base = slot.rating
    if base == nil then base = settings ~= nil and settings.start or 1000 end
    return base + (slot.ratingPending or 0)
end


-- ------------------------------------------------------- carried state --
--
-- `Open77.state` is host-owned and survives a hot reload; it is deliberately
-- dropped on stop/restart and it is not a database. Four things ride in it, and
-- each has to earn its place because the bag is small:
--
--   pending   matches recorded whose transaction has not landed
--   volatile  when the bridge is off, the career itself -- which would
--             otherwise be wiped by every Lua save on precisely the servers
--             where testing happens
--   tainted   THE STICKY BOT TAINTS. This one is not bookkeeping: a match
--             tainted at minute 4 and resolved at minute 18 spans any Lua save
--             in between, and a taint that died with the outgoing VM would let
--             the successor rate a bot match. The gate must survive the reload
--             or it is not a gate.
--   ratings   re-armed from `pending`, see `adopt`
--
-- THE BAG IS 64 KiB AND IT IS SHARED. There is one per RESOURCE, and
-- `server/mapstore.lua` carries the map a surveyor is authoring in the same
-- one. So everything here lives under ONE top-level key and `carry` does a
-- READ-MODIFY-WRITE: load the bag, keep every key that is not ours, write the
-- merge. A writer that built its payload from scratch would delete the other's
-- without any error at all -- no exception, no log line, just an afternoon of
-- surveying gone. Every writer in this resource must do the same.
--
-- It is trimmed rather than allowed to raise: an oversized save throws from the
-- C function, and losing a career readout is a far smaller failure than
-- stopping the resource.
local CARRY_KEY = "cordonRanked"
local CARRY_PROTOCOL = 1
local CARRY_BUDGET_BYTES = 48 * 1024

local function carriedPayload(identityLimit, matchLimit)
    local matches = {}
    for index = math.max(1, #pending - matchLimit + 1), #pending do
        matches[#matches + 1] = pending[index]
    end

    -- The taints are carried WHOLE and are never trimmed by the budget loop
    -- below. They are a handful of integers, and dropping one is not a smaller
    -- readout -- it is a bot match becoming rateable.
    local taints = {}
    for id, reason in pairs(tainted) do taints[tostring(id)] = tostring(reason) end

    local volatileCareers = nil
    if dbReady == false then
        volatileCareers = {}
        local kept = 0
        for identifier, record in pairs(careers) do
            if kept >= identityLimit then break end
            local modes = {}
            local any = false
            for mode, slot in pairs(record.modes) do
                local totals = combine(slot.stored, slot.session)
                -- THE RATING RIDES TOO, and it needs its own reason to be
                -- carried: a player can hold a rating with no career matches
                -- attached to it in this VM -- adopted across an earlier
                -- reload, or loaded from a store that has since gone away --
                -- and losing it on the next Lua save is exactly the "volatile
                -- ladder that looks broken" this whole carry exists to prevent.
                -- These three keys are in none of the three field lists, so
                -- `addTotals` on the other side steps straight over them and
                -- the career arithmetic cannot be corrupted by their presence.
                if slot.rating ~= nil then
                    totals.rating = slot.rating
                    totals.ratingMatches = slot.ratingMatches or 0
                    totals.peak = slot.peak or slot.rating
                end
                if totals.matches > 0 or slot.rating ~= nil then
                    modes[mode] = totals
                    any = true
                end
            end
            if any then
                volatileCareers[identifier] = modes
                kept = kept + 1
            end
        end
    end

    return {
        protocol = CARRY_PROTOCOL,
        pending = matches,
        volatile = volatileCareers,
        tainted = taints,
    }
end

local function carry()
    local root = globalTable("Open77")
    local state = root ~= nil and root.state or nil
    if type(state) ~= "table" or type(state.save) ~= "function" then return end

    local identityLimit = math.floor(tonumber(setting("maxCarriedIdentities")) or 72)
    local matchLimit = math.floor(tonumber(setting("maxCarriedMatches")) or 8)
    local encoder = globalTable("json")
    if encoder == nil or type(encoder.encode) ~= "function" then return end

    for _ = 1, 5 do
        local payload = carriedPayload(identityLimit, matchLimit)
        local ok, encoded = pcall(encoder.encode, payload)
        if not ok then return end
        if #encoded <= CARRY_BUDGET_BYTES then
            -- READ-MODIFY-WRITE. See the block comment above: this file is not
            -- the bag's only user and a payload built from scratch silently
            -- deletes everybody else's keys.
            local bag = {}
            if type(state.load) == "function" then
                local read, existing = pcall(state.load)
                if read and type(existing) == "table" then
                    for key, value in pairs(existing) do
                        if key ~= CARRY_KEY then bag[key] = value end
                    end
                end
            end
            bag[CARRY_KEY] = payload

            -- Never called from inside `onResourceStop`: a reload prepares the
            -- successor BEFORE stopping this VM, so a write from a stopping
            -- resource is refused. Every call site here is a state change,
            -- which is what the contract asks for.
            pcall(state.save, bag)
            return
        end
        identityLimit = math.floor(identityLimit / 2)
        matchLimit = math.max(2, math.floor(matchLimit / 2))
        if identityLimit < 1 then identityLimit = 1 end
    end
    log("carried state would not fit in 48 KiB even trimmed -- not carried")
end

local function adopt()
    local root = globalTable("Open77")
    local state = root ~= nil and root.state or nil
    if type(state) ~= "table" or type(state.load) ~= "function" then return end
    local ok, bag = pcall(state.load)
    if not ok or type(bag) ~= "table" then return end
    local carried = bag[CARRY_KEY]
    if type(carried) ~= "table" then return end
    if carried.protocol ~= CARRY_PROTOCOL then
        log("carried state from another protocol version discarded")
        return
    end

    -- THE TAINTS FIRST, and unconditionally. Everything else in this function
    -- is a convenience; this is the gate. A bot match that spanned the reload
    -- must still be refused by the successor VM.
    local taints = 0
    if type(carried.tainted) == "table" then
        for id, reason in pairs(carried.tainted) do
            local matchId = finite(id)
            if matchId ~= nil then
                matchId = math.floor(matchId)
                if tainted[matchId] == nil then
                    tainted[matchId] = tostring(reason or "bots")
                    taintCount = taintCount + 1
                    taints = taints + 1
                end
            end
        end
    end

    -- REVALIDATED, NOT TRUSTED. This is JSON written by a previous generation
    -- of this file's own code, and the one field everything downstream indexes
    -- on is the identifier: `careers[nil]` raises, and a nil named parameter is
    -- an ABSENT key in a Lua values table, so it never reaches the binder and
    -- the driver rejects the whole statement for an undefined `@id`. An entry
    -- that cannot be keyed is dropped here rather than at either of those.
    local matches = 0
    if type(carried.pending) == "table" then
        for _, record in ipairs(carried.pending) do
            if type(record) == "table" and type(record.entries) == "table" then
                local entries = {}
                for _, entry in ipairs(record.entries) do
                    if type(entry) == "table" and type(entry.identifier) == "string"
                        and #entry.identifier == 36 then
                        entries[#entries + 1] = entry
                    end
                end
                if #entries > 0 then
                    record.entries = entries
                    record.mode = tostring(record.mode or "solo")
                    record.matchId = math.floor(tonumber(record.matchId) or 0)
                    record.botsSeen = math.floor(tonumber(record.botsSeen) or 0)
                    record.humans = math.floor(tonumber(record.humans) or #entries)
                    record.keyed = math.floor(tonumber(record.keyed) or #entries)
                    record.rateable = record.rateable == true
                    -- A match that was rated before its write failed keeps the
                    -- exchange it earned; recomputing it against a table that
                    -- has moved since would rate the same match twice from
                    -- different baselines. Revalidated to numbers, and dropped
                    -- entirely rather than half-trusted -- a missing block is a
                    -- match that simply gets rated on the retry.
                    local results = nil
                    if type(record.ratingResults) == "table" then
                        results = {}
                        for _, result in ipairs(record.ratingResults) do
                            local delta = type(result) == "table" and tonumber(result.delta) or nil
                            if delta == nil or delta ~= delta or type(result.key) ~= "string"
                                or #result.key ~= 36 then
                                results = nil
                                break
                            end
                            results[#results + 1] = {
                                key = result.key,
                                before = math.floor(tonumber(result.before) or 0),
                                delta = math.floor(delta),
                                after = math.floor(tonumber(result.after) or 0),
                                placement = math.floor(tonumber(result.placement) or 0),
                            }
                        end
                        if results ~= nil and #results == 0 then results = nil end
                    end
                    record.ratingResults = results
                    record.ratingFloor = math.floor(tonumber(record.ratingFloor) or 0)
                    pending[#pending + 1] = record
                    matches = matches + 1
                end
            end
        end
    end

    local identityCount = 0
    if type(carried.volatile) == "table" then
        for identifier, modes in pairs(carried.volatile) do
            if type(identifier) == "string" and #identifier == 36 and type(modes) == "table" then
                local record = careerFor(identifier)
                for mode, totals in pairs(modes) do
                    if type(totals) == "table" then
                        local slot = modeSlot(record, tostring(mode))
                        addTotals(slot.stored, totals)
                        -- Revalidated like everything else here: a rating that
                        -- arrives as a string or a table would poison every
                        -- later exchange rather than failing anywhere visible.
                        local rating = tonumber(totals.rating)
                        if rating ~= nil and rating == rating then
                            slot.rating = math.floor(rating)
                            slot.ratingMatches =
                                math.max(0, math.floor(tonumber(totals.ratingMatches) or 0))
                            slot.peak = math.floor(tonumber(totals.peak) or slot.rating)
                        end
                    end
                end
                identityCount = identityCount + 1
            end
        end
    end

    -- Re-arm the unsettled rating deltas, AFTER the volatile block above has
    -- put the settled ratings back. `ratingPending` is what makes a card honest
    -- between an exchange and the write that carries it; it died with the
    -- outgoing VM while the exchange itself rode across in `pending`, so
    -- without this the two would disagree until the retry landed.
    for _, record in ipairs(pending) do
        for _, result in ipairs(record.ratingResults or {}) do
            local slot = modeSlot(careerFor(result.key), record.mode)
            slot.ratingPending = (slot.ratingPending or 0) + result.delta
        end
    end

    if matches > 0 or identityCount > 0 or taints > 0 then
        log(("adopted %d unwritten match(es), %d volatile career(s) and %d bot taint(s) across a reload")
            :format(matches, identityCount, taints))
    end
end


-- ------------------------------------------------------------------ schema --
--
-- Three tables. Prefix `open77_br_` (plan section 11).
--
-- `<prefix>career` is the ladder: one row per identity PER FORMAT, because a
-- solo win rate says nothing about a squad win rate (section 11: "No overall
-- rating across formats") and folding them together would produce a number that
-- describes neither.
--
-- `<prefix>matches` is one row per persisted player per match, and it is not
-- bookkeeping either: it exists so that "a match containing a bot leaves no row
-- behind" is a question somebody can actually ASK --
--
--     SELECT COUNT(*) FROM open77_br_matches WHERE match_id = ?;
--     SELECT COUNT(*) FROM open77_br_matches WHERE bots_present <> 0;
--
-- -- and the second of those is the gate's own assertion. `bots_present` is
-- filled with the number of NEGATIVE participant ids this file actually saw in
-- the standings, not with a constant: the taint should already have refused the
-- write, so a non-zero value there is proof the gate leaked, and a column that
-- can only ever be written 0 by construction would assert nothing.
--
-- An aggregate-only ladder can only ever be checked by not moving, which is
-- indistinguishable from a ladder that is not writing at all.
--
-- THERE IS NO NAME COLUMN, and that is deliberate rather than an omission. A
-- career row is durable, exportable data about a real person; the identifier is
-- opaque and already master-backed, and the display name is answered live by
-- `Open77.players.name` at the moment somebody reads the card. Storing it would
-- put a chosen human-readable handle on disk for no capability at all.
local function schema()
    return {
        ([[
        CREATE TABLE IF NOT EXISTS %s (
            identifier          CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
            mode                VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
            matches             BIGINT UNSIGNED NOT NULL DEFAULT 0,
            wins                BIGINT UNSIGNED NOT NULL DEFAULT 0,
            top4                BIGINT UNSIGNED NOT NULL DEFAULT 0,
            kills               BIGINT UNSIGNED NOT NULL DEFAULT 0,
            assists             BIGINT UNSIGNED NOT NULL DEFAULT 0,
            damage              BIGINT UNSIGNED NOT NULL DEFAULT 0,
            revives             BIGINT UNSIGNED NOT NULL DEFAULT 0,
            cordon_deaths       BIGINT UNSIGNED NOT NULL DEFAULT 0,
            best_placement      INT UNSIGNED NOT NULL DEFAULT 0,
            longest_survival_ms BIGINT UNSIGNED NOT NULL DEFAULT 0,
            first_seen          DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
            last_played         DATETIME NULL,
            PRIMARY KEY (identifier, mode),
            KEY idx_%s_ladder (mode, wins DESC)
        ) ENGINE=InnoDB
        ]]):format(tableName("career"), tableName("career")),

        ([[
        CREATE TABLE IF NOT EXISTS %s (
            id           BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
            match_id     BIGINT NOT NULL,
            identifier   CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
            mode         VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
            placement    INT NOT NULL DEFAULT 0,
            squad        VARCHAR(32) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT '',
            kills        INT NOT NULL DEFAULT 0,
            survived_ms  BIGINT NOT NULL DEFAULT 0,
            bots_present INT NOT NULL DEFAULT 0,
            played_at    DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
            KEY idx_%s_identity (identifier, mode),
            KEY idx_%s_match (match_id)
        ) ENGINE=InnoDB
        ]]):format(tableName("matches"), tableName("matches"), tableName("matches")),

        -- THE RATING IS ITS OWN TABLE, not four more columns on `career`.
        --
        -- Two reasons, and the second is the one that decided it. First, an
        -- existing deployment: `CREATE TABLE IF NOT EXISTS` cannot add a
        -- column, so folding the rating into `career` would need a migration --
        -- and `ALTER TABLE ... ADD COLUMN IF NOT EXISTS` is MariaDB-only syntax
        -- that would quietly make this ladder refuse to start on MySQL.
        --
        -- Second and more importantly, THE TWO HAVE DIFFERENT WRITE SEMANTICS.
        -- Every career column is a COUNTER (or an extremum of counters) and its
        -- upsert is a pure delta accumulation, which is what makes two servers
        -- sharing one database safe. A rating is a GAUGE computed from its own
        -- current value. Keeping them apart is what stops somebody adding
        -- `rating = VALUES(rating)` to a statement whose every other clause is
        -- `x = x + VALUES(x)`.
        --
        -- The key is the same (identifier, mode) as the career, so the two rows
        -- are one join apart, and a promotion to a master-owned global profile
        -- stays a migration of correctly-keyed rows rather than a re-keying.
        ([[
        CREATE TABLE IF NOT EXISTS %s (
            identifier    CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
            mode          VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
            rating        INT NOT NULL,
            peak          INT NOT NULL,
            rated_matches BIGINT UNSIGNED NOT NULL DEFAULT 0,
            last_delta    INT NOT NULL DEFAULT 0,
            first_seen    DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
            updated_at    DATETIME NULL,
            PRIMARY KEY (identifier, mode),
            KEY idx_%s_ladder (mode, rating DESC)
        ) ENGINE=InnoDB
        ]]):format(tableName("rating"), tableName("rating")),
    }
end

--- Probe the bridge by putting the schema up. Coroutine only -- `.await` yields.
local function ensureSchema()
    if dbReady ~= nil then return dbReady end
    local sql = globalTable("MySQL")
    if sql == nil then
        dbReady = false
        dbReason = "no MySQL global in this runtime"
        log("DATABASE UNAVAILABLE (" .. dbReason .. ") -- careers are VOLATILE this run")
        carry()
        return false
    end
    local ok, reason = pcall(function()
        for _, statement in ipairs(schema()) do sql.update.await(statement) end
    end)
    if not ok then
        dbReady = false
        dbReason = tostring(reason)
        log("DATABASE UNAVAILABLE (" .. dbReason .. ") -- careers are VOLATILE this run")
        -- The volatile career now needs the reload bridge it did not need while
        -- the durable store was still a possibility.
        carry()
        return false
    end
    dbReady = true
    dbReason = "ready"
    log("database ready -- careers persist in " .. tableName("career"))
    return true
end


-- ------------------------------------------------------------ the worker --
--
-- ONE coroutine owns every database call this file makes, and that is not
-- tidiness. `.await` yields, so two independent `CreateThread`s can interleave
-- mid-transaction -- and the two operations here are a LOAD (replace `stored`
-- with what the table says) and a COMMIT (move a delta out of `session` and
-- into `stored`). Interleave them and a load can overwrite a commit's result
-- with a row read before it landed, or a commit can be double-counted by a load
-- that already includes it. Serialised in one FIFO, every order is correct: a
-- load enqueued first runs first, and a load enqueued after a commit reads a
-- table that already contains it while `session` no longer does.
--
-- Nothing here runs on the tick, and nothing here runs in a damage or death
-- path: `recordMatch` snapshots synchronously and returns, and this drains
-- afterwards. A database that is slow or down cannot hold up the next match.
local jobs = {}
local workerRunning = false
local drain

local function enqueue(job)
    jobs[#jobs + 1] = job
    if workerRunning then return end
    local spawn = nil
    local ok = pcall(function() spawn = CreateThread end)
    if not ok or type(spawn) ~= "function" then return end
    workerRunning = true
    spawn(function()
        local drained, err = pcall(drain)
        workerRunning = false
        if not drained then log("worker raised: " .. tostring(err)) end
        -- A raise leaves work behind. Restart once rather than stalling until
        -- the next match; a second failure will log again and stop.
        if not drained and #jobs > 0 then
            workerRunning = true
            spawn(function()
                local retried, why = pcall(drain)
                workerRunning = false
                if not retried then log("worker raised again, stalling: " .. tostring(why)) end
            end)
        end
    end)
end

local function loadCareer(identifier)
    local record = careerFor(identifier)
    if record.loaded then return end
    if not ensureSchema() then
        -- Degraded: the blank record IS the record. Marked loaded so the same
        -- failed query is not retried once per match for the rest of the run.
        record.loaded = true
        return
    end
    local sql = globalTable("MySQL")
    local ok, rows = pcall(function()
        return sql.query.await(([[
            SELECT mode, matches, wins, top4, kills, assists, damage, revives,
                   cordon_deaths, best_placement, longest_survival_ms
              FROM %s
             WHERE identifier = ?
        ]]):format(tableName("career")), { identifier })
    end)
    if not ok then
        log(("career load failed for %s: %s"):format(identifier, tostring(rows)))
        return
    end
    if type(rows) == "table" then
        for _, row in ipairs(rows) do
            local slot = modeSlot(record, tostring(row.mode or "solo"))
            slot.stored = {
                matches = math.floor(tonumber(row.matches) or 0),
                wins = math.floor(tonumber(row.wins) or 0),
                top4 = math.floor(tonumber(row.top4) or 0),
                kills = math.floor(tonumber(row.kills) or 0),
                assists = math.floor(tonumber(row.assists) or 0),
                damage = math.floor(tonumber(row.damage) or 0),
                revives = math.floor(tonumber(row.revives) or 0),
                cordonDeaths = math.floor(tonumber(row.cordon_deaths) or 0),
                bestPlacement = math.floor(tonumber(row.best_placement) or 0),
                longestSurvivalMs = math.floor(tonumber(row.longest_survival_ms) or 0),
            }
        end
    end

    -- The rating rows, in the same coroutine turn and BEFORE `record.loaded` is
    -- set. That ordering is the whole point: the commit job below calls
    -- `loadCareer` for every participant and only then computes the exchange,
    -- so a rating is never calculated against a baseline the store had not yet
    -- answered for. A rating computed from a default 1000 when the table said
    -- 1400 is not a rounding error -- the delta is then written against the
    -- real value and the player lands somewhere neither number implies.
    local rated, ratingRows = pcall(function()
        return sql.query.await(([[
            SELECT mode, rating, peak, rated_matches
              FROM %s
             WHERE identifier = ?
        ]]):format(tableName("rating")), { identifier })
    end)
    if not rated then
        -- Deliberately NOT marked loaded: the career half landed and the rating
        -- half did not, and rating this player against a default while their
        -- real row exists is the one failure mode worth retrying for.
        log(("rating load failed for %s: %s"):format(identifier, tostring(ratingRows)))
        return
    end
    if type(ratingRows) == "table" then
        for _, row in ipairs(ratingRows) do
            local slot = modeSlot(record, tostring(row.mode or "solo"))
            slot.rating = math.floor(tonumber(row.rating) or 0)
            slot.peak = math.floor(tonumber(row.peak) or slot.rating)
            slot.ratingMatches = math.floor(tonumber(row.rated_matches) or 0)
        end
    end
    record.loaded = true
end


-- ------------------------------------------------------- the rating write --

local function clientEvent(event, target, payload)
    local trigger = nil
    local ok = pcall(function() trigger = TriggerClientEvent end)
    if not ok or type(trigger) ~= "function" then return end
    pcall(trigger, event, target, payload)
end

-- `-1` is every client. Used only for the two ladder TRACE events, which carry
-- no identifier and no name -- see `announceWrite`.
local function broadcast(event, payload)
    clientEvent(event, -1, payload)
end

-- ONE event per rated match, broadcast, carrying no name and no identifier.
-- It is separate from `cordon:ladderWrite` rather than folded into it because
-- the two are decided at different moments: the ladder write is the match's
-- DECISION, taken synchronously at match end, while the exchange below can only
-- be computed once the store has answered for everybody's baseline. A single
-- event would have had to wait for the database to say anything at all.
local function announceRating(record)
    local playerOf = {}
    for _, entry in ipairs(record.entries) do playerOf[entry.identifier] = entry.playerId end
    local rows = {}
    for _, result in ipairs(record.ratingResults) do
        rows[#rows + 1] = {
            id = playerOf[result.key],
            before = result.before, delta = result.delta, after = result.after,
            k = result.k, expected = result.expected, actual = result.actual,
            placement = result.placement, squad = result.squad,
            provisional = result.provisional == true,
        }
    end
    broadcast("cordon:ratingWrite", {
        matchId = record.matchId,
        mode = record.mode,
        model = record.ratingModel,
        storage = storageLine(),
        at = nowMs(),
        rows = rows,
    })
end

--- Is this format rated as squads or as individuals?
---
--- Asked of the DATA rather than of a hardcoded list of names, so a format added
--- to the config rates without an edit here. Config first
--- (`CordonConfig.formats.<mode>.squadSize`), and if the config is silent, the
--- STANDINGS answer: a format in which two keyed contestants share a squad id
--- is a squad format, whatever it is called. The fallback matters because this
--- file must keep working while `shared/config.lua` is somebody else's
--- in-progress edit.
local function isSquadFormat(mode, entries)
    local config = globalTable("CordonConfig")
    local formats = config ~= nil and config.formats or nil
    if type(formats) == "table" then
        local spec = formats[tostring(mode)]
        if type(spec) == "table" then
            local size = tonumber(spec.squadSize or spec.teamSize or spec.size)
            if size ~= nil then return math.floor(size) > 1 end
        end
    end
    local seen = {}
    for _, entry in ipairs(entries or {}) do
        local squad = entry.squad
        if squad ~= nil and squad ~= "" then
            if seen[squad] then return true end
            seen[squad] = true
        end
    end
    return false
end

--- Rate one recorded match. COMPUTED ON THE WORKER, deliberately, and that
--- placement is the whole reason the number can be trusted.
---
--- `recordMatch` is synchronous and returns before any statement is issued, so
--- at that moment a participant's stored rating may not have been read yet --
--- `warm` queues the load at match start, and the load and this share one FIFO
--- but not one instant. So the commit job loads every participant first and
--- calls this afterwards, on the same coroutine, where "loaded" is a fact
--- rather than a hope.
---
--- Computed ONCE per record, guarded by `record.ratingResults`. A transient
--- write failure leaves the match in `pending` and it is retried later; the
--- exchange it carries is what was earned at the time, not a recalculation
--- against a table that has moved since.
local function applyRating(record)
    if record.ratingResults ~= nil then return end
    -- The size gate. Recorded, not rated -- the career rows for a nine-player
    -- match are perfectly good data, and refusing to write them would lose a
    -- match somebody played. It is only the LADDER that a small field cannot
    -- move, because a placement is a statement about a field.
    if not record.rateable then
        record.ratingNote = record.ratingNote
            or ("field of %d human(s), %d keyable, is below ratedMinPlayers")
                :format(record.humans or 0, record.keyed or 0)
        return
    end
    local module = ratingModule()
    if module == nil then return end
    local settings = ratingSettings(record.mode)
    if settings == nil or not settings.enabled then return end

    local squadded = isSquadFormat(record.mode, record.entries)
    local deltas, results, note

    if squadded then
        -- Group the keyed entries by squad. The squad's placement is the BEST
        -- (smallest) placement any of its members holds: a squad is eliminated
        -- as a unit and the standings say so, but a member who disconnected
        -- earlier carries an earlier elimination, and rating the squad on its
        -- worst member's placement would punish the survivors for the leaver.
        local order, bySquad = {}, {}
        for _, entry in ipairs(record.entries) do
            local slot = modeSlot(careerFor(entry.identifier), record.mode)
            local key = entry.squad
            if key == nil or key == "" then key = "solo:" .. entry.identifier end
            local squad = bySquad[key]
            if squad == nil then
                squad = { id = key, members = {}, placement = entry.placement }
                bySquad[key] = squad
                order[#order + 1] = squad
            end
            if entry.placement > 0
                and (squad.placement <= 0 or entry.placement < squad.placement) then
                squad.placement = entry.placement
            end
            squad.members[#squad.members + 1] = {
                key = entry.identifier,
                rating = ratingValue(slot, settings),
                matches = slot.ratingMatches or 0,
            }
        end
        local ok, a, b, c = pcall(module.squadPlacement, order,
            { settings = settings, format = record.mode })
        if not ok then
            log("rating model raised: " .. tostring(a))
            return
        end
        deltas, results, note = a, b, c
        record.ratingModel = "squadPlacement"
    else
        local participants = {}
        for _, entry in ipairs(record.entries) do
            local slot = modeSlot(careerFor(entry.identifier), record.mode)
            participants[#participants + 1] = {
                key = entry.identifier,
                rating = ratingValue(slot, settings),
                matches = slot.ratingMatches or 0,
                placement = entry.placement,
            }
        end
        local ok, a, b, c = pcall(module.placement, participants,
            { settings = settings, format = record.mode })
        if not ok then
            log("rating model raised: " .. tostring(a))
            return
        end
        deltas, results, note = a, b, c
        record.ratingModel = "placement"
    end

    if deltas == nil or results == nil then
        record.ratingNote = tostring(note or "not rated")
        record.ratingModel = nil
        return
    end
    if note ~= nil then log(("match %d rating: %s"):format(record.matchId, note)) end

    record.ratingResults = results
    -- Carried on the record rather than re-read at write time: the panel can
    -- move the floor between the exchange and the statement, and the two must
    -- not then disagree about where a player landed.
    record.ratingFloor = settings.floor
    -- The card a player reads must be right NOW, from the same numbers, exactly
    -- as the career already is. `settle` moves this into `rating` once the
    -- statement has landed -- or once there turns out to be nowhere to land.
    for _, result in ipairs(results) do
        local slot = modeSlot(careerFor(result.key), record.mode)
        slot.ratingPending = (slot.ratingPending or 0) + result.delta
    end
    announceRating(record)
end


-- ------------------------------------------------------------ the statements --

local function statementsFor(record)
    local statements = {}
    local careerTable = tableName("career")
    local matchesTable = tableName("matches")
    local recordMatches = setting("recordMatches") ~= false

    for _, entry in ipairs(record.entries) do
        -- THE UPSERT IS A DELTA, NEVER A TOTAL. Two servers sharing one
        -- database, or a row corrected by hand, must not be silently
        -- overwritten by whatever this VM happened to have cached.
        --
        -- `best_placement` is the one column that is neither a sum nor a plain
        -- maximum. 0 is the "no data" sentinel on BOTH sides -- the stored row
        -- of a player who has never had a placement recorded, and the incoming
        -- value for a match that produced none -- so the nested IF() is the
        -- minimum with both sentinels excluded. `LEAST(best_placement, 0)`
        -- would freeze the column at 0 forever the first time either side was
        -- unknown, and it would read as "won every match".
        statements[#statements + 1] = {
            query = ([[
                INSERT INTO %s
                    (identifier, mode, matches, wins, top4, kills, assists, damage,
                     revives, cordon_deaths, best_placement, longest_survival_ms,
                     last_played)
                VALUES (@id, @mode, 1, @wins, @top4, @kills, @assists, @damage,
                        @revives, @cordonDeaths, @placement, @survived,
                        CURRENT_TIMESTAMP)
                ON DUPLICATE KEY UPDATE
                    matches             = matches + 1,
                    wins                = wins + VALUES(wins),
                    top4                = top4 + VALUES(top4),
                    kills               = kills + VALUES(kills),
                    assists             = assists + VALUES(assists),
                    damage              = damage + VALUES(damage),
                    revives             = revives + VALUES(revives),
                    cordon_deaths       = cordon_deaths + VALUES(cordon_deaths),
                    best_placement      = IF(VALUES(best_placement) = 0, best_placement,
                                          IF(best_placement = 0, VALUES(best_placement),
                                             LEAST(best_placement, VALUES(best_placement)))),
                    longest_survival_ms = GREATEST(longest_survival_ms,
                                                   VALUES(longest_survival_ms)),
                    last_played         = CURRENT_TIMESTAMP
            ]]):format(careerTable),
            values = {
                id = entry.identifier, mode = record.mode,
                wins = entry.wins, top4 = entry.top4,
                kills = entry.kills, assists = entry.assists, damage = entry.damage,
                revives = entry.revives, cordonDeaths = entry.cordonDeaths,
                placement = entry.bestPlacement,
                survived = entry.longestSurvivalMs,
            },
        }

        if recordMatches then
            statements[#statements + 1] = {
                query = ([[
                    INSERT INTO %s
                        (match_id, identifier, mode, placement, squad, kills,
                         survived_ms, bots_present)
                    VALUES (@match, @id, @mode, @placement, @squad, @kills,
                            @survived, @bots)
                ]]):format(matchesTable),
                values = {
                    match = record.matchId, id = entry.identifier, mode = record.mode,
                    placement = entry.placement,
                    -- NEVER nil. A nil named parameter is an ABSENT key in a Lua
                    -- values table, so it never reaches the binder and the
                    -- driver rejects the whole statement for an undefined
                    -- `@squad` -- which loses the row for a solo match rather
                    -- than storing "no squad". The column is NOT NULL DEFAULT ''
                    -- for the same reason.
                    squad = entry.squad or "",
                    kills = entry.kills, survived = entry.survivedMs,
                    -- The gate's assertion. See the schema comment: this is what
                    -- was OBSERVED, so a non-zero value here is proof the taint
                    -- leaked rather than a value the code can only write as 0.
                    bots = record.botsSeen or 0,
                },
            }
        end
    end

    -- The rating, written as a DELTA for the same reason every career column
    -- is. `GREATEST(@floor, ...)` puts the floor in SQL as well as in the model,
    -- so the table cannot end up holding a value the model would never produce.
    --
    -- NOTE THE ORDER OF THE TWO ASSIGNMENTS. MySQL evaluates the assignments of
    -- ON DUPLICATE KEY UPDATE left to right and a later one sees the values the
    -- earlier ones wrote, so `peak` is assigned FIRST -- while `rating` on its
    -- right-hand side is still the row's OLD value -- and computes the same
    -- expression `rating` is about to be given. Swapping the two lines would
    -- silently double the delta into the peak.
    for _, result in ipairs(record.ratingResults or {}) do
        statements[#statements + 1] = {
            query = ([[
                INSERT INTO %s
                    (identifier, mode, rating, peak, rated_matches, last_delta, updated_at)
                VALUES (@id, @mode, @after, @after, 1, @delta, CURRENT_TIMESTAMP)
                ON DUPLICATE KEY UPDATE
                    peak          = GREATEST(peak, GREATEST(@floor, rating + @delta)),
                    rating        = GREATEST(@floor, rating + @delta),
                    rated_matches = rated_matches + 1,
                    last_delta    = @delta,
                    updated_at    = CURRENT_TIMESTAMP
            ]]):format(tableName("rating")),
            values = {
                id = result.key, mode = record.mode,
                after = result.after, delta = result.delta,
                floor = record.ratingFloor or 0,
            },
        }
    end
    return statements
end

--- Move one match's delta out of `session` and into `stored`. Called once the
--- durable store has it, and once when there is no durable store to have it --
--- in the degraded case `stored` is simply where the volatile total lives.
local function settle(record)
    for _, entry in ipairs(record.entries) do
        local slot = modeSlot(careerFor(entry.identifier), record.mode)
        for _, field in ipairs(SUM_FIELDS) do
            slot.session[field] = math.max(0,
                (slot.session[field] or 0) - math.floor(tonumber(entry[field]) or 0))
        end
        addTotals(slot.stored, entry)
        -- The extrema cannot be decremented out of `session`; they are simply
        -- dropped, because `stored` now holds them and `combine` takes the
        -- max/min of the two.
        slot.session.longestSurvivalMs = 0
        slot.session.bestPlacement = 0
    end

    -- The rating settles the same way and for the same reason, as a DELTA
    -- rather than an assignment. `result.after` was computed against the
    -- baseline plus whatever was already pending, and the worker's FIFO
    -- guarantees earlier matches settle first -- so adding the delta and
    -- assigning `after` agree, and the delta form is the one that stays correct
    -- if they ever stop agreeing.
    for _, result in ipairs(record.ratingResults or {}) do
        local slot = modeSlot(careerFor(result.key), record.mode)
        local floor = record.ratingFloor or 0
        -- `slot.rating` is nil until something has settled into it, and when it
        -- is nil THIS is that something: the worker's FIFO settles matches in
        -- the order they were recorded, so an earlier match for the same
        -- identity and format has already been through here and left a value
        -- behind. A nil therefore means no earlier match is outstanding, which
        -- makes `result.before` -- the baseline the exchange was computed
        -- against -- exactly the right base.
        --
        -- Do NOT subtract `ratingPending` from `result.before` to "undo" the
        -- optimistic display: `applyRating` has ALREADY added this match's own
        -- delta to `ratingPending`, so the subtraction removes the very delta
        -- about to be added and every first-ever rated match settles back to
        -- the baseline. That bug shipped once in the deathmatch and read as a
        -- card saying "last +32" over a rating of 1000.
        local before = slot.rating
        if before == nil then before = result.before end
        local after = before + result.delta
        if after < floor then after = floor end
        slot.rating = after
        slot.peak = math.max(slot.peak or after, after)
        slot.ratingMatches = (slot.ratingMatches or 0) + 1
        slot.lastDelta = result.delta
        slot.ratingPending = (slot.ratingPending or 0) - result.delta
    end
end

local function commit(record)
    if not ensureSchema() then return false, "degraded" end
    local sql = globalTable("MySQL")
    local statements = statementsFor(record)
    local chunk = math.max(1, math.min(64, math.floor(tonumber(setting("statementChunk")) or 48)))
    local index = 1
    while index <= #statements do
        local slice = {}
        for offset = index, math.min(index + chunk - 1, #statements) do
            slice[#slice + 1] = statements[offset]
        end
        -- `transaction.await` resolves a failure to `false, reason` instead of
        -- raising (oxmysql parity), so BOTH have to be tested: the pcall for a
        -- bridge-level refusal, and the return for a rollback.
        local ok, committed, reason = pcall(function()
            return sql.transaction.await(slice)
        end)
        if not ok then return false, tostring(committed) end
        if committed ~= true then return false, tostring(reason or "rolled_back") end
        index = index + chunk
    end
    return true
end

drain = function()
    while #jobs > 0 do
        local job = table.remove(jobs, 1)
        if job.kind == "load" then
            loadCareer(job.identifier)
        elseif job.kind == "commit" then
            local record = job.record
            -- LOAD, THEN RATE, THEN WRITE, in that order and on this one
            -- coroutine. `loadCareer` is idempotent and returns immediately for
            -- anybody already loaded, so this costs nothing in the ordinary
            -- case -- and in the case that matters (a player whose warm-up load
            -- has not come back yet) it is the difference between an exchange
            -- computed against the real baseline and one computed against 1000.
            for _, entry in ipairs(record.entries) do loadCareer(entry.identifier) end
            applyRating(record)
            local ok, reason = commit(record)
            if ok then
                settle(record)
                log(("wrote match %s (%s) -- %d player(s)%s"):format(
                    tostring(record.matchId), record.mode, #record.entries,
                    record.ratingResults ~= nil and ", rated" or ", not rated"))
            elseif reason == "degraded" then
                -- No durable store this run. The write still HAPPENED, into the
                -- volatile table, and the readout says which store answered.
                settle(record)
            else
                -- A TRANSIENT FAILURE LEAVES THE MATCH IN `pending`, untouched
                -- and still first, and stops the drain. It is retried when the
                -- next match is recorded or when the resource next starts.
                -- Spinning here would hammer a database that is already
                -- unhappy, and dropping it would lose twenty minutes somebody
                -- played.
                log(("write failed for match %s (%s) -- kept, retried at the next match")
                    :format(tostring(record.matchId), tostring(reason)))
                carry()
                return
            end
            for index = #pending, 1, -1 do
                if pending[index] == record then table.remove(pending, index) end
            end
            carry()
        end
    end
end


-- ------------------------------------------------------------ the write --

local function announceWrite(record)
    -- ONE event per match, broadcast, carrying no name and no identifier.
    --
    -- The exclusion is at the WRITE and never at the read, and a rule that
    -- leaves no trace is a rule nobody can check. This is the trace: every
    -- ladder write this mode performs is announced, so "a bot-filled match
    -- produced none" is an observation rather than an article of faith -- and
    -- an all-human control match proves the announcement is not simply never
    -- wired.
    --
    -- The payload is the MATCH, not the career: participant ids and the numbers
    -- from the standings the players just read. The career KEY -- the
    -- master-backed identifier -- is deliberately not in it, because this
    -- crosses the wire to clients.
    local rows = {}
    for _, entry in ipairs(record.entries) do
        rows[#rows + 1] = {
            id = entry.playerId,
            placement = entry.placement, squad = entry.squad,
            kills = entry.kills, assists = entry.assists, damage = entry.damage,
            revives = entry.revives, cordonDeaths = entry.cordonDeaths,
            survivedMs = entry.survivedMs,
            won = entry.wins > 0,
            identified = entry.identifier ~= nil,
        }
    end
    broadcast("cordon:ladderWrite", {
        matchId = record.matchId,
        mode = record.mode,
        reason = record.reason,
        at = record.at,
        storage = storageLine(),
        ranked = true,
        rated = record.rateable,
        humans = record.humans,
        rows = rows,
    })
end

-- ------------------------------------------------- the match-table adapter --
--
-- `server/match.lua` resolves a match by calling `K.ranked.recordMatch(current)`
-- -- the live match TABLE, not an id and a standings array. This turns one into
-- the other, and it is a separate function rather than inline in `recordMatch`
-- so the explicit `(matchId, opts)` form stays the documented contract and
-- stays unit-testable without a kernel.
--
-- The roster is the source of the standings because that is where the numbers
-- live: `Cordon.players[id]` carries kills, assists, damage, revives and the
-- placement that `M.eliminate` wrote. A participant is IN this match when they
-- hold a squad, which is what `M.toStaging` clears between matches.
local function standingsFromMatch(match)
    local root = globalTable("Cordon")
    if root == nil or type(match) ~= "table" then return nil end
    local players = type(root.players) == "table" and root.players or nil
    if players == nil then return nil end
    local squads = type(match.squads) == "table" and match.squads or {}
    local startedAt = tonumber(match.startedAtMs)
    local ending = nowMs()

    local rows = {}
    for id, record in pairs(players) do
        if type(record) == "table" and record.squad ~= nil then
            -- Placement, in the order the mode actually knows it. A member's
            -- own placement is written when they are eliminated; a squad's is
            -- written when it is wiped; and the WINNING squad's members have
            -- neither, because nobody eliminated them -- `M.checkEnd` sets
            -- `winner.placement = 1` on the squad alone. Missing all three
            -- leaves 0, which the career treats as "no placement" and the
            -- rating model drops rather than guessing at.
            local squad = squads[record.squad]
            local placement = tonumber(record.placement)
            if placement == nil and type(squad) == "table" then
                placement = tonumber(squad.placement)
            end
            if placement == nil and match.winner ~= nil and record.squad == match.winner then
                placement = 1
            end

            -- Survival is measured from the match start, not from the drop, so
            -- it is comparable across matches whose staging ran long. A player
            -- still alive at the end survived the whole match.
            local survived = 0
            if startedAt ~= nil then
                local finishedAt = tonumber(record.deathAtMs) or ending
                survived = math.max(0, math.floor(finishedAt - startedAt))
            end

            rows[#rows + 1] = {
                id = id,
                placement = placement or 0,
                squad = record.squad,
                kills = record.kills,
                assists = record.assists,
                damage = record.damage,
                revives = record.revives,
                -- Not in the kernel record today. Read anyway rather than
                -- hardcoded to 0, so the column starts counting the day
                -- `server/cordon.lua` begins tagging its own kills, with no
                -- edit here and no gap in the career.
                cordonDeaths = record.cordonDeaths,
                survivedMs = survived,
            }
        end
    end
    return rows
end

--- Record one finished match. THE ONE ENTRY POINT, called by `server/match.lua`
--- when a match resolves.
---
--- Two call forms, and the table form is what `match.lua` uses:
---
---   `recordMatch(match)`            the live match table from `Cordon.match.current()`
---   `recordMatch(matchId, opts)`    explicit, and the one the tests use
---
--- `matchId` is the kernel's match id. `opts` carries:
---   mode        the FORMAT -- "solo", "duo", "squad". Defaults to "solo".
---   reason      why the match ended, for the announcement only
---   standings   array of rows, one per participant:
---               `{ id, placement, squad, kills, assists, damage, revives,
---                  cordonDeaths, survivedMs }`
---               If absent, `Cordon.scoring.rows(matchId)` is asked instead.
---
--- Returns `written (boolean), reason`. `false, "bots"` is the gate path and is
--- the reason the caller writes into the result card.
---
--- Everything here is SYNCHRONOUS and cheap: it walks the standings the match
--- has already computed and hands the result to the worker. No statement is
--- issued on this call stack.
function Ranked.recordMatch(matchId, opts)
    opts = type(opts) == "table" and opts or {}
    if not enabled() then return false, "disabled" end

    if type(matchId) == "table" then
        local match = matchId
        opts.mode = opts.mode or match.format
        opts.reason = opts.reason or match.reason
        opts.standings = opts.standings or standingsFromMatch(match)
        -- `id` is the match's identity and `number` is the per-server counter.
        -- Either keys a row; neither may be nil, because `finite(nil)` refuses
        -- below and a match with no id is a match the gate cannot be asked
        -- about -- which is exactly the case that must not be written.
        --
        -- BUT `match.id` IS A STRING, and this line used to hand it straight to
        -- `finite()`. `server/match.lua:396` builds it as `("m%d:%d"):format(
        -- startedMs, number)` -- "m1286139:2" -- and `finite` is `tonumber`,
        -- which answers nil on that. So `id == nil`, `recordMatch` returned
        -- `false, "no_match"`, and the caller's `pcall` discarded the reason.
        -- Every rated match this mode has ever played wrote nothing, and said
        -- nothing about it. Measured 2026-09-03: a 21-player rated match
        -- resolved with all four open77_br_* tables still empty.
        --
        -- The string carries two integers, so take them rather than inventing a
        -- key: startedMs shifted left of the per-match counter. This is NOT
        -- collision-proof across restarts and cannot be -- the sandbox has no
        -- wall clock, only `Open77.time.monotonic()`, which resets with the
        -- process -- so two runs can in principle mint the same key and merge
        -- one match's rows into another's. The same weakness is already in the
        -- id itself; keying off it does not add risk, and the honest fix is a
        -- database-side identity, which is a schema change and not this one.
        local numeric = finite(match.id)
        if numeric == nil and type(match.id) == "string" then
            local startedMs, number = match.id:match("^m(%d+):(%d+)$")
            if startedMs ~= nil then
                numeric = (tonumber(startedMs) * 100000) + tonumber(number)
            end
        end
        matchId = numeric ~= nil and numeric or match.number
    end

    local id = finite(matchId)
    if id == nil then return false, "no_match" end
    id = math.floor(id)

    -- ================================================================
    -- THE GATE. FIRST, BEFORE ANYTHING IS EVEN READ.
    -- ================================================================
    -- Not a flag on a row, not a column, not a filter for a later query to
    -- remember: a match containing a bot produces no snapshot, no queue entry,
    -- no announcement, no statement -- and `rating.lua` is never called at all.
    -- There is nothing left behind to forget about.
    --
    -- Consulted ONCE, here, and never again for this match. Asking twice would
    -- open the door to the two answers differing (the taint is sticky, but the
    -- bot module's half is somebody else's code) and a write that is half
    -- refused is worse than either outcome.
    if Ranked.ladderEligible(id) ~= true then
        log(("match %d not written -- %s"):format(id, tostring(Ranked.taintReason(id) or "bots")))
        return false, "bots"
    end

    local mode = tostring(opts.mode or opts.format or "solo")

    local rows = opts.standings
    if type(rows) ~= "table" then
        local root = globalTable("Cordon")
        local scoring = root ~= nil and root.scoring or nil
        if type(scoring) ~= "table" or type(scoring.rows) ~= "function" then
            return false, "no_standings"
        end
        local ok, produced = pcall(scoring.rows, matchId)
        if not ok or type(produced) ~= "table" then return false, "no_standings" end
        rows = produced
    end

    local record = {
        matchId = id,
        mode = mode,
        reason = tostring(opts.reason or "resolved"),
        at = nowMs(),
        entries = {},
        humans = 0,
        -- Humans the ladder can actually KEY. Tracked apart from `humans`
        -- because the rating normalises by the size of the field it rates, and
        -- that field is the keyed one -- see the size gate below.
        keyed = 0,
        -- Counted, not assumed. The gate above should have refused already, so
        -- this stays 0 -- and if it ever does not, the `bots_present` column
        -- carries the proof into the database rather than the mode discovering
        -- it a season later.
        botsSeen = 0,
    }

    for _, row in ipairs(rows) do
        -- HUMANS ONLY, and the guard is `> 0` rather than `not row.bot`: a bot
        -- is a participant with a negative id, and the id is the thing that
        -- must never reach `Open77.players.identifier`.
        local playerId = positiveId(type(row) == "table" and row.id or nil)
        if playerId == nil then
            record.botsSeen = record.botsSeen + 1
        else
            record.humans = record.humans + 1
            local placement = math.max(0, math.floor(tonumber(row.placement) or 0))
            local squad = row.squad
            if squad ~= nil then
                squad = tostring(squad)
                if #squad > 32 then squad = squad:sub(1, 32) end
            end
            local survived = math.max(0, math.floor(tonumber(row.survivedMs) or 0))
            local identifier = identities[playerId] or rememberIdentity(playerId)
            if identifier ~= nil then record.keyed = record.keyed + 1 end
            record.entries[#record.entries + 1] = {
                playerId = playerId,
                -- Captured at connect and at match start, because
                -- `Open77.players.identifier` answers nil for a player who has
                -- already gone -- and decision 10 makes a disconnect an
                -- elimination, so a leaver has a placement that everybody
                -- else's rating depends on.
                identifier = identifier,
                placement = placement,
                squad = squad,
                -- The career delta for this one match.
                matches = 1,
                wins = placement == 1 and 1 or 0,
                -- Top 4 is the mode's own shorthand for "made the last squads",
                -- and it is a placement bracket in every format: in solo it is
                -- the last four players, in squad the last four squads, because
                -- `placement` is already the squad's placement there.
                top4 = (placement >= 1 and placement <= 4) and 1 or 0,
                kills = math.max(0, math.floor(tonumber(row.kills) or 0)),
                assists = math.max(0, math.floor(tonumber(row.assists) or 0)),
                damage = math.max(0, math.floor(tonumber(row.damage) or 0)),
                revives = math.max(0, math.floor(tonumber(row.revives) or 0)),
                cordonDeaths = math.max(0, math.floor(tonumber(row.cordonDeaths) or 0)),
                survivedMs = survived,
                -- The two extrema, phrased as this match's contribution.
                bestPlacement = placement,
                longestSurvivalMs = survived,
            }
        end
    end

    if #record.entries == 0 then
        return false, "no_players"
    end

    -- THE SIZE GATE IS NOT THE BOT GATE, and the difference is deliberate. A
    -- small match is RECORDED and not RATED: the career rows are perfectly good
    -- data and refusing them would lose a match somebody played, while the
    -- ladder cannot be moved by a field too small for a placement to mean
    -- anything (plan section 11: `ratedMinPlayers`, 16).
    --
    -- BOTH counts have to clear the minimum, and the second is the one that is
    -- easy to forget. The rating normalises by the size of the field it rates,
    -- and that field is the KEYED one: a 64-human match in which only three
    -- players have a master-backed identity is rated as a three-way contest,
    -- normalised by 2 instead of 63, and the winner of those three collects the
    -- exchange of somebody who beat a whole lobby. Gating on `humans` alone
    -- would let exactly that through on a server whose master is unreachable.
    local minimum = math.max(2, math.floor(tonumber(setting("ratedMinPlayers")) or 16))
    record.rateable = record.humans >= minimum and record.keyed >= minimum
    if not record.rateable then
        log(("match %d recorded but NOT rated -- %d human(s), %d keyable, ratedMinPlayers is %d")
            :format(id, record.humans, record.keyed, minimum))
    end

    -- The announcement is the match's, and it goes out whether or not any of
    -- those players could be keyed -- an eligible match that nothing could be
    -- attributed to is still a match the ladder saw, and saying so is what
    -- separates "no identity" from "not wired".
    announceWrite(record)

    -- The career the player can read updates NOW, from the same numbers. The
    -- durable copy follows on the worker.
    local keyed = {}
    for _, entry in ipairs(record.entries) do
        if entry.identifier ~= nil then
            local slot = modeSlot(careerFor(entry.identifier), mode)
            addTotals(slot.session, entry)
            keyed[#keyed + 1] = entry
        end
    end

    if #keyed == 0 then
        log(("match %d (%s) eligible but no player could be identified -- nothing to key a career on")
            :format(id, mode))
        return true, "unidentified"
    end

    record.entries = keyed
    pending[#pending + 1] = record
    local ceiling = math.floor(tonumber(setting("maxPendingMatches")) or 64)
    while #pending > ceiling do
        table.remove(pending, 1)
        log("pending write queue overflowed -- oldest match dropped")
    end
    carry()
    enqueue({ kind = "commit", record = record })
    return true, "queued"
end

--- Called by `server/match.lua` at match start. Two jobs: capture every present
--- player's identity WHILE THEY ARE CERTAINLY PRESENT, and warm the career
--- cache so a match end is a computation rather than a round trip.
---
--- `roster` is an array of participant ids; bots in it are harmless because
--- `warm` refuses a non-positive id before touching any binding. If it is
--- absent, `Cordon.roster(matchId)` is asked.
function Ranked.onMatchStart(matchId, roster)
    if not enabled() then return end
    if type(roster) ~= "table" then
        local root = globalTable("Cordon")
        if root == nil then return end
        -- `Cordon.humans()` is the kernel's own humans-only view and returns
        -- records, not ids. It is preferred over the roster table for exactly
        -- the reason the kernel keeps it separate: bot ids are NEGATIVE, and
        -- the identity binding this function exists to call raises on one.
        -- `positiveId` below would catch that anyway; asking for humans means
        -- it never has to.
        local source = type(root.humans) == "function" and root.humans or root.roster
        if type(source) ~= "function" then return end
        local ok, produced = pcall(source, matchId)
        if not ok or type(produced) ~= "table" then return end
        roster = produced
    end
    for _, participant in ipairs(roster) do
        local id = positiveId(type(participant) == "table" and participant.id or participant)
        if id ~= nil then
            Ranked.warm(id)
            Ranked.greet(id)
        end
    end
end

--- Capture identity and queue a load. Idempotent and safe for a bot id.
function Ranked.warm(playerId)
    if not enabled() then return nil end
    local identifier = rememberIdentity(playerId)
    if identifier == nil then return nil end
    local record = careerFor(identifier)
    if record.loaded or record.requested then return identifier end
    record.requested = true
    enqueue({ kind = "load", identifier = identifier })
    return identifier
end


-- ------------------------------------------------------------- the readout --

local function totalsFor(identifier)
    local record = careers[identifier]
    local perMode, ratings = {}, {}
    if record == nil then return perMode, false, ratings end
    for mode, slot in pairs(record.modes) do
        local totals = combine(slot.stored, slot.session)
        local settings = ratingSettings(mode)
        -- A format is shown when it has a career OR a rating. The two can come
        -- apart in both directions -- a rating adopted across a reload with no
        -- matches behind it in this VM, and a match recorded on a server that
        -- has rating switched off -- and hiding either half would make the card
        -- disagree with the table.
        local rated = slot.rating ~= nil or (slot.ratingMatches or 0) > 0
            or (slot.ratingPending or 0) ~= 0
        if totals.matches > 0 or rated then
            perMode[mode] = totals
            ratings[mode] = {
                rating = settings ~= nil and ratingValue(slot, settings) or slot.rating,
                matches = slot.ratingMatches or 0,
                peak = slot.peak,
                lastDelta = slot.lastDelta or 0,
                established = slot.rating ~= nil,
                provisional = settings ~= nil
                    and (slot.ratingMatches or 0) < (settings.provisionalMatches or 0),
            }
        end
    end
    -- DELIBERATELY NO OVERALL TOTALS ROW. Section 11 and `rating.lua`'s header:
    -- solo, duo and squad are different measurements. Summing the careers would
    -- be defensible for kills and indefensible for wins, best placement and win
    -- rate -- a 1-in-16 squad win and a 1-in-64 solo win are not the same event
    -- and adding them produces a win rate that describes neither.
    return perMode, record.loaded, ratings
end

--- The career of one player, or nil. Published so the HUD or another file can
--- read it without knowing the storage.
function Ranked.careerOf(playerId)
    local id = positiveId(playerId)
    local identifier = (id ~= nil and identities[id]) or identifierOf(playerId)
    if identifier == nil then return nil end
    local perMode, loaded, ratings = totalsFor(identifier)
    return { modes = perMode, loaded = loaded, ratings = ratings, storage = storageLine() }
end

local function formatDuration(ms)
    local seconds = math.max(0, math.floor((tonumber(ms) or 0) / 1000))
    return ("%d:%02d"):format(math.floor(seconds / 60), seconds % 60)
end

local function report(say, playerId, identifier)
    local perMode, loaded, ratings = totalsFor(identifier)
    local name = playerId ~= nil and playerName(playerId) or "?"
    local module = ratingModule()

    say(("career %s -- storage: %s%s"):format(
        name, storageLine(), loaded and "" or "  (not loaded yet)"))

    local modes = {}
    for mode in pairs(perMode) do modes[#modes + 1] = mode end
    table.sort(modes)

    if #modes == 0 then
        -- The baseline is said even here -- ESPECIALLY here. This is the card a
        -- player reads before their first match, and "you start at 1000" is the
        -- one thing it can honestly tell them.
        if module ~= nil and type(module.describe) == "function" then
            local ok, line = pcall(module.describe, ratingSettings())
            if ok and type(line) == "string" then say("  rating -- " .. line) end
        end
        return say("  no matches recorded yet")
    end

    -- PER FORMAT, AND THERE IS NO OVERALL LINE, deliberately -- see `totalsFor`.
    for _, mode in ipairs(modes) do
        local totals = perMode[mode]
        local rated = ratings[mode]
        -- `*` is "provisional" -- still inside the placement window, where K is
        -- scaled up and the number is a guess rather than evidence. `?` is a
        -- format with no rated match at all, so what is shown is the baseline
        -- and not a measurement. Saying so is cheap; a player reading 1000 and
        -- believing it was earned is not.
        local elo, mark = "     ", " "
        if rated ~= nil and rated.rating ~= nil then
            elo = ("%5d"):format(rated.rating)
            if rated.matches <= 0 then mark = "?"
            elseif rated.provisional then mark = "*" end
        end
        say(("  %-5s elo %s%s  matches %-5d wins %-4d top4 %-4d kills %-5d assists %-4d")
            :format(mode, elo, mark, totals.matches, totals.wins, totals.top4,
                totals.kills, totals.assists))
        say(("        best placement %s  longest survival %s  damage %d  revives %d  cordon deaths %d")
            :format(totals.bestPlacement > 0 and tostring(totals.bestPlacement) or "-",
                formatDuration(totals.longestSurvivalMs), totals.damage,
                totals.revives, totals.cordonDeaths))
        if rated ~= nil and rated.matches > 0 then
            say(("        rated matches %d  peak %d  last %+d%s"):format(
                rated.matches, rated.peak or rated.rating, rated.lastDelta,
                rated.provisional
                    and "  (provisional: K is scaled up until the placement window closes)"
                    or ""))
        end
    end

    -- The parameters are printed rather than hidden, because a rating whose
    -- baseline and K nobody can see is a magic number with a database behind it.
    if module ~= nil and type(module.describe) == "function" then
        local ok, line = pcall(module.describe, ratingSettings(modes[1]))
        if ok and type(line) == "string" then say("  rating -- " .. line) end
    end
    say(("  matches below %d humans are recorded but not rated")
        :format(math.max(2, math.floor(tonumber(setting("ratedMinPlayers")) or 16))))

    local queued = 0
    for _, record in ipairs(pending) do
        for _, entry in ipairs(record.entries) do
            if entry.identifier == identifier then queued = queued + 1 end
        end
    end
    if queued > 0 then
        say(("  %d match(es) recorded and not yet written -- the numbers above already include them")
            :format(queued))
    end
end

local function sayer(source, raw)
    return function(text)
        print(text)
        local id = positiveId(source)
        if id ~= nil then
            local trigger = nil
            local ok = pcall(function() trigger = TriggerClientEvent end)
            if ok and type(trigger) == "function" then
                pcall(trigger, "open77:command:result", id, raw or "", true, text)
            end
        end
    end
end

local function registerCommand(name, handler, restricted)
    local register = nil
    local ok = pcall(function() register = RegisterCommand end)
    if not ok or type(register) ~= "function" then return end
    register(name, handler, restricted)
end

--- `/br.stats` -- your own career. UNRESTRICTED: reading your own record is the
--- feature, not an operator verb.
---
--- The `<id>` form is deliberately NOT here. `RegisterCommand`'s third argument
--- is the whole ACL gate and it is per-COMMAND, not per-invocation -- there is
--- no binding that lets an unrestricted handler ask whether its caller is
--- privileged. Registering one command that takes an id would therefore either
--- expose everybody's card to everybody, or hide everybody's from themselves.
--- So the mode ships a PAIR, and `/br.stats.of <id>` below is the restricted
--- half. The server console is privileged by definition and gets the id form
--- here as well, so an operator at the console never needs the pair.
registerCommand("br.stats", function(source, args, raw)
    local say = sayer(source, raw)
    if not enabled() then return say("career stats are disabled in this server's config") end

    local wanted = finite(args and args[1])
    local caller = positiveId(source)

    if wanted ~= nil and caller == nil then
        -- Console. Privileged by definition.
        local target = positiveId(wanted)
        if target == nil then return say("br.stats -- give a positive player id") end
        local identifier = Ranked.warm(target)
        if identifier == nil then
            return say(("career player=%d -- no identity (not connected, or this server has no master-backed identity for them)")
                :format(target))
        end
        return report(say, target, identifier)
    end
    if wanted ~= nil then
        return say("br.stats reads your own career. /br.stats.of <id> reads somebody else's and is ACL-gated.")
    end

    if caller == nil then
        say("usage: br.stats                 -- your own career, in game")
        say("       br.stats <playerId>      -- from the server console")
        return say("       br.stats.of <playerId>   -- in game, ACL-gated")
    end
    local identifier = Ranked.warm(caller)
    if identifier == nil then
        return say("career -- this server has no master-backed identity for you, so nothing is being recorded. "
            .. storageLine())
    end
    report(say, caller, identifier)
end, false)

--- The restricted half of the pair. ACL-gated by `RegisterCommand`'s third
--- argument, which is the whole gate.
registerCommand("br.stats.of", function(source, args, raw)
    local say = sayer(source, raw)
    if not enabled() then return say("career stats are disabled in this server's config") end
    local target = positiveId(finite(args and args[1]))
    if target == nil then return say("usage: br.stats.of <playerId>") end
    local identifier = Ranked.warm(target)
    if identifier == nil then
        return say(("career player=%d -- no identity for that id"):format(target))
    end
    report(say, target, identifier)
end, true)


-- ---------------------------------------------------------------- lifecycle --

--- One career line per session, never a nag, and never after a Lua save.
function Ranked.greet(playerId)
    if not enabled() or setting("announceOnJoin") == false then return false end
    local id = positiveId(playerId)
    if id == nil or announced[id] then return false end
    if not connected[id] then
        -- A RELOAD SURVIVOR. `announced` died with the outgoing VM and
        -- `connected` is empty for exactly the same reason; the two absences
        -- cancel. Mark them greeted and stay silent -- a Lua save must not put
        -- a career card in front of somebody who is mid-drop.
        announced[id] = true
        return false
    end
    announced[id] = true
    local identifier = identities[id]
    if identifier == nil then return false end
    local perMode = totalsFor(identifier)
    local matches, wins = 0, 0
    for _, totals in pairs(perMode) do
        matches = matches + totals.matches
        wins = wins + totals.wins
    end
    if matches <= 0 then return false end
    -- SENT TO THAT PLAYER ONLY, not broadcast. The two ladder trace events are
    -- broadcast because they carry no identity; a career card is one person's
    -- record and there is no reason for the other sixty-three clients in the
    -- lobby to receive it.
    --
    -- Counts, not a rate: a win rate summed across formats would be the number
    -- `totalsFor` refuses to compute, for the reason written there.
    clientEvent("cordon:careerWelcome", id, { matches = matches, wins = wins })
    return true
end

local function onConnected(playerIdStr)
    local id = positiveId(playerIdStr)
    if id == nil then return end
    connected[id] = true
    Ranked.warm(id)
end

local function onDisconnected(playerIdStr)
    local id = positiveId(playerIdStr)
    if id == nil then return end
    connected[id] = nil
    announced[id] = nil
    -- The identity snapshot is kept deliberately for one more moment: decision
    -- 10 makes this disconnect an ELIMINATION, and the match it just changed
    -- still has to be able to attribute the leaver. It is dropped once the
    -- queue no longer needs it.
    local timeout = nil
    local ok = pcall(function() timeout = SetTimeout end)
    if not ok or type(timeout) ~= "function" then return end
    timeout(60000, function()
        local stillHere = false
        for _, record in ipairs(pending) do
            for _, entry in ipairs(record.entries) do
                if entry.playerId == id then stillHere = true end
            end
        end
        if not stillHere and connected[id] == nil then identities[id] = nil end
    end)
end

--- Operator readout, and the answer to "is anything being written at all".
function Ranked.describe()
    local identityCount = 0
    for _ in pairs(careers) do identityCount = identityCount + 1 end
    local rating = "rating module ABSENT"
    local module = ratingModule()
    if module ~= nil and type(module.describe) == "function" then
        local ok, line = pcall(module.describe)
        if ok and type(line) == "string" then rating = line end
    end
    return ("%s -- %d identity(ies) cached, %d match(es) awaiting a write, %d job(s) queued, %d bot taint(s) held; rating: %s")
        :format(storageLine(), identityCount, #pending, #jobs, taintCount, rating)
end

local function addHandler(event, handler)
    local add = nil
    local ok = pcall(function() add = AddEventHandler end)
    if not ok or type(add) ~= "function" then return end
    add(event, handler)
end

addHandler("onPlayerConnected", onConnected)
addHandler("onPlayerDisconnected", onDisconnected)

addHandler("onResourceStart", function(name)
    local self = nil
    local ok = pcall(function() self = GetCurrentResourceName() end)
    if ok and self ~= nil and name ~= self then return end
    if not enabled() then return log("DISABLED in config") end
    -- ADOPT BEFORE ANYTHING ELSE. The bot taints ride in here, and a match that
    -- resolves in the first seconds after a hot reload must find them already
    -- in place.
    adopt()
    local spawn = nil
    local spawned = pcall(function() spawn = CreateThread end)
    if not spawned or type(spawn) ~= "function" then return end
    spawn(function()
        ensureSchema()
        log("ready -- career per identity per format; " .. storageLine())
        -- Anything adopted from the outgoing VM is written now rather than
        -- waiting for the next match to end.
        for _, record in ipairs(pending) do
            enqueue({ kind = "commit", record = record })
        end
    end)
end)

return CordonRanked
