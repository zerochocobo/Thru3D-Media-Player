# Generates native/xr-layer/anime4k_glsl.h from the pinned Anime4K shaders in third_party/anime4k/glsl.
# The network order (restore, restore_soft, upscale, upscale_denoise; S, M, L, VL each) is the order
# anime4k.cpp indexes by.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$glsl = Join-Path $root 'third_party/anime4k/glsl'
$networks = @()
foreach ($kind in @(@('restore', 'Anime4K_Restore_CNN_'), @('restore_soft', 'Anime4K_Restore_CNN_Soft_'),
                    @('upscale', 'Anime4K_Upscale_CNN_x2_'), @('upscale_denoise', 'Anime4K_Upscale_Denoise_CNN_x2_'))) {
    foreach ($tier in @('S', 'M', 'L', 'VL')) {
        $networks += "$($kind[0])_$($tier.ToLower())=$(Join-Path $glsl "$($kind[1])$tier.glsl")"
    }
}
& python -I (Join-Path $PSScriptRoot 'convert.py') (Join-Path $root 'native/xr-layer/anime4k_glsl.h') @networks
if ($LASTEXITCODE -ne 0) { throw "convert.py failed: $LASTEXITCODE" }
