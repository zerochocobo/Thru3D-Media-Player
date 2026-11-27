"""Modelling tools shared by the stone hall and its wall furnishings."""

import math

import bpy
from mathutils import Matrix, Vector


def collection(name):
    group = bpy.data.collections.new(name)
    bpy.context.scene.collection.children.link(group)
    bpy.context.view_layer.active_layer_collection = bpy.context.view_layer.layer_collection.children[name]
    return group


def material(name, colour, roughness=0.82, metal=0, glow=0):
    mat = bpy.data.materials.new(name)
    mat.diffuse_color = (*colour, 1)
    mat.use_nodes = True
    shader = mat.node_tree.nodes.get("Principled BSDF")
    for key, value in [
        ("Base Color", (*colour, 1)),
        ("Roughness", roughness),
        ("Metallic", metal),
        ("Emission Color", (*colour, 1)),
        ("Emission Strength", glow),
    ]:
        shader.inputs[key].default_value = value
    return mat


def packed_image(path):
    image = bpy.data.images.load(str(path), check_existing=True)
    if not image.packed_file:
        image.pack()
    return image


def mottling(mat, scale, low, high, grain):
    nodes, links = mat.node_tree.nodes, mat.node_tree.links
    noise = nodes.new("ShaderNodeTexNoise")
    noise.inputs["Scale"].default_value = scale
    noise.inputs["Detail"].default_value = 3.5
    palette = nodes.new("ShaderNodeValToRGB")
    palette.color_ramp.elements[0].position = 0.22
    palette.color_ramp.elements[0].color = (*low, 1)
    palette.color_ramp.elements[1].position = 0.81
    palette.color_ramp.elements[1].color = (*high, 1)
    links.new(noise.outputs["Fac"], palette.inputs[0])
    shader = nodes["Principled BSDF"]
    links.new(palette.outputs[0], shader.inputs["Base Color"])
    pores = nodes.new("ShaderNodeTexNoise")
    pores.inputs["Scale"].default_value = scale * 14
    bump = nodes.new("ShaderNodeBump")
    bump.inputs["Distance"].default_value = grain
    bump.inputs["Strength"].default_value = 0.30
    links.new(pores.outputs["Fac"], bump.inputs["Height"])
    links.new(bump.outputs[0], shader.inputs["Normal"])


def scan_surface(mat, image, tint, reference, scale, relief):
    """Use metre-based box projection so the stone and timber continue across joints."""
    nodes, links = mat.node_tree.nodes, mat.node_tree.links
    coords = nodes.new("ShaderNodeTexCoord")
    coords.object = reference
    mapping = nodes.new("ShaderNodeVectorMath")
    mapping.operation = "MULTIPLY"
    mapping.inputs[1].default_value = scale
    links.new(coords.outputs["Object"], mapping.inputs[0])
    tex = nodes.new("ShaderNodeTexImage")
    tex.image, tex.projection, tex.projection_blend = image, "BOX", 0.17
    links.new(mapping.outputs[0], tex.inputs["Vector"])
    colour = nodes.new("ShaderNodeMixRGB")
    colour.blend_type = "MULTIPLY"
    colour.inputs[0].default_value = 1
    colour.inputs[2].default_value = (*tint, 1)
    links.new(tex.outputs["Color"], colour.inputs[1])
    shader = nodes["Principled BSDF"]
    links.new(colour.outputs[0], shader.inputs["Base Color"])
    bump = nodes.new("ShaderNodeBump")
    bump.inputs["Strength"].default_value = 0.32
    bump.inputs["Distance"].default_value = relief
    links.new(tex.outputs["Color"], bump.inputs["Height"])
    links.new(bump.outputs[0], shader.inputs["Normal"])


def assign(obj, name, mat):
    obj.name = name
    obj.data.materials.append(mat)
    return obj


def mesh(name, verts, faces, mat):
    data = bpy.data.meshes.new(name)
    data.from_pydata(verts, [], faces)
    data.update()
    obj = bpy.data.objects.new(name, data)
    bpy.context.collection.objects.link(obj)
    return assign(obj, name, mat)


def bevel(obj, width):
    mod = obj.modifiers.new("Hand-worn edge", "BEVEL")
    mod.width, mod.segments = width, 2
    mod.harden_normals = True
    return obj


def block(name, at, size, mat, edge=0):
    bpy.ops.mesh.primitive_cube_add(size=1, location=at)
    obj = assign(bpy.context.object, name, mat)
    obj.data.transform(Matrix.Diagonal((*size, 1)))
    return bevel(obj, edge) if edge else obj


def beam(name, a, b, width, depth, mat, edge=0):
    direction = Vector(b) - Vector(a)
    obj = block(name, (Vector(a) + Vector(b)) / 2, (width, depth, direction.length), mat, edge)
    obj.rotation_euler = direction.to_track_quat("Z", "Y").to_euler()
    return obj


def prism(name, contour, y_front, y_back, mat):
    count = len(contour)
    verts = [(x, y, z) for y in (y_front, y_back) for x, z in contour]
    faces = [tuple(range(count)), tuple(reversed(range(count, count * 2)))]
    faces.extend((i, count + i, count + (i + 1) % count, (i + 1) % count) for i in range(count))
    return mesh(name, verts, faces, mat)


def lathe(name, at, profile, mat, segments=32):
    verts = [
        (r * math.cos(i * math.tau / segments), r * math.sin(i * math.tau / segments), z)
        for r, z in profile
        for i in range(segments)
    ]
    faces = []
    for row in range(len(profile) - 1):
        for i in range(segments):
            a, b = row * segments + i, row * segments + (i + 1) % segments
            faces.append((a, b, b + segments, a + segments))
    faces += [tuple(reversed(range(segments))), tuple(range(len(verts) - segments, len(verts)))]
    obj = mesh(name, verts, faces, mat)
    obj.location = at
    for poly in obj.data.polygons[:-2]:
        poly.use_smooth = True
    return obj


def oval(name, at, radii, mat):
    bpy.ops.mesh.primitive_uv_sphere_add(segments=16, ring_count=10, location=at)
    obj = assign(bpy.context.object, name, mat)
    obj.scale = radii
    for poly in obj.data.polygons:
        poly.use_smooth = True
    return obj


def line(name, points, width, mat, loop=False):
    data = bpy.data.curves.new(name, "CURVE")
    data.dimensions, data.resolution_u = "3D", 1
    data.bevel_depth, data.bevel_resolution = width, 2
    path = data.splines.new("POLY")
    path.points.add(len(points) - 1)
    for point, pos in zip(path.points, points):
        point.co = (*pos, 1)
    path.use_cyclic_u = loop
    obj = bpy.data.objects.new(name, data)
    bpy.context.collection.objects.link(obj)
    return assign(obj, name, mat)


def marker(name, at, size=0.12):
    obj = bpy.data.objects.new(name, None)
    bpy.context.collection.objects.link(obj)
    obj.location, obj.empty_display_size = at, size
    return obj
