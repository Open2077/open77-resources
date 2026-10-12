/* Compact menu renderer. Lua owns navigation, action targets and confirmations.
 * This page emits readiness, viewport size, diagnostics and nonce-bound text only.
 * Free-text forms capture input temporarily; the ordinary list remains a HUD.
 */
(function () {
  "use strict";

  /* ----------------------------------------------------- failure reporting */
  //
  // Same reasoning as web/app.js, and it applies more here, not less: CEF
  // console output is forwarded through the webhost's `Trace`, which does not
  // reach `red4ext/logs/open77-*.log`, and the WebUI bridge swallows every
  // exception thrown inside an `Open77.on` handler. Without this, a page that
  // dies half way through renders nothing and says nothing, while Lua sees a
  // healthy surface with its handlers registered and its messages accepted.
  var reportCount = 0;
  var reporting = false;

  function describe(value) {
    try {
      if (value instanceof Error) {
        return (value.name || "Error") + ": " + value.message;
      }
      if (value === null || value === undefined) return String(value);
      if (typeof value === "object") return Object.prototype.toString.call(value);
      return String(value);
    } catch (ignored) { return "<undescribable>"; }
  }

  function report(text) {
    if (reporting || reportCount >= 20) return;
    reporting = true;
    reportCount += 1;
    try {
      window.Open77.emit("menu:diag", { text: String(text).slice(0, 400) });
    } catch (ignored) { /* nowhere left to complain to */ }
    reporting = false;
  }

  window.addEventListener("error", function (event) {
    report("uncaught " + (event.message || "?") + " at line " + (event.lineno || 0));
  });
  (function (original) {
    console.error = function () {
      report(Array.prototype.map.call(arguments, describe).join(" "));
      try { original.apply(console, arguments); } catch (ignored) { /* no console */ }
    };
  })(console.error);

  // Lua cannot tell an empty array from an empty map, so a resource that sends
  // a list with nothing in it arrives here as `{}`, not `[]`. `{}` is truthy,
  // so the usual `value || []` guard KEEPS the object: `.length` then reads
  // `undefined` and `.forEach` throws, aborting the whole render. Every list
  // crossing the bridge goes through here. (`web/app.js` carries the same
  // helper for the same reason; this page cannot share it, each surface loads
  // only its own files.)
  function list(value) { return Array.isArray(value) ? value : []; }

  function text(value) { return value === null || value === undefined ? "" : String(value); }

  var elements = {
    title: document.getElementById("title"),
    trail: document.getElementById("trail"),
    list: document.getElementById("list"),
    more: document.getElementById("more"),
    status: document.getElementById("status"),
    roles: document.getElementById("roles"),
    detail: document.getElementById("detail")
  };

  /* Rows are rebuilt rather than diffed. Nine <li> elements at a keypress is
     nothing, and a diff would need a stable key per row that Lua does not
     send -- the same label can appear in two frames meaning two things. */
  function render(payload) {
    payload = payload || {};
    var rows = list(payload.rows);

    elements.title.textContent = text(payload.title) || "ADMIN";
    elements.roles.textContent = text(payload.roles) || "Direct grants";
    elements.detail.textContent = text(payload.detail);
    elements.trail.textContent = text(payload.trail).toUpperCase().split("/").join(" / ");

    var fragment = document.createDocumentFragment();
    for (var index = 0; index < rows.length; index += 1) {
      var row = rows[index] || {};
      var item = document.createElement("li");
      item.className = row.on ? "row on" : "row";
      if (row.disabled) item.classList.add("disabled");
      item.setAttribute("role", "option");
      item.setAttribute("aria-selected", String(!!row.on));
      item.setAttribute("aria-disabled", String(!!row.disabled));

      var label = document.createElement("span");
      label.className = "label";
      label.textContent = text(row.label);
      item.appendChild(label);

      if (row.value !== undefined && row.value !== null && text(row.value) !== "") {
        var value = document.createElement("span");
        value.className = "value";
        value.textContent = text(row.value);
        item.appendChild(value);
      }

      var arrow = document.createElement("span");
      arrow.className = "arrow";
      // The `>` affordance appears on submenu rows and on nothing else, but the
      // element is always present so every label starts at the same x. A menu
      // whose text shifts sideways as the selection moves is unreadable while
      // the player is also moving.
      arrow.textContent = row.arrow ? ">" : "";
      item.appendChild(arrow);

      fragment.appendChild(item);
    }
    elements.list.textContent = "";
    elements.list.appendChild(fragment);

    var total = Number(payload.total) || 0;
    var first = Number(payload.first) || 1;
    var index2 = Number(payload.index) || 0;
    // Only when the window is actually hiding something. On a five-item menu
    // the counter is noise.
    // Escapes, not literal glyphs. The page is served from the resource's own
    // virtual origin and `<script src>` inherits the document charset, but a
    // stray non-UTF-8 read of this file would turn an arrow into mojibake in
    // the one place the operator looks to know the list continues.
    elements.more.textContent = total > rows.length
      ? index2 + " / " + total + (first > 1 ? "  \u2191" : "")
        + (first + rows.length - 1 < total ? "  \u2193" : "")
      : "";

    elements.status.textContent = text(payload.status);
    elements.status.className = payload.ok === false ? "status bad" : "status";

    document.body.classList.add("open");
  }

  function hide() {
    document.body.classList.remove("open");
    closeInput();
  }

  // Send a value plus a Lua-owned nonce, never a command or target.
  var inputId = null;
  var inputMaxBytes = 256;
  var inputPanel = document.getElementById("input-panel");
  var inputValue = document.getElementById("input-value");
  var inputForm = document.getElementById("input-form");
  function closeInput() {
    inputId = null;
    inputPanel.hidden = true;
    inputValue.value = "";
    document.body.classList.remove("typing");
  }
  function cancelInput() { Open77.emit("menu:input:cancel", { id: inputId }); }
  inputForm.addEventListener("submit", function (event) {
    event.preventDefault();
    if (inputId === null) return;
    var value = inputValue.value.trim();
    if (!value || new TextEncoder().encode(value).length > inputMaxBytes) {
      document.getElementById("input-error").textContent = "Enter 1–" + inputMaxBytes + " UTF-8 bytes.";
      return;
    }
    Open77.emit("menu:input:submit", { id: inputId, value: value });
  });
  document.getElementById("input-cancel").addEventListener("click", cancelInput);
  inputValue.addEventListener("keydown", function (event) {
    if (event.key === "Enter" && !event.isComposing) {
      event.preventDefault();
      if (!event.repeat) inputForm.requestSubmit();
    }
  });
  document.addEventListener("keydown", function (event) {
    if (inputId === null) return;
    if (event.key === "Escape") { event.preventDefault(); cancelInput(); }
    if (event.key === "Tab") {
      var controls = [inputValue, document.getElementById("input-cancel"), inputForm.querySelector("button[type=submit]")];
      var at = controls.indexOf(document.activeElement);
      event.preventDefault();
      controls[(at + (event.shiftKey ? 2 : 1)) % controls.length].focus();
    }
  });
  Open77.on("menu:input", function (payload) {
    inputId = payload.id;
    inputMaxBytes = Math.max(1, Math.min(256, Number(payload.maxBytes) || 256));
    inputValue.maxLength = inputMaxBytes;
    document.getElementById("input-title").textContent = text(payload.title);
    document.getElementById("input-label").textContent = text(payload.label);
    document.getElementById("input-hint").textContent = text(payload.hint);
    document.getElementById("input-error").textContent = "";
    inputValue.value = "";
    inputPanel.hidden = false;
    document.body.classList.add("typing");
    inputValue.focus();
  });
  Open77.on("menu:input:close", closeInput);
  Open77.on("menu:input:error", function (payload) {
    document.getElementById("input-error").textContent = text(payload.message);
  });
  Open77.on("menu:noclip", function (payload) {
    var hud = document.getElementById("noclip-hud");
    hud.hidden = !payload.active;
    if (hud.hidden) return;
    var speed = Number(payload.effective) || 0;
    document.getElementById("noclip-speed").textContent = speed.toFixed(speed < 1 ? 2 : speed < 10 ? 1 : 0);
    document.getElementById("noclip-mode").textContent = payload.paused ? "INPUT PAUSED" : payload.slow ? "PRECISION" : payload.boost ? "BOOST" : "NOCLIP";
    document.getElementById("noclip-base").textContent = payload.boost || payload.slow ? "BASE " + Number(payload.speed).toFixed(1) : "";
    hud.classList.toggle("paused", !!payload.paused);
  });
  var announcementTimer;
  Open77.on("menu:announcement", function (payload) {
    clearTimeout(announcementTimer);
    document.getElementById("announcement-title").textContent = "// " + (text(payload.title) || "SERVER ANNOUNCEMENT");
    document.getElementById("announcement-text").textContent = text(payload.text);
    document.getElementById("announcement").hidden = false;
    announcementTimer = setTimeout(function () { document.getElementById("announcement").hidden = true; }, 10000);
  });
  function viewport() {
    var available = innerHeight - (innerHeight <= 600 ? 16 : innerHeight * .32) - 128;
    Open77.emit("menu:viewport", { rows: Math.max(3, Math.min(12, Math.floor((available - 210) / 30))) });
  }
  window.addEventListener("resize", viewport);

  Open77.on("menu:frame", function (payload) {
    try { render(payload); } catch (error) { report("render: " + describe(error)); }
  });

  Open77.on("menu:hide", function () {
    try { hide(); } catch (error) { report("hide: " + describe(error)); }
  });

  // `menu:ready` MUST be emitted whatever happened above: Lua drops every
  // message until the page has reported ready, so a throw before this point
  // would cost the menu every frame it is ever sent.
  try { Open77.ready(); } catch (error) { report("ready: " + describe(error)); }
  Open77.emit("menu:ready", {});
  viewport();
})();
