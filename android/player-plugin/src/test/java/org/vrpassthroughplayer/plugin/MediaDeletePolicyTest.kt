package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test
import java.nio.file.Files

class MediaDeletePolicyTest {
    @Test fun rejectsEscapesRootsDirectoriesAndNonMedia() {
        val root = Files.createTempDirectory("media-delete-policy").toFile()
        try {
            val file = root.resolve("video.mp4").apply { writeText("fixture") }
            assertEquals(file, MediaDeletePolicy.local(file, listOf(root)))
            assertTrue(MediaDeletePolicy.regular(file))
            val photo = root.resolve("照片 [Album] EXC#95_LRF_Full_SBS.jpg").apply { writeText("fixture") }
            assertEquals(photo, MediaDeletePolicy.local(photo, listOf(root)))
            assertThrows(IllegalArgumentException::class.java) { MediaDeletePolicy.local(root.resolve("photo.jpg#notes.nfo"), listOf(root)) }
            assertThrows(IllegalArgumentException::class.java) { MediaDeletePolicy.local(file, listOf(root.resolve("other"))) }
            assertThrows(IllegalArgumentException::class.java) { MediaDeletePolicy.local(root, listOf(root)) }
            assertThrows(IllegalArgumentException::class.java) { MediaDeletePolicy.local(root.resolve("../escape.mp4"), listOf(root)) }
            assertThrows(IllegalArgumentException::class.java) { MediaDeletePolicy.local(root.resolve("subtitle.srt"), listOf(root)) }
            val folder = root.resolve("folder.mp4").apply { mkdir() }
            assertFalse(MediaDeletePolicy.regular(folder))
            MediaDeletePolicy.unchanged(7, 1, 7, 1)
            assertThrows(IllegalStateException::class.java) { MediaDeletePolicy.unchanged(8, 1, 7, 1) }
            assertThrows(IllegalStateException::class.java) { MediaDeletePolicy.unchanged(7, 2, 7, 1) }
        } finally { root.listFiles()?.forEach { it.delete() }; root.delete() }
    }
    @Test fun rejectsSmbShareAndDangerousPaths() {
        assertEquals("Video/旅行.mp4", MediaDeletePolicy.smbPath("Video/旅行.mp4"))
        for (path in listOf("Video", "Video/../other.mp4", "Video//a.mp4", "Video/a\\b.mp4", "Video/a?.mp4", "Video/a*.mp4", "Video/a.srt", "Video/image.jpg#notes.nfo"))
            assertThrows(IllegalArgumentException::class.java) { MediaDeletePolicy.smbPath(path) }
    }

    @Test fun renameAcceptsListedFilesThroughTheSameLocalAndSmbPathChecks() {
        val root = Files.createTempDirectory("rename-root").toFile().canonicalFile
        try {
            for (name in listOf("a.MP4", "a.jpg", "a.FlAc", "a.pdf", "a.epub", "a.zip", "a.zh.SRT", "a.GLB")) {
                assertEquals(root.resolve(name), MediaDeletePolicy.local(root.resolve(name), listOf(root), forRename = true))
                assertEquals("share/$name", MediaDeletePolicy.smbPath("share/$name", forRename = true))
            }
            for (name in listOf("a.nfo", "VIDEO_TS.IFO", "../a.srt")) {
                assertThrows(IllegalArgumentException::class.java) { MediaDeletePolicy.smbPath("share/$name", forRename = true) }
                assertThrows(IllegalArgumentException::class.java) { MediaDeletePolicy.local(root.resolve(name), listOf(root), forRename = true) }
            }
        } finally { root.delete() }
    }

    @Test fun smbAcceptsLiteralHashAndPercentWithoutInterpretingEscapes() {
        for (path in listOf("Video/#合集%2F/图#1%252F.jpg", "Video/a%2f.mp4", "Video/100%.pdf")) {
            assertEquals(path, MediaDeletePolicy.smbPath(path))
        }
        val folder = "Video/#合集%2F"
        assertEquals(folder, MediaDeletePolicy.smbPath(folder, folder = true))
    }
}
