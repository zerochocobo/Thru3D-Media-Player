"""Compile production comic/plugin sources and run host speech tests, without Gradle,
APK/AAR packaging, native rebuilding, model inference, or device access. Uses cached dependencies.
"""
from pathlib import Path
import json
import os
import subprocess
import zipfile


def main():
    root = Path(__file__).resolve().parent.parent
    toolroot = Path(os.environ.get('THRU3D_TOOL_ROOT', str(Path.home() / '.cache/thru3d-toolchain')))
    cache = toolroot / 'gradle-cache/caches/modules-2/files-2.1'
    output = root / 'build/output/comic-reader-20261025/android-host'
    output.mkdir(parents=True, exist_ok=True)

    def jar(group, name, version='*'):
        return sorted((cache / group / name).glob(version + '/*/' + name + '-*.jar'))[-1]

    def aar_classes(archive, name):
        target = output / (name + '.jar')
        with zipfile.ZipFile(archive) as z:
            target.write_bytes(z.read('classes.jar'))
        return target

    stdlib = jar('org.jetbrains.kotlin', 'kotlin-stdlib', '2.1.21')
    compiler = [jar('org.jetbrains.kotlin', 'kotlin-compiler-embeddable', '2.1.21'), stdlib,
                jar('org.jetbrains.kotlin', 'kotlin-script-runtime', '2.1.21'), jar('org.jetbrains.kotlin', 'kotlin-reflect'),
                jar('org.jetbrains.intellij.deps', 'trove4j'), jar('org.jetbrains', 'annotations'),
                jar('org.jetbrains.kotlinx', 'kotlinx-coroutines-core-jvm')]
    junit = jar('junit', 'junit', '4.13.2')
    hamcrest = jar('org.hamcrest', 'hamcrest-core', '1.3')
    android = toolroot / 'android-sdk/platforms/android-36/android.jar'
    java = toolroot / 'jdk/jdk-17.0.20.1+1/bin/java.exe'
    baseline = root / 'android/player-plugin/build/intermediates/compile_library_classes_jar/debug/bundleLibCompileToJarDebug/classes.jar'
    if not baseline.is_file():
        raise RuntimeError('Existing plugin compile classes required; this host check never builds a replacement AAR.')
    godot = aar_classes(toolroot / 'godot-android-api/4.7.2/godot-lib.template_debug.aar', 'godot-api')
    # Required supertypes of Godot and existing plugin signatures; read cached AARs only.
    extras = []
    for group, name in [('androidx.media3', 'media3-common'), ('androidx.fragment', 'fragment'),
                        ('androidx.activity', 'activity'), ('androidx.lifecycle', 'lifecycle-viewmodel'),
                        ('androidx.lifecycle', 'lifecycle-runtime'), ('androidx.lifecycle', 'lifecycle-livedata-core'),
                        ('androidx.savedstate', 'savedstate'), ('androidx.core', 'core')]:
        archives = sorted((cache / group / name).glob('*/*/*.aar'))
        if archives:
            extras.append(aar_classes(archives[-1], name))
    extras += [jar('androidx.lifecycle', 'lifecycle-common'), jar('org.jetbrains', 'annotations')]
    cp = [android, stdlib, baseline, godot, junit, hamcrest, *extras]
    package = Path('org/vrpassthroughplayer/plugin')
    source = root / 'android/player-plugin/src/main/java' / package
    tests = root / 'android/player-plugin/src/test/java' / package
    changed = ['ComicSpeechRouting', 'ComicSpeechPrefetch', 'ComicOcrNative', 'ComicReaderController', 'ComicNarrationSession', 'MpvVideoBridge', 'QuestPlayerPlugin', 'SharedNarrationEngine', 'NarrationNative', 'NarrationPolicy', 'NarrationRhythm', 'NarrationLevel', 'VoicePreviewStream']
    test_names = [name for name in ['ComicSpeechRoutingTest', 'ComicSpeechPrefetchTest', 'ComicNarrationSessionTest', 'SharedNarrationEngineTest'] if (tests / (name + '.kt')).exists()]
    sources = [source / (name + '.kt') for name in changed] + [tests / (name + '.kt') for name in test_names]
    classes = output / 'comic-reader-check.jar'
    args = ['-no-stdlib', '-no-reflect', '-jvm-target', '17', '-Xfriend-paths=' + str(baseline),
            '-classpath', os.pathsep.join(map(str, cp)), '-d', str(classes), *map(str, sources)]
    arguments = output / 'compiler.args'
    arguments.write_text('\n'.join('"' + arg.replace('\\', '/') + '"' for arg in args), encoding='utf-8')

    def run(name, command):
        result = subprocess.run(list(map(str, command)), cwd=root, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, timeout=180)
        (output / (name + '.log')).write_bytes(result.stdout)
        if result.returncode:
            raise RuntimeError(name + ':\n' + result.stdout.decode('utf-8', 'replace'))
        return result.stdout.decode('utf-8', 'replace')

    run('compile', [java, '-cp', os.pathsep.join(map(str, compiler)), 'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler', '@' + str(arguments)])
    host = run('tests', [java, '-cp', os.pathsep.join(map(str, [classes, baseline, stdlib, junit, hamcrest, *extras,
                   jar('org.json', 'json', '20240303'), android])), 'org.junit.runner.JUnitCore',
                   *['org.vrpassthroughplayer.plugin.' + name for name in test_names]])
    (output / 'result.json').write_text(json.dumps({'compiled_production_sources': changed,
        'baseline_dependencies_only': str(baseline.relative_to(root)), 'host_tests': host.strip(),
        'scope': 'Source compilation and JVM tests only; Android AudioTrack/JNI/device not executed; fake synthesis backend verifies routing and cancellation; no APK/AAR or device operations'}, indent=2), encoding='utf-8')
    print(host.strip())


if __name__ == '__main__':
    main()
