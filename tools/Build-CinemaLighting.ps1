param(
    [string]$Godot = 'godot',
    [string]$Blender = 'blender',
    [int]$Samples = 256,
    [int]$Atlas = 4096,
    [switch]$ImportOnly
)
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$project = Join-Path $workspace 'app/godot'
$output = Join-Path $workspace 'build/output/cinema-full-lighting'
$assets = Join-Path $project 'environments/grand_cinema'
New-Item -ItemType Directory -Path $output -Force | Out-Null
function Invoke-CinemaProcess([string]$Executable, [string[]]$Arguments, [string]$Log) {
    $quoted = @($Arguments | ForEach-Object { '"' + $_.Replace('"','\"') + '"' })
    $p = Start-Process -FilePath $Executable -ArgumentList $quoted -WorkingDirectory $workspace -WindowStyle Hidden -PassThru -RedirectStandardOutput $Log -RedirectStandardError ($Log + '.errors')
    $p.WaitForExit()
    if ($p.ExitCode -ne 0) { throw "Cinema process failed ($($p.ExitCode)); see $Log" }
}
if (-not $ImportOnly) {
    Invoke-CinemaProcess (Get-Command $Godot).Source @('--headless','--xr-mode','off','--path',$project,'--script',(Join-Path $workspace 'tools/Generate-CinemaModel.gd')) (Join-Path $output 'manifest.log')
    Invoke-CinemaProcess (Get-Command $Blender).Source @('--background','--factory-startup','--python','tools/cinema/build_full_lighting.py','--','--samples',"$Samples",'--atlas',"$Atlas") (Join-Path $output 'bake.log')
    if ((Get-Content (Join-Path $output 'bake.log') -Raw) -notmatch 'CINEMA_FULL_LIGHTING_OK') { throw 'Baker did not complete.' }
}
$record = Get-Content (Join-Path $workspace 'tools/cinema/full_hall/build.json') -Raw | ConvertFrom-Json
if ((Get-FileHash (Join-Path $assets 'manifest.json')).Hash.ToLowerInvariant() -ne $record.manifest_sha256) { throw 'Navigation manifest changed since this bake.' }
foreach ($name in @('cinema.glb','cinema_light.jpg','cinema_light_off.jpg')) {
    $source = Join-Path $output $name
    if ((Get-FileHash -LiteralPath $source).Hash.ToLowerInvariant() -ne $record.files.$name.sha256) { throw "Baked output mismatch: $name" }
}
if ((Get-Item (Join-Path $output 'cinema.glb')).Length -gt 32MB) { throw 'GLB exceeds the existing mobile authoring budget.' }
foreach ($name in @('cinema.glb','cinema_light.jpg','cinema_light_off.jpg')) { Copy-Item -LiteralPath (Join-Path $output $name) -Destination (Join-Path $assets $name) -Force }
$engine = (Get-Command $Godot).Source
Invoke-CinemaProcess $engine @('--headless','--xr-mode','off','--path',$project,'--editor','--import') (Join-Path $output 'import.log')
foreach ($settings in Get-ChildItem -LiteralPath $assets -Filter '*.import' | Where-Object { $_.Name -match '\.(jpg|png)\.import$' }) {
    $text = [IO.File]::ReadAllText($settings.FullName)
    $pinned = $text -replace '(?m)^compress/mode=\d+', 'compress/mode=2' -replace '(?m)^mipmaps/generate=false', 'mipmaps/generate=true'
    if ($pinned -ne $text) { [IO.File]::WriteAllText($settings.FullName, $pinned) }
}
Invoke-CinemaProcess $engine @('--headless','--xr-mode','off','--path',$project,'--editor','--import') (Join-Path $output 'import-compressed.log')
Write-Output 'Full cinema dual lighting imported with compressed mipmapped textures. No APK export or device operations.'
