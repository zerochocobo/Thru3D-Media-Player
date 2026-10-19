param([string]$Godot = 'godot', [string]$Video = '', [switch]$SpaceOnly, [switch]$Wait)
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$project = Join-Path $workspace 'app/godot'
$output = Join-Path $workspace $(if ($SpaceOnly) { 'build/output/cinema-prototype' } else { 'build/output/cinema-desktop' })
New-Item -ItemType Directory -Path $output -Force | Out-Null
if (-not $SpaceOnly) {
    & (Join-Path $PSScriptRoot 'Prepare-CinemaDesktopVideo.ps1') | Out-Null
}
$scene = if ($SpaceOnly) { 'res://scenes/cinema_prototype.tscn' } else { 'res://scenes/cinema_desktop_player.tscn' }
$arguments = @('--path', $project, '--xr-mode', 'off', '--rendering-method', 'gl_compatibility',
    '--rendering-driver', 'opengl3', '--resolution', '1440x960', '--position', '80,40', '--log-file',
    (Join-Path $output 'interactive.log'), $scene)
if ($Video) { $arguments += @('--', "--cinema-video=$Video") }
# Isolate the desktop experiment's settings/history from the normal player.
# Start-Process inherits only this child-process environment; the user's setting is restored.
$previousAppData = $env:APPDATA
try {
    if (-not $SpaceOnly) {
        $env:APPDATA = Join-Path $output 'userdata'
        New-Item -ItemType Directory -Path $env:APPDATA -Force | Out-Null
    }
    $quotedArguments = @($arguments | ForEach-Object { '"' + $_.Replace('"', '\"') + '"' })
    $process = Start-Process -FilePath (Get-Command $Godot).Source -ArgumentList $quotedArguments -WorkingDirectory $workspace -WindowStyle Normal -PassThru
    Write-Output "Cinema desktop player started (PID $($process.Id))."
    if ($Wait) {
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) { throw "Cinema desktop player exited with $($process.ExitCode)" }
    }
} finally { $env:APPDATA = $previousAppData }
