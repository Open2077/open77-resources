-- rp_salvage / server/config.lua: everything an operator may move or retune.
--
-- Positions come from rp_ferrailleur's measured yard (Rancho Coronado junkyard, zone `junkyard`,
-- centre 1374.9, -1674.9, 49.3) and are reused as DATA only: this resource does not call
-- rp_ferrailleur. Points marked `measured = false` are placed by arithmetic from those
-- coordinates, not walked in game: stand on the spot, read `/pos`, paste it here.

SalvageConfig = {}
local C = SalvageConfig

-- The job and the society (rp_jobs job name = rp_economy society name).
C.job = "ferrailleur"
C.society = "ferrailleur"
C.bucket = 0

-- Every work action, every carry and every sale asks rp_jobs: on duty in this job. The epoch
-- guard refuses a commit after a job, grade or duty change and drops a carried crate at once.
C.eligibility = { resource = "rp_jobs", export = "eligible", args = { job = "ferrailleur", duty = true } }
C.epochs = { resource = "rp_jobs", read = "workEpoch", event = "rp_jobs:workEpoch" }

-- ---------------------------------------------------------------------------------------------
-- Items. Defined through rp_inventory:define (B1 schema v1), the single definer toward the
-- coordinator. `chip` is an rp_inventory built-in and is not redefined. `crowbar` is the id
-- rp_ferrailleur defines too: whichever of the two runs first in an rp_inventory generation
-- owns it, one more reason never to run both.
-- ---------------------------------------------------------------------------------------------
C.items = {
    scrap_metal = { label = "Scrap metal", weight = 1.0, usable = false, illegal = false, category = "material" },
    copper_wire = { label = "Copper wire", weight = 0.25, usable = false, illegal = false, category = "material" },
    -- The crate's custody token: one unique instance per crate, moved by rp_cargo into a bed.
    salvage_crate = { label = "Scrap crate", weight = 2.0, unique = true, usable = false, illegal = false,
                      category = "cargo" },
    crowbar = { label = "Crowbar", weight = 1.5, usable = false, illegal = false, category = "tool",
                durability = { max = 20, start = 20, breaks = true } },
    welder = { label = "Cutting torch", weight = 3.0, usable = false, illegal = false, category = "tool",
               durability = { max = 30, start = 30, breaks = true } },
}
-- Grams per unit, as the coordinator charges them (must match the definitions; chip is built-in).
C.weightsG = { scrap_metal = 1000, copper_wire = 250, chip = 50, salvage_crate = 2000, crowbar = 1500, welder = 3000 }
C.tools = { crowbar = { max = 20, breaks = true }, welder = { max = 30, breaks = true } }

-- ---------------------------------------------------------------------------------------------
-- Coordinator accounts (A13 section 3.1). sys: accounts are journal-only sources and sinks.
-- ---------------------------------------------------------------------------------------------
C.accounts = {
    source = "sys:salvage",        -- materials and crate tokens come from here (needs a mint rule)
    broken = "sys:broken",         -- a tool worn to 0 (B1 rule: breaks = true)
    retired = "sys:salvage",       -- a sold crate's token goes back here
}

-- ---------------------------------------------------------------------------------------------
-- The yard
-- ---------------------------------------------------------------------------------------------
-- The foreman: clock in / clock out (rp_jobs setDuty). A point target with an explicit position,
-- like every prompt of this resource.
C.foreman = {
    position = { x = 1374.0, y = -1671.5, z = 49.3 }, yaw = 180.0, measured = true,   -- walked 2026-10-12
    label = "Yard foreman", distance = 2.5,
}

-- Wreck nodes: five points walked in game on 2026-10-12 (integrator, two clients): four kneeling
-- spots 1.5 m in front of the crushed-car stack at the south end of the yard lane (yaw 180 faces
-- the stack; the first stands at a red wreck badged THORTON) and one beside the rusted wreck west
-- of the lane. rp_ferrailleur's seven arithmetic points fell inside a trailer, a porch and a shed,
-- so they were dropped (makigai keeps its key at a new spot; villefort and chevillon are gone).
-- They are durable open77_containers nodes
-- named by the key `node.<key>` (one charge spent per completed work, one charge back every
-- regrowMs, across restarts). Charges and regrowMs apply when a node is first created; an existing
-- node keeps its own (salvage.lab.reset refills it to its maximum). A node closed in
-- open77_containers keeps its key spent for good: give it `containerKey = "node.<key>.2"` here.
-- `yaw` is the heading the welder kneels with (playAt); 0 = facing +y, 180 = facing -y.
C.nodeDefaults = { charges = 3, regrowMs = 5 * 60 * 1000 }
C.nodes = {
    { key = "thorton",   label = "Burnt-out Thorton",  position = { x = 1368.0, y = -1690.8, z = 49.3 }, yaw = 180.0 },
    { key = "quadra",    label = "Gutted Quadra",      position = { x = 1371.0, y = -1690.8, z = 49.3 }, yaw = 180.0 },
    { key = "mizutani",  label = "Rusted Mizutani",    position = { x = 1378.0, y = -1690.8, z = 49.3 }, yaw = 180.0 },
    { key = "archer",    label = "Crushed Archer",     position = { x = 1381.0, y = -1690.8, z = 49.3 }, yaw = 180.0 },
    { key = "makigai",   label = "Stripped Makigai",   position = { x = 1371.0, y = -1671.5, z = 49.3 }, yaw = 45.0 },
}
-- A new crate is set down this far from the node, towards the yard centre, so it does not sit in
-- the welder's kneeling spot.
C.crateOffsetM = 1.4
C.yardCentre = { x = 1374.5, y = -1681.0, z = 49.3 }   -- the open lane between the stack and the bays

-- The buyer stands on the east verge of the lane, facing it (yaw 90 = facing -x); the counter is the
-- drop point a crate is handed over at, 1.2 m in front of the buyer. rp_ferrailleur's dealer point
-- was inside the shed west of the lane (walked 2026-10-12), out of reach for a crate carrier.
C.buyer = {
    position = { x = 1376.3, y = -1684.0, z = 49.3 }, yaw = 90.0,
    counter = { x = 1375.1, y = -1684.0, z = 49.3 }, measured = true,
    label = "Rusty's scale", name = "Rusty",
    -- An NPC behind the counter (presentation only; a refusal is logged, the counter still works).
    -- damagePolicy 2 = invulnerable (Open77.npcs.damage).
    npc = { template = "civilian_female_relaxed_01", record = nil, damagePolicy = 2 },
}

-- Bays: a truck parked with its bed on the marker (rp_cargo also checks the player stands within
-- 5 m of the vehicle origin). `truckRadius` is how far from the bay the truck may stand.
C.bays = {
    load = { position = { x = 1378.0, y = -1671.0, z = 49.3 }, label = "Truck loading bay", truckRadius = 7.0,
             measured = true },
    unload = { position = { x = 1373.0, y = -1678.5, z = 49.3 }, label = "Unloading bay", truckRadius = 7.0,
               measured = true },
}
-- `/salvage load`, `/salvage unload` and the lab look for a truck this close to the player.
C.truckNearM = 6.0

-- ---------------------------------------------------------------------------------------------
-- Actions (open77_actions). Profiles: integrator measurements of 2026-10-12 (A4).
-- ---------------------------------------------------------------------------------------------
C.actions = {
    cut = {
        label = "Cut with the torch", progress = "Cutting", durationMs = 8000, tool = "welder",
        animation = { profile = "amb_1056d7_kneel_welder", at = "target" },   -- brings its own torch
    },
    pry = {
        label = "Pry with the crowbar", progress = "Prying", durationMs = 8000, tool = "crowbar",
        animation = { profile = "scavenge", at = "self" },
        -- In the right hand for the bar; the first alias the catalogue accepts wins (`tool.crowbar`
        -- does not exist yet: the fire axe stands in, as in rp_ferrailleur).
        handProp = { models = { "tool.crowbar", "tool.fire_axe" }, bone = "RightHand",
                     offset = { x = 0.0, y = 0.0, z = 0.0 }, rotation = { x = 0.0, y = 0.0, z = 0.0 } },
    },
    -- "Check the haul": reads your crate at this wreck. Shown with the kneeling driller CHECK clip,
    -- never as drilling (A4: the driller leaves are check_tool / inspect only).
    inspect = {
        label = "Check the haul", progress = "Checking the haul", durationMs = 4000,
        animation = { profile = "amb_cf84c6_kneel_use_driller", at = "target" },
    },
    clock = { durationMs = 750 },
    unload = { label = "Unload a crate", progress = "Unloading", durationMs = 1500 },
}
C.maxDistance = 2.5

-- What one completed work yields, rolled at the server's commit from the operation id (a retried
-- commit draws the same lines). `chance` in percent; count uniform in min..max.
C.loot = {
    cut = {
        { item = "scrap_metal", min = 2, max = 4, chance = 100 },
        { item = "copper_wire", min = 1, max = 1, chance = 50 },
    },
    pry = {
        { item = "scrap_metal", min = 1, max = 2, chance = 100 },
        { item = "copper_wire", min = 1, max = 2, chance = 100 },
        { item = "chip", min = 1, max = 1, chance = 10 },
    },
}

-- ---------------------------------------------------------------------------------------------
-- The haul crate
-- ---------------------------------------------------------------------------------------------
C.crate = {
    -- Integrator, 2026-10-12: crate.ammo_box renders at hand scale and carries well (FPP low right,
    -- survives a server teleport). crate.small / crate.cargo are freight size only.
    model = "crate.ammo_box",
    label = "scrap crate",
    contentsKg = 12,             -- materials one crate holds (the token's 2 kg come on top)
    joinRadiusM = 2.0,           -- work at a node fills YOUR ground crate within this radius (a crate is
                                 -- set down 1.4 m from its wreck; the measured wrecks stand 3 m apart)
    maxPerPlayer = 4,            -- open crates (ground, hands or bed) per subject
    maxOpen = 48,                -- open crates on the server (ground crates are carry items: <= 128)
    pickupBy = "crew",           -- "crew": anyone eligible (on duty as a scrapper); "owner": the filler only
    reach = 2.0, vehicleReach = 4.5,
    binding = nil,               -- nil = open77_actions' measured binding for this model (both views)
    gripMs = nil, releaseMs = nil,
    orphanAgeMs = 2 * 60 * 1000, -- an empty crate with no token older than this is closed by the sweep
}

-- ---------------------------------------------------------------------------------------------
-- Prices (eddies per unit) and the split of every sale (one rp_economy:sale operation).
-- ---------------------------------------------------------------------------------------------
C.prices = { scrap_metal = 18, copper_wire = 40, chip = 150 }
C.saleOrder = { "scrap_metal", "copper_wire", "chip" }
C.societyShare = 0.10

-- ---------------------------------------------------------------------------------------------
-- Maintenance
-- ---------------------------------------------------------------------------------------------
C.sweepMs = 5000            -- settle in-doubt work, retry node charges, retire sold crates
C.notifyCooldownMs = 1500   -- at most one refusal toast per player per this many ms
C.receiptsKept = 16         -- per subject, for salvage.lab.state
