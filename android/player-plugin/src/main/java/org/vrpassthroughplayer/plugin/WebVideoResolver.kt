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

    @Synchronized fun begin(url: String, bilibiliBeta: Boolean = false): Int {
        if (closed) return 0
        cancel()
        val id = ++sequence
        val publicPage = runCatching { WebVideoPage.parse(url) }.getOrNull()
        val attempt = Attempt(id); active = attempt
        state = JSONObject().put("id", id).put("state", "resolving")
        job = executor.submit {
            try {
                val app = context() ?: error("Activity unavailable")
                attempt.check()
                val media = browserMedia(url)
                if (media?.optBoolean("protected") == true) throw ExtractionFailure("protected_content")
                val sourcePage = publicPage ?: media?.let { WebVideoBrowserCapture.serverPage(url, it) ?: WebVideoNetworkCapture.page(url, it) }
                    ?: throw ExtractionFailure("unsupported_page")
                val pgc = sourcePage.site == "bilibili" && sourcePage.id.matches(Regex("(?:ep|ss)[1-9][0-9]{0,19}:1"))
                val page = if (pgc) WebVideoBilibiliCapture.episodePage(sourcePage, media)
                    ?: throw ExtractionFailure("browser_playback_required") else sourcePage
                val networkEnabled = media?.optBoolean("network_enabled") == true
                val bilibiliEnabled = bilibiliBeta && page.site == "bilibili" && media?.optBoolean("bilibili_enabled") == true
                if (bilibiliBeta && !bilibiliEnabled)
                    throw ExtractionFailure("browser_playback_required")
                val browserQuality = networkEnabled || bilibiliEnabled
                // The browser already selected this quality using the user's site session.
                // Do not force its member/4K stream through the extractor's default 1080p cap.
                val maxHeight = if (browserQuality) maxOf(2160, minOf(media.optInt("width"), media.optInt("height"))).coerceAtMost(8192)
                    else if (BuildConfig.DEBUG && media?.optInt("diagnostic_max_height") == 2160) 2160 else 1080
                val capabilities = WebVideoCapabilities(maxHeight)::accepts
                val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(30)
                val network = WebVideoNetworkCapture({ uri, headers, prefix ->
                    readBrowserResource(uri, headers, prefix, attempt, deadline)
                }, capabilities)
                attempt.stage = "browser_capture"
                var route = if (bilibiliEnabled) "browser_bilibili" else if (networkEnabled) "browser_network" else "browser_direct"
                val session by lazy { attempt.stage = "session"; cookies(page.url) }
                val legacy = if (!browserQuality || media.optBoolean("server")) media?.let {
                    WebVideoBrowserCapture.formats(it, if (it.optBoolean("server")) org.json.JSONArray() else session)
                } else null
                val (info, initial) = WebVideoResolution.select(page, {
                    if (media?.optBoolean("server") == true) legacy
                    else if (bilibiliEnabled) WebVideoBilibiliCapture.formats(page, media)
                    else if (networkEnabled) network.resolve(page, media)
                    else legacy?.takeIf { page.site in setOf("weibo", "tiktok", "instagram", "facebook", "twitter", "reddit") || !media?.optString("layout").isNullOrEmpty() }
                }, {
                    attempt.check()
                    // Opt-in means keep the website's stream/quality. If that stream cannot be
                    // transferred, do not silently replace a member stream with a public preview.
                    if (browserQuality || publicPage == null) throw ExtractionFailure("browser_playback_required")
                    route = "extractor"
                    attempt.stage = "session"
                    val savedCookies = session
                    attempt.check()
                    try { extract(app, page, attempt, savedCookies) } catch (error: Exception) {
                        if (pgc) throw error
                        val fallback = media?.let { WebVideoBrowserCapture.formats(it, savedCookies) } ?: throw error
                        route = "browser_direct"; fallback
                    }
                }, capabilities, attempt::check, {
                    if (browserQuality) null else legacy?.also { route = "browser_direct" }
                })
                if (browserQuality && !WebVideoNetworkCapture.keepsQuality(initial.video, media))
                    throw ExtractionFailure("browser_playback_required")
                if (pgc && kotlin.math.abs(initial.durationSeconds - media!!.getDouble("duration")) > maxOf(2.0, initial.durationSeconds * .01))
                    throw ExtractionFailure("browser_playback_required")
                var selected = initial
                attempt.stage = "projection"
                fun projectionFor(track: WebVideoTrack): JSONObject? =
                    (if (network.projections.containsKey(track.url)) network.projections[track.url] else inspectProjection(track, attempt))
                        ?: WebVideoPageProjection.parse(track.pageLayout)
                var projection = projectionFor(selected.video)
                if (projection != null && !browserQuality) {
                    val immersive = WebVideoFormats.select(selected.page, info, WebVideoCapabilities(2160)::accepts)
                    if (immersive.video.formatId != selected.video.formatId) {
                        val actual = projectionFor(immersive.video)
                        // A flat preview is not a replacement for a verified immersive representation.
                        if (actual != null) { selected = immersive; projection = actual }
                    }
                }
                require(selected.video.projectionHint.isEmpty() || projection != null) { "Missing immersive metadata" }
                require(selected.video.pageLayout.isEmpty() || projection != null) { "Unsupported page layout" }
                val descriptor = WebVideoDescriptor(selected.page, selected.title, selected.video, selected.audio,
                    selected.durationSeconds, projection = projection, silent = selected.silent)
                // EME or SPA replacement can arrive while network probes run. Never publish an
                // old representation after the page switched content or acquired MediaKeys.
                if (media != null) {
                    val latest = browserMedia(url) ?: throw ExtractionFailure("browser_playback_required")
                    if (latest.optBoolean("protected")) throw ExtractionFailure("protected_content")
                    if (latest.optString("capture_identity") != media.optString("capture_identity") || latest.optBoolean("network_enabled") != networkEnabled)
                        throw ExtractionFailure("browser_playback_required")
                    if (pgc && WebVideoBilibiliCapture.episodePage(sourcePage, latest) != page)
                        throw ExtractionFailure("browser_playback_required")
                    if (bilibiliEnabled) {
                        val current = WebVideoBilibiliCapture.formats(page, latest) ?: throw ExtractionFailure("browser_playback_required")
                        val pair = WebVideoFormats.select(page, current, capabilities)
                        if (pair.video.url != selected.video.url || pair.audio?.url != selected.audio?.url)
                            throw ExtractionFailure("browser_playback_required")
                    }
                    if (browserQuality && !WebVideoNetworkCapture.keepsQuality(selected.video, latest))
                        throw ExtractionFailure("browser_playback_required")
                }
                synchronized(this) {
                    if (closed || active !== attempt || attempt.cancelled.get()) return@submit
                    ready(descriptor)
                    state = descriptor.publicJson().put("id", id).put("state", "ready").put("resolution_route", route)
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

    private fun readBrowserResource(uri: java.net.URI, headers: Map<String, String>, prefix: Boolean,
        attempt: Attempt, deadline: Long): Pair<java.net.URI, ByteArray> {
        attempt.check(); check(System.nanoTime() < deadline)
        val http = RemoteMediaHttp(); attempt.probe = http
        try {
            val limit = SphericalVideoMetadata.PREFIX_LIMIT
            val c = http.open(uri, if (prefix) "bytes=0-${limit - 1}" else "", headers)
            try {
                c.readTimeout = 5000
                if (c.responseCode == 206) require(c.getHeaderField("Content-Range").orEmpty().startsWith("bytes 0-"))
                if (!prefix) require(c.contentLengthLong <= limit)
                val bytes = c.inputStream.use { input ->
                    val out = java.io.ByteArrayOutputStream(); val buffer = ByteArray(16384)
                    while (out.size() < limit) {
                        attempt.check(); check(System.nanoTime() < deadline)
                        val count = input.read(buffer, 0, minOf(buffer.size, limit - out.size()))
                        if (count < 0) break
                        out.write(buffer, 0, count)
                        if (prefix) {
                            val data = out.toByteArray()
                            if (SphericalVideoMetadata.headerComplete(data, data.size) && (WebVideoContainer.parse(data)?.duration ?: 0.0) > 0 ||
                                WebVideoContainer.transportStream(data) != null) break
                        }
                    }
                    if (!prefix) require(out.size() < limit || input.read() == -1)
                    out.toByteArray()
                }
                if (!prefix && c.responseCode == 206) {
                    val match = Regex("bytes 0-([0-9]+)/([0-9]+)").matchEntire(c.getHeaderField("Content-Range").orEmpty())
                    require(match != null && match.groupValues[1].toLong() + 1 == bytes.size.toLong() && match.groupValues[2].toLong() == bytes.size.toLong())
                }
                return c.url.toURI() to bytes
            } finally { http.release(c) }
        } finally { attempt.probe = null; http.close() }
    }

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
                if (BuildConfig.DEBUG) {
                    // Debug builds name the failure type only: fixed tokens, never URLs or cookies.
                    val kinds = Regex("\\[ssl: [a-z_]+]|timed out|http error [0-9]{3}|[a-z]+error\\b").findAll(diagnostic).map { it.value }.distinct().take(6)
                    android.util.Log.w("WebVideoResolver", "extractor exit ${process.exitValue()}: ${kinds.joinToString()}")
                }
                throw ExtractionFailure(when {
                    "drm" in diagnostic -> "protected_content"
                    "bilibili preview" in diagnostic -> "browser_playback_required"
                    "impersonat" in diagnostic -> "browser_playback_required"
                    "fresh cookies" in diagnostic || "cookies are needed" in diagnostic -> "browser_session_required"
                    "sign in" in diagnostic || "login" in diagnostic || "logged-in" in diagnostic || "authentication is required" in diagnostic -> "login_required"
                    "geo" in diagnostic || "your country" in diagnostic -> "region_restricted"
                    "po token" in diagnostic -> "proof_token_required"
                    "http error 403" in diagnostic || "http error 412" in diagnostic -> "site_rejected"
                    "timed out" in diagnostic || "name resolution" in diagnostic || "unable to download" in diagnostic ||
                        "[ssl: unexpected_eof" in diagnostic || "eof occurred" in diagnostic || "connection reset" in diagnostic ||
                        "remote end closed" in diagnostic -> "network_failed"
                    "unavailable" in diagnostic || "no longer available" in diagnostic || "private video" in diagnostic || "not found" in diagnostic -> "video_unavailable"
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
