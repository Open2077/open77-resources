-- rp_streetfood / server/config.lua: everything an operator may move or retune.
--
-- Positions are catalogue anchors, never invented: the grill is the vanilla cook spot of a market
-- grill and the counter the vanilla customer spot in front of it (open77_pedestrians
-- spots-generated.lua, dataset cp2077-2310-9ff49a042f46aff01c17f276); the seats are A1 furniture
-- (open77_furniture, catalogue furniture-1-17f2d5e1987b). `measured = false` means "anchor data, not
-- walked by a player in this resource's lab run": stand on it, read `/pos`, correct it here.

StreetfoodConfig = {}
local C = StreetfoodConfig

local function convar(name, default)
    if type(GetConvar) ~= "function" then return default end
    local ok, value = pcall(GetConvar, name, default)
    return ok and value or default
end

-- The job (rp_jobs) and the society its sales pay (rp_jobs job name = rp_economy society name).
C.job = "cook"
C.society = "cook"
C.bucket = 0

-- Cooking, serving and stocking ask rp_jobs: on duty in this job. The epoch guard refuses a commit
-- after a job, grade or duty change; for the hand-over (a two-player step open77_actions does not
-- run) this resource applies the same rule itself.
C.eligibility = { resource = "rp_jobs", export = "eligible", args = { job = "cook", duty = true } }
C.epochs = { resource = "rp_jobs", read = "workEpoch", event = "rp_jobs:workEpoch" }

-- ---------------------------------------------------------------------------------------------
-- Items. Defined through rp_inventory:define (B1 schema v1), the single definer toward the
-- coordinator. Ids carry an `sf_` prefix: rp_bar, rp_needs and rp_shops own their own food.
-- `usable = false`: a dish is eaten through this resource (the eat actions), never through
-- rp_inventory's /use, so its needs effect and its custody move stay one path.
-- ---------------------------------------------------------------------------------------------
C.items = {
    sf_synth_meat = { label = "Synth-meat strips", weight = 0.2, usable = false, illegal = false, category = "ingredient" },
    sf_bun = { label = "Soy bun", weight = 0.1, usable = false, illegal = false, category = "ingredient" },
    sf_sauce = { label = "Chili sauce sachet", weight = 0.05, usable = false, illegal = false, category = "ingredient" },
    sf_soda = { label = "Synth soda can", weight = 0.35, usable = false, illegal = false, category = "drink" },
    sf_skewer = { label = "Grilled skewer", weight = 0.25, usable = false, illegal = false, category = "food" },
    sf_burger = { label = "Grill burger", weight = 0.3, usable = false, illegal = false, category = "food" },
}
-- Grams per unit as the coordinator charges them (must match `weight` above).
C.weightsG = { sf_synth_meat = 200, sf_bun = 100, sf_sauce = 50, sf_soda = 350, sf_skewer = 250, sf_burger = 300 }
-- What a cook may move from their pockets into a stall's pantry ("Stock the pantry").
C.stockable = { "sf_synth_meat", "sf_bun", "sf_sauce", "sf_soda" }

-- ---------------------------------------------------------------------------------------------
-- Coordinator accounts (A13 section 3.1). sys: accounts are journal-only sources and sinks; a mint
-- rule names the two this resource creates value from (no colon inside: the rule grammar).
-- ---------------------------------------------------------------------------------------------
C.accounts = {
    kitchen = "sys:streetfood.kitchen",    -- ingredients burned into it, cooked dishes minted from it
    supplier = "sys:streetfood.supplier",  -- operator / lab restock (mint)
    eaten = "sys:streetfood.eaten",        -- a dish eaten or a drink drunk (burn)
}

-- ---------------------------------------------------------------------------------------------
-- The menu. `from`: where a sold portion comes from ("pass" = cooked here, "pantry" = resold
-- stock). `needs`: the rp_needs delta applied once, after the eat commit. `hand`: a native item
-- record held in the hand between hand-over and drinking (only records the platform documents as
-- working: wiki/rp-animations.md; food has none, so food is not drawn in the hand).
-- ---------------------------------------------------------------------------------------------
C.menu = {
    skewer = { item = "sf_skewer", label = "Grilled skewer", price = 18, kind = "food", from = "pass",
               recipe = "skewer", needs = { hunger = 30 } },
    burger = { item = "sf_burger", label = "Grill burger", price = 24, kind = "food", from = "pass",
               recipe = "burger", needs = { hunger = 40, thirst = -5 } },
    soda = { item = "sf_soda", label = "Soda can", price = 6, kind = "drink", from = "pantry",
             needs = { thirst = 25 }, hand = "Items.crowd_soda_can_a" },
}
C.menuOrder = { "skewer", "burger", "soda" }

-- Recipes: inputs leave the pantry and the dish lands on the pass in ONE coordinator operation,
-- reserved before the progress bar and committed after it. `station` picks the profile.
C.recipes = {
    skewer = { label = "Grill a skewer", progress = "Grilling", station = "grill", durationMs = 10000,
               inputs = { { item = "sf_synth_meat", count = 2 }, { item = "sf_sauce", count = 1 } },
               output = { item = "sf_skewer", count = 1 } },
    burger = { label = "Grill a burger", progress = "Grilling", station = "grill", durationMs = 12000,
               inputs = { { item = "sf_synth_meat", count = 1 }, { item = "sf_bun", count = 1 },
                          { item = "sf_sauce", count = 1 } },
               output = { item = "sf_burger", count = 1 } },
}
C.recipeOrder = { "skewer", "burger" }

-- Station profiles: the four job profiles the integrator measured on players (A4, 2026-10-12).
-- Each needs its real counter in front of it (the cook profile alone stands at grill height with
-- nothing to grill). Only the grill has a catalogue anchor at the enabled stall.
C.stationProfiles = {
    grill = "amb_704dff_cook",               -- spatula, turns meat on a grill (market_grill_spatula__cook)
    wok = "amb_450061_stand_wok",            -- 43 anchors in the catalogue, none at the food court
    fryer = "amb_2bfab5_stand_table_fryer",  -- 4 anchors in the catalogue, none at the food court
}

-- Consumption profiles. `layer` ones keep locomotion (and use the drink held in the hand);
-- workspot ones are stationary (the hand item is released before they play).
C.consume = {
    counter = { profile = "amb_fd31d1_stand_market_grill", layer = false, durationMs = 12000,
                label = "Eat at the counter", progress = "Eating" },   -- buy_and_eat_from_grill, at the counter anchor
    food = { profile = "takeout", layer = false, durationMs = 12000,
             label = "Eat your takeout", progress = "Eating" },       -- stationary; the catalogue lists a takeout prop for it
    drink = { profile = "drink_walk", layer = true, durationMs = 9000,
              label = "Drink", progress = "Drinking" },                -- walking, two sips of the held can
    seat = { durationMs = 15000, label = "Eat seated", progress = "Eating" },  -- the seat's own pose
}
C.orderProfile = "order"   -- "Order food" gesture (rp-profiles.json), at the customer's spot

-- ---------------------------------------------------------------------------------------------
-- Stalls
-- ---------------------------------------------------------------------------------------------
C.stalls = {
    -- The food court of the 2026-09-28 pedestrian proof and of the A3/A1 seat runs (upper floor,
    -- z 115). Grill: spots-generated row 9594 (`amb_704dff_cook`, also crowd-spot row 58918, so the
    -- crowd can book it: stop the crowd for a lab run). Counter: row 1144 (`stand_ground`), 1.45 m
    -- in front of the grill and facing it.
    food_court = {
        enabled = true, label = "Food-court grill",
        -- arrivalRadius: playAt plays where the actor stands when within this many metres of the
        -- anchor (open77_actions >= 532eb489). Live 2026-10-12: relocating the cook onto the grill
        -- anchor behind the counter got the body pushed back (interrupted player_moving).
        grill = { position = { x = -397.617, y = 715.138, z = 115.000 }, yaw = 64.0, station = "grill",
                  arrivalRadius = 1.0,
                  -- Walked 2026-10-12 (both rigs cooked): the cook stands on the step behind the grill,
                  -- ~0.5 m from the anchor at z 115.35; the 1 m arrival radius plays the pose there. A
                  -- body left at z 115.0 on the step edge is refused `player_not_grounded`.
                  measured = true, source = "spots-generated row 9594 (amb_704dff_cook)" },
        counter = { position = { x = -398.887, y = 715.848, z = 115.000 }, yaw = -107.0,
                    arrivalRadius = 1.0,
                    -- Walked 2026-10-12: orders and the counter meal played 0.5 m from the anchor.
                    measured = true, source = "spots-generated row 1144 (stand_ground facing the grill)" },
        pantryCapacityG = 40000,
        passCapacityG = 2000,     -- 8 skewers / 6 burgers waiting at most: "the pass is full"
        -- Seats (only with seating enabled). A1 furniture ids; `spot` is the pose played. Verdicts
        -- from the research ledger "A1 ten furniture ids verified live" (2026-10-12).
        seats = {
            { furniture = "14182403679719868087", spot = "14182403679719868087", label = "Chair by the grill",
              position = { x = -403.207, y = 714.571, z = 115.000 }, yaw = -100.20, profile = "chair",
              verdict = "A1 #5 seated live (horiz 0.376)", enabled = true },
            { furniture = "14644536518519442059", spot = "14644536518519442059", label = "Workbench chair",
              position = { x = -408.115, y = 712.281, z = 115.000 }, yaw = -38.00, profile = "seatedthink",
              verdict = "A1 #4 seated live", enabled = true },
            { furniture = "9160494166749203069", spot = "9160494166749203069", label = "Blue chair",
              position = { x = -421.196, y = 710.938, z = 115.040 }, yaw = -109.01, profile = "seated",
              verdict = "A1 #1 measured (A3 run)", enabled = true },
            { furniture = "3931217955540569133", spot = "3931217955540569133", label = "Barstool",
              position = { x = -402.632, y = 725.100, z = 115.114 }, yaw = -34.00,
              profile = "amb_f6ac22_sit_barstool_bar",
              verdict = "barstool family measured with radius 1.0 (A1 #3 / A2); this stool not", enabled = false },
        },
    },
    -- Kabuki Market (sample, off): the market grill cook spot row 7736, 17 m from the RP spawn. Its
    -- counter is ARITHMETIC (1.4 m ahead of the cook's yaw): no customer spot stands there.
    kabuki = {
        enabled = false, label = "Kabuki grill",
        grill = { position = { x = -1167.426, y = 2023.262, z = 7.780 }, yaw = 177.0, station = "grill",
                  measured = false, source = "spots-generated row 7736 (amb_704dff_cook)" },
        counter = { position = { x = -1167.499, y = 2021.864, z = 7.780 }, yaw = -3.0,
                    measured = false, source = "arithmetic: 1.4 m ahead of the grill yaw" },
        pantryCapacityG = 40000, passCapacityG = 2000, seats = {},
    },
}
C.stallOrder = { "food_court", "kabuki" }

-- Seating (optional). "stall": the seats above, each an open77_actions target with a one-winner
-- claim. B6 (the furniture resource with NPC occupancy) has published no export yet; when it does,
-- its provider replaces this one (docs/world-interaction/c4-streetfood.md, needs). Off by default:
-- the convar `rp_streetfood_seating 1` turns it on.
C.seating = {
    enabled = convar("rp_streetfood_seating", "0") == "1",
    provider = "stall",
    furnitureLookup = true,    -- refresh seat poses from open77_furniture:get when it runs
    maxDistance = 3.0,
}

-- ---------------------------------------------------------------------------------------------
-- Hand-over and payment
-- ---------------------------------------------------------------------------------------------
C.serve = {
    durationMs = 3000,          -- the platform `give` presentation, after consent
    startDistance = 3.0,        -- cook and customer, server-observed
    breakDistance = 5.0,
    inviteTimeoutMs = 20000,
    ticketTtlMs = 5 * 60 * 1000,
    maxTip = 200,
    instrument = "cash",        -- rp_economy sale: the buyer pays from this wallet
    reason = "street food",
}
C.maxDistance = 2.5

-- ---------------------------------------------------------------------------------------------
-- Lab / operator restock: what `streetfood.lab.seed` puts in a pantry (minted from the supplier).
-- ---------------------------------------------------------------------------------------------
C.seed = { sf_synth_meat = 12, sf_bun = 6, sf_sauce = 8, sf_soda = 6 }

-- ---------------------------------------------------------------------------------------------
-- Maintenance
-- ---------------------------------------------------------------------------------------------
C.sweepMs = 2000            -- settle in-doubt cooks / meals / sales, expire tickets and lost offers
C.notifyCooldownMs = 1500   -- at most one refusal toast per player per this many ms
C.receiptsKept = 16         -- per subject, for streetfood.lab.state
C.lostOfferMs = 60000       -- an offer with no platform state and no event for this long is dropped
