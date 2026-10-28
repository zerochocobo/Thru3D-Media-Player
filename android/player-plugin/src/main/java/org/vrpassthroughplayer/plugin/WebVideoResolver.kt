package org.vrpassthroughplayer.plugin

import android.content.Context
import com.yausername.youtubedl_android.YoutubeDL
import org.json.JSONObject
import java.io.Closeable
import java.io.File
import java.io.InputStream
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/** Local extraction only; no remote parsing service or user credential files. */
internal class WebVideoResolver(private val context: () -> Context?, private val ready: (WebVideoDescriptor) -> Unit,
    private val cookies: (String) -> org.json.JSONArray = { org.json.JSONArray() },
    private val browserMedia: (String) -> JSONObject? = { null }) : Closeable {
    private val executor = Executors.newSingleThreadExecutor { Thread(it, "WebVideoResolver") }
    private var job: Future<*>? = null
    private var active: Attempt? = null
    private var sequence = 0
    private var closed = false
    private var state = JSONObject().put("state", "idle")

    private class Attempt(val id: Int) {
        val cancelled = AtomicBoolean()
        var stage = "runtime"
        @Volatile var process: Process? = null
        @Volatile var probe: RemoteMediaHttp? = null
        fun cancel() { cancelled.set(true); process?.destroyForcibly(); probe?.close() }
        fun check() { check(!cancelled.get() && !Thread.currentThread().isInterrupted) { "Extraction cancelled" } }
    }
    private class ExtractionFailure(val code: String) : Exception()

    companion object {
        internal fun failureCode(error: Exception, stage: String): String {
            if (error is ExtractionFailure) return error.code
            if (error is MediaServerFailure) {
                if (error.httpStatus in setOf(401, 403)) return "site_rejected"
                if (error.httpStatus in setOf(404, 410)) return "video_unavailable"
                if (error.transportError.isNotEmpty()) return "network_failed"
            }
            return when (stage) {
                "runtime" -> "runtime_initialization_failed"
                "selection" -> "no_supported_stream"
                "projection" -> "projection_unavailable"
                "session" -> "browser_session_unavailable"
                else -> "extractor_failed"
            }
        }
    }

    @Synchronized fun begin(url: String): Int {
        if (closed) return 0
        cancel()
        val id = ++sequence
        val page = try { WebVideoPage.parse(url) } catch (_: Exception) {
            state = JSONObject().put("id", id).put("state", "error").put("error", "Choose a supported video URL").put("error_code", "unsupported_page")
            return id
        }
        val attempt = Attempt(id); active = attempt
        state = JSONObject().put("id", id).put("state", "resolving").put("uri", page.url)
        job = executor.submit {
            try {
                val app = context() ?: error("Activity unavailable")
                attempt.check()
                val media = browserMedia(url)
                if (media?.optBoolean("protected") == true) throw ExtractionFailure("protected_content")
                attempt.stage = "session"
                val session = cookies(page.url)
                attempt.check()
                val captured = media?.let { WebVideoBrowserCapture.formats(it, session) }
                var info = if (captured != null && (page.site in setOf("weibo", "tiktok", "instagram", "facebook", "twitter", "reddit") || !media?.optString("layout").isNullOrEmpty())) captured
                    else try { extract(app, page, attempt, session) } catch (error: Exception) { captured ?: throw error }
                attempt.check()
                val canonical = runCatching { WebVideoPage.parse(info.optString("webpage_url")) }.getOrNull()
                    ?.takeIf { it.site == page.site } ?: page
                attempt.stage = "selection"
                var selected = try { WebVideoFormats.select(canonical, info, WebVideoCapabilities()::accepts) } catch (error: Exception) {
                    // The extractor may only offer fragmented/HDR/unsupported formats while the
                    // page itself plays a plain progressive file; that file is still a valid handoff.
                    if (captured == null || info === captured) throw error
                    info = captured
                    WebVideoFormats.select(page, captured, WebVideoCapabilities()::accepts)
                }
                attempt.stage = "projection"
                var projection = inspectProjection(selected.video, attempt) ?: WebVideoPageProjection.parse(selected.video.pageLayout)
                if (projection != null) {
                    val immersive = WebVideoFormats.select(canonical, info, WebVideoCapabilities(2160)::accepts)
                    if (immersive.video.formatId != selected.video.formatId) {
                        val actual = inspectProjection(immersive.video, attempt) ?: WebVideoPageProjection.parse(immersive.video.pageLayout)
                        // A flat preview is not a replacement for a verified immersive representation.
                        if (actual != null) { selected = immersive; projection = actual }
                    }
                }
                require(selected.video.projectionHint.isEmpty() || projection != null) { "Missing immersive metadata" }
                require(selected.video.pageLayout.isEmpty() || projection != null) { "Unsupported page layout" }
                val descriptor = WebVideoDescriptor(selected.page, selected.title, selected.video, selected.audio,
                    selected.durationSeconds, projection = projection, silent = selected.silent)
                synchronized(this) {
                    if (closed || active !== attempt || attempt.cancelled.get()) return@submit
                    ready(descriptor)
                    state = descriptor.publicJson().put("id", id).put("state", "ready")
                }
            } catch (error: Exception) {
                synchronized(this) {
                    if (!closed && active === attempt && !attempt.cancelled.get()) state = JSONObject().put("id", id)
                        .put("state", "error").put("error", "Video extraction failed. Try the web page or another video.")
                        .put("error_code", failureCode(error, attempt.stage)).put("stage", attempt.stage)
                }
            } finally { attempt.process?.destroyForcibly(); attempt.process = null }
        }
        return id
    }
    @Synchronized fun snapshot(): String = state.toString()
    @Synchronized fun cancel() {
        active?.cancel(); active = null; job?.cancel(true); job = null
        state = JSONObject().put("state", "idle")
    }
    override fun close() { synchronized(this) { closed = true; cancel() }; executor.shutdownNow() }

    /** Some headset network paths intermittently cut connections. Retry once; a stream that
     * declares no projection is then treated as flat rather than failing the whole handoff,
     * while hinted immersive streams still require readable metadata (checked by the caller). */
    private fun inspectProjection(track: WebVideoTrack, attempt: Attempt): JSONObject? {
        repeat(2) { tries ->
            try { return readProjection(track, attempt) }
            catch (error: Exception) {
                attempt.check()
                if (error is IllegalArgumentException) throw error // Malformed metadata, not transport.
                if (tries == 1) { if (track.projectionHint.isEmpty() && track.pageLayout.isEmpty()) return null; throw error }
            }
        }
        return null
    }
    private fun readProjection(track: WebVideoTrack, attempt: Attempt): JSONObject? {
        attempt.check()
        if (track.transport != "file") return null
        val http = RemoteMediaHttp()
        attempt.probe = http
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(25)
        try {
            attempt.check()
            // Small bounded header read; signed URLs/headers stay on the resolver worker.
            val c = http.open(track.url, "bytes=0-${SphericalVideoMetadata.PREFIX_LIMIT-1}", track.headers)
            try {
                val data = c.inputStream.use { input ->
                    val buffer = ByteArray(SphericalVideoMetadata.PREFIX_LIMIT)
                    var size = 0
                    // DASH init segments are a few KiB; stop at the media data instead of
                    // pulling the full 2 MiB prefix (twice for immersive candidates).
                    while (size < buffer.size && !SphericalVideoMetadata.headerComplete(buffer, size)) {
                        attempt.check()
                        check(System.nanoTime() < deadline) { "Projection read timed out" }
                        val n = input.read(buffer, size, minOf(16384, buffer.size - size))
                        if (n < 0) break
                        size += n
                    }
                    buffer.copyOf(size)
                }
                return SphericalVideoMetadata.parse(data)
            } finally { http.release(c) }
        } finally { attempt.probe = null; http.close() }
    }

    private fun extract(app: Context, page: WebVideoPage, attempt: Attempt, cookies: org.json.JSONArray): JSONObject {
        // Bootstrap the pinned Android Python/QuickJS distribution; no downloader/update API is used.
        YoutubeDL.init(app)
        attempt.check()
        val bin = File(app.applicationInfo.nativeLibraryDir)
        val python = File(app.noBackupFilesDir, "youtubedl-android/packages/python/usr")
        val script = prepareScript(app)
        val bootstrap = app.assets.open("web-video/extract.py").bufferedReader().use { it.readText() }
        attempt.stage = "session"
        val session = cookies.toString().toByteArray(Charsets.UTF_8)
        require(session.size <= 256 * 1024)
        attempt.check()
        attempt.stage = "extraction"
        val command = listOf(File(bin, "libpython.so").absolutePath, "-c", bootstrap,
            script.absolutePath, File(bin, "libqjs.so").absolutePath, page.url)
        val process = ProcessBuilder(command).apply {
            environment().apply {
                put("LD_LIBRARY_PATH", File(python, "lib").absolutePath)
                put("SSL_CERT_FILE", File(python, "etc/tls/cert.pem").absolutePath)
                put("PYTHONHOME", python.absolutePath)
                put("PYTHONDONTWRITEBYTECODE", "1")
                put("HOME", python.absolutePath); put("TMPDIR", app.cacheDir.absolutePath)
            }
        }.start()
        attempt.process = process
        val readers = Executors.newFixedThreadPool(2) { Thread(it, "WebVideoOutput") }
        try {
            attempt.check() // Cancellation between ProcessBuilder.start and publication also kills it.
            val out = readers.submit<String> { readBounded(process.inputStream, 8 * 1024 * 1024, process) }
            val err = readers.submit<String> { readBounded(process.errorStream, 64 * 1024, process) }
            try { process.outputStream.use { it.write(session) } } finally { session.fill(0) }
            if (!process.waitFor(75, TimeUnit.SECONDS)) throw ExtractionFailure("timeout")
            attempt.check()
            if (process.exitValue() != 0) {
                // Only a fixed category crosses into diagnostics; raw errors can contain credentials
                // or signed CDN query strings and must never be copied into the UI/logs.
                val diagnostic = runCatching { err.get(5, TimeUnit.SECONDS).lowercase() }.getOrDefault("")
                throw ExtractionFailure(when {
                    "drm" in diagnostic -> "protected_content"
                    "impersonat" in diagnostic -> "browser_playback_required"
                    "fresh cookies" in diagnostic || "cookies are needed" in diagnostic -> "browser_session_required"
                    "sign in" in diagnostic || "login" in diagnostic || "logged-in" in diagnostic || "authentication is required" in diagnostic -> "login_required"
                    "geo" in diagnostic || "your country" in diagnostic -> "region_restricted"
                    "po token" in diagnostic -> "proof_token_required"
                    "http error 403" in diagnostic || "http error 412" in diagnostic -> "site_rejected"
                    "timed out" in diagnostic || "name resolution" in diagnostic || "unable to download" in diagnostic -> "network_failed"
                    "unavailable" in diagnostic || "private video" in diagnostic || "not found" in diagnostic -> "video_unavailable"
                    "javascript" in diagnostic || "quickjs" in diagnostic -> "javascript_failed"
                    else -> "extractor_failed"
                })
            }
            val json = out.get(5, TimeUnit.SECONDS)
            err.get(5, TimeUnit.SECONDS) // Drain, but never log diagnostics containing signed URLs/cookies.
            return JSONObject(json)
        } finally {
            session.fill(0)
            process.destroyForcibly(); process.inputStream.close(); process.errorStream.close(); process.outputStream.close()
            readers.shutdownNow()
        }
    }
    private fun readBounded(input: InputStream, limit: Int, process: Process): String {
        val output = java.io.ByteArrayOutputStream()
        val buffer = ByteArray(8192)
        input.use { while (true) {
            val n = it.read(buffer); if (n < 0) break
            if (output.size() + n > limit) { process.destroyForcibly(); error("Extractor output too large") }
            output.write(buffer, 0, n)
        } }
        return output.toString("UTF-8")
    }
    private fun prepareScript(app: Context): File {
        val manifest = JSONObject(app.assets.open("web-video/runtime.json").bufferedReader().use { it.readText() })
        val hash = manifest.getString("sha256")
        require(hash.matches(Regex("[0-9a-f]{64}")))
        val directory = File(app.noBackupFilesDir, "web-video").apply { mkdirs() }
        val target = File(directory, "yt-dlp-$hash.zip")
        fun digest(file: File): String {
            val d = java.security.MessageDigest.getInstance("SHA-256")
            file.inputStream().use { input -> val buffer = ByteArray(65536); while (true) {
                val n = input.read(buffer); if (n < 0) break; d.update(buffer, 0, n)
            } }
            return d.digest().joinToString("") { "%02x".format(it) }
        }
        if (!target.isFile || digest(target) != hash) {
            val temporary = File(directory, "runtime.tmp")
            try {
                app.assets.open("web-video/yt-dlp.zip").use { input -> temporary.outputStream().use { input.copyTo(it) } }
                check(digest(temporary) == hash) { "Extractor runtime integrity check failed" }
                check(temporary.renameTo(target)) { "Extractor runtime installation failed" }
            } finally { temporary.delete() }
        }
        return target
    }
}
