package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.net.URI
import java.util.concurrent.CopyOnWriteArrayList

class MediaServerPlaybackBindingTest {
    @Test fun captureReadersNeverReportAndPlayingLeaseRetainsItsMetadataUntilStop() {
        val reports = CopyOnWriteArrayList<Pair<String, JSONObject>>()
        val reporter = MediaServerPlaybackReporter({ true }, send = { _, path, body -> reports += path to body })
        MediaServerClientTest.Fixture { request, _, _ ->
            if (URI(request.split(' ')[1]).path.endsWith("PlaybackInfo")) MediaServerClientTest.Reply(body =
                """{"PlaySessionId":"session","MediaSources":[{"Id":"source","Protocol":"File","Size":32,"SupportsDirectPlay":true,
                    "MediaStreams":[{"Type":"Video","Index":0},{"Type":"Audio","Index":2}]}]}""".toByteArray())
            else MediaServerClientTest.Reply(206, "Content-Range: bytes 0-0/32\r\nContent-Type: video/mp4\r\n", byteArrayOf(1))
        }.use { fixture -> LocalStreamServer().use { local ->
            val account = MediaServerAccount("server", "NAS", fixture.url, "token", "jellyfin", "user")
            val library = MediaServerLibrary({ null }, { local }, { 1 }, getAccount = { account }, reports = reporter, emit = { _, _ -> })
            val uri = MediaLibraryUri.scene("server", "film")
            val state = JSONObject().put("action", "state").put("token", "1").put("uri", uri)
                .put("position_ms", 120000).put("paused", false).put("audio", 2)
            try {
                val capture = library.playable(uri, captureReader = true)
                library.playbackState(state.toString()); reporter.awaitIdle()
                assertTrue(reports.isEmpty()); library.release(capture)
                val playing = library.playable(uri)
                library.playbackState(state.toString()); reporter.awaitIdle()
                assertEquals("Sessions/Playing", reports.single().first)
                assertEquals("source", reports.single().second.getString("MediaSourceId"))
                assertEquals(2, reports.single().second.getInt("AudioStreamIndex"))
                library.release(playing)
                library.playbackState(JSONObject().put("action", "stop").put("token", "1").toString()); reporter.awaitIdle()
                assertEquals("Sessions/Playing/Stopped", reports.last().first)
                assertEquals("session", reports.last().second.getString("PlaySessionId"))
                assertEquals(1200000000L, reports.last().second.getLong("PositionTicks"))
            } finally { library.close() }
        } }
    }
}
