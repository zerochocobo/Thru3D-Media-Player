param([string]$SourceDirectory = '')
$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$manifest = Get-Content -LiteralPath (Join-Path $workspace 'third_party/narration/model.json') -Raw | ConvertFrom-Json
if ($manifest.id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { throw 'Unsafe model id.' }
$destination = Join-Path $workspace ('models/narration/' + $manifest.id)
if (-not $SourceDirectory) { $SourceDirectory = $env:THRU3D_NARRATION_MODEL_SOURCE }
if (-not $SourceDirectory) { $SourceDirectory = $destination }
foreach ($entry in $manifest.files.PSObject.Properties) {
    if ($entry.Name -match '(^/|\\|(^|/)\.\.(/|$)|:)') { throw 'Unsafe model manifest path.' }
    $target = Join-Path $destination $entry.Name
    $valid = (Test-Path -LiteralPath $target -PathType Leaf) -and (Get-Item -LiteralPath $target).Length -eq $entry.Value.bytes
    if ($valid) { $valid = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() -eq $entry.Value.sha256 }
    if ($valid) { continue }
    $source = Join-Path $SourceDirectory $entry.Name
    if (-not (Test-Path -LiteralPath $source -PathType Leaf) -or
        (Get-Item -LiteralPath $source).Length -ne $entry.Value.bytes -or
        (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant() -ne $entry.Value.sha256) {
        throw "Missing verified narration payload: $($entry.Name). Set THRU3D_NARRATION_MODEL_SOURCE or pass -SourceDirectory to a verified bundle."
    }
    New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
    Copy-Item -LiteralPath $source -Destination $target -Force
    if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() -ne $entry.Value.sha256) { throw 'Narration model copy differs.' }
}
Write-Output "Verified bundled narration models: $(@($manifest.files.PSObject.Properties).Count) files in models/narration/$($manifest.id)."
& (Join-Path $PSScriptRoot 'Prepare-VoiceCloneModels.ps1')
