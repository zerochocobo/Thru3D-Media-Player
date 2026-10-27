package org.vrpassthroughplayer.plugin

import org.json.JSONObject

/** Immutable inputs captured when the user adds a film, never the next film's clock. */
internal data class ListeningTaskSpec(val media: String,val uri: String,val title: String,val language: String,
    val target: String,val duration: Double,val track: Int,val playlist: Int,val disc: Boolean,val origin: Double,
    val persist: Boolean,val network: Boolean,val model: String="") {
    fun json()=JSONObject().put("media",media).put("uri",uri).put("title",title).put("language",language)
        .put("target",target).put("duration",duration).put("track",track).put("playlist",playlist)
        .put("disc",disc).put("origin",origin).put("persist",persist).put("network",network).put("model",model)
    // A signed HTTP URL is not a durable capability. Resolve stable library URIs again.
    val durable get()=persist && uri.substringBefore(':') in setOf("file","content","usb","cloud","smb","medialib","dlna")
    companion object {
        fun parse(j: JSONObject): ListeningTaskSpec {
            val media=j.getString("media");require(media.matches(Regex("[a-f0-9]{64}")))
            val uri=j.getString("uri");require(uri.length in 1..8192 && uri.substringBefore(':') in setOf("file","content","usb","cloud","smb","medialib","dlna","http","https"))
            val language=j.getString("language");require(language in setOf("zh","en","ja"))
            val target=j.optString("target");require(target.length<=16 && target.all{it.isLetter()||it=='-'})
            val duration=j.getDouble("duration");require(duration.isFinite() && duration in 0.01..86400.0)
            val track=j.getInt("track");require(track in 0..1024)
            val playlist=j.optInt("playlist",-1);require(playlist in -1..99999)
            val origin=j.optDouble("origin",0.0);require(origin.isFinite())
            val model=j.optString("model");require(model.isEmpty()||model.matches(Regex("[a-f0-9]{64}")))
            return ListeningTaskSpec(media,uri,j.optString("title").take(256),language,
                if(target==language || language=="zh"&&target=="zh-Hans")"" else target,duration,track,playlist,j.optBoolean("disc"),origin,
                j.optBoolean("persist"),j.optBoolean("network",true),model)
        }
    }
}
