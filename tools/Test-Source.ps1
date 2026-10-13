param([string]$GodotExe = $env:GODOT_EXE)
$ErrorActionPreference = 'Stop'
if (-not $GodotExe) {
    $command = Get-Command godot -ErrorAction SilentlyContinue
    if ($command) { $GodotExe = $command.Source }
    else { throw 'Pass -GodotExe or set GODOT_EXE.' }
}
$workspace = Split-Path -Parent $PSScriptRoot
$project = Join-Path $workspace 'app/godot'
$logs = Join-Path $workspace 'build/output/source-tests'
New-Item -ItemType Directory -Path $logs -Force | Out-Null
$previousAppData = $env:APPDATA
$previousLocalAppData = $env:LOCALAPPDATA
$sourceTestData = Join-Path $workspace 'build/output/source-test-userdata'
New-Item -ItemType Directory -Path $sourceTestData -Force | Out-Null
try {
# Keep host test preferences and temporary user:// files away from real player data.
$env:APPDATA = $sourceTestData
$env:LOCALAPPDATA = $sourceTestData
# Import resource metadata before running a fresh checkout's GDScript suite.
& $GodotExe --headless --xr-mode off --path $project --editor --quit-after 600 2>&1 |
    Out-File (Join-Path $logs 'import.log') -Encoding utf8
if ($LASTEXITCODE -ne 0 -or (Get-Content (Join-Path $logs 'import.log') -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') {
    throw 'Godot source import failed; inspect build/output/source-tests/import.log.'
}
foreach ($test in (Get-ChildItem -LiteralPath (Join-Path $project 'tests') -Filter 'test_*.gd' | Sort-Object Name)) {
    $log = Join-Path $logs ($test.BaseName + '.log')
    if ($test.Name -eq 'test_thumbnails.gd') {
        # Capture awaits a rendered frame; the headless dummy renderer cannot complete it.
        $stderr = Join-Path $logs ($test.BaseName + '.stderr.log')
        $arguments = @('--xr-mode','off','--rendering-method','gl_compatibility','--rendering-driver','opengl3',
            '--path', ('"' + $project + '"'), '--quit-after','18000','--script', ("res://tests/" + $test.Name))
        $process = Start-Process -FilePath $GodotExe -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput $log -RedirectStandardError $stderr
        if (-not $process.WaitForExit(60000)) { throw "Thumbnail renderer remains active (PID $($process.Id)); inspect it before retrying." }
        $testExit = $process.ExitCode
        $testOutput = (Get-Content $log -Raw) + (Get-Content $stderr -Raw)
        if ($testOutput -notmatch 'thumbnail checks=[0-9]+ failures=0') {
            throw 'Thumbnail test did not complete; inspect its source-tests logs.'
        }
    } else {
        & $GodotExe --headless --xr-mode off --path $project --quit-after 1800 --script ("res://tests/" + $test.Name) 2>&1 |
            Out-File $log -Encoding utf8
        $testExit = $LASTEXITCODE
        $testOutput = Get-Content $log -Raw
    }
    if ($testExit -ne 0 -or $testOutput -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') {
        throw "Source test failed: $($test.Name); inspect $log"
    }
    Write-Output "Passed: $($test.Name)"
}
} finally {
    $env:APPDATA = $previousAppData
    $env:LOCALAPPDATA = $previousLocalAppData
}
