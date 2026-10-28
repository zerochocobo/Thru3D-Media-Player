package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject

/** A standard declared equirectangular layout; spherical/fisheye variants are not conflated. */
internal object WebVideoPageProjection {
    fun parse(layout: String): JSONObject? {
        if (layout !in setOf("STEREO_180_LR", "STEREO_180_TB", "STEREO_360_LR", "STEREO_360_TB", "MONO_360")) return null
        val half = "_180_" in layout
        return JSONObject().put("version", 1).put("source", "page_player_format")
            .put("kind", "equirectangular").put("geometry", if (half) 1 else 3)
            .put("stereo_mode", if (layout.endsWith("_LR")) 2 else if (layout.endsWith("_TB")) 1 else 0)
            .put("pose", JSONArray(listOf(0, 0, 0))).put("bounds", JSONArray(listOf(0.0, 0.0, if (half) .25 else 0.0, if (half) .25 else 0.0)))
    }
}
