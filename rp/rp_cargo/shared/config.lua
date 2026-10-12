-- rp_cargo configuration. Loaded as a SERVER script (this resource ships nothing to clients).
Config = {}

-- The layouts live in data/layouts.json (read with Open77.io.readJson, permission filesystem.read):
-- one entry per vehicle record, slots in the vehicle frame. See README.md and the lab commands.
Config.layoutsFile = "layouts.json"

-- Physical checks of load / unload (the server's; a prompt or an open tailgate decides nothing).
-- 6 m: a player standing at a tailgate prompt is up to ~5.9 m from a Mackinaw's origin (bed 2.4 m
-- behind it, prompt 1 m past the bed, reached from 2.5 m); 5 m refused them (measured live).
Config.reach = 6.0               -- metres between the player and the vehicle origin
Config.maxVehicleSpeed = 1.0     -- m/s: nobody loads or unloads a moving vehicle

-- One operation per plate at a time; a second one waits at most this long, then answers `busy`.
Config.lockTimeoutMs = 10000

-- The projection sweep: every tracked vehicle in the world with a layout is drawn from the
-- coordinator, every drawn prop is checked against its vehicle. The first scan waits for
-- rp_garage to load its registry.
Config.sweepMs = 15000
Config.startDelayMs = 3000

-- Item id -> prop alias drawn in a slot, for objects moved into a cargo account by another
-- resource without a slot of their own (a load through rp_cargo names its model itself).
-- Curated aliases only: a raw .mesh path cannot be attached (wiki/attachments.md).
Config.models = {
    nomad_crate = "crate.small",
}

-- Model alias -> the height one box of that model takes in a stack (metres). A layout's
-- `stackHeight` is measured with crate.small; a shorter box listed here stacks on the one under it
-- instead of floating above it (measured live: ammo boxes hung a hand's width over the layer below).
Config.stackHeights = {
    ["crate.ammo_box"] = 0.32,
}

-- Model alias -> how far that model's origin sits from a crate.small's when both rest on the same
-- floor (metres; a layout's slot z is measured with crate.small). Measured live 2026-10-13 on a
-- Mackinaw with the tailgate open, standing and crouched: an ammo box rests on the bed floor at slot
-- z 0.5 where crate.small is at 0.9; at 0.9 it hung at the height of the bed rails.
Config.seats = {
    ["crate.ammo_box"] = -0.40,
}

-- Optional allowlist of the resources that may call load / unload (GetInvokingResource()).
-- nil = any server resource (they are trusted code; players never reach these exports).
Config.callers = nil
