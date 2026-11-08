package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test
import org.vrpassthroughplayer.plugin.MediaServerClientTest.Fixture
import org.vrpassthroughplayer.plugin.MediaServerClientTest.Reply
import java.net.URI
import java.nio.ByteBuffer

class WebVideoBrowserResourceReaderTest {
    @Test fun tailMp4UsesExactRangesAndRejectsChangedFileIdentity() {
        val ftyp = ByteBuffer.allocate(24).putInt(24).put("ftypisom0000isom0000".toByteArray()).array()
        val media = ByteBuffer.allocate(SphericalVideoMetadata.PREFIX_LIMIT + 8).putInt(SphericalVideoMetadata.PREFIX_LIMIT + 8).put("mdat".toByteArray()).array()
        val moov = ByteBuffer.allocate(24).putInt(24).put("moov".toByteArray()).put(ByteArray(16)).array()
        val body = ftyp + media + moov
        for (changed in listOf(false, true)) {
            var requests = 0
            Fixture { _, headers, _ ->
                assertEquals("own-media-request", headers["authorization"])
                val range = Regex("bytes=([0-9]+)-([0-9]+)").matchEntire(headers["range"].orEmpty())!!
                val start = range.groupValues[1].toInt();val end = minOf(range.groupValues[2].toInt(), body.size - 1)
                requests++
                Reply(206, "Content-Range: bytes $start-$end/${body.size}\r\nETag: \"${if(changed && start > 0) "new" else "initial"}\"\r\n", body.copyOfRange(start, end + 1))
            }.use { origin -> RemoteMediaHttp().use { http ->
                val actual = WebVideoBrowserResourceReader.read(URI(origin.url + "/clip.mp4"), mapOf("Authorization" to "own-media-request"), true, http) {}
                if (changed) assertEquals(SphericalVideoMetadata.PREFIX_LIMIT, actual.second.size)
                else assertArrayEquals(ftyp + moov, actual.second)
                assertTrue(requests > 1)
            } }
        }
    }

    @Test fun prefixUsesBoundedRangeAndOwnRequestHeaders() {
        val body = byteArrayOf(1, 2, 3, 4)
        Fixture { _, headers, _ ->
            assertEquals("bytes=0-${SphericalVideoMetadata.PREFIX_LIMIT - 1}", headers["range"])
            assertEquals("https://www.douyin.com/", headers["referer"])
            Reply(206, "Content-Range: bytes 0-3/4\r\n", body)
        }.use { origin -> RemoteMediaHttp().use { http ->
            val uri = URI(origin.url + "/file")
            val actual = WebVideoBrowserResourceReader.read(uri, mapOf("Referer" to "https://www.douyin.com/"), true, http) {}
            assertEquals(uri, actual.first); assertArrayEquals(body, actual.second)
        } }
    }

    @Test fun prefixRejectsAnUnexpectedRangeOffset() {
        Fixture { _, _, _ -> Reply(206, "Content-Range: bytes 4-7/8\r\n", ByteArray(4)) }.use { origin ->
            RemoteMediaHttp().use { http -> assertThrows(IllegalArgumentException::class.java) {
                WebVideoBrowserResourceReader.read(URI(origin.url + "/file"), emptyMap(), true, http) {}
            } }
        }
    }

    @Test fun fullManifestCannotBeAnIncomplete206Response() {
        for (total in listOf(4, 100)) {
            Fixture { _, headers, _ ->
                assertFalse(headers.containsKey("range"))
                Reply(206, "Content-Range: bytes 0-3/$total\r\n", ByteArray(4))
            }.use { origin -> RemoteMediaHttp().use { http ->
                val read = { WebVideoBrowserResourceReader.read(URI(origin.url + "/manifest"), emptyMap(), false, http) {} }
                if (total == 4) assertEquals(4, read().second.size)
                else assertThrows(IllegalArgumentException::class.java) { read() }
            } }
        }
    }

    @Test fun cancellationInterruptsReadingWithoutClosingTheSharedHttpOwner() {
        var checks = 0
        Fixture { _, _, _ -> Reply(body = ByteArray(65536)) }.use { origin -> RemoteMediaHttp().use { http ->
            assertThrows(InterruptedException::class.java) {
                WebVideoBrowserResourceReader.read(URI(origin.url + "/file"), emptyMap(), true, http) {
                    if (++checks == 3) throw InterruptedException()
                }
            }
            val next = http.open(URI(origin.url + "/next"), "", emptyMap())
            try { assertEquals(200, next.responseCode) } finally { http.release(next) }
        } }
        assertEquals(3, checks)
    }
}
