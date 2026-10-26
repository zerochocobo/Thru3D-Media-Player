"""Pinned Moonshine 0.1.5 integration fix: scope VAD state/environment to a stream.

Upstream intentionally retains a global SileroVad forever. That keeps ORT's
process Env alive after other clients release their counted ownership, breaking
global-pool initialization and allocator registration on their next load.
The detector already belongs to one TranscriberStream; give it unique ownership
so both the recurrent state and the ORT environment are released with that stream.
"""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

PIN = '234f60faa0eb388b01cdf7e60aca232af37aefda'
CHANGES = {
    'core/voice-activity-detector.h': (
        '29c313f9a6592ae1c291953ffac9058294a809792d9d33d11469e83a6062f0ba', [
            ('#include <string>', '#include <memory>\n#include <string>'),
            ('  // Raw pointer intentionally not deleted to avoid static destruction order\n  // issues\n  static SileroVad *silero_vad;',
             '  // Each stream owns its recurrent state and releases its ORT Env.\n  std::unique_ptr<SileroVad> silero_vad;'),
        ]),
    'core/voice-activity-detector.cpp': (
        '8fab332566ed5b69e279dd0d6ab82921d5024070a7bb9730e1d4a4b4e023118d', [
            ('// Intentionally leaked to avoid static destruction order issues with ONNX\n// Runtime\nSileroVad *VoiceActivityDetector::silero_vad = nullptr;\n\n', ''),
            ('  // We only want a single, global instance of silero_vad\n  if (VoiceActivityDetector::silero_vad == nullptr) {\n    VoiceActivityDetector::silero_vad = new SileroVad();\n  }',
             '  silero_vad = std::make_unique<SileroVad>();'),
        ]),
}


def main():
    root = Path(sys.argv[1])
    revision = subprocess.check_output(['git', '-C', root, 'rev-parse', 'HEAD'], text=True).strip()
    if revision != PIN:
        raise RuntimeError('Unreviewed Moonshine revision')
    digests = {}
    for name, (expected, replacements) in CHANGES.items():
        original = subprocess.check_output(['git', '-C', root, 'show', 'HEAD:' + name]).decode().replace('\r\n', '\n')
        if hashlib.sha256(original.encode()).hexdigest() != expected:
            raise RuntimeError('Moonshine base source digest differs: ' + name)
        patched = original
        for before, after in replacements:
            if patched.count(before) != 1:
                raise RuntimeError('Ambiguous Moonshine patch: ' + name)
            patched = patched.replace(before, after)
        path = root / name
        current = path.read_text(encoding='utf-8')
        if current not in (original, patched):
            raise RuntimeError('Unreviewed local Moonshine edit: ' + name)
        if current != patched:
            path.write_text(patched, encoding='utf-8', newline='\n')
        digests[name] = hashlib.sha256(path.read_bytes()).hexdigest()
    print(json.dumps(digests))


if __name__ == '__main__':
    main()
