resource "open77_devices"
version "1.0.0"
open77_version ">=0.0.1"
auto_start true
reload_policy "local"

client_script "client/main.lua"
server_script "server/main.lua"

-- `Open77.world.setDeviceInteractionEnabled` is a CLIENT capability, like HUD
-- claims and input blocks: the client owns the policy and the server sends it an
-- event. This package is the client half that owns the claim, and the server
-- half that lets a gamemode declare it once instead of per client.
permissions {
    -- Client: the device policy itself. A write that changes what the player
    -- can do with the world, so it is deliberately not under `world.query`,
    -- which is the read gate on `Open77.world.nearby`.
    "world.devices",

    -- Both halves: the declaration reaches clients as an ordinary
    -- authenticated net event, and a client reports a use back the same way.
    "network.events",
}
