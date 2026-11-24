param([switch]$CompileOnly)
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$cache = Join-Path $workspace '.cache/openlist'
$source = Join-Path $cache 'OpenList-2bdf16d5967d0a403f67d809efd5a418b8f5bd30'
$mutex = [Threading.Mutex]::new($false, 'Local\VRPassthroughPlayer-OpenList')
$held = $false
try {
    try { $held = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held = $true }
    if (!$held) { throw 'OpenList build is busy; retry after it finishes.' }
    if (!(Test-Path -LiteralPath "$source/go.mod")) { throw 'Pinned OpenList source must already be prepared.' }
    # Native host checks only. Do not run Prepare-OpenList/gomobile or produce APK/AAR.
    Get-ChildItem -LiteralPath "$workspace/cloud/openlist" -File -Filter '*.go' | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination "$source/cloudcore/$($_.Name)" -Force
    }
    foreach ($driver in @('thunder', 'guangya_open')) {
        New-Item -ItemType Directory -Force -Path "$source/drivers/$driver" | Out-Null
        Get-ChildItem -LiteralPath "$workspace/cloud/openlist/search/$driver" -File -Filter '*.go' | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination "$source/drivers/$driver/$($_.Name)" -Force
        }
    }
    $env:GOROOT = "$cache/go"; $env:GOPATH = "$cache/gopath"
    $env:GOMODCACHE = "$cache/modules"; $env:GOCACHE = "$cache/go-build"
    $env:GOTOOLCHAIN = 'local'; $env:CGO_ENABLED = '0'
    $filter = if ($CompileOnly) { '^$' } else { 'TestPlayerGuangya' }
    & "$cache/go/bin/go.exe" -C $source test -mod=mod -timeout 90s ./drivers/guangya_open ./cloudcore -run $filter -v
    if ($LASTEXITCODE) { throw 'GuangYaPan native checks failed' }
} finally { if ($held) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
