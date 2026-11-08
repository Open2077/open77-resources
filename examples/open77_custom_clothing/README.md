# Custom clothing example

This resource creates two new TweakXL item records, registers their slot/body/
label in shared Lua, and makes them available to the standard wardrobe. It reuses
installed game visuals; no game meshes are included.

1. Run `python resources/examples/open77_custom_clothing/build.py` from the repo.
2. Load `examples/open77_custom_clothing`, `assets/loaders/tweakxl`, and
   `system/open77_appearance` (0.3.0+) in your server resource configuration.
   Add `system/open77_wardrobe_ui` to use the stock wardrobe.
3. Enable required mods and unsecured executable loaders for TweakXL. Start the
   resource explicitly (`ensure open77_custom_clothing`), or set its `auto_start`
   to `true` for your deployment.
4. Join through the launcher so the required package is installed before launch.
5. Open the wardrobe, choose Jackets and search for “Custom coat”. A female
   character sees the female coat; a male character sees the male coat.

For your own mod replace the YAML/assets and shared declarations. The full
[custom clothing API](../../../wiki/custom-clothing.md) covers packaging,
registration, persistence, errors and existing shop integration.
