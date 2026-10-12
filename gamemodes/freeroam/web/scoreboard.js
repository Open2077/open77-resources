(() => {
  "use strict";

  const body = document.body;
  const rowsEl = document.getElementById("rows");
  const countEl = document.getElementById("count");
  const emptyEl = document.getElementById("empty");

  let roster = new Map(), revision = null, epoch = null, pending = null;
  let distances = new Map(), distanceBatch = null, selfId = null;
  let ordered = [], dirty = true, opened = false, scheduled = false, requestedAt = -Infinity;
  const integer = (v, min, max) => Number.isSafeInteger(v) && v >= min && v <= max;
  // Empty Lua tables cross the JSON bridge as {}, including empty list fields.
  // Accept only that empty object shape; nonempty maps are still malformed lists.
  const list = v => Array.isArray(v) ? v :
    (v && typeof v === "object" && Object.keys(v).length === 0 ? [] : null);
  const repair = () => {
    pending = null;
    if (Date.now() - requestedAt >= 1000) {
      requestedAt = Date.now(); Open77.emit("scoreboard:requestRoster", {});
    }
  };
  function receivePage(m) {
    if (m) m = { ...m, players: list(m.players), removed: list(m.removed) };
    if (!m || typeof m.epoch !== "string" || !integer(m.revision, 0, Number.MAX_SAFE_INTEGER) ||
        !integer(m.pages, 1, 64) || !integer(m.page, 1, m.pages) || !integer(m.count, 0, 4096) ||
        !Array.isArray(m.players) || !Array.isArray(m.removed) || m.players.length + m.removed.length > 128 ||
        !["full", "delta"].includes(m.kind)) return repair();
    if (m.kind === "delta") {
      if (epoch !== m.epoch || revision === null) return repair();
      if (m.revision <= revision) return;
      if (m.base !== revision) return repair();
    } else if (epoch === m.epoch && revision !== null && m.revision < revision) return;
    if (!pending || pending.revision !== m.revision || pending.epoch !== m.epoch || pending.kind !== m.kind)
      pending = { ...m, chunks: new Map() };
    if (pending.pages !== m.pages || pending.count !== m.count) return repair();
    pending.chunks.set(m.page, m);
    if (pending.chunks.size !== pending.pages) return;
    const next = pending.kind === "delta" ? new Map(roster) : new Map();
    for (let page = 1; page <= pending.pages; page++) {
      const chunk = pending.chunks.get(page);
      for (const row of chunk.players) {
        if (!row || !integer(row.id, 1, Number.MAX_SAFE_INTEGER) || typeof row.name !== "string" || row.name.length > 256) return repair();
        next.set(row.id, row.name);
      }
      for (const id of chunk.removed) {
        if (!integer(id, 1, Number.MAX_SAFE_INTEGER)) return repair();
        next.delete(id);
      }
    }
    if (next.size !== pending.count) return repair();
    roster = next; revision = m.revision; epoch = m.epoch; pending = null;
    dirty = true; schedule();
  }
  function receiveDistances(m) {
    if (m) m = { ...m, players: list(m.players) };
    if (!m || !integer(m.pages, 1, 64) || !integer(m.page, 1, m.pages) || !Array.isArray(m.players)) return;
    if (!distanceBatch || distanceBatch.revision !== m.revision)
      distanceBatch = { revision: m.revision, pages: m.pages, chunks: new Map() };
    distanceBatch.chunks.set(m.page, m.players);
    if (distanceBatch.chunks.size !== distanceBatch.pages) return;
    const next = new Map();
    for (const chunk of distanceBatch.chunks.values())
      for (const row of chunk) if (Number.isFinite(row.distance)) next.set(Number(row.id), row.distance);
    distances = next; selfId = Number(m.selfId); distanceBatch = null; dirty = true; schedule();
  }
  function schedule() {
    if (!opened || scheduled) return;
    scheduled = true;
    requestAnimationFrame(() => { scheduled = false; if (opened) render(); });
  }

  function formatDistance(metres) {
    const value = Number(metres) || 0;
    if (value >= 1000) return (value / 1000).toFixed(1) + " km";
    return Math.round(value) + " m";
  }

  function render() {
    if (dirty) {
      ordered = Array.from(roster, ([id, label]) => ({ id, label, self: id === selfId,
        distance: distances.get(id), streamed: distances.has(id) }));
      ordered.sort((a,b) => Number(b.self)-Number(a.self) || Number(b.streamed)-Number(a.streamed) ||
        (a.streamed && b.streamed ? a.distance-b.distance : 0) ||
        a.label.toLowerCase().localeCompare(b.label.toLowerCase()) || a.id-b.id);
      dirty = false;
    }
    countEl.textContent = String(ordered.length);
    // Fixed-height window: thousands of roster rows never become thousands of DOM nodes.
    const first = Math.max(0, Math.min(Math.floor(rowsEl.scrollTop / 48), Math.max(0, ordered.length - 1)));
    const last = Math.min(ordered.length, first + Math.ceil((rowsEl.clientHeight || 480) / 48) + 2);
    const spacer = height => { const el = document.createElement("div"); el.style.height = height + "px"; return el; };
    rowsEl.replaceChildren(spacer(first * 48));
    for (const player of ordered.slice(first, last)) {
      const row = document.createElement("div");
      row.className = "row";
      // Every row is a player on the server. Only the ones streamed near the
      // local player carry a distance; the others are somewhere in the city.
      const streamed = player.streamed === true && player.distance !== null && player.distance !== undefined;
      const distance = Number(player.distance) || 0;
      if (player.self) row.classList.add("self");
      else if (!streamed) row.classList.add("far");
      else if (distance <= 25) row.classList.add("near");

      const name = document.createElement("span");
      name.className = "name";
      name.textContent = String(player.label || "Player").slice(0, 64);

      const id = document.createElement("span");
      id.className = "id";
      id.textContent = String(player.id || "?");

      const dist = document.createElement("span");
      dist.className = "dist";
      dist.textContent = player.self ? "YOU" : (streamed ? formatDistance(distance) : "\u2014");

      row.append(name, id, dist);
      rowsEl.append(row);
    }

    rowsEl.append(spacer((ordered.length - last) * 48));
    emptyEl.textContent = revision === null
      ? "// WAITING FOR THE SERVER ROSTER"
      : "// NO ONE ELSE ON THE SERVER";
    emptyEl.classList.toggle("hidden", ordered.length > 0);
  }

  Open77.on("scoreboard:rosterPage", receivePage);
  Open77.on("scoreboard:distances", receiveDistances);
  Open77.on("scoreboard:open", () => { opened = true; body.classList.add("open"); schedule(); });
  Open77.on("scoreboard:closed", () => { opened = false; body.classList.remove("open"); });
  rowsEl.addEventListener("scroll", schedule);
  window.addEventListener("resize", schedule);

  Open77.ready();
  Open77.emit("scoreboard:ready", {});
})();
