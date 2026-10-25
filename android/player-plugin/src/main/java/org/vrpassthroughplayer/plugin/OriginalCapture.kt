package org.vrpassthroughplayer.plugin

import android.content.ContentValues
import android.content.ContentUris
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Matrix
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Environment
import android.os.Build
import android.os.ParcelFileDescriptor
import android.os.StatFs
import android.os.SystemClock
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
    @JvmStatic external fun progress(id: Int): Int
    @JvmStatic external fun cover(id: Int, source: String, caFile: String): ByteArray
    @JvmStatic external fun frame(id: Int, source: String, positionUs: Long, caFile: String): Bitmap?
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
    private val exports = ConcurrentHashMap<Int, ClipExportTask>()
    @Volatile private var closed = false
    private val live=LiveClipCapture(context,owner,flushAudio,retainPip,releasePip){id,json->results[id]=json}
    fun supported() = !closed && OriginalClipNative.supported() && LiveCaptureNative.available()
    fun clock(id: Int,position: Long,playing: Boolean)=live.clock(id,position,playing)
    fun pip(id: Int,position: Long,recipe: String)=live.pip(id,position,recipe)
    fun stop(id: Int,end: Long)=live.stop(id,end)
    fun cancel(id: Int): Boolean = exports[id]?.cancel { OriginalClipNative.cancel(id) } ?: live.cancel(id)
    fun status(id: Int): String {
        val result = results[id] ?: return "{}"
        val state = JSONObject(result)
        if (state.optString("state") == "saving" && state.optBoolean("range_clip"))
            state.put("progress", OriginalClipNative.progress(id).coerceIn(0, 99))
        else if (state.optString("state") in listOf("preparing", "recording", "saving")) {
            val progress=live.progress(id)
            if(progress>=0)state.put("state","saving").put("progress",progress)
        }
        return state.toString()
    }
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
        OriginalClipNative.prepare(id)
        val task = if (movie) ClipExportTask().also { exports[id] = it } else null
        // Pin displayed previews before returning to Godot: closing/replacing a window cannot
        // delete the files under an accepted screenshot. This performs no image/source I/O.
        var composition: PipScreenshot? = null
        var invalidComposition = false
        if (!movie && request.has("pip") && request.optJSONObject("mode")?.optInt("geometry", -1) != 0) {
            try { composition = PipScreenshot(request.getJSONObject("pip"), retainPip, releasePip) }
            catch (_: Exception) { invalidComposition = true }
        }
        active[id] = source
        results[id] = JSONObject().put("state", "saving").put("kind", if (movie) "clip" else "screenshot")
            .put("range_clip", movie).put("progress", if (movie) 0 else -1).toString()
        val requestedAt = SystemClock.elapsedRealtime()
        (if (movie) clips else screenshots).execute {
            val startedAt = SystemClock.elapsedRealtime()
            val timings = JSONObject().put("queue_ms", startedAt - requestedAt)
            var lease = ""
            var descriptor: ParcelFileDescriptor? = null
            var pending: Uri? = null
            var app: Context? = null
            var temporary: File? = null
            var extraFiles = emptyList<SidecarAudio.Track>()
            var terminal: String? = null
            try {
                // A requested still is a short foreground operation. Background scheduling can
                // stretch its decoder/encoder work several seconds during 8K playback.
                android.os.Process.setThreadPriority(if (movie) android.os.Process.THREAD_PRIORITY_BACKGROUND
                    else android.os.Process.THREAD_PRIORITY_DEFAULT)
                check(!closed)
                task?.checkActive()
                check(!invalidComposition) { "Picture in picture capture unavailable" }
                app = context() ?: error("Capture unavailable")
                val mode = CaptureFormat.clean(request.getJSONObject("mode"), allowFlat = true)
                val directory = (if (movie) Environment.DIRECTORY_MOVIES else Environment.DIRECTORY_PICTURES) + "/Thru3D"
                val namedRange = movie && request.optString("source_name").isNotBlank()
                val base = if (namedRange) ClipExportName.base(request.getString("source_name"), request.getLong("start_us"), request.getLong("end_us"))
                    else (if (movie) "recording_" else "screenshot_") + SimpleDateFormat("yyyyMMdd_HHmmss_SSS", Locale.ROOT).format(Date())
                if (namedRange) {
                    existingClip(app, directory, base)?.let { existing ->
                        task!!.commit {
                            terminal = JSONObject().put("state", "exists").put("kind", "clip").put("progress", 100)
                                .put("directory", directory).put("name", existing.name).put("uri", existing.uri).toString()
                        }
                        return@execute
                    }
                }
                require(StatFs(app.filesDir.path).availableBytes > 64L * 1024 * 1024) { "Not enough storage" }
                // Resolve afresh: playback may close before this export finishes.
                val resolved = resolve(source)
                if (resolved.startsWith("http://127.0.0.1:")) lease = resolved
                task?.checkActive()
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
                timings.put("resolve_ms", SystemClock.elapsedRealtime() - startedAt)
                task?.checkActive()
                val values = ContentValues().apply {
                    put(MediaStore.MediaColumns.DISPLAY_NAME, "$base.${if (movie) "mp4" else "jpg"}")
                    put(MediaStore.MediaColumns.MIME_TYPE, if (movie) "video/mp4" else "image/jpeg")
                    put(MediaStore.MediaColumns.RELATIVE_PATH, directory)
                    put(MediaStore.MediaColumns.IS_PENDING, 1)
                }
                val resolver = app.contentResolver
                pending = resolver.insert(if (movie) MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
                    else MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY), values) ?: error("Capture save failed")
                if (namedRange) assertClipName(app, pending, "$base.mp4")
                val report = if (movie) {
                    resolver.openFileDescriptor(pending, "rw")!!.use { output ->
                        check(!closed)
                        JSONObject(OriginalClipNative.export(id, path, "/proc/self/fd/${output.fd}", request.getLong("start_us"),
                            request.getLong("end_us"), request.optInt("audio_index", -1), extraAudio, MpvTlsTrust.prepare(app), mode.toString()))
                    }.also { check(it.optString("state") == "saved") { it.optString("error", "Clip export failed") } }
                } else {
                    val retriever = MediaMetadataRetriever()
                    var retrieverOpen = true
                    var bitmap: Bitmap? = null
                    try {
                        val setupAt = SystemClock.elapsedRealtime()
                        if (uri.scheme == "content") retriever.setDataSource(descriptor!!.fileDescriptor)
                        else if (uri.scheme in listOf("http", "https")) retriever.setDataSource(path, emptyMap())
                        else retriever.setDataSource(path)
                        check(!closed)
                        val params = MediaMetadataRetriever.BitmapParams().apply { preferredConfig = Bitmap.Config.ARGB_8888 }
                        val width = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: 0
                        val height = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: 0
                        check(width > 0 && height > 0 && width.toLong() * height <= 40L * 1024 * 1024) { "Full resolution capture unavailable" }
                        val position = request.getLong("position_us")
                        timings.put("source_setup_ms", SystemClock.elapsedRealtime() - setupAt)
                        val decodeAt = SystemClock.elapsedRealtime()
                        fun systemFrame(option: Int): Bitmap? = if (Build.VERSION.SDK_INT >= 30)
                            retriever.getFrameAtTime(position, option, params) else retriever.getFrameAtTime(position, option)
                        // Playing: fast independent sync frame. User-paused: the displayed PTS first.
                        val exact = request.optBoolean("exact_frame", false)
                        var selection = if (exact) "closest_frame" else "keyframe"
                        bitmap = systemFrame(if (exact) MediaMetadataRetriever.OPTION_CLOSEST else MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                        if (bitmap == null && exact && !closed) {
                            bitmap = systemFrame(MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                            selection = "keyframe"
                        }
                        val software = bitmap == null
                        if (software) {
                            selection = "closest_frame"
                            val rotation = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0
                            // Release the system decoder before allocating the independent fallback.
                            retriever.release()
                            retrieverOpen = false
                            check(!closed)
                            bitmap = OriginalClipNative.frame(id, path, request.getLong("position_us"), MpvTlsTrust.prepare(app))
                                ?: error("Could not capture source frame")
                            if (rotation % 360 != 0) {
                                val original = bitmap
                                bitmap = Bitmap.createBitmap(original, 0, 0, original.width, original.height,
                                    Matrix().apply { postRotate(rotation.toFloat()) }, false)
                                if (bitmap !== original) original.recycle()
                            }
                        }
                        val captured = bitmap ?: error("Could not capture source frame")
                        check(captured.width.toLong() * captured.height == width.toLong() * height) { "Full resolution capture unavailable" }
                        timings.put("frame_ms", SystemClock.elapsedRealtime() - decodeAt)
                        val encodeAt = SystemClock.elapsedRealtime()
                        if (composition?.hasWindows() == true) {
                            temporary = File.createTempFile("source-frame-", ".jpg", app.cacheDir)
                            composition!!.compose(captured, temporary!!, mode, java.util.function.BooleanSupplier { closed })
                            timings.put("compose_encode_ms", SystemClock.elapsedRealtime() - encodeAt)
                        }
                        check(!closed)
                        val bytes = resolver.openOutputStream(pending, "w")!!.buffered(65536).use { output ->
                            CaptureFormat.jpeg(output, mode) { encoded ->
                                val composed = temporary
                                if (composed != null) composed.inputStream().use { it.copyTo(encoded, 65536) }
                                else check(captured.compress(Bitmap.CompressFormat.JPEG, 100, encoded))
                            }
                        }
                        timings.put("encode_write_ms", SystemClock.elapsedRealtime() - encodeAt)
                        check(!closed)
                        JSONObject().put("state", "saved").put("extension", "jpg").put("width", captured.width).put("height", captured.height)
                            .put("bytes", bytes).put("jpeg_quality", 100).put("timings_ms", timings)
                            .put("frame_decoder", if (software) "ffmpeg" else "android").put("frame_selection", selection)
                    } finally { bitmap?.recycle(); if (retrieverOpen) runCatching { retriever.release() } }
                }
                check(!closed)
                task?.checkActive()
                val extension = report.getString("extension")
                val publishAt = SystemClock.elapsedRealtime()
                val outputUri = checkNotNull(pending)
                val publish = {
                    check(!closed)
                    check(resolver.update(outputUri, ContentValues().apply {
                        put(MediaStore.MediaColumns.DISPLAY_NAME, "$base.$extension")
                        put(MediaStore.MediaColumns.MIME_TYPE, if (!movie) {
                            if (extension == "jpg") "image/jpeg" else "image/png"
                        } else if (extension == "mp4") "video/mp4" else "video/x-matroska")
                        put(MediaStore.MediaColumns.IS_PENDING, 0)
                    }, null, null) == 1) { "Capture save failed" }
                    if (namedRange) assertClipName(app, outputUri, "$base.$extension")
                    timings.put("publish_ms", SystemClock.elapsedRealtime() - publishAt)
                        .put("total_ms", SystemClock.elapsedRealtime() - requestedAt)
                    if (BuildConfig.DEBUG && !movie) {
                        val diagnostic = JSONObject()
                        for (key in listOf("width", "height", "bytes", "jpeg_quality", "frame_decoder", "frame_selection", "timings_ms"))
                            diagnostic.put(key, report.get(key))
                        android.util.Log.i("Thru3DCapture", diagnostic.toString())
                    }
                    // Both URI and local file browsing can reopen the published result.
                    report.put("uri", outputUri.toString()).put("name", "$base.$extension").put("directory", directory)
                        .put("kind", if (movie) "clip" else "screenshot").put("progress", 100)
                    terminal = report.toString(); pending = null
                }
                if (task != null) task.commit(publish) else publish()
            } catch (failure: Throwable) {
                terminal = JSONObject().put("state", "error").put("kind", if (movie) "clip" else "screenshot")
                    .put("error", when (failure) {
                        is OutOfMemoryError -> "Full resolution capture unavailable"
                        else -> failure.message?.takeIf { it in errors } ?: "Capture save failed"
                    }).toString()
            } finally {
                OriginalClipNative.forget(id)
                val cleanupFailed = pending?.let { runCatching { app?.contentResolver?.delete(it, null, null) }.isFailure } ?: false
                temporary?.delete(); runCatching { descriptor?.close() }
                runCatching { composition?.close() }
                if (lease.isNotEmpty()) runCatching { release(lease) }
                extraFiles.forEach { track ->
                    runCatching { track.descriptor?.close() }
                    if (track.location.startsWith("http://127.0.0.1:")) runCatching { release(track.location) }
                }
                val cancelled = task?.finish() == true
                exports.remove(id)
                active.remove(id); busy.set(false)
                results[id] = if (cleanupFailed) JSONObject().put("state", "error").put("error", "Capture save failed").toString()
                    else if (cancelled) JSONObject().put("state", "cancelled").put("kind", "clip").toString()
                    else terminal ?: JSONObject().put("state", "error").put("error", "Capture save failed").toString()
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
    private fun existingClip(app: Context, directory: String, base: String): ClipExportName.Existing? {
        val collection = MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        return ClipExportName.existing(File(Environment.getExternalStorageDirectory(), directory), base) { name ->
            app.contentResolver.query(collection, arrayOf(MediaStore.MediaColumns._ID, MediaStore.MediaColumns.IS_PENDING,
                MediaStore.MediaColumns.SIZE), "${MediaStore.MediaColumns.DISPLAY_NAME}=? AND ${MediaStore.MediaColumns.RELATIVE_PATH} IN (?,?)",
                arrayOf(name, directory, "$directory/"), null)?.use { cursor ->
                var found: ClipExportName.Existing? = null
                while (cursor.moveToNext()) {
                    check(cursor.getInt(1) == 0) { "Capture is busy" }
                    if (cursor.getLong(2) > 0) found = ClipExportName.Existing(name, ContentUris.withAppendedId(collection, cursor.getLong(0)).toString())
                }
                found
            }
        }
    }
    private fun assertClipName(app: Context, uri: Uri, expected: String) {
        // Do not publish an automatically suffixed duplicate if another writer won a race.
        val exact = app.contentResolver.query(uri, arrayOf(MediaStore.MediaColumns.DISPLAY_NAME), null, null, null)?.use {
            it.moveToFirst() && it.getString(0) == expected
        } ?: false
        check(exact) { "Capture save failed" }
    }
    companion object {
        private val errors = setOf("Not enough storage", "This source cannot export clips", "Capture source unavailable", "Capture save failed",
            "Recording is empty", "Recording is too short", "Clip export failed", "Clip export cancelled", "Source interrupted during export",
            "Audio track unavailable for export", "Could not capture source frame", "Full resolution capture unavailable", "Lossless container unavailable",
            "Keyframe too far from recording start", "Clip timestamps unavailable", "Picture in picture capture unavailable", "Capture is busy", "Invalid loop range")
    }
}
