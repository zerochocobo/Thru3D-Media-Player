"""Authorized Quest recording regression through production controls and real playback.

Creates synthetic per-channel tones/subtitles, preserves settings in backups/, and
checks exported media. This operates the headset; run only with user authorization.
"""
import argparse
import hashlib
import io
import json
import runpy
import re
import subprocess
import tarfile
import time
import zlib
import struct
import urllib.parse
from datetime import datetime
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/output/capture-save-audio-20261024/device'
FIXTURES = OUT / 'fixtures'
FREQUENCIES = [401, 631, 863, 79, 1327, 1567]
Device = runpy.run_path(str(Path(__file__).with_name('Test-VideoPipDevice.py')))['Device']


def run(arguments):
    return subprocess.run(list(map(str, arguments)), capture_output=True, check=True).stdout


def prepare():
    FIXTURES.mkdir(parents=True, exist_ok=True)
    srt = FIXTURES / 'speech.srt'
    srt.write_text('\n\n'.join(f'{i+1}\n00:00:{start:02d},000 --> 00:00:{start+6:02d},000\nThe recording keeps my voice.'
                             for i, start in enumerate([5, 16, 27, 38, 49])), encoding='utf-8')
    for name, channels, geometry in [('plain_2D.mp4', 2, 0), ('surround_2D.mkv', 6, 0),
                                     ('surround_360_LRF.mkv', 6, 3), ('surround_360_4K_LRF.mkv', 6, 4)]:
        target = FIXTURES / name
        identity = hashlib.sha256(json.dumps([FREQUENCIES[:channels], channels, geometry, 65]).encode()).hexdigest()
        stamp=target.with_suffix(target.suffix+'.sha256')
        if target.exists() and stamp.exists() and stamp.read_text().strip()==identity:
            continue
        tones = '|'.join(f'0.04*sin(2*PI*{f}*t)' for f in FREQUENCIES[:channels])
        layout = 'stereo' if channels == 2 else '5.1(side)'
        size = '3840x1920' if geometry == 4 else ('1920x960' if geometry else '1280x720')
        run(['ffmpeg', '-v', 'error', '-y', '-f', 'lavfi', '-i', f'color=c=0x303030:s={size}:r=30,drawgrid=w=80:h=80:t=2:c=white@0.3',
             '-f', 'lavfi', '-i', f'aevalsrc={tones}:s=48000:c={layout}', '-i', srt, '-t', '65',
             '-map', '0:v', '-map', '1:a', '-map', '2:s', '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '22',
             '-g', '30', '-bf', '2', '-c:a', 'aac' if channels == 2 else 'eac3', '-b:a', '192k' if channels == 2 else '640k',
             '-c:s', 'mov_text' if name.endswith('.mp4') else 'srt', target])
        stamp.write_text(identity,encoding='ascii')
        print('Prepared', name, flush=True)
    def chunk(tag, value):
        return struct.pack('>I', len(value)) + tag + value + struct.pack('>I', zlib.crc32(tag + value))
    row = b'\0' + bytes((240, 20, 220)) * 128 + bytes((20, 230, 240)) * 128
    (FIXTURES / 'pip-marker.png').write_bytes(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>2I5B', 256, 128, 8, 2, 0, 0, 0))
                                            + chunk(b'IDAT', zlib.compress(row * 128)) + chunk(b'IEND', b''))


class Regression:
    def __init__(self, args):
        self.d = Device(args.adb, args.serial, OUT)
        self.serial = 0
        self.results = []
        self.smb_title = args.smb_title
        package_path = self.d.shell('pm', 'path', self.d.package).decode().strip().removeprefix('package:')
        assert package_path.startswith('/data/app/') and '\n' not in package_path
        self.apk_sha256 = self.d.shell('sha256sum', package_path).decode().split()[0]
        self.backup = Path(args.backup) if args.backup else ROOT / 'backups' / ('capture-regression-' + datetime.now().strftime('%Y%m%d-%H%M%S'))
        assert self.backup.resolve().is_relative_to((ROOT/'backups').resolve())

    def observe(self, label='observe'):
        self.serial += 1
        return self.d.wait(self.d.send('observe'), f'{self.serial:04d}-{label}', lambda r: True, 30)

    def wait(self, label, predicate, seconds=60):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            report = self.observe(label)
            result = report.get('capture_result', {})
            if result.get('state') == 'error':
                raise RuntimeError(label + ': ' + str(result))
            if predicate(report):
                return report
            time.sleep(.25)
        raise TimeoutError(label)

    def save_settings(self):
        if (self.backup/'settings.tar').exists():
            self.settings_archive()
            print('Using preserved pre-test settings backup', self.backup.name, flush=True)
            return
        self.backup.mkdir(parents=True)
        data = self.d.command('exec-out', 'run-as', self.d.package, 'tar', '-C', 'files', '-cf', '-', 'settings', 'player_settings.cfg')
        with tarfile.open(fileobj=io.BytesIO(data)) as archive:
            assert all(not Path(p.name).is_absolute() and '..' not in Path(p.name).parts and not p.issym() and not p.islnk() for p in archive)
        (self.backup / 'settings.tar').write_bytes(data)
        (self.backup / 'manifest.json').write_text(json.dumps({'sha256': hashlib.sha256(data).hexdigest(), 'scope': 'App preferences/settings before authorized recording regression'}), encoding='utf-8')
        print('Saved settings backup', self.backup.name, flush=True)

    def settings_archive(self):
        data = (self.backup / 'settings.tar').read_bytes()
        manifest = json.loads((self.backup / 'manifest.json').read_text(encoding='utf-8'))
        assert hashlib.sha256(data).hexdigest() == manifest['sha256'], 'Pre-test settings backup was altered'
        with tarfile.open(fileobj=io.BytesIO(data)) as archive:
            assert all(not Path(p.name).is_absolute() and '..' not in Path(p.name).parts and not p.issym() and not p.islnk() for p in archive)
        return data

    def restore_settings(self):
        # Close the recording and let accepted cancellation finish before stopping.
        self.d.send('close')
        time.sleep(1)
        self.d.send('menu_action', target='capture_cancel')
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            if not self.observe('cleanup-before-restore').get('capture', {}).get('clip_busy'):
                break
            time.sleep(.3)
        else:
            raise RuntimeError('Recording worker has not cleaned up; preserve settings backup for recovery')
        self.d.send('close')
        time.sleep(1)
        self.d.shell('am', 'force-stop', self.d.package)
        data = self.settings_archive()
        self.d.command('exec-in', 'run-as ' + self.d.package + ' tar -C files -xf -', data=data)
        self.d.shell('am', 'start', '-n', self.d.package + '/com.godot.game.GodotAppLauncher')
        self.d.process = None
        print('Restored pre-test settings and restarted normal VR launcher', flush=True)

    def smb_entry(self):
        assert self.smb_title and '/' not in self.smb_title and '\\' not in self.smb_title, 'Pass the reported MKV basename with --smb-title'
        series = re.split(r'S\d\dE\d\d', self.smb_title, maxsplit=1)[0]
        banks = []
        for index in [0, 1]:
            try:
                outer = json.loads(self.d.shell('run-as', self.d.package, 'cat', f'files/settings/recent_files_{index}.json'))
                banks.append(json.loads(outer['payload_json']))
            except (RuntimeError, ValueError, KeyError):
                pass
        for bank in sorted(banks, key=lambda v: v['sequence'], reverse=True):
            for entry in bank['entries'].values():
                if entry.get('uri', '').startswith('smb://') and entry.get('title', '').startswith(series):
                    # A recent episode locates the same directory; open the exact
                    # basename explicitly supplied for this authorized regression.
                    result=dict(entry)
                    directory=result['uri'].rsplit('/',1)[0]
                    result['uri']=directory+'/'+urllib.parse.quote(self.smb_title,safe='[]._-()')
                    result['title']=self.smb_title
                    result['position_ms']=92_000
                    return result
        raise RuntimeError('The reported SMB MKV was not found in the current recent-file catalog')

    def open(self, uri, title, projection=0, position=0):
        self.d.send('close')
        self.d.send('open', uri=uri, title=title, benchmark=True, projection=projection, stereo=projection != 0,
                    enabled=False, depth=False, layer=True, position_ms=position, loop=False)
        report = self.wait('opened', lambda r: r['media']['frame_counter'] >= 10 and r['media']['state'] in ['playing', 'paused'], 90)
        self.d.send('hide_menus')
        return report

    def enable_narration(self):
        report = self.observe('subtitle-tracks')
        subtitles = report['media']['playback']['details']['subtitle_tracks']
        assert subtitles, 'Fixture text subtitles are missing'
        self.d.send('subtitle', track_id=int(subtitles[0]['id']))
        self.d.send('narration', options={'voice_kind': 'preset', 'language': 'en', 'profile': 'en_female',
                                        'duck': 50.0, 'volume': 100.0, 'enabled': True})
        self.wait('narration-enabled', lambda r: r['media']['playback'].get('narration', {}).get('enabled'), 30)

    def screenshot(self, label):
        self.d.send('menu_action', target='capture_screenshot')
        report = self.wait(label, lambda r: r.get('capture_result', {}).get('kind') == 'screenshot'
                           and r['capture_result'].get('state') == 'saved')
        result = report['capture_result']
        assert result['name'] in report['capture']['notice'], 'Save notice omitted the filename'
        local = OUT / (label + '.' + result['extension'])
        self.d.command('pull', '/sdcard/Pictures/Thru3D/' + result['name'], local)
        case = {'case': label, 'apk_sha256': self.apk_sha256, 'result': result, 'local_file': str(local), 'marker': verify_marker(local)}
        self.results.append(case)
        (OUT / 'device-results.json').write_text(json.dumps(self.results, indent=2), encoding='utf-8')

    def record(self, label, seconds, channels, narrated=False, cancel=False, cancel_at=0):
        print('Recording', label, flush=True)
        self.d.send('menu_action', target='capture_record')
        self.wait(label + '-recording', lambda r: r.get('capture', {}).get('recording'), 30)
        deadline = time.monotonic() + seconds + 150
        narration = []
        while time.monotonic() < deadline:
            report = self.observe(label + '-running')
            result = report.get('capture_result', {})
            assert result.get('state') != 'error', result
            assert report.get('capture', {}).get('recording'), result
            status = report['media'].get('playback', {}).get('narration', {})
            narration.append(status)
            voice_ready = not narrated or (status.get('written_frames', 0) >= 48000 and status.get('completed', 0) >= 1)
            if report['capture']['duration_ms'] >= seconds * 1000 and voice_ready:
                break
            time.sleep(.3)
        else:
            raise TimeoutError(label + ': recording/narration did not advance')
        save_started = time.monotonic()
        cancel_started = None
        self.d.send('menu_action', target='capture_record')
        progress = []
        cancelling = False
        deadline = time.monotonic() + 300
        while time.monotonic() < deadline:
            report = self.observe(label + '-saving')
            state, result = report.get('capture', {}), report.get('capture_result', {})
            percent = state.get('export_progress', -1)
            if percent >= 0:
                progress.append(percent)
            assert result.get('state') != 'error', result
            if cancel and not cancelling and state.get('export_cancellable') and percent >= cancel_at:
                cancel_started = time.monotonic()
                self.d.send('menu_action', target='capture_cancel')
                cancelling = True
            if not state.get('clip_busy'):
                break
            time.sleep(.25)
        else:
            raise TimeoutError(label + ': save did not finish')
        save_elapsed = time.monotonic() - save_started
        assert progress == sorted(progress), progress
        if cancel:
            assert cancelling and result.get('state') == 'cancelled', result
            cache = self.d.shell('run-as', self.d.package, 'ls', '-1', 'cache/').decode()
            assert not any(line.startswith('live-clip-') for line in cache.splitlines()), 'Cancelled clip left local files'
            pending = self.d.shell('content', 'query', '--uri', 'content://media/external_primary/video/media', '--projection', '_id',
                                   '--where', "is_pending=1 AND relative_path='Movies/Thru3D/'").decode()
            assert 'Row:' not in pending, pending
            summary = {'case': label, 'cancelled': True, 'progress': progress, 'no_pending_file': True, 'temporary_files_clean': True,
                       'cancel_seconds': time.monotonic() - cancel_started}
        else:
            assert result.get('state') == 'saved', result
            assert result['name'] in state['notice'], 'Save notice omitted the filename'
            assert result['capture_metrics']['lost_blocks'] == 0, result
            assert result['capture_metrics']['audio_channels'] == channels, result
            local = OUT / (label + '.mkv')
            self.d.command('pull', '/sdcard/Movies/Thru3D/' + result['name'], local)
            summary = {'case': label, 'result': result, 'progress': progress, 'local_file': str(local),
                       'save_seconds': save_elapsed,
                       'narration_completed': max((s.get('completed', 0) for s in narration), default=0),
                       'narration_written_frames': max((s.get('written_frames', 0) for s in narration), default=0),
                       'narration_truncated': max((s.get('output_truncated', 0) for s in narration), default=0)}
            analyze(summary, channels, narrated)
        summary['apk_sha256'] = self.apk_sha256
        self.results.append(summary)
        (OUT / 'device-results.json').write_text(json.dumps(self.results, indent=2), encoding='utf-8')
        print('Verified', label, flush=True)
        return summary


def analyze(case, channels, narrated):
    path = Path(case['local_file'])
    info = json.loads(run(['ffprobe', '-v', 'error', '-show_streams', '-show_format', '-of', 'json', path]))
    audio = next(s for s in info['streams'] if s['codec_type'] == 'audio')
    video = next(s for s in info['streams'] if s['codec_type'] == 'video')
    assert audio['channels'] == channels and audio['codec_name'] == 'pcm_f32le', audio
    decode = subprocess.run(['ffmpeg', '-v', 'error', '-i', str(path), '-map', '0:v', '-f', 'null', '-'], capture_output=True)
    assert decode.returncode == 0 and not decode.stderr, decode.stderr.decode(errors='replace')
    raw = run(['ffmpeg', '-v', 'error', '-i', path, '-map', '0:a', '-f', 'f32le', '-'])
    pcm = np.frombuffer(raw, dtype='<f4').reshape(-1, channels)
    assert np.isfinite(pcm).all() and np.max(np.abs(pcm)) <= 1.001
    assert np.max(np.abs(pcm)) > .0001, 'The recording audio is silent'
    residuals = []
    tones = []
    for start in range(48000, len(pcm) - 24000, 24000):
        block = pcm[start:start+24000].astype(np.float64)
        residual = []
        strength = []
        t = np.arange(len(block)) / 48000
        for channel in range(channels):
            f = FREQUENCIES[channel]
            basis = np.column_stack([np.sin(2*np.pi*f*t), np.cos(2*np.pi*f*t), np.ones(len(t))])
            fitted = basis @ np.linalg.lstsq(basis, block[:, channel], rcond=None)[0]
            residual.append(float(np.sqrt(np.mean((block[:, channel] - fitted)**2))))
            strength.append(float(np.sqrt(np.mean(fitted**2))))
        residuals.append(residual); tones.append(strength)
    case['audio'] = {'channels': channels, 'sample_rate': int(audio['sample_rate']), 'seconds': len(pcm)/48000,
                     'peak': float(np.max(np.abs(pcm))), 'rms': np.sqrt(np.mean(pcm.astype(np.float64)**2, axis=0)).tolist()}
    case['video'] = {key: video.get(key) for key in ['codec_name', 'width', 'height', 'color_transfer', 'color_primaries']}
    tags = {k.lower(): v for k, v in info['format'].get('tags', {}).items()}
    case['pip_composed'] = tags.get('thru3d_pip') == 'composed'
    if case['case'].startswith('pip-'):
        assert case['pip_composed'], 'PiP composition metadata is missing'
    if case['case'] == 'pip-narration':
        case['marker'] = verify_marker(path)
    if channels > 2:
        assert tags.get('thru3d_audio_channel_mask') == '1551', tags
    if not case['case'].startswith('smb'):
        assert tones and np.max(tones, axis=0).min() > .004, tones
        if narrated:
            peak_voice = np.max(residuals, axis=0)
            assert min(peak_voice[:2]) > .005, peak_voice.tolist()
            if channels > 2:
                assert min(peak_voice[:2]) > max(peak_voice[2:]) * 3, peak_voice.tolist()
            assert case['narration_completed'] >= 1 and case['narration_written_frames'] > 48000
            assert case['narration_truncated'] == 0, case
            case['audio']['voice_residual_rms'] = peak_voice.tolist()


def verify_marker(path):
    raw = run(['ffmpeg', '-v', 'error', '-i', path, '-frames:v', '1', '-pix_fmt', 'rgb24', '-f', 'rawvideo', '-'])
    rgb = np.frombuffer(raw, dtype=np.uint8).reshape(-1, 3)
    pink = int(np.sum((rgb[:, 0] > 180) & (rgb[:, 1] < 100) & (rgb[:, 2] > 180)))
    cyan = int(np.sum((rgb[:, 0] < 100) & (rgb[:, 1] > 180) & (rgb[:, 2] > 180)))
    assert min(pink, cyan) > 20, (pink, cyan)
    return {'pink_pixels': pink, 'cyan_pixels': cyan}


def execute(args):
    suite = Regression(args)
    if args.resume and (OUT/'device-results.json').exists():
        suite.results=json.loads((OUT/'device-results.json').read_text(encoding='utf-8'))
    suite.results = [case for case in suite.results if case['case'] not in args.repeat_case]
    completed={case['case'] for case in suite.results}
    suite.save_settings()
    smb = suite.smb_entry()
    try:
        suite.d.shell('am', 'broadcast', '-a', 'com.oculus.vrpowermanager.prox_close')
        if 'smb-original' not in completed:
            suite.open(smb['uri'], smb['title'], position=int(smb['position_ms']))
            suite.record('smb-original', 6, 6)
        for fixture, label, channels in [('plain_2D.mp4', 'stereo-original', 2), ('surround_2D.mkv', 'surround-original', 6)]:
            if label in completed: continue
            suite.open(suite.d.upload(FIXTURES / fixture), fixture)
            suite.d.send('narration', options={'enabled': False})
            suite.record(label, 6, channels)
        for fixture, label, channels in [('plain_2D.mp4', 'stereo-narration', 2), ('surround_2D.mkv', 'surround-narration', 6)]:
            if label in completed: continue
            suite.open(suite.d.upload(FIXTURES / fixture), fixture)
            suite.enable_narration()
            suite.record(label, 17, channels, narrated=True)
        suite.open(suite.d.upload(FIXTURES / 'surround_360_LRF.mkv'), 'surround_360_LRF.mkv', projection=3)
        suite.d.send('narration', options={'enabled': False})
        suite.d.probe('pip-one', 'count', value=1, predicate=lambda r: len(r['layout']['pip']['windows']) == 1)
        if 'pip-cancel' not in completed:
            suite.record('pip-cancel', 12, 6, cancel=True)
        if 'pip-saved-after-cancel' not in completed:
            saved = suite.record('pip-saved-after-cancel', 6, 6)
            assert saved['pip_composed'], saved
        if any(label not in completed for label in ['pip-image-screenshot', 'pip-narration']):
            suite.d.probe('pip-image', 'image', uri=suite.d.upload(FIXTURES / 'pip-marker.png'))
            suite.wait('pip-image-ready', lambda r: any(w.get('mode') == 'image' and not w['image_loading'] and not w['image_error'] for w in r['layout']['pip']['windows']))
            if 'pip-image-screenshot' not in completed:
                suite.screenshot('pip-image-screenshot')
            if 'pip-narration' not in completed:
                suite.d.send('seek', position_ms=0)
                suite.wait('pip-seek-ready', lambda r: r['layout']['playback_control']['state'] == 'idle'
                           and r['layout']['playback_control']['source_frame_pts_verified']
                           and r['layout']['playback_control']['observed_position_ms'] < 3000)
                suite.enable_narration()
                saved = suite.record('pip-narration', 17, 6, narrated=True)
                assert saved['pip_composed'], saved
        if any(label not in completed for label in ['pip-4k-cancel-encoding', 'pip-4k-saved']):
            suite.open(suite.d.upload(FIXTURES / 'surround_360_4K_LRF.mkv'), 'surround_360_4K_LRF.mkv', projection=3)
            suite.d.send('narration', options={'enabled': False})
            suite.d.probe('pip-4k-one', 'count', value=1)
            # The compositor can revise the presentation route after its first
            # GPU samples. Do not press the capture action during that transition.
            suite.wait('pip-4k-warmed', lambda r: r['media']['frame_counter'] >= 150
                       and r['layout']['pip']['draws'] >= 120 and r['layout']['frame_hold']['visible'])
            if 'pip-4k-cancel-encoding' not in completed:
                cancelled = suite.record('pip-4k-cancel-encoding', 8, 6, cancel=True, cancel_at=25)
                assert cancelled['cancel_seconds'] < 10, cancelled
            if 'pip-4k-saved' not in completed:
                saved = suite.record('pip-4k-saved', 6, 6)
                assert saved['pip_composed'] and saved['video']['width'] == 3840, saved
        for result in suite.results:
            channels = result.get('audio', {}).get('channels')
            if result.get('local_file') and channels:
                if result.get('replay_apk_sha256') == suite.apk_sha256:
                    continue
                # Debug opens intentionally accept only approved fixture files,
                # not arbitrary content:// URIs. Upload verifies identical bytes.
                report = suite.open(suite.d.upload(Path(result['local_file'])), 'recording-check.mkv')
                layout = '5.1(side)' if channels == 6 else 'stereo'
                restored = suite.wait('replay-layout', lambda r: r['media']['playback']['details'].get('audio_output_layout') == layout
                                      and (channels == 2 or r['media']['playback']['details'].get('capture_audio_layout_applied')), 25)
                result['replay_layout'] = restored['media']['playback']['details']['audio_output_layout']
                result['replay_apk_sha256'] = suite.apk_sha256
                (OUT / 'device-results.json').write_text(json.dumps(suite.results, indent=2), encoding='utf-8')
        (OUT / 'device-results.json').write_text(json.dumps(suite.results, indent=2), encoding='utf-8')
        assert {case['case'] for case in suite.results} == {
            'smb-original', 'stereo-original', 'surround-original', 'stereo-narration', 'surround-narration',
            'pip-cancel', 'pip-saved-after-cancel', 'pip-image-screenshot', 'pip-narration',
            'pip-4k-cancel-encoding', 'pip-4k-saved'}
        print('All headset recording cases passed', flush=True)
    finally:
        try:
            suite.restore_settings()
        finally:
            suite.d.shell('am', 'broadcast', '-a', 'com.oculus.vrpowermanager.automation_disable')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['prepare', 'run'])
    parser.add_argument('--adb', default='adb')
    parser.add_argument('--serial', default='', help='Explicit headset serial; required for device runs')
    parser.add_argument('--smb-title', default='', help='Explicitly authorized MKV basename; no credentials or full URL')
    parser.add_argument('--backup', default='', help='Reuse the original pre-test settings backup on a retry')
    parser.add_argument('--resume', action='store_true', help='Keep completed verified cases while retrying a test fixture')
    parser.add_argument('--repeat-case', action='append', default=[], help='Repeat a selected smoke case against a replacement APK')
    args = parser.parse_args()
    if args.action == 'run' and not args.serial:
        parser.error('--serial is required for an authorized device run')
    prepare() if args.action == 'prepare' else execute(args)
