param([string]$Godot='godot',[switch]$Render,[switch]$Adjustments)
$ErrorActionPreference='Stop'
$workspace=Split-Path -Parent $PSScriptRoot
$output=Join-Path $workspace 'build/output/photo-spatial'
New-Item -ItemType Directory -Path "$output/user" -Force | Out-Null
$nativeOutput=Join-Path $output 'gradient'
New-Item -ItemType Directory -Path $nativeOutput -Force | Out-Null
$vcvars='C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat'
cmd /c "`"$vcvars`" >nul 2>nul && cl /nologo /std:c++17 /O2 /EHsc /W4 /Fo`"$nativeOutput\\`" /Fe`"$nativeOutput/photo_gradient_probe.exe`" `"$workspace/tests/native/photo_gradient_probe.cpp`"" *> "$nativeOutput/compile.log"
if ($LASTEXITCODE -ne 0) { throw "Native photo gradient parity build failed; inspect $nativeOutput/compile.log" }
& "$nativeOutput/photo_gradient_probe.exe" --check-strengths *> "$nativeOutput/strength-range.log"
if ($LASTEXITCODE -ne 0) { throw "Native photo strength range failed; inspect $nativeOutput/strength-range.log" }
Get-Content "$nativeOutput/strength-range.log"
$savedAppData=$env:APPDATA
$savedProbe=$env:THRU3D_PHOTO_GRADIENT_PROBE
$runId=[guid]::NewGuid().ToString('N').Substring(0,8)
try {
    $env:THRU3D_PHOTO_GRADIENT_PROBE=Join-Path $nativeOutput 'photo_gradient_probe.exe'
    $env:APPDATA="$output/user"
    $cases=@('test_photo_spatial_gradient','test_photo_spatial_scene','test_photo_spatial_stability','test_photo_spatial_scale','test_photo_spatial_controls','test_spatial_photos','test_photos','test_photo_preload','test_photo_depth_payload','test_photo_portrait','test_photo_frame','test_photo_loading','test_photo_layouts','test_menu_surface_layout','test_i18n','test_player_menu')
    # The optional adjustment suite currently reproduces a pre-existing capture failure on HEAD.
    # Keep it independently runnable and failing; never turn its known failure into a pass.
    if ($Adjustments) { $cases+='test_photo_adjustments' }
    if ($Render) { $cases+=@('render_photo_spatial_scene','render_photo_spatial_stability','render_photo_spatial_controls','render_spatial_photos') }
    foreach ($case in $cases) {
		$env:APPDATA=Join-Path $output "user/$runId/$case"
		New-Item -ItemType Directory -Path $env:APPDATA -Force | Out-Null
        $arguments=@('--path',"$workspace/app/godot",'--xr-mode','off','--audio-driver','Dummy','--quit-after','5000','--script',"res://tests/$case.gd")
        if ($case.StartsWith('render_')) { $arguments+=@('--rendering-method','gl_compatibility','--rendering-driver','opengl3','--position','-2400,-1200') }
        else { $arguments+='--headless' }
        & $Godot @arguments *> "$output/$case.log"
        $result=Get-Content -LiteralPath "$output/$case.log" -Raw
        if ($LASTEXITCODE -ne 0 -or $result -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|FAIL:)' -or $result -match '(?i)(\b[1-9][0-9]* failures(?![=])|failures=[1-9])') { throw "$case failed; see $output/$case.log" }
        if ($result -match 'ObjectDB.*leaked|Leaked instance:') {
            if ($case -in @('test_photo_spatial_scene','render_photo_spatial_scene','test_photo_spatial_stability','render_photo_spatial_stability','test_photo_spatial_scale','test_photo_spatial_controls','render_photo_spatial_controls')) { throw "$case leaked resources; see $output/$case.log" }
            Write-Warning "$case logged an existing-suite resource warning; inspect $output/$case.log independently."
        }
        if ($result -notmatch '(checks|failures|passed)') { throw "$case returned no completion report" }
        $result -split "`n" | Where-Object { $_ -match '(checks|failures|passed)' } | Select-Object -Last 1
    }
} finally { $env:APPDATA=$savedAppData; $env:THRU3D_PHOTO_GRADIENT_PROBE=$savedProbe }
