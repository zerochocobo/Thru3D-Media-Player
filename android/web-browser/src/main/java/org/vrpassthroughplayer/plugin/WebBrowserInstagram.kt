package org.vrpassthroughplayer.plugin

import java.net.URI
import org.json.JSONObject
import org.w3c.dom.Element

/** Current rendered post/clear inline MPD; the old manual resolver stays independent. */
object WebBrowserInstagram {
    private const val ENABLED=true // Current finite detail posts; see the actual local acceptance record.
    data class Representation(val id: String,val url: String,val kind: String,val width: Int,val height: Int,
        val bandwidth: Long,val codec: String,val initEnd: Long,val indexEnd: Long)
    data class Manifest(val duration: Double,val tracks: List<Representation>)
    fun document(value: String): Boolean=runCatching {
        val u=URI(value)
        value.length<=8192 && u.scheme=="https" && u.host in setOf("www.instagram.com","instagram.com") && u.rawUserInfo==null && u.port in setOf(-1,443) && u.rawFragment==null
    }.getOrDefault(false)
    fun observing(value: String)=ENABLED && document(value)
    fun enabled(value: String)=ENABLED && page(value)!=null
    fun page(value: String): String?=runCatching {
        require(document(value));Regex("/(?:reel|p|tv)/([A-Za-z0-9_-]{5,64})/?").matchEntire(URI(value).rawPath.orEmpty())?.groupValues?.get(1)
    }.getOrNull()
    private fun range(value: String): Pair<Long,Long>?=runCatching {
        val m=Regex("(0|[1-9][0-9]{0,12})-(0|[1-9][0-9]{0,12})").matchEntire(value) ?: return null
        (m.groupValues[1].toLong() to m.groupValues[2].toLong()).also{require(it.first<=it.second)}
    }.getOrNull()
    private fun children(e: Element,name: String)=(0 until e.childNodes.length).map{e.childNodes.item(it)}.filterIsInstance<Element>().filter{it.localName==name}

    fun manifest(xml: String): Manifest?=runCatching {
        require(xml.length<=96*1024 && !Regex("<!DOCTYPE|<!ENTITY",RegexOption.IGNORE_CASE).containsMatchIn(xml))
        // Reuse WebVideoNetworkCapture.dash's Android-compatible parser boundary.
        val factory=javax.xml.parsers.DocumentBuilderFactory.newInstance().apply{isNamespaceAware=true;isExpandEntityReferences=false}
        val parsed=factory.newDocumentBuilder().apply{
            setEntityResolver{_,_->org.xml.sax.InputSource(java.io.StringReader(""))}
            setErrorHandler(object:org.xml.sax.helpers.DefaultHandler(){
                override fun error(e:org.xml.sax.SAXParseException){throw org.xml.sax.SAXException("Invalid manifest")}
                override fun fatalError(e:org.xml.sax.SAXParseException){throw org.xml.sax.SAXException("Invalid manifest")}
            })
        }.parse(org.xml.sax.InputSource(java.io.StringReader(xml)))
        val root=parsed.documentElement
        require(root.localName=="MPD" && root.getAttribute("type")=="static" && children(root,"Period").size==1)
        require(children(root,"Period").single().getAttribute("start") in setOf("","PT0S","PT0.0S"))
        val nodes=root.getElementsByTagName("*")
        for(i in 0 until nodes.length){val e=nodes.item(i) as Element
            require(e.localName !in setOf("ContentProtection","SegmentTemplate","SegmentList","Location","UTCTiming") && !e.hasAttributeNS("http://www.w3.org/1999/xlink","href"))}
        val duration=java.time.Duration.parse(root.getAttribute("mediaPresentationDuration")).toMillis()/1000.0
        require(duration.isFinite() && duration>0 && duration<=86400)
        val reps=root.getElementsByTagNameNS("*","Representation");require(reps.length in 1..32)
        val tracks=(0 until reps.length).map{i->
            val rep=reps.item(i) as Element;val id=rep.getAttribute("id")
            require(id.matches(Regex("[A-Za-z0-9_.:-]{1,200}")))
            val source=children(rep,"BaseURL").single().textContent
            val uri=WebBrowserNetworkMedia.address(source)
            require(uri?.scheme=="https" && uri.port in setOf(-1,443) && uri.rawQuery.orEmpty().split('&').none{it.substringBefore('=') in setOf("bytestart","byteend")})
            val segment=children(rep,"SegmentBase").single();val init=children(segment,"Initialization").single()
            val initial=range(init.getAttribute("range")) ?: error("Missing initialization")
            val index=range(segment.getAttribute("indexRange")) ?: error("Missing index")
            require(initial.first==0L && maxOf(initial.second,index.second)<=2*1024*1024 && init.getAttribute("sourceURL").isEmpty())
            val adapt=rep.parentNode as? Element ?: error("Missing adaptation")
            val mime=rep.getAttribute("mimeType").ifEmpty{adapt.getAttribute("mimeType")}
            require(mime in setOf("video/mp4","audio/mp4"))
            val video=mime=="video/mp4"
            val width=rep.getAttribute("width").ifEmpty{"0"}.toInt();val height=rep.getAttribute("height").ifEmpty{"0"}.toInt()
            if(video)require(width in 1..8192 && height in 1..8192)
            val bandwidth=rep.getAttribute("bandwidth").toLong();require(bandwidth in 1..1_000_000_000L)
            Representation(id,source,if(video)"video" else "audio",width,height,bandwidth,
                rep.getAttribute("codecs").ifEmpty{adapt.getAttribute("codecs")},initial.second,index.second)
        }
        require(tracks.map{it.id}.toSet().size==tracks.size)
        Manifest(duration,tracks)
    }.getOrNull()

    /** Compare exact original selectors, interpreting only the two declared
     * transport range fields. This does not return/reconstruct a file address. */
    fun payloadRequest(track: Representation,value: String): Boolean=runCatching {
        val actual=WebBrowserNetworkMedia.address(value) ?: return false
        val declared=URI(track.url)
        require(actual.scheme==declared.scheme && actual.host==declared.host &&
            (if(actual.port<0)443 else actual.port)==(if(declared.port<0)443 else declared.port) && actual.rawPath==declared.rawPath)
        val tokens=actual.rawQuery.orEmpty().split('&')
        require(tokens.filter{it.substringBefore('=') !in setOf("bytestart","byteend")}.joinToString("&")==declared.rawQuery.orEmpty())
        fun field(name: String)=tokens.filter{it.substringBefore('=')==name}.single().substringAfter('=')
        val start=field("bytestart");val end=field("byteend")
        require(start.matches(Regex("0|[1-9][0-9]{0,12}")) && end.matches(Regex("0|[1-9][0-9]{0,12}")))
        start.toLong()<=end.toLong() && end.toLong()>maxOf(track.initEnd,track.indexEnd)
    }.getOrDefault(false)

    fun metadata(item: JSONObject,currentPage: String): JSONObject?=runCatching {
        val id=page(currentPage) ?: return null
        require(item.optString("frame")==currentPage && !item.optBoolean("protected") && item.optBoolean("blob"))
        val source=item.getString("instagram_source")
        require(source.startsWith("blob:https://www.instagram.com/") || source.startsWith("blob:https://instagram.com/"))
        val data=item.getJSONObject("instagram")
        require(data.toString().length<=192*1024 && data.getString("id")==id && data.getString("page")==currentPage &&
            data.getString("media_id").matches(Regex("[0-9]{5,30}")) && data.getString("revision").matches(Regex("[a-f0-9]{1,8}")))
        val graph=manifest(data.getString("manifest")) ?: return null
        val width=item.getInt("width");val height=item.getInt("height");val duration=item.getDouble("duration")
        require(width in 1..8192 && height in 1..8192 && width==data.getInt("width") && height==data.getInt("height"))
        require(duration.isFinite() && duration>0 && kotlin.math.abs(duration-data.getDouble("duration"))<=.001 &&
            kotlin.math.abs(duration-graph.duration)<=maxOf(.1,graph.duration*.0001) && kotlin.math.abs(graph.duration-data.getDouble("expected_duration"))<=.001)
        val time=item.optDouble("time",0.0);val start=data.optDouble("start_seconds",time)
        require(time.isFinite() && time>=0 && time<=duration+.1 && start.isFinite() && start>=0 && start<=duration)
        if(item.optBoolean("instagram_ended"))require(start==0.0 && kotlin.math.abs(time-duration)<=.1)
        else require(kotlin.math.abs(start-time)<=.001)
        require(data.get("has_audio") is Boolean)
        val requests=WebBrowserNetworkMedia.candidates(item)
        val files=(0 until requests.length()).map{requests.getJSONObject(it)}.filter{it.optString("kind")=="file"}.map{it.getString("url")}
        fun observed(t: Representation)=files.any{payloadRequest(t,it)}
        fun selected(value: JSONObject,kind: String): Representation {
            val track=graph.tracks.single{it.id==value.getString("id") && it.kind==kind}
            require(track.url==value.getString("url") && track.bandwidth==value.getLong("bandwidth") && observed(track))
            val evidence=value.getJSONArray("requests");require(evidence.length() in 1..8)
            require((0 until evidence.length()).all{val address=evidence.getString(it);address in files && payloadRequest(track,address)})
            return track
        }
        val video=selected(data.getJSONObject("video"),"video")
        require(video.width==width && video.height==height)
        val allowed=graph.tracks.filter{it.kind=="video" && it.width==width && it.height==height && observed(it)}
        require(video.bandwidth==allowed.maxOf{it.bandwidth})
        if(data.getBoolean("has_audio")){
            val audio=selected(data.getJSONObject("audio"),"audio")
            require(graph.tracks.filter{it.kind=="audio" && observed(it)}.single()==audio)
        }else require(graph.tracks.none{it.kind=="audio"} && data.isNull("audio"))
        data
    }.getOrNull()

    /** One bounded return witness: identity only, never request credentials. */
    fun identity(data: JSONObject)=JSONObject().apply {
        for(key in listOf("id","page","media_id","manifest","revision","width","height","duration","has_audio"))put(key,data.get(key))
        put("video_url",data.getJSONObject("video").getString("url"))
        put("audio_url",data.optJSONObject("audio")?.optString("url").orEmpty())
    }
    fun matchesIdentity(item: JSONObject,identity: JSONObject,currentPage: String): Boolean=runCatching {
        val data=metadata(item,currentPage) ?: return false
        val actual=WebBrowserInstagram.identity(data)
        listOf("id","page","media_id","manifest","revision","width","height","has_audio","video_url","audio_url").all{actual.get(it)==identity.get(it)} &&
            kotlin.math.abs(actual.getDouble("duration")-identity.getDouble("duration"))<=.001
    }.getOrDefault(false)
}
