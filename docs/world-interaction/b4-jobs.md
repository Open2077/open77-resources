# B4: job, duty and grade adapter over `rp_jobs` (wave 1, minimal)

**Row:** B4 of the world-interaction plan (`wt-world-interaction/docs/world-interaction-plan.md` §4 B).
**Date:** 2026-10-12. **Branch:** `Open2077/open77-rp-examples` `wi/b4-jobs`, from `wi/b8-compat` (d401b40).
**Resource:** `rp_jobs` 2.0.0 → 2.1.0.

**Status: built offline, not proven.** Nothing was deployed, no server or database was started, the game
was not launched and no `open77_*` tool was called. Every behaviour below was executed only on the B8
offline fake host (`tests/compat/fakehost.lua`) with Lua 5.4 through KeraLua's `lua54.dll`. Nothing here
claims in-game behaviour; the two-client proof is the integrator's (§8).

**Reconcile (2026-10-12, branch `wi/reconcile-a13`):** the final `open77_transactions` (Open77 `697e9e2f`)
ships the `subjectOf` export and the one-override provider this row assumed; `rp_jobs` needed no code change.
Its subject rule is now also tested against that coordinator (vendored, `server/main.lua` included):
`test_subject_provider_rule_against_the_final_coordinator` (§4.1, §6).

**Conventions.** **Fact** = seen in source or in an offline run cited here. **Inference** = follows from
source, not measured. **Open** = a decision for the integrator or the owner.

---

## 1. What the row asked and where it is answered

| Requirement (plan §2 step 1, §4 B4, §5.3 Authorization) | Answer | Offline evidence |
|---|---|---|
| "A clocks in at a foreman/NPC target. The server validates duty and eligibility." | `setDuty(playerId, on, requirement)` export for a foreman target; `eligible` for every later step | `epoch_invalidation` (setDuty), `compat_exports` (setDuty refusals) |
| Authoritative eligibility; `canInteract` controls presentation only | `eligible(playerId, requirement) -> true, epoch \| nil, reason`; client `summary()` documented as presentation only | `eligibility_matrix`, `forged_prompts` |
| "Job/grade changes invalidate pending work as specified" | per-player **work epoch**, event `rp_jobs:workEpoch`, `stale_job_epoch` at commit | `epoch_invalidation` |
| "Forged visible prompts grant nothing" | every net event and every commit re-decided on the server | `forged_prompts` |
| "Job/duty persist" | SQL write-through of job, grade and duty, serialized per subject, retried; duty cleared at boot | `persistence_round_trip` |
| "Exports remain compatible" | the 8 exports, their tokens, the 2 events and the 8 commands unchanged; new tokens are additive | `compat_exports`, `test_compat_contracts.py` |
| Durable keys only (A13 §3.1, §12.5) | subject provider rule; session-shaped keys refused | `subject_provider` |
| No KVP fallback when the database is enabled (B8 R1) | configured database not answering → `store_unavailable`, never KVP | `no_kvp_fork` |
| Public HUD summary small and audience-appropriate | player bag `rp_jobs` (on duty only), server `summary`, client `summary` | `public_summary` |

---

## 2. API

All server exports are synchronous and never yield (callable through `exports.rp_jobs:x()` or
`Open77.exports.callSync`, so B5's synchronous eligibility hooks can use them).

```lua
exports.rp_jobs:eligible(playerId, requirement)          -- true, epoch | nil, reason
exports.rp_jobs:workEpoch(playerId)                       -- epoch | nil, reason
exports.rp_jobs:summary(playerId)                         -- { job, label, grade, gradeLabel, onDuty } | nil, reason
exports.rp_jobs:setDuty(playerId, onDuty, requirement?)   -- true, epoch | nil, reason
-- client (the local player's own file, presentation only):
exports.rp_jobs:summary()                                 -- { job, label, grade, gradeLabel, boss, onDuty }
-- host-wide event:
AddEventHandler("rp_jobs:workEpoch", function(playerId, epoch, reason) end)
```

### 2.1 `requirement`

Every field is optional; `nil` (or `{}`) means "any player whose file is loaded".

| Field | Type | Meaning |
|---|---|---|
| `job` | string or array of strings | the player holds one of these jobs (aliases `police`/`medecin`/`taxi` accepted) |
| `minGrade` | integer 0..3 | grade ≥ this; `{ job = "ncpd", minGrade = 3 }` is a boss check **scoped to the job** (`isBoss` is not) |
| `duty` | boolean | `true` = on duty; `false` = no constraint |
| `society` | string | the job's society (today the job name, case-insensitive) |
| `epoch` | number or `false` | a value captured earlier; any change since answers `stale_job_epoch` |

`minGrade`, `duty = true` or `society` imply that the player holds *some* job (`no_job` otherwise).
Unknown keys are refused, so a typo (`grade` for `minGrade`) cannot silently widen a requirement.

### 2.2 Refusal tokens, in evaluation order

| Token | When |
|---|---|
| `invalid_requirement` | not a table, unknown key, `minGrade` not an integer 0..3, `duty` not boolean, empty or mixed job list, `epoch` not a number |
| `unknown_job` | a `job` entry names no job |
| `invalid_player_id` | not an integer ≥ 1 (checked before any lookup; `0` never reaches `players.identifier`) |
| `player_not_found` | no file for that seat (not connected, or disconnected) |
| `subject_unavailable` / `invalid_key` / the provider's own token | no durable key (§4.1) |
| `store_unavailable` | the database is configured but not answering, the store was refused, or the read failed |
| `not_loaded` | the read is in flight |
| `stale_job_epoch` | `requirement.epoch` differs from the current epoch |
| `no_job`, `wrong_job`, `wrong_society`, `grade_too_low`, `off_duty` | business refusals |

`setDuty` adds `invalid_duty` (not a boolean) and `no_job`. Its requirement is checked first; do not put
`duty` in it. It answers `true, epoch` and leaves the epoch unchanged when the player already is in that
state. It sends the same chat lines as `/service` and logs `duty=on ... (export by <resource>)`.

### 2.3 `summary` and the public bag

| Surface | Audience | Content |
|---|---|---|
| player state bag key `rp_jobs` (`RpJobsConfig.PublicStateKey`) | everyone in the player's routing bucket | on duty: `{ job, label, grade = <grade label>, duty = true }`; otherwise `{ duty = false }` |
| server `summary(playerId)` | the calling server resource decides | `{ job \| false, label \| false, grade \| false, gradeLabel \| false, onDuty }` |
| client `summary()` | the local player only (from the private `rp_jobs:self`) | `{ job, label, grade, gradeLabel, boss, onDuty }` |
| `rp_jobs:plate` broadcast (unchanged) | all clients | `[<job label>] <name>` + colour, on duty only |

The bag never holds the identifier, the hire record, the salary, the epoch or a balance (test
`public_summary`). An off-duty job is not public, consistent with the nameplate, `/jobs` and `listOnDuty`.
A refused bag write (`permission_denied:state.write` without the new manifest permission) is logged once
and changes nothing else.

---

## 3. Work-epoch contract (for B5 `open77_actions` and any other consumer)

1. **Value.** A Lua integer, or `false` when the player has no loaded file (disconnected). Today it is
   `floor(boot wall clock in ms) + n`, drawn from one sequence per `rp_jobs` generation, so it is unique
   across players, across seat reuse and across restarts of `rp_jobs` (inference: a collision needs one
   generation to make more changes than there are milliseconds between its start and the next start).
   **Compare with `==`/`~=` only.** The order happens to increase within a generation; do not rely on it.
2. **Moves on** (one new value per change, with this `reason`): `loaded` (every load, including a hot
   restart of `rp_jobs`), `job_changed` (hire, fire, resign, agency, `setjob`, `setJob`), `grade_changed`
   (only when the grade actually changes), `duty_on`, `duty_off` (including `job_changed` and
   `disconnected` clearing duty). A disconnect then raises `(playerId, false, "unloaded")`.
   A no-op `setjob`/`setJob` (same job, same grade) and payroll do **not** move it.
3. **Event.** `TriggerEvent("rp_jobs:workEpoch", playerId, epoch, reason)` right after the state change
   and before the legacy `rp_jobs:duty` / `rp_jobs:changed` event of the same change. The host queues bus
   events to the next tick, so a listener that reads `workEpoch(playerId)` already sees the new value.
4. **Pending work.** Capture `epoch` from `eligible` (or `workEpoch`) when the work begins; at commit call
   `eligible(playerId, { ..., epoch = captured })`, which answers `stale_job_epoch` if anything moved.
   The event lets a consumer cancel at once instead of waiting for the commit.
5. **What it is not.** It is not a durable value and not a lock: it does not survive a restart (a restart
   invalidates everything captured before, by design), and two server instances sharing one database have
   independent epochs.

**B5 mapping** (read-only check of `wt-wi-b5/resources/system/open77_actions`, `shared/model.lua:346-399`,
`server/engine.lua:382-450`; that repository was not edited):

```lua
eligibility = { resource = "rp_jobs", export = "eligible", args = { job = "ferrailleur", duty = true } },
epochs      = { resource = "rp_jobs", read = "workEpoch", event = "rp_jobs:workEpoch" },
```

- B5 calls `callSync("rp_jobs", "eligible", playerId, args)` and reads `allowed, why`; `true, epoch`
  satisfies it and the second value is ignored there.
- B5's epoch guard reads `workEpoch(playerId)`, maps `nil` to `false`, and compares with `~=`; it also
  follows the event and cancels the running operation with the guard's reason (default `stale_job_epoch`).
  A `false` event after a disconnect is consistent with that mapping.
- Recommended: use `read` **and** `event`. The read is authoritative; the event only makes cancellation
  immediate.

`rp_jobs` applies the same rule to its own pending work: the employment agency menu captures the epoch
when it opens and refuses the choice (`Nothing was signed: open it again.`) if the file changed while it
was open.

---

## 4. Persistence

### 4.1 Durable key (subject provider rule)

- `rec.identifier` = `open77_transactions:subjectOf(playerId)` when that coordinator answers
  (`RpJobsConfig.Subject`), else `Open77.players.identifier(playerId)`. Today both are the account id
  (A13 §12.5 and §12.8: the account id is the default character id), so **no existing row moves**.
- A provider refusal (`nil, reason`) is passed through, never replaced by the account id.
- **Resolved by 697e9e2f.** `open77_transactions:subjectOf(playerId)` exists, never yields and answers the
  account id by default; one resource may register an override (`registerSubjectProvider`); a second is
  refused. Its refusals reach `rp_jobs` as is: `invalid_player`, `subject_unavailable`,
  `subject_provider_unavailable`, `invalid_key` (its own key lint: session-like or all-digit keys, at most
  80 bytes of `[A-Za-z0-9_.@~-]`), or the override's own reason. `rp_jobs` keeps its stricter 64-byte limit
  (the column). **Fact (offline, real coordinator):** default key `acct-0007`, override key `acct-0007~3`, an
  override refusal `no_character` passed through, `session:7` and `12` refused `invalid_key` with no row.
- `Subject.required = true` refuses files while the provider is not running. **Open:** set it the day a
  character override provider is registered; otherwise a boot without the coordinator would key rows by the
  bare account id (a fork between characters).
- Refused keys (`invalid_key`): empty, longer than the 64-byte column, control characters,
  `session...`-prefixed, all digits. Nothing is ever keyed by the session id.

### 4.2 Store states (chosen without fallback)

| Server | State | Behaviour |
|---|---|---|
| database configured and answering | `sql` | schema, then `UPDATE ... SET on_duty = 0 WHERE on_duty <> 0`, then files load |
| database configured, not answering yet | `pending` | files wait unloaded; every change refused `store_unavailable`; WRN after 15 s; files load **in the same boot** when it answers |
| schema statement fails | `pending` + retry if `database_unreachable`; else `refused` | `refused`: files never load this boot, every change refused |
| no database configured (`ready` → `database_unavailable`) | `lab_kvp` if `LabKvpWithoutDatabase` (default) else `refused` | explicit disposable lab store, logged at every boot, never read on an SQL boot |

**Fact (offline, before/after):** the shipped script (d401b40) on a database that does not answer within
15 s falls back to KVP (`database not ready after 15 s (database_unreachable): falling back to Open77.kvp`),
accepts `setJob(7, "ncpd", 0)` into `emp:acct-0007 = ncpd|0|...` and, on the next SQL boot, shows the SQL
job again: the change made during the outage is stranded. With this branch the same boot refuses the change
(`store_unavailable`), writes no `emp:` key, and loads the SQL job once the database answers.

### 4.3 Writes

- One statement in flight per subject (`writers[identifier]`); further changes mark it dirty and the next
  statement is built from the newest record when it leaves. **Why:** the bridge runs one resource's
  requests concurrently (A13 D1), so two absolute upserts could land in reverse order.
  Offline: three `setjob`s during one in-flight write submit 2 statements and SQL ends on the third state.
- Failed write: retried with backoff (1, 2, 4, ... 30 s) for as long as the reason is
  `database_unreachable`, up to 4 attempts otherwise; memory stays authoritative meanwhile.
- A reconnect while a write is in flight takes the newer in-memory state instead of the stale row.
- `on_duty` is written through with the row, cleared on disconnect, on stop and for every row at boot
  (a crash cannot leave a stale 1). It is informative: nothing reads it back.
- The schema is unchanged (`tests/compat/schema-snapshot.json` still matches).

### 4.4 Remaining KVP use (not employment)

`seeded:<job>` (the one-time society seed flag) still lives in the resource's KVP file in every mode. It is
wallet state; B8 §5.3 assigns its move to SQL to the B3 migration with the societies. Until then a redeploy
that wipes the resource's `data/` re-seeds a society (B8 inference, unchanged here).

---

## 5. Compatibility

- **Unchanged:** `getJob`, `hasJob`, `getGrade`, `isBoss`, `onDuty`, `setJob`, `listOnDuty`, `salary`
  (signatures, values, not-loaded semantics, aliases); `rp_jobs:changed` and `rp_jobs:duty` (payloads and
  order: `duty(false)` with the old job before `changed`); `/jobs` `/job` `/service` `/agence` `/embaucher`
  `/virer` `/promouvoir` `/setjob`; job names = society names; grade 0..3 with boss = 3; duty never restored.
- **Additive:** `setJob` may answer `store_unavailable`, `subject_unavailable` or `invalid_key` where it
  answered `not_loaded`; `/service`, `/job` and the agency explain an offline store; new exports, event,
  restricted command `jobcheck` (ACL `command.jobcheck`), manifest permission `state.write`.
- **Static suite:** the frozen consumer surface (`test_adapter_surface_is_frozen`) is unchanged because no
  consumer was edited; new exports are declared but not yet consumed.
- **Not papered over (B8 §5.4):** `rp_medic` still compares `getJob()` to the legacy `medecin`/`police`
  (never matches in jobs mode); `isBoss` stays unscoped (use `eligible{ job, minGrade = 3 }`); the
  differing duty checks of `rp_shops`, `rp_bar`, `rp_trauma` are untouched. Those are consumer fixes.
- **Behaviour change to know:** `onPlayerReady` for a seat whose file is already open (or opening) is
  ignored instead of re-reading over live duty. **Inference:** the platform does not raise it twice for one
  session; if it does (a client resource swap), duty now survives where it was silently dropped.

---

## 6. Offline tests

`python -m unittest discover -s tests -p "test_compat*.py"`, 2026-10-12: **20 tests OK, 1 expected
failure** (the pre-existing `rp_economy` R1 invariant, B3's). 11 new tests in `tests/test_compat_jobs.py`
over `tests/compat/jobs_scenarios.lua` (new); `fakehost.lua`, `luahost.py` and `contracts.py` unchanged —
every extra fake (SQL interpreter with fault injection and deferred completions, a "late" database mode,
player bags, a subject provider, distances, chat capture) is local to the scenario file.

| Test | Covers |
|---|---|
| `test_eligibility_matrix` | 32 cases: jobs, aliases, lists, duty, grade, society, every refusal token |
| `test_epoch_invalidates_work_on_setjob_duty_and_grade_changes` | duty cycle, grade change, no-op, job change, removal, `setDuty`; event reasons and order |
| `test_epoch_never_repeats_across_seats_disconnects_and_restarts` | `false/unloaded`, seat reuse by another account, restart |
| `test_forged_prompts_grant_nothing` | forged hire (jobless, bad target, out of range), far agency prompt, forged/replayed commits; one legitimate grant |
| `test_persistence_round_trip` | SQL row, crash + restart, duty reset at boot, disconnect, reconnect greeting, removal |
| `test_writes_are_ordered_coalesced_and_retried` | deferred completions, reconnect during a write, unreachable-database retry, no `emp:` key |
| `test_no_kvp_fork_when_the_database_is_configured` | late database: refusals, untouched SQL, late load in the same boot; schema refusal; transient schema retry |
| `test_no_database_lab_store_is_explicit_and_never_leaks_into_sql` | `LabKvpWithoutDatabase` on/off |
| `test_existing_exports_and_events_are_compatible` | the 8 exports and tokens, event order, commands, `jobcheck` |
| `test_public_summary_is_small_and_audience_appropriate` | bag on/off duty, no private keys, refusal, disabled key |
| `test_durable_keys_follow_the_subject_provider_rule` | provider key, provider refusal, default rule, required provider, session/numeric/long keys |
| `test_subject_provider_rule_against_the_final_coordinator` (reconcile) | the same rule against Open77 `697e9e2f`'s `subjectOf`: default, one override, its refusal, key lint |

Also: every changed Lua file compiles under Lua 5.4 (`loadfile`), no BOM, LF in the index.

**What the fake host does not establish:** the real bridge's callback shape for a failed `update`
(assumed `nil, reason` from the API description), real tick ordering of bus events, state-bag replication and
its permission, and anything in game. (`Open77.exports.callSync` to a running coordinator is now exercised
offline, on the coordinator sandbox `tests/compat/txsandbox.lua`.)

---

## 7. Files

| File | Change |
|---|---|
| `rp_jobs/server/main.lua` | store states without fallback, subject provider, ordered writes, work epochs, `eligible`/`workEpoch`/`summary`/`setDuty`, public bag, agency epoch guard, `jobcheck` |
| `rp_jobs/client/main.lua` | client `summary()` export |
| `rp_jobs/shared/config.lua` | `Subject`, `LabKvpWithoutDatabase`, `PublicStateKey` |
| `rp_jobs/open77.lua` | 2.1.0, permission `state.write` |
| `rp_jobs/README.md` | B4 section, persistence, events, bag, log lines, `jobcheck` |
| `tests/compat/jobs_scenarios.lua`, `tests/test_compat_jobs.py` | new |

---

## 8. Integrator test steps (lab, two clients, MariaDB on)

Deploy this branch's `rp_jobs` with the lab database enabled; clients A (id 1) and B (id 2). Re-hash what
runs. Expected log lines are the ones this code prints; none of them has been observed live yet.

1. **Boot.** `[rp_jobs] store=sql table=rp_jobs_employees`, then per player `loaded job=... (sql)` and
   `work epoch=<n> (loaded)`.
2. **Eligibility.** Console `setjob 1 ferrailleur 0` → `job_changed`. `jobcheck 1 ferrailleur 0 duty` →
   `refused off_duty`. A: `/service` → `duty=on job=ferrailleur (player_request)` + `work epoch=E (duty_on)`;
   `jobcheck 1 ferrailleur 0 duty` → `eligible epoch=E`.
3. **Invalidation.** A: `/service` twice → two new epochs; `jobcheck` shows an epoch ≠ E. `setjob 1 ferrailleur 1`
   → `grade_changed`, duty kept. With B5 integrated: start a duty-gated action, clock out mid-progress →
   the operation ends with `stale_job_epoch` and grants nothing.
4. **Foreman path.** From a lab resource: `exports.rp_jobs:setDuty(1, true, { job = "ferrailleur" })` →
   `true, epoch`, chat `Clocked in at Scrapper ...`, log `(export by <resource>)`; for B (jobless) →
   `nil, "no_job"`.
5. **Public summary.** On B's client, `Open77.state.player(1).rp_jobs` → `{ job = "ferrailleur",
   label = "Scrapper", grade = "employee", duty = true }` while A is on duty, `{ duty = false }` after
   `/service`. Check no `permission_denied:state.write` line.
6. **Forged prompt.** Trigger `rp_jobs:hire` from B (jobless) at A → B reads `You have no job, choom...`,
   A's job unchanged.
7. **Persistence.** Restart the server (not only the resource): A comes back `Welcome back ... Scrapper as
   employee`, off duty; `SELECT job, grade, on_duty FROM rp_jobs_employees` → `ferrailleur, 1, 0`.
8. **No KVP fork.** Stop the lab MariaDB, restart `rp_jobs` (or the server): `store=pending after 15 s`;
   A `/service` → `Job records are offline ...`; console `setjob 1 ncpd 0` → `job file is not loaded
   (store_unavailable): nothing changed`; the resource's KVP file holds no `emp:` key. Start MariaDB:
   `store=sql`, `loaded job=ferrailleur grade=1 (sql)` without a restart.
9. Capture the grep-able lines above with the proof's artifact hashes into the research ledger.

---

## 9. Research ledger entry for the integrator

> **2026-10-12 — B4 jobs/duty/grade adapter over `rp_jobs` (rp-examples `wi/b4-jobs`, offline).**
>
> **Built:** `rp_jobs` 2.1.0 adds `eligible(playerId, { job, minGrade, duty, society, epoch })` →
> `true, epoch | nil, reason`, `workEpoch`, `summary`, `setDuty` (foreman clock-in), host event
> `rp_jobs:workEpoch(playerId, epoch | false, reason)`, a public player bag `rp_jobs` (on duty only), a
> client `summary()`, and the restricted diagnostic `jobcheck`. Existing exports, events and commands
> unchanged.
>
> **Facts (offline, B8 fake host, KeraLua `lua54.dll`):** 20 tests OK + 1 pre-existing xfail. The work epoch
> moves on every job, grade and duty change and on every load; a capture before any change is refused with
> `stale_job_epoch`; seat reuse and restarts never repeat an epoch. Forged hire, far agency prompt and forged
> or replayed commits grant nothing. Three changes during one in-flight write submit 2 statements and SQL ends
> on the last state; an unreachable database is retried until the row lands. Shipped d401b40 on a database
> silent for 15 s forks into KVP and strands the change (`emp:acct-0007 = ncpd|0|...`, SQL job back on the
> next boot); this branch refuses with `store_unavailable`, writes no KVP and loads from SQL when the database
> answers in the same boot. Gap R1 closed for `rp_jobs` employment.
>
> **Inferences (unmeasured):** a failed `Open77.database.update` completes its callback as `nil, reason`
> (API text); `onPlayerReady` is raised once per session; epochs cannot collide across restarts unless a
> generation makes more changes than there are milliseconds between its start and the next one.
>
> **Open:** set `RpJobsConfig.Subject.required = true` once a character override provider exists; move
> `seeded:<job>` to SQL with B3; fix `rp_medic`'s legacy job names (consumer, B8 §5.4).
>
> **Not done:** no live run. Proof steps: `docs/world-interaction/b4-jobs.md` §8 (rp-examples).
