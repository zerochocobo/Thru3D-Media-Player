# Picture plugins and interpolation

0.18.10 adds an Anime4K Plugins tab for compatible 2D animation. Turn it on to choose A/B/C and S/M/L/VL; values follow per-video settings. It takes the place of denoising/upscaling while retaining final sharpening/color. Availability and automatic stop guards depend on the current video path and load. Quest 3 observations do not establish Quest 2 or PICO acceptance.

Frame Interpolation (Beta) is off by default and remembered per video. Regular playback accepts compatible sources up to 4K/33fps; compatible 2D-to-3D accepts up to 33fps and an output pixel count per eye no greater than 2560×1440. Person passthrough and fisheye are excluded. Load and delayed depth updates can stop interpolation while video playback continues; it can be re-enabled for the current video. Anime4K and interpolation cannot run together. PICO availability is a first release for user testing, not completed hardware acceptance.

The MIT Anime4K sources, lock and coefficients are in third_party/anime4k, with a separate packaged notice. The generated GLES header is reproduced by tools/anime4k/Generate-Anime4kGlsl.ps1. The project does not include separate model weights, personal images, video samples or performance-study captures. Optional tools/anime4k/reference.py and tools/frame_interp/harness.py operate on separately supplied images/frames.

The project code remains GPL-3.0-only; retain upstream notices. Source/host tests do not establish motion quality, audio synchronization or performance on every headset.

## 0.19.1 Monochrome Film

The Plugins tab offers Standard, Film Noir and Soft styles plus Off/Low/Medium/High grain, remembered per video. Film-weighted grayscale, chroma compensation and a pivoted S curve preserve tonal separation; frame-varying grain is applied at the final grade stage in place of saturation. It works on the supported video drawing paths, including 2D-to-3D; depth inference still reads the color source. There is no local-contrast pass, grain does not follow disparity, and stereoscopic benefit is not claimed from source tests.
