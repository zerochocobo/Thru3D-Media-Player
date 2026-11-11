package org.vrpassthroughplayer.plugin

import android.graphics.SurfaceTexture
import android.media.*
import android.opengl.GLES11Ext
import android.opengl.GLES30
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.Surface
import org.json.JSONObject
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicBoolean

/** One independent mirror decoder. Godot owns the OES texture; SurfaceTexture stays on its GL thread. */
internal class AirplayMirror(private val render: (Runnable) -> Unit, private val captions: AirplayCaptions) {
    private val thread = HandlerThread("Thru3D-Airplay-Mirror").apply { start() }
    private val worker = Handler(thread.looper)
    private val packets = AirplayPackets()
    private val lock = Any()
    private val pending = AtomicBoolean(false)
    private val scheduled = AtomicBoolean(false)
    private val attaching = AtomicBoolean(false)
    private val videoResetPending = AtomicBoolean(false)
    private val audioResetPending = AtomicBoolean(false)
    private val displayGeneration = java.util.concurrent.atomic.AtomicLong()
    private val receivedVideo = java.util.concurrent.atomic.AtomicLong()
    private val receivedAudio = java.util.concurrent.atomic.AtomicLong()
    private var nextDiagnosticMs = 0L
    @Volatile var epoch = 0L; private set
    @Volatile var width = 1280; private set
    @Volatile var height = 720; private set
    @Volatile var error = ""; private set
    @Volatile var audioError = ""; private set
    @Volatile var muted = false
        set(value) {
            field = value
            worker.post { runCatching { if (value) { audioOutput = -1; audioBuffer = null; waitingAudio = null; track?.pause(); track?.flush(); audio?.flush() } else { audioError = ""; track?.play() } }.onFailure { failAudio(it) } }
        }
    private var texture: SurfaceTexture? = null
    private var surface: Surface? = null
    private var direct = false
    private var layerSlot = 0
    private var surfaceWidth = 0
    private var surfaceHeight = 0
    private var video: MediaCodec? = null
    @Volatile private var videoConfig = ByteArray(0)
    private var audio: MediaCodec? = null
    private var track: AudioTrack? = null
    private var audioCodec = 8
    private var samples = 480
    private var sampleRate = 44100
    private var audioChannels = 2
    private var pcmPacket: AirplayPackets.Packet? = null
    private var pcmBuffer: ByteBuffer? = null
    @Volatile private var sourceName = "AirPlay"
    private var baseNs = 0L
    private var wallNs = 0L
    private var frames = 0L
    private var submittedFrames = 0L
    private var videoInputs = 0L
    private var revision = 0L
    private var decodedWidth = 0
    private var decodedHeight = 0
    private var outputWidth = 0
    private var outputHeight = 0
    private val released = java.util.ArrayDeque<Long>()
    private var matrix = FloatArray(16).also { android.opengl.Matrix.setIdentityM(it, 0) }
    private var waitingVideo: AirplayPackets.Packet? = null
    private var waitingAudio: AirplayPackets.Packet? = null
    private var audioBytes = 0L
    private var audioOutput = -1
    private var audioBuffer: ByteBuffer? = null
    private var audioDueNs = 0L
    private var decodedAudioRate = 0
    private var decodedAudioChannels = 0
    private val info = MediaCodec.BufferInfo()
    @Volatile private var attached = false
    @Volatile private var suspended = false
    @Volatile private var playerPipe: AirplayPlayerPipe? = null
    private var playerMux: AirplayMatroska? = null
    fun playerActive(): Boolean = playerPipe?.closed == false
    fun claimPlayer(): android.os.ParcelFileDescriptor? = playerPipe?.claim()
    fun openPlayer(id: Long): Boolean {
        if (id != epoch || id <= 0 || attached || attaching.get() || playerPipe != null || !packets.videoReady()) return false
        val pipe = AirplayPlayerPipe()
        playerPipe = pipe
        worker.post {
            if (epoch != id || playerPipe !== pipe) { pipe.close(); return@post }
            resumePackets()
            playerMux = null // A rotation may invalidate the retained GOP before this worker runs.
            error = ""; worker.removeCallbacks(pump); worker.post(pump)
        }
        return true
    }
    private val pump = object : Runnable {
        override fun run() {
            if (!attached && !playerActive()) return
            val runningEpoch = epoch
            runCatching {
                for (attempt in 0 until 8) {
                    val p = waitingVideo ?: packets.take(true) ?: break
                    if (baseNs == 0L) { baseNs = p.ns; wallNs = System.nanoTime() + 100_000_000 }
                    if (!feedVideo(p)) { waitingVideo = p; break }
                    waitingVideo = null
                }
                drainVideo()
            }.onFailure { if (epoch == runningEpoch) error = "$sourceName decoder unavailable"; Log.w("Thru3D-Airplay", "Video decoder failed: ${it.javaClass.simpleName}"); playerPipe?.close(); stopCodecs() }
            if (error.isEmpty()) runCatching {
                for (attempt in 0 until 8) {
                    val p = waitingAudio ?: packets.take(false) ?: break
                    if (!feedAudio(p)) { waitingAudio = p; break }
                    waitingAudio = null
                }
                drainAudio()
                playerMux?.let { playerPipe?.offer(it.silence(baseNs + (System.nanoTime() - wallNs).coerceAtLeast(0))) }
            }.onFailure { failAudio(it) }
            if ((attached || playerActive()) && error.isEmpty()) worker.postDelayed(this, 5)
        }
    }
    fun begin(id: Long, paused: Boolean = false, source: String = "AirPlay") { sourceName = source; epoch = id; packets.clear(); error = ""; audioError = ""; audioBytes = 0; receivedVideo.set(0); receivedAudio.set(0); nextDiagnosticMs = 0; suspended = paused; if (paused) packets.park() }
    fun size(w: Int, h: Int) {
        if (w !in 16..1920 || h !in 16..1920) return
        synchronized(lock) { width = w; height = h }
    }
    fun audioFormat(codec: Int, spf: Int, rate: Int = 44100, channels: Int = 2) {
        if (codec !in listOf(0, 4, 8) || spf !in listOf(480, 512, 960, 1024) || rate !in listOf(44100, 48000) || channels !in 1..2 || (codec == 8 && (rate != 44100 || channels != 2))) return
        worker.post { if (codec != audioCodec || spf != samples || rate != sampleRate || channels != audioChannels) stopAudio(); audioCodec = codec; samples = spf; sampleRate = rate; audioChannels = channels; audioError = ""; Log.i("Thru3D-Airplay", "Audio format codec=$codec samples=$spf rate=$rate channels=$channels") }
    }
    fun packet(video: Boolean, bytes: ByteArray, ns: Long, codec: Int) {
        if (epoch <= 0) return
        (if (video) receivedVideo else receivedAudio).incrementAndGet()
        if (ns <= 0 || bytes.size > 2*1024*1024) return
        packets.offer(AirplayPackets.Packet(video, bytes, ns, codec))
    }
    fun discontinuity(video: Boolean) {
        packets.discontinuity(video)
        val pending = if (video) videoResetPending else audioResetPending
        if (pending.compareAndSet(false, true)) worker.post {
            try { if (video) { waitingVideo = null; stopVideo() } else stopAudio() }
            finally { pending.set(false) }
        }
    }
    fun attach(id: Long, textureId: Int): Boolean {
        if (id <= 0 || id != epoch || textureId <= 0 || attached || !attaching.compareAndSet(false, true)) return false
        val generation = displayGeneration.incrementAndGet()
        worker.post { render(Runnable {
            if (epoch != id || generation != displayGeneration.get()) { attaching.set(false); return@Runnable }
            runCatching {
                synchronized(lock) {
                    texture = preserveOes { SurfaceTexture(textureId) }.apply {
                        setDefaultBufferSize(width, height)
                        setOnFrameAvailableListener({ if (epoch == id) pending.set(true) }, worker)
                    }
                    surface = Surface(texture); direct = false; layerSlot = 0; attached = true
                }
                worker.post { resumePackets(); worker.post(pump) }
            }.onFailure { error = "AirPlay decoder unavailable" }
            attaching.set(false)
        }) }
        return true
    }
    fun attachLayer(id: Long, producer: Surface, slot: Int, w: Int, h: Int): Boolean {
        if (id <= 0 || id != epoch || slot !in 6..7 || w !in 16..1920 || h !in 16..1920 ||
            (attached && !direct) || !attaching.compareAndSet(false, true)) return false
        val generation = displayGeneration.incrementAndGet()
        worker.post {
            if (id == epoch && generation == displayGeneration.get()) {
                val replacing = attached && direct
                worker.removeCallbacks(pump)
                if (replacing) { stopVideo(); waitingVideo = null; packets.restartVideo() }
                synchronized(lock) {
                    surface = producer; direct = true; surfaceWidth = w; surfaceHeight = h
                    frames = 0; submittedFrames = 0; videoInputs = 0; decodedWidth = 0; decodedHeight = 0; outputWidth = 0; outputHeight = 0
                    layerSlot = slot // Publish only after the previous codec has stopped writing.
                    attached = true; error = ""
                }
                if (!replacing) resumePackets()
                Log.i("Thru3D-Airplay", "Video producer bound slot=$slot ${w}x$h replacement=$replacing")
                worker.post(pump)
            }
            attaching.set(false)
        }
        return true
    }
    fun frame(): JSONObject {
        val id = epoch
        val now = android.os.SystemClock.elapsedRealtime()
        if (id > 0 && now >= nextDiagnosticMs) {
            nextDiagnosticMs = now + 5000
            // Numeric pipeline state only; no sender identity, PIN, keys or media payload.
            Log.i("Thru3D-Airplay", "Mirror pipeline epoch=$id target=${width}x$height video_packets=${receivedVideo.get()} audio_packets=${receivedAudio.get()} config_bytes=${packets.config.size} ready=${packets.videoReady()} attached=$attached output=${decodedWidth}x$decodedHeight frames=$frames video_inputs=$videoInputs submitted_frames=$submittedFrames slot=$layerSlot direct=$direct video_error=${error.isNotEmpty()} audio_bytes=$audioBytes suspended=$suspended")
        }
        if (attached && !direct && scheduled.compareAndSet(false, true)) render(Runnable {
            try {
                synchronized(lock) {
                    if (id == epoch && pending.getAndSet(false)) texture?.let {
                        preserveOes { it.updateTexImage() }; it.getTransformMatrix(matrix); decodedWidth = outputWidth; decodedHeight = outputHeight; frames++
                    }
                }
            } catch (_: Exception) { error = "$sourceName decoder unavailable" }
            finally { scheduled.set(false) }
        })
        return synchronized(lock) { val completed = org.json.JSONArray(); while (released.isNotEmpty()) completed.put(released.removeFirst())
            JSONObject().put("epoch", epoch).put("width", if (decodedWidth > 0) decodedWidth else width).put("height", if (decodedHeight > 0) decodedHeight else height)
            .put("frames", frames).put("submitted_frames", submittedFrames).put("video_inputs", videoInputs)
            .put("revision", revision).put("released", completed).put("muted", muted).put("error", error)
            .put("target_width", width).put("target_height", height).put("layer_slot", layerSlot)
            .put("video_ready", packets.videoReady()).put("on_layer", direct).put("suspended", suspended).put("audio_error", audioError).put("audio_bytes", audioBytes)
            .put("transform", org.json.JSONArray(matrix.map { it.toDouble() })) }
    }
    private fun feedVideo(p: AirplayPackets.Packet): Boolean {
        playerPipe?.let { pipe ->
            val mux = playerMux ?: AirplayMatroska(width, height, sampleRate, audioChannels, baseNs).also { playerMux = it }
            pipe.offer(mux.video(p.data, packets.config, p.ns)); return true
        }
        // An Android-surface swapchain keeps its original producer geometry on some runtimes.
        // Wait for the AirPlay-only replacement before submitting a differently shaped frame.
        if (direct && (width != surfaceWidth || height != surfaceHeight)) return false
        val config = packets.config
        if (video != null && !videoConfig.contentEquals(config)) {
            stopVideo()
        }
        if (video == null) {
            if (config.isEmpty() || AirplayPackets.nals(p.data).none { (p.data[it.first].toInt() and 31) == 5 }) return true
            val format = MediaFormat.createVideoFormat("video/avc", width, height)
            for (span in AirplayPackets.nals(config)) {
                val type = config[span.first].toInt() and 31
                if (type in 7..8) format.setByteBuffer(if (type == 7) "csd-0" else "csd-1", ByteBuffer.wrap(byteArrayOf(0,0,0,1) + config.copyOfRange(span.first, span.last+1)))
            }
            format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 2*1024*1024)
            format.setInteger(MediaFormat.KEY_PRIORITY, 0)
            video = MediaCodec.createDecoderByType("video/avc").also { decoder ->
                decoder.configure(format, surface, null, 0)
                if (direct) decoder.setOnFrameRenderedListener({ current, _, _ ->
                    if (video === current && attached) synchronized(lock) { decodedWidth = outputWidth; decodedHeight = outputHeight; frames++ }
                }, worker)
                decoder.start()
            }
            Log.i("Thru3D-Airplay", "Video decoder started ${width}x$height path=${if (direct) "layer" else "texture"}")
            videoConfig = config
        }
        return feed(video!!, p).also { if (it) synchronized(lock) { videoInputs++ } }
    }
    private fun feedAudio(p: AirplayPackets.Packet): Boolean {
        if ((muted && !captions.accepting && !playerActive()) || audioError.isNotEmpty() || baseNs == 0L || p.ns < baseNs - 100_000_000) return true
        if (p.codec != audioCodec) return true
        if (audioCodec == 0) {
            val due = wallNs + p.ns - baseNs
            val now = System.nanoTime()
            if (now > due + 200_000_000) { pcmPacket = null; pcmBuffer = null; return true }
            if (now < due - 10_000_000) return false
            if (pcmPacket !== p) {
                pcmPacket = p; pcmBuffer = ByteBuffer.wrap(p.data)
                captions.offer(pcmBuffer!!, sampleRate, audioChannels)
                playerMux?.let { playerPipe?.offer(it.audio(p.data, p.ns)) }
            }
            val buffer = pcmBuffer!!
            if (!muted && !playerActive()) {
                if (track == null) track = createTrack(sampleRate, audioChannels)
                val written = track!!.write(buffer, buffer.remaining(), AudioTrack.WRITE_NON_BLOCKING)
                check(written >= 0) { "AudioTrack write failed" }
                audioBytes += written
                if (buffer.hasRemaining()) return false
            }
            pcmPacket = null; pcmBuffer = null
            return true
        }
        if (audio == null) {
            val csd = MirrorAudioFormat.aacConfig(audioCodec, samples, sampleRate, audioChannels)
            val format = MediaFormat.createAudioFormat("audio/mp4a-latm", sampleRate, audioChannels)
            format.setInteger(MediaFormat.KEY_PCM_ENCODING, AudioFormat.ENCODING_PCM_16BIT)
            format.setByteBuffer("csd-0", ByteBuffer.wrap(csd)); format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 65536)
            audio = MediaCodec.createDecoderByType("audio/mp4a-latm").also { it.configure(format, null, null, 0); it.start() }
        }
        return feed(audio!!, p)
    }
    private fun feed(codec: MediaCodec, p: AirplayPackets.Packet): Boolean {
        val index = codec.dequeueInputBuffer(0)
        if (index < 0) return false
        val buffer = codec.getInputBuffer(index)!!
        check(buffer.capacity() >= p.data.size) { "Mirror access unit exceeds decoder input" }
        buffer.clear(); buffer.put(p.data)
        codec.queueInputBuffer(index, 0, p.data.size, ((p.ns - baseNs)/1000).coerceAtLeast(0), 0)
        return true
    }
    private fun drainVideo() {
        val codec = video ?: return
        repeat(8) {
            val index = codec.dequeueOutputBuffer(info, 0)
            if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                val format = codec.outputFormat
                val w = if (format.containsKey("crop-right")) format.getInteger("crop-right") - format.getInteger("crop-left", 0) + 1 else format.getInteger(MediaFormat.KEY_WIDTH)
                val h = if (format.containsKey("crop-bottom")) format.getInteger("crop-bottom") - format.getInteger("crop-top", 0) + 1 else format.getInteger(MediaFormat.KEY_HEIGHT)
                if (w in 16..1920 && h in 16..1920) synchronized(lock) {
                    outputWidth = w; outputHeight = h; decodedWidth = w; decodedHeight = h; revision++
                }
            } else if (index >= 0) {
                val target = wallNs + info.presentationTimeUs*1000
                codec.releaseOutputBuffer(index, target.coerceIn(System.nanoTime(), System.nanoTime()+200_000_000))
                // Queueing to a Surface precedes its consumer's rendered notification. An XR
                // layer must be submitted before that notification can be used as evidence.
                if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0) synchronized(lock) { submittedFrames++ }
            } else return
        }
    }
    private fun drainAudio() {
        val codec = audio ?: return
        repeat(8) {
            if (audioOutput >= 0) {
                if (!muted && !playerActive()) {
                    if (System.nanoTime() < audioDueNs - 10_000_000) return
                    val buffer = audioBuffer
                    if (buffer != null && buffer.hasRemaining()) {
                        val written = track?.write(buffer, buffer.remaining(), AudioTrack.WRITE_NON_BLOCKING) ?: 0
                        check(written >= 0) { "AudioTrack write failed" }
                        audioBytes += written
                        if (buffer.hasRemaining()) return
                    }
                }
                codec.releaseOutputBuffer(audioOutput, false); audioOutput = -1; audioBuffer = null
            }
            val index = codec.dequeueOutputBuffer(info, 0)
            if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                track?.release()
                val f = codec.outputFormat; val rate = f.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                val channels = f.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                decodedAudioRate = if (f.getInteger(MediaFormat.KEY_PCM_ENCODING, AudioFormat.ENCODING_PCM_16BIT) == AudioFormat.ENCODING_PCM_16BIT) rate else 0
                decodedAudioChannels = channels
                if (playerActive()) {
                    check(rate == sampleRate && channels == audioChannels) { "AirPlay PCM format changed" }
                    track = null
                } else track = createTrack(rate, channels)
                Log.i("Thru3D-Airplay", "Audio output started rate=$rate channels=${f.getInteger(MediaFormat.KEY_CHANNEL_COUNT)}")
            } else if (index >= 0) {
                audioOutput = index; audioBuffer = codec.getOutputBuffer(index)
                audioBuffer?.position(info.offset); audioBuffer?.limit(info.offset+info.size)
                if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0)
                    audioBuffer?.let { captions.offer(it, decodedAudioRate, decodedAudioChannels) }
                playerMux?.let { mux ->
                    audioBuffer?.let { buffer ->
                        val bytes = ByteArray(buffer.remaining()); buffer.duplicate().get(bytes)
                        playerPipe?.offer(mux.audio(bytes, baseNs + info.presentationTimeUs * 1000))
                    }
                }
                audioDueNs = wallNs + info.presentationTimeUs*1000
            } else return
        }
    }
    private fun resumePackets() {
        val liveNs = packets.resume()
        if (liveNs > 0) { baseNs = liveNs; wallNs = System.nanoTime() + 100_000_000 }
        suspended = false; audioError = ""
    }
    fun detach(id: Long, keepSession: Boolean = false) {
        if (id != epoch) return
        playerPipe?.close(); playerPipe = null
        if (suspended && !attached && !attaching.get()) {
            if (!keepSession) { epoch = 0; suspended = false; packets.clear() }
            return
        }
        displayGeneration.incrementAndGet()
        if (keepSession) { suspended = true; packets.park() }
        else { epoch = 0; suspended = false; packets.clear() }
        attached = false
        worker.post {
            playerMux = null
            worker.removeCallbacks(pump); stopCodecs()
            if (direct) synchronized(lock) { surface = null; direct = false; layerSlot = 0; frames = 0; decodedWidth = 0; decodedHeight = 0; released.addLast(id) }
            else render(Runnable { synchronized(lock) {
                surface?.release(); surface = null; texture?.release(); texture = null
                pending.set(false); frames = 0; decodedWidth = 0; decodedHeight = 0; released.addLast(id)
            } })
        }
    }
    fun detachAndWait(id: Long, keepSession: Boolean = false): Boolean {
        detach(id, keepSession)
        val stopped = java.util.concurrent.CountDownLatch(1)
        worker.post { stopped.countDown() }
        return try { stopped.await(1500, java.util.concurrent.TimeUnit.MILLISECONDS) }
        catch (_: InterruptedException) { Thread.currentThread().interrupt(); false }
    }
    private fun failAudio(failure: Throwable) {
        playerPipe?.close()
        audioError = "$sourceName audio unavailable"
        Log.w("Thru3D-Airplay", "Audio decoder failed: ${failure.javaClass.simpleName}")
        stopAudio()
    }
    private fun stopAudio() {
        captions.discontinuity(); decodedAudioRate = 0; decodedAudioChannels = 0
        audio?.let { runCatching { it.stop() }; runCatching { it.release() } }; audio = null
        track?.let { runCatching { it.stop() }; runCatching { it.release() } }; track = null
        audioOutput = -1; audioBuffer = null; waitingAudio = null; pcmPacket = null; pcmBuffer = null
    }
    private fun createTrack(rate: Int, channels: Int): AudioTrack {
        val mask = if (channels == 1) AudioFormat.CHANNEL_OUT_MONO else AudioFormat.CHANNEL_OUT_STEREO
        return AudioTrack.Builder().setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_MOVIE).build())
            .setAudioFormat(AudioFormat.Builder().setEncoding(AudioFormat.ENCODING_PCM_16BIT).setSampleRate(rate).setChannelMask(mask).build())
            .setBufferSizeInBytes(AudioTrack.getMinBufferSize(rate, mask, AudioFormat.ENCODING_PCM_16BIT).coerceAtLeast(16384)).build().also { it.play() }
    }
    private fun stopCodecs() {
        stopVideo()
        stopAudio(); baseNs = 0; waitingVideo = null
    }
    private fun stopVideo() {
        val old = video; video = null
        old?.let { runCatching { it.stop() }; runCatching { it.release() } }
        videoConfig = ByteArray(0)
        synchronized(lock) { frames = 0; submittedFrames = 0; videoInputs = 0; decodedWidth = 0; decodedHeight = 0; outputWidth = 0; outputHeight = 0 }
    }
    fun close() { detach(epoch); worker.post { thread.quitSafely() } }
    private fun <T> preserveOes(action: () -> T): T {
        val binding = IntArray(1); GLES30.glGetIntegerv(GLES11Ext.GL_TEXTURE_BINDING_EXTERNAL_OES, binding, 0)
        return try { action() } finally { GLES30.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, binding[0]) }
    }
}
