$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$manifest = Get-Content (Join-Path $root 'third_party/moonshine/model.json') -Raw | ConvertFrom-Json
& "$PSScriptRoot/Build-ListeningRuntime.ps1"
foreach ($language in @('zh', 'en', 'ja')) {
    $directory = Join-Path $root "models/listening/$language"
    New-Item -ItemType Directory -Force $directory | Out-Null
    foreach ($property in $manifest.models.$language.files.PSObject.Properties) {
        & "$PSScriptRoot/Download-Artifact.ps1" -Uri $property.Value.url -Destination (Join-Path $directory $property.Name) -Sha256 $property.Value.sha256
    }
}
Write-Output 'Pinned Moonshine runtime and three listening models verified.'
