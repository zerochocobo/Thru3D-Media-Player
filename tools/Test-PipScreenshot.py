"""Pixel oracle for production still composition; all fixtures and reports are reproducible in build/."""
import argparse
import binascii
import json
import io
import math
from pathlib import Path
import subprocess
import struct
import sys
import time
import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build/output/pip-screenshot/pixels"


def linux(path):
    path = str(Path(path).resolve()).replace("\\", "/")
    return "/mnt/" + path[0].lower() + path[2:] if len(path) > 1 and path[1] == ":" else path


def rotation(yaw=0, pitch=0):
    cy, sy, cp, sp = math.cos(yaw), math.sin(yaw), math.cos(pitch), math.sin(pitch)
    return np.array(((cy, 0, sy), (0, 1, 0), (-sy, 0, cy))) @ np.array(((1, 0, 0), (0, cp, -sp), (0, sp, cp)))


def window(center=(0, 0, -1.5), pose=None, crop=None, image=-1, orientation=1, eye=0, size=(.7, .42)):
    pose = np.eye(3) if pose is None else pose
    crop = rotation(.55, .15) if crop is None else crop
    inverse = pose.T
    return dict(axes=(inverse * 50).T.flatten().tolist(), anchor=(inverse @ -np.array(center)).tolist(),
                left=(inverse @ (np.array((-.0315, 0, 0))-center)).tolist(),
                right=(inverse @ (np.array((.0315, 0, 0))-center)).tolist(), size=list(size), feather=[.025, .04],
                crop=np.concatenate((-crop[:, 2], crop[:, 0], crop[:, 1])).tolist(), tangent=[.3, .18],
                source_eye=eye, image=image, orientation=orientation)


def flatten(w):
    return sum((w[k] for k in ("axes", "anchor", "left", "right", "size", "feather", "crop", "tangent")), []) + [w["source_eye"], w["image"], w["orientation"]]


def bilinear(data, u, v):
    h, w = data.shape[:2]
    x, y = np.clip(u * w - .5, 0, w-1), np.clip(v * h - .5, 0, h-1)
    ix, iy = np.floor(x).astype(int), np.floor(y).astype(int)
    fx, fy = (x-ix)[..., None], (y-iy)[..., None]
    return ((data[iy, ix]*(1-fx) + data[iy, np.minimum(ix+1, w-1)]*fx)*(1-fy) +
            (data[np.minimum(iy+1, h-1), ix]*(1-fx) + data[np.minimum(iy+1, h-1), np.minimum(ix+1, w-1)]*fx)*fy) / 255.


def linear(c):
    return np.where(c <= .04045, c / 12.92, ((c+.055)/1.055)**2.4)


def oracle(data, image, flags, windows):
    geometry, stereo, tb, half, swap, fov = flags
    h, w = data.shape[:2]; ew, eh = w//(2 if stereo and not tb else 1), h//(2 if stereo and tb else 1)
    yy, xx = np.mgrid[:h, :w]; u, v = (xx % ew + .5)/ew, (yy % eh + .5)/eh
    eye = (yy//eh if tb else xx//ew) if stereo else np.zeros((h, w), int)
    if stereo and swap: eye = 1-eye
    if geometry == 2:
        stretch = np.ones(2) if stereo and half else min(ew, eh)/np.array((ew, eh))
        axis = (np.stack((u, v), axis=-1)-.5)*2/stretch
        radius = np.linalg.norm(axis, axis=-1); angle = radius*math.radians(fov/2)
        s = np.sin(angle)/np.maximum(radius, 1e-12)
        direction = np.stack((axis[..., 0]*s, -axis[..., 1]*s, -np.cos(angle)), axis=-1)
        valid = radius <= 1
    else:
        lon, lat = (u-.5)*math.pi*(2 if geometry == 3 else 1), (.5-v)*math.pi
        direction = np.stack((np.sin(lon)*np.cos(lat), np.sin(lat), -np.cos(lon)*np.cos(lat)), axis=-1)
        valid = np.ones((h, w), bool)
    output = data.copy()
    for window in windows:
        # Reconstruct the world-to-window transform independently with column vectors.
        matrix = np.array(window["axes"]).reshape(3, 3).T
        origins = np.where((eye == 0)[..., None], window["left"], window["right"])
        rays = direction @ matrix.T + window["anchor"] - origins
        t = -origins[..., 2]/np.where(abs(rays[..., 2]) < 1e-12, 1e-12, rays[..., 2])
        point = origins + rays*t[..., None]
        q = np.stack((point[..., 0]/window["size"][0]+.5, .5-point[..., 1]/window["size"][1]), axis=-1)
        inside = valid & (t > 0) & (abs(rays[..., 2]) >= 1e-12) & (q > 0).all(axis=-1) & (q < 1).all(axis=-1)
        edge = np.clip(np.minimum(q, 1-q)/window["feather"], 0, 1)
        alpha = np.prod(edge*edge*(3-2*edge), axis=-1)
        sample_uv = q.copy()
        if window["image"] >= 0:
            a, b = q[..., 0].copy(), q[..., 1].copy()
            orientation = window["orientation"]
            pairs = {1:(a,b), 2:(1-a,b), 3:(1-a,1-b), 4:(a,1-b), 5:(b,a), 6:(b,1-a), 7:(1-b,1-a), 8:(1-b,a)}
            color = bilinear(image, *pairs[orientation])
            rgb = linear(color[..., :3])*color[..., 3:] + .025*(1-color[..., 3:])
        else:
            forward, right, up = np.array(window["crop"]).reshape(3, 3)
            crop = forward + right*(q[..., :1]-.5)*2*window["tangent"][0] - up*(q[..., 1:]-.5)*2*window["tangent"][1]
            crop /= np.linalg.norm(crop, axis=-1)[..., None]
            outside = crop[..., 2] > 0 if geometry == 1 else np.zeros((h, w), bool)
            if geometry == 2:
                angle = np.arccos(np.clip(-crop[..., 2], -1, 1)); outside = angle > math.radians(fov/2)
                stretch = np.ones(2) if stereo and half else min(ew, eh)/np.array((ew, eh))
                transverse = np.maximum(np.linalg.norm(crop[..., :2], axis=-1), 1e-12)
                sample_uv = .5 + .5 * angle[..., None]/math.radians(fov/2)*crop[..., :2]*np.array((1,-1))/transverse[..., None]*stretch
            else:
                sample_uv = np.stack((.5+np.arctan2(crop[..., 0], -crop[..., 2])/(math.pi*(2 if geometry == 3 else 1)),
                                      .5-np.arcsin(np.clip(crop[..., 1], -1, 1))/math.pi), axis=-1)
            selected = window["source_eye"] if stereo else 0
            source = data[selected*eh:(selected+1)*eh] if stereo and tb else data[:, selected*ew:(selected+1)*ew] if stereo else data
            color = bilinear(source, sample_uv[..., 0], sample_uv[..., 1]); color[outside] = (0,0,0,1)
            rgb = linear(color[..., :3])
        mixed = rgb*alpha[..., None]+linear(output[..., :3]/255.)*(1-alpha[..., None])
        encoded = np.where(mixed <= .0031308, mixed*12.92, 1.055*np.maximum(mixed, 0)**(1/2.4)-.055)
        output[inside, :3] = np.clip(np.floor(encoded[inside]*255+.5), 0, 255).astype('u1')
        output[inside, 3] = 255
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", type=Path, required=True)
    parser.add_argument("--benchmark", action="store_true")
    parser.add_argument("--jpeg", action="store_true", help="Also compare streaming JPEG100 against independent encoding of the lossless oracle")
    args = parser.parse_args(); OUT.mkdir(parents=True, exist_ok=True)
    yy, xx = np.mgrid[:240, :480]
    source = np.stack(((xx*3+yy)%256, (yy*2)%256, np.where(xx < 240, 32, 224), np.full_like(xx, 255)), axis=-1).astype('u1')
    yy, xx = np.mgrid[:24, :32]
    image = np.stack((xx*8, yy*10, (xx+yy)*4, np.where(xx < 16, 128, 255)), axis=-1).astype('u1')
    source.tofile(OUT/"source.rgba"); image.tofile(OUT/"image.rgba")
    cases = []
    for geometry in (1,2,3):
        for stereo,tb,half in ((0,0,0),(1,0,0),(1,1,0),(1,0,1),(1,1,1)):
            for swap in (0,1):
                for fov in ((180,190,200,220) if geometry == 2 else (180,)):
                    flags = (geometry,stereo,tb,half,swap,fov)
                    cases.append((f"projection-{'-'.join(map(str,flags))}", flags, [window(eye=swap if stereo else 0)]))
    for orientation in range(1,9):
        cases.append((f"image-{orientation}", (3,1,0,0,0,180), [window(), window(center=(.12,.05,-1.4),image=0,orientation=orientation)]))
    cases += [("seam", (3,1,0,0,0,180), [window(center=(0,0,1.5),pose=rotation(math.pi))]),
              ("pole", (3,1,1,0,1,180), [window(center=(0,1.5,0),pose=rotation(pitch=math.pi/2),eye=1)]),
              ("three-windows", (1,1,0,0,0,180), [window(),window(center=(-.3,.1,-1.4)),window(center=(.25,.08,-1.3),image=0)]),
              ("no-windows", (3,1,0,0,0,180), [])]
    rng=np.random.default_rng(4321)
    for index in range(12):
        pose=rotation(rng.uniform(-1.1,1.1),rng.uniform(-.7,.7))
        item=window(center=-pose[:,2]*rng.uniform(.6,4),pose=pose,eye=index%2,
                    size=(rng.uniform(.22,1.2),rng.uniform(.22,.8)))
        # A moved/rotated main sphere, like immersive viewing drag and zoom.
        main=rotation(.2,-.1);inverse=pose.T
        item['axes']=(inverse@main*50).T.flatten().tolist()
        item['anchor']=(np.array(item['anchor'])+inverse@np.array((.1,.05,-1))).tolist()
        cases.append((f"spatial-{index}",(3,1,index%2,0,index%2,180),[item]))
    jobs = []
    def add(name, flags, windows, source_file=OUT/"source.rgba", width=480, height=240):
        recipe = OUT/(name+".txt")
        recipe.write_text(" ".join(map(str, (*flags,len(windows))))+"\n"+"\n".join(" ".join(map(str,flatten(w))) for w in windows))
        jobs.append([linux(args.host), linux(source_file), str(width), str(height), linux(OUT/(name+".png")),linux(recipe),linux(OUT/"image.rgba"),"32","24"])
    for name, flags, windows in cases: add(name,flags,windows)
    if args.benchmark:
        for width,height in ((4096,2048),(7680,3840)):
            # High-frequency, reproducible input; no hardware decoder or GPU in this benchmark.
            yy,xx=np.mgrid[:height,:width]
            big=np.stack((xx%256, yy%256, (xx+yy)%256, np.full_like(xx,255)),axis=-1).astype('u1')
            path=OUT/f"benchmark-{width}.rgba";big.tofile(path);del big,yy,xx
            add(f"benchmark-{width}",(3,1,0,0,0,180),[window(),window(center=(-.4,.1,-1.4)),window(center=(.4,.1,-1.4),image=0)],path,width,height)
    png_jobs=list(jobs)
    if args.jpeg:
        for job in png_jobs:
            jpeg=job.copy(); jpeg[4]=job[4][:-4]+'.jpg'; jobs.append(jpeg)
    plan=OUT/"jobs.json";plan.write_text(json.dumps(jobs))
    worker = "import json,subprocess,sys,time; jobs=json.load(open(sys.argv[1])); times=[]\nfor job in jobs:\n t=time.monotonic(); result=subprocess.run(job,check=True,capture_output=True,text=True); item=json.loads(result.stdout); item['process_seconds']=time.monotonic()-t; times.append(item)\nprint(json.dumps(times))"
    command = ["wsl","--exec","python3","-c",worker,linux(plan)] if sys.platform == "win32" else [sys.executable,"-c",worker,str(plan)]
    elapsed=json.loads(subprocess.run(command,check=True,capture_output=True,text=True).stdout)
    maximum=0; changed=0; jpeg_mae=0.; jpeg_p99=0.
    for name,flags,windows in cases:
        actual=np.array(Image.open(OUT/(name+".png")))
        raw=(OUT/(name+".png")).read_bytes(); offset=8
        while offset<len(raw):
            length=struct.unpack_from('>I',raw,offset)[0]
            chunk=raw[offset+4:offset+8+length]
            assert binascii.crc32(chunk)==struct.unpack_from('>I',raw,offset+8+length)[0],(name,'PNG CRC')
            offset+=length+12
        expected=oracle(source,image,flags,windows)
        error=int(np.max(np.abs(actual.astype(int)-expected.astype(int))));maximum=max(maximum,error)
        assert error<=1,(name,error)
        delta=np.any(actual!=source,axis=-1)
        if windows: assert delta.any(),name
        else: assert np.array_equal(actual,source),"Empty composition modified source pixels"
        changed+=int(delta.sum())
        if args.jpeg:
            jpeg=Image.open(OUT/(name+".jpg"))
            assert jpeg.format=="JPEG" and jpeg.size==(480,240),name
            assert all(value==1 for table in jpeg.quantization.values() for value in table),(name,"JPEG100 quantization")
            reference=io.BytesIO();Image.fromarray(actual).convert("RGB").save(reference,format="JPEG",quality=100,subsampling=2)
            expected_jpeg=np.array(Image.open(io.BytesIO(reference.getvalue())))
            delta=np.abs(np.array(jpeg).astype(int)-expected_jpeg.astype(int))
            # Pinned libjpeg 3.1 enables fancy chroma downsampling; Pillow can use older
            # box downsampling. Compare whole-image error, allowing their colored edges
            # to differ, rather than claiming lossy JPEG pixels are identical.
            mean_error=float(np.mean(delta)); percentile=float(np.quantile(delta,.99))
            assert mean_error<2 and percentile<=20,(name,"independent JPEG",mean_error,percentile)
            jpeg_mae=max(jpeg_mae,mean_error);jpeg_p99=max(jpeg_p99,percentile)
    report=dict(state="passed",cases=len(cases),compared_pixels=len(cases)*480*240,changed_pixels=changed,max_channel_error=maximum,
                jpeg_cases=len(cases) if args.jpeg else 0,
                jpeg_max_mean_reference_error=round(jpeg_mae,4),jpeg_max_p99_reference_error=jpeg_p99,
                host_seconds={Path(job[4]).name:{key:round(value,4) for key,value in t.items()} for job,t in zip(jobs,elapsed)},headset_performance_tested=False)
    (OUT/"verification.json").write_text(json.dumps(report,indent=2))
    print(json.dumps({k:v for k,v in report.items() if k!="host_seconds"}))
    if args.benchmark: print(json.dumps({k:v for k,v in report["host_seconds"].items() if k.startswith("benchmark")}))


if __name__ == "__main__": main()
