param([string]$ToolRoot = $(if ($env:THRU3D_TOOL_ROOT) { $env:THRU3D_TOOL_ROOT } else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.cache\thru3d-toolchain' }), [string]$WslDistribution = 'QuestMpvBuild')
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
& python (Join-Path $PSScriptRoot 'prepare_airplay.py')
if ($LASTEXITCODE -ne 0) { throw 'AirPlay source preparation failed.' }
$crypto = Join-Path $workspace 'build/airplay/deps/crypto/lib/libcrypto.a'
if (-not (Test-Path -LiteralPath $crypto) -or -not (Test-Path -LiteralPath (Join-Path (Split-Path -Parent (Split-Path -Parent $crypto)) 'receipt.json'))) {
    if ($IsWindows) {
        $script = Join-Path $PSScriptRoot 'Build-Airplay.sh'
        $linuxScript = (& wsl -d $WslDistribution -e wslpath -a $script).Trim()
        if ($LASTEXITCODE -ne 0 -or -not $linuxScript.StartsWith('/')) { throw 'AirPlay WSL path conversion failed.' }
        & wsl -d $WslDistribution -e bash $linuxScript
    } else { & bash (Join-Path $PSScriptRoot 'Build-Airplay.sh') }
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $crypto)) { throw 'AirPlay crypto build failed.' }
}
$receipt = Get-Content -LiteralPath (Join-Path (Split-Path -Parent (Split-Path -Parent $crypto)) 'receipt.json') -Raw | ConvertFrom-Json
if ($receipt.openssl -ne '3.5.9' -or $receipt.abi -ne 'arm64-v8a' -or $receipt.api -ne 29 -or
    (Get-FileHash -LiteralPath $crypto -Algorithm SHA256).Hash.ToLowerInvariant() -ne $receipt.sha256) {
    throw 'AirPlay crypto dependency validation failed.'
}
Write-Output 'AirPlay sources and Android crypto dependency ready.'
