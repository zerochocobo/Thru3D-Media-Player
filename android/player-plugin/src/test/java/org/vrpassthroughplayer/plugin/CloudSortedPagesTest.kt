package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test

class CloudSortedPagesTest {
    @Test fun mixedOrderIsPassedThroughToProviderWithoutPageLocalSorting() {
        val client = Client(listOf(file("z.mp4"), CloudFile("a folder", true, 0, "/movies/a")))
        val page = CloudSortedPages().page(client, "/movies", 0, false, "mixed_modified_desc")
        assertEquals("mixed_modified_desc", client.calls.single().order)
        assertEquals(listOf("z.mp4", "a folder"), page.files.map { it.name })
        assertEquals(0, client.rawCalls)
        assertFalse(CloudSortedPages.validOrder("mixed_invalid"))
    }
    private fun file(name: String) = CloudFile(name, false, 100, "/movies/$name")
    private data class Call(val path: String, val offset: Int, val refresh: Boolean, val order: String)
    private class Client(var files: List<CloudFile>, val total: Int = files.size, val native: Boolean = true) : CloudClient {
        val calls = ArrayList<Call>()
        var rawCalls = 0
        var lastPage: CloudPage? = null
        private fun read(offset: Int): CloudPage {
            val end = minOf(files.size, offset + CloudDrive.PAGE_SIZE)
            return CloudPage(files.subList(offset, end), if (end < total) end else -1, total).also { lastPage = it }
        }
        override fun orderedPage(path: String, offset: Int, refresh: Boolean, order: String): CloudPage? {
            calls.add(Call(path, offset, refresh, order))
            return if (native) read(offset) else null
        }
        override fun page(path: String, offset: Int, refresh: Boolean): CloudPage { rawCalls++; return read(offset) }
        override fun list(path: String): List<CloudFile> = throw AssertionError("Browsing must not enumerate the directory")
        override fun find(path: String): CloudFile = throw AssertionError("Browsing must not locate media")
        override fun resolve(file: CloudFile): CloudLink = throw AssertionError("Browsing must not resolve streams")
    }

    @Test fun nameSortingRequestsOnlyTheRequestedApiPageInVeryLargeDirectories() {
        val client = Client((1..96).map { file("film$it.mp4") }, total = 50_000)
        val pages = CloudSortedPages()
        val first = pages.page(client, "/movies", 0, false, "name_asc")
        assertEquals(listOf(Call("/movies", 0, false, "name_asc")), client.calls)
        assertEquals(48, first.files.size)
        assertEquals(50_000, first.total)
        assertEquals(48, first.nextOffset)
        val next = pages.page(client, "/movies", 48, false, "name_asc")
        assertEquals(listOf(0, 48), client.calls.map { it.offset })
        assertEquals("film49.mp4", next.files.first().name)
        assertEquals(96, next.nextOffset)
        assertEquals(0, client.rawCalls)
    }

    @Test fun providerNameOrderIsPreservedIncludingLexicalNumbers() {
        val names = listOf("film1.mp4", "film10.mp4", "film2.mp4")
        val client = Client(names.map(::file))
        val page = CloudSortedPages().page(client, "/movies", 0, false, "name_asc")
        assertEquals(names, page.files.map { it.name })
        assertSame(client.lastPage, page)
    }

    @Test fun everySupportedOrderAndRefreshIsForwardedToTheProvider() {
        val client = Client(listOf(file("film.mp4")))
        val pages = CloudSortedPages()
        for (order in CloudSortedPages.ORDERS + "source") {
            pages.page(client, "/movies", 0, false, order)
            pages.page(client, "/movies", 0, true, order)
        }
        assertEquals(14, client.calls.size)
        assertEquals(7, client.calls.count { it.refresh })
        assertEquals(0, client.rawCalls)
    }

    @Test fun unsupportedNativeSortNeverFallsBackToAFullDirectoryRead() {
        val client = Client(listOf(file("film.mp4")), native = false)
        for (order in CloudSortedPages.ORDERS)
            assertThrows(CloudFailure::class.java) { CloudSortedPages().page(client, "/movies", 0, false, order) }
        assertEquals(0, client.rawCalls)
    }

    @Test fun sourceOrderWithoutNativeSortingStillReadsOnlyOneRawPage() {
        val client = Client((1..96).map { file("film$it.mp4") }, total = 50_000, native = false)
        val page = CloudSortedPages().page(client, "/movies", 48, false, "source")
        assertEquals("film49.mp4", page.files.first().name)
        assertEquals(50_000, page.total)
        assertEquals(1, client.rawCalls)
    }

    @Test fun rawApiPageRetainsM4aSubtitlesDocumentsAndUnknownFutureTypes() {
        val names = listOf("film.mp4", "film.srt", "film.si.mix.m4a", "notes.pdf", "notes.txt", "future.sidecar_new")
        val client = Client(names.map(::file))
        val page = CloudSortedPages().page(client, "/movies", 0, false, "name_asc")
        assertEquals(names, page.files.map { it.name })
        assertEquals(6, page.total)
        val media = page.files.filter { MediaKinds.supported(it.name) }
        // M4A is a supported audio entry even when it also serves as a video sidecar.
        assertEquals(listOf("film.mp4", "film.si.mix.m4a", "notes.pdf"), media.map { it.name })
        assertEquals(listOf("film.srt"), SidecarSubtitles.files(page.files.map { it.name }))
    }

    @Test fun sortedSingleApiPageFindsM4aWithoutAnySubtitleFile() {
        val client = Client(listOf(file("film.mp4"), file("film.si.mix.m4a")))
        val page = CloudSortedPages().page(client, "/movies", 0, false, "name_asc")
        val playback = CloudPlaybackPages.Playback("/movies/film.mp4", "account",
            CloudPlaybackPages.Selection(page.files, page.nextOffset < 0))
        assertEquals(listOf("film.si.mix.m4a"), SidecarAudio.forCloud(playback.path, playback.automatic(client)) { it.id }.map { it.title })
    }

    @Test fun completeApiPageReusesAudioAndSubtitlesWithoutAnotherLookup() {
        val client = Client(listOf("film.mp4", "film.srt", "film.si.mix.m4a", "film.commentary.M4A", "film10.si.mix.m4a", "future.sidecar_new").map(::file))
        val page = CloudSortedPages().page(client, "/movies", 0, false, "name_desc")
        val cache = CloudPlaybackPages()
        cache.replace("account", "identity", "/movies", page.files, true, "42")
        val selection = cache.forVideo("account", "identity", "/movies/film.mp4")
        assertEquals("42", selection.folderId)
        val playback = CloudPlaybackPages.Playback("/movies/film.mp4", "identity", selection)
        val raw = playback.automatic(client)
        assertEquals(listOf("film.si.mix.m4a", "film.commentary.M4A"), SidecarAudio.forCloud(playback.path, raw) { it.id }.map { it.title })
        assertEquals(listOf("film.srt"), SidecarSubtitles.forCloud(playback.path, raw) { it.id }.map { it.title })
        assertTrue(raw.any { it.name == "future.sidecar_new" })
        assertEquals(1, client.calls.size)
        assertEquals(0, client.rawCalls)
    }

    @Test fun partialPageKeepsExistingCompanionLookupPolicyAndOriginalMetadata() {
        val base = Client(listOf(file("film.mp4"), file("future.sidecar_new")), total = 100)
        var searches = 0
        val client = object : CloudClient by base {
            override fun companions(path: String, pageFiles: List<CloudFile>): List<CloudFile> {
                searches++
                assertEquals(base.files, pageFiles)
                return listOf(file("film.srt"), file("film.si.mix.m4a"))
            }
        }
        val page = CloudSortedPages().page(client, "/movies", 0, false, "name_asc")
        val playback = CloudPlaybackPages.Playback("/movies/film.mp4", "identity", CloudPlaybackPages.Selection(page.files, false))
        assertEquals(1, SidecarAudio.forCloud(playback.path, playback.automatic(client)) { it.id }.size)
        assertEquals(1, SidecarSubtitles.forCloud(playback.path, playback.automatic(client)) { it.id }.size)
        assertEquals(1, searches)
        assertEquals(1, base.calls.size)
    }

    @Test fun invalidOrderOrOffsetFailsBeforeAnyProviderRequest() {
        val client = Client(listOf(file("film.mp4")))
        val pages = CloudSortedPages()
        assertThrows(IllegalArgumentException::class.java) { pages.page(client, "/movies", -1, false, "name_asc") }
        assertThrows(IllegalArgumentException::class.java) { pages.page(client, "/movies", 0, false, "invalid") }
        assertTrue(client.calls.isEmpty())
        assertEquals(0, client.rawCalls)
    }

    @Test fun nonAlignedRawOffsetIsPassedThroughFor115FilteredRows() {
        val client = Client((1..5).map { file("film$it.mp4") })
        val page = CloudSortedPages().page(client, "/movies", 2, false, "name_asc")
        assertEquals("film3.mp4", page.files.first().name)
        assertEquals(2, client.calls.single().offset)
    }

    @Test fun providerFailuresAreNotRetriedThroughDirectoryEnumeration() {
        var requests = 0
        val base = Client(listOf(file("film.mp4")))
        val client = object : CloudClient by base {
            override fun orderedPage(path: String, offset: Int, refresh: Boolean, order: String): CloudPage {
                requests++
                throw CloudFailure()
            }
        }
        assertThrows(CloudFailure::class.java) { CloudSortedPages().page(client, "/movies", 0, false, "name_asc") }
        assertEquals(1, requests)
        assertEquals(0, base.rawCalls)
    }

    @Test fun naturalComparatorRemainsAvailableForExplicitLegacySearchResults() {
        assertTrue(CloudSortedPages.natural("2.mp4", "10.mp4") < 0)
        assertTrue(CloudSortedPages.natural("_a.png", "a.png") > 0)
        assertTrue(CloudSortedPages.natural(".cover.png", "!cover.png") < 0)
        val names = listOf("a2.png", "A02.png", "a02.png", "a10.png", "中2.png", "中10.png")
        val files = names.reversed().map(::file)
        assertEquals(listOf("A02.png", "a02.png", "a2.png", "a10.png", "中2.png", "中10.png"),
            files.sortedWith(CloudSortedPages.comparator("name_asc")).map { it.name })
    }
}
