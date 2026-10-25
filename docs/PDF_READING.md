# PDF and paired-page reading

Local and supported remote PDFs share the photo pipeline: single pages, paired spreads, RTL direction, pairing offsets and PiP paging. PDF/archive/ordinary-photo layout preferences stay separate. History/favorites retain source identities for reopening instead of expired cloud URLs or whole-directory scans. Source permissions and history privacy still apply.

Android `PdfDocuments`/`PdfBridge` use the platform renderer. `PdfProxyInput`/`PdfReadCache` adapt seek/range sources with bounded reads and cancellation. Unsupported documents, password/encryption and source errors are explicit; no arbitrary PDF editing or universal DRM support is claimed. JPEG page/spread encodings and `ReadingPageCache` reduce repeated rendering. Complexity, memory and provider latency still matter.

Archive sources share directory memory and eligible inner-folder favorites. Paired ordinary images can use supported generated 3D/portrait paths. Neighboring decoded page/spread preparation is bounded; photo-3D conversion is not prefetched. OCR/translation is independently opt-in; see [comic reading](COMIC_READING.md).

Tests use synthetic pages and fake/loopback sources. Original documents and personal caches remain excluded. Host tests do not establish minimum-headset performance or every cloud provider/account capability.

PDF／杂志漫画支持单页、双页、阅读方向和画中画翻页，布局独立记忆；历史／收藏重开仍受权限／隐私约束。读取、缓存和邻页准备均有界。
