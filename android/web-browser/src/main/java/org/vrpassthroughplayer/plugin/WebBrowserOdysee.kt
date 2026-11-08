package org.vrpassthroughplayer.plugin

import java.net.URI
import java.util.Locale
import org.json.JSONObject

/** Current free claim declaration and actual complete-file request; never API replay. */
object WebBrowserOdysee {
    private const val ENABLED=true // Current free-claim file flow passed the production desktop preflight.
    private data class Identity(val id: String,val slug: String,val prefix: String)
    private data class FileIdentity(val claim: String,val file: String,val slug: String?)
    fun document(value: String): Boolean=runCatching {
        val u=URI(value)
        value.length<=8192 && u.scheme=="https" && u.host in setOf("odysee.com","www.odysee.com") &&
            u.port in setOf(-1,443) && u.rawUserInfo==null && u.rawFragment==null
    }.getOrDefault(false)
    private fun identity(value: String): Identity?=runCatching {
        require(document(value));val path=URI(value).rawPath.orEmpty();require(!path.contains(".."))
        val m=Regex("/(?:@[A-Za-z0-9_.-]+(?::[a-fA-F0-9]{1,40})?/)?([A-Za-z0-9_.-]+):([a-fA-F0-9]{1,40})/?").matchEntire(path) ?: return null
        Identity(path.trim('/'),m.groupValues[1],m.groupValues[2].lowercase(Locale.ROOT))
    }.getOrNull()
    fun page(value: String): String?=identity(value)?.id
    fun observing(value: String)=ENABLED && document(value)
    fun enabled(value: String)=ENABLED && page(value)!=null
    private fun file(value: String): FileIdentity?=runCatching {
        val u=WebBrowserNetworkMedia.address(value) ?: return null;require(u.scheme=="https")
        val old=Regex("/api/v[34]/streams/free/([A-Za-z0-9_.-]+)/([a-fA-F0-9]{40})/([a-fA-F0-9]{6}\\.mp4)").matchEntire(u.rawPath)
        if(old!=null)FileIdentity(old.groupValues[2].lowercase(Locale.ROOT),old.groupValues[3].lowercase(Locale.ROOT),old.groupValues[1])
        else Regex("/v6/streams/([a-fA-F0-9]{40})/([a-fA-F0-9]{6}\\.mp4)").matchEntire(u.rawPath)?.let {
            FileIdentity(it.groupValues[1].lowercase(Locale.ROOT),it.groupValues[2].lowercase(Locale.ROOT),null)
        }
    }.getOrNull()
    fun metadata(item: JSONObject,currentPage: String): JSONObject?=runCatching {
        val current=identity(currentPage) ?: return null
        require(item.optString("frame")==currentPage && !item.optBoolean("protected") && !item.optBoolean("blob"))
        val data=item.getJSONObject("odysee")
        require(data.toString().length<=48*1024 && data.getString("id")==current.id && data.getString("page")==currentPage)
        require(data.getString("revision").matches(Regex("[a-f0-9]{1,8}")))
        val source=item.getString("source");val actual=file(source) ?: return null
        require(source==data.getString("source") && source==item.getString("odysee_source"))
        val declared=file(data.getString("declared_source")) ?: return null
        require(declared.slug==current.slug && actual.claim==declared.claim && actual.file==declared.file && actual.claim.startsWith(current.prefix))
        require(actual.slug==null || actual.slug==current.slug)
        require(data.getString("claim_id")==actual.claim && data.getString("file_id")==actual.file)
        val width=item.getInt("width");val height=item.getInt("height");val duration=item.getDouble("duration")
        require(width in 1..16384 && height in 1..16384 && width==data.getInt("width") && height==data.getInt("height"))
        require(duration.isFinite() && duration>0 && duration<=86400 && kotlin.math.abs(duration-data.getDouble("duration"))<=.001)
        val expected=data.getDouble("expected_duration");require(expected.isFinite() && expected>0 && expected<=86400 && data.opt("whole_seconds") is Boolean)
        require(if(data.getBoolean("whole_seconds"))kotlin.math.floor(duration)==expected else kotlin.math.abs(duration-expected)<=.5)
        val requests=WebBrowserNetworkMedia.candidates(item)
        require((0 until requests.length()).any {val r=requests.getJSONObject(it);r.optString("kind")=="file" && r.optString("url")==source})
        data
    }.getOrNull()
}
