-- rp_inventory: item definitions and tunables, loaded on both runtimes.
-- id -> { label, weight (kg), usable, illegal, effect, category }
-- This is the legacy shape; shared/schema.lua imports it unchanged as definition schema v1 and
-- documents the optional v1 fields (weightG, maxStack, unique, metadata, durability, serial,
-- quality, prop, hand, loot).
--
-- `category` only picks the glyph the /inv panel draws on the tile (heal, food,
-- drink, fuel, smoke, drug, tech, tool, material, cargo, misc); it changes no rule.
--
-- `record` / `visual` are optional TweakDB overrides for the ground drop's item
-- card and 3D entity. The devkit documents Items.money + Items.MoneyShard as the
-- only guaranteed pair, so that is the default for every item; set a record here
-- when you have verified it on your build.

RpInventoryConfig = {
    maxCarryWeight = 40.0,          -- kg a player can carry
    defaultStashCapacity = 100.0,   -- kg when openStash is called without a capacity
    interactDistance = 3.0,         -- metres for give / search / seize / pick up
    dropTtlMs = 30 * 60 * 1000,     -- a dropped item evaporates after 30 minutes
    lootRecord = "Items.money",     -- documented default record for a ground drop
    lootVisual = "Items.MoneyShard",-- documented default 3D entity for a ground drop
    useDurationMs = 3000,           -- progress bar while using a consumable

    -- Storage backend, chosen once per boot (the convar `rp_inventory_backend` overrides it):
    --   "legacy"        rp_inventory_items / rp_inventory_stashes, kvp when no database answers
    --   "transactions"  a facade over open77_transactions (must be running and in resources.load);
    --                   never a kvp fallback; legacy rows are imported once per subject
    backend = "legacy",
    migrateOnLoad = true,           -- transactions: import a subject's legacy rows on first load
    reprojectLimit = 500,           -- transactions: world: drops re-projected per start (open77_transactions:listWorld)
    pocketGrantees = { rp_salvage = true, rp_economy = true, rp_cargo = true }, -- transactions: grantPockets callers
    importUnknownItems = false,     -- transactions: import rows of undefined item ids (weight 0, reported)
    requireDurableStore = true,     -- transactions: import only when open77_transactions reports store = "sql"
    coordinatorWallets = false,     -- transactions: sellAsync may pay cash:/bank:/soc: (only once B3 owns them)

    -- The /inv panel (world-interaction row B7, docs/world-interaction/b7-ui.md).
    panelStashReach = 6.0,          -- metres the player may walk from where a stash panel opened
    panelCargoReach = 5.0,          -- metres to the vehicle for the read-only cargo view (or seated in it)
    panelUnitsShown = 24,           -- unique units (durability / serial) listed per item in a state
    panelUnitsBudget = 64,          -- and per container (the rest is counted in moreUnits)
    panelPendingWatchS = 900,       -- seconds an in_doubt panel action is watched before "ask an admin"
    panelFocusGraceMs = 3000,       -- client: a panel that never got focus in this time closes itself
}

RpInventoryItems = {
    water       = { label = "Bottle of water",     weight = 0.5,  usable = true,  illegal = false, category = "drink",
                    effect = { kind = "drink" } },
    burrito     = { label = "Burrito",             weight = 0.4,  usable = true,  illegal = false, category = "food",
                    effect = { kind = "food" } },
    nicola      = { label = "NiCola",              weight = 0.4,  usable = true,  illegal = false, category = "drink",
                    effect = { kind = "drink" } },
    chooh2      = { label = "CHOOH2 fuel can",     weight = 5.0,  usable = true,  illegal = false, category = "fuel",
                    effect = { kind = "fuel", litres = 20 } },
    bandage     = { label = "Bandage",             weight = 0.2,  usable = true,  illegal = false, category = "heal",
                    effect = { kind = "heal", amount = 25 } },
    maxdoc      = { label = "MaxDoc Mk.1",         weight = 0.3,  usable = true,  illegal = false, category = "heal",
                    effect = { kind = "heal", amount = 60 } },
    bounceback  = { label = "Bounce Back Mk.1",    weight = 0.3,  usable = true,  illegal = false, category = "heal",
                    effect = { kind = "heal", amount = 40, stamina = true } },
    phone       = { label = "Holophone",           weight = 0.3,  usable = false, illegal = false, category = "tech" },
    radio       = { label = "Radio",               weight = 0.8,  usable = false, illegal = false, category = "tech" },
    lockpick    = { label = "Lockpick",            weight = 0.1,  usable = false, illegal = false, category = "tool" },
    scrap       = { label = "Scrap",               weight = 1.0,  usable = false, illegal = false, category = "material" },
    component   = { label = "Component",           weight = 0.5,  usable = false, illegal = false, category = "material" },
    chip        = { label = "Data chip",           weight = 0.05, usable = false, illegal = false, category = "tech" },
    cigarettes  = { label = "Pack of cigarettes",  weight = 0.1,  usable = true,  illegal = false, category = "smoke",
                    effect = { kind = "smoke" } },
    synthcoke   = { label = "Synthcoke",           weight = 0.1,  usable = true,  illegal = true, category = "drug",
                    effect = { kind = "stamina" } },
    -- Illegal unless the holder has the permit job (rp_jobs `medecin` stands in for a ripperdoc licence).
    implant_box = { label = "Implant box",         weight = 2.0,  usable = false, illegal = true, category = "tech",
                    permit = "medecin" },
    crate       = { label = "Cargo crate",         weight = 25.0, usable = false, illegal = false, category = "cargo" },
}
