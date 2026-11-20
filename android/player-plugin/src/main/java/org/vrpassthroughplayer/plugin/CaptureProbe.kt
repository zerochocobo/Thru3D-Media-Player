package org.vrpassthroughplayer.plugin

import android.app.Activity
import android.database.ContentObserver
import android.graphics.Point
import android.hardware.display.DisplayManager
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.view.Display
import android.view.SurfaceView
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import org.json.JSONArray
import org.json.JSONObject

/** QIYU's system screenshots and recordings of this app come out black (user, 2026-11-20). Logs what a
 *  capture may depend on: the window's secure flag and surfaces, every display (a recording adds a virtual
 *  one) and the size and folder of each new screenshot or recording. Logcat only (tag ThruCapture), which
 *  the exported log carries; file names and pixels are never read. Installed on QIYU only. */
internal object CaptureProbe {
    private var displayListener: DisplayManager.DisplayListener? = null
    private var mediaObserver: ContentObserver? = null
    private val shown = HashMap<Int, String>()
    private var lastMedia = ""

    fun install(activity: Activity) = activity.runOnUiThread {
        if (displayListener != null) return@runOnUiThread
        runCatching {
            val displays = activity.getSystemService(DisplayManager::class.java) ?: return@runCatching
            note("window " + window(activity))
            for (display in displays.displays) report(display, "present")
            val watch = object : DisplayManager.DisplayListener {
                override fun onDisplayAdded(id: Int) {
                    displays.getDisplay(id)?.let { report(it, "added") }
                    note("window " + window(activity))
                }
                override fun onDisplayRemoved(id: Int) { shown.remove(id); note("display removed $id") }
                override fun onDisplayChanged(id: Int) { displays.getDisplay(id)?.let { report(it, "changed") } }
            }
            displays.registerDisplayListener(watch, Handler(Looper.getMainLooper()))
            displayListener = watch
        }
        runCatching {
            val resolver = activity.contentResolver
            val observer = object : ContentObserver(Handler(Looper.getMainLooper())) {
                override fun onChange(selfChange: Boolean, uri: Uri?) { newestCapture(activity) }
            }
            resolver.registerContentObserver(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, true, observer)
            resolver.registerContentObserver(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, true, observer)
            mediaObserver = observer
        }
    }

    fun close(activity: Activity) = activity.runOnUiThread {
        runCatching { displayListener?.let { activity.getSystemService(DisplayManager::class.java)?.unregisterDisplayListener(it) } }
        runCatching { mediaObserver?.let { activity.contentResolver.unregisterContentObserver(it) } }
        displayListener = null; mediaObserver = null; shown.clear()
    }

    /** A changed display is logged only when what is recorded about it changed (state, size, flags). */
    private fun report(display: Display, event: String) {
        val text = display(display).toString()
        if (event == "changed" && shown[display.displayId] == text) return
        shown[display.displayId] = text
        note("display $event $text")
    }

    private fun display(display: Display): JSONObject {
        val size = Point().also { display.getRealSize(it) }
        val flags = JSONArray()
        for ((mask, name) in DISPLAY_FLAGS) if (display.flags and mask != 0) flags.put(name)
        return JSONObject().put("id", display.displayId).put("name", display.name).put("flags", flags)
            .put("state", display.state).put("width", size.x).put("height", size.y)
            .put("refresh", display.refreshRate.toDouble()).put("hdr", display.isHdr)
    }

    /** FLAG_SECURE or a secure SurfaceView would turn system captures black. */
    private fun window(activity: Activity): JSONObject {
        val window = activity.window
        val attributes = window?.attributes
        val surfaces = JSONArray()
        window?.decorView?.let { collect(it, surfaces) }
        return JSONObject().put("secure", attributes != null && attributes.flags and WindowManager.LayoutParams.FLAG_SECURE != 0)
            .put("format", attributes?.format ?: 0).put("surfaces", surfaces)
            .put("width", window?.decorView?.width ?: 0).put("height", window?.decorView?.height ?: 0)
    }

    private fun collect(view: View, out: JSONArray) {
        if (view is SurfaceView) {
            // SurfaceView keeps setSecure() in a hidden field; unknown when the platform hides it.
            val flags = runCatching { SurfaceView::class.java.getDeclaredField("mSurfaceFlags").apply { isAccessible = true }.getInt(view) }.getOrNull()
            out.put(JSONObject().put("class", view.javaClass.simpleName).put("width", view.width).put("height", view.height)
                .put("shown", view.isShown).put("secure", flags?.let { it and SURFACE_SECURE != 0 } ?: "unknown"))
        }
        if (view is ViewGroup) for (i in 0 until view.childCount) collect(view.getChildAt(i), out)
    }

    /** The newest image or video when the media store changes: folder, size and age, no file name. */
    private fun newestCapture(activity: Activity) {
        for (uri in listOf(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, MediaStore.Video.Media.EXTERNAL_CONTENT_URI)) runCatching {
            val columns = arrayOf(MediaStore.MediaColumns.RELATIVE_PATH, MediaStore.MediaColumns.WIDTH, MediaStore.MediaColumns.HEIGHT,
                MediaStore.MediaColumns.DATE_ADDED, MediaStore.MediaColumns.SIZE, MediaStore.MediaColumns.MIME_TYPE)
            activity.contentResolver.query(uri, columns, null, null, MediaStore.MediaColumns.DATE_ADDED + " DESC")?.use { row ->
                if (!row.moveToFirst()) return@use
                val added = row.getLong(3)
                val age = System.currentTimeMillis() / 1000 - added
                if (age > 120) return@use
                val text = JSONObject().put("folder", row.getString(0) ?: "").put("width", row.getInt(1)).put("height", row.getInt(2))
                    .put("age_s", age).put("bytes", row.getLong(4)).put("mime", row.getString(5) ?: "").toString()
                if (text != lastMedia) { lastMedia = text; note("media new $text") }
            }
        }.onFailure { note("media query failed ${it.javaClass.simpleName}") }
    }

    private fun note(text: String) { runCatching { android.util.Log.i("ThruCapture", text) } }

    private const val SURFACE_SECURE = 0x80 // SurfaceControl.SECURE
    private val DISPLAY_FLAGS = listOf(Display.FLAG_SECURE to "secure", Display.FLAG_SUPPORTS_PROTECTED_BUFFERS to "protected_buffers",
        Display.FLAG_PRIVATE to "private", Display.FLAG_PRESENTATION to "presentation", Display.FLAG_ROUND to "round")
}
