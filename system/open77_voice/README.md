# open77_voice

This resource turns on in-game voice chat: players talk with push-to-talk (N by default) to everyone nearby, and to the radio, phone and party channels the server lets them speak on.
Reference voice resource for OPEN//77. Audio capture, Opus, jitter buffering,
server SFU routing and spatial playback are native; Lua controls policy and
presentation without ever receiving PCM, Opus payloads or arbitrary recipient
lists.

- **Docs:** [Integrated voice chat](https://open2077.net/docs/voice), [Voice lipsync](https://open2077.net/docs/voice-lipsync)
- **Starts:** on its own
- **Needs:** nothing
- **Runs on:** server and client

The server starts voice at the configured quality and 20 m proximity. The PTT
key defaults to `N`, is configurable in the pause menu, and is persisted per
server. PTT requests `all`, meaning proximity plus every radio/phone/party channel where
the authoritative server granted `CanSpeak`. The frame is encoded once even
when several routes use it.

Proximity is always part of the default `all` transmit intent. The low-level
resource claims no reach-cycle key. Use the server-managed [`open-voice`](../open-voice/)
gameplay package for pma-voice-style whisper/normal/shout cycling and its HUD.
The pause menu only displays canonical reach and cannot change it.

See [Integrated voice chat](https://open2077.net/docs/voice) for the complete client/server API, channel
effects, security model, optional edge-triggered key example, and events.

Channel effects include a lightweight native stereo reverb. Server resources
configure its wet mix, room size, RT60 decay, damping and pre-delay; the values
are authoritative channel metadata and never add media bandwidth.
