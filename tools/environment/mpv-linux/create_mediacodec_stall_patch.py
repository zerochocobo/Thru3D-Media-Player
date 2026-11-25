"""Generate 0009-ffmpeg-mediacodec-stall.patch on the priority (0007) patched mediacodecdec.c.

mediacodec_receive_frame() retries forever while MediaCodec holds every input buffer and returns no
frame; before the first frame it polls with a zero timeout. It runs on the caller's thread, which for
MPV (no vd-queue) is the core thread, so a decoder that never returns a frame freezes the whole
player: synchronous client calls, track switches and mpv_terminate_destroy all wait on it. Quest
reports show exactly that (a source that never shows its first frame and never finishes closing,
holding the layer Surface so later videos fail too). A stalled-range experiment ruled out network
reads as the cause (research/smb_open_stall).

After 3 s with every input buffer queued and no frame, the decoder now reports an error and keeps
failing at once. MPV counts three hardware decoding errors and falls back to the next decoding method,
so the core returns to its loop and the source plays in software or fails and closes normally.

THRU3D_MEDIACODEC_EMULATE_STALL (Debug device probes only, set by the player) makes the decoder
never take an output buffer, so the codec fills up and this path can be exercised on demand.
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
    rep('''#include "libavutil/pixfmt.h"
''', '''#include "libavutil/pixfmt.h"
#include "libavutil/time.h"
''')
    rep('''    QuestDoviContext quest_dovi;
} MediaCodecContext;
''', '''    QuestDoviContext quest_dovi;
    // Thru3D patch 0009: the decoder held every input buffer without a frame past the limit.
    int quest_stalled;
    int quest_emulate_stall;
} MediaCodecContext;

// Thru3D patch 0009: the feed loop in mediacodec_receive_frame() runs on the caller's thread (MPV's
// core). A decoder that holds every input buffer and never returns a frame would block it for good.
#define QUEST_FEED_STALL_US INT64_C(3000000)
''')
    rep('''    MediaCodecContext *s = avctx->priv_data;
    int ret = mediacodec_decode_init_once(avctx);
''', '''    MediaCodecContext *s = avctx->priv_data;
    int ret = mediacodec_decode_init_once(avctx);
    // Device probes only (Debug builds set it): never take an output buffer, so the codec fills up.
    s->quest_emulate_stall = getenv("THRU3D_MEDIACODEC_EMULATE_STALL") != NULL;
''')
    rep('''    MediaCodecContext *s = avctx->priv_data;
    int ret;
    ssize_t index;

    /* In delay_flush mode, wait until the user has released or rendered
       all retained frames. */
    if (s->delay_flush && ff_mediacodec_dec_is_flushing(avctx, s->ctx)) {
        if (!ff_mediacodec_dec_flush(avctx, s->ctx)) {
            return AVERROR(EAGAIN);
        }
    }

    /* poll for new frame */
    ret = quest_mediacodec_receive(avctx, s, frame, false);
''', '''    MediaCodecContext *s = avctx->priv_data;
    int ret;
    ssize_t index;
    int64_t stall_start = 0;

    if (s->quest_stalled)
        return AVERROR_EXTERNAL;

    /* In delay_flush mode, wait until the user has released or rendered
       all retained frames. */
    if (s->delay_flush && ff_mediacodec_dec_is_flushing(avctx, s->ctx)) {
        if (!ff_mediacodec_dec_flush(avctx, s->ctx)) {
            return AVERROR(EAGAIN);
        }
    }

    /* poll for new frame */
    ret = s->quest_emulate_stall ? AVERROR(EAGAIN) : quest_mediacodec_receive(avctx, s, frame, false);
''')
    rep('''                /* no space, block for an output frame to appear */
                ret = quest_mediacodec_receive(avctx, s, frame, true);
                /* Try again if both input port and output port return EAGAIN.
                 * If no data is consumed and no frame in output, it can make
                 * both avcodec_send_packet() and avcodec_receive_frame()
                 * return EAGAIN, which violate the design.
                 */
                if (ff_AMediaCodec_infoTryAgainLater(s->ctx->codec, index) &&
                    ret == AVERROR(EAGAIN))
                    continue;
                return ret;
''', '''                /* no space, block for an output frame to appear */
                ret = s->quest_emulate_stall ? AVERROR(EAGAIN) : quest_mediacodec_receive(avctx, s, frame, true);
                /* Try again if both input port and output port return EAGAIN.
                 * If no data is consumed and no frame in output, it can make
                 * both avcodec_send_packet() and avcodec_receive_frame()
                 * return EAGAIN, which violate the design.
                 */
                if (ff_AMediaCodec_infoTryAgainLater(s->ctx->codec, index) &&
                    ret == AVERROR(EAGAIN)) {
                    int64_t now = av_gettime_relative();
                    if (!stall_start) {
                        stall_start = now;
                    } else if (now - stall_start > QUEST_FEED_STALL_US) {
                        av_log(avctx, AV_LOG_ERROR, "MediaCodec returned no frame for %" PRId64 " ms "
                               "with every input buffer queued; giving up on this decoder\\n",
                               (now - stall_start) / 1000);
                        s->quest_stalled = 1;
                        return AVERROR_EXTERNAL;
                    }
                    continue;
                }
                return ret;
''')
    return text


def main():
    ffmpeg = Path(sys.argv[1]) # Explicit pinned FFmpeg source directory required.
    priority = json.loads((DIRECTORY/'mediacodec-priority-manifest.json').read_text())
    source = (ffmpeg/NAME).read_bytes()
    if sha_bytes(source) != priority['patched_files_sha256'][NAME]:
        raise ValueError('mediacodecdec.c is not the priority (0007) patched base')
    before = source.decode()
    after = edit(before)
    patch = ''.join(difflib.unified_diff(before.splitlines(True), after.splitlines(True),
                                         'a/' + NAME, 'b/' + NAME, n=3))
    patch_path = DIRECTORY/'0009-ffmpeg-mediacodec-stall.patch'
    patch_path.write_text(patch, newline='\n')
    subprocess.run(['git', 'apply', '--check', str(patch_path)], cwd=ffmpeg, check=True)
    record = {
        'purpose': 'Bound the MediaCodec feed loop so a decoder returning no frame cannot freeze the MPV core',
        'priority_patch_sha256': priority['patch_sha256'],
        'base_files_sha256': {NAME: sha_bytes(source)},
        'patched_files_sha256': {NAME: sha_bytes(after.encode())},
        'patch_sha256': sha_bytes(patch_path.read_bytes()),
        'inputs_sha256': {'tools/environment/mpv-linux/create_mediacodec_stall_patch.py':
                          sha_bytes((ROOT/'tools/environment/mpv-linux/create_mediacodec_stall_patch.py').read_bytes())},
    }
    (DIRECTORY/'mediacodec-stall-manifest.json').write_text(json.dumps(record, indent=2) + '\n', newline='\n')
    print('0009 MediaCodec stall patch generated', record['patch_sha256'])


if __name__ == '__main__':
    main()
