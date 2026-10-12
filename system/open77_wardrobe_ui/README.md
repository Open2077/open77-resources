# open77_wardrobe_ui

This resource is the in-game wardrobe: a fitting room where players preview and save worn clothing, star favorite items, and build up to seven named outfits that other players see once saved.

- **Docs:** none yet
- **Starts:** on its own
- **Needs:** `open77_appearance`, `open77_equipment`, `open77_wardrobe`
- **Runs on:** client

It sits on top of [`open77_appearance`](../open77_appearance/) and the standalone
[`open77_equipment`](../../standalone/open77_equipment/) and
[`open77_wardrobe`](../../standalone/open77_wardrobe/) resources.

Open **Freeroam → Player → Wardrobe**, press **F2**, or use **/wardrobe**.
The shortcut can be reassigned in Open77's keybind settings. This resource uses
freeroam's offline design system, drawer/navigation pattern, catalogue cards,
and action buttons; it requires no external fonts, icons or services.

## Player workflow

Choose **Equipment** to change worn clothing, or **Outfits** to edit one of
seven visual overlays. Choose a clothing category and search its compatible
catalogue. Selecting an item previews it on your character. Star items to find
them under Favorites. Up to 256 favorites are remembered on this device for
the same identity and server, across game restarts. Favorites use native KVP
storage, not the PID-scoped browser cache; a storage failure is shown instead
of claiming the star was saved. Native file locking protects simultaneous game
processes; compare-and-set retries also preserve edits to the same identity.

**Save changes** commits all edits together. **Cancel** restores the latest
confirmed look; the cancel button confirms when a draft exists. Escape always
releases focus and discards an unsaved preview, including when the native pause
handler owns the key. Closing while a save is pending cannot retract a save
already accepted by the server.

Outfits can be named, equipped, copied from worn clothing, or reset. **Hide
slot** hides that part of an active outfit; **Use equipment** removes the outfit
override so the worn item shows through. **Show equipment** turns the visual
overlay off. Editing a selected outfit previews it immediately. Underwear is
preserved and is not exposed as a player removal control.

Selecting or removing equipment turns off the outfit overlay in the draft.
Editing a regular clothing slot also removes a covering full-body suit, so the
selected garment can be seen. Saved outfit contents remain available in Outfits;
Save commits these changes together and Cancel restores the confirmed look.

Front/back and rotation buttons use the perspective arbiter and resource-owned
camera orbit. Closing restores the prior requested perspective. Appearance and
barber shortcuts discard uncommitted clothing edits before opening the native
editor, and wait for restored clothing to attach. The preview uses a level view
even when opened from a steep TPS look angle; closing restores gameplay pitch.
The fitting room does not
pause the world and closes on death, vehicle entry, world transition, or ten
minutes without an editing action.

## Authority and persistence

The appearance resource supplies the selected character key, presentation
revision, compatible equipment/outfits and saved outfit names. A save submits
only edited equipment slots, explicitly replaced outfits, changed names and
optional active outfit. Unchanged incompatible-family clothing stays in storage.
Resetting or editing an outfit replaces that outfit's complete slot set.

The server validates the patch and compares revision and character key before
persisting and replicating it. A database failure is shown explicitly; the UI
never claims a save merely because a local preview worked. A conflict restores
the newest server snapshot. A timeout retains the draft for a revision-checked
retry. A server with its database explicitly disabled labels the wardrobe as
session-only.

Preview leases suppress equipment intents, wardrobe intents and body publication.
The appearance lease is acquired first and released last. Cancel restores the
replication resources' newest committed records; the appearance publication
barrier stays up until their visual attachments settle. No preview writes go to
the database or to other players.

The native clothing catalogue is sent to CEF in 64-item batches because Lua
WebUI events have a 1024-value bound. The catalogue streams in a separate
coroutine and yields between batches to respect the per-resume instruction
budget; a cancelled menu generation stops its stream. Empty Lua arrays are normalized into object
maps before browser editing, preserving hide versus inherit through JSON.

## Catalogue coverage

The audited 2.31 base-game and Phantom Liberty sources contain 1,991 clothing
records. Native and server catalogues preserve every record, identity, slot,
family flag and selection flag. The native/server allowlist retains 1,983 records for compatibility. Of those,
164 audited records are unavailable as player clothing: 64 `Items.EmptySlots*`
templates, 89 generic category templates, two quest diving-suit helper
entities, four records with no clothing factory or only a scene prop/loot token, and five
mapped q005/q115 variants that failed controlled player-attachment tests. The menu exposes the remaining 1,819 catalogue records: 1,804 per
body family. Legacy stored identities remain accepted. All 47 other quest/story
records and 504 other expansion records (489 per family) remain reachable.

| Player category | Selectable records per family |
|---|---:|
| Headwear | 261 |
| Eyewear | 153 |
| Tops | 240 |
| Jackets | 626 |
| Bottoms | 293 |
| Footwear | 195 |
| Full body | 36 |

Eight internal test/debug records remain excluded by the shared selection
policy: six `TEST.ItemPass_*Armor` fixtures, `Items.TestClothing`, and
`Items.TightJumpsuit_01_test_01`. These are not missing quest or expansion outfits.
They remain represented in the audited/native/server data rather than being
silently deleted or made available by bypassing validation.

`tests/catalogue.test.cjs` compares every source/native/server entry and verifies
family counts and the absence of query-cap truncation. `tests/catalogue-browser.cjs`
loads the actual menu in Chromium and proves every selectable entry is reachable
through both category pagination and an individual full-record search, for both
families. Coverage proves integration and reachability; native visual correctness
of each asset is a separate in-game validation requirement.

An absent flat `appearanceName` alone does not prove an item is a placeholder.
Five mapped q005/q115 entities had built-in meshes but failed attachment using
both ordinary equipment and engine-created ItemIDs on a prepared player proxy.
The real `Items.q115_thrusters` and all three `Items.Q005_Militech_Suit` variants
remain reachable, as does `Items.q203_samurai_jacket`. The exact classification
records the failure without claiming these five entities have no assets.

The UI uses the native `nonvisual` flag generated from the exact audited
record-ID list. It does not hide clothes merely because they carry an
`EmptySlots` tag. Existing no-appearance records display as an empty slot;
copying worn clothing into an outfit preserves their empty visual meaning.

The browser readiness handshake retries probes and queues an early open request.
The test deliberately drops its first ready event to verify recovery.

## Verification

For an in-game check with two connected players:

1. Open **Freeroam → Player → Wardrobe** or press **F2**. Try an item in each
   category, search by name, change pages, and star a favorite.
2. Watch from the second client: the preview stays private. **Cancel → Discard**
   restores the saved look. Repeat and **Save changes**; the other player sees it.
3. In **Outfits**, name an outfit, copy worn clothing, and try **Hide slot** and
   **Use equipment**. Save, switch outfits, then use **Show equipment**. Repeat
   with outfit seven to cover the last slot.
4. Restart the game and reconnect. Clothing, outfit names, active outfit and
   favorites should return. Repeat the save/observer check in the other direction.
5. Open **Barber** and **Edit appearance** from the wardrobe. Cancel one edit;
   spend more than 90 seconds in another before confirming it, then reconnect
   to check that the accepted appearance persists.
6. Check **Escape**, death/respawn, and vehicle entry/exit. The wardrobe should
   release focus on close and reopen normally once alive and on foot.

`tests/model.test.cjs` (run with `node --test`) checks
cancel isolation, optimistic revision/key, patch omission, protected underwear,
active outfit zero, all seven outfits, reset, and hidden/inherited slot semantics.

`tests/favorites.test.lua` validates identity scope, persisted reconstruction,
server separation, catalogue allowlisting, bounded lists and batched validation.
Run it with Lua 5.4 or later from the repository root.

`tests/browser.cjs` exercises the real HTML/CSS/JavaScript in headless Chromium
with a mocked game bridge and the audited clothing catalogue. It covers searching,
preview, named outfit creation, hide, save payload, timeout, discard confirmation,
and usable save controls at 720p/1080p. Install Playwright in a developer tools
location; `PLAYWRIGHT_MODULE` can select its module and `OP77_TEST_BROWSER` can
select an installed Chromium/Edge executable. Run from the repository root.
This verifies page behavior, not native rendering or network synchronization;
those need the in-game check above.
