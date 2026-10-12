-- GENERATED FILE -- do not edit by hand.
--
-- Produced by resources/system/open77_admin/tools/build-catalog.py from
-- docs/vehicle-models.md. Part of the catalogue: the head file,
-- shared/catalog.lua, explains the shape and WHY THIS IS SEVERAL
-- FILES. Do not merge it back into one; read that note first.
--
-- This file holds: the record index for positions 687 to 1372.
-- Estimated load cost: 2118 of a 4000 VM-instruction budget.

local catalog = Open77AdminCatalog
local records, byRecord = catalog.records, catalog.byRecord
for position = 687, 1372 do
    byRecord[records[position]] = position
end

-- Loud about a manifest that lists these files out of order or
-- omits one. A half-loaded catalogue is worse than no catalogue:
-- it validates spawns against a partial table and refuses records
-- that are perfectly real, with nothing to say why.
if #catalog.records ~= catalog.count
    or #catalog.names ~= catalog.count
    or #catalog.flags ~= catalog.count
    or byRecord[records[catalog.count]] ~= catalog.count then
    error("open77_admin catalogue incomplete -- check the shared_script order in open77.lua")
end
