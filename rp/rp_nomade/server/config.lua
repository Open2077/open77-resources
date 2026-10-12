-- rp_nomade / server/config.lua: everything an operator may move or retune.
--
-- Places. The camp points come from rp_nomade 1.0 (the Aldecaldos camp around V's nomad tent in
-- the north-eastern Badlands, AMM ground + 0.1, run in game with that version) and the
-- destinations from points other RP resources drive to (rp_delamain presets, the rp_nomade 1.0
-- Afterlife street drop). They are reused as DATA only. The Afterlife drop (unload bay and fence)
-- was walked with THIS resource and is flagged as measured; the camp's points worked in live runs
-- and keep their unmeasured flag, like the Kabuki drop, until someone confirms them. Stand on the
-- spot, read `/pos`, paste it here and flip the flag. The NCPD checkpoints are placed by
-- arithmetic on the camp -> city corridor: drive the GPS route and move each one onto the road where
-- it really crosses into the city.

NomadConfig = {}
local C = NomadConfig

-- The job (rp_jobs job name = rp_economy society name) and the id the fixer board reads.
C.job = "nomade"
C.society = "nomade"
C.fixerJob = "nomad"
C.bucket = 0

-- The police job (rp_jobs) whose on-duty members may search a truck (`/nomad search`).
C.policeJob = "ncpd"

-- Taking a run, loading, unloading and returning ask rp_jobs: on duty as a nomad. The epoch guard
-- refuses a commit after a job, grade or duty change.
C.eligibility = { resource = "rp_jobs", export = "eligible", args = { job = "nomade", duty = true } }
C.epochs = { resource = "rp_jobs", read = "workEpoch", event = "rp_jobs:workEpoch" }
C.policeEligibility = { resource = "rp_jobs", export = "eligible", args = { job = "ncpd", duty = true } }

-- ---------------------------------------------------------------------------------------------
-- Items, defined through rp_inventory:define (the single definer toward the coordinator).
--   nomad_contraband  the smuggled goods: they live in the camp's stash, ride in the crates, end
--                     at the fence (burned), in a buyer's pockets or in the NCPD evidence stash.
--                     `illegal = true`: rp_ncpd's /fouille names them in a buyer's pockets.
--   nomad_crate       the crate's custody token: one unique instance per crate. It sits in the
--                     crate while the crate is on the ground or carried, and in the truck bed
--                     (veh:<plate>:cargo) while it rides; rp_cargo moves instances, so the token is
--                     what a truck carries. A load names `crate.bedModel` (crate.ammo_box) for the
--                     bed; rp_cargo's own default for the item (crate.small) only draws a token
--                     another resource moved into a bed.
-- ---------------------------------------------------------------------------------------------
C.items = {
    nomad_contraband = { label = "Smuggled goods", weight = 2.5, usable = false, illegal = true, category = "material" },
    nomad_crate = { label = "Nomad cargo crate", weight = 5.0, unique = true, usable = false, illegal = false,
                    category = "cargo" },
}
-- Grams per unit as the coordinator charges them (must match `weight` above).
C.weightsG = { nomad_contraband = 2500, nomad_crate = 5000 }
C.goodsItem = "nomad_contraband"
C.tokenItem = "nomad_crate"

-- ---------------------------------------------------------------------------------------------
-- Coordinator accounts. Stash keys are fixed, so a restart finds them with no lookup. sys:
-- accounts are journal-only sources and sinks (no second colon: the mint rule grammar).
-- ---------------------------------------------------------------------------------------------
C.accounts = {
    stash = "stash:nmd.aldecaldos:goods",     -- the camp's contraband: what every run carries out
    evidence = "stash:ncpd.evidence:seized",   -- NCPD evidence: everything a search confiscates
    tokens = "sys:nomad",                      -- crate tokens are minted here and burned back here
    supplier = "sys:nomad.supplier",           -- the camp's restock (mint)
}
C.stashCapacityG = 600000       -- 240 units of goods
C.evidenceCapacityG = 2000000

-- The camp's supplier: every `everyMs` the stash is topped up by `amount` when it holds fewer
-- than `below` units. One operation per window (its id is the window number): a restart inside a
-- window replays it instead of adding twice. `amount = 0` turns it off (stock by console only).
C.restock = { everyMs = 10 * 60 * 1000, below = 24, amount = 24 }

-- ---------------------------------------------------------------------------------------------
-- The camp: the Aldecaldos camp, north-eastern Badlands (rp_zones `nomad_camp`, centre
-- 1792.9, 2248.9, 180.2). Positions are where the player stands (the prompt card floats 1 m up).
-- ---------------------------------------------------------------------------------------------
C.camp = {
    label = "Aldecaldos camp",
    position = { x = 1792.9, y = 2248.9, z = 180.2 },                  -- V's tent, what /nomad camp reports
    board = { position = { x = 1790.0, y = 2252.0, z = 180.3 }, yaw = 0.0, measured = false,
              label = "Aldecaldos contracts board" },
    -- One crate per point, in order (a route asks for at most this many crates).
    loadingPoints = {
        { x = 1786.0, y = 2256.0, z = 180.3, measured = false },
        { x = 1788.0, y = 2258.0, z = 180.3, measured = false },
        { x = 1790.0, y = 2258.5, z = 180.3, measured = false },
        { x = 1792.0, y = 2257.0, z = 180.3, measured = false },
    },
    -- The truck bay: park the truck with its bed here; carrying a crate, "Load into the truck".
    -- rp_nomade 1.0 spawned its Mackinaw on this spot (yaw 58.6, the tent's heading).
    truckBay = { position = { x = 1800.0, y = 2240.0, z = 180.2 }, truckRadius = 8.0, measured = false,
                 label = "Convoy truck bay" },
    -- The stash: carrying a crate of the camp, "Return to the stash" (goods back, no pay).
    returnBay = { position = { x = 1788.2, y = 2253.6, z = 180.3 }, yaw = 58.6, measured = false,
                  label = "Camp stash" },
    -- Set dressing (open77_props aliases, server props seen by everyone): the vanilla camp is quest
    -- content the multiplayer world never streams, so without it the board's card floats over bare
    -- desert. A table under the board, loaded pallets beside the loading points and the stash (none
    -- near the truck bay: a parked truck needs the room). {} for none.
    decor = {
        { model = "furniture.table.outdoor", position = { x = 1790.0, y = 2252.4, z = 180.25 }, yaw = 0.0 },
        { model = "pallet.wood.loaded", position = { x = 1783.9, y = 2257.0, z = 180.25 }, yaw = 30.0 },
        { model = "pallet.stack", position = { x = 1786.4, y = 2252.8, z = 180.25 }, yaw = 58.6 },
    },
}

-- ---------------------------------------------------------------------------------------------
-- Routes: one choice each on the contracts board (up to four). `fence` is where a crate is
-- handed over (drop point, an NPC stands behind it); `unloadBay` where the truck parks and the
-- crew takes the crates out of the bed. `price` is what the fence pays per crate; the camp keeps
-- `campCut` of it (soc:<society>), the rest goes to the nomad who took the run.
-- ---------------------------------------------------------------------------------------------
C.routes = {
    {
        id = "afterlife", label = "Run to the Afterlife street",
        description = "Smuggled goods for a fence on the Afterlife street, Watson.",
        crates = 3, goodsPerCrate = 4, price = 600, timeLimitMs = 25 * 60 * 1000,
        destination = {
            label = "Afterlife street, Watson",
            -- Walked in game: the truck parks in the northbound lane against the east curb outside the
            -- club's ramp; the fence waits on the sidewalk by the trash bags, facing the road (the
            -- 1.0 points put both on the centre line, the fence standing in traffic).
            unloadBay = { position = { x = -1422.5, y = 975.0, z = 23.35 }, truckRadius = 8.0, measured = true },
            fence = { position = { x = -1417.5, y = 975.5, z = 24.25 }, yaw = 90.0, measured = true,
                      name = "Rook", label = "Rook, the fence" },
            arrivalRadius = 40.0,
        },
    },
    {
        id = "kabuki", label = "Run to Lizzie's, Kabuki",
        description = "Two crates for a fence working the street outside Lizzie's Bar.",
        crates = 2, goodsPerCrate = 4, price = 550, timeLimitMs = 25 * 60 * 1000,
        destination = {
            label = "Lizzie's Bar, Kabuki",
            -- rp_delamain's `lizzies` preset: a cab stops there, so a truck can.
            unloadBay = { position = { x = -1188.9, y = 1566.2, z = 22.9 }, truckRadius = 8.0, measured = false },
            fence = { position = { x = -1186.4, y = 1567.5, z = 22.9 }, yaw = 90.0, measured = false,
                      name = "Mama Tsu", label = "Mama Tsu, the fence" },
            arrivalRadius = 40.0,
        },
    },
}
-- An NPC stands at each fence (presentation only: the drop point works without it).
-- damagePolicy 2 = invulnerable (Open77.npcs.damage).
C.fenceNpc = { template = "civilian_female_relaxed_01", damagePolicy = 2 }
C.campCut = 0.20
-- A crate handed to the fence outside a live run of the crew (stolen, the run failed or
-- expired) is "hot": the fence pays the seller this share of the price, nothing to the camp, and
-- no delivery is counted. 0 = the fence refuses hot goods.
C.hotRatio = 0.5
C.maxRunsPerNomad = 1
C.maxOpenCrates = 64            -- crates of every run on the server (carry items: at most 128)

-- ---------------------------------------------------------------------------------------------
-- NCPD checkpoints on the roads into the city. Entering one with goods in the truck bed rolls a
-- search, deterministic per run and checkpoint (the same run always meets the same answer at the
-- same checkpoint): `searchChance` in percent. A search confiscates every crate of that run in
-- the truck (moved to the evidence stash in one operation), fines the driver and raises their
-- NCPD wanted level. `zone` is an Open77.zones definition; the check is the truck's position.
-- Points by arithmetic on the corridor from the camp (1793, 2249) to Watson: NOT road points.
-- ---------------------------------------------------------------------------------------------
C.checkpoints = {
    {
        id = "badlands_toll", label = "NCPD checkpoint, Badlands highway",
        zone = { shape = "cylinder", position = { x = 900.0, y = 1900.0, z = 120.0 }, radius = 120.0, maxHeight = 200.0 },
        searchChance = 25, measured = false,
    },
    {
        id = "watson_ramp", label = "NCPD checkpoint, Watson entry",
        zone = { shape = "cylinder", position = { x = -500.0, y = 1700.0, z = 40.0 }, radius = 120.0, maxHeight = 200.0 },
        searchChance = 35, measured = false,
    },
}
C.search = {
    fine = 1500,                -- eddies, cash then bank, to soc:<policeSociety>; unpaid -> warrant (rp_ncpd)
    policeSociety = "ncpd",
    wanted = 2,                 -- NCPD wanted level (Open77.players.setWanted) after a checkpoint search
    unpaidWarrant = 1,          -- rp_ncpd warrant level when the fine cannot be paid (0 = none)
}

-- A player NCPD officer: `/nomad search` next to a truck (or a crate on the ground). Authority
-- is rp_garage's (a police warrant on the plate); otherwise the driver or the run's nomad must
-- consent (Open77.playerInteractions, on foot within `consentDistance`).
C.officer = {
    reachM = 6.0,               -- the officer stands this close to the truck (or 3 m from a crate)
    crateReachM = 3.0,
    durationMs = 8000,          -- the search, an open77_actions bar
    animation = { profile = "examine", at = "self" },
    consentDistance = 5.0,
    inviteTimeoutMs = 20000,
    fine = 0,                   -- the officer fines with rp_ncpd's /amende; set > 0 to fine at once
}

-- ---------------------------------------------------------------------------------------------
-- Actions (open77_actions)
-- ---------------------------------------------------------------------------------------------
C.actions = {
    take = { durationMs = 4000, progress = "Signing the manifest",
             animation = { profile = "phone", at = "self" } },
    unload = { label = "Unload a crate", progress = "Unloading", durationMs = 1500 },
}
C.maxDistance = 2.5

-- The crate players carry (an open77_actions carry kind). The library's default binding is tuned
-- for crate.small (a body-width load between both hands); crate.ammo_box is a small box: measured in
-- game (actions.lab.bind, both views), it sits on the forearms against the chest in third person and
-- lies flat, centred, low in the first-person view.
C.crate = {
    model = "crate.ammo_box",
    bedModel = "crate.ammo_box",   -- what rp_cargo draws in the bed
    label = "nomad crate",
    -- vehicleReach is measured to the truck's centre: the tailgate prompt (cfg.bayPrompt) sits 3.4 m
    -- behind it on a Mackinaw and is reached from 2.5 m, so 4.5 refused a player at the prompt
    -- ("Get closer.", measured live). 6.0 covers the prompt's whole reach.
    reach = 2.0, vehicleReach = 6.0,
    binding = {
        bone = "Chest",
        offset = { x = -0.12, y = -0.42, z = -0.22 }, rotation = { x = 0.0, y = 90.0, z = 0.0 },
        -- first person, measured level and 30 degrees down (2026-10-13): the Chest slot does not follow
        -- the view's pitch while the hands do; 0.6 m ahead it floated mid-screen when looking down
        firstPerson = { offset = { x = 0.08, y = -0.32, z = -0.28 }, rotation = { x = 90.0, y = 0.0, z = 0.0 } },
    },
    -- Who may lift a crate off the ground: "anyone" (a crate left alone can be stolen: the run of
    -- its nomad fails) or "crew" (nomads on duty only).
    pickupBy = "anyone",
}
C.truckNearM = 6.0              -- /nomad load and /nomad unload look for a truck this close
-- The "Load into the truck" and "Unload a crate" prompts follow the truck parked in their bay: drawn
-- behind its bed (rp_cargo's layout, `behindBedM` past the last slot), where a player can stand,
-- instead of at the bay's centre, which a parked truck covers. Without a truck they stay at the bay.
C.bayPrompt = { followTruck = true, behindBedM = 1.0 }

-- ---------------------------------------------------------------------------------------------
-- A crate sold to another player (consented hand-over, the crate on the ground next to the seller)
-- ---------------------------------------------------------------------------------------------
C.playerSale = {
    minPrice = 100, maxPrice = 5000,
    startDistance = 3.0, breakDistance = 5.0, crateReachM = 3.0,
    inviteTimeoutMs = 20000, durationMs = 3000,
}

-- ---------------------------------------------------------------------------------------------
-- Navigation (client: Open77.blips, ui.vanilla.map). A pin on the destination from the start of
-- the run; the GPS route once every crate is in a truck (`gpsFrom = "loaded"`) or at once
-- (`"accepted"`); a pin and route back to the camp when the run failed with goods still out.
-- ---------------------------------------------------------------------------------------------
C.navigation = {
    enabled = true, gpsFrom = "loaded",
    destinationSprite = "objective", campSprite = "quest",
    checkpointSprite = "HazardWarningVariant", showCheckpoints = true,
}

-- ---------------------------------------------------------------------------------------------
-- Upkeep
-- ---------------------------------------------------------------------------------------------
C.tickMs = 1000                 -- trucks at checkpoints, deadlines, destination arrival
C.sweepMs = 5000                -- doubts, retires, re-placements, restock
C.abandonMs = 2 * 60 * 60 * 1000   -- a crate on the ground this long after its run ended goes back to the stash
C.notifyCooldownMs = 1500
C.ui = { author = "Aldecaldos", color = { 242, 179, 61 }, icon = "CARGO" }
