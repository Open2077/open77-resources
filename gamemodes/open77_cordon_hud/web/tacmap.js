/* The Cordon tactical map.
 *
 * SCHEMATIC, AND THAT IS NOT NEGOTIABLE. Every mark on this canvas is drawn
 * from data the server published -- the block grid out of `cordon`, the named
 * landmarks and supply point out of `map`, the squad out of `squad` -- or from
 * the local player's own position, which client/tacmap.lua reads through the
 * ungated `Open77.character.state()`. There is no image asset in this resource
 * and there must never be one: a game map texture is a game asset and
 * redistributing it is forbidden (plan section 17).
 *
 * It is painted as an NCPD sector overlay because that is what the cordon is:
 * a dark ground, a cyan survey grid, sealed blocks hatched red, the closure in
 * progress flashing amber, and one hard white line around the ground that is
 * still yours. The white line is the single most important mark on the page and
 * is drawn last of the terrain so nothing can sit on top of it.
 *
 * The page computes geometry -- world metres to canvas pixels -- and nothing
 * else. It does not decide which blocks are open, where the cordon is going, or
 * whether a pin is legal; a click sends a WORLD POINT and the server answers.
 * A second opinion about the block list would be a second bug.
 *
 * EVERY FIELD IS OPTIONAL. Before the survey exists there is no `cordon` at
 * all, and the map says NO SURVEY DATA rather than drawing a zero-by-zero grid.
 */
(() => {
  "use strict";

  const $ = id => document.getElementById(id);
  const body = document.body;
  const T = window.CordonStrings;

  const canvas = $("mapCanvas");
  const context = canvas.getContext("2d");

  let payload = null;
  let surveySnapshot = null;
  let boundsSnapshot = null;
  let receiptToken = null;
  let togglePressed = false;
  let mapReceivedAt = 0;
  let sweepFrame = 0;
  let sweepDrawAt = 0;
  /* The last geometry used to draw, so a click can be converted back to world
   * coordinates with exactly the transform that produced the pixel the player
   * aimed at. Recomputing it at click time would drift the moment the window
   * resizes between the paint and the press. */
  let projection = null;
  let hatchClosed = null;
  let hatchClosing = null;
  /* The cell the pointer is over, in canvas pixels, so the map can say what a
   * click would hit BEFORE it is made. On a 2x2 grid every cell is four hundred
   * pixels across and the answer is obvious; on a 14x14 it is not, and a player
   * who cannot tell which block they are about to pin will pin the wrong one. */
  let hover = null;

  function num(value, fallback) {
    const n = Number(value);
    return Number.isFinite(n) ? n : (fallback === undefined ? 0 : fallback);
  }

  function text(value, limit) {
    return String(value === undefined || value === null ? "" : value).slice(0, limit || 32);
  }

  function clock(milliseconds) {
    const total = Math.max(0, Math.ceil(num(milliseconds) / 1000));
    return String(Math.floor(total / 60)).padStart(2, "0") + ":"
      + String(total % 60).padStart(2, "0");
  }

  function cssVar(name, fallback) {
    const value = getComputedStyle(document.documentElement).getPropertyValue(name).trim();
    return value || fallback;
  }

  /* --------------------------------------------------------------------- */
  /* Hatch patterns                                                        */
  /*                                                                       */
  /* Diagonal lines rather than a flat fill: a solid red block over a dark  */
  /* ground reads as "selected", and a hatch reads as "struck out", which   */
  /* is what a sealed block is. It is also the convention every real        */
  /* tactical overlay uses for denied ground.                              */
  /* --------------------------------------------------------------------- */

  function makeHatch(colour, alpha) {
    const tile = document.createElement("canvas");
    tile.width = 8;
    tile.height = 8;
    const tileContext = tile.getContext("2d");
    tileContext.strokeStyle = colour;
    tileContext.globalAlpha = alpha;
    tileContext.lineWidth = 1.5;
    tileContext.beginPath();
    tileContext.moveTo(-2, 10);
    tileContext.lineTo(10, -2);
    tileContext.moveTo(2, 14);
    tileContext.lineTo(14, 2);
    tileContext.stroke();
    return context.createPattern(tile, "repeat");
  }

  function ensurePatterns() {
    if (hatchClosed && hatchClosing) return;
    hatchClosed = makeHatch(cssVar("--cordon-closed", "#ff5c5c"), .55);
    hatchClosing = makeHatch(cssVar("--cordon-closing", "#f5c95c"), .6);
  }

  /* --------------------------------------------------------------------- */
  /* Projection                                                            */
  /* --------------------------------------------------------------------- */

  /* THE GRID CONVENTIONS ARE THE SERVER'S, AND THEY ARE LOAD-BEARING.
   * `open77_cordon/shared/grid.lua` states both in its header: "COLUMNS AND
   * ROWS ARE 1-BASED, and the origin is the CORNER of block (1,1), not its
   * centre ... Changing either invalidates every captured mark." So the base
   * defaults to 1 here, and `originX`/`originY` is the corner of the FIRST
   * block rather than of a zeroth one that does not exist.
   *
   * `indexBase` exists so that a server which ever publishes 0-based cells can
   * say so, instead of the whole map drawing one block off -- an error that
   * looks entirely plausible until somebody stands on an edge.
   *
   * Field names are read in two spellings, for the same reason the closure
   * clock is: the HUD contract says `gridCols` / `gridRows` / `blockSize`, and
   * the map table in `grid.lua` says `cols` / `rows` / `blockMetres`. Whichever
   * the server sends, the map draws. */
  function buildProjection(cordon) {
    const cols = Math.max(1, Math.trunc(num(cordon.gridCols, num(cordon.cols, 0))));
    const rows = Math.max(1, Math.trunc(num(cordon.gridRows, num(cordon.rows, 0))));
    const blockSize = Math.max(1, num(cordon.blockSize, num(cordon.blockMetres, 100)));
    const origin = cordon.origin && typeof cordon.origin === "object" ? cordon.origin : null;
    const originX = num(cordon.originX, origin ? num(origin.x) : 0);
    const originY = num(cordon.originY, origin ? num(origin.y) : 0);
    const base = Math.trunc(num(cordon.indexBase, 1));

    const pad = 26;
    const boxWidth = canvas.width - pad * 2;
    const boxHeight = canvas.height - pad * 2;

    /* Square cells, always. A grid stretched to fill the box would make a
     * 100 m block read as 140 m in one axis, and a player judging a run across
     * two blocks would be wrong by half a closure window. */
    const cell = Math.min(boxWidth / cols, boxHeight / rows);
    const width = cell * cols;
    const height = cell * rows;
    const left = pad + (boxWidth - width) / 2;
    const top = pad + (boxHeight - height) / 2;

    /* MARK SIZES SCALE WITH THE CELL, and that is not decoration -- it is the
     * whole reason this map now works at 2x2 and at 14x14 with one set of
     * drawing code. Every radius below was authored against Pacifica's 9x5,
     * where a cell is about ninety pixels; on Watson's 2x2 a cell is four
     * hundred, and a four-pixel landing dot on a four-hundred-pixel block is
     * invisible. Clamped at both ends so a large grid does not shrink its marks
     * into noise either. */
    const scale = Math.max(0.85, Math.min(2.2, cell / 90));

    return {
      cols, rows, blockSize, originX, originY, base, cell, left, top, width, height, scale,
      /* World +Y is north, and north is UP on this map -- so the row axis is
       * flipped, because canvas y grows downward. Getting this wrong mirrors
       * the whole map vertically, which looks plausible right up until a squad
       * calls out a landmark. */
      toCanvas(worldX, worldY) {
        const u = (worldX - originX) / (cols * blockSize);
        const v = (worldY - originY) / (rows * blockSize);
        return { x: left + u * width, y: top + (1 - v) * height };
      },
      toWorld(canvasX, canvasY) {
        const u = (canvasX - left) / width;
        const v = 1 - (canvasY - top) / height;
        return { x: originX + u * cols * blockSize, y: originY + v * rows * blockSize };
      },
      /* `col` and `row` arrive in the SERVER numbering; subtracting `base` is
       * the ONLY place that becomes a zero-based offset. */
      cellRect(col, row) {
        return {
          x: left + (col - base) * cell,
          y: top + (rows - 1 - (row - base)) * cell,
          w: cell,
          h: cell,
        };
      },
      cellAt(worldX, worldY) {
        return {
          col: base + Math.floor((worldX - originX) / blockSize),
          row: base + Math.floor((worldY - originY) / blockSize),
        };
      },
    };
  }

  /* BLOCK IDS ARRIVE IN TWO SPELLINGS AND BOTH ARE NORMALISED HERE.
   * `grid.lua` writes "<col>,<row>" with a COMMA, and its header explains why
   * the key is a readable string at all: "7,9 in a crash log is a block
   * somebody can walk to." The HUD contract writes its example with a colon.
   * Rather than pick one and be silently wrong against the other -- a map that
   * draws NO closed blocks because every membership test missed -- both
   * separators are accepted and everything downstream uses one canonical form.
   *
   * Cells may also arrive as a SET (`{ "3,7": true }`) rather than an array,
   * because a set is what the cordon holds internally (membership is the only
   * question it asks) and because the Lua JSON codec cannot tell an empty array
   * from an empty map. Both shapes are read. */
  const KEY_SPLIT = /[,:]/;

  function parseBlock(id) {
    const parts = String(id).split(KEY_SPLIT);
    if (parts.length < 2) return null;
    const col = Number(parts[0]);
    const row = Number(parts[1]);
    if (!Number.isFinite(col) || !Number.isFinite(row)) return null;
    return { col: Math.trunc(col), row: Math.trunc(row) };
  }

  function canonical(col, row) { return col + "," + row; }

  function blockSet(cells) {
    const ids = Array.isArray(cells) ? cells
      : (cells && typeof cells === "object"
        ? Object.keys(cells).filter(key => cells[key] !== false)
        : []);
    const set = new Set();
    for (const id of ids) {
      const cell = parseBlock(id);
      if (cell) set.add(canonical(cell.col, cell.row));
    }
    return set;
  }

  /* --------------------------------------------------------------------- */
  /* Drawing                                                               */
  /* --------------------------------------------------------------------- */

  function drawGround(p) {
    context.fillStyle = cssVar("--cordon-ground", "#04070d");
    context.fillRect(0, 0, canvas.width, canvas.height);
  }

  /* EVERY CELL IS PAINTED, INCLUDING THE OPEN ONES, and that is the change that
   * made this map readable at all.
   *
   * It used to paint sealed and closing blocks and leave open ground as bare
   * canvas, which is defensible on a 14x14 Pacifica where two hundred cells are
   * open and hatching would be a wall of red. On the 2x2 Watson test map during
   * deploy, EVERY cell is open -- `C.openKeys()` says so deliberately, "the
   * district is not sealed then; it is untouched" -- so the entire map was bare
   * canvas and read as a renderer that had drawn nothing. Reported by the owner
   * 2026-09-02: "wtf is that grid".
   *
   * `--cordon-open` is a 10% blue-gray wash chosen for exactly this: it states
   * "this is the ground you are playing on" without spending a status colour on
   * two hundred blocks, which theme.css explains at the token itself. */
  function drawBlocks(p, open, closing, finals) {
    ensurePatterns();
    /* A slow flash, phase-locked to wall time rather than to a frame counter,
     * so it does not stutter when the surface is repainting at 12 fps. */
    const flash = .55 + .45 * Math.abs(Math.sin(Date.now() / 380));
    const openFill = cssVar("--cordon-open", "rgba(174,211,224,.10)");
    const finalFill = cssVar("--cordon-final", "rgba(174,211,224,.16)");

    for (let row = p.base; row < p.base + p.rows; row += 1) {
      for (let col = p.base; col < p.base + p.cols; col += 1) {
        const id = canonical(col, row);
        const rect = p.cellRect(col, row);
        const isOpen = open.has(id);
        /* Open ground first, under everything. A final block that is still open
         * gets the brighter wash instead; a final block that has been sealed is
         * sealed, and the hatch below says so over the top of it. */
        if (isOpen) {
          context.fillStyle = finals.has(id) ? finalFill : openFill;
          context.fillRect(rect.x, rect.y, rect.w, rect.h);
        }
        if (closing.has(id)) {
          context.save();
          context.globalAlpha = flash;
          context.fillStyle = hatchClosing;
          context.fillRect(rect.x, rect.y, rect.w, rect.h);
          context.restore();
        } else if (!isOpen) {
          context.fillStyle = hatchClosed;
          context.fillRect(rect.x, rect.y, rect.w, rect.h);
        }
      }
    }

    /* Corner ticks on the final blocks. The wash alone is a 6% difference and
     * disappears under a hatch; the ticks survive both and are what actually
     * says "the last fight happens here". Drawn faint on purpose -- it is a
     * hint, and `finalBlocks` is a WHITELIST: the schedule picks one of them,
     * so promising a specific cell would be a promise the mode has not made. */
    if (finals.size === 0) return;
    const arm = Math.min(rectArm(p), p.cell * .28);
    context.strokeStyle = cssVar("--op77-text-faint", "rgba(141,153,168,.72)");
    context.lineWidth = 1.5;
    context.beginPath();
    for (const id of finals) {
      const cell = parseBlock(id);
      if (!cell) continue;
      const r = p.cellRect(cell.col, cell.row);
      for (const [cx, cy, dx, dy] of [
        [r.x, r.y, 1, 1], [r.x + r.w, r.y, -1, 1],
        [r.x, r.y + r.h, 1, -1], [r.x + r.w, r.y + r.h, -1, -1],
      ]) {
        context.moveTo(cx + dx * arm, cy);
        context.lineTo(cx, cy);
        context.lineTo(cx, cy + dy * arm);
      }
    }
    context.stroke();
  }

  function rectArm(p) { return 10 * p.scale; }

  /* THE MAJOR-LINE STEP IS DERIVED, NOT FIXED AT FIVE.
   *
   * "Every fifth line is brighter" is the right rule for a 14x14 district and
   * the wrong one for a 2x2: with two columns only line 0 satisfies `col % 5`,
   * so the left and top edges of the map drew bright and the right and bottom
   * drew faint. That asymmetry is what a broken renderer looks like, and it was
   * on screen in the owner's report.
   *
   * So: a grid small enough to count at a glance makes every line major, a
   * larger one keeps the every-five rhythm, and the OUTER FRAME is always major
   * because it is the edge of the playable survey and must never be the dimmest
   * line on the map. */
  function majorStep(count) { return count <= 6 ? 1 : 5; }

  function drawGrid(p) {
    context.lineWidth = 1;
    const major = cssVar("--cordon-grid-major", "rgba(34,216,226,.30)");
    const minor = cssVar("--cordon-grid", "rgba(34,216,226,.14)");
    const stepCols = majorStep(p.cols);
    const stepRows = majorStep(p.rows);
    for (let col = 0; col <= p.cols; col += 1) {
      context.strokeStyle = (col % stepCols === 0 || col === p.cols) ? major : minor;
      const x = Math.round(p.left + col * p.cell) + .5;
      context.beginPath();
      context.moveTo(x, p.top);
      context.lineTo(x, p.top + p.height);
      context.stroke();
    }
    for (let row = 0; row <= p.rows; row += 1) {
      context.strokeStyle = (row % stepRows === 0 || row === p.rows) ? major : minor;
      const y = Math.round(p.top + row * p.cell) + .5;
      context.beginPath();
      context.moveTo(p.left, y);
      context.lineTo(p.left + p.width, y);
      context.stroke();
    }
  }

  /* THE BLOCK KEY, written in the corner of each cell. It is the name a squad
   * says out loud ("I'm in one-two") and the name the cordon closes, and until
   * it was on the map the player had no way to connect the CORDON CLOSES IN
   * banner to any square in front of them. Suppressed on a grid whose cells are
   * too small to carry it rather than drawn illegibly. */
  function drawCellLabels(p) {
    if (p.cell < 46) return;
    context.font = "700 " + Math.round(9 * Math.min(1.5, p.scale)) +
      "px 'IBM Plex Mono', 'Cascadia Mono', Consolas, monospace";
    context.textAlign = "left";
    context.textBaseline = "top";
    context.fillStyle = cssVar("--op77-text-faint", "rgba(141,153,168,.72)");
    for (let row = p.base; row < p.base + p.rows; row += 1) {
      for (let col = p.base; col < p.base + p.cols; col += 1) {
        const rect = p.cellRect(col, row);
        context.fillText(canonical(col, row), rect.x + 5, rect.y + 4);
      }
    }
  }

  /* The cell under the pointer. Drawn before the terrain marks so it never
   * hides one, and it is the map's only answer to "is this thing clickable" --
   * a full-screen overlay whose footer says CLICK A BLOCK and which gives no
   * response to the mouse is indistinguishable from a dead surface, which is
   * exactly how this one was reported. */
  function drawHover(p, clickable) {
    if (!hover || !clickable) return;
    const rect = p.cellRect(hover.col, hover.row);
    context.save();
    context.fillStyle = cssVar("--op77-accent-soft", "rgba(34,216,226,.12)");
    context.fillRect(rect.x, rect.y, rect.w, rect.h);
    context.strokeStyle = cssVar("--op77-accent", "#22d8e2");
    context.lineWidth = 1.5;
    context.strokeRect(Math.round(rect.x) + .5, Math.round(rect.y) + .5,
                       Math.round(rect.w) - 1, Math.round(rect.h) - 1);
    context.restore();
  }

  /* THE BOUNDARY. For every open block, every edge whose neighbour is not open
   * is stroked white. That draws the exact perimeter of the open set with no
   * geometry library and no assumption that the cordon is rectangular -- which
   * matters, because the closure order is "farthest from the final block first"
   * and the open set is genuinely ragged part-way through a window. */
  function drawBoundary(p, open) {
    context.strokeStyle = cssVar("--cordon-edge", "#ffffff");
    context.lineWidth = 2.5;
    context.lineCap = "square";
    context.shadowColor = "rgba(0, 0, 0, .9)";
    context.shadowBlur = 4;
    context.beginPath();
    for (const id of open) {
      const cellId = parseBlock(id);
      if (!cellId) continue;
      const { col, row } = cellId;
      const rect = p.cellRect(col, row);
      if (!open.has(canonical(col, row + 1))) {      /* north edge, top on screen */
        context.moveTo(rect.x, rect.y);
        context.lineTo(rect.x + rect.w, rect.y);
      }
      if (!open.has(canonical(col, row - 1))) {      /* south edge, bottom */
        context.moveTo(rect.x, rect.y + rect.h);
        context.lineTo(rect.x + rect.w, rect.y + rect.h);
      }
      if (!open.has(canonical(col - 1, row))) {      /* west edge, left */
        context.moveTo(rect.x, rect.y);
        context.lineTo(rect.x, rect.y + rect.h);
      }
      if (!open.has(canonical(col + 1, row))) {      /* east edge, right */
        context.moveTo(rect.x + rect.w, rect.y);
        context.lineTo(rect.x + rect.w, rect.y + rect.h);
      }
    }
    context.stroke();
    context.shadowBlur = 0;
  }

  /* Is this world point on the drawn grid at all? Every survey mark asks, and
   * a mark half a metre outside the survey is a mark that would be painted on
   * the panel chrome. */
  function onMap(p, point) {
    return point.x >= p.left && point.x <= p.left + p.width &&
      point.y >= p.top && point.y <= p.top + p.height;
  }

  /* One label routine for every named mark, because they all face the same
   * problem: the text crosses hatch, grid and the white boundary, and it must
   * not run off the right edge of the map. */
  function label(p, point, words, colour, dy) {
    if (!words) return;
    context.fillStyle = colour;
    context.textBaseline = "middle";
    context.textAlign = point.x > p.left + p.width * .8 ? "right" : "left";
    const offset = context.textAlign === "right" ? -7 : 7;
    context.strokeStyle = "rgba(4, 7, 13, .95)";
    context.lineWidth = 3;
    context.strokeText(words, point.x + offset, point.y + (dy || 0));
    context.fillText(words, point.x + offset, point.y + (dy || 0));
  }

  function markFont(p, size) {
    return "700 " + Math.round((size || 10) * Math.min(1.4, p.scale)) +
      "px 'IBM Plex Mono', 'Cascadia Mono', Consolas, monospace";
  }

  function drawLandmarks(p, landmarks) {
    context.font = markFont(p, 10);
    for (const landmark of Array.isArray(landmarks) ? landmarks : []) {
      if (typeof landmark !== "object" || landmark === null) continue;
      const point = p.toCanvas(num(landmark.x), num(landmark.y));
      if (!onMap(p, point)) continue;

      context.fillStyle = cssVar("--op77-text-faint", "rgba(141,153,168,.72)");
      context.beginPath();
      context.arc(point.x, point.y, 2.5 * p.scale, 0, Math.PI * 2);
      context.fill();

      /* The name is the survey's, not this file's: landmark labels are data.
       * They are what lets a squad call a spot out loud, which is the whole
       * reason the plan chose a named district over an anonymous grid. */
      label(p, point, text(landmark.name, 26).toUpperCase(),
            cssVar("--op77-text-dim", "#8d99a8"));
    }
  }

  /* LANDING ZONES -- the marks the deploy phase exists for.
   *
   * This is where a pin actually goes: `cordon:pin` snaps a click to the
   * NEAREST SURVEYED LANDING ZONE (open77_cordon/server/match.lua), so a map
   * that does not draw them is asking the player to guess where their click
   * will land. Twelve of them on Watson, two marked hot.
   *
   * Drawn as a ring rather than a dot so a pin can sit inside one without
   * hiding it -- which is what happens the moment the player pins the zone they
   * are looking at. */
  function drawLandings(p, landings) {
    context.font = markFont(p, 9);
    const dim = cssVar("--cordon-landing", "#8d99a8");
    const hot = cssVar("--cordon-landing-hot", "#ff5964");
    for (const zone of Array.isArray(landings) ? landings : []) {
      if (typeof zone !== "object" || zone === null) continue;
      const point = p.toCanvas(num(zone.x), num(zone.y));
      if (!onMap(p, point)) continue;
      const isHot = zone.hot === true;
      const radius = (isHot ? 6 : 4.5) * p.scale;

      context.strokeStyle = isHot ? hot : dim;
      context.lineWidth = isHot ? 2 : 1.5;
      context.beginPath();
      context.arc(point.x, point.y, radius, 0, Math.PI * 2);
      context.stroke();
      /* A hot zone gets a second ring rather than a fill: a filled circle at
       * this size is a blob, and the whole point of "hot" is that it is
       * legible at a glance from across the panel. */
      if (isHot) {
        context.beginPath();
        context.arc(point.x, point.y, radius * .45, 0, Math.PI * 2);
        context.stroke();
      }
      label(p, point, text(zone.label, 22).toUpperCase(), isHot ? hot : dim,
            radius + 8 * p.scale);
    }
  }

  /* LOOT CLUSTER ANCHORS. Survey data -- where the map says loot belongs --
   * and NOT a live inventory of what is still on the ground: that would have to
   * ride the tick and is a different feature. The tier is carried by size, one
   * colour for all four, because nine anchors in four colours is a heat map of
   * nothing. See the token note in theme.css. */
  function drawLoot(p, clusters) {
    context.strokeStyle = cssVar("--cordon-loot", "#8d99a8");
    context.lineWidth = 1.25;
    for (const cluster of Array.isArray(clusters) ? clusters : []) {
      if (typeof cluster !== "object" || cluster === null) continue;
      const point = p.toCanvas(num(cluster.x), num(cluster.y));
      if (!onMap(p, point)) continue;
      /* Tier 1 is the common anchor and tier 4 the rare one, so size grows with
       * tier. Clamped: an unknown tier draws the smallest mark rather than a
       * NaN-sized rectangle that silently paints nothing. */
      const tier = Math.max(1, Math.min(4, Math.trunc(num(cluster.tier, 1))));
      const size = (3 + tier * .9) * p.scale;
      context.strokeRect(point.x - size, point.y - size, size * 2, size * 2);
    }
  }

  /* Supply points. The survey publishes a LIST of candidates; a live drop is
   * one of them and rides its own notice. A single object is still accepted
   * because that is the shape this function was written against. */
  function drawSupply(p, supply) {
    const points = Array.isArray(supply) ? supply
      : (supply && typeof supply === "object" ? [supply] : []);
    context.strokeStyle = cssVar("--cordon-supply", "#f5c95c");
    context.lineWidth = 2;
    for (const entry of points) {
      if (typeof entry !== "object" || entry === null) continue;
      const point = p.toCanvas(num(entry.x), num(entry.y));
      if (!onMap(p, point)) continue;
      const size = 5 * p.scale;
      context.save();
      context.translate(point.x, point.y);
      context.rotate(Math.PI / 4);
      context.strokeRect(-size, -size, size * 2, size * 2);
      context.restore();
    }
  }

  /* THE DROP PIN, and the click that has not been answered yet.
   *
   * Two marks, and the difference between them is the honest part. `pin` is the
   * server's: it has snapped the click to a landing zone and the squad is going
   * there. `pending` is the point the player pressed, held for a few seconds by
   * client/tacmap.lua, drawn dashed and unlabelled. Painting the press as a
   * confirmed pin would be a lie for as long as it took the server to refuse
   * it -- and a click that draws NOTHING until the next 500 ms push is the
   * click the owner reported as not working. */
  function drawPin(p, pin, pending) {
    const colour = cssVar("--cordon-pin", "#22d8e2");
    if (pending && typeof pending === "object") {
      const point = p.toCanvas(num(pending.x), num(pending.y));
      if (onMap(p, point)) {
        context.save();
        context.setLineDash([4, 4]);
        context.strokeStyle = colour;
        context.globalAlpha = .7;
        context.lineWidth = 1.5;
        context.beginPath();
        context.arc(point.x, point.y, 9 * p.scale, 0, Math.PI * 2);
        context.stroke();
        context.restore();
      }
    }
    if (!pin || typeof pin !== "object") return;
    const point = p.toCanvas(num(pin.x), num(pin.y));
    if (!onMap(p, point)) return;
    const arm = 11 * p.scale;

    /* A crosshair with a gap, not a dot: the pin has to be findable on top of a
     * landing ring, a loot square and the open-ground wash all at once, and a
     * cross reads through every one of them. The gap is what lets the landing
     * ring underneath stay visible -- the pin marks a zone, it does not replace
     * it. Drawn twice, dark then coloured, so it survives the white cordon
     * boundary as well as the hatch.
     *
     * The four arms and the ring are SEPARATE paths on purpose: `arc` continues
     * the current subpath, so appending it to a path that ends at the bottom of
     * the cross draws a stray line out to the circle's start. */
    const gap = arm * .35;
    context.save();
    for (const [width, style] of [[4.5, "rgba(4, 7, 13, .95)"], [2, colour]]) {
      context.lineWidth = width;
      context.strokeStyle = style;
      context.beginPath();
      context.moveTo(point.x - arm, point.y); context.lineTo(point.x - gap, point.y);
      context.moveTo(point.x + gap, point.y); context.lineTo(point.x + arm, point.y);
      context.moveTo(point.x, point.y - arm); context.lineTo(point.x, point.y - gap);
      context.moveTo(point.x, point.y + gap); context.lineTo(point.x, point.y + arm);
      context.stroke();
      context.beginPath();
      context.arc(point.x, point.y, gap, 0, Math.PI * 2);
      context.stroke();
    }
    context.restore();

    context.font = markFont(p, 10);
    label(p, point, text(pin.name, 22).toUpperCase() || text(pin.block, 8),
          colour, -(arm + 7 * p.scale));
  }

  function drawPings(p, pings) {
    for (const ping of Array.isArray(pings) ? pings : []) {
      if (typeof ping !== "object" || ping === null) continue;
      const point = p.toCanvas(num(ping.x), num(ping.y));
      const life = Math.max(0, Math.min(1, num(ping.life, 1)));
      /* Two rings, the outer one expanding as the ping ages. A ping that simply
       * faded would be invisible against the hatch by the time anyone looked. */
      context.strokeStyle = cssVar("--op77-accent-ice", "#70f3f5");
      context.globalAlpha = life;
      context.lineWidth = 2;
      context.beginPath();
      context.arc(point.x, point.y, 4, 0, Math.PI * 2);
      context.stroke();
      context.globalAlpha = life * .5;
      context.beginPath();
      context.arc(point.x, point.y, 4 + (1 - life) * 16, 0, Math.PI * 2);
      context.stroke();
      context.globalAlpha = 1;
    }
  }

  function drawSquad(p, squad) {
    const members = squad && Array.isArray(squad.members) ? squad.members : [];
    context.font = "700 10px 'IBM Plex Mono', 'Cascadia Mono', Consolas, monospace";
    context.textBaseline = "bottom";
    context.textAlign = "center";
    for (const member of members) {
      if (typeof member !== "object" || member === null) continue;
      if (member.x === undefined || member.y === undefined) continue;
      const point = p.toCanvas(num(member.x), num(member.y));
      const colour = member.alive === true ? cssVar("--cordon-up", "#4fe3a9")
        : member.downed === true ? cssVar("--cordon-down", "#f5c95c")
        : cssVar("--cordon-out", "rgba(141,153,168,.72)");

      context.fillStyle = colour;
      context.beginPath();
      context.arc(point.x, point.y, 4.5, 0, Math.PI * 2);
      context.fill();
      context.strokeStyle = "rgba(4, 7, 13, .95)";
      context.lineWidth = 1.5;
      context.stroke();

      /* Bots are labelled here too. The map is one of the three places section
       * 8.1 requires it, and a squad seat filled by a bot is exactly the case a
       * player needs to know about before they run to it expecting a revive. */
      const name = text(member.name, 14) + (member.bot === true ? " [BOT]" : "");
      context.strokeStyle = "rgba(4, 7, 13, .95)";
      context.lineWidth = 3;
      context.strokeText(name, point.x, point.y - 7);
      context.fillStyle = colour;
      context.fillText(name, point.x, point.y - 7);
    }
  }

  function drawSelf(p, marker) {
    if (!marker || typeof marker !== "object") return;
    const point = p.toCanvas(num(marker.x), num(marker.y));
    context.save();
    context.translate(point.x, point.y);
    /* `heading` is a map bearing: 0 is +Y (north, up on this projection) and it
     * grows clockwise, which is exactly what a positive canvas rotation does.
     * The triangle below is authored pointing up, so no further correction. */
    if (marker.headingKnown === true) context.rotate(num(marker.heading) * Math.PI / 180);
    context.fillStyle = cssVar("--cordon-you", "#70f3f5");
    context.strokeStyle = "rgba(4, 7, 13, .95)";
    context.lineWidth = 2;
    context.beginPath();
    context.moveTo(0, -9);
    context.lineTo(6.5, 7);
    context.lineTo(0, 3.5);
    context.lineTo(-6.5, 7);
    context.closePath();
    context.stroke();
    context.fill();
    context.restore();
  }

  /* THE GRID CAN ARRIVE ON EITHER MESSAGE, AND EITHER SPELLING.
   *
   * `C.fragment()` puts it on the 500 ms state push; `K.surveyPayload()` puts
   * it on the survey, which is sent once and is the first of the two to arrive
   * on a fresh HUD. And each of them sends `gridCols`/`gridRows` beside
   * `cols`/`rows` because the survey table and `grid.lua` disagree on the name.
   *
   * This used to test `gridCols`/`gridRows` on the cordon fragment ONLY, while
   * `buildProjection` right below it accepted all four names -- so a server
   * that published the grid under the other spelling, or on the other message,
   * drew NO SURVEY DATA over a grid it had in hand. The two are now read
   * through one merge so they cannot disagree again. */
  function drawSweptGround(p, allowed, rectangle) {
    context.save();
    context.fillStyle = "rgba(255,49,77,.25)";
    for (const key of allowed) {
      const { col, row } = parseBlock(key);
      const cell = p.cellRect(col, row);
      const safe = CordonSweepGeometry.clip(p, col, row, rectangle);
      context.beginPath();
      context.rect(cell.x, cell.y, cell.w, cell.h);
      if (safe) {
        const a = p.toCanvas(safe.minX, safe.maxY), b = p.toCanvas(safe.maxX, safe.minY);
        context.rect(a.x, a.y, b.x - a.x, b.y - a.y);
      }
      context.fill("evenodd");
    }
    context.restore();
  }

  function drawSweepBoundary(p, allowed, rectangle) {
    context.save();
    context.strokeStyle = cssVar("--cordon-edge", "#ffffff");
    context.lineWidth = 2.5;
    context.shadowColor = "rgba(0,0,0,.9)";
    context.shadowBlur = 4;
    context.beginPath();
    for (const [ax, ay, bx, by] of CordonSweepGeometry.segments(p, allowed, rectangle)) {
      const a = p.toCanvas(ax, ay), b = p.toCanvas(bx, by);
      context.moveTo(a.x, a.y); context.lineTo(b.x, b.y);
    }
    context.stroke();
    context.restore();
  }

  function animateSweep(now) {
    sweepFrame = 0;
    if (!payload || !payload.cordon || !payload.cordon.sweep || document.hidden) return;
    if (now - sweepDrawAt >= 33) { sweepDrawAt = now; draw(); }
    sweepFrame = requestAnimationFrame(animateSweep);
  }

  function gridSource() {
    const cordon = payload && payload.cordon && typeof payload.cordon === "object"
      ? payload.cordon : null;
    const survey = payload && payload.map && typeof payload.map === "object"
      ? payload.map : null;
    if (!cordon && !survey) return null;
    /* The cordon fragment LAST: it is the live one, and on the one field they
     * both carry -- the geometry -- they agree anyway. */
    const merged = Object.assign({}, survey || {}, cordon || {}, cordon && cordon.grid || {});
    const cols = num(merged.gridCols, num(merged.cols, 0));
    const rows = num(merged.gridRows, num(merged.rows, 0));
    return (cols > 0 && rows > 0) ? merged : null;
  }

  function draw() {
    const cordon = gridSource();
    $("mapNoData").hidden = Boolean(cordon);

    context.clearRect(0, 0, canvas.width, canvas.height);
    if (!cordon) {
      projection = null;
      hover = null;
      $("mapCursor").textContent = T.t("tacmap.cursorNone");
      return;
    }

    const p = buildProjection(cordon);
    projection = p;
    const survey = payload.map && typeof payload.map === "object" ? payload.map : {};

    const open = blockSet(cordon.open);
    /* Two shapes for the same fact. The HUD contract calls the blocks inside the
     * current closure window `closing` (a list); the gamemode's `C.publish()`
     * sends `nextCell`, the single cell at the head of the closure queue, because
     * its schedule closes them one at a time. Both are read and unioned, so the
     * map flashes whatever the server considers about to go -- one cell or ten. */
    const closing = blockSet(cordon.closing);
    if (cordon.nextCell !== undefined && cordon.nextCell !== null) {
      const cell = parseBlock(cordon.nextCell);
      if (cell) closing.add(canonical(cell.col, cell.row));
    }

    /* The final-block whitelist rides the SURVEY, not the cordon: it is a
     * property of the map, chosen when the map was drawn up. The cordon's own
     * `finalCell` is the single cell the schedule actually picked, and it is
     * added here so that once the cordon has armed the map stops hinting at a
     * pair and names the one. */
    const finals = blockSet(survey.finalBlocks);
    if (cordon.finalCell !== undefined && cordon.finalCell !== null) {
      const cell = parseBlock(cordon.finalCell);
      if (cell) { finals.clear(); finals.add(canonical(cell.col, cell.row)); }
    }

    const clickable = body.dataset.mode === "pin" || body.dataset.mode === "ping";

    drawGround(p);
    drawBlocks(p, open, closing, finals);
    const sweep = cordon.sweep;
    const sweepRect = sweep ? CordonSweepGeometry.rect(sweep,
      num(cordon.sweepElapsedMs) + performance.now() - mapReceivedAt) : null;
    const allowed = sweep ? blockSet(cordon.allowed) : null;
    if (sweep) drawSweptGround(p, allowed, sweepRect);
    drawGrid(p);
    drawCellLabels(p);
    drawHover(p, clickable);
    /* The boundary after the grid, before the markers: it must be the
     * brightest terrain line and it must not sit over a player. */
    if (sweep) drawSweepBoundary(p, allowed, sweepRect);
    else drawBoundary(p, open);
    /* Survey marks from least to most important, so the more important one is
     * always the one on top where two land in the same metre -- which on a
     * survey built from fourteen walked points happens constantly: Watson's
     * loot anchors, landing zones and landmarks share coordinates by design. */
    drawLoot(p, survey.lootClusters);
    drawLandings(p, survey.landings);
    drawLandmarks(p, survey.landmarks);
    drawSupply(p, survey.supply);
    drawPings(p, payload.pings);
    drawPin(p, payload.pin, payload.pendingPin);
    drawSquad(p, payload.squad);
    drawSelf(p, payload.marker);

    $("mapScale").textContent = T.fmt("tacmap.scale",
      { meters: Math.round(num(cordon.blockSize, num(cordon.blockMetres, 100))) });
    $("mapCursor").textContent = hover && clickable
      ? T.fmt("tacmap.cursor", { block: canonical(hover.col, hover.row) })
      : T.t("tacmap.cursorNone");
  }

  /* --------------------------------------------------------------------- */
  /* Chrome                                                                */
  /* --------------------------------------------------------------------- */

  function renderChrome() {
    const phase = text(payload && payload.phase, 16) || "unknown";
    const label = T.t("phase." + phase, "") || T.t("phase.unknown");
    $("mapPhaseLabel").textContent = label;
    $("mapClock").textContent = num(payload && payload.remainingMs) > 0
      ? clock(payload.remainingMs) : T.t("band.clockIdle");
    $("mapCloseKey").textContent = text(payload && payload.keyClose, 8) || "ESC";

    const mode = text(payload && payload.mode, 8) || "none";
    body.dataset.mode = mode;
    $("mapAction").textContent = mode === "pin" ? T.t("tacmap.actionPin")
      : mode === "ping" ? T.t("tacmap.actionPing") : T.t("tacmap.actionRead");
    $("mapModeHint").textContent = mode === "pin" ? T.t("tacmap.hintPin")
      : mode === "ping" ? T.t("tacmap.hintPing")
      : T.t("tacmap.hintNone");
  }

  /* Sized against the element's own box so the map fills whatever the surface
   * is, and re-sized on any change. `devicePixelRatio` is 1 on the shipped
   * 1920x1080 surface, but reading it costs nothing and a scaled surface would
   * otherwise draw a blurry grid. */
  function resize() {
    const box = canvas.parentElement.getBoundingClientRect();
    const ratio = window.devicePixelRatio || 1;
    const width = Math.max(320, Math.floor(box.width));
    const height = Math.max(240, Math.floor(box.height));
    if (canvas.width === Math.floor(width * ratio) &&
        canvas.height === Math.floor(height * ratio)) return false;
    canvas.width = Math.floor(width * ratio);
    canvas.height = Math.floor(height * ratio);
    canvas.style.width = width + "px";
    canvas.style.height = height + "px";
    /* The patterns were created against the old context state; rebuilt lazily. */
    hatchClosed = null;
    hatchClosing = null;
    return true;
  }

  window.addEventListener("resize", () => { if (resize()) draw(); });

  /* --------------------------------------------------------------------- */
  /* Input                                                                 */
  /* --------------------------------------------------------------------- */

  /* Canvas pixels for a pointer event. The canvas carries an inline pixel size
   * set by `resize()` and a CSS size to match, so the ratio is the device pixel
   * ratio -- but it is read from the two boxes rather than from
   * `devicePixelRatio`, because those are the numbers the projection was built
   * from and a click has to be converted with the transform that drew it. */
  function toCanvasPoint(event) {
    const box = canvas.getBoundingClientRect();
    if (box.width <= 0 || box.height <= 0) return null;
    return {
      x: (event.clientX - box.left) * (canvas.width / box.width),
      y: (event.clientY - box.top) * (canvas.height / box.height),
    };
  }

  /* The cell a canvas point is in, or null when the point is off the grid. */
  function cellUnder(point) {
    const p = projection;
    if (!p || !point) return null;
    if (point.x < p.left || point.x > p.left + p.width) return null;
    if (point.y < p.top || point.y > p.top + p.height) return null;
    const world = p.toWorld(point.x, point.y);
    const cell = p.cellAt(world.x, world.y);
    const last = p.base - 1;
    return {
      x: world.x,
      y: world.y,
      col: Math.min(last + p.cols, Math.max(p.base, cell.col)),
      row: Math.min(last + p.rows, Math.max(p.base, cell.row)),
    };
  }

  /* POINTERDOWN, ON THE WRAPPER, AND NOT `click` ON THE CANVAS.
   *
   * Three deliberate changes from what was here, each closing a way the press
   * could reach the page and produce nothing:
   *
   *   * `pointerdown` instead of `click`. A `click` is only dispatched when the
   *     press AND the release land on the same element; this surface is driven
   *     by a cursor the game moves from raw-input deltas, so the pointer can
   *     travel between the two messages the WebUI forwards. A map pin does not
   *     need a chord -- it needs a press.
   *   * the listener sits on `.canvas-wrap`, not on the canvas. `resize()` sets
   *     the canvas to a FLOORED pixel size inside a fractionally-sized box, so
   *     the last fraction of a pixel along the right and bottom edges belongs
   *     to the wrapper and not to the canvas. Listening on the parent means no
   *     press inside the map area can miss the handler for a rounding reason.
   *   * the primary button only. A right-click during the match must stay
   *     available to whatever else wants it.
   *
   * Outside the grid is still IGNORED rather than clamped: a pin snapped to the
   * nearest edge is a pin the player did not choose, and they would not find
   * out until they landed. The hover highlight is what makes that legible --
   * the cell lights up under the pointer, so "nothing happened" is visibly
   * "you pressed outside the survey". */
  const surface = canvas.parentElement;
  /* Chromium raises `pointerdown` and then `mousedown` for the same press, and
   * BOTH are bound: this file cannot be tested outside the game, and binding
   * only one of them would mean discovering in a live match that the chosen
   * event never arrived. This guard is what makes binding both free -- one
   * press emits once, whichever event carried it. */
  let lastPress = 0;

  function press(event) {
    if (event.button !== 0) return;
    if (event.timeStamp - lastPress < 120) return;
    if (!projection) return;
    const mode = body.dataset.mode;
    if (mode !== "pin" && mode !== "ping") return;

    const target = cellUnder(toCanvasPoint(event));
    if (!target) return;
    lastPress = event.timeStamp;
    event.preventDefault();

    /* The block is a convenience for the server log; the WORLD POINT is the
     * payload that matters, and the server resolves it against its own grid.
     * This page never decides whether the target is legal. */
    Open77.emit("cordon:click", {
      x: target.x, y: target.y, col: target.col, row: target.row,
    });
  }

  surface.addEventListener("pointerdown", press);
  surface.addEventListener("mousedown", press);

  function move(event) {
    const next = cellUnder(toCanvasPoint(event));
    const changed = (next === null) !== (hover === null) ||
      (next && hover && (next.col !== hover.col || next.row !== hover.row));
    hover = next;
    /* Repaint only when the cell actually changes. The pointer produces a
     * message per mouse sample and this surface draws a whole canvas; redrawing
     * on every sample would put a full repaint on the pointer's own rate, which
     * is the mistake the 6 fps cap on this surface exists to avoid. */
    if (changed) draw();
  }

  /* Both spellings again, and this pair carries a second job: the block readout
   * in the footer is the one thing on this surface that proves the page is
   * receiving the mouse AT ALL. If it stays on a dash while the cursor crosses
   * the map, the fault is upstream of this file -- the surface does not hold
   * cursor focus -- and no amount of drawing code will fix it. */
  surface.addEventListener("pointermove", move);
  surface.addEventListener("mousemove", move);

  function leave() {
    if (hover === null) return;
    hover = null;
    draw();
  }
  surface.addEventListener("pointerleave", leave);
  surface.addEventListener("mouseleave", leave);

  document.addEventListener("keydown", event => {
    const editable = event.target instanceof Element &&
      (event.target.closest("input,select,textarea") || event.target.isContentEditable);
    const toggle = text(payload && payload.keyToggle, 32).toUpperCase();
    if (!editable && !event.repeat && toggle && event.key.toUpperCase() === toggle) togglePressed = true;
    if (event.key === "Escape") {
      event.preventDefault();
      Open77.emit("cordon:close", {});
    }
  });
  document.addEventListener("keyup", event => {
    const editable = event.target instanceof Element &&
      (event.target.closest("input,select,textarea") || event.target.isContentEditable);
    const toggle = text(payload && payload.keyToggle, 32).toUpperCase();
    // Release capture only after the physical key is up. Closing on keydown
    // lets the Lua key mapper interpret that still-held key as a fresh opening.
    if (toggle && event.key.toUpperCase() === toggle) {
      const pressedHere = togglePressed;
      togglePressed = false;
      if (!editable && pressedHere) {
        event.preventDefault();
        Open77.emit("cordon:close", {});
      }
    }
  });

  /* --------------------------------------------------------------------- */
  /* --------------------------------------------------------------------- */
  /* The map editor                                                        */
  /* --------------------------------------------------------------------- */

  /* Every action becomes an ORDINARY `/br.map` command, submitted through the
   * same path the chat box uses. That is the security design rather than a
   * convenience: `RegisterCommand`'s third argument is the only permission gate
   * a server resource has -- nothing lets a resource ask whether a caller is an
   * admin -- so a bespoke net event would have been an unauthenticated door
   * into the editor. Going through the command path means a non-admin pressing
   * these buttons is refused exactly as if they had typed it.
   *
   * This file therefore never decides whether an action is allowed, never
   * mutates a local copy of the map, and never reports success. It composes
   * tokens and prints whatever came back. */

  const edPanel = $("mapEditor");
  const edToggle = $("mapEditToggle");
  const edArgInput = $("edArg");
  const edReplyOut = $("edReply");
  const edVehHint = $("edVehHint");

  let edKind = "loot";
  let edLootTier = "street";
  $("edLootTier").addEventListener("click", event => {
    const selected = event.target.closest("button[data-tier]");
    if (!selected) return;
    edLootTier = selected.dataset.tier;
    for (const button of $("edLootTier").querySelectorAll("button[data-tier]")) {
      button.setAttribute("aria-pressed", String(button === selected));
    }
  });
  let edOpen = false;
  let edLastSendAt = 0;

  /* ONE COMMAND PER 700 ms, and it is a disconnect guard rather than polish --
   * the same reason the click handler above has one. The server drops a session
   * that sends more than THIRTY-TWO events in a second, and a button is far
   * easier to hold down than a map click. */
  function edSend(tokens) {
    const now = Date.now();
    if (now - edLastSendAt < 700) return false;
    edLastSendAt = now;
    Open77.emit("cordon:editor", { tokens: tokens });
    return true;
  }

  function edSelectedArgs() {
    const raw = (edArgInput.value || "").trim();
    if (raw === "") return [];
    /* Split on whitespace but keep a quoted phrase together, because a landing
     * label is normally two words ("North Stalls") and /br.map quotes it. */
    const out = [];
    const re = /"([^"]*)"|(\S+)/g;
    let m;
    while ((m = re.exec(raw)) !== null) out.push(m[1] !== undefined ? m[1] : m[2]);
    return out;
  }

  function edRenderKinds() {
    const buttons = $("edKinds").querySelectorAll("button[data-kind]");
    for (const button of buttons) {
      button.setAttribute("aria-pressed", button.dataset.kind === edKind ? "true" : "false");
    }
    /* The one hint that is kind-specific, and it exists because a car hangs at
     * exactly the height it was created at -- it does not fall to the road. */
    edVehHint.hidden = edKind !== "veh";
    $("edLootTier").hidden = edKind !== "loot";
  }

  function edSetOpen(next) {
    edOpen = next === true;
    edPanel.hidden = !edOpen;
    body.dataset.editor = String(edOpen);
    edToggle.setAttribute("aria-pressed", edOpen ? "true" : "false");
    if (edOpen) edRenderKinds();
    resize();
    draw();
  }

  edToggle.addEventListener("click", () => edSetOpen(!edOpen));

  $("edKinds").addEventListener("click", event => {
    const button = event.target.closest("button[data-kind]");
    if (!button) return;
    edKind = button.dataset.kind;
    edRenderKinds();
  });

  /* `add <kind> [args]` captures the caller's own position on the SERVER. The
   * page deliberately sends no coordinates for this: the mode trusts its own
   * reading of where a body is, and a position computed here would be a second
   * opinion that can disagree. */
  $("edHere").addEventListener("click", () => {
    const args = edKind === "loot" ? [edLootTier, "1", "0"] : edSelectedArgs();
    edSend(["br.map", "add", edKind].concat(args));
  });

  /* THERE IS NO "PLACE ON THE BLOCK I CLICKED", and that is the server's shape
   * rather than an omission here. `cmdAdd` in server/editor.lua takes a kind and
   * its options and then calls `callerPosition(source)` -- the caller's own
   * position, read on the SERVER -- and accepts no coordinate of any form. Its
   * header says why: "a command carries a kind, an index, a tier and at most a
   * heading; never a place", so that the only position the mode can ever author
   * is one a body actually stood at.
   *
   * A button was written here that sent `add <kind> cell <col,row>` before that
   * was checked. The server would have refused it as an unknown option, which is
   * the good outcome; shipping a control whose command does not exist is not.
   * Placing is therefore: walk to the spot, press PLACE HERE. */

  $("edList").addEventListener("click", () => edSend(["br.map", "points", edKind]));
  $("edDelete").addEventListener("click", () => {
    const args = edSelectedArgs();
    if (args.length === 0) return;
    edSend(["br.map", "del", edKind].concat(args));
  });

  /* Per-cell ground, and it is not optional on a vertical district: Little
   * China's walkable ground runs 8.93 to 60.21 m across 44 cells, so a single
   * ground plane would place points in the air or under the floor. */
  $("edGround").addEventListener("click", () => {
    edSend(["br.map", "ground", "cell"]);
  });

  $("edNew").addEventListener("click", () => {
    const args = edSelectedArgs();
    if (args.length === 0) return;
    edSend(["br.map", "new"].concat(args));
  });
  $("edCopy").addEventListener("click", () => {
    const args = edSelectedArgs();
    if (args.length < 2) return;
    edSend(["br.map", "copy"].concat(args));
  });
  $("edSelect").addEventListener("click", () => {
    const args = edSelectedArgs();
    if (args.length === 0) return;
    if (edSend(["br.map", "select"].concat(args))) edArgInput.value = "";
  });

  /* The server's own line, verbatim. Reinterpreting it here would be a second
   * account of what happened, and the refusals are the useful half. */
  Open77.on("cordon:editor:reply", data => {
    if (!data || typeof data !== "object") return;
    edReplyOut.textContent = String(data.text || "");
  });

  /* The map header, from the same report `/br.map` prints. */
  Open77.on("cordon:editor:map", data => {
    if (!data || typeof data !== "object") return;
    $("edMapName").textContent = String(data.name || "--");
    $("edSurveyed").hidden = data.surveyed !== true;
    $("edProvisional").hidden = data.provisional !== true;
  });

  /* Bridge                                                                */
  /* --------------------------------------------------------------------- */

  Open77.on("cordon:strings", table => {
    T.set(table);
    renderChrome();
    draw();
  });

  Open77.on("cordon:map:survey", next => { surveySnapshot = next; });
  Open77.on("cordon:map:bounds", next => { boundsSnapshot = next; });
  Open77.on("cordon:map", next => {
    if (!next || typeof next !== "object") return;
    next = Object.assign({}, next, {
      map: next.map || surveySnapshot,
      cordon: next.cordon || (boundsSnapshot && Object.assign({}, boundsSnapshot, { sweepElapsedMs: num(next.sweepElapsedMs) }))
    });
    payload = next;
    mapReceivedAt = performance.now();
    if (sweepFrame === 0 && next.cordon && next.cordon.sweep) sweepFrame = requestAnimationFrame(animateSweep);
    body.dataset.ready = "true";
    /* RE-MEASURED ON EVERY PUSH, and it costs one `getBoundingClientRect` that
     * usually changes nothing. This surface is CREATED HIDDEN -- the browser is
     * told `WasHidden(true)` before the page loads -- and it is shown, not
     * resized, when the deploy window opens. So the one-shot `resize()` at the
     * bottom of this file can be the only measurement the canvas ever gets, and
     * if the wrapper had no layout at that moment the canvas stays clamped at
     * its 320x240 floor inside a box twelve hundred pixels wide, with no
     * `resize` event ever coming to correct it. Measuring here means the map is
     * right by the first frame the player sees rather than by luck. */
    resize();
    renderChrome();
    draw();
    const token = next.openToken;
    if (Number.isFinite(token) && receiptToken !== token) {
      receiptToken = token;
      togglePressed = false;
      // Diagnostic receipt only: synchronous canvas calls do not prove CEF has
      // presented a frame. Keyboard/cursor policy still waits for rendered below.
      Open77.emit("cordon:map:received", {
        openToken: token, hidden: document.hidden,
        canvasWidth: canvas.width, canvasHeight: canvas.height
      });
    }
    // Two animation frames let layout and canvas paint finish before the Lua
    // surface takes gameplay input. Old callbacks cannot focus a later opening.
    requestAnimationFrame(() => requestAnimationFrame(() => {
      if (payload && payload.openToken === token && Number.isFinite(token) && canvas.width > 0 && canvas.height > 0)
        Open77.emit("cordon:rendered", { openToken: token });
    }));
  });

  $("mapClose").addEventListener("click", () => Open77.emit("cordon:close", {}));
  resize();
  Open77.ready();
  Open77.emit("cordon:ready", {});
})();
