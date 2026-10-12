/* The combat surface.
 *
 * Presentation only. Every number on this page arrived from Lua, which took it
 * from the server damage ledger, the server state push or the engine's own
 * magazine. The page computes nothing except the two things a page is for:
 * interpolating between snapshots (CSS transitions) and choosing a word from
 * the string table for a kind the server sent as an enum.
 */
(() => {
  "use strict";

  const $ = id => document.getElementById(id);
  const body = document.body;
  const T = window.DMStrings;

  const hitmarker = $("hitmarker");
  const damageFlash = $("damageFlash");
  const indicatorsEl = $("indicators");
  const calloutEl = $("callout");
  const protectionSweep = $("protectionSweep");
  const protectionCount = $("protectionCount");

  /* 2 * pi * 104, matching the stroke-dasharray in combat.css. */
  const RING = 653.4;

  let hitTimer = 0;
  let flashTimer = 0;
  const liveIndicators = new Map();

  function num(value, fallback) {
    const n = Number(value);
    return Number.isFinite(n) ? n : (fallback === undefined ? 0 : fallback);
  }

  /* ---------------------------------------------------------------------- */
  /* Vitals, ammo, protection                                               */
  /* ---------------------------------------------------------------------- */

  function renderVitals(payload) {
    const maxHealth = Math.max(1, num(payload.maxHealth, 100));
    const health = Math.max(0, Math.min(maxHealth, num(payload.health)));
    const fraction = health / maxHealth;

    $("healthValue").textContent = String(Math.ceil(health));
    $("healthFill").style.width = (fraction * 100).toFixed(1) + "%";
    body.dataset.vitals = fraction <= .25 ? "critical" : fraction <= .5 ? "warn" : "ok";

    const armor = Math.max(0, num(payload.armor));
    const maxArmor = Math.max(armor, num(payload.maxArmor));
    body.dataset.armored = String(armor > 0);
    $("armorValue").textContent = String(Math.ceil(armor));
    $("armorFill").style.width = maxArmor > 0
      ? ((armor / maxArmor) * 100).toFixed(1) + "%" : "0%";
  }

  function renderAmmo(payload) {
    const magazine = Math.trunc(num(payload.magazine, -1));
    const reserve = Math.trunc(num(payload.reserve, -1));
    const capacity = Math.trunc(num(payload.capacity, -1));
    const known = payload.ammoKnown === true && magazine >= 0;
    const dash = T.t("combat.empty");

    $("magazineValue").textContent = known ? String(magazine) : dash;
    $("reserveValue").textContent = known && reserve >= 0 ? String(reserve) : dash;

    if (!known) { body.dataset.ammo = "unknown"; return; }
    const low = capacity > 0 ? magazine <= Math.max(2, Math.floor(capacity * .25)) : magazine <= 3;
    body.dataset.ammo = magazine === 0 ? "empty" : low ? "low" : "ok";
  }

  function renderProtection(payload) {
    const remaining = Math.max(0, num(payload.protectionMs));
    const total = Math.max(0, num(payload.protectionTotalMs));
    const shown = payload.protected === true;

    body.dataset.protected = String(shown);
    /* A server that has not wired the window yet still gets a ring, from the
     * god-mode flag on the health ledger -- but no number it cannot back. */
    body.dataset.protectionTimed = String(total > 0 && remaining > 0);

    if (total > 0) {
      const fraction = Math.max(0, Math.min(1, remaining / total));
      protectionSweep.style.strokeDashoffset = (RING * (1 - fraction)).toFixed(1);
    } else {
      protectionSweep.style.strokeDashoffset = shown ? "0" : String(RING);
    }
    protectionCount.textContent = (remaining / 1000).toFixed(1);
  }

  /* ---------------------------------------------------------------------- */
  /* Directional damage                                                     */
  /* ---------------------------------------------------------------------- */

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

  /* ---------------------------------------------------------------------- */
  /* Feedback                                                               */
  /* ---------------------------------------------------------------------- */

  function showHitmarker(payload) {
    hitmarker.classList.remove("show", "lethal", "headshot");
    if (payload && payload.lethal === true) hitmarker.classList.add("lethal");
    else if (payload && payload.bodyPart === "head") hitmarker.classList.add("headshot");
    /* Restart the animation even when hits land back to back. */
    void hitmarker.offsetWidth;
    hitmarker.classList.add("show");
    clearTimeout(hitTimer);
    hitTimer = setTimeout(() => hitmarker.classList.remove("show"), 360);
  }

  function showDamageFlash() {
    damageFlash.classList.remove("show");
    void damageFlash.offsetWidth;
    damageFlash.classList.add("show");
    clearTimeout(flashTimer);
    flashTimer = setTimeout(() => damageFlash.classList.remove("show"), 440);
  }

  /* The server sends a kind and a count. Every word comes from the table, so
   * "DOUBLE KILL" exists in exactly one file. */
  function calloutText(kind, count) {
    if (kind === "multi") {
      const exact = T.t("callout.multi." + count, "");
      return {
        title: exact || T.fmt("callout.multiGeneric", { count }),
        sub: T.fmt("callout.multiSub", { count }),
      };
    }
    if (kind === "streak") {
      const exact = T.t("callout.streak." + count, "");
      return {
        title: exact || T.fmt("callout.streakGeneric", { count }),
        sub: T.fmt("callout.streakSub", { count }),
      };
    }
    return { title: T.t("callout." + kind), sub: "" };
  }

  const calloutQueue = [];
  let calloutBusy = false;

  function drainCallouts() {
    if (calloutBusy) return;
    const next = calloutQueue.shift();
    if (!next) return;
    calloutBusy = true;
    calloutEl.dataset.kind = next.kind;
    $("calloutTitle").textContent = next.title;
    $("calloutSub").textContent = next.sub;
    calloutEl.classList.remove("show");
    void calloutEl.offsetWidth;
    calloutEl.classList.add("show");
    setTimeout(() => {
      calloutEl.classList.remove("show");
      calloutBusy = false;
      drainCallouts();
    }, 1500);
  }

  function queueCallout(payload) {
    const kind = String((payload && payload.kind) || "multi");
    const count = Math.trunc(num(payload && payload.count));
    const text = calloutText(kind, count);
    if (!text.title) return;
    calloutQueue.push({ kind, title: text.title, sub: text.sub });
    if (calloutQueue.length > 3) calloutQueue.shift();
    drainCallouts();
  }

  /* ---------------------------------------------------------------------- */
  /* Bridge                                                                 */
  /* ---------------------------------------------------------------------- */

  Open77.on("dm:strings", table => {
    T.set(table);
  });

  Open77.on("dm:combat", payload => {
    if (!payload || typeof payload !== "object") return;
    body.dataset.active = String(payload.active === true);
    body.dataset.alive = String(payload.alive !== false);
    body.dataset.crosshair = String(payload.crosshair !== false);
    body.dataset.team = String(Math.trunc(num(payload.team)));
    renderVitals(payload);
    renderAmmo(payload);
    renderProtection(payload);
    renderIndicators(payload.indicators);
  });

  Open77.on("dm:hit", showHitmarker);
  Open77.on("dm:damaged", showDamageFlash);
  Open77.on("dm:callout", queueCallout);

  Open77.ready();
  Open77.emit("dm:ready", {});
})();
