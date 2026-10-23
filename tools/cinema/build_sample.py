"""Bake a local, movable 3D study in the existing hall: rows H-J, seats 21-24.

Reuses the production manifest, Hall and seat_model; never replaces the hall.
Blender --background --python tools/cinema/build_sample.py -- --samples 128
"""
import argparse
import hashlib
import json
import math
import sys
import time
from pathlib import Path

import bpy
from mathutils import Vector

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))
import build_hall as hall
import seat_model as seats

ASSETS = HERE / 'sample/assets'
TEXTURES = HERE / 'sample/textures'
TARGET_ROWS = (8, 9, 10)
TARGET_COLS = (21, 22, 23, 24)


def select(objects):
    bpy.ops.object.select_all(action='DESELECT')
    for obj in objects:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = objects[0]


def scan(name, roughness, tile=None):
    mat = bpy.data.materials.new('Study_' + name)
    mat.use_nodes = True
    nt = mat.node_tree
    bsdf = nt.nodes.get('Principled BSDF')
    bsdf.inputs['Roughness'].default_value = roughness
    data = json.loads((TEXTURES / 'sources.json').read_text())[name]
    coord = nt.nodes.new('ShaderNodeTexCoord')
    scale = nt.nodes.new('ShaderNodeVectorMath'); scale.operation = 'SCALE'
    scale.inputs[3].default_value = 1 / (tile or data['tile_metres'])
    nt.links.new(coord.outputs['Object'], scale.inputs[0])
    for channel in ['color', 'displacement', 'roughness']:
        tex = nt.nodes.new('ShaderNodeTexImage')
        tex.image = bpy.data.images.load(str(TEXTURES / (name + '_' + channel + '.jpg')), check_existing=True)
        tex.projection = 'BOX'; tex.projection_blend = .18
        nt.links.new(scale.outputs['Vector'], tex.inputs['Vector'])
        if channel == 'color':
            nt.links.new(tex.outputs['Color'], bsdf.inputs['Base Color'])
        elif channel == 'displacement':
            tex.image.colorspace_settings.name = 'Non-Color'
            bump = nt.nodes.new('ShaderNodeBump')
            bump.inputs['Strength'].default_value = .38
            bump.inputs['Distance'].default_value = .002 if name in ['carpet', 'wall', 'velour'] else .0007
            nt.links.new(tex.outputs['Color'], bump.inputs['Height'])
            nt.links.new(bump.outputs['Normal'], bsdf.inputs['Normal'])
        else:
            tex.image.colorspace_settings.name = 'Non-Color'
            remap = nt.nodes.new('ShaderNodeMapRange')
            remap.inputs['To Min'].default_value = roughness * .8
            remap.inputs['To Max'].default_value = min(roughness * 1.15, 1)
            nt.links.new(tex.outputs['Color'], remap.inputs['Value'])
            nt.links.new(remap.outputs['Result'], bsdf.inputs['Roughness'])
    return mat


def area(name, position, target, energy, size, color, size_y=None):
    light = bpy.data.lights.new(name, 'AREA')
    light.energy = energy; light.color = color; light.shape = 'RECTANGLE'
    light.size = size; light.size_y = size_y or size
    obj = bpy.data.objects.new(name, light); bpy.context.collection.objects.link(obj)
    obj.location = hall.G(*position)
    obj.rotation_euler = (hall.G(*target) - obj.location).to_track_quat('-Z', 'Y').to_euler()
    return obj


def join(objects, name):
    select(objects); bpy.ops.object.join()
    obj = bpy.context.object; obj.name = name
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    return obj


def unwrap(obj):
    select([obj])
    for uv in list(obj.data.uv_layers): obj.data.uv_layers.remove(uv)
    obj.data.uv_layers.new(name='StudyBake')
    bpy.ops.object.mode_set(mode='EDIT'); bpy.ops.mesh.select_all(action='SELECT')
    bpy.ops.uv.smart_project(angle_limit=math.radians(72), island_margin=.006, area_weight=.3)
    bpy.ops.object.mode_set(mode='OBJECT')


def bake(obj, size, output=None, unwrap_target=True):
    if unwrap_target: unwrap(obj)
    image = bpy.data.images.new(obj.name + '_Bake', size, size, alpha=False, float_buffer=True)
    for slot in obj.material_slots:
        # A material may belong to another target too. Only its active target node changes.
        nt = slot.material.node_tree
        node = nt.nodes.new('ShaderNodeTexImage'); node.image = image; nt.nodes.active = node
    select([obj])
    bpy.ops.object.bake(type='DIFFUSE', pass_filter={'DIRECT', 'INDIRECT', 'COLOR'}, margin=12, use_clear=True)
    image.filepath_raw = str((output or ROOT / 'build/output/cinema-sample') / (obj.name + '.png')); image.file_format = 'PNG'
    image.save_render(image.filepath_raw, scene=bpy.context.scene)
    print('SAMPLE_BAKED', obj.name, flush=True)
    return image.filepath_raw


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--samples', type=int, default=128)
    parser.add_argument('--atlas', type=int, default=2048)
    parser.add_argument('--render-only', action='store_true')
    args = parser.parse_args(sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else [])
    ASSETS.mkdir(parents=True, exist_ok=True)
    output = ROOT / 'build/output/cinema-sample'; output.mkdir(parents=True, exist_ok=True)
    start = time.time()
    manifest_path = ROOT / 'app/godot/environments/grand_cinema/manifest.json'
    manifest = json.loads(manifest_path.read_text())
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    scene.render.engine = 'CYCLES'; hall.setup_cycles(args.samples)
    scene.cycles.max_bounces = 7; scene.cycles.diffuse_bounces = 5
    scene.cycles.glossy_bounces = 2
    scene.cycles.use_denoising = True
    scene.view_settings.view_transform = 'Standard'; scene.view_settings.look = 'None'
    scene.view_settings.exposure = 0; scene.view_settings.gamma = 1
    scene.world.node_tree.nodes['Background'].inputs['Color'].default_value = (.25, .32, .45, 1)
    scene.world.node_tree.nodes['Background'].inputs['Strength'].default_value = .055
    # Same production architecture supplies occlusion and bounce, but is not exported.
    h = hall.Hall(manifest); h.build()
    context = h.hall.to_object({k: hall._principled('Context_' + k, **v) for k, v in hall.SURFACES.items()})
    fixtures = h.fix.to_object({**{k: hall._emitter(k, c, e) for k, (c, e, _) in hall.GLOWS.items()},
                               **{k: hall._principled(k, c, 1) for k, c in hall.FIXED.items()}})
    mats = [scan('velour', .92), scan('shell', .52), scan('leather', .48),
            hall._principled('Study_dark_metal', (.075, .077, .080), .42),
            hall._principled('Study_cup', (.013, .015, .018), .42),
            hall._principled('Study_leg', (.028, .031, .035), .55)]
    floor_mat = scan('carpet', .95)
    wall_mat = scan('wall', .96)
    wood_mat = scan('wood', .52)
    trim_mat = hall._principled('Study_bronze', (.13, .08, .035), .52)
    groups = []
    for row in TARGET_ROWS:
        parts = []
        for seat in [s for s in manifest['seats'] if s['row'] == row and s['column'] in TARGET_COLS]:
            mesh = seats._make_mesh('StudySeat_' + seat['id'], 0, zones=True)
            for mat in mats: mesh.materials.append(mat)
            zones = mesh.attributes['seat_zone']
            for poly in mesh.polygons: poly.material_index = zones.data[poly.index].value
            obj = bpy.data.objects.new(mesh.name, mesh); scene.collection.objects.link(obj)
            x, y, z = seat['eye_position']; obj.location = hall.G(x, y - manifest['design']['seated_eye_height'], z + .1)
            seats.smooth_terminator(obj); parts.append(obj)
        # Match the existing end console, including its material zones.
        mesh = seats._make_mesh('StudyEnd', 0, zones=True, parts=seats._end_parts(0))
        for mat in mats: mesh.materials.append(mat)
        for poly in mesh.polygons: poly.material_index = mesh.attributes['seat_zone'].data[poly.index].value
        obj = bpy.data.objects.new('StudyEnd', mesh); scene.collection.objects.link(obj)
        end = next(s for s in manifest['seats'] if s['row'] == row and s['column'] == 24)
        x, y, z = end['eye_position']; obj.location = hall.G(x + .45, y - 1.2, z + .1); parts.append(obj)
        groups.append(join(parts, 'StudySeats_%02d' % row))
    # Local floor/risers follow the original manifest exactly, offset 4mm to avoid coplanar draw.
    b = hall.Builder('StudyArchitecture')
    for row in TARGET_ROWS:
        z0 = h.first_edge + (row - 1) * h.pitch; z1 = z0 + h.pitch; level = row * h.riser
        b.quad_facing((7.13, level + .004, z0), (h.platform, level + .004, z0),
                      (h.platform, level + .004, z1), (7.13, level + .004, z1), 'carpet', (0, 1, 0))
        b.box((7.13, level - .65, z0 - .004), (h.platform, level, z0), 'carpet', faces='-z')
        b.box((7.13, level - .022, z0 - .018), (h.platform, level + .010, z0 + .022), 'trim', faces='+y-z')
        for step in range(4):
            za = z0 + step * h.tread; top = ((row - 1) * 4 + step + 1) * h.step_rise
            b.quad_facing((h.platform, top + .004, za), (16.72, top + .004, za),
                          (16.72, top + .004, za + h.tread), (h.platform, top + .004, za + h.tread), 'carpet', (0, 1, 0))
            b.box((h.platform, top - h.step_rise, za - .004), (16.72, top, za), 'carpet', faces='-z')
    # Slim timber wainscot and fabric panels stay behind the existing walkable boundary.
    za = h.first_edge + 7 * h.pitch; zb = za + 3 * h.pitch
    for i in range(9):
        a = za + i * .5; c = a + .484
        ya, yc = h.floor_line(a), h.floor_line(c)
        b.quad_facing((16.71, ya, a), (16.71, yc, c), (16.71, yc + 1.1, c), (16.71, ya + 1.1, a), 'wood', (-1, 0, 0))
        b.quad_facing((16.70, ya + 1.12, a), (16.70, yc + 1.12, c), (16.70, yc + 4.4, c), (16.70, ya + 4.4, a), 'wall', (-1, 0, 0))
        b.quad_facing((16.69, ya + 1.10, a), (16.69, yc + 1.10, c), (16.69, yc + 1.12, c), (16.69, ya + 1.12, a), 'trim', (-1, 0, 0))
    groups.append(b.to_object({'carpet': floor_mat, 'wall': wall_mat, 'wood': wood_mat, 'trim': trim_mat}))
    area('ScreenBounce', (0, 10.2, -3.9), (0, 6, 17), 14500, 31, (.73, .83, 1), 17)
    area('LocalCeiling', (10.4, 10.8, 17.8), (9.2, 5.8, 17.8), 1050, 4, (1, .76, .53), 4)
    area('AisleFill', (14.5, 9.6, 17.8), (10, 6.2, 17.8), 420, 3, (1, .84, .65), 3)
    area('WallWash', (16.2, 8.8, 17.5), (16.7, 7.2, 17.5), 170, 1.2, (1, .57, .26), .2)
    # Neighbor silhouettes keep the small study from baking as an isolated showroom.
    for s in manifest['seats']:
        if s['row'] not in range(7, 12) or s['column'] not in range(17, 25): continue
        if s['row'] in TARGET_ROWS and s['column'] in TARGET_COLS: continue
        o = seats.build_seat('ContextSeat_' + s['id'], 1)
        o.data.materials.clear(); o.data.materials.append(mats[0])
        x, y, z = s['eye_position']; o.location = hall.G(x, y - 1.2, z + .1)
    cam_data = bpy.data.cameras.new('StudyCamera'); camera = bpy.data.objects.new('StudyCamera', cam_data)
    scene.collection.objects.link(camera); scene.camera = camera
    camera.location = hall.G(12.5, 7.9, 16.0)
    camera.rotation_euler = (hall.G(9.2, 6.25, 17.7) - camera.location).to_track_quat('-Z', 'Y').to_euler()
    cam_data.lens = 30
    scene.render.resolution_x = 1440; scene.render.resolution_y = 960
    scene.render.resolution_percentage = 100
    # Durable editable source, with portable texture references and the review camera.
    bpy.context.preferences.filepaths.save_version = 0
    bpy.ops.wm.save_as_mainfile(filepath=str(ASSETS / 'study.blend'))
    bpy.ops.file.make_paths_relative()
    bpy.ops.wm.save_as_mainfile(filepath=str(ASSETS / 'study.blend'))
    scene.render.filepath = str(output / 'offline-reference.png'); bpy.ops.render.render(write_still=True)
    if args.render_only: return
    baked = {o.name: bake(o, args.atlas) for o in groups}
    # Remove bake-only surroundings and lights; the existing Godot hall supplies context.
    for o in list(scene.objects):
        if o not in groups: bpy.data.objects.remove(o, do_unlink=True)
    for obj in groups:
        image = bpy.data.images.load(baked[obj.name], check_existing=False); image.pack()
        mat = hall.unlit_material(obj.name + '_Unlit', image=image, uv='StudyBake')
        obj.data.materials.clear(); obj.data.materials.append(mat)
        for poly in obj.data.polygons: poly.material_index = 0
        for attr in list(obj.data.color_attributes): obj.data.color_attributes.remove(attr)
    model = ASSETS / 'sample.glb'
    bpy.ops.export_scene.gltf(filepath=str(model), export_format='GLB', export_materials='EXPORT',
        export_image_format='AUTO', export_normals=True, export_tangents=False, export_texcoords=True,
        export_cameras=False, export_lights=False, export_animations=False, export_yup=True)
    result = {'source_manifest_sha256': hashlib.sha256(manifest_path.read_bytes()).hexdigest(),
        'rows': TARGET_ROWS, 'columns': TARGET_COLS, 'atlas_size': args.atlas, 'samples': args.samples,
        'triangles': sum(seats.triangle_count(o) for o in groups), 'seconds': time.time() - start,
        'model_sha256': hashlib.sha256(model.read_bytes()).hexdigest(),
        'approach': 'Per-surface Cycles diffuse direct+indirect+color; no shared seat lighting multiplied twice; opaque unlit runtime; local warm house-light study, no dynamic movie illumination.'}
    (ASSETS / 'build.json').write_text(json.dumps(result, indent=2) + '\n', encoding='utf8')
    print('CINEMA_SAMPLE_OK', json.dumps(result), flush=True)


if __name__ == '__main__': main()
