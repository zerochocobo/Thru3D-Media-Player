# Scenery and private panoramas

0.16.5 provides a unified scenery picker for cinema, bundled panoramas, dark and passthrough choices. The shared library supports previews, batch import, rename/remove and progress. Global and image modes reference shared assets but save separate choices; image mode defaults independently and excludes the cinema. The image settings can use the current panorama as a background. Reading-mode scaffolding in source is not an exposed new background feature.

Imported originals, generated previews and content-addressed bindings live under the application's private background library, outside public Git. Removing a caller asset and changing a mode selection are distinct operations. The built-in previews are runtime UI assets, not personal imports or store promotion. Belfast/Morning/Milky Way previews derive from the attributed originals; the Milky Way derivative retains CC BY4.0 and ESO/S. Brunier credit. The cinema preview comes from the project environment; actual generated scene/texture payloads remain separately prepared.

统一入口可预览与管理场景，全局／图片共享素材但独立保存选择；私人导入、预览缓存及绑定数据不公开。图片不继承影院；阅读模式源代码预留不等于已开放功能。内置缩略图保留原背景许可与署名。

## 0.17.2 scene controls and distribution boundary

Distributed builds include beach cinema, loungers/free movement, sun/moon and day/night interaction and nighttime handheld fireworks. Scenery sections use four columns and compact dividers; the add-panorama card follows custom backgrounds. Quest 3 observations do not certify Quest 2/PICO Neo3; lower tiers limit refresh rate and dynamic shadows. Runtime source and shaders are public, while private models, textures, scene bundle and generated audio remain separately supplied. All build types now require those assets and fail if missing; the former Debug exclusion is removed. See [model and scenery preparation](MODELS.md).

0.17.3 adds lower-cost Adreno6xx beach shader paths, darker low-tier nighttime water, lounger adjustments and Traditional Chinese/Japanese labels. Low-tier compositor video sampling defaults to unfiltered. These changes do not establish Quest2/PICONeo3 scene/AI acceptance; external scenery payloads remain required and excluded from public Git.

0.17.4 adds beach interaction/prop and shoreline/celestial source updates, corrected panel/controller ownership and shared inexpensive sky rendering. Raw scene/model/texture/audio payloads, celestial generated audio and tools/beach studies remain excluded. The public runtime integration is not a standalone licensed asset bundle or low-tier performance guarantee.

0.17.5 retains beach teleport/tabletop/foley/meteor runtime updates without exporting model/scene/texture/audio payloads or modeling fixtures. External resources remain mandatory for complete builds; no personal audio samples are included.

## User scene import in 0.17.7

Debug builds expose glTF and supported Unity scene bundles under My scenes on supported platforms. The importer budgets geometry and textures, can compress eligible textures to ETC2, and can use the playing screen as a light source. Release builds expose the panorama collection. The repository includes importer source. Users supply scene bundles and scenery assets separately.

0.17.7 的 Debug 构建可在支持平台的「我的场景」导入 glTF 和受支持的 Unity 场景包。Release 构建提供全景图库。场景包与场景资源由用户另行准备。
