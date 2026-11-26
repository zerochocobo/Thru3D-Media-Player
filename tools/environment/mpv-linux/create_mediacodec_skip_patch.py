"""Generate 0010-ffmpeg-mediacodec-skip-nonref.patch on the stall (0009) patched mediacodecdec.c.

MPV asks a decoder to skip non-reference pictures (AVCodecContext.skip_frame = AVDISCARD_NONREF)
when video falls behind audio with --framedrop=decoder, and before the target of an exact seek.
FFmpeg's software decoders honour it; the MediaCodec wrapper ignores it and feeds every packet. A
decoder slower than the source (QIYU A091 and Quest 2: Snapdragon 865 class, about 48 fps at 8K,
given 8K 59.94 fps) then falls further behind for good: A/V drift grew past 20 s in a user log, MPV
dropped almost every decoded frame at the VO and about 4 frames a second reached the screen.

Now, while skip_frame asks for it, a packet whose pictures are all non-reference is not sent to
MediaCodec: HEVC sub-layer non-reference VCL types (TRAIL_N, TSA_N, STSA_N, RADL_N, RASL_N and the
reserved even types up to 14) in the highest temporal sub-layer of the stream's SPS, base layer only;
H.264 slices with nal_ref_idc 0. Nothing references these pictures, so the rest decode unchanged.
About a third of the pictures in typical 8K HEVC files are such, which brings 59.94 fps under 48.

Kept conservative: nothing is skipped until an SPS gave the sub-layer count, nor for packets with a
reference picture, enhancement layers (MV-HEVC), MVC or no VCL NAL at all.

THRU3D_MEDIACODEC_SKIP_NONREF (Debug device probes only, set by the player) skips such packets
always, so the effect can be checked on a decoder that keeps up anyway.
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
    rep('''    int quest_stalled;
    int quest_emulate_stall;
} MediaCodecContext;
''', '''    int quest_stalled;
    int quest_emulate_stall;
    // Thru3D patch 0010: non-reference pictures MPV asked to skip are not sent to MediaCodec.
    int quest_max_tid; // the SPS's highest temporal sub-layer, -1 until an SPS was seen
    int quest_force_skip;
    int64_t quest_skipped;
} MediaCodecContext;
''')
    rep('''#define QUEST_FEED_STALL_US INT64_C(3000000)
''', '''#define QUEST_FEED_STALL_US INT64_C(3000000)

// Thru3D patch 0010: the packet (one access unit, Annex B after the bitstream filter) holds only
// pictures nothing references, so it can be skipped when MPV asks for it. HEVC: sub-layer
// non-reference VCL types in the highest temporal sub-layer, base layer only. H.264: nal_ref_idc 0.
// A parameter set before the first slice updates the sub-layer count either way.
static int quest_nonref_packet(AVCodecContext *avctx, MediaCodecContext *s, const AVPacket *pkt, int scan_all)
{
    const uint8_t *p = pkt->data, *end = pkt->data + pkt->size;
    int hevc = avctx->codec_id == AV_CODEC_ID_HEVC, vcl = 0;
    if (!p || (!hevc && avctx->codec_id != AV_CODEC_ID_H264))
        return 0;
    while (end - p >= 4) {
        if (p[0] || p[1] || p[2] != 1) {
            p++;
            continue;
        }
        p += 3;
        if (hevc) {
            int type, layer, tid;
            if (end - p < 2)
                break;
            type = (p[0] >> 1) & 0x3f;
            layer = ((p[0] & 1) << 5) | (p[1] >> 3);
            tid = (p[1] & 7) - 1;
            if (layer)
                return 0;
            if (type == 33 && end - p >= 3)
                s->quest_max_tid = (p[2] >> 1) & 7;
            if (type < 32) {
                if (type > 14 || (type & 1) || s->quest_max_tid < 0 || tid != s->quest_max_tid)
                    return 0;
                vcl++;
                if (!scan_all)
                    return 1;
            }
        } else {
            int type = p[0] & 0x1f;
            if (type == 14 || type == 15 || type == 20)
                return 0;
            if (type >= 1 && type <= 5) {
                if (type == 5 || (p[0] & 0x60))
                    return 0;
                vcl++;
                if (!scan_all)
                    return 1;
            }
        }
    }
    return vcl > 0;
}

// Thru3D patch 0010: whether to drop this packet instead of sending it. Key frames are only read for
// their parameter sets; everything else is read only while skipping is asked for.
static int quest_skip_packet(AVCodecContext *avctx, MediaCodecContext *s, const AVPacket *pkt)
{
    if (avctx->codec_type != AVMEDIA_TYPE_VIDEO)
        return 0;
    if (avctx->codec_id == AV_CODEC_ID_HEVC && (pkt->flags & AV_PKT_FLAG_KEY)) {
        quest_nonref_packet(avctx, s, pkt, 0);
        return 0;
    }
    if (!s->quest_force_skip && avctx->skip_frame < AVDISCARD_NONREF)
        return 0;
    if (!quest_nonref_packet(avctx, s, pkt, 1))
        return 0;
    if (++s->quest_skipped == 1 || s->quest_skipped % 600 == 0)
        av_log(avctx, AV_LOG_INFO, "Thru3D skipped %" PRId64 " non-reference pictures\\n", s->quest_skipped);
    return 1;
}
''')
    rep('''    s->quest_emulate_stall = getenv("THRU3D_MEDIACODEC_EMULATE_STALL") != NULL;
''', '''    s->quest_emulate_stall = getenv("THRU3D_MEDIACODEC_EMULATE_STALL") != NULL;
    // Device probes only (Debug builds set it): skip non-reference pictures even when keeping up.
    s->quest_force_skip = getenv("THRU3D_MEDIACODEC_SKIP_NONREF") != NULL;
    s->quest_max_tid = -1;
    s->quest_skipped = 0;
''')
    rep('''        /* fetch new packet or eof */
        ret = ff_decode_get_packet(avctx, &s->buffered_pkt);
        if (ret >= 0) {
''', '''        /* fetch new packet or eof */
        ret = ff_decode_get_packet(avctx, &s->buffered_pkt);
        if (ret >= 0 && quest_skip_packet(avctx, s, &s->buffered_pkt)) {
            /* Thru3D patch 0010: a picture nothing references, skipped as MPV asked */
            av_packet_unref(&s->buffered_pkt);
            continue;
        }
        if (ret >= 0) {
''')
    return text


def main():
    ffmpeg = Path(sys.argv[1]) # Explicit pinned FFmpeg source directory required.
    stall = json.loads((DIRECTORY/'mediacodec-stall-manifest.json').read_text())
    source = (ffmpeg/NAME).read_bytes()
    if sha_bytes(source) != stall['patched_files_sha256'][NAME]:
        raise ValueError('mediacodecdec.c is not the stall (0009) patched base')
    before = source.decode()
    after = edit(before)
    patch = ''.join(difflib.unified_diff(before.splitlines(True), after.splitlines(True),
                                         'a/' + NAME, 'b/' + NAME, n=3))
    patch_path = DIRECTORY/'0010-ffmpeg-mediacodec-skip-nonref.patch'
    patch_path.write_text(patch, newline='\n')
    subprocess.run(['git', 'apply', '--check', str(patch_path)], cwd=ffmpeg, check=True)
    record = {
        'purpose': 'Skip non-reference pictures before MediaCodec when MPV asks (falling behind, exact-seek pre-roll)',
        'stall_patch_sha256': stall['patch_sha256'],
        'base_files_sha256': {NAME: sha_bytes(source)},
        'patched_files_sha256': {NAME: sha_bytes(after.encode())},
        'patch_sha256': sha_bytes(patch_path.read_bytes()),
        'inputs_sha256': {'tools/environment/mpv-linux/create_mediacodec_skip_patch.py':
                          sha_bytes((ROOT/'tools/environment/mpv-linux/create_mediacodec_skip_patch.py').read_bytes())},
    }
    (DIRECTORY/'mediacodec-skip-manifest.json').write_text(json.dumps(record, indent=2) + '\n', newline='\n')
    print('0010 MediaCodec non-reference skip patch generated', record['patch_sha256'])


if __name__ == '__main__':
    main()
