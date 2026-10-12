# open77_parkour_example

A free self-service Dash example: players type `/parkour install` to give themselves native ground Dash, Air Dash or both, with a Basic or Advanced preset. It grants nothing on startup and is meant to be copied into your own job, progression or payment policy.

- **Docs:** [Native Dash and Air Dash](https://open2077.net/docs/dash)
- **Starts:** with `ensure open77_parkour_example` (it declares `auto_start false`)
- **Needs:** `open77_cyberware`, `open77_dash`, `open77_equipment`
- **Runs on:** server

## Use it

This resource is disabled by default and grants nothing on startup. Include its
dependencies in your server resource selection, then explicitly start
`open77_parkour_example`. `open77_dash` supplies native client projection;
`open77_cyberware` and `open77_equipment` supply the existing character/equipment
foundation. This resource uses only public server APIs.

In chat:

```text
/parkour install basic air
/parkour inspect
/parkour test
/parkour remove
```

Hold a direction and tap the configured Dash key (default Ctrl). For Air Dash,
jump first. `inspect` reports the actual projection status, charges, airtime use
and timing; a requested grant is not usable until projection is ready. `test`
prints physical-input instructions and does not trigger movement by a debug API.
Removal releases this resource's grant and preserves paid arms/legs.

Select `basic` or `advanced`, and `ground`, `air` or `combined`:

| Preset | Stamina cost | Charges | Cooldown | Charge regeneration |
|---|---:|---:|---:|---:|
| Basic | 20 | 1 | 700 ms | 2500 ms |
| Advanced | 10 | 3 | 450 ms | 1500 ms |

Ground grants native ground Dash. Air grants standalone Air Dash. Combined
grants both and requires already active double-jump legs. Three charges do not
permit three Air Dashes in one airtime: native Air Dash remains limited to one
until stable landing, with cooldown and charge debt accounted separately.
Native speed/distance are fixed; walls can shorten or block movement.

For the combined doctor workflow, an authorized doctor offers
`/doc offer <patient-id> training legs` through
[`open77_ripperdoc_example`](../open77_ripperdoc_example/).
The patient consents and waits for installation completion. Then use
`/parkour install advanced combined`. Jump, release and jump again, then Dash.
Air Dash consumes native airborne readiness; the reverse ordering has native
limits and does not reset the jump counter. Existing Gorilla Arms remain active.

Edit `server/config.lua` before enabling the resource: binding, presentation,
costs/charges/cooldowns, `allowedBuckets` and `canUse` are creator policy. The
example is free self-service and creates no economy or second equipment ledger.
The server checks access at installation and while a grant remains active;
leaving an allowed zone revokes that grant. Add your own progression/job/payment
policy, or disable the example and call the same permission-controlled APIs from
your own resource. Resource stop/disconnect cleanup is owned by the platform.

The optional [cyberware lab](../open77_cyberware_lab/) also exposes Dash controls
through these APIs. Do not use two grant resources for the same player
simultaneously: each may revoke only its own capability, and foreign ownership is
rejected.

API, configuration and events: [Native Dash and Air Dash](https://open2077.net/docs/dash).
