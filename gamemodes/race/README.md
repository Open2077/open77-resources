# race

This is a compatibility alias: races now run inside [freeroam](../freeroam/), and this resource only exists so an older server profile that still loads `race` starts Freeroam instead. It has no spawn, queue, UI or editor of its own.

- **Docs:** none yet
- **Starts:** with `ensure race` (it declares `auto_start false`)
- **Needs:** `freeroam`
- **Runs on:** server

## Use it

New servers should load `freeroam` directly and leave `race` out. If an old profile still runs `ensure race`, the dependency on `freeroam >=0.6.0` starts Freeroam once, and the server log asks you to update the resource list to `freeroam`.

## Moving from race to freeroam

The engine, configuration and full course editor are documented in
[Freeroam / Race](../freeroam/race/README.md). A legacy `race` profile must also load the persistent appearance stack so the wardrobe
and equipment menus are available in-game: `open77_appearance` plus its three
companions `open77_equipment`, `open77_wardrobe`, `open77_wardrobe_ui` (in that
order). Provisioning a race server from the `freeroam` deployment template already
includes all four.

Commands and their ACL names remain
`/race`, `/race.join`, `/race.leave`, `/race.editor`, and `command.race.*`.

Before starting the updated resource, back up the installation's course data and
run the migration helper from the root of the Open77 platform repository (PowerShell):

```powershell
./scripts/migrate-race-to-freeroam.ps1 -ResourcesRoot 'D:/server/resources' -WhatIf
./scripts/migrate-race-to-freeroam.ps1 -ResourcesRoot 'D:/server/resources'
```

The helper copies `race/data/courses/*.json` and `race/data/race-settings.json`
into `freeroam/data/race/`. It preserves the originals, verifies copied bytes,
skips identical destination files, and refuses the entire migration if any
destination contains different data. Reconcile such conflicts explicitly before
retrying; no course is silently replaced. The repository's authored courses have
already moved with the engine. `scripts/test-race-migration.ps1` exercises preview,
idempotence, source preservation and conflict handling in isolated fixtures.
