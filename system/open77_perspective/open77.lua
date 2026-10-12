resource "open77_perspective"
version "1.0.0"
open77_version ">=0.0.1"
auto_start true
reload_policy "local"

client_script "client/main.lua"
server_script "server/main.lua"

-- The reticle is now the trusted client bootstrap resource open77_reticle.
-- It must also work with native F7 when this optional policy resource is absent.

-- `input.actions` for the toggle key, `network.events` for the policy channel,
-- `perspective.policy` for the one call that can take the choice away from the
-- player. No permission is needed to ASK for a perspective -- `Open77.perspective`
-- `set`/`get`/`toggle`/`state` are ungated, like `Open77.camera`.
permissions { "input.actions", "network.events", "perspective.policy" }
