# open77_devices

This resource turns a vanilla device prompt off on every client, such as the one on a vending
machine, so your resource can put its own prompt there. You declare it once on the server and it
is applied by every client.

- **Docs:** [Overriding a vanilla device prompt](https://open2077.net/docs/device-interactions)
- **Starts:** on its own
- **Needs:** nothing
- **Runs on:** server and client

`Open77.world.setDeviceInteractionEnabled` is a client capability: the policy has to be held on the
machine that renders the prompt. This package owns the client claim, the wire, and the late-join and
routing-bucket answers, so a gamemode does not reimplement the fan-out and get them wrong.

Full guide: [Overriding a vanilla device prompt](https://open2077.net/docs/device-interactions).

The resource is `auto_start true`, but a server profile with an explicit `resources.load` list is a
silent allowlist: add `"open77_devices"` to it as well, or the package is never started and never
says so.

## Server exports

```lua
exports.open77_devices:disable("VendingMachine")
exports.open77_devices:disable(engineEntity, { bucket = 4 })
exports.open77_devices:enable("VendingMachine")
exports.open77_devices:clear("VendingMachine")   -- or clear() for everything this resource declared
local declared = exports.open77_devices:list()
```

`target` is an engine entity id (what `Open77.world.nearby(radius, "device")` reports as
`engineEntity`, decimal or `0x`) or a device class name. A class matches both the object class
(`VendingMachine`) and the controller persistent state (`VendingMachineControllerPS`).

Then draw your own prompt with [open77_interactions](../open77_interactions/), whose `class` target takes the same name.

## The use report

```lua
AddEventHandler("open77_devices:used", function(playerId, engineEntity, className, choice, allowed)
    -- ...
end)
```

This is a **claim by that client**, rate-limited to ten per second and per player. Validate distance,
bucket and eligibility on the server before acting on it.

## What stopping this resource does

Every server-declared policy lifts at once and every vanilla prompt comes back. That is the correct
failure: a device nobody can ever use again is the state the design refuses to allow. But it means
a disabled device is presentation, never a lock.
