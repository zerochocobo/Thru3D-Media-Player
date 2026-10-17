package org.vrpassthroughplayer.plugin

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTimestamp
import android.media.AudioTrack
import android.media.PlaybackParams
import android.os.Process
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.math.abs

/** One media source, one clock, bounded in-memory PCM. Neither subtitles nor PCM are logged/saved. */
internal class NarrationController(private val context: () -> Context?, private val source: () -> Source?,
                                   private val gain: (Double) -> Unit, private val audioChanged: () -> Unit = {}) : AutoCloseable {
    data class Source(val handle: Long, val path: String, val caFile: String, val allowed: Boolean,
                      val volume: Double, val muted: Boolean, val delay: Double, val subtitleCommand: Long)
    private class Speech(val cue: NarrationPolicy.Cue, val epoch: Long) {
        val chunks = mutableListOf<FloatArray>()
        var samples = 0; var cursor = 0; var done = false; var failed = false; var rtf = 0.0
    }
    private val lock = Any()
    private val clock = Executors.newSingleThreadScheduledExecutor { Thread(it, "SubtitleNarrationClock") }
    private val readerWorker = Executors.newSingleThreadExecutor { Thread(it, "SubtitleNarrationReader") }
    @Volatile private var config = NarrationPolicy.Config()
    @Volatile private var closed = false
    @Volatile private var suspended = true
    @Volatile private var report = "{\"state\":\"off\"}"
    @Volatile private var soundEligible = false
    private var epoch = 1L
    private var engine = 0L
    private var loading = false
    private var modelFailure = ""
    private var reader = 0L
    private var reading = false
    private var readThrough = -1.0
    private var sourceKey = ""
    private var timelineFailed = false
    private var runtimeFailed = false
    private var outputSpeed = 1.0
    private var outputFit = 1.0
    private var previewPending = false
    private var previewActive = false
    private var lastSeek = -1L
    private var language = ""
    private var windows = emptyList<NarrationPolicy.Cue>()
    private val cache = linkedMapOf<String, Speech>()
    private val spoken = linkedSetOf<String>()
    private val prepared = linkedSetOf<String>()
    private var synthesizing = false
    private var output: Speech? = null
    private var track: AudioTrack? = null
    private var writeOrigin = 0
    private var written = 0L
    private var underruns = 0
    private var lastGain = 1.0
    private var gainTarget = 1.0
    private var gainStart = 1.0
    private var gainElapsed = 0.0
    private var lastTick = System.nanoTime()
    private var nextPoll = 0L
    private var observation = JSONObject()
    private var outer = JSONObject()
    private var state = "off"
    private var completed = 0
    private var lateSkipped = 0
    private var timestampFrames = 0L
    private var timestampNs = 0L
    private var writtenTotal = 0L
    private var lastRtf = 0.0
    private var lastLatenessMs = 0.0
    private var outputPaused = false
    private var phaseErrorMs = 0.0
    val enabled get() = config.enabled && !closed
    val wantsAudio get() = enabled && soundEligible
    init { clock.scheduleWithFixedDelay({ runCatching { tick() }.onFailure { synchronized(lock) { state="speech_error";runtimeFailed=true;stopOutput();restoreGain();publish() } } }, 0, 20, TimeUnit.MILLISECONDS) }

    fun configure(value: String): Boolean {
        val next = try { NarrationPolicy.Config.parse(value) } catch (_: Exception) { return false }
        synchronized(lock) {
            if (closed) return false
            val previous = config; config = next
            if (previous == next) return true
            if(previous.copy(preview=next.preview)==next && next.enabled) {
                invalidate();previewPending=true;return true
            }
            val activeSpeech=output
            val voiceOnly=previous.copy(zhVoice=next.zhVoice,enVoice=next.enVoice,duck=next.duck,volume=next.volume)==next
            if (voiceOnly && activeSpeech!=null) {
                cache.clear();cache[activeSpeech.cue.key]=activeSpeech;prepared.clear();prepared+=activeSpeech.cue.key
                return true // Current sentence finishes in its existing voice; future synthesis uses the new one.
            }
            if (previous.copy(duck=next.duck, volume=next.volume) != next) {
                invalidate(); sourceKey=""; modelFailure=""
            }
            if (!next.enabled) { unload(); state="off" }
        }
        return true
    }
    fun status() = JSONObject(report)
    fun timelineChanged() = synchronized(lock) { if(config.source<0) {invalidate();sourceKey=""} }
    fun transportChanged() = synchronized(lock) {invalidate();sourceKey="";nextPoll=0}
    fun allow(value: Boolean) { suspended=!value; if (!value) synchronized(lock) { pauseOutput(); restoreGain() } }
    private fun restoreGain() {
        if (lastGain != 1.0) { runCatching { gain(1.0) }; lastGain=1.0 }
        gainTarget=1.0;gainStart=1.0;gainElapsed=0.0
    }
    private fun pauseOutput() {
        if(outputPaused)return
        track?.let { audio ->
            val played = audio.playbackHeadPosition.toLong() and 0xffffffffL
            output?.let { it.cursor=(writeOrigin+played.toInt()*2).coerceAtMost(it.samples) }
            runCatching { audio.pause(); audio.flush() }
        }
        writeOrigin=output?.cursor ?: 0;written=0
        timestampFrames=0;timestampNs=0
        outputPaused=true
    }
    private fun stopOutput() {
        pauseOutput(); track?.let { audio -> underruns += runCatching { audio.underrunCount }.getOrDefault(0); runCatching { audio.release() } }
        track=null; output=null;written=0;writeOrigin=0;outputPaused=false
    }
    private fun invalidate() {
        if(soundEligible) {soundEligible=false;audioChanged()}
        ++epoch
        if (engine > 0) runCatching { NarrationNative.cancel(engine, epoch) }
        if (reader > 0) runCatching { NarrationNative.closeReader(reader) }
        reader=0;reading=false;readThrough=-1.0;windows=emptyList();cache.clear();spoken.clear();prepared.clear();timelineFailed=false;runtimeFailed=false
        previewPending=false;previewActive=false
        stopOutput();restoreGain()
    }
    private fun unload() {
        val old=engine;engine=0
        if (old > 0) synthesis.execute { NarrationNative.destroy(old) }
    }
    private fun prepareModel() {
        if (loading || engine > 0 || modelFailure.isNotEmpty()) return
        loading=true;val token=epoch
        synthesis.execute {
            Process.setThreadPriority(5)
            var loaded=0L;var failure="model_error"
            try {
                val app=context() ?: error("Unavailable")
                val manifest=app.assets.open("narration/model.json").bufferedReader().use { JSONObject(it.readText()) }
                val directory=File(app.filesDir,manifest.getString("directory")).canonicalFile
                val files=manifest.getJSONObject("files")
                if (!directory.isDirectory) { failure="model_missing";error("Unavailable") }
                for (name in files.keys()) {
                    val file=File(directory,name).canonicalFile;val expected=files.getJSONObject(name)
                    require(file.path.startsWith(directory.path+File.separator) && file.isFile && file.length()==expected.getLong("bytes"))
                    val digest=MessageDigest.getInstance("SHA-256")
                    file.inputStream().buffered().use { input -> val bytes=ByteArray(128*1024);while(true) {val count=input.read(bytes);if(count<0)break;digest.update(bytes,0,count)} }
                    require(digest.digest().joinToString("") { "%02x".format(it) }==expected.getString("sha256"))
                    synchronized(lock) { if (closed || token!=epoch) error("Cancelled") }
                }
                loaded=NarrationNative.create(directory.path)
            } catch (_: LinkageError) { /* Missing/incompatible runtime is a recoverable model error. */
            } catch (_: Exception) { /* Deliberately no URI, subtitle text or model exception in logs. */ }
            synchronized(lock) {
                loading=false
                if (closed || token!=epoch) { if(loaded>0)NarrationNative.destroy(loaded);return@synchronized }
                engine=loaded;modelFailure=if(loaded==0L)failure else ""
                if(engine>0)NarrationNative.cancel(engine,epoch)
            }
        }
    }
    private fun timeline(path: String, index: Int, position: Double, lang: String, delay: Double) {
        if (reading || position+10 < readThrough) return
        if (reader == 0L) reader=NarrationNative.openReader(path,index,source()?.caFile.orEmpty())
        val current=reader;val token=epoch;val end=position+20
        reading=true
        readerWorker.execute {
            // Parsing and normalization run on this worker too; contain their failures alongside native reads.
            val result=runCatching {
                val raw=org.json.JSONArray(NarrationNative.readWindow(current,maxOf(0.0,position-delay),maxOf(0.0,position-delay)+20))
                NarrationPolicy.cues(raw,lang).map { it.copy(start=it.start+delay,end=it.end+delay,windowStart=it.windowStart+delay,windowEnd=it.windowEnd+delay) }
            }
            synchronized(lock) {
                if(closed||token!=epoch)return@synchronized
                reading=false
                if(result.isFailure) { state="timeline_error";timelineFailed=true;restoreGain();return@synchronized }
                windows=result.getOrThrow()
                readThrough=end
            }
        }
    }
    private fun generate(position: Double) {
        if(synthesizing||engine==0L||cache.values.sumOf { it.samples }>48000*2*10)return
        val cue=windows.firstOrNull { it.end>position && it.start<=position+10 && it.key !in spoken && it.key !in cache } ?: return
        if(cue.start+config.offset<position-.4) { spoken+=cue.key;lateSkipped++;return }
        val speech=Speech(cue,epoch);cache[cue.key]=speech;val model=engine;val token=epoch;val voice=config.voice(language)
        synthesizing=true
        synthesis.execute {
            var result: JSONObject?=null
            try {
                NarrationNative.cancel(model,token)
                result=JSONObject(NarrationNative.synthesize(model,cue.text,voice,token,object: NarrationNative.Sink {
                    override fun onChunk(epoch: Long, pcm: FloatArray): Boolean = synchronized(lock) {
                        if(closed||this@NarrationController.epoch!=epoch||cache[cue.key]!==speech||
                            cache.values.sumOf { it.samples }+pcm.size>48000*2*20)return@synchronized false
                        speech.chunks+=pcm;speech.samples+=pcm.size;prepared+=cue.key;true
                    }
                }))
            } catch (_: Exception) { }
            synchronized(lock) {
                synthesizing=false
                if(closed||token!=epoch||cache[cue.key]!==speech)return@synchronized
                speech.done=true;speech.failed=result==null||result.optBoolean("cancelled")||!result.optBoolean("eos")||result.optDouble("audio_seconds",0.0)<=0
                speech.rtf=result?.let { it.optDouble("wall_seconds")/it.optDouble("audio_seconds") } ?: 0.0
                if(speech.rtf.isFinite())lastRtf=speech.rtf
                if(speech.failed) { if(output===speech)stopOutput();cache.remove(cue.key);spoken+=cue.key;prepared.remove(cue.key);state="speech_error";runtimeFailed=true;restoreGain() }
            }
        }
    }
    private fun begin(speech: Speech, current: Source, speed: Double) {
        stopOutput();output=speech;writeOrigin=speech.cursor
        val minimum=AudioTrack.getMinBufferSize(48000,AudioFormat.CHANNEL_OUT_STEREO,AudioFormat.ENCODING_PCM_FLOAT)
        require(minimum>0)
        val audio=AudioTrack.Builder().setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
            .setAudioFormat(AudioFormat.Builder().setSampleRate(48000).setChannelMask(AudioFormat.CHANNEL_OUT_STEREO).setEncoding(AudioFormat.ENCODING_PCM_FLOAT).build())
            .setTransferMode(AudioTrack.MODE_STREAM).setBufferSizeInBytes(maxOf(minimum,48000*2*4/3)).build()
        check(audio.state==AudioTrack.STATE_INITIALIZED);track=audio
        val duration=if(speech.done)speech.samples/96000.0 else speech.cue.end-speech.cue.start
        val fit=(duration/(speech.cue.end-speech.cue.start+.3)).coerceIn(1.0,1.3)
        outputFit=fit;outputSpeed=speed*config.rate*fit
        audio.playbackParams=PlaybackParams().setSpeed(outputSpeed.toFloat().coerceIn(.25f,3.9f)).setPitch(1f)
        audio.setVolume(if(current.muted)0f else (current.volume/100*config.volume).toFloat())
        // Prime a small bounded buffer before play(), so startup itself does not underrun.
        write(speech,audio);audio.play()
    }
    private fun write(speech: Speech, audio: AudioTrack) {
        val played=audio.playbackHeadPosition.toLong() and 0xffffffffL
        var budget=((48000*outputSpeed*.06).toLong()-(written-played)).coerceAtLeast(0).toInt()*2
        var skip=speech.cursor
        for(chunk in speech.chunks) {
            if(skip>=chunk.size) {skip-=chunk.size;continue}
            if(budget<=0)break
            val count=minOf(chunk.size-skip,budget)
            val result=audio.write(chunk,skip,count,AudioTrack.WRITE_NON_BLOCKING)
            check(result>=0);speech.cursor+=result;written+=result/2;writtenTotal+=result/2;budget-=result
            if(result<count)break
            skip=0
        }
        val timestamp=AudioTimestamp()
        if(audio.getTimestamp(timestamp)) {timestampFrames=timestamp.framePosition;timestampNs=timestamp.nanoTime}
    }
    private fun tick() = synchronized(lock) {
        if(closed)return@synchronized
        val now=System.nanoTime();val delta=((now-lastTick)/1e9).coerceIn(0.0,.1);lastTick=now
        val current=source()
        if(!config.enabled||current==null||current.handle<=0) {state="off";restoreGain();publish();return@synchronized}
        if(now>=nextPoll) {
            outer=JSONObject(MpvSourceNative.status(current.handle));observation=outer.optJSONObject("details") ?: JSONObject();nextPoll=now+100_000_000
        }
        val subtitle=observation.optJSONObject("subtitle") ?: JSONObject()
        val selected=if(config.source<0)subtitle.optString("track_id").toIntOrNull() ?: 0 else config.source
        val tracks=observation.optJSONArray("subtitle_tracks")
        val metadata=tracks?.let { (0 until it.length()).map { i -> it.getJSONObject(i) }.find { it.optInt("id")==selected } }
        val lang=if(config.language=="auto")NarrationPolicy.language(metadata?.optString("language").orEmpty()) else config.language
        val delay=config.sourceDelay ?: current.delay
        val identity="$selected:$lang:$delay"
        val seek=outer.optLong("seeks_started")
        if(identity!=sourceKey || seek!=lastSeek) {
            invalidate();sourceKey=identity;lastSeek=seek;language=lang
        }
        val observed=observation.optLong("observed_monotonic_ns")
        val age=(now-observed)/1e9
        val speed=observation.optString("playback_speed").toDoubleOrNull() ?: 1.0
        val clockValid=age in 0.0..0.5 && outer.optLong("seeks_started")==outer.optLong("seeks_completed") &&
            outer.optLong("last_source_epoch")>=outer.optLong("epoch_floor") &&
            subtitle.optLong("source_epoch")>=outer.optLong("epoch_floor") &&
            subtitle.optBoolean("timeline_valid") && (config.source>=0 || subtitle.optLong("command_id")>=current.subtitleCommand)
        val playing=current.allowed&&!suspended&&observation.optString("paused")!="yes"&&observation.optString("paused_for_cache")!="yes"&&
            observation.optString("eof_reached")!="yes"&&clockValid
        val base=observation.optString("position_seconds").toDoubleOrNull() ?: 0.0
        val position=base+if(playing)age*speed else 0.0
        val index=metadata?.optInt("stream_index",-1) ?: -1
        val path=if(metadata?.optBoolean("external")==true)metadata.optString("filename") else current.path
        val preview=previewPending||previewActive
        val readable=metadata!=null&&index>=0&&metadata.optString("codec") in TEXT_CODECS
        if(lang.isNotEmpty() && (readable||preview))prepareModel()
        state=when {
            metadata==null&&!preview->"subtitle_required"
            lang.isEmpty()->"language_required"
            !preview&&!readable->"unsupported_subtitle"
            modelFailure.isNotEmpty()->modelFailure
            runtimeFailed->"speech_error"
            engine==0L->"loading"
            timelineFailed->"timeline_error"
            !clockValid->"waiting"
            else->"ready"
        }
        if(state=="ready") {
            if(previewPending) {
                val text=if(lang=="zh")"欢迎使用字幕朗读。现在我们一起欣赏这段精彩的视频。" else "Welcome to subtitle narration. Now we can enjoy this wonderful video together."
                windows=listOf(NarrationPolicy.Cue(position+1.5,position+9.5,text));previewPending=false;previewActive=true
            }
            if(!previewActive)timeline(path,index,position,lang,delay)
            generate(position)
        }
        val expired=cache.values.filter { it.cue.end+.4<position }
        for(speech in expired) {if(output===speech)stopOutput();cache.remove(speech.cue.key);spoken+=speech.cue.key}
        if(previewActive && windows.isNotEmpty() && (windows.first().key in spoken || position>windows.first().end+.4)) {
            invalidate();sourceKey="";publish();return@synchronized
        }
        while(spoken.size>256)spoken.remove(spoken.first())
        if(!playing || state!="ready") {pauseOutput();restoreGain();publish();return@synchronized}
        var active=output
        if(active==null) {
            active=cache.values.firstOrNull { !it.failed&&(it.samples>=96000||it.done)&&position>=it.cue.start+config.offset&&position<it.cue.end+.4 }
            if(active!=null) {
                if(position>active.cue.start+config.offset+.4) {spoken+=active.cue.key;cache.remove(active.cue.key);lateSkipped++;active=null}
                else {lastLatenessMs=(position-active.cue.start-config.offset)*1000;begin(active,current,speed)}
            }
        }
        if(active!=null) {
            val audio=track
            if(audio!=null) {
                var correction=1.0
                val timestampAge=(now-timestampNs)/1e9
                if(timestampNs>0&&timestampAge in 0.0..0.25) {
                    val heard=writeOrigin/2.0+timestampFrames+timestampAge*48000*outputSpeed
                    val heardMedia=active.cue.start+config.offset+heard/48000/(config.rate*outputFit)
                    phaseErrorMs=(heardMedia-position)*1000
                    correction=(1.0-(heardMedia-position)*.15).coerceIn(.97,1.03)
                }
                val targetSpeed=(speed*config.rate*outputFit*correction).coerceAtMost(speed*1.3)
                if(abs(targetSpeed-outputSpeed)>.0025) { audio.playbackParams=PlaybackParams().setSpeed(targetSpeed.toFloat().coerceIn(.25f,3.9f)).setPitch(1f);outputSpeed=targetSpeed }
                if(audio.playState!=AudioTrack.PLAYSTATE_PLAYING) {write(active,audio);audio.play();outputPaused=false}
                audio.setVolume(if(current.muted)0f else (current.volume/100*config.volume).toFloat())
                write(active,audio)
                val played=audio.playbackHeadPosition.toLong() and 0xffffffffL
                if(active.done && active.cursor>=active.samples && played>=written) {
                    completed++;spoken+=active.cue.key;cache.remove(active.cue.key);stopOutput()
                }
            }
        }
        // Entire subtitle windows, including pauses. Only cues with prepared speech duck.
        val readyWindows=windows.filter { it.key in prepared }
        val windowGain=NarrationPolicy.duck(position,readyWindows,config.duck,engine>0&&config.volume>0&&!current.muted)
        val target=if(output!=null&&config.volume>0&&!current.muted)minOf(windowGain,1.0-config.duck) else windowGain
        if(target!=gainTarget) {gainStart=lastGain;gainTarget=target;gainElapsed=0.0}
        gainElapsed+=delta
        val fraction=(gainElapsed/(if(gainTarget<gainStart).15 else .35)).coerceAtMost(1.0)
        val adjusted=gainStart+(gainTarget-gainStart)*fraction
        if(abs(adjusted-lastGain)>.005 || adjusted==target && adjusted!=lastGain) {gain(adjusted);lastGain=adjusted}
        if(output!=null)state="speaking"
        publish()
    }
    private fun publish() {
        val needsAudio=enabled&&engine>0&&config.volume>0&&state in setOf("ready","speaking")
        if(needsAudio!=soundEligible) {soundEligible=needsAudio;audioChanged()}
        report=JSONObject().put("state",state).put("enabled",config.enabled).put("language",language)
            .put("model_ready",engine>0).put("generation",epoch).put("cached_seconds",cache.values.sumOf { it.samples-it.cursor }/96000.0)
            .put("completed",completed).put("late_skipped",lateSkipped).put("underruns",underruns+(track?.underrunCount ?: 0))
            .put("original_gain",lastGain).put("audio_timestamp_frames",timestampFrames).put("audio_timestamp_ns",timestampNs).toString()
        report=JSONObject(report).put("written_frames",writtenTotal).put("last_rtf",lastRtf).put("last_lateness_ms",lastLatenessMs).put("phase_error_ms",phaseErrorMs).toString()
    }
    override fun close() {
        synchronized(lock) {if(closed)return;closed=true;invalidate();unload()}
        clock.shutdownNow();readerWorker.shutdownNow()
    }
    companion object {
        private val synthesis=Executors.newSingleThreadExecutor { Thread(it,"MossSubtitleSynthesis") }
        val TEXT_CODECS=setOf("subrip","ass","ssa","webvtt","mov_text","text","sami","microdvd","subviewer","ttml")
    }
}
