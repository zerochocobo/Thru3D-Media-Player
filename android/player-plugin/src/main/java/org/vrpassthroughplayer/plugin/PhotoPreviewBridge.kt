package org.vrpassthroughplayer.plugin

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.media.ExifInterface
import android.net.Uri
import org.json.JSONObject
import java.io.Closeable
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger
import kotlin.math.roundToInt

/** A single, cancellable, sampled preview reader, independent of full photos and depth work.
 * Only private files are returned. The caller releases each result after copying the preview. */
internal class PhotoPreviewBridge(
    private val context: () -> Context?,
    private val resolve: (String) -> String,
    private val releaseStream: (String) -> Unit,
    private val cacheName: String = "photo-gallery",
    private val edge: Int = EDGE,
    private val emit: (Int, String) -> Unit,
) : Closeable {
    private val worker = Executors.newSingleThreadExecutor { Thread(it, "PhotoGalleryPreview") }
    private val current = AtomicInteger()
    @Volatile private var closed = false
    @Volatile private var connection: HttpURLConnection? = null
    private val lock = PhotoCache.lock
    private val directories = mutableMapOf<Int, File>()
    private val references = mutableMapOf<Int, Int>()
    private var prepared = false

    fun open(id: Int, uri: String): Boolean {
        if (closed) return false
        current.set(id); connection?.disconnect()
        worker.execute {
            var resolved = ""
            var directory: File? = null
            var published = false
            var phase = "source"
            fun checkCurrent() { if (closed || current.get() != id) throw InterruptedException() }
            try {
                checkCurrent()
                val app = context() ?: error("PHOTO_UNAVAILABLE")
                synchronized(lock) {
                    if (!prepared) {
                        File(app.cacheDir, cacheName).listFiles()?.forEach { it.deleteRecursively() }
                        prepared = true
                    }
                    directory = File(app.cacheDir, "$cacheName/$id").apply { mkdirs() }
                    directories[id] = directory!!
                    references[id] = 1
                }
                val source = File(directory, "source")
                resolved = resolve(uri); checkCurrent()
                val location = Uri.parse(resolved)
                val input = when (location.scheme) {
                    "file" -> File(location.path ?: error("PHOTO_UNAVAILABLE")).inputStream()
                    "content" -> app.contentResolver.openInputStream(location) ?: error("PHOTO_UNAVAILABLE")
                    "http", "https" -> {
                        val http = URL(resolved).openConnection() as HttpURLConnection
                        connection = http; http.connectTimeout = 10000; http.readTimeout = 15000
                        require(http.responseCode in 200..299 && http.contentLengthLong <= PhotoBridge.MAX_BYTES)
                        http.inputStream
                    }
                    else -> error("PHOTO_UNAVAILABLE")
                }
                input.use { stream -> source.outputStream().use { output ->
                    val buffer = ByteArray(65536); var bytes = 0L
                    while (true) {
                        checkCurrent(); val count = stream.read(buffer); if (count < 0) break
                        bytes += count; require(bytes <= PhotoBridge.MAX_BYTES)
                        output.write(buffer, 0, count)
                    }
                } }
                checkCurrent()
                phase = "decode"
                val heif = HeifPhotoInfo.read(source)
                val metadata = JSONObject().put("state", "ready").put("orientation", 1)
                var bitmap: Bitmap
                if (PhotoBitmap.isNative(source)) {
                    val bounds = PhotoBitmap.bounds(source)
                    var sample = 1
                    while (maxOf(bounds.outWidth, bounds.outHeight) / sample > edge * 2) sample *= 2
                    bitmap = PhotoBitmap.region(source, 0, 0, bounds.outWidth, bounds.outHeight, sample, ::checkCurrent)
                    metadata.put("orientation", PhotoBitmap.orientation(source))
                } else if (heif != null) {
                    // Select one eye before Android decodes; no packed stereo or full-size raw allocation.
                    heif.selectPrimary(source, heif.left)
                    bitmap = ImageDecoder.decodeBitmap(ImageDecoder.createSource(source)) { decoder, info, _ ->
                        val size = dimensions(info.size.width, info.size.height, edge)
                        HeifPhotoDecoder.configure8Bit(decoder)
                        decoder.setTargetSize(size.first, size.second)
                    }
                    metadata.put("native_stereo", heif.stereo).put("single_eye", true)
                } else {
                    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                    BitmapFactory.decodeFile(source.path, bounds)
                    require(bounds.outMimeType in setOf("image/jpeg", "image/png", "image/webp"))
                    val size = dimensions(bounds.outWidth, bounds.outHeight, edge)
                    var sample = 1
                    while (maxOf(bounds.outWidth, bounds.outHeight) / sample > edge * 2) sample *= 2
                    val decoded = BitmapFactory.decodeFile(source.path, BitmapFactory.Options().apply { inSampleSize = sample })
                        ?: error("PHOTO_DECODE_FAILED")
                    try { bitmap = Bitmap.createScaledBitmap(decoded, size.first, size.second, true) }
                    catch (error: Throwable) { decoded.recycle(); throw error }
                    if (bitmap !== decoded) decoded.recycle()
                    metadata.put("orientation", runCatching { ExifInterface(source.path).getAttributeInt(ExifInterface.TAG_ORIENTATION, 1) }.getOrDefault(1))
                    val header = source.inputStream().use { stream ->
                        val bytes = ByteArray(minOf(source.length(), 1024L * 1024).toInt()); var count = 0
                        while (count < bytes.size) {
                            checkCurrent(); val n = stream.read(bytes, count, bytes.size - count); if (n < 0) break
                            count += n
                        }
                        String(bytes, 0, count, Charsets.ISO_8859_1)
                    }
                    metadata.put("panorama", header.contains("GPano:ProjectionType=\"equirectangular\"") || header.contains("<GPano:ProjectionType>equirectangular</GPano:ProjectionType>"))
                }
                try {
                    checkCurrent()
                    val fitted = dimensions(bitmap.width, bitmap.height, edge)
                    if (bitmap.width != fitted.first || bitmap.height != fitted.second) {
                        val scaled = Bitmap.createScaledBitmap(bitmap, fitted.first, fitted.second, true)
                        if (scaled !== bitmap) bitmap.recycle()
                        bitmap = scaled
                    }
                    phase = "encode"
                    val preview = File(directory, "preview.png")
                    preview.outputStream().use { require(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) }
                    metadata.put("path", preview.path).put("width", bitmap.width).put("height", bitmap.height)
                    source.delete()
                    checkCurrent(); published = true; emit(id, metadata.toString())
                } finally { bitmap.recycle() }
            } catch (_: InterruptedException) { }
            catch (error: Throwable) {
                if (!closed && current.get() == id) {
                    // No media URI, resolved credentials, file path or provider exception message.
                    android.util.Log.w("QuestPhotoPreview", "request=$id phase=$phase failure=${error.javaClass.simpleName}")
                    emit(id, "{\"state\":\"error\",\"error\":\"PHOTO_UNAVAILABLE\"}")
                }
            } finally {
                connection?.disconnect(); connection = null
                if (uri.startsWith("smb://") || uri.startsWith("cloud://") || uri.startsWith("usb://")) releaseStream(resolved)
                if (!published) { synchronized(lock) { directories.remove(id); references.remove(id) }; directory?.deleteRecursively() }
            }
        }
        return true
    }
    fun cancel(id: Int) { if (current.compareAndSet(id, 0)) connection?.disconnect() }
    /** Pin an already displayed local preview without touching the source or decoding on the caller. */
    fun retain(id: Int): File? = synchronized(lock) {
        val directory = directories[id] ?: return@synchronized null
        references[id] = (references[id] ?: 1) + 1
        File(directory, "preview.png")
    }
    fun release(id: Int) {
        val directory = synchronized(lock) {
            val count = references[id] ?: return@synchronized null
            if (count > 1) { references[id] = count - 1; null }
            else { references.remove(id); directories.remove(id) }
        }
        directory?.deleteRecursively()
    }
    fun cacheDirectories(): Set<File> = synchronized(lock) { directories.values.toSet() }
    override fun close() { closed = true; current.set(0); connection?.disconnect(); worker.shutdownNow() }
    companion object {
        const val EDGE = 512
        fun dimensions(width: Int, height: Int, edge: Int = EDGE): Pair<Int, Int> {
            // Match the full-photo reader. Tall comic pages are sampled before allocating pixels.
            require(width in 1..65535 && height in 1..65535)
            val scale = minOf(1.0, edge.toDouble() / maxOf(width, height))
            return maxOf(1, (width * scale).roundToInt()) to maxOf(1, (height * scale).roundToInt())
        }
    }
}
