param()
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$out = Join-Path $workspace 'build/output/frame-gpu-timing'
New-Item -ItemType Directory -Path $out -Force | Out-Null
$vcvars = 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat'
$source = Join-Path $workspace 'tests/native/frame_gpu_timing_test.cpp'
$binary = Join-Path $out 'frame_gpu_timing_test.exe'
cmd /c "`"$vcvars`" >nul 2>nul && cl /nologo /std:c++17 /O2 /EHsc /W4 /WX /Fo`"$out\\`" /Fe`"$binary`" `"$source`""
if ($LASTEXITCODE -ne 0) { throw 'Frame GPU timing test compilation failed.' }
& $binary
if ($LASTEXITCODE -ne 0) { throw 'Frame GPU timing regression failed.' }
