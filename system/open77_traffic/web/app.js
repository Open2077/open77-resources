/* open77_traffic -- the /traffic admin panel.
 *
 * This page holds no authority. It renders the server's snapshots and turns
 * operator intent into exactly one outbound verb:
 *
 *     Open77.emit("traffic:command", { tokens: ["traffic", "set", "key", "value"] })
 *
 * which the client resource rebuilds from a whitelist and submits as the
 * restricted `traffic` command -- the same ACL-checked path the chat box uses.
 * There is no second path, and adding one would be adding a hole.
 *
 * Behaviours that are deliberate rather than accidental:
 *
 *   * A number edit is a draft until APPLY, and the two-second refresh never
 *     overwrites it. APPLY sends every draft at once (one `set` line each);
 *     an on/off switch is sent the moment it is pressed.
 *   * Nothing is shown that the server did not say. An empty table means the
 *     server reported no cars, not that the page failed to ask, and a control
 *     whose command the server refused says so instead of looking live.
 */
(function () {
  "use strict";

  /* ------------------------------------------------------- failure reporting */
  // CEF console output does not reach the game log, and the WebUI bridge
  // swallows an exception thrown inside an `Open77.on` handler, so a broken
  // page on this surface is otherwise completely invisible. Those, plus
  // anything thrown while rendering, go to the client resource's log through
  // `traffic:diag`: a log line, never a command.
  var diagnostics = 0;
  var reporting = false;

  function describe(value) {
    try {
      if (value instanceof Error) {
        return (value.name || "Error") + ": " + value.message + (value.stack
          ? " | " + String(value.stack).split(String.fromCharCode(10)).join(" <- ").slice(0, 300)
          : "");
      }
      if (value === null || value === undefined) return String(value);
      if (typeof value === "object") return Object.prototype.toString.call(value);
      return String(value);
    } catch (ignored) {
      return "<undescribable>";
    }
  }

  var bridge = window.Open77 || null;

  function emit(event, payload) {
    if (!bridge || typeof bridge.emit !== "function") {
      setStatus("No UI bridge on this page: nothing can reach the game.", "bad");
      return false;
    }
    try {
      bridge.emit("traffic:" + event, payload || {});
      return true;
    } catch (error) {
      setStatus("Could not send " + event + ": " + describe(error), "bad");
      return false;
    }
  }

  function report(text) {
    // Re-entrancy matters: emitting reports its own failures through this path.
    if (reporting || diagnostics >= 40) return;
    reporting = true;
    diagnostics += 1;
    try {
      if (bridge && typeof bridge.emit === "function") {
        bridge.emit("traffic:diag", { message: String(text).slice(0, 500) });
      }
    } catch (ignored) { /* nowhere left to complain to */ }
    reporting = false;
  }

  function on(event, handler) {
    if (!bridge || typeof bridge.on !== "function") return;
    bridge.on("traffic:" + event, function (payload) {
      try {
        handler(payload || {});
      } catch (error) {
        report(error && (error.stack || error.message) || String(error));
      }
    });
  }

  window.addEventListener("error", function (event) { report(event.message); });
  window.addEventListener("unhandledrejection", function (event) {
    report("unhandled rejection: " + describe(event.reason));
  });

  /* ------------------------------------------------------------------ helpers */
  // Lua sends `{}` for an empty list as well as an empty map, and `{}` is truthy,
  // so every list crossing the bridge goes through here or `.length` reads
  // undefined and the render aborts.
  function list(value) { return Array.isArray(value) ? value : []; }

  function num(value) {
    var n = typeof value === "number" ? value : Number(value);
    return isFinite(n) ? n : null;
  }

  function truthy(value) { return value === true || value === 1 || value === "true"; }

  function shown(value) {
    if (value === null || value === undefined || value === "") return "—";
    return String(value);
  }

  function fmt(value) {
    var n = num(value);
    if (n === null) return "—";
    if (n % 1 === 0 && Math.abs(n) < 1e15) return n.toLocaleString("en-US");
    return String(Math.round(n * 100) / 100);
  }

  function whole(value) {
    var n = num(value);
    return n === null ? "—" : Math.round(n).toLocaleString("en-US");
  }

  function plural(count, one, many) { return fmt(count) + " " + (count === 1 ? one : many); }

  // Durations are declared in ms or s, and 3600000 ms is not a number anybody
  // reads at a glance, so ranges, defaults and drafts are also said in the
  // largest unit that keeps them short. The field itself keeps the raw unit:
  // that is what the server takes.
  function duration(value, unit) {
    var n = num(value);
    if (n === null || (unit !== "ms" && unit !== "s")) return null;
    var ms = unit === "s" ? n * 1000 : n;
    if (ms < 1000) return fmt(ms) + " ms";
    var s = ms / 1000;
    if (s < 60) return fmt(Math.round(s * 10) / 10) + " s";
    if (s < 3600) return fmt(Math.round(s / 6) / 10) + " min";
    return fmt(Math.round(s / 360) / 10) + " h";
  }

  // Reasons and failures cross the bridge as short snake_case codes. Only the
  // ones this panel can say something true about are expanded; everything else
  // is shown exactly as the server wrote it.
  var EXPLAINED = {
    invalid_command: "the client refused that command: it was outside the panel's whitelist.",
    not_sent: "the command was not sent — the client has no transport to the server.",
    unsupported_pattern: "the car's record does not support that mode.",
    component_unavailable: "the car has no crowd member to change.",
    native_rejected: "the game refused the change for that car.",
    no_driver: "the car has no driver to change.",
    unknown_pattern: "that mode is not one this generator knows.",
    panic_unsupported_task: "the car is not enrolled in traffic, so it cannot panic.",
    traffic_panic_inactive: "the car's traffic task is not running."
  };

  function explain(message) {
    if (!message) return "no reason given";
    return EXPLAINED[message] || message;
  }

  // The same reasons again, in two or three words for a table cell.
  var REASONS = {
    unsupported_pattern: "mode unsupported",
    component_unavailable: "no crowd member",
    native_rejected: "game refused",
    no_driver: "no driver",
    unknown_pattern: "unknown mode",
    // Panic outcomes: why a request did not (or no longer does) run.
    join_unreleased: "lane not released",
    command_unreleased: "command not released",
    not_executing: "never started",
    application_timeout: "not applied in time",
    duration_elapsed: "finished",
    pattern_changed: "mode changed",
    unsupported_vehicle: "vehicle unsupported"
  };

  function reasonText(token) {
    var key = String(token);
    return REASONS[key] || key.replace(/_/g, " ").slice(0, 40);
  }

  var MODE_NAMES = { "default": "normal", stop: "stop", panic: "panic" };
  function modeName(pattern) { return MODE_NAMES[pattern] || String(pattern || "—"); }

  // A server message on the reset path stands alone: the server's own words
  // already name the case, and a prefix from this page would say "reset" a
  // second time. Only a bare transport token needs a subject.
  function resetFailureText(message) {
    var text = explain(message);
    if (/^[a-z0-9_]+$/.test(text)) return "Reset failed — " + text.replace(/_/g, " ");
    return text;
  }

  function el(tag, className, value) {
    var node = document.createElement(tag);
    if (className) node.className = className;
    if (value !== undefined) node.textContent = value;
    return node;
  }

  function clear(node) { while (node.firstChild) node.removeChild(node.firstChild); }

  /* -------------------------------------------------------------------- state */
  var POLL_HINT_MS = 10000;    // past this a pending command is described as unanswered
  var PENDING_GIVE_UP_MS = 30000;
  var APPLIED_HOLD_MS = 3000;  // how long an applied value outranks a stale snapshot
  var LIVE_MS = 6000;          // a snapshot younger than this is "live" (the poll is 2 s)
  var MASTER_KEY = "enabled";  // mounted on the overview rather than in its group

  function byId(id) { return document.getElementById(id); }

  var els = {
    badge: byId("badge-state"),
    close: byId("close"),
    scrim: byId("scrim"),
    tabs: document.querySelectorAll(".tab"),
    settingsDot: byId("settings-dot"),
    blocked: byId("blocked"),
    master: byId("master"),
    statActive: byId("stat-active"),
    statNear: byId("stat-near"),
    statNearLabel: byId("stat-near-label"),
    statDrivers: byId("stat-drivers"),
    statsNote: byId("stats-note"),
    settingsNote: byId("settings-note"),
    groups: byId("groups"),
    radiusForm: byId("radius-form"),
    radius: byId("radius"),
    radiusGo: byId("radius-go"),
    nearbyCount: byId("nearby-count"),
    patterns: byId("patterns"),
    patternCounts: byId("pattern-counts"),
    table: document.querySelector("#nearby tbody"),
    resetAsk: byId("reset-ask"),
    resetConfirm: byId("reset-confirm"),
    resetGo: byId("reset-go"),
    resetCancel: byId("reset-cancel"),
    savebar: byId("savebar"),
    savebarCount: byId("savebar-count"),
    discard: byId("discard"),
    applyAll: byId("apply-all"),
    live: byId("live"),
    toast: byId("toast")
  };

  var open = false;
  var rows = {};            // setting key -> row record, in the server's order
  var order = [];           // setting keys, in the server's order
  var groups = {};          // group label -> { box, body }
  var radius = 100;
  var radiusDirty = false;
  var pending = null;       // { operation, at } for state, pattern and reset
  var batch = null;         // { keys, saved, failed } for the `set` lines in flight
  var blocked = null;       // transport refusal, e.g. permission_denied
  var dataAt = 0;
  var confirmReset = false;
  var lastPattern = null;   // what the last mode request asked for
  var toastTimer = 0;

  /* ------------------------------------------------------------------ status  */
  // Results and errors are a toast beside the drawer, as on /freeroam; the
  // footer carries the one thing that is always true: how live the panel is.
  function setStatus(value, tone) {
    els.toast.textContent = String(value);
    els.toast.className = "toast show" + (tone === "bad" ? " error" : tone === "good" ? " good" : "");
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { els.toast.classList.remove("show"); },
      tone === "bad" ? 9000 : 5000);
  }

  function savingCount() {
    var count = 0;
    order.forEach(function (key) { if (rows[key].saving) count += 1; });
    return count;
  }

  function renderLive() {
    var text, tone = "";
    if (blocked) {
      text = "NO ACCESS"; tone = "bad";
    } else if (pending || savingCount()) {
      tone = "busy";
      text = pending && Date.now() - pending.at > POLL_HINT_MS ? "NO ANSWER YET" : "WORKING…";
    } else if (!dataAt) {
      text = "WAITING FOR SERVER";
    } else {
      var age = Math.max(0, Math.round((Date.now() - dataAt) / 1000));
      if (age * 1000 < LIVE_MS) { text = "LIVE"; tone = "ok"; }
      else { text = "LAST UPDATE " + age + "S AGO"; tone = "busy"; }
    }
    els.live.className = "live" + (tone ? " " + tone : "");
    els.live.textContent = text;
  }

  // A refused command takes every mutation with it, so the controls say so
  // instead of looking live and doing nothing.
  function setBlocked(message) {
    if (blocked) return;
    blocked = message;
    document.body.classList.add("blocked");
    els.blocked.textContent = message;
    els.blocked.hidden = false;
    order.forEach(function (key) { releaseSaving(rows[key]); });
    batch = null;
    cancelReset();
    pending = null;
    renderLive();
  }

  /* --------------------------------------------------------------------- tabs */
  function selectTab(name, focus) {
    for (var index = 0; index < els.tabs.length; index += 1) {
      var tab = els.tabs[index];
      var active = tab.dataset.tab === name;
      tab.classList.toggle("active", active);
      tab.setAttribute("aria-selected", active ? "true" : "false");
      tab.tabIndex = active ? 0 : -1;
      byId("page-" + tab.dataset.tab).classList.toggle("active", active);
      if (active && focus) tab.focus();
    }
  }

  /* ---------------------------------------------------------------- settings  */
  function controlKind(entry) {
    var type = String(entry.type || "").toLowerCase();
    if (type === "boolean" || type === "bool") return "boolean";
    if (type === "number" || type === "integer" || type === "int"
      || type === "float" || type === "decimal") return "number";
    // An unknown type is rendered from the shape of its own default rather than
    // guessed into a numeric box it may not be. The server is the only
    // validator that counts.
    if (typeof entry.default === "boolean") return "boolean";
    if (typeof entry.default === "number") return "number";
    return "text";
  }

  function label(row) { return String(row.entry.label || row.key); }

  // The field already shows the unit, so the meta line under it does not.
  function shortValue(entry, value) {
    if (controlKind(entry) === "boolean") return truthy(value) ? "on" : "off";
    return duration(value, entry.unit) || fmt(value);
  }

  function valueText(entry, value) {
    var short = shortValue(entry, value);
    return duration(value, entry.unit) || !entry.unit || controlKind(entry) === "boolean"
      ? short : short + " " + entry.unit;
  }

  function rangeText(entry) {
    var min = num(entry.min), max = num(entry.max);
    var say = function (value) { return shortValue(entry, value); };
    if (min === null && max === null) return null;
    if (min === null) return "up to " + say(max);
    if (max === null) return "from " + say(min);
    return say(min) + "–" + say(max);
  }

  function serverText(row) {
    return row.server === null || row.server === undefined ? "" : String(row.server);
  }

  function metaText(row) {
    var entry = row.entry;
    if (row.saving) return "saving…";
    if (row.kind === "boolean") return "";
    if (row.edited) {
      var draft = row.kind === "number" ? duration(desiredText(row), entry.unit) : null;
      return (draft ? "= " + draft + " · " : "") + "was " + shortValue(entry, row.server);
    }
    var range = rangeText(entry);
    return (range ? range + " · " : "") + "default " + shortValue(entry, entry.default);
  }

  function ensureGroup(name) {
    if (groups[name]) return groups[name];
    var box = el("section", "group");
    var head = el("div", "section-head");
    head.appendChild(el("h2", null, name));
    box.appendChild(head);
    var body = el("div", "group-body");
    box.appendChild(body);
    els.groups.appendChild(box);
    groups[name] = { box: box, body: body };
    return groups[name];
  }

  function markClean(row) {
    row.error = null;
    row.root.classList.remove("invalid");
    row.errorNode.hidden = true;
  }

  function buildSwitch(row) {
    var wrap = el("div", "seg");
    wrap.setAttribute("role", "group");
    wrap.setAttribute("aria-labelledby", "set-label-" + row.key);
    row.buttons = {};
    [["true", "ON"], ["false", "OFF"]].forEach(function (pair) {
      var button = el("button", null, pair[1]);
      button.type = "button";
      button.dataset.value = pair[0];
      // A switch has nothing to draft: pressing it is the whole intent, so it
      // is sent at once and shows "saving" until the server answers.
      button.addEventListener("click", function () {
        var wanted = pair[0] === "true";
        if (blocked || row.saving || wanted === truthy(row.server)) return;
        row.value = wanted;
        row.touched = true;
        markClean(row);
        applyRows([row]);
      });
      row.buttons[pair[0]] = button;
      wrap.appendChild(button);
    });
    return wrap;
  }

  function buildInput(row) {
    var entry = row.entry;
    var field = el("span", "field");
    var input = el("input");
    // A text box, not type=number: a number box turns "12a" into "" before
    // this page can say what is wrong with it, and grows spinner arrows the
    // rest of the house does not have.
    input.type = "text";
    input.inputMode = row.kind === "number" ? "decimal" : "text";
    input.autocomplete = "off";
    input.spellcheck = false;
    input.maxLength = 32;
    input.id = "set-" + row.key;
    input.setAttribute("aria-labelledby", "set-label-" + row.key);
    input.setAttribute("aria-describedby",
      (entry.description ? "set-help-" + row.key + " " : "") + "set-meta-" + row.key + " set-error-" + row.key);
    input.addEventListener("input", function () {
      row.touched = true;
      markClean(row);
      refreshDirty(row);
    });
    input.addEventListener("keydown", function (event) {
      if (event.key !== "Enter") return;
      event.preventDefault();
      applyAll();
    });
    field.appendChild(input);
    if (entry.unit) field.appendChild(el("span", "unit", String(entry.unit)));
    row.input = input;
    return field;
  }

  function ensureRow(entry) {
    var key = String(entry.key);
    var row = rows[key];
    if (row) return row;
    var kind = controlKind(entry);
    row = {
      key: key,
      entry: entry,
      kind: kind,
      edited: false,
      // `touched` is the operator's own mark, set by typing in the field or
      // pressing a switch, and cleared by Revert, Discard or a successful
      // apply. Only a touched row is a draft; every other row belongs to the
      // server, which is what stops a remote write from arriving as somebody's
      // unsaved edit.
      touched: false,
      saving: false,
      savingAt: 0,
      appliedAt: 0,
      server: entry.value === null || entry.value === undefined ? entry.default : entry.value,
      value: kind === "boolean" ? truthy(entry.value === undefined ? entry.default : entry.value) : null
    };

    var root = el("article", "set");
    root.dataset.key = key;
    row.root = root;

    var text = el("div", "set-text");
    var name = el("h3", "set-label", label(row));
    name.id = "set-label-" + key;
    text.appendChild(name);
    if (entry.description) {
      var help = el("p", "set-help", String(entry.description));
      help.id = "set-help-" + key;
      text.appendChild(help);
    }
    row.errorNode = el("p", "set-error");
    row.errorNode.id = "set-error-" + key;
    row.errorNode.setAttribute("role", "alert");
    row.errorNode.hidden = true;
    text.appendChild(row.errorNode);
    root.appendChild(text);

    var control = el("div", "set-control");
    control.appendChild(kind === "boolean" ? buildSwitch(row) : buildInput(row));
    row.meta = el("div", "set-meta");
    row.meta.id = "set-meta-" + key;
    control.appendChild(row.meta);
    root.appendChild(control);

    row.revert = el("button", "link", "REVERT");
    row.revert.type = "button";
    row.revert.setAttribute("aria-label", "Revert " + label(row));
    row.revert.addEventListener("click", function () { revert(row); });

    if (key === MASTER_KEY) els.master.appendChild(root);
    else ensureGroup(String(entry.group || "Settings")).body.appendChild(root);
    rows[key] = row;
    order.push(key);
    refreshDirty(row);
    return row;
  }

  function desiredText(row) {
    if (row.kind === "boolean") return row.value ? "true" : "false";
    return String(row.input.value).trim();
  }

  function isDirty(row) {
    var raw = desiredText(row);
    if (row.kind === "boolean") return truthy(raw) !== truthy(row.server);
    // An empty box is a draft for the operator who erased it -- the poll must not
    // write the server's value back under them -- and is not a draft for a row
    // nobody has touched, which is simply not filled in yet.
    if (raw === "") return row.touched === true;
    if (row.kind === "number") {
      var server = num(row.server);
      return !(server !== null && Number(raw) === server);
    }
    return raw !== serverText(row);
  }

  function isDraft(row) { return row.kind !== "boolean" && row.edited && !row.saving; }

  function refreshDirty(row) {
    row.edited = isDirty(row);
    row.root.classList.toggle("edited", isDraft(row));
    row.root.classList.toggle("saving", row.saving);
    row.meta.textContent = metaText(row);
    if (isDraft(row)) row.meta.appendChild(row.revert);
    if (row.kind === "boolean") {
      row.buttons.true.setAttribute("aria-pressed", row.value ? "true" : "false");
      row.buttons.false.setAttribute("aria-pressed", row.value ? "false" : "true");
      row.buttons.true.disabled = row.buttons.false.disabled = row.saving;
    } else {
      row.input.readOnly = row.saving;
    }
    renderSavebar();
  }

  function renderSavebar() {
    var drafts = 0, saving = 0;
    order.forEach(function (key) {
      if (isDraft(rows[key])) drafts += 1;
      if (rows[key].saving && rows[key].kind !== "boolean") saving += 1;
    });
    els.savebar.hidden = drafts === 0 && saving === 0;
    els.savebarCount.textContent = drafts
      ? plural(drafts, "UNSAVED CHANGE", "UNSAVED CHANGES")
      : "SAVING " + plural(saving, "CHANGE", "CHANGES") + "…";
    els.applyAll.disabled = drafts === 0 || !!blocked;
    els.discard.disabled = drafts === 0;
    els.settingsDot.hidden = drafts === 0;
  }

  function revert(row) {
    if (row.kind === "boolean") row.value = truthy(row.server);
    else row.input.value = serverText(row);
    row.touched = false;
    markClean(row);
    refreshDirty(row);
  }

  function fieldError(row, message) {
    row.error = message;
    // Server reasons are written lower-case to be spliced into a sentence;
    // standing alone under a field they read as one.
    row.errorNode.textContent = message.charAt(0).toUpperCase() + message.slice(1);
    row.errorNode.hidden = false;
    row.root.classList.add("invalid");
  }

  function validateNumber(row) {
    var entry = row.entry;
    var raw = desiredText(row);
    if (raw === "") return "Enter a value.";
    if (!/^[-+]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][-+]?[0-9]+)?$/.test(raw)) return "Not a number.";
    var value = Number(raw);
    if (!isFinite(value)) return "Not a finite number.";
    var min = num(entry.min), max = num(entry.max);
    if (min !== null && value < min) return "The lowest allowed is " + fmt(min) + ".";
    if (max !== null && value > max) return "The highest allowed is " + fmt(max) + ".";
    // Admission is type, finiteness and the declared bounds -- nothing else.
    // `step` is presentation only in the declaration and is never enforced by
    // the host, so it must not be enforced here either.
    var integer = String(entry.type || "").toLowerCase().indexOf("int") === 0;
    if (integer && value % 1 !== 0) return "Must be a whole number.";
    return null;
  }

  function validateText(row) {
    var raw = desiredText(row);
    if (raw === "") return "Enter a value.";
    if (/\s/.test(raw)) return "No spaces: the command line takes one word.";
    if (raw.length > 32) return "At most 32 characters.";
    return null;
  }

  function validate(row) {
    if (row.kind === "number") return validateNumber(row);
    if (row.kind === "text") return validateText(row);
    return null;
  }

  // Every row in `list` is validated before any is sent, so a batch with one
  // bad value sends nothing and says which one. The lines go out in the
  // server's own order.
  function applyRows(list) {
    if (blocked || !list.length) return;
    var invalid = list.filter(function (row) {
      var message = validate(row);
      if (message) fieldError(row, message);
      return !!message;
    });
    if (invalid.length) {
      setStatus(invalid.length === 1
        ? label(invalid[0]) + ": " + invalid[0].error
        : invalid.length + " values need fixing before anything is saved.", "bad");
      selectTab("settings");
      if (invalid[0].input) invalid[0].input.focus();
      return;
    }
    list.forEach(function (row) {
      var value = desiredText(row);
      if (!emit("command", { tokens: ["traffic", "set", row.key, value] })) return;
      if (!batch) batch = { keys: {}, saved: [], failed: [] };
      batch.keys[row.key] = true;
      row.saving = true;
      row.savingAt = Date.now();
      markClean(row);
      refreshDirty(row);
    });
    renderLive();
  }

  function applyAll() {
    applyRows(order.map(function (key) { return rows[key]; }).filter(isDraft));
  }

  function releaseSaving(row) {
    if (!row.saving) return;
    row.saving = false;
    refreshDirty(row);
  }

  // One toast per APPLY, not one per line: it is sent when the last line of the
  // batch has answered.
  function settle(row, ok, message) {
    if (!batch || !batch.keys[row.key]) return false;
    delete batch.keys[row.key];
    if (ok) batch.saved.push(row);
    else batch.failed.push({ row: row, message: message });
    if (Object.keys(batch.keys).length) return true;
    var done = batch;
    batch = null;
    var total = done.saved.length + done.failed.length;
    if (!done.failed.length) {
      setStatus(total === 1
        ? label(done.saved[0]) + " is now " + valueText(done.saved[0].entry, done.saved[0].server) + "."
        : "Saved " + total + " settings. New cars use them from the next spawn.", "good");
    } else {
      var first = done.failed[0];
      setStatus((done.saved.length ? "Saved " + done.saved.length + " of " + total + ". " : "")
        + label(first.row) + ": " + first.message, "bad");
    }
    return true;
  }

  function renderSettings(entries) {
    var seen = {};
    entries.forEach(function (entry) {
      if (!entry || typeof entry.key !== "string") return;
      if (entry.key !== MASTER_KEY) seen[String(entry.group || "Settings")] = true;
      var row = ensureRow(entry);
      row.entry = entry;
      if (entry.value !== null && entry.value !== undefined) row.server = entry.value;

      // `touched` is the operator's own mark, so a row they have not touched is
      // never a draft: it takes the server's value on every snapshot, however
      // its flags were left. A touched row keeps its text, marker and error
      // until it is applied or reverted.
      var drafting = row.touched && (row.edited || row.saving);
      if (!drafting) {
        row.touched = false;
        if (row.saving) releaseSaving(row);
        // `appliedAt` is the short grace period in which an already-answered
        // apply outranks a snapshot that was still in flight when it was sent.
        if (Date.now() - row.appliedAt > APPLIED_HOLD_MS) {
          if (row.kind === "boolean") row.value = truthy(row.server);
          else row.input.value = serverText(row);
        }
      }
      refreshDirty(row);
    });

    Object.keys(groups).forEach(function (name) {
      groups[name].box.hidden = !seen[name];
    });

    els.settingsNote.textContent = entries.length
      ? "Server-wide and kept across restarts. New values apply from the next car that spawns."
      : "The server declared no settings for this generator.";
  }

  /* ----------------------------------------------------------------- snapshot */
  function renderStats(data) {
    var active = num(data.active), owned = num(data.totalOwned);
    var desired = num(data.desired), budget = num(data.admittedBudget);
    var capacity = data.capacity || {}, phases = data.phases || {};
    els.statActive.textContent = active === null ? "—" : fmt(active);
    els.statDrivers.textContent = whole(data.drivers);
    var leaving = owned !== null && active !== null ? owned - active : 0;
    els.statsNote.textContent = "Max " + whole(desired) + " · current admission " + whole(budget)
      + " · core jobs " + whole(capacity.globalUsed)
      + " · " + whole(capacity.perSimulatorLimit) + " slots per simulator. "
      + whole(phases.enrolling) + " enrolling · " + whole(phases.moving) + " moving · "
      + whole(phases.healthy_waiting) + " healthy waiting · " + whole(phases.recovering)
      + " recovering · " + whole(phases.failed_retiring) + " failed/retiring."
      + (leaving > 0 ? " " + plural(leaving, "more is", "more are") + " being cleaned up." : "");

    var resetting = truthy(data.resetting);
    var generating = truthy(data.enabled);
    var limited = generating && budget !== null && desired !== null && active !== null
      && budget < desired && active >= budget;
    els.badge.textContent = resetting ? "RESETTING" : limited ? "AT CAPACITY" : generating ? "GENERATING" : "PAUSED";
    els.badge.className = "ds-badge " + (resetting || limited ? "is-busy" : generating ? "is-on" : "is-off");
  }

  function renderNearby(nearby) {
    var cars = list(nearby.vehicles);
    var total = num(nearby.total);
    var limit = num(nearby.shown);

    if (!radiusDirty && document.activeElement !== els.radius && num(nearby.radius) !== null) {
      radius = nearby.radius;
      els.radius.value = String(radius);
    }

    els.statNear.textContent = total === null ? "—" : fmt(total);
    els.statNearLabel.textContent = "WITHIN " + fmt(radius) + " M";
    els.nearbyCount.textContent = total === null
      ? "No data"
      : (total === 0 ? "No cars"
        : limit !== null && limit < total ? "Nearest " + fmt(limit) + " of " + fmt(total)
          : plural(total, "car", "cars"))
        + " · bucket " + shown(nearby.bucket);

    var applied = num(nearby.applied), waiting = num(nearby.pending), failed = num(nearby.failed);
    if (!total || (applied === null && waiting === null && failed === null)) {
      els.patternCounts.hidden = true;
    } else {
      els.patternCounts.hidden = false;
      clear(els.patternCounts);
      els.patternCounts.appendChild(document.createTextNode("Mode status · "));
      els.patternCounts.appendChild(el("span", "ok", fmt(applied || 0) + " applied"));
      els.patternCounts.appendChild(document.createTextNode(" · "));
      els.patternCounts.appendChild(el("span", "warn", fmt(waiting || 0) + " pending"));
      els.patternCounts.appendChild(document.createTextNode(" · "));
      els.patternCounts.appendChild(el("span", failed ? "bad" : null, fmt(failed || 0) + " failed"));
      // Panic is its own timed request, so its outcomes are counted apart from
      // the mode's, and only while any car has one to show.
      var panic = nearby.panic || {};
      var panicking = num(panic.active) || 0, panicWaiting = num(panic.pending) || 0,
        panicMissed = num(panic.notApplied) || 0;
      if (panicking || panicWaiting || panicMissed) {
        els.patternCounts.appendChild(document.createTextNode(" · Panic · "));
        els.patternCounts.appendChild(el("span", "ok", fmt(panicking) + " active"));
        els.patternCounts.appendChild(document.createTextNode(" · "));
        els.patternCounts.appendChild(el("span", "warn", fmt(panicWaiting) + " pending"));
        els.patternCounts.appendChild(document.createTextNode(" · "));
        els.patternCounts.appendChild(el("span", panicMissed ? "bad" : null, fmt(panicMissed) + " not applied"));
      }
    }

    clear(els.table);
    if (!cars.length) {
      var emptyRow = el("tr");
      var cell = el("td", "empty", total === null
        ? "No fleet data in the last snapshot."
        : total === 0
          ? "No traffic cars within " + fmt(radius) + " m."
          : "The server counted cars but sent no rows for them.");
      cell.colSpan = 5;
      emptyRow.appendChild(cell);
      els.table.appendChild(emptyRow);
      return;
    }
    cars.forEach(function (car) {
      // A live panic outranks the mode for as long as it runs: the Mode column
      // says panic and the Status column its own pending/active state. Once it
      // is over the row shows the mode again, and a panic that never applied
      // says why underneath.
      var panicStatus = String(car.panicStatus || "inactive");
      var panicLive = panicStatus === "pending" || panicStatus === "active";
      var native = panicLive ? panicStatus : String(car.patternStatus || "inactive");
      var tr = el("tr");

      var vehicle = el("td");
      vehicle.appendChild(el("span", "rec",
        shown(car.record).replace(/^Vehicle\.v_[^_]+_/, "").replace(/_/g, " ")));
      var sub = "#" + shown(car.id);
      if (car.owner !== null && car.owner !== undefined && car.owner !== "") sub += " · run by " + car.owner;
      vehicle.appendChild(el("span", "sub", sub));
      vehicle.appendChild(el("span", "sub", String(car.phase || "unknown").replace(/_/g, " ")
        + (car.reason ? " · " + reasonText(car.reason) : "")));
      tr.appendChild(vehicle);

      tr.appendChild(el("td", null, panicLive ? "panic" : modeName(car.pattern)));

      var status = el("td");
      var tone = native === "applied" || native === "active" ? "applied"
        : native === "pending" ? "pending" : native === "failed" ? "failed" : "";
      status.appendChild(el("span", "st" + (tone ? " " + tone : ""), native));
      if (!panicLive && car.patternReason) status.appendChild(el("span", "sub", reasonText(car.patternReason)));
      if (panicStatus === "blocked" || panicStatus === "refused") {
        status.appendChild(el("span", "sub", "panic " + panicStatus
          + (car.panicReason ? " · " + reasonText(car.panicReason) : "")));
      }
      tr.appendChild(status);

      tr.appendChild(el("td", "n", whole(car.distance)));
      var speed = num(car.speed);
      tr.appendChild(el("td", "n", speed === null ? "—" : whole(speed * 3.6)));
      els.table.appendChild(tr);
    });
  }

  // The setting declarations arrive once per opening (`traffic:settings`); a
  // snapshot carries only the values in force, keyed by setting.
  var declarations = [];

  function settingEntries(values) {
    values = values && typeof values === "object" ? values : {};
    return declarations.map(function (declaration) {
      var entry = {};
      Object.keys(declaration || {}).forEach(function (field) { entry[field] = declaration[field]; });
      entry.value = declaration ? values[declaration.key] : undefined;
      return entry;
    });
  }

  function receive(payload) {
    dataAt = Date.now();
    // The snapshot IS the answer to a state request. Pending MUTATIONS
    // (pattern, panic, reset) are left alone: their answer is a result.
    if (pending && pending.operation === "state") pending = null;
    renderStats(payload.stats || {});
    // Before the declarations have arrived there is nothing to render a value
    // into; the next push will.
    if (declarations.length) renderSettings(settingEntries(payload.settings));
    renderNearby(payload.nearby || {});
    renderLive();
  }

  /* ---------------------------------------------------------------- transport */
  function command(tokens) {
    if (blocked) {
      setStatus(blocked, "bad");
      return false;
    }
    if (!emit("command", { tokens: tokens })) return false;
    pending = { operation: tokens[1], at: Date.now() };
    renderLive();
    return true;
  }

  function resetIdle() {
    els.resetGo.disabled = false;
    els.resetGo.textContent = "DELETE AND RESTART";
  }

  function clearWorking() {
    var buttons = els.patterns.querySelectorAll("button[data-pattern]");
    for (var index = 0; index < buttons.length; index += 1) buttons[index].classList.remove("working");
  }

  // Backing out of the confirmation is a UI act, not a cancellation: while a
  // reset is still unanswered the button keeps reading "DELETING…" and stays
  // disabled, so re-arming the destructive path cannot send a second reset into
  // a first one that has not answered.
  function cancelReset() {
    confirmReset = false;
    els.resetConfirm.hidden = true;
    els.resetAsk.hidden = false;
    if (!pending || pending.operation !== "reset") resetIdle();
  }

  function applyResult(result) {
    var operation = String(result.operation || "");
    var ok = result.ok === true;
    var message = String(result.message || "");

    if (/permission_denied/.test(message)) {
      setBlocked("The server refused /traffic for this session (" + message
        + "). Ask an operator to grant command.traffic.");
      return;
    }

    if (operation === "set") {
      // Per-row state belongs only to a row with a line in flight. A `set`
      // result also arrives for lines this page never sent -- an external write
      // from the same player -- and mutating an idle row from one of those
      // would make the next snapshot look like a draft nobody made.
      var row = result.key ? rows[result.key] : null;
      if (row && row.saving) {
        row.saving = false;
        if (ok) {
          // The next snapshot carries what the server stored, and this row is
          // no longer the operator's draft, so it follows the server again.
          row.appliedAt = Date.now();
          row.touched = false;
          row.server = row.kind === "boolean" ? row.value
            : row.kind === "number" ? Number(desiredText(row)) : desiredText(row);
        } else {
          // A refused switch goes back to where the server has it; a refused
          // number keeps its text so the operator can correct it.
          if (row.kind === "boolean") { row.value = truthy(row.server); row.touched = false; }
          fieldError(row, explain(message));
        }
        refreshDirty(row);
        if (settle(row, ok, explain(message))) { renderLive(); return; }
      }
      setStatus(ok ? (message || "Setting saved.") : explain(message), ok ? "good" : "bad");
      renderLive();
      return;
    }

    if (pending && pending.operation === operation) pending = null;

    if (operation === "pattern") {
      clearWorking();
      if (ok) {
        var mode = lastPattern ? modeName(lastPattern.pattern).toUpperCase() : "Mode";
        setStatus(mode + " sent to " + fmt(result.requested || 0) + " of "
          + plural(num(result.matched) || 0, "car", "cars") + " in range."
          + (num(result.failed) ? " " + fmt(result.failed) + " refused." : "")
          + " The Status column shows when each car applies it.", num(result.failed) ? "bad" : "good");
      } else {
        setStatus("Mode change refused: " + explain(message), "bad");
      }
    } else if (operation === "panic") {
      clearWorking();
      if (ok) {
        setStatus("PANIC requested for " + fmt(result.requested || 0) + " of "
          + plural(num(result.matched) || 0, "car", "cars") + " in range."
          + (num(result.failed) ? " " + fmt(result.failed) + " refused." : "")
          + (num(result.durationSeconds) ? " Each panics for " + fmt(result.durationSeconds)
            + " s once its game confirms it, then rejoins traffic." : "")
          + " The Status column shows pending, then active.", num(result.failed) ? "bad" : "good");
      } else {
        setStatus("Panic refused: " + explain(message), "bad");
      }
    } else if (operation === "reset") {
      // Three outcomes, and they are not interchangeable:
      //   counts present  -> the reset ran (it may have failed on some cars);
      //   no counts       -> it never ran, and nothing was deleted or changed;
      //   ok              -> it ran clean.
      var ran = num(result.removedVehicles) !== null || num(result.removedDrivers) !== null;
      if (ok) {
        cancelReset();
        setStatus("Reset: removed " + plural(num(result.removedVehicles) || 0, "car", "cars") + " and "
          + plural(num(result.removedDrivers) || 0, "driver", "drivers") + ". Traffic is spawning again.",
        "good");
      } else if (ran) {
        cancelReset();
        setStatus("The reset ran but did not finish cleanly — " + message, "bad");
      } else {
        resetIdle();
        setStatus(resetFailureText(message), "bad");
      }
    } else if (!ok) {
      // `state` and `open`: the snapshot is the answer, so only a refusal talks.
      setStatus(explain(message), "bad");
    }
    renderLive();
  }

  /* ------------------------------------------------------------------ actions */
  function radiusValue() {
    var raw = String(els.radius.value).trim();
    if (!/^[0-9]+$/.test(raw)) return null;
    var value = Number(raw);
    if (value < 1 || value > 500) return null;
    return value;
  }

  function look() {
    var value = radiusValue();
    if (value === null) {
      setStatus("The radius must be a whole number of metres from 1 to 500.", "bad");
      els.radius.focus();
      return;
    }
    radius = value;
    radiusDirty = false;
    command(["traffic", "state", String(value)]);
  }

  function applyPattern(pattern, button) {
    var value = radiusValue();
    if (value === null) {
      setStatus("Set a radius from 1 to 500 m first: the mode is sent to the cars inside it.", "bad");
      els.radius.focus();
      return;
    }
    radius = value;
    radiusDirty = false;
    lastPattern = { pattern: pattern, radius: value };
    // Panic is not a mode but a timed reaction with its own command; Normal
    // and Stop are modes, and either one also ends a running panic.
    var tokens = pattern === "panic" ? ["traffic", "panic", String(value)]
      : ["traffic", "pattern", pattern, String(value)];
    if (!command(tokens)) return;
    clearWorking();
    button.classList.add("working");
  }

  function close() {
    open = false;
    pending = null;
    cancelReset();
    document.body.classList.remove("open");
    emit("close", {});
    renderLive();
  }

  els.close.addEventListener("click", close);
  els.scrim.addEventListener("click", close);

  Array.prototype.forEach.call(els.tabs, function (tab, index) {
    tab.addEventListener("click", function () { selectTab(tab.dataset.tab); });
    tab.addEventListener("keydown", function (event) {
      var step = event.key === "ArrowRight" ? 1 : event.key === "ArrowLeft" ? -1 : 0;
      if (!step) return;
      event.preventDefault();
      var next = els.tabs[(index + step + els.tabs.length) % els.tabs.length];
      selectTab(next.dataset.tab, true);
    });
  });

  els.applyAll.addEventListener("click", applyAll);
  els.discard.addEventListener("click", function () {
    order.forEach(function (key) { if (isDraft(rows[key])) revert(rows[key]); });
  });

  els.radiusForm.addEventListener("submit", function (event) {
    event.preventDefault();
    if (blocked) return;
    look();
  });
  els.radius.addEventListener("input", function () { radiusDirty = true; });
  els.patterns.addEventListener("click", function (event) {
    var button = event.target.closest("button[data-pattern]");
    if (!button || blocked) return;
    applyPattern(button.dataset.pattern, button);
  });

  els.resetAsk.addEventListener("click", function () {
    if (blocked) return;
    confirmReset = true;
    // The confirmation line is static on purpose. A reset is all-owned --
    // registry-enumerated, released wrecks and handed-over cars included -- so
    // a count of what is still tracked would understate what the button does.
    els.resetConfirm.hidden = false;
    els.resetAsk.hidden = true;
    els.resetGo.focus();
  });
  els.resetCancel.addEventListener("click", function () {
    cancelReset();
    els.resetAsk.focus();
  });
  els.resetGo.addEventListener("click", function () {
    if (blocked) return;
    if (!command(["traffic", "reset", "confirm"])) return;
    els.resetGo.disabled = true;
    els.resetGo.textContent = "DELETING…";
  });

  document.addEventListener("keydown", function (event) {
    if (event.key !== "Escape" || !open) return;
    event.preventDefault();
    // Escape backs out of the destructive confirmation first: a keystroke that
    // closed the whole panel while a delete was armed would be a trap.
    if (confirmReset) {
      cancelReset();
      els.resetAsk.focus();
      return;
    }
    close();
  });

  on("settings", function (payload) { declarations = list(payload); });
  on("open", function (payload) {
    open = true;
    document.body.classList.add("open");
    receive(payload);
  });
  on("data", function (payload) { if (open) receive(payload); });
  on("result", applyResult);
  on("close", function () {
    open = false;
    pending = null;
    cancelReset();
    document.body.classList.remove("open");
    renderLive();
  });

  setInterval(function () {
    var now = Date.now();
    if (pending && now - pending.at > PENDING_GIVE_UP_MS) {
      // A command that never answered must not leave a control dead forever:
      // after the give-up the operator may try again.
      if (pending.operation === "reset") resetIdle();
      if (pending.operation === "pattern" || pending.operation === "panic") clearWorking();
      pending = null;
    }
    order.forEach(function (key) {
      var row = rows[key];
      if (!row.saving || now - row.savingAt <= PENDING_GIVE_UP_MS) return;
      var reason = "No answer from the server; the value may not have changed.";
      row.saving = false;
      if (row.kind === "boolean") { row.value = truthy(row.server); row.touched = false; }
      fieldError(row, reason);
      refreshDirty(row);
      settle(row, false, reason);
    });
    renderLive();
  }, 1000);

  // Ready is TWO calls, and they are not the same call. `Open77.ready()` is the
  // BRIDGE handshake -- the WebHost raises its own `ui:ready` for the surface --
  // while the client resource is waiting for this resource's own
  // `traffic:ready`. Calling only the first is a page that loads perfectly and
  // is never shown, because `page:on("traffic:ready")` never fires and every
  // `page:send` before it is dropped in silence.
  //
  // It is emitted LAST, and that is load order rather than tidiness: Lua pushes
  // the open snapshot the moment `traffic:ready` lands, so every handler above
  // has to exist before that emit reaches the client.
  try {
    if (bridge && typeof bridge.ready === "function") bridge.ready();
  } catch (error) {
    report("bridge ready failed: " + describe(error));
  }
  emit("ready", {});

  // A page with no bridge still renders -- that is how it is previewed outside
  // the game -- it just cannot talk to anything, and says so rather than looking
  // live.
  if (!bridge) {
    document.body.classList.add("open");
    setStatus("No UI bridge: this page is not running inside the game.", "bad");
  }
})();
