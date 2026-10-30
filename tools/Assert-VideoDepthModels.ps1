param([string]$Workspace = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'
$assetRoot = Join-Path $Workspace 'android/player-plugin/src/main/assets/depth-mnn'
foreach ($profile in @(@('zipdepth_video.json','manifest.json','depth.mnn',512,288), @('zipdepth_video_compat.json','compat_manifest.json','depth_compat.mnn',384,224))) {
    $pinned = Get-Content (Join-Path $Workspace "models/manifest/$($profile[0])") -Raw | ConvertFrom-Json
    $bundled = Get-Content (Join-Path $assetRoot $profile[1]) -Raw | ConvertFrom-Json
    foreach ($record in @($pinned, $bundled)) {
        if ($record.model -ne 'ZipDepth base' -or $record.usage -ne 'video' -or $record.width -ne $profile[3] -or $record.height -ne $profile[4] -or $record.compute_precision -ne 'fp16' -or $record.gpu_mode -ne 16) {
            throw "Video depth profile differs: $($profile[0])"
        }
    }
    $hash = (Get-FileHash -LiteralPath (Join-Path $assetRoot $profile[2]) -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($pinned.mnn_sha256 -ne $hash -or $bundled.mnn_sha256 -ne $hash) { throw "Video depth model differs: $($profile[2])" }
}
Write-Output 'Verified ZipDepth video models: 512x288 and 384x224, FP16 OpenCL.'
