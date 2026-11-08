-- Example: drive open77_braindance from your own scripts.
--   Console:  bdexample <playerId> server   -- server-driven: hold black, do work, resume
--             bdexample <playerId> client   -- client-driven: the client script runs it
--   Keys:     B (rebindable) starts the client-driven glitch transition
--             N (rebindable) walks the braindance editor layers: visual, thermal, audio, off
resource "open77_braindance_example"
version "1.1.0"
open77_version ">=0.0.1"
auto_start false
dependency "open77_braindance >=1.1.0"

server_script "server/main.lua"
client_script "client/main.lua"

permissions { "network.events", "input.actions" }
