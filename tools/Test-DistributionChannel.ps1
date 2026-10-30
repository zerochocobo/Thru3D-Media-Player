param([string]$ToolRoot = $(if ($env:THRU3D_TOOL_ROOT) { $env:THRU3D_TOOL_ROOT } else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.cache\thru3d-toolchain' }))
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
. "$PSScriptRoot/environment/Activate-QuestEnvironment.ps1" -ToolRoot $ToolRoot
$output = Join-Path $workspace 'build/output/distribution-channel'
New-Item -ItemType Directory -Force $output | Out-Null
& $env:GODOT_EXE --headless --xr-mode off --path "$workspace/app/godot" --script res://tests/test_distribution_channel.gd -- $output 2>&1 | Tee-Object "$output/host.log"
if ($LASTEXITCODE -ne 0 -or (Get-Content "$output/host.log" -Raw) -match '(?m)^(SCRIPT ERROR:|SHADER ERROR:|ERROR:)') { throw 'Distribution channel host regression failed.' }

# Use settings serialized by the actual engine, not a synthetic Variant encoder.
Add-Type -AssemblyName System.IO.Compression.FileSystem
foreach ($channel in @('standard','pico_cn_store','quest_store','unknown')) {
    $archive = Join-Path $output "$channel.zip"
    if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive }
    $zip = [IO.Compression.ZipFile]::Open($archive, [IO.Compression.ZipArchiveMode]::Create)
    try { [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, (Join-Path $output "$channel.binary"), 'assets/project.binary') }
    finally { $zip.Dispose() }
}
& "$PSScriptRoot/Assert-DistributionPackaged.ps1" -ArchivePath "$output/standard.zip" -ExpectedChannel standard
& "$PSScriptRoot/Assert-DistributionPackaged.ps1" -ArchivePath "$output/pico_cn_store.zip" -ExpectedChannel pico_cn_store
& "$PSScriptRoot/Assert-DistributionPackaged.ps1" -ArchivePath "$output/quest_store.zip" -ExpectedChannel quest_store
foreach ($case in @(@('standard','pico_cn_store'), @('pico_cn_store','standard'), @('unknown','standard'), @('quest_store','standard'), @('standard','quest_store'))) {
    $rejected = $false
    try { & "$PSScriptRoot/Assert-DistributionPackaged.ps1" -ArchivePath (Join-Path $output ($case[0] + '.zip')) -ExpectedChannel $case[1] }
    catch { if ($_.Exception.Message -notmatch 'channel mismatch') { throw }; $rejected = $true }
    if (-not $rejected) { throw 'Wrong-channel package was accepted.' }
}

# All invalid combinations must fail before any model preparation or build starts.
foreach ($arguments in @(
    @{ XrVendor='Quest'; BuildType='Release'; PicoChinaStore=$true; AndroidVersionCode=49 },
    @{ XrVendor='Pico'; BuildType='Debug'; PicoChinaStore=$true; AndroidVersionCode=49 },
    @{ XrVendor='OpenXR'; BuildType='Release'; AndroidVersionCode=49 },
    @{ XrVendor='Pico'; BuildType='Release'; PicoChinaStore=$true }
)) {
    $rejected = $false
    try { & "$PSScriptRoot/Build-Player.ps1" @arguments }
    catch { if ($_.Exception.Message -notmatch 'limited to PICO Release|requires an explicit AndroidVersionCode') { throw }; $rejected = $true }
    if (-not $rejected) { throw 'Invalid channel/build-number combination was accepted.' }
}
foreach ($arguments in @(
    @{ QuestStore=$true; XrVendor='Quest'; BuildType='Debug' },
    @{ QuestStore=$true; XrVendor='Pico'; BuildType='Release' },
    @{ QuestStore=$true; XrVendor='OpenXR'; BuildType='Release' }
)) {
    $rejected = $false
    try { & "$PSScriptRoot/Build-Player.ps1" @arguments }
    catch { if ($_.Exception.Message -notmatch 'limited to QUEST Release') { throw }; $rejected = $true }
    if (-not $rejected) { throw 'Invalid Meta store target was accepted.' }
}

# Exercise the actual build-number/name resolution without signing or assembling an APK.
$buildSource = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Build-Player.ps1'))
$resolveStart = $buildSource.IndexOf('$presetText =')
$resolveEnd = $buildSource.IndexOf('$originalProjectConfig = [IO.File]::ReadAllBytes', $resolveStart)
if ($resolveStart -lt 0 -or $resolveEnd -lt 0) { throw 'Build-number resolution block not found.' }
$resolve = [ScriptBlock]::Create($buildSource.Substring($resolveStart, $resolveEnd - $resolveStart))
function Test-UploadResolution([bool]$China, [int]$Code) {
    $exportPresetsPath = Join-Path $workspace 'app/godot/export_presets.cfg'
    $exportPreset = 'PICO 4'; $XrVendor = 'Pico'; $BuildType = 'Release'
    $QuestStore = $false; $UncompressedNativeLibraries = $false
    $PicoChinaStore = $China; $AndroidVersionCode = $Code
    $customApkName = $false; $appVersion = '0.15.0'
    . $resolve
    if ($expectedVersionCode -ne $Code) { throw 'Explicit upload build number was lost.' }
    $name = if ($China) { 'PICO-CN-STORE' } else { 'PICO' }
    if ($ApkName -notmatch ("Thru3D-$name-0\.15\.0-vc$Code-release-\d{8}\.apk")) { throw 'Channel/build number missing from APK filename.' }
}
$sourceCode = [int][regex]::Match([IO.File]::ReadAllText((Join-Path $workspace 'app/godot/export_presets.cfg')), '(?m)^version/code=(\d+)').Groups[1].Value
Test-UploadResolution $false ($sourceCode + 1)
Test-UploadResolution $true ($sourceCode + 2)
$rejected = $false
try { Test-UploadResolution $true $sourceCode }
catch { if ($_.Exception.Message -notmatch 'must exceed the source versionCode') { throw }; $rejected = $true }
if (-not $rejected) { throw 'Reused source build number was accepted as a new upload.' }

# Resolve the actual public entry point without reaching model/signing preparation.
$headerEnd = $buildSource.IndexOf('function Convert-HexString')
if ($headerEnd -lt 0) { throw 'Build header not found.' }
$header = [ScriptBlock]::Create($buildSource.Substring(0, $headerEnd))
function Test-MetaResolution([bool]$Stored) {
    . $header -QuestStore -XrVendor Quest -BuildType Release -UncompressedNativeLibraries:$Stored
    if ($applicationId -ne 'com.thru3d.quest' -or $distributionChannel -ne 'quest_store') { throw 'Meta identity/channel resolution failed.' }
    $exportPresetsPath = Join-Path $workspace 'app/godot/export_presets.cfg'
    $appVersion = '0.15.2'
    . $resolve
    $suffix = if ($Stored) { '-NO-NATIVE-COMPRESSION' } else { '' }
    if ($ApkName -notmatch ('Thru3D-QUEST-META-STORE-0\.15\.2' + $suffix + '-release-\d{8}\.apk')) { throw 'Meta archive name lacks channel/variant.' }
}
Test-MetaResolution $false
Test-MetaResolution $true

$tokens = $null; $errors = $null
[void][Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Build-Player.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Build-Player PowerShell syntax regression.' }
Write-Output 'Distribution packaging: engine settings, wrong-channel rejection, PICO/Meta parameter guards and identity resolution passed.'
