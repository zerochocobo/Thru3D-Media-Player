# Picture-in-picture and image windows

The video control bar opens up to three numbered PiP windows. Video windows share the currently presented main frame and projection/effects state, without another video source or decoder per window. They are views of the current video rather than independent simultaneous movies.

Select a region, adjust zoom from 1× to 8×, move a window with grip and adjust distance with the same-hand stick. Shape and individual close controls remain available; numbered zoom preferences are retained. Windows stay upright. Stereo zoom compensates disparity where supported; native stereo and generated-depth eyes keep separate alignment rules.

A window can show a static image through the existing source picker. A bounded asynchronous loader handles decoded resources and cancellation. Closing, replacing an image, changing modes or changing the playback source releases relevant resources. These windows do not implement animated images or independent video playback. Magnification and corner scaling use the displayed image geometry.

Supported runtimes use `video_pip_compositor.gd` and `native/xr-layer` with a shared atlas and independent compositor layers. `pip_shader.cmake` derives the atlas shader from the production video shaders, keeping eye clamps, color/mask math and cached fisheye maps tied to the same source. Unsupported cases use the existing rendering path. Adaptive quality prioritizes the main video; this is not a fixed frame-rate or thermal guarantee for every headset.

## Source checks

`tools/Test-VideoPip.ps1 -Godot <executable>` runs host state and OpenGL checks. `tools/Test-PipAtlasGpu.py --header <generated-pip_shader_sources.h> --output <report>` compares shader pixels using ModernGL, NumPy and Pillow; the desktop OES stand-in does not establish Android EGL import behavior.

`tests/native/video_pip_compile/CMakeLists.txt` builds the compositor with a caller-configured Android NDK/CMake toolchain. Generated headers and native output belong in `build/`.

Optional device scripts require an explicitly selected device and a complete installed Debug build. They operate playback and should run only during an authorized device test. Fixture generators produce synthetic media. No personal accounts, images, media or captured performance logs accompany this repository. Host checks do not establish headset performance or Quest 2/PICO Neo3 acceptance.

## 中文说明

最多三个画中画共享主视频当前帧，可选择区域、放大、移动、调距离及单独关闭，也可切换为静态图片窗口；不是多视频独立解码。图片加载、换源及关闭采用有界资源管理，支持设备上的合成层与图集优先保证主视频。宿主逻辑／像素检查不代表所有头显性能及交互均已验收。
