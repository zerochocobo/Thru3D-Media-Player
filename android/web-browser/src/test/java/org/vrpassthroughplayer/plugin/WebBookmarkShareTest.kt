package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.net.InetAddress
import java.net.Socket
import java.net.URI
import java.util.concurrent.TimeUnit

class WebBookmarkShareTest {
    private fun action(name: String) = JSONObject().put("action", name)
    @Test fun remoteWritesAreAtomicPrivateAndRevisionChecked() {
        var disk = "{}"; var fail = false
        val library = WebBrowserLibrary(disk) { if (fail) error("disk full"); disk = it }
        library.recordHistory = true; library.visit("https://private.example/history", "Private", 1)
        val before = library.remoteSnapshot()
        assertEquals("Private", before.getJSONArray("history").getJSONObject(0).getString("title"))
        assertEquals("history_conflict", library.remote(action("clear_history")).getString("error"))
        assertEquals("invalid_request", library.remote(action("remove").put("collection", "cookies")).getString("error"))
        val add = action("import_bookmarks").put("revision", before.getString("revision"))
            .put("items", JSONArray("""[{"url":"https://example.com/a","title":"中文 & <script>"},{"url":"https://example.com/a"},{"url":"https://example.com/b"}]"""))
        val saved = library.remote(add)
        assertEquals(2, saved.getJSONArray("bookmarks").length())
        assertEquals(1, JSONObject(disk).getJSONArray("history").length())
        assertEquals("conflict", library.remote(add).getString("error"))
        val bad = action("import_bookmarks").put("revision", saved.getString("revision"))
            .put("items", JSONArray("""[{"url":"https://example.com/new"},{"url":"file:///secret"}]"""))
        assertEquals("invalid_address", library.remote(bad).getString("error"))
        assertEquals(saved.toString(), library.remoteSnapshot().toString())
        val remove = action("remove").put("collection", "bookmarks").put("revision", saved.getString("revision"))
            .put("urls", JSONArray().put("https://example.com/a"))
        fail = true
        try { library.remote(remove); fail("Expected disk failure") } catch (_: IllegalStateException) { }
        assertEquals(saved.toString(), library.remoteSnapshot().toString())
        fail = false
        assertEquals(1, library.remote(remove).getJSONArray("bookmarks").length())
        assertEquals(1, WebBrowserLibrary(disk) {}.remoteSnapshot().getJSONArray("bookmarks").length())
    }
    private class Fixture(duration: Long = 60_000, requireCode: Boolean = true) : AutoCloseable {
        val library = WebBrowserLibrary("{}") {}
        val server = WebBookmarkShare({ "fixture".toByteArray() }, { request, alive ->
            synchronized(library) { if (alive()) library.remote(request) else JSONObject().put("error", "expired") }
        }, { InetAddress.getByName("127.0.0.1") }, 0, duration)
        init { assertEquals("", server.start(requireCode)) }
        fun send(path: String, body: JSONObject? = null, token: String? = null, extra: String = "", host: String? = null, type: String = "application/json"): Pair<Int,String> {
            val url = URI(server.status().getString("url"))
            val bytes = body?.toString()?.toByteArray(Charsets.UTF_8) ?: ByteArray(0)
            return Socket(url.host, url.port).use { socket ->
                socket.soTimeout = 5000
                val head = "${if (body == null) "GET" else "POST"} $path HTTP/1.1\r\nHost: ${host ?: url.rawAuthority}\r\nContent-Type: $type\r\nContent-Length: ${bytes.size}\r\n" +
                    (if (token != null) "Authorization: Bearer $token\r\n" else "") + extra + "\r\n"
                socket.getOutputStream().apply { write(head.toByteArray()); write(bytes); flush() }
                val response = socket.getInputStream().readBytes().toString(Charsets.UTF_8)
                response.substringBefore("\r\n").split(' ')[1].toInt() to response.substringAfter("\r\n\r\n")
            }
        }
        fun pair() = JSONObject(send("/pair", JSONObject().put("code", server.status().getString("code"))).second).getString("token")
        override fun close() = server.close()
    }
    @Test fun rootAddressAndPairingProtectBookmarkApi() = Fixture().use { f ->
        assertTrue(f.server.status().getString("code").matches(Regex("[ABCDEFGHJKLMNPQRSTUVWXYZ]{4}")))
        assertEquals("", URI(f.server.status().getString("url")).path)
        assertEquals(200, f.send("/").first)
        assertEquals(404, f.send("/library.json").first)
        assertEquals(401, f.send("/api", action("list")).first)
        assertEquals(401, f.send("/pair", JSONObject().put("code", "wrong")).first)
        val token = f.pair()
        assertEquals(64, token.length)
        val list = f.send("/api", action("list"), token)
        assertEquals(200, list.first); assertEquals(0, JSONObject(list.second).getJSONArray("history").length())
        val saved = f.send("/api", action("save_bookmark").put("revision", JSONObject(list.second).getString("revision"))
            .put("url", "https://example.com/日本語").put("title", "日本語"), token)
        assertEquals(200, saved.first); assertTrue(saved.second.contains("日本語"))
        assertEquals(409, f.send("/api", action("clear_history"), token).first)
    }
    @Test fun rebindingCrossOriginAndSimpleFormPostsAreRejected() = Fixture().use { f ->
        val token = f.pair()
        assertEquals(403, f.send("/", host = "attacker.test").first)
        assertEquals(403, f.send("/api", action("list"), token, "Origin: https://attacker.test\r\n").first)
        assertEquals(403, f.send("/pair", JSONObject().put("code", f.server.status().getString("code")), extra = "Sec-Fetch-Site: cross-site\r\n").first)
        assertEquals(415, f.send("/api", action("list"), token, type = "text/plain").first)
        assertEquals(403, f.send("/api", action("list"), token, "Transfer-Encoding: chunked\r\n").first)
        assertEquals(400, f.send("/api", action("list"), token, "Host: attacker.test\r\n").first)
    }
    @Test fun bruteForceIsLimitedAndRestartRevokesTokens() = Fixture().use { f ->
        val token = f.pair()
        repeat(5) { assertEquals(401, f.send("/pair", JSONObject().put("code", "wrong")).first) }
        assertEquals(429, f.send("/pair", JSONObject().put("code", f.server.status().getString("code"))).first)
        f.server.close(); assertFalse(f.server.status().getBoolean("active"))
        assertEquals("", f.server.start(true))
        assertEquals(401, f.send("/api", action("list"), token).first)
        assertEquals(200, f.send("/api", action("list"), f.pair()).first)
    }
    @Test fun defaultSessionConnectsWithoutCodeAndCanEndFromComputer() = Fixture(requireCode = false).use { f ->
        assertFalse(f.server.status().getBoolean("requires_code"))
        assertEquals("", f.server.status().getString("code"))
        val response = f.send("/pair", JSONObject())
        assertEquals(200, response.first)
        val token = JSONObject(response.second).getString("token")
        val address = URI(f.server.status().getString("url"))
        assertEquals(200, f.send("/api", action("list"), token).first)
        assertEquals(200, f.send("/api", action("stop_share"), token).first)
        // The reply is flushed before closing the listener.
        repeat(20) { if (f.server.status().optBoolean("active")) Thread.sleep(5) }
        assertFalse(f.server.status().getBoolean("active"))
        try { Socket(address.host, address.port).close(); fail("Other devices can still connect after remote closure") } catch (_: java.io.IOException) { }
    }
    @Test fun bootstrapDoesNotConsumeCodeAttemptsAndTypedLowercaseWorks() = Fixture().use { f ->
        repeat(10) { assertEquals(401, f.send("/pair", JSONObject()).first) }
        assertEquals(200, f.send("/pair", JSONObject().put("code", f.server.status().getString("code").lowercase())).first)
    }
    @Test fun expiryClosesListenerAndMissingAssetsNeverExposeAccess() {
        Fixture(100).use { f ->
            val uri = URI(f.server.status().getString("url"))
            Thread.sleep(250)
            assertFalse(f.server.status().getBoolean("active"))
            try { Socket(uri.host, uri.port).close(); fail("Expired listener is open") } catch (_: java.io.IOException) { }
        }
        WebBookmarkShare({ error("missing") }, { _, _ -> JSONObject() }, { InetAddress.getByName("127.0.0.1") }, 0).use { server ->
            assertEquals("share_unavailable", server.start()); assertFalse(server.status().getBoolean("active"))
        }
    }
    @Test fun importLimitAndInvalidInputCannotPartiallyWrite() {
        val library = WebBrowserLibrary("{}") {}
        val items = JSONArray()
        repeat(1000) { items.put(JSONObject().put("url", "https://example.com/$it")) }
        val first = library.remote(action("import_bookmarks").put("items", items).put("revision", library.remoteSnapshot().getString("revision")))
        assertEquals(1000, first.getJSONArray("bookmarks").length())
        val more = library.remote(action("import_bookmarks").put("items", JSONArray().put(JSONObject().put("url", "https://example.com/extra")))
            .put("revision", first.getString("revision")))
        assertEquals("bookmark_limit", more.getString("error"))
        assertEquals(first.toString(), library.remoteSnapshot().toString())
        val duplicate = library.remote(action("import_bookmarks").put("items", JSONArray().put(JSONObject().put("url", "https://example.com/1").put("title", "overwrite")))
            .put("revision", first.getString("revision")))
        assertEquals(first.toString(), duplicate.toString())
    }
    @Test fun changedNetworkClosesTheSessionAndReleasesItsLeaseOnce() {
        val ip = java.util.concurrent.atomic.AtomicReference(InetAddress.getByName("127.0.0.1"))
        val stops = java.util.concurrent.atomic.AtomicInteger()
        WebBookmarkShare({ "asset".toByteArray() }, { _, _ -> JSONObject() }, { ip.get() }, 0, 3000,
            onStop = { stops.incrementAndGet() }).use { server ->
            assertEquals("", server.start())
            ip.set(InetAddress.getByName("127.0.0.2"))
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(2)
            while (server.status().optBoolean("active") && System.nanoTime() < deadline) Thread.sleep(20)
            assertFalse(server.status().getBoolean("active")); server.close()
            assertEquals(1, stops.get())
        }
    }
    @Test fun occupiedPortFailsWithoutTakingOverAnotherListener() {
        java.net.ServerSocket(0, 1, InetAddress.getByName("127.0.0.1")).use { occupied ->
            WebBookmarkShare({ "asset".toByteArray() }, { _, _ -> JSONObject() }, { InetAddress.getByName("127.0.0.1") }, occupied.localPort).use { server ->
                assertEquals("share_unavailable", server.start()); assertFalse(server.status().getBoolean("active"))
                assertFalse(occupied.isClosed)
            }
        }
    }
    @Test fun remoteHistoryNeverPromotesTransientVisitsAndVersionsAreIndependent() {
        var disk = "{}"
        val library = WebBrowserLibrary(disk) { disk = it }
        library.recordHistory = true; library.visit("https://example.com/saved", "Saved", 10)
        library.recordHistory = false; library.visit("https://example.com/session", "Session", 20)
        val before = library.remoteSnapshot()
        assertEquals(2, before.getJSONArray("history").length())
        assertFalse(disk.contains("/session"))
        library.visit("https://example.com/latest", "Latest", 30)
        // A new visit must not conflict with a bookmark editor opened before it.
        assertFalse(library.remote(action("save_bookmark").put("url", "https://example.com/bookmark").put("revision", before.getString("revision"))).has("error"))
        assertFalse(disk.contains("/session")); assertFalse(disk.contains("/latest"))
        assertEquals("history_conflict", library.remote(action("clear_history").put("history_revision", before.getString("history_revision"))).getString("error"))
        val current = library.remoteSnapshot()
        val removed = library.remote(action("remove").put("collection", "history").put("urls", JSONArray().put("https://example.com/session"))
            .put("history_revision", current.getString("history_revision")))
        assertEquals(2, removed.getJSONArray("history").length())
        assertEquals(1, removed.getJSONArray("bookmarks").length())
        assertEquals(1, JSONObject(disk).getJSONArray("history").length())
        library.recordHistory = true
        library.visit("https://example.com/new-public", "New", 40)
        assertFalse(disk.contains("/session")); assertFalse(disk.contains("/latest"))
        assertEquals(2, WebBrowserLibrary(disk) {}.remoteSnapshot().getJSONArray("history").length())
    }
    @Test fun remoteHistoryDeletionRollsBackOnFailureAndClearsBothCopies() {
        var disk = "{}"; var broken = false
        val library = WebBrowserLibrary(disk) { if (broken) error("disk"); disk = it }
        library.recordHistory = true; library.visit("https://example.com/a", "Old", 1)
        library.recordHistory = false; library.visit("https://example.com/a", "New", 2)
        library.visit("https://example.com/transient", "Transient", 3); library.bookmark("https://example.com/a", "Bookmark")
        val before = library.remoteSnapshot(); val oldDisk = disk
        val clear = action("clear_history").put("history_revision", before.getString("history_revision"))
        broken = true
        try { library.remote(clear); fail("Expected failed write") } catch (_: IllegalStateException) { }
        assertEquals(before.toString(), library.remoteSnapshot().toString()); assertEquals(oldDisk, disk)
        broken = false
        val cleared = library.remote(clear)
        assertEquals(0, cleared.getJSONArray("history").length()); assertEquals(1, cleared.getJSONArray("bookmarks").length())
        assertEquals(0, WebBrowserLibrary(disk) {}.remoteSnapshot().getJSONArray("history").length())
    }

    @Test fun pageVisitsUseTheDeferredWriterAndEditsStaySynchronous() {
        val later = mutableListOf<String>(); val now = mutableListOf<String>()
        val library = WebBrowserLibrary("{}", saveLater = { later.add(it) }) { now.add(it) }
        library.recordHistory = true
        library.visit("https://www.bilibili.com/video/BV1xx411c7mD", "Video", 1)
        assertEquals(1, later.size); assertTrue(now.isEmpty())
        assertTrue(library.bookmark("https://www.bilibili.com/", "Home"))
        assertEquals(1, now.size)
        assertTrue(now.single().contains("BV1xx411c7mD"))
    }
}
