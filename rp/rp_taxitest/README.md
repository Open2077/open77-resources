# rp_taxitest

Console tools that test whether the vehicle AI will drive a car with an NPC driver from where a player stands, and that read the real ground height under a map point. Use them on a test server to find out why a taxi refuses to move, before you change eval_taxi or rp_delamain.

- **Docs:** [Networked vehicle AI](https://open2077.net/docs/vehicle-ai), [World queries: raycast, ground height, objects around the player, entity axes, district](https://open2077.net/docs/world-queries)
- **Starts:** on its own
- **Needs:** nothing
- **Runs on:** server

## Use it

Both commands are registered as restricted: type them in the server console. Never load this resource on a public server.

- `groundz <playerId> <x> <y> [<x> <y> ...]` prints the ground height under each point, as seen by a player within 300 m or by that player. Use it to put zones and points of interest on real ground instead of a guessed height.
- `taxitest near <playerId>` spawns an Archer Hella with an NPC driver 6 m in front of the player and drives it 120 m ahead, with the height read from the ground.
- `taxitest wrongz <playerId>` drives to the same point 30 m above the road, to show what a wrong height does.
- `taxitest mapz <playerId> <x> <y> <z>` drives to the point exactly as given. `taxitest far <playerId> <x> <y>` reads the height first, the way eval_taxi does.
- `taxitest traffic <playerId>` asks the driver to join traffic. `taxitest legs <playerId> <x> <y>` drives there in 200 m legs.
- `nearride`, `trafficride` and `legsride` do the same with the player seated as a passenger.
- `taxitest voice <playerId> [record]` spawns an NPC next to the player and plays a list of voice lines, also echoed in chat.
- `taxitest stop` removes the test car.
- While a car drives, the log prints `[taxitest] t=<seconds> state=<status> reason=<reason> ... moved=<metres>` every second.
