# open77_zones

The client-side zone poller: enter/exit events with hysteresis, for spheres,
boxes, polygons, combinations and entity-attached shapes. A local
presentation signal, shared by any gamemode that needs "the player walked
into (or out of) a shape" without polling `Open77.character.state()` by hand.

- **Docs:** [Zones](https://open2077.net/docs/zones)
- **Starts:** on its own
- **Needs:** nothing
- **Runs on:** client

Full contract, including the shapes, the cost and the server-side
re-validation every caller must apply, is in [Zones](https://open2077.net/docs/zones).

## The containment maths is not in here

It lives in `scripting/lua/open77_zones.lua` and reaches every resource on
**both** runtimes as `Open77.zones.contains`, `normalize` and `bounds`. The
client embeds that file through a CMake-generated header; the dedicated
server embeds the same bytes as an assembly resource.

That is deliberate, and it is the point of the feature. This resource decides
whether a prompt appears; the server decides whether the shop sells. Two
implementations that disagreed by a centimetre at the boundary would leave a
place a player can stand where exactly one of them is true: an exploit that
looks like a network glitch. One file makes agreement a build property, and
`open77_zones_parity.lua` holds the line in both test suites.

So this file contains only what is genuinely client-side: ownership, the poll
cadence, the hysteresis band, the bounding-volume rejection, the vertex
budget, and resolving an attached entity's current position.

## Layout

```text
open77.lua
client/main.lua     create/remove/contains, the poll loop, hysteresis, attachment
```

There is **no** `server/main.lua`, and there does not need to be. Server
resources cannot call each other or share a Lua state (see
[The gamemode kernel and shared server services](https://open2077.net/docs/gamemode-kernel)), so a "server half" of a resource is not something
Open77 can build, which is exactly why the server side of zones is a
platform API (`Open77.zones.playersIn`, `Open77.zones.containsPlayer`) rather
than an export of this resource. Every server script reaches it directly.

## For a caller

- This is presentation only. Every rule that depends on containment must be
  re-derived on the server before anything is granted: an enter/exit event
  here is a hint, never proof. `Open77.zones.containsPlayer(playerId, def)`
  is that re-derivation, against the same definition table.
- Swapping a radius zone for a polygon is a change to the definition and
  nothing else: the export, the events, the handle and the hysteresis are
  identical for every shape.
- Owned handles are per-caller, per-generation: `remove`/`contains` refuse a
  handle belonging to another resource, and a caller's zones are dropped
  automatically when its resource generation stops or reloads.
- Two ceilings, shared across every resource on the client: 256 live zones,
  and 4096 live polygon vertices. The second is the one that matters: cost
  tracks edges walked on a tick where the player is *inside* the bounding
  box, not zones registered.

See [Zones](https://open2077.net/docs/zones) and the
[Complete server Lua API](https://open2077.net/docs/server-api).
