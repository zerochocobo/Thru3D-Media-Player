param([string]$SourceDirectory = '')
$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$manifest = Get-Content -LiteralPath (Join-Path $workspace 'third_party/narration/clone_model.json') -Raw | ConvertFrom-Json
if ($manifest.id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { throw 'Unsafe voice encoder model id.' }
$destination = Join-Path $workspace ('models/narration/' + $manifest.id)
if (-not $SourceDirectory) { $SourceDirectory = $env:THRU3D_NARRATION_CLONE_SOURCE }
foreach ($entry in $manifest.files.PSObject.Properties) {
    if ($entry.Name -notmatch '^[A-Za-z0-9_.-]+$') { throw 'Unsafe voice encoder model path.' }
    $target = Join-Path $destination $entry.Name
    $valid = (Test-Path -LiteralPath $target -PathType Leaf) -and (Get-Item -LiteralPath $target).Length -eq $entry.Value.bytes
    if ($valid) { $valid = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() -eq $entry.Value.sha256 }
    if ($valid) { continue }
    if (-not $SourceDirectory) { throw 'Missing verified voice encoder. Set THRU3D_NARRATION_CLONE_SOURCE or pass -SourceDirectory.' }
    $source = Join-Path $SourceDirectory $entry.Name
    if (-not (Test-Path -LiteralPath $source -PathType Leaf) -or (Get-Item -LiteralPath $source).Length -ne $entry.Value.bytes -or
        (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant() -ne $entry.Value.sha256) { throw "Missing verified voice encoder payload: $($entry.Name)" }
    New-Item -ItemType Directory -Path $destination -Force | Out-Null
    Copy-Item -LiteralPath $source -Destination $target -Force
    if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() -ne $entry.Value.sha256) { throw 'Voice encoder copy differs.' }
}
Write-Output 'Verified bundled voice reference encoder: 2 files.'
