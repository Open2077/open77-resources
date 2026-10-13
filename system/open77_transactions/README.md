# open77_transactions

This resource is the server's durable ledger for items and money: paying for a job, giving items, selling between players or stocking a stall all happen as one operation that is applied exactly once and leaves a receipt. Balances and the journal are kept in SQL tables, so they survive a restart.

- **Docs:** [Durable transactions](https://open2077.net/docs/transactions)
- **Starts:** with `ensure open77_transactions` (it declares `auto_start false`)
- **Needs:** nothing
- **Runs on:** server

## Use it

The server needs a configured MySQL or MariaDB database. List `open77_transactions` in `resources.load` and `ensure` it: on first start it creates its `op77_tx_*` tables and checks the store, then fires `open77_transactions:ready`. If the store fails its checks, every call answers `store_failed`.

Accounts are named `<namespace>:<key>`: `char`, `veh`, `stash` and `world` hold items, `cash`, `bank` and `soc` hold money, and `sys:` accounts are unlimited sources and sinks. Mutating exports wait on the database, so call them with `Open77.exports.call`:

```lua
local tx = exports.open77_transactions
local wallet = tx:account(playerId, "cash")
local pending, why = Open77.exports.call("open77_transactions", "transfer", {
    opId = tx:newOpId(), kind = "job_pay",
    lines = { { money = 250, from = "sys:jobs", to = wallet } },
})
local receipt
if pending then receipt, why = pending:await() end
```

- Two-step operations: `reserve`, then `commit` or `cancel`. One-step: `transfer`. Reads: `read`, `list`, `history`, `status`.
- Items are declared with `define`. `world:` containers are opened with `openWorld` and closed with `close` (see [open77_containers](../open77_containers/)).
- Operator tunables, set live from Warden or with `tunable.set open77_transactions <key> <value>`: `writers` (which resources may change which namespaces, `*` by default) and `mint1` to `mint6` (who may create items or money out of a `sys:` account, with an hourly cap). Nothing is created out of `sys:` until a mint rule allows it, for example `mint1` = `my_job sys:jobs money 100000`.
- Other tunables: `store`, `serverTag` (unique per server sharing a database), `preloadWorld`, `retentionDays` (90 by default), `workPerTick`.
- Server events: `open77_transactions:committed`, `open77_transactions:world`.
- Console: `transactions health | mints | read <account> | status <opId> | resolve <opId>`.
