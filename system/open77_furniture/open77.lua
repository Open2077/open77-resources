-- Row A1 of docs/world-interaction-plan.md: read-only lookups over the world's
-- furniture spots (docs/world-interaction/a1-furniture.md). Opt-in: nothing
-- starts it unless the server's selection asks for it. Server only, no
-- permission: it reads its own generated data and, for the lab console
-- command, Open77.players.position, which needs none.
resource "open77_furniture"
-- 0.2.0: poses carry `arrivalRadius` (per resource; B6 data update).
version "0.2.0"
auto_start false
reload_policy "local"
-- The generated catalogue is one script file per chunk (each server script
-- gets its own load budget). scripts/furniture/build_furniture_catalog.py
-- refuses to write a catalogue this list does not name in order.
server_scripts {
    "server/furniture-generated-meta.lua",
    "server/furniture-generated-1.lua",
    "server/furniture-generated-2.lua",
    "server/furniture-generated-3.lua",
    "server/furniture-generated-4.lua",
    "server/furniture-generated-5.lua",
    "server/furniture-generated-6.lua",
    "server/furniture-generated-7.lua",
    "server/index.lua",
    "server/main.lua",
}
