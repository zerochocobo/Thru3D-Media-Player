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
internal class AirplayMirror(private val render: (Runnable) -> Unit) {
    private val thread = HandlerThread("Thru3D-Airplay-Mirror").apply { start() }
    private val worker = Handler(thread.looper)
    private val packets = AirplayPackets()
    private val lock = Any()
    private val pending = AtomicBoolean(false)
    private val scheduled = AtomicBoolean(false)
    private val attaching = AtomicBoolean(false)
    private val displayGeneration = java.util.concurrent.atomic.AtomicLong()
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
    private var baseNs = 0L
    private var wallNs = 0L
    private var frames = 0L
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
    private val info = MediaCodec.BufferInfo()
    @Volatile private var attached = false
    @Volatile private var suspended = false
    private val pump = object : Runnable {
        override fun run() {
            if (!attached) return
            val runningEpoch = epoch
            runCatching {
                for (attempt in 0 until 8) {
                    val p = waitingVideo ?: packets.take(true) ?: break
                    if (baseNs == 0L) { baseNs = p.ns; wallNs = System.nanoTime() + 100_000_000 }
                    if (!feedVideo(p)) { waitingVideo = p; break }
                    waitingVideo = null
                }
                drainVideo()
            }.onFailure { if (epoch == runningEpoch) error = "AirPlay decoder unavailable"; Log.w("Thru3D-Airplay", "Video decoder failed: ${it.javaClass.simpleName}"); stopCodecs() }
            if (error.isEmpty()) runCatching {
                for (attempt in 0 until 8) {
                    val p = waitingAudio ?: packets.take(false) ?: break
                    if (!feedAudio(p)) { waitingAudio = p; break }
                    waitingAudio = null
                }
                drainAudio()
            }.onFailure { failAudio(it) }
            if (attached && error.isEmpty()) worker.postDelayed(this, 5)
        }
    }
    fun begin(id: Long, paused: Boolean = false) { epoch = id; packets.clear(); error = ""; audioError = ""; audioBytes = 0; suspended = paused; if (paused) packets.park() }
    fun size(w: Int, h: Int) {
        if (w !in 16..1920 || h !in 16..1920) return
        synchronized(lock) { width = w; height = h }
    }
    fun audioFormat(codec: Int, spf: Int) {
        if (codec !in listOf(4, 8) || spf !in listOf(480, 512, 960, 1024)) return
        worker.post { if (codec != audioCodec || spf != samples) stopAudio(); audioCodec = codec; samples = spf; audioError = ""; Log.i("Thru3D-Airplay", "Audio format codec=$codec samples=$spf") }
    }
    fun packet(video: Boolean, bytes: ByteArray, ns: Long, codec: Int) {
        if (epoch <= 0 || ns <= 0 || bytes.size > 2*1024*1024) return
        packets.offer(AirplayPackets.Packet(video, bytes, ns, codec))
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
                    frames = 0; decodedWidth = 0; decodedHeight = 0; outputWidth = 0; outputHeight = 0
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
        if (attached && !direct && scheduled.compareAndSet(false, true)) render(Runnable {
            try {
                synchronized(lock) {
                    if (id == epoch && pending.getAndSet(false)) texture?.let {
                        preserveOes { it.updateTexImage() }; it.getTransformMatrix(matrix); decodedWidth = outputWidth; decodedHeight = outputHeight; frames++
                    }
                }
            } catch (_: Exception) { error = "AirPlay decoder unavailable" }
            finally { scheduled.set(false) }
        })
        return synchronized(lock) { val completed = org.json.JSONArray(); while (released.isNotEmpty()) completed.put(released.removeFirst())
            JSONObject().put("epoch", epoch).put("width", if (decodedWidth > 0) decodedWidth else width).put("height", if (decodedHeight > 0) decodedHeight else height)
            .put("frames", frames).put("revision", revision).put("released", completed).put("muted", muted).put("error", error)
            .put("target_width", width).put("target_height", height).put("layer_slot", layerSlot)
            .put("video_ready", packets.videoReady()).put("on_layer", direct).put("suspended", suspended).put("audio_error", audioError).put("audio_bytes", audioBytes)
            .put("transform", org.json.JSONArray(matrix.map { it.toDouble() })) }
    }
    private fun feedVideo(p: AirplayPackets.Packet): Boolean {
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
        return feed(video!!, p)
    }
    private fun feedAudio(p: AirplayPackets.Packet): Boolean {
        if (muted || audioError.isNotEmpty() || baseNs == 0L || p.ns < baseNs - 100_000_000) return true
        if (audio == null) {
            val csd = if (audioCodec == 8) byteArrayOf(0xf8.toByte(), 0xe8.toByte(), if (samples == 512) 0x40 else 0x50, 0)
                else byteArrayOf(0x12, if (samples == 960) 0x14 else 0x10)
            val format = MediaFormat.createAudioFormat("audio/mp4a-latm", 44100, 2)
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
            } else return
        }
    }
    private fun drainAudio() {
        val codec = audio ?: return
        repeat(8) {
            if (audioOutput >= 0) {
                if (!muted) {
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
                val channels = if (f.getInteger(MediaFormat.KEY_CHANNEL_COUNT) == 1) AudioFormat.CHANNEL_OUT_MONO else AudioFormat.CHANNEL_OUT_STEREO
                track = AudioTrack.Builder().setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_MOVIE).build())
                    .setAudioFormat(AudioFormat.Builder().setEncoding(AudioFormat.ENCODING_PCM_16BIT).setSampleRate(rate).setChannelMask(channels).build())
                    .setBufferSizeInBytes(AudioTrack.getMinBufferSize(rate, channels, AudioFormat.ENCODING_PCM_16BIT).coerceAtLeast(16384)).build().also { it.play() }
                Log.i("Thru3D-Airplay", "Audio output started rate=$rate channels=${f.getInteger(MediaFormat.KEY_CHANNEL_COUNT)}")
            } else if (index >= 0) {
                audioOutput = index; audioBuffer = codec.getOutputBuffer(index)
                audioBuffer?.position(info.offset); audioBuffer?.limit(info.offset+info.size)
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
        if (suspended && !attached && !attaching.get()) {
            if (!keepSession) { epoch = 0; suspended = false; packets.clear() }
            return
        }
        displayGeneration.incrementAndGet()
        if (keepSession) { suspended = true; packets.park() }
        else { epoch = 0; suspended = false; packets.clear() }
        attached = false
        worker.post {
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
        audioError = "AirPlay audio unavailable"
        Log.w("Thru3D-Airplay", "Audio decoder failed: ${failure.javaClass.simpleName}")
        stopAudio()
    }
    private fun stopAudio() {
        audio?.let { runCatching { it.stop() }; runCatching { it.release() } }; audio = null
        track?.let { runCatching { it.stop() }; runCatching { it.release() } }; track = null
        audioOutput = -1; audioBuffer = null; waitingAudio = null
    }
    private fun stopCodecs() {
        stopVideo()
        stopAudio(); baseNs = 0; waitingVideo = null
    }
    private fun stopVideo() {
        val old = video; video = null
        old?.let { runCatching { it.stop() }; runCatching { it.release() } }
        videoConfig = ByteArray(0)
        synchronized(lock) { frames = 0; decodedWidth = 0; decodedHeight = 0; outputWidth = 0; outputHeight = 0 }
    }
    fun close() { detach(epoch); worker.post { thread.quitSafely() } }
    private fun <T> preserveOes(action: () -> T): T {
        val binding = IntArray(1); GLES30.glGetIntegerv(GLES11Ext.GL_TEXTURE_BINDING_EXTERNAL_OES, binding, 0)
        return try { action() } finally { GLES30.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, binding[0]) }
    }
}
