package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.net.Inet4Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.ServerSocket
import java.net.Socket
import java.security.SecureRandom
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

/** Temporary browser-library LAN access, optionally paired. Based on DiagnosticLogs' local socket lifecycle.
 * Assets are local; no Gecko session or external website is loaded by this server.
 */
internal class WebBookmarkShare(
    private val asset: (String) -> ByteArray,
    private val handle: (JSONObject, () -> Boolean) -> JSONObject,
    private val address: () -> InetAddress = { wifiAddress() },
    private val port: Int = 8791,
    private val durationMs: Long = 30 * 60 * 1000L,
    private val now: () -> Long = { System.nanoTime() / 1_000_000 },
    private val onStop: () -> Unit = {}
) : AutoCloseable {
    companion object {
        private fun wifiAddress(): InetAddress = NetworkInterface.getNetworkInterfaces().toList()
            .filter { it.isUp && !it.isLoopback }
            .sortedBy { if (it.name.startsWith("wlan")) 0 else 1 }
            .flatMap { it.inetAddresses.toList() }
            .firstOrNull { it is Inet4Address && it.isSiteLocalAddress } ?: error("no_wifi")
    }
    private class Session(val socket: ServerSocket, val authority: String, val pin: String, val token: String, val until: Long) {
        var attempts = 0
        var retryAt = 0L
        val clients = ConcurrentHashMap.newKeySet<Socket>()
        val workers = ThreadPoolExecutor(2, 2, 0, TimeUnit.SECONDS, ArrayBlockingQueue<Runnable>(8),
            { runnable -> Thread(runnable, "BookmarkClient").apply { isDaemon = true } })
    }
    private val random = SecureRandom()
    @Volatile private var session: Session? = null
    @Volatile private var lastError = ""
    private fun alive(s: Session) = session === s && !s.socket.isClosed && now() < s.until

    @Synchronized fun start(requireCode: Boolean = false): String {
        session?.let { if (alive(it)) return "" }
        close()
        var socket: ServerSocket? = null
        return try {
            val ip = address()
            socket = ServerSocket().apply { reuseAddress = true }
            socket.bind(InetSocketAddress(ip, port), 8)
            // Fail before opening access if packaging is incomplete.
            for (path in listOf("bookmark-remote/index.html", "bookmark-remote/app.js", "bookmark-remote/style.css", "translations.json")) asset(path)
            val alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ"
            val code = if (requireCode) (1..4).map { alphabet[random.nextInt(alphabet.length)] }.joinToString("") else ""
            val token = ByteArray(32).also(random::nextBytes).joinToString("") { "%02x".format(it.toInt() and 255) }
            val s = Session(socket, "${ip.hostAddress}:${socket.localPort}", code, token, now() + durationMs)
            session = s; lastError = ""
            thread(name = "BookmarkShare", isDaemon = true) {
                while (alive(s)) {
                    val client = runCatching { s.socket.accept() }.getOrNull() ?: break
                    s.clients.add(client)
                    try { s.workers.execute { try { serve(s, client) } finally { s.clients.remove(client); runCatching { client.close() } } } }
                    catch (_: java.util.concurrent.RejectedExecutionException) { s.clients.remove(client); client.close() }
                }
            }
            thread(name = "BookmarkExpiry", isDaemon = true) {
                // Bounded wait also notices a network change and retires the old advertised address.
                while (alive(s)) {
                    Thread.sleep(minOf(1000L, durationMs))
                    if (runCatching { address() != ip }.getOrDefault(true)) break
                }
                synchronized(this) { if (session === s) close() }
            }
            ""
        } catch (_: Exception) {
            runCatching { socket?.close() }; lastError = "share_unavailable"; lastError
        }
    }
    fun status(): JSONObject {
        val s = session
        return if (s != null && alive(s)) JSONObject().put("active", true).put("url", "http://${s.authority}")
            .put("code", s.pin).put("requires_code", s.pin.isNotEmpty()).put("seconds", ((s.until - now()) / 1000).coerceAtLeast(0))
        else JSONObject().put("active", false).put("error", lastError)
    }
    @Synchronized override fun close() {
        val s = session; session = null; lastError = ""
        if (s != null) {
            runCatching { s.socket.close() }; s.clients.forEach { runCatching { it.close() } }
            s.workers.shutdownNow()
            onStop()
        }
    }
    private fun line(input: InputStream): String {
        val out = ByteArrayOutputStream()
        while (out.size() < 8192) {
            val c = input.read(); if (c < 0) error("eof")
            if (c == 10) return out.toString("US-ASCII").trimEnd('\r')
            out.write(c)
        }
        error("header")
    }
    private fun serve(s: Session, client: Socket) {
        try {
            client.soTimeout = 5000
            val input = client.getInputStream().buffered()
            val first = line(input).split(' ')
            require(first.size == 3 && first[2] == "HTTP/1.1")
            val headers = mutableMapOf<String, String>()
            var total = 0
            while (true) {
                val value = line(input); if (value.isEmpty()) break
                total += value.length; require(total <= 16384 && headers.size < 40)
                require(value.contains(':'))
                val key = value.substringBefore(':').lowercase()
                require(!headers.containsKey(key)); headers[key] = value.substringAfter(':').trim()
            }
            if (!alive(s)) { reply(client, 410); return }
            // Exact Host prevents DNS rebinding. No CORS; mutation requires same-origin JSON.
            if (headers["host"] != s.authority || headers.containsKey("transfer-encoding") ||
                headers["origin"]?.let { it != "http://${s.authority}" } == true ||
                headers["sec-fetch-site"] == "cross-site") { reply(client, 403); return }
            val path = first[1]
            if (first[0] == "GET") {
                val entry = when (path) {
                    "/" -> "bookmark-remote/index.html" to "text/html"
                    "/app.js" -> "bookmark-remote/app.js" to "text/javascript"
                    "/style.css" -> "bookmark-remote/style.css" to "text/css"
                    "/translations.json" -> "translations.json" to "application/json"
                    else -> null
                }
                if (entry == null) reply(client, 404) else reply(client, 200, asset(entry.first), entry.second)
                return
            }
            if (first[0] != "POST" || path !in setOf("/pair", "/api")) { reply(client, 404); return }
            if (headers["content-type"]?.substringBefore(';') != "application/json") { reply(client, 415); return }
            val length = headers["content-length"]?.toIntOrNull() ?: 0
            if (length !in 1..(2 * 1024 * 1024) || (path == "/pair" && length > 128)) { reply(client, 413); return }
            val body = ByteArray(length)
            var read = 0
            while (read < length) { val count = input.read(body, read, length - read); require(count > 0); read += count }
            val request = JSONObject(body.toString(Charsets.UTF_8))
            if (path == "/pair") {
                synchronized(s) {
                    if (!alive(s)) { reply(client, 410); return }
                    if (now() < s.retryAt) { reply(client, 429); return }
                    // Empty bootstrap requests discover optional pairing without consuming attempts.
                    if (s.pin.isNotEmpty() && request.optString("code").isEmpty()) { reply(client, 401); return }
                    if (s.pin.isNotEmpty() && request.optString("code").trim().uppercase(java.util.Locale.ROOT) != s.pin) {
                        if (++s.attempts >= 5) { s.retryAt = now() + 60_000; s.attempts = 0 }
                        reply(client, 401); return
                    }
                    s.attempts = 0
                    reply(client, 200, JSONObject().put("token", s.token).toString().toByteArray())
                }
                return
            }
            val token = headers["authorization"]?.removePrefix("Bearer ")
            if (token != s.token) { reply(client, 401); return }
            if (request.optString("action") == "stop_share") {
                reply(client, 200)
                synchronized(this) { if (session === s) close() }
                return
            }
            val result = handle(request) { alive(s) }
            if (!alive(s)) { reply(client, 410); return }
            reply(client, if (result.has("error")) 409 else 200, result.toString().toByteArray(Charsets.UTF_8))
        } catch (_: Exception) { runCatching { reply(client, 400) } }
    }
    private fun reply(client: Socket, status: Int, bytes: ByteArray = "{}".toByteArray(), type: String = "application/json") {
        val header = "HTTP/1.1 $status Response\r\nContent-Type: $type; charset=utf-8\r\nContent-Length: ${bytes.size}\r\n" +
            "Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\n" +
            "Content-Security-Policy: default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'\r\n" +
            "Connection: close\r\n\r\n"
        client.getOutputStream().apply { write(header.toByteArray(Charsets.US_ASCII)); write(bytes); flush() }
    }
}
