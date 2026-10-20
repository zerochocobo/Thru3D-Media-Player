# TIFF, HDR and OpenEXR photos

The shared photo pipeline recognizes TIFF/TIF, Radiance HDR and OpenEXR from local storage, SMB and supported cloud sources, including panorama naming/layout detection. Adjacent navigation and thumbnails use the same media-kind rules.

`native/tiff` uses libtiff 4.7.2 with libjpeg-turbo 3.1.2. `native/hdr` implements Radiance RGBE/XYZE decoding and uses OpenEXRCore 3.3.14, Imath 3.1.12 and libdeflate 1.24. The exact upstream source archives and original notices are retained under `third_party/tiff` and `third_party/openexr`; CMake verifies SHA-256 before extraction. These are source dependencies, with no prebuilt libraries or AI weights.

Decoding bounds dimensions, work buffers and region caches. TIFF uses strip/scanline or bounded tile reads. HDR/EXR use a private `T3DI` region cache for large-photo viewing. Display output is RGBA8: HDR/EXR use sampled log-average exposure, ACES mapping and sRGB encoding. This does not promise native headset HDR, ICC color management, deep EXR or every possible codec/format variant. Original-file export retains the original file.

The Morning Sky background is an 8192×4096 JPEG derived from Poly Haven's Kloppenheim 06 Pure Sky, under CC0. Attribution and the derived-file hash are in `app/godot/backgrounds/NOTICE.txt`; `tools/media/prepare_sky_background.py` records the conversion recipe. Supply the upstream EXR separately; it is not included here.

Native probes are in `tests/native/hdr_probe.cpp` and `tiff_probe.cpp`. Optional `tools/Test-HdrPhotos.py` and `Test-TiffPhotos.py` compare production Android pixels with independent Python references using synthetic or caller-supplied licensed fixtures; they require an explicitly selected device. They are not run by ordinary source verification. No personal photos or large original backgrounds are distributed.

## 中文说明

本地、SMB和支持的网盘可打开TIFF、Radiance HDR及OpenEXR照片／全景图。解码限制尺寸、缓冲及缓存占用；HDR／EXR经统一曝光、ACES及sRGB映射到8位显示，不代表头显原生HDR或覆盖全部格式变体。保留五份哈希锁定的上游源码与许可证，不包含预编译库、模型权重或个人图片。晨光天空保留CC0来源及转换脚本，原始EXR另行准备。
