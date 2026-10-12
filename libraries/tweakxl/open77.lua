-- TweakXL: loads r6/tweaks YAML/TweakDB records (fast travel points, vehicles, items).
--
-- Upstream: https://github.com/psiberx/cp2077-tweak-xl (MIT; LICENSE and
-- THIRD_PARTY_LICENSES ship inside the package). The zip is the official release,
-- untouched, and is game-root-relative (red4ext/plugins/..., r6/config/...).
--
-- A loader is a shared dependency, not world content: any resource whose assets
-- need it declares `dependency "tweakxl >=1.11.4"` and this package rides along as
-- the required mod "tweakxl-assets". RED4ext plugins initialise before the depot
-- mounts archives, so there is no ordering to manage between loader and world.
--
-- It is EXECUTABLE content. A server only boots with it when
-- `requiredMods.unsecured` is true; every list badges that server and players
-- confirm the risk before joining. Bump the version here and swap the zip in
-- dist/ together -- the manifest version is what dependents pin against.
resource "tweakxl"
version "1.11.4"
auto_start true

preload_mod "dist/TweakXL-1.11.4.zip"

server_script "server/main.lua"
