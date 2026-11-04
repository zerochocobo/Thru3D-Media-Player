param([string]$Godot = 'godot', [switch]$RenderPreview)
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$output = Join-Path $workspace 'build/output/depth-position'
New-Item -ItemType Directory -Force $output | Out-Null
foreach ($test in @('test_depth_position', 'test_photo_depth_payload', 'test_depth_strength_scale')) {
    $log = Join-Path $output ($test + '.log')
    & $Godot --headless --xr-mode off --path (Join-Path $workspace 'app/godot') --quit-after 1800 --script ('res://tests/' + $test + '.gd') 2>&1 | Out-File $log -Encoding utf8
    $result = Get-Content $log -Raw
    if ($LASTEXITCODE -ne 0 -or $result -match '(?m)^(SCRIPT ERROR:|ERROR:)' -or $result -notmatch '(0 failures|failures=0)') { throw "Depth position regression failed: $test; $log" }
    Write-Output ($result.Trim())
}
if ($RenderPreview) {
    foreach ($test in @('render_depth_parallax', 'render_depth_position')) {
        $log = Join-Path $output ($test + '.log')
        & $Godot --xr-mode off --rendering-method gl_compatibility --rendering-driver opengl3 --path (Join-Path $workspace 'app/godot') --quit-after 1800 --script ('res://tests/' + $test + '.gd') 2>&1 | Out-File $log -Encoding utf8
        $result = Get-Content $log -Raw
        if ($LASTEXITCODE -ne 0 -or $result -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)' -or $result -notmatch '(passed \(0 failures\)|Depth position UI render complete)') { throw "Depth position render failed: $test; $log" }
        Write-Output ($result.Trim())
    }
}
