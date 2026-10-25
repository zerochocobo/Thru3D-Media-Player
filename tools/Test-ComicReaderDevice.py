"""QUEST Debug comic diagnostics through the existing shell-protected receiver.

Requires an explicitly installed complete APK. Copies only the selected local sample pages.
Writes reproducible evidence to build/output; never modifies saved voice records or settings.
"""
import argparse
import json
from pathlib import Path
import shlex
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parent.parent
ADB = Path('adb')
PACKAGE = 'com.wapok.thru3d'
OUTPUT = ROOT / 'build/output/comic-reader-20261025/device'
OUTPUT.mkdir(parents=True, exist_ok=True)


def adb(*args, binary=False):
    result = subprocess.run([str(ADB), *map(str, args)], capture_output=True, timeout=180)
    if result.returncode:
        raise RuntimeError(result.stderr.decode('utf-8', 'replace'))
    return result.stdout if binary else result.stdout.decode('utf-8', 'replace').strip()


def shell(*args):
    return adb('shell', shlex.join(map(str, args)))


def read_json(path):
    try:
        return json.loads(adb('exec-out', 'run-as', PACKAGE, 'cat', path))
    except (RuntimeError, ValueError):
        return None


def command(operation, params=None, extra=()):
    key = 'comic_' + uuid.uuid4().hex[:12]
    args = ['am', 'broadcast', '-n', PACKAGE + '/org.vrpassthroughplayer.plugin.DebugDiagnosticsReceiver',
            '-a', PACKAGE + '.DEBUG_PLAYER_MPV', '--es', 'request', key, '--es', 'operation', operation]
    if params:
        args += ['--es', 'params', json.dumps(params, ensure_ascii=False, separators=(',', ':'))]
    shell(*args, *extra)
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        receipt = read_json('files/diagnostics/debug_request_' + key + '.json')
        if receipt:
            if receipt.get('state') != 'accepted':
                raise RuntimeError(str(receipt))
            if operation != 'comic':
                return receipt
            report = read_json('files/diagnostics/comic_' + key + '.json')
            if report is not None:
                return report
        time.sleep(.15)
    raise TimeoutError(operation + ' diagnostic acknowledgement')


def snapshot():
    return command('comic', {'step': 'status'})


def save(name, result):
    (OUTPUT / (name + '.json')).write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')


def wait_until(predicate, seconds=90):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        result = snapshot()
        if predicate(result):
            return result
        time.sleep(.5)
    save('timeout', result)
    raise TimeoutError('Comic state; see timeout.json')


def selected(result):
    for page in result.get('native', {}).get('pages', []):
        for block in page.get('blocks', []):
            if block.get('eligible'):
                yield page, block


def hover(page, block, result, milliseconds=6000):
    left, top, right, bottom = block['hit_rect']
    row = len(block['hit_rows']) // 2
    lo, hi = block['hit_rows'][row]
    x = (lo + hi) / 2 / page['page_size'][0]
    y = (top + row + .5) / page['page_size'][1]
    rx, ry, rw, rh = result['rects'][int(page['page'])]
    return command('comic', {'step': 'hover', 'x': rx + rw*x, 'y': ry + rh*y, 'ms': milliseconds})


def run_pages():
    samples = json.loads((ROOT / 'build/output/comic-ocr-20261024/samples.json').read_text(encoding='utf-8'))
    folder = '/sdcard/Pictures/Thru3D-comic-test-20261025'
    shell('mkdir', '-p', folder)
    for sample in samples:
        adb('push', sample['path'], folder + '/' + sample['id'] + '.png')
    command('comic', {'step':'options', 'options':{'comic_enabled': True, 'comic_voice':'Xiaoyu', 'comic_language':'auto', 'comic_volume':75}})
    results = []
    for sample in samples:
        start = time.monotonic()
        command('photo_open', extra=['--es','folder',folder,'--es','name',sample['id']+'.png','--ei','layout','0'])
        command('hide_menus')
        result = wait_until(lambda r: not r['photo_loading'] and r['state'] in ['ready','no_dialogue','unavailable'], 90)
        result['page_open_to_ready_ms'] = round((time.monotonic()-start)*1000)
        result['sample'] = sample['id']
        save(sample['id'], result)
        results.append(result)
        print(json.dumps({'sample':sample['id'], 'state':result['state'], 'eligible':len(list(selected(result))), 'ms':result['page_open_to_ready_ms']}), flush=True)
    save('pages', results)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('operation', choices=['status','command','pages'])
    parser.add_argument('--params', default='{}')
    parser.add_argument('--name', default='status')
    args = parser.parse_args()
    if args.operation == 'pages':
        run_pages()
    else:
        result = snapshot() if args.operation == 'status' else command('comic', json.loads(args.params))
        save(args.name, result)
        print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
