# open77_chat

This resource is the in-game chat: players press T to talk and run slash commands with completion, and other resources post messages and register command suggestions through it.
`open77_chat` is Open77's server-distributed chat resource. It provides an animated WebUI chat
overlay, authenticated messages, slash-command dispatch, completion, and a small client API for
other resources. Its HUD follows the Open77 Design System: the passive feed stays compact in
the top-left corner, while opening chat unfolds the full channel panel and command index. The surface
requests the runtime's maximum 240 fps cadence for uncapped-feeling input and transitions; an idle
page is damage-driven and does not repaint continuously.

If the client WebHost restarts, the chat resource restores its last 48 messages
in order (at most 256 KiB of serialized history). The composer closes and releases
input; press `T` to reopen it after recovery. `chat:clear` and the `clear` export
also clear the retained history. This recovery state belongs to the running Lua
resource and is not retained across resource stops or game restarts.

- **Docs:** [Chat, slash commands, and completion](https://open2077.net/docs/chat)
- **Starts:** on its own
- **Needs:** nothing
- **Runs on:** server and client

## Controls

- `T` opens chat.
- `Enter` submits the current input.
- `Escape` closes chat without sending.
- Arrow keys select a suggestion.
- `Tab` completes the selected suggestion.

The open panel also shows message length, connection state, and a new-message control if the player
has scrolled away from the latest entry. Closing it folds the controls away; recent messages remain
in the passive feed and fade after their configured duration. The passive feed is shorter than the
open list and is always pinned to the newest row.

## Messages and commands

Normal text is sent through `chat:submit` and broadcast by the authoritative server resource. Input
beginning with `/` is tokenized and routed through `open77:command:execute`; it is never broadcast as
a chat message.

```text
/weather.set rain 20
/loot.create.player 1 Items.money 250
/mycommand "one argument" plain\ value
```

The parser supports single quotes, double quotes, escaped spaces, and at most 32 tokens. Restricted
commands require the matching `command.<name>` ACL permission.

`/id` replies privately with the caller's temporary network player ID. This ID changes across
sessions and must not be used as a persistent account identifier.

## Suggestions

Server resources can publish command suggestions after receiving `chat:ready`:

```lua
local suggestions = {
    {
        command = "/garage.open",
        help = "Open a configured garage.",
        parameters = {
            { name = "garageId", help = "Configured garage identifier." },
            { name = "force", optional = true }
        }
    }
}

RegisterNetEvent("chat:ready", function()
    TriggerClientEvent("chat:addSuggestions", source, suggestions)
end)
```

Client resources may also emit `chat:addSuggestion`, `chat:addSuggestions`, and
`chat:removeSuggestion`.

## Client API

```lua
TriggerEvent("chat:addMessage", {
    type = "system",
    author = "GARAGE",
    text = "Your vehicle is ready.",
    color = { 0, 229, 255 }
})

AddEventHandler("chat:commandSubmitted", function(raw, tokens)
    print(raw, tokens[1])
end)
```

Messages accept the following presentation fields in addition to `author`, `text`, `playerId`,
`color`, and `segments`:

| Field | Values | Purpose |
|---|---|---|
| `type` or `kind` | `player`, `system`, `announcement`, `warning`, `error`, `action`, `join`, `leave` | Selects the visual message grammar. `player` is the default chat row. |
| `channel` | `global`, `local`, `squad`, `whisper`, `ooc`, `admin` | Adds channel presentation metadata. Routing remains the sending resource's responsibility. |
| `role` | `admin`, `mod`, or a custom label | Adds a compact role marker beside an author. |
| `mention` | boolean | Highlights a message intended for the local player. |
| `title` | string | Overrides the heading of an announcement. |
| `time` | string | Overrides the client-generated `HH:MM` timestamp. |
| `duration` | milliseconds | Controls how long the passive row remains before fading. |

All fields are optional, and the pre-0.4 message shape remains valid.

Exports:

- `addMessage(message)`
- `clear()`
- `addSuggestion(command, help, parameters?)`
- `removeSuggestion(command)`
- `setEnabled(enabled)`
- `isEnabled()`

## Security

- Source IDs are supplied by the authenticated server session.
- Slash commands cannot bypass the server ACL.
- Messages are sanitized and limited to 256 UTF-8 bytes.
- WebUI content is rendered as text, never injected as HTML.
- Local client events cannot invoke protected server commands.

See the full [chat guide](https://open2077.net/docs/chat) and the repository
[license](../../LICENSE).
