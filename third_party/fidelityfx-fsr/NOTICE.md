# AMD FidelityFX Super Resolution 1

The EASU upscaling and RCAS sharpening algorithms adapted in `native/xr-layer/picture_glsl.h` and used by `native/xr-layer/layer_copy.cpp` and `native/xr-layer/video_layer.cpp` are from AMD FidelityFX FSR 1. Copyright (c) 2021 Advanced Micro Devices, Inc. All rights reserved. Distributed under the accompanying [MIT license](LICENSE.txt).

Upstream source: https://github.com/GPUOpen-Effects/FidelityFX-FSR/tree/a21ffb8f6c13233ba336352bdff293894c706575/ffx-fsr

License source: https://github.com/GPUOpen-Effects/FidelityFX-FSR/blob/a21ffb8f6c13233ba336352bdff293894c706575/license.txt

Project adaptations include GLSL integration with Android external and 2D textures, the head-facing processing window, denoising, adjustable strength, colour grading and compositor-layer rendering. These notices preserve the upstream terms; the project root GPL license is unchanged.
