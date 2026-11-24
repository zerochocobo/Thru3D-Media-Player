package org.vrpassthroughplayer.plugin

/** Match GPU-process samples to a visible tab's completed GeckoDisplay request. */
object DouyinFrameEvidence {
    const val SIDE = 17
    private const val ROW = SIDE * 6
    private const val GRID = SIDE * ROW
    // bt709=1: WebRender drew the video with its own BT.709 conversion, the Surface read with the driver's.
    private val pair = Regex("""paired side=17 surface=(\d+) generation=([1-9]\d*) timestamp_ns=(\d+) pts_us=(\d+) boot_ns=(\d+) surface_rgb=([0-9a-f]{$GRID}) webrender_rgb=([0-9a-f]{$GRID}) bt709=([01])""")
    private data class Capture(val owner: String, val start: Long, val end: Long, val rgb: String)
    private val captures = ArrayDeque<Capture>()
    private var nextRequest = 0L
    private var activeRequest = 0L

    // The native log has a draw timestamp but no application request ID.
    @Synchronized internal fun beginRequest(): Long? {
        if (activeRequest != 0L) return null
        activeRequest = ++nextRequest
        return activeRequest
    }

    @Synchronized internal fun finishRequest(request: Long) {
        if (activeRequest == request) activeRequest = 0L
    }

    @Synchronized fun clear() = captures.clear()

    @Synchronized fun record(owner: String, start: Long, end: Long, pixels: IntArray) {
        require(pixels.size == SIDE * SIDE)
        val hex = "0123456789abcdef"
        val rgb = buildString(GRID) {
            for (pixel in pixels) for (shift in 20 downTo 0 step 4) append(hex[(pixel ushr shift) and 15])
        }
        if (captures.size == 48) captures.removeFirst()
        captures.addLast(Capture(owner, start, end, rgb))
    }

    fun export(log: String): String {
        val samples = synchronized(this) { captures.toList() }
        val rows = log.lineSequence().mapNotNull { line ->
            val body = line.substringAfter("Thru3DGeckoFrame:", "").trim()
            val fields = pair.matchEntire(body)?.groupValues ?: return@mapNotNull null
            val ts = fields[3].toLongOrNull() ?: return@mapNotNull null
            val at = fields[5].toLongOrNull() ?: return@mapNotNull null
            if (ts / 1000 != fields[4].toLongOrNull()) return@mapNotNull null
            at to fields
        }.toList()
        return samples.joinToString("\n") { capture ->
            val found = rows.filter { it.first in capture.start..capture.end }.singleOrNull()?.second
            when {
                found == null -> "${capture.owner} unpaired=no_unique_native_sample"
                found[7] != capture.rgb && found[7].chunked(ROW).asReversed().joinToString("") != capture.rgb ->
                    "${capture.owner} unpaired=display_pixels_differ"
                else -> "${capture.owner} ${found[0]}"
            }
        }.ifEmpty { "(no completed video-region requests)" }
    }
}
