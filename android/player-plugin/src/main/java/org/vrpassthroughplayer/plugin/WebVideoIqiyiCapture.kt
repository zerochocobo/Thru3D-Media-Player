package org.vrpassthroughplayer.plugin

import java.net.URI
import org.json.JSONObject

/** Keeps the SDK's complete timeline; the existing HLS proxy owns requests and local ranges. */
internal object WebVideoIqiyiCapture {
    fun page(document: String,media: JSONObject?): WebVideoPage? = runCatching {
        require(media!=null && media.optBoolean("iqiyi_enabled") && media.optString("capture_identity").isNotEmpty())
        require(WebBrowserIqiyi.metadata(media,document)!=null)
        WebVideoPage.parse(document)
    }.getOrNull()
    fun keeps(page: WebVideoPage,initial: JSONObject,latest: JSONObject,track: WebVideoTrack): Boolean {
        if(WebVideoIqiyiCapture.page(latest.optString("frame"),latest)!=page)return false
        val a=initial.optJSONObject("iqiyi") ?: return false
        val b=WebBrowserIqiyi.metadata(latest,latest.optString("frame")) ?: return false
        return latest.optString("iqiyi_source")==initial.optString("iqiyi_source") &&
            listOf("id","revision","tvid","vid","bid").all { a.optString(it)==b.optString(it) } &&
            latest.optInt("width")==track.width && latest.optInt("height")==track.height
    }
    fun resolve(page: WebVideoPage,media: JSONObject,network: WebVideoNetworkCapture): JSONObject? {
        if(page.site!="iqiyi" || WebVideoIqiyiCapture.page(media.optString("frame"),media)!=page)return null
        val resourcePlan=WebBrowserIqiyi.resourcePlan(media,media.optString("frame"))
        if(media.getJSONObject("iqiyi").optString("dispatch_status")=="selected_level" && resourcePlan==null)return null
        if(resourcePlan!=null) {
            val body=resourcePlan.getString("playlist");resourcePlan.remove("playlist")
            val info=WebVideoIqiyiResources(resourcePlan,body).use { resources ->
                val ordinary=mapOf("user-agent" to media.optString("agent"),"referer" to media.getString("frame"),"origin" to "https://www.iqiyi.com")
                network.resolveDeclaredHls(page,media,URI(page.url),body) { uri,_,prefix ->
                    val target=resources.target(uri,{ network.requestHeaders(it,ordinary) },network::readRaw)
                    network.readRaw(target,network.requestHeaders(target,ordinary),prefix)
                }
            } ?: return null
            info.getJSONArray("formats").getJSONObject(0).put("browser_iqiyi",resourcePlan)
            return info
        }
        val plan=WebBrowserIqiyi.plan(media,media.optString("frame")) ?: return null
        val bound=JSONObject(media.toString()).put("network",plan.getJSONArray("network"))
        val info=network.resolveObservedHls(page,bound,URI(plan.getString("manifest_url")),plan.getString("playlist")) ?: return null
        val formats=info.optJSONArray("formats") ?: return null
        if(formats.length()!=1)return null
        val track=formats.getJSONObject(0)
        if(track.optInt("width")!=media.optInt("width") || track.optInt("height")!=media.optInt("height") ||
            track.optString("vcodec") in setOf("","none","unknown") || track.optString("acodec") in setOf("","none","unknown"))return null
        return info
    }
}
