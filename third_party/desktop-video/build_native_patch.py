import hashlib
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
CACHE = ROOT / 'tmp/desktop-video'
SOURCES = CACHE / 'native-sources'
ORIGINAL = SOURCES / 'FFmpegPlayer-987b76428774d21cf6542d5cda7d1cd09ebf2730/src'
SOURCE = CACHE / 'patched-source'
BUILD = ROOT / 'build/desktop-video/native-patch'
RUNTIME = ROOT / 'build/desktop-video/runtime-patched'
RECORD = ROOT / 'third_party/desktop-video'
GODOT = SOURCES / 'godot-cpp-4d5d707d60aac3ecb4d3e413c840448fb1356264'
FFMPEG = SOURCES / 'FFmpeg-b1a4534186ca51b0457579fc05a5739eb2cc45cd'
SOURCE.mkdir(parents=True, exist_ok=True)
BUILD.mkdir(parents=True, exist_ok=True)
(SOURCE / 'src').mkdir(exist_ok=True)
(RUNTIME / 'win64').mkdir(parents=True, exist_ok=True)
lock = json.loads((RECORD / 'native-build-lock.json').read_text(encoding='utf-8-sig'))
patch_path = RECORD / 'native-fixes.patch'
assert hashlib.sha256(patch_path.read_bytes()).hexdigest() == lock['patch_sha256'], 'Native patch hash mismatch'
patches = {}
lines = patch_path.read_text(encoding='utf-8').splitlines(True)
index = 0
while index < len(lines):
    assert lines[index].startswith('--- a/src/'), 'Invalid native patch header'
    name = lines[index].strip().removeprefix('--- a/src/')
    index += 1
    assert lines[index].strip() == '+++ b/src/' + name
    index += 1
    original_lines = (ORIGINAL / name).read_text(encoding='utf-8').splitlines(True)
    output = []
    cursor = 0
    while index < len(lines) and not lines[index].startswith('--- a/'):
        match = re.match(r'@@ -(\d+)(?:,\d+)? \+\d+(?:,\d+)? @@', lines[index])
        assert match, 'Invalid native patch hunk'
        start = int(match.group(1)) - 1
        assert start >= cursor
        output.extend(original_lines[cursor:start])
        cursor = start
        index += 1
        while index < len(lines) and not lines[index].startswith(('@@ ', '--- a/')):
            line = lines[index]
            index += 1
            prefix, payload = line[0], line[1:]
            if prefix in ' -':
                assert original_lines[cursor] == payload, 'Native patch source mismatch: ' + name
                cursor += 1
            if prefix in ' +':
                output.append(payload)
            assert prefix in ' +-'
    output.extend(original_lines[cursor:])
    patches[name] = ''.join(output)

for path in sorted(ORIGINAL.iterdir()):
    original = path.read_text(encoding='utf-8')
    assert hashlib.sha256(path.read_bytes()).hexdigest() == lock['source_sha256'][path.name], 'Pinned native source hash mismatch: ' + path.name
    text = patches.get(path.name, original)
    (SOURCE / 'src' / path.name).write_text(text, encoding='utf-8', newline='\n')
(FFMPEG / 'libavutil/avconfig.h').write_text('#ifndef AVUTIL_AVCONFIG_H\n#define AVUTIL_AVCONFIG_H\n#define AV_HAVE_BIGENDIAN 0\n#define AV_HAVE_FAST_UNALIGNED 1\n#endif\n', encoding='ascii')
libs = BUILD / 'import-libs'
libs.mkdir(exist_ok=True)
for name in ['avcodec-60', 'avformat-60', 'avutil-58', 'swresample-4', 'swscale-7']:
    dll = ROOT / 'build/desktop-video/runtime/win64' / (name + '.dll')
    dump = subprocess.check_output(['dumpbin', '/exports', str(dll)], text=True, errors='replace')
    names = re.findall(r'^\s+\d+\s+[A-F0-9]+\s+[A-F0-9]+\s+([A-Za-z_][A-Za-z_0-9]*)\s*$', dump, flags=re.M)
    assert names, name
    definition = libs / (name + '.def')
    definition.write_text('LIBRARY ' + name + '.dll\nEXPORTS\n' + '\n'.join(names) + '\n', encoding='ascii')
    subprocess.run(['lib', '/nologo', '/machine:x64', '/def:' + str(definition), '/out:' + str(libs / (name + '.lib'))], check=True)
    shutil.copy2(dll, RUNTIME / 'win64' / dll.name)

classes = lock['binding_classes']
cmake = f'''cmake_minimum_required(VERSION 3.20)
project(CinemaDesktopVideoPatch LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
add_subdirectory("{GODOT.as_posix()}" godot-cpp)
get_target_property(binding_sources godot-cpp SOURCES)
set(kept_sources)
foreach(source IN LISTS binding_sources)
  if(NOT source MATCHES "/gen/src/classes/" OR source MATCHES "/({'|'.join(classes)})\\.cpp$")
    list(APPEND kept_sources "${{source}}")
  endif()
endforeach()
set_property(TARGET godot-cpp PROPERTY SOURCES ${{kept_sources}})
file(GLOB plugin_sources "${{CMAKE_CURRENT_SOURCE_DIR}}/src/*.cpp")
add_library(FFmpegPlayer SHARED ${{plugin_sources}})
target_link_libraries(FFmpegPlayer PRIVATE godot::cpp)
target_compile_definitions(FFmpegPlayer PRIVATE NOMINMAX)
target_compile_options(FFmpegPlayer PRIVATE /utf-8 /EHsc)
target_include_directories(FFmpegPlayer PRIVATE "{FFMPEG.as_posix()}")
target_link_libraries(FFmpegPlayer PRIVATE {' '.join('"' + (libs / (n + '.lib')).as_posix() + '"' for n in ['avcodec-60','avformat-60','avutil-58','swresample-4','swscale-7'])})
set_target_properties(FFmpegPlayer PROPERTIES RUNTIME_OUTPUT_DIRECTORY "{(RUNTIME / 'win64').as_posix()}")
'''
(SOURCE / 'CMakeLists.txt').write_text(cmake, encoding='utf-8', newline='\n')
sdk_tools = pathlib.Path(os.environ['CINEMA_NATIVE_SDK_TOOLS'])
subprocess.run(['cmake', '-S', str(SOURCE), '-B', str(BUILD), '-G', 'Ninja', '-DCMAKE_BUILD_TYPE=Release', '-DCMAKE_RC_COMPILER=' + str(sdk_tools / 'rc.exe'), '-DCMAKE_MT=' + str(sdk_tools / 'mt.exe'), '-DPython3_EXECUTABLE=' + sys.executable], check=True)
subprocess.run(['cmake', '--build', str(BUILD), '--parallel', '8'], check=True)
for license in ['LICENSE-EIRTeam-gdextension.txt', 'LICENSE-ffmpeg.txt']:
    shutil.copy2(RECORD / license, RUNTIME / license)
extension = (ROOT / 'build/desktop-video/runtime/FFmpegPlayer.gdextension').read_text(encoding='utf-8').replace('/runtime/win64/', '/runtime-patched/win64/')
(RUNTIME / 'FFmpegPlayer.gdextension').write_text(extension, encoding='utf-8', newline='\n')
dll = RUNTIME / 'win64/FFmpegPlayer.dll'
print(json.dumps({'extension': str(RUNTIME / 'FFmpegPlayer.gdextension'), 'dll_sha256': hashlib.sha256(dll.read_bytes()).hexdigest(), 'dll_bytes': dll.stat().st_size, 'runtime_tested': False}, indent=2))
