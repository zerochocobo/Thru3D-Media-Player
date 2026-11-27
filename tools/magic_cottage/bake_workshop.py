"""Rebuild the editable and shipped workshop assets from project sources."""
import os
from pathlib import Path
import shutil
import subprocess

from PIL import Image

from star_charts import build
from coverlet import textile

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[1]
OUT=ROOT/"build/magic-cottage-design"
RUNTIME=ROOT/"app/godot/environments/magic_cottage"
MASTER=HERE/"source/coastal-hall.blend"
def blender(script, source=None, render=False):
    args=["blender","--background",str(source) if source else "--factory-startup","--threads","8","--python-exit-code","1","--python",str(HERE/script)]
    if render and os.environ.get("COTTAGE_CYCLES_DEVICE"):
        args+=["--","--cycles-device",os.environ["COTTAGE_CYCLES_DEVICE"]]
    subprocess.run(args,cwd=ROOT,check=True)

def main():
    OUT.mkdir(parents=True,exist_ok=True)
    build()
    textile()
    # The packer points the settle cloth at this imported copy (mipmapped, VRAM compressed).
    shutil.copyfile(OUT/"coverlet.jpg",RUNTIME/"coverlet.jpg")
    for name,source in [("rock","rock_boulder_dry_diff_2k.jpg"),("oak","wood_table_001_diff_2k.jpg")]:
        with Image.open(ROOT/"tools/beach/source/textures"/source) as im:
            im.resize((512,512),Image.Resampling.LANCZOS).save(OUT/(name+".jpg"),quality=86)
    blender("build_hall.py")
    shutil.copyfile(OUT/"great-hall.blend",MASTER)
    blender("export_workshop.py",MASTER)
    godot=shutil.which("godot_console") or shutil.which("godot")
    subprocess.run([godot,"--headless","--xr-mode","off","--path",str(ROOT/"app/godot"),"--log-file",str(OUT/"pack.log"),"--script",str(HERE/"pack_workshop.gd"),"--",str(OUT/"workshop.glb"),"res://environments/magic_cottage/workshop.res"],check=True)
    subprocess.run([godot,"--headless","--xr-mode","off","--path",str(ROOT/"app/godot"),"--log-file",str(OUT/"spell-surfaces.log"),"--script",str(HERE/"bake_spell_surfaces.gd")],check=True)
    subprocess.run([godot,"--headless","--xr-mode","off","--path",str(ROOT/"app/godot"),"--log-file",str(OUT/"flora-bake.log"),"--script",str(HERE/"bake_flora.gd")],check=True)
    subprocess.run([godot,"--headless","--xr-mode","off","--path",str(ROOT/"app/godot"),"--log-file",str(OUT/"ivy-bake.log"),"--script",str(HERE/"bake_room_ivy.gd")],check=True)
    subprocess.run([godot,"--headless","--xr-mode","off","--path",str(ROOT/"app/godot"),"--log-file",str(OUT/"apparition-props.log"),"--script",str(HERE/"bake_apparition_props.gd")],check=True)
    blender("render_ingredients.py",MASTER,True)
    plate=Image.new("RGBA",(256*6,256))
    for i in range(6):
        with Image.open(OUT/f"dose{i}.png") as icon:
            plate.paste(icon,(i*256,0))
    plate.save(RUNTIME/"ingredients.png",optimize=True)
    blender("render_workshop.py",MASTER,True)
    for name in ("workshop-alchemy","workshop-sofa"):
        shutil.copyfile(OUT/(name+".jpg"),ROOT/"docs/design/magic-cottage"/(name+".jpg"))
    with Image.open(OUT/"workshop-seat.jpg") as im:
        im.thumbnail((512,320))
        im.save(ROOT/"app/godot/backgrounds/previews/magic_cottage.jpg",quality=88)

if __name__=="__main__":
    main()
