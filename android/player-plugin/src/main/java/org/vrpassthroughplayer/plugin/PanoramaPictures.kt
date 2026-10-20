package org.vrpassthroughplayer.plugin

import android.content.ContentValues
import android.content.Context
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Environment
import android.provider.MediaStore
import org.json.JSONObject
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** A user-requested, byte-for-byte original copy into public Pictures, independent of the preview. */
internal class PanoramaPictures(private val context: () -> Context?, private val originals: PanoramaOriginals) {
    private val worker = Executors.newSingleThreadExecutor { r -> Thread(r, "PanoramaPictures") }
    private val busy = AtomicBoolean()
    @Volatile private var state = "{}"
    @Volatile private var closed = false
    fun snapshot(): String = state
    @Synchronized fun save(source: String, title: String, spherical: Boolean): Boolean {
        if (closed || !busy.compareAndSet(false, true)) return false
        val retained = originals.retain(source)
        if (retained == null) { busy.set(false); return false }
        state = JSONObject().put("state", "saving").put("source", source).toString()
        worker.execute {
            var pending: Uri? = null
            var app: Context? = null
            try {
                app = context() ?: error("No context")
                val uri = Uri.parse(source)
                require(uri.scheme == "file" && uri.authority.isNullOrEmpty())
                val file = File(uri.path ?: error("No file")).canonicalFile
                val root = File(app.filesDir, "online-panoramas").canonicalFile
                require(file.parentFile == root && file.isFile && file.length() in 1..PhotoBridge.MAX_BYTES)
                val bounds = PhotoBitmap.bounds(file)
                val mime = bounds.outMimeType
                require(mime in PanoramaWebPolicy.imageTypes && PanoramaWebPolicy.highResolution(bounds.outWidth, bounds.outHeight))
                val name = PanoramaPictureName.make(title, mime, spherical && bounds.outWidth == 2 * bounds.outHeight)
                val resolver = app.contentResolver
                val values = ContentValues().apply {
                    put(MediaStore.Images.Media.DISPLAY_NAME, name)
                    put(MediaStore.Images.Media.MIME_TYPE, mime)
                    put(MediaStore.Images.Media.WIDTH, bounds.outWidth)
                    put(MediaStore.Images.Media.HEIGHT, bounds.outHeight)
                    put(MediaStore.Images.Media.RELATIVE_PATH, Environment.DIRECTORY_PICTURES + "/Thru3D")
                    put(MediaStore.Images.Media.IS_PENDING, 1)
                }
                pending = resolver.insert(MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY), values)
                    ?: error("Insert failed")
                var count = 0L
                file.inputStream().use { input ->
                    resolver.openOutputStream(pending, "w")?.use { output ->
                        val buffer = ByteArray(64 * 1024)
                        while (true) {
                            if (closed) throw InterruptedException()
                            val read = input.read(buffer); if (read < 0) break
                            output.write(buffer, 0, read); count += read
                        }
                    } ?: error("No output")
                }
                check(count == file.length() && !closed)
                check(resolver.update(pending, ContentValues().apply { put(MediaStore.Images.Media.IS_PENDING, 0) }, null, null) == 1)
                state = JSONObject().put("state", "saved").put("source", source).put("uri", pending.toString())
                    .put("name", name).put("directory", "Pictures/Thru3D").put("bytes", count)
                    .put("width", bounds.outWidth).put("height", bounds.outHeight).toString()
                pending = null
            } catch (_: Throwable) {
                state = JSONObject().put("state", "error").put("source", source).put("error", "Could not save image").toString()
            } finally {
                pending?.let { uri -> runCatching { app?.contentResolver?.delete(uri, null, null) } }
                originals.release(retained)
                busy.set(false)
            }
        }
        return true
    }
    @Synchronized fun close() { closed = true; worker.shutdown() }
}
