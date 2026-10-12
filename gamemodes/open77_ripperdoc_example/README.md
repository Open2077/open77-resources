# open77_ripperdoc_example

A replaceable ripperdoc role-play example: a doctor offers to install, inspect or remove Gorilla Arms and double-jump legs on a nearby patient, the patient accepts by holding E, and the procedure is paid from a session-only clinic credit balance. Implants are stored durably by the platform; the credits and prices are a demonstration you replace with your own economy.

- **Docs:** [Cyberware](https://open2077.net/docs/cyberware)
- **Starts:** with `ensure open77_ripperdoc_example` (it declares `auto_start false`)
- **Needs:** `open77_cyberware`, `open77_interactions`
- **Runs on:** server and client

## Use it

This resource supplies replaceable RP policy using the public cyberware APIs.
It is disabled by default, including on servers using wildcard discovery.
Opt in by adding it to `resources.load` and explicitly running
`ensure open77_ripperdoc_example` from the server console. Both its server and
downloaded client halves then start. Server makers can replace the entire policy.

Grant doctors ACL `command.doc`. The patient needs no installation permission.
While both players are alive in the same bucket within three metres:

- Doctor: `/doc offer <patient-id> training` (or `industrial`, `cosmetic`).
- Doctor: `/doc inspect <patient-id>` requests a free arm inspection using the
  same consent prompt. After acceptance, only doctor and patient receive the
  installed definition, grade, native profile and cosmetic/nonlethal mode, or
  confirmation that no arm implant is installed. Inspection changes neither
  equipment nor credits. It does not expose account IDs or invent condition data.
- Patient: look at the doctor and hold **E** to accept, or press **F** to decline.
  `/implantaccept` and `/implantcancel` provide chat controls for the same flow.
- Both stay nearby during the procedure. Movement apart, death, disconnect,
  expired consent, revision changes and failed native projection cancel it.
- Doctor: `/doc remove <patient-id>` requests removal with separate consent.
- `/cliniccredits` shows the example account's available clinic credits.

Configuration lives in `server/config.lua`: grades, damage, charge/cooldown,
knockback, cosmetic/nonlethal flags, prices, range and procedure/consent duration.
The example credit account starts at 500 and is scoped to this resource's server
session, retaining its balance across a player reconnect but resetting when the
resource or server restarts. It is a demonstration budget, not a persistent RP
economy. Replace this optional resource's payment policy with your economy.
Implants themselves use the platform's durable character storage.

Consent reserves the price once. The platform's completion event finalizes it;
failed projection/cancellation refunds it. A native stage may be cancelled only
by the resource that started it. Once SQL commit begins, cancellation reports
`operation_committing` and the example waits for the actual outcome.
Each new offer uses `Open77.cyberware.newOperationId()`; that ID is retained
through submission/retries. Process-local resource counters are never used as
durable transaction IDs.

The interaction service owns prompt cleanup when this resource stops. The
platform releases owned pending stages and definition grants. A stopped preset
does not delete paid durable implants; its matching definition must be restored
before those implants can grant power again.

Default prices: training arms 100 credits, industrial 250, cosmetic free, and 25
credits for a removal, so a removal followed by a training reinstall takes a
fresh account from 500 to 375.

`maxAccounts` (default 1024, integer 1..10000) bounds the example's session credit
ledger. At capacity, new accounts receive a clear refusal before payment or an
implant request; existing balances and reserved refunds remain usable. Disconnect
does not evict a balance or refill credits on reconnect. This remains a session
clinic demonstration: resource/server restart resets its ledger. Replace it with
your economy adapter for durable currency; the platform's implants stay durable.

## Double-jump legs

The existing commands default to arms. Select legs explicitly:

- `/doc offer <patient-id> training legs` installs `example.double_jump` (or use
  `athlete`). The patient accepts through the same physical prompt or
  `/implantaccept`, with the same procedure, cancellation and refund rules.
- `/doc inspect <patient-id> legs` privately reports the installed definition,
  grade, profile and configured stamina cost after consent.
- `/doc remove <patient-id> legs` removes only legs and retains Gorilla Arms.

`server/config.lua` supplies replaceable `legsDefinition`, `legsCosts` and
`legsRemovalCost`. Training costs 100 credits and 15 stamina per admitted second
jump; athlete costs 250 credits and 8 stamina. The native jump trajectory is the
same for both grades. Airborne-time/fall-speed admission limits are configurable,
not an added jump-height or fall-immunity grant. Prices and stamina are distinct.

Use the ordinary jump button twice: take off, release, then press again while
in the air. The server admits one second jump per airtime; landing rearms it.
Input can be refused for insufficient stamina, cooldown, life/vehicle/motion
conflicts or stale body state. Observer movement uses the existing replicated
native air presentation; no added network particles/sounds are requested here.

## Combining the doctor workflow with Dash

After a consenting patient finishes installing double-jump legs, an independently
enabled `open77_parkour_example` can grant the session capability with
`/parkour install basic combined` (or `advanced`). The optional cyberware lab
provides the same grant/inspect/remove workflow. Standalone `air` needs no paid
leg replacement. These resources use `Open77.dash` and preserve the doctor's
durable equipment record, consent and payment policy. They do not buy Dash on
the patient's behalf or add a second equipment ledger. Server creators decide
which optional resources, jobs, prices and training zones are available.

See [parkour setup](../open77_parkour_example/) and
[Native Dash and Air Dash](https://open2077.net/docs/dash).
