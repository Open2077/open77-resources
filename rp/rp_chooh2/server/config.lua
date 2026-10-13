-- rp_chooh2 / server/config.lua: everything an operator may move or retune.
--
-- Places, all walked in game. The fields are the planted bed along the outer wall of the
-- Biotechnica protein farm on the northern edge of Northside (the greenhouse halls behind the wall
-- are closed; the bed between the wall and the sidewalk slopes down to the north, so each row has
-- its own height), with the road beside it for the truck. The refinery is the Petrochem tank farm
-- of the North Sunrise Oil Field (sub-district Badlands_NorthSunriseOilField): the stations stand
-- at the base of the storage tank centred near -1454.6, 4013.5 (radius 16.5 m), the depot on its
-- south side. The road between the two sites is about 1.2 km.

Chooh2Config = {}
local C = Chooh2Config

C.bucket = 0

-- Jobs (rp_jobs names). The names must exist in the rp_jobs job table (README "Setup"); an
-- operator who does not want new jobs maps the roles onto existing ones here.
C.jobs = {
    harvest = "farmhand",                         -- harvests the rows
    refine = "refinery",                          -- runs the plant, collects and sells canisters
    haul = { "farmhand", "refinery", "nomade" },  -- may lift, load, unload and deliver corn crates
}
-- Who may clock in at which office (rp_jobs setDuty for the player's own job).
C.offices = {
    farm = { "farmhand" },
    refinery = { "refinery" },
}
-- The society that receives the share of a canister sale (rp_economy society = rp_jobs job).
C.society = "refinery"
-- The job id the fixer board reads in `rp:job:completed`.
C.fixerJob = "chooh2"

local function onDuty(job) return { resource = "rp_jobs", export = "eligible", args = { job = job, duty = true } } end
C.eligibility = {
    harvest = onDuty(C.jobs.harvest),
    refine = onDuty(C.jobs.refine),
    haul = onDuty(C.jobs.haul),
}
C.epochs = { resource = "rp_jobs", read = "workEpoch", event = "rp_jobs:workEpoch" }

-- ---------------------------------------------------------------------------------------------
-- Items, defined through rp_inventory:define (the single definer toward the coordinator).
-- ---------------------------------------------------------------------------------------------
C.items = {
    biotech_corn = { label = "Biotechnica corn", weight = 1.0, usable = false, illegal = false, category = "material" },
    chooh2_canister = { label = "CHOOH2 canister", weight = 5.0, usable = false, illegal = false, category = "fuel" },
    -- A corn crate's custody token: one unique instance per crate, moved by rp_cargo into a bed.
    chooh2_crate = { label = "Corn crate", weight = 2.0, unique = true, usable = false, illegal = false,
                     category = "cargo" },
}
-- Grams per unit, as the coordinator charges them (must match the definitions).
C.weightsG = { biotech_corn = 1000, chooh2_canister = 5000, chooh2_crate = 2000 }

-- Coordinator accounts. sys: accounts are journal-only sources and sinks (no second colon).
C.accounts = {
    fields = "sys:chooh2.fields",       -- corn and crate tokens come from here (mint rule)
    refinery = "sys:chooh2.refinery",   -- corn is burned into it, canisters are minted out of it (mint rule)
    retired = "sys:chooh2.fields",      -- a delivered crate's token goes back here
    burned = "sys:chooh2.burned",       -- a canister poured into a tank
    intake = "stash:chooh2.sunrise:intake",
    output = "stash:chooh2.sunrise:output",
}
C.stashes = {
    intake = { capacityG = 400 * 1000 },   -- 400 corn
    output = { capacityG = 200 * 1000 },   -- 40 canisters
}

-- ---------------------------------------------------------------------------------------------
-- The fields: Biotechnica protein farm, north of Northside
-- ---------------------------------------------------------------------------------------------
-- Farm office: farmhands clock in and out here.
C.farmOffice = {
    position = { x = -986.5, y = 2998.0, z = 16.01 }, yaw = -70.8, measured = true,
    label = "Biotechnica farm office", distance = 2.5,
}

-- Corn rows: five open77_containers nodes keyed `node.<key>` in the planted bed, 3 m from the
-- farm's outer wall (measured with rays), yaw -70.8 faces the wall. One charge per harvest, one
-- back every regrowMs, across restarts. Charges and regrowMs apply when a node is first
-- created; an existing node keeps its own (chooh2.reset refills it). A node closed in
-- open77_containers keeps its key spent for good: give it `containerKey = "node.<key>.2"` here.
C.nodeDefaults = { charges = 4, regrowMs = 5 * 60 * 1000 }
C.nodes = {
    { key = "row1", label = "Corn row 1", position = { x = -977.71, y = 3000.01, z = 16.55 }, yaw = -70.8, measured = true },
    { key = "row2", label = "Corn row 2", position = { x = -980.14, y = 3007.01, z = 15.65 }, yaw = -70.8, measured = true },
    { key = "row3", label = "Corn row 3", position = { x = -982.58, y = 3014.01, z = 14.17 }, yaw = -70.8, measured = true },
    { key = "row4", label = "Corn row 4", position = { x = -985.01, y = 3021.01, z = 13.13 }, yaw = -70.8, measured = true },
    { key = "row5", label = "Corn row 5", position = { x = -987.45, y = 3028.01, z = 12.06 }, yaw = -70.8, measured = true },
}
-- A new crate is set down this far from its row, towards the lane centre (off the kneeling spot).
C.crateOffsetM = 1.4
C.laneCentre = { x = -989.0, y = 3014.0, z = 14.0 }   -- the sidewalk beside the bed

-- The farm's truck bay: a truck parked with its bed near the marker.
C.farmBay = {
    position = { x = -994.0, y = 3010.0, z = 14.04 }, label = "Farm loading bay", truckRadius = 8.0, measured = true,
}

-- ---------------------------------------------------------------------------------------------
-- The refinery: Petrochem tank farm, North Sunrise Oil Field
-- ---------------------------------------------------------------------------------------------
C.refineryOffice = {
    position = { x = -1470.19, y = 4004.5, z = 7.12 }, yaw = -60.0, measured = true,
    label = "Petrochem shift office", distance = 2.5,
}
-- Where a truck backs up to be unloaded ("Unload a crate" lifts the top corn crate of the bed).
C.unloadBay = {
    position = { x = -1482.6, y = 4013.5, z = 7.12 }, label = "Refinery unloading bay", truckRadius = 8.0, measured = true,
}
-- The intake hopper: a corn crate put down here empties into the intake stash.
C.intake = {
    position = { x = -1471.99, y = 4018.16, z = 7.12 }, yaw = -105.0, measured = true, label = "Corn intake hopper",
}
-- The control station: the refining run, at the foot of the tank (yaw -90 faces it).
C.control = {
    position = { x = -1472.6, y = 4013.5, z = 7.12 }, yaw = -90.0, measured = true, label = "Fermenter control station",
    -- The card is drawn 0.8 m towards the tank: a batch places the operator ON the stand point, and
    -- a card drawn there (1 m over it) sat inside her body, out of view until she stepped back
    -- (measured live 2026-10-13).
    promptAt = { x = -1471.8, y = 4013.5, z = 7.12 },
}
-- The output rack: operators take canisters from the output stash into their pockets.
C.outputRack = {
    position = { x = -1471.99, y = 4008.84, z = 7.12 }, yaw = -75.0, measured = true, label = "CHOOH2 output rack",
}
-- The fuel depot: the clerk buys canisters (money minted on behalf of this resource, share to
-- the society). The counter is the point players stand at, 1.2 m in front of the clerk.
C.depot = {
    position = { x = -1463.15, y = 3998.69, z = 7.12 }, yaw = 150.0,
    counter = { x = -1463.8, y = 3997.57, z = 7.12 }, measured = true,
    label = "Sunrise fuel depot", name = "the depot clerk", buyer = "depot",
    -- An NPC behind the counter (presentation only; a refusal is logged, the counter still works).
    -- damagePolicy 2 = invulnerable.
    npc = { template = "civilian_male_relaxed_01", record = nil, damagePolicy = 2 },
}
-- The pump: "Refuel the nearest car" with a canister from your pockets.
C.pump = {
    position = { x = -1476.0, y = 3996.0, z = 7.12 }, measured = true, label = "Depot fuel pump", vehicleRadius = 7.0,
}

-- `/chooh2 load`, `/chooh2 unload` and `/chooh2 refuel` look for a vehicle this close to the player.
C.truckNearM = 6.0

-- ---------------------------------------------------------------------------------------------
-- Actions (open77_actions)
-- ---------------------------------------------------------------------------------------------
-- Animation profiles: `scavenge` (kneel, both hands in the dirt) is the one rp_salvage uses;
-- `examine`, `tablet2` and `mechanic` come from the open77_animations catalogue. `required = false`:
-- the step still runs when a client cannot play the pose.
C.actions = {
    harvest = { label = "Harvest corn", progress = "Harvesting", durationMs = 8000,
                animation = { profile = "scavenge", at = "self" } },
    inspect = { label = "Check the row", progress = "Checking the row", durationMs = 3000,
                animation = { profile = "examine", at = "self", required = false } },
    unload = { label = "Unload a crate", progress = "Unloading", durationMs = 1500 },
    refine = { label = "Run a batch", progress = "Fermenting corn into CHOOH2", durationMs = 15000,
               animation = { profile = "tablet2", at = "target", required = false } },
    gauges = { label = "Read the gauges", progress = "Reading the gauges", durationMs = 2000 },
    collect = { label = "Take canisters", progress = "Taking canisters", durationMs = 2500 },
    sell = { label = "Sell canisters", progress = "Selling", durationMs = 2000 },
    refuel = { label = "Refuel", progress = "Pouring CHOOH2", durationMs = 5000,
               animation = { profile = "mechanic", at = "self", required = false } },
    clock = { durationMs = 750 },
}
C.maxDistance = 2.5

-- What one harvest yields, rolled at the server's commit from the operation id (a retried
-- commit draws the same count).
C.harvest = { item = "biotech_corn", min = 3, max = 5 }

-- ---------------------------------------------------------------------------------------------
-- Crates
-- ---------------------------------------------------------------------------------------------
C.crate = {
    model = "crate.ammo_box",    -- a box at hand scale that carries well
    label = "corn crate",
    contentsKg = 20,             -- corn one crate holds (the token's 2 kg come on top)
    joinRadiusM = 2.0,           -- a harvest fills YOUR ground crate within this radius of the row
    maxPerPlayer = 4,            -- open crates (ground, hands or bed) per subject
    maxOpen = 48,                -- open crates on the server (ground crates are carry items: <= 128)
    pickupBy = "crew",           -- "crew": anyone on duty in a haul job; "owner": the harvester only
    -- vehicleReach is measured to the truck's origin and matches C.truckNearM: a player behind a
    -- Mackinaw's bed stands up to ~5.9 m from its origin (measured live by rp_nomade and rp_cargo,
    -- where 4.5 refused them), and with 4.5 a truck `/chooh2 load` found within 6 m refused the crate.
    reach = 2.0, vehicleReach = 6.0,
    binding = nil, gripMs = nil, releaseMs = nil,
    orphanAgeMs = 2 * 60 * 1000, -- an empty, tokenless crate older than this is closed by the sweep
}

-- ---------------------------------------------------------------------------------------------
-- The plant
-- ---------------------------------------------------------------------------------------------
-- One run burns `cornIn` corn from the intake and mints `canistersOut` canisters into the output,
-- in one coordinator operation.
C.refine = { cornIn = 10, canistersOut = 2 }
-- At most this many canisters per "Take canisters" (pockets have a weight limit).
C.collectMax = 3

-- ---------------------------------------------------------------------------------------------
-- Sale and refuel
-- ---------------------------------------------------------------------------------------------
C.prices = { chooh2_canister = 150 }   -- eddies per canister at the depot
C.saleMax = 10                         -- canisters per sale
C.societyShare = 0.10

-- A canister adds this many litres to the tank (open77_fuel never overfills). A tank with less
-- room than `minRoomL` refuses before anything is taken. `reachM`: from the player to the car's
-- origin; `maxSpeedMps`: the car must stand still.
C.refuel = { litres = 15.0, minRoomL = 3.0, reachM = 4.0, maxSpeedMps = 1.0 }

-- ---------------------------------------------------------------------------------------------
-- Maintenance
-- ---------------------------------------------------------------------------------------------
C.sweepMs = 5000            -- settle in-doubt work, retry node charges and pending fills, close crates
C.notifyCooldownMs = 1500   -- at most one refusal toast per player per this many ms
C.receiptsKept = 16         -- per subject, for chooh2.state
