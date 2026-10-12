// Display-only privacy for official Open77 surfaces. Mirrored in shell/pause
// because each WebUI has an isolated origin. Never change bridge/network data.
(function () {
  "use strict";
  let visible = false;
  const hidden = "[address hidden]", known = new Set(), originals = new WeakMap();
  const attributes = ["title", "aria-label", "placeholder", "alt"];
  const skip = "script,style,textarea,input,[data-address-privacy-ignore]";
  let knownPattern = null;
  const ipv4 = /\b(?:\d{1,3}\.){3}\d{1,3}(?::\d{1,5})?\b/g;
  const hostPort = /\b(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z][a-z0-9-]*:\d{1,5}\b|\blocalhost(?::\d{1,5})?\b/gi;
  const ipv6 = /\[[a-f0-9:.%_-]+\](?::\d{1,5})?|(?<![\w:])(?:[a-f0-9]{0,4}:){2,}[a-f0-9:.%_-]*(?![\w:])/gi;
  function text(value) {
    let result = String(value == null ? "" : value);
    if (visible) return result;
    // IPv6 first: an IPv4-mapped address must be hidden as one unit.
    result = result.replace(ipv6, candidate => {
      const host = candidate.startsWith("[") ? candidate.slice(1, candidate.indexOf("]")) : candidate;
      try { new URL("http://[" + host.split("%")[0] + "]/"); return hidden; }
      catch (_) { return candidate; }
    }).replace(ipv4, candidate => candidate.split(":")[0].split(".").every(n => Number(n) <= 255) ? hidden : candidate)
      .replace(hostPort, hidden);
    return knownPattern ? result.replace(knownPattern, hidden) : result;
  }
  function remember(value) {
    let changed = false;
    function address(raw) {
      if (typeof raw !== "string" || !raw.trim()) return;
      try {
        const url = new URL(raw.includes("://") ? raw : "http://" + raw);
        for (const part of [url.host, url.hostname]) {
          if (part && !known.has(part)) { known.add(part); changed = true; }
        }
      } catch (_) { /* malformed data is still covered by the literal filters */ }
    }
    function visit(item) {
      if (!item || typeof item !== "object") return;
      for (const [key, itemValue] of Object.entries(item)) {
        if (/^(endpoint|serverAddress|ipAddress|resourceBaseUrl)$/i.test(key)) address(itemValue);
        else if (itemValue && typeof itemValue === "object") visit(itemValue);
      }
    }
    visit(value);
    if (changed) {
      const parts = [...known].sort((a,b) => b.length-a.length).map(s => s.replace(/[.*+?^${}()|[\]\\]/g,"\\$&"));
      knownPattern = new RegExp("(?<![\\w.-])(?:" + parts.join("|") + ")(?![\\w.-])", "gi");
      refresh();
    }
  }
  function update(node, key, read, write) {
    const current = read();
    let entries = originals.get(node);
    const before = entries && entries[key];
    // Keep the raw value through toggles, but retire it when the renderer writes
    // new content. Weak keys cannot retain rows removed by a directory refresh.
    const raw = before && current === before.display ? before.raw : current;
    const display = text(raw);
    if (display !== current) write(display);
    if (display !== raw || before) {
      if (!entries) originals.set(node, entries = Object.create(null));
      entries[key] = { raw, display };
    }
  }
  function input(element) {
    if (element.matches('input[data-private-address-query]')) {
      element.style.webkitTextSecurity = !visible && text(element.value) !== element.value ? "disc" : "none";
    }
    if (!element.matches('input[data-private-address]')) return;
    // Keep the real value for Direct Connect and native validation.
    element.type = visible ? "text" : "password";
  }
  function scan(root) {
    if (root.nodeType === Node.TEXT_NODE) {
      if (!root.parentElement || root.parentElement.closest(skip)) return;
      update(root,"text",() => root.nodeValue,value => { root.nodeValue = value; });
      return;
    }
    if (root.nodeType !== Node.ELEMENT_NODE) return;
    if (root.matches("script,style,[data-address-privacy-ignore]")) return;
    for (const key of attributes) if (root.hasAttribute(key)) {
      update(root,key,() => root.getAttribute(key),value => root.setAttribute(key,value));
    }
    if (root.matches('input[data-show-addresses]')) root.checked = visible;
    input(root);
    for (const child of root.childNodes) scan(child);
  }
  const observer = new MutationObserver(records => {
    observer.disconnect();
    for (const record of records) {
      if (record.type === "childList") record.addedNodes.forEach(scan);
      else scan(record.target);
    }
    observe();
  });
  function observe() {
    observer.observe(document.documentElement, { subtree:true, childList:true, characterData:true,
      attributes:true, attributeFilter:attributes });
  }
  function refresh() {
    observer.disconnect();
    scan(document.documentElement);
    observe();
  }
  function setVisible(value) {
    visible = value === true;
    refresh();
    window.dispatchEvent(new CustomEvent("address-privacy:changed", { detail:{visible} }));
  }
  document.addEventListener("change", event => {
    if (!event.target.matches("input[data-show-addresses]")) return;
    setVisible(event.target.checked);
    window.dispatchEvent(new CustomEvent("address-privacy:request", { detail:{visible} }));
  });
  document.addEventListener("input", event => input(event.target), true);
  window.Open77AddressPrivacy = { text, remember, setVisible, get visible() { return visible; } };
  // Mutation callbacks run before paint, including asynchronous status/error
  // updates. Only visible text/labels are changed, never IDs, URLs or payloads.
  refresh();
})();
