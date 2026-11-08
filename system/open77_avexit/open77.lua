-- open77_avexit -- the AV door animations: Rosalind Myers stepping out of her
-- AV in Phantom Liberty (q305), stepping up into it, (1.2.0) sitting down in a
-- Rayfield Excalibur's pilot seat (side quest sq012) and (1.3.0) Corpo V
-- climbing into Jenkins' AV and sitting down on its back seat (the opening,
-- q000; 1.3.1: it starts farther from the AV, clear of its collision), cut into
-- five clips and shipped as the custom locomotion package
-- `avexit`. open77_avdoor plays them when a player steps out of an aircraft or
-- boards one; this resource only registers the package and ships its archive.
-- README.md says where the motion comes from and how it was built.
resource "open77_avexit"
version "1.3.1"
open77_version ">=0.0.1"
auto_start true

-- The archive is mounted by the game as it starts: a running client keeps the
-- revision it booted with until it reconnects.
reload_policy "reconnect"

shared_script "register.lua"
files { "package.json", "graph.locomotion.json" }

-- Installed by the launcher in archive/pc/mod before Cyberpunk starts (the
-- server serves it as a required mod: `requiredMods.enabled` must be true).
preload_mod "dist/Open77Locomotion_avexit_3ff5278f87ee.zip"

-- Both halves: Open77.locomotion.register -- the server learns the clips'
-- lengths, the client the graph and the archive's depot paths.
permissions { "locomotion.register" }
