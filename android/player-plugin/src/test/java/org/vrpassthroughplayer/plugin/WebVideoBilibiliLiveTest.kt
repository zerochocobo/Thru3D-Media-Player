package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class WebVideoBilibiliLiveTest {
    private val page = "https://live.bilibili.com/12345?from=live"
    private val url = "https://live-test.bilivideo.com/live/12345.m3u8?token=synthetic"

    private fun media() = JSONObject().put("frame", page).put("blob", true).put("duration", 0)
        .put("width", 1920).put("height", 1080).put("bilibili_source", "blob:https://live.bilibili.com/source")
        .put("bilibili_enabled", true).put("bilibili_ready", true).put("capture_identity", "selected")
        .put("bilibili_live", JSONObject().put("page", page).put("room", "12345").put("quality", 400)
            .put("revision", 1).put("url", url))
        .put("network", JSONArray().put(JSONObject().put("kind", "hls").put("url", url)
            .put("at", System.currentTimeMillis()).put("headers", JSONObject().put("user-agent", "test"))))

    @Test fun usesTheCurrentRoomsExactPrivatePlaylist() {
        val descriptor = requireNotNull(WebVideoBilibiliLive.descriptor(page, media(), "selected"))
        assertEquals("bilibili_live", descriptor.page.site)
        assertEquals("https://live.bilibili.com/12345", descriptor.page.url)
        assertEquals("live_hls", descriptor.video.transport)
        assertEquals(url, descriptor.video.url.toString())
        assertFalse(descriptor.publicJson().toString().contains("synthetic"))
    }

    @Test fun rejectsPreviousSelectionAndUnboundOrProtectedMedia() {
        assertNull(WebVideoBilibiliLive.descriptor(page, media(), "previous"))
        assertNull(WebVideoBilibiliLive.descriptor(page.replace("12345", "54321"), media(), "selected"))
        for (change in listOf<(JSONObject) -> Unit>(
            { it.put("protected", true) },
            { it.put("duration", 120) },
            { it.getJSONObject("bilibili_live").put("revision", 1.5) },
            { it.getJSONArray("network").getJSONObject(0).put("url", "$url&other=1") },
            { it.getJSONArray("network").getJSONObject(0).put("at", 1) },
            { it.getJSONArray("network").getJSONObject(0).put("headers", JSONObject()) },
        )) {
            val item = media()
            change(item)
            assertNull(WebVideoBilibiliLive.descriptor(page, item, "selected"))
        }
    }

    @Test fun usesDelegatedCdnOnlyWithTheObservedMasterAndItsOwnLeafRequest() {
        val child = "https://edge.smtcdns.net/current.m3u8?token=leaf"
        val item = media()
        item.getJSONObject("bilibili_live").put("url", child).put("master", url)
        val requests = item.getJSONArray("network")
        requests.put(JSONObject().put("kind", "hls").put("url", child).put("live_leaf", true)
            .put("at", System.currentTimeMillis()).put("headers", JSONObject().put("user-agent", "leaf only")))
        assertNull(WebVideoBilibiliLive.descriptor(page, item, "selected"))
        requests.getJSONObject(0).put("live_child", child)
        val descriptor = requireNotNull(WebVideoBilibiliLive.descriptor(page, item, "selected"))
        assertEquals(child, descriptor.video.url.toString())
        assertEquals("leaf only", descriptor.video.headers["user-agent"])
    }

    @Test fun requiresTheNewSwitchRequestToMatchTheStreamAndExactTier() {
        val rendition = "https://live-test.bilivideo.com/live/live_selected/index.m3u8?qn=250&sign=exact"
        val now = System.currentTimeMillis()
        val item = media()
        val live = item.getJSONObject("bilibili_live").put("url", rendition).put("quality", 250)
            .put("stream", "live_selected").put("switch_at", now - 200)
        val request = item.getJSONArray("network").getJSONObject(0)
        request.put("url", rendition).put("live_leaf", true).put("at", now - 100)
        val descriptor = requireNotNull(WebVideoBilibiliLive.descriptor(page, item, "selected"))
        assertEquals(rendition, descriptor.video.url.toString())

        live.put("switch_at", now)
        assertNull(WebVideoBilibiliLive.descriptor(page, item, "selected"))
        live.put("switch_at", now - 200).put("stream", "live_select")
        assertNull(WebVideoBilibiliLive.descriptor(page, item, "selected"))
        live.put("stream", "live_selected").put("quality", 400)
        assertNull(WebVideoBilibiliLive.descriptor(page, item, "selected"))
        live.put("quality", 250)
        request.put("live_leaf", false)
        assertNull(WebVideoBilibiliLive.descriptor(page, item, "selected"))
    }
}
