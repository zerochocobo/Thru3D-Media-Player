package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.atomic.AtomicReference

/** Only the native clock boundary is replaced. Controller.tick/publish/retention
 * are compiled from production. Completed ASR results enter its actual cue map;
 * no Android model, audio, or user data is accessed. */
internal object MpvSourceNative {
    var position=5.0
    var track=0
    fun narrationStatus(handle: Long): String = JSONObject().put("seeks_started",0).put("seeks_completed",0)
        .put("details",JSONObject().put("position_seconds",position.toString()).put("duration_seconds","120")
            .put("observed_monotonic_ns",System.nanoTime()).put("paused","yes").put("paused_for_cache","no")
            .put("audio_track_id",(track+1).toString()).put("playback_speed","1").put("demuxer_start_time","0")
            .put("audio_tracks",JSONArray().put(JSONObject().put("id",track+1).put("stream_index",track)))).toString()
    fun setListeningCache(handle: Long,seconds: Double): Boolean=error("Unexpected shared-reader change")
}

private fun field(owner: Any,name: String)=owner.javaClass.getDeclaredField(name).apply {isAccessible=true}
private fun tick(owner: Any){owner.javaClass.getDeclaredMethod("tick").apply {isAccessible=true}.invoke(owner)}

fun main(args: Array<String>){
    val output=File(args.single());output.mkdirs()
    var checks=0;val failures=mutableListOf<String>()
    fun verify(ok: Boolean,label: String){checks++;if(!ok)failures.add(label)}
    for(mode in listOf("ephemeral","memory","persistent")){
        val current=AtomicReference<ListeningController.Source?>(null)
        val controller=ListeningController({null},{current.get()},{})
        val clock=field(controller,"clock").get(controller) as ExecutorService
        clock.shutdownNow();clock.awaitTermination(2,java.util.concurrent.TimeUnit.SECONDS)
        // Stop the next native work step while the completed previous step is
        // being published, exactly the window between worker updates and ticks.
        field(controller,"busy").setBoolean(controller,true)
        val media=if(mode=="ephemeral")"" else "a".repeat(64)
        val persistent=mode=="persistent"
        verify(controller.configure(JSONObject().put("enabled",true).put("language","en").put("lead",12)
            .put("media",media).put("persist",persistent).put("network",true).toString()),"$mode configure")
        current.set(ListeningController.Source(1,"http://192.0.2.1/owned.mp4","",true,false,-1,0.0))
        MpvSourceNative.position=5.0;MpvSourceNative.track=0;tick(controller)
        val cacheDirectory=if(persistent)File(output,"cache/${System.nanoTime()}") else null
        val cache=if(media.isEmpty())null else ListeningCueCache.obtain(cacheDirectory,
            ListeningCueCache.key(media,120.0,"en","model",0,-1),true)
        if(cache!=null){
            field(controller,"cueCache").set(controller,cache)
            for((key,value) in mapOf("cacheMedia" to media,"cacheLanguage" to "en","cacheTrack" to 0,"cachePlaylist" to -1))field(controller,key).set(controller,value)
        }
        @Suppress("UNCHECKED_CAST") val cues=field(controller,"cues").get(controller) as MutableMap<String,ListeningPolicy.Cue>
        val first=ListeningPolicy.Cue(5.0,9.0,"Live speech becomes visible subtitles")
        cues[first.key]=first;cache?.add(first);cache?.cover(0.0,30.0)
        field(controller,"through").setDouble(controller,30.0)
        repeat(3){
            tick(controller);val report=JSONObject(controller.status())
            verify(report.getJSONArray("cues").length()==1,"$mode finalized cue survives clock tick $it")
            verify(report.optDouble("ahead",report.getDouble("through")-report.getDouble("position"))>=12,"$mode ready ahead $it")
            if(mode=="ephemeral"&&it==2)File(output,"ephemeral-report.json").writeText(report.toString(2))
        }
        verify(JSONObject(controller.status()).getBoolean("cache_persistent")==persistent,"$mode cache policy unchanged")
        MpvSourceNative.position=15.0;tick(controller)
        verify(JSONObject(controller.status()).getJSONArray("cues").length()==0,"$mode expired cue removed")
        val next=ListeningPolicy.Cue(15.0,19.0,"The next sentence is visible too")
        cues[next.key]=next;cache?.add(next);tick(controller)
        verify(JSONObject(controller.status()).getJSONArray("cues").length()==1,"$mode next finalized cue delivered")
        MpvSourceNative.track=1;tick(controller)
        verify(JSONObject(controller.status()).getJSONArray("cues").length()==0,"$mode changing audio track rejects previous recognized text")
        controller.transportChanged()
        verify(JSONObject(controller.status()).getJSONArray("cues").length()==0,"$mode transport invalidates old visible cues")
        controller.close()
        (field(controller,"worker").get(controller) as ExecutorService).awaitTermination(2,java.util.concurrent.TimeUnit.SECONDS)
    }
    File(output,"controller-verification.json").writeText(JSONObject().put("checks",checks).put("failures",JSONArray(failures))
        .put("scope","Production controller; synthetic completed-ASR and native-clock boundaries, no model or headset").toString(2))
    println("Listening controller: $checks checks, ${failures.size} failures")
    failures.forEach {System.err.println(it)}
    check(failures.isEmpty())
}
