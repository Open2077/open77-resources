# Plate pack, route W (vehicle customization E4)

A production ArchiveXL pack that lets the server put a text on the plate of the 15 Light RP
dealer models, of the staff-only Rayfield Caliburn and of every other vanilla player vehicle
(`Vehicle.*_player*`, cars and motorcycles; 86 models since 2026-11-07), plus the client script that sets the text.
Quest variants (`Vehicle.q<digits>_*`) are out of the customization extension by the owner's
decision of 2026-11-07 and are not models of the spec. Traffic and unowned cars keep the
factory look: every component this pack adds is authored **disabled**. The client turns them
on only when a plate text is set.

**No vanilla data is copied.** The pack holds:
- one patch `.app` per vanilla appearance resource. Its definitions carry the names of
  vanilla definitions and nothing else of them;
- in each definition, only our own components;
- optionally our own `.inkwidget`.

Vanilla resources (the plate mesh, a screen quad mesh, a widget, two fonts) are referenced by
depot path. Proof: see "No vanilla bytes" below.

| Path | What it is |
|---|---|
| `specs/plates.json` | Models, appearance resources, plate meshes, placement rules, designs, component names |
| `player-models.py` | Rewrites the spec's generated models (`"generated": "player-models.py"`): one per vanilla player record the 16 hand-written entries do not name, from `docs/generated/vehicle-components-player-2.50.json`; skips quest variants |
| `native/geometry.cjs` | Quaternions, rigid transforms, glb reader, ray/mesh test |
| `native/plates.cjs` | `survey`, `generate`, `validate` (round trip), `scan` (no vanilla bytes), `data` (committed table), `views` (preview renders) |
| `native/cover.cjs` | Plate measurement, the cover rule, the ray-cast print-leak proof, the offline view renderer |
| `native/png.cjs` | Minimal PNG reader and writer for the view renderer |
| `tests/scan-rule.test.cjs` | `node --test`: the scan's handle-index exception (`native/scan-rule.cjs`) |
| `native/scan-rule.cjs` | The scan's one exception for a shared binary block: a handle-index run of two `.app` files (see "No vanilla bytes"); tests in `tests/scan-rule.test.cjs` |
| `native/inkwidget.cjs` | Our `.inkwidget` (design `original`), written from scratch: one item per plate mesh |
| `build-plates.ps1` | The whole pipeline, one command |
| `preview-plates.ps1` | Preview PNGs for the owner and the lead: the items in 2D, and before/after renders of every plate mesh |
| `data/plates-dealer-2.50.json`, `.md` | Per-model plate data, generated with `-UpdateData` |
| `lab/` | **LAB ONLY**: the trigger REDscript and the lab resource's server script |
| `../../../client/redscript/Open77VehiclePlate.reds` | Production client script (ships with the client) |

## Build

```powershell
pwsh -File scripts/vehicle-kit/plates/build-plates.ps1                       # design original (the only one left)
pwsh -File scripts/vehicle-kit/plates/build-plates.ps1 -UpdateData           # also rewrites data/plates-dealer-2.50.*
pwsh -File scripts/vehicle-kit/plates/preview-plates.ps1                     # needs the build above
pwsh -File scripts/vehicle-kit/plates/preview-plates.ps1 -InGameShot <shot.png> -InGameRect 440,615,300,150
```

The build needs:
- the game folder (`-GameDirectory`, or `OP77_GAME_DIR` from the process scope, then the user scope). It is only read;
- WolvenKit CLI 8.20 (`scripts/find-wolvenkit.ps1`);
- Node.js 18 or later.

Outputs go to the git-ignored `artifacts/vehicle-kit-plates/`:
- `vanilla/`, `vanilla-json/`, `glb/`: cached game files, never shipped;
- `<design>/work/`: generated JSON, staged files, round trip, packed archive;
- `<design>/resource/open77_vehicle_plates/`: lab resource with `dist/<zip>`;
- `<design>/manifest.json` and `SHA256SUMS`;
- `lab-install/`: the trigger to drop under `r6/scripts/Open77Lab/`.

Same inputs give the same revision, and so byte-identical archives and ZIPs. The revision
hashes the spec, `native/*.cjs`, this script, H's normalizer, the WolvenKit version, and
every vanilla file and glb read. Depot prefix: `open77\assets\open77_vehicle_plates\<rev12>\`.

**Install one plate pack at a time**, and remove any earlier revision's ZIP first: every
revision patches the same vanilla definitions with the same component names.

## How the pack adds components (ArchiveXL `ResourcePatch`)

Clients need an official ArchiveXL 1.28.0 or later, the first stable release for game 2.5; the Open77
fork is not needed. The line numbers below were read in the fork `Open2077/archive-xl`, branch
`open77/1.28`, commit ef0e474, whose `ResourcePatch` source is identical to upstream 1.28.0 and
unchanged up to 1.28.6 (the fork only changes world streaming). The plate was seen in game with
the fork installed; an official release has not been tried yet.

`src/App/Extensions/ResourcePatch/Extension.cpp`:

- Lines 26-27: the prop names are `appearances` and `components`.
- `OnAppearanceResourceLoad` (347-497) walks each definition of the patch `.app` (368).
  - A definition **named** like a vanilla definition is not added (372-390: `isNewAppearance = false`).
  - `PrefetchAppearance` (374-377, 1476-1489) keeps it by name, but only when `components` is in props.
  - Only a name that matches nothing is appended as a new appearance (489-496). The `validate` step therefore fails any patch definition whose name is not in the target.
  - Parts values, parts overrides, dependencies and visual tags are merged only when their own prop is listed (398, 429, 442, 473). We list none of them.
- At entity build time, `OnEntityPackageLoad` (60, 740-830) calls `PatchPackageResults(AppearanceResource, ...)` (1148-1200).
  - That function looks the definition up by name (`GetAppearanceDefinition`, 1168 and 1492-1505).
  - It extracts our compiled package and calls `MergeComponents` (1195). This appends our components to the vanilla ones.
- `Modifies` (1383-1386) is `props.empty() || props.contains(prop)`. So `props: [ appearances, components ]` is required: an empty list would mean "everything".

The `.xl` therefore holds one entry per vanilla `.app`:

```yaml
resource:
  patch:
    open77\assets\open77_vehicle_plates\<rev12>\thorton_galena__basic.app:
      props: [ appearances, components ]
      targets:
        - base\vehicles\appearances\standard\thorton_galena__basic.app
```

Coverage, build of 2026-11-07 (revision `d4412f3b864f`, 86 models: 1043 definitions in 48
`.app` files, 31 of them new with the other player vehicles):

| Status | Definitions | What gets added |
|---|---|---|
| `plate` | 776 | screen + text on the rear plate (and on the front plate where there is one: 300 definitions) |
| `mount` | 36 | a mounted `license_plate.mesh` on the rear bumper, then screen + text on it |
| `front-only` | 0 | screen + text on the front plate |
| `none` | 139 | nothing: 131 on bodies with no plate in any definition of their `.app` (no rear plate, no sibling placement: the Nomad, Kurtz and NCU builds, Hellhound, Mackinaw BMF and Saguaro...), 4 Columbus jammer/rescue vans, 3 where the donor's bumper slot is empty (Quadra Sport R7 `player_02`...), 1 Type-66 `sampson` (donor plate misses its bumper, 1/9 and 3/9 rays) |
| `excluded` | 92 | nothing: burnt, destroyed, damaged, no wheels |

812 patched definitions, 2260 components. Per model, on the appearance a spawned car wears:
61 `plate` (46 cars, all 15 motorcycles), 5 `mount`, 20 `none`; the 20 are listed in
`data/plates-dealer-2.50.md` with their reason. Leaving the two quest variants out changes no
`.app` of the pack: they wear the Hella's and the Cortes' appearance resources, which the
dealer models already patch whole.

Coverage, build of 2026-11-06 (465 definitions in 17 `.app` files; the Caliburn's adds 13):

| Status | Definitions | What gets added |
|---|---|---|
| `plate` | 382 | screen + text on the rear plate (and on the front plate where there is one) |
| `mount` | 36 | a mounted `license_plate.mesh` on the rear bumper, then screen + text on it |
| `front-only` | 0 | screen + text on the front plate |
| `none` | 5 | nothing: 4 Columbus jammer/rescue vans (the donor plate misses their bumper, 0/9 rays) and `q_104_jammer_holo` (no rear bumper) |
| `excluded` | 42 | nothing: burnt, destroyed, damaged, no wheels |

418 patched definitions, 1230 components. Every `player_01` (or the model's player entry)
and every curated trim is patched; the per-model table is `data/plates-dealer-2.50.md`.

- every non-excluded definition of the 17 `.app` files of the spec is patched, as long as it has a rear plate or a mount can be placed. That includes `player_01` and every curated Light RP trim (see the data table);
- definitions matching `burnt|destroyed|damage|no_wheels` are left alone;
- appearances that another pack adds as new definitions (route B, a new `.app`) are **not** covered. Such a pack must add the plate components itself, or be listed as a target here.

## Components (the client contract)

| Name | Type | Bound to | Role |
|---|---|---|---|
| `open77_plate_screen` | `entMeshComponent` | the rear plate component (or the mount) | `television_neokitsch_21x9_screen_a.mesh`, appearance `interactive_screen` (`screen_ui.mi`), scaled to cover the plate's holo layer (cover rule below), 3 mm in front of the holo |
| `open77_plate_text` | `WorldWidgetComponent` | the screen quad (`meshTargetBinding` + hard binding) | draws the item of our `.inkwidget` made for that plate mesh (`itemNameToSpawn`: `Car`, `Moto`, `MotoTilt` or `MotoWide`) |
| `open77_plate_mount` | `entMeshComponent` | the definition's own rear bumper | the vanilla `license_plate.mesh`, only for factory definitions without a rear plate, with its holo chunk masked out (`chunkMask` `9223372036854775805`, bit 1 cleared) |
| `..._f` | same | the front plate | front pair, where the definition has a front plate |

All of them have `isEnabled = 0`. Component ids are FNV-1a-64 of
`open77:plates:<app leaf>:<definition>:<name>`, which is stable and our own.

### Quad placement: the cover rule (revision e52bbedf19fa, 2026-11-05)

**The defect it fixes.** The first rule fitted the quad *inside* the holo rectangle at the
design aspect (3.3 for cars, 1.11 for bikes), 11 to 23 mm in front of the holo. The holo
layer (chunk `holoChunk` of the plate mesh, material `parallaxscreen.mt`) is the part that
carries the factory print. On `license_plate.mesh` (holo 321.7 x 119.7 mm), a 3.3 quad
leaves 11.2 mm of print above and below it seen square on, and more from any other angle.
The lead saw it in game on 2026-11-05: Archer Hella `player_01`, mount route, the `NC77…`
print above our plate. The ray cast below reproduces that band.

**The rule** (`native/cover.cjs`, numbers in `specs/plates.json` `placement`):
1. The holo layer of each plate mesh is measured from the decoded glb: chunk, rectangle, depth range, and reading frame from the UVs. A bent holo (`license_plate_angle_01.mesh`) is measured on its chord.
2. The quad lies 3 mm in front of the holo's outermost point (`proudMetres`).
3. A visible plate surface pushes the quad out in front of it only when it is within 1.5 mm of the quad plane and within 25 deg of parallel to it (`clearanceMetres`, `parallelDegrees`). Revision `e52bbedf19fa` needed no push on any mesh.
4. The quad covers the holo rectangle grown on **every side** by `gap x tan 60 deg + 1 mm`, where gap is the distance from the quad to the deepest holo point. So no ray that leaves the holo within 60 deg of the plate normal can pass beside the quad.
5. The widget item for that mesh is authored at the quad's own aspect. The design (yellow band, region label, text, border) is drawn inside the holo rectangle. The margin around it is the plate background colour. Nothing is stretched.
6. On a mount, which is our own component, the plate's holo chunk is masked out of `chunkMask`: there is no print left to show. Vanilla does the same to whole plates on its burnt definitions (`chunkMask` 0).

Results, revision `e52bbedf19fa`, unchanged in `bade669de13c` (also in `data/plates-dealer-2.50.md`):

| Plate mesh | Holo w x h (mm) | Quad before (mm) | Print uncovered before, t / b / l / r (mm) | Quad after (mm) | Margin / gap (mm) | Item (px) |
|---|---|---|---|---|---|---|
| `license_plate.mesh` (cars, mounts) | 321.7 x 119.7 | 321.7 x 97.5 | 11.2 / 11.2 / 0 / 0 | 337.5 x 135.7 | 7.9 / 4.0 | `Car` 995 x 400 |
| `license_plate_small.mesh` (Apollo basic, Kusanagi) | 120.0 x 108.4 | 120.0 x 108.1 | 0.1 / 0.1 / 0 / 0 | 138.6 x 127.0 | 9.3 / 4.8 | `Moto` 437 x 400 |
| `license_plate_angle_01.mesh` (Apollo police, player_02; bent) | 120.0 x 76.1 | 84.5 x 76.1 | 0.1 / 0.1 / 17.8 / 17.8 | 148.3 x 104.5 | 14.2 / 7.6 | `MotoTilt` 568 x 400 |
| `motorcycle_license_plate.mesh` (Kusanagi player_02/03) | 193.0 x 118.8 | 131.9 x 118.8 | 0 / 0 / 30.6 / 30.6 | 205.4 x 131.2 | 6.2 / 3.0 | `MotoWide` 626 x 400 |

After: the quad overlaps every holo edge by the margin, seen square on (uncovered = minus the margin on every side).

**The proof**, run by every build: a ray is cast from every holo sample (one per 2 mm², on
both faces) towards the viewer. Print is seen when the ray misses both the plate body and the
quad. Decals, stickers and the car are not counted as hiding anything, so the test is
pessimistic.
- Cone: 24 azimuths at 10, 20, ..., 60 deg off the normal, 144 views. Before: 144 of 144 views show print, on every mesh. After: 0 of 144 on every mesh. **The build fails on any print seen within the cone.**
- Leaning: the widest band of visible print with the viewer leaning 0 to 80 deg towards one side.
  - Before, car top band: 11 mm square on, 17.7 at 30 deg, 31.2 at 60 deg.
  - After: 0 on every side of every mesh up to 60 deg.
  - Past 60 deg, a band of 1.8 to 6.3 mm shows at 70 deg: a grazing view along the plate. Inference, not measured: the bumper around the plate hides most of it on a car.
- Renders: `preview-plates.ps1` ray-traces each mesh from six directions, before and after, with print pixels counted. Revision `e52bbedf19fa`: 253 832 print pixels before, 0 after.

Alternatives weighed:
- **A print-free vanilla plate appearance for the mounts: impossible.** Every appearance of `license_plate.mesh` (`default`, `socal_plate`, `rogue_custom`) puts a printed material on the holo chunk. It would not help the 370 `plate` definitions either, whose plate is the factory component and cannot be changed without a vanilla component override. Masking the holo chunk of our own mount gives the same result with no new resource.
- **Masking the holo chunk of the factory plate** on the `plate` route would need the patch to modify a vanilla component. The pack only appends components, by design (see "How the pack adds components"). And a traffic car without a plate text would then lose its factory print.
- **Cover with a letterboxed widget** (kept): one rule for both routes and every mesh, no change to the client contract, and proven offline per mesh.

Mounts:
- the placement of a sibling definition's rear plate on the same slot is cast onto this definition's own rear-bumper mesh (9 rays along the plate normal);
- the plate goes 2 mm in front of the rearmost hit;
- a mount is refused if fewer than 6 rays hit, if the centre ray misses, or if the shift exceeds 25 cm. That definition then stays plate-less, and the script returns 3.

A definition with a front plate but no rear plate and no possible mount gets the front pair
only (status `front-only`). No definition of the 16 current files is in that case; the status
exists so that a future file does not silently lose its front plate.

## Vanilla toggles our widget: who disables it at spawn

Found offline by reading the bytecode of the vanilla `r6/cache/final.redscripts` (game 2.50).
The definitions and callers were located by scanning the bundle's definition table.

- `VehicleObject.SetInteriorUIEnabled(enabled: Bool)` is `private final`. It calls the native `VehicleObject.GetUIComponents()` and runs `IComponent.Toggle(enabled)` on every component returned. Then it sets `VehicleDef.IsUIActive` on the vehicle blackboard.
- Its callers:
  - `VehicleObject.OnGameAttached` calls it with `false`, unconditionally: every spawn, stream-in and garage retrieval.
  - `VehicleObject.OnMountingEvent` calls it with `true`; `VehicleObject.OnUnmountingEvent` calls it with `false`.
  - `VehicleObject.TempDisableUI(delay)` calls it with `false`, then queues `DelayEnableInteriorUIEvent`, whose handler calls it with `true`. This happens even when nobody is in the car.
  - `TempDisableUI(0.6)` is called by `VehicleComponent.ApplyVehicleVisualCustomizationTemplate` and by `VehicleComponent.DisableCurrentCustomization`, so on every paint.
- `GetUIComponents()` evidently includes our `WorldWidgetComponent`. The lead measured it in game on 2026-11-05: on the create path, the text widget came up disabled while the screen quad (a mesh component) stayed enabled. The native function body itself was not read (inference, consistent with the measurement).

What `client/redscript/Open77VehiclePlate.reds` does about it:
- `Open77ApplyPlateText` toggles the quad and the widget on itself, and returns 0 until the widget's ink tree exists;
- a `@wrapMethod` of `SetInteriorUIEnabled` runs after every vanilla toggle:
  - when a plate text is set, it switches our widget back on and pushes the stored text again (DelaySystem retries, never blocking), because a re-enabled widget is a new ink tree with the library's default text;
  - when no text is set, it switches our widget back off, so mounting a traffic car never spawns a hidden plate widget.

This also settles the "disabled vs enabled widget" question of the brief:
- an "enabled widget" variant would be disabled by `OnGameAttached` anyway;
- the lead measured that a disabled widget, toggled on, spawns at once and renders.

So only the disabled variant is built.

## Client script contract

`VehicleComponent.Open77ApplyPlateText(text: String) -> Int32`:

| Result | Meaning |
|---|---|
| `1` | Text written. An empty text clears the plate and also returns 1. Texts are cut to 16 characters. |
| `0` | Not ready: the vehicle is not attached, or the widget has not spawned yet. Retry, as for paint. |
| `2` | The widget has no text field (pack and script disagree). Give up. |
| `3` | This appearance carries no plate components. Give up: model or trim without a plate. |

`VehicleComponent.Open77ClearPlateText() -> Bool`:
- `true` when the car is back to factory, or never had plate components;
- `false` while the vehicle is detached.

`VehicleComponent.Open77PlateDebugState() -> String` gives a lab and diagnostics readout.

Both main calls are idempotent and cheap, so they can be called on every reconciliation. An
appearance change rebuilds components as authored (disabled): the caller must apply again
after it (E0.4). Rules kept:
- nothing blocks the game thread;
- no `Open77.rtti`;
- no globals, only three fields on the vehicle.

## Designs

| Design | Widget | Text field | Fonts | Status |
|---|---|---|---|---|
| `original` | ours, `open77_plate.inkwidget`, built from scratch | `PlateText` | Orbitron Bold + Rajdhani Bold (OFL, the game's copies by depot path) | the only design built. The fit-rule revision `4e33176c00be` was seen in game (Hella, with the print band); the cover revisions `e52bbedf19fa` and `bade669de13c` (adds the Caliburn) are **not seen in game yet** |
| `sign` | vanilla `generic_street_name_sign.inkwidget` | `StreetNameContainer/StreetName` | Blender Pro (the game's) | **retired** (`retiredDesigns` in the spec): a vanilla widget has one fixed aspect, 3.3, and cannot be letterboxed. The cover quads run from 2.49 (car) down to 1.09 (small bike plate), so it would be stretched 1.3x to 3x. An opaque backing quad would need one more component for the client to toggle, a change to the client contract. It proved route W in game (H, E0.7, Galena) |
| `lcd` | vanilla `lcdscreen_10x1.inkwidget` | `default_ui/messege_text` | the widget's own | **retired**, same reason at aspect 10; never measured in game |

`build-plates.ps1 -Design` accepts only `original`. `plates.cjs generate` refuses a retired
design and any placement rule other than `cover`.

The library has one item per plate mesh, each authored at the aspect of that mesh's quad
(`plateMeshes.item` in the spec, layouts in `inkwidget.cjs` `layoutFor`):

| Item | Plate mesh | Size (px) | Design face inside it (px) | Style |
|---|---|---|---|---|
| `Car` | `license_plate.mesh` | 995 x 400 | 948 x 353 at 23,23 | car: `NIGHT CITY` band |
| `Moto` | `license_plate_small.mesh` | 437 x 400 | 378 x 341 at 29,29 | bike: `NC` band |
| `MotoTilt` | `license_plate_angle_01.mesh` | 568 x 400 | 459 x 292 at 54,54 | bike |
| `MotoWide` | `motorcycle_license_plate.mesh` | 626 x 400 | 588 x 362 at 19,19 | bike |

The face is the holo rectangle mapped onto the item. The background rectangle fills the
whole item; band, region label, borders and `PlateText` stay inside the face. The superseded
fit-rule items (`Car` 990 x 300, `Moto` 600 x 540, the face being the whole item) are drawn
by the previews only, for the before row.

An original `.inkwidget` is feasible offline:
- the library is plain data;
- each item is made of rectangles and two text widgets, with no logic controller, style or animation;
- it is written as both the embedded CR2W package and the compiled package data, as vanilla libraries are;
- WolvenKit deserializes and re-serializes it, and `validate` checks the round trip, the item names, and each item's size against its layout.

Region label and colours are placeholders for the owner.

## No vanilla bytes

Four checks run in the build; any failure stops it.

1. **Structural.** The round trip `validate` accepts only:
   - our component names;
   - an allow-listed set of RED4 types;
   - resource paths from a fixed list (screen mesh, plate meshes, the design widget, the fonts);
   - definition names that exist in the target `.app`;
   - empty parts, dependencies, tags and proxy.

   The original `.inkwidget` may reference only the two font families, and no controller.
2. **Hashes.** No staged file, archive entry or ZIP entry equals any vanilla file the build read.
3. **Block scan.** Every 64-byte block of every vanilla file read (52 files) is looked up among all 64-byte windows of our cooked files. Blocks of a single repeated byte are skipped. A shared block is then sorted:
   - **names**: only printable ASCII and NUL. These are RED4 type and field names, and the vanilla definition names that a patch must carry to be matched. Reported in `scan.json`, allowed;
   - **index runs**: the block's 32-bit words (little- or big-endian, any alignment) count up by a constant step, such as `1b 1c 1d ...`. These are CR2W index tables, which any two files of similar size share. Reported, allowed;
   - **handle-index runs** (2026-11-07, `native/scan-rule.cjs`): a block of two `.app` files that, in **both** files, lies inside one `array:handle:*` property (found by walking the CR2W export table and the property headers, nested structs included, from the property's size field to the end of its value), holds at most two leading header words (that property's size and element count, where the structure puts them), and then only one run of 32-bit words each exactly 1 more than the previous, every one a valid chunk reference of that file (1 to its export count). Reported in `scan.json` (`handleIndexRuns`), allowed. Any other file type, a third header word, a gap in the run, or a block outside a handle array still fails;
   - **anything else** fails the build.

   Why a handle-index run is not game content: CR2W writes an `array:handle:<class>` property as its size (counting itself), its element count, then one word per element, the 1-based index of the chunk it points to. A file whose chunks are written in order holds `2, 3, 4 ...` there, so two unrelated `.app` files that each keep 33 objects in chunks 2 to 34 share `8c 00 00 00 21 00 00 00 02 00 00 00 ...` byte for byte, whatever the objects are. The case that added the rule (2026-11-07, the build that extended the pack to every player vehicle): our `quadra_sport_r7_basic.app` patch at offset 2786 is its root `appearances` list (33 appearance definitions in chunks 2 to 34); the vanilla `chevalier_emperor__basic.app` at offset 5696 is its `DismWoundConfig.Configs` list (33 dismemberment wound containers in chunks 2 to 34). Same layout, unrelated contents. The earlier index-run rule did not take it because the size and count words break the constant step. `node --test scripts/vehicle-kit/plates/tests/scan-rule.test.cjs` checks the conditions on synthetic CR2W files, and with `OP77_PLATES_SCAN_DIR=<-OutDir of a build>` the real block (passes) and 64-byte blocks of the vanilla file's buffers (fail).

   Revision `d4412f3b864f` (38 files, 985 695 bytes, 117 vanilla files): 0 content blocks, 94 name blocks (106 names), 42 index runs, 1 handle-index run (the 2026-11-07 case below). Revision `bade669de13c` (18 files, 522 389 bytes): 0 content blocks, 34 name blocks (49 names), 19 index runs. Revision `e52bbedf19fa` (17 files, 508 399 bytes): 0 content blocks, 32 name blocks (47 names), 19 index runs. The earlier revisions had 0 content blocks too.
4. **Archive and ZIP.** The packed archive is extracted again and each file is compared byte for byte with the staged one. The hashes of the archive entries and of the ZIP entries are checked against every vanilla file hash.

WolvenKit has no name for our own `.inkwidget`, so the round trip gives its path back as a
hash. `validate` compares it as FNV-1a 64 of the depot path, which is what the game looks up.
Any other hashed path must be the hash of an allow-listed path.

## Outputs

| Design | Revision | Rule | Archive SHA-256 | ZIP | ZIP SHA-256 |
|---|---|---|---|---|---|
| `original` | `d4412f3b864f` (2026-11-07, current: every vanilla player vehicle but the quest variants; built with `-OutDir` outside the checkout) | cover | `fb34d11163c5...e2eb06fa17a` | `<OutDir>/original/resource/open77_vehicle_plates/dist/open77_vehicle_plates_original_d4412f3b864f.zip` (606 309 bytes) | `8a65b0436a08...e6b01017374` |
| `original` | `bade669de13c` (2026-11-06, superseded: adds the Caliburn) | cover | `0cecbdb68a25...d20451224` | `artifacts/vehicle-kit-plates/original/resource/open77_vehicle_plates/dist/open77_vehicle_plates_original_bade669de13c.zip` (313 KB) | `e71f85dc7d5a...e14be9a51` |
| `original` | `e52bbedf19fa` (2026-11-05, superseded) | cover | `7a2eebb62d78...e1e00cee2` | `artifacts/vehicle-kit-plates/original/resource/open77_vehicle_plates/dist/open77_vehicle_plates_original_e52bbedf19fa.zip` (314 KB) | `5d6e992003b7...cb932656d6` |
| `original` | `4e33176c00be` (2026-11-05, superseded) | fit | `7e8e357cc010...c2221457` | `..._original_4e33176c00be.zip` | |
| `sign` | `61a24339a4d4` (2026-11-05, retired) | fit | `38e82e7083fc...65c7517f8` | `..._sign_61a24339a4d4.zip` | |

The full hashes are in the design's `manifest.json` (with a `cover` block: per mesh, quad,
margin, gap, cone result, mount `chunkMask`, and the before values) and `SHA256SUMS`. A
change to any `native/*.cjs`, the spec or the script changes the revision.

Previews, in `artifacts/vehicle-kit-plates/previews/`:
- `cover-<plate mesh>.png`: one sheet per mesh, six views (front, 30 and 60 deg above, 45 deg below, 60 deg left and right). Three rows: before (fit rule), after on the plate route, after on the mount route (holo masked). The factory print is hatched magenta, and each view gives its print-pixel count;
- `views/`: the single renders, and `views.json` with the counts;
- `items/<item>.png`, `items/legacy-<item>.png`: the library items, 2D, game fonts;
- `original-sheet.png`, `original-<item>-<text>.png`: the original design with sample texts;
- `ingame-crop.png` (with `-InGameShot`): a crop of a real in-game shot, for comparison. The lead's shot of 2026-11-05 shows the print band of revision `4e33176c00be`.

These renders are offline ray traces, not game renders. The screen material, the lighting
and the car around the plate are not reproduced.

## Lab procedure (for the lead)

LAB ONLY. Never on a public server. Test clients and the lab server only.

Files:
1. **Client script** (production): `client/redscript/Open77VehiclePlate.reds` ships with the client. For a lab before it is in a release, copy it to `r6/scripts/Open77/` on each test client, next to the other Open77 scripts.
2. **Lab trigger**: `artifacts/vehicle-kit-plates/lab-install/r6/scripts/Open77Lab/Open77VehiclePlateLab.reds` goes under `<game>/r6/scripts/Open77Lab/` on each test client. Remove it after the session.
3. **Lab resource**: `artifacts/vehicle-kit-plates/original/resource/open77_vehicle_plates/`, with its `dist/*.zip` as `preload_mod`, goes into the lab server's resources.
   - Start it by hand: `auto_start false`.
   - Grant the lab account `command.vpl.<name>`.
   - Only one revision at a time: remove the ZIP of an earlier revision (`..._original_bade669de13c.zip`, `..._original_e52bbedf19fa.zip`, `..._original_4e33176c00be.zip`, `..._sign_61a24339a4d4.zip`) from the resource and from the clients' preload cache.
4. Uninstall H's E0.7 pack first (`open77_vehicle_plate_test`). Its added Galena appearances would not conflict, but its trigger shares the paint channel; ours uses `#040507`.

Commands (server side, `lab/plates_server.lua`):

| Command | Effect |
|---|---|
| `/vpl.car <model\|all> [front] [page]` | spawns the model's player entry 8 m ahead, facing away (rear plates); `all` spawns 16 models in a row, page 1 (the dealer models and the Caliburn) by default and page 2 to 6 for the other player vehicles in spec order; `front` turns them towards you |
| `/vpl.trims <model> [front]` | the model's curated trims in a row |
| `/vpl.text <id\|.\|all> <3 chars>` | plate `OP77-<chars>` through the magic paint (every viewer gets it) |
| `/vpl.clear <id\|.\|all>` | back to factory |
| `/vpl.state <id\|.\|all>` | each client logs `vplate77 state ...` |
| `/vpl.paint <id\|.> <#rrggbb>` | a real paint: vanilla `TempDisableUI` runs, and the plate must survive it |
| `/vpl.app <id\|.> <entry>` | appearance change: the plate disappears until `/vpl.text` again |
| `/vpl.remove` | removes your lab cars |

Client log lines (via `Open77PlayerResetTrace`):
- `vplate77 request ...`;
- `vplate77 apply ... result=<1|0|2|3> tries=<n> state=...`;
- `vplate77 readback ...` at 1 s and 6 s.

Steps and what each should look like:
1. `/vpl.car all` with no text. All 16 must look factory. Plate-less trims show no plate, with no visible quad and no floating panel.
2. `/vpl.text all ABC`. Every car shows `OP77-ABC` on its rear plate, and on the front plate where one exists (see the table).
   - Galena player_01: the plate on the left of the junk bumper, where H's test showed it.
   - Bikes: a small plate on the rear (Apollo: on the body; Kusanagi: on the body, the seat for the animal trims, or the tilted `motorcycle_license_plate` on player_02/03).
   - Every `apply` line should end at `result=1` after a few tries.
   - **No factory print around our plate** (cover rule): walk around each plate and look from above, below and both sides, down to about 30 deg off the plate. No `NC77…` print, no magenta/white holo strip, on any side. Mounts (Archer Hella `player_01`, the 2026-11-05 defect) show no holo at all, only our plate under the plate's top bar.
   - The text reads square, not stretched, on the four items: `Car` on cars and mounts, `Moto` on Apollo basic and Kusanagi, `MotoTilt` on Apollo police and `player_02`, `MotoWide` on Kusanagi `player_02`/`player_03`.
   - The quad's dark margin (7.9 mm on cars) hangs below the holo's bottom edge, and is about flush with the top bar's width. On bikes the quad sticks out past the bar sides: small plate 2.8 / 0.7 mm, angle plate 7.7 / 5.5 mm (left / right). The `motorcycle_license_plate` frame stays in front of the quad's margin. Judge whether that looks acceptable.
3. Enter a car, then leave it. The text must stay on (the wrap re-enables after `OnUnmountingEvent`). Check `/vpl.state` after each.
4. `/vpl.paint . #3050a0`. The paint changes, and the text survives `TempDisableUI` (gone at most a second, then back).
5. Drive 150 m away and come back. Is the text still there, or did the widget respawn with the default text? See the risks.
6. `/vpl.trims <model>`, then `/vpl.text all XYZ`. Each curated trim shows the plate, except where the table says `none`, which returns `result=3`.
7. `/vpl.clear all`. Back to factory.
8. Two clients: a late joiner sees the same text (paint replicates).

## Risks and what must be checked in game

- **Widget respawn at range**: with `limitedSpawnDistanceFromVehicle = 0` and no spawn distance override, the world UI system may despawn the widget at range. On respawn it shows the library's default text: empty for `original`, "Example street name" for `sign`.
  - The vanilla-toggle wrap does not see that.
  - If step 5 fails, the caller must re-apply on a slow cadence (`Open77ApplyPlateText` is cheap and idempotent), or a later revision adds a game controller to our `.inkwidget`.
- **LOD and proxy**: the quad and the mount are ordinary mesh components with `LODMode Appearance`. The vehicle's proxy mesh (far LOD) is the vanilla proxy, so no plate text at a distance. Expected and acceptable.
- **Bumper damage and detach**: our components are bound to the plate component, or for a mount to the rear bumper, so they follow it when it detaches. A destroyed car switches to a `burnt`/`destroyed` definition, which we do not patch.
- **Appearance change** rebuilds the components disabled: the C++ caller re-applies (E0.4).
- **Shared paint channel in the lab only**: the lab text rides on the paint, so a lab car keeps its previous paint. Production uses the plate field of the visual contract.
- **Vanilla customization tint**: `VehicleObject.GetCustomizationWidgets()` also returns `GetUIComponents()`. No script calls it, so its user is native. If the native paint feature tints those widgets, our plate text may take the car's paint colour. Check in step 4.
- **Front plates**: they are rotated 180° about Z in their slot. The quad maps the plate's own reading frame, so the text should read correctly from the front. Not seen in game.
- **Another pack's new appearances** are not covered (see Coverage).
- **More cars on the plate path (2026-11-07).** The pack now patches 812 definitions in 48 `.app` files instead of 418 in 17. Traffic of those bodies spawns with our components disabled, as before; but every player vehicle whose appearance is covered can now have a Light RP plate written, so more cars run the client's write path. The open "plate not written after 80 tries (`entity_not_attached`)" warning and the "plate widget stuck" rebuild are therefore likely to be seen more often, on more models (inference: the data adds exposure, not a new path; widget size and behaviour unchanged, 995 x 400 for `Car`). Whether a disabled `WorldWidgetComponent` on a traffic car allocates its widget window at all is not known (hypothesis to check against the `+0x289E49` crash).
- **The new player vehicles are offline data only**: covers, mounts and widget items are the same four meshes and items as before, but no new model was seen in game.
- **Mount `chunkMask`**: the mount hides its holo chunk with `chunkMask` `9223372036854775805` (all chunks but bit 1). That the engine honours a partial mask on an added mesh component is an inference from vanilla's use of `chunkMask` 0 on burnt definitions, not measured in game. If the holo still shows on a mount, the cover quad still hides it within 60 deg: same proof as the `plate` route.
- **Depth separation**: the quad is 3 to 3.9 mm in front of the holo's outermost point (the first rule used 11 to 23 mm). Check at 30 to 50 m that the print does not flicker through the quad. If it does, raise `proudMetres`: the margin grows with the gap (`gap x tan 60 deg + 1 mm`), so the proof still holds.
- **Grazing views**: past 60 deg off the plate normal, a print band of 1.8 to 6.3 mm can show at 70 deg, and 10 to 24 mm at 80 deg (table above). The cover is not meant to hold there.
- **The renders** are offline ray traces of the plate meshes alone, without the screen material, the lighting or the car. The decals and stickers chunks are drawn in a darker grey. The leak test never counts them as hiding the print.
- **What sits in front of the quad**: only the plate's top bar and its stickers, over the quad's top margin (cars: 60.5 to 67.3 mm above the holo centre, the holo top being 59.9). On the bent `license_plate_angle_01`, the bar reaches 1.4 mm below the holo top. No plate geometry lies in front of the design face anywhere else; `motorcycle_license_plate` has none at all.
