package org.vrpassthroughplayer.plugin

import android.content.Context
import android.graphics.BitmapFactory
import android.net.Uri
import android.webkit.URLUtil
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

/** Anonymous download. No account cookies, bearer tokens, page JavaScript or cloud bridge. */
internal class PanoramaDownload(private val context: () -> Context?, private val originals: PanoramaOriginals) {
    private val worker = Executors.newSingleThreadExecutor { r -> Thread(r, "PanoramaDownload") }
    private val epoch = AtomicInteger()
    @Volatile private var connection: HttpURLConnection? = null
    @Volatile private var state = JSONObject()
    @Volatile private var closed = false
    private var original: File? = null
    fun snapshot(): JSONObject = JSONObject(state.toString())
    @Synchronized fun cancel() {
        epoch.incrementAndGet(); connection?.disconnect(); state = JSONObject()
        original?.let { originals.release(it) }; original = null
    }
    @Synchronized fun view(source: String) {
        originals.view(source)
        if (original?.let { Uri.fromFile(it).toString() } == source) {
            original?.let { originals.release(it) }; original = null; state = JSONObject()
        }
    }
    @Synchronized fun start(url: String, referer: String, disposition: String = "") {
        if (closed || !PanoramaWebPolicy.allowed(url)) return
        cancel()
        val token = epoch.get()
        state = JSONObject().put("state", "loading").put("bytes", 0)
        worker.execute {
            var partial: File? = null
            var active: HttpURLConnection? = null
            try {
                fun current() { if (closed || token != epoch.get()) throw InterruptedException() }
                current()
                context() ?: error("Image download failed")
                val directory = originals.prepare()
                val remaining = minOf(12L * 1024 * 1024 * 1024 - (directory.listFiles()?.sumOf { it.length() } ?: 0),
                    directory.usableSpace) - 64L * 1024 * 1024
                require(remaining > 0) { "Panorama storage is full" }
                var next = url
                var http: HttpURLConnection? = null
                for (redirect in 0..5) {
                    current()
                    require(PanoramaWebPolicy.allowed(next)) { "Image download failed" }
                    http = URL(next).openConnection() as HttpURLConnection
                    connection = http; active = http
                    http.instanceFollowRedirects = false; http.connectTimeout = 15000; http.readTimeout = 20000
                    http.setRequestProperty("User-Agent", "Thru3D-PanoramaBrowser/1.0")
                    val sourceOrigin = PanoramaWebPolicy.origin(referer)
                    if (sourceOrigin.isNotEmpty()) http.setRequestProperty("Referer", sourceOrigin)
                    val status = http.responseCode
                    if (status in setOf(301, 302, 303, 307, 308)) {
                        val location = http.getHeaderField("Location") ?: error("Image download failed")
                        next = URL(URL(next), location).toString(); http.disconnect(); http = null
                    } else { require(status == 200) { "Image download failed" }; break }
                }
                val response = http ?: error("Image download failed")
                val type = PanoramaWebPolicy.mime(response.contentType.orEmpty())
                // Image-looking URLs may still be gallery/license HTML. Resume them in the browser.
                if (type in setOf("text/html", "application/xhtml+xml")) {
                    if (token == epoch.get()) state = JSONObject().put("state", "page").put("url", next)
                    return@execute
                }
                require(type in PanoramaWebPolicy.imageTypes || type == "application/octet-stream") { "Choose a supported image original" }
                val length = response.contentLengthLong
                require(length <= PhotoBridge.MAX_BYTES) { "Image too large" }
                require(length <= remaining) { "Panorama storage is full" }
                val name = URLUtil.guessFileName(url, disposition, type).substringBeforeLast('.').take(60)
                    .replace(Regex("[^\\p{L}\\p{N}._ -]"), "_").ifBlank { "panorama" }
                partial = File.createTempFile("download-", ".part", directory)
                var count = 0L; var reported = 0L
                response.inputStream.use { input -> partial!!.outputStream().use { output ->
                    // Check the actual format before saving a potentially huge body.
                    val prefix = ByteArray(12)
                    var offset = 0
                    while (offset < prefix.size) {
                        current()
                        val read = input.read(prefix, offset, prefix.size - offset)
                        if (read < 0) break
                        offset += read
                    }
                    require(offset == prefix.size && PanoramaWebPolicy.imageHeader(prefix)) { "Choose a supported image original" }
                    output.write(prefix); count = prefix.size.toLong()
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        current()
                        val read = input.read(buffer); if (read < 0) break
                        count += read; require(count <= PhotoBridge.MAX_BYTES) { "Image too large" }
                        require(count <= remaining) { "Panorama storage is full" }
                        output.write(buffer, 0, read)
                        if (count - reported >= 256 * 1024) {
                            reported = count
                            if (token == epoch.get()) state = JSONObject().put("state", "loading").put("bytes", count).put("total", length)
                        }
                    }
                } }
                current()
                require(length < 0 || count == length) { "Image download failed" }
                val bounds = PhotoBitmap.bounds(partial!!)
                require(bounds.outMimeType in PanoramaWebPolicy.imageTypes) { "Choose a supported image original" }
                require(PanoramaWebPolicy.highResolution(bounds.outWidth, bounds.outHeight)) { "Choose an 8K or larger original" }
                val actualExtension = when (bounds.outMimeType) { "image/png" -> "png"; "image/webp" -> "webp"; "image/tiff" -> "tif"; "image/vnd.radiance" -> "hdr"; "image/x-exr" -> "exr"; else -> "jpg" }
                val target = File(directory, "${name}_${System.nanoTime()}.$actualExtension")
                require(partial!!.renameTo(target)) { "Image download failed" }
                partial = null
                val metadata = JSONObject().put("source", referer).put("download_url", url).put("resolved_url", next)
                    .put("width", bounds.outWidth).put("height", bounds.outHeight).put("bytes", count)
                // Persist provenance with the original; licenses remain on the linked source page.
                runCatching { File(target.path + ".json").writeText(metadata.toString()) }
                synchronized(this) {
                    originals.register(target)
                    if (closed || token != epoch.get()) originals.release(target)
                    else {
                        original = target
                        state = JSONObject().put("state", "ready")
                            .put("uri", Uri.fromFile(target).toString()).put("title", "$name.$actualExtension")
                            .put("width", bounds.outWidth).put("height", bounds.outHeight).put("bytes", count)
                            .put("source", referer).put("download_url", url)
                    }
                }
            } catch (_: InterruptedException) { }
            catch (error: Throwable) {
                if (!closed && token == epoch.get()) state = JSONObject().put("state", "error")
                    .put("error", error.message?.takeIf { it in setOf("Image too large", "Panorama storage is full",
                        "Choose an 8K or larger original", "Choose a supported image original") } ?: "Image download failed")
            } finally { partial?.delete(); active?.disconnect(); if (token == epoch.get()) connection = null }
        }
    }
    @Synchronized fun close() { closed = true; cancel(); worker.shutdownNow() }
}
