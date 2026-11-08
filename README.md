# Open77 resources

Every official Lua resource for [Open77](https://open2077.net) servers, in one place: the
platform's own resources, the game modes, small examples, optional standalone resources, shared
libraries and a complete Night City roleplay pack. Read them, copy them, change them.

| Folder | What is inside |
|---|---|
| [`system/`](system/) | the platform resources every server runs on: chat, HUD, vehicles, weapons, NPCs, prompts, jobs, items and money |
| [`gamemodes/`](gamemodes/) | complete game modes: free roam, races, pursuit, deathmatch, a 64-player battle royale, example arenas |
| [`rp/`](rp/) | the roleplay pack: identity, jobs, economy, inventory, housing, police, medics, gangs, phone and more |
| [`examples/`](examples/) | small resources that each show one feature |
| [`standalone/`](standalone/) | optional resources that work on any server: icons, free camera, wardrobe, equipment, sky ads |
| [`libraries/`](libraries/) | shared code: PolyZone zones, the ArchiveXL and TweakXL loaders |
| [`tools/`](https://github.com/Open2077/open77-resources/tree/next/tools) | build tools for content packs: the vehicle customization pipeline (on `next` until the next server release) |

Each folder has an index, and each resource has a short README: what it does, what it needs, how
to turn it on, and a link to its documentation on [open2077.net/docs](https://open2077.net/docs).

## Which branch to use

- **`main`**: the resources of the current server release. Use this one.
- **`next`**: what the next server release will contain. Some resources there need a newer server
  build than the one you run.

`EXPORT.json` names the platform commit the generated folders come from.

## Add a resource to your server

1. Your server download already contains `system/` and the default game mode. Do not copy
   `system/` over it, unless you mean to update one resource.
2. Copy the folders you want into your server's `resources/` folder. Keep one copy of each name.
   Category folders are fine: `resources/rp/rp_salvage` is found like `resources/rp_salvage`.
3. List the resources in `resources.load` in your server configuration, then start the ones whose
   README says **Starts:** with `ensure` by typing `ensure <name>` in the server console.

The [hosting guide](https://open2077.net/docs/host-a-server) covers the server itself, and
[Server resources](https://open2077.net/docs/server-resources) covers loading, start order and
dependencies.

## The roleplay pack

[`rp/`](rp/) is a full Night City roleplay server: start with [rp/README.md](rp/README.md).

The jobs built on the platform's job libraries need `open77_actions`, `open77_transactions`,
`open77_furniture` and `open77_seating`, which are in `system/` since server release
2.31.21+op77.138. This applies to:

- `rp_salvage` (scrapyard) and `rp_streetfood` (street-food stall);
- `rp_ripperdoc`, `rp_chooh2`, `rp_techie`, `rp_netrunner`, `rp_fixer`, `rp_trauma` and
  `rp_nomade`, the [roleplay jobs](https://open2077.net/docs/rp-jobs).

The libraries are experimental and not part of the default Freeroam selection: copy them from
`system/` with the jobs and list them in `resources.load`.

## Vehicle customization packs

Rims, body kits, liveries, stickers, performance stages, plates and window tint come as content
packs: resources with a `preload_mod` ZIP that the launcher mounts before the game starts. They
need the Open77 server and client release that brings the vehicle customization natives.

- **Use ready-made packs.** The Light RP server publishes the packs it runs in
  [`resources/assets/models`](https://github.com/Open2077/light-rp/tree/main/resources/assets/models)
  (`lightrp_vk_*`, `lightrp_vehicle_*`, `open77_vehicle_plates`). Its
  `lightrp_vehicle_kit/README.md` says how to turn them on.
- **Make your own.** [`tools/vehicle-kit`](https://github.com/Open2077/open77-resources/tree/next/tools/vehicle-kit)
  is the pipeline that built them: a JSON spec goes in, and a resource ready to copy comes out. It
  is on `next` until the next server release. The rules and limits are in
  [Vehicle customization content packs](https://open2077.net/docs/vehicle-customization-packs).

## Where changes go

- `system/`, `gamemodes/`, `examples/`, `standalone/`, `libraries/` and `tools/` are exported from
  the Open77 platform at each release. Report problems in this repository's issues; fixes land through the
  platform and arrive with the next export.
- `rp/` is developed here: pull requests are welcome.

## License

MIT, see [LICENSE](LICENSE). A few third-party components keep their own license: see
[NOTICE.md](NOTICE.md). Open77 is a community project, not affiliated with or endorsed by
CD PROJEKT RED. Cyberpunk 2077 is a trademark of CD PROJEKT S.A.
