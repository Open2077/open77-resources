/* =============================================================================
   open77_vehiclepicker - page script
   =============================================================================

   Draws whatever `picker:state` carries and reports clicks. It holds no roster
   of its own, decides nothing, and never guesses a value it was not sent - an
   entry with no `launch5s` renders as "not measured", never as an estimated
   bar. See `shared/roster.lua` for why that restraint is the point.
   ========================================================================== */

(function () {
  "use strict";

  const body = document.body;
  const grid = document.getElementById("grid");
  const eyebrow = document.getElementById("eyebrow");
  const title = document.getElementById("title");
  const subtitle = document.getElementById("subtitle");
  const deadline = document.getElementById("deadline");
  const status = document.getElementById("status");
  const lockText = document.getElementById("lock-text");

  let entries = [];
  let selected = null;
  let cursor = 0;
  let statusTimer = null;

  const close = () => Open77.emit("picker:close", {});
  const pick = key => Open77.emit("picker:choose", { key: key });

  function setStatus(text, kind) {
    status.textContent = text || "";
    status.className = "status" + (kind ? " " + kind : "");
    if (statusTimer) { clearTimeout(statusTimer); statusTimer = null; }
    if (text) {
      statusTimer = setTimeout(() => {
        status.textContent = "";
        status.className = "status";
      }, 2400);
    }
  }

  /* A card. Selecting is instant-confirm on purpose: there is no separate
     CONFIRM button and therefore no way to close the panel having lost a pick.
     "What if the player never chooses" and "what if he closes without
     confirming" collapse into the same answer - the last thing he clicked is
     what he has, and if he clicked nothing he has the roster default. */
  function card(entry, index) {
    const el = document.createElement("button");
    el.type = "button";
    el.className = "card" + (entry.key === selected ? " selected" : "");
    el.dataset.key = entry.key;
    el.setAttribute("aria-pressed", entry.key === selected ? "true" : "false");

    const name = document.createElement("div");
    name.className = "name";
    name.textContent = entry.name || entry.key;
    el.appendChild(name);

    const meta = document.createElement("div");
    meta.className = "meta";
    meta.textContent = entry.maker || "";
    el.appendChild(meta);

    const tags = document.createElement("div");
    tags.className = "tags";
    if (entry.isDefault) { tags.appendChild(tag("DEFAULT", "default")); }
    if (entry.unverified) { tags.appendChild(tag("UNTESTED", "unverified")); }
    if (entry.note) { tags.appendChild(tag(entry.note, "")); }
    if (tags.childNodes.length) { el.appendChild(tags); }

    /* The launch figure, and only where one exists. `typeof` rather than a
       truthiness test: a genuine 0.0 would be a measurement, not an absence. */
    const bars = document.createElement("div");
    bars.className = "bars";
    const measured = typeof entry.launch5s === "number";
    bars.appendChild(bar("5s", measured ? entry.launch5s : null, measured ? "m" : ""));
    el.appendChild(bars);

    el.addEventListener("click", () => { cursor = index; pick(entry.key); });
    return el;
  }

  function tag(text, kind) {
    const el = document.createElement("span");
    el.className = "tag" + (kind ? " " + kind : "");
    el.textContent = text;
    return el;
  }

  /* One row. `value === null` means unmeasured and draws an empty track with an
     em dash - visibly different from a zero-length bar, which would read as
     "measured, and terrible". The scale is fixed at 100 m so two cards can be
     compared by eye; a figure beyond it clamps rather than rescaling the row. */
  function bar(label, value, unit) {
    const row = document.createElement("div");
    row.className = "bar";

    const name = document.createElement("span");
    name.textContent = label;
    row.appendChild(name);

    const track = document.createElement("span");
    track.className = "track";
    if (value !== null) {
      const fill = document.createElement("span");
      fill.className = "fill";
      fill.style.width = Math.max(0, Math.min(100, value)) + "%";
      track.appendChild(fill);
    }
    row.appendChild(track);

    const val = document.createElement("span");
    val.className = "val";
    val.textContent = value === null ? "—" : Math.round(value) + unit;
    row.appendChild(val);

    return row;
  }

  function render() {
    grid.textContent = "";
    if (!entries.length) {
      const empty = document.createElement("div");
      empty.className = "empty";
      empty.textContent = "No vehicles offered for this role.";
      grid.appendChild(empty);
      return;
    }
    entries.forEach((entry, index) => grid.appendChild(card(entry, index)));
  }

  function renderDeadline(remainingMs) {
    if (typeof remainingMs !== "number") {
      deadline.className = "deadline";
      deadline.textContent = "";
      return;
    }
    const seconds = Math.max(0, Math.ceil(remainingMs / 1000));
    deadline.textContent = seconds + "s";
    deadline.className = "deadline on" + (seconds <= 5 ? " urgent" : "");
  }

  /* ------------------------------------------------------------- keyboard --

     Arrows move, Enter picks, Escape closes. Escape is here for completeness
     and for a client where the plugin does not swallow it; the reliable close
     path in a live session is the Lua-side `open77:pauseKey` handler. Nothing
     here is the only way out of the panel - see client/main.lua. */
  document.addEventListener("keydown", event => {
    if (!body.classList.contains("open")) { return; }

    if (event.key === "Escape") { event.preventDefault(); close(); return; }

    if (!entries.length) { return; }

    if (event.key === "ArrowRight" || event.key === "ArrowDown") {
      event.preventDefault();
      cursor = (cursor + 1) % entries.length;
      focusCursor();
    } else if (event.key === "ArrowLeft" || event.key === "ArrowUp") {
      event.preventDefault();
      cursor = (cursor - 1 + entries.length) % entries.length;
      focusCursor();
    } else if (event.key === "Enter" || event.key === " ") {
      event.preventDefault();
      pick(entries[cursor].key);
    }
  });

  function focusCursor() {
    const cards = grid.querySelectorAll(".card");
    if (cards[cursor]) { cards[cursor].focus(); }
  }

  document.getElementById("close").addEventListener("click", close);
  document.getElementById("scrim").addEventListener("click", close);

  /* ---------------------------------------------------------------- bridge -- */

  Open77.on("picker:state", state => {
    if (!state) { return; }
    entries = Array.isArray(state.entries) ? state.entries : [];
    selected = state.selected || null;

    eyebrow.textContent = state.eyebrow || "LOADOUT";
    title.textContent = state.title || "Select vehicle";
    subtitle.textContent = [state.band, state.bandNote].filter(Boolean).join("  //  ");
    lockText.textContent = "The match has started. Your pick is saved for the next one.";
    body.classList.toggle("locked", state.locked === true);

    const at = entries.findIndex(e => e.key === selected);
    cursor = at >= 0 ? at : 0;

    render();
    renderDeadline(state.remainingMs);
  });

  Open77.on("picker:open", () => {
    body.classList.add("open");
    /* Focus the selected card so the first arrow press moves from where the
       eye already is, and so a keyboard-only player has a visible caret. */
    setTimeout(focusCursor, 0);
  });

  Open77.on("picker:closed", () => {
    body.classList.remove("open");
    setStatus("");
  });

  Open77.on("picker:result", payload => {
    if (!payload) { return; }
    setStatus(payload.text || "", payload.ok ? "ok" : "bad");
  });

  Open77.ready();
  Open77.emit("picker:ready", {});
})();
