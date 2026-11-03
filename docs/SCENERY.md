# Scenery and private panoramas

0.16.5 provides a unified scenery picker for cinema, bundled panoramas, dark and passthrough choices. The shared library supports previews, batch import, rename/remove and progress. Global and image modes reference shared assets but save separate choices; image mode defaults independently and excludes the cinema. The image settings can use the current panorama as a background. Reading-mode scaffolding in source is not an exposed new background feature.

Imported originals, generated previews and content-addressed bindings live under the application's private background library, outside public Git. Removing a caller asset and changing a mode selection are distinct operations. The built-in previews are runtime UI assets, not personal imports or store promotion. Belfast/Morning/Milky Way previews derive from the attributed originals; the Milky Way derivative retains CC BY4.0 and ESO/S. Brunier credit. The cinema preview comes from the project environment; actual generated scene/texture payloads remain separately prepared.

统一入口可预览与管理场景，全局／图片共享素材但独立保存选择；私人导入、预览缓存及绑定数据不公开。图片不继承影院；阅读模式源代码预留不等于已开放功能。内置缩略图保留原背景许可与署名。
