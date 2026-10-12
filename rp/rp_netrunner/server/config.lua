-- rp_netrunner / server/config.lua: everything an operator may move or retune for the contract
-- job (breach contracts, sites, the fixer drop, pay, the trace). The quickhacks shared with the
-- client (ping, Short Circuit, Overheat, jammer) are in shared/config.lua.
--
-- Positions are catalogue anchors, never invented: the desk terminals are the vanilla AI spots of
-- office workers typing at a real keyboard (open77_furniture, catalogue furniture-1-26de4c86091e,
-- and open77_pedestrians spots-generated.lua, dataset cp2077-2310-9ff49a042f46aff01c17f276); the
-- others are vanilla tablet spots. A point is `measured = true` once a breach ran on it in game
-- (the junction box over the Afterlife, the City Center lobby desk, the club back-office desk); the
-- others are `measured = false`: nobody has breached there yet. Stand on it, read `/pos`, correct it.

NetrunnerConfig = {}
local C = NetrunnerConfig

-- The jobs (rp_jobs) and the societies their sales pay (rp_jobs job name = rp_economy society name).
C.job = "netrunner"
C.fixerJob = "fixer"
C.bucket = 0

-- Breaching and delivering ask rp_jobs: on duty as a netrunner. The epoch guard ends a running
-- breach at once on a clock-off, a job or a grade change.
C.eligibility = { resource = "rp_jobs", export = "eligible", args = { job = "netrunner", duty = true } }
C.epochs = { resource = "rp_jobs", read = "workEpoch", event = "rp_jobs:workEpoch" }
-- Posting and cancelling a contract as a player: on duty as a fixer.
C.fixerRequirement = { job = "fixer", duty = true }

-- ---------------------------------------------------------------------------------------------
-- Items. Defined through rp_inventory:define (the single definer toward the coordinator).
-- `chip` (the breach kit burned by every completed attempt) is an rp_inventory built-in.
-- ---------------------------------------------------------------------------------------------
C.items = {
    -- One unique shard per contract (instance `nrs.<contract id>`), minted by a successful breach,
    -- burned by the delivery. Contraband: an NCPD search finds it.
    nr_data_shard = { label = "Data shard", weight = 0.05, unique = true, usable = false, illegal = true,
                      category = "data" },
    -- The contract record itself: one instance per contract on the board (`nrc.<contract id>`),
    -- its metadata is the contract. It never leaves the board stash except to be retired.
    nr_contract = { label = "Breach contract", weight = 0.001, unique = true, usable = false, illegal = false,
                    category = "contract" },
}

-- ---------------------------------------------------------------------------------------------
-- Coordinator accounts. The board is one stash (deterministic id: a restart finds the same
-- contracts with one read). sys:netrunner is where contracts and shards are minted from (a mint
-- rule) and where burned kits, shards and retired contracts go (no rule needed to burn).
-- ---------------------------------------------------------------------------------------------
C.accounts = {
    board = "stash:nr.board:contracts",
    source = "sys:netrunner",
    sink = "sys:netrunner",
}
C.boardCapacityG = 1000

-- ---------------------------------------------------------------------------------------------
-- Difficulty and pay per tier. chance = baseChance + gradeBonus x rp_jobs grade (0..3)
-- - retryPenalty x attempts already made, clamped to minChance..maxChance; the roll is drawn from
-- the breach's operation id (the same operation always rolls the same number).
-- ---------------------------------------------------------------------------------------------
C.tiers = {
    [1] = { label = "Street node", durationMs = 12000, baseChance = 75,
            reward = { min = 300, max = 700, default = 450 }, minutes = { min = 15, max = 60, default = 40 } },
    [2] = { label = "Corporate subnet", durationMs = 18000, baseChance = 55,
            reward = { min = 800, max = 1600, default = 1100 }, minutes = { min = 20, max = 90, default = 50 } },
    [3] = { label = "Datafort", durationMs = 25000, baseChance = 40,
            reward = { min = 1600, max = 3000, default = 2200 }, minutes = { min = 30, max = 120, default = 60 } },
}
C.difficulty = { gradeBonus = 8, retryPenalty = 5, minChance = 10, maxChance = 95 }

-- How the netrunner sits or stands while breaching (open77_actions animation; `at = "target"` puts
-- the body on the site's point facing its yaw). `required = false`: a client without the pose still
-- runs the breach (the bar, the claim, the checks), it only loses the presentation.
C.poses = {
    -- an office worker typing at a desk keyboard (the vanilla workspot of the desk itself)
    desk = { profile = "amb_d7c499_sit_chair_table_keybo", at = "target", arrivalRadius = 1.0, required = false },
    -- standing, both hands on a tablet (rp-profiles `tablet2`, brings its own tablet)
    tablet = { profile = "tablet2", at = "target", arrivalRadius = 1.0, required = false },
    -- sitting on the ground with a laptop (rp-profiles `laptop`, brings its own laptop): a jack-in
    laptop = { profile = "laptop", at = "target", arrivalRadius = 1.0, required = false },
}

-- ---------------------------------------------------------------------------------------------
-- Breach sites. `pose` picks C.poses; `npc = true` lets the NPC fixer post contracts on it.
-- ---------------------------------------------------------------------------------------------
C.sites = {
    {
        key = "watson_junction", label = "Junction box above the Afterlife", area = "Watson, the alley over the Afterlife",
        tier = 1, pose = "laptop", npc = true, enabled = true,
        position = { x = -1434.631, y = 989.401, z = 23.260 }, yaw = -56.0, measured = true,
        source = "open77_pedestrians spot row 3217 (amb_f8fa00_kneel_ground_tablet), street level above the club; " ..
            "breached in game (laptop pose, success and a traced failure)",
    },
    {
        key = "den_node", label = "Market-hall netrunner den", area = "930 m south of NCPD HQ",
        tier = 2, pose = "tablet", npc = true, enabled = true,
        position = { x = -1907.820, y = -1927.096, z = 48.903 }, yaw = -24.0, measured = false,
        source = "spot row 2869 (amb_148b83_stand_ground_tablet), 4.8 m from the netrunner chairs " ..
            "16528104635163718811 / 16528105734675347022",
    },
    {
        key = "corp_lobby", label = "Corporate lobby terminal", area = "City Center, 310 m east of NCPD HQ",
        tier = 2, pose = "desk", npc = true, enabled = true,
        position = { x = -1450.216, y = -1038.966, z = 9.281 }, yaw = -87.24, measured = true,
        source = "furniture 4013872865819777899 = spot row 8594 (sit_chair_table_keyboard work), 310 m east of NCPD HQ; " ..
            "breached in game at the desk",
    },
    {
        key = "club_office", label = "Club back-office terminal", area = "1.4 km south-west of the Afterlife",
        tier = 2, pose = "desk", npc = true, enabled = true,
        position = { x = -2440.810, y = 51.412, z = 4.160 }, yaw = 0.0, measured = true,
        source = "furniture 11181519055687801554 = spot row 25016 (sit_chair_table_keyboard work), under a bar; " ..
            "breached in game at the desk (three traced failures)",
    },
    {
        key = "plaza_desk", label = "Plaza security desk", area = "610 m west of NCPD HQ",
        tier = 3, pose = "desk", npc = true, enabled = true,
        position = { x = -2364.606, y = -927.932, z = 12.266 }, yaw = 96.0, measured = false,
        source = "furniture 4080162105142424950 = spot row 8727 (sit_chair_table_keyboard work)",
    },
    {
        key = "office_workstation", label = "Corporate office workstation", area = "1.1 km west-south-west of the Afterlife",
        tier = 3, pose = "desk", npc = true, enabled = true,
        position = { x = -2413.342, y = 400.497, z = 11.827 }, yaw = 2.0, measured = false,
        source = "furniture 14274856704730037017 = spot row 31673 (sit_chair_table_keyboard work)",
    },
}
C.maxDistance = 2.5        -- the server's distance check at the start and before paying
C.promptDistance = 2.0

-- ---------------------------------------------------------------------------------------------
-- Fixer drops: one E prompt, "Talk to the fixer": it opens the board, or hands the shard over when
-- the netrunner carries the shard of a contract posted here.
-- ---------------------------------------------------------------------------------------------
C.fixers = {
    {
        key = "afterlife", label = "Fixer drop - Afterlife back room", name = "The Afterlife's fixer",
        position = { x = -1419.9, y = 989.4, z = 16.6 }, yaw = 0.0, measured = false,
        source = "rp_netrunner 1.x access point (AMM -1419.9, 989.4, 16.5), 21 m from rp_fixer's office ring",
    },
}

-- The NPC fixer: keeps `open` contracts on the board (sites with `npc = true` and no contract),
-- posted at `fixer`, rewards drawn inside the tier's bounds, rounded to `round`.
C.npcBoard = { enabled = true, fixer = "afterlife", open = 3, everyMs = 60000, round = 50 }

-- The fixer's cut of every reward: to the fixer society for NPC contracts, to the posting fixer's
-- own cash for a player's contract. rate 0 = no cut.
C.cut = { rate = 0.15, npcTo = { society = "fixer" } }

C.contracts = {
    maxOpen = 24,             -- contracts on the board at once (every state)
    maxPerFixer = 3,          -- open contracts one player fixer may have posted
    oneBySite = true,         -- one live contract per site (a netrunner holds one contract at a time)
}

-- A failed breach: "retry" keeps the contract with the netrunner, "reopen" puts it back on the
-- board, "fail" ends it. Whatever the mode, the contract fails after maxAttempts failed breaches.
-- The site's ICE stays alert for siteAlertMs: nobody can breach it again before.
C.failure = { mode = "retry", maxAttempts = 3, siteAlertMs = 60000 }

-- What a failed breach leaves behind. dispatch: rp_ncpd:alert at the site (officers on duty get a
-- dispatch line and a map pin); record: an entry in the netrunner's NCPD record; wantedLevel: the
-- native NCPD heat on the netrunner's own game for wantedMs (0 = none; never lowers a higher one).
C.trace = {
    dispatch = true, record = true, revealName = false, wantedLevel = 1, wantedMs = 120000,
    text = "ICE trace: breach attempt at %s",
}

-- The kit a completed breach burns (success or failure). nil = free.
C.breach = { item = "chip", count = 1 }

-- Delivery. drop: the fixer drop's E prompt (NPC contracts, or a player's contract while its fixer
-- is away). handover: a consented hand-over to the player fixer who posted it.
C.deliver = {
    durationMs = 2500,
    animation = { profile = "give", at = "self", loop = false, required = false },
    dropWhenFixerAway = true,
    handover = { durationMs = 3000, startDistance = 3.0, breakDistance = 5.0, inviteTimeoutMs = 20000 },
    buyer = "client",         -- rp_economy sale buyer { sys = "client" }: the off-screen client pays
    reason = "netrunner contract",
}

-- The board prompt.
C.board = { durationMs = 500, animation = { profile = "phonecheck", at = "self", loop = false, required = false } }

-- ---------------------------------------------------------------------------------------------
-- Maintenance
-- ---------------------------------------------------------------------------------------------
C.sweepMs = 5000            -- refresh the board, expire contracts, settle doubts, NPC postings, heat
C.notifyCooldownMs = 1500   -- at most one refusal toast per player per this many ms
C.lostOfferMs = 60000       -- a hand-over with no platform state and no event for this long is dropped
