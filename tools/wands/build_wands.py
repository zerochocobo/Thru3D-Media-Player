"""Model the selectable wands, bake their wood and metal into one texture, export them and render
their menu pictures.

blender --background --factory-startup --python tools/wands/build_wands.py

Each wand is a lathe: a profile of radius along its length, with carving, knots and bends worked into
the vertices. Blender +Y is the length (glTF -Z, Godot's forward), the pommel at the origin and the
tip LENGTH away. UVs give every wand one column of the atlas: u round the shaft, v along it, so the
baked grain runs the length of the wood as it would in a turned dowel.

The atlas stores the surface colour with baked ambient occlusion in RGB and how polished a texel is
in alpha (1 for silver, a little for waxed wood); the headset adds a fixed key light and a glint
(app/godot/assets/wands/wand.gdshader), so the wand reads the same whichever way the hand turns it.
"""
import math
import os
from pathlib import Path

import bmesh
import bpy
import numpy as np
from mathutils import Vector

ROOT = Path(os.environ.get("WAND_ROOT", Path(__file__).resolve().parents[2]))
OUT = ROOT / "app/godot/assets/wands"
WORK = ROOT / "build/wands"
LENGTH = 0.34
SEGMENTS = 24
RINGS = 220
ATLAS = 1024
COLUMN = ATLAS // 5


def smooth(e0, e1, x):
    t = min(1.0, max(0.0, (x - e0) / (e1 - e0)))
    return t * t * (3 - 2 * t)


def bump(x, centre, width):
    return math.exp(-((x - centre) / width) ** 2)


def taper(t, a, b, r0, r1):
    """Radius going from r0 at length a to r1 at length b, slightly convex like a turned shaft."""
    u = min(1.0, max(0.0, (t - a) / (b - a)))
    return r0 + (r1 - r0) * (u ** 1.15)


def tip_round(t, r):
    """Close the last few millimetres into a rounded point."""
    left = LENGTH - t
    if left < r:
        return r * math.sqrt(max(0.0, 1 - ((r - left) / r) ** 2))
    return r


def pommel_round(t, r, depth):
    if t < depth:
        return r * math.sqrt(max(0.0, 1 - ((depth - t) / depth) ** 2))
    return r


# ---- the five profiles: radius(t, angle), centre offset(t), metal(t) -----------------------------

def walnut(t, a):
    # A turned handle: rounded pommel, two beads, a plain grip, a collar, then a long even taper.
    if t < 0.105:
        r = 0.0098
        r += 0.0012 * bump(t, 0.022, 0.0035) + 0.0010 * bump(t, 0.032, 0.003)
        r -= 0.0007 * bump(t, 0.027, 0.0015) + 0.0007 * bump(t, 0.038, 0.0015)
        r += 0.00006 * math.sin(t * 900)  # faint lathe rings on the grip
        r = pommel_round(t, r + 0.0009 * bump(t, 0.008, 0.006), 0.010)
    else:
        r = taper(t, 0.105, LENGTH, 0.0080, 0.0029)
    r += 0.0016 * bump(t, 0.102, 0.0035) - 0.0006 * bump(t, 0.108, 0.0012)
    return tip_round(t, r), (0.0, 0.0), False


def gnarled(t, a):
    # A branch: thick root end, lumps and six knots, bending gently along its length.
    base = taper(t, 0.0, LENGTH, 0.0115, 0.0030)
    lumps = 0.0007 * math.sin(t * 61 + a * 2) + 0.0005 * math.sin(t * 143 + a * 3 + 1.3)
    knots = 0.0
    for centre, angle, size in [(0.03, 0.6, 1.0), (0.075, 3.4, .9), (0.12, 1.9, .8), (0.165, 5.0, .75), (0.215, 2.6, .6), (0.27, 4.4, .45)]:
        da = math.atan2(math.sin(a - angle), math.cos(a - angle))
        knots += 0.0034 * size * bump(t, centre, 0.006) * math.exp(-(da / 0.7) ** 2)
    r = base + lumps * (1 - 0.6 * t / LENGTH) + knots
    r = pommel_round(t, r * (1 + 0.12 * bump(t, 0.006, 0.01)), 0.009)
    offset = (0.006 * math.sin(t * 9.5) + 0.003 * math.sin(t * 23), 0.004 * math.sin(t * 6.2 + 1))
    return tip_round(t, r), offset, False


def ash(t, a):
    # Pale and straight; the handle carries a deep two-start spiral groove under a teardrop pommel.
    if t < 0.11:
        r = 0.0092 + 0.0016 * bump(t, 0.012, 0.009)
        phase = (a / (2 * math.pi)) * 2 + t / 0.03
        groove = 0.5 + 0.5 * math.cos(2 * math.pi * phase)
        r -= 0.0019 * groove ** 6 * smooth(0.018, 0.026, t) * (1 - smooth(0.098, 0.106, t))
        r = pommel_round(t, r, 0.012)
    else:
        r = taper(t, 0.11, LENGTH, 0.0071, 0.0026)
    r += 0.0010 * bump(t, 0.109, 0.003)
    return tip_round(t, r), (0.0, 0.0), False


def ebony(t, a):
    # Black wood with an eight-faceted grip between two silver bands, under a silver cap.
    metal = t < 0.014 or abs(t - 0.046) < 0.0025 or abs(t - 0.100) < 0.003
    if t < 0.014:
        r = 0.0102 + 0.0006 * bump(t, 0.007, 0.002)
        r = pommel_round(t, r, 0.011)
    elif t < 0.100:
        facet = math.cos(math.pi / 8) / math.cos(((a + math.pi / 8) % (math.pi / 4)) - math.pi / 8)
        r = 0.0090 * facet
    else:
        r = taper(t, 0.100, LENGTH, 0.0078, 0.0029)
    if abs(t - 0.046) < 0.0025 or abs(t - 0.100) < 0.003:
        r = max(r, 0.0100 + 0.0003 * math.cos((t - 0.046) * 2000))
    return tip_round(t, r), (0.0, 0.0), metal


def rosewood(t, a):
    # A braided grip: two counter-wound ridges cross over each other, a bulb pommel and a slim shaft.
    if t < 0.112:
        r = 0.0094
        left = 0.5 + 0.5 * math.cos(3 * a + t / 0.0045)
        right = 0.5 + 0.5 * math.cos(3 * a - t / 0.0045)
        r += 0.0011 * (left ** 3 + right ** 3) * smooth(0.024, 0.03, t) * (1 - smooth(0.102, 0.108, t))
        r += 0.0026 * bump(t, 0.011, 0.007)
        r = pommel_round(t, r, 0.012)
    else:
        r = taper(t, 0.112, LENGTH, 0.0076, 0.0028)
        r += 0.0004 * math.cos(6 * a) * (1 - smooth(0.112, 0.15, t))
    r += 0.0012 * bump(t, 0.110, 0.0025)
    return tip_round(t, r), (0.0, 0.0), False


# id, profile, wood colours (dark, light), grain scale, polish of the wood
WANDS = [
    ("walnut", walnut, ((0.035, 0.017, 0.008), (0.16, 0.085, 0.040)), 1.0, 0.25),
    ("gnarled", gnarled, ((0.050, 0.032, 0.019), (0.19, 0.13, 0.075)), 1.6, 0.08),
    ("ash", ash, ((0.28, 0.19, 0.10), (0.60, 0.46, 0.29)), 0.8, 0.22),
    ("ebony", ebony, ((0.012, 0.009, 0.008), (0.075, 0.052, 0.042)), 1.2, 0.45),
    ("rosewood", rosewood, ((0.055, 0.012, 0.008), (0.20, 0.045, 0.026)), 0.9, 0.32),
]


def clear():
    bpy.ops.wm.read_factory_settings(use_empty=True)


def lathe(index, name, profile):
    mesh = bpy.data.meshes.new(name)
    bm = bmesh.new()
    uv = bm.loops.layers.uv.new("UVMap")
    rows = []
    metal_rows = []
    # Denser rings over the handle, where the carving is.
    ts = []
    for i in range(RINGS + 1):
        s = i / RINGS
        ts.append(LENGTH * (0.55 * s + 0.45 * s * s))
    for t in ts:
        row = []
        metal = False
        for j in range(SEGMENTS + 1):
            a = 2 * math.pi * j / SEGMENTS
            r, (ox, oz), m = profile(t, a)
            metal = metal or m
            row.append(bm.verts.new((ox + r * math.cos(a), t, oz + r * math.sin(a))))
        rows.append(row)
        metal_rows.append(metal)
    u0 = index * COLUMN / ATLAS
    du = (COLUMN - 4) / ATLAS
    pad = 2 / ATLAS
    for i in range(RINGS):
        for j in range(SEGMENTS):
            face = bm.faces.new((rows[i][j], rows[i][j + 1], rows[i + 1][j + 1], rows[i + 1][j]))
            for loop, (ii, jj) in zip(face.loops, [(i, j), (i, j + 1), (i + 1, j + 1), (i + 1, j)]):
                loop[uv].uv = (u0 + pad + du * jj / SEGMENTS, ts[ii] / LENGTH)
            face.material_index = 1 if metal_rows[i] and metal_rows[i + 1] else 0
    # Weld the seam column's positions (UVs stay split per face) and close the two ends.
    bm.verts.ensure_lookup_table()
    for i in (0, RINGS):
        centre_t = ts[i]
        r, (ox, oz), m = profile(centre_t, 0)
        cap = bm.verts.new((ox, centre_t, oz))
        for j in range(SEGMENTS):
            verts = (rows[i][j], rows[i][j + 1], cap) if i == RINGS else (rows[i][j + 1], rows[i][j], cap)
            face = bm.faces.new(verts)
            for loop in face.loops:
                loop[uv].uv = (u0 + pad + du * 0.5, 1.0 if i == RINGS else 0.0)
            face.material_index = 1 if metal_rows[i] else 0
    bmesh.ops.remove_doubles(bm, verts=bm.verts[:], dist=1e-7)
    # The rings above wind clockwise seen from outside, which points every normal into the wand; Godot
    # culls back faces, so unflipped the wand shows only the inside of its far wall, like a hollow shell.
    bmesh.ops.reverse_faces(bm, faces=bm.faces[:])
    bm.normal_update()
    # A closed mesh wound outwards encloses a positive signed volume.
    volume = 0.0
    for face in bm.calc_loop_triangles():
        a, b, c = (loop.vert.co for loop in face)
        volume += a.dot(b.cross(c)) / 6.0
    if volume <= 0:
        raise RuntimeError(f"{name}: faces wind into the wand")
    tip = max(bm.faces, key=lambda f: f.calc_center_median().y)
    base = min(bm.faces, key=lambda f: f.calc_center_median().y)
    if tip.normal.y < 0.5 or base.normal.y > -0.5:
        raise RuntimeError(f"{name}: end caps face inwards")
    bm.to_mesh(mesh)
    bm.free()
    for poly in mesh.polygons:
        poly.use_smooth = True
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.scene.collection.objects.link(obj)
    return obj, metal_rows, ts


def wood_material(name, dark, light, scale, seed):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    nodes = mat.node_tree.nodes
    links = mat.node_tree.links
    bsdf = nodes["Principled BSDF"]
    coord = nodes.new("ShaderNodeTexCoord")
    mapping = nodes.new("ShaderNodeMapping")
    # Stretch along the length so figure runs as long streaks, as in a dowel cut along the grain.
    mapping.inputs["Scale"].default_value = (60 * scale, 3.5 * scale, 60 * scale)
    mapping.inputs["Location"].default_value = (seed * 1.7, seed * 0.3, seed * 2.1)
    links.new(coord.outputs["Object"], mapping.inputs["Vector"])
    wave = nodes.new("ShaderNodeTexWave")
    wave.wave_type = "BANDS"
    wave.bands_direction = "X"
    wave.inputs["Scale"].default_value = 0.9
    wave.inputs["Distortion"].default_value = 7.0
    wave.inputs["Detail"].default_value = 3.0
    wave.inputs["Detail Scale"].default_value = 1.4
    links.new(mapping.outputs["Vector"], wave.inputs["Vector"])
    noise = nodes.new("ShaderNodeTexNoise")
    noise.inputs["Scale"].default_value = 3.0
    noise.inputs["Detail"].default_value = 8.0
    noise.inputs["Roughness"].default_value = 0.62
    links.new(mapping.outputs["Vector"], noise.inputs["Vector"])
    fine = nodes.new("ShaderNodeTexNoise")
    fine.inputs["Scale"].default_value = 90.0
    fine.inputs["Detail"].default_value = 2.0
    links.new(mapping.outputs["Vector"], fine.inputs["Vector"])
    mix = nodes.new("ShaderNodeMath")
    mix.operation = "MULTIPLY_ADD"
    links.new(wave.outputs["Fac"], mix.inputs[0])
    mix.inputs[1].default_value = 0.65
    links.new(noise.outputs["Fac"], mix.inputs[2])
    pores = nodes.new("ShaderNodeMath")
    pores.operation = "MULTIPLY_ADD"
    links.new(fine.outputs["Fac"], pores.inputs[0])
    pores.inputs[1].default_value = 0.25
    links.new(mix.outputs[0], pores.inputs[2])
    ramp = nodes.new("ShaderNodeValToRGB")
    ramp.color_ramp.elements[0].position = 0.25
    ramp.color_ramp.elements[0].color = (*dark, 1)
    ramp.color_ramp.elements[1].position = 0.95
    ramp.color_ramp.elements[1].color = (*light, 1)
    links.new(pores.outputs[0], ramp.inputs["Fac"])
    links.new(ramp.outputs["Color"], bsdf.inputs["Base Color"])
    return mat


def silver_material():
    mat = bpy.data.materials.new("Silver")
    mat.use_nodes = True
    nodes = mat.node_tree.nodes
    bsdf = nodes["Principled BSDF"]
    noise = nodes.new("ShaderNodeTexNoise")
    noise.inputs["Scale"].default_value = 400.0
    ramp = nodes.new("ShaderNodeValToRGB")
    ramp.color_ramp.elements[0].color = (0.55, 0.56, 0.58, 1)
    ramp.color_ramp.elements[1].color = (0.80, 0.81, 0.83, 1)
    mat.node_tree.links.new(noise.outputs["Fac"], ramp.inputs["Fac"])
    mat.node_tree.links.new(ramp.outputs["Color"], bsdf.inputs["Base Color"])
    return mat


def bake(objects, kind, image):
    for obj in objects:
        for slot in obj.material_slots:
            nodes = slot.material.node_tree.nodes
            node = nodes.get("Bake target") or nodes.new("ShaderNodeTexImage")
            node.name = "Bake target"
            node.image = image
            nodes.active = node
    bpy.ops.object.select_all(action="DESELECT")
    for obj in objects:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = objects[0]
    scene = bpy.context.scene
    if kind == "DIFFUSE":
        scene.render.bake.use_pass_direct = False
        scene.render.bake.use_pass_indirect = False
        scene.render.bake.use_pass_color = True
    scene.render.bake.margin = 3
    scene.render.bake.use_clear = True
    bpy.ops.object.bake(type=kind)


def pixels(image):
    data = np.empty(ATLAS * ATLAS * 4, dtype=np.float32)
    image.pixels.foreach_get(data)
    return data.reshape(ATLAS, ATLAS, 4)


def main():
    clear()
    WORK.mkdir(parents=True, exist_ok=True)
    OUT.mkdir(parents=True, exist_ok=True)
    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    scene.cycles.device = "CPU"
    scene.cycles.samples = 48
    silver = silver_material()
    objects = []
    polish = np.zeros((ATLAS, ATLAS), dtype=np.float32)
    for index, (name, profile, colours, scale, gloss) in enumerate(WANDS):
        obj, metal_rows, ts = lathe(index, name, profile)
        obj.data.materials.append(wood_material(name + " wood", colours[0], colours[1], scale, index))
        obj.data.materials.append(silver)
        objects.append(obj)
        c0, c1 = index * COLUMN, (index + 1) * COLUMN
        polish[:, c0:c1] = gloss
        for i in range(len(ts) - 1):
            if metal_rows[i] and metal_rows[i + 1]:
                y0, y1 = int(ts[i] / LENGTH * ATLAS), int(math.ceil(ts[i + 1] / LENGTH * ATLAS))
                polish[y0:y1 + 1, c0:c1] = 1.0
    for index, obj in enumerate(objects):
        obj.location.x = index * 0.2
    colour = bpy.data.images.new("wand colour", ATLAS, ATLAS, alpha=True, float_buffer=True)
    occlusion = bpy.data.images.new("wand occlusion", ATLAS, ATLAS, alpha=True, float_buffer=True)
    bake(objects, "DIFFUSE", colour)
    scene.world = bpy.data.worlds.new("bake sky")
    scene.world.light_settings.distance = 0.03
    bake(objects, "AO", occlusion)
    for obj in objects:
        obj.location.x = 0
    rgb = pixels(colour)[..., :3]
    ao = pixels(occlusion)[..., 0:1]
    shaded = rgb * (0.45 + 0.55 * ao)
    # Linear bake → sRGB texture.
    srgb = np.where(shaded <= 0.0031308, shaded * 12.92, 1.055 * np.power(np.clip(shaded, 0, None), 1 / 2.4) - 0.055)
    atlas = np.concatenate([np.clip(srgb, 0, 1), polish[..., None]], axis=2)
    out = bpy.data.images.new("wands", ATLAS, ATLAS, alpha=True)
    out.pixels.foreach_set(atlas.astype(np.float32).ravel())
    out.filepath_raw = str(OUT / "wands.png")
    out.file_format = "PNG"
    out.save()
    # Export with the baked atlas as the only material so the importer sees UVs and one surface.
    baked = bpy.data.materials.new("Wand atlas")
    baked.use_nodes = True
    tex = baked.node_tree.nodes.new("ShaderNodeTexImage")
    tex.image = out
    baked.node_tree.links.new(tex.outputs["Color"], baked.node_tree.nodes["Principled BSDF"].inputs["Base Color"])
    for obj in objects:
        obj.data.materials.clear()
        obj.data.materials.append(baked)
    bpy.ops.object.select_all(action="DESELECT")
    for obj in objects:
        obj.select_set(True)
    bpy.ops.export_scene.gltf(filepath=str(WORK / "wands.glb"), use_selection=True, export_format="GLB",
                              export_apply=True, export_yup=True, export_image_format="NONE")
    bpy.ops.wm.save_as_mainfile(filepath=str(WORK / "wands.blend"))
    render_pictures(objects, out)
    print("WANDS_OK", [w[0] for w in WANDS])


def outline(path):
    """Lift the picture for a dark menu button and ring it with a pale edge so dark wood still reads."""
    image = bpy.data.images.load(str(path))
    w, h = image.size
    data = np.empty(w * h * 4, dtype=np.float32)
    image.pixels.foreach_get(data)
    data = data.reshape(h, w, 4)
    alpha = data[..., 3].copy()
    grown = alpha.copy()
    for dy in (-2, -1, 0, 1, 2):
        for dx in (-2, -1, 0, 1, 2):
            grown = np.maximum(grown, np.roll(np.roll(alpha, dy, 0), dx, 1))
    edge = np.clip(grown - alpha, 0, 1) * 0.55
    rgb = np.clip(data[..., :3] * 1.9 + 0.04, 0, 1)
    pale = np.array([0.93, 0.88, 0.78], dtype=np.float32)
    out_alpha = np.clip(alpha + edge, 0, 1)
    mixed = (rgb * alpha[..., None] + pale * edge[..., None]) / np.maximum(out_alpha[..., None], 1e-4)
    image.pixels.foreach_set(np.concatenate([mixed, out_alpha[..., None]], axis=2).astype(np.float32).ravel())
    image.save()


def render_pictures(objects, atlas):
    """One menu picture per wand (lying corner to corner) and a lineup for review."""
    scene = bpy.context.scene
    scene.render.engine = "BLENDER_EEVEE_NEXT" if "BLENDER_EEVEE_NEXT" in {e.identifier for e in bpy.types.RenderSettings.bl_rna.properties["engine"].enum_items} else "BLENDER_EEVEE"
    scene.render.film_transparent = True
    scene.view_settings.view_transform = "Standard"
    world = scene.world
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs["Color"].default_value = (0.55, 0.52, 0.48, 1)
    world.node_tree.nodes["Background"].inputs["Strength"].default_value = 0.9
    sun = bpy.data.objects.new("key", bpy.data.lights.new("key", "SUN"))
    sun.data.energy = 3.2
    sun.rotation_euler = (math.radians(50), math.radians(-30), math.radians(20))
    scene.collection.objects.link(sun)
    camera = bpy.data.objects.new("camera", bpy.data.cameras.new("camera"))
    camera.data.type = "ORTHO"
    scene.collection.objects.link(camera)
    scene.camera = camera
    for obj in objects:
        obj.hide_render = True
    for obj in objects:
        obj.hide_render = False
        obj.rotation_euler = (0, 0, math.radians(-45))
        obj.location = (0, 0, 0)
        # The handle is what tells the wands apart: frame it and the start of the shaft.
        along = 0.095
        mid = Vector((along * math.sin(math.radians(45)), along * math.cos(math.radians(45)), 0))
        camera.location = mid + Vector((0, 0, 1))
        camera.rotation_euler = (0, 0, 0)
        camera.data.ortho_scale = 0.15
        scene.render.resolution_x = scene.render.resolution_y = 192
        scene.render.filepath = str(OUT / ("%s.png" % obj.name))
        bpy.ops.render.render(write_still=True)
        obj.hide_render = True
        outline(OUT / ("%s.png" % obj.name))
    # Lineup: all five upright, pommel down.
    for i, obj in enumerate(objects):
        obj.hide_render = False
        obj.rotation_euler = (math.radians(-90), 0, 0)
        obj.rotation_euler = (0, 0, 0)
        obj.location = (i * 0.06 - 0.12, 0, 0)
    camera.location = (0, LENGTH * 0.5, 1)
    camera.data.ortho_scale = LENGTH * 1.08
    scene.render.resolution_x = 900
    scene.render.resolution_y = 1000
    scene.render.film_transparent = False
    scene.render.filepath = str(WORK / "lineup.png")
    bpy.ops.render.render(write_still=True)


main()
