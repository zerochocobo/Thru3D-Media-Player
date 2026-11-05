param(
    [string]$Godot = $env:GODOT_EXE,
    [switch]$Regression,
    [switch]$RenderPreview,
    [switch]$Readability,
    [switch]$AllThemes,
    [string]$BaselineRef = ''
)
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
if (-not $Godot) { $Godot = Join-Path $env:USERPROFILE '.local/bin/godot.exe' }
if (-not (Test-Path -LiteralPath $Godot)) { throw "Godot is missing: $Godot" }
$regressionArguments = @((Join-Path $PSScriptRoot 'ui_theme_regression.py'), '--godot', $Godot)
if ($Regression) { $regressionArguments += '--regressions' }
& python @regressionArguments
if ($LASTEXITCODE -ne 0) { throw 'UI theme regression failed; see build/output/ui-themes/regressions.' }
if ($RenderPreview -or $AllThemes) {
    if (-not $BaselineRef) { throw 'Pass -BaselineRef for a local pre-theme revision to compare historical pixels.' }
    $capture = Join-Path $PSScriptRoot 'ui_theme_check.py'
    $common = @('library', 'player', 'browser-home', 'browser-panel', 'accounts', 'music',
        'scenery', 'keyboard', 'controls', 'typography', 'photos', 'pip', 'states',
        'seek', 'immersive', 'status', 'disc', 'puzzle', 'media-server', 'photo-adjustments')
    & python $capture --godot $Godot --stage baseline-fixed --source-ref $BaselineRef --fixtures @common
    if ($LASTEXITCODE -ne 0) { throw 'Historical UI baseline capture failed.' }
    & python $capture --godot $Godot --stage default-fixed --theme default --fixtures @common switch
    if ($LASTEXITCODE -ne 0) { throw 'Default UI capture failed.' }
    & python $capture --compare baseline-fixed default-fixed
    if ($LASTEXITCODE -ne 0) { throw 'Default UI pixels differ from the pre-theme Git revision.' }
    if ($AllThemes) {
        foreach ($theme in @('pearl', 'sand', 'jade', 'ocean', 'dusk')) {
            & python $capture --godot $Godot --stage $theme --theme $theme --fixtures @common
            if ($LASTEXITCODE -ne 0) { throw "Theme preview failed: $theme" }
        }
    }
}
if ($Readability) {
    foreach ($theme in @('default', 'pearl', 'sand', 'jade', 'ocean', 'dusk')) {
        & python (Join-Path $PSScriptRoot 'ui_theme_check.py') --godot $Godot --stage "readability-$theme" --theme $theme --fixtures readability browser-home
        if ($LASTEXITCODE -ne 0) { throw "UI readability render failed: $theme" }
    }
}
Write-Output 'UI theme validation completed. No APK build or headset operations.'
