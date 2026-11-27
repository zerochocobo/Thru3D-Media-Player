"""Build and verify the coastal hall master, then optionally render its camera views."""

import math
import subprocess
import sys
from pathlib import Path

import bpy
from mathutils import Vector


sys.path.insert(0, str(Path(__file__).resolve().parent))
from hall_mesh import (
    beam,
    bevel,
    block,
    collection,
    lathe,
    marker,
    material,
    mottling,
    oval,
    packed_image,
    prism,
    scan_surface,
)
from hall_stonework import compass, masonry, wand_demo
from workshop_model import sofa, sky, furnishings
from wall_furnishings import herbarium, library

SEAT_Y = -1.82
ROOT = Path(__file__).resolve().parents[2]
ART = ROOT / "docs/design/magic-cottage"
OUT = ROOT / "build/magic-cottage-design"
OUT.mkdir(parents=True, exist_ok=True)
bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
scene.unit_settings.system = "METRIC"


collection("Fabric | main structure")
texture_origin = marker("Survey origin", (0, 0, 0), 0.04)
stone = material("Limewashed stone", (0.34, 0.29, 0.23))
archstone = [
    material("Arch stone %d" % i, (0.35 + i * 0.018, 0.27 + i * 0.018, 0.18 + i * 0.016)) for i in range(4)
]
oak = material("Hewn oak", (0.14, 0.066, 0.030))
oak_light = material("Worn oak", (0.28, 0.145, 0.064))
slate = material("Roof underside", (0.13, 0.097, 0.079))

clay = material("Unglazed clay", (0.35, 0.135, 0.061))
green = material("Moonbell leaf", (0.095, 0.21, 0.12))
blue = material("Moonbell flower", (0.22, 0.41, 0.85), 0.40, glow=0.52)
brass = material("Hammered brass", (0.57, 0.33, 0.089), 0.37, 0.68)
linen = material("Linen and beeswax", (0.72, 0.60, 0.40))
water = material("Tidal star mirror", (0.019, 0.045, 0.105), 0.33)
mottling(clay, 4.5, (0.11, 0.040, 0.018), (0.49, 0.205, 0.066), 0.0025)
clay.node_tree.nodes["Principled BSDF"].inputs["Coat Weight"].default_value = 0.20
mottling(green, 4, (0.032, 0.087, 0.051), (0.18, 0.305, 0.12), 0.0017)
mottling(blue, 3.5, (0.10, 0.18, 0.43), (0.34, 0.52, 0.94), 0.0010)
mottling(brass, 5, (0.16, 0.084, 0.029), (0.66, 0.39, 0.12), 0.0016)

beach = ROOT / "tools/beach/source"
grain = packed_image(beach / "textures/wood_table_001_diff_2k.jpg")
rock = packed_image(beach / "textures/rock_boulder_dry_diff_2k.jpg")
scan_surface(oak, grain, (0.34, 0.175, 0.09), texture_origin, (0.95, 0.63, 1.1), 0.018)
scan_surface(oak_light, grain, (0.64, 0.37, 0.17), texture_origin, (1.0, 0.72, 1.05), 0.014)
scan_surface(stone, rock, (0.75, 0.65, 0.55), texture_origin, (0.53, 0.53, 0.53), 0.033)
scan_surface(slate, grain, (0.30, 0.21, 0.16), texture_origin, (1.2, 0.55, 1), 0.019)
for i, mat in enumerate(archstone):
    scan_surface(
        mat,
        rock,
        (0.74 + i * 0.085, 0.66 + i * 0.063, 0.54 + i * 0.045),
        texture_origin,
        (0.72, 0.72, 0.72),
        0.030,
    )

# Width 9 m, depth 7.2 m. In Blender the sitter looks along +Y.
block("Floor", (0, 1.30, -0.10), (9, 7.2, 0.20), stone)

for sign in (-1, 1):
    block("Side masonry", (sign * 4.59, 1.30, 1.75), (0.18, 7.2, 3.5), stone)
block("Rear wall", (0, -2.39, 1.75), (9.18, 0.18, 3.5), stone)
prism("Rear gable", [(-4.5, 3.5), (4.5, 3.5), (0, 5.2)], -2.48, -2.30, stone)


def roof_height(x):
    return 5.20 - 1.70 * abs(x) / 4.5


def gable_piece(name, x0, x1, base0, base1):
    prism(name, [(x0, base0), (x1, base1), (x1, roof_height(x1)), (x0, roof_height(x0))], 4.90, 5.16, stone)


# Solid gable with genuine openings. Individual voussoirs show recess depth.
for lo, hi in [(-4.5, -4.12), (-2.88, -2.65), (2.65, 2.88), (4.12, 4.5)]:
    gable_piece("Gable pier", lo, hi, 0, 0)
for centre in (-3.50, 3.50):
    half, sill, shoulder, crown = 0.62, 0.71, 2.52, 3.25
    block("Window sill", (centre, 5.03, sill / 2), (2 * half, 0.26, sill), stone)
    for sign in (-1, 1):
        edge = centre + sign * half
        # Split the pointed arch into dressed wedge stones with individual reveals.
        rim = [
            (
                edge - sign * half * (1 - math.cos(i * math.pi / 16)),
                shoulder + (crown - shoulder) * math.sin(i * math.pi / 16),
            )
            for i in range(9)
        ]
        for i, (p, q) in enumerate(zip(rim, rim[1:])):
            left, right = sorted((p, q))
            gable_piece("Lancet arch", left[0], right[0], left[1], right[1])
            extra_p = (p[0] + sign * 0.082 * (1 - i / 8), p[1] + 0.085 * i / 8)
            extra_q = (q[0] + sign * 0.082 * (1 - (i + 1) / 8), q[1] + 0.085 * (i + 1) / 8)
            bevel(prism("Lancet voussoir", [p, q, extra_q, extra_p], 4.78, 4.99, archstone[i % 4]), 0.008)
        block("Jamb", (edge, 4.87, (sill + shoulder) / 2), (0.12, 0.23, shoulder - sill), archstone[1])
        block("Open wooden shutter", (edge + sign * 0.20, 4.83, 1.59), (0.28, 0.07, 1.68), oak)
    block("Recessed sill lip", (centre, 4.83, sill), (1.42, 0.48, 0.14), archstone[1])

radius, spring = 2.65, 1.88
arc = [
    (radius * math.cos(math.pi * i / 32), spring + radius * math.sin(math.pi * i / 32)) for i in range(33)
]
mirror = prism("Still water in stone portal", [(-radius, 0.12), (radius, 0.12), *arc], 4.80, 4.84, water)
sky(scene, mirror, ROOT / "app/godot/environments/magic_cottage/star-atlas.jpg")
for i, (a, b) in enumerate(zip(arc, arc[1:])):
    gable_piece("Portal spandrel", b[0], a[0], b[1], a[1])
    outer = [(x * 1.065, spring + (z - spring) * 1.065) for x, z in (a, b)]
    bevel(prism("Portal arch stone", [b, a, *outer], 4.72, 4.94, archstone[i % 4]), 0.012)
for sign in (-1, 1):
    for course in range(6):
        block(
            "Portal jamb",
            (sign * 2.72, 4.85, (course + 0.5) * spring / 6),
            (0.15, 0.25, spring / 6 - 0.012),
            archstone[course % 4],
        )
block("Mirror threshold", (0, 4.80, 0.07), (5.44, 0.28, 0.14), archstone[1])
for sign in (-1, 1):
    prism(
        "Pitched roof", [(0, 5.20), (sign * 4.58, 3.47), (sign * 4.58, 3.61), (0, 5.34)], -2.48, 5.22, slate
    )
for y in (-1.8, 0.55, 2.85, 4.60):
    for sign in (-1, 1):
        block("Oak post", (sign * 4.30, y, 1.72), (0.24, 0.24, 3.44), oak)
        beam("Rafter", (sign * 4.37, y, 3.39), (0, y, 5.14), 0.22, 0.24, oak)
        beam("Knee brace", (sign * 4.30, y, 2.42), (sign * 3.36, y, 3.51), 0.16, 0.20, oak)
    block("Collar tie", (0, y, 4.42), (3.86, 0.18, 0.18), oak)

masonry(archstone, oak, oak_light, brass)
sofa()
paper = material("Handmade vellum", (0.81, 0.65, 0.40), 0.91)
mottling(paper, 5, (0.47, 0.31, 0.15), (0.91, 0.77, 0.52), 0.0007)
book_targets, iron = library(oak, oak_light, brass, paper, SEAT_Y, packed_image(ART / "moonbell-folio.png"))
plant_target, music_target = herbarium(oak, oak_light, clay, brass, green, blue)
furnishings(oak, brass, iron, clay, paper)
collection("Front wall | mirror seal")
mirror_target = compass(-2.70, 4.66, 1.19, 0.18, brass, iron, "Hammered star seal")
targets = [*book_targets, plant_target, music_target, mirror_target]
scene.frame_set(1)
wand_demo(
    SEAT_Y,
    *(t.matrix_world.translation.copy() for t in (book_targets[1], music_target, plant_target)),
    oak_light,
    brass,
)


def lamp(name, at, energy, colour, radius):
    light = bpy.data.lights.new(name, "POINT")
    light.energy, light.color, light.shadow_soft_size = energy, colour, radius
    obj = bpy.data.objects.new(name, light)
    bpy.context.collection.objects.link(obj)
    obj.location = at


collection("Lighting | candles and coastal fill")
wax = material("Beeswax", (0.82, 0.57, 0.27), 0.48)
flame_mat = material("Candle wick glow", (1, 0.48, 0.12), 0.4, glow=5.5)
for x, y, z in [
    (-3.5, 4.72, 0.80),
    (3.5, 4.72, 0.80),
    (-4.05, 1.87, 2.53),
    (4.06, 2.86, 1.13),
    (-4.03, 4.20, 2.53),
    (4.16, 4.28, 2.32),
]:
    lathe(
        "Pottery candle dish",
        (x, y, z),
        [(0.055, 0), (0.07, 0.014), (0.12, 0.031), (0.12, 0.045), (0.11, 0.046), (0.07, 0.028)],
        clay,
    )
    for dx, dy, h in [(-0.042, 0.014, 0.15), (0.038, 0.008, 0.105), (0, -0.034, 0.20)]:
        lathe(
            "Beeswax taper",
            (x + dx, y + dy, z + 0.03),
            [(0.028, 0), (0.027, h - 0.012), (0.029, h), (0.020, h - 0.008)],
            wax,
            16,
        )
        oval("Wick flame", (x + dx, y + dy, z + h + 0.048), (0.010, 0.010, 0.028), flame_mat)
    lamp("Candle pool", (x, y - 0.12, z + 0.28), 39, (1, 0.53, 0.23), 0.14)
lamp("Window daylight", (0, 3.8, 3.38), 510, (0.62, 0.73, 1), 1.7)
lamp("Soft reflected candlelight", (0, -0.55, 3.15), 185, (1, 0.72, 0.48), 1.8)
lamp("West bay reflected light", (-3.42, 2.78, 2.30), 74, (1, 0.65, 0.34), 0.74)
lamp("East bay reflected light", (3.46, 3.03, 2.17), 85, (1, 0.68, 0.45), 0.68)

# Both lancets look into the procedural star field.

collection("Camera views")


def camera(name, location, aim, lens):
    bpy.ops.object.camera_add(location=location)
    obj = bpy.context.object
    obj.name = name
    obj.rotation_euler = (Vector(aim) - Vector(location)).to_track_quat("-Z", "Y").to_euler()
    obj.data.lens, obj.data.sensor_width = lens, 36
    return obj


cam = camera("Seated eye 1.15 m", (0, SEAT_Y, 1.15), (0, 4.8, 1.71), 16)
west = camera("West library detail", (-1.48, 1.34, 1.68), (-4.10, 3.03, 1.50), 31)
east = camera("East herbarium detail", (1.36, 1.56, 1.83), (4.06, 3.14, 1.54), 32)
scene.camera = cam
scene.frame_end = 365
scene.render.fps = 30
for frame, title in [
    (1, "At rest"),
    (24, "Summon the herbal"),
    (102, "Read"),
    (148, "Return to the shelf"),
    (209, "Shelved"),
    (216, "Sound the coffer"),
    (307, "Wake the moonbell"),
    (365, "Return wand to wall"),
]:
    scene.timeline_markers.new(title, frame=frame)
scene.frame_set(1)
for area in bpy.context.screen.areas:
    if area.type == "VIEW_3D":
        view = area.spaces.active
        view.region_3d.view_perspective = "CAMERA"
        view.shading.type = "MATERIAL"
        view.shading.use_scene_world = True
        view.shading.use_scene_lights = True
scene.render.engine = "CYCLES"
scene.cycles.samples = 24
scene.cycles.use_denoising = True
scene.render.resolution_x, scene.render.resolution_y = 1600, 900
scene.render.resolution_percentage = 100
scene.render.image_settings.file_format = "PNG"
scene.render.filepath = "//seated-layout.png"

# Trace against the actual meshes before saving a model with a clipped film
# corner or a landmark hidden directly behind the shelf or plant.
bpy.context.view_layer.update()
depsgraph = bpy.context.evaluated_depsgraph_get()
for eye_x in (-0.15, 0, 0.15):
    for eye_z in (0.95, 1.15, 1.35):
        eye = Vector((eye_x, SEAT_Y, eye_z))
        for film_x in (-2.25, 0, 2.25):
            for film_z in (1.75 - 4.5 * 9 / 32, 1.75, 1.75 + 4.5 * 9 / 32):
                direction = Vector((film_x, 4.80, film_z)) - eye
                hit, _, _, _, obj, _ = scene.ray_cast(depsgraph, eye, direction.normalized())
                assert hit and obj.name == "Still water in stone portal", (eye, film_x, film_z, obj)
for sign in (-1, 1):
    direction = Vector((sign * 3.50, 4.90 - SEAT_Y, 0.04)).normalized()
    hit, _, _, _, obj, _ = scene.ray_cast(depsgraph, cam.location, direction)
    assert hit and obj.name.startswith("Glazed lancet"), ("Window glazing", sign, obj)
distances = {}
for obj in scene.objects:
    if obj.type not in {"MESH", "CURVE"}:
        continue
    group = obj.users_collection[0].name
    corners = [obj.matrix_world @ Vector(corner) for corner in obj.bound_box]
    if group.startswith(("West wall", "East wall", "Manuscript")):
        assert all(abs(p.x) >= 3.60 for p in corners), ("Furniture in aisle", obj.name)
    elif group.startswith("South wall"):
        assert all(p.y <= -1.37 for p in corners), ("Chair placement", obj.name)
for target in targets:
    point = target.matrix_world.translation
    distances[target.name] = round((point - cam.location).length, 2)
    assert distances[target.name] > 4.5
    # There must be a continuous path from either hand to the object's own geometry.
    owner = target.users_collection[0]
    for side in (-1, 1):
        for height in (0.95, 1.15, 1.35):
            origin = Vector((side * 0.26, SEAT_Y + 0.22, height - 0.31))
            hit, pos, _, _, obj, _ = scene.ray_cast(depsgraph, origin, (point - origin).normalized())
            assert hit and owner in obj.users_collection and (pos - point).length < 0.13, (
                target.name,
                obj,
                pos,
                point,
            )

herbal = bpy.data.objects["Moonbell herbal"]
home_pose = herbal.matrix_world.copy()
scene.frame_set(112)
assert (herbal.matrix_world.translation - cam.location).length < 1.15
scene.frame_set(208)
assert (herbal.matrix_world.translation - home_pose.translation).length < 0.001
for frame, target in [(23, book_targets[1]), (216, music_target), (307, plant_target)]:
    scene.frame_set(frame)
    stick = bpy.data.objects["Hazel wand"].matrix_world
    look = (target.matrix_world.translation - stick.translation).normalized()
    assert (stick.to_quaternion() @ Vector((0, 0, 1))).dot(look) > 0.995, ("Wand alignment", frame)
scene.frame_set(245)
assert bpy.data.objects["Coffer lid hinge"].rotation_euler.y > 1.1
scene.frame_set(332)
assert bpy.data.objects.get("First cotyledon") is not None
scene.frame_set(1)
print("HALL_MODEL_OK: 81 film rays, two windows, 36 wand rays; distances", distances)
bpy.context.preferences.filepaths.save_version = 0
scene.render.filepath = "//seated-layout.png"
bpy.ops.wm.save_as_mainfile(filepath=str(OUT / "great-hall.blend"), compress=True)
if "--render-layout" in sys.argv:
    for view, frame, image_name in [
        (cam, 1, "seated-layout"),
        (west, 1, "library"),
        (east, 1, "herbarium"),
        (cam, 112, "reading"),
    ]:
        scene.camera = view
        scene.frame_set(frame)
        scene.render.filepath = str(OUT / (image_name + ".png"))
        bpy.ops.render.render(write_still=True)
if "--render-motion" in sys.argv:
    scene.camera = cam
    scene.cycles.samples = 5
    scene.render.resolution_percentage = 55
    scene.render.use_persistent_data = True
    frames = OUT / "motion-frames"
    frames.mkdir(exist_ok=True)
    for index, frame in enumerate(range(1, scene.frame_end + 1, 3)):
        scene.frame_set(frame)
        scene.render.filepath = str(frames / f"{index:04}.png")
        bpy.ops.render.render(write_still=True)
    subprocess.run(
        [
            "ffmpeg",
            "-v",
            "error",
            "-nostdin",
            "-y",
            "-framerate",
            "10",
            "-start_number",
            "0",
            "-i",
            str(frames / "%04d.png"),
            "-frames:v",
            str(index + 1),
            "-c:v",
            "libx264",
            "-crf",
            "19",
            "-vf",
            "pad=ceil(iw/2)*2:ceil(ih/2)*2",
            "-pix_fmt",
            "yuv420p",
            "-movflags",
            "+faststart",
            str(OUT / "wand-study.mp4"),
        ],
        check=True,
    )
