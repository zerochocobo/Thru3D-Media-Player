package org.vrpassthroughplayer.plugin

import android.content.Context
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.util.Log
import androidx.media3.container.NalUnitUtil
import org.json.JSONObject
import org.vrpassthroughplayer.miracast.WfdAudioFrames
import org.vrpassthroughplayer.miracast.WfdRtspSession
import org.vrpassthroughplayer.miracast.WfdRtcp
import org.vrpassthroughplayer.miracast.WfdTransport
import org.vrpassthroughplayer.miracast.WfdTimestamp
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.Inet4Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** Radio privilege stays in the optional shell broker; current-peer media stays in the player. */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
internal class MiracastReceiver(
    private val context: () -> Context?,
    private val mirror: AirplayMirror,
    private val claim: () -> Long,
    private val release: (Long) -> Unit,
    private val owns: (Long) -> Boolean,
    private val canAccept: () -> Boolean
) {
    private val thread = HandlerThread("Thru3D-Miracast-Control").apply { start() }
    private val worker = Handler(thread.looper)
    private val streams = Executors.newSingleThreadExecutor { task -> Thread(task, "Thru3D-Miracast-Media") }
    @Volatile private var wanted = false
    @Volatile private var closed = false
    @Volatile var state = "off"; private set
    @Volatile var error = ""; private set
    @Volatile var name = ""; private set
    private var broker: MiracastRadioClient? = null
    @Volatile private var stream: Stream? = null
    private var retryAfter = 0L
    private val poll = object : Runnable {
        override fun run() {
            if (closed || !wanted) return
            try {
                if (broker == null) {
                    broker = MiracastRadioClient(context() ?: error("Receiver context unavailable"))
                    checkBroker(request("enable"))
                }
                var status = checkBroker(request("heartbeat"))
                if (!status.optBoolean("enabled") && status.optString("state") == "off") status = checkBroker(request("enable"))
                error = if (status.optString("error").isEmpty()) "" else "Miracast unavailable"
                state = status.optString("state", "unavailable")
                name = status.optString("name").take(128)
                val peer = status.optJSONObject("peer")
                val current = stream
                if (current != null && (peer == null || current.identity != peerIdentity(peer))) current.close()
                if (wanted && !closed && peer != null && stream == null && SystemClock.elapsedRealtime() >= retryAfter && canAccept()) {
                    val epoch = claim()
                    if (epoch > 0) {
                        try {
                            val next = Stream(epoch, peer)
                            stream = next
                            streams.execute { next.run() }
                        } catch (failure: Exception) { release(epoch); throw failure }
                    }
                }
            } catch (_: Exception) {
                state = "unavailable"; error = "Miracast unavailable"
                stream?.close(); resetBroker()
            }
            if (!closed && wanted) worker.postDelayed(this, if (state == "unavailable") 2000 else 500)
        }
    }
    fun enable(value: Boolean) {
        wanted = value
        if (!value) stream?.close()
        worker.post {
            worker.removeCallbacks(poll)
            if (!value) { runCatching { if (broker != null) request("disable") }; resetBroker(); state = "off"; error = "" }
            else { error = ""; worker.post(poll) }
        }
    }
    fun disconnect() { stream?.close() }
    private fun checkBroker(status: JSONObject): JSONObject {
        check(status.optInt("version") == 1 && status.optInt("app_uid") == android.os.Process.myUid()) { "Wrong receiver broker" }
        return status
    }
    private fun request(command: String): JSONObject {
        return (broker ?: error("Broker unavailable")).request(command, canAccept())
    }
    private fun resetBroker() { runCatching { broker?.close() }; broker = null }
    private fun peerIdentity(peer: JSONObject) = listOf(peer.optString("host"), peer.optString("local"), peer.optInt("port")).joinToString("|")
    private inner class Stream(private val epoch: Long, peer: JSONObject) {
        val identity = peerIdentity(peer)
        private val host = InetAddress.getByName(peer.getString("host"))
        private val local = InetAddress.getByName(peer.getString("local"))
        private val port = peer.getInt("port")
        private val stopped = AtomicBoolean(false)
        @Volatile private var tcp: Socket? = null
        @Volatile private var rtp: DatagramSocket? = null
        @Volatile private var rtcp: DatagramSocket? = null
        @Volatile private var audioType = "none"
        @Volatile private var remoteRtp = 0
        @Volatile private var remoteRtcp = 0
        @Volatile private var playing = false
        @Volatile private var keyframe = false
        @Volatile private var control: WfdRtspSession? = null
        private val clock = WfdTimestamp()
        fun run() {
            var receiver: Thread? = null
            var reports: Thread? = null
            var stage = "bind_media"
            try {
                check(host is Inet4Address && local is Inet4Address && !host.isLoopbackAddress && !local.isLoopbackAddress && port in 1..65535)
                var localPort = 0
                for (candidate in 19000..19100 step 2) {
                    var first: DatagramSocket? = null
                    try {
                        first = DatagramSocket(InetSocketAddress(local, candidate))
                        rtcp = DatagramSocket(InetSocketAddress(local, candidate + 1))
                        rtp = first; localPort = candidate; break
                    } catch (_: Exception) { first?.close() }
                }
                check(localPort > 0) { "No RTP socket pair" }
                rtp!!.receiveBufferSize = 1024 * 1024; rtp!!.soTimeout = 1000
                stage = "connect_rtsp"
                tcp = Socket().also { socket ->
                    try { socket.bind(InetSocketAddress(local, 0)); socket.connect(InetSocketAddress(host, port), 3000) }
                    catch (failure: Exception) { runCatching { socket.close() }; throw failure }
                }
                val frames = WfdAudioFrames { pcm, bytes, pts ->
                    if (!stopped.get() && owns(epoch)) mirror.packet(false, bytes, clock.nanoseconds(pts), if (pcm) 0 else 4)
                }
                val transport = WfdTransport(object : WfdTransport.Listener {
                    override fun video(bytes: ByteArray, pts: Long) {
                        if (stopped.get() || !owns(epoch)) return
                        for (nal in AirplayPackets.nals(bytes)) if ((bytes[nal.first].toInt() and 31) == 7) {
                            val size = runCatching { NalUnitUtil.parseSpsNalUnit(bytes, nal.first, nal.last + 1) }.getOrNull()
                            if (size != null && size.width in 16..1920 && size.height in 16..1920) mirror.size(size.width, size.height)
                        }
                        if (AirplayPackets.nals(bytes).any { (bytes[it.first].toInt() and 31) == 5 }) keyframe = true
                        mirror.packet(true, bytes, clock.nanoseconds(pts), 264)
                    }
                    override fun audio(codec: WfdTransport.AudioCodec, bytes: ByteArray, pts: Long) {
                        check((audioType == "AAC" && codec == WfdTransport.AudioCodec.AAC_ADTS) || (audioType == "LPCM" && codec == WfdTransport.AudioCodec.LPCM)) { "Unnegotiated audio" }
                        frames.pes(codec, bytes, pts)
                    }
                    override fun discontinuity(video: Boolean) {
                        if (!video) frames.reset() else keyframe = false
                        if (owns(epoch)) mirror.discontinuity(video)
                    }
                })
                val report = WfdRtcp(transport, java.security.SecureRandom().nextInt())
                reports = Thread({
                    try {
                        val buffer = ByteArray(4096); val packet = DatagramPacket(buffer, buffer.size)
                        rtcp!!.soTimeout = 500
                        var nextReport = SystemClock.elapsedRealtime() + 2500
                        while (!stopped.get() && owns(epoch)) {
                            try {
                                packet.length = buffer.size; rtcp!!.receive(packet)
                                if (packet.address == host && (remoteRtcp == 0 || packet.port == remoteRtcp)) report.receive(buffer, packet.length, System.nanoTime())
                            } catch (_: java.net.SocketTimeoutException) { }
                            if (playing && remoteRtcp > 0 && SystemClock.elapsedRealtime() >= nextReport) {
                                report.report(System.nanoTime())?.let { rtcp!!.send(DatagramPacket(it, it.size, host, remoteRtcp)) }
                                nextReport = SystemClock.elapsedRealtime() + 5000
                            }
                        }
                    } catch (_: Exception) { if (!stopped.get()) close() }
                }, "Thru3D-Miracast-RTCP").also { it.start() }
                receiver = Thread({
                    try {
                        val buffer = ByteArray(65536); val packet = DatagramPacket(buffer, buffer.size)
                        var keyRequestAt = SystemClock.elapsedRealtime() + 1500
                        while (!stopped.get() && owns(epoch)) {
                            try {
                                packet.length = buffer.size; rtp!!.receive(packet)
                                if (playing && packet.address == host && (remoteRtp == 0 || remoteRtp == packet.port)) transport.rtp(buffer, 0, packet.length)
                            } catch (_: java.net.SocketTimeoutException) { }
                            if (playing && !keyframe && SystemClock.elapsedRealtime() >= keyRequestAt) {
                                runCatching { control?.requestKeyFrame() }; keyRequestAt = SystemClock.elapsedRealtime() + 2000
                            }
                        }
                    } catch (_: Exception) { if (!stopped.get()) close() }
                }, "Thru3D-Miracast-RTP").also { it.start() }
                stage = "negotiate_rtsp"
                Log.i("Thru3D-Miracast", "Session TCP connected")
                WfdRtspSession(tcp!!, localPort, object : WfdRtspSession.Listener {
                    override fun audioFormat(codec: String) {
                        audioType = codec
                        if (owns(epoch) && codec != "none") mirror.audioFormat(if (codec == "LPCM") 0 else 4, 1024, 48000, 2)
                    }
                    override fun playing(rtpPort: Int, rtcpPort: Int) {
                        remoteRtp = rtpPort
                        remoteRtcp = if (rtcpPort > 0) rtcpPort else if (rtpPort in 1..65534) rtpPort + 1 else 0
                        playing = true
                        stage = "playing"
                        Log.i("Thru3D-Miracast", "Session PLAY accepted")
                    }
                    override fun stopped() { close() }
                }, if (BuildConfig.DEBUG) WfdRtspSession.Trace { incoming, method, status ->
                    Log.i("Thru3D-Miracast", "Control incoming=$incoming method=$method status=$status")
                } else null).use { control = it; it.run() }
            } catch (failure: Exception) {
                if (!stopped.get()) error = "Miracast unavailable"
                val known = setOf("Unadvertised video format", "Unadvertised audio format", "Non-UDP RTP transport selected", "Protected WFD session unsupported", "Unbound WFD presentation URL", "Missing or invalid RTSP session", "Unmatched RTSP response CSeq", "WFD request rejected", "No RTP socket pair", "Unnegotiated audio")
                val reason = failure.message?.takeIf { it in known }?.replace(' ', '_') ?: failure.javaClass.simpleName
                val errno = generateSequence<Throwable>(failure) { it.cause }.take(4).filterIsInstance<android.system.ErrnoException>().firstOrNull()?.errno ?: 0
                Log.w("Thru3D-Miracast", "Session failed stage=$stage reason=$reason errno=$errno")
            }
            finally {
                Log.i("Thru3D-Miracast", "Session ended stage=$stage playing=$playing")
                close(); runCatching { receiver?.join(1500) }; runCatching { reports?.join(1500) }; release(epoch)
                worker.post {
                    if (stream === this) { stream = null; retryAfter = SystemClock.elapsedRealtime() + 3000; resetBroker() }
                }
            }
        }
        fun close() {
            stopped.set(true)
            runCatching { tcp?.close() }; rtp?.close(); rtcp?.close()
        }
    }
    fun close() {
        closed = true; wanted = false; stream?.close(); streams.shutdownNow()
        worker.post { worker.removeCallbacks(poll); runCatching { if (broker != null) request("disable") }; resetBroker(); thread.quitSafely() }
    }
}
