param([string]$ToolRoot = $(if ($env:THRU3D_TOOL_ROOT) { $env:THRU3D_TOOL_ROOT } else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.cache\thru3d-toolchain' }))
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$out = Join-Path $workspace 'build/output/browser-focus/native-test'
New-Item -ItemType Directory -Force -Path $out | Out-Null
$vcvars = 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat'
$source = Join-Path $workspace 'tests/native/browser_layer_test.cpp'
$include = Join-Path $workspace 'third_party/openxr/include'
$jni = Join-Path $ToolRoot 'jdk/jdk-17.0.20.1+1/include'
$binary = Join-Path $out 'browser_layer_test.exe'
cmd /c "`"$vcvars`" >nul 2>nul && cl /nologo /std:c++17 /O2 /EHsc /W4 /WX /I`"$include`" /I`"$jni`" /I`"$jni/win32`" /Fo`"$out\\`" /Fe`"$binary`" `"$source`""
if ($LASTEXITCODE -ne 0) { throw 'Browser native layer test build failed.' }
& $binary
if ($LASTEXITCODE -ne 0) { throw 'Browser native layer test failed.' }
