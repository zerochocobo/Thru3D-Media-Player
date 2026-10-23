package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import java.security.MessageDigest
import kotlin.math.*

/** Bounded streaming segmentation. No speaker identity or separation is inferred from VAD. */
internal class VoiceSpeechCandidates(private val from: Double,private val until: Double,private val track: Int) {
    companion object {
        const val STEP=512.0/16000
        fun range(start: Double,end: Double,maximum: Double,duration: Double=0.0) {
            require(start.isFinite()&&end.isFinite()&&start>=0&&end>start&&end-start<=maximum+1e-6){"voice_invalid_range"}
            require(duration<=0||end<=duration+0.001){"voice_invalid_range"}
        }
        fun candidate(start: Double,end: Double,track: Int,manual: Boolean=false): JSONObject {
            range(start,end,10.0);require(end-start>=3.0-1e-6){"voice_invalid_range"}
            val identity="$track:${(start*1000).roundToLong()}:${(end*1000).roundToLong()}"
            val key=MessageDigest.getInstance("SHA-256").digest(identity.toByteArray()).joinToString(""){"%02x".format(it)}
            return JSONObject().put("key",key).put("start",start).put("end",end).put("text","")
                .put("timing","audio").put("manual",manual)
        }
        /** Keep row identity and original bounds so repeated crops remain reversible. */
        fun trim(rows: JSONArray,key: String,start: Double,end: Double): JSONArray {
            require(start.isFinite()&&end.isFinite()&&start>=0&&end-start>=2.999&&end-start<=10.001){"voice_invalid_range"}
            val index=(0 until rows.length()).firstOrNull {rows.getJSONObject(it).getString("key")==key}
                ?: error("voice_candidate_missing")
            val original=rows.getJSONObject(index);require(original.optString("timing")=="audio"){"voice_invalid_range"}
            val lower=original.optDouble("original_start",original.getDouble("start"))
            val upper=original.optDouble("original_end",original.getDouble("end"))
            require(start>=lower-0.001&&end<=upper+0.001){"voice_invalid_range"}
            var clippedStart=start.coerceAtLeast(lower);var clippedEnd=end.coerceAtMost(upper)
            // UI coordinates are float32. Restore the exact minimum after roundoff.
            if(clippedEnd-clippedStart<3.0){
                if(clippedStart+3.0<=upper)clippedEnd=clippedStart+3.0 else clippedStart=clippedEnd-3.0
            }
            val row=JSONObject(original.toString()).put("original_start",lower).put("original_end",upper)
                .put("start",clippedStart).put("end",clippedEnd)
            if(!row.has("original_waveform"))row.put("original_waveform",row.optJSONArray("waveform") ?: JSONArray())
            row.remove("waveform") // Selected audio will regenerate its own envelope on audition.
            return JSONArray((0 until rows.length()).map {if(it==index)row else rows.getJSONObject(it)})
        }
    }
    private val rows=ArrayList<JSONObject>()
    private var onset=-1.0
    private var lastSpeech=0.0
    private var speechFrames=0
    private var clipped=0
    private var power=0.0
    private var tooLong=false
    private val envelope=ArrayList<Float>()
    var through=from;private set
    fun accept(start: Double,probability: FloatArray,rms: FloatArray,peak: FloatArray,finished: Boolean): JSONArray {
        require(probability.size==rms.size&&rms.size==peak.size&&probability.size<=32)
        require(start.isFinite()&&start>=through-0.001)
        for(i in probability.indices){
            val time=start+i*STEP
            require(probability[i].isFinite()&&rms[i].isFinite()&&peak[i].isFinite())
            val speech=probability[i]>=if(onset<0)0.55f else 0.35f
            if(speech){
                if(onset<0){onset=time;speechFrames=0;clipped=0;power=0.0;tooLong=false;envelope.clear()}
                lastSpeech=time+STEP;speechFrames++;power+=rms[i]*rms[i];if(peak[i]>=0.999f)clipped++
            }
            if(onset>=0){
                if(envelope.size<320)envelope+=rms[i]
                if(time+STEP-onset>9.8)tooLong=true
                if(!speech&&time+STEP-lastSpeech>=0.16)finish(time+STEP)
            }
            through=min(until,time+STEP)
        }
        if(finished)finish(through)
        return JSONArray(rows.toList())
    }
    private fun finish(boundary: Double) {
        if(onset<0)return
        val start=max(from,onset-0.10);val end=min(min(until,boundary),lastSpeech+0.08)
        val seconds=end-start
        val speechSeconds=speechFrames*STEP
        if(!tooLong&&seconds in 3.0..10.0&&speechSeconds>=2.7&&speechSeconds/seconds>=0.65&&
            sqrt(power/max(1,speechFrames))>=0.003&&clipped.toDouble()/max(1,speechFrames)<0.10&&rows.size<256){
            val wave=JSONArray()
            for(i in 0 until 32){val lo=i*envelope.size/32;val hi=max(lo+1,(i+1)*envelope.size/32).coerceAtMost(envelope.size)
                wave.put((lo until hi).maxOfOrNull {envelope[it].toDouble()} ?: 0.0)}
            rows+=candidate(start,end,track).put("waveform",wave)
                .put("score",speechSeconds/seconds+(if(seconds in 5.0..8.0)0.15 else 0.0))
        }
        onset=-1.0;envelope.clear()
    }
}
