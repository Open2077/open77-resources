resource 'open77_locomotion_aetherfall'
version '1.0.0'
description 'Custom locomotion exported by Gta2CPPuppet Studio'
shared_script 'register.lua'
files { 'package.json', 'graph.locomotion.json' }
preload_mod 'dist/Open77Locomotion_aetherfall_4567af5e1783.zip'
permissions { 'locomotion.register' }

auto_start false
reload_policy 'reconnect'
