"""Exercise the production filter graph on PCM; writes only reproducible build output."""
import argparse
import json
import math
from pathlib import Path
import re
import subprocess

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
RATE = 48000


def graph():
    source = (ROOT / "native/mpv/whisper_audio.h").read_text(encoding="utf-8")
    body = source.split("static const char* graph()", 1)[1].split("static bool valid", 1)[0]
    return "".join(json.loads(s) for s in re.findall(r'"(?:[^"\\]|\\.)*"', body)).split("lavfi=[", 1)[1][:-1]


def process(ffmpeg, chain, pcm):
    result = subprocess.run([ffmpeg, "-hide_banner", "-loglevel", "error", "-f", "f32le", "-ar", str(RATE),
                             "-ac", "2", "-i", "pipe:0", "-af", chain, "-f", "f32le", "pipe:1"],
                            input=pcm.astype("<f4").tobytes(), capture_output=True, check=True)
    return np.frombuffer(result.stdout, dtype="<f4").reshape(-1, 2)


def rms(pcm):
    return float(np.sqrt(np.mean(np.square(pcm.astype(np.float64)))))


def db_ratio(a, b):
    return 20 * math.log10(max(rms(a), 1e-15) / max(rms(b), 1e-15))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--ffmpeg", default="ffmpeg")
    parser.add_argument("--output", type=Path, default=ROOT / "build/output/system-volume-boost/pcm")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    time = np.arange(RATE * 8) / RATE
    signal = np.zeros_like(time)
    # A low-level harmonic signal, loud action, return to low-level audio, silence.
    quiet = (0.65 * np.sin(2 * np.pi * 230 * time) + 0.35 * np.sin(2 * np.pi * 1430 * time)) * 10 ** (-42 / 20)
    signal[RATE:3 * RATE] = quiet[RATE:3 * RATE]
    loud = 0.9 * np.sin(2 * np.pi * 137 * time)
    signal[3 * RATE:4 * RATE] = loud[3 * RATE:4 * RATE]
    signal[4 * RATE:7 * RATE] = quiet[4 * RATE:7 * RATE]
    signal[3 * RATE] = 0.999  # A sudden transient tests peak limiting.
    source = np.column_stack((signal, signal * 0.37)).astype(np.float32)
    source.tofile(args.output / "source.f32le")
    base = graph()
    report = {"sample_rate": RATE, "frames": len(source), "graph": base, "levels": {}, "checks": 0}

    def check(condition, message):
        report["checks"] += 1
        if not condition:
            raise AssertionError(message)

    for level, expected_gain in [(100, 0), (125, 7), (150, 14)]:
        name = str(level)
        makeup = str(10 ** (expected_gain / 20))
        chain = base.replace("mix=0", "mix=1").replace("makeup=1:", "makeup=" + makeup + ":")
        output = process(args.ffmpeg, chain, source)
        check(len(output) == len(source), name + ": lookahead compensation must preserve frame count")
        check(np.isfinite(output).all(), name + ": finite output")
        gain = db_ratio(output[2 * RATE:3 * RATE], source[2 * RATE:3 * RATE])
        loud_gain = db_ratio(output[int(3.3 * RATE):4 * RATE], source[int(3.3 * RATE):4 * RATE])
        check(abs(gain - expected_gain) < 0.1, name + ": bounded whisper gain")
        check(loud_gain < -2, name + ": loud action must become quieter, not just clipped")
        peak = float(np.max(np.abs(output)))
        check(peak <= 0.95001, name + ": sample peak ceiling")
        balance_error = float(np.max(np.abs(output[:, 1] - output[:, 0] * 0.37)))
        check(balance_error < 2e-6, name + ": preserve stereo balance through action and whispers")
        check(np.max(np.abs(output[:RATE - 300])) == 0, name + ": silence remains silence")
        return_gain = db_ratio(output[6 * RATE:7 * RATE], source[6 * RATE:7 * RATE])
        check(abs(return_gain - expected_gain) < 0.2, name + ": recover whispers after loud action")
        report["levels"][name] = {"quiet_gain_db": gain, "loud_gain_db": loud_gain,
                                    "sample_peak": peak, "stereo_error": balance_error, "return_gain_db": return_gain}
        output.tofile(args.output / (name + ".f32le"))
    # FFmpeg command support is required by the actual native fade controller.
    continuous = np.column_stack((quiet, quiet * 0.37)).astype(np.float32)
    commands = "0.5 acompressor threshold 0.0316227766;0.5 acompressor ratio 6;0.5 acompressor makeup 5.0118723363;0.5 acompressor mix 1;1.5 acompressor makeup 1"
    command_output = process(args.ffmpeg, "asendcmd=c='" + commands + "'," + base, continuous)
    check(abs(db_ratio(command_output[int(0.1 * RATE):int(0.4 * RATE)], continuous[int(0.1 * RATE):int(0.4 * RATE)])) < 0.01,
          "mix=0 starts dry")
    report["runtime_gain_db"] = db_ratio(command_output[RATE:int(1.4 * RATE)], continuous[RATE:int(1.4 * RATE)])
    check(abs(report["runtime_gain_db"] - 14) < 0.1,
          "runtime commands change threshold, ratio, makeup and mix to the strong preset")
    check(abs(db_ratio(command_output[2*RATE:3*RATE], continuous[2*RATE:3*RATE])) < 0.01,
          "returning to 100% removes makeup while retaining compression")
    check(report["levels"]["100"]["loud_gain_db"] < report["levels"]["125"]["loud_gain_db"] < report["levels"]["150"]["loud_gain_db"],
          "decreasing the yellow value cannot increase steady loud action")
    check(len(command_output) == len(continuous), "runtime changes preserve audio duration")
    report["passed"] = True
    (args.output / "measurements.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
