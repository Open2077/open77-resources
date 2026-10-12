-- open77_fuel -- the canonical state-bag sample (native-parity C9).
--
-- Cyberpunk has no fuel model, so `GetVehicleFuelLevel` / `SetVehicleFuelLevel`
-- have no native to adapt. Fuel is a STATE-BAG FIELD: the server owns a `fuel`
-- key on every vehicle's bag, burns it from the replicated speed and engine
-- state once a second, cuts the engine at zero, and every client that streams
-- the car reads the number for free. This resource is the reference for that
-- pattern -- a per-vehicle gameplay value a server invents -- and is deliberately
-- small enough to copy.
resource "open77_fuel"
version "1.0.0"
open77_version ">=0.0.1"
auto_start true
reload_policy "local"

shared_script "shared/fuel.lua"
server_script "server/main.lua"
client_script "client/main.lua"

-- world.vehicles (server): the registry read (`all`, `get`) and `setEngine`,
-- which is how "out of fuel" reaches the car.
-- state.write (server): the `fuel` key on each vehicle's replicated bag. Bag
-- reads need no permission on either side.
-- vehicles.read (client): only for `current()`, which maps the entity the
-- local body is mounted in back to its canonical id through
-- `Open77.vehicles.fromEntity`; `level(id)` is a bare bag read.
permissions { "world.vehicles", "state.write", "vehicles.read" }
