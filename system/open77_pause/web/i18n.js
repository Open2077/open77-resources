/* The page half of the one string table.
 *
 * shared/strings.lua is the ONLY place a player-facing word this resource owns
 * is written. The client script hands that table over verbatim on
 * `pause:strings`, and this file is what applies it: `apply(root)` fills every
 * element carrying `data-t` with the value at that dotted path, so index.html
 * holds structure and no language at all. Dynamic text asks for `t(path)` or
 * `fmt(path, values)`.
 *
 * Three attribute forms exist beside the text one, because a screen reader
 * needs words too and an `aria-label` cannot be a child node:
 *
 *     data-t              textContent
 *     data-t-label        aria-label
 *     data-t-title        title
 *     data-t-placeholder  placeholder
 *
 * Nothing here invents a fallback string. A missing key renders as its own
 * path, which is ugly ON PURPOSE: a blank label hides the mistake, a visible
 * `settings.filterPlaceholder` does not, and the second one gets fixed.
 *
 * Deliberately NOT in this table: engine setting labels and dropdown option
 * names. Those arrive already localised from the game itself, on the `meta:`
 * line of the script bridge -- see shared/strings.lua for the full list of what
 * counts as data rather than language.
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
   * no matching value is left standing rather than blanked, for the same reason
   * a missing key is. */
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
    for (const element of scope.querySelectorAll("[data-t-label]")) {
      element.setAttribute("aria-label", t(element.dataset.tLabel));
    }
    for (const element of scope.querySelectorAll("[data-t-title]")) {
      element.setAttribute("title", t(element.dataset.tTitle));
    }
    for (const element of scope.querySelectorAll("[data-t-placeholder]")) {
      element.setAttribute("placeholder", t(element.dataset.tPlaceholder));
    }
  }

  function set(next) {
    table = next && typeof next === "object" ? next : null;
    apply(document);
    return table;
  }

  function ready() { return table !== null; }

  window.PauseText = { set, apply, t, fmt, ready };
})();
