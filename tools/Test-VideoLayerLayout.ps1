$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$out = Join-Path $workspace 'build/video-layer-layout-test'
New-Item -ItemType Directory -Path $out -Force | Out-Null
$vcvars = 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat'
$source = Join-Path $workspace 'tests/native/layer_layout_test.cpp'
$include = Join-Path $workspace 'third_party/openxr/include'
$binary = Join-Path $out 'layer_layout_test.exe'
$ErrorActionPreference = 'Continue'
cmd /c "`"$vcvars`" >nul 2>nul && cl /nologo /std:c++17 /O2 /EHsc /W4 /WX /I`"$include`" /Fo`"$out\\`" /Fe`"$binary`" `"$source`""
if ($LASTEXITCODE -ne 0) { throw 'Video layer layout test build failed.' }
$ErrorActionPreference = 'Stop'
& $binary
if ($LASTEXITCODE -ne 0) { throw 'Video layer layout test failed.' }
