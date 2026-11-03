package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicLong

/** Opt-in local integration; credentials enter via process environment and never enter reports. */
class MediaServerPlaybackLiveTest {
    @Test fun jellyfinReportsUpdateSessionsAndResumeThenRestoreTheUnusedSample() = verify("jellyfin", "JELLYFIN")
    @Test fun embyReportsUpdateSessionsAndResumeThenRestoreTheUnusedSample() = verify("emby", "EMBY")

    private fun verify(provider: String, environment: String) {
        val url = System.getenv("VRPP_${environment}_TEST_URL").orEmpty()
        val username = System.getenv("VRPP_${environment}_TEST_USERNAME").orEmpty()
        val password = System.getenv("VRPP_${environment}_TEST_PASSWORD")
        val label = if (provider == "emby") "Emby" else "Jellyfin"
        assumeTrue("Optional local $label reporting integration", url.isNotEmpty() && username.isNotEmpty() && password != null)
        val anonymous = MediaServerAccount(UUID.randomUUID().toString(), "Thru3D reporting test", MediaServerAccount.address(url), "", provider)
        val account = MediaServerHttp(anonymous).use { EmbyClient(anonymous, it).login(username, password!!) }
        MediaServerHttp(account).use { http ->
            fun get(path: String, body: JSONObject? = null, method: String = if (body == null) "GET" else "POST"): JSONObject {
                val raw = String(http.bytes(account.endpoint(path), 4 * 1024 * 1024, body, method = method), Charsets.UTF_8)
                return if (raw.isBlank()) JSONObject() else JSONObject(raw)
            }
            var sample: JSONObject? = null
            var original: JSONObject? = null
            var restoreSample = false
            val now = AtomicLong(100)
            val responses = CopyOnWriteArrayList<JSONObject>()
            val reporter = MediaServerPlaybackReporter({ true },
                { if (provider == "emby") System.nanoTime() / 1_000_000 else now.get() }, { a, path, body ->
                    MediaServerHttp(a, 5000, 5000).use { transport ->
                        val connection = transport.open(a.endpoint(path), json = body)
                        try {
                            responses += JSONObject().put("path", path).put("status", connection.responseCode)
                                .put("event", body.optString("EventName")).put("position_ticks", body.optLong("PositionTicks"))
                        } finally { transport.release(connection) }
                    }
                })
            fun userData(id: String): JSONObject = if (provider == "emby")
                get("Users/${account.userId}/Items/$id").getJSONObject("UserData")
                else get("UserItems/$id/UserData?UserId=${account.userId}")
            val resumePath = if (provider == "emby") "Users/${account.userId}/Items/Resume?Limit=100&Recursive=true&MediaTypes=Video"
                else "UserItems/Resume?UserId=${account.userId}&Limit=100"
            try {
                val client = EmbyClient(account, http)
                val version = client.probe()
                assertTrue(version.isNotBlank())
                assertTrue(client.home(JSONObject()).has("libraries"))
                assertTrue(client.candidates(JSONObject().put("kind", "tags")).has("total"))
                val items = get("Users/${account.userId}/Items?Recursive=true&IncludeItemTypes=Movie,Episode,Video&Limit=100&EnableUserData=true")
                    .getJSONArray("Items").objects()
                sample = items.firstOrNull { item ->
                    val state = item.optJSONObject("UserData") ?: JSONObject()
                    item.optLong("RunTimeTicks") > 600L * 10000000 && state.optLong("PlaybackPositionTicks") == 0L &&
                        state.optInt("PlayCount") == 0 && !state.optBoolean("Played") && state.optString("LastPlayedDate").isBlank()
                }
                assumeTrue("Need an unused video longer than ten minutes", sample != null)
                val id = sample!!.getString("Id")
                original = userData(id)
                assumeTrue("Selected sample must still be unused", original!!.optLong("PlaybackPositionTicks") == 0L &&
                    original!!.optInt("PlayCount") == 0 && !original!!.optBoolean("Played") && original!!.optString("LastPlayedDate").isBlank())
                val context = client.stream(id).playback!!
                HttpRangeStreamSource(account) { client.stream(id) }.use { source ->
                    source.open().use { reader ->
                        val buffer = ByteArray(64)
                        assertTrue(reader.read(0, buffer, buffer.size) > 0)
                        assertTrue(reader.read(source.size / 2, buffer, buffer.size) > 0)
                    }
                }
                fun current(): JSONObject {
                    val raw = String(http.bytes(account.endpoint("Sessions?DeviceId=${account.id}"), 1024 * 1024), Charsets.UTF_8)
                    return org.json.JSONArray(raw).objects().first { it.optString("DeviceId") == account.id }
                }
                var state = MediaServerPlaybackState(0, false, true)
                restoreSample = true
                reporter.observe("1", account, context, state); reporter.awaitIdle()
                assertEquals(id.replace("-", ""), current().getJSONObject("NowPlayingItem").getString("Id").replace("-", ""))
                if (provider == "emby") Thread.sleep(10100) else now.addAndGet(10000)
                state = state.copy(positionMs = 60000)
                reporter.observe("1", account, context, state); reporter.awaitIdle()
                assertEquals(600000000L, current().getJSONObject("PlayState").getLong("PositionTicks"))
                state = state.copy(paused = true); reporter.observe("1", account, context, state); reporter.awaitIdle()
                assertTrue(current().getJSONObject("PlayState").getBoolean("IsPaused"))
                state = state.copy(paused = false); reporter.observe("1", account, context, state); reporter.awaitIdle()
                assertFalse(current().getJSONObject("PlayState").getBoolean("IsPaused"))
                state = state.copy(positionMs = 120000, seek = 1)
                reporter.observe("1", account, context, state); reporter.awaitIdle()
                assertEquals(1200000000L, current().getJSONObject("PlayState").getLong("PositionTicks"))
                reporter.stop("1"); reporter.awaitIdle()
                assertFalse(current().has("NowPlayingItem"))
                assertEquals(1200000000L, userData(id).getLong("PlaybackPositionTicks"))
                if (provider == "emby") {
                    fun containsSample(path: String) = get(path).getJSONArray("Items").objects().any { it.getString("Id") == id }
                    val root = "Users/${account.userId}/Items/Resume?Limit=100"
                    println("Live Emby Resume query: default=${containsSample(root)}, recursive=${containsSample("$root&Recursive=true")}, mediaTypeOnly=${containsSample("$root&MediaTypes=Video")}, defaultAgain=${containsSample(root)}")
                }
                assertTrue(get(resumePath).getJSONArray("Items").objects()
                    .any { it.getString("Id").replace("-", "") == id.replace("-", "") })
                assertEquals(6, responses.size)
                assertTrue(responses.all { it.getInt("status") == 204 })
                if (provider == "emby") assertEquals(listOf("TimeUpdate", "Pause", "Unpause", "TimeUpdate"),
                    responses.filter { it.getString("path").endsWith("Progress") }.map { it.getString("event") })
                println("Live $label $version reporting: start, progress, pause, unpause, seek, stop and resume verified")
                println("Live $label responses: " + org.json.JSONArray(responses).toString())
            } finally {
                reporter.stop("1"); reporter.awaitIdle(); reporter.close()
                try { if (restoreSample && original != null && sample != null) {
                    val id = sample!!.getString("Id")
                    val clearPath = if (provider == "emby") "Users/${account.userId}/PlayedItems/$id"
                        else "UserPlayedItems/$id?UserId=${account.userId}"
                    get(clearPath, method = "DELETE")
                    val restored = userData(id)
                    for (field in listOf("PlaybackPositionTicks", "PlayCount", "Played", "IsFavorite", "LastPlayedDate", "Likes", "Rating"))
                        assertEquals("Restored $field", original!!.opt(field), restored.opt(field))
                    println("Live $label reporting: original sample state restored")
                } } finally { get("Sessions/Logout", JSONObject()) }
            }
        }
    }
}
