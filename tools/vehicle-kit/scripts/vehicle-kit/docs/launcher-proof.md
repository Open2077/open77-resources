# Launcher delivery proof (plan P3.11)

`scripts/vehicle-kit/prove-launcher-delivery.ps1` proves that a player whose install does not
have the vehicle customization packs gets them through the launcher. The launcher downloads
them from the lab, projects them into the game folder, and ArchiveXL and TweakXL load them.
The proof follows the checklist in [wiki/mods.md, "Verifying that a mod loaded"](../../../wiki/mods.md):
it runs steps 1, 2, 3 and 5. Step 4 (in game) stays manual.

The script runs in PowerShell 7, one phase at a time. Every phase prints what it did. When a
phase refuses, it says why and gives the exact remedy.

```powershell
$proof = '.\scripts\vehicle-kit\prove-launcher-delivery.ps1'
pwsh -ExecutionPolicy Bypass -File $proof -Phase prepare   # read-only; builds the launcher
pwsh -ExecutionPolicy Bypass -File $proof -Phase strip     # game closed
pwsh -ExecutionPolicy Bypass -File $proof -Phase launch    # then accept the consent dialog
pwsh -ExecutionPolicy Bypass -File $proof -Phase verify    # once in the world
pwsh -ExecutionPolicy Bypass -File $proof -Phase restore   # game closed
```

All the state lives in `-WorkDir` (default `%TEMP%\op77-vc-launcher-proof`).

- `prepare.json`: the lab snapshot and the per-file prediction.
- `strip\`: the backup and `strip.json`.
- `launch.json`: the footprint snapshot.
- `runs\<stamp>\`: the isolated launcher store and settings, the stand-in master log, and the
  moved-aside session.

The script finds its inputs from the environment, read from the process first and then from
the user scope, so a shell opened before the variable was set still sees it:

- the game: `-GameDirectory`, or `OP77_GAME_DIR`;
- the launcher repository: `-LauncherRepo`, or `OP77_LAUNCHER_DIR`, or a `launcher` folder
  next to this repository's folder;
- the lab server folder: `-LabRoot`, or `OP77_VC_LAB_DIR`. It is optional: without it, the
  lab's `server.jsonc` auth settings and its log line in step 5 are not checked.

`-ExpectedClientSha256Prefix` makes `prepare` check that the game still holds the lab's feature
client. Without it, `prepare` only prints that client's hash.

`-Packages` picks the packs. The default is the five vehicle packs: stages, body, liveries, rims
and tint, which are 7 files. You can add `open77_vehicle_plates`, `archivexl` or `tweakxl`.
`-Phase selftest` checks the stand-in master, the session seed and the file-in-use probe,
without opening a socket or leaving the work folder.

## Design choices

### How the launcher learns about the lab: Direct Connect

The lab is masterless, and the launcher drops directory rows that point at a loopback or
private address:

- `LauncherController.Directory.cs:30` filters them out through `ServerEndpoint.IsVisibleInDirectory`.
- `LauncherController.Connect.cs:138-144` refuses them with `server_requires_direct_connect`.

So neither a DevOrigin `servers` row nor a local `Open77.Master` row can carry
`127.0.0.1:11855`. Direct Connect is the path the launcher supports for a local server.
`launch` starts the launcher with `open77://connect?endpoint=127.0.0.1:11855`.

For an endpoint that is not in the directory, the launcher reads
`http://<host>:<port+1>/mods/v1/manifest`. That is the lab's own resource HTTP listener
(`DirectServerMods.cs:31-111`, `LauncherController.WorldMods.cs:7-31`). It checks the
manifest's digest, then fetches `blobs/<sha256>` from the same server. **Nothing changes on
the lab.**

DevOrigin is not built, because nothing would read it:

- The development preset skips the mod-stack index (`LauncherController.ModUpdate.cs:31-42`).
- DevOrigin serves only `modstack/*` and the index, never a world's required mods.

`prepare` checks the manifest the same way `DirectServerMods.Parse` does (field rules, the
`url == "blobs/<sha256>"` rule, the recomputed digest). It then downloads every blob and checks
the HTTP status, the size and the SHA-256.

### Keeping the lab's feature client: the development preset

The isolated settings use `"master": "development"`. In that preset the launcher never runs the
mod-stack install or its own self-update (`LauncherController.ModUpdate.cs:31-42`,
`LauncherController.SelfUpdate.cs:45`). The alpha preset would run `ModStackInstaller`
(`LauncherController.ModUpdate.cs:329-353`), which replaces `red4ext/plugins/Open77/Open77.dll`
and sweeps Open77's folders (`ModStack/ModProjector.cs:340-351`, stack layer only).

So no dev seam is needed, and the client is not backed up. `strip` records the hashes of
`Open77.dll`, `RED4ext.dll`, `config.ini`, `winmm.dll` and `version.dll`. `verify` and
`restore` fail loudly if any of them changes.

### What the launcher writes into the game folder on Connect

In the development preset, for a direct world, `LaunchWorldCoreAsync` runs these steps in order.

1. **World files.** `ModProjector.PlanWorld` handles each file of each package
   (`LauncherController.WorldMods.cs:264-321`):
   - A missing file is added.
   - An identical file is "kept in place", with no write.
   - A different file that is not in the journal is a conflict, and the launcher offers a world
     repair.

   World files are written as **copies**, never hard links (`ModStack/ModProjector.cs:398`
   and `:467`). A projected file therefore has one link, and its bytes also sit in the isolated
   store's blobs. The launcher logs one line (`LauncherController.WorldMods.cs:319`):
   `world '<name>': projected N file(s), removed M, kept K in place.` For a direct connect,
   `<name>` is the endpoint.
2. **Script cache.** When the projection is not a no-op, `ScriptCacheRepair.ResetForScriptChange`
   (`LauncherController.WorldMods.cs:308`) removes the generated `r6/cache` redscript artefacts
   (`ModStack/ScriptCacheRepair.cs:14-22`), with a backup in the store. The game rebuilds them
   at boot.
3. **`red4ext/config.ini` is not written.** The isolated store starts with an empty journal, so
   `Red4extIgnorePolicy.PlanWorld` returns no overlay (`ModStack/Red4extIgnoreList.cs:425-441`).
4. **Nothing under `red4ext/plugins/Open77` or `r6/scripts/Open77`.**

The launcher also writes outside the game folder:

- `LaunchReadiness.Prepare` (`LauncherController.Readiness.cs:62`) copies the client's
  `NCMP-Template-*` saves into `Saved Games\CD Projekt Red\Cyberpunk 2077` when they are not
  current. The client does the same at boot.
- It rewrites the session file (`LauncherController.Connect.cs:216`).
- It starts the game with `OP77_CONNECT`, `OP77_CONNECT_MASTER=development` and the world
  digest (`LauncherController.Connect.cs:283-310`).

### Strip and restore

`strip` touches a file only after every selected file passes three checks:

- its hash equals the lab package's;
- `fsutil hardlink list` shows exactly one link;
- it is not a reparse point.

It then backs up each file and re-hashes the backup before removing anything. It also copies the
`r6/cache` artefacts, without removing them.

`restore` puts each file back from its backup. If a backup is missing, it uses the matching
entry of the origin zip, checked by hash. It also restores the timestamps and attributes, then
checks the hash and `links=1` again. If it finds a file with foreign bytes, it moves that file
into `strip\displaced\` and does not delete it.

For the script cache, `restore` only puts back files that are missing. A cache that the game
regenerated for the same script set is left as it is.

### Identity and joining a devLocalAuth lab

Connect needs a launcher session (`LauncherController.Connect.cs:182-187`). The launcher passes
`OP77_CONNECT_MASTER=development`, so the client's `open77_shell` enrolls against
`MASTERS.development`, which is `http://127.0.0.1:8090`. It then reads that master's catalog
before dialling the lab. If nothing answers, the boot connect aborts after four attempts with
`enrollment failed`.

`launch` therefore starts a **stand-in master** on 127.0.0.1:8090: this script with
`-Phase serve-master`, in its own minimized window. It answers only what the launcher and the
client ask for:

| Route | Answer |
|---|---|
| `GET /healthz` | 200, with a `Date` header (the launcher's clock check) |
| `GET /api/v1/servers` | an empty page |
| `POST /api/v1/mods/attest` | `{"results":[]}`: no verdict, so the direct world asks the player |
| `GET /api/v1/builds/manifest` | `[]`: the launcher falls back to its known game builds |
| `GET /api/v1/accounts/game-ownership` | not required, allowed |
| `GET /api/v1/accounts/discord` | not configured |
| `POST /api/v1/accounts/login` | a stand-in account, as a fallback |
| `POST /api/v1/identities/enroll` | `CYIDACK1`, echoing the user id and the name, with a zero certificate and a random master key |
| anything else | 404 |

Connect tickets and the integrity report get a 404. The client treats both as non-fatal
(`networking/src/ClientSession.cpp:528-563`).

The enroll answer is enough for this lab, for three reasons:

- The client stores the certificate without checking it.
- A loopback catalog is exempt from the master-key pin (`networking/src/ClientIdentity.cpp:753-758`).
- The lab's `devLocalAuth` verifier accepts any identity, and the lab does not require connect
  tickets.

The stand-in master logs method, path, status and size. It never logs a header or a body.

If enrollment still fails, the client log shows `enrollment failed reason=...`. The fallback
then does not involve the launcher: the files are already projected, so join from the running
game with `scripts/debug-bridge.ps1 'resource.emit open77:shell:autoconnect 127.0.0.1:11855'`
and an empty master. Steps 1 and 2 already passed by then.

### Isolation and the footprint restore

The launcher's own seams isolate everything they can:

- `OP77_LAUNCHER_SETTINGS`, with consents, worlds and transfer history beside it;
- `OP77_LAUNCHER_MODSTORE`;
- `OP77_LAUNCHER_MASTER_URL`, `_WEBSITE_URL` and `_CDN_URL`, all pointing at the stand-in master;
- `OP77_LAUNCHER_INSTANCE=vcproof`, which gives the launcher its own mutex, pipe and WebView2
  folder;
- `OP77_IDENTITY_PROFILE=vcproof` and `OP77_PLAYER_NAME`.

Settings turn off Discord rich presence and update checks. Everything stays on 127.0.0.1.

Some paths are hard-coded under `%LOCALAPPDATA%\Open77`, and `launch` and `restore` handle each
one:

| Written by the run | Handling |
|---|---|
| `launcher-session-v1.dat` (`LauncherSession.cs:34-38`) | Moved aside first and checked by hash; a stand-in session is seeded (random token, 12 h). `restore` moves the original back byte for byte. |
| `launcher.log` (`LauncherLog.cs:18-25`) | `launch` records its length and the hash of its prefix. `restore` saves the run's lines to `runs\<stamp>\launcher.log.proof-tail.txt` and truncates the log back. If the log rotated, it is left as is. |
| `launcher-webview.vcproof` (`MainForm.cs:144-146`) | Removed if it was new. |
| `identity-vcproof-v1.dat` (written by the client) | Removed if it was new. |
| `HKCU\Software\Classes\open77` (`Program.cs:124-128`, every GUI start) | Recorded, then restored. |
| Any other new item (incidents, diagnostics) | Reported, not deleted. |

## Expected output

`prepare` on 2026-11-06, with launcher `280671c`, game 2.5, and the lab announcing 23 packages
with digest `5b16ab48191f…`:

```text
[  OK  ] manifest v1, 23 mods, digest 5b16ab48191f recomputed and equal
[  OK  ] lightrp_vk_body-assets   0.1.0   200   575578 B sha da3b87a9eb05     (23 such lines)
         files strip will remove (selected packages):
           kept     links=1      69484 B ce7fa4c98a7e r6/tweaks/LightRP/open77-lightrp-stages.yaml
           ...                                         (7 files)
[ INFO ] expected launcher line after strip: world '127.0.0.1:11855': projected 7 file(s), removed 0, kept 62 in place.
[  OK  ] TCP 8090 is free for the stand-in master
```

`verify` after a good run:

```text
== 1. Launcher log at the Connect
[  OK  ] world '127.0.0.1:11855': projected 7, removed 0, kept 62 in place, as predicted
[  OK  ] game pid N launched with OP77_CONNECT=127.0.0.1:11855 OP77_CONNECT_MASTER=development
== 2. Files on disk
[  OK  ] archive/pc/mod/LightRPVehicleKitBody.archive  sha 9e80cde7080e  links=1  store blob ok  journal copy/world
[  OK  ] all 23 package archives are in the isolated store (the store started empty: each one was downloaded)
== 3. Loader logs after the game booted
[  OK  ] red4ext-*.log: ArchiveXL loaded / TweakXL loaded / Open77 loaded
[  OK  ] ... open77-lightrp-stages.yaml -> TweakXL-*.log: Reading "LightRP\open77-lightrp-stages.yaml"
[  OK  ] ... open77_vehicle_tint.archive.xl -> ArchiveXL-*.log: Loading "open77_vehicle_tint.archive.xl"
[  OK  ] ... LightRPVehicleKitRims.archive -> held open by Cyberpunk2077 pid N (inference: ...)
== 5. Server side
[  OK  ] server-*.log: Required mods: 23 declared, digest 5b16ab48191f
[  OK  ] all 23 blob URLs re-checked (200, size, SHA-256); selected ones listed
```

## What the proof covers, and what it does not

It covers:

- a real download from the lab into an empty, isolated store;
- the projection of exactly the stripped files, with their hashes, link counts and journal entries;
- the loader lines for the tweak and `.xl` files;
- the server's own `Required mods` line;
- the launch environment the client receives.

It does not cover:

- **Step 4, in game.** Apply each pack to a car and look at it.
- **Server-side blob hits.** The lab does not log `GET /mods/v1/blobs/...`
  (`server/src/Open77.Server/Resources/ModDownloadService.cs:156-191`). `verify` makes the
  requests again, and the client store shows what was downloaded.
- **A plain `.archive` mount.** REDengine mounts `archive/pc/mod` silently. The Restart Manager
  probe ("held open by the game") is an inference, and "not held" is inconclusive.
- **A real master.** The stand-in master proves the launcher path, not the alpha directory,
  attestation, ownership or ticket flow.
- **Shared state.** Other sessions share the game folder. If someone deploys a client or
  restarts the lab between `prepare` and `verify`, the guarded hashes and the lab digest catch
  it, but the run has to start over.

## Launcher changes that would make the proof cleaner (not made)

- **An `OP77_LAUNCHER_HOME` override**, read wherever `%LOCALAPPDATA%\Open77` is hard-coded:
  `LauncherLog`, `LauncherSession` (and the client's `ReadLauncherAccountToken`), the WebView2
  folder, `PlayerIdentity`, incidents, diagnostics, prerequisites, and the Epic/GOG sign-in
  folders. The proof could then leave the player's folder alone, instead of moving the session
  and truncating the log.
- **Skip `SchemeRegistration.EnsureRegistered` when `OP77_LAUNCHER_INSTANCE` is set.** A test
  instance should not take over `open77://` links.
- **A configurable development master URL in the client.** `open77_shell` hard-codes
  `127.0.0.1:8090`, so the stand-in master cannot move to a free port when a local master is
  running.
