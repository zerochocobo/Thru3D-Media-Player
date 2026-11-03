package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong

class MediaServerPlaybackTest {
    private val context = MediaServerPlaybackContext("film", "version-b", "play-session", setOf(1, 3), setOf(5))
    private fun account(provider: String = "emby") = MediaServerAccount("server", "NAS", "http://127.0.0.1:1", "secret", provider, "user")
    private data class Sent(val account: MediaServerAccount, val path: String, val body: JSONObject)
    private fun state(ms: Long = 0) = MediaServerPlaybackState(ms, false, true, audio = 3, subtitle = -1)

    @Test fun orderedLifecycleTicksCadenceAndEmbyEvents() {
        val now = AtomicLong(100); val sent = CopyOnWriteArrayList<Sent>()
        MediaServerPlaybackReporter({ true }, now::get, { a, p, b -> sent += Sent(a, p, b) }).use { reporter ->
            val a = account(); var s = state(60000)
            reporter.observe("1", a, context, s); reporter.awaitIdle()
            assertEquals(listOf("Sessions/Playing"), sent.map { it.path })
            assertEquals(600000000L, sent.single().body.getLong("PositionTicks"))
            assertEquals("version-b", sent.single().body.getString("MediaSourceId"))
            assertEquals("play-session", sent.single().body.getString("PlaySessionId"))
            assertEquals(3, sent.single().body.getInt("AudioStreamIndex"))
            repeat(40) { reporter.observe("1", a, context, s.copy(positionMs = 60001L + it)) }
            reporter.awaitIdle(); assertEquals(1, sent.size)
            now.addAndGet(10000); reporter.observe("1", a, context, s.copy(positionMs = 70000)); reporter.awaitIdle()
            assertEquals("TimeUpdate", sent.last().body.getString("EventName"))
            for ((change, event) in listOf(
                s.copy(paused = true) to "Pause", s.copy(paused = false) to "Unpause",
                s.copy(audio = 1) to "AudioTrackChange", s.copy(audio = 1, subtitle = 5) to "SubtitleTrackChange",
                s.copy(audio = 1, subtitle = 5, volume = 20) to "VolumeChange",
                s.copy(audio = 1, subtitle = 5, volume = 20, speed = 1.5) to "PlaybackRateChange",
                s.copy(audio = 1, subtitle = 5, volume = 20, speed = 1.5, seek = 1, positionMs = 120000) to "TimeUpdate")) {
                s = change; reporter.observe("1", a, context, s); reporter.awaitIdle()
                assertEquals(event, sent.last().body.getString("EventName"))
            }
            reporter.stop("1"); reporter.awaitIdle()
            assertEquals("Sessions/Playing/Stopped", sent.last().path)
            assertEquals(1200000000L, sent.last().body.getLong("PositionTicks"))
            val count = sent.size
            reporter.observe("1", a, context, state()); reporter.awaitIdle(); assertEquals(count, sent.size)
        }
    }

    @Test fun jellyfinUsesItsOwnBodiesAndUnknownTracksAreNeverGuessed() {
        val sent = CopyOnWriteArrayList<Sent>()
        MediaServerPlaybackReporter({ true }, send = { a, p, b -> sent += Sent(a, p, b) }).use { reporter ->
            reporter.observe("1", account("jellyfin"), context, state().copy(audio = 77, subtitle = 88)); reporter.awaitIdle()
            assertFalse(sent.last().body.has("AudioStreamIndex")); assertFalse(sent.last().body.has("SubtitleStreamIndex"))
            reporter.observe("1", account("jellyfin"), context, state(2147483648L).copy(paused = true)); reporter.awaitIdle()
            assertFalse(sent.last().body.has("EventName")); assertFalse(sent.last().body.has("PlaybackRate"))
            assertEquals(21474836480000L, sent.last().body.getLong("PositionTicks"))
            reporter.stop("1"); reporter.awaitIdle()
            assertEquals(setOf("ItemId", "MediaSourceId", "PlaySessionId", "PositionTicks"), sent.last().body.keys().asSequence().toSet())
        }
    }
    @Test fun localExternalTrackChangesReportWithoutInventingServerIndexes() {
        val sent = CopyOnWriteArrayList<Sent>()
        MediaServerPlaybackReporter({ true }, send = { a, p, b -> sent += Sent(a, p, b) }).use { reporter ->
            val external = state().copy(audio = null, subtitle = null, audioChoice = "6", subtitleChoice = "7")
            reporter.observe("1", account(), context, external); reporter.awaitIdle()
            reporter.observe("1", account(), context, external.copy(audioChoice = "8")); reporter.awaitIdle()
            assertEquals("AudioTrackChange", sent.last().body.getString("EventName"))
            assertFalse(sent.last().body.has("AudioStreamIndex"))
            reporter.observe("1", account(), context, external.copy(audioChoice = "8", subtitleChoice = "9")); reporter.awaitIdle()
            assertEquals("SubtitleTrackChange", sent.last().body.getString("EventName"))
            assertFalse(sent.last().body.has("SubtitleStreamIndex"))
        }
    }

    @Test fun privatePlaybackNeverBackfillsAndDisablingClosesAtLastAllowedPosition() {
        var allowed = false; val sent = CopyOnWriteArrayList<Sent>()
        MediaServerPlaybackReporter({ allowed }, send = { a, p, b -> sent += Sent(a, p, b) }).use { reporter ->
            reporter.observe("1", account(), context, state(60000)); reporter.awaitIdle()
            allowed = true; reporter.observe("1", account(), context, state(70000)); reporter.awaitIdle()
            assertTrue(sent.isEmpty())
            reporter.observe("2", account(), context, state(80000)); reporter.awaitIdle()
            allowed = false; reporter.privacyChanged(); reporter.observe("2", account(), context, state(90000)); reporter.awaitIdle()
            assertEquals(listOf("Sessions/Playing", "Sessions/Playing/Stopped"), sent.map { it.path })
            assertEquals(800000000L, sent.last().body.getLong("PositionTicks"))
            allowed = true; reporter.observe("2", account(), context, state(100000)); reporter.awaitIdle()
            assertEquals(2, sent.size)
        }
    }

    @Test fun slowNetworkConflatesProgressAndStopsOldSessionBeforeNextStart() {
        val entered = CountDownLatch(1); val release = CountDownLatch(1); val sent = CopyOnWriteArrayList<Sent>()
        MediaServerPlaybackReporter({ true }, send = { a, p, b ->
            sent += Sent(a, p, b)
            if (sent.size == 1) { entered.countDown(); assertTrue(release.await(10, TimeUnit.SECONDS)) }
        }).use { reporter ->
            reporter.observe("1", account(), context, state()); assertTrue(entered.await(10, TimeUnit.SECONDS))
            repeat(1000) { reporter.observe("1", account(), context, state(it.toLong()).copy(seek = it.toLong())) }
            reporter.stop("1")
            reporter.observe("2", account(), context.copy(itemId = "next"), state(50000))
            reporter.observe("1", account(), context, state(90000)) // A late old token cannot replace the new item.
            release.countDown(); reporter.awaitIdle()
            assertEquals(listOf("Sessions/Playing", "Sessions/Playing/Stopped", "Sessions/Playing"), sent.map { it.path })
            assertEquals(9990000L, sent[1].body.getLong("PositionTicks"))
            assertEquals("next", sent.last().body.getString("ItemId"))
            reporter.invalidate("server"); reporter.awaitIdle()
            assertEquals("Sessions/Playing/Stopped", sent.last().path)
        }
    }

    @Test fun transportFailuresDoNotRetryStartsOrBlockStateAndPauseUsesLastClock() {
        val sent = CopyOnWriteArrayList<Sent>()
        MediaServerPlaybackReporter({ true }, send = { a, p, b ->
            sent += Sent(a, p, b); throw MediaServerFailure("Server unavailable")
        }).use { reporter ->
            reporter.observe("1", account(), context, state(120000)); reporter.awaitIdle()
            reporter.observe("1", account(), context, state(120100)); reporter.awaitIdle()
            assertEquals(1, sent.size)
            reporter.pause(); reporter.awaitIdle()
            assertEquals("Pause", sent.last().body.getString("EventName"))
            reporter.stop("1"); reporter.awaitIdle()
            assertEquals(1, sent.count { it.path == "Sessions/Playing" })
            assertEquals(1201000000L, sent.last().body.getLong("PositionTicks"))
        }
    }
}
