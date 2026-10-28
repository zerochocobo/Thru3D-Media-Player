param([string]$ToolRoot = $(if ($env:THRU3D_TOOL_ROOT) { $env:THRU3D_TOOL_ROOT } else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.cache\thru3d-toolchain' }), [switch]$RenderPreview, [switch]$Browser)
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
. "$PSScriptRoot/environment/Activate-QuestEnvironment.ps1" -ToolRoot $ToolRoot
$output = Join-Path $workspace 'build/output/bookmark-remote'
New-Item -ItemType Directory -Force $output | Out-Null
Push-Location $workspace
try {
    $api = Join-Path $ToolRoot 'godot-android-api/4.7.2/godot-lib.template_debug.aar'
    if (-not (Test-Path -LiteralPath $api)) { throw 'Prepare the matching Godot API AAR before running host tests.' }
    & "$workspace/android/gradlew.bat" -p "$workspace/android" "-PgodotAarPath=$api" :web-browser:testDebugUnitTest --console=plain *> "$output/jvm.log"
    if ($LASTEXITCODE -ne 0) { throw "JVM tests failed: $output/jvm.log" }
    & node --test tests/web-bookmark-remote.test.cjs *> "$output/frontend.log"
    if ($LASTEXITCODE -ne 0) { throw "Frontend tests failed: $output/frontend.log" }
    $godotConsole = Join-Path (Split-Path $env:GODOT_EXE) 'godot_console.exe'
    $runner = if (Test-Path $godotConsole) { $godotConsole } else { $env:GODOT_EXE }
    foreach ($test in @('test_web_bookmark_share', 'test_web_browser_library', 'test_distribution_channel', 'test_i18n')) {
        & $runner --headless --xr-mode off --path "$workspace/app/godot" --quit-after 1800 --script "res://tests/$test.gd" *> "$output/$test.log"
        $log = Get-Content -Raw "$output/$test.log"
        if ($LASTEXITCODE -ne 0 -or $log -match 'SCRIPT ERROR:' -or $log -notmatch '(0 failures|failures=0)') { throw "Godot test failed: $test" }
    }
    if ($RenderPreview) {
        & $runner --xr-mode off --rendering-method gl_compatibility --rendering-driver opengl3 --path "$workspace/app/godot" --quit-after 1800 --script res://tests/render_web_bookmark_share.gd *> "$output/render.log"
        if ($LASTEXITCODE -ne 0 -or (Get-Content -Raw "$output/render.log") -notmatch '20 layouts, 0 failures') { throw 'Bookmark preview rendering failed.' }
    }
    if ($Browser) {
        # Playwright must be available to node (e.g. NODE_PATH from the desktop dependency runtime).
        $cache = Join-Path $ToolRoot 'gradle-cache/caches/modules-2/files-2.1'
        $jars = @((Get-ChildItem "$cache/org.json/json/20250517" -Recurse -Filter '*.jar').FullName,
            (Get-ChildItem "$cache/org.jetbrains.kotlin/kotlin-stdlib/2.4.21" -Recurse -Filter '*.jar').FullName)
        $classpath = (@("$workspace/android/web-browser/build/tmp/kotlin-classes/debug", "$workspace/android/web-browser/build/tmp/kotlin-classes/debugUnitTest") + $jars) -join [IO.Path]::PathSeparator
        $oldCode = $env:BOOKMARK_PREVIEW_CODE; $oldUrl = $env:BOOKMARK_PREVIEW_URL
        try {
            foreach ($secure in @($false, $true)) {
                $fixtureLog = "$output/fixture-$secure.log"
                $arguments = @('-cp', ('"' + $classpath + '"'), 'org.vrpassthroughplayer.plugin.WebBookmarkPreview', ('"' + $workspace + '"'), '18791')
                if ($secure) { $arguments += '--secure' }
                $fixture = Start-Process -FilePath "$env:JAVA_HOME/bin/java.exe" -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput $fixtureLog -RedirectStandardError "$output/fixture-$secure-error.log"
                try {
                    $deadline = (Get-Date).AddSeconds(15); $state = $null
                    while (-not $state -and -not $fixture.HasExited -and (Get-Date) -lt $deadline) {
                        Start-Sleep -Milliseconds 100
                        if (Test-Path $fixtureLog) { $line = Get-Content $fixtureLog -First 1; if ($line -and $line.StartsWith('{')) { $state = $line | ConvertFrom-Json } }
                    }
                    if (-not $state) { throw 'Loopback preview did not start; check the port and fixture log.' }
                    $env:BOOKMARK_PREVIEW_URL = $state.url
                    $env:BOOKMARK_PREVIEW_CODE = if ($secure) { $state.code } else { '' }
                    & node tests/web-bookmark-remote.e2e.cjs *> "$output/e2e-$secure.log"
                    if ($LASTEXITCODE -ne 0) { throw "Browser test failed: $output/e2e-$secure.log" }
                } finally {
                    # This process is exclusively the in-memory fixture started above.
                    if (-not $fixture.HasExited) { Stop-Process -Id $fixture.Id -ErrorAction SilentlyContinue }
                }
            }
        } finally { $env:BOOKMARK_PREVIEW_CODE = $oldCode; $env:BOOKMARK_PREVIEW_URL = $oldUrl }
    }
    Write-Output "Bookmark Wi-Fi tests passed. Output: $output"
} finally { Pop-Location }
