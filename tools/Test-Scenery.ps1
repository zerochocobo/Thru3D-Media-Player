param([string]$Godot = 'godot', [switch]$RenderPreview)
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$project = Join-Path $workspace 'app/godot'
$output = Join-Path $workspace 'build/output/scenery-checks'
New-Item -ItemType Directory -Path $output -Force | Out-Null
foreach ($test in @('test_background_library', 'test_scenery_integration', 'test_scenery_workflow', 'test_cinema_background_menu')) {
    $log = Join-Path $output ($test + '.log')
    & $Godot --headless --xr-mode off --path $project --quit-after 3000 --script ('res://tests/' + $test + '.gd') 2>&1 | Tee-Object -FilePath $log | Out-Null
    $result = Get-Content -LiteralPath $log -Raw
    if ($LASTEXITCODE -ne 0 -or $result -match '(?m)^(SCRIPT ERROR:|ERROR:)' -or $result -notmatch '((Background library|Scenery integration|Scenery workflow): [0-9]+ checks, 0 failures|CINEMA_BACKGROUND_MENU checks=[0-9]+ failures=0)') { throw "Scenery regression failed: $test" }
}
if ($RenderPreview) {
    $log = Join-Path $output 'render.log'
    & $Godot --xr-mode off --rendering-method gl_compatibility --rendering-driver opengl3 --path $project --quit-after 3000 --script res://tests/render_scenery_menu.gd 2>&1 | Tee-Object -FilePath $log | Out-Null
    $result = Get-Content -LiteralPath $log -Raw
    if ($LASTEXITCODE -ne 0 -or $result -match '(?m)^(SCRIPT ERROR:|ERROR:)' -or $result -notmatch 'SCENERY_UI_RENDER_OK') { throw 'Scenery visual render failed.' }
}
Write-Output 'Scenery checks passed.'
