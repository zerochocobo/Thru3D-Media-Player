package org.vrpassthroughplayer.plugin

import java.net.URI
import java.util.Locale
import org.json.JSONObject

/** Current Mango main-player binding; request credentials remain on their actual requests. */
object WebBrowserMango {
    fun page(value: String): String? = runCatching {
        require(value.length <= 8192)
        val u=URI(value)
        require(u.scheme=="https" && u.rawUserInfo==null && u.rawFragment==null && u.port in setOf(-1,443))
        require(u.host?.lowercase(Locale.ROOT) in setOf("mgtv.com","www.mgtv.com","w.mgtv.com"))
        Regex("/(?:s|b|v)/(?:[A-Za-z0-9_-]+/)*([1-9][0-9]{0,19})\\.html").matchEntire(u.rawPath.orEmpty())?.groupValues?.get(1)
    }.getOrNull()
    fun enabled(value: String) = page(value)!=null
    /** Public identity/counts only; never copy raw metadata, hashes or request URLs. */
    fun captureDiagnostics(item: JSONObject): JSONObject {
        val data = item.optJSONObject("mango_capture") ?: JSONObject()
        val states = setOf("idle", "observing", "metadata", "sources", "unbound_sources", "normalized", "protected_or_invalid",
            "invalid_data", "stream_error", "timeout", "oversize", "cancelled", "context_changed", "http_rejected", "redirected")
        return JSONObject().put("status", data.optString("status").takeIf { it in states } ?: "unknown")
            .put("metadata", data.optBoolean("metadata")).put("clear", data.optBoolean("clear"))
            .put("id", data.optString("id").takeIf { it.matches(Regex("[1-9][0-9]{0,19}")) }.orEmpty())
            .put("duration", data.optDouble("duration", 0.0).takeIf { it.isFinite() && it in 0.0..172800.0 } ?: 0.0)
            .put("declared_dispatches", data.optInt("declared_dispatches").coerceIn(0, 128))
            .put("declared_files", data.optInt("declared_files").coerceIn(0, 16))
            .put("manifests", data.optInt("manifests").coerceIn(0, 8))
            .put("bound_hls", data.optInt("bound_hls").coerceIn(0, 6))
    }
    fun metadata(item: JSONObject,currentPage: String): JSONObject? = runCatching {
        val id=page(currentPage) ?: return null
        require(item.optString("frame")==currentPage && !item.optBoolean("protected") && item.optBoolean("blob"))
        val data=item.getJSONObject("mango")
        require(data.toString().length<=128*1024 && data.optBoolean("clear") && data.getString("id")==id && data.getString("page")==currentPage)
        require(data.getString("revision").matches(Regex("[a-f0-9]{1,8}")))
        val width=item.getInt("width");val height=item.getInt("height");val duration=item.getDouble("duration")
        require(width in 1..16384 && height in 1..16384 && data.getInt("width")==width && data.getInt("height")==height)
        val bound=data.getDouble("duration");val expected=data.getDouble("expected_duration")
        require(duration.isFinite() && duration>0 && duration<=172800 && bound.isFinite() && expected.isFinite() && expected>0 &&
            kotlin.math.abs(duration-bound)<=.001 && kotlin.math.abs(duration-expected)<=2.0)
        val preview=data.optBoolean("preview")
        if(preview || data.has("program_duration")) {
            val program=data.getDouble("program_duration")
            require(program.isFinite() && program>0 && program<=172800 &&
                if(preview) program>expected+2.0 else kotlin.math.abs(program-expected)<=.001)
            if(preview) {
                val trial=data.getDouble("preview_duration")
                require(trial.isFinite() && trial>0 && kotlin.math.abs(trial-expected)<=.001)
            }
        }
        val urls=data.getJSONArray("manifests")
        require(urls.length() in 1..8)
        val declared=(0 until urls.length()).map { urls.getString(it).also { value -> require(WebBrowserNetworkMedia.address(value)?.scheme=="https") } }.toSet()
        require(declared.size==urls.length())
        val network=WebBrowserNetworkMedia.candidates(item)
        val matched=(0 until network.length()).map { network.getJSONObject(it) }.filter {
            it.optString("kind")=="hls" && (it.optString("url") in declared || it.optString("original_url") in declared)
        }.distinctBy { it.getString("url") }
        require(matched.size in 1..6)
        data
    }.getOrNull()
}
