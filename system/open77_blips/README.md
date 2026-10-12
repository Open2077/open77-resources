# open77_blips

This resource is the transparent, click-through overlay the platform uses to draw the custom icons other resources give their blips. Players only see the icons, never a window, and no resource ever touches the overlay itself.

- **Docs:** [Custom SVG blips](https://open2077.net/docs/custom-blip-icons), [Vanilla blips and mappins](https://open2077.net/docs/blips)
- **Starts:** on its own
- **Needs:** nothing
- **Runs on:** client

## Use it

You do not call this resource. Leave it running, declare your icon file in your own resource and attach it to a blip through `Open77.blips`. The platform sends the icon and its screen position to this overlay; this resource only draws what it is told.

- The overlay is a system WebUI layer, drawn behind every other interface at 60 fps.
- An icon is 48 px wide when its asset gives no size.
- When a resource removes its blip, or stops, its icons disappear.

Other resources never get a handle to this surface: they declare an asset, and the platform decides which pixels are drawn and where.
