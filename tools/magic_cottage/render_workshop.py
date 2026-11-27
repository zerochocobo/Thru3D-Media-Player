"""Render the actual Blender master, including the furnishings behind the seated eye."""
import bpy
from mathutils import Vector
from pathlib import Path

out=Path(__file__).resolve().parents[2]/"build/magic-cottage-design"
scene=bpy.context.scene
scene.frame_set(1)
scene.render.resolution_x=1200
scene.render.resolution_y=720
scene.render.resolution_percentage=100
scene.cycles.samples=10
scene.cycles.use_denoising=True
cam=scene.camera
for name,location,aim,lens in [
    ("workshop-seat",(0,-1.82,1.15),(0,4.8,1.77),16),
    ("workshop-alchemy",(.27,-.05,2.14),(4.07,2.37,1.40),26),
    ("workshop-sofa",(1.92,1.31,1.83),(0,-1.83,.72),38),
]:
    cam.location=location
    cam.rotation_euler=(Vector(aim)-Vector(location)).to_track_quat("-Z","Y").to_euler()
    cam.data.lens=lens
    scene.render.filepath=str(out/(name+".jpg"))
    scene.render.image_settings.file_format="JPEG"
    scene.render.image_settings.quality=90
    bpy.ops.render.render(write_still=True)
