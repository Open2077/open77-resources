(() => {
  "use strict";

  const watermark = document.getElementById("watermark");
  const build = document.getElementById("build-value");
  const playerName = document.getElementById("player-name");
  const playerId = document.getElementById("player-id");
  const sessionValue = document.getElementById("session-value");

  const text = value => String(value == null ? "" : value);

  // Keep screenshot correlation, without exposing the complete identifier.
  const shortId = value => {
    const id = text(value);
    return id.length > 12 ? id.slice(0, 8) + "…" + id.slice(-4) : id;
  };

  function render(payload) {
    if (!payload || typeof payload !== "object") return;

    build.textContent = text(payload.version) || "—";
    watermark.dataset.online = payload.online === true ? "true" : "false";

    if (payload.online === true) {
      const name = text(payload.name) || "unknown";
      const id = text(payload.playerId) || "?";
      playerName.textContent = name;
      playerId.textContent = `#${id}`;
      sessionValue.textContent = shortId(payload.identifier) || "pending";
    } else {
      playerName.textContent = "Not connected";
      playerId.textContent = "";
      sessionValue.textContent = "OFFLINE";
    }
  }

  Open77.on("watermark:state", render);
  Open77.ready();
  Open77.emit("watermark:ready", {});
})();
