# rp_trauma

Replaces the instant respawn with a roleplay death and runs Trauma Team International: players buy Silver, Gold or Platinum plans at Trauma Team kiosks, a player who goes down raises a call to the on-duty medics, one team stabilises the body and evacuates it to Vik's clinic, and every charge goes through the transaction coordinator.

- **Docs:** [Build a job](https://open2077.net/docs/world-interaction), [Actions and carrying](https://open2077.net/docs/actions), [Durable transactions](https://open2077.net/docs/transactions), [UI kit](https://open2077.net/docs/ui-kit), [Player health and stamina](https://open2077.net/docs/player-stats)
- **Starts:** on its own (`auto_start true`); the Trauma Team service (plans, calls, Stabilise and Evacuate, billing) starts once `open77_transactions`, `rp_inventory` and `open77_actions` run
- **Needs:** `open77_uikit`, `open77_contextmenu`, `open77_notifications`, `open77_props`; for the service `open77_transactions`, `open77_actions` (with `open77_animations`, `open77_interactions`), `rp_inventory` (transactions backend), `rp_jobs`, `rp_economy`; `rp_identity` for names
- **Runs on:** server and client

It includes the medic commands of `rp_medic` (`/soin /reanimer /911 /medic`): run one or the other, a
command name registered twice is served by the first resource only.

## How to play

### Citizens: plans

Walk to a Trauma Team kiosk (`/tti plans` lists them) and press **E** on *Trauma Team plans*. A menu
shows the three tiers with their price, priority and cover:

| Plan | Price per 7 days | Priority | Covers (stabilise, evacuate, Vik's bill, revive, patch up) | Health on arrival |
|---|---|---|---|---|
| Silver | 1 500 eddies | 3 (calls held back 5 s) | 100 %, 50 %, 50 %, 50 %, 0 % | 50 % |
| Gold | 4 000 eddies | 2 | 100 %, 100 %, 100 %, 100 %, 50 % | 75 % |
| Platinum | 10 000 eddies | 1 | everything | 100 % |

Pick one: a 4 s bar runs ("Signing the Trauma Team contract", tablet in hand) and the price leaves
your bank account (the cash wallet pays what the bank cannot), in one operation with your membership
card. Picking your current tier again renews it: one more week after the current end, at most four
weeks ahead. Picking another tier starts it now; the rest of the old plan is lost (the menu says so).
Leaving the menu signs nothing. Not enough money: the kiosk says so and nothing is held.

A plan that ends is renewed automatically from your bank account while you are connected, once per
period. If the account is short, the plan lapses and you are told once. `/tti autorenew off` stops the
renewals. `/tti` (or `/contrat`) shows your plan, its time left and what you owe.

### Citizens: going down

When you die you stay **down**: the freeroam respawn happens, then you are brought back to where you
fell, frozen, at 5 % health, inputs blocked except the chat, with a countdown hint. A call goes out:

- with a plan: "Trauma Team Gold: call #3 placed, priority 2. A team is on the way.";
- without: "No Trauma Team plan: emergency call #3 placed, the care is billed to you." The call reaches
  the medics after 15 s.

When a medic takes the call you read "Trauma Team medic <name> is responding to your call #3." Without
a plan, a dialog asks you to accept the charges (stabilisation 400 and evacuation 800 eddies, bank,
then cash, the rest invoiced): **Accept** lets the medic work, **Refuse** stops them for a minute. No
answer within 15 s counts as unconscious: the medic treats you and you are billed after. With a plan
there is no dialog: the plan's terms apply and you pay only the part it does not cover.

Once stable your hint reads "STABLE - Trauma Team is evacuating you". The evacuation fades your screen
and you wake up at Vik's clinic at your plan's health, with a chat line listing the charges ("400 eddies
covered by your plan, 400 eddies from your account"). What your wallets could not pay becomes an
invoice: `/tti pay` (or `/trauma payer`) settles it from the bank, then cash.

`/respawn` still works after the countdown (at once when no medic is on duty): you wake up at Vik's
and the bill (500 eddies) follows your plan. It closes your call.

### Trauma Team medics

Get the `trauma` job and clock in with `/service` (rp_jobs). Every call reaches you as a chat line, a
toast and a map pin whose title carries the call's tag and live distance: `[PLATINUM #3] Name down -
120 m`, `[UNINSURED #4] ...`, `[TAKEN #3] ...` once a team has it.

1. `/tti take` answers the best open call (priority, then oldest), `/tti take 3` a given one. One team
   per call: another medic reads "Another Trauma Team unit has this call." and can join with
   `/tti assist 3`. `/tti drop` leaves your calls (an empty team reopens the call for everyone).
2. Fly or drive: `/trauma av` on the AV pad of the Afterlife street spawns the Trauma Team AV with you at
   the controls; `/trauma av off` sends it back.
3. At the body, **E** *Stabilise the patient*: you kneel for 8 s (X cancels). One medic per body at a
   time. The patient is now stable (25 % health, still down).
4. **E** *Evacuate to Vik's clinic*: a 6 s bar, then the patient is moved to the clinic.

Each act pays you 40 % of what the patient paid, straight from their wallet, plus 40 % of what their
plan covered, paid by the Trauma Team society while it can afford it; you read "+N eddies to your
account". The rest stays with the society (`soc:trauma`).

The older acts remain: ALT+click a player or `/soin <id>` **Patch up** a hurt standing citizen (they
accept the charges first; no answer is a no), ALT+click or `/reanimer <id>` **Revive** a down
citizen where they lie (same rules as Stabilise). `/911 <message>` alerts Trauma Team and the NCPD,
`/medic` lists the medics on duty, `/tti calls` and `/trauma` show the dispatch.

### What everyone around sees

The medic kneeling over the body (the `examine` pose), the patient in the wounded seated pose while
down, the prompt card over the body for the medics close enough, then the patient disappearing when
evacuated (their own screen fades). The poses are played by the server, so every client sees them.

## Setup

In `resources.load`, the libraries first, and **not** `rp_medic`:

```text
resources.load: [ ..., "open77_transactions", "open77_animations", "open77_props", "open77_interactions",
                  "open77_uikit", "open77_contextmenu", "open77_notifications", "open77_actions",
                  "rp_jobs", "rp_inventory", "rp_economy", "rp_identity", "rp_trauma" ]
```

Once, in the server console (merge with the other jobs' entries: `writers` is one list for the whole
server, and use a `mintN` number no other rule uses):

```text
tunable.set open77_transactions writers rp_trauma:cash+bank+soc+stash/tti, rp_economy:cash+bank+soc, rp_inventory
tunable.set open77_transactions mint1 rp_trauma sys:trauma.plans tti_card 500; rp_trauma sys:trauma.billing tti_invoice 2000000
ensure open77_transactions
ensure open77_actions
ensure rp_trauma
```

- `writers`: rp_trauma moves money between wallets (`cash`, `bank`), into the society (`soc:trauma`)
  and writes each holder's file `stash:<subject>:tti`. It creates no money.
- `mint`: the membership card (`tti_card`) is created out of `sys:trauma.plans`, invoices
  (`tti_invoice`, one unit per eddy owed) out of `sys:trauma.billing`. Paying an invoice burns it.
- The convar `rp_inventory_backend` set to `transactions` (before `rp_inventory` starts): the two
  items are declared through `rp_inventory:define`, which reaches the coordinator only with that
  backend.
- `rp_jobs` must know the `trauma` job (it ships it).

Expected log lines:

```text
[rp_trauma] started: down=60 s, hospital bill=500, fees heal=100 revive=300 stabilise=400 evacuate=800, plans silver/gold/platinum, ...
[rp_trauma] coordinator ready (store=sql)
[rp_trauma] items defined through rp_inventory: 2
[rp_trauma] ready: 3 plans, 2 kiosk and patient targets, job trauma, society trauma
[rp_trauma] call #1 raised: player 3 gold priority 2 at -1195, 2001, 8
[rp_trauma] stabilise tt.care:...: player 3 by 4 fee=400 covered=400 paid=0 invoiced=0 cut=0 bounty=160
[rp_trauma] evacuate tt.care:...: player 3 by 4 moved=true fee=800 covered=800 ...
```

Console (restricted, ACL `command.tti.*`): `tti.status` (counters and open calls), `tti.setup <id>`
(the trauma job, on duty), `tti.act <medic> stabilise|evacuate <patient>` (the request the body's
prompt makes), `tti.file <id>` (a holder's plan and invoices as the coordinator holds them).

### rp_trauma 1.x servers

On a player's first join, their 1.x state is imported once: an active contract becomes a Gold plan
until its paid period ends, every unpaid bill (SQL `rp_trauma_bills` or the kvp `debt:` fallback)
becomes an invoice. The rows are marked (`paid_at = 0`, `active = 0`) and the operation ids come from
them, so a second import moves nothing. The two tables keep their schema (created when missing, for
`rp_mdt`); nothing else is written to them.

## Config

`server/config.lua` (`TraumaConfig`), server only:

| Key | Value | Meaning |
|---|---|---|
| `plans.<tier>` | see the table above | `price`, `periodHours`, `priority`, `dispatchDelaySeconds`, `covers.<act>`, `evacHealth`, `pitch` |
| `maxPrepaidPeriods` | 4 | how far ahead a plan can be paid |
| `autoRenew` | default on, from the bank, every 30 s | renewal of an ended plan |
| `payFrom` / `invoices.payFrom` | bank, then cash | wallets that pay a plan / a charge or an invoice |
| `fees` | stabilise 400, evacuate 800, hospital 500, revive 300, heal 100 | before the plan's cover (the last three come from `shared/config.lua`) |
| `medicShare` / `medicWallet` | 0.4 / bank | the medic's cut and where it lands |
| `consent` | 15 s, a refusal holds 60 s | the dialog shown to a patient without cover |
| `calls` | uninsured calls on, priority 9, held back 15 s, reminders every 60 s, 48 at once | dispatch |
| `actions` | plan 4 s (`tablet`), stabilise 8 s (`examine`, 25 % health), evacuate 6 s (`tablet2`) | open77_actions definitions |
| `evacuation` | Vik's clinic (`Config.hospital.respawn`) | where an evacuated patient wakes up |
| `accounts` | `sys:trauma.plans`, `sys:trauma.billing`, file part `tti` | coordinator accounts |
| `legacy` | on, contracts become `gold` | the 1.x import |

Kiosks (open77_actions targets; estimates near measured points, to be walked):

| Id | Position | Landmark |
|---|---|---|
| `tti_kiosk_pad` | -1376.0, 950.5, 23.5 | Afterlife street, 6.5 m west of the Trauma Team AV pad centre |
| `tti_kiosk_market` | -1186.5, 2010.5, 7.82 | Kabuki Market, 6 m north-east of the market centre |

`shared/config.lua` (`Config`, both sides) keeps the down state: `downSeconds` (60; 600 for a live
server), `countdownWithoutMedics` (true; false for a live server: `/respawn` at once with nobody on
duty), `hospitalBill`, `healFee`, `reviveFee`, the bars of the older acts, `downHealthFraction`
(0.05), `reviveHealthFraction` (0.5), the hospital point (Vik's clinic, `-1546, 1231, 11.6`), the AV
(`Vehicle.av_trauma`, pad `-1370, 953, 23.5` r 12) and the staging poses.

### Exports and events

```lua
exports.rp_trauma:isDown(playerId)        -- boolean
exports.rp_trauma:hasContract(playerId)   -- boolean: an active plan of any tier
exports.rp_trauma:planOf(playerId)        -- { tier, label, untilAt, autoRenew, priority } | nil
exports.rp_trauma:owed(playerId)          -- eddies invoiced and not paid (connected players)
exports.rp_trauma:calls()                 -- { { id, patient, priority, tier, state, responder, stable, position } }
exports.rp_trauma:revive(playerId, byId)  -- true | nil, reason (no fee)
exports.rp_trauma:heal(playerId, byId)    -- true | nil, reason (no fee)
```

| Event (host bus) | Arguments |
|---|---|
| `rp:job:completed` | `{ job = "trauma", kind = "subscribe" \| "stabilise" \| "evacuate" \| "revive", playerId, ref, data }`: the buyer for `subscribe`, the medic otherwise; `ref` is the coordinator operation id |
| `rp_trauma:down` | `playerId, position` |
| `rp_trauma:revived` | `playerId, byPlayerId \| nil` (a revive, an evacuation, a hospital respawn) |
| `rp_trauma:call` | `callId, "open" \| "taken" \| "closed", patientId, medicId \| reason` |
| `rp_trauma:subscribed` | `playerId, tier, untilAt` |

Durable state lives in the coordinator: each holder's file `stash:<subject>:tti` holds the membership
card (a unique item whose metadata is the plan: tier, end, periods, auto-renewal) and the invoices.
The medics' counters stay in `Open77.kvp`. Calls, consents and the down state are runtime state.

## Limits

- The platform cannot hold the freeroam respawn: the down state re-applies itself after it (a
  teleport back to the death spot under a fade). A body is never carried: the evacuation is a fade
  and a teleport to Vik's clinic.
- The consent dialog is shown to a player whose gameplay inputs are blocked; the UI kit takes its own
  focus. Any answer that never comes (closed dialog, another resource's dialog open, the kit
  unavailable) counts as unconscious: treated and billed after.
- The medic kneels where they stand, not turned towards the body.
- A covered act pays the medic only while the society can afford the bounty; an invoiced amount pays
  the society when the patient settles it, not the medic.
- A restart forgets the open calls and frees every held player (no bill); plans and invoices stay.
- `rp_mdt` reads the 1.x tables for contracts and bills: point it at `planOf`, `owed` and `calls`.
- Stabilise and Evacuate need `open77_actions`; without it only the older acts and `/respawn` remain.
