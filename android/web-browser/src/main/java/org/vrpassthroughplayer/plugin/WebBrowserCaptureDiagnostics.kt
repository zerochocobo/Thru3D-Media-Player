package org.vrpassthroughplayer.plugin

import org.json.JSONObject

/** Same bounded public-status boundary as WebBrowserMango.captureDiagnostics.
 * No source addresses, declarations, headers or arbitrary website strings. */
internal object WebBrowserCaptureDiagnostics {
    private val states=mapOf(
        "tiktok" to setOf("document","card","owner_identity","different_item","excluded_content","source_identity",
            "source_shape","source_address","ambiguous_declaration","declaration_error","not_decoded","source_scheme",
            "decoded_shape","observed_payload","multiple_players","direct_source","bound"),
        "iqiyi" to setOf("missing","bound","unsupported_page","not_main","wrong_item","wrong_track","ambiguous_track",
            "wrong_element","not_decoded","invalid_video","wrong_dimensions_or_duration","unsupported_declaration",
            "unsupported_container","missing_playlist","oversize_playlist","non_hls_playlist",
            "protected_manifest","read_error"))

    fun project(site: String,item: JSONObject): JSONObject {
        val allowed=states[site] ?: return JSONObject()
        val data=item.optJSONObject(site+"_diagnostics") ?: JSONObject()
        val result=JSONObject().put("status",data.optString("status").takeIf{it in allowed} ?: "unknown")
        val flags=if(site=="tiktok")listOf("advertisement") else listOf("capture_ready","binding_ready","source_matches",
            "dimensions_match","duration_matches","track_drm","root_drm","dispatch_ready","timeline_matches","has_segment_list")
        for(key in flags)if(data.opt(key) is Boolean)result.put(key,data.getBoolean(key))
        val fields=if(site=="tiktok")mapOf("expected_width" to 8192.0,"expected_height" to 8192.0,
            "expected_duration" to 86400.0,"decoded_duration" to 86400.0)
            else mapOf("drm_type" to 32.0,"dispatcher_count" to 1024.0)
        for((key,limit)in fields) {
            val value=(data.opt(key) as? Number)?.toDouble() ?: continue
            if(value.isFinite() && value>=(if(key=="drm_type")-1.0 else 0.0) && value<=limit &&
                (key=="decoded_duration" || value==kotlin.math.floor(value)))result.put(key,value)
        }
        if(site=="tiktok")data.optString("public_id").takeIf{it.matches(Regex("[1-9][0-9]{14,19}"))}?.let{result.put("public_id",it)}
        if(site=="iqiyi" && result.getString("status")=="unsupported_container") {
            data.optString("container").takeIf{it in setOf("ts","265ts","f4v","m4s","mp4","missing","other")}?.let{result.put("container",it)}
            data.optString("declaration").takeIf{it in setOf("hls","json_object","json_array","url","missing","empty","other")}?.let{result.put("declaration",it)}
        }
        return result
    }
}
