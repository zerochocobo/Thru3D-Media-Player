package org.vrpassthroughplayer.plugin

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTimestamp
import android.media.AudioTrack
import android.os.Process
import android.os.Build
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
                      val volume: Double, val muted: Boolean, val delay: Double, val subtitleCommand: Long,
                      val playRequested: Boolean)
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
    @Volatile private var pausingWithVideo = false
    @Volatile private var startupHold = false
    private var startupDecisionPending = false
    private var startupDeadlineNs = 0L
    private var pauseDeadlineNs = 0L
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
    private var previewPending = false
    private var previewActive = false
    @Volatile private var previewRequested = false
    private var previewPosition = 0.0
    private var lastSeek = -1L
    private var language = ""
    private var windows = emptyList<NarrationPolicy.Cue>()
    private val cache = linkedMapOf<String, Speech>()
    private val spoken = linkedSetOf<String>()
    private val prepared = linkedSetOf<String>()
    private var synthesizing = false
    private var output: Speech? = null
    private var outputStarted = false
    private var playStartedNs = 0L
    private var playOriginFrames = 0L
    private var outputLatencySeconds = 0.0
    private var rendered: NarrationPcm? = null
    private var track: AudioTrack? = null
    private var writeOrigin = 0
    private var written = 0L
    private var speechEndFrame = -1L
    private val tailSilence = FloatArray(OUTPUT_LEAD_FRAMES*2)
    private var lastFeedNs = 0L
    private var maxFeedGapMs = 0.0
    private var underruns = 0
    private var lastGain = 1.0
    private var gainTarget = 1.0
    private var gainStart = 1.0
    private var gainElapsed = 0.0
    private var lastTick = System.nanoTime()
    private var nextPoll = 0L
    private var observation = JSONObject()
    private var playbackClock = NarrationPolicy.PlaybackClock(0.0,0,"video")
    private var outer = JSONObject()
    private var state = "off"
    private var completed = 0
    private var lateSkipped = 0
    private var synthesisRetries = 0
    private var synthesisFailures = 0
    private var lastGenerationFrames = 0
    private var lastEos = false
    private var timestampFrames = 0L
    private var timestampNs = 0L
    private var writtenTotal = 0L
    private var lastRtf = 0.0
    private var lastLatenessMs = 0.0
    private var outputPaused = false
    private var startupFrames = 0
    private var phaseErrorMs = 0.0
    private var phaseValid = false
    private var phaseSampleNs = 0L
    private var phaseMediaPosition = 0.0
    private var outputCreateMs = 0.0
    private var outputRenderMs = 0.0
    private var outputStartMs = 0.0
    private var outputSetupMs = 0.0
    private var outputResumeMs = 0.0
    private var outputTempo = 1.0
    private var outputRawSeconds = 0.0
    private var outputPcmSeconds = 0.0
    val enabled get() = config.enabled && !closed
    val wantsAudio get() = enabled && soundEligible
    val wantsPreview get() = wantsAudio && previewRequested
    val wantsPauseDrain get() = enabled && pausingWithVideo
    val holdsPlayback get() = enabled && startupHold && !previewRequested
    init { clock.scheduleWithFixedDelay({ runCatching { tick() }.onFailure { synchronized(lock) { state="speech_error";runtimeFailed=true;stopOutput();restoreGain();releaseStartupHold();publish() } } }, 0, 20, TimeUnit.MILLISECONDS) }

    fun configure(value: String): Boolean {
        val next = try { NarrationPolicy.Config.parse(value) } catch (_: Exception) { return false }
        synchronized(lock) {
            if (closed) return false
            val previous = config; config = next
            if (previous == next) return true
            if(previous.copy(preview=next.preview)==next && next.enabled) {
                invalidate();previewPending=true;previewRequested=true;return true
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
    fun pauseWithVideo() = synchronized(lock) {
        // A user pause is asynchronous in MPV. Keep the current sentence aligned
        // until its clock actually stops; never start another one during this wait.
        if(outputStarted&&!previewActive&&!suspended) {
            pausingWithVideo=true;pauseDeadlineNs=System.nanoTime()+200_000_000;nextPoll=0;audioChanged()
        }
    }
    private fun finishPauseDrain() {
        if(pausingWithVideo) {pausingWithVideo=false;audioChanged()}
    }
    fun allow(value: Boolean) {
        val changed=suspended==value;suspended=!value
        synchronized(lock) {
            if(changed)nextPoll=0
            if(!value) {finishPauseDrain();pauseOutput();restoreGain()}
        }
    }
    private fun restoreGain() {
        if (lastGain != 1.0) { runCatching { gain(1.0) }; lastGain=1.0 }
        gainTarget=1.0;gainStart=1.0;gainElapsed=0.0
    }
    private fun pauseOutput() {
        phaseValid=false
        if(outputPaused)return
        track?.let { audio ->
            // pause() preserves unplayed samples and the frame counter. Flushing
            // here loses the presentation pipeline and requires guessing a rewind.
            runCatching { audio.pause() }
        }
        timestampFrames=0;timestampNs=0;lastFeedNs=0
        outputPaused=true
    }
    private fun stopOutput() {
        pauseOutput(); track?.let { audio -> underruns += runCatching { audio.underrunCount }.getOrDefault(0); runCatching { audio.release() } }
        rendered?.close();rendered=null
        track=null; output=null;written=0;speechEndFrame=-1;writeOrigin=0;outputPaused=false;outputStarted=false;playStartedNs=0;playOriginFrames=0;lastFeedNs=0
    }
    private fun invalidate() {
        val hadAudio=soundEligible||previewRequested||pausingWithVideo||startupHold
        soundEligible=false;previewRequested=false;pausingWithVideo=false
        // Hold the requested transport until a fresh clock decides whether this
        // is the beginning of the video. Mid-video changes release immediately.
        startupHold=enabled&&config.volume>0;startupDecisionPending=startupHold
        startupDeadlineNs=if(startupHold)System.nanoTime()+15_000_000_000 else 0
        if(hadAudio||startupHold)audioChanged()
        ++epoch
        if (engine > 0) runCatching { NarrationNative.cancel(engine, epoch) }
        if (reader > 0) runCatching { NarrationNative.closeReader(reader) }
        reader=0;reading=false;readThrough=-1.0;windows=emptyList();cache.clear();spoken.clear();prepared.clear();timelineFailed=false;runtimeFailed=false
        previewPending=false;previewActive=false;previewPosition=0.0
        maxFeedGapMs=0.0
        stopOutput();restoreGain()
    }
    private fun releaseStartupHold() {
        startupDecisionPending=false;startupDeadlineNs=0
        if(startupHold) {startupHold=false;audioChanged()}
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
    private fun generate(position: Double, advancing: Boolean) {
        if(synthesizing||engine==0L||cache.values.sumOf { it.samples }>48000*2*10)return
        val cue=windows.firstOrNull { it.end>position && it.start<=position+15 && it.key !in spoken && it.key !in cache } ?: return
        if(!previewActive && (cue.start+config.offset<position-.4 || !NarrationPolicy.hasPreparationLead(cue.start+config.offset,cue.end+config.offset,position,advancing))) {
            spoken+=cue.key;lateSkipped++;return
        }
        val speech=Speech(cue,epoch);cache[cue.key]=speech;val model=engine;val token=epoch;val voice=config.voice(language)
        val frames=NarrationPolicy.frameBudget(cue.end-cue.start)
        synthesizing=true
        synthesis.execute {
            var result: JSONObject?=null
            for(attempt in 0..1) {
              try {
                NarrationNative.cancel(model,token)
                result=JSONObject(NarrationNative.synthesizeConfigured(model,cue.text,voice,token,frames,if(attempt==0)0 else 17,object: NarrationNative.Sink {
                    override fun onChunk(epoch: Long, pcm: FloatArray): Boolean = synchronized(lock) {
                        if(closed||this@NarrationController.epoch!=epoch||cache[cue.key]!==speech||
                            cache.values.sumOf { it.samples }+pcm.size>48000*2*20)return@synchronized false
                        speech.chunks+=pcm;speech.samples+=pcm.size;if(previewActive)prepared+=cue.key;true
                    }
                }))
              } catch (_: Exception) { result=null }
              val success=result?.let {it.optBoolean("eos")&&!it.optBoolean("cancelled")&&it.optDouble("audio_seconds",0.0)>0} ?: false
              if(success||attempt==1)break
              synchronized(lock) {
                  if(closed||token!=epoch||cache[cue.key]!==speech){synthesizing=false;return@execute}
                  if(output===speech) {stopOutput();if(previewActive)previewPosition=0.0}
                  speech.chunks.clear();speech.samples=0;speech.cursor=0;prepared.remove(cue.key);synthesisRetries++
              }
            }
            synchronized(lock) {
                synthesizing=false
                if(closed||token!=epoch||cache[cue.key]!==speech)return@synchronized
                speech.done=true;speech.failed=result==null||result.optBoolean("cancelled")||!result.optBoolean("eos")||result.optDouble("audio_seconds",0.0)<=0
                speech.rtf=result?.let { it.optDouble("wall_seconds")/it.optDouble("audio_seconds") } ?: 0.0
                if(speech.rtf.isFinite())lastRtf=speech.rtf
                lastGenerationFrames=result?.let {kotlin.math.round(it.optDouble("audio_seconds",0.0)/.08).toInt()} ?: 0
                lastEos=result?.optBoolean("eos") ?: false
                if(speech.failed) {
                    if(output===speech){stopOutput();restoreGain()}
                    cache.remove(cue.key);spoken+=cue.key;prepared.remove(cue.key);synthesisFailures++
                } else prepared+=cue.key
            }
        }
    }
    private fun begin(speech: Speech, current: Source, speed: Double) {
        val setupStarted=System.nanoTime()
        stopOutput();output=speech;writeOrigin=0
        val minimum=AudioTrack.getMinBufferSize(48000,AudioFormat.CHANNEL_OUT_STEREO,AudioFormat.ENCODING_PCM_FLOAT)
        require(minimum>0)
        val audio=AudioTrack.Builder().setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
            .setAudioFormat(AudioFormat.Builder().setSampleRate(48000).setChannelMask(AudioFormat.CHANNEL_OUT_STEREO).setEncoding(AudioFormat.ENCODING_PCM_FLOAT).build())
            .setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY)
            .setTransferMode(AudioTrack.MODE_STREAM).setBufferSizeInBytes(maxOf(minimum,48000*2*4/3)).build()
        check(audio.state==AudioTrack.STATE_INITIALIZED);track=audio
        val created=System.nanoTime();outputCreateMs=(created-setupStarted)/1e6
        val duration=if(speech.done)speech.samples/96000.0 else speech.cue.end-speech.cue.start
        val tempo=speed*NarrationPolicy.playbackRate(duration,speech.cue.end-speech.cue.start,lastLatenessMs/1000,config.rate)
        rendered=NarrationPcm(tempo).also {it.update(speech.chunks,speech.done);speech.cursor=speech.samples}
        outputTempo=tempo;outputRawSeconds=duration;outputPcmSeconds=rendered!!.samples/96000.0
        outputRenderMs=(System.nanoTime()-created)/1e6
        audio.setVolume(if(current.muted)0f else (current.volume/100*config.volume).toFloat())
        // Prepare before the cue boundary; only play() belongs on the deadline.
        prime(speech,audio)
        outputStartMs=0.0;outputSetupMs=(System.nanoTime()-setupStarted)/1e6
    }
    private fun prime(speech: Speech, audio: AudioTrack) {
        // A large AudioTrack defaults to a full-buffer startup threshold. A bounded
        // 60 ms producer must lower it, or neither the playback head nor writes advance.
        val pcm=rendered ?: error("Missing PCM")
        val leadFrames=OUTPUT_LEAD_FRAMES // Prefilled before play(); absorbs producer scheduling stalls.
        startupFrames=if(Build.VERSION.SDK_INT>=31) {
            audio.setStartThresholdInFrames(minOf(leadFrames,maxOf(1,(pcm.samples-pcm.cursor)/2)))
        } else {
            // Android 10/11 have no threshold setter: shrink the active buffer and prime it fully.
            audio.setBufferSizeInFrames(leadFrames)
        }
        check(startupFrames>0)
        write(speech,audio,startupFrames)
        if(pcm.done && written<startupFrames) {
            val silence=FloatArray((startupFrames-written).toInt()*2)
            val count=audio.write(silence,0,silence.size,AudioTrack.WRITE_NON_BLOCKING)
            check(count>=0);written+=count/2;writtenTotal+=count/2
        }
    }
    private fun write(speech: Speech, audio: AudioTrack, leadFrames: Int=OUTPUT_LEAD_FRAMES) {
        if(outputStarted&&audio.playState==AudioTrack.PLAYSTATE_PLAYING) {
            val feeding=System.nanoTime()
            if(lastFeedNs>0)maxFeedGapMs=maxOf(maxFeedGapMs,(feeding-lastFeedNs)/1e6)
            lastFeedNs=feeding
        }
        val pcm=rendered ?: error("Missing PCM")
        pcm.update(speech.chunks,speech.done);speech.cursor=speech.samples
        val played=audio.playbackHeadPosition.toLong() and 0xffffffffL
        var budget=(leadFrames-(written-played)).coerceAtLeast(0).toInt()*2
        var skip=pcm.cursor
        for(chunk in pcm.chunks) {
            if(skip>=chunk.size) {skip-=chunk.size;continue}
            if(budget<=0)break
            val count=minOf(chunk.size-skip,budget)
            val result=audio.write(chunk,skip,count,AudioTrack.WRITE_NON_BLOCKING)
            check(result>=0);pcm.cursor+=result;written+=result/2;writtenTotal+=result/2;budget-=result
            if(result<count)break
            skip=0
        }
        if(pcm.done && pcm.cursor>=pcm.samples) {
            if(speechEndFrame<0)speechEndFrame=written
            // Keep the mixer supplied while the final speech frames drain. A raw
            // buffer starvation at EOS is otherwise reported as an underrun.
            if(budget>0) {
                val count=audio.write(tailSilence,0,minOf(budget,tailSilence.size),AudioTrack.WRITE_NON_BLOCKING)
                check(count>=0);written+=count/2;writtenTotal+=count/2
            }
        }
        val timestamp=AudioTimestamp()
        if(audio.getTimestamp(timestamp)) {timestampFrames=timestamp.framePosition;timestampNs=timestamp.nanoTime}
    }
    private fun tick() = synchronized(lock) {
        if(closed)return@synchronized
        phaseValid=false
        val now=System.nanoTime();val delta=((now-lastTick)/1e9).coerceIn(0.0,.1);lastTick=now
        val current=source()
        if(!config.enabled||current==null||current.handle<=0) {state="off";restoreGain();releaseStartupHold();publish();return@synchronized}
        if(now>=nextPoll) {
            outer=JSONObject(MpvSourceNative.narrationStatus(current.handle));observation=outer.optJSONObject("details") ?: JSONObject()
            val transition=pausingWithVideo || outputStarted&&!outputPaused&&!previewActive || current.playRequested&&current.allowed&&!suspended&&
                (observation.optString("paused")=="yes"||observation.optString("paused_for_cache")=="yes")
            nextPoll=now+if(transition)20_000_000 else 100_000_000
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
        playbackClock=NarrationPolicy.playbackClock(observation)
        val observed=playbackClock.observedNs
        val clockNow=System.nanoTime()
        val age=(clockNow-observed)/1e9
        val speed=observation.optString("playback_speed").toDoubleOrNull() ?: 1.0
        val clockValid=age in 0.0..0.5 && outer.optLong("seeks_started")==outer.optLong("seeks_completed") &&
            outer.optLong("last_source_epoch")>=outer.optLong("epoch_floor") &&
            subtitle.optLong("source_epoch")>=outer.optLong("epoch_floor") &&
            subtitle.optBoolean("timeline_valid") && (config.source>=0 || subtitle.optLong("command_id")>=current.subtitleCommand)
        val mediaPlaying=current.allowed&&!suspended&&observation.optString("paused")!="yes"&&observation.optString("paused_for_cache")!="yes"&&
            observation.optString("eof_reached")!="yes"&&clockValid
        if(pausingWithVideo&&(current.playRequested||!mediaPlaying||now>=pauseDeadlineNs)) {
            if(!current.playRequested)pauseOutput()
            finishPauseDrain()
        }
        val base=playbackClock.position
        val mediaPosition=base+if(mediaPlaying)age*speed else 0.0
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
            !clockValid&&!preview->"waiting"
            else->"ready"
        }
        var position=if(previewActive)previewPosition else mediaPosition
        if(startupHold) {
            if(preview||config.volume<=0||current.muted||now>=startupDeadlineNs||
                state in setOf("model_missing","model_error","speech_error","timeline_error","subtitle_required","language_required","unsupported_subtitle"))releaseStartupHold()
            else if(startupDecisionPending&&clockValid) {
                startupDecisionPending=false
                if(!readable||lang.isEmpty()||mediaPosition !in -0.25..0.4)releaseStartupHold()
            }
        }
        if(state=="ready") {
            if(previewPending) {
                val text=if(lang=="zh")"欢迎使用字幕朗读。现在我们一起欣赏这段精彩的视频。" else "Welcome to subtitle narration. Now we can enjoy this wonderful video together."
                // Audition the voice on its own clock, including when the video is paused.
                // The clock starts with output, so model preparation cannot expire the sample.
                windows=listOf(NarrationPolicy.Cue(0.0,8.0,text));previewPending=false;previewActive=true
                previewPosition=0.0;position=0.0
            }
            if(!previewActive)timeline(path,index,position,lang,delay)
            generate(position,mediaPlaying&&position>=0&&!holdsPlayback)
        }
        val expired=cache.values.filter { it.cue.end+.4<position }
        for(speech in expired) {if(output===speech)stopOutput();cache.remove(speech.cue.key);spoken+=speech.cue.key}
        if(previewActive && windows.isNotEmpty() && (windows.first().key in spoken || position>windows.first().end+.4)) {
            invalidate();sourceKey="";publish();return@synchronized
        }
        while(spoken.size>256)spoken.remove(spoken.first())
        val playing=if(previewActive)current.allowed&&!suspended else mediaPlaying&&(current.playRequested||pausingWithVideo)
        val offset=if(previewActive)0.0 else config.offset
        val outputSpeed=if(previewActive)1.0 else speed
        var active=output
        if(active==null&&state=="ready") {
            val warmup=if(previewActive)0.0 else .5
            active=cache.values.firstOrNull { !it.failed&&(it.done||(previewActive&&it.samples>=96000))&&position+warmup>=it.cue.start+offset&&position<it.cue.end+.4 }
            if(active!=null) {
                if(position>active.cue.start+offset+.4) {spoken+=active.cue.key;cache.remove(active.cue.key);prepared.remove(active.cue.key);lateSkipped++;active=null}
                else {lastLatenessMs=maxOf(0.0,position-active.cue.start-offset)*1000;begin(active,current,outputSpeed)}
            }
        }
        if(holdsPlayback&&state=="ready"&&!startupDecisionPending&&
            (active!=null || !reading&&readThrough>=0&&windows.none {
                it.end>position&&it.start+offset<=position+.5&&it.key !in spoken
            }))releaseStartupHold()
        if(!playing || state!="ready") {pauseOutput();restoreGain();publish();return@synchronized}
        if(active!=null) {
            val audio=track
            if(audio!=null) {
                if(!outputStarted&&position>=active.cue.start+offset-outputLatencySeconds*outputSpeed) {
                    if(outputPaused)prime(active,audio)
                    playOriginFrames=audio.playbackHeadPosition.toLong() and 0xffffffffL
                    playStartedNs=System.nanoTime();audio.play();outputStartMs=(System.nanoTime()-playStartedNs)/1e6
                    lastFeedNs=playStartedNs
                    outputStarted=true;outputPaused=false
                    lastLatenessMs=maxOf(0.0,position-active.cue.start-offset)*1000
                }
                if(outputStarted&&audio.playState!=AudioTrack.PLAYSTATE_PLAYING) {
                    val resuming=System.nanoTime();prime(active,audio)
                    playOriginFrames=audio.playbackHeadPosition.toLong() and 0xffffffffL
                    playStartedNs=System.nanoTime();audio.play();outputPaused=false;lastFeedNs=playStartedNs
                    outputResumeMs=(System.nanoTime()-resuming)/1e6
                }
                audio.setVolume(if(current.muted)0f else (current.volume/100*config.volume).toFloat())
                if(outputStarted)write(active,audio)
                val phaseNow=System.nanoTime()
                val timestampAge=(phaseNow-timestampNs)/1e9
                if(outputStarted&&timestampNs>=playStartedNs&&timestampNs>0&&timestampAge in 0.0..0.25) {
                    phaseValid=true;phaseSampleNs=phaseNow;phaseMediaPosition=position+(phaseNow-clockNow)/1e9*outputSpeed
                    val heard=writeOrigin/2.0+timestampFrames+timestampAge*48000
                    val heardMedia=active.cue.start+offset+heard/48000*outputSpeed
                    phaseErrorMs=(heardMedia-phaseMediaPosition)*1000
                    if(timestampFrames>=24000&&audio.underrunCount==0) {
                        val measured=(timestampNs-playStartedNs)/1e9-(timestampFrames-playOriginFrames)/48000.0
                        if(measured in 0.0..0.25)outputLatencySeconds=outputLatencySeconds*.8+measured*.2
                    }
                }
                val played=audio.playbackHeadPosition.toLong() and 0xffffffffL
                val presented=if(timestampNs>=playStartedNs&&timestampNs>0&&timestampAge in -.25..0.25)
                    timestampFrames+timestampAge*48000 else played.toDouble()
                if(active.done && rendered?.done==true && speechEndFrame>=0 && presented>=speechEndFrame) {
                    completed++;spoken+=active.cue.key;cache.remove(active.cue.key);stopOutput()
                }
            }
        }
        if(previewActive&&outputStarted)previewPosition+=delta
        // Entire subtitle windows, including pauses. Only cues with prepared speech duck.
        val readyWindows=windows.filter { it.key in prepared }
        val windowGain=NarrationPolicy.duck(position,readyWindows,config.duck,mediaPlaying&&engine>0&&config.volume>0&&!current.muted)
        val target=if(mediaPlaying&&outputStarted&&config.volume>0&&!current.muted)minOf(windowGain,1.0-config.duck) else windowGain
        if(target!=gainTarget) {gainStart=lastGain;gainTarget=target;gainElapsed=0.0}
        gainElapsed+=delta
        val fraction=(gainElapsed/(if(gainTarget<gainStart).15 else .35)).coerceAtMost(1.0)
        val adjusted=gainStart+(gainTarget-gainStart)*fraction
        if(abs(adjusted-lastGain)>.005 || adjusted==target && adjusted!=lastGain) {gain(adjusted);lastGain=adjusted}
        if(outputStarted)state="speaking"
        publish()
    }
    private fun publish() {
        val needsAudio=enabled&&engine>0&&config.volume>0&&state in setOf("ready","speaking")
        if(needsAudio!=soundEligible) {soundEligible=needsAudio;audioChanged()}
        val status=JSONObject().put("state",if(holdsPlayback&&state=="ready")"loading" else state).put("enabled",config.enabled).put("language",language)
            .put("startup_hold",holdsPlayback)
            .put("preview",previewRequested)
            .put("pause_pending",pausingWithVideo)
            .put("model_ready",engine>0).put("generation",epoch).put("cached_seconds",(cache.values.sumOf { it.samples-it.cursor }+(rendered?.let {it.samples-it.cursor} ?: 0))/96000.0)
            .put("completed",completed).put("late_skipped",lateSkipped).put("underruns",underruns+(track?.underrunCount ?: 0))
            .put("original_gain",lastGain).put("audio_timestamp_frames",timestampFrames).put("audio_timestamp_ns",timestampNs)
        status.put("written_frames",writtenTotal).put("last_rtf",lastRtf).put("last_lateness_ms",lastLatenessMs).put("phase_error_ms",phaseErrorMs)
            .put("phase_valid",phaseValid).put("phase_sample_ns",phaseSampleNs).put("phase_media_position",phaseMediaPosition)
            .put("audio_play_started_ns",playStartedNs).put("output_origin_frames",writeOrigin/2)
            .put("clock_kind",playbackClock.kind).put("clock_position_seconds",playbackClock.position).put("clock_observed_ns",playbackClock.observedNs)
            .put("startup_frames",startupFrames).put("playback_head_frames",track?.let { it.playbackHeadPosition.toLong() and 0xffffffffL } ?: 0)
        status.put("synthesis_retries",synthesisRetries).put("synthesis_failures",synthesisFailures)
            .put("last_generation_frames",lastGenerationFrames).put("last_eos",lastEos)
            .put("prepared_start",cache.values.firstOrNull {it.done&&!it.failed}?.cue?.start ?: -1.0)
            .put("output_create_ms",outputCreateMs).put("output_render_ms",outputRenderMs)
            .put("output_start_ms",outputStartMs).put("output_setup_ms",outputSetupMs).put("output_resume_ms",outputResumeMs)
            .put("output_tempo",outputTempo).put("output_raw_seconds",outputRawSeconds).put("output_pcm_seconds",outputPcmSeconds)
            .put("output_cue_start",output?.cue?.start ?: -1.0)
            .put("audio_performance_mode",track?.performanceMode ?: -1)
            .put("output_started",outputStarted).put("output_latency_estimate_ms",outputLatencySeconds*1000)
            .put("max_feed_gap_ms",maxFeedGapMs).put("play_origin_frames",playOriginFrames)
        report=status.toString()
    }
    override fun close() {
        synchronized(lock) {if(closed)return;closed=true;invalidate();unload()}
        clock.shutdownNow();readerWorker.shutdownNow()
    }
    companion object {
        private const val OUTPUT_LEAD_FRAMES = 9600 // 200 ms, within the existing 16k-frame capacity.
        private val synthesis=Executors.newSingleThreadExecutor { Thread(it,"MossSubtitleSynthesis") }
        val TEXT_CODECS=setOf("subrip","ass","ssa","webvtt","mov_text","text","sami","microdvd","subviewer","ttml")
    }
}
