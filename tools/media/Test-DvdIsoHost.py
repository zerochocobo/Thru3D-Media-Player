"""Exercise original DVD menus with the native probe, without mounting the ISO.

The pointer and chapter are supplied for the chosen authored disc. Outputs are
rebuildable evidence; this does not control or install anything on a headset.
"""
import argparse
import json
import os
from pathlib import Path
import queue
import shutil
import subprocess
import threading
import time

p = argparse.ArgumentParser()
p.add_argument('iso')
p.add_argument('--binary-dir', type=Path, required=True)
p.add_argument('--output', type=Path, required=True)
p.add_argument('--point', nargs=2, type=int, required=True, metavar=('X', 'Y'))
p.add_argument('--chapter', type=int, required=True)
args = p.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
for name in ('frame.ppm', 'overlay.rgba', 'overlay.json'):
    (args.output / name).unlink(missing_ok=True)
env = dict(os.environ)
env['LD_LIBRARY_PATH'] = ':'.join(str(args.binary_dir.resolve() / name) for name in (
    'libavformat', 'libavcodec', 'libavutil', 'libswscale', 'libavfilter', 'libswresample', 'libavdevice'))
probe = str(args.binary_dir.resolve() / 'dvd_menu_probe')
preflight = json.loads(subprocess.check_output([probe, args.iso], env=env, text=True, timeout=30))
assert preflight['disc']['disc_type'] == 'dvd', preflight
assert 1 <= len(preflight['disc']['titles']) <= 99, preflight
assert preflight['disc']['menu'] == 'dvd', 'This interaction test needs a DVD with menus'
(args.output / 'preflight.json').write_text(json.dumps(preflight, indent=2) + '\n')
messages = queue.Queue()
with (args.output / 'decode.log').open('w') as log, (args.output / 'states.jsonl').open('w') as states:
    child = subprocess.Popen([probe, args.iso, str(args.output)], env=env,
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log, text=True, bufsize=1)

    def read_states():
        for line in child.stdout:
            messages.put(json.loads(line))

    threading.Thread(target=read_states, daemon=True).start()

    def wait_for(predicate):
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            state = messages.get(timeout=max(.01, deadline - time.monotonic()))
            states.write(json.dumps(state) + '\n'); states.flush()
            assert not state.get('error'), state
            if predicate(state):
                return state
        raise AssertionError('DVD navigation did not reach the expected state')

    def send(kind, x=0, y=0):
        child.stdin.write(f'{kind} {x} {y}\n'); child.stdin.flush()

    try:
        wait_for(lambda s: s.get('menu') and s.get('buttons') and s.get('seen'))
        # The first VOBU must finish before its single still picture is ready.
        deadline = time.monotonic() + 5
        while not (args.output / 'frame.ppm').exists() and time.monotonic() < deadline:
            time.sleep(.05)
        assert (args.output / 'frame.ppm').stat().st_size > 1000
        # A static menu must keep the video clock moving while its audio plays.
        # The native probe deliberately does NOT throttle audio-only packets.
        time.sleep(2)
        wait_for(lambda s: s.get('menu') and s.get('seen'))
        assert (args.output / 'decode.log').read_text().count('video packet bytes') >= 3
        initial = (args.output / 'overlay.rgba').read_bytes()
        send(0, *args.point)
        wait_for(lambda s: s.get('menu') and (args.output / 'overlay.rgba').read_bytes() != initial)
        shutil.copyfile(args.output / 'frame.ppm', args.output / 'menu.ppm')
        shutil.copyfile(args.output / 'overlay.rgba', args.output / 'hover.rgba')
        send(1, -1, -1)  # A ray miss must never activate the old highlight.
        wait_for(lambda s: 'input' in s)
        send(0, *args.point)
        wait_for(lambda s: 'input' in s)
        wait_for(lambda s: s.get('menu'))
        send(1, *args.point)
        selection = wait_for(lambda s: s.get('title', 0) > 0 and not s.get('menu'))
        assert selection['chapter'] == args.chapter, selection
        send(7)
        wait_for(lambda s: s.get('menu') and s.get('buttons'))
    finally:
        started = time.monotonic()
        send(-1)
        try:
            child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            child.kill(); child.wait()
            raise AssertionError('DVD menu did not cancel promptly')
    assert child.returncode == 0, 'Native menu decode failed; see decode.log'
    result = dict(passed=True, selection=selection, hover=True, miss=True,
                  return_menu=True, cancel_seconds=round(time.monotonic() - started, 3))
    (args.output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result))
