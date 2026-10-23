"""Preview renders for seat_model (run headless):

blender --background --factory-startup --python tools/cinema/preview_seat.py -- [out_dir] [texture_size]

Renders are Workbench FLAT with the baked texture, i.e. exactly what the unlit runtime shows.
Gap checks use a bright background so any see-through slot along a row stands out.
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
SEAT_ENVELOPE = ((-0.545, -0.38, 0.0), (0.36, 0.42, 1.08))
PITCH = seat_model.SEAT_PITCH
ROW_DEPTH, TIER = 1.25, 0.45
EYE = Vector((0.0, -0.10, 1.20))
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


def report(obj, label, envelope=None):
    lo, hi = bbox(obj)
    ok = envelope is None or all(envelope[0][i] <= lo[i] and hi[i] <= envelope[1][i] for i in range(3))
    near = min((v.co - EYE).length for v in obj.data.vertices)
    uv = obj.data.uv_layers[seat_model.UV_NAME].data
    print("%s tris=%d verts=%d bbox=(%.4f, %.4f, %.4f)..(%.4f, %.4f, %.4f) envelope_ok=%s eye_clearance=%.3f "
          "uv=[%.3f..%.3f]x[%.3f..%.3f] materials=%s uvmaps=%s"
          % (label, seat_model.triangle_count(obj), len(obj.data.vertices), lo.x, lo.y, lo.z, hi.x, hi.y, hi.z,
             ok, near, min(d.uv.x for d in uv), max(d.uv.x for d in uv), min(d.uv.y for d in uv),
             max(d.uv.y for d in uv), [m.name for m in obj.data.materials], [u.name for u in obj.data.uv_layers]))


def camera(name, loc, target, lens=50):
    cam_data = bpy.data.cameras.new(name)
    cam_data.lens = lens
    cam_data.clip_start = 0.02
    cam = bpy.data.objects.new(name, cam_data)
    bpy.context.scene.collection.objects.link(cam)
    cam.location = loc
    cam.rotation_euler = (Vector(target) - Vector(loc)).to_track_quat("-Z", "Y").to_euler()
    return cam


def render(cam, filename, bright=False):
    scene = bpy.context.scene
    scene.camera = cam
    scene.display.shading.light = "FLAT"
    scene.display.shading.color_type = "TEXTURE"
    scene.display.shading.background_color = (0.85, 0.85, 0.9) if bright else (0.06, 0.06, 0.07)
    path = os.path.join(OUT, filename)
    scene.render.filepath = path
    bpy.ops.render.render(write_still=True)
    print("rendered", path)


def build_row(prefix, lod, y, z):
    xs = [(i - 1.5) * PITCH for i in range(4)]
    objs = []
    for i, x in enumerate(xs):
        s = seat_model.build_seat("%s_%d" % (prefix, i), lod)
        s.location = (x, y, z)
        objs.append(s)
    end = seat_model.build_end_armrest(prefix + "_end", lod)
    end.location = (xs[-1] + PITCH / 2, y, z)
    objs.append(end)
    return objs


clear_scene()
seat_model.build_seat("Probe", 0)  # material exists before the bake, as in the hall script
t = time.time()
texture = os.path.join(OUT, "seat_baked.png")
seat_model.bake_seat_texture(texture, SIZE)
print("BAKE_SECONDS %.1f" % (time.time() - t))
for obj in list(bpy.data.objects):
    bpy.data.objects.remove(obj)
print("AFTER_BAKE datablocks:", [m.name for m in bpy.data.materials] + [i.name for i in bpy.data.images]
      + [s.name for s in bpy.data.scenes] + [w.name for w in bpy.data.worlds])

for lod in (0, 1):
    report(seat_model.build_seat("CheckSeat%d" % lod, lod), "SEAT_LOD%d" % lod, SEAT_ENVELOPE)
    report(seat_model.build_end_armrest("CheckEnd%d" % lod, lod), "END_LOD%d" % lod)
for obj in list(bpy.data.objects):
    bpy.data.objects.remove(obj)

mat = seat_model.seat_material(texture)
mat.use_backface_culling = True
scene = bpy.context.scene
scene.render.engine = "BLENDER_WORKBENCH"
scene.render.resolution_x = 1280
scene.render.resolution_y = 800
scene.display.shading.show_backface_culling = True
scene.display.shading.background_type = "VIEWPORT"
scene.view_settings.view_transform = "Standard"

front = build_row("Row0", 0, 0.0, 0.0)                     # inspected row
back = build_row("Row1", 0, -ROW_DEPTH, TIER)              # row behind (viewer's own seats)
seat_eye = Vector((-0.45, -ROW_DEPTH - 0.10, TIER + 1.20))  # seated eye in the row behind

render(camera("Front34", (2.6, 3.0, 1.5), (0.0, 0.0, 0.55), 35), "row_front34.png")
render(camera("Grazing", (3.4, 1.6, 0.62), (-1.0, -0.05, 0.55), 40), "row_grazing_front.png", bright=True)
render(camera("GrazingLow", (0.2, 3.2, 0.42), (0.2, -0.2, 0.62), 45), "row_front_low.png", bright=True)
render(camera("BehindAbove", (0.5, -3.4, 2.6), (0.0, -0.2, 0.6), 40), "row_behind_above.png", bright=True)
render(camera("BehindClose", seat_eye + Vector((0.15, 0.0, 0.0)), (-0.45, -0.30, 0.80), 40), "behind_close.png")
render(camera("CloseCup", (0.65, 1.0, 1.05), (0.0, 0.25, 0.64), 40), "close_cupholder.png")
render(camera("Upholstery", (0.25, 0.85, 1.0), (-0.45, -0.10, 0.62), 40), "close_upholstery.png")
for obj in front:
    obj.hide_render = True
# Own two consoles (x = -0.9 and 0.0 relative to the seat at -0.45) from the seated eye.
render(camera("ArmEye", seat_eye, (-0.45, -ROW_DEPTH + 0.45, TIER + 0.50), 16), "armrest_eye.png")
for obj in front:
    obj.hide_render = False
for obj in front + back:
    obj.hide_render = True
far = build_row("Far", 1, 0.0, 0.0)
render(camera("FarRow", (1.8, -3.0, 2.0), (0.0, 0.0, 0.6), 40), "row_lod1_behind.png", bright=True)
print("DONE")
