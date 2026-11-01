#!/usr/bin/env python3
"""Quest/PICO Debug-only local photo cache timing and first-frame regression.

Install a complete Build-Player -IncludeDiagnostics APK first. Requires Pillow.
Uses generated CC0 fixtures, preserves settings in backups/, and returns to the library.
Serialize runs: do not issue another store_capture request while this tool is running.
No test URLs, account information or personal photos are printed or saved in reports.
"""
import argparse
import hashlib
import json
import re
import shlex
import subprocess
import time
import uuid
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
ADB=SERIAL=PKG=''
OUT=BACKUP=None
FOLDER=''
CYCLE_SLEEP=False
def adb(*args,data=None,check=True,timeout=120):
    r=subprocess.run([ADB,'-s',SERIAL,*map(str,args)],input=data,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=timeout)
    if check and r.returncode: raise RuntimeError(r.stderr.decode(errors='replace'))
    return r.stdout
def shell(*args): return adb('shell',shlex.join(map(str,args))).decode(errors='replace').strip()
def read(path): return adb('exec-out','run-as',PKG,'cat',path,check=False)
def write(path,data):
    assert path.startswith('files/store_capture/') or path=='files/player_settings.cfg'
    result=adb('shell','-T',shlex.join(['run-as',PKG,'sh','-c','cat > '+shlex.quote(path)]),data=data,timeout=12)
    if result: raise RuntimeError(result.decode(errors='replace'))
    return result
def store(params):
    key='cache_'+uuid.uuid4().hex[:12]
    params=dict(params,id=key)
    write('files/store_capture/request.json',json.dumps(params).encode())
    until=time.monotonic()+100
    while time.monotonic()<until:
        try:
            r=json.loads(read('files/store_capture/response.json'))
            if r.get('id')==key:return r
        except ValueError:pass
        time.sleep(.2)
    raise TimeoutError('store capture acknowledgement')
def command(op,**params):
    key='cache_'+uuid.uuid4().hex[:16]
    args=['am','broadcast','-n',PKG+'/org.vrpassthroughplayer.plugin.DebugDiagnosticsReceiver','-a',PKG+'.DEBUG_PLAYER_MPV',
          '--es','request',key,'--es','operation',op,'--es','params',json.dumps(params,separators=(',',':'))]
    if op=='photo_open':args+=['--es','folder',params['folder'],'--es','name',params['name'],'--ei','layout',str(params.get('layout',0))]
    shell(*args)
    for _ in range(80):
        try:
            r=json.loads(read('files/diagnostics/debug_request_'+key+'.json'))
            if r.get('state')!='accepted':raise RuntimeError(str(r))
            return r
        except ValueError:time.sleep(.15)
    raise TimeoutError(op)

def save(name,data): (OUT/(name+'.json')).write_text(json.dumps(data,ensure_ascii=False,indent=2),encoding='utf-8')
def status(): return store({'operation':'photo_cache','phase':'status'})['library']
def run(each):
    store({'operation':'photo_cache','phase':'configure','each':each})
    opened_result=store({'operation':'photo_probe','uris':['file://'+FOLDER+f'/cache-{i}.jpg' for i in range(5)],'strength':1.12})
    if opened_result.get('state')=='local_file_required':raise RuntimeError('Local fixture was rejected')
    # photo_probe returns before a pending presentation/3D job finishes on a cold open.
    # The status loop below requires actual display readiness for every neighbour.
    opened=time.monotonic(); samples=[]; ready=None
    while time.monotonic()-opened<90:
        r=status();r['elapsed_s']=round(time.monotonic()-opened,3);samples.append(r)
        print(json.dumps({'each':each,'seconds':r['elapsed_s'],'stage':r.get('stage'),'upload':r.get('last_upload'),
            'budget':r.get('budget'),'neighbors':r.get('neighbors')}),flush=True)
        save(f'each-{each}-warming',samples)
        if not r['loading'] and len(r['neighbors'])==each*2 and all(e['ready'] and e['file'] for e in r['neighbors']):ready=r;break
        time.sleep(1)
    if ready is None: raise RuntimeError(f'All requested {each*2} neighbours did not become ready')
    timings=[]
    for entry in ready['neighbors']:
        step=(entry['index']-ready['index'])%5
        if step>2:step-=5
        timings.append({'offset':step,**{key:round(max(0,entry[field]-ready['shown_us'])/1e6,3) if entry[field] else None
            for key,field in [('file_s','file_us'),('depth_s','depth_us'),('ready_s','ready_us')]}})
    save(f'each-{each}-timings',{'current_open_s':round((ready['shown_us']-ready['open_started_us'])/1e6,3),'neighbors':timings})
    wake_ready_s=None
    if CYCLE_SLEEP:
        shell('input','keyevent','KEYCODE_SLEEP');time.sleep(3)
        shell('am','broadcast','-a','com.oculus.vrpowermanager.prox_close')
        shell('input','keyevent','KEYCODE_WAKEUP')
        resumed=time.monotonic();wake=[]
        while time.monotonic()-resumed<90:
            r=status();wake.append(r);save(f'each-{each}-wake',wake)
            if r['index']==ready['index'] and not r['loading'] and not r['placeholder'] and len(r['neighbors'])==each*2 and all(e['file'] and e['ready'] for e in r['neighbors']) and r['budget']['gpu_source']=='gles_timer':
                wake_ready_s=round(time.monotonic()-resumed,3);break
            time.sleep(1)
        if wake_ready_s is None:raise RuntimeError('GPU admission/cache did not recover after sleep')
    remote=f'/data/local/tmp/vrpp-photo-cache-each-{each}.mp4'
    recorder=subprocess.Popen([ADB,'-s',SERIAL,'shell','screenrecord','--time-limit','12','--bit-rate','6000000','--size','1280x720',remote],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    time.sleep(1)
    results=[]
    for direction in ([1,-1,1,-1] if each==1 else [1,1,-1,-1]):
        r=store({'operation':'photo_cache','phase':'step','direction':direction})['library'];results.append(r)
        immediate=r['immediate']
        passed=r['accepted'] and not immediate['loading'] and not immediate['placeholder'] and immediate['stereo'] and immediate['material_stereo'] and immediate['opacity']==1
        passed=passed and len(r['frames'])==30 and all(not f['loading'] and not f['placeholder'] and f['stereo'] for f in r['frames'])
        print(json.dumps({'each':each,'direction':direction,'immediate':immediate,'passed':passed,'sampled_frames':len(r['frames'])}),flush=True)
        save(f'each-{each}-steps',results)
        if not passed: raise RuntimeError('Cached navigation showed a loading cover or had no complete stereo texture')
    recorder.communicate(timeout=20)
    if recorder.returncode:raise RuntimeError('Android screen recording failed')
    adb('pull',remote,OUT/f'each-{each}-switch.mp4');shell('rm',remote)
    pixels=store({'operation':'photo_cache','phase':'pixels'})['library']['pixels'];save(f'each-{each}-pixels',pixels)
    if len(pixels)!=each*2 or any(p['error']>1.1/255 for p in pixels):raise RuntimeError('Prepared GPU pixels differ from the actual computed stereo image')
    return {'each':each,'warm_seconds':ready['elapsed_s'],'current_open_s':round((ready['shown_us']-ready['open_started_us'])/1e6,3),'timings':timings,'max_upload_cpu_us':ready['max_upload_us'],'wake_ready_s':wake_ready_s,'steps':len(results),'drawn_frames':sum(len(r['frames']) for r in results),'gpu_pixel_checks':len(pixels)*25,'passed':True}


def main():
    global ADB, SERIAL, PKG, OUT, BACKUP, FOLDER, CYCLE_SLEEP
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--adb', required=True)
    parser.add_argument('--serial', required=True)
    parser.add_argument('--package', default='com.wapok.thru3d')
    parser.add_argument('--output', required=True, type=Path, help='Rebuildable report directory under build/')
    parser.add_argument('--backup', required=True, type=Path, help='New persistent backup directory under backups/')
    parser.add_argument('--restore-settings', type=Path, help='Restore this earlier byte-exact settings snapshot on exit')
    parser.add_argument('--cycle-sleep',action='store_true',help='Quest: sleep/wake an active photo, then require cache/GPU timing recovery')
    args=parser.parse_args()
    CYCLE_SLEEP=args.cycle_sleep
    ADB,SERIAL,PKG=args.adb,args.serial,args.package
    OUT,BACKUP=args.output.resolve(),args.backup.resolve()
    if not OUT.is_relative_to(ROOT/'build') or not BACKUP.is_relative_to(ROOT/'backups'):
        parser.error('Reports belong in build/ and persistent private settings backups in backups/')
    OUT.mkdir(parents=True,exist_ok=True)
    BACKUP.mkdir(parents=True,exist_ok=False)
    original=read('files/player_settings.cfg')
    if not original:raise RuntimeError('A debuggable installed app and existing player_settings.cfg are required')
    (BACKUP/'player_settings.before.cfg').write_bytes(original)
    restore=args.restore_settings.read_bytes() if args.restore_settings else original
    if not restore:raise RuntimeError('Empty settings snapshot')
    # A fresh owned directory prevents collisions; only its five files are removed.
    FOLDER='/sdcard/Pictures/Thru3D-cache-test-'+uuid.uuid4().hex[:12]
    from PIL import Image, ImageDraw
    source=Image.open(ROOT/'app/godot/backgrounds/belfast_sunset_puresky.jpg').convert('RGB')
    fixtures=OUT/'fixtures';fixtures.mkdir(exist_ok=True)
    shell('mkdir','-p',FOLDER)
    try:
        for i in range(5):
            w,h=1357,1920
            image=source.crop((source.width*i//8,0,min(source.width,source.width*i//8+source.width//2),source.height)).resize((w,h))
            draw=ImageDraw.Draw(image)
            draw.rectangle((w//4,h//3,w*3//4,h*3//4),fill=[(165,30,55),(25,145,60),(45,60,185),(150,85,20),(100,30,145)][i],outline='black',width=9)
            path=fixtures/f'cache-{i}.jpg';image.save(path,quality=94)
            adb('push',path,FOLDER+'/'+path.name)
        shell('am','broadcast','-a','com.oculus.vrpowermanager.prox_close')
        shell('input','keyevent','KEYCODE_WAKEUP')
        command('perf_tune',quiet=True)
        pid=shell('pidof',PKG).split()[0]
        native_logger=subprocess.Popen([ADB,'-s',SERIAL,'logcat','--pid='+pid,'-v','brief','-s','QuestPhotoDepth:I','*:S'],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        try:
            results=[run(each) for each in [1,2]]
        finally:
            native_logger.terminate()
            native_bytes,_=native_logger.communicate(timeout=10)
        # Log only numeric timings from the existing native pipeline, never media URLs.
        lines=native_bytes.decode(errors='replace')
        native=[]
        for line in lines.splitlines():
            if 'request=' not in line or 'total_ms=' not in line:continue
            native.append(dict(re.findall(r'(request|total_ms|input_ms|depth_ms|stereo_ms|stereo_gpu_us)=([0-9.]+)',line)))
        save('native-pipeline-timings',native)
        ready_events=[]
        for line in read('files/diagnostics/events.jsonl').splitlines():
            try:event=json.loads(line)
            except ValueError:continue
            if event.get('event')=='photo_cache_render_ready':ready_events.append(event)
        save('render-ready-events',ready_events)
        save('acceptance-summary',{'state':'passed','cases':results})
        print(json.dumps(results),flush=True)
    finally:
        try:
            # Stop before restoring bytes so test state cannot overwrite the snapshot.
            shell('am','force-stop',PKG)
            write('files/player_settings.cfg',restore)
            restored=read('files/player_settings.cfg')==restore
            for i in range(5):shell('rm','-f',FOLDER+f'/cache-{i}.jpg')
            shell('rmdir',FOLDER)
            shell('am','start','-n',PKG+'/com.godot.game.GodotAppLauncher','-a','android.intent.action.MAIN',
                '-c','com.oculus.intent.category.VR','-c','org.khronos.openxr.intent.category.IMMERSIVE_HMD')
            command('perf_tune',quiet=True)
            save('cleanup',{'settings_byte_exact':restored,'settings_sha256':hashlib.sha256(restore).hexdigest(),'owned_fixtures_removed':True})
            if not restored:raise RuntimeError('Restored settings differ from the original snapshot')
        finally:
            shell('am','broadcast','-a','com.oculus.vrpowermanager.prox_open')

if __name__=='__main__':main()
