/* OPEN//77 UI kit -- the single page behind every widget.
 *
 * Message routing, both directions, is two channels:
 *
 *   in   "uikit:apply"  { widget, action, token, spec }
 *   out  "uikit:event"  { widget, token, type, ... }
 *
 * `token` is minted by Lua on every open and echoed back on every event. This
 * file never invents one and never answers with a token it was not given, so a
 * click that raced a close cannot resolve whatever replaced it -- Lua drops a
 * token that is no longer live.
 *
 * This page holds keyboard and cursor focus only while a dialog is open. The
 * progress bar and the text hints are pointer-events:none and take nothing.
 *
 * The source is deliberately pure ASCII: a served .js without an explicit
 * charset is decoded as Latin-1, and a raw multi-byte glyph becomes mojibake.
 * Every non-ASCII character is a String.fromCharCode constant below.
 */
(() => {
  "use strict";

  const textRoot = document.getElementById("text");
  const progressRoot = document.getElementById("progress");
  const scrim = document.getElementById("scrim");
  const cinematicRoot = document.getElementById("cinematic");

  const MIDDOT = String.fromCharCode(0xB7);
  const CHEV_LEFT = String.fromCharCode(0x2039);
  const CHEV_RIGHT = String.fromCharCode(0x203A);
  const ARROWS = String.fromCharCode(0x2191, 0x2193);

  let dialog = null;      // { token, kind, spec, rows, active, submit }
  let progress = null;    // { token, spec, endsAt, timer }
  let cinematicTimer = null;

  const POSITIONS = new Set(["top", "center", "bottom"]);
  const clampPosition = value => (POSITIONS.has(value) ? value : "center");
  const text = value => (value === undefined || value === null ? "" : String(value));

  function emit(widget, token, type, extra) {
    Open77.emit("uikit:event", Object.assign({ widget, token, type }, extra || {}));
  }

  function el(tag, className, content) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (content !== undefined) node.textContent = text(content);
    return node;
  }

  function svgNode(tag) {
    return document.createElementNS("http://www.w3.org/2000/svg", tag);
  }

  /* ---------------------------------------------------------------------
     Cinematic bars -- no focus, no scrim, pointer-events:none. Lua keeps
     the surface visible for the length of the ease after a hide, so the
     slide out is actually seen; this side only has to unhide the element
     before the slide in and hide it again after the slide out.
     --------------------------------------------------------------------- */

  function clampNumber(value, fallback, low, high) {
    const number = Number(value);
    if (!Number.isFinite(number)) return fallback;
    return Math.min(high, Math.max(low, number));
  }

  function showCinematic(spec) {
    if (cinematicTimer) { clearTimeout(cinematicTimer); cinematicTimer = null; }
    const height = clampNumber(spec.heightPct, 12, 1, 40);
    const ease = clampNumber(spec.durationMs, 350, 0, 5000);
    cinematicRoot.style.setProperty("--bar-height", height + "vh");
    cinematicRoot.style.setProperty("--bar-ease", ease + "ms");
    cinematicRoot.style.setProperty("--bar-color", text(spec.color) || "#000000");
    cinematicRoot.hidden = false;
    // Two frames, not one: the element was display:none, and a transition
    // needs a painted starting state before the class flips or it snaps.
    requestAnimationFrame(() => requestAnimationFrame(() => {
      cinematicRoot.classList.add("shown");
    }));
  }

  function hideCinematic() {
    if (cinematicTimer) { clearTimeout(cinematicTimer); cinematicTimer = null; }
    if (cinematicRoot.hidden) return;
    cinematicRoot.classList.remove("shown");
    const ease = clampNumber(
      parseFloat(cinematicRoot.style.getPropertyValue("--bar-ease")), 350, 0, 5000);
    cinematicTimer = setTimeout(() => {
      cinematicTimer = null;
      cinematicRoot.hidden = true;
    }, ease + 50);
  }

  /* ---------------------------------------------------------------------
     Text hints -- no focus, no scrim, pointer-events:none
     --------------------------------------------------------------------- */

  function renderText(spec) {
    textRoot.replaceChildren();
    const slots = Array.isArray(spec && spec.slots) ? spec.slots : [];
    if (slots.length === 0) {
      textRoot.hidden = true;
      return;
    }
    const stacks = new Map();
    for (const slot of slots) {
      const position = clampPosition(slot && slot.position);
      let stack = stacks.get(position);
      if (!stack) {
        stack = el("div", "text-stack");
        stack.dataset.position = position;
        stacks.set(position, stack);
        textRoot.append(stack);
      }
      const hint = el("div", "hint");
      hint.style.setProperty("--accent", text(slot.color) || "#22D8E2");
      if (slot.icon) hint.append(el("span", "icon", slot.icon));
      const copy = el("div", "copy");
      if (slot.eyebrow) copy.append(el("span", "eyebrow", slot.eyebrow));
      copy.append(el("span", "body", slot.text));
      if (Array.isArray(slot.actions) && slot.actions.length > 0) {
        const row = el("span", "actions");
        for (const action of slot.actions.slice(0, 3)) {
          const item = el("span", "action");
          item.append(el("kbd", "keycap", text(action && action.key)), el("span", "label", text(action && action.label)));
          row.append(item);
        }
        copy.append(row);
      }
      hint.append(copy);
      if (slot.key) hint.append(el("kbd", "keycap", slot.key));
      stack.append(hint);
    }
    textRoot.hidden = false;
  }

  /* ---------------------------------------------------------------------
     Progress -- never takes focus. The player is held by the control
     surface; this is only the picture of it.
     --------------------------------------------------------------------- */

  function stopProgress() {
    if (progress && progress.timer) clearInterval(progress.timer);
    progress = null;
    progressRoot.replaceChildren();
    progressRoot.hidden = true;
  }

  function renderProgress(token, spec) {
    stopProgress();
    const duration = Number(spec.duration) || 1000;
    progressRoot.dataset.position = clampPosition(spec.position);

    const readout = el("span", null, "");
    const hintline = el("span", "hintline");
    hintline.append(readout);
    if (spec.cancellable) hintline.append(el("kbd", "keycap", spec.cancelKey || "X"));

    let host;
    if (spec.style === "circle") {
      host = el("div", "dial");
      const radius = 55;
      const circumference = 2 * Math.PI * radius;
      const svg = svgNode("svg");
      svg.setAttribute("viewBox", "0 0 118 118");
      const track = svgNode("circle");
      track.setAttribute("class", "ring-track");
      track.setAttribute("cx", "59");
      track.setAttribute("cy", "59");
      track.setAttribute("r", String(radius));
      track.setAttribute("fill", "none");
      track.setAttribute("stroke-width", "4");
      const fill = svgNode("circle");
      fill.setAttribute("class", "ring-fill");
      fill.setAttribute("cx", "59");
      fill.setAttribute("cy", "59");
      fill.setAttribute("r", String(radius));
      fill.setAttribute("fill", "none");
      fill.setAttribute("stroke-width", "4");
      fill.style.setProperty("--circumference", String(circumference));
      fill.style.setProperty("--duration", duration + "ms");
      svg.append(track, fill);
      const core = el("div", "core");
      core.append(el("span", "label", spec.label), hintline);
      host.append(svg, core);
    } else {
      host = el("div", "bar");
      const head = el("div", "head");
      head.append(el("span", "label", spec.label), hintline);
      const track = el("div", "track");
      const fill = el("i", "fill");
      fill.style.setProperty("--duration", duration + "ms");
      track.append(fill);
      host.append(head, track);
    }
    host.style.setProperty("--accent", text(spec.color) || "#22D8E2");
    progressRoot.append(host);
    progressRoot.hidden = false;

    const endsAt = Date.now() + duration;
    const tick = () => {
      const left = Math.max(0, endsAt - Date.now());
      readout.textContent = (left / 1000).toFixed(1) + "s";
      if (left <= 0 && progress) {
        clearInterval(progress.timer);
        progress.timer = null;
        // Lua owns the deadline and normally settles first. This is the second
        // path, and a stale token makes a double answer harmless.
        emit("progress", token, "progressDone");
      }
    };
    progress = { token, spec, endsAt, timer: setInterval(tick, 100) };
    tick();
  }

  /* ---------------------------------------------------------------------
     Dialogs -- the only things on this page that take focus
     --------------------------------------------------------------------- */

  function closeDialog() {
    dialog = null;
    scrim.replaceChildren();
    scrim.hidden = true;
  }

  function panelHead(spec, eyebrowText) {
    const header = el("header");
    header.append(el("span", "eyebrow", eyebrowText));
    header.append(el("h1", null, spec.title));
    if (spec.description || spec.message) {
      header.append(el("p", "sub", spec.description || spec.message));
    }
    return header;
  }

  function buildPanel(spec, eyebrowText) {
    const panel = el("section", "panel rule");
    if (spec.size === "large") panel.classList.add("large");
    panel.setAttribute("role", "dialog");
    panel.setAttribute("aria-modal", "true");
    panel.tabIndex = -1;
    panel.append(panelHead(spec, eyebrowText));
    return panel;
  }

  function legend(pairs) {
    const wrap = el("div", "legend");
    pairs.forEach((pair, index) => {
      if (index > 0) wrap.append(el("span", null, MIDDOT));
      wrap.append(el("kbd", "keycap", pair[0]), el("span", null, pair[1]));
    });
    return wrap;
  }

  /* --- alert --- */

  function renderAlert(token, spec) {
    const panel = buildPanel(spec, spec.tone === "danger" ? "Warning" : "Confirm");
    if (spec.tone === "danger") panel.style.setProperty("--accent", "#FF5C5C");
    else if (spec.tone === "warning") panel.style.setProperty("--accent", "#F5C95C");
    else if (spec.tone === "success") panel.style.setProperty("--accent", "#4FE3A9");

    const footer = el("footer");
    footer.append(legend([["ENTER", "confirm"], ["ESC", "cancel"]]));
    if (spec.cancel) {
      const cancel = el("button", "btn", spec.cancel);
      cancel.type = "button";
      cancel.addEventListener("click", () => emit("dialog", token, "cancel"));
      footer.append(cancel);
    }
    const confirm = el("button", "btn primary", spec.confirm);
    confirm.type = "button";
    if (spec.tone === "danger") confirm.classList.add("danger");
    confirm.addEventListener("click", () => emit("dialog", token, "confirm"));
    footer.append(confirm);
    panel.append(footer);
    scrim.append(panel);
    requestAnimationFrame(() => confirm.focus());
  }

  /* --- input --- */

  function fieldValue(field, node) {
    if (field.type === "checkbox") return node.dataset.on === "1";
    if (field.type === "slider" || field.type === "number") {
      const raw = Number(node.value);
      return Number.isFinite(raw) ? raw : null;
    }
    if (field.type === "select") return node.dataset.value || null;
    return node.value;
  }

  function fieldError(field, value) {
    if (field.type === "checkbox") return null;
    if (field.type === "select") return value ? null : "Pick one.";
    if (field.type === "number" || field.type === "slider") {
      if (value === null) return field.required ? "A number is required." : null;
      if (value < field.min || value > field.max) {
        return "Between " + field.min + " and " + field.max + ".";
      }
      return null;
    }
    const length = text(value).length;
    if (field.required && length === 0) return "Required.";
    if (length > 0 && field.min && length < field.min) {
      return "At least " + field.min + " characters.";
    }
    if (field.max && length > field.max) return "At most " + field.max + " characters.";
    return null;
  }

  function buildField(field) {
    const wrap = el("div", "field");
    const label = el("label", null, field.label);
    label.htmlFor = "f-" + field.id;
    wrap.append(label);
    if (field.description) wrap.append(el("p", "desc", field.description));

    let node;
    if (field.type === "textarea") {
      node = el("textarea");
      node.value = text(field.default);
      if (field.placeholder) node.placeholder = field.placeholder;
      if (field.max) node.maxLength = field.max;
      wrap.append(node);
    } else if (field.type === "checkbox") {
      node = el("div", "toggle");
      node.setAttribute("role", "checkbox");
      node.tabIndex = 0;
      const box = el("span", "check");
      box.dataset.on = field.default ? "1" : "0";
      node.dataset.on = box.dataset.on;
      node.setAttribute("aria-checked", field.default ? "true" : "false");
      node.append(box, el("span", "body", field.label));
      const toggle = () => {
        node.dataset.on = node.dataset.on === "1" ? "0" : "1";
        box.dataset.on = node.dataset.on;
        node.setAttribute("aria-checked", node.dataset.on === "1" ? "true" : "false");
      };
      node.addEventListener("click", toggle);
      node.addEventListener("keydown", event => {
        if (event.key === " " || event.key === "Enter") {
          event.preventDefault();
          toggle();
        }
      });
      wrap.append(node);
    } else if (field.type === "slider") {
      node = el("input");
      node.type = "range";
      node.min = String(field.min);
      node.max = String(field.max);
      node.step = String(field.step || 1);
      node.value = String(field.default === undefined || field.default === null
        ? field.min : field.default);
      const out = el("output", null, node.value);
      node.addEventListener("input", () => { out.textContent = node.value; });
      const row = el("div", "slider");
      row.append(node, out);
      wrap.append(row);
    } else if (field.type === "select") {
      // Custom listbox. The native dropdown popup does not render reliably in
      // the CEF compositor, and the server suite asserts that none ships.
      node = el("div", "listbox");
      node.setAttribute("role", "listbox");
      node.setAttribute("aria-label", field.label);
      node.dataset.value = text(field.default);
      for (const option of field.options) {
        const button = el("button", "opt", option.label);
        button.type = "button";
        button.setAttribute("role", "option");
        button.dataset.value = option.value;
        button.setAttribute("aria-selected", option.value === field.default ? "true" : "false");
        button.addEventListener("click", () => {
          node.dataset.value = option.value;
          for (const sibling of node.children) {
            sibling.setAttribute("aria-selected",
              sibling.dataset.value === option.value ? "true" : "false");
          }
        });
        node.append(button);
      }
      wrap.append(node);
    } else {
      node = el("input");
      node.type = field.type === "password" ? "password"
        : field.type === "number" ? "number" : "text";
      if (field.type === "number") {
        node.min = String(field.min);
        node.max = String(field.max);
        node.step = String(field.step || 1);
      } else if (field.max) {
        node.maxLength = field.max;
      }
      if (field.default !== undefined && field.default !== null) node.value = String(field.default);
      if (field.placeholder) node.placeholder = field.placeholder;
      wrap.append(node);
    }

    node.id = "f-" + field.id;
    const error = el("p", "err");
    error.hidden = true;
    wrap.append(error);
    return { wrap, node, error };
  }

  function renderInput(token, spec) {
    const panel = buildPanel(spec, "Input");
    const content = el("div", "content");
    const nodes = [];

    for (const field of spec.fields) {
      const built = buildField(field);
      content.append(built.wrap);
      nodes.push({ field, node: built.node, error: built.error });
    }

    const submit = () => {
      const values = {};
      let bad = false;
      for (const entry of nodes) {
        const value = fieldValue(entry.field, entry.node);
        const message = fieldError(entry.field, value);
        entry.error.textContent = message || "";
        entry.error.hidden = !message;
        if (message) { bad = true; continue; }
        values[entry.field.id] = value;
      }
      if (bad) return;
      // Indexed as well as keyed: a caller that wrote its fields in order can
      // read them back in order without having invented ids.
      nodes.forEach((entry, index) => { values[index + 1] = values[entry.field.id]; });
      emit("dialog", token, "submit", { values });
    };

    const footer = el("footer");
    footer.append(legend([["ENTER", "confirm"], ["ESC", "cancel"]]));
    const cancel = el("button", "btn", spec.cancel);
    cancel.type = "button";
    cancel.addEventListener("click", () => emit("dialog", token, "cancel"));
    const confirm = el("button", "btn primary", spec.confirm);
    confirm.type = "button";
    confirm.addEventListener("click", submit);
    footer.append(cancel, confirm);

    panel.append(content, footer);
    scrim.append(panel);
    dialog.submit = submit;
    if (nodes.length > 0) requestAnimationFrame(() => nodes[0].node.focus());
  }

  /* --- context and menu: option rows --- */

  function rowValues() {
    const values = {};
    for (const row of scrim.querySelectorAll(".row[data-option]")) {
      if (row.dataset.checked !== undefined) {
        values[row.dataset.option] = row.dataset.checked === "1";
      } else if (row.dataset.index !== undefined) {
        values[row.dataset.option] = Number(row.dataset.index);
      }
    }
    return values;
  }

  function optionOf(id) {
    const options = (dialog && dialog.spec && dialog.spec.options) || [];
    for (const option of options) {
      if (option.id === id) return option;
    }
    return null;
  }

  function activate(token, row, option) {
    if (!row || !option || row.getAttribute("aria-disabled") === "true") return;
    if (row.dataset.checked !== undefined) {
      // A checkbox row toggles in place and does NOT resolve the dialog. Its
      // state leaves with whatever finally does -- a picked row, or the close,
      // which carries `values` for exactly this reason.
      row.dataset.checked = row.dataset.checked === "1" ? "0" : "1";
      const box = row.querySelector(".check");
      if (box) box.dataset.on = row.dataset.checked;
      return;
    }
    emit("dialog", token, "select", { optionId: option.id, values: rowValues() });
  }

  function sideScroll(row, direction) {
    if (!row || row.dataset.index === undefined) return;
    const option = optionOf(row.dataset.option);
    if (!option || !Array.isArray(option.values)) return;
    let index = Number(row.dataset.index) + direction;
    if (index < 1) index = option.values.length;
    if (index > option.values.length) index = 1;
    row.dataset.index = String(index);
    const node = row.querySelector('[data-role="value"]');
    if (node) node.textContent = option.values[index - 1];
  }

  function highlight() {
    if (!dialog || !dialog.rows) return;
    dialog.rows.forEach((row, index) => row.classList.toggle("active", index === dialog.active));
    const row = dialog.rows[dialog.active];
    if (row && row.scrollIntoView) row.scrollIntoView({ block: "nearest" });
  }

  function buildRow(token, option) {
    const row = el("button", "row");
    row.type = "button";
    row.dataset.option = option.id;
    if (option.tone) row.classList.add(option.tone);
    if (option.disabled) row.setAttribute("aria-disabled", "true");
    row.append(option.icon ? el("span", "icon", option.icon) : el("span"));

    const body = el("div", "text");
    body.append(el("span", "title", option.label));
    if (option.description) body.append(el("span", "desc", option.description));
    row.append(body);

    const trail = el("div", "trail");
    if (option.checked !== undefined && option.checked !== null) {
      row.dataset.checked = option.checked ? "1" : "0";
      const box = el("span", "check");
      box.dataset.on = row.dataset.checked;
      trail.append(box);
    } else if (Array.isArray(option.values)) {
      row.dataset.index = String(option.index || 1);
      const value = el("span", null, option.values[(option.index || 1) - 1]);
      value.dataset.role = "value";
      trail.append(el("span", null, CHEV_LEFT), value, el("span", null, CHEV_RIGHT));
    } else if (option.menu) {
      trail.append(el("span", null, CHEV_RIGHT));
    }
    row.append(trail);

    if (option.metadata) {
      const meta = el("div", "meta");
      for (const entry of option.metadata) {
        const cell = el("span");
        cell.append(el("b", null, entry.label));
        if (entry.value) cell.append(document.createTextNode(" " + entry.value));
        meta.append(cell);
      }
      row.append(meta);
    }

    row.addEventListener("click", () => activate(token, row, option));
    return row;
  }

  function renderRows(token, spec, keyboard) {
    const panel = buildPanel(spec, spec.kind === "menu" ? "Menu" : "Options");
    const content = el("div", "content");
    const rows = el("div", "rows");
    for (const option of spec.options) rows.append(buildRow(token, option));
    content.append(rows);

    const footer = el("footer");
    footer.append(legend(keyboard
      ? [[ARROWS, "move"], ["ENTER", "pick"], ["ESC", "close"]]
      : [["ESC", "close"]]));
    if (spec.canGoBack) {
      const back = el("button", "btn", "Back");
      back.type = "button";
      back.addEventListener("click", () => emit("dialog", token, "back"));
      footer.append(back);
    }
    const close = el("button", "btn", "Close");
    close.type = "button";
    // Closing a row menu carries its checkbox and side-scroll state with it. A
    // settings menu made only of toggles has no row that "picks" anything, so
    // without this its values could never reach Lua at all.
    close.addEventListener("click", () => emit("dialog", token, "cancel", { values: rowValues() }));
    footer.append(close);

    panel.append(content, footer);
    scrim.append(panel);

    dialog.rows = Array.prototype.slice.call(rows.children);
    dialog.active = dialog.rows.findIndex(row => row.getAttribute("aria-disabled") !== "true");
    highlight();
    requestAnimationFrame(() => panel.focus());
  }

  /* --- radial --- */

  function renderRadial(token, spec) {
    const wheel = el("div", "radial");
    const options = spec.options.slice(0, 8);
    const count = options.length;
    const svg = svgNode("svg");
    svg.setAttribute("viewBox", "0 0 380 380");
    const centre = 190;
    const inner = 68;
    const outer = 184;
    const gap = 0.03;
    const slice = (Math.PI * 2) / count;

    const point = (radius, angle) => [
      (centre + radius * Math.cos(angle)).toFixed(2),
      (centre + radius * Math.sin(angle)).toFixed(2),
    ];

    options.forEach((option, index) => {
      const start = -Math.PI / 2 + index * slice + gap;
      const end = start + slice - gap * 2;
      const a = point(inner, start);
      const b = point(outer, start);
      const c = point(outer, end);
      const d = point(inner, end);
      const large = slice - gap * 2 > Math.PI ? 1 : 0;
      const path = svgNode("path");
      path.setAttribute("class", "sector");
      path.setAttribute("d",
        "M " + a[0] + " " + a[1] + " L " + b[0] + " " + b[1] +
        " A " + outer + " " + outer + " 0 " + large + " 1 " + c[0] + " " + c[1] +
        " L " + d[0] + " " + d[1] +
        " A " + inner + " " + inner + " 0 " + large + " 0 " + a[0] + " " + a[1] + " Z");
      if (option.disabled) path.setAttribute("aria-disabled", "true");
      path.addEventListener("click", () => {
        if (option.disabled) return;
        emit("dialog", token, "select", { optionId: option.id });
      });
      svg.append(path);

      const middle = start + (slice - gap * 2) / 2;
      const glyphAt = point((inner + outer) / 2 - 10, middle);
      const nameAt = point((inner + outer) / 2 + 12, middle);
      const spoke = svgNode("g");
      spoke.setAttribute("class", "spoke");
      if (option.icon) {
        const glyph = svgNode("text");
        glyph.setAttribute("class", "glyph");
        glyph.setAttribute("x", glyphAt[0]);
        glyph.setAttribute("y", glyphAt[1]);
        glyph.textContent = option.icon;
        spoke.append(glyph);
      }
      const name = svgNode("text");
      name.setAttribute("class", "name");
      name.setAttribute("x", nameAt[0]);
      name.setAttribute("y", nameAt[1]);
      name.textContent = option.label;
      spoke.append(name);
      svg.append(spoke);
    });

    const hub = el("div", "hub");
    hub.append(el("span", "eyebrow", "Radial"), el("span", "title", spec.title));
    wheel.append(svg, hub);
    scrim.append(wheel);
  }

  /* --- dispatch --- */

  function openDialog(token, spec) {
    closeDialog();
    dialog = { token, kind: spec.kind, spec, rows: null, active: -1, submit: null };
    scrim.dataset.position = clampPosition(spec.position);
    scrim.hidden = false;
    if (spec.kind === "alert") renderAlert(token, spec);
    else if (spec.kind === "input") renderInput(token, spec);
    else if (spec.kind === "radial") renderRadial(token, spec);
    else renderRows(token, spec, spec.kind === "menu");
  }

  // Clicking off a browse-shaped dialog closes it. Deliberately NOT wired for
  // `alert` or `input`: a stray click that throws away a filled-in form is
  // worse than one more deliberate press. One listener for the life of the
  // page rather than one per open, so repeated opens cannot stack handlers.
  scrim.addEventListener("click", event => {
    if (event.target !== scrim || !dialog) return;
    if (dialog.kind === "alert" || dialog.kind === "input") return;
    emit("dialog", dialog.token, "cancel", dialog.rows ? { values: rowValues() } : null);
  });

  /* ---------------------------------------------------------------------
     Keyboard
     --------------------------------------------------------------------- */

  document.addEventListener("keydown", event => {
    if (!dialog) return;
    const token = dialog.token;
    if (event.key === "Escape") {
      // In a live session the plugin swallows Escape in the window procedure
      // and Lua cancels on `open77:pauseKey` instead. This path is what makes
      // the page behave correctly everywhere else, and a double cancel is
      // harmless -- the second one carries a dead token.
      event.preventDefault();
      emit("dialog", token, "cancel", dialog.rows ? { values: rowValues() } : null);
      return;
    }
    if (event.key === "Enter") {
      if (dialog.kind === "alert") {
        event.preventDefault();
        emit("dialog", token, "confirm");
        return;
      }
      if (dialog.kind === "input") {
        if (event.target && event.target.tagName === "TEXTAREA") return;
        event.preventDefault();
        if (dialog.submit) dialog.submit();
        return;
      }
      if (dialog.rows && dialog.active >= 0) {
        event.preventDefault();
        const row = dialog.rows[dialog.active];
        if (row) activate(token, row, optionOf(row.dataset.option));
      }
      return;
    }
    if (!dialog.rows) return;
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      const step = event.key === "ArrowDown" ? 1 : -1;
      const total = dialog.rows.length;
      for (let hop = 1; hop <= total; hop += 1) {
        const next = ((dialog.active + step * hop) % total + total) % total;
        if (dialog.rows[next].getAttribute("aria-disabled") !== "true") {
          dialog.active = next;
          break;
        }
      }
      highlight();
      return;
    }
    if (event.key === "ArrowLeft" || event.key === "ArrowRight") {
      const row = dialog.rows[dialog.active];
      if (row && row.dataset.index !== undefined) {
        event.preventDefault();
        sideScroll(row, event.key === "ArrowRight" ? 1 : -1);
      }
      return;
    }
    if (event.key === "Backspace" && dialog.spec.canGoBack) {
      event.preventDefault();
      emit("dialog", token, "back");
    }
  });

  /* ---------------------------------------------------------------------
     The inbound channel
     --------------------------------------------------------------------- */

  Open77.on("uikit:apply", message => {
    if (!message || typeof message !== "object") return;
    const token = Number(message.token);
    if (message.widget === "text") {
      renderText(message.spec);
      return;
    }
    if (message.widget === "cinematic") {
      if (message.action === "show") showCinematic(message.spec || {});
      else hideCinematic();
      return;
    }
    if (message.widget === "progress") {
      if (message.action === "open") renderProgress(token, message.spec || {});
      else if (!progress || progress.token === token) stopProgress();
      return;
    }
    if (message.widget === "dialog") {
      if (message.action === "open") openDialog(token, message.spec || {});
      else if (!dialog || dialog.token === token) closeDialog();
    }
  });

  Open77.ready();
  Open77.emit("uikit:event", { type: "ready" });
})();
