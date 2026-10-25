package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import java.io.BufferedInputStream
import java.net.*
import java.util.UUID
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/** Foreground-only LAN receiver. Bounded HTTP workers, SOAP bodies, subscriptions and command queue. */
internal class DlnaReceiver(val udn: String, val name: String = "Thru3D", val renderer: DlnaRenderer = DlnaRenderer()) : AutoCloseable {
    private val running = AtomicBoolean(false)
    private val workers = ThreadPoolExecutor(3, 3, 0, TimeUnit.SECONDS, ArrayBlockingQueue<Runnable>(8))
    private val timer = Executors.newSingleThreadScheduledExecutor()
    // GENA callbacks can block for their timeouts; keep them off the SSDP announce timer.
    private val notifier = Executors.newSingleThreadScheduledExecutor()
    private val connections = ConcurrentHashMap.newKeySet<Socket>()
    @Volatile private var server: ServerSocket? = null
    @Volatile private var multicast: MulticastSocket? = null
    private var network: NetworkInterface? = null
    @Volatile var address = ""; private set
    @Volatile var failure = ""; private set
    val port: Int get() = server?.localPort ?: 0
    private data class Subscription(val sid: String, val service: String, val peer: String, val callback: URL,
                                    @Volatile var expires: Long, @Volatile var sequence: Long = 0, @Volatile var previous: String = "")
    private val subscriptions = ConcurrentHashMap<String, Subscription>()
    private val targets get() = listOf("upnp:rootdevice", udn, "urn:schemas-upnp-org:device:MediaRenderer:1") + SERVICES.map { serviceType(it) }
    /** [preferredPort] keeps a controller's cached control URL valid when the app returns to the foreground. */
    fun start(bind: InetAddress? = null, discovery: Boolean = true, preferredPort: Int = 0) {
        if (!running.compareAndSet(false, true)) return
        Thread({
            try {
                val selected = bind ?: NetworkInterface.getNetworkInterfaces().toList().filter { it.isUp && !it.isLoopback }
                    .sortedBy { if (it.name.startsWith("wlan") || it.name.startsWith("wifi")) 0 else 1 }
                    .flatMap { it.inetAddresses.toList() }.firstOrNull { it is Inet4Address && it.isSiteLocalAddress }
                    ?: throw IllegalStateException("No local network")
                address = selected.hostAddress!!
                network = NetworkInterface.getByInetAddress(selected)
                val listener = ServerSocket().apply {
                    reuseAddress = true; soTimeout = 1000
                    try { bind(InetSocketAddress(selected, preferredPort)) } catch (e: java.io.IOException) { if (preferredPort == 0) throw e; bind(InetSocketAddress(selected, 0)) }
                }
                server = listener
                if (!running.get()) { listener.close(); return@Thread }
                if (discovery) {
                    val socket = MulticastSocket(null).apply {
                        reuseAddress = true; bind(InetSocketAddress(1900)); soTimeout = 1000; timeToLive = 2
                        networkInterface = network
                        joinGroup(InetSocketAddress(GROUP, 1900), network)
                    }
                    multicast = socket
                    Thread({ discover(socket) }, "Thru3D-SSDP").apply { isDaemon = true; start() }
                    announce("ssdp:alive")
                }
                timer.scheduleWithFixedDelay({ runCatching { announce("ssdp:alive") } }, 30, 30, TimeUnit.SECONDS)
                notifier.scheduleWithFixedDelay({ runCatching { notifySubscribers() } }, 0, 500, TimeUnit.MILLISECONDS)
                while (running.get()) {
                    val client = try { listener.accept() } catch (_: SocketTimeoutException) { continue }
                    connections.add(client)
                    try { workers.execute { client.use { handle(it) }; connections.remove(client) } }
                    catch (_: java.util.concurrent.RejectedExecutionException) { connections.remove(client); client.close() }
                }
            } catch (_: Exception) {
                if (running.get()) failure = "DLNA receiver unavailable"
            } finally { close() }
        }, "Thru3D-DLNA").apply { isDaemon = true; start() }
    }
    fun status(): JSONObject = renderer.poll().put("running", running.get() && port > 0 && failure.isEmpty())
        .put("name", name).put("address", address).put("error", failure)
    /** Stops networking only. Cast state lives in [renderer] and is detached by the owner. */
    override fun close() {
        val socket = multicast; multicast = null
        val wasRunning = running.getAndSet(false)
        // The plugin closes from Android's main thread, where StrictMode rejects network I/O.
        if (socket != null) Thread({ if (wasRunning) runCatching { announce("ssdp:byebye", socket) }; runCatching { socket.close() } }, "Thru3D-SSDP-bye").apply { isDaemon = true; start() }
        runCatching { server?.close() }
        connections.forEach { runCatching { it.close() } }; connections.clear()
        subscriptions.clear(); timer.shutdownNow(); notifier.shutdownNow(); workers.shutdownNow()
    }
    private fun usn(target: String) = if (target == udn) udn else "$udn::$target"
    private fun announce(kind: String, socket: MulticastSocket? = multicast) {
        socket ?: return
        for (target in targets) {
            val text = "NOTIFY * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nNT: $target\r\nNTS: $kind\r\nUSN: ${usn(target)}\r\nCACHE-CONTROL: max-age=90\r\nLOCATION: http://$address:$port/device.xml\r\nSERVER: Android/1.0 UPnP/1.0 Thru3D/1.0\r\n\r\n"
            val bytes = text.toByteArray(); socket.send(DatagramPacket(bytes, bytes.size, GROUP, 1900))
        }
    }
    private fun discover(socket: MulticastSocket) {
        val buffer = ByteArray(4096)
        var window = 0L; var count = 0
        while (running.get()) {
            try {
                val packet = DatagramPacket(buffer, buffer.size); socket.receive(packet)
                val message = String(packet.data, 0, packet.length, Charsets.UTF_8)
                if (!message.startsWith("M-SEARCH * HTTP/1.1\r\n")) continue
                val headers = message.split("\r\n").drop(1).filter { it.contains(':') }.associate { it.substringBefore(':').lowercase() to it.substringAfter(':').trim() }
                if (headers["man"]?.trim('"') != "ssdp:discover") continue
                val now = System.currentTimeMillis()
                if (now - window > 1000) { window = now; count = 0 }
                if (++count > 12) continue
                val st = headers["st"] ?: continue
                for (target in targets.filter { st == "ssdp:all" || it == st }) {
                    val response = "HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=90\r\nEXT:\r\nLOCATION: http://$address:$port/device.xml\r\nSERVER: Android/1.0 UPnP/1.0 Thru3D/1.0\r\nST: $target\r\nUSN: ${usn(target)}\r\n\r\n".toByteArray()
                    // One unreachable searcher must not stop discovery for everyone else.
                    try { socket.send(DatagramPacket(response, response.size, packet.address, packet.port)) } catch (_: java.io.IOException) { break }
                }
            } catch (_: SocketTimeoutException) { /* bounded shutdown wait */ }
            catch (_: Exception) {
                if (running.get() && !socket.isClosed) { Thread.sleep(50); continue }
                if (running.get()) { failure = "DLNA discovery unavailable"; close() }
                return
            }
        }
    }
    private fun handle(client: Socket) {
        try {
            client.soTimeout = 3000
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
            fun remaining() { require(System.nanoTime() < deadline) }
            val input = BufferedInputStream(client.getInputStream())
            fun line(): String {
                val bytes = java.io.ByteArrayOutputStream()
                while (bytes.size() < 8192) { remaining(); val c = input.read(); if (c < 0) throw IllegalArgumentException(); if (c == 10) return bytes.toString("UTF-8").trimEnd('\r'); bytes.write(c) }
                throw IllegalArgumentException()
            }
            val request = line().split(' ')
            require(request.size == 3 && request[2] in setOf("HTTP/1.1", "HTTP/1.0"))
            val headers = mutableMapOf<String, String>(); var total = 0
            while (true) { val row = line(); if (row.isEmpty()) break; total += row.length; require(total <= 16384 && row.contains(':'))
                // Framing headers must be unambiguous; other repeats keep their first value.
                val key = row.substringBefore(':').lowercase(); if (headers.containsKey(key)) { require(key != "content-length"); continue }
                headers[key] = row.substringAfter(':').trim() }
            require(!headers.containsKey("transfer-encoding"))
            val length = headers["content-length"]?.toIntOrNull() ?: if (headers.containsKey("content-length")) -1 else 0
            require(length in 0..65536)
            val payload = ByteArray(length); var offset = 0
            while (offset < length) { remaining(); val n = input.read(payload, offset, length - offset); require(n > 0); offset += n }
            val path = request[1]; val method = request[0]; val peer = client.inetAddress.hostAddress!!
            if (method == "GET" && path == "/device.xml") { respond(client, 200, description()); return }
            val service = SERVICES.firstOrNull { path == "/$it.xml" || path == "/$it/control" || path == "/$it/event" }
            if (service == null) { respond(client, 404); return }
            if (method == "GET" && path == "/$service.xml") { respond(client, 200, scpd(service)); return }
            if (method in setOf("SUBSCRIBE", "UNSUBSCRIBE") && path == "/$service/event") { subscribe(client, service, method, headers, peer); return }
            if (method != "POST" || path != "/$service/control") { respond(client, 405); return }
            try {
                val soap = headers["soapaction"].orEmpty().trim('"').split('#')
                if (soap.size != 2 || soap[0] != serviceType(service)) throw DlnaRenderer.Fault(401, "Invalid Action")
                val document = DlnaRenderer.xml(String(payload, Charsets.UTF_8))
                val body = document.getElementsByTagNameNS("http://schemas.xmlsoap.org/soap/envelope/", "Body")
                if (body.length != 1) throw DlnaRenderer.Fault(402, "Invalid Args")
                val element = (0 until body.item(0).childNodes.length).map { body.item(0).childNodes.item(it) }.filter { it.nodeType == org.w3c.dom.Node.ELEMENT_NODE }.singleOrNull()
                    ?: throw DlnaRenderer.Fault(402, "Invalid Args")
                if (element.localName != soap[1] || element.namespaceURI != soap[0]) throw DlnaRenderer.Fault(401, "Invalid Action")
                val args = mutableMapOf<String, String>()
                for (i in 0 until element.childNodes.length) { val child = element.childNodes.item(i); if (child.nodeType == org.w3c.dom.Node.ELEMENT_NODE) { if (args.put(child.localName, child.textContent) != null) throw DlnaRenderer.Fault(402, "Invalid Args") } }
                if (soap[1] !in actions(service).keys) throw DlnaRenderer.Fault(401, "Invalid Action")
                // Controllers add vendor arguments (Bilibili: SourceId, ExtendData) or omit optional
                // metadata. Pass only declared inputs; each action validates the values it needs.
                val declared = actions(service).getValue(soap[1]).filter { it.direction == "in" && args.containsKey(it.name) }.associate { it.name to args.getValue(it.name) }
                val result = renderer.action(service, soap[1], declared, peer).entries.joinToString("") { "<${it.key}>${DlnaRenderer.escape(it.value)}</${it.key}>" }
                respond(client, 200, envelope("<u:${soap[1]}Response xmlns:u=\"${soap[0]}\">$result</u:${soap[1]}Response>"))
            } catch (e: DlnaRenderer.Fault) { respond(client, 500, fault(e.code, e.message)) }
            catch (_: Exception) { respond(client, 500, fault(402, "Invalid Args")) }
        } catch (_: Exception) { runCatching { respond(client, 400) } }
    }
    private fun subscribe(client: Socket, service: String, method: String, headers: Map<String, String>, peer: String) {
        val sid = headers["sid"]
        if (sid != null) {
            val previous = subscriptions[sid]
            if (previous == null || previous.service != service || previous.peer != peer || previous.expires <= System.currentTimeMillis() || headers.containsKey("callback") || headers.containsKey("nt")) { respond(client, 412); return }
            if (method == "UNSUBSCRIBE") { subscriptions.remove(sid); respond(client, 200); return }
            previous.expires = System.currentTimeMillis() + 300000
            respond(client, 200, extra = "SID: $sid\r\nTIMEOUT: Second-300\r\n"); return
        }
        if (method != "SUBSCRIBE" || headers["nt"] != "upnp:event" || subscriptions.size >= 8) { respond(client, 412); return }
        val raw = headers["callback"].orEmpty()
        val callback = runCatching { URI(raw.removeSurrounding("<", ">")).toURL() }.getOrNull()
        // No DNS lookups or third-party callbacks: GENA must return to the requesting IPv4 controller.
        if (!raw.startsWith('<') || !raw.endsWith('>') || callback == null || callback.protocol != "http" || callback.host != peer || callback.userInfo != null || callback.ref != null || callback.port !in -1..65535 || callback.port == 0) { respond(client, 412); return }
        val id = "uuid:${UUID.randomUUID()}"
        respond(client, 200, extra = "SID: $id\r\nTIMEOUT: Second-300\r\n")
        subscriptions[id] = Subscription(id, service, peer, callback, System.currentTimeMillis() + 300000)
    }
    private fun notifySubscribers() {
        for ((id, s) in subscriptions) {
            if (s.expires < System.currentTimeMillis()) { subscriptions.remove(id); continue }
            val body = renderer.eventBody(s.service)
            if (body == s.previous) continue
            try {
                Socket().use { socket ->
                    socket.connect(InetSocketAddress(s.peer, if (s.callback.port < 0) 80 else s.callback.port), 500); socket.soTimeout = 500
                    val data = body.toByteArray(Charsets.UTF_8)
                    val target = s.callback.file.ifEmpty { "/" }
                    val header = "NOTIFY $target HTTP/1.1\r\nHOST: ${s.callback.authority}\r\nCONTENT-TYPE: text/xml; charset=\"utf-8\"\r\nNT: upnp:event\r\nNTS: upnp:propchange\r\nSID: $id\r\nSEQ: ${s.sequence}\r\nCONTENT-LENGTH: ${data.size}\r\nCONNECTION: close\r\n\r\n"
                    socket.getOutputStream().apply { write(header.toByteArray()); write(data); flush() }
                    val input = socket.getInputStream()
                    val responseBytes = java.io.ByteArrayOutputStream()
                    val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(500)
                    while (responseBytes.size() < 512 && System.nanoTime() < deadline) {
                        val next = input.read(); if (next < 0 || next == 10) break; responseBytes.write(next)
                    }
                    val response = responseBytes.toString("US-ASCII")
                    if (!response.startsWith("HTTP/1.1 200") && !response.startsWith("HTTP/1.0 200")) throw IllegalStateException()
                }
                s.previous = body; s.sequence = if (s.sequence == 4294967295L) 1 else s.sequence + 1
            } catch (_: Exception) { subscriptions.remove(id) }
        }
    }
    private fun description(): String = "<?xml version=\"1.0\"?><root xmlns=\"urn:schemas-upnp-org:device-1-0\"><specVersion><major>1</major><minor>0</minor></specVersion><device><deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType><friendlyName>${DlnaRenderer.escape(name)}</friendlyName><manufacturer>Thru3D</manufacturer><modelName>Thru3D Player</modelName><UDN>$udn</UDN><serviceList>" + SERVICES.joinToString("") { "<service><serviceType>${serviceType(it)}</serviceType><serviceId>urn:upnp-org:serviceId:$it</serviceId><SCPDURL>/$it.xml</SCPDURL><controlURL>/$it/control</controlURL><eventSubURL>/$it/event</eventSubURL></service>" } + "</serviceList></device></root>"
    companion object {
        private val GROUP = InetAddress.getByName("239.255.255.250")
        val SERVICES = listOf("AVTransport", "RenderingControl", "ConnectionManager")
        fun serviceType(service: String) = "urn:schemas-upnp-org:service:$service:1"
        fun envelope(body: String) = "<?xml version=\"1.0\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body>$body</s:Body></s:Envelope>"
        private fun fault(code: Int, message: String) = envelope("<s:Fault><faultcode>s:Client</faultcode><faultstring>UPnPError</faultstring><detail><UPnPError xmlns=\"urn:schemas-upnp-org:control-1-0\"><errorCode>$code</errorCode><errorDescription>${DlnaRenderer.escape(message)}</errorDescription></UPnPError></detail></s:Fault>")
        private fun respond(socket: Socket, code: Int, body: String = "", extra: String = "") {
            val bytes = body.toByteArray(Charsets.UTF_8)
            val reason = mapOf(200 to "OK", 400 to "Bad Request", 404 to "Not Found", 405 to "Method Not Allowed", 412 to "Precondition Failed", 500 to "Internal Server Error")[code]
            socket.getOutputStream().apply { write("HTTP/1.1 $code $reason\r\nContent-Type: text/xml; charset=\"utf-8\"\r\nContent-Length: ${bytes.size}\r\nConnection: close\r\n$extra\r\n".toByteArray()); write(bytes); flush() }
        }
        data class Argument(val name: String, val direction: String, val variable: String, val type: String = "string")
        fun actions(service: String): Map<String, List<Argument>> {
            fun arg(name: String, dir: String = "in", type: String = "string", variable: String = name) = Argument(name, dir, variable, type)
            val instance = arg("InstanceID", type = "ui4", variable = "A_ARG_TYPE_InstanceID")
            fun avt(vararg args: Argument) = listOf(instance) + args
            fun outputs(vararg names: String) = names.map { arg(it, "out") }
            return when (service) {
                "AVTransport" -> linkedMapOf(
                    "SetAVTransportURI" to avt(arg("CurrentURI", type = "uri", variable = "AVTransportURI"), arg("CurrentURIMetaData", variable = "AVTransportURIMetaData")),
                    "SetNextAVTransportURI" to avt(arg("NextURI", type = "uri", variable = "NextAVTransportURI"), arg("NextURIMetaData", variable = "NextAVTransportURIMetaData")),
                    "Next" to avt(), "Previous" to avt(),
                    "Play" to avt(arg("Speed", variable = "TransportPlaySpeed")), "Pause" to avt(), "Stop" to avt(),
                    "Seek" to avt(arg("Unit", variable = "A_ARG_TYPE_SeekMode"), arg("Target", variable = "A_ARG_TYPE_SeekTarget")),
                    "GetTransportInfo" to avt(arg("CurrentTransportState", "out", variable = "TransportState"), arg("CurrentTransportStatus", "out", variable = "TransportStatus"), arg("CurrentSpeed", "out", variable = "TransportPlaySpeed")),
                    "GetPositionInfo" to (avt(arg("Track", "out", "ui4", "CurrentTrack")) + outputs("TrackDuration", "TrackMetaData", "TrackURI", "RelTime", "AbsTime") + listOf(arg("RelCount", "out", "i4"), arg("AbsCount", "out", "i4"))),
                    "GetMediaInfo" to (avt(arg("NrTracks", "out", "ui4")) + outputs("MediaDuration", "CurrentURI", "CurrentURIMetaData") +
                        listOf(arg("NextURI", "out", "uri", "NextAVTransportURI"), arg("NextURIMetaData", "out", variable = "NextAVTransportURIMetaData")) + outputs("PlayMedium", "RecordMedium", "WriteStatus")),
                    "GetDeviceCapabilities" to (avt() + outputs("PlayMedia", "RecMedia", "RecQualityModes")),
                    "GetTransportSettings" to (avt() + outputs("PlayMode", "RecQualityMode")),
                    "GetCurrentTransportActions" to avt(arg("Actions", "out", variable = "CurrentTransportActions")))
                "RenderingControl" -> linkedMapOf(
                    "ListPresets" to avt(arg("CurrentPresetNameList", "out", variable = "PresetNameList")),
                    "GetVolume" to avt(arg("Channel", variable = "A_ARG_TYPE_Channel"), arg("CurrentVolume", "out", "ui2", "Volume")),
                    "SetVolume" to avt(arg("Channel", variable = "A_ARG_TYPE_Channel"), arg("DesiredVolume", type = "ui2", variable = "Volume")),
                    "GetMute" to avt(arg("Channel", variable = "A_ARG_TYPE_Channel"), arg("CurrentMute", "out", "boolean", "Mute")),
                    "SetMute" to avt(arg("Channel", variable = "A_ARG_TYPE_Channel"), arg("DesiredMute", type = "boolean", variable = "Mute")))
                else -> linkedMapOf(
                    "GetProtocolInfo" to listOf(arg("Source", "out", variable = "SourceProtocolInfo"), arg("Sink", "out", variable = "SinkProtocolInfo")),
                    "GetCurrentConnectionIDs" to listOf(arg("ConnectionIDs", "out", variable = "CurrentConnectionIDs")),
                    "GetCurrentConnectionInfo" to listOf(arg("ConnectionID", type = "i4"), arg("RcsID", "out", "i4"), arg("AVTransportID", "out", "i4"), arg("ProtocolInfo", "out"), arg("PeerConnectionManager", "out"), arg("PeerConnectionID", "out", "i4"), arg("Direction", "out"), arg("Status", "out")))
            }
        }
        fun scpd(service: String): String {
            val actions = actions(service)
            val list = actions.entries.joinToString("") { (name, args) -> "<action><name>$name</name><argumentList>" + args.joinToString("") { "<argument><name>${it.name}</name><direction>${it.direction}</direction><relatedStateVariable>${it.variable}</relatedStateVariable></argument>" } + "</argumentList></action>" }
            val variables = actions.values.flatten().distinctBy { it.variable }.joinToString("") {
                val evented = service == "ConnectionManager" && it.variable in listOf("SourceProtocolInfo", "SinkProtocolInfo", "CurrentConnectionIDs")
                "<stateVariable sendEvents=\"${if (evented) "yes" else "no"}\"><name>${it.variable}</name><dataType>${it.type}</dataType>" +
                    (if (it.variable == "Volume") "<allowedValueRange><minimum>0</minimum><maximum>100</maximum><step>1</step></allowedValueRange>" else "") + "</stateVariable>"
            } + if (service == "ConnectionManager") "" else "<stateVariable sendEvents=\"yes\"><name>LastChange</name><dataType>string</dataType></stateVariable>"
            return "<?xml version=\"1.0\"?><scpd xmlns=\"urn:schemas-upnp-org:service-1-0\"><specVersion><major>1</major><minor>0</minor></specVersion><actionList>$list</actionList><serviceStateTable>$variables</serviceStateTable></scpd>"
        }
    }
}
