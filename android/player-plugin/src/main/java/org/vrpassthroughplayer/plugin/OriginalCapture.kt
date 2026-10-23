package org.vrpassthroughplayer.plugin

import android.content.ContentValues
import android.content.Context
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Environment
import android.os.Build
import android.os.ParcelFileDescriptor
import android.os.StatFs
import android.provider.MediaStore
import org.json.JSONObject
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

internal object OriginalClipNative {
    private val loaded = try { System.loadLibrary("quest_mpv"); version() == 1 } catch (_: UnsatisfiedLinkError) { false }
    @JvmStatic private external fun version(): Int
    fun supported() = loaded
    @JvmStatic external fun export(id: Int, source: String, output: String, startUs: Long, endUs: Long,
                                   audioIndex: Int, extraAudio: String, caFile: String, mode: String): String
    @JvmStatic external fun cancel(id: Int)
    @JvmStatic external fun prepare(id: Int)
    @JvmStatic external fun forget(id: Int)
}

/** One independent source lease per request; no access to the decoder or headset eye buffers. */
internal class OriginalCapture(private val context: () -> Context?, private val resolve: (String) -> String,
                               private val release: (String) -> Unit,
                               private val sidecars: (String, String) -> List<SidecarAudio.Track>,
                               owner: (Int)->Long,flushAudio: (Int)->Unit,
                               private val retainPip: (Int)->File?, private val releasePip: (Int)->Unit) {
    private val screenshots = Executors.newSingleThreadExecutor { Thread(it, "OriginalScreenshot") }
    private val clips = Executors.newSingleThreadExecutor { Thread(it, "OriginalClip") }
    private val pictureBusy = AtomicBoolean()
    private val clipBusy = AtomicBoolean()
    private val next = AtomicInteger()
    private val results = ConcurrentHashMap<Int, String>()
    private val active = ConcurrentHashMap<Int, String>()
    @Volatile private var closed = false
    private val live=LiveClipCapture(context,owner,flushAudio){id,json->results[id]=json}
    fun supported() = !closed && OriginalClipNative.supported() && LiveCaptureNative.available()
    fun clock(id: Int,position: Long,playing: Boolean)=live.clock(id,position,playing)
    fun stop(id: Int,end: Long)=live.stop(id,end)
    fun status(id: Int) = results[id] ?: "{}"
    fun uses(uri: String) = active.values.any { it == uri || it.startsWith(uri.trimEnd('/') + "/") }
    fun request(json: String): Int {
        val request = runCatching { JSONObject(json) }.getOrNull() ?: return 0
        val liveMovie=request.optString("kind")=="live_clip"
        val movie = liveMovie || request.optString("kind") == "clip"
        val busy = if (movie) clipBusy else pictureBusy
        val source = request.optString("uri")
        if (!supported() || source.isEmpty() || !busy.compareAndSet(false, true)) return 0
        val id = next.incrementAndGet()
        if(liveMovie) {
            active[id]=source;results[id]="{\"state\":\"preparing\",\"kind\":\"clip\"}"
            live.prepare(id,request)
            clips.execute {try{live.run(id)}finally{active.remove(id);clipBusy.set(false)
                results.keys.sorted().dropLast(8).forEach{if(!active.containsKey(it))results.remove(it)}}}
            return id
        }
        if (movie) OriginalClipNative.prepare(id)
        // Pin displayed previews before returning to Godot: closing/replacing a window cannot
        // delete the files under an accepted screenshot. This performs no image/source I/O.
        var composition: PipScreenshot? = null
        var invalidComposition = false
        if (!movie && request.has("pip")) {
            try { composition = PipScreenshot(request.getJSONObject("pip"), retainPip, releasePip) }
            catch (_: Exception) { invalidComposition = true }
        }
        active[id] = source
        results[id] = JSONObject().put("state", "saving").put("kind", if (movie) "clip" else "screenshot").toString()
        (if (movie) clips else screenshots).execute {
            var lease = ""
            var descriptor: ParcelFileDescriptor? = null
            var pending: Uri? = null
            var app: Context? = null
            var temporary: File? = null
            var extraFiles = emptyList<SidecarAudio.Track>()
            try {
                android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_BACKGROUND)
                check(!closed)
                check(!invalidComposition) { "Picture in picture capture unavailable" }
                app = context() ?: error("Capture unavailable")
                val mode = CaptureFormat.clean(request.getJSONObject("mode"))
                require(StatFs(app.filesDir.path).availableBytes > 64L * 1024 * 1024) { "Not enough storage" }
                // Resolve afresh: playback may close before this export finishes.
                val resolved = resolve(source)
                if (resolved.startsWith("http://127.0.0.1:")) lease = resolved
                val uri = Uri.parse(resolved)
                val path = when (uri.scheme) {
                    "file" -> uri.path ?: error("Capture source unavailable")
                    "content" -> {
                        descriptor = app.contentResolver.openFileDescriptor(uri, "r") ?: error("Capture source unavailable")
                        "/proc/self/fd/${descriptor!!.fd}"
                    }
                    "http", "https" -> resolved
                    else -> error("This source cannot export clips")
                }
                var extraAudio = ""
                if (movie && request.optString("audio_title").isNotEmpty()) {
                    extraFiles = sidecars(source, resolved)
                    val selected = extraFiles.filter { it.title == request.getString("audio_title") }.singleOrNull()
                        ?: error("Audio track unavailable for export")
                    val location = selected.location
                    extraAudio = when {
                        location.startsWith("fd://") -> "/proc/self/fd/" + location.removePrefix("fd://")
                        location.startsWith("file://") -> Uri.parse(location).path ?: error("Audio track unavailable for export")
                        else -> location
                    }
                }
                val directory = (if (movie) Environment.DIRECTORY_MOVIES else Environment.DIRECTORY_PICTURES) + "/Thru3D"
                val base = (if (movie) "recording_" else "screenshot_") + SimpleDateFormat("yyyyMMdd_HHmmss_SSS", Locale.ROOT).format(Date())
                val values = ContentValues().apply {
                    put(MediaStore.MediaColumns.DISPLAY_NAME, "$base.${if (movie) "mp4" else "png"}")
                    put(MediaStore.MediaColumns.MIME_TYPE, if (movie) "video/mp4" else "image/png")
                    put(MediaStore.MediaColumns.RELATIVE_PATH, directory)
                    put(MediaStore.MediaColumns.IS_PENDING, 1)
                }
                val resolver = app.contentResolver
                pending = resolver.insert(if (movie) MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
                    else MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY), values) ?: error("Capture save failed")
                val report = if (movie) {
                    resolver.openFileDescriptor(pending, "rw")!!.use { output ->
                        check(!closed)
                        JSONObject(OriginalClipNative.export(id, path, "/proc/self/fd/${output.fd}", request.getLong("start_us"),
                            request.getLong("end_us"), request.optInt("audio_index", -1), extraAudio, MpvTlsTrust.prepare(app), mode.toString()))
                    }.also { check(it.optString("state") == "saved") { it.optString("error", "Clip export failed") } }
                } else {
                    val retriever = MediaMetadataRetriever()
                    var bitmap: Bitmap? = null
                    try {
                        if (uri.scheme == "content") retriever.setDataSource(descriptor!!.fileDescriptor)
                        else if (uri.scheme in listOf("http", "https")) retriever.setDataSource(path, emptyMap())
                        else retriever.setDataSource(path)
                        check(!closed)
                        val params = MediaMetadataRetriever.BitmapParams().apply { preferredConfig = Bitmap.Config.ARGB_8888 }
                        val width = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: 0
                        val height = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: 0
                        check(width > 0 && height > 0 && width.toLong() * height <= 40L * 1024 * 1024) { "Full resolution capture unavailable" }
                        bitmap = (if (Build.VERSION.SDK_INT >= 30) retriever.getFrameAtTime(request.getLong("position_us"), MediaMetadataRetriever.OPTION_CLOSEST, params)
                            else retriever.getFrameAtTime(request.getLong("position_us"), MediaMetadataRetriever.OPTION_CLOSEST))
                            ?: error("Could not capture source frame")
                        check(width > 0 && height > 0 && bitmap.width.toLong() * bitmap.height == width.toLong() * height) { "Full resolution capture unavailable" }
                        temporary = File.createTempFile("source-frame-", ".png", app.cacheDir)
                        if (composition?.hasWindows() == true) {
                            composition!!.compose(bitmap, temporary!!, mode, java.util.function.BooleanSupplier { closed })
                        } else temporary!!.outputStream().use { check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) }
                        check(!closed)
                        resolver.openOutputStream(pending, "w")!!.use { output -> temporary!!.inputStream().use { CaptureFormat.png(it, output, mode) } }
                        JSONObject().put("state", "saved").put("extension", "png").put("width", bitmap.width).put("height", bitmap.height)
                    } finally { bitmap?.recycle(); retriever.release() }
                }
                check(!closed)
                val extension = report.getString("extension")
                check(resolver.update(pending, ContentValues().apply {
                    put(MediaStore.MediaColumns.DISPLAY_NAME, "$base.$extension")
                    put(MediaStore.MediaColumns.MIME_TYPE, if (!movie) "image/png" else if (extension == "mp4") "video/mp4" else "video/x-matroska")
                    put(MediaStore.MediaColumns.IS_PENDING, 0)
                }, null, null) == 1) { "Capture save failed" }
                // Both URI and file browsing can reopen the result, independent of its timestamp-only name.
                report.put("uri", pending.toString()).put("name", "$base.$extension").put("directory", directory).put("kind", if (movie) "clip" else "screenshot")
                results[id] = report.toString(); pending = null
            } catch (failure: Throwable) {
                results[id] = JSONObject().put("state", "error").put("kind", if (movie) "clip" else "screenshot")
                    .put("error", when (failure) {
                        is OutOfMemoryError -> "Full resolution capture unavailable"
                        else -> failure.message?.takeIf { it in errors } ?: "Capture save failed"
                    }).toString()
            } finally {
                if (movie) OriginalClipNative.forget(id)
                pending?.let { runCatching { app?.contentResolver?.delete(it, null, null) } }
                temporary?.delete(); descriptor?.close()
                composition?.close()
                if (lease.isNotEmpty()) release(lease)
                extraFiles.forEach { track ->
                    runCatching { track.descriptor?.close() }
                    if (track.location.startsWith("http://127.0.0.1:")) runCatching { release(track.location) }
                }
                active.remove(id); busy.set(false)
                results.keys.sorted().dropLast(8).forEach { if (!active.containsKey(it)) results.remove(it) }
            }
        }
        return id
    }
    fun close() {
        closed = true
        live.close()
        active.keys.forEach { OriginalClipNative.cancel(it) }
        screenshots.shutdown(); clips.shutdown()
    }
    companion object {
        private val errors = setOf("Not enough storage", "This source cannot export clips", "Capture source unavailable", "Capture save failed",
            "Recording is empty", "Recording is too short", "Clip export failed", "Clip export cancelled", "Source interrupted during export",
            "Audio track unavailable for export", "Could not capture source frame", "Full resolution capture unavailable", "Lossless container unavailable",
            "Keyframe too far from recording start", "Clip timestamps unavailable", "Picture in picture capture unavailable")
    }
}
