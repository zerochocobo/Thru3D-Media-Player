package org.vrpassthroughplayer.plugin

import java.io.Closeable
import java.io.File
import java.net.URI
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** One disposable file window for the main reader. No Bitmap, texture or depth ownership.
 * All source work is serial; selection cancels obsolete IO, but never interrupts PdfRenderer.
 * A file leased to PhotoBridge survives eviction until its copy has finished. */
internal class ReadingPageCache(
    private val load: (String, CloudCancellation) -> File,
    private val validate: (String) -> Unit,
    private val dispose: (File) -> Unit,
    private val budget: Long = 128L * 1024 * 1024,
    private val pageLimit: Long = 32L * 1024 * 1024,
    private val settleMillis: Long = 120,
) : Closeable {
    private class Entry(val uri: String, val file: File, val bytes: Long, var readers: Int = 0)
    private class Work(val uri: String, val background: Boolean, val cancellation: CloudCancellation = CloudCancellation())
    private val lock = PhotoCache.lock
    private val worker = Executors.newSingleThreadScheduledExecutor { Thread(it, "ReadingPages") }
    private val entries = linkedMapOf<String, Entry>()
    private val leased = mutableMapOf<String, Entry>()
    private var wanted = emptyList<String>() // current, forward, backward, in admission priority
    private var ahead = emptyList<String>()
    private val failed = mutableSetOf<String>()
    private var selectedId = 0
    private var selectedUri = ""
    private var selectedAt = 0L
    private var active: Work? = null
    private var scheduled = false
    private var closed = false
    private var paused = false

    fun window(keep: List<String>, prefetch: List<String>) {
        val cancel = synchronized(lock) {
            if (closed) return
            val next = keep.filter(::supported).distinct().take(6)
            val pending = prefetch.filter { it in next }.distinct().take(4)
            if (next == wanted && pending == ahead) return
            wanted = next; ahead = pending
            failed.retainAll(next.toSet())
            prune()
            schedule()
            active?.takeIf { it.uri !in next }?.cancellation
        }
        cancel?.cancel()
    }

    fun select(id: Int, uri: String) {
        val cancel = synchronized(lock) {
            selectedId = id; selectedUri = uri
            selectedAt = System.nanoTime()
            // Stop speculative work until the new page/spread has actually been displayed.
            ahead = emptyList()
            active?.takeIf { it.uri != uri }?.cancellation
        }
        cancel?.cancel()
    }

    fun cancel(id: Int) {
        val token = synchronized(lock) {
            if (selectedId != id) return
            selectedId = 0; selectedUri = ""
            active?.cancellation
        }
        token?.cancel()
    }

    /** Called on PhotoBridge's IO thread. Matching in-flight prefetch is reused, not restarted. */
    fun resolve(id: Int, uri: String): String {
        val future = synchronized(lock) {
            check(!closed && selectedId == id && selectedUri == uri)
            worker.submit<String> {
                fun current() = synchronized(lock) { !closed && selectedId == id && selectedUri == uri }
                if (!current()) throw InterruptedException()
                validate(uri) // Also validate warm cache hits after account/session revocation.
                val hit = synchronized(lock) {
                    if (!current()) throw InterruptedException()
                    entries[uri]?.takeIf { it.file.isFile }?.let { entry ->
                        // Lookup and pin must be atomic with window eviction on the UI thread.
                        entry.readers++
                        entry.file.toURI().toString().also { leased[it] = entry }
                    }
                }
                if (hit != null) return@submit hit
                // Preserve the old archive selection debounce for rapid page scrubbing.
                while (synchronized(lock) { System.nanoTime() - selectedAt < 120_000_000L }) {
                    if (!current()) throw InterruptedException()
                    Thread.sleep(10)
                }
                val entry = produce(uri, allowed = ::current)
                synchronized(lock) {
                    if (!current()) { retire(entry); throw InterruptedException() }
                    entry.readers++
                    val path = entry.file.toURI().toString()
                    leased[path] = entry
                    admit(entry)
                    path
                }
            }
        }
        return future.get()
    }

    fun release(path: String): Boolean = synchronized(lock) {
        val entry = leased[path] ?: return false
        if (--entry.readers == 0) {
            leased.remove(path)
            if (entries[entry.uri] !== entry) dispose(entry.file)
        }
        true
    }

    fun files(): Set<File> = synchronized(lock) { (entries.values + leased.values).map { it.file }.toSet() }

    fun cached(uri: String): Boolean = synchronized(lock) {
        !closed && !paused && entries[uri]?.file?.isFile == true
    }

    /** Speculative rendering can only lease an already extracted/rendered page. No IO miss. */
    fun acquireCached(uri: String): String {
        validate(uri)
        return synchronized(lock) {
            check(!closed && !paused)
            val entry = entries[uri]?.takeIf { it.file.isFile } ?: error("PAGE_NOT_CACHED")
            entry.readers++
            entry.file.toURI().toString().also { leased[it] = entry }
        }
    }

    private fun produce(uri: String, background: Boolean = false, allowed: () -> Boolean): Entry {
        val work = Work(uri, background)
        synchronized(lock) { if (closed || !allowed()) throw InterruptedException(); active = work }
        var file: File? = null
        try {
            validate(uri)
            file = load(uri, work.cancellation)
            synchronized(lock) {
                if (closed || work.cancellation.cancelled) throw InterruptedException()
            }
            require(file.isFile && file.length() > 0)
            return Entry(uri, file, file.length())
        } catch (error: Throwable) {
            file?.let(dispose)
            throw error
        } finally { synchronized(lock) { if (active === work) active = null } }
    }

    private fun admit(entry: Entry) {
        if (!paused && entry.uri in wanted && entry.bytes <= pageLimit && entry.bytes <= budget) entries[entry.uri] = entry
        else { retire(entry); return }
        prune()
    }

    private fun retire(entry: Entry) {
        if (entries[entry.uri] === entry) entries.remove(entry.uri)
        if (entry.readers == 0) dispose(entry.file)
    }

    private fun prune() {
        entries.values.toList().filter { it.uri !in wanted }.forEach(::retire)
        var bytes = entries.values.sumOf { it.bytes }
        for (uri in wanted.asReversed()) {
            if (bytes <= budget) break
            entries[uri]?.let { bytes -= it.bytes; retire(it) }
        }
    }

    private fun schedule() {
        if (scheduled || closed || paused || ahead.none { it !in entries && it !in failed }) return
        scheduled = true
        worker.schedule(task@{
            val uri = synchronized(lock) {
                scheduled = false
                if (closed || paused) null else ahead.firstOrNull { it !in entries && it !in failed }
            } ?: return@task
            try {
                val entry = produce(uri, true) { !paused && uri in ahead }
                synchronized(lock) {
                    if (!closed && !paused && uri in wanted) admit(entry) else retire(entry)
                    // Oversized or budget-rejected pages must not loop on every idle frame.
                    if (uri !in entries) failed.add(uri)
                }
            } catch (_: Exception) { synchronized(lock) { if (uri in ahead) failed.add(uri) } }
            synchronized(lock) { schedule() }
        }, settleMillis, TimeUnit.MILLISECONDS)
    }

    fun foreground(value: Boolean) {
        val cancel = synchronized(lock) {
            paused = !value
            if (paused) entries.values.toList().forEach(::retire) else { failed.clear(); schedule() }
            // Keep an already requested foreground page readable on resume. Only speculative
            // work is cancelled; foreground output is leased but not retained while paused.
            active?.takeIf { paused && it.background }?.cancellation
        }
        cancel?.cancel()
    }

    override fun close() {
        val cancel = synchronized(lock) {
            if (closed) return
            closed = true; wanted = emptyList(); ahead = emptyList(); prune()
            worker.shutdown()
            active?.cancellation
        }
        cancel?.cancel()
    }

    companion object {
        fun supported(uri: String): Boolean = runCatching {
            val value = URI(uri)
            value.scheme in setOf("comic", "pdfpage") && !value.host.isNullOrEmpty() &&
                value.rawQuery == null && value.rawFragment == null &&
                (value.path.removePrefix("/").toIntOrNull() ?: -1) >= 0
        }.getOrDefault(false)
    }
}
