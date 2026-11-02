param([string]$Godot = $env:GODOT_EXE)
$ErrorActionPreference = 'Stop'
if (!$Godot) { $Godot = (Get-Command godot.exe -ErrorAction Stop).Source }
$workspace = Split-Path -Parent $PSScriptRoot
$output = Join-Path $workspace 'build/output/vr-passthrough'
$project = Join-Path $workspace 'app/godot'
New-Item -ItemType Directory -Force $output | Out-Null
$previousAppData = $env:APPDATA
$env:APPDATA = Join-Path $output 'appdata'
$taskMutex = [Threading.Mutex]::new($false, 'Local\VRPassthroughPlayer-Build')
$taskLocked = $false
try {
    try { $taskLocked = $taskMutex.WaitOne(0) }
    catch [Threading.AbandonedMutexException] { $taskLocked = $true }
    if (!$taskLocked) { throw 'Another build owns the workspace; retry when it completes.' }
    foreach ($case in @('test_vr_passthrough', 'test_view_follow', 'test_narration', 'test_cast_receiver', 'render_vr_passthrough')) {
        $mode = if ($case.StartsWith('render_')) { '--rendering-method gl_compatibility --rendering-driver opengl3' } else { '--headless' }
        $arguments = '{0} --xr-mode off --path "{1}" --script res://tests/{2}.gd' -f $mode, $project, $case
        $taskProcess = Start-Process -FilePath $Godot -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput "$output/$case.stdout.log" -RedirectStandardError "$output/$case.stderr.log"
        if (!$taskProcess.WaitForExit(45000)) { Stop-Process -Id $taskProcess.Id; throw "$case timed out." }
        $result = (Get-Content "$output/$case.stdout.log" -Raw) + (Get-Content "$output/$case.stderr.log" -Raw)
        if ($taskProcess.ExitCode -ne 0 -or $result -match 'SCRIPT ERROR|SHADER ERROR|(?m)^ERROR:' -or $result -notmatch '0 failures|failures=0|passed') { throw "$case failed; see build/output/vr-passthrough." }
        $result -split '\r?\n' | Where-Object { $_ -match '0 failures|failures=0|passed' } | Write-Output
    }
} finally {
    if ($taskLocked) { $taskMutex.ReleaseMutex() }
    $taskMutex.Dispose()
    $env:APPDATA = $previousAppData
}
Write-Output 'VR passthrough source and rendering checks passed. No APK packaging or device operation.'
