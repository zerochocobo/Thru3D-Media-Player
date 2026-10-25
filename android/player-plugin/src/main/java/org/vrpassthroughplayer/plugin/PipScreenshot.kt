package org.vrpassthroughplayer.plugin

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import org.json.JSONObject
import java.io.File
import java.util.function.BooleanSupplier

internal object PipScreenshotNative {
    private val loaded = try { System.loadLibrary("quest_mpv"); version() == 1 } catch (_: UnsatisfiedLinkError) { false }
    @JvmStatic private external fun version(): Int
    fun available() = loaded
    @JvmStatic external fun compose(source: Bitmap, images: Array<Bitmap>, output: String, mode: IntArray,
                                    windows: FloatArray, cancelled: BooleanSupplier): Boolean
}

/** Small immutable recipe and pinned preview files. No GPU access or second video/PiP source reader. */
internal class PipScreenshot(pip: JSONObject, retain: (Int) -> File?, private val release: (Int) -> Unit) : AutoCloseable {
    private val leases = mutableListOf<Pair<Int, File>>()
    private val parameters = mutableListOf<Float>()
    init {
        try {
            require(pip.getInt("version") == 1)
            val windows = pip.getJSONArray("windows")
            require(windows.length() in 0..3)
            for (i in 0 until windows.length()) {
                val window = windows.getJSONObject(i)
                fun values(key: String, count: Int) {
                    val array = window.getJSONArray(key)
                    require(array.length() == count)
                    for (j in 0 until count) {
                        val value = array.getDouble(j).toFloat()
                        require(value.isFinite() && kotlin.math.abs(value) < 1e8f)
                        parameters.add(value)
                    }
                }
                values("axes", 9); values("anchor", 3); values("left", 3); values("right", 3)
                values("size", 2); values("feather", 2); values("crop", 9); values("tangent", 2)
                val eye = window.getInt("source_eye"); require(eye in 0..1); parameters.add(eye.toFloat())
                val image = window.getJSONObject("image")
                if (image.length() > 0) {
                    val id = image.getInt("id"); require(id > 0)
                    val orientation = image.getInt("orientation"); require(orientation in 1..8)
                    val file = retain(id) ?: error("Picture in picture capture unavailable")
                    parameters.add(leases.size.toFloat()); parameters.add(orientation.toFloat())
                    leases.add(id to file)
                } else { parameters.add(-1f); parameters.add(1f) }
            }
        } catch (error: Throwable) { close(); throw error }
    }
    fun hasWindows() = parameters.isNotEmpty()
    fun packed() = parameters.toFloatArray()
    fun previews() = leases.toList()
    fun compose(source: Bitmap, target: File, mode: JSONObject, cancelled: BooleanSupplier) {
        check(PipScreenshotNative.available()) { "Picture in picture capture unavailable" }
        val images = mutableListOf<Bitmap>()
        try {
            for ((_, file) in leases) {
                check(!cancelled.asBoolean)
                val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                BitmapFactory.decodeFile(file.path, options)
                require(options.outWidth in 1..2048 && options.outHeight in 1..2048)
                images.add(BitmapFactory.decodeFile(file.path, BitmapFactory.Options().apply {
                    inPreferredConfig = Bitmap.Config.ARGB_8888; inScaled = false
                }) ?: error("Picture in picture capture unavailable"))
            }
            val flags = intArrayOf(mode.getInt("geometry"), if (mode.optBoolean("stereo_sbs")) 1 else 0,
                if (mode.optBoolean("top_bottom")) 1 else 0, if (mode.optBoolean("stereo_half")) 1 else 0,
                if (mode.optBoolean("swap_eyes")) 1 else 0, mode.getInt("fisheye_fov"))
            check(!cancelled.asBoolean && PipScreenshotNative.compose(source, images.toTypedArray(), target.path,
                flags, parameters.toFloatArray(), cancelled)) { "Picture in picture capture unavailable" }
        } finally { images.forEach { it.recycle() } }
    }
    override fun close() {
        val held=leases.toList(); leases.clear()
        held.forEach { runCatching { release(it.first) } }
    }
}
