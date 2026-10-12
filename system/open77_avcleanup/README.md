# open77_avcleanup

This resource removes abandoned AVs (the flying vehicles) from the world, so empty Manticores and other AVs left behind by players do not pile up on your server. It only takes an AV that nobody sits in, nobody drives, and that has stayed that way for a grace period.

- **Docs:** [Network vehicles](https://open2077.net/docs/vehicles)
- **Starts:** on its own
- **Needs:** nothing
- **Runs on:** server

## Use it

It works as soon as it runs. Every 12 to 15 minutes it sweeps the vehicle list and removes each AV (record `Vehicle.av_*` or `Vehicle.max_tac_av`) that has:

- no occupant;
- no driver holding its physics;
- stayed that way for at least 5 minutes, so a player who has just parked and stepped out keeps their AV.

Ground cars, occupied AVs and driven AVs are never touched. Each removal is logged with the vehicle id, record, position and the resource that spawned it.

To sweep right away, run the admin command `avcleanup.now`. A forced sweep removes the vacant AVs already seen by an earlier sweep without waiting for the grace period, and starts the clock for the others.

The interval, jitter and grace period are the `CONFIG` table at the top of `server/main.lua` (`intervalMinutes`, `jitterMinutes`, `graceMinutes`).
