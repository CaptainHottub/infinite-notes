/* Pure layout projection shared by the browser and regression tests. */
(function (root) {
  function reflow(strokes, oldPages, newPages, idMap = {}) {
    const oldById = new Map(oldPages.map(page => [page.id, page]));
    const nextById = new Map(newPages.map((page, index) => [page.id, { page, index }]));
    if (oldById.size !== oldPages.length || nextById.size !== newPages.length) throw new Error("Duplicate page IDs");
    const result = new Map();
    for (const [id, stroke] of strokes) {
      let old = stroke.pageId ? oldById.get(stroke.pageId) : oldPages[stroke.pageIndex];
      if (!old && !stroke.pageId && stroke.points?.length) {
        const xs = stroke.points.map(p => p.x), ys = stroke.points.map(p => p.y);
        const x = (Math.min(...xs) + Math.max(...xs)) / 2;
        const y = (Math.min(...ys) + Math.max(...ys)) / 2;
        const distance = page => {
          const dx = Math.max(page.x - x, 0, x - page.x - page.width);
          const dy = Math.max(page.y - y, 0, y - page.y - page.height);
          return dx * dx + dy * dy;
        };
        old = oldPages.reduce((best, page) => !best || distance(page) < distance(best) ? page : best, null);
      }
      if (!old) { result.set(id, stroke); continue; }
      const next = nextById.get(idMap[old.id] || old.id);
      if (!next) continue;
      const points = stroke.points.map(point => {
        const copy = { ...point };
        for (const axis of ["x", "y"]) {
          const local = point[axis] - old[axis];
          const rawLocal = (point[axis + "_raw"] ?? point[axis]) - old[axis];
          copy[axis + "_local"] = local;
          copy[axis + "_raw_local"] = rawLocal;
          copy[axis] = local + next.page[axis];
          if (axis + "_raw" in point) copy[axis + "_raw"] = rawLocal + next.page[axis];
        }
        return copy;
      });
      result.set(id, { ...stroke, pageId: next.page.id, pageIndex: next.index, points });
    }
    return result;
  }
  if (typeof module !== "undefined" && module.exports) module.exports = { reflow };
  else root.InfiniteNotesPageLayout = { reflow };
})(typeof globalThis !== "undefined" ? globalThis : this);
