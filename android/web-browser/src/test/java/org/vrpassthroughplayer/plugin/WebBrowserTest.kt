package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class WebBrowserTest {
    @Test fun embyHttpBookmarkUsesTheSameIdentityAcrossRoutesAndRestarts() {
        var disk = "{}"
        val home = "http://192.168.31.185:8096/web/index.html#!/home"
        val details = "http://192.168.31.185:8096/web/index.html#!/item?id=42&serverId=local"
        val library = WebBrowserLibrary(disk) { disk = it }
        assertTrue(library.bookmark(home, "Emby"))
        val saved = WebBrowserLibrary(disk) {}.snapshot().getJSONArray("bookmarks")
        assertEquals(1, saved.length())
        assertEquals(WebBrowserAddress.recordable(details), saved.getJSONObject(0).getString("url"))
        assertEquals("http://192.168.31.185:8096/web/index.html", saved.getJSONObject(0).getString("url"))
        assertTrue(library.bookmark(details, "Emby"))
        assertEquals(0, WebBrowserLibrary(disk) {}.snapshot().getJSONArray("bookmarks").length())
        assertTrue(library.bookmark("http://192.168.31.185:8096", "Emby"))
        assertEquals("http://192.168.31.185:8096", WebBrowserLibrary(disk) {}.snapshot().getJSONArray("bookmarks").getJSONObject(0).getString("url"))
    }
    @Test fun toolbarBookmarkFailuresRollBackAndRetryWithoutSilentlyToggling() {
        var disk = "{}"
        var failWrite = true
        val library = WebBrowserLibrary(disk) { if (failWrite) throw java.io.IOException("fixture"); disk = it }
        val request = JSONObject().put("action", "toggle_bookmark").put("url", "http://192.168.31.185:8096/web/index.html#!/home")
        try { library.edit(request); fail("Expected write failure") } catch (_: java.io.IOException) { }
        assertEquals(0, library.snapshot().getJSONArray("bookmarks").length())
        failWrite = false
        assertEquals("", library.edit(request))
        val before = disk
        failWrite = true
        try { library.edit(request); fail("Expected write failure") } catch (_: java.io.IOException) { }
        assertEquals(1, library.snapshot().getJSONArray("bookmarks").length())
        assertEquals(before, disk)
        assertEquals("invalid_address", library.edit(JSONObject().put("action", "toggle_bookmark").put("url", "https://example.com/?access_token=secret")))
    }
    @Test fun onlyWebAddressesEnterTheBrowser() {
        assertEquals("https://www.bilibili.com", WebBrowserAddress.normalize(" www.bilibili.com "))
        assertEquals("http://192.168.1.2:8000/video", WebBrowserAddress.normalize("http://192.168.1.2:8000/video"))
        for (url in listOf("javascript:alert(1)", "file:///sdcard/file", "content://provider/file", "intent://app", "https://user:password@example.com", "https://example.com\n/path")) {
            assertNull(url, WebBrowserAddress.normalize(url))
        }
        assertTrue(WebBrowserAddress.navigable("about:blank"))
        assertFalse(WebBrowserAddress.navigable("about:config"))
        assertNull(WebBrowserAddress.recordable("https://example.com/callback?%63ode=secret"))
        assertEquals("https://example.com/", WebBrowserAddress.recordable("https://example.com/#access_token=secret"))
    }
    @Test fun privateVisitsAreNeverBackfilledWhenHistoryIsEnabled() {
        var saved = "{}"
        val library = WebBrowserLibrary(saved) { saved = it }
        library.visit("https://example.com/private", "private", 1)
        library.recordHistory = true
        library.visit("https://example.com/public", "public", 2)
        val persisted = JSONObject(saved).getJSONArray("history")
        assertEquals(1, persisted.length())
        assertEquals("https://example.com/public", persisted.getJSONObject(0).getString("url"))
        library.recordHistory = false
        library.bookmark("https://example.com/bookmark", "bookmark")
        assertFalse(saved.contains("/private"))
        assertEquals(2, library.snapshot().getJSONArray("history").length())
        library.clearHistory()
        val cleared = JSONObject(saved)
        assertEquals(0, cleared.getJSONArray("history").length())
        assertEquals(1, cleared.getJSONArray("bookmarks").length())
    }
    @Test fun invalidSavedEntriesAndDuplicatesAreDiscarded() {
        val saved = """{"bookmarks":[{"url":"https://example.com/","title":"a"},{"url":"https://example.com/","title":"b"},{"url":"file:///secret"}]}"""
        val library = WebBrowserLibrary(saved) {}
        assertEquals(1, library.snapshot().getJSONArray("bookmarks").length())
        assertTrue(library.bookmark("https://example.com/", "a"))
        assertEquals(0, library.snapshot().getJSONArray("bookmarks").length())
    }
    @Test fun bookmarksCanBeCreatedEditedAndRemovedWithoutTouchingHistory() {
        var disk = "{}"
        val library = WebBrowserLibrary(disk) { disk = it }
        library.recordHistory = true
        library.visit("https://example.com/watched", "watched", 42)
        assertEquals("", library.edit(JSONObject().put("action", "save_bookmark").put("url", "example.com/first").put("title", "First")))
        assertEquals("", library.edit(JSONObject().put("action", "save_bookmark").put("previous", "https://example.com/first")
            .put("url", "https://example.com/second").put("title", "Renamed")))
        val restored = WebBrowserLibrary(disk) {}
        assertEquals("Renamed", restored.snapshot().getJSONArray("bookmarks").getJSONObject(0).getString("title"))
        assertEquals("https://example.com/second", restored.snapshot().getJSONArray("bookmarks").getJSONObject(0).getString("url"))
        assertEquals("", library.edit(JSONObject("""{"action":"remove","collection":"bookmarks","urls":["https://example.com/second"]}""")))
        assertEquals(0, JSONObject(disk).getJSONArray("bookmarks").length())
        assertEquals(1, JSONObject(disk).getJSONArray("history").length())
    }
    @Test fun removingHistoryErasesBothPersistentAndTransientCopiesWithoutPromotingVisits() {
        var disk = "{}"
        val library = WebBrowserLibrary(disk) { disk = it }
        library.recordHistory = true
        library.visit("https://example.com/a", "old a", 1)
        library.visit("https://example.com/b", "b", 2)
        library.recordHistory = false
        library.visit("https://example.com/a", "new a", 3)
        library.visit("https://example.com/private", "private", 4)
        library.bookmark("https://example.com/bookmark", "bookmark")
        assertEquals("", library.edit(JSONObject("""{"action":"remove","collection":"history","urls":["https://example.com/a"]}""")))
        assertEquals(2, library.snapshot().getJSONArray("history").length())
        assertFalse(library.snapshot().toString().contains("/a\""))
        assertFalse(disk.contains("private"))
        assertEquals(1, WebBrowserLibrary(disk) {}.snapshot().getJSONArray("history").length())
        library.edit(JSONObject().put("action", "clear_history"))
        assertEquals(0, library.snapshot().getJSONArray("history").length())
        assertEquals(0, JSONObject(disk).getJSONArray("history").length())
        assertEquals(1, JSONObject(disk).getJSONArray("bookmarks").length())
    }
    @Test fun invalidAndDuplicateBookmarkEditsDoNotOverwriteExistingEntries() {
        var disk = "{}"
        val library = WebBrowserLibrary(disk) { disk = it }
        library.bookmark("https://example.com/a", "a")
        library.bookmark("https://example.com/b", "b")
        val before = disk
        for (url in listOf("file:///secret", "https://user:password@example.com", "https://example.com/?access_token=secret")) {
            assertEquals("invalid_address", library.edit(JSONObject().put("action", "save_bookmark")
                .put("previous", "https://example.com/a").put("url", url)))
        }
        assertEquals("bookmark_exists", library.edit(JSONObject().put("action", "save_bookmark")
            .put("previous", "https://example.com/a").put("url", "https://example.com/b")))
        assertEquals("bookmark_missing", library.edit(JSONObject().put("action", "save_bookmark")
            .put("previous", "https://example.com/deleted").put("url", "https://example.com/c")))
        assertEquals(before, disk)
        assertNull(WebBrowserAddress.normalize("https://example.com/" + "字".repeat(2000)))
    }
    @Test fun failedManagementWritesRollBackAndCanBeRetried() {
        var failWrite = false
        var disk = "{}"
        val library = WebBrowserLibrary(disk) { if (failWrite) throw java.io.IOException("fixture"); disk = it }
        library.bookmark("https://example.com/a", "a")
        val before = library.snapshot().toString()
        failWrite = true
        val deletion = JSONObject("""{"action":"remove","collection":"bookmarks","urls":["https://example.com/a"]}""")
        try { library.edit(deletion); fail("Expected write failure") } catch (_: java.io.IOException) { }
        assertEquals(before, library.snapshot().toString())
        assertEquals(1, JSONObject(disk).getJSONArray("bookmarks").length())
        failWrite = false
        assertEquals("", library.edit(deletion))
        assertEquals(0, JSONObject(disk).getJSONArray("bookmarks").length())
    }
    @Test fun batchDeletionPreservesUnselectedAndOtherCollectionEntries() {
        var disk = "{}"
        val library = WebBrowserLibrary(disk) { disk = it }
        library.recordHistory = true
        for (name in listOf("a", "b", "c")) {
            library.bookmark("https://example.com/$name", name)
            library.visit("https://example.com/$name", name, 1)
        }
        assertEquals("", library.edit(JSONObject("""{"action":"remove","collection":"bookmarks","urls":["https://example.com/a","https://example.com/c"]}""")))
        val saved = JSONObject(disk)
        assertEquals(1, saved.getJSONArray("bookmarks").length())
        assertEquals("b", saved.getJSONArray("bookmarks").getJSONObject(0).getString("title"))
        assertEquals(3, saved.getJSONArray("history").length())
        assertEquals("", library.edit(JSONObject("""{"action":"remove","collection":"history","urls":["https://example.com/b"]}""")))
        val reloaded = WebBrowserLibrary(disk) {}.snapshot()
        assertEquals(1, reloaded.getJSONArray("bookmarks").length())
        assertEquals(2, reloaded.getJSONArray("history").length())
    }
}
