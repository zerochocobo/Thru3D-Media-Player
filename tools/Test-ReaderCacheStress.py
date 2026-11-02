#!/usr/bin/env python3
"""Real local CBZ/PDF magazine stress using a complete -IncludeDiagnostics Debug APK.

Explicit device/output/private backup arguments are required. Pillow is required.
Stops test media and restores settings byte-for-byte. Serialise store_capture requests.
Raw device logs can contain private information and are saved only under backups/.
"""
import argparse, importlib.util, json, time, uuid, re, hashlib, traceback
from pathlib import Path

def generate(folder):
    from PIL import Image,ImageDraw
    from zipfile import ZipFile,ZIP_STORED,ZIP_DEFLATED
    folder.mkdir(parents=True,exist_ok=True)
    base=Image.open(Path(__file__).resolve().parents[1]/'app/godot/backgrounds/belfast_sunset_puresky.jpg').convert('RGB')
    for compact in [False,True]:
        name='Compact' if compact else 'Mixed'
        images=[];files=[]
        for i in range(16):
            w,h=([(1000,3000),(1000,3500),(1800,2400),(1600,3000)] if compact else [(900,700),(1024,1024),(1379,1923),(4000,3000),(4096,4096),(8192,4096),(2048,3072)])[i%(4 if compact else 7)]
            image=base.resize((w,h));draw=ImageDraw.Draw(image)
            draw.rectangle((w//4,h//3,w*3//4,h*3//4),fill=[(170,30,60),(30,150,60),(50,50,190)][i%3])
            path=folder/f'{name}-{i+1:03d}.jpg';image.save(path,quality=90,progressive=i%2==0);files.append(path)
            page=image.copy();page.thumbnail((3000,4000));images.append(page)
        with ZipFile(folder/f'{name}.cbz','w',ZIP_DEFLATED if compact else ZIP_STORED) as z:
            for i,path in enumerate(files):z.write(path,f'{i+1:03d}.jpg')
        images[0].save(folder/f'{name}.pdf','PDF',resolution=144,save_all=True,append_images=images[1:])
    return sorted([*folder.glob('*.cbz'),*folder.glob('*.pdf')])

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--adb',required=True);parser.add_argument('--serial',required=True)
    parser.add_argument('--package',default='com.wapok.thru3d')
    parser.add_argument('--output',required=True,type=Path);parser.add_argument('--backup',required=True,type=Path)
    parser.add_argument('--each',type=int,choices=[1,2],default=2)
    args=parser.parse_args();workspace=Path(__file__).resolve().parents[1]
    if not args.output.resolve().is_relative_to(workspace/'build') or not args.backup.resolve().is_relative_to(workspace/'backups'):
        parser.error('Rebuildable reports belong in build/; private settings and raw logs belong in backups/')
    spec=importlib.util.spec_from_file_location('device',Path(__file__).with_name('Test-PhotoCacheDevice.py'));d=importlib.util.module_from_spec(spec);spec.loader.exec_module(d)
    d.ADB=args.adb;d.SERIAL=args.serial;d.PKG=args.package
    root=args.output.resolve();out=root;out.mkdir(parents=True,exist_ok=True);backup=args.backup.resolve();backup.mkdir(parents=True,exist_ok=False)
    folder='/sdcard/Android/data/'+d.PKG+'/files/Thru3D-reader-crash-'+uuid.uuid4().hex[:12];books=generate(root/'fixtures');samples=[];failure=None
    original=d.read('files/player_settings.cfg');assert original;(backup/'settings.cfg').write_bytes(original)
    def setting(s,section,key,value):
     match=re.search(r'(?ms)^\['+re.escape(section)+r'\]\r?\n(.*?)(?=^\[|\Z)',s)
     if not match:return s+'\n['+section+']\n'+key+'='+value+'\n'
     body=match.group(1);pattern=r'(?m)^'+re.escape(key)+r'\s*=.*$'
     body=re.sub(pattern,key+'='+value,body) if re.search(pattern,body) else body+key+'='+value+'\n'
     return s[:match.start(1)]+body+s[match.end(1):]
    temp=original.decode('utf-8')
    for section,key,value in [('privacy','history','"none"'),('privacy','file_settings','"none"'),('effects','auto_3d','true'),('photo','cache_each',str(args.each)),('photo','spatial_preferred','false'),('photo_screen','reading_layout','4')]:temp=setting(temp,section,key,value)

    def store(params):
     key='reader_'+uuid.uuid4().hex[:12];d.write('files/store_capture/request.json',json.dumps(dict(params,id=key)).encode())
     until=time.monotonic()+100
     while time.monotonic()<until:
      if not d.adb('shell','pidof',d.PKG,check=False).strip():raise RuntimeError('Application process exited')
      try:
       r=json.loads(d.read('files/store_capture/response.json'))
       if r.get('id')==key:return r
      except ValueError:pass
      time.sleep(.2)
     raise TimeoutError('Reader request acknowledgement')
    def save(): (out/'report.json').write_text(json.dumps({'samples':samples,'failure':failure},indent=2),encoding='utf-8')
    def state(stage):
     r=store({'operation':'status'});p=r['photo'];data={'stage':stage,'photo_active':r['photo_active'],**{k:p.get(k) for k in ['index','count','archive_mode','layout','loading','placeholder','preparing_depth','depth_enabled','depth_requested','magazine_pages','error','depth_error','source_size']}}
     memory=d.shell('dumpsys','meminfo',d.PKG);data['memory']=[l.strip() for l in memory.splitlines() if 'TOTAL PSS:' in l or l.strip().startswith('TOTAL ')]
     samples.append(data);save();print(json.dumps(data,ensure_ascii=True),flush=True);return data
    try:
     d.shell('am','force-stop',d.PKG);d.write('files/player_settings.cfg',temp.encode('utf-8'))
     d.shell('mkdir','-p',folder)
     for p in books:d.adb('push',p,folder+'/'+p.name)
     d.shell('am','broadcast','-a','com.oculus.vrpowermanager.prox_close');d.shell('input','keyevent','KEYCODE_WAKEUP')
     d.shell('am','start','-n',d.PKG+'/com.godot.game.GodotAppLauncher','-a','android.intent.action.MAIN','-c','com.oculus.intent.category.VR','-c','org.khronos.openxr.intent.category.IMMERSIVE_HMD')
     time.sleep(3)
     store({'operation':'status'}) # Wait until Godot's main scene and diagnostics are actually ready.
     d.command('perf_tune',quiet=True)
     for book in books:
      result=store({'operation':'reader_probe','phase':'open','uri':'file://'+folder+'/'+book.name})
      if result['state']!='ready':raise RuntimeError('Reader fixture open failed: '+str(result['state'])+' '+str(result.get('library',{})))
      first=state(book.name+'-open');assert first['archive_mode'] and first['layout']==4 and first['count']==16,'Not in actual archive magazine mode'
      # Burst before the current page has finished decoding/conversion.
      response=store({'operation':'reader_probe','phase':'turn','count':6,'direction':1,'interval':.016})
      state(book.name+'-early');samples[-1]['turns']=response.get('library',{}).get('turns',[]);save()
      settled=False
      for i in range(25):
       time.sleep(2);r=state(book.name+'-warmup-'+str(i))
       if not r['loading'] and r['depth_enabled']:settled=True;break
      if not settled:raise RuntimeError('Reader did not recover to actual 3D before cache pressure test')
      for i in range(5):time.sleep(2);state(book.name+'-idle-'+str(i))

      for i in range(12):
       response=store({'operation':'reader_probe','phase':'turn','count':6,'direction':-1 if i%2==0 else 1,'interval':.05 if i%3 else .2})
       state(book.name+'-burst-'+str(i));samples[-1]['turns']=response.get('library',{}).get('turns',[]);save()
      for i in range(12):
       time.sleep(2);r=state(book.name+'-settle-'+str(i))
       if not r['loading'] and r['depth_enabled']:break
      if r['loading'] or not r['depth_enabled']:raise RuntimeError('Reader did not recover to 3D after rapid navigation')
      # The next real archive selection closes the prior reader through the app's normal path.
    except Exception as e:
     failure=type(e).__name__+': '+str(e);save();print(traceback.format_exc(),flush=True)
    finally:
     for name,args in [('crash',('logcat','-b','crash','-d','-v','threadtime')),('exits',('shell','dumpsys','activity','exit-info',d.PKG)),('logcat',('logcat','-d','-v','threadtime'))]: (backup/(name+'.txt')).write_bytes(d.adb(*args,check=False))
     d.shell('am','force-stop',d.PKG);d.write('files/player_settings.cfg',original);assert d.read('files/player_settings.cfg')==original
     for p in books:d.shell('rm','-f',folder+'/'+p.name)
     d.shell('rmdir',folder)
     d.shell('am','start','-n',d.PKG+'/com.godot.game.GodotAppLauncher','-a','android.intent.action.MAIN','-c','com.oculus.intent.category.VR','-c','org.khronos.openxr.intent.category.IMMERSIVE_HMD')
     d.command('perf_tune',quiet=True);d.shell('am','broadcast','-a','com.oculus.vrpowermanager.prox_open')
     (out/'cleanup.json').write_text(json.dumps({'settings_equal':True,'settings_sha256':hashlib.sha256(original).hexdigest(),'fixtures_removed':True}),encoding='utf-8')
     if failure:raise RuntimeError(failure)

if __name__=="__main__":main()
