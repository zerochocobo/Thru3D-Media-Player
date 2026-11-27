"""Bake the editable Blender collections into a small number of indexed XR draws."""
import json
import os
import struct
import time
from collections import defaultdict
from pathlib import Path

import bpy
import numpy as np

ROOT=Path(os.environ.get("COTTAGE_ROOT",Path(__file__).resolve().parents[2]))
OUT=ROOT/"build/magic-cottage-design"
scene=bpy.context.scene
scene.frame_set(1)
SKIP=("Still water","Glazed lancet","First cotyledon","Seed husk")
# Baked irradiance spans two orders of magnitude between a dark corner and a candle dish. It is
# exposed and rolled off toward WHITE (Reinhard), then stored at half strength: corner colours are
# 8 bit on the headset, and the unshaded material lifts them back (pack_workshop.gd LIGHT_LIFT).
EXPOSURE=float(os.environ.get("COTTAGE_LIGHT_EXPOSURE","6.0"))
WHITE=float(os.environ.get("COTTAGE_LIGHT_WHITE","3.0"))
# Bounce the bake misses under the roof and behind furniture; keeps beams from going black.
AMBIENT=float(os.environ.get("COTTAGE_LIGHT_AMBIENT","0.25"))
BAKED=OUT/"baked-light.blend"

# Polished surfaces get a rim and glint in the headset (room_sheen.gdshader).
SHEEN=("Antique crown glass","Hammered brass","Woad-blue salt glaze","Tidal star mirror")

def shipped(obj):
    if obj.type not in {"MESH","CURVE"} or obj.hide_render: return False
    col=obj.users_collection[0].name
    return not col.startswith("Wand") and not obj.name.startswith(SKIP)

def tone(irradiance):
    x=(irradiance+AMBIENT)*EXPOSURE
    return .5*x/(1+x/WHITE)

def bake_light():
    """Bake the hall's own Cycles lights, direct and bounced but without surface colour, into a
    corner colour on every shipped object. The headset then draws the room unshaded, with no
    real-time lights."""
    for obj in scene.objects:
        if obj.users_collection and obj.users_collection[0].name.startswith("Wand"): obj.hide_render=True
    targets=[o for o in scene.objects if shipped(o)]
    for o in scene.objects: o.select_set(False)
    for o in targets:
        o.hide_set(False); o.hide_viewport=False; o.hide_select=False
        o.select_set(True)
    bpy.context.view_layer.objects.active=targets[0]
    bpy.ops.object.make_single_user(object=True,obdata=True)
    bpy.ops.object.convert(target="MESH")
    targets=[o for o in scene.objects if shipped(o)]
    for o in targets:
        attr=o.data.color_attributes.new("Baked light","FLOAT_COLOR","CORNER")
        o.data.color_attributes.active_color=attr
        o.select_set(True)
    # The player's hearth lamp, which the Blender renders never had, so the brew lights the floor.
    hearth=bpy.data.lights.new("Hearth glow (baked)","POINT")
    hearth.energy, hearth.color, hearth.shadow_soft_size = 140, (1, .58, .30), .25
    lamp=bpy.data.objects.new("Hearth glow (baked)",hearth)
    lamp.location=(3.72,.94,1.13)
    scene.collection.objects.link(lamp)
    prefs=bpy.context.preferences.addons["cycles"].preferences
    prefs.compute_device_type=os.environ.get("COTTAGE_CYCLES_DEVICE","OPTIX")
    prefs.get_devices()
    for device in prefs.devices: device.use=device.type==prefs.compute_device_type
    scene.cycles.device="GPU"
    scene.cycles.samples=int(os.environ.get("COTTAGE_BAKE_SAMPLES","256"))
    scene.render.bake.target="VERTEX_COLORS"
    started=time.time()
    bpy.ops.object.bake(type="DIFFUSE",pass_filter={"DIRECT","INDIRECT"},target="VERTEX_COLORS")
    # Roof boards, window reveals and the like face out of the hall, so their front bake sees the
    # night outside. Bake the other side as well; the export keeps the side facing the room.
    for o in targets:
        o.data.flip_normals()
        attr=o.data.color_attributes.new("Baked light back","FLOAT_COLOR","CORNER")
        o.data.color_attributes.active_color=attr
    bpy.ops.object.bake(type="DIFFUSE",pass_filter={"DIRECT","INDIRECT"},target="VERTEX_COLORS")
    for o in targets: o.data.flip_normals()
    print("WORKSHOP LIGHT BAKE",len(targets),"objects",round(time.time()-started,1),"s",flush=True)
    # About half an hour of GPU work: keep it, so the tone curve can be tuned by exporting again.
    bpy.ops.wm.save_as_mainfile(filepath=str(BAKED),copy=True)

if not any(o.type=="MESH" and o.data.color_attributes.get("Baked light back") for o in scene.objects if shipped(o)):
    bake_light()
graph=bpy.context.evaluated_depsgraph_get()
lights=[]
parts=defaultdict(lambda:defaultdict(list))
pivot={}
labels={"Fabric":"Shell","Glazing":"Lead","South wall":"Settle","West wall":"Library",
        "East wall | herbalist":"Dresser","East wall | singing":"Coffer","Front wall":"MirrorSeal",
        "Manuscript | Star":"Atlas","Manuscript | Moonbell":"Herbal","Manuscript | Projection":"Journal"}
for obj in scene.objects:
    if not shipped(obj): continue
    col=obj.users_collection[0].name
    group=next((v for k,v in labels.items() if col.startswith(k)),col if col in {"Jug","Kettle","Fire","Recipe"} or col.startswith("Dose") else "Shell")
    ev=obj.evaluated_get(graph)
    mesh=ev.to_mesh()
    if mesh is None or not len(mesh.polygons):
        ev.to_mesh_clear()
        continue
    mesh.calc_loop_triangles()
    loop=np.empty(len(mesh.loop_triangles)*3,np.int32)
    mesh.loop_triangles.foreach_get("loops",loop)
    vid=np.empty(len(mesh.loops),np.int32)
    mesh.loops.foreach_get("vertex_index",vid)
    p=np.empty(len(mesh.vertices)*3,np.float32)
    mesh.vertices.foreach_get("co",p)
    matrix=np.array(ev.matrix_world)
    p=p.reshape(-1,3)[vid[loop]]@matrix[:3,:3].T+matrix[:3,3]
    n=np.empty(len(mesh.corner_normals)*3,np.float32)
    mesh.corner_normals.foreach_get("vector",n)
    n=n.reshape(-1,3)[loop]@np.linalg.pinv(matrix[:3,:3])
    n/=np.maximum(np.linalg.norm(n,axis=1,keepdims=True),.00001)
    mat=mesh.materials[0] if mesh.materials else None
    name=mat.name if mat else ""
    kind="oak" if name in ("Hewn oak","Worn oak","Roof underside") else "rock" if name.startswith(("Arch stone","Limewashed")) else "ember" if name in ("Wick flame","Peat fire") else "brew" if name=="Luminous decoction" else "sheen" if name in SHEEN else "plain"
    if name=="Madder coverlet": kind="cloth"
    rgb=np.array(mat.diffuse_color[:3] if mat else (.36,.32,.25))
    if kind in ("rock","oak"): rgb=np.minimum(1,rgb*(2.35 if kind=="rock" else 2.85))
    light=np.ones((len(loop),3),np.float32)
    baked=mesh.color_attributes.get("Baked light")
    if baked is not None and kind not in ("ember","brew"):
        corner=np.empty(len(mesh.loops)*4,np.float32)
        baked.data.foreach_get("color",corner)
        raw=corner.reshape(-1,4)[loop][:,:3]
        back=mesh.color_attributes.get("Baked light back")
        if back is not None:
            back.data.foreach_get("color",corner)
            behind=corner.reshape(-1,4)[loop][:,:3]
            # Every light is inside the hall, so a surface's other side is solid or night sky and
            # bakes near zero; the brighter side is the one facing into the room.
            raw=np.maximum(raw,behind)
        lights.append(raw.max(axis=1))
        light=tone(raw)
    shade=np.minimum(1,rgb*light).round(3)
    axis=np.abs(n.reshape(-1,3,3).mean(axis=1)).argmax(axis=1).repeat(3)
    u=np.where(axis==0,p[:,1],p[:,0])
    v=np.where(axis==2,p[:,1],p[:,2])
    u,v=u*.9,v*.9
    if kind=="cloth":
        uv=np.empty(len(mesh.loops)*2,np.float32)
        mesh.uv_layers.active.data.foreach_get("uv",uv)
        textile_uv=uv.reshape(-1,2)[loop]
        u,v=textile_uv[:,0],1-textile_uv[:,1]
    data=np.column_stack((p[:,0],p[:,2],-p[:,1],n[:,0],n[:,2],-n[:,1],u,v,shade)).astype("<f4")
    parts[group][kind].append(data)
    ev.to_mesh_clear()

doc={"asset":{"version":"2.0","generator":"Thru3D workshop bake"},"scene":0,"scenes":[{"nodes":[]}],"nodes":[],"meshes":[],"materials":[],"buffers":[],"bufferViews":[],"accessors":[],"textures":[],"images":[]}
blob=bytearray()
def view(data):
    start=len(blob)
    blob.extend(data)
    doc["bufferViews"].append({"buffer":0,"byteOffset":start,"byteLength":len(data)})
    blob.extend(b"\0"*((-len(blob))%4))
    return len(doc["bufferViews"])-1
def acc(arr,kind,typ,bounds=False):
    ent={"bufferView":view(arr.tobytes()),"componentType":typ,"count":len(arr),"type":kind}
    if bounds: ent.update(min=arr.min(axis=0).tolist(),max=arr.max(axis=0).tolist())
    doc["accessors"].append(ent)
    return len(doc["accessors"])-1

for kind,file in [("rock","rock_boulder_dry_diff_2k.jpg"),("oak","wood_table_001_diff_2k.jpg"),("plain",None),("ember",None),("cloth","coverlet.jpg"),("brew",None),("sheen",None)]:
    pbr={"metallicFactor":.1,"roughnessFactor":.84}
    mat={"name":kind,"doubleSided":True,"pbrMetallicRoughness":pbr}
    if file:
        path=OUT/("coverlet.jpg" if kind=="cloth" else kind+".jpg")
        doc["images"].append({"mimeType":"image/jpeg","bufferView":view(path.read_bytes())})
        doc["textures"].append({"source":len(doc["images"])-1})
        pbr["baseColorTexture"]={"index":len(doc["textures"])-1}
    if kind=="ember": mat["emissiveFactor"]=[.55,.17,.035]
    doc["materials"].append(mat)

for group,surfaces in parts.items():
    allpos=np.concatenate([arr[:,:3] for surf in surfaces.values() for arr in surf])
    centre=((allpos.max(axis=0)+allpos.min(axis=0))/2).astype("<f4")
    prim=[]
    for kind,arrays in surfaces.items():
        data=np.concatenate(arrays)
        data[:,:3]-=centre
        verts,idx=np.unique(data.round(5),axis=0,return_inverse=True)
        attrs={key:acc(np.ascontiguousarray(verts[:,a:b]),typ,5126,key=="POSITION") for key,a,b,typ in [("POSITION",0,3,"VEC3"),("NORMAL",3,6,"VEC3"),("TEXCOORD_0",6,8,"VEC2"),("COLOR_0",8,11,"VEC3")]}
        prim.append({"attributes":attrs,"indices":acc(idx.astype("<u4").ravel(),"SCALAR",5125),"material":["rock","oak","plain","ember","cloth","brew","sheen"].index(kind)})
    doc["scenes"][0]["nodes"].append(len(doc["nodes"]))
    doc["nodes"].append({"name":group,"mesh":len(doc["meshes"]),"translation":centre.tolist()})
    doc["meshes"].append({"name":group,"primitives":prim})
doc["buffers"]=[{"byteLength":len(blob)}]
js=json.dumps(doc,separators=(",",":")).encode()
js+=b" "*((-len(js))%4)
dest=OUT/"workshop.glb"
with dest.open("wb") as f:
    f.write(struct.pack("<4sII",b"glTF",2,28+len(js)+len(blob)))
    f.write(struct.pack("<I4s",len(js),b"JSON")+js)
    f.write(struct.pack("<I4s",len(blob),b"BIN\0")+blob)
every=np.concatenate(lights) if lights else np.zeros(1)
print("WORKSHOP LIGHT raw irradiance percentiles 10/50/90/99",[round(float(np.percentile(every,q)),3) for q in (10,50,90,99)],"exposure",EXPOSURE,"white",WHITE,"ambient",AMBIENT)
print("WORKSHOP EXPORT",dest,len(blob),list(parts))
