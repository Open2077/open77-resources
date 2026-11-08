# open77_appearance

## Temporary activity outfits (server exports)

A server resource can project clothing for an activity without changing the
character's saved equipment or any of their seven wardrobe outfits:

```lua
-- Declare dependency "open77_appearance >=0.2.0" in the calling resource.
local ok, reason = exports.open77_appearance:setTemporaryOutfit(playerId, {
    OuterChest = "Items.Coat_01_basic_01", Head = false,
})
-- On leaving the activity:
exports.open77_appearance:clearTemporaryOutfit(playerId)
```

Slot names are `Head`, `Face`, `InnerChest`, `OuterChest`, `Legs`, `Feet` and
`Outfit`. Values are catalogue item records or `false` to hide a slot; omitted
slots retain the underlying equipment. The active transmog outfit is temporarily
disabled, then restored on release. Underwear slots are not accepted here.
The owner and scoped observers receive the same projected look, including on
late scope entry. These exports require the canonical presentation to be ready.

Each player has at most one temporary owner. Only that resource generation can
replace or clear its outfit; a competing resource receives
`owned_by_other_resource` / `not_owner`. Stopping or reloading the owner releases
its outfit automatically (the generation reconciliation also runs every 500 ms).
Disconnect or character selection retires it. Client equipment/transmog edits
and fitting-room commits are refused while it is held; they never overwrite the
saved look. Releasing an outfit restores the current canonical record, without
writing a captured snapshot back to the database.

Validation: the production-host `TemporaryOutfitTests` cover projection,
restoration of active outfit 0, client-write rejection, owner isolation,
reload/stop, late scope entry and disconnect. Live acceptance is recorded in
`docs/research/aetherfall-arena.md` at the repository root.

This resource lets players create and change their character's look in the game's own character editor, and saves it on the server so it comes back every time they join.
This auto-start resource opens Cyberpunk 2077's native in-game character customization mirror,
captures the resulting logical customization options, validates them on the server, and persists
them per authenticated Open77 GUID and server-owned character key.

- **Docs:** [The join-time readiness gate](https://open2077.net/docs/readiness-gate), [Configure a SQL database](https://open2077.net/docs/database)
- **Starts:** on its own
- **Needs:** nothing
- **Runs on:** server and client

## Commands

- `/appearance [ripperdoc|hairdresser] [male|female]`
- `/appearance male` or `/appearance female` (full-editor shorthand)
- `/barber`
- `/appearance.status` reports body/presentation readiness for the caller's scoped peers, without customization or identity data.
- `/wardrobe` opens the optional [`open77_wardrobe_ui`](../open77_wardrobe_ui/) fitting room (also F2).

## Client exports

```lua
exports.open77_appearance:open("ripperdoc", "female")
local snapshot = exports.open77_appearance:capture()
local revision = exports.open77_appearance:revision()
```

## Server integration

The active RP character defaults to `default`. A server-side gamemode can switch it after its own
authorization and character selection logic:

```lua
TriggerEvent("open77:appearance:setCharacter", playerId, characterGuid)
```

After a successful optimistic-concurrency commit the resource emits:

```lua
AddEventHandler("open77:appearance:saved", function(playerId, userGuid, characterKey, revision, snapshot)
end)
```

The database bridge must be enabled in `server/server.jsonc`. The table is created automatically;
`sql/001_appearance.sql` is also provided for managed migrations. All statements are parameterized,
and appearance edits use one-shot nonces plus revision checks.

Equipment and wardrobe persistence lives in `open77_character_presentation`, created automatically
or through `sql/002_presentation.sql`. Its key is the authenticated user and active RP character.
The menu sends only edited equipment slots, replaced outfit sets and renamed outfits in one
revision-checked transaction. All seven outfits and their names share the same JSON row; legacy
rows without names or revision remain readable. A rejected or failed save retains the previous
committed state. Preview changes are local until Save succeeds.

## It holds the join-time readiness gate

This resource is a **participant** in the platform readiness gate
(`Open77.ready`, see [The join-time readiness gate](https://open2077.net/docs/readiness-gate)).
Every player who connects arrives with one hold in its name, so no other resource may teleport,
spawn or kill them until this one has answered.

- **A returning player**: a saved character is found, the hold is released the moment the lookup
  returns, and nothing waits. This is the overwhelmingly common path and it must stay that way.
- **A new player**: the hold is kept, with reason `character_creation`, while they build a
  character, and heartbeat-refreshed every ten seconds for as long as the creation is genuinely in
  flight. It is released on commit, and within ten seconds of an abort, a rejection or an expiry.
- **Database disabled**: resolves an explicit development default; changes do not persist.
- **Configured database unavailable, corrupt data, or a failed lookup**: reports bootstrap
  failure rather than silently substituting a default character. The shell must complete its
  pristine-world bootstrap before gameplay placement is allowed.

Why it exists: the database bridge is per-server, not per-resource. When a server enables the
database for its own reasons (a ranked ladder, for example), persistence comes on here too and this
resource opens the character creator on join, while a gamemode, told by the same client
announcement, may teleport those players to its lobby. The gate is what makes the two compatible
without either resource knowing the other exists.

### Creator-only options during restore (0.3.2)

The native creator and the in-game mirror expose different option catalogues.
After a successful native restore, verification compares every stored option
that the mirror can still capture. An absent option is not a mismatch, even when
its stored value is nonzero. Every observable value must match, and at least 75%
of all stored options must match; an empty confirmation is rejected.

The original canonical snapshot is retained for body publication. Creator-only
selections are not removed from the saved appearance. The client log reports
`restore verification: matched=... unavailable=... mismatched=... valid=...`
to distinguish missing contextual entries from incorrect restored values.

This fixes the join blocker caused by the head option `0x0731d84e0d92820c`
(`tattoo`) at values 1–6. Deploy resource 0.3.2 on the server and reconnect
affected players; this Lua fix does not require a client DLL rebuild or SQL
migration. Data already deleted by a workaround cannot be reconstructed by it.

### A mismatch no longer locks the player out (0.3.3)

When the restore verification finds values that differ but the mirror did capture the player
(at least one stored option matched), the failure is no longer latched. Before, such a player was
never announced in game and the wardrobe and editor refused to open ("appearance still settling";
18 players in 6 h on LightRP Testing, 2026-11-07). The client now keeps what the game shows, tells
the player to check it in the wardrobe or the editor, and carries on; their next save rewrites the
record. An empty or failed capture (`restore_failed`, `could not be captured`) still latches, since
that is the case where the native mirror may still be open.

## Custom clothing (0.3.0)

Resource-owned `Open77.clothing.register` declarations extend the built-in catalogue. Use a shared script for matching server/client metadata. Unknown client records remain rejected; temporarily unavailable stored mod items are preserved and hidden until their provider returns. See [the custom clothing API](../../../wiki/custom-clothing.md).

## Facial shapes in body replication

`captureBody()` includes `groups[i].morphs`, an array of `{regionHash, targetHash}` pairs alongside mesh `keys`. The resource validates and forwards these selections, including on scope re-entry. Preserve them in custom body relays; older snapshots need a fresh capture to recover missing shapes. See [the body API contract](../../../wiki/appearance-body.md).
