param([switch]$SkipJvm, [switch]$SkipGo)
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$output = Join-Path $workspace 'build/output/pdf-cloud-providers'
New-Item -ItemType Directory -Force $output | Out-Null
if (!$SkipJvm) {
    . "$PSScriptRoot/environment/Activate-QuestEnvironment.ps1"
    & "$workspace/android/gradlew.bat" -p "$workspace/android" ('-PgodotAarPath=' + (Join-Path $env:QUEST_TOOL_ROOT 'godot-android-api/4.7.2/godot-lib.template_debug.aar')) :player-plugin:testDebugUnitTest --tests org.vrpassthroughplayer.plugin.PdfDocumentsTest --tests org.vrpassthroughplayer.plugin.PdfCloudProvidersTest --tests org.vrpassthroughplayer.plugin.PdfReadCacheTest --tests org.vrpassthroughplayer.plugin.CloudStreamSourceTest --tests org.vrpassthroughplayer.plugin.OpenListPlaybackTest --tests org.vrpassthroughplayer.plugin.BaiduOpenListTest --tests org.vrpassthroughplayer.plugin.CloudDriveTest --tests org.vrpassthroughplayer.plugin.CloudSearchTest --console=plain *> "$output/jvm.log"
    if ($LASTEXITCODE) { throw 'PDF cloud JVM checks failed; see build/output/pdf-cloud-providers/jvm.log.' }
}
if (!$SkipGo) {
    # Reuse the prepared pinned source with a read-only overlay. Never invoke
    # Prepare-OpenList: it can rebuild/publish the shared Android AAR.
    $cache = Join-Path $workspace '.cache/openlist'
    $source = Join-Path $cache 'OpenList-2bdf16d5967d0a403f67d809efd5a418b8f5bd30'
    if (!(Test-Path "$source/go.mod") -or !(Test-Path "$cache/go/bin/go.exe")) { throw 'Prepared OpenList host dependencies are required; no Android binding will be built.' }
    $replace = @{}
    Get-ChildItem "$workspace/cloud/openlist" -Filter '*.go' -File | ForEach-Object { $replace[(Join-Path $source "cloudcore/$($_.Name)")] = $_.FullName }
    Get-ChildItem "$workspace/cloud/openlist/search" -Filter '*.go' -File -Recurse | ForEach-Object {
        $packageRoot = if ($_.Directory.Name -eq 'gowebdav') { 'pkg' } else { 'drivers' }
        $replace[(Join-Path $source "$packageRoot/$($_.Directory.Name)/$($_.Name)")] = $_.FullName
    }
    $overlay = Join-Path $output 'overlay.json'
    @{Replace=$replace} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $overlay -Encoding utf8NoBOM
    $env:GOROOT="$cache/go"; $env:GOPATH="$cache/gopath"; $env:GOMODCACHE="$cache/modules"
    $env:GOCACHE="$cache/go-build"; $env:GOTOOLCHAIN='local'; $env:CGO_ENABLED='0'
    $env:GOTMPDIR=Join-Path $workspace 'tmp/pdf-cloud-go'
    New-Item -ItemType Directory -Force $env:GOTMPDIR | Out-Null
    & "$cache/go/bin/go.exe" -C $source test "-overlay=$overlay" -mod=readonly -timeout 180s -skip '^TestLiveRemoteWebDav$' ./cloudcore ./drivers/115_open ./drivers/baidu_netdisk ./drivers/aliyundrive_open ./drivers/quark_open ./drivers/onedrive ./drivers/webdav ./pkg/gowebdav -v *> "$output/go.log"
    if ($LASTEXITCODE) { throw 'PDF cloud Go checks failed; see build/output/pdf-cloud-providers/go.log.' }
    Select-String -LiteralPath "$output/go.log" -Pattern '^ok\s|PDF ranges=|PASS: TestPdf' | ForEach-Object { $_.Line }
}
Write-Output 'Cloud PDF host checks passed. No APK/AAR packaging, installation, real-account access or device operation.'
