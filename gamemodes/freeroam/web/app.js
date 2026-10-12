(() => {
  "use strict";

  const body = document.getElementById("freeroam-menu");
  const toast = document.getElementById("toast");
  let toastTimer = null;
  let state = {
    locations: [], spawns: [],
    vehicles: { catalog: [], allowCustomModels: false },
    weapons: { catalog: [], enabled: false, defaultReserve: 500, maximumReserve: 5000 },
    player: {},
  };
  let selectedSlot = 1;
  let vehicleCategory = "All";
  let weaponCategory = "All";
  let weaponSlots = [];
  let garageState = { count: 0, maximum: 0 };
  let playerState = { available: false };

  const send = (type, extra) => Open77.emit(
    "freeroam:action", Object.assign({ type }, extra || {}));
  const close = () => Open77.emit("freeroam:close", {});
  // An empty Lua table crosses the bridge as {}, not []; never iterate raw.
  const asArray = value => Array.isArray(value) ? value : [];
  const text = value => String(value || "").toLocaleLowerCase();

  function showToast(ok, message) {
    toast.textContent = message;
    toast.classList.toggle("error", !ok);
    toast.classList.add("show");
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => toast.classList.remove("show"), 3600);
  }

  // Tabs -----------------------------------------------------------------

  const navigation = [...body.querySelectorAll(".tab")];
  const pages = body.querySelector(".pages");
  function activatePage(name) {
    if (name === "tv" && state.canManageTv !== true) name = "vehicles";
    const page = document.getElementById("page-" + name);
    if (!page) return;
    const changed = !page.classList.contains("active");
    body.classList.toggle("animation-mode", name === "animations");
    for (const tab of navigation) {
      const active = tab.dataset.tab === name;
      tab.classList.toggle("active", active);
      if (active) tab.setAttribute("aria-current", "page");
      else tab.removeAttribute("aria-current");
    }
    for (const other of body.querySelectorAll(".page")) other.classList.toggle("active", other === page);
    if (changed) pages.scrollTop = 0;
    body.querySelector(".foot-search").hidden = !page.querySelector("input.search, #travel-search");
  }
  // Activities can also open via slash commands. Keep the same selection and
  // layout path without emitting another Lua open request.
  body.addEventListener("freeroam:navigate", event => activatePage(event.detail));
  document.getElementById("tabs").addEventListener("keydown", event => {
    const visible = navigation.filter(tab => !tab.hidden && !tab.disabled);
    const current = visible.indexOf(document.activeElement);
    if (current < 0 || !["ArrowDown", "ArrowUp", "Home", "End"].includes(event.key)) return;
    event.preventDefault();
    const index = event.key === "Home" ? 0 : event.key === "End" ? visible.length - 1
      : (current + (event.key === "ArrowDown" ? 1 : -1) + visible.length) % visible.length;
    visible[index].focus(); // Enter/Space activates; arrows never launch an activity.
  });

  for (const tab of body.querySelectorAll(".tab")) {
    tab.addEventListener("click", () => {
      if (tab.dataset.tab === "animations") {
        Open77.emit("animations:open", {});
        return;
      }
      if (tab.dataset.tab === "race" || tab.dataset.tab === "footrace") {
        body.classList.remove("animation-mode");
        Open77.emit("freeroam:race", { mode: tab.dataset.tab === "footrace" ? "foot" : "vehicle" });
        return;
      }
      activatePage(tab.dataset.tab);
      if (tab.dataset.tab === "weapons") send("weaponSnapshot", {});
      if (tab.dataset.tab === "tv") requestTv();
      if (tab.dataset.tab === "pvp") Open77.emit("pvp:open", {});
    });
  }

  // Catalog rendering ----------------------------------------------------

  function categories(items) {
    return ["All", ...new Set(asArray(items).map(item => item.category || "Other"))];
  }

  function renderFilters(id, items, active, select) {
    const host = document.getElementById(id);
    const values = categories(items);
    const signature = JSON.stringify(values);
    if (host.dataset.signature === signature) {
      for (const button of host.children) {
        const chosen = button.textContent === active;
        button.classList.toggle("active", chosen);
        button.setAttribute("aria-pressed", String(chosen));
      }
      return;
    }
    host.dataset.signature = signature;
    host.replaceChildren();
    for (const category of values) {
      const button = document.createElement("button");
      button.textContent = category;
      button.classList.toggle("active", category === active);
      button.setAttribute("aria-pressed", String(category === active));
      button.addEventListener("click", () => select(category));
      host.append(button);
    }
  }

  function matches(item, category, query) {
    if (category !== "All" && item.category !== category) return false;
    if (!query) return true;
    return text(`${item.label} ${item.key} ${item.category} ${item.record}`).includes(query);
  }

  function card(item, action) {
    const button = document.createElement("button");
    button.className = "catalog-card";
    button.title = item.record || "";
    const label = document.createElement("strong");
    label.textContent = item.label || item.key;
    const meta = document.createElement("small");
    meta.textContent = item.category || "Other";
    button.append(label, meta);
    button.addEventListener("click", action);
    return button;
  }

  function emptyState(host, message, reset) {
    const empty = document.createElement("div");
    empty.className = "empty-state";
    const copy = document.createElement("p");
    copy.textContent = message;
    empty.append(copy);
    if (reset) {
      const button = document.createElement("button");
      button.className = "btn";
      button.textContent = "Reset search & filters";
      button.addEventListener("click", reset);
      empty.append(button);
    }
    host.append(empty);
  }

  function renderVehicles() {
    const vehicles = state.vehicles && typeof state.vehicles === "object" ? state.vehicles : {};
    const items = asArray(vehicles.catalog);
    const query = text(document.getElementById("vehicle-search").value.trim());
    const grid = document.getElementById("vehicle-grid");
    renderFilters("vehicle-filters", items, vehicleCategory, category => {
      vehicleCategory = category;
      renderVehicles();
    });
    const shown = items.filter(item => matches(item, vehicleCategory, query));
    const signature = JSON.stringify([shown, vehicleCategory, query]);
    if (grid.dataset.signature !== signature) {
      grid.dataset.signature = signature;
      grid.replaceChildren();
      grid.scrollTop = 0;
      for (const item of shown) grid.append(card(item, () => send("car", { model: item.key })));
      if (!shown.length) emptyState(grid, items.length ? "No vehicles match your search." : "No vehicles are configured on this server.", items.length ? () => {
        vehicleCategory = "All";
        document.getElementById("vehicle-search").value = "";
        renderVehicles();
        document.getElementById("vehicle-search").focus();
      } : null);
    }
    document.getElementById("vehicle-count").textContent = `${shown.length} / ${items.length} models`;

    document.getElementById("vehicle-custom").style.display =
      vehicles.allowCustomModels ? "" : "none";
    const max = Number(vehicles.maxPerPlayer) || 0;
    const count = Number(garageState.count) || 0;
    const effectiveMax = Number(garageState.maximum) || max;
    document.getElementById("vehicle-hint").textContent = effectiveMax > 0
      ? `Choose a model to spawn. Garage: ${count} / ${effectiveMax}. Oldest replaced when full.`
      : "Choose a model to spawn it nearby. Your garage has no vehicle limit.";
    const latest = garageState.latest && typeof garageState.latest === "object"
      ? garageState.latest : null;
    const identity = latest && (latest.label || latest.record || `VEHICLE ${latest.id}`);
    document.getElementById("vehicle-latest").textContent = latest
      ? `LATEST · ${identity} · ${latest.engineOn ? "ENGINE ON" : "ENGINE OFF"} · ` +
        `${latest.locked ? "LOCKED" : "UNLOCKED"} · ` +
        `${latest.lightsOn ? "LIGHTS ON" : "LIGHTS OFF"}`
      : "Your garage is empty. Choose your first ride below.";
  }

  function renderWeapons() {
    const weapons = state.weapons && typeof state.weapons === "object" ? state.weapons : {};
    const items = asArray(weapons.catalog);
    const query = text(document.getElementById("weapon-search").value.trim());
    const grid = document.getElementById("weapon-grid");
    renderFilters("weapon-filters", items, weaponCategory, category => {
      weaponCategory = category;
      renderWeapons();
    });
    const shown = items.filter(item => matches(item, weaponCategory, query));
    const equipped = weaponSlots.find(value => Number(value.slot) === selectedSlot) || {};
    const signature = JSON.stringify([shown, weaponCategory, query, equipped.record]);
    if (grid.dataset.signature !== signature) {
      grid.dataset.signature = signature;
      grid.replaceChildren();
      for (const item of shown) {
      const button = card(item, () => send("weaponEquip", {
        key: item.key,
        slot: selectedSlot,
      }));
      button.classList.toggle("equipped", equipped.record === item.record);
      button.setAttribute("aria-pressed", String(equipped.record === item.record));
      grid.append(button);
      }
      if (!shown.length) emptyState(grid, items.length ? "No weapons match your search." : "No weapons are configured on this server.", items.length ? () => {
        weaponCategory = "All";
        document.getElementById("weapon-search").value = "";
        renderWeapons();
        document.getElementById("weapon-search").focus();
      } : null);
    }
    document.getElementById("weapon-count").textContent = `${shown.length} / ${items.length} weapons`;
    document.getElementById("ammo-reserve").placeholder =
      `reserve 0-${Number(weapons.maximumReserve) || 5000}`;
    if (!document.getElementById("ammo-reserve").value)
      document.getElementById("ammo-reserve").value = String(Number(weapons.defaultReserve) || 500);
  }

  function renderLoadout() {
    const host = document.getElementById("weapon-loadout");
    host.replaceChildren();
    for (let slot = 1; slot <= 3; slot += 1) {
      const value = weaponSlots.find(item => Number(item.slot) === slot) || {};
      const row = document.createElement("button");
      row.className = "loadout-row";
      row.classList.toggle("selected", slot === selectedSlot);
      const name = document.createElement("strong");
      const record = value.record || value.tweakDbId || "";
      const configured = asArray(state.weapons && state.weapons.catalog)
        .find(item => item.record === value.record);
      const display = configured && configured.label ? configured.label : record || "Empty";
      name.textContent = `SLOT ${slot} · ${display}`;
      row.title = record;
      const status = document.createElement("small");
      const ammo = value.ammo && typeof value.ammo === "object" ? value.ammo : {};
      const flags = [value.active ? "ACTIVE" : "", value.drawn ? "DRAWN" : ""]
        .filter(Boolean).join(" · ") || "INACTIVE";
      status.textContent = Number(ammo.total) >= 0
        ? `${flags} · reserve ${ammo.reserve} · mag ${ammo.magazine}/${ammo.capacity}`
        : flags;
      row.append(name, status);
      row.addEventListener("click", () => selectSlot(slot));
      host.append(row);
    }
  }

  function selectSlot(slot) {
    selectedSlot = slot;
    for (const button of body.querySelectorAll("#weapon-slots button")) {
      button.classList.toggle("active", Number(button.dataset.slot) === slot);
      button.setAttribute("aria-pressed", String(Number(button.dataset.slot) === slot));
    }
    renderLoadout();
    renderWeapons();
  }

  function renderTravel() {
    const query = text(document.getElementById("travel-search").value.trim());
    const locations = document.getElementById("location-list");
    locations.replaceChildren();
    for (const location of asArray(state.locations)) {
      if (query && !text(`${location.label} ${location.name} ${location.district}`).includes(query)) continue;
      const button = document.createElement("button");
      const label = document.createElement("span");
      label.textContent = location.label || location.name;
      const detail = document.createElement("i");
      const p = location.position || {};
      detail.textContent = `${location.district || "Night City"} · ${Math.round(p.x)}, ${Math.round(p.y)}, ${Math.round(p.z)}`;
      button.append(label, detail);
      button.addEventListener("click", () => send("goto", { name: location.name }));
      locations.append(button);
    }
    if (!locations.childElementCount) emptyState(locations, query ? "No destinations match your search." : "No destinations configured.");

    const spawns = document.getElementById("spawn-list");
    spawns.replaceChildren();
    for (const point of asArray(state.spawns)) {
      if (query && !text(`${point.label} ${point.name}`).includes(query)) continue;
      const button = document.createElement("button");
      const label = document.createElement("span");
      label.textContent = point.label || point.name;
      const coords = document.createElement("i");
      const p = point.position || {};
      coords.textContent = `${Math.round(p.x)}, ${Math.round(p.y)}, ${Math.round(p.z)}`;
      button.append(label, coords);
      button.addEventListener("click", () => send("spawn", { name: point.name }));
      spawns.append(button);
    }
    if (!spawns.childElementCount) emptyState(spawns, query ? "No spawn points match your search." : "No spawn points configured.");
  }

  function render() {
    renderVehicles();
    renderWeapons();
    renderLoadout();
    renderTravel();
    const player = state.player && typeof state.player === "object" ? state.player : {};
    document.getElementById("player-restore").style.display = player.allowRestore ? "" : "none";
    document.getElementById("godmode-controls").style.display = player.allowGodMode ? "" : "none";
    renderPlayerState();
  }

  function renderPlayerState() {
    const host = document.getElementById("player-status");
    if (!playerState.available) {
      host.textContent = "PLAYER STATE UNAVAILABLE";
      host.classList.remove("signal");
      return;
    }
    const health = Math.round(Number(playerState.health) || 0);
    const maximum = Math.round(Number(playerState.maximumHealth) || 0);
    const armor = Math.round(Number(playerState.armor) || 0);
    host.textContent = `HEALTH ${health}/${maximum} · ARMOR ${armor} · ` +
      (playerState.godMode ? "GOD MODE ON" : "GOD MODE OFF");
    host.classList.toggle("signal", playerState.godMode === true);
  }

  // Static controls ------------------------------------------------------

  document.getElementById("close").addEventListener("click", close);
  document.getElementById("vehicle-search").addEventListener("input", renderVehicles);
  document.getElementById("weapon-search").addEventListener("input", renderWeapons);
  document.getElementById("travel-search").addEventListener("input", renderTravel);
  document.getElementById("cyberware-open").addEventListener("click", () => send("cyberlab", {}));
  document.getElementById("vehicle-delete").addEventListener("click", () => send("dv", {}));
  document.getElementById("vehicle-delete-all").addEventListener("click", () => send("dv", { all: true }));
  document.getElementById("vehicle-spawn").addEventListener("click", () => {
    const record = document.getElementById("vehicle-record").value.trim();
    if (record) send("car", { model: record });
  });
  document.getElementById("vehicle-repair").addEventListener("click", () => send("vehicleRepair", {}));
  document.getElementById("vehicle-engine-on").addEventListener("click", () => send("vehicleEngine", { enabled: true }));
  document.getElementById("vehicle-engine-off").addEventListener("click", () => send("vehicleEngine", { enabled: false }));
  document.getElementById("vehicle-lock").addEventListener("click", () => send("vehicleLock", { enabled: true }));
  document.getElementById("vehicle-unlock").addEventListener("click", () => send("vehicleLock", { enabled: false }));
  document.getElementById("vehicle-lights").addEventListener("click", () => send("vehicleLights", { enabled: true }));
  document.getElementById("vehicle-lights-off").addEventListener("click", () => send("vehicleLights", { enabled: false }));

  for (const button of body.querySelectorAll("#weapon-slots button"))
    button.addEventListener("click", () => selectSlot(Number(button.dataset.slot)));
  document.getElementById("weapon-ammo").addEventListener("click", () => {
    const reserveText = document.getElementById("ammo-reserve").value.trim();
    const magazineText = document.getElementById("ammo-magazine").value.trim();
    const reserve = Number(reserveText);
    const maximum = Number(state.weapons && state.weapons.maximumReserve) || 5000;
    if (!Number.isInteger(reserve) || reserve < 0 || reserve > maximum)
      return showToast(false, `reserve must be an integer from 0 to ${maximum}`);
    const payload = { slot: selectedSlot, reserve };
    if (magazineText) {
      const magazine = Number(magazineText);
      if (!Number.isInteger(magazine) || magazine < 0)
        return showToast(false, "magazine must be a positive integer");
      payload.magazine = magazine;
    }
    send("weaponAmmo", payload);
  });
  document.getElementById("weapon-activate").addEventListener("click", () =>
    send("weaponActivate", { slot: selectedSlot }));
  document.getElementById("weapon-refresh").addEventListener("click", () => send("weaponSnapshot", {}));
  document.getElementById("weapon-holster").addEventListener("click", () => send("weaponHolster", {}));
  document.getElementById("weapon-remove").addEventListener("click", () =>
    send("weaponRemove", { slot: selectedSlot }));

  document.getElementById("coord-go").addEventListener("click", () => {
    const value = id => document.getElementById(id).value.trim();
    if (["coord-x", "coord-y", "coord-z"].some(id => !value(id)))
      return showToast(false, "Enter X, Y and Z before travelling.");
    const x = Number(value("coord-x"));
    const y = Number(value("coord-y"));
    const z = Number(value("coord-z"));
    const heading = Number(value("coord-h") || "0");
    if (![x, y, z, heading].every(Number.isFinite))
      return showToast(false, "invalid coordinates");
    send("tpc", { x, y, z, heading });
  });
  document.getElementById("player-wardrobe").addEventListener("click", () => send("wardrobe", {}));
  document.getElementById("player-spawn").addEventListener("click", () => send("spawn", {}));
  document.getElementById("player-restore").addEventListener("click", () => send("restore", {}));
  document.getElementById("player-max-levels").addEventListener("click", () => send("maxLevels", {}));
  document.getElementById("player-revive").addEventListener("click", () => send("revive", {}));
  document.getElementById("player-god-on").addEventListener("click", () => send("godMode", { enabled: true }));
  document.getElementById("player-god-off").addEventListener("click", () => send("godMode", { enabled: false }));
  document.getElementById("player-suicide").addEventListener("click", () => send("suicide", {}));

  // Televisions ----------------------------------------------------------
  //
  // The catalogue and the spawn path live in the `open77_media` resource, not
  // here, so this tab is a client of it rather than a second implementation: it
  // asks, and it renders the answer. Everything a player can change goes through
  // that resource's server events, which is why changing a URL from here changes
  // it for everyone watching the same set.

  let tvCatalogue = [];
  let tvLocal = [];
  let tvFilter = "";

  const tvSend = (action, extra) => {
    if (state.canManageTv === true) Open77.emit("freeroam:tv", Object.assign({ action }, extra || {}));
  };
  const requestTv = () => {
    tvSend("catalogue");
    tvSend("local");
  };

  function renderTvCatalogue() {
    const grid = document.getElementById("tv-grid");
    grid.innerHTML = "";
    const shown = tvCatalogue.filter(record =>
      tvFilter === "" || text(record.label).includes(tvFilter) || text(record.id).includes(tvFilter));

    for (const record of shown) {
      const card = document.createElement("button");
      card.className = "catalog-card";
      card.type = "button";
      const title = document.createElement("strong");
      title.textContent = record.label || record.id;
      const blurb = document.createElement("small");
      blurb.textContent = record.blurb || record.model || "";
      const size = document.createElement("span");
      size.className = "tag";
      size.textContent = `${Number(record.width).toFixed(2)}×${Number(record.height).toFixed(2)} m`;
      card.append(title, blurb, size);
      card.addEventListener("click", () => tvSend("spawn", {
        record: record.id, url: document.getElementById("tv-url").value.trim(),
      }));
      grid.appendChild(card);
    }
    if (shown.length === 0) {
      const empty = document.createElement("p");
      empty.className = "hint";
      empty.textContent = tvCatalogue.length === 0
        ? "No records received. The open77_media resource may not be running."
        : "No records match that filter.";
      grid.appendChild(empty);
    }
  }

  // One row per set this client is rendering. The controls map onto the media
  // resource's own actions, so nothing here is a separate implementation of any
  // of them.
  function renderTvLocal() {
    const list = document.getElementById("tv-screens");
    list.innerHTML = "";
    // Nearest first, and the count stops claiming "in range".
    //
    // `open77:media:local` carries every television this client knows about --
    // the server's whole set, up to its own ceiling -- and it arrives in id
    // order. So the row for the set standing in front of the player sat wherever
    // its id happened to fall, and an operator changing "the volume" was usually
    // changing a television kilometres away while the picture in front of them
    // did not move. Nothing was broken in the control: it was aimed at the wrong
    // set, and the list gave no way to tell. The ones this client is actually
    // rendering come first, then by distance, and each row says which it is.
    const ordered = tvLocal.slice().sort((a, b) => {
      if (Boolean(a.materialised) !== Boolean(b.materialised)) return a.materialised ? -1 : 1;
      const left = Number(a.distance), right = Number(b.distance);
      if (isFinite(left) && isFinite(right) && left !== right) return left - right;
      return (Number(a.id) || 0) - (Number(b.id) || 0);
    });
    const rendered = ordered.filter(screen => screen.materialised === true).length;
    document.getElementById("tv-local-count").textContent = ordered.length === 0
      ? "NO SETS IN RANGE"
      : `${ordered.length} SET${ordered.length === 1 ? "" : "S"} — ${rendered} ON THIS CLIENT`;

    for (const screen of ordered) {
      const row = document.createElement("div");
      row.className = "catalogue-row";

      const head = document.createElement("strong");
      head.textContent = `#${screen.id}  ${screen.label || "television"}`;
      const where = document.createElement("small");
      const distance = screen.distance === null || screen.distance === undefined
        ? "distance unknown"
        : `${Number(screen.distance).toFixed(1)} m away`;
      // Which television this row is. A set this client is rendering is the one
      // on its screen; everything else is somewhere else on the map, and its
      // volume is not the volume of the picture in front of the player.
      where.textContent = `${screen.materialised === true ? "ON SCREEN" : "DRIVING A SET ELSEWHERE"} · ${distance}`;

      const urlRow = document.createElement("div");
      urlRow.className = "row";
      const url = document.createElement("input");
      url.type = "text";
      url.className = "search";
      url.spellcheck = false;
      url.value = screen.url || "";
      url.placeholder = "https://... (empty = idle test pattern)";
      url.setAttribute("aria-label", `Web page for television ${screen.id}`);
      const load = document.createElement("button");
      load.className = "btn";
      load.type = "button";
      load.textContent = "SHOW";
      const show = () => tvSend("url", { id: screen.id, url: url.value.trim() });
      load.addEventListener("click", show);
      url.addEventListener("keydown", event => { if (event.key === "Enter") show(); });
      urlRow.append(url, load);

      const controls = document.createElement("div");
      controls.className = "row";
      const volume = document.createElement("input");
      volume.type = "range";
      volume.min = "0";
      volume.max = "100";
      volume.value = String(screen.volume === undefined ? 100 : screen.volume);
      volume.setAttribute("aria-label", `Volume for television ${screen.id}`);
      volume.addEventListener("change", () =>
        tvSend("volume", { id: screen.id, volume: Number(volume.value) }));
      const sounds = document.createElement("button");
      sounds.className = "btn";
      sounds.type = "button";
      sounds.textContent = screen.muted ? "UNMUTE" : "MUTE";
      sounds.addEventListener("click", () => tvSend("muted", { id: screen.id, value: !screen.muted }));
      const play = document.createElement("button");
      play.className = "btn";
      play.type = "button";
      play.textContent = screen.paused ? "PLAY" : "PAUSE";
      play.addEventListener("click", () => tvSend("paused", { id: screen.id, value: !screen.paused }));
      const remove = document.createElement("button");
      remove.className = "btn danger";
      remove.type = "button";
      remove.textContent = "REMOVE";
      remove.addEventListener("click", () => tvSend("remove", { id: screen.id }));
      controls.append(volume, sounds, play, remove);

      // Placement: where the cabinet stands and which way it points.
      //
      // A spawned set lands about a metre in front of you facing you, which is
      // the right default and rarely the right answer -- hovering over a crate,
      // half inside a shelf, or a hand's width from flush. Before this row, the
      // only way to fix that was REMOVE and spawn again, which threw away the
      // URL and the volume, and there was no way at all to turn a set that had
      // come out facing the wrong way.
      //
      // The nudge is relative to the SET, not to the player or the world axis:
      // LEFT moves the television along the cabinet's own left, so a set turned
      // to face a room still moves the way the button says. The arithmetic lives
      // in the media resource (`shared/placement.lua`) and is pinned by its own
      // test, because a "left" that moves a set right is exactly the kind of
      // wrong that no log line can report.
      const placement = document.createElement("div");
      placement.className = "row placement-controls";
      const step = document.createElement("select");
      step.className = "search";
      step.title = "How far one press moves the set";
      step.setAttribute("aria-label", "Placement step size");
      for (const metres of [0.05, 0.25, 1, 5]) {
        const option = document.createElement("option");
        option.value = String(metres);
        option.textContent = `${metres} m`;
        if (metres === 0.25) option.selected = true;
        step.appendChild(option);
      }
      placement.appendChild(step);
      const nudges = [
        ["▲ UP", "up"], ["▼ DOWN", "down"],
        ["◀ LEFT", "left"], ["▶ RIGHT", "right"],
        ["FORWARD", "forward"], ["BACK", "back"],
      ];
      for (const [label, direction] of nudges) {
        const button = document.createElement("button");
        button.className = "btn";
        button.type = "button";
        button.textContent = label;
        button.title = `Move the set ${direction} by the step`;
        button.addEventListener("click", () =>
          tvSend("move", { id: screen.id, direction, metres: Number(step.value) }));
        placement.appendChild(button);
      }
      for (const [label, direction] of [["↺ TURN", "left"], ["↻ TURN", "right"]]) {
        const button = document.createElement("button");
        button.className = "btn";
        button.type = "button";
        button.textContent = label;
        button.title = `Turn the set 15° to its ${direction}`;
        button.addEventListener("click", () =>
          tvSend("rotate", { id: screen.id, direction, degrees: 15 }));
        placement.appendChild(button);
      }

      row.append(head, where, urlRow, controls, placement);
      list.appendChild(row);
    }
  }

  document.getElementById("tv-search").addEventListener("input", event => {
    tvFilter = text(event.target.value);
    renderTvCatalogue();
  });
  document.getElementById("tv-refresh").addEventListener("click", requestTv);

  document.addEventListener("keydown", event => {
    if (!body.classList.contains("open")) return;
    if (event.key === "Escape") { event.preventDefault(); close(); }
    if (event.key === "/" && !body.classList.contains("animation-mode") &&
        !["INPUT", "TEXTAREA", "SELECT"].includes(document.activeElement?.tagName)) {
      const input = body.querySelector(".page.active input.search, .page.active #travel-search");
      if (input) { event.preventDefault(); input.focus(); }
    }
    if (event.key === "Tab") {
      const focusable = [...body.querySelectorAll('button, input, select, summary, [tabindex="0"]')]
        .filter(element => !element.disabled && element.getClientRects().length && getComputedStyle(element).visibility !== "hidden");
      const first = focusable[0], last = focusable[focusable.length - 1];
      if (first && (!body.contains(document.activeElement) ||
          (event.shiftKey && document.activeElement === first) || (!event.shiftKey && document.activeElement === last))) {
        event.preventDefault(); (event.shiftKey ? last : first).focus();
      }
    }
  });

  // Bridge ---------------------------------------------------------------

  Open77.on("freeroam:state", payload => {
    if (payload && typeof payload === "object") state = payload;
    body.querySelector('[data-tab="tv"]').hidden = state.canManageTv !== true;
    if (state.canManageTv !== true) {
      tvCatalogue = []; tvLocal = [];
      renderTvCatalogue(); renderTvLocal();
      if (document.getElementById("page-tv").classList.contains("active")) activatePage("vehicles");
    }
    render();
  });
  Open77.on("freeroam:tv:open", () => {
    if (state.canManageTv !== true) return;
    activatePage("tv"); requestTv();
  });
  Open77.on("freeroam:weapons", payload => {
    weaponSlots = asArray(payload && payload.slots);
    renderWeapons();
    renderLoadout();
  });
  Open77.on("freeroam:garage", payload => {
    garageState = payload && typeof payload === "object" ? payload : { count: 0, maximum: 0 };
    renderVehicles();
  });
  Open77.on("freeroam:player", payload => {
    playerState = payload && typeof payload === "object" ? payload : { available: false };
    renderPlayerState();
  });
  Open77.on("freeroam:open", () => {
    body.classList.add("open");
    const name = body.querySelector(".page.active")?.id.replace("page-", "") || "vehicles";
    activatePage(name);
    const focus = body.classList.contains("animation-mode") ? document.getElementById("anim-search") : body.querySelector(".tab.active");
    focus?.focus({ preventScroll: true });
  });
  Open77.on("freeroam:closed", () => body.classList.remove("open"));
  Open77.on("freeroam:result", payload => {
    if (payload && payload.text) showToast(payload.ok === true, payload.text);
  });
  // `freeroam:tv` carries three shapes, told apart by which key is present
  // rather than by a discriminator: the catalogue, this client's nearby sets, and
  // a one-line answer to an action. They arrive from different places (the media
  // resource's server and its client), so a shared discriminator would have to
  // be invented on both sides for no gain.
  Open77.on("freeroam:tv", payload => {
    if (state.canManageTv !== true) return;
    if (!payload || typeof payload !== "object") return;
    if (payload.catalogue) {
      tvCatalogue = asArray(payload.catalogue);
      document.getElementById("tv-status").textContent = tvCatalogue.length
        ? `${tvCatalogue.length} screens available · Choose a model to place it nearby.`
        : "No televisions are available. Check that the media resource is running.";
      renderTvCatalogue();
      return;
    }
    if (payload.screens) {
      tvLocal = asArray(payload.screens);
      renderTvLocal();
      return;
    }
    if (payload.text) {
      showToast(payload.ok === true, payload.text);
      if (payload.ok === true) requestTv();
    }
  });

  Open77.ready();
  Open77.emit("freeroam:ready", {});
})();
