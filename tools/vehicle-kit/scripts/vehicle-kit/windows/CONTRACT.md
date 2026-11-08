# Window tint: route 2 contract (proposal by E6, implemented by W1)

Status: **route 2 is being implemented by W1** (branch `vc/w1-window-tint`), from this
proposal by E6. The packs are built by `build-tint.ps1` (see `README.md`); the server
setter, client adapter and docs land on the same branch. Not yet tested in game. The
inventory behind every number here is offline and re-runnable:
`glass_inventory.py` writes `data/glass-2.50.json` and `data/glass-2.50.md` (metadata only,
no game file).

## 0. The answer

Every Light RP dealer car except the two motorcycles draws its side and rear windows as
**separate mesh components**. Each one is an `entPhysicalMeshComponent` with its own glass
mesh, and the glass is always one chunk whose material derives from
`base\materials\vehicle_glass.mt`. The exception is a few extra panes on four models
(Galena, Thrax, Cortes, Columbus), which live inside the body, door or trunk mesh.

The engine can switch the **mesh appearance of one component** at runtime. Many of these glass meshes already ship tinted appearances that the
game itself picks per trim (Hella `tinted`, Colby `tinted`, Cortes `padre`, Thrax
`black_01`).

So the recommended route has three parts:

- **Pack.** An ArchiveXL **mesh patch** adds three appearances to each glass mesh, one per
  tint level, built from each existing appearance. Only the glass chunk changes, swapped for
  our own `.mi`. Each `.mi` points at the vanilla tinted glass `.mi` by path and sets four
  tint values.
- **Server.** The server stores one integer, `open77.visual.tint`. That field already
  exists and is reserved as `int|null`, so the bag budget does not move.
- **Client.** For each mesh component whose mesh has `open77_tint<level>__<current
  appearance>`, the client switches that component to it.

It works with **any trim**, because it is keyed by mesh appearance, not entity appearance.
The appearance count stays bounded at 3 per glass-mesh appearance instead of trims × tints.

Coverage in v1:

- **9 models complete:** Maimai, Hella, Colby, Quartz, Hozuki, Supron, Bandit, Merrimac,
  Semimaru.
- **4 partial:** Galena, Thrax, Cortes, Columbus (§3).
- **2 without glass:** Apollo, Kusanagi.

## 1. Evidence

### Facts (file, RTTI, source)

- **Glass components and templates** (`data/glass-2.50.md`, cp77tools 8.20 on the installed
  2.50 archives):
  - 13 of the 15 models have 2 to 8 tintable glass components plus a windshield
    `window_f`. Apollo and Kusanagi have none.
  - Every tintable chunk resolves to `vehicle_glass.mt`, through
    `glass_exterior_generic.mi`, `glass_exterior_generic_tinted_black.mi`,
    `glass_windshield.mi` or `glass_windshield_tinted_black.mi`.
  - The exception is the two Supron trunk windows, which use `vehicle_glass_onesided.mt`
    directly.
  - The deep scan (`--deep`) serialized all 856 meshes of the factory and trim appearances
    and resolved every chunk material. Window glass also appears in four non-window meshes:
    - Galena `body_01` (all five looks);
    - Thrax `body_01`;
    - Cortes rear doors `door_bl_a` / `door_br_a`;
    - Columbus `trunk_b` (`cover_glass`, `#3f5c63`), plus its mirror glass and mirror
      indicator cover.

    Each body or door mesh has four glass chunks, one per LOD (inference: the window meshes
    have one LOD). The geometry is not read, so which windows these are (quarter or rear-door
    glass) is an inference.
  - Interior screens and dials use `glass_ui_generic*.mi`, also derived from
    `vehicle_glass.mt`. They are not windows.
  - **Every appearance has an `entAppearanceProxyMeshComponent`** (slot `deformation_rig`,
    46 in all). It is the far-LOD proxy mesh, and it draws its own `Glass` chunk in
    `vehicle_glass_onesided.mt`.
- **Tint parameters of `vehicle_glass.mt`, with template defaults:**

  | Parameter | Type | Default |
  |---|---|---|
  | `TintColor` | Color | `#a2adb4` a=0 |
  | `TintSurface` | Color | `#81836a` |
  | `Opacity` | scalar 0..1 | 1 |
  | `OpacityBackFace` | scalar 0..1 | 0 |
  | `FrontFacesReflectionPower` | scalar 0..10 | 1 |
  | `BackFacesReflectionPower` | scalar 0..10 | 1 |
  | `GlassTint` | texture | `white.xbm` |

  `vehicle_glass_onesided.mt` has no back-face parameters.
- **Vanilla tint values that already render on player cars:**

  | Source | TintColor | Opacity | OpacityBackFace | BackFacesReflectionPower |
  |---|---|---|---|---|
  | clear `glass_exterior_generic.mi` | `#e3e3e3` | 1 | 1 | 0.05 |
  | `glass_exterior_generic_tinted_black.mi` | `#636e71` | 1 | 0.5 | 0 |
  | Semimaru factory side glass | `#8a9699` | 1 | 0.5 | — |
  | Colby `tinted` | `#2f2f2f` | 0.9 | 0 | — |
  | Thrax `black_01` | `#212121` | 0.9 | 0.2 | — |
  | Cortes `extra_dark` | `#1e2223` | 1 | 0.9 | — |

- **The base `.mi` already carries the full damage setup.**
  `glass_exterior_generic_tinted_black.mi` sets dirt (`MaskTexture`, `Roughness` =
  `common_windows_dirt_d02.xbm`), cracks, and bullet-hole shatter (`UseDamageGrid = 1`,
  `UseShatterPoints = 1`, `ShatterTexture`, `ShatterNormal`). An instance derived from it
  keeps all of that.
- **Some factory glass is already tinted.**
  - Galena's player appearance wears `voodoo_01` (sides `#636e71`, rear `#373d3f`).
  - Hella's rear glass is `tinted`. Cortes' factory is `padre` (tinted). Merrimac uses
    `dark`.
  - Semimaru's default glass is already a tinted-black derivative.
- **Engine per-component switch (RTTI manifest 2.50):**
  - `entAppearanceEvent` (parent `redEvent`) has `appearanceName: CName` @64 and
    `componentName: CName` @72.
  - The quest node `questEntityManagerSetMeshAppearance_NodeTypeParams` carries
    `{objectRef, isPlayer, componentName, appearanceName}`.
  - The vanilla script bundle references `entAppearanceEvent` from `SetMeshAppearanceEvent`
    and `Device.SetMeshAppearance`.
- **The client already has the whole read side** (`client/src/api/CyberwareMaterials.cpp`):
  - It enumerates mesh components by RTTI (`mesh: raRef:CMesh`, `meshAppearance: CName`).
  - It gets the loaded `CMesh` through `RED4ext::Ref<CMesh>(path)` and reads
    `mesh->appearances` by name.
  - `Switch()` does Toggle(false), writes `meshAppearance`, then Toggle(true) two ticks
    later.
  - It tracks bindings `{component, original, applied}` so it can restore.
  - It already queues entity events through `Engine::Rtti::EntityNative("QueueEvent")`
    (Combat, Effects, WorldCommands).
- **ArchiveXL fork `Open2077/archive-xl` `open77/1.28`, as installed** (its `ResourcePatch` and
  `Mesh` sources are identical to upstream 1.28.0; the fork only changes world streaming):
  - `ResourcePatchExtension::OnMeshResourceLoad` (hook on `CMesh::PostLoad`) applies a
    mesh patch with `props: [appearances]`. It **clones every patch appearance into the
    target**, adds the ones whose names are new, and tags them with the patch's source tag.
  - `MeshExtension` resolves a chunk material name **missing from the target** from the
    patch mesh's own material entries, whether local or external `.mi`.
  - A name **present in the target** (`stickers`) keeps the target's material.
  - A patch mesh may have no geometry. ArchiveXL's own `h1_base_color_patch.mesh` has a
    null `renderResourceBlob`.
- **The bag already reserves the field.**
  - `open77.visual` carries `"tint": null` today. The server writes it as null
    (`VehicleVisual.cs`, field order `… plate, tint`).
  - The client parser accepts `"tint": 2` and ignores it (`VehicleVisualStateTests.cpp`
    `FullValueDecodes`).
  - Bag limits are 4096 bytes and 256 JSON values.
- **Glass meshes are not shared with windshields.** No tintable glass mesh is also a
  windshield anywhere in the 15 models. Bandit uses Quartz's five side and rear glass
  meshes; nothing else is shared.

### Inferences (reasonable, not measured)

- **`entAppearanceEvent` with `componentName` is the switch that rebuilds one component's
  render proxy with another mesh appearance.** The quest node exists for exactly that, and
  devices use the event at runtime. Not seen on a vehicle yet.
- **The Toggle cycle (`Switch`) also re-creates the proxy with the new `meshAppearance`.**
  It is shipped for cyberware, but no visual proof is on file. Observer cyberware colours
  were "not accepted".
- **What the opacity parameters mean.** `Opacity` and `OpacityBackFace` act as see-through
  from outside and from inside, where lower back-face opacity means a clearer view out.
  This is read from the vanilla presets: Thrax limo glass has 0.2.
- **A patched appearance resolves our `.mi` at chunk-material lookup time**, through the
  same path ArchiveXL uses for every mesh-patch mod. Never measured on a *vehicle* mesh;
  E0.6 measured only entity-appearance dynamics, which are broken on vehicles.
- **Appearance and stream-in reset the switch.** An entity appearance change (trim),
  stream-in and a rebuild re-create the components from the `.app` definition, which resets
  `meshAppearance`. This is the same reason `hide`/`show`/`attach`/`plate` are re-applied.

### Hypotheses (unverified, test in game)

- **H1. Damage and repair.** Vehicle damage or repair may switch a glass component's mesh
  appearance. Hella ships `damaged` and `tinted_damaged`. If the engine does that, the
  adapter must re-apply after damage or repair. The pack already covers it:
  `open77_tint<n>__damaged` exists wherever `damaged` does.
- **H2. Door windows.** Window components bound to door slots (`door_front_left_a`, Maimai)
  keep their mesh appearance when the door opens or closes.
- **H3. Far LOD.** The proxy mesh carries its own glass chunk (fact above), so a tinted car
  seen from far away shows factory glass until its full meshes stream in. The distance at
  which that happens is not measured.

## 2. Routes evaluated

| Route | What it takes | Verdict |
|---|---|---|
| **1a. Entity appearances via ArchiveXL** (`.ent` patch + own `.app`) | One new entity appearance per trim × level: about 15 models × up to 7 looks × 3 = **~250 definitions**. Each one is a full copy of the vanilla trim definition, which is vanilla data (H's E0.6/E0.7 packs are lab-only for that reason). | **Rejected.** Combinatorial with trims, which is what the brief forbids. Not distributable. |
| **1b. Dynamic appearances** (`base!variant`) | One definition and `!variant` per level | **Rejected.** Broken on vehicles in ArchiveXL 1.28, upstream code included (E0.6). |
| **1c. AppearanceParts / `partsOverrides`** | A tint part included by the trim's definition, or an override of the glass components' `meshAppearance` | **Rejected.** AppearanceParts does merge components on a vehicle (E0.6). But a part is included *by an appearance definition*, so each trim × level still needs its own entity appearance: the same count as 1a, again with copied trim definitions. `partsOverrides` only reaches components that come from parts `.ent` files, and vehicle glass is inline in the `.app` definitions. |
| **2. Mesh-appearance patch + per-component switch** | Pack: 70 geometry-less patch meshes, 6 own `.mi`. Server: one int. Client: a mesh-appearance switch per glass component. | **Recommended.** Trim-independent, 0 bag values, original data only, reuses existing client machinery, no new RVA. Needs the native in §4–§5. |
| **2b. Runtime material clone, zero pack** (`CyberwareMaterials::Variant`) | Clone the glass chunk's material instance and set tint params on the clone at runtime | **Fallback only.** It depends on Codeware `LoadMaterialSetupAsync` (RVA 0x40AC88) and CMesh internals (MaterialLock 0x218, owner 0x50, job 0x90). It has no visual proof yet. Each client edits shared `CMesh` objects, so traffic cars could pick up the clones. |
| **A. Tinted shell** (attach a host drawing the glass mesh with our appearance, hide the factory glass) | 6–9 attachments per car plus the `hide` names | **Rejected.** The bag is 16 values per attachment, so ~150 of 256 values, colliding with rims and kits. Hiding a physical glass component loses shatter/bullet-hole visuals and may lose collision. About 8 extra entities per car. |

## 3. Per-model table

The full tables are in `data/glass-2.50.md`, generated:

- per model and per trim: component, slot, mesh, mesh appearance, glass material, base `.mi`
  and effective values;
- the pack plan: 70 glass meshes, 492 appearances added, 6 `.mi`.

Summary:

| Model | Tintable glass components | Factory glass look today | Route 2 |
|---|---|---|---|
| maimai | `window_b`, `window_fl_a/b/c`, `window_fr_a/b/c` (doors) | clear `#e3e3e3`, Opacity 0.3–0.5 | works (H2 to test on door glass) |
| galena | `window_b`, `window_bl/br/fl/fr` | factory and GT trim already tinted (`voodoo_01` `#636e71`, rear `#373d3f`); Suburban and Worn clear | **partial**: the glass inside `body_01` (all five looks) stays factory clear; level 1 is *lighter* than factory |
| hella | `window_b`, `window_bl/br`, `window_bl_02_01`, `window_br_02`, `window_fl/fr` | sides clear, rear `tinted` `#636e71` | works |
| colby | `window_b`, `window_bl/br/fl/fr` | clear / pale `#adc4ca` | works |
| quartz | `window_b`, `window_bl/br/fl/fr` | clear / pale | works |
| hozuki | `trunk_a_window_01`, `window_bl/bl_02/br/br_02/fl/fr` | `dark_01` on some, default on others | works |
| supron | `window_bl/br/fl/fr`, `body_01_window_bl_01/br_01`, `trunk_a/b_window_01` | clear; trunk glass `#010159` Opacity 0.8 (`vehicle_glass_onesided.mt`) | works; trunk glass uses the onesided `.mi` |
| columbus | `window_fl`, `window_fr` | clear | **partial**: the rear glass is `cover_glass` inside `trunk_b` (`#3f5c63`, already dark) and stays factory; mirror glass must never be tinted |
| cortes | `window_b`, `window_bl/bl_02/br/br_02/fl/fr` | `padre` (tinted `#636e71`) | **partial**: the glass inside the rear doors `door_bl_a` / `door_br_a` (clear `#e3e3e3`) stays factory |
| thrax | `window_b`, `window_bl/br/fl/fr` | clear / pale | **partial**: the glass inside `body_01` (clear) stays factory |
| bandit | `window_b`, `window_bl/br/fl/fr` (Quartz meshes) | clear / pale | works |
| merrimac | `window_b_player_01`, `window_bl/bl_02/br/br_02/fl/fr` | `dark` (`#636e71`) | works |
| semimaru | `window_back`, `window_fl/fl_02/fr/fr_02` | tinted-black derivative `#8a9699`/`#636e71` | works; level 1 equals factory sides |
| apollo, kusanagi | none | — | not applicable (motorcycles) |

The windshield `window_f` is never tinted: the pack does not patch windshield meshes.

**The four partial models** could be completed by also patching their body or door meshes
the same way: new appearances, glass chunks swapped, every other chunk keeping the target's
material name. That touches the paintable body, and how the paint system reacts to a
switched body mesh appearance is unknown, so it is left out of v1 (test T6). The far-LOD
proxy meshes (`entAppearanceProxyMeshComponent`) could be patched as well, but their
components have no name, so only switch mechanism (b), by handle, can reach them.

## 4. Server contract

### `Open77.vehicles.setWindowTint(id, level | nil)`

Returns `true`, or `false, reason`.

- `level` is an integer, 0 to 3. Both `0` and `nil` mean factory glass and store
  `tint = null`.
- Anything else is refused with `invalid_tint`: a non-integer, a value below 0 or above 3,
  or a string.
- **No model check.** Like `setPlate`, the platform stores the level on any vehicle. Which
  models *offer* tint is the resource's decision (Light RP: `support`). Only the client knows
  whether its pack covers a mesh (§5). A level on a motorcycle stays stored and draws
  nothing.
- **D9.** A real change needs `world.vehicles` and `world.vehicles.appearance`. The same
  level again is a restatement: no new `rev`, no event, and `world.vehicles` alone is enough.
- `getVisual(id).tint` returns the integer or nil. `tint` stops being "reserved, always
  nil".
- **Properties.** `getProperties(id).visual.tint` and `setProperties(id, {visual = {tint =
  n}})` give an exact round trip. Absent in a versioned table means factory glass; absent in
  a patch leaves the level alone. A non-integer in `setProperties` is `invalid_tint`.
- `respawnAs` carries it with the rest of `open77.visual`.
- **Event.** `onVehicleVisualChanged(id, rev, fields)` reports `tint`, appended after
  `plate`: `profile, neon, parts, wheels, plate, tint`.
- **Budget.** `tint: null` is already one of the 256 values. An integer replaces it: **+0
  values, −3 bytes** (`3` instead of `null`). Nothing else in the bag changes.
- **Upper bound.** 3 is a server constant. A fourth level is a pack addition plus that
  constant, with no client change (§5 builds names from the integer).

### FiveM shim (proposal)

- `SetVehicleWindowTint(vehicle, tint)` and `GetVehicleWindowTint(vehicle)`, plus the
  `windowTint` property.
- FiveM → Open77 mapping:

  | FiveM value | Meaning | Open77 level |
  |---|---|---|
  | `-1`, `0`, `4` | none, NONE, STOCK | nil |
  | `3` | LIGHTSMOKE | 1 |
  | `2` | DARKSMOKE | 2 |
  | `1`, `5` | PURE_BLACK, LIMO | 3 |
  | `6` | GREEN | refused, `unsupported_property:windowTint` |

- Open77 → FiveM, for `Get`: 1 → 3, 2 → 2, 3 → 5, nil → -1.
- `wiki/vehicles.md` ("No window tint on 2.31") and `unsupportedProperties` lose
  `windowTint`.

## 5. Client adapter

The parser's `tint` becomes `std::optional<uint8_t>`. A non-integer or out-of-range value is
skipped as `tint:*:invalid`, and the rest of the value still applies.

**When it runs.** On a newer `rev`, and on every re-apply trigger that `hide`/`show`/`plate`
already use: appearance change, stream-in, rebuild. Repair and damage are added if H1 holds.
Always on the game thread.

**Procedure:**

1. Take every component of the vehicle entity whose native type has `mesh: raRef:CMesh` and
   `meshAppearance: CName`. This is the same filter as `CyberwareMaterials::Apply`.
2. Resolve the loaded mesh with `RED4ext::Ref<CMesh>(path)`. If it is not loaded yet, mark
   the vehicle pending and retry on a later tick (bounded, like `materials_pending`).
3. `original` = the remembered original when `current == applied`, otherwise `current`. This
   is the same binding rule as `CyberwareMaterials`.
4. `target` = `open77_tint<level>__<original>` when the level is set, otherwise `original`.
5. If `target != current` **and** `mesh->appearances` contains `target`, switch the
   component. Otherwise leave it alone. That covers the windshield, non-glass parts, and
   meshes the pack does not cover.
6. **Switch mechanism, decided by test T1:**
   - **(a)** queue `entAppearanceEvent{appearanceName = target, componentName = <component
     name>}` on the entity through `QueueEvent`. `componentName` is never empty: an empty one
     may address the whole entity (untested);
   - **(b)** the existing `Switch()` Toggle cycle.

   Neither needs a new RVA.
7. **Level null.** Switch every bound component back to its `original`, as
   `CyberwareMaterials::Clear` does.
8. **Nothing to tint.** If the level is set and no component of the vehicle has any
   `open77_tint<level>__*` appearance, skip and log once per vehicle and reason (D4). Reasons:
   - `tint:not_covered`: no pack, or a model the pack does not cover;
   - `tint:pending_mesh`: retries exhausted.

   Report it in the `skipped` list that `customizationAvailable` already returns, so Light
   RP can show its `clientPack` message.

The adapter never receives a component name from the server (D1/D4). The pack and the
client agree only on the naming rule `open77_tint<level>__<source appearance>`.

**Cost.** At most ~10 components per car. Work happens only on a change or re-apply, never
per frame.

**Interactions:**

- `hide` on a glass component makes the tint moot.
- Paint profiles and `setPaint` do not touch glass. Glass materials are not multilayer
  (inference).
- `attach` never involves glass.

## 6. Pack spec (for the generator, once §4–§5 are accepted)

**Resource and mount.**

- A resource such as `open77_vehicle_windows` (or one owned by Light RP) ships a
  `preload_mod` ZIP containing `archive/pc/mod/<name>.archive` and `<name>.archive.xl`.
- Depot prefix `open77\assets\<resource>\<rev12>\`, the same rule as the `archivexl` and
  `plates` kits.

**Material instances.** Six `CMaterialInstance` files (`data/glass-2.50.json` →
`packPlan.materialInstances`). Each one sets only the values below.

| File | Chunk material | Base, by depot path | Values set |
|---|---|---|---|
| `glass_tint1.mi` | `open77_tint1` | `base\vehicles\common\materials\glass_exterior_generic_tinted_black.mi` | TintColor `#8a9699`, Opacity 1, OpacityBackFace 0.5, BackFacesReflectionPower 0 (Semimaru factory) |
| `glass_tint2.mi` | `open77_tint2` | same | `#636e71`, 1, 0.5, 0 (the base as is) |
| `glass_tint3.mi` | `open77_tint3` | same | `#212121`, 1, 0.5, 0 (TintColor of Thrax `black_01`, opacities of level 2: Thrax's 0.9 / 0.2 rendered lighter than level 2, 2026-11-07) |
| `glass_tint<n>_onesided.mi` | `open77_tint<n>_onesided` | `base\materials\vehicle_glass_onesided.mt` | TintColor and Opacity of level n (Supron trunk glass only) |

The level values are **starting points copied from looks the game already renders on player
cars**. They are tuned in game (T3), and only the six `.mi` change.

**Patch meshes.**

- One geometry-less patch mesh per target glass mesh: 70 in total (`packPlan.perMesh`).
- `appearances`: for every appearance of the target that has a glass chunk, three
  appearances `open77_tint<n>__<source>`. Each keeps the source's `chunkMaterials` list and
  replaces only the glass chunks with `open77_tint<n>` (or `_onesided`).
- `materialEntries` holds the three or six `open77_tint*` names (external).
- `externalMaterials` holds our `.mi` paths.
- There is no render blob.

**`.archive.xl` entry, per target:**

```yaml
resource:
  patch:
    open77\assets\<resource>\<rev12>\windows\<target mesh file name>:
      props: [ appearances ]
      targets: [ <vanilla glass mesh depot path> ]
```

**Originality.**

- Nothing is copied from a game file except **names**: chunk material names, appearance
  names and depot paths.
- No geometry, no texture, and no material parameter set is copied. Our `.mi` set only our
  numbers.
- The archive therefore contains original data only, unlike the E0.6/E0.7 lab packs.

**Build.** Same pipeline guarantees as `archivexl/build-axl-pack.ps1`: JSON → cp77tools
deserialize, round-trip check, `normalize-archive.cjs` for byte-identical rebuilds, and
`SHA256SUMS`. The generator reads `packPlan` and never the game for geometry.

**Size estimate.** About 70 small CR2W meshes (names only) and 6 `.mi`: well under 1 MB.

## 7. Light RP data shape (owner to review the prices)

`shared/vehicle_customization.lua`:

```lua
-- category: drop `soon = true` once the native ships
{ id = "windows", label = "Windows", description = "Window tint", icon = "windows" },

windows = {
    levels = {
        { level = 1, id = "light", label = "Light" },
        { level = 2, id = "dark",  label = "Dark" },
        { level = 3, id = "limo",  label = "Limo" },
    },
},
support = {
    apollo = { lights = false, windows = false },  -- no glass (motorcycle)
    kusanagi = { windows = false },                -- no glass (motorcycle)
    bandit = { lights = false },
},
unsupported = {
    windows = "This model has no tintable windows.",
    -- client side (skipped `tint:not_covered`):
    clientWindows = "Your game has not loaded the window tint pack. Reconnect to the server.",
},
camera = { presets = { windows = { angle = 0, radius = 5, height = 1.3, targetHeight = 0.9, orbit = true } } },
```

`server/config/vehicle_customization.lua`:

```lua
windows = { 1500, 2500, 3500 },  -- price per level (light, dark, limo) -- PLACEHOLDER, owner to review
-- back to factory glass: owner to decide (free, or a removal fee like performance)
```

On Galena, Thrax, Cortes and Columbus a few panes stay factory clear (§3). Columbus would
tint only its two front side windows. Light RP may sell these as they are, or set
`<key> = { windows = false }`; the owner decides after T5.

Light RP's module today asserts one flat amount per category, so `windows` as a table needs
a small module change, like `performance`. That is Light RP's code, not this campaign's
platform work.

## 8. What the lead must test in game

T0 needs no pack: only vanilla appearances and a small debug-bridge command that the lead or
C adds, for example `vehicle.meshapp <id> <component> <appearance> [event|toggle]`. T2
onward needs the generator, which is gated by this decision.

| # | Test | Pass criterion |
|---|---|---|
| **T0** | Colby (`Vehicle.v_standard2_thorton_colby_player`, factory): switch `window_fl` from `default` to the **vanilla** `tinted` (`#2f2f2f`), once with `event` and once with `toggle`. Also Hella `window_bl`: `tinted` → `default`. | The window visibly darkens (or clears) on the switching client within a second. Note which mechanism works; that is the §5 step 6 decision. |
| **T1** | On the switched Colby: open and close the door, roll the window down and up, enter and exit, drive 30 s, leave and return beyond streaming range, `setAppearance` to a trim and back. | The tint stays, or comes back with the re-apply triggers of §5. Record each case where it resets. |
| **T1b** | Shoot the switched window; repair the car. | Bullet holes and shatter show on the tinted glass. Check whether the mesh appearance changes on damage or repair (H1). |
| **T2** | Single-mesh lab pack: Colby `window_fl` with `open77_tint3__default` → `glass_tint3.mi`. Switch it as in T0. | The window shows the limo look. The ArchiveXL log has no "didn't have material stub" warning, and the `stickers` chunk keeps its look. This proves patched-appearance material resolution on a vehicle mesh. |
| **T3** | Full pack, three levels on Hella (clear sides) and Galena (factory already tinted): view from outside (day, night, neon on) and from the driver seat in first person. | Three distinct levels, the driver can see out at limo, and the windshield stays clear. Tune the six `.mi` values if needed. |
| **T4** | Two clients: A sets level 3 on a car B is watching; B joins late; bucket change. | B sees the same level in every case. |
| **T5** | Every one of the 13 models at level 2 through the tool, including Supron trunk glass, Maimai door glass and Columbus. | Every listed component tints. A `tint:not_covered` log appears only for motorcycles. Note how visible the factory-clear panes are on Galena, Thrax, Cortes and Columbus; the owner decides whether they ship partial. |
| **T6** (only if T5 calls for it) | Lab patch of one body mesh (Thrax `body_01`, appearance `urban_02`) with the glass chunks swapped; paint the car, switch the body component, repaint, damage it. | The paint stays, the quarter glass tints, and no chunk turns black or default. This decides whether body or door meshes can join the pack. |

No x64dbg or Ghidra step is needed: the route uses no new address.
