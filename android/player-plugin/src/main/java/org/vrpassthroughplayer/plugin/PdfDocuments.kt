package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import java.io.Closeable
import java.io.File
import java.net.URI
import java.util.concurrent.Executors

/** One render worker; browser, reader and PiP references have independent lifetimes. */
internal class PdfDocuments(private val openRenderer: (String, CloudCancellation, JSONObject) -> Renderer,
    private val emit: (Int, String) -> Unit) : Closeable {
    interface Renderer : Closeable {
        val pages: Int
        val sourceIdentity: JSONObject get() = JSONObject()
        fun validate() {}
        fun render(page: Int, edge: Int): File
    }
    private class Session(val uri: String, var references: Int = 1, var renderer: Renderer? = null,
        val cancellation: CloudCancellation = CloudCancellation())
    private val lock = Any()
    private val sessions = mutableMapOf<String, Session>()
    private val worker = Executors.newSingleThreadExecutor { Thread(it, "PdfPages") }
    private var closed = false

    fun open(id: Int, uri: String, identity: String = "{}"): Int = synchronized(lock) {
        if (closed) return -1
        val key = id.toString()
        val session = Session(uri)
        if (sessions.size >= 8) return -1
        sessions[key] = session
        worker.execute {
            if (!alive(key, session)) return@execute
            val result = try {
                require(if (uri.startsWith("smb://")) PdfSmbSource.supported(uri)
                    else URI(uri).scheme in setOf("file", "content", "cloud")) { "PDF_UNAVAILABLE" }
                val hint = if (identity.length <= 16384) runCatching { JSONObject(identity) }.getOrDefault(JSONObject()) else JSONObject()
                val renderer = openRenderer(uri, session.cancellation, hint)
                session.renderer = renderer
                require(renderer.pages in 1..20000) { "PDF_PAGE_LIMIT" }
                val entries = JSONArray()
                for (page in 0 until renderer.pages) entries.put(JSONObject()
                    .put("title", "%05d.png".format(java.util.Locale.ROOT, page + 1))
                    .put("kind", "image").put("uri", "pdfpage://$key/$page")
                    .put("pdf_page", page).put("pdf_pages", renderer.pages))
                JSONObject().put("state", "ready").put("session", key).put("entries", entries)
                    .put("source_file", renderer.sourceIdentity)
            } catch (error: Exception) {
                runCatching { session.renderer?.close() }; session.renderer = null
                session.cancellation.cancel()
                JSONObject().put("state", "error").put("error", safeError(error))
            }
            if (alive(key, session)) emit(id, result.toString())
        }
        id
    }

    private fun alive(key: String, session: Session) = synchronized(lock) { !closed && sessions[key] === session }
    fun retain(key: String): Boolean = synchronized(lock) {
        val session = sessions[key] ?: return false
        if (closed) return false
        session.references++; true
    }
    fun release(key: String) {
        val retired = synchronized(lock) {
            val session = sessions[key] ?: return
            if (--session.references != 0) return
            sessions.remove(key)
            worker.execute { runCatching { session.renderer?.close() }; session.renderer = null }
            session
        }
        retired.cancellation.cancel()
    }

    /** Call only from an image IO worker, never the Godot or Android UI thread. */
    fun resolve(uri: String, edge: Int, cancelled: () -> Boolean = { false }): String {
        val value = URI(uri)
        require(value.scheme == "pdfpage" && value.rawQuery == null && value.rawFragment == null) { "PDF_UNAVAILABLE" }
        val key = value.host ?: error("PDF_UNAVAILABLE")
        val page = value.path.removePrefix("/").toIntOrNull() ?: error("PDF_UNAVAILABLE")
        // Queue under the same lock as release: renderer close follows this read,
        // while the last consumer can still cancel blocked network IO immediately.
        val future = synchronized(lock) {
            check(!closed) { "PDF_UNAVAILABLE" }
            val session = sessions[key] ?: error("PDF_UNAVAILABLE")
            worker.submit<String> {
                if (!alive(key, session) || cancelled()) throw InterruptedException()
                val renderer = session.renderer ?: error("PDF_UNAVAILABLE")
                require(page in 0 until renderer.pages) { "PDF_UNAVAILABLE" }
                renderer.render(page, edge.coerceIn(256, 3072)).toURI().toString()
            }
        }
        return future.get()
    }

    fun validate(uri: String) {
        val key = URI(uri).host ?: error("PDF_UNAVAILABLE")
        val future = synchronized(lock) {
            val session = sessions[key] ?: error("PDF_UNAVAILABLE")
            check(!closed)
            worker.submit { check(alive(key, session)); (session.renderer ?: error("PDF_UNAVAILABLE")).validate() }
        }
        future.get()
    }

    override fun close() {
        val remaining = synchronized(lock) {
            if (closed) return
            closed = true
            val values = sessions.values.toList(); sessions.clear()
            worker.execute { values.forEach { runCatching { it.renderer?.close() }; it.renderer = null } }
            worker.shutdown()
            values
        }
        remaining.forEach { it.cancellation.cancel() }
    }

    companion object {
        fun safeError(error: Exception): String = when {
            error.message in setOf("PDF_CACHE_FULL", "PDF_NETWORK_UNAVAILABLE", "PDF_PAGE_LIMIT", "PDF_NOT_SEEKABLE", "PDF_PASSWORD_UNSUPPORTED") -> error.message!!
            error is CloudFailure && error.reason == "cloud_location_expired" -> "PDF_LOCATION_EXPIRED"
            error is CloudFailure || error is PlaybackFailureException -> "PDF_NETWORK_UNAVAILABLE"
            else -> "PDF_UNAVAILABLE"
        }
    }
}
