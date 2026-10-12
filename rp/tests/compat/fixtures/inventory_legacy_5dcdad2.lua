-- Golden pre-migration fixture: rp_inventory_items / rp_inventory_stashes rows in the 5dcdad2
-- layout (tests/compat/schema-snapshot.json), and the open77_transactions state the one-shot
-- import must produce from them. Weights come from rp_inventory/shared/items.lua (kg -> g)
-- plus the definitions the scenario registers (`crowbar` as rp_ferrailleur, `bulk_NN` as
-- compat_bulk). Changing either side is a migration contract change.

local bulk = {}
for i = 1, 45 do bulk[("bulk_%02d"):format(i)] = 1 end

return {
    items = {
        ["acct-a"] = { water = 3, burrito = 2, crowbar = 1 },      -- 1500 + 800 + 1500 g
        ["acct-b"] = { crate = 2, scrap = 5 },                     -- 55 kg: over the 40 kg pockets
        ["acct-c"] = { water = 1, ghost_item = 4 },                -- an id nobody defines
        ["acct-e"] = bulk,                                         -- 45 kinds: more than one chunk
        ["acct-z"] = { water = 0 },                                -- a zero row (skipped, reported)
    },
    stashes = {
        ["home:12"] = { scrap = 10, component = 4 },               -- 10000 + 2000 g
        ["home:7"] = { maxdoc = 1 },                               -- 300 g
        ["12"] = { water = 1 },                                    -- all digits: refused as a runtime id
    },
    expected = {
        ["char:acct-a"] = { weightG = 3800, capacityG = 40000, stacks = { water = 3, burrito = 2, crowbar = 1 } },
        ["char:acct-b"] = { weightG = 55000, capacityG = 55000, stacks = { crate = 2, scrap = 5 } },
        ["char:acct-e"] = { weightG = 45 * 100, capacityG = 40000, stacks = bulk, chunks = 2 },
        ["stash:home:12"] = { weightG = 12000, capacityG = 100000, stacks = { scrap = 10, component = 4 } },
        ["stash:home:7"] = { weightG = 300, capacityG = 100000, stacks = { maxdoc = 1 } },
    },
    refused = {
        ["char:acct-c"] = "unknown_items",
        ["stash:12"] = "runtime_id_key",
    },
}
