(() => {
  "use strict";
  const root = document.getElementById("nameplates");
  const nodes = new Map();
  const safeColor = value => /^#[0-9a-f]{6}([0-9a-f]{2})?$/i.test(String(value || ""))
    ? String(value) : "#f2f6f8";  // --op77-text

  function update(payload = {}) {
    const seen = new Set();
    for (const player of Array.isArray(payload.players) ? payload.players : []) {
      const id = String(player && player.id || "");
      if (!id) continue;
      seen.add(id);
      let node = nodes.get(id);
      if (!node) {
        node = document.createElement("div");
        node.className = "nameplate";
        const voice = document.createElement("span");
        voice.className = "nameplate-voice";
        voice.setAttribute("aria-hidden", "true");
        const name = document.createElement("span");
        name.className = "nameplate-name";
        node.append(voice, name);
        root.append(node);
        nodes.set(id, node);
      }
      const x = Math.max(0, Math.min(1, Number(player.x) || 0));
      const y = Math.max(0, Math.min(1, Number(player.y) || 0));
      const distance = Math.max(0, Number(player.distance) || 0);
      node.style.left = `${x * 100}%`;
      node.style.top = `${y * 100}%`;
      node.style.setProperty("--plate-color", safeColor(player.color));
      node.style.setProperty("--plate-opacity", String(Math.max(.42, 1 - distance / 80)));
      node.classList.toggle("nameplate--talking", player.talking === true);
      node.querySelector(".nameplate-name").textContent =
        String(player.label || "Player").slice(0, 96);
    }
    for (const [id, node] of nodes) {
      if (seen.has(id)) continue;
      node.remove();
      nodes.delete(id);
    }
  }

  Open77.on("nameplates:update", update);
  Open77.ready();
  Open77.emit("nameplates:ready", {});
})();
