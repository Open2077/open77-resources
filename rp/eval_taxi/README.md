# eval_taxi

Gives players an NPC taxi: type /taxi and a cab with a visible driver pulls up next to you and drives you to the waypoint on your map. It is also where rp_delamain sends a customer when no player driver is on duty.

- **Docs:** [Networked vehicle AI](https://open2077.net/docs/vehicle-ai)
- **Starts:** on its own
- **Needs:** nothing
- **Runs on:** server and client

## Use it

- Place a waypoint on your map, then type `/taxi`. Type `/taxi cancel` to end the ride.
- The server spawns an Archer Hella 6 m from you, mounts an NPC driver (`Character.NightlifeMaleDriver`) and seats you in the front passenger seat. The cab then drives at 90 km/h.
- The driver greets you, reacts to traffic and says goodbye through voice lines, each one repeated in chat in case the voice is silent.
- Keep the destination close and on a street. The server puts it on the road with `Open77.world.groundZ`; if the cab has not moved 3 m after 12 s, you are told to pick a street under 300 m away and run `/taxi` again.
- You cannot call a cab while you are dead, sitting in another vehicle, or already riding one.
- The ride ends when you arrive, cancel, leave the cab, or disconnect. The cab stays 10 s more, and no cab lives longer than 20 minutes.
- To change the car, the driver or the speed, edit the constants at the top of `server/main.lua`: `TAXI_RECORD`, `DRIVER_RECORD`, `RIDE_SPEED_MPS`, `ARRIVAL_RADIUS_M`, `TAXI_TTL_MS`.
- Every change of the AI state is logged as `[eval_taxi] ai vehicle=... state=... reason=...`.
