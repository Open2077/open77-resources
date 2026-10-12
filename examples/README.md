# examples

Small resources that each show one feature. Read them, copy what you need.

| Resource | What it does | Docs |
|---|---|---|
| [`open77_contextmenu_example`](open77_contextmenu_example/) | Adds three demonstration actions to the ALT context menu so you can see how a resource registers its own entries: "Inspect target", "Inspect myself" and "Use this direction". | [Generic context menu — open77_contextmenu](https://open2077.net/docs/context-menu) |
| [`open77_gizmos_demo`](open77_gizmos_demo/) | A test bench for the client gizmo API: an admin opens move, rotate and scale handles on a virtual point, a spawned chair, their own character, a vehicle, an NPC or a prop, and every gizmo event is printed to the client log. | [Entity gizmos (client Lua)](https://open2077.net/docs/gizmos) |
| [`open77_gizmos_editor`](open77_gizmos_editor/) | A worked example of server-authorized placement with the gizmo API: an operator runs `/gizmo.editor`, drags a test chair into place with on-screen handles, and the server checks the proposed transform before it moves the real prop. | [Entity gizmos (client Lua)](https://open2077.net/docs/gizmos) |
| [`open77_icons_demo`](open77_icons_demo/) | Places four map icons from the [`open77_icons`](../../standalone/open77_icons/) library (fuel, hospital, car and grape) in a row near your character shortly after you enter the world, then changes two of them. | [Custom SVG blips](https://open2077.net/docs/custom-blip-icons) |
| [`open77_loading_screen`](open77_loading_screen/) | Shows a branded overlay with a progress bar ("Loading your destination") over every native loading screen, and hides the game HUD until the load ends. | [Custom loading screens](https://open2077.net/docs/loading-screens) |
| [`open77_pointing`](open77_pointing/) | Lets players point with a finger in the direction their camera faces: hold B, or type `/pointing on` and `/pointing off`. | [Role-play animations](https://open2077.net/docs/rp-animations) |
| [`open77_seat_switch`](open77_seat_switch/) | Adds a `/seats` chat command that moves you to another seat of the car you are in, with the seat-change animation, and turns automatic seat switching on or off for you. | [Changing seats inside a vehicle](https://open2077.net/docs/vehicle-seat-switching) |

Exported from the Open77 platform repository; `EXPORT.json` names the commit.
