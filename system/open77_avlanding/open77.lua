-- open77_avlanding -- "WARNING", flashing, in a turning ring of warning words
-- on the ground under an aircraft that comes down to it. Every game draws the sign
-- under the aircraft it draws, laid on the ground's plane; the server only
-- answers `/avlanding.test`, which shows it to the player who types it.
-- README.md says what it is made of.
resource "open77_avlanding"
version "1.4.2"
open77_version ">=0.0.1"
auto_start true

-- The archive is mounted by the game as it starts: a running client keeps the
-- revision it booted with until it reconnects.
reload_policy "reconnect"

shared_script "shared/config.lua"
server_script "server/main.lua"
client_script "client/main.lua"

-- The sign's two effects, particle systems and texture, installed by the launcher in
-- archive/pc/mod before Cyberpunk starts (the server serves it as a required
-- mod: `requiredMods.enabled` must be true).
preload_mod "dist/Open77AvLanding_10c786843d78.zip"

-- THE OLD LANDING LASERS, GONE. The released Open77 client draws its own
-- marker under every AV near the ground -- twelve red beams on a ring, one
-- orbiting inside it, a 60-dot OPEN77 -- with `laser.mine`
-- (base\fx\devices\mine_laser\mine_laser_red.effect), and nothing in Lua
-- turns it off. This archive keeps that effect alive and draws it as nothing
-- (scripts/avlanding/make_laser_off.py): the sign above is the only marker.
-- It is laid with this server's world mods and taken off when the player
-- leaves, so the game's own laser mines lose their red beam here only.
preload_mod "dist/Open77AvLasersOff_68c5fe42a822.zip"

-- Least privilege, line by line.
permissions {
    -- Client: Open77.vehicles.nearby -- the aircraft in range, their record,
    -- occupants, engine and physics owner.
    "vehicles.read",

    -- Client: Open77.world.entityGeometry (where this screen draws a hull, its
    -- heading and mesh box), Open77.world.raycast (the ground under it and
    -- under the sign's footprint: static meshes and terrain) and
    -- Open77.world.groundZ (static only, on a client whose rays take no
    -- collision groups).
    "world.query",

    -- Client: Open77.vfx.play / update / stop -- the sign itself.
    "world.effects",

    -- Server: TriggerClientEvent -- `/avlanding.test` asks the caller's game
    -- to lay the sign, and answers in their console. Client: RegisterNetEvent.
    "network.events",
}
