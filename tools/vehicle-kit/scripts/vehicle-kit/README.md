# Vehicle kit asset pipeline

Builds original vehicle parts (rims, rear wings) as Open77 prop models, from a JSON spec,
with one command and without the game running:

```text
spec.json ─► Blender (procedural, original geometry) ─► .glb
          ─► WolvenKit import onto a template .mesh ─► native cook (local materials, LOD
             table, one mesh + visual host .ent per model) ─► serialize round trip check
          ─► .archive ─► preload_mod ZIP + package.json + Lua ─► owner-review renders
```

Each part is visual only (campaign decision D5): no collision, no physics, the car keeps
its stock tyres and handling. A server resource declares the parts with
`Open77.vehicles.registerParts` (one fit per vehicle record) and puts them on a car with
`setWheels` / `setParts`; every client binds them to the car's slots. Only the E0.9 lab
resource uses `Open77.props.attach`. All the geometry is original (D6): nothing is traced,
copied or derived from a game mesh, and the cook fails if a cooked file embeds anything
or references a game resource outside a short allowlist (see "Cooked layout").

## Prerequisites

| Tool | Version proven | Where it is looked for |
|---|---|---|
| PowerShell | 7.x (`pwsh`) | |
| Blender | 4.5.14 portable | `-Blender`, `OP77_BLENDER`, `%LOCALAPPDATA%\Open77\blender\`, `%LOCALAPPDATA%\Sanstour\tools\blender-portable\*\`, `%ProgramFiles%\Blender Foundation\*\`, `PATH` |
| Cyberpunk IO Suite (Blender add-on) | 1.8.0, the last release for Blender 4.5 | `-BlenderScripts`, `OP77_BLENDER_SCRIPTS`, `%LOCALAPPDATA%\Open77\blender-scripts` |
| WolvenKit CLI (`cp77tools`) | 8.20.0 | `scripts/find-wolvenkit.ps1` (`-WolvenKitCli`, `OP77_WOLVENKIT_CLI`, dotnet tools) |
| Node.js | 18+ | `PATH` |
| Cyberpunk 2077 | 2.31 | `-GameDirectory`, `OP77_GAME_DIR` (process, then user scope) |

The game folder is **read** for two template files and never written.

**Blender stays untouched.** The script never runs Blender with its normal profile. Each
Blender child process gets its own `BLENDER_USER_SCRIPTS`, `BLENDER_USER_CONFIG`,
`BLENDER_USER_EXTENSIONS` and `BLENDER_USER_DATAFILES`, set for that process only, and
starts with `--factory-startup`. The add-on lives in its own folder and is enabled for
the run only (`addon_utils.enable(..., persistent=False)`). This matters when the same
Blender is shared with another project.

Install the add-on once into that dedicated folder. The download is checked against the
release SHA-256 `80538cf42eb17f266267dc7fb19f15f891d3cb6c5765b7e228ee4d95cf5564ef`:

```powershell
pwsh -File scripts/vehicle-kit/build-pack.ps1 -InstallAddon
```

Without the add-on, `-Exporter auto` falls back to Blender's stock glTF exporter with a
warning. The geometry is the same; you only lose the add-on's mesh validation:

- UVs present;
- under 65 535 vertices per submesh;
- no degenerate faces.

## One command

```powershell
pwsh -File scripts/vehicle-kit/build-pack.ps1                          # parts.example.json
pwsh -File scripts/vehicle-kit/build-pack.ps1 -Spec my-kit.json -SkipPreview
pwsh -File scripts/vehicle-kit/build-pack.ps1 -DeepCollisionCheck       # also scans the game archives for open77\ paths
```

The output goes to `artifacts/vehicle-kit/<resource>/`, which is git-ignored. The script
refuses an output folder that sits inside the repository without being ignored. The
command ends with `VK_PACK_OK`; any failure throws, with the failing tool's last lines.

| Path in the output folder | Content |
|---|---|
| `resource/<resource>/` | The asset resource: `open77.lua`, `register.lua`, `package.json`, `dist/<Archive>_<rev12>.zip` |
| `resource/<resource>_e09/` | The E0.9 lab resource (commands below) |
| `preview/` | `<part>_<finish>_34.png` (3/4 hero view) and `<part>_<finish>_sheet.png` (four views) |
| `manifest.json`, `SHA256SUMS` | Revision, tool versions, template hashes (not shipped), ZIP/archive/preview hashes |
| `work/` | Intermediates: glb, imported mesh, prepared JSON, stage, round trip, packed archive, cached templates |

**Reruns are idempotent.** The revision is the SHA-256 of:

- the spec;
- every pipeline script;
- the tool versions;
- the two template hashes.

Its first 12 hex digits name the depot folder (`open77\assets\<resource>\<rev12>\`) and
the ZIP. The glb, the imported mesh and every staged file are already reproducible.
`cp77tools pack` stamps each archive entry with the time of the pack, so
`native/normalize-archive.cjs` pins those timestamps to 2000-01-01 UTC and rewrites the
index checksum (CRC-64/XZ, verified before patching). The ZIP entry uses the same fixed
time. An unchanged input therefore rebuilds the same paths and the same archive and ZIP
bytes. Any change gives new depot
paths, so a new archive can never be shadowed by an old one still in a player's cache.

What the build checks, and fails on:

- **Spec:** names against the `registerModel` rules; palette references; no
  `archiveName` that collides with a platform archive.
- **Import:** chunk count, triangles per chunk, LOD masks, and bounds within 3 mm of
  the Blender export.
- **Cook:**
  - no collision parameters;
  - an increasing LOD table;
  - every cooked `PS_Color` is `ffffffff`;
  - **materials are all local:** no `externalMaterials`, `preloadExternalMaterials`,
    `preloadLocalMaterialInstances`, `localMaterialInstances` or `inplaceResources`
    entry; every material entry has `isLocalInstance = 1`; every local material is a
    `CMaterialInstance` on `metal_base.remt`, cooked for `PLATFORM_PC`, with the palette's
    parameters, `Metalness` and `Roughness` set to `white.xbm` and no bias (see
    "Finishes: metalness");
  - exactly one appearance, `default`, naming only existing material entries;
  - nothing embedded, and no reference outside our prefix except `metal_base.remt`,
    `white.xbm` and the host's interaction definition (D6);
  - exactly two pure `entMeshComponent` copies per visual host, on appearance `default`;
  - unique basenames.
- **Round trip:** the deserialized files serialize back to the same geometry, vertex
  colors, LOD table, `geometryHash`, local materials (WolvenKit must have written one
  `meshLocalMaterialHeader` per material), appearance and hosts. The same material
  rules run again on the round trip.
- **Staged binaries:** each cooked `.mesh` must name `localMaterialBuffer` and must not
  name `externalMaterials`, `preloadExternalMaterials`, `preloadLocalMaterialInstances`
  or `inplaceResources`. This is the byte scan of `scripts/check-prop-meshes.py`: a CR2W
  file lists the properties it writes in its name table, and WolvenKit writes no empty
  list.
- **Archive and ZIP:**
  - the archive listing equals the staged list;
  - every path sits under the revision prefix, so no vanilla path is present;
  - every extracted file is byte-identical to the staged one;
  - the ZIP has exactly one entry, `archive/pc/mod/<archiveName>.archive`, and is at
    most 64 MiB.

## Measured conventions

Measured on `v_standard2_archer_hella__ext01_wheel_fl_01.mesh` (rear:
`..._wheel_bl_01.mesh`) with `measure-vanilla.ps1`. To re-measure another model:

```powershell
pwsh -File scripts/vehicle-kit/measure-vanilla.ps1                     # Archer Hella front wheel + right wheel entity
pwsh -File scripts/vehicle-kit/measure-vanilla.ps1 -Name <mesh base name> -Folder <base\vehicles\...\entities> -Entities <ent base names>
```

It extracts into `%TEMP%\open77-vehicle-kit-measure`, which it refuses to place inside
the repository. Never commit what it extracts.

| Property | Value |
|---|---|
| Units / axes | metres; engine and Blender axes: X right, Y forward, Z up. glTF export (Y-up) and WolvenKit import cancel out, with bounds identical to the Blender export |
| Spin axis | X |
| Pivot | wheel centre (Y = Z = 0) |
| Outboard face | −X: the branding decal quad sits at X = −0.211 |
| Front rim | radius 0.2785; X −0.211 … +0.104 (width 0.315) |
| Rear rim | radius 0.2874; X −0.243 … +0.099 |
| Front tyre (separate mesh) | outer radius 0.3726; X −0.210 … +0.093 |
| LODs | `lodLevelInfo [0]`: one LOD |
| Chunks | 4: decal (2 tris) + rim (920 tris) on lodMask 1, plus two lodMask 0 chunks (shadow/proxy) |
| Materials | `ml_v_standard2_archer_hella_wheel_01_masksset` (local multilayer instance) + `vehicle_branding` |
| Mesh flags | `objectType ROT_Vehicle`, one `meshMeshParamPhysics` convex collider |
| Mounting | the wheel `.ent` binds the mesh as `entPhysicalMeshComponent` with `entHardTransformBinding` to `vehicle_slots/wheel_front_left` |
| Right side | `..._wheel_fr_01.ent` binds the **same** `wheel_fl_01.mesh` to `vehicle_slots/wheel_front_right` with an identity transform |

From the right-side row, one rim mesh fits all four slots (`wheel_front_left`,
`wheel_front_right`, `wheel_back_left`, `wheel_back_right`), because the right-hand slot
frames must be mirrored. This is an inference until the E0.9 test. The rim generator
follows the front convention by default: `radius 0.2785`, `face_x −0.208`,
`width 0.305`.

### Cooked layout

The cooked shape copies the Light RP board-game props (`roulette_ball.mesh`,
`chess_board.mesh` in `0_open77_tabletop_extra.archive`), the custom meshes proven
visible in game. The field-by-field comparison is in
`docs/research/props-and-object-spawning.md` (2026-11-05, E0.9 second result).

**One mesh per model.** Each `<part>_<finish>` gets its own mesh, whose only appearance
is `default`. The reason is in the client: the Open77 mesh backend rewrites every
mesh component of a registered model's host to the appearance the caller asked for,
`default` when none, and does not reload the resource for a registered model
(`client/src/api/Props.cpp`, `BeginComponentWrite`). A host authored on any other
appearance is changed under the engine. The geometry is duplicated per finish: about
45 KB per rim mesh.

**Mesh.** The container is WolvenKit's import template
`base\environment\ld_kit\box_1m_1m_1m_grey.w2mesh`. The cook then replaces or drops
everything else:

- geometry comes from the glb;
- its box collider is dropped (`parameters = []`), and so are the bone lists and every
  external or preloaded material list;
- materials are **local**: `localMaterialBuffer` holds one `CMaterialInstance` per palette
  material the finish uses, on `engine\materials\metal_base.remt`, cooked for
  `PLATFORM_PC`, with `BaseColor`, `Metalness` and `Roughness` =
  `engine\textures\editor\white.xbm` and the palette's `BaseColorScale`, `MetalnessScale`
  and `RoughnessScale` (see "Finishes: metalness"). The material buffer takes
  `BufferId 0` and the render buffer `1`: with a shared id WolvenKit refuses the file;
- `materialEntries` are `isLocalInstance = 1`;
- `lodLevelInfo` and `renderLODs` get the spec's distances, because WolvenKit writes
  `[0, 0]`, which would hide the finest LOD. The default is one LOD, `[0]`, like every
  custom mesh proven visible;
- `geometryHash` is the first 8 bytes (little-endian) of the SHA-256 of the render
  buffer, and `surfaceAreaPerAxis` is the projected area that Blender measures, both
  computed as the board-game props compute theirs. The template left `0` and `(1, 1, 1)`;
- `castGlobalShadowsCachedInCook` and `castLocalShadowsCachedInCook` are `1`, and the
  quantization `W` is offset `1`, scale `0` instead of the template's `-inf`, as on the
  proven props;
- `objectType` is `ROT_Static`, not the vanilla wheel's `ROT_Vehicle`.

**Vertex colors must be white.** The imported layout carries a `PS_Color` stream.
`metal_base.remt` multiplies the surface by vertex color and alpha. A glb without
`COLOR_0` makes WolvenKit fill that stream with `00000000`, and the part then draws
nothing in the main pass while still casting its shadow. That was the first E0.9
result. So the pipeline enforces white at three points:

- every Blender object carries two white byte-color attributes, exported as `COLOR_0`
  and `COLOR_1` (`export_vertex_color='ACTIVE'`, with the add-on's options extended for
  the run);
- the glb is checked to be 1.0 on every primitive;
- the cook asserts every cooked `PS_Color` is `ffffffff`, after import and again after
  the round trip.

The proven Light RP props write and assert the same values.

**Visual host.** There is one per model, a copy of `base\gameplay\debug\debuginteraction.ent`:

- both `entMeshComponent` copies point at the model's mesh, appearance `default`;
- the interaction component is disabled;
- `autoHideDistance` comes from the spec (150 m);
- the template's embedded vanilla mesh (`ld_kit_dcem_computer_screen_station.w2mesh`,
  512 vertices) is removed, with its `inplaceResources` and `resolvedDependencies`
  entries. Earlier builds shipped it inside every host, as the Aetherfall and board-game
  hosts still do. Nothing referenced it once the mesh components were repointed.

The root stays `DebugInteractionObject`, not the board games' `entEntity`. A registered
model is spawned from a TweakDB record through the dynamic entity service, which needs a
`gameObject` root: the E0.2 crash came from template roots that are not one (see the
comment above the host lookup in `Props.cpp`). The board games spawn their raw `.ent`
through the static entity backend instead.

**Depot paths.** Everything sits under `open77\assets\<resource>\<rev12>\`:

- `<part>_<finish>.mesh`;
- `<part>_<finish>_visual.ent`.

No ArchiveXL or TweakXL file is needed, since nothing in the game references the new
paths except our props.

**Models.** The models are `<part>_<finish>`, used in game as
`asset:<resource>/<part>_<finish>`. Do not pass `appearance` to `props.create`: each
mesh has only `default`.

### Finishes: metalness

`metal_base.remt` reads each channel as *texture × Scale + Bias*. Its own defaults are
`Metalness` = `engine\textures\editor\black.xbm`, `Roughness` = `white.xbm`, `BaseColor` =
`grey.xbm`, both biases 0, and every scalar is clamped to 0..1. An instance that sets
`MetalnessScale` without a `Metalness` texture therefore multiplies zero and cooks as a
dielectric, whatever the palette says. Packs `71f872a21fa7` (rims) and `c774256c18e1`
(body kit) did exactly that, so their `chrome` read as matte light grey in game
(2026-11-05, `docs/research/vehicles-api.md`). The board-game props the cook copied are
not metals, so the gap never showed there.

The cook now writes the shape of CDPR's own chrome on this template,
`base\environment\decoration\furniture\restaurant\bar_a\textures\bar_a_chrome.mi`
(referenced by path, never copied): `BaseColor` and `Metalness` = `white.xbm`, a grey
`BaseColorScale` (0.643) and `RoughnessScale` 0.1. `Roughness` is written explicitly too.
The cook fails a material without both textures or with a bias, and `build-pack.ps1`
refuses palette values outside 0..1, so the gap cannot come back silently.

Palette guidance, now that metalness takes effect:

| Finish | Metalness | Roughness | Colour (linear) | Note |
|---|---|---|---|---|
| chrome | 1 | 0.10 | 0.66–0.69 | the vanilla chrome above |
| polished steel | 1 | 0.20 | ~0.72 | |
| satin aluminium | 1 | ~0.32 | ~0.76 | aluminium is bright; a dark colour reads as steel |
| bronze, gunmetal | 0.9–1 | 0.32–0.35 | the tint | |
| paint, carbon, plastic, rubber | **0** | to taste | the colour | a dielectric; metalness above 0 only darkens its reflection |

The owner-review renders (`render_preview.py`) feed the same palette values to Blender,
so they showed metal while the game did not. A preview is an art review, not game
evidence.

## Adding a part

1. Add an entry to the spec's `parts`:
   - `id` (`[a-z0-9_]`);
   - `kind` (`rim` or `spoiler`);
   - `params` (see the docstring at the top of `blender/make_rim.py` or
     `blender/make_spoiler.py`);
   - `finishes`, mapping each slot to a palette name.

   Rims have the slots `rim_main` and `rim_detail`; wings have `wing_main` and
   `wing_detail`.
2. Add palette entries if needed: `color` (linear RGB 0–1), `metalness`, `roughness`.
3. Rebuild, then look at `preview/<part>_<finish>_sheet.png`.

To add a new **kind**:

1. Write `blender/make_<kind>.py` on the same pattern. `vk_common.MeshBuilder` provides
   lathe and sweep, and `PartExporter` handles the naming and the `part.json` record.
   Keep one Blender object per (slot, LOD), named `submesh_NN_LOD_L`.
2. Register the script in `$Generators` at the top of `build-pack.ps1`.
3. If the kind exports more than one LOD, add its LOD table under
   `native.lodDistances` in the spec. One LOD needs nothing: the default is `[0]`.

The pivot is the attach point: build the part around the origin of the slot or root
it will be bound to.

Poly budget: one LOD by default. The rims are about 4.3k triangles, against 920 for the
vanilla rim, which also has a single LOD. The wing is 330. More LODs are possible
(`segments` / `sections` with one entry per LOD, plus `lodDistances`), but no
multi-LOD custom mesh has been seen in game yet.

## Using the pack from a server resource

The build writes the asset resource ready to copy into a server's resources folder:

```lua
-- open77.lua (asset resource)
resource 'open77_vehicle_kit_test'
version '0.1.0'
auto_start false
reload_policy 'reconnect'
client_script 'register.lua'
files { 'package.json' }
preload_mod 'dist/Open77VehicleKitTest_<rev12>.zip'
permissions { 'props.register' }
```

```lua
-- register.lua (client), abridged: every cooked model becomes asset:<resource>/<model>
for _, id in ipairs(ids) do          -- package.models keys, sorted
    local def = package.models[id]
    local called, alias, reason = pcall(Open77.props.registerModel, id, { mesh = def.mesh, visualEntity = def.visualEntity })
    if not (called and alias) then
        log(('skipped model %s: %s'):format(id, tostring(called and reason or alias)))
    end
end
```

`register.lua` never raises (decision D4). An error there fails the resource activation,
which disconnects the player. A model that cannot register is logged as
`[vehicle-kit] skipped model <id>: <reason>`, and the others still register. The summary
line is `[vehicle-kit] registered N of M models, skipped K, revision <rev12>`. A missing or
invalid `package.json` logs one line and registers nothing.
`prop_archive_missing_restart_required` means the game mounted an older archive than this
package: restart the game.

A gameplay resource declares `dependency 'open77_vehicle_kit_test'` and
`permissions { 'world.vehicles', 'world.vehicles.appearance' }`. It registers the parts
once at start (no permission needed for that) and then sets them per car on the server:

```lua
Open77.vehicles.registerParts({
    rim_vk1 = { kind = 'rim', label = 'VK-1 split five',
        variants = { chrome = 'asset:open77_vehicle_kit_test/rim_vk1_chrome' },
        fit = { ['Vehicle.v_standard2_archer_hella_player'] = {
            -- offset and scale come from measure-wheels.ps1 for this model
            hide = { 'wheel_01_bl_a', 'wheel_01_br_a', 'wheel_01_fl_a', 'wheel_01_fr_a' } } } },
    spoiler_vk1 = { kind = 'part', slot = 'trunk_body', label = 'VK-1 street wing',
        variants = { carbon = 'asset:open77_vehicle_kit_test/spoiler_vk1_carbon' },
        fit = { ['Vehicle.v_standard2_archer_hella_player'] = { offset = { 0, -0.2, 0.35 } } } },
})
local ok, reason = Open77.vehicles.setWheels(vehicleId, { rim = 'rim_vk1', variant = 'chrome' })
ok, reason = Open77.vehicles.setParts(vehicleId, { spoiler_vk1 = 'carbon' })
```

The server stores the choice in the car's `open77.visual` value, so it reaches late joiners
and survives `getProperties` / `setProperties`. The fit is measured per model:
`measure-wheels.ps1` writes the rim fits (see `docs/rims.md`), and the field rules are in
`wiki/vehicles.md`, "Kit parts, rim fits and trims". A record without a fit answers
`part_not_for_model`.

A new or changed archive takes effect only after a full game restart: `preload_mod` is
mounted at startup. A changed spec gets a new revision, so new depot paths and a new ZIP
name.

### E0.9 lab resource

`resource/<resource>_e09/` is generated next to the asset resource. Its commands are
restricted: grant `command.vkit.*` to the tester.

| Command | Effect |
|---|---|
| `/vkit.rim [model\|index] [slot\|all] [vehicleId] [mirror]` | Attaches a rim to the four `wheel_*` slots, or to one slot. It uses the car you sit in, else the lab car, else spawns `Vehicle.v_standard2_archer_hella_player` 6 m ahead. `mirror` turns the right-hand rims by 180°, for use if the right slots are not mirrored. |
| `/vkit.wing [model\|index] [vehicleId]` | Attaches a wing to the vehicle root at a first-guess trunk offset |
| `/vkit.move <propId> <ox> <oy> <oz> [rx ry rz]` | Re-poses one of your props in its slot frame (metres, degrees) |
| `/vkit.list` | Your props and their live bindings |
| `/vkit.clear` | Removes your props and the lab car |
| `/vkit.bones [vehicleId]` (client) | Lists the vehicle's named slots as this client sees them |

After `vkit.rim` or `vkit.wing`, the client also prints:

- the vehicle's slot list;
- each prop's `rendered` and `attachmentStatus`, on builds that have
  `Open77.props.projected`.

## Known limits

Status on 2026-11-06, from the campaign ledger. Every in-game statement below comes from
**one client**; a second client has not looked at kit parts yet.

- **Seen in game.** The first rim and body packs registered every model (24 of 24 and 16 of
  16, 2026-11-05); `scale` is honoured, a rim comes back after a stream-in, and hiding a
  stock component works (Colby). The 18 Light RP rims and the Hella's body parts were then
  checked frame by frame (2026-11-06, rims `f721d6538465`, body `ed9c4dea033d`): only the
  three front lips needed a new fit. Not seen yet: Hozuki, Semimaru, Maimai, Bandit, Quartz.
- **Rotation and steering follow the wheel** (E0.5, `7c080452`): a prop bound to `wheel_*`
  spins and steers with it, and `-x` points outboard on all four wheels.
- **The stock tyre stays.** The fit's `hide` list turns the stock rim components off; the
  tyre is the car's own, so the wheel diameter is unchanged.
- **A pack must be in the game folder.** A stale or missing archive shows as
  `prop_archive_missing_restart_required` on the server and `model_not_registered` on the
  client, and the car stays factory with no other symptom. A new pack revision needs a full
  game restart.
- **No collision and no physics,** by design (D5). The prop never touches handling. The
  wheel diameter is unchanged because the tyre is the car's own.
- **`objectType` is `ROT_Static`,** inherited from the template, while vanilla wheels
  use `ROT_Vehicle`. Expect no difference for a visual prop. Check shadows and motion
  blur in E0.9.
- **One mesh size, scaled per wheel.** A rim is built once; the fit scales it to each
  model's tyre (`scale = min(stock rim outer radius, bead + 1.5 mm) / 0.28`) and its
  per-wheel `wheels` entries size the back axle separately where it differs.
- **Part placement is per model.** The offset differs for every car and for some trims
  (`appearances` in the fit). Tune it with `vkit.move` in the lab and record it in the fit.
- **The materials are flat.** They are plain `metal_base.remt` instances on the engine's
  white texture: no brushed or carbon pattern and no decals. Colour, metalness and
  roughness are uniform per palette entry (see "Finishes: metalness").
- **Visibility.** Builds `ca3f8a77b1fb` and earlier drew only their shadows. Later
  builds remove every structural difference found against the board-game props, except
  the host root class (see "Visual host"), and their parts are seen in game. Which change
  made the difference is not known; see the research note.
- **Validator catalogue lag.** `open77_validate` against the published 2.50.0+op77.156
  catalogue reports `registerModel`, `props.register` and `props.projected` as unknown.
  They exist in the current source, and the Aetherfall asset resource uses the same
  pair. A server and client built from current `main` are needed.
- **The `description` manifest key is accepted but ignored,** so the generated
  manifests carry the description as a comment.
- **WolvenKit quirks the script works around:**
  - `convert serialize` and `deserialize` flatten folders, so the build deserializes
    one depot directory at a time and the cook enforces unique basenames;
  - `pack` names the archive after the folder, so the archive is renamed, and stamps
    every entry with the pack time, which `normalize-archive.cjs` pins;
  - only the first primitive of a multi-primitive node is kept, hence one Blender
    object per slot and LOD;
  - output folders must already exist;
  - the "Garment support is enabled…" warning on import is harmless.
- **Git Bash mangles backslashes** in WolvenKit regexes and depot paths. Run the
  scripts from PowerShell 7.

### Fallback: NCWE `import_model`

If a future WolvenKit release breaks import onto a template mesh, NCWE Studio can import
the same glb (`import_model`) into a project and export it as an Open77 world resource.
That path gives a static world mesh, not a registered prop model. So it covers display
tests only, and attaching to a vehicle still needs the props pipeline above.
