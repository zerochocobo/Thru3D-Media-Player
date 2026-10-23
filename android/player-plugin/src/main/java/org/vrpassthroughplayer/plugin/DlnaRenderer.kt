package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.net.InetAddress
import java.net.URI
import java.util.ArrayDeque
import javax.xml.parsers.DocumentBuilderFactory

/** Protocol state only. Playback is owned by Godot; transport IDs never alias MPV generations. */
internal class DlnaRenderer(private val now: () -> Long = System::currentTimeMillis) {
    data class Offer(val id: Long, val peer: String, val uri: String, val metadata: String, val title: String,
                     var requested: Boolean = false, var start: Long = 0, val expires: Long)
    class Fault(val code: Int, override val message: String) : Exception(message)
    private var serial = 0L
    private var pending: Offer? = null
    private var active: Offer? = null
    private val events = ArrayDeque<JSONObject>()
    private var state = "NO_MEDIA_PRESENT"
    private var position = 0L
    private var duration = 0L
    private var seekable = false
    private var volume = 50
    private var muted = false
    private var error = false
    private fun enqueue(value: JSONObject) {
        if (events.size >= 64) throw Fault(501, "Action Failed")
        events.addLast(value)
    }
    private fun event(action: String, offer: Offer) = JSONObject().put("action", action).put("token", offer.id)
    private fun expire() {
        val offer = pending ?: return
        if (now() >= offer.expires) { pending = null; events.removeIf { it.optLong("token") == offer.id } }
    }
    @Synchronized fun poll(): JSONObject {
        expire()
        val batch = JSONArray()
        while (events.isNotEmpty()) batch.put(events.removeFirst())
        return JSONObject().put("events", batch).put("pending_token", pending?.id ?: 0).put("active_token", active?.id ?: 0)
    }
    /** Acknowledge only after the headset user grants replacement. Returns current queued seek. */
    @Synchronized fun accept(id: Long): JSONObject {
        expire()
        val offer = pending?.takeIf { it.id == id && it.requested } ?: return JSONObject()
        active = offer; pending = null; state = "TRANSITIONING"; position = offer.start
        duration = 0; seekable = false; error = false
        return offerJson(offer)
    }
    @Synchronized fun reject(id: Long) {
        if (pending?.id == id) pending = null
        events.removeIf { it.optLong("token") == id }
    }
    @Synchronized fun detach() {
        pending = null; active = null; events.clear(); state = "NO_MEDIA_PRESENT"
        position = 0; duration = 0; seekable = false; error = false
    }
    /** Ends only the given active cast. A newer pending offer (Stop → SetAVTransportURI → Play) survives. */
    @Synchronized fun finish(id: Long) {
        if (active?.id != id) return
        active = null; events.removeIf { it.optLong("token") == id }
        state = "NO_MEDIA_PRESENT"; position = 0; duration = 0; seekable = false; error = false
    }
    @Synchronized fun publish(json: JSONObject) {
        if (json.optLong("token") != active?.id) return
        state = json.optString("state").takeIf { it in setOf("PLAYING", "PAUSED_PLAYBACK", "STOPPED", "TRANSITIONING") } ?: "STOPPED"
        position = json.optLong("position_ms").coerceAtLeast(0)
        duration = json.optLong("duration_ms").coerceAtLeast(0)
        seekable = json.optBoolean("seekable")
        volume = json.optInt("volume", volume).coerceIn(0, 100); muted = json.optBoolean("muted", muted)
        error = json.optBoolean("error")
    }
    private fun offerJson(o: Offer) = event("request", o).put("uri", o.uri).put("title", o.title).put("start_ms", o.start)
    private fun owned(peer: String): Offer {
        expire()
        val offer = pending ?: active ?: throw Fault(701, "Transition not available")
        if (offer.peer != peer) throw Fault(701, "Transition not available")
        return offer
    }
    @Synchronized fun action(service: String, action: String, args: Map<String, String>, peer: String): Map<String, String> {
        expire()
        if (service != "ConnectionManager" && args["InstanceID"] != "0") throw Fault(718, "Invalid InstanceID")
        if (service == "RenderingControl" && action != "ListPresets" && args["Channel"] != "Master") throw Fault(402, "Invalid Args")
        val offer = pending ?: active
        val mediaDuration = if (pending != null) 0 else duration
        val mediaPosition = pending?.start ?: position
        val transport = if (pending != null) (if (pending!!.requested) "TRANSITIONING" else "STOPPED") else state
        when ("$service/$action") {
            "AVTransport/SetAVTransportURI" -> {
                val uri = args["CurrentURI"].orEmpty()
                if (!validUri(uri)) throw Fault(716, "Resource not found")
                val metadata = args["CurrentURIMetaData"].orEmpty()
                if (metadata.length > 32768) throw Fault(402, "Invalid Args")
                // A different controller may offer media, but cannot take transport ownership before acceptance.
                if (pending != null && pending!!.peer != peer) throw Fault(701, "Transition not available")
                pending?.let { old -> events.removeIf { it.optLong("token") == old.id } }
                val title = if (metadata.isBlank()) null else runCatching { xml(metadata).getElementsByTagNameNS("*", "title").item(0)?.textContent }.getOrNull()
                pending = Offer(++serial, peer, uri, metadata, title?.take(256)?.takeIf { it.isNotBlank() } ?: "Cast video", expires = now() + 60000)
            }
            "AVTransport/Play" -> {
                if (args["Speed"] != "1") throw Fault(717, "Play speed not supported")
                val target = owned(peer)
                if (target === pending) {
                    if (!target.requested) { enqueue(offerJson(target)); target.requested = true }
                } else enqueue(event("play", target))
            }
            "AVTransport/Pause", "AVTransport/Stop" -> {
                // Controllers commonly send Stop before their first SetAVTransportURI.
                if (action == "Stop" && offer == null) return emptyMap()
                val target = owned(peer)
                if (target === pending) reject(target.id)
                else enqueue(event(if (action == "Stop") "stop" else "pause", target))
            }
            "AVTransport/Seek" -> {
                // One track per transport: absolute and relative time are the same position.
                if (args["Unit"] !in setOf("REL_TIME", "ABS_TIME")) throw Fault(710, "Seek mode not supported")
                val target = owned(peer)
                val ms = parseTime(args["Target"].orEmpty()) ?: throw Fault(711, "Illegal seek target")
                if (target === pending) target.start = ms
                else {
                    if (!seekable || (duration > 0 && ms > duration)) throw Fault(711, "Illegal seek target")
                    enqueue(event("seek", target).put("position_ms", ms))
                }
            }
            "RenderingControl/SetVolume", "RenderingControl/SetMute" -> {
                val target = owned(peer)
                if (target === pending) throw Fault(701, "Transition not available")
                if (action == "SetVolume") {
                    val value = args["DesiredVolume"]?.toIntOrNull()?.takeIf { it in 0..100 } ?: throw Fault(402, "Invalid Args")
                    enqueue(event("volume", target).put("value", value))
                } else {
                    val value = args["DesiredMute"]?.lowercase()
                    if (value !in setOf("0", "1", "true", "false")) throw Fault(402, "Invalid Args")
                    enqueue(event("mute", target).put("value", value in setOf("1", "true")))
                }
            }
            "AVTransport/GetTransportInfo" -> return mapOf("CurrentTransportState" to transport, "CurrentTransportStatus" to if (error) "ERROR_OCCURRED" else "OK", "CurrentSpeed" to "1")
            "AVTransport/GetPositionInfo" -> return mapOf("Track" to if (offer == null) "0" else "1", "TrackDuration" to time(mediaDuration), "TrackMetaData" to offer?.metadata.orEmpty(), "TrackURI" to offer?.uri.orEmpty(), "RelTime" to time(mediaPosition), "AbsTime" to time(mediaPosition), "RelCount" to "2147483647", "AbsCount" to "2147483647")
            "AVTransport/GetMediaInfo" -> return mapOf("NrTracks" to if (offer == null) "0" else "1", "MediaDuration" to time(mediaDuration), "CurrentURI" to offer?.uri.orEmpty(), "CurrentURIMetaData" to offer?.metadata.orEmpty(), "NextURI" to "", "NextURIMetaData" to "", "PlayMedium" to "NETWORK", "RecordMedium" to "NOT_IMPLEMENTED", "WriteStatus" to "NOT_IMPLEMENTED")
            "AVTransport/GetDeviceCapabilities" -> return mapOf("PlayMedia" to "NETWORK", "RecMedia" to "NOT_IMPLEMENTED", "RecQualityModes" to "NOT_IMPLEMENTED")
            "AVTransport/GetTransportSettings" -> return mapOf("PlayMode" to "NORMAL", "RecQualityMode" to "NOT_IMPLEMENTED")
            "AVTransport/GetCurrentTransportActions" -> return mapOf("Actions" to if (offer == null) "" else "Play,Pause,Stop" + if (seekable) ",Seek" else "")
            "RenderingControl/GetVolume" -> return mapOf("CurrentVolume" to volume.toString())
            "RenderingControl/GetMute" -> return mapOf("CurrentMute" to if (muted) "1" else "0")
            "RenderingControl/ListPresets" -> return mapOf("CurrentPresetNameList" to "FactoryDefaults")
            "ConnectionManager/GetProtocolInfo" -> return mapOf("Source" to "", "Sink" to PROTOCOLS)
            "ConnectionManager/GetCurrentConnectionIDs" -> return mapOf("ConnectionIDs" to "0")
            "ConnectionManager/GetCurrentConnectionInfo" -> {
                if (args["ConnectionID"] != "0") throw Fault(706, "Invalid connection reference")
                return mapOf("RcsID" to "0", "AVTransportID" to "0", "ProtocolInfo" to "", "PeerConnectionManager" to "", "PeerConnectionID" to "-1", "Direction" to "Input", "Status" to "OK")
            }
            else -> throw Fault(401, "Invalid Action")
        }
        return emptyMap()
    }
    @Synchronized fun eventBody(service: String): String {
        expire()
        val o = pending ?: active
        val values = if (service == "RenderingControl") "<Volume channel=\"Master\" val=\"$volume\"/><Mute channel=\"Master\" val=\"${if (muted) 1 else 0}\"/>"
        else "<TransportState val=\"${if (pending != null) (if (pending!!.requested) "TRANSITIONING" else "STOPPED") else state}\"/><TransportStatus val=\"${if (error) "ERROR_OCCURRED" else "OK"}\"/><AVTransportURI val=\"${escape(o?.uri.orEmpty())}\"/><CurrentTrackURI val=\"${escape(o?.uri.orEmpty())}\"/><CurrentTrackDuration val=\"${time(duration)}\"/><CurrentTransportActions val=\"${if (o == null) "" else "Play,Pause,Stop" + if (seekable) ",Seek" else ""}\"/>"
        val property = if (service == "ConnectionManager") "<SourceProtocolInfo/></e:property><e:property><SinkProtocolInfo>${escape(PROTOCOLS)}</SinkProtocolInfo></e:property><e:property><CurrentConnectionIDs>0</CurrentConnectionIDs>"
        else "<LastChange>${escape("<Event xmlns=\"urn:schemas-upnp-org:metadata-1-0/${if (service == "RenderingControl") "RCS" else "AVT"}/\"><InstanceID val=\"0\">$values</InstanceID></Event>")}</LastChange>"
        return "<e:propertyset xmlns:e=\"urn:schemas-upnp-org:event-1-0\"><e:property>$property</e:property></e:propertyset>"
    }
    companion object {
        val PROTOCOLS = listOf("video/mp4", "video/x-matroska", "video/webm", "video/mpeg", "video/mp2t", "application/vnd.apple.mpegurl", "application/x-mpegURL").joinToString(",") { "http-get:*:$it:*" }
        fun escape(s: String) = s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;").replace("'", "&apos;")
        fun validUri(s: String): Boolean = s.length in 1..8192 && runCatching {
            val u = URI(s)
            u.scheme in setOf("http", "https") && !u.host.isNullOrBlank() && u.userInfo == null && u.fragment == null && u.port in -1..65535 && u.port != 0 && !headsetLocal(u.host)
        }.getOrDefault(false)
        /** A LAN sender must not make the headset fetch its own local services (OpenList, players). No DNS lookups. */
        private fun headsetLocal(host: String): Boolean {
            val name = host.lowercase().trimEnd('.')
            if (name == "localhost" || name.endsWith(".localhost")) return true
            val dotted = Regex("\\d{1,3}(\\.\\d{1,3}){3}").matches(name)
            // Short/decimal/hex IPv4 forms (127.1, 2130706433, 0x7f.1) still resolve; refuse them.
            if (!dotted && name.split('.').all { Regex("0x[0-9a-f]*|\\d+").matches(it) }) return true
            if (!dotted && !name.startsWith("[")) return false
            val address = InetAddress.getByName(name.removeSurrounding("[", "]"))
            return address.isLoopbackAddress || address.isAnyLocalAddress || address.isLinkLocalAddress
        }
        fun time(ms: Long): String { val s = ms.coerceAtLeast(0) / 1000; return "%02d:%02d:%02d".format(java.util.Locale.ROOT, s / 3600, s / 60 % 60, s % 60) }
        fun parseTime(s: String): Long? {
            val m = Regex("(\\d{1,3}):([0-5]\\d):([0-5]\\d)(?:\\.\\d{1,3})?").matchEntire(s) ?: return null
            return ((m.groupValues[1].toLong() * 3600 + m.groupValues[2].toLong() * 60 + m.groupValues[3].toLong()) * 1000).takeIf { it <= Int.MAX_VALUE }
        }
        fun xml(s: String): org.w3c.dom.Document {
            require(s.length <= 65536 && !s.contains("<!DOCTYPE", true) && !s.contains("<!ENTITY", true))
            val factory = DocumentBuilderFactory.newInstance().apply { isNamespaceAware = true; isExpandEntityReferences = false
                // Android's parser does not expose all Xerces features. The lexical DTD/entity
                // rejection above and resolver below remain mandatory on every implementation.
                runCatching { setFeature("http://apache.org/xml/features/disallow-doctype-decl", true) }
                runCatching { setFeature("http://xml.org/sax/features/external-general-entities", false) }
                runCatching { setFeature("http://xml.org/sax/features/external-parameter-entities", false) }
            }
            return factory.newDocumentBuilder().apply {
                setEntityResolver { _, _ -> throw org.xml.sax.SAXException("External entities disabled") }
                setErrorHandler(object : org.xml.sax.helpers.DefaultHandler() {
                    override fun error(e: org.xml.sax.SAXParseException) { throw e }
                    override fun fatalError(e: org.xml.sax.SAXParseException) { throw e }
                })
            }.parse(ByteArrayInputStream(s.toByteArray(Charsets.UTF_8)))
        }
    }
}
