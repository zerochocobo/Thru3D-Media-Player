package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.security.MessageDigest

class MediaArtworkFileTest {
    @get:Rule val temporary = TemporaryFolder()

    @Test fun staticResponseOnlyReadsAPrefixAndCreatesNoFile() {
        val bytes = ByteArray(2 * 1024 * 1024)
        bytes[0] = 0xff.toByte()
        bytes[1] = 0xd8.toByte()
        val input = bytes.inputStream()
        val destination = File(temporary.root, "poster.anim")
        assertFalse(MediaArtworkFile.copyAnimation(input, bytes.size.toLong(), destination))
        assertTrue(bytes.size - input.available() <= 8192)
        assertFalse(destination.exists())
    }

    @Test fun realIssue13OriginalsSurviveServerFetchByteForByte() {
        val path = System.getenv("THRU_ARTWORK_FIXTURES")
        assumeTrue("Set THRU_ARTWORK_FIXTURES to the issue author's sample repository", !path.isNullOrBlank())
        val cases = mapOf(
            "emby-library-cover-320x180-animated.png" to "a702a5f0fa1d1ca63ee1fc6461201177ff9a9b6d3e0a964865903e241efe97c0",
            "stash-scene-preview-640x360-animated.webp" to "e6873e6a7aca15a7af7aa82b2e9ac8b6719f13107aef7583c2d596fbb7bd6ce8"
        )
        for ((name, digest) in cases) {
            val bytes = File(path, name).readBytes()
            val type = if (name.endsWith(".png")) "Primary" else "Backdrop"
            val requests = mutableListOf<String>()
            MediaServerClientTest.Fixture { request, _, _ ->
                requests.add(request)
                MediaServerClientTest.Reply(body = bytes)
            }.use { fixture ->
                val account = MediaServerAccount("test", "Test", fixture.url, "", "emby", "user")
                MediaServerHttp(account).use { http ->
                    val uri = EmbyClient(account, http).image("item", type, 0, "version", 512, original = true)
                    val connection = http.open(uri, accept = "image/webp,image/png,image/jpeg,*/*;q=0.5")
                    val file = File(temporary.root, "$name.anim")
                    try {
                        assertTrue(connection.inputStream.use { MediaArtworkFile.copyAnimation(it, connection.contentLengthLong, file) })
                    } finally { http.release(connection) }
                    assertEquals(digest, MessageDigest.getInstance("SHA-256").digest(file.readBytes()).joinToString("") { "%02x".format(it) })
                    assertTrue(requests.single().contains("/Items/item/Images/$type/0?tag=version "))
                }
            }
        }
    }

    @Test fun animatedOriginalsShareABoundedCacheAndOrdinaryPostersStayAvailable() {
        val directory = temporary.newFolder("media-servers", "account")
        val poster = File(directory, "still.jpg").apply { writeBytes(byteArrayOf(1)) }
        val files = (1..3).map {
            File(directory, "image$it.anim").apply {
                java.io.RandomAccessFile(this, "rw").use { file -> file.setLength(8L * 1024 * 1024) }
                setLastModified(it * 1000L)
            }
        }
        MediaServerPosterCache.prune(temporary.root, files.last())
        assertFalse(files.first().exists())
        assertTrue(poster.exists() && files.drop(1).all { it.isFile })
    }
}
