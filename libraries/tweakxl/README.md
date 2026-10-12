# tweakxl

Installs the TweakXL loader in your players' games, so your world resources can add TweakDB records from `r6/tweaks` YAML files, such as fast travel points, vehicles and items. It is a shared dependency, not world content: any resource that needs TweakXL declares it, and several worlds share one copy.

- **Docs:** [Mods your server requires](https://open2077.net/docs/server-mods), [Mods: the complete guide](https://open2077.net/docs/mods)
- **Starts:** on its own
- **Needs:** nothing
- **Runs on:** server

## Use it

In the resource whose assets need TweakXL, declare the dependency:

```lua
dependency "tweakxl >=1.11.4"
```

Add `tweakxl` to `resources.load` next to that resource, keep
`requiredMods.enabled` set to `true`, and restart the server. The zip is declared as
the required mod `tweakxl-assets`, and the launcher installs it before the game
boots. RED4ext plugins initialise before the game mounts archives, so there is no
load order to manage between the loader and your world.

The zip contains a RED4ext plugin (`TweakXL.dll`), which is executable content. A
server only boots with it when `requiredMods.unsecured` is `true`; server lists then
badge your server as unsecured and players confirm the risk before joining. On a
secured server, exclude it from a wildcard selection with `"!tweakxl"`.

The server script only prints a line at start; the loader itself runs in the
player's game. To update it, replace the zip in `dist/` and bump the manifest
`version` together, because dependents pin against the manifest version. A new
package needs a server restart and a fresh launcher boot of the game.

## Credit and licence

`dist/TweakXL-1.11.4.zip` is the official TweakXL 1.11.4 release, untouched.
TweakXL is made by Pavel Siberx (psiberx) and is MIT-licensed upstream:
https://github.com/psiberx/cp2077-tweak-xl. Its `LICENSE` and
`THIRD_PARTY_LICENSES` files ship inside the zip, under `red4ext/plugins/TweakXL/`.
Keep them when you redistribute the package.
