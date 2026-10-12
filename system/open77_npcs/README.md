# open77_npcs

This resource adds `npc.*` commands that spawn, move and control server-owned NPCs from the developer console or chat, and it is the reference code for Open77's NPC system.

- **Docs:** [Server-owned NPCs](https://open2077.net/docs/npcs)
- **Starts:** on its own
- **Needs:** nothing
- **Runs on:** server and client

It demonstrates:

- creation, inspection, health and removal on the authoritative server;
- bucket/distance streaming and late-join projection;
- native movement, follow, patrol, wander, facing, look-at, wait and animation tasks;
- task, damage and death events;
- the read-only client snapshot API.

Start the resource and use `npc.create`, `npc.move`, `npc.follow`, `npc.patrol`, `npc.wander`,
`npc.look`, `npc.anim`, `npc.hold`, `npc.freeze`, `npc.damage`, `npc.revive`, `npc.list` and the
other `npc.*` commands from the developer console or chat.

`npc.create <playerId> Character.Judy` accepts a direct record without catalogue registration.
Lua resources should prefer `Open77.npcs.create({record="Character.Judy", position=position})`.
Legacy aliases remain compatible; native record/asset availability is checked on each client.

See [Server-owned NPCs](https://open2077.net/docs/npcs) for the complete public contract.
