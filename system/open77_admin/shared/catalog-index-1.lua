-- GENERATED FILE -- do not edit by hand.
--
-- Produced by resources/system/open77_admin/tools/build-catalog.py from
-- docs/vehicle-models.md. Part of the catalogue: the head file,
-- shared/catalog.lua, explains the shape and WHY THIS IS SEVERAL
-- FILES. Do not merge it back into one; read that note first.
--
-- This file holds: the record index for positions 1 to 686.
-- Estimated load cost: 2118 of a 4000 VM-instruction budget.

local catalog = Open77AdminCatalog
local records, byRecord = catalog.records, catalog.byRecord
for position = 1, 686 do
    byRecord[records[position]] = position
end
