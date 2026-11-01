package org.vrpassthroughplayer.plugin

import android.content.Intent
import org.json.JSONArray
import org.json.JSONObject

internal class ExternalPlaybackIntentReader(private val source: Intent) {
    private val headerKeys = listOf("headers", "android.media.intent.extra.HTTP_HEADERS")
    private val positionKeys = listOf("position", "extra_position", "start_position", "startfrom")

    private fun text(key: String): String? = runCatching { source.getStringExtra(key) }.getOrNull()
    @Suppress("DEPRECATION")
    private fun value(key: String): Any? = runCatching { source.extras?.get(key) }.getOrNull()
    fun title() = text("title") ?: text(Intent.EXTRA_TITLE) ?: text("forcename")
    fun position(): Number? = (value("position") ?: value("extra_position"))?.let { it as? Int ?: it as? Long }
    fun startMs(): Int = ExternalPlaybackContract.startMs(positionKeys.map(::value))

    private fun headerPairs(key: String): List<Pair<String?, String?>>? {
        val bundle = runCatching { source.getBundleExtra(key) }.getOrNull()
        if (bundle != null) {
            // Do not read unknown values or traverse arbitrary Parcelable/Serializable objects.
            val names = bundle.keySet().toList()
            require(names.size <= ExternalPlaybackContract.MAX_ENTRIES) { "INVALID_HEADER" }
            return names.map { name ->
                name to if (name?.lowercase(java.util.Locale.ROOT) in ExternalPlaybackRequest.headerNames)
                    runCatching { bundle.getString(name) }.getOrNull() else ""
            }
        }
        val values = runCatching { source.getStringArrayExtra(key) }.getOrNull() ?: return null
        return ExternalPlaybackContract.stringArrayPairs(values)
    }

    fun headers(): ExternalPlaybackContract.Headers =
        ExternalPlaybackContract.headers(headerKeys.flatMap { headerPairs(it).orEmpty() })

    /** Never throws: a malformed request must still leave its names and kinds behind. */
    fun metadata(): JSONObject = try {
        evidence()
    } catch (_: Exception) {
        JSONObject().put("flags", source.flags).put("action", Intent.ACTION_VIEW).put("metadata_state", "failed")
    }

    private fun evidence(): JSONObject {
        val type = source.type.orEmpty().lowercase(java.util.Locale.ROOT)
        val knownMime = setOf("video/*", "video/mp4", "video/mpeg", "video/x-matroska", "video/webm",
            "video/x-msvideo", "video/quicktime", "application/vnd.apple.mpegurl", "application/x-mpegurl",
            "application/dash+xml", "application/octet-stream")
        val value = JSONObject().put("flags", source.flags).put("action", Intent.ACTION_VIEW)
            .put("mime", if (type.isEmpty()) "none" else if (type in knownMime) type else "unclassified")
        val names = runCatching { source.extras?.keySet()?.toList() }
        if (names.isFailure) return value.put("extras_state", "unreadable")
        val extras = JSONObject()
        var redacted = 0
        names.getOrNull().orEmpty().take(ExternalPlaybackContract.MAX_ENTRIES).forEach { key ->
            val name = ExternalPlaybackContract.safeName(key)
            if (name == ExternalPlaybackContract.REDACTED) redacted++
            else extras.put(name, ExternalPlaybackContract.kind(value(key)))
        }
        value.put("extras", extras).put("extras_count", names.getOrNull()?.size ?: 0).put("extras_redacted", redacted)
        val positions = JSONObject()
        for (key in positionKeys) {
            // JSONObject rejects NaN and Infinity; those stay visible only as a kind.
            when (val number = value(key)) {
                is Int, is Long -> positions.put(key, number)
                is Float -> if (number.isFinite()) positions.put(key, number.toDouble()) else positions.put(key, "non_finite")
                is Double -> positions.put(key, if (number.isFinite()) number else "non_finite")
            }
        }
        value.put("positions", positions)
        runCatching { headers() }.onSuccess {
            value.put("header_names", JSONArray(it.received)).put("header_names_dropped", JSONArray(it.dropped))
        }.onFailure { value.put("header_state", "invalid") }
        return value
    }
}
