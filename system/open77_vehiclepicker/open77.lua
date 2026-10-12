resource "open77_vehiclepicker"
version "0.1.0"
open77_version ">=0.0.1"
auto_start true

-- "reconnect", like every resource that owns a CEF surface. Swapping a live
-- surface while gameplay runs has historically been unstable, so the roster is
-- deliberately DATA rather than behaviour: editing `shared/roster.lua` is the
-- normal way to change what this resource offers, and it costs a reconnect
-- rather than a code review.
reload_policy "reconnect"

-- No dependencies, and that is a decision.
--
-- A declared dependency is HARD -- `StartRecursive` refuses a resource outright
-- with `missing_dependency:<name>` when one is absent. The picker is useful
-- with nothing else running (it opens, it remembers, it reports) and every
-- gamemode that consumes it does so through exports and net events, both of
-- which degrade to a clear error rather than a crash when the other side is
-- missing. Adding a gamemode here would invert that: a server that does not run
-- Pursuit could no longer run the picker either.

-- The roster is `shared`, not `client`, so that the file a gamemode's server
-- copies is byte-for-byte the file the client validates against. See README.md,
-- "Integrating", and `wiki/gamemode-kernel.md` for why copying is the only
-- server-side sharing mechanism this platform has.
shared_script "shared/roster.lua"

-- Listed explicitly, never globbed. `client/**/*.lua` requires an intermediate
-- directory and matches nothing against a flat `client/main.lua`; the client
-- then refuses the WHOLE session resource set with
-- `script_pattern_empty:client/**/*.lua` and nobody can connect.
client_script "client/main.lua"

-- No server script. This is not an omission -- the server Lua runtime installs
-- no `exports` and no cross-resource event bus, so a server half here could
-- never be asked for anything by a gamemode (`wiki/gamemode-kernel.md`). The
-- gamemode's own server owns validation, using its copy of the roster.

web_ui_page "web/index.html"
-- Created explicitly in client/main.lua so the surface's layer, zIndex and
-- initial visibility are set in one place with the reasons beside them.
web_ui_auto_create false
web_files { "web/**" }

permissions {
    -- AddEventHandler("open77:pauseKey"), the reliable Escape path.
    "local.events",
    -- RegisterNetEvent for open/close/lock, TriggerServerEvent for the pick.
    "network.events"
}
