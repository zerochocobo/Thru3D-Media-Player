"""Check tracked public files for excluded assets, private paths and credentials."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import subprocess

FORBIDDEN_PARTS = {'.git', '.cache', '.venv', '.godot', '.gradle', '.cxx', '__pycache__', 'prompt', 'artifacts', 'build', 'tmp', 'backups', 'keystore', 'releases', 'credentials', 'research'}
FORBIDDEN_SUFFIXES = {'.glb', '.data', '.model', '.npz', '.npy', '.gguf', '.tflite', '.ort', '.onnx', '.mnn', '.pt', '.pth', '.ckpt', '.safetensors', '.bin', '.param', '.apk', '.aar', '.so', '.keystore', '.jks', '.p12', '.pfx', '.hdr', '.log', '.zip', '.tgz', '.tar', '.gz', '.bz2', '.xz', '.7z', '.rar', '.key', '.pem'}
# MIT-licensed glTF mesh buffers, not inference weights. Only these exact bytes qualify.
HAND_BUFFER_PINS = {
    'app/godot/models/hands/LeftHandHumanoid.bin': '05f96e5aae870c8f2fde8a1fea337b060c7fde3e659b124a5ed979f0ffa1222a',
    'app/godot/models/hands/RightHandHumanoid.bin': '89468a6868afbd6a9d5e545e7fdd5dadd7d7abab6d4389d8acc14a7804901e41',
}
FONT_PINS = {
    'app/godot/assets/fonts/cjk-brackets.otf': 'e63dc18bc1615fcdf509de72a18799271d5f66959296cd6bf9caa20d5d6dd7fa',
}
# Reviewed upstream source bundles required by native/usb, never signing/data backups.
USB_SOURCE_PINS = {
    'third_party/usb/fatfs-r016.zip': '99f7dc1f7e095356e4a9e3dbe29959090d8b948afe2bbc5441e52fdf4b85449e',
    'third_party/usb/ntfs-3g-2026.9.28.tgz': '350d9415c59f7c3fa74e23985ad2d56423c6a168337368f672e2e362d8f295c8',
}
# Reviewed image-decoder source archives, bounded to these exact paths and bytes.
IMAGE_SOURCE_PINS = {'third_party/tiff/libjpeg-turbo-3.1.2.tar.gz': '560f6338b547544c4f9721b18d8b87685d433ec78b3c644c70d77adad22c55e6', 'third_party/tiff/tiff-4.7.2.tar.xz': '4996f0c4f93094719b1ca5c6279b20e588773ba8a247533e486416fb662ddb88', 'third_party/openexr/imath-3.1.12.tar.gz': '8a1bc258f3149b5729c2f4f8ffd337c0e57f09096e4ba9784329f40c4a9035da', 'third_party/openexr/libdeflate-1.24.tar.gz': 'ad8d3723d0065c4723ab738be9723f2ff1cb0f1571e8bfcf0301ff9661f475e8', 'third_party/openexr/openexr-3.3.14.tar.gz': '54d931aaf50402c21ab7a0de9b390f91586d729a603455e1fe402dd3783426e0'}
IMAGE_SOURCE_NOTICES = ['third_party/tiff/LIBJPEG-TURBO-IJG.txt', 'third_party/tiff/LICENSE.md', 'third_party/tiff/LIBJPEG-TURBO-LICENSE.md', 'third_party/openexr/LICENSE.md', 'third_party/openexr/IMATH-LICENSE.md', 'third_party/openexr/LIBDEFLATE-LICENSE.txt']
# Exact project-generated effects; arbitrary audio and recordings remain excluded.
PUZZLE_AUDIO_PINS = {'app/godot/audio/puzzle/rotate.wav': '2dab090f79861e99cae55434cda831922a7d0c0ac5cf94de8fc9c2c0249b5f06', 'app/godot/audio/puzzle/snap.wav': 'afe5db969224020aba863a236c86de92ecbfa0e1ec5a16d70a3caf0925191ed4', 'app/godot/audio/puzzle/success.wav': '65d1e4934a74344671febe19660979092eae2824ecda672eccf6711628d57b49', 'app/godot/audio/puzzle/launch.wav': '9672c6b35d2222fa66fcbea5598d4e68661488e63503d348a18c42ff2df530e9', 'app/godot/audio/puzzle/burst.wav': '0c1517ce01ebbca7b3ec5db7e4deaf408169bf61ee9ee79b7a698cfa3010fab4'}
PATTERNS = {
    'private machine path': re.compile(r'(?i)(?:[CG]:[/\\]+(?:Users[/\\]+dennis|devtools|GIT|code[/\\]+VRPassthroughPlayer)|/mnt/' + r'g/|/opt/' + r'quest-mpv)'),
    'GitHub credential': re.compile(r'\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{50,})\b'),
    'AWS access key': re.compile(r'\b(?:AKIA|ASIA)[A-Z0-9]{16}\b'),
    'hardcoded signing password': re.compile(r'''(?im)(?:THRU3D_SIGNING_PASSWORD|GODOT_ANDROID_KEYSTORE_(?:DEBUG|RELEASE)_PASSWORD)\s*(?:=|:)\s*['"][^'"\r\n]+['"]|-(?:storepass|keypass)\s+['"][^'"$\r\n]+['"]'''),
    'private signing key': re.compile(r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'),
    'private handover link': re.compile(r'(?i)(?:HANDOVER_\d{8}|docs/(?:store|archive|branding)/)'),
}


def check_files(files):
    errors = []
    for name, data in files.items():
        path = PurePosixPath(name)
        if path.is_absolute() or '..' in path.parts or '\\' in name or ':' in name:
            errors.append(f'{name}: unsafe path')
        if path.name.lower() in {'voice.json', 'voice.new', 'reference.wav'} or ('narration' in path.parts and 'voices' in path.parts) or data.startswith(b'T3VOICE1'):
            errors.append(f'{name}: excluded personal voice data')
        if name.startswith('app/godot/environments/grand_cinema/'):
            errors.append(f'{name}: excluded generated scene model')
        approved_mesh = name in HAND_BUFFER_PINS
        approved_font = name in FONT_PINS
        approved_audio = name in PUZZLE_AUDIO_PINS
        if approved_audio and hashlib.sha256(data).hexdigest() != PUZZLE_AUDIO_PINS[name]:
            errors.append(f'{name}: puzzle sound differs from reviewed procedural bytes')
        if path.suffix.lower() in {'.wav', '.ogg', '.mp3', '.flac', '.dts'} and not approved_audio:
            errors.append(f'{name}: unreviewed sound recording')
        source_pins = {**USB_SOURCE_PINS, **IMAGE_SOURCE_PINS}
        approved_source = name in source_pins
        if approved_source and hashlib.sha256(data).hexdigest() != source_pins[name]:
            errors.append(f'{name}: source archive differs from reviewed upstream bytes')
        if approved_font and (len(data) != 6844 or hashlib.sha256(data).hexdigest() != FONT_PINS[name]):
            errors.append(f'{name}: font differs from reviewed OFL subset')
        if approved_mesh and (len(data) != 38584 or hashlib.sha256(data).hexdigest() != HAND_BUFFER_PINS[name]):
            errors.append(f'{name}: hand mesh differs from reviewed MIT asset')
        if FORBIDDEN_PARTS.intersection(part.lower() for part in path.parts) or (path.suffix.lower() in FORBIDDEN_SUFFIXES and not approved_mesh and not approved_source):
            errors.append(f'{name}: excluded directory or binary asset')
        if name.startswith(('models/narration/', 'android/player-plugin/src/main/assets/narration/')):
            errors.append(f'{name}: excluded narration payload cache')
        if name.startswith(tuple('docs/' + item + '/' for item in ('store', 'branding', 'archive'))) or name.startswith('tools/record_'):
            errors.append(f'{name}: private development or promotion content')
        if name.endswith('store_capture_debug.gd') or 'local.properties' == path.name:
            errors.append(f'{name}: local-only configuration/tool')
        if path.name.lower() in {'signing-identities.json', 'thru3d-signing.json', '.env'}:
            errors.append(f'{name}: excluded signing identity or local credential configuration')
        if path.name.lower().startswith(('readme', 'changelog')) and name not in {'README.md', 'README.zh-CN.md', 'CHANGELOG.md', 'CHANGELOG.zh-CN.md', 'third_party/README.md'}:
            errors.append(f'{name}: internal documentation excluded')
        if len(data) > 25 * 1024 * 1024:
            errors.append(f'{name}: unexpected file over 25 MiB')
        try:
            value = data.decode('utf-8')
        except UnicodeDecodeError:
            if path.suffix.lower() not in {'.png', '.jpg', '.jpeg', '.webp', '.mp4', '.jar'} and not approved_mesh and not approved_font and not approved_source and not approved_audio:
                errors.append(f'{name}: unreviewed binary type')
            continue
        for label, pattern in PATTERNS.items():
            if pattern.search(value):
                errors.append(f'{name}: {label}')  # Never print the matched credential.
    if PUZZLE_AUDIO_PINS.keys() & files.keys() and 'tools/Generate-PuzzleSounds.py' not in files:
        errors.append('tools/Generate-PuzzleSounds.py: puzzle sound generator missing')
    if USB_SOURCE_PINS.keys() & files.keys():
        for name in ('LICENSE.fatfs', 'LICENSE.ntfs-3g', 'LICENSE.libaums', 'source-lock.json'):
            asset = 'third_party/usb/' + name
            if asset not in files:
                errors.append(f'{asset}: USB source license/lock missing')
        try:
            lock = json.loads(files.get('third_party/usb/source-lock.json', b'{}'))
            for name, component in [('third_party/usb/fatfs-r016.zip', 'fatfs'), ('third_party/usb/ntfs-3g-2026.9.28.tgz', 'ntfs-3g')]:
                if name in files and lock[component]['sha256'] != USB_SOURCE_PINS[name]:
                    errors.append(f'{name}: USB source lock differs from reviewed pin')
        except (ValueError, KeyError, TypeError):
            errors.append('third_party/usb/source-lock.json: invalid USB source lock')
    if IMAGE_SOURCE_PINS.keys() & files.keys():
        for name in IMAGE_SOURCE_NOTICES:
            if name not in files:
                errors.append(f'{name}: image source license missing')
        for name, pin in IMAGE_SOURCE_PINS.items():
            if name not in files:
                continue
            cmake = 'native/tiff/CMakeLists.txt' if '/tiff/' in name else 'native/hdr/CMakeLists.txt'
            source = files.get(cmake, b'').decode('utf-8', errors='replace')
            if pin not in source or PurePosixPath(name).name not in source:
                errors.append(f'{name}: image source CMake pin missing or mismatched')
    if FONT_PINS.keys() & files.keys():
        for name in ('LICENSE.txt', 'NOTICE.txt'):
            asset = 'app/godot/assets/fonts/' + name
            if asset not in files:
                errors.append(f'{asset}: font license/source notice missing')
    if HAND_BUFFER_PINS.keys() & files.keys():
        for name in ('LICENSE.txt', 'NOTICE.txt', 'hand.png', 'LeftHandHumanoid.gltf', 'RightHandHumanoid.gltf'):
            asset = 'app/godot/models/hands/' + name
            if asset not in files:
                errors.append(f'{asset}: hand mesh dependency/notice missing')
        for buffer in HAND_BUFFER_PINS:
            gltf = str(PurePosixPath(buffer).with_suffix('.gltf'))
            if gltf in files:
                try:
                    declared = json.loads(files[gltf])['buffers']
                    if declared != [{'byteLength': 38584, 'uri': PurePosixPath(buffer).name}]:
                        errors.append(f'{gltf}: unexpected hand buffer reference')
                except (ValueError, KeyError, TypeError):
                    errors.append(f'{gltf}: invalid hand buffer contract')
    required = {'LICENSE', 'README.md', 'CHANGELOG.md', 'CHANGELOG.zh-CN.md', 'docs/BUILD.md', 'docs/MODELS.md', 'docs/LICENSING.md',
                'app/godot/project.godot', 'android/player-plugin/build.gradle', 'native/mpv/CMakeLists.txt'}
    errors.extend(f'{name}: required public file missing' for name in sorted(required - files.keys()))
    if 'LICENSE' in files and b'Version 3, 29 June 2007' not in files['LICENSE']:
        errors.append('LICENSE: expected complete GPL v3 text')
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    root = args.root.resolve()
    names = subprocess.check_output(['git', '-c', f'safe.directory={root.as_posix()}', '-C', str(root),
                                     'ls-files', '-z'], text=True).split('\0')
    files = {}
    for name in filter(None, names):
        path = root / name
        if path.is_symlink() or not path.is_file():
            raise SystemExit(f'{name}: tracked file is missing or redirected')
        files[name] = path.read_bytes()
    errors = check_files(files)
    if errors:
        raise SystemExit('\n'.join(errors))
    print(f'Public source boundary checks passed: {len(files)} tracked files')


if __name__ == '__main__':
    main()
