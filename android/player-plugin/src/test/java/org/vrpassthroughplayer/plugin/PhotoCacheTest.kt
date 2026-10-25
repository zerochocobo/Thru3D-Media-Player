package org.vrpassthroughplayer.plugin

import java.io.File
import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Test

class PhotoCacheTest {
    @Test fun cloudPdfBlocksParticipateInCleanupButActiveDocumentRemainsReadable() {
        val cache = Files.createTempDirectory("pdf-source-cache").toFile()
        try {
            val stale = put(cache, "pdf-sources/source-stale.blocks", 11)
            val active = put(cache, "pdf-sources/source-active.blocks", 13)
            assertEquals(2L to 24L, PhotoCache.usage(cache))
            PhotoCache.clear(cache, setOf(active))
            assertFalse(stale.exists()); assertTrue(active.exists())
            PhotoCache.clear(cache, emptySet())
            assertFalse(active.exists()); assertEquals(0L to 0L, PhotoCache.usage(cache))
        } finally { cache.deleteRecursively() }
    }
    private fun put(root: File, path: String, size: Int): File = File(root, path).apply {
        parentFile!!.mkdirs(); writeBytes(ByteArray(size))
    }

    @Test fun clearRemovesCrashLeftoversButPreservesLivePhotosAndOtherCaches() {
        val cache = Files.createTempDirectory("photo-cache-clear").toFile()
        try {
            put(cache, "photos/old/source", 11)
            put(cache, "photos/old/depth.bin", 13)
            put(cache, "photos/old/stereo-100.png", 17)
            put(cache, "photo-preloads/old/stereo-150.png", 19)
            val live = put(cache, "photo-preloads/live/stereo-100.png", 23)
            val transferring = put(cache, "photos/loading/source", 29)
            val model = put(cache, "photo-depth-mnn/program", 31)
            val cover = put(cache, "media-servers/cover.jpg", 37)
            assertEquals(6L to 112L, PhotoCache.usage(cache))
            PhotoCache.clear(cache, setOf(live.parentFile!!, transferring.parentFile!!))
            assertFalse(File(cache, "photos/old").exists())
            assertFalse(File(cache, "photo-preloads/old").exists())
            assertTrue(live.isFile); assertTrue(transferring.isFile)
            assertTrue(model.isFile); assertTrue(cover.isFile)
            assertEquals(2L to 52L, PhotoCache.usage(cache))
            PhotoCache.clear(cache, emptySet())
            assertEquals(0L to 0L, PhotoCache.usage(cache))
        } finally { cache.deleteRecursively() }
    }

    @Test fun missingDirectoriesAreAnEmptyCache() {
        val cache = Files.createTempDirectory("photo-cache-empty").toFile()
        try {
            assertEquals(0L to 0L, PhotoCache.usage(cache))
            PhotoCache.clear(cache, emptySet())
            assertFalse(File(cache, "photos").exists())
        } finally { cache.deleteRecursively() }
    }

    @Test fun pdfCleanupPreservesOnlyPagesBeingCopiedAndNeverOriginalDocuments() {
        val cache = Files.createTempDirectory("pdf-cache-clear").toFile()
        try {
            val old = put(cache, "pdf-pages/page-old.png", 11)
            val copying = put(cache, "pdf-pages/page-copying.png", 13)
            val source = put(cache, "documents/book.pdf", 17)
            assertEquals(2L to 24L, PhotoCache.usage(cache))
            PhotoCache.clear(cache, setOf(copying))
            assertFalse(old.exists()); assertTrue(copying.isFile); assertTrue(source.isFile)
            PhotoCache.clear(cache, emptySet())
            assertFalse(copying.exists()); assertTrue(source.isFile)
            assertEquals(0L to 0L, PhotoCache.usage(cache))
        } finally { cache.deleteRecursively() }
    }

    @Test fun archiveCopiesAndPartialDownloadsAreCountedAndClearedAfterSessionRelease() {
        val cache = Files.createTempDirectory("archive-cache-clear").toFile()
        try {
            val original = put(cache, "comic-pages/comic-source-complete.rar", 41)
            val interrupted = put(cache, "comic-pages/comic-source-interrupted.rar", 43)
            val page = put(cache, "comic-pages/comic-session/page-0.jpg", 47)
            val credentials = put(cache, "accounts/persistent", 53)
            val model = put(cache, "photo-depth-mnn/program", 59)
            assertEquals(3L to 131L, PhotoCache.usage(cache))
            // The same global clear runs at startup and in settings. Live sessions survive it.
            PhotoCache.clear(cache, setOf(File(cache, "comic-pages")))
            assertTrue(original.isFile); assertTrue(interrupted.isFile); assertTrue(page.isFile)
            PhotoCache.clear(cache, emptySet())
            assertEquals(0L to 0L, PhotoCache.usage(cache))
            assertFalse(original.exists()); assertFalse(interrupted.exists()); assertFalse(page.exists())
            assertTrue(credentials.isFile); assertTrue(model.isFile)
        } finally { cache.deleteRecursively() }
    }
}
