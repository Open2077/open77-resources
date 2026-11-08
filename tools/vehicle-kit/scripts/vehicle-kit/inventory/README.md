# Vehicle customization inventory (offline)

Offline cross-check for experiment E0.1 of the vehicle customization plan: reads the
installed game files only. It never launches the game and never writes to the game
folder.

| Script | Output |
|---|---|
| `vehicle_inventory.py` | `docs/generated/vehicle-customization-<ver>.csv`: one row per `gamedataVehicle_Record` |
| `dealer_components.py` | `docs/generated/vehicle-components-dealer-<ver>.json` and `.md`: Light RP dealership models, components and license plates; with `--scope`, `vehicle-components-player-bodies-<ver>.json` and `.md`: every vanilla player body, with its trims |
| `player_components.py` | `docs/generated/vehicle-components-player-<ver>.json` and `.md`: every vanilla `Vehicle.*_player*` record, its wheel and plate components per entity appearance; with `--measure-plan`, the `measure-wheels.ps1 -Dealer` input |
| `player_body_components.py` | Every vanilla `Vehicle.*_player*` car (bikes, AVs and panzers skipped), in the dealer inventory's shape, one model per body: records that share an entity and an exterior share a key. Written outside the repository (`body_measure.py --dealer` reads it) |
| `body_hides.py` | `specs/lightrp-bodykit-hides.json`: per car body, the factory parts each body-kit group hides, read from every appearance of the entity |
| `player_scope.py` | `docs/generated/vehicle-player-scope-<ver>.json`: every `Vehicle.*_player*` car and bike of the installed TweakDB, grouped by entity into bodies |
| `tdb.py` | Pure-Python `tweakdb.bin` reader, used by the scripts above |
| `cr2w_json.py` | WolvenKit CLI extraction and serialization helpers, plus JSON readers |

## Requirements

- Python 3.10 or later, standard library only.
- WolvenKit CLI (`cp77tools`, tested with 8.20.0) for archive listings, `oodle decompress`,
  `unbundle` and `convert serialize`. The default path is
  `%USERPROFILE%\.dotnet\tools\cp77tools.exe`; use `--cp77tools` to override it.
- WolvenKit's TweakDB string table, `tweakdbstr.kark`, available in the WolvenKit
  repository at `WolvenKit.Common/Resources/`. It supplies record names. Flat IDs do not
  need names: `Record.prop` is derived from the record ID (see below). Records missing
  from the table are written as `<0x...>`. The optional `--vehicles-txt` list provides
  additional `Vehicle.*` names.
- A scratch folder **outside the repository** for archive listings and extracted files.
  `dealer_components.py` refuses to use a folder inside the checkout. Keep game files,
  meshes, textures, `.ent` and `.app` dumps out of Git.

## Regenerate

From the repository root:

```powershell
$game = 'C:\Program Files (x86)\Steam\steamapps\common\Cyberpunk 2077'   # or $env:OP77_GAME_DIR
$scratch = "$env:TEMP\op77-vehicle-inventory"
$kark = '<path to>\tweakdbstr.kark'

python -I scripts/vehicle-kit/inventory/vehicle_inventory.py --game $game `
    --names $kark --cache $scratch --vehicles-txt <optional vehicles.txt>

python -I scripts/vehicle-kit/inventory/dealer_components.py --game $game `
    --names $kark --cache $scratch --scratch "$scratch\extract" `
    --light-rp <light-rp checkout>
```

For the body kit beyond the dealership cars (`scripts/vehicle-kit/docs/bodykit.md`):

```powershell
python -I scripts/vehicle-kit/inventory/player_body_components.py --game $game `
    --names $kark --cache $scratch --scratch "$scratch\extract" --vehicles-txt <optional vehicles.txt> `
    --base docs/generated/vehicle-components-dealer-2.50.json --out "$scratch\vehicle-body-components-player-2.50.json"

python -I scripts/vehicle-kit/inventory/body_hides.py --game $game `
    --inventory "$scratch\vehicle-body-components-player-2.50.json" --cache $scratch --scratch "$scratch\extract"
```

`player_body_components.py` copies the dealer models verbatim (the 14 measured cars keep
byte-identical inputs) and analyses the other records like `dealer_components.py`. It
takes about 25 minutes for the 57 other car records of 2.50. Quest variant records
(`Vehicle.q<digits>_*`: `q000_hym_player_car`, `q304_songbird_escape_player`) are listed as
skipped, like the bikes: the kit leaves them out (owner decision, 2026-11-07). `body_hides.py` reads the
`.app` of every appearance (already serialized by the inventory) in about a minute.

Every vanilla player body (the sticker and livery packs read this table):

```powershell
python -I scripts/vehicle-kit/inventory/player_scope.py --game $game --names $kark `
    --cache $scratch --vehicles-txt <optional vehicles.txt>
python -I scripts/vehicle-kit/inventory/dealer_components.py --game $game `
    --names $kark --cache $scratch --scratch "$scratch\extract" `
    --scope docs/generated/vehicle-player-scope-2.50.json --light-rp <light-rp checkout> --skip-plate-survey
```

`player_scope.py` keeps the `Vehicle.*_player*` records whose `vehicleType` is a car or a
bike and that have an entity template, drops the panzer class (Basilisk) and the quest
variants (records named `Vehicle.q<digits>_*`: `Vehicle.q000_hym_player_car` and
`Vehicle.q304_songbird_escape_player` on 2.50, which share the Hella's and the Cortes'
entities; the owner keeps them out of the whole extension), lists each dropped record
with its reason under `excluded`, and groups the records that share one `.ent` into a body. A body's key is its Light RP catalogue key when
it has one, then a few fixed overrides (`nazare`, `nazare_linas`, `cortes_cab`), else a
name derived from the record; a key matching the sticker contract's excluded words is
refused. On game 2.50: 1,379 vehicle records, 88 player records, 86 in scope (the two
quest variants excluded), 49 bodies, the same 88 names as the workstation's `vehicles.txt`.

With `--scope`, each body's primary record is inventoried as a dealer model is, and every
record of the body gets a `trims` row: the entity appearance it spawns with, that
appearance's components, `differs` (another mesh or parent binding than the primary's
player appearance: the panel moved or changed), `restyled` (same geometry, another mesh
appearance: a material swap only) and `absent`. With `--light-rp` as well, the catalogue
keys take their Light RP label, category and price, so the 16 dealer models read the same
in both tables (the player table adds only `trims`). The Legatus and the Outlaw heist have
one component each whose mesh is an unresolved hash: the packs skip it.

The first run lists every non-audio, non-language archive (`cp77tools archive -l`) into
`<cache>/archive-lists`, which takes about one minute. These listings resolve
`raRef:CResource` hashes (FNV-1a 64 of the depot path) back to paths and identify the
archive that contains each file. The scripts refresh a listing when its archive is newer.
`dealer_components.py` reuses serialized JSON from earlier runs. The first run takes
about 15 minutes for the 15 models. The plate survey then serializes every vehicle
`.app` file, about 126 files, which adds a few GB of JSON to the scratch folder and more
minutes of runtime. Pass `--skip-plate-survey` to skip that pass.

`player_components.py` takes the same `--game`, `--names`, `--cache` and `--scratch`
(and `--vehicles-txt`, which fills the string table's holes); it reuses `dealer_components.py`
for the TweakDB, `.ent` and `.app` reading. It lists every record named `Vehicle.*_player*`
(AV and tank classes excluded; none carries such a name in 2.50), except the quest
variants: records named `Vehicle.q<digits>_*` (2.50: `Vehicle.q000_hym_player_car`,
`Vehicle.q304_songbird_escape_player`) are out of the whole customization extension by
the owner's decision of 2026-11-07. They go to `excludedRecords` with that reason and are
never analysed, so no rim fit, plate model or Light RP data is built for them
(`player-rim-fit.cjs`, `plates/player-models.py` and Light RP's generator skip or refuse
the same pattern). For each other record:
the player appearance and where it comes from (`appearanceName`, the entity default, or the
first entity appearance, which is not fixed: the game may spawn another), every entity
appearance with its `.app` definition, and per appearance the wheel components (the
`measure-wheels.ps1` rule: rim, tyre, any other mesh on a wheel, brake or axle slot;
shadows skipped) and the plate components. Identical wheel sets are written once
(`wheelSets`). `bodies` groups the records sharing an entity and `.app` set.
`--measure-plan <file>` (outside the checkout) also writes one `measure-wheels.ps1`
model per distinct (entity, `.app`, definition) wheel variant, keyed `v<n>`, with the
records and appearances it stands for in `variantOf`. 2.50: 86 records, 49 bodies, 932
wheel variants, 2 quest variants left out (their bodies are the dealer Hella's and Cortes',
so leaving them out removes no wheel variant).

`dealer_components.py` also:

- reads `LightRpConfig.vehicles.catalog` in `shared/config.lua` and the `publicStock`
  table in `server/config/dealerships.lua` of the Light RP checkout (read-only);
- picks the EP1 copy of a file when both an `ep1_*` archive and a base archive list it,
  on the assumption that EP1 archives shadow the base game;
- chooses a model's player appearance in this order: the record's `appearanceName`, the
  entity's `defaultAppearance`, then the first entity appearance;
- flags component roles (`rim`, `tire`, `wheel`, `spoiler`, `bumper`, `plate`, `glass`,
  `light`, `widget`, `decal` and so on) with name and mesh heuristics. Confirm a role
  against the live entity (`entity.components`) before relying on it.

## How TweakDB is read

`tdb.py` follows WolvenKit's `TweakDBReader.cs` (blob version 8, parser version 4; both
files of game version 2.50 use them):

- The header is `magic 0x0BB1DB47`, followed by the versions and the offsets of the flats,
  records, queries and group tags.
- In the flats section, each type is identified by `FNV1a64(type name)`, such as `Bool`,
  `array:TweakDBID` or `raRef:CResource`. Each type has a deduplicated value pool and a
  table of `(TweakDBID, value index)` keys.
  - Strings are VLQ length-prefixed.
  - Arrays use a VLQ count.
  - Resources are stored as 64-bit path hashes.
- In the records section, each record has a `(TweakDBID, murmur3_32(type name without
  "gamedata"/"_Record", seed 0x5EEDBA5E))` entry.
- A TweakDBID is `CRC32(name) | len(name) << 32`. The ID of the flat
  `Vehicle.x.hasVisualCustomization` is therefore the running CRC32 of
  `.hasVisualCustomization` started from the record's CRC, with the lengths added. No
  name is needed.
- `tweakdb_ep1.bin` contains all 196,423 base records and is layered over `tweakdb.bin`,
  with the last layer winning. Only 2,212 base flats are absent from the EP1 file. None of
  them is a `Vehicle.*` flat, and no vehicle colour, customization, appearance or wheel flat
  differs between the two files (checked on 2026-11-05).
- Flat names are the record getters in the RTTI manifest with a lowercase first letter,
  such as `HasVisualCustomization` → `hasVisualCustomization` and
  `VehWheelDimensionsSetup` → `vehWheelDimensionsSetup`.

## CSV columns (`vehicle-customization-<ver>.csv`)

- `vehicleType`, `manufacturer` and `model` contain the `enumName` of the referenced
  records, such as `Car`/`Bike`, `Archer` and `Turbo`.
- The customization flags are written as they appear in the record. `customizeLights`
  defaults to `true` on almost every record.
- `genericCustomizationMask` and `entityTemplatePath` contain depot paths.
  `<0x…>` means that WolvenKit's hash list does not know the path.
- The wheel columns come from `vehWheelDimensionsSetup` → `frontPreset` / `backPreset` →
  `rimRadius`, `tireRadius`, `tireWidth` and `wheelOffset`.
- `profiles` contains the colour templates from `appearancesToColorTemplate.colorTemplates`
  as compact JSON:

  ```json
  {"id":"Vehicle.…_inline3","main":[r,g,b],"sec":[r,g,b],"hue":0.42,"pattern":true,
   "decals":2,"multilayers":1,"match":["<.app appearance>"],"variant":["<colour variant>"]}
  ```

  Default values are omitted:
  - `hue` when it is -1 (no light hue);
  - `pattern` when false;
  - `decals` and `multilayers` when they are 0;
  - `variant` when it is empty.

  `dealer_components.py` writes the decal targets (`componentToAttachTo`, resource) and the
  multilayer details (mlsetup, mlmask, affected components) for dealership models.
