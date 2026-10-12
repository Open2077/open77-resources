-- THE string table.
--
-- Decision 16 of the Kabuki Arena plan: every player-facing word in this
-- resource lives here and nowhere else -- not in the HTML, not in the CSS,
-- not inline in the JavaScript, not in a Lua notice. The two web surfaces are
-- handed this table verbatim on `ready` and paint every static label from it
-- through `data-t` attributes, so translating the HUD is one edit to one file
-- instead of a search across Lua, HTML and JS.
--
-- Conventions:
--   * `{name}` is a placeholder, substituted by `format()` on either side;
--   * a key is never assembled at runtime from a server-sent string -- the
--     server sends a *kind* (an enum) and this table names it. That is what
--     keeps the server free of display language.
--
-- The only strings deliberately absent are the ones the server sends as data:
--   player names, and the weapon label/category from the shared weapon table.

DeathmatchHudStrings = {
    locale = "en",

    brand = "OPEN//77",
    modeName = "DEATHMATCH",
    modeKind = "FREE FOR ALL",

    -- One key per phase the server can send. `lobby` is the word the gamemode
    -- actually uses for a player who is in no instance -- `waiting` is kept
    -- only because a fragment written before the rename would still resolve.
    -- `buy` and `between` are the arena's; the free-for-all standings interval
    -- reaches this table as `resolved`, normalised in the state push.
    phase = {
        lobby = "LOBBY",
        waiting = "LOBBY",
        countdown = "DEPLOYING",
        buy = "BUY",
        active = "LIVE",
        between = "NEXT ROUND",
        resolved = "RESULTS",
    },

    band = {
        kills = "K",
        deaths = "D",
        ratio = "K/D",
        score = "SCORE",
        instance = "INSTANCE",
        instanceUnknown = "--",
        occupancy = "{current}/{max}",
        -- Bots sit beside the fraction rather than inside it: capacity is a
        -- ceiling on PLAYERS, so folding bots into the numerator would print a
        -- number the kernel would never agree with.
        occupancyBots = "{current}/{max} +{bots}",
        clockIdle = "--:--",
    },

    -- The band's weapon card speaks for whichever loadout mode the server is
    -- running. Under the equalizer it names the one weapon the whole instance
    -- shares; under `/guns` it names what THIS player picked, and calling that
    -- "SHARED WEAPON" would be the card contradicting the game.
    weapon = {
        eyebrow = "SHARED WEAPON",
        eyebrowChoice = "YOUR LOADOUT",
        pending = "STANDBY",
        equalizer = "SAME KIT FOR EVERYONE",
        choice = "YOUR PICK",
    },

    countdown = {
        deploy = "DEPLOY",
        initialising = "INITIALISING",
        getReady = "GET READY",
    },

    protection = {
        eyebrow = "SPAWN PROTECTION",
        short = "PROTECTED",
    },

    combat = {
        health = "HP",
        armor = "AP",
        ammo = "AMMO",
        reserve = "RES",
        empty = "--",
        reloading = "RELOAD",
    },

    -- Multi-kill and streak callouts. `count` is the server's number; the name
    -- is chosen here so the server never ships display language.
    callout = {
        -- String keys on purpose: a sparse integer-keyed Lua table is not an
        -- array, and the JSON codec that carries this to the page would have to
        -- guess. `multi["2"]` is unambiguous on both sides.
        multi = {
            ["2"] = "DOUBLE KILL",
            ["3"] = "TRIPLE KILL",
            ["4"] = "QUAD KILL",
        },
        multiGeneric = "MULTI KILL x{count}",
        streak = {
            ["3"] = "KILLING SPREE",
            ["5"] = "RAMPAGE",
            ["7"] = "UNSTOPPABLE",
            ["10"] = "GODLIKE",
        },
        streakGeneric = "{count} KILL STREAK",
        firstBlood = "FIRST BLOOD",
        revenge = "REVENGE",
        headshot = "HEADSHOT",
        assist = "ASSIST",
        streakEnded = "STREAK ENDED",
        multiSub = "{count} KILLS",
        streakSub = "{count} IN A ROW",
    },

    killfeed = {
        environment = "NIGHT CITY",
        unknownPlayer = "PLAYER",
        bot = "BOT",
        headshot = "HS",
        distance = "{meters} m",
        streak = "x{count}",
        suicide = "SELF",
    },

    -- Decision 2: free-for-all NEVER queues. There is no enrolment, no minimum
    -- and nothing to wait for, so the dock invites a player to drop into a
    -- round that is already running rather than to sign up for a later one.
    -- `enrolled*` / `searching` / `queuePosition` survive because the ARENA
    -- formats do queue, and that dock is the same dock.
    lobby = {
        secureEyebrow = "SECURE ZONE",
        title = "DEATHMATCH LOBBY",
        enrolPrompt = "Drop into a live round.",
        enrolAgainPrompt = "Drop back into a live round.",
        enrolledEyebrow = "ENROLMENT CONFIRMED",
        searching = "LOOKING FOR PLAYERS",
        nextRound = "NEXT ROUND",
        queuePosition = "Position {position} in the queue.",
        enrolled = "You are enrolled.",
        players = "IN COMBAT",
        matchEyebrow = "MATCH #{id}",
        matchSummary = "{count} combatants // {limit} kills to win",
        keycap = "/DM",
    },

    -- The arena surface: 1v1, 2v2 and 3v3.
    --
    -- IT IS A DIFFERENT GAME FROM THE FREE-FOR-ALL AND IT NEEDED ITS OWN WORDS.
    -- Until this block existed `web/match.js` never read `state.arena` at all,
    -- so an elimination match rendered the free-for-all scoreboard -- and the
    -- footer, falling back to a literal default because the arena fragment
    -- carries no `killLimit`, announced "FIRST TO 25 ELIMINATIONS" over a
    -- format that has no kill limit and cannot have one. What an arena is
    -- measured on is ROUNDS, so that is what these say.
    --
    -- `label` and the format keys are the server's (`Config.formats[x].label`
    -- -- Duel, Doubles, Squads); everything here is the language AROUND them.
    arena = {
        round = "ROUND {round}",
        bestOf = "BEST OF {count}",
        -- The round tally's own caption. "FIRST TO 3" beside a 2-1 score is the
        -- whole state of a best-of in four characters.
        target = "FIRST TO {count}",
        alive = "IN",
        eliminated = "OUT",
        you = "YOU",
        disconnected = "GONE",

        -- The buy window. It is the one phase with a deadline the player must
        -- act inside, so it is the one line on this surface that is allowed to
        -- be loud.
        buy = "PICK YOUR KIT",
        buyClock = "{seconds}s",

        -- Sides swap at the halfway point so the end of the map a team drew is
        -- not the reason it won. Before the swap the indicator is a warning;
        -- after it, a statement -- and a player who cannot tell which half they
        -- are on will read a spawn as a bug.
        swapPending = "SIDES SWAP AFTER ROUND {round}",
        swapped = "SIDES SWAPPED",

        -- The standings footer and the panel's LIMIT field, both of which used
        -- to read a kill limit here.
        footerRounds = "BEST OF {bestOf} // FIRST TO {target} ROUNDS",
        limitValue = "{target} ROUNDS",
        matchSummary = "{count} in the round // first to {target} rounds",
        spectating = "ELIMINATED // SPECTATING YOUR TEAM",
    },

    result = {
        eyebrow = "ROUND OVER",
        victory = "VICTORY",
        defeat = "DEFEAT",
        draw = "DRAW",
        winner = "{name} takes the round.",
        noWinner = "No single winner.",
    },

    death = {
        eyebrow = "OPEN//77 // FLATLINED",
        killedBy = "YOU WERE KILLED BY",
        unknownKiller = "NIGHT CITY",
        respawnIn = "RESPAWN IN",
    },

    board = {
        eyebrow = "OPEN77 COMBAT NETWORK",
        title = "STANDINGS",
        titleAccent = "DEATHMATCH",
        columnRank = "#",
        columnPlayer = "PLAYER",
        columnScore = "SCORE",
        columnKills = "K",
        columnDeaths = "D",
        columnRatio = "K/D",
        columnStreak = "STREAK",
        empty = "Standings appear when the round starts.",
        footerLimit = "FIRST TO {limit} ELIMINATIONS",
        footerHold = "HOLD {key} FOR STANDINGS",
        keyBoard = "TAB",
    },

    panel = {
        eyebrow = "NIGHT CITY COMBAT PROTOCOL",
        title = "DEATHMATCH",
        lead = "Everyone against everyone. One weapon, the same odds. The weapon rotates every round.",
        statusLabel = "STATUS",
        -- Was "ENROLLED", against a queue that decision 2 deleted. It counts
        -- the players actually fighting, so it says so.
        enrolledLabel = "IN COMBAT",
        limitLabel = "LIMIT",
        weaponLabel = "WEAPON",
        limitValue = "{limit} KILLS",
        weaponPending = "TO BE ANNOUNCED",
        join = "DEPLOY",
        rejoin = "DEPLOY AGAIN",
        cancel = "CANCEL ENROLMENT",
        leave = "LEAVE MATCH",
        close = "CLOSE",

        -- The arena queue, and the reason it lives on the enrolment panel.
        --
        -- The queue station in the world opens THIS panel (the server answers
        -- `deathmatch:stationQueue` with `deathmatch:panel`), and until these
        -- three buttons existed the panel it opened had no way to pick a size --
        -- so the station could invite a player to queue and then not let them.
        -- Free-for-all is absent from the row on purpose: it never queues
        -- (decision 1), and DEPLOY above is its button.
        queueLabel = "QUEUE FOR AN ARENA",
        queueLead = "Elimination rounds, teams balanced, sides swapped at the halfway point. You wait here only because the format needs a full roster.",
        queueDepth = "{queued} waiting",
        queueSize = "{size}",
        queueUnrated = "First-come, not rated.",

        rulesLabel = "RULES",
        rules = "The lobby is protected and restricted. Damage is live only inside the arena. The best score wins at the kill limit or when time runs out.",
    },

    -- The weapon picker (`/guns`), rebuilt in the `/admin` panel's language.
    --
    -- The WEAPONS are data: their key, their label, their category and their
    -- reserve come from `Config.loadout.primaries` through the server -- one
    -- row of docs/generated/weapons-2.31.csv each -- exactly like the shared
    -- weapon's label above, and are the one thing this table deliberately does
    -- not hold. Every word AROUND them is here. That includes the group
    -- headings, which are the weapon's own `category` field and therefore also
    -- data; `groupOther` is the only one this table names, for a category the
    -- config did not put in its display order.
    --
    -- `applyNext` is the string that carries the mode's one rule about timing:
    -- a weapon never changes in a player's hands mid-firefight, so a pick made
    -- while alive and unprotected waits for the respawn. Saying so is the
    -- difference between a rule and something that looks broken.
    --
    -- `eyebrow`, `lead` and `hint` are gone with the card grid they labelled.
    -- The header now carries the OPEN//77 mark and one title, as the admin
    -- menu does, `trail` is the breadcrumb line under it, and the key hints
    -- moved into a mono footer built from `foot*` plus `keyClose`.
    guns = {
        title = "YOUR WEAPONS",
        -- The breadcrumb, and it carries the picker's one structural rule:
        -- the player chooses slot 1. The sidearm and the blade stay fixed so
        -- that running the primary dry is not the end of the fight.
        trail = "PRIMARY // SIDEARM AND BLADE STAY FIXED",
        filterHint = "type to filter",
        groupOther = "OTHER",
        carrying = "IN HAND",
        queued = "NEXT SPAWN",
        -- The reserve is on screen because it is the decision: a Grad carries
        -- 60 rounds and a Defender 360, and neither number is guessable from
        -- the name.
        reserve = "{count} rds",
        reserveNone = "--",
        position = "{index} / {total}",
        positionFiltered = "{index} / {shown} of {total}",
        noMatch = "Nothing here matches \"{text}\".",
        applyNow = "Yours immediately.",
        applyNext = "Reaches your hands on your next respawn. Weapons never change mid-fight.",
        applyDeploy = "Yours the moment you drop into a round.",
        equalizer = "This server plays the equalizer: one weapon for everyone, rotating each round. Your pick is kept for if that changes.",
        empty = "No weapons are configured on this server.",
        footMove = "move",
        footSelect = "take",
        footFilter = "filter",
        footClose = "close",
        keyClose = "ESC",
    },

    -- Team ids are integers on the wire; the names live here. Index 1 is team
    -- 1. Team 0 means "no team" and is never named.
    teams = { "ALPHA", "BRAVO", "CHARLIE", "DELTA" },
}
