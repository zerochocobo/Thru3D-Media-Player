package org.vrpassthroughplayer.plugin

import org.json.JSONObject

/** Media-time policy, independent of Android/network/model execution. */
internal object ListeningPolicy {
    class AudioInput(val path: String,val stream: Int,val cacheTrack: Int,val origin: Double,val external: Boolean)
    /** Split web playback attaches its required original audio through audio-add.
     * ff-index belongs to that audio file, never to the video-only main input.
     * Accept only the primary location retained by this playback host. */
    fun audioInput(path: String,metadata: JSONObject,primaryAudio: String,origin: Double): AudioInput? {
        val stream=metadata.optInt("stream_index",-1)
        if(stream<0)return null
        if(!metadata.optBoolean("external"))return AudioInput(path,stream,stream,origin,false)
        if(stream==Int.MAX_VALUE||primaryAudio.isEmpty()||metadata.optString("filename")!=primaryAudio)return null
        // MPV rebases an external file to its own start time. The native reader
        // must probe that origin rather than inherit the video container's.
        // Reserve negative identities so external stream 0 cannot reuse cues
        // from embedded stream 0; local lease tokens never enter cache keys.
        return AudioInput(primaryAudio,stream,-2-stream,Double.NaN,true)
    }
    fun percent(done: Double,total: Double): Int =
        if(!done.isFinite()||!total.isFinite()||total<=0)-1 else (done/total*100).toInt().coerceIn(0,100)
    fun accept(cue: Cue,language: String): Boolean {
        val letters=cue.text.filter {it.isLetterOrDigit()}.lowercase()
        if(letters.isEmpty())return false
        // Keep short acknowledgements and ordinary repeated dialogue. Reject
        // only long decoder loops, never a blacklist of legitimate sentences.
        if(language=="ja"&&letters.length>=12)for(size in 1..minOf(16,letters.length/4)){
            val unit=letters.take(size);var matched=size
            while(matched+size<=letters.length&&letters.regionMatches(matched,unit,0,size))matched+=size
            if(matched/size>=4&&matched>=letters.length*.9)return false
        }
        return true
    }
    fun failureState(stage: String, upstream: PlaybackFailure?): String = when {
        stage !in setOf("audio_open", "recognition") -> "listening_error"
        upstream?.sourceCode in setOf("cdn_connections_limited", "cdn_rate_limited") || upstream?.httpStatus in setOf(429,503) -> "source_busy"
        upstream != null -> "source_error"
        stage == "audio_open" -> "audio_error"
        else -> "listening_error"
    }
    /** media: the per-file settings key (sha256 hex) or empty; persist: the per-file
     * settings policy allows storing recognized text for this video. */
    data class Config(val enabled: Boolean=false,val language: String="ja",val lead: Int=12,val target: String="",
                      val media: String="",val persist: Boolean=false,val network: Boolean=true) {
        val translation get()=target.isNotEmpty() && target!=language && !(language=="zh"&&target=="zh-Hans")
        companion object {
            fun parse(value: String): Config {
                require(value.length<=1024)
                val j=JSONObject(value)
                require(j.get("enabled") is Boolean && j.getString("language") in setOf("zh","en","ja"))
                val lead=j.getDouble("lead");require(lead in setOf(8.0,12.0,20.0))
                val target=j.optString("target","");require(target.length<=16&&target.all {it.isLetter()||it=='-'})
                val media=j.optString("media","");require(media.isEmpty()||media.matches(Regex("[0-9a-f]{64}")))
                return Config(j.getBoolean("enabled"),j.getString("language"),lead.toInt(),target,
                    media,j.optBoolean("persist",false)&&media.isNotEmpty(),j.optBoolean("network",true))
            }
        }
    }
    data class Cue(val start: Double,val end: Double,val text: String) {
        val key get()="$start:$end:$text"
        fun json()=JSONObject().put("start",start).put("end",end).put("text",text)
        companion object {
            fun parse(j: JSONObject): Cue? {
                val a=j.optDouble("start");val b=j.optDouble("end");val text=j.optString("text").trim()
                if(!a.isFinite()||!b.isFinite()||a<0||b<=a||b-a>15||text.isEmpty()||text.length>1000)return null
                return Cue(a,b,text)
            }
        }
    }
    fun horizon(position: Double,speed: Double,lead: Int)=position+lead*speed.coerceIn(1.0,3.0)
    fun workHorizon(anchor: Double,position: Double,holding: Boolean,speed: Double,lead: Int)=
        horizon(if(holding)maxOf(anchor,position) else position,speed,lead)
    fun visible(cue: Cue,position: Double)=position>=cue.start&&position<cue.end
    /** Recognition behind the audible clock only produces cues that can never show.
     * A forward seek may settle after the anchor was taken from the pre-seek clock. */
    fun behind(through: Double,position: Double)=position>through+5.0
    fun retain(cues: Collection<Cue>,position: Double)=cues.filter {it.end>position-.25&&it.start<position+65}.sortedBy {it.start}.take(64)
}
