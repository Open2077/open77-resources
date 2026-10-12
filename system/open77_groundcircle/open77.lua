resource "open77_groundcircle"
version "0.2.0"
open77_version ">=0.0.1"

-- auto_start, and why it changed from false to true.
--
-- It was `false`, with the reasoning that "a HUD surface appearing unannounced
-- during a live session is indistinguishable from a bug". The instinct was
-- right and the mechanism was wrong, for two reasons found while making this
-- resource production-ready:
--
--   * There is no way to start it. `auto_start false` is honoured by
--     `StartAutomatic()` in scripting/src/ResourceHost.cpp, and neither the Lua
--     surface nor the admin console exposes any start verb. A client-only
--     resource with `auto_start false` is not "opt-in", it is unreachable --
--     so the fallback could never actually have been used.
--   * The surface it creates is transparent, `pointer-events: none`, and empty
--     until a caller asks for a circle. Nothing appears unannounced, because
--     nothing appears at all until an export is called.
--
-- The gate that does the work instead is MEMBERSHIP OF THE RESOURCE SET. This
-- resource is absent from the Pursuit server's resources.load list, so that
-- server does not discover or start it. Adding it is the deliberate act:
--
--     "load": [ ..., "open77_groundcircle" ]
--
-- and then one line in the caller -- see the header of client/main.lua, which
-- carries the exact line and explains why `create` accepts open77_worldui's
-- definition table unchanged.
auto_start true

-- The circle geometry lives entirely in Lua and the page is stateless between
-- frames, so a hot reload loses nothing a caller cannot re-create.
reload_policy "local"

-- Listed explicitly, one per line. A `**` glob over scripts matches nothing
-- against a flat client/main.lua and the client then refuses the ENTIRE
-- resource set with `script_pattern_empty` -- nobody can connect, and the
-- symptom names this file only if you already know to look. `**` is safe for
-- web_files and nowhere else.
client_script "client/main.lua"

-- No permissions block, and that is checked rather than assumed: the `hud`
-- layer is ungated (only `modal`, `system` and `debug` require one), exports
-- and the resource-lifecycle handlers need none, and `open77:worldReady` is
-- subscribed to by `pursuit`, which declares no local-event permission either.
-- Nothing here reads the world, so there is nothing else to ask for.

web_ui_page "web/index.html"
web_ui_auto_create false
web_files { "web/index.html" }
