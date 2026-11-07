package org.vrpassthroughplayer.plugin

import java.io.Closeable
import java.net.URI
import java.net.URLDecoder
import org.json.JSONObject

/** Normal SDK-issued file dispatch and query-byte ranges, never credential/signature generation. */
internal class WebVideoIqiyiResources(plan: JSONObject,manifest: String) : Closeable {
    private class File(val url: URI,val id: String,val start: Long,val end: Long)
    private class Request(val uri: URI,val file: Int,val start: Long,val end: Long)
    private val tvid=plan.getString("tvid")
    private val ff=plan.getString("ff")
    private val files: List<File>
    private val requests: Map<URI,Request>
    private val resolved=HashMap<URI,URI>()
    @Volatile private var closed=false
    init {
        require(plan.toString().length<=256*1024 && tvid.matches(Regex("[A-Za-z0-9]{1,64}")) && ff in setOf("ts","265ts"))
        require(WebBrowserIqiyi.page(plan.getString("page"))!=null)
        val rows=plan.getJSONArray("files");require(rows.length() in 1..2048)
        files=(0 until rows.length()).map { i ->
            val f=rows.getJSONObject(i);val u=address(f.getString("url"));val id=f.getString("source_id")
            require(id.matches(Regex("[A-Za-z0-9_-]{1,160}")) && u.rawPath.substringAfterLast('/')=="$id.$ff")
            val q=query(u);require(q["qd_tvid"]==null || q["qd_tvid"]==tvid)
            val start=f.getLong("start");val end=f.getLong("end");require(start>=0 && end>start)
            File(u,id,start,end)
        }
        val parts=plan.getJSONArray("requests");require(parts.length() in 1..2048)
        val list=(0 until parts.length()).map { i ->
            val p=parts.getJSONObject(i);val uri=address(p.getString("url"));val file=p.getInt("file");val start=p.getLong("start");val end=p.getLong("end")
            require(file in files.indices && start>=files[file].start && end<=files[file].end && end>start && end-start<=16*1024*1024)
            val q=query(uri);require(q["start"]==start.toString() && q["end"]==end.toString() && q["contentlength"]==(end-start).toString())
            require(uri.rawPath==files[file].url.rawPath)
            Request(uri,file,start,end)
        }
        requests=list.associateBy { it.uri };require(requests.size==list.size)
        val refs=manifest.lineSequence().map(String::trim).filter { it.isNotEmpty() && !it.startsWith('#') }
            .map { address(URI(plan.getString("page")).resolve(it).toString()) }.toSet()
        require(refs==requests.keys)
    }
    fun expected(uri: URI): Long = requests[uri]?.let { it.end-it.start } ?: error("Undeclared resource")
    fun target(uri: URI,headers: (URI)->Map<String,String>,fetch: (URI,Map<String,String>,Boolean)->Pair<URI,ByteArray>): URI = try {
        targetInternal(uri,headers,fetch)
    } catch(error: MediaServerFailure) { throw error }
    catch(_: Exception) { throw IllegalStateException("Selected resource unavailable") }
    private fun targetInternal(uri: URI,headers: (URI)->Map<String,String>,fetch: (URI,Map<String,String>,Boolean)->Pair<URI,ByteArray>): URI {
        check(!closed)
        val request=requests[uri] ?: error("Undeclared resource");val file=files[request.file]
        val cached=synchronized(resolved) { check(!closed);resolved[file.url] }
        val cdn=cached ?: run {
            val endpoint=dispatchUrl(file.url);val (_,body)=fetch(endpoint,headers(endpoint),false)
            require(body.size<=128*1024)
            val payload=JSONObject(body.toString(Charsets.UTF_8));val returned=URI(payload.getString("uri"))
            require(returned.rawPath.substringAfterLast('/')=="${file.id}.$ff")
            val nodes=payload.getJSONArray("d");require(nodes.length() in 1..16)
            val selected=(0 until nodes.length()).mapNotNull { i -> runCatching {
                val u=address(nodes.getJSONObject(i).getString("URL"));val q=query(u)
                require(u.scheme=="https" && u.rawPath.substringAfterLast('/')=="${file.id}.$ff" && (q["qd_tvid"]==null || q["qd_tvid"]==tvid));u
            }.getOrNull() }.firstOrNull() ?: error("Wrong dispatched file")
            synchronized(resolved) { check(!closed);resolved[file.url]=selected }
            selected
        }
        return rangeUrl(cdn,request.start,request.end)
    }
    override fun close() { synchronized(resolved) { closed=true;resolved.clear() } }
    companion object {
        private fun address(value: String): URI = WebBrowserNetworkMedia.address(value) ?: error("Invalid resource address")
        private fun query(uri: URI): Map<String,String> {
            val result=LinkedHashMap<String,String>()
            for(raw in uri.rawQuery.orEmpty().split('&').filter(String::isNotEmpty)) {
                val name=URLDecoder.decode(raw.substringBefore('='),"UTF-8");require(name !in result)
                result[name]=URLDecoder.decode(raw.substringAfter('=',""),"UTF-8")
            }
            return result
        }
        internal fun dispatchUrl(uri: URI): URI {
            val q=query(uri);val extra=listOf("pv" to "0.1","cross-domain" to "1","mss" to "3").filter { it.first !in q }
            return URI(uri.toString()+if(extra.isEmpty()) "" else (if(uri.rawQuery.isNullOrEmpty()) "?" else "&")+extra.joinToString("&") { "${it.first}=${it.second}" })
        }
        internal fun rangeUrl(uri: URI,start: Long,end: Long): URI {
            require(start>=0 && end>start);query(uri)
            val replacements=linkedMapOf("start" to start.toString(),"end" to end.toString(),"contentlength" to (end-start).toString())
            val parts=uri.rawQuery.orEmpty().split('&').filter(String::isNotEmpty).map { raw ->
                val name=URLDecoder.decode(raw.substringBefore('='),"UTF-8")
                replacements.remove(name)?.let { "$name=$it" } ?: raw
            }+replacements.map { "${it.key}=${it.value}" }
            return URI("${uri.scheme}://${uri.rawAuthority}${uri.rawPath}?${parts.joinToString("&")}")
        }
    }
}
