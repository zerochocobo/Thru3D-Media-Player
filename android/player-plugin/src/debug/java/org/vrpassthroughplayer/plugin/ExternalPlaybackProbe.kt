package org.vrpassthroughplayer.plugin

import android.content.Context
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import org.json.JSONObject
import java.io.File
import java.io.RandomAccessFile
import java.net.URI
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

/** Phase-one source reads while the actual VR host is foreground. No decode or history claims. */
internal object ExternalPlaybackProbe {
    private val inbox = ExternalPlaybackInbox()
    private val worker = ThreadPoolExecutor(1, 1, 0, TimeUnit.MILLISECONDS, ArrayBlockingQueue(1),
        { task -> Thread(task, "ExternalPlaybackProbe") }, ThreadPoolExecutor.DiscardOldestPolicy())
    private var metadata = JSONObject()

    @Synchronized fun offer(context: Context, request: ExternalPlaybackRequest, fields: JSONObject): Long {
        // Remove old evidence so a new request cannot be confused with a previous receipt.
        reportFile(context).delete()
        metadata = fields
        return inbox.offer(request)
    }

    /** A rejected delivery keeps only its contract evidence; nothing can be claimed for reading. */
    @Synchronized fun reject(context: Context, fields: JSONObject): Long {
        reportFile(context).delete()
        metadata = fields
        return inbox.cancel()
    }

    fun start(context: Context, id: Long) {
        worker.execute {
            try { probe(context, id) } finally { inbox.discard(id) }
        }
    }

    private fun probe(context: Context, id: Long) {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(55)
        while (inbox.current(id) && DiagnosticRequests.current()?.externalPlaybackProbeHostReady() != true) {
            if (System.nanoTime() >= deadline) return
            Thread.sleep(100)
        }
        if (!inbox.current(id) || !PlaybackPrivacy.diagnostics) return
        val report = synchronized(this) { JSONObject(metadata.toString()) }
            .put("request_id", id).put("process_id", DiagnosticRequests.processId)
            .put("scope", "source_reads_only_no_decode_or_xr_verdict")
            .put("host_ready", true).put("host_ready_elapsed_ms", SystemClock.elapsedRealtime())
        if (report.has("reject_code")) {
            write(context, id, report.put("state", "rejected"))
            return
        }
        val delivery = inbox.claim(id) ?: return
        val request = delivery.request
        report.put("scheme", request.scheme).put("loopback", request.loopback)
            .put("header_names_accepted", org.json.JSONArray(request.headers.keys.toList()))
            .put("title_length", request.title.length).put("state", "host_ready")
        try {
            // A second read beyond the initial block checks fresh provider/range access.
            for (offset in listOf(0L, 1_048_576L)) {
                if (!inbox.current(id) || !PlaybackPrivacy.diagnostics) return
                val bytes = read(context, request, offset)
                report.put(if (offset == 0L) "initial_bytes" else "later_bytes", bytes)
                if (bytes <= 0) {
                    report.put("state", if (offset == 0L) "source_empty" else "source_short")
                    break
                }
            }
            if (report.optString("state") == "host_ready") report.put("state", "source_readable")
        } catch (failure: Exception) {
            report.put("state", "source_read_failed")
            if (failure is MediaServerFailure) report.put("http_status", failure.httpStatus)
        }
        write(context, id, report.put("read_elapsed_ms", SystemClock.elapsedRealtime()))
    }

    private fun write(context: Context, id: Long, report: JSONObject) {
        if (!inbox.current(id) || !PlaybackPrivacy.diagnostics) return
        val output = reportFile(context)
        val temporary = File.createTempFile("external-probe-", ".json", context.cacheDir)
        try {
            temporary.writeText(report.toString())
            synchronized(this) { if (inbox.current(id) && PlaybackPrivacy.diagnostics) temporary.renameTo(output) }
        } finally { temporary.delete() }
    }

    private fun read(context: Context, request: ExternalPlaybackRequest, offset: Long): Int = when (request.scheme) {
        "http", "https" -> RemoteMediaHttp().use { http ->
            val connection = http.open(URI(request.uri), "bytes=$offset-${offset + 4095}", request.headers)
            try {
                if (connection.responseCode == 206) HttpRangeStreamSource.validate(connection, offset)
                else mediaRequire(offset == 0L, "Server does not support seeking")
                connection.inputStream.use { it.read(ByteArray(4096)) }
            }
            finally { http.release(connection) }
        }
        "file" -> RandomAccessFile(File(URI(request.uri)), "r").use { it.seek(offset); it.read(ByteArray(4096)) }
        else -> ParcelFileDescriptor.AutoCloseInputStream(
            context.contentResolver.openFileDescriptor(Uri.parse(request.uri), "r") ?: error("SOURCE_UNREADABLE")
        ).use { stream -> stream.channel.position(offset); stream.read(ByteArray(4096)) }
    }

    private fun reportFile(context: Context) = File(context.cacheDir, "external-playback-probe.json")
}
