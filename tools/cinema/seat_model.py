"""Procedural premium lounge seat for the VR IMAX auditorium.

Blender (Z up, metres). Origin = floor under the seat centre line, seat faces +Y.
Every part is a parametric surface sampled per LOD; UVs come from the surface
parameters (or a fixed planar projection for caps) packed into one atlas whose
layout is derived from LOD 0, so LOD 0 and LOD 1 share the same texture.

    import seat_model
    seat_model.bake_seat_texture(path, 2048)
    obj = seat_model.build_seat("Seat", lod=0)
"""

import math
import os
import time

import bmesh
import bpy
from mathutils import Vector

MATERIAL_NAME = "CinemaSeat"
UV_NAME = "UVMap"
SEAT_PITCH = 0.80  # row spacing used for neighbour occlusion in the bake

# Surface zones (only used while baking).
FABRIC, SHELL, PAD, METAL, CUP, LEG = range(6)
ZONE_NAMES = ("fabric", "shell", "pad", "metal", "cup", "leg")


def _srgb(hex_value):
    def lin(c):
        c /= 255.0
        return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
    return tuple(lin(int(hex_value[i:i + 2], 16)) for i in (0, 2, 4))


# --------------------------------------------------------------------------
# Part generation (pure python, no bpy data)

class _Part:
    """One UV chart: vertices, faces, per-corner raw UVs and per-face zones."""

    def __init__(self, key, weight=1.0):
        self.key = key
        self.weight = weight
        self.verts = []
        self.faces = []      # tuples of vertex indices
        self.uvs = []        # per face: list of raw (u, v)
        self.zones = []
        self.bounds = None   # raw uv bounds (u0, v0, u1, v1) or None for [0,1]
        self.size = (1.0, 1.0)  # physical extent in metres for packing

    def orient(self, mode, ref):
        """Flips the whole part so faces point out of (or into / along) `ref`."""
        score = 0.0
        for face in self.faces:
            pts = [self.verts[i] for i in face]
            n = _newell(pts)
            c = sum(pts, Vector()) / len(pts)
            if mode == "dir":
                score += n.dot(ref)
            else:
                score += n.dot(c - ref) * (1 if mode == "out" else -1)
        if score < 0:
            self.faces = [tuple(reversed(f)) for f in self.faces]
            self.uvs = [list(reversed(u)) for u in self.uvs]


def _newell(pts):
    n = Vector((0.0, 0.0, 0.0))
    for i, a in enumerate(pts):
        b = pts[(i + 1) % len(pts)]
        n.x += (a.y - b.y) * (a.z + b.z)
        n.y += (a.z - b.z) * (a.x + b.x)
        n.z += (a.x - b.x) * (a.y + b.y)
    return n


def _grid(key, rings, ring_params, sweep_params, closed, seg_zones, weight=1.0):
    """Sweeps `rings` (list of point lists). Ring params run 0..1 around the ring
    (len = points + 1 when closed), sweep params 0..1 along the sweep."""
    part = _Part(key, weight)
    n = len(rings[0])
    for ring in rings:
        assert len(ring) == n
        part.verts.extend(ring)
    segs = n if closed else n - 1
    for r in range(len(rings) - 1):
        for c in range(segs):
            c2 = (c + 1) % n
            part.faces.append((r * n + c, r * n + c2, (r + 1) * n + c2, (r + 1) * n + c))
            u0, u1 = ring_params[c], ring_params[c + 1]
            v0, v1 = sweep_params[r], sweep_params[r + 1]
            part.uvs.append([(u0, v0), (u1, v0), (u1, v1), (u0, v1)])
            part.zones.append(seg_zones[c])
    return part


def _loop_length(pts, closed=True):
    total = 0.0
    for i in range(len(pts) - (0 if closed else 1)):
        total += (pts[(i + 1) % len(pts)] - pts[i]).length
    return total


def _arc_params(pts, closed=True):
    acc = [0.0]
    for i in range(len(pts) - (0 if closed else 1)):
        acc.append(acc[-1] + (pts[(i + 1) % len(pts)] - pts[i]).length)
    return [a / acc[-1] for a in acc]


def _planar(key, loops, axes, zones, weight=1.0, extra_faces=()):
    """Polygon caps projected on two axes. `loops` is a list of point loops (each
    becomes one n-gon); `extra_faces` are (points, zone) quads sharing the chart."""
    part = _Part(key, weight)
    a, b = axes
    for loop, zone in list(zip(loops, zones)) + list(extra_faces):
        base = len(part.verts)
        part.verts.extend(loop)
        part.faces.append(tuple(range(base, base + len(loop))))
        part.uvs.append([(p.dot(a), p.dot(b)) for p in loop])
        part.zones.append(zone)
    us = [uv[0] for f in part.uvs for uv in f]
    vs = [uv[1] for f in part.uvs for uv in f]
    part.bounds = (min(us), min(vs), max(us), max(vs))
    part.size = (part.bounds[2] - part.bounds[0], part.bounds[3] - part.bounds[1])
    return part


# ---- Backrest -------------------------------------------------------------

RECLINE = math.radians(12.0)
BACK_FRONT_Y = -0.175     # cushion front y at z = 0.46
BACK_REAR_LIMIT = -0.374
BACK_TOP_Z = 1.068
ARC = 0.040               # front-view curvature of the headrest top

# name, x, a, b : depth offset d = a - b * depth (0 = cushion front, negative = back)
BACK_HALF = [
    ("c", 0.000, 0.006, 0.00),
    ("g1", 0.068, -0.017, 0.00),
    ("p1", 0.112, 0.005, 0.00),
    ("g2", 0.156, -0.017, 0.00),
    ("p2", 0.196, 0.006, 0.00),
    ("g3", 0.232, -0.015, 0.00),
    ("b", 0.263, 0.030, 0.00),
    ("k", 0.291, 0.000, 0.10),
    ("s", 0.303, 0.000, 0.30),
    ("lip", 0.317, 0.002, 0.32),
    ("sh", 0.323, 0.000, 0.60),
    ("rc", 0.308, 0.000, 0.84),
    ("rk", 0.250, -0.002, 0.965),
    ("rm", 0.130, -0.005, 0.995),
    ("rear", 0.000, -0.006, 1.00),
]
BACK_FRONT_NAMES = {"c", "g1", "p1", "g2", "p2", "g3", "b"}
# Zone of the segment leaving each half point towards the rear.
BACK_SEG_ZONE = {n: FABRIC for n in ("c", "g1", "p1", "g2", "p2", "g3", "b", "k")}
BACK_SEG_ZONE.update({n: SHELL for n in ("s", "lip", "sh", "rc", "rk", "rm")})

# name, z, front bulge, x scale, top compression, arc weight, depth
BACK_ROWS = [
    ("r0", 0.360, 0.000, 0.950, 1.00, 0.00, 0.120),
    ("r1", 0.448, 0.004, 0.985, 1.00, 0.00, 0.140),
    ("r2", 0.560, 0.022, 1.000, 1.00, 0.00, 0.152),
    ("r3", 0.680, 0.012, 1.000, 1.00, 0.00, 0.152),
    ("r4", 0.790, 0.004, 1.000, 1.00, 0.00, 0.142),
    ("r5", 0.852, -0.012, 1.000, 1.00, 0.10, 0.097),   # headrest seam; trim recess on the rear
    ("r6", 0.900, 0.016, 1.000, 1.00, 0.30, 0.136),    # headrest pad
    ("r7", 0.980, 0.020, 1.000, 1.00, 0.60, 0.122),
    ("r8", 1.035, 0.008, 0.995, 0.86, 0.85, 0.104),
    ("r9", BACK_TOP_Z, 0.000, 0.950, 0.42, 1.00, 0.092),
]
BACK_LOD = {
    0: ([h[0] for h in BACK_HALF], [r[0] for r in BACK_ROWS]),
    1: (["c", "p2", "b", "s", "sh", "rk", "rear"], ["r0", "r2", "r4", "r6", "r8", "r9"]),
}


def _back_front_y(z):
    return BACK_FRONT_Y - (z - 0.46) * math.tan(RECLINE)


def _back_depth(z, depth):
    return min(depth, _back_front_y(z) - BACK_REAR_LIMIT - 0.006)


def _back_loop_names(half_names):
    """Full loop order starting at the right cushion side so the UV seam sits on the side."""
    right = [n for n in half_names]                       # front centre -> rear centre (x >= 0)
    left = [n for n in reversed(half_names[1:-1])]        # rear -> front on the left (x < 0)
    loop = [(n, 1) for n in right] + [(n, -1) for n in left]
    start = next(i for i, (n, s) in enumerate(loop) if n in ("sh", "s") and s == 1)
    return loop[start:] + loop[:start]


def _back_point(name, side, row):
    _, z, bulge, xs, squash, arc_w, depth = row
    _, x, a, b = {h[0]: h for h in BACK_HALF}[name]
    depth = _back_depth(z, depth)
    d = a - b * depth
    if name in BACK_FRONT_NAMES:
        d += bulge
    mid = -0.5 * depth
    d = mid + (d - mid) * squash
    x *= xs * side
    zz = z - ARC * (x / 0.30) ** 2 * arc_w
    return Vector((x, _back_front_y(z) + d, zz))


def _backrest(lod):
    names, rows = BACK_LOD[lod]
    rows = [r for r in BACK_ROWS if r[0] in rows]
    loop = _back_loop_names(names)
    ref_loop = _back_loop_names(BACK_LOD[0][0])
    ref_pts = [_back_point(n, s, BACK_ROWS[3]) for n, s in ref_loop]
    param_of = dict(zip(ref_loop, _arc_params(ref_pts)))
    ring_params = [param_of[key] for key in loop] + [1.0]
    ref_rings = [[_back_point(n, s, row) for n, s in ref_loop] for row in BACK_ROWS]
    centre_line = [_back_point("c", 1, row) for row in BACK_ROWS]
    acc = [0.0]
    for i in range(len(centre_line) - 1):
        acc.append(acc[-1] + (centre_line[i + 1] - centre_line[i]).length)
    row_param = {row[0]: acc[i] / acc[-1] for i, row in enumerate(BACK_ROWS)}
    sweep_params = [row_param[r[0]] for r in rows]
    rings = [[_back_point(n, s, row) for n, s in loop] for row in rows]
    order = [h[0] for h in BACK_HALF]
    zones = []
    for i, (n, _) in enumerate(loop):
        m = loop[(i + 1) % len(loop)][0]
        zones.append(BACK_SEG_ZONE[order[min(order.index(n), order.index(m))]])
    part = _grid("back", rings, ring_params, sweep_params, True, zones, weight=1.3)
    part.size = (sum(_loop_length(r) for r in ref_rings) / len(ref_rings), acc[-1])
    part.orient("out", Vector((0.0, _back_front_y(0.70) - 0.07, 0.70)))
    top = _planar("back_top", [rings[-1]], (Vector((1, 0, 0)), Vector((0, 1, 0))), [SHELL], weight=1.0)
    ref = _planar("back_top", [ref_rings[-1]], (Vector((1, 0, 0)), Vector((0, 1, 0))), [SHELL])
    top.bounds, top.size = ref.bounds, ref.size
    top.orient("dir", Vector((0, 0, 1)))
    return [part, top]


# ---- Seat cushion -----------------------------------------------------------

SEAT_PROFILE = [  # name, y, z, zone of segment to next, crowned top
    ("B1", -0.100, 0.325, SHELL, False),
    ("R0", -0.205, 0.360, FABRIC, False),
    ("R1", -0.210, 0.410, FABRIC, False),
    ("T0", -0.190, 0.438, FABRIC, True),
    ("T1", -0.020, 0.458, FABRIC, True),
    ("T2", 0.170, 0.466, FABRIC, True),
    ("T3", 0.310, 0.462, FABRIC, True),
    ("F0", 0.364, 0.450, FABRIC, True),
    ("F1", 0.397, 0.426, FABRIC, False),
    ("F2", 0.408, 0.393, FABRIC, False),
    ("F3", 0.398, 0.361, FABRIC, False),
    ("F4", 0.370, 0.343, SHELL, False),
    ("P0", 0.340, 0.330, SHELL, False),
    ("P1", 0.250, 0.318, SHELL, False),
]
SEAT_HALF_X = 0.275
SEAT_STATIONS = [  # name, x, ring shrink
    ("e0", -0.275, 0.80),
    ("m0", -0.268, 0.95),
    ("s0", -0.252, 1.00),
    ("c", 0.000, 1.00),
    ("s1", 0.252, 1.00),
    ("m1", 0.268, 0.95),
    ("e1", 0.275, 0.80),
]
SEAT_LOD = {
    0: ([p[0] for p in SEAT_PROFILE], [s[0] for s in SEAT_STATIONS]),
    1: (["B1", "R1", "T0", "T2", "F0", "F2", "F4", "P1"], ["e0", "c", "e1"]),
}
SEAT_CENTRE = Vector((0.0, 0.10, 0.395))


def _seat_point(prof, station):
    _, y, z, _, crowned = prof
    _, x, shrink = station
    p = Vector((x, y, z))
    if crowned:
        p.z -= 0.012 * (x / 0.26) ** 2
    if shrink != 1.0:
        q = SEAT_CENTRE + (Vector((0.0, p.y, p.z)) - SEAT_CENTRE) * shrink
        p = Vector((x, q.y, q.z))
    return p


def _seat(lod):
    pnames, snames = SEAT_LOD[lod]
    prof = [p for p in SEAT_PROFILE if p[0] in pnames]
    stations = [s for s in SEAT_STATIONS if s[0] in snames]
    ref_pts = [Vector((0, p[1], p[2])) for p in SEAT_PROFILE]
    ref_params = dict(zip([p[0] for p in SEAT_PROFILE], _arc_params(ref_pts)))
    ring_params = [ref_params[p[0]] for p in prof] + [1.0]
    sweep_params = [(s[1] + SEAT_HALF_X) / (2 * SEAT_HALF_X) for s in stations]
    rings = [[_seat_point(p, s) for p in prof] for s in stations]
    zones = [p[3] for p in prof]
    part = _grid("seat", rings, ring_params, sweep_params, True, zones, weight=1.15)
    part.size = (_loop_length(ref_pts), 2 * SEAT_HALF_X)
    part.orient("out", SEAT_CENTRE)
    parts = [part]
    axes = (Vector((0, 1, 0)), Vector((0, 0, 1)))
    for key, ring, stn, sign in (("seat_cap_l", rings[0], SEAT_STATIONS[0], -1),
                                 ("seat_cap_r", rings[-1], SEAT_STATIONS[-1], 1)):
        cap = _planar(key, [ring], axes, [FABRIC], weight=0.8)
        ref = _planar(key, [[_seat_point(p, stn) for p in SEAT_PROFILE]], axes, [FABRIC])
        cap.bounds, cap.size = ref.bounds, ref.size
        cap.orient("dir", Vector((sign, 0, 0)))
        parts.append(cap)
    return parts


# ---- Armrest: leather pad, cup holder pod and side standard ----------------

ARM_X = 0.330
PAD_RING = [  # name, dx, z, zone of next segment
    ("bl", -0.040, 0.605, SHELL),
    ("br", 0.040, 0.605, PAD),
    ("rs", 0.045, 0.628, PAD),
    ("rr", 0.041, 0.650, PAD),
    ("rt", 0.024, 0.660, PAD),
    ("t", 0.000, 0.6625, PAD),
    ("lt", -0.024, 0.660, PAD),
    ("lr", -0.041, 0.650, PAD),
    ("ls", -0.045, 0.628, PAD),
]
PAD_ZC = 0.632
PAD_STATIONS = [  # name, y, width scale, ring shrink, dz
    ("pb", -0.272, 1.00, 0.70, 0.0),
    ("p0", -0.256, 1.00, 1.00, 0.0),
    ("p1", 0.020, 1.00, 1.00, 0.0),
    ("p2", 0.240, 1.00, 1.00, 0.0),
    ("pf", 0.322, 0.92, 1.00, -0.006),
]
PAD_LOD = {0: ([r[0] for r in PAD_RING], [s[0] for s in PAD_STATIONS]),
           1: (["bl", "br", "rt", "lt"], ["p0", "pf"])}

POD_Y = 0.356
POD_A, POD_B = 0.046, 0.050     # superellipse half sizes (x, y)
POD_N = 12
POD_BASE_Z, POD_WALL_Z, POD_TOP_Z = 0.600, 0.656, 0.666
POD_ROLL = 0.86                 # inset of the rolled top edge
POD_RIM_R = 0.0345              # thin dim metal rim between RIM_R and HOLE_R
POD_HOLE_R, POD_FLOOR_R, POD_FLOOR_Z = 0.031, 0.028, 0.614
POD_LOD = {0: list(range(POD_N)), 1: [0, 3, 6, 9]}

LEG_RINGS = [  # z, y back, y front, half thickness
    (0.000, -0.285, 0.270, 0.026),
    (0.300, -0.235, 0.215, 0.022),
    (0.606, -0.255, 0.245, 0.024),
]
LEG_POINTS = ["bo_", "bo", "fo", "fo_", "fi_", "fi", "bi", "bi_"]
LEG_LOD = {0: (LEG_POINTS, [0, 1, 2]), 1: (["bo", "fo", "fi", "bi"], [0, 2])}


def _mirror(p, side):
    return Vector((p.x * side, p.y, p.z))


def _pad(lod, side, tag):
    rnames, snames = PAD_LOD[lod]
    ring = [r for r in PAD_RING if r[0] in rnames]
    stations = [s for s in PAD_STATIONS if s[0] in snames]

    def point(r, s):
        _, dx, z, _ = r
        _, y, ws, shrink, dz = s
        zz = PAD_ZC + (z - PAD_ZC) * shrink - (1 - shrink) * 0.012 + dz
        return _mirror(Vector((ARM_X + dx * ws * shrink, y, zz)), side)

    ref_ring = [Vector((r[1], 0, r[2])) for r in PAD_RING]
    params = dict(zip([r[0] for r in PAD_RING], _arc_params(ref_ring)))
    ring_params = [params[r[0]] for r in ring] + [1.0]
    y0, y1 = PAD_STATIONS[0][1], PAD_STATIONS[-1][1]
    sweep_params = [(s[1] - y0) / (y1 - y0) for s in stations]
    rings = [[point(r, s) for r in ring] for s in stations]
    zones = [r[3] for r in ring]
    part = _grid("pad_" + tag, rings, ring_params, sweep_params, True, zones, weight=1.15)
    part.size = (_loop_length(ref_ring), y1 - y0)
    part.orient("out", _mirror(Vector((ARM_X, 0.0, PAD_ZC)), side))
    parts = [part]
    axes = (Vector((1, 0, 0)), Vector((0, 0, 1)))
    for key, loop, stn, sign in (("padb_" + tag, rings[0], PAD_STATIONS[0], -1),
                                 ("padf_" + tag, rings[-1], PAD_STATIONS[-1], 1)):
        cap = _planar(key, [loop], axes, [PAD], weight=0.5)
        ref = _planar(key, [[point(r, stn) for r in PAD_RING]], axes, [PAD])
        cap.bounds, cap.size = ref.bounds, ref.size
        cap.orient("dir", Vector((0, sign, 0)))
        parts.append(cap)
    return parts


def _pod_ring(ids, z, cx, scale=1.0, radius=None):
    pts = []
    for k in ids:
        t = math.radians(45.0) + 2.0 * math.pi * k / POD_N
        c, s = math.cos(t), math.sin(t)
        if radius is None:
            x = POD_A * scale * math.copysign(abs(c) ** 0.5, c)
            y = POD_B * scale * math.copysign(abs(s) ** 0.5, s)
        else:
            x, y = radius * c, radius * s
        pts.append(Vector((cx + x, POD_Y + y, z)))
    return pts


def _fix_up(part, sign):
    """Orients every face of a planar chart individually towards +/-Z."""
    faces, uvs = [], []
    for face, uv in zip(part.faces, part.uvs):
        if _newell([part.verts[i] for i in face]).z * sign < 0:
            face, uv = tuple(reversed(face)), list(reversed(uv))
        faces.append(face)
        uvs.append(uv)
    part.faces, part.uvs = faces, uvs


def _pod(lod, side, tag):
    ids = POD_LOD[lod]
    n = len(ids)
    cx = ARM_X * side
    base = _pod_ring(ids, POD_BASE_Z, cx, 0.96)
    wall = _pod_ring(ids, POD_WALL_Z, cx)
    params = [k / POD_N for k in ids] + [1.0]
    outer = _grid("pod_out_" + tag, [base, wall], params, [0.0, 1.0], True, [PAD] * n, weight=0.9)
    outer.size = (2.0 * math.pi * 0.5 * (POD_A + POD_B), POD_WALL_Z - POD_BASE_Z)
    centre = Vector((cx, POD_Y, 0.63))
    outer.orient("out", centre)
    axes = (Vector((1, 0, 0)), Vector((0, 1, 0)))
    bounds = (cx - POD_A, POD_Y - POD_B, cx + POD_A, POD_Y + POD_B)
    bottom = _planar("pod_bot_" + tag, [base], axes, [SHELL], weight=0.4)
    bottom.bounds, bottom.size = bounds, (2 * POD_A, 2 * POD_B)
    _fix_up(bottom, -1)
    parts = [outer, bottom]
    if lod == 0:
        roll = _pod_ring(ids, POD_TOP_Z, cx, POD_ROLL)
        rim = _pod_ring(ids, POD_TOP_Z, cx, radius=POD_RIM_R)
        hole = _pod_ring(ids, POD_TOP_Z - 0.002, cx, radius=POD_HOLE_R)
        floor = _pod_ring(ids, POD_FLOOR_Z, cx, radius=POD_FLOOR_R)
        quads = [([wall[i], wall[(i + 1) % n], roll[(i + 1) % n], roll[i]], PAD) for i in range(n)]
        quads += [([roll[i], roll[(i + 1) % n], rim[(i + 1) % n], rim[i]], PAD) for i in range(n)]
        quads += [([rim[i], rim[(i + 1) % n], hole[(i + 1) % n], hole[i]], METAL) for i in range(n)]
        top = _planar("pod_top_" + tag, [floor], axes, [CUP], weight=1.0, extra_faces=quads)
        inner = _grid("pod_in_" + tag, [hole, floor], params, [0.0, 1.0], True, [CUP] * n, weight=0.5)
        inner.size = (2 * math.pi * POD_HOLE_R, POD_TOP_Z - POD_FLOOR_Z)
        inner.orient("in", centre)
        parts.append(inner)
    else:
        top = _planar("pod_top_" + tag, [wall], axes, [PAD], weight=1.0)
    _fix_up(top, 1)
    top.bounds, top.size = bounds, (2 * POD_A, 2 * POD_B)
    parts.append(top)
    return parts


def _leg_point(name, spec):
    z, yb, yf, t = spec
    r = 0.028
    table = {"bo_": (0.55 * t, yb), "bo": (t, yb + r), "fo": (t, yf - r), "fo_": (0.55 * t, yf),
             "fi_": (-0.55 * t, yf), "fi": (-t, yf - r), "bi": (-t, yb + r), "bi_": (-0.55 * t, yb)}
    dx, y = table[name]
    return Vector((ARM_X + dx, y, z))


def _leg(lod, side, tag):
    pnames, ring_ids = LEG_LOD[lod]
    ref = [_leg_point(n, LEG_RINGS[-1]) for n in LEG_POINTS]
    params_all = dict(zip(LEG_POINTS, _arc_params(ref)))
    rings = [[_mirror(_leg_point(n, LEG_RINGS[i]), side) for n in pnames] for i in ring_ids]
    ring_params = [params_all[n] for n in pnames] + [1.0]
    sweep = [LEG_RINGS[i][0] / LEG_RINGS[-1][0] for i in ring_ids]
    part = _grid("leg_" + tag, rings, ring_params, sweep, True, [LEG] * len(pnames), weight=0.7)
    part.size = (_loop_length(ref), LEG_RINGS[-1][0])
    part.orient("out", _mirror(Vector((ARM_X, 0.0, 0.3)), side))
    return [part]


def _beam():
    """Pivot tube carrying the seat between the standards (mostly hidden)."""
    rings = [[Vector((x, y, z)) for y, z in ((0.015, 0.335), (0.045, 0.335), (0.045, 0.365), (0.015, 0.365))]
             for x in (-0.31, 0.31)]
    part = _grid("beam", rings, [0.0, 0.25, 0.5, 0.75, 1.0], [0.0, 1.0], True, [LEG] * 4, weight=0.3)
    part.size = (0.12, 0.62)
    part.orient("out", Vector((0, 0.03, 0.35)))
    return [part]


def _parts(lod):
    parts = _backrest(lod) + _seat(lod)
    for side, tag in ((1, "r"), (-1, "l")):
        parts += _pad(lod, side, tag) + _pod(lod, side, tag) + _leg(lod, side, tag)
    if lod == 0:
        parts += _beam()
    return parts


# --------------------------------------------------------------------------
# UV atlas layout (derived from LOD 0, shared by all LODs)

_LAYOUT = None
UV_PADDING = 0.010


def _shelf_pack(items, scale):
    """items: (key, w, h, rotated) metres, in placement order. Returns {key: (x, y, w, h, rotated)} or None."""
    rects = {}
    x = y = shelf_h = 0.0
    for key, w, h, rot in items:
        rw, rh = w * scale, h * scale
        if rw + UV_PADDING > 1.0:
            return None
        if x + rw + UV_PADDING > 1.0:
            y += shelf_h
            x, shelf_h = 0.0, 0.0
        rects[key] = (x + UV_PADDING * 0.5, y + UV_PADDING * 0.5, rw, rh, rot)
        x += rw + UV_PADDING
        shelf_h = max(shelf_h, rh + UV_PADDING)
    return rects if y + shelf_h <= 1.0 else None


def _layout():
    """Packs the LOD 0 charts once; tries a few rotation policies and keeps the densest."""
    global _LAYOUT
    if _LAYOUT is None:
        parts = _parts(0)
        best_scale, best = 0.0, None
        for policy in ("none", "landscape", "portrait"):
            items = []
            for p in parts:
                w, h = p.size[0] * p.weight, p.size[1] * p.weight
                rot = (policy == "landscape" and h > w) or (policy == "portrait" and w > h)
                items.append((p.key, h if rot else w, w if rot else h, rot))
            for order in (lambda it: (-it[2], -it[1]), lambda it: -it[1] * it[2], lambda it: -it[1]):
                ordered = sorted(items, key=order)
                lo, hi, found = 0.1, 10.0, None
                for _ in range(40):
                    mid = (lo + hi) * 0.5
                    rects = _shelf_pack(ordered, mid)
                    if rects:
                        lo, found = mid, rects
                    else:
                        hi = mid
                if found and lo > best_scale:
                    best_scale, best = lo, found
        _LAYOUT = ({p.key: p.bounds for p in parts}, best)
    return _LAYOUT


# --------------------------------------------------------------------------
# Blender objects

def seat_material(texture_path=None):
    """Returns the shared 'CinemaSeat' material (created once, reused)."""
    mat = bpy.data.materials.get(MATERIAL_NAME)
    if mat is None:
        mat = bpy.data.materials.new(MATERIAL_NAME)
        mat.use_nodes = True
        bsdf = mat.node_tree.nodes.get("Principled BSDF")
        if bsdf:
            bsdf.inputs["Base Color"].default_value = (*_srgb("631d28"), 1.0)
            bsdf.inputs["Roughness"].default_value = 0.8
        mat.diffuse_color = (*_srgb("631d28"), 1.0)
    if texture_path:
        nodes, links = mat.node_tree.nodes, mat.node_tree.links
        bsdf = nodes.get("Principled BSDF")
        tex = nodes.get("SeatTexture") or nodes.new("ShaderNodeTexImage")
        tex.name = "SeatTexture"
        tex.image = bpy.data.images.load(texture_path, check_existing=True)
        if bsdf:
            links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
        nodes.active = tex
    return mat


def _make_mesh(name, lod, zones=False):
    bounds, rects = _layout()
    parts = _parts(lod)
    bm = bmesh.new()
    uv_layer = bm.loops.layers.uv.new(UV_NAME)
    zone_layer = bm.faces.layers.int.new("seat_zone") if zones else None
    for part in parts:
        rx, ry, rw, rh, rot = rects[part.key]
        b = bounds[part.key] or (0.0, 0.0, 1.0, 1.0)
        bw, bh = max(b[2] - b[0], 1e-9), max(b[3] - b[1], 1e-9)
        verts = [bm.verts.new(v) for v in part.verts]
        for face, uvs, zone in zip(part.faces, part.uvs, part.zones):
            f = bm.faces.new([verts[i] for i in face])
            f.smooth = True
            for loop, (u, v) in zip(f.loops, uvs):
                u = min(max((u - b[0]) / bw, 0.0), 1.0)
                v = min(max((v - b[1]) / bh, 0.0), 1.0)
                loop[uv_layer].uv = (rx + v * rw, ry + u * rh) if rot else (rx + u * rw, ry + v * rh)
            if zone_layer:
                f[zone_layer] = zone
    ngons = [f for f in bm.faces if len(f.verts) > 4]
    if ngons:
        bmesh.ops.triangulate(bm, faces=ngons, quad_method="BEAUTY", ngon_method="BEAUTY")
    mesh = bpy.data.meshes.new(name)
    bm.to_mesh(mesh)
    bm.free()
    mesh.set_sharp_from_angle(angle=math.radians(52.0))
    return mesh


def build_seat(name, lod=0):
    """Creates one seat object (lod 0 near, lod 1 far) linked to the scene collection."""
    if lod not in (0, 1):
        raise ValueError("lod must be 0 or 1")
    mesh = _make_mesh(name, lod)
    mesh.materials.append(seat_material())
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.scene.collection.objects.link(obj)
    return obj


def triangle_count(obj):
    return sum(len(p.vertices) - 2 for p in obj.data.polygons)


# --------------------------------------------------------------------------
# Texture bake

ZONE_LOOK = {  # sRGB hex, roughness
    FABRIC: ("631d28", 0.95),  # burgundy microfibre / velvet
    SHELL: ("15171b", 0.45),   # charcoal moulded shell
    PAD: ("2a1c16", 0.55),     # espresso leather-look armrest
    METAL: ("3a3d42", 0.35),   # dim: hundreds of rims must not sparkle across the hall
    CUP: ("0b0c0e", 0.6),
    LEG: ("1f2125", 0.45),     # side standards
}


def _socket(node, name, kind):
    return next(s for s in node.inputs if s.name == name and s.type == kind)


def _math(nt, op, a, b=None):
    node = nt.nodes.new("ShaderNodeMath")
    node.operation = op
    for i, value in enumerate((a, b)):
        if value is None:
            continue
        if isinstance(value, (int, float)):
            node.inputs[i].default_value = value
        else:
            nt.links.new(value, node.inputs[i])
    return node.outputs[0]


def _band(nt, axis_socket, centre, half, soft, mirror=False):
    """1 inside |axis - centre| < half, smooth falloff over `soft` (world metres)."""
    value = _math(nt, "ABSOLUTE", axis_socket) if mirror else axis_socket
    dist = _math(nt, "ABSOLUTE", _math(nt, "SUBTRACT", value, centre))
    mr = nt.nodes.new("ShaderNodeMapRange")
    mr.interpolation_type = "SMOOTHSTEP"
    mr.inputs["From Min"].default_value = half + soft
    mr.inputs["From Max"].default_value = half
    nt.links.new(dist, mr.inputs["Value"])
    return mr.outputs["Result"]


def _mix(nt, factor, a, b):
    node = nt.nodes.new("ShaderNodeMix")
    node.data_type = "RGBA"
    if isinstance(factor, (int, float)):
        node.inputs["Factor"].default_value = factor
    else:
        nt.links.new(factor, node.inputs["Factor"])
    for name, value in (("A", a), ("B", b)):
        sock = _socket(node, name, "RGBA")
        if isinstance(value, tuple):
            sock.default_value = value
        else:
            nt.links.new(value, sock)
    return next(o for o in node.outputs if o.type == "RGBA")


def _scaled(base, k):
    return tuple(min(1.0, c * k) for c in base[:3]) + (1.0,)


def _any(nt, sockets):
    out = sockets[0]
    for s in sockets[1:]:
        out = _math(nt, "MAXIMUM", out, s)
    return out


def _edge_mask(nt, radius, lo, hi):
    """Rounded-edge mask from the Bevel node: 0 on flat areas, 1 on rolled edges."""
    bevel = nt.nodes.new("ShaderNodeBevel")
    bevel.samples = 4
    bevel.inputs["Radius"].default_value = radius
    geo = nt.nodes.new("ShaderNodeNewGeometry")
    dot = nt.nodes.new("ShaderNodeVectorMath")
    dot.operation = "DOT_PRODUCT"
    nt.links.new(bevel.outputs["Normal"], dot.inputs[0])
    nt.links.new(geo.outputs["Normal"], dot.inputs[1])
    mr = nt.nodes.new("ShaderNodeMapRange")
    mr.inputs["From Min"].default_value = 1.0 - lo
    mr.inputs["From Max"].default_value = 1.0 - hi
    nt.links.new(dot.outputs["Value"], mr.inputs["Value"])
    return mr.outputs["Result"], bevel.outputs["Normal"]


def _occlusion(nt, distance):
    ao = nt.nodes.new("ShaderNodeAmbientOcclusion")
    ao.samples = 8
    ao.inputs["Distance"].default_value = distance
    return ao.outputs["AO"]


def _seams(nt, x, y, z, coord, color, base):
    """Painted channel seams with dashed stitching (matches the modelled channels)."""
    back = _band(nt, y, -0.36, 0.17, 0.02)        # backrest (y < -0.17)
    seat = _math(nt, "SUBTRACT", 1.0, back)
    lines = [_math(nt, "MULTIPLY", _band(nt, x, gx, 0.0022, 0.0035, mirror=True), back) for gx in (0.068, 0.156, 0.232)]
    lines += [_math(nt, "MULTIPLY", _band(nt, x, gx, 0.0022, 0.0035, mirror=True), seat) for gx in (0.085, 0.200)]
    lines.append(_math(nt, "MULTIPLY", _band(nt, z, 0.852, 0.0022, 0.0035), back))
    color = _mix(nt, _math(nt, "MULTIPLY", _any(nt, lines), 0.6), color, _scaled(base, 0.4))
    stitches = []
    for gx, mask in ((0.068, back), (0.156, back), (0.232, back), (0.085, seat), (0.200, seat)):
        for off in (-0.008, 0.008):
            stitches.append(_math(nt, "MULTIPLY", _band(nt, x, gx + off, 0.0006, 0.0010, mirror=True), mask))
    dash = nt.nodes.new("ShaderNodeTexWave")
    dash.wave_type = "BANDS"
    dash.bands_direction = "DIAGONAL"
    dash.inputs["Scale"].default_value = 70.0
    nt.links.new(coord, dash.inputs["Vector"])
    dashes = _math(nt, "GREATER_THAN", dash.outputs["Fac"], 0.45)
    stitch = _math(nt, "MULTIPLY", _any(nt, stitches), dashes)
    return _mix(nt, _math(nt, "MULTIPLY", stitch, 0.3), color, _scaled(base, 1.6))


def _bake_material(zone, image):
    hex_value, rough = ZONE_LOOK[zone]
    mat = bpy.data.materials.new("_seatbake_" + ZONE_NAMES[zone])
    mat.use_nodes = True
    nt = mat.node_tree
    bsdf = nt.nodes["Principled BSDF"]
    bsdf.inputs["Roughness"].default_value = rough
    base = (*_srgb(hex_value), 1.0)
    coord = nt.nodes.new("ShaderNodeTexCoord")
    xyz = nt.nodes.new("ShaderNodeSeparateXYZ")
    nt.links.new(coord.outputs["Object"], xyz.inputs[0])
    x, y, z = xyz.outputs["X"], xyz.outputs["Y"], xyz.outputs["Z"]
    # Broad, low-frequency tonal variation only (fine noise would alias at distance).
    noise = nt.nodes.new("ShaderNodeTexNoise")
    noise.inputs["Scale"].default_value = {FABRIC: 9.0, PAD: 22.0}.get(zone, 6.0)
    noise.inputs["Detail"].default_value = 2.0
    nt.links.new(coord.outputs["Object"], noise.inputs["Vector"])
    ramp = nt.nodes.new("ShaderNodeValToRGB")
    lo, hi = {FABRIC: (0.90, 1.08), PAD: (0.88, 1.10)}.get(zone, (0.95, 1.04))
    ramp.color_ramp.elements[0].position = 0.3
    ramp.color_ramp.elements[1].position = 0.7
    ramp.color_ramp.elements[0].color = _scaled(base, lo)
    ramp.color_ramp.elements[1].color = _scaled(base, hi)
    nt.links.new(noise.outputs["Fac"], ramp.inputs["Fac"])
    color = ramp.outputs["Color"]
    if zone == FABRIC:
        # Velvet: crevices sink darker, rolled edges catch a soft sheen.
        color = _mix(nt, _occlusion(nt, 0.05), _scaled(base, 0.55), color)
        edge, _ = _edge_mask(nt, 0.018, 0.02, 0.18)
        color = _mix(nt, _math(nt, "MULTIPLY", edge, 0.55), color, _scaled(base, 1.45))
        color = _seams(nt, x, y, z, coord.outputs["Object"], color, base)
    elif zone == PAD:
        color = _mix(nt, _occlusion(nt, 0.03), _scaled(base, 0.6), color)
        edge, _ = _edge_mask(nt, 0.010, 0.02, 0.2)
        color = _mix(nt, _math(nt, "MULTIPLY", edge, 0.5), color, _scaled(base, 1.5))
        geo = nt.nodes.new("ShaderNodeNewGeometry")
        nz = nt.nodes.new("ShaderNodeSeparateXYZ")
        nt.links.new(geo.outputs["Normal"], nz.inputs[0])
        sheen = nt.nodes.new("ShaderNodeMapRange")
        sheen.interpolation_type = "SMOOTHSTEP"
        sheen.inputs["From Min"].default_value = 0.85
        sheen.inputs["From Max"].default_value = 1.0
        nt.links.new(nz.outputs["Z"], sheen.inputs["Value"])
        color = _mix(nt, _math(nt, "MULTIPLY", sheen.outputs["Result"], 0.35), color, _scaled(base, 1.4))
        # Welt seams along both top edges of the pad.
        dx = _math(nt, "SUBTRACT", _math(nt, "ABSOLUTE", x), ARM_X)
        welt = _math(nt, "MULTIPLY", _band(nt, dx, 0.033, 0.0012, 0.0018, mirror=True),
                     _band(nt, y, 0.02, 0.27, 0.01))
        color = _mix(nt, _math(nt, "MULTIPLY", welt, 0.7), color, _scaled(base, 0.45))
    elif zone in (SHELL, LEG):
        edge, _ = _edge_mask(nt, 0.008, 0.02, 0.25)
        color = _mix(nt, _math(nt, "MULTIPLY", edge, 0.6), color, _scaled(base, 1.7))
        if zone == SHELL:
            rear = _band(nt, y, -0.46, 0.15, 0.015)          # rear face only (y < -0.31)
            inner = _math(nt, "MULTIPLY", _band(nt, x, 0.0, 0.205, 0.006, mirror=True),
                          _band(nt, z, 0.640, 0.170, 0.006))
            outer = _math(nt, "MULTIPLY", _band(nt, x, 0.0, 0.213, 0.003, mirror=True),
                          _band(nt, z, 0.640, 0.178, 0.003))
            outline = _math(nt, "MULTIPLY", _math(nt, "SUBTRACT", outer, inner), rear)
            color = _mix(nt, _math(nt, "MULTIPLY", inner, rear), color, (*_srgb("1d2025"), 1.0))
            color = _mix(nt, _math(nt, "MULTIPLY", outline, 0.55), color, (*_srgb("0a0b0d"), 1.0))
            strip = _math(nt, "MULTIPLY", _band(nt, z, 0.852, 0.004, 0.0015), rear)
            color = _mix(nt, strip, color, (*_srgb("3e4147"), 1.0))
        else:
            # Dim number-plate area on the outer face of each standard (no text).
            outside = _band(nt, x, 0.40, 0.049, 0.002, mirror=True)
            plate = _math(nt, "MULTIPLY", _band(nt, y, 0.15, 0.040, 0.003), _band(nt, z, 0.50, 0.018, 0.003))
            frame = _math(nt, "MULTIPLY", _band(nt, y, 0.15, 0.044, 0.002), _band(nt, z, 0.50, 0.022, 0.002))
            color = _mix(nt, _math(nt, "MULTIPLY", _math(nt, "SUBTRACT", frame, plate), outside), color,
                         (*_srgb("0c0d0f"), 1.0))
            color = _mix(nt, _math(nt, "MULTIPLY", plate, outside), color, (*_srgb("2e3136"), 1.0))
    nt.links.new(color, bsdf.inputs["Base Color"])
    tex = nt.nodes.new("ShaderNodeTexImage")
    tex.image = image
    nt.nodes.active = tex
    return mat


def _setup_device(scene):
    prefs = bpy.context.preferences.addons["cycles"].preferences
    for kind in ("OPTIX", "CUDA"):
        try:
            prefs.compute_device_type = kind
            prefs.get_devices()
        except (TypeError, ValueError):
            continue
        usable = [d for d in prefs.devices if d.type == kind]
        if usable:
            for d in prefs.devices:
                d.use = d.type == kind
            scene.cycles.device = "GPU"
            return kind
    scene.cycles.device = "CPU"
    return "CPU"


def _bake_world():
    world = bpy.data.worlds.new("_seatbake_world")
    world.use_nodes = True
    nt = world.node_tree
    bg = nt.nodes["Background"]
    coord = nt.nodes.new("ShaderNodeTexCoord")
    sep = nt.nodes.new("ShaderNodeSeparateXYZ")
    nt.links.new(coord.outputs["Generated"], sep.inputs[0])
    ramp = nt.nodes.new("ShaderNodeValToRGB")
    ramp.color_ramp.elements[0].position = 0.30
    ramp.color_ramp.elements[0].color = (0.15, 0.15, 0.16, 1.0)
    ramp.color_ramp.elements[1].position = 0.75
    ramp.color_ramp.elements[1].color = (0.85, 0.85, 0.85, 1.0)
    maprange = nt.nodes.new("ShaderNodeMapRange")
    maprange.inputs["From Min"].default_value = -1.0
    maprange.inputs["From Max"].default_value = 1.0
    nt.links.new(sep.outputs["Z"], maprange.inputs["Value"])
    nt.links.new(maprange.outputs["Result"], ramp.inputs["Fac"])
    nt.links.new(ramp.outputs["Color"], bg.inputs["Color"])
    bg.inputs["Strength"].default_value = 1.0
    return world


def bake_seat_texture(path, size=2048):
    """Bakes albedo x occlusion x soft top light for the shared seat UV layout to `path` (PNG)."""
    t0 = time.time()
    caller_scene = bpy.context.scene
    before = {coll: set(getattr(bpy.data, coll)) for coll in
              ("objects", "meshes", "materials", "images", "worlds", "lights", "scenes", "node_groups")}
    scene = bpy.data.scenes.new("_seatbake_scene")
    try:
        scene.render.engine = "CYCLES"
        device = _setup_device(scene)
        scene.cycles.samples = 96
        scene.cycles.use_denoising = False
        scene.cycles.max_bounces = 4
        scene.cycles.diffuse_bounces = 3
        scene.view_settings.view_transform = "Standard"
        scene.world = _bake_world()

        image = bpy.data.images.new("_seatbake_image", size, size, alpha=False, float_buffer=False)
        image.generated_color = (*_srgb("15171b"), 1.0)
        mesh = _make_mesh("_seatbake_mesh", 0, zones=True)
        for zone in range(len(ZONE_NAMES)):
            mesh.materials.append(_bake_material(zone, image))
        zone_attr = mesh.attributes["seat_zone"]
        values = [0] * len(mesh.polygons)
        zone_attr.data.foreach_get("value", values)
        mesh.polygons.foreach_set("material_index", values)
        obj = bpy.data.objects.new("_seatbake_obj", mesh)
        scene.collection.objects.link(obj)
        # Neighbours and floor give the occlusion seen in a packed row.
        for i, dx in enumerate((-SEAT_PITCH, SEAT_PITCH)):
            other = bpy.data.objects.new("_seatbake_nb%d" % i, mesh)
            other.location.x = dx
            scene.collection.objects.link(other)
        floor_mesh = bpy.data.meshes.new("_seatbake_floor")
        floor_mesh.from_pydata([(-3, -3, 0), (3, -3, 0), (3, 3, 0), (-3, 3, 0)], [], [(0, 1, 2, 3)])
        floor_mat = bpy.data.materials.new("_seatbake_floormat")
        floor_mat.use_nodes = True
        floor_mat.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = (0.03, 0.03, 0.035, 1)
        floor_mesh.materials.append(floor_mat)
        floor = bpy.data.objects.new("_seatbake_floor", floor_mesh)
        scene.collection.objects.link(floor)
        # Soft key from above and slightly in front (ceiling / screen side).
        light = bpy.data.lights.new("_seatbake_sun", "SUN")
        light.energy = 0.35
        light.angle = math.radians(60.0)
        sun = bpy.data.objects.new("_seatbake_sun", light)
        sun.rotation_euler = (math.radians(-35.0), 0.0, 0.0)  # tilted towards -Y: light comes from +Y/up
        scene.collection.objects.link(sun)

        view_layer = scene.view_layers[0]
        for o in scene.objects:
            o.select_set(False, view_layer=view_layer)
        obj.select_set(True, view_layer=view_layer)
        view_layer.objects.active = obj
        with bpy.context.temp_override(scene=scene, view_layer=view_layer, active_object=obj,
                                       object=obj, selected_objects=[obj], selected_editable_objects=[obj]):
            bpy.ops.object.bake(type="DIFFUSE", pass_filter={"DIRECT", "INDIRECT", "COLOR"},
                                margin=max(4, size // 128), margin_type="EXTEND", use_clear=False,
                                target="IMAGE_TEXTURES")
        folder = os.path.dirname(os.path.abspath(path))
        os.makedirs(folder, exist_ok=True)
        image.filepath_raw = path
        image.file_format = "PNG"
        image.save()
        print("seat_model: baked %s (%dpx, %s) in %.1fs" % (path, size, device, time.time() - t0))
    finally:
        for coll, existing in before.items():
            data = getattr(bpy.data, coll)
            for item in [it for it in data if it not in existing]:
                if coll == "scenes" and item == caller_scene:
                    continue
                data.remove(item)
