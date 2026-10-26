"""Desktop integration check for the production reader and Moonshine step.

Build with Test-ListeningReaderHost.sh first. Requires numpy/soundfile, FFmpeg,
and the three earlier benchmark WAVs in --samples (zh.wav, en.wav, ja.wav).
This is not a headset throughput benchmark or a human-labelled accuracy test.
"""
import argparse
import json
import pathlib
import subprocess

import numpy as np
import soundfile as sf

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--samples", type=pathlib.Path, required=True)
parser.add_argument("--ffmpeg", default="ffmpeg")
parser.add_argument("--wsl", default="QuestMpvBuild")
args = parser.parse_args()
root = pathlib.Path(__file__).resolve().parent.parent
output = root / "build/output/live-interpretation/reader"
output.mkdir(parents=True, exist_ok=True)


def linux(path):
    path = pathlib.Path(path).resolve()
    return "/mnt/" + path.drive[0].lower() + path.as_posix()[2:]


def native(name, *arguments):
    result = subprocess.run(
        ["wsl", "-d", args.wsl, "--", linux(output / name), *map(str, arguments)],
        capture_output=True, timeout=120,
    )
    if result.returncode:
        raise RuntimeError(result.stderr.decode("utf-8", errors="replace"))
    return result.stdout.decode("utf-8"), result.stderr.decode("utf-8", errors="replace")


reads, inferences = [], []
for language in ("zh", "en", "ja"):
    audio, rate = sf.read(args.samples / (language + ".wav"), dtype="float32")
    assert rate == 16000 and audio.ndim == 1
    container = output / (language + ".mkv")
    # The minimal desktop FFmpeg build used by this project has no WAV demuxer.
    subprocess.run([args.ffmpeg, "-v", "error", "-y", "-i", str(args.samples / (language + ".wav")),
                    "-c:a", "copy", str(container)], check=True)
    for start in (0, 2.5):
        pcm = output / f"{language}-{start}.f32"
        response, _ = native("reader-host", linux(container), 0, start, linux(pcm))
        result = json.loads(response)
        actual = np.fromfile(pcm, dtype="<f4")
        expected = audio[round(start * rate):]
        assert len(actual) == len(expected) and result["cancelled"]
        error = float(np.max(np.abs(actual - expected)))
        assert error < 1e-6
        reads.append(dict(language=language, start=start, samples=len(actual), max_error=error, native=result))
        response, errors = native("inference-host", linux(root / "models/listening" / language),
                                  language, linux(container), 0, start)
        (output / f"inference-{language}-{start}.jsonl").write_text(response, encoding="utf-8")
        (output / f"inference-{language}-{start}.stderr").write_text(errors, encoding="utf-8")
        steps = [json.loads(line) for line in response.splitlines() if line.startswith("{")]
        assert steps and steps[-1]["eof"]
        cues = {json.dumps(c): c for step in steps for c in step["cues"]}
        assert cues
        previous = start
        for step in steps:
            assert 0 <= step["through"] - previous <= 1.01
            assert all(start <= c["start"] < c["end"] <= step["through"] for c in step["cues"])
            previous = step["through"]
        inferences.append(dict(language=language, start=start, steps=len(steps), through=previous, cues=list(cues.values())))
        print(language, start, "PCM, media timestamps, final text, EOF and cancellation passed", flush=True)
for name, results in (("results", reads), ("inference-results", inferences)):
    (output / (name + ".json")).write_text(json.dumps(results, ensure_ascii=False, indent=2), encoding="utf-8")
