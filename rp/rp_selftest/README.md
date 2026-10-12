# rp_selftest

Checks, with no player online, that the core RP resources still answer each other correctly, and prints one PASS or FAIL line per check in the server log. Run it after an update to see at a glance whether economy, jobs, identity, inventory, bank, needs and the other RP resources still keep their exports.

- **Docs:** [Cross-resource server exports](https://open2077.net/docs/server-exports)
- **Starts:** on its own
- **Needs:** `rp_economy`, `rp_jobs`, `rp_identity`, `rp_inventory`, `rp_bank`, `rp_needs`
- **Runs on:** server

## Use it

- It runs once, half a second after it starts. To run it again, type `restart rp_selftest` in the server console.
- Read the server log. Each line is `[rp_selftest] PASS <check> -- <detail>` or `[rp_selftest] FAIL <check> -- <detail>`, and the last one is `[rp_selftest] done: <n> passed, <n> failed`.
- The 33 checks call exports with an unknown player or a bad argument and expect a clean refusal: `rp_economy`, `rp_jobs`, `rp_identity`, `rp_inventory`, `rp_bank` and `rp_needs` first, then read-only exports of `rp_config`, `rp_logs`, `rp_whitelist`, `rp_admin`, `rp_garage`, `rp_housing`, `rp_gangs`, `rp_crime`, `rp_phone`, `rp_radio` and `rp_shops`.
- Those last eleven are not dependencies. When one of them is not running, its checks fail and the others still run.
- It also checks that the refused calls did not raise `rp_economy:changed`.
- It leaves two traces: an item `crowbar_test` registered through `rp_inventory`, and a `selftest` society in `rp_bank` that it credits and then debits by 100. Leave it off a server where you do not want them.

Each check in `server/main.lua` looks like this:

```lua
local v, r = call("rp_economy", "add", 999999, -5, "test")
check("economy.add refuses a negative amount", v == nil and type(r) == "string", r)
```
