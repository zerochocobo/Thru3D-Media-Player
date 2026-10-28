package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayInputStream
import java.nio.file.Files

class BackgroundAudioFilesTest {
    @Test fun recordingLosslessAndDtsFilesFollowTheSameTransactionalLibraryRules() {
        for (extension in listOf("m4a", "wav", "flac", "dts", "dtshd")) {
            assertTrue(MediaKinds.audio("Music.$extension".uppercase()))
            assertTrue(MediaKinds.supportedFileName("music #1?.$extension"))
            val directory = folder()
            val saved = BackgroundAudioFiles.copy(ByteArrayInputStream(byteArrayOf(1, 2, 3)), directory, extension)
            assertTrue(saved.created)
            assertFalse(BackgroundAudioFiles.copy(ByteArrayInputStream(byteArrayOf(1, 2, 3)), directory, extension).created)
            assertTrue(BackgroundAudioFiles.remove(directory, saved.file.path)); directory.delete()
        }
        assertEquals(512L * 1024 * 1024, BackgroundAudioFiles.MAX_BYTES)
    }
    @Test fun sizeLimitUsesLongAndDoesNotLimitTheWholeLibrary() {
        val directory = folder()
        assertThrows(IllegalArgumentException::class.java) { BackgroundAudioFiles.copy(ByteArrayInputStream(byteArrayOf(1)), directory, "flac", BackgroundAudioFiles.MAX_BYTES + 1) }
        // The exact per-file boundary is accepted, then completeness is checked.
        assertThrows(IllegalStateException::class.java) { BackgroundAudioFiles.copy(ByteArrayInputStream(byteArrayOf(1)), directory, "flac", BackgroundAudioFiles.MAX_BYTES) }
        // Virtual metadata exercises >4 GiB totals without allocating a giant test file.
        val large = object : java.io.File(directory, "import_existing.flac") {
            override fun isFile() = true
            override fun length() = 4L * 1024 * 1024 * 1024 + 1
        }
        val largeLibrary = object : java.io.File(directory.path) {
            override fun listFiles() = directory.listFiles()!!.plus(large)
        }
        val saved = BackgroundAudioFiles.copy(ByteArrayInputStream(byteArrayOf(1, 2, 3)), largeLibrary, "wav")
        assertTrue(saved.created)
        val storage = BackgroundAudioFiles.storage(largeLibrary)
        assertEquals(4L * 1024 * 1024 * 1024 + 4, storage.used)
        assertTrue(storage.total > 0 && storage.free in 0..storage.total)
        assertTrue(BackgroundAudioFiles.remove(directory, saved.file.path)); directory.delete()
    }
    @Test fun storageCountsFilesOnceIncludingAnInFlightCopy() {
        val directory = folder()
        directory.resolve("a.flac").writeBytes(ByteArray(7))
        directory.resolve("pending.part").writeBytes(ByteArray(3))
        directory.resolve("nested").mkdir()
        assertEquals(10L, BackgroundAudioFiles.storage(directory).used)
        directory.resolve("a.flac").delete()
        assertEquals(3L, BackgroundAudioFiles.storage(directory).used)
        directory.resolve("pending.part").delete(); directory.resolve("nested").delete(); directory.delete()
    }
    private fun folder() = Files.createTempDirectory("thru3d-audio-test").toFile().also { it.deleteOnExit() }
    @Test fun completeCopyIsIndependentAndDeduplicated() {
        val directory = folder(); val bytes = ByteArray(1024) { it.toByte() }
        val saved = BackgroundAudioFiles.copy(ByteArrayInputStream(bytes), directory, "mp3", bytes.size.toLong())
        assertArrayEquals(bytes, saved.file.readBytes())
        val repeated = BackgroundAudioFiles.copy(ByteArrayInputStream(bytes), directory, "mp3")
        assertEquals(saved.file, repeated.file)
        assertEquals(1, directory.listFiles()!!.size)
        assertTrue(BackgroundAudioFiles.remove(directory, saved.file.path)); directory.delete()
    }
    @Test fun truncatedDownloadNeverPublishesAFile() {
        val directory = folder()
        assertThrows(IllegalStateException::class.java) { BackgroundAudioFiles.copy(ByteArrayInputStream(byteArrayOf(1, 2)), directory, "ogg", 100) }
        assertTrue(directory.listFiles()!!.isEmpty()); directory.delete()
    }
    @Test fun cancellationAndDecoderRejectionCleanTheirPartials() {
        val directory = folder()
        assertThrows(java.io.IOException::class.java) { BackgroundAudioFiles.copy(ByteArrayInputStream(byteArrayOf(1)), directory, "wav", cancelled = { true }) }
        assertThrows(IllegalStateException::class.java) { BackgroundAudioFiles.copy(ByteArrayInputStream(byteArrayOf(1)), directory, "wav", validate = { false }) }
        assertTrue(directory.listFiles()!!.isEmpty()); directory.delete()
    }
    @Test fun sizeAndPathPoliciesPreserveOtherFiles() {
        val directory = folder(); val other = folder().resolve("personal.mp3").apply { writeText("keep") }
        assertThrows(IllegalArgumentException::class.java) { BackgroundAudioFiles.copy(ByteArrayInputStream(byteArrayOf(1)), directory, "mp3", BackgroundAudioFiles.MAX_BYTES + 1) }
        assertThrows(IllegalArgumentException::class.java) { BackgroundAudioFiles.copy(ByteArrayInputStream(byteArrayOf(1)), directory, "exe") }
        assertFalse(BackgroundAudioFiles.remove(directory, other.path)); assertTrue(other.exists())
        other.delete(); other.parentFile?.delete(); directory.delete()
    }
    @Test fun audioClassificationPreservesLiteralFilenames() {
        assertTrue(MediaKinds.supported("calm.MP3")); assertEquals("audio", MediaKinds.kind("rain.ogg"))
        assertTrue(MediaKinds.supportedFileName("night #1?.wav")); assertEquals("audio", MediaKinds.fileNameKind("night #1?.wav"))
        assertTrue(MediaKinds.supportedFileName("Recording #1?.M4A")); assertEquals("audio", MediaKinds.fileNameKind("Recording #1?.M4A"))
        assertTrue(MediaKinds.audio("https://recorder/Recording.M4A?download=1#track"))
        assertEquals("image", MediaKinds.kind("photo.jpg")); assertEquals("video", MediaKinds.kind("movie.mp4"))
    }
    @Test fun remoteCopySurvivesServerShutdown() {
        val directory = folder(); val payload = ByteArray(100_000) { (it % 251).toByte() }
        val server = java.net.ServerSocket(0, 1, java.net.InetAddress.getLoopbackAddress())
        val thread = Thread {
            server.accept().use { socket ->
                socket.soTimeout = 2000
                val reader = socket.getInputStream().bufferedReader()
                while (!reader.readLine().isNullOrEmpty()) { /* HTTP request headers */ }
                socket.getOutputStream().use { output ->
                    output.write("HTTP/1.1 200 OK\r\nContent-Length: ${payload.size}\r\nConnection: close\r\n\r\n".toByteArray())
                    output.write(payload)
                }
            }
        }.apply { start() }
        val connection = java.net.URL("http://127.0.0.1:${server.localPort}/music.mp3").openConnection()
        connection.connectTimeout = 2000; connection.readTimeout = 2000
        var transferred = 0L
        val saved = connection.getInputStream().use { BackgroundAudioFiles.copy(it, directory, "mp3", connection.contentLengthLong,
            progress = { bytes, _ -> transferred = bytes }) }
        server.close(); thread.join(2000)
        assertFalse(thread.isAlive); assertEquals(payload.size.toLong(), transferred)
        assertArrayEquals(payload, saved.file.readBytes())
        BackgroundAudioFiles.remove(directory, saved.file.path); directory.delete()
    }
}
