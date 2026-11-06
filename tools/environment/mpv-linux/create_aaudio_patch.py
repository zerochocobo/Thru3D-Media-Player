"""Generate 0005-mpv-aaudio-clock.patch from the live-capture ao_aaudio.c.

After a flush (every seek), Quest 3 AAudio can keep returning AAUDIO_ERROR_INVALID_STATE from
AAudioStream_getTimestamp while the stream plays on. ao_aaudio then keeps a stale presented
position, its reported delay grows by one second per second, the audio clock stops, and video
(synced to it) freezes while sound continues. The patch follows the frames the stream consumed
whenever no timestamp is available, offset by the gap last measured from a real one.

A timestamp is the position at present_time, not now. Quest v29 publishes it only every 50 ms, so
using the position alone made the delay a 68-114 ms sawtooth that jumped up to 50 ms; video synced
to that clock was released late or in pairs and dropped (41 latched frames/s for 60 fps). The
position is projected to the current time: 64.0-65.6 ms in the same measurement.

reset() (seeks, track changes and the end of every file) waited without limit for the stream to
leave a transitional state. On Quest 3 a stream whose start the system mixer never took stayed in
STARTING: closing that file blocked the playback core in reset(), mpv_terminate_destroy waited on
it forever, and the source never released its player slot ("source capacity exhausted"). Each
wait is now bounded; a stream that does not settle is rebuilt through the existing reload path.
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
        "    int64_t read_gap;\n"
        "    // CLOCK_MONOTONIC time of the last start or resume request.\n"
        "    int64_t started_ns;\n")
    rep("    p->discarded = p->AAudioStream_getFramesWritten(p->stream) - p->presented;\n",
        "    p->discarded = p->AAudioStream_getFramesWritten(p->stream) - p->presented;\n"
        "    p->started_ns = monotonic_ns();\n")
    rep("    aaudio_result_t result = paused\n",
        "    if (!paused)\n        p->started_ns = monotonic_ns();\n\n"
        "    aaudio_result_t result = paused\n")
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

    result = p->AAudioStream_getTimestamp(stream, CLOCK_MONOTONIC, &presented, &present_time);
    int64_t now_ns = monotonic_ns();
    if (result < 0) {
        MP_TRACE(ao, "AAudioStream_getTimestamp() returned %s\\n",
                 p->AAudio_convertResultToText(result));
        // Some devices never report a timestamp again after a flush while the stream keeps
        // playing. A stale position would grow the delay with every write and stop the audio
        // clock (video then freezes on it). Follow the frames the stream consumed instead.
        presented = MPMAX(p->presented, read - p->discarded - p->read_gap);
        present_time = now_ns;
    }
    p->presented = presented;

    // The position belongs to present_time, which can be tens of ms old: project it to now, or
    // the delay below is a sawtooth at the timestamp's update rate and video judders on it. Only a
    // timestamp taken since this stream (re)started and close to now is projected: an older one
    // describes a stream that was not moving, and a far-off one is not a usable clock reading.
    int64_t age = now_ns - present_time;
    if (present_time < p->started_ns || llabs(age) > MAX_TIMESTAMP_PROJECTION_NS)
        age = 0;
    int64_t played = MPMIN(presented + age * ao->samplerate / INT64_C(1000000000), written - p->discarded);
    if (result >= 0)
        p->read_gap = MPCLAMP(read - (played + p->discarded), 0, ao->samplerate);
""")
    rep("    end_time += MP_TIME_S_TO_NS(written - (presented + p->discarded)) / ao->samplerate;\n",
        "    end_time += MP_TIME_S_TO_NS(written - (played + p->discarded)) / ao->samplerate;\n")
    rep("static aaudio_data_callback_result_t data_callback(AAudioStream *stream, void *context,\n",
        "#define MAX_TIMESTAMP_PROJECTION_NS INT64_C(200000000)\n\n"
        "static int64_t monotonic_ns(void)\n{\n"
        "    struct timespec now;\n"
        "    clock_gettime(CLOCK_MONOTONIC, &now);\n"
        "    return now.tv_sec * INT64_C(1000000000) + now.tv_nsec;\n}\n\n"
        "static aaudio_data_callback_result_t data_callback(AAudioStream *stream, void *context,\n")
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
    # A stream stuck in a transitional state must not block the playback core (or its teardown).
    rep("static void reset(struct ao *ao)\n{\n",
        "// Quest AAudio can stay in a transitional state (STARTING seen) indefinitely: past this\n"
        "// the stream is rebuilt instead of blocking the playback core and its teardown.\n"
        "#define STATE_CHANGE_TIMEOUT_NS INT64_C(500000000)\n\n"
        "static void reset(struct ao *ao)\n{\n")
    rep("                                state, &state, INT64_MAX)) < 0) {\n",
        "                                state, &state, STATE_CHANGE_TIMEOUT_NS)) < 0) {\n")
    rep("                            AAUDIO_STREAM_STATE_PAUSING, &state, INT64_MAX)) < 0) {\n",
        "                            AAUDIO_STREAM_STATE_PAUSING, &state, STATE_CHANGE_TIMEOUT_NS)) < 0) {\n")
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
        'purpose': 'AAudio clock without timestamps after a flush (seek freeze: audio plays, video frozen); '
                   'bounded reset waits (a stream stuck in STARTING blocked teardown and leaked the player slot); '
                   'timestamp position projected to now (Quest v29 updates it every 50 ms: clock sawtooth, video judder)',
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
