package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import java.net.URI
import java.util.Locale

/** Filename only selects a bounded header inspection; it never proves MVC. */
internal object MkvMvcPreflight {
    data class Result(val width: Int, val height: Int)
    fun candidate(vararg locations: String): Boolean = locations.any { location ->
        val path = runCatching { URI(location).path }.getOrNull() ?: location.substringBefore('?').substringBefore('#')
        path.lowercase(Locale.ROOT).let { it.endsWith(".mkv") || it.endsWith(".mk3d") }
    }
    /** Inspection only selects the MVC route: mpv's own probing still decides everything else. */
    fun inspect(probe: () -> String, failed: (Throwable) -> Unit): Result? =
        runCatching { parse(probe()) }.onFailure(failed).getOrNull()
    fun parse(json: String): Result? {
        val value = JSONObject(json)
        if (!value.getBoolean("mvc")) return null
        return Result(value.getInt("width"), value.getInt("height")).also {
            require(it.width in 2..3840 && it.width % 2 == 0 && it.height in 1..1080)
        }
    }
}
