package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class WebBrowserNiconicoTest {
    @Test fun mainSiteCanObservePrefetchButOnlyWatchPagesEnablePlayback() {
        val home="https://www.nicovideo.jp/"
        assertTrue(WebBrowserNiconico.observing(home));assertFalse(WebBrowserNiconico.enabled(home))
        assertTrue(WebBrowserNiconico.observing("https://www.nicovideo.jp/watch/sm9"))
        for(value in listOf("http://www.nicovideo.jp/","https://www.nicovideo.jp.evil/","https://other@www.nicovideo.jp/","https://www.nicovideo.jp:8443/","https://www.nicovideo.jp/#x"))
            assertFalse(WebBrowserNiconico.observing(value))
    }
    private val page="https://www.nicovideo.jp/watch/sm9"
    private fun item(): JSONObject {
        val root="https://related.test/master.m3u8?sig=root";val video="https://video.test/current.m3u8?sig=video";val audio="https://audio.test/current.m3u8?sig=audio"
        val key="https://keys.test/current?sig=key"
        val network=JSONArray()
        for(url in listOf(root,video,audio,key))network.put(JSONObject().put("url",url).put("kind",if(url==key)"segment" else "hls").put("headers",JSONObject()))
        return JSONObject().put("frame",page).put("blob",true).put("source","").put("niconico_source","blob:https://www.nicovideo.jp/current")
            .put("width",512).put("height",384).put("duration",219.1).put("niconico_enabled",true).put("niconico_ready",true).put("capture_identity","selected")
            .put("network",network).put("niconico",JSONObject().put("id","sm9").put("page",page).put("revision","ab1")
                .put("root",root).put("video",video).put("audio",audio).put("resources",JSONArray().put(key))
                .put("master_playlist","#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=800000\n$video\n")
                .put("width",512).put("height",384).put("duration",219.1).put("expected_duration",219.1).put("audio_duration",219.08)
                .put("vcodec","avc1.64001e").put("acodec","mp4a.40.2"))
    }
    @Test fun currentGraphSurvivesPauseAndUsesTheExplicitSelection() {
        val m=item();assertEquals("sm9",WebBrowserNiconico.page(page));assertNotNull(WebBrowserNiconico.metadata(m,page))
        assertNotNull(WebBrowserNiconico.metadata(m.put("playing",false),page));assertSame(m,WebBrowserMediaPolicy.selectedCandidate(listOf(m),"selected"))
        assertNull(WebBrowserMediaPolicy.selectedCandidate(listOf(m),"old-selection"))
    }
    @Test fun pageOwnerDimensionsDurationAndProtectionCannotChange() {
        for(change in listOf<(JSONObject)->Unit>(
            {it.put("protected",true)},{it.put("blob",false)},{it.put("niconico_source","blob:https://other.test/current")},
            {it.put("width",960)},{it.put("duration",15)}, {it.getJSONObject("niconico").put("id","sm10")},
            {it.getJSONObject("niconico").put("page",page+"?changed=1")},{it.getJSONObject("niconico").put("revision","bad revision")},
            {it.getJSONObject("niconico").put("audio_duration",15)})) {
            val m=item();change(m);assertNull(WebBrowserNiconico.metadata(m,page))
        }
        for(url in listOf(page.replace("https:","http:"),page.replace("www.nicovideo.jp","www.nicovideo.jp.evil"),page+"#other"))assertNull(WebBrowserNiconico.page(url))
    }
    @Test fun everyExactManifestAndResourceRequestMustBePresent() {
        for(index in 0..3){val m=item();m.getJSONArray("network").getJSONObject(index).put("url","https://other.test/not-current");assertNull(WebBrowserNiconico.metadata(m,page))}
        val m=item();m.getJSONObject("niconico").put("audio",m.getJSONObject("niconico").getString("video"));assertNull(WebBrowserNiconico.metadata(m,page))
    }
}
