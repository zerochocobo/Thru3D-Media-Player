package org.vrpassthroughplayer.plugin

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.Surface
import org.json.JSONObject
import java.io.File
import java.security.SecureRandom
import java.util.concurrent.atomic.AtomicLong

/** LAN discovery/transport has its own lifetime, independent of the DLNA main-screen owner. */
internal class AirplayReceiver(private val context: () -> Context?, render: (Runnable) -> Unit) {
    private val thread = HandlerThread("Thru3D-Airplay-Server").apply { start() }
    private val worker = Handler(thread.looper)
    private val serial = AtomicLong()
    private val mirror = AirplayMirror(render)
    private var handle = 0L
    private var wanted = false
    @Volatile private var foreground = true
    private var port = 0
    private var raopName = ""
    private val airplayTxt = LinkedHashMap<String, String>()
    private val raopTxt = LinkedHashMap<String, String>()
    private val registrations = ArrayList<NsdManager.RegistrationListener>()
    @Volatile private var state = "off"
    @Volatile private var error = ""
    @Volatile private var pin = ""
    @Volatile private var active = 0L
    @Volatile private var accepting = false
    @Volatile private var generation = 0L
    private var registeredServices = 0
    private fun haltMirror() {
        accepting = false
        val old = active; active = 0
        if (old > 0) mirror.detach(old)
    }
    fun enable(value: Boolean) { if (!value) haltMirror(); worker.post {
        if (wanted == value && (!value || handle != 0L)) return@post
        val app = context() ?: return@post
        if (value) try { AirplayReceiverService.begin(app) { enable(false) } }
        catch (_: Exception) { state = "failed"; error = "AirPlay receiver unavailable"; return@post }
        else AirplayReceiverService.end(app)
        wanted = value; Log.i("Thru3D-Airplay", "Receiver enabled=$value"); restart()
    } }
    fun foreground(value: Boolean) {
        if (foreground == value) return
        foreground = value
        if (!value) mirror.detachAndWait(active, keepSession = true)
        Log.i("Thru3D-Airplay", "Receiver foreground=$value (transport retained)")
    }
    private fun restart() {
        stop()
        if (!wanted) return
        if (!AirplayNative.available) { state = "unavailable"; error = "AirPlay receiver unavailable"; return }
        val app = context() ?: return
        val preferences = app.getSharedPreferences("airplay_receiver", Context.MODE_PRIVATE)
        val id = preferences.getString("id", null) ?: ByteArray(6).also { SecureRandom().nextBytes(it); it[0] = ((it[0].toInt() or 2) and 254).toByte() }
            .joinToString("") { "%02x".format(it) }.also { preferences.edit().putString("id", it).apply() }
        val address = id.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
        val key = File(app.filesDir, "airplay/pairing.key").apply { parentFile!!.mkdirs() }
        val session = ++generation
        state = "starting"; error = ""; airplayTxt.clear(); raopTxt.clear(); port = 0
        accepting = true
        val listener = object : AirplayNative.Listener {
            override fun event(kind: String, value: String) {
                if (session != generation || !accepting) return
                when (kind) {
                    "port" -> port = value.toIntOrNull() ?: 0
                    "airplay_txt", "raop_txt" -> {
                        val parts = value.split('=', limit = 2)
                        if (parts.size == 2) (if (kind == "airplay_txt") airplayTxt else raopTxt)[parts[0]] = parts[1]
                    }
                    "raop_name" -> raopName = value
                    "pin" -> pin = value.take(8)
                    "mirror_start" -> if (active == 0L) { val epoch = serial.incrementAndGet(); mirror.begin(epoch, !foreground); active = epoch; pin = ""; AirplayReceiverService.active(app, true); Log.i("Thru3D-Airplay", "Mirror started epoch=$epoch") }
                    "mirror_stop" -> { val epoch = active; active = 0; if (epoch > 0) { AirplayReceiverService.active(app, false); Log.i("Thru3D-Airplay", "Mirror stopped epoch=$epoch reason=$value"); mirror.detach(epoch) } }
                    "size" -> { val parts = value.split('x'); if (parts.size == 2) mirror.size(parts[0].toIntOrNull() ?: 0, parts[1].toIntOrNull() ?: 0) }
                    "audio_format" -> { val parts = value.split(':'); if (parts.size == 2) mirror.audioFormat(parts[0].toIntOrNull() ?: 0, parts[1].toIntOrNull() ?: 0) }
                }
            }
            override fun packet(video: Boolean, bytes: ByteArray, ns: Long, codec: Int) {
                if (session == generation && accepting && active > 0) mirror.packet(video, bytes, ns, codec)
            }
        }
        handle = runCatching { AirplayNative.start(listener, "Thru3D", address, key.absolutePath) }.getOrDefault(0)
        if (handle == 0L || port <= 0) { state = "failed"; error = "AirPlay receiver unavailable"; stop(); return }
        registeredServices = 0
        register(app, "Thru3D", "_airplay._tcp.", airplayTxt, session)
        register(app, raopName, "_raop._tcp.", raopTxt, session)
    }
    private fun register(app: Context, name: String, type: String, txt: Map<String, String>, session: Long) {
        val nsd = app.getSystemService(Context.NSD_SERVICE) as NsdManager
        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(info: NsdServiceInfo) {
                val registration = this
                worker.post {
                    if (session != generation) runCatching { nsd.unregisterService(registration) }
                    else if (++registeredServices == 2) state = "ready"
                }
            }
            override fun onServiceUnregistered(info: NsdServiceInfo) {}
            override fun onRegistrationFailed(info: NsdServiceInfo, code: Int) { worker.post { if (session == generation) { state = "failed"; error = "AirPlay receiver unavailable" } } }
            override fun onUnregistrationFailed(info: NsdServiceInfo, code: Int) {}
        }
        registrations.add(listener)
        runCatching {
            nsd.registerService(NsdServiceInfo().also { info -> info.serviceName = name; info.serviceType = type; info.port = port; txt.forEach { (k,v) -> info.setAttribute(k,v) } }, NsdManager.PROTOCOL_DNS_SD, listener)
        }.onFailure { state = "failed"; error = "AirPlay receiver unavailable" }
    }
    fun poll(): String = mirror.frame().put("active", active).put("state", state).put("pin", pin).put("receiver_error", error).put("foreground", foreground).toString()
    fun attach(epoch: Long, texture: Int): Boolean = active == epoch && mirror.attach(epoch, texture)
    fun attachLayer(epoch: Long, surface: Surface, slot: Int, width: Int, height: Int): Boolean = active == epoch && mirror.attachLayer(epoch, surface, slot, width, height)
    fun detachLayer(epoch: Long): Boolean = mirror.detachAndWait(epoch)
    fun suspend(epoch: Long): Boolean = mirror.detachAndWait(epoch, keepSession = true)
    fun disconnect(epoch: Long) { worker.post { if (active == epoch) restart() } }
    fun muted(value: Boolean) { mirror.muted = value }
    private fun stop() {
        haltMirror()
        ++generation
        val id = active; active = 0; pin = ""
        if (id > 0) mirror.detach(id)
        context()?.let { app ->
            val nsd = app.getSystemService(Context.NSD_SERVICE) as NsdManager
            registrations.forEach { runCatching { nsd.unregisterService(it) } }
        }
        registrations.clear()
        context()?.let { AirplayReceiverService.active(it, false) }
        if (handle != 0L) { AirplayNative.stop(handle); handle = 0 }
        if (state !in listOf("unavailable", "failed")) state = "off"
    }
    fun close() { haltMirror(); context()?.let { AirplayReceiverService.end(it) }; worker.post { wanted = false; stop(); mirror.close(); thread.quitSafely() } }
}
