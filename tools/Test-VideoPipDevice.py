"""Debug-only Quest validation through the normal VR launcher and production player.

Closes the current video, copies generated identity fixtures to app-owned files,
and restores the numbered global zoom settings before closing test playback.
Does not build or install an APK. Run only during an authorized headset test.
Generate fixtures with tools/New-PipDeviceMedia.py; reports belong in build/output/.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shlex
import subprocess
import time
import uuid


class Device:
    def __init__(self, adb, serial, output):
        self.adb, self.serial, self.output = adb, serial, output
        self.package = "com.wapok.thru3d"
        self.output.mkdir(parents=True, exist_ok=True)
        self.process = None
        self.sequence = 0

    def command(self, *arguments, data=None, timeout=60):
        result = subprocess.run([self.adb, "-s", self.serial, *map(str, arguments)], input=data, capture_output=True, timeout=timeout)
        if result.returncode:
            raise RuntimeError(result.stderr.decode(errors="replace") + result.stdout.decode(errors="replace"))
        return result.stdout

    def shell(self, *arguments, data=None):
        return self.command("shell", "-T", shlex.join(map(str, arguments)), data=data)

    def read(self, filename):
        try:
            return json.loads(self.shell("run-as", self.package, "cat", "files/diagnostics/" + filename))
        except (RuntimeError, json.JSONDecodeError):
            return None

    def send(self, operation, **parameters):
        self.sequence += 1
        key = "pip_" + uuid.uuid4().hex[:24]
        arguments = ["am", "broadcast", "-n", self.package + "/org.vrpassthroughplayer.plugin.DebugDiagnosticsReceiver",
                     "-a", self.package + ".DEBUG_PLAYER_MPV", "--es", "request", key,
                     "--es", "operation", operation, "--es", "params", json.dumps(parameters, separators=(",", ":"))]
        # The receiver resolves a source URI/fixture before dispatching the JSON.
        if operation == "open":
            for name in ("uri", "title", "fixture"):
                if name in parameters: arguments += ["--es", name, str(parameters[name])]
            arguments += ["--ei", "projection", str(parameters.get("projection", 0))]
        if operation in ("subtitle", "audio"):
            arguments += ["--ei", "track_id", str(parameters.get("track_id", 0))]
        if operation == "narration":
            arguments += ["--es", "options", json.dumps(parameters.get("options", {}), separators=(",", ":"))]
        self.shell(*arguments)
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            receipt = self.read("debug_request_" + key + ".json")
            if receipt:
                if receipt.get("state") != "accepted":
                    raise RuntimeError(receipt)
                process = receipt["diagnostic_process"]
                if self.process and self.process != process:
                    raise RuntimeError("Player process unexpectedly changed")
                self.process = process
                return receipt
            time.sleep(.15)
        raise TimeoutError("No receipt for " + operation)

    def wait(self, receipt, label, predicate, seconds=35):
        deadline = time.monotonic() + seconds
        refreshed = time.monotonic()
        last = None
        while time.monotonic() < deadline:
            report = self.read("mpv_player_" + str(receipt["id"]) + ".json")
            # Request counters restart with the process; app-owned reports survive
            # APK replacement. A matching integer alone can accept an older build.
            current = report and report.get("request_id") == receipt["id"] and any(
                c.get("request_id") == receipt["id"] and c.get("request_key") == receipt["request"]
                for c in report.get("commands", []))
            if current:
                last = report
                if report.get("media", {}).get("state") == "failed":
                    raise RuntimeError(label + ": " + str(report["media"]))
                if predicate(report):
                    (self.output / (label + ".json")).write_text(json.dumps(report, indent=2), encoding="utf-8")
                    print("Verified:", label, flush=True)
                    return report
            # A paused frame can have no native status changes. Ask for a current
            # snapshot rather than interpreting an unchanged old report as completion.
            if time.monotonic() - refreshed > 1.5:
                receipt = self.send("observe")
                refreshed = time.monotonic()
            time.sleep(.15)
        if last:
            (self.output / (label + "-timeout.json")).write_text(json.dumps(last, indent=2), encoding="utf-8")
        raise TimeoutError(label)

    def probe(self, label, step, predicate=None, **parameters):
        receipt = self.send("pip_probe", step=step, **parameters)
        def condition(report):
            result = report.get("pip_probe", {})
            if result.get("step") != step:
                return False
            if not result.get("ok"):
                raise RuntimeError(label + ": " + str(result))
            return predicate(report) if predicate else True
        return self.wait(receipt, label, condition)

    def upload(self, fixture):
        relative = "files/fixtures/" + fixture.name
        expected = hashlib.sha256(fixture.read_bytes()).hexdigest()
        try:
            actual = self.shell("run-as", self.package, "sha256sum", relative).decode().split()[0]
            if actual == expected:
                return "file:///data/user/0/" + self.package + "/" + relative
        except RuntimeError:
            pass
        self.shell("run-as", self.package, "mkdir", "-p", "files/fixtures")
        transfer = shlex.join(["run-as", self.package, "sh", "-c", "cat > " + shlex.quote(relative)])
        self.command("exec-in", transfer, data=fixture.read_bytes())
        # exec-in can close its transport before the device-side cat has finished
        # draining a large fixture. Wait for its complete hash before playback.
        deadline = time.monotonic() + 15
        while True:
            actual = self.shell("run-as", self.package, "sha256sum", relative).decode().split()[0]
            if actual == expected or time.monotonic() >= deadline:
                break
            time.sleep(.15)
        assert actual == expected, "Fixture bytes changed during transfer"
        return "file:///data/user/0/" + self.package + "/" + relative


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--adb", default="adb")
    parser.add_argument("--serial", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--fixtures", type=Path, default=Path("build/output/video-pip/fixtures"))
    parser.add_argument("--mode", choices=("smoke",), default="smoke")
    args = parser.parse_args()
    device = Device(args.adb, args.serial, args.output)
    initial = device.read("capabilities_latest.json")
    assert initial and initial["xr"]["initialized"] and initial["xr"]["viewport_use_xr"], "Normal XR launcher required"
    assert initial["xr"]["head_has_tracking_data"], "A live head pose is required"
    original = initial["video_layout"]["pip"]["preferences"]
    summary = {"mode": args.mode, "original_zoom": original, "state": "running"}
    changed_zoom = False
    (args.output / "summary.json").write_text(json.dumps(summary, indent=2))
    try:
        receipt = device.send("close")
        device.wait(receipt, "00-closed", lambda r: r["media"]["state"] == "closed")
        time.sleep(.5)
        uri = device.upload(args.fixtures / "pip_identity_sbs.mp4")
        receipt = device.send("open", uri=uri, title="pip_identity_sbs.mp4", benchmark=True, projection=0,
                              stereo=True, enabled=False, depth=False, loop=True, layer=True)
        device.wait(receipt, "01-open-flat", lambda r: r["media"]["frame_counter"] >= 3 and r["layout"]["video_layer"]["shown"])
        device.send("hide_menus")
        report = device.probe("02-flat-three", "count", value=3,
                              predicate=lambda r: len(r["layout"]["pip"]["windows"]) == 3 and all(w["on_layer"] for w in r["layout"]["pip"]["windows"]))
        assert report["layout"]["video_layer"]["surface"] and report["layout"]["pip"]["atlas"] == [0, 0], "Flat crops must keep the decoder Surface"
        for step in ("move", "resize", "pick"):
            device.probe("03-flat-" + step, step, slot=1)
        changed_zoom = True
        device.probe("04-zoom", "zoom", slot=2, value=3., predicate=lambda r: r["layout"]["pip"]["preferences"]["2"] == 3.)
        device.probe("05-close-first", "close", slot=1, predicate=lambda r: [w["slot"] for w in r["layout"]["pip"]["windows"]] == [2, 3])
        device.probe("06-fill-first", "count", value=3, predicate=lambda r: sorted(w["slot"] for w in r["layout"]["pip"]["windows"]) == [1,2,3])
        device.probe("07-vr180", "format", projection=1, layout=1,
                     predicate=lambda r: r["layout"]["geometry"] == "half_equirect_180" and len(r["layout"]["pip"]["layers"]) == 3 and r["layout"]["pip"]["atlas"][0] > 0)
        receipt = device.send("playing", enabled=False)
        device.wait(receipt,"08-paused",lambda r:r["native_status"]["details"].get("paused")=="yes")
        sampled = device.probe("09-native-samples", "samples", predicate=lambda r: len(r["layout"]["pip"]["samples"].split()) == 18)
        assert sampled["layout"]["video_layer"]["shown"] and sampled["layout"]["pip"]["main_ready"], "Opaque 180 main must use its processed compositor image for this small fixture"
        main_samples = list(map(int, sampled["layout"]["pip"]["main_samples"].split()))
        assert len(main_samples) == 12, main_samples
        assert main_samples[2] > main_samples[4] + 30 and main_samples[10] > main_samples[8] + 30, main_samples
        assert main_samples[5] > 245 and main_samples[11] > 245, main_samples
        samples = list(map(int, sampled["layout"]["pip"]["samples"].split()))
        for offset in range(0,len(samples),6):
            slot,eye,red,green,blue,alpha=samples[offset:offset+6]
            assert eye == 0 and alpha > 245 and red > blue + 30, (slot,eye,red,green,blue,alpha)
        summary["state"] = "passed"
        summary["flat_surface_kept"] = True
        summary["native_mono_samples"] = samples
        summary["vr_main_compositor"] = True
        summary["native_stereo_main_samples"] = main_samples
        summary["gpu_metrics"] = sampled["layout"]["pip"]["metrics"]
    except BaseException as error:
        summary["state"] = "failed"; summary["error"] = str(error)
        raise
    finally:
        cleanup_errors = []
        if changed_zoom:
            try:
                device.probe("10-restore-windows", "count", value=3)
                for slot, zoom in original.items():
                    device.probe("10-restore-zoom-" + str(slot), "zoom", slot=int(slot), value=float(zoom))
                summary["zoom_restored"] = True
            except Exception as error:
                cleanup_errors.append("restore zoom: " + str(error))
        try:
            receipt = device.send("close")
            device.wait(receipt, "11-closed", lambda r: r["media"]["state"] == "closed")
        except Exception as error:
            cleanup_errors.append("close test playback: " + str(error))
        if cleanup_errors:
            summary["cleanup_errors"] = cleanup_errors
            if summary["state"] == "passed": summary["state"] = "cleanup_failed"
        (args.output / "summary.json").write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary, indent=2))
    if summary["state"] != "passed": raise SystemExit(1)


if __name__ == "__main__":
    main()
