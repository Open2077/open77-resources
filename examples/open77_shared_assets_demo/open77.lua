resource "open77_shared_assets_demo"
version "1.0.0"
-- Opt-in example: enable this on a development server to show both panels.
auto_start false
dependency "open77_shared_assets_lib >=1.0.0"
client_script "client.lua"
web_files { "web/**" }
