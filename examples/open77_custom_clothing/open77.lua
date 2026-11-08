resource "open77_custom_clothing"
version "1.0.0"
auto_start false
shared_script "clothes.lua"
permission "clothing.register"
dependency "open77_appearance >=0.3.0"
dependency "tweakxl >=1.11.4"
preload_mod "dist/open77-custom-clothing.zip"
