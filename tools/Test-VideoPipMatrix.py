"""Authorized headset checks against an already installed, complete Debug APK.

Uses normal VR playback and production controls. Does not build/install, erase app
data, or change model/refresh policies permanently. Pixel probes are outside perf
windows. Reports and reproducible fixtures belong in build/output/.
"""
import argparse
import json
from pathlib import Path
import runpy
import re
import subprocess
import time
import uuid

Device = runpy.run_path(str(Path(__file__).with_name("Test-VideoPipDevice.py")))["Device"]
GEOMETRY = ("flat", "half_equirect_180", "fisheye_180", "equirect_360")


class Suite:
    def __init__(self, device, fixtures, mono_pip=False):
        self.d, self.fixtures = device, fixtures
        self.mono_pip = mono_pip
        self.index = 0
        self.run_id = uuid.uuid4().hex[:10]
        self.results = []

    def label(self, name):
        self.index += 1
        return f"{self.index:03d}-{name}"

    def observe(self, name, predicate=lambda r: True, seconds=45):
        return self.d.wait(self.d.send("observe"), self.label(name), predicate, seconds)

    def close(self):
        self.d.wait(self.d.send("close"), self.label("closed"), lambda r:r["media"]["state"]=="closed")
        time.sleep(.75)

    def open(self, name, projection=0, stereo=True, alpha=False, depth=False):
        self.close()
        local=self.fixtures/name
        if not local.exists():local=Path("build/output/fixtures")/name
        if local.exists():
            uri=self.d.upload(local)
        else:
            uri="file:///data/user/0/"+self.d.package+"/files/fixtures/"+name
        receipt=self.d.send("open",uri=uri,title=name,benchmark=True,projection=projection,
            stereo=stereo,enabled=alpha,depth=depth,loop=True,layer=True)
        return self.d.wait(receipt,self.label("open-"+name),lambda r:r["media"]["frame_counter"]>=3,90)

    def count(self, value):
        return self.d.probe(self.label("count-"+str(value)),"count",value=value,
            predicate=lambda r:len(r["layout"]["pip"]["windows"])==value)

    def format(self, projection, layout, **options):
        def valid(r):
            v=r["layout"]
            return (v["geometry"]==GEOMETRY[projection] and v["stereo_sbs"]==(layout!=0)
                and v["top_bottom"]==(layout in (2,4)) and v["stereo_half"]==(layout in (3,4)))
        self.d.probe(self.label("format"),"format",projection=projection,layout=layout,**options)
        return self.observe("format-ready",valid)

    def layers(self, eyes, processed=False):
        def valid(r):
            p=r["layout"]["pip"]
            native = all(w["on_layer"] for w in p["windows"]) and len(p["layers"])==3 and (not processed or p["main_ready"])
            mesh = p.get("main_cost_fallback", False) and all(not w["on_layer"] for w in p["windows"]) and not p["layers"] and p["main_image"]==[0,0]
            return len(p["windows"])==3 and (native or mesh)
        report=self.observe("layers-ready",valid,90)
        assert report["layout"]["pip"]["fallback"] in ("", "transparent_cost"), report["layout"]["pip"]
        return report

    def pause(self):
        return self.d.wait(self.d.send("playing",enabled=False),self.label("paused"),
            lambda r:r["native_status"]["details"].get("paused")=="yes")

    def samples(self, eyes, swap=False, viewing=0, identity=True, processed=False, alpha=None):
        if self.mono_pip:
            eyes = 1
        report=self.d.probe(self.label("pixels"),"samples",
            predicate=lambda r:len(r["layout"]["pip"]["samples"].split())==3*eyes*6)
        p=report["layout"]["pip"]
        values=list(map(int,p["samples"].split()))
        identity_info=report["media"].get("presentation_identity",{})
        if identity:
            assert identity_info.get("source_pts_verified") and identity_info.get("pair_identity_verified"), identity_info
            frame=round(identity_info["pts_us"]*30/1_000_000)%180
            expected=(128+3*(frame%32),60,40)
            for i in range(0,len(values),6):
                slot,eye,*rgba=values[i:i+6]
                source=(viewing-1 if viewing else 0 if self.mono_pip else eye)
                if swap:source=1-source
                want=expected if source==0 else expected[::-1]
                assert max(abs(a-b) for a,b in zip(rgba[:3],want))<=9 and rgba[3]>245,(slot,eye,rgba,want,identity_info)
        if alpha is not None:
            assert all(abs(values[i+5]-alpha)<=8 for i in range(0,len(values),6)),values
        if processed:
            main=list(map(int,p["main_samples"].split()))
            assert len(main)==12,main
            for i in range(0,len(values),6):
                eye=values[i+1]
                compare=main[eye*6+2:eye*6+6]
                assert max(abs(a-b) for a,b in zip(values[i+2:i+6],compare))<=9,(values[i:i+6],compare)
        return report

    def expected_alpha(self, mask):
        # Respect the user's edge controls rather than changing their settings or
        # pretending the default shader bounds are the active production bounds.
        config=self.d.shell("run-as",self.d.package,"cat","files/player_settings.cfg").decode()
        def value(key,default):
            found=re.search(r"(?m)^"+key+r"=([0-9.]+)\s*$",config)
            return min(100,max(0,float(found.group(1)))) if found else default
        half=.01+.49*value("alpha_feather",100)/100
        centre=.5+.4*value("alpha_shrink",40)/100
        low=min(.98,max(0,centre-half));high=min(1,max(low+.02,centre+half))
        return round(255*max(0,min(1,(mask/255-low)/(high-low))))

    def matrix(self):
        cases=[("flat-sbs",0,1,"sbs"),("flat-half-sbs",0,3,"sbs"),
            ("flat-tb",0,2,"tb"),("flat-half-tb",0,4,"tb"),
            ("180-sbs",1,1,"sbs"),("180-half-sbs",1,3,"sbs"),
            ("180-tb",1,2,"tb"),("180-half-tb",1,4,"tb"),
            ("360-sbs",3,1,"sbs"),("360-tb",3,2,"tb"),
            ("fish-sbs",2,1,"sbs"),("fish-half-sbs",2,3,"sbs"),
            ("fish-tb",2,2,"tb"),("fish-half-tb",2,4,"tb")]
        for name,projection,layout,source in cases:
            self.open("pip_identity_"+source+".mp4",projection)
            self.format(projection,layout,fov=190,swap=False,eye=0,curve=0,horizontal=0,vertical=0)
            self.count(3); report=self.layers(2)
            if projection==0:
                assert report["layout"]["video_layer"]["surface"] and report["layout"]["pip"]["atlas"]==[0,0]
            else:
                for slot in (1,2,3): self.d.probe(self.label("center"),"pick",slot=slot,x=0,y=0)
                self.pause(); report=self.samples(2)
            self.results.append({"case":name,"state":"passed","pip":report["layout"]["pip"]})
            print("PASS",name,flush=True)
        self.open("pip_identity_sbs.mp4",0)
        self.format(0,1,curve=.5,rotation=20,swap=False,eye=0)
        self.count(3); r=self.layers(2)
        assert r["layout"]["video_layer"]["surface"],r["layout"]
        self.d.probe(self.label("curved-pick"),"pick",slot=1,u=.3,v=.7)
        self.format(0,1,curve=0,rotation=0)
        self.results.append({"case":"curved-rotated-flat","state":"passed"})
        for projection in (0,2,3):
            self.open("pip_identity_sbs.mp4",projection,stereo=False)
            self.format(projection,0,fov=220,swap=False,eye=0)
            self.count(3); self.layers(1)
            self.results.append({"case":"mono-"+GEOMETRY[projection],"state":"passed"})
        # Paused source survives lens parameter changes and does not continuously redraw.
        self.open("pip_identity_sbs.mp4",2); self.format(2,1,fov=180,swap=False,eye=0)
        self.count(3); self.layers(2); self.pause()
        self.format(2,1,fov=220); self.layers(2)
        paused=self.observe("paused-cache")
        time.sleep(1)
        repeated=self.observe("paused-cache-repeat")
        assert repeated["layout"]["pip"]["draws"]==paused["layout"]["pip"]["draws"],(paused["layout"]["pip"],repeated["layout"]["pip"])
        receipt=self.d.send("seek",position_ms=3000,seek_mode="exact")
        self.d.wait(receipt,self.label("seek-complete"),lambda r:r["layout"]["playback_control"]["state"]=="idle" and abs(r["layout"]["playback_control"]["display_position_ms"]-3000)<150)
        self.layers(2)
        self.results.append({"case":"paused-lens-seek-cache","state":"passed"})
        # Production gestures include every corner; visual layout is checked before movement.
        self.open("pip_identity_sbs.mp4",1); self.format(1,1,swap=False,eye=0)
        self.count(3); r=self.layers(2)
        positions={w["slot"]:w["position"] for w in r["layout"]["pip"]["windows"]}
        assert positions[1][1]>positions[2][1] and positions[2][0]<positions[1][0]<positions[3][0],positions
        for step in ("move","pick"):
            self.d.probe(self.label(step),step,slot=1)
        for corner in range(4):self.d.probe(self.label("corner-"+str(corner)),"resize",slot=1,corner=corner)
        self.pause()
        for swap,eye in ((True,0),(False,1),(True,2)):
            self.format(1,1,swap=swap,eye=eye)
            for slot in (1,2,3):self.d.probe(self.label("center"),"pick",slot=slot,x=0,y=0)
            self.layers(2 if eye==0 else 1); self.samples(2 if eye==0 else 1,swap,eye)
        self.format(1,1,swap=False,eye=0,horizontal=.5,vertical=.25)
        self.layers(2); self.format(1,1,horizontal=0,vertical=0)
        self.d.probe(self.label("close-slot1"),"close",slot=1)
        r=self.observe("numbering",lambda r:[w["slot"] for w in r["layout"]["pip"]["windows"]]==[2,3])
        self.count(3)
        self.results.append({"case":"gestures-eyes-numbering","state":"passed"})
        self.effects()

    def effects(self):
        # Built-in mask: independent main and PiP samples should agree at the same centre.
        self.open("pip_FISHEYE_F180_alpha.mp4",2,alpha=True)
        self.format(2,1,fov=180,swap=False,eye=0)
        self.count(3); self.layers(2,True)
        for slot in (1,2,3):self.d.probe(self.label("center"),"pick",slot=slot,x=0,y=0)
        self.pause(); r=self.samples(2,identity=False,processed=True,alpha=self.expected_alpha(128))
        self.results.append({"case":"packed-alpha","state":"passed","pip":r["layout"]["pip"]})
        # AI and depth use the existing models and the exact same leased processed frame.
        self.open("pip_identity_sbs.mp4",1,alpha=True)
        self.format(1,1,swap=False,eye=0)
        self.count(3); self.layers(2,True)
        for slot in (1,2,3):self.d.probe(self.label("center"),"pick",slot=slot,x=0,y=0)
        self.pause(); r=self.samples(2,identity=False,processed=True)
        assert r["layout"]["alpha_requested"] and r["layout"]["alpha_enabled"],r["layout"]
        self.results.append({"case":"rvm-alpha","state":"passed","pip":r["layout"]["pip"]})
        self.open("mp05_person_still.mp4",1,alpha=True)
        self.format(1,1,swap=False,eye=0)
        self.count(3); self.layers(2,True)
        for slot in (1,2,3):self.d.probe(self.label("person-center"),"pick",slot=slot,x=0,y=0)
        self.pause();r=self.samples(2,identity=False,processed=True)
        values=list(map(int,r["layout"]["pip"]["samples"].split()))
        assert max(values[i+5] for i in range(0,len(values),6))>=128,values
        assert r["native_status"]["bridge"]["zero_copy"] and r["media"]["presentation_identity"]["inference_ran"],r["media"]
        self.results.append({"case":"nonzero-person-rvm-alpha-oes","state":"passed","pip":r["layout"]["pip"]})
        self.open("depth_2d.mp4",0,stereo=False,depth=True)
        self.count(3)
        r=self.observe("depth-warped",lambda r:r["layout"]["video_layer"]["warped"] and all(w["on_layer"] for w in r["layout"]["pip"]["windows"]),120)
        self.pause(); r=self.samples(2,identity=False)
        self.results.append({"case":"depth","state":"passed","pip":r["layout"]["pip"]})
        self.open("depth_2d.mp4",0,stereo=True)
        self.format(0,1,swap=True,eye=2)
        self.count(3);self.layers(1)
        self.format(0,0)
        self.d.send("depth",enabled=True)
        r=self.observe("retained-eye-depth",lambda r:r["layout"]["video_layer"]["warped"] and r["layout"]["video_layer"]["shown"]
            and len(r["layout"]["pip"]["layers"])==3,120)
        assert r["layout"]["viewing_eye"]==2,r["layout"]
        sampling=r["layout"]["pip"]["sampling"]
        assert sampling["stereo"] and sampling["eye"]==0 and not sampling["swap"] and sampling["offset"]==[0,0],sampling
        main=[layer for layer in r["layout"]["video_layer"]["layers"] if layer["slot"]==0 and layer["source"]==1]
        assert len(main)==2 and main[0]["eye"]==1 and main[1]["eye"]==2 and main[0]["rect"][0]==0 and main[1]["rect"][0]==main[0]["rect"][2],main
        self.results.append({"case":"retained-native-eye-to-depth","state":"passed","main_layers":main,"sampling":sampling})
        self.open("mp06_text_subtitles.mkv",0,stereo=False)
        self.count(3); self.layers(1)
        self.d.send("subtitle",track_id=1)
        self.d.wait(self.d.send("seek",position_ms=1500,seek_mode="exact"),self.label("subtitle-seek"),
            lambda r:r["layout"]["playback_control"]["state"]=="idle")
        self.observe("subtitle-ready",lambda r:bool(r["layout"]["subtitles"].get("text")))
        self.results.append({"case":"subtitle-with-three-windows","state":"passed"})

    def performance(self, seconds, selected=None):
        for case,name,projection,stereo,alpha,depth in (
            ("flat4k","mp08_4k.mp4",0,False,False,False),("flat8k","mp08_8k_long.mp4",0,False,False,False),
            ("vr1804k","mp08_4k.mp4",1,True,False,False),("vr3608k","mp08_8k_long.mp4",3,True,False,False),
            ("rvm8k","mp08_8k_long.mp4",1,True,True,False),
            ("packed1k","pip_FISHEYE_F180_alpha.mp4",2,True,True,False),
            ("packed8k","pip_8k_FISHEYE_F180_alpha.mp4",2,True,True,False),
            ("person8k","pip_person8k.mp4",1,True,True,False),
            ("person","mp05_person_still.mp4",1,True,True,False),("depth","depth_2d.mp4",0,False,False,True)):
            if selected and case not in selected:continue
            self.open(name,projection,stereo,alpha,depth)
            self.format(projection,1 if stereo else 0,fov=180,swap=False,eye=0,curve=0,horizontal=0,vertical=0)
            self.d.send("perf_tune",refresh_rate=0 if alpha or depth else 90)
            alpha_proof=None
            if case in ("person8k","packed8k"):
                self.count(3);self.layers(2,True)
                for slot in (1,2,3):self.d.probe(self.label("stress-center"),"pick",slot=slot,x=0,y=0)
                proof=self.pause()
                if proof["layout"]["pip"].get("main_cost_fallback",False):
                    # This path intentionally owns no atlas to read back. Do not
                    # pretend a mesh snapshot is a native pixel/opacity check.
                    assert proof["layout"]["alpha_enabled"] and all(not w["on_layer"] for w in proof["layout"]["pip"]["windows"])
                    alpha_proof={"path":"shared_frame_mesh","native_pixel_readback":"unavailable"}
                    if case=="person8k":assert proof["media"]["presentation_identity"]["inference_ran"]
                else:
                    proof=self.samples(2,identity=False,processed=True,
                        alpha=self.expected_alpha(128) if case=="packed8k" else None)
                    alpha_proof=proof["layout"]["pip"]["samples"]
                    pixels=list(map(int,alpha_proof.split()))
                    assert max(pixels[i+5] for i in range(0,len(pixels),6))>0,pixels
                    if case=="person8k":
                        assert max(pixels[i+5] for i in range(0,len(pixels),6))>=128 and proof["media"]["presentation_identity"]["inference_ran"]
                        assert proof["native_status"]["bridge"]["zero_copy"]
                self.d.send("playing",enabled=True)
            pair=[]
            for count in (0,3,0):
                self.count(count)
                if count: self.layers(2 if stereo or depth else 1,alpha or "alpha" in name)
                self.d.send("hide_menus")
                self.d.send("perf_tune",quiet=True)
                time.sleep(3)
                label=self.label("perf-"+self.run_id+"-"+name.removesuffix(".mp4")+"-"+str(count))
                pid=self.d.shell("pidof",self.d.package).decode().strip().split()[0]
                started=time.monotonic();epoch=time.time()
                with (self.d.output/(label+"-vrapi.log")).open("wb") as stream:
                    logger=subprocess.Popen([self.d.adb,"-s",self.d.serial,"logcat","-v","epoch","--pid="+pid,"-T","1","VrApi:I","*:S"],
                        stdin=subprocess.DEVNULL,stdout=stream,stderr=subprocess.STDOUT,creationflags=getattr(subprocess,"CREATE_NO_WINDOW",0))
                    try:
                        self.d.send("perf_sample",label=label,seconds=seconds)
                        self.d.send("perf_tune",quiet=True)
                        deadline=time.monotonic()+seconds+30
                        while time.monotonic()<deadline:
                            sample=self.d.read("perf_sample_"+label+".json")
                            if sample:break
                            time.sleep(.5)
                        else:raise TimeoutError(label)
                    finally:
                        logger.terminate()
                        try:logger.wait(timeout=5)
                        except subprocess.TimeoutExpired:logger.kill();logger.wait()
                sample["observed_wall_seconds"]=round(time.monotonic()-started,3)
                sample["epoch_start"]=epoch;sample["epoch_end"]=time.time()
                (self.d.output/(label+".json")).write_text(json.dumps(sample,indent=2))
                r=self.observe("perf-state")
                pair.append({"count":count,"sample":sample,"pip":r["layout"]["pip"],"media":r["media"]})
                print("PERF",name,count,sample["delta_ms"],"late",sample["late_frames"],flush=True)
            self.results.append({"case":case,"file":name,"projection":projection,"stereo":stereo,"alpha":alpha,"depth":depth,"nonzero_alpha_proof":alpha_proof,"pair":pair})

    def timing(self):
        self.open("mp08_8k_long.mp4",3)
        self.format(3,1,swap=False,eye=0,horizontal=0,vertical=0)
        self.count(3)
        heavy=self.observe("large-main-fallback",lambda r:r["layout"]["pip"].get("main_cost_fallback",False),90)
        self.open("pip_identity_sbs.mp4",1)
        self.format(1,1,swap=False,eye=0,horizontal=0,vertical=0)
        self.count(3);self.layers(2)
        time.sleep(5)
        light=self.observe("small-main-still-native",lambda r:r["layout"]["video_layer"]["shown"]
            and r["layout"]["pip"]["main_ready"] and r["layout"]["pip"]["metrics"].get("main_gpu_samples",0)>=60,20)
        assert not light["layout"]["pip"]["main_cost_fallback"],light["layout"]["pip"]
        self.pause();self.samples(2,processed=True)
        self.results.append({"case":"main-timing-heavy-to-light","state":"passed",
            "heavy":heavy["layout"]["pip"],"light":light["layout"]["pip"]})

    def memory(self, name):
        raw=self.d.shell("dumpsys","meminfo",self.d.package).decode(errors="replace")
        (self.d.output/(name+".txt")).write_text(raw)
        pss=re.search(r"TOTAL PSS:\s*(\d+)",raw)
        return int(pss.group(1)) if pss else None

    def lifecycle(self, restore):
        # Exercise main swapchain and fixed projection cache as well as the atlas.
        self.open("pip_FISHEYE_F180_alpha.mp4",2,alpha=True); self.format(2,1,fov=180,swap=False,eye=0)
        for count in (1,2,3):self.count(count)
        self.layers(2,True)
        memory=[]
        for cycle in range(9):
            if cycle in (0,3,8):memory.append({"cycle":cycle,"pss_kb":self.memory("memory-"+str(cycle))})
            self.count(0)
            r=self.observe("released",lambda r:r["layout"]["pip"]["atlas"]==[0,0] and r["layout"]["pip"]["main_image"]==[0,0])
            self.count(3);self.layers(2,True)
        target={"1":1.5,"2":4.0,"3":2.0}
        for slot,zoom in target.items():self.d.probe(self.label("persist-set"),"zoom",slot=int(slot),value=zoom)
        self.close()
        self.d.shell("am","force-stop",self.d.package)
        self.d.shell("am","start","-W","-a","android.intent.action.MAIN","-c",
            "org.khronos.openxr.intent.category.IMMERSIVE_HMD","-n",self.d.package+"/com.godot.game.GodotAppLauncher")
        self.d.process=None
        deadline=time.monotonic()+30
        while True:
            try:self.d.send("observe");break
            except RuntimeError as error:
                if "Running Godot plugin unavailable" not in str(error) or time.monotonic()>=deadline:raise
                time.sleep(.5)
        self.observe("persist-after-restart",lambda r:r["layout"]["pip"]["preferences"]==target)
        self.open("pip_identity_sbs.mp4",1);self.format(1,1,swap=False,eye=0);self.count(3);self.layers(2)
        self.observe("window-zoom-after-restart",lambda r:all(w["zoom"]==target[str(w["slot"])] for w in r["layout"]["pip"]["windows"]))
        for slot,zoom in restore.items():self.d.probe(self.label("restore-zoom"),"zoom",slot=int(slot),value=zoom)
        self.observe("zoom-restored",lambda r:r["layout"]["pip"]["preferences"]==restore)
        self.results.append({"case":"resource-cycles-and-global-persistence","state":"passed","memory":memory,"restored_zoom":restore})


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument("--adb",default="adb");p.add_argument("--serial",required=True)
    p.add_argument("--output",type=Path,required=True)
    p.add_argument("--fixtures",type=Path,default=Path("build/output/video-pip/fixtures"))
    p.add_argument("--mode",choices=("matrix","effects","performance","lifecycle","timing"),required=True)
    p.add_argument("--restore-zoom",help="Comma-separated original per-slot zooms when restoring an earlier test's changes")
    p.add_argument("--seconds",type=float,default=12)
    pip_view = p.add_mutually_exclusive_group()
    pip_view.add_argument("--mono-pip", action="store_true", default=True, help="Validate fixed-2D PiP (default); the main video retains stereo")
    pip_view.add_argument("--legacy-stereo-pip", action="store_false", dest="mono_pip", help="Only for comparing a previously installed stereo-PiP build")
    p.add_argument("--cases",nargs="+",choices=("flat4k","flat8k","vr1804k","vr3608k","rvm8k","packed1k","packed8k","person8k","person","depth"))
    args=p.parse_args();d=Device(args.adb,args.serial,args.output);s=Suite(d,args.fixtures,args.mono_pip)
    deadline=time.monotonic()+30
    while True:
        try:d.send("observe");break
        except RuntimeError as error:
            if "Running Godot plugin unavailable" not in str(error) or time.monotonic()>=deadline:raise
            time.sleep(.5)
    initial=d.read("capabilities_latest.json");assert initial and initial["xr"]["initialized"]
    original=initial["video_layout"]["pip"]["preferences"]
    report={"mode":args.mode,"mono_pip":args.mono_pip,"original_zoom":original,"state":"running","results":s.results}
    try:
        if args.mode=="matrix":s.matrix()
        elif args.mode=="effects":s.effects()
        elif args.mode=="performance":s.performance(args.seconds,args.cases)
        elif args.mode=="timing":s.timing()
        else:s.lifecycle(dict(zip(("1","2","3"),map(float,args.restore_zoom.split(",")))) if args.restore_zoom else original)
        report["state"]="passed"
    except BaseException as error:
        report["state"]="failed";report["error"]=str(error);raise
    finally:
        try:s.close();d.send("perf_tune",refresh_rate=0,quiet=True)
        except Exception as error:
            report["cleanup_error"]=str(error);report["state"]="failed"
        (d.output/"summary.json").write_text(json.dumps(report,indent=2))
    print("Suite",report["state"],"cases",len(s.results),flush=True)
    if report["state"]!="passed":raise SystemExit(1)


if __name__=="__main__":main()
