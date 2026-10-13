param([string]$ToolRoot = $(if ($env:THRU3D_TOOL_ROOT) { $env:THRU3D_TOOL_ROOT } else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.cache\thru3d-toolchain' }))
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$output = Join-Path $workspace 'build/pico-emulator-egl-test'
New-Item -ItemType Directory -Path $output -Force | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem
$template = [IO.Compression.ZipFile]::OpenRead((Join-Path $ToolRoot 'godot-templates/4.7.2.stable/android_source.zip'))
try {
    $entry = $template.GetEntry('libs/debug/godot-lib.template_debug.aar')
    [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, (Join-Path $output 'stock.aar'), $true)
} finally { $template.Dispose() }
$aar = [IO.Compression.ZipFile]::OpenRead((Join-Path $output 'stock.aar'))
try { [IO.Compression.ZipFileExtensions]::ExtractToFile($aar.GetEntry('classes.jar'), (Join-Path $output 'classes.jar'), $true) }
finally { $aar.Dispose() }
$classpath = (Join-Path $ToolRoot 'android-sdk/platforms/android-36/android.jar') + ';' + (Join-Path $output 'classes.jar')
$sources = @((Join-Path $workspace 'tools/environment/godot/OvrConfigChooser.java')) +
    @(Get-ChildItem -LiteralPath (Join-Path $workspace 'tests/godot_egl') -Recurse -Filter '*.java' | ForEach-Object FullName)
& (Join-Path $ToolRoot 'jdk/jdk-17.0.20.1+1/bin/javac.exe') -classpath $classpath -d $output @sources
if ($LASTEXITCODE -ne 0) { throw 'EGL chooser test compilation failed.' }
& (Join-Path $ToolRoot 'jdk/jdk-17.0.20.1+1/bin/java.exe') -cp ($output + ';' + $classpath) EglChooserTest
if ($LASTEXITCODE -ne 0) { throw 'EGL chooser regression failed.' }
