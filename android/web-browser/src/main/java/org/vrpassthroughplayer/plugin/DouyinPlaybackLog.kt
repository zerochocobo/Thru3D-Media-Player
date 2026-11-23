package org.vrpassthroughplayer.plugin

import android.graphics.Color
import android.graphics.Rect
import android.os.SystemClock
import org.json.JSONArray
import org.json.JSONObject
import org.mozilla.geckoview.GeckoDisplay
import org.vrpassthroughplayer.browser.BuildConfig

/** Temporary reporter build. Each request describes one visible video in the active tab. */
class DouyinPlaybackLog {
    companion object {
        val enabled: Boolean get() = BuildConfig.DOUYIN_PLAYBACK_LOG
        fun document(url: String) = enabled && (WebBrowserDouyin.document(url) ||
            url == "http://127.0.0.1:18769/thru3d-frame-control.html")
    }

    private var lastRequest = -10_000L
    private var pending = false
    private var sequence = 0L
    private var currentOwner = ""
    private val attempts = mutableMapOf<String, Int>()
    private var requests = 0
    private val reportedErrors = mutableSetOf<String>()

    fun observe(items: JSONArray, display: GeckoDisplay, width: Int, height: Int, tab: Int, nav: Long,
                stillVisible: () -> Boolean) {
        val videos = (0 until minOf(items.length(), 16)).mapNotNull { items.optJSONObject(it) }
        for (item in videos) {
            if (item.optBoolean("protected")) continue
            val state = WebBrowserCaptureDiagnostics.playback(item)
            val code = state.optInt("error_code", 0)
            if (code !in 1..4) continue
            val key = "tab=$tab nav=$nav video=${item.optLong("id")} epoch=${item.optLong("network_epoch")} html_media_error=$code"
            if (reportedErrors.size < 16 && reportedErrors.add(key)) {
                WebBrowserTrail.mark("web.douyin_error", "$key ready=${state.optInt("ready_state", -1)} network=${state.optInt("network_state", -1)}", force = true)
            }
        }
        val candidates = videos.mapNotNull { item ->
            if (item.optBoolean("protected") || item.optInt("width") <= 0 || item.optInt("height") <= 0) return@mapNotNull null
            val rect = centralCrop(item, width, height) ?: return@mapNotNull null
            item to rect
        }
        val candidate = candidates.singleOrNull()
        if (candidate == null || videos.any { it.optBoolean("protected") }) {
            currentOwner = ""
            return
        }
        val (item, rect) = candidate
        val video = item.optLong("id", -1)
        val epoch = item.optLong("network_epoch", -1)
        if (video <= 0 || epoch <= 0) { currentOwner = ""; return }
        val owner = "tab=$tab nav=$nav video=$video epoch=$epoch"
        val ownerChanged = currentOwner != owner
        currentOwner = owner
        val now = SystemClock.uptimeMillis()
        val count = attempts[owner] ?: 0
        if (requests >= 24 || count >= 3) return
        if (!ownerChanged && now - lastRequest < (if (pending) 5000L else 1000L)) return
        attempts[owner] = count + 1
        requests++
        val request = ++sequence
        lastRequest = now
        pending = true
        val stats = WebBrowserCaptureDiagnostics.playback(item)
        val track = item.optJSONObject("douyin")
        val clipId = track?.optString("active_id")?.takeIf { it.matches(Regex("[0-9]{15,20}")) }
        val revision = track?.optString("revision")?.takeIf { it.matches(Regex("[a-f0-9]{8}")) }
        val selection = if (clipId != null && revision != null) "clip=$clipId track=$revision" else "track=unbound"
        val detail = "$owner request=$request time_ms=${(item.optDouble("time", 0.0) * 1000).toLong()} " +
            "$selection video_size=${item.optInt("width")}x${item.optInt("height")} ready=${stats.optInt("ready_state",-1)} " +
            "decoded=${stats.optLong("decoded_frames",-1)} shown=${stats.optLong("presented_frames",-1)} " +
            "dropped=${stats.optLong("dropped_frames",-1)}"
        fun record(result: String) {
            if (sequence != request) return
            pending = false
            if (stillVisible() && currentOwner == owner) {
                WebBrowserTrail.mark("web.douyin_video", "$detail capture_ms=${SystemClock.uptimeMillis()-now} $result", force = true)
            }
        }
        val side = DouyinFrameEvidence.SIDE
        val start = SystemClock.elapsedRealtimeNanos()
        runCatching { display.screenshot().source(rect).size(side, side).capture() }
            .onSuccess { result -> result.accept({ bitmap ->
                if (bitmap == null) record("gecko=empty") else try {
                    val end = SystemClock.elapsedRealtimeNanos()
                    val pixels = IntArray(side * side)
                    bitmap.getPixels(pixels, 0, side, 0, 0, side, side)
                    if (sequence == request && currentOwner == owner && stillVisible()) {
                        DouyinFrameEvidence.record(detail, start, end, pixels)
                    }
                    val purple = pixels.count { pixel ->
                        val r = Color.red(pixel); val g = Color.green(pixel); val b = Color.blue(pixel)
                        r >= 20 && b >= 20 && g + 15 < minOf(r,b) && kotlin.math.abs(r-b) <= 35
                    }
                    record("gecko_center=%06x purple_pixels=%d/%d".format(pixels[pixels.size / 2] and 0xffffff, purple, pixels.size))
                } catch (error: RuntimeException) {
                    record("gecko_read_error=${error.javaClass.simpleName}")
                } finally { bitmap.recycle() }
            }, { error -> record("gecko_error=${error?.javaClass?.simpleName ?: "unknown"}") }) }
            .onFailure { record("gecko_error=${it.javaClass.simpleName}") }
    }

    private fun centralCrop(item: JSONObject, width: Int, height: Int): Rect? {
        val box = item.optJSONArray("douyin_visible_rect") ?: return null
        val (left, top, right, bottom) = (0..3).map { box.optDouble(it) }
        if (listOf(left, top, right, bottom).any { !it.isFinite() || it !in 0.0..1.0 }) return null
        if ((right-left)*width < 32 || (bottom-top)*height < 32) return null
        val dx = (right-left)*0.25
        val dy = (bottom-top)*0.25
        return Rect(((left+dx)*width).toInt(), ((top+dy)*height).toInt(),
            ((right-dx)*width).toInt(), ((bottom-dy)*height).toInt())
    }
}
