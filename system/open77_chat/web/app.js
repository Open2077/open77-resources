(() => {
  "use strict";

  const MAX_MESSAGES = 48;
  const MAX_MESSAGE_LENGTH = 4096;
  const DEFAULT_STALE_DELAY = 8500;
  const KNOWN_KINDS = new Set([
    "message", "system", "announce", "warning", "error", "action", "join", "leave"
  ]);
  const CHANNELS = {
    global: { label: "Global", color: "#22d8e2" },
    local: { label: "Local", color: "#8a94a2" },
    squad: { label: "Squad", color: "#2be58b" },
    whisper: { label: "Whisper", color: "#7c5cff" },
    ooc: { label: "OOC", color: "#ffb020" },
    admin: { label: "Admin", color: "#ff3b4e" }
  };

  const root = document.getElementById("chat");
  const messages = document.getElementById("messages");
  const emptyState = document.getElementById("emptyState");
  const composer = document.getElementById("composer");
  const input = document.getElementById("input");
  const characterCount = document.getElementById("characterCount");
  const sendButton = document.getElementById("sendButton");
  const messageCount = document.getElementById("messageCount");
  const suggestionsNode = document.getElementById("suggestions");
  const suggestionList = document.getElementById("suggestionList");
  const suggestionCount = document.getElementById("suggestionCount");
  const scrollLatest = document.getElementById("scrollLatest");
  const unreadCount = document.getElementById("unreadCount");

  const suggestions = new Map();
  const templates = new Map();
  const history = [];
  let historyIndex = 0;
  let open = false;
  let visibleSuggestions = [];
  let selectedSuggestion = 0;
  let unreadMessages = 0;

  const bounded = (value, max = MAX_MESSAGE_LENGTH) => String(value ?? "").slice(0, max);
  const safeToken = (value, fallback) => {
    const token = bounded(value, 24).toLowerCase().replace(/[^a-z0-9_-]/g, "");
    return token || fallback;
  };
  const rgb = (value, fallback = "#22d8e2") => {
    if (!Array.isArray(value) || value.length < 3) return fallback;
    const component = index => Math.max(0, Math.min(255, Math.round(Number(value[index]) || 0)));
    return `rgb(${component(0)}, ${component(1)}, ${component(2)})`;
  };
  const timeNow = () => new Intl.DateTimeFormat("en-GB", {
    hour: "2-digit", minute: "2-digit", hour12: false
  }).format(new Date());
  const isAtBottom = () => messages.scrollHeight - messages.scrollTop - messages.clientHeight < 28;

  function formatCount(value) {
    return String(Math.max(0, value)).padStart(2, "0");
  }

  function updateEmptyState() {
    const empty = messages.children.length === 0;
    root.classList.toggle("is-empty", empty);
    emptyState.setAttribute("aria-hidden", String(!empty));
    messageCount.textContent = formatCount(messages.children.length);
  }

  function updateComposerState() {
    const length = input.value.length;
    characterCount.textContent = `${String(length).padStart(3, "0")}/256`;
    characterCount.classList.toggle("near-limit", length >= 224);
    sendButton.disabled = input.value.trim().length === 0;
  }

  function updateUnread(value) {
    unreadMessages = Math.max(0, value);
    unreadCount.textContent = String(unreadMessages);
    scrollLatest.hidden = !open || unreadMessages === 0;
  }

  function scrollToLatest(behavior = "auto") {
    messages.scrollTo({ top: messages.scrollHeight, behavior });
    updateUnread(0);
  }

  function scheduleStale(row, delay) {
    if (row._staleTimer) clearTimeout(row._staleTimer);
    row._staleTimer = 0;
    row.classList.remove("stale");
    if (open) return;
    row._staleTimer = setTimeout(() => {
      row._staleTimer = 0;
      if (!open) row.classList.add("stale");
    }, delay);
  }

  function normalizeKind(raw) {
    const source = safeToken(raw.kind || raw.type, "message");
    if (source === "player" || source === "default") return "message";
    if (source === "announcement") return "announce";
    return KNOWN_KINDS.has(source) ? source : "message";
  }

  function normalizeMessage(raw = {}) {
    const args = Array.isArray(raw.args) ? raw.args : [];
    const author = bounded(raw.author ?? (args.length > 1 ? args[0] : ""), 96);
    let text = bounded(
      raw.text ?? raw.message ?? (args.length > 1 ? args.slice(1).join(" ") : args[0]),
      MAX_MESSAGE_LENGTH
    );
    if (raw.templateId && templates.has(String(raw.templateId))) {
      text = templates.get(String(raw.templateId)).replace(/\{(\d+)\}/g,
        (_, index) => bounded(args[Number(index)] ?? "", 1024));
    }

    const kind = normalizeKind(raw);
    const channel = Object.prototype.hasOwnProperty.call(CHANNELS, raw.channel)
      ? raw.channel
      : (kind === "warning" ? "admin" : "global");
    const channelColor = CHANNELS[channel].color;
    return {
      ...raw,
      author,
      text,
      kind,
      channel,
      channelColor,
      color: rgb(raw.color, channelColor),
      playerId: bounded(raw.playerId, 20),
      role: safeToken(raw.role, ""),
      time: bounded(raw.time || timeNow(), 16),
      segments: Array.isArray(raw.segments) ? raw.segments : [],
      mention: raw.mention === true || raw.mentioned === true,
      title: bounded(raw.title, 96)
    };
  }

  function appendText(row, message) {
    const text = document.createElement("span");
    text.className = "message-text";
    if (message.segments.length) {
      for (const source of message.segments.slice(0, 32)) {
        const segment = document.createElement("span");
        segment.className = `message-segment${source && source.bold ? " bold" : ""}`;
        segment.textContent = bounded(source && source.text, 1024);
        if (source && source.color) segment.style.color = rgb(source.color);
        text.append(segment);
      }
    } else {
      text.textContent = message.text;
    }
    row.append(text);
  }

  function appendTime(row, message) {
    const time = document.createElement("time");
    time.className = "message-time";
    time.textContent = message.time;
    row.append(time);
  }

  function buildMessageRow(message) {
    const row = document.createElement("article");
    row.className = `message message-${message.kind}`;
    if (message.mention) row.classList.add("is-mention");
    row.style.setProperty("--message-color", message.color);
    row.style.setProperty("--channel-color", message.channelColor);
    row._staleDelay = Math.max(2500, Number(message.duration) || DEFAULT_STALE_DELAY);

    if (message.kind === "announce") {
      const heading = document.createElement("div");
      heading.className = "message-announcement-heading";
      const label = document.createElement("span");
      label.textContent = `// ${message.title || "Server announcement"}`;
      heading.append(label);
      appendTime(heading, message);
      row.append(heading);
      appendText(row, message);
      return row;
    }

    appendTime(row, message);

    if (message.kind === "system" || message.kind === "error" || message.kind === "warning") {
      const marker = document.createElement("span");
      marker.className = "message-marker";
      marker.textContent = message.kind === "error" ? "!" : message.kind === "warning" ? "△" : "›";
      row.append(marker);
      if (message.author) {
        const source = document.createElement("span");
        source.className = "message-source";
        source.textContent = message.author;
        row.append(source);
      }
      appendText(row, message);
      return row;
    }

    if (message.kind === "join" || message.kind === "leave") {
      const state = document.createElement("span");
      state.className = "presence-state";
      state.setAttribute("aria-hidden", "true");
      row.append(state);
      const presence = document.createElement("span");
      presence.className = "presence-text";
      const action = message.kind === "join" ? "connected" : "disconnected";
      presence.textContent = `${message.author || "Player"} ${action}${message.text ? ` · ${message.text}` : ""}`;
      row.append(presence);
      return row;
    }

    if (message.kind === "action") {
      const action = document.createElement("span");
      action.className = "action-text";
      action.textContent = `* ${message.author || "Player"} ${message.text}`;
      row.append(action);
      return row;
    }

    const channel = document.createElement("span");
    channel.className = "message-channel";
    channel.textContent = CHANNELS[message.channel].label;
    row.append(channel);

    if (/^\d+$/.test(message.playerId)) {
      const id = document.createElement("span");
      id.className = "message-player-id";
      id.textContent = `[${message.playerId}]`;
      row.append(id);
    }

    if (message.author) {
      const author = document.createElement("span");
      author.className = `message-author${message.role ? ` role-${message.role}` : ""}`;
      author.textContent = message.author;
      if (message.role) {
        const role = document.createElement("small");
        role.textContent = `[${message.role}]`;
        author.append(role);
      }
      row.append(author);
    }
    appendText(row, message);
    return row;
  }

  function addMessage(raw) {
    const message = normalizeMessage(raw);
    if (!message.text && !message.segments.length) return;

    const shouldFollow = !open || isAtBottom();
    const row = buildMessageRow(message);
    messages.append(row);
    while (messages.children.length > MAX_MESSAGES) messages.firstElementChild.remove();

    updateEmptyState();
    if (shouldFollow) {
      requestAnimationFrame(() => scrollToLatest());
    } else {
      updateUnread(unreadMessages + 1);
    }
    scheduleStale(row, row._staleDelay);
  }

  function renderSuggestions() {
    suggestionList.replaceChildren();
    const query = input.value.trim().toLowerCase();
    if (!query.startsWith("/")) {
      visibleSuggestions = [];
      selectedSuggestion = 0;
      suggestionsNode.classList.remove("has-items");
      suggestionCount.textContent = "00 matches";
      return;
    }

    const commandQuery = query.split(/\s+/)[0];
    visibleSuggestions = [...suggestions.values()]
      .filter(item => item.command.toLowerCase().startsWith(commandQuery))
      .sort((left, right) => left.command.length - right.command.length || left.command.localeCompare(right.command))
      .slice(0, 7);
    selectedSuggestion = Math.max(0, Math.min(selectedSuggestion, visibleSuggestions.length - 1));
    suggestionCount.textContent = `${formatCount(visibleSuggestions.length)} ${visibleSuggestions.length === 1 ? "match" : "matches"}`;

    visibleSuggestions.forEach((item, index) => {
      const row = document.createElement("div");
      row.className = `suggestion${index === selectedSuggestion ? " selected" : ""}`;
      row.setAttribute("role", "option");
      row.setAttribute("aria-selected", String(index === selectedSuggestion));

      const indexNode = document.createElement("span");
      indexNode.className = "suggestion-index";
      indexNode.textContent = String(index + 1).padStart(2, "0");
      row.append(indexNode);

      const syntax = document.createElement("span");
      syntax.className = "suggestion-syntax";
      const command = document.createElement("strong");
      command.className = "suggestion-command";
      command.textContent = item.command;
      syntax.append(command);
      for (const parameter of (item.parameters || []).slice(0, 8)) {
        const node = document.createElement("span");
        node.className = "suggestion-params";
        const name = bounded(parameter && parameter.name || parameter, 40);
        node.textContent = parameter && parameter.optional ? `[${name}]` : `<${name}>`;
        if (parameter && parameter.help) node.title = bounded(parameter.help, 240);
        syntax.append(node);
      }
      row.append(syntax);

      const help = document.createElement("span");
      help.className = "suggestion-help";
      help.textContent = bounded(item.help, 240);
      row.append(help);
      row.addEventListener("pointerdown", event => {
        event.preventDefault();
        selectedSuggestion = index;
        completeSuggestion();
      });
      suggestionList.append(row);
    });
    suggestionsNode.classList.toggle("has-items", visibleSuggestions.length > 0);
  }

  function completeSuggestion() {
    const item = visibleSuggestions[selectedSuggestion];
    if (!item) return false;
    const match = input.value.match(/^\s*\/\S*(.*)$/s);
    const suffix = match ? match[1] : "";
    input.value = item.command + (suffix.trim() ? suffix : " ");
    input.setSelectionRange(input.value.length, input.value.length);
    selectedSuggestion = 0;
    updateComposerState();
    renderSuggestions();
    input.focus();
    return true;
  }

  function setOpen(value) {
    open = Boolean(value);
    root.classList.toggle("open", open);
    composer.setAttribute("aria-hidden", String(!open));
    root.querySelector(".chat-header").setAttribute("aria-hidden", String(!open));
    root.querySelector(".chat-footer").setAttribute("aria-hidden", String(!open));

    for (const child of messages.children) {
      if (open) {
        if (child._staleTimer) clearTimeout(child._staleTimer);
        child._staleTimer = 0;
        child.classList.remove("stale");
      } else {
        scheduleStale(child, child._staleDelay || DEFAULT_STALE_DELAY);
      }
    }

    if (open) {
      input.focus();
      updateEmptyState();
      requestAnimationFrame(() => {
        scrollToLatest();
        input.focus();
        window.Open77.emit("chat:requestSuggestions", {});
      });
    } else {
      input.blur();
      input.value = "";
      selectedSuggestion = 0;
      updateUnread(0);
      updateComposerState();
      renderSuggestions();
      // The HUD list is shorter than the composer list (30vh vs 34vh, 4+4px vs
      // 11+6px padding), so the scroll offset that was the maximum a moment ago
      // now leaves the newest row below the clip edge — and with few rows the
      // open list never scrolled at all, so the last line is cut in half on
      // every send or Esc. `.messages` has no transition on its box, so the
      // read of scrollHeight inside scrollToLatest() already sees the final
      // layout; the HUD state has no scrolling affordance and is always pinned
      // to the newest row.
      scrollToLatest();
    }
  }

  function submit() {
    const text = input.value.trim();
    if (!text) {
      window.Open77.emit("chat:close", {});
      return;
    }
    history.push(text);
    if (history.length > 50) history.shift();
    historyIndex = history.length;
    root.classList.remove("transmitting");
    void root.offsetWidth;
    root.classList.add("transmitting");
    window.Open77.emit("chat:submit", { text });
  }

  input.addEventListener("input", () => {
    selectedSuggestion = 0;
    updateComposerState();
    renderSuggestions();
  });
  input.addEventListener("focus", () => root.classList.add("input-focused"));
  input.addEventListener("blur", () => root.classList.remove("input-focused"));

  document.addEventListener("keydown", () => {
    if (open && document.activeElement !== input) input.focus();
  }, true);

  input.addEventListener("keydown", event => {
    if (event.isComposing) return;
    if (event.key === "Escape") {
      event.preventDefault();
      window.Open77.emit("chat:close", {});
    } else if (event.key === "Enter") {
      event.preventDefault();
      submit();
    } else if (event.key === "Tab" && visibleSuggestions.length) {
      event.preventDefault();
      completeSuggestion();
    } else if (event.key === "ArrowUp" && visibleSuggestions.length) {
      event.preventDefault();
      selectedSuggestion = (selectedSuggestion - 1 + visibleSuggestions.length) % visibleSuggestions.length;
      renderSuggestions();
    } else if (event.key === "ArrowDown" && visibleSuggestions.length) {
      event.preventDefault();
      selectedSuggestion = (selectedSuggestion + 1) % visibleSuggestions.length;
      renderSuggestions();
    } else if (event.key === "ArrowUp" && history.length) {
      event.preventDefault();
      historyIndex = Math.max(0, historyIndex - 1);
      input.value = history[historyIndex] || "";
      updateComposerState();
      renderSuggestions();
    } else if (event.key === "ArrowDown" && history.length) {
      event.preventDefault();
      historyIndex = Math.min(history.length, historyIndex + 1);
      input.value = history[historyIndex] || "";
      updateComposerState();
      renderSuggestions();
    }
  });

  sendButton.addEventListener("click", submit);
  scrollLatest.addEventListener("click", () => scrollToLatest("smooth"));
  messages.addEventListener("scroll", () => {
    if (isAtBottom()) updateUnread(0);
  }, { passive: true });

  Open77.on("chat:open", () => setOpen(true));
  Open77.on("chat:close", () => setOpen(false));
  Open77.on("chat:state", state => {
    const enabled = !state || state.enabled !== false;
    root.classList.toggle("disabled", !enabled);
    if (!enabled) setOpen(false);
  });
  Open77.on("chat:addMessage", addMessage);
  Open77.on("chat:clear", () => {
    for (const row of messages.children) {
      if (row._staleTimer) clearTimeout(row._staleTimer);
    }
    messages.replaceChildren();
    updateUnread(0);
    updateEmptyState();
  });
  Open77.on("chat:clearSuggestions", () => {
    suggestions.clear();
    selectedSuggestion = 0;
    renderSuggestions();
  });
  Open77.on("chat:addTemplate", payload => {
    if (payload && payload.id) templates.set(String(payload.id), bounded(payload.template));
  });
  Open77.on("chat:addSuggestion", payload => {
    if (!payload || !payload.command) return;
    const command = String(payload.command).startsWith("/") ? String(payload.command) : `/${payload.command}`;
    suggestions.set(command.toLowerCase(), { ...payload, command });
    renderSuggestions();
  });
  Open77.on("chat:addSuggestions", payload => {
    for (const item of (payload && payload.suggestions) || []) {
      if (!item || !item.command) continue;
      const command = String(item.command).startsWith("/") ? String(item.command) : `/${item.command}`;
      suggestions.set(command.toLowerCase(), { ...item, command });
    }
    renderSuggestions();
  });
  Open77.on("chat:removeSuggestion", payload => {
    const command = String(payload && payload.command || "");
    suggestions.delete((command.startsWith("/") ? command : `/${command}`).toLowerCase());
    renderSuggestions();
  });

  updateComposerState();
  updateEmptyState();
  Open77.ready();
  Open77.emit("chat:ready", {});
})();
