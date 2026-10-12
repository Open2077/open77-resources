(function () {
  "use strict";
  const $ = id => document.getElementById(id);
  const emit = (name, value = {}) => Open77.emit(name, value);
  const editor = $("editor");

  // DOM listboxes stay inside the CEF compositor; native select popups do not.
  function dropdown(id, choices, selected) {
    const root = $(id);
    root.replaceChildren();
    const trigger = document.createElement("button");
    trigger.type = "button";
    trigger.setAttribute("aria-haspopup", "listbox");
    trigger.setAttribute("aria-expanded", "false");
    const list = document.createElement("div");
    list.id = id + "-options";
    list.className = "dropdown-options";
    list.setAttribute("role", "listbox");
    list.setAttribute("aria-label", root.getAttribute("aria-label"));
    trigger.setAttribute("aria-controls", list.id);
    list.hidden = true;
    const close = () => { list.hidden = true; trigger.setAttribute("aria-expanded", "false"); };
    root.closeDropdown = close;
    function choose(value) {
      const entry = choices.find(item => item.value === value) || choices[0];
      root.dataset.value = entry ? entry.value : "";
      trigger.textContent = entry ? entry.label : "No options";
      trigger.disabled = !entry;
      for (const option of list.children) option.setAttribute("aria-selected", String(option.dataset.value === root.dataset.value));
    }
    for (const entry of choices) {
      const option = document.createElement("button");
      option.type = "button";
      option.setAttribute("role", "option");
      option.dataset.value = entry.value;
      option.textContent = entry.label;
      option.addEventListener("click", () => {
        choose(entry.value); close(); trigger.focus();
        root.dispatchEvent(new Event("change", { bubbles: true }));
      });
      list.append(option);
    }
    root.append(trigger, list);
    choose(selected);
    trigger.addEventListener("click", () => {
      const opening = list.hidden;
      document.querySelectorAll(".dropdown").forEach(other => other.closeDropdown?.());
      if (opening) {
        list.hidden = false; trigger.setAttribute("aria-expanded", "true");
        (list.querySelector('[aria-selected="true"]') || list.firstElementChild)?.focus();
      }
    });
    root.onkeydown = event => {
      if (event.key === "Escape" && !list.hidden) {
        event.preventDefault(); event.stopPropagation(); close(); trigger.focus();
      } else if (["ArrowDown", "ArrowUp", "Home", "End"].includes(event.key)) {
        event.preventDefault(); event.stopPropagation();
        const options = Array.from(list.children);
        if (!options.length) return;
        list.hidden = false; trigger.setAttribute("aria-expanded", "true");
        const index = options.indexOf(document.activeElement);
        const next = event.key === "Home" ? 0 : event.key === "End" ? options.length - 1
          : (index + (event.key === "ArrowUp" ? -1 : 1) + options.length) % options.length;
        options[next].focus();
      } else if (event.key === "Tab") close();
    };
  }
  document.addEventListener("click", event => {
    document.querySelectorAll(".dropdown").forEach(root => { if (!root.contains(event.target)) root.closeDropdown?.(); });
  });

  let models = [];
  let cameras = [];
  let definitions = [];
  let limits = { maxDefinitions: 24 };
  let editingKey = null;
  let draft = null;
  let aspectRatio = 16 / 9;
  let aspectLocked = true;
  let stepMode = "fine";
  let liveModes = { follow: false, snap: false };
  // The effective bindings as the engine reports them, and when the last mode
  // key was accepted: the page owns the keyboard while it is visible, the game's
  // mapping covers the hidden state.
  let liveKeys = { follow: "F6", snap: "F7" };
  let lastModeKeyAt = 0;
  let cameraPropModel = null;
  let cameraPropDefault = "electronics.camera";
  let busy = false;
  let lastRect = "";
  let emitTimer = 0;

  // --- utility -------------------------------------------------------------
  function message(text, kind = "") {
    const status = $("status");
    status.textContent = text;
    status.className = kind;
  }
  function clamp(value, low, high) { return Math.min(high, Math.max(low, value)); }
  function fixed(value, decimals) { return Number(value).toFixed(decimals); }
  function reasonText(reason) {
    return String(reason == null ? "unknown" : reason).replace(/_/g, " ");
  }

  // --- numeric rows --------------------------------------------------------
  // step[0] is the fine increment, step[1] the coarse one. Ranges mirror the
  // published contract: FOV 1..120, range 1..500, display 0.05..40 m.
  const FIELDS = {
    "camera-x": { label: "CAMERA X (m)", path: ["camera", "position", "x"], step: [0.05, 0.5], digits: 3, min: -100000, max: 100000 },
    "camera-y": { label: "CAMERA Y (m)", path: ["camera", "position", "y"], step: [0.05, 0.5], digits: 3, min: -100000, max: 100000 },
    "camera-z": { label: "CAMERA Z (m)", path: ["camera", "position", "z"], step: [0.05, 0.5], digits: 3, min: -100000, max: 100000 },
    "camera-yaw": { label: "YAW (deg)", path: ["camera", "rotation", "yaw"], step: [1, 15], digits: 1, wrap: true },
    "camera-pitch": { label: "PITCH (deg)", path: ["camera", "rotation", "pitch"], step: [1, 15], digits: 1, min: -89, max: 89 },
    "camera-roll": { label: "ROLL (deg)", path: ["camera", "rotation", "roll"], step: [1, 15], digits: 1, min: -180, max: 180 },
    "camera-fov": { label: "FOV (deg)", path: ["camera", "fov"], step: [1, 10], digits: 1, min: 1, max: 120 },
    "camera-range": { label: "RANGE (m)", path: ["camera", "range"], step: [5, 25], digits: 0, min: 1, max: 500 },
    "place-x": { label: "X (m)", path: ["placement", "position", "x"], step: [0.05, 0.5], digits: 3, min: -100000, max: 100000 },
    "place-y": { label: "Y (m)", path: ["placement", "position", "y"], step: [0.05, 0.5], digits: 3, min: -100000, max: 100000 },
    "place-z": { label: "Z (m)", path: ["placement", "position", "z"], step: [0.05, 0.5], digits: 3, min: -100000, max: 100000 },
    "place-yaw": { label: "YAW (deg)", path: ["placement", "rotation", "yaw"], step: [1, 15], digits: 1, wrap: true },
    "place-pitch": { label: "PITCH (deg)", path: ["placement", "rotation", "pitch"], step: [1, 15], digits: 1, min: -90, max: 90 },
    "place-roll": { label: "ROLL (deg)", path: ["placement", "rotation", "roll"], step: [1, 15], digits: 1, min: -180, max: 180 },
    "place-width": { label: "WIDTH (m)", path: ["placement", "width"], step: [0.05, 0.5], digits: 3, min: 0.05, max: 40 },
    "place-height": { label: "HEIGHT (m)", path: ["placement", "height"], step: [0.05, 0.5], digits: 3, min: 0.05, max: 40 },
    "depth": { label: "DEPTH (m)", path: ["depth"], step: [0.01, 0.1], digits: 3, min: -1, max: 5 },
    "radius": { label: "RADIUS (m)", path: ["placement", "radius"], step: [1, 5], digits: 0, min: 1, max: 500 }
  };
  const inputs = {};

  function readPath(object, path) {
    let node = object;
    for (const key of path) { if (node == null) return undefined; node = node[key]; }
    return node;
  }
  function writePath(object, path, value) {
    let node = object;
    for (let i = 0; i < path.length - 1; i += 1) node = node[path[i]];
    node[path[path.length - 1]] = value;
  }
  function wrapDegrees(value) { return ((value + 180) % 360 + 360) % 360 - 180; }

  function buildRow(id) {
    const spec = FIELDS[id];
    const host = $(`row-${id}`);
    if (!host) return;
    host.replaceChildren();
    const label = document.createElement("label");
    label.setAttribute("for", `in-${id}`);
    label.textContent = spec.label;
    const input = document.createElement("input");
    input.id = `in-${id}`;
    input.type = "text";
    input.inputMode = "decimal";
    input.autocomplete = "off";
    input.spellcheck = false;
    const down = document.createElement("button");
    down.type = "button"; down.textContent = "\u2212"; down.setAttribute("aria-label", `Decrease ${spec.label}`);
    const up = document.createElement("button");
    up.type = "button"; up.textContent = "+"; up.setAttribute("aria-label", `Increase ${spec.label}`);
    host.append(label, input, down, up);
    inputs[id] = input;

    const commit = raw => {
      const value = Number(String(raw).trim());
      if (!Number.isFinite(value)) { refreshFields(); return; }
      setField(id, value);
    };
    const nudge = (direction, coarse) => {
      const current = Number(input.value);
      if (!Number.isFinite(current)) return;
      const step = (coarse || stepMode === "coarse") ? spec.step[1] : spec.step[0];
      setField(id, current + direction * step);
    };
    input.addEventListener("change", () => commit(input.value));
    input.addEventListener("keydown", event => {
      if (event.key === "Enter") { commit(input.value); input.blur(); event.preventDefault(); return; }
      // Arrows walk the focused field with the same increments as the buttons,
      // so a placement can be finished without touching the mouse. Shift always
      // means the coarse step, whatever the bar says.
      const direction = event.key === "ArrowUp" ? 1 : (event.key === "ArrowDown" ? -1 : 0);
      if (direction !== 0) { event.preventDefault(); nudge(direction, event.shiftKey); }
    });

    // Press and hold walks the value; a single click still moves exactly one
    // step. The keyboard path arrives as a click with detail 0, so it is kept.
    let holdDelay = 0;
    let holdRepeat = 0;
    const stopHold = () => {
      window.clearTimeout(holdDelay);
      window.clearInterval(holdRepeat);
      holdDelay = 0;
      holdRepeat = 0;
    };
    const beginHold = direction => {
      stopHold();
      nudge(direction);
      holdDelay = window.setTimeout(() => {
        holdRepeat = window.setInterval(() => nudge(direction), 55);
      }, 320);
    };
    for (const [button, direction] of [[down, -1], [up, 1]]) {
      button.addEventListener("pointerdown", event => { event.preventDefault(); beginHold(direction); });
      button.addEventListener("pointerup", stopHold);
      button.addEventListener("pointerleave", stopHold);
      button.addEventListener("pointercancel", stopHold);
      button.addEventListener("click", event => { if (event.detail === 0) nudge(direction); });
    }
  }

  function setField(id, value) {
    const spec = FIELDS[id];
    if (spec.wrap) value = wrapDegrees(value);
    if (spec.min !== undefined) value = clamp(value, spec.min, spec.max);
    if (id === "place-width" && aspectLocked) {
      value = clamp(value, Math.max(0.05, 0.05 * aspectRatio), Math.min(40, 40 * aspectRatio));
      writePath(draft, spec.path, value);
      writePath(draft, ["placement", "height"], value / aspectRatio);
    } else if (id === "place-height" && aspectLocked) {
      value = clamp(value, Math.max(0.05, 0.05 / aspectRatio), Math.min(40, 40 / aspectRatio));
      writePath(draft, spec.path, value);
      writePath(draft, ["placement", "width"], value * aspectRatio);
    } else {
      writePath(draft, spec.path, value);
    }
    if (/^place-(x|y|z|yaw|pitch|roll)$/.test(id)) {
      // A typed pose is manual from here on: the retained surface anchor no
      // longer describes it, so depth cannot be re-applied to it.
      draft.anchor = null;
      $("place-meta").textContent = "manual pose";
    }
    refreshFields();
    queueDraft();
  }

  function refreshFields() {
    if (!draft) return;
    for (const [id, spec] of Object.entries(FIELDS)) {
      const value = readPath(draft, spec.path);
      const input = inputs[id];
      if (!input || value === undefined) continue;
      if (document.activeElement !== input) input.value = fixed(value, spec.digits);
    }
  }

  function setStepMode(mode) {
    stepMode = mode;
    $("step-fine").classList.toggle("selected", mode === "fine");
    $("step-coarse").classList.toggle("selected", mode === "coarse");
    $("step-fine").setAttribute("aria-pressed", String(mode === "fine"));
    $("step-coarse").setAttribute("aria-pressed", String(mode === "coarse"));
  }

  // --- draft plumbing ------------------------------------------------------
  function currentDraft() {
    return {
      name: $("name").value.trim(),
      model: draft.model,
      cameraKey: draft.cameraKey || null,
      camera: draft.camera,
      placement: draft.placement,
      depth: draft.depth,
      anchor: draft.anchor,
      // The housing is authored by the toggle, not by a field: the page only
      // carries whatever the Lua side put in the draft.
      housing: draft.housing || null
    };
  }
  function queueDraft() {
    if (!draft || emitTimer) return;
    emitTimer = window.setTimeout(() => { emitTimer = 0; if (draft) emit("editor:draft", { draft: currentDraft() }); }, 70);
  }

  function updateSpaceLabels() {
    const parent = draft.placement.parent;
    const local = parent != null;
    $("place-space-title").textContent = local ? "Position (local, m)" : "Position (world, m)";
    $("place-rot-title").textContent = local ? "Rotation (local, deg)" : "Rotation (world, deg)";
    $("clear-parent").hidden = !local;
    const storable = local && (parent.type === "player" || parent.type === "vehicle" || parent.type === "prop");
    const last = draft.lastParent;
    let text;
    if (local && storable) {
      text = `Parented to ${parent.type} ${parent.id}: the live screen follows it while this session holds it, and the ` +
        `world pose saved next to it is what a restart restores — re-select the parent after that.`;
    } else if (local) {
      text = `Parented to ${parent.type} ${parent.id} for the LOCAL PREVIEW only: a client-only identity has no service ` +
        `record, so SAVE stores the world pose captured at that moment.`;
    } else if (last) {
      text = `Last parent was ${last.type} ${last.id}. A runtime id is never reattached by number on restore, so the ` +
        `stored record is its world pose — aim at a player or vehicle and SNAP to parent it again.`;
    } else {
      text = "Not parented: the pose below is in world space. A surface hit on a player or a vehicle offers a parent that follows it.";
    }
    $("parent-note").className = (local && !storable) ? "note warn" : (local ? "note ok" : "note");
    $("parent-note").textContent = text;
  }

  function updateEditingChrome() {
    $("delete").hidden = editingKey == null;
    $("save-meta").textContent = editingKey == null ? "unsaved draft" : `editing ${editingKey}`;
    $("key-note").textContent = editingKey == null ? "Key: allocated on save." : `Key: ${editingKey}`;
    $("source-meta").textContent = draft.cameraKey ? `shared camera ${draft.cameraKey}` : "owned camera";
    $("camera-note").textContent = draft.cameraKey
      ? "This placement reuses an existing camera. Its pose is not edited here."
      : "This placement's camera is created or updated at this pose on SAVE.";
    const shared = draft.cameraKey != null;
    for (const id of ["camera-x", "camera-y", "camera-z", "camera-yaw", "camera-pitch", "camera-roll", "camera-fov", "camera-range"]) {
      if (inputs[id]) inputs[id].disabled = shared;
    }
    $("camera-from-view").disabled = shared;
  }

  function modelOptions() {
    const choices = [];
    for (const model of models) {
      const dims = model.defaultWidth && model.defaultHeight
        ? ` (${model.defaultWidth} x ${model.defaultHeight} m${model.frameless ? ", frameless" : ""})`
        : "";
      // The basis is the native's own answer, and the yaw offset it carries is
      // applied by the client on every presentation, never into the draft.
      const basis = model.basis
        ? `, front ${model.basis.normal}${model.basis.yawOffset ? ` yaw+${model.basis.yawOffset}` : ""}`
        : "";
      choices.push({ value: model.id, label: model.id + dims + basis });
    }
    dropdown("model-select", choices, draft?.model || "");
  }

  function cameraOptions() {
    const choices = [{ value: "", label: "OWNED — create or edit at this pose" }];
    for (const camera of cameras) {
      choices.push({ value: camera.key, label: `${camera.key} (bucket ${camera.bucket == null ? "?" : camera.bucket})` });
    }
    dropdown("camera-select", choices, draft?.cameraKey || "");
  }

  function newDraft(value) {
    draft = value;
    aspectRatio = clamp(draft.placement.width / draft.placement.height, 0.05, 20);
    editingKey = draft.key || null;
    $("name").value = draft.name || "";
    dropdown("access-select", [
      { value: "granted", label: "granted — you, plus explicit viewer grants" },
      { value: "public", label: "public — anyone within the radius" }
    ], draft.placement.access || "granted");
    $("place-meta").textContent = draft.anchor ? "snapped surface" : "manual pose";
    modelOptions();
    cameraOptions();
    refreshFields();
    updateSpaceLabels();
    updateEditingChrome();
  }

  // --- saved list ----------------------------------------------------------
  function renderSaved() {
    const list = $("saved-list");
    const scrollTop = list.scrollTop;
    list.replaceChildren();
    $("saved-count").textContent = `${definitions.length} / ${limits.maxDefinitions}`;
    if (!definitions.length) {
      const empty = document.createElement("p");
      empty.className = "empty";
      empty.textContent = "No saved placements yet. Save one and it appears here, live and after a restart.";
      list.append(empty);
      return;
    }
    for (const row of definitions) {
      const item = document.createElement("div");
      item.className = "saved-row" + (row.key === editingKey ? " current" : "");
      const title = document.createElement("div");
      title.className = "title";
      const name = document.createElement("strong");
      name.textContent = row.name;
      const state = document.createElement("span");
      state.className = "meta";
      state.textContent = String(row.state || "?").toUpperCase();
      if (row.reason) state.title = reasonText(row.reason);
      title.append(name, state);
      const id = document.createElement("div");
      id.className = "id";
      id.textContent = `key ${row.key} · camera ${row.cameraKey} · screen ${row.screenId == null ? "-" : row.screenId} · ` +
        `${row.model} ${fixed(row.width, 3)}x${fixed(row.height, 3)} m · ${row.access} r${row.radius}` +
        (row.lastParent ? ` · last parent ${row.lastParent.type} ${row.lastParent.id} (world pose stored)` : "") +
        (row.notice ? ` · ${reasonText(row.notice)}` : "") +
        (row.viewerState ? ` · you: ${row.viewerState}${row.viewerReason ? " (" + reasonText(row.viewerReason) + ")" : ""}` : "");
      const actions = document.createElement("div");
      actions.className = "actions";
      const edit = document.createElement("button");
      edit.textContent = "EDIT";
      edit.disabled = busy;
      edit.addEventListener("click", () => { if (!busy) emit("editor:action", { action: "reopen", key: row.key }); });
      const remove = document.createElement("button");
      remove.className = "danger";
      remove.textContent = "DELETE";
      remove.disabled = busy;
      remove.addEventListener("click", () => {
        if (busy) return;
        busy = true;
        message(`Deleting ${row.key}…`);
        emit("editor:action", { action: "delete", key: row.key });
      });
      actions.append(edit, remove);
      item.append(title, id, actions);
      list.append(item);
    }
    list.scrollTop = scrollTop;
  }

  // --- preview rectangle ---------------------------------------------------
  function publishRect() {
    const hole = $("hole");
    if (editor.hidden || hole.offsetParent === null) return;
    const rect = hole.getBoundingClientRect();
    const payload = {
      x: Math.round(rect.left), y: Math.round(rect.top),
      width: Math.max(16, Math.round(rect.width)), height: Math.max(16, Math.round(rect.height))
    };
    const signature = JSON.stringify(payload);
    if (signature === lastRect) return;
    lastRect = signature;
    emit("editor:rect", payload);
  }

  // --- state chips ---------------------------------------------------------
  const CHIPS = { source: "chip-source", feed: "chip-feed", world: "chip-world", panel: "chip-panel", budget: "chip-budget", bucket: "chip-bucket" };
  function renderStates(states) {
    for (const [key, id] of Object.entries(CHIPS)) {
      const value = states[key];
      if (value === undefined || value === null) continue;
      const chip = $(id);
      const state = typeof value === "string" ? value : (value.state || "unknown");
      chip.dataset.state = state;
      let text = String(state).toUpperCase();
      if (typeof value === "object" && value.detail) text += ` ${value.detail}`;
      chip.querySelector("b").textContent = text;
      chip.title = typeof value === "object" && value.reason ? reasonText(value.reason) : "";
    }
    if (states.localPreview) {
      const state = typeof states.localPreview === "string" ? states.localPreview : states.localPreview.state;
      const on = state !== "hidden";
      $("preview-toggle").classList.toggle("selected", on);
      $("preview-toggle").setAttribute("aria-pressed", String(on));
      if (typeof states.localPreview === "object" && states.localPreview.reason) {
        $("preview-toggle").title = `Local placement preview: ${state} (${reasonText(states.localPreview.reason)})`;
      }
    }
  }

  // --- wiring --------------------------------------------------------------
  function wire() {
    for (const id of Object.keys(FIELDS)) buildRow(id);
    setStepMode("fine");
    $("step-fine").addEventListener("click", () => setStepMode("fine"));
    $("step-coarse").addEventListener("click", () => setStepMode("coarse"));

    $("name").addEventListener("input", queueDraft);

    $("model-select").addEventListener("change", () => {
      if (!draft) return;
      draft.model = $("model-select").dataset.value;
      const model = models.find(entry => entry.id === draft.model);
      if (model && model.defaultWidth && model.defaultHeight) {
        draft.placement.width = model.defaultWidth;
        draft.placement.height = model.defaultHeight;
        aspectRatio = clamp(model.defaultWidth / model.defaultHeight, 0.05, 20);
        refreshFields();
        message(`Model ${model.id}: display reset to its authored ${model.defaultWidth} x ${model.defaultHeight} m.`, "ok");
      } else {
        message(`Model set to ${draft.model}.`);
      }
      queueDraft();
    });

    $("camera-select").addEventListener("change", () => {
      if (!draft) return;
      draft.cameraKey = $("camera-select").dataset.value || null;
      updateEditingChrome();
      queueDraft();
    });

    $("access-select").addEventListener("change", () => {
      if (!draft) return;
      draft.placement.access = $("access-select").dataset.value;
      queueDraft();
    });

    $("aspect").addEventListener("click", () => {
      if (!draft) return;
      aspectLocked = !aspectLocked;
      if (aspectLocked) aspectRatio = clamp(draft.placement.width / draft.placement.height, 0.05, 20);
      $("aspect").classList.toggle("selected", aspectLocked);
      $("aspect").setAttribute("aria-pressed", String(aspectLocked));
      message(aspectLocked ? `Aspect lock on (${aspectRatio.toFixed(3)}:1).` : "Aspect lock off: width and height move independently.");
    });

    $("flip").addEventListener("click", () => {
      if (!draft) return;
      draft.placement.rotation.yaw = wrapDegrees(draft.placement.rotation.yaw + 180);
      refreshFields();
      queueDraft();
      message("Flipped the display face by 180 degrees.");
    });

    $("preview-toggle").addEventListener("click", () => emit("editor:togglePreview"));

    $("snap").addEventListener("click", () => {
      if (busy || !draft) return;
      emit("editor:snap");
    });

    $("clear-parent").addEventListener("click", () => {
      if (!draft || !draft.placement.parent) return;
      emit("editor:unparent");
    });

    $("camera-from-view").addEventListener("click", () => emit("editor:cameraFromView"));

    $("follow").addEventListener("click", () => emit("editor:toggleFollow"));
    $("livesnap").addEventListener("click", () => emit("editor:toggleSnap"));
    $("live-off").addEventListener("click", () => emit("editor:liveOff"));
    $("live-camera").addEventListener("click", () => emit("editor:toggleFollow"));
    $("live-surface").addEventListener("click", () => emit("editor:toggleSnap"));

    $("camprop").addEventListener("click", () => {
      // The model lives on the Lua side: the page only asks for the default one
      // or for it to go away, so a refused alias can clear the toggle itself.
      emit("editor:cameraProp", { model: cameraPropModel ? null : (cameraPropDefault || "electronics.camera") });
    });

    $("reset").addEventListener("click", () => {
      if (busy) return;
      emit("editor:action", { action: "reset" });
    });

    $("hide-ui").addEventListener("click", () => {
      editor.classList.toggle("hidden-ui");
      $("hide-ui").textContent = editor.classList.contains("hidden-ui") ? "SHOW UI" : "HIDE UI";
      window.setTimeout(publishRect, 0);
    });

    $("release").addEventListener("click", () => emit("editor:releaseCursor"));

    $("close").addEventListener("click", () => emit("editor:action", { action: "close" }));
    $("cancel").addEventListener("click", () => emit("editor:action", { action: "close" }));

    $("save").addEventListener("click", () => {
      if (busy || !draft) return;
      const name = $("name").value.trim();
      if (name.length === 0) { message("Give the placement a name before saving.", "bad"); $("name").focus(); return; }
      busy = true;
      $("save").disabled = true;
      message("Saving: the server has not confirmed anything yet.");
      emit("editor:action", { action: "save", spec: currentDraft() });
    });

    $("delete").addEventListener("click", () => {
      if (busy || !editingKey) return;
      busy = true;
      message(`Deleting ${editingKey}…`);
      emit("editor:action", { action: "delete", key: editingKey });
    });

    $("copy-lua").addEventListener("click", () => emit("editor:copy", { kind: "lua" }));
    $("copy-json").addEventListener("click", () => emit("editor:copy", { kind: "json" }));

    document.addEventListener("keydown", event => {
      if (event.key === "Escape") {
        event.preventDefault();
        emit("editor:action", { action: "close" });
        return;
      }
      // Handle visible-page input here and hidden-page input through the engine
      // mapping. Lua also debounces deliveries shared by both paths.
      if (event.key !== liveKeys.follow && event.key !== liveKeys.snap) return;
      event.preventDefault();
      if (event.repeat) return;
      const at = performance.now();
      if (at - lastModeKeyAt < 150) return;
      lastModeKeyAt = at;
      emit(event.key === liveKeys.follow ? "editor:toggleFollow" : "editor:toggleSnap");
    });

    new ResizeObserver(publishRect).observe($("hole"));
    window.addEventListener("resize", publishRect);
  }

  // --- page protocol -------------------------------------------------------
  function applyDraftPayload(value) {
    if (!draft) return;
    for (const key of ["model", "camera", "placement", "anchor", "housing"]) {
      if (value[key] !== undefined) draft[key] = value[key];
    }
    if (value.cameraKey !== undefined) draft.cameraKey = value.cameraKey;
    if (value.key !== undefined) draft.key = value.key;
    if (value.lastParent !== undefined) draft.lastParent = value.lastParent;
    if (typeof value.depth === "number") draft.depth = value.depth;
    if (value.name !== undefined) { draft.name = value.name; $("name").value = value.name; }
    aspectRatio = clamp(draft.placement.width / draft.placement.height, 0.05, 20);
    $("place-meta").textContent = draft.anchor ? "snapped surface" : "manual pose";
    modelOptions();
    cameraOptions();
    refreshFields();
    updateSpaceLabels();
    updateEditingChrome();
  }

  Open77.on("editor:open", value => {
    models = Array.isArray(value.models) && value.models.length
      ? value.models
      : [{ id: "surface", defaultWidth: 1.6, defaultHeight: 0.9, frameless: true,
           basis: { space: "entity_local", normal: "-Y", yawOffset: 0 } },
         { id: "panel", defaultWidth: 1.6, defaultHeight: 0.9, frameless: false,
           basis: { space: "authored_mesh_face", normal: "mesh_face", yawOffset: 90 } }];
    cameras = Array.isArray(value.cameras) ? value.cameras : [];
    definitions = Array.isArray(value.definitions) ? value.definitions : [];
    limits = value.limits || limits;
    $("chip-bucket").dataset.state = "active";
    $("chip-bucket").querySelector("b").textContent = value.bucket == null ? "?" : String(value.bucket);
    if (value.focusKey) $("hint-key").textContent = value.focusKey;
    if (value.followKey) { liveKeys.follow = value.followKey; $("key-follow").textContent = value.followKey; $("hint-follow").textContent = value.followKey; }
    if (value.liveSnapKey) { liveKeys.snap = value.liveSnapKey; $("key-live").textContent = value.liveSnapKey; $("hint-live").textContent = value.liveSnapKey; }
    setLiveUI(value.live || {});
    if (value.cameraProp) {
      if (value.cameraProp.default) cameraPropDefault = value.cameraProp.default;
      setCameraPropUI(value.cameraProp.model);
    }
    editor.hidden = false;
    busy = false;
    $("save").disabled = false;
    newDraft(value.draft);
    if (value.lastParent !== undefined) { draft.lastParent = value.lastParent; updateSpaceLabels(); }
    renderSaved();
    message(value.editingKey
      ? `Editing ${value.editingKey}. Changes stay on this machine until SAVE.`
      : "New placement. Changes stay on this machine until SAVE.");
    window.setTimeout(publishRect, 0);
  });

  Open77.on("editor:applyDraft", value => {
    applyDraftPayload(value.draft || {});
    message(value.message || "Draft updated.", value.ok === false ? "bad" : "ok");
  });
  Open77.on("editor:definitions", value => { definitions = Array.isArray(value.rows) ? value.rows : []; renderSaved(); });
  Open77.on("editor:cameras", value => { cameras = Array.isArray(value.rows) ? value.rows : []; cameraOptions(); });
  Open77.on("editor:presentation", value => {
    if (!value) return;
    const row = definitions.find(entry => entry.key === value.key);
    if (!row) return;
    row.viewerState = value.state;
    row.viewerReason = value.reason;
    if (value.screenId != null) row.screenId = value.screenId;
    renderSaved();
  });
  Open77.on("editor:states", value => renderStates(value));

  // --- live placement ------------------------------------------------------
  function setLiveUI(value) {
    liveModes.follow = value.follow === true;
    liveModes.snap = value.snap === true;
    // The two card toggles and the bar's segmented control are the same state:
    // one positioning mode at a time, so the third state is "neither".
    const states = [
      ["follow", liveModes.follow],
      ["livesnap", liveModes.snap],
      ["live-camera", liveModes.follow],
      ["live-surface", liveModes.snap],
      ["live-off", !liveModes.follow && !liveModes.snap]
    ];
    for (const [id, on] of states) {
      const button = $(id);
      button.classList.toggle("selected", on);
      button.setAttribute("aria-pressed", String(on));
    }
  }

  Open77.on("editor:live", value => {
    setLiveUI(value || {});
    if (value && value.message) message(value.message, "ok");
  });

  // The live modes drive the draft while the page is hidden, so the fields are
  // caught up here rather than by a full draft round-trip at 30 Hz.
  Open77.on("editor:livePose", value => {
    if (!draft || !value) return;
    if (value.camera) {
      draft.camera.position = value.camera.position;
      draft.camera.rotation = value.camera.rotation;
    }
    if (value.placement) {
      draft.placement.position = value.placement.position;
      draft.placement.rotation = value.placement.rotation;
    }
    if (value.snapped !== undefined) {
      draft.anchor = value.snapped ? (value.anchor || draft.anchor) : null;
      $("place-meta").textContent = draft.anchor ? "snapped surface" : "manual pose";
    }
    if (value.hasParent !== undefined) {
      draft.placement.parent = value.hasParent ? (value.parent || null) : null;
      updateSpaceLabels();
    }
    refreshFields();
  });

  Open77.on("editor:syncDraft", value => {
    if (value && value.draft) applyDraftPayload(value.draft);
  });

  // The Lua side owns whether a housing exists -- a refused alias clears it --
  // so the toggle follows this message rather than its own click.
  function setCameraPropUI(model) {
    cameraPropModel = typeof model === "string" && model !== "" ? model : null;
    const button = $("camprop");
    button.classList.toggle("selected", cameraPropModel !== null);
    button.setAttribute("aria-pressed", String(cameraPropModel !== null));
    if (cameraPropModel) button.title = `Preview housing ${cameraPropModel}. SAVE creates the shared housing; unsaved edits stay local.`;
  }

  Open77.on("editor:cameraPropState", value => {
    setCameraPropUI(value && value.model);
    if (value && value.message) message(value.message, value.ok === false ? "bad" : "ok");
  });

  Open77.on("editor:notice", value => {
    busy = false;
    $("save").disabled = false;
    message(value.message, value.ok === false ? "bad" : (value.kind || ""));
  });
  Open77.on("editor:snapResult", value => {
    busy = false;
    if (value.ok) message(value.message || "Snapped to the surface under the aim.", "ok");
    else message(`Snap failed: ${reasonText(value.reason)}. Place it manually with the fields, or release the cursor, aim, and press the snap key.`, "bad");
  });
  Open77.on("editor:copyResult", value => {
    if (value.ok) message(`${value.kind.toUpperCase()} definition copied to the clipboard (${value.length} bytes).`, "ok");
    else message(`Clipboard refused the ${value.kind} definition: ${reasonText(value.reason)}.`, "bad");
  });
  Open77.on("editor:saved", value => {
    busy = false;
    $("save").disabled = false;
    if (!value.ok) { message(`Save refused: ${reasonText(value.reason)}. Nothing was saved.`, "bad"); return; }
    if (value.definition) {
      editingKey = value.definition.key;
      draft.key = editingKey;
      $("name").value = value.definition.name;
    }
    definitions = Array.isArray(value.definitions) ? value.definitions : definitions;
    renderSaved();
    updateEditingChrome();
    const warnings = Array.isArray(value.warnings) && value.warnings.length
      ? " " + value.warnings.map(reasonText).join("; ") : "";
    message(`Saved ${value.definition ? value.definition.key : ""} as screen ${value.screenId == null ? "?" : value.screenId}. ` +
      `The panel chip is the server's own report, not this page's.${warnings}`, warnings ? "warn" : "ok");
  });
  Open77.on("editor:deleted", value => {
    busy = false;
    if (!value.ok) { message(`Delete refused: ${reasonText(value.reason)}.`, "bad"); return; }
    definitions = Array.isArray(value.definitions) ? value.definitions : definitions;
    if (editingKey === value.key) {
      editingKey = null;
      if (draft) draft.key = null;
      updateEditingChrome();
    }
    renderSaved();
    message(`Deleted ${value.key}.`, "ok");
  });
  Open77.on("editor:closed", value => {
    editor.hidden = true;
    busy = false;
    definitions = [];
    draft = null;
    editingKey = null;
    message(`Editor closed (${reasonText(value.reason)}).`);
  });
  Open77.on("editor:focus", () => {
    editor.hidden = false;
    message("Cursor captured. F4 snaps to the surface you are looking at; RELEASE CURSOR hands the game back.");
    window.setTimeout(publishRect, 0);
  });

  wire();
  Open77.ready();
  emit("editor:ready");
})();
