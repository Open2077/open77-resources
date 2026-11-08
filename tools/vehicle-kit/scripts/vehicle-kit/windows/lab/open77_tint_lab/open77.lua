-- Open77 window tint lab (vehicle customization, route 2). LAB ONLY: never start it on a
-- public server. Server-side dev path for the T-steps of scripts/vehicle-kit/windows/README.md:
-- spawns the dealer models and sets their tint level through the production native
-- Open77.vehicles.setWindowTint. It ships no file: the glass comes from open77_vehicle_tint
-- (or the T2 pack open77_vehicle_tint_t2), installed beside it. Every command is restricted:
-- grant the lab account command.vtint, command.vtint.car, command.vtint.get, command.vtint.remove.
resource 'open77_tint_lab'
version '0.1.0'
auto_start false
server_script 'server.lua'
permissions { 'world.vehicles', 'world.vehicles.appearance', 'network.events', 'players.life.read' }
