# Light RP vehicle stickers

Two sticker packs, one resource each, one Lua core (`stickers/lua/stickers_main.lua`):

| Pack | Resource | Build | What it ships |
|---|---|---|---|
| Vanilla looks | `lightrp_vehicle_stickers` | `stickers/build-stickers.ps1` | our decal entities pointing by path at the game's own sticker meshes (`Vehicle.o77_st_*`) |
| Original motifs | `lightrp_vehicle_original_stickers` | `stickers/build-original-stickers.ps1` | our art, our textures, our decal meshes and entities (`Vehicle.o77_os_*`) |

Both register their rows with `Open77.vehicles.registerStickers` and put a sticker on a car with
`setStickers`. A row's integer `decals` is what the sticker costs against the 12-decal budget of
a car, livery included (`getDecalBudget`; a 13th decal crashes the game at `+0x37DD77`). Nothing
here has been seen in game yet; the research log is `docs/research/vehicle-wave2-packs.md`.

Status on 2026-11-08: the original pack carries five themes on every vanilla player body of
the installed game (49 bodies: the 15 dealer models, the Caliburn and 33 others, see
[Models](#models)), built offline as revision `c63f2be126d8` (235 sets, 1,466
decals, 2 to 9 per set; ZIP 8.7 MiB). It is `57df1c007bfd` of 2026-11-07 under a new depot
prefix: the renamed component table changed the revision, not the content. The 2026-11-06 revision `a44fa172fed4` had the 16
dealer models only (80 sets, 490 decals). Theme 01 "Course" is the pilot's, unchanged; themes
02, 04, 05 and 06 were added after it. Theme 03 "Sponsors" is not produced. Not deployed, not
seen in game.

## Themes of the original pack

Each theme is its own catalogue `group` (what Light RP's Auto Studio groups by), one row per
(theme, model), id `os.<model>.<theme>`. A set holds at most 9 decals, so a light livery fits
beside one theme; two themes on one car are the server budget's business.

| Theme | Group (label) | Motifs and zones | Colourway |
|---|---|---|---|
| 01 `course` | `Original: Race` (Race) | double stripes on hood, roof and trunk (one scale); number 77 roundel on the doors (readable, not mirrored); chequered sill stripe; chequered flag on the front wings | light car |
| 02 `graffiti` | `Original: Graffiti` | abstract bubble tag on the doors (no letters); drips along the sills; burst on the hood; throw-up on the rear; arrows on the rear wings | dark car |
| 04 `tech` | `Original: Circuit` | circuit traces on the doors; data bar along the sills; central chip on the hood; bus on the rear; chip on the roof | dark car |
| 05 `vague` | `Original: Wave and sun` | great wave and banded sun on the doors; wave scales along the sills; sun over the sea on the hood; surf on the rear; petals on the front wings | light car |
| 06 `filet` | `Original: Pinstripe` | belt pinstripe on the front and rear doors, at one height, continued on the front and rear wings; hood pinstripes; rear pinstripe and sill line (both optional) | dark car |

On a bike, the long door motif of themes 02, 04 and 05 has no room: its `fallback` puts the
theme's emblem (the burst, the roof chip, the sun over the sea; textures already in the pack) on
the largest painted flank instead, 14 to 18 cm across. The pinstripe keeps a 15 to 19 cm segment.

## Models

The spec's `models` (16: the dealer stock and the Caliburn) and `extendedModels` (33: every
other vanilla player body) list each body of `docs/generated/vehicle-player-scope-2.50.json`
once; `test_stickers.py` checks it.

- **Scope.** `scripts/vehicle-kit/inventory/player_scope.py`: every `Vehicle.*_player*` car and
  bike of the installed TweakDB, grouped by entity into bodies. Out of scope: AVs, the panzer
  class, and the quest variants (`Vehicle.q<digits>_*`: `Vehicle.q000_hym_player_car` and
  `Vehicle.q304_songbird_escape_player` share the Hella's and the Cortes' bodies; the owner keeps
  them out of the whole extension). A body's key is its Light RP catalogue key when it has one,
  since `os.<key>.<theme>` ids are saved on players' cars, else a key derived from its record.
- **Strict and lenient.** The 16 `models` keep the strict rule: a failing decal fails the build.
  An `extendedModels` body is placed by the same rules, but a decal that fails an assertion is
  left out with its pair partner, a set left under `minDecalsPerSet` is not produced
  (`placements.json`, `droppedSets`), and a body no theme fits takes nothing
  (`modelsWithoutSets`).
- **Trims.** A set is measured on the body's primary record. Another record of the same body
  (the component table's `trims`) is listed with it when its appearance carries every panel the
  set hangs on, with the same mesh and binding. The catalogue row then carries `models` (the
  primary first, 64 records at most), `registerStickers` gets that list as `model`, and every
  listed record shares the set's TweakXL holder. Refused trims are in `trimsRefused`.
- **Component table.** `-Dealer`, by default `docs/generated/vehicle-components-player-bodies-2.50.json`
  (`dealer_components.py --scope --light-rp`): the dealer table's 16 rows plus the 33 other
  bodies, each with its `trims`. Its SHA-256 is part of the revision.

Coverage of revision `c63f2be126d8`, from its `placements.json`, the livery spec and the livery
plan. C, G, T, V, F: the decals of the Race, Graffiti, Circuit, Wave and sun, and Pinstripe sets.
Trims: other records of the body listed with at least one set (refused in brackets).

| Body | Primary record | Rule | Sticker sets (decals) | Trims listed | Liveries |
|---|---|---|---|---|---|
| `hella` | `Vehicle.v_standard2_archer_hella_player` | strict | C7 G6 T5 V6 F8 | 0 | 12 designs |
| `galena` | `Vehicle.v_standard2_thorton_galena_player` | strict | C8 G8 T6 V8 F8 | 1 (1 refused) | 12 designs |
| `colby` | `Vehicle.v_standard2_thorton_colby_player` | strict | C6 G6 T5 V6 F8 | 1 | 12 designs |
| `quartz` | `Vehicle.v_standard2_archer_quartz_player` | strict | C8 G8 T7 V8 F6 | 1 | 12 designs |
| `hozuki` | `Vehicle.v_standard2_mizutani_hozuki_player` | strict | C8 G7 T5 V7 F9 | 0 (1 refused) | 12 designs |
| `supron` | `Vehicle.v_standard25_mahir_supron_player` | strict | C7 G4 T5 V6 F6 | 1 | 12 designs |
| `columbus` | `Vehicle.v_standard25_villefort_columbus_player` | strict | C8 G7 T7 V8 F8 | 0 | 12 designs |
| `cortes` | `Vehicle.v_standard2_villefort_cortes_player` | strict | C9 G7 T7 V8 F8 | 0 | 12 designs |
| `merrimac` | `Vehicle.v_standard25_thorton_merrimac_player` | strict | C6 G8 T7 V6 F8 | 0 | 12 designs |
| `semimaru` | `Vehicle.v_sport1_yaiba_semimaru_player` | strict | C7 G8 T6 V8 F5 | 0 | 12 designs |
| `maimai` | `Vehicle.v_standard2_makigai_maimai_player` | strict | C5 G5 T6 V3 F3 | 0 | 12 designs |
| `thrax` | `Vehicle.v_standard2_chevalier_thrax_player` | strict | C9 G8 T7 V8 F9 | 0 | no: `hasUniqueCustomization` false |
| `bandit` | `Vehicle.v_standard2_archer_bandit_player` | strict | C7 G7 T6 V7 F5 | 0 | no: no vanilla reference to paint over |
| `apollo` | `Vehicle.v_sportbike3_brennan_apollo_player` | strict | C2 G2 T2 V2 F2 | 1 (1 refused) | no: `hasUniqueCustomization` false |
| `kusanagi` | `Vehicle.v_sportbike1_yaiba_kusanagi_player` | strict | C2 G2 T2 V2 F2 | 1 (3 refused) | no: `hasUniqueCustomization` false |
| `caliburn` | `Vehicle.v_sport1_rayfield_caliburn_player` | strict | C6 G7 T6 V5 F3 | 1 (1 refused) | no: no vanilla reference to paint over, needs P3.7 paintable work |
| `shion` | `Vehicle.v_sport2_mizutani_shion_player` | lenient | C8 G5 T6 V7 F5 | 1 (1 refused) | 12 designs (+1 trim) |
| `type66` | `Vehicle.v_sport2_quadra_type66_player` | lenient | C6 G7 T6 V7 F7 | 4 (1 refused) | 12 designs |
| `911turbo` | `Vehicle.v_sport2_porsche_911turbo_player` | lenient | C6 G7 T6 V8 F5 | 0 | no: not CrystalCoat paintable, needs P3.7 paintable work |
| `911turbo_cabrio` | `Vehicle.v_sport2_porsche_911turbo_cabrio_player` | lenient | C8 G7 T6 V8 F9 | 0 | no: not CrystalCoat paintable, needs P3.7 paintable work |
| `aerondight` | `Vehicle.v_sport1_rayfield_aerondight_player` | lenient | C7 G7 T5 V7 F7 | 0 | no: 16 panels after folding, over 12 (follow-up) |
| `alvarado` | `Vehicle.v_sport2_villefort_alvarado_player` | lenient | C9 G8 T7 V8 F8 | 0 | no: 13 panels after folding, over 12 (follow-up) |
| `alvarado_hearse` | `Vehicle.v_sport2_villefort_alvarado_hearse_player` | lenient | C8 G8 T7 V8 F8 | 0 | 12 designs |
| `alvarado_valentinos` | `Vehicle.v_sport2_villefort_alvarado_valentinos_player` | lenient | C8 G8 T7 V8 F8 | 0 | 12 designs |
| `colby_nomad` | `Vehicle.v_standard25_thorton_colby_nomad_player` | lenient | C5 G8 T4 V6 F5 | 1 | no: not CrystalCoat paintable, needs P3.7 paintable work |
| `colby_pickup` | `Vehicle.v_standard25_thorton_colby_pickup_player` | lenient | C4 G4 T5 V4 F3 | 1 | 12 designs (+1 trim) |
| `colby_pickup_kurtz` | `Vehicle.v_standard25_thorton_colby_pickup_kurtz_player` | lenient | C6 G6 T4 V6 F5 | 0 | no: `hasUniqueCustomization` false, needs P3.7 paintable work |
| `cortes_cab` | `Vehicle.v_standard2_villefort_cortes_delamain_player` | lenient | C9 G7 T7 V8 F8 | 0 | no: `hasUniqueCustomization` false, needs P3.7 paintable work |
| `deleon` | `Vehicle.v_sport2_villefort_deleon_player` | lenient | C9 G6 T7 V8 F8 | 1 | no: no vanilla reference to paint over, needs P3.7 paintable work |
| `emperor` | `Vehicle.v_standard3_chevalier_emperor_player` | lenient | C8 G8 T6 V8 F9 | 0 | no: 14 panels after folding, over 12 (follow-up) |
| `galena_nomad` | `Vehicle.v_standard2_thorton_galena_nomad_player` | lenient | C6 G5 T4 V6 F6 | 1 | no: not CrystalCoat paintable, needs P3.7 paintable work |
| `hellhound` | `Vehicle.v_standard3_militech_hellhound_player` | lenient | C5 G6 T4 V6 F5 | 0 | no: not CrystalCoat paintable, needs P3.7 paintable work |
| `legatus` | `Vehicle.v_utility4_chevalier_legatus_player` | lenient | C7 G6 T6 V8 F8 | 0 | no: `hasUniqueCustomization` false, needs P3.7 paintable work |
| `mackinaw` | `Vehicle.v_standard3_thorton_mackinaw_player` | lenient | C5 G4 T5 V4 F8 | 0 | 12 designs |
| `mackinaw_bmf` | `Vehicle.v_utility4_thorton_mackinaw_bmf_player` | lenient | C4 G4 T7 V4 F6 | 0 | no: not CrystalCoat paintable, needs P3.7 paintable work |
| `mackinaw_ncu` | `Vehicle.v_standard3_thorton_mackinaw_ncu_player` | lenient | C6 G8 T6 V8 F6 | 1 | no: `hasUniqueCustomization` false, needs P3.7 paintable work |
| `nazare` | `Vehicle.v_sportbike2_arch_player` | lenient | none: 0 decals fit in every theme | 0 | no: `hasUniqueCustomization` false, needs P3.7 paintable work |
| `nazare_linas` | `Vehicle.v_sportbike2_arch_linas_player` | lenient | none: 0 decals fit in every theme | 0 | no: `hasUniqueCustomization` false, needs P3.7 paintable work |
| `outlaw` | `Vehicle.v_sport1_herrera_outlaw_player` | lenient | C6 G7 T6 V7 F5 | 0 | no: no vanilla reference to paint over, needs P3.7 paintable work |
| `outlaw_heist` | `Vehicle.v_sport1_herrera_outlaw_heist_player` | lenient | C5 G7 T5 V7 F5 | 0 | no: no vanilla reference to paint over, needs P3.7 paintable work |
| `quartz_nomad` | `Vehicle.v_standard2_archer_quartz_nomad_player` | lenient | C5 G5 T5 V5 F5 | 1 | no: not CrystalCoat paintable, needs P3.7 paintable work |
| `riptide` | `Vehicle.v_sport1_herrera_riptide_player` | lenient | C4 G4 T5 V5 F2 | 0 | no: 19 panels after folding, over 12 (follow-up) |
| `shion_nomad` | `Vehicle.v_sport2_mizutani_shion_nomad_player` | lenient | C5 G5 T5 V5 F5 | 2 | no: not CrystalCoat paintable, needs P3.7 paintable work |
| `sport_r7` | `Vehicle.v_sport1_quadra_sport_r7_player` | lenient | C8 G6 T6 V7 F7 | 0 (1 refused) | 12 designs |
| `supron_kurtz` | `Vehicle.v_standard3_mahir_supron_kurtz_player` | lenient | C5 G8 T5 V8 F9 | 0 | no: not CrystalCoat paintable, needs P3.7 paintable work |
| `tanishi` | `Vehicle.v_standard3_makigai_tanishi_player` | lenient | C5 G6 T4 V6 F8 | 0 | 12 designs |
| `tanishi_mr_hands` | `Vehicle.v_standard3_makigai_tanishi_player_mr_hands` | lenient | C7 G8 T6 V8 F6 | 0 | 12 designs |
| `turbo` | `Vehicle.v_sport1_quadra_turbo_player` | lenient | C5 G5 T7 V8 F8 | 0 (1 refused) | 12 designs |
| `type66_nomad` | `Vehicle.v_sport2_quadra_type66_nomad_player` | lenient | C5 G8 T6 V8 F4 | 1 | no: not CrystalCoat paintable, needs P3.7 paintable work |

47 of the 49 bodies take sets: 235 sets, 1,466 decals, 2 to 9 per set, 68 records (47
primaries and 21 trims). The Nazare and the Nazare Linas take none: no zone of any theme has
room on their fairing (`modelsWithoutSets` gives every theme's reason). The Aerondight and the
Legatus show no cabin from above (the Aerondight's windows are `crystal_dome` materials, not
classed as glass): their top regions fall back to the bike rule, so the hood motif sits
between the axles, on the roof. Their boards show it; no fix in this revision.

## Rebuild

```powershell
pwsh -File scripts/vehicle-kit/stickers/build-stickers.ps1
pwsh -File scripts/vehicle-kit/stickers/build-original-stickers.ps1
pwsh -File scripts/vehicle-kit/stickers/build-original-stickers.ps1 -ReviewOnly                  # boards only
pwsh -File scripts/vehicle-kit/stickers/build-original-stickers.ps1 -ReviewOnly -Models hella,caliburn
```

| Input | Where it comes from |
|---|---|
| Spec | `stickers/specs/original-stickers.json`: themes, motifs, the zones each motif names, the models, the cap |
| Component table | `-Dealer`, by default `docs/generated/vehicle-components-player-bodies-2.50.json` (see [Models](#models)) |
| Game folder (read only) | `-GameDirectory`, else `OP77_GAME_DIR` (process scope, then user scope) |
| WolvenKit CLI | `-WolvenKitCli`, else `scripts/find-wolvenkit.ps1` (8.20 used here) |
| Python | `uv` runs every step with pinned Pillow and numpy, `python -I` |
| Node.js | `native/normalize-archive.cjs` (archive timestamps), `plates/native/plates.cjs scan` (no vanilla bytes) |
| Body-kit cache | `%TEMP%\open77-vehicle-kit-measure\original-stickers`, filled by `body_measure.extract` when a model is missing |
| Game files read for the placement | `%TEMP%\open77-vehicle-kit-game\original-stickers` (`-GameCache`): raw meshes, `.mi` chains, the container mesh and their JSON |

Both caches are refused inside the repository. The output goes to
`artifacts/vehicle-kit/original-stickers/` (git-ignored):

| Output | What it is |
|---|---|
| `preview/boards/<model>_<theme>.png` | the review board of each set: five views, wheels and decals depth-tested, per-decal metrics, skipped zones |
| `preview/overview/<theme>.png` | one image per theme: the spec's `overviewModels` (left, top and rear views), the picture to show first |
| `preview/motifs/` | each motif's texture |
| `placements.json` | every decal: zone, host component, scale, size, metrics; skipped zones; `decalsPerModel` |
| `resource/lightrp_vehicle_original_stickers/` | the draft resource: `open77.lua`, `server/stickers.lua` (catalogue), `server/main.lua`, `catalogue.json`, `dist/Open77LightRPOriginalStickers_<rev12>.zip` |
| `manifest.json`, `SHA256SUMS` | revision, tools, scan result, placement totals, archive / YAML / ZIP hashes |

Same spec, scripts, tools and game build give the same revision and the same bytes.

## How a motif reaches a car

1. **Art** (`st_draw.py`, `st_art.py`). Every motif is drawn from primitives in code; per motif a
   colour texture with its alpha cut-out (BC7 sRGB) and a mask (BC4), as `lv_art.py` does.
2. **Placement** (`st_place.py`). Per model, each zone a motif names (hood, roof, trunk, rear,
   door, sill, front or rear wing, left and right) is found on the drawn exterior of the player
   appearance and hung on one stock panel. The rules are in the module docstring; in short:
   paint facing the view, smooth, no glass close behind it, off the wheels; no body-kit part
   (`specs/lightrp-bodykit-fit.json`), no trim, no bumper (except `rear`); largest scale first;
   pairs symmetric, a flag mirrored so it points the same way on both sides, the number left
   readable; stripes cropped along the car; no two decals overlap. A zone without room is
   left out and reported. A set over 12 decals, or under `minDecalsPerSet`, fails the build.
   Spec options of a motif, added with themes 02 to 06:

   | Option | Effect |
   |---|---|
   | `crop: "u"`, `minLength`, `maxLength`, `cropKeep` | a side band (sill, pinstripe) keeps its height and takes a run along the car; `cropKeep` (`start`, `middle`, `end`) names the part of the art kept when the run is shorter |
   | `anchorZ: "belt"`, `anchorOffset`, `anchorWeight` | the band prefers the belt line's height (top of the front door's paint), trading length for distance to it |
   | `alignTo`, `alignTolerance` (cm) | a segment continues an earlier motif's height on the same side (door to wing); out of tolerance, it is left out rather than drawn at another height |
   | `fallback: {motif, minScale}` | no room even at `minScale`: the named motif's art goes there instead |
   | `optional` | dropped, last first and both sides together, when a set is over `maxDecalsPerSet` (9) |
   | `texelsPerCm` | finer texture for the thin pinstripes |

   Zone `door2_l` / `door2_r` is a four-door's rear door; a two-door has none.
3. **Boards** (`st_board.py`). Look at every board before shipping: each motif on its named
   panel, nothing floating, nothing through glass or wheels. The theme overviews are drawn
   from the same views.
4. **Cook** (`st_ocook.py`, `liveries/lv_cook.py`). One decal mesh per placement (our geometry in
   the CR2W shell of a vanilla container mesh, never shipped), one decal entity, the material
   instances on `stickers.mi`, the TweakXL records (`Vehicle.o77_os_<model>_<theme>_<zone>`
   `VehicleDecalAttachment`, `Vehicle.o77_sticker_os_<model>_<theme>` holder listing them), and
   the Lua catalogue, one row per (theme, model), id `os.<model>.<theme>`. WolvenKit round trip,
   pack, byte check after extraction, no-vanilla-bytes scan, ZIP.
5. **No vanilla bytes** (`plates/native/plates.cjs scan`, then `st_ocook.py scan-names`). The
   scan reports every 64-byte block of a game file the build read that is found in our files.
   Only two kinds may be shared, each verified field by field: the CR2W strings and names tables
   (every entry's hash checked), and the vertex format descriptor of a render chunk
   (`rendVertexBufferChunk.vertexLayout`: packing elements whose type, usage and stream name a
   `PT_`, `PS_` and `ST_` value, the slot strides, mask and hash, nothing else). Our decal meshes
   keep the container's CR2W layout, so they share names tables with every mesh and the vertex
   format with any mesh of the same format and leading names. Any other shared block fails the
   build. Measured on revision `c63f2be126d8`: of the
   1,603 game files the build reads, 1,358 shared blocks lie in names tables and 78 in vertex
   format descriptors, all of them in the Race door motif's meshes (`course_door_l.mesh`),
   whose format equals the Galena Nomad's and the Hellhound's crystal-dome window meshes.

## Deploy (not done by the build)

The resource needs the TweakXL loader resource and the wave-2 natives (`registerStickers`,
`setStickers`). Its lab command is `/osticker list|clear|<id> [vehicleId]` (restricted:
ACL `command.osticker`), so it can sit next to the vanilla pack's `/sticker`. The records are
created by TweakXL at game start: a new pack revision needs a server restart (new resource,
new `preload_mod`) and a client relaunch.

## Tests

```powershell
uv run --no-project python -I -m unittest discover -s scripts/vehicle-kit/stickers -p "test_*.py" -v
uv run --no-project --with pillow==13.0.0 --with numpy==2.5.4 python -I -m unittest discover -s scripts/vehicle-kit/stickers -p "test_*.py" -v
```

The first line runs the cook, catalogue, Lua and no-vanilla-bytes tests (a names table and a
vertex format descriptor pass, vertices and an unknown enum do not; the livery scan accepts
the blocks of its baseline only), the scope (49 bodies, no quest variant), and the themes' own:
one catalogue group per theme, theme 01's ids unchanged, no sponsor theme, every theme under the
12-decal car cap and the 9-decal set budget, the L/R mirroring rule (only the course roundel
stays readable), the resource Lua on every theme. The second line adds the art and placement
tests: theme 01's art byte-identical to the pilot, no motif touching its texture edge, tapered
strokes at full width; decal offset and frame, glass shell, bumper rule, the `u` crop (kept end,
stretch, minimum length), thin lines and thin bands measured whatever their phase, the rear-door
zone, the belt line at one height on both doors, `alignTolerance`, the fallback emblem, the
optional drop (61 tests in all, 22 of them need numpy and Pillow).
