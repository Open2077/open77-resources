-- Compatibility alias: old profiles start the unified Freeroam resource once.
resource "race"
version "1.1.0"
open77_version ">=0.0.1"
auto_start false
dependency "freeroam >=0.6.0"
server_script "compat.lua"
