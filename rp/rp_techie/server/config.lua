-- rp_techie / server/config.lua: everything an operator may move or retune.
--
-- Positions are catalogue anchors, never invented: the benches and the dealer counter are vanilla
-- AI spots of the pedestrian catalogue (open77_pedestrians spots-generated.lua, dataset
-- cp2077-2310-9ff49a042f46aff01c17f276) on the upper floor west of Kabuki Market, where the game
-- itself kneels a worker with a tool and stands one with a tablet; the gun-shop counter is a spot of
-- the same catalogue 4.4 m from rp_shops' walked 2nd Amendment ring. `measured = false` means "anchor
-- data, not walked by a player in this resource": stand on it, read `/pos`, correct it here.

TechieConfig = {}
local C = TechieConfig

local function convar(name, default)
    if type(GetConvar) ~= "function" then return default end
    local ok, value = pcall(GetConvar, name, default)
    return ok and value or default
end

-- The job (rp_jobs) and the society its shop sales pay a share to (rp_economy society name). The
-- convars let an operator run the loop under another job until rp_jobs lists `techie`.
C.job = convar("rp_techie_job", "techie")
C.society = convar("rp_techie_society", "techie")
C.bucket = 0
-- The job id this resource reports to the fixer board (`rp:job:completed`), whatever rp_jobs job
-- the operator runs it under.
C.jobId = "techie"

-- Every bench, dealer and shop action asks rp_jobs: on duty in this job (plus the recipe's grade).
-- The epoch guard refuses a commit after a job, grade or duty change; for trades (a two-player step
-- open77_actions does not run) this resource applies the same rule itself.
C.eligibility = { resource = "rp_jobs", export = "eligible", args = { job = C.job, duty = true } }
C.epochs = { resource = "rp_jobs", read = "workEpoch", event = "rp_jobs:workEpoch" }

-- ---------------------------------------------------------------------------------------------
-- Items. Defined through rp_inventory:define (B1 schema v1). Ids carry a `tch_` prefix.
-- `usable = false`: they are crafted, traded and sold through this resource only.
-- ---------------------------------------------------------------------------------------------
-- Salvage parts: what rp_salvage produces (scrap_metal, copper_wire) and rp_inventory's built-in
-- chip. rp_salvage owns the first two; this resource defines them only when nobody else did
-- (a server without rp_salvage), with the same definition. `chip` is never redefined.
C.parts = { "scrap_metal", "copper_wire", "chip" }
C.partDefinitions = {
    scrap_metal = { label = "Scrap metal", weight = 1.0, usable = false, illegal = false, category = "material" },
    copper_wire = { label = "Copper wire", weight = 0.25, usable = false, illegal = false, category = "material" },
}
C.partLabels = { scrap_metal = "Scrap metal", copper_wire = "Copper wire", chip = "Data chip" }
-- How long boot waits for rp_salvage to define its parts before defining them here (seconds).
C.partsDefineWaitS = 20

C.items = {
    -- Stage 1 outputs: they wait on the workshop tray between the two stages.
    tch_alloy_plate = { label = "Alloy plate", weight = 0.4, usable = false, illegal = false, category = "component" },
    tch_wire_loom = { label = "Wiring loom", weight = 0.2, usable = false, illegal = false, category = "component" },
    tch_logic_board = { label = "Logic board", weight = 0.1, usable = false, illegal = false, category = "component" },
    -- Weapon mods: sold to the gun shop or to players.
    tch_mod_suppressor = { label = "Suppressor kit", weight = 0.6, usable = false, illegal = false, category = "weapon_mod" },
    tch_mod_magazine = { label = "Extended magazine kit", weight = 0.5, usable = false, illegal = false, category = "weapon_mod" },
    tch_mod_sight = { label = "Reflex sight kit", weight = 0.3, usable = false, illegal = false, category = "weapon_mod" },
    -- Cyberware components: what the ripperdoc job buys (exports components() / offer()).
    tch_cw_neural_link = { label = "Neural link chip", weight = 0.1, usable = false, illegal = false, category = "cyberware_component" },
    tch_cw_servo = { label = "Servo actuator", weight = 0.4, usable = false, illegal = false, category = "cyberware_component" },
    tch_cw_optic = { label = "Optic lens array", weight = 0.1, usable = false, illegal = false, category = "cyberware_component" },
}
-- Grams per unit as the coordinator charges them (must match `weight` above; chip is built-in).
C.weightsG = {
    scrap_metal = 1000, copper_wire = 250, chip = 50,
    tch_alloy_plate = 400, tch_wire_loom = 200, tch_logic_board = 100,
    tch_mod_suppressor = 600, tch_mod_magazine = 500, tch_mod_sight = 300,
    tch_cw_neural_link = 100, tch_cw_servo = 400, tch_cw_optic = 100,
}
-- What the techie sells (in pockets after stage 2), in display order.
C.products = { "tch_mod_suppressor", "tch_mod_magazine", "tch_mod_sight",
               "tch_cw_neural_link", "tch_cw_servo", "tch_cw_optic" }
-- The clean list the ripperdoc job buys (exports.rp_techie:components()).
C.cyberwareComponents = { "tch_cw_neural_link", "tch_cw_servo", "tch_cw_optic" }

-- ---------------------------------------------------------------------------------------------
-- Coordinator accounts. sys: accounts are journal-only sources and sinks; a mint rule names the
-- ones this resource creates value from (no colon after `sys:`: the rule grammar).
-- ---------------------------------------------------------------------------------------------
C.accounts = {
    workshop = "sys:techie.workshop",   -- every stage burns its inputs into it and mints its outputs from it
    dealer = "sys:techie.dealer",       -- the parts dealer: parts minted from it, the price burned into it
    shop = "sys:techie.shop",           -- shop sales when C.shopPayment = "ledger" (money minted from it)
}

-- ---------------------------------------------------------------------------------------------
-- Animations (open77_actions plays them; profiles from open77_animations). The three `amb_*` tool
-- poses were measured on players by the integrator (A4); `repair` and `tablet2` are RP profiles.
-- ---------------------------------------------------------------------------------------------
C.animations = {
    weld = "amb_1056d7_kneel_welder",             -- kneeling, torch: cutting scrap into plates
    screwdriver = "repair",                       -- kneeling, screwdriver: stripping wire
    drill_kneel = "amb_cf84c6_kneel_use_driller", -- kneeling, drill held up: fitting a mod
    drill_stand = "amb_6862d5_stand_use_driller", -- standing, drill: desoldering a chip
    tablet = "tablet2",                           -- standing, tablet: calibrating cyberware
}
C.tradeProfile = "give"   -- the dealer and shop counters: a short offer gesture

-- Bench types. A recipe names one; a bench is one open77_actions target (one player at a time).
C.benchTypes = {
    workbench = { label = "Workbench" },
    electronics = { label = "Electronics bench" },
}

-- ---------------------------------------------------------------------------------------------
-- Recipes: data only. Each is one open77_actions action `craft_<key>`: its reserve hook holds the
-- inputs and the room for the outputs in ONE coordinator reservation, its commit burns the inputs
-- and mints the outputs in that same operation (mint rule per output, README "Setup").
--   stage     strip | assemble (the rp:job:completed kind)
--   bench     a C.benchTypes key: where it is done
--   animation a C.animations key
--   minGrade  rp_jobs grade 0..3 needed
--   inputs    { item, count, from = "pockets" | "tray" }
--   outputs   { item, count, to = "pockets" | "tray" }
-- Stage 1 (strip) takes salvage from the pockets and leaves components on the workshop tray; stage
-- 2 (assemble) takes them from the tray and puts the product in the pockets. The tray is a stash:
-- a restart between the two stages loses nothing.
-- ---------------------------------------------------------------------------------------------
C.recipes = {
    strip_plate = {
        stage = "strip", bench = "workbench", animation = "weld", durationMs = 8000, minGrade = 0,
        label = "Cut scrap into alloy plates", progress = "Cutting scrap",
        inputs = { { item = "scrap_metal", count = 3, from = "pockets" } },
        outputs = { { item = "tch_alloy_plate", count = 2, to = "tray" } },
    },
    strip_wire = {
        stage = "strip", bench = "workbench", animation = "screwdriver", durationMs = 7000, minGrade = 0,
        label = "Strip copper into a wiring loom", progress = "Stripping wire",
        inputs = { { item = "copper_wire", count = 2, from = "pockets" } },
        outputs = { { item = "tch_wire_loom", count = 1, to = "tray" } },
    },
    strip_chip = {
        stage = "strip", bench = "electronics", animation = "drill_stand", durationMs = 9000, minGrade = 0,
        label = "Desolder a chip onto a logic board", progress = "Desoldering",
        inputs = { { item = "chip", count = 1, from = "pockets" }, { item = "copper_wire", count = 1, from = "pockets" } },
        outputs = { { item = "tch_logic_board", count = 1, to = "tray" } },
    },
    assemble_suppressor = {
        stage = "assemble", bench = "workbench", animation = "drill_kneel", durationMs = 12000, minGrade = 0,
        label = "Assemble a suppressor kit", progress = "Assembling a suppressor",
        inputs = { { item = "tch_alloy_plate", count = 2, from = "tray" }, { item = "tch_wire_loom", count = 1, from = "tray" } },
        outputs = { { item = "tch_mod_suppressor", count = 1, to = "pockets" } },
    },
    assemble_magazine = {
        stage = "assemble", bench = "workbench", animation = "drill_kneel", durationMs = 10000, minGrade = 0,
        label = "Assemble an extended magazine", progress = "Assembling a magazine",
        inputs = { { item = "tch_alloy_plate", count = 3, from = "tray" } },
        outputs = { { item = "tch_mod_magazine", count = 1, to = "pockets" } },
    },
    assemble_sight = {
        stage = "assemble", bench = "workbench", animation = "drill_kneel", durationMs = 12000, minGrade = 1,
        label = "Assemble a reflex sight", progress = "Assembling a sight",
        inputs = { { item = "tch_alloy_plate", count = 1, from = "tray" }, { item = "tch_logic_board", count = 1, from = "tray" } },
        outputs = { { item = "tch_mod_sight", count = 1, to = "pockets" } },
    },
    assemble_servo = {
        stage = "assemble", bench = "electronics", animation = "tablet", durationMs = 14000, minGrade = 0,
        label = "Build a servo actuator", progress = "Calibrating a servo",
        inputs = { { item = "tch_alloy_plate", count = 2, from = "tray" }, { item = "tch_wire_loom", count = 2, from = "tray" } },
        outputs = { { item = "tch_cw_servo", count = 1, to = "pockets" } },
    },
    assemble_neural = {
        stage = "assemble", bench = "electronics", animation = "tablet", durationMs = 15000, minGrade = 1,
        label = "Flash a neural link chip", progress = "Flashing a neural link",
        inputs = { { item = "tch_logic_board", count = 2, from = "tray" }, { item = "tch_wire_loom", count = 1, from = "tray" } },
        outputs = { { item = "tch_cw_neural_link", count = 1, to = "pockets" } },
    },
    assemble_optic = {
        stage = "assemble", bench = "electronics", animation = "tablet", durationMs = 15000, minGrade = 2,
        label = "Align an optic lens array", progress = "Aligning optics",
        inputs = { { item = "tch_logic_board", count = 1, from = "tray" }, { item = "tch_alloy_plate", count = 1, from = "tray" },
                   { item = "tch_wire_loom", count = 1, from = "tray" } },
        outputs = { { item = "tch_cw_optic", count = 1, to = "pockets" } },
    },
}
-- Menu and prompt order. A bench prompt shows "Work at the bench" (the full menu) on E, then the
-- first three recipes of its type on F, R and Y; every recipe is in the menu and in /techie craft.
C.recipeOrder = {
    "strip_plate", "strip_wire", "assemble_suppressor", "assemble_magazine", "assemble_sight",
    "strip_chip", "assemble_servo", "assemble_neural", "assemble_optic",
}

-- ---------------------------------------------------------------------------------------------
-- Workshops. A workshop is a set of benches sharing one tray (`stash:tch.<workshop>:tray`, the
-- work in progress between stages). Each bench is an open77_actions target `<workshop>_<bench>`.
-- ---------------------------------------------------------------------------------------------
C.workshops = {
    -- Upper floor west of Kabuki Market (z 12, 4 m above the market, inside the kabuki_market
    -- zone), 48 m from the freeroam spawn. The game kneels a worker with a tool here and stands
    -- another with a tablet 8.7 m away; card players and loungers fill the rest of the floor. Each
    -- bench keeps the crowd off its point while it exists (`keepCrowdOff`, open77_pedestrians).
    kabuki_west = {
        enabled = true, label = "Kabuki west workshop", trayCapacityG = 30000,
        benches = {
            { key = "kneel", type = "workbench", label = "Workbench",
              position = { x = -1238.89, y = 1998.18, z = 12.010 }, yaw = 155.0, arrivalRadius = 1.0,
              measured = true, source = "walked in game: inside the scaffold, 1.2 m beside the spot where the game kneels its own worker (spots row 37034)" },
            { key = "stand", type = "electronics", label = "Electronics bench",
              position = { x = -1240.88, y = 1999.11, z = 12.010 }, yaw = 155.0, arrivalRadius = 1.0,
              measured = true, source = "walked in game: the wall panel at the end of the workbench scaffold, 2.2 m along it (the spot row 37033 faced the open street)" },
        },
    },
    -- The Gallery walkway (sample, off): a kneeling tool spot 16 m south of the employment agency
    -- and a tablet spot 7.9 m from it, both on the walkway level.
    gallery = {
        enabled = false, label = "Gallery workshop", trayCapacityG = 30000,
        benches = {
            { key = "kneel", type = "workbench", label = "Workbench",
              position = { x = -1172.625, y = 2071.664, z = 12.060 }, yaw = 155.0, arrivalRadius = 1.0,
              measured = false, source = "spots-generated row 39487 (amb_cc2fe0_kneel_ground_tool)" },
            { key = "stand", type = "electronics", label = "Electronics bench",
              position = { x = -1171.758, y = 2079.524, z = 11.982 }, yaw = 169.96, arrivalRadius = 1.0,
              measured = false, source = "spots-generated row 31019 (amb_77e5ea_stand_ground_tablet)" },
        },
    },
}
C.workshopOrder = { "kabuki_west", "gallery" }

-- ---------------------------------------------------------------------------------------------
-- The parts dealer: a techie buys a lot of salvage for cash. One coordinator operation: the parts
-- are minted out of sys:techie.dealer into the pockets and the price is burned into it. The mint
-- rule's hourly cap is the dealer's supply (README "Setup").
-- ---------------------------------------------------------------------------------------------
C.dealers = {
    kabuki_west = {
        enabled = true, label = "Sparks, parts dealer", name = "Sparks",
        position = { x = -1235.566, y = 2000.680, z = 12.077 }, yaw = -151.0,
        measured = true, source = "walked in game: by the dumpster, 4.2 m from the workbench point and 3.8 m from the game's kneeling worker (spots row 32163)",
        lots = {
            { item = "scrap_metal", count = 3, price = 75 },
            { item = "copper_wire", count = 2, price = 90 },
            { item = "chip", count = 1, price = 220 },
        },
    },
}
C.dealerOrder = { "kabuki_west" }

-- ---------------------------------------------------------------------------------------------
-- Shops (NPC buyers): a techie sells every product of the shop's kind from their pockets in ONE
-- rp_economy sale (the goods leave the pockets, the price is split between the techie and the
-- society). `C.shopPayment = "ledger"` pays from sys:techie.shop through the coordinator instead
-- (an operator who has not given rp_techie an rp_economy mint budget yet; README "Setup").
-- ---------------------------------------------------------------------------------------------
C.shopPayment = convar("rp_techie_shop_payment", "economy")   -- "economy" | "ledger"
C.shops = {
    gunshop = {
        enabled = true, label = "Wilson, 2nd Amendment", buyer = "2nd Amendment",
        position = { x = -1160.02, y = 2017.85, z = 7.76 }, yaw = -21.2,
        measured = true, source = "walked in game: beside rp_shops' East Row ring, facing Wilson under the stairs",
        accepts = { "tch_mod_suppressor", "tch_mod_magazine", "tch_mod_sight" },
    },
    medpoint = {
        enabled = true, label = "Dr. Osei, Med-Point", buyer = "Med-Point",
        position = { x = -1224.52, y = 1990.59, z = 7.80 }, yaw = 165.3,
        measured = true, source = "walked in game: beside rp_shops' Med-Point ring (The Stalls), facing Dr. Osei",
        accepts = { "tch_cw_neural_link", "tch_cw_servo", "tch_cw_optic" },
    },
}
C.shopOrder = { "gunshop", "medpoint" }
C.societyShare = 0.10      -- of every shop sale, to soc:<C.society>
C.shopMaxLines = 12        -- item stacks one shop sale may carry

-- Prices in eddies per unit. `shop`: what an NPC shop pays. `suggested`: the default price of a
-- trade between players when the seller names none (players may agree any price up to the cap).
C.prices = {
    scrap_metal = { suggested = 22 }, copper_wire = { suggested = 42 }, chip = { suggested = 180 },
    tch_mod_suppressor = { shop = 240, suggested = 320 },
    tch_mod_magazine = { shop = 170, suggested = 230 },
    tch_mod_sight = { shop = 420, suggested = 560 },
    tch_cw_servo = { shop = 340, suggested = 450 },
    tch_cw_neural_link = { shop = 800, suggested = 1050 },
    tch_cw_optic = { shop = 520, suggested = 700 },
}

-- ---------------------------------------------------------------------------------------------
-- Trades between players (Open77.playerInteractions `give` with consent, then ONE coordinator
-- operation: the goods out of the seller's pockets into the buyer's, the price out of the buyer's
-- cash into the seller's). Parts flow towards an on-duty techie (a scrapper sells, the techie
-- buys); products flow away from one (the techie sells, anyone buys).
-- ---------------------------------------------------------------------------------------------
C.trade = {
    durationMs = 3000,          -- the platform `give` presentation, after consent
    startDistance = 3.0,        -- server-observed, both players
    breakDistance = 5.0,
    inviteTimeoutMs = 20000,
    maxCount = 20,              -- units per trade
    maxUnitPrice = 5000,        -- eddies per unit
    -- Resources allowed to start a trade through exports.rp_techie:offer (the ripperdoc job).
    offerCallers = { rp_ripperdoc = true },
}
C.maxDistance = 2.5

-- ---------------------------------------------------------------------------------------------
-- Mint caps per hour, for `techie.mintrules` (the console prints the tunable lines from these).
-- ---------------------------------------------------------------------------------------------
C.mintCaps = {
    workshop = { tch_alloy_plate = 400, tch_wire_loom = 200, tch_logic_board = 100,
                 tch_mod_suppressor = 60, tch_mod_magazine = 60, tch_mod_sight = 40,
                 tch_cw_servo = 40, tch_cw_neural_link = 30, tch_cw_optic = 30 },
    dealer = { scrap_metal = 300, copper_wire = 200, chip = 40 },
    shopMoney = 60000,          -- only with C.shopPayment = "ledger"
}

-- ---------------------------------------------------------------------------------------------
-- Maintenance
-- ---------------------------------------------------------------------------------------------
C.sweepMs = 2000            -- settle in-doubt stages and sales, drop lost offers
C.notifyCooldownMs = 1500   -- at most one refusal toast per player per this many ms
C.receiptsKept = 16         -- per subject, for techie.lab.state
C.lostOfferMs = 60000       -- an offer with no platform state for this long is dropped
C.menuTimeoutMs = 30000     -- the bench menu (open77_uikit context)
