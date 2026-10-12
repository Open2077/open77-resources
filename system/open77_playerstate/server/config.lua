-- open77_playerstate -- configuration and the operator-tunable declaration.
--
-- Every number a server owner might reasonably want to change is here and is
-- declared as a tunable, so it can be moved from the Warden Tuning tab between
-- one player and the next without editing Lua over SSH and without a restart.
-- server/main.lua turns this table into the live proxy with one `declare` call.
--
-- Two things are NOT tunable and are constants at the bottom of this file:
-- anything whose wrong value crashes a client, and anything that only exists to
-- stop a bug becoming a stuck server. Those are not settings, they are
-- invariants, and an operator who could type a number into them would be able
-- to type a number that takes the server down.

Open77PlayerStateConfig = {}

local Config = Open77PlayerStateConfig

-- ---------------------------------------------------------------- tunables --
--
-- Read at the point of use, never hoisted into a file-scope local: `Tune.key`
-- is a call behind a metatable, and a local captured at load freezes forever
-- while the panel goes on reporting the new number.
--
-- Every `apply` here is "live" and that is correct for this resource rather
-- than lazy. `next_round` / `next_match` exist so a change cannot move the
-- finish line under someone already playing; nothing here decides an outcome.
-- The one value that genuinely must not change under a player mid-flight --
-- the restore policy for a join already in progress -- is captured onto that
-- join at its start, in server/restore.lua, which is the `capture()` pattern
-- applied to the one place that needs it.
Config.tunables = {
    -- --------------------------------------------------------- Persistence --
    enabled = {
        value = true, apply = "live",
        label = "Save and restore player state", group = "Persistence", order = 1,
        description =
            "Master switch. Off means this resource records nothing and restores nothing; " ..
            "it does not delete anything already saved, so turning it back on resumes " ..
            "where players left off.",
    },
    autosaveSeconds = {
        value = 60, type = "integer", min = 15, max = 900, step = 5,
        unit = "s", apply = "live",
        label = "Autosave interval", group = "Persistence", order = 2,
        description =
            "How often a moving player's position is written to the database. Saving only " ..
            "on disconnect is lossy in exactly the cases people care about most -- a crash, " ..
            "a power cut, a server that is killed rather than stopped -- so this is what " ..
            "bounds how much anyone can lose. Lower costs more database writes; a player " ..
            "who has not moved is never written whatever this says.",
    },
    minMoveMetres = {
        value = 1.5, min = 0.0, max = 50.0, step = 0.5,
        unit = "m", apply = "live",
        label = "Minimum movement to save", group = "Persistence", order = 3,
        description =
            "A player who has moved less than this since their last write is skipped. " ..
            "This is what makes an idle or AFK server cost nothing. Zero writes every " ..
            "player every interval.",
    },
    expiryHours = {
        value = 336, type = "integer", min = 0, max = 8760, step = 24,
        unit = "h", apply = "live",
        label = "Saved state expires after", group = "Persistence", order = 4,
        description =
            "A saved position older than this is ignored and the player spawns normally. " ..
            "A spot from three weeks ago, on a server whose world or gamemode has moved " ..
            "on since, is often worse than a fresh spawn. Zero disables expiry entirely. " ..
            "The default is two weeks.",
    },

    -- ------------------------------------------------------------ Restoring --
    restoreHealth = {
        value = true, apply = "live",
        label = "Restore health", group = "Restoring", order = 1,
        description =
            "Bring the player back on the health they logged out with, rather than full. " ..
            "Off means they always return at full health at the saved position.",
    },
    restoreArmor = {
        value = true, apply = "live",
        label = "Restore armour", group = "Restoring", order = 2,
        description = "Bring back the armour value the player logged out with.",
    },
    minRestoreHealth = {
        value = 0.15, min = 0.01, max = 1.0, step = 0.05,
        apply = "live",
        label = "Health floor on restore", group = "Restoring", order = 3,
        description =
            "As a fraction of maximum health, the least anyone is ever restored on. " ..
            "Somebody who disconnected on three hit points in the middle of a firefight " ..
            "and returns to die in one shot has been punished for reconnecting. 0.01 is " ..
            "the lowest the engine accepts.",
    },

    -- ------------------------------------------------------------ Ownership --
    --
    -- The spawn-ownership problem, in two knobs. See the long note in
    -- server/main.lua under "who owns spawn" for why it is shaped this way.
    spawnPolicy = {
        value = "auto", choices = { "auto", "always", "never" }, apply = "live",
        label = "When to restore position", group = "Ownership", order = 1,
        description =
            "A gamemode owns where its players spawn. If this resource also places them, " ..
            "two things move the same player and the last one wins. 'auto' stands down " ..
            "whenever one of the resources named below is running. 'never' saves state " ..
            "but never places anybody. 'always' restores regardless -- only correct if " ..
            "you know nothing else on this server places players.",
    },
    spawnOwners = {
        value = "pursuit,race", type = "string", apply = "live",
        label = "Resources that own spawn", group = "Ownership", order = 2,
        description =
            "Comma-separated resource names. Under the 'auto' policy, this resource goes " ..
            "completely inert while any of them is running. Add your gamemode here if it " ..
            "places players on join and cannot be told to stand aside for a returning one. " ..
            "Pursuit and Race are listed because a match must never start a player in last " ..
            "night's position. Freeroam is deliberately NOT listed: it cooperates instead, " ..
            "skipping its own join spawn for a player this resource has restored and keeping " ..
            "it for everyone else.",
    },

    -- -------------------------------------------------------------- Joining --
    readyTimeoutSeconds = {
        value = 45, type = "integer", min = 5, max = 300, step = 5,
        unit = "s", apply = "live",
        label = "Join hold budget", group = "Joining", order = 1,
        description =
            "How long this resource may keep a joining player reserved while it waits for " ..
            "their character to actually exist in the world. This is the budget for the " ..
            "player becoming incarnated, not for the whole join: whenever another resource " ..
            "is still legitimately holding them -- a character creator, say -- the clock is " ..
            "refreshed rather than run down, so a slow character creation never costs " ..
            "anybody their saved position.",
    },
}

-- --------------------------------------------------------------- constants --
--
-- Not tunable, on purpose. Each of these is an invariant rather than a
-- preference, and every one of them has a failure mode an operator should not
-- be able to type their way into.

-- Multi-character support is open77_appearance's, and it tracks the active key
-- in its own VM. Server resources cannot call each other, so there is no way to
-- ask which character a player is currently wearing. Every row this resource
-- writes therefore keys to 'default', exactly as an appearance row does for a
-- player who has never used a second slot. The column exists so the day a
-- character key becomes readable, it can be filled in without a migration
-- against live rows.
Config.characterKey = "default"

-- The heading estimator's cadence. This is a dictionary read per tracked player
-- per second and never touches the database -- see the heading note in
-- server/main.lua for why the estimate exists at all.
Config.headingTickMs = 1000
Config.headingMinMove = 0.35

-- How often the join path re-asks "is this player real yet". Half a second is
-- fast enough that nobody perceives it and slow enough to be free.
Config.joinPollMs = 500

-- An absolute ceiling on one join's wait, independent of every tunable and of
-- every other resource's timeout. Nothing should ever reach it; it exists so a
-- bug in the wait loop costs one player one restore rather than leaking a
-- coroutine per join for the lifetime of the server.
Config.joinCeilingMs = 600000

-- After the respawn transaction is issued the player is mid-fade with no
-- puppet attached, and armour set into that window is lost. These bound the
-- poll that waits for the life phase to come back to `alive` before armour is
-- applied. 20 s is far beyond the observed transaction; reaching it means the
-- respawn did not land, and the code says so rather than setting armour on a
-- player who is not there.
Config.settlePollMs = 250
Config.settleMaxMs = 20000

-- Statements per database transaction is capped at 64 by the bridge. The
-- autosave flush batches its upserts into transactions of this size so one
-- tick costs one round trip per chunk instead of one per player.
Config.flushChunk = 50
