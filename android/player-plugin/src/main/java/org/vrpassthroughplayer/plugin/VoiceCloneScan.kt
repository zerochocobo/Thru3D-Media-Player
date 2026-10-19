package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject

/** Fill a useful page across time windows; later pages retain earlier candidates. */
internal object VoiceCloneScan {
    data class Result(val rows: JSONArray,val next: Double,val eof: Boolean)
    fun read(start: Double,line: Int,previous: JSONArray=JSONArray(),
             active: ()->Unit={},progress: (JSONArray,Double)->Unit={_,_->},
             now: ()->Long=System::nanoTime,read: (Double,Double)->JSONObject): Result {
        require(start.isFinite()&&start>=0)
        val found=linkedMapOf<String,JSONObject>()
        for(i in 0 until previous.length())previous.getJSONObject(i).let {found[it.getString("key")]=it}
        val initial=found.size
        var cursor=start
        var eof=false
        val deadline=now()+30_000_000_000L
        var windows=0
        do {
            active()
            val batch=read(cursor,cursor+45)
            val candidates=VoiceClonePolicy.candidates(batch.getJSONArray("cues"),line)
            for(i in 0 until candidates.length())candidates.getJSONObject(i).let {found[it.getString("key")]=it}
            cursor+=45;windows++
            eof=batch.optBoolean("eof")||(batch.optDouble("duration")>0&&cursor>=batch.optDouble("duration"))
            progress(JSONArray(found.values.toList()),cursor)
        }while(!eof&&found.size-initial<32&&windows<1920&&now()<deadline)
        active()
        return Result(JSONArray(found.values.toList()),cursor,eof)
    }
}
