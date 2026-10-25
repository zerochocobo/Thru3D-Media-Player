"""Builds, lights, bakes and exports the giant-screen auditorium from its manifest.

blender --background --factory-startup --python tools/cinema/build_hall.py -- \
    --manifest app/godot/environments/grand_cinema/manifest.json \
    --out app/godot/environments/grand_cinema/cinema.glb [--atlas 4096] [--samples 160] [--preview DIR]

The manifest (from cinema_blueprint.gd) owns every walkable and collidable
dimension. This script only adds the visible architecture around those
volumes, so navigation and the model cannot drift apart. Lighting is baked
with Cycles: the screen is the dominant emitter, plus step, sconce and exit
lights. The export is unlit, so headsets pay no runtime lighting cost.
"""

import argparse
import json
import math
import os
import random
import sys
import time

import bmesh
import bpy
from mathutils import Matrix, Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

# --------------------------------------------------------------------------
# Arguments and coordinates

def parse_args():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--atlas", type=int, default=2048)
    parser.add_argument("--samples", type=int, default=160)
    parser.add_argument("--seat-texture", type=int, default=1024)
    parser.add_argument("--preview", default="")
    parser.add_argument("--quick", action="store_true", help="Low-quality bake for layout iteration")
    parser.add_argument("--save-blend", default="")
    parser.add_argument("--work", default="tmp/cinema-build")
    parser.add_argument("--placeholder-seats", action="store_true")
    return parser.parse_args(argv)


def G(x, y, z):
    """Godot (Y up, screen towards -Z) to Blender (Z up). A proper rotation."""
    return Vector((x, -z, y))


# --------------------------------------------------------------------------
# Geometry accumulation in Godot space

class Builder:
    def __init__(self, name):
        self.name = name
        self.verts = []
        self.faces = []
        self.face_mats = []
        self.mats = []

    def _mat(self, key):
        if key not in self.mats:
            self.mats.append(key)
        return self.mats.index(key)

    def poly(self, points, key):
        """Counter-clockwise when seen from the visible side (Godot space)."""
        start = len(self.verts)
        self.verts.extend(G(*p) for p in points)
        self.faces.append(tuple(range(start, start + len(points))))
        self.face_mats.append(self._mat(key))

    def quad_facing(self, a, b, c, d, key, normal):
        """Adds a quad and flips its winding so it faces `normal` (Godot space)."""
        va, vb, vc = Vector(a), Vector(b), Vector(c)
        if (vb - va).cross(vc - va).dot(Vector(normal)) < 0:
            a, b, c, d = d, c, b, a
        self.poly([a, b, c, d], key)

    def box(self, lo, hi, key, faces="+x-x+y-y+z-z"):
        x0, y0, z0 = lo
        x1, y1, z1 = hi
        if "+x" in faces: self.quad_facing((x1, y0, z0), (x1, y1, z0), (x1, y1, z1), (x1, y0, z1), key, (1, 0, 0))
        if "-x" in faces: self.quad_facing((x0, y0, z0), (x0, y0, z1), (x0, y1, z1), (x0, y1, z0), key, (-1, 0, 0))
        if "+y" in faces: self.quad_facing((x0, y1, z0), (x0, y1, z1), (x1, y1, z1), (x1, y1, z0), key, (0, 1, 0))
        if "-y" in faces: self.quad_facing((x0, y0, z0), (x1, y0, z0), (x1, y0, z1), (x0, y0, z1), key, (0, -1, 0))
        if "+z" in faces: self.quad_facing((x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1), key, (0, 0, 1))
        if "-z" in faces: self.quad_facing((x0, y0, z0), (x0, y1, z0), (x1, y1, z0), (x1, y0, z0), key, (0, 0, -1))

    def tube(self, start, end, radius, key, segments=8):
        s, e = Vector(start), Vector(end)
        axis = (e - s).normalized()
        helper = Vector((0, 1, 0)) if abs(axis.y) < 0.9 else Vector((1, 0, 0))
        u = axis.cross(helper).normalized()
        v = axis.cross(u).normalized()
        ring = [u * math.cos(i * math.tau / segments) * radius + v * math.sin(i * math.tau / segments) * radius
                for i in range(segments)]
        for i in range(segments):
            j = (i + 1) % segments
            n = (ring[i] + ring[j]).normalized()
            self.quad_facing(tuple(s + ring[i]), tuple(s + ring[j]), tuple(e + ring[j]), tuple(e + ring[i]), key, tuple(n))

    def to_object(self, materials):
        mesh = bpy.data.meshes.new(self.name)
        mesh.from_pydata([tuple(v) for v in self.verts], [], self.faces)
        for key in self.mats:
            mesh.materials.append(materials[key])
        mesh.polygons.foreach_set("material_index", self.face_mats)
        mesh.update()
        obj = bpy.data.objects.new(self.name, mesh)
        bpy.context.scene.collection.objects.link(obj)
        bm = bmesh.new()
        bm.from_mesh(mesh)
        bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=0.0005)
        bm.to_mesh(mesh)
        bm.free()
        return obj


# --------------------------------------------------------------------------
# Materials

def _principled(name, color, roughness=0.9, noise=None, stripes=None):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    nodes, links = mat.node_tree.nodes, mat.node_tree.links
    bsdf = nodes.get("Principled BSDF")
    bsdf.inputs["Base Color"].default_value = (*color, 1.0)
    bsdf.inputs["Roughness"].default_value = roughness
    if noise or stripes:
        coord = nodes.new("ShaderNodeTexCoord")
        ramp_in = None
        if stripes:
            wave = nodes.new("ShaderNodeTexWave")
            wave.wave_type = "BANDS"
            wave.bands_direction = stripes.get("direction", "X")
            wave.inputs["Scale"].default_value = stripes["scale"]
            wave.inputs["Distortion"].default_value = stripes.get("distortion", 2.0)
            links.new(coord.outputs["Object"], wave.inputs["Vector"])
            ramp_in = wave.outputs["Fac"]
            amount = stripes["amount"]
        else:
            tex = nodes.new("ShaderNodeTexNoise")
            tex.inputs["Scale"].default_value = noise["scale"]
            tex.inputs["Detail"].default_value = noise.get("detail", 2.0)
            links.new(coord.outputs["Object"], tex.inputs["Vector"])
            ramp_in = tex.outputs["Fac"]
            amount = noise["amount"]
        mix = nodes.new("ShaderNodeMix")
        mix.data_type = "RGBA"
        mix.blend_type = "MIX"
        mix.inputs[6].default_value = (*(c * (1 - amount) for c in color), 1)
        mix.inputs[7].default_value = (*(min(1.0, c * (1 + amount)) for c in color), 1)
        links.new(ramp_in, mix.inputs[0])
        links.new(mix.outputs[2], bsdf.inputs["Base Color"])
    return mat


def _emitter(name, color, strength):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    nodes, links = mat.node_tree.nodes, mat.node_tree.links
    nodes.clear()
    out = nodes.new("ShaderNodeOutputMaterial")
    em = nodes.new("ShaderNodeEmission")
    em.inputs["Color"].default_value = (*color, 1)
    em.inputs["Strength"].default_value = strength
    links.new(em.outputs[0], out.inputs["Surface"])
    return mat


def unlit_material(name, color=None, image=None, uv="", color_attribute=""):
    """Emission behind a camera-ray mix: exported as KHR_materials_unlit."""
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    nodes, links = mat.node_tree.nodes, mat.node_tree.links
    nodes.clear()
    out = nodes.new("ShaderNodeOutputMaterial")
    path = nodes.new("ShaderNodeLightPath")
    mix_shader = nodes.new("ShaderNodeMixShader")
    em = nodes.new("ShaderNodeEmission")
    transparent = nodes.new("ShaderNodeBsdfTransparent")
    links.new(path.outputs["Is Camera Ray"], mix_shader.inputs[0])
    links.new(transparent.outputs[0], mix_shader.inputs[1])
    links.new(em.outputs[0], mix_shader.inputs[2])
    links.new(mix_shader.outputs[0], out.inputs["Surface"])
    source = None
    if image is not None:
        tex = nodes.new("ShaderNodeTexImage")
        tex.image = image
        if uv:
            uvn = nodes.new("ShaderNodeUVMap")
            uvn.uv_map = uv
            links.new(uvn.outputs[0], tex.inputs["Vector"])
        source = tex.outputs["Color"]
    if color_attribute:
        attr = nodes.new("ShaderNodeVertexColor")
        attr.layer_name = color_attribute
        if source is None:
            source = attr.outputs["Color"]
        else:
            mul = nodes.new("ShaderNodeMix")
            mul.data_type = "RGBA"
            mul.blend_type = "MULTIPLY"
            mul.inputs[0].default_value = 1.0
            links.new(source, mul.inputs[6])
            links.new(attr.outputs["Color"], mul.inputs[7])
            source = mul.outputs[2]
    if source is not None:
        links.new(source, em.inputs["Color"])
    else:
        em.inputs["Color"].default_value = (*color, 1)
    return mat


# Linear albedos. Real auditorium finishes are very dark; the screen does the lighting.
SURFACES = {
    "Carpet": dict(color=(0.022, 0.024, 0.034), noise=dict(scale=38.0, amount=0.35, detail=4.0)),
    "Riser": dict(color=(0.010, 0.010, 0.012)),
    "Tread": dict(color=(0.028, 0.030, 0.038), noise=dict(scale=40.0, amount=0.3)),
    "Nosing": dict(color=(0.040, 0.040, 0.043), roughness=0.5),
    "Fabric": dict(color=(0.030, 0.032, 0.040), noise=dict(scale=6.0, amount=0.18)),
    "FabricDeep": dict(color=(0.022, 0.023, 0.029), noise=dict(scale=6.0, amount=0.18)),
    "Velvet": dict(color=(0.006, 0.006, 0.007)),
    "Reveal": dict(color=(0.004, 0.004, 0.005)),
    "Wood": dict(color=(0.070, 0.038, 0.021), stripes=dict(scale=1.5, amount=0.12, direction="Z", distortion=1.0)),
    "Ceiling": dict(color=(0.010, 0.010, 0.012)),
    "Cloud": dict(color=(0.020, 0.021, 0.024), noise=dict(scale=3.0, amount=0.12)),
    "Metal": dict(color=(0.09, 0.095, 0.10), roughness=0.35),
    "Rail": dict(color=(0.070, 0.072, 0.075), roughness=0.3),
    "Speaker": dict(color=(0.012, 0.012, 0.013), noise=dict(scale=80.0, amount=0.4)),
    "Door": dict(color=(0.050, 0.030, 0.020), stripes=dict(scale=5.0, amount=0.25, direction="Z")),
    "Stage": dict(color=(0.005, 0.005, 0.006)),
}

# Real CC0 scans (tools/cinema/prepare_textures.py) per surface, with a
# brightness factor so one calibrated scan serves several finishes.
TEXTURE_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "textures")
with open(os.path.join(TEXTURE_DIR, "textures.json"), encoding="utf-8") as _handle:
    TEXTURES = json.load(_handle)
HALL_FINISH = {
    "Carpet": ("carpet_floor", 1.0),
    "Tread": ("carpet_tread", 1.0),
    "Riser": ("carpet_tread", 0.45),
    "Nosing": ("metal_brushed", 0.4),
    "Fabric": ("wall_fabric", 1.0),
    "FabricDeep": ("wall_fabric", 0.6),
    "Velvet": ("velvet_black", 1.0),
    "Reveal": ("velvet_black", 0.6),
    "Wood": ("wood_walnut", 1.0),
    "Ceiling": ("velvet_black", 1.3),
    "Cloud": ("cloud_felt", 1.0),
    "Metal": ("metal_brushed", 0.8),
    "Rail": ("metal_brushed", 0.65),
    "Speaker": ("velvet_black", 1.6),
    "Door": ("wood_walnut", 0.75),
    "Stage": ("velvet_black", 0.8),
}
# Baked irradiance is stored divided by this, leaving headroom near the screen.
# Must match light_scale in app/godot/shaders/cinema_baked_surface.gdshader.
LIGHT_SCALE = 2.0

# Side wall detailing (metres): fabric-wrapped acoustic panels and wainscot boards.
PANEL_COLUMNS = 2
PANEL_HEIGHT = 2.6
PANEL_JOINT = 0.012     # half of the dark reveal between neighbouring panels
PANEL_CHAMFER = 0.03
PANEL_BACKING = 0.05    # reveal backing sits this far behind the panel faces
PANEL_BACKING_STRIP = 0.05  # half width of the backing behind each joint
WAINSCOT_STEPS = 4      # straight pieces per board, following the stair line
WAINSCOT_JOINT = 0.006
WAINSCOT_TRIM = 0.015
# Surround speakers and door hardware.
SPEAKER_STANDOFF = 0.08
SPEAKER_DEPTH = 0.34
SPEAKER_RIM = 0.035
SPEAKER_RECESS = 0.015
KICK_PLATE_HEIGHT = 0.25
KICK_PLATE_PROUD = 0.006
DOOR_HEIGHT = 2.4
DOOR_FRAME = 0.10
DOOR_FRAME_PROUD = 0.03
DOOR_GAP = 0.006
SIDE_DOOR_LEAF = 0.24   # just in front of the deepest side wall panels (0.20)
REAR_DOOR_LEAF = 0.10
# Projection booth niche in the rear wall (heights above the rear aisle).
BOOTH_HALF_WIDTH = 2.6
BOOTH_BOTTOM = 3.4
BOOTH_TOP = 4.6
BOOTH_DEPTH = 0.45
BOOTH_PORT_X = 1.15
LENS_RADIUS = 0.07
# Ceiling pin lights, exit pictograms, row letter plaques.
STAR_SEED = 23
STARS_PER_CLOUD = (3, 9)
STAR_MARGIN = 0.25
STAR_SPACING = 0.45
STAR_RADIUS = (0.03, 0.06)
EXIT_MARK_PROUD = 0.015
PLAQUE_PROUD = 0.008
# Screen wall: stage fascia boards, black velvet drapes and the screen border.
FASCIA_BOARD = 2.4
FASCIA_JOINT = 0.008
FASCIA_PROUD = 0.02
FASCIA_BOTTOM = 0.30    # the glow strip stays visible below the boards
PLEAT_WIDTH = 0.32      # one full fold
PLEAT_STEPS = 6
PLEAT_DEPTH = 0.06
DRAPE_OFFSET = 0.35     # in front of the screen plane
DRAPE_CLEARANCE = 0.30  # beyond the screen edge: no seat sees a drape across the picture
SCREEN_FRAME = 0.22
FRAME_PROUD = 0.04
LIGHT_FILE = "cinema_light.jpg"


def preview_material(key, light):
    """Blender-side stand-in for the runtime shader: scan x factor x decoded light."""
    texture, factor = HALL_FINISH[key]
    mat = bpy.data.materials.new("Preview" + key)
    mat.use_nodes = True
    nodes, links = mat.node_tree.nodes, mat.node_tree.links
    nodes.clear()
    out = nodes.new("ShaderNodeOutputMaterial")
    em = nodes.new("ShaderNodeEmission")
    surface = nodes.new("ShaderNodeTexImage")
    surface.image = bpy.data.images.load(os.path.join(TEXTURE_DIR, TEXTURES[texture]["file"]), check_existing=True)
    tile_uv = nodes.new("ShaderNodeUVMap")
    tile_uv.uv_map = "Tile"
    links.new(tile_uv.outputs[0], surface.inputs["Vector"])
    baked = nodes.new("ShaderNodeTexImage")
    decoded = bpy.data.images.load(light.filepath_raw, check_existing=True)
    decoded.colorspace_settings.name = "sRGB"
    baked.image = decoded
    bake_uv = nodes.new("ShaderNodeUVMap")
    bake_uv.uv_map = "Bake"
    links.new(bake_uv.outputs[0], baked.inputs["Vector"])
    mul = nodes.new("ShaderNodeMix")
    mul.data_type = "RGBA"
    mul.blend_type = "MULTIPLY"
    mul.inputs[0].default_value = 1.0
    links.new(surface.outputs["Color"], mul.inputs[6])
    links.new(baked.outputs["Color"], mul.inputs[7])
    links.new(mul.outputs[2], em.inputs["Color"])
    em.inputs["Strength"].default_value = factor * LIGHT_SCALE
    links.new(em.outputs[0], out.inputs["Surface"])
    return mat


def hall_export_material(key, images):
    texture, factor = HALL_FINISH[key]
    if texture not in images:
        images[texture] = bpy.data.images.load(os.path.join(TEXTURE_DIR, TEXTURES[texture]["file"]))
        images[texture].pack()
    material = unlit_material("Hall" + key, image=images[texture], uv="Tile")
    if factor != 1.0:
        # Image x constant exports as baseColorTexture with a baseColorFactor.
        nodes, links = material.node_tree.nodes, material.node_tree.links
        emission = next(n for n in nodes if n.type == "EMISSION")
        source = emission.inputs["Color"].links[0].from_socket
        mul = nodes.new("ShaderNodeMix")
        mul.data_type = "RGBA"
        mul.blend_type = "MULTIPLY"
        mul.inputs[0].default_value = 1.0
        mul.inputs[7].default_value = (factor, factor, factor, 1.0)
        links.new(source, mul.inputs[6])
        links.new(mul.outputs[2], emission.inputs["Color"])
    return material


# Emitters: (bake colour, bake strength, export colour). Export colours are what
# the eye sees directly; bake strengths are what they throw onto the room.
GLOWS = {
    "StepLed": ((1.0, 0.62, 0.30), 18.0, (1.0, 0.66, 0.36)),
    "Sconce": ((1.0, 0.70, 0.42), 9.0, (1.0, 0.78, 0.55)),
    "StageGlow": ((1.0, 0.60, 0.32), 5.0, (0.85, 0.50, 0.26)),
    "Exit": ((0.10, 0.90, 0.40), 4.0, (0.20, 0.95, 0.50)),
    "Star": ((1.0, 0.85, 0.65), 1.5, (0.62, 0.52, 0.40)),
    "Booth": ((0.45, 0.60, 1.0), 2.0, (0.030, 0.040, 0.062)),
    "RowLetter": ((1.0, 0.72, 0.45), 2.0, (0.95, 0.70, 0.45)),
}
FIXED = {
    # Visible but not lighting anything (black masking, unlit screen surface).
    "Masking": (0.0035, 0.0035, 0.004),
    # Same black as the masking: a smaller or letterboxed picture floats in a
    # black void instead of revealing a grey screen surface around it.
    "ScreenIdle": (0.0035, 0.0035, 0.004),
}


# --------------------------------------------------------------------------
# Auditorium

class Hall:
    def __init__(self, manifest):
        self.m = manifest
        d = manifest["design"]
        self.d = d
        self.W = d["room_half_width"]
        self.front = d["room_front"]
        self.back = d["room_back"]
        self.H = manifest["room"]["height"]
        self.H_rear = d["ceiling_rear"]
        self.rows = d["row_count"]
        self.pitch = d["row_pitch"]
        self.riser = d["row_riser"]
        self.steps = d["steps_per_row"]
        self.tread = d["stair_tread"]
        self.step_rise = d["stair_riser"]
        self.first_z = d["first_row_z"]
        self.first_edge = self.first_z + d.get("tier_front_offset", -self.pitch * 0.5)
        self.stair_start = d.get("stair_start_z", self.first_edge)
        self.stair_end = self.stair_start + self.rows * self.pitch
        self.rear_edge = self.first_edge + self.rows * self.pitch
        self.top = self.rows * self.riser
        self.platform = d["platform_half_width"]
        self.aisle = d["aisle_outer_x"]
        self.rail = d["rail_x"]
        s = manifest["screen"]
        self.screen_w = s["width"]
        self.screen_h = s["height"]
        self.screen_z = s["position"][2]
        self.screen_y = s["position"][1]
        self.screen_bottom = self.screen_y - self.screen_h * 0.5
        self.screen_top = self.screen_y + self.screen_h * 0.5
        self.hall = Builder("Hall")
        self.fix = Builder("Fixtures")
        self.stars = random.Random(STAR_SEED)

    def ceiling(self, z):
        t = (z - self.front) / (self.back - self.front)
        return self.H + (self.H_rear - self.H) * t

    def floor_line(self, z):
        """Smooth stair nosing line beside the seating, used by wall trims."""
        if z <= self.stair_start:
            return 0.0
        return min(self.top, (z - self.stair_start) / self.pitch * self.riser)

    # -- Front: screen wall, masking and stage ---------------------------------
    def build_front(self):
        h, f = self.hall, self.fix
        W, sz = self.W, self.screen_z
        # Black masking fills the entire front wall; the screen reads as light, not a frame.
        f.quad_facing((-W, 0, sz - 0.12), (W, 0, sz - 0.12), (W, self.ceiling(sz), sz - 0.12),
                      (-W, self.ceiling(sz), sz - 0.12), "Masking", (0, 0, 1))
        hw = self.screen_w * 0.5
        f.quad_facing((-hw, self.screen_bottom, sz - 0.06), (hw, self.screen_bottom, sz - 0.06),
                      (hw, self.screen_top, sz - 0.06), (-hw, self.screen_top, sz - 0.06), "ScreenIdle", (0, 0, 1))
        # Stage bulkhead below the screen with a warm floor wash.
        stage_front = sz + 0.04  # flush: the transport bar floats here
        h.box((-W, 0, sz - 0.12), (W, self.screen_bottom - 0.08, stage_front), "Stage", faces="+y+z")
        # A real diffuser separated from the stage face, not a subpixel sliver.
        f.quad_facing((-W + 0.6, 0.09, stage_front + 0.04), (W - 0.6, 0.09, stage_front + 0.04),
                      (W - 0.6, 0.19, stage_front + 0.04), (-W + 0.6, 0.19, stage_front + 0.04), "StageGlow", (0, 0, 1))
        self.build_stage_fascia(stage_front)
        self.build_drapes()
        # Front floor from stage to the first tier.
        P = self.platform
        h.quad_facing((-P, 0, stage_front), (P, 0, stage_front), (P, 0, self.first_edge), (-P, 0, self.first_edge),
                      "Carpet", (0, 1, 0))
        for xa, xb in [(-W, -P), (P, W)]:
            h.quad_facing((xa, 0, stage_front), (xb, 0, stage_front), (xb, 0, self.stair_start), (xa, 0, self.stair_start), "Carpet", (0, 1, 0))

    def build_stage_fascia(self, stage_front):
        """Walnut boards (the door finish) with shadow joints above the glow strip,
        a metal edge on top."""
        h, W = self.hall, self.W
        top = self.screen_bottom - 0.08
        z = stage_front + FASCIA_PROUD
        boards = max(1, round(2 * W / FASCIA_BOARD))
        width = 2 * W / boards
        for i in range(boards):
            x0, x1 = -W + i * width + FASCIA_JOINT, -W + (i + 1) * width - FASCIA_JOINT
            h.quad_facing((x0, FASCIA_BOTTOM, z), (x1, FASCIA_BOTTOM, z), (x1, top - 0.04, z), (x0, top - 0.04, z), "Door", (0, 0, 1))
        h.box((-W, FASCIA_BOTTOM, stage_front), (W, FASCIA_BOTTOM + 0.001, z), "Door", faces="-y")
        h.box((-W, top - 0.04, stage_front), (W, top, z + 0.006), "Metal", faces="+y+z-y")

    def pleats(self, x0, x1, y0, y1, z, depth):
        """Velvet folds hanging between x0 and x1, swinging `depth` either side of z."""
        steps = max(PLEAT_STEPS, round(abs(x1 - x0) / PLEAT_WIDTH * PLEAT_STEPS))
        points = []
        for i in range(steps + 1):
            x = x0 + (x1 - x0) * i / steps
            points.append((x, z + depth * math.sin(math.tau * i / PLEAT_STEPS)))
        for (xa, za), (xb, zb) in zip(points, points[1:]):
            self.hall.quad_facing((xa, y0, za), (xb, y0, zb), (xb, y1, zb), (xa, y1, za), "Speaker", (0, 0, 1))

    def build_drapes(self):
        """Black velvet legs beside the screen and a valance above it. They stay
        outside every seat's sight line to the screen edges. They share the grille
        cloth material: the hall stays within its shared-material budget."""
        W, sz = self.W, self.screen_z
        hw = self.screen_w * 0.5 + DRAPE_CLEARANCE
        ceiling = self.ceiling(sz)
        z = sz + DRAPE_OFFSET
        # The legs hang in front of the stage, down to the floor.
        for side in (-1.0, 1.0):
            self.pleats(side * hw, side * W, 0.0, ceiling, z, PLEAT_DEPTH)
        self.pleats(-W, W, self.screen_top + DRAPE_CLEARANCE, ceiling, z, PLEAT_DEPTH * 0.6)
        # Velvet border framing the screen, standing just proud of its surface.
        x, b, t = self.screen_w * 0.5, self.screen_bottom, self.screen_top
        f = SCREEN_FRAME
        for lo, hi in [((-x - f, b - f, sz - 0.06), (x + f, b, sz + FRAME_PROUD)), ((-x - f, t, sz - 0.06), (x + f, t + f, sz + FRAME_PROUD)),
                       ((-x - f, b, sz - 0.06), (-x, t, sz + FRAME_PROUD)), ((x, b, sz - 0.06), (x + f, t, sz + FRAME_PROUD))]:
            self.hall.box(lo, hi, "Speaker", faces="+z+x-x+y-y")

    # -- Seating tiers and stairs ------------------------------------------------
    def build_tiers(self):
        h, f = self.hall, self.fix
        P, W = self.platform, self.W
        for row in range(self.rows):
            z0 = self.first_edge + row * self.pitch
            z1 = z0 + self.pitch
            level = (row + 1) * self.riser
            prev = row * self.riser
            h.quad_facing((-P, level, z0), (P, level, z0), (P, level, z1), (-P, level, z1), "Carpet", (0, 1, 0))
            h.quad_facing((-P, prev, z0), (P, prev, z0), (P, level, z0), (-P, level, z0), "Riser", (0, 0, -1))
            # Nosing trim on each tier edge catches the screen light and outlines the rake.
            h.box((-P, level - 0.03, z0 - 0.012), (P, level + 0.004, z0 + 0.02), "Nosing", faces="+y-z")
            for side in (-1.0, 1.0):
                x = side * P
                h.quad_facing((x, prev, z0), (x, prev, z1), (x, level, z1), (x, level, z0), "Riser", (side, 0, 0))
                # Row letters glow at both aisle ends of every tier.
                letter = chr(65 + row)
                h.box((min(x, x + side * PLAQUE_PROUD), level - 0.43, z0 + 0.14), (max(x, x + side * PLAQUE_PROUD), level - 0.21, z0 + 0.36),
                      "Nosing", faces="+y-y+z-z" + ("+x" if side > 0 else "-x"))
                self.text(letter, (x + side * (PLAQUE_PROUD + 0.004), level - 0.32, z0 + 0.25), side, 0.16, "RowLetter")
        # One continuous staircase on each side, from the seating block to the wall.
        for step in range(self.rows * self.steps):
            z0 = self.stair_start + step * self.tread
            z1 = z0 + self.tread
            top = (step + 1) * self.step_rise
            under = step * self.step_rise
            for side in (-1.0, 1.0):
                xa, xb = sorted((side * P, side * W))
                h.quad_facing((xa, top, z0), (xb, top, z0), (xb, top, z1), (xa, top, z1), "Tread", (0, 1, 0))
                h.quad_facing((xa, under, z0), (xb, under, z0), (xb, top, z0), (xa, top, z0), "Riser", (0, 0, -1))
                h.box((xa, top - 0.025, z0 - 0.01), (xb, top + 0.003, z0 + 0.03), "Nosing", faces="+y-z")
                # Small step lights at both edges of the main aisle.
                for x in (side * (P + 0.18), side * (self.aisle - 0.18)):
                    f.quad_facing((x - 0.13, top - 0.085, z0 - 0.012), (x + 0.13, top - 0.085, z0 - 0.012),
                                  (x + 0.13, top - 0.04, z0 - 0.012), (x - 0.13, top - 0.04, z0 - 0.012), "StepLed", (0, 0, -1))
        # Rear cross aisle.
        h.quad_facing((-P, self.top, self.rear_edge), (P, self.top, self.rear_edge), (P, self.top, self.back),
                      (-P, self.top, self.back), "Carpet", (0, 1, 0))
        for xa, xb in [(-W, -P), (P, W)]:
            h.quad_facing((xa, self.top, self.stair_end), (xb, self.top, self.stair_end), (xb, self.top, self.back), (xa, self.top, self.back), "Carpet", (0, 1, 0))

    def build_rails(self):
        h = self.hall
        for side in (-1.0, 1.0):
            x = side * self.rail
            for row in range(self.rows + 1):
                z = self.stair_start + row * self.pitch + self.tread * 0.5
                floor = min(self.top, (row * self.steps + 1) * self.step_rise)
                h.tube((x, floor, z), (x, floor + 0.98, z), 0.022, "Rail", segments=12)
            start = (x, self.step_rise + 1.0, self.stair_start + self.tread * 0.5)
            end = (x, min(self.top, (self.rows * self.steps + 1) * self.step_rise) + 1.0,
                   self.stair_end + self.tread * 0.5)
            h.tube(start, end, 0.03, "Rail", segments=16)
            # Glass-free mid rail keeps the edge legible at a distance.
            h.tube((x, start[1] - 0.45, start[2]), (x, end[1] - 0.45, end[2]), 0.012, "Rail", segments=12)

    # -- Side walls: wood wainscot, pleated acoustic bays, sconces, speakers -------
    def build_walls(self):
        h, f = self.hall, self.fix
        W = self.W
        bay = 2.75
        bays = int(round((self.back - self.front) / bay))
        bay = (self.back - self.front) / bays
        for side in (-1.0, 1.0):
            inward = (-side, 0, 0)
            wall_x = side * W
            # Wainscot follows the stair line so the wall reads at human scale: one
            # board per bay with a shadow joint, capped by a brushed metal trim.
            x = wall_x - side * 0.06
            xt = x - side * WAINSCOT_TRIM
            for b in range(bays):
                z0 = self.front + b * bay
                for i in range(WAINSCOT_STEPS):
                    za = z0 + bay * i / WAINSCOT_STEPS + (WAINSCOT_JOINT if i == 0 else 0.0)
                    zb = z0 + bay * (i + 1) / WAINSCOT_STEPS - (WAINSCOT_JOINT if i == WAINSCOT_STEPS - 1 else 0.0)
                    ya, yb = self.floor_line(za), self.floor_line(zb)
                    h.quad_facing((x, ya - 0.3, za), (x, yb - 0.3, zb), (x, yb + 1.13, zb), (x, ya + 1.13, za), "Wood", inward)
                    # Trim: front, top back to the wall, underside.
                    za, zb = z0 + bay * i / WAINSCOT_STEPS, z0 + bay * (i + 1) / WAINSCOT_STEPS
                    ya, yb = self.floor_line(za), self.floor_line(zb)
                    h.quad_facing((xt, ya + 1.13, za), (xt, yb + 1.13, zb), (xt, yb + 1.17, zb), (xt, ya + 1.17, za), "Metal", inward)
                    h.quad_facing((xt, ya + 1.17, za), (xt, yb + 1.17, zb), (wall_x, yb + 1.17, zb), (wall_x, ya + 1.17, za), "Metal", (0, 1, 0))
                    h.quad_facing((xt, ya + 1.13, za), (xt, yb + 1.13, zb), (x, yb + 1.13, zb), (x, ya + 1.13, za), "Metal", (0, -1, 0))
                # Dark joint behind the gap between neighbouring boards.
                for zj in (z0, z0 + bay):
                    ya, yb = self.floor_line(zj - 0.03), self.floor_line(zj + 0.03)
                    h.quad_facing((x + side * 0.02, ya - 0.3, zj - 0.03), (x + side * 0.02, yb - 0.3, zj + 0.03),
                                  (x + side * 0.02, yb + 1.13, zj + 0.03), (x + side * 0.02, ya + 1.13, zj - 0.03), "Reveal", inward)
            for b in range(bays):
                z0 = self.front + b * bay
                z1 = z0 + bay
                deep = (b % 2 == 0)
                depth = 0.20 if deep else 0.08
                inset = 0.06
                # Black velvet near the screen, like the front of a GT hall.
                material = "Velvet" if z1 < self.screen_z + 6.0 else "Fabric"
                bottom0, bottom1 = self.floor_line(z0) + 1.2, self.floor_line(z1) + 1.2
                top0, top1 = self.ceiling(z0) - 0.9, self.ceiling(z1) - 0.9
                x = wall_x - side * depth
                za, zb = z0 + inset, z1 - inset
                bza = self.floor_line(za) + 1.2
                bzb = self.floor_line(zb) + 1.2
                tza, tzb = self.ceiling(za) - 0.9, self.ceiling(zb) - 0.9
                # Fabric-wrapped acoustic panels with chamfered edges.
                self.panels(x, side, (za, bza, tza), (zb, bzb, tzb), material)
                # Chamfered returns give each bay a lit edge and a shadowed edge.
                h.quad_facing((wall_x, bza, z0), (x, bza, za), (x, tza, za), (wall_x, tza, z0), material, (0, 0, -1))
                h.quad_facing((x, bzb, zb), (wall_x, bzb, z1), (wall_x, tzb, z1), (x, tzb, zb), material, (0, 0, 1))
                # Recessed reveal behind the bay joints.
                h.quad_facing((wall_x, bottom0, z0), (wall_x, bottom1, z1), (wall_x, top1, z1), (wall_x, top0, z0), "Reveal", inward)
                # Cove band beneath the ceiling.
                h.quad_facing((wall_x - side * 0.3, top0, z0), (wall_x - side * 0.3, top1, z1),
                              (wall_x - side * 0.3, self.ceiling(z1), z1), (wall_x - side * 0.3, self.ceiling(z0), z0), "Velvet", inward)
                zc = (z0 + z1) * 0.5
                # Sconce slot at each joint above the stair (human-height scale cue).
                if z0 > self.screen_z + 3.0:
                    y = self.floor_line(z0) + 2.25
                    xs = wall_x - side * 0.05
                    f.quad_facing((xs, y, z0 - 0.035), (xs, y, z0 + 0.035), (xs, y + 0.62, z0 + 0.035), (xs, y + 0.62, z0 - 0.035), "Sconce", inward)
                    h.box((min(xs, xs - side * 0.07), y - 0.06, z0 - 0.07), (max(xs, xs - side * 0.07), y + 0.68, z0 + 0.07), "Metal",
                          faces="+y-y+z-z" + ("-x" if side > 0 else "+x"))
                # Surround loudspeakers high on alternate bays.
                if b % 2 == 1 and zc > self.screen_z + 4.0:
                    self.surround_speaker(wall_x - side * depth, side, self.floor_line(zc) + 5.6, zc)
            self.build_side_door(side)

    def panels(self, x, side, near, far, material):
        """Splits a raked bay face into chamfered panels. `near`/`far` are
        (z, bottom y, top y) at the bay's two edges; joints follow the rake."""
        za, bza, tza = near
        zb, bzb, tzb = far
        inward = Vector((-side, 0, 0))
        height = ((tza - bza) + (tzb - bzb)) * 0.5
        bands = max(1, round(height / PANEL_HEIGHT))
        width = zb - za

        def at(s, t, depth):
            z = za + width * s
            y0, y1 = bza + (bzb - bza) * s, tza + (tzb - tza) * s
            return (x + side * depth, y0 + (y1 - y0) * t, z)

        gs, gt = PANEL_JOINT / width, PANEL_JOINT / height
        cs, ct = PANEL_CHAMFER / width, PANEL_CHAMFER / height
        # Dark backing only behind the joints: a full backing would spend as much
        # lightmap area as the wall itself on surfaces that are never seen.
        bs, bt = PANEL_BACKING_STRIP / width, PANEL_BACKING_STRIP / height
        strips = [(column / PANEL_COLUMNS - bs, column / PANEL_COLUMNS + bs, 0.0, 1.0) for column in range(1, PANEL_COLUMNS)]
        strips += [(0.0, 1.0, band / bands - bt, band / bands + bt) for band in range(1, bands)]
        for s0, s1, t0, t1 in strips:
            self.hall.quad_facing(at(s0, t0, PANEL_BACKING), at(s1, t0, PANEL_BACKING), at(s1, t1, PANEL_BACKING),
                                  at(s0, t1, PANEL_BACKING), "Reveal", tuple(inward))
        for column in range(PANEL_COLUMNS):
            s0 = column / PANEL_COLUMNS + (gs if column else 0.0)
            s1 = (column + 1) / PANEL_COLUMNS - (gs if column < PANEL_COLUMNS - 1 else 0.0)
            for band in range(bands):
                t0 = band / bands + (gt if band else 0.0)
                t1 = (band + 1) / bands - (gt if band < bands - 1 else 0.0)
                outer = [at(s0, t0, PANEL_CHAMFER), at(s1, t0, PANEL_CHAMFER), at(s1, t1, PANEL_CHAMFER), at(s0, t1, PANEL_CHAMFER)]
                inner = [at(s0 + cs, t0 + ct, 0.0), at(s1 - cs, t0 + ct, 0.0), at(s1 - cs, t1 - ct, 0.0), at(s0 + cs, t1 - ct, 0.0)]
                self.hall.quad_facing(*inner, material, tuple(inward))
                centre = sum((Vector(p) for p in inner), Vector()) / 4
                for k in range(4):
                    a, b = outer[k], outer[(k + 1) % 4]
                    out = (Vector(a) + Vector(b)) * 0.5 - centre
                    out.x = 0
                    self.hall.quad_facing(a, b, inner[(k + 1) % 4], inner[k], material, tuple(inward + out.normalized()))

    def surround_speaker(self, wall, side, y, zc):
        """Cabinet on a short wall bracket, framed grille cloth recessed in front."""
        h = self.hall
        inward = (-side, 0, 0)
        back = wall - side * SPEAKER_STANDOFF
        front = back - side * SPEAKER_DEPTH
        hh, hw, rim = 0.45, 0.30, SPEAKER_RIM
        h.box((min(back, front), y - hh, zc - hw), (max(back, front), y + hh, zc + hw), "Reveal", faces="+y-y+z-z")
        grille = front + side * SPEAKER_RECESS
        outer = [(y - hh, zc - hw), (y - hh, zc + hw), (y + hh, zc + hw), (y + hh, zc - hw)]
        inner = [(y - hh + rim, zc - hw + rim), (y - hh + rim, zc + hw - rim), (y + hh - rim, zc + hw - rim), (y + hh - rim, zc - hw + rim)]
        for k in range(4):
            (ya, za), (yb, zb) = outer[k], outer[(k + 1) % 4]
            (yc, zcc), (yd, zd) = inner[(k + 1) % 4], inner[k]
            h.quad_facing((front, ya, za), (front, yb, zb), (front, yc, zcc), (front, yd, zd), "Metal", inward)
            h.quad_facing((front, yd, zd), (front, yc, zcc), (grille, yc, zcc), (grille, yd, zd), "Metal",
                          tuple(Vector(inward) + (Vector((0, (y - yd) + (y - yc), (zc - zd) + (zc - zcc))).normalized())))
        h.quad_facing(*[(grille, a, b) for a, b in inner], "Speaker", inward)
        h.tube((wall, y, zc), (back, y, zc), 0.035, "Metal", segments=8)

    def build_side_door(self, side):
        h, f = self.hall, self.fix
        W = self.W
        z0, z1 = 0.4, 2.4
        inward = (-side, 0, 0)
        mid = (z0 + z1) * 0.5
        # Leaves stand in front of the deepest acoustic panels, which used to hide
        # their upper half and leave only the frame showing.
        self.double_door(lambda u, y, d: (side * (W - d), y, u), mid, z1 - z0, 0.0, SIDE_DOOR_LEAF)
        # The diffuser must sit in front of the box's inward-facing front.
        # Previously both faces occupied xs exactly (head-motion Z fighting).
        housing_x = side * (W - 0.24)
        xs = housing_x - side * 0.03
        f.quad_facing((xs, 2.78, mid - 0.22), (xs, 2.78, mid + 0.22), (xs, 2.98, mid + 0.22), (xs, 2.98, mid - 0.22), "Exit", inward)
        xm = xs - side * EXIT_MARK_PROUD
        self.exit_mark(lambda a, b: (xm, 2.78 + b, mid - side * (a - 0.22)), inward)
        h.box((min(housing_x, housing_x + side * 0.06), 2.74, mid - 0.25), (max(housing_x, housing_x + side * 0.06), 3.02, mid + 0.25), "Speaker",
              faces="+y-y+z-z" + ("-x" if side > 0 else "+x"))

    def double_door(self, at, centre, width, floor, leaf):
        """Pair of walnut leaves in a frame on a wall. `at(u, y, d)` maps the
        position along the wall, height and distance in front of it to Godot."""
        h = self.hall
        wall = Vector(at(0, 0, 0)) - Vector(at(0, 0, 1))
        back = next(sign + axis for axis, value in zip("xyz", wall) for sign in "+-"
                    if abs(value) > .5 and (value > 0) == (sign == "+"))
        inward = tuple(-wall)

        def box(u0, u1, y0, y1, d0, d1, key):
            a, b = Vector(at(u0, y0, d0)), Vector(at(u1, y1, d1))
            lo = tuple(min(a[i], b[i]) for i in range(3))
            hi = tuple(max(a[i], b[i]) for i in range(3))
            faces = "".join(face for face in ["+x", "-x", "+y", "-y", "+z", "-z"] if face != back and not (face == "-y" and y0 <= floor))
            h.box(lo, hi, key, faces=faces)

        def quad(u0, u1, y0, y1, d, key):
            h.quad_facing(at(u0, y0, d), at(u1, y0, d), at(u1, y1, d), at(u0, y1, d), key, inward)

        u0, u1 = centre - width * 0.5, centre + width * 0.5
        top = floor + DOOR_HEIGHT
        f = DOOR_FRAME
        # Frame: jambs and head standing proud of the leaves.
        box(u0 - f, u0, floor, top + f, 0.0, leaf + DOOR_FRAME_PROUD, "Wood")
        box(u1, u1 + f, floor, top + f, 0.0, leaf + DOOR_FRAME_PROUD, "Wood")
        box(u0, u1, top, top + f, 0.0, leaf + DOOR_FRAME_PROUD, "Wood")
        quad(centre - 0.02, centre + 0.02, floor, top, leaf - 0.02, "Reveal")
        for a, b in ((u0, centre - DOOR_GAP), (centre + DOOR_GAP, u1)):
            quad(a, b, floor + 0.01, top - 0.005, leaf, "Door")
            quad(a + 0.04, b - 0.04, floor + 0.02, floor + KICK_PLATE_HEIGHT, leaf + KICK_PLATE_PROUD, "Nosing")
            # Push bar on two short standoffs.
            bar = leaf + 0.075
            h.tube(at(a + 0.12, floor + 1.02, bar), at(b - 0.12, floor + 1.02, bar), 0.018, "Metal", segments=10)
            for u in (a + 0.14, b - 0.14):
                h.tube(at(u, floor + 1.02, leaf), at(u, floor + 1.02, bar), 0.012, "Metal", segments=8)

    def port(self, x, y, w, ht, z, lens):
        """One projection port in the booth niche: dark glass in a metal frame,
        with a lens bezel and glow behind the glass when `lens`."""
        h, f = self.hall, self.fix
        rim = 0.04
        f.quad_facing((x - w / 2, y - ht / 2, z - 0.01), (x + w / 2, y - ht / 2, z - 0.01),
                      (x + w / 2, y + ht / 2, z - 0.01), (x - w / 2, y + ht / 2, z - 0.01), "Booth", (0, 0, -1))
        for lo, hi in (((x - w / 2 - rim, y - ht / 2 - rim), (x + w / 2 + rim, y - ht / 2)),
                       ((x - w / 2 - rim, y + ht / 2), (x + w / 2 + rim, y + ht / 2 + rim)),
                       ((x - w / 2 - rim, y - ht / 2), (x - w / 2, y + ht / 2)),
                       ((x + w / 2, y - ht / 2), (x + w / 2 + rim, y + ht / 2))):
            h.box((lo[0], lo[1], z - 0.035), (hi[0], hi[1], z), "Metal", faces="-z+x-x+y-y")
        if lens:
            self.disc(h, (x, y, z - 0.015), LENS_RADIUS + 0.03, "Metal")
            self.disc(f, (x, y, z - 0.02), LENS_RADIUS, "Sconce")

    def disc(self, builder, centre, radius, key, n=16):
        cx, cy, cz = centre
        for k in range(n):
            a, b = math.tau * k / n, math.tau * (k + 1) / n
            pts = [Vector(centre), Vector((cx + radius * math.cos(a), cy + radius * math.sin(a), cz)),
                   Vector((cx + radius * math.cos(b), cy + radius * math.sin(b), cz))]
            if (pts[1] - pts[0]).cross(pts[2] - pts[0]).dot(Vector((0, 0, -1))) < 0:
                pts[1], pts[2] = pts[2], pts[1]
            builder.poly([tuple(p) for p in pts], key)

    # -- Rear wall, doors and projection ports -----------------------------------
    def build_rear(self):
        h, f = self.hall, self.fix
        W, z = self.W, self.back
        y0, y1 = self.top, self.ceiling(self.back)
        h.quad_facing((-W, y0 - 0.3, z), (W, y0 - 0.3, z), (W, y0 + 1.15, z), (-W, y0 + 1.15, z), "Wood", (0, 0, -1))
        # Fabric wall around the projection booth niche.
        nx, nb, nt = BOOTH_HALF_WIDTH, y0 + BOOTH_BOTTOM, y0 + BOOTH_TOP
        for (xa, ya), (xb, yb) in (((-W, y0 + 1.15), (-nx, y1)), ((nx, y0 + 1.15), (W, y1)),
                                   ((-nx, y0 + 1.15), (nx, nb)), ((-nx, nt), (nx, y1))):
            h.quad_facing((xa, ya, z), (xb, ya, z), (xb, yb, z), (xa, yb, z), "FabricDeep", (0, 0, -1))
        # Niche: dark reveals, a back wall carrying the ports, a metal sill.
        zb = z + BOOTH_DEPTH
        h.quad_facing((-nx, nb, zb), (nx, nb, zb), (nx, nt, zb), (-nx, nt, zb), "Reveal", (0, 0, -1))
        h.quad_facing((-nx, nt, z), (nx, nt, z), (nx, nt, zb), (-nx, nt, zb), "Reveal", (0, -1, 0))
        h.quad_facing((-nx, nb, z), (nx, nb, z), (nx, nb, zb), (-nx, nb, zb), "Reveal", (0, 1, 0))
        for x, n in ((-nx, 1), (nx, -1)):
            h.quad_facing((x, nb, z), (x, nb, zb), (x, nt, zb), (x, nt, z), "Reveal", (n, 0, 0))
        h.box((-nx - 0.08, nb - 0.06, z - 0.10), (nx + 0.08, nb, z), "Metal", faces="+y-y-z+x-x")
        mid = (nb + nt) * 0.5
        for x in (-BOOTH_PORT_X, BOOTH_PORT_X):
            self.port(x, mid, 0.80, 0.56, zb, True)
        self.port(0.0, mid, 0.46, 0.34, zb, False)
        # Rear exits beside the cross aisle.
        for side in (-1.0, 1.0):
            xc = side * (self.rail + W) * 0.5
            x0, x1 = xc - 0.95, xc + 0.95
            self.double_door(lambda u, y, d: (u, y, z - d), xc, x1 - x0, y0, REAR_DOOR_LEAF)
            f.quad_facing((xc - 0.22, y0 + 2.8, z - 0.03), (xc + 0.22, y0 + 2.8, z - 0.03),
                          (xc + 0.22, y0 + 3.0, z - 0.03), (xc - 0.22, y0 + 3.0, z - 0.03), "Exit", (0, 0, -1))
            self.exit_mark(lambda a, b: (xc + side * (0.22 - a), y0 + 2.8 + b, z - 0.03 - EXIT_MARK_PROUD), (0, 0, -1))

    # -- Ceiling with floating acoustic clouds and pin-point downlights ------------
    def build_ceiling(self):
        h, f = self.hall, self.fix
        W = self.W
        za, zb = self.front, self.back
        h.quad_facing((-W, self.ceiling(za), za), (W, self.ceiling(za), za), (W, self.ceiling(zb), zb), (-W, self.ceiling(zb), zb),
                      "Ceiling", (0, -1, 0))
        z = self.screen_z + 2.5
        cloud_depth, gap = 3.4, 0.35
        while z + cloud_depth < self.back - 1.0:
            z0, z1 = z, z + cloud_depth
            y0, y1 = self.ceiling(z0) - 1.1, self.ceiling(z1) - 1.1
            for column in range(-3, 3):
                x0 = column * 5.0 + 0.18
                x1 = x0 + 4.64
                h.quad_facing((x0, y0, z0), (x1, y0, z0), (x1, y1, z1), (x0, y1, z1), "Cloud", (0, -1, 0))
                h.quad_facing((x0, y0, z0), (x1, y0, z0), (x1, y0 + 0.14, z0), (x0, y0 + 0.14, z0), "Cloud", (0, 0, -1))
                h.quad_facing((x0, y1, z1), (x1, y1, z1), (x1, y1 + 0.14, z1), (x0, y1 + 0.14, z1), "Cloud", (0, 0, 1))
                for px, pz, r in self.star_layout(x0, x1, z0, z1):
                    py = self.ceiling(pz) - 1.1 - 0.004
                    f.quad_facing((px - r, py, pz - r), (px + r, py, pz - r), (px + r, py, pz + r),
                                  (px - r, py, pz + r), "Star", (0, -1, 0))
            z += cloud_depth + gap
        # Side walls continue above the cove up to the sloped ceiling (front and rear covered elsewhere).

    def star_layout(self, x0, x1, z0, z1):
        """Irregular pin lights on one cloud: a regular grid read as graph paper
        from the rear rows. Seeded, so every bake places them identically."""
        count = self.stars.randint(*STARS_PER_CLOUD)
        placed = []
        for attempt in range(200):
            if len(placed) == count:
                break
            px = self.stars.uniform(x0 + STAR_MARGIN, x1 - STAR_MARGIN)
            pz = self.stars.uniform(z0 + STAR_MARGIN, z1 - STAR_MARGIN)
            if all((px - qx) ** 2 + (pz - qz) ** 2 >= STAR_SPACING ** 2 for qx, qz, _ in placed):
                placed.append((px, pz, self.stars.uniform(*STAR_RADIUS)))
        return placed

    def exit_mark(self, at, normal):
        """Running figure and arrow on an exit sign, kept clear of its centre.
        `at(a, b)` maps metres across (0..0.44) and up (0..0.20) to Godot."""
        f = self.fix

        def line(points, width):
            for (a0, b0), (a1, b1) in zip(points, points[1:]):
                d = Vector((a1 - a0, b1 - b0)).normalized() * width * 0.5
                n = Vector((-d.y, d.x))
                f.quad_facing(at(a0 + n.x - d.x, b0 + n.y - d.y), at(a1 + n.x + d.x, b1 + n.y + d.y),
                              at(a1 - n.x + d.x, b1 - n.y + d.y), at(a0 - n.x - d.x, b0 - n.y - d.y), "Masking", normal)

        def fan(points):
            centre = Vector(at(*points[0]))
            for p, q in zip(points[1:], points[2:]):
                tri = [centre, Vector(at(*p)), Vector(at(*q))]
                if (tri[1] - tri[0]).cross(tri[2] - tri[0]).dot(Vector(normal)) < 0:
                    tri[1], tri[2] = tri[2], tri[1]
                f.poly([tuple(v) for v in tri], "Masking")

        head = [(0.088 + 0.016 * math.cos(math.tau * k / 8), 0.158 + 0.016 * math.sin(math.tau * k / 8)) for k in range(9)]
        fan([(0.088, 0.158)] + head)
        line([(0.082, 0.136), (0.066, 0.088)], 0.018)
        line([(0.066, 0.088), (0.044, 0.062), (0.030, 0.026)], 0.013)
        line([(0.066, 0.088), (0.092, 0.058), (0.098, 0.022)], 0.013)
        line([(0.080, 0.124), (0.102, 0.104), (0.118, 0.116)], 0.011)
        line([(0.080, 0.124), (0.058, 0.112), (0.046, 0.096)], 0.011)
        line([(0.330, 0.100), (0.398, 0.100)], 0.022)
        fan([(0.396, 0.064), (0.396, 0.136), (0.428, 0.100)])

    def text(self, value, position, side, size, key):
        curve = bpy.data.curves.new("RowLetter", "FONT")
        curve.body = value
        curve.size = size
        curve.align_x = "CENTER"
        curve.align_y = "CENTER"
        obj = bpy.data.objects.new("RowLetter", curve)
        bpy.context.scene.collection.objects.link(obj)
        depsgraph = bpy.context.evaluated_depsgraph_get()
        mesh = obj.evaluated_get(depsgraph).to_mesh()
        # Text lies in its local XY plane; face it outward along Godot ±X.
        normal = Vector((side, 0, 0))
        right = Vector((0, 0, side))  # reading direction on the platform side
        up = Vector((0, 1, 0))
        base = Vector(position)
        bm = bmesh.new()
        bm.from_mesh(mesh)
        bmesh.ops.triangulate(bm, faces=bm.faces)
        for face in bm.faces:
            pts = [base + right * v.co.x + up * v.co.y for v in face.verts]
            self.fix.quad_facing(*pts, key, tuple(normal)) if len(pts) == 4 else self._tri(pts, key, normal)
        bm.free()
        obj.evaluated_get(depsgraph).to_mesh_clear()
        bpy.data.objects.remove(obj)
        bpy.data.curves.remove(curve)

    def _tri(self, pts, key, normal):
        a, b, c = pts
        if (b - a).cross(c - a).dot(normal) < 0:
            b, c = c, b
        self.fix.poly([tuple(a), tuple(b), tuple(c)], key)

    def build(self):
        self.build_front()
        self.build_tiers()
        self.build_rails()
        self.build_walls()
        self.build_rear()
        self.build_ceiling()


# --------------------------------------------------------------------------
# Seats

def seat_rows(manifest):
    rows = {}
    for seat in manifest["seats"]:
        ex, ey, ez = seat["eye_position"]
        level = ey - manifest["design"]["seated_eye_height"]
        origin = (ex, level, ez + 0.10)
        rows.setdefault(seat["row"], []).append(origin)
    return rows


def make_seats(texture_path, args):
    """Returns ((near seat, near end console), (far seat, far end console)), all
    sharing one baked texture. Each seat carries the console on its left; the
    end console closes the right-hand end of every row."""
    if not args.placeholder_seats:
        import seat_model
        seat_model.bake_seat_texture(texture_path, 256 if args.quick else args.seat_texture)
        return ((seat_model.build_seat("SeatNear", 0), seat_model.build_end_armrest("EndNear", 0)),
                (seat_model.build_seat("SeatFar", 1), seat_model.build_end_armrest("EndFar", 1)))
    sets = []
    for _ in range(2):
        seat = make_placeholder_seat(texture_path)
        end = seat.copy()
        end.data = seat.data.copy()
        bpy.context.scene.collection.objects.link(end)
        sets.append((seat, end))
    return tuple(sets)


def make_placeholder_seat(texture_path):
    # Layout iteration only: a coarse chair with a flat texture.
    b = Builder("SeatSource")
    def box(lo, hi):
        b.box(lo, hi, "Seat")
    box((-0.27, 0.0, -0.20), (0.27, 0.45, 0.30))
    box((-0.27, 0.42, 0.10), (0.27, 1.0, 0.30))
    for x in (-0.31, 0.27):
        box((x, 0.0, -0.30), (x + 0.04, 0.65, 0.25))
    mat = bpy.data.materials.new("CinemaSeat")
    obj = b.to_object({"Seat": mat})
    obj.data.uv_layers.new(name="UVMap")
    image = bpy.data.images.new("SeatPlaceholder", 8, 8)
    image.pixels = [0.35, 0.08, 0.1, 1.0] * 64
    image.filepath_raw = texture_path
    image.file_format = "PNG"
    image.save()
    return obj


SEATS_PER_CHUNK = 4
SEAT_PITCH = 0.9  # replaced from the manifest at build time


def build_seat_chunks(manifest, seat_object, end_object, suffix):
    """Joins four-seat runs into one mesh: modest draw calls, fine-grained culling,
    and a near/far switch that only details the chairs around the viewer.
    Each object's origin is its chunk centre, so distance checks are local."""
    source = seat_object.data
    chunks = []
    for row, origins in sorted(seat_rows(manifest).items()):
        origins = sorted(origins)
        for index in range(0, len(origins), SEATS_PER_CHUNK):
            picks = origins[index:index + SEATS_PER_CHUNK]
            centre = G(*[sum(o[axis] for o in picks) / len(picks) for axis in range(3)])
            bm = bmesh.new()
            parts = [(source, origin) for origin in picks]
            if picks[-1] == origins[-1]:
                end = picks[-1]
                parts.append((end_object.data, (end[0] + SEAT_PITCH * 0.5, end[1], end[2])))
            for data, origin in parts:
                count = len(bm.verts)
                bm.from_mesh(data)
                bm.verts.ensure_lookup_table()
                bmesh.ops.translate(bm, verts=bm.verts[count:], vec=G(*origin) - centre)
            mesh = bpy.data.meshes.new("Seats_%02d%s_%s" % (row, chr(65 + index // SEATS_PER_CHUNK), suffix))
            bm.to_mesh(mesh)
            bm.free()
            for material in source.materials:
                mesh.materials.append(material)
            obj = bpy.data.objects.new(mesh.name, mesh)
            obj.location = centre
            bpy.context.scene.collection.objects.link(obj)
            chunks.append(obj)
    return chunks


# --------------------------------------------------------------------------
# Lighting and baking

def setup_cycles(samples):
    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    prefs = bpy.context.preferences.addons["cycles"].preferences
    device = "CPU"
    for kind in ("OPTIX", "CUDA", "HIP", "ONEAPI"):
        try:
            prefs.compute_device_type = kind
            prefs.get_devices()
            usable = [d for d in prefs.devices if d.type == kind]
            if usable:
                for d in prefs.devices:
                    d.use = d.type == kind
                device = kind
                break
        except TypeError:
            continue
    scene.cycles.device = "GPU" if device != "CPU" else "CPU"
    scene.cycles.samples = samples
    scene.cycles.use_denoising = False
    scene.cycles.max_bounces = 4
    scene.cycles.diffuse_bounces = 3
    scene.cycles.glossy_bounces = 0
    world = bpy.data.worlds.new("Dark") if not scene.world else scene.world
    scene.world = world
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs["Strength"].default_value = 0.0
    print("CYCLES device=%s samples=%d" % (device, samples))
    return device


def add_screen_emitter(hall):
    """Average film light from the screen: the dominant source in an IMAX hall."""
    mat = _emitter("ScreenLight", (0.82, 0.88, 1.0), 2.6)
    b = Builder("BakeScreenLight")
    hw = hall.screen_w * 0.5
    z = hall.screen_z - 0.04
    b.quad_facing((-hw, hall.screen_bottom, z), (hw, hall.screen_bottom, z), (hw, hall.screen_top, z), (-hw, hall.screen_top, z),
                  "ScreenLight", (0, 0, 1))
    return b.to_object({"ScreenLight": mat})


def add_tile_uvs(hall_obj):
    """Box-projects every face at its material's real-world texture scale.
    TEXCOORD_0 is this tiling layer; the light bake becomes TEXCOORD_1."""
    mesh = hall_obj.data
    for uv in list(mesh.uv_layers):
        mesh.uv_layers.remove(uv)
    layer = mesh.uv_layers.new(name="Tile")
    coords = [0.0] * (len(mesh.loops) * 2)
    names = [m.name.split(".")[0] for m in mesh.materials]
    for polygon in mesh.polygons:
        tile = TEXTURES[HALL_FINISH[names[polygon.material_index]][0]]["tile_metres"]
        n = polygon.normal
        axis = max(range(3), key=lambda i: abs(n[i]))
        for loop in polygon.loop_indices:
            co = mesh.vertices[mesh.loops[loop].vertex_index].co
            if axis == 2:      # floors, treads, ceilings
                u, v = co.x, co.y
            elif axis == 0:    # side walls run along Blender Y
                u, v = co.y * (1 if n.x > 0 else -1), co.z
            else:              # front, rear and risers
                u, v = co.x * (-1 if n.y > 0 else 1), co.z
            coords[loop * 2] = u / tile
            coords[loop * 2 + 1] = v / tile
    layer.data.foreach_set("uv", coords)


def bake_hall(hall_obj, size, margin):
    """Bakes lighting only (no surface colour) into the second UV layer."""
    mesh = hall_obj.data
    bake_uv = mesh.uv_layers.new(name="Bake")
    mesh.uv_layers.active = bake_uv
    select_only(hall_obj)
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    t = time.time()
    bpy.ops.uv.smart_project(angle_limit=math.radians(60), island_margin=0.0008, area_weight=0.0,
                             correct_aspect=True, scale_to_bounds=False)
    try:
        bpy.ops.uv.pack_islands(udim_source="CLOSEST_UDIM", rotate=True, margin_method="FRACTION", margin=0.0006,
                                shape_method="AABB")
    except TypeError:
        bpy.ops.uv.pack_islands(rotate=True, margin=0.0006)
    bpy.ops.object.mode_set(mode="OBJECT")
    print("UV unwrap %.1fs" % (time.time() - t))
    image = bpy.data.images.new("HallLightLinear", size, size, alpha=False, float_buffer=True)
    image.colorspace_settings.name = "Non-Color"
    for material in mesh.materials:
        node = material.node_tree.nodes.new("ShaderNodeTexImage")
        node.image = image
        material.node_tree.nodes.active = node
    t = time.time()
    bpy.ops.object.bake(type="DIFFUSE", pass_filter={"DIRECT", "INDIRECT"},
                        margin=margin, use_clear=True, target="IMAGE_TEXTURES")
    print("Hall bake %.1fs" % (time.time() - t))
    return image


def encode_light(image, path):
    """Stores irradiance / LIGHT_SCALE sRGB-encoded: 8-bit precision goes to the darks.
    JPEG is fine as a source: Godot re-encodes it to ETC2/ASTC for headsets anyway."""
    import numpy as np
    size = image.size[0]
    pixels = np.empty(size * size * 4, dtype=np.float32)
    image.pixels.foreach_get(pixels)
    pixels = pixels.reshape(size, size, 4)
    light = pixels[..., :3]
    print("Light p50=%.3f p99=%.3f max=%.3f scale=%.1f" % (np.percentile(light, 50), np.percentile(light, 99),
          light.max(), LIGHT_SCALE))
    value = np.clip(light / LIGHT_SCALE, 0.0, 1.0)
    value = np.where(value <= 0.0031308, value * 12.92, 1.055 * np.power(value, 1 / 2.4) - 0.055)
    encoded = bpy.data.images.new("HallLight", size, size, alpha=False, float_buffer=False)
    encoded.colorspace_settings.name = "Non-Color"  # bytes are written exactly as computed
    out = np.ones((size, size, 4), dtype=np.float32)
    out[..., :3] = value
    encoded.pixels.foreach_set(out.ravel())
    encoded.filepath_raw = os.path.abspath(path)
    encoded.file_format = "JPEG"
    encoded.save(quality=95)
    return encoded


def bake_seat_light(chunks, hidden):
    """Bakes each LOD set alone so coincident near/far chairs never shadow each other."""
    for obj in hidden:
        obj.hide_render = True
    for obj in chunks:
        obj.hide_render = False
        mesh = obj.data
        attr = mesh.color_attributes.new("Light", "BYTE_COLOR", "POINT")
        mesh.color_attributes.active_color = attr
    select_only(*chunks)
    t = time.time()
    bpy.ops.object.bake(type="DIFFUSE", pass_filter={"DIRECT", "INDIRECT"}, target="VERTEX_COLORS")
    print("Seat light bake %.1fs" % (time.time() - t))
    # Chair backs face away from the screen and bake almost black. A small floor
    # and gain stand in for the eye's dark adaptation, so nearby upholstery reads.
    for obj in chunks:
        data = obj.data.color_attributes["Light"].data
        values = [0.0] * (len(data) * 4)
        data.foreach_get("color", values)
        for index in range(0, len(values), 4):
            for channel in range(3):
                values[index + channel] = min(1.0, SEAT_LIGHT_FLOOR + values[index + channel] * SEAT_LIGHT_GAIN)
        data.foreach_set("color", values)


SEAT_LIGHT_FLOOR = 0.06
SEAT_LIGHT_GAIN = 1.7


def select_only(*objects):
    bpy.ops.object.select_all(action="DESELECT")
    for obj in objects:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = objects[0]


# --------------------------------------------------------------------------
# Preview (Blender EEVEE, unlit export materials)

def render_preview(manifest, directory, video_image=None):
    directory = os.path.abspath(directory)
    os.makedirs(directory, exist_ok=True)
    scene = bpy.context.scene
    for engine in ("BLENDER_EEVEE", "BLENDER_EEVEE_NEXT"):
        try:
            scene.render.engine = engine
            break
        except TypeError:
            continue
    scene.render.resolution_x, scene.render.resolution_y = 1600, 1000
    scene.view_settings.view_transform = "Standard"
    screen = manifest["screen"]
    # Bright stand-in picture for the live video layer (16:9 inside the 1.43 screen).
    w = screen["width"]
    h = w / (16 / 9)
    cy = screen["position"][1]
    b = Builder("PreviewVideo")
    z = screen["position"][2] + 0.035
    b.quad_facing((-w / 2, cy - h / 2, z), (w / 2, cy - h / 2, z), (w / 2, cy + h / 2, z), (-w / 2, cy + h / 2, z), "Video", (0, 0, 1))
    video = b.to_object({"Video": unlit_material("PreviewVideo", color=(0.55, 0.62, 0.75))})
    cam_data = bpy.data.cameras.new("Eye")
    cam = bpy.data.objects.new("Eye", cam_data)
    scene.collection.objects.link(cam)
    scene.camera = cam
    seats = {s["id"]: s for s in manifest["seats"]}
    views = [
        ("default", seats[manifest["default_seat"]]["eye_position"], None, 100),
        ("front-row", seats["A18"]["eye_position"], None, 100),
        ("rear-row", seats[[k for k in seats if k.startswith(chr(64 + manifest["design"]["row_count"]))][17]]["eye_position"], None, 100),
        ("overview", [13.0, 12.5, 26.5], [0.0, 6.0, 4.0], 90),
        ("reverse", [0.0, 6.0, 0.5], [0.0, 6.0, 26.0], 100),
    ]
    for name, eye, target, fov in views:
        e = G(*eye)
        if target is None:
            target = [eye[0], screen["position"][1] * 0.75 + eye[1] * 0.25, screen["position"][2]]
        direction = G(*target) - e
        cam.location = e
        cam.rotation_euler = direction.to_track_quat("-Z", "Y").to_euler()
        cam_data.angle = math.radians(fov)
        scene.render.filepath = os.path.join(directory, "%s.png" % name)
        bpy.ops.render.render(write_still=True)
        print("PREVIEW", scene.render.filepath)
    bpy.data.objects.remove(video)
    bpy.data.objects.remove(cam)


# --------------------------------------------------------------------------

def main():
    args = parse_args()
    started = time.time()
    with open(args.manifest, encoding="utf-8") as handle:
        manifest = json.load(handle)
    bpy.ops.wm.read_factory_settings(use_empty=True)
    hall = Hall(manifest)
    hall.build()

    bake_materials = {key: _principled(key, **spec) for key, spec in SURFACES.items()}
    glow_bake = {key: _emitter(key, color, strength) for key, (color, strength, _) in GLOWS.items()}
    glow_bake.update({key: _principled(key, color, 1.0) for key, color in FIXED.items()})
    hall_obj = hall.hall.to_object(bake_materials)
    fixtures = hall.fix.to_object(glow_bake)

    work = os.path.abspath(args.work)
    os.makedirs(work, exist_ok=True)
    seat_texture_path = os.path.join(work, "seat_baked.png")
    seat_bake_material = _principled("SeatBake", (0.20, 0.06, 0.07), 0.9)
    near_chunks, far_chunks = [], []
    global SEAT_PITCH
    SEAT_PITCH = manifest["design"]["seat_pitch"]
    for (source, end), suffix, target in zip(make_seats(seat_texture_path, args), ("near", "far"), (near_chunks, far_chunks)):
        for part in (source, end):
            part.data.materials.clear()
            part.data.materials.append(seat_bake_material)
        target.extend(build_seat_chunks(manifest, source, end, suffix))
        bpy.data.objects.remove(source)
        bpy.data.objects.remove(end)
    chunks = near_chunks + far_chunks

    setup_cycles(16 if args.quick else args.samples)
    emitter = add_screen_emitter(hall)
    # Detailed chairs occlude the floor and walls in the hall bake.
    for obj in far_chunks:
        obj.hide_render = True
    add_tile_uvs(hall_obj)
    linear_light = bake_hall(hall_obj, 1024 if args.quick else args.atlas, 4 if args.quick else 8)
    light = encode_light(linear_light, os.path.join(os.path.dirname(os.path.abspath(args.out)), LIGHT_FILE))
    bake_seat_light(near_chunks, far_chunks)
    bake_seat_light(far_chunks, near_chunks)
    for obj in chunks:
        obj.hide_render = False
    bpy.data.objects.remove(emitter)

    # Swap to unlit export materials.
    hall_keys = [m.name.split(".")[0] for m in hall_obj.data.materials]
    export_glow = {key: unlit_material(key, color=export) for key, (_, _, export) in GLOWS.items()}
    export_glow.update({key: unlit_material(key, color=color) for key, color in FIXED.items()})
    fixture_mesh = fixtures.data
    # Swap slots in place: clearing the list would drop per-face material indices.
    for index, material in enumerate(fixture_mesh.materials):
        fixture_mesh.materials[index] = export_glow[material.name.split(".")[0]]
    seat_image = bpy.data.images.load(seat_texture_path)
    seat_image.pack()
    seat_material = unlit_material("Seat", image=seat_image, uv="UVMap", color_attribute="Light")
    for obj in chunks:
        obj.data.materials.clear()
        obj.data.materials.append(seat_material)

    hall_mesh = hall_obj.data
    if args.preview:
        # Preview only: show tiled scan x baked light, as the Godot shader does.
        for index, key in enumerate(hall_keys):
            hall_mesh.materials[index] = preview_material(key, light)
        render_preview(manifest, args.preview)
    images = {}
    for index, key in enumerate(hall_keys):
        hall_mesh.materials[index] = hall_export_material(key, images)
    if args.save_blend:
        bpy.ops.wm.save_as_mainfile(filepath=os.path.abspath(args.save_blend))

    def count(objects):
        return sum(sum(len(p.vertices) - 2 for p in o.data.polygons) for o in objects)
    triangles = count([hall_obj, fixtures] + chunks)
    print("CINEMA_BUDGET hall=%d near=%d far=%d near_chunk_max=%d" % (count([hall_obj, fixtures]), count(near_chunks),
          count(far_chunks), max(count([o]) for o in near_chunks)))
    bpy.ops.export_scene.gltf(filepath=os.path.abspath(args.out), export_format="GLB", use_selection=False,
                              export_apply=True, export_texcoords=True, export_normals=False, export_tangents=False,
                              export_materials="EXPORT", export_image_format="JPEG", export_jpeg_quality=92,
                              export_vertex_color="MATERIAL", export_cameras=False, export_lights=False,
                              export_extras=False, export_yup=True, export_animations=False)
    print("CINEMA_BLENDER_OK triangles=%d seats=%d chunks=%d seconds=%.1f out=%s" % (
        triangles, len(manifest["seats"]), len(chunks), time.time() - started, args.out))


if __name__ == "__main__":
    main()
