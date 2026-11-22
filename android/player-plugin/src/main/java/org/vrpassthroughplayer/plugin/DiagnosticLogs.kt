package org.vrpassthroughplayer.plugin

import android.content.ContentValues
import android.content.Context
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.net.HttpURLConnection
import java.net.Inet4Address
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.ServerSocket
import java.net.Socket
import java.net.URL
import java.security.SecureRandom
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.Executors
import java.util.zip.GZIPOutputStream
import kotlin.concurrent.thread

/**
 * The diagnostic log a user can hand over: this app's own logcat (no permission is needed for its own
 * process), with media names, accounts and URL parameters masked. Saved to Download/Thru3D/logs or
 * served for a while on the headset's Wi-Fi address, since a headset has no share target to a phone,
 * or sent to the developer's write-only inbox (cloud/log-upload) when the user chooses to upload it.
 */
internal object DiagnosticLogs {
    private const val SHARE_MS = 10 * 60 * 1000L
    private const val PORT = 8790
    private const val UPLOAD_URL = ""
    /** The inbox refuses more (cloud/log-upload MAX_BYTES). */
    private const val UPLOAD_MAX_BYTES = 4 * 1024 * 1024
    private val worker = Executors.newSingleThreadExecutor { Thread(it, "DiagnosticLogs").apply { isDaemon = true } }
    @Volatile private var server: ServerSocket? = null
    @Volatile private var shareUntil = 0L

    /** [action]: "save", "share", "upload", "stop" or "recent"; [header] goes on top of the log (versions, settings);
     * [full] keeps every line, otherwise periodic lines are thinned ([condense]).
     * Reports {"action", "ok", "path"|"url"+"expires_ms"|"code"|"lines", "error"} through [report]. */
    fun request(context: Context, action: String, header: String, full: Boolean, report: (JSONObject) -> Unit) {
        val app = context.applicationContext
        worker.execute {
            val result = JSONObject().put("action", action)
            try {
                when (action) {
                    "save" -> result.put("path", save(app, compose(app, header, full), fileName()))
                    "share" -> result.put("url", share(compose(app, header, full))).put("expires_ms", shareUntil)
                    "upload" -> result.put("code", upload(UPLOAD_URL, compose(app, header, full), installation(app).lineSequence().first(), reportCategory(header)))
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

    /** This app's logcat: one process ([pid]), or every process of the app (null). Android returns only
     * this app's own lines, including those of an earlier process still in the ring buffer. */
    internal fun logcat(pid: Int?, vararg extra: String): String {
        val command = listOf("logcat", "-d", "-v", "threadtime") + listOfNotNull(pid?.let { "--pid=$it" }) + extra
        val process = ProcessBuilder(command).redirectErrorStream(true).start()
        val text = process.inputStream.bufferedReader().readText()
        process.waitFor()
        return text
    }

    private fun device(title: String) = buildString {
        append(title).append(' ').append(SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US).format(Date())).append('\n')
        append("Device: ").append(Build.MANUFACTURER).append(' ').append(Build.MODEL)
            .append(" · Android ").append(Build.VERSION.RELEASE).append(" (API ").append(Build.VERSION.SDK_INT).append(")\n")
        append("Build: ").append(Build.FINGERPRINT).append('\n')
    }

    /** Installed package identity, independent of the Godot display version in [header]. */
    private fun installation(context: Context): String {
        val app = runCatching { context.packageManager.getPackageInfo(context.packageName, 0) }.getOrNull()
        return "App: ${context.packageName} ${app?.versionName ?: "?"} (versionCode=${app?.longVersionCode ?: -1})\n" +
            "App updated (epoch_ms): ${app?.lastUpdateTime ?: -1}\n" +
            "Storage reader: ${StorageDocumentReader.IMPLEMENTATION}\n"
    }

    private fun compose(context: Context, header: String, full: Boolean): String = buildString {
        append(device("Thru3D diagnostic log"))
        append(installation(context))
        append(redact(header)).append('\n')
        append(if (full) "Detail: full\n\n" else "Detail: compact (VrApi every 10 s and whenever frames, stale frames or free memory go wrong; " +
            "other periodic lines every 30 s; repeated messages merged)\n\n")
        append(webBetaSection()).append('\n')
        append(webBrowserSection()).append('\n')
        append(redact(CrashRecords.exportSection(context))).append('\n')
        append(events(context, if (full) 6000 else 1500)).append('\n')
        append("== Log of this session ==\n")
        val log = logcat(android.os.Process.myPid(), "-t", "30000")
        append(redact(if (full) log else condense(log)))
    }

    internal fun webBetaSection(): String = buildString {
        append("== Playback Beta (this session, oldest first) ==\n")
        val steps = CrashTrail.recentWebBetaSteps()
        if (steps.isEmpty()) append("(none recorded)\n")
        else steps.forEach { append(redact(it)).append('\n') }
    }

    /** Gecko loads, paints, Surfaces, composites, media and Godot's page layer; "now" lines are the
     * windows' live state when the log was taken. Search "web.white_suspect" first. */
    internal fun webBrowserSection(): String = buildString {
        append("== Web browser (this session, oldest first) ==\n")
        val steps = WebBrowserTrail.recent()
        if (steps.isEmpty()) append("(none recorded)\n")
        else steps.forEach { append(redact(it)).append('\n') }
    }

    /** The crash report saved on the next launch; the player settings header is not known that early. */
    internal fun crashFile(context: Context, report: String): String = buildString {
        append(device("Thru3D crash report"))
        val app = runCatching { context.packageManager.getPackageInfo(context.packageName, 0) }.getOrNull()
        append("App: ").append(app?.versionName ?: "?").append(" (").append(app?.longVersionCode ?: 0).append(")\n\n")
        append(report).append('\n')
        append(events(context, 1500))
    }

    /** The newest player events across sessions (user://diagnostics; written only while history is recorded). */
    private fun events(context: Context, lines: Int): String {
        val directory = File(context.filesDir, "diagnostics")
        val all = listOf("events.1.jsonl", "events.jsonl").flatMap { name ->
            runCatching { File(directory, name).takeIf { it.isFile }?.readLines() }.getOrNull() ?: emptyList()
        }
        return "== Recent events (all sessions, newest last) ==\n" +
            (if (all.isEmpty()) "(none recorded)\n" else redact(all.takeLast(lines).joinToString("\n", postfix = "\n")))
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
    private fun recent(): List<String> = logcat(android.os.Process.myPid(), "-t", "4000", "*:W").lineSequence()
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
    internal fun save(context: Context, text: String, name: String): String {
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

    /** The problem type the user chose for an upload: the header's `Report: {"category", "note"}` line.
     * The note stays in the log text only. */
    internal fun reportCategory(header: String): String = header.lineSequence().firstOrNull { it.startsWith("Report: ") }
        ?.let { runCatching { JSONObject(it.removePrefix("Report: ")).optString("category") }.getOrNull() }
        ?.takeIf { Regex("[a-z_]{1,32}").matches(it) }.orEmpty()

    /** Sends the masked log, gzipped, to the inbox at [endpoint]; the code the user quotes when reporting
     * a problem. Fails with the inbox's reason ("rate_limited", "quota", "too_large", ...) or "http_<status>". */
    internal fun upload(endpoint: String, text: String, app: String, category: String = ""): String {
        check(endpoint.isNotBlank()) { "upload_unconfigured" }
        val body = ByteArrayOutputStream().also { bytes -> GZIPOutputStream(bytes).use { it.write(text.toByteArray()) } }.toByteArray()
        if (body.size > UPLOAD_MAX_BYTES) error("too_large")
        val connection = URL(endpoint).openConnection() as HttpURLConnection
        try {
            connection.requestMethod = "POST"
            connection.connectTimeout = 15_000
            connection.readTimeout = 30_000
            connection.doOutput = true
            connection.setFixedLengthStreamingMode(body.size)
            connection.setRequestProperty("Content-Type", "application/gzip")
            connection.setRequestProperty("X-Thru3D-App", app.removePrefix("App: ").filter { it.code in 32..126 })
            if (category.isNotEmpty()) connection.setRequestProperty("X-Thru3D-Category", category)
            connection.outputStream.use { it.write(body) }
            val status = connection.responseCode
            val reply = runCatching {
                JSONObject((if (status in 200..299) connection.inputStream else connection.errorStream).bufferedReader().use { it.readText() })
            }.getOrNull()
            if (status !in 200..299) error(reply?.optString("error")?.takeIf { it.isNotEmpty() } ?: "http_$status")
            return reply?.optString("code")?.takeIf { Regex("[A-Z0-9]{6,12}").matches(it) } ?: error("bad_reply")
        } finally {
            connection.disconnect()
        }
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
