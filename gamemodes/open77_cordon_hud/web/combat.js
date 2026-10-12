/* The Cordon combat surface.
 *
 * Presentation only. Every number on this page arrived from Lua, which took it
 * from the server damage ledger or the server state push. The page computes
 * nothing except the two things a page is for: interpolating between snapshots
 * (CSS transitions) and choosing a word from the string table for a kind the
 * server sent as an enum.
 *
 * EVERY FIELD IS OPTIONAL. The first push lands before anything is set, and a
 * player watching from staging gets a payload with no cordon and no inventory.
 * Nothing below tests for a field it then dereferences; everything reads
 * through `num()` or a `typeof` guard and renders an empty state.
 */
(() => {
  "use strict";

  const $ = id => document.getElementById(id);
  const body = document.body;
  const T = window.CordonStrings;

  const hitmarker = $("hitmarker");
  const damageFlash = $("damageFlash");
  const cordonPulse = $("cordonPulse");
  const movePulse = $("movePulse");
  const indicatorsEl = $("indicators");
  const shieldSweep = $("shieldSweep");

  /* 2 * pi * 104, matching the stroke-dasharray in combat.css. */
  const RING = 653.4;

  let hitTimer = 0;
  let flashTimer = 0;
  let pulseTimer = 0;
  let moveTimer = 0;
  const liveIndicators = new Map();

  function num(value, fallback) {
    const n = Number(value);
    return Number.isFinite(n) ? n : (fallback === undefined ? 0 : fallback);
  }

  function text(value, limit) {
    return String(value === undefined || value === null ? "" : value).slice(0, limit || 32);
  }

  /* --------------------------------------------------------------------- */
  /* Vitals, plates, ammo, shield                                          */
  /* --------------------------------------------------------------------- */

  function renderVitals(payload) {
    const maxHealth = Math.max(1, num(payload.maxHealth, 100));
    const health = Math.max(0, Math.min(maxHealth, num(payload.health)));
    const fraction = health / maxHealth;

    // Canonical normalized health can arrive as 30.000001 after a 30% revive.
    // Round the label to the nearest point; retain full precision for the bar.
    $("healthValue").textContent = String(Math.round(health));
    $("healthFill").style.width = (fraction * 100).toFixed(1) + "%";
    body.dataset.vitals = fraction <= .25 ? "critical" : fraction <= .5 ? "warn" : "ok";

    /* Armor is 0..75 in this mode: three plates of 25 (plan section 5). The
     * bar is measured against that ceiling rather than against the highest
     * value seen, so a player who just broke a plate sees the bar drop by a
     * third instead of refilling to full. */
    const armor = Math.max(0, num(payload.armor));
    const maxArmor = 75;
    body.dataset.armored = String(armor > 0);
    $("armorValue").textContent = String(Math.round(armor));
    $("armorFill").style.width = Math.min(100, (armor / maxArmor) * 100).toFixed(1) + "%";

    const plates = Math.max(0, Math.min(3, Math.trunc(num(payload.plates))));
    const pips = $("plates").children;
    for (let index = 0; index < pips.length; index += 1) {
      pips[index].classList.toggle("on", index < plates);
    }
    $("plates").setAttribute("aria-hidden", String(plates <= 0));
  }

  function renderAmmo(payload) {
    /* Both counters come from the active engine weapon snapshot. Unknown is
     * distinct from empty; never infer magazine capacity from reserve ammo. */
    const rounds = Math.trunc(num(payload.ammo, -1));
    const known = rounds >= 0;
    $("ammoValue").textContent = known ? String(rounds) : T.t("combat.empty");
    const reserve = Math.trunc(num(payload.ammoReserve, -1));
    $("ammoReserve").textContent = reserve >= 0 ? String(reserve) : T.t("combat.empty");

    /* The active weapon's name replaces the generic AMMO label when there is
     * one: in a battle royale which gun is in your hands is a fact you keep
     * forgetting, and the label is free real estate. */
    const label = text(payload.ammoLabel, 22);
    $("ammoLabel").textContent = label || T.t("combat.ammo");

    body.dataset.ammo = !known ? "unknown" : rounds === 0 ? "empty" : rounds <= 3 ? "low" : "ok";
  }

  function renderShield(payload) {
    const remaining = Math.max(0, num(payload.shieldMs));
    const shown = remaining > 0;
    body.dataset.shielded = String(shown);

    /* The total is not on the wire, so the ring is drawn against the mode's own
     * ceiling: 4 s at deploy, 2 s after a revive (plan section 8). Taking the
     * larger of the two means a revive shield fills the ring rather than
     * appearing as a stub, and neither ever overflows it. */
    const total = 4000;
    const fraction = Math.max(0, Math.min(1, remaining / total));
    shieldSweep.style.strokeDashoffset = (RING * (1 - fraction)).toFixed(1);
    $("shieldCount").textContent = (remaining / 1000).toFixed(1);
  }

  /* --------------------------------------------------------------------- */
  /* Outside the cordon                                                    */
  /* --------------------------------------------------------------------- */

  /* Last value written to the custom property, so the 25 Hz push does not
   * invalidate style on every frame for a number that has not visibly moved.
   * Quantised to fiftieths: the whole ramp is at most fifty writes, and a
   * fiftieth of the rim's opacity is below what an eye resolves. */
  let vignetteStep = -1;

  function renderOutside(payload) {
    const outside = payload.outside === true;
    body.dataset.outside = String(outside);

    /* HOW LOUD THE RIM IS, 0..1, computed on the SERVER'S tuning in Lua (see
     * outsideLevel() in client/combat.lua). The page does not decide it and
     * does not smooth it -- the value already arrives extrapolated at 25 Hz,
     * and the CSS breathe carries the motion.
     *
     * It is written to a custom property rather than to `style.opacity`
     * because the vignette's opacity is driven by a keyframe animation: an
     * inline opacity would lose to the animation, while a variable READ by the
     * keyframes scales it. Only opacity animates, so the compositor carries
     * the whole effect and nothing repaints -- which is the rule this HUD
     * learned the hard way when three surfaces at high refresh cost two
     * clients their frame rate (docs/research/battle-royale-and-scale.md).
     *
     * The server may send no level at all -- an older build, or one whose
     * fragment predates the field -- and `outside` alone then means full, which
     * is the behaviour that shipped. */
    const level = outside
      ? (payload.outsideLevel === undefined ? 1 : Math.max(0, Math.min(1, num(payload.outsideLevel, 1))))
      : 0;
    const step = Math.round(level * 50);
    if (step !== vignetteStep) {
      vignetteStep = step;
      body.style.setProperty("--cordon-outside", (step / 50).toFixed(2));
    }

    /* Three tiers, so the banner can change in KIND and not only in degree. A
     * rim that is merely brighter is read as the same message louder; a rim
     * that has visibly become something else is read as a new one. The
     * thresholds are the page's, not the server's, because they describe this
     * layout rather than the rules. */
    const tier = !outside ? "none" : level >= .8 ? "lethal" : level >= .45 ? "burn" : "warn";
    if (body.dataset.outsideTier !== tier) body.dataset.outsideTier = tier;

    if (!outside) return;

    const dps = num(payload.dps);
    $("outsideRate").textContent = dps > 0
      ? T.fmt("cordon.outsideSub", { dps: dps.toFixed(0) })
      : "";

    /* TIME TO FLATLINE. Lua derives it from the server's health ledger and the
     * phase rate (flatlinePayload() in client/combat.lua) and sends
     * `{ seconds }` only while both are known; absent means "do not guess". It
     * is rounded UP so the figure never reads zero while the player is still
     * alive, and below one second the word replaces the number: a countdown
     * that says "0s" over a living player is a HUD calling him dead. */
    const flatline = payload.flatline && typeof payload.flatline === "object"
      ? payload.flatline : null;
    const flatlineEl = $("outsideFlatline");
    if (!flatline) {
      flatlineEl.hidden = true;
      flatlineEl.textContent = "";
    } else {
      const seconds = Math.max(0, num(flatline.seconds));
      flatlineEl.hidden = false;
      flatlineEl.textContent = seconds < 1
        ? T.t("cordon.flatlineNow")
        : T.fmt("cordon.flatlineIn", { seconds: Math.ceil(seconds) });
    }

    const compass = payload.compass && typeof payload.compass === "object"
      ? payload.compass : null;
    if (!compass) {
      /* The server has not told us where the nearest open block is. The banner
       * still fires -- the player is still bleeding -- but the compass hides
       * rather than pointing north by default. */
      $("compass").hidden = true;
      return;
    }
    $("compass").hidden = false;
    $("compassDistance").textContent = T.fmt("cordon.compassDist",
      { meters: Math.round(num(compass.distance)) });
    /* `aimed` is false when the local position could not be read. The distance
     * is still true, so the strip keeps it and drops the arrow: an arrow that
     * is wrong is worse than no arrow when it is the only thing telling a
     * bleeding player which way to run. */
    const arrow = $("compassArrow");
    arrow.hidden = compass.aimed !== true;
    arrow.style.transform = "rotate(" + num(compass.angle).toFixed(1) + "deg)";
  }

  /* --------------------------------------------------------------------- */
  /* Standing on doomed ground                                             */
  /* --------------------------------------------------------------------- */

  /* ZONE CLOSING IN / NEXT ZONE. Lua sends `move` only while the server says
   * this player's cell is announced and not yet closed, and never together
   * with `outside`; absent means "do not draw". `seconds` is the player's own
   * cell's deadline, extrapolated in Lua between pushes; `compass` is the
   * bearing to the nearest cell that survives the phase, or absent when
   * nothing does (the terminal phase), in which case the clock stands alone.
   *
   * Three tiers by seconds left, set as a data attribute so the CSS can
   * change the strip in KIND -- steady, then a beat, then a strobe -- rather
   * than only in degree. The thresholds are the page's: they describe how
   * long a player needs to start moving, not a rule of the mode. */
  function renderMove(payload) {
    const move = payload.move && typeof payload.move === "object" ? payload.move : null;
    const doomed = !!move && payload.outside !== true;
    body.dataset.doomed = String(doomed);
    if (!doomed) {
      if (body.dataset.moveTier !== "none") body.dataset.moveTier = "none";
      return;
    }

    const known = move.seconds !== undefined && move.seconds !== null;
    const seconds = known ? Math.max(0, num(move.seconds)) : -1;
    const tier = !known || seconds >= 20 ? "calm" : seconds >= 8 ? "warn" : "urgent";
    if (body.dataset.moveTier !== tier) body.dataset.moveTier = tier;

    /* Rounded UP, like the flatline figure, so it never reads zero while the
     * cell is still open; below one second the word replaces the number. */
    $("moveTitle").textContent = !known
      ? T.t("cordon.moveTitleNoClock")
      : seconds < 1
        ? T.t("cordon.moveNow")
        : T.fmt("cordon.moveTitle", { seconds: Math.ceil(seconds) });
    $("moveSub").textContent = T.t("cordon.moveSub");

    const compass = move.compass && typeof move.compass === "object" ? move.compass : null;
    const section = $("moveCompass");
    if (!compass) {
      section.hidden = true;
      return;
    }
    section.hidden = false;
    $("moveDistance").textContent = T.fmt("cordon.compassDist",
      { meters: Math.round(num(compass.distance)) });
    const arrow = $("moveArrow");
    arrow.hidden = compass.aimed !== true;
    arrow.style.transform = "rotate(" + num(compass.angle).toFixed(1) + "deg)";
  }

  function showMove() {
    movePulse.classList.remove("show");
    void movePulse.offsetWidth;
    movePulse.classList.add("show");
    clearTimeout(moveTimer);
    moveTimer = setTimeout(() => movePulse.classList.remove("show"), 700);
  }

  function renderUse(payload) {
    const use = payload.use && typeof payload.use === "object" ? payload.use : null;
    const valid = payload.active === true && !payload.revive && use && (use.kind === "plate" || use.kind === "heal");
    const section = $("useAction");
    section.hidden = !valid;
    section.setAttribute("aria-hidden", String(!valid));
    if (!valid) return;
    const remaining = Math.max(0, num(use.remainingMs)), duration = Math.max(1, num(use.durationMs, 1));
    $("useLabel").textContent = T.t(use.kind === "plate" ? "combat.applyingPlate" : "combat.healing");
    $("useRemaining").textContent = remaining > 0 ? T.fmt("combat.useTime", {seconds: Math.ceil(remaining / 1000)}) : T.t("combat.useFinishing");
    $("useFill").style.width = (Math.max(0, Math.min(.99, 1 - remaining / duration)) * 100).toFixed(1) + "%";
  }

  function renderRevive(payload) {
    const revive = payload.revive && typeof payload.revive === "object" ? payload.revive : null;
    const downed = payload.downed && typeof payload.downed === "object" ? payload.downed : null;
    body.dataset.reviveTarget = String(Boolean(downed) || Boolean(revive) && ["target", "self"].includes(revive.role));
    const section = $("revive");
    section.hidden = !revive && !downed;
    section.setAttribute("aria-hidden", String(section.hidden));
    $("selfReviveHint").hidden = !downed;
    if (section.hidden) return;
    if (downed) {
      $("selfReviveHint").textContent = T.fmt("squad.bleedOut", {seconds: Math.ceil(Math.max(0, num(downed.remainingMs)) / 1000)});
    }
    if (!revive) {
      $("reviveLabel").textContent = T.t(downed.pending ? "squad.recoveryPending" : "squad.selfDowned");
      const waiting = num(downed.selfReadyInMs) > 0;
      $("reviveName").textContent = downed.pending ? "" : T.fmt(waiting ? "squad.selfWait" : "squad.selfHold",
        {seconds: Math.ceil(num(waiting ? downed.selfReadyInMs : downed.selfHoldMs, 3000) / 1000)});
      $("reviveFill").style.width = "0%";
      return;
    }
    const incoming = revive.role === "target", self = revive.role === "self";
    $("reviveLabel").textContent = T.t(revive.pending === true ? "squad.recoveryPending"
      : self ? "squad.selfReviving" : incoming ? "squad.revived" : "squad.reviving");
    $("reviveName").textContent = incoming || self ? "" : text(revive.name, 24);
    const progress = Math.max(0, Math.min(revive.pending ? 1 : .99, num(revive.progress)));
    $("reviveFill").style.width = (progress * 100).toFixed(1) + "%";
  }

  function renderIndicators(items) {
    const seen = new Set();
    for (const item of Array.isArray(items) ? items : []) {
      const id = String(item.id);
      seen.add(id);
      let element = liveIndicators.get(id);
      if (!element) {
        element = document.createElement("div");
        element.className = "ind";
        const arc = document.createElement("span");
        arc.className = "ind-arc";
        element.append(arc);
        indicatorsEl.append(element);
        liveIndicators.set(id, element);
      }
      element.classList.toggle("omni", item.omni === true);
      element.style.transform = "rotate(" + num(item.angle).toFixed(1) + "deg)";
      /* `life` runs 1 -> 0 over the indicator's window; squaring it holds the
       * arrow bright while the player turns, then drops it quickly. */
      const life = Math.max(0, Math.min(1, num(item.life)));
      element.style.opacity = (life * life).toFixed(3);
    }
    for (const [id, element] of liveIndicators) {
      if (seen.has(id)) continue;
      element.remove();
      liveIndicators.delete(id);
    }
  }

  /* --------------------------------------------------------------------- */
  /* Feedback                                                              */
  /* --------------------------------------------------------------------- */

  function showHitmarker(payload) {
    hitmarker.classList.remove("show", "lethal", "headshot", "bot");
    if (payload && payload.lethal === true) hitmarker.classList.add("lethal");
    else if (payload && payload.bodyPart === "head") hitmarker.classList.add("headshot");
    /* A hit on a bot is marked, quietly. The mode fills matches with bots, and
     * a player is entitled to know which of the two things they just shot --
     * the same rule that labels them in the feed, applied at the one moment
     * the feed is too slow to help. */
    if (payload && payload.victim === "bot") hitmarker.classList.add("bot");
    /* Restart the animation even when hits land back to back. */
    void hitmarker.offsetWidth;
    hitmarker.classList.add("show");
    clearTimeout(hitTimer);
    hitTimer = setTimeout(() => hitmarker.classList.remove("show"), 360);
  }

  function showDamage(payload) {
    /* Two visuals, chosen by cause. The cordon has no attacker and no
     * direction, so it gets a slow red edge bloom rather than the sharp
     * directional bite of a bullet. A player must be able to tell, without
     * reading anything, whether they are being shot or being bled. */
    const cordon = payload && String(payload.cause) === "cordon";
    const element = cordon ? cordonPulse : damageFlash;
    element.classList.remove("show");
    void element.offsetWidth;
    element.classList.add("show");
    if (cordon) {
      clearTimeout(pulseTimer);
      pulseTimer = setTimeout(() => element.classList.remove("show"), 900);
    } else {
      clearTimeout(flashTimer);
      flashTimer = setTimeout(() => element.classList.remove("show"), 440);
    }
  }

  /* --------------------------------------------------------------------- */
  /* Bridge                                                                */
  /* --------------------------------------------------------------------- */

  Open77.on("cordon:strings", table => { T.set(table); });

  Open77.on("cordon:combat", payload => {
    if (!payload || typeof payload !== "object") return;
    body.dataset.active = String(payload.active === true);
    body.dataset.mapOpen = String(payload.mapOpen === true);
    body.dataset.alive = String(payload.alive !== false);
    body.dataset.squad = String(Math.trunc(num(payload.squad)));
    renderVitals(payload);
    renderAmmo(payload);
    renderShield(payload);
    renderOutside(payload);
    renderMove(payload);
    renderRevive(payload);
    renderUse(payload);
    renderIndicators(payload.indicators);
  });

  Open77.on("cordon:hit", showHitmarker);
  Open77.on("cordon:damaged", showDamage);
  Open77.on("cordon:move", showMove);

  Open77.ready();
  Open77.emit("cordon:ready", {});
})();
