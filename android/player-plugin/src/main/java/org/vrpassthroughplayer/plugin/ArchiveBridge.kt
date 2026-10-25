package org.vrpassthroughplayer.plugin

import android.content.Context
import android.net.Uri
import org.json.JSONArray
import org.json.JSONObject
import java.io.Closeable
import java.io.File
import java.io.FileInputStream
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

/** Only a single foreground archive owns a source lease. Passwords never enter media URIs. */
internal class ArchiveBridge(private val context: () -> Context?, private val sources: MediaSources,
    private val emit: (Int, String) -> Unit) : Closeable {
    private val worker = Executors.newSingleThreadExecutor { Thread(it, "ComicArchive") }
    private val generation = AtomicInteger()
    @Volatile private var closed = false
    @Volatile private var cancellation: CloudCancellation? = null
    private val pages = ArchivePageRequests()
    @Volatile private var session = ""
    @Volatile private var sourceUri = ""
    @Volatile private var sourceLease = ""
    private var cacheCleaned = false
    private var cacheInUse = false // guarded by PhotoCache.lock, including queued opens/closes
    private var sessionData: JSONObject? = null
    private var sessionPassword = ""
    private val unlocks by lazy {
        val storage = CloudAccountStore(app(), "archive-unlocks-v1.bin", "thru3d_archive_unlocks_v1")
        ArchiveUnlocks({ storage.load() }, { storage.save(it) })
    }
    private fun app() = context() ?: error("Archive unavailable")
    private fun core(body: JSONObject, cancel: CloudCancellation? = null): JSONObject {
        OpenListBackend.start(app())
        return OpenListBackend.request("POST", "/comic", body, cancel).getJSONObject("data").also {
            if (it.has("error")) {
                val error = it.getString("error")
                val upstream = if (error == "Source does not support archive range reading") sources.streamFailure(sourceLease) else null
                throw IllegalStateException(if (upstream?.httpStatus in setOf(429,503) ||
                    upstream?.sourceCode in setOf("cdn_rate_limited","cdn_connections_limited"))
                    "Archive source is busy; try again later" else error)
            }
        }
    }
    fun open(id: Int, uri: String, title: String, password: String, persist: Boolean): Int {
        if (closed) return -1
        val serial = generation.incrementAndGet(); cancellation?.cancel(); cancelPage()
        synchronized(PhotoCache.lock) { cacheInUse = true }
        worker.execute {
            if (serial != generation.get() || closed) return@execute
            val cancel = CloudCancellation(); cancellation = cancel
            val result = try {
                check(ArchiveKinds.supported(title.ifEmpty { Uri.parse(uri).lastPathSegment.orEmpty() })) { "Archive format or compression is not supported" }
                require(password.length <= 512)
                val candidate = if (password.isNotEmpty()) password else runCatching {
                    val book = passwords("list", "").optJSONArray("passwords") ?: JSONArray()
                    unlocks.password(uri, (0 until book.length()).map { book.getString(it) }.toSet())
                }.getOrDefault("")
                val cache = File(app().cacheDir, "comic-pages")
                if (!cacheCleaned) {
                    // Disposable extracted pages and downloaded copies, never the user's original.
                    cache.listFiles()?.filter { it.name.startsWith("comic-") }?.forEach { it.deleteRecursively() }
                    cacheCleaned = true
                }
                if (sourceUri != uri || sourceLease.isEmpty()) {
                    releaseSession()
                    val download = SmallRarCache(cache, cancel) { received, total ->
                        if (serial == generation.get() && !closed)
                            emit(id, JSONObject().put("state", "loading").put("received", received).put("total", total).toString())
                    }
                    sourceLease = sources.archiveStream(uri, download); sourceUri = uri
                }
                val retained = sessionData?.takeIf { session.isNotEmpty() }
                val data = retained?.let { JSONObject(it.toString()) }
                    ?: core(JSONObject().put("op", "open").put("url", sourceLease).put("name", title.ifEmpty { Uri.parse(uri).lastPathSegment.orEmpty() })
                        .put("password", candidate).put("remote", Uri.parse(uri).scheme !in setOf("file", "content", "usb") && !sources.cachedArchive(sourceLease))
                        .put("cache", cache.absolutePath), cancel)
                session = data.getString("session")
                if (serial != generation.get() || closed) throw InterruptedException()
                if (retained == null) sessionPassword = candidate
                ArchiveKinds.describeEntries(data)
                sessionData = JSONObject(data.toString())
                if (sessionPassword.isNotEmpty() && data.optBoolean("verified")) {
                    val saved = !persist || !passwords("add", sessionPassword).has("error")
                    val associated = runCatching { unlocks.verified(uri, sessionPassword, persist && saved) }.isSuccess
                    if (!saved || !associated) data.put("password_save_error", true)
                }
                data.put("state", "ready")
            } catch (e: Exception) {
                JSONObject().put("state", "error").put("error", safeError(e))
            } finally { if (cancellation === cancel) cancellation = null }
            if (serial == generation.get() && !closed) emit(id, result.toString())
        }
        return id
    }
    fun selectPage(id: Int, uri: String) { if (uri.startsWith("comic://")) pages.select(id, uri) else pages.cancel() }
    fun resolve(id: Int, uri: String): String {
        val value = Uri.parse(uri)
        val key = value.host.orEmpty(); val page = value.path?.removePrefix("/")?.toIntOrNull()
        require(key.isNotEmpty() && key == session && page != null && page >= 0) { "Archive session ended" }
        val cancel = pages.begin(id, uri)
        val result = core(JSONObject().put("op", "page").put("session", key).put("page", page), cancel)
        check(key == session && !closed && pages.isCurrent(id, uri)) { "Archive session ended" }
        return Uri.fromFile(File(result.getString("path"))).toString()
    }
    fun cancelPage(id: Int? = null) { pages.cancel(id) }
    fun validatePage(uri: String) {
        val value = Uri.parse(uri)
        check(!closed && value.scheme == "comic" && value.host == session && session.isNotEmpty() &&
            sources.hasPhotoStream(sourceLease)) { "Archive session ended" }
    }
    fun takePage(uri: String, cancel: CloudCancellation): File {
        validatePage(uri)
        val value = Uri.parse(uri)
        val page = value.path?.removePrefix("/")?.toIntOrNull() ?: error("Archive unavailable")
        val ticket = java.util.UUID.randomUUID().toString().replace("-", "")
        val result = try {
            core(JSONObject().put("op", "take-page").put("session", value.host).put("page", page).put("transfer", ticket), cancel)
        } catch (error: Exception) {
            // A disconnected response can still have completed extraction. The core serializes
            // cleanup after that request, so a late rename cannot resurrect an orphan.
            runCatching { worker.execute { runCatching {
                core(JSONObject().put("op", "discard-page").put("session", value.host).put("transfer", ticket))
            } } }
            throw error
        }
        val file = File(result.getString("path"))
        try { validatePage(uri); return file }
        catch (error: Exception) { file.delete(); throw error }
    }
    fun stop(expected: String = "") {
        if (expected.isNotEmpty() && expected != session) return
        val serial = generation.incrementAndGet(); cancellation?.cancel(); cancelPage()
        worker.execute {
            releaseSession()
            synchronized(PhotoCache.lock) { if (serial == generation.get()) cacheInUse = false }
        }
    }
    fun cacheDirectories(): Set<File> = synchronized(PhotoCache.lock) {
        if (cacheInUse) setOf(File(app().cacheDir, "comic-pages")) else emptySet()
    }
    private fun releaseSession() {
        val key = session; session = ""
        sessionData = null; sessionPassword = ""
        if (key.isNotEmpty() || sourceLease.isNotEmpty()) runCatching { core(JSONObject().put("op", "close").put("session", key)) }
        if (sourceLease.isNotEmpty()) sources.releasePhotoStream(sourceLease)
        sourceLease = ""; sourceUri = ""
    }
    @Synchronized fun passwords(operation: String, value: String): JSONObject = try {
        val storage = CloudAccountStore(app(), "archive-passwords-v1.bin", "thru3d_archive_passwords_v1")
        val original = storage.load()
        val values = (0 until original.length()).map { original.getString(it) }.toMutableList()
        when (operation) {
            "list" -> Unit
            "add" -> { require(value.isNotEmpty() && value.length <= 512); values.remove(value); values.add(0, value); require(values.size <= 100) }
            "delete" -> { unlocks.forget(value); values.remove(value) }
            else -> error("Invalid password book operation")
        }
        if (operation != "list") storage.save(JSONArray(values))
        JSONObject().put("passwords", JSONArray(values))
    } catch (_: Exception) { JSONObject().put("error", "Archive password book unavailable") }
    override fun close() { if (closed) return; closed = true; stop(); worker.execute { unlocks.clear() }; worker.shutdown() }
    companion object {
        fun safeError(e: Exception): String = if (e is CloudFailure && e.reason in setOf("cloud_location_expired","cloud_page_expired")) "Archive location expired; refresh the folder"
            else e.message?.takeIf { it.startsWith("Archive ") || it.startsWith("Solid archives") || it.startsWith("Source does not support archive") }
            ?: "Archive could not be opened"
    }
}

internal object ArchiveKinds {
    val extensions = setOf("zip", "cbz", "rar", "cbr", "7z", "tar", "gz", "tgz", "xz", "bz2", "zipx", "001")
    fun named(name: String) = name.substringBefore('?').substringBefore('#').substringAfterLast('.', "").lowercase() in extensions
    fun supported(name: String) = name.substringAfterLast('.', "").lowercase() in setOf("zip", "cbz", "rar", "cbr", "7z")
    fun describeEntries(data: JSONObject) {
        val entries = data.optJSONArray("entries") ?: return
        for (i in 0 until entries.length()) {
            val entry = entries.getJSONObject(i)
            if (entry.optString("kind") == "file" && entry.optString("title").substringAfterLast('.', "").lowercase() in DlnaClient.VIDEO_EXTENSIONS) entry.put("kind", "video")
        }
    }
}

/** A seekable file descriptor preserves Android SAF permission and USB/local ownership. */
internal class ArchiveFileSource(context: Context, uri: String) : StreamSource {
    private val descriptor = context.contentResolver.openFileDescriptor(Uri.parse(uri), "r") ?: error("Archive unavailable")
    private val input = FileInputStream(descriptor.fileDescriptor)
    override val size = try { input.channel.size().also { require(it > 0) } }
        catch (e: Exception) { runCatching { input.close() }; descriptor.close(); throw e }
    override fun open() = object : StreamSource.Reader {
        override fun read(offset: Long, buffer: ByteArray, length: Int): Int = input.channel.read(java.nio.ByteBuffer.wrap(buffer, 0, length), offset)
        override fun close() {}
    }
    override fun close() { runCatching { input.close() }; descriptor.close() }
}
