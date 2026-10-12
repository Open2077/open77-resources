# open77_sound

The bundled audio service: plays **an audio file a resource ships**, in 2D or
in the world, with volume, looping, pitch and distance falloff.

- **Docs:** [Resource audio](https://open2077.net/docs/sound)
- **Starts:** on its own
- **Needs:** nothing
- **Runs on:** client

Full documentation, including the spatial model, the caps, the server twins and
the list of what this system is deliberately **not**, is in
[Resource audio](https://open2077.net/docs/sound).

Other client resources call the `play`, `stop`, `stopAll`, `setVolume`, `setPosition`,
`isPlaying`, `list` and `preload` exports.

## What lives here

| File | Role |
|---|---|
| `open77.lua` | The manifest. Note the two permissions and why each is needed. |
| `client/main.lua` | Policy: ownership, ids, caps, lifetime, the listener feed. No audio. |
| `web/index.html` | An empty document. The surface is never composited. |
| `web/app.js` | The mix: decode, gain, pitch, loop, HRTF panner. No policy. |

The split is deliberate. Lua decides **what** may play and for how long; the page
decides **how it sounds**. Nothing in the page knows what a resource is, and
nothing in Lua touches an audio sample.

## The three things that make it work

1. **The surface is invisible and runs at 1 fps**, the lowest the WebUI host
   allows. Audio is clocked independently of the compositor, so the frame rate
   costs nothing and buys nothing: it is set to the floor because there is
   nothing to draw.
2. **The clip bytes arrive over `page:send` as base64**, not over the network:
   the surface CSP is `connect-src 'none'`, so the page cannot fetch anything,
   and `decodeAudioData` takes an ArrayBuffer and is not subject to CSP at all.
   That is why there is no URL anywhere in `app.js`.
3. **Another resource's file is reached through one permissioned door**,
   `Open77.resource.readPackedFile`, gated by `resources.files.read`, declared
   files only, 1 MiB. A resource's own root and its own surface allowlist make
   every other route impossible.
