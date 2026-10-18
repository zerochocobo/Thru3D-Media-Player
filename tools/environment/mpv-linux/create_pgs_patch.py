"""Generate an independent PGS client patch against the locked mpv archive."""
import difflib
import hashlib
import json
import os
from pathlib import Path
import tarfile

ROOT = Path(__file__).resolve().parents[3]
ARCHIVE = Path(str(Path(os.environ.get('THRU3D_MPV_DOWNLOADS', str(Path.home() / '.cache/thru3d-mpv/downloads'))) / 'mpv-0b7ed67.tar.gz'))


def sha(data):
    return hashlib.sha256(data).hexdigest()


def main():
    lock = json.loads((ROOT/'third_party/mpv/source-lock.json').read_text())
    expected = next(p['sha256'] for p in lock['sources'] if p['name'] == 'mpv')
    if sha(ARCHIVE.read_bytes()) != expected:
        raise ValueError('PGS archive differs from locked mpv')
    names=['player/client.c','sub/dec_sub.c','sub/dec_sub.h','demux/demux.c','demux/demux.h']
    originals={}
    with tarfile.open(ARCHIVE) as archive:
        for name in names:
            member=next(p for p in archive.getnames() if p.endswith('/'+name))
            originals[name]=archive.extractfile(member).read().decode()
    original=originals['player/client.c']
    anchor = '#include "client.h"\n'
    if original.count(anchor) != 1:
        raise ValueError('PGS client include anchor changed')
    edited = original.replace(anchor, anchor + '#include "sub/dec_sub.h"\n'
                              '#include "mpv/quest_subtitle.h"\n', 1)
    edited += '\n' + (ROOT/'native/mpv/pgs/quest_pgs_client.c.inc').read_text()
    changes={'player/client.c':edited}
    def replace(name,old,new):
        text=changes.get(name,originals[name])
        if text.count(old)!=1: raise ValueError('Text queue source anchor changed: '+name)
        changes[name]=text.replace(old,new,1)
    replace('demux/demux.h','int demux_read_packet_async(struct sh_stream *sh, struct demux_packet **out_pkt);',
            'int demux_read_packet_cached(struct sh_stream *sh, struct demux_packet **out_pkt);\nint demux_read_packet_async(struct sh_stream *sh, struct demux_packet **out_pkt);')
    replace('demux/demux.c','int demux_read_packet_async(struct sh_stream *sh, struct demux_packet **out_pkt)\n{', '''// Consumer-side nonblocking drain of packets already queued by this demuxer.
// Unlike the async reader's unthreaded path this must never call thread_work.
int demux_read_packet_cached(struct sh_stream *sh, struct demux_packet **out_pkt)
{
    *out_pkt = NULL;
    struct demux_stream *ds = sh ? sh->ds : NULL;
    if (!ds)
        return 0;
    struct demux_internal *in = ds->in;
    mp_mutex_lock(&in->lock);
    int r = ds->reader_head && !ds->reader_head->is_cached
        ? dequeue_packet(ds, MP_NOPTS_VALUE, out_pkt) : 0;
    mp_mutex_unlock(&in->lock);
    return r;
}

int demux_read_packet_async(struct sh_stream *sh, struct demux_packet **out_pkt)
{''')
    replace('sub/dec_sub.h','void sub_read_packets(struct dec_sub *sub, double video_pts, bool force,',
            'void sub_read_cached_text(struct dec_sub *sub, double video_pts);\nvoid sub_read_packets(struct dec_sub *sub, double video_pts, bool force,')
    replace('sub/dec_sub.c','void sub_read_packets(struct dec_sub *sub, double video_pts, bool force,\n                      bool *packets_read, bool *sub_updated)',
            'static void read_packets(struct dec_sub *sub, double video_pts, bool force,\n                         bool *packets_read, bool *sub_updated, bool cached_only)')
    replace('sub/dec_sub.c','    video_pts = pts_to_subtitle(sub, video_pts);\n    while (1) {', '''    if (cached_only && !sub->sd->driver->get_lines) {
        mp_mutex_unlock(&sub->lock);
        return;
    }
    video_pts = pts_to_subtitle(sub, video_pts);
    int queued_budget = 256;
    while (!cached_only || queued_budget-- > 0) {''')
    replace('sub/dec_sub.c','        int st = demux_read_packet_async_until(sub->sh, min_pts, &pkt);',
            '        int st = cached_only ? demux_read_packet_cached(sub->sh, &pkt)\n                             : demux_read_packet_async_until(sub->sh, min_pts, &pkt);')
    replace('sub/dec_sub.c','// Redecode all cached packets if needed.', '''void sub_read_packets(struct dec_sub *sub, double video_pts, bool force,
                      bool *packets_read, bool *sub_updated)
{
    read_packets(sub, video_pts, force, packets_read, sub_updated, false);
}

void sub_read_cached_text(struct dec_sub *sub, double video_pts)
{
    bool read = false, updated = false;
    read_packets(sub, video_pts, true, &read, &updated, true);
}

// Redecode all cached packets if needed.''')
    header = (ROOT/'native/mpv/include/mpv/quest_subtitle.h').read_text()
    patch = ''.join(''.join(difflib.unified_diff(originals[name].splitlines(True),changes[name].splitlines(True),
                                             fromfile='a/'+name,tofile='b/'+name)) for name in names)
    patch += ''.join(difflib.unified_diff([], header.splitlines(True), fromfile='/dev/null',
                                       tofile='b/include/mpv/quest_subtitle.h'))
    directory = ROOT/'native/mpv/patches'
    (directory/'0003-mpv-pgs-bitmap.patch').write_text(patch, newline='\n')
    manifest = {'api_version': 1, 'base_archive_sha256': expected,
                'base_files_sha256': {name:sha(text.encode()) for name,text in originals.items()},
                'patched_files_sha256': {**{name:sha(text.encode()) for name,text in changes.items()},
                                        'include/mpv/quest_subtitle.h':sha(header.encode())},
                'patch_sha256': sha(patch.encode()), 'private_header_sha256': sha(header.encode())}
    (directory/'pgs-bitmap-manifest.json').write_text(json.dumps(manifest, indent=2)+'\n')
    print('Independent PGS bitmap patch generated')


if __name__ == '__main__':
    main()
