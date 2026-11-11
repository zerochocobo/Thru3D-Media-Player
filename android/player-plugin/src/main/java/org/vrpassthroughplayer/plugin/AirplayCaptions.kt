package org.vrpassthroughplayer.plugin

import android.content.Context
import android.os.Process
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.ByteBuffer
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Speech recognition for a live PCM source. Audio and cues are kept in memory for this session. */
internal class AirplayCaptions(private val context: () -> Context?) : AutoCloseable {
    private val worker = Executors.newSingleThreadScheduledExecutor { Thread(it, "AirPlay-Captions") }
    private val lock = Any()
    private val audio = ByteArrayOutputStream()
    private var generation = 0L
    private var rate = 0
    private var channels = 0
    private var reset = true
    private var closed = false
    private var engine = 0L // worker only
    private var sequence = 0L
    @Volatile private var state = "off"
    @Volatile private var report = "{}"
    val accepting: Boolean get() = state == "ready"

    fun configure(language: String): Boolean = synchronized(lock) {
        if (closed || language !in listOf("", "en", "ja", "zh")) return false
        val token = ++generation
        audio.reset(); reset = true
        state = if (language.isEmpty()) "off" else "preparing"
        publish(token)
        worker.execute {
            if (!current(token)) return@execute
            release()
            if (language.isEmpty()) return@execute
            try {
                Process.setThreadPriority(Process.THREAD_PRIORITY_BACKGROUND)
                val app = context() ?: error("No application context")
                val bundle = app.assets.open("moonshine/model.json").bufferedReader().use { JSONObject(it.readText()) }
                    .getJSONObject("models").getJSONObject(language)
                val directory = File(app.filesDir, "listening/$language")
                NarrationModels.ensure(directory, bundle.getJSONObject("files"),
                    { app.assets.open(bundle.getString("directory") + "/" + it) }, { current(token) }, {})
                if (!current(token)) return@execute
                engine = synchronized(ListeningWorkGate.lock) {
                    if (current(token)) ListeningNative.create(directory.path, language) else 0L
                }
                if (!current(token)) { release(); return@execute }
                check(engine > 0)
                synchronized(lock) { if (current(token)) { state = "ready"; publish(token) } }
                schedule(token)
            } catch (_: Exception) { fail(token) }
            catch (_: LinkageError) { fail(token) }
        }
        true
    }

    fun offer(buffer: ByteBuffer, sampleRate: Int, channelCount: Int) {
        if (!accepting || sampleRate !in 8000..96000 || channelCount !in 1..2) return
        val length = buffer.remaining()
        val capacity = sampleRate * channelCount * 2 // At most one second of unread audio.
        if (length !in 1..capacity || length % (channelCount * 2) != 0) return
        synchronized(lock) {
            if (!accepting) return
            if (rate != sampleRate || channels != channelCount || audio.size() + length > capacity) {
                audio.reset(); reset = true; rate = sampleRate; channels = channelCount
            }
            val copy = ByteArray(length); buffer.duplicate().get(copy); audio.write(copy)
        }
    }

    fun discontinuity() = synchronized(lock) { audio.reset(); reset = true }

    fun status(): String = report

    private fun current(token: Long) = synchronized(lock) { !closed && generation == token }

    private fun publish(token: Long, lines: JSONArray = JSONArray()) {
        report = JSONObject().put("state", state).put("generation", token).put("sequence", sequence).put("cues", lines).toString()
    }

    private fun schedule(token: Long) = synchronized(lock) {
        if (current(token)) worker.schedule({ recognize(token) }, 350, TimeUnit.MILLISECONDS)
    }

    private fun recognize(token: Long) {
        if (!current(token)) return
        try {
            val lines = synchronized(ListeningWorkGate.lock) {
                val batch = synchronized(lock) batch@{
                    if (!current(token) || audio.size() == 0) return@batch null
                    Pcm(audio.toByteArray(), rate, channels, reset).also { audio.reset(); reset = false }
                }
                batch?.let { JSONArray(ListeningNative.recognizePcm(engine, it.bytes, it.rate, it.channels, it.reset)) }
            }
            synchronized(lock) {
                if (current(token) && lines != null && lines.length() > 0) { sequence++; publish(token, lines) }
            }
            schedule(token)
        } catch (_: Exception) { fail(token) }
    }

    private data class Pcm(val bytes: ByteArray, val rate: Int, val channels: Int, val reset: Boolean)

    private fun fail(token: Long) {
        release()
        synchronized(lock) { if (current(token)) { state = "listening_error"; audio.reset(); publish(token) } }
    }

    private fun release() {
        if (engine > 0) ListeningNative.destroy(engine)
        engine = 0
    }

    override fun close() = synchronized(lock) {
        closed = true; audio.reset(); state = "off"; publish(++generation)
        worker.execute { release() }
        worker.shutdown()
    }
}
