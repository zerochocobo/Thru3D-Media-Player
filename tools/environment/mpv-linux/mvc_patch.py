"""Apply the owned MVC codec/demux adapter to the exact pinned FFmpeg tree."""
import hashlib
import json
from pathlib import Path
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[3]


def sha(content):
    return hashlib.sha256(content).hexdigest()


def once(text, old, new):
    if text.count(old) != 1:
        raise ValueError('Pinned MVC source anchor differs: ' + old[:80])
    return text.replace(old, new, 1)


def apply_mvc_patch(ffmpeg, archive):
    subprocess.run(['python3', str(ROOT / 'tools/environment/Prepare-MvcDecoder.py')], check=True)
    names = ['libavcodec/allcodecs.c', 'libavcodec/codec_id.h', 'libavcodec/codec_desc.c',
             'libavcodec/Makefile', 'libavformat/allformats.c', 'libavformat/Makefile', 'libavformat/dvdvideodec.c']
    original = {}
    with tarfile.open(archive) as tar:
        for member in tar.getmembers():
            relative = '/'.join(member.name.split('/')[1:])
            if relative in names:
                original[relative] = tar.extractfile(member).read()
    if set(original) != set(names):
        raise ValueError('Pinned FFmpeg archive is missing MVC patch inputs')
    edited = {name: content.decode() for name, content in original.items()}
    p = 'libavcodec/allcodecs.c'
    edited[p] = once(edited[p], 'extern const FFCodec ff_h264_decoder;',
                    'extern const FFCodec ff_h264_decoder;\nextern const FFCodec ff_h264_mvc_decoder;')
    p = 'libavcodec/codec_id.h'
    edited[p] = once(edited[p], '    AV_CODEC_ID_FIRST_AUDIO = 0x10000,',
                    '    AV_CODEC_ID_H264_MVC,\n\n    AV_CODEC_ID_FIRST_AUDIO = 0x10000,')
    p = 'libavcodec/codec_desc.c'
    marker = edited[p].index('AV_CODEC_ID_PCM_S16LE')
    at = edited[p].rfind('    {', 0, marker)
    entry = ('    {\n        .id = AV_CODEC_ID_H264_MVC,\n        .type = AVMEDIA_TYPE_VIDEO,\n'
             '        .name = "h264_mvc",\n        .long_name = NULL_IF_CONFIG_SMALL("H.264 MVC stereo"),\n'
             '        .props = AV_CODEC_PROP_LOSSY | AV_CODEC_PROP_REORDER,\n    },\n')
    edited[p] = edited[p][:at] + entry + edited[p][at:]
    edited['libavcodec/Makefile'] += ('\n# Thru3D: pinned BSD MVC decoder and native paired-frame adapter.\n'
        'OBJS-$(CONFIG_H264_MVC_DECODER) += h264_mvc.o edge264mvc_all.o\n'
        '$(SUBDIR)edge264mvc_all.o: CFLAGS += -std=gnu11 -D_GNU_SOURCE -O3 -fwrapv -flax-vector-conversions -Wno-override-init\n')
    p = 'libavformat/allformats.c'
    edited[p] = once(edited[p], 'extern const FFInputFormat  ff_mpegts_demuxer;',
                    'extern const FFInputFormat  ff_mpegts_demuxer;\nextern const FFInputFormat ff_bd_mvc_demuxer;')
    edited['libavformat/Makefile'] += '\nOBJS-$(CONFIG_BD_MVC_DEMUXER) += bd_mvc.o dvd_nav.o dvdclut.o\n'
    # Preserve upstream title/PGC/codec handling, adding per-reader cursors so
    # libdvdread and libdvdnav can share the caller's cached network AVIO safely.
    dvd = edited.pop('libavformat/dvdvideodec.c')
    dvd = once(dvd, '    const AVClass               *class;',
               '    const AVClass               *class;\n    DvdIO thru_ifo_io, thru_nav_io;')
    dvd = dvd.replace('AVFormatContext *s = opaque;', 'AVFormatContext *s = ((DvdIO *)opaque)->context;', 2)
    dvd = once(dvd, 'c->dvdread = DVDOpen2(s, &dvdread_log_cb, s->url);',
               'c->thru_ifo_io = *(DvdIO *)s->opaque;\n'
               '    c->dvdread = DVDOpenStream2(&c->thru_ifo_io, &dvdread_log_cb, &dvd_io_callbacks);')
    dvd = once(dvd, 'dvdnav_open_status = dvdnav_open2(&state->dvdnav, s, &dvdnav_log_cb, s->url);',
               'c->thru_nav_io = *(DvdIO *)s->opaque;\n'
               '    dvdnav_open_status = dvdnav_open_stream2(&state->dvdnav, &c->thru_nav_io, &dvdnav_log_cb, &dvd_io_callbacks);')
    dvd = once(dvd, 'if (timestamp < 0 || timestamp > s->duration)',
               'timestamp = av_rescale_q(timestamp, s->streams[stream_index]->time_base, DVDVIDEO_TIME_BASE_Q);\n'
               '    if (timestamp < 0 || timestamp > av_rescale_q(s->duration, AV_TIME_BASE_Q, DVDVIDEO_TIME_BASE_Q))')
    dvd = once(dvd, 'dvdnav_time_search(c->play_state.dvdnav, timestamp)',
               'thru_dvd_title_jump(c->play_state.dvdnav, c->opt_title, timestamp, '
               'c->play_state.pgc_pg_times_est, c->play_state.pgc_nb_pg_est)')
    # dvdnav_get_current_time immediately after a seek still has the OLD NAV
    # cell clock. Rebase at the first fresh NAV, before any PES is delivered.
    dvd = once(dvd, 'state->nav_pts = dvdnav_get_current_time(state->dvdnav);\n                state->ptt',
               'state->nav_pts = dvdnav_get_current_time(state->dvdnav);\n'
               '                if (state->is_seeking) {\n'
               '                    state->ptm_offset = state->nav_pts;\n'
               '                    c->pts_offset = state->nav_pts;\n'
               '                }\n                state->ptt')
    dvd = once(dvd, 'ff_dvdvideo_demuxer =', 'ff_thru3d_dvd_title_demuxer =')
    dvd = once(dvd, 'AVFMT_NOFILE   | AVFMT_NO_BYTE_SEEK', 'AVFMT_NO_BYTE_SEEK')
    dvd = once(dvd, 'return avformat_open_input(&c->mpeg_ctx, "", &ff_mpegps_demuxer.p, NULL);',
        '''ret = avformat_open_input(&c->mpeg_ctx, "", &ff_mpegps_demuxer.p, NULL);
    if (ret < 0) return ret;
    /* IFO supplies codec IDs: do not depend on raw-format probing before the
       MPEG parser can assemble a complete picture/subpicture. */
    for (unsigned i = 0; i < s->nb_streams; i++) {
        AVStream *st = avformat_new_stream(c->mpeg_ctx, NULL);
        if (!st) return AVERROR(ENOMEM);
        if ((ret = avcodec_parameters_copy(st->codecpar, s->streams[i]->codecpar)) < 0) return ret;
        st->id = s->streams[i]->id;
        avpriv_set_pts_info(st, 32, 1, 90000);
        ffstream(st)->need_parsing = AVSTREAM_PARSE_FULL;
    }
    return 0;''')
    edited['libavformat/thru3d_dvd_title.c'] = dvd
    desired = {name: content.encode() for name, content in edited.items()}
    for local, name in [('ffmpeg_h264_mvc.c','libavcodec/h264_mvc.c'),
                        ('mvc_recovery.h','libavcodec/mvc_recovery.h'),
                        ('ffmpeg_bd_mvc.c','libavformat/bd_mvc.c'),
                        ('ffmpeg_dvd_nav.c','libavformat/dvd_nav.c'),
                        ('dvd_nav.h','libavformat/dvd_nav.h'),
                        ('edge264mvc_all.c','libavcodec/edge264mvc_all.c')]:
        desired[name] = (ROOT / 'native/mpv/mvc' / local).read_bytes()
    pin = json.loads((ROOT / 'third_party/edge264-mvc/manifest.json').read_text())
    source = ROOT / 'tmp/mvc-research' / ('edge264-mvc-' + pin['revision'])
    desired['libavcodec/edge264mvc/edge264mvc.h'] = (source / 'edge264mvc.h').read_bytes()
    desired['libavcodec/edge264mvc/LICENSE.BSD'] = (source / 'LICENSE_BSD.txt').read_bytes()
    for path in (source / 'src').glob('*'):
        if path.suffix in ('.c', '.h'):
            desired['libavcodec/edge264mvc/src/' + path.name] = path.read_bytes()
    marker = ffmpeg / '.quest-mvc-manifest.json'
    previous = json.loads(marker.read_text()) if marker.exists() else {}
    for name, content in desired.items():
        target = ffmpeg / name
        if target.is_file():
            actual = target.read_bytes()
            allowed = actual == content or name in original and actual == original[name]
            allowed |= previous.get('files_sha256', {}).get(name) == sha(actual)
            if not allowed:
                raise ValueError('Unrecognized MVC build source; preserve before replacing: ' + name)
        target.parent.mkdir(parents=True, exist_ok=True)
        if not target.is_file() or target.read_bytes() != content:
            target.write_bytes(content)
    marker.write_text(json.dumps({'revision': pin['revision'],
                                  'files_sha256': {name: sha(content) for name, content in desired.items()}}, indent=2) + '\n')
    builder_script = ffmpeg.parents[1] / 'scripts/ffmpeg.sh'
    if builder_script.is_file():
        flags = builder_script.read_text()
        if '--enable-libbluray' not in flags:
            flags = once(flags, '--enable-{jni,mediacodec,mbedtls,libdav1d,libxml2} --disable-vulkan',
                         '--enable-{jni,mediacodec,mbedtls,libdav1d,libxml2} --disable-vulkan\n'
                         '\t--enable-libbluray --pkg-config-flags=--static')
            builder_script.write_text(flags)
        flags = builder_script.read_text()
        if '--enable-libdvdnav' not in flags:
            flags = once(flags, '--enable-libbluray --pkg-config-flags=--static',
                         '--enable-libbluray --enable-libdvdnav --enable-libdvdread --pkg-config-flags=--static')
            builder_script.write_text(flags)
    mpv_script = ffmpeg.parents[1] / 'scripts/mpv.sh'
    if mpv_script.is_file():
        flags = mpv_script.read_text()
        if '-Dlibbluray=disabled' not in flags:
            flags = once(flags, '-Dlibmpv=true -Dcplayer=false',
                         '-Dlibmpv=true -Dcplayer=false -Dlibbluray=disabled')
            mpv_script.write_text(flags)
    print('Pinned MVC codec, decoder and UDF/SSIF demux source verified', flush=True)
