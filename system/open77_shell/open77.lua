resource "open77_shell"
version "0.1.0"
open77_version ">=0.0.1"
auto_start true
reload_policy "local"

client_script "client/main.lua"
web_ui_page "web/index.html"
web_ui_auto_create false
web_files { "web/**" }
permissions { "webui.system", "network.client" }
