package org.vrpassthroughplayer.plugin

import java.net.URI
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Why a page shows white, from a Release log: Gecko load/paint/crash, display Surfaces, composites,
 * media and Godot's layer ("web." crash-trail steps), each line written when its state changes.
 * Lines go to logcat (tag Thru3DWeb) and a ring the exported log prints whole (DiagnosticLogs).
 * Hosts only while playback diagnostics are allowed ([hosts]); never paths, queries, titles or cookies.
 */
object WebBrowserTrail {
    const val TAG = "Thru3DWeb"
    private const val SLOTS = 240
    private const val BURST_MS = 10_000L
    private const val BURST_LINES = 40
    @Volatile var hosts = true
    internal var clock: () -> Long = System::currentTimeMillis
    internal var sink: (String) -> Unit = { line -> runCatching { android.util.Log.i(TAG, line) } }
    private val lines = ArrayDeque<Pair<Long, String>>()
    private val last = HashMap<String, String>()
    private var burstStart = 0L
    private var burstCount = 0
    private var dropped = 0
    /** Each window's live state, refreshed by the browser while a page is shown (the "now" lines). */
    @Volatile private var snapshot: List<String> = emptyList()

    /** One step. [force] skips the burst cap: crashes and white verdicts are never dropped. */
    @Synchronized fun mark(stage: String, detail: String = "", force: Boolean = false) {
        val now = clock()
        if (now - burstStart >= BURST_MS) { burstStart = now; burstCount = 0 }
        if (!force && burstCount >= BURST_LINES) { dropped++; return }
        burstCount++
        var text = stage + (if (detail.isEmpty()) "" else " $detail")
        if (dropped > 0) { text += " dropped=$dropped"; dropped = 0 }
        if (lines.size == SLOTS) lines.removeFirst()
        lines.addLast(now to text)
        sink(text)
    }

    /** [mark] only when [key]'s [signature] (by default the detail) differs from the last one recorded for it. */
    @Synchronized fun change(key: String, stage: String, detail: String, signature: String = detail): Boolean {
        if (last[key] == signature) return false
        last[key] = signature
        mark(stage, detail)
        return true
    }

    fun publish(windows: List<String>) { snapshot = windows }

    /** The recent steps, oldest first, then the live state of each shown window. */
    fun recent(): List<String> {
        val time = SimpleDateFormat("HH:mm:ss.SSS", Locale.US)
        val steps = synchronized(this) { lines.toList() }
        return steps.map { time.format(Date(it.first)) + " " + it.second } + snapshot.map { "now " + it }
    }

    @Synchronized fun clear() { lines.clear(); last.clear(); dropped = 0; burstCount = 0; snapshot = emptyList() }

    /** Scheme and host, masked while diagnostics are private; "blank" for about: pages. */
    fun host(url: String): String {
        if (url.isEmpty() || url.startsWith("about:")) return "blank"
        if (!hosts) return "***"
        val parsed = runCatching { URI(url) }.getOrNull()
        return parsed?.host?.let { parsed.scheme + "://" + it } ?: (parsed?.scheme ?: "invalid")
    }

    private val categories = mapOf(1 to "unknown", 2 to "security", 3 to "network", 4 to "content", 5 to "uri", 6 to "proxy", 7 to "safebrowsing")
    fun errorCategory(category: Int): String = categories[category] ?: "c$category"
}

/**
 * One tab's paint evidence for the white-page verdict (uptime ms). A page can be idle without
 * composites, so only conditions that should have painted count: a bound Surface that never
 * received a frame, a loaded document without a contentful paint, decoding video without frames,
 * or a load error that left the document blank.
 */
internal class WebBrowserRenderWatch {
    companion object {
        const val SURFACE_GRACE_MS = 5_000L
        const val PAINT_GRACE_MS = 8_000L
        const val MEDIA_GRACE_MS = 5_000L
        const val NO_FRAME = "no_frame_since_surface"
        const val NO_PAINT = "no_contentful_paint"
        const val MEDIA = "video_decoding_no_frame"
        const val LOAD_ERROR = "load_error_blank"
        const val HITCH_MS = 100L
        const val PERF_WINDOW_MS = 10_000L
    }
    class Verdict(val fresh: List<String>, val recovered: List<String>)
    /** One perf window: page composites per second, the longest gap and gaps of [HITCH_MS] or more while
     * video decodes (an idle page legitimately stops compositing), and the video's own frame rates. */
    class Perf(val seconds: Double, val composites: Double, val maxGapMs: Long, val hitches: Int,
               val decodedRate: Double, val presentedRate: Double, val dropped: Long) {
        private fun rate(value: Double) = String.format(Locale.US, "%.1f", value)
        override fun toString() = "fps=${rate(composites)} max_gap_ms=$maxGapMs hitches=$hitches " +
            "video_decoded_fps=${rate(decodedRate)} video_shown_fps=${rate(presentedRate)} video_dropped=$dropped window_s=${rate(seconds)}"
        /** Coarse buckets: a steady page logs once, a change of a few frames per second does not repeat it. */
        fun signature(): String = listOf(Math.round(composites / 5), Math.round(presentedRate / 5),
            when { dropped == 0L -> 0; dropped < 10 -> 1; dropped < 60 -> 2; else -> 3 },
            when { hitches == 0 -> 0; hitches < 3 -> 1; hitches < 10 -> 2; else -> 3 }).joinToString(":")
    }
    var bound = false; private set
    var boundAt = 0L; private set
    var draws = 0L; private set
    var lastDraw = 0L; private set
    var composite = false; private set
    var contentfulPaint = false; private set
    var loadError = false; private set
    var pageStopAt = 0L; private set
    var pageOk = false; private set
    private var playing = false
    private var decoded = -1L
    private var decodedAt = 0L
    private val reported = linkedSetOf<String>()
    private var perfStart = 0L
    private var perfDraws = 0
    private var perfMaxGap = 0L
    private var perfHitches = 0
    /** Decoded, presented and dropped video frames: the latest report and the window's first one. */
    private val frames = LongArray(3)
    private var framesAtStart: LongArray? = null
    var lastPerf = ""; private set

    /** A reported page verdict then shows as recovered: the next document starts its own episode. */
    fun pageStart() { pageStopAt = 0; pageOk = false; loadError = false; composite = false; contentfulPaint = false }
    fun pageStop(now: Long, ok: Boolean) { pageStopAt = now; pageOk = ok }
    fun loadFailed(now: Long) { loadError = true; pageStopAt = now; pageOk = false }
    fun firstComposite() { composite = true }
    fun contentfulPaint() { contentfulPaint = true }
    /** Gecko recomposites after a reset; the document's contentful paint does not repeat. */
    fun paintReset() { composite = false }
    fun bind(now: Long) {
        bound = true; boundAt = now; draws = 0; reported.remove(NO_FRAME); reported.remove(MEDIA)
        perfStart = now; perfDraws = 0; perfMaxGap = 0; perfHitches = 0; framesAtStart = null
    }
    fun unbind() { bound = false }
    fun draw(now: Long) {
        if (lastDraw > 0 && decodingAt(now)) {
            val gap = now - maxOf(lastDraw, perfStart)
            perfMaxGap = maxOf(perfMaxGap, gap)
            if (gap >= HITCH_MS) perfHitches++
        }
        draws++; perfDraws++; lastDraw = now
    }
    fun media(now: Long, isPlaying: Boolean, decodedFrames: Long, presentedFrames: Long = 0, droppedFrames: Long = 0) {
        if (decodedFrames != decoded) { if (decoded >= 0) decodedAt = now; decoded = decodedFrames }
        playing = isPlaying
        frames[0] = decodedFrames; frames[1] = presentedFrames; frames[2] = droppedFrames
        if (framesAtStart == null) framesAtStart = frames.copyOf()
    }

    /** The window since the previous call, once [PERF_WINDOW_MS] has passed; null while unbound, early or idle. */
    fun perf(now: Long): Perf? {
        if (!bound || now - perfStart < PERF_WINDOW_MS) return null
        val seconds = (now - perfStart) / 1000.0
        val start = framesAtStart
        // A new video restarts its counters: count that window from zero rather than negative.
        fun delta(index: Int) = if (start == null) 0L else (frames[index] - start[index]).let { if (it < 0) frames[index] else it }
        val result = Perf(seconds, perfDraws / seconds, perfMaxGap, perfHitches, delta(0) / seconds, delta(1) / seconds, delta(2))
        perfStart = now; perfDraws = 0; perfMaxGap = 0; perfHitches = 0; framesAtStart = if (start == null) null else frames.copyOf()
        if (result.composites == 0.0 && result.decodedRate == 0.0) return null
        lastPerf = result.toString()
        return result
    }
    fun decodingAt(now: Long): Boolean = playing && decodedAt > 0 && now - decodedAt < 3_000

    fun verdict(now: Long): Verdict {
        if (!bound) return Verdict(emptyList(), emptyList())
        val found = buildSet {
            if (loadError) add(LOAD_ERROR)
            if (draws == 0L && now - boundAt >= SURFACE_GRACE_MS) add(NO_FRAME)
            if (pageOk && !contentfulPaint && now - maxOf(pageStopAt, boundAt) >= PAINT_GRACE_MS) add(NO_PAINT)
            if (decodingAt(now) && now - maxOf(lastDraw, boundAt) >= MEDIA_GRACE_MS) add(MEDIA)
        }
        val recovered = reported.filter { it !in found }
        reported.removeAll(recovered.toSet())
        return Verdict(found.filter { reported.add(it) }, recovered)
    }
}

/** Colour statistics of a captured page: no content leaves the device, only ratios and counts. */
internal object WebBrowserPixelProbe {
    fun describe(pixels: IntArray): String {
        if (pixels.isEmpty()) return "samples=0"
        var white = 0; var black = 0
        val counts = HashMap<Int, Int>()
        for (pixel in pixels) {
            val r = pixel shr 16 and 0xff; val g = pixel shr 8 and 0xff; val b = pixel and 0xff
            if (r >= 240 && g >= 240 && b >= 240) white++
            if (r <= 15 && g <= 15 && b <= 15) black++
            val key = (r shr 4 shl 8) or (g shr 4 shl 4) or (b shr 4)
            counts[key] = (counts[key] ?: 0) + 1
        }
        val n = pixels.size.toDouble()
        fun ratio(value: Int) = String.format(Locale.US, "%.2f", value / n)
        return "samples=${pixels.size} white=${ratio(white)} black=${ratio(black)} dominant=${ratio(counts.values.max())} colors=${counts.size}"
    }
}
