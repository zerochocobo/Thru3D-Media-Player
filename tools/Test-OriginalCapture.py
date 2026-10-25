"""Production packet-copy integration: fixtures on Windows, the same C++ core on Linux, packet verification."""
import argparse
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build/output/original-capture"


def run(args, **kwargs):
    return subprocess.run([str(x) for x in args], check=True, capture_output=True, text=True, **kwargs)


def prepare():
    OUT.mkdir(parents=True, exist_ok=True)
    common = ["ffmpeg", "-y", "-v", "error"]
    run(common + ["-f", "lavfi", "-i", "testsrc2=size=640x320:rate=30", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
                  "-f", "lavfi", "-i", "sine=frequency=880:sample_rate=48000", "-t", "8", "-map", "0:v", "-map", "1:a", "-map", "2:a",
                  "-c:v", "libx264", "-g", "60", "-keyint_min", "60", "-sc_threshold", "0", "-bf", "3", "-pix_fmt", "yuv420p",
                  "-c:a", "aac", "-b:a", "96k", OUT / "avc.mp4"])
    run(common + ["-i", OUT / "avc.mp4", "-map", "0:a:1", "-c", "copy", OUT / "sidecar.m4a"])
    run(common + ["-i", OUT / "avc.mp4", "-map", "0:v", "-map", "0:a:0", "-c:v", "copy", "-c:a", "pcm_s16le", OUT / "pcm.mkv"])
    run(common + ["-f", "lavfi", "-i", "testsrc2=size=512x256:rate=30", "-f", "lavfi", "-i", "sine=frequency=660:sample_rate=48000",
                  "-t", "6", "-vf", "format=yuv420p10le", "-c:v", "libx265", "-threads", "2", "-x265-params",
                  "pools=2:frame-threads=2:keyint=60:min-keyint=60:scenecut=0:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc",
                  "-c:a", "aac", OUT / "hdr.mp4"])
    print("Prepared AVC B-frame/two-audio, sidecar, PCM/Matroska and 10-bit HDR HEVC fixtures")


def execute():
    binary = OUT / "clip-host"
    cases = [
        ("avc-selected", "avc.mp4", 2500000, 5750000, 2, ""),
        ("avc-auto", "avc.mp4", 2500000, 5750000, -2, ""),
        ("avc-muted", "avc.mp4", 2500000, 5750000, -1, ""),
        ("external", "avc.mp4", 2500000, 5750000, -1, "sidecar.m4a"),
        ("mkv-pcm", "pcm.mkv", 2500000, 5750000, 1, ""),
        ("hdr", "hdr.mp4", 2500000, 4750000, 1, ""),
        ("invalid-audio", "avc.mp4", 2500000, 5750000, 99, ""),
        ("empty", "avc.mp4", 2500000, 2500000, 1, ""),
    ]
    reports = []
    for name, source, start, end, audio, sidecar in cases:
        target = OUT / (name + ".output")
        # Android writes through /proc/self/fd to a MediaStore pending descriptor too.
        with target.open("wb+") as fd:
            args = [str(binary), str(OUT / source), f"/proc/self/fd/{fd.fileno()}", str(start), str(end), str(audio)]
            if sidecar:
                args.append(str(OUT / sidecar))
            result = subprocess.run(args, text=True, capture_output=True, pass_fds=(fd.fileno(),))
        (OUT / (name + ".stderr.log")).write_text(result.stderr)
        report = json.loads(result.stdout.strip())
        report.update(name=name, source=source, audio=audio, sidecar=sidecar, requested_start=start, requested_end=end)
        reports.append(report)
    (OUT / "clip-reports.json").write_text(json.dumps(reports, indent=2))
    print(json.dumps(reports, indent=2))


def inspect(path, packets=False):
    args = ["ffprobe", "-v", "error", "-show_streams", "-show_format", "-of", "json"]
    if packets:
        args += ["-show_packets", "-show_data_hash", "sha256"]
    return json.loads(run(args + [path]).stdout)


def verify():
    reports = json.loads((OUT / "clip-reports.json").read_text())
    checks = []
    for report in reports:
        name = report["name"]
        if name in ("empty", "invalid-audio"):
            assert report["state"] == "error", report
            checks.append(name + ": rejected")
            continue
        assert report["state"] == "saved", report
        assert report["progress"] == 99, report  # 100 belongs to MediaStore publication.
        output = OUT / (name + ".output")
        source = inspect(OUT / report["source"], True)
        saved = inspect(output, True)
        source_video = next(s for s in source["streams"] if s["codec_type"] == "video")
        saved_video = next(s for s in saved["streams"] if s["codec_type"] == "video")
        for key in ("codec_name", "width", "height", "pix_fmt", "color_range", "color_space", "color_transfer", "color_primaries"):
            assert source_video.get(key) == saved_video.get(key), (name, key, source_video.get(key), saved_video.get(key))
        assert report["start_us"] <= report["requested_start"] and report["lead_us"] <= 2000000, report
        assert report["requested_end"] - 100000 <= report["end_us"] <= report["requested_end"] + 250000, report
        tags = {k.lower(): v for k, v in saved["format"].get("tags", {}).items()}
        assert json.loads(tags["thru3d_mode"])["geometry"] == 3, (name, tags)
        source_packets = [p for p in source["packets"] if p["stream_index"] == source_video["index"]]
        saved_packets = [p for p in saved["packets"] if p["stream_index"] == saved_video["index"]]
        hashes = [p["data_hash"] for p in source_packets]
        copied = [p["data_hash"] for p in saved_packets]
        assert copied and "K" in saved_packets[0]["flags"], name
        index = hashes.index(copied[0])
        assert hashes[index:index+len(copied)] == copied, name + ": video packets changed"
        assert report["video_packets"] == len(copied), name
        audio = [s for s in saved["streams"] if s["codec_type"] == "audio"]
        if name == "avc-muted":
            assert not audio
        else:
            assert len(audio) == 1
            audio_source = inspect(OUT / report["sidecar"], True) if report["sidecar"] else source
            audio_index = 0 if report["sidecar"] else report["audio"]
            if audio_index == -2:
                audio_index = next(s["index"] for s in source["streams"] if s["codec_type"] == "audio")
            original_audio = [p["data_hash"] for p in audio_source["packets"] if p["stream_index"] == audio_index]
            copied_audio = [p["data_hash"] for p in saved["packets"] if p["stream_index"] == audio[0]["index"]]
            begin = original_audio.index(copied_audio[0])
            assert original_audio[begin:begin+len(copied_audio)] == copied_audio, name + ": audio packets changed"
            first_video = float(saved_packets[0]["pts_time"])
            first_audio = float(next(p for p in saved["packets"] if p["stream_index"] == audio[0]["index"])["pts_time"])
            assert abs(first_video - first_audio) < 0.08, (name, first_video, first_audio)
        run(["ffmpeg", "-v", "error", "-err_detect", "explode", "-i", output, "-f", "null", "-"])
        checks.append(name + ": byte-identical video/audio packets, layout metadata, clean decode, source resolution/color and timing")
    (OUT / "verification.json").write_text(json.dumps({"state": "passed", "cases": checks}, indent=2))
    print("Production source-clip integration passed:")
    print("\n".join(checks))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("phase", choices=("prepare", "execute", "verify"))
    args = parser.parse_args()
    {"prepare": prepare, "execute": execute, "verify": verify}[args.phase]()
