package org.vrpassthroughplayer.plugin

import java.net.URI
import java.net.URLDecoder
import org.json.JSONArray
import org.json.JSONObject

/** Current SDK-selected TS declaration. Observed requests or the selected SDK file declarations supply each resource. */
object WebBrowserIqiyi {
    private const val ENABLED = true // Real Gecko button, HLS and retained-page preflight passed locally.
    fun enabled(value: String) = ENABLED && page(value) != null
    fun page(value: String): String? = runCatching {
        require(value.length <= 8192)
        val u=URI(value)
        require(u.scheme=="https" && u.host=="www.iqiyi.com" && u.port in setOf(-1,443) && u.rawUserInfo==null && u.rawFragment==null)
        Regex("/([vw]_[A-Za-z0-9]+)\\.html").matchEntire(u.rawPath)?.groupValues?.get(1)
    }.getOrNull()
    private fun query(uri: URI): Map<String,String> {
        val result=LinkedHashMap<String,String>()
        for(pair in uri.rawQuery.orEmpty().split('&').filter(String::isNotEmpty)) {
            val name=URLDecoder.decode(pair.substringBefore('='),"UTF-8")
            require(name !in result)
            result[name]=URLDecoder.decode(pair.substringAfter('=',""),"UTF-8")
        }
        return result
    }
    private class Range(val uri: URI,val start: Long,val end: Long,val sd: Long)
    private class Part(val range: Range,val duration: Double)
    private fun range(uri: URI,tvid: String): Range {
        require(uri.path.endsWith(".ts",true) || uri.path.endsWith(".265ts",true))
        val q=query(uri)
        require(q["qd_tvid"]==null || q["qd_tvid"]==tvid)
        fun number(key: String): Long = q[key]?.takeIf { it.matches(Regex("[0-9]{1,15}")) }?.toLong() ?: error("Invalid range")
        val start=number("start");val end=number("end")
        require(start<end && number("contentlength")==end-start)
        return Range(uri,start,end,number("sd"))
    }
    private fun parts(data: JSONObject): List<Part> {
        val text=data.getString("playlist");require(text.length<=128*1024)
        val lines=text.lineSequence().map(String::trim).filter(String::isNotEmpty).toList()
        require(lines.firstOrNull()=="#EXTM3U" && lines.lastOrNull()=="#EXT-X-ENDLIST")
        val result=ArrayList<Part>();var duration: Double?=null
        for(line in lines.drop(1)) {
            when {
                line.startsWith("#EXTINF:") -> {
                    require(duration==null)
                    duration=line.substringAfter(':').substringBefore(',').toDouble().also { require(it.isFinite() && it>0 && it<=172800) }
                }
                line.startsWith('#') -> require(line=="#EXT-X-ENDLIST" || Regex("#EXT-X-(?:VERSION|TARGETDURATION|MEDIA-SEQUENCE):[0-9]+").matches(line))
                else -> {
                    val uri=WebBrowserNetworkMedia.address(URI(data.getString("page")).resolve(line).toString()) ?: error("Invalid reference")
                    result.add(Part(range(uri,data.getString("tvid")),duration ?: error("Missing duration")));duration=null
                    require(result.size<=2048)
                }
            }
        }
        require(duration==null && result.isNotEmpty() && kotlin.math.abs(result.sumOf { it.duration }-data.getDouble("duration"))<=2)
        // A complete declaration, not a prefix whose missing tail could pass as the programme.
        for(file in result.groupBy { it.range.uri.rawPath }.values) {
            var position=0L
            for(part in file) { require(part.range.start==position);position=part.range.end }
        }
        return result
    }
    fun metadata(item: JSONObject,currentPage: String): JSONObject? = runCatching {
        require(page(currentPage)!=null && item.optString("frame")==currentPage && item.optBoolean("blob") && !item.optBoolean("protected"))
        val data=item.getJSONObject("iqiyi")
        require(data.optString("id")==page(currentPage) && data.optString("revision").matches(Regex("[a-f0-9]{1,8}")))
        require(data.toString().length<=132*1024 && data.getBoolean("ready") && data.getString("page")==currentPage &&
            data.getString("src")==item.getString("iqiyi_source") && data.getString("src").startsWith("blob:"))
        for(key in listOf("tvid","vid")) require(data.getString(key).matches(Regex("[A-Za-z0-9]{1,64}")))
        require(data.getInt("bid")>=0 && data.getString("ff") in setOf("ts","265ts") && data.getInt("drm_type")==1 && !data.getBoolean("has_drm"))
        val duration=item.getDouble("duration")
        require(duration.isFinite() && duration>0 && duration<=172800 && kotlin.math.abs(duration-data.getDouble("duration"))<=.01)
        for(key in listOf("width","height")) require(item.getInt(key) in 1..16384 && item.getInt(key)==data.getInt(key))
        parts(data)
        data
    }.getOrNull()

    /** URLs already constructed by the active SDK's parsed levelInfoArr. The
     * original complete timeline stays compact; future files are dispatched lazily. */
    fun resourcePlan(item: JSONObject,currentPage: String): JSONObject? = runCatching {
        val data=metadata(item,currentPage) ?: return null
        require(data.optString("dispatch_status")=="selected_level")
        val parts=parts(data);val files=data.getJSONArray("dispatchers");require(files.length() in 1..2048)
        val duration=data.getDouble("dispatch_duration_ms")/1000.0
        require(duration.isFinite() && duration>0 && kotlin.math.abs(duration-data.getDouble("duration"))<=.5)
        require(parts.first().range.sd==0L)
        val durations=parts.mapIndexed { i,part ->
            val end=if(i+1<parts.size)parts[i+1].range.sd/1000.0 else duration
            (end-part.range.sd/1000.0).also { require(it.isFinite() && it>0 && it<=172800) }
        }
        val selected=(0 until files.length()).map { index ->
            val row=files.getJSONObject(index);val uri=WebBrowserNetworkMedia.address(row.getString("url")) ?: error("Invalid dispatch")
            require(uri.rawPath.substringAfterLast('/')==row.getString("source_id")+"."+data.getString("ff"))
            val start=row.getLong("start");val end=row.getLong("end");require(start>=0 && end>start)
            val associated=parts.filter { it.range.uri.rawPath==uri.rawPath }
            require(associated.any { it.range.start==start } && associated.any { it.range.end==end })
            val q=query(uri);require(q["qd_tvid"]==null || q["qd_tvid"]==data.getString("tvid"))
            Triple(uri,start,end)
        }
        val requests=parts.map { part ->
            val index=selected.indexOfFirst { (uri,start,end) -> uri.rawPath==part.range.uri.rawPath && start<=part.range.start && end>=part.range.end }
            require(index>=0 && part.range.end-part.range.start<=16*1024*1024)
            JSONObject().put("url",part.range.uri.toString()).put("file",index).put("start",part.range.start).put("end",part.range.end)
        }
        val timeline=buildString {
            append("#EXTM3U\n#EXT-X-TARGETDURATION:");append(kotlin.math.ceil(durations.max()).toInt());append('\n')
            for(i in parts.indices) { append("#EXTINF:");append(durations[i]);append(",\n");append(parts[i].range.uri);append('\n') }
            append("#EXT-X-ENDLIST\n")
        }
        JSONObject().put("page",currentPage).put("tvid",data.getString("tvid")).put("ff",data.getString("ff"))
            .put("files",JSONArray(files.toString())).put("requests",JSONArray(requests)).put("playlist",timeline)
    }.getOrNull()

    /** Convert declared time/byte ranges into standard HLS BYTERANGE over exact observed GETs.
     * No upstream URL/query/signature or credential is synthesized or reassigned. */
    fun plan(item: JSONObject,currentPage: String): JSONObject? = runCatching {
        val data=metadata(item,currentPage) ?: return null
        val parts=parts(data);val tvid=data.getString("tvid")
        val network=WebBrowserNetworkMedia.candidates(item,includeSegments=true)
        val records=(0 until network.length()).map { network.getJSONObject(it) }
        val manifests=records.filter { it.getString("kind")=="hls" && query(URI(it.getString("url")))["qd_tvid"]==tvid }.distinctBy { it.getString("url") }
        require(manifests.size==1)
        val observed=records.mapNotNull { r -> runCatching {
            require(r.getString("kind")=="segment" && r.optString("mime") in setOf("video/mp2t","application/octet-stream","binary/octet-stream"))
            val age=System.currentTimeMillis()-r.getLong("at");require(age in 0..1800000)
            val range=range(URI(r.getString("url")),tvid)
            require(query(range.uri)["qd_tvid"]==tvid && range.end-range.start<=16*1024*1024)
            r to range
        }.getOrNull() }
        val used=LinkedHashMap<String,JSONObject>()
        val mapped=parts.map { part ->
            val (record,actual)=observed.filter { (_,r) -> r.uri.rawPath==part.range.uri.rawPath && r.start<=part.range.start && r.end>=part.range.end }
                .minByOrNull { (_,r) -> r.end-r.start } ?: error("Unobserved current range")
            used[record.getString("url")]=record
            Triple(part,actual,record.getString("url"))
        }
        val body=buildString {
            append("#EXTM3U\n#EXT-X-VERSION:4\n#EXT-X-TARGETDURATION:")
            append(kotlin.math.ceil(parts.maxOf { it.duration }).toInt());append("\n#EXT-X-MEDIA-SEQUENCE:0\n")
            for((part,actual,url) in mapped) {
                append("#EXTINF:");append(part.duration);append(",\n#EXT-X-BYTERANGE:")
                append(part.range.end-part.range.start);append('@');append(part.range.start-actual.start);append('\n');append(url);append('\n')
            }
            append("#EXT-X-ENDLIST\n")
        }
        require(body.toByteArray(Charsets.UTF_8).size<=160*1024)
        JSONObject().put("manifest_url",manifests.single().getString("url")).put("playlist",body).put("network",JSONArray(used.values))
    }.getOrNull()
}
