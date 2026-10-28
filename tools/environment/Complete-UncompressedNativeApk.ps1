param(
    [Parameter(Mandatory)][string]$ApkPath,
    [ValidateSet('Debug','Release')][string]$BuildType = 'Release'
)
$ErrorActionPreference = 'Stop'
$prefix = 'GODOT_ANDROID_KEYSTORE_' + $BuildType.ToUpperInvariant()
$keyPath = [Environment]::GetEnvironmentVariable($prefix + '_PATH', 'Process')
$alias = [Environment]::GetEnvironmentVariable($prefix + '_USER', 'Process')
$passwordVariable = $prefix + '_PASSWORD'
if (-not $keyPath -or -not $alias -or -not [Environment]::GetEnvironmentVariable($passwordVariable, 'Process')) {
    throw 'Prepared signing identity is required; no replacement key is generated.'
}
$tools = Join-Path $env:ANDROID_HOME 'build-tools/36.1.0'
$aligned = $ApkPath + '.' + [guid]::NewGuid().ToString('N') + '.aligned.apk'
try {
    & "$tools/zipalign.exe" -f -P 16 4 $ApkPath $aligned
    if ($LASTEXITCODE -ne 0) { throw 'Uncompressed native APK alignment failed.' }
    & "$tools/apksigner.bat" sign --ks $keyPath --ks-key-alias $alias --ks-pass "env:$passwordVariable" --key-pass "env:$passwordVariable" --v1-signing-enabled false --v2-signing-enabled true --v3-signing-enabled false --v4-signing-enabled false $aligned
    if ($LASTEXITCODE -ne 0) { throw 'Uncompressed native APK signing failed.' }
    & "$tools/apksigner.bat" verify --verbose $aligned
    if ($LASTEXITCODE -ne 0) { throw 'Uncompressed native APK signature invalid.' }
    & "$tools/zipalign.exe" -c -P 16 4 $aligned
    if ($LASTEXITCODE -ne 0) { throw 'Uncompressed native APK lost alignment.' }
    Move-Item -LiteralPath $aligned -Destination $ApkPath -Force
} finally {
    if (Test-Path -LiteralPath $aligned) { Remove-Item -LiteralPath $aligned }
}
