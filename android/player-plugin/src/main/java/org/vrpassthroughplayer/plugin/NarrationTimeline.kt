package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject

/** Per-source text/time index. Playback generations, language and line selection do not own it.
 * Text remains in memory, is bounded, and is released when the source closes. */
internal class NarrationTimeline(private val byteLimit: Int = 8 * 1024 * 1024) {
    data class Entry(val start: Double, val end: Double, val text: String)
    data class Batch(val cues: JSONArray, val eof: Boolean, val duration: Double) {
        companion object {
            fun parse(value: String): Batch {
                val j=JSONObject(value)
                return Batch(j.getJSONArray("cues"),j.getBoolean("eof"),j.optDouble("duration",0.0))
            }
        }
    }
    private val entries=linkedSetOf<Entry>()
    private var ranges=emptyList<Pair<Double,Double>>()
    private var bytes=0
    var duration=0.0; private set
    var limited=false; private set
    val size get()=entries.size
    val indexedSeconds get()=ranges.sumOf {it.second-it.first}
    val complete get()=duration>0 && covers(0.0,duration)
    val fraction get()=if(duration>0)(indexedSeconds/duration).coerceIn(0.0,1.0) else -1.0

    fun covers(start: Double, end: Double): Boolean {
        val finish=if(duration>0)minOf(end,duration) else end
        return finish<=start && duration>0 || ranges.any {it.first<=start+.001 && it.second>=finish-.001}
    }
    fun accept(start: Double, end: Double, batch: Batch): Boolean {
        if(batch.duration.isFinite() && batch.duration>0)duration=batch.duration
        if(batch.eof && duration<=0)duration=end
        if(!remember(batch.cues))return false
        val finish=if(duration>0)minOf(end,duration) else end
        if(finish>start) {
            val merged=mutableListOf<Pair<Double,Double>>()
            for(range in (ranges+listOf(start to finish)).sortedBy {it.first}) {
                val previous=merged.lastOrNull()
                if(previous!=null && range.first<=previous.second+.001)merged[merged.lastIndex]=previous.first to maxOf(previous.second,range.second)
                else merged+=range
            }
            ranges=merged
        }
        return true
    }
    // A displayed cue is useful text, but does not prove the surrounding range
    // was fully extracted (there may be overlapping/bilingual events).
    fun remember(cues: JSONArray): Boolean {
        val added=(0 until cues.length()).map {i -> cues.getJSONObject(i).let {
            Entry(it.getDouble("start"),it.getDouble("end"),it.getString("text"))
        }}.filter {it.start.isFinite()&&it.end.isFinite()&&it.start>=0&&it.end>it.start}.toSet()-entries
        val cost=added.sumOf {it.text.length*2+64}
        if(bytes+cost>byteLimit || entries.size+added.size>20000) {limited=true;return false}
        entries.addAll(added);bytes+=cost
        return true
    }
    fun window(start: Double, end: Double)=JSONArray().also {result ->
        entries.filter {it.end>=start-1 && it.start<end}.sortedBy {it.start}.forEach {
            result.put(JSONObject().put("start",it.start).put("end",it.end).put("text",it.text))
        }
    }
    fun nextWindow(): Pair<Double,Double>? {
        if(complete||limited)return null
        val start=ranges.firstOrNull()?.takeIf {it.first<=.001}?.second ?: 0.0
        val boundary=ranges.firstOrNull {it.first>start+.001}?.first ?: Double.POSITIVE_INFINITY
        return start to minOf(start+45,boundary,if(duration>0)duration else Double.POSITIVE_INFINITY)
    }
    companion object {
        /** The MPV queue is a partial set, never proof that a whole time range
         * has been read. Reject old seek/track snapshots before caching text. */
        fun shared(snapshot: JSONObject, selected: Int, floor: Long, command: Long, now: Long): JSONArray? {
            val age=(now-snapshot.optLong("observed_monotonic_ns"))/1e9
            if(!snapshot.optBoolean("supported") || selected<=0 || snapshot.optString("track_id").toIntOrNull()!=selected ||
                snapshot.optLong("source_epoch")<floor || snapshot.optLong("command_id")<command || age !in 0.0..1.0)return null
            val raw=snapshot.optJSONArray("cues") ?: return null
            val result=JSONArray()
            for(i in 0 until minOf(raw.length(),256)) {
                val cue=raw.optJSONObject(i) ?: continue
                val start=cue.optDouble("start");val end=cue.optDouble("end");val text=cue.optString("text")
                if(start.isFinite()&&end.isFinite()&&start>=0&&end>start&&text.isNotBlank()&&text.length<=8192)
                    result.put(JSONObject().put("start",start).put("end",end).put("text",text))
            }
            return result
        }
        fun visible(snapshot: JSONObject, position: Double, delay: Double, selected: Int): JSONArray {
            val start=snapshot.optString("start_seconds").toDoubleOrNull() ?: return JSONArray()
            val end=snapshot.optString("end_seconds").toDoubleOrNull() ?: return JSONArray()
            val text=snapshot.optString("text").take(8192)
            if(!snapshot.optBoolean("timeline_valid") || selected<=0 || snapshot.optString("track_id").toIntOrNull()!=selected ||
                !position.isFinite() || !delay.isFinite() || !start.isFinite() || !end.isFinite() || start<0 || end<=start ||
                position-delay<start-.05 || position-delay>=end || text.isBlank())return JSONArray()
            return JSONArray().put(JSONObject().put("start",start).put("end",end).put("text",text))
        }
        // Never put arbitrary exception messages (which could contain URLs/text) in diagnostics.
        fun errorCode(error: Throwable): String = error.message?.takeIf {
            it.matches(Regex("subtitle_(?:open_timeout|open|stream|text_required|decoder|seek_timeout|seek|read_timeout|read|window_limit|packet_limit|internal):-?[0-9]{1,12}"))
        } ?: "subtitle_internal:0"
        fun retryable(code: String)=code.startsWith("subtitle_open")||code.startsWith("subtitle_seek")||code.startsWith("subtitle_read")
    }
}
