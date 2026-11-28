# Spatial reading source

0.19.0 enables reading in Release. Open compatible EPUB, MOBI, AZW3, TXT and PDF from local, SMB, cloud and DLNA sources. Controllers or hand gestures turn pages; Grip moves the book. Contents, search, bookmarks, read-aloud, auto turning, day/night paper, typography, favorites and per-book time are implemented. Long TXT books paginate the current chapter before continuing in the background. Protected or incompatible books are outside this capability.

The eight-font catalog includes sizes, SHA-256, upstream links and OFL-1.1 labels. Metadata and sample previews are included; font binaries and upstream license copies must be obtained separately. BookFonts inherits SceneGallery source selection: default private scene/font origins are empty in this export. Supply licensed fonts or explicitly configure your own service. Publishing tools and credentials are excluded.

User books, annotations, reading progress, narration caches and account data are not shipped in Git. The product’s offline sample media pack is also excluded. The standalone book_preview_probe accepts caller-supplied book.json/page images. See [external resources](EXTERNAL_RESOURCES.md) and [models/narration](MODELS.md).

## 0.19.1 reading controls

Additional paper colors and user-selected subtle page images apply to text ebooks. Page animation and its sound can be chosen independently. Voice audition and existing local cloned voices are available for narration; private voice payloads remain excluded. Reading and attic settings select among five original wands; the visible attic owns the wand choice while reading there. Meshes/materials are generated separately with tools/wands; menu previews and the shader are public.
