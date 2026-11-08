Aetherfall original prop assets — private demonstration

The resource registers five immutable native models with the generic client
Open77.props.registerModel API. Gameplay uses the wand and unit-radius sigil.
Permanent arena architecture is exported separately from NCWE in
resources/assets/maps/open77_aetherfall_world.

Source and cooker:
  scripts/aetherfall/build-arena-models.py (Blender, original geometry)
  scripts/aetherfall/prepare-arena-assets.cjs
  scripts/aetherfall/build-arena-assets.ps1 (WolvenKit, no deployment)

package.json records every native file hash and the validation state. A passed
native round trip does not establish rendering, collision or attachment in the
running game. New archive versions require a full game restart.

Aliases are asset:open77_aetherfall_assets/<model>. Visual hosts are used for
attachments and collision=false. Only floor has a physical host. Keep this
resource as a dependency of any gameplay resource using the aliases.
