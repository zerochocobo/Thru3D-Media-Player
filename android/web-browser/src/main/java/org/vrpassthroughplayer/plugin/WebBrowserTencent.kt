package org.vrpassthroughplayer.plugin

import java.net.URI
import java.net.URLDecoder
import org.json.JSONObject
import org.json.JSONArray

/** Public Tencent identity plus the exact main-player observation. Private data stays native. */
object WebBrowserTencent {
    const val USER_BETA_AVAILABLE = true
    private data class Page(val id: String, val cover: String)
    private fun route(value: String): Page? = runCatching {
        val u = URI(value)
        require(u.scheme == "https" && u.host == "v.qq.com" && u.port in setOf(-1,443) && u.rawUserInfo == null && u.fragment == null)
        val clip = Regex("/x/page/([A-Za-z0-9]{11})\\.html").matchEntire(u.path)
        val cover = Regex("/x/cover/([A-Za-z0-9]{5,32})(?:/([A-Za-z0-9]{11}))?\\.html").matchEntire(u.path)
        require(clip != null || cover != null)
        val ids = u.rawQuery.orEmpty().split('&').filter { URLDecoder.decode(it.substringBefore('='),"UTF-8") == "vid" }
            .map { URLDecoder.decode(it.substringAfter('=',""),"UTF-8") }
        require(ids.size <= 1 && ids.all { Regex("[A-Za-z0-9]{11}").matches(it) })
        val id = clip?.groupValues?.get(1) ?: cover!!.groupValues[2].ifEmpty { ids.firstOrNull().orEmpty() }
        require(ids.isEmpty() || ids.single() == id)
        Page(id,cover?.groupValues?.get(1).orEmpty())
    }.getOrNull()
    fun document(value: String) = route(value) != null
    fun enabled(value: String) = USER_BETA_AVAILABLE && document(value)
    fun diagnosticShape(input: JSONArray?): JSONArray = JSONArray().also { output ->
        var characters=0
        for(i in 0 until minOf(96,input?.length() ?: 0)) {
            val item=input?.optJSONObject(i) ?: continue
            val path=item.optString("path");val kind=item.optString("kind")
            if(!path.matches(Regex("[A-Za-z_][A-Za-z0-9_.\\[\\]]{0,255}")) || kind !in setOf("object","array","string","number","boolean","null")) continue
            val safe=JSONObject().put("path",path).put("kind",kind)
            val keys=item.optJSONArray("keys")
            if(keys!=null)safe.put("keys",JSONArray().also { names ->
                for(k in 0 until minOf(32,keys.length()))keys.optString(k).takeIf { it.matches(Regex("[A-Za-z_][A-Za-z0-9_]{0,63}")) }?.let { name -> names.put(name) }
            })
            for(key in listOf("count","chars"))if(item.has(key))safe.put(key,item.optInt(key).coerceIn(0,2*1024*1024))
            if(kind=="number" && path.substringAfterLast('.').matches(Regex("(?:ret|code|(?:video|audio|content|total|preview)?(?:width|height|duration|durationms|bitrate|fps|samplerate|channels)|enc|drm|drm_?flag|isprevid|vw|vh|td)",RegexOption.IGNORE_CASE))) {
                val value=item.optDouble("sample",Double.NaN)
                if(value.isFinite()&&kotlin.math.abs(value)<=1e9)safe.put("sample",value)
            }
            characters+=safe.toString().length
            if(characters>32768)break
            output.put(safe)
        }
    }
    private fun canonical(p: Page,id: String) = if (p.cover.isEmpty()) "https://v.qq.com/x/page/$id.html"
        else "https://v.qq.com/x/cover/${p.cover}/$id.html"

    fun references(data: JSONObject): Set<String>? = runCatching {
        val body = data.getString("playlist")
        require(body.toByteArray(Charsets.UTF_8).size <= 160 * 1024)
        val base = WebBrowserNetworkMedia.address(data.getString("manifest_url")) ?: return null
        require(base.scheme == "https")
        val lines = body.lineSequence().map(String::trim).toList()
        require(lines.firstOrNull() == "#EXTM3U" && "#EXT-X-ENDLIST" in lines && lines.size <= 16000)
        require(lines.none { it.startsWith("#EXT-X-STREAM-INF:") || it.startsWith("#EXT-X-DEFINE:") })
        require(lines.none { Regex("^#EXT-X-(?:SESSION-)?KEY:").containsMatchIn(it) &&
            !Regex("^#EXT-X-(?:SESSION-)?KEY:METHOD=NONE(?:,|$)").containsMatchIn(it) })
        val values = lines.filter { it.isNotEmpty() && !it.startsWith('#') } +
            lines.filter { it.startsWith("#EXT-X-MAP:") }.flatMap { line -> Regex("URI=\"([^\"]+)\"").findAll(line).map { it.groupValues[1] }.toList() }
        require(values.size in 1..4096)
        values.map { value ->
            val u = WebBrowserNetworkMedia.address(base.resolve(value).toString()) ?: error("Invalid HLS reference")
            require(u.scheme == "https");u.toString()
        }.toSet()
    }.getOrNull()

    fun metadata(item: JSONObject,currentPage: String): JSONObject? = runCatching {
        val p = route(currentPage) ?: return null
        require(item.optString("frame") == currentPage && !item.optBoolean("protected"))
        val data = item.getJSONObject("tencent")
        require(data.toString().length <= 192 * 1024 && data.optBoolean("clear") && data.optBoolean("full"))
        val id = data.getString("id")
        require(Regex("[A-Za-z0-9]{11}").matches(id) && (p.id.isEmpty() || p.id == id) && data.getString("page") == canonical(p,id))
        require(Regex("[a-f0-9]{1,8}").matches(data.getString("revision")) && Regex("[A-Za-z0-9_.-]{1,256}").matches(data.getString("filename")))
        require(item.optInt("width") in 1..8192 && item.optInt("height") in 1..8192 &&
            data.optInt("width") == item.optInt("width") && data.optInt("height") == item.optInt("height"))
        val duration = item.getDouble("duration");val expected = data.getDouble("duration")
        require(duration.isFinite() && duration > 0 && duration <= 86400 && expected.isFinite() && expected > 0 &&
            kotlin.math.abs(duration-expected) <= maxOf(2.0,expected*.01))
        val network = WebBrowserNetworkMedia.candidates(item,includeSegments=true)
        val requests = (0 until network.length()).map { network.getJSONObject(it) }
        if (data.optString("playlist").isNotEmpty()) {
            require(item.optBoolean("blob"))
            require(kotlin.math.abs(duration-expected) <= maxOf(.5,expected*.0001))
            val urls = data.getJSONArray("urls")
            require(urls.length() in 1..8 && (0 until urls.length()).any { urls.getString(it) == data.getString("manifest_url") })
            require((0 until urls.length()).all { WebBrowserNetworkMedia.address(urls.getString(it))?.scheme == "https" })
            val refs = references(data) ?: return null
            require(requests.any { it.optString("kind") == "segment" && (it.optString("url") in refs || it.optString("original_url") in refs) })
            val total = data.getString("playlist").lineSequence().map(String::trim).filter { it.startsWith("#EXTINF:") }
                .map { it.substringAfter(':').substringBefore(',').toDouble().also { value -> require(value.isFinite() && value > 0) } }.sum()
            require(kotlin.math.abs(total-expected) <= .1)
        } else {
            require(!item.optBoolean("blob"))
            val source = item.getString("source")
            require(WebBrowserNetworkMedia.address(source)?.scheme == "https")
            val files = requests.filter { it.optString("kind") == "file" && (it.optString("url") == source || it.optString("original_url") == source) &&
                URI(it.getString("url")).path.endsWith("/"+data.getString("filename")) }.distinctBy { it.getString("url") }
            require(files.size == 1)
        }
        data
    }.getOrNull()
}
