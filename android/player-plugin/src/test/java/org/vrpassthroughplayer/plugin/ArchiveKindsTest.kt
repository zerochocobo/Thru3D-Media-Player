package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test

class ArchiveKindsTest {
    @Test fun archiveVideosHaveMetadataButNoPlayableCapability() {
        val entries = org.json.JSONArray().put(org.json.JSONObject().put("title", "chapter/clip.mp4").put("kind", "file"))
            .put(org.json.JSONObject().put("title", "readme.txt").put("kind", "file"))
        ArchiveKinds.describeEntries(org.json.JSONObject().put("entries", entries))
        assertEquals("video", entries.getJSONObject(0).getString("kind"))
        assertFalse(entries.getJSONObject(0).has("uri"))
        assertEquals("file", entries.getJSONObject(1).getString("kind"))
    }
    @Test fun upstreamPacingHonorsSpacingAndCancellation() {
        val pacer = ArchiveRangePacer(25_000_000)
        pacer.await { false }
        val start=System.nanoTime()
        pacer.await { false }
        assertTrue(System.nanoTime()-start >= 24_000_000)
        assertThrows(InterruptedException::class.java){pacer.await { true }}
    }
    @Test fun archivesRemainVisibleAndDoNotBecomeVideo() {
        for (ext in listOf("ZIP", "CBZ", "RAR", "CBR", "7Z")) {
            assertTrue(ArchiveKinds.supported("Comic.$ext"))
            assertEquals("archive",MediaKinds.fileNameKind("Comic #1?.$ext"))
            assertTrue(MediaKinds.supportedFileName("Comic #1?.$ext"))
        }
        assertTrue(MediaKinds.supported("https://host/book.cbz?token=example"))
        assertTrue(MediaKinds.supported("book.tar")) // visible, explicit unsupported-format prompt
        assertFalse(ArchiveKinds.supported("book.tar"))
        assertFalse(ArchiveKinds.named("book.zip.exe"))
        assertEquals("image",MediaKinds.kind("page.png"))
        assertEquals("video",MediaKinds.kind("film.mp4"))
    }
}
