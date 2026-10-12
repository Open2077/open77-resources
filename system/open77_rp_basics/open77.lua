resource "open77_rp_basics"
version "1.0.0"
open77_version ">=0.0.1"

-- Off by default. This kit can hold a player still on another player's say-so,
-- so it starts when an operator asks for it and not because it happens to be on
-- disk. Add it to `resources.load` (or start it from the console) once the ACL
-- grants below exist.
auto_start false

reload_policy "local"

-- The animations are the synchronised RP profiles, not local presentation, so
-- the platform resource that owns them has to be running first.
dependency "open77_animations >=1.0.0"

shared_script "shared/rules.lua"
server_script "server/main.lua"
client_script "client/main.lua"

-- Least privilege, line by line. A sample resource is also a worked example of
-- a manifest audit, so each entry says which call needs it and why nothing
-- wider would do.
permissions {
    -- Server: `Open77.players.setFrozen`. The whole of `cuff`. It rides the
    -- replicated life state, so every observer agrees the body is held, and
    -- `setFrozen(false)` drops only THIS resource's claim -- a jail script
    -- holding the same player keeps holding him.
    "players.life.freeze",

    -- Server: `Open77.players.get(...).alive` and the life half of the gate.
    -- Without it the read comes back with `alive` absent rather than false, and
    -- the gate refuses `target_not_alive` -- which is the right failure, but a
    -- confusing one to debug. Acting on a player who is on the "press any key"
    -- screen crashes his client, so this is a safety permission, not a nicety.
    "players.life.read",

    -- Server: `Open77.players.teleport`, and only for the escort leash. It is
    -- deliberately NOT under `players.life.*`: a move is not a life event and
    -- has a different blast radius, which is exactly why it is its own line.
    "players.teleport",

    -- Server: `Open77.animations.play` / `stop` for the `handsup` profile.
    -- `players.animations.read` is deliberately absent: the kit tracks its own
    -- playback ids and never needs to ask what somebody else started.
    "players.animations.control",

    -- Server: `Open77.weapons.get`, the frisk payload. Read-only; the kit never
    -- assigns, removes or holsters, so none of the write-side weapon
    -- capabilities appear here.
    "player.weapons.read",

    -- Server: `Open77.acl.isAllowed`, which is what stops a griefer cuffing
    -- everyone. An export carries no player identity, so the officer is an
    -- argument and the ACL is the only thing that makes it mean something.
    "acl.read",

    -- Both halves: the server tells one client what its controls should be and
    -- that client answers `open77:rpbasics:sync` after a reload. Ordinary
    -- authenticated net events, nothing more.
    "network.events",

    -- Client: `Open77.input.setActionBlocked` for `Map` and `Hub`. blockAll
    -- leaves vanilla menus reachable on purpose, so these two are taken by name.
    "input.actions",

    -- Client: `Open77.input.blockAll`. A separate permission from
    -- `input.actions` because it is a different blast radius -- it takes the
    -- whole gameplay action stream -- and it deserves its own line in an audit.
    "input.blockAll",
}
