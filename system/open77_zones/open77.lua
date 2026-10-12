resource "open77_zones"
version "0.2.0"
open77_version ">=0.0.1"
auto_start true
reload_policy "local"

client_script "client/main.lua"

-- Client-only, and it needs no permission: it reads the local character
-- transform, which Open77.character exposes ungated. An entity-attached zone
-- resolves its anchor through Open77.character.position, which is ungated too.
--
-- There is deliberately no server half, and none is needed. Server resources
-- are isolated -- the runtime installs no `exports` and no cross-resource event
-- bus, so a server library cannot be called by another server resource. That is
-- why the server side of zones is a platform API rather than a resource:
-- Open77.zones.playersIn and Open77.zones.containsPlayer are on the Open77
-- namespace, reachable from every server script directly.
--
-- The containment maths is in neither place. It is one shared Lua file,
-- scripting/lua/open77_zones.lua, embedded by both runtimes and published as
-- Open77.zones.contains, so this resource and the server answer identically.
permissions {
}
