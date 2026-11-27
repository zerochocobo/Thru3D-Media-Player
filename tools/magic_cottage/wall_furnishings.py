"""Wall joinery, illuminated manuscripts and the astronomer's herbarium."""

import math
import random

import bpy

from hall_mesh import block, collection, lathe, line, marker, material, mesh, mottling, oval


def pose(obj, frame, location, rotation):
    obj.location = location
    obj.rotation_euler = rotation
    for path in ("location", "rotation_euler"):
        obj.keyframe_insert(data_path=path, frame=frame)


def foil(parent, name, xy, depth, thickness, mat, loop=False):
    obj = line(name, [(x, depth, z) for x, z in xy], thickness, mat, loop)
    obj.parent = parent
    return obj


def attach(part, parent):
    part.parent = parent
    return part


def illustrated_page(parent, mat, left):
    # The original painted spread is mapped onto two separate bowed sheets.
    # The left sheet is mounted on the reverse of the hinged cover.
    corners = (
        [(466, 741), (838, 743), (836, 426), (524, 416)]
        if left
        else [(871, 739), (1226, 738), (1172, 416), (861, 428)]
    )
    size = mat.node_tree.nodes.get("Page artwork").image.size[:]
    verts, uvs, faces = [], [], []
    cols, rows = 14, 10
    for row in range(rows + 1):
        v = row / rows
        for col in range(cols + 1):
            u = col / cols
            x = 0.013 + 0.35 * u
            bend = 0.009 * math.sin(math.pi * u) + 0.0018 * math.sin(v * math.pi) * u
            verts.append(
                (0.38 - x if left else x, 0.016 + bend if left else -0.044 - bend, -0.25 + 0.50 * v)
            )
            bottom = [corners[0][k] * (1 - u) + corners[1][k] * u for k in (0, 1)]
            top = [corners[3][k] * (1 - u) + corners[2][k] * u for k in (0, 1)]
            px, py = [bottom[k] * (1 - v) + top[k] * v for k in (0, 1)]
            uvs.append((px / size[0], 1 - py / size[1]))
    for row in range(rows):
        for col in range(cols):
            a = row * (cols + 1) + col
            faces.append((a, a + 1, a + cols + 2, a + cols + 1))
    page = attach(mesh("Botanical plate" if left else "Pressed moonbell plate", verts, faces, mat), parent)
    uv = page.data.uv_layers.new(name="Illumination")
    for poly in page.data.polygons:
        poly.use_smooth = True
        for i in poly.loop_indices:
            uv.data[i].uv = uvs[page.data.loops[i].vertex_index]


def manuscript(number, y, hide, paper, gold, illustration, seat_y):
    names = ["Star atlas", "Moonbell herbal", "Projection journal"]
    collection("Manuscript | " + names[number])
    root = marker(names[number], (-4.02, y, 1.56))
    home = root.location.copy()
    base_angle = math.radians(56)
    root.rotation_euler.z = base_angle
    width, height = 0.38, 0.54
    # The hinge axis is at the spine. The same volume opens in mid-air.
    hinge = attach(marker("Front board hinge", (0, -0.064, 0)), root)
    attach(
        block(
            "Leather back board", (width / 2, 0.069, 0), (width + 0.014, 0.027, height + 0.026), hide, 0.009
        ),
        root,
    )
    attach(
        block("Gilt page edges", (width / 2, 0.008, 0), (width - 0.012, 0.098, height), paper, 0.005), root
    )
    attach(
        block(
            "Leather front board",
            (width / 2, -0.010, 0),
            (width + 0.014, 0.030, height + 0.026),
            hide,
            0.008,
        ),
        hinge,
    )
    attach(block("Pastedown", (width / 2, 0.009, 0), (width - 0.026, 0.009, height - 0.025), paper), hinge)
    attach(
        block("Rounded leather spine", (0.005, 0.004, 0), (0.040, 0.158, height + 0.016), hide, 0.015), root
    )
    for z in (-0.18, -0.135, 0.14, 0.185):
        attach(block("Raised sewing band", (0.002, 0.003, z), (0.046, 0.162, 0.011), gold, 0.004), root)
    for margin in (0.024, 0.039):
        foil(
            hinge,
            "Tooled frame",
            [
                (margin, -height / 2 + margin),
                (width - margin, -height / 2 + margin),
                (width - margin, height / 2 - margin),
                (margin, height / 2 - margin),
            ],
            -0.026,
            0.0024,
            gold,
            True,
        )
    if number == 0:
        for radius in (0.060, 0.104):
            foil(
                hinge,
                "Orbit",
                [
                    (0.19 + radius * math.cos(t * math.tau / 40), radius * math.sin(t * math.tau / 40))
                    for t in range(40)
                ],
                -0.027,
                0.003,
                gold,
                True,
            )
        motif = [
            (0.19, 0.143),
            (0.205, 0.024),
            (0.29, 0),
            (0.209, -0.018),
            (0.19, -0.14),
            (0.17, -0.02),
            (0.087, 0),
            (0.17, 0.018),
        ]
    elif number == 1:
        motif = [
            (0.13, -0.12),
            (0.16, -0.045),
            (0.14, 0.015),
            (0.10, 0.05),
            (0.145, 0.043),
            (0.18, 0.001),
            (0.207, 0.045),
            (0.215, 0.117),
            (0.25, 0.09),
            (0.235, 0.045),
            (0.204, 0.025),
            (0.182, -0.022),
        ]
    else:
        motif = [
            (0.096, -0.105),
            (0.096, 0.044),
            (0.12, 0.092),
            (0.19, 0.125),
            (0.26, 0.092),
            (0.284, 0.044),
            (0.284, -0.105),
        ]
    foil(hinge, "Cover device", motif, -0.029, 0.005, gold, number != 1)
    for x in (0.055, width - 0.055):
        for z in (-0.215, 0.215):
            attach(oval("Brass boss", (x, -0.029, z), (0.009, 0.006, 0.009), gold), hinge)
            sx, sz = (1 if x < 0.1 else -1), (1 if z < 0 else -1)
            foil(
                hinge,
                "Corner tooling",
                [
                    (x + sx * 0.005, z + sz * 0.060),
                    (x + sx * 0.018, z + sz * 0.027),
                    (x + sx * 0.034, z + sz * 0.023),
                    (x + sx * 0.020, z + sz * 0.015),
                    (x + sx * 0.060, z + sz * 0.005),
                ],
                -0.027,
                0.0023,
                gold,
            )
    if number == 1:
        illustrated_page(hinge, illustration, True)
        illustrated_page(root, illustration, False)
        for i in range(8):
            depth = -0.034 + i * 0.010
            foil(
                root,
                "Folded signature",
                [(width - 0.003, -0.248), (width - 0.003, 0.249)],
                depth,
                0.0008,
                paper,
            )
        for frame, pos, rot in [
            (1, home, (0, 0, base_angle)),
            (24, home, (0, 0, base_angle)),
            (46, (-2.86, y - 0.20, 1.70), (-0.08, 0, 0.7)),
            (80, (0, seat_y + 1.05, 1.00), (-0.29, 0, 0)),
            (147, (0, seat_y + 1.05, 1.00), (-0.29, 0, 0)),
            (178, (-2.86, y - 0.20, 1.70), (-0.08, 0, 0.7)),
            (208, home, (0, 0, base_angle)),
        ]:
            pose(root, frame, pos, rot)
        for frame, angle in [(1, 0), (69, 0), (101, -176), (138, -176), (159, 0), (208, 0)]:
            hinge.rotation_euler.z = math.radians(angle)
            hinge.keyframe_insert(data_path="rotation_euler", frame=frame)
    # Local to the front board; ray tests use the exact pose shown on frame 1.
    target = attach(marker("Aim.Book." + str(number + 1), (0.19, -0.048, 0.04)), hinge)
    return target


def library(oak, trim, brass, paper, seat_y, artwork):
    collection("West wall | scriptorium")
    dark = material("Oxidised iron", (0.063, 0.072, 0.067), 0.62, 0.58)
    illustration = material("Illuminated moonbell folios", (0.85, 0.75, 0.55), 0.93)
    nodes, links = illustration.node_tree.nodes, illustration.node_tree.links
    tex = nodes.new("ShaderNodeTexImage")
    tex.name = "Page artwork"
    tex.image = artwork
    links.new(tex.outputs["Color"], nodes["Principled BSDF"].inputs["Base Color"])
    links.new(tex.outputs["Color"], nodes["Principled BSDF"].inputs["Emission Color"])
    nodes["Principled BSDF"].inputs["Emission Strength"].default_value = 0.20
    hides = [
        material("Indigo Morocco", (0.039, 0.078, 0.14)),
        material("Sage calfskin", (0.082, 0.18, 0.105)),
        material("Oxblood binding", (0.195, 0.062, 0.039)),
    ]
    for hide in hides:
        rgb = hide.diffuse_color[:3]
        mottling(hide, 7, tuple(v * 0.39 for v in rgb), tuple(v * 1.25 for v in rgb), 0.0018)
    near, far = 1.60, 4.46
    middle = (near + far) / 2
    block("Bookcase back", (-4.41, middle, 1.24), (0.16, far - near, 2.42), oak, 0.015)
    for z in (0.17, 0.82, 1.23, 1.97, 2.47):
        block("Mortised shelf", (-4.13, middle, z), (0.69, far - near + 0.10, 0.09), trim, 0.016)
        block(
            "Carved shelf bead", (-3.78, middle, z - 0.025), (0.035, far - near + 0.14, 0.055), oak, 0.012
        )
    for y in (near, far):
        block("Carved upright", (-4.13, y, 1.26), (0.65, 0.11, 2.5), oak, 0.017)
        post = lathe(
            "Turned pilaster",
            (-3.78, y, 0.16),
            [
                (0.06, 0),
                (0.075, 0.06),
                (0.047, 0.12),
                (0.036, 0.25),
                (0.035, 2.03),
                (0.065, 2.12),
                (0.065, 2.25),
            ],
            trim,
        )
        oval("Pilaster terminal", (post.location.x, y, 2.57), (0.083, 0.083, 0.110), trim)
    rng = random.Random(212)
    for level, count in [(0.22, 15), (0.87, 13), (2.02, 17)]:
        for i in range(count):
            y = near + 0.16 + i * (far - near - 0.35) / count
            if level > 2 and abs(y - 1.99) < .30:
                continue  # clear a dedicated lectern bay for the recipe grimoire
            h = rng.uniform(0.22, 0.315) if level < 2 else rng.uniform(0.25, 0.34)
            thick = rng.uniform(0.062, 0.115)
            hide = rng.choice(hides)
            block(
                "Archive | folded paper signatures",
                (-4.08, y, level + h / 2),
                (0.333, thick * 0.82, h - 0.014),
                paper,
                0.004,
            )
            for side in (-1, 1):
                block(
                    "Archive | leather board",
                    (-4.08, y + side * thick * 0.47, level + h / 2),
                    (0.35, 0.012, h),
                    hide,
                    0.005,
                )
            block("Archive | rounded spine", (-3.915, y, level + h / 2), (0.043, thick, h), hide, 0.012)
            for z in (level + 0.05, level + h - 0.055):
                block("Spine gilding", (-3.891, y, z), (0.006, thick * 0.86, 0.006), brass)
    targets = [
        manuscript(i, y, hides[i], paper, brass, illustration, seat_y)
        for i, y in enumerate((2.14, 2.96, 3.78))
    ]
    return targets, dark


def botanical_leaf(base, yaw, length, width, leafmat, vein):
    verts, ribs = [], []
    for i in range(8):
        t = i / 7
        p = (
            base[0] + math.cos(yaw) * length * t,
            base[1] + math.sin(yaw) * length * t,
            base[2] + length * (0.74 * math.sin(math.pi * t * 0.85) - 0.08 * t),
        )
        w = (math.sin(math.pi * t) ** 0.76) * width + 0.002
        ribs.append((p[0], p[1], p[2] + 0.008))
        for f in (-1, 0, 1):
            verts.append(
                (p[0] - math.sin(yaw) * w * f, p[1] + math.cos(yaw) * w * f, p[2] - 0.28 * w * abs(f))
            )
    mesh(
        "Folded lanceolate leaf",
        verts,
        [(3 * i + j, 3 * i + j + 1, 3 * i + j + 4, 3 * i + j + 3) for i in range(7) for j in (0, 1)],
        leafmat,
    )
    line("Leaf midrib", ribs, 0.002, vein)


def moonbell(at, petals, brass):
    verts = []
    # A nodding, five-lobed corolla, with a hollow mouth and a visible stamen.
    for ring, (r, z) in enumerate(
        [
            (0.014, 0.008),
            (0.042, -0.012),
            (0.051, -0.078),
            (0.069, -0.112),
            (0.061, -0.112),
            (0.044, -0.073),
        ]
    ):
        for i in range(30):
            a = math.tau * i / 30
            scallop = 0.5 + 0.5 * math.cos(5 * a)
            radius = r * (1 + 0.16 * math.cos(5 * a) * min(1, ring * 0.7))
            verts.append(
                (radius * math.cos(a), radius * math.sin(a), z - (0.033 * scallop if ring in (3, 4) else 0))
            )
    obj = mesh(
        "Moonbell | scalloped corolla",
        verts,
        [
            (30 * k + i, 30 * k + (i + 1) % 30, 30 * (k + 1) + (i + 1) % 30, 30 * (k + 1) + i)
            for k in range(5)
            for i in range(30)
        ],
        petals,
    )
    for poly in obj.data.polygons:
        poly.use_smooth = True
    obj.location = at
    attach(oval("Pollen", (0, 0, -0.113), (0.009, 0.009, 0.026), brass), obj)
    return obj


def herbarium(oak, trim, clay, brass, leaf, petals):
    collection("East wall | herbalist's dresser")
    near, far = 1.62, 4.47
    mid = (near + far) / 2
    block("Dresser back", (4.46, mid, 0.90), (0.08, far - near, 1.74), oak, 0.015)
    block("Dresser body", (4.22, mid, 0.54), (0.51, far - near, 1.03), oak, 0.018)
    block("Worn lip of dresser", (4.12, mid, 1.07), (0.74, far - near + 0.10, 0.11), trim, 0.023)
    for y in (1.95, 2.64, 3.32, 4.01):
        block("Recessed cupboard door", (3.948, y, 0.55), (0.045, 0.58, 0.78), trim, 0.022)
        for offset in (-0.20, 0.20):
            block("Inset door stile", (3.917, y + offset, 0.55), (0.028, 0.034, 0.61), oak, 0.008)
        oval("Forged pull", (3.893, y + 0.11, 0.79), (0.031, 0.027, 0.027), brass)
    shelf_z = 2.27
    block("Apothecary ledge", (4.25, mid, shelf_z), (0.48, far - near, 0.068), trim, 0.012)
    # The six working ingredients occupy this shelf.
    cx, cy, base = 4.05, 3.64, 1.13
    lathe(
        "Moonbell | thrown planter",
        (cx, cy, base),
        [
            (0.15, 0),
            (0.17, 0.026),
            (0.15, 0.05),
            (0.20, 0.10),
            (0.25, 0.31),
            (0.238, 0.36),
            (0.258, 0.37),
            (0.258, 0.397),
            (0.228, 0.40),
            (0.214, 0.36),
        ],
        clay,
    )
    for z, r in [(0.048, 0.155), (0.34, 0.244), (0.378, 0.261)]:
        line(
            "Inlaid band",
            [
                (cx + r * math.cos(i * math.tau / 48), cy + r * math.sin(i * math.tau / 48), base + z)
                for i in range(48)
            ],
            0.007,
            brass,
            True,
        )
    for i in range(12):
        a = i * math.tau / 12
        points = []
        for k in range(24):
            t = math.tau * k / 24
            z = 0.22 + 0.067 * math.cos(t)
            r = 0.203 + (z - 0.10) * 0.23 + 0.004
            angle = a + 0.115 * math.sin(t)
            points.append((cx + r * math.cos(angle), cy + r * math.sin(angle), base + z))
        line("Slip-painted laurel", (points), 0.004, brass, True)
    soil = material("Dark earth", (0.055, 0.030, 0.014))
    oval("Earth", (cx, cy, base + 0.362), (0.224, 0.224, 0.039), soil)
    origin = (cx, cy, base + 0.38)
    sprout = oval("First cotyledon", (cx, cy, origin[2]+.086), (.024,.018,.085), leaf)
    sprout.rotation_euler.y=.29
    oval("Seed husk", (cx+.031,cy,origin[2]+.15), (.034,.018,.018), petals)
    plant_target = marker("Aim.Moonbell", (cx - 0.19, cy - 0.10, base + 0.22))
    # The lyre box sits on the same wall cabinet. Its lid pivots away from the viewer.
    collection("East wall | singing coffer")
    x, y, z = 4.06, 2.18, 1.13
    block("Resonance box", (x, y, z + 0.14), (0.48, 0.75, 0.28), trim, 0.040)
    block("Soundboard", (x, y, z + 0.291), (0.43, 0.69, 0.029), oak, 0.016)
    for i in range(9):
        yy = y - 0.275 + i * 0.068
        line("Plucked brass string", [(x - 0.17, yy, z + 0.315), (x + 0.15, yy, z + 0.319)], 0.0025, brass)
    hinge = marker("Coffer lid hinge", (x + 0.21, y, z + 0.32))
    attach(block("Walnut lid", (-0.217, 0, 0.036), (0.49, 0.77, 0.079), trim, 0.026), hinge)
    for yy in (-0.268, 0.268):
        attach(block("Lid strap", (-0.218, yy, 0.08), (0.45, 0.037, 0.009), brass, 0.004), hinge)
    for i in range(3):
        r = 0.061 + i * 0.018
        attach(
            line(
                "Pierced rose",
                [
                    (-0.22 + r * math.cos(a * math.tau / 36), r * math.sin(a * math.tau / 36), 0.083)
                    for a in range(36)
                ],
                0.004,
                brass,
                True,
            ),
            hinge,
        )
    for frame, angle in [(1, 0), (215, 0), (245, 72), (267, 72), (290, 0)]:
        hinge.rotation_euler.y = math.radians(angle)
        hinge.keyframe_insert(data_path="rotation_euler", frame=frame)
    attach(block("Escutcheon", (-0.46, 0, -0.006), (0.024, 0.090, 0.115), brass, 0.012), hinge)
    coffer_target = marker("Aim.Coffer", (x - 0.24, y - 0.08, z + 0.18))
    return plant_target, coffer_target
