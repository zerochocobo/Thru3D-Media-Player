"""Compile the production listening controller and test finalized cue publication.

Uses cached Kotlin/plugin dependencies and a synthetic native-clock boundary.
No Gradle output is modified, and no model, APK, device, or personal media is used.
"""
from pathlib import Path
import argparse
import os
import subprocess
import json
import hashlib
import re


def main():
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=Path, help="Compiled plugin classes directory/jar matching this source snapshot")
    parser.add_argument("--output", type=Path, default=root / "build/output/listening-controller-host")
    args = parser.parse_args()
    output = args.output.resolve(); output.mkdir(parents=True, exist_ok=True)
    toolroot = Path(os.environ.get("THRU3D_TOOL_ROOT", str(Path.home() / ".cache/thru3d-toolchain")))
    cache = toolroot / "gradle-cache/caches/modules-2/files-2.1"

    def jar(group, name, version="*"):
        return sorted((cache / group / name).glob(version + "/*/" + name + "-*.jar"))[-1]

    kotlin_version = re.search(r"id 'org.jetbrains.kotlin.android' version '([^']+)'", (root / "android/settings.gradle").read_text(encoding="utf-8-sig")).group(1)
    stdlib = jar("org.jetbrains.kotlin", "kotlin-stdlib", kotlin_version)
    annotations = jar("org.jetbrains", "annotations")
    compiler = [jar("org.jetbrains.kotlin", "kotlin-compiler-embeddable", kotlin_version), stdlib,
                jar("org.jetbrains.kotlin", "kotlin-script-runtime", kotlin_version), jar("org.jetbrains.kotlin", "kotlin-reflect"),
                jar("org.jetbrains.intellij.deps", "trove4j"), annotations, jar("org.jetbrains.kotlinx", "kotlinx-coroutines-core-jvm")]
    android = toolroot / "android-sdk/platforms/android-36/android.jar"
    java = toolroot / "jdk/jdk-17.0.20.1+1/bin/java.exe"
    baseline = args.baseline or root / "android/player-plugin/build/intermediates/compile_library_classes_jar/debug/bundleLibCompileToJarDebug/classes.jar"
    if not baseline.exists():
        raise SystemExit("Build plugin classes first or pass --baseline for this source snapshot.")
    json_jar = jar("org.json", "json", "20240303")
    source = root / "android/player-plugin/src/main/java/org/vrpassthroughplayer/plugin/ListeningController.kt"
    probe = root / "tests/host/listening/ControllerProbe.kt"
    classes = output / "controller-check.jar"
    cp = [stdlib, annotations, baseline, json_jar, android]
    options = ["-no-stdlib", "-no-reflect", "-jvm-target", "17", "-Xfriend-paths=" + str(baseline),
               "-classpath", os.pathsep.join(map(str, cp)), "-d", str(classes), str(source), str(probe)]
    argfile = output / "compiler.args"
    argfile.write_text("\n".join('"' + arg.replace("\\", "/") + '"' for arg in options), encoding="utf-8")
    commands = [("compile", [java, "-cp", os.pathsep.join(map(str, compiler)), "org.jetbrains.kotlin.cli.jvm.K2JVMCompiler", "@" + str(argfile)]),
                ("probe", [java, "-cp", os.pathsep.join(map(str, [classes, *cp])), "org.vrpassthroughplayer.plugin.ControllerProbeKt", output])]
    (output / "sources.json").write_text(json.dumps({p.relative_to(root).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
        for p in [source, probe]}, indent=2), encoding="utf-8")
    for name, command in commands:
        result = subprocess.run(list(map(str, command)), cwd=root, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=90)
        (output / (name + ".log")).write_bytes(result.stdout)
        if result.returncode:
            print("\n".join(result.stdout.decode("utf-8", "replace").splitlines()[-35:])); raise SystemExit(result.returncode)
    print((output / "probe.log").read_text(encoding="utf-8"))


if __name__ == "__main__":
    main()
