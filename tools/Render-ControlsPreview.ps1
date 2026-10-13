param([string]$ToolRoot = $(if ($env:THRU3D_TOOL_ROOT) { $env:THRU3D_TOOL_ROOT } else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.cache\thru3d-toolchain' }), [switch]$SkipAnimation)
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
. "$PSScriptRoot\environment\Activate-QuestEnvironment.ps1" -ToolRoot $ToolRoot
$output = Join-Path $workspace 'build/output/controller-controls'
New-Item -ItemType Directory -Path $output -Force | Out-Null
$env:SDL_JOYSTICK_HIDAPI = '0'
$projectDirectory = Join-Path $workspace 'app/godot'
$stdoutPath = Join-Path $output 'render.log'
$stderrPath = Join-Path $output 'render-errors.log'
$arguments = @('--xr-mode','off','--rendering-method','gl_compatibility','--rendering-driver','opengl3',
    '--path', ('"' + $projectDirectory + '"'), '--log-file', ('"' + (Join-Path $output 'godot-render.log') + '"'),
    '--quit-after','3000','--script','res://tests/render_controls_page.gd')
$process = Start-Process -FilePath $env:GODOT_EXE -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
if (-not $process.WaitForExit(60000)) { throw "Controls preview remains active (PID $($process.Id)); inspect it before retrying." }
if ($process.ExitCode -ne 0) { throw 'Controls preview failed.' }
$renderLog = (Get-Content $stdoutPath -Raw) + (Get-Content $stderrPath -Raw)
if ($renderLog -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'Controls preview reported an error.' }
$previews = Join-Path $output 'previews'
if (-not $SkipAnimation) {
    $ffmpeg = Get-Command ffmpeg -ErrorAction SilentlyContinue
    if ($ffmpeg) {
        & $ffmpeg.Source -hide_banner -loglevel error -y -framerate 12 -i (Join-Path $previews 'gesture-frames/%03d.png') -filter_complex '[0:v]scale=1200:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=128[p];[b][p]paletteuse=dither=bayer:bayer_scale=5' -loop 0 (Join-Path $previews 'zh-gesture-zoom.gif')
        if ($LASTEXITCODE -ne 0) { throw 'Controls animation export failed.' }
    } else { Write-Warning 'FFmpeg unavailable; the complete animation frames remain in the previews directory.' }
}
Write-Output "Controls previews: $previews"
