"""Generate 0005-mpv-aaudio-clock.patch from the live-capture ao_aaudio.c.

After a flush (every seek), Quest 3 AAudio can keep returning AAUDIO_ERROR_INVALID_STATE from
AAudioStream_getTimestamp while the stream plays on. ao_aaudio then keeps a stale presented
position, its reported delay grows by one second per second, the audio clock stops, and video
(synced to it) freezes while sound continues. The patch follows the frames the stream consumed
whenever no timestamp is available, offset by the gap last measured from a real one.
"""
import difflib
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
DIRECTORY = ROOT/'native/mpv/patches'
NAME = 'audio/out/ao_aaudio.c'


def sha_bytes(data):
    return hashlib.sha256(data).hexdigest()


def edit(text):
    def rep(old, new):
        nonlocal text
        if text.count(old) != 1:
            raise ValueError('Unexpected ao_aaudio.c layout: ' + old.splitlines()[0])
        text = text.replace(old, new)
    rep("    int64_t presented;\n    int64_t discarded;\n",
        "    int64_t presented;\n    int64_t discarded;\n"
        "    // Frames read by the stream but not yet presented, from the last valid timestamp.\n"
        "    int64_t read_gap;\n")
    rep("""    int64_t written = p->AAudioStream_getFramesWritten(stream);

    if ((result = p->AAudioStream_getTimestamp(stream, CLOCK_MONOTONIC, &presented, &present_time)) < 0) {
        MP_TRACE(ao, "AAudioStream_getTimestamp() returned %s\\n",
                 p->AAudio_convertResultToText(result));
        presented = p->presented;
    } else {
        p->presented = presented;
    }
""", """    int64_t written = p->AAudioStream_getFramesWritten(stream);
    // AAudio counts flushed frames as read; the timestamp position excludes them.
    int64_t read = p->AAudioStream_getFramesRead(stream);

    if ((result = p->AAudioStream_getTimestamp(stream, CLOCK_MONOTONIC, &presented, &present_time)) < 0) {
        MP_TRACE(ao, "AAudioStream_getTimestamp() returned %s\\n",
                 p->AAudio_convertResultToText(result));
        // Some devices never report a timestamp again after a flush while the stream keeps
        // playing. A stale position would grow the delay with every write and stop the audio
        // clock (video then freezes on it). Follow the frames the stream consumed instead.
        presented = MPMAX(p->presented, read - p->discarded - p->read_gap);
        struct timespec now;
        clock_gettime(CLOCK_MONOTONIC, &now);
        present_time = now.tv_sec * INT64_C(1000000000) + now.tv_nsec;
    } else {
        p->read_gap = MPCLAMP(read - (presented + p->discarded), 0, ao->samplerate);
    }
    p->presented = presented;
""")
    # The recording watermark: an estimated position keeps a recording's audio flowing too.
    rep("""    // Only the hardware presentation watermark releases submitted samples to a recording.
    if (result >= 0)
        mpv_quest_capture_audio_feed(""", """    // Only the presentation watermark releases submitted samples to a recording.
    mpv_quest_capture_audio_feed(""")
    rep("""            ao->samplerate, ao->channels.num, capture_format,
            presented + p->discarded, present_time);
""", """        ao->samplerate, ao->channels.num, capture_format,
        presented + p->discarded, present_time);
""")
    return text


def main():
    if len(sys.argv) != 2: raise SystemExit('Usage: create_aaudio_patch.py <live-capture-patched-mpv-source>')
    mpv = Path(sys.argv[1])
    capture = json.loads((DIRECTORY/'live-capture-manifest.json').read_text())
    source = (mpv/NAME).read_bytes()
    if sha_bytes(source) != capture['patched_files_sha256'][NAME]:
        raise ValueError('ao_aaudio.c is not the live-capture patched base')
    before = source.decode()
    after = edit(before)
    patch = ''.join(difflib.unified_diff(before.splitlines(True), after.splitlines(True),
                                         'a/' + NAME, 'b/' + NAME, n=3))
    patch_path = DIRECTORY/'0005-mpv-aaudio-clock.patch'
    patch_path.write_text(patch, newline='\n')
    subprocess.run(['git', 'apply', '--check', str(patch_path)], cwd=mpv, check=True)
    record = {
        'purpose': 'AAudio clock without timestamps after a flush (seek freeze: audio plays, video frozen)',
        'capture_patch_sha256': capture['patch_sha256'],
        'base_files_sha256': {NAME: sha_bytes(source)},
        'patched_files_sha256': {NAME: sha_bytes(after.encode())},
        'patch_sha256': sha_bytes(patch_path.read_bytes()),
        'inputs_sha256': {'tools/environment/mpv-linux/create_aaudio_patch.py':
                          sha_bytes((ROOT/'tools/environment/mpv-linux/create_aaudio_patch.py').read_bytes())},
    }
    (DIRECTORY/'aaudio-clock-manifest.json').write_text(json.dumps(record, indent=2) + '\n', newline='\n')
    print('0005 AAudio clock patch generated', record['patch_sha256'])


if __name__ == '__main__':
    main()
