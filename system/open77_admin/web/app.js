/* open77_admin -- the panel.
 *
 * This page holds no authority. Every control it offers ends in exactly one
 * outbound message:
 *
 *     Open77.emit("admin:command", { tokens: [...] })
 *
 * which the client resource turns into `open77:command:execute`, which the
 * server authorises against `command.<name>` before any handler runs. There is
 * no second path, and adding one would be adding a hole.
 *
 * Because Lua cannot ask the ACL what the caller holds, the page renders every
 * control optimistically and LEARNS from refusals: a `permission_denied:` reply
 * greys the control that produced it for the rest of the session and says so
 * where the operator clicked. Honest, self-correcting, and needs no new API.
 */
(function () {
  "use strict";

  /* ----------------------------------------------------- failure reporting */
  //
  // Installed FIRST, and deliberately so. Two things conspire to make a broken
  // page on this surface completely invisible:
  //
  //   * CEF console output is forwarded by `SurfaceClient::OnConsoleMessage`
  //     through the webhost's `Trace`, and that trace level does not reach
  //     `red4ext/logs/open77-*.log`. Nothing a page prints is readable.
  //   * The WebUI bridge SWALLOWS every exception thrown inside an
  //     `Open77.on` handler -- `__dispatch` wraps each call in try/catch and
  //     calls `console.error`. So a handler that dies half way through leaves
  //     no trace anywhere, and Lua cannot tell: from its side the surface was
  //     created, the handlers registered, and the emits kept arriving.
  //
  // Together those two turn "the panel is blank" into a bug with no evidence
  // at all. This forwards uncaught errors, rejected promises, anything sent to
  // console.error, and a few milestones to the client resource, which writes
  // them to the ordinary log. It is capped, and it never reports its own
  // failures -- there would be nowhere left to report them to.
  var reportCount = 0;
  var reporting = false;

  function describe(value) {
    try {
      if (value instanceof Error) return (value.name || "Error") + ": " + value.message
        + (value.stack
          ? " | " + String(value.stack).split(String.fromCharCode(10)).join(" <- ").slice(0, 300)
          : "");
      if (value === null || value === undefined) return String(value);
      if (typeof value === "object") return Object.prototype.toString.call(value);
      return String(value);
    } catch (ignored) { return "<undescribable>"; }
  }

  function report(level, text) {
    // Re-entrancy matters: `Open77.emit` reports its own transport failures
    // through console.error, which lands right back here.
    if (reporting || reportCount >= 40) return;
    reporting = true;
    reportCount += 1;
    try {
      window.Open77.emit("admin:diag", { level: String(level), text: String(text).slice(0, 500) });
    } catch (ignored) { /* nowhere left to complain to */ }
    reporting = false;
  }

  // Lua cannot tell an empty array from an empty map, so a resource that sends
  // a list with nothing in it arrives here as `{}`, not `[]`. `{}` is truthy,
  // so the usual `value || []` guard keeps the object: `.length` then reads
  // `undefined` and `.forEach` throws, aborting the whole render. That is how
  // the props tab came to report "undefined of 1" with an empty table. Every
  // list crossing the bridge goes through here.
  function list(value) { return Array.isArray(value) ? value : []; }

  // What the panel actually looks like right now, in numbers. If the next blank
  // panel logs `open=true opacity=1 panel=1690x972`, the page rendered and the
  // pixels were lost downstream; if it logs `panel=0x0` the layout collapsed;
  // if this line never appears at all, the page never got that far.
  function paintState() {
    try {
      var panel = document.querySelector(".panel");
      var box = panel ? panel.getBoundingClientRect() : { width: 0, height: 0 };
      return "open=" + document.body.classList.contains("open")
        + " opacity=" + window.getComputedStyle(document.body).opacity
        // The ROOT's opacity, and it is not redundant with the body's: `opacity`
        // applies to <html> as well, an ancestor at 0 paints the entire document
        // into a fully transparent layer, and the body reading above is blind to
        // it. That blind spot is exactly what hid this panel -- and what
        // swallowed the body-scoped debug rectangle sent to find it. Never drop
        // this field: `opacity=1 rootOpacity=0` is the whole diagnosis.
        + " rootOpacity=" + window.getComputedStyle(document.documentElement).opacity
        + " viewport=" + window.innerWidth + "x" + window.innerHeight
        + " panel=" + Math.round(box.width) + "x" + Math.round(box.height);
    } catch (error) { return "paintState failed: " + describe(error); }
  }

  window.addEventListener("error", function (event) {
    report("error", "uncaught " + (event.message || "?")
      + " at " + (event.filename || "?") + ":" + (event.lineno || 0));
  });
  window.addEventListener("unhandledrejection", function (event) {
    report("error", "unhandled rejection: " + describe(event.reason));
  });
  (function (original) {
    console.error = function () {
      report("error", Array.prototype.map.call(arguments, describe).join(" "));
      try { original.apply(console, arguments); } catch (ignored) { /* no console */ }
    };
  })(console.error);

  var boot = null;
  var open = false;
  var poller = null;
  var denied = Object.create(null);   // command name -> true, learned from refusals
  var access = Object.create(null);
  var pendingPlayers = [];
  function unavailable(name) {
    return !!denied[name] || (/^(admin(?:\.|$)|adminfull$|weather\.)/.test(name) && access[name] !== true);
  }
  var state = { players: [], vehicles: [], world: null, audit: [], governor: null, rated: {},
    props: null };

  // Static reference data, fetched instead of arriving at boot.
  //
  // The client host caps a single page payload at 1024 value nodes (keys
  // counted), and the catalogue facets alone are past 1600 -- shipping them in
  // `admin:boot` meant the whole boot payload was silently dropped, with no
  // error anywhere, and every tab that reads `boot` came up empty. So they are
  // requested a window at a time when a tab first needs them, and cached here
  // for the session. Nothing in here ever changes while the game runs.
  var reference = {
    groups: null, classes: null, makers: null,
    propModels: null, propEffects: null, propLight: null,
  };
  var referenceLoading = Object.create(null);

  var catalog = {
    query: "", group: "player", klass: null, maker: null,
    player: false, police: false, sort: "name", rows: [], total: 0, selected: null,
  };
  var selection = { record: null, name: null, vehicleId: null };

  var $ = function (id) { return document.getElementById(id); };
  var el = function (tag, cls, text) {
    var node = document.createElement(tag);
    if (cls) node.className = cls;
    if (text !== undefined && text !== null) node.textContent = String(text);
    return node;
  };

  /* ------------------------------------------------------------------ send */

  function run(tokens, tag) {
    if (!Array.isArray(tokens) || tokens.length === 0) return;
    // Once a command has come back refused, stop sending it. The reads poll
    // once a second, and every refusal costs the operator a chat line: without
    // this, an operator whose role omits one read would watch the same denial
    // scroll past forever.
    //
    // But say so. Returning silently is worse than the spam it prevents: the
    // statically declared [data-cmd] buttons are wired once and never
    // re-rendered, so a bare `return` makes Noclip, Heal, Refresh and the rest
    // do literally nothing, with no log line and no visual state.
    if (unavailable(String(tokens[0]))) {
      if (String(tokens[0]).indexOf("admin.read.") === 0) return;
      logLine(tokens.join(" "), false, "You do not have permission to run /" + tokens[0]);
      return;
    }
    Open77.emit("admin:command", { tokens: tokens.map(String), tag: tag || null });
    // Reads run once a second while the panel is open. Logging them would bury
    // the operator's own actions under a hundred lines of polling, so only
    // mutations reach the log.
    if (String(tokens[0]).indexOf("admin.read.") !== 0) logLine(tokens.join(" "), null, "sent");
  }

  /* ------------------------------------------------------------- result log */

  var logNode = null;

  function logLine(raw, ok, message) {
    if (!logNode) logNode = $("con-log");
    var placeholder = logNode.querySelector(".empty");
    if (placeholder) placeholder.remove();

    var row = el("div", "row");
    row.appendChild(el("span", "k", ok === null ? "»" : ok ? "OK" : "NO"));
    var value = el("span", "v" + (ok === true ? " good" : ok === false ? " bad" : ""), message || "");
    row.appendChild(value);
    row.appendChild(el("span", "r mono", raw));
    logNode.insertBefore(row, logNode.firstChild);
    while (logNode.children.length > 120) logNode.removeChild(logNode.lastElementChild);

    $("f-last").textContent = (ok === false ? "refused: " : "") + (message || raw);
  }

  /* -------------------------------------------------------------- rendering */

  // The [data-cmd] buttons live in index.html and are wired once, so unlike the
  // rows they are never re-rendered. Their disabled state has to be pushed.
  function syncStaticButtons() {
    Array.prototype.forEach.call(document.querySelectorAll("[data-cmd]"), function (button) {
      var name = String(button.dataset.cmd).split(" ")[0];
      var off = unavailable(name);
      button.disabled = off;
      button.classList.toggle("dead", off);
      button.title = off ? "You do not have permission to run /" + name : "";
    });
  }

  function pill(text, kind) { return el("span", "pill" + (kind ? " " + kind : ""), text); }

  function fmt(n, places) {
    if (n === null || n === undefined) return "—";
    return Number(n).toFixed(places === undefined ? 0 : places);
  }

  function clearNode(node) { while (node.firstChild) node.removeChild(node.firstChild); }

  function actionButton(label, tokens, kind) {
    var button = el("button", "act" + (kind ? " " + kind : ""), label);
    button.type = "button";
    if (unavailable(tokens[0])) {
      button.classList.add("dead");
      button.title = "You do not have permission to run /" + tokens[0];
      button.disabled = true;
    }
    button.addEventListener("click", function () { run(tokens); });
    return button;
  }

  // Like actionButton, but its arguments are read at CLICK time. A row's Move
  // has to take the coordinates that are in the box when the operator clicks,
  // not the ones that were there when the table last re-rendered — and it
  // re-renders once a second.
  function lateActionButton(label, name, argsFn, kind) {
    var button = el("button", "act" + (kind ? " " + kind : ""), label);
    button.type = "button";
    if (unavailable(name)) {
      button.classList.add("dead");
      button.title = "You do not have permission to run /" + name;
      button.disabled = true;
    }
    button.addEventListener("click", function () {
      var extra = argsFn();
      if (extra === null) return;
      run([name].concat(extra));
    });
    return button;
  }

  /* ------------------------------------------------------------ tab: players */

  function renderPlayers() {
    var body = $("pl-table").tBodies[0];
    var filter = $("pl-search").value.trim().toLowerCase();
    clearNode(body);

    var list = state.players.filter(function (p) {
      if (!filter) return true;
      return String(p.playerId) === filter || (p.name || "").toLowerCase().indexOf(filter) >= 0;
    });

    $("pl-count").textContent = list.length + " of " + state.players.length;

    list.forEach(function (p) {
      var tr = el("tr");
      tr.appendChild(el("td", "mono", p.playerId));

      var nameCell = el("td");
      nameCell.appendChild(el("span", "name", p.name || "?"));
      if (p.identifier) nameCell.appendChild(el("span", "sub", String(p.identifier).slice(0, 16)));
      tr.appendChild(nameCell);

      var stateCell = el("td");
      if (!p.incarnated) stateCell.appendChild(pill("not incarnated", "bad"));
      else if (p.dead) stateCell.appendChild(pill(p.phase || "down", "warn"));
      else stateCell.appendChild(pill("alive", "ok"));
      if (p.godMode) stateCell.appendChild(pill("god", "acc"));
      tr.appendChild(stateCell);

      // Health arrives as absolute points plus the maximum, because getHealth
      // is absolute and revive/respawn are fractional. Showing the pair means
      // a server that raised maxHealth still reads correctly.
      tr.appendChild(el("td", "n mono", p.health === null || p.health === undefined
        ? "—" : Math.round(p.health) + "/" + Math.round(p.maxHealth || 100)));

      var bucketCell = el("td", "n");
      if (p.bucket && p.bucket !== 0) bucketCell.appendChild(pill(p.bucket, "warn"));
      else bucketCell.appendChild(el("span", "mono", "0"));
      tr.appendChild(bucketCell);

      tr.appendChild(el("td", "n mono", p.distance === null || p.distance === undefined
        ? "—" : fmt(p.distance, 0) + "m"));

      tr.appendChild(el("td", "mono", p.position
        ? fmt(p.position.x) + " " + fmt(p.position.y) + " " + fmt(p.position.z) : "—"));

      var actions = el("td");
      var id = String(p.playerId);
      actions.appendChild(actionButton("Go to", ["admin.player.goto", id]));
      actions.appendChild(actionButton("Bring", ["admin.player.bring", id]));
      actions.appendChild(actionButton("Observe", ["admin.player.observe", id]));
      actions.appendChild(actionButton("Heal", ["admin.player.heal", id]));
      actions.appendChild(actionButton("Revive", ["admin.player.revive", id]));
      actions.appendChild(actionButton("God", ["admin.player.god", id]));
      actions.appendChild(actionButton("Kick", ["admin.moderate.kick", id], "bad"));

      var ban = el("button", "act bad", "Ban");
      ban.type = "button";
      ban.addEventListener("click", function () {
        // Duration first, and always as an explicit token. The server only
        // reads slot 2 as a duration when it carries a unit, so a reason that
        // starts with a number is safe either way — but sending the duration
        // separately is what lets the panel offer one at all.
        var span = window.prompt(
          "Ban " + (p.name || id) + " for how long?\n30m · 12h · 7d · 3600s — or blank for permanent.", "");
        if (span === null) return;
        var reason = window.prompt("Reason (shown to them):", "");
        if (reason === null) return;
        var tokens = ["admin.moderate.ban", id];
        tokens.push(span.trim() ? span.trim().split(/\s+/)[0] : "perm");
        if (reason.trim()) tokens = tokens.concat(reason.trim().split(/\s+/));
        run(tokens);
      });
      actions.appendChild(ban);
      tr.appendChild(actions);

      // Moving somebody who is in a match desyncs that gamemode's state, and
      // this resource cannot ask it -- server resources cannot talk to each
      // other. Disclosure is the honest answer: flag it before the click.
      if (p.bucket && p.bucket !== 0) {
        tr.title = "In routing bucket " + p.bucket + " — they are in a match. Moving them may desync it.";
      }
      if (!p.incarnated) {
        tr.title = "Not incarnated. Server-side actions on this session are refused: they crash the client.";
      }
      body.appendChild(tr);
    });

    $("pl-note").textContent = noteForPlayers();
  }

  // The note has three states and the render path runs on every poll, so the
  // reason has to be recomputed rather than written once when the refusal
  // arrives — otherwise the next render quietly erases it.
  function noteForPlayers() {
    if (denied["admin.read.players"]) {
      return "Your role does not include admin.read.players, so the roster stays empty. "
        + "Ask an owner for the 'moderator' role.";
    }
    if (state.players.length === 0) {
      return "Nobody has announced yet. The roster rebuilds from each client within a second "
        + "of a reload.";
    }
    return "Ping is not shown because the Lua runtime has no reader for it. An absent column "
      + "beats a fabricated one.";
  }

  /* ----------------------------------------------------------- tab: overview */

  function renderOverview() {
    var stats = $("ov-stats");
    clearNode(stats);

    function stat(key, value, kind) {
      var node = el("div", "stat");
      node.appendChild(el("span", "k", key));
      node.appendChild(el("span", "v" + (kind ? " " + kind : ""), value));
      stats.appendChild(node);
    }

    var world = state.world || {};
    stat("Players", state.players.length);
    stat("Vehicles", state.vehicles.length);
    stat("Buckets", list(world.buckets).length || 1);
    stat("Uptime", world.uptimeMs ? Math.floor(world.uptimeMs / 60000) + "m" : "—");
    var gov = world.governor || {};
    stat("Governor", gov.available ? "ready" : "n/a", gov.available ? "ok" : "warn");

    var auditNode = $("ov-audit");
    clearNode(auditNode);
    var recent = state.audit.slice(-6).reverse();
    if (recent.length === 0) {
      auditNode.appendChild(el("p", "empty", "Nothing yet this uptime."));
    } else {
      recent.forEach(function (entry) { auditNode.appendChild(auditRow(entry)); });
    }

    var res = $("ov-res");
    clearNode(res);
    list(world.resources).forEach(function (item) {
      res.appendChild(pill(item.name, item.state === "running" ? "ok" : "warn"));
    });
  }

  function auditRow(entry) {
    var row = el("div", "row");
    row.appendChild(el("span", "k", "#" + entry.seq));
    var value = el("span", "v" + (entry.ok ? "" : " bad"),
      entry.actorName + " · " + entry.action + (entry.detail ? " " + entry.detail : ""));
    row.appendChild(value);
    row.appendChild(el("span", "r mono", entry.ok ? "ok" : "failed"));
    return row;
  }

  function renderAudit() {
    var node = $("au-rows");
    clearNode(node);
    if (state.audit.length === 0) { node.appendChild(el("p", "empty", "Nothing yet.")); return; }
    state.audit.slice().reverse().forEach(function (entry) { node.appendChild(auditRow(entry)); });
  }

  /* ----------------------------------------------------------- tab: vehicles */

  // The catalogue rows come from the CLIENT's copy of the shared table, which
  // only ever holds the seeded measurements. Everything the server has learned
  // since arrives separately, on admin.read.vehicles, so the two have to be
  // merged at render — otherwise the whole learning loop is a no-op and the
  // km/h column is stuck on three records forever.
  function ratedFor(row) {
    return row.ratedTopSpeed || state.rated[row.record] || null;
  }

  function renderCatalog() {
    var body = $("cat-table").tBodies[0];
    clearNode(body);
    catalog.rows.forEach(function (row) {
      var tr = el("tr");
      tr.dataset.record = row.record;
      if (selection.record === row.record) tr.classList.add("sel");

      var nameCell = el("td");
      nameCell.appendChild(el("span", "name", row.name));
      nameCell.appendChild(el("span", "sub", row.record));
      tr.appendChild(nameCell);

      var classCell = el("td");
      classCell.appendChild(pill(row.klass || row.class, row.police ? "warn" : null));
      tr.appendChild(classCell);

      tr.appendChild(el("td", "n mono", ratedFor(row) ? fmt(ratedFor(row)) : "—"));

      tr.addEventListener("click", function () { select(row.record, row.name); });
      body.appendChild(tr);
    });

    var note = catalog.total === 0
      ? "No record matches."
      : "Showing " + catalog.rows.length + " of " + catalog.total +
        " matching records. Speeds are read from a live instance of that model, so a record "
        + "nobody has spawned this session shows a dash and sorts last.";
    if (denied["admin.read.vehicles"]) {
      note += " Your role does not include admin.read.vehicles, so the live list below stays "
        + "empty — browsing the catalogue still works.";
    }
    $("cat-note").textContent = note;
  }

  var catalogSequence = 0;

  // One filtered listing, pulled a window at a time.
  //
  // Lua answers at most a few dozen rows per message for the same node-count
  // reason as the reference sections, and it keeps the ordered list between
  // requests so only the first window of a given filter pays for the scan. The
  // sequence number drops the answers to a filter the operator has already
  // moved on from, which matters because a search box changes the filter faster
  // than a listing comes back.
  function refreshCatalog() {
    catalogSequence += 1;
    var sequence = catalogSequence;
    var collected = [];

    function pull(offset) {
      Open77.invoke("admin:catalog", {
        query: catalog.query,
        group: catalog.group,
        class: catalog.klass,
        maker: catalog.maker,
        playerOnly: catalog.player,
        police: catalog.police,
        sort: catalog.sort,
        offset: offset,
      }).then(function (result) {
        if (sequence !== catalogSequence) return;
        if (!result) return;
        var arrived = Array.isArray(result.rows) ? result.rows : [];
        collected = collected.concat(arrived);
        catalog.rows = collected;
        catalog.total = result.total || 0;
        // Lua sorted on what Lua knows; re-sort here on the merged figure so a
        // record the server has measured this session outranks one it has not.
        if (catalog.sort === "speed") {
          catalog.rows.sort(function (a, b) {
            var left = ratedFor(a), right = ratedFor(b);
            if (!left && !right) return a.name < b.name ? -1 : 1;
            if (!left) return 1;
            if (!right) return -1;
            if (left === right) return a.name < b.name ? -1 : 1;
            return right - left;
          });
        }
        renderCatalog();
        // Forward progress only, for the same reason as `loadReference`.
        if (!result.done && arrived.length > 0 && collected.length < 600) {
          pull(collected.length);
        }
      }).catch(function () { /* the surface is closing; nothing to report */ });
    }

    pull(0);
  }

  function select(record, name) {
    selection.record = record;
    selection.name = name;
    // Selecting from the catalogue clears any instance selection: the two
    // panes answer different questions and pretending one is the other is
    // exactly the confusion the two-tier layout exists to prevent.
    selection.vehicleId = null;
    $("sel-name").textContent = name || "Nothing selected";
    $("sel-record").textContent = record || "—";
    $("sel-spawn").disabled = !record;
    $("sel-give").disabled = !record;
    renderCatalog();
    renderVehicles();
    syncGovernorCards();
  }

  function renderVehicles() {
    var body = $("veh-table").tBodies[0];
    clearNode(body);
    state.vehicles.forEach(function (v) {
      var tr = el("tr");
      if (selection.vehicleId === v.vehicleId) tr.classList.add("sel");
      tr.appendChild(el("td", "mono", v.vehicleId));

      var nameCell = el("td");
      nameCell.appendChild(el("span", "name", v.name || v.record || "?"));
      if (v.record) nameCell.appendChild(el("span", "sub", v.record));
      tr.appendChild(nameCell);

      tr.appendChild(el("td", "n mono",
        v.health === null || v.health === undefined ? "—" : Math.round(v.health * 100) + "%"));

      var aboard = el("td");
      if (v.occupants && v.occupants.length) {
        v.occupants.forEach(function (o) { aboard.appendChild(pill(o.name || o.playerId, "warn")); });
      } else {
        aboard.appendChild(el("span", "dim mono", "empty"));
      }
      tr.appendChild(aboard);

      var cap = el("td");
      if (v.governorTier === "instance") cap.appendChild(pill("this car", "acc"));
      else if (v.governorTier === "record") cap.appendChild(pill("model", "bad"));
      else if (v.governorTier === "global") cap.appendChild(pill("global", "warn"));
      else cap.appendChild(el("span", "dim mono", "stock"));
      tr.appendChild(cap);

      var actions = el("td");
      var id = String(v.vehicleId);
      var occupied = v.occupants && v.occupants.length > 0;

      actions.appendChild(actionButton("Repair", ["admin.veh.repair", id, occupied ? "visual" : "full"]));
      actions.appendChild(actionButton("Engine", ["admin.veh.flag", id, "engineOn"]));
      actions.appendChild(actionButton("Lock", ["admin.veh.flag", id, "locked"]));

      var remove = el("button", "act bad" + (occupied ? " dead" : ""), "Delete");
      remove.type = "button";
      if (occupied) {
        remove.disabled = true;
        remove.title = "Somebody is aboard. Removing an occupied vehicle is refused server-side.";
      } else {
        remove.addEventListener("click", function () { run(["admin.veh.remove", id]); });
      }
      actions.appendChild(remove);

      var tune = el("button", "act", "Tune");
      tune.type = "button";
      tune.addEventListener("click", function () {
        selection.vehicleId = v.vehicleId;
        selection.record = v.record || selection.record;
        selection.name = v.name || selection.name;
        $("sel-name").textContent = selection.name || "Nothing selected";
        $("sel-record").textContent = selection.record || "—";
        $("sel-spawn").disabled = !selection.record;
        $("sel-give").disabled = !selection.record;
        renderVehicles();
        syncGovernorCards();
      });
      actions.appendChild(tune);

      tr.appendChild(actions);
      body.appendChild(tr);
    });
  }

  /* --------------------------------------------------------- the two governors
   *
   * Precedence is instance -> record -> default, resolved natively per vehicle
   * per frame. The card layout mirrors it: the instance card sits above the
   * record card and says it wins, and the record card carries its blast radius
   * in its own copy rather than only in the docs.
   */

  var sliders = {};

  function bounds(field) {
    var config = (boot && boot.governor) || {};
    return config[field] || { min: 0, max: 100, step: 1, default: 0 };
  }

  function initSliders() {
    Array.prototype.forEach.call(document.querySelectorAll(".slider[data-tier]"), function (node) {
      var tier = node.dataset.tier;
      var field = node.dataset.field;
      var input = node.querySelector("input");
      var readout = node.querySelector("label b");
      var range = bounds(field);
      input.min = range.min;
      input.max = range.max;
      input.step = range.step;
      input.value = range.default;
      sliders[tier + ":" + field] = { input: input, readout: readout, field: field };
      input.addEventListener("input", function () { paintSlider(tier, field); });
      paintSlider(tier, field);
    });
  }

  function paintSlider(tier, field) {
    var entry = sliders[tier + ":" + field];
    if (!entry) return;
    var value = Number(entry.input.value);
    if (field === "topSpeedKph") {
      entry.readout.textContent = value <= 0 ? "uncapped" : fmt(value) + " km/h";
    } else if (field === "accelerationScale") {
      entry.readout.textContent = value >= 1 ? "1.00× stock" : value.toFixed(2) + "×";
    } else {
      entry.readout.textContent = fmt(value) + " km/h";
    }
  }

  function loadProfile(tier, profile) {
    ["topSpeedKph", "accelerationScale", "taperKph"].forEach(function (field) {
      var entry = sliders[tier + ":" + field];
      if (!entry) return;
      entry.input.value = profile && profile[field] !== undefined
        ? profile[field] : bounds(field).default;
      paintSlider(tier, field);
    });
  }

  function readProfileTokens(tier) {
    return [
      String(Number(sliders[tier + ":topSpeedKph"].input.value)),
      String(Number(sliders[tier + ":taperKph"].input.value)),
      String(Number(sliders[tier + ":accelerationScale"].input.value)),
    ];
  }

  function syncGovernorCards() {
    var available = state.governor && state.governor.available;
    var instance = (state.governor && state.governor.instance) || {};
    var klass = (state.governor && state.governor.class) || {};

    var hasVehicle = selection.vehicleId !== null && selection.vehicleId !== undefined;
    var hasRecord = !!selection.record;

    $("ti-title").textContent = hasVehicle
      ? "Vehicle " + selection.vehicleId : "No vehicle selected";
    $("tr-title").textContent = hasRecord ? selection.record : "No record selected";

    if (hasVehicle) loadProfile("i", instance[String(selection.vehicleId)] || instance[selection.vehicleId]);
    if (hasRecord) loadProfile("r", klass[selection.record]);

    // A record profile applies to this car only while it has no instance
    // profile of its own -- an instance entry shadows the record outright, and
    // clearing it is what lets the record apply again.
    var shadowed = hasVehicle && hasRecord
      && (instance[String(selection.vehicleId)] || instance[selection.vehicleId])
      && klass[selection.record];
    $("ti-note").textContent = shadowed
      ? "In force. It overrides the model cap below for this car."
      : "Overrides the model cap below.";

    // The instance sliders stay live without a selection: the "my car" pair
    // below them sends the same profile to a server-resolved vehicle, so a
    // selection is only required by the id-addressed buttons.
    Array.prototype.forEach.call(
      document.querySelectorAll('#tier-instance input'),
      function (node) { node.disabled = !available; });
    Array.prototype.forEach.call(
      document.querySelectorAll(
        '[data-act="apply-instance"], [data-act="clear-instance"]'),
      function (node) { node.disabled = !available || !hasVehicle; });
    Array.prototype.forEach.call(
      document.querySelectorAll('[data-act="apply-here"], [data-act="clear-here"]'),
      function (node) { node.disabled = !available; });
    Array.prototype.forEach.call(
      document.querySelectorAll('#tier-record input, #tier-record button'),
      function (node) { node.disabled = !available || !hasRecord; });
    Array.prototype.forEach.call(
      document.querySelectorAll('#tier-global input, #tier-global button'),
      function (node) { node.disabled = !available; });

    // The global sliders follow the stored profile, but only when IT changes:
    // this sync runs on every roster push, and reloading mid-drag would fight
    // the operator's hand once a second.
    var globalProfile = (state.governor && state.governor.global) || null;
    var globalKey = JSON.stringify(globalProfile);
    if (globalKey !== syncGovernorCards.lastGlobalKey) {
      syncGovernorCards.lastGlobalKey = globalKey;
      loadProfile("g", globalProfile);
    }

    var warning = $("gov-unavail");
    if (available) {
      warning.hidden = true;
    } else {
      warning.hidden = false;
      warning.textContent =
        "Performance tuning is unavailable: no connected client has the vehicle governor. "
        + "It ships in the next client build. The controls are disabled rather than silently "
        + "doing nothing.";
    }
    $("f-gov").textContent = available
      ? "governor · " + (state.governor.clients || 0) + " client(s)"
      : "governor · unavailable";
  }

  /* ------------------------------------------------- hold-to-confirm, record */

  function bindHold(button, action) {
    var timer = null;
    var HOLD_MS = 800;
    var label = button.textContent;

    function start() {
      if (button.disabled) return;
      button.textContent = "hold…";
      timer = window.setTimeout(function () {
        timer = null;
        button.textContent = label;
        action();
      }, HOLD_MS);
    }
    function cancel() {
      if (timer !== null) { window.clearTimeout(timer); timer = null; }
      button.textContent = label;
    }
    button.addEventListener("mousedown", start);
    button.addEventListener("mouseup", cancel);
    button.addEventListener("mouseleave", cancel);
  }

  /* -------------------------------------------------------------- tab: world */

  var WEATHER = ["sunny", "clear", "lightclouds", "cloudy", "rain", "fog", "toxicfog",
    "sandstorm", "pollution", "softrain", "rainyclouds", "distantrain", "coldclearsky"];

  function renderWorld() {
    var world = state.world || {};

    var times = $("w-time");
    if (!times.dataset.built) {
      times.dataset.built = "1";
      ["06:00", "09:00", "12:00", "17:30", "20:30", "23:00", "03:00"].forEach(function (clock) {
        var button = el("button", "fac", clock);
        button.type = "button";
        button.addEventListener("click", function () { run(["weather.time.set", clock]); });
        times.appendChild(button);
      });
    }

    var weather = $("w-weather");
    if (!weather.dataset.built) {
      weather.dataset.built = "1";
      WEATHER.forEach(function (name) {
        var button = el("button", "fac", name);
        button.type = "button";
        button.addEventListener("click", function () { run(["weather.set", name]); });
        weather.appendChild(button);
      });
    }

    var locations = $("w-locs");
    clearNode(locations);
    list(world.locations).forEach(function (item) {
      var row = el("div", "row");
      row.appendChild(el("span", "k", item.saved ? "saved" : "config"));
      var value = el("span", "v");
      value.appendChild(el("span", "name", item.label || item.name));
      value.appendChild(el("span", "sub", item.name + " · "
        + fmt(item.position.x) + " " + fmt(item.position.y) + " " + fmt(item.position.z)));
      row.appendChild(value);
      var right = el("span", "r");
      right.appendChild(actionButton("Go", ["admin.player.at", "me", item.name]));
      if (item.saved) {
        right.appendChild(actionButton("Forget", ["admin.world.loc.remove", item.name], "bad"));
      }
      row.appendChild(right);
      locations.appendChild(row);
    });
    if (list(world.locations).length === 0) {
      locations.appendChild(el("p", "empty", "No destinations."));
    }
  }

  /* -------------------------------------------------------------- tab: props */

  // One labelled row of chips per alias family, the family being the text
  // before the first dot. The catalogue is 184 model aliases now, and as one
  // flat run of buttons that is a wall nobody reads. The run order already
  // carries the grouping — `shared/config.lua` keeps each family contiguous —
  // so the only thing missing was the label and the line break.
  //
  // `list()` because these arrive over the bridge, where an EMPTY Lua table
  // encodes as `{}` rather than `[]`; `.forEach` on that object throws.
  function buildAliasChips(container, aliases, onPick) {
    var group = null;
    var family = null;
    list(aliases).forEach(function (alias) {
      var text = String(alias);
      var dot = text.indexOf(".");
      var name = dot > 0 ? text.slice(0, dot) : text;
      if (name !== family) {
        family = name;
        // Flip the container to one row per family on the FIRST group only, so
        // an empty catalogue still renders as the plain chip strip it was.
        container.classList.add("grouped");
        group = el("div", "chipfam");
        group.appendChild(el("span", "cardk chipfamk", name));
        container.appendChild(group);
      }
      var button = el("button", "fac", text);
      button.type = "button";
      button.addEventListener("click", function () { onPick(text); });
      group.appendChild(button);
    });
  }

  // The model catalogue, as a searchable scrolling LIST — the 184-chip wall it
  // replaces was unreadable and would only have grown. One section per family
  // (the text before the first dot), a sticky family header, and one row per
  // alias showing the short name with the full alias beside it. Clicking a row
  // still only fills the model box: a single click that puts a solid object in
  // the world with no confirmable target is exactly the gesture an operator
  // makes by accident while reading a list.
  //
  // No thumbnails and no dimensions, on purpose: the depot pipeline has no
  // renders, and the bounding boxes measured in research were never landed in
  // a manifest. A wrong preview would be worse than none.
  function buildPropList(container, aliases, onPick) {
    var families = [];
    var current = null;
    list(aliases).forEach(function (alias) {
      var text = String(alias);
      var dot = text.indexOf(".");
      var name = dot > 0 ? text.slice(0, dot) : text;
      if (!current || current.name !== name) {
        current = { name: name, items: [] };
        families.push(current);
      }
      current.items.push(text);
    });
    families.forEach(function (family) {
      var section = el("div", "propfam");
      var head = el("div", "propfamh");
      head.appendChild(el("span", "cardk", family.name));
      head.appendChild(el("span", "count", String(family.items.length)));
      section.appendChild(head);
      family.items.forEach(function (alias) {
        var short = alias.length > family.name.length + 1
          ? alias.slice(family.name.length + 1) : alias;
        var row = el("button", "proprow");
        row.type = "button";
        row.dataset.alias = alias;
        row.appendChild(el("span", "name", short));
        row.appendChild(el("span", "sub mono", alias));
        row.addEventListener("click", function () {
          var previous = container.querySelector(".proprow.on");
          if (previous) previous.classList.remove("on");
          row.classList.add("on");
          onPick(alias);
        });
        section.appendChild(row);
      });
      container.appendChild(section);
    });
  }

  // Instant, client-side. A row matches on its full alias (which contains both
  // the family and the short name); a query that names a whole family keeps the
  // family's every row. An emptied-out section hides with its header.
  function filterPropList() {
    var container = $("pr-models");
    var query = ($("pr-filter").value || "").trim().toLowerCase();
    var shown = 0;
    var total = 0;
    Array.prototype.forEach.call(container.querySelectorAll(".propfam"), function (section) {
      var familyName = section.querySelector(".cardk").textContent.toLowerCase();
      var familyMatch = query !== "" && familyName.indexOf(query) !== -1;
      var visible = 0;
      Array.prototype.forEach.call(section.querySelectorAll(".proprow"), function (row) {
        total += 1;
        var hit = query === "" || familyMatch
          || row.dataset.alias.toLowerCase().indexOf(query) !== -1;
        row.hidden = !hit;
        if (hit) visible += 1;
      });
      section.hidden = visible === 0;
      shown += visible;
    });
    $("pr-filtercount").textContent = query === ""
      ? total + " props" : shown + " of " + total;
  }

  // Built once, from the `propModels` / `propEffects` reference sections.
  //
  // The lists are fetched the first time this runs rather than carried in the
  // boot payload. That is not only about their own size: the boot payload is a
  // shared budget, and a tab that adds forty aliases to it is a tab that breaks
  // whichever tab was already closest to the ceiling.
  function buildPropAliases() {
    loadReference("propModels", buildPropAliases);
    loadReference("propEffects", buildPropAliases);
    loadReference("propLight");

    var models = $("pr-models");
    if (reference.propModels && !models.dataset.built) {
      models.dataset.built = "1";
      buildPropList(models, reference.propModels, function (alias) {
        $("pr-model").value = alias;
      });
      $("pr-filter").addEventListener("input", filterPropList);
      filterPropList();
    }
    var effects = $("pr-fxaliases");
    if (reference.propEffects && !effects.dataset.built) {
      effects.dataset.built = "1";
      buildAliasChips(effects, reference.propEffects, function (alias) {
        $("pr-fx").value = alias;
      });
    }
  }

  // The radius box, as zero or one command token. An unparseable entry is left
  // out rather than sent: the server would refuse it once a second.
  function propRadiusToken() {
    var raw = ($("pr-radius").value || "").trim();
    if (!raw) return [];
    var value = Number(raw);
    return isFinite(value) && value > 0 ? [String(value)] : [];
  }

  function renderProps() {
    buildPropAliases();
    var data = state.props || {};
    var rows = list(data.props);
    var body = $("pr-table").tBodies[0];
    clearNode(body);

    $("pr-count").textContent = data.propTotal === undefined
      ? "—"
      : rows.length + " of " + data.propTotal + " · " + (data.owned || 0) + "/" + (data.cap || 0) + " yours";

    rows.forEach(function (row) {
      var tr = el("tr");
      tr.appendChild(el("td", "mono", row.id));

      var modelCell = el("td");
      modelCell.appendChild(el("span", "name", row.model || "?"));
      if (row.resource) modelCell.appendChild(el("span", "sub", row.resource));
      tr.appendChild(modelCell);

      var kindCell = el("td");
      kindCell.appendChild(pill(row.kind || "prop", row.kind === "light" ? "acc" : null));
      tr.appendChild(kindCell);

      var bucketCell = el("td", "n");
      if (row.bucket) bucketCell.appendChild(pill(row.bucket, "warn"));
      else bucketCell.appendChild(el("span", "mono", "0"));
      tr.appendChild(bucketCell);

      tr.appendChild(el("td", "n mono", row.distance === null || row.distance === undefined
        ? "—" : fmt(row.distance, 1) + "m"));
      tr.appendChild(el("td", "mono", row.position
        ? fmt(row.position.x) + " " + fmt(row.position.y) + " " + fmt(row.position.z) : "—"));

      var actions = el("td");
      if (row.ours) {
        // Move reuses the spawn coordinate box. The page never knows where the
        // operator is standing — only the server does — so "move it to me" is
        // not offered here rather than being faked from a stale roster row.
        actions.appendChild(lateActionButton("Move", "admin.props.move", function () {
          var parts = ($("pr-at").value || "").trim().split(/\s+/).filter(Boolean);
          if (parts.length !== 3) {
            logLine("admin.props.move", false, "type x y z in the coordinate box first");
            return null;
          }
          var yaw = $("pr-yaw").value.trim();
          return [row.id].concat(parts, yaw ? [yaw] : []);
        }));
        actions.appendChild(actionButton("Remove", ["admin.props.remove", row.id], "bad"));
        if (row.kind === "light") {
          var on = !row.light || row.light.enabled !== false;
          actions.appendChild(actionButton(on ? "Switch off" : "Switch on",
            ["admin.props.light.toggle", row.id, on ? "off" : "on"]));
        }
      } else {
        // Not ours: the registry refuses every mutation on it. Saying so beats
        // offering a button that always fails.
        actions.appendChild(el("span", "sub", "owned by " + (row.resource || "another resource")));
      }
      tr.appendChild(actions);
      body.appendChild(tr);
    });

    var note = $("pr-note");
    if (denied["admin.read.props"]) {
      note.textContent = "You do not have permission to run /admin.read.props, so this list stays empty.";
    } else if (data.available === false) {
      note.textContent = "This host does not expose the prop registry.";
    } else if (rows.length === 0) {
      note.textContent = data.radius
        ? "No props within " + fmt(data.radius) + " m of you, in bucket " + (data.bucket || 0) + "."
        : "No props.";
    } else {
      note.textContent = "Distances are measured only inside your own routing bucket — "
        + "a prop in another bucket is counted in the total and cannot be shown as near you.";
    }

    var fxNode = $("pr-fxrows");
    clearNode(fxNode);
    var effects = list(data.effects);
    if (effects.length === 0) {
      fxNode.appendChild(el("p", "empty", "No looping effects."));
    } else {
      effects.forEach(function (row) {
        var line = el("div", "row");
        line.appendChild(el("span", "k", row.id));
        var value = el("span", "v");
        value.appendChild(el("span", "name", row.effect || "?"));
        value.appendChild(el("span", "sub", "bucket " + row.bucket + " · "
          + fmt(row.position.x) + " " + fmt(row.position.y) + " " + fmt(row.position.z)
          + " · " + (row.resource || "?")));
        line.appendChild(value);
        var right = el("span", "r");
        if (row.ours) right.appendChild(actionButton("Stop", ["admin.fx.stop", row.id], "bad"));
        else right.appendChild(el("span", "sub", "owned elsewhere"));
        line.appendChild(right);
        fxNode.appendChild(line);
      });
    }
  }

  /* ------------------------------------------------------------ tab: console */

  function renderPalette(commands) {
    var node = $("con-hints");
    clearNode(node);
    var query = $("con-line").value.trim().toLowerCase().replace(/^\//, "");
    var matches = commands.filter(function (entry) {
      return !query || entry.command.toLowerCase().indexOf(query) >= 0;
    }).slice(0, 40);

    if (matches.length === 0) {
      node.appendChild(el("p", "empty",
        commands.length + " commands known. Nothing matches — the palette is contributed by "
        + "every resource on the server, so it only lists what is actually loaded."));
      return;
    }
    matches.forEach(function (entry) {
      var row = el("div", "row");
      row.appendChild(el("span", "k", "cmd"));
      var value = el("span", "v");
      value.appendChild(el("span", "mono", entry.command));
      if (entry.help) value.appendChild(el("span", "sub", entry.help));
      row.appendChild(value);
      row.addEventListener("click", function () {
        $("con-line").value = entry.command.replace(/^\//, "") + " ";
        $("con-line").focus();
      });
      node.appendChild(row);
    });
  }

  var paletteCache = [];

  /* ----------------------------------------------------------------- polling */

  function poll() {
    if (!open) return;
    var tab = document.querySelector(".nav button.on").dataset.tab;
    run(["admin.read.players"]);
    if (tab === "vehicles") run(["admin.read.vehicles"]);
    if (tab === "world" || tab === "overview") run(["admin.read.world"]);
    if (tab === "audit" || tab === "overview") run(["admin.read.audit"]);
    // The panel polls the READ, never `admin.props.list`: the list command
    // answers in prose as well, so polling it would print a sixty-line listing
    // into the operator's chat once a second.
    if (tab === "props") run(["admin.read.props"].concat(propRadiusToken()));
  }

  function startPolling() {
    stopPolling();
    var interval = (boot && boot.limits && boot.limits.rosterPushMs) || 1000;
    // Reads carry a server-side floor of readIntervalMs; polling faster than
    // that only produces refusals, so the page never tries.
    var floor = (boot && boot.limits && boot.limits.readIntervalMs) || 500;
    poller = window.setInterval(poll, Math.max(interval, floor * 2));
    poll();
  }

  function stopPolling() {
    if (poller !== null) { window.clearInterval(poller); poller = null; }
  }

  /* ------------------------------------------------------------------- tabs */

  function showTab(name) {
    Array.prototype.forEach.call(document.querySelectorAll(".nav button"), function (button) {
      button.classList.toggle("on", button.dataset.tab === name);
    });
    Array.prototype.forEach.call(document.querySelectorAll(".tab"), function (section) {
      section.classList.toggle("on", section.dataset.tab === name);
    });
    // Reference data is pulled the first time the tab that reads it is opened,
    // never at boot. Both calls are idempotent and cheap after the first.
    if (name === "vehicles") {
      buildFacets();
      if (catalog.rows.length === 0) refreshCatalog();
    }
    if (name === "props") buildPropAliases();
    poll();
  }

  /* --------------------------------------------------------------- wiring up */

  // Pull one reference section, in whatever number of windows Lua wants to use,
  // then run `whenReady` once. Called from the render that needs the data, so a
  // section is fetched at most once and only if a tab that uses it is opened.
  function loadReference(section, whenReady) {
    if (reference[section] !== null || referenceLoading[section]) return;
    referenceLoading[section] = true;
    var collected = [];

    function pull(offset) {
      Open77.invoke("admin:reference", { section: section, offset: offset })
        .then(function (result) {
          if (!result || result.error) {
            referenceLoading[section] = false;
            report("error", "reference " + section + " refused: "
              + ((result && result.error) || "empty answer"));
            return;
          }
          if (result.value !== undefined) {
            reference[section] = result.value;
            referenceLoading[section] = false;
            if (whenReady) whenReady();
            return;
          }
          // An EMPTY Lua table encodes as `{}`, not `[]` -- the host's encoder
          // decides array-ness from the entries it has, and an empty one has
          // none. `.concat({})` would append the object itself as a row.
          var items = Array.isArray(result.items) ? result.items : [];
          collected = collected.concat(items);
          // Continue only on FORWARD PROGRESS. `done` is set by Lua on every
          // answer, but a reply that lost its shape must cost one wasted round
          // trip, not an unbounded request loop against the game thread.
          if (!result.done && items.length > 0 && collected.length < 4000) {
            pull(collected.length);
            return;
          }
          reference[section] = collected;
          referenceLoading[section] = false;
          if (whenReady) whenReady();
        })
        .catch(function (error) {
          // Degrade, never block: the section stays null, the tab renders
          // without it, and a later open retries.
          referenceLoading[section] = false;
          report("error", "reference " + section + " failed: " + describe(error));
        });
    }

    pull(0);
  }

  function buildFacets() {
    loadReference("groups", buildFacets);
    loadReference("classes", buildFacets);
    loadReference("makers", buildFacets);

    var groups = $("cat-groups");
    clearNode(groups);
    list(reference.groups).forEach(function (group) {
      var button = el("button", "fac" + (catalog.group === group.key ? " on" : ""),
        group.label + " " + group.count);
      button.type = "button";
      button.addEventListener("click", function () {
        catalog.group = catalog.group === group.key ? null : group.key;
        buildFacets();
        refreshCatalog();
      });
      groups.appendChild(button);
    });

    buildMakerFacet();

    var classes = $("cat-classes");
    clearNode(classes);
    list(reference.classes)
      .slice()
      .sort(function (a, b) { return (a.order || 99) - (b.order || 99); })
      .forEach(function (item) {
        var button = el("button", "fac" + (catalog.klass === item.key ? " on" : ""), item.label);
        button.type = "button";
        button.title = item.key + " · " + item.count + " records";
        button.addEventListener("click", function () {
          catalog.klass = catalog.klass === item.key ? null : item.key;
          buildFacets();
          refreshCatalog();
        });
        classes.appendChild(button);
      });
  }

  function closeMakerFacet(focusTrigger) {
    var dropdown = $("cat-makers");
    if (!dropdown) return;
    dropdown.classList.remove("open");
    var trigger = $("cat-makers-trigger");
    trigger.setAttribute("aria-expanded", "false");
    if (focusTrigger) trigger.focus();
  }

  function selectMaker(key, label) {
    catalog.maker = key || null;
    var dropdown = $("cat-makers");
    dropdown.dataset.value = key || "";
    $("cat-makers-trigger").querySelector("span").textContent = label || "every manufacturer";
    Array.prototype.forEach.call(
      dropdown.querySelectorAll(".fac-dropdown-option"), function (option) {
        var selected = option.dataset.value === (key || "");
        option.classList.toggle("on", selected);
        option.setAttribute("aria-selected", selected ? "true" : "false");
      });
    closeMakerFacet(true);
    refreshCatalog();
  }

  function buildMakerFacet() {
    var dropdown = $("cat-makers");
    if (!dropdown) return;
    closeMakerFacet(false);
    var menu = $("cat-makers-menu");
    clearNode(menu);

    var entries = [{ key: "", label: "every manufacturer", count: null }]
      .concat(list(reference.makers)
        .slice()
        .sort(function (a, b) { return b.count - a.count || (a.label < b.label ? -1 : 1); }));
    var selectedLabel = "every manufacturer";
    entries.forEach(function (item, index) {
      var key = item.key || "";
      var label = item.count === null || item.count === undefined
        ? item.label : item.label + "  (" + item.count + ")";
      var option = el("button", "fac-dropdown-option", label);
      option.type = "button";
      option.id = "cat-maker-option-" + index;
      option.dataset.value = key;
      option.setAttribute("role", "option");
      var selected = (catalog.maker || "") === key;
      option.classList.toggle("on", selected);
      option.setAttribute("aria-selected", selected ? "true" : "false");
      if (selected) selectedLabel = label;
      option.addEventListener("click", function (event) {
        event.stopPropagation();
        selectMaker(key, label);
      });
      menu.appendChild(option);
    });
    dropdown.dataset.value = catalog.maker || "";
    $("cat-makers-trigger").querySelector("span").textContent = selectedLabel;
  }

  function wireMakerFacet() {
    var dropdown = $("cat-makers");
    var trigger = $("cat-makers-trigger");
    trigger.addEventListener("click", function (event) {
      event.stopPropagation();
      var opening = !dropdown.classList.contains("open");
      dropdown.classList.toggle("open", opening);
      trigger.setAttribute("aria-expanded", opening ? "true" : "false");
      if (opening) {
        var selected = dropdown.querySelector(".fac-dropdown-option.on")
          || dropdown.querySelector(".fac-dropdown-option");
        if (selected) {
          selected.focus();
          selected.scrollIntoView({ block: "nearest" });
        }
      }
    });
    dropdown.addEventListener("keydown", function (event) {
      var options = Array.prototype.slice.call(
        dropdown.querySelectorAll(".fac-dropdown-option"));
      if (!options.length) return;
      var current = options.indexOf(document.activeElement);
      if (event.key === "ArrowDown" || event.key === "ArrowUp") {
        event.preventDefault();
        if (!dropdown.classList.contains("open")) {
          dropdown.classList.add("open");
          trigger.setAttribute("aria-expanded", "true");
        }
        var direction = event.key === "ArrowDown" ? 1 : -1;
        var fallback = direction > 0 ? -1 : 0;
        options[((current < 0 ? fallback : current) + direction + options.length)
          % options.length].focus();
      } else if (event.key === "Home" || event.key === "End") {
        event.preventDefault();
        options[event.key === "Home" ? 0 : options.length - 1].focus();
      } else if (event.key === "Escape") {
        event.preventDefault();
        event.stopPropagation();
        closeMakerFacet(true);
      } else if (event.key === "Tab") {
        closeMakerFacet(false);
      }
    });
    document.addEventListener("click", function () { closeMakerFacet(false); });
  }

  function wire() {
    $("close").addEventListener("click", function () { Open77.emit("admin:close", {}); });

    Array.prototype.forEach.call(document.querySelectorAll(".nav button"), function (button) {
      button.addEventListener("click", function () { showTab(button.dataset.tab); });
    });

    Array.prototype.forEach.call(document.querySelectorAll("[data-cmd]"), function (button) {
      button.addEventListener("click", function () { run(button.dataset.cmd.split(" ")); });
    });

    $("pl-search").addEventListener("input", renderPlayers);

    var searchTimer = null;
    $("cat-search").addEventListener("input", function () {
      catalog.query = $("cat-search").value.trim();
      if (searchTimer !== null) window.clearTimeout(searchTimer);
      // 1,372 records filtered in Lua per keystroke is wasteful and the codec
      // is bounded; a short debounce makes typing feel the same and costs a
      // fraction of the traffic.
      searchTimer = window.setTimeout(refreshCatalog, 140);
    });

    wireMakerFacet();

    $("cat-sort").addEventListener("click", function () {
      catalog.sort = catalog.sort === "name" ? "speed" : "name";
      $("cat-sort").textContent = "sort · " + catalog.sort;
      $("cat-sort").classList.toggle("on", catalog.sort === "speed");
      refreshCatalog();
    });

    $("cat-player").addEventListener("click", function () {
      catalog.player = !catalog.player;
      $("cat-player").classList.toggle("on", catalog.player);
      refreshCatalog();
    });
    $("cat-police").addEventListener("click", function () {
      catalog.police = !catalog.police;
      $("cat-police").classList.toggle("on", catalog.police);
      refreshCatalog();
    });

    $("sel-spawn").addEventListener("click", function () {
      if (selection.record) run(["admin.veh.spawn", selection.record]);
    });
    $("sel-give").addEventListener("click", function () {
      if (!selection.record) return;
      var target = window.prompt("Give " + selection.name + " to which player id?", "");
      if (target === null || !target.trim()) return;
      run(["admin.veh.give", target.trim(), selection.record]);
    });

    document.querySelector('[data-act="apply-instance"]').addEventListener("click", function () {
      if (selection.vehicleId === null) return;
      run(["admin.veh.speed", String(selection.vehicleId)].concat(readProfileTokens("i")));
    });
    document.querySelector('[data-act="clear-instance"]').addEventListener("click", function () {
      if (selection.vehicleId === null) return;
      run(["admin.veh.speed.clear", String(selection.vehicleId)]);
    });
    document.querySelector('[data-act="clear-record"]').addEventListener("click", function () {
      if (!selection.record) return;
      run(["admin.veh.speed.clear", selection.record]);
    });

    // The record tier is the one that changes every car of a model on the whole
    // server, so it is the one gesture in this panel that cannot be a click.
    bindHold(document.querySelector('[data-act="apply-record"]'), function () {
      if (!selection.record) return;
      run(["admin.veh.speed", selection.record].concat(readProfileTokens("r")));
    });

    // "My car" needs no selection at all: the SERVER resolves the vehicle the
    // operator is aboard, or the nearest spawned one, at the moment of the
    // call. It reuses the instance sliders — the profile is the same shape and
    // the result is the same tier.
    document.querySelector('[data-act="apply-here"]').addEventListener("click", function () {
      run(["admin.veh.speed.here"].concat(readProfileTokens("i")));
    });
    document.querySelector('[data-act="clear-here"]').addEventListener("click", function () {
      run(["admin.veh.speed.clear", "here"]);
    });

    // Global holds every spawned vehicle on the server at once — the same
    // blast radius as the record tier, so the same hold-to-apply gesture.
    bindHold(document.querySelector('[data-act="apply-global"]'), function () {
      run(["admin.veh.speed.global"].concat(readProfileTokens("g")));
    });
    document.querySelector('[data-act="clear-global"]').addEventListener("click", function () {
      run(["admin.veh.speed.clear", "global"]);
    });

    $("self-speed").querySelector("input").addEventListener("change", function (event) {
      var value = Number(event.target.value);
      $("self-speed").querySelector("label b").textContent = value + " m/s";
      run(["admin.self.speed", String(value)]);
    });
    $("self-speed").querySelector("input").addEventListener("input", function (event) {
      $("self-speed").querySelector("label b").textContent = Number(event.target.value) + " m/s";
    });

    $("self-tpgo").addEventListener("click", function () {
      var parts = $("self-tp").value.trim().split(/\s+/).filter(Boolean);
      if (parts.length < 3) { logLine("admin.player.tp", false, "give x y z, and optionally a heading"); return; }
      run(["admin.player.tp", "me"].concat(parts));
    });

    $("w-locadd").addEventListener("click", function () {
      var name = $("w-locname").value.trim();
      if (!name) { logLine("admin.world.loc.add", false, "name the spot first"); return; }
      run(["admin.world.loc.add", name]);
      $("w-locname").value = "";
    });

    $("w-saygo").addEventListener("click", function () {
      var text = $("w-say").value.trim();
      if (!text) return;
      run(["admin.world.announce"].concat(text.split(/\s+/)));
      $("w-say").value = "";
    });

    /* --------------------------------------------------------------- props */

    function propModelTokens() {
      // One token, always: a depot path has no spaces, and an alias has none
      // either. Splitting on whitespace here would turn a typo into a spawn
      // with four stray arguments and a usage line nobody can read.
      var model = $("pr-model").value.trim();
      if (!model) { logLine("admin.props.here", false, "name a model first"); return null; }
      return model;
    }

    function coordinateTokens(id, command) {
      var parts = ($(id).value || "").trim().split(/\s+/).filter(Boolean);
      if (parts.length !== 3) { logLine(command, false, "give x y z — z is the ground"); return null; }
      return parts;
    }

    $("pr-here").addEventListener("click", function () {
      var model = propModelTokens();
      if (model === null) return;
      var yaw = $("pr-yaw").value.trim();
      run(yaw ? ["admin.props.here", model, yaw] : ["admin.props.here", model]);
    });

    $("pr-atgo").addEventListener("click", function () {
      var model = propModelTokens();
      if (model === null) return;
      var position = coordinateTokens("pr-at", "admin.props.spawn");
      if (position === null) return;
      var yaw = $("pr-yaw").value.trim();
      run(["admin.props.spawn", model].concat(position, yaw ? [yaw] : []));
    });

    // Intensity, radius and the three colour channels are POSITIONAL on the
    // command, so a blank box in the middle cannot simply be skipped: the
    // server's defaults are filled in here instead, and the panel sends the
    // complete set.
    function lightTokens() {
      var defaults = reference.propLight || {};
      var intensity = $("pr-lint").value.trim()
        || String((defaults.intensity && defaults.intensity.default) || 20);
      var radius = $("pr-lrad").value.trim()
        || String((defaults.radius && defaults.radius.default) || 10);
      var rgb = ($("pr-lrgb").value || "").trim().split(/\s+/).filter(Boolean);
      if (rgb.length === 0) rgb = ["1", "1", "1"];
      if (rgb.length !== 3) {
        logLine("admin.props.light", false, "colour is three channels, 0–1, e.g. 1 0.4 0.2");
        return null;
      }
      return [intensity, radius].concat(rgb);
    }

    $("pr-lighthere").addEventListener("click", function () {
      var light = lightTokens();
      if (light === null) return;
      run(["admin.props.light.here"].concat(light));
    });

    $("pr-lightgo").addEventListener("click", function () {
      var position = coordinateTokens("pr-lightat", "admin.props.light");
      if (position === null) return;
      var light = lightTokens();
      if (light === null) return;
      run(["admin.props.light"].concat(position, light));
    });

    $("pr-refresh").addEventListener("click", function () {
      run(["admin.read.props"].concat(propRadiusToken()));
    });

    $("pr-fxplay").addEventListener("click", function () {
      var effect = $("pr-fx").value.trim();
      if (!effect) { logLine("admin.fx.play", false, "name an effect first"); return; }
      run(["admin.fx.play", effect]);
    });

    $("pr-fxloop").addEventListener("click", function () {
      var effect = $("pr-fx").value.trim();
      if (!effect) { logLine("admin.fx.loop", false, "name an effect first"); return; }
      run(["admin.fx.loop", effect]);
    });

    function runConsole() {
      var line = $("con-line").value.trim().replace(/^\//, "");
      if (!line) return;
      Open77.emit("admin:command", { line: line });
      logLine(line, null, "sent");
      $("con-line").value = "";
      renderPalette(paletteCache);
    }
    $("con-run").addEventListener("click", runConsole);
    $("con-line").addEventListener("input", function () { renderPalette(paletteCache); });
    $("con-line").addEventListener("keydown", function (event) {
      if (event.key === "Enter") { event.preventDefault(); runConsole(); }
    });

    // The plugin swallows Escape in the window procedure so this rarely fires
    // in a live session -- open77:pauseKey is the path that actually closes the
    // panel. Kept because it is the right thing in every other context.
    document.addEventListener("keydown", function (event) {
      if (event.key === "Escape" && $("cat-makers").classList.contains("open")) {
        event.preventDefault();
        closeMakerFacet(true);
      } else if (event.key === "Escape" && document.body.classList.contains("open")) {
        event.preventDefault();
        Open77.emit("admin:close", {});
      }
    });
  }

  /* ---------------------------------------------------------------- inbound */

  // Everything here is decoration on a shell that is already in the DOM: the
  // panel does not need `boot` to be visible, and must never be gated behind
  // it. The guard is there so a bad field decorates less rather than stopping
  // the rest of the handler -- and says which field, in the log.
  Open77.on("admin:boot", function (payload) {
    boot = payload || {};
    report("info", "boot received: " + Object.keys(boot).join(","));
    try { applyBoot(); } catch (error) { report("error", "boot: " + describe(error)); }
  });

  function applyBoot() {
    $("tag-build").textContent = (boot.catalog && boot.catalog.build) || "2.31";
    $("f-catalog").textContent = ((boot.catalog && boot.catalog.count) || 0) + " records";
    $("self-mods").textContent = (boot.travel && boot.travel.modifiers) || "";
    if (boot.travel && boot.travel.speed) {
      var input = $("self-speed").querySelector("input");
      input.min = boot.travel.speed.min;
      input.max = boot.travel.speed.max;
      input.step = boot.travel.speed.step;
      input.value = boot.travel.speed.default;
      $("self-speed").querySelector("label b").textContent = boot.travel.speed.default + " m/s";
    }
    initSliders();
    // The facet rail and the prop alias chips are NOT built here any more. They
    // are built when their own tab is first opened, from data fetched then —
    // see `loadReference`. Boot stays a handful of scalars, which is what keeps
    // it inside the host's payload ceiling with room for the next tab.
    //
    // They still cost no permission: the alias lists come from this resource's
    // own configuration, not from an ACL-gated read, so an operator whose role
    // omits `admin.read.props` still gets them.
    syncGovernorCards();
  }

  // The server's snapshot, sent by the `/admin` handler that just passed the
  // ACL gate. It arrives before the client's own show signal.
  Open77.on("admin:open", function (payload) {
    if (payload && payload.you) {
      $("who").textContent = (payload.you.name || "?") + " · id " + payload.you.playerId;
    }
  });

  // The client's show signal: this is what actually makes the panel visible.
  Open77.on("admin:show", function () {
    // VISIBILITY FIRST, before anything that can throw.
    //
    // This used to run three statements deep behind `syncStaticButtons()`, and
    // the bridge swallows an exception thrown in here. So any failure above the
    // `classList.add` left the panel focused, mouse captured, `opacity: 0` --
    // indistinguishable from a page that never loaded, and silent. Nothing
    // below this line may be able to prevent the panel from appearing.
    document.body.classList.add("open");
    open = true;

    try {
      // Forget every learned refusal. A grant made in Warden takes effect on
      // the operator's very next command, so reopening the panel has to be the
      // way to pick it up — otherwise a promoted moderator would keep seeing
      // greyed controls until they reconnected, and would reasonably conclude
      // the grant had not worked.
      Object.keys(denied).forEach(function (key) { delete denied[key]; });
      syncStaticButtons();
    } catch (error) { report("error", "show/buttons: " + describe(error)); }

    try { startPolling(); } catch (error) { report("error", "show/poll: " + describe(error)); }
    try { refreshCatalog(); } catch (error) { report("error", "show/catalog: " + describe(error)); }

    report("info", "show applied: " + paintState());
  });

  Open77.on("admin:closed", function () {
    document.body.classList.remove("open");
    open = false;
    stopPolling();
  });

  Open77.on("admin:players", function (payload) {
    pendingPlayers = (payload && payload.offset ? pendingPlayers : []).concat(list(payload && payload.players));
    if (payload && payload.done === false) return;
    state.players = pendingPlayers;
    renderPlayers();
    renderOverview();
  });

  Open77.on("admin:access", function (payload) {
    access = (payload && payload.commands) || {};
    Object.keys(denied).forEach(function (name) { delete denied[name]; });
    Object.keys(access).forEach(function (name) { if (!access[name]) denied[name] = true; });
    if (!access["admin.read.players"]) state.players = [];
    if (!access["admin.read.vehicles"]) state.vehicles = [];
    if (!access["admin.read.audit"]) state.audit = [];
    if (!access["admin.read.world"]) state.world = null;
    if (!access["admin.read.props"]) state.props = null;
    syncStaticButtons();
    renderPlayers(); renderVehicles(); renderWorld(); renderProps(); renderAudit();
  });

  Open77.on("admin:vehicles", function (payload) {
    payload = payload || {};
    state.vehicles = list(payload.vehicles);
    state.governor = payload.governor || null;
    state.rated = payload.ratedTopSpeed || {};
    renderCatalog();
    renderVehicles();
    syncGovernorCards();
    renderOverview();
  });

  Open77.on("admin:world", function (payload) {
    state.world = payload || {};
    // The world read also reports governor availability, and it is the one the
    // panel gets on the Overview tab. Without folding it in, the Overview stat
    // and the footer disagree until somebody happens to open Vehicles.
    if (state.world.governor) {
      state.governor = Object.assign(state.governor || {}, state.world.governor);
      syncGovernorCards();
    }
    renderWorld();
    renderOverview();
  });

  // MERGED, not replaced. Three commands push on this channel and two of them
  // send a slice: `admin.props.catalog` carries only the alias lists, and
  // `admin.fx.list` is answered by the same collector but reached from a
  // different screen. Assigning the payload outright would blank the table
  // every time one of the partial pushes arrived.
  Open77.on("admin:props", function (payload) {
    state.props = Object.assign(state.props || {}, payload || {});
    renderProps();
  });

  Open77.on("admin:audit", function (payload) {
    // The server sends the tail of the ring, not the ring: an empty Lua table
    // also encodes as `{}` rather than `[]`, so both are normalised here.
    state.audit = Array.isArray(payload && payload.entries) ? payload.entries : [];
    renderAudit();
    renderOverview();
  });

  // The palette arrives in windows, and unordered: Lua cannot afford to sort
  // it (see the comment on the client half) and this side can. `offset === 0`
  // starts a new palette rather than appending to the last one, so a republish
  // replaces instead of duplicating.
  Open77.on("admin:palette", function (payload) {
    payload = payload || {};
    var items = Array.isArray(payload.commands) ? payload.commands : [];
    paletteCache = (payload.offset ? paletteCache : []).concat(items);
    if (payload.done) {
      paletteCache.sort(function (a, b) {
        return a.command < b.command ? -1 : a.command > b.command ? 1 : 0;
      });
    }
    renderPalette(paletteCache);
  });

  Open77.on("admin:self", function (payload) {
    if (!payload) return;
    if (payload.noclipSpeed !== undefined) {
      $("self-speed").querySelector("input").value = payload.noclipSpeed;
      $("self-speed").querySelector("label b").textContent = payload.noclipSpeed + " m/s";
    }
  });

  Open77.on("admin:result", function (payload) {
    if (!payload) return;
    var message = String(payload.message || "");
    var name = String(payload.raw || "").split(" ")[0];

    // Learn from the refusal. Lua cannot ask the ACL what this operator holds,
    // so the panel renders optimistically and disables what comes back denied.
    if (payload.ok === false && message.indexOf("permission_denied:") === 0) {
      denied[name] = true;
      message = "You do not have permission to run /" + name;
      // A refused read leaves its screen permanently empty, so the reason has
      // to appear on that screen and not only in the log, where the operator
      // is not looking. Both notes recompute from `denied` on every render.
      renderPlayers();
      renderVehicles();
      renderCatalog();
      renderWorld();
      renderProps();
      syncStaticButtons();
    }
    logLine(payload.raw, payload.ok, message);
  });

  /* -------------------------------------------------------------------- boot */

  // `admin:ready` MUST be emitted, whatever happened above.
  //
  // Lua's `send()` drops every message until the page has reported ready, so a
  // throw anywhere in `wire()` -- one missing element id is enough -- used to
  // cost the panel every inbound message including `admin:show`, while
  // `takeFocus` still captured the mouse. A blank, focused, unclosable panel
  // from one bad `getElementById`. So the wiring is allowed to fail in parts,
  // and the handshake happens regardless.
  try { wire(); } catch (error) { report("error", "wire: " + describe(error)); }

  try { Open77.ready(); } catch (error) { report("error", "ready: " + describe(error)); }
  Open77.emit("admin:ready", {});
  report("info", "page script complete: " + paintState());
})();
