(() => {
  "use strict";

  // Compact voice line. The Lua side (client/main.lua) publishes one payload:
  // { visible, configured, available, captureEnabled, transmitting,
  //   microphoneDetected, inputLevel, state, mode (label), modeName, distance,
  //   color, key, modeIndex, modeCount, modes, activation, activeTalkers, error }.
  // Everything here is presentation; nothing is decided from the page.
  const STATES = ["idle", "detected", "talking", "muted", "offline"];
  const STATE_LABELS = {
    idle: "Listening",
    detected: "Signal detected",
    talking: "Transmitting",
    muted: "Mic disabled",
    offline: "Voice offline"
  };

  const root = document.getElementById("voice");
  const modeLabel = document.getElementById("modeLabel");
  const distance = document.getElementById("distance");
  const cycleKey = document.getElementById("cycleKey");
  const talkers = document.getElementById("talkers");
  const talkerCount = document.getElementById("talkerCount");
  const meter = document.getElementById("meter");
  const meterBars = [...meter.children];
  const error = document.getElementById("error");

  let previousMode = "";
  let modeAnimationTimer = 0;

  const setText = (element, value) => {
    if (element.textContent !== value) element.textContent = value;
  };
  const setAttribute = (element, name, value) => {
    if (element.getAttribute(name) !== value) element.setAttribute(name, value);
  };
  const toggle = (element, name, enabled) => {
    if (element.classList.contains(name) !== enabled) element.classList.toggle(name, enabled);
  };
  meterBars.forEach((bar, index) => toggle(bar, "hot", index >= meterBars.length - 2));
  setAttribute(meter, "aria-valuemin", "0");
  setAttribute(meter, "aria-valuemax", "100");

  const bounded = (value, max) => String(value ?? "").slice(0, max);
  const clamp = (value, minimum, maximum) => Math.max(minimum, Math.min(maximum, Number(value) || 0));
  const safeColor = value => {
    const text = String(value || "");
    return /^#[0-9a-f]{6}$/i.test(text) ? text : "#22D8E2";
  };

  function resolveState(value, inputLevel) {
    const supplied = bounded(value.state, 16).toLowerCase();
    if (STATES.includes(supplied)) return supplied;
    if (!value.configured || value.available === false) return "offline";
    if (!value.captureEnabled) return "muted";
    if (value.transmitting) return "talking";
    if (value.microphoneDetected || inputLevel > 0.025) return "detected";
    return "idle";
  }

  function animateModeChange(mode) {
    if (!previousMode) {
      previousMode = mode;
      return;
    }
    if (mode === previousMode) return;
    previousMode = mode;
    clearTimeout(modeAnimationTimer);
    root.classList.remove("mode-changing");
    void root.offsetWidth;
    root.classList.add("mode-changing");
    modeAnimationTimer = setTimeout(() => root.classList.remove("mode-changing"), 340);
  }

  function renderMeter(level, state) {
    const enabled = state !== "muted" && state !== "offline";
    const lit = enabled ? Math.round(clamp(level, 0, 1) * meterBars.length) : 0;
    meterBars.forEach((bar, index) => {
      toggle(bar, "lit", index < lit);
    });
    setAttribute(meter, "aria-valuenow", String(Math.round(lit * 100 / meterBars.length)));
  }

  function formatDistance(value) {
    const metres = Math.max(0, Number(value) || 0);
    if (metres > 0 && metres < 10 && !Number.isInteger(metres)) return metres.toFixed(1);
    return String(Math.round(metres));
  }

  function render(value = {}) {
    const inputLevel = clamp(value.inputLevel, 0, 1);
    const state = resolveState(value, inputLevel);
    const activeMode = bounded(value.modeName || value.mode || "normal", 24).toLowerCase();
    const label = bounded(value.mode || value.modeName || "Voice", 24);
    const key = bounded(value.key || "F11", 12).toUpperCase();
    const heard = Math.max(0, Math.round(Number(value.activeTalkers) || 0));

    toggle(root, "visible", value.visible !== false);
    for (const name of STATES) toggle(root, `state-${name}`, name === state);
    const color = safeColor(value.color);
    if (root.style.getPropertyValue("--mode-color") !== color) root.style.setProperty("--mode-color", color);

    setText(modeLabel, label);
    setText(distance, formatDistance(value.distance));
    setText(cycleKey, key);
    setText(talkerCount, String(heard));
    if (talkers.hidden !== (heard === 0)) talkers.hidden = heard === 0;

    renderMeter(inputLevel, state);
    animateModeChange(activeMode);

    const errorText = bounded(value.error, 80);
    setText(error, errorText);
    toggle(error, "active", errorText.length > 0);

    setAttribute(root, "aria-label",
      `Voice ${STATE_LABELS[state]}, ${label}, ${formatDistance(value.distance)} metres`);
    setAttribute(root, "title", `${STATE_LABELS[state]} · ${label} · ${formatDistance(value.distance)} m · ${key}`);
  }

  Open77.on("open-voice:update", render);
  Open77.ready();
  Open77.emit("open-voice:ready", {});
})();
