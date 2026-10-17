param([string]$FromDirectory, [switch]$VerifyOnly)
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$destination = Join-Path $workspace 'app/godot/assets/audio'
$catalog = Get-Content (Join-Path $destination 'catalog.json') -Raw | ConvertFrom-Json
if ($catalog.schema_version -ne 1 -or @($catalog.assets).Count -ne 12) { throw 'Invalid built-in audio catalog.' }
if (-not $VerifyOnly -and -not $FromDirectory) { throw 'Supply licensed version-matched audio with -FromDirectory. See docs/AUDIO.md.' }
$source = if ($VerifyOnly) { $destination } else { (Resolve-Path -LiteralPath $FromDirectory).Path }
$names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($asset in $catalog.assets) {
    if ($asset.path -notmatch '^[a-z_]+\.ogg$' -or -not $names.Add($asset.path) -or $asset.sha256 -notmatch '^[a-f0-9]{64}$') {
        throw 'Unsafe or duplicate audio asset.'
    }
    $inputPath = Join-Path $source $asset.path
    if (-not (Test-Path -LiteralPath $inputPath -PathType Leaf) -or
        (Get-Item -LiteralPath $inputPath).Length -ne $asset.bytes -or
        (Get-FileHash -LiteralPath $inputPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $asset.sha256) {
        throw "Missing or mismatched audio: $($asset.path). See docs/AUDIO.md."
    }
}
if ($VerifyOnly) { Write-Output 'Version-matched built-in audio verified.'; return }
# Never write through a caller-added junction/symlink in the destination chain.
foreach ($asset in $catalog.assets) {
    $targetPath = Join-Path $destination $asset.path
    $candidate = [IO.Path]::GetFullPath($targetPath)
    while ($candidate) {
        if ((Test-Path -LiteralPath $candidate) -and ((Get-Item -LiteralPath $candidate -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Audio destination is redirected; restore an ordinary workspace directory.'
        }
        $candidate = Split-Path -Parent $candidate
    }
}
foreach ($asset in $catalog.assets) {
    Copy-Item -LiteralPath (Join-Path $source $asset.path) -Destination (Join-Path $destination $asset.path) -Force
}
Write-Output 'Verified audio imported. Godot must import the resources; keep recordings out of Git.'
