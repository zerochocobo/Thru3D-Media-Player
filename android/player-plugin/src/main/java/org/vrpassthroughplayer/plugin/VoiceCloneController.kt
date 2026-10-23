package org.vrpassthroughplayer.plugin

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.max

/** All file/model work is serial and off the VR thread. Every result belongs to one source and request generation. */
internal class VoiceCloneController(private val context: ()->Context?,private val source: ()->Source?,
    private val onHold: (Boolean)->Unit,private val audioChanged: ()->Unit,private val drain: ()->Unit={},
    private val runtime: SharedNarrationEngine,private val previewCache: ()->NarrationPreviewCache,
    private val openSample: ((String)->Source)?=null) : AutoCloseable {
    data class Source(val handle: Long,val path: String,val ca: String,val subtitleDelay: Double,val audioDelay: Double,val allowed: Boolean,val volume: Double,val muted: Boolean,val disc: Boolean=false,val discPlaylist: Int=-1,val narrationVolume: Double=1.0,
                      val reference: (() -> VoiceClonePolicy.Reference)?=null,val release: ()->Unit={})
    // All sessions and the global manager share a queue, including engine teardown.
    // A new source must not load TTS while the previous source is still closing it.
    companion object {
        private val worker=Executors.newSingleThreadExecutor {Thread(it,"VoiceCloneTasks")}
        private data class Catalog(val json: String,val revision: Long)
        @Volatile private var catalog: Catalog?=null
    }
    private val generation=AtomicLong()
    private val stateLock=Any()
    private val holdLock=Any()
    private val holding=AtomicBoolean()
    private fun hold(value: Boolean)=synchronized(holdLock){if(holding.getAndSet(value)!=value)onHold(value)}
    @Volatile private var closed=false
    @Volatile private var opened=false
    @Volatile private var managing=false
    @Volatile private var interrupted=false
    @Volatile private var audio: AudioTrack?=null
    @Volatile private var nativeJob=0L
    @Volatile private var reader=0L
    @Volatile private var encoder: VoiceEncoderClient?=null
    @Volatile private var report="{}"
    @Volatile var wantsAudio=false;private set
    val holdsPlayback get()=opened||managing
    private var state=JSONObject().put("state","idle").put("revision",0)
    private var params=JSONObject()
    @Volatile private var rows=JSONArray()
    private var next=0.0
    private var taskDir: File?=null
    private var referenceKey=""
    private var candidateId=""
    private val previewSession=NarrationPreviewSession(runtime,previewCache,drain)
    private var modelRevision=""
    private var requestStarted=0L
    private var previewReady=false
    private var sampleSource: Source?=null
    private var sampleDetails: JSONObject?=null
    private fun currentSource()=sampleSource ?: source()
    private fun clearSample(){sampleSource?.release?.invoke();sampleSource=null;sampleDetails=null}
    private fun app()=context() ?: error("voice_unavailable")
    private fun active(token: Long)=!closed&&generation.get()==token&&source()?.allowed==true
    private fun checkActive(token: Long){check(active(token)){"voice_cancelled"}}
    private fun publish(block: (JSONObject)->Unit={})=synchronized(stateLock){
        block(state);state.put("revision",state.optLong("revision")+1).put("opened",opened);report=state.toString()
    }
    private fun phase(value: String){publish {it.put("state",value).put("error","").put("error_code","").put("error_detail","")}}
    private fun publishCurrent(token: Long,block: (JSONObject)->Unit)=synchronized(stateLock){if(!closed&&generation.get()==token)publish(block)}
    fun status(): JSONObject {
        val result=JSONObject(report);val current=catalog ?: return result
        // Session and global controllers must never return contradictory copies
        // after saving/deleting a voice. The immutable catalog is updated on the
        // shared worker; status reads do no disk work.
        return result.put("shared_model",runtime.stats()).put("voices",JSONArray(current.json)).put("voices_revision",current.revision)
            .put("voices_ready",result.optBoolean("voices_ready",true))
    }
    private fun cancel() {
        generation.incrementAndGet();encoder?.close();encoder=null
        val job=nativeJob;if(job>0)runCatching {VoiceCloneNative.cancelJob(job)}
        val reading=reader;if(reading>0)runCatching {NarrationNative.closeReader(reading)}
        previewSession.cancel()
        wantsAudio=false;audio?.let {runCatching {it.pause();it.flush()}};audioChanged()
    }
    private fun clearEngine(){previewSession.close()}
    private fun clearCandidate(){taskDir?.let {if(it.isDirectory)it.deleteRecursively()};taskDir=null;referenceKey="";candidateId="";previewReady=false;publish {
        it.put("ready_key","");for(key in listOf("reference_input_db","reference_output_db","reference_gain_db","reference_center","reference_crest_db","reference_target_db"))it.remove(key)
    }}
    fun request(raw: String): Boolean {
        if(closed||raw.length>8192)return false
        val j=runCatching {JSONObject(raw)}.getOrNull() ?: return false
        val op=synchronized(stateLock){VoiceClonePolicy.operation(j,state)}
        if(op !in setOf("list","open","open_source","mode","scan","manual","trim","candidates","original","clone","save","rename","delete","preview","stop","close"))return false
        interrupted=false;requestStarted=System.nanoTime()
        cancel();val token=generation.get()
        if(op=="trim")publish {it.put("ready_key","")}
        if(op in setOf("open","open_source","mode","scan","manual")||(op=="candidates"&&(j.has("start")||j.optBoolean("all")))){
            publish {rows=JSONArray();it.put("candidates",rows).put("ready_key","")}
        }
        if(op in setOf("open","open_source"))opened=true
        if(op=="list"&&j.optBoolean("pause"))managing=true
        if(op=="close"){opened=false;managing=false}
        if(op in setOf("open","open_source"))publish {it.put("source_ready",false).put("candidates",JSONArray()).put("ready_key","")}
        publish {it.put("notice","")}
        publish {it.put("operation",op).put("active_key",j.optString("key")).put("preview_id",j.optString("id")).put("state",if(op=="open")"pausing" else if(op in setOf("save","rename","delete"))"saving" else "preparing").put("error","").put("error_code","").put("error_detail","").put("played_frames",0)}
        if(op=="list")publish {it.put("voices_ready",false)}
        publish {it.put("cache_hit",false).put("first_audio_ms",-1).put("cache_write_failed",false).put("preview_underruns",0)
            .put("rhythm_pause_removed_ms",0).put("rhythm_drag_removed_ms",0).put("rhythm_local_tempo",1.0).put("rhythm_buffer_samples",0)
            .put("level_initial_gain_db",0).put("level_gain_db",0).put("level_limited_frames",0).put("level_buffer_samples",0)}
        if(opened||managing||op=="preview")hold(true)
        worker.execute {
            try {
                // Closing owns cleanup even if an immediate list/open supersedes its
                // UI result. Otherwise returning to the manager could retain a lease.
                if(op=="close"){
                    clearEngine();clearCandidate();clearSample();params=JSONObject()
                    publish {rows=JSONArray();it.put("candidates",rows).put("source_ready",false).put("audio_options",JSONArray())}
                    publishCurrent(token){it.put("state","idle")};return@execute
                }
                checkActive(token)
                when(op) {
                    "list"->{refreshVoices();phase("ready")}
                    "open"->{clearCandidate();clearSample();params=j;awaitPause(token)
                        if(j.optString("mode","subtitles")=="subtitles")readCandidates(token,j.optDouble("position",0.0).minus(20).coerceAtLeast(0.0),true)
                        else prepareAudio(token)}
                    "open_source"->{clearCandidate();clearSample();rows=JSONArray();params=j
                        publish {it.put("source_ready",false).put("candidates",rows).put("ready_key","")};phase("probing")
                        val input=(openSample ?: error("voice_input_unavailable"))(j.getString("uri"));sampleSource=input
                        checkActive(token)
                        val job=VoiceCloneNative.createJob();nativeJob=job
                        try {sampleDetails=JSONObject(VoiceCloneNative.probe(job,input.path,input.ca,input.disc,input.discPlaylist))}
                        finally {VoiceCloneNative.cancelJob(job);if(nativeJob==job)nativeJob=0}
                        prepareAudio(token)}
                    "mode"->{clearCandidate();params.put("mode",j.getString("mode"));rows=JSONArray()
                        if(j.getString("mode")=="subtitles")readCandidates(token,0.0,true) else prepareAudio(token)}
                    "scan"->{awaitPause(token);clearCandidate();scanAudio(token,j)}
                    "manual"->{awaitPause(token);clearCandidate();manualCandidate(token,j)}
                    "trim"->{
                        val updated=VoiceSpeechCandidates.trim(rows,j.getString("key"),j.getDouble("start"),j.getDouble("end"))
                        checkActive(token);clearCandidate()
                        publishCurrent(token){rows=updated;it.put("candidates",rows).put("ready_key","").put("state","ready")}
                    }
                    "candidates"->{awaitPause(token);clearCandidate();params.put("audio_id",j.optInt("audio_id",params.optInt("audio_id",0)));readCandidates(token,if(j.optBoolean("all"))0.0 else if(j.has("start"))j.getDouble("start") else next,j.optBoolean("all")||j.has("start"))}
                    "original","clone"->{awaitPause(token);renderCandidate(token,j.getString("key"),op=="clone")}
                    "save"->{require(previewReady&&candidateId.isNotEmpty()&&j.getString("key")==referenceKey&&
                        (0 until rows.length()).any {rows.getJSONObject(it).getString("key")==referenceKey});checkActive(token)
                        val dir=taskDir ?: error("voice_unavailable");val saved=NarrationAssets.voices(app()).save(j.getString("name"),File(dir,"prepared.wav"),File(dir,"codes.bin"))
                        checkActive(token);refreshVoices();publish {it.put("saved",saved).put("save_request",j.optInt("request")).put("state","saved")}}
                    "rename"->{NarrationAssets.voices(app()).rename(j.getString("id"),j.getString("name"));refreshVoices();phase("ready")}
                    "delete"->{previewCache().deleteVoice(j.getString("id"));NarrationAssets.voices(app()).delete(j.getString("id"));refreshVoices();publish {it.put("deleted",j.getString("id")).put("state","ready")}}
                    "preview"->{val id=j.getString("id");require(PersonalVoiceStore.isVoice(id)||id in NarrationPolicy.voices.values.flatten());val lang=j.optString("language","zh");
                        if((source()?.handle ?: 0)>0)awaitPause(token,false)
                        val text=if(PersonalVoiceStore.isVoice(id))VoiceClonePreviewText.text(lang) else NarrationPolicy.previewText(lang)
                        streamPreview(token,id,lang,text,if(PersonalVoiceStore.isVoice(id))NarrationAssets.voices(app()).load(id) else IntArray(0),true)}
                    "stop"->phase("ready")
                }
            } catch(error: Throwable) {
                if(op=="open_source"){clearSample();publishCurrent(token){it.put("source_ready",false)}}
                if(active(token)){
                    val stage=synchronized(stateLock){state.optString("state")}
                    val code=VoiceClonePolicy.failureCode(op,stage,error)
                    val reason=VoiceClonePolicy.diagnostic(error)
                    // Fixed operation/stage/code only: no URLs, subtitle text or file paths.
                    Log.w("Thru3DVoiceClone","operation=$op stage=$stage code=$code detail=$reason exception=${error.javaClass.simpleName}")
                    publish {it.put("state","error").put("error_code",code).put("error_detail",reason).put("error",VoiceClonePolicy.failureMessage(code))}
                }
            } finally {
                audio?.let {runCatching {it.release()}};audio=null;wantsAudio=false
                if(generation.get()==token){audioChanged();if(!opened&&!managing)hold(false)}
            }
        }
        return true
    }
    private fun refreshVoices(){
        val voices=NarrationAssets.voices(app()).list();val json=voices.toString();val previous=catalog
        if(previous?.json!=json)catalog=Catalog(json,(previous?.revision ?: 0)+1)
        publish {it.put("voices_ready",true)}
    }
    private fun observation()=sampleDetails ?: JSONObject(MpvSourceNative.narrationStatus(source()?.handle ?: error("voice_unavailable"))).getJSONObject("details")
    private fun duration(details: JSONObject)=details.optDouble("duration",details.optDouble("duration_seconds",0.0)).let {if(it.isFinite()&&it>0)it else 0.0}
    private fun awaitPause(token: Long,requireOpened: Boolean=true) {
        check(!requireOpened||opened);val deadline=System.nanoTime()+3_000_000_000L
        if(sampleSource!=null){checkActive(token);return}
        while(true){checkActive(token);if(observation().optString("paused")=="yes")return;check(System.nanoTime()<deadline){"voice_pause_timeout"};Thread.sleep(25)}
    }
    private fun selectedTrack(type: String,id: Int,details: JSONObject): JSONObject {
        val missing=if(type=="audio")"voice_audio_required" else "voice_subtitles_required"
        val tracks=details.optJSONArray(type+"_tracks") ?: error(missing)
        return (0 until tracks.length()).map {tracks.getJSONObject(it)}.firstOrNull {it.optInt("id")==id} ?: error(missing)
    }
    private fun prepareAudio(token: Long) {
        checkActive(token);val details=observation();val track=VoiceClonePolicy.audioTrack(params.optInt("audio_id",0),details)
        params.put("audio_id",track.getInt("id"));params.put("mode",if(params.optString("mode")=="manual")"manual" else "speech")
        refreshVoices()
        publishCurrent(token){rows=JSONArray();it.put("source_ready",true).put("mode",params.getString("mode")).put("candidates",rows)
            .put("audio_options",details.optJSONArray("audio_tracks") ?: JSONArray()).put("audio_id",track.getInt("id"))
            .put("duration",duration(details)).put("state","ready").put("eof",false).put("ready_key","")}
    }
    private fun manualCandidate(token: Long,command: JSONObject) {
        checkActive(token);val track=VoiceClonePolicy.audioTrack(command.optInt("audio_id",params.optInt("audio_id",0)),observation())
        val start=command.getDouble("start");val end=command.getDouble("end")
        VoiceSpeechCandidates.range(start,end,10.0,duration(observation()))
        val row=VoiceSpeechCandidates.candidate(start,end,track.getInt("id"),true)
        params.put("audio_id",track.getInt("id"));params.put("language",command.optString("language",params.optString("language","zh")))
        publishCurrent(token){rows=JSONArray().put(row);it.remove("scan_start");it.remove("scan_end")
            it.put("candidates",rows).put("audio_id",track.getInt("id")).put("mode","manual").put("state","ready").put("ready_key","")}
    }
    private fun scanAudio(token: Long,command: JSONObject) {
        val details=observation();val track=VoiceClonePolicy.audioTrack(command.optInt("audio_id",params.optInt("audio_id",0)),details)
        val start=command.getDouble("start");val end=command.getDouble("end")
        VoiceSpeechCandidates.range(start,end,600.0,duration(details))
        params.put("audio_id",track.getInt("id"));params.put("language",command.optString("language",params.optString("language","zh")))
        publishCurrent(token){rows=JSONArray();it.put("candidates",rows).put("mode","speech").put("audio_id",track.getInt("id"))
            .put("scan_start",start).put("scan_end",end).put("next",start).put("eof",false)}
        phase("model_verifying");val model=NarrationAssets.prepareVad(app()){active(token)};checkActive(token)
        val s=currentSource() ?: error("voice_input_unavailable");val input=VoiceClonePolicy.input(s.path,track,s.disc)
        val segments=VoiceSpeechCandidates(start,end,track.getInt("id"));phase("scanning")
        (if(!track.optBoolean("external"))s.reference?.invoke() else null).use {reference->
            checkActive(token);val job=VoiceCloneNative.createJob();nativeJob=job
            try {VoiceCloneNative.scan(job,reference?.path ?: input.path,input.stream,s.ca,start,end,input.disc,s.discPlaylist,model.path,
                object:VoiceCloneNative.ScanListener {
                    override fun frames(start: Double,probability: FloatArray,rms: FloatArray,peak: FloatArray,finished: Boolean): Boolean {
                        checkActive(token);val found=segments.accept(start,probability,rms,peak,finished)
                        publishCurrent(token){rows=found;it.put("candidates",rows).put("next",segments.through).put("eof",finished)}
                        return true
                    }
                })
            }finally {VoiceCloneNative.cancelJob(job);if(nativeJob==job)nativeJob=0}
        }
        checkActive(token)
        val ranked=JSONArray((0 until rows.length()).map {rows.getJSONObject(it)}.sortedByDescending {it.optDouble("score",0.0)})
        publishCurrent(token){rows=ranked;it.put("candidates",rows)};phase("ready")
        if(rows.length()==0)publishCurrent(token){it.put("notice","No suitable clips found. Try another range.")}
    }
    private fun readCandidates(token: Long,start: Double,replace: Boolean) {
        check(start.isFinite()&&start>=0);phase("reading")
        val s=source() ?: error("voice_unavailable");val details=observation();val sub=selectedTrack("subtitle",params.getInt("subtitle_id"),details)
        require(sub.optString("codec") in setOf("subrip","ass","ssa","webvtt","mov_text","text","sami","microdvd","subviewer","ttml"))
        val input=VoiceClonePolicy.input(s.path,sub,s.disc)
        val audioOptions=details.optJSONArray("audio_tracks") ?: JSONArray()
        val selectedAudio=VoiceClonePolicy.audioTrack(params.optInt("audio_id",0),details)
        params.put("audio_id",selectedAudio.getInt("id"))
        publishCurrent(token){rows=if(replace)JSONArray() else rows
            it.put("mode","subtitles").put("source_ready",true).put("duration",duration(details)).put("candidates",rows).put("audio_options",audioOptions).put("audio_id",params.getInt("audio_id")).put("eof",false)}
        val handle=NarrationNative.openReaderConfigured(input.path,input.stream,s.ca,input.disc,s.discPlaylist);reader=handle
        val result: VoiceCloneScan.Result
        try {result=VoiceCloneScan.read(start,params.optInt("line",0),rows,
            active={checkActive(token)},progress={found,cursor->
                checkActive(token)
                publishCurrent(token){rows=found;next=cursor;it.put("candidates",rows).put("next",next)}
            },read={from,to->JSONObject(NarrationNative.readBatch(handle,from,to))})}
        finally {NarrationNative.closeReader(handle);if(reader==handle)reader=0}
        checkActive(token)
        refreshVoices();publishCurrent(token){rows=result.rows;next=result.next;it.put("candidates",rows).put("next",next).put("eof",result.eof).put("ready_key","").put("state","ready")}
        if(rows.length()==0){val code=if(result.eof)"no_candidates" else "no_candidates_in_range"
            publish {it.put("state","error").put("error_code",code).put("error",VoiceClonePolicy.failureMessage(code))}}
    }
    private fun renderCandidate(token: Long,key: String,clone: Boolean) {
        val cue=(0 until rows.length()).map {rows.getJSONObject(it)}.firstOrNull {it.getString("key")==key} ?: error("voice_candidate_missing")
        publish {it.put("active_key",key).put("ready_key",if(referenceKey==key&&previewReady)key else "")}
        if(referenceKey!=key){clearCandidate();val s=currentSource() ?: error("voice_unavailable");val details=observation();val track=selectedTrack("audio",params.getInt("audio_id"),details)
            val subtitleDelay=params.optDouble("subtitle_delay",s.subtitleDelay)
            val audioDelay=params.optJSONObject("audio_delays")?.optDouble(track.getInt("id").toString(),s.audioDelay) ?: s.audioDelay
            // Audio candidates already use source timestamps; subtitle/audio sync offsets only apply to captions.
            val shift=if(cue.optString("timing")=="audio")0.0 else subtitleDelay-audioDelay
            val start=cue.getDouble("start")+shift;val end=cue.getDouble("end")+shift;require(start>=0)
            val dir=File(app().cacheDir,"voice-clone/"+UUID.randomUUID());check(dir.mkdirs());taskDir=dir
            val input=VoiceClonePolicy.input(s.path,track,s.disc)
            phase("extracting")
            // A cloud playback lease owns its transport/cache lifecycle. Use the
            // existing independent download lease for a new reference sample.
            (if(!track.optBoolean("external"))s.reference?.invoke() else null).use {reference->
                checkActive(token)
                val handle=VoiceCloneNative.createJob();nativeJob=handle
                try {VoiceCloneNative.extract(handle,reference?.path ?: input.path,input.stream,s.ca,start,end,File(dir,"reference.wav").path,input.disc,s.discPlaylist)}
                finally {VoiceCloneNative.cancelJob(handle);if(nativeJob==handle)nativeJob=0}
            }
            checkActive(token);referenceKey=key
        }
        val dir=taskDir ?: error("voice_unavailable")
        // Audition, encoding and saved references use exactly the same prepared WAV.
        // Preparing it is independent of the model, so listening never loads TTS.
        val reference=File(dir,"prepared.wav")
        if(!reference.isFile){
            phase("preparing")
            val dialogue=File(dir,"reference.wav.dialogue.wav")
            val prepared=VoiceReferencePcm.prepare(VoiceClonePolicy.readWav(if(dialogue.isFile)dialogue else File(dir,"reference.wav")))
            checkActive(token);VoiceReferencePcm.write(reference,prepared.pcm)
            if(cue.optString("timing")=="audio"){
                val wave=JSONArray();val stride=prepared.pcm.size/32
                repeat(32){i->var power=0.0;for(k in i*stride until (i+1)*stride)power+=prepared.pcm[k]*prepared.pcm[k];wave.put(kotlin.math.sqrt(power/stride))}
                cue.put("waveform",wave)
            }
            publishCurrent(token){it.put("reference_input_db",prepared.inputDb).put("reference_output_db",prepared.outputDb)
                .put("reference_gain_db",prepared.gainDb).put("reference_center",dialogue.isFile)
                .put("reference_crest_db",prepared.crestDb).put("reference_target_db",prepared.targetDb)}
        }
        if(!clone){phase("playing_original");play(token,VoiceClonePolicy.readWav(reference),true);return}
        if(candidateId.isEmpty()){
            phase("encoding");drain()
            runtime.encoding({active(token)}) {
                val model=NarrationAssets.prepare(app(),true){active(token)};checkActive(token)
                VoiceEncoderClient(app()).use {client->encoder=client;client.encode(File(model,"moss_audio_tokenizer_encode.onnx"),File(dir,"prepared.wav"),File(dir,"codes.bin")){active(token)}};encoder=null
            }
            checkActive(token);candidateId="custom:"+UUID.randomUUID()
        }
        val language=params.optString("language","zh");val text=if(cue.optString("timing")=="audio")VoiceClonePreviewText.text(language) else NarrationPolicy.speechText(cue.getString("text"),language)
        streamPreview(token,candidateId,language,text,PersonalVoiceStore.codes(File(dir,"codes.bin")),false)
        checkActive(token);previewReady=true;publish {it.put("ready_key",key)}
    }
    private fun streamPreview(token: Long,id: String,language: String,text: String,codes: IntArray,saved: Boolean) {
        checkActive(token)
        if(modelRevision.isEmpty())modelRevision=app().assets.open("narration/model.json").use {input->
            java.security.MessageDigest.getInstance("SHA-256").digest(input.readBytes()).joinToString(""){"%02x".format(it)}}
        previewSession.play(id,language,text,codes,saved,modelRevision,{active(token)},{streamOutput(token)},
            phase={value->checkActive(token);publishCurrent(token){it.put("state",value).put("error","").put("error_code","").put("error_detail","")}},
            cacheInfo={hit,samples->publishCurrent(token){it.put("cache_hit",hit).put("preview_frames",samples/2)}},
            cacheFailure={publishCurrent(token){it.put("cache_write_failed",true)}},
            rhythmInfo={stats->publishCurrent(token){it.put("preview_raw_frames",stats.inputSamples/2).put("preview_frames",stats.outputSamples/2)
                .put("rhythm_pause_removed_ms",stats.removedPauseSamples/96.0).put("rhythm_drag_removed_ms",stats.removedDragSamples/96.0)
                .put("rhythm_local_tempo",stats.localTempo).put("rhythm_buffer_samples",stats.maxBufferedSamples)}},
            levelInfo={stats->publishCurrent(token){it.put("level_initial_gain_db",stats.initialGainDb).put("level_gain_db",stats.gainDb)
                .put("level_limited_frames",stats.limitedFrames).put("level_buffer_samples",stats.maxBufferedSamples)}})
    }
    private fun streamOutput(token: Long)=object:VoicePreviewStream.Output {
        private var track: AudioTrack?=null
        private val released=AtomicBoolean()
        private val outputLock=Any()
        private var firstWrite=true
        private val startedAt=requestStarted
        override fun start() {
            checkActive(token);val s=source() ?: error("voice_unavailable")
            val gain=VoiceClonePolicy.playbackGain(s.volume,s.narrationVolume,false);check(!s.muted&&gain>0){"voice_preview_muted"}
            wantsAudio=true;audioChanged();Thread.sleep(80);checkActive(token)
            val value=AudioTrack.Builder().setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
                .setAudioFormat(AudioFormat.Builder().setEncoding(AudioFormat.ENCODING_PCM_FLOAT).setSampleRate(48000).setChannelMask(AudioFormat.CHANNEL_OUT_STEREO).build())
                .setBufferSizeInBytes(max(76800,AudioTrack.getMinBufferSize(48000,AudioFormat.CHANNEL_OUT_STEREO,AudioFormat.ENCODING_PCM_FLOAT))).setTransferMode(AudioTrack.MODE_STREAM).build()
            synchronized(outputLock){
                if(released.get()){value.release();error("voice_cancelled")}
                track=value;audio=value;value.setVolume(gain)
            }
            checkActive(token);publishCurrent(token){it.put("output_gain",gain)}
        }
        override fun write(pcm: FloatArray) {
            val value=track ?: error("voice_playback_failed");var at=0
            while(at<pcm.size){checkActive(token);val n=value.write(pcm,at,minOf(4096,pcm.size-at),AudioTrack.WRITE_BLOCKING);check(n>0);at+=n
                if(firstWrite){checkActive(token);firstWrite=false;value.play();publishCurrent(token){it.put("state","playing_clone").put("first_audio_ms",(System.nanoTime()-startedAt)/1e6)}}}
        }
        override fun finish(samples: Int) {
            val value=track ?: error("voice_playback_failed");val deadline=System.nanoTime()+30_000_000_000L
            while((value.playbackHeadPosition.toLong() and 0xffffffffL)<samples/2){checkActive(token);check(System.nanoTime()<deadline){"voice_playback_timeout"};Thread.sleep(20)}
            publishCurrent(token){it.put("played_frames",samples/2).put("preview_underruns",value.underrunCount)}
        }
        override fun close() {
            synchronized(outputLock){
                if(released.getAndSet(true))return
                track?.let {value->runCatching {value.pause();value.flush();value.release()};if(audio===value)audio=null}
            }
            if(generation.get()==token){wantsAudio=false;audioChanged()}
        }
    }
    private fun play(token: Long,data: FloatArray,original: Boolean=false) {
        checkActive(token);val s=source() ?: error("voice_unavailable");val outputGain=VoiceClonePolicy.playbackGain(s.volume,s.narrationVolume,original)
        check(!s.muted&&outputGain>0){"voice_preview_muted"}
        publish {it.put("preview_frames",data.size/2).put("played_frames",0).put("output_gain",outputGain)}
        wantsAudio=true;audioChanged();Thread.sleep(80);checkActive(token)
        val track=AudioTrack.Builder().setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
            .setAudioFormat(AudioFormat.Builder().setEncoding(AudioFormat.ENCODING_PCM_FLOAT).setSampleRate(48000).setChannelMask(AudioFormat.CHANNEL_OUT_STEREO).build())
            .setBufferSizeInBytes(max(48000*2*4/5,AudioTrack.getMinBufferSize(48000,AudioFormat.CHANNEL_OUT_STEREO,AudioFormat.ENCODING_PCM_FLOAT))).setTransferMode(AudioTrack.MODE_STREAM).build()
        audio=track;track.setVolume(outputGain);track.play();var offset=0
        while(offset<data.size){checkActive(token);val count=track.write(data,offset,minOf(4096,data.size-offset),AudioTrack.WRITE_BLOCKING);check(count>0);offset+=count}
        val deadline=System.nanoTime()+30_000_000_000L;while((track.playbackHeadPosition.toLong() and 0xffffffffL) < (data.size/2).toLong()){checkActive(token);check(System.nanoTime()<deadline);Thread.sleep(20)}
        checkActive(token);publish {it.put("state","ready").put("played_frames",data.size/2)}
    }
    @Synchronized fun allow(value: Boolean){
        if(value||closed||interrupted)return
        interrupted=true;cancel();val token=generation.get()
        worker.execute {clearEngine();clearCandidate();clearSample();rows=JSONArray()
            if(!closed&&generation.get()==token){publish {it.put("source_ready",false).put("candidates",rows)};phase("ready");if(!opened&&!managing)hold(false)}}
    }
    override fun close(){if(closed)return;closed=true;opened=false;managing=false;cancel();publish {it.put("state","idle").put("ready_key","")};worker.execute {clearEngine();clearCandidate();clearSample();hold(false)}}
}
