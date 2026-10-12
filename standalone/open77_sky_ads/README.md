# open77_sky_ads

Replaces the four vanilla Towers of Light sky hologram textures with the official Open//77 wordmark for every player on your server. The original particles keep their scrolling, glow and fade; ordinary billboards are not replaced and no new hologram locations are added.

- **Docs:** [Sky hologram advertisements](https://open2077.net/docs/sky-advertising)
- **Starts:** on its own
- **Needs:** nothing
- **Runs on:** server

The source is the official logo from
https://open2077.net/brand/logo/open77-logo-light.png
(SHA-256 `00c60c9821f1e22f05c1fcb37bfba39d37bdca2ea6d91ad77435caed8f5f6e92`).
Its dark lettering is placed on a tall light backplate, with cyan/red accents and
four large vertical repetitions in a 128 x 2048 strip. No generated imitation of
the logo. The original sixteen small horizontal logos left too much dark space:
their light output was almost invisible at skyline distances. Version 1.0.1 uses
the height of the beam and keeps the backdrop bright through the mip chain.

## Build from the Open77 repository root

```powershell
pwsh scripts/new-open77-sky-ad-texture.ps1 `
  -LogoPath resources/open77_sky_ads/source/open77-logo-light.png `
  -LogoBackgroundColor '#EFF4F6' `
  -Vertical `
  -OutputPath resources/open77_sky_ads/source/open77-towers-of-light.png

pwsh scripts/build-sky-advertising.ps1 `
  -InputPath resources/open77_sky_ads/source/open77-towers-of-light.png `
  -ArchiveName Open77SkyAds -Version 1.0.1 `
  -OutputDirectory resources/open77_sky_ads/dist `
  -WolvenKitCli <path to WolvenKit.CLI.exe>
```

Requires a local Cyberpunk 2077 2.31 installation. The builder checks every XBM:
128 x 2048, DXTNoAlpha, generic color, linear gamma, streaming and 12 mip levels.
Compiled XBM/archive/ZIP outputs are ignored, not committed as game-derived assets.

Authoring regression check: `pwsh scripts/test-open77-sky-ad-texture.ps1`.
This checks the unchanged legacy generator, dimensions, opacity, luminous coverage,
and that the resource source matches the vertical generator. It does not replace
the in-game day/night check.

## Use it

`dist/` is not part of this repository (build outputs are ignored), so build
`dist/Open77SkyAds.zip` first with the steps above. Copy this resource, including
`dist/Open77SkyAds.zip`, into the server's resource root. Add `open77_sky_ads` to `resources.load`, keep `requiredMods.enabled: true`,
and restart the dedicated server. Existing required mods must stay selected.
Warden lists it as the resource-owned mod `open77_sky_ads-assets`.

Players must exit Cyberpunk and connect through the launcher to download and mount
the package before boot. A Lua hot reload cannot change already-mounted textures.
The package contains only one inert `.archive`, no scripts, DLLs or executables.
It requires neither an extra loader nor a relaxation of the server's mod policy.

Alternatively, import `dist/Open77SkyAds.zip` alone with Warden's Mods inspector;
do not also select the resource, to avoid declaring the same package twice.

To remove: remove `open77_sky_ads` from the load list, restart the server, then
relaunch the world through the launcher. Other replacers of the same four depot
paths may take priority. Quest-controlled hologram visibility is unchanged.
