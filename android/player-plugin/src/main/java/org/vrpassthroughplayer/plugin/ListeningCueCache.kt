package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest

/** Recognized original-language cues for one video, so seeking back or watching
 * again skips transcribing media time that was already covered. The key binds
 * the video, its duration, language and the exact speech model; a model upgrade
 * or schema change never reuses old entries. Only original text is kept;
 * translations stay in memory. Disk writes only when the caller's per-file
 * settings policy allows; otherwise the coverage lives for this playback only. */
internal class ListeningCueCache(private val directory: File?, val key: String, private val network: Boolean) {
    private val cues = ArrayList<ListeningPolicy.Cue>() // sorted by start
    private val covered = ArrayList<DoubleArray>()      // merged [start, end)
    private var dirty = false
    private var full = false
    private var written = 0L
    val persistent get() = directory != null

    /** End of the covered interval containing [at], if any. */
    fun coveredEnd(at: Double): Double? = covered.firstOrNull { at >= it[0] - .25 && at < it[1] }?.get(1)

    fun cues(from: Double, to: Double): List<ListeningPolicy.Cue> {
        var low = 0; var high = cues.size
        while (low < high) { val mid = (low + high) ushr 1; if (cues[mid].start < from - 15) low = mid + 1 else high = mid }
        val result = ArrayList<ListeningPolicy.Cue>()
        for (i in low until cues.size) { val cue = cues[i]; if (cue.start >= to) break; if (cue.end > from) result.add(cue) }
        return result
    }

    fun add(cue: ListeningPolicy.Cue) {
        if (full) return
        var at = cues.binarySearchBy(cue.start) { it.start }.let { if (it < 0) -it - 1 else it }
        // Streaming updates may repeat a finished line; keep one per time span.
        while (at > 0 && cues[at - 1].start == cue.start) at--
        if (at < cues.size && cues[at].start == cue.start && cues[at].end == cue.end) { if (cues[at] == cue) return; cues[at] = cue }
        else cues.add(at, cue)
        if (cues.size > MAX_CUES) full = true
        dirty = true
    }

    fun cover(start: Double, end: Double) {
        if (full || !(end > start) || !start.isFinite() || !end.isFinite()) return
        var a = start; var b = end
        val iterator = covered.iterator()
        while (iterator.hasNext()) { val span = iterator.next(); if (span[1] >= a && span[0] <= b) { a = minOf(a, span[0]); b = maxOf(b, span[1]); iterator.remove() } }
        val at = covered.indexOfFirst { it[0] > a }.let { if (it < 0) covered.size else it }
        covered.add(at, doubleArrayOf(a, b))
        dirty = true
    }

    /** Serialized under the caller's lock; [write] runs outside it. */
    fun snapshot(force: Boolean): String? {
        if (directory == null || !dirty || (!force && System.nanoTime() - written < WRITE_INTERVAL_NS)) return null
        dirty = false; written = System.nanoTime()
        return JSONObject().put("schema", SCHEMA).put("key", key).put("network", network)
            .put("covered", JSONArray(covered.map { JSONArray().put(it[0]).put(it[1]) }))
            .put("cues", JSONArray(cues.map { JSONArray().put(it.start).put(it.end).put(it.text) })).toString()
    }

    fun write(json: String) {
        val dir = directory ?: return
        if (json.length > MAX_BYTES) return
        runCatching {
            dir.mkdirs()
            // Replace atomically: a crash leaves the previous complete entry.
            val temporary = File(dir, "$key.json.tmp")
            temporary.writeBytes(json.toByteArray())
            if (!temporary.renameTo(File(dir, "$key.json"))) temporary.delete()
        }
    }

    companion object {
        const val SCHEMA = 1
        const val SETTLE_SECONDS = 4.0
        private const val MAX_CUES = 20000
        private const val MAX_BYTES = 4 * 1024 * 1024
        private const val WRITE_INTERVAL_NS = 15_000_000_000L
        fun directory(files: File) = File(files, "listening-cues")

        /** media: the per-file settings key; model: the language's pinned model identity. */
        fun key(media: String, duration: Double, language: String, model: String): String =
            sha256("$SCHEMA|$media|${"%.3f".format(java.util.Locale.ROOT, duration)}|$language|$model")

        fun modelIdentity(manifest: JSONObject, language: String): String =
            sha256(manifest.optString("revision") + "|" + manifest.getJSONObject("models").getJSONObject(language).getJSONObject("files").toString())

        /** Loads the stored entry for [key]; a missing, mismatched or corrupt file starts empty. */
        fun load(directory: File?, key: String, network: Boolean): ListeningCueCache {
            val cache = ListeningCueCache(directory, key, network)
            val file = directory?.let { File(it, "$key.json") } ?: return cache
            if (!file.isFile || file.length() > MAX_BYTES) return cache
            runCatching {
                val json = JSONObject(file.readText())
                if (json.getInt("schema") != SCHEMA || json.getString("key") != key) return cache
                val spans = json.getJSONArray("covered")
                for (i in 0 until spans.length()) { val span = spans.getJSONArray(i); cache.cover(span.getDouble(0), span.getDouble(1)) }
                val rows = json.getJSONArray("cues")
                for (i in 0 until minOf(rows.length(), MAX_CUES)) {
                    val row = rows.getJSONArray(i)
                    ListeningPolicy.Cue.parse(JSONObject().put("start", row.getDouble(0)).put("end", row.getDouble(1)).put("text", row.getString(2)))?.let(cache::add)
                }
                cache.dirty = false
            }.onFailure { cache.cues.clear(); cache.covered.clear(); cache.dirty = false }
            return cache
        }

        /** Per-file settings cleanup; network-only keeps local videos' entries. */
        fun clear(files: File, networkOnly: Boolean): Boolean {
            val entries = directory(files).listFiles() ?: return true
            var ok = true
            for (file in entries) {
                if (networkOnly) {
                    val network = runCatching { JSONObject(file.readText()).optBoolean("network", true) }.getOrDefault(true)
                    if (!network) continue
                }
                if (file.exists() && !file.delete()) ok = false
            }
            return ok
        }

        private fun sha256(value: String) = MessageDigest.getInstance("SHA-256").digest(value.toByteArray()).joinToString("") { "%02x".format(it) }
    }
}
