package org.vrpassthroughplayer.plugin

import android.content.Context
import android.graphics.Bitmap
import android.net.Uri
import org.json.JSONObject
import java.io.Closeable
import java.io.File
import java.util.concurrent.Executors

/**
 * The reading mode's own document service: one open book, paginated for the reader's current type
 * settings. Pages are drawn on request as images for the book's leaves; nothing here touches the
 * photo or PDF paths.
 */
internal class BookBridge(private val context: () -> Context?, private val ready: (Int, String) -> Unit,
    private val page: (Int, Int, String) -> Unit, private val found: (Int, Int, String) -> Unit = { _, _, _ -> },
    private val remote: (String, CloudCancellation) -> PdfNetworkSource = { _, _ -> error("BOOK_UNAVAILABLE") }) : Closeable {
    private class Session(val id: Int, @Volatile var pages: BookSheets? = null, @Volatile var copy: File? = null,
        val cancellation: CloudCancellation = CloudCancellation())
    private val lock = Any()
    private val worker = Executors.newSingleThreadExecutor { Thread(it, "BookPages") }
    /** Searches run apart from page drawing; a newer search makes the one running give up. */
    private val searcher = Executors.newSingleThreadExecutor { Thread(it, "BookSearch") }
    private val searches = java.util.concurrent.atomic.AtomicInteger()
    private var session: Session? = null
    private var closed = false
    private var prepared = false

    private fun cache() = File(context()?.cacheDir ?: error("BOOK_UNAVAILABLE"), "book-pages").also { directory ->
        check(directory.isDirectory || directory.mkdirs()) { "BOOK_CACHE_FULL" }
        if (!prepared) { directory.listFiles()?.forEach { it.delete() }; prepared = true }
    }

    /** Replaces the open book. [style] is the reader's type settings as JSON. */
    fun open(id: Int, uri: String, style: String): Int = synchronized(lock) {
        if (closed) return -1
        val next = Session(id)
        val previous = session
        session = next
        previous?.cancellation?.cancel() // A book still on its way from the network stops downloading.
        worker.execute {
            previous?.let(::dispose)
            if (!current(next)) return@execute
            val result = try {
                val started = System.nanoTime()
                val file = source(Uri.parse(uri), next)
                val look = BookStyle.parse(style).let { it.withFont(font(it.font)) }
                val name = Uri.parse(uri).lastPathSegment ?: uri
                val saved = layouts(uri, file, look)
                val pages = if (pdf(file)) PdfSheets(file, name.substringAfterLast('/').substringBeforeLast('.'), look)
                    else Books.open(file, name).let { book ->
                        if (saved?.isFile == true) BookPages(book, look, saved)
                        else try {
                            // The chapter being read first; the whole book follows without holding up the pages.
                            chapter(style, book).let { at -> BookPages(book, look, null, at..at).also { whole(next, id, book, look, saved, at) } }
                        } catch (error: Throwable) { book.close(); throw error }
                    }
                next.pages = pages
                pages.describe().put("state", "ready").put("session", id).put("open_ms", (System.nanoTime() - started) / 1_000_000)
            } catch (error: Throwable) {
                dispose(next)
                JSONObject().put("state", "error").put("session", id).put("error",
                    error.message?.takeIf { it in setOf("BOOK_PROTECTED", "BOOK_CACHE_FULL", "PDF_PAGE_LIMIT") } ?: "BOOK_UNAVAILABLE")
            }
            if (current(next)) ready(id, result.toString()) else dispose(next)
        }
        id
    }

    /**
     * Where this book's page breaks for these type settings are kept between openings, so a long book
     * opens at once the second time. Only the newest few books keep theirs.
     */
    /** A font is only read from the app's own downloads: a font file, inside its files folder. */
    private fun font(path: String): String {
        if (path.isEmpty()) return ""
        val home = context()?.filesDir?.canonicalPath ?: return ""
        val file = runCatching { java.io.File(path).canonicalFile }.getOrNull() ?: return ""
        return file.path.takeIf { it.startsWith(home + java.io.File.separator) && file.isFile &&
            file.extension.lowercase() in setOf("otf", "ttf") } ?: ""
    }

    private fun layouts(uri: String, file: File, look: BookStyle): File? = runCatching {
        val directory = File(context()?.cacheDir ?: return@runCatching null, "book-layouts")
        if (!directory.isDirectory && !directory.mkdirs()) return@runCatching null
        val stamp = if (Uri.parse(uri).scheme == "file") file.lastModified() else 0L
        val digest = java.security.MessageDigest.getInstance("SHA-1").digest("$uri|${file.length()}|$stamp|${look.key}".toByteArray())
        val target = File(directory, digest.joinToString("") { "%02x".format(it) } + ".pages")
        if (target.isFile) target.setLastModified(System.currentTimeMillis())
        directory.listFiles()?.sortedByDescending { it.lastModified() }?.drop(LAYOUTS)?.forEach { it.delete() }
        target
    }.getOrNull()

    private fun pdf(file: File) = runCatching { file.inputStream().use { ByteArray(5).let { head -> it.read(head) == 5 && String(head, Charsets.ISO_8859_1) == "%PDF-" } } }.getOrDefault(false)

    /** Chapters around [at] worth laying out first, or null when the whole book is quick anyway. */
    private fun window(book: Book, at: Int): IntRange? {
        fun size(index: Int) = book.chapters[index].flow.blocks.sumOf { (it as? BookBlock.Text)?.text?.length ?: 0 }
        if (book.chapters.size < 8) return null
        val first = maxOf(0, at - 2)
        var last = at; var characters = (first..at).sumOf(::size)
        while (last + 1 < book.chapters.size && characters < WINDOW_CHARACTERS) characters += size(++last)
        return if (first == 0 && last == book.chapters.size - 1) null else first..last
    }

    private fun chapter(style: String, book: Book) = runCatching {
        org.json.JSONObject(style).optString("at").substringBefore('/').toInt() }.getOrDefault(0).coerceIn(0, book.chapters.size - 1)

    /**
     * Paginates the whole book off the page worker, then swaps it in and tells the reader again. A long
     * book first gets a window of chapters around [at] (a few hundred thousand characters, a second or
     * two), so the reader can go on for dozens of chapters while the rest (a minute for a 15 MB serial
     * on Quest 3) is laid out.
     */
    private fun whole(owner: Session, id: Int, book: Book, look: BookStyle, saved: File?, at: Int) {
        Thread({
            window(book, at)?.let { range ->
                val near = try { BookPages(book, look, null, range) { !current(owner) } } catch (_: Throwable) { null }
                if (near != null) post {
                    if (!current(owner)) { near.close(); return@post }
                    owner.pages = near
                    ready(id, near.describe().put("state", "ready").put("session", id).toString())
                }
            }
            if (!current(owner)) { post { if (!current(owner)) runCatching { book.close() } }; return@Thread }
            val pages = try { BookPages(book, look, saved) { !current(owner) } } catch (error: Throwable) {
                runCatching { android.util.Log.w("QuestBookPages", "whole book layout failed: ${error.javaClass.simpleName} ${error.message}") }; null }
            post {
                if (pages == null) {
                    // The chapters on show stay readable; the reader is told the rest could not be laid out.
                    if (!current(owner)) runCatching { book.close() }
                    else ready(id, JSONObject().put("state", "error").put("session", id).put("error", "BOOK_LAYOUT_FAILED").toString())
                    return@post
                }
                if (!current(owner)) { pages.close(); return@post }
                owner.pages = pages
                ready(id, pages.describe().put("state", "ready").put("session", id).toString())
            }
        }, "BookWhole").start()
    }

    /** Parsers need a seekable file; anything that is not one already is copied once. */
    private fun source(uri: Uri, owner: Session): File {
        if (uri.scheme == "file") return File(uri.path ?: error("BOOK_UNAVAILABLE"))
        if (uri.scheme != "content") return download(uri.toString(), owner)
        val app = context() ?: error("BOOK_UNAVAILABLE")
        val target = File.createTempFile("source-", ".book", cache())
        owner.copy = target
        (app.contentResolver.openInputStream(uri) ?: error("BOOK_UNAVAILABLE")).use { input ->
            target.outputStream().use { output ->
                val buffer = ByteArray(1 shl 16)
                var total = 0L
                while (true) {
                    val read = input.read(buffer)
                    if (read < 0) break
                    total += read
                    require(total <= SOURCE_BYTES) { "BOOK_UNAVAILABLE" }
                    if (owner.cancellation.cancelled) error("BOOK_CANCELLED")
                    if (total and 0xFFFFFL < read && target.parentFile!!.usableSpace < 64L shl 20) error("BOOK_CACHE_FULL")
                    output.write(buffer, 0, read)
                }
            }
        }
        return target
    }

    /** A book on a share, cloud drive or media server: fetched whole into the cache before it is read. */
    private fun download(uri: String, owner: Session): File {
        val network = remote(uri, owner.cancellation)
        network.use { input ->
            val size = input.source.size
            require(size in 1..SOURCE_BYTES) { "BOOK_UNAVAILABLE" }
            if (cache().usableSpace < size + (64L shl 20)) error("BOOK_CACHE_FULL")
            val name = uri.substringAfterLast('/').substringAfterLast('.', "book").take(8).filter { it.isLetterOrDigit() }
            val target = File.createTempFile("source-", ".$name", cache())
            owner.copy = target
            input.source.open().use { reader ->
                target.outputStream().use { output ->
                    val buffer = ByteArray(1 shl 16)
                    var offset = 0L
                    while (offset < size) {
                        input.validate()
                        if (!current(owner)) error("BOOK_UNAVAILABLE")
                        val read = reader.read(offset, buffer, minOf(buffer.size.toLong(), size - offset).toInt())
                        if (read <= 0) error("BOOK_UNAVAILABLE")
                        output.write(buffer, 0, read)
                        offset += read
                    }
                }
            }
            return target
        }
    }

    /** Hands work to the page worker; once the bridge has closed there is nothing to hand it to. */
    private fun post(task: () -> Unit) {
        try { worker.execute(task) } catch (_: java.util.concurrent.RejectedExecutionException) {}
    }

    private fun current(value: Session) = synchronized(lock) { !closed && session === value }
    private fun dispose(value: Session) {
        value.cancellation.cancel()
        runCatching { value.pages?.close() }; value.pages = null
        value.copy?.delete(); value.copy = null
    }

    /** Finds [query] in the open book; the hits arrive with [token] through the found signal. */
    fun search(id: Int, query: String, token: Int): Boolean = synchronized(lock) {
        val owner = session?.takeIf { !closed && it.id == id } ?: return false
        val generation = searches.incrementAndGet()
        searcher.execute {
            val pages = owner.pages ?: return@execute
            val result = try {
                pages.search(query.take(64), SEARCH_HITS) { searches.get() != generation || !current(owner) }
            } catch (_: Throwable) { JSONObject().put("hits", org.json.JSONArray()).put("more", false) }
            if (searches.get() == generation && current(owner)) found(id, token, result.put("query", query).toString())
        }
        true
    }

    /** The words at a reading position, for naming a bookmark. */
    fun excerpt(id: Int, at: String): String {
        val pages = synchronized(lock) { session?.takeIf { !closed && it.id == id }?.pages } ?: return ""
        return runCatching { pages.excerpt(at) }.getOrDefault("")
    }

    /** Draws one page [edge] pixels tall and reports its file; the reader deletes it after loading. */
    fun render(id: Int, index: Int, edge: Int): Boolean = synchronized(lock) {
        val owner = session?.takeIf { !closed && it.id == id } ?: return false
        worker.execute {
            if (!current(owner)) return@execute
            val pages = owner.pages ?: return@execute
            if (index !in 0 until pages.pages) return@execute
            var bitmap: Bitmap? = null
            val path = try {
                bitmap = pages.render(index, edge.coerceIn(256, 3072))
                val file = File.createTempFile("page-", ".jpg", cache())
                file.outputStream().use { check(bitmap.compress(Bitmap.CompressFormat.JPEG, 96, it)) }
                file.path
            } catch (_: Throwable) { "" } finally { bitmap?.recycle() }
            if (current(owner)) page(id, index, path) else if (path.isNotEmpty()) File(path).delete()
        }
        true
    }

    /** Read-aloud blocks of a page. Pages are immutable once ready, so this never waits for drawing. */
    fun text(id: Int, index: Int): String? {
        val pages = synchronized(lock) { session?.takeIf { it.id == id }?.pages } ?: return null
        return if (index in 0 until pages.pages) runCatching { pages.text(index).toString() }.getOrNull() else null
    }

    fun discard(path: String) {
        val file = File(path)
        if (file.parentFile?.name == "book-pages" && file.name.startsWith("page-")) file.delete()
    }

    fun close(id: Int) {
        val old = synchronized(lock) { session?.takeIf { it.id == id }?.also { session = null } } ?: return
        worker.execute { dispose(old) }
    }

    override fun close() {
        val old = synchronized(lock) { if (closed) return; closed = true; session.also { session = null } }
        worker.execute { old?.let(::dispose) }
        worker.shutdown()
        searches.incrementAndGet(); searcher.shutdown()
    }

    private companion object { const val SOURCE_BYTES = 512L * 1024 * 1024; const val LAYOUTS = 40; const val WINDOW_CHARACTERS = 400_000; const val SEARCH_HITS = 300 }
}
