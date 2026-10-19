"""Read MP4 indexes without reading media payloads; report network seek hazards.

Read-only. Reports include basenames, so keep raw output in build/ locally.
"""
import argparse
from collections import deque
import json
import struct
import time
from pathlib import Path


def u32(data, at):
    return struct.unpack_from('>I', data, at)[0]


def boxes(data, start=0, end=None):
    end = len(data) if end is None else end
    while start < end:
        if end - start < 8:
            raise ValueError('truncated box')
        size, kind = struct.unpack_from('>I4s', data, start)
        header = 8
        if size == 1:
            size = struct.unpack_from('>Q', data, start + 8)[0]
            header = 16
        elif size == 0:
            size = end - start
        if size < header or start + size > end:
            raise ValueError('invalid box size')
        yield kind.decode('latin1'), start + header, start + size
        start += size


def child(data, parent, kind):
    return next((a, b) for k, a, b in boxes(data, *parent) if k == kind)


def table(data, bounds, width):
    start, end = bounds
    count = u32(data, start + 4)
    if start + 8 + count * width > end:
        raise ValueError('truncated table')
    return list(struct.iter_unpack('>' + ('I' if width == 4 else 'Q'), data[start + 8:start + 8 + count * width]))


def inspect(path):
    started = time.monotonic()
    size = path.stat().st_size
    atoms = []
    reads = 0
    with path.open('rb', buffering=0) as source:
        at = 0
        moov = None
        while at < size:
            source.seek(at)
            head = source.read(16)
            reads += len(head)
            length, kind = struct.unpack_from('>I4s', head)
            if length == 1:
                length = struct.unpack_from('>Q', head, 8)[0]
            elif length == 0:
                length = size - at
            if length < 8 or at + length > size:
                raise ValueError('invalid top-level box')
            atoms.append(dict(type=kind.decode('latin1'), offset=at, size=length))
            if kind == b'moov':
                if length > 32 * 1024 * 1024:
                    raise ValueError('moov exceeds diagnostic budget')
                source.seek(at)
                moov = source.read(length)
                reads += len(moov)
            at += length
    if moov is None:
        raise ValueError('no moov')
    root = next(boxes(moov))[1:]
    tracks = []
    chunks_all = []
    for kind, a, b in boxes(moov, *root):
        if kind != 'trak':
            continue
        mdia = child(moov, (a, b), 'mdia')
        hdlr = child(moov, mdia, 'hdlr')
        handler = moov[hdlr[0] + 8:hdlr[0] + 12].decode('latin1')
        mdhd = child(moov, mdia, 'mdhd')[0]
        scale = u32(moov, mdhd + (20 if moov[mdhd] == 1 else 12))
        stbl = child(moov, child(moov, mdia, 'minf'), 'stbl')
        tables = {k: (x, y) for k, x, y in boxes(moov, *stbl)}
        co = 'co64' if 'co64' in tables else 'stco'
        offsets = [v[0] for v in table(moov, tables[co], 8 if co == 'co64' else 4)]
        sz = tables['stsz'][0]
        fixed, count = u32(moov, sz + 4), u32(moov, sz + 8)
        lengths = [fixed] * count if fixed else [v[0] for v in struct.iter_unpack('>I', moov[sz + 12:sz + 12 + count * 4])]
        sc = tables['stsc'][0]
        runs = list(struct.iter_unpack('>III', moov[sc + 8:tables['stsc'][1]]))
        ts = tables['stts'][0]
        timings = list(struct.iter_unpack('>II', moov[ts + 8:tables['stts'][1]]))
        durations = [duration for n, duration in timings for _ in range(n)]
        if len(durations) != count:
            raise ValueError('sample timing mismatch')
        seconds = {}
        ticks = 0
        for length, duration in zip(lengths, durations):
            second = ticks // scale
            seconds[second] = seconds.get(second, 0) + length
            ticks += duration
        max_second = max(seconds, default=0)
        rolling_five = [sum(seconds.get(s+j, 0) for j in range(5)) / 5 for s in range(max(1, max_second-3))]
        sample, run, dts = 0, 0, 0
        chunks = []
        for i, offset in enumerate(offsets):
            while run + 1 < len(runs) and i + 1 >= runs[run + 1][0]:
                run += 1
            n = runs[run][1]
            nbytes = sum(lengths[sample:sample + n])
            duration = sum(durations[sample:sample + n])
            entry = dict(track=len(tracks), kind=handler, offset=offset, end=offset+nbytes,
                         bytes=nbytes, time=dts / scale, duration=duration / scale, samples=n)
            chunks.append(entry)
            sample += n
            dts += duration
        if sample != count:
            raise ValueError('chunk sample mismatch')
        chunks_all.extend(chunks)
        ordered = sorted(c['bytes'] for c in chunks)
        tracks.append(dict(kind=handler, samples=count, bytes=sum(lengths), duration=dts / scale,
                           chunks=len(chunks), first_offset=min(offsets), last_offset=max(offsets),
                           chunk_bytes_max=max(ordered), chunk_bytes_median=ordered[len(ordered)//2],
                           max_one_second_Mbps=max(seconds.values(), default=0)*8/1e6,
                           max_five_second_Mbps=max(rolling_five, default=0)*8/1e6,
                           first_chunks=chunks[:4], last_chunks=chunks[-2:]))
    av = sorted((c for c in chunks_all if c['kind'] in ('soun', 'vide')), key=lambda c: c['offset'])
    switches = sum(a['track'] != b['track'] for a, b in zip(av, av[1:]))
    clocks = {'vide': 0.0, 'soun': 0.0}
    pending = {'vide': deque(), 'soun': deque()}
    pending_bytes = {'vide': 0, 'soun': 0}
    peak_pending = {'vide': 0, 'soun': 0}
    max_ahead = {'vide': 0.0, 'soun': 0.0}
    for c in av:
        kind = c['kind']
        clocks[kind] = c['time'] + c['duration']
        pending[kind].append(c)
        pending_bytes[kind] += c['bytes']
        floor = min(clocks.values())
        for k in clocks:
            while pending[k] and pending[k][0]['time'] + pending[k][0]['duration'] <= floor:
                pending_bytes[k] -= pending[k].popleft()['bytes']
            peak_pending[k] = max(peak_pending[k], pending_bytes[k])
            max_ahead[k] = max(max_ahead[k], clocks[k] - floor)
    windows = []
    for begin in (0, 60, 300):
        selected = sorted((c for c in av if begin <= c['time'] < begin + 30), key=lambda c: c['time'])
        jumps = [b['offset'] - a['end'] for a, b in zip(selected, selected[1:])]
        windows.append(dict(begin=begin, chunks=len(selected),
                            backwards=sum(j < 0 for j in jumps), jumps_over_64MiB=sum(abs(j) >= 64*1024*1024 for j in jumps),
                            maximum_jump_bytes=max(map(abs, jumps), default=0)))
    return dict(name=path.name, size=size, atoms=atoms, tracks=tracks,
                physical_av_switches=switches, time_order_windows=windows,
                file_order_max_ahead_seconds=max_ahead,
                file_order_pending_payload_peak_bytes=peak_pending,
                index_bytes_read=reads, elapsed_seconds=time.monotonic()-started)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('paths', nargs='+', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    reports = []
    for path in args.paths:
        for item in sorted(path.glob('*.mp4')) if path.is_dir() else [path]:
            try:
                report = inspect(item)
            except Exception as error:
                report = dict(name=item.name, error=str(error))
            reports.append(report)
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(json.dumps(reports, indent=2, ensure_ascii=False), encoding='utf-8')
            print(json.dumps(report, ensure_ascii=False), flush=True)


if __name__ == '__main__':
    main()
