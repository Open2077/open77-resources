/* The match surface.
 *
 * Presentation only. Every timer anchor, roster entry, score, instance and
 * team arrives in the authoritative state push; the only local calculation is
 * the ratio, which is division of two pushed integers, and the countdown,
 * which client/match.lua interpolates from a pushed millisecond value.
 *
 * No player-facing word is written in this file. Everything resolves through
 * DMStrings against shared/strings.lua.
 */
(() => {
  "use strict";

  const $ = id => document.getElementById(id);
  const body = document.body;
  const T = window.DMStrings;

  /* "lobby" is the server's word for a player who is in no instance, and it is
   * the honest starting value: before the first push this page knows nothing
   * except that it has not been told it is fighting. `queueCount` and
   * `minimumPlayers` used to live here and were removed with decision 2 --
   * free-for-all never queues and has no minimum, so a dock counting towards
   * one was describing a mode that no longer exists. */
  let state = { phase: "lobby", rows: [] };

  /* What the SERVER last issued this player, from `deathmatch:loadout`. Under
   * `mode = "choice"` there is no round weapon at all -- the server publishes
   * none -- so this is the only truthful source for the band's weapon card.
   * Declared here rather than beside the picker because `render` reads it. */
  let loadout = null;

  /* The phases in which no clock is running. Anything else has a deadline the
   * server anchored and client/match.lua counts down. */
  const IDLE_PHASES = new Set(["lobby", "waiting"]);

  function num(value, fallback) {
    const n = Number(value);
    return Number.isFinite(n) ? n : (fallback === undefined ? 0 : fallback);
  }

  function text(value, limit) {
    return String(value === undefined || value === null ? "" : value).slice(0, limit || 48);
  }

  function clock(milliseconds) {
    const total = Math.max(0, Math.ceil(num(milliseconds) / 1000));
    const minutes = Math.floor(total / 60);
    const seconds = total % 60;
    return String(minutes).padStart(2, "0") + ":" + String(seconds).padStart(2, "0");
  }

  function ratio(kills, deaths) {
    return (num(kills) / Math.max(1, num(deaths))).toFixed(2);
  }

  function phaseLabel(phase) {
    return T.t("phase." + phase, String(phase).toUpperCase());
  }

  function teamClass(team) {
    const id = Math.trunc(num(team));
    return id >= 1 && id <= 4 ? " team-" + id : "";
  }

  function isSelf(id) {
    return String(id) === String(state.playerId);
  }

  /* The local player's own line. `state.self` is the authoritative view when
   * the server sends one; the standings row is the fallback, and is the same
   * numbers by another route. */
  function selfRow() {
    if (state.self && typeof state.self === "object") return state.self;
    const rows = Array.isArray(state.rows) ? state.rows : [];
    return rows.find(row => isSelf(row.id)) || {};
  }

  /* ---------------------------------------------------------------------- */
  /* Standings                                                              */
  /* ---------------------------------------------------------------------- */

  function renderRows() {
    const rows = Array.isArray(state.rows) ? state.rows : [];
    const container = $("rows");
    container.replaceChildren();

    for (const player of rows) {
      const row = document.createElement("div");
      row.className = "row";
      if (isSelf(player.id)) row.classList.add("self");
      if (player.rank === 1) row.classList.add("leader");
      if (player.active === false) row.classList.add("inactive");

      const rank = document.createElement("span");
      rank.textContent = String(player.rank || "-");

      const name = document.createElement("span");
      name.className = "name" + teamClass(player.team);
      const label = document.createElement("span");
      label.textContent = text(player.name) || T.t("killfeed.unknownPlayer");
      name.append(label);
      /* Bots are labelled everywhere they appear -- decision 12 excludes bot
       * rounds from the ladder, and a player has to be able to see which is
       * which without being told. */
      if (player.bot === true) {
        const badge = document.createElement("b");
        badge.className = "bot";
        badge.textContent = T.t("killfeed.bot");
        name.append(badge);
      }

      row.append(rank, name);
      for (const value of [
        num(player.score),
        num(player.kills),
        num(player.deaths),
        ratio(player.kills, player.deaths),
        num(player.streak),
      ]) {
        const cell = document.createElement("span");
        cell.textContent = String(value);
        row.append(cell);
      }
      container.append(row);
    }
    $("emptyRows").classList.toggle("hidden", rows.length > 0);
  }

  /* ---------------------------------------------------------------------- */
  /* Death screen                                                           */
  /* ---------------------------------------------------------------------- */

  function renderDeath(phase, participant) {
    const death = state.death && typeof state.death === "object" ? state.death : {};
    const visible = phase === "active" && participant && state.playerState === "respawning";
    const killer = text(death.killerName, 64).trim();

    $("deathKiller").textContent = killer || T.t("death.unknownKiller");
    $("deathCountdown").textContent = (Math.max(0, num(death.remainingMs)) / 1000).toFixed(1);
    $("deathScreen").classList.toggle("visible", visible);
    $("deathScreen").setAttribute("aria-hidden", String(!visible));
  }

  /* ---------------------------------------------------------------------- */
  /* Arena -- 1v1, 2v2, 3v3                                                 */
  /* ---------------------------------------------------------------------- */

  /* THE FRAGMENT THIS READS HAD NO CONSUMER AT ALL until this block existed.
   * `server/arena.lua` has published `state.arena` since it was written and
   * `render` never looked at it, so an elimination match drew the free-for-all
   * scoreboard -- and `killLimit`, which an arena fragment does not and cannot
   * carry, fell through to this file's own literal default and announced
   * "FIRST TO 25 ELIMINATIONS" over a format decided on ROUNDS.
   *
   * Everything below therefore has one rule behind it: an arena is measured in
   * rounds won and players left standing, and neither of those is a kill count.
   */

  /* `null` for a free-for-all and for the lobby, which is what every branch
   * here keys on. Presence of the object, never the phase or the format
   * string: `phase` is shared with the free-for-all loop and a format string
   * would have to be matched against a list this file would then own. */
  function arenaOf() {
    return state.arena && typeof state.arena === "object" ? state.arena : null;
  }

  function teamName(side) {
    return T.t("teams." + (Math.trunc(num(side)) - 1), String(side));
  }

  /* The three arena sizes, in the order the server declares them. Taken from
   * the queue counts rather than hard-coded, so a server that adds or drops a
   * format needs no edit here -- and sorted, because object key order is not a
   * contract. */
  function arenaSizes() {
    const counts = state.arenaQueue && typeof state.arenaQueue === "object"
      ? state.arenaQueue : {};
    return Object.keys(counts).sort();
  }

  function rosterEntry(member, side) {
    const item = document.createElement("li");
    const mine = isSelf(member.id);
    /* Three states, not two, and the third is why. A player who left the
     * server is neither eliminated nor alive; drawing a disconnect as a kill
     * would be the panel lying about how a round was won. */
    const gone = member.connected === false;
    const out = member.eliminated === true;
    item.className = gone ? "gone" : out ? "out" : "alive";
    if (mine) item.classList.add("mine");

    const name = document.createElement("span");
    name.className = "name";
    name.textContent = mine
      ? T.t("arena.you")
      : (text(member.name, 24) || T.t("killfeed.unknownPlayer"));

    const status = document.createElement("span");
    status.className = "state";
    status.textContent = gone ? T.t("arena.disconnected")
      : out ? T.t("arena.eliminated") : T.t("arena.alive");

    /* The right-hand column is `flex-direction: row-reverse`, so both columns
     * append in the same order and CSS decides which end the state chip sits
     * on. Two append orders would be two things to keep in step. */
    item.append(name, status);
    void side;
    return item;
  }

  function renderRoster(elementId, members, side) {
    const list = $(elementId);
    list.replaceChildren();
    for (const member of Array.isArray(members) ? members : []) {
      list.append(rosterEntry(member, side));
    }
  }

  function renderArena(arena, phase) {
    body.classList.toggle("arena", arena !== null);
    if (arena === null) return;

    const mySide = Math.trunc(num(arena.side, 1));
    const wins = Array.isArray(arena.wins) ? arena.wins : [0, 0];
    const roster = Array.isArray(arena.roster) ? arena.roster : [[], []];
    const target = num(arena.target, 1);
    const round = Math.max(1, num(arena.round, 1));

    /* `label` is the server's word for the format ("Duel"); the format KEY is
     * only ever used as a fallback, so no display language is assembled here
     * from a wire value. */
    $("arenaFormat").textContent =
      text(arena.label, 24).toUpperCase() || text(arena.format, 8).toUpperCase();
    $("arenaRound").textContent = T.fmt("arena.round", { round })
      + " // " + T.fmt("arena.bestOf", { count: num(arena.bestOf, 1) });

    $("arenaNameA").textContent = teamName(1);
    $("arenaNameB").textContent = teamName(2);
    $("arenaWinsA").textContent = String(num(wins[0]));
    $("arenaWinsB").textContent = String(num(wins[1]));
    $("arenaTarget").textContent = T.fmt("arena.target", { count: target });
    $("arenaSideA").classList.toggle("mine", mySide === 1);
    $("arenaSideB").classList.toggle("mine", mySide === 2);

    /* The buy window is hidden rather than blanked outside its own phase: an
     * empty clock reads as a stopped one. */
    const buying = phase === "buy";
    $("arenaBuy").hidden = !buying;
    if (buying) {
      $("arenaBuyClock").textContent = T.fmt("arena.buyClock", {
        seconds: Math.max(0, Math.ceil(num(state.remainingMs) / 1000)),
      });
    }

    /* `swapped` is the server's own predicate -- the same one that chooses the
     * spawn cluster -- so the indicator and the spawns cannot disagree. */
    const swapped = arena.swapped === true;
    $("arenaSwap").classList.toggle("swapped", swapped);
    $("arenaSwap").textContent = swapped
      ? T.t("arena.swapped")
      : T.fmt("arena.swapPending", { round: num(arena.swapAfterRounds, 0) });

    renderRoster("arenaRosterA", roster[0], 1);
    renderRoster("arenaRosterB", roster[1], 2);

    /* Eliminated is a state with no countdown attached: there is no respawn
     * inside an elimination round, which is exactly why the death screen's
     * clock is suppressed for the arena and this line takes its place. */
    $("arenaNote").hidden = arena.eliminated !== true;
  }

  /* The queue row on the enrolment panel: what the world's queue station opens.
   * Each button carries its live depth, because a queue whose length you cannot
   * see is a queue nobody joins. */
  function renderQueue() {
    const counts = state.arenaQueue && typeof state.arenaQueue === "object"
      ? state.arenaQueue : {};
    const sizes = arenaSizes();
    /* Hidden while the player is already in a fight: you cannot queue for an
     * arena from inside one, and the server would refuse with
     * `already_in_instance`. A button that cannot work is worse than none. */
    const offer = sizes.length > 0 && state.participant !== true;
    $("panelQueue").classList.toggle("hidden", !offer);
    if (!offer) return;

    const container = $("queueSizes");
    container.replaceChildren();
    for (const size of sizes) {
      const button = document.createElement("button");
      button.type = "button";
      if (String(state.queueFormat) === size) button.classList.add("queued");

      const label = document.createElement("span");
      label.textContent = T.fmt("panel.queueSize", { size: size.toUpperCase() });
      const depth = document.createElement("small");
      depth.textContent = T.fmt("panel.queueDepth", { queued: num(counts[size]) });
      button.append(label, depth);
      button.addEventListener("click", () => Open77.emit("dm:action", {
        action: "queue", size,
      }));
      container.append(button);
    }
    $("queueNote").textContent = state.queueRated === true
      ? "" : T.t("panel.queueUnrated");
  }

  /* ---------------------------------------------------------------------- */
  /* Render                                                                 */
  /* ---------------------------------------------------------------------- */

  function render(payload) {
    state = payload && typeof payload === "object" ? payload : state;

    const phase = String(state.phase || "lobby");
    const label = phaseLabel(phase);
    const remaining = num(state.remainingMs);
    const weapon = state.weapon || {};
    const instance = state.instance || {};
    const queued = state.queuedNext === true;
    const participant = state.participant === true;
    const panelOpen = state.panelOpen === true;
    const boardOpen = state.boardHeld === true || panelOpen || phase === "resolved";
    const mine = selfRow();
    const idle = IDLE_PHASES.has(phase);
    const arena = arenaOf();

    body.dataset.phase = phase;
    body.dataset.team = String(Math.trunc(num(mine.team)));
    body.classList.toggle("panel-open", panelOpen);
    body.classList.toggle("board-open", boardOpen);
    body.classList.toggle("in-match", participant && phase !== "resolved");
    renderDeath(phase, participant);

    $("phasePill").textContent = label;
    $("boardPhase").textContent = label;
    $("clock").textContent = idle ? T.t("band.clockIdle") : clock(remaining);
    $("boardClock").textContent = idle ? T.t("band.clockIdle") : clock(remaining);

    /* Instance identity: which one, and how full. Capacity is a HUMAN ceiling
     * -- the kernel admits against `memberCount` alone -- so the occupancy
     * fraction counts players, and the bots that are also in the round are
     * added beside it rather than folded in. Reporting "7/12" for one player
     * and six bots would be a wrong number; "1/12 +6" is the true one. */
    const hasInstance = instance.label !== undefined || instance.id !== undefined;
    $("instanceBlock").classList.toggle("hidden", !hasInstance);
    if (hasInstance) {
      const bots = num(instance.bots);
      $("instanceName").textContent = text(instance.label || instance.id, 24)
        || T.t("band.instanceUnknown");
      $("instanceCount").textContent = T.fmt(
        bots > 0 ? "band.occupancyBots" : "band.occupancy", {
          current: num(instance.players, num(state.participantCount)),
          max: num(instance.capacity, num(state.maxPlayers)),
          bots,
        });
    }

    /* The weapon card, and which of the two mode's truths it is telling. Under
     * the equalizer it is the round's shared weapon, straight off the push;
     * under `/guns` the push carries no weapon and this player's own issued kit
     * is what the card is for. */
    const choosing = loadout !== null && loadout.mode === "choice";
    $("weaponEyebrow").textContent = T.t(choosing ? "weapon.eyebrowChoice" : "weapon.eyebrow");
    $("weaponName").textContent = choosing
      ? (text(loadout.label, 40) || T.t("weapon.pending"))
      : (text(weapon.label, 40) || T.t("weapon.pending"));
    $("weaponCategory").textContent = choosing
      ? (text(loadout.category, 48) || T.t("weapon.choice"))
      : (text(weapon.category, 48) || T.t("weapon.equalizer"));

    $("selfKills").textContent = String(num(mine.kills));
    $("selfDeaths").textContent = String(num(mine.deaths));
    $("selfRatio").textContent = ratio(mine.kills, mine.deaths);

    /* THE FOOTER, AND THE BUG IT USED TO PRINT.
     *
     * `killLimit` is a free-for-all number and only the free-for-all fragment
     * carries it. An arena fragment does not -- an elimination format has no
     * kill limit and cannot have one -- so this line fell through to the
     * literal 25 below and told a 1v1 it was racing to twenty-five
     * eliminations. The default is kept for the free-for-all, where a missing
     * limit really is a missing number; the arena is answered from its own
     * best-of instead, which is the only thing it is actually decided on. */
    const killLimit = num(state.killLimit, 25);
    const limitText = arena
      ? T.fmt("arena.footerRounds", {
          bestOf: num(arena.bestOf, 1), target: num(arena.target, 1),
        })
      : T.fmt("board.footerLimit", { limit: killLimit });
    $("boardLimit").textContent = limitText;
    $("boardHold").textContent = T.fmt("board.footerHold", { key: T.t("board.keyBoard") });

    /* The dock and the panel used to read "N/2" against a minimum-players
     * concept decision 2 deleted: free-for-all never queues, has no minimum and
     * never waits for one. What a player outside a round actually wants to know
     * is how many are already fighting, which is what the lobby fragment's
     * `instancePlayers` counts across every open free-for-all instance. Inside
     * a round it narrows to this instance's own combatants, bots included. */
    const fighting = participant
      ? num(state.participantCount) : num(state.instancePlayers);
    $("combatCount").textContent = String(fighting);
    $("panelFighting").textContent = String(fighting);
    $("panelPhase").textContent = label;
    $("panelLimit").textContent = arena
      ? T.fmt("arena.limitValue", { target: num(arena.target, 1) })
      : T.fmt("panel.limitValue", { limit: killLimit });
    $("panelWeapon").textContent = (choosing ? text(loadout.label, 40) : text(weapon.label, 40))
      || T.t("panel.weaponPending");

    if (participant && phase === "active") {
      $("lobbyEyebrow").textContent = T.fmt("lobby.matchEyebrow", { id: state.matchId || "-" });
      /* The dock names the fight. In a free-for-all that is the shared weapon,
       * which is the mode's whole identity; in an arena there is no shared
       * weapon -- both teams buy from the same list -- so it names the format
       * instead of printing STANDBY forever. */
      $("lobbyTitle").textContent = arena
        ? (text(arena.label, 24) || T.t("modeName"))
        : (text(weapon.label, 40) || T.t("modeName"));
      $("lobbyText").textContent = arena
        ? T.fmt("arena.matchSummary", {
            count: num(state.participantCount), target: num(arena.target, 1),
          })
        : T.fmt("lobby.matchSummary", {
            count: num(state.participantCount),
            limit: killLimit,
          });
    } else if (queued) {
      $("lobbyEyebrow").textContent = T.t("lobby.enrolledEyebrow");
      $("lobbyTitle").textContent = phase === "active"
        ? T.t("lobby.nextRound") : T.t("lobby.searching");
      $("lobbyText").textContent = state.queuePosition
        ? T.fmt("lobby.queuePosition", { position: state.queuePosition })
        : T.t("lobby.enrolled");
    } else {
      $("lobbyEyebrow").textContent = T.t("lobby.secureEyebrow");
      $("lobbyTitle").textContent = T.t("lobby.title");
      $("lobbyText").textContent = participant
        ? T.t("lobby.enrolAgainPrompt") : T.t("lobby.enrolPrompt");
    }

    $("joinButton").classList.toggle("hidden", state.canJoin !== true);
    $("joinButton").textContent = participant ? T.t("panel.rejoin") : T.t("panel.join");
    $("leaveQueueButton").classList.toggle("hidden", !queued);
    $("leaveMatchButton").classList.toggle("hidden", state.canLeaveMatch !== true);

    const showCountdown = phase === "countdown" && participant;
    $("countdown").classList.toggle("visible", showCountdown);
    $("countdownValue").textContent = String(Math.max(1, Math.ceil(remaining / 1000)));
    $("countdownLabel").textContent = remaining <= 1800
      ? T.t("countdown.initialising") : T.t("countdown.deploy");

    renderArena(arena, phase);
    renderQueue();
    renderResult(phase, participant, mine, arena);
    renderRows();
  }

  function renderResult(phase, participant, mine, arena) {
    const result = state.result || {};
    const show = phase === "resolved" && participant;
    $("resultBanner").classList.toggle("visible", show);
    if (!show) return;

    /* Team formats resolve on a team, free-for-all on a player. The server
     * sends ids; the words are ours.
     *
     * `winnerSide` is what `server/arena.lua` actually writes; `winnerTeam` was
     * the name this file expected and nothing in the gamemode has ever sent
     * one, so an arena result used to land in the free-for-all branch below
     * with no `winnerId` either and resolve, always, to DRAW. Both names are
     * read, and the player's own SIDE decides won or lost -- `mine.team` comes
     * from the standings row and an eliminated player still has one. */
    const winnerTeam = Math.trunc(num(result.winnerTeam, num(result.winnerSide)));
    if (winnerTeam > 0) {
      if (arena) {
        const wins = Array.isArray(result.wins) ? result.wins : [0, 0];
        const side = Math.trunc(num(arena.side, num(mine.team)));
        $("resultTitle").textContent = winnerTeam === side
          ? T.t("result.victory") : T.t("result.defeat");
        $("resultText").textContent = T.fmt("result.winner", { name: teamName(winnerTeam) })
          + "  " + num(wins[0]) + " - " + num(wins[1]);
        return;
      }
      const won = winnerTeam === Math.trunc(num(mine.team));
      $("resultTitle").textContent = won ? T.t("result.victory") : T.t("result.defeat");
      $("resultText").textContent = T.fmt("result.winner", {
        name: T.t("teams." + (winnerTeam - 1), String(winnerTeam)),
      });
      return;
    }

    const hasWinner = num(result.winnerId) > 0;
    const won = isSelf(result.winnerId);
    $("resultTitle").textContent = !hasWinner
      ? T.t("result.draw") : won ? T.t("result.victory") : T.t("result.defeat");
    $("resultText").textContent = hasWinner
      ? T.fmt("result.winner", { name: text(result.winnerName, 48) || T.t("killfeed.unknownPlayer") })
      : T.t("result.noWinner");
  }

  /* ---------------------------------------------------------------------- */
  /* Weapon picker -- /guns                                                 */
  /* ---------------------------------------------------------------------- */

  /* The picker's own state, and deliberately NOT part of `state`: the weapon
   * catalogue changes only when shared/config.lua is edited, so putting 49
   * rows on the several-times-a-second state push would be paying for it
   * forever. It arrives whole, on `dm:guns`, and this is where it lives until
   * the next one.
   *
   *   chosen    what the player has picked
   *   carrying  what the server has actually issued them
   * They differ for exactly as long as a pick is waiting on a respawn, and that
   * gap is the only thing this surface has to explain.
   *
   * `weapons` replaced `kits`: the server used to send the four-kit arena buy
   * list and now sends every primary in `Config.loadout.primaries`, already
   * sorted into its category groups. Slots 2 and 3 are not in it and never
   * were -- the sidearm and the blade are fixed so that a player who runs the
   * primary dry still has a fight left. */
  let guns = { weapons: [], chosen: null, carrying: null, mode: "choice" };

  /* Type-to-filter, and the cursor into the FILTERED list. Both are page-local
   * and both reset when a fresh catalogue arrives: a filter is a search, not a
   * preference. */
  let gunsFilter = "";
  let gunsCursor = 0;

  /* Lower-case, letters and digits only, so "SPT32 Grad" is found by "spt32",
   * by "grad" and by "spt32grad". server/loadout.lua matches `/guns <name>`
   * with the same rule, so the two routes into the same pick behave alike. */
  function slug(value) {
    return String(value === undefined || value === null ? "" : value)
      .toLowerCase().replace(/[^a-z0-9]/g, "");
  }

  function gunsVisible() {
    const all = Array.isArray(guns.weapons) ? guns.weapons : [];
    const needle = slug(gunsFilter);
    if (!needle) return all;
    return all.filter(weapon => slug(weapon.key).includes(needle)
      || slug(weapon.label).includes(needle)
      || slug(weapon.category).includes(needle));
  }

  /* One key hint. The GLYPHS are escapes rather than literal characters, for
   * the reason web/app.js and open77_admin's menu.js both give: a stray
   * non-UTF-8 read of this file would turn an arrow into mojibake in the one
   * place a player looks to learn the panel. They are also not language, which
   * is why they are here and the WORDS beside them come from the string
   * table. */
  function gunsHint(cap, word) {
    const span = document.createElement("span");
    const key = document.createElement("b");
    key.textContent = cap;
    span.append(key, document.createTextNode(word));
    return span;
  }

  function renderGuns() {
    const list = $("gunsList");
    const rows = gunsVisible();
    const total = Array.isArray(guns.weapons) ? guns.weapons.length : 0;

    if (gunsCursor > rows.length - 1) gunsCursor = Math.max(0, rows.length - 1);

    /* Rows are rebuilt rather than diffed, exactly as the admin menu rebuilds
     * its nine: fifty <li> elements at a keypress is nothing next to a diff
     * that would need a stable key per row through a category heading. */
    list.replaceChildren();
    let group = null;
    let selected = null;

    rows.forEach((weapon, index) => {
      const category = text(weapon.category, 32);
      if (category !== group) {
        group = category;
        const head = document.createElement("li");
        head.className = "guns-group";
        head.textContent = category || T.t("guns.groupOther");
        list.append(head);
      }

      const key = text(weapon.key, 32);
      const item = document.createElement("li");
      item.className = index === gunsCursor ? "guns-row on" : "guns-row";
      item.dataset.key = key;

      const label = document.createElement("span");
      label.className = "label";
      label.textContent = text(weapon.label, 32) || key;
      item.append(label);

      /* Carrying wins over chosen when they are the same row: "in hand" is the
       * stronger claim and the two can only differ on two different rows. */
      if (key === guns.carrying) item.append(chip("tag now", T.t("guns.carrying")));
      else if (key === guns.chosen) item.append(chip("tag next", T.t("guns.queued")));

      const value = document.createElement("span");
      value.className = "value";
      /* The reserve, because it is the decision the player is actually making:
       * 60 rounds for a Grad against 360 for a Defender is not recoverable from
       * the name, and it is the field the old kit cards had no room for. */
      value.textContent = num(weapon.reserve) > 0
        ? T.fmt("guns.reserve", { count: num(weapon.reserve) })
        : T.t("guns.reserveNone");
      item.append(value);

      item.addEventListener("click", () => pickGuns(key));
      /* Hover moves the cursor rather than lighting a second, competing
       * highlight. One row is selected at a time however the player got there,
       * so Enter after a mouse move takes the row under the pointer. */
      item.addEventListener("mouseenter", () => {
        if (gunsCursor === index) return;
        gunsCursor = index;
        renderGuns();
      });

      list.append(item);
      if (index === gunsCursor) selected = item;
    });

    const empty = $("gunsEmpty");
    empty.classList.toggle("hidden", rows.length > 0);
    empty.textContent = total === 0
      ? T.t("guns.empty")
      : T.fmt("guns.noMatch", { text: gunsFilter });

    /* The filter line: a lit prompt, then either what has been typed or the
     * hint that typing does something. */
    const filter = $("gunsFilter");
    filter.replaceChildren();
    const prompt = document.createElement("b");
    prompt.textContent = "/";
    filter.append(prompt);
    if (gunsFilter) {
      const typed = document.createElement("em");
      typed.textContent = gunsFilter;
      filter.append(typed);
    } else {
      filter.append(document.createTextNode(T.t("guns.filterHint")));
    }

    /* Where the cursor sits in the list, in the admin menu's own `n / total`
     * form -- and it says both numbers while a filter is narrowing the list,
     * because "3 / 5" on a catalogue of forty-nine would be a wrong number. */
    $("gunsMore").textContent = rows.length === 0 ? ""
      : rows.length === total
        ? T.fmt("guns.position", { index: gunsCursor + 1, total })
        : T.fmt("guns.positionFiltered", {
          index: gunsCursor + 1, shown: rows.length, total,
        });

    /* One line saying WHEN the current pick lands. The equalizer message wins
     * over all of it: with the switch off there is no timing to explain. */
    const note = $("gunsNote");
    note.classList.remove("settled");
    if (guns.mode !== "choice") {
      note.textContent = T.t("guns.equalizer");
    } else if (!guns.chosen) {
      note.textContent = "";
    } else if (guns.chosen === guns.carrying) {
      note.classList.add("settled");
      note.textContent = T.t("guns.applyNow");
    } else if (guns.carrying === null || guns.carrying === undefined) {
      note.textContent = T.t("guns.applyDeploy");
    } else {
      note.textContent = T.t("guns.applyNext");
    }

    const foot = $("gunsFoot");
    foot.replaceChildren();
    foot.append(
      gunsHint("\u2191\u2193", T.t("guns.footMove")),
      gunsHint("\u23ce", T.t("guns.footSelect")),
      gunsHint("A-Z", T.t("guns.footFilter")),
      gunsHint(T.t("guns.keyClose"), T.t("guns.footClose")));

    /* The keyboard is the fast route out of a spawn-protection window, so the
     * row it is on has to be on screen. `nearest` never scrolls when the row
     * already is. */
    if (selected && typeof selected.scrollIntoView === "function") {
      selected.scrollIntoView({ block: "nearest" });
    }
  }

  function pickGuns(key) {
    if (!key || guns.mode !== "choice") return;
    /* Painted before the server answers. The pick is a preference the server
     * cannot refuse -- the key came out of the list it just sent -- and a row
     * that waits a round-trip to light up reads as a dropped click. The
     * authoritative `carrying` is untouched, so nothing here claims the weapon
     * is in hand. */
    guns.chosen = key;
    renderGuns();
    Open77.emit("dm:guns", { action: "pick", key });
  }

  function moveGunsCursor(delta) {
    const count = gunsVisible().length;
    if (count === 0) return;
    gunsCursor = ((gunsCursor + delta) % count + count) % count;
    renderGuns();
  }

  /* Returns true when the key was consumed, so the caller can stop it reaching
   * anything else. Every route out of this panel is ONE action: ESC closes it
   * whether or not a filter is standing, because a picker that needs two
   * presses to leave is a picker that can cost a fight. */
  function gunsKey(event) {
    const key = event.key;
    if (key === "Escape") { Open77.emit("dm:guns", { action: "close" }); return true; }
    if (key === "ArrowDown") { moveGunsCursor(1); return true; }
    if (key === "ArrowUp") { moveGunsCursor(-1); return true; }
    if (key === "PageDown") { moveGunsCursor(8); return true; }
    if (key === "PageUp") { moveGunsCursor(-8); return true; }
    if (key === "Home") { gunsCursor = 0; renderGuns(); return true; }
    if (key === "End") {
      gunsCursor = Math.max(0, gunsVisible().length - 1);
      renderGuns();
      return true;
    }
    if (key === "Enter") {
      const row = gunsVisible()[gunsCursor];
      if (row) pickGuns(text(row.key, 32));
      return true;
    }
    if (key === "Backspace") {
      gunsFilter = gunsFilter.slice(0, -1);
      gunsCursor = 0;
      renderGuns();
      return true;
    }
    /* Any single printable character types into the filter. The digits that
     * used to pick kits 1-9 went with the kits: against forty-nine weapons a
     * digit is worth far more as a character of "ma70" or "sor22" than as an
     * ordinal nobody could count to. */
    if (key.length === 1 && key !== " "
      && !event.ctrlKey && !event.altKey && !event.metaKey) {
      gunsFilter = (gunsFilter + key).slice(0, 24);
      gunsCursor = 0;
      renderGuns();
      return true;
    }
    return false;
  }

  /* ---------------------------------------------------------------------- */
  /* Notices and kill feed                                                  */
  /* ---------------------------------------------------------------------- */

  function notice(payload) {
    const item = document.createElement("div");
    item.className = "notice " + text(payload.kind || "info", 16);
    const title = document.createElement("strong");
    title.textContent = text(payload.title, 64) || T.t("modeName");
    const message = document.createElement("span");
    message.textContent = text(payload.message, 180);
    item.append(title, message);
    $("notices").append(item);
    while ($("notices").children.length > 3) $("notices").firstChild.remove();
    setTimeout(() => item.classList.add("leaving"), 4200);
    setTimeout(() => item.remove(), 4700);
  }

  function chip(className, content) {
    const element = document.createElement("span");
    element.className = className;
    element.textContent = content;
    return element;
  }

  function killfeed(payload) {
    const killerId = payload.killerId;
    const victimId = payload.victimId;
    const killer = text(payload.killerName !== undefined ? payload.killerName : payload.killer);
    const victim = text(payload.victimName !== undefined ? payload.victimName : payload.victim);

    const item = document.createElement("div");
    item.className = "kill";
    if (killerId !== undefined && isSelf(killerId)) item.classList.add("mine");
    if (victimId !== undefined && isSelf(victimId)) item.classList.add("died");
    if (!killer) item.classList.add("unattributed");

    const killerEl = chip("who killer" + teamClass(payload.killerTeam),
      killer || T.t("killfeed.environment"));
    item.append(killerEl);
    if (payload.killerBot === true) item.append(chip("bot", T.t("killfeed.bot")));

    /* Weapon, then the headshot marker, then the victim: the same reading
     * order as every shooter feed, so it needs no learning. */
    const weapon = text(payload.weapon, 28);
    if (weapon) item.append(chip("weapon-name", weapon));
    else item.append(chip("verb", "✦"));
    if (payload.headshot === true) item.append(chip("hs", T.t("killfeed.headshot")));

    item.append(chip("who victim" + teamClass(payload.victimTeam),
      victim || T.t("killfeed.unknownPlayer")));
    if (payload.victimBot === true) item.append(chip("bot", T.t("killfeed.bot")));

    const distance = num(payload.distance, -1);
    if (distance >= 0) {
      item.append(chip("dist", T.fmt("killfeed.distance", { meters: distance.toFixed(0) })));
    }
    if (num(payload.streak) >= 3) {
      item.append(chip("streak", T.fmt("killfeed.streak", { count: num(payload.streak) })));
    }

    $("feed").prepend(item);
    while ($("feed").children.length > 6) $("feed").lastChild.remove();
    setTimeout(() => item.classList.add("leaving"), 5200);
    setTimeout(() => item.remove(), 5700);
  }

  /* ---------------------------------------------------------------------- */
  /* Bridge                                                                 */
  /* ---------------------------------------------------------------------- */

  function emit(action) {
    Open77.emit("dm:action", { action });
  }

  $("joinButton").addEventListener("click", () => emit("join"));
  $("leaveQueueButton").addEventListener("click", () => emit("leaveQueue"));
  $("leaveMatchButton").addEventListener("click", () => emit("leaveMatch"));
  $("close").addEventListener("click", () => Open77.emit("dm:close", {}));
  $("gunsClose").addEventListener("click", () => Open77.emit("dm:guns", { action: "close" }));
  /* The scrim is shared by both modals, so it has to close whichever is up.
   * The picker is on top (z-index 12 against the panel's 10), so it goes
   * first: clicking away from the thing you can see should dismiss that. */
  $("scrim").addEventListener("click", () => {
    if (body.classList.contains("guns-open")) Open77.emit("dm:guns", { action: "close" });
    else Open77.emit("dm:close", {});
  });
  document.addEventListener("keydown", event => {
    /* The picker owns the keyboard whole while it is up -- arrows, Enter,
     * Backspace and every printable character are its filter and its cursor.
     * It is on top of the enrolment panel, so it answers first, and a key it
     * consumed is stopped here rather than also reaching the page default.
     *
     * This costs the player nothing in a live round: the panel closes itself
     * the moment spawn protection ends when it opened itself, and ESC always
     * leaves in one press. Gameplay input is never captured while it is shut,
     * because the surface only takes focus while `guns-open` is set. */
    if (body.classList.contains("guns-open")) {
      if (gunsKey(event)) event.preventDefault();
      return;
    }
    if (event.key === "Escape") Open77.emit("dm:close", {});
  });

  Open77.on("dm:strings", table => {
    T.set(table);
    /* Re-run the render so every value that was formatted from the table --
     * the clock placeholder, the footers, the lobby copy -- picks up the new
     * language without waiting for the next push. */
    render(state);
    renderGuns();
  });
  Open77.on("dm:state", render);
  Open77.on("dm:notice", notice);
  Open77.on("dm:killfeed", killfeed);
  Open77.on("dm:panel", payload => {
    body.classList.toggle("panel-open", payload && payload.open === true);
  });
  Open77.on("dm:loadout", payload => {
    loadout = payload && typeof payload === "object" ? payload : null;
    render(state);
  });
  Open77.on("dm:guns", payload => {
    const open = payload && payload.open === true;
    body.classList.toggle("guns-open", open);
    $("gunsPicker").setAttribute("aria-hidden", String(!open));
    if (payload && payload.weapons !== undefined) {
      guns = {
        /* Lua cannot tell an empty array from an empty map, so a server that
         * sent a list with nothing in it would arrive here as `{}` rather than
         * `[]` -- truthy, and `.forEach` would throw halfway through a render.
         * `openPicker` refuses to send at all on an empty arsenal, so this is
         * belt and braces; every list crossing this bridge gets it. */
        weapons: Array.isArray(payload.weapons) ? payload.weapons : [],
        chosen: payload.chosen === undefined ? null : text(payload.chosen, 32),
        carrying: payload.carrying === undefined || payload.carrying === null
          ? null : text(payload.carrying, 32),
        mode: text(payload.mode, 16) || "choice",
      };
      /* A fresh catalogue is a fresh panel. The filter is a search rather than
       * a preference, so it does not survive; the cursor starts on what the
       * player already has, which makes Enter alone a no-op instead of a
       * surprise. */
      gunsFilter = "";
      const at = guns.weapons.findIndex(weapon => text(weapon.key, 32) === guns.chosen);
      gunsCursor = at >= 0 ? at : 0;
    }
    renderGuns();
  });

  Open77.ready();
  Open77.emit("dm:ready", {});
})();
