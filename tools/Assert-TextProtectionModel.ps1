param([string]$Workspace = '', [string]$ModelRoot = '')
$ErrorActionPreference = 'Stop'
if (-not $Workspace) { $Workspace = Split-Path -Parent $PSScriptRoot }
$manifest = Get-Content -LiteralPath (Join-Path $Workspace 'third_party/text-protection/model.json') -Raw | ConvertFrom-Json
if (-not $ModelRoot) { $ModelRoot = Join-Path $Workspace ('models/text-protection/' + $manifest.id) }
foreach ($file in $manifest.files.PSObject.Properties) {
    if ($file.Name -match '(^/|\\|(^|/)\.\.(/|$)|:)') { throw 'Unsafe text detection model filename.' }
    $model = Join-Path $ModelRoot $file.Name
    if (-not (Test-Path -LiteralPath $model -PathType Leaf)) { throw "Missing Tiny text detector: $model. Run tools/environment/Prepare-TextProtection.ps1." }
    if ((Get-Item -LiteralPath $model).Length -ne $file.Value.bytes) { throw "Tiny text detector size differs: $model" }
    if ((Get-FileHash -LiteralPath $model -Algorithm SHA256).Hash.ToLowerInvariant() -ne $file.Value.sha256) { throw "Tiny text detector digest differs: $model" }
}
