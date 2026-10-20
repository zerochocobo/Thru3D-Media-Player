package org.vrpassthroughplayer.plugin

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.BitmapRegionDecoder
import android.graphics.Rect
import org.json.JSONObject
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

/** Original-pixel region decoding: one bounded tile in flight, never a full 20K bitmap. */
internal class PanoramaRegions(private val context: () -> Context?) {
    private val worker = Executors.newSingleThreadExecutor { r -> Thread(r, "PanoramaRegions") }
    private val epoch = AtomicInteger()
    private val pending = AtomicInteger()
    @Volatile private var state = "{}"
    private var decoder: BitmapRegionDecoder? = null
    private var tiff: File? = null
    private var width = 0
    private var height = 0
    private var directory: File? = null
    @Volatile private var closed = false

    fun open(path: String): Int {
        if (closed) return 0
        val token = epoch.incrementAndGet(); pending.set(0)
        state = JSONObject().put("state", "opening").toString()
        worker.execute {
            detach()
            if (closed || token != epoch.get()) return@execute
            try {
                val app = context() ?: error("No context")
                val file = File(path).canonicalFile
                require(file.path.startsWith(app.cacheDir.canonicalPath + File.separator))
                val raw = PhotoBitmap.rawBounds(file)
                require(file.isFile && (raw!=null || file.length() <= PhotoBridge.MAX_BYTES))
                @Suppress("DEPRECATION")
                val region = if (PhotoBitmap.isTiff(file) || raw!=null) null else (BitmapRegionDecoder.newInstance(file.path, false) ?: error("Unsupported image"))
                val info = if (region == null) PhotoBitmap.bounds(file) else null
                val w = region?.width ?: info!!.outWidth
                val h = region?.height ?: info!!.outHeight
                if (w !in 8192..65535 || h !in 1..65535) { region?.recycle(); error("Unsupported dimensions") }
                if (closed || token != epoch.get()) { region?.recycle(); return@execute }
                decoder = region
                tiff = if (region == null) file else null
                width = w; height = h
                directory = File(app.cacheDir, "panorama-regions/$token").apply { check(mkdirs() || isDirectory) }
                state = JSONObject().put("state", "ready").put("width", width).put("height", height).toString()
            } catch (_: Throwable) {
                detach()
                if (token == epoch.get()) state = JSONObject().put("state", "error").toString()
            }
        }
        return token
    }
    fun snapshot(session: Int): String = if (session == epoch.get() && !closed) state else "{}"
    fun request(session: Int, column: Int, row: Int): Boolean {
        if (closed || session != epoch.get() || !pending.compareAndSet(0, session)) return false
        worker.execute {
            try {
                if (closed || session != epoch.get()) return@execute
                val region = decoder
                val original = tiff
                if (region == null && original == null) return@execute
                val left = column.toLong() * TILE; val top = row.toLong() * TILE
                require(left in 0 until width.toLong() && top in 0 until height.toLong())
                val core = Rect(left.toInt(), top.toInt(), minOf(width, left.toInt() + TILE), minOf(height, top.toInt() + TILE))
                val rectangle = Rect(maxOf(0, core.left - 2), maxOf(0, core.top - 2),
                    minOf(width, core.right + 2), minOf(height, core.bottom + 2))
                val image = if (original != null) PhotoBitmap.region(original, rectangle.left, rectangle.top,
                    rectangle.width(), rectangle.height(), 1, {
                        if (closed || session != epoch.get()) throw InterruptedException()
                    }) else region!!.decodeRegion(rectangle, BitmapFactory.Options().apply {
                    inSampleSize = 1; inPreferredConfig = Bitmap.Config.ARGB_8888; inScaled = false
                }) ?: error("Tile unavailable")
                val file = File(directory ?: error("Closed"), "tile.png")
                try { file.outputStream().use { check(image.compress(Bitmap.CompressFormat.PNG, 100, it)) } }
                finally { image.recycle() }
                if (session == epoch.get() && !closed) state = JSONObject().put("state", "tile")
                    .put("column", column).put("row", row).put("path", file.path)
                    .put("x", rectangle.left).put("y", rectangle.top).put("width", rectangle.width()).put("height", rectangle.height()).toString()
            } catch (_: Throwable) {
                if (session == epoch.get() && !closed) state = JSONObject().put("state", "tile_error")
                    .put("column", column).put("row", row).toString()
            } finally { pending.compareAndSet(session, 0) }
        }
        return true
    }
    fun release(session: Int) {
        if (!epoch.compareAndSet(session, session + 1)) return
        pending.set(0); state = "{}"
        worker.execute { detach() }
    }
    private fun detach() {
        decoder?.recycle(); decoder = null
        tiff = null; width = 0; height = 0
        // Only this component's generated tile directory; never traverses source/media storage.
        directory?.let { File(it, "tile.png").delete(); it.delete() }; directory = null
    }
    fun close() { closed = true; epoch.incrementAndGet(); pending.set(0); worker.execute { detach() }; worker.shutdown() }
    companion object { const val TILE = 1024 }
}
