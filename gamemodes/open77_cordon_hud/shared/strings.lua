-- THE string table for the Cordon HUD.
--
-- Plan decision 15: "English, one string table per resource, kinds and counts
-- over the wire." Every player-facing word in this resource lives here and
-- nowhere else -- not in the HTML, not in the CSS, not inline in JavaScript,
-- not in a Lua notice. The three surfaces are handed this table verbatim on
-- `ready` and paint every static label from it through `data-t`; dynamic text
-- asks for `t(path)` or `fmt(path, values)`.
--
-- Conventions:
--   * `{name}` is a placeholder, substituted by `fmt()` on the page side;
--   * a key is NEVER assembled at runtime from a server-sent string. The server
--     sends a KIND (an enum) and a COUNT; this table names it. That is the
--     whole mechanism that keeps display language off the server, and it is
--     what makes the feed's `kind = "cordon"` render as "THE CORDON" here and
--     as something else in a future locale without a server edit.
--
-- The only strings deliberately absent are the ones that are genuinely data:
--   * player names (server-sent, per player);
--   * weapon labels in the inventory strip (a TweakDB record display name,
--     shaped server-side from the loot table);
--   * landmark names on the tac-map (survey data, `map.landmarks[].name`).
--
-- BOTS ARE LABELLED EVERYWHERE. `feed.bot` is ONE key read by the kill feed, by
-- the squad panel, by the tac-map and by the result card, and every one of those
-- call sites is required rather than decorative: plan section 8.1 -- "a player who cannot
-- tell whether they just won against people has been cheated of the only thing
-- the mode sells."

CordonHudStrings = {
    locale = "en",

    brand = "OPEN//77",
    modeName = "CORDON",
    modeKind = "BATTLE ROYALE",

    -- One key per phase the server can send, plus `unknown` for the state
    -- before the first push lands. The page never upper-cases a raw phase
    -- string as a fallback: an unmapped phase renders `unknown`, which is
    -- honest, rather than leaking a server identifier onto the screen.
    phase = {
        staging    = "STAGING",
        deploy     = "DEPLOY",
        live       = "LIVE",
        extraction = "EXTRACTION",
        resolved   = "RESULTS",
        unknown    = "STANDBY",
    },

    format = {
        solo    = "SOLO",
        duo     = "DUO",
        squad   = "SQUAD",
        unknown = "--",
    },

    -- The phase band, MATCH_BAND region.
    band = {
        squads       = "SQUADS",
        players      = "ALIVE",
        kills        = "KILLS",
        clockIdle    = "--:--",
        -- Bots sit beside the alive count rather than inside it. Folding them
        -- into one number would print a figure the server roster never agrees
        -- with, and it would hide the one fact section 8.1 insists the player
        -- is entitled to.
        bots         = "+{count} BOT",
        botsPlural   = "+{count} BOTS",
        -- Every other word about the cordon lives under `cordon` below, beside
        -- the vignette's, so the band and the fast surface cannot drift apart
        -- on what a closure is called.
        damage       = "{dps} HP/S",
    },

    -- The staging panel. Everything the player needs before the drop.
    staging = {
        eyebrow      = "AFTERLIFE LOBBY",
        stepDrop     = "Choose a drop with your squad.",
        stepLoot     = "Find weapons, armor and supplies.",
        stepSurvive  = "Stay in the open blocks. Outlast the rest.",
        title        = "STAGING",
        -- THE SECTOR IS NOT NAMED HERE. It was hardcoded to "Pacifica" and the
        -- mode moved to Watson on 2026-09-02, so the one line a new player reads
        -- to learn the premise told them the wrong city district. The map owns
        -- its own title; this sentence only has to work for any of them.
        lead         = "The sector is sealed. The cordon shuts block by block. Last squad standing gets the extraction.",
        formatLabel  = "FORMAT",
        squadLabel   = "SQUAD",
        squadValue   = "#{id}",
        squadNone    = "--",
        -- THE QUEUE, and there is no ready state to name any more. The old
        -- `readyLabel` / `readyOn` / `readyOff` / `readyKeyHint` asked every
        -- player to confirm something the server never read, and sixty-four
        -- confirmations is not a thing a lobby produces. One decision replaces
        -- them: in this match, or watching it.
        queueLabel   = "IN QUEUE",
        -- Queued of everybody standing in staging, so the number says both how
        -- big the next match is and how many are still only watching.
        queueValue   = "{queued}/{lobby}",
        countdown    = "DROP IN",
        waiting      = "WAITING FOR PLAYERS",
        -- The join control is a KEY, not a button: this surface never takes the
        -- mouse (see the top of client/main.lua), so the label names the key.
        joinOff      = "JOIN BATTLE ROYALE",
        joinOn       = "YOU ARE IN THE NEXT MATCH",
        joinKeyHint  = "PRESS {key} TO JOIN",
        leaveKeyHint = "PRESS {key} TO LEAVE THE QUEUE",
        joinLocked   = "A MATCH IS RUNNING",
        botFill      = "{count} BOTS WILL FILL THE EMPTY SLOTS",
        -- Spectator feed: a player who joined mid-match watches from staging
        -- (plan section 6.1 -- the fallback that needs no platform change, and
        -- the one that is always available).
        watchEyebrow = "MATCH IN PROGRESS",
        watchLead    = "This is the match you are waiting on. The queue opens when it resolves.",
    },

    -- The deploy window: the tac-map is the pin, the panel is the clock.
    deploy = {
        eyebrow   = "DEPLOYMENT",
        title     = "PICK YOUR DROP",
        waitingTitle = "DEPLOYING",
        waitingLead = "Waiting for everyone to arrive. Combat starts together.",
        lead      = "Click the map to pin. Your squad drops on the leader pin unless you set your own.",
        mapHint   = "PRESS {key} FOR THE TACTICAL MAP",
        -- The LABEL first and the block second. "PIN MARKET CENTRE // 1,2" is a
        -- place a squad can call out loud; "PIN 1,2" is a coordinate they have
        -- to look up on the map they were about to close. The block stays
        -- because it is what the cordon closes and what the log records.
        pinnedAt  = "PIN {name} // {block}",
        -- A pin nobody chose. `M.landingFor` assigns one at the drop when the
        -- squad never pinned, and saying "PIN" for it would claim a decision
        -- that was not made.
        pinnedAuto = "DROP ASSIGNED // {name}",
        noPin     = "NO PIN SET",
        clock     = "DROP IN",
    },

    -- The squad panel and the revive prompt.
    squad = {
        title       = "SQUAD",
        you         = "YOU",
        alive       = "UP",
        -- The platform has no downed state (plan decision 4): a "downed"
        -- squadmate is a body inside its revive window. The word says that
        -- rather than borrowing a mechanic this game does not have.
        downed      = "REVIVABLE",
        dead        = "FLATLINED",
        -- The bot badge is `feed.bot`, ONE key for all three call sites (feed,
        -- squad panel, result card) so a bot cannot be labelled in one place
        -- and not another. There is deliberately no second spelling here.
        distance    = "{meters} m",
        distanceFar = "{km} km",
        empty       = "You are on your own in this one.",
        selfDowned  = "DOWNED",
        bleedOut    = "BLEED OUT IN {seconds}s",
        selfWait    = "SELF-REVIVE AVAILABLE IN {seconds}s",
        selfHold    = "HOLD F FOR {seconds}s TO SELF-REVIVE",
        selfReviving = "SELF-REVIVING // KEEP HOLDING F",
        reviving    = "REVIVING // F TO CANCEL",
        revived     = "BEING REVIVED",
        recoveryPending = "WAITING FOR RECOVERY",
    },

    -- The inventory strip: three weapons, plates, heals. GAMEMODE_LOW.
    inventory = {
        plateAction = "ARMOR PLATE",
        healAction = "HEALING ITEM",
        slotEmpty = "EMPTY",
        weapon = "WEAPON",
        ammoNone  = "--",
        plates    = "PLATES",
        heals     = "MAXDOC",
    },

    -- The fast surface.
    combat = {
        applyingPlate = "APPLYING ARMOR PLATE",
        healing = "USING HEALING ITEM",
        useTime = "{seconds}s",
        useFinishing = "FINISHING",
        health = "HP",
        armor  = "AP",
        ammo   = "AMMO",
        reload = "RELOAD",
        empty  = "--",
        shield = "SPAWN SHIELD",
    },

    -- The cordon itself: the vignette banner, the compass, the closure clock.
    cordon = {
        outsideTitle = "OUTSIDE THE CORDON",
        outsideSub   = "NCPD FIRE // {dps} HP/S",
        -- Time to death at the current bleed, from two server numbers (the
        -- health ledger and the phase rate). It is the one figure a bleeding
        -- player actually needs: "2 HP/S" asks for arithmetic, "FLATLINE IN
        -- 14s" does not.
        flatlineIn   = "FLATLINE IN {seconds}s",
        flatlineNow  = "FLATLINING",
        compass      = "NEAREST OPEN BLOCK",
        compassDist  = "{meters} m",
        -- STANDING ON DOOMED GROUND -- one phase before "outside". The
        -- server says this player's cell is announced and not yet closed, when
        -- it closes, and where the nearest cell that survives the phase is.
        -- The strip is the HUD half of the owner's "il faut avancer vers la
        -- prochaine zone": a countdown you can feel and an arrow to follow,
        -- BEFORE the bleed rather than after it.
        moveTitle    = "BOUNDARY ARRIVES IN {seconds}s",
        moveTitleNoClock = "ZONE CLOSING",
        moveNow      = "ZONE CLOSING NOW",
        moveSub      = "THIS BLOCK IS ABOUT TO SEAL",
        moveCompass  = "NEXT ZONE",
        closingIn    = "CORDON CLOSES IN",
        closingNow   = "CORDON CLOSING",
        phase        = "CORDON {index}",
        noneYet      = "NO CORDON YET",
    },

    -- The kill feed. `kind` is the server enum; every word around it is here.
    feed = {
        cordon        = "THE CORDON",
        unknownPlayer = "PLAYER",
        holdout       = "GANG GUARD",
        bot           = "BOT",
        killVerb      = "//",
        cordonVerb    = "BLED OUT",
        squadwipe     = "SQUAD WIPED",
        squadwipeOne  = "SQUAD {id} WIPED",
    },

    -- Transient gamemode notices, centred in the gamemode area (the platform
    -- owns CHROME_TOASTS at middle-left; a gamemode never borrows it).
    notice = {
        cordonWarning = "CORDON CLOSES IN {seconds}s",
        cordonClosing = "THE CORDON IS CLOSING",
        supplyDrop    = "SUPPLY DROP INBOUND",
        squadWiped    = "SQUAD ELIMINATED",
        squadmateDown = "SQUADMATE FLATLINED",
        reviveWindow  = "{seconds}s TO REVIVE",
        botsAdded     = "{count} BOTS ADDED",
        -- The two refusals the join key can produce. A kind with no string here
        -- draws NOTHING, which is exactly how a key that legitimately refused
        -- looks like a key that is broken -- so both are named.
        matchInProgress = "A MATCH IS RUNNING // YOU DROP IN THE NEXT ONE",
        notReady        = "YOUR CHARACTER IS NOT READY YET",
        nightfall     = "NIGHTFALL",
        blackout      = "BLACKOUT",

        -- THE FOURTEEN THAT DREW NOTHING.
        --
        -- Every kind below was already being sent by the server and had no
        -- string here, so it rendered as silence -- which is the failure this
        -- table's own comment warns about six lines above, applied to the two
        -- loops a player spends the whole match inside: picking things up, and
        -- picking people up. Looting gave no feedback at all, and the entire
        -- revive conversation -- I am reviving you, somebody is reviving me, it
        -- was cancelled, it was refused -- was invisible on both sides.
        --
        -- Measured 2026-09-03 by diffing the kinds the server sends against the
        -- keys this table defines: 19 sent, 5 named.

        -- Looting. `pickup` carries a `kind`, and the interesting half is in the
        -- fields, so each kind gets its own line rather than one generic string
        -- that would have to say "you picked up a thing".
        pickup         = "PICKED UP {label}",
        pickupWeapon   = "{label} // SLOT {slot}",
        pickupFailed   = "PICKUP FAILED // TRY AGAIN",
        pickupUncertain = "PICKUP UNCONFIRMED // CHOOSE ANOTHER CRATE",
        pickupAmmo     = "{label}",
        pickupHeal     = "MEDS // {held} HELD",
        pickupPlate    = "PLATE // {held} HELD",
        -- The refusal that looks exactly like a broken key if it is silent: the
        -- crate was too far away when the take was resolved.
        pickupFar      = "TOO FAR",

        -- Consumables. `using` opens the cast, `used` closes it, `useCancelled`
        -- explains why it did not close -- and without the third one an
        -- interrupted plate is indistinguishable from a plate that never
        -- started.
        using          = "{kind} // {seconds}s",
        useRefused     = "CANNOT USE ITEM",
        useRefusedHealth = "HEALTH FULL",
        useRefusedBusy = "ACTION ALREADY IN PROGRESS",
        useRefusedEmpty = "NO ITEMS LEFT",
        used           = "{kind} APPLIED // {held} HELD",
        useCancelled   = "INTERRUPTED",

        -- The revive, from both sides. These four are the conversation between
        -- two players and every one of them was silent.
        reviving       = "REVIVING {target} // {seconds}s",
        beingRevived   = "{by} IS PICKING YOU UP // {seconds}s",
        reviveCancelled = "REVIVE INTERRUPTED",
        reviveRefused  = "CANNOT REVIVE // {reason}",

        -- Armour.
        shieldEquipped = "{label} // {capacity} AP",
        shieldStripped = "{label} STRIPPED // +1 PLATE",
        shieldBroken   = "ARMOR BROKEN",
        noShield       = "NO CARRIER // FIND ARMOR FIRST",
        armorFull      = "ARMOR FULL",
        plateFull      = "PLATES FULL // {held}",

        -- THE DROP PIN, and its three refusals.
        --
        -- Every one of these is here because the absence of a string is what
        -- made the map look dead: `web/match.js` draws NOTHING for a kind this
        -- table does not name, the server sent `pinRefused` with the reason in a
        -- field, and no string named that kind -- so a click into the wrong
        -- phase, a click with no squad and a click on a map with no landing
        -- zones were all indistinguishable from a click that never travelled.
        -- The server now sends one kind per outcome, which is the rule the
        -- queue refusals above already follow.
        dropPin         = "DROP PIN // {label}",
        pinNotDeploying = "DROP PINS ARE SET DURING DEPLOYMENT",
        pinNoSquad      = "YOU ARE NOT IN THIS MATCH",
        pinNoZone       = "THIS MAP HAS NO SURVEYED LANDING ZONES",

        -- Squad events. These have been sent since squads existed and were
        -- heard by nobody until `cordon:squad` was routed into this pipe.
        squadmateLost    = "SQUADMATE ELIMINATED",
        squadmateRevived = "SQUADMATE BACK UP",
    },

    -- The tac-map.
    tacmap = {
        objective = "TACTICAL OVERVIEW",
        actionPin = "CHOOSE YOUR LANDING ZONE",
        actionPing = "MARK A POSITION FOR YOUR SQUAD",
        actionRead = "READ THE SECTOR",
        title         = "TACTICAL OVERLAY",
        eyebrow       = "NCPD // SECTOR GRID",
        legendOpen    = "OPEN",
        legendClosing = "CLOSING",
        legendClosed  = "SEALED",
        legendYou     = "YOU",
        legendSquad   = "SQUAD",
        legendSupply  = "SUPPLY",
        legendPing    = "PING",
        -- The four marks the survey publishes. They were drawn by nothing and
        -- named by nothing until the survey was actually sent; a legend that
        -- lists a mark the map cannot draw is worse than no legend, so these
        -- arrive in the same change as the drawing code.
        legendLanding = "LANDING",
        legendLoot    = "LOOT",
        legendPin     = "DROP PIN",
        legendFinal   = "FINAL BLOCK",
        -- The block under the cursor, written into the footer so the player can
        -- see WHICH cell a click will land in before they commit to it.
        cursor        = "BLOCK {block}",
        cursorNone    = "--",
        hintPin       = "CLICK A BLOCK TO SET YOUR DROP PIN",
        hintPing      = "CLICK THE MAP TO PING YOUR SQUAD",
        hintNone      = "OBSERVING",

        -- ================================================================
        -- THE MAP EDITOR, and why it lives on this surface.
        --
        -- The owner asked for "un editeur du mode ... l'editeur en ui pour les
        -- comptes admin" because the only way to author a point was to walk it,
        -- read /br.where and hand-edit a file under `resources/` -- which the
        -- dev server watches, so every save reloaded the resource set and
        -- emptied a live match.
        --
        -- It is a MODE of the tac-map rather than a fifth surface: this one is
        -- already the schematic grid, already takes the mouse, and
        -- docs/research/battle-royale-and-scale.md measured that three
        -- full-screen surfaces per client cost two clients.
        --
        -- EVERY action here is submitted as the ordinary `/br.map` command
        -- through `open77:command:execute`, which is what the chat box uses.
        -- That is deliberate and it is the security design: `RegisterCommand`'s
        -- third argument is the ONLY permission gate a server resource has --
        -- there is no API for a resource to ask whether a caller is an admin --
        -- so a bespoke net event would have been an unauthenticated way into
        -- the editor for every player. Going through the command path means a
        -- non-admin clicking these buttons is refused exactly as if they had
        -- typed the command.
        editorTitle    = "MAP EDITOR",
        editorEyebrow  = "NCPD // SURVEY AUTHORING",
        editorOpen     = "EDIT",
        editorExit     = "DONE",
        -- The map's own identity and readiness, straight from the server's
        -- `/br.map` report rather than a second opinion computed here.
        editorMap      = "MAP",
        editorSurveyed = "SURVEYED",
        editorProvis   = "PROVISIONAL",
        editorCounts   = "{done}/{want}",
        -- The nine kinds `/br.map` accepts, in its own vocabulary so the button
        -- and the command cannot drift apart.
        kindSpawn      = "SPAWN",
        kindLand       = "LANDING",
        kindLoot       = "LOOT",
        kindVeh        = "VEHICLE",
        kindStage      = "STAGING",
        kindMark       = "LANDMARK",
        kindSupply     = "SUPPLY",
        kindHold       = "HOLDOUT",
        kindExit       = "EXIT",
        -- Two ways to place, and the difference matters: "here" captures the
        -- server's idea of where your body is, which is the only position the
        -- mode trusts; "block" sends the cell you clicked.
        editorHere     = "PLACE HERE",
        editorList     = "LIST",
        editorDelete   = "DELETE",
        editorGround   = "GROUND HERE",
        -- Map-level verbs.
        editorNew      = "NEW MAP",
        editorCopy     = "COPY",
        editorSelect   = "SELECT",
        -- Said once, in the panel, because it is the one thing that surprises
        -- an operator: a vehicle hangs at exactly the height it was created at.
        editorVehHint  = "CARS HANG WHERE PLACED -- STAND ON THE ROAD",
        -- The reply line. The server answers every /br.map verb with one line
        -- and it is the only truth about what happened, so it is shown verbatim
        -- rather than being reinterpreted here.
        editorReply    = "--",
        editorBusy     = "WAIT",
        close         = "CLOSE",
        scale         = "{meters} m",
        -- The tac-map is drawn from survey data and nothing else. It carries no
        -- game map texture, ever: game assets are not redistributable
        -- (plan section 17, "Game map textures are game assets").
        noData        = "NO SURVEY DATA",
        noDataLead    = "The server has not published a block grid yet.",
    },

    -- The result card and the standings under it.
    result = {
        eyebrowWin    = "EXTRACTION AUTHORISED",
        eyebrowLose   = "ELIMINATED",
        victory       = "WINNER",
        placement     = "PLACEMENT",
        placementVal  = "#{placement}",
        kills         = "KILLS",
        survived      = "SURVIVED",
        winnerLabel   = "LAST SQUAD STANDING",
        winnerNone    = "NOBODY MADE IT OUT",
        -- A bot can win (plan section 8.1) and the card says so, through the
        -- same `feed.bot` badge the kill feed and the squad panel use. An
        -- unlabelled bot victory is the mode lying about what the player just
        -- lost to, so the badge is not optional on this card.

        -- ------------------------------------------------------------------
        -- THE ELIMINATION CARD -- the same card, mid-match, for one player.
        --
        -- Owner, 2026-09-03: "quand je meurs si la game tourne tjrs, moi je
        -- devrais voir mon tableau de score direct et me dire que je suis mort
        -- retour lobby, pas attendre la fin de la game." It is the SAME panel
        -- with the same three numbers -- a second card would be a second thing
        -- to keep true -- so only the words that cannot be shared live here.
        --
        -- The eyebrow is `eyebrowLose` and the numbers are `placement`,
        -- `kills` and `survived`, all reused. What is different is that
        -- mid-match there may be NO PLACEMENT yet: a Squad player who bled out
        -- while his squad fights on is out of the match without the squad
        -- having a rank, so the headline cannot be "#5" and must not be blank.
        -- `FLATLINED` is the word the squad panel already uses for exactly that
        -- state, so the two surfaces name it the same way.
        eliminated    = "FLATLINED",
        -- The body is still where it fell; this is the countdown until the mode
        -- stands the player up in the lobby. It is the deadline the elimination
        -- sweep is actually watching, not a second clock.
        lobbyIn       = "RETURNING TO THE LOBBY IN {seconds}s",
        -- Already in the lobby. One line per spectate mode, chosen by the
        -- EFFECTIVE mode the server sends (`result.spectate`) -- which is the
        -- mode after `ghost` has degraded, so this never promises a flight the
        -- server is not giving. `ghost` is unreachable today (no `player.travel`
        -- grant, experiment E4 unrun) and its line exists so the day it lands
        -- costs no string work.
        spectate      = {
            staging = "WATCHING FROM THE LOBBY",
            ghost   = "SPECTATING YOUR SQUAD",
        },
        standings     = "STANDINGS",
        columnPlace   = "#",
        columnPlayer  = "PLAYER",
        columnSquad   = "SQ",
        columnKills   = "K",
        standingsNone = "Standings are published when the match resolves.",
        unrated       = "UNRATED // THIS MATCH CONTAINED BOTS",
    },

    keys = {
        tacmap  = "M",
        join    = "Y",
        close   = "ESC",
        unbound = "--",
    },
}
