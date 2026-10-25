package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import java.io.File

/** Source-time spatial samples. Preview leases outlive window closure and PDF page changes. */
internal class PipClipTimeline(startUs: Long, private val retain: (Int) -> File?, private val release: (Int) -> Unit) : AutoCloseable {
    data class Sample(val us: Long, val recipe: PipScreenshot)
    private val files = linkedMapOf<Int, File>()
    private val samples = mutableListOf(Sample(startUs, PipScreenshot(empty(), { null }, {})))
    private var previous = ""
    var composed = false
        private set
    @Synchronized fun add(us: Long, value: JSONObject) {
        require(us >= samples.last().us) { "Picture in picture recording unavailable" }
        val json = value.toString()
        if (json == previous) return
        check(us == samples.last().us || samples.size < 60_000) { "Picture in picture recording limit reached" }
        val recipe = PipScreenshot(value, { id ->
            files[id] ?: run {
                check(files.size < 128) { "Picture in picture recording limit reached" }
                val file = retain(id) ?: error("Picture in picture capture unavailable")
                files[id] = file
                file
            }
        }, {})
        if (us == samples.last().us) samples.removeAt(samples.lastIndex)
        samples.add(Sample(us, recipe)); previous = json
        composed = composed || recipe.hasWindows()
    }
    @Synchronized fun at(us: Long): PipScreenshot {
        var lo = 0; var hi = samples.size
        while (lo < hi) { val mid = (lo + hi) / 2; if (samples[mid].us <= us) lo = mid + 1 else hi = mid }
        return samples[maxOf(0, lo - 1)].recipe
    }
    @Synchronized override fun close() {
        files.keys.toList().forEach { runCatching { release(it) } }; files.clear(); samples.clear()
    }
    companion object { fun empty() = JSONObject().put("version", 1).put("windows", org.json.JSONArray()) }
}
