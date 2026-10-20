"""Generate the playback observer after the verified PGS layer; never edit a build tree."""
import difflib
import hashlib
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[3]
import argparse
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--archive', type=Path, required=True, help='Pinned upstream mpv source archive')
ARCHIVE = parser.parse_args().archive
def sha(data): return hashlib.sha256(data).hexdigest()

def main():
    directory = ROOT/'native/mpv/patches'
    pgs = json.loads((directory/'pgs-bitmap-manifest.json').read_text())
    if sha(ARCHIVE.read_bytes()) != pgs['base_archive_sha256']: raise ValueError('Archive differs')
    names = ['player/client.c', 'demux/demux.c', 'audio/out/ao_aaudio.c', 'common/global.h']
    with tempfile.TemporaryDirectory(dir=ROOT/'tmp', prefix='capture-patch-') as temp:
        base = Path(temp)
        with tarfile.open(ARCHIVE) as archive:
            for name in set(names) | set(pgs['base_files_sha256']):
                member = next(p for p in archive.getnames() if p.endswith('/'+name))
                out = base/name; out.parent.mkdir(parents=True, exist_ok=True)
                out.write_bytes(archive.extractfile(member).read())
        subprocess.run(['git', 'apply', '--check', str(directory/'0003-mpv-pgs-bitmap.patch')], cwd=base, check=True)
        subprocess.run(['git', 'apply', str(directory/'0003-mpv-pgs-bitmap.patch')], cwd=base, check=True)
        originals = {name: (base/name).read_text() for name in names}
    changes = dict(originals)
    def replace(name, old, new):
        if changes[name].count(old) != 1: raise ValueError('Capture anchor differs: '+name)
        changes[name] = changes[name].replace(old, new, 1)
    replace('player/client.c', '#include "client.h"\n', '#include "client.h"\n#include <pthread.h>\n#include "mpv/quest_capture.h"\n')
    changes['player/client.c'] += '\n' + (ROOT/'native/mpv/live/quest_capture_client.c.inc').read_text()
    replace('common/global.h', '#define MPV_MPV_H\n', '#define MPV_MPV_H\n#include <stdint.h>\n#include <stdatomic.h>\n')
    replace('common/global.h', 'struct mpv_global {', 'struct mpv_global {\n    _Atomic uint64_t quest_capture_id; // unique across overlapping core teardown/reopen\n')
    replace('demux/demux.c', '#include "common/recorder.h"\n', '#include "common/recorder.h"\n#include "common/av_common.h"\n#include "mpv/quest_capture.h"\n')
    replace('demux/demux.c', '    prune_old_packets(in);\n    *res = pkt;', '''    // Observe exactly the packet handed to the decoder, not network read-ahead.
    if (ds->type == STREAM_VIDEO && ds->sh->codec->lav_codecpar && !pkt->segmented) {
        AVPacket observed = {0};
        AVRational timebase = {1, 1000000};
        mp_set_av_packet(&observed, pkt, &timebase);
        AVCodecParameters capture_params = *ds->sh->codec->lav_codecpar;
        if (capture_params.framerate.num <= 0 && ds->sh->codec->fps > 0)
            capture_params.framerate = av_d2q(ds->sh->codec->fps, 1000000);
        mpv_quest_capture_video_feed(atomic_load(&in->d_thread->global->quest_capture_id), ds->index,
                                    &capture_params, &observed);
    }
    prune_old_packets(in);
    *res = pkt;''')
    replace('audio/out/ao_aaudio.c', '#include "ao.h"\n', '#include "ao.h"\n#include <time.h>\n#include "common/global.h"\n#include "mpv/quest_capture.h"\n')
    replace('audio/out/ao_aaudio.c', '    void *lib_handle;', '''    void *lib_handle;
    int32_t (*capture_get_xruns)(AAudioStream *);
    int32_t capture_xruns;''')
    replace('audio/out/ao_aaudio.c', '    p->lib_handle = dlopen("libaaudio.so", RTLD_NOW | RTLD_GLOBAL);', '''    p->lib_handle = dlopen("libaaudio.so", RTLD_NOW | RTLD_GLOBAL);
    p->capture_get_xruns = p->lib_handle ? dlsym(p->lib_handle, "AAudioStream_getXRunCount") : NULL;''')
    replace('audio/out/ao_aaudio.c', '    ao_read_data(ao, &data, nframes, end_time, NULL, true, true);', '''    int capture_format = ao->format == AF_FORMAT_FLOAT ? 1 :
                         ao->format == AF_FORMAT_S16 ? 2 : ao->format == AF_FORMAT_S32 ? 3 : 0;
    // Reanchor only on a real underrun, never on timestamp observation jitter.
    if (p->capture_get_xruns) {
        int32_t xruns = p->capture_get_xruns(stream);
        if (xruns >= 0 && xruns != p->capture_xruns) {
            p->capture_xruns = xruns;
            mpv_quest_capture_audio_feed(atomic_load(&ao->global->quest_capture_id), NULL, -2,
                ao->samplerate, ao->channels.num, capture_format, 0, 0);
        }
    }
    // Only the hardware presentation watermark releases submitted samples to a recording.
    if (result >= 0)
        mpv_quest_capture_audio_feed(atomic_load(&ao->global->quest_capture_id), NULL, 0,
            ao->samplerate, ao->channels.num, capture_format,
            presented + p->discarded, present_time);
    ao_read_data(ao, &data, nframes, end_time, NULL, true, true);
    mpv_quest_capture_audio_feed(atomic_load(&ao->global->quest_capture_id), data, nframes,
        ao->samplerate, ao->channels.num, capture_format, written, 0);''')
    replace('audio/out/ao_aaudio.c', '        p->AAudioStream_close(p->stream);', '''        int64_t capture_frame = 0, capture_ns = 0;
        bool capture_valid = p->AAudioStream_getTimestamp(p->stream, CLOCK_MONOTONIC,
            &capture_frame, &capture_ns) >= 0;
        p->AAudioStream_close(p->stream);
        // The callback has now joined. Never let close/flush expose an unheard tail.
        if (capture_valid)
            mpv_quest_capture_audio_feed(atomic_load(&ao->global->quest_capture_id), NULL, 0,
                ao->samplerate, ao->channels.num, 0, capture_frame + p->discarded, capture_ns);
        mpv_quest_capture_audio_feed(atomic_load(&ao->global->quest_capture_id), NULL, -1,
            ao->samplerate, ao->channels.num, 0, 0, 0);''')
    # reset() waits for the device to pause before requesting flush. No callback can
    # touch this stream's bounded history while it is being discarded here.
    replace('audio/out/ao_aaudio.c', '    if ((result = p->AAudioStream_requestFlush(p->stream)) < 0) {', '''    int64_t capture_frame = 0, capture_ns = 0;
    if (p->AAudioStream_getTimestamp(p->stream, CLOCK_MONOTONIC, &capture_frame, &capture_ns) >= 0)
        mpv_quest_capture_audio_feed(atomic_load(&ao->global->quest_capture_id), NULL, 0,
            ao->samplerate, ao->channels.num, 0, capture_frame + p->discarded, capture_ns);
    mpv_quest_capture_audio_feed(atomic_load(&ao->global->quest_capture_id), NULL, -1,
        ao->samplerate, ao->channels.num, 0, 0, 0);
    if ((result = p->AAudioStream_requestFlush(p->stream)) < 0) {''')
    header = (ROOT/'native/mpv/include/mpv/quest_capture.h').read_text()
    changes['include/mpv/quest_capture.h'] = header
    patch = ''.join(''.join(difflib.unified_diff(originals.get(name, '').splitlines(True), value.splitlines(True),
        fromfile='a/'+name if name in originals else '/dev/null', tofile='b/'+name)) for name,value in changes.items())
    (directory/'0004-mpv-live-capture.patch').write_text(patch, newline='\n')
    record = {'api_version':2, 'pgs_patch_sha256':pgs['patch_sha256'],
        'inputs_sha256':{str(p.relative_to(ROOT)).replace('\\','/'):sha(p.read_bytes()) for p in [
            ROOT/'native/mpv/live/quest_capture_client.c.inc', ROOT/'native/mpv/include/mpv/quest_capture.h', Path(__file__)]},
        'base_files_sha256':{k:sha(v.encode()) for k,v in originals.items()},
        'patched_files_sha256':{k:sha(v.encode()) for k,v in changes.items()},
        'patch_sha256':sha(patch.encode()), 'private_header_sha256':sha(header.encode())}
    (directory/'live-capture-manifest.json').write_text(json.dumps(record,indent=2)+'\n')
    print('Bounded playback observer patch generated')
if __name__ == '__main__': main()
