package org.vrpassthroughplayer.plugin

import android.content.ContentUris
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.graphics.Matrix
import android.media.ExifInterface
import android.net.Uri
import android.os.Build
import android.os.CancellationSignal
import android.os.Environment
import android.os.ParcelFileDescriptor
import android.provider.MediaStore
import android.util.Size
import org.json.JSONObject
import org.json.JSONArray
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.io.File
import java.io.IOException
import java.net.SocketTimeoutException
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.ByteBuffer
import java.nio.file.attribute.BasicFileAttributes
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

/** One optional reader, independent of foreground storage, photo and player executors. */
internal class LocalThumbnailPrefetch(
    private val context: () -> Context?,
    private val deadlineMs: Long = 2400,
    private val smb: ((String) -> StreamSource.Reader)? = null,
    private val dlna: ((String, String) -> DlnaThumbnailReader?)? = null,
    private val dlnaChildren: ((String, String, Work) -> JSONArray)? = null,
    private val fixture: ((Work) -> Result?)? = null,
) : Closeable {
    data class Request(val uri: String, val kind: String, val directoryLimit: Int,
        val visit: Int, val videoNames: List<String>, val size: Long = -1,
        val resource: String = "", val sidecar: String = "", val sidecarSize: Long = -1)

    data class Result(val jpg: ByteArray, val uri: String, val size: Long = -1, val modified: Long = -1,
        val entry: JSONObject? = null)

    class Work(val id: Int, val request: Request) {
        val cancelled = AtomicBoolean()
        val abandoned = AtomicBoolean()
        @Volatile var closing = false
        val abort = AtomicReference<(() -> Unit)?>()
        @Volatile var started = false
        @Volatile var finished = false
        @Volatile var temporary = false
        @Volatile var sampled = 0
        @Volatile var stage = "open"
        @Volatile var timedOut = false
        var reason = ""
        var transport = ""
        var container = ""
        var codec = ""
        var httpStatus = 0
        var mediaBytes = 0L
        var elapsedMs = 0L
        var result: Result? = null

        fun miss(reason: String): Nothing? {
            this.reason = reason
            return null
        }

        fun diagnostic(): JSONObject = JSONObject().put("stage", stage)
            .put("reason", if (timedOut) "deadline" else if (cancelled.get()) "cancelled" else reason)
            .put("transport", transport).put("container", container).put("codec", codec)
            .put("worker_ms", elapsedMs).apply {
                if (httpStatus > 0) put("http_status", httpStatus)
                if (mediaBytes > 0) put("media_bytes", mediaBytes)
            }

        fun checkActive() {
            if (cancelled.get() || Thread.currentThread().isInterrupted) throw InterruptedException()
        }

        fun <T> interruptible(stop: () -> Unit, read: () -> T): T {
            abort.set(stop)
            return try { checkActive(); read() }
            finally { abort.compareAndSet(stop, null) }
        }
    }

    private val work = AtomicReference<Work?>()
    private val ids = AtomicInteger()
    private val reader = Executors.newSingleThreadExecutor { Thread(it, "LocalThumbnail").apply { isDaemon = true } }
    private val watchdog = ScheduledThreadPoolExecutor(1) { Thread(it, "LocalThumbnailDeadline").apply { isDaemon = true } }
        .apply { removeOnCancelPolicy = true }
    @Volatile private var closed = false
    private var storeFolder = ""
    private var lastTrailNs = 0L
    private val videoUris = LinkedHashMap<String, Uri?>()

    fun request(raw: String): Int {
        if (closed || raw.length > 24000) return -1
        val json = runCatching { JSONObject(raw) }.getOrNull() ?: return -1
        val uri = json.optString("uri")
        val kind = json.optString("kind")
        if (uri.isBlank() || uri.length > 8192 || kind !in setOf("image", "video", "folder")) return -1
        val names = json.optJSONArray("videos")
        val videos = if (names == null) emptyList() else (0 until minOf(names.length(), 16)).map { names.optString(it) }
        val request = Request(uri, kind, json.optInt("sample_limit").coerceIn(0, 32), json.optInt("visit"), videos,
            json.optLong("size", -1), json.optString("resource"), json.optString("sidecar"), json.optLong("sidecar_size", -1))
        val job = Work(ids.incrementAndGet(), request)
        if (!work.compareAndSet(null, job)) return -1
        try { reader.execute { run(job) } }
        catch (_: RuntimeException) { work.compareAndSet(job, null); return -1 }
        return job.id
    }

    private fun run(job: Work) {
        runCatching { android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_BACKGROUND) }
        val began = System.nanoTime()
        val source = when (job.request.uri.substringBefore(':')) {
            "file", "content" -> "local"
            "smb" -> "smb"
            "dlna" -> "dlna"
            else -> "unknown"
        }
        val trail = PlaybackPrivacy.diagnostics && (lastTrailNs == 0L || began - lastTrailNs >= 4_000_000_000L)
        if (trail) {
            lastTrailNs = began
            CrashTrail.mark("thumbnail.begin", "job=${job.id} source=$source kind=${job.request.kind}")
        }
        val deadline = runCatching { watchdog.schedule({ abort(job) }, deadlineMs, TimeUnit.MILLISECONDS) }.getOrNull()
        try {
            job.checkActive()
            job.started = true
            job.result = if (fixture != null) fixture.invoke(job) else context()?.let { load(it, job) }
        } catch (error: IOException) {
            job.reason = when {
                error is SocketTimeoutException -> "io_timeout"
                source == "smb" && SmbClientPolicy.needsCredentials(error) -> "smb_access_denied"
                else -> "io_error"
            }
            job.temporary = true
        } catch (_: InterruptedException) {
            job.cancelled.set(true)
        } catch (_: RuntimeException) {
            job.reason = "reader_failed"
        } finally {
            deadline?.cancel(false)
            job.abort.set(null)
            job.elapsedMs = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - began)
            if (trail && PlaybackPrivacy.diagnostics) {
                val outcome = if (job.timedOut) "deadline" else if (job.cancelled.get()) "cancelled"
                    else if (job.result != null) "ready" else if (job.reason.isNotEmpty()) job.reason else "missing"
                CrashTrail.mark("thumbnail.end", "job=${job.id} stage=${job.stage} result=$outcome ms=${job.elapsedMs}")
            }
            synchronized(job) {
                job.finished = true
                releaseAbandoned(job)
            }
        }
    }

    fun state(id: Int): String {
        val job = work.get()?.takeIf { it.id == id } ?: return """{"state":"gone"}"""
        return synchronized(job) {
            val finished = job.finished && !job.closing
            val result = job.result.takeIf { finished && !job.cancelled.get() }
            val state = when {
                job.cancelled.get() -> if (finished) "cancelled" else "cancelling"
                result != null -> "ready"
                finished -> if (job.temporary) "temporary" else "missing"
                job.started -> "reading"
                else -> "queued"
            }
            JSONObject().put("state", state).put("sampled", job.sampled)
                .apply {
                    if (finished && PlaybackPrivacy.diagnostics) put("diagnostic", job.diagnostic())
                    result?.let { put("uri", it.uri).put("size", it.size).put("modified", it.modified).put("entry", it.entry) }
                }.toString()
        }
    }

    fun take(id: Int): ByteArray {
        val job = work.get()?.takeIf { it.id == id } ?: return byteArrayOf()
        return synchronized(job) {
            if (job.finished && job.closing) job.abandoned.set(true)
            if (!job.finished || job.closing || !work.compareAndSet(job, null) || job.cancelled.get()) byteArrayOf()
            else job.result?.jpg ?: byteArrayOf()
        }
    }

    fun cancel(id: Int) {
        val job = work.get()?.takeIf { it.id == id } ?: return
        if (!beginCancel(job)) return
        if (runCatching { watchdog.execute { closeActive(job) } }.isFailure) {
            synchronized(job) { job.closing = false; releaseAbandoned(job) }
        }
    }

    fun abandon(id: Int) {
        val job = work.get()?.takeIf { it.id == id } ?: return
        job.abandoned.set(true)
        cancel(id)
        synchronized(job) { releaseAbandoned(job) }
    }

    private fun abort(job: Work) {
        if (beginCancel(job, timedOut = true)) {
            if (PlaybackPrivacy.diagnostics && deadlineTrailAllowed()) {
                CrashTrail.mark("thumbnail.deadline", "job=${job.id} stage=${job.stage}")
            }
            closeActive(job)
        }
    }

    private var deadlineTrailNs = 0L
    private fun deadlineTrailAllowed(): Boolean {
        val now = System.nanoTime()
        if (deadlineTrailNs != 0L && now - deadlineTrailNs < 4_000_000_000L) return false
        deadlineTrailNs = now
        return true
    }

    private fun beginCancel(job: Work, timedOut: Boolean = false): Boolean = synchronized(job) {
        if (work.get() !== job || !job.cancelled.compareAndSet(false, true)) return false
        job.timedOut = timedOut
        job.closing = true
        true
    }

    private fun closeActive(job: Work) {
        runCatching { job.abort.getAndSet(null)?.invoke() }
        synchronized(job) { job.closing = false; releaseAbandoned(job) }
    }

    private fun releaseAbandoned(job: Work) {
        if (job.abandoned.get() && job.finished && !job.closing) work.compareAndSet(job, null)
    }

    override fun close() {
        closed = true
        work.get()?.let { cancel(it.id) }
        reader.shutdownNow()
        watchdog.shutdown()
    }

    private fun load(context: Context, job: Work): Result? {
        PhotoMemory.attach(context)
        val request = job.request
        val uri = Uri.parse(request.uri)
        if (uri.scheme in setOf("smb", "dlna")) return network(uri, job)
        if (uri.scheme == "content") {
            job.stage = "media_store"
            if (request.kind == "folder" || uri.authority != MediaStore.AUTHORITY ||
                uri.pathSegments.firstOrNull() != MediaStore.VOLUME_EXTERNAL_PRIMARY) return null
            val pixels = try { system(context, uri, job) }
                catch (_: IOException) { null }
                catch (_: RuntimeException) { null }
            if (pixels != null) return Result(pixels, request.uri)
            val collection = if (request.kind == "video") "video" else "images"
            if (uri.pathSegments.getOrNull(1) != collection) return null
            job.checkActive()
            val signal = CancellationSignal()
            val file = job.interruptible(signal::cancel) {
                context.contentResolver.openFileDescriptor(uri, "r", signal)
            } ?: return null
            val size = file.statSize
            return ParcelFileDescriptor.AutoCloseInputStream(file).use { input ->
                val reader = channelReader(input.channel)
                val picture = if (request.kind == "video") video(reader, size, LOCAL_VIDEO_BYTES, job)
                    else remotePhoto(reader, size, job)
                picture?.let { Result(it, request.uri) }
            }
        }
        if (uri.scheme != "file" || !uri.authority.isNullOrEmpty() || uri.path.isNullOrBlank()) return null
        @Suppress("DEPRECATION")
        val root = Environment.getExternalStorageDirectory().canonicalFile
        val original = File(uri.path!!).absoluteFile
        val file = original.canonicalFile
        if (!file.toPath().startsWith(root.toPath()) || file != original || file.name.startsWith('.')) return null
        return if (request.kind == "folder") folder(file, job)
        else {
            val before = attributes(file) ?: return null
            val pixels = if (request.kind == "video") localVideo(context, root, file, before.size(), job)
                else photo(file, before.size(), job)
            if (pixels == null) null
            else if (changed(file, before)) job.miss("source_changed")
            else Result(pixels, request.uri, before.size(), before.lastModifiedTime().toMillis())
        }
    }

    private fun localVideo(context: Context, root: File, file: File, size: Long, job: Work): ByteArray? {
        job.stage = "media_store"
        val systemPicture = try { videoUri(context, root, file, job)?.let { system(context, it, job) } }
            catch (_: IOException) { null }
            catch (_: RuntimeException) { null }
        if (systemPicture != null) return systemPicture
        job.checkActive()
        job.stage = "open"
        job.transport = "file"
        Files.newByteChannel(file.toPath(), NOFOLLOW_LINKS).use { channel ->
            return video(channelReader(channel), size, LOCAL_VIDEO_BYTES, job)
        }
    }

    private fun channelReader(channel: java.nio.channels.SeekableByteChannel) = object : StreamSource.Reader {
        override fun read(offset: Long, buffer: ByteArray, length: Int): Int {
            channel.position(offset)
            return channel.read(ByteBuffer.wrap(buffer, 0, length))
        }
        override fun close() = channel.close()
    }

    private fun network(uri: Uri, job: Work): Result? {
        val request = job.request
        val jpg = when (uri.scheme) {
            "smb" -> {
                job.transport = "smb"
                job.stage = "smb_open"
                val opener = smb ?: return null
                val sidecar = request.sidecar.takeIf { request.kind == "video" && it.startsWith("smb://") &&
                    it.substringBeforeLast('/') == request.uri.substringBeforeLast('/') && request.sidecarSize > 0 }
                val declared = if (sidecar == null) null else try {
                    opener(sidecar).use { remotePhoto(it, request.sidecarSize, job) }
                } catch (_: IOException) { job.checkActive(); null }
                if (declared != null) {
                    job.stage = "smb_sidecar"
                    return Result(declared, request.uri, request.size)
                }
                job.stage = "smb_open"
                if (request.kind == "folder" || request.size <= 0) return job.miss("size_unavailable")
                opener(request.uri).use { input ->
                    if (request.kind == "image") remotePhoto(input, request.size, job)
                    else video(input, request.size, NETWORK_VIDEO_BYTES, job)
                }
            }
            "dlna" -> {
                val server = uri.authority ?: return null
                if (request.kind == "folder") return dlnaFolder(server, uri.pathSegments.singleOrNull() ?: return null, job)
                val url = request.resource.takeIf { it.isNotBlank() } ?: return null
                dlnaPicture(server, url, request.kind == "video", job)
            }
            else -> null
        }
        return jpg?.let { Result(it, request.uri, request.size) }
    }

    private fun dlnaFolder(server: String, objectId: String, job: Work): Result? {
        job.stage = "folder_browse"
        if (job.request.directoryLimit == 0) return null
        val entries = dlnaChildren?.invoke(server, objectId, job) ?: return null
        val candidates = (0 until entries.length()).map { entries.getJSONObject(it) }
            .filter { !it.optBoolean("container") && it.optString("kind") in setOf("video", "image") && it.optString("id").isNotBlank() }
        val child = candidates.firstOrNull { it.optString("kind") == "image" }
            ?: candidates.firstOrNull { it.optString("cover").isNotBlank() } ?: candidates.firstOrNull()
            ?: return job.miss("no_candidate")
        val source = child.optString("uri")
        val cover = child.optString("cover").ifBlank { child.optString("thumbnail_uri") }
        val declared = if (cover.isBlank() || cover == source) null else try {
            dlnaPicture(server, cover, false, job, DLNA_FOLDER_COVER_BYTES)
        } catch (_: IOException) {
            job.checkActive()
            null
        }
        val jpg = declared ?: run {
            job.checkActive()
            if (source.isBlank()) return null
            val remaining = NETWORK_VIDEO_BYTES - job.mediaBytes
            if (remaining <= 1) return job.miss("read_limit")
            dlnaPicture(server, source, child.optString("kind") == "video", job, remaining.toInt())
        } ?: return null
        val uri = "dlna://${Uri.encode(server)}/${Uri.encode(child.getString("id"))}"
        return Result(jpg, uri, child.optLong("size", -1), entry = child)
    }

    private fun dlnaPicture(server: String, url: String, isVideo: Boolean, job: Work,
        byteLimit: Int = NETWORK_VIDEO_BYTES): ByteArray? {
        job.stage = "dlna_probe"
        job.reason = ""
        val reader = dlna?.invoke(server, url) ?: return job.miss("resource_unavailable")
        return reader.use { input ->
            try {
                val probeBytes = job.interruptible(input::close) { input.probe() }
                if (probeBytes > 0) job.mediaBytes += probeBytes
                val remaining = byteLimit - probeBytes.coerceAtLeast(0)
                job.transport = if (input.sequential) "http_prefix" else "http_range"
                if (remaining <= 0) job.miss("read_limit")
                else if (input.size <= 0 && !input.sequential) job.miss("probe_rejected")
                else if (isVideo) video(input, input.size, remaining, job, !input.sequential)
                else remotePhoto(input, input.size, job, remaining.toLong())
            } finally { job.httpStatus = input.httpStatus }
        }
    }

    private fun video(input: StreamSource.Reader, size: Long, bytes: Int, job: Work, seekable: Boolean = true): ByteArray? {
        job.stage = "video_decode"
        job.reason = ""
        if ((seekable && size <= 0) || !OriginalClipNative.supported()) return job.miss("input_unavailable")
        val maxPixels = minOf(40L * 1024 * 1024, PhotoMemory.snapshot().native / 8)
        if (maxPixels <= 0) { job.temporary = true; return job.miss("memory_limit") }
        val bitmap = job.interruptible(input::close) {
            OriginalClipNative.thumbnail(ThumbnailVideoReader(job, input), size, bytes, maxPixels, seekable)
        } ?: return null
        return try { encode(bitmap, 1, job) } finally { bitmap.recycle() }
    }

    private fun remotePhoto(input: StreamSource.Reader, size: Long, job: Work,
        byteLimit: Long = NETWORK_IMAGE_BYTES): ByteArray? {
        job.stage = "photo_read"
        val partial = size > byteLimit
        val target = if (partial) minOf(65536L, byteLimit) else if (size < 0) byteLimit else size
        val payload = ByteArray(target.toInt())
        val chunk = ByteArray(minOf(payload.size, 128 * 1024))
        var count = 0
        job.interruptible(input::close) {
            while (count < payload.size) {
                job.checkActive()
                val read = input.read(count.toLong(), chunk, minOf(chunk.size, payload.size - count))
                if (read == 0 && size < 0) break
                if (read <= 0) throw IOException("Short image preview")
                job.mediaBytes += read
                chunk.copyInto(payload, count, 0, read)
                count += read
            }
        }
        if (count == 0) return job.miss("short_read")
        if (size < 0 && count == payload.size) return job.miss("read_limit")
        val bytes = if (count == payload.size) payload else payload.copyOf(count)
        val jpeg = count >= 2 && bytes[0] == 0xff.toByte() && bytes[1] == 0xd8.toByte()
        val decoded = if (jpeg || (partial && PhotoBitmap.tiffHeader(bytes))) decodePhoto(bytes, partial, job) else null
        if (decoded != null) { job.stage = if (partial) "embedded_photo" else "photo_decode"; return decoded }
        if (partial) return job.miss("no_embedded_photo")
        // File-based photo decoders get a seekable memory file. Original photos never enter
        // the disk cache, even if the app exits in the middle of a preview.
        job.checkActive()
        if (OriginalClipNative.supported()) {
            val fd = OriginalClipNative.thumbnailImageInput(bytes)
            if (fd >= 0) {
                val decodedFile = ParcelFileDescriptor.adoptFd(fd).use { decodePhotoFile(File("/proc/self/fd/${it.fd}"), job) }
                if (decodedFile != null) return decodedFile
            }
        }
        return decodePlatformPhoto(ImageDecoder.createSource(ByteBuffer.wrap(bytes)), job)
    }

    private fun folder(file: File, job: Work): Result? {
        job.stage = "folder_browse"
        if (job.request.directoryLimit <= 0 || !Files.isDirectory(file.toPath(), NOFOLLOW_LINKS)) return null
        var chosen: File? = null
        var best = 0
        Files.newDirectoryStream(file.toPath()).use { entries ->
            job.interruptible(entries::close) {
                val iterator = entries.iterator()
                while (job.sampled < job.request.directoryLimit) {
                    job.checkActive()
                    if (!iterator.hasNext()) break
                    val child = iterator.next().toFile()
                    job.sampled++
                    if (child.name.startsWith('.') || !supportsPhoto(child) || attributes(child) == null) continue
                    val rank = when (child.nameWithoutExtension.lowercase()) {
                        "folder" -> 4
                        "cover" -> 3
                        "poster" -> 2
                        else -> 1
                    }
                    if (rank > best) { chosen = child; best = rank }
                    if (rank == 4) break
                }
            }
        }
        val child = chosen ?: return job.miss("no_candidate")
        val before = attributes(child) ?: return null
        val pixels = photo(child, before.size(), job) ?: return null
        if (changed(child, before)) return null
        return Result(pixels, Uri.fromFile(child).toString(), before.size(), before.lastModifiedTime().toMillis())
    }

    private fun attributes(file: File): BasicFileAttributes? {
        val result = Files.readAttributes(file.toPath(), BasicFileAttributes::class.java, NOFOLLOW_LINKS)
        return result.takeIf { it.isRegularFile && it.size() > 0 }
    }

    private fun changed(file: File, before: BasicFileAttributes): Boolean {
        val after = attributes(file) ?: return true
        return before.size() != after.size() || before.lastModifiedTime() != after.lastModifiedTime()
    }

    private fun videoUri(context: Context, root: File, file: File, job: Work): Uri? {
        if (Build.VERSION.SDK_INT < 29) return null
        val relative = file.parentFile?.relativeTo(root)?.invariantSeparatorsPath ?: return null
        val directory = if (relative.isEmpty()) "" else "$relative/"
        val scope = "${job.request.visit}/$directory"
        if (storeFolder != scope) { storeFolder = scope; videoUris.clear() }
        if (videoUris.containsKey(file.name)) return videoUris[file.name]
        // Batch only names already visible in this directory. No scan of the MediaStore collection.
        val names = job.request.videoNames.filter { it.length in 1..255 && '/' !in it && '\\' !in it }
        val wanted = (listOf(file.name) + names).distinct().filterNot(videoUris::containsKey).take(16)
        val collection = MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val selection = "${MediaStore.MediaColumns.RELATIVE_PATH}=? AND ${MediaStore.MediaColumns.DISPLAY_NAME} IN (${wanted.joinToString(",") { "?" }})"
        val cancel = CancellationSignal()
        job.interruptible(cancel::cancel) {
            context.contentResolver.query(collection, arrayOf(MediaStore.MediaColumns._ID, MediaStore.MediaColumns.DISPLAY_NAME),
                selection, (listOf(directory) + wanted).toTypedArray(), null, cancel)?.use { cursor ->
                wanted.forEach { videoUris[it] = null }
                var count = 0
                while (count++ < wanted.size && cursor.moveToNext()) {
                    job.checkActive()
                    videoUris[cursor.getString(1)] = ContentUris.withAppendedId(collection, cursor.getLong(0))
                }
            }
        }
        while (videoUris.size > 256) videoUris.remove(videoUris.keys.first())
        return videoUris[file.name]
    }

    private fun system(context: Context, uri: Uri, job: Work): ByteArray? {
        if (Build.VERSION.SDK_INT < 29) return null
        val signal = CancellationSignal()
        val bitmap = job.interruptible(signal::cancel) {
            context.contentResolver.loadThumbnail(uri, Size(320, 180), signal)
        }
        return try { encode(bitmap, 1, job) } finally { bitmap.recycle() }
    }

    private fun photo(file: File, bytes: Long, job: Work): ByteArray? {
        job.stage = "photo_read"
        job.transport = "file"
        if (!supportsPhoto(file)) return job.miss("unsupported_photo")
        if (bytes <= LOCAL_IMAGE_BYTES) return decodePhotoFile(file, job)
        if (ExtendedPhoto.kind(file) == ExtendedPhoto.RAW) return decodePhotoFile(file, job)
        val jpeg = file.extension.lowercase() in setOf("jpg", "jpeg")
        if (!jpeg) return job.miss("read_limit")
        val payload = ByteArray(64 * 1024)
        var count = 0
        Files.newInputStream(file.toPath(), NOFOLLOW_LINKS).use { input ->
            job.interruptible(input::close) {
                while (count < payload.size) {
                    job.checkActive()
                    val read = input.read(payload, count, minOf(65536, payload.size - count))
                    if (read <= 0) break
                    job.mediaBytes += read
                    count += read
                }
            }
        }
        if (count != payload.size) throw IOException("Short thumbnail input")
        job.stage = "embedded_photo"
        return decodePhoto(payload, true, job) ?: job.miss("no_embedded_photo")
    }

    private fun decodePhotoFile(file: File, job: Work): ByteArray? {
        job.checkActive()
        job.stage = "photo_decode"
        val picture: Bitmap
        var orientation = 1
        if (ExtendedPhoto.kind(file) != 0) {
            val preview = ExtendedPhoto.bitmap(file, 512, true, job::checkActive)
            picture = preview.first
            orientation = preview.second[5].toInt()
        } else if (PhotoBitmap.isNative(file)) {
            val bounds = PhotoBitmap.bounds(file)
            val sample = sampleSize(bounds.outWidth, bounds.outHeight, MAX_PHOTO_PIXELS) ?: return null
            orientation = PhotoBitmap.orientation(file)
            picture = PhotoBitmap.region(file, 0, 0, bounds.outWidth, bounds.outHeight, sample, job::checkActive)
        } else return decodePlatformPhoto(ImageDecoder.createSource(file), job)
        return try { encode(picture, orientation, job) } finally { picture.recycle() }
    }

    private fun decodePlatformPhoto(source: ImageDecoder.Source, job: Work): ByteArray? {
        val picture = try {
            ImageDecoder.decodeBitmap(source) { decoder, info, _ ->
                job.checkActive()
                val sample = sampleSize(info.size.width, info.size.height, MAX_PHOTO_PIXELS)
                    ?: error("Image too large for background preview")
                decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
                decoder.setTargetSampleSize(sample)
            }
        } catch (_: ImageDecoder.DecodeException) { return job.miss("photo_decode_failed") }
        return try { encode(picture, 1, job) } finally { picture.recycle() }
    }

    private fun decodePhoto(payload: ByteArray, partial: Boolean, job: Work): ByteArray? {
        val exif = runCatching { ExifInterface(ByteArrayInputStream(payload)) }.getOrNull()
        val orientation = exif?.getAttributeInt(ExifInterface.TAG_ORIENTATION, 1) ?: 1
        val data = if (partial) exif?.thumbnail?.takeIf { it.size in 1..65536 } ?: return null else payload
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(data, 0, data.size, bounds)
        if (bounds.outMimeType != "image/jpeg") return null
        val sample = sampleSize(bounds.outWidth, bounds.outHeight) ?: return null
        job.checkActive()
        val bitmap = BitmapFactory.decodeByteArray(data, 0, data.size, BitmapFactory.Options().apply { inSampleSize = sample }) ?: return null
        return try { encode(bitmap, orientation, job) } finally { bitmap.recycle() }
    }

    private fun supportsPhoto(file: File): Boolean = file.extension.lowercase() in MediaKinds.images

    private fun encode(bitmap: Bitmap, orientation: Int, job: Work): ByteArray? {
        job.checkActive()
        val transform = Matrix().apply {
            when (orientation) {
                2 -> setScale(-1f, 1f)
                3 -> setRotate(180f)
                4 -> setScale(1f, -1f)
                5 -> { setRotate(90f); postScale(-1f, 1f) }
                6 -> setRotate(90f)
                7 -> { setRotate(270f); postScale(-1f, 1f) }
                8 -> setRotate(270f)
            }
        }
        val upright = Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, transform, true)
        try {
            val width = minOf(upright.width, (upright.height.toLong() * 320 / 180).toInt().coerceAtLeast(1))
            val height = minOf(upright.height, (upright.width.toLong() * 180 / 320).toInt().coerceAtLeast(1))
            val cropped = Bitmap.createBitmap(upright, (upright.width - width) / 2, (upright.height - height) / 2, width, height)
            try {
                val scaled = Bitmap.createScaledBitmap(cropped, 320, 180, true)
                try {
                    job.checkActive()
                    val buffer = ByteArrayOutputStream()
                    return if (scaled.compress(Bitmap.CompressFormat.JPEG, 82, buffer)) buffer.toByteArray() else null
                } finally { if (scaled !== cropped) scaled.recycle() }
            } finally { if (cropped !== upright) cropped.recycle() }
        } finally { if (upright !== bitmap) upright.recycle() }
    }

    companion object {
        private const val LOCAL_IMAGE_BYTES = 32L * 1024 * 1024
        private const val LOCAL_VIDEO_BYTES = 8 * 1024 * 1024
        private const val NETWORK_IMAGE_BYTES = 4L * 1024 * 1024
        private const val NETWORK_VIDEO_BYTES = 4 * 1024 * 1024
        private const val DLNA_FOLDER_COVER_BYTES = 512 * 1024
        private const val MAX_PHOTO_PIXELS = 128_000_000L

        internal fun sampleSize(width: Int, height: Int, maxPixels: Long = 40_000_000L): Int? {
            if (width !in 1..65535 || height !in 1..65535 || width.toLong() * height > maxPixels) return null
            var sample = 1
            while (maxOf(width, height) / sample > 512) sample *= 2
            return sample
        }
    }
}
