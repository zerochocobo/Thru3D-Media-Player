"""Extend the reviewed study to the production hall with two baked light states.

Shared chair albedo, per-vertex chair irradiance, tiled architectural scans and
two architectural irradiance maps. One GLB contains both LODs and both states.
"""
import argparse
import hashlib
import json
import math
import struct
import sys
import time
from pathlib import Path

import bpy
import numpy as np
from mathutils.bvhtree import BVHTree

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))
import build_hall as hall
import build_sample as study
import seat_model as seats

LIGHT_SCALE = 8.0
# Left/centre/right screen strips; packed as R/G/B of the screen light map and
# as TEXCOORD_2.x, TEXCOORD_2.y, TEXCOORD_3.x on chairs (Godot CUSTOM0.xyz).
SCREEN_ZONES = 3
# Watts per zone for a white strip; runtime divides film linear colour by the
# reference grey the old fixed 14500 W bounce stood for.
SCREEN_ZONE_WATTS = 14500 / 3
OUT = ROOT / 'build/output/cinema-full-lighting'
SOURCE = HERE / 'full_hall'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def upholstered_back():
    material = study.scan('velour', .92)
    material.name = 'Study_back'
    nodes, links = material.node_tree.nodes, material.node_tree.links
    bsdf = nodes.get('Principled BSDF')
    source = bsdf.inputs['Base Color'].links[0].from_socket
    darker = nodes.new('ShaderNodeMix'); darker.data_type = 'RGBA'; darker.blend_type = 'MULTIPLY'
    darker.inputs[0].default_value = 1.0
    darker.inputs[7].default_value = (BACK_SHADE, BACK_SHADE, BACK_SHADE, 1.0)
    links.new(source, darker.inputs[6]); links.new(darker.outputs[2], bsdf.inputs['Base Color'])
    return material


BACK_SHADE = .55


def setup_materials():
    # Fully upholstered chairs: the back and shell use the same woven fabric,
    # darker, so the backs viewers study show a real weave instead of plastic noise.
    chair = [study.scan('velour', .92), upholstered_back(), study.scan('leather', .48),
             hall._principled('Study_dark_metal', (.075, .077, .080), .42),
             hall._principled('Study_cup', (.013, .015, .018), .42),
             hall._principled('Study_leg', (.028, .031, .035), .55)]
    scan_names = {'Carpet': 'carpet', 'Tread': 'carpet', 'Riser': 'carpet',
                  'Fabric': 'wall', 'FabricDeep': 'wall', 'Wood': 'wood', 'Door': 'wood'}
    scan_materials = {name: study.scan(name, .95 if name != 'wood' else .52) for name in set(scan_names.values())}
    materials = {key: scan_materials[scan_names[key]] if key in scan_names else hall._principled(key, **spec)
                 for key, spec in hall.SURFACES.items()}
    # Keep material keys stable for the runtime and existing authoring utilities.
    materials = {key: material.copy() for key, material in materials.items()}
    for key, material in materials.items(): material.name = key
    # Existing near-black/matte finishes retain the production CC0 texture set.
    data = json.loads((study.TEXTURES / 'sources.json').read_text())
    for key, name in scan_names.items():
        texture_key = 'study_' + name
        hall.TEXTURES[texture_key] = {'file': str(study.TEXTURES / (name + '_color.jpg')), 'tile_metres': data[name]['tile_metres']}
        hall.HALL_FINISH[key] = (texture_key, .65 if key in ['FabricDeep', 'Riser'] else 1.0)
    return chair, materials


def chair_source(name, lod, materials, end=False):
    mesh = seats._make_mesh(name, lod, zones=True, parts=seats._end_parts(lod) if end else None)
    for material in materials: mesh.materials.append(material)
    for poly in mesh.polygons: poly.material_index = mesh.attributes['seat_zone'].data[poly.index].value
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.scene.collection.objects.link(obj)
    seats.smooth_terminator(obj)
    return obj


def bake_albedo(obj):
    image = bpy.data.images.new('SharedChairAlbedo', 2048, 2048, alpha=False, float_buffer=True)
    for material in obj.data.materials:
        node = material.node_tree.nodes.new('ShaderNodeTexImage')
        node.image = image; material.node_tree.nodes.active = node
    hall.select_only(obj)
    bpy.ops.object.bake(type='DIFFUSE', pass_filter={'COLOR'}, margin=12, use_clear=True)
    path = OUT / 'seat_albedo.png'
    image.save_render(str(path), scene=bpy.context.scene)
    return path


def lighting(h, mode):
    enabled = mode == 'on'
    for obj in bpy.context.scene.objects:
        if obj.type == 'LIGHT' and obj.get('house_watts') is not None:
            obj.data.energy = obj['house_watts'] if enabled else 0
    for key in ['Sconce', 'Star', 'StageGlow']:
        material = bpy.data.materials[key]
        node = next(n for n in material.node_tree.nodes if n.type == 'EMISSION')
        node.inputs['Strength'].default_value = hall.GLOWS[key][1] if enabled else 0


def add_lights(h):
    # The screen is no longer a fixed light: three white zone emitters are baked
    # alone and scaled at runtime by the film's left/centre/right colour.
    width = h.screen_w / SCREEN_ZONES
    for zone in range(SCREEN_ZONES):
        x = -h.screen_w / 2 + (zone + .5) * width
        obj = study.area('ScreenZone%d' % zone, (x, h.screen_y, h.screen_z + .1), (x, h.screen_y, h.screen_z + 20),
                         0, width, (1, 1, 1), h.screen_h)
        obj['screen_zone'] = zone
    # Repeated ceiling bays use the reviewed study's warm, broad house lighting.
    for row in [2, 5, 8, 11, 14]:
        z = h.first_edge + (row - .5) * h.pitch
        floor = row * h.riser
        for x in [-10.4, 0, 10.4]:
            obj = study.area('HouseCeiling', (x, min(h.ceiling(z) - 1.3, floor + 5.6), z),
                             (x, floor, z), 1050, 4, (1, .76, .53), 4)
            obj['house_watts'] = 1050
        for side in [-1, 1]:
            for name, x, height, target_x, target_height, energy, size, color, size_y in [
                ('HouseAisle', 14.5, 4.4, 10, 1.0, 420, 3, (1, .84, .65), 3),
                ('HouseWash', 16.2, 3.6, 16.7, 2.0, 170, 1.2, (1, .57, .26), .2)]:
                obj = study.area(name, (side*x, floor+height, z), (side*target_x, floor+target_height, z), energy, size, color, size_y)
                obj['house_watts'] = energy


def unwrap_hall(obj):
    hall.add_tile_uvs(obj)
    obj.data.uv_layers.active = obj.data.uv_layers.new(name='Bake')
    hall.select_only(obj)
    bpy.ops.object.mode_set(mode='EDIT'); bpy.ops.mesh.select_all(action='SELECT')
    bpy.ops.uv.smart_project(angle_limit=math.radians(60), island_margin=.001, area_weight=0)
    bpy.ops.uv.pack_islands(udim_source='CLOSEST_UDIM', rotate=True, margin_method='FRACTION', margin=.0015, shape_method='AABB')
    bpy.ops.object.mode_set(mode='OBJECT')


def bake_hall(obj, size, mode):
    obj.data.uv_layers.active = obj.data.uv_layers['Bake']
    image = bpy.data.images.new('Hall_' + mode, size, size, alpha=False, float_buffer=True)
    image.colorspace_settings.name = 'Non-Color'
    for material in obj.data.materials:
        node = material.node_tree.nodes.new('ShaderNodeTexImage'); node.image = image
        material.node_tree.nodes.active = node
    hall.select_only(obj)
    bpy.ops.object.bake(type='DIFFUSE', pass_filter={'DIRECT', 'INDIRECT'}, margin=12, use_clear=True)
    hall.LIGHT_SCALE = LIGHT_SCALE
    name = 'cinema_light.jpg' if mode == 'on' else 'cinema_light_off.jpg'
    hall.encode_light(image, str(OUT / name))
    print('FULL_HALL_BAKED', mode, flush=True)


def bake_chairs(chunks, hidden, mode):
    for obj in hidden: obj.hide_render = True
    for obj in chunks:
        obj.hide_render = False
        attr = obj.data.color_attributes.new('Irradiance_' + mode, 'FLOAT_COLOR', 'POINT')
        obj.data.color_attributes.active_color = attr
    hall.select_only(*chunks)
    bpy.ops.object.bake(type='DIFFUSE', pass_filter={'DIRECT', 'INDIRECT'}, target='VERTEX_COLORS')
    print('FULL_CHAIRS_BAKED', mode, chunks[0].name, flush=True)


def bake_screen_zones(architecture, near, far, size):
    """Each zone alone, everything else dark: house lights, sconces, safety and step glows."""
    lighting(None, 'off')
    glows = {}
    for key in hall.GLOWS:
        node = next(n for n in bpy.data.materials[key].node_tree.nodes if n.type == 'EMISSION')
        glows[key] = node.inputs['Strength'].default_value; node.inputs['Strength'].default_value = 0
    zones = [obj for obj in bpy.context.scene.objects if obj.type == 'LIGHT' and obj.get('screen_zone') is not None]
    channels = []
    for zone in range(SCREEN_ZONES):
        for obj in zones: obj.data.energy = SCREEN_ZONE_WATTS if obj['screen_zone'] == zone else 0
        for obj in near: obj.hide_render = False
        for obj in far: obj.hide_render = True
        image = bake_irradiance(architecture, size, 'Zone%d' % zone)
        pixels = np.empty(size * size * 4, dtype=np.float32); image.pixels.foreach_get(pixels)
        channels.append(pixels.reshape(size, size, 4)[..., :3] @ np.array([.2126, .7152, .0722], dtype=np.float32))
        bake_chairs(near, far, 'zone%d' % zone); bake_chairs(far, near, 'zone%d' % zone)
    for obj in zones: obj.data.energy = 0
    for key, value in glows.items():
        next(n for n in bpy.data.materials[key].node_tree.nodes if n.type == 'EMISSION').inputs['Strength'].default_value = value
    packed = bpy.data.images.new('ScreenZones', size, size, alpha=False, float_buffer=True)
    rgba = np.ones((size, size, 4), dtype=np.float32); rgba[..., :3] = np.stack(channels, axis=-1)
    packed.pixels.foreach_set(rgba.ravel())
    hall.LIGHT_SCALE = LIGHT_SCALE
    hall.encode_light(packed, str(OUT / 'cinema_screen_light.jpg'))
    print('FULL_SCREEN_ZONES_BAKED', flush=True)


def bake_irradiance(obj, size, name):
    obj.data.uv_layers.active = obj.data.uv_layers['Bake']
    image = bpy.data.images.new('Hall_' + name, size, size, alpha=False, float_buffer=True)
    image.colorspace_settings.name = 'Non-Color'
    for material in obj.data.materials:
        node = material.node_tree.nodes.new('ShaderNodeTexImage'); node.image = image
        material.node_tree.nodes.active = node
    hall.select_only(obj)
    bpy.ops.object.bake(type='DIFFUSE', pass_filter={'DIRECT', 'INDIRECT'}, margin=12, use_clear=True)
    return image


def pack_chair_light(obj):
    mesh = obj.data
    count = len(mesh.vertices)
    values = {}
    for mode in ['on', 'off']:
        pixels = np.empty(count * 4, dtype=np.float32)
        mesh.color_attributes['Irradiance_' + mode].data.foreach_get('color', pixels)
        values[mode] = np.sqrt(np.clip(pixels.reshape(count, 4)[:, :3] / LIGHT_SCALE, 0, 1))
    zones = []
    for zone in range(SCREEN_ZONES):
        pixels = np.empty(count * 4, dtype=np.float32)
        mesh.color_attributes['Irradiance_zone%d' % zone].data.foreach_get('color', pixels)
        rgb = pixels.reshape(count, 4)[:, :3]
        zones.append(np.sqrt(np.clip((rgb @ np.array([.2126, .7152, .0722], dtype=np.float32)) / LIGHT_SCALE, 0, 1)))
    for attr in list(mesh.color_attributes): mesh.color_attributes.remove(attr)
    packed = mesh.color_attributes.new('DualLight', 'FLOAT_COLOR', 'POINT')
    rgba = np.ones((count, 4), dtype=np.float32)
    rgba[:, :3] = values['on']; rgba[:, 3] = values['off'][:, 2]
    packed.data.foreach_set('color', rgba.ravel()); mesh.color_attributes.active_color = packed
    layer = mesh.uv_layers.new(name='LightOffRG')
    indices = np.empty(len(mesh.loops), dtype=np.int32); mesh.loops.foreach_get('vertex_index', indices)
    uv = values['off'][indices, :2].copy()
    # glTF flips Blender UV V; encode so exported TEXCOORD_1 contains R,G directly.
    uv[:, 1] = 1 - uv[:, 1]; layer.data.foreach_set('uv', uv.ravel())
    # Screen zones: TEXCOORD_2 = (left, centre), TEXCOORD_3 = (right, 0); Godot reads
    # both as CUSTOM0.xyzw. V is flipped by the exporter like TEXCOORD_1 above.
    for name, pair in [('ScreenLC', (zones[0], zones[1])), ('ScreenR', (zones[2], np.zeros(count, dtype=np.float32)))]:
        layer = mesh.uv_layers.new(name=name)
        uv = np.stack([pair[0][indices], 1 - pair[1][indices]], axis=1).astype(np.float32)
        layer.data.foreach_set('uv', uv.ravel())


def verify_safety_diffusers(architecture, fixtures):
    bpy.context.view_layer.update()
    tree = BVHTree.FromObject(architecture, bpy.context.evaluated_depsgraph_get())
    clearances = []
    for face in fixtures.data.polygons:
        name = fixtures.data.materials[face.material_index].name.split('.')[0]
        if name not in ['Exit', 'StageGlow']: continue
        _, _, _, distance = tree.ray_cast(face.center, -face.normal, .2)
        assert distance is not None and distance >= .025, (name, 'coplanar or missing backing', distance)
        clearances.append({'fixture': name, 'backing_clearance_metres': distance})
    assert len(clearances) == 5, 'Expected four exits and one stage diffuser'
    return clearances


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--samples', type=int, default=256)
    parser.add_argument('--atlas', type=int, default=4096)
    args = parser.parse_args(sys.argv[sys.argv.index('--')+1:] if '--' in sys.argv else [])
    started = time.time(); OUT.mkdir(parents=True, exist_ok=True); SOURCE.mkdir(exist_ok=True)
    manifest_path = ROOT / 'app/godot/environments/grand_cinema/manifest.json'
    manifest = json.loads(manifest_path.read_text())
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene; hall.setup_cycles(args.samples)
    scene.cycles.max_bounces = 7; scene.cycles.diffuse_bounces = 5; scene.cycles.glossy_bounces = 2
    scene.cycles.seed = 23
    scene.view_settings.view_transform = 'Standard'; scene.view_settings.look = 'None'
    scene.view_settings.exposure = 0; scene.view_settings.gamma = 1
    chair_materials, hall_materials = setup_materials()
    near_source = chair_source('SeatSource', 0, chair_materials)
    albedo = bake_albedo(near_source)
    bpy.data.objects.remove(near_source, do_unlink=True)
    h = hall.Hall(manifest); h.build()
    architecture = h.hall.to_object(hall_materials)
    fixtures = h.fix.to_object({**{k: hall._emitter(k,c,e) for k,(c,e,_) in hall.GLOWS.items()},
                              **{k: hall._principled(k,c,1) for k,c in hall.FIXED.items()}})
    diffuser_clearances = verify_safety_diffusers(architecture, fixtures)
    hall.SEAT_PITCH = manifest['design']['seat_pitch']
    sets = []
    for lod, suffix in [(0,'near'), (1,'far')]:
        source = chair_source('SeatSource', lod, chair_materials)
        end = chair_source('EndSource', lod, chair_materials, True)
        sets.append(hall.build_seat_chunks(manifest, source, end, suffix))
        bpy.data.objects.remove(source, do_unlink=True); bpy.data.objects.remove(end, do_unlink=True)
    near, far = sets
    add_lights(h); unwrap_hall(architecture)
    for obj in far: obj.hide_render = True
    scene['dual_light_scale'] = LIGHT_SCALE
    scene['source_manifest_sha256'] = sha(manifest_path)
    bpy.context.preferences.filepaths.save_version = 0
    # Only original texture inputs are required to reconstruct; bake targets are unlinked.
    for material in chair_materials:
        for node in list(material.node_tree.nodes):
            if node.type == 'TEX_IMAGE' and node.image and node.image.name == 'SharedChairAlbedo': material.node_tree.nodes.remove(node)
    bpy.ops.wm.save_as_mainfile(filepath=str(SOURCE / 'study.blend'))
    bpy.ops.file.make_paths_relative(); bpy.ops.wm.save_as_mainfile(filepath=str(SOURCE / 'study.blend'))
    for mode in ['on', 'off']:
        lighting(h, mode)
        for obj in near: obj.hide_render = False
        for obj in far: obj.hide_render = True
        bake_hall(architecture, args.atlas, mode)
        bake_chairs(near, far, mode); bake_chairs(far, near, mode)
    bake_screen_zones(architecture, near, far, args.atlas // 2)
    # Shared base color; no second copy of geometry and no per-seat light textures.
    image = bpy.data.images.load(str(albedo), check_existing=False); image.pack()
    seat_material = hall.unlit_material('SeatDual', image=image, uv=seats.UV_NAME, color_attribute='DualLight')
    for obj in near+far:
        obj.hide_render = False; pack_chair_light(obj)
        obj.data.materials.clear(); obj.data.materials.append(seat_material)
        for poly in obj.data.polygons: poly.material_index = 0
    images = {}
    for i, material in enumerate(architecture.data.materials):
        architecture.data.materials[i] = hall.hall_export_material(material.name.split('.')[0], images)
    for i, material in enumerate(fixtures.data.materials):
        key = material.name.split('.')[0]
        fixtures.data.materials[i] = hall.unlit_material(key, color=hall.GLOWS[key][2] if key in hall.GLOWS else hall.FIXED[key])
    for obj in list(scene.objects):
        if obj.type == 'LIGHT': bpy.data.objects.remove(obj, do_unlink=True)
    # Re-exportable checkpoint is disposable; editable source/inputs stay in tools/.
    bpy.ops.wm.save_as_mainfile(filepath=str(OUT/'export.blend'))
    bpy.ops.export_scene.gltf(filepath=str(OUT/'cinema.glb'), export_format='GLB', export_texcoords=True,
        export_normals=False, export_tangents=False, export_materials='EXPORT', export_image_format='JPEG', export_jpeg_quality=95,
        export_vertex_color='NAME', export_vertex_color_name='DualLight', export_cameras=False, export_lights=False, export_animations=False, export_yup=True)
    raw = (OUT/'cinema.glb').read_bytes()
    document = json.loads(raw[20:20+struct.unpack_from('<I',raw,12)[0]])
    for mesh in document['meshes']:
        if not mesh['name'].startswith('Seats_'): continue
        primitive = mesh['primitives'][0]
        assert document['accessors'][primitive['attributes']['COLOR_0']]['type'] == 'VEC4', 'Off-blue channel omitted'
        assert 'TEXCOORD_1' in primitive['attributes'], 'Off red/green channels omitted'
        assert 'TEXCOORD_2' in primitive['attributes'] and 'TEXCOORD_3' in primitive['attributes'], 'Screen zone channels omitted'
    result = {'samples': args.samples, 'atlas': args.atlas, 'light_scale': LIGHT_SCALE, 'seconds':time.time()-started,
              'safety_diffusers': diffuser_clearances,
              'manifest_sha256':sha(manifest_path), 'triangles':sum(seats.triangle_count(o) for o in [architecture,fixtures]+near+far),
              'chair_encoding':'COLOR_0.rgb=sqrt(on/8); TEXCOORD_1.rg,COLOR_0.a=sqrt(off/8); opaque custom shader',
              'lighting':'Independent Cycles direct+indirect solves; fixed screen and safety lights; warm house area lights on/off',
              'files':{name: {'bytes':(OUT/name).stat().st_size,'sha256':sha(OUT/name)} for name in ['cinema.glb','cinema_light.jpg','cinema_light_off.jpg','cinema_screen_light.jpg']}}
    (SOURCE/'build.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
    print('CINEMA_FULL_LIGHTING_OK',json.dumps(result),flush=True)


if __name__ == '__main__': main()
