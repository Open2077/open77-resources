# Light RP vehicle liveries (E3)

Twelve original liveries for the 21 vanilla player bodies that take a unique TwinTone
template: the eleven Light RP dealer cars and ten other player bodies (section 3). The designs
are taxi, Night City Motors, six Light RP jobs, NCPD, and three styles. A server applies one
with `Open77.vehicles.setPaintProfile(id, 'Vehicle.o77_livery_<design>_<model>')`.

Status on 2026-11-08: the pack covers the 21 bodies as revision `062aaf1f63a2`
(252 templates, taken by 23 vehicle records with the two trims; ZIP 7.4 MiB), built offline and **not
seen in game**. It is `98ed7f188e77` of 2026-11-07 under a new depot prefix: the renamed
component table and the new scan step changed the revision, not the content. The 28 other player bodies are listed in the spec's `unsupported` with their
reason (section 3). The paragraph below is the state of the eleven dealer cars.

Status on 2026-11-06, from the campaign ledger: **pack `490d5fb1f73b` was seen in game on
one client** (2026-11-06 10:09-10:12, lab): the twelve Hella liveries were applied together with
no crash for over two minutes, through a reinstall of the third-person puppet, and Urban was
complete on both sides, the hood and the trunk. Still open: a second client, persistence, and
a sale in the Auto Studio. Two earlier revisions failed. The first look (`66ea08e0cd1f`) drew
the taxi black and the racing livery black with white sills; section 5 gives the two causes,
the evidence and the composite check that now blocks both. `5a611a69c48f` crashed the game at
`+0x37DD77` because the Hella templates carried 12 to 19 decals; "At most 12 decals per
template" (section 4) gives the cap that fixed it. The server change of section 7
(`registerPaintProfiles`) merged on 2026-11-05 (`66fc1c98`). Section 8 is the lab procedure and
section 9 lists what is proven and what is not.

## 1. Rebuild

```powershell
pwsh -File scripts/vehicle-kit/liveries/build-liveries.ps1
pwsh -File scripts/vehicle-kit/liveries/build-liveries.ps1 -SkipPreview            # no applied previews
```

| Input | Where it comes from |
|---|---|
| Spec | `liveries/specs/lightrp-liveries.json`: designs, colours, finishes, models |
| Component table | `-Dealer`, by default `docs/generated/vehicle-components-player-bodies-2.50.json` (`scripts/vehicle-kit/inventory`: every vanilla player body with its `trims`). Its file name and SHA-256 are part of the revision |
| Game folder (read only) | `-GameDirectory`, else `OP77_GAME_DIR` (process scope, then user scope) |
| WolvenKit CLI | `-WolvenKitCli`, else `scripts/find-wolvenkit.ps1` (8.20 used here) |
| Python | `uv` runs every step with pinned Pillow and numpy, `python -I` |
| Node.js | `native/normalize-archive.cjs` pins the archive timestamps; `plates/native/plates.cjs scan` finds the shared bytes |
| Scan baseline | `-ScanBaseline`, by default `liveries/specs/no-vanilla-bytes-baseline.json`: the shared blocks reviewed by hand (see "No vanilla bytes" below). It does not enter the revision |
| Body-kit cache | `%TEMP%\open77-vehicle-kit-measure\bodykit` (E2's cache). The script fills it with `blender/body_measure.py --extract` when a panel is missing. It must stay outside the repository. |

The output goes to `artifacts/vehicle-kit/liveries/`. The script refuses to write into a
folder that sits in the repository and is not git-ignored, because `work/` holds extracted
game files.

| Output | What it is |
|---|---|
| `resource/lightrp_vk_liveries/` | Draft resource: `open77.lua`, `server/liveries.lua` (generated tables), `server/main.lua`, `profiles.json`, `dist/LightRPVehicleLiveries_<rev12>.zip` |
| `open77-lightrp-liveries.yaml` | The TweakXL records (also inside the ZIP) |
| `preview/flat/<design>_flat.png` | The atlas of each design on its body colour. Magenta lines mark the three regions. |
| `preview/applied/<design>/<model>.png` | The composite of section 5: our multilayer over the model's vanilla mask on the visible paint of the player appearance, then our decals with their cut-out, from the left, the right, above, the front and the rear |
| `preview/layers/<model>_<design>.png` | The same five views, each texel coloured by the layer that wins it, with its role |
| `preview/reference/<model>_*.png` | The factory reference: the vanilla stack and the TwinTone generic mask (grey main, white secondary, black vanilla material) |
| `layer-roles.json` | The measured role of every layer of every reference stack (section 5) |
| `composite.json` | The coverage table and the decal placement of every design and model, with the limits |
| `manifest.json`, `SHA256SUMS` | Revision, tools, hashes, templates read but not shipped, every referenced vanilla path |
| `work/` | Intermediate files: plan, art, decal glb, WolvenKit JSON, staged archive, extracted game files. **Never ship or commit it.** |

The build ends with a line like this one, from the run of 2026-11-06:

```text
VK_LIVERIES_OK revision=5a611a69c48f records=132 files=1340 zip=4922286 (not deployed)
```

It takes 13 to 15 minutes on this machine, cache warm:

- layer roles of the reference stacks, about 2 minutes;
- artwork, about 2.5 minutes;
- decal grids, under a minute;
- the composite check and its previews, about 5 minutes;
- the WolvenKit steps, the rest.

The first run also extracts and serializes what the composite reads: 135 game files for the
plan, 296 meshes, 60 mltemplates, 167 material instances, 13 masks exported to PNG layers and
11 generic masks. All of it is cached in `work/game/`. The build never writes in the game
folder and never deploys.

**No vanilla bytes.** After the archive byte check, `plates/native/plates.cjs scan` compares
every cooked file with every game file the build read: `lv_scan.py plan` lists the
extractions cached in `work/game/raw` and the stock panel meshes of `composite-inputs.json`.
`lv_scan.py check` then explains each shared 64-byte block. It accepts a block inside the CR2W
names table of its game file, or inside a verified vertex format descriptor, as the sticker
build does (`st_ocook.py`). The pack also shares 224 blocks that are neither. All of them were
already in revision `8c50ead76bc6`:

| Count | Cooked file | Game file | What it is |
|---|---|---|---|
| 122 | our `.mlsetup` | `.mlsetup` | vanilla trim layers kept by reference (section 6) |
| 5 | our `.mlsetup` | material instance | the same |
| 94 | our decal `.mesh` | `.mesh` | 70 in `materialEntries`, 7 in `renderChunkInfos`, 4 in the render blob header, 13 with no identified owner |
| 3 | `courier_d.xbm` | Mackinaw generic mask | windows of our compressed texture equal to a periodic pattern of the mask |

These 224 blocks are the baseline, `liveries/specs/no-vanilla-bytes-baseline.json`. Each one is
keyed by the game side of the hit (`<file name>@<offset>`), which does not change with the
revision. Any other shared block fails the build. A baseline block that is no longer shared is
counted, not reported as an error. The step prints a line like this one, from the build of
`062aaf1f63a2`:

```text
LV_SCAN_OK ours=2256 vanilla=1162 new shared blocks=0, known blocks=224 of 224 (8c50ead76bc6, 0 no longer shared), names-table blocks=780, vertex-format blocks=818
```

**Reproducibility.** `<rev12>` is a SHA-256 over:

- the spec, every script and the Lua template;
- every generated PNG and glb;
- every game file read, including the mltemplates and the material instance chains of the
  composite;
- `layer-roles.json`;
- the WolvenKit version, the TweakXL floor and the projection settings.

The depot prefix is `open77\assets\lightrp_vk_liveries\<rev12>\`. A changed design gets new
paths, so a client never mixes two revisions.

**Measured on 2026-11-06.** Two builds in a row into the same output folder, cache warm, gave
the same revision and the same seven `SHA256SUMS` lines: ZIP, archive, YAML, `open77.lua`,
both server scripts and `profiles.json`. `manifest.json`, `composite.json` and
`layer-roles.json` were byte-identical too. The archive timestamps are pinned, so the bytes do
not depend on the time of the build. The same check passed on 2026-11-05 for `66ea08e0cd1f`,
into two different output folders, and on 2026-11-08 for `062aaf1f63a2`, in parallel into two
folders, the scan step included.

## 2. How a vanilla livery works (research)

### Facts

These were read in `tweakdb.bin` and `tweakdb_ep1.bin` through `../inventory/tdb.py`, and in
the WolvenKit JSON of the files involved.

- **A model lists its liveries** in `Vehicle.<record>.appearancesToColorTemplate`, which
  points to a `VehicleAppearancesToColorTemplate` record. That record's `colorTemplates` array
  holds `VehicleColorTemplate` records.
  - Generic paints have `mainColor`, `secondaryColor` and no pattern.
  - The unique liveries have `hasCustomPattern = true` and no colour of their own.
- **A unique template carries two inline lists:**
  - `customMultilayers`, of type `VehicleCustomMultilayer`. Each entry has `customMlSetup`
    and `customMlMask` (resource paths), `affectedComponents`, `excludedComponents`,
    `onlyForPlayerVehicleAppearances`, `coatLayerMin` and `coatLayerMax`.
  - `customDecals`, of type `VehicleDecalAttachment`. Each entry has `componentToAttachTo`,
    `decalResource` (an `.ent`) and `onlyForPlayerVehicleAppearances`.
- **The base colour comes from the multilayer.** The `.mlsetup` gives each layer its
  material (an `.mltemplate`), its colour (a key of that template's palette) and its opacity.
  The `.mlmask` says where each layer goes on the car's own UVs.
- **Artwork comes from decals.** Vanilla stickers on the Hella combat cab, the 6th Street car
  and the scavenger cars are `.ent` files with one `entMeshComponent` named `decal`. Its
  mesh is a thin shell over the panel. The material is a local instance of
  `base\vehicles\common\materials\stickers.mi`, whose base is
  `base\materials\vehicle_mesh_decal.mt`.
- **The vanilla stickers carry their cut-out in one of two ways** (read 2026-11-06; this
  corrects the 2026-11-05 note, which said every sticker used `MaskTexture`):
  - `stickers.mi` sets `enableMask = 1`. The `.mt`'s default `MaskTexture` is
    `engine\textures\small_white.xbm`, and `stickers.mi` does not override it.
  - The full-colour atlases (`decals_combatcab_checker_d01`, `decals_6thstreet_d01`) are RGBA
    `TCM_QualityColor` (BC7) textures with a real alpha. Their instances set no
    `MaskTexture`, so the cut-out is the diffuse alpha.
  - The graffiti stickers set a `MaskTexture` (`TEXG_Generic_Grayscale`, `TCM_QualityR`),
    always with `enableMask = 1`.
  - No vanilla sticker has an opaque `TCM_DXTNoAlpha` diffuse with `enableMask = 0`. That is
    what revision `66ea08e0cd1f` shipped (section 5).
- **The factory TwinTone split is a texture.** Each model's TweakDB
  `genericCustomizationMask` is a UV0 `.xbm`: mid grey takes the main colour, white the
  secondary colour, black is left to the vanilla material (sills, lower bumpers, inner
  arches, interior). `excludedComponentsGeneric` lists the components it leaves alone, for
  example maimai's hood, trunk and bumpers, and the `body_01` of hozuki and merrimac.
- **A chunk's material kind is in its `.mi` chain, not always in the mesh.** Many local
  instances carry `values: []` over `multilayer_vehicle_destruction.mi` or over a
  `material_instances/ext_*.mi` (hozuki, merrimac, maimai). Only the chain says whether the
  chunk is multilayered.
- **The vanilla decal ent has a fixed shape**:
  - `castShadows = Never`, chunkMask `9223372036854775807`, `forceLODLevel = -1`,
    identity transform;
  - the component appears both in `components` and in `compiledData`.
  - The decal mesh has `localMaterialBuffer` materials and `PS_Color` streams.
- **Measured per model** (`work/plan.json`): every supported car has a vanilla full-body
  unique template over masks of its own (no `unique_mlmasks` pattern mask, no junk-kit mask).
  Nine cars use one multilayer; semimaru and maimai use two (body plus rims, body plus a
  second exterior mask).
- **Four dealer models cannot take a livery**:
  - thrax: `hasUniqueCustomization = false`;
  - bandit: one colour template and no unique template, so no reference mask;
  - apollo and kusanagi: bikes, `hasUniqueCustomization = false`.
- **The client already applies any template of the record's list by id.**
  `client/redscript/Open77VehiclePaint.reds`, `Open77ApplyNetworkProfile`, walks
  `AppearancesToColorTemplate.colorTemplates` and calls `VehicleVisualCustomizationTemplate.
  FromRecord`. E0.2 proved this path in game for the Hella's vanilla templates
  (`docs/research/vehicles-api.md`, *E0.2*).

### Answer: can a new record use our own textures?

**Yes, through decals.** This is an inference, built from the facts above, that needs one
in-game check.

- A new `VehicleColorTemplate` appended to the model's `colorTemplates` by TweakXL is
  found by `Open77ApplyNetworkProfile`, because that function walks the live record list.
- Its `customDecals` name our `.ent` files. Those use our `.mesh` files, which use our two
  `.xbm` textures per design.
- No vanilla record or resource is patched, so **no `.archive.xl` is needed**. The archive
  only adds new depot paths under our prefix. The game mounts `archive/pc/mod`, and TweakXL
  creates the records. D's prop pack works the same way.

**The base colour is our `.mlsetup` laid over the model's own vanilla `.mlmask`**, which is
referenced by path and never shipped.

- A fully custom mask would mean authoring masks on each body's UV layout. That needs the
  vanilla UVs as a template, which decision D6 forbids shipping.
- The decals carry every shape, letter and emblem instead. So the mask only has to say
  "paint the body", and the vanilla one already says it.

### Inferences still to check in game

- **`!append-once`** under `colorTemplates` appends our records to the vanilla list. This is
  the TweakXL array syntax. The first in-game look of 2026-11-06 applied our records, so it
  reached the live list (section 9).
- **`matchingAppearances: []` keeps the game from ever picking a livery for traffic.** The
  vanilla unique templates list the appearances they suit, and ours list none.
- **A colour `DiffuseTexture` works in `vehicle_mesh_decal.mt`.** The default diffuse of
  `stickers.mi` is a colour atlas, and the vanilla stickers set `UseGradientMap = 0`.
- **Our decal material cuts out the artwork in the game.** It sets `enableMask = 1` and
  carries the cut-out in both vanilla places: the BC7 diffuse alpha and a BC4 `MaskTexture`
  holding the same values. Whichever channel the shader reads, the result is the same. Which
  one it reads is not known.
- **The textures load in the game.** Offline, WolvenKit 8.20 keeps both setups through the
  round trip. Each 2048 × 1024 texture holds 12 mips: 2 796 240 bytes for the colour (8 bits
  per pixel, BC7) and 1 398 120 bytes for the mask (4 bits per pixel, BC4). On 2026-11-06 the
  taxi textures of `5a611a69c48f` were exported back with `cp77tools export --uext dds`,
  which writes the colour decoded to RGBA8 sRGB and the mask to R8, and compared with the
  source PNG:
  - colour (`TCM_QualityColor`): RGB mean error 0.02 / 255, maximum 11; alpha mean error
    0.08 / 255, maximum 22; 981 of 2 097 152 texels (0.05 %) cross the 50 % alpha threshold;
  - mask (`TCM_QualityR`): mean error 0.04 / 255, maximum 25, as on 2026-11-05.

  That is the quality of BC7 and BC4.

### Hypotheses (no evidence yet)

- Decals offset 4 mm from the panel do not z-fight at range. How far the vanilla stickers sit
  off their panel was not measured; `-Offset` changes ours.
- A player appearance whose body is `body_player_01` hides the decals of a hidden
  `body_01`. The decal is attached to the component, so it should follow its visibility.

## 3. The designs

Every design is drawn by `lv_art.py` from the spec's parameters. No game image, logo or font
is used. Text uses Aileron, the CC0 face bundled with Pillow. The company names are the
Light RP ones (`light-rp shared/jobs.lua` and the ncmotors dealer). No real brand and no
Night City brand mark is drawn.

| Design id | Label | Light RP job | Finish | Body | Artwork |
|---|---|---|---|---|---|
| `taxi` | City Taxi | taxi (Delamain Partner) | gloss | `#f2c21b` | Black chequer band, TAXI on the doors and the roof, NIGHT CITY CAB |
| `ncmotors` | Night City Motors | (dealer) | metallic | `#d9dde2` | Cyan-to-magenta swoosh, NIGHT CITY MOTORS, *Drive it home today.* |
| `courier` | Food & Parcel Delivery | delivery (Courier) | gloss | `#ef6c1a` | White band, parcel emblem, DELIVERY on the roof |
| `sanitation` | City Services | sanitation | matte | `#2f7d4a` | Light band, yellow chevrons, CITY SERVICES |
| `scrapper` | Salvage & Recycling | scrapper | matte | `#5b5f3a` | Sand band, recycle emblem |
| `rooftop` | Rooftop Maintenance | ac_cleaner (AC Cleaner) | gloss | `#3d8fd1` | White band, fan emblem |
| `mechanic` | Rust & Chrome Garage | mechanic | gloss | `#2b2e33` | Red and orange flames, RUST & CHROME, wrench |
| `medic` | Street Medic | trauma (Street Medic) | gloss | `#f4f4f2` | Green and yellow chequer band, red ECG line, STREET MEDIC, MEDIC on the roof |
| `ncpd` | NCPD Patrol | ncpd | gloss | `#f2f3f5` | Black lower half and hood, blue stripe, NCPD, PATROL, NC-77, NCPD on the roof |
| `racing` | Twin Stripe 77 | (style) | gloss | `#1f4fbf` | Twin white stripes nose to tail over the top, sill pinstripe, roundel 77 on the doors |
| `neon` | Neon Slash | (style) | gloss | `#111216` | Magenta, cyan and yellow slashes |
| `urban` | Urban Grid Camo | (style) | matte | `#8a8f94` | Four-tone grid camo (seeded, reproducible) |

**Models (21):** the eleven dealer cars (hella, galena, colby, quartz, hozuki, supron,
columbus, cortes, merrimac, semimaru, maimai), the two staff-only sports cars of the Light RP
catalogue (shion, type66), and alvarado_hearse, alvarado_valentinos, colby_pickup, mackinaw,
sport_r7, tanishi, tanishi_mr_hands and turbo. Every design exists on every model, so there are
252 templates. The record id is `Vehicle.o77_livery_<design>_<model>`, for example
`Vehicle.o77_livery_taxi_hella`.

**Trims.** A model's other records of the same body (the component table's `trims`) take its
liveries when they share its `AppearancesToColorTemplate` and their appearance carries every
target and decal panel with the same geometry: `plan.json` lists them under `records`, the
refused ones under `trimsRefused`. The Lua catalogue and `profiles.json` then list the same rows
under each record. Quest variants (records named `Vehicle.q<digits>_*`) are out of the scope
table, so never a trim: the owner keeps them out of the whole extension.

In revision `062aaf1f63a2` two trims take their model's liveries: the Shion's
`Vehicle.v_sport2_mizutani_shion_base_player` and the Colby Pickup's
`Vehicle.v_standard25_thorton_colby_pickup_02_player`. Fourteen are refused, each with its
reason in `plan.json`: a panel the trim's appearance lacks (the Type-66's deathrace bumpers and
hood on five trims, the Shion targa's trunk, the Quartz base's junk bumpers, the Colby GT's roof
rack, the Sport R7 02's body and stripes, the Turbo R's body and front bumper, the Galena Bobas'
front bumper and trunk) or another mesh on the same panel (the Galena GT's, the Hozuki GT's and
the Supron GT's bumpers). The YAML holds 272 records: the 252 templates and the 20
`AppearancesToColorTemplate` lists they join (the two Tanishi share one).

**Bodies without liveries** (`unsupported` in the spec, 28):

| Reason | Bodies |
|---|---|
| No vanilla full-body unique template over the model's own masks: no reference to paint over (needs P3.7 paintable work) | caliburn (its pattern templates use the shared unique masks), deleon |
| No unique (pattern) template, colour templates only (needs P3.7) | outlaw, outlaw_heist |
| `hasUniqueCustomization = false` (needs P3.7) | colby_pickup_kurtz, cortes_cab (the cab livery is baked in), legatus, mackinaw_ncu, and the bikes nazare, nazare_linas |
| No `AppearancesToColorTemplate` at all, not CrystalCoat paintable (needs P3.7) | 911turbo, 911turbo_cabrio, colby_nomad, galena_nomad, hellhound, mackinaw_bmf, quartz_nomad, shion_nomad, supron_kurtz, type66_nomad |
| `hasUniqueCustomization = false` (dealer models, section 2) | thrax, and the bikes apollo, kusanagi |
| One colour template, no unique template: no reference mask (section 2) | bandit |
| Over the 12-decal cap after both fold tiers (a fold rule, not P3.7) | aerondight (16), alvarado (13), emperor (14), riptide (19) |

**Finishes:**

| Finish | Template, referenced by path |
|---|---|
| gloss | `base\surfaces\materials\paint\paint_fine\paint_fine_clean_01_300.mltemplate` |
| matte | `paint_fine_clean_matte_01_300.mltemplate` |
| metallic | `base\surfaces\materials\paint\car_paint\car_paint_metallic_01.mltemplate` |

- The body colour is the nearest colour of that template's own palette, matched in linear
  space.
- `work/package.json` records the colour asked for and the colour obtained for each model.
- The palette limits the match. The taxi yellow `#f2c21b` comes out `#ddbe18`. The artwork
  colours are exact, because the decals carry them.
- The body is one colour. The secondary goes to the paint layers that sit on the factory
  secondary region only when a design sets `"twoTone": true`, and no design does today. The
  secondary is still listed in `profiles.json` and `server/liveries.lua`; the artwork takes
  its own colours from the spec's `art` block.

## 4. How the artwork reaches the car

### One atlas per design, shared by every model

- The atlas is 2048 × 1024. It is split into three regions:
  - left side, front at the left;
  - right side, front at the right;
  - top view, front at the left.
- The artwork is placed in nominal metres: length 4.6, side height 1.0, width 1.9.
- Each model maps its own bounds onto the regions, so a design stretches to every body.
- The cut-out is the alpha of `<id>_d.png`, and `<id>_m.png` holds the same values for the
  `MaskTexture`. Outside the artwork the colour is bled outward, so a filtered edge never
  picks up black. A text's aspect ratio is corrected for the model's real length.

### Decal geometry (`lv_decals.py`)

1. The panels of the player appearance are assembled in the vehicle frame from E2's body-kit
   cache (`lv_surface.model_surface`). Each LOD 1 chunk gets the kind of its material,
   resolved through the `.mi` chain: multilayered paint, other multilayer (interior), glass,
   light, other. The chunks the appearance's `chunkMask` hides are dropped.
2. Every chunk is ray-cast orthographically from the left, the right and above on a 2 cm grid.
   The z-buffer holds every visible chunk, so a rack, a mirror or a window in front of a panel
   hides it.
3. A grid quad becomes a decal triangle pair only when all of these hold:
   - all four corners hit **visible multilayered paint of the same target component**;
   - no depth step exceeds 5 cm;
   - the quad's centre, cast on a grid shifted by half a cell, hits the same panel within
     1 cm of the corners' mean depth (four corners on the bars of colby's roof rack used to
     bridge the gap between the bars);
   - the surface faces the view (cosine ≥ 0.45);
   - that view is the best one for the surface.
4. The vertices are pushed 4 mm along the normal and expressed in the component's own frame.
   A decal is attached to its component, unless the plan folds that component into a host.
   Folding is explained in the next section.
5. A component gets a decal only where its design has ink. The coverage is counted on the
   atlas alpha.
6. A target with no visible paint gets no decal and is listed as missing. The build of
   2026-11-06 reports three, all of them as expected: galena `body_roof_barcode_01` (a
   barcode sticker mesh), columbus `bumper_a_shadowmesh` and merrimac
   `body_elements_player_shadow_01` (shadow meshes).

### At most 12 decals per template

The game crashes when one colour template carries 13 or more `customDecals`. Every client
that spawns the car crashes 0.2 to 0.5 s later, at `Cyberpunk2077.exe+0x37DD77` (2.5). Twelve
decals are fine. The measure is in `docs/research/vehicles-api.md` (2026-11-06): 12 Hella with
12 decals each are clean, and one car with 13 crashes. The cap counts per car; the number of
liveried cars nearby does not matter.

The Archer Hella has 19 painted targets. The other models of the pack have at most 12 after
the tiers below (the Mackinaw and the Turbo fold their mirrors into the doors), so they keep
one decal per target. Four bodies stay above 12 after both tiers and are left out until a
third tier exists: aerondight 16, alvarado 13, emperor 14, riptide 19.

`lv_plan.py` (`decal_hosts`) brings a model above the cap under it, and writes the result to
`plan.json` as `decalHosts`. It applies whole tiers, in this order, until the count fits:

1. A plain `entMeshComponent` hard-bound under a target joins that target. The binding may
   pass through non-target components, as `door_br_player_stripe_01` does through
   `door_br_shadow`. This is how a door stripe joins its door, `bumper_f_player_01` joins
   `bumper_f_01`, and the trunk plate joins `trunk_a`.
2. Targets bound to the same `vehicle_slots` slot share one decal.

A component that one of the spec's `kitFits` can hide is never folded, and nothing is folded
into it. Galena's `trunk_spoiler` is such a component: our wings hide it. Its artwork would
otherwise float where the hidden part was.

On the Hella, tier 1 is enough and takes it from 19 decals to 12.

`lv_decals.py` meshes a folded panel exactly as before, then writes it in the host's frame and
into the host's glb. The host's binding carries it rigidly, as the game carries the stripe
with its door. `decals.json` lists the panels of each decal under `parts`. The composite check
counts a texel over any of those parts as on its panel. `lv_cook.py` refuses a template above
the cap.

### Native cook (`lv_cook.py`, D's rules from `native/cook.cjs`)

- **Meshes.** WolvenKit imports the glb onto a never-shipped vanilla decal mesh container.
  The cook then:
  - clears the bone and parameter lists;
  - writes one local `CMaterialInstance` per design over `stickers.mi`;
  - writes one appearance per design;
  - checks that every `PS_Color` vertex is `ffffffff`;
  - sets the geometry hash.
- **Textures.** WolvenKit imports the PNGs, the cook patches the setup, and WolvenKit imports
  them again with `--keep`:
  - colour: `TEXG_Generic_Color`, `TCM_QualityColor` (BC7, RGBA, the cut-out in the alpha),
    sRGB, the setup of the vanilla full-colour sticker atlases;
  - mask: `TEXG_Generic_Grayscale`, `TCM_QualityR` (BC4), linear.

  Until 2026-11-06 the colour texture was `TCM_DXTNoAlpha` (BC1, no alpha).
- **Decal material.** One local instance per design over `stickers.mi`: `DiffuseTexture`,
  `MaskTexture`, `enableMask = 1`, white `DiffuseColor`, `UseGradientMap = 0`, the flat
  normal, `DirtOpacity = 0`. Until 2026-11-06 it set `enableMask = 0`.

  A plain PNG import gives `TCM_None` (uncompressed RGBA, 11 MB of texture data). That is why
  the second import with `--keep` exists.

**Two WolvenKit 8.20 traps, measured while building this:**

- A folder `serialize` or `deserialize` drops the subfolders, and files with the same name
  overwrite each other. Every file therefore crosses WolvenKit under a flat, reversible name:
  the depot path with `\` replaced by `~`.
- `import <folder>` exits with code 3 even when it succeeds; the same file imported alone
  exits with 0. The build accepts 3 for folder imports only, and only after WolvenKit
  reports `Imported N/N file(s)` for exactly the number of files it staged.
- **Mlsetups.** These follow the layer roles **measured** on the model's vanilla reference
  stack (`layer-roles.json`, section 5):
  - `paint` (layer 0, or a layer whose contribution lies at least half on the factory-painted
    body) takes our primary, in the finish's template;
  - `accent` (a paint layer lying at least half on the factory secondary region) takes the
    secondary when the design sets `"twoTone": true`, the primary otherwise;
  - `grime` (dust, dirt, rust, ...) is set to opacity 0;
  - `trim` (everything else: sills, lower bumpers, rubber, chrome, inner arches) keeps its
    vanilla material path, palette key and opacity;
  - a rim-only multilayer is trim and grime only;
  - a multilayer with no factory reference (all its components are in
    `excludedComponentsGeneric`: maimai's second one) has layer 0 as paint and every other
    layer as trim.

  Until 2026-11-06 every layer that changed between vanilla paint jobs took our primary or
  secondary. That recoloured trim (section 5).
- **Entities.** There is one `.ent` per design and panel, with the vanilla decal entity's
  shape.
- **Checks.** Everything goes through deserialize, then a serialize round trip, then a
  field check. The archive is packed, its timestamps pinned, and then it is listed and
  extracted again. A byte check runs on every entry.

## 5. The first in-game look, its causes, and the composite check

### What the lead saw (2026-11-06, revision `66ea08e0cd1f`)

Hella Stage 1, `Vehicle.v_standard2_archer_hella_player_o77s1`, appearance
`archer_hella__basic_player_01`:

- **taxi**: a black body with thin, jagged yellow seams and a yellow trunk lid; no chequer,
  no text;
- **racing**: a black body with blue edges and a blue trunk, no white stripe seen, a white
  sill band and a very bright white lower front bumper;
- the factory `inline2` template looked right.

The first guess was an upper multilayer layer covering the body. The composite refuted it: in
`66ea08e0cd1f` our primary already won 99.8 % of the Hella's painted body.

### The composite (`lv_composite.py`)

The old preview painted every panel in the primary and laid the artwork on top, so it could
not show either defect. `lv_composite.py` draws what the game blends:

- **The multilayer.** Each layer of our `.mlsetup` is blended in order over the model's
  vanilla `.mlmask`, sampled at the UV0 of every visible paint texel of the player
  appearance. The weight is `w_i = mask_i × opacity_i`, applied as a lerp. A texel's winning
  layer is the one contributing most, `c_i = w_i × Π_{j>i} (1 − w_j)`. A layer's colour is
  its template's `colorScale` entry. The template's albedo and the microblend are not
  modelled.
- **The decals.** Our decal meshes, the glb files the archive ships, are drawn where they are
  not behind the body. The opacity is either the atlas alpha (`mask`, what the material is
  meant to draw) or 1 (`opaque`, what a decal material without a working cut-out draws).
- **The factory reference.** The TwinTone generic mask (section 2) defines the **painted
  body**: visible texels of the target panels, outside `excludedComponentsGeneric`, where the
  generic mask is grey or white. Where it is black is the **trim region**: sills, lower
  bumpers, arches.

There are five orthographic views (left, right, top, front, rear) on a 1 cm grid, and each
visible texel counts once. Every share below is therefore a share of what a viewer sees.

The vanilla masks and generic masks are exported to PNG by WolvenKit into `work/game/` and
never shipped.

### Cause 1, the dominant one: the decals were opaque

`66ea08e0cd1f` shipped an opaque BC1 diffuse, a BC4 `MaskTexture` and `enableMask = 0`. No
vanilla sticker uses that combination (section 2). Drawn opaque, every decal quad shows the
bled atlas, which is black away from the artwork. The paint then survives only in the gaps
between quads (the jagged seams) and on panels with no decal: the taxi has no artwork on the
Hella's `trunk_a`, hence the yellow trunk lid.

The composite of `66ea08e0cd1f` in opaque mode reproduces the screenshots. Shares of the
painted body, as paint / artwork / dark (linear luminance under 0.03):

| Model | `66ea08e0cd1f` as drawn (opaque) | `66ea08e0cd1f` with its cut-out | `5a611a69c48f` |
|---|---|---|---|
| hella taxi | 29.4 / 70.6 / **70.6** | 93.0 / 6.8 / 6.3 | 93.0 / 6.8 / 6.1 |
| galena taxi | 24.3 / 75.7 / **75.7** | 91.4 / 8.6 / 7.5 | 90.1 / 9.9 / 8.9 |
| cortes taxi | 22.2 / 71.7 / **71.7** | 70.5 / 5.2 / 4.7 | 90.3 / 5.3 / 4.7 |
| maimai taxi | 25.3 / 74.7 / **74.7** | 88.9 / 11.1 / 9.5 | 89.0 / 11.0 / 9.5 |
| hella racing | 25.1 / 74.9 / **40.3** | 83.5 / 16.3 / 0.0 | 83.5 / 16.3 / 0.0 |
| galena racing | 23.8 / 76.2 / **52.2** | 91.2 / 8.8 / 0.4 | 87.3 / 12.7 / 0.4 |
| cortes racing | 21.8 / 71.9 / **40.7** | 66.2 / 13.2 / 0.3 | 82.5 / 13.1 / 0.3 |
| maimai racing | 25.0 / 75.0 / **57.3** | 90.8 / 9.2 / 0.4 | 91.0 / 9.0 / 0.4 |

"Paint" counts texels where no artwork covers the body and our paint layers win. The taxi's
dark share in the last column is its black chequer.

Two points of the screenshots the composite does not settle:

- It draws the racing stripes over the hood, roof and trunk as a wide white band, which the
  lead did not report. The screenshots may not have shown the top.
- It draws the racing doors blue around the white roundel, where the lead described a black
  body.

### Cause 2: the layer rule recoloured trim

The `66ea08e0cd1f` rule gave our primary or secondary to every layer that changes between
vanilla paint jobs. Several of those are trim. On the Hella, layer 9 (`plastic_tech_hq_01_30`)
covers a quarter of the visible body and lies on the trim region: the sills and the lower
bumpers. With the racing secondary `#f5f5f5`, that is the white sill band and the white lower
front bumper. Painted-body coverage cannot see this, because those texels are outside the
painted body. So the check measures the trim region on its own, against the share the
vanilla reference's own paint wins there:

| Model | Primary share of the painted body, before → after | Trim region recoloured, before → after (vanilla reference) |
|---|---|---|
| hella | 99.8 % → 99.8 % | 80.3 % → 3.9 % (3.9 %) |
| galena | 100 % → 100 % | 53.0 % → 15.0 % (15.0 %) |
| cortes | **75.7 %** → 95.5 % (layer 8 had the secondary: 16 %) | 55.9 % → 10.0 % (10.0 %) |
| maimai | 100 % → 100 % | 36.3 % → 6.1 % (6.1 %) |

Maimai's second multilayer (hood, trunk and bumpers, all excluded from the generic mask) has
no factory reference. There our layer 0 wins 81.4 % before and after, and the vanilla bare
steel layer keeps the rest as trim. The check does not assert it.

### Cause 3, minor: decals on the wrong component

- Galena's `body_roof_barcode_01` got a decal (916 texels), but it is a barcode sticker mesh
  with no paint chunk in `thorton_galena__basic_player_01`: 0 % of that decal lay on its own
  panel.
- The Hella racing decal on `bumper_f_player_01` lay 20 % off its panel (79.5 % on it).

The decal step now keeps only visible multilayered paint of the target component (section 4).
The worst after the fix, over 132 records: 95.2 % visible (semimaru mirror), 99.6 % on its own
panel, 0.7 % floating.

### The rules now

- Layer roles are measured, not guessed (section 4, *Mlsetups*). The roles of the eleven
  reference stacks, as `P` paint, `A` accent, `t` trim, `g` grime:

  | Model | Layers 0-19 |
  |---|---|
  | hella | `PPtttgPtttttggtgtggt` |
  | galena | `PtttttttttttgPtttggt` |
  | colby | `PPtPgPPAAtttgttPggPt` |
  | quartz | `PPtPggPttAttAPtPPggt` |
  | hozuki | `PtttPAttttttttgPtggt` |
  | supron | `PtPPttAttttttgtPtggP` |
  | columbus | `PPPttAAtgtttgPtPtggt` |
  | cortes | `PtPtttPtAAttgPtPtggP` |
  | merrimac | `PtttPPPPtPPtgPPPggPP` |
  | semimaru | `PPPAtttgtttttPPPtPgg`; rims `ttttttttttttttttttgg` (trim and grime only) |
  | maimai | `PttttttttttttgtPtggt`; second exterior `Ptttttttttttttgttggt` |

- The decal material is cut out by its alpha and by its mask (section 4).
- A multilayer whose components have no visible multilayered chunk fails the build: no role
  can be measured for it.

### The checks (`lv_composite.py check`, after the cook)

The `66ea08e0cd1f` column below was re-measured on hella, galena, cortes and maimai, for taxi
and racing.

| Assertion | Limit | Factory / this build | `66ea08e0cd1f` |
|---|---|---|---|
| Paint layers win the painted body | ≥ 85 % (`-MinPrimary`) | factory 95.5 % (cortes) to 100 %; this build the same, every design | cortes 75.7 % |
| Trim region recoloured, above the vanilla reference | ≤ +5 points (`-MaxTrimRecolouredExcess`) | +0 points on every model | +30 to +76 points |
| Each decal in front of its panel | ≥ 85 % (`-MinDecalVisible`) | ≥ 95.2 % | ≥ 97.8 % |
| Each decal on its own panel | ≥ 90 % (`-MinDecalOnComponent`) | ≥ 99.6 % | 0 % (galena barcode), 79.5 % (Hella bumper) |
| Each decal floating more than 2 cm | ≤ 3 % (`-MaxDecalFloating`) | ≤ 0.7 % | ≤ 0.3 %; 6.0 % on colby's rack before the centre test |
| Every decal component is in the player appearance with visible paint | | yes | no (galena barcode) |

The other multilayers (semimaru's rims, maimai's second exterior) get the primary-share
check on their own texels only where the generic mask grounds them, and only when the
factory reference paints some of them: the Colby Pickup's door step has a multilayer of its
own whose vanilla stack is all trim (0 painted texels), so it stays trim, as in the factory.
"In the player appearance" counts the components an appearance part brings (`partsValues`),
from the component table: the Colby Pickup's hood decal sits on the Kurtz hood scoop, which
such a part adds. Both rules came with the 2026-11-07 extension; neither changes a result
of the eleven dealer cars.

Why these limits:

- **85 %** sits ten points under the lowest factory reference (cortes, 95.5 %) and ten points
  over the defect (75.7 %).
- **+5 points** leaves room for the 1 cm raster on panel edges. A fixed limit would not work:
  the vanilla reference's own paint layers already win 0.0 % (columbus) to 61.9 % (merrimac)
  of the trim region, while the defect measured +30 to +76 points.
- The decal limits leave five to ten points under the worst value of this build, and still
  catch both placement defects of `66ea08e0cd1f` and the rack bridging of a test build.

`composite.json` holds the full table: for every design and model, the primary share, the
winning layers, the trim share and its reference, every decal's placement, and the
paint/artwork/dark shares. The build fails on any assertion.

## 6. What ships, what is only referenced (D6)

**Shipped**, all generated by this build:

- the `.xbm` textures, `.mesh` decal shells, `.ent` decal entities and `.mlsetup` paint
  stacks under `open77\assets\lightrp_vk_liveries\<rev12>\`;
- the TweakXL YAML;
- the Lua tables.

**Referenced by depot path, never shipped:**

- each model's own `.mlmask` (listed in `manifest.json`);
- `stickers.mi`;
- `engine\textures\editor\normal.xbm`;
- the three finish `.mltemplate` files;
- `base\surfaces\microblends\default.xbm`;
- the trim layers' vanilla `.mltemplate` and microblend paths.

`lv_cook.py prepare` fails if a shipped file references anything else.

**Read as templates, never shipped:**

- the vanilla decal mesh `rayfield_caliburn ... door_fl_numbers_01.mesh`, as the CR2W
  container (every buffer, material and appearance is replaced);
- the vanilla reference `.mlsetup` files, for layer roles and trim keys;
- the finish `.mltemplate` palettes, for colour matching.

`manifest.json` records their SHA-256.

**Judgment call for review.** A generated `.mlsetup` keeps the vanilla trim layers' material
path, palette key and microblend path, which are short strings. No texture, mesh or binary
data comes along. These are references in the D6 sense, but they come from reading a vanilla
`.mlsetup`.

**No LAB ONLY variant.** Every shipped file is generated, so the ZIP and the resource are
meant to ship as they are. There is no lab-only build that copies game data. `work/` does
hold extracted game files, which is why it lives under the git-ignored `artifacts/` and is
never packed.

## 7. Blocker (lifted): the server did not know pack profiles

**Update 2026-11-06.** Option 1 below merged on 2026-11-05 as
`Open77.vehicles.registerPaintProfiles` (`vc/b4-register-paint-profiles`, `66fc1c98`;
`docs/vehicle-visual-contract.md`). The rest of this section is the analysis as written
before it.

**Fact, from code (before `66fc1c98`).** `VehicleCustomizationService.TryProfile`
(`server/src/Open77.Server.Core/Vehicles/VehicleCustomizationService.cs`) accepts a profile
only when `VehicleCustomizationData.Profiles(vehicle.Record)` lists it. That list is the
`profiles` column of the embedded catalogue `server/src/Open77.Server.Core/Data/
vehicle-customization-2.50.tsv`, built from the vanilla TweakDB. The comment on it says so
plainly:

> A record absent from the table -- including a pack-added one (TweakXL) -- has no profile
> the server can vouch for.

So today:

- `listPaintProfiles` does not list the 132 records;
- `setPaintProfile(id, 'Vehicle.o77_livery_taxi_hella')` answers `false, 'invalid_profile'`.

The client side would apply them, as section 2 explains.

**Needed change (server team, not E3).** Pick one:

1. **Recommended: `Open77.vehicles.registerPaintProfiles(catalogue)`.** It would follow
   `registerParts`: atomic, namespaced by the declaring resource (D4 whitelist), and dropped
   when the resource stops.
   - The catalogue is `{ [dealer record] = { { id, label, main = {r,g,b}, sec = {r,g,b}, pattern = true } ... } }`.
     That is exactly `profiles.json` > `records` and `LightRpVehicleLiveries` here.
   - `Profiles(record)` would return the vanilla list plus the registered rows.
   - A stage record would inherit them, as it already inherits the vanilla list.
   - `server/main.lua` already calls it when the function exists.
2. **Merge the rows into the tsv** at catalogue build time (`scripts/build-data-catalogue.py`).
   This is simpler, but it bakes one pack's records into the platform.

The draft resource feature-detects option 1. Without it, the resource logs at start how many
of the 132 profiles the server lists.

## 8. Lab procedure (for the lead)

Prerequisites:

- a server with `registerPaintProfiles` (section 7);
- the TweakXL loader resource in `resources.load`;
- a local lab server, not prod.

1. **Drop.** Copy `artifacts/vehicle-kit/liveries/resource/lightrp_vk_liveries/` into the lab
   server's resources folder and add `lightrp_vk_liveries` to `resources.load`. The launcher
   projects the `preload_mod` ZIP before the game starts:
   - `archive/pc/mod/LightRPVehicleLiveries.archive`;
   - `r6/tweaks/LightRP/open77-lightrp-liveries.yaml`.

   A client already running must restart.
2. **Check the server.** The start line reads
   `[lightrp_vk_liveries] 11 models, 132 livery records (revision <rev12>)`. With the server
   change, it also reads `registerPaintProfiles: true`.
3. **List.** Sit in a dealer Hella, then call:

   ```lua
   local seat = Open77.vehicles.getPlayerSeat(player)
   local list = Open77.vehicles.listPaintProfiles(seat.vehicleId)   -- expect the vanilla 26 + 12 o77_livery_*_hella
   ```

   The resource's command also works: `/livery list`. It is a restricted command, so the
   lab account needs the server ACL `command.livery`.
4. **Apply.** Again from the server:

   ```lua
   Open77.vehicles.setPaintProfile(seat.vehicleId, "Vehicle.o77_livery_taxi_hella")
   Open77.vehicles.setPaintProfile(seat.vehicleId, nil)   -- back to generic paint
   ```

   With the command: `/livery taxi`, `/livery ncpd`, `/livery off`. Another resource gets the
   id with `exports.lightrp_vk_liveries:liveryProfile(record, 'taxi')`.
5. **Look.** Compare with `preview/applied/<design>/<model>.png`. Look from both sides at
   door height, from above (a high third-person camera), and from the front and the rear.
   On every design:
   - the body is the design's colour, one tone;
   - the sills, the lower bumpers and the inner arches (and, on the Hella, the dark strip at
     the foot of the doors) stay the car's own vanilla material;
   - there is no artwork on the front or rear faces (no decal view covers them);
   - side text reads normally from both sides;
   - roof text reads normally from the car's left, with the nose to your left.

   | Design | Body | Both sides | From above |
   |---|---|---|---|
   | taxi | yellow, gloss | black chequer band along the belt line; TAXI large on the front door; NIGHT CITY CAB on the rear door; small No 0277 near the rear | black chequer strip across the hood near the nose; TAXI on the roof; trunk plain yellow |
   | ncmotors | silver, metallic | swoosh low on the doors, cyan at the front to magenta at the rear; NIGHT CITY MOTORS and *Drive it home today.* mid-side | two thin cyan-to-magenta pinstripes along both edges, nose to tail |
   | courier | orange, gloss | white band along the belt line; DELIVERY / FOOD & PARCEL mid-side; parcel emblem toward the front | white panel with DELIVERY on the roof |
   | sanitation | green, matte | light band; CITY SERVICES / SANITATION on the rear half; bin emblem toward the front; yellow chevrons low at the rear corner | plain light panel on the roof, no text |
   | scrapper | olive, matte | sand band; SALVAGE & RECYCLING / SCRAPPER mid-side; recycle emblem toward the front | plain sand panel on the roof |
   | rooftop | blue, gloss | white band; ROOFTOP MAINTENANCE / AC CLEANER; fan emblem toward the front | plain white panel on the roof |
   | mechanic | dark grey, gloss | red and orange flames from the front wing back over the front door; RUST & CHROME / GARAGE - MECHANIC and a wrench on the rear door | flames over the hood from the nose |
   | medic | white, gloss | green and yellow chequer band low on the doors; red ECG line above it at the front; STREET MEDIC in red toward the rear | thin green and yellow strip across the hood near the nose; MEDIC in red on the roof |
   | ncpd | white, gloss | black band along the bottom of the doors and wings, a blue stripe above it; NCPD on the front door; PATROL on the rear door; small NC-77 near the rear | black hood; NCPD on the roof |
   | racing | blue, gloss | white roundel 77 at the rear edge of the front door; a thin white pinstripe at the foot of the doors | two white stripes nose to tail over hood, roof and trunk |
   | neon | near black, gloss | magenta, cyan and yellow slashes rising toward the rear | magenta and cyan diagonal slashes on the hood and on the trunk |
   | urban | grey, matte | four-tone grid camo over the whole side | camo over hood, roof and trunk |

   **On the Hella, the side artwork sits low for this body** (composite of `5a611a69c48f`).
   The foot of its doors is the car's own dark strip, fading upward, and the decals draw
   over it. As a result:
   - the black TAXI on the front door and NIGHT CITY CAB on the rear door read poorly;
   - the lower half of NCPD darkens;
   - PATROL lands on the rear wheel arch and does not show;
   - ncpd's black band, ncmotors' swoosh, sanitation's chevrons and racing's pinstripe end
     up mostly on the sills and the wing corners.

   The chequer band, the roof and hood artwork and every mid-height text read well. This is
   a layout limit of the shared atlas, not a decal or layer defect. It is not fixed in this
   revision.

   Per model, these are expected and match the vanilla reference stack:
   - cortes: a bare anodised-steel strip along the roof centre, under the roof text;
   - hozuki: a hard-plastic panel in the roof centre;
   - maimai: hood, trunk and bumpers take the colour on their layer 0 only, with the car's
     own bare steel around it;
   - maimai: the roof is mostly glass, so the roof text is cut.

   On hozuki and merrimac, `body_01` is outside the generic mask, so the check does not
   assert it. Our primary wins 48 % of hozuki's `body_01` (the rest is inner arches and the
   roof panel) and 81 % of merrimac's.

   Watch for these failures:
   - Black panels with the paint showing only in thin seams: the decal cut-out does not
     work. This is the `66ea08e0cd1f` look (section 5). Note which channel would have to
     carry it.
   - White or coloured sills or lower bumpers: a trim layer took a livery colour. The
     composite check should have stopped the build.
   - The body colour changes but no artwork shows: the decal `.ent` or texture is not
     loading. Read `red4ext` and TweakXL logs for unresolved paths.
   - Artwork flickers: the 4 mm offset is too small. Rebuild with `-Offset 0.006`.
   - Artwork floats: the panel frame is wrong. Compare against E2's body-kit measurements.
6. **Two clients.** Repeat with a second client watching. The profile id replicates like the
   vanilla ones.

## 9. Proven offline, open in game

**Proven offline, on every build:**

- each record, its `AppearancesToColorTemplate` and its reference profiles exist in this
  game build's TweakDB;
- every shipped path is under the prefix, and every external reference is in the allowed
  list (D6);
- the mesh, ent and mlsetup files and the textures survive a WolvenKit serialize round trip;
- the texture setups hold, with a full mip chain;
- every decal vertex colour is white;
- the composite assertions of section 5, on every design and model: paint wins the painted
  body, trim stays at its vanilla share, every decal component is a visible paint panel of
  the player appearance, and every decal lies on it;
- the archive lists exactly the staged files and extracts byte-identical;
- the ZIP has two entries and stays under 64 MB.

**Proven offline, once:**

- two builds produced identical bytes (section 1): into two folders on 2026-11-05
  (`66ea08e0cd1f`), and twice in a row into one folder on 2026-11-06 (`5a611a69c48f`);
- the textures of `66ea08e0cd1f` decoded back to the source PNGs at BC1 and BC4 quality
  (section 2), and those of `5a611a69c48f` at BC7 and BC4 quality on 2026-11-06;
- the composite of `66ea08e0cd1f`, drawn opaque, reproduces the first in-game look
  (section 5);
- the generated Lua parses with `luac -p` (Lua 5.4.8). `open77.lua` is a manifest, read by
  the server's own parser rather than by Lua. It follows the stage pack's manifest, plus the
  `permissions { ... }` form used by existing resources.

**Not checked offline:**

- the server's manifest parser and validator never read this resource; the `open77_*` tools
  were out of scope;
- no Lua ran.

**Previews:**

- 12 flat atlases;
- one composite per design and model (132), plus one layer sheet per design and model and
  the factory reference of each model.

The composites are a software rasterizer, not the game's renderer. They model the layer
colours, the masks and the decal cut-out; they do not model the templates' albedo, the
microblends, the clear coat or the lighting.

**Open (in game):**

- whether the shader reads the decal cut-out from the diffuse alpha or from `MaskTexture`
  (either works offline; section 2);
- the racing stripes seen from above, which the first look did not report (section 5);
- z-fighting at distance;
- the body colour in the game's lighting;
- replication of a pack profile to a second client, after the server change.

**Seen in game (2026-11-06 10:09-10:12, `490d5fb1f73b`, one client):** the twelve Hella
liveries applied together for over two minutes with no crash, the puppet reinstalled; Urban
complete left, right, hood and trunk. The open points above still hold for the other models
and for a second client.

**Seen in game first (2026-11-06, `66ea08e0cd1f`, by the lead):** the records apply on the
Hella Stage 1, so TweakXL `!append-once` on `colorTemplates` reaches the live list, and our
decal entities load: the black quads of the screenshots are their shape (section 5). The
look was wrong for the reasons of section 5.

## 10. Risks

- **Server version.** A server older than `66fc1c98` has no `registerPaintProfiles` and
  refuses every livery with `invalid_profile` (section 7).
- **TweakXL is required** on every client. It is the same dependency as the stage pack.
- **Size.** The archive holds 1 340 files and weighs 6.1 MB; the ZIP weighs 4.9 MB. Both are
  far under the 64 MB ceiling, because flat artwork compresses well. Each new design adds two
  textures and, per model, one appearance per covered mesh plus its entities.
- **One atlas layout for 21 bodies.** The side artwork is placed at fixed fractions of
  each body's height and length. On the Hella the low text falls on the dark foot of the
  doors or into a wheel arch (section 8). A per-model offset of the side regions in
  `lv_decals.py`, or a light outline on black text in `lv_art.py`, would fix it.
- **Panels hidden by accessories.** Roof racks and other non-paintable parts occlude the
  roof artwork of some cars (galena, supron, colby). No decal is laid where a rack, a mirror
  or a window hides the paint from its view, so the artwork has holes there.
- **Overlapping bodies.** The Hella's player appearance carries both `body_01` and
  `body_player_01`, plus `*_player_stripe_01` shells. Each gets its own decal. If two of them
  are visible in the same place in the game, their decals may fight.
- **Game updates.** The plan step fails loudly if a reference template or record disappears.
  The masks and meshes are hashed into the revision.
- **Damage and dirt.** The decals use `DirtOpacity = 0` and do not deform with crash damage.
  A dented door keeps a flat sticker. Vanilla stickers behave the same way; this is an
  inference from their setup.
