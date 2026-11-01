# Pinned Tiny model only. Keep the verified weights outside Git in a persistent model directory.
param([string]$ModelRoot = '')
$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$manifest = Get-Content -LiteralPath (Join-Path $workspace 'third_party/text-protection/model.json') -Raw | ConvertFrom-Json
if (-not $ModelRoot) { $ModelRoot = Join-Path $workspace ('models/text-protection/' + $manifest.id) }
New-Item -ItemType Directory -Force -Path $ModelRoot | Out-Null
foreach ($file in $manifest.files.PSObject.Properties) {
    if ($file.Name -match '(^/|\\|(^|/)\.\.(/|$)|:)') { throw 'Unsafe text detection model filename.' }
    $target = Join-Path $ModelRoot $file.Name
    & "$PSScriptRoot/Download-Artifact.ps1" -Uri $manifest.url -Destination $target -Sha256 $file.Value.sha256
    if ((Get-Item -LiteralPath $target).Length -ne $file.Value.bytes) { throw 'Text detector model size differs.' }
}
Write-Output 'Pinned PP-OCRv6 Tiny video text detector prepared.'
