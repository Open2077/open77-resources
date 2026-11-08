"""Geometry helpers for the vehicle-kit body parts (wings, lip, skirts, roof rack, bull bar).

Original geometry only, built from numbers: tubes swept along paths, rounded corners,
extruded 2D outlines and lofted sections. Everything returns vk_common.MeshBuilder so
the parts keep the shared submesh/export contract (vk_common.PartExporter).

Frame: metres, X right, Y forward, Z up (the vehicle frame).
"""
import math

import vk_common as vk

TAU = math.tau


def _sub(a, b):
    return (a[0] - b[0], a[1] - b[1], a[2] - b[2])


def _add(a, b):
    return (a[0] + b[0], a[1] + b[1], a[2] + b[2])


def _mul(a, s):
    return (a[0] * s, a[1] * s, a[2] * s)


def _dot(a, b):
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def _cross(a, b):
    return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])


def _norm(a):
    n = math.sqrt(_dot(a, a)) or 1.0
    return (a[0] / n, a[1] / n, a[2] / n)


def rounded_path(points, radius, steps=4, closed=False):
    """A polyline whose inner corners are replaced by circular arcs (fillets)."""
    pts = list(points)
    n = len(pts)
    if n < 3 or radius <= 0:
        return pts + ([pts[0]] if closed else [])
    out = []
    idx = range(n) if closed else range(1, n - 1)
    if not closed:
        out.append(pts[0])
    for i in idx:
        p0, p1, p2 = pts[i - 1], pts[i], pts[(i + 1) % n]
        d0, d1 = _norm(_sub(p0, p1)), _norm(_sub(p2, p1))
        cosang = max(-1.0, min(1.0, _dot(d0, d1)))
        ang = math.acos(cosang)
        if ang > math.pi - 1e-3 or ang < 1e-3:
            out.append(p1)
            continue
        l0 = math.dist(p0, p1) * 0.49
        l1 = math.dist(p1, p2) * 0.49
        t = min(radius / math.tan(ang / 2), l0, l1)
        a = _add(p1, _mul(d0, t))
        b = _add(p1, _mul(d1, t))
        # Quadratic Bezier through the corner: close to an arc, never self-crossing.
        for s in range(steps + 1):
            u = s / steps
            out.append(tuple(a[k] * (1 - u) ** 2 + p1[k] * 2 * u * (1 - u) + b[k] * u * u for k in range(3)))
    if closed:
        out.append(out[0])
    else:
        out.append(pts[-1])
    return out


def tube(path, radius, segments=8, cap=True, closed=False, radius_at=None):
    """A round tube swept along a 3D polyline (parallel-transport frames, no twist).

    closed=True expects path[-1] == path[0] and leaves the ends open (they weld)."""
    pts = list(path)
    if closed and math.dist(pts[0], pts[-1]) > 1e-6:
        pts.append(pts[0])
    n = len(pts)
    tangents = []
    for i in range(n):
        if closed and (i == 0 or i == n - 1):
            t = _norm(_add(_norm(_sub(pts[1], pts[0])), _norm(_sub(pts[-1], pts[-2]))))
        elif i == 0:
            t = _norm(_sub(pts[1], pts[0]))
        elif i == n - 1:
            t = _norm(_sub(pts[-1], pts[-2]))
        else:
            t = _norm(_add(_norm(_sub(pts[i], pts[i - 1])), _norm(_sub(pts[i + 1], pts[i]))))
        tangents.append(t)
    ref = (0.0, 0.0, 1.0) if abs(tangents[0][2]) < 0.9 else (1.0, 0.0, 0.0)
    normal = _norm(_cross(_cross(tangents[0], ref), tangents[0]))
    rings = []
    for i, (p, t) in enumerate(zip(pts, tangents)):
        if i:
            # Parallel transport: project the previous normal onto the new normal plane.
            normal = _norm(_sub(normal, _mul(t, _dot(normal, t))))
        binormal = _cross(t, normal)
        r = radius_at(i / (n - 1)) if radius_at else radius
        rings.append([_add(p, _add(_mul(normal, r * math.cos(TAU * j / segments)), _mul(binormal, r * math.sin(TAU * j / segments))))
                      for j in range(segments)])
    return vk.MeshBuilder().sweep(rings, closed_section=True, cap=cap and not closed)


def prism_yz(outline, x0, x1):
    """Extrude a closed Y/Z outline along X (both ends capped)."""
    return vk.MeshBuilder().sweep([[(x0, y, z) for y, z in outline], [(x1, y, z) for y, z in outline]],
                                  closed_section=True, cap=True)


def prism_xy(outline, z0, z1):
    """Extrude a closed X/Y outline along Z (both ends capped)."""
    return vk.MeshBuilder().sweep([[(x, y, z0) for x, y in outline], [(x, y, z1) for x, y in outline]],
                                  closed_section=True, cap=True)


def prism_xz(outline, y0, y1):
    """Extrude a closed X/Z outline along Y (both ends capped)."""
    return vk.MeshBuilder().sweep([[(x, y0, z) for x, z in outline], [(x, y1, z) for x, z in outline]],
                                  closed_section=True, cap=True)


def rounded_rect(w, h, r, steps=3, cx=0.0, cy=0.0):
    """Closed 2D outline of a w x h rectangle with corner radius r, counter-clockwise."""
    r = min(r, w / 2 - 1e-4, h / 2 - 1e-4)
    out = []
    for (sx, sy, a0) in ((1, 1, 0.0), (-1, 1, 90.0), (-1, -1, 180.0), (1, -1, 270.0)):
        ccx, ccy = cx + sx * (w / 2 - r), cy + sy * (h / 2 - r)
        for s in range(steps + 1):
            a = math.radians(a0 + 90.0 * s / steps)
            out.append((ccx + r * math.cos(a), ccy + r * math.sin(a)))
    return out


def ribbon_outline(path2d, width_at):
    """Closed 2D outline of a strip of varying width around an open 2D centre line."""
    n = len(path2d)
    left, right = [], []
    for i, (x, y) in enumerate(path2d):
        if i == 0:
            dx, dy = path2d[1][0] - x, path2d[1][1] - y
        elif i == n - 1:
            dx, dy = x - path2d[i - 1][0], y - path2d[i - 1][1]
        else:
            dx, dy = path2d[i + 1][0] - path2d[i - 1][0], path2d[i + 1][1] - path2d[i - 1][1]
        L = math.hypot(dx, dy) or 1.0
        nx, ny = -dy / L, dx / L
        w = width_at(i / (n - 1)) / 2
        left.append((x + nx * w, y + ny * w))
        right.append((x - nx * w, y - ny * w))
    return left + list(reversed(right))


def mirror_x(builder):
    """A copy mirrored across X = 0 (faces reversed so the winding stays outward)."""
    out = vk.MeshBuilder()
    out.verts = [(-x, y, z) for x, y, z in builder.verts]
    out.faces = [tuple(reversed(f)) for f in builder.faces]
    out.uvs = [tuple(reversed(uv)) for uv in builder.uvs]
    return out


def loft(sections, cap=True):
    """Loft closed 3D sections with the same point count (one MeshBuilder)."""
    return vk.MeshBuilder().sweep(sections, closed_section=True, cap=cap)


def bezier2(p0, p1, p2, steps):
    return [tuple(p0[k] * (1 - u) ** 2 + p1[k] * 2 * u * (1 - u) + p2[k] * u * u for k in range(len(p0)))
            for u in (s / steps for s in range(steps + 1))]


def strip_sweep(path, width, thick, closed=False, axis=(1.0, 0.0, 0.0)):
    """A flat strap (rectangular section width x thick) along a polyline whose width runs
    along `axis` (the path must stay roughly perpendicular to it)."""
    pts = list(path)
    if closed and math.dist(pts[0], pts[-1]) > 1e-6:
        pts.append(pts[0])
    n = len(pts)
    rings = []
    for i in range(n):
        a_, b_ = pts[max(0, i - 1)], pts[min(n - 1, i + 1)]
        if closed and (i == 0 or i == n - 1):
            a_, b_ = pts[-2], pts[1]
        t = _norm(_sub(b_, a_))
        nrm = _norm(_cross(axis, t))
        p = pts[i]
        hw, ht = _mul(axis, width / 2), _mul(nrm, thick / 2)
        rings.append([_add(_add(p, hw), ht), _add(_sub(p, hw), ht), _sub(_sub(p, hw), ht), _sub(_add(p, hw), ht)])
    return vk.MeshBuilder().sweep(rings, closed_section=True, cap=not closed)


def contact(direction, pts):
    """Mount contact record: part-frame points that must touch the body, resting `direction`
    (down = on a top surface, up = under a bottom surface, out = against a side, fwd = in
    front of the front face, back = behind the rear face)."""
    return {'dir': direction, 'pts': [[round(float(c), 5) for c in p] for p in pts]}


def box(lo, hi):
    """Mount embed box (part frame): a region allowed to sit inside the body."""
    return [[round(float(c), 5) for c in lo], [round(float(c), 5) for c in hi]]


def grid_pts(x0, x1, y0, y1, z, nx=3, ny=3):
    return [(x0 + (x1 - x0) * i / max(1, nx - 1), y0 + (y1 - y0) * j / max(1, ny - 1), z) for i in range(nx) for j in range(ny)]


def triangles(builder):
    return sum(len(f) - 2 for f in builder.faces)


def run_generator(kind, defaults, validate, build, slot_colors, pivot, description, styles=None):
    """Shared main() of the body-part generators (same contract as make_spoiler.py).

    build(p, lod, n) -> ({slot: MeshBuilder}, mount dict); one LOD per entry of
    p['sections'] (one by default). slot_colors: {slot: (rgb, metallic, roughness)},
    Blender stand-ins only: the cooked materials come from the spec palette.
    styles: {style: {param: default}} applied over `defaults` before the part's own params
    (p['style'] defaults to the first style)."""
    parser = vk.base_parser(description)
    args = vk.script_args(parser)
    part = vk.load_part(args.part)
    if part['kind'] != kind:
        raise SystemExit(f"this generator builds kind '{kind}', got {part['kind']!r}")
    p = dict(defaults, sections=[24])
    if styles:
        style = (part.get('params') or {}).get('style', next(iter(styles)))
        if style not in styles:
            raise SystemExit(f'style must be one of {sorted(styles)}')
        p.update(styles[style])
        p['style'] = style
    p.update(part.get('params', {}))
    validate(p)
    if not (1 <= len(p['sections']) <= 3):
        raise SystemExit('sections: one entry per LOD, 1..3 LODs')
    vk.clear_scene()
    addon = vk.enable_cp77_addon()
    mats = {slot: vk.preview_material(slot, rgb, m, r) for slot, (rgb, m, r) in slot_colors.items()}
    exp = vk.PartExporter(part, args.out)
    mount = None
    for lod, n in enumerate(p['sections'], start=1):
        slots, m = build(p, lod, int(n))
        for slot, builder in slots.items():
            if triangles(builder) > 4000:
                raise SystemExit(f'{part["id"]} {slot}: {triangles(builder)} triangles, budget 4000 per slot')
            exp.add(builder, lod, slot, mats[slot])
        mount = mount or m
    exp.export(args.exporter, addon, not args.no_blend, {
        'mount': dict({'frame': 'vehicle Base slot or root', 'pivot': pivot}, **mount), 'addon': addon})
