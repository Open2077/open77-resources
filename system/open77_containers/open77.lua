-- open77_containers -- durable world containers (world-interaction row A6).
--
-- A crate, a ground pile or a salvage node is a `world:` container that the A13
-- transaction coordinator (`open77_transactions`) mints and holds: contents,
-- capacity, expiry and -- in the world row's metadata -- the placement. Its
-- prop, state-bag summary and interaction prompt are projections this resource
-- rebuilds at every boot by paging the coordinator's `listWorld` and joining
-- its own registry (policy, metadata, node charges, grants, tombstones). See
-- docs/world-interaction/a6-containers.md.
--
-- Opt-in: `auto_start false`. Load it through `resources.load` together with
-- `open77_transactions`. The coordinator is deliberately NOT a `dependency`: it
-- ships no client half, and the client validates every dependency of a
-- client-shipped resource (docs/research/rp-server-build-rounds.md). Instead
-- the boot waits for `open77_transactions:ready`; until then (and whenever the
-- coordinator is down) value operations answer `coordinator_unavailable`.
--
-- Registry store: SQL by default (table `open77_containers`), chosen once at
-- boot and never switched. `lab_kvp` (Open77.kvp, disposable) needs BOTH
-- convars `open77_containers_store lab_kvp` and `open77_containers_lab 1`.
resource "open77_containers"
version "0.2.0"
open77_version ">=0.0.1"
auto_start false
reload_policy "local"

-- Both ship a client half, so the client manifest may name them.
--   open77_interactions  server `define` / `clear` (container prompts) and the
--                        prop grant contract (`grantProp` / `revokeProp`), 0.3.0
--   open77_props         client projection of the props this resource creates
dependency "open77_interactions >=0.3.0"
dependency "open77_props >=0.1.0"

server_script "shared/model.lua"
server_script "server/store.lua"
server_script "server/service.lua"
server_script "server/main.lua"
client_script "client/main.lua"

permissions {
    -- server: RegisterNetEvent("open77_containers:use"); client: TriggerServerEvent
    "network.events",
    -- server: Open77.props.create / get / remove / setTransform / attach / detach,
    --         onPropRemoved (the projection of every container)
    "world.props",
    -- server: Open77.state.entity("prop", id):set -- the public summary mirror.
    --         Written, never read for a decision (any state.write resource can
    --         overwrite a prop bag; the sweep repairs drift).
    "state.write",
    -- server: the registry table (sql store mode)
    "database.access",
}
