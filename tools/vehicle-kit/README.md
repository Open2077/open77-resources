# vehicle-kit

The pipeline that builds Open77 vehicle customization packs: original rims, body kit parts,
liveries, stickers, performance stages with engine sounds, plates and window tint, each as a
resource ready to copy into a server, with its `preload_mod` ZIP.

- **Docs:** [Vehicle customization content packs](https://open2077.net/docs/vehicle-customization-packs)
- **Runs on:** your Windows machine, with PowerShell 7. Never on the server.
- **Needs:** Cyberpunk 2077, the WolvenKit CLI, Node.js 18+, Python 3 with `numpy` and `Pillow`,
  and Blender 4.5 for rims and body parts

## What is in this folder

The folders mirror the Open77 platform repository, so every script runs unchanged. **Run every
command from this folder** (`tools/vehicle-kit`).

| Path | Content |
|---|---|
| `scripts/vehicle-kit/` | The pipeline. Its `README.md` explains every step and every check |
| `scripts/vehicle-kit/specs/` | The specs and fit tables of the Light RP reference packs |
| `scripts/find-wolvenkit.ps1` | Finds the WolvenKit CLI (`-WolvenKitCli`, `OP77_WOLVENKIT_CLI`, dotnet tools, usual folders) |
| `scripts/furniture/luahost.py` | The Lua host the Python tests run the generated Lua in |
| `docs/generated/*.json` | The vehicle inventories the fit tables are built from: component names, depot paths and measurements of the vanilla player cars, Cyberpunk 2077 2.50 |
| `server/.../vehicles-2.31.tsv` | The vehicle record list the stages builder reads |
| `client/redscript/Open77VehiclePlate.reds` | The client plate script the plates build checks |

Builds write to `artifacts/` in this folder, which git ignores. The game folder is read, never
written: set `OP77_GAME_DIR` or pass `-GameDirectory`.

## Build a pack

Each builder takes a JSON spec (`-Spec`). Without one, `build-pack.ps1` builds a small example
pack (`parts.example.json`) and the other builders rebuild the Light RP reference pack: the
quickest way to check your setup. The Light RP rims and body kit specs are
`specs/lightrp-rims.json` and `specs/lightrp-bodykit.json`.

| Pack | Command | Guide |
|---|---|---|
| Rims, body kit parts | `pwsh -File scripts/vehicle-kit/build-pack.ps1 -Spec <spec>.json` | `scripts/vehicle-kit/README.md`, `docs/rims.md`, `docs/bodykit.md` |
| Liveries | `pwsh -File scripts/vehicle-kit/liveries/build-liveries.ps1` | `docs/liveries.md` |
| Stickers | `pwsh -File scripts/vehicle-kit/stickers/build-original-stickers.ps1` | `docs/stickers.md` |
| Stages and engine sounds | `pwsh -File scripts/vehicle-kit/stages/build-stages.ps1` | `stages/STAGES.md` |
| Plates | `pwsh -File scripts/vehicle-kit/plates/build-plates.ps1` | `plates/README.md` |
| Window tint | `pwsh -File scripts/vehicle-kit/windows/build-tint.ps1` | `windows/README.md` |

The guides are relative to `scripts/vehicle-kit/`. Rims and body parts need the Blender add-on
once: `pwsh -File scripts/vehicle-kit/build-pack.ps1 -InstallAddon`.

Every build ends with the resource folder under `artifacts/`. Copy it into your server's
resources, add it to `resources.load` in `server.jsonc`, and have the players reconnect: the
launcher mounts a `preload_mod` before the game starts.

## Rules the builds enforce

- **Original content only.** No game file is copied into a pack: game data is only named, by
  depot path or record. The rims and body kit cook refuses any embedded file and any reference
  outside a short allowlist; the liveries, stickers and plates builds compare every cooked file
  with every game file they read and fail on a shared block outside a hand-reviewed baseline
  ("No vanilla bytes").
- **The resource name is part of the content.** Every depot path in the archive starts with
  `open77\assets\<resource>\<revision>\`. To rename a pack, rebuild it under the new name.
- **The revision is a hash of the inputs.** It names the ZIP and the depot folder, so a rebuilt
  pack can never be shadowed by a stale copy in a player's cache. The same inputs rebuild the
  same bytes.

## Ready-made packs

The Light RP server publishes the packs this pipeline built, with their declaring scripts:
[Open2077/light-rp, `resources/assets/models`](https://github.com/Open2077/light-rp/tree/main/resources/assets/models)
(`lightrp_vk_*`, `lightrp_vehicle_*`, `open77_vehicle_plates`). Its
`lightrp_vehicle_kit/README.md` says how to turn them on.

## Good to know

- The notes cite research documents and sources of the platform repository by path. Those are
  not public; the rules they led to are written into the scripts' checks.
- One check of `stages/test_engine_sounds.py` reads the platform server's customization table,
  so it fails outside the platform repository; the other tests run here.
- `prove-launcher-delivery.ps1` proves the launcher delivers a pack to a fresh client. It needs the
  Open77 launcher sources.
