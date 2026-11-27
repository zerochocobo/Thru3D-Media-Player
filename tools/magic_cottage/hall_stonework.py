"""Dressed stone, timber details, and the owner's wheeled star calendar."""

import math
import random

from mathutils import Vector

from hall_mesh import beam, block, collection, lathe, line, marker, material, oval, packed_image


def masonry(stones, oak, trim, brass):
    rng = random.Random(1739)
    collection("Fabric | flagstone floor and wall courses")
    for row in range(13):
        y = -2.3 + row * 7.2 / 13
        x = -4.5
        while x < 4.48:
            end = min(x + rng.uniform(0.68, 1.30), 4.5)
            block(
                "Honed limestone flag",
                ((x + end) / 2, y + 3.6 / 13, -0.040),
                (max(0.01, end - x - 0.014), 7.2 / 13 - 0.013, 0.083),
                rng.choice(stones),
                0.009,
            )
            x = end
    for side in (-1, 1):
        for row in range(8):
            y = -2.30
            while y < 4.88:
                end = min(y + rng.uniform(0.55, 1.16), 4.90)
                block(
                    "Wall ashlar",
                    (side * 4.51, (y + end) / 2, 0.20 + row * 0.434),
                    (0.065, max(0.01, end - y - 0.018), 0.417),
                    rng.choice(stones),
                    0.014,
                )
                y = end
        for k in range(3):
            x = side * (0.8 + k * 1.22)
            block("Longitudinal purlin", (x, 1.30, 5.12 - 0.378 * abs(x)), (0.12, 7.16, 0.14), oak, 0.013)
    for y in (-1.8, 0.55, 2.85, 4.60):
        for side in (-1, 1):
            for h in (2.43, 3.29):
                block("Pegged capital", (side * 4.29, y, h), (0.30, 0.32, 0.078), trim, 0.014)
                oval("Oak dowel", (side * 4.13, y, h), (0.014, 0.029, 0.029), oak)
            beam("Spandrel strut", (side * 4.10, y, 2.87), (side * 3.64, y, 3.80), 0.10, 0.14, trim, 0.013)
    # Traceries hug the high front gable. The brass beads follow the archivolt.
    for i in range(1, 32):
        a = math.pi * i / 32
        x, z = 2.73 * math.cos(a), 1.88 + 2.73 * math.sin(a)
        oval("Archivolt nail", (x, 4.702, z), (0.020, 0.013, 0.020), brass)


def portal_image(obj, source):
    """Project the existing original star-whale artwork into the modelled arch.

    The lower image band preserves the whale's aspect. The high crown fades
    into an indigo star field so no rectangular frame is visible.
    """
    mat = obj.data.materials[0]
    nodes, links = mat.node_tree.nodes, mat.node_tree.links
    surface = nodes["Principled BSDF"]
    tex = nodes.new("ShaderNodeTexImage")
    tex.image = packed_image(source)
    uv = obj.data.uv_layers.new(name="Inlaid mirror sky")
    for poly in obj.data.polygons:
        for idx in poly.loop_indices:
            vertex = obj.data.vertices[obj.data.loops[idx].vertex_index].co
            uv.data[idx].uv = (0.262 + (vertex.x + 2.65) * 0.0910, 0.41 + (vertex.z - 0.12) * 0.1635)
    # Sample only the water and sky inside the original concept's frame.
    coord = nodes.new("ShaderNodeTexCoord")
    clamp = nodes.new("ShaderNodeVectorMath")
    clamp.operation = "MINIMUM"
    clamp.inputs[1].default_value = (1, 0.777, 1)
    links.new(coord.outputs["UV"], clamp.inputs[0])
    links.new(clamp.outputs[0], tex.inputs["Vector"])
    sep = nodes.new("ShaderNodeSeparateXYZ")
    links.new(coord.outputs["Generated"], sep.inputs[0])
    crown = nodes.new("ShaderNodeValToRGB")
    crown.color_ramp.elements[0].position = 0.46
    crown.color_ramp.elements[1].position = 0.64
    links.new(sep.outputs["Z"], crown.inputs[0])
    specks = nodes.new("ShaderNodeTexVoronoi")
    specks.inputs["Scale"].default_value = 52
    links.new(coord.outputs["Generated"], specks.inputs["Vector"])
    stars = nodes.new("ShaderNodeValToRGB")
    stars.color_ramp.elements[0].position = 0.037
    stars.color_ramp.elements[0].color = (0.59, 0.78, 1.0, 1)
    stars.color_ramp.elements[1].position = 0.077
    stars.color_ramp.elements[1].color = (0.008, 0.014, 0.044, 1)
    links.new(specks.outputs["Distance"], stars.inputs[0])
    blend = nodes.new("ShaderNodeMixRGB")
    links.new(crown.outputs[0], blend.inputs[0])
    links.new(tex.outputs["Color"], blend.inputs[1])
    links.new(stars.outputs[0], blend.inputs[2])
    # The book gets an uncluttered, calm background while it is being read.
    sleep = nodes.new("ShaderNodeMixRGB")
    sleep.inputs[2].default_value = (0.006, 0.014, 0.032, 1)
    links.new(blend.outputs[0], sleep.inputs[1])
    for frame, fade in [(1, 0), (24, 0), (59, 1), (165, 1), (208, 0)]:
        sleep.inputs[0].default_value = fade
        sleep.inputs[0].keyframe_insert(data_path="default_value", frame=frame)
    links.new(sleep.outputs[0], surface.inputs["Emission Color"])
    surface.inputs["Emission Strength"].default_value = 1.18
    surface.inputs["Base Color"].default_value = (0.002, 0.003, 0.01, 1)
    surface.inputs["Specular IOR Level"].default_value = 0.025


def compass(x, y, z, r, brass, dark, name):
    disc = lathe(name, (x, y, z), [(r * 0.86, 0), (r, 0.014), (r, 0.040), (r * 0.94, 0.045)], dark, 48)
    disc.rotation_euler.x = math.pi / 2
    for radius in (0.87, 0.68):
        line(
            "Engraved calendar ring",
            [
                (
                    x + radius * r * math.cos(i * math.tau / 64),
                    y - 0.050,
                    z + radius * r * math.sin(i * math.tau / 64),
                )
                for i in range(64)
            ],
            0.006,
            brass,
            True,
        )
    for i in range(16):
        a = i * math.tau / 16
        line(
            "Calendar division",
            [
                (x + s * r * math.cos(a), y - 0.056, z + s * r * math.sin(a))
                for s in (0.70, 0.83 if i % 2 else 0.89)
            ],
            0.004,
            brass,
        )
    points = []
    for i in range(16):
        a = math.tau * i / 16
        radius = r * (0.66 if i % 4 == 0 else 0.48 if i % 2 == 0 else 0.16)
        points.append((x + radius * math.cos(a), y - 0.061, z + radius * math.sin(a)))
    line("Eight-point star", points, 0.009, brass, True)
    return marker("Aim.Portal", (x, y - 0.020, z))


def seat(oak, trim, linen, brass, seat_y):
    collection("South wall | reader's chair")
    block("Seat pan", (0, seat_y - 0.05, 0.45), (0.73, 0.68, 0.11), oak, 0.028)
    block("Flax cushion", (0, seat_y - 0.045, 0.527), (0.64, 0.57, 0.09), linen, 0.036)
    block("Scalloped oak back", (0, -2.238, 0.99), (0.70, 0.115, 0.95), trim, 0.035)
    for x in (-0.32, 0.32):
        for y in (seat_y + 0.21, -2.218):
            lathe(
                "Turned chair post",
                (x, y, 0),
                [
                    (0.045, 0),
                    (0.040, 0.07),
                    (0.05, 0.10),
                    (0.032, 0.25),
                    (0.043, 0.45),
                    (0.042, 0.71),
                    (0.049, 0.74),
                    (0.042, 0.77),
                ],
                oak,
                20,
            )
        block("Shaped arm rail", (x, seat_y - 0.08, 0.76), (0.112, 0.65, 0.112), trim, 0.032)
    for x in (-0.22, -0.11, 0, 0.11, 0.22):
        block("Carved back flute", (x, -2.172, 1.01), (0.028, 0.017, 0.60), oak, 0.009)
    # The wand rests on the rear-wall side of the chair in its hanging cradle.
    for x, z in ((0.575, 0.824), (0.685, 1.025)):
        block("Wand cradle", (x, -2.245, z), (0.067, 0.099, 0.018), brass, 0.005)


def wand_demo(seat_y, book, coffer, plant, wood, brass):
    collection("Wand | wall cradle and casting study")
    wand = marker("Hazel wand", (0.54, -2.22, 0.76))
    wand.rotation_mode = "QUATERNION"
    shaft = lathe(
        "Whittled shaft",
        (0, 0, 0),
        [
            (0.016, 0),
            (0.019, 0.029),
            (0.014, 0.121),
            (0.015, 0.144),
            (0.012, 0.159),
            (0.007, 0.30),
            (0.003, 0.414),
        ],
        wood,
        12,
    )
    shaft.parent = wand
    binding = line(
        "Helical grip",
        [(0.017 * math.cos(i * 0.28), 0.017 * math.sin(i * 0.28), 0.02 + i * 0.0008) for i in range(130)],
        0.0023,
        brass,
    )
    binding.parent = wand
    light = material("Amber wandlight", (1, 0.44, 0.10), 0.35, glow=3.2)
    tip = oval("Amber wand tip", (0, 0, 0.411), (0.005, 0.005, 0.012), light)
    tip.parent = wand
    home = Vector((0.54, -2.22, 0.76))
    hand = Vector((0.27, seat_y + 0.23, 0.85))
    rest = Vector((0.34, seat_y + 0.12, 0.71))
    upright = Vector((0.22, 0, 0.40)).normalized()
    low = Vector((0.40, 0.57, 0.04)).normalized()
    directions = [(target - hand).normalized() for target in (book, coffer, plant)]
    timeline = [
        (1, home, upright),
        (6, home, upright),
        (19, hand, directions[0]),
        (31, hand, directions[0]),
        (57, rest, low),
        (137, rest, low),
        (149, hand, directions[0]),
        (160, hand, directions[0]),
        (185, rest, low),
        (210, hand, directions[1]),
        (224, hand, directions[1]),
        (243, rest, low),
        (286, rest, low),
        (301, hand, directions[2]),
        (314, hand, directions[2]),
        (336, rest, low),
        (357, home, upright),
        (365, home, upright),
    ]
    for frame, position, direction in timeline:
        wand.location = position
        wand.rotation_quaternion = direction.to_track_quat("Z", "Y")
        wand.keyframe_insert(data_path="location", frame=frame)
        wand.keyframe_insert(data_path="rotation_quaternion", frame=frame)
    for target, direction, beats in zip((book, coffer, plant), directions, [(24,), (216,), (307,)]):
        strand = line("Casting filament", [hand + direction * 0.42, target], 0.0025, light)
        for beat in beats:
            for frame, hidden in [(1, True), (beat - 4, False), (beat + 3, True)]:
                strand.hide_render = hidden
                strand.hide_viewport = hidden
                strand.keyframe_insert(data_path="hide_render", frame=frame)
                strand.keyframe_insert(data_path="hide_viewport", frame=frame)
