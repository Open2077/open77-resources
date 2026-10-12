# open77_appearance

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
