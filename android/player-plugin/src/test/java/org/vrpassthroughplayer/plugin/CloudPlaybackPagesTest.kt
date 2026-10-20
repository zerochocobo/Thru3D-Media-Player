package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test

class CloudPlaybackPagesTest {
    private fun file(name: String) = CloudFile(name, false, 100, "/movies/$name")
    private val first = listOf(file("film.mp4"), file("film.srt"), file("other.ass"), file("film.si.mix.m4a"))
    private val second = listOf(file("next.mp4"), file("film.en.srt"))

    @Test fun rawPlaybackPagesRemainBoundedAndPreserveUnknownFileTypes() {
        val cache = CloudPlaybackPages()
        val files = listOf(file("film.mp4"), file("film.si.mix.m4a"), file("film.srt"), file("future.sidecar_new"))
        cache.replace("account", "identity", "/movies", files, true)
        assertEquals(files, cache.forVideo("account", "identity", "/movies/film.mp4").files)
        val tooMany = (1..49).map { file("film$it.mp4") }
        for (complete in listOf(false, true))
            assertThrows(IllegalArgumentException::class.java) { cache.replace("other", "identity", "/movies", tooMany, complete) }
    }
    private class NoDirectoryClient : CloudClient {
        var searches = 0
        var directoryRequests = 0
        var failure = false
        override fun page(path: String, offset: Int, refresh: Boolean): CloudPage { directoryRequests++; error("No extra directory requests") }
        override fun list(path: String): List<CloudFile> { directoryRequests++; error("Never enumerate sibling pages") }
        override fun find(path: String): CloudFile = error("Discovery must preserve returned identities")
        override fun resolve(file: CloudFile): CloudLink = error("Only selected tracks may be resolved")
        override fun companions(path: String, pageFiles: List<CloudFile>): List<CloudFile> {
            searches++
            if (failure) throw CloudFailure()
            return listOf(CloudFile("film.zh.srt", false, 100, "/movies/film.zh.srt"))
        }
    }

    @Test fun completeSinglePageSkipsSearchForBothTrackTypesAndManualSelector() {
        val cache = CloudPlaybackPages()
        cache.replace("account", "mount", "/movies", first, complete = true)
        val client = NoDirectoryClient()
        val selected = CloudPlaybackPages.Playback("/movies/film.mp4", "mount", cache.forVideo("account", "mount", "/movies/film.mp4"))
        assertEquals(1, SidecarAudio.forCloud(selected.path, selected.automatic(client)) { it.name }.size)
        assertEquals(1, SidecarSubtitles.forCloud(selected.path, selected.automatic(client)) { it.name }.size)
        assertEquals(listOf("film.srt", "other.ass"), selected.subtitleNames())
        assertEquals("other.ass", selected.subtitle("other.ass").name)
        assertEquals(0, client.searches)
        assertEquals(0, client.directoryRequests)
    }

    @Test fun multiplePagesSearchOnceAndManualSelectorNeverExposesSearchOnlyFiles() {
        val client = NoDirectoryClient()
        val selected = CloudPlaybackPages.Playback("/movies/film.mp4", "mount", CloudPlaybackPages.Selection(first, false))
        repeat(2) { assertEquals(listOf("film.zh.srt"), selected.automatic(client).map { it.name }) }
        assertEquals(1, client.searches)
        assertEquals(0, client.directoryRequests)
        assertEquals(listOf("film.srt", "other.ass"), selected.subtitleNames())
        assertThrows(CloudFailure::class.java) { selected.subtitle("film.zh.srt") }
        assertThrows(CloudFailure::class.java) { selected.subtitle("../other.srt") }
        assertEquals(1, client.searches)
    }

    @Test fun unavailableSearchAndMissingCacheNeverFallBackToDirectoryEnumeration() {
        val client = NoDirectoryClient().apply { failure = true }
        val selected = CloudPlaybackPages.Playback("/movies/film.mp4", "mount", CloudPlaybackPages.Selection())
        repeat(2) { assertTrue(selected.automatic(client).isEmpty()) }
        assertEquals(3, client.searches)
        assertTrue(selected.subtitleNames().isEmpty())
        assertEquals(0, client.directoryRequests)
    }

    @Test fun failedSearchRetainsCachedCompanionsAndStopsAfterBoundedRetries() {
        val client = NoDirectoryClient().apply { failure = true }
        val selected = CloudPlaybackPages.Playback("/movies/film.mp4", "mount", CloudPlaybackPages.Selection(first, false))
        assertEquals(listOf("film.srt"), SidecarSubtitles.forCloud(selected.path, selected.automatic(client)) { it.name }.map { it.title })
        assertEquals(1, SidecarAudio.forCloud(selected.path, selected.automatic(client)) { it.name }.size)
        assertEquals(3, client.searches)
        assertEquals(0, client.directoryRequests)
    }

    @Test fun coldHistoryRecoversOriginalDirectoryWithoutAVisiblePage() {
        val folders = ArrayList<String>()
        val client = object : CloudClient {
            override fun page(path: String, offset: Int, refresh: Boolean): CloudPage = error("Unexpected page")
            override fun list(path: String): List<CloudFile> { folders.add(path); return first }
            override fun find(path: String): CloudFile {
                assertEquals("/movies/other.ass", path)
                return file("other.ass")
            }
            override fun resolve(file: CloudFile): CloudLink = error("Discovery must not resolve streams")
        }
        val selected = CloudPlaybackPages.Playback("/movies/film.mp4", "mount", CloudPlaybackPages.Selection())
        assertEquals(listOf("film.srt"), SidecarSubtitles.forCloud(selected.path, selected.automatic(client)) { it.name }.map { it.title })
        selected.automatic(client)
        assertEquals(listOf("/movies"), folders)
        assertEquals("other.ass", selected.subtitle("other.ass", client).name)
        assertThrows(IllegalArgumentException::class.java) { selected.subtitle("../escape.srt", client) }
    }

    @Test fun transientSearchFailureIsRetriedAndSuccessfulResultIsShared() {
        var attempts = 0
        val client = object : CloudClient {
            override fun page(path: String, offset: Int, refresh: Boolean): CloudPage = error("Unexpected page")
            override fun list(path: String): List<CloudFile> {
                attempts++
                if (attempts == 1) throw CloudFailure()
                return first
            }
            override fun find(path: String): CloudFile = error("Unexpected lookup")
            override fun resolve(file: CloudFile): CloudLink = error("Unexpected resolve")
        }
        val selected = CloudPlaybackPages.Playback("/movies/film.mp4", "mount", CloudPlaybackPages.Selection())
        assertEquals(first, selected.automatic(client))
        assertEquals(first, selected.automatic(client))
        assertEquals(2, attempts)
        selected.cancellation.cancel()
        val cancelled = CloudPlaybackPages.Playback("/movies/film.mp4", "mount", CloudPlaybackPages.Selection())
        cancelled.cancellation.cancel()
        assertTrue(cancelled.automatic(client).isEmpty())
        assertEquals(2, attempts)
    }

    @Test fun rawCurrentPageKeepsHiddenCaptionsAndAudioWithoutCombiningPages() {
        val cache = CloudPlaybackPages()
        cache.replace("account", "mount", "/movies", first)
        val captured = cache.forVideo("account", "mount", "/movies/film.mp4").files
        assertEquals(listOf("film.srt", "other.ass"), SidecarSubtitles.files(captured.map { it.name }))
        assertEquals(listOf("film.srt"), SidecarSubtitles.forCloud("/movies/film.mp4", captured) { it.name }.map { it.title })
        assertEquals(1, SidecarAudio.forCloud("/movies/film.mp4", captured) { it.name }.size)
        cache.replace("account", "mount", "/movies", second)
        assertTrue(cache.forVideo("account", "mount", "/movies/film.mp4").files.isEmpty())
        assertEquals(first, captured) // An open video's manual selector keeps its original page.
        assertEquals(second, cache.forVideo("account", "mount", "/movies/next.mp4").files)
    }

    @Test fun refreshSortDirectoryAndAccountDoNotLeakOldPages() {
        val cache = CloudPlaybackPages()
        cache.replace("account", "mount", "/movies", first)
        assertTrue(cache.forVideo("different", "mount", "/movies/film.mp4").files.isEmpty())
        assertTrue(cache.forVideo("account", "mount", "/other/film.mp4").files.isEmpty())
        cache.replace("account", "mount", "/movies", second)
        assertTrue(cache.forVideo("account", "mount", "/movies/film.mp4").files.isEmpty())
        cache.replace("account", "mount", "/movies", first)
        assertTrue(cache.forVideo("account", "new-mount", "/movies/film.mp4").files.isEmpty())
        assertTrue(cache.forVideo("account", "mount", "/movies/film.mp4").files.isEmpty())
        cache.replace("account", "mount", "/movies", first)
        assertEquals(first, cache.forVideo("account", "mount", "/movies/film.mp4").files)
        cache.replace("account", "mount", "/movies", first)
        cache.remove("account")
        assertTrue(cache.forVideo("account", "mount", "/movies/film.mp4").files.isEmpty())
    }

    @Test fun duplicateVideoNamesAndUnopenedHistoryDoNotSelectAnUnrelatedPage() {
        val cache = CloudPlaybackPages()
        assertTrue(cache.forVideo("account", "mount", "/movies/film.mp4").files.isEmpty())
        cache.replace("account", "mount", "/movies", first + file("film.mp4"))
        assertTrue(cache.forVideo("account", "mount", "/movies/film.mp4").files.isEmpty())
        for (i in 0..8) cache.replace("$i", "mount", "/movies", first)
        assertTrue(cache.forVideo("0", "mount", "/movies/film.mp4").files.isEmpty())
    }

    @Test fun visibleSinglePageKeepsIdentityAndNoSearchPolicyUntilNavigationOrAccountChange() {
        val cache=CloudPlaybackPages()
        cache.replace("account","mount","/movies",first,true,"42")
        assertEquals("42",cache.forVideo("account","mount","/movies/film.mp4").folderId)
        val expired=cache.forVideo("account","mount","/movies/film.mp4")
        assertEquals(first, expired.files); assertTrue(expired.complete); assertEquals("42",expired.folderId)
        assertEquals("42",cache.folderId("account","mount","/movies"))
        assertEquals("",cache.folderId("account","new-mount","/movies"))
        assertEquals("",cache.folderId("account","mount","/other"))
        cache.remove("account")
        assertEquals("",cache.folderId("account","mount","/movies"))
    }
}
