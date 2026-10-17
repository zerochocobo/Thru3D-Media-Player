package org.vrpassthroughplayer.plugin

/** Raw rows of the currently displayed page, before the media-only UI filter.
 * Cache pages stay separate; automatic discovery can search an incomplete directory.
 * Only process-local metadata is retained. */
internal class CloudPlaybackPages(private val now: () -> Long = { System.nanoTime() / 1_000_000 }) {
    data class Selection(val files: List<CloudFile> = emptyList(), val complete: Boolean = false, val folderId: String = "")
    class Playback(val path: String, val identity: String, val page: Selection) {
        private var found: List<CloudFile>? = null
        /** A complete one-page listing needs no search. Both track types share one result. */
        @Synchronized fun automatic(client: CloudClient): List<CloudFile> = found ?: (
            if (page.complete) page.files else runCatching { client.companions(path, page.files) }.getOrDefault(page.files)
        ).also { found = it }

        fun subtitleNames(): List<String> = SidecarSubtitles.files(page.files.groupBy { it.name }.values
            .filter { it.size == 1 }.map { it.single() }.filter { !it.folder && it.size > 0 }.map { it.name })

        fun subtitle(name: String): CloudFile = page.files.filter { it.name == name }.singleOrNull()
            ?.takeIf { SidecarSubtitles.supportedFile(it.name) && !it.folder && it.size > 0 }
            ?: throw CloudFailure("cloud_file_missing")
    }
    private data class Page(val identity: String, val directory: String, val selection: Selection, val expires: Long)
    private val pages = LinkedHashMap<String, Page>(8, .75f, true)

    @Synchronized fun replace(account: String, identity: String, directory: String, files: List<CloudFile>, complete: Boolean = false, folderId: String = "") {
        require(files.size <= CloudDrive.PAGE_SIZE)
        pages[account] = Page(identity, directory, Selection(files.toList(), complete, folderId), now() + 120_000)
        while (pages.size > 8) pages.remove(pages.keys.first())
    }

    /** Capture once on video open; later browsing cannot change this video's companions. */
    @Synchronized fun forVideo(account: String, identity: String, path: String): Selection {
        val page = pages[account] ?: return Selection()
        if (page.identity != identity) {
            pages.remove(account)
            return Selection()
        }
        if (page.directory != path.substringBeforeLast('/').ifEmpty { "/" }) return Selection()
        val video = page.selection.files.filter { it.name == path.substringAfterLast('/') }
        if (video.size != 1 || video.single().folder) return Selection()
        // A visible directory's ID stays useful after its metadata expires; files are still verified fresh.
        if (page.expires <= now()) return Selection(folderId = page.selection.folderId)
        return page.selection
    }

    @Synchronized fun folderId(account: String, identity: String, directory: String): String =
        pages[account]?.takeIf { it.identity == identity && it.directory == directory }?.selection?.folderId.orEmpty()

    @Synchronized fun remove(account: String) { pages.remove(account) }
}
