package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class EmbySourceLocationTest {
    @Test fun episodeDetailRetainsItsSeasonWithoutRetainingPhysicalPath() {
        val episode = """{"Id":"episode","Name":"Episode 1","Type":"Episode","ParentId":"season","SeasonId":"season",
            "SeriesId":"series","SeriesName":"Series","Path":"/private/series/01.mp4","MediaSources":[],"Chapters":[]}"""
        for (provider in listOf("emby", "jellyfin")) {
            MediaServerClientTest.Fixture { _, _, _ -> MediaServerClientTest.Reply(body = episode.toByteArray()) }.use { fixture ->
                val account = MediaServerAccount("test", "Test", fixture.url, "fake", provider, "user1")
                MediaServerHttp(account).use { http ->
                    val detail = EmbyClient(account, http).detail("episode")
                    assertEquals("season", detail.getString("parent_id"))
                    assertEquals("season", detail.getString("season_id"))
                    assertEquals("series", detail.getString("series_id"))
                    assertEquals("Series", detail.getString("series_title"))
                    assertFalse(detail.toString().contains("/private/series"))
                }
            }
        }
    }
}
