param(
    [string]$ToolRoot = $(if ($env:THRU3D_TOOL_ROOT) { $env:THRU3D_TOOL_ROOT } else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.cache\thru3d-toolchain' }),
    [switch]$ForExport
)
$ErrorActionPreference = 'Stop'
$workspace = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$pin = Get-Content (Join-Path $workspace 'third_party/geckoview/runtime.json') -Raw | ConvertFrom-Json
$sdk = Join-Path $ToolRoot 'android-sdk'
$platform = Join-Path $sdk "platforms/$($pin.compile_sdk)/android.jar"
if (-not (Test-Path -LiteralPath $platform)) {
    $manager = Join-Path $sdk 'cmdline-tools/latest/bin/sdkmanager.bat'
    if (-not (Test-Path -LiteralPath $manager)) { throw 'Android SDK manager unavailable.' }
    & $manager "platforms;$($pin.compile_sdk)"
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $platform)) { throw 'Browser compile SDK installation failed.' }
}
if (-not $ForExport) { Write-Host 'Browser compile SDK verified; runtime min/target SDK remain controlled by the player.'; return }

# Patch the generated Godot template reproducibly. Do not edit its targetSdk/minSdk:
# a newer compile API is required by GeckoView, not by the Quest/PICO device runtime.
$exportRoot = Join-Path $workspace 'app/godot/android/build'
$config = Join-Path $exportRoot 'config.gradle'
$text = [IO.File]::ReadAllText($config)
$values = @{
    androidGradlePlugin = "'$($pin.agp)'"
    kotlinVersion = "'$($pin.kotlin)'"
    compileSdk = "'$($pin.compile_sdk)'"
}
foreach ($key in $values.Keys) {
    $pattern = '(?m)^(\s*' + [Regex]::Escape($key) + '\s*:\s*)[^,\r\n]+(,)'
    if ([Regex]::Matches($text, $pattern).Count -ne 1) { throw "Godot template version field changed: $key" }
    $replacement = '${1}' + $values[$key] + '${2}'
    $text = [Regex]::Replace($text, $pattern, $replacement)
}
[IO.File]::WriteAllText($config, $text, [Text.UTF8Encoding]::new($false))
# Godot 4.7 supplies file:G:/... on Windows. Gradle 9 rejects this opaque URI;
# give Copy a File for drive paths, preserving Gradle's handling of other platforms.
$build = Join-Path $exportRoot 'build.gradle'
$text = [IO.File]::ReadAllText($build)
$oldCopy = '    into exportPath'
$newCopy = '    into(exportPath.startsWith("file:") && exportPath.substring(5).matches("[A-Za-z]:.*") ? new File(exportPath.substring(5)) : exportPath)'
if (-not $text.Contains($newCopy)) {
    if ([Regex]::Matches($text, [Regex]::Escape($oldCopy)).Count -ne 1) { throw 'Godot export copy destination changed.' }
    $text = $text.Replace($oldCopy, $newCopy)
    [IO.File]::WriteAllText($build, $text, [Text.UTF8Encoding]::new($false))
}
$properties = Join-Path $exportRoot 'gradle.properties'
$text = [IO.File]::ReadAllText($properties)
$exportProperties = @{
    'android.builtInKotlin' = 'false'
    'android.newDsl' = 'false'
    # Godot's Windows console wrapper waits for every descendant in its job.
    # An export-created daemon would keep a successful export alive indefinitely.
    'org.gradle.daemon' = 'false'
    'kotlin.compiler.execution.strategy' = 'in-process'
}
foreach ($key in $exportProperties.Keys) {
    $pattern = '(?m)^' + [Regex]::Escape($key) + '=.*$'
    $value = "$key=$($exportProperties[$key])"
    if ([Regex]::IsMatch($text, $pattern)) { $text = [Regex]::Replace($text, $pattern, $value) }
    else { $text += "`n$value`n" }
}
[IO.File]::WriteAllText($properties, $text, [Text.UTF8Encoding]::new($false))
Copy-Item -LiteralPath (Join-Path $workspace 'android/gradle/wrapper/gradle-wrapper.properties') -Destination (Join-Path $exportRoot 'gradle/wrapper/gradle-wrapper.properties') -Force
Write-Host "Godot export uses the pinned browser compile toolchain: $($pin.agp) / $($pin.kotlin) / $($pin.compile_sdk)."
