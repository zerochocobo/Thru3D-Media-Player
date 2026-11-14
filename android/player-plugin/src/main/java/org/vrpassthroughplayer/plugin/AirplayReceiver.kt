package org.vrpassthroughplayer.plugin

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.Surface
import org.json.JSONObject
import java.io.File
import java.security.SecureRandom

/** LAN discovery/transport has its own lifetime, independent of the DLNA main-screen owner. */
internal class AirplayReceiver(private val context: () -> Context?, render: (Runnable) -> Unit) {
    private val thread = HandlerThread("Thru3D-Airplay-Server").apply { start() }
    private val worker = Handler(thread.looper)
    private val leases = CastMirrorLease()
    private val captions = AirplayCaptions(context)
    private val mirror = AirplayMirror(render, captions)
    private var handle = 0L
    private var wanted = false
    private var requirePassword = false
    @Volatile private var foreground = true
    private var port = 0
    private var raopName = ""
    private val airplayTxt = LinkedHashMap<String, String>()
    private val raopTxt = LinkedHashMap<String, String>()
    private val registrations = ArrayList<NsdManager.RegistrationListener>()
    @Volatile private var state = "off"
    @Volatile private var error = ""
    @Volatile private var pin = ""
    private val active: Long get() = leases.current?.epoch ?: 0L
    @Volatile private var airplayCodec = 8
    @Volatile private var airplaySamples = 480
    @Volatile private var airplayWidth = 1280
    @Volatile private var airplayHeight = 720
    @Volatile private var accepting = false
    @Volatile private var generation = 0L
    private var registeredServices = 0
    // Keep multicast reception enabled when onMainPause releases DLNA's foreground multicast lock.
    // Own this lease for the complete receiver lifetime, including idle/background discovery.
    private var multicast: WifiManager.MulticastLock? = null
    private val discovery = AirplayDiscoveryDiagnostics()
    fun discoveryDiagnostics(): String = discovery.snapshot()
    private fun discoveryEvent(stage: String, code: Int? = null, failure: Throwable? = null) {
        Log.i("Thru3D-Airplay", "Discovery " + discovery.record(stage, generation, state, port,
            handle != 0L, registeredServices, code, failure, foreground, multicast?.isHeld == true))
    }
    @Synchronized private fun beginMirror(): Long {
        val ticket = leases.claim("AirPlay") ?: return 0
        mirror.begin(ticket.epoch, !foreground, "AirPlay")
        mirror.size(airplayWidth, airplayHeight); mirror.audioFormat(airplayCodec, airplaySamples)
        context()?.let { AirplayReceiverService.active(it, true) }
        return ticket.epoch
    }
    @Synchronized private fun endMirror(protocol: String, epoch: Long) {
        if (!leases.release(protocol, epoch)) return
        captions.configure("")
        mirror.detach(epoch)
        context()?.let { AirplayReceiverService.active(it, leases.current != null) }
    }
    private fun haltMirror() {
        accepting = false
        leases.current?.let { endMirror(it.protocol, it.epoch) }
    }
    fun enable(value: Boolean) { if (!value) haltMirror(); worker.post {
        if (wanted == value && (!value || handle != 0L)) return@post
        val app = context() ?: return@post
        if (value) try { AirplayReceiverService.begin(app) { enable(false) } }
        catch (failure: Exception) {
            state = "failed"; error = "AirPlay receiver unavailable"
            discoveryEvent("foreground_start_failed", failure = failure); return@post
        }
        else AirplayReceiverService.end(app)
        wanted = value; Log.i("Thru3D-Airplay", "Receiver enabled=$value"); restart()
    } }
    /** Godot's global configuration is the only persistent owner of this option. */
    fun requirePassword(value: Boolean) { worker.post {
        if (requirePassword == value) return@post
        requirePassword = value
        // A new server invalidates old authorization and republishes both discovery records.
        if (wanted) restart()
    } }
    fun foreground(value: Boolean) {
        if (foreground == value) return
        foreground = value
        if (!value) { captions.configure(""); mirror.detachAndWait(active, keepSession = true) }
        Log.i("Thru3D-Airplay", "Receiver foreground=$value (transport retained)")
        worker.post { discoveryEvent("foreground_changed") }
    }
    private fun restart() {
        stop()
        if (!wanted) return
        discoveryEvent("native_load_begin")
        if (!AirplayNative.available) {
            state = "unavailable"; error = "AirPlay receiver unavailable"
            discoveryEvent("native_load_failed", failure = AirplayNative.loadFailure); return
        }
        discoveryEvent("native_load_ready")
        val app = context() ?: return
        val preferences = app.getSharedPreferences("airplay_receiver", Context.MODE_PRIVATE)
        val id = preferences.getString("id", null) ?: ByteArray(6).also { SecureRandom().nextBytes(it); it[0] = ((it[0].toInt() or 2) and 254).toByte() }
            .joinToString("") { "%02x".format(it) }.also { preferences.edit().putString("id", it).apply() }
        val address = id.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
        val key = File(app.filesDir, "airplay/pairing.key").apply { parentFile!!.mkdirs() }
        val session = ++generation
        state = "starting"; error = ""; airplayTxt.clear(); raopTxt.clear(); port = 0
        try {
            val wifi = app.getSystemService(Context.WIFI_SERVICE) as WifiManager
            val lock = multicast ?: wifi.createMulticastLock("Thru3D:AirplayDiscovery")
                .apply { setReferenceCounted(false) }.also { multicast = it }
            if (!lock.isHeld) lock.acquire()
            discoveryEvent("multicast_lock_acquired")
        } catch (failure: Exception) {
            state = "failed"; error = "AirPlay receiver unavailable"
            discoveryEvent("multicast_lock_failed", failure = failure); stop(); return
        }
        accepting = true
        val listener = object : AirplayNative.Listener {
            override fun event(kind: String, value: String) {
                if (session != generation || !accepting) return
                when (kind) {
                    "startup_stage" -> discoveryEvent("native_$value")
                    "port" -> port = value.toIntOrNull() ?: 0
                    "airplay_txt", "raop_txt" -> {
                        val parts = value.split('=', limit = 2)
                        if (parts.size == 2) (if (kind == "airplay_txt") airplayTxt else raopTxt)[parts[0]] = parts[1]
                    }
                    "raop_name" -> raopName = value
                    "pin" -> pin = value.take(8)
                    "mirror_start" -> if (leases.current?.protocol != "AirPlay") {
                        val epoch = beginMirror()
                        if (epoch == 0L) worker.post { restart() }
                        else { pin = ""; Log.i("Thru3D-Airplay", "Mirror started epoch=$epoch") }
                    }
                    "mirror_stop" -> leases.current?.takeIf { it.protocol == "AirPlay" }?.let { endMirror(it.protocol, it.epoch) }
                    "size" -> { val parts = value.split('x'); if (parts.size == 2) {
                        airplayWidth = parts[0].toIntOrNull() ?: 1280; airplayHeight = parts[1].toIntOrNull() ?: 720
                        if (leases.current?.protocol == "AirPlay") mirror.size(airplayWidth, airplayHeight)
                    } }
                    "audio_format" -> { val parts = value.split(':'); if (parts.size == 2) {
                        airplayCodec = parts[0].toIntOrNull() ?: 8; airplaySamples = parts[1].toIntOrNull() ?: 480
                        if (leases.current?.protocol == "AirPlay") mirror.audioFormat(airplayCodec, airplaySamples)
                    } }
                }
            }
            override fun packet(video: Boolean, bytes: ByteArray, ns: Long, codec: Int) {
                if (session == generation && accepting && leases.current?.protocol == "AirPlay") mirror.packet(video, bytes, ns, codec)
            }
        }
        discoveryEvent("native_start_begin")
        handle = runCatching { AirplayNative.start(listener, "Thru3D", address, key.absolutePath, requirePassword) }
            .onFailure { discoveryEvent("native_start_exception", failure = it) }.getOrDefault(0)
        if (handle == 0L || port <= 0) {
            state = "failed"; error = "AirPlay receiver unavailable"
            discoveryEvent("native_start_failed"); stop(); return
        }
        discoveryEvent("native_listening")
        registeredServices = 0
        register(app, "Thru3D", "_airplay._tcp.", airplayTxt, session)
        register(app, raopName, "_raop._tcp.", raopTxt, session)
        worker.postDelayed({
            if (session == generation && registeredServices < 2) discoveryEvent("nsd_incomplete_after_10s")
        }, 10_000)
    }
    private fun register(app: Context, name: String, type: String, txt: Map<String, String>, session: Long) {
        val nsd = app.getSystemService(Context.NSD_SERVICE) as NsdManager
        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(info: NsdServiceInfo) {
                val registration = this
                worker.post {
                    if (session != generation) runCatching { nsd.unregisterService(registration) }
                    else {
                        if (++registeredServices == 2) state = "ready"
                        discoveryEvent("${type}_registered")
                    }
                }
            }
            override fun onServiceUnregistered(info: NsdServiceInfo) {}
            override fun onRegistrationFailed(info: NsdServiceInfo, code: Int) { worker.post { if (session == generation) {
                state = "failed"; error = "AirPlay receiver unavailable"
                discoveryEvent("${type}_registration_failed", code)
            } } }
            override fun onUnregistrationFailed(info: NsdServiceInfo, code: Int) {
                // Record the old generation separately; do not mutate the current receiver state.
                Log.w("Thru3D-Airplay", "Unregistration failed type=$type generation=$session code=$code")
            }
        }
        registrations.add(listener)
        runCatching {
            discoveryEvent("${type}_register_begin")
            nsd.registerService(NsdServiceInfo().also { info -> info.serviceName = name; info.serviceType = type; info.port = port; txt.forEach { (k,v) -> info.setAttribute(k,v) } }, NsdManager.PROTOCOL_DNS_SD, listener)
        }.onFailure {
            state = "failed"; error = "AirPlay receiver unavailable"
            discoveryEvent("${type}_register_exception", failure = it)
        }
    }
    fun poll(): String = mirror.frame().put("active", active).put("protocol", leases.current?.protocol ?: "AirPlay")
        .put("state", state).put("pin", pin).put("receiver_error", error).put("foreground", foreground).put("player_active", mirror.playerActive()).toString()
    fun openPlayer(epoch: Long): Boolean = foreground && active == epoch && mirror.openPlayer(epoch)
    fun claimPlayer(uri: String): android.os.ParcelFileDescriptor? =
        if (uri == "airplayvideo://$active" && active > 0) mirror.claimPlayer() else null
    fun attach(epoch: Long, texture: Int): Boolean = active == epoch && mirror.attach(epoch, texture)
    fun attachLayer(epoch: Long, surface: Surface, slot: Int, width: Int, height: Int): Boolean = active == epoch && mirror.attachLayer(epoch, surface, slot, width, height)
    fun detachLayer(epoch: Long): Boolean = mirror.detachAndWait(epoch)
    fun suspend(epoch: Long): Boolean = mirror.detachAndWait(epoch, keepSession = true)
    fun disconnect(epoch: Long) { worker.post { if (active == epoch) restart() } }
    fun muted(value: Boolean) { mirror.muted = value }
    @Synchronized fun captions(epoch: Long, language: String): Boolean =
        epoch > 0 && active == epoch && (foreground || language.isEmpty()) && captions.configure(language)
    fun captionStatus(epoch: Long): String = if (epoch > 0 && active == epoch) captions.status() else "{}"
    private fun stop() {
        haltMirror()
        ++generation
        pin = ""
        context()?.let { app ->
            val nsd = app.getSystemService(Context.NSD_SERVICE) as NsdManager
            registrations.forEach { runCatching { nsd.unregisterService(it) } }
        }
        registrations.clear()
        context()?.let { AirplayReceiverService.active(it, leases.current != null) }
        if (handle != 0L) { AirplayNative.stop(handle); handle = 0 }
        runCatching { if (multicast?.isHeld == true) multicast?.release(); multicast = null }
            .onFailure { discoveryEvent("multicast_release_failed", failure = it) }
        port = 0; registeredServices = 0
        if (state !in listOf("unavailable", "failed")) state = "off"
        discoveryEvent("stopped")
    }
    fun close() { haltMirror(); captions.close(); context()?.let { AirplayReceiverService.end(it) }; worker.post { wanted = false; stop(); mirror.close(); thread.quitSafely() } }
}
