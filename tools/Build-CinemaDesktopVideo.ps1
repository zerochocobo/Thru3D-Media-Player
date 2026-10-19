[CmdletBinding()]
param([switch]$Offline, [switch]$DependenciesPrepared)
$ErrorActionPreference = 'Stop'
$taskRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$recordRoot = Join-Path $taskRoot 'third_party/desktop-video'
$sourceLock = Get-Content -LiteralPath (Join-Path $recordRoot 'native-build-lock.json') -Raw | ConvertFrom-Json
$buildInputs = Get-Content -LiteralPath (Join-Path $recordRoot 'native-build-inputs.json') -Raw | ConvertFrom-Json
$publisher = Get-Content -LiteralPath (Join-Path $recordRoot 'manifest.json') -Raw | ConvertFrom-Json
$runtimeRoot = Join-Path $taskRoot 'build/desktop-video/runtime-patched'
$cacheRoot = Join-Path $taskRoot 'tmp/desktop-video'
$sourceRoot = Join-Path $cacheRoot 'native-sources'

function Get-Sha([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Test-Pinned([string]$Path, [string]$Hash, [long]$Bytes = -1) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    if ($Bytes -ge 0 -and (Get-Item -LiteralPath $Path).Length -ne $Bytes) { return $false }
    return (Get-Sha $Path) -eq $Hash
}
if (-not $DependenciesPrepared) {
    & (Join-Path $PSScriptRoot 'Prepare-CinemaDesktopVideo.ps1') -DependenciesOnly -Offline:$Offline | Out-Null
}
$fingerprintParts = foreach ($name in @('manifest.json', 'native-build-inputs.json', 'native-build-lock.json', 'native-fixes.patch', 'build_native_patch.py')) {
    $name + ':' + (Get-Sha (Join-Path $recordRoot $name))
}
$fingerprintParts += 'Build-CinemaDesktopVideo.ps1:' + (Get-Sha $PSCommandPath)
$fingerprintBytes = [Text.Encoding]::UTF8.GetBytes(($fingerprintParts -join "`n"))
$hasher = [Security.Cryptography.SHA256]::Create()
try { $fingerprint = [BitConverter]::ToString($hasher.ComputeHash($fingerprintBytes)).Replace('-', '').ToLowerInvariant() } finally { $hasher.Dispose() }
if ((Get-Sha (Join-Path $recordRoot 'native-fixes.patch')) -ne $sourceLock.patch_sha256) { throw 'Pinned native patch hash mismatch.' }
if (-not (Test-Pinned (Join-Path $recordRoot 'LICENSE-godot-cpp.txt') $sourceLock.godot_cpp_license_sha256)) { throw 'Pinned Godot C++ binding license hash mismatch.' }
New-Item -ItemType Directory -Path $runtimeRoot -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $recordRoot 'LICENSE-godot-cpp.txt') -Destination (Join-Path $runtimeRoot 'LICENSE-godot-cpp.txt') -Force
$preparedPath = Join-Path $runtimeRoot 'prepared.json'
if (Test-Path -LiteralPath $preparedPath) {
    try {
        $cached = Get-Content -LiteralPath $preparedPath -Raw | ConvertFrom-Json
        $validCache = $cached.fingerprint -eq $fingerprint -and $cached.source_commit -eq $sourceLock.source_commit -and
            $cached.publisher_asset_sha256 -eq $publisher.asset_sha256 -and $cached.abi -eq $buildInputs.abi -and
            (Test-Pinned (Join-Path $runtimeRoot 'win64/FFmpegPlayer.dll') $cached.dll_sha256 $cached.dll_bytes) -and
            (Test-Pinned (Join-Path $runtimeRoot 'FFmpegPlayer.gdextension') $cached.extension_sha256)
        foreach ($file in $publisher.files) {
            if ($file.name -ne 'FFmpegPlayer.dll') { $validCache = $validCache -and (Test-Pinned (Join-Path (Join-Path $runtimeRoot 'win64') $file.name) $file.sha256 $file.bytes) }
        }
        if ($validCache) { $cached | ConvertTo-Json -Depth 6; return }
    } catch { Write-Verbose 'Rebuilding an invalid desktop native cache.' }
}

New-Item -ItemType Directory -Path $cacheRoot, $sourceRoot, $runtimeRoot -Force | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem
foreach ($archive in $buildInputs.archives) {
    $archivePath = Join-Path $cacheRoot $archive.name
    if (-not (Test-Path -LiteralPath $archivePath)) {
        if ($Offline) { throw "Pinned source archive is missing: $($archive.name)" }
        if (-not $archive.url.StartsWith('https://codeload.github.com/')) { throw 'Native sources must use the pinned primary HTTPS source.' }
        Invoke-WebRequest -Uri $archive.url -OutFile $archivePath -TimeoutSec 180
    }
    if (-not (Test-Pinned $archivePath $archive.sha256 $archive.bytes)) { throw "Pinned native source archive mismatch: $($archive.name)" }
    $zip = [IO.Compression.ZipFile]::OpenRead($archivePath)
    try {
        foreach ($entry in $zip.Entries) {
            if (-not $entry.FullName.StartsWith($archive.prefix) -or $entry.FullName.EndsWith('/')) { continue }
            $destination = [IO.Path]::GetFullPath((Join-Path $sourceRoot $entry.FullName))
            if (-not $destination.StartsWith(([IO.Path]::GetFullPath($sourceRoot) + [IO.Path]::DirectorySeparatorChar), [StringComparison]::OrdinalIgnoreCase)) { throw 'Native source archive path escapes its cache.' }
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination)) | Out-Null
            $inputStream = $entry.Open()
            try { $outputStream = [IO.File]::Create($destination); try { $inputStream.CopyTo($outputStream) } finally { $outputStream.Dispose() } } finally { $inputStream.Dispose() }
        }
    } finally { $zip.Dispose() }
}
$compiler = Get-Command cl.exe -ErrorAction Stop
$msvcRoot = (Get-Item -LiteralPath $compiler.Source).Directory.Parent.Parent.Parent.FullName
$sdkRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits/10'
$sdkVersion = Get-ChildItem -LiteralPath (Join-Path $sdkRoot 'Include') -Directory | Where-Object { $_.Name -match '^\d+\.\d+\.\d+\.\d+$' } | Sort-Object { [version]$_.Name } | Select-Object -Last 1 -ExpandProperty Name
if (-not $sdkVersion) { throw 'Windows SDK required for the desktop decoder build was not found.' }
$sdkTools = Join-Path $sdkRoot "bin/$sdkVersion/x64"
$python = Join-Path $env:USERPROFILE '.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe'
if (-not (Test-Path -LiteralPath $python)) { $python = (Get-Command python.exe -ErrorAction Stop).Source }
$oldPath = $env:PATH; $oldLib = $env:LIB; $oldInclude = $env:INCLUDE
$logPath = Join-Path $taskRoot 'build/desktop-video/native-patch-build.log'
try {
    $env:PATH = "$sdkTools;$($compiler.Path | Split-Path -Parent);" + $oldPath
    $env:LIB = "$msvcRoot/lib/x64;$sdkRoot/Lib/$sdkVersion/um/x64;$sdkRoot/Lib/$sdkVersion/ucrt/x64"
    $env:INCLUDE = "$msvcRoot/include;$sdkRoot/Include/$sdkVersion/ucrt;$sdkRoot/Include/$sdkVersion/shared;$sdkRoot/Include/$sdkVersion/um;$sdkRoot/Include/$sdkVersion/winrt"
    $env:CINEMA_NATIVE_SDK_TOOLS = $sdkTools
    & $python -B (Join-Path $recordRoot 'build_native_patch.py') *> $logPath
    if ($LASTEXITCODE -ne 0) { throw "Desktop native decoder build failed. See $logPath" }
} finally { $env:PATH = $oldPath; $env:LIB = $oldLib; $env:INCLUDE = $oldInclude; Remove-Item Env:CINEMA_NATIVE_SDK_TOOLS -ErrorAction SilentlyContinue }
$dllPath = Join-Path $runtimeRoot 'win64/FFmpegPlayer.dll'
$result = [ordered]@{
    runtime_directory = $runtimeRoot
    extension_path = (Join-Path $runtimeRoot 'FFmpegPlayer.gdextension').Replace('\', '/')
    class_name = 'VideoStreamFFmpeg'
    fingerprint = $fingerprint
    source_commit = $sourceLock.source_commit
    godot_cpp_commit = $sourceLock.godot_cpp_commit
    ffmpeg_headers_commit = $sourceLock.ffmpeg_headers_commit
    publisher_asset_sha256 = $publisher.asset_sha256
    source_archives = @($buildInputs.archives | Select-Object name,sha256)
    patch_sha256 = $sourceLock.patch_sha256
    abi = $buildInputs.abi
    ffmpeg_abi = $buildInputs.ffmpeg_abi
    dll_sha256 = Get-Sha $dllPath
    dll_bytes = (Get-Item -LiteralPath $dllPath).Length
    extension_sha256 = Get-Sha (Join-Path $runtimeRoot 'FFmpegPlayer.gdextension')
    godot_runtime_verified = $false
}
$resultJson = $result | ConvertTo-Json -Depth 6
[IO.File]::WriteAllText($preparedPath, $resultJson + "`n", [Text.UTF8Encoding]::new($false))
$resultJson
