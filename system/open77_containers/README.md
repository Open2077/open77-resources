# open77_containers

This resource gives a server durable world containers: crates, ground piles and depletable search nodes whose contents survive a restart, each shown as a server prop with an optional interaction prompt. The contents live in `open77_transactions` accounts, so every item moved in or out is recorded exactly once.

- **Docs:** [Server-owned world props](https://open2077.net/docs/props), [Durable transactions](https://open2077.net/docs/transactions)
- **Starts:** with `ensure open77_containers` (it declares `auto_start false`)
- **Needs:** `open77_interactions`, `open77_props`
- **Runs on:** server and client

## Use it

List `open77_containers` and [open77_transactions](../open77_transactions/) in `resources.load` and start both with `ensure`. The coordinator is not a manifest dependency, but nothing works until it is ready: until then, value operations answer `coordinator_unavailable`. The registry is kept in a SQL table (`open77_containers`), so the server needs a configured database. When the coordinator restricts its `writers`, allow `open77_containers:world`.

At every boot the resource rebuilds each container's prop, prompt and public summary from what is stored.

- Three kinds: `crate`, `pile` (removed when empty) and `node` (charges that are spent and regrow over time). A container without a `prompt` gets no prompt; `prompt = { label = "Open", key = "E" }` adds one.
- Create one from a server resource with the asynchronous export `create`, called through `Open77.exports.call("open77_containers", "create", spec)`. A spec takes `kind`, `position`, `yaw`, `bucket`, `model`, `label`, `capacityG`, `ttlMs`, `key`, `prompt` and, for a node, `node = { charges, regrowMs }`.
- Other asynchronous exports: `get`, `grant`, `revoke`, `reserve`, `commit`, `cancel`, `transfer`, `status`, `consume`, `refill`, `place`, `carry`, `drop`, `setPublic`, `setPrivate`, `close`. Synchronous reads: `summary`, `list`, `find`, `access`, `projection`.
- The owner holds every right; it can grant `take`, `put`, `target`, `consume`, `move`, `meta`, `read` or `close` to another resource.
- When a player uses a prompt, the server checks bucket and reach, then fires `open77_containers:used (id, playerId, choiceId, info)` for the owner to handle.
- On the client, `exports.open77_containers:summary(propId)` reads the public summary mirrored on the prop, for HUDs only.
- Console: `containers.spawn`, `containers.here`, `containers.list`, `containers.info`, `containers.remove`, `containers.grant`, `containers.consume`, `containers.refill`.
