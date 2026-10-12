-- Cordon -- public rules for the Open77 battle royale.
--
-- THIS FILE IS SENT TO EVERY CONNECTING CLIENT. Never place a secret, an ACL
-- entry, an identity or an address in it. Everything here is publishable.
--
-- It is also the single source of truth for player-facing TEXT
-- (`Config.strings`, plan decision 15: English, one table per resource, and the
-- server sends KINDS AND COUNTS over the wire, never display text). A kill feed
-- that ships a rendered sentence is a kill feed that cannot be translated and
-- cannot be re-styled without a server reload.
--
-- Layout, in the order a reader needs it:
--
--   buckets          the two routing buckets: staging and the match
--   match            formats, capacity, the clock either side of the match
--   schedule         the cordon closure schedule, as NAMED PRESETS
--   grid             block size and the shape of a block box
--   loot             tier tables, the drop budget, the registry arithmetic
--   inventory        three weapon slots, plates, heals -- the mode IS the inventory
--   squads           fill, revive, pings
--   bots             backfill policy, gang aliases, clamps, pacing, leash
--   cordon           tick rate, the hold rule, the damage kind
--   spawnProtection  the two shields, both enforced by the arbiter
--   strings          every player-facing string, English
--   tunables         the Warden panel contract
--
-- ---------------------------------------------------------------------------
-- THIS FILE HOLDS NO MAP GEOMETRY, and that split is the same one the
-- deathmatch pays for. Geometry -- the grid origin, the landing zones, the loot
-- marks, the final-block whitelist -- is SURVEYED, lives in the map store
-- (MySQL plus the carried-state bag) and is regenerated wholesale by
-- `/br.survey dump`. Anything a surveyor's paste would overwrite must not be
-- here or the paste destroys a rule. What IS here is rules: how many rings a
-- phase closes, how much a plate is worth, how many bots fill an empty lobby.
--
-- `Config.grid` is the one thing that sits on the line, and it lands here on
-- purpose: 100 m is a DESIGN choice about how far a player runs between edges,
-- while WHERE the grid is anchored is geometry. The map record carries the
-- origin and may override every default in `Config.grid`; `shared/grid.lua`
-- reads the map, never this table.
--
-- Plan: docs/gamemode-cordon-plan.md. Measurements: docs/research/battle-royale-and-scale.md.
-- ---------------------------------------------------------------------------
Config = {
    -- ======================================================================
    -- BUCKETS
    -- ======================================================================
    --
    -- TWO buckets, and there will never be more (plan decision 1: one match per
    -- server, a second match is a second server). The deathmatch needed 80
    -- buckets because its instance kernel opens a fight per group of twelve;
    -- this mode's whole population is one match, so the address space is two
    -- integers and a reserved tail.
    --
    -- WHY 5100. The 5000 range is the only three-digit-prefixed block on this
    -- platform with nothing in it: `pursuit` holds 1000 and 2000-2099,
    -- `open77_deathmatch` holds 4100 and 4200-4287, `race` holds 6000. Bucket
    -- collision is silent and vicious -- two modes in one bucket relay each
    -- other's snapshots and each other's props -- so the range is picked by
    -- reading the other resources, not by feel.
    --
    -- `reservedFirst`..`reservedLast` is reserved and unused. It costs nothing
    -- and it means the day somebody does want a second concurrent match, or a
    -- private scrim bucket, they take a number rather than a fight with race.
    buckets = {
        staging       = 5100,   -- lobby / staging / spectator-watch
        match         = 5101,   -- the sealed sector; population off, lockdown relaxed
        reservedFirst = 5102,
        reservedLast  = 5119,
    },
    -- ======================================================================
    -- MATCH -- formats and the clock either side of the fight
    -- ======================================================================
    match = {
        -- 64 is a CONFIG value (`network.maximumPlayers`, validated 1..1024,
        -- enforced at join in SessionManager), not a platform ceiling -- but it
        -- was only made honest by two measurements recorded in
        -- docs/research/battle-royale-and-scale.md:
        --
        --   E2: 63 bodied proxies in view cost the client 1.6 ms of Open77 hook
        --       and held 74 Hz. The client can DRAW 64.
        --   E1: the un-culled relay cost every player ~326 KB/s and killed the
        --       link at the transport's 256 KB/s default clamp. The network
        --       could not SEND 64 until P1 (player area of interest) landed;
        --       with it, per-player egress fell to ~23 KB/s spread over 2 km.
        --
        -- So 64 is the shipped size AND it depends on `simulation.playerInterestRadius`
        -- being non-zero in the server profile. See the note at the end of
        -- `Config.tunables`: it is a SERVER setting, not one of ours, and a
        -- server that leaves it at the default 0 will run this mode at 64 and
        -- fall over. That is the single most important line in this file.
        maxPlayers = 64,
        -- The formats. `squadSize` is the whole difference between them; the
        -- squad code reads this and nothing branches on the format name.
        -- `squads` is derived (maxPlayers / squadSize) and written out only so
        -- a reader does not have to divide.
        formats = {
            solo  = { key = "solo",  squadSize = 1, squads = 64, label = "SOLO"  },
            duo   = { key = "duo",   squadSize = 2, squads = 32, label = "DUO"   },
            squad = { key = "squad", squadSize = 4, squads = 16, label = "SQUAD" },
        },
        -- Plan Q1 proposed Squad as the default and Solo as the first playtest
        -- format. Squad was the default for a while, on the argument that it is
        -- the format the mode is designed around (revive, pings and squad voice
        -- all exist for it) and that defaulting elsewhere would leave three
        -- systems untested on the busiest server.
        --
        -- SOLO for now, owner's call 2026-09-03: on a server that is usually one
        -- person testing, Squad(4) means a lobby of one is a squad of one, which
        -- reads as a bug rather than as a format. Solo is what a single tester
        -- should meet. The squad systems do not rot -- they are still exercised
        -- by setting the format back, which is a one-line tunable and the reason
        -- nothing in the squad code branches on the format NAME (only on
        -- `squadSize`), so this line is genuinely the whole switch.
        --
        -- Q1 is not re-litigated: the plan's answer stands as the answer for a
        -- POPULATED server, and this is recorded as an explicit re-decision for
        -- the current, unpopulated one.
        defaultFormat = "solo",
        -- How many HUMANS must be in staging before the countdown starts at
        -- all. This is a FLOOR, not a target: two players are a battle royale
        -- with two sides, which is the least the mode needs to mean anything.
        --
        -- It was 16, tied to `ratedMinPlayers` on the argument that a match
        -- worth starting is a match worth rating. That argument is wrong for a
        -- young server: it never starts, so it never attracts the sixteenth
        -- player, so it never starts. Owner's call, 2026-09-03 -- "16 c'est
        -- trop si y'a pas trop de joueurs".
        --
        -- Rating is unaffected and that is the point of separating them:
        -- `ratedMinPlayers` still decides what counts, so a four-player match
        -- runs and is simply UNRATED. Nobody's career moves on a thin lobby.
        minPlayers = 2,
        -- The queue size at which waiting longer stops being worth it. Reaching
        -- it collapses whatever is left of `stagingSeconds` down to
        -- `countdownSeconds`.
        --
        -- It can only ever bring the start FORWARD, never push it back, so a
        -- player leaving and rejoining cannot rewind a clock other people are
        -- already watching.
        --
        -- Plan section 2 asked for this already -- "fills to 64 or 60 s,
        -- whichever first" -- and `countdownSeconds` below was written for it,
        -- but `M.armCountdown` never implemented the cut: it armed the long
        -- wait and left it there, so a full lobby still sat out the full
        -- `stagingSeconds`. Owner's ask, 2026-09-03: start from about five in
        -- the queue rather than waiting for a lobby that may never fill.
        startAtPlayers = 5,
        -- --------------------------------------------------------------
        -- THE CLOCK EITHER SIDE OF THE MATCH (plan section 2)
        -- --------------------------------------------------------------
        --
        -- 105 + 45 = 150 s, which is the plan's -2:30. The split is not
        -- cosmetic: the tac-map opens at the boundary between them, and the
        -- staging countdown can be cut short by a full lobby while the deploy
        -- window never can -- everybody needs the same time to read the map.
        stagingSeconds = 105,
        -- The countdown that runs INSIDE staging once `minPlayers` is met.
        -- Plan section 2: "fills to 64 or 60 s, whichever first". A lobby that
        -- fills at second 3 still gives the last joiner a moment to see where
        -- they are.
        countdownSeconds = 60,
        deploySeconds = 45,
        -- The result card. 12 s is the plan's number and it is short on
        -- purpose: the standings live on the staging panel afterwards, so this
        -- is a celebration, not a report.
        resultSeconds = 12,
        -- Result card -> everybody back in staging. Plan's +0:20.
        returnSeconds = 20,
        -- --------------------------------------------------------------
        -- DYING WHILE THE MATCH RUNS ON (plan section 6.1)
        -- --------------------------------------------------------------
        --
        -- Both of these were live defaults inside `server/match.lua` with no
        -- entry here, which made them invisible to anybody reading the config to
        -- find out how the mode behaves. Naming them changes nothing -- the
        -- values are the ones the code already used -- and makes them tunable
        -- from one place.
        --
        -- THE BODY. How long a corpse nobody is coming for stays exactly where
        -- it fell before the sweep moves it to the lobby. Long enough to read
        -- the card where you died, short enough not to be a punishment. It is
        -- the whole of the "middle" between dying and the lobby, and the cordon
        -- shortens it for a body lying out in the bleed
        -- (`Config.squads.bleedOutCordonFactor`).
        --
        -- A revive window somebody can actually answer OUTRANKS it: in Squad a
        -- downed player holds for `Config.squads.reviveWindowSeconds` instead,
        -- because the body is the mechanic.
        eliminationHoldSeconds = 8,
        -- THE CARD. How long the player's own result card -- placement, kills,
        -- time survived -- stays on screen after they land in the lobby.
        -- `resultSeconds` for the same reason it is 12 there: it is a verdict,
        -- not a report, and the match is still running behind it. Zero never
        -- shows it.
        --
        -- Separate from the hold on purpose. The hold is about the corpse and
        -- can be cut to a third by the cordon; the card is about the player
        -- reading their own result and must not be cut with it.
        eliminationCardSeconds = 12,
        -- Placement pacing. Every placement in this mode is `kill -> respawn`
        -- with both ledgers suppressed (plan decision 11), and each `respawn`
        -- carries a streaming preload. 64 of them in one tick stampedes the
        -- scheduler, so they are staggered: 64 x 50 ms = 3.2 s, which fits
        -- inside the 4 s deploy shield with room to spare.
        placementStaggerMs = 50,
        -- A placement that does not land is retried rather than dropped -- the
        -- deathmatch's numbers, which were paid for by a real lobby of players
        -- standing in the void.
        placementGraceMs = 7000,
        placementRetryMs = 250,
        placementRetryTimeoutMs = 30000,
        -- Plan decision 10. A disconnect is an elimination in v1 because
        -- rejoin-in-place needs the mode to persist verified weapons and ammo
        -- per player, and that store does not exist until loot inventory is
        -- stable (plan Q4).
        disconnectIsElimination = true,
        -- --------------------------------------------------------------
        -- THE DROP (plan section 3) -- the aerial insertion
        -- --------------------------------------------------------------
        --
        -- This table REPLACES decision 18 ("pin and stand"), and the reason
        -- that decision existed is now fixed rather than worked around. E3
        -- measured a 120 m fall killing a god-moded player, and the diagnosis
        -- was wrong in an instructive way: fall damage does not "bypass the god
        -- mode gates". It is a self-targeted ATTACK -- `PlayHardLandingEffects`
        -- fires `Attacks.HardLanding` / `VeryHardLanding` / `DeathLanding`
        -- through the ordinary DamageSystem -- and the client's shield was
        -- `Immortal`, which does not block an attack, it FLOORS the health pool
        -- at ~1%. One per cent is exactly what the server's lethality test
        -- accepts, so the client reported its own death and the server applied
        -- it. Both halves are closed now: the client shield is `Invulnerable`,
        -- and `PlayerLifeService.ObserveDeathIntent` refuses a death intent
        -- from a god-moded player.
        --
        -- The chute itself does not rely on either. REDengine grades a landing
        -- by comparing the vertical speed against thresholds latched from the
        -- state graph's STATIC parameters; the runtime gravity override lowers
        -- the real impact speed while those thresholds stay put, so the engine
        -- grades the touchdown `Regular` and fires no attack at all. The
        -- shields are what catches a mis-tuned value, not what makes it work.
        drop = {
            -- Off by default until a real lobby has flown it. `false` restores
            -- the ground placement exactly, which is also the fallback path, so
            -- the flag switches between two behaviours that both already run.
            enabled = false,
            -- Metres above the surveyed landing zone. 250 m is roughly nine
            -- seconds of descent at `descentRate`, which is long enough to
            -- read the district and short enough that the deploy stagger
            -- (64 x 50 ms) plus the descent still fits inside one minute.
            altitudeMetres = 250.0,
            -- Downward acceleration in m/s², NEGATIVE. Vanilla is -16.0; the
            -- vanilla jetpack descends at -4.0, which is the value this borrows
            -- because it is the one CDPR shipped for a controlled descent.
            gravity = -4.0,
            -- Terminal speed in m/s. This is what actually bounds the impact,
            -- and it must exist: a constant gravity has no terminal velocity,
            -- so without it the landing speed would grow with `altitudeMetres`
            -- and a higher drop would re-cross the engine's thresholds.
            descentRateMetresPerSecond = 8.0,
            -- Horizontal assist in m/s while airborne. 0 disables it and the
            -- descent is purely vertical.
            glideSpeedMetresPerSecond = 6.0,
            -- THE GUARD, and the most important number here. If a client never
            -- reports its touchdown -- an old client, a resource that failed to
            -- start, a player who alt-tabbed through the whole descent -- the
            -- server places them on the ground itself and the match continues.
            -- The mode must never wait on a client. Sized as descent time
            -- (altitude / rate ~= 31 s) plus generous slack.
            landingTimeoutSeconds = 60.0,
            -- Below this height above the landing zone the server stops
            -- believing a `cordon:landed` report: a player claiming to have
            -- landed while still at altitude would be claiming their landing
            -- grace early. Generous, because the landing zone's z and the real
            -- ground under a drifting player are not the same metre.
            landedToleranceMetres = 25.0,
        },
    },
    -- ======================================================================
    -- SCHEDULE -- the cordon closure, as NAMED PRESETS
    -- ======================================================================
    --
    -- WHY PRESETS AND NOT A TUNABLE TABLE. A tunable string value is capped at
    -- 256 characters (wiki/server-api.md, "Operator-tunable settings"). So the
    -- TUNABLE CARRIES A NAME and the tables live here. An operator picking
    -- "blitz" from the Warden panel is choosing a row of this table; there is no
    -- path by which a panel write can author a schedule, which is also why a
    -- malformed schedule cannot reach a running match.
    --
    -- ----------------------------------------------------------------------
    -- WHAT REPLACED THE HAND-WRITTEN PHASE TABLE, 2026-09-02, AND WHY
    -- ----------------------------------------------------------------------
    --
    -- This used to be seven literal rows: `{ atSeconds = 150, toRings = 5, ... }`
    -- and so on down to a 17:30 finish. Every one of those numbers was a
    -- statement about a 14x14 Pacifica, and on any other map size the table
    -- degenerated SILENTLY. Measured on Watson (2x2, the only map that plays
    -- today): rings 5, 3, 2 and 1 are all the WHOLE grid once `Grid.ringsFrom`
    -- clips them, so the first four phases closed nothing at all, phase 5 took
    -- three of the four blocks at once at t=13:00, and phase 7 took the last at
    -- t=16:30. Thirteen minutes of nothing followed by a guillotine.
    --
    -- So a preset is now a SHAPE and `C.buildSchedule` derives the phases from
    -- the map it is actually handed -- as many steps as the grid has rings for,
    -- normalised to the total the preset asks for. The same preset gives Watson
    -- seven phases at 25 m and a 14x14 Pacifica ten at 100 m, and neither
    -- carries a number that was written for the other.
    --
    -- A PRESET, field by field:
    --
    --   graceSeconds          the drop to the first closure starting. The loot
    --                         window, and the one number that answers "how long
    --                         before this becomes a fight".
    --   cordonSeconds         the first closure starting to the last shrink
    --                         ending. THE MATCH LENGTH, in one number. Every
    --                         per-step duration is derived from it, so a shorter
    --                         match is one edit and not nine.
    --   steps                 how many zones the player is asked to move
    --                         between. A CEILING, not a promise: a map with
    --                         fewer Chebyshev rings than this gets fewer phases,
    --                         because a phase that closes nothing is exactly the
    --                         bug above.
    --   closeShare            of each step, the fraction spent CLOSING; the rest
    --                         is the hold. 0.55 leaves the hold slightly shorter
    --                         than the close, which is what makes a late
    --                         rotation frightening rather than merely
    --                         inconvenient.
    --   speedUp               the first step's total time divided by the last's.
    --                         This one number is the Apex feel: early zones slow
    --                         and forgiving, late ones arriving before you have
    --                         finished the fight you are in.
    --   firstDamagePerSecond  the bleed in step 1 ...
    --   lastDamagePerSecond   ... and in the last shrink, interpolated
    --                         GEOMETRICALLY between them. Not linearly: a linear
    --                         ramp from 2.5 to 30 over seven steps puts 11 HP/s
    --                         in the middle of a match where players still have a
    --                         whole zone to cross, which kills rotations instead
    --                         of punishing them. Geometric keeps the early steps
    --                         survivable and spends the whole increase late.
    --   finalSeconds          the terminal phase, which closes the last cell.
    --   finalDamagePerSecond  its rate. It leaves no survivors BY ARITHMETIC and
    --                         not by a special case: nothing is open, and 60 HP/s
    --                         against a 100 HP ledger with 75 armour is under
    --                         three seconds. The mode never needs a "kill
    --                         everyone" branch -- which is the branch that would
    --                         eventually fire during a live match by mistake.
    --
    -- THE CLOSING UNIT IS THE LATTICE CELL, NOT THE SURVEYED BLOCK. See
    -- `Config.cordon.lattice` and `Grid.subdivisionFor`: on Watson a step closes
    -- 25 m cells, on a 9x5 Pacifica 50 m ones, on a 14x14 the 100 m blocks the
    -- plan describes. Rings are still Chebyshev radii around the hidden final
    -- cell, so `rings = n` is a (2n+1)-cell square clipped by the grid, and the
    -- clipping is still a feature: a final cell near the coast makes an
    -- asymmetric first close, which reads as NCPD sealing from the landward
    -- side.
    --
    -- WHERE THIS CONTRADICTS THE PLAN. Section 2's timetable is 17:30 over seven
    -- named cordons; `standard` below is 6:10. Owner request, 2026-09-02 ("le
    -- cordon qui close faut un temps bcp plus rapide et plusieurs zone qui se
    -- referme au fur et a mesure a la Apex legends, reduit drastiquement les
    -- zones"), not a measurement. `long` keeps a plan-length match available for
    -- a full 64-player sector, and it is one tunable away.
    schedule = {
        -- ==================================================================
        -- STANDARD -- ~6:10 of cordon, the default.
        -- ==================================================================
        --
        -- Nine steps requested; Watson can carry seven and a 14x14 Pacifica ten,
        -- and both finish at the same 370 s because the per-step durations are
        -- normalised rather than fixed. With the 105 s staging and the 45 s
        -- deploy window in front of it, a match is about 8:40 of wall clock.
        --
        -- The zone sequence on Watson, which is the one that will be looked at
        -- first: 175 m -> 150 -> 125 -> 100 -> 75 -> 25 -> nothing, with 45 s of
        -- pure looting in front. Crossing that map on foot is about 30 s, so
        -- every hold is a real rotation and none of them is a formality.
        standard = {
            graceSeconds = 45,
            cordonSeconds = 300,
            steps = 9,
            closeShare = 0.55,
            speedUp = 2.6,
            firstDamagePerSecond = 2.5,
            lastDamagePerSecond = 30.0,
            finalSeconds = 25,
            finalDamagePerSecond = 60.0,
        },
        -- ==================================================================
        -- BLITZ -- ~3:00 of cordon, for DEVELOPMENT.
        -- ==================================================================
        --
        -- Not a game mode: a test fixture. The closure code is the part that
        -- needs running twenty times an afternoon, and at this pace a whole
        -- match including staging fits in five minutes.
        --
        -- The rates are NOT the standard rates: at this speed a player has less
        -- time to walk back in, so the bleed starts higher to keep "outside is
        -- fatal" true in the compressed clock. They are a GUESS chosen to make
        -- each phase visibly lethal in a dev run, and nothing balances against
        -- them.
        blitz = {
            graceSeconds = 20,
            cordonSeconds = 140,
            steps = 7,
            closeShare = 0.55,
            speedUp = 2.2,
            firstDamagePerSecond = 4.0,
            lastDamagePerSecond = 40.0,
            finalSeconds = 20,
            finalDamagePerSecond = 80.0,
        },
        -- ==================================================================
        -- LONG -- ~15:45 of cordon, the plan's own pacing.
        -- ==================================================================
        --
        -- Plan section 2 asks for 17:30 and this is the closest honest version
        -- of it: twelve steps, a two-minute loot window, and a damage ramp that
        -- starts at 2 HP/s because a 2 km sector takes minutes to cross. Kept so
        -- that "the mode is too fast now" is a tunable and not a revert.
        long = {
            graceSeconds = 120,
            cordonSeconds = 780,
            steps = 12,
            closeShare = 0.55,
            speedUp = 2.8,
            firstDamagePerSecond = 2.0,
            lastDamagePerSecond = 25.0,
            finalSeconds = 45,
            finalDamagePerSecond = 50.0,
        },
        -- The preset the `schedule` tunable falls back to when it names one that
        -- does not exist. A typo in the Warden panel must not produce a match
        -- with no cordon at all -- a battle royale whose boundary never closes
        -- never ends.
        --
        -- IT WILL BE HIT. Tunables persist to `tunables.json`, so a server that
        -- ran the retired `"short"` preset asks for it again after this file
        -- replaced it; `schedulePreset` warns and lands here.
        fallback = "standard",
    },
    -- ======================================================================
    -- GRID -- block size and the shape of a block box
    -- ======================================================================
    --
    -- DEFAULTS ONLY. A map record in the store carries its own origin and may
    -- override every number here; `shared/grid.lua` reads the map it is handed
    -- and never touches this table. These are what a map inherits when it says
    -- nothing.
    --
    -- WHY BLOCKS AND NOT A CIRCLE (plan decision 2). The platform has no
    -- primitive that draws a ring wider than 50 m -- `open77_groundcircle`,
    -- anchors and markers all cap there -- and its containment code is written
    -- for axis-aligned boxes. A block edge is also a straight segment on a
    -- street grid, which is the one shape a line of props can draw cheaply. The
    -- circle is the recorded fallback if the edge reads badly in Phase 4.
    grid = {
        -- 100 m is a design choice about how far a player runs between edges,
        -- and it is the number the survey is anchored to: changing it after the
        -- survey invalidates every loot mark's block tag.
        blockMetres = 100,
        -- 14 x 14 = 196 blocks = ~2 km^2, the plan's Pacifica sector.
        cols = 14,
        rows = 14,
        -- --------------------------------------------------------------
        -- HOW TALL A BLOCK IS
        -- --------------------------------------------------------------
        --
        -- A block is a BOX, and its job is to answer "is this player inside".
        -- Pacifica is stilted and multi-level -- the Grand Imperial Mall alone
        -- spans several floors -- so a box that hugs street level would bleed
        -- anybody on a roof or in a basement garage.
        --
        -- These are margins from the map's origin z (the surveyed street plane),
        -- and they are DELIBERATELY GENEROUS in both directions. A false
        -- "outside" costs a player health they cannot understand losing; a false
        -- "inside" costs nothing but a moment of mercy. The asymmetry is why
        -- the ceiling is large enough to contain an AV overflight.
        --
        -- Both numbers are a GUESS until the Phase 2 survey reports the real
        -- vertical span of the sector. `/br.map check` should refuse a map whose
        -- captured marks fall outside them.
        floorMargin   = 60.0,
        ceilingMargin = 260.0,
        -- The final phase's sub-block square (plan section 2, Cordon 6). 40 m
        -- inside a 100 m block, centred on the block, which puts the last fight
        -- at shotgun-and-panic range.
        finalSquareMetres = 40.0,
        -- The final block is drawn from a surveyed whitelist, never from the
        -- whole grid: plan section 3 forbids a block that is mostly water,
        -- highway or a blind rooftop. This is only the SIZE of that whitelist
        -- the survey must reach before `/br.map check` calls the map playable.
        finalWhitelistMin = 30,
    },
    -- ======================================================================
    -- LOOT -- ground drops, and the arithmetic against the registry cap
    -- ======================================================================
    --
    -- THE PICKUP GRANTS NOTHING BY ITSELF; THE MODE IS THE INVENTORY.
    -- `open77_loot` places a real native drop, presents it through the game's
    -- own Take UI, validates the pickup server-side and tells every server VM
    -- through `onLootPickup(playerId, dropId, item, quantity)`. What the native
    -- inventory then holds is presentation. The AUTHORITY is `server/loot.lua`
    -- reacting to that event: `Open77.weapons.assign` into a free slot, then the
    -- verified TweakDBID that comes back on `open77:weapons:completed` goes into
    -- the arbiter's accepted set. Fail-closed, exactly as the deathmatch's
    -- `loadout.lua` does it -- so the worst case of a loot bug is "cannot
    -- shoot", never "free damage".
    --
    -- ------------------------------------------------------------------
    -- THE BUDGET, and why it is 900 rather than "as many as look right"
    -- ------------------------------------------------------------------
    --
    -- The registry is capped at 4096 drops (wiki/loot.md). The arithmetic
    -- against that cap, with the survey's 500 loot marks:
    --
    --   marks by tier    500 x { .55, .30, .12, .03 }  = 275 / 150 / 60 / 15
    --   drops per mark   avg  { 1.5, 1.8, 2.2, 3.0 }
    --   match drops      412.5 + 270 + 132 + 45         =  859.5
    --   supply drops     6 closures x 6                 =   36
    --   death drops      worst case 64 x 4, TTL 300 s   =  256
    --                                                     -----
    --                                                     ~1152 of 4096
    --
    -- That is 28% of the registry at the theoretical worst moment, which never
    -- actually occurs (all 64 cannot die at once and hold their TTL). It is also
    -- comfortably above the 64 x 12 = 768 rule of thumb for "every player can
    -- find a gun". E11 measures the real streaming cost of ~900 drops with three
    -- clients moving through them; if it is expensive, generation goes lazy per
    -- block and this budget becomes a per-block one.
    --
    -- The KIND MIX below multiplies out to the plan's section 5 targets, and the
    -- multiplication is written out so a change to one weight can be checked:
    --
    --   weapons 412.5x.20 + 270x.26 + 132x.34 + 45x.50 = 220  (plan: ~220)
    --   ammo    412.5x.36 + 270x.32 + 132x.28 + 45x.20 = 281  (plan: ~300)
    --   heals   412.5x.22 + 270x.22 + 132x.20 + 45x.15 = 183  (plan: ~200)
    --   plates  412.5x.16 + 270x.18 + 132x.18 + 45x.15 = 145  (plan: ~150)
    --   money   412.5x.06 + 270x.02 + 132x.00 + 45x.00 =  30  (plan: ~30)
    --                                                    ----
    --                                                     859
    loot = {
        budget = 900, -- enforced by the seeding planner, leaving room for death loot
        seedSpacingMetres = 2.0,
        minimumPerParticipant = { weapon = 1, heal = 1, shield = 1, plate = 1 },
        registryCap = 4096,          -- the platform's, not ours. Never raise it here.
        expectedMarks = 500,         -- what the Phase 2 survey must deliver
        -- Positive density preserves one slot per authored anchor; extras must
        -- fit its scatter surface at seedSpacingMetres separation.
        density = 1.0,
        -- How far a drop may scatter from its cluster anchor. Capped, and NOT
        -- for taste: every drop takes the anchor's height, because the anchor
        -- is the only walked point in the cluster, so a scatter wider than the
        -- flat ground around it puts items on roofs and in the air. Measured on
        -- Pacifica, where the surface moves several metres inside twenty. The
        -- cluster's own `radius` still applies when it is smaller than this.
        maxScatterMetres = 8.0,
        -- Pickup radius handed to `loot.create`. The platform accepts 0.5..10 m
        -- and validates a pickup at `radius + 0.75 m`. 1.6 m is tight enough
        -- that two drops a metre apart stay distinguishable in the Take UI.
        radiusMetres = 1.6,
        -- Match drops live for the match. Death drops must not: a body's guns
        -- lying on the ground twenty minutes later are 256 registry entries
        -- nobody will collect.
        matchTtlMs = 0,              -- 0 = no TTL; cleared when the match tears down
        deathDropTtlMs = 300000,     -- 5 min, plan section 5
        -- --------------------------------------------------------------
        -- AMMO
        -- --------------------------------------------------------------
        --
        -- `setAmmo` is RESERVE ONLY and this is not a style preference: the call
        -- fails AS A WHOLE if `magazine` exceeds the weapon's capacity (measured
        -- 2026-08-31 on the deathmatch -- a Lexington given
        -- `{ reserve = 300, magazine = 60 }` ended on `000 0000`). Never add a
        -- `magazine` field to anything in this file.
        --
        -- THE FOUR AMMO RECORDS ARE AN INFERENCE, NOT A MEASUREMENT.
        -- docs/research/weapons-and-item-records.md records four distinct engine
        -- ammo pools by numeric TweakDBID and notes that `Ammo.HandgunAmmo`,
        -- `Ammo.RifleAmmo`, `Ammo.SniperRifleAmmo` and `Ammo.ShotgunAmmo` are the
        -- only ammo records found in either TweakDB -- but the name-to-id
        -- association was never resolved directly, because the reverse table is
        -- absent on this build. They are used here as the DROP's item record
        -- (what the Take UI shows), which is the harmless half; the reserve
        -- actually granted comes from `setAmmo` keyed off the weapon, so a wrong
        -- record here shows the wrong icon and grants the right bullets.
        --
        -- One measured trap that a hand-written table would get wrong: a
        -- PRECISION RIFLE fires RIFLE ammo, not sniper ammo. An M-179e Achilles
        -- reports the same pool id as an M2067 Defender. Do not "fix" the
        -- `precision` line below to point at sniper.
        ammo = {
            handgun   = { record = "Ammo.HandgunAmmo",     label = "handgun",  amount = 90  },
            rifle     = { record = "Ammo.RifleAmmo",       label = "rifle",    amount = 120 },
            precision = { record = "Ammo.RifleAmmo",       label = "rifle",    amount = 90  },
            sniper    = { record = "Ammo.SniperRifleAmmo", label = "sniper",   amount = 20  },
            shotgun   = { record = "Ammo.ShotgunAmmo",     label = "shotgun",  amount = 24  },
        },
        -- Which ammo pool a weapon category draws from. `server/loot.lua` uses
        -- it to decide what an ammo drop is worth to the gun in your hands.
        ammoForCategory = {
            Pistol            = "handgun",
            Revolver          = "handgun",
            SMG               = "handgun",   -- SMGs share the handgun pool on 2.31
            ["Assault rifle"] = "rifle",
            LMG               = "rifle",
            ["Precision rifle"] = "precision",
            ["Sniper rifle"]  = "sniper",
            Shotgun           = "shotgun",
        },
        -- --------------------------------------------------------------
        -- PLATES, HEALS AND MONEY -- the three drops with UNVERIFIED records
        -- --------------------------------------------------------------
        --
        -- READ THIS BEFORE CHANGING A RECORD BELOW.
        --
        -- `Items.money` and `Items.MoneyShard` are documented in wiki/loot.md
        -- (the platform picks the shard automatically as the visual for abstract
        -- currency), so `money` is safe.
        --
        -- `plate` and `heal` are NOT. There is no generated catalogue of
        -- consumables on this build -- docs/generated/ carries weapons,
        -- clothing, props, NPCs, SFX and VFX and nothing else -- so the records
        -- named below could not be checked the way every weapon record in this
        -- file was. They are the vanilla names as commonly written, and they are
        -- MARKED `verified = false` so `server/loot.lua` can refuse to seed a
        -- match with an unverified record rather than scattering 350 invisible
        -- drops across Pacifica.
        --
        -- TO VERIFY, and it is one console line each in the lab:
        --     loot.create.player 1 Items.FirstAidWhiffV0 1
        --     loot.create.player 1 Items.BonesMcCoy70V0 1
        --     loot.create.player 1 Items.ArmorPlateCommon 1
        -- A record that does not exist produces no entity. When a drop appears
        -- and its Take card names the right thing, set `verified = true` here and
        -- delete this paragraph. Until then `fallbackRecord` is what actually
        -- gets seeded: a canonical weapon record is a guaranteed-visible drop,
        -- which makes an unverified plate look wrong rather than look absent --
        -- and looking wrong is the failure mode somebody reports.
        plate = {
            -- STAYS UNVERIFIED, and now for a measured reason rather than an
            -- untested suspicion: `Items.ArmorPlateCommon` DOES NOT EXIST on
            -- 2.31. Confirmed twice, independently, on 2026-09-03 --
            -- `tweak.record Items.ArmorPlateCommon` answers `ERR
            -- record_not_found`, and `docs/generated/clothing-2.31.csv`
            -- (generated from this build's own tweakdb.bin) contains no record
            -- matching "plate" at all.
            --
            -- So do NOT go looking for a typo: there is no armour-plate item to
            -- name here. The fallback below is a real record (it IS in that CSV)
            -- and the plate is granted either way, so the only casualty is the
            -- word on the Take card. Finding the right record means dumping the
            -- consumable/gadget tables, which nothing in docs/generated/ covers
            -- yet.
            record = "Items.ArmorPlateCommon", verified = false,
            -- The fallback is an ARMOUR record rather than eddies. An unverified
            -- plate then looks like a plate instead of looking like litter --
            -- which is what a container full of money next to a dead body did.
            -- Verified through docs/generated/clothing-2.31.csv, generated from
            -- this build's own r6/cache/tweakdb.bin.
            fallbackRecord = "Items.ArmoredOuterChestClothing", fallbackQuantity = 1,
            label = "plate",
        },

        -- SHIELDS -- the equippable armour layer. Capacity comes from the
        -- carrier you wear; plates only refill it, they do not raise the
        -- ceiling. 75 is that ceiling because the combat surface scales its
        -- armour bar against a hard-coded 75, and Config.inventory already
        -- documents "3 x 25 = 75" -- so these numbers change nothing in the HUD.
        --
        -- The pool is the MODE'S, deliberately not the engine's `Armor` field,
        -- and the cordon is what decides it: scripted damage reaches the same
        -- Commit path, so engine armour would absorb the bleed and a full
        -- carrier would buy 75 extra points of standing in the dark. The one
        -- damage in this mode that must stay unsurvivable is the cordon.
        shields = {
            tiers = {
                { key = "light",  label = "LIGHT VEST",    capacity = 25, weight = 50,
                  record = "Items.Vest_01_basic_01",           verified = true,
                  fallbackRecord = "Items.money", fallbackQuantity = 1 },
                { key = "medium", label = "MEDIUM VEST",   capacity = 50, weight = 34,
                  record = "Items.Q000_Nomad_Vest",            verified = true,
                  fallbackRecord = "Items.money", fallbackQuantity = 1 },
                { key = "heavy",  label = "HEAVY CARRIER", capacity = 75, weight = 16,
                  record = "Items.Q115_Custom_Predator_Armor", verified = true,
                  fallbackRecord = "Items.money", fallbackQuantity = 1 },
            },
        },
        heal = {
            -- MaxDoc and Bounce Back are the two the plan names. Both are rolled
            -- from one `heal` kind because the mode's inventory does not
            -- distinguish them -- a heal is a heal is `Config.inventory.healValue`.
            -- They differ only in the card the Take UI shows, which is flavour.
            records = {
                -- VERIFIED 2026-09-03 through the debug bridge's read-only
                -- `tweak.record`, with the client session DISCONNECTED (it is
                -- refused during a session with `local_lab_command_disabled`):
                --
                --   Items.FirstAidWhiffV0 -> OK type=gamedataConsumableItem_Record id=0x1519DBB192
                --   Items.BonesMcCoy70V0  -> OK type=gamedataConsumableItem_Record id=0x145C1A7DFB
                --
                -- Both exist, so `verified = false` was merely stale, and it was
                -- costing every heal its physical drop: `resolveRecord` logged
                -- "dropping nil instead and still granting the heal", so the
                -- grant worked and the container appeared to contain nothing.
                { record = "Items.FirstAidWhiffV0", verified = true, label = "maxdoc" },
                { record = "Items.BonesMcCoy70V0",  verified = true, label = "bounceback" },
            },
            fallbackRecord = "Items.money", fallbackQuantity = 1,
        },
        money = {
            record = "Items.money", visualItem = "Items.MoneyShard", verified = true,
            min = 250, max = 1500, step = 50,
            -- Plan Q5 is unanswered, so money is scaffolded and inert: it counts
            -- toward a placement TIE-BREAK and a career number, and gates
            -- nothing (plan decision 14, progression gates nothing). If Q5 comes
            -- back "leave money out", delete the `money` weight from every tier
            -- and this block goes dead without touching anything else.
            countsTowardTieBreak = true,
        },
        -- The supply crate itself (plan section 5). A prop with a red light and
        -- a blip; the six drops around it roll on tier 4.
        supply = {
            propMesh = "base\\environment\\decoration\\containers\\cargo\\cargo_crate\\cargo_crate_a.mesh",
            drops = 6,
            flareSeconds = 20,       -- how long the marker burns before the crate exists
            firstClosureIndex = 2,   -- from Cordon 2 on, per plan section 2
        },
        -- ==================================================================
        -- CONTAINERS -- what a loot point LOOKS like
        -- ==================================================================
        --
        -- THE DROP IS THE AUTHORITY; THE CONTAINER IS PRESENTATION.
        --
        -- `Open77.loot.create` spawns the game's own `gameItemDropObject`, and
        -- that object's mesh is the ITEM's mesh: a money drop is a money shard,
        -- an ammo drop is a magazine. Lying on Pacifica's concrete at a couple
        -- of metres those read as litter rather than as loot, which is exactly
        -- what the owner reported after playing on 2026-09-02 -- "some flying
        -- bags ... they were 'dollars' i could collect i think".
        --
        -- So each seeded drop gets a CONTAINER PROP under it: a vanilla
        -- `lootable_*` crate, case or toolbox, spawned through `Open77.props`
        -- and owned by this mode. The prop carries no interaction and no
        -- authority whatsoever -- the native prompt, the Take card, the
        -- distance check and the grant all remain the drop's, unchanged and
        -- already proven end to end. Removing the whole of this block leaves a
        -- working, uglier mode; that is the property it was built to have.
        --
        -- WHY THE ITEM SITS ON THE LID RATHER THAN INSIDE THE BOX.
        -- These hosts are SOLID (`docs/generated/prop-hosts.json` marks 116 of
        -- 184 with real collision, and every model named below is one of them).
        -- A drop spawned inside a solid crate would put the crate's geometry
        -- between the camera and the thing the interaction ray has to find. On
        -- the lid the item is in the open, at chest height instead of underfoot
        -- -- which also answers the one complaint the harness ever had about
        -- the native prompt: it could not aim at a bag lying on the player's
        -- own feet.
        --
        -- `heightMetres` IS AN ESTIMATE PER MODEL, not a measurement. Nothing
        -- on this platform reports a mesh's bounding box, so these are read off
        -- the vanilla objects by eye and they are the first thing to correct
        -- from a screenshot. The error is deliberately biased: `overlapMetres`
        -- sinks the item slightly INTO the lid, because an item a few
        -- centimetres inside a crate reads as sitting in it while an item a few
        -- centimetres above it reads as broken. Item drops have not been
        -- observed to fall onto anything, so gravity cannot be relied on to
        -- correct an underestimate.
        containers = {
            -- OFF, and this is a back-out rather than a design change.
            --
            -- Containers went in on 2026-09-02 because ground drops read as
            -- litter -- a money drop is a money shard, and the owner reported
            -- "some flying bags ... they were 'dollars'". They work: props=5
            -- projected=5, rendered, with the item sitting on the lid.
            --
            -- Then the owner looted one and the game crashed, at
            -- Cyberpunk2077.exe+0x53F9D4 -- the engine's pool allocator, reading
            -- an unaligned pointer (0x...621) while every valid pointer in the
            -- frame ended 008/000. That is heap corruption, and the prop
            -- lifecycle is what changed: before containers this mode created
            -- almost no props, and now it creates and destroys eighty-eight a
            -- match. Api::Props::ForgetNative skips the engine despawn when it
            -- is off the game thread but resets the handle anyway, orphaning the
            -- entity, and Api::Props::Remove has no thread guard at all while
            -- SetTransform beside it does.
            --
            -- BACK ON, under test. The dump was read on 2026-09-02 and the
            -- fault is now identified rather than guessed: Cyberpunk2077.exe
            -- +0x53F9D4 is the engine's deferred-free list drain, and it died
            -- reading a free-list link that was not 8-aligned -- a use-after-
            -- free WRITE into an already-released block, surfacing whenever the
            -- pool next drains. See docs/research/debugging-and-reverse.md.
            --
            -- The item sits on the crate's LID, so the two are in physics
            -- contact, and the pickup used to free both in the same frame.
            -- server/loot.lua now defers the container removal 1.5 s so they
            -- never coincide.
            --
            -- HONEST CAVEAT, unchanged: the same faulting address appears in a
            -- capture predating containers by a day and a half, so this may be
            -- removing the likeliest trigger of an older latent fault rather
            -- than its only cause. If looting crashes again, turn this off
            -- first -- the drop itself is unaffected and loot still works.
            enabled = true,
            -- A container per KIND, so the silhouette says what is in it before
            -- the Take card does -- a gun case reads as a gun from ten metres.
            -- Every alias below is a curated, collision-carrying host from
            -- `prop.catalog`; five of the six are the game's own `lootable_*`
            -- meshes, which is the shape a Cyberpunk player already knows.
            --
            -- The model strings here are ALSO how a stale container is
            -- recognised after a hot reload (see `L.clearContainers` in
            -- server/loot.lua), so this set must stay disjoint from every other
            -- prop this mode creates -- the cordon edge and the supply crate in
            -- particular. `supply.propMesh` above is a raw depot path rather
            -- than an alias, so it can never collide with a row of this table.
            models = {
                -- Mesh-space bounds decoded from the shipped 2.31 assets, metres.
                -- heightMetres is top Z relative to the prop origin; minZMetres
                -- seats ray-surveyed anchors without the legacy blanket sink.
                weapon  = { model = "military.case.large", heightMetres = 0.618113, minZMetres = -0.002643 },
                ammo    = { model = "container.ammo_case", heightMetres = 0.263543, minZMetres = 0.0 },
                plate   = { model = "military.case",       heightMetres = 0.602800, minZMetres = 0.000246 },
                heal    = { model = "medical.device",     heightMetres = 0.293998, minZMetres = -0.000363 },
                shield  = { model = "military.case",       heightMetres = 0.602800, minZMetres = 0.000246 },
                money   = { model = "container.safe",      heightMetres = 0.764439, minZMetres = 0.0 },
                default = { model = "crate.small",         heightMetres = 0.349009, minZMetres = -0.001295 },
            },
            -- How far the item is pushed back down into the lid. See above.
            overlapMetres = 0.08,
            -- Legacy walked anchors retain this sink. Explicit grounded=true
            -- clusters use the measured mesh minimum instead (no blanket sink).
            -- The container is sunk this far below the cluster anchor's height.
            -- The anchor is a walked probe and the only ground truth the server
            -- has -- there is no ground query in Lua on either side of the
            -- platform -- so a drop is placed at the anchor's z and is wrong by
            -- however much the surface moves underneath the scatter. Burying
            -- the container a few centimetres makes a small error read as "it
            -- settled into the dirt" instead of "it is hovering", which is the
            -- only defence available without a ray.
            sinkMetres = 0.06,
            -- Yaw is random so a cluster does not look like a warehouse shelf.
            randomYaw = true,
            -- Streaming. Tighter than the platform's 120 m default on purpose:
            -- at the plan's 900 drops these are 900 streamed engine entities
            -- with real VRAM behind them, and a crate is not worth seeing from
            -- further away than the drop on top of it.
            streamingRadius = 70.0,
            streamingHysteresis = 15.0,
            -- One resource may own 2,048 props (wiki/props.md) and this mode
            -- also spends props on the cordon edge and the supply crate. Past
            -- this many containers the drops keep being seeded and simply go
            -- bare, because a loot point with no gun is a broken match and a
            -- loot point with no crate is only a plain one.
            maxContainers = 1200,
        },
        -- ==================================================================
        -- TIERS
        -- ==================================================================
        --
        -- EVERY WEAPON RECORD BELOW WAS CHECKED AGAINST
        -- docs/generated/weapons-2.31.csv, ROW BY ROW, and every one satisfies:
        --
        --     canonical == True
        --     deprecated == False
        --     can_drop == True
        --     equip_area == "EquipmentArea.Weapon"
        --
        -- That last field is load-bearing rather than pedantic: the weapon API
        -- offers three slots and refuses grenades, heavy weapons and arm
        -- cyberware, and the arbiter cannot verify what it did not issue. A
        -- record outside `EquipmentArea.Weapon` in this table is a drop that
        -- picks up and then cannot be fired -- indistinguishable, to the player,
        -- from a broken mode.
        --
        -- Quality is a POOL PER TIER, not a stat roll (plan section 5). Nothing
        -- in this mode rolls damage: the ARBITER prices damage per weapon, so a
        -- legendary matters because the server says it does. Two players holding
        -- the same record always hit for the same number, which is the property
        -- that makes a fight readable.
        --
        -- `reserve` is what the gun ARRIVES with -- deliberately under the
        -- deathmatch's full-load numbers (Pistol 180 / SMG 240 / Rifle 240 /
        -- Shotgun 80 / Sniper 60 / LMG 360), because a battle royale wants you
        -- hunting ammo. Roughly half a load at tier 1, rising with tier.
        tiers = {
            -- ----------------------------------------------------------
            -- TIER 1 -- STREET. Everywhere. What you grab in the first ten
            -- seconds so that the first fight is a fight and not a chase.
            -- ----------------------------------------------------------
            {
                key = "street", label = "STREET",
                markShare = 0.55, dropsPerMark = { min = 1, max = 2 },
                kinds = { weapon = 20, ammo = 36, heal = 22, plate = 16, shield = 10, money = 6 },
                weapons = {
                    { key = "lexington", label = "M-10AF Lexington", category = "Pistol",   record = "Items.Preset_Lexington_Default", reserve = 90, weight = 20 },
                    { key = "unity",     label = "Unity",            category = "Pistol",   record = "Items.Preset_Unity_Default",     reserve = 90, weight = 20 },
                    { key = "nova",      label = "DR5 Nova",         category = "Revolver", record = "Items.Preset_Nova_Default",      reserve = 60, weight = 14 },
                    { key = "overture",  label = "Overture",         category = "Revolver", record = "Items.Preset_Overture_Default",  reserve = 60, weight = 10 },
                    { key = "saratoga",  label = "M221 Saratoga",    category = "SMG",      record = "Items.Preset_Saratoga_Default",  reserve = 120, weight = 18 },
                    { key = "pulsar",    label = "DS1 Pulsar",       category = "SMG",      record = "Items.Preset_Pulsar_Default",    reserve = 120, weight = 10 },
                    { key = "crusher",   label = "Crusher",          category = "Shotgun",  record = "Items.Preset_Crusher_Default",   reserve = 40, weight = 8 },
                },
            },
            -- ----------------------------------------------------------
            -- TIER 2 -- RARE. Named buildings and the edges of landing zones.
            -- The plan names Copperhead, Ajax and Carnage; the other three fill
            -- the categories those three leave empty so a tier-2 room is not
            -- three rifles.
            -- ----------------------------------------------------------
            {
                key = "rare", label = "RARE",
                markShare = 0.30, dropsPerMark = { min = 1, max = 3 },
                kinds = { weapon = 26, ammo = 32, heal = 22, plate = 18, shield = 12, money = 2 },
                weapons = {
                    { key = "copperhead", label = "D5 Copperhead",    category = "Assault rifle", record = "Items.Preset_Copperhead_Default", reserve = 150, weight = 18 },
                    { key = "ajax",       label = "M251s Ajax",       category = "Assault rifle", record = "Items.Preset_Ajax_Default",       reserve = 150, weight = 18 },
                    { key = "kyubi",      label = "Kyubi",            category = "Assault rifle", record = "Items.Preset_Kyubi_Default",      reserve = 150, weight = 10 },
                    { key = "carnage",    label = "Carnage",          category = "Shotgun",       record = "Items.Preset_Carnage_Default",    reserve = 48, weight = 16 },
                    { key = "zhuo",       label = "L-69 Zhuo",        category = "Shotgun",       record = "Items.Preset_Zhuo_Default",       reserve = 48, weight = 10 },
                    { key = "shingen",    label = "TKI-20 Shingen",   category = "SMG",           record = "Items.Preset_Shingen_Default",    reserve = 150, weight = 12 },
                    { key = "kolac",      label = "Kolac",            category = "Precision rifle", record = "Items.Preset_Kolac_Default",    reserve = 80, weight = 8 },
                    { key = "grad",       label = "SPT32 Grad",       category = "Sniper rifle",  record = "Items.Preset_Grad_Default",       reserve = 30, weight = 8 },
                },
            },
            -- ----------------------------------------------------------
            -- TIER 3 -- EPIC. Holdout sites and the "hot" landing zones. The
            -- plan names Achilles, Overwatch and Sidewinder; Overwatch is
            -- `Items.Preset_Grad_Panam`, which is worth stating because the
            -- record name and the in-game name share nothing.
            -- ----------------------------------------------------------
            {
                key = "epic", label = "EPIC",
                markShare = 0.12, dropsPerMark = { min = 2, max = 3 },
                kinds = { weapon = 34, ammo = 28, heal = 20, plate = 18, shield = 14, money = 0 },
                weapons = {
                    { key = "achilles",   label = "M-179e Achilles",  category = "Precision rifle", record = "Items.Preset_Achilles_Default",  reserve = 100, weight = 18 },
                    { key = "sidewinder", label = "D5 Sidewinder",    category = "Assault rifle",   record = "Items.Preset_Sidewinder_Default", reserve = 180, weight = 18 },
                    { key = "masamune",   label = "HJSH-18 Masamune", category = "Assault rifle",   record = "Items.Preset_Masamune_Default",   reserve = 180, weight = 14 },
                    { key = "overwatch",  label = "Overwatch",        category = "Sniper rifle",    record = "Items.Preset_Grad_Panam",         reserve = 40, weight = 14 },
                    { key = "nekomata",   label = "Nekomata",         category = "Sniper rifle",    record = "Items.Preset_Nekomata_Default",   reserve = 40, weight = 12 },
                    { key = "tactician",  label = "M2038 Tactician",  category = "Shotgun",         record = "Items.Preset_Tactician_Default",  reserve = 60, weight = 12 },
                    { key = "defender",   label = "M2067 Defender",   category = "LMG",             record = "Items.Preset_Defender_Default",   reserve = 240, weight = 12 },
                },
            },
            -- ----------------------------------------------------------
            -- TIER 4 -- LEGENDARY. Holdouts and supply crates ONLY -- there are
            -- no tier-4 marks in the open (plan section 5). Five records, which
            -- is the plan's "a pool of five", with Comrade's Hammer and Ashura
            -- named in it.
            --
            -- Comrade's Hammer is `Items.Preset_Burya_Comrade`. The catalogue
            -- lists it under its French display name ("Marteau du Camarade"),
            -- which is why searching the canonical page for "Comrade" finds
            -- nothing; it was verified by record, not by name.
            -- ----------------------------------------------------------
            {
                key = "legendary", label = "LEGENDARY",
                markShare = 0.03, dropsPerMark = { min = 2, max = 4 },
                kinds = { weapon = 50, ammo = 20, heal = 15, plate = 15, shield = 12, money = 0 },
                holdoutAndSupplyOnly = true,
                weapons = {
                    { key = "comrade",  label = "Comrade's Hammer", category = "Revolver",      record = "Items.Preset_Burya_Comrade",  reserve = 48, weight = 20 },
                    { key = "ashura",   label = "Ashura",           category = "Sniper rifle",  record = "Items.Preset_Ashura_Default", reserve = 40, weight = 20 },
                    { key = "baxing",   label = "Ba Xing Chong",    category = "Shotgun",       record = "Items.Preset_Zhuo_Eight_Star", reserve = 60, weight = 20 },
                    { key = "kyubixmod", label = "Kyubi x-MOD2",    category = "Assault rifle", record = "Items.Preset_Kyubi_Legendary", reserve = 200, weight = 20 },
                    { key = "pozharxmod", label = "Pozhar x-MOD2",  category = "Shotgun",       record = "Items.Preset_Pozhar_Legendary", reserve = 60, weight = 20 },
                },
            },
        },
    },
    -- ======================================================================
    -- INVENTORY -- what a player can carry (plan section 5)
    -- ======================================================================
    --
    -- The weapon API offers exactly three slots and refuses grenades, heavy
    -- weapons and cyberware, so the inventory is not a design space -- it is the
    -- shape of the platform, written down. What IS a design choice is the plate
    -- and heal economy, and every number in it is a first guess.
    inventory = {
        weaponSlots = 3,
        -- Armour comes only from plates, so the ceiling is arithmetic: 3 x 25 =
        -- 75, which is the plan's "armor 0-75". Do not raise `plateMax` without
        -- moving the combat model's armour ceiling with it.
        plateValue = 25,
        plateMax = 3,
        -- 40 HP per heal against a 100 HP ledger with NO REGEN: three heals is
        -- a full recovery and four is one spare. GUESS -- it has never been
        -- played. The direction to move it is down, because a mode where you
        -- carry four full heals is a mode where fights do not resolve.
        healValue = 40,
        healMax = 4,
        -- Both are HELD keys running a SERVER timer, and both are interrupted by
        -- incoming damage. The hold is the whole risk: standing still for three
        -- seconds in the open is the price of the armour, and a heal that
        -- completed on the client would be a heal that cannot be contested.
        plateApplyMs = 3000,
        healMs = 4000,
        interruptOnDamage = true,
        -- Picking up a weapon with all three slots full swaps the ACTIVE slot,
        -- and the displaced weapon is re-created as a drop where you stand. The
        -- alternative -- refusing the pickup -- makes a legendary you cannot
        -- take, which reads as a bug every single time.
        swapDropsDisplaced = true,
        -- Health is a flat 100 with no regeneration. Stated here because the
        -- HUD, the plate arithmetic above and the cordon damage rates all assume
        -- it, and three files assuming a number that lives in none of them is
        -- how a rebalance goes wrong.
        maxHealth = 100,
        healthRegen = false,
    },
    -- ======================================================================
    -- SQUADS (plan section 6)
    -- ======================================================================
    squads = {
        -- Party first, then the emptiest squad. A party is an INVITE CODE shown
        -- on the staging panel and nothing more in v1 -- no persistence, no
        -- friends list, no cross-match memory. The code exists so four people in
        -- a voice call can land together, which is the entire requirement.
        fillPolicy = "party_then_emptiest",
        inviteCodeLength = 5,
        -- Team ids are RE-APPLIED at every placement, not set once.
        -- `Open77.combat.setTeam` surviving a `kill -> respawn` is arena E12 and
        -- is STILL UNMEASURED; plan decision "re-apply regardless" is the cheap
        -- side of that bet, and the expensive side is a squadmate killing you
        -- through friendly fire the platform thought it had cancelled.
        reapplyTeamOnEveryPlacement = true,
        -- --------------------------------------------------------------
        -- REVIVE AT THE BODY (plan decision 4)
        -- --------------------------------------------------------------
        --
        -- What there is, is `Open77.players.revive`. So a flatlined squadmate is
        -- a corpse with a window on it, and a living squadmate holding E over
        -- it. The body's last authoritative position is the revive point, and E7
        -- (body persistence and position readability while dead) is still
        -- unmeasured.
        --
        -- THE OLD RATIONALE HERE SAID "no way to freeze a player", AND THAT IS
        -- NOT WHAT IS WRONG. Read alongside squads.lua's header, which says the
        -- same thing, it sent everybody looking for a mechanism to BUILD. The
        -- mechanism already exists and it is already wired to exactly this
        -- state: `Open77MultiplayerPolicy.reds:1822-1831` consumes the whole
        -- gameplay action stream whenever `Open77SoftDeathActive()` is true, and
        -- that native is `LifeReplication::IsLocalSoftDead()` -- Dead,
        -- RevivePending or RespawnPending. Its own comment claims it "blocks
        -- movement, combat, interactions and vehicle entry".
        --
        -- It does not block movement, and the proof is six lines below it in the
        -- same file: the hip-fire refusal that used to live at that hook "never
        -- ran once", because the game POLLS fire from the state machine instead
        -- of dispatching it as an action. Locomotion is polled the same way --
        -- `defaultTransition.script:783-784` reads `GetActionValue('MoveX')` and
        -- `('MoveY')` -- while `PlayerPuppet.OnAction` only ever sees named
        -- buttons (`ToggleWalk`, `CallVehicle`, `PocketRadio`;
        -- player.script:1318-1378). Consuming the action stream cannot reach an
        -- axis nobody dispatches. So a downed player walks.
        --
        -- The owner reported it as a question -- "i can still move? i should be
        -- stuck on the floor right?" -- and the answer is yes. It is not a Lua
        -- fix: vanilla's own pin is the status effect
        -- `GameplayRestriction.NoMovement` (highLevelTransitions.script:11-21,
        -- applied on entering the ground-death state at :690-694), and no
        -- Open77 binding on either side of the wire can apply a status effect.
        -- It is a redscript change, and a small one, because
        -- `Open77SafeAreaPolicy.reds:235-252` already does exactly this call
        -- from an Open77-owned 0.20 s tick. Until it is built and deployed,
        -- everything below governs a body that can still walk away.
        reviveWindowSeconds = 60,
        -- Successive downings in the same match shorten both rescue windows.
        downedWindowSeconds = { 60, 45, 30, 20, 15 },
        reviveHoldSeconds = 5,
        revivePromptRadiusMetres = 2.5,
        -- Revived at 30 of 100 with no armour: alive, and losing the next fight
        -- unless somebody covers you. A full-health revive would make the
        -- window a formality.
        reviveHealth = 30,
        -- Ghosted for the grace so the body does not block the reviver, then
        -- solid. `graceMs` is passed straight to `players.revive`.
        reviveGraceMs = 2000,
        -- The revive is cancelled by damage to EITHER party. Cancelling only on
        -- the reviver's damage lets a squad revive under fire by tanking with
        -- the corpse, which is not a play anybody should discover.
        reviveCancelOnDamage = true,
        -- --------------------------------------------------------------
        -- BLEEDING OUT IN THE CORDON
        -- --------------------------------------------------------------
        --
        -- How much faster a body that fell OUTSIDE the open blocks runs out of
        -- time. The cordon used to ignore the downed entirely -- `C.tick`
        -- iterates `K.alive()` -- so going down in the bleed was the one
        -- reliable way to stop bleeding, and a squad could park a corpse out
        -- there indefinitely.
        --
        -- It shortens the ONE deadline the body already has (the revive window,
        -- or the elimination hold when nobody can come) rather than opening a
        -- second damage stream on a corpse the platform already floors at 0.01
        -- health. One clock, so the HUD's revive bar cannot disagree with the
        -- sweep that is actually watching.
        --
        -- 3.0 turns a 30 s window into 10 s and an 8 s hold into 2.6 s: long
        -- enough that a squadmate who is already close can still make the call,
        -- short enough that the ring is a reason not to be there. 1.0 disables
        -- it. `server/match.lua` -> `M.armBleedOut` is the whole of it.
        bleedOutCordonFactor = 3.0,
        -- --------------------------------------------------------------
        -- PINGS
        -- --------------------------------------------------------------
        --
        -- There is no raycast API, so a ping is `camera.view()` forward x 40 m:
        -- it marks a DISTANCE, not a surface. Aim at a wall two metres away and
        -- the ping lands inside the building. That is a known and accepted
        -- imprecision; the tac-map click, which pings a BLOCK, is the precise
        -- channel.
        pingDistanceMetres = 40,
        pingCooldownMs = 4000,
        pingTtlMs = 12000,
        -- Rendered with `Open77.anchors` `render = "dot"` -- native per-frame
        -- projection, 32 anchors per resource. ONE ping per player at a time is
        -- therefore not politeness, it is the quota: 64 players with three pings
        -- each is 192 anchors against a cap of 32.
        pingsPerPlayer = 1,
        -- A `party` voice channel per squad, membership maintained on every
        -- roster change and torn down at match end. A channel that outlives its
        -- squad is a channel two enemies end up talking on.
        voiceChannel = true,
        -- Spectating: "ghost" if E4 says a ghosted + god-moded + noclipping
        -- unarmed player is invisible and harmless, "staging" otherwise. E4 is
        -- BLOCKED and unmeasured, so the default is the one that needs no
        -- platform behaviour to be true.
        spectateMode = "staging",
    },
    -- ======================================================================
    -- BOTS -- contestants that fill a match players did not fill (section 8.1)
    -- ======================================================================
    --
    -- A 64-slot battle royale with nine people in it is not a battle royale. It
    -- is this mode's worst failure case and its most likely one, and it is also
    -- why the mode can be developed at real size on a workstation where VRAM
    -- caps real clients at three.
    --
    -- Everything structural here is COPIED from
    -- `open77_deathmatch/server/bots.lua`, which is 4,584 lines of this problem
    -- already solved and already played. Server resources cannot link, so
    -- copying is the documented sharing mechanism. Each of the values below was
    -- paid for by a real failure over there; none of them is a fresh opinion.
    bots = {
        -- WHAT ONE REPORTED HIT TAKES OFF A BOT.
        --
        -- The engine reports that a bot was hit and reports the damage as ZERO
        -- (measured: `hits=457 zeroDamage=457`), so the mode supplies the
        -- number. Three body shots or two head shots at these values.
        hitDamage = 34.0,
        headshotMultiplier = 2.0,
        headHeight = 1.5,
        maxHitDamage = 200.0,
        -- --------------------------------------------------------------
        -- BACKFILL POLICY -- where this mode DEPARTS from the deathmatch
        -- --------------------------------------------------------------
        --
        -- Bots are opt-in. Operators can enable backfill for testing or for
        -- a small roster; the default runs with human contestants only.
        --
        --   off        never; the match runs with whoever is there
        --   threshold  fill to `fillTarget` only when humans < `fillFloor`
        --   always     fill every empty slot to the format's capacity
        --
        botFill = "off",
        fillTarget = 40,
        fillFloor = 24,
        -- Bots are added at the END of staging, before deploy, so the drop map
        -- shows a real headcount. The fill is recomputed per match and NEVER
        -- mid-match: a bot appearing at minute six is a bot appearing out of
        -- nothing in front of somebody.
        fillAtStagingEnd = true,
        refillMidMatch = false,
        -- --------------------------------------------------------------
        -- THE THREE GANGS, and the one alias that must never join them
        -- --------------------------------------------------------------
        --
        -- One faction is one side, and one side does not fight. Under native
        -- combat, "bots must also kill each other" is not something this mode
        -- scripts -- it is a question about two records that the engine's own
        -- attitude matrix answers, and it can only answer yes if the records
        -- belong to different gangs. Bots are round-robined across this list, so
        -- a roster of thirty-nine is thirteen of each.
        --
        -- `civilian_female_relaxed_01` IS NOT HERE AND MUST NEVER BE. It
        -- resolves to `Character.Panam`, which carries the TweakDB tag
        -- `Invulnerable` -- vanilla quest protection that no attitude change, no
        -- damage policy and no Lua call can lift. The deathmatch's list once
        -- named it, `bots.lua` round-robined it, and HALF EVERY ROSTER WAS
        -- UNSHOOTABLE. That was the whole of "I cannot fire on the bot", and it
        -- also invalidated the Phase 0 experiment that concluded players cannot
        -- damage NPCs at all: the decisive shots were fired at a protected story
        -- character. She is independently unsafe here too -- driving the weapon
        -- path against her native graph corrupts a component vtable
        -- (Cyberpunk2077.exe+0x336376).
        templates = {
            "hostile_female_ranged_lab",   -- Maelstrom
            "gang_valentinos_ranged_01",   -- Valentinos
            "gang_tygerclaws_ranged_01",   -- Tyger Claws
        },
        -- Two rules that are not negotiable, and both are enforced at the WRITE
        -- rather than filtered at the read. A player who cannot tell whether
        -- they just won against people has been cheated of the only thing this
        -- mode sells.
        labelled = true,
        excludeMatchesFromLadder = true,
        -- Negative participant ids, bound twice: the negative id in the roster,
        -- the uint64 npc id in an alias table. Scoring, standings and the feed
        -- then need no special case -- but FIVE PLAYER BINDINGS RAISE on a
        -- non-positive id, so `members` and `humans` must stay separate
        -- everywhere in the server code. That is the trap this comment exists
        -- to keep warm.
        negativeParticipantIds = true,
        difficulty = "standard",
        combat = {
            -- `native` means THE ENGINE FIGHTS AND THIS MODE REPLICATES. No
            -- scripted targeting, no `moveTo` stream, no damage on a timer. A
            -- scripted damage layer on a spawned hostile record is a SECOND
            -- combat system on one body: hits through walls, no animation, and
            -- it cancels the behaviour tree. Never reintroduce one.
            mode = "native",
            -- Owner-reports, not witness-reports: `open77:npcHit` on the
            -- shooter, `open77:npcAttackedMe` on the victim, crossfire on the
            -- lease holder. Every client streaming a bot runs its own copy of
            -- that bot's AI, so crediting a witness credits one burst once per
            -- spectator -- and with 40 bots across 64 clients that is not a
            -- rounding error, it is a scoreboard made of noise.
            ownerReportsOnly = true,
            forceWeapon = true,
            incoming = {
                -- Kept TRUE though it currently selects nothing: measured
                -- 2026-09-01 on the deathmatch, the engine reports ZERO damage
                -- on 100% of these hits (52 of 52), so `fallbackDamage` is
                -- pricing the entire fight. The day the real numbers are
                -- recovered this is the switch that starts using them, and
                -- setting it false now would hide that they had arrived.
                useEngineAmount = true,
                scale = 1.0,
                -- THE CLAMPS ARE NOT OPTIONAL. A gang record's rifle is priced
                -- for a levelled solo player; this mode's health is a
                -- hundred-point scale. Unclamped, one burst is a kill.
                maxPerHit = 34.0,
                fallbackDamage = 18.0,
                -- Per victim, across ALL bots. The per-hit clamp bounds one
                -- bullet; nothing upstream bounds six bots converging -- and in
                -- a closing cordon, six bots converging is the normal case
                -- rather than the edge one.
                maxDamagePerSecond = 90.0,
                -- Per (victim, bot) pair.
                minIntervalMs = 90,
            },
        },
        -- --------------------------------------------------------------
        -- SPAWN PACING -- the gate that is not optional at this scale
        -- --------------------------------------------------------------
        --
        -- 40 bots is six times what the arena ever spawned at once. The queue is
        -- drained one body per tick, 400 ms apart, and nothing is issued to a
        -- body for 5 s after it lands.
        spawn = {
            settleMs = 5000,
            spacingMs = 400,
            perTick = 1,
            -- Rebuild on respawn, never move: the client does not withhold
            -- `NpcMotion` during a placement, so a bot dragged with
            -- `setTransform` arrives twice.
            rebuildOnRespawn = true,
        },
        -- --------------------------------------------------------------
        -- THE CORDON AND THE BOT
        -- --------------------------------------------------------------
        --
        -- A bot obeys the cordon: same per-phase bleed, same death. Between
        -- closures it is issued ONE `moveTo` toward a point inside the next
        -- cordon -- ONCE PER CLOSURE, NOT STREAMED. Re-issuing movement on a
        -- tick cancels the behaviour tree the engine is using to fight
        -- (measured in the arena as F13: a bot could not take cover or break
        -- contact). A bot already inside the next cordon is given nothing at all
        -- and left to the engine.
        cordon = {
            moveToPerClosure = true,
            -- Where inside the next cordon it is sent. A guess, and the number
            -- to move if bots pile onto the final block's centre: further in is
            -- safer for the bot and more boring for the player who meets it.
            insetMetres = 25.0,
            -- Bots do not loot (plan section 8.1). Ground loot, plates and heals
            -- are a PLAYER economy; giving bots an inventory doubles the surface
            -- for no gain, and a bot carrying a looted legendary is a
            -- scoreboard entry nobody can explain.
            loots = false,
        },
        -- --------------------------------------------------------------
        -- LEASH
        -- --------------------------------------------------------------
        --
        -- Subordinate to the one-moveTo-per-closure rule above: this fires only
        -- for a bot the cordon has left behind entirely, and its soft correction
        -- IS a `moveTo`, so it competes with the closure move by construction.
        -- Hence the long interval and the high sample counts -- this must be
        -- rare or it becomes the movement stream F13 forbids.
        --
        -- "Frozen without a witness is EXPECTED": NPC navigation needs a client
        -- authority lease, so a bot alone in a corner of a 2 km^2 map does not
        -- move. That is correct and cheap. A leash that fights it would spend
        -- the whole match issuing corrections nobody can see.
        leash = {
            enabled = true,
            intervalMs = 1000,
            softSamples = 3,          -- ~3 s outside before a moveTo back in
            hardSamples = 10,         -- ~10 s before a setTransform, which revokes the lease
            insetMetres = 8.0,
            -- Beyond this it is a placement, not a correction: respawned on a
            -- surveyed mark rather than dragged through whatever is in between.
            -- 250 m rather than the arena's 60 m because a block is 100 m wide
            -- and the arena's number would trigger inside one.
            teleportLimitM = 250.0,
        },
    },
    -- ======================================================================
    -- CORDON -- the tick, the hold rule, and the one damage kind that works
    -- ======================================================================
    cordon = {
        -- 4 Hz. 64 players x 4 Hz x up to 196 blocks is under 50 k box tests per
        -- second in Lua, which is noise against the measured 14 ms scheduler
        -- latency. The closure schedule is precomputed at match start into one
        -- ordered list of block ids with a close time each, so the tick does one
        -- comparison per block per step rather than re-deriving the geometry.
        tickHz = 4,
        -- --------------------------------------------------------------
        -- THE HOLD RULE -- "held for N samples", never judged on one
        -- --------------------------------------------------------------
        --
        -- Containment keeps the deathmatch's contract: THREE answers, `inside` /
        -- `outside` / cannot tell. An unreadable position FREEZES the damage
        -- accumulator rather than deciding either way, so a player can neither
        -- be bled across a replication gap nor clear the accumulator by causing
        -- one.
        --
        -- Two samples at 4 Hz is 500 ms of confirmed "outside" before the first
        -- tick of damage. Small, because unlike the deathmatch's backstop this
        -- is not a placement -- being wrong costs a fraction of a second of
        -- health, and being slow costs the boundary its teeth.
        holdSamples = 2,
        -- --------------------------------------------------------------
        -- THE DAMAGE KIND. THIS IS A MEASUREMENT, NOT A CHOICE.
        -- --------------------------------------------------------------
        --
        -- E5, 2026-09-02: `Open77.players.damage(id, 20, { kind = "environment" })`
        -- returns true, health goes 100 -> 80, and the server emits
        -- `playerDamaged victim=65 attacker=0 amount=20.00 kind=environment`.
        -- One call, attributed to attacker 0, carrying everything a kill feed
        -- needs.
        --
        -- THE TRAP THAT COST TWO RUNS, and it will catch the next person:
        -- `players.damage`'s `cause` option is NOT a free-text cause. The Lua
        -- wrapper reads
        --
        --     DamagePlayer(playerId, amount, options.attacker,
        --                  options.cause or options.kind, options.weapon)
        --
        -- so `cause` is read FIRST and both feed the engine's ATTACK KIND parser
        -- (`TryParseAttackKind`: ranged / firearm / melee / explosion /
        -- quickhack / environment / fall / unknown / script). The plan's own
        -- `{ cause = "cordon" }` returns `false invalid_argument`, and so does a
        -- table carrying BOTH `kind` and `cause`, because `cause` wins. Pass
        -- only `kind`.
        damageKind = "environment",
        -- The bleed has no attributed attacker, so `open77:localDamaged` will
        -- not fire on the client and the red edge vignette gets nothing from the
        -- platform. The mode pushes its own event. (Inference from E5; the
        -- observational half is the one piece of E5 still open.)
        hurtEvent = "cordon:hurt",
        -- How long before a closure the warning shows on the HUD and the
        -- tac-map. Plan section 2 puts the first warning at 2:00 for a 2:30
        -- closure.
        warnSeconds = 30,
        -- A cordon kill is credited to the last player who damaged the victim in
        -- this window; otherwise to the cordon. The feed says which, and saying
        -- which is the point -- a kill that silently belonged to nobody looks
        -- like a lost kill to the player who did 95 damage.
        killCreditWindowSeconds = 10,
        -- NOBODY IS WALLED (plan decision 3). No client clamp, no backstop
        -- placement, no exceptions -- running through the cordon to flank is a
        -- legitimate play and the bleed is its price. Vehicles do not protect
        -- you either: the seat does not matter, the position does.
        walled = false,
        vehiclesProtect = false,
        -- Bounds are pushed to clients ON EACH BLOCK CLOSURE, not every tick.
        -- A net event is <=32 args and 48 KiB with no interest filter, so a
        -- broadcast is 64 sends; at 4 Hz that is 256 sends a second of a list
        -- that changed once.
        pushBoundsOnClosureOnly = true,
        -- How often, at most, that push may actually leave. The closure loop can
        -- retire several cells inside one 4 Hz tick, and the bounds message
        -- carries the WHOLE open-cell list -- so on a large lattice an
        -- unthrottled publish would send the same kilobyte to sixty-four players
        -- four times a second to describe a boundary that has moved one cell.
        -- A closure that reaches the tac-map a fifth of a second late is
        -- invisible; containment is decided on the server either way. The two
        -- edges that must never be late -- a phase turning over and the
        -- timetable emptying -- bypass this.
        publishMinIntervalMs = 500,
        -- ==================================================================
        -- THE LATTICE -- what the cordon actually closes
        -- ==================================================================
        --
        -- THE CLOSING UNIT IS NOT THE SURVEYED BLOCK. The survey grid is as
        -- coarse as the ground somebody walked: Watson is 2x2, four 100 m cells,
        -- which offers the cordon exactly three closures on a 200 m district.
        -- That is a guillotine, not a shrinking zone, and no retiming fixes it.
        --
        -- So `Grid.subdivide` splits every block `factor` ways on each axis and
        -- the cordon closes the result. Watson becomes an 8x8 of 25 m cells; a
        -- 9x5 Pacifica becomes 18x10 at 50 m; a 14x14 map is already fine and
        -- gets factor 1, i.e. exactly the geometry the plan describes.
        --
        -- IT IS INVISIBLE TO EVERY CLIENT, which is the reason it was done this
        -- way rather than as a second shape. The tac-map and the in-world edge
        -- both derive everything they draw from the origin, cols, rows and block
        -- size the SERVER sends them, so publishing the lattice as "the grid"
        -- subdivides both of them and not one client file changed.
        --
        -- The map is still authored in blocks: loot marks, landing zones, the
        -- final-block whitelist and the per-block heights are all keyed by the
        -- surveyed cell, and `Grid.expandKeys` / `Grid.expandCellTable` are the
        -- one seam where a block key becomes lattice keys.
        lattice = {
            -- False restores the pre-2026-09-02 behaviour exactly: the cordon
            -- closes surveyed blocks. Kept as a one-line way to answer "is this
            -- the lattice's fault?" without reverting anything.
            enabled = true,
            -- The shortest side of the lattice, in cells. Eight is what makes a
            -- schedule possible at all: it gives four Chebyshev rings around a
            -- central final cell and seven around a corner one, and a closure
            -- reads as a zone converging rather than as a wall falling somewhere
            -- around the fourth ring.
            minCellsPerSide = 8,
            -- The smallest final zone the mode is willing to produce, and the
            -- cap that stops `minCellsPerSide` from subdividing a tiny map into
            -- a corridor. Below about twenty metres the last fight stops being a
            -- fight -- two players spawn-camping a doorway is not a finale.
            minCellMetres = 20.0,
            -- The wire. The open-cell list is published as an array of
            -- "col,row" strings on every closure; a net event caps at 48 KiB
            -- (wiki/server-api.md) and 1024 keys is roughly 8 KB, so this leaves
            -- an order of magnitude of headroom. It also bounds the closure
            -- queue, which is one entry per cell.
            maxCells = 1024,
        },
        -- WHERE THE LAST ZONE MAY BE. Two rules, in `finalCandidates` and
        -- `pickFinal` (server/cordon.lua), both rewritten on 2026-09-04 after
        -- the owner reported that "le cercle se ferme toujours au meme endroit
        -- sur les meme bloc" -- and measured to be right: Watson's whitelist
        -- was two adjacent blocks, and the old candidate rule (centre cells
        -- only, then filtered to walked ones) put all eight candidates in the
        -- west three-eighths of the lattice.
        --
        -- The candidates are now EVERY walked cell of every whitelisted block
        -- -- a cell holding a landing zone, a loot anchor, a landmark, a supply
        -- mark or a walked ground sample. Somebody stood there, which is the
        -- whole criterion. `finalJitterCells` only governs the FALLBACK for a
        -- block nobody has put a point in: the cells within this many of the
        -- block's centre, clipped to the block, because the middle of an
        -- unwalked block is the least-bad guess about its ground and a corner
        -- cell is a coin flip on a wall, a roof or the water.
        finalJitterCells = 1,
        -- How many previous finals a new match refuses to repeat, when it has
        -- the choice. A uniform draw over fourteen cells repeats one match in
        -- fourteen; an evening of ten matches notices that. Three means the
        -- same cell cannot come up twice within four matches, and on top of it
        -- the server prefers a candidate in a different BLOCK from the last
        -- final whenever one exists -- two cells of the same block are the same
        -- ending to a player, because the rings close on the same streets.
        -- Never refuses: a single-candidate map plays the same ending, and says
        -- `candidates=1` in the "cordon armed" log line. Zero disables the
        -- memory. Remembered for the server process only.
        finalRepeatMemory = 3,
        -- ==================================================================
        -- THE EDGE -- what the boundary looks like, in the world and on screen
        -- ==================================================================
        --
        -- The shipped world boundary uses the base game's animated AWACS
        -- hologram (neon.holo_zone). Persistent client-local VFX instances move
        -- along the same shrinking rectangle, clipped to the surveyed allowed
        -- cells, that the server uses for damage. They have no collision and
        -- require no replicated props. Motion, visibility from both sides and
        -- damage after the front passes a stationary player were proven live.
        --
        -- The authored effect fades around 50 metres; increasing its planning
        -- radius does not make it a 300-metre wall. Distant guidance comes from
        -- the HUD and exact moving outline on the tac-map. The sweep block
        -- bounds instance count and work per frame. An unavailable or failed
        -- renderer leaves HUD guidance; it must not display a frozen boundary.
        --
        -- The prop, lamp, fire and projected-wall settings below are retained
        -- for the LEGACY whole-cell renderer and its fallback configurations.
        -- Their historical measurements do not describe the shipped sweep.
        -- While an authoritative continuous sweep is present, that legacy
        -- geometry is suppressed so it cannot contradict the damage boundary.
        -- edge.style still controls the world layer: world enables it; hud/off
        -- retire its instances. Outside warnings remain authoritative.
        --
        -- Asset evidence, earlier barricade/Blackwall probes, live screenshots
        -- and rendering limits: docs/research/vfx-sfx-runtime.md. Earlier
        -- whole-cell experiments: docs/research/battle-royale-and-scale.md.
        edgeStyle = "world",
        edge = {
            -- Base-game animated holograms follow the authoritative moving front.
            -- Live-tested from both sides; authored fade is about 50 metres.
            sweep = { enabled = true, effect = "neon.holo_zone", radius = 60,
                spacing = 9, maxInstances = 24, heightOffset = 0, yawOffset = 90 },
            -- The master switch, and also the `cordonEdge` tunable so an
            -- operator can turn the world layer off from the Warden panel
            -- without a resource reload. Three values:
            --   "off"    no world edge and no screen rim. It does NOT remove
            --            the OUTSIDE THE CORDON banner or the compass: those
            --            are the readout, not the decoration, and the compass
            --            is the only thing on screen telling a bleeding player
            --            which way to run. An off switch for a visual effect
            --            must never strip a player of the information they need
            --            to survive it.
            --   "hud"    screen only. The recorded fallback, and still a
            --            playable mode: Warzone-era players accept it and
            --            Apex's players never had anything else.
            --   "world"  screen plus the in-world edge
            style = "world",

            -- ----------------------------------------------------------
            -- THE WORLD LAYER
            -- ----------------------------------------------------------
            --
            -- EVERY NUMBER HERE IS A BUDGET, not a taste. The client runtime
            -- caps a resource at 64 VFX (`kPerOwnerLimit`, client/src/api/Effects.cpp)
            -- and 256 props (the same name in Props.cpp), and the prop
            -- registry's GLOBAL cap of 1024 is shared with the loot containers
            -- this mode projects. The arithmetic for the defaults below is at
            -- `maxTotalPosts`: about 150 props and 32 effects in the ordinary
            -- case, never more than ~225 props and ~44 effects with the
            -- hysteresis full.

            -- Only segments this close are drawn at all. 150 m is chosen against
            -- the block size: standing at the centre of a 100 m block, the four
            -- edges of your own block are 50 m away and the next ring is 150,
            -- so this draws your own block's boundary and the one beyond it and
            -- stops. Raising it past ~250 m buys nothing a 50 m column does not
            -- already give for free.
            drawRadiusMetres = 150.0,
            -- Hard caps under the radius. `maxSegments` bounds the work;
            -- `maxPosts` bounds the quota. Both are reached before either
            -- engine limit is.
            -- SIXTEEN, not four, and the change is what keeps the edge the
            -- same density at every lattice pitch. `maxPosts` is the real cap;
            -- `maxSegments` only bounds how many boundary lines are considered.
            -- At 100 m cells four segments already fill the sixteen posts
            -- (`round(100 / spacing)` = 4 posts each), so this changes nothing
            -- there -- but at Watson's 25 m lattice a segment carries ONE post,
            -- and four segments would have drawn a hundred metres of boundary
            -- instead of four hundred. Sixteen segments x one post is the same
            -- sixteen posts over the same four hundred metres, at every scale,
            -- with no per-map number to keep in step.
            maxSegments = 16,
            -- THE PLACEMENT IS THREE PASSES (client/edge.lua, `scanFinish`), by
            -- distance RANK and not by radius:
            --
            --   1. the MARKERS: one post at the middle of every segment in
            --      range, the skeleton that keeps a distant boundary continuous
            --      (perspective closes a lattice-pitch gap on its own at a
            --      hundred metres);
            --   2. the RAMPART: the nearest `wallPosts` slots, every one of
            --      them, nearest segment first, WHATEVER THEIR DISTANCE;
            --   3. the FILL: every `fillStride`-th remaining slot, nearest
            --      first, until `maxPosts`.
            --
            -- WHY RANK AND NOT RADIUS. The previous `denseRadiusMetres = 45`
            -- filled only segments inside 45 m, and the owner's whole match ran
            -- with the nearest post at 54 m: the curtain never existed and he
            -- saw sixteen markers, one per cell. A player can only look at one
            -- arc of the boundary at a time, and the arc in front of him is by
            -- definition the nearest one, so the wall is put THERE, at five
            -- metres or at a hundred and forty.
            --
            -- FORTY wall slots at a 2 m pitch is about eighty metres of
            -- continuous rampart: 77 degrees of the view when seen square-on
            -- from fifty metres, the whole width of the screen. On Watson's
            -- 25 m lattice that is three segments and a bit; on Pacifica's
            -- 100 m blocks it is most of one. Both read as "the street in front
            -- of me is walled".
            wallPosts = 40,
            -- Beyond the near line, one FILL post every this-many slots. Since
            -- the eighth round a fill post is a red LAMP (`beacon.fill`), not a
            -- roadblock: four slots is an 8 m pitch, and a lamp with a 10 m
            -- pool every 8 m is a continuous red glow along the tarmac out to
            -- the draw radius. Two was the roadblock's pitch and is the first
            -- number to lower if the far line reads too sparse -- at the cost
            -- of real-time lights, which is the budget that actually binds
            -- now (see `maxTotalPosts`).
            fillStride = 4,
            -- EIGHTY: 16 markers, 40 near-line slots, 24 fill slots. Spent
            -- where the player is looking, not spread evenly. The second line
            -- (`next.maxPosts`) is counted separately.
            --
            -- It is also the first number to LOWER if the client log starts
            -- carrying "a rebuild pass failed": the plan build is one small
            -- table per post (integer keys since the sixth round, no
            -- `string.format`), on a pass of its own after the candidate sort,
            -- and it is the one place in edge.lua whose cost scales with this
            -- table.
            maxPosts = 80,
            -- The ceiling on what the hysteresis may HOLD, counted against the
            -- plan. A post that has merely fallen out of the nearest set is kept
            -- while it is still within `holdRadiusFactor` of the draw radius --
            -- that is what stopped the layer creating 206 light hosts in one
            -- session for a sixteen-post edge -- and this bounds how far that can
            -- run. Raised from 100 to 120 for the second line, which is up to
            -- `next.maxPosts` more posts than the plan carried before.
            --
            -- THE PROP ARITHMETIC (eighth round), against the client's
            -- 256-per-resource limit. No post carries a mesh any more; every
            -- prop below is a light host except the strip:
            --
            --   markers    16 x 1 light (the red pool)               = 16
            --   near line  40 slots: 20 lamps (odd slots) + 20 strips  = 40
            --   fill       24 x 1 lamp                                = 24
            --   next line  up to `next.maxPosts` = 24 amber lamps     = 24
            --                                                  planned 104
            --
            -- With the hysteresis full (120 posts) that is at most ~130 props,
            -- half the cap. THE NUMBER THAT ACTUALLY BINDS IS REAL-TIME LIGHTS:
            -- 16 + 20 + 24 + 24 = 84 point lights planned, against the 33 the
            -- owner's client ran on 2026-09-04 without complaint. It is
            -- UNMEASURED past that. All four counts are on the status line
            -- (`lights= lamps= nexts=`); if a client's frame rate drops at the
            -- boundary, `fillStride` and `next.maxPosts` are the two numbers to
            -- raise and lower respectively, and they cost nothing but reach.
            maxTotalPosts = 120,
            -- THE EFFECT CEILING. The client caps a resource at 64 live VFX
            -- handles (`kPerOwnerLimit`, client/src/api/Effects.cpp) and
            -- refuses the 65th with `quota_exceeded`. The DECORATIVE effects are
            -- gated on this number, in priority order:
            --
            --   burn     never gated: the proven marker skeleton, one per
            --            marker, bounded by `maxSegments` and the hold (~16-22)
            --   flame    gated -- the line fires, `everySlots` = 2 over 40
            --            near slots = 20
            --   blaze    gated, and it also keeps `blaze.reserve` handles free
            --            below the ceiling -- unverified, one per marker, ~16
            --   blast    gated -- one-shots, 4 s, only within `surge.blast.radiusMetres`
            --
            -- Planned: 16 + 20 + 16 = 52. With the hysteresis holding 22
            -- markers it is 22 + 20 + 16 = 58 -- exactly the gate, which is why
            -- the blaze reserves eight: it gives way first, and a closure
            -- always has room for its blasts. Six under the hard cap is the
            -- margin for a handle the Lua side has miscounted. `edge.lua`
            -- counts what it holds (`effects=held/ceiling` on the status line);
            -- lower this if that line ever reads a refusal.
            maxEffects = 58,
            -- Engine calls per work pass. A wall slot is one to three calls, a
            -- marker up to six; the Lua side of each is cheap and the spawn
            -- itself happens on later game-thread ticks. Three puts an eighty-
            -- post plan up in under three seconds at `workPollMs = 100`.
            postsPerTick = 3,
            -- WHETHER THE HYSTERESIS MAY HOLD A POST FROM AN EARLIER CORDON.
            --
            -- `false`, and it is a bug fix rather than a preference. The hold
            -- rule was written to stop a post being destroyed and respawned as
            -- the PLAYER walks, which is a real problem it really solves -- but
            -- it drew no distinction between "the player moved" and "the cordon
            -- closed", so a post standing on a boundary that had since been
            -- swallowed was kept for as long as the player stayed within 172 m
            -- of it.
            --
            -- Measured in the owner's own client log of 2026-09-03:
            -- `nearest post=(-1271.5,2039.4,11.9)` IDENTICAL across eight
            -- consecutive status lines and thirty-three cordon revisions
            -- (rev=14 to rev=47) while the open set fell from 53 cells to 22,
            -- with `posts=40` pinned at exactly `maxTotalPosts`. A dozen of the
            -- forty entities were the PREVIOUS cordon's boundary -- holding
            -- budget against the current one, and drawing a line where there is
            -- no longer any bleed, which is the one lie a boundary must never
            -- tell.
            --
            -- `true` restores the old behaviour for a bisect. The status line's
            -- `stale=` field counts posts from an earlier revision and should
            -- settle back to zero within a second of every closure.
            holdAcrossRevisions = false,
            -- THE SLOT PITCH, and it is a property of the SEGMENT, never of the
            -- player. A segment is divided into `round(length / spacing)` slots
            -- at their interior midpoints, once, from geometry alone -- so the
            -- key a post is held under never moves when the player walks toward
            -- it, and the rampart ADDS posts around what is already standing
            -- instead of destroying and respawning it a metre away.
            --
            -- TWO METRES, against a hesco measured at 1.58 m: 80 % wall with
            -- NO scale at all, and continuous at `rampart.scale.along = 1.15`.
            -- This is the number that makes the wall not depend on
            -- `visualScale`, which nobody has photographed. On Watson a 25 m
            -- segment is 13 slots of 1.92 m; on Pacifica a 100 m block is 50.
            -- The 0.35 m slits every two metres are what keep a player outside
            -- the cordon visible while he runs in through it.
            spacingMetres = 2.0,
            -- How far a post stands on the CLOSED side of the line. Small: the
            -- post IS the line. The light's own offset is much larger and lives
            -- in `light.outsetMetres`, because the light is what has to fall on
            -- the ground you must not stand on; each layer has its own, which is
            -- added to this one (the strip's is NEGATIVE, so it lies on the
            -- line itself).
            outsetMetres = 1.5,
            -- Added to the ground height the map reports. Zero is the surveyed
            -- street plane; raise it if the barricades are found to be buried.
            groundOffsetMetres = 0.0,

            -- REFRESH POLICY, which is the whole performance story.
            --
            -- The edge is rebuilt when the cordon changes (a block closed) or
            -- when the player has moved `refreshMetres`, tested on a `pollMs`
            -- timer. NOTHING here runs per frame, and that is deliberate:
            -- docs/research/battle-royale-and-scale.md records that three
            -- full-screen surfaces at high refresh cost two clients their frame
            -- rate, and a per-frame world scan would be the same mistake in a
            -- different file.
            --
            -- One poll is one `character.state()` plus, at most, a walk over
            -- the cells the draw radius can REACH -- 5x5 at these defaults, not
            -- the whole grid -- and a point-segment distance per boundary edge
            -- found. A few hundred table lookups once a second, and only when
            -- the player has actually moved 20 m. The cost does not grow with
            -- the map, which is why `gridSize` can go to 24 without this
            -- becoming a question.
            refreshMetres = 20.0,
            pollMs = 1000,

            -- ----------------------------------------------------------
            -- THE RAMPART -- the wall itself, on the nearest `wallPosts` slots
            -- ----------------------------------------------------------
            --
            -- `barrier.hesco` is `hesco_barrier_a_high_single_a.mesh`, and its
            -- bounding box was read out of the cooked archive on 2026-09-03:
            -- 1.58 x 1.59 x 2.01 m, base at z=0, ORIGIN ON A VERTICAL EDGE
            -- (X -1.54..0.04, Y -0.04..1.54). A sand-filled wire cube two metres
            -- tall -- the "high single" Hesco unit -- which is the game's own
            -- military cordon and, one every two-metre slot, an 80 % wall with
            -- no scaling at all.
            --
            -- EVIDENCE: the same host generator, the same alias-to-host-to-mesh
            -- chain and the same `"collision": false` as the photographed
            -- roadblock, and a mesh measured to be the whole object rather than
            -- a fragment (research section 38.1 is the reason that check
            -- matters). The hesco itself has NOT been photographed in game.
            --
            -- THE HOLLOW RULE: this alias must read `"collision": false` in
            -- `docs/generated/prop-hosts.json`; a solid one would wall the
            -- players in. Hollow alternatives, all measured:
            --   barrier.road.jersey       5.10 x 0.69 x 0.99 m, origin at one END
            --                             (centre = { x = 2.55, y = 0.21 }),
            --                             length on X: a 5 m plastic jersey
            --                             barrier, one per 2.5 slots
            --   barrier.pedestrian        1.00 x 4.10 x 1.26 m, length on Y
            --   fence.wire.reinforcement  1.50 x 0.43 x 1.10 m, origin at one end
            --   military.checkpoint       2.54 x 1.83 x 2.60 m
            -- AVOID `barrier.concrete`, `barrier.road`, `barrier.blockade.wide`
            -- and `sign.rect.keep_out`: all four are `"collision": true`.
            rampart = {
                -- OFF SINCE THE EIGHTH ROUND (2026-09-04). It was seen and it
                -- worked -- "ok we can see the elements spawning" -- and the
                -- owner's next words were that a wall of props is the wrong
                -- material: "a la place de props de mur en beton, pourquoi on
                -- utilise pas autre chose qui peut faire un effet plutot du
                -- jeu". The near line is now fire and lamps (`flame`, `beacon`).
                -- `true` puts the hesco back under them, unchanged; nothing
                -- else has to move.
                enabled = false,
                model = "barrier.hesco",
                -- MULTIPLIERS on the measured size, in the LINE's frame
                -- (`along` the boundary, `across` the normal, `up` height).
                -- 1.15 along is 1.82 m of a 1.92 m Watson slot: touching, with
                -- a hand's width of daylight; 1.4 up is 2.8 m, over head height.
                -- UNSCALED (if `visualScale` turns out not to be honoured) it is
                -- 1.58 m of every 1.92, two metres tall: still a wall.
                scale = { along = 1.15, across = 1.0, up = 1.4 },
                -- The cube is square in plan, so either axis works; "x" is the
                -- one the `centre` below is written for.
                lengthAxis = "x",
                -- The measured footprint centre relative to the mesh origin, in
                -- mesh-local metres (X -1.54..0.04 -> -0.75; Y -0.04..1.54 ->
                -- +0.75). `raiseBarricade` rotates and scales this so the cube
                -- is CENTRED on its slot; without it a wall of these would
                -- zig-zag by 0.75 m.
                centre = { x = -0.75, y = 0.75 },
                -- On top of the shared `outsetMetres`. Zero: the wall stands
                -- 1.5 m onto the closed side, 0.7 m to 2.3 m from the line.
                outsetMetres = 0.0,
                -- A mesh prop's origin is at its base (measured: minZ = 0), so
                -- zero stands it on the surveyed ground. Raise it if the wall is
                -- found half sunk; lower it if it hovers.
                groundOffsetMetres = 0.0,
                yawOffsetDegrees = 0.0,
            },

            -- ----------------------------------------------------------
            -- THE BARRICADE -- the fill beyond the rampart, and the fallback
            -- for a wall slot whose hesco was refused
            -- ----------------------------------------------------------
            --
            -- `concrete_roadblock_w100_h110.mesh`, measured 1.01 x 1.00 x 1.14 m,
            -- centred in plan, base at z=0. THE ONE PROP IN THIS TABLE WITH A
            -- PHOTOGRAPH: the 1 m capture band in
            -- docs/research/battle-royale-and-scale.md ("bloc de beton plein,
            -- pose au sol, occultant"). It is the fallback for everything
            -- because of that.
            barrier = {
                -- OFF SINCE THE EIGHTH ROUND, same reason as `rampart`. The
                -- fill tier it carried is now `beacon.fill` -- a red lamp per
                -- fill slot -- and a slot whose lamp is refused falls back to
                -- this roadblock only when it is switched back on. It keeps its
                -- place as the one mesh with a photograph.
                enabled = false,
                -- MUST read `"collision": false` in
                -- `docs/generated/prop-hosts.json`. See the long note at the top
                -- of this block: `collision = false` cannot be honoured on a mesh
                -- prop, so a solid alias here would wall the players in, and this
                -- mode has no walls.
                model = "barrier.roadblock.concrete",
                -- MULTIPLIERS on the measured size, in the LINE's frame. At
                -- `fillStride = 2` the fill pitch is ~4 m: 2.5 along is 2.5 m
                -- of every 4 (a 60 % dotted kerb line), 2.0 up is 2.3 m.
                -- Unscaled it is 1 m of every 4, 1.14 m tall -- a dotted line,
                -- visibly a line at walking distance, which is all the fill
                -- tier has to be.
                scale = { along = 2.5, across = 1.0, up = 2.0 },
                -- Square in plan, so the axis does not matter; "y" is the
                -- convention `client/edge.lua` lays on the line with no extra
                -- rotation.
                lengthAxis = "y",
                -- On top of the shared `outsetMetres` above, which already puts
                -- the post 1.5 m onto the closed side. Zero keeps the barricade
                -- on the line where it belongs.
                outsetMetres = 0.0,
                -- A mesh prop's origin is at its base, so zero stands it on the
                -- surveyed ground. Raise it a little if the barricades are found
                -- half sunk into the tarmac; lower it if they hover.
                groundOffsetMetres = 0.0,
                -- If the yaw convention turns out to be mirrored rather than
                -- rotated, this corrects it without touching the code.
                yawOffsetDegrees = 0.0,
            },

            -- ----------------------------------------------------------
            -- THE BASTION -- the mass on every marker, for the far band
            -- ----------------------------------------------------------
            --
            -- `container.shipping` is `industrial_container_a.mesh`, MEASURED
            -- on 2026-09-03 at 4.82 x 2.67 x 1.94 m -- not the "roughly 6 x 2.4
            -- x 2.6" the fifth round guessed -- with its LENGTH ON LOCAL X,
            -- centred in plan, base at z=0. The fifth round shipped it with
            -- `lengthAxis = "y"`, which laid the 2.67 m side along the line and
            -- the 4.82 m side across it. Fixed below by measurement.
            --
            -- It is still the largest hollow object in the catalogue that
            -- belongs on a street, and one of the four `wiki/props.md` names
            -- when it lists "things that look like they should stop you". At
            -- 150 m an unscaled container is 1.8 x 0.74 degrees, every 9.5
            -- degrees on Watson's lattice: a row of parked trucks on the
            -- horizon, which is a line. At the shipped scale it is 4.6 x 1.5.
            --
            -- EVIDENCE: same chain as the photographed roadblock; NOT itself
            -- photographed. THE HOLLOW RULE applies: `"collision": false` in
            -- `docs/generated/prop-hosts.json`, which it is. Other hollow
            -- alternatives, measured:
            --   street.water_tower        5.52 x 5.56 x 10.91 m -- eleven metres
            --                             tall, the only object here that would
            --                             read at 150 m by height alone, and
            --                             absurd on a street
            --   military.checkpoint       2.54 x 1.83 x 2.60 m
            --   industrial.vent.rooftop   6.77 x 2.05 x 1.90 m
            --   debris.pile               5.77 x 6.42 x 1.87 m -- rubble;
            --                             "NCPD demolished the street"
            -- AVOID `container.freight` and `barrier.concrete`: both read
            -- `"collision": true`.
            bastion = {
                -- OFF SINCE THE EIGHTH ROUND. The far band it was sized for is
                -- carried by the marker's red pool (proven at night), its fire
                -- and its plume (`blaze`, unverified); in daylight at 150 m the
                -- far line is fainter than it was with a container every
                -- 25 m, and that is the one cost of the material change worth
                -- saying out loud. `true` puts the containers back.
                enabled = false,
                model = "container.shipping",
                -- MARKER POSTS ONLY. One container per boundary segment, with
                -- the rampart or the kerb line running between them. A
                -- CONTINUOUS wall of containers would be opaque, and the
                -- players outside the cordon are precisely the ones running in
                -- through it -- they have to be visible while they do.
                markersOnly = true,
                -- MULTIPLIERS on the measured size, in the LINE's frame.
                -- 2.5 along is 12 m of container against Watson's 25 m cell:
                -- half the street, which reads as closed without sealing the
                -- sightline; 2.0 up is 3.9 m, two containers high. Unscaled it
                -- is 4.8 x 1.9 m, still the largest thing on the line.
                scale = { along = 2.5, across = 1.0, up = 2.0 },
                -- MEASURED: the container's length is local X.
                lengthAxis = "x",
                -- Pushed onto the closed side so the layers do not intersect:
                -- the rampart occupies 0.7-2.3 m from the line, the container's
                -- half-width is 1.33 m, so at 1.5 + 2.5 = 4 m out it spans
                -- 2.7-5.3 m. ADDED to the shared `outsetMetres`.
                outsetMetres = 2.5,
                -- Origin measured at the base (minZ = 0). If the containers
                -- turn out half sunk, raise this; if they hover, lower it.
                groundOffsetMetres = 0.0,
                yawOffsetDegrees = 0.0,
            },

            -- ----------------------------------------------------------
            -- THE STRIP -- the painted line on the ground. UNVERIFIED.
            -- ----------------------------------------------------------
            --
            -- `race.route_arrow` is the host for `sq024_gps_path.ent`, the
            -- street-race road chevron: `common_holograms_a_w500_h150.mesh`
            -- with the `orange_arrows` appearance, an EMISSIVE hologram panel.
            -- Measured on 2026-09-03: the mesh is a flat 5.00 x 1.50 m plane,
            -- and the host copies the entity's authored `localTransform`
            -- (quaternion -0.5, 0.5, -0.5, 0.5; position -0.75, -2.5, +0.10),
            -- which lays it FLAT, centred on the prop origin, ten centimetres
            -- above the ground, with its 5 m axis along entity +Y -- the axis
            -- `client/edge.lua` lays on the line. So: no centring, no rotation,
            -- no ground offset needed; it is already a ground decal.
            --
            -- WHY IT IS HERE. Everything else on the line is lit by the sun or
            -- by our lights; a hologram is lit by itself, so it is the one layer
            -- that reads the same at noon and at midnight, and it is ON THE
            -- GROUND, which is where a player looks when he is about to step
            -- over a line. One every second wall slot (3.85 m pitch on Watson)
            -- overlaps its neighbours by a metre: a continuous orange line the
            -- length of the rampart.
            --
            -- WHY IT IS UNVERIFIED, AND SHIPPED ANYWAY. Nothing in the tree
            -- records this host being photographed: the race mode "briefly
            -- used" it and dropped it for routing reasons, not rendering ones
            -- (docs/research/race-checkpoints-and-ui.md). Its failure mode is
            -- one invisible hollow entity per strip and nothing else, it is
            -- counted separately as `strips=` on the status line so a
            -- screenshot can be read against it, and `enabled = false` removes
            -- it. Two things a screenshot can settle: whether the panel draws
            -- at all, and whether its arrows point along the line (harmless) or
            -- across it (`yawOffsetDegrees = 90` and `lengthAxis` swap).
            strip = {
                enabled = true,
                model = "race.route_arrow",
                -- Passed explicitly because `Props.cpp` writes `meshAppearance`
                -- on every mesh host -- "default" when the caller says nothing
                -- -- and this mesh's appearance is `orange_arrows`. Naming it
                -- makes that write a no-op whether or not it takes effect.
                appearance = "orange_arrows",
                -- Every second WALL slot -- the even ones, under the fires
                -- (`phaseSlots = 0` here and in `flame`), so the odd slots
                -- carry the lamps and nothing stacks.
                everySlots = 2,
                phaseSlots = 0,
                scale = { along = 1.0, across = 1.0, up = 1.0 },
                -- ACROSS THE LINE since the eighth round, not along it. The
                -- panel's 5 m axis is entity +Y, which `lengthAxis = "y"` lays
                -- along the boundary; "x" turns it ninety degrees so the panel
                -- crosses the line, centred on it -- 2.5 m inside, 2.5 m out --
                -- every 3.85 m. Arrows along a boundary point nowhere; arrows
                -- across it point IN or OUT, and that is a direction the player
                -- can use. Which of the two the authored glyphs point is
                -- UNMEASURED: if a capture shows them pointing out of the
                -- zone, `yawOffsetDegrees = 180` turns every panel end for end.
                lengthAxis = "x",
                -- NEGATIVE: cancels the shared 1.5 m outset, so the strip is
                -- centred ON the boundary line, where the player's foot is
                -- about to land.
                outsetMetres = -1.5,
                groundOffsetMetres = 0.0,
                yawOffsetDegrees = 0.0,
            },

            -- ----------------------------------------------------------
            -- THE LAMP -- red lights along the line, between the fires
            -- ----------------------------------------------------------
            --
            -- Until the eighth round this was a beacon on top of the hesco.
            -- There is no hesco now: the lamp sits sixty centimetres above
            -- the tarmac on every ODD near-line slot (the fires take the even
            -- ones) and lights a red disc of street around it, so the ground
            -- between two fires glows and the line reads continuous where the
            -- fires alone would read dotted. Same light host as the marker
            -- pool -- coloured pools photographed at night on two clients
            -- (research 33.4 and 33.8) -- and it CHASES (see `chase`), which
            -- is what makes the line move.
            --
            -- Fill slots (`beacon.fill`) get the same lamp: beyond the near
            -- eighty metres the line is lamps alone, one every `fillStride`
            -- slots, and their pools overlap.
            --
            -- Daylight is the honest weakness of a lamp and it is UNMEASURED:
            -- a 180-intensity point light on sunlit tarmac may add nothing
            -- visible, in which case the daytime line is the fires and the
            -- (unverified) strip. The fires do not care what time it is.
            beacon = {
                enabled = true,
                -- Every second near-line slot, offset by one from the fires
                -- (`flame.phaseSlots = 0`): slots 1, 3, 5 are lamps, 2, 4, 6
                -- are fires.
                everySlots = 2,
                phaseSlots = 1,
                -- A lamp on every FILL post too (the roadblock it replaces is
                -- off). `false` leaves the fill tier to `barrier`.
                fill = true,
                color = { x = 1.0, y = 0.06, z = 0.05 },
                -- A lamp at knee height with a 6 m pool: enough to paint the
                -- 4 m to the next fire, not enough to wash the block -- that is
                -- the marker `light`'s job.
                intensity = 180.0,
                radius = 6.0,
                -- Knee height. Low so the pool is a disc on the ground rather
                -- than a glow in the air; not on the ground because a light at
                -- z = 0 is inside the tarmac and lights nothing.
                heightMetres = 0.6,
                -- On the line: zero added to the shared 1.5 m outset.
                outsetMetres = 0.0,
                -- The fill lamps stand further apart, so they reach further.
                fillRadius = 10.0,
                fillIntensity = 220.0,
            },

            -- ----------------------------------------------------------
            -- THE FLAME -- fire along the top of the rampart. 2026-09-04.
            -- ----------------------------------------------------------
            --
            -- The owner's words, the day the boundary was finally seen: "its
            -- not dynamic enough and it would be better with like fire effect
            -- over it or smth when u see it from the inside". This is that,
            -- literally: `fire.small` on top of the hesco wall, one every
            -- third slot, alternating with the beacons so the wall reads
            -- lamp / fire / lamp / fire along its length.
            --
            -- WHY THIS ALIAS AND NO OTHER. `fire.small` is the one curated VFX
            -- alias with a captured frame behind it (research §31.1, from the
            -- server path), and since 2026-09-04 it is also the alias the
            -- owner's client ACCEPTED nineteen times (`burns=19`) in the
            -- session where he confirmed the boundary -- which is stronger than
            -- anything `fire.large` can claim, though "seen as part of the
            -- whole" is still not "separated in a capture". A fire is the one
            -- primitive here that MOVES by itself: no Lua tick, no update call,
            -- the flame flickers because the engine animates it. That is what
            -- makes a line of them read as alive where a line of sandbags reads
            -- as parked.
            --
            -- WHY ON TOP. The burn at the markers sits at the foot of the line
            -- where the eye is at five metres; the wall itself is the thing
            -- seen from fifty. A flame on its crest is visible from both sides
            -- -- from inside it is "the wall is burning", from outside it is
            -- the line you have to get back over -- and it is not hidden by the
            -- hesco from either.
            --
            -- BUDGET: gated on `maxEffects` above. Forty planned wall slots at
            -- `everySlots = 3` is fourteen handles. It is the first decorative
            -- layer to be refused when the ceiling is reached, after the
            -- unverified blaze, so a tight budget costs the wall its fires
            -- before it costs the markers their proven one.
            flame = {
                enabled = true,
                effect = "fire.small",
                -- SINCE THE EIGHTH ROUND THIS IS THE LINE. Every second near-
                -- line slot -- the even ones, the lamps take the odd -- so the
                -- nearest eighty metres of boundary is a fire every 3.85 m on
                -- Watson: twenty fires. `e_fire_idle_small` is a ground fire
                -- about a metre across, so at that pitch the line is a quarter
                -- fire and three quarters red-lit tarmac, which reads as a line
                -- of fires at five metres and as a burning line at fifty --
                -- where each fire is 1.1 degrees wide and the gaps 4.4, and a
                -- flickering emissive point stays visible at an angle a grey
                -- roadblock (1.7 degrees) never did. `fire.medium` is the
                -- escalation if it reads too thin; unverified, same family.
                everySlots = 2,
                phaseSlots = 0,
                -- On the line: zero added to the shared 1.5 m outset.
                outsetMetres = 0.0,
                -- ON THE GROUND. Until this round it stood at 2.4 m on the
                -- crest of the hesco; with no wall under it a fire at 2.4 m is
                -- a fire floating in the air. A pyro effect is authored from
                -- its base, like `burn`.
                heightMetres = 0.0,
                -- 0: until this resource stops it. See `burn.durationSeconds`.
                durationSeconds = 0.0,
            },

            -- ----------------------------------------------------------
            -- THE CHASE -- the beacons alternate along the wall. 2026-09-04.
            -- ----------------------------------------------------------
            --
            -- Hazard-light language: every beacon on the rampart flips between
            -- lit and dark on a slow beat, each one out of phase with its
            -- neighbours, so a red light is always travelling along the wall.
            -- It is the second thing on the line that MOVES, and it moves on
            -- the one primitive this platform has proven end to end -- the
            -- light host, coloured pools photographed on two clients (research
            -- §33.4, §33.8), and `enabled` toggled IN PLACE on the same entity
            -- id without a respawn (§33.6; `client/src/api/Props.cpp` keeps
            -- `enabled` out of the structural set for exactly this use).
            --
            -- THE COST IS UPDATE CALLS, and they are bounded twice. Every step
            -- flips every beacon, so a step is one `Open77.props.update` per
            -- beacon -- fourteen for the shipped rampart, up to twenty with the
            -- hysteresis full. `edge.lua` drains those at most `updatesPerTick`
            -- per pass, on a pass of its own, and does not open the next step
            -- until the last one has drained -- so a long wall slows the beat
            -- rather than piling calls into one resume, which is the failure
            -- the top of edge.lua was rewritten for. At 4 per 100 ms pass a
            -- fourteen-beacon step drains in 400 ms; the beat below leaves
            -- another 400 ms of idle passes for the scan and the status line.
            --
            -- The marker LIGHT -- the big pool on the closed side -- is never
            -- chased. It is the readout that says which way is in, and a
            -- readout does not blink.
            chase = {
                enabled = true,
                -- Milliseconds between flips. 800 is a slow hazard flasher;
                -- below ~500 a twenty-lamp line cannot drain a step before
                -- the next one is due and the beat simply stretches to what
                -- the drain allows.
                stepMs = 800,
                -- THE CLOCK YOU FEEL (eighth round). Over the last
                -- `hurrySeconds` before the next closure the beat shortens
                -- linearly from `stepMs` to `hurryStepMs`, and stays there for
                -- the whole closing window -- so the red line flickers faster
                -- and faster as the phase ends, and a player who is not
                -- reading the HUD still knows. The countdown is the server's
                -- `closeInMs` off the state push, extrapolated locally; the
                -- beat never goes below what `updatesPerTick` can drain, it
                -- just stretches. Zero `hurrySeconds` disables it.
                hurrySeconds = 20.0,
                hurryStepMs = 300,
                -- `Open77.props.update` calls per pass. Six, up from four, for
                -- the hurry: twenty lamps at a 300 ms beat is 67 writes a
                -- second, and six per 100 ms pass drains 60 -- close enough
                -- that the beat holds near its floor instead of stretching
                -- back to 500. Each is one cheap native call; lower it if the
                -- log carries "a rebuild pass failed".
                updatesPerTick = 6,
            },

            -- ----------------------------------------------------------
            -- THE SURGE -- what a closure looks like. 2026-09-04.
            -- ----------------------------------------------------------
            --
            -- A phase transition is the moment this mode is selling and the
            -- boundary used to mark it with nothing: the old line's posts were
            -- retired over a few passes and the new line's were raised, and a
            -- player looking at the wall saw sandbags replace sandbags. Now:
            --
            --   * every lamp on the line -- beacons and marker lights -- flares
            --     to `color` at `intensityScale` for `seconds`, then settles
            --     back to red and the chase resumes. Two update calls per lamp
            --     per closure, drained by the same bounded pass as the chase;
            --   * each MARKER of the line being swallowed goes up in a
            --     `blast` as it is retired: the barrel explosion, played once,
            --     at the post's position. Only markers -- the fill and the
            --     rampart simply vanish -- and only within `radiusMetres` of
            --     the player, because a fireball nobody can see is a handle
            --     spent for nothing.
            --
            -- EVIDENCE for the blast. `explosion.frag` is
            -- `base\fx\environment\destructibles\barrel\barrel_explosion.effect`,
            -- and it is the effect the shipped combat path plays for every
            -- replicated grenade detonation (`SpawnExplosion` in
            -- client/src/api/Combat.cpp: "played standalone by destructibles,
            -- unlike the grenade blast which is authored into the projectile
            -- attack"), through the same `gameFxSystem.SpawnEffect` native
            -- `Open77.vfx.play` calls. It is the one one-shot in the catalogue
            -- with live code behind it. The flare is the proven light host
            -- again. Nothing here is a new primitive.
            --
            -- NO SOUND ON THE BLAST, deliberately. `Open77.sfx.play` is
            -- entity-bound and would put a grenade detonation AT THE PLAYER'S
            -- EARS for a fireball forty metres away -- which in a battle royale
            -- reads as "somebody just threw a grenade at me", the one lie the
            -- boundary must never tell.
            surge = {
                enabled = true,
                -- How long the line burns white-hot after a closure.
                seconds = 5.0,
                -- White-orange rather than white: pure white on a red-tinted
                -- street crushes to pink. Linear channels, keys x/y/z.
                color = { x = 1.0, y = 0.62, z = 0.30 },
                -- Multiplies each lamp's own intensity. Two is "twice as
                -- bright", which is what a flare has to be to read as one
                -- against a street already lit red.
                intensityScale = 2.0,
                blast = {
                    enabled = true,
                    effect = "explosion.frag",
                    -- Only retiring markers this close to the player blast.
                    -- Seventy metres is the range at which a barrel fireball
                    -- is still an event rather than a flicker.
                    radiusMetres = 70.0,
                    -- A one-shot MUST carry a duration: `0` would hold the
                    -- handle until the resource stops, and every closure would
                    -- leak a handle into the 64-cap for the rest of the match.
                    -- Four seconds outlives the fireball and its smoke.
                    durationSeconds = 4.0,
                },
            },

            -- ----------------------------------------------------------
            -- THE ALARM -- the sound of stepping outside. UNVERIFIED.
            -- ----------------------------------------------------------
            --
            -- Played once, on the local player, by open77_cordon/client/main.lua
            -- at the moment `outside` flips to true -- the same edge that
            -- raises `cordon:hurt` for the HUD. The HUD cannot play it: that
            -- resource holds only `network.events`, and `Open77.sfx` needs
            -- `world.effects`, which this one has.
            --
            -- THE EVENT NAME IS UNVERIFIED ON 2.31, and the failure mode is
            -- silence: Wwise discards an unknown id without a log line
            -- (docs/research/vfx-sfx-runtime.md). `ui_hacking_access_denied`
            -- is the breach-protocol refusal buzzer from the 1.6 event seed --
            -- a UI one-shot, so even the wrong sound is a short one -- and
            -- `durationSeconds` bounds it regardless: Open77 queues a
            -- `SoundStopEvent` for the name when the handle expires, so a name
            -- that turned out to loop is cut at two seconds. One boolean
            -- removes it.
            alarm = {
                enabled = true,
                event = "ui_hacking_access_denied",
                durationSeconds = 2.0,
            },

            -- ----------------------------------------------------------
            -- THE MAST -- height for the far band. MEASURED, UNVERIFIED, OFF.
            -- ----------------------------------------------------------
            --
            -- `street.electrical_pole` is `electrical_pole_a.mesh`, measured
            -- 1.44 x 1.21 x 6.12 m: a six-metre utility pole with a crossarm,
            -- hollow, the tallest object in the catalogue that is not absurd on
            -- a street (`street.water_tower` is 10.9 m and IS absurd). At 150 m
            -- it is 2.3 degrees tall, at 50 m seven. Off because a row of
            -- utility poles says "street", not "cordon"; present because the
            -- next round that needs height at 150 m should not have to measure
            -- the catalogue again. `enabled = true` puts one behind every
            -- container.
            mast = {
                enabled = false,
                model = "street.electrical_pole",
                markersOnly = true,
                scale = { along = 1.0, across = 1.0, up = 1.0 },
                lengthAxis = "y",
                outsetMetres = 3.0,
                groundOffsetMetres = 0.0,
                yawOffsetDegrees = 0.0,
            },

            -- ----------------------------------------------------------
            -- THE BURN -- the only effect in this tree with a screenshot
            -- ----------------------------------------------------------
            --
            -- `fire.small` is `base\fx\environment\pyro\e_fire_idle_small.effect`,
            -- and it is the ONE curated VFX alias on this build with recorded
            -- in-game proof. `docs/research/props-and-object-spawning.md` §31.1
            -- played it from server Lua at a coordinate and wrote down "a fire
            -- visibly burning on the steps", with a captured frame; E0.5
            -- separately established that the same effect survives a 385 m
            -- stream-away-and-back as a `duration = 0` loop. Everything else in
            -- `Open77.vfx.catalog()`, `smoke.column.black` included, is
            -- `discoverable_not_individually_validated`.
            --
            -- It is also the right picture, not merely the safe one. Fire is
            -- EMISSIVE, so it reads at noon and at midnight where a point light
            -- reads only at night; it is depth sorted, lit and fogged by the
            -- engine, so it is occluded by the megabuilding in front of it,
            -- which is complaint 1 from the projected wall; and it carries a
            -- plume, which is vertical extent that no metre-and-a-half prop can
            -- buy. "NCPD burned the block" is the sentence this mode has been
            -- trying to say since the first revision of the edge.
            --
            -- `fire.medium` and `fire.large` are the same authored family and
            -- the obvious escalation if this reads too small. NEITHER HAS BEEN
            -- SEEN; the default stays on the one that has.
            burn = {
                enabled = true,
                effect = "fire.small",
                -- MARKER POSTS ONLY, and this one is a budget: the client caps a
                -- resource at 64 effects (`kPerOwnerLimit`,
                -- client/src/api/Effects.cpp). At the marker pitch there are at
                -- most `maxSegments` = 16 of them plus the same number of
                -- blazes: half the ceiling.
                markersOnly = true,
                -- NEGATIVE, so the fire sits half a metre INSIDE the line --
                -- between the strip and the rampart, in front of the wall as
                -- seen from inside. Behind the wall it would be hidden by the
                -- hesco at five metres and by the container at fifty; this is
                -- the layer with a photograph and it has to be where the eye is.
                outsetMetres = -1.0,
                -- On the ground. A pyro effect is authored from its base.
                heightMetres = 0.0,
                -- 0 means "until this resource stops it". The engine caps an
                -- explicit duration at 600 s (`kMaximumDurationSeconds`), so a
                -- timed fire would have to be re-armed every ten minutes for no
                -- gain.
                durationSeconds = 0.0,
            },

            -- ----------------------------------------------------------
            -- THE BLAZE -- the big fire behind the container. UNVERIFIED.
            -- ----------------------------------------------------------
            --
            -- `fire.large` is `base\fx\environment\pyro\e_fire_large.effect`:
            -- the same authored family as the photographed `fire.small`, and
            -- the family the game itself places as `worldStaticParticleNode`s
            -- in its sectors (`e_fire_medium_tall`, `e_fire_small` in
            -- `exterior_-24_-38_0_0`, docs/research/multiplayer-mode.md) --
            -- which is the inference that an environment pyro effect is
            -- self-contained and renders standing on its own. NOBODY HAS SEEN
            -- THIS ONE. It is the layer that would give the far band a plume
            -- taller than a container; it is counted as `blazes=` on the status
            -- line; and it is one boolean to remove. A screenshot showing the
            -- small fire and no large one settles it.
            blaze = {
                enabled = true,
                effect = "fire.large",
                markersOnly = true,
                -- Handles kept FREE below `maxEffects` before a blaze is
                -- raised: it is the unverified layer, so it gives way before
                -- the line fires and before the closure blasts. Eight is six
                -- blasts plus two of margin; see the arithmetic at
                -- `maxEffects`.
                reserve = 8,
                -- OTHER EFFECTS TO TRY IN THIS SLOT, all raw cooked paths from
                -- `docs/generated/vfx-assets-2.31.csv`, none of them seen, each
                -- a one-string change and a resource reload (no build). They
                -- are here because the owner asked for "un effet plutot du
                -- jeu" and these are the game's own zone vocabulary:
                --   base\fx\vehicles\av\_landing_area\v_av_landing_area_hologram_militech.effect
                --       the AV landing-pad hologram -- a large ground-projected
                --       holographic ring, the closest thing the game has to an
                --       Apex ring marker
                --   base\fx\quest\q104\av_crashsite\q104_av_warning_zone.effect
                --       an AV crash-site warning zone
                --   base\fx\environment\holograms\awacs_zone\e_awacs_zone.effect
                --       the AWACS zone hologram (`neon.holo_zone`)
                --   base\fx\devices\flare\d_flare_smoke.effect
                --       a road flare (`race.flare.smoke`): red smoke and light;
                --       the one alias another shipped mode plays through
                --       `Open77.vfx.play`
                --   base\fx\vehicles\police\v_police_sirens_01.effect
                --       NCPD siren lights; may need the vehicle's light slots
                -- A quest or vehicle effect may depend on context it does not
                -- have here (wiki/effects.md); the failure mode is an accepted
                -- handle that draws nothing, counted as `blazes=` on the
                -- status line.
                -- Behind the container (which spans 2.7-5.3 m out), so the
                -- plume shows above it from inside and the fire itself is seen
                -- from outside.
                outsetMetres = 4.5,
                heightMetres = 0.0,
                durationSeconds = 0.0,
            },

            -- The column. `effect` is a curated alias from
            -- `Open77.vfx.catalog()` or a raw cooked `base\...\.effect` path.
            --
            -- OFF SINCE 2026-09-03, and it is a demotion on evidence rather than
            -- a taste change. `smoke.column.black` was chosen for its size --
            -- five metres wide and fifty tall -- and carried through four rounds
            -- on that strength alone. Nobody has ever seen it.
            -- `docs/research/vfx-sfx-runtime.md` still lists validating the
            -- curated aliases on 2.31 as an OPEN experiment, and the `burn`
            -- block above now occupies the same slot with a screenshot behind
            -- it. Set `enabled = true` the day somebody proves the alias
            -- renders; nothing else has to change.
            column = {
                enabled = false,
                effect = "smoke.column.black",
                -- MARKER POSTS ONLY, and this is legibility rather than budget.
                -- The column is five metres wide and FIFTY TALL; one every six
                -- metres would be an opaque lid over the street, and a player
                -- cannot shoot what they cannot see -- while the people outside
                -- the cordon are precisely the ones running in through it. At the
                -- marker pitch (one per boundary segment) it is what it was
                -- designed to be: the thing you read from across the district.
                -- `false` puts one on every post.
                markersOnly = true,
                -- 0 means "until this resource stops it", which is what a
                -- boundary marker wants. The engine caps an explicit duration
                -- at 600 s (`kMaximumDurationSeconds`), so a timed post would
                -- have to be re-armed every ten minutes for no gain.
                durationSeconds = 0.0,
            },

            -- The red wash. A point light, not a spot: a spot has to be aimed,
            -- and the thing being lit is a strip of street on the far side of a
            -- line the player may approach from any angle.
            light = {
                enabled = true,
                -- MARKER POSTS ONLY, and here the reason IS a budget: a
                -- real-time light is the expensive half of a post for the
                -- renderer, and the owner's 2026-09-03 client had up to 31 of
                -- them standing. At the marker pitch there are sixteen, and with
                -- `radius = 40` against a 25 m lattice their pools still overlap,
                -- so the red wash on the closed side stays continuous at half the
                -- cost. `false` restores one per post.
                markersOnly = true,
                -- Linear colour, channels 0-1, and the keys really are x/y/z --
                -- an {r,g,b} table is rejected as `invalid_color` (wiki/props.md).
                -- Not pure red: a trace of green and blue keeps it from crushing
                -- to black on a dark street, which is where it will mostly be
                -- seen.
                color = { x = 1.0, y = 0.06, z = 0.05 },
                -- Bounds enforced by the client: intensity 0-10000, radius
                -- 0.1-500.
                --
                -- RAISED 2026-09-03, ~6x, and the direction is the only thing
                -- that is defensible here rather than the number. 140 was the
                -- previous guess; `open77_admin`'s own default for
                -- `admin.props.light` is **20**, so 140 was already "bright in a
                -- room" -- and this light is competing with the Night City sun
                -- on open tarmac. Both remain GUESSES; nobody has yet photo-
                -- graphed a cordon light. If the street reads pink at night,
                -- come down; if daylight still swallows it, the ceiling is
                -- 10000 and the `burn` block above is the layer that does not
                -- care what time it is.
                --
                -- `radius` is the pool's reach, not the light's visibility --
                -- lit ground is visible from any distance -- so 70 m against a
                -- 25 m lattice keeps neighbouring markers' pools overlapping and
                -- the wash on the closed side continuous.
                intensity = 850.0,
                radius = 70.0,
                -- Above the ground, so the pool falls on the street rather than
                -- being swallowed by it.
                heightMetres = 4.0,
                -- Far enough onto the closed side that the lit ground is
                -- unambiguously the side you must not be on. Roughly half the
                -- light radius, so the pool's near edge lands on the line --
                -- which is why it moved with `radius` above.
                outsetMetres = 30.0,
            },

            -- ----------------------------------------------------------
            -- THE NEXT LINE -- the zone that survives, drawn ahead. 2026-09-04.
            -- ----------------------------------------------------------
            --
            -- The owner's sentence, and the whole reason this block exists:
            -- "le principe de voir la zone et ce que tu spawn c'est de savoir
            -- que la zone s'approche au fur et a mesure et qu'il faut avancer
            -- vers la prochaine zone a la apex, la on a pas du tout cette
            -- impression". A single boundary, however visible, is a fence you
            -- happen to be near. What makes a zone a ZONE is seeing the next
            -- one before it arrives.
            --
            -- The server already announces the doomed cells for the whole hold
            -- (`closing` on `cordon:bounds`, the amber flash on the tac-map).
            -- This draws their INNER edge in the world: every side of an open,
            -- surviving cell that faces a doomed one gets amber lamps -- one at
            -- the middle slot and one every `everySlots` -- for as long as the
            -- announcement stands. From inside the doomed band the player sees
            -- the red fires behind him and the amber line ahead; the HUD's
            -- ZONE CLOSING IN / NEXT ZONE strip says how long and how far. As
            -- the window runs the red line eats the band cell by cell toward
            -- the amber one; when a doomed cell closes, the amber post on its
            -- far side is the SAME slot key as the new red post (the key is
            -- the surviving cell's side), so the diff rebuilds it in place as
            -- fire and lamp. That rebuild, plus the closure flare, is the line
            -- arriving.
            --
            -- Lamps only, deliberately: this line is a warning, not a wall,
            -- and it moves one ring inward every phase, so it must be the
            -- cheapest post there is. Amber is the tac-map's own colour for
            -- doomed ground (`--cordon-closing`, #f5c95c), so the two readouts
            -- agree. During a closure flare (`surge`) these lamps go
            -- white-hot with every other lamp on the line.
            next = {
                enabled = true,
                -- Nearest next-line segments considered, on top of
                -- `maxSegments` for the current line.
                segments = 16,
                -- Posts on this line, counted apart from `maxPosts`. Twenty-
                -- four is sixteen segment markers plus eight infill on the
                -- nearest few; every one is a real-time light, and this is the
                -- number to lower first if a client's frame rate drops at the
                -- boundary (see the arithmetic at `maxTotalPosts`).
                maxPosts = 24,
                -- Infill pitch on the nearest segments: every sixth 2 m slot
                -- is 11.5 m on Watson, and a 14 m pool bridges it.
                everySlots = 6,
                -- Linear amber. Warmer than the fires' red, cooler than the
                -- surge's white-orange, so the three states are three colours.
                color = { x = 1.0, y = 0.55, z = 0.08 },
                intensity = 320.0,
                radius = 14.0,
                -- Chest height: a warning line is read from a distance, and a
                -- pool with its centre off the ground carries further than a
                -- disc at the player's feet.
                heightMetres = 1.2,
                -- On top of the shared `outsetMetres`. Zero: the lamp stands
                -- 1.5 m INTO the doomed band, which is where "the edge of what
                -- survives" is.
                outsetMetres = 0.0,
            },

            -- ----------------------------------------------------------
            -- THE PROJECTED WALL -- retired from "world", kept for "hud"
            -- ----------------------------------------------------------
            --
            -- `open77_cordon/client/edge.lua` publishes the nearest boundary
            -- segments as `cordon:edge:wall`; `open77_cordon_hud/client/wall.lua`
            -- projects them against the live camera and strokes them on a
            -- transparent WebUI surface. It was built on 2026-09-03 because the
            -- world layer reported `rendered=32 failed=0` to a player looking at
            -- an empty street, and it did exactly what it promised.
            --
            -- IT IS ALSO WHAT THE OWNER PHOTOGRAPHED AND ASKED US TO FIX. Its own
            -- file header had already written down all three of his complaints as
            -- accepted costs -- no occlusion, no ground contact under a distant
            -- panel, a set of nearest segments that is disjoint around a corner --
            -- and none of them is fixable in a screen overlay: the client exposes
            -- no spatial query to a Lua resource at all (`Open77.world` carries
            -- safe areas and nothing else), and the only occluded primitive on
            -- the platform, `Open77.anchors`' `render = "ring"`, draws a circle
            -- and cannot be handed a polyline.
            --
            -- So under `style = "world"` the world layer carries the boundary
            -- alone and this draws nothing. It is NOT deleted: under
            -- `style = "hud"` it is the only boundary there is, and a mode with
            -- no visible boundary is the one thing this design cannot ship.
            wall = {
                -- ABSENT ON PURPOSE, AND THE ABSENCE IS THE SETTING. `edge.lua`'s
                -- `wallEnabled` reads three states: an explicit true or false
                -- wins, and no key at all means AUTOMATIC -- on under
                -- `style = "hud"`, off under "world". Uncomment one of these to
                -- pin it, which is what a bisect wants:
                --   enabled = true,   -- draw it under "world" too (both layers)
                --   enabled = false,  -- never draw it, not even under "hud"

                -- How far the projected wall reaches, and it is deliberately
                -- much shorter than `drawRadiusMetres`. A ground line a hundred
                -- metres away projects near the HORIZON -- eye height on screen,
                -- with nothing drawn between the player and it -- which is
                -- precisely the "line floating in front of us with a gap under
                -- it" in the owner's report. At seventy metres a panel's base
                -- lands well below the horizon and reads as touching the ground,
                -- and fewer buildings stand between it and the camera. A
                -- mitigation for the fallback, not a fix.
                rangeMetres = 70.0,
                -- Panels per publish. `edge.lua` clamps this to 24 whatever is
                -- written here, because each panel costs the HUD four native
                -- projections per frame at 20 Hz.
                maxPanels = 16,
                -- Panel height in metres. Tall enough to read as a barrier at
                -- forty metres, short enough not to become a lid over the street.
                heightMetres = 18.0,
                -- `--op77-signal`, the design system's coral, and the same value
                -- `open77_groundcircle` uses for its `danger` style -- so the two
                -- projected boundary primitives on this platform agree.
                color = "#ff5964",
            },

            -- ----------------------------------------------------------
            -- THE SCREEN
            -- ----------------------------------------------------------
            --
            -- The vignette already existed and was BINARY: outside or not. That
            -- is wrong in both directions -- it was equally loud at 2 HP/s in
            -- Cordon 1, when a player has half a minute to walk back, and at
            -- 40 HP/s in Cordon 7, when they have two seconds.
            --
            -- These numbers ride the state push inside `C.fragment()` rather
            -- than living in the HUD, because the HUD is a SEPARATE RESOURCE
            -- with its own Lua state and cannot read this table. Four numbers at
            -- 2 Hz to 64 players is about 7 KB/s across the whole server against
            -- the ~23 KB/s PER PLAYER the snapshot relay already costs (E1), so
            -- the tuning stays here where it can be edited.
            vignette = {
                enabled = true,
                -- Time outside at which the rim reaches full strength. Twelve
                -- seconds is roughly how long a player needs to turn round and
                -- start running, so the ramp finishes about when panic should.
                rampMs = 12000,
                -- Bleed rate at which the rim is at full strength IMMEDIATELY,
                -- ignoring the ramp. 25 HP/s is Cordon 6: at that rate the
                -- twelve-second ramp would still be climbing when the player is
                -- already dead.
                fullRateDps = 25.0,
                -- The floor the rim never drops below while outside, so the
                -- first frame outside is already unmistakable rather than
                -- fading up from nothing.
                minimum = 0.35,
            },
        },
    },
    -- ======================================================================
    -- SPAWN PROTECTION -- two shields, both enforced by the ARBITER
    -- ======================================================================
    --
    -- THE PLATFORM HAS NO SHIELD. `Recovering` IS NOT INVULNERABLE -- it is a
    -- life state, and damage lands on a Recovering player exactly as it lands on
    -- anyone. The only real invulnerability the platform offers is god mode, and
    -- god mode was not usable here: E3 measured a 120 m fall killing a god-moded
    -- player outright. The diagnosis at the time -- "fall damage bypasses the
    -- arbiter god mode gates" -- was close but wrong, and `Config.match.drop`
    -- carries the real one: the shield was `Immortal`, which floors health at
    -- ~1% instead of blocking the attack, and the server accepted the client's
    -- resulting death intent. Both are fixed. God mode is now a usable shield
    -- against a fall; it is still not the shield THIS table describes.
    --
    -- So THIS MODE ENFORCES ITS OWN, in `server/main.lua`'s damage arbiter: a
    -- shot at a shielded victim is refused and logged, the same way a shot from
    -- an unverified weapon is. That makes the shield a rule rather than a state,
    -- which is also why it survives a placement.
    spawnProtection = {
        -- Plan section 8: 4 s at deploy, or until landing + 1 s. With
        -- `Config.match.drop.enabled` the second number is live at last: the
        -- deploy shield covers the descent, and `landingGraceSeconds` is what
        -- the server grants when the touchdown is reported (or when the landing
        -- timeout places the player itself). With the drop off, the descent
        -- does not exist and only the first number applies, exactly as before.
        deploySeconds = 4.0,
        landingGraceSeconds = 1.0,
        -- Short on purpose. A revive already costs the reviver five seconds of
        -- standing still; two seconds is enough to get behind the reviver and no
        -- more.
        reviveSeconds = 2.0,
        -- Drop the shield the moment the protected player's own outgoing damage
        -- is credited. Without this, four seconds of one-way fire is a strategy.
        breakOnAggression = true,
        showOnHud = true,
        -- Stated as data because it is the thing most likely to be re-litigated
        -- by somebody who reads `Recovering` in the platform docs and assumes it
        -- protects. It does not.
        enforcedInArbiter = true,
    },
    -- ======================================================================
    -- STRINGS -- every player-facing string, English (plan decision 15)
    -- ======================================================================
    --
    -- Nothing player-facing is written inline anywhere else in this resource or
    -- in `open77_cordon_hud`. The server sends KINDS AND COUNTS -- `{ kind =
    -- "cordonKill", victim = 12 }` -- and the HUD looks the sentence up here.
    -- A server that shipped rendered text could not be translated and could not
    -- have its wording fixed without a resource reload mid-match.
    --
    -- `%s` / `%d` positions are part of the contract: a translator moving them
    -- is fine, a translator DELETING one crashes `string.format` on the client.
    strings = {
        title = "CORDON",
        -- ------------------------------------------------------------------
        -- NOTICE -- toasts. Addressed to one player, about that player.
        -- ------------------------------------------------------------------
        notice = {
            -- Staging
            joinedStaging     = { title = "STAGING",          body = "Waiting for the next drop. %d of %d." },
            notReady          = { title = "HOLD ON",          body = "Your character is not ready yet." },
            serverFull        = { title = "SERVER FULL",      body = "Every slot is taken. That is a server capacity limit, not a queue -- try again shortly." },
            matchInProgress   = { title = "MATCH RUNNING",    body = "A match is already live. You are in staging for the next one." },
            countdownStarted  = { title = "DROP IN",          body = "%d s. Join the queue on the panel." },
            countdownHeld     = { title = "WAITING",          body = "%d more needed before the drop." },
            formatIs          = { title = "FORMAT",           body = "%s. Squads of %d." },
            -- Party
            partyCreated      = { title = "PARTY",            body = "Your invite code is %s. It is good until the drop." },
            partyJoined       = { title = "PARTY",            body = "You are squadded with %s." },
            partyUnknownCode  = { title = "PARTY",            body = "No party with code %s." },
            partyFull         = { title = "PARTY",            body = "That squad is full -- %d is the maximum in this format." },
            partyLeft         = { title = "PARTY",            body = "You left your squad." },
            -- Deploy
            deployOpen        = { title = "PICK YOUR DROP",   body = "%d s. Click the map. Your squad lands together." },
            deployPinSet      = { title = "DROP POINT",       body = "%s." },
            deployPinTooFar   = { title = "DROP POINT",       body = "Within %d m of your squad's pin." },
            deployLeaderOnly  = { title = "DROP POINT",       body = "Your squad leader sets the pin. You may adjust yours within %d m." },
            -- Match
            dropped           = { title = "GOOD HUNTING",     body = "%d contestants. %d squads." },
            placementFailed   = { title = "PLACEMENT FAILED", body = "The drop could not place you. Trying again." },
            protectionOn      = { title = "SHIELD",           body = "%d s." },
            protectionBroken  = { title = "SHIELD LOST",      body = "You fired -- the shield dropped." },
            -- The cordon
            cordonWarning     = { title = "CORDON CLOSING",   body = "%d s. Blocks outside the line go dark." },
            cordonClosing     = { title = "CORDON CLOSING",   body = "NCPD is sealing the outer blocks. %d HP/s outside." },
            cordonOutside     = { title = "OUTSIDE THE LINE", body = "You are bleeding. Nearest open block %d m %s." },
            cordonInside      = { title = "BACK INSIDE",      body = "You are behind the line." },
            -- Loot and inventory
            lootFull          = { title = "SLOTS FULL",       body = "%s swapped for %s. The old one is at your feet." },
            lootVerifying     = { title = "PICKED UP",        body = "%s. Verifying." },
            lootUnverified    = { title = "WEAPON",           body = "%s is in your hands but could not be verified; your shots stay blocked." },
            ammoPicked        = { title = "AMMO",             body = "+%d %s." },
            plateFull         = { title = "PLATES",           body = "You are carrying %d, the maximum." },
            plateApplied      = { title = "ARMOR",            body = "+%d. %d plates left." },
            plateInterrupted  = { title = "INTERRUPTED",      body = "You took fire -- the plate is still in your bag." },
            healFull          = { title = "MEDS",             body = "You are carrying %d, the maximum." },
            healApplied       = { title = "PATCHED",          body = "+%d HP. %d left." },
            healInterrupted   = { title = "INTERRUPTED",      body = "You took fire -- the injector is still in your bag." },
            -- Squad
            squadmateDown     = { title = "SQUADMATE DOWN",   body = "%s. %d s to reach the body." },
            squadmateLost     = { title = "SQUADMATE LOST",   body = "%s is gone for good." },
            reviveHold        = { title = "REVIVE",           body = "Tap %s to revive (%d s). Tap again to cancel." },
            reviveDone        = { title = "BACK UP",          body = "%s is on their feet." },
            reviveCancelled   = { title = "REVIVE FAILED",    body = "Revive interrupted." },
            revived           = { title = "PATCHED UP",       body = "%s pulled you back. %d HP, no armor." },
            pingCooldown      = { title = "PING",             body = "%d s." },
            -- Elimination and the end
            eliminated        = { title = "ELIMINATED",       body = "#%d of %d. %d kills, %d damage." },
            spectatingSquad   = { title = "SPECTATING",       body = "Watching %s." },
            watchingFromStaging = { title = "STAGING",        body = "Your match is still running. Watch it on the panel." },
            extraction        = { title = "EXTRACTION",       body = "Trauma Team inbound. Hold the block." },
            -- Career
            careerWelcome     = { title = "CAREER",           body = "%d matches, %d wins, best placement #%d. Type /br.stats for the card." },
            matchUnrated      = { title = "UNRATED",          body = "This match contains bots, so it will not move your rating." },
        },
        -- ------------------------------------------------------------------
        -- FEED -- the kill feed. Broadcast, about other people.
        -- ------------------------------------------------------------------
        --
        -- One line per event KIND. The server sends the kind plus ids; the HUD
        -- resolves the names. `%s` is always a display name and never an id --
        -- an id in a kill feed is a bug that ships.
        feed = {
            kill              = "%s killed %s",
            killHeadshot      = "%s killed %s -- headshot",
            killMelee         = "%s cut down %s",
            killCordon        = "%s bled out beyond the line",
            killCordonAssist  = "%s bled out -- %s had them",
            killHoldout       = "%s was killed by a %s holdout",
            killBoss          = "%s was killed by the cyberpsycho",
            killSelf          = "%s flatlined",
            killFall          = "%s fell",
            revive            = "%s revived %s",
            squadWiped        = "%s squad eliminated",
            botTag            = "BOT",
            lastSquad         = "%s squad extracted",
            -- The three the mode owes the player as EVENTS rather than kills.
            supplyDrop        = "Supply drop inbound",
            blackout          = "Grid down",
            bossSpawned       = "Cyberpsycho sighted",
        },
        -- ------------------------------------------------------------------
        -- PHASE -- the band across the top. Keys match `schedule[*].label`.
        -- ------------------------------------------------------------------
        phase = {
            staging   = "STAGING",
            deploy    = "PICK YOUR DROP",
            drop      = "DROP",
            loot      = "NO CORDON",
            cordon1   = "CORDON 1",
            cordon2   = "CORDON 2",
            cordon3   = "CORDON 3",
            cordon4   = "CORDON 4",
            cordon5   = "CORDON 5",
            cordon6   = "CORDON 6",
            cordon7   = "FINAL CORDON",
            extraction = "EXTRACTION",
            results   = "RESULTS",
            -- Suffixes the band appends to any of the above.
            closingIn = "CLOSING IN %s",
            closing   = "CLOSING",
            outside   = "OUTSIDE -- %d HP/s",
        },
        -- ------------------------------------------------------------------
        -- RESULT -- the card at the end.
        -- ------------------------------------------------------------------
        result = {
            victoryTitle    = "EXTRACTED",
            victoryBody     = "Last squad standing. Trauma Team has you.",
            victorySolo     = "Last one standing. Trauma Team has you.",
            placementTitle  = "#%d OF %d",
            placementBody   = "%d kills  -  %d damage  -  %s survived",
            squadLine       = "%s  -  #%d  -  %d kills",
            botWon          = "A bot squad took this one.",
            ratedLine       = "Rating %+d",
            unratedLine     = "Unrated -- this match contained bots",
            noDatabaseLine  = "In-memory only -- no database on this server",
            returningIn     = "Back to staging in %d s",
        },
        -- ------------------------------------------------------------------
        -- HUD -- labels and chips, not sentences.
        -- ------------------------------------------------------------------
        hud = {
            alive           = "%d ALIVE",
            squadsAlive     = "%d SQUADS",
            kills           = "%d KILLS",
            botTag          = "BOT",
            spectating      = "SPECTATING",
            downedTag       = "DOWN %d",
            reviveProgress  = "REVIVING %s",
            plates          = "PLATES",
            heals           = "MEDS",
            noWeapon        = "EMPTY",
            unverified      = "UNVERIFIED",
            compassTo       = "%d m",
            outsideBanner   = "OUTSIDE THE CORDON",
            supplyInbound   = "SUPPLY",
            finalBlock      = "FINAL BLOCK",
            tacmapHint      = "%s for the map",
            joinQueue       = "JOIN",
            queueCount      = "%d / %d QUEUED",
            inviteCode      = "CODE %s",
        },
        -- ------------------------------------------------------------------
        -- ERROR -- command failures. Operator- and player-facing both.
        -- ------------------------------------------------------------------
        error = {
            playerOnly      = "player only",
            notInMatch      = "you are not in the match",
            notInStaging    = "you are not in staging",
            unknownFormat   = "unknown format -- try solo, duo or squad",
            unknownPreset   = "unknown schedule preset -- try standard or short",
            matchRunning    = "a match is already running",
            noMatch         = "no match is running",
            mapIncomplete   = "the active map is not playable -- run /br.map check",
        },
    },
    -- ======================================================================
    -- TUNABLES -- the Warden panel contract (plan section 13)
    -- ======================================================================
    --
    -- ONE `Open77.tunables.declare(Config.tunables)` call in the whole resource,
    -- made from the first server script. The proxy it returns READS THROUGH TO
    -- THE HOST ON EVERY ACCESS, so read it at the point of use: a value hoisted
    -- into a file-scope local is frozen at load while the panel goes on
    -- reporting the new number.
    --
    -- WHY EVERY KEY IS `apply = "live"` HERE, WHICH IS THE OPPOSITE OF THE
    -- DEATHMATCH'S REASONING AND ARRIVES AT THE SAME PLACE. Over there, several
    -- rounds run at once, so `promote()` -- which is per-RESOURCE, not per-match
    -- -- would move instance A's finish line while opening instance B. Here
    -- there is only ever ONE match (decision 1), so `promote()` would be
    -- correct. It is still not used: the match CAPTURES the whole set at deploy
    -- (`match.tune = Open77.tunables.capture()`) and every rule reads the
    -- capture for the match's life. A capture is strictly stronger than a
    -- promote -- it cannot be half-applied -- and it makes "which settings did
    -- that match run under" a value the result card can carry.
    --
    -- Bounds are chosen so that anything inside them is still a game. Anything
    -- outside them is not a setting, it is a bug report.
    --
    -- Budget: 128 tunables per resource, 64 KiB of declaration, 32 choices,
    -- 256-character strings. Twenty-one keys here, so there is room.
    tunables = {
        -- ---------------------------------------------------------------
        -- MATCH
        -- ---------------------------------------------------------------
        format = {
            -- SOLO, owner's call 2026-09-03. NOTE THAT THIS LINE, NOT
            -- `match.defaultFormat`, IS THE ONE THAT DECIDES: `K.tune` returns
            -- the runtime tunable first, then THIS declared `value`, and only
            -- reaches the `defaultFormat` fallback when neither exists. Setting
            -- `defaultFormat` alone changes nothing while this key is declared.
            value = "solo", type = "enum", choices = { "solo", "duo", "squad" },
            apply = "live", label = "Format", group = "Match", order = 1,
            description = "Solo (64 x 1), Duo (32 x 2) or Squad (16 x 4). One format per match; a change reaches the NEXT match, never the running one.",
        },
        minPlayers = {
            value = 16, type = "integer", min = 1, max = 64, step = 1,
            apply = "live", label = "Minimum players", group = "Match", order = 2,
            description = "Humans in staging before the countdown starts. 16 in production, 1 in development. Bots never count toward it -- a lobby of bots is not a reason to start.",
        },
        stagingSeconds = {
            value = 105, type = "integer", min = 15, max = 600, step = 5,
            unit = "s", apply = "live", label = "Staging", group = "Match", order = 3,
            description = "How long staging lasts before the drop map opens. Cut short when the lobby fills.",
        },
        deploySeconds = {
            value = 45, type = "integer", min = 10, max = 180, step = 5,
            unit = "s", apply = "live", label = "Deploy window", group = "Match", order = 4,
            description = "How long the drop map stays open for squads to pin a landing zone. Never cut short -- everybody needs the same time to read the map.",
        },
        -- The drop is a tunable rather than a rebuild because it is the one
        -- setting an operator will want to turn off from the panel the first
        -- time a client reports a bad landing: `false` restores the ground
        -- placement, which is the same code path the landing timeout already
        -- falls back to, so switching costs the next match and nothing else.
        drop = {
            value = false, type = "boolean",
            apply = "live", label = "Aerial insertion", group = "Match", order = 6,
            description = "Drop the squad from altitude under a grav-chute instead of standing them on the landing zone. Off restores the ground placement exactly. A client that never reports its touchdown is placed on the ground by the server after Config.match.drop.landingTimeoutSeconds -- the mode never waits on a client.",
        },
        -- DYING WHILE THE MATCH RUNS ON. Both were live defaults inside
        -- `server/match.lua` and are now named in `Config.match`; declaring them
        -- here is what makes them settable from the panel and from
        -- `tunable.set open77_cordon <key> <value>` without a reload.
        --
        -- THE DECLARED `value` IS THE ONE THAT DECIDES -- see the note on
        -- `format` above -- so both are set to exactly what `Config.match`
        -- carries. Declaring them changes no behaviour; it only opens the door.
        eliminationHoldSeconds = {
            value = 8, type = "integer", min = 0, max = 60, step = 1,
            unit = "s", apply = "live", label = "Body hold", group = "Match", order = 7,
            description = "How long a body nobody is coming for stays exactly where it fell before the player is stood up in the lobby. Long enough to read your own result card where you died. A revive window somebody can actually answer outranks it, so in Squad a downed player holds for the revive window instead -- and the cordon shortens it for a body lying out in the bleed (see Cordon bleed-out).",
        },
        eliminationCardSeconds = {
            value = 12, type = "integer", min = 0, max = 300, step = 1,
            unit = "s", apply = "live", label = "Elimination card", group = "Match", order = 8,
            description = "How long your own result card -- placement, kills, time survived -- stays up after you land in the lobby, while the match runs on without you. Zero never shows it. Separate from the body hold on purpose: the hold is about the corpse and the cordon can cut it to a third, the card is about reading your own result and must not be cut with it.",
        },
        schedule = {
            value = "standard", type = "enum", choices = { "standard", "blitz", "long" },
            apply = "live", label = "Cordon schedule", group = "Match", order = 5,
            description = "Which closure schedule the next match runs. 'standard' is ~6:10 of cordon in as many zones as the map has rings for; 'blitz' is ~3:00 for development; 'long' is ~15:45, the plan's own pacing for a full sector. This picks a PRESET NAME -- the shapes live in shared/config.lua, because a tunable string is capped at 256 characters. The retired 'short' preset falls back to 'standard' with a warning in the log.",
        },
        -- ---------------------------------------------------------------
        -- PACING. Three overrides on the chosen preset, so a match can be
        -- retimed from the panel without authoring a schedule. ZERO means "the
        -- preset decides", which is why the minimum is 0 and not the smallest
        -- sensible value -- an operator who wants the preset back sets it to
        -- zero rather than having to remember what the preset said.
        --
        -- They apply at the NEXT match, not the running one: the whole closure
        -- timetable is precomputed at `C.begin` and comparing a live clock
        -- against a table that changed underneath it is how blocks close twice
        -- or never. `apply = "live"` here means the value reaches the resource
        -- immediately; the cordon reads it when it next arms.
        -- ---------------------------------------------------------------
        cordonSeconds = {
            value = 0, type = "integer", min = 0, max = 1800, step = 10,
            unit = "s", apply = "live", label = "Cordon length", group = "Cordon", order = 5,
            description = "How long the whole closure takes, from the first zone starting to close to the last shrink finishing. The per-step timings are derived from it, so this is the one number that sets match length on every map. 0 uses the preset (standard: 300 s).",
        },
        cordonGrace = {
            value = 0, type = "integer", min = 0, max = 600, step = 5,
            unit = "s", apply = "live", label = "Loot window", group = "Cordon", order = 6,
            description = "From the drop to the first zone starting to close. The only number that answers 'how long before this becomes a fight'. 0 uses the preset (standard: 45 s).",
        },
        cordonSteps = {
            value = 0, type = "integer", min = 0, max = 24, step = 1,
            apply = "live", label = "Cordon steps", group = "Cordon", order = 7,
            description = "How many zones a player is asked to move between. A CEILING: a map with fewer Chebyshev rings than this gets fewer phases, because a phase that closes nothing is worse than no phase. 0 uses the preset (standard: 9).",
        },
        -- ---------------------------------------------------------------
        -- CORDON
        -- ---------------------------------------------------------------
        damageScale = {
            value = 1.0, type = "number", min = 0.1, max = 4.0, step = 0.1,
            apply = "live", label = "Cordon damage scale", group = "Cordon", order = 1,
            description = "Multiplies every phase's HP/s, live, on the running match -- and the HUD shows the scaled figure, because the rate a player is told is the rate the server applies. Below 1 the boundary stops being a boundary; above 2 a wrong turn is fatal before the compass can be read. Does not touch weapon damage.",
        },
        -- THE ONE SWITCH THAT MATTERS FOR THE EDGE, and it is a tunable
        -- rather than a config edit for the same reason `drop` is: the first
        -- thing an operator will want, the first time a client reports the
        -- world edge costing frames or drawing in the wrong place, is to turn
        -- it off without reloading the resource under a live match.
        --
        -- It reaches the client through the `cordon:bounds` payload, which is
        -- pushed on every closure, so a change lands on the next closed block
        -- rather than at the next match. `off` and `hud` both retire every post
        -- the client is holding.
        cordonEdge = {
            value = "world", type = "enum", choices = { "off", "hud", "world" },
            apply = "live", label = "Cordon edge", group = "Cordon", order = 4,
            description = "Reach for this first if the boundary misbehaves. 'world' builds the boundary out of the game's own geometry -- a hesco wall with an orange hologram strip and red beacons on the nearest eighty metres, concrete roadblocks beyond it, and a shipping container, a fire and a red light at each segment marker -- plus the graded screen rim -- occluded by buildings and standing on the ground, because it is real engine geometry; 'hud' drops all of that and projects the boundary onto a screen overlay instead, which shows through walls and floats at the horizon when it is far away -- the fallback, not the intent; 'off' drops both but keeps the outside banner and the compass. The world layer is drawn client-side, so it costs no network traffic.",
        },
        gridSize = {
            value = 14, type = "integer", min = 6, max = 24, step = 1,
            apply = "live", label = "Grid size", group = "Cordon", order = 2,
            description = "NOT IMPLEMENTED (audited 2026-09-03: nothing in this resource reads this key). The cordon takes its lattice from the ACTIVE MAP, not from this key, so changing it re-tags nothing and moves no block. Kept because it records the v1 shape: 14 blocks per side at 100 m each, ~2 km^2, the surveyed Pacifica sector.",
        },
        activeMap = {
            -- An editable starter; existing persisted active-map choices remain authoritative.
            value = "dogtown", type = "string",
            apply = "live", label = "Active map", group = "Cordon", order = 3,
            description = "Which map from the runtime store this server plays. 'dogtown' is the editable default starter; surveyed built-ins remain available. Author maps in-game with /br.map; geometry never lives under resources/, because the 1 Hz watcher hot-swaps the whole set.",
        },
        -- ---------------------------------------------------------------
        -- LOOT AND WORLD
        -- ---------------------------------------------------------------
        lootDensity = {
            value = 1.0, type = "number", min = 0.25, max = 2.0, step = 0.05,
            apply = "live", label = "Loot density", group = "World", order = 1,
            description = "Scales requested counts, retaining one per authored anchor. Extra drops require separated space inside the authored radius; zero-radius points never stack. The 900 seed budget is enforced. Shortages are logged.",
        },
        holdoutsEnabled = {
            value = false, type = "boolean",
            apply = "live", label = "Gang holdouts", group = "World", order = 2,
            description = "Gang camps standing on the map's richest surveyed loot clusters, spawned at `live` and removed at `staging` by server/holdouts.lua. IMPLEMENTED 2026-09-04, and still DEFAULTED OFF: turning tier-4 loot into a fight changes the shape of a match and that is the owner's call. The camp does not script combat -- the records run the engine's own AI, which is why they are gang records and not civilians. Sites, seats and the tier gate are the three keys below.",
        },
        holdoutSites = {
            value = 6, type = "integer", min = 1, max = 24, step = 1,
            apply = "live", label = "Holdout sites", group = "World", order = 3,
            description = "How many camps may stand at once. The marks are taken richest-tier first, so a map with more qualifying clusters than this guards its BEST loot rather than its first-authored loot. Watson only surveys three clusters at tier 3+, so it stands three camps whatever this says.",
        },
        holdoutSize = {
            value = 4, type = "integer", min = 1, max = 12, step = 1,
            apply = "live", label = "Holdout size", group = "World", order = 4,
            description = "NPCs per camp, spawned on a 3.5 m ring around the mark rather than stacked on it -- four records on one point get shoved apart by the engine and walk out of their own camp before anybody arrives. They are MORTAL, unlike the reference resource's demo NPC: a camp that cannot be cleared is a wall.",
        },
        holdoutMinTier = {
            value = 3, type = "integer", min = 1, max = 4, step = 1,
            apply = "live", label = "Holdout tier gate", group = "World", order = 5,
            description = "The lowest loot tier a camp will stand on. At 3 the two tier-3 marks and the tier-4 mark are guarded and the tier-1/2 street loot stays free, which is the intended shape: the fight is the price of the good gun, not of every gun.",
        },
        bossEnabled = {
            value = false, type = "boolean",
            apply = "live", label = "Cyberpsycho", group = "World", order = 3,
            description = "Spawn one boss at a tier-4 mark at Cordon 4. OFF and cannot be turned on yet: it needs a record promoted into the server-owned alias registry, which is a reviewed platform step.",
        },
        blackoutEnabled = {
            value = false, type = "boolean",
            apply = "live", label = "Blackout", group = "World", order = 4,
            description = "NOT IMPLEMENTED (audited 2026-09-03: nothing in this resource reads this key). Design intent: at Cordon 4, 25 s of night with every edge light off -- cheap, loud and memorable. It would stay off by default even once built, because a boundary you cannot see is the one thing this mode cannot afford to hide.",
        },
        supplyDrops = {
            value = false, type = "boolean",
            apply = "live", label = "Supply drops", group = "World", order = 5,
            description = "NOT IMPLEMENTED (audited 2026-09-03: nothing in this resource reads this key). DEFAULTED OFF for the same reason as the holdouts above: an operator switch that is on and does nothing is worse than one that is off and says so. Design intent: one crate per closure from Cordon 2 on, landing inside the next cordon with six legendary-tier drops around it.",
        },
        -- ---------------------------------------------------------------
        -- SQUADS
        -- ---------------------------------------------------------------
        reviveWindowSeconds = {
            value = 60, type = "integer", min = 15, max = 120, step = 5,
            unit = "s", apply = "live", label = "Revive window", group = "Squads", order = 1,
            description = "Maximum downed window in Solo and Squad; successive downs cap it at 60/45/30/20/15 seconds per match. Self-revive unlocks after at most 25 seconds, leaving at least 5 seconds for the 3-second hold before zone acceleration.",
        },
        bleedOutCordonFactor = {
            value = 3.0, type = "number", min = 1.0, max = 20.0, step = 0.5,
            apply = "live", label = "Cordon bleed-out", group = "Squads", order = 2,
            description = "How much faster a body that went down OUTSIDE the cordon runs out of time. It shortens the one deadline the body already has -- the revive window, or the elimination hold when nobody can come -- rather than adding a second damage stream, so the HUD's revive bar and the sweep always agree. 1.0 restores the old behaviour, where the cordon ignored the downed completely and dying in the bleed was the safest way to stop bleeding. The verdict is taken once, at the moment of death.",
        },
        spectateMode = {
            value = "staging", type = "enum", choices = { "staging", "ghost" },
            apply = "live", label = "Spectating", group = "Squads", order = 3,
            description = "'staging' returns an eliminated player to the lobby to watch on the panel. 'ghost' flies them over their squad -- and is UNPROVEN: it depends on a ghosted, god-moded, noclipping player being invisible and harmless to others (experiment E4, not yet run). Leave it on 'staging' until that is measured.",
        },
        -- ---------------------------------------------------------------
        -- BOTS
        -- ---------------------------------------------------------------
        botFill = {
            value = "off", type = "enum", choices = { "off", "threshold", "always" },
            apply = "live", label = "Bot fill", group = "Bots", order = 1,
            description = "Disabled by default. off: human contestants only. threshold: fill to the target when humans are below the floor. always: fill every empty slot. Any match containing a bot is never rated.",
        },
        botFillTarget = {
            value = 40, type = "integer", min = 0, max = 64, step = 1,
            apply = "live", label = "Bot fill target", group = "Bots", order = 2,
            description = "How many contestants -- humans plus bots -- a filled match aims for. 40 is 40 server-owned NPCs in one bucket against a 4096 registry and a 512-per-resource cap; the real cost is the client authority lease and streaming, measured by E11 at that number.",
        },
        botFillFloor = {
            value = 24, type = "integer", min = 0, max = 64, step = 1,
            apply = "live", label = "Bot fill floor", group = "Bots", order = 3,
            description = "Under 'threshold', bots are added only when fewer than this many humans are in staging. On a busy server the fill never fires at all, which is what makes 'threshold' safe as the default.",
        },
        -- ---------------------------------------------------------------
        -- RATING
        -- ---------------------------------------------------------------
        ratedMinPlayers = {
            value = 16, type = "integer", min = 2, max = 64, step = 1,
            apply = "live", label = "Rated minimum", group = "Rating", order = 1,
            description = "Matches with fewer contestants than this are not rated. A placement model divides by the field size less one, so a four-player 'match' moves ratings by an amount that means nothing.",
        },
        ratingK = {
            value = 32, type = "integer", min = 1, max = 200, step = 1,
            apply = "live", label = "Placement K", group = "Rating", order = 2,
            description = "How far one match can move a rating, after the pairwise placement model divides by the field size less one. One K per format; a match exchanges once, so this sits well above a per-round K.",
        },
    },
}

-- ---------------------------------------------------------------------------
-- PLAYER AREA OF INTEREST -- A NOTE, BECAUSE IT IS NOT A TUNABLE HERE AND
-- SOMEBODY WILL COME LOOKING FOR IT IN THIS TABLE.
--
-- Plan section 13 lists `playerInterest` among the operator-facing values, and
-- it is one -- but it is a SERVER setting, not a resource tunable, and it
-- cannot be declared above. It lives in `server.jsonc` as
-- `simulation.playerInterestRadius` and `simulation.playerInterestHysteresis`,
-- implemented in `SessionManager` as a per-viewer interest set reconciled once
-- per server tick and expressed to clients through the existing
-- `PlayerJoined` / `PlayerLeft` roster messages.
--
-- WHY IT MATTERS TO THIS FILE, AND WHY IT IS WRITTEN DOWN HERE. It is ZERO --
-- disabled -- by default, so that every mode built before Cordon behaves
-- exactly as it did. A server that runs this mode at `maxPlayers = 64` with the
-- radius left at zero relays every player's snapshot to every other player: 64 x
-- 63 relays per snapshot tick, ~326 KB/s of pure player-snapshot traffic per
-- player, measured to kill the link outright at the transport's 256 KB/s
-- default clamp (E1). With interest on and players spread over the sector, the
-- same measurement gives ~23 KB/s -- 13.4x less -- and correctly saves nothing
-- when all 63 genuinely are inside one 50 m ball.
--
-- So: 500 m radius (the longest ranged damage the server honours, per
-- `DamageAuthorityService.RangeFor` -- culling below it would silently cap
-- sniping, because the shooter's client would never have been sent the player it
-- is being asked to hit), with hysteresis on the way out only. The mode cannot
-- enforce this. `server/main.lua` should READ it at startup and log loudly when
-- it is zero and `maxPlayers` is above ~24, because the failure mode is a server
-- that runs fine in testing and dies on its first full lobby.
-- ---------------------------------------------------------------------------
