package org.vrpassthroughplayer.plugin

import android.content.ContentValues
import android.content.Context
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.Inet4Address
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.ServerSocket
import java.net.Socket
import java.security.SecureRandom
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.Executors
import kotlin.concurrent.thread

/**
 * The diagnostic log a user can hand over: this app's own logcat (no permission is needed for its own
 * process), with media names, accounts and URL parameters masked. Saved to Download/Thru3D/logs or
 * served for a while on the headset's Wi-Fi address, since a headset has no share target to a phone.
 */
internal object DiagnosticLogs {
    private const val SHARE_MS = 10 * 60 * 1000L
    private const val PORT = 8790
    private val worker = Executors.newSingleThreadExecutor { Thread(it, "DiagnosticLogs").apply { isDaemon = true } }
    @Volatile private var server: ServerSocket? = null
    @Volatile private var shareUntil = 0L

    /** [action]: "save", "share", "stop" or "recent"; [header] goes on top of the log (versions, settings);
     * [full] keeps every line, otherwise periodic lines are thinned ([condense]).
     * Reports {"action", "ok", "path"|"url"+"expires_ms"|"lines", "error"} through [report]. */
    fun request(context: Context, action: String, header: String, full: Boolean, report: (JSONObject) -> Unit) {
        val app = context.applicationContext
        worker.execute {
            val result = JSONObject().put("action", action)
            try {
                when (action) {
                    "save" -> result.put("path", save(app, compose(header, full)))
                    "share" -> result.put("url", share(compose(header, full))).put("expires_ms", shareUntil)
                    "stop" -> stop()
                    "recent" -> result.put("lines", JSONArray(recent()))
                    else -> error("Unknown log action")
                }
                result.put("ok", true)
            } catch (failure: Throwable) {
                result.put("ok", false).put("error", failure.message ?: failure.javaClass.simpleName)
            }
            report(result)
        }
    }

    private fun logcat(vararg extra: String): String {
        val command = listOf("logcat", "-d", "-v", "threadtime", "--pid=${android.os.Process.myPid()}") + extra
        val process = ProcessBuilder(command).redirectErrorStream(true).start()
        val text = process.inputStream.bufferedReader().readText()
        process.waitFor()
        return text
    }

    private fun compose(header: String, full: Boolean): String = buildString {
        append("Thru3D diagnostic log ").append(SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US).format(Date())).append('\n')
        append("Device: ").append(Build.MANUFACTURER).append(' ').append(Build.MODEL)
            .append(" · Android ").append(Build.VERSION.RELEASE).append(" (API ").append(Build.VERSION.SDK_INT).append(")\n")
        append("Build: ").append(Build.FINGERPRINT).append('\n')
        append(redact(header)).append('\n')
        append(if (full) "Detail: full\n\n" else "Detail: compact (VrApi every 10 s and whenever frames, stale frames or free memory go wrong; " +
            "other periodic lines every 30 s; repeated messages merged)\n\n")
        val log = logcat("-t", "30000")
        append(redact(if (full) log else condense(log)))
    }

    // Per-second or per-frame lines that bury the rest: kept at intervals, or always when they show trouble.
    private val vrApi = Regex("""\bVrApi\s*: FPS=(\d+)/(\d+).*?Stale=(\d+).*?Free=(\d+)MB""")
    private val periodic = listOf("CCodecBufferChannel: no latch time", "BufferPoolAccessor", "ClientSharedTelemetryStats",
        "Mapping Android axis", "layer alpha draw", "OpenXR_GPUMemTrace")
    private val stamp = Regex("""^(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)\.\d+ +\d+ +\d+ """)

    /** Compact log: VrApi every 10 s, and every second below 90% of the target rate, with more than 3
     * stale frames or under 1 GB free; other periodic lines every 30 s; consecutive repeats merged. */
    fun condense(log: String): String {
        val out = StringBuilder()
        val lastKept = HashMap<String, Long>()
        var previous = ""
        var repeats = 0
        fun seconds(line: String): Long? = stamp.find(line)?.groupValues?.drop(1)?.map { it.toLong() }
            ?.let { (month, day, h, m, s) -> ((month * 31 + day) * 24 + h) * 3600 + m * 60 + s }
        fun keepEvery(key: String, line: String, interval: Long): Boolean {
            val now = seconds(line) ?: return true
            val last = lastKept[key]
            if (last != null && now - last < interval) return false
            lastKept[key] = now
            return true
        }
        fun flush() { if (repeats > 0) out.append("    (repeated ").append(repeats).append(" times)\n"); repeats = 0 }
        for (line in log.lineSequence()) {
            val message = stamp.find(line)?.let { line.substring(it.range.last + 1) } ?: line
            if (message.isNotEmpty() && message == previous) { repeats++; continue }
            flush()
            previous = message
            val fps = vrApi.find(line)
            val keep = if (fps != null) {
                val (shown, target, stale, free) = fps.destructured
                shown.toInt() < target.toInt() * 9 / 10 || stale.toInt() > 3 || free.toInt() < 1024 || keepEvery("VrApi", line, 10)
            } else periodic.firstOrNull { line.contains(it) }?.let { keepEvery(it, line, 30) } ?: true
            if (keep) out.append(line).append('\n')
        }
        flush()
        return out.toString()
    }

    /** Warnings and errors of this process, newest last, for reading in the headset. */
    private fun recent(): List<String> = logcat("-t", "4000", "*:W").lineSequence()
        .filter { it.length > 33 && !it.startsWith("-") }
        // Read in the headset: drop the date, time and process/thread numbers, keep level, tag and text.
        .map { line -> redact(stamp.find(line)?.let { line.substring(it.range.last + 1) } ?: line).replace(Regex(" {2,}"), " ").trim() }
        .toList().takeLast(40)

    private val mediaName = Regex("""([/\\])[^/\\\n"'<>]{1,200}\.(mp4|mkv|mov|avi|wmv|ts|m2ts|mts|iso|webm|flv|rmvb|m4v|jpg|jpeg|png|heic|heif|webp|gif|avif|avifs|apng|dng|cr2|cr3|nef|nrw|arw|raf|rw2|orf|pef|srw|hdr|rgbe|exr|bmp|tif|tiff|pdf|cbz|cbr|zip|rar|7z|srt|ass|ssa|vtt|sup|mp3|flac|wav|m4a|aac|ogg)\b""", RegexOption.IGNORE_CASE)
    private val credentials = Regex("""(\b[a-z][a-z0-9+.-]*://)[^/\s:@"']+(:[^/\s@"']*)?@""", RegexOption.IGNORE_CASE)
    private val query = Regex("""(\b[a-z][a-z0-9+.-]*://[^\s"'?#]*)\?[^\s"'#]*""", RegexOption.IGNORE_CASE)
    private val secretField = Regex("""("?\b(?:token|access_token|refresh_token|cookie|password|passwd|pwd|secret|authorization|sign|session|title|filename|file_name)"?\s*[:=]\s*)("[^"]*"|[^\s,;&}]+)""", RegexOption.IGNORE_CASE)
    private val email = Regex("""[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}""")

    /** Masks what identifies the user's media or accounts; keeps extensions, hosts and paths' shape. */
    fun redact(text: String): String = text
        .replace(credentials) { it.groupValues[1] + "***@" }
        .replace(query) { it.groupValues[1] + "?***" }
        .replace(secretField) { it.groupValues[1] + "***" }
        .replace(mediaName) { it.groupValues[1] + "***." + it.groupValues[2] }
        .replace(email, "***@***")

    private fun fileName() = "thru3d-log-" + SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(Date()) + ".txt"

    /** Download/Thru3D/logs/<name> (MediaStore, so no storage permission); the shown path. */
    private fun save(context: Context, text: String): String {
        val name = fileName()
        if (Build.VERSION.SDK_INT >= 29) {
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, name)
                put(MediaStore.MediaColumns.MIME_TYPE, "text/plain")
                put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + "/Thru3D/logs")
            }
            val resolver = context.contentResolver
            val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values) ?: error("Download folder unavailable")
            resolver.openOutputStream(uri)?.use { it.write(text.toByteArray()) } ?: error("Log file not writable")
            return Environment.DIRECTORY_DOWNLOADS + "/Thru3D/logs/" + name
        }
        val folder = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), "Thru3D/logs").apply { mkdirs() }
        File(folder, name).writeText(text)
        return Environment.DIRECTORY_DOWNLOADS + "/Thru3D/logs/" + name
    }

    private fun wifiAddress(): String = NetworkInterface.getNetworkInterfaces().toList()
        .filter { it.isUp && !it.isLoopback }
        .sortedBy { if (it.name.startsWith("wlan")) 0 else 1 }
        .flatMap { it.inetAddresses.toList() }
        .firstOrNull { it is Inet4Address && it.isSiteLocalAddress }?.hostAddress ?: error("No Wi-Fi address")

    /** Serves [text] at http://<Wi-Fi address>:8790/<code> for ten minutes; a short code keeps it typeable. */
    private fun share(text: String): String {
        stop()
        val alphabet = "abcdefghjkmnpqrstuvwxyz23456789"
        val random = SecureRandom()
        val code = (1..4).map { alphabet[random.nextInt(alphabet.length)] }.joinToString("")
        val bytes = text.toByteArray()
        val socket = ServerSocket().apply { reuseAddress = true; bind(InetSocketAddress(PORT)) }
        server = socket
        shareUntil = System.currentTimeMillis() + SHARE_MS
        thread(name = "DiagnosticLogShare", isDaemon = true) {
            while (!socket.isClosed) {
                val client = runCatching { socket.accept() }.getOrNull() ?: break
                if (System.currentTimeMillis() > shareUntil) { runCatching { client.close() }; stop(); break }
                thread(isDaemon = true) { serve(client, code, bytes) }
            }
        }
        thread(name = "DiagnosticLogShareTimer", isDaemon = true) {
            Thread.sleep(SHARE_MS)
            if (server === socket) stop()
        }
        return "http://${wifiAddress()}:$PORT/$code"
    }

    private fun serve(client: Socket, code: String, body: ByteArray) = client.use {
        it.soTimeout = 10_000
        val request = it.getInputStream().bufferedReader().readLine() ?: return@use
        val parts = request.split(' ')
        val found = parts.size >= 2 && parts[1].trimEnd('/') == "/$code" && parts[0] in setOf("GET", "HEAD")
        val out = it.getOutputStream()
        val head = if (found) "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: ${body.size}\r\n" +
            "Content-Disposition: inline; filename=\"${fileName()}\"\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        else "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        out.write(head.toByteArray())
        if (found && parts[0] == "GET") out.write(body)
        out.flush()
    }

    fun stop() {
        shareUntil = 0L
        server?.let { runCatching { it.close() } }
        server = null
    }
}
