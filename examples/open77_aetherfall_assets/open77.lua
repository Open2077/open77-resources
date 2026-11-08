resource 'open77_aetherfall_assets'
version '1.0.0'
description 'Original Aetherfall arena geometry and wand'
auto_start false
reload_policy 'reconnect'
client_script 'register.lua'
files { 'package.json' }
preload_mod 'dist/Open77Aetherfall_2f42aa9b6c88.zip'
permissions { 'props.register' }
