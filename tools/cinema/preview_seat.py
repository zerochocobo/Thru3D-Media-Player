"""Preview renders for seat_model (run headless):

blender --background --factory-startup --python tools/cinema/preview_seat.py -- [out_dir] [texture_size]
"""

import importlib
import os
import sys
import time

import bpy
from mathutils import Vector

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)
import seat_model  # noqa: E402

importlib.reload(seat_model)

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
OUT = os.path.abspath(argv[0] if argv else os.path.join(HERE, "..", "..", "tmp", "cinema-seat"))
SIZE = int(argv[1]) if len(argv) > 1 else 2048
ENVELOPE = ((-0.38, -0.38, 0.0), (0.38, 0.42, 1.08))
PITCH = 0.80
os.makedirs(OUT, exist_ok=True)


def clear_scene():
    for obj in list(bpy.data.objects):
        bpy.data.objects.remove(obj)
    for coll in (bpy.data.meshes, bpy.data.materials, bpy.data.cameras, bpy.data.lights, bpy.data.images):
        for item in list(coll):
            if item.users == 0:
                coll.remove(item)


def bbox(obj):
    xs = [v.co for v in obj.data.vertices]
    lo = Vector((min(v.x for v in xs), min(v.y for v in xs), min(v.z for v in xs)))
    hi = Vector((max(v.x for v in xs), max(v.y for v in xs), max(v.z for v in xs)))
    return lo, hi


def report(obj, lod):
    lo, hi = bbox(obj)
    tris = seat_model.triangle_count(obj)
    ok = all(ENVELOPE[0][i] <= lo[i] and hi[i] <= ENVELOPE[1][i] for i in range(3))
    eye = Vector((0.0, -0.10, 1.20))
    near = min((v.co - eye).length for v in obj.data.vertices)
    uv = obj.data.uv_layers[seat_model.UV_NAME].data
    us = [d.uv.x for d in uv]
    vs = [d.uv.y for d in uv]
    print("LOD%d tris=%d verts=%d bbox=(%.4f, %.4f, %.4f)..(%.4f, %.4f, %.4f) contract=%s eye_clearance=%.3f "
          "uv=[%.3f..%.3f]x[%.3f..%.3f] materials=%s uvmaps=%s"
          % (lod, tris, len(obj.data.vertices), lo.x, lo.y, lo.z, hi.x, hi.y, hi.z, ok, near,
             min(us), max(us), min(vs), max(vs), [m.name for m in obj.data.materials],
             [u.name for u in obj.data.uv_layers]))


def camera(name, loc, target, lens=50):
    cam_data = bpy.data.cameras.new(name)
    cam_data.lens = lens
    cam = bpy.data.objects.new(name, cam_data)
    bpy.context.scene.collection.objects.link(cam)
    cam.location = loc
    direction = Vector(target) - Vector(loc)
    cam.rotation_euler = direction.to_track_quat("-Z", "Y").to_euler()
    return cam


def render(cam, filename, lit):
    scene = bpy.context.scene
    scene.camera = cam
    shading = scene.display.shading
    shading.light = "STUDIO" if lit else "FLAT"
    shading.color_type = "TEXTURE"
    path = os.path.join(OUT, filename)
    scene.render.filepath = path
    bpy.ops.render.render(write_still=True)
    print("rendered", path)


clear_scene()
seat_model.build_seat("Probe", 0)  # material creation before bake (as the hall script would)
t = time.time()
texture = os.path.join(OUT, "seat_baked.png")
seat_model.bake_seat_texture(texture, SIZE)
print("BAKE_SECONDS %.1f" % (time.time() - t))
for obj in list(bpy.data.objects):
    bpy.data.objects.remove(obj)

leftovers = [m.name for m in bpy.data.materials] + [i.name for i in bpy.data.images] + \
    [s.name for s in bpy.data.scenes] + [w.name for w in bpy.data.worlds]
print("AFTER_BAKE datablocks:", leftovers)

near = seat_model.build_seat("SeatLOD0", 0)
far = seat_model.build_seat("SeatLOD1", 1)
report(near, 0)
report(far, 1)
near.location.x = -0.45
far.location.x = 0.45
mat = seat_model.seat_material(texture)
mat.use_backface_culling = True

scene = bpy.context.scene
scene.render.engine = "BLENDER_WORKBENCH"
scene.render.resolution_x = 1280
scene.render.resolution_y = 800
scene.display.shading.show_backface_culling = True
scene.display.shading.background_type = "VIEWPORT"
scene.display.shading.background_color = (0.06, 0.06, 0.07)
scene.view_settings.view_transform = "Standard"
scene.world = bpy.data.worlds.new("PreviewWorld") if not scene.world else scene.world
scene.world.color = (0.05, 0.05, 0.06)

render(camera("Front", (1.4, 2.3, 1.35), (0.0, 0.0, 0.56), 50), "front34.png", False)
render(camera("FrontLit", (1.4, 2.3, 1.35), (0.0, 0.0, 0.56), 50), "front34_lit.png", True)
render(camera("Rear", (-1.3, -2.2, 1.7), (0.0, 0.0, 0.60), 50), "rear34.png", False)
render(camera("Straight", (-0.45, 1.8, 1.25), (-0.45, 0.0, 0.58), 50), "front_lod0.png", False)
# The viewer's own right armrest and cup holder, seen from the seated eye point.
render(camera("Arm", (-0.45 + 0.02, -0.02, 1.15), (-0.45 + 0.33, 0.34, 0.64), 30), "armrest_eye.png", False)
render(camera("Close", (0.25, 0.95, 1.0), (-0.12, 0.30, 0.64), 40), "close_cupholder.png", False)

# Two rows of eight; the camera sits two rows back at seated eye height, ~3 m from the front row.
for obj in (near, far):
    obj.hide_render = True
for tier in range(3):
    for i in range(8):
        s = seat_model.build_seat("Row%d_%d" % (tier, i), 0 if tier else 1)
        s.location = ((i - 3.5) * PITCH, -tier * 1.25, tier * 0.45)
render(camera("Row", (0.3, -3.75, 1.35 + 1.20), (0.0, -0.6, 0.9), 40), "row8.png", False)
render(camera("RowFront", (3.0, 3.8, 2.0), (0.0, -0.8, 0.6), 35), "row8_front.png", False)
print("DONE")
