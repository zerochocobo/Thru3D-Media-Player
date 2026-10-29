package org.vrpassthroughplayer.plugin

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import org.json.JSONObject
import java.io.File

/** Shell-only integration of the same resolve/status/play operations exposed by the VR menu. */
class WebVideoDiagnosticsReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val request = intent.getStringExtra("request").orEmpty()
        if (!request.matches(Regex("[A-Za-z0-9_-]{1,64}"))) return
        if (intent.getStringExtra("operation") == "browser_capture") { capture(context, request); return }
        if (intent.getStringExtra("operation") == "browser_system_input") { systemInput(context, request); return }
        if (intent.getStringExtra("operation") == "browser_media") {
            val pending = goAsync()
            Thread({
                val result = JSONObject().put("request", request)
                try { result.put("media", DiagnosticRequests.current()?.probeWebBrowserMediaForDiagnostics()).put("ok", true) }
                catch (_: Exception) { result.put("ok", false) }
                finally { writeResult(context, request, result); pending.finish() }
            }, "BrowserMediaProbe").start()
            return
        }
        val result = JSONObject().put("request", request)
        try {
            val plugin = DiagnosticRequests.current() ?: error("Player not running")
            when (intent.getStringExtra("operation")) {
                "resolve" -> result.put("id", plugin.web_video_resolve(intent.getStringExtra("url").orEmpty()))
                "status" -> result.put("video", JSONObject(plugin.web_video_status()))
                "cancel" -> plugin.web_video_cancel()
                "browser_status" -> {
                    val source = JSONObject(plugin.web_browser_status())
                    val safe = JSONObject()
                    for (key in listOf("engine", "progress", "error", "active", "attached", "playing", "generation",
                        "detached_through", "needs_surface", "extension", "videos", "tabs", "native_supported", "editing", "session_ready", "tab_id", "navigation", "focused_window", "operation_error", "live_tabs", "network_capture_enabled", "network_capture_available")) {
                        if (source.has(key)) safe.put(key, source.get(key))
                    }
                    safe.put("page", runCatching { WebVideoPage.parse(source.optString("url")).url }.getOrDefault(""))
                    val windows = org.json.JSONArray()
                    for (entry in source.optJSONArray("windows")?.let { array -> (0 until array.length()).map { array.getJSONObject(it) } }.orEmpty()) {
                        val item = JSONObject()
                        for (key in listOf("id", "tab_id", "navigation", "attached", "generation", "detached_through", "needs_surface", "editing", "error", "progress")) item.put(key, entry.opt(key))
                        windows.put(item)
                    }
                    val tabs = org.json.JSONArray()
                    for (entry in source.optJSONArray("tab_list")?.let { array -> (0 until array.length()).map { array.getJSONObject(it) } }.orEmpty()) {
                        tabs.put(JSONObject().put("id", entry.optInt("id")).put("window", entry.optInt("window")).put("sleeping", entry.optBoolean("sleeping")).put("protected", entry.optBoolean("protected")))
                    }
                    safe.put("windows", windows).put("tab_list", tabs)
                    result.put("browser", safe)
                }
                "browser_command" -> {
                    val action = intent.getStringExtra("command").orEmpty()
                    require(action in setOf("new", "select", "close", "detach", "merge", "focus"))
                    plugin.web_browser_command(JSONObject().put("action", action).put("window", intent.getIntExtra("window", 1))
                        .put("tab", intent.getIntExtra("tab", 0)).toString())
                }
                "browser_ui" -> {
                    val step = intent.getStringExtra("step").orEmpty()
                    require(step in setOf("open", "handoff", "close", "click", "scroll", "key", "window_state"))
                    val url = intent.getStringExtra("url").orEmpty()
                    require(url.length <= 4096)
                    if (step == "open") result.put("page", runCatching { WebVideoPage.parse(url).url }.getOrDefault(""))
                    result.put("id", plugin.requestMpvPlayerCommand(JSONObject().put("operation", "web_browser_ui")
                        .put("request_key", request).put("step", step).put("url", url)
                        .put("x", intent.getFloatExtra("x", 0.5f).toDouble())
                        .put("y", intent.getFloatExtra("y", 0.5f).toDouble())
                        .put("target", intent.getIntExtra("target", 0))
                        .put("scroll", intent.getFloatExtra("scroll", -1f).toDouble()).toString()))
                }
                "play" -> {
                    val state = JSONObject(plugin.web_video_status())
                    check(state.optString("state") == "ready")
                    result.put("id", plugin.requestMpvPlayerCommand(JSONObject().put("operation", "open")
                        .put("request_key", request).put("uri", state.getString("uri")).put("title", state.getString("title"))
                        .put("profile", "256x144").put("enabled", false).put("stereo", false).put("position_ms", 0).toString()))
                }
                else -> error("Invalid operation")
            }
            result.put("ok", true)
        } catch (_: Exception) { result.put("ok", false).put("error", "Web video diagnostic unavailable") }
        writeResult(context, request, result)
    }

    private fun systemInput(context: Context, request: String) {
        val pending = goAsync()
        val claimed = java.util.concurrent.atomic.AtomicBoolean()
        fun complete(value: JSONObject?) {
            if (!claimed.compareAndSet(false, true)) return
            try {
                writeResult(context, request, JSONObject().put("request", request)
                    .put("ok", value != null).put("input", value))
            } finally { pending.finish() }
        }
        android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({ complete(null) }, 8000)
        try {
            val plugin = DiagnosticRequests.current()
            if (plugin == null) complete(null) else plugin.probeWebBrowserSystemInput(::complete)
        } catch (_: Exception) { complete(null) }
    }

    private fun capture(context: Context, request: String) {
        val pending = goAsync()
        val claimed = java.util.concurrent.atomic.AtomicBoolean()
        fun complete(bitmap: android.graphics.Bitmap?) {
            if (!claimed.compareAndSet(false, true)) { bitmap?.recycle(); return }
            Thread({
                val result = JSONObject().put("request", request).put("ok", false)
                try {
                    check(bitmap != null && bitmap.width > 0 && bitmap.height > 0)
                    val directory = File(context.filesDir, "diagnostics").apply { mkdirs() }
                    val name = "browser_$request.png"
                    File(directory, name).outputStream().use { check(bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it)) }
                    result.put("ok", true).put("file", name).put("width", bitmap.width).put("height", bitmap.height)
                        .put("scope", "Gecko producer pixels; not XR compositor capture")
                } catch (_: Exception) { result.put("error", "Browser capture unavailable") }
                finally {
                    bitmap?.recycle()
                    try { writeResult(context, request, result) } finally { pending.finish() }
                }
            }, "WebBrowserCapture").start()
        }
        android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({ complete(null) }, 8000)
        val plugin = DiagnosticRequests.current()
        if (plugin == null) complete(null) else plugin.captureWebBrowserForDiagnostics(::complete)
    }

    private fun writeResult(context: Context, request: String, result: JSONObject) {
        val directory = File(context.filesDir, "diagnostics").apply { mkdirs() }
        val temporary = File(directory, "web_video_$request.tmp")
        try {
            temporary.writeText(result.toString())
            check(temporary.renameTo(File(directory, "web_video_$request.json")))
        } finally { temporary.delete() }
    }
}
