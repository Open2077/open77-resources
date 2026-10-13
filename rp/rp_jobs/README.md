# rp_jobs

Gives your server jobs with grades, bosses, clocking in and out, and a salary paid from each job's society account. Other RP resources ask it which job a player has and whether they are on duty.

- **Docs:** [Build a job: prompts, animations, items and pay](https://open2077.net/docs/world-interaction)
- **Starts:** on its own
- **Needs:** `open77_uikit`, `open77_worldui`, `open77_contextmenu`
- **Runs on:** server and client

Server-authoritative jobs for an Open77 RP server (build `2.31.13+op77.76`). Replaces the
phase-0 `rp_jobs` in place: the `getJob` / `hasJob` exports and the `rp_jobs:changed` event are
kept, the courier run is gone (see "Removed from v1" at the end).

v2.1 adds the world-interaction **B4 adapter**: an authoritative eligibility export, a per-player
**work epoch** that invalidates pending work on any job, grade or duty change, a small public
summary, a server `setDuty` for foreman-style clock-in targets, durable keys through the subject
provider rule and no SQL-to-KVP fallback. Every v2 export, event and command is unchanged. Design
and contract: [`docs/world-interaction/b4-jobs.md`](../docs/world-interaction/b4-jobs.md).

A player holds **one job** with a **grade 0..3** (`recruit`, `employee`, `senior`, `boss`), can
clock in and out (`/service`), and is paid **in cash** from the job's **society** (`rp_bank`)
every 10 minutes while on duty. Civil jobs are joined at the **employment agency** (a ring and an
E prompt by the spawn); the others are staffed by their **boss** (ALT+click or `/embaucher`) or
by an admin (`/setjob`).

## The sixteen jobs

| name | label | joined how | salary per payroll (grade 0 / 1 / 2 / 3) | tag colour |
|---|---|---|---|---|
| `ncpd` | NCPD | boss or admin | 300 / 450 / 600 / 800 €$ | blue |
| `trauma` | Trauma Team | boss or admin | 300 / 450 / 600 / 800 €$ | red |
| `delamain` | Delamain | agency | 200 / 300 / 400 / 550 €$ | yellow |
| `mecano` | Mechanic | agency | 200 / 300 / 400 / 550 €$ | orange |
| `ripper` | Ripperdoc | boss or admin | 250 / 400 / 550 / 750 €$ | purple |
| `nomade` | Nomad | agency | 180 / 260 / 360 / 500 €$ | sand |
| `ferrailleur` | Scrapper | agency | 150 / 220 / 300 / 420 €$ | grey |
| `barman` | Bartender | agency | 150 / 220 / 300 / 420 €$ | pink |
| `cook` | Street cook | agency | 150 / 220 / 300 / 420 €$ | amber (the `rp_streetfood` stall job) |
| `techie` | Techie | agency | 180 / 260 / 360 / 500 €$ | gold (the `rp_techie` workbench job) |
| `farmhand` | Biotechnica farmhand | agency | 150 / 220 / 300 / 420 €$ | lime (`rp_chooh2`: the corn rows and the farm truck) |
| `refinery` | Petrochem operator | agency | 180 / 260 / 360 / 500 €$ | ochre (`rp_chooh2`: the refinery and the depot) |
| `fixer` | Fixer | boss or admin | 250 / 400 / 550 / 750 €$ | cyan |
| `netrunner` | Netrunner | boss or admin | 250 / 400 / 550 / 750 €$ | green |
| `vigile` | Security guard | agency | 180 / 260 / 360 / 500 €$ | steel |
| `gang` | Gang | **reserved** (nobody may hold it yet) | 0 | — |

Everything above is `shared/config.lua` (`RpJobsConfig.Jobs`, `.Grades`, `.PayrollIntervalMs`,
`.SocietyStartingFund`, `.HireDistance`, `.Agency`, `.NameplateMaxDistance`). The legacy names
`police`, `medecin` and `taxi` are aliases of `ncpd`, `trauma` and `delamain` (accepted by
`hasJob`, `setJob`, `listOnDuty`, `salary` and `/setjob`), so `rp_medic`, `rp_inventory`
(`implant_box` for a `medecin`) and `eval_taxi` keep working.

## Commands

| Command | Who | Effect |
|---|---|---|
| `/jobs` | anyone | The job board: every job, whether it is an agency job, and **who is on duty** in it. Yours is marked `[yours]`. |
| `/job` | anyone | Your file: job, grade (`2/3 senior`), `ON DUTY` / `off duty`, your salary, and the **society balance** (`rp_bank`). |
| `/service` | employees | Clock in / clock out. Refused without a job. Your on-duty colleagues are told; your tag appears over your body for everyone else. |
| `/agence` | anyone | The employment agency menu (UI kit context menu): join a civil job, resign from your current one, or leave. Works within `Agency.reach` (12 m) of the agency ring; set `reach = 0` to allow it anywhere. |
| `/embaucher <playerId> [grade]` | boss | Hires the player into your job as `grade` 0 (recruit), 1 or 2 — never 3. The target must be **within 5 m** and jobless. ALT+click a player > **Hire into <job>** does the same at grade 0. |
| `/virer <playerId>` | boss | Fires an employee of your job. They are told. |
| `/promouvoir <playerId> <grade>` | boss | Sets an employee's grade 0..2. `3` **hands over the boss seat**: they become boss, you step down to senior. |
| `/setjob <playerId> <job\|none> [grade]` | admin (ACL `command.setjob`) or the console | Gives or removes a job, any grade 0..3. The first time a job gets a boss this way, its society is **seeded** with `SocietyStartingFund` (50 000 €$) through `rp_bank`. |
| `/jobcheck <playerId> [job\|any] [minGrade] [duty]` | admin (ACL `command.jobcheck`) or the console | Prints the server's own eligibility verdict and the player's work epoch, e.g. `jobcheck player 1: refused off_duty (job=ferrailleur grade=0 duty=off epoch=..., store=sql)`. Changes nothing. |

Every player-facing refusal is explained in chat: no job, not the boss, too far (with the
distance), already employed elsewhere, unknown player, reserved job, invalid grade. From the
server console, `/jobs` `/job` `/service` `/agence` `/embaucher` `/virer` `/promouvoir` answer
`run it from the game`; `setjob` answers in the console.

Player ids are the session ids (`/players`). Names in chat come from `rp_identity` (`fullName`)
when it runs, else from the account name.

## Duty, tags and payroll

- Duty is written through to SQL (`on_duty`) but **never restored**: it is cleared on
  disconnect, when the resource stops, and for every row at boot (a crash cannot leave a stale
  flag). A player who comes back is off duty (and told they still hold the job).
- While on duty, every *other* client draws your nameplate as `[NCPD] Vince Rocker` in the job
  colour (`Open77.nameplates.set`, `maxDistance` 40 m). The nameplate API only overrides remote
  players, so you never see your own tag. The server broadcasts the roster; clients only render.
- **Payroll** runs every `PayrollIntervalMs` (10 min): for every on-duty employee,
  `exports.rp_bank:societyRemove(job, salary, "payroll")` then
  `exports.rp_economy:add(playerId, salary, "salary")`. A dry society pays nothing and the
  employee reads `No payroll this time: the NCPD society is dry.`; if the wallet refuses, the
  society is refunded. One log line per payment.
- The society starts empty. `/setjob <id> <job> 3` seeds it once per job (flag kept in the
  resource's kvp store: `seeded:<job>`). Fines, bills and sales from the other resources feed it
  afterwards.

## Exports (server, synchronous, never yield)

```lua
exports.rp_jobs:getJob(playerId)               -- "ncpd" | nil
exports.rp_jobs:hasJob(playerId, "police")     -- true | false   (aliases: police, medecin, taxi)
exports.rp_jobs:getGrade(playerId)             -- { level = 2, label = "senior" } | nil
exports.rp_jobs:isBoss(playerId)               -- boolean
exports.rp_jobs:onDuty(playerId)               -- boolean
exports.rp_jobs:setJob(playerId, "trauma", 1)  -- true | nil, reason
exports.rp_jobs:setJob(playerId, nil)          -- true (job removed)
exports.rp_jobs:listOnDuty("ncpd")             -- { 3, 7 }  (player ids, ascending)
exports.rp_jobs:salary("ncpd", 2)              -- 600
```

`setJob` reasons: `invalid_player_id`, `player_not_found`, `not_loaded` (the file is still being
read), `store_unavailable` (the database is configured but not answering, or the store is
refused: nothing changed), `subject_unavailable` / `invalid_key` (no durable key for that
player), `unknown_job`, `reserved_job` (`gang`), `invalid_grade`. `getJob`/`getGrade` answer `nil`
and `hasJob`/`isBoss`/`onDuty` answer `false` for a player whose file is not loaded.

### World-interaction adapter (B4)

```lua
exports.rp_jobs:eligible(playerId, requirement)    -- true, epoch | nil, reason
exports.rp_jobs:workEpoch(playerId)                 -- epoch | nil, reason
exports.rp_jobs:summary(playerId)                   -- { job, label, grade, gradeLabel, onDuty } | nil, reason
exports.rp_jobs:setDuty(playerId, true, { job = "ferrailleur" })  -- true, epoch | nil, reason
```

`requirement` is a table, every field optional (`nil` = any loaded file):

| Field | Meaning |
|---|---|
| `job` | a job name or a list of names (aliases accepted); the player must hold one of them |
| `minGrade` | integer 0..3; the player's grade must be at least this (`3` = boss **of that job**, unlike `isBoss`) |
| `duty` | `true` = must be on duty; `false` or absent = no duty constraint |
| `society` | the job's society name (today the job name) |
| `epoch` | a value from an earlier `eligible`/`workEpoch`; refused with `stale_job_epoch` if it moved |

Refusals: `invalid_requirement` (wrong type, unknown key, bad grade), `unknown_job`,
`invalid_player_id`, `player_not_found`, `not_loaded`, `store_unavailable`,
`subject_unavailable`/`invalid_key`, then `stale_job_epoch`, `no_job`, `wrong_job`,
`wrong_society`, `grade_too_low`, `off_duty` (checked in that order). `setDuty` adds
`invalid_duty` and `no_job`; do not put `duty` in its requirement.

The **work epoch** is an integer that moves on every job, grade and duty change of that player
(and is fresh at every load). Keep the epoch `eligible` returns when work begins and pass it back
as `requirement.epoch` at commit: any change in between answers `stale_job_epoch`. Epochs never
repeat for another player on the same seat nor after a restart of `rp_jobs`; compare them with
`==` only. A canInteract or a prompt only decides what a client is **shown**; the server's
`eligible` decides what happens.

Client side, `exports.rp_jobs:summary()` returns the local player's own file
(`{ job, label, grade, gradeLabel, boss, onDuty }`) for prompt presentation.

They read the in-memory cache only. Call them inside `pcall` from another resource (a
synchronous export raises when the resource is missing). A resource **without** a client script
may declare `dependency "rp_jobs"`; a resource with one must not (this manifest is delivered to
clients, and `rp_jobs` itself ships a client script).

## Events (host-wide bus, `TriggerEvent`)

```lua
AddEventHandler("rp_jobs:changed", function(playerId, jobName) end)       -- jobName is nil when the job was removed
AddEventHandler("rp_jobs:duty",    function(playerId, jobName, onDuty) end) -- onDuty is a boolean
AddEventHandler("rp_jobs:workEpoch", function(playerId, epoch, reason) end)
-- epoch: the new integer, or false when the file is gone (disconnect);
-- reason: loaded | job_changed | grade_changed | duty_on | duty_off | unloaded
```

`rp_jobs:duty (…, false)` is raised before `rp_jobs:changed` when an on-duty player changes or
loses their job, with the **old** job name. Each change raises its `rp_jobs:workEpoch` just before
its legacy event.

### Public summary (state bag)

While a player is on duty, their replicated player bag holds
`rp_jobs = { job = "ncpd", label = "NCPD", grade = "senior", duty = true }`; otherwise
`rp_jobs = { duty = false }`. The audience is the player's routing bucket, so the off-duty job
stays private, as the nameplate does. No identifier, hire record, salary, epoch or balance is ever
in it. Key name: `RpJobsConfig.PublicStateKey` (`false` = no bag key). Needs `state.write`; a
refused write is logged once and changes nothing else.

Internal net events (`rp_jobs:clientReady`, `rp_jobs:agency`, `rp_jobs:hire`, `rp_jobs:plate`,
`rp_jobs:roster`, `rp_jobs:self`) are this resource's client/server transport, not an API.

## Persistence

Table created inside `Open77.database.ready(...)` with `CREATE TABLE IF NOT EXISTS`, permission
`database.access`:

```sql
rp_jobs_employees (
    identifier VARCHAR(64) PRIMARY KEY,   -- Open77.players.identifier, never the session id
    job        VARCHAR(32) NOT NULL,
    grade      TINYINT     NOT NULL DEFAULT 0,
    on_duty    TINYINT(1)  NOT NULL DEFAULT 0,   -- informative: cleared on disconnect and on stop
    hired_at   BIGINT      NOT NULL DEFAULT 0,   -- unix seconds
    hired_by   VARCHAR(80) NOT NULL DEFAULT ''   -- the boss's identifier, "agency", "console", "admin:<identifier>", "export"
)
```

A row exists only while the player holds a job (`none` deletes it). The file is read on
`onPlayerReady` (and for everyone already connected on a hot start); every change is written
through with the callback forms, so the exports never touch the database. Writes are **serialized
per subject and coalesced**: one statement in flight per row, the next one built from the newest
state, so two quick changes can never land in SQL in the wrong order. A failed write is retried
(for as long as the database is unreachable, a few times otherwise). A failed SQL read is never
treated as "no job": the player is told to reconnect.

**Durable key.** `identifier` is the player's subject from the subject provider rule
(`RpJobsConfig.Subject`): `open77_transactions:subjectOf` when that coordinator runs, else
`Open77.players.identifier`, the account id either way until a character layer registers an
override. A session-shaped (`session...`), all-digit or over-long key is refused (`invalid_key`).

**Database configured but not answering:** no fallback. Job files stay unloaded (`getJob` nil,
`hasJob` false, `setJob`/`eligible` answer `store_unavailable`, `/service` says the records are
offline), the log says `store=pending after 15 s`, and the files load the moment the database
answers, in the same boot. A failing schema statement refuses the store (`store=refused`); an
unreachable one is retried.

**No database configured at all** (`ready` answers `database_unavailable`): with
`RpJobsConfig.LabKvpWithoutDatabase = true` (default) employment lives in `Open77.kvp`
(`emp:<identifier>`), a disposable test store the log names at every boot
(`store=kvp reason=database_unavailable`) and that never leaks into SQL; with `false`, job files
are refused instead.

The society seed flags (`seeded:<job>`) still live in the resource's KVP file in every mode: they
are wallet state that moves with the societies in the B3 migration.

## Log (grep-able)

```text
[rp_jobs] job board prop 123456 at -1172.3 2088.3 11.9
[rp_jobs] started: 16 jobs, payroll every 10 min, agency at -1173.1 2087.4 11.9
[rp_jobs] store=sql table=rp_jobs_employees
[rp_jobs] player 3 loaded job=ncpd grade=0 (sql)
[rp_jobs] player 3 work epoch=1760261234001 (loaded)
[rp_jobs] player 3 job=ncpd grade=3 (setjob by console)
[rp_jobs] player 3 work epoch=1760261234002 (grade_changed)
[rp_jobs] society ncpd seeded +50000 balance=50000
[rp_jobs] player 3 duty=on job=ncpd (player_request)
[rp_jobs] player 3 work epoch=1760261234003 (duty_on)
[rp_jobs] player 4 job=ncpd grade=0 (hired by player 3)
[rp_jobs] payroll player 3 ncpd grade=3 +800 cash=1300 society=49200
[rp_jobs] player 4 duty=off job=ncpd (disconnected)
[rp_jobs] store=pending after 15 s (database_unreachable): job files stay unloaded until the database answers; no KVP fallback
[rp_jobs] SQL write for <subject> failed (database_unreachable ...): attempt 1, retry in 1 s
```

## The agency POI

`RpJobsConfig.Agency.position = { x = -1173.12, y = 2087.44, z = 11.94 }` — **The Gallery**, the
elevated walkway at the north end of Kabuki Market, 83 m north-east of the freeroam spawn
(Kabuki Market Centre `-1191.30, 2006.88, 7.82`; walk north past The Arch and up the steps):
a ring, a map pin and an `E` prompt (`open77_worldui`, `promptDistance = 3.0`,
`style = "interaction"`), plus a **job-board terminal** the server spawns 1.2 m behind the ring
(`Open77.props.create`, the curated prop alias `electronics.monitor.device` — see
`prop.catalog` —, removed on stop; a refusal only logs). `z` is the walked height — if the ring is not visible, stand on the spot,
`/pos`, and paste the ground height. The Gallery is outside the `kabuki_market` safe zone (70 m)
and inside the `kabuki` district. The prompt fires `rp_jobs:agency`; the server checks the
distance again (`Agency.reach`) before opening the menu, so the client cannot open it from
anywhere.

## Manifest

Permissions: `network.events`, `database.access`, `ui.nameplates`, `world.props`, `state.write`
(the public summary bag). Dependencies:
`open77_uikit` (the agency menu, server twin `context`), `open77_worldui` (the POI),
`open77_contextmenu` (the hire action) — all three ship a client half. `rp_bank`, `rp_economy`
and `rp_identity` are server-only and reached through `pcall`: without `rp_bank` payroll and
`/job`'s balance say the bank is offline; without `rp_economy` the society is refunded and the
employee told; without `rp_identity` account names are used.

## Test in 2 minutes

Two players at the freeroam spawn (Kabuki Market Centre), ids `1` and `2`; `rp_bank`, `rp_economy` and (optionally)
`rp_identity` running. Log on start: `[rp_jobs] started: 16 jobs, ...` then `[rp_jobs]
store=sql table=rp_jobs_employees`.

1. **Console:** `setjob 1 ncpd 3` → console `Player 1 (...) is now boss at NCPD.`, player 1 reads
   `An admin made you boss at NCPD. /service to clock in.`, log `society ncpd seeded +50000`.
2. Player 1: `/job` → `Job: NCPD (ncpd) - grade 3/3 boss - off duty.`, `Salary: 800 €$ per
   payroll ...`, `Society NCPD: 50 000 €$.`
3. Player 1: `/service` → `Clocked in at NCPD as boss. 0 colleagues on duty. ...` Player 2 now
   sees `[NCPD] <name>` in blue over player 1's body. `/jobs` on player 2 lists `NCPD (ncpd): on
   duty: <name>`.
4. Player 1 stands 10 m from player 2: `/embaucher 2` → `Too far away (10 m). Get within 5 m to
   hire someone.` Walk next to them, hold **ALT**, click player 2, pick **Hire into NCPD** (or
   `/embaucher 2 1`) → player 1 `You hired <name> at NCPD as recruit.`, player 2 `Welcome to
   NCPD, choom: ... /service to clock in.`
5. Player 2: `/service` → both are on duty; player 1 reads `<name> clocked in (NCPD, recruit).`
6. Player 1: `/promouvoir 2 2` → player 2 is `senior`. `/promouvoir 2 3` → player 2 becomes
   boss, player 1 reads `You handed the NCPD boss seat to ... You are now senior.`
   Player 2: `/virer 1` → player 1 reads `... fired you from NCPD. Hand in your badge, choom.`
   and `/service` now answers `No job, no shift. /agence to find one.`
7. Player 1 walks 83 m north to The Gallery (map pin `Employment agency - Kabuki Gallery`, a
   terminal behind the ring), looks at the ring, presses **E** (or types `/agence` within 12 m):
   from the spawn `/agence` answers `The employment agency is 83 m away (the ring and map pin on
   the Kabuki Gallery walkway). Walk over.` The menu lists Delamain, Mechanic, Nomad, Scrapper,
   Bartender, Street cook, Security guard with their pay. Pick **Delamain** → `Signed: you now work for
   Delamain as recruit.` `/agence` again: Delamain is greyed out, **Resign from Delamain** is
   offered.
8. Wait for the payroll tick (10 min, or lower `PayrollIntervalMs` in `shared/config.lua` for the
   test): the on-duty boss reads `Payday from NCPD: +800 €$ as boss. Cash: ...`, log `payroll
   player 2 ncpd grade=3 +800 ...`; player 1's Delamain society is empty, so on duty they read
   `No payroll this time: the Delamain society is dry.`
9. Disconnect player 2 and reconnect: `Welcome back: you still work for NCPD as boss.`, off duty,
   the tag is gone for everyone until the next `/service`.
10. From another resource: `print(exports.rp_jobs:getJob(2), exports.rp_jobs:isBoss(2),
    exports.rp_jobs:hasJob(2, "police"))` → `ncpd true true`.
11. Each change above also logs a `work epoch=` line with its reason (`job_changed`,
    `grade_changed`, `duty_on`, `duty_off`). The B4 eligibility and epoch steps are in
    `docs/world-interaction/b4-jobs.md` ("Integrator test steps").

Offline: `python -m unittest discover -s tests -p "test_compat*.py"` from the `rp/` folder runs
this resource's real server script on the B8 fake host (`tests/test_compat_jobs.py`).

## Removed from v1

`/mission` and `/stopmission` (the courier run, its van and its waypoints) are **gone**: the
courier job is replaced by `rp_nomade` later in this phase. The v1 job names `livreur`, `taxi`,
`medecin`, `police` map to nothing / `delamain` / `trauma` / `ncpd`; a v1 KVP job file is not
migrated (v1 saved under `job:<identifier>`, v2 uses SQL or `emp:<identifier>`).
