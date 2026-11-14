package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import java.net.URI
import org.vrpassthroughplayer.plugin.MediaServerClientTest.Fixture
import org.vrpassthroughplayer.plugin.MediaServerClientTest.Reply

class ExternalPlaybackRequestTest {
    @Test fun startPositionsUseKnownIntegerMillisecondsOnly() {
        assertEquals(1234, ExternalPlaybackContract.startMs(listOf(null, "wrong", 1234L)))
        assertEquals(0, ExternalPlaybackContract.startMs(listOf(-1, 4000)))
        assertEquals(Int.MAX_VALUE, ExternalPlaybackContract.startMs(listOf(Long.MAX_VALUE)))
        assertEquals(0, ExternalPlaybackContract.startMs(listOf(Double.NaN, 12.5f)))
    }

    @Test fun latestForegroundClaimConsumesExactlyOnceAndExpires() {
        var time = 0L
        val inbox = ExternalPlaybackInbox({ time }, 100)
        inbox.offer(request("content://fixture/first"))
        inbox.offer(request("content://fixture/second"))
        assertTrue(inbox.claimLatest()!!.request.uri.endsWith("second"))
        assertNull(inbox.claimLatest())
        inbox.offer(request()); time = 101
        assertNull(inbox.claimLatest()); assertNull(inbox.claimLatest())
    }
    private val view = "android.intent.action.VIEW"
    private fun request(uri: String = "https://media.example/video?id=3&api_key=secret") = ExternalPlaybackRequest.parse(view, uri)

    @Test fun dynamicUrlsAndLoopbackDoNotRequireAnExtensionOrMime() {
        val r = request("http://127.0.0.1:9978/proxy?episode=3&api_key=secret")
        assertTrue(r.loopback); assertEquals("", r.mime)
        assertTrue(request("http://[::1]:9978/proxy").loopback)
        assertTrue(request("http://localhost:9978/proxy").loopback)
        assertFalse(request("https://localhost.evil.example/proxy").loopback)
        assertTrue(r.uri.contains("api_key=secret")) // Request bytes are not identity normalization.
        assertFalse(r.toString().contains("secret")); assertFalse(r.toString().contains("proxy"))
    }

    @Test fun embyTokensAreAcceptedButTransferControlAndHeaderInjectionAreRejected() {
        val r = ExternalPlaybackRequest.parse(view, "https://media.example/stream", headers =
            mapOf("X-Emby-Token" to "secret", "X-MediaBrowser-Token" to "other", "Referer" to "https://media.example/"))
        assertEquals("secret", r.headers["x-emby-token"])
        for ((name, value) in listOf("Host" to "other.example", "Range" to "bytes=0-", "Cookie" to "a\r\nb", "Authorization" to "a\u0000b")) {
            assertThrows(IllegalArgumentException::class.java) { ExternalPlaybackRequest.parse(view, r.uri, headers = mapOf(name to value)) }
        }
        assertThrows(IllegalArgumentException::class.java) { ExternalPlaybackRequest.parse(view, r.uri, headers = linkedMapOf("Cookie" to "a", "cookie" to "b")) }
    }

    @Test fun badInputsCannotBecomePlaybackOrRevealTheirValueInErrors() {
        for (uri in listOf("intent://video", "https://user:secret@media.example/stream", "file://host/etc/file", "content:///missing", "https://media.example/\nsecret")) {
            val failure = assertThrows(IllegalArgumentException::class.java) { request(uri) }
            assertFalse(failure.message.orEmpty().contains("secret"))
        }
        assertThrows(IllegalArgumentException::class.java) { ExternalPlaybackRequest.parse("android.intent.action.MAIN", "https://media.example/video") }
    }

    @Test fun parsedEmbyCredentialsReachOnlyTheOriginalOrigin() {
        val original = AtomicReference<Map<String, String>>()
        val redirected = AtomicReference<Map<String, String>>()
        val redirectedPath = AtomicReference<String>()
        Fixture { path, headers, _ ->
            redirected.set(headers); redirectedPath.set(path)
            Reply(206, "Content-Range: bytes 0-0/1\r\n", byteArrayOf(7))
        }.use { target ->
            Fixture { _, headers, _ ->
                original.set(headers)
                Reply(302, "Location: ${target.url}/media\r\n", byteArrayOf())
            }.use { origin ->
                val request = ExternalPlaybackRequest.parse(view, origin.url + "/video?api_key=synthetic", headers = mapOf(
                    "X-Emby-Token" to "synthetic", "X-MediaBrowser-Token" to "synthetic", "Referer" to origin.url,
                    "Cookie" to "synthetic", "Authorization" to "Bearer synthetic", "User-Agent" to "TestPlayer"))
                RemoteMediaHttp().use { http ->
                    val connection = http.open(URI(request.uri), "bytes=0-0", request.headers)
                    try { assertEquals(7, connection.inputStream.read()) } finally { http.release(connection) }
                }
            }
        }
        for (name in listOf("x-emby-token", "x-mediabrowser-token", "referer", "cookie", "authorization")) {
            assertNotNull(original.get()[name]); assertNull(redirected.get()[name])
        }
        assertEquals("TestPlayer", redirected.get()["user-agent"])
        assertFalse(redirectedPath.get().contains("api_key"))
    }

    @Test fun privateFilesAreRejectedAfterDecodingAndCanonicalizationButNeighborsAreNot() {
        val base = Files.createTempDirectory("external-file-test").toFile()
        try {
            val privateDir = File(base, "private").apply { mkdirs() }
            val roots = listOf(privateDir)
            for (path in listOf("private/token", "public/../private/token", "private/%74oken")) {
                val uri = base.toURI().toString() + path
                assertEquals("PRIVATE_FILE_DENIED", assertThrows(IllegalArgumentException::class.java) {
                    ExternalPlaybackRequest.parse(view, uri, privateRoots = roots)
                }.message)
            }
            val neighbor = File(base, "private-other/video.mp4").toURI().toString()
            assertEquals(neighbor, ExternalPlaybackRequest.parse(view, neighbor, privateRoots = roots).uri)
        } finally { base.deleteRecursively() }
    }

    @Test fun onlyTheLatestDeliveryCanBeClaimedAndTheSameVideoCanBeChosenAgain() {
        val inbox = ExternalPlaybackInbox()
        val first = inbox.offer(request()); val second = inbox.offer(request())
        assertNull(inbox.claim(first)); assertEquals(second, inbox.claim(second)?.id); assertNull(inbox.claim(second))
        val again = inbox.offer(request()); assertNotNull(inbox.claim(again))
        assertFalse(inbox.current(second)); assertTrue(inbox.current(again))
        inbox.cancel(); assertFalse(inbox.current(again))
    }

    @Test fun competingReadyAndResumeCallbacksCannotReplayADelivery() {
        val inbox = ExternalPlaybackInbox(); val id = inbox.offer(request())
        val start = CountDownLatch(1); val count = AtomicInteger()
        val callers = (0..7).map { Thread { start.await(); if (inbox.claim(id) != null) count.incrementAndGet() }.apply { start() } }
        start.countDown(); callers.forEach { it.join(2000); assertFalse(it.isAlive) }
        assertEquals(1, count.get())
    }

    @Test fun bundleAndArrayHeadersDropUnknownNamesTheSameWayAndRecordThem() {
        val array = ExternalPlaybackContract.stringArrayPairs(arrayOf("User-Agent", "TV", "Origin", "https://a", "Accept-Encoding", "gzip"))
        val bundle = listOf<Pair<String?, String?>>("User-Agent" to "TV", "Origin" to "", "Accept-Encoding" to "")
        for (pairs in listOf(array, bundle)) {
            val headers = ExternalPlaybackContract.headers(pairs)
            assertEquals(mapOf("User-Agent" to "TV"), headers.accepted)
            assertEquals(listOf("user-agent", "origin", "accept-encoding"), headers.received)
            assertEquals(listOf("origin", "accept-encoding"), headers.dropped)
            // Accepted headers still pass the strict parser instead of rejecting the whole request.
            assertEquals("TV", ExternalPlaybackRequest.parse(view, "https://media.example/v", headers = headers.accepted).headers["user-agent"])
        }
    }

    @Test fun malformedHeaderContainersAreFormatErrorsNotCrashes() {
        for (values in listOf(arrayOf<String?>("User-Agent"), arrayOf<String?>(null, "x"), arrayOfNulls<String>(130))) {
            assertEquals("INVALID_HEADER", assertThrows(IllegalArgumentException::class.java) {
                ExternalPlaybackContract.headers(ExternalPlaybackContract.stringArrayPairs(values))
            }.message)
        }
        assertEquals("INVALID_HEADER", assertThrows(IllegalArgumentException::class.java) {
            ExternalPlaybackContract.headers(listOf("Cookie" to null))
        }.message)
        // A null value under an ignored name is not read and does not reject the request.
        assertTrue(ExternalPlaybackContract.headers(listOf("X-Unknown" to null)).accepted.isEmpty())
    }

    @Test fun contractEvidenceRecordsKindsAndSafeNamesWithoutValues() {
        assertEquals("int", ExternalPlaybackContract.kind(5)); assertEquals("long", ExternalPlaybackContract.kind(5L))
        assertEquals("float", ExternalPlaybackContract.kind(1.5f)); assertEquals("string", ExternalPlaybackContract.kind("secret"))
        assertEquals("string_array", ExternalPlaybackContract.kind(arrayOf("a"))); assertEquals("null", ExternalPlaybackContract.kind(null))
        assertEquals("non_finite", ExternalPlaybackContract.kind(Double.NaN))
        assertEquals("non_finite", ExternalPlaybackContract.kind(Float.POSITIVE_INFINITY))
        for (name in listOf("subs.enable", "android.media.intent.extra.HTTP_HEADERS", "x-mediabrowser-token", "return_result")) {
            assertEquals(name, ExternalPlaybackContract.safeName(name))
        }
        for (bad in listOf(null, "", "with space", "line\nbreak", "名称", "x".repeat(49),
                "https://media.example.invalid/video?api_key=synthetic", "api_key=synthetic", "Bearer synthetic",
                "a3f9c2e17b4d8e6f0a1b2c3d4e5f6a7b", "token.a3f9c2e17b4d8e6f0a1b2c3d4e5f")) {
            assertEquals(ExternalPlaybackContract.REDACTED, ExternalPlaybackContract.safeName(bad))
        }
    }

    @Test fun uriOrTokenShapedHeaderNamesAreDroppedWithoutBeingRecorded() {
        val headers = ExternalPlaybackContract.headers(listOf("https://media.example.invalid/v?api_key=synthetic" to "",
            "a3f9c2e17b4d8e6f0a1b2c3d4e5f6a7b" to "", "User-Agent" to "TV"))
        assertEquals(mapOf("User-Agent" to "TV"), headers.accepted)
        val recorded = (headers.received + headers.dropped).joinToString()
        for (secret in listOf("synthetic", "media.example", "a3f9c2e1")) assertFalse(recorded.contains(secret))
        assertEquals(listOf(ExternalPlaybackContract.REDACTED, ExternalPlaybackContract.REDACTED), headers.dropped)
    }

    @Test fun rejectedDeliveriesInvalidateWaitingWorkAndCannotBeClaimed() {
        val inbox = ExternalPlaybackInbox(); val waiting = inbox.offer(request())
        val rejected = inbox.cancel()
        assertFalse(inbox.current(waiting)); assertTrue(inbox.current(rejected))
        assertNull(inbox.claim(waiting)); assertNull(inbox.claim(rejected))
    }

    @Test fun untitledContentUsesTheProviderDisplayNameOnly() {
        assertEquals("trip_180_LR.mp4", ExternalPlaybackContract.title(null, "content") { "trip_180_LR.mp4" })
        assertEquals("trip_TB.mkv", ExternalPlaybackContract.title(" ", "content") { "trip_TB.mkv" })
        assertEquals("Given", ExternalPlaybackContract.title("Given", "content") { error("not queried") })
        assertNull(ExternalPlaybackContract.title(null, "https") { error("not queried") })
        assertNull(ExternalPlaybackContract.title(null, "content") { throw SecurityException("revoked") })
        assertNull(ExternalPlaybackContract.title(null, "content") { "" })
        // The provider name passes through the same control-character and length cleanup.
        val parsed = ExternalPlaybackRequest.parse(view, "content://provider/video/1",
            ExternalPlaybackContract.title(null, "content") { "a\nb_360_TB.mp4" })
        assertEquals("ab_360_TB.mp4", parsed.title)
    }

    @Test fun anExpiredDeliveryRequiresReselection() {
        var now = 0L; val inbox = ExternalPlaybackInbox({ now }, 100)
        val id = inbox.offer(request()); now = 101
        assertNull(inbox.claim(id)); assertNull(inbox.claim(id))
    }

    @Test fun discardedOrRejectedWorkCannotRetainCredentialsOrDropANewerDelivery() {
        val inbox = ExternalPlaybackInbox()
        val old = inbox.offer(request()); val next = inbox.offer(request())
        inbox.discard(old); assertNotNull(inbox.claim(next))
        val pending = inbox.offer(request()); inbox.discard(pending); assertNull(inbox.claim(pending))
        val title = ExternalPlaybackRequest.parse(view, "https://media.example/stream", title = "\n" + "😀".repeat(300)).title
        assertEquals(256, title.codePointCount(0, title.length)); assertFalse(title.contains('\n'))
    }
}
