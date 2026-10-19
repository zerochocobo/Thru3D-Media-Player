param(
    [string]$Godot = 'godot_console',
    [string]$ReleaseTemplate = "$env:APPDATA/Godot/export_templates/4.7.2.stable/windows_release_x86_64.exe"
)
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$project = Join-Path $workspace 'app/godot'
$output = Join-Path $workspace 'build/output/cinema-build-gate'
$runtime = Join-Path $output 'release-source'
New-Item -ItemType Directory -Path $runtime -Force | Out-Null
# Release templates intentionally forbid --path and --script. Run an ordinary
# test scene beside the existing engine, using disposable copies of current
# sources/imports. This is no export, PCK, APK, installation or Git checkout.
$runtimeEngine = Join-Path $runtime 'release-runtime.exe'
if (-not (Test-Path -LiteralPath $runtimeEngine) -or
    (Get-FileHash -LiteralPath $runtimeEngine).Hash -ne (Get-FileHash -LiteralPath $ReleaseTemplate).Hash) {
    Copy-Item -LiteralPath $ReleaseTemplate -Destination $runtimeEngine -Force
}
$extensions = @('.gd','.tscn','.tres','.gdshader','.gdshaderinc','.json','.cfg','.godot','.import','.uid','.svg','.png','.jpg','.jpeg','.webp','.otf','.ttf','.wav','.ogg','.glb','.gltf','.ctex','.scn','.sample','.fontdata','.res')
$sourceFiles = & rg --files --hidden --no-ignore $project -g '!**/.godot/**' -g '!**/addons/**'
if ($LASTEXITCODE -ne 0) { throw 'Unable to enumerate current project sources.' }
$sourceFiles += & rg --files --hidden --no-ignore (Join-Path $project '.godot/imported')
$sourceFiles += Join-Path $project '.godot/global_script_class_cache.cfg'
foreach ($source in $sourceFiles) {
    if ([IO.Path]::GetExtension($source) -notin $extensions) { continue }
    $relative = $source.Substring($project.Length).TrimStart('\','/')
    $destination = Join-Path $runtime $relative
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination)) | Out-Null
    Copy-Item -LiteralPath $source -Destination $destination -Force
}
Copy-Item -LiteralPath (Join-Path $project '.godot/uid_cache.bin') -Destination (Join-Path $runtime '.godot/uid_cache.bin') -Force
$projectConfig = Get-Content -LiteralPath (Join-Path $project 'project.godot') -Raw
$projectConfig = $projectConfig.Replace('run/main_scene="res://scenes/main.tscn"', 'run/main_scene="res://tests/test_cinema_build_gate.tscn"')
[IO.File]::WriteAllText((Join-Path $runtime 'project.godot'), $projectConfig, [Text.UTF8Encoding]::new($false))
$previousAppData = $env:APPDATA
try {
    $env:APPDATA = Join-Path $output 'userdata'
    New-Item -ItemType Directory -Path $env:APPDATA -Force | Out-Null
    foreach ($variant in @('debug','release')) {
        $log = Join-Path $output "$variant.log"
        $resultDirectory = Join-Path $output $variant
        $resultFile = Join-Path $resultDirectory 'summary.json'
        if (Test-Path -LiteralPath $resultFile) { Remove-Item -LiteralPath $resultFile }
        $arguments = @('--headless','--xr-mode','off','--audio-driver','Dummy','--quit-after','5000','--log-file',$log)
        if ($variant -eq 'debug') { $engine = (Get-Command $Godot).Source; $arguments += @('--path',$project,'res://tests/test_cinema_build_gate.tscn') }
        else { $engine = $runtimeEngine }
        $arguments += @('--', "--expect-$variant", "--gate-output=$resultDirectory")
        $quoted = @($arguments | ForEach-Object { '"' + $_.Replace('"','\"') + '"' })
        $process = Start-Process -FilePath $engine -ArgumentList $quoted -WorkingDirectory $runtime -WindowStyle Hidden -PassThru
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) { throw "$variant test process failed ($($process.ExitCode)); see $log" }
        $result = Get-Content -LiteralPath $resultFile -Raw | ConvertFrom-Json
        $logText = Get-Content -LiteralPath $log -Raw
        if (-not $result.passed -or $result.actual_debug_build -ne ($variant -eq 'debug') -or $logText -match 'SCRIPT ERROR:|SHADER ERROR:|ObjectDB instances leaked|FAIL:') { throw "$variant test failed; see $log" }
        Write-Output "$variant : $($result.checks) checks, 0 failures (actual debug flag=$($result.actual_debug_build))"
    }
} finally { $env:APPDATA = $previousAppData }
