(() => {
  "use strict";
  const root = document.getElementById("interaction");
  const safeColor = value => /^#[0-9a-f]{6}$/i.test(String(value || ""))
    ? String(value) : "#22D8E2";  // --op77-accent
  const markers = new Set([
    "dot", "ring", "diamond", "arrow", "chevron",
    "exclamation", "info", "vehicle", "person", "door", "shop"
  ]);
  const safeMarker = value => markers.has(String(value || "")) ? String(value) : "dot";
  const clamp01 = value => Math.max(0, Math.min(1, Number(value) || 0));

  // Two feeds, two rates.
  //
  // `interaction:update` is content: which prompt won, what the card says, how
  // far a hold has run. It arrives on the resource's Lua tick and rebuilds DOM.
  //
  // `open77:anchors` is position, published by the plugin on every rendered
  // frame. It never touches DOM structure -- only two custom properties and, at
  // most, one text node -- because a Lua-published coordinate is always a frame
  // behind the camera that draws it, and that lag is the whole reason this feed
  // exists. Rebuilding the card at that rate would trade one stutter for another.
  let content = null;
  let distanceNode = null;
  const frame = new Map();
  let scheduled = 0;
  let lastMeter = "";

  function schedule() {
    if (scheduled) return;
    // Coalesce: the plugin caps itself at ~120 Hz and several messages can land
    // between two paints. Only the last one is worth writing.
    scheduled = requestAnimationFrame(() => { scheduled = 0; place(); });
  }

  function place() {
    if (!content || !content.visible) {
      root.classList.remove("visible", "active");
      return;
    }
    let x, y, distance;
    if (content.anchor) {
      // The anchor batch is the COMPLETE set of what the plugin is projecting:
      // an id that is absent is hidden, out of its distance band, behind the
      // camera or not streamed. Absent means gone, not "keep the last position".
      const anchor = frame.get(content.anchor);
      if (!anchor || anchor.onScreen === false) {
        root.classList.remove("visible", "active");
        return;
      }
      x = anchor.x;
      y = anchor.y;
      distance = anchor.distance;
    } else {
      // No anchor id: this tick projected in Lua (a brand-new entry, or a client
      // without the anchor service). The card still has to draw.
      x = content.x;
      y = content.y;
      distance = content.distance;
    }
    root.style.setProperty("--anchor-x", String(clamp01(x)));
    root.style.setProperty("--anchor-y", String(clamp01(y)));
    if (distanceNode) {
      const meters = Math.max(0, Number(distance) || 0);
      const text = `${meters < 10 ? meters.toFixed(1) : Math.round(meters)} M`;
      if (text !== lastMeter) {
        lastMeter = text;
        distanceNode.textContent = text;
      }
    }
    root.classList.add("visible");
    root.classList.toggle("active", Boolean(content.active));
  }

  function update(payload = {}) {
    if (!payload.visible || !Array.isArray(payload.choices) || payload.choices.length === 0) {
      content = null;
      distanceNode = null;
      lastMeter = "";
      root.classList.remove("visible", "active");
      root.replaceChildren();
      return;
    }
    content = payload;
    root.style.setProperty("--accent", safeColor(payload.color));
    root.style.setProperty("--marker-scale", String(Math.max(.6, Math.min(2, Number(payload.markerScale) || 1))));
    const fragment = document.createDocumentFragment();

    // The marker is the persistent world-space affordance. The action card is
    // deliberately absent until Lua says the player is both close enough and
    // looking at the projected target.
    const marker = document.createElement("span");
    marker.className = `world-marker marker-${safeMarker(payload.marker)}`;
    marker.classList.toggle("animated", payload.markerAnimated !== false);
    marker.setAttribute("aria-hidden", "true");
    fragment.append(marker);

    distanceNode = document.createElement("span");
    distanceNode.className = "distance";
    lastMeter = "";
    fragment.append(distanceNode);

    if (payload.active) {
      const panel = document.createElement("div");
      panel.className = "choices";
      for (const choice of payload.choices.slice(0, 4)) {
        const row = document.createElement("section");
        row.className = "choice";
        row.style.setProperty("--choice-accent", safeColor(choice && choice.color));
        row.classList.toggle("disabled", !choice || !choice.enabled);
        row.classList.toggle("holding", Boolean(choice && choice.hold));

        const key = document.createElement("span");
        key.className = "key";
        key.textContent = String(choice && choice.key || "E").slice(0, 8);
        row.append(key);

        if (choice && choice.icon) {
          const icon = document.createElement("span");
          icon.className = "icon";
          icon.textContent = String(choice.icon).slice(0, 12);
          row.append(icon);
        }

        const copy = document.createElement("span");
        copy.className = "copy";
        const label = document.createElement("strong");
        label.textContent = String(choice && choice.label || "Interaction").slice(0, 96);
        copy.append(label);
        if (choice && choice.description) {
          const description = document.createElement("small");
          description.textContent = String(choice.description).slice(0, 160);
          copy.append(description);
        }
        row.append(copy);

        if (choice && choice.hold) {
          const progress = document.createElement("i");
          progress.className = "progress";
          progress.style.setProperty("--progress", String(clamp01(choice.progress)));
          row.append(progress);
        }
        panel.append(row);
      }
      fragment.append(panel);
    }
    root.replaceChildren(fragment);
    place();
  }

  function anchors(payload = {}) {
    frame.clear();
    for (const anchor of Array.isArray(payload.anchors) ? payload.anchors : []) {
      const id = String(anchor && anchor.id || "");
      if (id) frame.set(id, anchor);
    }
    schedule();
  }

  Open77.on("interaction:update", update);
  Open77.on("open77:anchors", anchors);
  Open77.ready();
  Open77.emit("interactions:ready", {});
})();
