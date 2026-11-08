# Window tint packs (route 2)

`build-tint.ps1` builds the two ArchiveXL **mesh-patch** packs of the window tint feature
described in `CONTRACT.md` §6, each with the server resource that ships it as a
`preload_mod`:

| Pack | Resource | What it holds |
|---|---|---|
| production | `open77_vehicle_tint` | 70 patch meshes (one per tintable glass mesh of the dealer models), 492 appearances, 6 material instances |
| T2 lab, **LAB ONLY** | `open77_vehicle_tint_t2` | 1 patch mesh (Colby `window_fl`), 1 appearance `open77_tint3__default`, its own copy of `glass_tint3.mi` |

Everything in both archives is **original data**. The generator (`native/tint.cjs`) builds
every file field by field from `data/glass-2.50.json`, which holds names and depot paths only.
The only things taken from the game are **names**: the target depot paths, the source
appearance names, the chunk material names, and the two base materials referenced by path.
No geometry, texture or material parameter set is copied. Each `.mi` sets only our four (or
two) values.

## What is in a pack

- **Material instances**, in `open77\assets\<resource>\<rev12>\materials\`. Each one is a
  `CMaterialInstance` that names its base by depot path and sets only the
  `packPlan.materialInstances` values:

  | File | Chunk material | Base | Values |
  |---|---|---|---|
  | `glass_tint1.mi` | `open77_tint1` | `base\vehicles\common\materials\glass_exterior_generic_tinted_black.mi` | TintColor `#8a9699`, Opacity 1, OpacityBackFace 0.5, BackFacesReflectionPower 0 |
  | `glass_tint2.mi` | `open77_tint2` | same | `#636e71`, 1, 0.5, 0 |
  | `glass_tint3.mi` | `open77_tint3` | same | `#212121`, 1, 0.5, 0 (retuned 2026-11-07: Thrax's 0.9 / 0.2 rendered lighter than level 2) |
  | `glass_tint<n>_onesided.mi` | `open77_tint<n>_onesided` | `base\materials\vehicle_glass_onesided.mt` | TintColor and Opacity of level n |

- **Patch meshes**, in `open77\assets\<resource>\<rev12>\windows\<target mesh file name>`.
  Each one is a `CMesh` with no geometry: no render blob, no local material, no physics, and
  every other root field at its empty default. It holds three parts:
  - `appearances`: `open77_tint<n>__<source>` for every source appearance in `packPlan.perMesh`
    and n = 1..3. Each keeps the source's chunk material list, chunk for chunk, and only the
    glass chunks are renamed `open77_tint<n>` (or `open77_tint<n>_onesided`, Supron trunk
    glass only).
  - `materialEntries`: the `open77_tint*` names this mesh uses, all external
    (`isLocalInstance 0`).
  - `externalMaterials`: our `.mi` depot paths.
- **`<resource>.archive.xl`**: one `resource: patch:` entry per target, `props: [ appearances ]`,
  `targets: [ <vanilla glass mesh depot path> ]`.
- **The preload ZIP**: `archive/pc/mod/<resource>.archive` and `archive/pc/mod/<resource>.archive.xl`.
  Entry timestamps are fixed at 2000-01-01.

ArchiveXL (`ResourcePatch` `OnMeshResourceLoad`, the same code in official 1.28.0 to 1.28.6 and
in the Open77 fork `open77/1.28`) clones each patch
appearance into the target mesh when the target loads. A chunk material name the target
lacks (`open77_tint*`) resolves from the patch mesh's own material entries. A name the target
has (`stickers`, `windows_frame_sticker`, ...) keeps the target's own material. See
`CONTRACT.md` §1 (facts) and §5 (client adapter).

## How the client consumes the names

The appearance name is the contract between the pack and the client:

```text
open77_tint<level>__<source mesh appearance>        level 1 light, 2 dark, 3 limo
```

For a vehicle with tint level L, the client walks the vehicle's glass mesh components. For
each one, it reads the component's current `meshAppearance` S (`default`, `tinted`, `dark`,
...) and switches the component to `open77_tintL__S`, **only if the loaded mesh has an
appearance of that name**. A component whose mesh is not patched, or whose source appearance
has no tint variant, is left alone. That covers windshields, mirrors, the trims the inventory
excluded, and a client without the pack.

Clearing the tint is the client's business (it restores the appearance it recorded). The
names never change between revisions; only the depot prefix does. A rebuild therefore never
needs a client change.

## Prerequisites

| Tool | Version | Notes |
|---|---|---|
| WolvenKit CLI (`cp77tools`) | 8.20.0 | resolved by `scripts/find-wolvenkit.ps1`, or `-WolvenKitCli` |
| Node.js | 18+ (built with v24.19.0) | runs `native/tint.cjs` and the archive normalizer |
| PowerShell | 7+ | the script carries `#requires -Version 7.0` and a UTF-8 BOM; Git Bash mangles the backslashes of depot paths |
| Cyberpunk 2077 | the installed build, **read only** | `OP77_GAME_DIR` (process, then user scope) or `-GameDirectory` |

## The one command

```powershell
pwsh -File scripts/vehicle-kit/windows/build-tint.ps1              # both packs
pwsh -File scripts/vehicle-kit/windows/build-tint.ps1 -Pack t2     # the lab pack only
```

The script never writes into the game folder, never launches the game and never deploys.

Output goes to `artifacts/vehicle-kit-tint/`. The script **refuses** an output folder inside the
repository that `git check-ignore` does not report as ignored, and any folder inside the game
directory. The same inputs give the same revision, and the same revision gives a
byte-identical archive, `.xl` and ZIP. Two consecutive runs on 2026-11-06 gave identical
hashes.

**Revision.** SHA-256 over these inputs; `rev12` is its first 12 hex digits:

- the pack name;
- the canonical JSON of the `packPlan` and `meshes` sections of `data/glass-2.50.json`;
- `native/tint.cjs`;
- `build-tint.ps1`;
- `archivexl/native/normalize-archive.cjs`;
- the WolvenKit version.

The vanilla files are not inputs: they are read for checks only and change no output byte.

## Outputs

| Path under `artifacts/vehicle-kit-tint/` | What |
|---|---|
| `vanilla/`, `vanilla-json/` | cache of the 70 target meshes, the base `.mi` and the two templates it reaches, plus their WolvenKit JSON. **Game data; never shipped, never committed.** |
| `<pack>/resource/<resource>/` | the server resource to install: `open77.lua`, no-op `server.lua` and `client.lua`, `dist/<resource>_<rev12>.zip` |
| `<pack>/work/packed/` | `<resource>.archive` and `<resource>.archive.xl` |
| `<pack>/work/generated/` | `plan.json`, the generated JSON (`json/materials`, `json/windows`), `generated.json` (per-mesh names), `scan.json` |
| `<pack>/work/stage`, `roundtrip`, `verify` | deserialized files, their WolvenKit round trip, and the files extracted back from the archive |
| `<pack>/manifest.json` | revision, inputs, counts, vanilla hashes read, every check's result, and a receipt (hash + size) per file |
| `<pack>/SHA256SUMS` | archive, `.xl`, ZIP |

## What the build proves

Each check fails the build; none is a warning.

1. **Data matches the installed game** (`generate`, read only). The checks:
   - every source appearance exists in the target mesh with exactly the chunk material
     names of the data;
   - no `open77_tint*` name is already an appearance or a material entry of any target, so a
     target's own material could never shadow ours;
   - every non-glass chunk name is a material entry of the target;
   - every value an `.mi` sets is a parameter of its template, of the matching class
     (`Color` → `CMaterialParameterColor`, `Float` → `CMaterialParameterScalar`). The base
     `.mi` is followed to `vehicle_glass.mt`, and `vehicle_glass_onesided.mt` is checked
     directly.
2. **WolvenKit accepts our JSON.** `convert deserialize`, then `convert serialize` back.
3. **Round trip and structure** (`validate`), checked against `packPlan`, not against the
   generator's own report:
   - exactly our files;
   - only the allowed RED4 types;
   - only our `.mi` paths in a mesh, and only its base path in an `.mi`;
   - no buffer;
   - every appearance name follows `open77_tint<level>__<source>` with a real source;
   - every chunk list has the source's length;
   - every glass chunk is swapped (513 in production) and every other chunk keeps the source
     name (564);
   - material entries are external and index our `.mi`;
   - `.mi` values come back equal, within float32 rounding;
   - every CName is one of ours or a chunk name of the target.
4. **No vanilla bytes.**
   - No staged file, archive entry, archive, ZIP entry or ZIP has the SHA-256 of any vanilla
     file the build read.
   - The 64-byte block scan (same method as the plates kit) hashes every 64-byte window of
     our cooked files and looks up every 64-byte block of the 73 vanilla files.
   - Result: **0 shared content blocks**, 78 shared blocks that are pure ASCII names, and 0
     index runs.
   - The 14 shared names are RED4 type and property names (`CMesh`, `CMaterialInstance`,
     `meshMeshAppearance`, `cookingPlatform`, `PLATFORM_PC`, `baseMaterial`,
     `rRef:IMaterial`, ...) and the base `.mi` depot path. That is what referencing by name
     means.
5. **Archive.**
   - Packed and normalized with `normalize-archive.cjs` (FILETIMEs pinned, CRC-64
     recomputed).
   - The listing equals the staged files.
   - Every file extracted back is byte-identical to the staged one.
6. **Resource.** `open77.lua`, `server.lua`, `client.lua` and `dist/<zip>` are checked against the rules
   of `ResourceManifestParser` and `ResourcePreloadModResolver`:
   - the name is a slug and matches the folder;
   - at least one script, hence the no-op `server.lua`;
   - a client script too, the no-op `client.lua`: without it the resource never runs on a
     client, so `GetResourceState` there never reads `running` and a gamemode that checks the
     pack that way (Light RP's Auto Studio, as for its body and rim packs) greys the tint menu.
     Measured 2026-11-07 on revision 63a96c8a49a0, which had none (75b3fcbb2b6e has it);
   - exactly one `.zip` preload, 1 B to 256 MiB;
   - ZIP entries only under `archive/pc/mod`;
   - no BOM in the Lua files.

   On 2026-11-06 both resources were also fed to the real server code of this branch
   (`ResourceManifestParser.ParseDirectory` and `WardenModImporter.Inspect`, loaded from its
   Release build). The result was `ok=True capability=inert review=False roots=[archive/pc/mod]`.

## T2 lab procedure (CONTRACT.md §8)

T2 proves the one thing no offline check can: a patched appearance on a **vehicle** glass mesh
resolves our external `.mi`.

1. Build the lab pack: `pwsh -File scripts/vehicle-kit/windows/build-tint.ps1 -Pack t2`.
2. Install `artifacts/vehicle-kit-tint/t2/resource/open77_vehicle_tint_t2/` on a **lab** server.
   - Never install it together with `open77_vehicle_tint`: both patch Colby `window_fl` with
     the same appearance name.
   - Add it to the load list, with `requiredMods.enabled` true.
   - `auto_start false` only keeps the no-op scripts stopped. The ZIP is offered to clients as
     soon as the resource is selected for load.
3. Launch the client through the launcher, so that it mounts
   `archive/pc/mod/open77_vehicle_tint_t2.archive` and its `.xl`.
4. Spawn a Colby (`Vehicle.v_standard2_thorton_colby_player`, factory) and note its
   `cyberId`. Read its glass first with the read-only (allowlisted) bridge command
   `vehicle.meshapps <cyberId>`: `window_fl` must list `tints=3:default` and its current
   `appearance=`. `vehicle.meshapps <cyberId> all` lists every mesh component.
5. Switch the front-left window. In a session, go through the client:

   ```text
   client.exec <playerId> return Open77.debug.command('vehicle.meshapp <cyberId> window_fl open77_tint3__default refresh')
   ```

6. `event` and `toggle` in place of `refresh` switch the name only: the window then draws
   no glass at all (the engine builds an appearance's material setup only on a resource
   load; measured 2026-11-07, `docs/research/vehicles-api.md`, W1 resolved).
7. Expected with `refresh`:
   - the front-left window shows the limo look;
   - the `stickers` chunk keeps its vanilla look;
   - the ArchiveXL log has no "didn't have material stub" warning for the mesh.
8. `vehicle.meshapps <cyberId>` must show `appearance=open77_tint3__default`. Restore with
   `... window_fl default refresh` (or the appearance `vehicle.meshapps` showed before).
   `vehicle.tintmode refresh|event|toggle` sets what the client adapter uses (default
   `refresh`).

If the window turns untextured or invisible, the patched appearance did not resolve its
material. See the first two risks below.

## Lab resource: setting a level from the server (LAB ONLY)

`lab/open77_tint_lab/` is a server-only resource (no file, no client script) for the steps after
T2. It calls the production native, so a client shows exactly what a resource would get. Copy the
folder into a **lab** server's resources beside `open77_vehicle_tint` (or the T2 pack), start it
(`auto_start false`), and grant the lab account `command.vtint`, `command.vtint.car`,
`command.vtint.get` and `command.vtint.remove`.

| Command | Does |
|---|---|
| `/vtint.car <model\|all>` | spawns the dealer model(s) 8 m ahead, side on (`colby` by default) |
| `/vtint [id\|.\|all] <0-3>` | `Open77.vehicles.setWindowTint`, then prints `getWindowTint` and the visual `rev` |
| `/vtint.get [id\|.\|all]` | `getWindowTint` and `getProperties(id).visual.tint` |
| `/vtint.remove` | removes your lab cars |

`.` (or nothing) is the car you sit in, else your last lab car. Client side, read the adapter
with the allowlisted bridge commands `vehicle.tint [vehicleId] [all]` and
`vehicle.meshapps <cyberId> [all]`.

## Install notes for the lead

- Install the production resource folder `open77_vehicle_tint/` as is.
  - The resource does nothing at runtime. Its value is the preload ZIP, and the launcher
    mounts it **before the game starts**, so a new revision needs a client relaunch.
  - Every revision has a new ZIP name and a new depot prefix. Replace the whole folder; do not
    keep two ZIPs.
- The server refuses any `preload_mod` unless `requiredMods.enabled` is true.
- Clients need an official ArchiveXL 1.28.0 or later, the first stable release for game 2.5. The
  Open77 fork `open77/1.28` changes only world streaming, so it adds nothing to this pack, and
  it is never distributed under the ArchiveXL name. On one client (2026-11-06) the switch
  behaved the same on the fork and on official 1.28.6, and the glass rendered like the factory
  glass on both; see `wiki/vehicle-customization.md`, "Which ArchiveXL each pack needs".
- Install the production pack only after T2 passes. Until then the client switch has nothing
  to switch to, and does nothing.

## Unverified

- **RTTI and field names.** Every `CMesh` and `CMaterialInstance` field name was taken from a
  WolvenKit 8.20 serialization of a vanilla glass mesh and of
  `glass_exterior_generic_tinted_black.mi`, and WolvenKit round-trips all of them. The
  **values** chosen for a geometry-less mesh were never loaded by the game:
  - `objectType ROT_Static`, `consoleBias 0`, empty `lodLevelInfo`, zero bounding box;
  - `saveDateTime 1048576`. This is WolvenKit's empty `CDateTime`; `0` is refused by its
    parser.
- **`externalMaterials` flags.** We write `Flags: Default`, as the Open77 marker meshes do
  (`scripts/markers/prepare-native-assets.cjs`). None of the vanilla files read here has an
  external material to compare against.
- **External vs local materials in a patch.** The contract's reading of the fork is that
  `MeshExtension` resolves a missing chunk material from the patch mesh's entries, "whether
  local or external `.mi`". This was never measured on a vehicle mesh, and T2 is that
  measurement.
  - If T2 shows the material is not found, switch the generator to local instances: a
    `localMaterialBuffer` holding the same `CMaterialInstance`, with `isLocalInstance 1`. It
    is still only our values; see `scripts/vehicle-kit/native/cook.cjs` for the WolvenKit
    shape.
- **`props: [ appearances ]` alone.** We assume this makes ArchiveXL carry the patch's material
  entries along with the appearances. That is the contract's reading, not a measurement.
- **A geometry-less patch with external materials only.** ArchiveXL's own
  `h1_base_color_patch.mesh` has a null render blob. Its material layout was not compared.

## Risks

- **Material not resolved** (see above). Symptom: a black, white or missing window after a
  switch. T2 isolates it to a single window.
- **Appearance reset.** An entity appearance change, stream-in or rebuild writes the `.app`
  definition's `meshAppearance` back. The client must replay the tint at the same moments as
  hide/show and plates.
- **Game updates.** A patch's chunk list is the data's, checked against the installed game at
  every build. If a game update reorders a target's chunks, the build fails at check 1 instead
  of shipping wrong materials. Rerun `glass_inventory.py`, then this script.
- **Two installs.** Production and T2 both add `open77_tint3__default` to Colby `window_fl`.
  ArchiveXL's behaviour with duplicate patch names is not defined here, so never install both.
- **Level values** are starting points copied from looks the game already renders. Tuning
  them (CONTRACT T3) changes only `packPlan.materialInstances`, hence a new revision, and no
  client change.

## Revisions and hashes

Production built 2026-11-07 with WolvenKit 8.20.0 and node v24.19.0, against the Steam install,
after the limo retune and the no-op `client.lua`. The data digest (`packPlan` + `meshes`) is
`70af099072601cd8068a8cab8ea20eac7f11c5228ce8f9a7ec6aa94d4acbe77c`. The T2 row is the 2026-11-06
build; rebuilding it now gives a new revision (the script changed).

| Pack | rev12 | Meshes / appearances / `.mi` | Archive SHA-256 (bytes) | `.xl` SHA-256 | ZIP SHA-256 (bytes) |
|---|---|---|---|---|---|
| production `open77_vehicle_tint` | `75b3fcbb2b6e` | 70 / 492 / 6 | `4d784caa3333677e26acd5655dca18adaf1a1c3c74fbfdd8bf1e9c214ff1de7a` (90 112) | `4dd48fd6068822cb3a9bb25a528ed57f5b7b99d2421190644258bec9bf1182ee` | `4787ce221a0daea9b614d93a786ef8a893e108794b400896494e53aab6b7e636` (15 532) |
| T2 `open77_vehicle_tint_t2`, LAB ONLY | `206898005489` | 1 / 1 / 1 | `39e145fa71f6c661b994ef05e58433419b711749df6bbdb6e01c6097975a532c` (8 192) | `f4fb94f688a8382e4cdf0a0742af60b11fdf9b71ddc2e9ca180a771a56b73910` | `906188aca247c52cab1fc9d42b5f7d713d412a225d359d70436fc8b639250080` (2 057) |

Any change to `native/tint.cjs`, `build-tint.ps1`, the normalizer, the data or WolvenKit gives
a new revision. Update this table with the build that is actually installed.
