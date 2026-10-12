resource 'open77_loading_screen'
version '1.0.0'
auto_start false
reload_policy 'reconnect'
client_script 'client.lua'
web_ui_page 'web/index.html'
web_ui_auto_create false
files { 'web/index.html' }
permissions { 'screen.read', 'ui.vanilla.hud', 'webui.modal' }
