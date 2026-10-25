"""Verify live capture against unchanged source packets/pixels and the actual submitted audio trace."""
import argparse
import array
import json
import subprocess
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/output/live-capture'
SOURCE=ROOT/'build/output/original-capture'

def run(args):
    return subprocess.run([str(x) for x in args],capture_output=True,check=True)

def probe(path,selector=None,packets=False):
    args=['ffprobe','-v','error','-of','json']
    if selector:args+=['-select_streams',selector]
    args+=['-show_packets','-show_data_hash','sha256'] if packets else ['-show_streams','-show_format']
    return json.loads(run(args+[path]).stdout)

def consecutive(source,actual):
    return any(source[i:i+len(actual)]==actual for i in range(len(source)-len(actual)+1))

def frame_hashes(path):
    output=run(['ffmpeg','-v','error','-i',path,'-map','0:v:0','-f','framemd5','-']).stdout.decode()
    return [line.rsplit(',',1)[-1].strip() for line in output.splitlines() if line and not line.startswith('#')]

def verify():
    reports=[]
    for name in ['avc','hdr','normal','mkv-avc','mkv-hdr','surround']:
        folder=OUT/name;source=SOURCE/(('avc' if name in ['normal','surround'] else name.removeprefix('mkv-'))+'.mp4');output=folder/'live.mkv'
        assert not (folder/'live-input.mp4').exists(),'The temporary source copy must be unavailable before stop/export'
        src=probe(source,'v:0')['streams'][0];dst=probe(output,'v:0')['streams'][0]
        metadata=json.loads(probe(output)['format']['tags']['THRU3D_MODE'])
        assert metadata['geometry']==(0 if name.startswith('mkv-') or name=='surround' else 3)
        fields=['codec_name','width','height','pix_fmt','color_range','color_space','color_transfer','color_primaries']
        for key in fields:assert src.get(key)==dst.get(key),(name,key,src.get(key),dst.get(key))
        original=probe(source,'v:0',True)['packets'];captured=probe(output,'v:0',True)['packets']
        assert consecutive([p['data_hash'] for p in original],[p['data_hash'] for p in captured]),'Encoded video must remain a continuous original interval'
        original_frames=frame_hashes(source);actual_frames=frame_hashes(output)
        assert all(value in original_frames for value in actual_frames),'Every decoded picture must retain original pixels'
        positions=[original_frames.index(value) for value in actual_frames]
        assert positions==sorted(set(positions)),'Displayed source pictures must stay in order'
        # B-frame reference pictures after stop may survive without every later dependent
        # picture. Every picture through the requested stop must still be present unchanged.
        required_end=135 # 4.5 s at this fixture's authored 30 fps.
        assert positions[:required_end-positions[0]]==list(range(positions[0],required_end)),positions
        decode=run(['ffmpeg','-v','error','-i',output,'-f','null','-'])
        assert not decode.stderr,decode.stderr.decode(errors='replace')
        raw=run(['ffmpeg','-v','error','-i',output,'-map','0:a:0','-f','f32le','-']).stdout
        samples=array.array('f');samples.frombytes(raw)
        channels=6 if name=='surround' else 2
        assert len(samples)==int(2.5*48000*channels),len(samples)
        expected={.25:0.0,.75:.25,1.6:.25,1.8:.125,2.3:.25} if name not in ['normal','surround'] else {}
        for seconds,value in expected.items():
            at=round(seconds*48000)*2
            assert abs(samples[at]-value)<1e-6,(name,seconds,samples[at],value)
            assert samples[at]==samples[at+1]
        if name=='normal':
            reference=array.array('f');reference.frombytes((folder/'staged.reference.f32').read_bytes())
            assert len(reference)==len(samples)
            assert all(abs(a-b)<1e-7 for a,b in zip(reference,samples)),'Normal heard PCM must be preserved without narration'
        if name=='surround':
            stream=probe(output,'a:0')['streams'][0]
            assert stream['channels']==6,stream
            assert probe(output)['format']['tags']['THRU3D_AUDIO_CHANNEL_MASK']=='1551'
            for seconds in [.75,1.6,1.8,2.3]:
                at=round(seconds*48000)*6
                for channel in range(6):
                    expected_sample=(channel+1)/32 + ([.125,.1875][channel] if channel<2 else 0)
                    assert abs(samples[at+channel]-expected_sample)<1e-7,(channel,samples[at+channel],expected_sample)
        audio=probe(output,'a:0',True)['packets']
        alignment=abs(float(captured[0]['pts_time'])-float(audio[0]['pts_time']))
        assert alignment<.080,alignment
        stages=[json.loads(line) for line in (folder/'report.log').read_text().splitlines() if line.startswith('{')]
        assert stages[0]['capture_metrics']['lost_blocks']==0
        assert stages[-1]['state']=='saved'
        reports.append({'case':name,'video_packets':len(captured),'source_packets_identical':True,'decoded_frames_identical':True,'requested_interval_complete':True,
            'source_unavailable_before_stop':True,'audio_seconds':len(samples)/(48000*channels),'audio_channels':channels,'audio_trace_samples':expected,
            'keyframe_preroll_seconds':.5,'initial_av_difference_seconds':alignment,'capture_metrics':stages[0]['capture_metrics']})
    report={'state':'passed','scope':'Exact production C++ GOP/queues/physical presentation boundary/mixer/RF64/local mux; synthetic host trace, no device claim',
        'cases':reports,'not_device_verified':['AAudio and AudioTrack hardware timestamps','PICO/Quest frame time and thermal load','MediaStore on device']}
    (OUT/'verification.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(report,indent=2))

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('action',choices=['prepare','verify']);args=parser.parse_args()
    if args.action=='prepare':subprocess.run(['python',str(ROOT/'tools/Test-OriginalCapture.py'),'prepare'],check=True)
    else:verify()
