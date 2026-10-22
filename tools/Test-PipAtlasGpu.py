"""Pixel oracle for the generated GLES atlas shader on a desktop OpenGL context.

Requires moderngl 5.12, numpy and Pillow. Optional --modules points to disposable
dependencies in tmp/. OES uses a padded 2D stand-in; actual EGL import is a device check.
"""
import argparse
import json
import math
from pathlib import Path
import re
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--header", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--modules", type=Path)
    args = parser.parse_args()
    if args.modules:
        sys.path.insert(0, str(args.modules.resolve()))
    import moderngl
    import numpy as np
    from PIL import Image

    context = moderngl.create_standalone_context(require=330)
    vertex = "#version 300 es\nvoid main(){vec2 p=vec2(float((gl_VertexID<<1)&2),float(gl_VertexID&2));gl_Position=vec4(p*2.0-1.0,0.0,1.0);}"
    shaders = re.findall(r'const char\* (\w+) = R"PIP\((.*?)\)PIP";', args.header.read_text(), re.S)
    assert len(shaders) == 2, "Both production variants must be extracted"
    checks, failures = 0, []
    maximum = 0.0
    map_max_pixels = 0.0
    width, height, tile = 512, 256, 64
    target = context.simple_framebuffer(((tile + 4) * 2, (tile + 4) * 3), components=4)
    raw_target = target
    srgb_texture = context.texture(target.size, 4, internal_format=0x8C43) # GL_SRGB8_ALPHA8
    srgb_target = context.framebuffer([srgb_texture])
    yy, xx = np.mgrid[:height, :width]
    rgb = np.stack([xx / (width - 1), yy / (height - 1), np.where(xx < width // 2, .12, .86), np.ones_like(xx)], axis=2)
    rgb = np.round(rgb * 255).astype("u1")
    left = np.tile(np.linspace(.15,.35,32)[:,None],(1,32))
    right = np.tile(np.linspace(.65,.85,32)[:,None],(1,32))
    mask_data = np.round(np.concatenate((left,right),axis=1)*255).astype("u1")
    matte = context.texture((64, 32), 1, mask_data.tobytes())
    matte.filter = (moderngl.LINEAR, moderngl.LINEAR)
    matte.repeat_x = matte.repeat_y = False
    matte.use(1)
    defaults = dict(video_geometry=0, stereo_sbs=True, top_bottom=False, stereo_half=False, swap_eyes=False,
                    viewing_eye=0, pip_viewing_eye=0, rotation_degrees=0, fisheye_fov=190., source_size=(width, height),
                    color_uv_scale=(1., 1.), stereo_offset=(0., 0.), alpha_enabled=False, depth_enabled=False,
                    depth_shift=.035, depth_convergence=.35, alpha_edge=(0., 1.), model_size=(32., 32.),
                    model_content_rect=(0., 0., 1., 1.), packed_alpha=False, packed_size=(768., 432.),
                    packed_color=False, grade_enabled=False, grade_gain=(1., 1., 1.), grade_gamma=(1., 1., 1.),
                    grade_offset=(0., 0., 0.), grade_contrast=1., grade_saturation=1., sharpness=0., pip_enabled=True,
                    pip_center=(.5, .5), pip_span=(1/3, 1/3), pip_forward=(0., 0., -1.), pip_right=(1., 0., 0.),
                    pip_up=(0., 1., 0.), pip_tangent=(math.tan(math.pi/6), math.tan(math.pi/6)*9/16),
                    atlas_origin=(0., 0.), atlas_size=(float(tile), float(tile)), atlas_eye=0, atlas_raw=True,
                    atlas_main=False, atlas_span=(math.pi, math.pi))

    def sample(data, uv):
        h, w = data.shape[:2]
        p = np.clip(np.array(uv) * (w, h) - .5, 0, (w - 1, h - 1))
        x, y = np.floor(p).astype(int)
        fx, fy = p - (x, y)
        return ((data[y, x] * (1-fx) + data[y, min(x+1,w-1)] * fx) * (1-fy) +
                (data[min(y+1,h-1), x] * (1-fx) + data[min(y+1,h-1), min(x+1,w-1)] * fx) * fy) / 255.

    def eye_uv(v, uv):
        geometry = v["video_geometry"]
        if geometry == 0:
            if v["atlas_main"]:
                return np.array(uv), False
            return np.array(v["pip_center"]) + (uv - .5) * v["pip_span"], False
        if v["atlas_main"]:
            lon, lat = (uv[0] - .5) * v["atlas_span"][0], (.5 - uv[1]) * v["atlas_span"][1]
            d = np.array((math.cos(lat) * math.sin(lon), math.sin(lat), -math.cos(lat) * math.cos(lon)))
        else:
            p = (uv - .5) * 2 * v["pip_tangent"]
            d = np.array(v["pip_forward"]) + np.array(v["pip_right"]) * p[0] - np.array(v["pip_up"]) * p[1]
        d /= np.linalg.norm(d)
        angle = math.acos(np.clip(-d[2], -1, 1))
        outside = (geometry == 1 and d[2] > 0) or (geometry == 2 and angle > math.radians(v["fisheye_fov"] / 2))
        if geometry in (1, 3):
            return np.array((.5 + math.atan2(d[0], -d[2]) / (math.pi * (2 if geometry == 3 else 1)),
                             .5 - math.asin(np.clip(d[1], -1, 1))/math.pi)), outside
        axis = np.array((d[0], -d[1]))
        if np.linalg.norm(axis) > 1e-6:
            axis /= np.linalg.norm(axis)
        size = np.array(v["source_size"]) / (np.array((1, 2)) if v["top_bottom"] and v["stereo_sbs"] else (2, 1) if v["stereo_sbs"] else (1, 1))
        stretch = 1 if v["stereo_sbs"] and v["stereo_half"] else min(size) / size
        return .5 + .5 * angle / math.radians(v["fisheye_fov"]/2) * axis * stretch, outside

    def oracle(v, data, uv):
        p, outside = eye_uv(v, uv)
        if v["stereo_sbs"] and not v["viewing_eye"] and not v["pip_viewing_eye"]:
            p += np.array(v["stereo_offset"]) * (-.5 if v["atlas_eye"] == 0 else .5)
            if v["video_geometry"] == 3 and v["stereo_offset"][0]:
                p[0] %= 1
        clipped = bool(np.any(p < 0) or np.any(p > 1))
        if v["rotation_degrees"] == 90: p = np.array((p[1], 1-p[0]))
        elif v["rotation_degrees"] == 180: p = 1-p
        elif v["rotation_degrees"] == 270: p = np.array((1-p[1], p[0]))
        selected = v["pip_viewing_eye"] or v["viewing_eye"]
        eye = (selected-1 if selected else v["atlas_eye"]) if v["stereo_sbs"] else 0
        if v["stereo_sbs"] and v["swap_eyes"]: eye = 1-eye
        size = np.array(v["source_size"]) / (np.array((1, 2)) if v["top_bottom"] and v["stereo_sbs"] else (2, 1) if v["stereo_sbs"] else (1, 1))
        c = np.clip(p, .5 / size, 1 - .5 / size)
        if v["stereo_sbs"]:
            axis = 1 if v["top_bottom"] else 0
            c[axis] = (c[axis] + eye) * .5
        color = sample(data, c * v["color_uv_scale"])[:3]
        alpha = 1.
        if v["alpha_enabled"]:
            model = np.array(v["model_size"])
            rect = np.array(v["model_content_rect"])
            a = rect[:2] + p * rect[2:]
            first = np.maximum((np.ceil(rect[:2]*model-.5)+.5)/model, .5/model)
            last = np.minimum((np.floor((rect[:2]+rect[2:])*model-.5)+.5)/model, 1-.5/model)
            a = np.clip(a, first, last)
            a[0] = (a[0]+eye)*.5
            alpha = float(np.clip((sample(mask_data,a)-v["alpha_edge"][0])/(v["alpha_edge"][1]-v["alpha_edge"][0]),0,1))
            if np.any(rect[:2]+p*rect[2:] < 0) or np.any(rect[:2]+p*rect[2:] > 1): alpha = 0.
        if outside or (clipped and v["stereo_sbs"] and not v["viewing_eye"] and not v["pip_viewing_eye"] and any(v["stereo_offset"])):
            color = np.zeros(3)
            alpha = 0. if v["alpha_enabled"] or v["packed_alpha"] else 1.
        elif v["grade_enabled"]:
            color=(color*np.array(v["grade_gain"])-.5)*v["grade_contrast"]+.5+np.array(v["grade_offset"])
            color=np.maximum(color,0)**np.array(v["grade_gamma"])
            luma=np.dot(color,(.2126,.7152,.0722))
            color=np.clip(luma+(color-luma)*v["grade_saturation"],0,1)
        linear = np.where(color <= .04045, color/12.92, ((color+.055)/1.055)**2.4) * alpha
        encoded = np.where(linear <= .0031308, linear*12.92, 1.055*np.maximum(linear,0)**(1/2.4)-.055)
        return np.append(encoded, alpha)

    # Exercise both explicit encoding and the actual sRGB framebuffer conversion,
    # including alpha premultiplication. Desktop OES remains a padded 2D stand-in.
    for name, source, hardware in [(n + ("_hardware_srgb" if h else ""), s, h) for n, s in shaders for h in (False, True)]:
        target = srgb_target if hardware else raw_target
        if hardware: context.enable_direct(0x8DB9) # GL_FRAMEBUFFER_SRGB
        else: context.disable_direct(0x8DB9)
        defaults["atlas_raw"] = not hardware
        external = "oes" in name
        source = source.replace("#extension GL_OES_EGL_image_external_essl3 : require", "").replace("samplerExternalOES", "sampler2D")
        program = context.program(vertex_shader=vertex, fragment_shader=source)
        vao = context.vertex_array(program, [])
        source_data = np.pad(rgb, ((0,64),(0,128),(0,0)), constant_values=255) if external else rgb
        color = context.texture((source_data.shape[1], source_data.shape[0]),4,source_data.tobytes())
        color.filter = (moderngl.LINEAR, moderngl.LINEAR); color.repeat_x = color.repeat_y = False
        color.use(0)
        program["color_texture"] = 0
        program["alpha_texture"] = 1
        program["atlas_projection"] = 2
        projection = context.texture((1025,1025),2,dtype="f4")
        projection.filter=(moderngl.LINEAR,moderngl.LINEAR)
        projection.repeat_x=projection.repeat_y=False
        projection_target=context.framebuffer([projection])
        for key, value in defaults.items():
            if key in program: program[key].value = value
        variants = []
        for geometry in (0,1,2,3):
            for layout in (0,1,2):
                for eye in (0,1):
                    for rotation in (0,90,180,270):
                        variants.append(dict(video_geometry=geometry, stereo_sbs=layout!=0, top_bottom=layout==2,
                                             stereo_half=layout==2, atlas_eye=eye, rotation_degrees=rotation,
                                             swap_eyes=bool(rotation%180), alpha_enabled=geometry%2==1))
                        if layout == 1:
                            variants.append(variants[-1] | dict(stereo_half=True))
        variants += [dict(video_geometry=3,pip_forward=(0.,0.,1.),stereo_offset=(.06,.02)),
                     dict(video_geometry=1,pip_forward=(0.,0.,1.)), dict(video_geometry=2,pip_forward=(0.,0.,1.)),
                     dict(video_geometry=0,pip_center=(.99,.01),stereo_offset=(.1,.1)),
                     dict(video_geometry=0,viewing_eye=2,swap_eyes=True)]
        variants += [dict(video_geometry=0,alpha_enabled=True,alpha_edge=(.4,.9)),
                     dict(video_geometry=0,alpha_enabled=True,alpha_edge=(.25,.75),sharpness=.5)]
        variants += [dict(video_geometry=g,top_bottom=tb,atlas_eye=e,pip_viewing_eye=selected,
            stereo_offset=(.08,.03),swap_eyes=swap,alpha_enabled=True)
            for g in (0,1,2,3) for tb in (False,True) for e in (0,1) for selected in (1,2) for swap in (False,True)]
        for changed in variants:
            v = defaults | changed
            v["color_uv_scale"] = (.8,.8) if external else (1.,1.)
            for key, value in v.items():
                if key in program: program[key].value = value
            target.use(); context.viewport = (0,0,tile+4,tile+4)
            vao.render(vertices=3)
            pixels = np.frombuffer(target.read(components=4,alignment=1),dtype="u1").reshape(target.height,target.width,4)/255.
            for x,y in ((2,2),(tile+1,2),(2,tile+1),(tile//2+2,tile//2+2)):
                uv = np.clip((np.array((x,y))+.5-2)/tile,.5/tile,1-.5/tile)
                expected = oracle(v,source_data,uv)
                error = float(np.max(np.abs(expected-pixels[y,x])))
                checks += 1; maximum = max(maximum,error)
                if error > .012: failures.append(dict(variant=name,settings=changed,pixel=(x,y),error=error,actual=pixels[y,x].tolist(),expected=expected.tolist()))
            checks += 1
            if np.max(np.abs(pixels[0,0]-pixels[2,2])) > .012:
                failures.append(dict(variant=name,settings=changed,error="gutter differs from edge"))
        # Whole processed main uses the same production projection and alpha maths,
        # with no PiP crop or gutters. Eye selection/alignment are baked here once.
        for geometry in (0, 1, 2, 3):
            for layout in (0, 1, 2):
                for eye in (0, 1):
                    for rotation in (0, 90, 180, 270):
                        lens=(180.,190.,220.,240.)[rotation//90]
                        span = 2*math.pi if geometry == 3 else math.radians(lens) if geometry == 2 else math.pi
                        v = defaults | dict(video_geometry=geometry, stereo_sbs=layout!=0, top_bottom=layout==2,
                            atlas_main=True, pip_enabled=False, atlas_eye=eye, rotation_degrees=rotation,
                            swap_eyes=True, stereo_offset=(.06, .02), alpha_enabled=True,
                            viewing_eye=2 if rotation==270 else 0, grade_enabled=rotation==90,
                            grade_gain=(1.1,.9,1.02), grade_gamma=(.85,1.15,.95), grade_offset=(-.01,.02,0.),
                            grade_contrast=1.05, grade_saturation=.8,
                            fisheye_fov=lens, atlas_span=(span, math.pi),
                            color_uv_scale=(.8,.8) if external else (1.,1.))
                        for key, value in v.items():
                            if key in program: program[key].value=value
                        program["atlas_cached"]=False
                        if geometry==2:
                            program["atlas_make_map"]=True
                            program["atlas_projection"]=3 # avoid sampling the render attachment
                            projection_target.use();context.viewport=(0,0,1025,1025);vao.render(vertices=3)
                            program["atlas_make_map"]=False
                            program["atlas_projection"]=2;projection.use(2)
                            program["atlas_cached"]=True
                            lookup=np.frombuffer(projection.read(),dtype="f4").reshape(1025,1025,2)
                            for u,w in ((.0001,.5),(.9999,.5),(.5,.0001),(.5,.9999),(.50013,.50031),(.8312,.7377),(.00001,.00001)):
                                node=np.array((u,w))*1024;nx,ny=np.floor(node).astype(int);fx,fy=node-(nx,ny)
                                mapped=(lookup[ny,nx]*(1-fx)+lookup[ny,nx+1]*fx)*(1-fy)+(lookup[ny+1,nx]*(1-fx)+lookup[ny+1,nx+1]*fx)*fy
                                eye_size=np.array(v["source_size"])/(np.array((1,2)) if v["top_bottom"] and v["stereo_sbs"] else (2,1) if v["stereo_sbs"] else (1,1))
                                error=float(np.max(np.abs(mapped-eye_uv(v,np.array((u,w)))[0])*eye_size*(8192/max(v["source_size"]))))
                                map_max_pixels=max(map_max_pixels,error);checks+=1
                                if error>.25:failures.append(dict(variant=name,projection_map=True,pixel_error_at_8k=error))
                        target.use(); context.viewport=(0,0,tile,tile); vao.render(vertices=3)
                        pixels=np.frombuffer(target.read(components=4,alignment=1),dtype="u1").reshape(target.height,target.width,4)/255.
                        for x,y in ((0,0), (tile-1,0), (tile//2,tile//2), (tile//3,tile*2//3)):
                            expected=oracle(v,source_data,(np.array((x,y))+.5)/tile)
                            error=float(np.max(np.abs(expected-pixels[y,x])))
                            checks+=1; maximum=max(maximum,error)
                            if error>.012: failures.append(dict(variant=name,whole_main=True,geometry=geometry,layout=layout,eye=eye,rotation=rotation,pixel=(x,y),error=error))
        program["atlas_cached"]=False
        projection_target.release();projection.release();color.release()
        packed = np.array(Image.open(Path(__file__).resolve().parents[1]/"app/godot/media/c04_alpha_f180_rgb.png").convert("RGBA"))
        reference = np.array(Image.open(Path(__file__).resolve().parents[1]/"app/godot/media/c04_packed_mask_oracle.png").convert("L"))
        ph,pw = packed.shape[:2]
        packed_data = np.pad(packed,((0,ph//4),(0,pw//4),(0,0)),constant_values=255) if external else packed
        color = context.texture((packed_data.shape[1],packed_data.shape[0]),4,packed_data.tobytes())
        color.filter=(moderngl.LINEAR,moderngl.LINEAR); color.repeat_x=color.repeat_y=False; color.use(0)
        for eye in (0,1):
            for x in (.1,.3,.5,.7,.9):
                for y in (.25,.5,.75):
                    v=defaults | dict(source_size=(pw,ph),packed_alpha=True,packed_size=(512.,256.),atlas_eye=eye,
                                      pip_center=(x,y),pip_span=(.001,.001),color_uv_scale=(.8,.8) if external else (1.,1.))
                    for key,value in v.items():
                        if key in program: program[key].value=value
                    target.use(); context.viewport=(0,0,tile+4,tile+4); vao.render(vertices=3)
                    actual=target.read(viewport=(tile//2+2,tile//2+2,1,1),components=4,alignment=1)[3]/255.
                    center=np.array((x,y))+(.5/tile)*.001
                    expected=float(sample(reference,((center[0]+eye)*.5,center[1])))
                    checks+=1; error=abs(actual-expected); maximum=max(maximum,error)
                    if error>.012: failures.append(dict(variant=name,packed=True,eye=eye,x=x,y=y,actual=actual,expected=expected))
        for geometry in (0,2):
            for eye in (0,1):
                v=defaults | dict(video_geometry=geometry,source_size=(pw,ph),packed_alpha=True,
                    packed_size=(512.,256.),atlas_eye=eye,atlas_main=True,pip_enabled=False,
                    atlas_span=(math.pi,math.pi),fisheye_fov=180.,color_uv_scale=(.8,.8) if external else (1.,1.))
                for key,value in v.items():
                    if key in program: program[key].value=value
                target.use(); context.viewport=(0,0,tile,tile); vao.render(vertices=3)
                pixels=np.frombuffer(target.read(components=4,alignment=1),dtype="u1").reshape(target.height,target.width,4)/255.
                for x,y in ((tile//2,tile//2),(tile//3,tile//2),(tile*2//3,tile//2)):
                    p,_=eye_uv(v,(np.array((x,y))+.5)/tile)
                    expected=float(sample(reference,((p[0]+eye)*.5,p[1])))
                    actual=float(pixels[y,x,3]); error=abs(actual-expected)
                    checks+=1; maximum=max(maximum,error)
                    if error>.012: failures.append(dict(variant=name,whole_packed=True,geometry=geometry,eye=eye,pixel=(x,y),actual=actual,expected=expected))
        color.release(); vao.release(); program.release()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(dict(checks=checks,failures=failures,max_error=maximum,projection_map_max_pixels_at_8k=map_max_pixels,renderer=context.info["GL_RENDERER"],
        scope="Generated GLES math compiled and sampled on desktop; external OES is a padded 2D stand-in"),indent=2))
    print(f"PiP native atlas GPU: {checks} checks, {len(failures)} failures; max error {maximum:.6f}")
    if failures:
        print(json.dumps(failures[:3],indent=2))
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
