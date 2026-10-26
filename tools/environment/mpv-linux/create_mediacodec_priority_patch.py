"""Generate 0007-ffmpeg-mediacodec-priority.patch on the Dolby (0002) patched mediacodecdec.c.

FFmpeg's MediaCodec video decoder can pass KEY_OPERATING_RATE but has no KEY_PRIORITY. ExoPlayer
based players (Skybox, Pigasus) configure decoders as real time (priority 0) at the stream's frame
rate; a Quest 3 tester saw 8K60 stutter only in a clip's highest-bitrate motion that those players
show smoothly. The new "priority" option (-1 unspecified, 0 real time, 1 best effort) is set only
when given, so other callers keep FFmpeg's behaviour.

A decoder may refuse a configuration it cannot sustain (Android lets configure() fail for an
operating rate or real-time priority beyond its capacity), e.g. 8K60 on Quest 2 / PICO Neo3. Then
initialization is retried once without both keys, as ExoPlayer does, so playback never depends on
them.
"""
import difflib
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
DIRECTORY = ROOT/'native/mpv/patches'
NAME = 'libavcodec/mediacodecdec.c'


def sha_bytes(data):
    return hashlib.sha256(data).hexdigest()


def edit(text):
    def rep(old, new):
        nonlocal text
        if text.count(old) != 1:
            raise ValueError('Unexpected mediacodecdec.c layout: ' + old.splitlines()[0])
        text = text.replace(old, new)
    rep('''    // Ref. MediaFormat KEY_OPERATING_RATE
    int operating_rate;
''', '''    // Ref. MediaFormat KEY_OPERATING_RATE
    int operating_rate;
    // Ref. MediaFormat KEY_PRIORITY (Thru3D patch 0007): -1 unspecified, 0 real time, 1 best effort
    int priority;
''')
    rep('''    if (s->operating_rate > 0)
        ff_AMediaFormat_setInt32(format, "operating-rate", s->operating_rate);
''', '''    if (s->operating_rate > 0)
        ff_AMediaFormat_setInt32(format, "operating-rate", s->operating_rate);
    if (s->priority >= 0)
        ff_AMediaFormat_setInt32(format, "priority", s->priority);
''')
    rep('''    { "operating_rate", "The desired operating rate that the codec will need to operate at, zero for unspecified",
            OFFSET(operating_rate), AV_OPT_TYPE_INT, {.i64 = 0}, 0, INT_MAX, VD },
    { NULL }
};
''', '''    { "operating_rate", "The desired operating rate that the codec will need to operate at, zero for unspecified",
            OFFSET(operating_rate), AV_OPT_TYPE_INT, {.i64 = 0}, 0, INT_MAX, VD },
    { "priority", "Codec priority: 0 real time, 1 best effort, -1 unspecified",
            OFFSET(priority), AV_OPT_TYPE_INT, {.i64 = -1}, -1, 1, VD },
    { NULL }
};
''')
    rep('''static av_cold int mediacodec_decode_init(AVCodecContext *avctx)
{
''', '''static av_cold int mediacodec_decode_init_once(AVCodecContext *avctx)
{
''')
    rep('''#include <stdint.h>
#include <string.h>
''', '''#include <stdint.h>
#include <stdlib.h>
#include <string.h>
''')
    rep('''    if ((ret = ff_mediacodec_dec_init(avctx, s->ctx, codec_mime, format)) < 0) {
        s->ctx = NULL;
        goto done;
    }
''', '''    if (getenv("THRU3D_MEDIACODEC_REJECT_HINTS") && (s->operating_rate > 0 || s->priority >= 0)) {
        // Device probes only (Debug builds set it): emulate a decoder refusing the hints, with
        // the state a failed ff_mediacodec_dec_init() leaves (its context already released).
        av_freep(&s->ctx);
        ret = AVERROR_EXTERNAL;
        goto done;
    }
    if ((ret = ff_mediacodec_dec_init(avctx, s->ctx, codec_mime, format)) < 0) {
        s->ctx = NULL;
        goto done;
    }
''')
    rep('''static int quest_mediacodec_receive(AVCodecContext *avctx,
''', '''// A decoder may refuse an operating rate or real-time priority it cannot sustain; then retry
// once without them (as ExoPlayer does), so playback never depends on these hints.
static av_cold int mediacodec_decode_init(AVCodecContext *avctx)
{
    MediaCodecContext *s = avctx->priv_data;
    int ret = mediacodec_decode_init_once(avctx);
    if (ret < 0 && avctx->codec_type == AVMEDIA_TYPE_VIDEO && (s->operating_rate > 0 || s->priority >= 0)) {
        av_log(avctx, AV_LOG_WARNING, "MediaCodec rejected operating rate %d / priority %d; "
               "retrying without them\\n", s->operating_rate, s->priority);
        s->operating_rate = 0;
        s->priority = -1;
        ret = mediacodec_decode_init_once(avctx);
    }
    return ret;
}

static int quest_mediacodec_receive(AVCodecContext *avctx,
''')
    return text


def main():
    ffmpeg = Path(sys.argv[1]) # Explicit pinned FFmpeg source directory required.
    dovi = json.loads((DIRECTORY/'dovi-rpu-manifest.json').read_text())
    source = (ffmpeg/NAME).read_bytes()
    if sha_bytes(source) != dovi['patched_files_sha256'][NAME]:
        raise ValueError('mediacodecdec.c is not the Dolby (0002) patched base')
    before = source.decode()
    after = edit(before)
    patch = ''.join(difflib.unified_diff(before.splitlines(True), after.splitlines(True),
                                         'a/' + NAME, 'b/' + NAME, n=3))
    patch_path = DIRECTORY/'0007-ffmpeg-mediacodec-priority.patch'
    patch_path.write_text(patch, newline='\n')
    subprocess.run(['git', 'apply', '--check', str(patch_path)], cwd=ffmpeg, check=True)
    record = {
        'purpose': 'MediaCodec KEY_PRIORITY option for real-time video decoding',
        'dovi_patch_sha256': dovi['patch_sha256'],
        'base_files_sha256': {NAME: sha_bytes(source)},
        'patched_files_sha256': {NAME: sha_bytes(after.encode())},
        'patch_sha256': sha_bytes(patch_path.read_bytes()),
        'inputs_sha256': {'tools/environment/mpv-linux/create_mediacodec_priority_patch.py':
                          sha_bytes((ROOT/'tools/environment/mpv-linux/create_mediacodec_priority_patch.py').read_bytes())},
    }
    (DIRECTORY/'mediacodec-priority-manifest.json').write_text(json.dumps(record, indent=2) + '\n', newline='\n')
    print('0007 MediaCodec priority patch generated', record['patch_sha256'])


if __name__ == '__main__':
    main()
