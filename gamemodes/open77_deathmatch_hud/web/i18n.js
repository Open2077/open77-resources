/* The page half of the one string table.
 *
 * shared/strings.lua is the ONLY place a player-facing word is written. Both
 * surfaces receive that table verbatim on `dm:strings` and this file is what
 * applies it: `apply(root)` fills every element carrying `data-t` with the
 * value at that dotted path, so the HTML holds structure and no language at
 * all. Dynamic text asks for `t(path)` or `fmt(path, values)`.
 *
 * Nothing here invents a fallback string. A missing key renders as its own
 * path, which is ugly on purpose: a blank label hides the mistake, a visible
 * `panel.rules` does not.
 */
(() => {
  "use strict";

  let table = null;

  function lookup(path) {
    if (!table || typeof path !== "string") return undefined;
    let node = table;
    for (const key of path.split(".")) {
      if (node === null || typeof node !== "object") return undefined;
      node = node[key];
    }
    return node;
  }

  function t(path, fallback) {
    const value = lookup(path);
    if (typeof value === "string") return value;
    if (typeof value === "number") return String(value);
    return fallback === undefined ? String(path) : fallback;
  }

  /* `{name}` placeholders, substituted from a plain object. A placeholder with
   * no matching value is left standing rather than blanked, for the same
   * reason a missing key is. */
  function fmt(path, values) {
    return t(path).replace(/\{(\w+)\}/g, (whole, key) =>
      values && Object.prototype.hasOwnProperty.call(values, key)
        ? String(values[key])
        : whole);
  }

  function apply(root) {
    const scope = root || document;
    for (const element of scope.querySelectorAll("[data-t]")) {
      element.textContent = t(element.dataset.t);
    }
  }

  function set(next) {
    table = next && typeof next === "object" ? next : null;
    apply(document);
    return table;
  }

  function raw() { return table; }

  window.DMStrings = { set, apply, t, fmt, raw };
})();
