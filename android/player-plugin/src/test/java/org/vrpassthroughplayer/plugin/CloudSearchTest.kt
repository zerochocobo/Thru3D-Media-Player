package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class CloudSearchTest {
    private class Directory(var files: List<CloudFile>) : CloudClient {
        var reads = 0
        var refreshes = 0
        override fun page(path: String, offset: Int, refresh: Boolean): CloudPage {
            assertEquals("/media", path); reads++; if (refresh) refreshes++
            val end = minOf(offset + 48, files.size)
            return CloudPage(files.subList(offset, end), if (end < files.size) end else -1, files.size)
        }
        override fun list(path: String): List<CloudFile> = error("Search must enforce its bound while paging")
        override fun find(path: String): CloudFile = error("Search must not prepare playback")
        override fun resolve(file: CloudFile): CloudLink = error("Search must not resolve media links")
    }
    @Test fun currentDirectorySearchIncludesUnseenPagesWithoutCrawlingAndPagingIsLocal() {
        val files = (0 until 60).map { CloudFile("旅行 $it.mp4", false, 128, "$it") } +
            CloudFile("旅行.heic", false, 128, "photo") + CloudFile("旅行", true, 0, "folder") + CloudFile("旅行.txt", false, 20, "text")
        val directory = Directory(files); val search = CloudDirectorySearch()
        val first = search.search("account", "identity", directory, "/media", "旅行", "all", "", false)
        assertEquals(48, first.getJSONArray("content").length()); assertEquals(2, directory.reads)
        val second = search.search("account", "identity", directory, "/media", "旅行", "all", first.getString("next_cursor"), false)
        assertEquals(14, second.getJSONArray("content").length()); assertEquals(2, directory.reads)
        assertEquals("", second.getString("next_cursor"))
        val photo = search.search("account", "identity", directory, "/media", "旅行", "image", "", false).getJSONArray("content")
        assertEquals(1, photo.length()); assertEquals("旅行.heic", photo.getJSONObject(0).getString("name"))
        val folders = search.search("account", "identity", directory, "/media", "旅行", "folder", "", false).getJSONArray("content")
        assertEquals(1, folders.length()); assertTrue(folders.getJSONObject(0).getBoolean("is_dir"))
    }
    @Test fun searchCursorCannotCrossAccountIdentityQueryOrTypeAndExpiry() {
        var clock = 0L
        val directory = Directory((0 until 60).map { CloudFile("movie $it.mp4", false, 128, "$it") })
        val search = CloudDirectorySearch { clock }
        val cursor = search.search("a", "old", directory, "/media", "movie", "video", "", false).getString("next_cursor")
        for ((account, identity, query, kind) in listOf(listOf("b", "old", "movie", "video"), listOf("a", "new", "movie", "video"),
            listOf("a", "old", "other", "video"), listOf("a", "old", "movie", "image"))) {
            assertThrows(IllegalArgumentException::class.java) { search.search(account, identity, directory, "/media", query, kind, cursor, false) }
        }
        clock = 300_000
        assertThrows(IllegalArgumentException::class.java) { search.search("a", "old", directory, "/media", "movie", "video", cursor, false) }
    }
    @Test fun selectedResultIsResolvedLazilyAndRefreshReadsNewDirectory() {
        val directory = Directory(listOf(CloudFile("中文 #%.mp4", false, 128, "1")))
        val search = CloudDirectorySearch()
        val first = search.search("a", "id", directory, "/media", "中文", "video", "", false)
        val token = first.getJSONArray("content").getJSONObject(0).getString("token")
        val result = search.resolve("a", "id", token)
        assertEquals("/media/中文 #%.mp4", result.getString("path")); assertEquals(1, directory.reads)
        directory.files = directory.files + CloudFile("中文 uploaded.mp4", false, 128, "2")
        val fresh = search.search("a", "id", directory, "/media", "中文", "video", "", true)
        assertEquals(2, fresh.getJSONArray("content").length()); assertEquals(1, directory.refreshes)
    }
    @Test fun searchKeywordIsPlainContainsAndSpecialFilenameCharactersStayLiteral() {
        val directory = Directory(listOf(CloudFile("旅行 #%.heic", false, 128, "1"), CloudFile("旅行 question?.mp4", false, 128, "2")))
        val search = CloudDirectorySearch()
        assertEquals(2, search.search("a", "id", directory, "/media", "旅行", "all", "", false).getJSONArray("content").length())
        assertEquals(1, search.search("a", "id", directory, "/media", "旅行", "image", "", false).getJSONArray("content").length())
        assertEquals(0, search.search("a", "id", directory, "/media", "*旅行*", "all", "", false).getJSONArray("content").length())
        assertEquals(1, search.search("a", "id", directory, "/media", "%", "all", "", false).getJSONArray("content").length())
    }
    @Test fun currentSearchRejectsLargeDirectoryAfterOnePage() {
        val directory = Directory((0 until 20_001).map { CloudFile("movie $it.mp4", false, 128, "$it") })
        assertThrows(IllegalArgumentException::class.java) { CloudDirectorySearch().search("a", "id", directory, "/media", "movie", "video", "", false) }
        assertEquals(1, directory.reads)
    }
    @Test fun openListSearchUsesNativeRouteAndOpaqueResultToken() {
        val mount = "/11111111-1111-4111-8111-111111111111"
        val calls = ArrayList<Pair<String, JSONObject>>()
        val client = OpenListBackend.Client(mount, CloudDrive.OPEN115) { _, route, body ->
            calls.add(route to body!!)
            val data = if (route == "/search") JSONObject().put("content", JSONArray()).put("next_cursor", "opaque:1") else JSONObject().put("path", "/中文 #%.mp4")
            JSONObject().put("code", 200).put("data", data)
        }
        val page = client.search("/media", "中文 #%'", "all", "video", "", false)
        assertEquals("opaque:1", page.getString("next_cursor")); assertEquals("/search", calls[0].first)
        assertEquals(mount, calls[0].second.getString("mount")); assertEquals("中文 #%'", calls[0].second.getString("query"))
        client.resolveSearch("/media", "opaque:0")
        assertEquals("/searchresolve", calls[1].first); assertEquals("opaque:0", calls[1].second.getString("token"))
    }
    @Test fun forceRefreshOnSecondSourcePageReachesCore() {
        for (provider in listOf(CloudDrive.OPEN115, CloudDrive.WEBDAV)) {
            var request = JSONObject()
            val client = OpenListBackend.Client("/11111111-1111-4111-8111-111111111111", provider) { _, _, body ->
                request = body!!
                JSONObject().put("data", JSONObject().put("content", JSONArray().put(JSONObject().put("name", "movie.mp4").put("id", "49").put("is_dir", false))).put("total", 49))
            }
            client.page("/", 48, true)
            assertTrue(request.getBoolean("refresh"))
        }
    }
    @Test fun cancellationCallbackRunsOnceAndLateAttachCancelsImmediately() {
        val cancellation = CloudCancellation(); var cancelled = 0
        cancellation.attachAction { cancelled++ }; cancellation.cancel(); cancellation.cancel()
        assertEquals(1, cancelled)
        assertThrows(CloudFailure::class.java) { cancellation.attachAction { cancelled++ } }
        assertEquals(2, cancelled)
    }
    @Test fun currentOnlyProvidersCannotAdvertiseRecursiveScopes() {
        for (provider in listOf(CloudDrive.ALIYUN, CloudDrive.QUARK, CloudDrive.WEBDAV, CloudDrive.P115)) {
            assertEquals("[\"current\"]", CloudLibrary.searchScopes(provider).toString())
        }
        assertEquals("[\"current\",\"all\"]", CloudLibrary.searchScopes(CloudDrive.OPEN115).toString())
        for (provider in listOf(CloudDrive.ONEDRIVE, CloudDrive.BAIDU)) assertEquals(3, CloudLibrary.searchScopes(provider).length())
    }
}
