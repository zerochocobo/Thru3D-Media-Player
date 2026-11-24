# Extended photo formats (0.16.1)

The production image core adds static/animated AVIF, APNG, GIF, animated WebP and supported DNG/CR2/CR3/NEF/NRW/ARW/RAF/RW2/ORF/PEF/SRW camera RAW. RAW support depends on the camera variant and embedded/developable data; an extension is not a guarantee. Existing JPEG/PNG/WebP/HEIF/TIFF/HDR/OpenEXR paths remain. Animation timing, frame disposal and bounded memory are handled separately; pause an animation before using compatible still-image effects. Emby/Jellyfin photos use original-source access and album navigation with existing eligible 3D/portrait paths.

`native/image` and `third_party/image/sources.json` retain the exact source pins for libavif, dav1d, LibRaw, libwebp, Little CMS, Meson and zlib. Original licenses/notices are included; the LibRaw build selects its LGPL route, with both upstream license texts retained. Source archives are exact reviewed upstream inputs, not runtime libraries or personal backups. Godot/Android JNI preparation uses these sources; `Assert-ImagePackaged.ps1` checks packaging. No decoder binary, original personal photos, camera data or model weight is published.

Optional host checks: `tools/Test-ImageFormatsHost.sh`, `tools/Test-ImageFormats.py`, and the synthetic/public-corpus preparation scripts under `tools/media/`. Their source catalog is metadata; payloads are supplied/generated separately and remain ignored. Check source rights before supplying your own images. Source/desktop validation does not establish all formats, cameras or headset performance.

0.16.2 bounds large-image and animation allocations and chooses supported downscaled/embedded previews when required. Adaptive neighbouring photo/portrait caching admits work only under measured headroom; prepared textures are reusable, but warming can pause or evict work. Contextual controls and source-relative rotation retain image-specific limits. No unlimited image-size, cache-hit or sustained-headset-FPS guarantee is implied.

## 0.18.9 media-server artwork

Compatible APNG and animated WebP artwork can animate in media-server covers, posters, actor portraits, episode images, stills and detail backgrounds. Pointing at a thumbnail starts it; full-size previews play automatically. Availability depends on source format and server access, with bounded caching and cancellation. No personal artwork or server credentials are distributed.
