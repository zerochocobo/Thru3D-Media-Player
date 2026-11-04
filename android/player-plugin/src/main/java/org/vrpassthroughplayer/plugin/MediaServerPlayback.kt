package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import java.io.Closeable
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Metadata from PlaybackInfo, retained independently of MPV and proxy/STRM URLs. */
internal data class MediaServerPlaybackContext(val itemId: String, val mediaSourceId: String, val playSessionId: String,
    val audioStreams: Set<Int> = emptySet(), val subtitleStreams: Set<Int> = emptySet())

internal data class MediaServerPlaybackState(val positionMs: Long, val paused: Boolean, val canSeek: Boolean,
    val muted: Boolean = false, val volume: Int = 100, val audio: Int? = null, val subtitle: Int? = null,
    val speed: Double = 1.0, val seek: Long = 0, val audioChoice: String = "", val subtitleChoice: String = "") {
    fun event(previous: MediaServerPlaybackState?): String = when {
        previous == null -> "TimeUpdate"
        paused != previous.paused -> if (paused) "Pause" else "Unpause"
        audio != previous.audio || audioChoice != previous.audioChoice -> "AudioTrackChange"
        subtitle != previous.subtitle || subtitleChoice != previous.subtitleChoice -> "SubtitleTrackChange"
        volume != previous.volume || muted != previous.muted -> "VolumeChange"
        speed != previous.speed -> "PlaybackRateChange"
        else -> "TimeUpdate" // A confirmed seek is a position update, not an undocumented EventName.
    }
    fun changed(previous: MediaServerPlaybackState?) = previous == null ||
        copy(positionMs = previous.positionMs) != previous
}

/** One bounded, ordered writer. Playback/render threads never wait for the server.
 * Only the newest pending progress survives slow IO; a stopped slot cannot accept more state.
 */
internal class MediaServerPlaybackReporter(
    private val allowed: () -> Boolean = { PlaybackPrivacy.networkHistory },
    private val clock: () -> Long = { System.nanoTime() / 1_000_000 },
    private val send: (MediaServerAccount, String, JSONObject) -> Unit = { account, path, body ->
        MediaServerHttp(account, 5000, 5000).use { it.bytes(account.endpoint(path), 65536, body) }; Unit
    },
) : Closeable {
    private class Slot(val token: String, val account: MediaServerAccount, val context: MediaServerPlaybackContext,
        var latest: MediaServerPlaybackState) {
        var startAttempted = false
        var sent: MediaServerPlaybackState? = null
        var lastReportAt = 0L
        var terminal = false
    }
    private val worker = Executors.newSingleThreadExecutor { Thread(it, "Thru3DPlaybackReports").apply { isDaemon = true } }
    private val slots = LinkedHashMap<String, Slot>()
    private var current: Slot? = null
    private var retiredToken = ""
    private var lastToken = 0L
    private var scheduled = false
    private var closed = false
    private var intervalMs = 10000L

    @Synchronized fun setIntervalMs(value: Int) {
        if (closed) return
        val normalized = ((value.coerceIn(500, 20000) + 250) / 500 * 500).toLong()
        if (intervalMs == normalized) return
        intervalMs = normalized
        schedule()
    }

    @Synchronized fun observe(token: String, account: MediaServerAccount, context: MediaServerPlaybackContext, state: MediaServerPlaybackState) {
        val sequence = token.toLongOrNull()?.takeIf { it > 0 } ?: return
        if (closed || token == retiredToken || account.provider !in setOf("emby", "jellyfin")) return
        if (current?.token != token) {
            if (sequence <= lastToken) return
            lastToken = sequence
            current?.let { it.terminal = true }
            current = null
            // Refuse a new session rather than accumulating unbounded history during an outage.
            if (slots.size >= 16 || !allowed()) { retiredToken = token; schedule(); return }
            val slot = Slot(token, account, context, state)
            slots[token] = slot; current = slot
        }
        val slot = current ?: return
        if (slot.terminal || slot.account != account) return
        if (!allowed()) { stop(token); return }
        slot.latest = state.copy(positionMs = state.positionMs.coerceIn(0, Long.MAX_VALUE / 10000),
            volume = state.volume.coerceIn(0, 100),
            audio = state.audio?.takeIf { it == -1 || it in slot.context.audioStreams },
            subtitle = state.subtitle?.takeIf { it == -1 || it in slot.context.subtitleStreams },
            speed = state.speed.takeIf { it.isFinite() && it in 0.1..8.0 } ?: 1.0)
        schedule()
    }
    @Synchronized fun stop(token: String) {
        if (closed) return
        lastToken = maxOf(lastToken, token.toLongOrNull() ?: 0)
        slots[token]?.terminal = true
        if (current?.token == token) current = null
        retiredToken = token
        schedule()
    }
    @Synchronized fun privacyChanged() {
        if (closed) return
        if (!allowed()) current?.let { stop(it.token) }
    }
    @Synchronized fun pause() {
        if (closed) return
        current?.let { it.latest = it.latest.copy(paused = true) }
        schedule()
    }
    @Synchronized fun invalidate(server: String) {
        if (closed) return
        slots.values.filter { it.account.id == server }.forEach { it.terminal = true }
        current?.takeIf { it.account.id == server }?.let { retiredToken = it.token; current = null }
        schedule()
    }
    private fun schedule() {
        if (scheduled || slots.isEmpty()) return
        scheduled = true
        worker.execute(::drain)
    }
    private data class Report(val slot: Slot, val state: MediaServerPlaybackState, val action: String)
    @Synchronized private fun next(): Report? {
        val iterator = slots.values.iterator()
        while (iterator.hasNext()) {
            val slot = iterator.next()
            if (slot.terminal) {
                iterator.remove()
                if (slot.startAttempted) return Report(slot, slot.latest, "Stopped")
                continue // Cancelled before its first request: no fabricated start/stop pair.
            }
            if (!allowed()) {
                slot.terminal = true; retiredToken = slot.token; current = null
                iterator.remove()
                if (slot.startAttempted) return Report(slot, slot.latest, "Stopped")
                continue
            }
            if (!slot.startAttempted) {
                // A lost response must not cause a duplicate Started and increment PlayCount twice.
                slot.startAttempted = true
                return Report(slot, slot.latest, "Playing")
            }
            if (slot.latest.changed(slot.sent) || clock() - slot.lastReportAt >= intervalMs) return Report(slot, slot.latest, "Progress")
        }
        scheduled = false
        return null
    }
    private fun drain() {
        while (true) {
            val report = next() ?: return
            val slot = report.slot; val state = report.state
            val path = if (report.action == "Playing") "Sessions/Playing" else "Sessions/Playing/${report.action}"
            // Pin the attempted snapshot before IO so failures cannot spin or grow a retry queue.
            val previous = synchronized(this) {
                slot.sent.also { slot.sent = state; slot.lastReportAt = clock() }
            }
            runCatching { send(slot.account, path, body(slot, state, report.action, previous)) }
        }
    }
    private fun body(slot: Slot, state: MediaServerPlaybackState, action: String, previous: MediaServerPlaybackState?): JSONObject {
        val result = JSONObject().put("ItemId", slot.context.itemId).put("MediaSourceId", slot.context.mediaSourceId)
            .put("PlaySessionId", slot.context.playSessionId).put("PositionTicks", state.positionMs * 10000)
        if (action != "Stopped" || slot.account.provider == "emby") {
            result.put("CanSeek", state.canSeek).put("IsPaused", state.paused).put("IsMuted", state.muted)
                .put("VolumeLevel", state.volume).put("PlayMethod", "DirectPlay")
            state.audio?.let { result.put("AudioStreamIndex", it) }
            state.subtitle?.let { result.put("SubtitleStreamIndex", it) }
            if (slot.account.provider == "emby") result.put("PlaybackRate", state.speed).put("QueueableMediaTypes", org.json.JSONArray().put("Video"))
        }
        if (action == "Progress" && slot.account.provider == "emby") result.put("EventName", state.event(previous))
        return result
    }
    @Synchronized override fun close() {
        if (closed) return
        closed = true
        slots.values.forEach { it.terminal = true }; current = null
        schedule()
        worker.shutdown() // Allow the already queued final Stop, without blocking app shutdown.
    }
    internal fun awaitIdle() { worker.submit {}.get(20, TimeUnit.SECONDS) }
}
