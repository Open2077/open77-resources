(() => {
  "use strict";
  const root = document.getElementById("notifications");
  const positions = ["top_left", "top_center", "top_right", "middle_left", "bottom_left", "bottom_center", "bottom_right"];
  const stacks = new Map();
  const toasts = new Map();
  // Fallback is the OPEN//77 brand accent (see web/open77-ui.css --op77-accent),
  // so an unstyled toast still reads as part of the platform.
  const safeColor = value => /^#[0-9a-f]{6}$/i.test(String(value || "")) ? String(value) : "#22D8E2";

  // The `//` eyebrow. Every Open77 surface labels itself in mono micro-type
  // before it says anything else; a toast names the kind of event it is.
  // An unknown type still gets a label rather than a blank line.
  const KINDS = { info: "Info", success: "Success", warning: "Warning", error: "Error" };
  const kindLabel = value => KINDS[String(value || "").toLowerCase()]
    || String(value || "").replace(/[^A-Za-z0-9 _-]/g, "").slice(0, 24)
    || "Info";

  for (const position of positions) {
    const stack = document.createElement("section");
    stack.className = `stack ${position}`;
    stack.dataset.position = position;
    root.append(stack);
    stacks.set(position, stack);
  }

  function build(value) {
    const toast = document.createElement("article");
    toast.className = `toast type-${String(value.type || "info")}`;
    toast.dataset.handle = String(value.handle);
    toast.style.setProperty("--accent", safeColor(value.color));

    const icon = document.createElement("span");
    icon.className = "icon";
    icon.textContent = String(value.icon || "").slice(0, 16);
    icon.hidden = !value.icon;
    toast.append(icon);

    const copy = document.createElement("span");
    copy.className = "copy";

    const kind = document.createElement("span");
    kind.className = "kind";
    kind.textContent = kindLabel(value.kind || value.type || "info");
    copy.append(kind);

    if (value.title) {
      const title = document.createElement("strong");
      title.textContent = String(value.title).slice(0, 96);
      copy.append(title);
    }
    const message = document.createElement("span");
    message.className = "message";
    message.textContent = String(value.message || "").slice(0, 384);
    copy.append(message);
    toast.append(copy);

    if (value.progress && Number(value.durationMs) > 0) {
      const progress = document.createElement("i");
      progress.className = "progress";
      progress.style.setProperty("--duration", `${Number(value.durationMs)}ms`);
      toast.append(progress);
    }
    return toast;
  }

  function add(value = {}) {
    const handle = String(value.handle || "");
    const stack = stacks.get(String(value.position || "middle_left"));
    if (!handle || !stack) return;
    const previous = toasts.get(handle);
    if (previous) previous.remove();
    const toast = build(value);
    toasts.set(handle, toast);
    stack.append(toast);
    requestAnimationFrame(() => toast.classList.add("visible"));
  }

  function remove(value = {}) {
    const handle = String(value.handle || "");
    const toast = toasts.get(handle);
    if (!toast) return;
    toasts.delete(handle);
    toast.classList.remove("visible");
    toast.classList.add("leaving");
    setTimeout(() => toast.remove(), 190);
  }

  Open77.on("notification:add", add);
  Open77.on("notification:update", add);
  Open77.on("notification:remove", remove);
  Open77.ready();
  Open77.emit("notifications:ready", {});
})();
