"""Photograph the actual shelf models for the illustrated recipe equations."""
import bpy
from mathutils import Vector
from pathlib import Path
out=Path(__file__).resolve().parents[2]/"build/magic-cottage-design"
scene=bpy.context.scene
cam=scene.camera
cam.data.type="ORTHO"
scene.render.resolution_x=scene.render.resolution_y=256
scene.render.resolution_percentage=100
scene.cycles.samples=18
scene.render.film_transparent=True
scene.render.image_settings.file_format="PNG"
scene.render.image_settings.color_mode="RGBA"
for obj in scene.objects:
    if obj.type in {"MESH","CURVE","LIGHT"}:
        obj.hide_render=True
def softbox(name,position,aim,power,color,size):
    light=bpy.data.lights.new(name,"AREA")
    light.energy=power
    light.shape="DISK"
    light.size=size
    light.color=color
    obj=bpy.data.objects.new(name,light)
    scene.collection.objects.link(obj)
    obj.location=position
    obj.rotation_euler=(aim-obj.location).to_track_quat("-Z","Y").to_euler()
    return obj
for i in range(6):
    objects=bpy.data.collections["Dose"+str(i)].objects
    bounds=[o.matrix_world@Vector(corner) for o in objects for corner in o.bound_box]
    target=Vector([(min(p[k] for p in bounds)+max(p[k] for p in bounds))*.5 for k in range(3)])
    cam.location=target+Vector((-1.3,-.64,.42))
    cam.rotation_euler=(target-cam.location).to_track_quat("-Z","Y").to_euler()
    cam.data.ortho_scale=max(max(p[k] for p in bounds)-min(p[k] for p in bounds) for k in range(3))*1.18
    lights=[softbox("Window",target+Vector((-1.1,-.75,1.5)),target,80,(1,.94,.82),.8),
            softbox("Rim",target+Vector((.45,.82,.69)),target,95,(.68,.82,1),.62)]
    for o in objects: o.hide_render=False
    scene.render.filepath=str(out/("dose%d.png"%i))
    bpy.ops.render.render(write_still=True)
    for o in objects: o.hide_render=True
    for light in lights: bpy.data.objects.remove(light,do_unlink=True)
