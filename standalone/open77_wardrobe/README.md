# open77_wardrobe

Keeps each player's wardrobe outfits (the game's transmog) in sync with the server, so the outfit you show is the one other players see on you. It stores seven outfits per character and which one is active.

- **Docs:** [Official resource exports](https://open2077.net/docs/resource-exports)
- **Starts:** on its own
- **Needs:** `open77_appearance`
- **Runs on:** client

An active outfit changes how your clothing looks without changing what you have
equipped. The equipped items themselves are handled by
[open77_equipment](../open77_equipment/), and the server record for both lives in
[open77_appearance](../../system/open77_appearance/).

On your own character, the server's record is applied to the game's wardrobe; a
change you make in the game goes up to the server when it differs from that record.
On other players, the record is drawn on their body. Nothing is applied until body
customization has finished, so a fresh character is not dressed half way.

## Use it

Keep `open77_wardrobe` and `open77_appearance` in your server's `resources.load`; it
starts by itself. Players change outfits through the game's wardrobe, or through the
fitting room in [open77_wardrobe_ui](../../system/open77_wardrobe_ui/).

This resource has no general API for creators. Its only exports, `beginPreview()`
and `endPreview()`, are reserved for `open77_wardrobe_ui` and refuse any other caller
with `preview_owner_denied`. While a preview is held, local wardrobe changes are not
sent to the server; ending the preview restores the replicated wardrobe.

If the client lacks the native wardrobe API, the resource prints
`native wardrobe API unavailable; restart Cyberpunk` and does nothing.
