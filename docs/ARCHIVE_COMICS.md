# Archive comic reading

ZIP/CBZ, RAR/CBR and 7z archives can appear as folders/pages through the existing library and photo navigation. The Kotlin `ArchiveBridge`, page-request/pacing classes and Go `comic_*` adapters share bounded indexing, decoded-page size limits, cancellation, thumbnails and browse memory. Local and supported SMB/cloud sources use the same app-owned stream routing; provider-side extraction is not used.

Compatible encrypted formats prompt for a password. Explicit remembering uses the app-private encrypted password book and verified archive association. It does not try the entire password book against a remote file. Book entries, unlock associations, archive contents and original user files are excluded from this repository. Source fixtures use synthetic passwords and images only.

Solid archives and some algorithms are unsupported; maximum entry/page/index limits fail explicitly. Remote reading requires seek/range support and can read archive metadata plus compressed page data. It does not promise every archive codec, zero network traffic, or support for all provider encryption/extraction APIs.

`tools/Generate-ComicFixtures.py` generates disposable fixtures under `build/output/` using 7-Zip/WinRAR. Go `comic_*_test.go` uses `COMIC_FIXTURES`; optional `COMIC_LARGE_SAMPLE` tests caller-owned samples and should remain unset during synthetic verification. Use a read-only Go source overlay when exercising the pinned OpenList cache; do not overwrite a shared cache or substitute an AAR/APK for current source.

压缩漫画复用媒体库、缩略图和图片导航；支持兼容的ZIP／RAR／7z及部分加密格式，不支持固实压缩和所有算法。密码簿与成功解锁关联保存在应用私有加密存储，不随源码分发；远程读取仍受有界索引、随机读取和取消规则限制。
