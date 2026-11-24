package org.vrpassthroughplayer.plugin

import java.util.concurrent.Executors

/** Match GPU-process samples to a visible tab's completed GeckoDisplay request. */
object DouyinFrameEvidence {
    const val SIDE = 17
    private const val ROW = SIDE * 6
    private const val GRID = SIDE * ROW
    // bt709=1: WebRender drew the video with its own BT.709 conversion, the Surface read with the driver's.
    private val pair = Regex("""paired side=17 surface=(\d+) generation=([1-9]\d*) timestamp_ns=(\d+) pts_us=(\d+) boot_ns=(\d+) surface_rgb=([0-9a-f]{$GRID}) webrender_rgb=([0-9a-f]{$GRID}) bt709=([01])""")
    private class Capture(val owner: String, val start: Long, val end: Long, val rgb: String) {
        @Volatile var native: String? = null
    }
    private val captures = ArrayDeque<Capture>()
    private var nextRequest = 0L
    private var activeRequest = 0L
    // Quest 3 keeps 256 KiB of main log: a Douyin feed pushes a sample's 3.6 KB line, and the decoder's
    // format, out within minutes. Both are read as each capture completes and kept until the export.
    private val reader = Executors.newSingleThreadExecutor { Thread(it, "DouyinFrameEvidence").apply { isDaemon = true } }
    internal var logcat: (List<String>) -> String = { filter ->
        val process = ProcessBuilder(listOf("logcat", "-d", "-v", "threadtime") + filter).redirectErrorStream(true).start()
        process.inputStream.bufferedReader().readText().also { process.waitFor() }
    }
    private val codecLines = LinkedHashSet<String>()

    // The native log has a draw timestamp but no application request ID.
    @Synchronized internal fun beginRequest(): Long? {
        if (activeRequest != 0L) return null
        activeRequest = ++nextRequest
        return activeRequest
    }

    @Synchronized internal fun finishRequest(request: Long) {
        if (activeRequest == request) activeRequest = 0L
    }

    @Synchronized fun clear() { captures.clear(); codecLines.clear() }

    /** Decoder events and formats read while capturing, oldest first; the exporter adds what is still in the log. */
    @Synchronized fun codecLines(): String = codecLines.joinToString("\n")

    @Synchronized fun record(owner: String, start: Long, end: Long, pixels: IntArray) {
        require(pixels.size == SIDE * SIDE)
        val hex = "0123456789abcdef"
        val rgb = buildString(GRID) {
            for (pixel in pixels) for (shift in 20 downTo 0 step 4) append(hex[(pixel ushr shift) and 15])
        }
        if (captures.size == 48) captures.removeFirst()
        val capture = Capture(owner, start, end, rgb)
        captures.addLast(capture)
        reader.execute { keep(capture) }
    }

    /** Tests: waits until the captures recorded so far have read the log. */
    internal fun drain() { reader.submit {}.get() }

    /** Reads the capture's native line, and the decoder lines so far, while the log still holds them. */
    private fun keep(capture: Capture) {
        runCatching {
            capture.native = rows(logcat(listOf("-t", "4096", "Thru3DGeckoFrame:I", "*:S")))
                .filter { it.first in capture.start..capture.end }.singleOrNull()?.second?.get(0)
            val codec = logcat(listOf("-t", "1024", "Thru3DCodecFault:I", "Thru3DCodecFormat:I", "*:S")).lineSequence()
                .filter { it.contains("Thru3DCodecFault:") || it.contains("Thru3DCodecFormat:") }.toList()
            synchronized(this) {
                codecLines.addAll(codec)
                while (codecLines.size > 256) codecLines.remove(codecLines.first())
            }
        }
    }

    private fun rows(log: String) = log.lineSequence().mapNotNull { line ->
        val body = line.substringAfter("Thru3DGeckoFrame:", "").trim()
        val fields = pair.matchEntire(body)?.groupValues ?: return@mapNotNull null
        val ts = fields[3].toLongOrNull() ?: return@mapNotNull null
        val at = fields[5].toLongOrNull() ?: return@mapNotNull null
        if (ts / 1000 != fields[4].toLongOrNull()) return@mapNotNull null
        at to fields
    }.toList()

    fun export(log: String): String {
        val samples = synchronized(this) { captures.toList() }
        val rows = rows(log)
        return samples.joinToString("\n") { capture ->
            val kept = capture.native?.let { pair.matchEntire(it)?.groupValues }
            val found = kept ?: rows.filter { it.first in capture.start..capture.end }.singleOrNull()?.second
            when {
                found == null -> "${capture.owner} unpaired=no_unique_native_sample"
                found[7] != capture.rgb && found[7].chunked(ROW).asReversed().joinToString("") != capture.rgb ->
                    "${capture.owner} unpaired=display_pixels_differ"
                else -> "${capture.owner} ${found[0]}"
            }
        }.ifEmpty { "(no completed video-region requests)" }
    }
}
