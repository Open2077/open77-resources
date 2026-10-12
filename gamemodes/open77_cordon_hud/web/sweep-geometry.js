/* Browser counterpart of shared/grid.lua continuous geometry. The server owns
 * the descriptor and allowed mask; this module only interpolates its timeline. */
(() => {
  "use strict";
  function rect(sweep, elapsedMs) {
    if (!sweep || !sweep.from) return null;
    const t = Math.max(0, Math.min(1, (elapsedMs - (sweep.startsInMs || 0)) / Math.max(1, sweep.durationMs || 1)));
    if (sweep.terminal && t >= 1) return null;
    const a = sweep.from, b = sweep.terminal ? a : (sweep.to || a), result = {};
    for (const key of ["minX", "minY", "maxX", "maxY"]) result[key] = a[key] + (b[key] - a[key]) * t;
    return result;
  }
  function clip(grid, col, row, rectangle) {
    if (!rectangle || col < 1 || row < 1 || col > grid.cols || row > grid.rows) return null;
    const x = grid.originX + (col - 1) * grid.blockSize, y = grid.originY + (row - 1) * grid.blockSize;
    const box = { minX: Math.max(x, rectangle.minX), minY: Math.max(y, rectangle.minY),
      maxX: Math.min(x + grid.blockSize, rectangle.maxX), maxY: Math.min(y + grid.blockSize, rectangle.maxY) };
    return box.minX < box.maxX && box.minY < box.maxY ? box : null;
  }
  function segments(grid, allowed, rectangle) {
    const result = [];
    const neighbour = (col, row) => allowed.has(`${col},${row}`) && clip(grid, col, row, rectangle);
    for (const key of allowed) {
      const [col, row] = key.split(",").map(Number), b = clip(grid, col, row, rectangle);
      if (!b) continue;
      if (!neighbour(col - 1, row)) result.push([b.minX, b.minY, b.minX, b.maxY]);
      if (!neighbour(col + 1, row)) result.push([b.maxX, b.minY, b.maxX, b.maxY]);
      if (!neighbour(col, row - 1)) result.push([b.minX, b.minY, b.maxX, b.minY]);
      if (!neighbour(col, row + 1)) result.push([b.minX, b.maxY, b.maxX, b.maxY]);
    }
    return result;
  }
  globalThis.CordonSweepGeometry = { rect, clip, segments };
})();
