aetherfall - Open77 custom locomotion

Extract this resource into your server's resources directory and ensure
open77_locomotion_aetherfall. The launcher installs its preload archive before
starting Cyberpunk. Already running clients must restart after installation.

In the resource that controls player styles, declare:
  dependency 'open77_locomotion_aetherfall'
  permissions { 'locomotion.control', 'locomotion.read' }

Server Lua:
  local ok, reason = Open77.locomotion.set(playerId, 'aetherfall')
  local selected = Open77.locomotion.get(playerId)
  Open77.locomotion.reset(playerId)

set also accepts { durationMs = 60000, resetOnDeath = true }.
The assigning resource owns the selection and releases it on stop.
Native movement, collision and gameplay remain authoritative. The graph
drives presentation bodies (remote players and local third-person view).
Vehicle/workspot, airborne, traversal, swimming and combat poses retain
native ownership. A missing/unregistered package keeps the native gait.

Built-in parameters: speed (m/s), directionX/directionY (unit direction
in the rendered body basis), grounded, crouched and sprinting. mounted
remains false while custom locomotion is active. Other parameters retain
their authored defaults; runtime custom parameter/trigger control is not
available in version 1.

The export validates native asset structure and archive roundtrips.
Test your authored clips on both puppets in-game before distributing.
An Open77 client and server with locomotion package v1 support are required.

PRIVATE LOCAL DEMONSTRATION ASSETS
Casting motions were extracted from the owner's installed Hogwarts Legacy and retargeted onto the male and female Cyberpunk rigs. Do not publish this resource. The import and baking recipe is scripts/aetherfall/build-animation-banks.ps1; provenance and validation are in artifacts/aetherfall/animation-bake and docs/research/aetherfall-arena.md. The animation graph uses native movement as its base; Open77.locomotion.playClip drives the five transient casting clips.

