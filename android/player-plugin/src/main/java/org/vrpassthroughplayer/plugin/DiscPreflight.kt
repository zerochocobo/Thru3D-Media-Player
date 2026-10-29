package org.vrpassthroughplayer.plugin

import org.json.JSONObject

/** Optical-disc ISO preflight results. Reopening the same disc (title switch, layer
 * change, resume) reuses them instead of scanning UDF and playlists over the
 * network again. Memory only and short-lived: the demuxer still validates the
 * disc on every real open, so a stale entry can only fail that open. */
internal object DiscPreflight {
    data class Result(val width: Int, val height: Int, val mvc: Boolean, val playlist: Int, val json: String)

    private const val ENTRIES = 16
    private const val LIFETIME_MS = 30 * 60 * 1000L
    private val entries = object : LinkedHashMap<String, Pair<Long, Result>>(ENTRIES, .75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Pair<Long, Result>>) = size > ENTRIES
    }

    fun parse(json: String): Result {
        val value = JSONObject(json)
        val result = Result(value.getInt("width"), value.getInt("height"), value.getBoolean("mvc"), value.getInt("playlist"), json)
        require(result.width in 1..8192 && result.height in 1..4320 && result.playlist in 0..99999 &&
            value.getJSONArray("titles").length() <= if (value.optString("disc_type") == "dvd") 99 else 48)
        return result
    }

    private fun key(uri: String, playlist: Int) = "$playlist\u0000$uri"

    @Synchronized fun cached(uri: String, playlist: Int, now: Long = System.currentTimeMillis()): Result? {
        val entry = entries[key(uri, playlist)] ?: return null
        if (now - entry.first !in 0..LIFETIME_MS) { entries.remove(key(uri, playlist)); return null }
        return entry.second
    }

    /** Also records the default (-1) request under the title it selected. */
    @Synchronized fun store(uri: String, requested: Int, result: Result, now: Long = System.currentTimeMillis()) {
        entries[key(uri, requested)] = now to result
        entries[key(uri, result.playlist)] = now to result
    }

    @Synchronized fun clear() = entries.clear()

    /** Preflight on a miss; a hit performs no disc reads at all. */
    fun probe(uri: String, path: String, playlist: Int, read: (String, Int) -> String): Result =
        cached(uri, playlist) ?: parse(read(path, playlist)).also { store(uri, playlist, it) }
}
