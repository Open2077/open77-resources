# ArchiveXL lab packs: vehicle appearances (E0.6) and plate text, route W (E0.7)

Two offline-built lab packs for the vehicle-customization campaign. Each one is an
ArchiveXL mod (`.archive` + `.archive.xl`) packaged as a `preload_mod` ZIP, plus a lab
resource with restricted commands. E0.7 also ships a lab REDscript that is installed by
hand. Both ran in game on one client on 2026-11-05 (`c1ade18e`), with the Open77 fork of
ArchiveXL installed: E0.6 static entries and `AppearanceParts` work at creation, on a change and
after a rebuild; E0.7 wrote `OP77-ABC` on the Galena's rear plate. The lead runs them.

**LAB ONLY.** The specs, scripts and generator in this folder are original. The built
archive is not: every new appearance definition is a copy of the vehicle's vanilla
`player_01` definition, read from the local game at build time. So the archive embeds game
data. The build writes only into the git-ignored `artifacts/vehicle-kit-archivexl/`.
**Never commit, upload to the Workshop or distribute its outputs.** No game file is committed.
Game resources are named by depot path in the specs and read into ignored folders.

| Path | What it is |
|---|---|
| `specs/e06-appearance.json`, `specs/e07-plate.json` | What each pack adds: vanilla depot paths, component placement, appearance names, expected look |
| `native/axl-generate.cjs` | Builds the WolvenKit JSON (a standalone `.app` and an ArchiveXL patch `.ent`) from a spec and the vanilla JSON. Its `validate` mode checks a round trip field by field. |
| `native/normalize-archive.cjs` | Pins the per-file timestamps of the RDAR v12 archive and recomputes its CRC-64, so rebuilds are byte-identical |
| `build-axl-pack.ps1` | The whole pipeline, end to end |
| `lua/e06_server.lua`, `lua/e07_server.lua` | Server scripts of the lab resources. `@@REVISION@@` is filled in at build time. |
| `reds/Open77VehiclePlateLab.reds` | E0.7 lab REDscript, installed by hand and never put in a ZIP |

## Build

```powershell
pwsh -File scripts/vehicle-kit/archivexl/build-axl-pack.ps1              # both packs
pwsh -File scripts/vehicle-kit/archivexl/build-axl-pack.ps1 -Pack e07    # one pack
```

The build needs:
- the game directory, through `-GameDirectory` or `OP77_GAME_DIR` (process, then user scope). It is read only.
- WolvenKit CLI 8.20, resolved by `scripts/find-wolvenkit.ps1`.
- Node.js 18 or later.

For each pack, the build does this:

1. Extracts the referenced vanilla files into `<pack>/vanilla` (cached; `-RefreshVanilla` re-reads them). Any missing depot path fails the build.
2. Serializes the `.ent`, the `.app` and the screen mesh.
3. Computes the revision: SHA-256 of the spec, the pipeline files, the pack's Lua and REDscript, the WolvenKit version and the hash of every vanilla file used.
4. Generates the JSON, deserializes it, serializes it again, and checks the round trip.
5. Packs the archive, then normalizes, lists and extracts it to compare bytes.
6. Writes the `.xl` and the ZIP (fixed timestamps).
7. Writes the lab resource.
8. E0.7 only: compiles the lab REDscript offline with the game's own `engine\tools\scc.exe`, on a copy of the vanilla script bundle in a scratch tree. It never writes into the game folder. `-SkipRedscriptCheck` skips this step.
9. Writes `manifest.json` and `SHA256SUMS`.

Two consecutive builds give the same hashes.

Outputs, under `artifacts/vehicle-kit-archivexl/<e06|e07>/`:

```text
work/packed/<archiveName>.archive          the archive (depot prefix open77\assets\<resource>\<rev12>\)
work/packed/<archiveName>.archive.xl       the ArchiveXL config
resource/<resource>/                       copy this folder to the lab server's resources root
  open77.lua  server.lua  dist/<archiveName>_<rev12>.zip
lab-install/r6/scripts/Open77Lab/*.reds    E0.7 only: copy under <game>/r6/scripts/Open77Lab/ on each test client
manifest.json  SHA256SUMS
```

The ZIP holds `archive/pc/mod/<archiveName>.archive` and
`archive/pc/mod/<archiveName>.archive.xl`. Both are inert extensions. `preload_mod` refuses
`.reds`, which is why the REDscript is a separate hand install.

### Both packs share one mechanism

The vanilla `.ent` gets a patch through the `.xl` file:

```yaml
resource:
  patch:
    open77\assets\<resource>\<rev12>\<vehicle>_e0x.ent:
      props: [ appearances ]
      targets:
        - <vanilla vehicle .ent>
```

The patch `.ent` holds only new appearance **entries**. Each entry points at our own `.app`
(same folder) and a definition in it. The patch has a bare `entEntity` root and no
component. That root is not merged into the vanilla entity, because `entity` and
`components` are not in `props`. Vanilla entries keep their names, so the factory looks and
traffic cars are untouched.

## E0.6: does an ArchiveXL-added appearance work with `setAppearance`?

**Target.** The record is `Vehicle.v_standard2_archer_hella_player`, the entity is
`base\vehicles\standard\v_standard2_archer_hella__basic_01.ent`, and the base is entry
`archer_hella__basic_player_01`, which maps to definition `player_01` of
`base\vehicles\appearances\standard\archer_hella__basic.app`.

The server passes the **entry name** verbatim, as `Open77.vehicles.setAppearance(id, name)`
or `create{ appearance = name }`:

| Server string | Built as | Expected on every client |
|---|---|---|
| `open77_e06_a` | entry + definition = `player_01` + an `entMeshComponent` bound to `vehicle_slots`/`Base`, using the Hella's own `..._ext01_junk_solar_01.mesh` | the factory car **plus a junk solar panel on the roof** |
| `open77_e06_parts` | entry + definition = `player_01` with `partsValues: [archer_hella_e06_roof_part.ent]` and the definition tag `AppearanceParts`; the part `.ent` holds the same solar-panel component | the same solar panel, **merged from a part** by ArchiveXL `IncludeAppearanceParts` |
| `open77_e06_dyn` | entry + plain copy of `player_01` | the factory look |
| `open77_e06_dyn!a` | **definition only, no entry** (see below) | **negative control**: no change, no crash; note what the car shows and what the client log says |

The `.app` also carries a definition `open77_e06_dyn!b` (Combat Cab stickers on the body and
the hood, `..._ext01_body_stickers_combatcab_01/03.mesh` and
`..._ext01_hood_sticker_combatcab_01.mesh`). It is ready for the day dynamic appearances can
be enabled.

### Dynamic appearances do not apply here (evidence)

The sources cited below are in the ArchiveXL fork Open2077/archive-xl, branch `open77/1.28`,
which matches the installed `1.28.0+Open77`. The fork only changes world streaming: these files
are identical to upstream 1.28.0, and official 1.28.6 still has the same code.

1. **The entity tag cannot be added to this vehicle.** A dynamic name (`base!variant`) is
   only resolved for an entity whose `.ent` carries the visual tag `DynamicAppearance`
   (`Garment/Dynamic.cpp`, `SupportsDynamicAppearance`). The vanilla Hella and Galena both
   have `visualTagsSchema = null`. The `.ent` patch branch that merges visual tags
   (`ResourcePatch/Extension.cpp`, the `EntityTemplateVisualTagsProp` block) does this when
   the target has no schema:
   ```cpp
   if (!aTemplate->visualTagsSchema) { aTemplate->visualTagsSchema = {}; }   // an EMPTY Handle
   aTemplate->visualTagsSchema->visualTags.Add(...);                         // write through null
   ```
   `visualTagsSchema` is a `Handle<ent::VisualTagsSchema>` (RED4ext.SDK
   `ent/EntityTemplate.hpp`). This is a null dereference the first time any Hella entity
   loads, so it would crash every client as soon as a Hella streams in, traffic included.
   The generator therefore **refuses** `entityVisualTags` on an entity without a schema.
   Negative control, verified: it fails with `AXL_FAILED ... has no visualTagsSchema`. The
   E0.6 spec ships with `entityVisualTags: []` and a `dynamicAppearance.status: "disabled"`
   note. **Fix to send upstream** (no official release up to 1.28.6 has it): create the schema (`Red::MakeHandle<ent::VisualTagsSchema>()`)
   instead of `{}`. Then set `entityVisualTags` back to `["DynamicAppearance"]`.
2. **Even with the tag, only name-level selection could work on a vehicle.** In
   `OnResolveAppearance` (`Garment/Extension.cpp`), a name with no `%context` is resolved
   against `GetFirstEntityState()`, i.e. any entity that has a state, usually the local
   player. The `.ent` entry is then synthesized from the base entry. The definition is
   picked by the exact name `base!variant`, falling back to the base definition. The
   component-level features (`{variant}` substitution in paths, `&` conditions) need an
   `EntityState` of the entity itself. `EntityState`s are created only from the
   ItemFactory, garment and appearance-changer hooks (`GetEntityState(...)` call sites),
   that is, for items worn by a character. A vehicle never gets one. Name-level selection
   on a vehicle is therefore exactly what a static entry already gives. It saves nothing in
   a model x rim x kit explosion.

**What can avoid the explosion.** Two directions; both are **inference, untested**.
- `AppearanceParts`: `IncludeAppearanceParts` runs in the generic entity builder
  (`ResourcePatch/Extension.cpp`, `OnEntityPackageLoad`) for any entity, and keys on the
  definition's visual tags. One base definition plus N part `.ent` files would turn into one
  definition per combination listing the parts, with no component copies. The
  `open77_e06_parts` row tests exactly this on a vehicle.
- Name-matched `.app` patches that add only our own components, disabled, and toggled at
  runtime. They would stay off the per-combination path entirely.

### In-game procedure (lead)

Use a lab server with two clients. Copy `e06/resource/open77_vehicle_appearance_test` to the
resources root, grant the lab account `command.vapp.car`, `command.vapp.test`,
`command.vapp.get`, `command.vapp.list`, `command.vapp.cycle` and `command.vapp.clear`, then
`start open77_vehicle_appearance_test`. The archive mounts at game start, so each client
connects once to receive the preload mod and then restarts the game.

```text
/vapp.car                         -> "lab Hella <id> spawned"; both clients see a factory Hella 6 m ahead
/vapp.test <id> open77_e06_a      -> both clients: solar panel on the roof
/vapp.test <id> default           -> both: back to factory
/vapp.test <id> open77_e06_parts  -> both: solar panel (AppearanceParts on a vehicle)
/vapp.test <id> open77_e06_dyn!a  -> both: NO change, no crash (negative control); read the client log
/vapp.car open77_e06_a            -> a Hella born wearing the appearance (create path rather than change path)
/vapp.cycle <id>                  -> the whole list, 8 s per step, with the expectation printed at each step
/vapp.get <id>   /vapp.list   /vapp.clear
```

`<id>` may be `.` for the car you sit in, or your lab car. Also check that a late joiner and a
traffic Hella still look factory.

## E0.7 route W: a text widget over the Galena rear plate

**Target.** The record is `Vehicle.v_standard2_thorton_galena_player`, the entity is
`base\vehicles\standard\v_standard2_thorton_galena_01__basic_01.ent`, and the base is entry
`thorton_galena__basic_player_01`, which maps to `player_01` of
`base\vehicles\appearances\standard\thorton_galena__basic.app`. The rear plate is component
`license_plate_01`, bound to `bumper_b_01`.

Each new definition adds two components to `player_01`:
- A **screen quad**, `open77_plate_screen`. It is an `entMeshComponent` using the 4-vertex,
  two-sided quad
  `base\environment\decoration\electronics\entertainment\television\television_neokitsch_21x9_screen_a.mesh`,
  in appearance `interactive_screen`, whose material is the stock world-UI
  `base\materials\screen\screen_ui.mi`; the generator checks this. It is bound to
  `license_plate_01`.
  - Placement: the quad is scaled to the width of the plate's holo layer (0.3217 m) and
    centred on it, 3 mm proud of the plate face (y = -0.024 in the plate frame). Its height
    is width / aspect.
  - Orientation: the quad's UVs read correctly from +Y (u grows toward -X). The plate is seen
    from -Y. So a yaw of 180 degrees makes the text read correctly from behind the car.
- A **`WorldWidgetComponent`**, `open77_plate_text`, modelled on the Galena's own
  `interior_ui`. Its `meshTargetBinding` and `parentTransform` both point at the screen; the
  item is `Root`; `limitedSpawnDistanceFromVehicle` is 0.

| Server string | Screen | Widget | Expected from behind the car |
|---|---|---|---|
| `open77_e07_quad` | 0.322 x 0.098 m, yaw 180 | none | the bare quad over the plate (placement control): a dark or blank panel |
| `open77_e07_plate` | 0.322 x 0.098 m, yaw 180 | street sign | a lit panel; text either the authored "Example street name" or whatever the sign's native controller writes |
| `open77_e07_plate_flip` | same, yaw 0 | street sign | predicted to read **mirrored** (orientation control) |
| `open77_e07_plate_lcd` | 0.322 x 0.032 m, yaw 180 | LCD 10x1 | a thin strip, empty until the text is set |

Candidate vanilla libraries with a text widget. Paths are relative to the library item
`Root`.

| `.inkwidget` | Root size | Text widget | Logic controller (risk of overwrite) |
|---|---|---|---|
| `base\gameplay\gui\world\street_signs\generic_street_name\generic_street_name_sign.inkwidget` (**used**) | 660x200 | `StreetNameContainer/StreetName` ("Example street name") | native `inkStreetNameSignLogicController`, with street, district and subdistrict refs: **may rewrite the text** |
| `base\gameplay\gui\world\street_signs\generic_screens\lcdscreen_10x1.inkwidget` (**used**) | 1500x150 | `default_ui/messege_text` (empty) | scripted `LcdScreenILogicController`, which acts only when a device feeds it |
| `base\gameplay\gui\world\street_signs\generic_highway_sign\...` | - | `Content/Texts/Texts/MainText` | native `inkHighwaySignLogicController` |
| `apartment_screen_10x1`, `lcd_screens\lcdscreen_10x1` | - | - | `ApartmentScreenInkGameController` / device controllers |

### Setting the text at runtime

The widget instance is `IWorldWidgetComponent.GetWidget() -> ref<inkWidget>`; the native
exists per the 2.50 RTTI manifest. The text is `inkTextWidget.SetText(String)` (`inkText` in
REDscript), found with `inkCompoundWidget.GetWidgetByPathName(n"StreetNameContainer/StreetName")`.

`reds/Open77VehiclePlateLab.reds` does exactly that. Calling a scripted function with
parameters through `Open77.rtti.call` crashes the client, so the script is triggered by a
wrap rather than called:
- The script wraps `VehicleComponent.ApplyVehicleVisualCustomizationTemplate`.
- Magic paint **primary #040506** is swallowed: the car keeps its real paint.
- The three secondary bytes index `0-9 A-Z space -`, and the text becomes `OP77-xyz`.
- Secondary 255,255,255 dumps the widget tree instead.
- It retries until the widget exists (up to 20 s), writes, then reads back after 1 s and
  again after 6 s, to catch a controller that overwrites the text.
- Results go to the client Open77 log as `vplate set|readback|tree|FAIL ...`.
- It compiles with `scc` against the vanilla bundle plus this branch's `client/redscript`,
  with 0 errors and 0 warnings in the lab file.

Paint replicates to every viewer and to late joiners, so this is also a two-client transport
for the lab. The production route would read the plate from a state bag instead: the
state-bags guide recipe `Entity(id).state:set("plate", ...)`. Open77 has no native plate,
and `setProperties plateText` is refused.

### In-game procedure (lead)

1. On **each** test client, with the game stopped, copy
   `e07/lab-install/r6/scripts/Open77Lab/Open77VehiclePlateLab.reds` to
   `<game>/r6/scripts/Open77Lab/`. Remove it after the session.
2. Install the resource as for E0.6:
   - copy `e07/resource/open77_vehicle_plate_test` to the resources root;
   - grant `command.vplate.car`, `.app`, `.text`, `.describe`, `.cycle` and `.clear`;
   - `start open77_vehicle_plate_test`;
   - restart each client after the first connect.

```text
/vplate.car quad              -> Galena 7 m ahead, facing away: a panel exactly over the rear plate
/vplate.app <id> plate        -> both clients: the street-sign widget on the plate
/vplate.describe <id>         -> each client logs "vplate tree ..." (names, classes, controllers, current texts)
/vplate.text <id> ABC         -> each client logs "vplate set ... after=\"OP77-ABC\"" then "vplate readback ... kept=true|false"
/vplate.app <id> flip         -> mirrored text expected; then /vplate.text again (an appearance change rebuilds the widget)
/vplate.app <id> lcd          -> thin strip; /vplate.text <id> 77X
/vplate.cycle <id>   /vplate.clear
```

Read `red4ext/logs/open77-*.log` on each client and grep for `vplate`.

## Fact, inference, untested

**Facts** (from files, source or the build):
- ArchiveXL `.ent` patches add or replace entries by name.
- `appearances` without `entity` or `components` leaves the vanilla package alone.
- The visual-tag branch dereferences a null handle on a schema-less target.
- Dynamic component features need an `EntityState`, which only character item hooks create.
- The vanilla Galena `player_01` already carries a `WorldWidgetComponent` (`interior_ui`), so
  vehicles build them.
- The quad's material is `screen_ui.mi`, and its UV orientation and plate rectangle were
  measured from the decoded meshes.
- Every generated file survives a WolvenKit round trip, field by field.
- The archives are byte-reproducible.
- The lab Lua passes `open77_validate` with no errors.
- The lab REDscript compiles.

**Inference:**
- `setAppearance` with an added entry name applies on every client (the client calls
  `ScheduleAppearanceChange` with the name verbatim).
- `AppearanceParts` works on a vehicle, on both the create path and the change path.
- `limitedSpawnDistanceFromVehicle 0` means no distance limit.
- The Galena player record supports generic paint: its `.ent` has the `vvc_color` effects and
  the customization component, and the Hella was measured `genericPaint=yes`. If not,
  `/vplate.text` answers false and route W loses its lab transport, not its rendering.
- The street-sign controller may overwrite the text (the readback says so).
- The bare `entEntity` root of the patch `.ent` loads harmlessly.
- A part component bound to `vehicle_slots` resolves once merged into the vehicle.

**Untested:** everything in game. In particular:
- the dynamic negative control's exact behaviour: the client retries an unresolved
  appearance every 5 s;
- what the quad shows with no widget;
- the mirrored orientation control;
- whether the plate widget renders at range: the proxy and LOD meshes at distance show the
  factory look.
