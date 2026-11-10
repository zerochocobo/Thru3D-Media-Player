package org.vrpassthroughplayer.plugin

import java.net.URI
import java.net.URLDecoder
import org.json.JSONObject

/** Received card/MPD identity and both the DOM and actually requested HTTP file. */
object WebBrowserNaver {
    private fun query(uri: URI)=uri.rawQuery.orEmpty().split('&').filter(String::isNotEmpty).map {
        URLDecoder.decode(it.substringBefore('='),"UTF-8") to URLDecoder.decode(it.substringAfter('=',""),"UTF-8")
    }
    fun document(value: String): Boolean=runCatching {
        val u=URI(value);val q=query(u)
        value.length<=8192 && u.scheme=="https" && u.host=="m.naver.com" && u.rawPath=="/shorts/" &&
            u.rawUserInfo==null && u.port in setOf(-1,443) && q.filter { it.first=="serviceType" }.map { it.second }.singleOrNull() in setOf("NTV","CLIP")
    }.getOrDefault(false)
    fun page(value: String): String?=runCatching {
        require(document(value));val u=URI(value);require(u.rawFragment==null)
        query(u).filter { it.first=="seedMediaId" }.singleOrNull()?.second?.takeIf { it.matches(Regex("[A-F0-9]{32,64}")) }
    }.getOrNull()
    private fun service(value: String)=query(URI(value)).single { it.first=="serviceType" }.second
    fun canonical(id: String,service: String="NTV")="https://m.naver.com/shorts/?serviceType=$service&seedMediaId=$id"
    fun canonicalPage(value: String): String?=page(value)?.let{canonical(it,service(value))}
    fun observing(value: String)=runCatching {
        val u=URI(value)
        value.length<=8192 && u.scheme=="https" && u.host=="m.naver.com" && u.rawPath=="/shorts/" && u.rawUserInfo==null && u.port in setOf(-1,443)
    }.getOrDefault(false)
    fun enabled(value: String)=document(value)
    private data class Resource(val source: String,val kind: String,val start: Double?=null,val end: Double?=null)
    private fun resource(value: String): Resource?=runCatching {
        require(value.length<=16384)
        val u=URI(value);require(u.scheme=="https" && u.rawUserInfo==null)
        val source=value.substringBefore('#');require(WebBrowserNetworkMedia.address(source)!=null)
        val fragment=u.rawFragment ?: return Resource(source,"plain")
        if(fragment.matches(Regex("tid=[A-Za-z0-9_-]{22}")))return Resource(source,"tracking")
        val m=Regex("t=(?:npt:)?([0-9]+(?:\\.[0-9]+)?)(?:,([0-9]+(?:\\.[0-9]+)?))?").matchEntire(fragment) ?: return null
        val start=m.groupValues[1].toDouble();val end=m.groupValues[2].takeIf(String::isNotEmpty)?.toDouble()
        require(start.isFinite() && start in 0.0..86400.0 && (end==null || end.isFinite() && end>start && end<=86400))
        Resource(source,"temporal",start,end)
    }.getOrNull()
    data class Timeline(val base: URI,val playlist: String,val refs: Set<String>,val duration: Double)
    private fun declared(data: JSONObject): Timeline?=runCatching {
        val plan=data.getJSONObject("timeline");require(plan.toString().length<=24*1024)
        val base=WebBrowserNetworkMedia.address(plan.getString("base")) ?: error("Invalid segment base")
        require(base.scheme=="https" && base.path.endsWith('/') && base.rawQuery==null)
        val template=plan.getString("media");val representation=plan.getString("representation")
        require(template.length<=16384 && template.none{it<' ' || it=='\u007f'} && representation.matches(Regex("[A-Za-z0-9_.-]{1,80}")))
        val params=Regex("\\$([^$]+)\\$").findAll(template).map{it.groupValues[1]}.toList()
        val numberToken=Regex("Number(?:%0([1-9][0-9]?)d)?")
        require(params.contains("RepresentationID") && params.any{numberToken.matches(it)} && params.all{p->p=="RepresentationID" || numberToken.matchEntire(p)?.let{it.groupValues[1].ifEmpty{"0"}.toInt()<=10}==true})
        fun number(o: JSONObject,key: String): Long {val v=o.get(key);require(v is Number);val n=v.toLong();require(v.toDouble().isFinite() && v.toDouble()==n.toDouble());return n}
        val start=number(plan,"start");val scale=number(plan,"timescale")
        require(start in 0..1000000 && scale in 1..1000000)
        val rows=plan.getJSONArray("rows");require(rows.length() in 1..256)
        var end=0L;var serial=start;var gaps=0L;var previousCount=0L;val segments=ArrayList<Pair<String,Long>>();var chars=0
        for(i in 0 until rows.length()){
            val row=rows.getJSONObject(i);val t=number(row,"t");val d=number(row,"d");val r=number(row,"r")
            require(d in 1..86400000000L && r in 0..2047 && segments.size+r+1<=2048)
            val gap=t-end;require(gap in 0..previousCount && gap.toDouble()/scale<=previousCount*.001 && (gap==0L || segments.isNotEmpty()))
            gaps+=gap;require(gaps.toDouble()/scale<=.1)
            if(gap>0){val previous=segments.last();segments[segments.lastIndex]=previous.first to previous.second+gap}
            end=t
            repeat((r+1).toInt()){
                val valueNumber=serial++
                val text=Regex("\\$(RepresentationID|Number)(?:%0([1-9][0-9]?)d)?\\$").replace(template){m->
                    if(m.groupValues[1]=="RepresentationID")representation else valueNumber.toString().padStart(m.groupValues[2].ifEmpty{"0"}.toInt(),'0')
                };require(!text.contains('$'))
                val uri=base.resolve(text);require(uri.scheme=="https" && uri.rawUserInfo==null && uri.rawFragment==null && uri.path.endsWith(".ts"))
                val value=WebBrowserNetworkMedia.address(uri.toString()) ?: error("Invalid segment")
                chars+=value.toString().length+64;require(chars<=160*1024)
                segments.add(value.toString() to d);end=Math.addExact(end,d)
            }
            previousCount=r+1
        }
        val duration=end.toDouble()/scale;require(duration>0 && duration<=86400 && segments.map{it.first}.toSet().size==segments.size)
        val max=segments.maxOf{it.second.toDouble()/scale}
        val root=WebBrowserNetworkMedia.address(data.getString("source")) ?: error("Invalid declared export")
        require(root.scheme=="https" && kotlin.math.abs(duration-data.getDouble("expected_duration"))<=.5)
        val body=buildString {
            append("#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:${kotlin.math.ceil(max).toInt()}\n#EXT-X-MEDIA-SEQUENCE:$start\n#EXT-X-PLAYLIST-TYPE:VOD\n")
            segments.forEach{(uri,ticks)->append("#EXTINF:${ticks.toDouble()/scale},\n$uri\n")};append("#EXT-X-ENDLIST\n")
        }
        require(body.toByteArray(Charsets.UTF_8).size<=160*1024)
        Timeline(root,body,segments.map{it.first}.toSet(),duration)
    }.getOrNull()
    fun timeline(item: JSONObject,currentPage: String): Timeline?=metadata(item,currentPage)?.takeIf{it.optString("format")=="segment_timeline"}?.let(::declared)
    /** Fixed scalar diagnostics only; never return declarations, sources or headers. */
    fun diagnostics(item: JSONObject,currentPage: String): JSONObject=runCatching {
        val d=item.getJSONObject("naver");val id=d.optString("id");val kind=d.optString("service_type","NTV")
        val plan=declared(d);val requests=WebBrowserNetworkMedia.candidates(item,true)
        JSONObject().put("document_valid",document(currentPage)).put("frame_match",item.optString("frame")==currentPage)
            .put("unprotected",!item.optBoolean("protected")).put("canonical_match",page(d.optString("page"))==id && d.optString("page")==canonical(id,kind))
            .put("data_size",d.toString().length).put("document_match",d.optString("document")==currentPage).put("binding_match",d.optString("binding")=="received_card_mpd")
            .put("revision_valid",d.optString("revision").matches(Regex("[a-f0-9]{1,8}")))
            .put("current_source_match",if(d.optString("format")=="segment_timeline")item.optString("source").isEmpty() else d.optString("current_source")==item.optString("source")).put("source_match",d.optString("source")==item.optString("naver_source"))
            .put("dimensions_match",d.optInt("width")==item.optInt("width") && d.optInt("height")==item.optInt("height"))
            .put("duration_match",kotlin.math.abs(d.optDouble("duration")-item.optDouble("duration"))<=.001)
            .put("expected_match",kotlin.math.abs(d.optDouble("expected_duration")-item.optDouble("duration"))<=.5)
            .put("clip_watch_match",kind=="CLIP" && service(currentPage)=="CLIP" && page(currentPage)==id)
            .put("blob_flag",item.optBoolean("blob")).put("blob_origin_match",d.optString("current_source").startsWith("blob:https://m.naver.com/"))
            .put("blob_kind",d.optString("fragment_kind")=="blob").put("timeline_valid",plan!=null)
            .put("timeline_duration_match",plan!=null && kotlin.math.abs(plan.duration-item.optDouble("duration"))<=.5)
            .put("requests",requests.length()).put("exact_segments",(0 until requests.length()).count{val r=requests.getJSONObject(it);r.optString("kind")=="segment" && r.optString("url") in plan?.refs.orEmpty()})
    }.getOrElse{JSONObject().put("diagnostics_available",false)}
    fun metadata(item: JSONObject,currentPage: String): JSONObject?=runCatching {
        require(document(currentPage) && item.optString("frame")==currentPage && !item.optBoolean("protected"))
        val data=item.getJSONObject("naver");val id=data.getString("id")
        val kind=data.optString("service_type","NTV")
        require(kind in setOf("NTV","CLIP") && data.toString().length<=32*1024 && page(data.getString("page"))==id && data.getString("page")==canonical(id,kind))
        require(data.getString("document")==currentPage && data.getString("binding")=="received_card_mpd")
        require(data.getString("revision").matches(Regex("[a-f0-9]{1,8}")))
        val segmented=data.optString("format")=="segment_timeline"
        val current=if(segmented)data.getString("current_source") else item.getString("source")
        require((if(segmented)item.getString("source").isEmpty() else data.getString("current_source")==current) && item.getString("naver_source")==data.getString("source"))
        val width=item.getInt("width");val height=item.getInt("height");val duration=item.getDouble("duration")
        require(width in 1..16384 && height in 1..16384 && width==data.getInt("width") && height==data.getInt("height"))
        require(duration.isFinite() && duration>0 && duration<=86400 && kotlin.math.abs(duration-data.getDouble("duration"))<=.001)
        val expected=data.getDouble("expected_duration")
        require(expected.isFinite() && expected>0 && expected<=86400 && kotlin.math.abs(duration-expected)<=.5)
        if(data.optString("format")=="segment_timeline"){
            require(kind=="CLIP" && service(currentPage)=="CLIP" && page(currentPage)==id && item.optBoolean("blob") &&
                current.length<=8192 && current.startsWith("blob:https://m.naver.com/") && current.none{it<' ' || it=='\u007f'} && data.getString("fragment_kind")=="blob")
            val plan=declared(data) ?: return null
            require(kotlin.math.abs(plan.duration-duration)<=.5)
            val requests=WebBrowserNetworkMedia.candidates(item,true)
            require((0 until requests.length()).any{val r=requests.getJSONObject(it);r.optString("kind")=="segment" && r.optString("url") in plan.refs})
        }else{
            require(kind=="NTV" && !item.optBoolean("blob") && data.optString("format","file")=="file")
            val selected=resource(current) ?: return null
            require(data.getString("source")==selected.source && data.getString("fragment_kind")==selected.kind)
            require((selected.start==null || selected.start<=duration) && (selected.end==null || selected.end<=duration+.5))
            val requests=WebBrowserNetworkMedia.candidates(item)
            require((0 until requests.length()).any {val r=requests.getJSONObject(it);r.optString("kind")=="file" && r.optString("url")==selected.source &&
                (selected.kind!="tracking" || r.optString("request_url")==current)})
        }
        data
    }.getOrNull()
}
