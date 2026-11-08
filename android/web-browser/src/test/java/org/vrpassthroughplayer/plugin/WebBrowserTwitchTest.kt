package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class WebBrowserTwitchTest {
    private val page = "https://clips.twitch.tv/PublicClip"
    private val source = "https://actual-related.test/clip.mp4?token=synthetic&sig=exact"
    private fun media() = JSONObject().put("frame", page).put("source", source).put("width", 1920).put("height", 1080)
        .put("duration", 32.099).put("capture_identity", "selected").put("twitch_enabled", true).put("twitch_ready", true)
        .put("twitch", JSONObject().put("id", "PublicClip").put("page", page).put("source", source).put("revision", "ab12")
            .put("width", 1920).put("height", 1080).put("duration", 32.099).put("expected_duration", 32.0))
        .put("network", JSONArray().put(JSONObject().put("kind", "file").put("url", source).put("headers", JSONObject())))

    @Test fun exactClipFileAndPausedSelectionArePreserved() {
        val item = media()
        assertNotNull(WebBrowserTwitch.metadata(item, page))
        assertNotNull(WebBrowserTwitch.metadata(item.put("playing", false), page))
        assertSame(item, WebBrowserMediaPolicy.selectedCandidate(listOf(item), "selected"))
        assertNull(WebBrowserMediaPolicy.selectedCandidate(listOf(item, media()), "selected"))
        assertNull(WebBrowserMediaPolicy.selectedCandidate(listOf(item), "other"))
    }

    @Test fun rejectProtectionWrongClipSourceAndDuration() {
        for (change in listOf<(JSONObject) -> Unit>(
            { it.put("protected", true) }, { it.put("blob", true) }, { it.put("source", source + "&quality=720") },
            { it.put("network", JSONArray()) }, { it.put("frame", page + "?changed=1") }, { it.put("width", 640) },
            { it.put("duration", 6) }, { it.getJSONObject("twitch").put("id", "OtherClip") },
            { it.getJSONObject("twitch").put("expected_duration", Double.NaN.toString()) }
        )) {
            val item = media(); change(item); assertNull(WebBrowserTwitch.metadata(item, page))
        }
        assertNull(WebBrowserMediaPolicy.selectedCandidate(listOf(media().put("twitch_ready", false)), "selected"))
    }

    @Test fun onlyOfficialClipPagesCanUseThisAdapter() {
        assertEquals("PublicClip", WebBrowserTwitch.page("https://www.twitch.tv/ea/clip/PublicClip?tt_medium=clips_api"))
        for (bad in listOf("http://clips.twitch.tv/PublicClip", "https://clips.twitch.tv.evil/PublicClip", "https://clips.twitch.tv/embed?clip=PublicClip",
            "https://www.twitch.tv/ea", "https://www.twitch.tv/videos/123", "https://clips.twitch.tv/Bad%2FClip", page + "#other"))
            assertNull(WebBrowserTwitch.page(bad))
    }
}
