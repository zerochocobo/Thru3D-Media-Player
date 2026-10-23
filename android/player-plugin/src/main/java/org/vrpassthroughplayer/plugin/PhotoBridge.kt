package org.vrpassthroughplayer.plugin

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.ExifInterface
import android.net.Uri
import org.json.JSONObject
import java.io.Closeable
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlin.math.roundToInt

/** Compressed photo transfer and bounded decoding run off the render thread. Only private cache
 * paths/metadata reach Godot. A newer selection cancels old transfer and rejects late depth. */
internal class PhotoBridge(
    private val context: () -> Context?,
    private val resolve: (String) -> String,
    private val releaseStream: (String) -> Unit,
    private val cacheName: String = "photos",
    private val preload: Boolean = false,
    private val postDepth: ((Runnable, Boolean) -> Unit)? = null,
    private val resolveRequest: ((Int, String) -> String)? = null,
    private val emit: (String, Int, String) -> Unit,
) : Closeable {
    private val current = AtomicInteger(0)
    private val files = ConcurrentHashMap<Int, PhotoSource>()
    private class DepthJob(val id: Int, val source: PhotoSource, @Volatile var strength: Float, val stereo: Boolean, val sceneToken: Int,
                           @Volatile var owner: PhotoBridge, @Volatile var background: Boolean) {
        @Volatile var cancelled = false
    }
    private val depthJobs = ConcurrentHashMap<Int, DepthJob>()
    private class PortraitJob(val id: Int, val token: Int, val source: PhotoSource, val strength: Float) {
        @Volatile var cancelled = false
    }
    private val portraitJobs = ConcurrentHashMap<Int, PortraitJob>()
    private val worker = ThreadPoolExecutor(1, 1, 0, TimeUnit.MILLISECONDS, ArrayBlockingQueue(1),
        { Thread(it, if (preload) "QuestPhotoPreload" else "QuestPhotoIO") }, ThreadPoolExecutor.DiscardOldestPolicy())
    @Volatile private var connection: HttpURLConnection? = null
    @Volatile private var closed = false
    private var cachePrepared = false // IO worker only; discard leftovers from a previous process.
    private class Loading(val id: Int, @Volatile var remote: Boolean) {
        val started = System.nanoTime()
        val meter = TransferMeter()
        @Volatile var phase = "connecting"
    }
    @Volatile private var loading: Loading? = null
    fun loadingStatus(id: Int): String {
        val state = loading?.takeIf { it.id == id && current.get() == id && !closed } ?: return ""
        val progress = state.meter.snapshot()
        return JSONObject().put("remote", state.remote).put("phase", state.phase)
            .put("elapsed_ms", (System.nanoTime() - state.started) / 1_000_000).apply {
                if (state.remote && state.phase != "connecting") put("bytes", progress.bytes).put("bytes_per_second", progress.bytesPerSecond)
            }.toString()
    }

    fun open(id: Int, uri: String): Boolean {
        if (closed) return false
        synchronized(PhotoCache.lock) { current.set(id) }
        val state = Loading(id, Uri.parse(uri).scheme !in setOf("file", "content"))
        loading = state
        cancelDepth(); connection?.disconnect()
        worker.execute {
            if (current.get() != id || closed) return@execute
            var directory: File? = null
            var resolved = ""
            var published = false
            try {
                val app = context() ?: error("PHOTO_UNAVAILABLE")
                if (!cachePrepared) {
                    File(app.cacheDir, cacheName).listFiles()?.forEach { it.deleteRecursively() }
                    cachePrepared = true
                }
                directory = File(app.cacheDir, "$cacheName/$id").apply { mkdirs() }
                val source = File(directory, "source")
                checkCurrent(id)
                resolved = resolveRequest?.invoke(id, uri) ?: resolve(uri)
                checkCurrent(id)
                val location = Uri.parse(resolved)
                state.remote = state.remote || location.scheme in setOf("http", "https")
                // The online original already lives in our private files directory. A hard link
                // gives the photo cache its own lifetime without copying another GB of pixels.
                val linked = if (location.scheme == "file") runCatching {
                    val original = File(location.path ?: "").canonicalFile
                    val online = File(app.filesDir, "online-panoramas").canonicalFile
                    if (original.parentFile == online && original.isFile && original.length() <= MAX_BYTES) {
                        android.system.Os.link(original.path, source.path); true
                    } else false
                }.getOrDefault(false) else false
                if (!linked) {
                val stream: InputStream = when (location.scheme) {
                    "file" -> File(location.path ?: error("PHOTO_UNAVAILABLE")).inputStream()
                    "content" -> app.contentResolver.openInputStream(location) ?: error("PHOTO_UNAVAILABLE")
                    "http", "https" -> {
                        val http = URL(resolved).openConnection() as HttpURLConnection
                        connection = http; http.connectTimeout = 15000; http.readTimeout = 20000
                        require(http.responseCode in 200..299) { "PHOTO_UNAVAILABLE" }
                        require(http.contentLengthLong <= MAX_BYTES) { "PHOTO_TOO_LARGE" }
                        require(http.contentLengthLong <= directory.usableSpace-64L*1024*1024) { "PHOTO_TOO_LARGE" }
                        http.inputStream
                    }
                    else -> error("PHOTO_UNAVAILABLE")
                }
                stream.use { input -> source.outputStream().use { output ->
                    state.phase = "reading"
                    val bytes = ByteArray(65536); var total = 0L
                    val header = ByteArrayOutputStream()
                    var metadataSent = false
                    while (true) {
                        checkCurrent(id)
                        val count = input.read(bytes); if (count < 0) break
                        total += count; require(total <= MAX_BYTES) { "PHOTO_TOO_LARGE" }
                        if(total/(1024*1024) != (total-count)/(1024*1024)) require(directory.usableSpace>64L*1024*1024) { "PHOTO_TOO_LARGE" }
                        if (state.remote) state.meter.add(count)
                        output.write(bytes, 0, count)
                        if (!metadataSent && header.size() < PhotoHeader.MAX_BYTES) {
                            header.write(bytes, 0, minOf(count, PhotoHeader.MAX_BYTES - header.size()))
                            PhotoHeader.read(header.toByteArray())?.let { dimensions ->
                                checkCurrent(id)
                                emit("photo_ready", id, JSONObject().put("state", "metadata")
                                    .put("width", dimensions.width).put("height", dimensions.height)
                                    .put("orientation", dimensions.orientation).put("native_stereo", dimensions.nativeStereo).toString())
                                metadataSent = true
                                header.reset()
                            }
                        }
                    }
                } }
                }
                state.phase = "preparing"
                if (PhotoBitmap.isNative(source)) {
                    val ready = NativePhoto.prepare(source, directory, { checkCurrent(id) },
                        { metadata -> emit("photo_ready", id, metadata.toString()) })
                    checkCurrent(id); files[id] = PhotoSource(source); published = true
                    ready.put("cache_bytes", directory.listFiles()?.sumOf { it.length() } ?: source.length())
                    emit("photo_ready", id, ready.toString()); return@execute
                }
                val heif = HeifPhotoInfo.read(source)
                if (heif != null) {
                    val ready = HeifPhotoDecoder.prepare(source, directory, heif, { checkCurrent(id) },
                        { metadata -> emit("photo_ready", id, metadata.toString()) })
                    checkCurrent(id)
                    files[id] = PhotoSource(source, heif.stereo)
                    published = true
                    ready.put("cache_bytes", directory.listFiles()?.sumOf { it.length() } ?: source.length())
                    emit("photo_ready", id, ready.toString())
                    return@execute
                }
                val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                BitmapFactory.decodeFile(source.path, bounds)
                require(bounds.outWidth in 1..65535 && bounds.outHeight in 1..65535) { "PHOTO_DECODE_FAILED" }
                require(bounds.outMimeType in setOf("image/jpeg", "image/png", "image/webp")) { "PHOTO_FORMAT_UNSUPPORTED" }
                val metadata = JSONObject().put("state", "ready").put("width", bounds.outWidth).put("height", bounds.outHeight)
                val orientation = runCatching {
                    PhotoHeader.normalizedOrientation(ExifInterface(source.path).getAttributeInt(ExifInterface.TAG_ORIENTATION, 1))
                }.getOrDefault(1)
                metadata.put("orientation", orientation)
                source.inputStream().use { CaptureFormat.readPng(it) }?.let { metadata.put("capture_mode", it) }
                // GPano is a positive hint only; ordinary 2:1 photos stay flat.
                val header = source.inputStream().use { input ->
                    val bytes = ByteArray(minOf(source.length(), 1024L * 1024).toInt())
                    var count = 0
                    while (count < bytes.size) {
                        val read = input.read(bytes, count, bytes.size - count)
                        if (read < 0) break
                        count += read
                    }
                    String(bytes, 0, count, Charsets.ISO_8859_1)
                }
                val panorama = header.contains("GPano:ProjectionType=\"equirectangular\"") || header.contains("<GPano:ProjectionType>equirectangular</GPano:ProjectionType>")
                metadata.put("panorama", panorama)
                fun field(name: String): Int = Regex("GPano:$name(?:=\"|>)([0-9]+)").find(header)?.groupValues?.get(1)?.toIntOrNull() ?: 0
                for (key in listOf("FullPanoWidthPixels", "FullPanoHeightPixels", "CroppedAreaImageWidthPixels", "CroppedAreaImageHeightPixels", "CroppedAreaLeftPixels", "CroppedAreaTopPixels")) metadata.put(key, field(key))
                // Correct late EXIF/GPano hints before a large preview is decoded and encoded.
                checkCurrent(id)
                emit("photo_ready", id, JSONObject(metadata.toString()).put("state", "metadata").toString())
                val regionSource = orientation == 1 && bounds.outWidth > 8192 && bounds.outWidth == 2 * bounds.outHeight
                // An inexpensive full-sphere fallback remains visible during original-pixel region loading.
                // Regions are activated only by an explicit full-sphere mode, never by aspect ratio alone.
                val previewEdge = 8192
                if (regionSource) metadata.put("region_source", source.path)
                var sample = 1
                while (bounds.outWidth / sample > previewEdge || bounds.outHeight / sample > previewEdge ||
                    bounds.outWidth.toLong() / sample * (bounds.outHeight / sample) > MAX_PIXELS) sample *= 2
                var output = source
                if (sample > 1) {
                    val bitmap = BitmapFactory.decodeFile(source.path, BitmapFactory.Options().apply { inSampleSize = sample }) ?: error("PHOTO_DECODE_FAILED")
                    try {
                        output = File(directory, "preview.png")
                        output.outputStream().use { require(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) }
                    } finally { bitmap.recycle() }
                }
                if (preload) {
                    var thumbSample = 1
                    while (maxOf(bounds.outWidth, bounds.outHeight) / thumbSample > 768) thumbSample *= 2
                    val bitmap = BitmapFactory.decodeFile(source.path, BitmapFactory.Options().apply { inSampleSize = thumbSample })
                    if (bitmap != null) {
                        val ratio = 384.0 / maxOf(bitmap.width, bitmap.height)
                        var small = bitmap
                        try {
                            small = Bitmap.createScaledBitmap(bitmap, maxOf(1, (bitmap.width * ratio).roundToInt()),
                                maxOf(1, (bitmap.height * ratio).roundToInt()), true)
                            val thumbnail = File(directory, "thumbnail.jpg")
                            thumbnail.outputStream().use { if (small.compress(Bitmap.CompressFormat.JPEG, 85, it)) metadata.put("thumbnail_path", thumbnail.path) }
                        } finally { if (small !== bitmap) small.recycle(); bitmap.recycle() }
                    }
                }
                checkCurrent(id)
                files[id] = PhotoSource(source)
                published = true
                metadata.put("path", output.path).put("sample", sample)
                    .put("cache_bytes",directory.listFiles()?.sumOf { it.length() } ?: source.length())
                emit("photo_ready", id, metadata.toString())
            } catch (_: InterruptedException) { }
            catch (error: Throwable) {
                // Never log the original URI, resolved credentials, or provider exception text.
                if (!closed && current.get() == id) android.util.Log.w("QuestPhoto",
                    "request=$id preload=$preload failure=${error.javaClass.simpleName}")
                if (!closed && current.get() == id) emit("photo_ready", id, JSONObject().put("state", "error")
                    .put("error", if (uri.startsWith("comic://") && error is Exception) ArchiveBridge.safeError(error)
                        else if (error.message == "PHOTO_TOO_LARGE") "PHOTO_TOO_LARGE" else "PHOTO_DECODE_FAILED").toString())
            } finally {
                connection?.disconnect(); connection = null
                if (uri.startsWith("smb://") || uri.startsWith("cloud://") || uri.startsWith("usb://")) releaseStream(resolved)
                // A published preload may already have been adopted by the foreground bridge.
                if (!published) directory?.deleteRecursively()
            }
        }
        return true
    }

    fun cancel(id: Int) {
        if (current.compareAndSet(id, 0)) connection?.disconnect()
        release(id)
    }
    fun release(id: Int) = synchronized(PhotoCache.lock) {
        depthJobs.remove(id)?.cancelled = true
        portraitJobs.entries.filter { it.value.id == id }.forEach { it.value.cancelled = true; portraitJobs.remove(it.key) }
        files.remove(id)?.release()
    }
    fun cancelDepth() = synchronized(PhotoCache.lock) {
        depthJobs.values.forEach { it.cancelled = true }
        depthJobs.clear()
    }
    fun cancelBackgroundDepth() = synchronized(PhotoCache.lock) {
        depthJobs.entries.filter { it.value.background }.forEach { it.value.cancelled = true; depthJobs.remove(it.key) }
    }
    fun updateDepthStrength(strength: Float) = synchronized(PhotoCache.lock) {
        if (strength.isFinite() && strength in 0f..2f)
            depthJobs.values.filter { it.stereo && !it.cancelled }.forEach { it.strength = strength }
    }
    /** Transfer both the source lease and unfinished work; its final signal follows the owner. */
    fun promoteTo(id: Int, target: PhotoBridge): Boolean = synchronized(PhotoCache.lock) {
        if (target.closed || files[id]?.file?.isFile != true) return@synchronized false
        target.cancelDepth()
        val source = files.remove(id) ?: return@synchronized false
        target.files[id] = source
        target.current.set(id)
        target.connection?.disconnect()
        depthJobs.remove(id)?.let { job -> job.owner = target; job.background = false; target.depthJobs[id] = job }
        true
    }
    // Includes a transfer not yet published, and files promoted from the preload bridge.
    fun cacheDirectories(): Set<File> = synchronized(PhotoCache.lock) {
        val active = files.values.mapNotNull { it.file.parentFile }.toMutableSet()
        // A cancelled worker still owns its input until its finally block runs.
        active.addAll(inFlightSources.values.mapNotNull { it.file.parentFile })
        active.addAll(portraitSources.values.mapNotNull { it.file.parentFile })
        val id = current.get()
        if (id != 0) context()?.let { active.add(File(it.cacheDir, "$cacheName/$id")) }
        active
    }
    fun activate(id: Int): Boolean {
        if (closed || files[id]?.file?.isFile != true) return false
        synchronized(PhotoCache.lock) {
            depthJobs.entries.filter { it.key != id }.forEach { it.value.cancelled = true; depthJobs.remove(it.key) }
            depthJobs[id]?.background = false
            current.set(id)
        }
        connection?.disconnect()
        return true
    }
    fun adopt(id: Int, file: File, nativeStereo: Boolean = false): Boolean {
        if (closed || !file.isFile) return false
        files[id] = PhotoSource(file, nativeStereo)
        return activate(id)
    }
    private fun checkCurrent(id: Int) { if (closed || current.get() != id) throw InterruptedException() }

    fun cancelSceneDepth(id: Int, token: Int) = synchronized(PhotoCache.lock) {
        depthJobs[id]?.takeIf { it.sceneToken == token && token > 0 }?.cancelled = true
    }

    /** One inference per photo on the shared model thread, using the independent photo model.
     * Color stays at source display resolution; only content contributes to depth normalization. */
    fun depth(id: Int, strength: Float = 1f, stereo: Boolean = false, background: Boolean = preload, sceneToken: Int = 0): Boolean {
        if (!strength.isFinite() || strength !in 0f..2f) return false
        val job = synchronized(PhotoCache.lock) {
            if (closed) return false
            val source = files[id] ?: return false
            if (source.nativeStereo && sceneToken == 0) return false
            val existing = depthJobs[id]
            if (existing != null && !existing.cancelled && existing.stereo == stereo && existing.sceneToken == sceneToken) {
                existing.strength = strength
                existing.background = background
                return true
            }
            depthJobs.remove(id)?.cancelled = true
            DepthJob(id, source.retain(), strength, stereo, sceneToken, this, background).also {
                depthJobs[id] = it
                inFlightSources[it] = source
            }
        }
        val source = job.source.file
        fun checkDepth() { if (job.cancelled || job.owner.closed) throw InterruptedException() }
        // A new foreground selection passes cancelled background jobs still waiting in the queue.
        val work = Runnable {
            val started = System.nanoTime()
            try {
                checkDepth()
                val app = context() ?: error("PHOTO_UNAVAILABLE")
                val w = PhotoDepthInput.WIDTH; val h = PhotoDepthInput.HEIGHT
                val near = ByteBuffer.allocateDirect(w * h * 4).order(ByteOrder.LITTLE_ENDIAN)
                val target = File(source.parentFile, "depth.bin")
                val metadata = File(source.parentFile, "depth.json")
                val cached = if (target.length() == w.toLong()*h*4 && metadata.isFile)
                    runCatching { JSONObject(metadata.readText()).takeIf { it.optString("photo_cache") == "da2-518-stretch-v2" } }.getOrNull() else null
                val result: JSONObject
                if (cached != null) {
                    near.put(target.readBytes()); near.rewind()
                    result = cached.put("depth_cached",true).put("model_reused",false)
                } else {
                    stage(id,"input")
                    val inputStarted = System.nanoTime()
                    val input = PhotoDepthInput.prepare(source, selectLeftEye = job.source.nativeStereo && job.sceneToken > 0)
                    val inputMs = (System.nanoTime() - inputStarted) / 1_000_000.0
                    val content = input.content
                    checkDepth()
                    stage(id,"waiting_model")
                    val modelStarted = System.nanoTime()
                    result = PhotoDepthRuntime.run(app,::checkDepth) { handle, reused ->
                        checkDepth()
                        val runtime = JSONObject(DepthNative.describe(handle)).put("session_reused", reused)
                        stage(id,"inference")
                        JSONObject(DepthNative.processPhoto(handle,input.rgb,near,content.x,content.y,content.width,content.height))
                            .put("runtime",runtime).put("model_reused",reused).put("depth_cached",false)
                    }
                    result.put("input_ms",inputMs).put("depth_total_ms",(System.nanoTime()-modelStarted)/1_000_000.0)
                    require(result.optString("state") == "ready")
                    checkDepth()
                    near.rewind(); val bytes = ByteArray(near.remaining()); near.get(bytes); near.rewind()
                    target.writeBytes(bytes)
                    result.put("path",target.path).put("width",w).put("height",h).put("photo_cache","da2-518-stretch-v2")
                        .put("rect",org.json.JSONArray(listOf(content.x.toDouble()/w,content.y.toDouble()/h,content.width.toDouble()/w,content.height.toDouble()/h)))
                    metadata.writeText(result.toString())
                }
                checkDepth()
                if (stereo) {
                    stage(id,"stereo")
                    val stereoStarted = System.nanoTime()
                    val rect = result.getJSONArray("rect")
                    val pair = PhotoStereo.prepare(source,near,FloatArray(4) { rect.getDouble(it).toFloat() },job.strength,id)
                    pair.keys().forEach { key -> result.put(key,pair.get(key)) }
                    result.put("stereo_total_ms",(System.nanoTime()-stereoStarted)/1_000_000.0)
                }
                result.put("total_ms",(System.nanoTime()-started)/1_000_000.0)
                    .put("cache_bytes",source.parentFile?.listFiles()?.sumOf { it.length() } ?: 0L)
                synchronized(PhotoCache.lock) {
                    checkDepth()
                    // Once a result is committed, a strength retry must enqueue fresh pair work.
                    job.owner.depthJobs.remove(id,job)
                    job.owner.stage(id,"ready")
                    android.util.Log.i("QuestPhotoDepth", "request=$id cached=${cached != null} reused=${result.optBoolean("model_reused")} total_ms=${result.optDouble("total_ms")} " +
                        "input_ms=${result.optDouble("input_ms")} depth_ms=${result.optDouble("depth_ms")} priority=${result.optJSONObject("runtime")?.optInt("priority",-1)} " +
                        "stereo_ms=${result.optDouble("stereo_total_ms")} stereo_gpu_us=${result.optLong("stereo_render_us")}")
                    if (job.sceneToken > 0) result.put("scene_token",job.sceneToken)
                    job.owner.emit(if (job.sceneToken > 0) "photo_scene_depth" else if (job.background) "photo_preload_depth" else "photo_depth",id,result.toString())
                }
            } catch (_: InterruptedException) { }
            catch (error: Throwable) {
                synchronized(PhotoCache.lock) { if (!job.cancelled && !job.owner.closed) {
                    job.owner.depthJobs.remove(id,job)
                    job.owner.stage(id,"failed")
                    android.util.Log.w("QuestPhotoDepth", "Photo depth failed", error)
                    val failure = JSONObject().put("state","error").put("error","PHOTO_DEPTH_FAILED").put("scene_token",job.sceneToken)
                    job.owner.emit(if (job.sceneToken > 0) "photo_scene_depth" else if (job.background) "photo_preload_depth" else "photo_depth", id, failure.toString())
                } }
            }
            finally { synchronized(PhotoCache.lock) {
                job.owner.depthJobs.remove(id,job)
                inFlightSources.remove(job)
                job.source.release()
            } }
        }
        if (postDepth != null) postDepth.invoke(work,!background)
        else if (background) DepthWorker.handler.post(work) else DepthWorker.handler.postAtFrontOfQueue(work)
        return true
    }

    fun cancelPortrait(token: Int) = synchronized(PhotoCache.lock) {
        portraitJobs.remove(token)?.cancelled = true
    }

    /** Still matting never consumes gallery previews or shares recurrent state with video. */
    fun portrait(id: Int, token: Int, strength: Float): Boolean {
        if (token <= 0 || !strength.isFinite() || strength !in 0f..2f) return false
        val job = synchronized(PhotoCache.lock) {
            if (closed || preload || current.get() != id) return false
            val source = files[id] ?: return false
            if (source.nativeStereo) return false
            portraitJobs.values.forEach { it.cancelled = true }; portraitJobs.clear()
            PortraitJob(id, token, source.retain(), strength).also {
                portraitJobs[token] = it; portraitSources[it] = source
            }
        }
        fun checkJob() { if (closed || job.cancelled) throw InterruptedException() }
        // Preparing and inference stay on the production RVM worker, behind retired video work.
        RvmWorkers.prepare.post { RvmWorkers.video.post {
            val started = System.nanoTime()
            try {
                checkJob()
                val app = context() ?: error("PHOTO_UNAVAILABLE")
                val result = PhotoPortrait.prepare(app, job.source.file, job.strength, token, ::checkJob)
                synchronized(PhotoCache.lock) {
                    checkJob()
                    emit("photo_portrait", id, result.put("token",token).put("state","ready")
                        .put("strength",job.strength.toDouble()).put("total_ms",(System.nanoTime()-started)/1_000_000.0).toString())
                }
            } catch (_: InterruptedException) { }
            catch (error: Throwable) {
                synchronized(PhotoCache.lock) { if (!closed && !job.cancelled) {
                    android.util.Log.w("QuestPhotoPortrait", "request=$id token=$token failure=${error.javaClass.simpleName}")
                    emit("photo_portrait", id, JSONObject().put("state","error").put("token",token)
                        .put("error",if (error.message == "PHOTO_NO_PERSON") "PHOTO_NO_PERSON" else "PHOTO_PORTRAIT_FAILED").toString())
                } }
            } finally { synchronized(PhotoCache.lock) {
                portraitJobs.remove(token,job); portraitSources.remove(job); job.source.release()
            } }
        } }
        return true
    }

    private fun stage(id: Int, phase: String) {
        android.util.Log.i("QuestPhotoDepth","request=$id preload=$preload phase=$phase")
        if (!BuildConfig.DEBUG) return
        runCatching {
            val app = context() ?: return@runCatching
            val directory = File(app.filesDir,"diagnostics").apply { mkdirs() }
            val report = JSONObject().put("pid",android.os.Process.myPid()).put("request",id).put("preload",preload)
                .put("phase",phase).put("uptime_ms",android.os.SystemClock.uptimeMillis())
            val file = android.util.AtomicFile(File(directory,"photo_pipeline.json"))
            val output = file.startWrite()
            try { output.write(report.toString().toByteArray(Charsets.UTF_8)); file.finishWrite(output) }
            catch (error: Throwable) { file.failWrite(output); throw error }
        }
    }

    override fun close() {
        closed = true; current.set(0); portraitJobs.values.forEach { it.cancelled = true }; portraitJobs.clear(); cancelDepth(); connection?.disconnect(); worker.shutdownNow()
        files.keys.toList().forEach(::release)
    }
    companion object {
        const val MAX_BYTES = 8L * 1024 * 1024 * 1024; const val MAX_PIXELS = 32L * 1024 * 1024
        private val inFlightSources = ConcurrentHashMap<DepthJob, PhotoSource>()
        private val portraitSources = ConcurrentHashMap<PortraitJob, PhotoSource>()
    }
}
