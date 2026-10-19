[CmdletBinding()]
param([switch]$Offline, [switch]$DependenciesOnly)

$ErrorActionPreference = 'Stop'
$taskRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$recordRoot = Join-Path $taskRoot 'third_party/desktop-video'
$record = Get-Content -LiteralPath (Join-Path $recordRoot 'manifest.json') -Raw | ConvertFrom-Json
if ($record.schema_version -ne 1 -or $record.platform -ne 'windows.x86_64') {
    throw 'Unsupported desktop video dependency record.'
}
$cacheRoot = Join-Path $taskRoot 'tmp/desktop-video'
$runtimeRoot = Join-Path $taskRoot 'build/desktop-video/runtime'
$archivePath = Join-Path $cacheRoot $record.asset_name
New-Item -ItemType Directory -Path $cacheRoot, (Join-Path $runtimeRoot 'win64') -Force | Out-Null

function Assert-PinnedFile([string]$Path, [string]$ExpectedHash, [long]$ExpectedBytes = -1) {
    $item = Get-Item -LiteralPath $Path
    if ($ExpectedBytes -ge 0 -and $item.Length -ne $ExpectedBytes) {
        throw "Dependency size mismatch: $Path"
    }
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $ExpectedHash) { throw "Dependency SHA-256 mismatch: $Path" }
}

if (-not (Test-Path -LiteralPath $archivePath)) {
    if ($Offline) { throw "Pinned publisher archive is missing: $archivePath" }
    if (-not $record.asset_url.StartsWith('https://github.com/KirbyKid256/FFmpegPlayer/releases/download/v1.0.1/')) {
        throw 'The desktop video archive must come from the pinned publisher release.'
    }
    # Default platform TLS verification stays enabled. No certificate callbacks,
    # trust-store mutations, system installation, or project-addon registration.
    Invoke-WebRequest -Uri $record.asset_url -OutFile $archivePath -TimeoutSec 180
}
Assert-PinnedFile $archivePath $record.asset_sha256 $record.asset_bytes

Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [System.IO.Compression.ZipFile]::OpenRead($archivePath)
try {
    # Extract only the pinned Windows whitelist, never arbitrary ZIP paths.
    foreach ($file in $record.files) {
        if ($file.name -notmatch '^[A-Za-z0-9_-]+\.dll$' -or $file.archive_entry -ne ('ffmpegplayer/win64/' + $file.name)) {
            throw 'Invalid pinned Windows file entry.'
        }
        $entry = $archive.GetEntry($file.archive_entry)
        if (-not $entry -or $entry.Length -ne $file.bytes) { throw "Missing or invalid archive entry: $($file.name)" }
        $destination = Join-Path (Join-Path $runtimeRoot 'win64') $file.name
        # A running desktop player holds its DLLs open. Preserve verified copies
        # instead of overwriting them whenever the launcher prepares the runtime.
        $alreadyPinned = $false
        if (Test-Path -LiteralPath $destination -PathType Leaf) {
            $existing = Get-Item -LiteralPath $destination
            $alreadyPinned = $existing.Length -eq $file.bytes -and
                (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant() -eq $file.sha256
        }
        if (-not $alreadyPinned) {
            $source = $entry.Open()
            try {
                $target = [System.IO.File]::Create($destination)
                try { $source.CopyTo($target) } finally { $target.Dispose() }
            } finally { $source.Dispose() }
        }
        Assert-PinnedFile $destination $file.sha256 $file.bytes
        $reader = [System.IO.BinaryReader]::new([System.IO.File]::OpenRead($destination))
        try {
            $reader.BaseStream.Position = 0x3C
            $peOffset = $reader.ReadUInt32()
            $reader.BaseStream.Position = $peOffset
            if ($reader.ReadUInt32() -ne 0x00004550 -or $reader.ReadUInt16() -ne 0x8664) {
                throw "Expected an AMD64 PE library: $destination"
            }
        } finally { $reader.Dispose() }
    }
} finally { $archive.Dispose() }

foreach ($license in $record.licenses) {
    $licenseSource = Join-Path $recordRoot $license.name
    Assert-PinnedFile $licenseSource $license.sha256
    Copy-Item -LiteralPath $licenseSource -Destination (Join-Path $runtimeRoot $license.name) -Force
}

$libraryPath = (Join-Path (Join-Path $runtimeRoot 'win64') 'FFmpegPlayer.dll').Replace('\', '/')
$dependencyEntries = @()
foreach ($file in $record.files) {
    if ($file.name -eq 'FFmpegPlayer.dll') { continue }
    $path = (Join-Path (Join-Path $runtimeRoot 'win64') $file.name).Replace('\', '/')
    $dependencyEntries += ('"' + $path + '": ""')
}
$extensionLines = @(
    '[configuration]',
    'entry_symbol = "ffmpeg_init"',
    'compatibility_minimum = "4.1"',
    '',
    '[libraries]',
    ('windows.x86_64 = "' + $libraryPath + '"'),
    '',
    '[dependencies]',
    ('windows.x86_64 = {' + ($dependencyEntries -join ', ') + '}')
)
$extensionPath = Join-Path $runtimeRoot 'FFmpegPlayer.gdextension'
[System.IO.File]::WriteAllText($extensionPath, ($extensionLines -join "`n") + "`n", [System.Text.UTF8Encoding]::new($false))
$result = [ordered]@{
    runtime_directory = $runtimeRoot
    extension_path = $extensionPath.Replace('\', '/')
    class_name = $record.class_name
    asset_sha256 = $record.asset_sha256
    source_commit = $record.source_commit
    publisher_digest = $record.publisher_digest
    windows_dlls_verified = @($record.files).Count
    godot_runtime_verified = $false
}
$resultJson = $result | ConvertTo-Json -Depth 3
[System.IO.File]::WriteAllText((Join-Path $runtimeRoot 'prepared.json'), $resultJson + "`n", [System.Text.UTF8Encoding]::new($false))
if ($DependenciesOnly) {
    $resultJson
} else {
    # The upstream decoder has known native lifetime/null-stream defects. The
    # desktop entry must never silently fall back to its unpatched plugin DLL.
    & (Join-Path $PSScriptRoot 'Build-CinemaDesktopVideo.ps1') -Offline:$Offline -DependenciesPrepared
}
