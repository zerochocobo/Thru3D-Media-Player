package org.vrpassthroughplayer.plugin

import java.net.URI
import org.json.JSONObject

/** Official parent detail and its actually rendered hosted player. */
object WebBrowserDailymotion {
    private const val ENABLED=true // Current detail verified with real button/native/audio/seek/retained return.
    fun document(value: String): Boolean=runCatching {
        val u=URI(value)
        value.length<=8192 && u.scheme=="https" && u.host in setOf("www.dailymotion.com","dailymotion.com") && u.rawUserInfo==null && u.port in setOf(-1,443)
    }.getOrDefault(false)
    fun observing(value: String)=ENABLED && document(value)
    fun page(value: String): String?=runCatching {
        val u=URI(value)
        require(value.length<=8192 && u.scheme=="https" && u.host in setOf("www.dailymotion.com","dailymotion.com") && u.rawUserInfo==null && u.port in setOf(-1,443) && u.rawFragment==null)
        Regex("/video/([A-Za-z0-9]{1,20})/?").matchEntire(u.rawPath.orEmpty())?.groupValues?.get(1)
    }.getOrNull()
    fun frame(value: String): Boolean=runCatching {
        val u=URI(value)
        value.length<=8192 && u.scheme=="https" && u.host=="geo.dailymotion.com" && u.rawUserInfo==null && u.port in setOf(-1,443) && Regex("/player(?:/[A-Za-z0-9]+)?\\.html").matches(u.rawPath.orEmpty())
    }.getOrDefault(false)
    fun enabled(value: String)=ENABLED && page(value)!=null
    fun transport(value: String): URI?=runCatching {
        require(value.length<=16384);URI(value)
        WebBrowserNetworkMedia.address(value.substringBefore('#')) ?: error("Invalid transport")
    }.getOrNull()
    /** Derive an HTTP transport copy; keep the original manifest as evidence.
     * Only URI fragments change, never signed query selectors or parameters. */
    fun transportManifest(body: String,base: URI): String {
        fun ref(value: String): String {
            if('#' !in value)return value
            require(transport(base.resolve(value).toString())!=null)
            return value.substringBefore('#')
        }
        return Regex("[^\\r\\n]+").replace(body){match->
            val line=match.value;val trimmed=line.trim()
            if(trimmed.startsWith('#'))Regex("\\bURI=\"([^\"]*)\"").replace(line){attr->"URI=\"${ref(attr.groupValues[1])}\""}
            else if(trimmed.isEmpty())line else {
                val start=line.indexOf(trimmed);line.substring(0,start)+ref(trimmed)+line.substring(start+trimmed.length)
            }
        }
    }
    fun metadata(item: JSONObject,currentPage: String): JSONObject?=runCatching {
        val id=page(currentPage) ?: return null
        val frame=item.getString("frame")
        require(WebBrowserDailymotion.frame(frame) && !item.optBoolean("protected") && item.optBoolean("blob"))
        val source=item.getString("dailymotion_source");require(source.startsWith("blob:https://geo.dailymotion.com/"))
        val data=item.getJSONObject("dailymotion")
        require(data.toString().length<=96*1024 && data.getString("id")==id && data.getString("page")=="https://www.dailymotion.com/video/$id" && data.getString("frame")==frame)
        require(data.getString("revision").matches(Regex("[a-f0-9]{1,8}")))
        require(WebBrowserNetworkMedia.address(data.getString("root"))?.scheme=="https")
        val width=item.getInt("width");val height=item.getInt("height");val duration=item.getDouble("duration");val expected=data.getDouble("expected_duration")
        require(width in 1..8192 && height in 1..8192 && width==data.getInt("width") && height==data.getInt("height"))
        require(duration.isFinite() && duration>0 && duration<=86400 && kotlin.math.abs(duration-data.getDouble("duration"))<=.001)
        require(expected.isFinite() && expected>0 && expected<=86400 && expected==kotlin.math.floor(expected) && kotlin.math.abs(duration-expected)<=1)
        val requests=WebBrowserNetworkMedia.candidates(item,true)
        require((0 until requests.length()).any{val r=requests.getJSONObject(it);r.optString("kind")=="hls" && r.optString("url")==data.getString("root")})
        val bodies=data.getJSONArray("manifests");require(bodies.length() in 1..6)
        var total=0;val seen=mutableSetOf<String>()
        for(i in 0 until bodies.length()){
            val entry=bodies.getJSONObject(i);val uri=entry.getString("url");val body=entry.getString("body");val request=entry.getString("request_id")
            require(seen.add(uri) && WebBrowserNetworkMedia.address(uri)?.scheme=="https" && body.startsWith("#EXTM3U"))
            val size=body.toByteArray(Charsets.UTF_8).size;total+=size;require(size<=48*1024 && total<=64*1024)
            val original=entry.optString("request_url",uri);require(transport(original)?.toString()==uri)
            require((0 until requests.length()).any{val r=requests.getJSONObject(it);r.optString("kind")=="hls" && r.optString("url")==uri &&
                r.optString("request_id")==request && r.optString("request_url",r.optString("url"))==original})
        }
        require(data.getString("root") in seen)
        data
    }.getOrNull()
}
