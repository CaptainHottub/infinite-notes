"""Stable page ownership; world coordinates are a compatibility/rendering view.

Persisted page-local records do not change when the owning page is reordered.
Legacy records stay readable until their first coordinated page transaction.
"""
from __future__ import annotations

import copy
import uuid


def page_index(stroke, pages):
    identifier = stroke.get("pageId")
    if identifier:
        return next((i for i, page in enumerate(pages) if page["id"] == identifier), None)
    index = stroke.get("pageIndex")
    if type(index) is int and 0 <= index < len(pages):
        return index
    points = stroke.get("points", [])
    if not points or not pages:
        return None
    x = (min(p["x"] for p in points) + max(p["x"] for p in points)) / 2
    y = (min(p["y"] for p in points) + max(p["y"] for p in points)) / 2
    def distance(page):
        dx = max(page.get("x", 0) - x, 0, x - page.get("x", 0) - page["width"])
        dy = max(page["y"] - y, 0, y - page["y"] - page["height"])
        return dx * dx + dy * dy
    return min(range(len(pages)), key=lambda i: distance(pages[i]))


def stable_pages(pages, *, migrate=False):
    result = copy.deepcopy(pages)
    mapping = {}
    for page in result:
        old_id = page["id"]
        identifier = str(uuid.uuid4()) if migrate else old_id
        mapping[old_id] = identifier
        page["id"] = identifier
    return result, mapping


def reflow_stroke(stroke, old_pages, new_pages, id_map=None):
    """Return a derived world view, or None if its owning page was deleted."""
    old_index = page_index(stroke, old_pages)
    if old_index is None:
        return copy.deepcopy(stroke)
    old = old_pages[old_index]
    identifier = (id_map or {}).get(old["id"], old["id"])
    new_index = next((i for i, page in enumerate(new_pages) if page["id"] == identifier), None)
    if new_index is None:
        return None
    new = new_pages[new_index]
    if (stroke.get("pageId") == identifier and stroke.get("pageIndex") == new_index
            and old.get("x", 0) == new.get("x", 0) and old["y"] == new["y"]):
        return stroke
    result = copy.deepcopy({key: value for key, value in stroke.items() if key != "points"})
    result["points"] = [dict(point) for point in stroke.get("points", [])]
    result["pageId"] = identifier
    result["pageIndex"] = new_index
    for point in result.get("points", []):
        for axis in ("x", "y"):
            local = point[axis] - old.get(axis, 0)
            raw_local = point.get(axis + "_raw", point[axis]) - old.get(axis, 0)
            point[axis + "_local"] = local
            point[axis + "_raw_local"] = raw_local
            point[axis] = local + new.get(axis, 0)
            if axis + "_raw" in point:
                point[axis + "_raw"] = raw_local + new.get(axis, 0)
    return result


def stored_stroke(stroke, pages):
    index = page_index(stroke, pages)
    if index is None:
        return copy.deepcopy(stroke)
    page = pages[index]
    result = copy.deepcopy(stroke)
    result["pageId"] = page["id"]
    result.pop("pageIndex", None)
    result["coordinateSpace"] = "page-local"
    for point in result.get("points", []):
        for axis in ("x", "y"):
            point[axis] -= page.get(axis, 0)
            if axis + "_raw" in point:
                point[axis + "_raw"] -= page.get(axis, 0)
            point.pop(axis + "_local", None)
            point.pop(axis + "_raw_local", None)
    return result


def world_stroke(stroke, pages):
    if stroke.get("coordinateSpace") != "page-local":
        return stroke
    index = page_index(stroke, pages)
    if index is None:
        raise ValueError("Stored ink refers to a missing page")
    result = copy.deepcopy(stroke)
    result.pop("coordinateSpace")
    result["pageIndex"] = index
    page = pages[index]
    for point in result.get("points", []):
        for axis in ("x", "y"):
            point[axis + "_local"] = point[axis]
            point[axis + "_raw_local"] = point.get(axis + "_raw", point[axis])
            point[axis] += page.get(axis, 0)
            if axis + "_raw" in point:
                point[axis + "_raw"] += page.get(axis, 0)
    return result
