"""Authorized short Quest/115 Debug check; saves sanitized counters, never URLs.

Use --root-file for the user-selected 115 root sample. Without it the existing
provider probe reopens its recent video, allowing before/after normal playback.
No APK install, account changes or long-running soak test. MVC uses the real
library entry, including the user's normal history and per-file settings policy.
"""
import argparse
import hashlib
import json
from pathlib import Path
import sys
import time
import uuid
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from adb_shell_session import AdbShell

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--serial',required=True)
p.add_argument('--provider',choices=('115_open','115'),default='115_open')
p.add_argument('--root-file',default='')
p.add_argument('--fixture',choices=('mp08_8k_long','mp07_motion_4k'))
p.add_argument('--ordinary-size',type=int,default=0,help='Reopen the exact earlier provider-probe source with this size; no URLs enter output')
p.add_argument('--ordinary-duration-ms',type=int,default=0,help='Exact earlier measured duration, for recovering its unique history URI after an app update')
p.add_argument('--expect-mvc',action='store_true')
p.add_argument('--reference',type=Path)
p.add_argument('--wake',action='store_true')
p.add_argument('--output',type=Path,required=True)
a=p.parse_args();a.output.mkdir(parents=True,exist_ok=True)
package='com.wapok.thru3d'
d=AdbShell(['adb','-s',a.serial])
records=[];result={'passed':False,'provider':a.provider,'expected_mvc':a.expect_mvc}
def read(name):
    try:return json.loads(d.run('run-as',package,'cat','files/diagnostics/'+name,check=False))
    except ValueError:return {}
def broadcast(action,values):
    key='mkv_'+uuid.uuid4().hex
    command=['am','broadcast','--async','--user','current','-n',package+'/org.vrpassthroughplayer.plugin.DebugDiagnosticsReceiver',
        '-a',package+'.'+action,'--es','request',key]
    for name,value in values.items():
        command+=['--ez' if isinstance(value,bool) else '--ei' if isinstance(value,int) else '--es',name,str(value).lower() if isinstance(value,bool) else str(value)]
    d.run(*command)
    return key
def request(operation,**values):
    key=broadcast('DEBUG_PLAYER_MPV',dict(operation=operation,**values))
    until=time.monotonic()+15
    while time.monotonic()<until:
        receipt=read('debug_request_'+key+'.json')
        if receipt.get('state')=='accepted':
            # A real library close clears the player diagnostic context before
            # its final report. Verify closure with a fresh observe below.
            if operation=='menu_action' and values.get('target')=='stop':return {'receipt':receipt['id']}
            report=read('mpv_player_'+str(receipt['id'])+'.json')
            if any(c.get('request_key')==key for c in report.get('commands',[])):return report
        time.sleep(.15)
    raise TimeoutError('Player diagnostic acknowledgement: '+operation)
def clean(report):
    media=report.get('media',{})
    details=dict(media.get('playback',{}).get('details',{}))
    native=report.get('native_status',{})
    details.update(native.get('details',{}))
    for key in ('software_layer','layer_compatible'):
        details[key]=native.get(key,media.get('playback',{}).get(key))
    for key in ('position_seconds','duration_seconds','avsync_seconds'):
        try:details[key]=float(details[key])
        except (ValueError,TypeError,KeyError):details[key]=None
    fmt=media.get('format',{})
    return dict(state=media.get('state'),session_id=media.get('session_id'),frames=media.get('frame_counter',0),
        error=bool(media.get('error')),format={k:fmt.get(k) for k in ('width','height','stereo_mode')},
        stereo=report.get('layout',{}).get('stereo_sbs'),stereo_half=report.get('layout',{}).get('stereo_half'),
        video_layer={k:report.get('layout',{}).get('video_layer',{}).get(k) for k in ('shown','surface')},
        details={k:details.get(k) for k in ('position_seconds','duration_seconds','paused','codec','hwdec_current',
            'hardware_decoding','software_layer','layer_compatible','audio_output','audio_codec','audio_clock_available','avsync_seconds')})
def snapshot(label):
    state=clean(request('observe'));state['case']=label;records.append(state)
    (a.output/'records.json').write_text(json.dumps(records,indent=2)+'\n')
    return state
def ready(label,target=None):
    until=time.monotonic()+60
    while time.monotonic()<until:
        state=snapshot(label)
        if state['error']:raise RuntimeError('Playback reported an error: '+label)
        position=state['details'].get('position_seconds')
        if state['frames']>=2 and isinstance(position,(float,int)) and position>=.1 and (target is None or abs(position-target)<2):return state
        time.sleep(.5)
    raise TimeoutError('Actual decoded playback: '+label)
def advance(label):
    first=ready(label+'-first');time.sleep(2);last=snapshot(label+'-advanced')
    assert last['frames']>first['frames']+8 and last['details']['position_seconds']>first['details']['position_seconds']+1,(label,last)
    return last
def source_uri(cloud,key,wait=True):
    until=time.monotonic()+(15 if wait else .1)
    while time.monotonic()<until:
        report=read('mpv_player_'+str(cloud['player_request'])+'.json')
        command=next((c for c in report.get('commands',[]) if c.get('request_key')==key and c.get('uri','').startswith('cloud://')),None)
        if command:return command['uri']
        time.sleep(.15)
    raise RuntimeError('Correlated cloud source is no longer available')
try:
    if a.wake:
        d.run('am','broadcast','-a','com.oculus.vrpowermanager.prox_close')
        d.run('input','keyevent','KEYCODE_WAKEUP')
        d.run('am','start','-n',package+'/com.godot.game.GodotAppLauncher','-a','android.intent.action.MAIN',
            '-c','com.oculus.intent.category.VR','-c','org.khronos.openxr.intent.category.IMMERSIVE_HMD')
        time.sleep(5)
    if a.ordinary_size:
        assert not a.root_file and not a.fixture and not a.expect_mvc
        names=d.run('sh','-c','ls -t files/diagnostics/cloud_probe_mkv_*.json',check=False).decode().splitlines()
        selected=None
        for name in names[:40]:
            name=Path(name).name
            cloud=read(name)
            if cloud.get('provider',a.provider)==a.provider and cloud.get('file_size')==a.ordinary_size and cloud.get('state') in ('passed','ranges_passed'):
                try:selected=source_uri(cloud,name.removeprefix('cloud_probe_').removesuffix('.json'),False)
                except RuntimeError:continue
                break
        if selected is None and a.ordinary_duration_ms:
            banks=[]
            for bank in (0,1):
                try:banks.append(json.loads(d.run('run-as',package,'cat',f'files/settings/recent_files_{bank}.json')))
                except ValueError:pass
            entries=json.loads(max(banks,key=lambda b:b['sequence'])['payload_json'])['entries']
            candidates=[e['uri'] for e in entries.values() if e.get('uri','').startswith('cloud://') and
                e.get('kind')=='video' and e.get('duration_ms')==a.ordinary_duration_ms]
            assert len(candidates)==1,'Earlier duration must identify one existing history source'
            selected=candidates[0]
            result['baseline_history_duration_ms']=a.ordinary_duration_ms
        assert selected,'Earlier normal-provider source unavailable; do not substitute a different movie'
        request('open',uri=selected,title='Normal playback regression',stereo=False,benchmark=True,normal_fast=True,enabled=False)
        result['baseline_file_size']=a.ordinary_size
    elif a.fixture:
        assert not a.root_file and not a.reference and not a.expect_mvc
        result['provider']='local_fixture'
        request('open',fixture=a.fixture,stereo=False,benchmark=True,normal_fast=True,enabled=False)
        result['fixture']=a.fixture
    else:
        key=broadcast('DEBUG_CLOUD',dict(provider=a.provider,play=True,root_file=a.root_file))
        until=time.monotonic()+90;cloud={}
        while time.monotonic()<until:
            cloud=read('cloud_probe_'+key+'.json')
            if cloud.get('state') in ('passed','ranges_passed','failed'):break
            time.sleep(.5)
        result['cloud']={k:cloud.get(k) for k in ('provider','state','selection','file_size','head_bytes','seek_bytes','head_sha256','seek_sha256','error_type','reason')}
        assert cloud.get('state') in ('passed','ranges_passed'),result['cloud']
        if a.reference:
            assert cloud['file_size']==a.reference.stat().st_size
            with a.reference.open('rb') as ref:
                for name,offset in [('head',0),('seek',cloud['file_size']//2)]:
                    ref.seek(offset);digest=hashlib.sha256(ref.read(cloud[name+'_bytes'])).hexdigest()
                    assert cloud[name+'_sha256']==digest,name+' bytes differ from local sample'
            result['range_bytes_match_local']=True
        if a.expect_mvc:
            # "open" is an explicit-layout decoder probe (restore_mode=false).
            # Validate automatic layout through the same path as a library click.
            selected=source_uri(cloud,key)
            request('menu_action',target='stop');time.sleep(.5)
            request('library_open',params=json.dumps(dict(uri=selected,title=a.root_file)))
            result['library_entry_used']=True
    state=advance('start')
    if a.ordinary_duration_ms:
        assert abs(state['details']['duration_seconds']*1000-a.ordinary_duration_ms)<2,state
    if a.expect_mvc:
        assert state['format']['width']==3840 and state['format']['height']==1080,state
        assert state['format']['stereo_mode'] in ('sbsl','sbs2l','left_right'),state
        assert state['details']['software_layer'] is True,state
        assert state['stereo'] is True and state['stereo_half'] is False,state
        assert state['video_layer']==dict(shown=True,surface=True),state
    else:
        assert state['details']['software_layer'] is not True,state
    for target in ([30,8,50,0] if a.expect_mvc else [30,0]):
        request('seek',position_ms=target*1000,seek_mode='exact')
        ready('seek-'+str(target),target)
        advance('seek-'+str(target))
    request('playing',enabled=False);time.sleep(1);paused=snapshot('paused');time.sleep(1);held=snapshot('pause-held')
    assert abs(paused['details']['position_seconds']-held['details']['position_seconds'])<.3
    request('playing',enabled=True);advance('resumed')
    result['functional_checks_passed']=True
finally:
    try:
        request('menu_action',target='stop');time.sleep(.5)
        result['closed']=snapshot('closed')['state']=='closed'
        result['passed']=result.get('functional_checks_passed',False) and result['closed']
    finally:
        if a.wake:d.run('am','broadcast','-a','com.oculus.vrpowermanager.automation_disable',check=False)
        (a.output/'result.json').write_text(json.dumps(result,indent=2)+'\n')
        d.close()
print(json.dumps(result,indent=2),flush=True)
