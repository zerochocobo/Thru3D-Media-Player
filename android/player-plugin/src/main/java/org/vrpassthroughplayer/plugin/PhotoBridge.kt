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
    private val backgroundAllowed: ((File) -> Boolean)? = null,
    private val postPortrait: ((Runnable) -> Unit)? = null,
    private val emit: (String, Int, String) -> Unit,
) : Closeable {
    private val current = AtomicInteger(0)
    private val files = ConcurrentHashMap<Int, PhotoSource>()
    private var animationId=0
    private var animation: AnimatedPhotoSession?=null
    private var animationDepth: AnimatedPhotoDepth?=null
    private fun closeAnimation() {
        animationDepth?.close();animationDepth=null
        animation?.close();animation=null;animationId=0
    }
    private val animationWorker=java.util.concurrent.Executors.newSingleThreadExecutor { task ->
        Thread({android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_BACKGROUND);task.run()},"PhotoAnimation")
    }
    fun animationFrame(id: Int): String = synchronized(PhotoCache.lock) {
        if(closed||current.get()!=id||files[id]?.animation!=true)return ""
        if(animationId!=id){closeAnimation();val owner=files[id]!!;val session=AnimatedPhotoSession(owner,worker=animationWorker,ownsWorker=false)
            animation=session;animationId=id;owner.animationSnapshot=session::snapshot}
        val state=JSONObject(animation?.poll()?:return "")
        if(state.optLong("token")>0)animationDepth?.present(AnimatedPhotoDepth.Identity(state.getLong("frame_id"),state.getLong("pts_us"),state.getLong("loop")))
        animationDepth?.let {state.put("depth",it.status())}
        state.toString()
    }
    fun setAnimationDepth(id: Int,enabled: Boolean): Boolean = synchronized(PhotoCache.lock) {
        if(!enabled){if(animationId==id){animationDepth?.close();animationDepth=null};return true}
        if(closed||current.get()!=id||files[id]?.animation!=true)return false
        if(animationId!=id)animationFrame(id)
        if(animationDepth==null)animationDepth=AnimatedPhotoDepth.create(context,animation!!::depthInput)
        true
    }
    fun animationDepthPixels(id: Int,token: Long): ByteArray = synchronized(PhotoCache.lock) {
        if(animationId==id)animationDepth?.pixels(token)?:ByteArray(0) else ByteArray(0)
    }
    fun pauseAnimation(id: Int,paused: Boolean) = synchronized(PhotoCache.lock) {if(animationId==id)animation?.pause(paused)}
    fun restartAnimation(id: Int) = synchronized(PhotoCache.lock) {if(animationId==id)closeAnimation()}
    fun uploadAnimation(id: Int,token: Long,texture: Int,mipmaps: Boolean): Boolean = synchronized(PhotoCache.lock) {
        animationId==id && animation?.upload(token,texture,mipmaps)==true
    }
    fun animationPixels(id: Int,token: Long): ByteArray = synchronized(PhotoCache.lock) {
        if(animationId==id)animation?.pixels(token)?:ByteArray(0) else ByteArray(0)
    }
    private class DepthJob(val id: Int, val source: PhotoSource, @Volatile var strength: Float, @Volatile var convergence: Float, val stereo: Boolean, val sceneToken: Int, val rotation: Int,
                           @Volatile var owner: PhotoBridge, @Volatile var background: Boolean, val model: PhotoDepthModel, val refine: Boolean) {
        @Volatile var cancelled = false
        val event get() = if (sceneToken > 0) "photo_scene_depth" else if (refine) "photo_depth_refined" else if (background) "photo_preload_depth" else "photo_depth"
    }
    private val depthJobs = ConcurrentHashMap<Int, DepthJob>()
    // Requests whose depth map may be kept between openings (history policy, decided by the caller).
    private val keptDepth: MutableSet<Int> = ConcurrentHashMap.newKeySet()
    fun keepDepth(id: Int, allowed: Boolean) { if (allowed && !closed) keptDepth.add(id) else keptDepth.remove(id) }
    private class PortraitJob(val id: Int, val token: Int, val source: PhotoSource, val strength: Float, val background: Boolean, val rotation: Int) {
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

    fun open(id: Int, uri: String, bounded: Boolean = false): Boolean {
        if (closed) return false
        synchronized(PhotoCache.lock) { current.set(id);closeAnimation() }
        val state = Loading(id, Uri.parse(uri).scheme !in setOf("file", "content", "pdfpage"))
        loading = state
        cancelDepth(); connection?.disconnect()
        worker.execute {
            if (current.get() != id || closed) return@execute
            var directory: File? = null
            var resolved = ""
            var published = false
            try {
                val app = context() ?: error("PHOTO_UNAVAILABLE")
                PhotoMemory.attach(app)
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
                CrashTrail.mark("photo.fetch", "req=$id preload=$preload from=${Uri.parse(uri).scheme}/${location.scheme}")
                // The online original already lives in our private files directory. A hard link
                // gives the photo cache its own lifetime without copying another GB of pixels.
                val linked = if (location.scheme == "file") runCatching {
                    val original = File(location.path ?: "").canonicalFile
                    val online = File(app.filesDir, "online-panoramas").canonicalFile
                    // Godot's joined magazine spread (tens of MB of raw rows) is deleted by its writer after ready:
                    // take the file over. Quest's SELinux denies app hard links, and a copy hit the reading 32 MB cap.
                    val spreads = File(app.cacheDir, "thru3d-photo-spreads").canonicalFile
                    if (original.parentFile == spreads && original.isFile && original.renameTo(source)) true
                    else if (original.parentFile == online && original.isFile) {
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
                        total += count; if(bounded) require(total <= 32L * 1024 * 1024) { "PHOTO_TOO_LARGE" }
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
                // Decoder retirement is serialized before allocating the next full photo, off UI.
                animationWorker.submit {}.get()
                PhotoBitmap.rawBounds(source)?.let { size ->
                    // A joined magazine spread: Godot already holds its pixels, native depth/stereo read the rows.
                    // Its composer bounds it to 8192x4096; the reading gate below is for encoded originals.
                    require(size[0] <= 8192 && size[1] <= 4096) { "PHOTO_TOO_LARGE" }
                    checkCurrent(id); files[id] = PhotoSource(source); published = true
                    emit("photo_ready", id, JSONObject().put("state", "ready").put("width", size[0]).put("height", size[1])
                        .put("orientation", 1).put("panorama", false).put("path", source.path).put("raw_rgba", true)
                        .put("decoded_width", size[0]).put("decoded_height", size[1]).put("sample", 1)
                        .put("cache_bytes", source.length()).toString())
                    return@execute
                }
                if (bounded) {
                    require(source.length() <= 32L * 1024 * 1024) { "PHOTO_TOO_LARGE" }
                    // Inspect original dimensions before NativePhoto/HEIF/downsample allocation.
                    val header = source.inputStream().use { input ->
                        val bytes = ByteArray(minOf(source.length(), PhotoHeader.MAX_BYTES.toLong()).toInt())
                        var count = 0
                        while (count < bytes.size) {
                            val read = input.read(bytes, count, bytes.size - count)
                            if (read < 0) break
                            count += read
                        }
                        PhotoHeader.read(bytes.copyOf(count))
                    }
                    val size=header ?: if(ExtendedPhoto.kind(source)!=0 || PhotoBitmap.isNative(source)) {
                        val bounds=PhotoBitmap.bounds(source);PhotoHeader(bounds.outWidth,bounds.outHeight)
                    } else null
                    require(size != null && ReadingRenderPolicy.accepts(size.width, size.height)) { "PHOTO_TOO_LARGE" }
                }
                val extendedKind=ExtendedPhoto.kind(source)
                if(extendedKind!=0) {
                    val ready=ExtendedPhoto.prepare(source,directory,preload,{checkCurrent(id)},
                        {metadata->emit("photo_ready",id,metadata.toString())})
                    ready.put("preview_only",preload)
                    checkCurrent(id);files[id]=PhotoSource(source).apply {animation=ready.optBoolean("animated")
                        if(animation)animationSnapshot={check->ExtendedPhoto.posterSnapshot(source,check)}};published=true
                    ready.put("cache_bytes",directory.listFiles()?.sumOf {it.length()}?:source.length())
                    emit("photo_ready",id,ready.toString());return@execute
                }
                if (PhotoBitmap.isNative(source)) {
                    val ready = NativePhoto.prepare(source, directory, { checkCurrent(id) },
                        { metadata -> emit("photo_ready", id, metadata.toString()) })
                    checkCurrent(id); files[id] = PhotoSource(source); published = true
                    ready.put("cache_bytes", directory.listFiles()?.sumOf { it.length() } ?: source.length())
                    emit("photo_ready", id, ready.toString()); return@execute
                }
                val heif = HeifPhotoInfo.read(source)
                if (heif != null) {
                    CrashTrail.mark("photo.heif", "req=$id bytes=${source.length()} stereo=${heif.stereo}")
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
                source.inputStream().use { CaptureFormat.read(it) }?.let { metadata.put("capture_mode", it) }
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
                val pixelBudget=PhotoMemory.snapshot().output/4
                require(pixelBudget>0) { "PHOTO_OUT_OF_MEMORY" }
                var sample = 1
                while (bounds.outWidth / sample > previewEdge || bounds.outHeight / sample > previewEdge ||
                    bounds.outWidth.toLong() / sample * (bounds.outHeight / sample) > pixelBudget) sample *= 2
                CrashTrail.mark("photo.decode", "req=$id ${bounds.outWidth}x${bounds.outHeight} ${bounds.outMimeType} sample=$sample " +
                    "bytes=${source.length()} budget=${pixelBudget / 1_000_000}MP cached=${files.size}")
                var output = source
                if (sample > 1) {
                    val bitmap = BitmapFactory.decodeFile(source.path, BitmapFactory.Options().apply { inSampleSize = sample }) ?: error("PHOTO_DECODE_FAILED")
                    try {
                        output = File(directory, "preview.t3di")
                        BitmapTransfer.write(output, bitmap) { checkCurrent(id) }
                        metadata.put("raw_rgba", true).put("decoded_width", bitmap.width).put("decoded_height", bitmap.height)
                    } finally { bitmap.recycle() }
                }
                if (preload && !uri.startsWith("pdfpage://")) {
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
                CrashTrail.mark("photo.ready", "req=$id")
                emit("photo_ready", id, metadata.toString())
            } catch (_: InterruptedException) { }
            catch (error: Throwable) {
                // Never log the original URI, resolved credentials, or provider exception text.
                if (!closed && current.get() == id) android.util.Log.w("QuestPhoto",
                    "request=$id preload=$preload failure=${error.javaClass.simpleName}")
                if (!closed && current.get() == id) emit("photo_ready", id, JSONObject().put("state", "error")
                    .put("error", if (uri.startsWith("comic://") && error is Exception) ArchiveBridge.safeError(error)
                        else if (error is OutOfMemoryError || error.message == "PHOTO_OUT_OF_MEMORY") "PHOTO_OUT_OF_MEMORY"
                        else if (error.message == "PHOTO_MEMORY_UNAVAILABLE") "PHOTO_MEMORY_UNAVAILABLE"
                        else if (error.message == "PHOTO_TOO_LARGE") "PHOTO_TOO_LARGE"
                        else if (generateSequence(error) { it.cause }.take(8).any { it is CloudFailure &&
                            it.reason in setOf("cloud_location_expired", "cloud_page_expired") }) "PHOTO_LOCATION_EXPIRED"
                        else "PHOTO_DECODE_FAILED").toString())
            } finally {
                connection?.disconnect(); connection = null
                if (uri.startsWith("smb://") || uri.startsWith("cloud://") || uri.startsWith("usb://") || uri.startsWith("pdfpage://") || uri.startsWith("comic://")) releaseStream(resolved)
                // A published preload may already have been adopted by the foreground bridge.
                if (!published) directory?.deleteRecursively()
            }
        }
        return true
    }

    fun depthPending(): Boolean = depthJobs.isNotEmpty()
    fun cancel(id: Int) {
        if (current.compareAndSet(id, 0)) connection?.disconnect()
        release(id)
    }
    fun release(id: Int) = synchronized(PhotoCache.lock) {
        if(animationId==id)closeAnimation()
        depthJobs.remove(id)?.cancelled = true
        portraitJobs.entries.filter { it.value.id == id }.forEach { it.value.cancelled = true; portraitJobs.remove(it.key) }
        keptDepth.remove(id)
        files.remove(id)?.let { it.release(); PhotoPages.clear(id) }
    }
    fun cancelDepth() = synchronized(PhotoCache.lock) {
        depthJobs.values.forEach { it.cancelled = true }
        depthJobs.clear()
    }
    fun cancelBackgroundDepth() = synchronized(PhotoCache.lock) {
        depthJobs.entries.filter { it.value.background }.forEach { it.value.cancelled = true; depthJobs.remove(it.key) }
    }
    fun cancelBackgroundPortrait() = synchronized(PhotoCache.lock) {
        portraitJobs.entries.filter { it.value.background }.forEach { it.value.cancelled = true; portraitJobs.remove(it.key) }
    }
    fun discardDepth(id: Int) = synchronized(PhotoCache.lock) {
        depthJobs.remove(id)?.cancelled = true
        files[id]?.discardDepth()
    }
    fun updateDepthStrength(strength: Float) = synchronized(PhotoCache.lock) {
        if (strength.isFinite() && strength in 0f..2f)
            depthJobs.values.filter { it.stereo && !it.cancelled }.forEach { it.strength = strength }
    }
    /** Transfer both the source lease and unfinished work; its final signal follows the owner. */
    fun promoteTo(id: Int, target: PhotoBridge): Boolean = synchronized(PhotoCache.lock) {
        if (target.closed || files[id]?.file?.isFile != true) return@synchronized false
        target.cancelDepth()
        target.closeAnimation()
        val source = files.remove(id) ?: return@synchronized false
        target.files[id] = source
        if (keptDepth.remove(id)) target.keptDepth.add(id)
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
            if(animationId!=id)closeAnimation()
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

    /** One inference per photo on the shared model thread, using an independent photo model.
     * Color stays at source display resolution; only content contributes to depth normalization.
     * The model follows [PhotoDepthRuntime.mode]; [refine] asks for the quality map of a picture shown with
     * the fast one and reports it as photo_depth_refined. A kept quality map always serves a request. */
    fun depth(id: Int, strength: Float = 1f, stereo: Boolean = false, background: Boolean = preload, sceneToken: Int = 0, rotation: Int = 0, convergence: Float = 0.35f,
              refine: Boolean = false): Boolean {
        if (refine && (background || sceneToken > 0 || !stereo)) return false
        // Scene depth (panorama layers, native stereo) keeps the quality model.
        val model = if (refine || sceneToken > 0) PhotoDepthModel.QUALITY else PhotoDepthRuntime.mode.firstModel
        if (!strength.isFinite() || strength !in 0f..2f || !convergence.isFinite() || convergence !in 0f..1f || !PhotoStereo.validRotation(rotation)) return false
        val job = synchronized(PhotoCache.lock) {
            if (closed) return false
            val source = files[id] ?: return false
            if (source.nativeStereo && sceneToken == 0) return false
            if (background && (sceneToken > 0 || source.animation || !allowBackground(source.file, !PhotoDepthRuntime.alive()))) return false
            val existing = depthJobs[id]
            if (existing != null && !existing.cancelled && existing.stereo == stereo && existing.sceneToken == sceneToken && existing.rotation == rotation
                && existing.model == model && existing.refine == refine) {
                existing.strength = strength
                existing.convergence = convergence
                existing.background = background
                return true
            }
            depthJobs.remove(id)?.cancelled = true
            DepthJob(id, source.retain(), strength, convergence, stereo, sceneToken, rotation, this, background, model, refine).also {
                depthJobs[id] = it
                inFlightSources[it] = source
            }
        }
        fun checkDepth() { if (job.cancelled || job.owner.closed) throw InterruptedException() }
        fun checkHeadroom(includeModel: Boolean = true) {
            checkDepth()
            if (job.background && !job.owner.allowBackground(job.source.file, includeModel)) throw BackgroundPressure()
        }
        // A new foreground selection passes cancelled background jobs still waiting in the queue.
        val work = Runnable {
            val started = System.nanoTime()
            var snapshot: File?=null
            try {
                // A resident photo session needs no cold-model allowance (512 MiB of a 1.5 GiB spread estimate).
                checkHeadroom(!PhotoDepthRuntime.alive())
                snapshot=job.source.effectSnapshot(::checkDepth)
                val source=snapshot?:job.source.file
                val app = context() ?: error("PHOTO_UNAVAILABLE")
                val w = PhotoDepthInput.WIDTH; val h = PhotoDepthInput.HEIGHT
                val near = ByteBuffer.allocateDirect(w * h * 4).order(ByteOrder.LITTLE_ENDIAN)
                val target = File(source.parentFile, "depth.bin")
                val metadata = File(source.parentFile, "depth.json")
                // Acceptable maps, best first: the quality map serves every request; the fast one only fast requests.
                val accepted = if (job.model == PhotoDepthModel.FAST) PhotoDepthModel.entries.toList() else listOf(PhotoDepthModel.QUALITY)
                val cached = if (target.length() == w.toLong()*h*4 && metadata.isFile)
                    runCatching { JSONObject(metadata.readText()).takeIf { PhotoDepthModel.ofCache(it.optString("photo_cache")) in accepted } }.getOrNull() else null
                val leftEye = job.source.nativeStereo && job.sceneToken > 0
                val pages = if (leftEye || job.sceneToken > 0) 0f else PhotoPages.split(id)
                fun variant(model: PhotoDepthModel) = model.cache + (if (leftEye) "-left" else "") + if (pages > 0f) "-pages${PhotoPages.seam(w, pages)}" else ""
                // An animation's frame snapshot is not the file a later opening would hash.
                val store = if (cached == null && snapshot == null && id in job.owner.keptDepth) PhotoDepthStore(app.cacheDir) else null
                val keys = store?.keys(source, PhotoDepthModel.entries.map(::variant))
                checkDepth()
                var keptModel: PhotoDepthModel? = null
                val kept = if (store != null && keys != null) accepted.firstNotNullOfOrNull { model ->
                    store.get(keys.getValue(variant(model)), w, h)?.also { keptModel = model }
                } else null
                val result: JSONObject
                val used: PhotoDepthModel
                if (cached != null) {
                    near.put(target.readBytes()); near.rewind()
                    used = PhotoDepthModel.ofCache(cached.optString("photo_cache"))!!
                    result = cached.put("depth_cached",true).put("model_reused",false)
                } else if (kept != null) {
                    // A picture seen before: no model session, no GPU time.
                    used = keptModel!!
                    near.put(kept.near); near.rewind()
                    val bytes = ByteArray(near.remaining()); near.get(bytes); near.rewind()
                    target.writeBytes(bytes)
                    result = JSONObject().put("state","ready").put("path",target.path).put("width",w).put("height",h)
                        .put("photo_cache",used.cache).put("rect",org.json.JSONArray(kept.rect.map { it.toDouble() }))
                    metadata.writeText(result.toString())
                    result.put("depth_cached",true).put("depth_kept",true).put("model_reused",false)
                } else {
                    used = job.model
                    stage(id,"input")
                    val inputStarted = System.nanoTime()
                    val cut = if (pages > 0f) PhotoPages.seam(w, pages).toFloat() / w else 0f
                    val inputs = PhotoDepthInput.prepareRegions(source, used.width, used.height, selectLeftEye = leftEye,
                        regions = if (pages > 0f) listOf(0f..cut, cut..1f) else listOf(0f..1f))
                    val input = inputs.first()
                    val inputMs = (System.nanoTime() - inputStarted) / 1_000_000.0
                    val content = input.content
                    checkDepth()
                    checkHeadroom(!PhotoDepthRuntime.alive())
                    stage(id,"waiting_model")
                    val modelStarted = System.nanoTime()
                    val output = if (used.width == w && used.height == h) near
                        else ByteBuffer.allocateDirect(used.width * used.height * 4).order(ByteOrder.LITTLE_ENDIAN)
                    result = PhotoDepthRuntime.run(app,used,::checkDepth) { handle, reused ->
                        checkHeadroom(false)
                        val runtime = JSONObject(DepthNative.describe(handle)).put("session_reused", reused)
                        stage(id,"inference")
                        if (inputs.size == 1) JSONObject(DepthNative.processPhoto(handle,input.rgb,output,content.x,content.y,content.width,content.height))
                            .put("runtime",runtime).put("model_reused",reused).put("depth_cached",false)
                        else {
                            // A spread: each page inferred and normalized alone, then joined in its own columns.
                            var page = JSONObject()
                            val maps = inputs.map { part ->
                                checkDepth()
                                page = JSONObject(DepthNative.processPhoto(handle,part.rgb,output,content.x,content.y,content.width,content.height))
                                require(page.optString("state") == "ready")
                                output.rewind()
                                PhotoDepthInput.resample(output, used.width, used.height, w, h)
                            }
                            near.put(PhotoPages.compose(maps[0], maps[1], w, h, pages)); near.rewind()
                            page.put("runtime",runtime).put("model_reused",reused).put("depth_cached",false).put("depth_pages",2)
                        }
                    }
                    // The fast map covers the same whole-photo stretch; resample it to the shared map size.
                    if (inputs.size == 1 && output !== near) { near.put(PhotoDepthInput.resample(output, used.width, used.height, w, h)); near.rewind() }
                    result.put("input_ms",inputMs).put("input_steps",input.steps).put("depth_total_ms",(System.nanoTime()-modelStarted)/1_000_000.0)
                    require(result.optString("state") == "ready")
                    checkDepth()
                    near.rewind(); val bytes = ByteArray(near.remaining()); near.get(bytes); near.rewind()
                    target.writeBytes(bytes)
                    result.put("path",target.path).put("width",w).put("height",h).put("photo_cache",used.cache)
                        .put("rect",org.json.JSONArray(listOf(content.x.toDouble()/used.width,content.y.toDouble()/used.height,
                            content.width.toDouble()/used.width,content.height.toDouble()/used.height)))
                    metadata.writeText(result.toString())
                    if (store != null && keys != null) {
                        val rect = result.getJSONArray("rect")
                        store.put(keys.getValue(variant(used)), near, w, h, FloatArray(4) { rect.getDouble(it).toFloat() })
                        // The quality map serves every later request: its fast map would only take room.
                        if (used == PhotoDepthModel.QUALITY) store.remove(keys.getValue(variant(PhotoDepthModel.FAST)))
                    }
                }
                result.put("depth_model", if (used == PhotoDepthModel.QUALITY) "quality" else "fast")
                checkDepth()
                if (stereo) {
                    checkHeadroom(false)
                    stage(id,"stereo")
                    val stereoStarted = System.nanoTime()
                    val rect = result.getJSONArray("rect")
                    val pair = PhotoStereo.prepare(source,near,FloatArray(4) { rect.getDouble(it).toFloat() },job.strength,id,job.rotation,job.convergence,
                        used == PhotoDepthModel.FAST, PhotoStereo.stretch, pages = pages, steady = PhotoStereo.steady)
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
                    android.util.Log.i("QuestPhotoDepth", "request=$id model=${used.name} refine=${job.refine} cached=${cached != null} kept=${kept != null} reused=${result.optBoolean("model_reused")} total_ms=${result.optDouble("total_ms")} " +
                        "input_ms=${result.optDouble("input_ms")} depth_ms=${result.optDouble("depth_ms")} priority=${result.optJSONObject("runtime")?.optInt("priority",-1)} " +
                        "stereo_ms=${result.optDouble("stereo_total_ms")} stereo_gpu_us=${result.optLong("stereo_render_us")} " +
                        "input_steps=[${result.optString("input_steps")}] stereo_steps=[${result.optString("stereo_steps")}]")
                    if (job.sceneToken > 0) result.put("scene_token",job.sceneToken)
                    job.owner.emit(job.event,id,result.toString())
                }
            } catch (_: InterruptedException) { }
            catch (error: Throwable) {
                synchronized(PhotoCache.lock) { if (!job.cancelled && !job.owner.closed) {
                    job.owner.depthJobs.remove(id,job)
                    if (error !is BackgroundPressure) {
                        job.owner.stage(id,"failed")
                        android.util.Log.w("QuestPhotoDepth", "Photo depth failed", error)
                    }
                    val failure = JSONObject().put("state","error").put("error","PHOTO_DEPTH_FAILED").put("scene_token",job.sceneToken)
                        .put("stereo_rotation",job.rotation)
                        .put("deferred", error is BackgroundPressure)
                    job.owner.emit(job.event, id, failure.toString())
                } }
            }
            finally { snapshot?.delete();synchronized(PhotoCache.lock) {
                job.owner.depthJobs.remove(id,job)
                inFlightSources.remove(job)
                job.source.release()
            } }
        }
        val serialized = Runnable { synchronized(BackgroundResourceBudget.photoWorkLock) { work.run() } }
        if (postDepth != null) postDepth.invoke(serialized,!background)
        else if (background) DepthWorker.handler.post(serialized) else DepthWorker.handler.postAtFrontOfQueue(serialized)
        return true
    }

    fun cancelPortrait(token: Int) = synchronized(PhotoCache.lock) {
        portraitJobs.remove(token)?.cancelled = true
    }

    private class BackgroundPressure : RuntimeException("PHOTO_BACKGROUND_PRESSURE")
    private fun allowBackground(source: File, includeModel: Boolean = true): Boolean = runCatching {
        backgroundAllowed?.let { return@runCatching it(source) }
        val budget = BackgroundResourceBudget.snapshot(context())
        if (!budget.work) return@runCatching false
        val bounds = PhotoBitmap.bounds(source)
        budget.admits(BackgroundResourceBudget.photoPeak(bounds.outWidth, bounds.outHeight, includeModel))
    }.getOrDefault(false)

    /** Still matting never consumes gallery previews or shares recurrent state with video. */
    fun portrait(id: Int, token: Int, strength: Float, background: Boolean = false, rotation: Int = 0): Boolean {
        if (token <= 0 || !strength.isFinite() || strength !in 0f..2f || !PhotoStereo.validRotation(rotation)) return false
        val job = synchronized(PhotoCache.lock) {
            if (closed || (!background && (preload || current.get() != id))) return false
            val source = files[id] ?: return false
            if (source.nativeStereo) return false
            if (background && (source.animation || !allowBackground(source.file))) return false
            if (background && portraitJobs.values.any { !it.background && !it.cancelled }) return false
            portraitJobs.entries.filter { !background || it.value.background }.forEach { it.value.cancelled = true; portraitJobs.remove(it.key) }
            PortraitJob(id, token, source.retain(), strength, background, rotation).also {
                portraitJobs[token] = it; portraitSources[it] = source
            }
        }
        fun checkJob() {
            if (closed || job.cancelled) throw InterruptedException()
            if (background && !(backgroundAllowed?.invoke(job.source.file) ?: BackgroundResourceBudget.snapshot(context()).work)) throw BackgroundPressure()
        }
        // Preparing and inference stay on the production RVM worker, behind retired video work.
        val work = Runnable {
            val started = System.nanoTime()
            var snapshot: File?=null
            try {
                checkJob()
                if (background && !allowBackground(job.source.file)) throw BackgroundPressure()
                snapshot=job.source.effectSnapshot(::checkJob)
                val app = context() ?: error("PHOTO_UNAVAILABLE")
                val result = PhotoPortrait.prepare(app, snapshot?:job.source.file, job.strength, token, ::checkJob,job.rotation)
                synchronized(PhotoCache.lock) {
                    checkJob()
                    emit(if (background) "photo_preload_portrait" else "photo_portrait", id, result.put("token",token).put("state","ready")
                        .put("strength",job.strength.toDouble()).put("total_ms",(System.nanoTime()-started)/1_000_000.0).toString())
                }
            } catch (_: InterruptedException) { }
            catch (error: Throwable) {
                synchronized(PhotoCache.lock) { if (!closed && !job.cancelled) {
                    if (error !is BackgroundPressure) android.util.Log.w("QuestPhotoPortrait", "request=$id token=$token failure=${error.javaClass.simpleName}")
                    emit(if (background) "photo_preload_portrait" else "photo_portrait", id, JSONObject().put("state","error").put("token",token)
                        .put("deferred", error is BackgroundPressure)
                        .put("error",if (error.message == "PHOTO_NO_PERSON") "PHOTO_NO_PERSON" else "PHOTO_PORTRAIT_FAILED").toString())
                } }
            } finally { snapshot?.delete();synchronized(PhotoCache.lock) {
                portraitJobs.remove(token,job); portraitSources.remove(job); job.source.release()
            } }
        }
        val serialized = Runnable { synchronized(BackgroundResourceBudget.photoWorkLock) { work.run() } }
        if (postPortrait != null) postPortrait.invoke(serialized)
        else RvmWorkers.prepare.post { RvmWorkers.video.post(serialized) }
        return true
    }

    private fun stage(id: Int, phase: String) {
        android.util.Log.i("QuestPhotoDepth","request=$id preload=$preload phase=$phase")
        CrashTrail.mark("photo.depth", "req=$id preload=$preload phase=$phase")
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
        animationWorker.shutdown()
    }
    companion object {
        // Streaming callers share this type bound; disk headroom controls real transfers.
        const val MAX_BYTES = Long.MAX_VALUE
        private val inFlightSources = ConcurrentHashMap<DepthJob, PhotoSource>()
        private val portraitSources = ConcurrentHashMap<PortraitJob, PhotoSource>()
    }
}
