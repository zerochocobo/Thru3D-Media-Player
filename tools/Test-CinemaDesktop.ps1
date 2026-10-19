param([string]$Godot = 'godot_console', [string]$Ffmpeg = 'ffmpeg')
$ErrorActionPreference = 'Stop'
$testWorkspace = Split-Path -Parent $PSScriptRoot
& (Join-Path $PSScriptRoot 'Prepare-CinemaDesktopVideo.ps1') | Out-Null
& (Join-Path $PSScriptRoot 'Generate-CinemaDesktopTestClips.ps1') -Ffmpeg $Ffmpeg | Out-Null
$testOutput = Join-Path $testWorkspace 'build/output/cinema-desktop-validation'
New-Item -ItemType Directory -Path $testOutput -Force | Out-Null
$previousAppData = $env:APPDATA
try {
    $env:APPDATA = Join-Path $testOutput 'userdata'
    New-Item -ItemType Directory -Path $env:APPDATA -Force | Out-Null
    $testCases = @(
        @('test_cinema_world_transport', 'CINEMA_WORLD_TRANSPORT checks=\d+ failures=0', $false),
        @('test_cinema_desktop_video', 'Cinema desktop video: \d+ checks, 0 failures', $true),
        @('render_cinema_desktop_player', 'Cinema desktop player: \d+ checks, 0 failures', $true)
    )
    foreach ($testCase in $testCases) {
        $testName = $testCase[0]
        $testLog = Join-Path $testOutput "$testName.log"
        $testArguments = @('--path', (Join-Path $testWorkspace 'app/godot'), '--xr-mode', 'off', '--audio-driver', 'Dummy', '--verbose', '--log-file', $testLog, '--quit-after', '5000')
        if ($testCase[2]) { $testArguments += @('--rendering-method', 'gl_compatibility', '--rendering-driver', 'opengl3', '--resolution', '1440x960', '--position', '-2400,-1200') }
        else { $testArguments += '--headless' }
        $testArguments += @('--script', "res://tests/$testName.gd")
        & $Godot @testArguments 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "$testName exited $LASTEXITCODE" }
        $testText = Get-Content -LiteralPath $testLog -Raw
        if ($testText -notmatch $testCase[1] -or $testText -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|FAIL:)' -or $testText -match 'ObjectDB instances leaked|Leaked instance:') { throw "$testName did not pass cleanly; see $testLog" }
        Write-Output ($testText -split "`n" | Where-Object { $_ -match $testCase[1] })
    }
} finally { $env:APPDATA = $previousAppData }
Write-Output 'Cinema desktop checks passed. No APK export, installation or device test was performed.'
