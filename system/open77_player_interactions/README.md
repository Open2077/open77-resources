# open77_player_interactions

This resource presents two-player interactions (giving an item, healing, carrying, escorting): the invited player gets an accept or decline prompt, and both players play matching animations in step once the server starts it. The server owns every interaction; this resource only shows it and sends the players' answers.

- **Docs:** [Player interactions](https://open2077.net/docs/player-interactions)
- **Starts:** on its own
- **Needs:** `open77_animations`
- **Runs on:** server and client

## Use it

Your server resource starts an interaction through the `Open77.playerInteractions` server API. This resource does the rest on each client:

- The invited player reads `Player <id> requests <kind>` in chat and answers with `/interaction accept` or `/interaction decline`. Either player can type `/interaction cancel`; `/interaction` alone shows the current state.
- Kinds are `give`, `heal`, `carry`, `escort` and `custom`. By default `give` plays the `give` animation on both players, and `heal` plays `examine` on the healer and `wounded` on the patient. Set `options.actorAnimation` and `options.targetAnimation` to use other animation profiles.
- If an animation cannot play, the interaction is cancelled and both players are told why.

Client resources can build their own prompt instead of the chat lines:

- Exports: `list`, `get(id)`, `current()`, `isReserved(playerId)`, `accept(id)`, `decline(id)`, `respond(id, accepted)`, `cancel(id)` and `result(requestId)`.
- Local events: `onPlayerInteractionOffered`, `onPlayerInteractionChanged`, `onPlayerInteractionStarted`, `onPlayerInteractionCompleted`, `onPlayerInteractionCancelled`, `onPlayerInteractionResult` and `onPlayerInteractionPresentationFailed`.

Answers are requests, not decisions: the server checks that the sender really is the invited player or a participant before anything changes.
