# Debug reading source scope

The source tree contains the reading implementation and its dependencies because they are part of the frozen source snapshot. Its reader entry is Debug-only (BookReader.offered); it is not announced as a Release feature in 0.18.11.

The book font catalog records separate font sizes, hashes, upstream sources and OFL-1.1 labels. Only catalog metadata and generated sample previews are included. Font binaries, user books, rendered user pages, marks, narration caches and account data are excluded. Obtain the matching upstream font and its license separately before supplying a font payload.

BookFonts inherits SceneGallery source selection. This export has no default private scene/font service origins, so private production font mirrors are unavailable. Publishing/upload tools and their credentials are not exported. The standalone book_preview_probe uses user-supplied synthetic book.json/page images; no book media is bundled.
