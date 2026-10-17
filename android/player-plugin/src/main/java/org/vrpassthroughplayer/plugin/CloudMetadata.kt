package org.vrpassthroughplayer.plugin

/** Account-local, bounded metadata only. Never stores download URLs or credentials. */
internal class CloudMetadata(private val now: () -> Long = { System.nanoTime() / 1_000_000 }) {
    private data class Value(val item: Any, val expires: Long)
    private data class PageKey(val path: String, val offset: Int, val order: String)
    private val files = LinkedHashMap<String, Value>(16, 0.75f, true)
    private val pages = LinkedHashMap<PageKey, Value>(16, 0.75f, true)
    @Synchronized fun file(path: String): CloudFile? = files[path]?.takeIf { it.expires > now() }?.item as? CloudFile
    @Synchronized fun page(path: String, offset: Int, order: String = "source"): CloudPage? = pages[PageKey(path, offset, order)]
        ?.takeIf { it.expires > now() }?.item as? CloudPage
    @Synchronized fun previous(path: String, offset: Int, order: String = "source"): CloudPage? = pages.entries
        .firstOrNull { it.key.path == path && it.key.order == order && it.value.expires > now() && (it.value.item as CloudPage).nextOffset == offset }
        ?.value?.item as? CloudPage
    @Synchronized fun put(path: String, file: CloudFile) {
        files[path] = Value(file, now() + 120_000)
        while (files.size > 20_000) files.remove(files.keys.first())
    }
    @Synchronized fun put(path: String, offset: Int, page: CloudPage, order: String = "source") {
        pages[PageKey(path, offset, order)] = Value(page, now() + 120_000)
        while (pages.size > 64) pages.remove(pages.keys.first())
    }
    @Synchronized fun invalidate(path: String) {
        val prefix = path.trimEnd('/') + "/"
        files.keys.removeAll { it == path || it.startsWith(prefix) }
        pages.keys.removeAll { it.path == path || it.path.startsWith(prefix) }
    }
}
