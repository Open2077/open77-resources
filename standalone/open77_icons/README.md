# open77_icons

Gives your client resources 2,112 Lucide icons to show as native map and minimap blips, through a small set of exports. It is an icon library, not a gamemode: it draws nothing until another resource asks for a blip.

- **Docs:** [Custom SVG blips](https://open2077.net/docs/custom-blip-icons)
- **Starts:** with `ensure open77_icons` (it declares `auto_start false`)
- **Needs:** nothing
- **Runs on:** client

The icons ship as native SVG blips. No gamemode dependency, WebUI, font
installation, CDN request or framework is required.

Requires the Open77 client with custom SVG blips and the expanded SVG limits
(256 KiB source / 1,024 polygons per icon). Older clients cannot render every
icon; `info().apiAvailable` detects the API, not the client's limit revision.

## Use it

Copy this whole directory into your server's `resources/standalone/open77_icons`.
In each resource using it, add this manifest dependency:

```lua
dependency "open77_icons >=1.0.0"
```

The resource is opt-in (`auto_start false`). Include it in `resources.load` if
your server uses an explicit selection. A running consumer with the dependency
starts it automatically; alternatively run `ensure open77_icons` in the server
console (or `startup.commands`). Selection alone does not start this opt-in
resource. No additional
permissions are needed in the consumer: this trusted service owns its native
blips and declares `ui.vanilla.map` itself.

## Create and change a blip

Run in a **client script**, after the player has entered the world:

```lua
local pump, reason = exports.open77_icons:create({
    icon = "fuel", -- "lucide:fuel" works too
    title = "Fuel station",
    position = { x = -595.785522, y = -722.328979, z = 8.715637 },
    color = "#FFCC00",
    size = 40,
    range = 0, -- always active; use a distance in metres for a proximity gate
    routable = true,
})
if not pump then
    print("Fuel blip unavailable: " .. tostring(reason))
    return
end

exports.open77_icons:setIcon(pump, "wrench", 40)
exports.open77_icons:setColor(pump, "#33DDBB")
exports.open77_icons:track(pump)
-- exports.open77_icons:remove(pump)
```

Use this resource's exports for subsequent operations, **not**
`Open77.blips.update(pump, ...)` from the consumer: native ownership belongs to
the library. Titles, routing, tracking, minimap and map legend use the standard
native blip implementation. `range` is a distance in metres (0 disables the
distance gate), not a map zoom-distance setting.

Each caller can manage only its own handles. Caller stop/reload removes its
blips (within one second if no shared stop event is emitted). Stopping the
library removes all library blips. Handles do not survive a resource restart
or world/session teardown; recreate them on world entry.

## Browse the catalogue

```lua
print(exports.open77_icons:has("hospital")) -- true
local page = exports.open77_icons:list("car", 0, 20)
for _, name in ipairs(page.icons) do print(name) end
print(page.total)
```

`catalogue.json` contains all names, asset paths and SHA-256 checksums. The
`icons/lucide/` directory can be previewed directly in an SVG-capable viewer.
Useful RP icons include `fuel`, `hospital`, `car`, `shopping-cart`, `utensils`,
`coffee`, `shirt`, `house`, `wrench`, `trash-2`, `briefcase-business`, `banknote`,
`shield`, `plane`, `map-pin` and `flag`.

## Client exports

| Export | Result |
| --- | --- |
| `info()` | Library/version/count, API presence and service quotas |
| `has(name)` | Boolean; names are case-insensitive, optional `lucide:` prefix |
| `list(query?, offset?, limit?)` | `{icons, total, offset, limit}`; substring search, zero-based offset, limit 1–100 (default 50) |
| `create(options)` | Decimal-string native handle, or `nil, reason` |
| `update(id, patch)` | `ok, reason?`; only supplied fields change |
| `setIcon(id, nameOrFalse, size?)` | Change icon, or `false` to restore the native sprite |
| `setColor(id, colorOrFalse)` | Hex colour, or `false` to restore engine tint |
| `setPosition(id, position)` | Change world position |
| `setActive(id, active)` | Change active state |
| `setRange(id, range)` | Change native range |
| `track(id)` / `untrack(id)` | Native tracking result; `nil, reason` if caller does not own handle |
| `get(id)` | Native snapshot, or `nil, reason` |
| `remove(id)` | `ok, reason?` |
| `clear()` | Number of this caller's blips removed |

`create` requires `icon` plus a native position or entity attachment. Optional
`size` is 16–128 (default 48); default fallback `sprite` is `tech`. Other accepted
native fields: `title`, `description`, `label`, `active`, `visibleThroughWalls`,
`range`, `routable` (create only), `slot`, `offset`, `color`. Native validation is preserved;
unknown fields are rejected. Invalid options return a reason such as
`unknown_icon`, `invalid_icon_size`, `blip_not_owned` or `icon_blip_limit`.
Export dispatch itself raises if the resource is not running: declare the
dependency and handle lifecycle appropriately.

## Budgets

Maximum **64 blips per caller, 128 across the service**. All consumers also
share the native **4,096 polygon budget** of this resource (16,384 client-wide).
A complex icon consumes more of that budget; increasing SVG import limits does
not remove live rendering safeguards. Native quota errors propagate unchanged.
Only requested icons are compiled/rendered; the entire catalogue is not drawn.

## Licence and reproducible import

Lucide Static **1.47.0**, distributed under ISC, with inherited Feather icons
under MIT. Keep **LICENSE-LUCIDE.txt** when redistributing. No paid/pro icons
or Font Awesome branding are included.

Source: https://www.npmjs.com/package/lucide-static/v/1.47.0

The generated `catalogue.json` records the pinned npm integrity. The importer
removes browser class attributes and expands the viewport to `-2 -2 28 28` to
retain stroke edges. Geometry is unchanged. It uses only Node's standard library:

```sh
# Download/extract the pinned package separately, then:
node tools/import-lucide.mjs /path/to/extracted/package
node tools/import-lucide.mjs /path/to/extracted/package --check
```

From the Open77 repository root, run the mock lifecycle/API tests with Lua 5.4:

```sh
lua resources/standalone/open77_icons/tests/client.test.lua
```

These tests do not claim to render icons. Native compiler acceptance is checked
with `Open77.BlipSvg.Tests --validate-icons resources/standalone/open77_icons/icons/lucide`.

The opt-in [open77_icons_demo](../../examples/open77_icons_demo/) consumer shows
the library in use: start it with `ensure open77_icons_demo` on a local server. It creates
four nearby HUD/minimap/map icons, then updates colour/geometry after 45 seconds.
It does not change player position or server gameplay. Stop it to clean up.
