"""Procedural premium lounge seat for the VR IMAX auditorium.

Blender (Z up, metres). Origin = floor under the seat centre line, seat faces +Y.
Every part is a parametric surface sampled per LOD; UVs come from the surface
parameters (or a fixed planar projection for caps) packed into one atlas whose
layout is derived from LOD 0, so LOD 0 and LOD 1 share the same texture.

    import seat_model
    seat_model.bake_seat_texture(path, 2048)
    obj = seat_model.build_seat("Seat", lod=0)
"""

import json
import math
import os
import time

import bmesh
import bpy
from mathutils import Vector

MATERIAL_NAME = "CinemaSeat"
UV_NAME = "UVMap"
SEAT_PITCH = 0.90  # row spacing used for neighbour occlusion in the bake

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


def _cross2(o, p, q):
    return (p[0] - o[0]) * (q[1] - o[1]) - (p[1] - o[1]) * (q[0] - o[0])


def _area2(pts, order):
    return sum(pts[order[i]][0] * pts[order[(i + 1) % len(order)]][1]
               - pts[order[(i + 1) % len(order)]][0] * pts[order[i]][1] for i in range(len(order)))


def _ear_clip_hole(outer, hole):
    """Triangulates a polygon with one hole (2D) by bridging it into a single loop."""
    pts = list(outer) + list(hole)
    o = list(range(len(outer)))
    h = list(range(len(outer), len(pts)))
    if _area2(pts, o) < 0:
        o.reverse()
    if _area2(pts, h) > 0:
        h.reverse()
    k, m = min(((a, b) for a in range(len(o)) for b in range(len(h))),
               key=lambda ab: math.dist(pts[o[ab[0]]], pts[h[ab[1]]]))
    order = o[:k + 1] + h[m:] + h[:m + 1] + o[k:]
    return pts, _ear_clip(pts, order)


def _ear_clip(pts, order=None):
    """Ear-clipping triangulation of a simple 2D polygon (indices into pts)."""
    cross = _cross2
    if order is None:
        order = list(range(len(pts)))
        if _area2(pts, order) < 0:
            order.reverse()
    idx = list(order)
    tris = []
    guard = 0
    while len(idx) > 3 and guard < 10000:
        guard += 1
        best = None
        for k in range(len(idx)):
            i0, i1, i2 = idx[k - 1], idx[k], idx[(k + 1) % len(idx)]
            a, b, c = pts[i0], pts[i1], pts[i2]
            if cross(a, b, c) <= 1e-12:
                continue
            if any(cross(a, b, pts[j]) >= 0 and cross(b, c, pts[j]) >= 0 and cross(c, a, pts[j]) >= 0
                   for j in idx if j not in (i0, i1, i2) and pts[j] not in (a, b, c)):
                continue
            # Prefer the fattest ear for well-shaped triangles.
            la = math.dist(a, b) + math.dist(b, c) + math.dist(c, a)
            q = cross(a, b, c) / (la * la)
            if best is None or q > best[0]:
                best = (q, k)
        if best is None:
            break
        k = best[1]
        tris.append((idx[k - 1], idx[k], idx[(k + 1) % len(idx)]))
        idx.pop(k)
    if len(idx) == 3:
        tris.append(tuple(idx))
    return tris


def _planar(key, loops, axes, zones, weight=1.0, extra_faces=()):
    """Polygon caps projected on two axes. `loops` is a list of point loops (each
    becomes one n-gon); `extra_faces` are (points, zone) quads sharing the chart."""
    part = _Part(key, weight)
    a, b = axes
    for loop, zone in list(zip(loops, zones)) + list(extra_faces):
        base = len(part.verts)
        part.verts.extend(loop)
        flat = [(p.dot(a), p.dot(b)) for p in loop]
        # Triangulate in the projection plane itself so the chart can never fold over.
        tris = _ear_clip(flat) if len(loop) > 4 else [tuple(range(len(loop)))]
        for tri in tris:
            part.faces.append(tuple(base + i for i in tri))
            part.uvs.append([flat[i] for i in tri])
            part.zones.append(zone)
    us = [uv[0] for f in part.uvs for uv in f]
    vs = [uv[1] for f in part.uvs for uv in f]
    part.bounds = (min(us), min(vs), max(us), max(vs))
    part.size = (part.bounds[2] - part.bounds[0], part.bounds[3] - part.bounds[1])
    return part


# ---- Backrest -------------------------------------------------------------
#
# Horizontal cross-sections are smooth closed curves made of pieces (quilted
# front panel, rolled cushion edge, shell rim, side wall, rear corner, rear).
# A curve parameter t in [0, 1) runs front centre -> right side -> rear centre
# -> left side; piece boundaries sit at fixed t, so every LOD samples the same
# surface at a subset of parameters and zones/UVs stay consistent.

RECLINE = math.radians(12.0)
BACK_FRONT_Y = -0.175     # cushion front y at z = 0.46
BACK_REAR_LIMIT = -0.374
BACK_TOP_Z = 1.068
ARC = 0.040               # front-view curvature of the headrest top
BACK_XF = 0.290           # end of the quilted panel / start of the rolled edge
BACK_ROLL = 0.036         # radius of the rolled cushion edge (upholstery 0.652 m wide)
BACK_W = 0.358            # shell half width: tucks 3 mm into the consoles at x = +/-0.355
BACK_GROOVES = (0.076, 0.173, 0.257)
BACK_T = (0.0, 0.18, 0.22, 0.235, 0.27, 0.315, 0.5)
BACK_SEAM_T = BACK_T[4]   # UV seam on the right side (sampled by every LOD)

# name, z, front bulge, x scale, top compression, arc weight, depth
BACK_ROWS = [
    ("r0", 0.360, 0.000, 1.000, 1.00, 0.00, 0.120),
    ("r1", 0.448, 0.004, 1.000, 1.00, 0.00, 0.140),
    ("r2", 0.560, 0.022, 1.000, 1.00, 0.00, 0.152),
    ("r4", 0.750, 0.008, 1.000, 1.00, 0.00, 0.146),
    ("r5", 0.852, -0.010, 1.000, 1.00, 0.10, 0.097),   # headrest seam; trim recess on the rear
    ("r6", 0.905, 0.016, 1.000, 1.00, 0.30, 0.136),    # headrest pad
    ("r7", 0.975, 0.020, 0.995, 1.00, 0.60, 0.122),
    ("r7b", 1.004, 0.016, 0.988, 0.93, 0.72, 0.113),   # extra row: rounder headrest shoulder
    ("r8", 1.028, 0.010, 0.975, 0.82, 0.85, 0.104),
    ("r9", 1.056, 0.004, 0.940, 0.55, 0.95, 0.096),
    ("r10", BACK_TOP_Z, 0.000, 0.880, 0.25, 1.00, 0.092),
]


def _half_t(lod):
    """Curve parameters sampled on the right half (0 < t < 0.5)."""
    T = BACK_T
    if lod == 0:
        p1 = [x / BACK_XF for x in (0.038, 0.064, 0.076, 0.088, 0.125, 0.161, 0.173, 0.185,
                                    0.215, 0.241, 0.257, 0.273)] + [1.0]
        pieces = (p1, [0.2, 0.4, 0.6, 0.8, 1.0], [0.5, 1.0], [1.0], [0.33, 0.67, 1.0], [0.33, 0.67])
    else:
        pieces = ([0.5, 1.0], [1.0], [1.0], [1.0], [1.0], [0.5])  # keeps the shell flush with the consoles
    out = []
    for i, ss in enumerate(pieces):
        out += [T[i] + s * (T[i + 1] - T[i]) for s in ss]
    return out


BACK_LOD = {0: (_half_t(0), [r[0] for r in BACK_ROWS]),
            1: (_half_t(1), ["r0", "r2", "r4", "r7", "r9", "r10"])}


def _back_front_y(z):
    return BACK_FRONT_Y - (z - 0.46) * math.tan(RECLINE)


def _back_depth(z, depth):
    return min(depth, _back_front_y(z) - BACK_REAR_LIMIT - 0.006)


def _back_panel(x, bulge):
    """Quilted front: soft rounded channel grooves and a bolster rising into the rolled edge."""
    ax = min(abs(x), BACK_XF)
    d = 0.004 + bulge
    for g in BACK_GROOVES:
        d -= 0.015 * math.exp(-((ax - g) / 0.011) ** 2)
    return d + 0.022 * math.exp(-((ax - BACK_XF) / 0.024) ** 2)


def _back_section(t, depth, bulge):
    """(x, d) on the right half for 0 <= t <= 0.5; d = 0 is the nominal cushion front."""
    T = BACK_T
    dF = _back_panel(BACK_XF, bulge)
    side_len = max(0.004, 0.32 * depth - BACK_ROLL)
    y1 = dF - BACK_ROLL - side_len
    wall_top = min(y1 - 0.010, dF - 0.40 * depth)
    r2 = 0.30 * depth
    wall_bot = -depth + r2
    xc = BACK_XF + BACK_ROLL
    if t <= T[1]:
        x = BACK_XF * t / T[1]
        return x, _back_panel(x, bulge)
    if t <= T[2]:
        s = (t - T[1]) / (T[2] - T[1])
        if s <= 0.8:
            phi = 0.5 * math.pi * (1.0 - s / 0.8)
            return BACK_XF + BACK_ROLL * math.cos(phi), dF - BACK_ROLL + BACK_ROLL * math.sin(phi)
        return xc, dF - BACK_ROLL - side_len * (s - 0.8) / 0.2
    if t <= T[3]:
        s = (t - T[2]) / (T[3] - T[2])
        p0, p1, p2 = (xc, y1), (xc + 0.019, y1 - 0.003), (BACK_W, wall_top)
        a, b, k = (p0, p1, s / 0.5) if s <= 0.5 else (p1, p2, (s - 0.5) / 0.5)
        return a[0] + (b[0] - a[0]) * k, a[1] + (b[1] - a[1]) * k
    if t <= T[4]:
        s = (t - T[3]) / (T[4] - T[3])
        return BACK_W + 0.002 * math.sin(math.pi * s), wall_top + (wall_bot - wall_top) * s
    if t <= T[5]:
        s = (t - T[4]) / (T[5] - T[4])
        phi = -0.5 * math.pi * s
        return BACK_W - r2 + r2 * math.cos(phi), -depth + r2 + r2 * math.sin(phi)
    s = (t - T[5]) / (T[6] - T[5])
    x0 = BACK_W - r2
    x = x0 * (1.0 - s)
    return x, -depth - 0.006 * (1.0 - (x / x0) ** 2)


def _back_point(t, row):
    _, z, bulge, xs, squash, arc_w, depth = row
    depth = _back_depth(z, depth)
    side = 1.0
    if t > 0.5:
        t, side = 1.0 - t, -1.0
    x, d = _back_section(t, depth, bulge)
    mid = -0.5 * depth
    d = mid + (d - mid) * squash
    x *= xs * side
    zz = z - ARC * (x / 0.34) ** 2 * arc_w
    return Vector((x, _back_front_y(z) + d, zz))


def _back_loop(half):
    ts = [0.0] + list(half) + [0.5] + [1.0 - t for t in reversed(half)]
    ts = sorted(set(round(t, 9) for t in ts))
    start = min(range(len(ts)), key=lambda i: abs(ts[i] - BACK_SEAM_T))
    return ts[start:] + ts[:start]


def _back_zone(t0, t1):
    if t1 < t0:
        t1 += 1.0
    t = ((t0 + t1) * 0.5) % 1.0
    th = t if t <= 0.5 else 1.0 - t
    return FABRIC if th < BACK_T[2] else SHELL


def _backrest(lod):
    half, row_names = BACK_LOD[lod]
    rows = [r for r in BACK_ROWS if r[0] in row_names]
    loop = _back_loop(half)
    ring_params = [(t - BACK_SEAM_T) % 1.0 for t in loop] + [1.0]
    centre_line = [_back_point(0.0, row) for row in BACK_ROWS]
    acc = [0.0]
    for i in range(len(centre_line) - 1):
        acc.append(acc[-1] + (centre_line[i + 1] - centre_line[i]).length)
    row_param = {row[0]: acc[i] / acc[-1] for i, row in enumerate(BACK_ROWS)}
    rings = [[_back_point(t, row) for t in loop] for row in rows]
    zones = [_back_zone(loop[i], loop[(i + 1) % len(loop)]) for i in range(len(loop))]
    part = _grid("back", rings, ring_params, [row_param[r[0]] for r in rows], True, zones, weight=1.3)
    ref_loop = _back_loop(BACK_LOD[0][0])
    ref_rings = [[_back_point(t, row) for t in ref_loop] for row in BACK_ROWS]
    part.size = (sum(_loop_length(r) for r in ref_rings) / len(ref_rings), acc[-1])
    part.orient("out", Vector((0.0, _back_front_y(0.70) - 0.07, 0.70)))
    axes = (Vector((1, 0, 0)), Vector((0, 1, 0)))
    top = _planar("back_top", [rings[-1]], axes, [SHELL], weight=1.0)
    ref = _planar("back_top", [ref_rings[-1]], axes, [SHELL])
    top.bounds, top.size = ref.bounds, ref.size
    top.orient("dir", Vector((0, 0, 1)))
    return [part, top]


# ---- Seat cushion -----------------------------------------------------------

def _seat_profile():
    """Closed side profile (y, z, zone of segment to next, crown weight) with a round rolled front."""
    pts = [((-0.100, 0.325), SHELL), ((-0.195, 0.352), FABRIC), ((-0.210, 0.395), FABRIC),
           ((-0.205, 0.425), FABRIC), ((-0.190, 0.438), FABRIC), ((-0.100, 0.449), FABRIC),
           ((0.000, 0.456), FABRIC), ((0.100, 0.460), FABRIC), ((0.200, 0.461), FABRIC),
           ((0.290, 0.4605), FABRIC)]
    cy, cz, r = 0.360, 0.414, 0.046
    for deg in (90, 60, 30, 0, -30, -60):
        a = math.radians(deg)
        pts.append(((cy + r * math.cos(a), cz + r * math.sin(a)), FABRIC))
    pts += [((cy, cz - r), SHELL), ((0.320, 0.332), SHELL), ((0.250, 0.320), SHELL)]
    # Crown weight: full on the top, fading out around the rolled front so the roll never folds.
    crown = [0.0] * len(pts)
    for i in range(4, 11):
        crown[i] = 1.0
    for i, w in zip(range(11, 16), (0.8, 0.6, 0.4, 0.2, 0.0)):
        crown[i] = w
    return [(y, z, zone, crown[i]) for i, ((y, z), zone) in enumerate(pts)]


SEAT_PROFILE = _seat_profile()
SEAT_HALF_X = 0.358       # cushion tucks 3 mm into the standards on both sides
SEAT_STATIONS = [  # name, x, ring shrink (rounded cushion sides)
    ("e0", -0.358, 0.84), ("m0", -0.355, 0.92), ("n0", -0.348, 0.97), ("s0", -0.333, 1.00),
    ("c", 0.000, 1.00),
    ("s1", 0.333, 1.00), ("n1", 0.348, 0.97), ("m1", 0.355, 0.92), ("e1", 0.358, 0.84),
]
SEAT_LOD = {
    0: (list(range(len(SEAT_PROFILE))), [s[0] for s in SEAT_STATIONS]),
    1: ([0, 2, 4, 7, 10, 13, 16, 18], ["e0", "s0", "s1", "e1"]),
}
SEAT_CENTRE = Vector((0.0, 0.10, 0.395))
SEAT_SEAMS = (0.110, 0.255)     # painted channel seams on the seat


def _seat_point(prof, station):
    y, z, _, crown = prof
    _, x, shrink = station
    p = Vector((x, y, z))
    p.z -= crown * 0.012 * (x / 0.34) ** 2
    if shrink != 1.0:
        q = SEAT_CENTRE + (Vector((0.0, p.y, p.z)) - SEAT_CENTRE) * shrink
        p = Vector((x, q.y, q.z))
    return p


def _seat(lod):
    idx, snames = SEAT_LOD[lod]
    prof = [SEAT_PROFILE[i] for i in idx]
    stations = [s for s in SEAT_STATIONS if s[0] in snames]
    ref_pts = [Vector((0, p[0], p[1])) for p in SEAT_PROFILE]
    ref_params = _arc_params(ref_pts)
    ring_params = [ref_params[i] for i in idx] + [1.0]
    sweep_params = [(s[1] + SEAT_HALF_X) / (2 * SEAT_HALF_X) for s in stations]
    rings = [[_seat_point(p, s) for p in prof] for s in stations]
    zones = [p[2] for p in prof]
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


# ---- Shared armrest console and its standard ----------------------------------
#
# Real cinema rows share one armrest between neighbours (N seats, N + 1 armrests).
# Each seat carries the console on its -X side, centred on the seat boundary; the
# hall adds one end console per row. The console is generated around x = 0 and
# then shifted, so its UV charts are identical wherever it is placed.

CONSOLE_X = -0.45         # seat boundary (pitch 0.90 m)
ARM_HW = 0.095            # console half width (0.19 m)
ARM_YB, ARM_YF = -0.330, 0.400
ARM_RC_BACK, ARM_RC_FRONT = 0.045, 0.060
ARM_RINGS = [  # inset from the plan outline, z   (bottom roll -> side -> rolled top edge -> top)
    (0.010, 0.600), (0.000, 0.612), (0.000, 0.636), (0.0025, 0.651), (0.008, 0.659), (0.018, 0.663)]
ARM_TOP_Z = ARM_RINGS[-1][1]
CUP_Y = ARM_YF - 0.075
CUP_N = 12
CUP_R, CUP_RIM_R, CUP_RIM_Z = 0.037, 0.0345, ARM_TOP_Z - 0.002
CUP_FLOOR_R, CUP_FLOOR_Z = 0.031, 0.606
ARM_LOD = {0: ((0, 22.5, 45, 67.5, 90), list(range(len(ARM_RINGS)))), 1: ((0, 90), [1, 3, 5])}

LEG_RINGS = [  # z, y back, y front, half thickness (as wide as the console: no slot to the seat)
    (0.000, -0.330, 0.290, ARM_HW),
    (0.300, -0.300, 0.240, ARM_HW),
    (0.598, -0.326, 0.300, ARM_HW),
]
LEG_CORNER = 0.025
LEG_LOD = {0: (list(range(12)), [0, 1, 2]), 1: ([1, 4, 7, 10], [0, 2])}


def _shift(parts, dx):
    for part in parts:
        part.verts = [v + Vector((dx, 0.0, 0.0)) for v in part.verts]
    return parts


def _arm_outline(inset, z, angles):
    """Plan outline of the console around x = 0 (counter-clockwise from the front-right corner)."""
    hw = ARM_HW
    corners = ((hw - ARM_RC_FRONT, ARM_YF - ARM_RC_FRONT, ARM_RC_FRONT, 0),
               (-hw + ARM_RC_FRONT, ARM_YF - ARM_RC_FRONT, ARM_RC_FRONT, 90),
               (-hw + ARM_RC_BACK, ARM_YB + ARM_RC_BACK, ARM_RC_BACK, 180),
               (hw - ARM_RC_BACK, ARM_YB + ARM_RC_BACK, ARM_RC_BACK, 270))
    pts = []
    for ccx, ccy, r, a0 in corners:
        rr = max(0.002, r - inset)
        for a in angles:
            t = math.radians(a0 + a)
            pts.append(Vector((ccx + rr * math.cos(t), ccy + rr * math.sin(t), z)))
    return pts


def _circle_pts(cx, cy, r, z, n=CUP_N):
    return [Vector((cx + r * math.cos(2 * math.pi * k / n), cy + r * math.sin(2 * math.pi * k / n), z))
            for k in range(n)]


def _console(lod, cx):
    angles, ring_ids = ARM_LOD[lod]
    rings = [_arm_outline(ARM_RINGS[i][0], ARM_RINGS[i][1], angles) for i in ring_ids]
    ref = _arm_outline(0.0, 0.0, ARM_LOD[0][0])
    ref_params = _arc_params(ref)
    per = len(ARM_LOD[0][0])
    idx = [c * per + ARM_LOD[0][0].index(a) for c in range(4) for a in angles]
    ring_params = [ref_params[i] for i in idx] + [1.0]
    prof = [Vector((0.0, -inset, z)) for inset, z in ARM_RINGS]
    sweep_all = _arc_params(prof, closed=False)
    walls = _grid("arm", rings, ring_params, [sweep_all[i] for i in ring_ids], True, [PAD] * len(idx), weight=1.1)
    walls.size = (_loop_length(ref), _loop_length(prof, closed=False))
    walls.orient("out", Vector((0.0, 0.03, 0.63)))
    parts = [walls]
    axes = (Vector((1, 0, 0)), Vector((0, 1, 0)))
    top_ref = _arm_outline(ARM_RINGS[-1][0], ARM_TOP_Z, ARM_LOD[0][0])
    bounds = (min(p.x for p in top_ref), min(p.y for p in top_ref), max(p.x for p in top_ref), max(p.y for p in top_ref))
    if lod == 0:
        hole = _circle_pts(0.0, CUP_Y, CUP_R, ARM_TOP_Z)
        rim = _circle_pts(0.0, CUP_Y, CUP_RIM_R, CUP_RIM_Z)
        floor = _circle_pts(0.0, CUP_Y, CUP_FLOOR_R, CUP_FLOOR_Z)
        top = _Part("arm_top", 1.0)
        _, tris = _ear_clip_hole([(p.x, p.y) for p in rings[-1]], [(p.x, p.y) for p in hole])
        verts3 = list(rings[-1]) + list(hole)
        for tri in tris:
            _add_planar_face(top, [verts3[i] for i in tri], PAD, axes)
        for k in range(CUP_N):
            k2 = (k + 1) % CUP_N
            _add_planar_face(top, (hole[k], hole[k2], rim[k2], rim[k]), METAL, axes)
        for tri in _ear_clip([(p.x, p.y) for p in floor]):
            _add_planar_face(top, [floor[i] for i in tri], CUP, axes)
        inner = _grid("arm_cup", [rim, floor], [k / CUP_N for k in range(CUP_N + 1)], [0.0, 1.0],
                      True, [CUP] * CUP_N, weight=0.5)
        inner.size = (2 * math.pi * CUP_RIM_R, CUP_RIM_Z - CUP_FLOOR_Z)
        inner.orient("in", Vector((0.0, CUP_Y, 0.63)))
        parts.append(inner)
        bottom = _planar("arm_bot", [rings[0]], axes, [SHELL], weight=0.4)
        _fix_up(bottom, -1)
        parts.append(bottom)
    else:
        top = _planar("arm_top", [rings[-1]], axes, [PAD], weight=1.0)
    _fix_up(top, 1)
    top.bounds, top.size = bounds, (bounds[2] - bounds[0], bounds[3] - bounds[1])
    parts.append(top)
    return _shift(parts + _standard(lod), cx)


def _add_planar_face(part, pts, zone, axes):
    a, b = axes
    base = len(part.verts)
    part.verts.extend(pts)
    part.faces.append(tuple(range(base, base + len(pts))))
    part.uvs.append([(p.dot(a), p.dot(b)) for p in pts])
    part.zones.append(zone)


def _fix_up(part, sign):
    """Orients every face of a planar chart individually towards +/-Z."""
    faces, uvs = [], []
    for face, uv in zip(part.faces, part.uvs):
        if _newell([part.verts[i] for i in face]).z * sign < 0:
            face, uv = tuple(reversed(face)), list(reversed(uv))
        faces.append(face)
        uvs.append(uv)
    part.faces, part.uvs = faces, uvs


def _leg_ring(spec, ids):
    """Rounded-rectangle plan section around x = 0 (12 points: 3 per corner)."""
    z, yb, yf, t = spec
    r = LEG_CORNER
    corners = ((t - r, yf - r, 0), (-t + r, yf - r, 90), (-t + r, yb + r, 180), (t - r, yb + r, 270))
    pts = []
    for cxr, cyr, a0 in corners:
        for k in range(3):
            a = math.radians(a0 + 45 * k)
            pts.append(Vector((cxr + r * math.cos(a), cyr + r * math.sin(a), z)))
    return [pts[i] for i in ids]


def _standard(lod):
    ids, ring_ids = LEG_LOD[lod]
    ref = _leg_ring(LEG_RINGS[-1], range(12))
    params_all = _arc_params(ref)
    rings = [_leg_ring(LEG_RINGS[i], ids) for i in ring_ids]
    ring_params = [params_all[i] for i in ids] + [1.0]
    sweep = [LEG_RINGS[i][0] / LEG_RINGS[-1][0] for i in ring_ids]
    part = _grid("leg", rings, ring_params, sweep, True, [LEG] * len(ids), weight=0.7)
    part.size = (_loop_length(ref), LEG_RINGS[-1][0])
    part.orient("out", Vector((0.0, 0.0, 0.3)))
    return [part]


def _beam():
    """Pivot tube carrying the seat between the two standards (hidden under the cushion)."""
    rings = [[Vector((x, y, z)) for y, z in ((0.015, 0.335), (0.045, 0.335), (0.045, 0.365), (0.015, 0.365))]
             for x in (-0.37, 0.355)]
    part = _grid("beam", rings, [0.0, 0.25, 0.5, 0.75, 1.0], [0.0, 1.0], True, [LEG] * 4, weight=0.3)
    part.size = (0.12, 0.725)
    part.orient("out", Vector((0, 0.03, 0.35)))
    return [part]


def _parts(lod):
    parts = _backrest(lod) + _seat(lod) + _console(lod, CONSOLE_X)
    if lod == 0:
        parts += _beam()
    return parts


def _end_parts(lod):
    return _console(lod, 0.0)


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


def _make_mesh(name, lod, zones=False, parts=None):
    bounds, rects = _layout()
    parts = _parts(lod) if parts is None else parts
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
    mesh.set_sharp_from_angle(angle=math.radians(60.0))
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


def build_end_armrest(name, lod=0):
    """Creates the standalone row-end console (+ standard) centred at x = 0.

    Seats carry their console on the -X side; place one of these at
    last_seat_x + SEAT_PITCH / 2 to close each row. Same material and UV layout
    as the seats, so the one baked seat texture serves both."""
    if lod not in (0, 1):
        raise ValueError("lod must be 0 or 1")
    mesh = _make_mesh(name, lod, parts=_end_parts(lod))
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


def _any(nt, sockets):
    out = sockets[0]
    for s in sockets[1:]:
        out = _math(nt, "MAXIMUM", out, s)
    return out


def _occlusion(nt, distance):
    ao = nt.nodes.new("ShaderNodeAmbientOcclusion")
    ao.samples = 8
    ao.inputs["Distance"].default_value = distance
    return ao.outputs["AO"]


TEXTURE_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "textures")
# Scanned, unlit-calibrated base colours per zone: (manifest key, brightness factor).
ZONE_SCAN = {
    FABRIC: ("seat_velour", 1.0),
    PAD: ("seat_leather", 1.0),
    SHELL: ("seat_shell", 1.0),
    LEG: ("seat_shell", 0.8),
    METAL: ("seat_metal", 1.0),
}
SCAN_BOX_BLEND = 0.2


def _texture_manifest():
    path = os.path.join(TEXTURE_DIR, "textures.json")
    if not os.path.isfile(path):
        raise FileNotFoundError("seat_model: texture manifest missing: %s" % path)
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def _check_textures():
    manifest = _texture_manifest()
    for key, _ in ZONE_SCAN.values():
        entry = manifest.get(key)
        if entry is None:
            raise FileNotFoundError("seat_model: '%s' not listed in %s" % (key, TEXTURE_DIR))
        path = os.path.join(TEXTURE_DIR, entry["file"])
        if not os.path.isfile(path):
            raise FileNotFoundError("seat_model: texture missing: %s" % path)
    return manifest


def _scale_col(nt, color, k):
    node = nt.nodes.new("ShaderNodeVectorMath")
    node.operation = "SCALE"
    nt.links.new(color, node.inputs[0])
    node.inputs["Scale"].default_value = k
    return node.outputs["Vector"]


def _scan(nt, coord, entry, factor):
    """Box-projected scan at its real-world tile size (object space, metres)."""
    path = os.path.join(TEXTURE_DIR, entry["file"])
    image = bpy.data.images.load(path, check_existing=True)
    image.colorspace_settings.name = "sRGB"
    scale = nt.nodes.new("ShaderNodeVectorMath")
    scale.operation = "SCALE"
    scale.inputs["Scale"].default_value = 1.0 / float(entry["tile_metres"])
    nt.links.new(coord, scale.inputs[0])
    tex = nt.nodes.new("ShaderNodeTexImage")
    tex.image = image
    tex.projection = "BOX"
    tex.projection_blend = SCAN_BOX_BLEND
    tex.interpolation = "Cubic"
    nt.links.new(scale.outputs["Vector"], tex.inputs["Vector"])
    color = tex.outputs["Color"]
    return _scale_col(nt, color, factor) if factor != 1.0 else color


def _seams(nt, x, y, z, coord, color):
    """Tailoring overlays on the velour: channel seams (darkened) and dashed stitching."""
    back = _band(nt, y, -0.36, 0.17, 0.02)        # backrest (y < -0.17)
    seat = _math(nt, "SUBTRACT", 1.0, back)
    lines = [_math(nt, "MULTIPLY", _band(nt, x, gx, 0.0022, 0.0035, mirror=True), back) for gx in BACK_GROOVES]
    lines += [_math(nt, "MULTIPLY", _band(nt, x, gx, 0.0022, 0.0035, mirror=True), seat) for gx in SEAT_SEAMS]
    lines.append(_math(nt, "MULTIPLY", _band(nt, z, 0.852, 0.0022, 0.0035), back))
    color = _mix(nt, _math(nt, "MULTIPLY", _any(nt, lines), 0.6), color, _scale_col(nt, color, 0.4))
    stitches = []
    for gx, mask in [(g, back) for g in BACK_GROOVES] + [(g, seat) for g in SEAT_SEAMS]:
        for off in (-0.008, 0.008):
            stitches.append(_math(nt, "MULTIPLY", _band(nt, x, gx + off, 0.0006, 0.0010, mirror=True), mask))
    dash = nt.nodes.new("ShaderNodeTexWave")
    dash.wave_type = "BANDS"
    dash.bands_direction = "DIAGONAL"
    dash.inputs["Scale"].default_value = 70.0
    nt.links.new(coord, dash.inputs["Vector"])
    dashes = _math(nt, "GREATER_THAN", dash.outputs["Fac"], 0.45)
    stitch = _math(nt, "MULTIPLY", _any(nt, stitches), dashes)
    return _mix(nt, _math(nt, "MULTIPLY", stitch, 0.3), color, _scale_col(nt, color, 1.6))


def _bake_material(zone, image, manifest):
    hex_value, rough = ZONE_LOOK[zone]
    mat = bpy.data.materials.new("_seatbake_" + ZONE_NAMES[zone])
    mat.use_nodes = True
    nt = mat.node_tree
    bsdf = nt.nodes["Principled BSDF"]
    bsdf.inputs["Roughness"].default_value = rough
    coord = nt.nodes.new("ShaderNodeTexCoord")
    obj_co = coord.outputs["Object"]
    xyz = nt.nodes.new("ShaderNodeSeparateXYZ")
    nt.links.new(obj_co, xyz.inputs[0])
    x, y, z = xyz.outputs["X"], xyz.outputs["Y"], xyz.outputs["Z"]
    if zone in ZONE_SCAN:
        key, factor = ZONE_SCAN[zone]
        color = _scan(nt, obj_co, manifest[key], factor)
    else:
        rgb = nt.nodes.new("ShaderNodeRGB")
        rgb.outputs[0].default_value = (*_srgb(hex_value), 1.0)
        color = rgb.outputs[0]
    # The scans already carry their own micro AO/relief; only modelled crevices darken further.
    if zone == FABRIC:
        color = _mix(nt, _occlusion(nt, 0.05), _scale_col(nt, color, 0.6), color)
        color = _seams(nt, x, y, z, obj_co, color)
    elif zone == PAD:
        color = _mix(nt, _occlusion(nt, 0.03), _scale_col(nt, color, 0.7), color)
        # Welt seams along both top edges of the pad.
        dx = _math(nt, "SUBTRACT", _math(nt, "ABSOLUTE", x), abs(CONSOLE_X))
        welt = _math(nt, "MULTIPLY", _band(nt, dx, ARM_HW - 0.019, 0.0012, 0.0018, mirror=True),
                     _band(nt, y, 0.05, 0.30, 0.01))
        color = _mix(nt, _math(nt, "MULTIPLY", welt, 0.7), color, _scale_col(nt, color, 0.45))
    elif zone in (SHELL, LEG):
        if zone == SHELL:
            rear = _band(nt, y, -0.46, 0.15, 0.015)          # rear face only (y < -0.31)
            inner = _math(nt, "MULTIPLY", _band(nt, x, 0.0, 0.225, 0.006, mirror=True),
                          _band(nt, z, 0.640, 0.170, 0.006))
            outer = _math(nt, "MULTIPLY", _band(nt, x, 0.0, 0.233, 0.003, mirror=True),
                          _band(nt, z, 0.640, 0.178, 0.003))
            outline = _math(nt, "MULTIPLY", _math(nt, "SUBTRACT", outer, inner), rear)
            color = _mix(nt, _math(nt, "MULTIPLY", inner, rear), color, _scale_col(nt, color, 1.25))
            color = _mix(nt, _math(nt, "MULTIPLY", outline, 0.55), color, _scale_col(nt, color, 0.45))
            # Dim brushed-metal trim in the rear recess.
            trim = _scan(nt, obj_co, manifest["seat_metal"], 1.0)
            strip = _math(nt, "MULTIPLY", _band(nt, z, 0.852, 0.004, 0.0015), rear)
            color = _mix(nt, strip, color, trim)
    nt.links.new(color, bsdf.inputs["Base Color"])
    tex = nt.nodes.new("ShaderNodeTexImage")
    tex.image = image
    nt.nodes.active = tex
    return mat


def smooth_terminator(obj):
    """Hides the shadow-terminator stepping that low-poly smooth meshes show in Cycles."""
    obj.cycles.shadow_terminator_geometry_offset = 0.6
    obj.cycles.shadow_terminator_offset = 0.1


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
    manifest = _check_textures()
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
            mesh.materials.append(_bake_material(zone, image, manifest))
        zone_attr = mesh.attributes["seat_zone"]
        values = [0] * len(mesh.polygons)
        zone_attr.data.foreach_get("value", values)
        mesh.polygons.foreach_set("material_index", values)
        obj = bpy.data.objects.new("_seatbake_obj", mesh)
        scene.collection.objects.link(obj)
        smooth_terminator(obj)
        # Neighbours and floor give the occlusion seen in a packed row.
        for i, dx in enumerate((-SEAT_PITCH, SEAT_PITCH)):
            other = bpy.data.objects.new("_seatbake_nb%d" % i, mesh)
            other.location.x = dx
            smooth_terminator(other)
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
