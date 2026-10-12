-- COMFORT -- the vanilla restrictions this mode has to take off.
--
-- Right now that is one thing, and it is not a nicety: REDengine marks a
-- handful of interiors -- the Afterlife, Lizzie's, Clouds -- as staged,
-- walk-only, weapons-holstered space. Cordon stages its lobby IN the Afterlife
-- (shared/watson.lua explains why: staging runs in its own routing bucket, so
-- the lobby is a different dimension rather than a fenced corner of the arena),
-- and sixty-four players who cannot run are sixty-four players walking.
--
-- WHY THIS IS ITS OWN FILE. The suppression is a claim held for as long as the
-- resource runs, not an action taken at a moment, so it does not belong inside
-- the match state machine or the readiness handshake -- both of which come and
-- go several times a session. A file that does one thing and holds one claim
-- can also be deleted to test whether the claim is what is being felt.
--
-- HOW THE CLAIM BEHAVES, from scripting/src/ResourceHost.cpp:5454. It is
-- cooperative and owner-scoped: safe areas return only once EVERY claiming
-- resource has released, stopping a resource releases its claim for it, and the
-- native answers false unless a multiplayer session is live -- so a stale claim
-- can never reach single-player. `setSafeAreas` returns `ok, effective`, where
-- the second value is the state across every owner, which is how this resource
-- can tell that somebody else is still holding safe areas off.
--
-- WHAT THIS FILE CANNOT DO. The claim is a SWITCH; the work is done by the
-- REDscript wrappers in `client/redscript/Open77SafeAreaPolicy.reds` that read
-- it. So a `suppressed` line here means the switch is on, never that the player
-- can run -- and that distinction has now cost this feature two rounds.
--
-- WHAT ACTUALLY BROKE IT, measured 2026-09-03 and worth reading before touching
-- anything else here. `Open77.world` was registered TWICE in
-- `scripting/src/ResourceHost.cpp` -- once with `setSafeAreas`, and twelve lines
-- later with the geometry reads that arrived from another branch. The second
-- `lua_setfield` under that name replaced the first table wholesale, so
-- `Open77.world.setSafeAreas` was nil on a client whose DLL exported the native,
-- whose manifest held the permission and whose REDscript wrappers compiled
-- clean. This file said so twenty times and then gave up; the log line it said
-- it with blamed the DLL, which is the wrong place to look, and that is fixed
-- below. The tables are merged now; the guard is in
-- `scripting/tests/ResourceHostTests.cpp`.
--
-- The September 5 lobby measurement supersedes the old tier-2-only diagnosis:
-- the current Afterlife stays in tier 1, and InDaClub applies a nested modifier
-- group that multiplies CanSprint by zero. The platform now suppresses that
-- group's movement restrictions while preserving InDaClub and NoCombat. Live
-- sprint reached 7.50 m/s; releasing this claim restored CanSprint=0 in place.
-- See docs/research/movement-and-animation-replication.md for the causal trace.
--- `occasion` names WHY this call happened, and it earns its place: the claim
--- is asserted three times (resource start, world entry, and recovery) and a
--- log with three identical success lines cannot tell which of them the player
--- was actually standing in a world for.
local function apply(occasion)
    if Open77 == nil or Open77.world == nil or Open77.world.setSafeAreas == nil then
        -- SAY WHAT IS MISSING, NOT WHY IT IS MISSING. The previous wording named
        -- one cause -- "the deployed client is older than the safe-area native"
        -- -- and it was the wrong one: the binding existed and had been deleted
        -- from the table by a second `Open77.world` registered after it. A whole
        -- round went into the DLL because this line pointed there.
        --
        -- So report the shape of the fault and name BOTH places it can come
        -- from, in the order they are cheap to check.
        print(("[cordon] comfort: the safe-area binding is not on the API surface " ..
               "(Open77=%s world=%s setSafeAreas=%s) -- either the deployed DLL predates it, " ..
               "or something registered a second `Open77.world` table over it in " ..
               "scripting/src/ResourceHost.cpp. Running in the Afterlife stays blocked either way")
            :format(type(Open77), Open77 ~= nil and type(Open77.world) or "n/a",
                    (Open77 ~= nil and Open77.world ~= nil) and type(Open77.world.setSafeAreas) or "n/a"))
        -- A named reason, so `claim` below stops instead of printing this same
        -- line twenty times: neither cause resolves by waiting.
        return false, "binding_absent"
    end

    local ok, effective = Open77.world.setSafeAreas(false)
    if ok == false then
        -- `effective` carries the reason on failure, per the value, reason
        -- convention these bindings use throughout.
        return false, tostring(effective)
    end

    print(("[cordon] comfort: safe areas suppressed at %s (effective=%s) -- the staged-interior " ..
           "restriction is off. This says the SWITCH is set, not that the player can run: the " ..
           "wrappers in client/redscript/Open77SafeAreaPolicy.reds do that work, and " ..
           "`debug-bridge.ps1 'script.state'` shows what they measured on tier-2 entry")
        :format(tostring(occasion or "resource start"), tostring(effective)))
    return true
end

-- A SUCCESS LINE PROVES THE CALL, NOT THE STATE, and on 2026-09-03 that
-- distinction was the whole bug report. `apply` prints the moment
-- `setSafeAreas` returns, and that moment is EIGHT SECONDS into the client's
-- life: the session resource set activates while the player is still on the
-- menu -- `open77_appearance` logs `bootstrap phase=waiting -> menu` on the
-- same millisecond, and `worldReady` follows almost a second later. The save
-- load, world entry, and every placement (each of which is a kill and a
-- respawn) all happen AFTER the line that says everything is fine.
--
-- So read it back. `safeAreasEnabled()` is the policy's own answer and folds
-- the session gate in with the claim set, which is exactly what makes a
-- disagreement worth printing: safe areas back ON while this resource believes
-- it holds a claim means either the claim was dropped underneath us or the
-- session is no longer one the policy will act for. Neither should happen --
-- but "should" is what the previous round relied on, and the owner spent it
-- walking.
--
-- The re-claim costs a set insert and cannot do harm: the claim is idempotent
-- and owner-scoped, and the host releases it when this resource stops. So the
-- watchdog repairs as well as reports.
local reported = nil

--- One read-back, no rescheduling. Split out from the watchdog because world
--- entry wants a reading too, and `open77:worldReady` is emitted from several
--- places in the client host -- folding the reschedule in here would have every
--- one of them start another poll chain running alongside the first.
local function readBack()
    if Open77 == nil or Open77.world == nil or Open77.world.safeAreasEnabled == nil then
        -- Nothing to watch and nothing that will change: whatever removed one
        -- half of the binding removed both. `apply` has already said so, with
        -- the two places to look.
        return
    end

    local enabled, reason = Open77.world.safeAreasEnabled()
    if enabled == nil then
        if reported ~= reason then
            reported = reason
            print(("[cordon] comfort: cannot read the safe-area state back (%s) -- the claim " ..
                   "may be standing, but nothing here can prove it"):format(tostring(reason)))
        end
    elseif enabled then
        if reported ~= "on" then
            reported = "on"
            print("[cordon] comfort: safe areas are ON again even though this resource holds a " ..
                  "claim -- re-claiming. If this line repeats, something is dropping the claim " ..
                  "or the session left the phases the policy acts for")
        end
        apply("recovery")
    elseif reported ~= "off" then
        reported = "off"
        print("[cordon] comfort: read back -- safe areas are OFF, which the claim line above " ..
              "only asserted. Necessary, not sufficient: if running is still blocked from here, " ..
              "the answer is in `debug-bridge.ps1 'script.state'`, trace:safearea where=tier2enter")
    end
end

-- One line per CHANGE, not per poll: a file that prints every five seconds for
-- an hour is a file nobody reads. The reschedule is unconditional for the same
-- reason the script bridge's is -- one bad answer must not end the watch.
local watching = false
local function verify()
    readBack()
    SetTimeout(5000, verify)
end

-- THE FIRST ATTEMPT LOSES A RACE, and it was measured rather than guessed. On
-- 2026-09-03 the resource's first call returned `safe_area_backend_unavailable`
-- and a second call 150 ms later succeeded: the native's backend is wired a
-- moment after the client Lua starts. That reload happened to come for another
-- reason, so the claim landed by luck. On an ordinary connection there is no
-- second reload and the player is left walking with nothing but one line in a
-- log to explain it.
--
-- So retry, briefly and with a ceiling. The ceiling matters more than the
-- retry: an unbounded loop against a backend that is genuinely absent -- an
-- older deployed DLL, say -- would print forever and never say the one useful
-- thing, which is that this client cannot do it at all.
local attempts = 0
local function claim()
    attempts = attempts + 1
    local ok, reason = apply()
    if ok then
        if not watching then
            watching = true
            SetTimeout(5000, verify)
        end
        return
    end

    if attempts >= 20 then
        print(("[cordon] comfort: giving up after %d attempts (%s) -- staged interiors will " ..
               "stay walk-only this session"):format(attempts, tostring(reason)))
        return
    end

    -- Only the backend race is worth waiting out. A permission refusal or a
    -- missing binding will never resolve on its own, so retrying those would
    -- just be twenty identical lines in the log.
    if reason ~= nil and reason ~= "safe_area_backend_unavailable" then
        print(("[cordon] comfort: safe-area suppression REFUSED (%s) -- not retrying, this " ..
               "does not resolve with time"):format(tostring(reason)))
        return
    end

    SetTimeout(250, claim)
end

claim()

-- WORLD ENTRY IS THE ONLY MOMENT WORTH AN EXTRA READ. The claim is made on the
-- menu; this fires when the player is actually in a world, so a line here is
-- the first one that describes the thing the owner can feel. It re-asserts
-- rather than merely checking, because the cost is a set insert and the failure
-- it guards against -- a claim that did not survive the transition into the
-- world -- would otherwise be silent until somebody tried to run.
--
-- `reported` is cleared first so this always produces exactly one line, even
-- when the state has not changed. That is deliberate: the one thing the last
-- round of this bug lacked was a log line taken AFTER the world was up.
AddEventHandler("open77:worldReady", function()
    reported = nil
    apply("world entry")
    readBack()
end)
