/* The Cordon match surface.
 *
 * Presentation only. Every count, roster entry, placement, block list and clock
 * anchor arrives in the authoritative state push, shaped on the server; the
 * only local calculation is formatting a pushed millisecond value that
 * client/match.lua already counted down.
 *
 * No player-facing word is written in this file. Everything resolves through
 * CordonStrings against shared/strings.lua -- including every phase name, every
 * feed verb and every bot label -- so the server sends kinds and counts and
 * never display text.
 *
 * EVERY FIELD IS OPTIONAL, AND THAT IS THE NORMAL CASE, not a defensive habit.
 * The first push arrives before anything is set; a player watching from staging
 * gets no `cordon`, no `inventory` and no `result`; a solo match has a `squad`
 * with one member. Every reader below either goes through `num()` / `text()` or
 * guards with `typeof`, and the page renders an empty state rather than
 * throwing halfway through a paint -- a JS exception in a CEF surface leaves
 * the HUD frozen on its last frame, which looks exactly like a server hang.
 */
(() => {
  "use strict";

  const $ = id => document.getElementById(id);
  const body = document.body;
  const T = window.CordonStrings;

  /* The honest starting value: before the first push this page knows nothing
   * except that it has not been told it is in a match. */
  let state = { phase: "unknown", participant: false };
  const fragmentSignatures = new Map();
  function fragmentChanged(name, value) {
    const signature = JSON.stringify(value);
    if (fragmentSignatures.get(name) === signature) return false;
    fragmentSignatures.set(name, signature);
    return true;
  }

  /* The phases with no clock running. Anything else has a deadline the server
   * anchored and client/match.lua counts down. */
  const IDLE_PHASES = new Set(["unknown"]);

  function num(value, fallback) {
    const n = Number(value);
    return Number.isFinite(n) ? n : (fallback === undefined ? 0 : fallback);
  }

  function text(value, limit) {
    return String(value === undefined || value === null ? "" : value).slice(0, limit || 32);
  }

  function clock(milliseconds) {
    const total = Math.max(0, Math.ceil(num(milliseconds) / 1000));
    const minutes = Math.floor(total / 60);
    const seconds = total % 60;
    return String(minutes).padStart(2, "0") + ":" + String(seconds).padStart(2, "0");
  }

  /* An unmapped phase renders as `unknown`, never as an upper-cased server
   * identifier: a HUD that prints `EXTRACTION_PENDING` because somebody added a
   * phase is leaking an internal enum onto the player's screen. */
  function phaseLabel(phase) {
    const key = "phase." + String(phase);
    const value = T.t(key, "");
    return value || T.t("phase.unknown");
  }

  function formatLabel(format) {
    const value = T.t("format." + String(format), "");
    return value || T.t("format.unknown");
  }

  /* A name plus, when it is a bot, the badge. ONE helper, used by the feed, the
   * squad list and the standings, so a bot cannot be labelled in one place and
   * not in another. */
  function nameNode(name, isBot, extraClass) {
    const wrap = document.createElement("span");
    wrap.className = "who" + (extraClass ? " " + extraClass : "");
    const label = document.createElement("span");
    label.textContent = text(name) || T.t("feed.unknownPlayer");
    wrap.append(label);
    if (isBot === true) {
      const badge = document.createElement("b");
      badge.className = "bot-tag";
      badge.textContent = T.t("feed.bot");
      wrap.append(badge);
    }
    return wrap;
  }

  /* --------------------------------------------------------------------- */
  /* Band and cordon strip                                                 */
  /* --------------------------------------------------------------------- */

  function renderBand(payload) {
    const phase = text(payload.phase, 16) || "unknown";
    $("phasePill").textContent = phaseLabel(phase);

    /* A phase with no deadline, and a phase whose deadline has not been set
     * yet, are the same thing to the player: there is no number to show. A
     * literal `00:00` sitting in the band is how a HUD tells somebody the match
     * is over when it has not started. */
    const idle = IDLE_PHASES.has(phase) || num(payload.remainingMs) <= 0;
    $("clock").textContent = idle ? T.t("band.clockIdle") : clock(payload.remainingMs);

    const format = text(payload.format, 8);
    /* Solo has one player per squad, so the squad count would print the same
     * number twice. It hides rather than repeating itself. */
    $("squadsBlock").hidden = format === "solo";
    $("aliveSquads").textContent = payload.aliveSquads === undefined
      ? "--" : String(Math.trunc(num(payload.aliveSquads)));
    $("alivePlayers").textContent = payload.alivePlayers === undefined
      ? "--" : String(Math.trunc(num(payload.alivePlayers)));

    const bots = Math.trunc(num(payload.botCount));
    const botEl = $("botCount");
    botEl.hidden = bots <= 0;
    if (bots > 0) {
      botEl.textContent = T.fmt(bots === 1 ? "band.bots" : "band.botsPlural", { count: bots });
    }

    const mine = payload.self && typeof payload.self === "object" ? payload.self : {};
    $("selfKills").textContent = String(Math.trunc(num(mine.kills)));
  }

  function renderCordonStrip(payload) {
    const cordon = payload.cordon && typeof payload.cordon === "object" ? payload.cordon : null;
    const strip = $("cordonStrip");
    if (!cordon) {
      /* No cordon yet is a real, named state -- the first two and a half
       * minutes of every match (plan section 2, the loot window). It says so
       * rather than showing a blank clock. */
      strip.dataset.state = "none";
      $("cordonPhaseLabel").textContent = T.t("cordon.noneYet");
      $("cordonClockLabel").textContent = "";
      $("cordonClock").textContent = "";
      $("cordonDps").textContent = "";
      return;
    }

    /* `closeAtMs` is the contract's name and client/match.lua normalises to it;
     * `closeInMs` is what the gamemode's `C.fragment()` emits today. Both are a
     * REMAINING duration -- there is no shared clock to make an absolute
     * timestamp mean anything -- so both are read. */
    const closeIn = num(cordon.closeAtMs, num(cordon.closeInMs, -1));
    /* A closure window that has begun -- blocks are going out one at a time --
     * reads differently from one that is still counting down. `closing` is the
     * list the server publishes for the window in progress. */
    const closing = Array.isArray(cordon.closing) ? cordon.closing.length : 0;
    strip.dataset.state = closing > 0 ? "closing" : closeIn > 0 ? "pending" : "idle";

    const index = Math.trunc(num(cordon.phaseIndex));
    $("cordonPhaseLabel").textContent = index > 0
      ? T.fmt("cordon.phase", { index }) : T.t("cordon.noneYet");

    if (closing > 0) {
      $("cordonClockLabel").textContent = T.t("cordon.closingNow");
      $("cordonClock").textContent = "";
    } else {
      $("cordonClockLabel").textContent = T.t("cordon.closingIn");
      $("cordonClock").textContent = closeIn >= 0 ? clock(closeIn) : T.t("band.clockIdle");
    }

    const dps = num(cordon.damagePerSecond);
    $("cordonDps").textContent = dps > 0 ? T.fmt("band.damage", { dps: dps.toFixed(0) }) : "";
  }

  /* --------------------------------------------------------------------- */
  /* Squad panel                                                           */
  /* --------------------------------------------------------------------- */

  function memberState(member) {
    if (member.alive === true) return "alive";
    /* `downed` is a body inside its revive window. The platform has no downed
     * state (plan decision 4), so this is "still revivable", and the string
     * table says so rather than borrowing a mechanic this game lacks. */
    if (member.downed === true) return "downed";
    return "dead";
  }

  function renderSquad(payload) {
    if (!fragmentChanged("squad", [payload.squad, payload.self && payload.self.playerId])) return;
    const squad = payload.squad && typeof payload.squad === "object" ? payload.squad : null;
    const members = squad && Array.isArray(squad.members) ? squad.members : [];
    const list = $("squadList");
    list.replaceChildren();

    $("squadId").textContent = squad && squad.id !== undefined
      ? T.fmt("staging.squadValue", { id: Math.trunc(num(squad.id)) }) : "";

    /* Solo, or a squad the server has not shaped yet. Either way there is
     * nothing to list and the panel says so in one line instead of drawing an
     * empty box. */
    $("squadEmpty").hidden = members.length > 1;
    $("squadPanel").dataset.empty = String(members.length <= 1);

    const mine = payload.self && typeof payload.self === "object" ? payload.self : {};

    for (const member of members) {
      if (typeof member !== "object" || member === null) continue;
      const row = document.createElement("li");
      const status = memberState(member);
      row.className = "squad-row is-" + status;

      /* Two accepted ways to say "this row is you": an explicit `self` flag, or
       * a playerId that matches `self.playerId`. Both are optional, and if the
       * server shapes neither the panel simply does not mark a row -- which is
       * a small loss, not a broken render. */
      const isSelf = member.self === true
        || (mine.playerId !== undefined && String(member.playerId) === String(mine.playerId));
      if (isSelf) row.classList.add("self");

      row.append(nameNode(member.name, member.bot === true));

      const bars = document.createElement("div");
      bars.className = "squad-bars";
      const health = document.createElement("i");
      const maxHealth = 100;
      health.className = "squad-health";
      health.style.width = Math.max(0, Math.min(100,
        (num(member.health) / maxHealth) * 100)).toFixed(0) + "%";
      bars.append(health);
      if (num(member.armor) > 0) {
        const armor = document.createElement("i");
        armor.className = "squad-armor";
        /* Armor caps at 75: three plates of 25. */
        armor.style.width = Math.max(0, Math.min(100,
          (num(member.armor) / 75) * 100)).toFixed(0) + "%";
        bars.append(armor);
      }
      row.append(bars);

      const meta = document.createElement("span");
      meta.className = "squad-meta";
      const distance = num(member.distance, -1);
      meta.textContent = status !== "alive"
        ? T.t("squad." + status)
        : isSelf
          ? T.t("squad.you")
          : distance >= 0
          ? (distance >= 1000
            ? T.fmt("squad.distanceFar", { km: (distance / 1000).toFixed(1) })
            : T.fmt("squad.distance", { meters: Math.round(distance) }))
          : T.t("squad.alive");
      row.append(meta);

      list.append(row);
    }
  }

  /* --------------------------------------------------------------------- */
  /* Staging, deploy, result                                               */
  /* --------------------------------------------------------------------- */

  function renderStaging(payload) {
    const staging = payload.staging && typeof payload.staging === "object" ? payload.staging : {};
    const squad = payload.squad && typeof payload.squad === "object" ? payload.squad : null;
    const hud = payload.hud && typeof payload.hud === "object" ? payload.hud : {};

    $("stagingFormat").textContent = formatLabel(payload.format);
    $("stagingSquad").textContent = squad && squad.id !== undefined
      ? T.fmt("staging.squadValue", { id: Math.trunc(num(squad.id)) })
      : T.t("staging.squadNone");

    /* The queue, not a ready ledger. `queued` is how many have asked for the
     * next match and `lobby` how many are standing here; `needed` is the floor
     * the countdown waits for and is the fallback denominator for a payload
     * shaped before `lobby` existed. */
    const queued = Math.trunc(num(staging.queued));
    const lobby = Math.trunc(num(staging.lobby, num(staging.needed)));
    $("stagingQueue").textContent = T.fmt("staging.queueValue", { queued, lobby });

    const countdownMs = num(staging.countdownMs, -1);
    const counting = countdownMs > 0;
    $("stagingCountdown").hidden = !counting;
    $("stagingClock").textContent = counting ? clock(countdownMs) : T.t("band.clockIdle");
    $("stagingWaiting").hidden = counting;

    const bots = Math.trunc(num(payload.botCount));
    $("stagingBotFill").hidden = bots <= 0;
    if (bots > 0) $("stagingBotFill").textContent = T.fmt("staging.botFill", { count: bots });

    /* The join control. There is no ready state to declare any more: the
     * countdown starts the match on its own, and the only thing this asks is
     * whether the player is in that match. `canQueue === false` is the server
     * saying there is no queue to be in right now -- a running match, or a
     * character that has not finished connecting. */
    const canQueue = staging.canQueue !== false && String(payload.phase) === "staging";
    const inQueue = hud.queueIntent === true;
    $("joinRow").dataset.state = !canQueue ? "locked" : inQueue ? "in" : "out";
    $("joinState").textContent = !canQueue ? T.t("staging.joinLocked")
      : inQueue ? T.t("staging.joinOn") : T.t("staging.joinOff");
    $("joinKey").textContent = text(hud.queueKey, 12) || "--";
    $("joinHint").textContent = !canQueue ? ""
      : T.fmt(inQueue ? "staging.leaveKeyHint" : "staging.joinKeyHint",
        { key: text(hud.queueKey, 12) || "--" });

    /* WATCHING, not playing: a mid-match joiner, or somebody who never queued.
     * The counts here are the same authoritative ones as the band's; the block
     * exists because a spectator's band is empty and they need to see the match
     * they are waiting on. `data-watching` on the panel is what collapses the
     * staging half of it -- a countdown and a join key are both about a phase
     * that is not currently happening. */
    const watching = payload.participant !== true
      && String(payload.phase) !== "staging"
      && String(payload.phase) !== "unknown"
      && payload.alivePlayers !== undefined;
    $("stagingWatch").hidden = !watching;
    $("stagingPanel").dataset.watching = String(watching);
    /* COLLAPSE ONCE YOU ARE IN. The owner's words, 2026-09-02: "i dont like
     * this staying on the screen while you wait for a game". Before you join,
     * the panel has a job -- it tells you what this is and how to get in. The
     * moment you are in the queue, every line of it is answered and only the
     * clock still changes, so everything but the clock and the queue count is
     * hidden. Nothing is removed: leaving the queue brings it all back. */
    $("stagingPanel").dataset.joined = String(inQueue === true && !watching);
    if (watching) {
      $("watchSquads").textContent = String(Math.trunc(num(payload.aliveSquads)));
      $("watchPlayers").textContent = String(Math.trunc(num(payload.alivePlayers)));
    }
  }

  function renderDeploy(payload) {
    const hud = payload.hud && typeof payload.hud === "object" ? payload.hud : {};
    const mine = payload.self && typeof payload.self === "object" ? payload.self : {};
    const waiting = mine.state === "deploying";
    $("deployTitle").textContent = T.t(waiting ? "deploy.waitingTitle" : "deploy.title");
    $("deployLead").textContent = T.t(waiting ? "deploy.waitingLead" : "deploy.lead");
    $("deployClock").textContent = clock(payload.remainingMs);
    $("deployMapHint").textContent = T.fmt("deploy.mapHint",
      { key: text(hud.tacmapKey, 12) || "--" });

    /* The pin is the server's: the client sends a world point and the server
     * decides which block that is and whether the squad may drop there.
     *
     * It reads `self.pin`, and until 2026-09-02 NOTHING EVER SENT IT -- the
     * state push carried no `pin` at any level, so this line rendered NO PIN
     * SET for every pin the server accepted, and a click that worked perfectly
     * was indistinguishable from a click that never happened. That is half of
     * the "the map click isn't working" report; the server half is `pinFor` in
     * open77_cordon/server/main.lua. */
    const pin = mine.pin && typeof mine.pin === "object" ? mine.pin : null;
    const fields = pin
      ? { name: text(pin.name, 24) || text(pin.block, 12), block: text(pin.block, 12) || "--" }
      : null;
    /* An assigned drop is not a pin. `M.landingFor` picks one for a squad that
     * never chose, and calling that "PIN" would credit the squad with a
     * decision they did not make -- and hide the fact that they can still
     * change it while the clock runs. */
    $("deployPin").textContent = !pin ? T.t("deploy.noPin")
      : pin.auto === true ? T.fmt("deploy.pinnedAuto", fields)
      : T.fmt("deploy.pinnedAt", fields);
    $("deployPin").dataset.set = String(Boolean(pin));
  }

  function renderResult(payload) {
    const result = payload.result && typeof payload.result === "object" ? payload.result : null;
    /* `resolved` can arrive a tick before the result is shaped, and `extraction`
     * carries none at all until the last squad is decided. The panel is ABSENT
     * in both cases rather than showing a card full of dashes -- a result card
     * is a statement, and an empty one is a statement that is not true yet. */
    $("resultPanel").dataset.ready = String(Boolean(result));

    /* THE ELIMINATION CARD OWNS THE SURFACE WHILE IT IS UP, and this flag is
     * how the staging watch panel gets out of its way.
     *
     * The two land in overlapping slots: `.panel.staging` sits at 25% x and the
     * card is centred at 44vw, and they cross by about 140px at 1080p. That
     * only became possible now, because an eliminated player is BOTH a
     * spectator (`participant: false`, which draws the watch panel) and the
     * owner of a fresh result card, and no state before this one was both.
     *
     * It is a body attribute rather than a `:has()` selector for two reasons:
     * `.staging` comes BEFORE `.result` in the document, so no sibling
     * combinator can reach backwards to it, and `:has()` support in the CEF
     * build this surface runs on is not something this file gets to assume.
     *
     * Set BEFORE the early return, so a card that retires puts the watch panel
     * back on the same push rather than one later. */
    body.dataset.eliminated = String(Boolean(result) && result.final === false);
    if (!result) return;

    const mine = payload.self && typeof payload.self === "object" ? payload.self : {};
    const placement = Math.trunc(num(result.placement, num(mine.placement, 0)));

    /* FINAL, OR THIS PLAYER'S OWN ELIMINATION.
     *
     * The server shapes both through `M.resultFor` and marks the mid-match one
     * `final: false`. The default is TRUE for an older server that sends no
     * such field: a payload with standings and a winner in it is a final card,
     * and treating it as an elimination would hide the winner line. */
    const final = result.final !== false;
    $("resultPanel").dataset.final = String(final);

    /* Only a finished match has a winner, so only a final card can be won. A
     * mid-match `placement === 1` cannot happen -- the squad that takes rank 1
     * is the one still standing, and the moment it is alone the match leaves
     * `live` -- but the guard is cheap and states the rule. */
    const won = final && placement === 1;

    $("resultEyebrow").textContent = T.t(won ? "result.eyebrowWin" : "result.eyebrowLose");
    $("resultPanel").dataset.outcome = won ? "win" : "loss";
    /* The headline, and the third case is the one that is new. A mid-match
     * elimination may have NO placement: a Squad player who bled out while his
     * squad fights on is out of the match before the squad has a rank. An empty
     * hero line there reads as a broken panel, so it says the word the squad
     * list already uses for that state. */
    $("resultTitle").textContent = won
      ? T.t("result.victory")
      : (placement > 0 ? T.fmt("result.placementVal", { placement })
        : (final ? "" : T.t("result.eliminated")));

    /* The winning squad, named, with every bot in it labelled. A bot can win
     * (plan section 8.1) and an unlabelled bot victory is the mode lying about
     * what the player just lost to.
     *
     * THE WHOLE LINE IS ABSENT MID-MATCH. `result.winnerNone` reads "NOBODY MADE
     * IT OUT", which is a statement about a finished match; printing it over a
     * match that is still running -- to a player who has just died and is the
     * one person most likely to believe it -- would be the mode announcing an
     * outcome that has not happened. */
    $("resultWinner").hidden = !final;
    const winners = final && Array.isArray(result.winnerNames) ? result.winnerNames : [];
    if (!final) {
      $("resultWinner").replaceChildren();
    } else if (winners.length === 0) {
      $("resultWinner").textContent = T.t("result.winnerNone");
    } else {
      $("resultWinner").replaceChildren();
      const label = document.createElement("span");
      label.className = "tag";
      label.textContent = T.t("result.winnerLabel");
      $("resultWinner").append(label);
      for (const winner of winners) {
        /* Two accepted shapes, because the server may send a plain string for a
         * solo winner and an object once bots are in: neither is re-derived
         * here, both are read. */
        const isObject = winner !== null && typeof winner === "object";
        const name = isObject ? winner.name : winner;
        const bot = isObject ? winner.bot === true : false;
        $("resultWinner").append(nameNode(name, bot, "winner"));
      }
    }

    $("resultPlacement").textContent = placement > 0
      ? T.fmt("result.placementVal", { placement }) : "--";
    $("resultKills").textContent = String(Math.trunc(num(result.kills, num(mine.kills))));
    $("resultSurvived").textContent = clock(result.survivedMs);

    /* WHAT HAPPENS NEXT, on the elimination card only.
     *
     * Two mutually exclusive answers, both server-shaped: `lobbyInMs` while the
     * body is still lying where it fell, then `watching` once it is standing in
     * the lobby. Nothing is invented here -- the countdown is the SAME deadline
     * the server's elimination sweep is watching, so the number on the card is
     * the number that fires.
     *
     * `Math.ceil` rather than floor: a card reading "0s" for half a second
     * before anything moves reads as a stall. */
    const next = $("resultNext");
    if (final) {
      next.hidden = true;
    } else if (result.watching === true) {
      /* The EFFECTIVE spectate mode, after the server has degraded an
       * unreachable one. The key is composed from it -- the same pattern the
       * notice table uses -- with a real string as the fallback, so an unknown
       * mode prints the honest lobby line rather than a dotted path. */
      const mode = text(result.spectate, 12) || "staging";
      next.textContent = T.t("result.spectate." + mode, T.t("result.spectate.staging"));
      next.hidden = false;
    } else if (result.lobbyInMs !== undefined && result.lobbyInMs !== null) {
      const seconds = Math.max(0, Math.ceil(num(result.lobbyInMs) / 1000));
      next.textContent = T.fmt("result.lobbyIn", { seconds });
      next.hidden = false;
    } else {
      next.hidden = true;
    }

    /* A match containing a bot is never rated (plan section 8.1, enforced at
     * the ladder write). Saying so on the card is what stops a player reading
     * an unchanged rating as a bug.
     *
     * `rated` is the server's own verdict and is the authority when it sends
     * one -- a match can be unrated for reasons other than bots (too few
     * players, `ratedMinPlayers`). The bot count is only the fallback for a
     * payload that has not been shaped to carry it. */
    const rated = payload.rated === undefined
      ? Math.trunc(num(payload.botCount)) <= 0
      : payload.rated !== false;
    $("resultUnrated").hidden = rated;

    renderStandings(result);
  }

  /* How many rows the panel can actually show. `.standings` is capped at
   * `max-height: 32vh` and the rows are ~24px, so about eleven fit at 1080p;
   * ten leaves the header room and never clips a half-row. */
  const STANDINGS_VISIBLE = 10;

  function standingsRow(entry, extraClass) {
    const row = document.createElement("div");
    row.className = "standings-row" + (extraClass ? " " + extraClass : "");
    if (entry.self === true) row.classList.add("self");

    const place = document.createElement("span");
    place.className = "num";
    place.textContent = String(Math.trunc(num(entry.placement)));
    row.append(place, nameNode(entry.name, entry.bot === true));

    const squad = document.createElement("span");
    squad.className = "num";
    squad.textContent = entry.squad === undefined ? "--" : String(Math.trunc(num(entry.squad)));

    const kills = document.createElement("span");
    kills.className = "num";
    kills.textContent = String(Math.trunc(num(entry.kills)));

    row.append(squad, kills);
    return row;
  }

  function renderStandings(result) {
    /* Optional. The contract's `result` carries the local player's own outcome;
     * a full standings table is a bonus the server may or may not shape, and
     * the panel is absent rather than empty when it does not. */
    const rows = Array.isArray(result.standings)
      ? result.standings.filter(entry => typeof entry === "object" && entry !== null)
      : [];
    const container = $("standingsRows");
    container.replaceChildren();
    $("standingsEmpty").hidden = rows.length > 0;
    $("standingsPanel").dataset.empty = String(rows.length === 0);

    /* THE PLAYER'S OWN ROW IS ALWAYS ON SCREEN, and this is a bug fix rather
     * than a nicety.
     *
     * The server sends one row per PARTICIPANT and a match is filled with bots
     * (40 of them at the default), so `standings` is ~41 rows -- into a panel
     * that shows about eleven. The list was rendered whole and left to
     * `overflow-y: auto`, and it is re-rendered on every 500 ms state push, so
     * the scroll position resets before anyone could use it -- and the result
     * card is not a surface the player has a cursor on anyway.
     *
     * The rows are sorted by placement, so what fitted was the winning squad and
     * the next one or two: bots, all of them with a legitimate zero in K. The
     * one row with a real kill count -- the player's -- sat below the fold for
     * anybody who did not finish in the top ten. Reported by the owner on
     * 2026-09-02 as "the K column reads 0 for every row" while their own card
     * read KILLS 8; both readings were true at the same time.
     *
     * So: the top of the table, and then the player, always. The gap row states
     * how many were dropped rather than hiding the fact that a cut happened. */
    const selfIndex = rows.findIndex(entry => entry.self === true);
    const head = selfIndex >= 0 && selfIndex < STANDINGS_VISIBLE
      ? rows.slice(0, STANDINGS_VISIBLE)
      : rows.slice(0, Math.max(0, STANDINGS_VISIBLE - 2));

    for (const entry of head) container.append(standingsRow(entry));

    if (head.length < rows.length) {
      const hidden = rows.length - head.length - (selfIndex >= head.length ? 1 : 0);
      const gap = document.createElement("div");
      gap.className = "standings-row";
      const dots = document.createElement("span");
      dots.className = "num";
      dots.textContent = "..";
      const label = document.createElement("span");
      label.className = "who";
      /* A bare count needs no string table, which keeps this fix inside one
       * file: adding an i18n key would reload the whole HUD resource for a
       * three-character label. */
      label.textContent = "+" + String(Math.max(0, hidden));
      const pad1 = document.createElement("span");
      pad1.className = "num";
      const pad2 = document.createElement("span");
      pad2.className = "num";
      gap.append(dots, label, pad1, pad2);
      container.append(gap);

      if (selfIndex >= head.length) container.append(standingsRow(rows[selfIndex]));
    }
  }

  /* --------------------------------------------------------------------- */
  /* Inventory strip                                                       */
  /* --------------------------------------------------------------------- */

  /* The last kit the strip drew, and the timer that puts it back to rest. `null`
   * means nothing has been drawn yet, which is not the same as an empty kit. */
  let inventorySignature = null;
  let inventoryTimer = 0;

  function renderInventory(payload) {
    const useKeys = payload.hud && payload.hud.useKeys || {};
    if (!fragmentChanged("inventory", { inventory: payload.inventory ?? null, useKeys })) return;
    $("plateUseKey").textContent = text(useKeys.plate, 12) || "--";
    $("healUseKey").textContent = text(useKeys.heal, 12) || "--";
    const inventory = payload.inventory && typeof payload.inventory === "object"
      ? payload.inventory : null;
    const slots = inventory && Array.isArray(inventory.slots) ? inventory.slots : [];
    const container = $("inventorySlots");
    container.replaceChildren();

    /* Always three, always in order, even when the player is carrying one gun.
     * An empty slot is information -- it is a slot ground loot can still fill --
     * and a strip that shrank as weapons were lost would move under the eye at
     * the worst possible moment. */
    for (let index = 1; index <= 3; index += 1) {
      const slot = slots.find(entry => typeof entry === "object" && entry !== null
        && Math.trunc(num(entry.slot)) === index) || null;
      const cell = document.createElement("div");
      cell.className = "slot";
      cell.dataset.filled = String(Boolean(slot));
      cell.dataset.active = String(Boolean(slot && slot.active === true));

      const key = document.createElement("span");
      key.className = "slot-index num";
      key.textContent = String(index);

      const label = document.createElement("span");
      label.className = "slot-label";
      label.textContent = slot ? (text(slot.label, 22) || T.t("inventory.slotEmpty"))
        : T.t("inventory.slotEmpty");

      const ammo = document.createElement("span");
      ammo.className = "slot-ammo num";
      const rounds = slot ? Math.trunc(num(slot.ammo, -1)) : -1;
      ammo.textContent = rounds >= 0 ? String(rounds) : T.t("inventory.ammoNone");

      cell.append(key, label, ammo);
      container.append(cell);
    }

    const plates = inventory ? Math.trunc(num(inventory.plates)) : 0;
    const heals = inventory ? Math.trunc(num(inventory.heals)) : 0;
    $("invPlates").textContent = String(plates);
    $("invHeals").textContent = String(heals);
    $("inventoryStrip").dataset.plates = String(plates > 0);
    $("inventoryStrip").dataset.heals = String(heals > 0);

    /* THE STRIP RESTS AT HALF WEIGHT AND COMES UP WHEN IT CHANGES. A kit that
     * has not changed is furniture; the moment it does -- a pickup, a swap, a
     * plate spent -- is exactly when it is worth looking at, and the change is
     * its own notification. The signature is everything the strip draws, so a
     * push that says nothing new does not flash it.
     *
     * The timer is per-change and restarted, not per-push: at 10 Hz a
     * setTimeout chain would otherwise be ten pending timers a second. */
    const signature = slots.map(entry => (typeof entry === "object" && entry !== null
      ? [Math.trunc(num(entry.slot)), text(entry.label, 22), Math.trunc(num(entry.ammo, -1)),
        entry.active === true ? 1 : 0].join(":")
      : "")).sort().join("|") + "|" + plates + "|" + heals;
    if (signature !== inventorySignature) {
      const first = inventorySignature === null;
      inventorySignature = signature;
      /* The first render is not a change -- it is the strip appearing, and
       * flashing it then would only teach the player to ignore the flash. */
      if (!first) {
        $("inventoryStrip").dataset.recent = "true";
        if (inventoryTimer !== 0) clearTimeout(inventoryTimer);
        inventoryTimer = setTimeout(() => {
          inventoryTimer = 0;
          $("inventoryStrip").dataset.recent = "false";
        }, 2600);
      }
    }
  }

  /* --------------------------------------------------------------------- */
  /* Kill feed                                                             */
  /* --------------------------------------------------------------------- */

  const feedElements = new Map();

  /* The feed arrives as a LIST inside the level push rather than as an edge
   * event, so the page has to work out for itself which entries are new.
   *
   * Entries carry no id, so the key is their CONTENT plus an occurrence ordinal
   * counted from the oldest end. Content alone would silently drop the second
   * of two identical kills (same killer, same victim, same weapon); the array
   * index alone would change for every row on every push, rebuilding the whole
   * feed twice a second and restarting each entry's enter animation.
   *
   * The one imperfection, stated rather than hidden: when an older duplicate
   * falls out of the server's window the ordinals of the remaining duplicates
   * shift by one, so those rows are rebuilt. It costs one re-animation on a row
   * that is already several seconds old, and only for genuinely identical
   * kills. */
  function feedKey(entry, ordinal) {
    return [
      text(entry.kind, 12),
      text(entry.killer, 24),
      text(entry.killerKind, 12),
      text(entry.victim, 24),
      text(entry.weapon, 24),
      ordinal,
    ].join("|");
  }

  function feedRow(entry) {
    const item = document.createElement("div");
    const kind = text(entry.kind, 12) || "kill";
    item.className = "kill kind-" + kind;

    if (kind === "squadwipe") {
      const label = document.createElement("span");
      label.className = "wipe";
      const squad = entry.squad;
      label.textContent = squad === undefined
        ? T.t("feed.squadwipe")
        : T.fmt("feed.squadwipeOne", { id: Math.trunc(num(squad)) });
      item.append(label);
      return item;
    }

    if (kind === "cordon") {
      /* No attacker. The cordon killed them, and the feed says which -- plan
       * section 4: "A cordon kill is credited to the last player who damaged
       * the victim in the previous 10 s, otherwise to the cordon. The feed says
       * which." A `cordon` entry that still carries a killer is the credited
       * case and renders as a normal kill with a cordon verb. */
      if (!text(entry.killer, 24)) {
        const source = document.createElement("span");
        source.className = "who cordon";
        source.textContent = T.t("feed.cordon");
        const verb = document.createElement("span");
        verb.className = "verb";
        verb.textContent = T.t("feed.cordonVerb");
        item.append(source, verb, nameNode(entry.victim, entry.victimBot === true, "victim"));
        return item;
      }
    }

    const holdout = entry.killerKind === "holdout";
    item.append(nameNode(holdout ? T.t("feed.holdout") : entry.killer,
      !holdout && entry.killerBot === true, "killer"));

    const weapon = text(entry.weapon, 24);
    const verb = document.createElement("span");
    verb.className = weapon ? "weapon" : "verb";
    verb.textContent = weapon || T.t("feed.killVerb");
    item.append(verb);

    item.append(nameNode(entry.victim, entry.victimBot === true, "victim"));
    return item;
  }

  function renderFeed(payload) {
    const entries = Array.isArray(payload.feed) ? payload.feed : [];
    const container = $("feed");
    const seen = new Set();
    const ordinals = new Map();

    /* NEWEST FIRST: `feed[0]` is the most recent event. The array is walked in
     * REVERSE -- oldest to newest -- and each unseen entry is PREPENDED, which
     * is what puts two events that arrived in the same push into the right
     * order. Walking forwards and prepending reverses them, which reads as the
     * feed lying about who shot first. */
    for (let index = entries.length - 1; index >= 0; index -= 1) {
      const entry = entries[index];
      if (typeof entry !== "object" || entry === null) continue;
      const base = text(entry.kind, 12) + "|" + text(entry.killer, 24)
        + "|" + text(entry.killerKind, 12) + "|" + text(entry.victim, 24) + "|" + text(entry.weapon, 24);
      const ordinal = (ordinals.get(base) || 0) + 1;
      ordinals.set(base, ordinal);

      const key = feedKey(entry, ordinal);
      seen.add(key);
      if (feedElements.has(key)) continue;
      const row = feedRow(entry);
      feedElements.set(key, row);
      container.prepend(row);
    }

    for (const [key, element] of feedElements) {
      if (seen.has(key)) continue;
      element.remove();
      feedElements.delete(key);
    }

    /* The server decides how long an entry lives -- it drops out of its window
     * -- but a runaway list is still capped here so a burst cannot push the
     * feed down through the vanilla minimap. The OLDEST goes, and with newest
     * first that is the last child. */
    while (container.children.length > 6) container.lastChild.remove();
  }

  /* --------------------------------------------------------------------- */
  /* Notices                                                               */
  /* --------------------------------------------------------------------- */

  function notice(payload) {
    if (!payload || typeof payload !== "object") return;
    const kind = text(payload.kind, 24);
    /* The server sent a KIND and a bag of SUBSTITUTION VALUES, never a sentence.
     * If this table does not name that kind, NOTHING is drawn: a toast reading
     * `notice.somethingNew` would be worse than silence, and unlike a label on a
     * panel it has no surrounding structure to make the mistake legible. A HUD
     * that silently ignores an unknown notice is also what lets the server add
     * one before the string exists without shipping a bug to the player. */
    const bag = payload.fields && typeof payload.fields === "object" ? payload.fields : {};
    const refusals = {health_full: "useRefusedHealth", already_applying: "useRefusedBusy", none_held: "useRefusedEmpty"};
    const noticeKey = kind === "useRefused" ? (refusals[bag.reason] || kind) : kind;
    const message = T.t("notice." + noticeKey, "");
    if (!message) return;

    /* `fields` is the gamemode's shape. Every value is coerced to a string here
     * and none of them is ever used as a KEY -- a server-sent string that chose
     * which line to print would be display language living on the server, which
     * decision 15 forbids. */
    const fields = {};
    for (const [key, value] of Object.entries(bag)) fields[key] = text(value, 48);
    if ((kind === "using" || kind === "used") && (bag.kind === "plate" || bag.kind === "heal")) {
      fields.kind = T.t("inventory." + (bag.kind === "plate" ? "plateAction" : "healAction"));
    }

    const element = document.createElement("div");
    element.className = "notice kind-" + kind;
    element.textContent = T.fmt("notice." + noticeKey, fields);
    $("notices").append(element);
    // One transient instruction fits between the match clock and team/feed.
    // New events replace old ones instead of covering combat with a stack.
    while ($("notices").children.length > 1) $("notices").firstChild.remove();
    setTimeout(() => element.classList.add("leaving"), 4200);
    setTimeout(() => element.remove(), 4700);
  }

  /* --------------------------------------------------------------------- */
  /* Render                                                                */
  /* --------------------------------------------------------------------- */

  function render(payload) {
    if (!payload || typeof payload !== "object") return;
    state = payload;

    const phase = text(payload.phase, 16) || "unknown";
    const mine = payload.self && typeof payload.self === "object" ? payload.self : {};
    body.dataset.phase = phase;
    body.dataset.deploying = String(mine.state === "deploying");
    body.dataset.participant = String(payload.participant === true);
    body.dataset.alive = String(mine.alive !== false);
    body.dataset.action = String(Boolean(mine.downed || mine.revive || mine.use));
    body.dataset.format = text(payload.format, 8) || "unknown";
    body.dataset.outside = String(mine.outside === true);
    body.dataset.doomed = String(mine.doomed === true);
    /* The tac-map dims this surface rather than hiding it: a full-screen map
     * with the phase band still legible through it is one less thing to close. */
    body.dataset.mapOpen = String(payload.hud && payload.hud.tacmapOpen === true);

    renderBand(mine.state === "deploying" ? { ...payload, phase: "deploy", remainingMs: null } : payload);
    renderCordonStrip(payload);
    renderSquad(payload);
    renderStaging(payload);
    renderDeploy(payload);
    renderInventory(payload);
    renderFeed(payload);
    renderResult(payload);
  }

  /* --------------------------------------------------------------------- */
  /* Bridge                                                                */
  /* --------------------------------------------------------------------- */

  Open77.on("cordon:strings", table => {
    T.set(table);
    fragmentSignatures.clear(); // Translation changes must redraw otherwise identical fragments.
    /* Re-run the render so every value formatted from the table -- the clocks,
     * the hints, the feed verbs -- picks up the new language without waiting
     * for the next push. */
    render(state);
  });

  Open77.on("cordon:state", render);
  Open77.on("cordon:notice", notice);

  Open77.ready();
  Open77.emit("cordon:ready", {});
})();
