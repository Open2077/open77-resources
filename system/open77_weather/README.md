# open77_weather

This resource keeps the server clock and weather in sync, so players see the same time of day and the same sky, and it gives operators `weather.*` commands to change them.
`open77_weather` provides a server-authoritative session clock and synchronized weather. The server
advances time, chooses weather transitions, and publishes a revisioned state. Clients compensate
for network latency and project the accepted state into REDengine.

- **Docs:** [Synchronised time and weather](https://open2077.net/docs/weather)
- **Starts:** on its own
- **Needs:** nothing
- **Runs on:** server and client

## Structure

| Path | Responsibility |
|---|---|
| `shared/config.lua` | Public clock settings, aliases, and weather presets. |
| `shared/clock.lua` | Pure clock functions shared by both runtimes. |
| `server/main.lua` | Canonical state, scheduler, ACL commands, server events, and the `environment.*` exports. |
| `client/main.lua` | Validation, RTT compensation, REDengine projection, and exports. |

Server scripts are never included in the client package. The manifest requests `network.events` and
`world.environment`. In a production resource set, only the authoritative environment resource
should receive `world.environment`.

`server/main.lua` is also what the host's `Open77.environment.*` facade calls: the `environment.*`
exports at the bottom of that file are the seam between the platform surface (installed in every
VM, gated by `world.environment`) and this authority. The authority deliberately stays here rather
than in a C# service, because the only code that can move a sky is `client/main.lua`: a host-owned
clock would be a clock nobody applies. Documented in [Synchronised time and weather](https://open2077.net/docs/weather).

## Configuration

`timeScale` is the number of in-game seconds advanced per real second. Weather durations are real
seconds. Stable aliases such as `rain`, `fog`, and `sandstorm` map to REDengine preset names.

The default state starts at `12:00:00`. Operators can change the initial state and preset catalog in
`shared/config.lua`; never place secrets in shared files.

### Reloading

Those values are *initial* values, so they apply at boot and not again. The authority hands its live
state (clock, preset, transition, `randomWeather`, revision and authority epoch) to the host through
`Open77.state`, and adopts it again when the resource reloads. A `reload` therefore picks up changed
code and a changed preset catalogue **without** moving the sky: the time of day keeps running and a
server that pinned its weather stays pinned. Clients see the same authority epoch and a revision that
only grows, so they cannot tell the reload happened, which is correct: the authority did not restart.

Carried state deliberately does not survive the resource going down. `stop`, `restart` and `refresh`
bring the authority back up at the configured defaults, and the server re-asserts whatever its
`startup.commands` pinned for this resource. That is the reset lever: **`reload` keeps the sky,
`restart` returns it to configuration.**

A carried snapshot is validated before it is adopted: it is refused if `protocol` in
`shared/config.lua` has changed, or if its preset is no longer in the catalogue, and the resource then
falls back to the configured defaults. **Bump `protocol` whenever the carried shape changes**, so a
snapshot written by an older version of this resource is refused rather than half-adopted. It was
bumped to `3` when the carried snapshot became a default scope plus an array of per-bucket
overrides (and the wire snapshot gained the matching `scope` field), so the first reload after that
deployment intentionally starts the authority from its configured defaults.

## Commands

Read-only commands:

```text
weather
weather.status
weather.time
```

Restricted mutation commands:

```text
weather.time.set 21:30:00
weather.time.freeze
weather.time.resume
weather.rate 8
weather.set rain 30
weather.random on
weather.next
```

A restricted command requires `command.<command>` in `acl.jsonc`. Grant
`command.weather.*` to a weather administrator when wildcard access is appropriate.

## Server API

Mutation events are local server events. They are not registered network events and cannot be sent
directly by a client.

```lua
TriggerEvent("open77:weather:setTime", 18, 30, 0)
TriggerEvent("open77:weather:setRate", 6)
TriggerEvent("open77:weather:setFrozen", true)
TriggerEvent("open77:weather:setWeather", "rain", 20)
TriggerEvent("open77:weather:setRandomEnabled", false)

AddEventHandler("open77:weather:state", function(state)
    print(state.revision, state.secondsOfDay, state.weather)
end)

TriggerEvent("open77:weather:requestState")
```

`open77:weather:timeChanged` and `open77:weather:weatherChanged` carry the same authoritative
snapshot.

## Client API

The client emits `open77:weather:updated` after accepting a snapshot. Other client resources can
read the projection through exports:

```lua
local state = Open77.exports.call("open77_weather", "getState"):await()
print(string.format("%02d:%02d - %s", state.hour, state.minute, state.weather))
```

Exports:

- `isReady()`
- `getState()`
- `requestSync()`

Gameplay resources should not call `Open77.environment` directly. That namespace is the protected
projection primitive used by this resource.

## Synchronization guarantees

- Every server incarnation has an `authorityEpoch`.
- Every mutation increments a monotonic revision.
- Clients ignore snapshots older than their accepted revision.
- Time synchronization includes half-round-trip latency compensation.
- A periodic authoritative heartbeat repairs lost local projections.
- The live game clock is read on every apply pass and written only when it has drifted past
  `timeDriftToleranceSeconds`: a late joiner whose save load replaced the clock converges within
  one apply interval, and a frozen server clock is re-asserted against the engine's natural 8x
  advance every `tolerance / 8` real seconds (each re-assert is a world time-jump; see the wiki).
- Stopping the resource releases its vanilla environment overrides.

See the [weather guide](https://open2077.net/docs/weather) and repository [license](../../LICENSE).
