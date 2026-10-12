-- Resource-owned server cameras and local HUD/world/WebUI presentations.
-- Load authority and main before the editor/viewer consumers of RemoteCameraService.
resource "open77_remote_camera"
version "0.3.0"
open77_version ">=1.0.0"
auto_start true
reload_policy "reconnect"
client_scripts { "client/main.lua", "client/editor.lua" }
server_scripts { "server/authority.lua", "server/main.lua", "server/editor.lua", "server/watch.lua" }

-- Pages are explicitly created; the editor starts hidden.
web_ui_page "web/editor.html"
web_ui_auto_create false
web_files { "web/**" }

permissions {
    -- Client: create/capture independent camera sources and present them.
    "camera.capture",
    -- Client: aim ray for the surface snap, and entity tests around the hit.
    "world.query",
    -- Client: the frame and offset conversions behind canonical prop/player/
    -- vehicle parents; without it the snap falls back to an unparented pose.
    "world.transform",
    -- Client and server: the resource-local event channel both halves use.
    "local.events",
    "network.events",
    -- Client: the snap key binding and the "is another modal holding input"
    -- check before the editor takes the cursor.
    "input.actions",
    -- Client: copying the generated Lua/JSON definition.
    "clipboard.write",
    -- Server: read this session's compiled ACL before every editor mutation.
    -- A read only; it never writes roles or grants.
    "acl.read",
    -- Server: read a caller's life phase when refusing the editor to a dead
    -- player, and keep interest leases for viewers of a screen.
    "players.life.read",
    "world.interest",
    -- Canonical parent resolution and server-owned camera housings.
    -- The client uses world.props for local housing previews.
    "world.props",
    "world.vehicles",
}
