package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject

/** Reuses verified whole-file playback with the current Archive download's actual redirect. */
internal object WebVideoArchiveCapture {
    fun page(document: String,media: JSONObject?): WebVideoPage?=runCatching {
        require(media!=null && media.optBoolean("archive_enabled") && media.optString("capture_identity").isNotEmpty())
        val data=WebBrowserArchive.metadata(media,document) ?: return null
        WebVideoPage.parse(data.getString("page"))
    }.getOrNull()
    fun candidate(page: WebVideoPage,media: JSONObject): JSONObject?=runCatching {
        require(page.site=="archive" && WebVideoArchiveCapture.page(media.optString("frame"),media)==page && media.optBoolean("archive_ready"))
        val data=media.getJSONObject("archive");val file=data.getString("file");val source=data.getString("source")
        val requests=WebBrowserNetworkMedia.candidates(media)
        val chosen=(0 until requests.length()).map{requests.getJSONObject(it)}.filter {
            it.optString("kind")=="file" && it.optString("url")==file && (file==source || it.optString("original_url")==source)
        }.distinctBy{it.getString("url")}
        require(chosen.size==1)
        JSONObject(media.toString()).put("source",file).put("network",JSONArray(chosen))
    }.getOrNull()
    fun resolve(page: WebVideoPage,media: JSONObject,network: WebVideoNetworkCapture): JSONObject? {
        val bound=candidate(page,media) ?: return null
        val info=network.resolve(page,bound) ?: return null
        val formats=info.optJSONArray("formats") ?: return null
        if(formats.length()!=1)return null
        val file=formats.getJSONObject(0)
        if(file.optString("url")!=bound.getString("source") || file.optString("vcodec") in setOf("","none","unknown") ||
            file.optString("acodec") in setOf("","none","unknown") || file.optInt("display_width",file.optInt("width"))!=media.optInt("width") || file.optInt("height")!=media.optInt("height"))return null
        // HTML videoWidth includes pixel aspect. Retain coded dimensions and accept
        // only the exact display width derived from this file's validated pasp/SPS.
        file.put("coded_width",file.getInt("width")).put("width",file.optInt("display_width",file.getInt("width")))
        return info
    }
    fun keeps(page: WebVideoPage,initial: JSONObject,latest: JSONObject,track: WebVideoTrack): Boolean {
        val bound=candidate(page,latest) ?: return false
        return bound.getString("source")==track.url.toString() && latest.optString("source")==initial.optString("source") &&
            latest.getJSONObject("archive").optString("revision")==initial.getJSONObject("archive").optString("revision") &&
            bound.optInt("width")==track.width && bound.optInt("height")==track.height
    }
}
