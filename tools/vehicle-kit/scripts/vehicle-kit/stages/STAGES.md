# Light RP performance stages

Three cumulative performance stages for each of the 15 non-staff Light RP dealer models
(13 cars, 2 bikes), and for every other vanilla player car and bike record of the game but the
quest variants (71 more records on 2.50, see "Extended models"). A stage is a **TweakXL record created at game start**, never a runtime
clone: experiment E0.8 measured that `tweak.clone` of a whole `Vehicle` record crashes the
client on spawn, while a TweakXL record derived with `$base` spawns through
`Open77.vehicles.create` and changes the real acceleration
(`docs/research/vehicles-api.md`, section *E0.8 — stage par record*). Changing a car's stage
is `respawnAs(id, record)` on the server (`docs/vehicle-visual-contract.md` section 6).

Status: generated and checked offline against the game's `tweakdb.bin`. Only the engine lever
has an in-game measurement (E0.8, torque x2 on the Hella). Brakes, grip and suspension are
**not measured yet**; see "In-game validation" at the end.

## Rebuild

```powershell
pwsh -File scripts/vehicle-kit/stages/build-stages.ps1                      # YAML -> ZIP -> draft resource
uv run --no-project python -I scripts/vehicle-kit/stages/make_stages.py --check <yaml>   # validate a YAML
uv run --no-project python -I scripts/vehicle-kit/stages/make_stages.py --update-doc     # refresh the tables below
```

- The game folder comes from `-GameDirectory` / `--game`, else `OP77_GAME_DIR` (process scope,
  then user scope). It is only read: `r6/cache/tweakdb.bin` with `tweakdb_ep1.bin` layered on
  top, through `../inventory/tdb.py`.
- Output (git-ignored): `artifacts/vehicle-kit/stages/` holding the YAML, `stages-manifest.json`
  (every base and stage value, tweakdb hashes), `stages-table.md`, `manifest.json`, `SHA256SUMS`
  and `resource/lightrp_vehicle_stages/` (the draft resource with `dist/LightRPVehicleStages_<rev12>.zip`).
  `<rev12>` is the first 12 hex digits of the stage YAML's SHA-256 (`-SkipEngineSounds`), or of
  the SHA-256 of `stages:<sha>\nsounds:<sha>\n` when the engine sounds are in, so the ZIP name
  changes exactly when its content does.
- The ZIP holds `r6/tweaks/LightRP/open77-lightrp-stages.yaml` and, unless `-SkipEngineSounds`,
  `r6/tweaks/LightRP/open77-lightrp-engine-sounds.yaml`: original YAML, no game file. The build
  reads them back out of the ZIP and checks those bytes again.
- `base-records.json` holds the names of the vanilla sub-records (engine, drive model, wheel
  setup, wheel presets) of each model. Every run hashes each name and compares it with the id
  found in `tweakdb.bin`; after a game update that renames them, regenerate it with
  `make_stages.py --names <tweakdbstr.kark> --cache <scratch>` (WolvenKit's string table, see
  `../inventory/README.md`). The same command rebuilds `record-properties.json` (the properties
  TweakXL gives a clone of each `$base`, for the TweakDBID collision check; it also reads TweakXL's
  `red4ext/plugins/TweakXL/Data/ExtraFlats.dat` from the game, or `--extra-flats <file>`).
- `extended-models.json` lists the extended models (every other vanilla `Vehicle.*_player*` car
  and bike record) with the vanilla reference price each one's stages are priced from; every run
  re-derives it from `tweakdb.bin` and refuses a mismatch. After a game update, rebuild it with
  `make_stages.py --refresh-models --names <tweakdbstr.kark>` (then review the diff).
- The output also holds `lightrp-vehicle-stage-catalogue.lua`, the Light RP gamemode's copy of the
  per-record data (proposed stage prices, sound counts per class): it goes to
  `server/config/vehicle_stage_catalogue.lua` in the Light RP repository (`--lightrp-config <file>`
  writes it there directly).
- The build ends with `VK_STAGES_OK revision=… models=86 records=… zip=… sha256=… (not deployed)`.
  It never copies anything into the game folder.

## What a stage is

```text
Vehicle.<dealer record>_o77sN          $base <dealer record>          vehEngineData, vehDriveModelData (bikes: bikeDriveModelData)
Vehicle.<dealer record>_o77sN_engine   $base <its vanilla engine>     engineMaxTorque
Vehicle.<dealer record>_o77sN_drive    $base <its vanilla drive model> wheelSetup
Vehicle.<dealer record>_o77sN_wheels   $base <its vanilla wheel setup> frontPreset, backPreset
Vehicle.<dealer record>_o77sN_front    $base <its vanilla front preset> brake, grip and suspension flats
Vehicle.<dealer record>_o77sN_back     $base <its vanilla rear preset>  (same)
```

Every record a stage changes is a **new id**. Many models use shared vanilla sub-records (the
Galena, Columbus and Semimaru run the generic `VehicleEngineData_4_Regular_Small`, `_Regular_Van`
and `_SuperSport` engines, the Apollo `VehicleEngineData_2_Default`; the Hella, Colby, Supron and
Columbus share one gear set), so modifying one in place would change every vehicle that uses it,
traffic included. The check refuses any record whose id already exists
in `tweakdb.bin`. A model whose engine stage is capped to x1.00 (the Quartz) has no `_engine`
record and keeps its vanilla engine. 15 models x 3 stages = 45 stage records, 267 records in all.

## Flats a stage overrides

| Record (TweakDB type) | Flat | Lever | Why |
|---|---|---|---|
| `Vehicle` | `vehEngineData`, `vehDriveModelData` / `bikeDriveModelData` | links | point the stage at its own derived engine and drive model |
| `VehicleEngineData` | `engineMaxTorque` | engine | the one lever measured in game (E0.8) |
| `VehicleDriveModelData` / `BikeDriveModelData` | `wheelSetup` | link | point at the derived wheel setup |
| `VehicleWheelDrivingSetup_4` / `_2` | `frontPreset`, `backPreset` | links | point at the derived presets; the `LF/RF/LB/RB` (`F/B`) wheel roles stay vanilla |
| `VehicleWheelDrivingPreset` | `maxBrakingTorque` | brakes | service brake torque per wheel; same factor on both axles keeps the brake balance |
| | `frictionMulLongitudinal`, `frictionMulLateral` | grip | tyre grip multipliers (traction and braking; cornering) |
| | `springStiffness`, `swaybarStiffness` | suspension (cars) | less body roll and pitch |
| | `springDamping`, `springReboundDamping`, `springBoundDampingLowRate`, `springReboundDampingLowRate` | dampers (cars) | scaled by the square root of the spring factor, so the damping ratio c / (2 sqrt(k m)) is unchanged |

Deliberately untouched, and why:

- **`gears`, `maxRPM`** (engine): the rated top speed is the top gear's `maxSpeed` (Hella: 32 m/s =
  115.2 km/h, exactly what `vehicle.rated` returned in E0.8). Leaving the gearbox alone keeps every
  model's top speed stock, which is the top-speed cap. Gear internals are unmeasured.
- **`handbrakeBrakingTorque`**: the handbrake drives drifts and turns; a brake upgrade should not
  change how a car slides.
- **`brakingFrictionFactor`, `tireFrictionCoef`**: identical on all 15 models (1.4 and 1.0), so their
  meaning cannot be inferred from the catalogue; the per-axle multipliers above have a real range.
- **`airResistanceFactor`, masses, `wheelsFrictionMap`**: would change top speed or the friction
  curves, both outside a stage.
- **`vehDriveModelDataAI`** (set on the Colby and the Galena only): the drive model the game uses
  when an AI drives. Players drive `vehDriveModelData`; see the validation notes.
- **`vehicleUIData`** (displayed horsepower): cosmetic, out of scope.
- **Bike suspension**: the bikes' tilt controller (`bikeTiltPID`) is tuned against their springs;
  bikes get engine, brakes and grip only.

## Stage policy

| Lever | s1 | s2 | s3 | Notes |
|---|---|---|---|---|
| Engine, cars | x1.20 | x1.40 | x1.60 | before caps; E0.8 fit: +48 % average acceleration per +100 % torque, so about +10 / +19 / +29 % |
| Engine, bikes | x1.10 | x1.20 | x1.30 | bikes are torque-sensitive (one driven wheel, wheelies) |
| Brakes | x1.10 | x1.20 | x1.30 | both axles |
| Grip | x1.02 | x1.04 | x1.06 | capped at 1.00 |
| Springs and swaybar (cars) | x1.05 | x1.10 | x1.15 | |
| Dampers (cars) | x1.025 | x1.049 | x1.072 | square root of the spring factor |

When the engine is capped, the three stages keep their proportions: `f_k = 1 + (f3 - 1) x k / 3`.
Every scaled value is rounded **down** (0.1 Nm, 0.001 grip, 0.01 stiffness, 1 for dampers), so
rounding never crosses a cap.

## Hard caps

- **Top speed: never raised.** No stage touches `gears` or `maxRPM` (refused by the check), so the
  rated top speed is the stock one at every stage. This alone keeps the vanilla top-speed ladder.
- **Torque, class ceiling.** The dealer models are placed on price tiers (cars: T1 < 20,000,
  T2 < 50,000, T3 < 100,000, T4 < 200,000, T5 above; bikes: B1 < 100,000, B2 above). The
  acceleration proxy is the *specific torque* `engineMaxTorque x finalGearTorqueDecimationScalor /
  total_mass` (Nm per tonne). A model's stage-3 specific torque may not exceed the class ceiling:
  the lowest "best stock specific torque" among all more expensive tiers of its ladder. In plain
  words: **a stage-3 car never out-accelerates the best stock car of any more expensive class**.
  Today the ceiling for T1 and T2 is the Hozuki (188.2 Nm/t, T3's best), for T3 the Bandit
  (341.6 Nm/t), for T4 the Semimaru (482.7 Nm/t), and the Kusanagi (366.3 Nm/t) for the Apollo.
  A model already above its ceiling at stock (the Quartz, 252.2 Nm/t, the vanilla outlier of T2)
  gets no engine gain at all: its stages are brakes, grip and suspension.
- **Torque, absolute:** 1,600 Nm (the Semimaru's stage 3 is 1,536 Nm).
- **Grip:** at most +6 %, and never above 1.00 (the best tyre multiplier of any dealer model,
  the Semimaru's rear lateral).
- **Brakes:** at most +30 %. **Suspension:** springs and swaybar at most +15 %, dampers at most
  sqrt(1.15).
- No stage value is below stock, and s1 <= s2 <= s3 for every flat.

Grip and brakes are not ladder-capped: the vanilla grip values are not ordered by price either,
and the friction maps (`Super_Sport_Friction_Map`, `Truck_Friction_Map`...) that separate the
classes most are left alone.

## What `--check` verifies

On the YAML (generation runs the same check, and the build runs it again on the bytes inside
the ZIP):

- the file stays in the plain YAML subset TweakXL reads (`Record:` / `  flat: value`), no BOM;
- every record name is `Vehicle.<dealer record>_o77s<1-3>[_engine|_drive|_wheels|_front|_back]`
  of one of the 15 models, and **is not an existing id** (no vanilla record modified in place);
- every `$base` exists in `tweakdb.bin`, has the expected record type for its part and ladder, and
  is the exact vanilla record the model's chain points at;
- every overridden flat is on the whitelist above **and** exists on the `$base` record in
  `tweakdb.bin` with the expected flat type (`Float` / `TweakDBID`);
- every record reference points at the right derived record defined in the same file; no orphan;
- every number is finite, at or above stock, within its stage cap, within the absolute caps, and
  the stage-3 specific torque is within the class ceiling; values never decrease from s1 to s3.

- no TweakDBID collision (see "TweakDBID collisions" below): every record id and every flat id
  TweakXL creates is new and unique, and each declared resolution still holds.

It then mutates nine copies of the parsed YAML and requires each to be refused: an unknown
`$base`, an unknown flat, a top-speed flat (`maxRPM`), torque over its cap, grip above 1.00, a NaN,
a vanilla record overwritten in place, a dangling reference, and the Hellhound stage-2 engine back
under its colliding name. A check that let one through fails the run (`negative_tests=9/9` in the
output).

## Engine sounds (wave 2, W2.3)

An engine sound is a vanilla **audio set**: the two String flats `player_audio_resource` and
`traffic_audio_resource` every `Vehicle` record carries (engine, gearbox and horn come with it).
The same run writes a second YAML, `open77-lightrp-engine-sounds.yaml`, into the same ZIP, and
the resource registers the catalogue with the server (`Open77.vehicles.registerEngineSounds`,
`PLAN-vehicle-custom-wave2.md`). Code: `engine_sounds.py`; research notes:
`docs/research/vehicle-wave2-packs.md`.

```text
Vehicle.<dealer record>_o77a<k>       $base <dealer record>   player_audio_resource, traffic_audio_resource
Vehicle.<dealer record>_o77s<n>a<k>   $base <dealer record>   the stage-n record's links (vehEngineData,
                                                              veh|bikeDriveModelData) + the two audio flats
```

- `$base` is always the vanilla dealer record, never `_o77sN`: TweakXL never resolves a `$base`
  that another tweak creates. A stage-n sound record repeats the stage record's links exactly, so
  it drives like stage n and sounds like sound k.
- The matrix is every (dealer model, stage 0..3, sound of the model's class), nothing more:
  13 cars x 4 stages x 12 car sounds + 2 bikes x 4 x 4 bike sounds = **656 records, 207,824 bytes**
  (generator v1, 2026-11-06). A sound equal to a model's factory set (s01 on the MaiMai, s13 on the
  Kusanagi, s16 on the Apollo) is generated too, so the server composes any record without a
  special case; the Lua marks it `factory = true`.
- Ids `s01`..`s16` are **append-only**: a saved car keeps meaning the same sound. The record suffix
  is `a<k>` with k the number of the id.
- Labels are neutral and **provisional**: written from the source cars' engine data (maxRPM,
  torque), not by ear. `set` names stay server-side.

| Id | Label | Class | Vanilla set (internal) |
|---|---|---|---|
| s01 | Compact, city buzz | car | `v_car_makigai_maimai` |
| s02 | Sport six, turbo | car | `v_car_mizutani_shion` |
| s03 | Muscle V8, open pipes | car | `v_car_quadra_type_66` |
| s04 | Cruiser V8, low rumble | car | `v_car_villefort_alvarado` |
| s05 | Luxury V8, smooth | car | `v_car_chevalier_emperor` |
| s06 | Sport coupe, high revs | car | `v_car_herrera_riptide` |
| s07 | Electric, high whine | car | `v_car_rayfield_caliburn` |
| s08 | Supercar, wide open | car | `v_car_herrera_outlaw` |
| s09 | Turbo sport, hard-edged | car | `v_car_quadra_turbo_r` |
| s10 | Pickup V8, gruff | car | `v_car_thorton_mackinaw` |
| s11 | Heavy diesel | car | `v_car_kaukaz_bratsk` |
| s12 | Armoured, heavy | car | `v_car_militech_hellhound` |
| s13 | Sport bike, high revs | bike | `v_mbike_yaiba_asmx_kusanagi` |
| s14 | Heavy twin, deep thump | bike | `v_mbike_arch_nazare` |
| s15 | Chopper, open pipes | bike | `v_mbike_arch_nazare_chopper` |
| s16 | Street bike, raspy | bike | `v_mbike_brennan_cycles_apollo` |

`--check-sounds` (also run after every generation, and on the bytes inside the ZIP against the
stage YAML of the same ZIP) verifies:

- the catalogue: ids, at most 12 car and 6 bike sounds, each set and its traffic twin occurring
  **together** on a vanilla record of the declared class (the class is the `type` flat's
  `enumName`: Car, Bike, Panzer), never one of the three special vehicles (`v_av_basilisk_tank`,
  `v_metro_train`, `v_mq006_rollercoaster`: metro and rollercoaster are typed Car, so they are
  listed by name), never a police, NCU, MaxTac, story-only, weaponised or licensed-brand set
  (Porsche), and **no make, model or gang word in a label** (every word of every vanilla set name,
  minus plain engineering words, plus the dealer labels);
- the records: name `Vehicle.<dealer record>_o77[s<n>]a<k>`, not an existing id, `$base` = the
  dealer record, the model's class matches the sound's (and the dealer record's own `type`), only
  the stage links and the two audio flats (both String on the base), the links equal to the stage
  record's, the audio values equal to the catalogue's, and the matrix complete: nothing missing
  but the declared, collision-justified exclusions below, nothing extra;
- no TweakDBID collision across both YAMLs and the game's TweakDB.

It then refuses nineteen broken copies (`negative_tests=19/19`): ten on the records (class
mismatch, a flat outside the two, a stage link from another stage, a missing and an extra
combination, a vanilla record in place, `$base` = the stage record, a swapped audio set, a declared
exclusion generated anyway, and the Deleon stage 3 + s03 record put back, refused as a collision)
and nine on the catalogue (Basilisk, metro, a police set, a brand label, a dealer-model label, an
unknown set, a bike set on a car, an unpaired traffic set, a duplicate id).

The resource (`lua/stages_main.lua`, copied as `server/main.lua`) composes the records and keeps
one choice when the other changes: `stageRecord(record, n)` keeps the sound, `engineSoundRecord(record,
id)` keeps the stage, `composeRecord(record, n, id)` rebuilds both for a garage restore,
`stageOf(record)` answers the key, stage and sound. Lab commands (restricted):
`/enginesound list|off|<id> [vehicleId]` (uses `setEngineSound` when the server has it, else
`respawnAs`) and `/perfstage <0-3> [vehicleId]`. `-SkipEngineSounds` builds the stage pack alone,
with the same ZIP bytes and revision as before wave 2.

Tests: `uv run --no-project python -I -m unittest discover -s scripts/vehicle-kit/stages -p "test_*.py"`
(the generator layer needs the game's `tweakdb.bin`, the Lua layer a Lua 5.4 through
`scripts/furniture/luahost.py`).

## TweakDBID collisions

A TweakDBID is CRC32(full name) plus its length byte: 40 bits, and TweakDB keys every record and
every flat by them alone, so two different names with the same CRC32 and the same length are one
id. TweakXL creates, for each record of a YAML, the record id and one flat `<record>.<property>`
per property of its `$base`'s type (it clones the base: the type's properties plus TweakXL's extra
flats, `Data/ExtraFlats.dat`), then assigns the flats the YAML sets. Measured in game on
2026-11-08 02:06 (TweakXL log of a lab client, pack 7c4f42a3cfc2):

```text
[warning] Type mismatch for Vehicle.v_sport2_villefort_deleon_player_o77s3a3.player_audio_resource assignment.
[warning] Vehicle.v_sport2_villefort_deleon_player_o77s3a3.player_audio_resource has hash collision with Vehicle.v_standard2_makigai_maimai_player_o77s1a3.drivingParamsGeneric.
```

Both names are CRC32 `0x49c53d2a`, 70 bytes. The MaiMai record (a dealer model, written first)
keeps the id; the Deleon stage 3 + s03 record had no valid audio set. The dealer-only pack had
no collision: it came with the 71 extended models (about 520,000 ids for both YAMLs). TweakXL only
warns about the names it knows: a collision with a **vanilla** flat is silent (it does not load
the vanilla names), and the new record then reads, or overwrites, a flat of an unrelated vanilla
record. Three of those were in the same pack.

Every generation and every `--check` / `--check-sounds` now refuses any id the YAMLs create twice
(records and flats, the two YAMLs together) or that already exists in `tweakdb.bin` /
`tweakdb_ep1.bin`, flats and records alike (`collisions.py`). The properties of each `$base` type
come from `record-properties.json`, a reviewed file like `base-records.json`: `--names` rebuilds it
from WolvenKit's string table (the properties named on at least half the type's vanilla records
and present in `tweakdb.bin`) and TweakXL's `ExtraFlats.dat`, plus any flat a `$base` alone
carries; every run re-verifies it (each listed property is a flat of every `$base` of its type).
Limit (inference): a property the game's RTTI exposes that no named vanilla record of the type
carries would be missed; none is known.

A collision is resolved here, never on a dealer record (both YAMLs still start with the exact
bytes of the dealer-only build): an extended engine-sound record is **dropped** and the sound's
coverage omits that stage for that model, so `VehicleEngineSound.Covers` is false there and the
server never composes the record (the resource registers the map form `models = { [record] =
{ stages } }` for that sound; `engine-sounds.lua` lists the hole in `missing`); an extended stage
sub-record, which only its own stage record names, is **renamed** `_c1` (no hole). The
missing-combination check accepts exactly these exclusions, and each one is re-measured on every
run: the record must still collide as stated, or the entry is stale and the build fails. The table
below is generated (`--update-doc`) and the check refuses a build whose STAGES.md does not list it.

<!-- BEGIN GENERATED COLLISIONS: make_stages.py --update-doc -->

| Kind | Record the generator would write | Colliding id | CRC32 / length | Held by | Resolution |
|---|---|---|---|---|---|
| sound | `Vehicle.v_sport2_villefort_deleon_player_o77s3a3` | `.player_audio_resource` | 0x49c53d2a / 70 | pack `Vehicle.v_standard2_makigai_maimai_player_o77s1a3.drivingParamsGeneric` | dropped: sound s03 does not cover stage 3 of this model |
| sound | `Vehicle.v_sport1_quadra_turbo_player_o77s1a1` | `.customizeLights` | 0x6faad9bf / 60 | vanilla `Character.ep1_combat_zone_service_dining_ma_savable.vendorID` | dropped: sound s01 does not cover stage 1 of this model |
| sound | `Vehicle.v_sport1_quadra_turbo_r_player_o77a4` | `.vehImpactTraffic` | 0x862ccfd5 / 61 | vanilla `Character.arasaka_sumo_hmelee2_fists_mb_rare.stateMachineName` | dropped: sound s04 does not cover stage 0 of this model |
| stage | `Vehicle.v_standard3_militech_hellhound_player_o77s2_engine` | `.gearCurvesPath` | 0x525008e5 / 73 | vanilla `EquipmentGLP.HeavyFastFiringWeaponCloseRangeDamageMult_inline3.weaponType` | renamed `Vehicle.v_standard3_militech_hellhound_player_o77s2_engine_c1` (only its stage record names it; no hole) |

<!-- END GENERATED COLLISIONS -->

What a player sees (server, resource and Light RP, read 2026-11-08): the studio does not list a
sound at a stage the pack has no record for (`listEngineSounds` filters by `Covers`), a stage the
car's sound has no record for is refused before any charge (`engine_sound_not_for_stage`), and a
stored combination the pack no longer has spawns at its stage with the factory sound, the sound
kept stored (dormant) until it can be worn again.

## Tables

Regenerated by `make_stages.py --update-doc`; a build whose tables differ from these prints a
warning.

<!-- BEGIN GENERATED: make_stages.py --update-doc -->

### Class ladder and engine cap

| Model | Ladder, tier | Price | Top speed (rated) | Torque | Specific torque | Class ceiling | Engine s1 / s2 / s3 | Engine cap |
|---|---|---:|---:|---:|---:|---:|---|---|
| Makigai MaiMai | car T1 | 10,000 | 118.8 km/h | 180 Nm | 155.6 Nm/t | 188.2 Nm/t | x1.070 / x1.140 / x1.210 | class ceiling |
| Thorton Galena | car T1 | 16,000 | 108.0 km/h | 170 Nm | 154.5 Nm/t | 188.2 Nm/t | x1.073 / x1.145 / x1.218 | class ceiling |
| Archer Hella | car T2 | 30,000 | 115.2 km/h | 295 Nm | 144.2 Nm/t | 188.2 Nm/t | x1.102 / x1.203 / x1.305 | class ceiling |
| Thorton Colby | car T2 | 35,000 | 115.2 km/h | 260 Nm | 148.1 Nm/t | 188.2 Nm/t | x1.090 / x1.181 / x1.271 | class ceiling |
| Mahir Supron | car T2 | 40,000 | 115.2 km/h | 230 Nm | 136.6 Nm/t | 188.2 Nm/t | x1.126 / x1.252 / x1.378 | class ceiling |
| Archer Quartz | car T2 | 47,500 | 136.8 km/h | 290 Nm | 252.2 Nm/t | 188.2 Nm/t | x1.000 / x1.000 / x1.000 | class ceiling (stock already at or above it) |
| Mizutani Hozuki | car T3 | 60,000 | 136.8 km/h | 320 Nm | 188.2 Nm/t | 341.6 Nm/t | x1.200 / x1.400 / x1.600 | stage policy |
| Villefort Columbus | car T3 | 75,000 | 115.2 km/h | 320 Nm | 134.1 Nm/t | 341.6 Nm/t | x1.200 / x1.400 / x1.600 | stage policy |
| Villefort Cortes | car T3 | 95,000 | 126.0 km/h | 415 Nm | 150.5 Nm/t | 341.6 Nm/t | x1.200 / x1.400 / x1.600 | stage policy |
| Thorton Merrimac | car T4 | 115,000 | 126.0 km/h | 430 Nm | 159.9 Nm/t | 482.7 Nm/t | x1.200 / x1.400 / x1.600 | stage policy |
| Archer Bandit | car T4 | 130,000 | 151.2 km/h | 421 Nm | 341.6 Nm/t | 482.7 Nm/t | x1.138 / x1.275 / x1.413 | class ceiling |
| Chevalier Thrax | car T4 | 155,000 | 126.0 km/h | 380 Nm | 150.9 Nm/t | 482.7 Nm/t | x1.200 / x1.400 / x1.600 | stage policy |
| Yaiba Semimaru | car T5 | 250,000 | 162.0 km/h | 960 Nm | 482.7 Nm/t | none (top tier) | x1.200 / x1.400 / x1.600 | stage policy |
| Brennan Apollo | bike T1 | 12,500 | 118.8 km/h | 140 Nm | 326.7 Nm/t | 366.3 Nm/t | x1.040 / x1.081 / x1.121 | class ceiling |
| Yaiba Kusanagi | bike T2 | 200,000 | 151.2 km/h | 185 Nm | 366.3 Nm/t | none (top tier) | x1.100 / x1.200 / x1.300 | stage policy |

### Engine (`engineMaxTorque`, Nm) and expected effect

Expected acceleration gain = +48 % x (torque factor - 1), fitted on the single E0.8 run (an estimate until measured). Top speed is unchanged at every stage.

| Model | Stock | s1 | s2 | s3 | Avg. acceleration s1 / s2 / s3 |
|---|---:|---:|---:|---:|---|
| Makigai MaiMai | 180 | 192.5 | 205.1 | 217.7 | +3 % / +7 % / +10 % |
| Thorton Galena | 170 | 182.3 | 194.7 | 207 | +3 % / +7 % / +10 % |
| Archer Hella | 295 | 325 | 355 | 385 | +5 % / +10 % / +15 % (0-80 km/h: 8.65 s / 8.26 s / 7.91 s, stock 9.07 s measured) |
| Thorton Colby | 260 | 283.4 | 306.9 | 330.4 | +4 % / +9 % / +13 % |
| Mahir Supron | 230 | 259 | 288 | 317 | +6 % / +12 % / +18 % |
| Archer Quartz | 290 | 290 | 290 | 290 | +0 % / +0 % / +0 % |
| Mizutani Hozuki | 320 | 384 | 448 | 512 | +10 % / +19 % / +29 % |
| Villefort Columbus | 320 | 384 | 448 | 512 | +10 % / +19 % / +29 % |
| Villefort Cortes | 415 | 498 | 581 | 664 | +10 % / +19 % / +29 % |
| Thorton Merrimac | 430 | 516 | 602 | 688 | +10 % / +19 % / +29 % |
| Archer Bandit | 421 | 478.9 | 536.9 | 594.8 | +7 % / +13 % / +20 % |
| Chevalier Thrax | 380 | 456 | 532 | 608 | +10 % / +19 % / +29 % |
| Yaiba Semimaru | 960 | 1152 | 1344 | 1536 | +10 % / +19 % / +29 % |
| Brennan Apollo | 140 | 145.6 | 151.3 | 156.9 | +2 % / +4 % / +6 % |
| Yaiba Kusanagi | 185 | 203.5 | 222 | 240.5 | +5 % / +10 % / +14 % |

### Brakes (`maxBrakingTorque` per wheel, front / rear, Nm)

| Model | Stock | s1 | s2 | s3 |
|---|---|---|---|---|
| Makigai MaiMai | 70 / 60 | 77 / 66 | 84 / 72 | 91 / 78 |
| Thorton Galena | 260 / 150 | 286 / 165 | 312 / 180 | 338 / 195 |
| Archer Hella | 320 / 220 | 352 / 242 | 384 / 264 | 416 / 286 |
| Thorton Colby | 320 / 220 | 352 / 242 | 384 / 264 | 416 / 286 |
| Mahir Supron | 300 / 240 | 330 / 264 | 360 / 288 | 390 / 312 |
| Archer Quartz | 280 / 370 | 308 / 407 | 336 / 444 | 364 / 481 |
| Mizutani Hozuki | 410 / 380 | 451 / 418 | 492 / 456 | 533 / 494 |
| Villefort Columbus | 410 / 340 | 451 / 374 | 492 / 408 | 533 / 442 |
| Villefort Cortes | 580 / 380 | 638 / 418 | 696 / 456 | 754 / 494 |
| Thorton Merrimac | 460 / 420 | 506 / 462 | 552 / 504 | 598 / 546 |
| Archer Bandit | 465 / 625 | 511.5 / 687.5 | 558 / 750 | 604.5 / 812.5 |
| Chevalier Thrax | 540 / 320 | 594 / 352 | 648 / 384 | 702 / 416 |
| Yaiba Semimaru | 720 / 790 | 792 / 869 | 864 / 948 | 936 / 1027 |
| Brennan Apollo | 210 / 65 | 231 / 71.5 | 252 / 78 | 273 / 84.5 |
| Yaiba Kusanagi | 280 / 150 | 308 / 165 | 336 / 180 | 364 / 195 |

### Grip (`frictionMulLongitudinal` / `frictionMulLateral`, front ; rear)

| Model | Stock | s1 | s2 | s3 |
|---|---|---|---|---|
| Makigai MaiMai | 0.930 / 0.880 ; 0.890 / 0.890 | 0.948 / 0.897 ; 0.907 / 0.907 | 0.967 / 0.915 ; 0.925 / 0.925 | 0.985 / 0.932 ; 0.943 / 0.943 |
| Thorton Galena | 0.860 / 0.860 ; 0.860 / 0.860 | 0.877 / 0.877 ; 0.877 / 0.877 | 0.894 / 0.894 ; 0.894 / 0.894 | 0.911 / 0.911 ; 0.911 / 0.911 |
| Archer Hella | 0.880 / 0.890 ; 0.880 / 0.870 | 0.897 / 0.907 ; 0.897 / 0.887 | 0.915 / 0.925 ; 0.915 / 0.904 | 0.932 / 0.943 ; 0.932 / 0.922 |
| Thorton Colby | 0.865 / 0.865 ; 0.865 / 0.890 | 0.882 / 0.882 ; 0.882 / 0.907 | 0.899 / 0.899 ; 0.899 / 0.925 | 0.916 / 0.916 ; 0.916 / 0.943 |
| Mahir Supron | 0.870 / 0.880 ; 0.870 / 0.870 | 0.887 / 0.897 ; 0.887 / 0.887 | 0.904 / 0.915 ; 0.904 / 0.904 | 0.922 / 0.932 ; 0.922 / 0.922 |
| Archer Quartz | 0.890 / 0.910 ; 0.940 / 0.950 | 0.907 / 0.928 ; 0.958 / 0.968 | 0.925 / 0.946 ; 0.977 / 0.987 | 0.943 / 0.964 ; 0.996 / 1.000 |
| Mizutani Hozuki | 0.900 / 0.910 ; 0.900 / 0.910 | 0.917 / 0.928 ; 0.917 / 0.928 | 0.935 / 0.946 ; 0.935 / 0.946 | 0.953 / 0.964 ; 0.953 / 0.964 |
| Villefort Columbus | 0.870 / 0.870 ; 0.860 / 0.830 | 0.887 / 0.887 ; 0.877 / 0.846 | 0.904 / 0.904 ; 0.894 / 0.863 | 0.922 / 0.922 ; 0.911 / 0.879 |
| Villefort Cortes | 0.870 / 0.870 ; 0.860 / 0.860 | 0.887 / 0.887 ; 0.877 / 0.877 | 0.904 / 0.904 ; 0.894 / 0.894 | 0.922 / 0.922 ; 0.911 / 0.911 |
| Thorton Merrimac | 0.890 / 0.890 ; 0.980 / 0.980 | 0.907 / 0.907 ; 0.999 / 0.999 | 0.925 / 0.925 ; 1.000 / 1.000 | 0.943 / 0.943 ; 1.000 / 1.000 |
| Archer Bandit | 0.920 / 0.925 ; 0.955 / 0.940 | 0.938 / 0.943 ; 0.974 / 0.958 | 0.956 / 0.962 ; 0.993 / 0.977 | 0.975 / 0.980 ; 1.000 / 0.996 |
| Chevalier Thrax | 0.870 / 0.860 ; 0.860 / 0.860 | 0.887 / 0.877 ; 0.877 / 0.877 | 0.904 / 0.894 ; 0.894 / 0.894 | 0.922 / 0.911 ; 0.911 / 0.911 |
| Yaiba Semimaru | 0.940 / 0.940 ; 0.960 / 1.000 | 0.958 / 0.958 ; 0.979 / 1.000 | 0.977 / 0.977 ; 0.998 / 1.000 | 0.996 / 0.996 ; 1.000 / 1.000 |
| Brennan Apollo | 0.870 / 0.870 ; 0.940 / 0.910 | 0.887 / 0.887 ; 0.958 / 0.928 | 0.904 / 0.904 ; 0.977 / 0.946 | 0.922 / 0.922 ; 0.996 / 0.964 |
| Yaiba Kusanagi | 0.890 / 0.900 ; 0.920 / 0.900 | 0.907 / 0.917 ; 0.938 / 0.917 | 0.925 / 0.935 ; 0.956 / 0.935 | 0.943 / 0.953 ; 0.975 / 0.953 |

### Suspension (`springStiffness` and `swaybarStiffness`, front ; rear; dampers x sqrt of the spring factor)

| Model | Stock springs | s3 springs | Stock swaybar | s3 swaybar | Stock `springDamping` | s3 `springDamping` |
|---|---|---|---|---|---|---|
| Makigai MaiMai | 10 ; 14 | 11.5 ; 16.1 | 8 ; 8.5 | 9.2 ; 9.77 | 1700 ; 2100 | 1823 ; 2251 |
| Thorton Galena | 13 ; 9 | 14.95 ; 10.35 | 13 ; 7 | 14.95 ; 8.05 | 1900 ; 1500 | 2037 ; 1608 |
| Archer Hella | 20 ; 15 | 23 ; 17.25 | 20 ; 9 | 23 ; 10.35 | 2700 ; 2200 | 2895 ; 2359 |
| Thorton Colby | 21 ; 17 | 24.15 ; 19.55 | 25 ; 9 | 28.75 ; 10.35 | 2500 ; 2100 | 2680 ; 2251 |
| Mahir Supron | 20 ; 18 | 23 ; 20.7 | 19 ; 13 | 21.85 ; 14.95 | 3600 ; 3700 | 3860 ; 3967 |
| Archer Quartz | 14 ; 21 | 16.1 ; 24.15 | 16 ; 17 | 18.4 ; 19.55 | 1900 ; 2600 | 2037 ; 2788 |
| Mizutani Hozuki | 20 ; 15 | 23 ; 17.25 | 22 ; 14 | 25.3 ; 16.1 | 3700 ; 3200 | 3967 ; 3431 |
| Villefort Columbus | 26 ; 23 | 29.9 ; 26.45 | 22 ; 18 | 25.3 ; 20.7 | 3700 ; 3600 | 3967 ; 3860 |
| Villefort Cortes | 20 ; 18 | 23 ; 20.7 | 17 ; 15 | 19.55 ; 17.25 | 3300 ; 3200 | 3538 ; 3431 |
| Thorton Merrimac | 40 ; 43 | 46 ; 49.45 | 32 ; 17 | 36.8 ; 19.55 | 3600 ; 3800 | 3860 ; 4075 |
| Archer Bandit | 16 ; 22 | 18.4 ; 25.3 | 15.5 ; 17.5 | 17.82 ; 20.12 | 2000 ; 2800 | 2144 ; 3002 |
| Chevalier Thrax | 20 ; 18 | 23 ; 20.7 | 19 ; 17 | 21.85 ; 19.55 | 3600 ; 3500 | 3860 ; 3753 |
| Yaiba Semimaru | 21 ; 26 | 24.15 ; 29.9 | 29 ; 20 | 33.35 ; 23 | 4100 ; 4500 | 4396 ; 4825 |
| Brennan Apollo | unchanged (bike) | | | | | |
| Yaiba Kusanagi | unchanged (bike) | | | | | |

### Proposed prices (PROPOSAL, the owner decides)

Price of each stage = car price x 10 / 15 / 20 % x value weight, at least 1,000 / 1,500 / 2,000, rounded up to 500. Value weight = 0.5 + 0.5 x (engine share actually delivered), so a model whose engine is capped by the class ceiling pays less.

| Model | Car price | Value weight | s1 | s2 | s3 | All three |
|---|---:|---:|---:|---:|---:|---:|
| Makigai MaiMai | 10,000 | 0.67 | 1,000 | 1,500 | 2,000 | 4,500 |
| Thorton Galena | 16,000 | 0.68 | 1,500 | 2,000 | 2,500 | 6,000 |
| Archer Hella | 30,000 | 0.75 | 2,500 | 3,500 | 5,000 | 11,000 |
| Thorton Colby | 35,000 | 0.73 | 3,000 | 4,000 | 5,500 | 12,500 |
| Mahir Supron | 40,000 | 0.82 | 3,500 | 5,000 | 7,000 | 15,500 |
| Archer Quartz | 47,500 | 0.50 | 2,500 | 4,000 | 5,000 | 11,500 |
| Mizutani Hozuki | 60,000 | 1.00 | 6,000 | 9,000 | 12,000 | 27,000 |
| Villefort Columbus | 75,000 | 1.00 | 7,500 | 11,500 | 15,000 | 34,000 |
| Villefort Cortes | 95,000 | 1.00 | 9,500 | 14,500 | 19,000 | 43,000 |
| Thorton Merrimac | 115,000 | 1.00 | 11,500 | 17,500 | 23,000 | 52,000 |
| Archer Bandit | 130,000 | 0.84 | 11,000 | 16,500 | 22,000 | 49,500 |
| Chevalier Thrax | 155,000 | 1.00 | 15,500 | 23,500 | 31,000 | 70,000 |
| Yaiba Semimaru | 250,000 | 1.00 | 25,000 | 37,500 | 50,000 | 112,500 |
| Brennan Apollo | 12,500 | 0.70 | 1,000 | 1,500 | 2,000 | 4,500 |
| Yaiba Kusanagi | 200,000 | 1.00 | 20,000 | 30,000 | 40,000 | 90,000 |

<!-- END GENERATED -->

## Prices are a proposal

Prices are the owner's decision. The proposal above prices each stage at 10 / 15 / 20 % of the
car's dealer price (45 % for all three), weighted by how much engine the stage really delivers
(a capped model pays less), with floors of 1,000 / 1,500 / 2,000. The intent: a full stage 3
always costs more than the gap a player would close by staging, and the next class's car stays
the better buy because the class ceiling keeps the staged car under it.

## Extended models (every vanilla player car and bike)

Besides the 15 dealer models, the pack stages every other vanilla `Vehicle.*_player*` record of the
installed game, cars and bikes, one entry per record: a trim (`_player_02`, `_player_03`) or a
story variant (`_player_missiles`, `_player_mr_hands`) is its own record and its own entry. They get
the same three stages, the same caps and policy, and the engine sounds of their class (12 for a car,
4 for a bike), exactly like the dealer models.

- **Scope** (`make_stages.py --refresh-models --names <tweakdbstr.kark>`): every
  `gamedataVehicle_Record` of `tweakdb.bin` + `tweakdb_ep1.bin` whose name in WolvenKit's string
  table matches `Vehicle.*_player*`, minus: a **quest variant**, any record named `Vehicle.q<digits>_*`
  (a mission's copy of a car, the owner's decision of 2026-11-07: `q000_hym_player_car` and
  `q304_songbird_escape_player` on 2.50), an AV (`av` token), a Panzer-class record, any class
  other than Car or Bike, a record without `entityTemplatePath`, and a record whose stage chain
  (engine, drive model, wheel setup, both wheel presets) is incomplete; each exclusion is listed
  with its reason in `extended-models.json`. A few Vehicle records have no name in the string
  table; a name cannot be guessed from an id, so they are counted, not staged.
- **The dealer models are frozen.** Their records, prices, ladder and stages do not move: their
  class ceilings are computed among the 15 alone, as before. Both YAMLs write them first, then a
  `# ==== Extended models` marker, then the extended models, so a dealer-only build's YAML is a
  byte prefix of the full one (`test_engine_sounds.py` rebuilds it and compares the bytes).
- **Light RP price.** An extended model's vanilla reference price (below) is on the game's scale,
  about half Light RP's: Light RP's dealer prices are 0.42x to 4.56x the vanilla price of the same
  record, median 1.94x. The generator multiplies it by **`EXTENDED_PRICE_FACTOR` = 2.0** (that
  median, rounded) before anything reads it: the tier and the stage prices both use the Light RP
  price. Dealer models keep their dealer price.
- **Extended ladder.** An extended model's tier is read from its Light RP price on the same
  thresholds (cars 20,000 / 50,000 / 100,000 / 200,000; bikes 100,000), and its class ceiling is the
  lowest best specific torque of the higher tiers among every staged record, the dealer models
  included (placed by their dealer price).
- **Reference price**, the first rule that answers, all read from `tweakdb.bin`:
  1. *offer*: the record's own vanilla Autofixer offer, a `gamedataVehicleOffer_Record` whose
     `price` names an `EconomicAssignment.*` record; the price is its `overrideValue` (Int32);
  2. *template*: the cheapest offer among the staged records with the same `entityTemplatePath`
     (a trim or story variant of an offered body);
  3. *class*: the median (low) offer price of the body class (`v_sport2_…` → `sport2`);
  4. *ladder*: the median (low) offer price of the ladder (car or bike).

  An offer is tied to its record by, in order: its `EconomicAssignment` name with the prefix swapped;
  the same name tokens once the body class is dropped (`v_sportbike2_arch_02_player` =
  `v_sportbike2_arch_player_02`); its `name` LocKey equal to the record's `displayName`. Each tie
  must be unique; an offer tied to nothing is listed as unmatched, never guessed.
- **Stage price**: the dealer formula above (10 / 15 / 20 % x value weight, floors 1,000 / 1,500 /
  2,000, rounded up to 500) with the Light RP price in place of the dealer price, then **capped** at
  the highest dealer price of that stage in the class: the Semimaru's 25,000 / 37,500 / 50,000 for a
  car, the Kusanagi's 20,000 / 30,000 / 40,000 for a bike (`dealer_price_caps`, recomputed from the
  dealer models on every run). An extended stage never costs more than the dearest dealer stage.
- **Owner decision, 2026-11-07.** Prices on Light RP's scale (factor 2.0, dealer caps above) and the
  quest variants out. A model's prices can still be set by hand in
  `LightRpCustomizationPricing.performance` (a catalogue key there overrides the generated price).

<!-- BEGIN GENERATED EXTENDED: make_stages.py --update-doc -->

71 extended records (58 cars, 13 bikes) besides the 15 dealer models; 2 in-scope record(s) excluded; 65 vanilla offers tied to a record, 0 unmatched; 3 Vehicle record(s) of tweakdb.bin have no name in WolvenKit's string table (none of them can be a named `_player` record).

- excluded: `Vehicle.q000_hym_player_car`: quest variant (Vehicle.q<digits>_*)
- excluded: `Vehicle.q304_songbird_escape_player`: quest variant (Vehicle.q<digits>_*)

### Extended models: reference price and proposed stage prices (PROPOSAL, the owner decides)

Light RP price = vanilla reference price x 2; the tier and the stage prices read it. Each stage is then capped at the highest dealer price of that stage in the class (car: 25,000 / 37,500 / 50,000; bike: 20,000 / 30,000 / 40,000); `Capped` lists the stages the cap lowered.

| Model | Record | Ladder, tier | Vanilla reference | Source | Light RP price | Value weight | s1 | s2 | s3 | All three | Capped |
|---|---|---|---:|---|---:|---:|---:|---:|---:|---:|---|
| Herrera Outlaw Heist | `Vehicle.v_sport1_herrera_outlaw_heist_player` | car T5 | 105,000 | offer Vehicle.herrera_outlaw_courier_outro_failed_offer | 210,000 | 1.00 | 21,000 | 31,500 | 42,000 | 94,500 | - |
| Herrera Outlaw | `Vehicle.v_sport1_herrera_outlaw_player` | car T4 | 92,000 | offer Vehicle.herrera_outlaw_offer | 184,000 | 0.77 | 14,500 | 21,500 | 28,500 | 64,500 | - |
| Herrera Riptide | `Vehicle.v_sport1_herrera_riptide_player` | car T5 | 108,000 | offer Vehicle.herrera_riptide_offer | 216,000 | 1.00 | 22,000 | 32,500 | 43,500 | 98,000 | - |
| Quadra Sport R7 | `Vehicle.v_sport1_quadra_sport_r7_player` | car T4 | 81,000 | offer Vehicle.quadra_sport_r_7_offer | 162,000 | 0.78 | 13,000 | 19,000 | 25,500 | 57,500 | - |
| Quadra Sport R7 Player 02 | `Vehicle.v_sport1_quadra_sport_r7_player_02` | car T4 | 86,000 | offer Vehicle.quadra_sport_r_7_02_offer | 172,000 | 0.78 | 13,500 | 20,500 | 27,000 | 61,000 | - |
| Quadra Turbo-R | `Vehicle.v_sport1_quadra_turbo_player` | car T4 | 69,000 | offer Vehicle.quadra_turbo_r_offer | 138,000 | 0.92 | 13,000 | 19,500 | 26,000 | 58,500 | - |
| Quadra Turbo R | `Vehicle.v_sport1_quadra_turbo_r_player` | car T4 | 69,000 | template Vehicle.v_sport1_quadra_turbo_player | 138,000 | 0.75 | 10,500 | 15,500 | 21,000 | 47,000 | - |
| Rayfield Aerondight | `Vehicle.v_sport1_rayfield_aerondight_player` | car T5 | 155,000 | offer Vehicle.rayfield_aerondight_offer | 310,000 | 1.00 | 25,000 | 37,500 | 50,000 | 112,500 | s1, s2, s3 |
| Rayfield Caliburn | `Vehicle.v_sport1_rayfield_caliburn_02_player` | car T5 | 135,000 | template Vehicle.v_sport1_rayfield_caliburn_player | 270,000 | 1.00 | 25,000 | 37,500 | 50,000 | 112,500 | s1, s2, s3 |
| Rayfield Caliburn Mordred | `Vehicle.v_sport1_rayfield_caliburn_mordred_player` | car T5 | 135,000 | template Vehicle.v_sport1_rayfield_caliburn_player | 270,000 | 1.00 | 25,000 | 37,500 | 50,000 | 112,500 | s1, s2, s3 |
| Rayfield Caliburn | `Vehicle.v_sport1_rayfield_caliburn_player` | car T5 | 135,000 | offer Vehicle.rayfield_caliburn_offer | 270,000 | 1.00 | 25,000 | 37,500 | 50,000 | 112,500 | s1, s2, s3 |
| Mizutani Shion Base | `Vehicle.v_sport2_mizutani_shion_base_player` | car T3 | 43,000 | offer Vehicle.mizutani_shion_base_offer | 86,000 | 0.99 | 9,000 | 13,000 | 17,500 | 39,500 | - |
| Mizutani Shion Nomad 02 | `Vehicle.v_sport2_mizutani_shion_nomad_02_player` | car T4 | 77,000 | template Vehicle.v_sport2_mizutani_shion_nomad_player | 154,000 | 0.97 | 15,000 | 22,500 | 30,000 | 67,500 | - |
| Mizutani Shion Nomad | `Vehicle.v_sport2_mizutani_shion_nomad_player` | car T4 | 77,000 | offer Vehicle.mizutani_shion_nomad_offer | 154,000 | 0.66 | 10,500 | 15,500 | 20,500 | 46,500 | - |
| Mizutani Shion Nomad Player Missiles | `Vehicle.v_sport2_mizutani_shion_nomad_player_missiles` | car T4 | 87,000 | offer Vehicle.mizutani_shion_nomad_missiles_offer | 174,000 | 0.97 | 17,000 | 25,500 | 34,000 | 76,500 | - |
| Mizutani Shion | `Vehicle.v_sport2_mizutani_shion_player` | car T4 | 57,000 | offer Vehicle.mizutani_shion_offer | 114,000 | 0.67 | 8,000 | 11,500 | 15,500 | 35,000 | - |
| Mizutani Shion Targa | `Vehicle.v_sport2_mizutani_shion_targa_player` | car T4 | 61,000 | offer Vehicle.mizutani_shion_targa_offer | 122,000 | 0.71 | 9,000 | 13,000 | 17,500 | 39,500 | - |
| Porsche 911Turbo Cabrio | `Vehicle.v_sport2_porsche_911turbo_cabrio_player` | car T4 | 73,000 | offer Vehicle.v_sport2_porsche_911turbo_cabrio_offer | 146,000 | 0.96 | 14,500 | 21,500 | 28,500 | 64,500 | - |
| Porsche 911 Turbo | `Vehicle.v_sport2_porsche_911turbo_player` | car T4 | 57,000 | class sport2 (17 offers) | 114,000 | 0.87 | 10,000 | 15,000 | 20,000 | 45,000 | - |
| Quadra Type-66 | `Vehicle.v_sport2_quadra_type66_02_player` | car T3 | 40,000 | template Vehicle.v_sport2_quadra_type66_base_player | 80,000 | 1.00 | 8,000 | 12,000 | 16,000 | 36,000 | - |
| Quadra Type66 Avenger | `Vehicle.v_sport2_quadra_type66_avenger_player` | car T4 | 75,000 | offer Vehicle.quadra_type_66_avenger_offer | 150,000 | 0.53 | 8,000 | 12,000 | 16,000 | 36,000 | - |
| Quadra Type66 Base | `Vehicle.v_sport2_quadra_type66_base_player` | car T3 | 40,000 | offer Vehicle.quadra_type_66_base_offer | 80,000 | 1.00 | 8,000 | 12,000 | 16,000 | 36,000 | - |
| Quadra Type66 Gt | `Vehicle.v_sport2_quadra_type66_gt_player` | car T4 | 50,000 | offer Vehicle.quadra_type_66_gt_offer | 100,000 | 0.84 | 8,500 | 13,000 | 17,000 | 38,500 | - |
| Quadra Type66 Nomad Ncu | `Vehicle.v_sport2_quadra_type66_nomad_ncu_player` | car T4 | 67,000 | offer Vehicle.quadra_type_66_nc_deathrace_offer | 134,000 | 0.66 | 9,000 | 13,500 | 18,000 | 40,500 | - |
| Quadra Type66 Nomad | `Vehicle.v_sport2_quadra_type66_nomad_player` | car T4 | 99,000 | offer Vehicle.quadra_type_1_offer | 198,000 | 0.52 | 10,500 | 15,500 | 21,000 | 47,000 | - |
| Quadra Type66 Nomad Player 03 | `Vehicle.v_sport2_quadra_type66_nomad_player_03` | car T4 | 99,000 | offer Vehicle.quadra_type_66_nomad_03_offer | 198,000 | 0.52 | 10,500 | 15,500 | 21,000 | 47,000 | - |
| Quadra Type-66 | `Vehicle.v_sport2_quadra_type66_player` | car T4 | 52,000 | offer Vehicle.quadra_type_66_offer | 104,000 | 0.83 | 9,000 | 13,000 | 17,500 | 39,500 | - |
| Villefort Alvarado Hearse | `Vehicle.v_sport2_villefort_alvarado_hearse_player` | car T3 | 39,000 | offer Vehicle.alvarado_hearse_combi_offer | 78,000 | 1.00 | 8,000 | 12,000 | 16,000 | 36,000 | - |
| Villefort Alvarado | `Vehicle.v_sport2_villefort_alvarado_player` | car T3 | 38,000 | offer Vehicle.villefort_alvarado_offer | 76,000 | 1.00 | 8,000 | 11,500 | 15,500 | 35,000 | - |
| Villefort Alvarado Valentinos | `Vehicle.v_sport2_villefort_alvarado_valentinos_player` | car T4 | 57,000 | class sport2 (17 offers) | 114,000 | 1.00 | 11,500 | 17,500 | 23,000 | 52,000 | - |
| Villefort Deleon | `Vehicle.v_sport2_villefort_deleon_player` | car T3 | 36,000 | offer Vehicle.villefort_deleon_offer | 72,000 | 1.00 | 7,500 | 11,000 | 14,500 | 33,000 | - |
| Villefort Deleon Sport | `Vehicle.v_sport2_villefort_deleon_sport_player` | car T3 | 26,000 | offer Vehicle.villefort_deleon_sport_offer | 52,000 | 1.00 | 5,500 | 8,000 | 10,500 | 24,000 | - |
| Yaiba Kusanagi Player 02 | `Vehicle.v_sportbike1_yaiba_kusanagi_player_02` | bike T2 | 75,000 | offer Vehicle.yaiba_kusanagi_02_offer | 150,000 | 1.00 | 15,000 | 22,500 | 30,000 | 67,500 | - |
| Yaiba Kusanagi Player 03 | `Vehicle.v_sportbike1_yaiba_kusanagi_player_03` | bike T2 | 72,000 | offer Vehicle.yaiba_kusanagi_03_offer | 144,000 | 1.00 | 14,500 | 22,000 | 29,000 | 65,500 | - |
| Yaiba Kusanagi Tyger | `Vehicle.v_sportbike1_yaiba_kusanagi_tyger_player` | bike T2 | 66,000 | template Vehicle.v_sportbike1_yaiba_kusanagi_player | 132,000 | 1.00 | 13,500 | 20,000 | 26,500 | 60,000 | - |
| Yaiba Muramasa | `Vehicle.v_sportbike1_yaiba_muramasa_player` | bike T2 | 75,000 | offer Vehicle.yaiba_muramasa_offer | 150,000 | 1.00 | 15,000 | 22,500 | 30,000 | 67,500 | - |
| Arch Jackie | `Vehicle.v_sportbike2_arch_jackie_player` | bike T2 | 68,000 | template Vehicle.v_sportbike2_arch_player_03 | 136,000 | 1.00 | 14,000 | 20,500 | 27,500 | 62,000 | - |
| Arch Jackie Tuned | `Vehicle.v_sportbike2_arch_jackie_tuned_player` | bike T2 | 68,000 | template Vehicle.v_sportbike2_arch_player_03 | 136,000 | 1.00 | 14,000 | 20,500 | 27,500 | 62,000 | - |
| Arch Linas | `Vehicle.v_sportbike2_arch_linas_player` | bike T2 | 71,000 | class sportbike2 (3 offers) | 142,000 | 1.00 | 14,500 | 21,500 | 28,500 | 64,500 | - |
| Arch | `Vehicle.v_sportbike2_arch_player` | bike T2 | 71,000 | offer Vehicle.arch_nemesis_offer | 142,000 | 1.00 | 14,500 | 21,500 | 28,500 | 64,500 | - |
| Arch Player 02 | `Vehicle.v_sportbike2_arch_player_02` | bike T2 | 74,000 | offer Vehicle.arch_nemesis_02_offer | 148,000 | 1.00 | 15,000 | 22,500 | 30,000 | 67,500 | - |
| Arch Player 03 | `Vehicle.v_sportbike2_arch_player_03` | bike T2 | 68,000 | offer Vehicle.arch_nemesis_03_offer | 136,000 | 1.00 | 14,000 | 20,500 | 27,500 | 62,000 | - |
| Arch Tyger | `Vehicle.v_sportbike2_arch_tyger_player` | bike T2 | 68,000 | template Vehicle.v_sportbike2_arch_player_03 | 136,000 | 1.00 | 14,000 | 20,500 | 27,500 | 62,000 | - |
| Brennan Apollo Nomad | `Vehicle.v_sportbike3_brennan_apollo_nomad_player` | bike T1 | 30,000 | template Vehicle.v_sportbike3_brennan_apollo_player | 60,000 | 1.00 | 6,000 | 9,000 | 12,000 | 27,000 | - |
| Brennan Apollo Player 02 | `Vehicle.v_sportbike3_brennan_apollo_player_02` | bike T1 | 36,000 | offer Vehicle.brennan_apollo_02_offer | 72,000 | 1.00 | 7,500 | 11,000 | 14,500 | 33,000 | - |
| Mahir Supron Gt | `Vehicle.v_standard25_mahir_supron_gt_player` | car T3 | 26,000 | offer Vehicle.mahir_supron_gt_offer | 52,000 | 1.00 | 5,500 | 8,000 | 10,500 | 24,000 | - |
| Thorton Colby Nomad | `Vehicle.v_standard25_thorton_colby_nomad_player` | car T3 | 41,000 | offer Vehicle.thorton_colby_pickup_nomad_offer | 82,000 | 1.00 | 8,500 | 12,500 | 16,500 | 37,500 | - |
| Thorton Colby Nomad Player Missiles | `Vehicle.v_standard25_thorton_colby_nomad_player_missiles` | car T4 | 56,000 | offer Vehicle.thorton_colby_nomad_missiles_offer | 112,000 | 1.00 | 11,500 | 17,000 | 22,500 | 51,000 | - |
| Thorton Colby Pickup 02 | `Vehicle.v_standard25_thorton_colby_pickup_02_player` | car T3 | 25,000 | template Vehicle.v_standard25_thorton_colby_pickup_player | 50,000 | 1.00 | 5,000 | 7,500 | 10,000 | 22,500 | - |
| Thorton Colby Pickup Kurtz | `Vehicle.v_standard25_thorton_colby_pickup_kurtz_player` | car T3 | 29,000 | offer Vehicle.kurtz_men_military_colby_offer | 58,000 | 1.00 | 6,000 | 9,000 | 12,000 | 27,000 | - |
| Thorton Colby Pickup | `Vehicle.v_standard25_thorton_colby_pickup_player` | car T3 | 25,000 | offer Vehicle.thorton_colby_pickup_offer | 50,000 | 1.00 | 5,000 | 7,500 | 10,000 | 22,500 | - |
| Archer Quartz Base | `Vehicle.v_standard2_archer_quartz_base_player` | car T2 | 21,000 | offer Vehicle.archer_quartz_base_offer | 42,000 | 0.87 | 4,000 | 5,500 | 7,500 | 17,000 | - |
| Archer Quartz Nomad | `Vehicle.v_standard2_archer_quartz_nomad_player` | car T4 | 90,000 | offer Vehicle.archer_quartz_nomad_offer | 180,000 | 0.66 | 12,000 | 18,000 | 24,000 | 54,000 | - |
| Archer Quartz Nomad Player 02 | `Vehicle.v_standard2_archer_quartz_nomad_player_02` | car T4 | 79,000 | offer Vehicle.archer_quartz_nomad_02_offer | 158,000 | 0.66 | 10,500 | 16,000 | 21,000 | 47,500 | - |
| Mizutani Hozuki Gt | `Vehicle.v_standard2_mizutani_hozuki_gt_player` | car T3 | 29,000 | offer Vehicle.mizutani_hozuki_gt_offer | 58,000 | 1.00 | 6,000 | 9,000 | 12,000 | 27,000 | - |
| Thorton Colby Gt | `Vehicle.v_standard2_thorton_colby_gt_player` | car T3 | 33,000 | offer Vehicle.thorton_colby_gt_offer | 66,000 | 1.00 | 7,000 | 10,000 | 13,500 | 30,500 | - |
| Thorton Galena Bobas | `Vehicle.v_standard2_thorton_galena_bobas_player` | car T2 | 13,000 | template Vehicle.v_standard2_thorton_galena_player | 26,000 | 0.66 | 2,000 | 3,000 | 3,500 | 8,500 | - |
| Thorton Galena Gt | `Vehicle.v_standard2_thorton_galena_gt_player` | car T3 | 26,000 | offer Vehicle.thorton_galena_gt_offer | 52,000 | 1.00 | 5,500 | 8,000 | 10,500 | 24,000 | - |
| Thorton Galena Nomad | `Vehicle.v_standard2_thorton_galena_nomad_player` | car T3 | 45,000 | offer Vehicle.thorton_galena_nomad_offer | 90,000 | 1.00 | 9,000 | 13,500 | 18,000 | 40,500 | - |
| Thorton Galena Nomad Player Missiles | `Vehicle.v_standard2_thorton_galena_nomad_player_missiles` | car T4 | 60,000 | offer Vehicle.thorton_galena_nomad_missiles_offer | 120,000 | 1.00 | 12,000 | 18,000 | 24,000 | 54,000 | - |
| Villefort Cortes Delamain | `Vehicle.v_standard2_villefort_cortes_delamain_player` | car T3 | 31,000 | class standard2 (16 offers) | 62,000 | 1.00 | 6,500 | 9,500 | 12,500 | 28,500 | - |
| Chevalier Emperor | `Vehicle.v_standard3_chevalier_emperor_player` | car T3 | 38,000 | offer Vehicle.chevallion_emperor_police_offer | 76,000 | 1.00 | 8,000 | 11,500 | 15,500 | 35,000 | - |
| Mahir Supron Kurtz | `Vehicle.v_standard3_mahir_supron_kurtz_player` | car T4 | 94,000 | offer Vehicle.kurtz_men_military_supron_offer | 188,000 | 1.00 | 19,000 | 28,500 | 38,000 | 85,500 | - |
| Makigai Tanishi | `Vehicle.v_standard3_makigai_tanishi_player` | car T3 | 35,000 | offer Vehicle.makigai_tanishi_offer | 70,000 | 1.00 | 7,000 | 10,500 | 14,000 | 31,500 | - |
| Makigai Tanishi Player Mr Hands | `Vehicle.v_standard3_makigai_tanishi_player_mr_hands` | car T3 | 38,000 | class standard3 (5 offers) | 76,000 | 1.00 | 8,000 | 11,500 | 15,500 | 35,000 | - |
| Militech Hellhound | `Vehicle.v_standard3_militech_hellhound_player` | car T5 | 150,000 | offer Vehicle.militech_hellhound_offer | 300,000 | 1.00 | 25,000 | 37,500 | 50,000 | 112,500 | s1, s2, s3 |
| Thorton Mackinaw 02 | `Vehicle.v_standard3_thorton_mackinaw_02_player` | car T3 | 38,000 | class standard3 (5 offers) | 76,000 | 1.00 | 8,000 | 11,500 | 15,500 | 35,000 | - |
| Thorton Mackinaw Ncu | `Vehicle.v_standard3_thorton_mackinaw_ncu_player` | car T3 | 38,000 | class standard3 (5 offers) | 76,000 | 1.00 | 8,000 | 11,500 | 15,500 | 35,000 | - |
| Thorton Mackinaw | `Vehicle.v_standard3_thorton_mackinaw_player` | car T3 | 33,000 | offer Vehicle.thorton_mackinaw_offer | 66,000 | 1.00 | 7,000 | 10,000 | 13,500 | 30,500 | - |
| Chevalier Legatus | `Vehicle.v_utility4_chevalier_legatus_player` | car T4 | 55,000 | offer Vehicle.chevillion_legatus_offer | 110,000 | 1.00 | 11,000 | 16,500 | 22,000 | 49,500 | - |
| Thorton Mackinaw Bmf | `Vehicle.v_utility4_thorton_mackinaw_bmf_player` | car T4 | 55,000 | class utility4 (1 offers) | 110,000 | 1.00 | 11,000 | 16,500 | 22,000 | 49,500 | - |

### Extended models: engine cap

Class ceilings of the extended ladder: every staged record placed on its tier by its Light RP price (the dealer price for a dealer model, the scaled vanilla reference price for the others). Brakes, grip and suspension follow the stage policy unchanged (stages-manifest.json lists every value).

| Model | Top speed (rated) | Torque | Specific torque | Class ceiling | Engine s1 / s2 / s3 | Engine cap |
|---|---:|---:|---:|---:|---|---|
| Herrera Outlaw Heist | 154.8 km/h | 710 Nm | 363.4 Nm/t | none (top tier) | x1.200 / x1.400 / x1.600 | stage policy |
| Herrera Outlaw | 154.8 km/h | 710 Nm | 363.4 Nm/t | 482.7 Nm/t | x1.109 / x1.219 / x1.328 | class ceiling |
| Herrera Riptide | 160.2 km/h | 740 Nm | 480.3 Nm/t | none (top tier) | x1.200 / x1.400 / x1.600 | stage policy |
| Quadra Sport R7 | 154.8 km/h | 765 Nm | 360.9 Nm/t | 482.7 Nm/t | x1.113 / x1.225 / x1.338 | class ceiling |
| Quadra Sport R7 Player 02 | 154.8 km/h | 765 Nm | 360.9 Nm/t | 482.7 Nm/t | x1.113 / x1.225 / x1.338 | class ceiling |
| Quadra Turbo-R | 151.2 km/h | 470 Nm | 319.7 Nm/t | 482.7 Nm/t | x1.170 / x1.340 / x1.510 | class ceiling |
| Quadra Turbo R | 154.8 km/h | 600 Nm | 372.0 Nm/t | 482.7 Nm/t | x1.099 / x1.198 / x1.298 | class ceiling |
| Rayfield Aerondight | 160.2 km/h | 950 Nm | 475.0 Nm/t | none (top tier) | x1.200 / x1.400 / x1.600 | stage policy |
| Rayfield Caliburn | 162.0 km/h | 960 Nm | 482.7 Nm/t | none (top tier) | x1.200 / x1.400 / x1.600 | stage policy |
| Rayfield Caliburn Mordred | 162.0 km/h | 960 Nm | 482.7 Nm/t | none (top tier) | x1.200 / x1.400 / x1.600 | stage policy |
| Rayfield Caliburn | 162.0 km/h | 960 Nm | 482.7 Nm/t | none (top tier) | x1.200 / x1.400 / x1.600 | stage policy |
| Mizutani Shion Base | 151.2 km/h | 451 Nm | 297.7 Nm/t | 472.2 Nm/t | x1.195 / x1.391 / x1.586 | class ceiling |
| Mizutani Shion Nomad 02 | 151.2 km/h | 500 Nm | 309.4 Nm/t | 482.7 Nm/t | x1.187 / x1.374 / x1.560 | class ceiling |
| Mizutani Shion Nomad | 154.8 km/h | 650 Nm | 406.2 Nm/t | 482.7 Nm/t | x1.063 / x1.126 / x1.188 | class ceiling |
| Mizutani Shion Nomad Player Missiles | 151.2 km/h | 500 Nm | 309.4 Nm/t | 482.7 Nm/t | x1.187 / x1.374 / x1.560 | class ceiling |
| Mizutani Shion | 154.8 km/h | 600 Nm | 400.0 Nm/t | 482.7 Nm/t | x1.069 / x1.138 / x1.207 | class ceiling |
| Mizutani Shion Targa | 154.8 km/h | 600 Nm | 385.6 Nm/t | 482.7 Nm/t | x1.084 / x1.168 / x1.252 | class ceiling |
| Porsche 911Turbo Cabrio | 146.9 km/h | 431 Nm | 310.1 Nm/t | 482.7 Nm/t | x1.186 / x1.371 / x1.557 | class ceiling |
| Porsche 911 Turbo | 146.9 km/h | 431 Nm | 334.1 Nm/t | 482.7 Nm/t | x1.148 / x1.297 / x1.445 | class ceiling |
| Quadra Type-66 | 147.6 km/h | 500 Nm | 288.2 Nm/t | 472.2 Nm/t | x1.200 / x1.400 / x1.600 | stage policy |
| Quadra Type66 Avenger | 160.2 km/h | 870 Nm | 465.9 Nm/t | 482.7 Nm/t | x1.012 / x1.024 / x1.036 | class ceiling |
| Quadra Type66 Base | 147.6 km/h | 500 Nm | 288.2 Nm/t | 472.2 Nm/t | x1.200 / x1.400 / x1.600 | stage policy |
| Quadra Type66 Gt | 147.6 km/h | 660 Nm | 343.3 Nm/t | 482.7 Nm/t | x1.135 / x1.271 / x1.406 | class ceiling |
| Quadra Type66 Nomad Ncu | 154.8 km/h | 700 Nm | 405.8 Nm/t | 482.7 Nm/t | x1.063 / x1.126 / x1.190 | class ceiling |
| Quadra Type66 Nomad | 160.2 km/h | 1000 Nm | 472.2 Nm/t | 482.7 Nm/t | x1.007 / x1.015 / x1.022 | class ceiling |
| Quadra Type66 Nomad Player 03 | 160.2 km/h | 1000 Nm | 472.2 Nm/t | 482.7 Nm/t | x1.007 / x1.015 / x1.022 | class ceiling |
| Quadra Type-66 | 147.6 km/h | 660 Nm | 345.5 Nm/t | 482.7 Nm/t | x1.132 / x1.265 / x1.397 | class ceiling |
| Villefort Alvarado Hearse | 126.0 km/h | 380 Nm | 134.4 Nm/t | 472.2 Nm/t | x1.200 / x1.400 / x1.600 | stage policy |
| Villefort Alvarado | 126.0 km/h | 380 Nm | 137.4 Nm/t | 472.2 Nm/t | x1.200 / x1.400 / x1.600 | stage policy |
| Villefort Alvarado Valentinos | 126.0 km/h | 380 Nm | 137.4 Nm/t | 482.7 Nm/t | x1.200 / x1.400 / x1.600 | stage policy |
| Villefort Deleon | 140.4 km/h | 510 Nm | 235.6 Nm/t | 472.2 Nm/t | x1.200 / x1.400 / x1.600 | stage policy |
| Villefort Deleon Sport | 126.0 km/h | 300 Nm | 147.7 Nm/t | 472.2 Nm/t | x1.200 / x1.400 / x1.600 | stage policy |
| Yaiba Kusanagi Player 02 | 151.2 km/h | 185 Nm | 381.6 Nm/t | none (top tier) | x1.100 / x1.200 / x1.300 | stage policy |
| Yaiba Kusanagi Player 03 | 151.2 km/h | 185 Nm | 373.8 Nm/t | none (top tier) | x1.100 / x1.200 / x1.300 | stage policy |
| Yaiba Kusanagi Tyger | 151.2 km/h | 185 Nm | 373.8 Nm/t | none (top tier) | x1.100 / x1.200 / x1.300 | stage policy |
| Yaiba Muramasa | 151.2 km/h | 185 Nm | 366.3 Nm/t | none (top tier) | x1.100 / x1.200 / x1.300 | stage policy |
| Arch Jackie | 144.0 km/h | 175 Nm | 414.5 Nm/t | none (top tier) | x1.100 / x1.200 / x1.300 | stage policy |
| Arch Jackie Tuned | 144.0 km/h | 183 Nm | 419.0 Nm/t | none (top tier) | x1.100 / x1.200 / x1.300 | stage policy |
| Arch Linas | 144.0 km/h | 175 Nm | 414.5 Nm/t | none (top tier) | x1.100 / x1.200 / x1.300 | stage policy |
| Arch | 144.0 km/h | 175 Nm | 414.5 Nm/t | none (top tier) | x1.100 / x1.200 / x1.300 | stage policy |
| Arch Player 02 | 144.0 km/h | 175 Nm | 425.7 Nm/t | none (top tier) | x1.100 / x1.200 / x1.300 | stage policy |
| Arch Player 03 | 144.0 km/h | 175 Nm | 414.5 Nm/t | none (top tier) | x1.100 / x1.200 / x1.300 | stage policy |
| Arch Tyger | 144.0 km/h | 175 Nm | 414.5 Nm/t | none (top tier) | x1.100 / x1.200 / x1.300 | stage policy |
| Brennan Apollo Nomad | 118.8 km/h | 140 Nm | 326.7 Nm/t | 425.7 Nm/t | x1.100 / x1.200 / x1.300 | stage policy |
| Brennan Apollo Player 02 | 118.8 km/h | 150 Nm | 325.0 Nm/t | 425.7 Nm/t | x1.100 / x1.200 / x1.300 | stage policy |
| Mahir Supron Gt | 133.2 km/h | 270 Nm | 168.8 Nm/t | 472.2 Nm/t | x1.200 / x1.400 / x1.600 | stage policy |
| Thorton Colby Nomad | 151.2 km/h | 450 Nm | 264.7 Nm/t | 472.2 Nm/t | x1.200 / x1.400 / x1.600 | stage policy |
| Thorton Colby Nomad Player Missiles | 151.2 km/h | 450 Nm | 264.7 Nm/t | 482.7 Nm/t | x1.200 / x1.400 / x1.600 | stage policy |
| Thorton Colby Pickup 02 | 115.2 km/h | 275 Nm | 166.7 Nm/t | 472.2 Nm/t | x1.200 / x1.400 / x1.600 | stage policy |
| Thorton Colby Pickup Kurtz | 115.2 km/h | 295 Nm | 125.5 Nm/t | 472.2 Nm/t | x1.200 / x1.400 / x1.600 | stage policy |
| Thorton Colby Pickup | 115.2 km/h | 275 Nm | 166.7 Nm/t | 472.2 Nm/t | x1.200 / x1.400 / x1.600 | stage policy |
| Archer Quartz Base | 122.4 km/h | 230 Nm | 206.3 Nm/t | 297.7 Nm/t | x1.148 / x1.295 / x1.443 | class ceiling |
| Archer Quartz Nomad | 151.2 km/h | 660 Nm | 406.2 Nm/t | 482.7 Nm/t | x1.063 / x1.126 / x1.189 | class ceiling |
| Archer Quartz Nomad Player 02 | 151.2 km/h | 660 Nm | 406.2 Nm/t | 482.7 Nm/t | x1.063 / x1.126 / x1.189 | class ceiling |
| Mizutani Hozuki Gt | 133.2 km/h | 260 Nm | 166.7 Nm/t | 472.2 Nm/t | x1.200 / x1.400 / x1.600 | stage policy |
| Thorton Colby Gt | 133.2 km/h | 300 Nm | 185.2 Nm/t | 472.2 Nm/t | x1.200 / x1.400 / x1.600 | stage policy |
| Thorton Galena Bobas | 133.2 km/h | 340 Nm | 251.0 Nm/t | 297.7 Nm/t | x1.062 / x1.124 / x1.186 | class ceiling |
| Thorton Galena Gt | 122.4 km/h | 215 Nm | 195.5 Nm/t | 472.2 Nm/t | x1.200 / x1.400 / x1.600 | stage policy |
| Thorton Galena Nomad | 147.6 km/h | 450 Nm | 257.1 Nm/t | 472.2 Nm/t | x1.200 / x1.400 / x1.600 | stage policy |
| Thorton Galena Nomad Player Missiles | 147.6 km/h | 450 Nm | 257.1 Nm/t | 482.7 Nm/t | x1.200 / x1.400 / x1.600 | stage policy |
| Villefort Cortes Delamain | 126.0 km/h | 415 Nm | 150.5 Nm/t | 472.2 Nm/t | x1.200 / x1.400 / x1.600 | stage policy |
| Chevalier Emperor | 126.0 km/h | 500 Nm | 174.8 Nm/t | 472.2 Nm/t | x1.200 / x1.400 / x1.600 | stage policy |
| Mahir Supron Kurtz | 115.2 km/h | 445 Nm | 183.6 Nm/t | 482.7 Nm/t | x1.200 / x1.400 / x1.600 | stage policy |
| Makigai Tanishi | 115.2 km/h | 310 Nm | 207.4 Nm/t | 472.2 Nm/t | x1.200 / x1.400 / x1.600 | stage policy |
| Makigai Tanishi Player Mr Hands | 115.2 km/h | 270 Nm | 180.6 Nm/t | 472.2 Nm/t | x1.200 / x1.400 / x1.600 | stage policy |
| Militech Hellhound | 126.0 km/h | 480 Nm | 137.1 Nm/t | none (top tier) | x1.200 / x1.400 / x1.600 | stage policy |
| Thorton Mackinaw 02 | 129.6 km/h | 570 Nm | 199.5 Nm/t | 472.2 Nm/t | x1.200 / x1.400 / x1.600 | stage policy |
| Thorton Mackinaw Ncu | 129.6 km/h | 570 Nm | 199.5 Nm/t | 472.2 Nm/t | x1.200 / x1.400 / x1.600 | stage policy |
| Thorton Mackinaw | 126.0 km/h | 500 Nm | 195.3 Nm/t | 472.2 Nm/t | x1.200 / x1.400 / x1.600 | stage policy |
| Chevalier Legatus | 111.6 km/h | 950 Nm | 95.0 Nm/t | 482.7 Nm/t | x1.200 / x1.400 / x1.600 | stage policy |
| Thorton Mackinaw Bmf | 126.0 km/h | 700 Nm | 273.4 Nm/t | 482.7 Nm/t | x1.200 / x1.400 / x1.600 | stage policy |

<!-- END GENERATED EXTENDED -->

## Anti-abuse

- **The server picks the record.** A stage is a server-side property of an owned vehicle; the
  gamemode asks `stageRecord(record, stage)` and calls `respawnAs`. A client never names a
  record, and `Open77.vehicles.create` accepts any TweakXL record, so a client-supplied name must
  never reach it.
- **No free repair or teleport.** `respawnAs` carries health and position, and is refused while
  anyone sits in the car (`vehicle_occupied`); add a cooldown on stage changes anyway.
- **Stages belong to the vehicle, not the player:** not transferable to another model, not
  refundable above a fraction of the price, and lost with the vehicle.
- **The physics runs on the driver's client.** A player who edits his own `r6/tweaks` can already
  change any car; stages do not widen that. They do give the server a reference: the rated top
  speed per record (`ratedTopSpeedKmh` export, never raised by a stage), usable as a plausibility
  threshold for speed reports.
- **Every client must have the same records.** The resource ships the YAML as a required mod, so
  the launcher projects it (and TweakXL) before the game starts; a world digest mismatch already
  forces a relaunch. A record missing on a client means TweakXL did not load: check `TweakXL.log`.

## Facts, inferences and open questions

Facts (read from `tweakdb.bin`, game 2.50 on 2026-11-05): every base value in the tables; the
record chain and types of each model; the bikes use `bikeDriveModelData` (`vehDriveModelData` is
empty) and `VehicleWheelDrivingSetup_2`; the Colby and the Galena also carry a separate
`vehDriveModelDataAI`; the Hella's rated top speed equals its top gear's `maxSpeed`.

Inferences, to be measured: the acceleration gain per torque factor (one E0.8 point, linear fit);
that `maxBrakingTorque`, the friction multipliers and the springs act on player-driven cars as their
names say; that specific torque ranks acceleration across models; that the top gear's `maxSpeed`
bounds the top speed when torque rises.

Open: whether TweakXL deep-clones inline sub-records under `$base` (harmless here, every changed
link is explicit); whether a remote client simulates the stage of a car another player drives
(the E0.8 open point).

## In-game validation (lab, by the lead)

1. **Remove the lab tweak first**: `r6/tweaks/Open77Lab/open77-vclab-stage.yaml` defines
   `Vehicle.v_standard2_archer_hella_player_o77s3` and `_o77s3_engine` too (torque 590). TweakXL
   reads the folders in name order (its log lists `base\…` then `Open77Lab\…`), so the lab file
   would most likely be applied after `LightRP` and silently win.
2. Install `r6/tweaks/LightRP/open77-lightrp-stages.yaml` (TweakXL 1.12.0, as in E0.8), start the
   game, and read `red4ext/plugins/TweakXL/TweakXL-*.log`: `Reading "LightRP\open77-lightrp-stages.yaml"`,
   `Import completed.` and no error line.
3. Spawn every stage record once with `Open77.vehicles.create` (45 records, or at least one per
   kind: FWD Hella, RWD Cortes, AWD Hozuki, truck Merrimac, engine-less Quartz, both bikes).
4. **Acceleration**, the E0.8 run: same straight (Badlands, about 152 m), standing start,
   `vehicles.ai.driveTo` at 55 m/s, server samples at 4 Hz; peak, 0-50, 0-80, 0-100 km/h for the
   Hella stock / s1 / s2 / s3 (expected 0-80: 9.07 s measured, then about 8.65 / 8.26 / 7.91 s),
   then one uncapped car (Cortes, x1.6 at s3) and the Kusanagi.
5. **Top speed**: a straight of 1 km or more, same command, stock vs s3: the peak must stay at or
   under the rated speed (Hella 115.2 km/h, Cortes 126 km/h).
6. **Braking**: from a steady 80 km/h, stop on the same spot, 4 Hz samples until under 1 km/h;
   stopping distance stock vs s3 (expected shorter by between the grip and the brake gain, 6 to
   30 %). Use the Hella: the Colby and the Galena may brake with their AI drive model under the AI
   driver.
7. Second client watching the car (the E0.8 open point), then the numbers go into
   `docs/research/vehicles-api.md`.
