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
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.math.abs

/** One media source, one clock, bounded in-memory PCM. Neither subtitles nor PCM are logged/saved. */
internal class NarrationController(private val context: () -> Context?, private val source: () -> Source?,
                                   private val gain: (Double) -> Unit, private val audioChanged: () -> Unit = {},
                                   private val runtime: SharedNarrationEngine) : AutoCloseable {
    data class Source(val handle: Long, val path: String, val caFile: String, val allowed: Boolean,
                      val volume: Double, val muted: Boolean, val delay: Double, val subtitleCommand: Long,
                      val playRequested: Boolean, val audioDelay: Double = 0.0)
    private class Speech(val cue: NarrationPolicy.Cue, val epoch: Long, val preview: Boolean = false) {
        val chunks = mutableListOf<FloatArray>()
        var samples = 0; var cursor = 0; var done = false; var failed = false; var rtf = 0.0
        var rawSamples=0;var localTempo=1.0
    }
    private val lock = Any()
    private val clock = Executors.newSingleThreadScheduledExecutor { Thread(it, "SubtitleNarrationClock") }
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
    @Volatile private var engineLease: SharedNarrationEngine.Lease?=null
    private val engine get()=engineLease?.handle ?: 0L
    @Volatile private var cloneSuspended=false
    private var loading = false
    private var modelRequest = 0L
    private val previewCache = linkedMapOf<String, List<FloatArray>>()
    @Volatile private var modelPhase = "off"
    @Volatile private var verifiedBytes = 0L
    @Volatile private var modelBytes = 0L
    @Volatile private var verificationMs = 0.0
    @Volatile private var modelLoadMs = 0.0
    private var modelLoadCount = 0
    @Volatile private var synthesisStartedNs = 0L
    @Volatile private var firstChunkMs = 0.0
    private var rejectedForLead = 0
    private var rejectedLate = 0
    private var outputTruncated = 0
    private var missingCues = 0
    private var lastTrimMs = 0.0
    private var precisionRecoveries = 0
    private var lastPrecisionRecovery = false
    private var precisionModelLoaded = false
    private var lastPrecisionLoadMs = 0.0
    private var precisionDurationRetries = 0
    private val outcomes = java.util.ArrayDeque<JSONObject>()
    private var modelFailure = ""
    private var reading = true
    private var readThrough = -1.0
    private var timelineKey = ""
    private var timelineText = NarrationTimeline()
    private var timelineCacheHits = 0
    private var sharedSequence = -1L
    private var sharedReads = 0
    private var sharedAhead = 0.0
    private var sharedReadMs = 0.0
    private var sharedMaxReadMs = 0.0
    private var interrupted = 0
    private var lastMissReason = ""
    private val displayedCues = mutableListOf<NarrationPolicy.Cue>()
    private var displayedReused = 0
    private var sourceKey = ""
    private var runtimeFailed = false
    private var previewPending = false
    private var previewActive = false
    @Volatile private var previewRequested = false
    private var previewPosition = 0.0
    private var reportPosition = 0.0
    private var generationFloor = Double.NaN
    private var lastSeek = -1L
    private var language = ""
    private var windows = emptyList<NarrationPolicy.Cue>()
    private var selectedLineEmpty = false
    private val cache = linkedMapOf<String, Speech>()
    private val spoken = linkedSetOf<String>()
    private val prepared = linkedSetOf<String>()
    private var synthesizing = false
    private var synthesisToken = 1L
    private var generating: Speech? = null
    private var output: Speech? = null
    private var outputStarted = false
    private var playStartedNs = 0L
    private var playOriginFrames = 0L
    private var outputLatencySeconds = 0.0
    private var rendered: NarrationPcm? = null
    private var track: AudioTrack? = null
    private val heardPcm=HeardPcm {pcm,count,ns,gain->LiveCaptureNative.narration(pcm,count,ns,gain)}
    private var captureGain=1f
    private var captureUnderruns=-1
    fun captureFlush()=synchronized(lock){captureHeard()}
    private fun captureSubmitted(pcm: FloatArray,offset: Int,count: Int) {
        if(count<=0)return
        runCatching{heardPcm.write(pcm,offset,count)}.onFailure {
            heardPcm.reset();LiveCaptureNative.audioFailed=true;LiveCaptureNative.recording=false
        }
    }
    private fun captureHeard() {
        // A recorder failure must never become a speech_error or stop playback.
        runCatching { captureHeardOutput() }.onFailure {LiveCaptureNative.audioFailed=true;LiveCaptureNative.recording=false}
    }
    private fun captureHeardOutput() {
        val audio=track ?: return
        if(!outputStarted||outputPaused||audio.playState!=AudioTrack.PLAYSTATE_PLAYING)return
        val count=audio.underrunCount
        if(captureUnderruns>=0&&count!=captureUnderruns)heardPcm.discontinuity()
        captureUnderruns=count
        val now=System.nanoTime();val timestamp=AudioTimestamp()
        if(audio.getTimestamp(timestamp)&&timestamp.nanoTime>=playStartedNs&&kotlin.math.abs(now-timestamp.nanoTime)<250_000_000)
            heardPcm.present(timestamp.framePosition,timestamp.nanoTime,now,captureGain,LiveCaptureNative.recording)
        else heardPcm.present(audio.playbackHeadPosition.toLong() and 0xffffffffL,now,now,captureGain,LiveCaptureNative.recording)
    }
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
    private var outputAdapted = false
    private var renderedFinalized = false
    private var outputRawSeconds = 0.0
    private var outputPcmSeconds = 0.0
    private var rhythmPauseRemovedMs=0.0
    private var rhythmDragRemovedMs=0.0
    private var rhythmBufferSamples=0
    private var levelGainDb=0.0
    private var levelLimitedFrames=0
    val enabled get() = config.enabled && !closed
    val previewVolume get() = config.volume
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
                val cancelPreview=previewRequested
                invalidate(false)
                if(!cancelPreview){previewPending=true;previewRequested=true}
                publish();return true
            }
            val activeSpeech=output
            val voiceOnly=previous.copy(zhVoice=next.zhVoice,enVoice=next.enVoice,jaVoice=next.jaVoice,voiceOverride=next.voiceOverride,duck=next.duck,volume=next.volume)==next
            if (voiceOnly && activeSpeech!=null&&!activeSpeech.preview) {
                cache.clear();cache[activeSpeech.cue.key]=activeSpeech;prepared.clear();prepared+=activeSpeech.cue.key
                return true // Current sentence finishes in its existing voice; future synthesis uses the new one.
            }
            if (previous.copy(duck=next.duck, volume=next.volume) != next) {
                invalidate(); sourceKey=""; modelFailure=""
            }
            if (!next.enabled) { unload(); state="off" }
            else state="loading"
            publish()
        }
        return true
    }
    fun status() = JSONObject(report)
    fun suspendForClone(value: Boolean)=synchronized(lock) {
        if(cloneSuspended==value)return@synchronized
        cloneSuspended=value;invalidate(false)
    }
    fun awaitCloneDrain(){synthesis.submit {}.get(30,TimeUnit.SECONDS)}
    fun diagnosticStatus() = synchronized(lock) {JSONObject(report).put("outcomes",org.json.JSONArray(outcomes.toList()))}
    private fun outcome(speech: Speech, kind: String) = outcome(speech.cue,kind,speech.preview)
    private fun outcome(cue: NarrationPolicy.Cue, kind: String, preview: Boolean=false) {
        if(kind in setOf("late_before_generation","expired_before_output","late_before_output","cannot_fit_deadline","generation_limit","generation_error"))lastMissReason=kind
        outcomes.addLast(JSONObject().put("start",cue.start).put("end",cue.end).put("kind",kind).put("generation",epoch).put("preview",preview)
            .put("position",reportPosition).put("played_frames",if(output?.cue?.key==cue.key&&outputStarted)track?.playbackHeadPosition?.toLong()?.and(0xffffffffL) ?: 0L else 0L))
        while(outcomes.size>512)outcomes.removeFirst()
    }
    fun timelineChanged() = synchronized(lock) { if(config.source<0) {invalidate();sourceKey=""} }
    fun transportChanged() = synchronized(lock) {invalidate();sourceKey="";nextPoll=0}
    fun subtitleReplaced(oldId: Int, newId: Int) = synchronized(lock) {
        if (config.source >= 0 && config.source != oldId) return@synchronized
        if (config.source == oldId) config = config.copy(source = newId)
        invalidate(); sourceKey = ""; timelineKey = ""; nextPoll = 0
    }
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
        captureHeard()
        phaseValid=false
        if(outputPaused)return
        track?.let { audio ->
            // pause() preserves unplayed samples and the frame counter. Flushing
            // here loses the presentation pipeline and requires guessing a rewind.
            runCatching { audio.pause() }
        }
        heardPcm.discontinuity()
        timestampFrames=0;timestampNs=0;lastFeedNs=0
        outputPaused=true
    }
    private fun stopOutput() {
        pauseOutput(); track?.let { audio -> underruns += runCatching { audio.underrunCount }.getOrDefault(0); runCatching { audio.release() } }
        rendered?.close();rendered=null
        heardPcm.reset()
        captureUnderruns=-1
        track=null; output=null;written=0;speechEndFrame=-1;writeOrigin=0;outputPaused=false;outputStarted=false;playStartedNs=0;playOriginFrames=0;lastFeedNs=0
    }
    private fun invalidate(allowHold: Boolean = true) {
        val hadAudio=soundEligible||previewRequested||pausingWithVideo||startupHold
        soundEligible=false;previewRequested=false;pausingWithVideo=false
        // Hold the requested transport until a fresh clock decides whether this
        // is the beginning of the video. Mid-video changes release immediately.
        startupHold=allowHold&&enabled&&config.volume>0;startupDecisionPending=startupHold
        startupDeadlineNs=if(startupHold)System.nanoTime()+15_000_000_000 else 0
        if(hadAudio||startupHold)audioChanged()
        ++epoch
        generationFloor=Double.NaN
        ++synthesisToken
        engineLease?.cancel()
        reading=true;readThrough=-1.0;sharedSequence=-1;sharedAhead=0.0
        windows=emptyList();displayedCues.clear();selectedLineEmpty=false;cache.clear();spoken.clear();prepared.clear();runtimeFailed=false;missingCues=0;lastMissReason=""
        previewPending=false;previewActive=false;previewPosition=0.0
        maxFeedGapMs=0.0
        stopOutput();restoreGain()
    }
    private fun releaseStartupHold() {
        startupDecisionPending=false;startupDeadlineNs=0
        if(startupHold) {startupHold=false;audioChanged()}
    }
    private fun unload() {
        val old=engineLease;engineLease=null
        ++modelRequest;loading=false;modelPhase="off";previewCache.clear();precisionModelLoaded=false;lastPrecisionRecovery=false;lastPrecisionLoadMs=0.0
        if (old != null) synthesis.execute {old.close()}
    }
    private fun prepareModel() {
        if (loading || engine > 0 || modelFailure.isNotEmpty()) return
        loading=true;modelPhase="verifying";verifiedBytes=0;val token=modelRequest
        synthesis.execute {
            Process.setThreadPriority(5)
            var loaded: SharedNarrationEngine.Lease?=null;var failure="model_error"
            try {
                val verifyingStarted=System.nanoTime()
                var loadingStarted=verifyingStarted
                val active={ synchronized(lock){!closed && token==modelRequest && config.enabled && !cloneSuspended} }
                val progress: (String,Long,Long)->Unit={phase,bytes,total->
                    modelPhase=phase;verifiedBytes=bytes;modelBytes=total
                    if(phase=="loading"){verificationMs=(System.nanoTime()-verifyingStarted)/1e6;loadingStarted=System.nanoTime()}
                }
                loaded=engineLease?.also {it.ensure(active,progress)} ?: runtime.acquire(active,progress)
                modelLoadMs=(System.nanoTime()-loadingStarted)/1e6
            } catch (_: LinkageError) { /* Missing/incompatible runtime is a recoverable model error. */
            } catch (_: Exception) { /* Deliberately no URI, subtitle text or model exception in logs. */ }
            synchronized(lock) {
                if (closed || token!=modelRequest || !config.enabled || cloneSuspended) {
                    if(loaded!=null&&loaded!==engineLease){val unused=loaded;synthesis.execute {unused?.close()}}
                    if(token==modelRequest)loading=false
                    return@synchronized
                }
                loading=false
                engineLease=loaded;modelFailure=if(loaded==null)failure else ""
                if(loaded!=null)modelLoadCount++
                modelPhase=if(loaded!=null)"ready" else "error"
            }
        }
    }
    private fun ensureTimeline(path: String, index: Int) {
        val key="$index:$path"
        if(key!=timelineKey) {
            if(timelineKey.isNotEmpty())invalidate(false)
            timelineKey=key;timelineText=NarrationTimeline();timelineCacheHits=0;displayedReused=0
        }
    }
    private fun sharedTimeline(snapshot: JSONObject, position: Double, selected: Int, lang: String, delay: Double, command: Long) {
        if(snapshot.optLong("sequence",-1)==sharedSequence)return
        val raw=NarrationTimeline.shared(snapshot,selected,outer.optLong("epoch_floor"),command,System.nanoTime()) ?: return
        sharedSequence=snapshot.getLong("sequence");sharedReads++;reading=false
        sharedAhead=snapshot.optDouble("ahead_seconds",0.0)
        sharedReadMs=snapshot.optDouble("read_us",0.0)/1000;sharedMaxReadMs=maxOf(sharedMaxReadMs,sharedReadMs)
        val before=timelineText.size
        val stored=timelineText.remember(raw)
        if(before==timelineText.size)timelineCacheHits++
        selectTimeline(if(stored)timelineText.window(maxOf(0.0,position-delay-8),position-delay+45) else raw,lang,delay)
        readThrough=position+sharedAhead
    }
    private fun selectTimeline(raw: org.json.JSONArray, lang: String, delay: Double) {
        val selected=NarrationPolicy.cues(raw,lang,config.line)
        selectedLineEmpty=config.line>0&&selected.isEmpty()&&NarrationPolicy.cues(raw,lang).isNotEmpty()
        val prefetched=selected.map {it.copy(start=it.start+delay,end=it.end+delay,windowStart=it.windowStart+delay,windowEnd=it.windowEnd+delay)}
        val merged=NarrationPolicy.mergeDisplayed(prefetched,displayedCues)
        windows=merged.first;spoken.addAll(merged.second)
        if(windows.isNotEmpty())selectedLineEmpty=false
        if(selectedLineEmpty)releaseStartupHold()
    }
    private fun reuseDisplayed(snapshot: JSONObject, position: Double, selected: Int, lang: String, delay: Double) {
        displayedCues.removeAll {it.windowEnd+config.deadlineSlack<position}
        if(windows.any {position>=it.windowStart && position<it.windowEnd})return
        val raw=NarrationTimeline.visible(snapshot,position,delay,selected)
        if(raw.length()==0)return
        val current=NarrationPolicy.cues(raw,lang,config.line).map {
            it.copy(start=it.start+delay,end=it.end+delay,windowStart=it.windowStart+delay,windowEnd=it.windowEnd+delay)
        }
        if(current.isEmpty()) {selectedLineEmpty=config.line>0;if(selectedLineEmpty)releaseStartupHold();return}
        timelineText.remember(raw);displayedReused++
        displayedCues.addAll(current)
        val merged=NarrationPolicy.mergeDisplayed(windows,displayedCues)
        windows=merged.first;spoken.addAll(merged.second);selectedLineEmpty=false
    }
    private fun generate(position: Double, advancing: Boolean) {
        if(synthesizing||engine==0L||cache.values.sumOf { it.samples }>48000*2*36)return
        val slack=if(previewActive).4 else config.deadlineSlack
        val offset=if(previewActive)0.0 else config.offset
        val cue=windows.firstOrNull { NarrationPolicy.afterSeek(it,generationFloor,offset) && (if(config.timing=="interrupt")NarrationPolicy.speechDeadline(it,windows) else it.end+slack)+offset>position && it.start<=position+35 && (config.timing=="interrupt"||advancing||it.start+offset>=position-slack) && it.key !in spoken && it.key !in cache } ?: return
        if(!previewActive && config.timing!="interrupt" && cue.start+offset<position-slack) {
            rejectedLate++
            spoken+=cue.key;lateSkipped++;missingCues++;outcome(cue,"late_before_generation");return
        }
        val speech=Speech(cue,epoch,previewActive);cache[cue.key]=speech;val model=engineLease ?: return;val token=epoch
        val speechLanguage=language;val voice=config.voice(speechLanguage)
        synthesizing=true;generating=speech
        val nativeToken=++synthesisToken
        model.cancel()
        synthesisStartedNs=System.nanoTime();firstChunkMs=0.0
        synthesis.execute {
            // Reuse comic readings off the clock/lock; a dictionary failure must
            // take the normal generation-error path rather than strand the queue.
            val text=runCatching {SubtitleNarrationText.prepare(cue.text,speechLanguage)}.getOrNull()
            var result: JSONObject?=null
            for(attempt in 0..1) {
              if(text==null)break
              lateinit var rhythm: NarrationRhythm
              val level=NarrationLevel {chunk->synchronized(lock){
                  check(!closed&&token==epoch&&cache[cue.key]===speech){"voice_cancelled"}
                  check(cache.values.sumOf {it.samples}+chunk.size<=48000*2*56)
                  speech.localTempo=rhythm.tempoCeiling
                  speech.chunks+=chunk;speech.samples+=chunk.size
                  if(speech.preview||config.timing=="interrupt")prepared+=cue.key
              }}
              rhythm=NarrationRhythm(text,speechLanguage){level.append(it)}
              synchronized(lock){speech.localTempo=rhythm.tempoCeiling}
              try {
                val frames=NarrationPolicy.generationFrameBudget(text,speechLanguage,cue.end-cue.start,if(attempt==0)48 else 64)
                result=JSONObject(runtime.synthesize(model,text,voice,nativeToken,frames,attempt>0,
                    active={ synchronized(lock){!closed && token==epoch && synthesisToken==nativeToken && !cloneSuspended} },
                    codes={NarrationAssets.voices(context() ?: error("Unavailable")).load(voice)},sink=object: NarrationNative.Sink {
                    override fun onChunk(epoch: Long, pcm: FloatArray): Boolean {
                        val active=synchronized(lock){
                            if(closed||this@NarrationController.epoch!=token||synthesisToken!=epoch||cache[cue.key]!==speech)false
                            else {if(speech.rawSamples==0)firstChunkMs=(System.nanoTime()-synthesisStartedNs)/1e6;speech.rawSamples+=pcm.size;true}}
                        if(!active)return false
                        rhythm.append(pcm)
                        return synchronized(lock){!closed&&this@NarrationController.epoch==token&&synthesisToken==epoch}
                    }
                }))
                if(result?.optBoolean("eos")==true&&!result!!.optBoolean("cancelled")){rhythm.finish();level.finish()}
                synchronized(lock){if(token==epoch&&cache[cue.key]===speech){
                    speech.localTempo=rhythm.tempoCeiling;rhythmPauseRemovedMs=rhythm.stats.removedPauseSamples/96.0
                    rhythmDragRemovedMs=rhythm.stats.removedDragSamples/96.0;rhythmBufferSamples=rhythm.stats.maxBufferedSamples
                    levelGainDb=level.stats.gainDb;levelLimitedFrames=level.stats.limitedFrames}}
              } catch (_: LinkageError) { result=null
              } catch (_: Exception) { result=null }
              finally {rhythm.close();level.close()}
              val success=result?.let {it.optBoolean("eos")&&!it.optBoolean("cancelled")&&it.optDouble("audio_seconds",0.0)>0} ?: false
              val fits=speech.preview||config.timing!="continuous"||NarrationPolicy.canFinish(speech.samples/96000.0,cue.end-cue.start,0.0,1.0,config.deadlineSlack)
              if((success&&fits)||attempt==1||synchronized(lock){output===speech&&outputStarted&&!speech.preview})break
              synchronized(lock) {
                  if(closed||token!=epoch||cache[cue.key]!==speech){synthesizing=false;if(generating===speech)generating=null;return@execute}
                  if(output===speech) {stopOutput();if(previewActive)previewPosition=0.0}
                  speech.chunks.clear();speech.samples=0;speech.rawSamples=0;speech.localTempo=1.0;speech.cursor=0;prepared.remove(cue.key);synthesisRetries++;precisionRecoveries++;if(success&&!fits)precisionDurationRetries++
              }
            }
            val complete=result?.let {it.optBoolean("eos")&&!it.optBoolean("cancelled")} ?: false
            val original=synchronized(lock) {if(complete&&!speech.preview&&token==epoch&&cache[cue.key]===speech&&output!==speech)speech.chunks.toList() else null}
            val trimming=original?.let {runCatching {NarrationPcm.trimOuterSilence(it)}}
            val trimmed=trimming?.getOrNull()
            synchronized(lock) {
                synthesizing=false
                if(generating===speech)generating=null
                if(closed||token!=epoch||cache[cue.key]!==speech)return@synchronized
                speech.done=true;speech.failed=result==null||result.optBoolean("cancelled")||!result.optBoolean("eos")||result.optDouble("audio_seconds",0.0)<=0||trimming?.isFailure==true
                if(trimmed!=null) {
                    val before=speech.samples;speech.chunks.clear();speech.chunks.addAll(trimmed);speech.samples=trimmed.sumOf {it.size}
                    lastTrimMs=(before-speech.samples)/96.0
                }
                speech.rtf=result?.let { it.optDouble("wall_seconds")/it.optDouble("audio_seconds") } ?: 0.0
                if(speech.rtf.isFinite())lastRtf=speech.rtf
                lastGenerationFrames=result?.let {kotlin.math.round(it.optDouble("audio_seconds",0.0)/.08).toInt()} ?: 0
                lastEos=result?.optBoolean("eos") ?: false
                lastPrecisionRecovery=result?.optBoolean("precision_recovery") ?: false
                precisionModelLoaded=result?.optBoolean("precision_model_loaded") ?: precisionModelLoaded
                lastPrecisionLoadMs=(result?.optDouble("precision_load_seconds",0.0) ?: 0.0)*1000
                if(speech.failed) {
                    if(output===speech){stopOutput();restoreGain()}
                    cache.remove(cue.key);spoken+=cue.key;prepared.remove(cue.key);synthesisFailures++;missingCues++
                    outcome(speech,if(result?.optBoolean("eos")==false)"generation_limit" else "generation_error")
                } else {
                    prepared+=cue.key
                    if(speech.preview&&speech.samples<=96000*8) {
                        previewCache["$speechLanguage:$voice"]=speech.chunks.toList()
                        while(previewCache.values.sumOf {chunks->chunks.sumOf {it.size}}>2_097_152)previewCache.remove(previewCache.keys.first())
                    }
                }
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
        val duration=if(speech.done||speech.preview)speech.samples/96000.0 else speech.cue.end-speech.cue.start
        val planned=if(speech.preview)1.0 else if(config.timing=="interrupt")
            if(speech.done)NarrationPolicy.plannedTempo(speechBudgets(speech,duration,config.offset),maxOf(reportPosition,speech.cue.start+config.offset),speed,0.0,speed)
            else NarrationPolicy.fittedTempo(0.0,Double.POSITIVE_INFINITY,speed)
            else (speed*NarrationPolicy.playbackRate(duration,speech.cue.end-speech.cue.start,lastLatenessMs/1000,1.0)).coerceAtMost(NarrationPolicy.MAX_ADAPTIVE_RATE)
        val tempo=NarrationRhythm.presentationTempo(planned,speech.localTempo)
        rendered=NarrationPcm(tempo).also {it.update(speech.chunks,speech.done);speech.cursor=speech.samples}
        outputAdapted=speech.done||speech.preview;renderedFinalized=false
        outputTempo=tempo;outputRawSeconds=if(speech.rawSamples>0)speech.rawSamples/96000.0 else duration;outputPcmSeconds=rendered!!.samples/96000.0
        outputRenderMs=(System.nanoTime()-created)/1e6
        captureGain=if(current.muted)0f else (current.volume/100*config.volume).toFloat()
        audio.setVolume(captureGain)
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
            captureSubmitted(silence,0,count)
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
        if(!renderedFinalized)pcm.update(speech.chunks,speech.done)
        speech.cursor=speech.samples
        val played=audio.playbackHeadPosition.toLong() and 0xffffffffL
        var budget=(leadFrames-(written-played)).coerceAtLeast(0).toInt()*2
        var skip=pcm.cursor
        for(chunk in pcm.chunks) {
            if(skip>=chunk.size) {skip-=chunk.size;continue}
            if(budget<=0)break
            val count=minOf(chunk.size-skip,budget)
            val result=audio.write(chunk,skip,count,AudioTrack.WRITE_NON_BLOCKING)
            captureSubmitted(chunk,skip,result)
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
                captureSubmitted(tailSilence,0,count)
                check(count>=0);written+=count/2;writtenTotal+=count/2
            }
        }
        val timestamp=AudioTimestamp()
        if(audio.getTimestamp(timestamp)) {timestampFrames=timestamp.framePosition;timestampNs=timestamp.nanoTime}
    }
    private fun fitCompletedTail(speech: Speech, audio: AudioTrack, position: Double, speed: Double, offset: Double) {
        if(outputAdapted||!speech.done||speech.failed||speech.preview||config.timing!="interrupt")return
        outputAdapted=true
        val pcm=rendered ?: return
        pcm.update(speech.chunks,true)
        outputRawSeconds=if(speech.rawSamples>0)speech.rawSamples/96000.0 else speech.samples/96000.0
        val played=audio.playbackHeadPosition.toLong() and 0xffffffffL
        val queued=(written-played).coerceAtLeast(0)/48000.0
        val tempo=NarrationRhythm.presentationTempo(minOf(NarrationPolicy.plannedTempo(speechBudgets(speech,(pcm.samples-pcm.cursor)/96000.0*outputTempo,offset),
            maxOf(position,speech.cue.start+offset),speed,queued+outputLatencySeconds,outputTempo),outputTempo*3.9),speech.localTempo)
        if(tempo<=outputTempo+.01)return
        val faster=NarrationPcm(tempo/outputTempo)
        faster.update(pcm.remaining(),true)
        pcm.close();rendered=faster;renderedFinalized=true
        outputTempo=tempo;outputPcmSeconds=written/48000.0+faster.samples/96000.0
    }
    private fun speechBudgets(speech: Speech, remainingRaw: Double, offset: Double): List<NarrationPolicy.SpeechBudget> {
        val pending=listOf(speech.cue)+windows.filter {it.key!=speech.cue.key&&it.start>=speech.cue.start-.001&&it.key !in spoken}
        val groups=pending.map {it.windowStart}.distinct().take(4).toSet()
        return pending.filter {it.windowStart in groups}.map {cue ->
            val stored=cache[cue.key]
            // Complete future PCM gives its exact duration. Until then use a
            // conservative text estimate solely for planning, never as an EOS.
            val seconds=if(cue.key==speech.cue.key)remainingRaw else if(stored?.done==true&&!stored.failed)stored.samples/96000.0
                else maxOf((stored?.samples ?: 0)/96000.0,.4+(if(language in setOf("zh","ja"))cue.text.count {it.isLetterOrDigit()}*.30 else Regex("[\\p{L}\\p{N}]+").findAll(cue.text).count()*.42))
            NarrationPolicy.SpeechBudget(seconds,NarrationPolicy.interruptBoundary(cue,windows)+offset+NarrationPolicy.TARGET_BORROW_SECONDS)
        }
    }
    private fun tick() = synchronized(lock) {
        if(closed)return@synchronized
        phaseValid=false
        val now=System.nanoTime();val delta=((now-lastTick)/1e9).coerceIn(0.0,.1);lastTick=now
        val current=source()
        if(!config.enabled||cloneSuspended||current==null||current.handle<=0) {state="off";restoreGain();releaseStartupHold();publish();return@synchronized}
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
        val identity="$selected:$lang:$delay:${config.line}"
        val seek=outer.optLong("seeks_started")
        if(identity!=sourceKey || seek!=lastSeek) {
            invalidate();sourceKey=identity;lastSeek=seek;language=lang
        }
        playbackClock=NarrationPolicy.playbackClock(observation.put("user_audio_delay_seconds",current.audioDelay))
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
        if(!preview&&clockValid&&!generationFloor.isFinite())generationFloor=mediaPosition
        val readable=metadata!=null&&metadata.optString("codec") in TEXT_CODECS
        val reuseAvailable=readable&&subtitle.optString("track_id").toIntOrNull()==selected
        if(!preview&&readable&&clockValid)ensureTimeline(path,index)
        if(lang.isNotEmpty() && (readable||preview))prepareModel()
        state=when {
            metadata==null&&!preview->"subtitle_required"
            lang.isEmpty()->"language_required"
            !preview&&!readable->"unsupported_subtitle"
            modelFailure.isNotEmpty()->modelFailure
            runtimeFailed->"speech_error"
            engine==0L->"loading"
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
        // Text extraction is independent of ONNX model loading/speech generation.
        if(!preview&&readable&&clockValid&&lang.isNotEmpty()) {
            sharedTimeline(outer.optJSONObject("subtitle_queue") ?: JSONObject(),mediaPosition,selected,lang,delay,current.subtitleCommand)
            if(reuseAvailable)reuseDisplayed(subtitle,mediaPosition,selected,lang,delay)
        }
        if(state=="ready") {
            if(previewPending) {
                val text=if(PersonalVoiceStore.isVoice(config.voice(lang)))VoiceClonePreviewText.text(lang) else NarrationPolicy.previewText(lang)
                // Audition the voice on its own clock, including when the video is paused.
                // The clock starts with output, so model preparation cannot expire the sample.
                windows=listOf(NarrationPolicy.Cue(0.0,NarrationPolicy.PREVIEW_WINDOW_SECONDS,text));previewPending=false;previewActive=true
                previewPosition=0.0;position=0.0
                previewCache["$lang:${config.voice(lang)}"]?.let { saved ->
                    val speech=Speech(windows.first(),epoch,true)
                    speech.chunks.addAll(saved);speech.samples=saved.sumOf {it.size};speech.done=true
                    cache[speech.cue.key]=speech;prepared+=speech.cue.key
                }
            }
            generate(position,mediaPlaying)
        }
        reportPosition=position
        val slack=if(previewActive).4 else config.deadlineSlack
        val effectiveOffset=if(previewActive)0.0 else config.offset
        val expired=cache.values.filter { speech ->
            val boundary=if(config.timing=="interrupt"&&!previewActive) NarrationPolicy.speechDeadline(speech.cue,windows) else speech.cue.end+slack
            boundary+effectiveOffset<=position
        }
        for(speech in expired) {
            if(generating===speech) {
                ++synthesisToken
                if(engine>0)NarrationNative.cancel(engine,synthesisToken)
            }
            if(output===speech){
                if(config.timing=="interrupt"&&outputStarted){interrupted++;outcome(speech,"interrupted_at_boundary")}
                else {outputTruncated++;missingCues++;outcome(speech,"output_truncated")}
                stopOutput()
            }
            else {lateSkipped++;missingCues++;outcome(speech,"expired_before_output")}
            cache.remove(speech.cue.key);spoken+=speech.cue.key
        }
        if(previewActive && windows.isNotEmpty() && (windows.first().key in spoken || position>windows.first().end+.4)) {
            invalidate(false);publish();return@synchronized
        }
        while(spoken.size>256)spoken.remove(spoken.first())
        val playing=if(previewActive)current.allowed&&!suspended else mediaPlaying&&(current.playRequested||pausingWithVideo)
        val offset=if(previewActive)0.0 else config.offset
        val outputSpeed=if(previewActive)1.0 else speed
        var active=output
        if(active==null&&state=="ready") {
            val warmup=if(previewActive)0.0 else .5
            active=cache.values.firstOrNull { !it.failed&&(it.done||((previewActive||config.timing=="interrupt")&&
                NarrationPolicy.streamingReady(it.samples,1.0,NarrationPolicy.speechDeadline(it.cue,windows)+offset-position,!previewActive&&config.timing=="interrupt")))&&position+warmup>=it.cue.start+offset&&
                position<(if(config.timing=="interrupt"&&!previewActive)NarrationPolicy.speechDeadline(it.cue,windows) else it.cue.end+slack)+offset }
            if(active!=null) {
                val lateness=maxOf(0.0,position-active.cue.start-offset)
                val fits=previewActive||NarrationPolicy.canFinish(active.samples/96000.0,active.cue.end-active.cue.start,lateness,1.0,slack)
                if(!previewActive&&config.timing!="interrupt"&&(position>active.cue.start+offset+slack||!fits)) {spoken+=active.cue.key;cache.remove(active.cue.key);prepared.remove(active.cue.key);lateSkipped++;rejectedLate++;missingCues++;outcome(active,if(fits)"late_before_output" else "cannot_fit_deadline");active=null}
                else {lastLatenessMs=maxOf(0.0,position-active.cue.start-offset)*1000;begin(active,current,outputSpeed)}
            }
        }
        if(holdsPlayback&&state=="ready"&&!startupDecisionPending) {
            val first=windows.firstOrNull {it.end>position&&it.start+offset>=position-.4&&it.start+offset<=position+5&&it.key !in spoken}
            val buffered=cache.values.filter {it.done&&!it.failed}.sumOf {it.samples}/96000.0
            val nearby=windows.filter {it.end>position&&it.start+offset>=position-.4&&it.start<=position+12&&it.key !in spoken}
            val complete=nearby.isNotEmpty()&&nearby.all {cache[it.key]?.done==true}
            if(!reading&&readThrough>=0&&(first==null||cache[first.key]?.done==true&&(buffered>=16.0||complete)))releaseStartupHold()
        }
        if(!playing || state!="ready") {pauseOutput();restoreGain();publish();return@synchronized}
        if(active!=null) {
            val audio=track
            if(audio!=null) {
                fitCompletedTail(active,audio,position,outputSpeed,offset)
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
                val fade=if(config.timing=="interrupt"&&!active.preview)((NarrationPolicy.speechDeadline(active.cue,windows)+offset-position)/.05).coerceIn(0.0,1.0) else 1.0
                captureHeard()
                captureGain=if(current.muted)0f else (current.volume/100*config.volume*fade).toFloat()
                audio.setVolume(captureGain)
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
                    completed++;outcome(active,"completed");spoken+=active.cue.key;cache.remove(active.cue.key);stopOutput()
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
        val status=JSONObject().put("state",if(holdsPlayback&&state=="ready")"loading" else if(state=="ready"&&selectedLineEmpty&&!previewRequested)"line_missing" else state).put("enabled",config.enabled).put("language",language)
            .put("voice",config.voice(language)).put("line",config.line)
            .put("startup_hold",holdsPlayback)
            .put("model_phase",modelPhase).put("model_verified_bytes",verifiedBytes).put("model_bytes",modelBytes)
            .put("model_verification_ms",verificationMs).put("model_load_ms",modelLoadMs)
            .put("model_load_count",modelLoadCount)
            .put("shared_model",runtime.stats())
            .put("timeline_reading",reading).put("timeline_cues",windows.size).put("timeline_read_through",readThrough)
            .put("timeline_cached_cues",timelineText.size).put("timeline_cache_hits",timelineCacheHits)
            .put("timeline_index_mode","mpv_shared_queue").put("timeline_shared_reads",sharedReads).put("timeline_shared_ahead",sharedAhead).put("timeline_shared_read_ms",sharedReadMs).put("timeline_shared_max_read_ms",sharedMaxReadMs)
            .put("timeline_displayed_reused",displayedReused).put("timeline_prefetch_failed",false)
            .put("timeline_indexing",false).put("timeline_complete",timelineText.complete).put("timeline_index_fraction",timelineText.fraction)
            .put("timeline_cache_limited",timelineText.limited).put("timeline_error_code","").put("timeline_read_ms",sharedReadMs)
            .put("synthesizing",synthesizing).put("first_chunk_ms",firstChunkMs)
            .put("rejected_preparation_lead",rejectedForLead).put("rejected_late",rejectedLate)
            .put("output_truncated",outputTruncated)
            .put("interrupted",interrupted).put("last_miss_reason",lastMissReason).put("missing_cues",missingCues).put("last_trim_ms",lastTrimMs)
            .put("timing",config.timing).put("output_delay_seconds",if(outputStarted&&!previewActive)lastLatenessMs/1000 else 0.0)
            .put("buffered_seconds",cache.values.filter {it.done&&!it.failed}.sumOf {it.samples}/96000.0).put("buffer_goal_seconds",16.0)
            .put("precision_recoveries",precisionRecoveries).put("precision_duration_retries",precisionDurationRetries).put("last_precision_recovery",lastPrecisionRecovery).put("precision_model_loaded",precisionModelLoaded).put("last_precision_load_ms",lastPrecisionLoadMs)
            .put("preview",previewRequested).put("preview_request",config.preview)
            .put("preview_progress",if(previewRequested&&output?.preview==true&&rendered?.done==true&&rendered!!.samples>0)
                ((track?.playbackHeadPosition?.toLong()?.and(0xffffffffL) ?: 0L)*200/rendered!!.samples).coerceIn(0,99) else -1)
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
            .put("rhythm_pause_removed_ms",rhythmPauseRemovedMs).put("rhythm_drag_removed_ms",rhythmDragRemovedMs)
            .put("rhythm_buffer_samples",rhythmBufferSamples).put("rhythm_local_tempo",output?.localTempo ?: 1.0)
            .put("level_gain_db",levelGainDb).put("level_limited_frames",levelLimitedFrames)
            .put("output_cue_start",output?.cue?.start ?: -1.0)
            .put("audio_performance_mode",track?.performanceMode ?: -1)
            .put("output_started",outputStarted).put("output_latency_estimate_ms",outputLatencySeconds*1000)
            .put("max_feed_gap_ms",maxFeedGapMs).put("play_origin_frames",playOriginFrames)
        report=status.toString()
    }
    override fun close() {
        synchronized(lock) {if(closed)return;closed=true;invalidate();unload();timelineText=NarrationTimeline();timelineKey=""}
        clock.shutdownNow()
    }
    companion object {
        private const val OUTPUT_LEAD_FRAMES = 9600 // 200 ms, within the existing 16k-frame capacity.
        private val synthesis=Executors.newSingleThreadExecutor { Thread(it,"MossSubtitleSynthesis") }
        val TEXT_CODECS=setOf("subrip","ass","ssa","webvtt","mov_text","text","sami","microdvd","subviewer","ttml")
    }
}
