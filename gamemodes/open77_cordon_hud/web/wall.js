/* The Cordon boundary surface -- the page half.
 *
 * PRESENTATION ONLY, AND MORE LITERALLY THAN ANYWHERE ELSE IN THIS RESOURCE.
 * Every number that arrives here is a NORMALISED SCREEN COORDINATE that
 * `client/wall.lua` obtained from `Open77.camera.project`. This file multiplies
 * by the viewBox and writes a path. It does not know where the camera is, how
 * wide the field of view is, or where the boundary is in the world -- and it
 * must not learn: the moment a page reconstructs a projection it can disagree
 * with the one Lua computed, and the whole argument for this design ("what is
 * computed is what is drawn") is gone.
 *
 * THE POOL IS FIXED AND NOTHING IS CREATED PER FRAME. Sixteen groups of four
 * paths are built once at load and reused; a frame writes at most 64 `d`
 * attributes and 16 opacities. Creating and destroying SVG nodes twenty times a
 * second would put the layout engine on the frame path, and this surface is
 * already the fourth full-screen composite on a client that has been measured
 * collapsing under three.
 *
 * EVERY FIELD IS OPTIONAL. The first payload can arrive before anything is set,
 * and a payload of zero panels is a normal, frequent state -- it is what the
 * gamemode sends when the boundary is out of range or when the camera was
 * unreadable for a tick. Zero panels must blank the surface, not freeze it: a
 * frozen overlay is the exact defect this whole layer replaces.
 */
(() => {
  "use strict";

  const NS = "http://www.w3.org/2000/svg";

  /* The viewBox. Coordinates arrive normalised 0..1 and are scaled onto it. */
  const VIEW_W = 1920;
  const VIEW_H = 1080;

  /* Must be >= the `MAX_PANELS` in client/wall.lua. Extra slots are free -- an
   * unused group is `visibility: hidden` and never painted -- so this is
   * deliberately the larger of the two, and a Lua-side budget increase does not
   * need an edit here to take effect. */
  const POOL = 24;

  /* Nine numbers per panel, in the order client/wall.lua writes them:
   *   base start x,y   base end x,y   top end x,y   top start x,y   fade
   * The quad is therefore already in path order and needs no re-ordering. */
  const STRIDE = 9;

  const root = document.documentElement;
  const host = document.getElementById("panels");
  const slots = [];

  function num(value, fallback) {
    const n = Number(value);
    return Number.isFinite(n) ? n : (fallback === undefined ? 0 : fallback);
  }

  /* Normalised -> viewBox, rounded to one decimal. A tenth of a viewBox unit is
   * well under a physical pixel at any resolution this runs at, and short
   * numbers keep the path strings small. */
  const px = v => (num(v) * VIEW_W).toFixed(1);
  const py = v => (num(v) * VIEW_H).toFixed(1);

  function path(className) {
    const node = document.createElementNS(NS, "path");
    node.setAttribute("class", className);
    return node;
  }

  for (let index = 0; index < POOL; index += 1) {
    const group = document.createElementNS(NS, "g");
    group.setAttribute("class", "wall-panel");
    group.setAttribute("visibility", "hidden");
    /* Paint order inside a panel: curtain, glow, ribs, base. The base is last
     * because it is the one line that has to survive being drawn over. */
    const fill = path("wall-fill");
    const glow = path("wall-glow");
    const rib = path("wall-rib");
    const base = path("wall-base");
    group.appendChild(fill);
    group.appendChild(glow);
    group.appendChild(rib);
    group.appendChild(base);
    host.appendChild(group);
    slots.push({ group, fill, glow, rib, base, shown: false });
  }

  function hideFrom(first) {
    for (let index = first; index < POOL; index += 1) {
      const slot = slots[index];
      if (slot.shown) {
        slot.group.setAttribute("visibility", "hidden");
        slot.shown = false;
      }
    }
  }

  function render(payload) {
    if (!payload || typeof payload !== "object") { hideFrom(0); return; }

    /* The accent follows the gamemode's config so an operator can retheme the
     * boundary without touching this resource. Validated rather than trusted:
     * an unparsed value here would take the whole stylesheet's colour with it. */
    const colour = payload.color;
    if (typeof colour === "string" && /^#[0-9a-fA-F]{6}$/.test(colour)) {
      root.style.setProperty("--wall-ink", colour);
    }

    const points = payload.points;
    const stride = Math.max(1, Math.trunc(num(payload.stride, STRIDE)));
    let count = Math.trunc(num(payload.panels, 0));
    if (!Array.isArray(points) || count <= 0) { hideFrom(0); return; }
    if (count > POOL) count = POOL;
    /* Never read past the array the host actually sent. A short array is what a
     * trimmed payload looks like, and reading past it would draw a panel at
     * (0,0) -- a bright line in the corner of the screen that looks like a bug
     * in the projection rather than in the guard that is missing. */
    const available = Math.trunc(points.length / stride);
    if (count > available) count = available;

    let drawn = 0;
    for (let index = 0; index < count; index += 1) {
      const at = index * stride;
      const x0 = px(points[at]);
      const y0 = py(points[at + 1]);
      const x1 = px(points[at + 2]);
      const y1 = py(points[at + 3]);
      const x2 = px(points[at + 4]);
      const y2 = py(points[at + 5]);
      const x3 = px(points[at + 6]);
      const y3 = py(points[at + 7]);
      const fade = Math.max(0, Math.min(1, num(points[at + 8], 1)));

      const slot = slots[drawn];
      const baseLine = `M${x0} ${y0}L${x1} ${y1}`;
      slot.fill.setAttribute("d", `${baseLine}L${x2} ${y2}L${x3} ${y3}Z`);
      slot.glow.setAttribute("d", baseLine);
      slot.base.setAttribute("d", baseLine);
      /* Two ribs and the top edge in one path: three subpaths, one attribute
       * write. Adjacent panels share a rib exactly, which draws it twice and
       * makes the joins read as posts -- see the note in client/wall.lua. */
      slot.rib.setAttribute("d",
        `M${x0} ${y0}L${x3} ${y3}M${x1} ${y1}L${x2} ${y2}M${x3} ${y3}L${x2} ${y2}`);
      slot.group.style.opacity = fade.toFixed(3);
      if (!slot.shown) {
        slot.group.setAttribute("visibility", "visible");
        slot.shown = true;
      }
      drawn += 1;
    }

    hideFrom(drawn);
  }

  Open77.on("cordon:wall", render);

  Open77.ready();
  Open77.emit("cordon:wall:ready", {});
})();
