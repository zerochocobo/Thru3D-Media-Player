param([string]$ToolRoot=$(if ($env:THRU3D_TOOL_ROOT) { $env:THRU3D_TOOL_ROOT } else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.cache/thru3d-toolchain' }), [string]$ProjectDirectory='')
$ErrorActionPreference='Stop'
$workspace=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if(!$ProjectDirectory){$ProjectDirectory=Join-Path $workspace 'app/godot'}
$ProjectDirectory=[IO.Path]::GetFullPath($ProjectDirectory)
if(!(Test-Path -LiteralPath (Join-Path $ProjectDirectory 'project.godot'))){throw 'Godot project is missing.'}
$lock=Get-Content (Join-Path $PSScriptRoot 'toolchain.lock.json') -Raw | ConvertFrom-Json
$records=@($lock.downloads | Where-Object { $_.name -eq 'Godot Android templates' })
if($records.Count -ne 1){throw 'Pinned Godot template archive is ambiguous.'}
$record=$records[0];$version=[string]$record.version
if(!$lock.godot.version.StartsWith($version+'.official.')){throw 'Godot engine and template pin differ.'}
$android=Join-Path $ProjectDirectory 'android'
$destination=Join-Path $android 'build'
$marker=Join-Path $android '.build_version'
$buildScript=Join-Path $destination 'build.gradle'
if((Test-Path -LiteralPath $buildScript) -and (Test-Path -LiteralPath $marker)){
    if(([IO.File]::ReadAllText($marker)).Trim() -ne $version){throw 'Existing Android template version differs; review it before replacing.'}
    Write-Output "Android template already prepared: $version"
    return
}
if((Test-Path -LiteralPath $marker) -or ((Test-Path -LiteralPath $destination) -and @(Get-ChildItem -LiteralPath $destination -Force).Count)){
    throw 'Partial Android template exists; refusing to overwrite its files.'
}
foreach($path in @($android,$destination)){
    if((Test-Path -LiteralPath $path) -and ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){
        throw 'Android template destination must not be a shared directory link.'
    }
}
$archive=Join-Path $ToolRoot ('downloads/'+[IO.Path]::GetFileName($record.path))
$source=Join-Path $ToolRoot "godot-templates/$version/android_source.zip"
if(!(Test-Path -LiteralPath $archive) -or (Get-Item -LiteralPath $archive).Length -ne $record.bytes -or
    (Get-FileHash -LiteralPath $archive).Hash.ToLowerInvariant() -ne $record.sha256){throw 'Godot template archive differs from the verified toolchain pin.'}
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip=[IO.Compression.ZipFile]::OpenRead($archive)
try{
    $entry=$zip.GetEntry('templates/android_source.zip')
    if(!$entry){throw 'Pinned archive has no Android source template.'}
    $stream=$entry.Open();$sha=[Security.Cryptography.SHA256]::Create()
    try{$expected=[Convert]::ToHexString($sha.ComputeHash($stream))}finally{$stream.Dispose();$sha.Dispose()}
}finally{$zip.Dispose()}
if(!(Test-Path -LiteralPath $source) -or (Get-FileHash -LiteralPath $source).Hash -ne $expected){throw 'Installed Android source template differs from the verified archive.'}
New-Item -ItemType Directory -Force -Path $android | Out-Null
# The CLI install flag acts only during export. Extract the same official source
# before applying our reproducible host/SDK overlays, without exporting a dummy APK.
[IO.Compression.ZipFile]::ExtractToDirectory($source,$destination)
if(!(Test-Path -LiteralPath $buildScript) -or !(Test-Path -LiteralPath (Join-Path $destination 'src/main/java/com/godot/game/GodotApp.java'))){throw 'Android source template is incomplete.'}
[IO.File]::WriteAllText($marker,$version+"`n",[Text.UTF8Encoding]::new($false))
Write-Output "Verified Android source template prepared: $version"
