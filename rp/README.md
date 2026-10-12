# The Night City roleplay pack

This `rp/` folder of `open77-resources` is the complete Night City roleplay pack. The platform resources it runs on are in [`../system/`](../system/), and your server download already contains them.

Forty gameplay resources and four test helpers for [Open77](https://open2077.net), the
Cyberpunk 2077 multiplayer platform. Together they run a complete roleplay server: identity,
money, inventory, twelve jobs with real runs, housing with real apartment doors, shops, a
bank, garages, gangs, crime, NCPD, a phone, a radio, zones and ambiance, all placed on real
Night City landmarks (Kabuki Market, the Afterlife, Viktor's clinic, Westbrook Motors, the
Rancho Coronado junkyard, the Aldecaldos camp…).

The original roleplay set was written by coding agents that had only the
[Open77 Devkit MCP](https://github.com/Open2077/open77-devkit), then played on a real server.
Take them as they are, take one job as a starting point, or read them to see how the platform
API is used for real: every folder has its own `README.md` with the commands, the config keys,
the exports and the log lines to expect.

> French speakers: the complete map of the set — per-phase tables, Night City coordinates,
> test paths and every platform trap paid for — is [`README.fr.md`](README.fr.md).

## Walking actions and held items

The platform's compiled animation service manages the default cigarette, phone,
can or bottle for walking profiles. `rp_needs`, `rp_bar` and `rp_phone` already
use `Open77.animations.play`; they inherit this cleanup without an extra job-side
prop loop. See [the action/item API](docs/held-actions.md) for custom inventory
visuals, holding versus drinking, permissions and current first-person limits.

## What is here

| Group | Resources |
|---|---|
| Core | `rp_config` (live tunables, `/config`), `rp_identity`, `rp_economy` (SQL wallets, payday), `rp_inventory` (WebUI backpack, stashes), `rp_jobs` (jobs, grades, societies), `rp_hud`, `rp_chat` (`/me`, `/do`, proximity), `rp_logs`, `rp_whitelist`, `rp_admin` |
| Jobs | `rp_mecano` (repair, paint, refuel, invoices, impound), `rp_ferrailleur` (scrapper) or its successor `rp_salvage` (opt-in: wrecks, crates, truck, buyer, built on the job libraries; never both), `rp_streetfood` (opt-in: grill, serve, pay, eat seated), `rp_bar`, `rp_ripperdoc`, `rp_medic`, `rp_trauma` (death, respawn at Vik's, bills), `rp_ncpd` (cuff, search, fines, jail) + `rp_mdt`, `rp_netrunner`, `rp_fixer`, `rp_nomade` (crate convoys: carry animation, cargo in the truck bed, GPS route), `rp_delamain` (taxi) |
| World | `rp_zones`, `rp_ambiance`, `rp_shops` (kiosks + vendors; `rp_shop` is its older chat-command version), `rp_bank` (ATMs), `rp_garage` (plates, keys, job orders, warrants: `canAccess`), `rp_cargo` (opt-in: crates in truck beds, every slot kept in the database), `rp_housing` (five real flats, doors found through `open77_doors`), `rp_needs` (hunger/thirst/fatigue), `rp_phone`, `rp_radio`, `rp_vigile` (security), `rp_fireworks` (synchronized shows) |
| Crime | `rp_crime` (lockpick, shop robbery, dealer, fence), `rp_gangs` (territories, street market) |
| Spectacle | `rp_fireworks` (synchronized shows), `rp_drones` (a drone light show: real drone bodies held in the sky, an OPEN//77 sign, cut and flip-book choreography) |
| Lab helpers | `rp_selftest` (33 checks, run once at start), `rp_taxitest` (`groundz`), `rp_worldprobe` (`wprobe`, `vwarp`), `eval_taxi` (the first taxi), [`rp_weapons_effect`](rp_weapons_effect) (English weapon workshop, `/weaponeffects`) |
| Platform (reference) | [`open77_prediction`](../system/open77_prediction/): the bundled prediction operator layer (switches, ping ceiling, telemetry), in the platform's `../system/` folder; already on every server, do not install. [`prediction_policy_example`](prediction_policy_example/): the ~40 lines a gamemode needs to turn on melee, Slam and hack prediction |

**`rp_fireworks` is the short one to read first.** Under three hundred lines of
server Lua, no client code, and it is the example for "everybody sees the same thing at
the same moment": every shell is fired by the server through
`Open77.effects.play`, which broadcasts it to the players in range. A show is a
list of cues on one clock, other resources start one with
`exports.rp_fireworks:playFor(playerId, "celebration")`, and its README carries
the four things that had to be measured in game — how high the shells go, how
far apart they have to be to stop reading as one smear, why a flare needs a
`ttlMs` when a burst does not, and where the other three firework shells hide.

Since the staging pass, every job action has a pose, a prop in the hands where it makes sense,
and a real duration — the pattern is explained in the site guide
[Animated actions](https://open2077.net/docs/animated-actions); `rp_nomade` is the reference
for carrying something while walking (pick-up, `carry` loop, put-down, crates attached to the
truck bed) and its README shows how to tune bone/offset/rotation by eye with `carrytune`.

Walking smoking, drinks and phone actions now use the platform's native hand items.
`rp_needs`, `rp_bar` and `rp_phone` prefer the upper-body profiles and declare
`open77_animations`; keep that system resource from the current base build.
See [walking actions and inventory items](docs/walking-actions.md) for job integration,
interruption cleanup and the current first-person limitation.

## Running the set

The optional [weapon workshop](rp_weapons_effect/README.md) requires a compatible
development client with native weapon tuning. It is disabled by default and does
not depend on the RP database stack. See [Weapon customization](https://open2077.net/docs/weapon-customization)
for supported controls, Lua examples and vehicle physics ownership.

1. An Open77 server on the current `main` build (the carry animation layer and the loot fixes
   landed in September 2026 releases) with MariaDB configured: every resource persists through
   `Open77.database` and creates its own `rp_*` tables at start.
2. Copy the folders you want from this `rp/` folder into your server's `resources/` folder (a
   `resources/rp/` category folder works too) and list them in the profile's `resources.load`
   (or let auto-start discover them). The `open77_*` resources they depend on are the platform
   resources of `../system/`. Dependencies are declared in
   each `open77.lua`; `rp_config` first, then `rp_identity` / `rp_economy` / `rp_inventory` /
   `rp_jobs`, then the rest.
3. Tune in `shared/config.lua` per resource (prices, positions, poses, props, durations).
   `rp_config/shared/defaults.lua` mirrors every tunable key and `/config` edits them live.
4. `rp_selftest` runs 33 checks across every phase once, when it starts. Type `restart rp_selftest`
   in the console to run them again, and `restart <name>` after a config edit.

Player texts are English. No resource holds a secret, a credential or a machine path: the
database connection string is the server's (`OP77_DATABASE_CONNECTION`).

## Things worth knowing

- **Command names collide silently** on the platform; `README.fr.md` lists the names the platform
  resources already take (`/heal`, `/revive`, …) and the ones this set registers.
- **Animation profiles are listed as candidates** (`{ profile = "carry" }, { profile = "phone" }`)
  and the first one the running catalogue knows is used, so the set works on older catalogues
  and picks up the walkable layer profiles when the server has them.
- **Props use curated aliases** (`crate.small`, `tool.welder`, `street.parking_meter`…); a raw
  `.mesh` path renders as a white slab.
- **Positions are measured**, not guessed: walked points and the AMM interior table. The
  coordinate map is in `README.fr.md` § *Carte de Night City*. The exception is the cargo beds
  of `rp_cargo/data/layouts.json`: the Thorton Mackinaw bed is measured (`measured: true`), the
  other beds are starting guesses flagged `measured: false` until someone measures them with the
  commands `cargospawn`, `cargotune` and `cargolayout`.
- **Vehicle access has one answer**: `exports.rp_garage:canAccess(playerId, plate, part, action)`
  (owner, key holder, mechanic on a job order, police with a warrant, stranger). An open trunk in
  the world is not authorization, and durable state is keyed by plate, never by a runtime id.
- Interiors with vanilla lootable decor can still crash a client on some builds (the Northside
  DLC flat); the housing list avoids them and the platform fix is tracked in the base repo.

## Documentation

- [Open77 docs](https://open2077.net/docs) — the API reference, guides and catalogues
- [Animated actions](https://open2077.net/docs/animated-actions) — poses, props in hand, durations
- [Open77 Devkit MCP](https://github.com/Open2077/open77-devkit) — the tool these resources were written with
- [`docs/PLAN.html`](docs/PLAN.html) — the delivery plan the set was built from
- `docs/world-interaction/` — the world-interaction rows done in this repository:
  [B8 compatibility audit](docs/world-interaction/b8-compat-audit.md),
  [A9 vehicle access and cargo](docs/world-interaction/a9-cargo.md),
  [C1 salvage pilot](docs/world-interaction/c1-salvage.md)
- `tests/` — offline checks, no game and no database, run from this `rp/` folder:
  `python -m unittest discover -s tests -p "test_compat*.py"` (B8 contracts, `rp_economy`) and
  `-p "test_a9*.py"` (`rp_garage` access matrix, `rp_cargo`) and `-p "test_c1*.py"` (`rp_salvage` on
  the real open77_actions / open77_containers / open77_transactions); they need a Lua 5.4 engine
  (`lupa`, or the KeraLua `lua54.dll`, see `tests/compat/luahost.py`)

## License

MIT — see [`LICENSE`](../LICENSE).
