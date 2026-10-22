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
    parser.add_argument("--atlas", type=int, default=4096)
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
    "Nosing": dict(color=(0.085, 0.085, 0.09), roughness=0.5),
    "Fabric": dict(color=(0.030, 0.032, 0.040), noise=dict(scale=6.0, amount=0.18)),
    "FabricDeep": dict(color=(0.022, 0.023, 0.029), noise=dict(scale=6.0, amount=0.18)),
    "Velvet": dict(color=(0.006, 0.006, 0.007)),
    "Reveal": dict(color=(0.004, 0.004, 0.005)),
    "Wood": dict(color=(0.070, 0.038, 0.021), stripes=dict(scale=1.5, amount=0.12, direction="Z", distortion=1.0)),
    "Ceiling": dict(color=(0.010, 0.010, 0.012)),
    "Cloud": dict(color=(0.020, 0.021, 0.024), noise=dict(scale=3.0, amount=0.12)),
    "Metal": dict(color=(0.09, 0.095, 0.10), roughness=0.35),
    "Rail": dict(color=(0.20, 0.205, 0.21), roughness=0.3),
    "Speaker": dict(color=(0.012, 0.012, 0.013), noise=dict(scale=80.0, amount=0.4)),
    "Door": dict(color=(0.050, 0.030, 0.020), stripes=dict(scale=5.0, amount=0.25, direction="Z")),
    "Stage": dict(color=(0.005, 0.005, 0.006)),
}

# Emitters: (bake colour, bake strength, export colour). Export colours are what
# the eye sees directly; bake strengths are what they throw onto the room.
GLOWS = {
    "StepLed": ((1.0, 0.62, 0.30), 18.0, (1.0, 0.66, 0.36)),
    "Sconce": ((1.0, 0.70, 0.42), 9.0, (1.0, 0.78, 0.55)),
    "StageGlow": ((1.0, 0.60, 0.32), 5.0, (0.85, 0.50, 0.26)),
    "Exit": ((0.10, 0.90, 0.40), 4.0, (0.20, 0.95, 0.50)),
    "Star": ((1.0, 0.85, 0.65), 1.5, (0.62, 0.52, 0.40)),
    "Booth": ((0.45, 0.60, 1.0), 2.0, (0.10, 0.15, 0.24)),
    "RowLetter": ((1.0, 0.72, 0.45), 2.0, (0.95, 0.70, 0.45)),
}
FIXED = {
    # Visible but not lighting anything (black masking, unlit screen surface).
    "Masking": (0.0035, 0.0035, 0.004),
    "ScreenIdle": (0.011, 0.0115, 0.013),
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
        self.first_edge = self.first_z - self.pitch * 0.5
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

    def ceiling(self, z):
        t = (z - self.front) / (self.back - self.front)
        return self.H + (self.H_rear - self.H) * t

    def floor_line(self, z):
        """Smooth stair nosing line beside the seating, used by wall trims."""
        if z <= self.first_edge:
            return 0.0
        return min(self.top, (z - self.first_edge) / self.pitch * self.riser)

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
        f.quad_facing((-W + 0.6, 0.04, stage_front + 0.01), (W - 0.6, 0.04, stage_front + 0.01),
                      (W - 0.6, 0.075, stage_front + 0.01), (-W + 0.6, 0.075, stage_front + 0.01), "StageGlow", (0, 0, 1))
        # Front floor from stage to the first tier.
        h.quad_facing((-W, 0, stage_front), (W, 0, stage_front), (W, 0, self.first_edge), (-W, 0, self.first_edge),
                      "Carpet", (0, 1, 0))

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
                self.text(letter, (x + side * 0.004, level - 0.32, z0 + 0.25), side, 0.16, "RowLetter")
        # One continuous staircase on each side, from the seating block to the wall.
        for step in range(self.rows * self.steps):
            z0 = self.first_edge + step * self.tread
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
        h.quad_facing((-W, self.top, self.rear_edge), (W, self.top, self.rear_edge), (W, self.top, self.back),
                      (-W, self.top, self.back), "Carpet", (0, 1, 0))

    def build_rails(self):
        h = self.hall
        for side in (-1.0, 1.0):
            x = side * self.rail
            for row in range(self.rows + 1):
                z = self.first_edge + row * self.pitch + self.tread * 0.5
                floor = min(self.top, (row * self.steps + 1) * self.step_rise)
                h.tube((x, floor, z), (x, floor + 0.98, z), 0.022, "Rail", segments=6)
            start = (x, self.step_rise + 1.0, self.first_edge + self.tread * 0.5)
            end = (x, min(self.top, (self.rows * self.steps + 1) * self.step_rise) + 1.0,
                   self.first_edge + self.rows * self.pitch + self.tread * 0.5)
            h.tube(start, end, 0.03, "Rail", segments=8)
            # Glass-free mid rail keeps the edge legible at a distance.
            h.tube((x, start[1] - 0.45, start[2]), (x, end[1] - 0.45, end[2]), 0.012, "Rail", segments=6)

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
            # Wainscot follows the stair line so the wall reads at human scale.
            samples = 48
            for i in range(samples):
                za = self.front + (self.back - self.front) * i / samples
                zb = self.front + (self.back - self.front) * (i + 1) / samples
                ya, yb = self.floor_line(za), self.floor_line(zb)
                x = wall_x - side * 0.06
                h.quad_facing((x, ya - 0.3, za), (x, yb - 0.3, zb), (x, yb + 1.15, zb), (x, ya + 1.15, za), "Wood", inward)
                h.quad_facing((x, ya + 1.15, za), (x, yb + 1.15, zb), (wall_x, yb + 1.15, zb), (wall_x, ya + 1.15, za), "Wood", (0, 1, 0))
            for b in range(bays):
                z0 = self.front + b * bay
                z1 = z0 + bay
                deep = (b % 2 == 0)
                depth = 0.20 if deep else 0.08
                inset = 0.06
                material = "FabricDeep" if z1 < self.screen_z + 6.0 else "Fabric"
                bottom0, bottom1 = self.floor_line(z0) + 1.2, self.floor_line(z1) + 1.2
                top0, top1 = self.ceiling(z0) - 0.9, self.ceiling(z1) - 0.9
                x = wall_x - side * depth
                za, zb = z0 + inset, z1 - inset
                bza = self.floor_line(za) + 1.2
                bzb = self.floor_line(zb) + 1.2
                tza, tzb = self.ceiling(za) - 0.9, self.ceiling(zb) - 0.9
                h.quad_facing((x, bza, za), (x, bzb, zb), (x, tzb, zb), (x, tza, za), material, inward)
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
                    y = self.floor_line(zc) + 5.6
                    xi = wall_x - side * (depth + 0.38)
                    lo = (min(xi, wall_x - side * depth), y - 0.45, zc - 0.30)
                    hi = (max(xi, wall_x - side * depth), y + 0.45, zc + 0.30)
                    h.box(lo, hi, "Speaker", faces="+y-y+z-z" + ("-x" if side > 0 else "+x"))
            self.build_side_door(side)

    def build_side_door(self, side):
        h, f = self.hall, self.fix
        W = self.W
        z0, z1 = 0.4, 2.4
        x = side * (W - 0.21)
        inward = (-side, 0, 0)
        # Opening frame, two leaves and push bars, then the exit sign above.
        h.box((min(x, x - side * 0.12), 0, z0 - 0.12), (max(x, x - side * 0.12), 2.52, z0), "Metal", faces="+y+z-z" + ("-x" if side > 0 else "+x"))
        h.box((min(x, x - side * 0.12), 0, z1), (max(x, x - side * 0.12), 2.52, z1 + 0.12), "Metal", faces="+y+z-z" + ("-x" if side > 0 else "+x"))
        h.box((min(x, x - side * 0.12), 2.4, z0), (max(x, x - side * 0.12), 2.52, z1), "Metal", faces="-y" + ("-x" if side > 0 else "+x"))
        xd = side * (W - 0.15)
        mid = (z0 + z1) * 0.5
        for za, zb in ((z0, mid - 0.01), (mid + 0.01, z1)):
            h.quad_facing((xd, 0, za), (xd, 0, zb), (xd, 2.4, zb), (xd, 2.4, za), "Door", inward)
            h.tube((xd - side * 0.09, 1.02, za + 0.12), (xd - side * 0.09, 1.02, zb - 0.12), 0.018, "Metal", segments=6)
        xs = side * (W - 0.24)
        f.quad_facing((xs, 2.78, mid - 0.22), (xs, 2.78, mid + 0.22), (xs, 2.98, mid + 0.22), (xs, 2.98, mid - 0.22), "Exit", inward)
        h.box((min(xs, xs + side * 0.06), 2.74, mid - 0.25), (max(xs, xs + side * 0.06), 3.02, mid + 0.25), "Speaker",
              faces="+y-y+z-z" + ("-x" if side > 0 else "+x"))

    # -- Rear wall, doors and projection ports -----------------------------------
    def build_rear(self):
        h, f = self.hall, self.fix
        W, z = self.W, self.back
        y0, y1 = self.top, self.ceiling(self.back)
        h.quad_facing((-W, y0 - 0.3, z), (W, y0 - 0.3, z), (W, y0 + 1.15, z), (-W, y0 + 1.15, z), "Wood", (0, 0, -1))
        h.quad_facing((-W, y0 + 1.15, z), (W, y0 + 1.15, z), (W, y1, z), (-W, y1, z), "FabricDeep", (0, 0, -1))
        # Projection ports: a dark glass band with two faint lens glows.
        f.quad_facing((-3.6, y0 + 3.6, z - 0.02), (3.6, y0 + 3.6, z - 0.02), (3.6, y0 + 4.5, z - 0.02), (-3.6, y0 + 4.5, z - 0.02), "Booth", (0, 0, -1))
        h.box((-3.75, y0 + 3.45, z - 0.18), (3.75, y0 + 3.6, z), "Metal", faces="+y-z")
        for x in (-1.2, 1.2):
            f.quad_facing((x - 0.18, y0 + 3.86, z - 0.03), (x + 0.18, y0 + 3.86, z - 0.03),
                          (x + 0.18, y0 + 4.18, z - 0.03), (x - 0.18, y0 + 4.18, z - 0.03), "Sconce", (0, 0, -1))
        # Rear exits beside the cross aisle.
        for side in (-1.0, 1.0):
            xc = side * (self.rail + W) * 0.5
            x0, x1 = xc - 0.95, xc + 0.95
            h.quad_facing((x0, y0, z - 0.1), (x1, y0, z - 0.1), (x1, y0 + 2.4, z - 0.1), (x0, y0 + 2.4, z - 0.1), "Door", (0, 0, -1))
            for lo, hi in (((x0 - 0.12, y0, z - 0.2), (x0, y0 + 2.52, z)), ((x1, y0, z - 0.2), (x1 + 0.12, y0 + 2.52, z)),
                           ((x0 - 0.12, y0 + 2.4, z - 0.2), (x1 + 0.12, y0 + 2.52, z))):
                h.box(lo, hi, "Metal", faces="-z+y-x+x-y")
            for xa, xb in ((x0, xc - 0.01), (xc + 0.01, x1)):
                h.tube((xa + 0.12, y0 + 1.02, z - 0.19), (xb - 0.12, y0 + 1.02, z - 0.19), 0.018, "Metal", segments=6)
            f.quad_facing((xc - 0.22, y0 + 2.8, z - 0.03), (xc + 0.22, y0 + 2.8, z - 0.03),
                          (xc + 0.22, y0 + 3.0, z - 0.03), (xc - 0.22, y0 + 3.0, z - 0.03), "Exit", (0, 0, -1))

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
                for ix in range(3):
                    for iz in range(2):
                        px = x0 + (ix + 0.5) * (x1 - x0) / 3
                        pz = z0 + (iz + 0.5) * cloud_depth / 2
                        py = self.ceiling(pz) - 1.1 - 0.004
                        f.quad_facing((px - 0.05, py, pz - 0.05), (px + 0.05, py, pz - 0.05), (px + 0.05, py, pz + 0.05),
                                      (px - 0.05, py, pz + 0.05), "Star", (0, -1, 0))
            z += cloud_depth + gap
        # Side walls continue above the cove up to the sloped ceiling (front and rear covered elsewhere).

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
    """Returns (near, far) chair source objects sharing one baked texture."""
    if not args.placeholder_seats:
        import seat_model
        seat_model.bake_seat_texture(texture_path, 256 if args.quick else args.seat_texture)
        return seat_model.build_seat("SeatNear", 0), seat_model.build_seat("SeatFar", 1)
    near = make_placeholder_seat(texture_path)
    far = near.copy()
    far.data = near.data.copy()
    bpy.context.scene.collection.objects.link(far)
    return near, far


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


SEATS_PER_CHUNK = 10


def build_seat_chunks(manifest, seat_object, suffix):
    """Joins ten-seat runs into one mesh: few draw calls, fine-grained culling,
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
            for origin in picks:
                count = len(bm.verts)
                bm.from_mesh(source)
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


def bake_hall(hall_obj, size, margin):
    mesh = hall_obj.data
    for uv in list(mesh.uv_layers):
        mesh.uv_layers.remove(uv)
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
    image = bpy.data.images.new("HallLight", size, size, alpha=False, float_buffer=False)
    image.colorspace_settings.name = "sRGB"
    for material in mesh.materials:
        node = material.node_tree.nodes.new("ShaderNodeTexImage")
        node.image = image
        material.node_tree.nodes.active = node
    t = time.time()
    bpy.ops.object.bake(type="COMBINED", pass_filter={"EMIT", "DIRECT", "INDIRECT", "DIFFUSE"},
                        margin=margin, use_clear=True, target="IMAGE_TEXTURES")
    print("Hall bake %.1fs" % (time.time() - t))
    return image


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
    for source, suffix, target in zip(make_seats(seat_texture_path, args), ("near", "far"), (near_chunks, far_chunks)):
        source.data.materials.clear()
        source.data.materials.append(seat_bake_material)
        target.extend(build_seat_chunks(manifest, source, suffix))
        bpy.data.objects.remove(source)
    chunks = near_chunks + far_chunks

    setup_cycles(16 if args.quick else args.samples)
    emitter = add_screen_emitter(hall)
    # Detailed chairs occlude the floor and walls in the hall bake.
    for obj in far_chunks:
        obj.hide_render = True
    atlas = bake_hall(hall_obj, 1024 if args.quick else args.atlas, 4 if args.quick else 12)
    bake_seat_light(near_chunks, far_chunks)
    bake_seat_light(far_chunks, near_chunks)
    for obj in chunks:
        obj.hide_render = False
    bpy.data.objects.remove(emitter)

    # Swap to unlit export materials.
    hall_material = unlit_material("Hall", image=atlas, uv="Bake")
    hall_obj.data.materials.clear()
    hall_obj.data.materials.append(hall_material)
    hall_obj.data.polygons.foreach_set("material_index", [0] * len(hall_obj.data.polygons))
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
    atlas.pack()

    if args.preview:
        render_preview(manifest, args.preview)
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
