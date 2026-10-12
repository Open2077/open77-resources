(function () {
  "use strict";
  var snapshot = null, selected = null, isOpen = false;
  var grades = {}, pending = {}, lastRecords = {}, renderKey = "", rosterKey = "", reports = 0;
  var slam = null, slamChoice = "harmless", slamKey = "";
  var reflex = null, reflexChoice = "street", reflexKey = "";
  var dashChoice = {preset: "basic", mode: "ground"}, dashKey = "", dashNodes = {}, dashPending = {};
  var panel = document.querySelector(".panel");
  function list(value) { return Array.isArray(value) ? value : []; }
  function emit(event, value) { window.Open77.emit("cyberlab:" + event, value || {}); }
  function diagnostic(message) {
    if (reports++ < 12) { try { emit("diag", {message: String(message).slice(0, 500)}); } catch (_) {} }
  }
  window.addEventListener("error", function (event) { diagnostic(event.message); });
  function on(event, handler) {
    window.Open77.on("cyberlab:" + event, function (payload) {
      try { handler(payload || {}); } catch (error) { diagnostic(error.stack || error.message); }
    });
  }
  function text(node, value) { node.textContent = value == null ? "" : String(value); }
  function el(tag, className, value) {
    var node = document.createElement(tag);
    if (className) node.className = className;
    if (value != null) text(node, value);
    return node;
  }
  function label(value) { return String(value || "").replace(/[_-]/g, " ").replace(/\b\w/g, function (c) { return c.toUpperCase(); }); }
  function notify(message, kind) { text(document.getElementById("status"), message); document.getElementById("status").className = kind || ""; }
  function playerName(player) { return (player && player.name) || "Unavailable player"; }
  function gradeId(implant) { return implant && implant.grade && implant.grade.id; }
  function installed(record, slot) { return record && typeof record[slot] === "object" ? record[slot] : null; }
  function busy() { return Boolean(snapshot && snapshot.pending) || Boolean(pending[selected]); }

  function chooseTarget(id) {
    if (id === selected) return;
    selected = id;
    dashKey = ""; renderDash();
    slam = null; slamKey = ""; renderSlam(); reflex = null; reflexKey = ""; renderReflex();
    renderKey = "";
    renderRoster();
    document.getElementById("implants").replaceChildren(el("p", "empty", "Loading implants…"));
    text(document.getElementById("target-name"), "Loading player #" + id);
    text(document.getElementById("target-detail"), "Waiting for current implant state…");
    text(document.getElementById("readiness"), "Loading");
    document.getElementById("readiness").className = "badge";
    notify("Loading player #" + id + "…");
    emit("target", {target: id});
  }

  function renderRoster() {
    if (!snapshot) return;
    var roster = list(snapshot.players), filter = document.getElementById("search").value.toLowerCase();
    var nextKey = JSON.stringify([roster, filter, selected, snapshot.you]);
    if (nextKey === rosterKey) return;
    rosterKey = nextKey;
    text(document.getElementById("count"), roster.length);
    document.getElementById("self").classList.toggle("on", snapshot.you && selected === snapshot.you.id);
    var container = document.getElementById("players");
    container.replaceChildren();
    roster.forEach(function (player) {
      if ((playerName(player) + " " + player.id).toLowerCase().indexOf(filter) < 0) return;
      var button = el("button", "player" + (player.id === selected ? " on" : ""));
      button.type = "button";
      button.setAttribute("aria-pressed", player.id === selected ? "true" : "false");
      button.appendChild(el("span", "", playerName(player)));
      button.appendChild(el("small", "", "#" + player.id));
      button.addEventListener("click", function () { chooseTarget(player.id); });
      container.appendChild(button);
    });
    if (!container.childElementCount) container.appendChild(el("p", "empty", "No matching players"));
  }

  function gradeSummary(grade, slot) {
    if (!grade) return "No grades available";
    if (slot === "legs") return grade.jumpStaminaCost + " stamina / jump · " + grade.cooldownMs + " ms cooldown";
    if (grade.cosmetic) return "Appearance only · No implant damage";
    return grade.normalDamage + " normal / " + grade.chargedDamage + " charged damage · " + grade.knockbackMeters + " m knockback" + (grade.nonlethal ? " · Nonlethal" : "");
  }

  function act(slot, action, grade) {
    if (!snapshot || selected !== snapshot.target.id || !snapshot.ready || busy()) return;
    pending[selected] = {at: Date.now()};
    notify((action === "install" ? "Installing" : "Removing") + " " + (slot === "arms" ? "Gorilla Arms" : "Double Jump") + " for " + playerName(snapshot.target) + " (#" + selected + ")…", "busy");
    renderKey = "";
    renderImplants();
    emit("action", {target: selected, slot: slot, action: action, grade: grade});
  }

  function renderImplants() {
    if (!snapshot || !snapshot.target || snapshot.target.id !== selected) return;
    // Polls must not tear down an open dropdown or steal keyboard focus. Only
    // rebuild controls when the relevant server state or a local choice changes.
    var nextKey = JSON.stringify([selected, snapshot.record, snapshot.effective, snapshot.catalog, snapshot.ready, busy(), grades]);
    if (nextKey === renderKey) return;
    renderKey = nextKey;
    var container = document.getElementById("implants");
    container.replaceChildren();
    list(snapshot.catalog).forEach(function (item) {
      var options = list(item.grades), owned = installed(snapshot.record || lastRecords[selected], item.slot), active = installed(snapshot.effective, item.slot);
      var choiceKey = selected + ":" + item.slot;
      var chosen = grades[choiceKey] || gradeId(owned) || (options[0] && options[0].id);
      if (!options.some(function (grade) { return grade.id === chosen; })) chosen = options[0] && options[0].id;
      var chosenGrade = options.find(function (grade) { return grade.id === chosen; });
      var same = owned && owned.definition === item.definition && gradeId(owned) === chosen;
      var card = el("article", "implant");
      var slot = el("div", "slot", item.slot + " slot");
      slot.appendChild(el("span", "", !snapshot.ready ? "Applying / waiting" : owned ? "Installed" : "Empty"));
      card.appendChild(slot);
      card.appendChild(el("h2", "", item.label || (item.slot === "arms" ? "Gorilla Arms" : "Double Jump")));
      card.appendChild(el("p", "description", item.slot === "arms" ? "Powerful fists with charged strikes and knockback." : "Jump again in midair. Land to recharge your next boost."));
      var state = el("div", "installed");
      state.appendChild(el("strong", "", !snapshot.ready ? (owned ? "Last observed: " + label(gradeId(owned)) : "Current implant state unavailable") : owned ? label(gradeId(owned)) + " installed" : "No implant installed"));
      if (active && (!owned || active.instanceId !== owned.instanceId)) state.appendChild(el("small", "", "Active override: " + label(gradeId(active))));
      else state.appendChild(el("small", "", !snapshot.ready ? "Waiting for the current operation and native projection." : active ? "Active" : owned ? "Waiting for activation" : "Baseline movement / combat"));
      card.appendChild(state);
      card.appendChild(el("div", "grade-label", "Choose grade"));
      var dropdown = el("details", "dropdown");
      var summary = el("summary", "", chosen ? label(chosen) : "Unavailable");
      summary.setAttribute("aria-label", (item.label || item.slot) + " grade");
      dropdown.appendChild(summary);
      var choices = el("div", "choices");
      choices.setAttribute("role", "listbox");
      choices.setAttribute("aria-label", "Available grades");
      options.forEach(function (grade) {
        var option = el("button", "", label(grade.id));
        option.type = "button";
        option.setAttribute("role", "option");
        option.setAttribute("aria-selected", grade.id === chosen ? "true" : "false");
        option.addEventListener("click", function () {
          grades[choiceKey] = grade.id;
          renderKey = "";
          renderImplants();
        });
        choices.appendChild(option);
      });
      dropdown.appendChild(choices);
      card.appendChild(dropdown);
      card.appendChild(el("div", "grade-info", gradeSummary(chosenGrade, item.slot)));
      var actions = el("div", "actions");
      var install = el("button", "install", same ? "Installed" : owned ? "Replace" : "Install");
      install.type = "button";
      install.disabled = !snapshot.ready || busy() || !chosen || Boolean(same);
      install.addEventListener("click", function () { act(item.slot, "install", chosen); });
      var remove = el("button", "remove", "Remove");
      remove.type = "button";
      remove.disabled = !snapshot.ready || busy() || !owned;
      remove.addEventListener("click", function () { act(item.slot, "remove"); });
      actions.appendChild(install); actions.appendChild(remove); card.appendChild(actions);
      container.appendChild(card);
    });
    if (!container.childElementCount) container.appendChild(el("p", "empty", "No implants are available. Refresh after the cyberware resource starts."));
  }

  function receive(data, opening) {
    if (!data.target) return;
    if (opening) { selected = data.target.id; grades = {}; renderKey = ""; slam = null; slamKey = ""; renderSlam(); reflex = null; reflexKey = ""; renderReflex(); }
    if (selected !== data.target.id) return;
    snapshot = data;
    if (data.record && typeof data.record === "object") lastRecords[selected] = data.record;
    if (!snapshot.pending && pending[selected] && Date.now() - pending[selected].at > 15000) {
      delete pending[selected];
      notify("No completion received. Current implant state is shown; refresh before trying again.", "bad");
    }
    text(document.getElementById("target-name"), playerName(data.target));
    text(document.getElementById("target-detail"), "Player #" + selected + (data.you && selected === data.you.id ? " · You" : " · Changes apply to this player") + (!data.ready && data.reason ? " · " + label(data.reason) : ""));
    var readiness = document.getElementById("readiness");
    text(readiness, busy() ? "Applying…" : data.ready ? "Ready" : "Not ready");
    readiness.className = "badge " + (busy() ? "busy" : data.ready ? "good" : "");
    renderRoster(); renderImplants(); renderDash();
  }

  function dashAction(action) {
    var data = snapshot && snapshot.dash;
    if (!isOpen || !snapshot || snapshot.target.id !== selected || !data || !data.available || dashPending[selected]) return;
    if (data.manageable === false && (action === "install" || action === "remove")) return;
    if (action === "install" && (list(data.presets).indexOf(dashChoice.preset) < 0 || list(data.modes).indexOf(dashChoice.mode) < 0)) return;
    if (action === "install" || action === "remove") dashPending[selected] = Date.now();
    notify("Dash " + (action === "install" ? "grant" : action) + " requested for player #" + selected + "…", "busy");
    emit("action", {slot: "dash", target: selected, action: action, preset: dashChoice.preset, mode: dashChoice.mode});
    renderDash();
  }

  function dashGrantLabel(definition) {
    var id = String(definition.id || "");
    var preset = /^(?:cyberlab\.dash|example\.parkour)\.(basic|advanced)\.(ground|air|combined)$/.exec(id);
    return preset ? label(preset[1]) + " / " + label(preset[2]) : id || "Definition unavailable";
  }

  function renderDash() {
    var container = document.getElementById("dash");
    var data = snapshot && snapshot.target.id === selected && snapshot.dash;
    if (!data) {
      dashKey = "";
      container.replaceChildren(el("p", "empty", snapshot && snapshot.target.id === selected ? "Dash state unavailable. Refresh after the support resource is ready." : "Loading Dash / Air Dash…"));
      return;
    }
    var presets = list(data.presets), modes = list(data.modes);
    if (presets.indexOf(dashChoice.preset) < 0) dashChoice.preset = presets[0];
    if (modes.indexOf(dashChoice.mode) < 0) dashChoice.mode = modes[0];
    var key = JSON.stringify([selected, presets, modes, dashChoice]);
    // Live feedback changes without replacing dropdowns or taking keyboard focus.
    if (key !== dashKey) {
      dashKey = key; dashNodes = {};
      var card = el("article", "implant");
      card.appendChild(el("div", "eyebrow", "Session ability"));
      card.appendChild(el("h2", "", "Dash / Air Dash"));
      dashNodes.hint = card.appendChild(el("p", "description"));
      var selectors = el("div", "dash-selectors");
      [["preset", "Dash preset", presets], ["mode", "Dash loadout", modes]].forEach(function (item) {
        var group = el("div"), dropdown = el("details", "dropdown");
        group.appendChild(el("div", "grade-label", item[1]));
        var summary = el("summary", "", label(dashChoice[item[0]]));
        summary.setAttribute("aria-label", item[1]); dropdown.appendChild(summary);
        var choices = el("div", "choices"); choices.setAttribute("role", "listbox"); choices.setAttribute("aria-label", item[1]);
        item[2].forEach(function (id) {
          var button = el("button", "", label(id)); button.type = "button";
          button.setAttribute("role", "option"); button.setAttribute("aria-selected", id === dashChoice[item[0]] ? "true" : "false");
          button.addEventListener("click", function () {
            dashChoice[item[0]] = id; renderDash();
            if (dashNodes[item[0]] && dashNodes[item[0]].focus) dashNodes[item[0]].focus();
          });
          choices.appendChild(button);
        });
        dropdown.appendChild(choices); group.appendChild(dropdown); selectors.appendChild(group);
        dashNodes[item[0]] = summary;
      });
      card.appendChild(selectors);
      dashNodes.preview = card.appendChild(el("p", "grade-info"));
      dashNodes.loadout = card.appendChild(el("p", "help"));
      var feedback = el("dl", "dash-feedback"); feedback.setAttribute("aria-label", "Latest server Dash state");
      [["grant", "Current grant"], ["status", "Grant / projection"], ["native", "Native readiness"], ["stamina", "Stamina"], ["charges", "Charges"], ["rearm", "Air rearm"], ["phase", "Activity"]].forEach(function (item) {
        var row = el("div", item[0] === "grant" ? "dash-current-grant" : ""); row.appendChild(el("dt", "", item[1]));
        dashNodes[item[0]] = row.appendChild(el("dd")); feedback.appendChild(row);
      });
      card.appendChild(feedback);
      dashNodes.reason = card.appendChild(el("p", "help"));
      var actions = el("div", "actions");
      [["install", "Grant"], ["inspect", "Inspect"], ["remove", "Remove"], ["test", "Test instructions"]].forEach(function (item) {
        var button = el("button", item[0] === "install" ? "install" : "", item[1]); button.type = "button";
        button.addEventListener("click", function () { dashAction(item[0]); });
        dashNodes[item[0]] = button; actions.appendChild(button);
      });
      card.appendChild(actions); container.replaceChildren(card);
    }
    if (dashPending[selected] && Date.now() - dashPending[selected] > 15000) delete dashPending[selected];
    var current = data.current, projection = current && current.projection, config = projection && projection.definition && projection.definition.config;
    var hasGrant = Boolean(projection && projection.definition && projection.status !== "absent");
    var preset = data.presetDetails && data.presetDetails[dashChoice.preset];
    text(dashNodes.preview, preset ? "Selected preset: " + preset.staminaCost + " stamina / dash · " + preset.maxCharges + " charges · " + preset.cooldownMs + " ms cooldown · " + preset.chargeRegenMs + " ms charge regen" : "Preset limits are configured by the server.");
    text(dashNodes.hint, data.hint || "Close this panel, release the binding, then hold a movement direction and press " + String(data.inputKey || "ctrl").toUpperCase() + ". Jump first to test Air Dash; land to rearm.");
    text(dashNodes.loadout, dashChoice.mode === "combined" ? "Combined requires installed, active double-jump legs. This session grant leaves your arms and legs unchanged." : "Standalone " + label(dashChoice.mode) + " Dash is a session grant; it leaves your installed arms and legs unchanged.");
    text(dashNodes.grant, hasGrant ? dashGrantLabel(projection.definition) : data.available ? "None" : "Unavailable");
    text(dashNodes.status, dashPending[selected] ? "Request pending" : !data.available ? "Unavailable" : projection ? label(projection.status) : "Not granted");
    text(dashNodes.native, data.nativeReady === true ? "Ready (reported)" : data.nativeReady === false ? "Not ready (reported)" : "Unknown — native readiness not reported");
    text(dashNodes.stamina, typeof data.stamina === "number" ? String(data.stamina) + (config ? " · " + config.staminaCost + " per dash" : "") : "Unavailable");
    text(dashNodes.charges, current && typeof current.charges === "number" ? current.charges + (config ? " / " + config.maxCharges : "") : "Unavailable");
    text(dashNodes.rearm, current ? (current.airUsed ? "Air dash used — land to rearm" : "Air charge unused — eligibility checked on input") + (config ? " · " + config.landingRearmMs + " ms landing rearm" : "") : "One air dash per airtime; land to rearm");
    text(dashNodes.phase, current ? label(current.phase || "idle") + (config ? " · " + config.cooldownMs + " ms cooldown · " + config.chargeRegenMs + " ms charge regen" : "") : "No active grant");
    text(dashNodes.reason, data.reason ? label(data.reason) : "Inspect refreshes the selected player's server state. Test instructions do not activate movement.");
    ["install", "inspect", "remove", "test"].forEach(function (action) {
      dashNodes[action].disabled = !data.available || Boolean(dashPending[selected]) || (data.manageable === false && (action === "install" || action === "remove")) || (action === "remove" && !hasGrant) || (action === "install" && (!dashChoice.preset || !dashChoice.mode));
    });
  }

  function renderSlam() {
    var container = document.getElementById("slam");
    if (!slam || slam.target !== selected) { container.replaceChildren(el("p", "empty", "Loading Ground Slam…")); return; }
    var key = JSON.stringify([slam, slamChoice]);
    if (key === slamKey) return;
    slamKey = key;
    var card = el("article", "implant");
    card.appendChild(el("div", "eyebrow", "Session ability"));
    card.appendChild(el("h2", "", "Ground Slam"));
    card.appendChild(el("p", "description", "Equip a blunt weapon, close this panel, then press " + String(slam.inputKey || "g").toUpperCase() + " on the ground or in the air. Ordinary landings do not activate it."));
    var grant = slam.grant, state = el("div", "installed");
    state.appendChild(el("strong", "", grant ? "Ground Slam " + label(grant.status) : "Not granted"));
    state.appendChild(el("small", "", grant && grant.definition ? label(grant.definition.id.split(".").pop()) : "No implant is required by the harmless or combat presets."));
    card.appendChild(state);
    var choices = el("div", "presets"), chosen;
    list(slam.presets).forEach(function (preset) {
      if (preset.id === slamChoice) chosen = preset;
      var button = el("button", preset.id === slamChoice ? "on" : "", preset.label);
      button.type = "button"; button.disabled = !preset.available;
      button.setAttribute("aria-pressed", preset.id === slamChoice ? "true" : "false");
      button.addEventListener("click", function () { slamChoice = preset.id; renderSlam(); });
      choices.appendChild(button);
    });
    card.appendChild(choices);
    card.appendChild(el("p", "description", chosen ? chosen.description : "No preset available."));
    card.appendChild(el("small", "", "20 stamina · 5 second cooldown · 4 m radius"));
    var actions = el("div", "actions");
    [["grant", "Grant"], ["revoke", "Revoke"], ["cancel", "Cancel action"]].forEach(function (entry) {
      var button = el("button", entry[0] === "grant" ? "install" : "", entry[1]);
      button.type = "button"; button.disabled = entry[0] === "grant" ? !chosen || !chosen.available : !grant;
      button.addEventListener("click", function () {
        notify("Ground Slam " + entry[1].toLowerCase() + " requested for player #" + selected + "…", "busy");
        emit("slamAction", {target: selected, action: entry[0], preset: slamChoice});
      });
      actions.appendChild(button);
    });
    card.appendChild(actions); container.replaceChildren(card);
  }
  on("slamData", function (data) { if (isOpen && data.target === selected) { slam = data; renderSlam(); } });
  on("slamResult", function (data) {
    if (isOpen && data.target === selected) notify(data.message || "Ground Slam request returned.", data.ok ? "good" : "bad");
  });

  function renderReflex() {
    var container = document.getElementById("reflex");
    if (!reflex || reflex.target !== selected) { container.replaceChildren(el("p", "empty", "Loading Overdrive…")); return; }
    var key = JSON.stringify([reflex, reflexChoice]);
    if (key === reflexKey) return;
    reflexKey = key;
    var card = el("article", "implant");
    card.appendChild(el("div", "eyebrow", "Session ability"));
    card.appendChild(el("h2", "", "Overdrive"));
    card.appendChild(el("p", "description", "Close this panel and tap " + String(reflex.inputKey || "x").toUpperCase() + " — the \"Overdrive\" action is rebindable under Pause › Settings › Key Bindings. Real time only: you move, swing and reload faster; nobody else is slowed and no bullet is slowed."));
    var current = reflex.current, state = el("div", "installed");
    var status = current && current.projection ? current.projection.status : (current ? current.phase : null);
    state.appendChild(el("strong", "", current ? "Overdrive " + label(status || "granted") : "Not granted"));
    state.appendChild(el("small", "", current
      ? "Charges " + (current.charges == null ? "?" : current.charges) + (current.remainingMs ? " · " + Math.ceil(current.remainingMs / 1000) + " s left" : "")
      : (reflex.reason ? label(reflex.reason) : "No implant is required by the lab presets.")));
    card.appendChild(state);
    var choices = el("div", "presets"), details = reflex.presetDetails || {}, chosen;
    list(reflex.presets).forEach(function (id) {
      var detail = details[id] || {};
      if (id === reflexChoice) chosen = detail;
      var button = el("button", id === reflexChoice ? "on" : "", label(id));
      button.type = "button"; button.disabled = !reflex.available;
      button.setAttribute("aria-pressed", id === reflexChoice ? "true" : "false");
      button.addEventListener("click", function () { reflexChoice = id; renderReflex(); });
      choices.appendChild(button);
    });
    card.appendChild(choices);
    card.appendChild(el("p", "description", chosen ? (chosen.tier === "reflex_heavy" ? "Heavy tier: the stronger boost, told apart on sight by the arc at the right hand." : "Standard tier: the everyday boost.") : "No preset available."));
    card.appendChild(el("small", "", chosen ? [
      Math.round((chosen.durationMs || 0) / 1000) + " s boost",
      Math.round((chosen.cooldownMs || 0) / 1000) + " s cooldown",
      (chosen.maxCharges || 1) + " charge" + ((chosen.maxCharges || 1) > 1 ? "s" : ""),
      (chosen.staminaCost || 0) + " stamina"].join(" · ") : ""));
    var actions = el("div", "actions");
    [["grant", "Grant"], ["revoke", "Revoke"], ["cancel", "Cancel boost"]].forEach(function (entry) {
      var button = el("button", entry[0] === "grant" ? "install" : "", entry[1]);
      button.type = "button";
      button.disabled = entry[0] === "grant" ? (!reflex.available || reflex.manageable === false) : !current;
      button.addEventListener("click", function () {
        notify("Overdrive " + entry[1].toLowerCase() + " requested for player #" + selected + "…", "busy");
        emit("reflexAction", {target: selected, action: entry[0], preset: reflexChoice});
      });
      actions.appendChild(button);
    });
    card.appendChild(actions); container.replaceChildren(card);
  }
  on("reflexData", function (data) { if (isOpen && data.target === selected) { reflex = data; renderReflex(); } });
  on("reflexResult", function (data) {
    if (isOpen && data.target === selected) notify(data.message || "Overdrive request returned.", data.ok ? "good" : "bad");
  });

  function close() { isOpen = false; panel.hidden = true; emit("close"); }
  document.getElementById("close").addEventListener("click", close);
  document.getElementById("show-dash").addEventListener("click", function () {
    document.getElementById("dash").scrollIntoView({block: "start", behavior: "smooth"});
  });
  document.getElementById("show-reflex").addEventListener("click", function () {
    document.getElementById("reflex").scrollIntoView({block: "start", behavior: "smooth"});
  });
  document.getElementById("show-slam").addEventListener("click", function () {
    document.getElementById("slam").scrollIntoView({block: "start", behavior: "smooth"});
  });
  document.getElementById("refresh").addEventListener("click", function () { notify("Refreshing player state…"); emit("refresh"); });
  document.getElementById("search").addEventListener("input", renderRoster);
  document.getElementById("self").addEventListener("click", function () { if (snapshot && snapshot.you) chooseTarget(snapshot.you.id); });
  document.addEventListener("keydown", function (event) { if (isOpen && event.key === "Escape") { event.preventDefault(); close(); } });
  document.addEventListener("click", function (event) {
    document.querySelectorAll("details[open]").forEach(function (dropdown) { if (!dropdown.contains(event.target)) dropdown.open = false; });
  });
  on("open", function (data) {
    isOpen = true; panel.hidden = false; document.getElementById("search").value = "";
    receive(data, true);
    notify("Choose an implant and grade for " + playerName(data.target) + " (#" + selected + ").");
  });
  on("data", function (data) { if (isOpen) receive(data, false); });
  on("close", function () { isOpen = false; panel.hidden = true; });
  on("result", function (result) {
    if (result.slot === "dash") {
      if (result.phase !== "pending") delete dashPending[result.target];
      if (!isOpen || result.target !== selected) return;
      notify(result.message || (result.ok ? "Dash request accepted; inspect current state." : "Dash request refused."), result.ok ? "good" : "bad");
      renderDash(); return;
    }
    if (result.phase === "pending") pending[result.target] = {at: Date.now()};
    else delete pending[result.target];
    if (!isOpen) return;
    notify((result.target ? "Player #" + result.target + ": " : "") + (result.message || result.error || (result.ok ? "Complete" : "Operation failed")), result.phase === "pending" ? "busy" : result.ok ? "good" : "bad");
    renderKey = "";
    renderImplants();
  });
  emit("ready");
})();
