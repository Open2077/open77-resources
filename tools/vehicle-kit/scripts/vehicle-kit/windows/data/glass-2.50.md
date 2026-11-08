# Window glass of the Light RP dealer models (2.50)

> Generated offline by `scripts/vehicle-kit/windows/glass_inventory.py` from the installed game (WolvenKit CLI) and the Light RP trims table. Metadata only. Full data: `glass-2.50.json`.

## Material template

`base\materials\vehicle_glass.mt` tint parameters (template defaults):

| parameter | type | default | range |
|---|---|---|---|
| `OpacityBackFace` | Scalar | 0 | 0..1 |
| `Opacity` | Scalar | 1 | 0..1 |
| `GlassTint` | Texture | base\materials\placeholder\white.xbm |  |
| `TintColor` | Color | #a2adb4 a=0 |  |
| `TintSurface` | Color | #81836a a=255 |  |
| `FrontFacesReflectionPower` | Scalar | 1 | 0..10 |
| `BackFacesReflectionPower` | Scalar | 1 | 0..10 |

`base\materials\vehicle_glass_onesided.mt` tint parameters (template defaults):

| parameter | type | default | range |
|---|---|---|---|
| `Opacity` | Scalar | 1 | 0..1 |
| `GlassTint` | Texture | base\materials\placeholder\white.xbm |  |
| `TintColor` | Color | #a2adb4 a=0 |  |
| `TintSurface` | Color | #81836a a=255 |  |
| `FrontFacesReflectionPower` | Scalar | 1 | 0..10 |

`base\materials\vehicle_glass_proxy.mt` tint parameters (template defaults):

| parameter | type | default | range |
|---|---|---|---|
| `GlassTint` | Texture | base\materials\placeholder\white.xbm |  |
| `TintColor` | Color | #a2adb4 a=0 |  |
| `FrontFacesReflectionPower` | Scalar | 1 | 0..10 |

## Base material instances used by the glass chunks

| base `.mi` | template | TintColor | Opacity | OpacityBackFace | BackFacesReflectionPower |
|---|---|---|---|---|---|
| `vehicle_glass.mt` | `vehicle_glass.mt` | — |  |  |  |
| `vehicle_glass_onesided.mt` | `vehicle_glass_onesided.mt` | — |  |  |  |
| `glass_exterior_generic.mi` | `vehicle_glass.mt` | #e3e3e3 | 1 | 1 | 0.05 |
| `glass_exterior_generic_tinted_black.mi` | `vehicle_glass.mt` | #636e71 | 1 | 0.5 | 0 |
| `glass_ui_generic.mi` | `vehicle_glass_onesided.mt` | #d0f4ff | 0.8 |  |  |
| `glass_ui_generic_dusty.mi` | `vehicle_glass_onesided.mt` | #d0f4ff | 0.8 |  |  |
| `glass_windshield.mi` | `vehicle_glass.mt` | #e3e3e3 | 1 | 1 | 0 |
| `glass_windshield_tinted_black.mi` | `vehicle_glass.mt` | #636e71 | 1 | 0.5 | 0 |
| `proxy_vehicle_glass.mi` | `vehicle_glass_proxy.mt` | — |  |  |  |

## Per model

Factory = the record's player appearance; trims = the curated Light RP trims. **Tintable** = side and rear glass whose chunk material derives from a `vehicle_glass*.mt` template; the windshield (`window_f`) is listed but left out of the tint.

| model | tintable | glass components (tintable) | windshield | meshes | glass mesh appearances used (factory / trims) | base `.mi` | TintColor today | glass in other meshes |
|---|---|---|---|---|---|---|---|---|
| maimai | yes | `window_b`, `window_fl_a`, `window_fl_b`, `window_fl_c`, `window_fr_a`, `window_fr_b`, `window_fr_c` | `window_f` | 7 | Factory: default; Suburban: default; GT: default; Worn I: default; Worn II: default | glass_exterior_generic.mi | #e3e3e3 | `None`, `interior_01`, `steering_wheel` |
| galena | yes | `window_b`, `window_bl`, `window_br`, `window_fl`, `window_fr` | `window_f` | 5 | Factory: voodoo_01; Suburban: default; GT: voodoo_01; Worn I: default; Worn II: default | glass_exterior_generic.mi, glass_windshield_tinted_black.mi | #373d3f, #636e71, #adc4ca, #e3e3e3 | `None`, `body_01`, `interior_01` |
| apollo | no — no glass component (motorcycle) | — | — | 0 | Factory: —; Street: — | — | — | `None`, `body_player`, `fairing_a_01`, `fairing_player_01`, `v_sportbike3_brennan_apollo__ext01_body_a_01` |
| hella | yes | `window_b`, `window_bl`, `window_bl_02_01`, `window_br`, `window_br_02`, `window_fl`, `window_fr` | `window_f` | 7 | Factory: default, tinted; Suburban: default; Worn I: default; Worn II: default; Worn III: default; Worn IV: default | glass_exterior_generic.mi, glass_exterior_generic_tinted_black.mi | #636e71, #c5dde3, #e3e3e3 | `None`, `interior_01`, `v_standard2_archer_hella__int01_v_console_01` |
| colby | yes | `window_b`, `window_bl`, `window_br`, `window_fl`, `window_fr` | `window_f` | 5 | Factory: default; Suburban I: default; Suburban II: default; Urban: default; Worn: default | glass_exterior_generic.mi | #adc4ca, #e3e3e3 | `None`, `interior_01` |
| quartz | yes | `window_b`, `window_bl`, `window_br`, `window_fl`, `window_fr` | `window_f` | 5 | Factory: default; Suburban: default; Urban: default; Worn I: default; Worn II: default; Worn III: default; Worn IV: default | glass_exterior_generic.mi | #adc4ca, #e3e3e3 | `None`, `interior_01` |
| hozuki | yes | `trunk_a_window_01`, `window_bl`, `window_bl_02`, `window_br`, `window_br_02`, `window_fl`, `window_fr` | `window_f` | 7 | Factory: dark_01, default; Urban: default | glass_exterior_generic.mi, glass_exterior_generic_tinted_black.mi, glass_windshield.mi, glass_windshield_tinted_black.mi | #636e71, #e3e3e3 | `None`, `body_01`, `interior_02` |
| supron | yes | `body_01_window_bl_01`, `body_01_window_br_01`, `trunk_a_window_01`, `trunk_b_window_01`, `window_bl`, `window_br`, `window_fl`, `window_fr` | `window_f` | 8 | Factory: default; Urban: default | glass_exterior_generic.mi, vehicle_glass_onesided.mt | #010159, #e3e3e3 | `None`, `interior_01` |
| columbus | yes | `window_fl`, `window_fr` | `window_f` | 2 | Factory: default; Suburban I: default; Suburban II: default | glass_exterior_generic.mi | #e3e3e3 | `None`, `interior_01`, `mirror_fl_01`, `mirror_fr_01`, `trunk_b` |
| cortes | yes | `window_b`, `window_bl`, `window_bl_02`, `window_br`, `window_br_02`, `window_fl`, `window_fr` | `window_f` | 7 | Factory: padre; Suburban: default; Worn: default | glass_exterior_generic.mi, glass_exterior_generic_tinted_black.mi | #636e71, #e3e3e3 | `None`, `door_bl_a`, `door_br_a`, `interior_01` |
| thrax | yes | `window_b`, `window_bl`, `window_br`, `window_fl`, `window_fr` | `window_f` | 5 | Factory: default | glass_exterior_generic.mi | #adc4ca, #e3e3e3 | `None`, `body_01`, `interior_01` |
| bandit | yes | `window_b`, `window_bl`, `window_br`, `window_fl`, `window_fr` | `window_f` | 5 | Factory: default | glass_exterior_generic.mi | #adc4ca, #e3e3e3 | `None`, `interior_02`, `steering_wheel_02` |
| merrimac | yes | `window_b_player_01`, `window_bl`, `window_bl_02`, `window_br`, `window_br_02`, `window_fl`, `window_fr` | `window_f` | 7 | Factory: dark, default | glass_exterior_generic.mi, glass_exterior_generic_tinted_black.mi, glass_windshield.mi | #636e71 | `None`, `interior_01`, `screen_fl_01`, `screen_fr_01`, `seats_b_01`, `seats_fl_01`, `stwheel_01` |
| semimaru | yes | `window_back`, `window_fl`, `window_fl_02`, `window_fr`, `window_fr_02` | `window_f` | 5 | Factory: default | glass_exterior_generic_tinted_black.mi | #636e71, #8a9699 | `None`, `interior_01` |
| kusanagi | no — no glass component (motorcycle) | — | — | 0 | Factory: —; R250: —; R250 Naked: —; Street: — | — | — | `None`, `v_sportbike1_yaiba_kusanagi__ext01_body_011080` |

## Glass components, factory appearance

| model | component | type | slot | mesh | mesh appearance | glass material | base `.mi` | TintColor | Opacity | OpacityBackFace |
|---|---|---|---|---|---|---|---|---|---|---|
| maimai | `window_f` (windshield) | PhysicalMeshComponent | `Base` | `v_standard2_makigai_maimai__ext01_window_f_01.mesh` | `default` | `glass` | `glass_windshield.mi` | #c5dde3 | 1 | 1 |
| maimai | `window_b` | PhysicalMeshComponent | `Base` | `v_standard2_makigai_maimai__ext01_window_b_01.mesh` | `default` | `glass` | `glass_exterior_generic.mi` | #e3e3e3 | 0.3 | 1 |
| maimai | `window_fr_c` | PhysicalMeshComponent | `Base` | `v_standard2_makigai_maimai__ext01_window_fr_c_01.mesh` | `default` | `glass` | `glass_exterior_generic.mi` | #e3e3e3 | 0.5 | 1 |
| maimai | `window_fl_c` | PhysicalMeshComponent | `Base` | `v_standard2_makigai_maimai__ext01_window_fl_c_01.mesh` | `default` | `glass` | `glass_exterior_generic.mi` | #e3e3e3 | 0.5 | 1 |
| maimai | `window_fl_a` | PhysicalMeshComponent | `door_front_left_a` | `v_standard2_makigai_maimai__ext01_window_fl_01.mesh` | `default` | `glass` | `glass_exterior_generic.mi` | #e3e3e3 | 0.5 | 1 |
| maimai | `window_fl_b` | PhysicalMeshComponent | `door_front_left_b` | `v_standard2_makigai_maimai__ext01_window_fl_b_01.mesh` | `default` | `glass` | `glass_exterior_generic.mi` | #e3e3e3 | 0.5 | 1 |
| maimai | `window_fr_a` | PhysicalMeshComponent | `door_front_right_a` | `v_standard2_makigai_maimai__ext01_window_fr_01.mesh` | `default` | `glass` | `glass_exterior_generic.mi` | #e3e3e3 | 0.5 | 1 |
| maimai | `window_fr_b` | PhysicalMeshComponent | `door_front_right_b` | `v_standard2_makigai_maimai__ext01_window_fr_b_01.mesh` | `default` | `glass` | `glass_exterior_generic.mi` | #e3e3e3 | 0.5 | 1 |
| maimai | `interior_01` | PhysicalMeshComponent | `Base` | `v_standard2_makigai_maimai__int01_interior_01.mesh` | `urban_02` | `ui_glass` | `glass_ui_generic_dusty.mi` | #d0f4ff | 0.8 |  |
| maimai | `steering_wheel` | PhysicalMeshComponent | `steering_wheel` | `v_standard2_makigai_maimai__int01_stwheel_01.mesh` | `urban_02` | `ui_glass` | `glass_ui_generic_dusty.mi` | #d0f4ff | 0.8 |  |
| maimai | `None` | AppearanceProxyMeshComponent | `deformation_rig` | `mproxy_maimai_player_01.mesh` | `default` | `Glass` | `vehicle_glass_onesided.mt` | — |  |  |
| galena | `body_01` | PhysicalMeshComponent | `Base` | `v_standard2_thorton_galena__ext01_body_01.mesh` | `destroyed_02` | `glass` | `glass_exterior_generic.mi` | #e3e3e3 | 0.99 | 1 |
| galena | `window_f` (windshield) | PhysicalMeshComponent | `Base` | `v_standard2_thorton_galena__ext01_window_f_01.mesh` | `default` | `glass` | `glass_windshield.mi` | #e3e3e3 | 1 | 1 |
| galena | `window_bl` | PhysicalMeshComponent | `window_back_left_a` | `v_standard2_thorton_galena__ext01_window_bl_01.mesh` | `voodoo_01` | `voodoo_01` | `glass_windshield_tinted_black.mi` | #636e71 | 1 | 0.5 |
| galena | `window_br` | PhysicalMeshComponent | `window_back_right_a` | `v_standard2_thorton_galena__ext01_window_br_01.mesh` | `voodoo_01` | `voodoo_01` | `glass_windshield_tinted_black.mi` | #636e71 | 1 | 0.5 |
| galena | `window_fl` | PhysicalMeshComponent | `window_front_left_a` | `v_standard2_thorton_galena__ext01_window_fl_01.mesh` | `voodoo_01` | `voodoo_01` | `glass_windshield_tinted_black.mi` | #636e71 | 1 | 0.5 |
| galena | `window_fr` | PhysicalMeshComponent | `window_front_right_a` | `v_standard2_thorton_galena__ext01_window_fr_01.mesh` | `voodoo_01` | `voodoo_01` | `glass_windshield_tinted_black.mi` | #636e71 | 1 | 0.5 |
| galena | `window_b` | PhysicalMeshComponent | `trunk_a` | `v_standard2_thorton_galena__ext01_window_b_01.mesh` | `voodoo_01` | `voodoo_01` | `glass_windshield_tinted_black.mi` | #373d3f | 1 | 0.5 |
| galena | `interior_01` | PhysicalMeshComponent | `Base` | `v_standard2_thorton_galena__int01_interior_01.mesh` | `poor_01` | `ui_glass` | `glass_ui_generic_dusty.mi` | #d0f4ff | 0.8 |  |
| galena | `None` | AppearanceProxyMeshComponent | `deformation_rig` | `thorton_galena__basic_player_01.mesh` | `default` | `Glass` | `vehicle_glass_onesided.mt` | — |  |  |
| apollo | `v_sportbike3_brennan_apollo__ext01_body_a_01` | PhysicalMeshComponent | `Base` | `v_sportbike3_brennan_apollo__ext01_body_a_01.mesh` | `player_01` | `light_covers_glass` | `glass_ui_generic.mi` | #d0f4ff | 0.8 |  |
| apollo | `fairing_a_01` | PhysicalMeshComponent | `Base` | `v_sportbike3_brennan_apollo__ext01_fairing_a_01.mesh` | `player_01` | `windows_glass_2` | `glass_exterior_generic.mi` | #ffd3d3 | 0.99 | 0.04 |
| apollo | `None` | AppearanceProxyMeshComponent | `deformation_rig` | `mproxy_brennan_player_01.mesh` | `default` | `glass` | `vehicle_glass_onesided.mt` | — |  |  |
| hella | `window_bl` | PhysicalMeshComponent | `window_back_left_a` | `v_standard2_archer_hella__ext01_window_bl_01.mesh` | `tinted` | `windows_glass_tinted` | `glass_exterior_generic_tinted_black.mi` | #636e71 | 1 | 0.5 |
| hella | `window_br` | PhysicalMeshComponent | `window_back_right_a` | `v_standard2_archer_hella__ext01_window_br_01.mesh` | `tinted` | `windows_glass_tinted` | `glass_exterior_generic_tinted_black.mi` | #636e71 | 1 | 0.5 |
| hella | `window_fl` | PhysicalMeshComponent | `window_front_left_a` | `v_standard2_archer_hella__ext01_window_fl_01.mesh` | `default` | `windows_glass` | `glass_exterior_generic.mi` | #e3e3e3 | 1 | 1 |
| hella | `window_f` (windshield) | PhysicalMeshComponent | `Base` | `v_standard2_archer_hella__ext01_window_f_01.mesh` | `default` | `windows_glass` | `glass_windshield.mi` | #e3e3e3 | 1 | 1 |
| hella | `window_b` | PhysicalMeshComponent | `Base` | `v_standard2_archer_hella__ext01_window_b_01.mesh` | `tinted` | `windows_glass_tinted` | `glass_exterior_generic_tinted_black.mi` | #636e71 | 1 | 0.5 |
| hella | `window_bl_02_01` | PhysicalMeshComponent | `Base` | `v_standard2_archer_hella__ext01_window_bl_02_01.mesh` | `tinted` | `windows_glass_tinted` | `glass_exterior_generic_tinted_black.mi` | #636e71 | 1 | 0.5 |
| hella | `window_br_02` | PhysicalMeshComponent | `Base` | `v_standard2_archer_hella__ext01_window_br_02_01.mesh` | `tinted` | `windows_glass_tinted` | `glass_exterior_generic_tinted_black.mi` | #636e71 | 1 | 0.5 |
| hella | `interior_01` | PhysicalMeshComponent | `Base` | `v_standard2_archer_hella__int01_interior_01.mesh` | `player_01` | `glass_ui` | `glass_ui_generic.mi` | #d0f4ff | 0.8 |  |
| hella | `window_fr` | PhysicalMeshComponent | `window_front_right_a` | `v_standard2_archer_hella__ext01_window_fr_01.mesh` | `default` | `windows_glass` | `glass_exterior_generic.mi` | #e3e3e3 | 1 | 1 |
| hella | `v_standard2_archer_hella__int01_v_console_01` | PhysicalMeshComponent | `Base` | `v_standard2_archer_hella__int01_v_console_01.mesh` | `default` | `ui_glass` | `glass_ui_generic.mi` | #d0f4ff | 0.8 |  |
| hella | `None` | AppearanceProxyMeshComponent | `deformation_rig` | `archer_hella__basic_player_01.mesh` | `default` | `Glass` | `vehicle_glass_onesided.mt` | — |  |  |
| colby | `window_f` (windshield) | PhysicalMeshComponent | `Base` | `v_standard2_thorton_colby__ext01_window_f_01.mesh` | `default` | `windows_glass` | `glass_windshield.mi` | #adc4ca | 0.9 | 0.9 |
| colby | `window_bl` | PhysicalMeshComponent | `Base` | `v_standard2_thorton_colby__ext01_window_bl_01.mesh` | `default` | `windows_glass` | `glass_exterior_generic.mi` | #e3e3e3 | 1 | 1 |
| colby | `window_br` | PhysicalMeshComponent | `Base` | `v_standard2_thorton_colby__ext01_window_br_01.mesh` | `default` | `windows_glass` | `glass_exterior_generic.mi` | #e3e3e3 | 1 | 1 |
| colby | `window_fr` | PhysicalMeshComponent | `window_front_right_a` | `v_standard2_thorton_colby__ext01_window_fr_01.mesh` | `default` | `windows_glass` | `glass_exterior_generic.mi` | #adc4ca | 0.9 | 0.9 |
| colby | `window_fl` | PhysicalMeshComponent | `window_front_left_a` | `v_standard2_thorton_colby__ext01_window_fl_01.mesh` | `default` | `windows_glass` | `glass_exterior_generic.mi` | #adc4ca | 0.9 | 0.9 |
| colby | `window_b` | PhysicalMeshComponent | `trunk_a` | `v_standard2_thorton_colby__ext01_window_b_01.mesh` | `default` | `windows_glass` | `glass_exterior_generic.mi` | #adc4ca | 0.9 | 0.9 |
| colby | `interior_01` | PhysicalMeshComponent | `Base` | `v_standard2_thorton_colby__int01_interior_01.mesh` | `poor_01` | `ui_glass` | `glass_ui_generic_dusty.mi` | #d0f4ff | 0.8 |  |
| colby | `None` | AppearanceProxyMeshComponent | `deformation_rig` | `thorton_colby__basic_player_01.mesh` | `default` | `Glass` | `vehicle_glass_onesided.mt` | — |  |  |
| quartz | `window_f` (windshield) | PhysicalMeshComponent | `Base` | `v_standard2_archer_quartz__ext01_window_f_01.mesh` | `default` | `windows_glass` | `glass_exterior_generic.mi` | #adc4ca | 0.9 | 0.9 |
| quartz | `window_b` | PhysicalMeshComponent | `Base` | `v_standard2_archer_quartz__ext01_window_b_01.mesh` | `default` | `windows_glass` | `glass_exterior_generic.mi` | #e3e3e3 | 1 | 1 |
| quartz | `window_bl` | PhysicalMeshComponent | `Base` | `v_standard2_archer_quartz__ext01_window_bl_01.mesh` | `default` | `windows_glass` | `glass_exterior_generic.mi` | #adc4ca | 0.9 | 0.9 |
| quartz | `window_br` | PhysicalMeshComponent | `Base` | `v_standard2_archer_quartz__ext01_window_br_01.mesh` | `default` | `windows_glass` | `glass_exterior_generic.mi` | #adc4ca | 0.9 | 0.9 |
| quartz | `window_fl` | PhysicalMeshComponent | `window_front_left_a` | `v_standard2_archer_quartz__ext01_window_fl_01.mesh` | `default` | `windows_glass` | `glass_exterior_generic.mi` | #e3e3e3 | 1 | 1 |
| quartz | `window_fr` | PhysicalMeshComponent | `window_front_right_a` | `v_standard2_archer_quartz__ext01_window_fr_01.mesh` | `default` | `windows_glass` | `glass_exterior_generic.mi` | #e3e3e3 | 1 | 1 |
| quartz | `interior_01` | PhysicalMeshComponent | `Base` | `v_standard2_archer_quartz__int01_interior_01.mesh` | `urban_03` | `glass_ui` | `glass_ui_generic.mi` | #d0f4ff | 0.8 |  |
| quartz | `None` | AppearanceProxyMeshComponent | `deformation_rig` | `archer_quartz__basic_player_01.mesh` | `default` | `Glass` | `vehicle_glass_onesided.mt` | — |  |  |
| hozuki | `window_bl` | PhysicalMeshComponent | `window_back_left_a` | `v_standard2_mizutani_hozuki__ext01_window_bl_01.mesh` | `dark_01` | `windows_glass_dark` | `glass_exterior_generic_tinted_black.mi` | #636e71 | 1 | 0.5 |
| hozuki | `window_bl_02` | PhysicalMeshComponent | `door_bl_a` | `v_standard2_mizutani_hozuki__ext01_window_bl_02.mesh` | `dark_01` | `windows_glass_dark` | `glass_exterior_generic_tinted_black.mi` | #636e71 | 1 | 0.5 |
| hozuki | `window_br` | PhysicalMeshComponent | `window_back_right_a` | `v_standard2_mizutani_hozuki__ext01_window_br_01.mesh` | `dark_01` | `windows_glass_dark` | `glass_exterior_generic_tinted_black.mi` | #636e71 | 1 | 0.5 |
| hozuki | `window_br_02` | PhysicalMeshComponent | `door_br_a` | `v_standard2_mizutani_hozuki__ext01_window_br_02.mesh` | `dark_01` | `windows_glass_dark` | `glass_exterior_generic_tinted_black.mi` | #636e71 | 1 | 0.5 |
| hozuki | `window_fr` | PhysicalMeshComponent | `window_front_right_a` | `v_standard2_mizutani_hozuki__ext01_window_fr_01.mesh` | `default` | `windows_glass` | `glass_exterior_generic.mi` | #e3e3e3 | 1 | 1 |
| hozuki | `window_fl` | PhysicalMeshComponent | `window_front_left_a` | `v_standard2_mizutani_hozuki__ext01_window_fl_01.mesh` | `default` | `windows_glass` | `glass_exterior_generic.mi` | #e3e3e3 | 1 | 1 |
| hozuki | `window_f` (windshield) | PhysicalMeshComponent | `Base` | `v_standard2_mizutani_hozuki__ext01_window_f_player_01.mesh` | `default` | `windows_glass` | `glass_windshield.mi` | #e3e3e3 | 1 | 1 |
| hozuki | `trunk_a_window_01` | PhysicalMeshComponent | `trunk_a` | `v_standard2_mizutani_hozuki__ext01_window_b_01.mesh` | `dark_01` | `windows_glass_dark` | `glass_windshield_tinted_black.mi` | #636e71 | 1 | 0.5 |
| hozuki | `interior_02` | PhysicalMeshComponent | `Base` | `v_standard2_mizutani_hozuki__int01_interior_player_01.mesh` | `default` | `glass_ui` | `glass_ui_generic.mi` | #d0f4ff | 0.8 |  |
| hozuki | `None` | AppearanceProxyMeshComponent | `deformation_rig` | `mizutani_hozuki__basic_player_01.mesh` | `default` | `Glass` | `vehicle_glass_onesided.mt` | — |  |  |
| supron | `body_01_window_bl_01` | PhysicalMeshComponent | `Base` | `v_standard25_mahir_supron__ext01_body_01_window_bl_01.mesh` | `default` | `glass` | `glass_exterior_generic.mi` | #e3e3e3 | 1 | 1 |
| supron | `window_f` (windshield) | PhysicalMeshComponent | `Base` | `v_standard25_mahir_supron__ext01_window_f_01.mesh` | `default` | `glass` | `glass_windshield.mi` | #e3e3e3 | 1 | 1 |
| supron | `body_01_window_br_01` | PhysicalMeshComponent | `Base` | `v_standard25_mahir_supron__ext01_body_01_window_br_01.mesh` | `default` | `glass` | `glass_exterior_generic.mi` | #e3e3e3 | 1 | 1 |
| supron | `window_bl` | PhysicalMeshComponent | `window_back_left_a` | `v_standard25_mahir_supron__ext01_window_bl_01.mesh` | `default` | `glass` | `glass_exterior_generic.mi` | #e3e3e3 | 1 | 1 |
| supron | `window_fr` | PhysicalMeshComponent | `window_front_right_a` | `v_standard25_mahir_supron__ext01_window_fr_01.mesh` | `default` | `glass` | `glass_exterior_generic.mi` | #e3e3e3 | 1 | 1 |
| supron | `window_fl` | PhysicalMeshComponent | `window_front_left_a` | `v_standard25_mahir_supron__ext01_window_fl_01.mesh` | `default` | `glass` | `glass_exterior_generic.mi` | #e3e3e3 | 1 | 1 |
| supron | `window_br` | PhysicalMeshComponent | `window_back_right_a` | `v_standard25_mahir_supron__ext01_window_br_01.mesh` | `default` | `glass` | `glass_exterior_generic.mi` | #e3e3e3 | 1 | 1 |
| supron | `interior_01` | PhysicalMeshComponent | `Base` | `v_standard25_mahir_supron__int01_interior_01.mesh` | `poor_04` | `glass_ui` | `glass_ui_generic_dusty.mi` | #d0f4ff | 0.8 |  |
| supron | `trunk_b_window_01` | PhysicalMeshComponent | `trunk_b` | `v_standard25_mahir_supron__ext01_trunk_b_window_01.mesh` | `default` | `glass` | `vehicle_glass_onesided.mt` | #010159 | 0.8 |  |
| supron | `trunk_a_window_01` | PhysicalMeshComponent | `trunk_a` | `v_standard25_mahir_supron__ext01_trunk_a_window_01.mesh` | `default` | `glass` | `vehicle_glass_onesided.mt` | #010159 | 0.8 |  |
| supron | `None` | AppearanceProxyMeshComponent | `deformation_rig` | `mahir_supron__basic_player_01.mesh` | `default` | `Glass` | `vehicle_glass_onesided.mt` | — |  |  |
| columbus | `window_f` (windshield) | PhysicalMeshComponent | `Base` | `v_standard25_villefort_columbus__ext01_window_f_01.mesh` | `default` | `glass` | `glass_windshield.mi` | #e3e3e3 | 1 | 1 |
| columbus | `window_fr` | PhysicalMeshComponent | `window_front_right_a` | `v_standard25_villefort_columbus__ext01_window_fr_01.mesh` | `default` | `glass` | `glass_exterior_generic.mi` | #e3e3e3 | 1 | 1 |
| columbus | `mirror_fr_01` | PhysicalMeshComponent | `door_fr_a` | `v_standard25_villefort_columbus__ext01_door_fr_mirror_01.mesh` | `suburban_02` | `glass` | `glass_exterior_generic.mi` | #556062 | 1 | 1 |
| columbus | `window_fl` | PhysicalMeshComponent | `window_front_left_a` | `v_standard25_villefort_columbus__ext01_window_fl_01.mesh` | `default` | `glass` | `glass_exterior_generic.mi` | #e3e3e3 | 1 | 1 |
| columbus | `mirror_fl_01` | PhysicalMeshComponent | `door_fl_a` | `v_standard25_villefort_columbus__ext01_door_fl_mirror_01.mesh` | `suburban_02` | `light_cover_glass` | `glass_exterior_generic.mi` | #535e61 | 1 | 1 |
| columbus | `trunk_b` | PhysicalMeshComponent | `trunk_b` | `v_standard25_villefort_columbus__ext01_trunk_b_01.mesh` | `suburban_02` | `cover_glass` | `glass_exterior_generic.mi` | #3f5c63 | 1 | 1 |
| columbus | `interior_01` | PhysicalMeshComponent | `Base` | `v_standard25_villefort_columbus__int01_interior_01.mesh` | `poor_01` | `glass_ui` | `glass_ui_generic_dusty.mi` | #d0f4ff | 0.8 |  |
| columbus | `None` | AppearanceProxyMeshComponent | `deformation_rig` | `villefort_columbus__basic_player_01.mesh` | `default` | `Glass` | `vehicle_glass_onesided.mt` | — |  |  |
| cortes | `window_b` | PhysicalMeshComponent | `Base` | `v_standard2_villefort_cortes__ext01_window_b_01.mesh` | `padre` | `glass_padre` | `glass_exterior_generic_tinted_black.mi` | #636e71 | 1 | 0.5 |
| cortes | `window_f` (windshield) | PhysicalMeshComponent | `Base` | `v_standard2_villefort_cortes__ext01_windshield_01.mesh` | `default` | `glass_windshield` | `glass_windshield.mi` | #e3e3e3 | 1 | 1 |
| cortes | `window_bl` | PhysicalMeshComponent | `window_back_left_a` | `v_standard2_villefort_cortes__ext01_door_window_bl_01.mesh` | `padre` | `glass_padre` | `glass_exterior_generic_tinted_black.mi` | #636e71 | 1 | 0.5 |
| cortes | `door_bl_a` | PhysicalMeshComponent | `door_back_left_a` | `v_standard2_villefort_cortes__ext01_door_bl_01.mesh` | `urban_06` | `glass_exterior_generic` | `glass_exterior_generic.mi` | #e3e3e3 | 1 | 1 |
| cortes | `window_bl_02` | PhysicalMeshComponent | `door_bl_a` | `v_standard2_villefort_cortes__ext01_door_glass_bl_01.mesh` | `padre` | `glass_padre` | `glass_exterior_generic_tinted_black.mi` | #636e71 | 1 | 0.5 |
| cortes | `window_br` | PhysicalMeshComponent | `window_back_right_a` | `v_standard2_villefort_cortes__ext01_door_window_br_01.mesh` | `padre` | `glass_padre` | `glass_exterior_generic_tinted_black.mi` | #636e71 | 1 | 0.5 |
| cortes | `door_br_a` | PhysicalMeshComponent | `door_back_right_a` | `v_standard2_villefort_cortes__ext01_door_br_01.mesh` | `urban_06` | `glass_exterior_generic` | `glass_exterior_generic.mi` | #e3e3e3 | 1 | 1 |
| cortes | `window_br_02` | PhysicalMeshComponent | `door_br_a` | `v_standard2_villefort_cortes__ext01_door_glass_br_01.mesh` | `padre` | `glass_padre` | `glass_exterior_generic_tinted_black.mi` | #636e71 | 1 | 0.5 |
| cortes | `window_fl` | PhysicalMeshComponent | `window_front_left_a` | `v_standard2_villefort_cortes__ext01_door_window_fl_01.mesh` | `padre` | `glass_padre` | `glass_exterior_generic_tinted_black.mi` | #636e71 | 1 | 0.5 |
| cortes | `window_fr` | PhysicalMeshComponent | `window_front_right_a` | `v_standard2_villefort_cortes__ext01_door_window_fr_01.mesh` | `padre` | `glass_padre` | `glass_exterior_generic_tinted_black.mi` | #636e71 | 1 | 0.5 |
| cortes | `interior_01` | PhysicalMeshComponent | `Base` | `v_standard2_villefort_cortes__int01_interior_01.mesh` | `urban_06` | `glass_ui` | `glass_ui_generic_dusty.mi` | #d0f4ff | 0.8 |  |
| cortes | `None` | AppearanceProxyMeshComponent | `deformation_rig` | `villefort_cortes__basic_player_01.mesh` | `default` | `Glass` | `vehicle_glass_onesided.mt` | — |  |  |
| thrax | `window_b` | PhysicalMeshComponent | `Base` | `v_standard2_chevalier_thrax__ext01_window_b_01.mesh` | `default` | `glass` | `glass_exterior_generic.mi` | #adc4ca | 0.9 | 0.9 |
| thrax | `body_01` | PhysicalMeshComponent | `Base` | `v_standard2_chevalier_thrax__ext01_body_01.mesh` | `urban_02` | `glass` | `glass_exterior_generic.mi` | #e3e3e3 | 1 | 1 |
| thrax | `window_f` (windshield) | PhysicalMeshComponent | `Base` | `v_standard2_chevalier_thrax__ext01_window_f_01.mesh` | `default` | `glass` | `glass_exterior_generic.mi` | #adc4ca | 0.9 | 0.9 |
| thrax | `interior_01` | PhysicalMeshComponent | `Base` | `v_standard2_chevalier_thrax__int01_interior_01.mesh` | `default` | `ui_glass` | `glass_ui_generic_dusty.mi` | #d0f4ff | 0.8 |  |
| thrax | `window_fl` | PhysicalMeshComponent | `window_front_left_a` | `v_standard2_chevalier_thrax__ext01_window_fl_01.mesh` | `default` | `glass` | `glass_exterior_generic.mi` | #e3e3e3 | 1 | 1 |
| thrax | `window_fr` | PhysicalMeshComponent | `window_front_right_a` | `v_standard2_chevalier_thrax__ext01_window_fr_01.mesh` | `default` | `glass` | `glass_exterior_generic.mi` | #adc4ca | 0.9 | 0.9 |
| thrax | `window_bl` | PhysicalMeshComponent | `window_back_left_a` | `v_standard2_chevalier_thrax__ext01_window_bl_01.mesh` | `default` | `glass` | `glass_exterior_generic.mi` | #e3e3e3 | 1 | 1 |
| thrax | `window_br` | PhysicalMeshComponent | `window_back_right_a` | `v_standard2_chevalier_thrax__ext01_window_br_01.mesh` | `default` | `glass` | `glass_exterior_generic.mi` | #adc4ca | 0.9 | 0.9 |
| thrax | `None` | AppearanceProxyMeshComponent | `deformation_rig` | `chevalier_thrax__basic_player_01.mesh` | `default` | `Glass` | `vehicle_glass_onesided.mt` | — |  |  |
| bandit | `window_f` (windshield) | PhysicalMeshComponent | `Base` | `v_standard2_archer_bandit__ext01_window_f_01.mesh` | `default` | `windows_glass` | `glass_exterior_generic.mi` | #adc4ca | 0.9 | 0.9 |
| bandit | `window_b` | PhysicalMeshComponent | `Base` | `v_standard2_archer_quartz__ext01_window_b_01.mesh` | `default` | `windows_glass` | `glass_exterior_generic.mi` | #e3e3e3 | 1 | 1 |
| bandit | `window_bl` | PhysicalMeshComponent | `Base` | `v_standard2_archer_quartz__ext01_window_bl_01.mesh` | `default` | `windows_glass` | `glass_exterior_generic.mi` | #adc4ca | 0.9 | 0.9 |
| bandit | `window_br` | PhysicalMeshComponent | `Base` | `v_standard2_archer_quartz__ext01_window_br_01.mesh` | `default` | `windows_glass` | `glass_exterior_generic.mi` | #adc4ca | 0.9 | 0.9 |
| bandit | `window_fl` | PhysicalMeshComponent | `window_front_left_a` | `v_standard2_archer_quartz__ext01_window_fl_01.mesh` | `default` | `windows_glass` | `glass_exterior_generic.mi` | #e3e3e3 | 1 | 1 |
| bandit | `window_fr` | PhysicalMeshComponent | `window_front_right_a` | `v_standard2_archer_quartz__ext01_window_fr_01.mesh` | `default` | `windows_glass` | `glass_exterior_generic.mi` | #e3e3e3 | 1 | 1 |
| bandit | `interior_02` | PhysicalMeshComponent | `Base` | `v_standard2_archer_bandit__int01_interior_02.mesh` | `default` | `glass_ui` | `glass_ui_generic.mi` | #d0f4ff | 0.8 |  |
| bandit | `steering_wheel_02` | PhysicalMeshComponent | `steering_wheel` | `v_standard2_archer_bandit__int01_stwheel_02.mesh` | `default` | `glass_ui` | `glass_ui_generic.mi` | #d0f4ff | 0.8 |  |
| bandit | `None` | AppearanceProxyMeshComponent | `deformation_rig` | `mproxy_quartz_bandit.mesh` | `default` | `Glass1` | `vehicle_glass_onesided.mt` | — |  |  |
| merrimac | `window_fr` | PhysicalMeshComponent | `window_front_right_a` | `v_standard25_thorton_merrimac__ext01_window_fr_01.mesh` | `dark` | `windows_glass_dark` | `glass_windshield.mi` | #636e71 | 1 | 0.5 |
| merrimac | `window_fl` | PhysicalMeshComponent | `window_front_left_a` | `v_standard25_thorton_merrimac__ext01_window_fl_01.mesh` | `dark` | `windows_glass_dark` | `glass_windshield.mi` | #636e71 | 1 | 0.5 |
| merrimac | `screen_fl_01` | MeshComponent | `Base` | `v_standard25_thorton_merrimac__int01_screen_fl_01.mesh` | `int_player_01` | `glass_ui` | `glass_ui_generic.mi` | #d0f4ff | 0.8 |  |
| merrimac | `seats_fl_01` | PhysicalMeshComponent | `Base` | `v_standard25_thorton_merrimac__int01_seats_fl_01.mesh` | `player_01` | `glass_ui` | `glass_ui_generic.mi` | #d0f4ff | 0.8 |  |
| merrimac | `stwheel_01` | PhysicalMeshComponent | `steering_wheel` | `v_standard25_thorton_merrimac__int01_stwheel_01.mesh` | `player_01` | `glass_ui` | `glass_ui_generic.mi` | #d0f4ff | 0.8 |  |
| merrimac | `seats_b_01` | PhysicalMeshComponent | `Base` | `v_standard25_thorton_merrimac__int01_seats_b_01.mesh` | `player_01` | `glass_ui` | `glass_ui_generic.mi` | #d0f4ff | 0.8 |  |
| merrimac | `screen_fr_01` | MeshComponent | `Base` | `v_standard25_thorton_merrimac__int01_screen_fr_01.mesh` | `int_player_01` | `glass_ui` | `glass_ui_generic.mi` | #d0f4ff | 0.8 |  |
| merrimac | `window_bl_02` | PhysicalMeshComponent | `Base` | `v_standard25_thorton_merrimac__ext01_window_bl_02.mesh` | `dark` | `windows_glass_dark` | `glass_exterior_generic.mi` | #636e71 | 1 | 0.5 |
| merrimac | `window_b_player_01` | MeshComponent | `Base` | `v_standard25_thorton_merrimac__ext01_window_b_player_01.mesh` | `default` | `windows_glass` | `glass_exterior_generic_tinted_black.mi` | #636e71 | 1 | 0.5 |
| merrimac | `window_br_02` | PhysicalMeshComponent | `Base` | `v_standard25_thorton_merrimac__ext01_window_br_02.mesh` | `dark` | `windows_glass_dark` | `glass_exterior_generic.mi` | #636e71 | 1 | 0.5 |
| merrimac | `window_f` (windshield) | PhysicalMeshComponent | `Base` | `v_standard25_thorton_merrimac__ext01_window_f_01.mesh` | `dark` | `windows_glass_dark` | `glass_windshield.mi` | #636e71 | 1 | 0.5 |
| merrimac | `window_bl` | PhysicalMeshComponent | `window_back_left_a` | `v_standard25_thorton_merrimac__ext01_window_bl_01.mesh` | `dark` | `windows_glass_dark` | `glass_exterior_generic.mi` | #636e71 | 1 | 0.5 |
| merrimac | `window_br` | PhysicalMeshComponent | `window_back_right_a` | `v_standard25_thorton_merrimac__ext01_window_br_01.mesh` | `dark` | `windows_glass_dark` | `glass_exterior_generic.mi` | #636e71 | 1 | 0.5 |
| merrimac | `interior_01` | PhysicalMeshComponent | `Base` | `v_standard25_thorton_merrimac__int01_interior_player_01.mesh` | `default` | `glass_ui` | `glass_ui_generic.mi` | #d0f4ff | 0.8 |  |
| merrimac | `None` | AppearanceProxyMeshComponent | `deformation_rig` | `thorton_merrimac_basic_player_01.mesh` | `default` | `Glass` | `vehicle_glass_onesided.mt` | — |  |  |
| semimaru | `window_f` (windshield) | PhysicalMeshComponent | `Base` | `v_sport1_yaiba_semimaru__ext01_window_f_01.mesh` | `default` | `window_glass` | `glass_windshield.mi` | #e3e3e3 | 1 | 1 |
| semimaru | `interior_01` | PhysicalMeshComponent | `Base` | `v_sport1_yaiba_semimaru__int01_interior_01.mesh` | `default` | `UI_glass` | `glass_ui_generic.mi` | #d0f4ff | 0.8 |  |
| semimaru | `window_fl` | PhysicalMeshComponent | `window_front_left_a` | `v_sport1_yaiba_semimaru__ext01_window_fl_01.mesh` | `default` | `window_glass` | `glass_exterior_generic_tinted_black.mi` | #8a9699 | 1 | 0.5 |
| semimaru | `window_fl_02` | PhysicalMeshComponent | `door_front_left_a` | `v_sport1_yaiba_semimaru__ext01_window_fl_02.mesh` | `default` | `window_glass` | `glass_exterior_generic_tinted_black.mi` | #8a9699 | 1 | 0.5 |
| semimaru | `window_fr` | PhysicalMeshComponent | `window_front_right_a` | `v_sport1_yaiba_semimaru__ext01_window_fr_01.mesh` | `default` | `window_glass` | `glass_exterior_generic_tinted_black.mi` | #636e71 | 1 | 0.5 |
| semimaru | `window_fr_02` | PhysicalMeshComponent | `door_front_right_a` | `v_sport1_yaiba_semimaru__ext01_window_fr_02.mesh` | `default` | `window_glass` | `glass_exterior_generic_tinted_black.mi` | #636e71 | 1 | 0.5 |
| semimaru | `window_back` | PhysicalMeshComponent | `trunk_a` | `v_sport1_yaiba_semimaru__ext01_window_b_01.mesh` | `default` | `window_glass` | `glass_exterior_generic_tinted_black.mi` | #8a9699 | 1 | 0.5 |
| semimaru | `None` | AppearanceProxyMeshComponent | `deformation_rig` | `yaiba_semimaru_basic_urban_01.mesh` | `default` | `Glass` | `vehicle_glass_onesided.mt` | — |  |  |
| kusanagi | `v_sportbike1_yaiba_kusanagi__ext01_body_011080` | PhysicalMeshComponent | `Base` | `v_sportbike1_yaiba_kusanagi__ext01_body_01.mesh` | `default` | `glass` | `glass_windshield.mi` | #ff9012 | 1 | 1 |

## Glass chunks outside the window components (`--deep`)

Every other mesh of the factory and trim appearances was serialized and its chunk materials resolved. A row here is glass the tint would not reach.

| model | component | mesh | mesh appearance | glass materials | base |
|---|---|---|---|---|---|
| maimai | `interior_01` | `v_standard2_makigai_maimai__int01_interior_01.mesh` | `urban_02` | `ui_glass` | `glass_ui_generic_dusty.mi` |
| maimai | `steering_wheel` | `v_standard2_makigai_maimai__int01_stwheel_01.mesh` | `urban_02` | `ui_glass` | `glass_ui_generic_dusty.mi` |
| maimai | `None` | `mproxy_maimai_player_01.mesh` | `default` | `Glass` | `vehicle_glass_onesided.mt` |
| maimai | `interior_01` | `v_standard2_makigai_maimai__int01_interior_01.mesh` | `suburban_02` | `ui_glass` | `glass_ui_generic_dusty.mi` |
| maimai | `steering_wheel` | `v_standard2_makigai_maimai__int01_stwheel_01.mesh` | `suburban_02` | `ui_glass` | `glass_ui_generic_dusty.mi` |
| maimai | `None` | `mproxy_maimai_suburban_01.mesh` | `default` | `Glass` | `vehicle_glass_onesided.mt` |
| maimai | `None` | `mproxy_maimai_gt_01.mesh` | `default` | `Glass` | `vehicle_glass_onesided.mt` |
| maimai | `interior_01` | `v_standard2_makigai_maimai__int01_interior_01.mesh` | `poor_01` | `ui_glass` | `glass_ui_generic_dusty.mi` |
| maimai | `steering_wheel` | `v_standard2_makigai_maimai__int01_stwheel_01.mesh` | `poor_01` | `ui_glass` | `glass_ui_generic_dusty.mi` |
| maimai | `None` | `mproxy_maimai_poor_05.mesh` | `poor_01` | `Glass` | `vehicle_glass_onesided.mt` |
| maimai | `None` | `mproxy_maimai_poor_04.mesh` | `poor_02` | `Glass` | `vehicle_glass_onesided.mt` |
| galena | `body_01` | `v_standard2_thorton_galena__ext01_body_01.mesh` | `destroyed_02` | `glass` | `glass_exterior_generic.mi` |
| galena | `interior_01` | `v_standard2_thorton_galena__int01_interior_01.mesh` | `poor_01` | `ui_glass` | `glass_ui_generic_dusty.mi` |
| galena | `None` | `thorton_galena__basic_player_01.mesh` | `default` | `Glass` | `vehicle_glass_onesided.mt` |
| galena | `body_01` | `v_standard2_thorton_galena__ext01_body_01.mesh` | `suburban_01` | `glass` | `glass_exterior_generic.mi` |
| galena | `interior_01` | `v_standard2_thorton_galena__int01_interior_01.mesh` | `suburban_01` | `ui_glass` | `glass_ui_generic_dusty.mi` |
| galena | `None` | `thorton_galena__basic_suburban_01.mesh` | `default` | `Glass` | `vehicle_glass_onesided.mt` |
| galena | `body_01` | `v_standard2_thorton_galena__ext01_body_01.mesh` | `urban_01` | `glass` | `glass_exterior_generic.mi` |
| galena | `interior_01` | `v_standard2_thorton_galena__int01_interior_01.mesh` | `urban_01` | `ui_glass` | `glass_ui_generic_dusty.mi` |
| galena | `None` | `thorton_galena__basic_gt_01.mesh` | `default` | `Glass` | `vehicle_glass_onesided.mt` |
| galena | `body_01` | `v_standard2_thorton_galena__ext01_body_01.mesh` | `poor_01` | `glass` | `glass_exterior_generic.mi` |
| galena | `None` | `thorton_galena__basic_poor_01.mesh` | `default` | `Glass` | `vehicle_glass_onesided.mt` |
| galena | `body_01` | `v_standard2_thorton_galena__ext01_body_01.mesh` | `industrial_03` | `glass` | `glass_exterior_generic.mi` |
| galena | `interior_01` | `v_standard2_thorton_galena__int01_interior_01.mesh` | `industrial_01` | `ui_glass` | `glass_ui_generic_dusty.mi` |
| galena | `None` | `thorton_galena__basic_poor_09.mesh` | `default` | `Glass` | `vehicle_glass_onesided.mt` |
| apollo | `v_sportbike3_brennan_apollo__ext01_body_a_01` | `v_sportbike3_brennan_apollo__ext01_body_a_01.mesh` | `player_01` | `light_covers_glass` | `glass_ui_generic.mi` |
| apollo | `fairing_a_01` | `v_sportbike3_brennan_apollo__ext01_fairing_a_01.mesh` | `player_01` | `windows_glass_2` | `glass_exterior_generic.mi` |
| apollo | `None` | `mproxy_brennan_player_01.mesh` | `default` | `glass` | `vehicle_glass_onesided.mt` |
| apollo | `body_player` | `v_sportbike3_brennan_apollo__ext01_body_a_player_01.mesh` | `default` | `glass_ui_generic` | `glass_ui_generic.mi` |
| apollo | `fairing_player_01` | `v_sportbike3_brennan_apollo__ext01_fairing_player_01.mesh` | `default` | `stickers_branding`, `windows_glass` | `glass_windshield.mi` |
| apollo | `None` | `brennan_apollo_police_basic_player_02.mesh` | `default` | `Glass` | `vehicle_glass_onesided.mt` |
| hella | `interior_01` | `v_standard2_archer_hella__int01_interior_01.mesh` | `player_01` | `glass_ui` | `glass_ui_generic.mi` |
| hella | `v_standard2_archer_hella__int01_v_console_01` | `v_standard2_archer_hella__int01_v_console_01.mesh` | `default` | `ui_glass` | `glass_ui_generic.mi` |
| hella | `None` | `archer_hella__basic_player_01.mesh` | `default` | `Glass` | `vehicle_glass_onesided.mt` |
| hella | `interior_01` | `v_standard2_archer_hella__int01_interior_01.mesh` | `suburban_01` | `glass_ui` | `glass_ui_generic.mi` |
| hella | `None` | `archer_hella__basic_suburban_1.mesh` | `default` | `Glass` | `vehicle_glass_onesided.mt` |
| hella | `interior_01` | `v_standard2_archer_hella__int01_interior_01.mesh` | `poor_04` | `glass_ui` | `glass_ui_generic.mi` |
| hella | `None` | `archer_hella__basic_poor_1.mesh` | `default` | `Glass` | `vehicle_glass_onesided.mt` |
| hella | `None` | `archer_hella__basic_poor_2.mesh` | `default` | `Glass` | `vehicle_glass_onesided.mt` |
| hella | `interior_01` | `v_standard2_archer_hella__int01_interior_01.mesh` | `poor_01` | `glass_ui` | `glass_ui_generic.mi` |
| hella | `None` | `archer_hella__basic_poor_3.mesh` | `default` | `Glass` | `vehicle_glass_onesided.mt` |
| hella | `interior_01` | `v_standard2_archer_hella__int01_interior_01.mesh` | `poor_03` | `glass_ui` | `glass_ui_generic.mi` |
| hella | `None` | `archer_hella__basic_poor_4.mesh` | `default` | `Glass` | `vehicle_glass_onesided.mt` |
| colby | `interior_01` | `v_standard2_thorton_colby__int01_interior_01.mesh` | `poor_01` | `ui_glass` | `glass_ui_generic_dusty.mi` |
| colby | `None` | `thorton_colby__basic_player_01.mesh` | `default` | `Glass` | `vehicle_glass_onesided.mt` |
| colby | `interior_01` | `v_standard2_thorton_colby__int01_interior_01.mesh` | `suburban_04` | `ui_glass` | `glass_ui_generic_dusty.mi` |
| colby | `None` | `mproxy_suburban_1.mesh` | `default` | `Glass` | `proxy_vehicle_glass.mi` |
| colby | `interior_01` | `v_standard2_thorton_colby__int01_interior_01.mesh` | `default` | `ui_glass` | `glass_ui_generic_dusty.mi` |
| colby | `None` | `mproxy_suburban_2.mesh` | `default` | `Glass` | `proxy_vehicle_glass.mi` |
| colby | `interior_01` | `v_standard2_thorton_colby__int01_interior_01.mesh` | `suburban_03` | `ui_glass` | `glass_ui_generic_dusty.mi` |
| colby | `None` | `mproxy_urban_01.mesh` | `default` | `Glass` | `proxy_vehicle_glass.mi` |
| colby | `None` | `mproxy_poor_02.mesh` | `default` | `Glass` | `proxy_vehicle_glass.mi` |
| quartz | `interior_01` | `v_standard2_archer_quartz__int01_interior_01.mesh` | `urban_03` | `glass_ui` | `glass_ui_generic.mi` |
| quartz | `None` | `archer_quartz__basic_player_01.mesh` | `default` | `Glass` | `vehicle_glass_onesided.mt` |
| quartz | `interior_01` | `v_standard2_archer_quartz__int01_interior_01.mesh` | `suburban_01` | `glass_ui` | `glass_ui_generic.mi` |
| quartz | `None` | `archer_quartz__basic_suburban_1.mesh` | `default` | `Glass` | `vehicle_glass_onesided.mt` |
| quartz | `None` | `archer_quartz__basic_urban_1.mesh` | `default` | `Glass` | `vehicle_glass_onesided.mt` |
| quartz | `interior_01` | `v_standard2_archer_quartz__int01_interior_01.mesh` | `poor_01` | `glass_ui` | `glass_ui_generic.mi` |
| quartz | `None` | `archer_quartz__basic_poor_1.mesh` | `default` | `Glass` | `vehicle_glass_onesided.mt` |
| quartz | `interior_01` | `v_standard2_archer_quartz__int01_interior_01.mesh` | `junk_01` | `glass_ui` | `glass_ui_generic.mi` |
| quartz | `None` | `archer_quartz__basic_poor_2.mesh` | `default` | `Glass` | `vehicle_glass_onesided.mt` |
| quartz | `None` | `archer_quartz__basic_poor_3.mesh` | `default` | `Glass` | `vehicle_glass_onesided.mt` |
| quartz | `None` | `archer_quartz__basic_poor_3.mesh` | `poor_3_4` | `Glass` | `vehicle_glass_onesided.mt` |
| hozuki | `interior_02` | `v_standard2_mizutani_hozuki__int01_interior_player_01.mesh` | `default` | `glass_ui` | `glass_ui_generic.mi` |
| hozuki | `None` | `mizutani_hozuki__basic_player_01.mesh` | `default` | `Glass` | `vehicle_glass_onesided.mt` |
| hozuki | `body_01` | `v_standard2_mizutani_hozuki__ext01_body_01.mesh` | `urban_01` | `glass` | `glass_ui_generic.mi` |
| hozuki | `None` | `mizutani_hozuki__basic_urban_01.mesh` | `default` | `Glass` | `vehicle_glass_onesided.mt` |
| supron | `interior_01` | `v_standard25_mahir_supron__int01_interior_01.mesh` | `poor_04` | `glass_ui` | `glass_ui_generic_dusty.mi` |
| supron | `None` | `mahir_supron__basic_player_01.mesh` | `default` | `Glass` | `vehicle_glass_onesided.mt` |
| supron | `interior_01` | `v_standard25_mahir_supron__int01_interior_01.mesh` | `urban_01` | `glass_ui` | `glass_ui_generic_dusty.mi` |
| supron | `None` | `mahir_supron__basic_urban_01.mesh` | `default` | `Glass` | `vehicle_glass_onesided.mt` |
| columbus | `mirror_fr_01` | `v_standard25_villefort_columbus__ext01_door_fr_mirror_01.mesh` | `suburban_02` | `glass` | `glass_exterior_generic.mi` |
| columbus | `mirror_fl_01` | `v_standard25_villefort_columbus__ext01_door_fl_mirror_01.mesh` | `suburban_02` | `light_cover_glass` | `glass_exterior_generic.mi` |
| columbus | `trunk_b` | `v_standard25_villefort_columbus__ext01_trunk_b_01.mesh` | `suburban_02` | `cover_glass` | `glass_exterior_generic.mi` |
| columbus | `interior_01` | `v_standard25_villefort_columbus__int01_interior_01.mesh` | `poor_01` | `glass_ui` | `glass_ui_generic_dusty.mi` |
| columbus | `None` | `villefort_columbus__basic_player_01.mesh` | `default` | `Glass` | `vehicle_glass_onesided.mt` |
| columbus | `mirror_fr_01` | `v_standard25_villefort_columbus__ext01_door_fr_mirror_01.mesh` | `suburban_01` | `glass` | `glass_exterior_generic.mi` |
| columbus | `mirror_fl_01` | `v_standard25_villefort_columbus__ext01_door_fl_mirror_01.mesh` | `suburban_01` | `light_cover_glass` | `glass_exterior_generic.mi` |
| columbus | `trunk_b` | `v_standard25_villefort_columbus__ext01_trunk_b_01.mesh` | `suburban_01` | `cover_glass` | `glass_exterior_generic.mi` |
| columbus | `interior_01` | `v_standard25_villefort_columbus__int01_interior_01.mesh` | `suburban_01` | `glass_ui` | `glass_ui_generic_dusty.mi` |
| columbus | `None` | `villefort_columbus__basic_suburban_01.mesh` | `default` | `Glass` | `vehicle_glass_onesided.mt` |
| columbus | `mirror_fr_01` | `v_standard25_villefort_columbus__ext01_door_fr_mirror_01.mesh` | `suburban_03` | `glass` | `glass_exterior_generic.mi` |
| columbus | `mirror_fl_01` | `v_standard25_villefort_columbus__ext01_door_fl_mirror_01.mesh` | `suburban_03` | `light_cover_glass` | `glass_exterior_generic.mi` |
| columbus | `trunk_b` | `v_standard25_villefort_columbus__ext01_trunk_b_01.mesh` | `suburban_03` | `cover_glass` | `glass_exterior_generic.mi` |
| columbus | `interior_01` | `v_standard25_villefort_columbus__int01_interior_01.mesh` | `suburban_03` | `glass_ui` | `glass_ui_generic_dusty.mi` |
| columbus | `None` | `villefort_columbus__basic_suburban_02.mesh` | `default` | `Glass` | `vehicle_glass_onesided.mt` |
| cortes | `door_bl_a` | `v_standard2_villefort_cortes__ext01_door_bl_01.mesh` | `urban_06` | `glass_exterior_generic`, `glass_ui` | `glass_exterior_generic.mi` |
| cortes | `door_br_a` | `v_standard2_villefort_cortes__ext01_door_br_01.mesh` | `urban_06` | `glass_exterior_generic`, `glass_ui` | `glass_exterior_generic.mi` |
| cortes | `interior_01` | `v_standard2_villefort_cortes__int01_interior_01.mesh` | `urban_06` | `glass_ui` | `glass_ui_generic_dusty.mi` |
| cortes | `None` | `villefort_cortes__basic_player_01.mesh` | `default` | `Glass` | `vehicle_glass_onesided.mt` |
| cortes | `door_bl_a` | `v_standard2_villefort_cortes__ext01_door_bl_01.mesh` | `suburban_01` | `glass_exterior_generic`, `glass_ui` | `glass_exterior_generic.mi` |
| cortes | `door_br_a` | `v_standard2_villefort_cortes__ext01_door_br_01.mesh` | `suburban_01` | `glass_exterior_generic`, `glass_ui` | `glass_exterior_generic.mi` |
| cortes | `interior_01` | `v_standard2_villefort_cortes__int01_interior_01.mesh` | `suburban_01` | `glass_ui` | `glass_ui_generic_dusty.mi` |
| cortes | `None` | `villefort_cortes__basic_suburban_1_01.mesh` | `default` | `Glass` | `vehicle_glass_onesided.mt` |
| cortes | `door_bl_a` | `v_standard2_villefort_cortes__ext01_door_bl_01.mesh` | `poor_01` | `glass_exterior_generic`, `glass_ui` | `glass_exterior_generic.mi` |
| cortes | `door_br_a` | `v_standard2_villefort_cortes__ext01_door_br_01.mesh` | `poor_01` | `glass_exterior_generic`, `glass_ui` | `glass_exterior_generic.mi` |
| cortes | `interior_01` | `v_standard2_villefort_cortes__int01_interior_01.mesh` | `poor_01` | `glass_ui` | `glass_ui_generic_dusty.mi` |
| cortes | `None` | `villefort_cortes__basic_poor_1_01.mesh` | `default` | `Glass` | `vehicle_glass_onesided.mt` |
| thrax | `body_01` | `v_standard2_chevalier_thrax__ext01_body_01.mesh` | `urban_02` | `glass` | `glass_exterior_generic.mi` |
| thrax | `interior_01` | `v_standard2_chevalier_thrax__int01_interior_01.mesh` | `default` | `ui_glass` | `glass_ui_generic_dusty.mi` |
| thrax | `None` | `chevalier_thrax__basic_player_01.mesh` | `default` | `Glass` | `vehicle_glass_onesided.mt` |
| bandit | `interior_02` | `v_standard2_archer_bandit__int01_interior_02.mesh` | `default` | `glass_ui` | `glass_ui_generic.mi` |
| bandit | `steering_wheel_02` | `v_standard2_archer_bandit__int01_stwheel_02.mesh` | `default` | `glass_ui` | `glass_ui_generic.mi` |
| bandit | `None` | `mproxy_quartz_bandit.mesh` | `default` | `Glass1` | `vehicle_glass_onesided.mt` |
| merrimac | `screen_fl_01` | `v_standard25_thorton_merrimac__int01_screen_fl_01.mesh` | `int_player_01` | `glass_ui` | `glass_ui_generic.mi` |
| merrimac | `seats_fl_01` | `v_standard25_thorton_merrimac__int01_seats_fl_01.mesh` | `player_01` | `glass_ui` | `glass_ui_generic.mi` |
| merrimac | `stwheel_01` | `v_standard25_thorton_merrimac__int01_stwheel_01.mesh` | `player_01` | `glass_ui` | `glass_ui_generic.mi` |
| merrimac | `seats_b_01` | `v_standard25_thorton_merrimac__int01_seats_b_01.mesh` | `player_01` | `glass_ui` | `glass_ui_generic.mi` |
| merrimac | `screen_fr_01` | `v_standard25_thorton_merrimac__int01_screen_fr_01.mesh` | `int_player_01` | `glass_ui` | `glass_ui_generic.mi` |
| merrimac | `interior_01` | `v_standard25_thorton_merrimac__int01_interior_player_01.mesh` | `default` | `glass_ui` | `glass_ui_generic.mi` |
| merrimac | `None` | `thorton_merrimac_basic_player_01.mesh` | `default` | `Glass` | `vehicle_glass_onesided.mt` |
| semimaru | `interior_01` | `v_sport1_yaiba_semimaru__int01_interior_01.mesh` | `default` | `UI_glass` | `glass_ui_generic.mi` |
| semimaru | `None` | `yaiba_semimaru_basic_urban_01.mesh` | `default` | `Glass` | `vehicle_glass_onesided.mt` |
| kusanagi | `v_sportbike1_yaiba_kusanagi__ext01_body_011080` | `v_sportbike1_yaiba_kusanagi__ext01_body_01.mesh` | `default` | `glass` | `glass_windshield.mi` |
| kusanagi | `v_sportbike1_yaiba_kusanagi__ext01_body_011080` | `v_sportbike1_yaiba_kusanagi_asm_r250__ext01_body_01.mesh` | `default` | `glass_window` | `glass_windshield.mi` |
| kusanagi | `None` | `yaiba_kusanagi_basic_asm_r250_regular_nr.mesh` | `default` | `Glass` | `vehicle_glass_onesided.mt` |
| kusanagi | `None` | `yaiba_kusanagi_basic_asm_r250_naked.mesh` | `default` | `Glass` | `vehicle_glass_onesided.mt` |

## Route 2 pack plan (not built)

- 70 glass meshes patched; 492 mesh appearances added, named `open77_tint<level>__<source mesh appearance>`: one per level for every appearance of the mesh that has a glass chunk, so a trim added later needs no rebuild.
- A new appearance keeps the source's chunk list and swaps only its glass chunks for one of these original material instances, each naming a vanilla base by depot path:

| chunk material | file | base (by path) | values set |
|---|---|---|---|
| `open77_tint1` | `glass_tint1.mi` | `base\vehicles\common\materials\glass_exterior_generic_tinted_black.mi` | TintColor #8a9699, Opacity 1, OpacityBackFace 0.5, BackFacesReflectionPower 0 |
| `open77_tint2` | `glass_tint2.mi` | `base\vehicles\common\materials\glass_exterior_generic_tinted_black.mi` | TintColor #636e71, Opacity 1, OpacityBackFace 0.5, BackFacesReflectionPower 0 |
| `open77_tint3` | `glass_tint3.mi` | `base\vehicles\common\materials\glass_exterior_generic_tinted_black.mi` | TintColor #212121, Opacity 1, OpacityBackFace 0.5, BackFacesReflectionPower 0 |
| `open77_tint1_onesided` | `glass_tint1_onesided.mi` | `base\materials\vehicle_glass_onesided.mt` | TintColor #8a9699, Opacity 1 |
| `open77_tint2_onesided` | `glass_tint2_onesided.mi` | `base\materials\vehicle_glass_onesided.mt` | TintColor #636e71, Opacity 1 |
| `open77_tint3_onesided` | `glass_tint3_onesided.mi` | `base\materials\vehicle_glass_onesided.mt` | TintColor #212121, Opacity 1 |

| level | label | TintColor | Opacity | OpacityBackFace | BackFacesReflectionPower | values taken from |
|---|---|---|---|---|---|---|
| 1 | light | #8a9699 | 1 | 0.5 | 0 | Yaiba Semimaru factory side glass (window_fl, window_back) |
| 2 | dark | #636e71 | 1 | 0.5 | 0 | glass_exterior_generic_tinted_black.mi as is (Hella `tinted`, Cortes `padre`) |
| 3 | limo | #212121 | 1 | 0.5 | 0 | TintColor of Chevalier Thrax `black_01` (glass_black_01), opacities of level 2: Thrax's 0.9 / 0.2 rendered lighter than level 2 (2026-11-07) |

| mesh | models | appearances with glass | added |
|---|---|---|---|
| `v_standard2_makigai_maimai__ext01_window_b_01.mesh` | maimai | `default` | 3 |
| `v_standard2_makigai_maimai__ext01_window_fr_c_01.mesh` | maimai | `default` | 3 |
| `v_standard2_makigai_maimai__ext01_window_fl_c_01.mesh` | maimai | `default` | 3 |
| `v_standard2_makigai_maimai__ext01_window_fl_01.mesh` | maimai | `default` | 3 |
| `v_standard2_makigai_maimai__ext01_window_fl_b_01.mesh` | maimai | `default` | 3 |
| `v_standard2_makigai_maimai__ext01_window_fr_01.mesh` | maimai | `default` | 3 |
| `v_standard2_makigai_maimai__ext01_window_fr_b_01.mesh` | maimai | `default` | 3 |
| `v_standard2_thorton_galena__ext01_window_bl_01.mesh` | galena | `default`, `voodoo_01` | 6 |
| `v_standard2_thorton_galena__ext01_window_br_01.mesh` | galena | `default`, `voodoo_01` | 6 |
| `v_standard2_thorton_galena__ext01_window_fl_01.mesh` | galena | `default`, `voodoo_01` | 6 |
| `v_standard2_thorton_galena__ext01_window_fr_01.mesh` | galena | `default`, `voodoo_01` | 6 |
| `v_standard2_thorton_galena__ext01_window_b_01.mesh` | galena | `default`, `voodoo_01`, `fluo_green_01`, `disposal_glass` | 12 |
| `v_standard2_archer_hella__ext01_window_bl_01.mesh` | hella | `default`, `tinted`, `tinted_damaged` | 9 |
| `v_standard2_archer_hella__ext01_window_br_01.mesh` | hella | `default`, `tinted`, `tinted_damaged` | 9 |
| `v_standard2_archer_hella__ext01_window_fl_01.mesh` | hella | `default`, `damaged` | 6 |
| `v_standard2_archer_hella__ext01_window_b_01.mesh` | hella | `default`, `tinted`, `damaged` | 9 |
| `v_standard2_archer_hella__ext01_window_bl_02_01.mesh` | hella | `default`, `tinted` | 6 |
| `v_standard2_archer_hella__ext01_window_br_02_01.mesh` | hella | `default`, `tinted` | 6 |
| `v_standard2_archer_hella__ext01_window_fr_01.mesh` | hella | `default` | 3 |
| `v_standard2_thorton_colby__ext01_window_bl_01.mesh` | colby | `default`, `tinted`, `dark`, `poor_01` | 12 |
| `v_standard2_thorton_colby__ext01_window_br_01.mesh` | colby | `default`, `tinted`, `dark` | 9 |
| `v_standard2_thorton_colby__ext01_window_fr_01.mesh` | colby | `default`, `tinted` | 6 |
| `v_standard2_thorton_colby__ext01_window_fl_01.mesh` | colby | `default`, `tinted` | 6 |
| `v_standard2_thorton_colby__ext01_window_b_01.mesh` | colby | `default`, `tinted`, `dark` | 9 |
| `v_standard2_archer_quartz__ext01_window_b_01.mesh` | bandit, quartz | `default` | 3 |
| `v_standard2_archer_quartz__ext01_window_bl_01.mesh` | bandit, quartz | `default` | 3 |
| `v_standard2_archer_quartz__ext01_window_br_01.mesh` | bandit, quartz | `default` | 3 |
| `v_standard2_archer_quartz__ext01_window_fl_01.mesh` | bandit, quartz | `default` | 3 |
| `v_standard2_archer_quartz__ext01_window_fr_01.mesh` | bandit, quartz | `default` | 3 |
| `v_standard2_mizutani_hozuki__ext01_window_bl_01.mesh` | hozuki | `default`, `dark_01` | 6 |
| `v_standard2_mizutani_hozuki__ext01_window_bl_02.mesh` | hozuki | `default`, `dark_01` | 6 |
| `v_standard2_mizutani_hozuki__ext01_window_br_01.mesh` | hozuki | `default`, `dark_01` | 6 |
| `v_standard2_mizutani_hozuki__ext01_window_br_02.mesh` | hozuki | `default`, `dark_01` | 6 |
| `v_standard2_mizutani_hozuki__ext01_window_fr_01.mesh` | hozuki | `default`, `dark_01` | 6 |
| `v_standard2_mizutani_hozuki__ext01_window_fl_01.mesh` | hozuki | `default`, `dark_01` | 6 |
| `v_standard2_mizutani_hozuki__ext01_window_b_01.mesh` | hozuki | `default`, `dark_01` | 6 |
| `v_standard25_mahir_supron__ext01_body_01_window_bl_01.mesh` | supron | `default` | 3 |
| `v_standard25_mahir_supron__ext01_body_01_window_br_01.mesh` | supron | `default` | 3 |
| `v_standard25_mahir_supron__ext01_window_bl_01.mesh` | supron | `default` | 3 |
| `v_standard25_mahir_supron__ext01_window_fr_01.mesh` | supron | `default` | 3 |
| `v_standard25_mahir_supron__ext01_window_fl_01.mesh` | supron | `default` | 3 |
| `v_standard25_mahir_supron__ext01_window_br_01.mesh` | supron | `default` | 3 |
| `v_standard25_mahir_supron__ext01_trunk_b_window_01.mesh` | supron | `default` | 3 |
| `v_standard25_mahir_supron__ext01_trunk_a_window_01.mesh` | supron | `default` | 3 |
| `v_standard25_villefort_columbus__ext01_window_fr_01.mesh` | columbus | `default`, `growl_fm` | 6 |
| `v_standard25_villefort_columbus__ext01_window_fl_01.mesh` | columbus | `default`, `growl_fm` | 6 |
| `v_standard2_villefort_cortes__ext01_window_b_01.mesh` | cortes | `default`, `delamain`, `padre`, `padre_red`, `extra_dark` | 15 |
| `v_standard2_villefort_cortes__ext01_door_window_bl_01.mesh` | cortes | `default`, `delamain`, `padre`, `padre_red`, `delamain_dented_q005`, `extra_dark` | 18 |
| `v_standard2_villefort_cortes__ext01_door_glass_bl_01.mesh` | cortes | `default`, `delamain`, `padre`, `padre_red`, `delamain_dented_q005`, `extra_dark` | 18 |
| `v_standard2_villefort_cortes__ext01_door_window_br_01.mesh` | cortes | `default`, `delamain`, `padre`, `padre_red`, `extra_dark` | 15 |
| `v_standard2_villefort_cortes__ext01_door_glass_br_01.mesh` | cortes | `default`, `delamain`, `padre`, `padre_red`, `extra_dark` | 15 |
| `v_standard2_villefort_cortes__ext01_door_window_fl_01.mesh` | cortes | `default`, `padre`, `delamain_dented_q005` | 9 |
| `v_standard2_villefort_cortes__ext01_door_window_fr_01.mesh` | cortes | `default`, `padre` | 6 |
| `v_standard2_chevalier_thrax__ext01_window_b_01.mesh` | thrax | `default`, `black_01`, `black_02` | 9 |
| `v_standard2_chevalier_thrax__ext01_window_fl_01.mesh` | thrax | `default`, `black_01`, `black_02` | 9 |
| `v_standard2_chevalier_thrax__ext01_window_fr_01.mesh` | thrax | `default`, `black_01`, `black_02` | 9 |
| `v_standard2_chevalier_thrax__ext01_window_bl_01.mesh` | thrax | `default`, `glass_black_01`, `glass_black_02` | 9 |
| `v_standard2_chevalier_thrax__ext01_window_br_01.mesh` | thrax | `default`, `black_01`, `black_02` | 9 |
| `v_standard25_thorton_merrimac__ext01_window_fr_01.mesh` | merrimac | `default`, `dark`, `poor_01`, `clean`, `dirty` | 15 |
| `v_standard25_thorton_merrimac__ext01_window_fl_01.mesh` | merrimac | `default`, `dark`, `poor_01`, `clean`, `dirty` | 15 |
| `v_standard25_thorton_merrimac__ext01_window_bl_02.mesh` | merrimac | `dark`, `poor_01`, `clean`, `dirt` | 12 |
| `v_standard25_thorton_merrimac__ext01_window_b_player_01.mesh` | merrimac | `default` | 3 |
| `v_standard25_thorton_merrimac__ext01_window_br_02.mesh` | merrimac | `dark`, `poor_01`, `clean`, `dirty` | 12 |
| `v_standard25_thorton_merrimac__ext01_window_bl_01.mesh` | merrimac | `dark`, `poor_01`, `clean`, `dirty` | 12 |
| `v_standard25_thorton_merrimac__ext01_window_br_01.mesh` | merrimac | `dark`, `poor_01`, `clean`, `dirty` | 12 |
| `v_sport1_yaiba_semimaru__ext01_window_fl_01.mesh` | semimaru | `default`, `tinted_blue` | 6 |
| `v_sport1_yaiba_semimaru__ext01_window_fl_02.mesh` | semimaru | `default`, `tinted_blue` | 6 |
| `v_sport1_yaiba_semimaru__ext01_window_fr_01.mesh` | semimaru | `default`, `tinted_blue` | 6 |
| `v_sport1_yaiba_semimaru__ext01_window_fr_02.mesh` | semimaru | `default`, `tinted_blue` | 6 |
| `v_sport1_yaiba_semimaru__ext01_window_b_01.mesh` | semimaru | `default`, `tinted_blue` | 6 |
