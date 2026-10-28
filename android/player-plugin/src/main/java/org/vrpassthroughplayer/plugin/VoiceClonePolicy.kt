package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest

internal object VoiceClonePolicy {
    class Reference(val path: String, private val release: () -> Unit) : AutoCloseable {
        private val released = java.util.concurrent.atomic.AtomicBoolean()
        override fun close() { if (released.compareAndSet(false,true)) release() }
    }
    /** Debug health only: never export subtitle text, names, voice IDs or paths. */
    fun referenceHealth(state: JSONObject): JSONObject = JSONObject().also { result ->
        for(key in listOf("opened","state","error_code","error_detail","played_frames","preview_frames","reference_input_db","reference_output_db","reference_gain_db","reference_center"))
            if(state.has(key))result.put(key,state.get(key))
        val candidates=state.optJSONArray("candidates") ?: JSONArray()
        result.put("candidate_count",candidates.length()).put("probe_candidate_key",candidates.optJSONObject(0)?.optString("key").orEmpty())
    }
    data class Input(val path: String, val stream: Int, val disc: Boolean)
    /** Independent DLNA caption files may have no MPV FFmpeg stream index. */
    fun input(movie: String, track: JSONObject, disc: Boolean = false): Input {
        val external = track.optBoolean("external")
        val path = if (external) track.optString("filename") else movie
        check(path.isNotBlank()) { "voice_input_unavailable" }
        val index = track.optInt("stream_index", -1)
        check(external || index >= 0) { "voice_input_unavailable" }
        return Input(path, if (external && index < 0) 0 else index, disc && !external)
    }
    fun diagnostic(error: Throwable): String = error.message.orEmpty().takeIf {
        it.matches(Regex("(voice_[a-z_]+|No value for [a-z_]+|voice_extract:[A-Za-z -]+(?::-?[0-9]+)?|subtitle_[a-z_]+:-?[0-9]+)"))
    } ?: "internal"
    fun playbackGain(videoVolume: Double,narrationVolume: Double,original: Boolean): Float {
        require(videoVolume.isFinite()&&videoVolume in 0.0..100.0&&narrationVolume.isFinite()&&narrationVolume in 0.0..1.0)
        return (videoVolume/100*(if(original)1.0 else narrationVolume)).toFloat()
    }
    fun audioTrack(requested: Int,details: JSONObject): JSONObject {
        val tracks=details.optJSONArray("audio_tracks") ?: error("voice_audio_required")
        val options=(0 until tracks.length()).map {tracks.getJSONObject(it)}
        val current=details.optString("audio_track_id").toIntOrNull()
        if(requested>0)return options.firstOrNull {it.optInt("id")==requested} ?: error("voice_audio_required")
        return options.firstOrNull {it.optInt("id")==current}
            ?: options.firstOrNull {it.optInt("stream_index",-1)>=0}
            ?: error("voice_audio_required")
    }
    fun failureCode(operation: String,stage: String,error: Throwable): String = when {
        operation in setOf("save","rename")->"save_failed"
        error.message=="voice_audio_required"||error.message=="voice_track_required"->"audio_required"
        error.message=="voice_subtitles_required"->"subtitles_failed"
        error.message=="voice_preview_muted"->"preview_muted"
        error.message=="voice_pause_timeout"->"pause_failed"
        error.message=="voice_synthesis_failed"->"synthesis_failed"
        error.message=="voice_reference_too_quiet"->"reference_too_quiet"
        error.message=="voice_invalid_range"->"invalid_range"
        stage=="probing"->"source_failed"
        stage=="scanning"->"scan_failed"
        stage=="extracting"->"extract_failed"
        stage=="encoding"->"encode_failed"
        stage=="generating"->"synthesis_failed"
        stage in setOf("model_verifying","model_loading")->"model_failed"
        stage=="reading"->"subtitles_failed"
        stage in setOf("playing_original","playing_clone")->"playback_failed"
        else->"prepare_failed"
    }
    fun failureMessage(code: String): String = when(code) {
        "no_candidates"->"This video has no subtitles suitable for a 3–10 second voice sample."
        "invalid_range"->"Choose a valid time range. Samples must be 3–10 seconds."
        "source_failed"->"Unable to read this media. Choose another source."
        "scan_failed"->"Unable to finish speech analysis. Retry or adjust the range."
        "no_candidates_in_range"->"No suitable samples found yet. Continue searching."
        "audio_required"->"No usable reference audio track. Choose another audio track."
        "preview_muted"->"Unmute and raise the video and narration volume to preview voices."
        "pause_failed"->"Unable to pause the video. Try again."
        "extract_failed"->"Unable to read the original audio. Check the source or choose another sample."
        "encode_failed"->"Unable to clone this voice sample. Try another sample."
        "reference_too_quiet"->"Reference speech is too quiet. Choose a clearer sample."
        "synthesis_failed"->"Unable to generate the voice preview. Try again."
        "model_failed"->"Unable to load narration model"
        "subtitles_failed"->"Unable to read subtitles. Check the source and try again."
        "playback_failed"->"Unable to play the voice preview. Try again."
        "save_failed"->"Unable to save voice. Check the name and storage."
        else->"Unable to prepare voice. Try another sample."
    }
    /** The second click must stop even if Godot still displays the previous status. */
    fun operation(command: JSONObject,state: JSONObject): String {
        val op=command.optString("operation")
        if(op !in setOf("original","clone","preview")||op!=state.optString("operation"))return op
        val active=state.optString("state") in setOf("preparing","extracting","encoding","model_verifying","model_loading","generating","playing_original","playing_clone")
        val same=if(op=="preview")command.optString("id")==state.optString("preview_id") else command.optString("key")==state.optString("active_key")
        return if(active&&same)"stop" else op
    }
    fun candidates(raw: JSONArray,line: Int): JSONArray {
        require(line in 0..2)
        val events=ArrayList<NarrationPolicy.Cue>()
        val sorted=(0 until raw.length()).mapNotNull {i->raw.getJSONObject(i).let {
            val s=it.optDouble("start");val e=it.optDouble("end");val text=NarrationPolicy.clean(it.optString("text"))
            if(s.isFinite()&&e.isFinite()&&s>=0&&e>s&&text.isNotEmpty())NarrationPolicy.Cue(s,e,text) else null
        }}.distinct().sortedBy {it.start}
        for(cue in sorted){val previous=events.lastOrNull()
            if(previous!=null&&cue.start<previous.end&&(cue.text==previous.text||cue.start==previous.start)){
                val text=if(cue.text.contains(previous.text))cue.text else if(previous.text.contains(cue.text))previous.text else previous.text+"\n"+cue.text
                events[events.lastIndex]=NarrationPolicy.Cue(previous.start,maxOf(previous.end,cue.end),text)
            }else events+=cue
        }
        return JSONArray().also {result->events.forEach {cue->
            val text=if(line==0)cue.text else cue.text.lines().filter {it.isNotBlank()}.getOrNull(line-1).orEmpty()
            if(cue.end-cue.start in (3.0-1e-6)..(10.0+1e-6)&&text.isNotBlank()){
                val key=MessageDigest.getInstance("SHA-256").digest("${cue.start}:${cue.end}:$text".toByteArray(Charsets.UTF_8)).joinToString(""){"%02x".format(it)}
                result.put(JSONObject().put("key",key).put("start",cue.start).put("end",cue.end).put("text",text))
            }
        }}
    }
    fun readWav(file: File): FloatArray {
        require(file.length() in 576044..1920044)
        val bytes=file.readBytes();val b=ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        fun tag(at: Int,text: String)=String(bytes,at,text.length,Charsets.US_ASCII)==text
        require(tag(0,"RIFF")&&tag(8,"WAVEfmt ")&&b.getInt(16)==16&&b.getShort(20).toInt()==1&&b.getShort(22).toInt()==2&&b.getInt(24)==48000&&b.getInt(28)==192000&&b.getShort(32).toInt()==4&&b.getShort(34).toInt()==16&&tag(36,"data"))
        require(b.getInt(4)==bytes.size-8&&b.getInt(40)==bytes.size-44&&(bytes.size-44)%4==0)
        b.position(44);return FloatArray((bytes.size-44)/2){b.short/32768f}
    }
}
