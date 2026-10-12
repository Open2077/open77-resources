# open77_interactions

Shared interaction prompts for every Open77 resource: a small marker in the world that expands into
a custom action card, with up to four choices, when the player is close enough and looking at it.
It projects a world position or a streamed Open77 entity into the WebUI viewport, selects one
deterministic interaction, and emits a local event when an action key is pressed or held. It does
not use Cyberpunk's native interaction prompt.

- **Docs:** [Contextual world interactions](https://open2077.net/docs/interactions), [Build a job: prompts, animations, items and pay](https://open2077.net/docs/world-interaction)
- **Starts:** on its own
- **Needs:** nothing
- **Runs on:** server and client

Each definition controls its maximum `markerDistance`, colour, scale and marker motif (`dot`,
`ring`, `diamond`, `arrow`, `chevron`, `exclamation`, `info`, `vehicle`, `person`, `door`, or
`shop`). The arbiter renders only one winning interaction.

## Two rates

Positioning and content are split on purpose. The screen position of the marker comes from
`Open77.anchors`: the client registers a native anchor per plausibly visible entry (entity-attached
when the definition names an `entity`, a fixed world point otherwise), and the plugin projects it on
every rendered frame straight to this resource's page over `open77:anchors`. Everything else (which
entry wins, the card's text and choices, key state and hold progress) is decided on the Lua tick and
pushed as `interaction:update`, which carries no authoritative position: it names the `anchor` id the
page must follow. When an entry has no anchor yet (its first tick, or a client without the anchor
service) `interaction:update` omits `anchor` and carries `x`/`y`/`distance` as the fallback.

The plugin allows 32 anchors per resource against 256 interaction definitions, so the tick spends the
budget on the entries that could matter this instant: anything already within its own trigger radius
first, then the latched entry, then by priority and proximity. With the native card an entry outside
every anchor slot cannot be drawn and is not projected; on the page fallback it still projects in
Lua, so it is never invisible, only less smooth.

## Cost

Every phase of the tick is timed on the host's clock, and once every 30 s the resource prints one
line while it has anything registered:

```text
[open77_interactions] cost 30s: work=2.10 ms/s cycles=420 (gather reused 310, select reused 180) resolves=60
  | avg/max us: targets 40/600 resolve 380/700 (scan 170/300 [puppets 90/150 npcs 20/40
  vehicles 30/60 players 30/50] predicates 160/250) gather 120/650 anchors 60/180 select 50/260
  input 30/90 | entries=56 eligible=51 anchors=32 targets=3
  | natives: state=420 query=60 lists=180 project=0 anchorUpdates=4
```

The bracket inside `scan` is the scan's sources (`world`, `puppets` for the two world queries,
`npcs`, `vehicles`, `players` for the three list reads), each avg/max in microseconds, only those
that ran. A slow pass therefore names its native. A `globalNpc` target that can only mean
Open77-spawned NPCs (`npcs = "open77"`, or a `record` rule) resolves from `Open77.npcs.all` alone
and never runs the puppet query, so a server whose NPC prompts all sit on bodies it spawned shows
no `puppets` figure at all. The plugin's own side of a world query is
logged per stage with the bridge's `world.trace on` (`Open77 world query cost: … us: engine=…
resolve=… fill=… total=…`).

`work` is the sum of the phases, so it is directly comparable to the per-resource number the host
prints (`server/open77_interactions=<us>` per frame): this line says which phase that number went
to. The same figures come back from the `stats` export. `tests/budget.test.lua` replays the tick at
RP scale (forty rings, three global targets, 128 parts around) with a count hook and pins both the
worst resume and how often the resource asks the runtime for anything. The resolve pass
places NPCs, players and vehicles from the lists that already carry their positions (it makes no
per-body native read), and a cycle in which the player has not moved, no entry changed and no
anchor's projection moved reuses last cycle's ranked set and winner outright.

## Targets

A **target** is a standing rule (every vending machine, every vehicle, every player, everything of
a class, anything inside a volume) rather than one prompt bolted to one place. It is registered
once, re-resolved against what this client can currently see every 500 ms (every second while the
player stands still), and every match is
*materialised* as an ordinary entry: the arbiter, the anchor budget, the card, the hold, the
cooldown and the owner sweep above are reused unchanged, so a target cannot behave differently from
a hand-written interaction.

Seven kinds (`model`, `class`, `globalVehicle`, `globalPlayer`, `globalNpc`, `zone`, `prop`), with
`addModel` / `addClass` / `addGlobalVehicle` / `addGlobalPlayer` / `addGlobalPed` / `addBoxZone` /
`addSphereZone` as sugar over one `addTarget`. A per-target or per-choice `canInteract` gates a
prompt, evaluated at resolution time only: either the name of an export the owner published (run
inline in the owner's own VM, because functions never cross the export boundary) or a declarative
rule. `groups` gates on the player's own replicated state bag, not on a third permission model.

The server half publishes `define` / `undefine` / `clear` / `list`, so a job resource declares its
targets once and every client applies them over an ordinary authenticated net event, with late
joins and declaring-resource reloads handled.

A `prop` target (0.3.0) names server props by id and follows them, resolved from the `open77_props`
projection mirror rather than a world query. Offering a prompt on another resource's prop needs the
owner's grant (`grantProp` / `requestProp` / `answerPropRequest`), checked at `define` and at every
push; `propAccess` re-asks in the intent's handler. A client-declared prop target matches only the
declaring resource's own props.

There are deliberately **no vehicle bones**: Cyberpunk authors slot names per entity, no Lua binding
lists them, `Open77.vehicles.doors` is a bitmask index table rather than slots, and the anchor
offset is added in world axes without being rotated into the vehicle's frame. What is offered
instead is `part`, a state selector that puts `part`/`partIndex`/`partOpen` in the payload.

The service is presentation and input routing only. The owning resource may turn the local event
into a server request with `TriggerServerEvent`; that resource must declare `network.events`, and
the server must validate player identity, bucket, distance, permissions and authoritative state.
This is doubly true of a target: `groups`, `canInteract`, the distance and the vehicle state in the
payload are all read on a machine the player owns. A client can always claim it pressed the button.

See [Contextual world interactions](https://open2077.net/docs/interactions) for the complete contract and examples.
