[CmdletBinding()]
param(
    [ValidateSet('Registration','Cold','Warm')][string]$Mode = 'Registration',
    [ValidatePattern('^[A-Za-z0-9_-]+$')][Parameter(Mandatory=$true)][string]$Serial,
    [ValidatePattern('^[a-z][a-z0-9_.]+$')][string]$ApplicationId = 'com.wapok.thru3d',
    [ValidateSet('A','B')][string]$Fixture = 'A',
    [string]$ToolRoot = $(if ($env:THRU3D_TOOL_ROOT) { $env:THRU3D_TOOL_ROOT } else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.cache\thru3d-toolchain' })
)
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$adb = Join-Path $ToolRoot 'android-sdk/platform-tools/adb.exe'
$uri = "file:///sdcard/Download/Thru3D-External-Test/Thru3D-External-$Fixture.mp4"
$entry = "$ApplicationId/org.vrpassthroughplayer.plugin.ExternalPlaybackActivity"
$registration = @()
# Read-only queries: these synthetic addresses are never opened or fetched. Use the
# same default-only filtering as the chooser; an unrestricted query hides HTTP(S) bugs.
foreach ($scheme in @('file', 'content', 'http', 'https')) {
    $queryUri = if ($scheme -eq 'file') { $uri } else { "${scheme}://example.com/thru3d-registration.mp4" }
    $categories = @('android.intent.category.DEFAULT')
    if ($scheme -in @('http', 'https')) { $categories += 'android.intent.category.BROWSABLE' }
    foreach ($category in $categories) {
        foreach ($mime in @('video/mp4', 'application/vnd.apple.mpegurl', 'application/x-mpegURL')) {
            $candidates = (& $adb -s $Serial shell cmd package query-activities --brief --query-flags 65536 -a android.intent.action.VIEW -c $category -t $mime -d $queryUri) -join "`n"
            if ($LASTEXITCODE -ne 0 -or -not $candidates.Contains($entry)) { throw "Production external video association is missing: $scheme $mime $category" }
            if ($candidates.Contains("$ApplicationId/org.vrpassthroughplayer.plugin.ExternalPlaybackProbeActivity")) { throw 'Diagnostic probe must not appear in the chooser.' }
            $registration += [ordered]@{ scheme=$scheme; mime=$mime; category=$category; registered=$true }
        }
    }
}
foreach ($scheme in @('http', 'https')) {
    $candidates = (& $adb -s $Serial shell cmd package query-activities --brief --query-flags 65536 -a android.intent.action.VIEW -t text/html -d "${scheme}://example.com/") -join "`n"
    if ($LASTEXITCODE -ne 0 -or $candidates.Contains($entry)) { throw 'External video entry must not claim ordinary HTML pages.' }
}
$evidence = [ordered]@{ mode=$Mode; registered=$true; component=$entry; fixture=$Fixture; registration=$registration; html_excluded=$true }
if ($Mode -ne 'Registration') {
    # Public, synthetic fixtures only. No authenticated URI or user media appears in shell/log output.
    & $adb -s $Serial shell mkdir -p /sdcard/Download/Thru3D-External-Test | Out-Null
    $source = if ($Fixture -eq 'A') { 'mp03_frame_identity.mp4' } else { 'mp06_audio_clock.mp4' }
    & $adb -s $Serial push (Join-Path $workspace "app/godot/media/$source") "/sdcard/Download/Thru3D-External-Test/Thru3D-External-$Fixture.mp4" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Test fixture transfer failed.' }
    $before = ((& $adb -s $Serial shell pidof $ApplicationId) -join '').Trim()
    $oldText = (& $adb -s $Serial shell run-as $ApplicationId cat files/diagnostics/capabilities_latest.json 2>$null) -join "`n"
    $oldCapability = try { $oldText | ConvertFrom-Json } catch { $null }
    if ($Mode -eq 'Cold') {
        & $adb -s $Serial shell am force-stop $ApplicationId | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Cold start preparation failed.' }
    } elseif (-not $before) { throw 'Warm start requires a running player.' }
    $startedAt = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() / 1000.0
    $launch = (& $adb -s $Serial shell am start -W -a android.intent.action.VIEW -p $ApplicationId -t video/mp4 -d $uri) -join "`n"
    if ($LASTEXITCODE -ne 0 -or $launch -match 'Error:|Exception') { throw 'Implicit external start failed.' }
    $deadline = [DateTime]::UtcNow.AddSeconds(45)
    do {
        Start-Sleep -Milliseconds 500
        $text = (& $adb -s $Serial shell run-as $ApplicationId cat files/diagnostics/capabilities_latest.json 2>$null) -join "`n"
        $capability = try { $text | ConvertFrom-Json } catch { $null }
        if ($capability -and $capability.captured_unix_seconds -ge $startedAt -and
            $capability.media.frame_counter -gt 0 -and $capability.media.presentation_identity.source_pts_verified -and
            ($Mode -eq 'Cold' -or $capability.media.session_id -ne $oldCapability.media.session_id)) { break }
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not $capability -or $capability.captured_unix_seconds -lt $startedAt -or $capability.media.frame_counter -le 0 -or
        -not $capability.media.presentation_identity.source_pts_verified -or
        ($Mode -eq 'Warm' -and $capability.media.session_id -eq $oldCapability.media.session_id)) { throw 'No fresh presented video frame; check headset focus, privacy and access.' }
    $after = ((& $adb -s $Serial shell pidof $ApplicationId) -join '').Trim()
    if ($Mode -eq 'Warm' -and $before -ne $after) { throw 'Warm handoff restarted the player process.' }
    $evidence.process_id = $after
    $evidence.same_process = $Mode -eq 'Warm' -and $before -eq $after
    $evidence.session_id = $capability.media.session_id
    $evidence.frame_counter = $capability.media.frame_counter
    $evidence.presentation = $capability.media.presentation_identity
    $evidence.xr_session_state = $capability.xr.session_state
}
$directory = Join-Path $workspace 'build/output/external-playback'
New-Item -ItemType Directory -Path $directory -Force | Out-Null
$evidence | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $directory "device-$($Mode.ToLowerInvariant()).json") -Encoding utf8
$evidence | ConvertTo-Json -Depth 5
