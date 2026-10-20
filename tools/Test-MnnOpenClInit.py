"""Exercise patched MNN initialization with a rejecting OpenCL driver (no headset).

Pass --mnn-source to the pristine 3.6.1 tree. All generated files stay in build/.
The C++ fixture compiles the production blocks verbatim, not a copied algorithm.
"""
import argparse
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--mnn-source', type=Path, required=True)
    parser.add_argument('--baseline', action='store_true', help='Run unpatched blocks; regression failures are expected.')
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    output = root / 'build/output/quest2-ai-opencl' / ('baseline' if args.baseline else 'host')
    output.mkdir(parents=True, exist_ok=True)
    spec = importlib.util.spec_from_file_location('mnn_patch', root / 'tools/mnn/patch_mnn_vrpp.py')
    patch = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(patch)
    runtime = output / 'OpenCLRuntime.cpp'
    shutil.copyfile(args.mnn_source / 'source/backend/opencl/core/runtime/OpenCLRuntime.cpp', runtime)
    if not args.baseline:
        patch.patch_opencl_initialization(runtime)
    text = runtime.read_text(encoding='utf-8')
    blocks = {
        'diagnostics': ('static thread_local std::string vrppClInitializationError;', 'static std::weak_ptr'),
        'context_queue': ('            const std::string extensions = platforms[' + ('0]' if args.baseline else 'platformId]'), '            mFirstGPUDevicePtr->getInfo(CL_DEVICE_GLOBAL_MEM_CACHE_SIZE'),
        'recording': ('#if !defined(ENABLE_OPENCL_TIME_PROFILER) && defined(MNN_USE_LIB_WRAPPER)', '\n#endif'),
    }
    for name, (start, end) in blocks.items():
        if name == 'diagnostics' and args.baseline:
            (output / 'opencl_initialization_diagnostics.inc').write_text('static thread_local std::string vrppClInitializationError;\n', encoding='utf-8')
            continue
        first = text.index(start)
        last = text.index(end, first)
        if name == 'recording':
            last += len(end)
        (output / f'opencl_initialization_{name}.inc').write_text(text[first:last], encoding='utf-8')
    source = root / 'tests/native/mnn_opencl_init_test.cpp'
    executable = output / ('mnn_opencl_init_test.exe' if os.name == 'nt' else 'mnn_opencl_init_test')
    if os.name == 'nt':
        vcvars = Path('C:/Program Files (x86)/Microsoft Visual Studio/2022/BuildTools/VC/Auxiliary/Build/vcvars64.bat')
        command = output / 'compile.cmd'
        command.write_text(f'@echo off\ncall "{vcvars}" >nul 2>nul\nif errorlevel 1 exit /b 1\n'
                           f'cl /nologo /std:c++17 /EHsc /W4 /WX /I"{output}" /Fo"{output / "test.obj"}" /Fe"{executable}" "{source}"\n', encoding='utf-8')
        subprocess.run(['cmd', '/d', '/c', str(command)], check=True)
    else:
        subprocess.run([os.environ.get('CXX', 'c++'), '-std=c++17', '-Wall', '-Wextra', '-Werror', '-I', str(output), str(source), '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True)


if __name__ == '__main__':
    main()
