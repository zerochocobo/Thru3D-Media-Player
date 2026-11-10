package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class WebBrowserDailymotionTest {
    private val owner="https://www.dailymotion.com/video/x5kesuj"
    private val frame="https://geo.dailymotion.com/player/official.html#settings=opaque"
    private val root="https://related.test:8443/current.m3u8?signature=exact"
    private fun media()=JSONObject().put("frame",frame).put("blob",true).put("source","").put("dailymotion_source","blob:https://geo.dailymotion.com/current")
        .put("width",848).put("height",480).put("duration",186.75342)
        .put("dailymotion",JSONObject().put("id","x5kesuj").put("page",owner).put("frame",frame).put("root",root).put("revision","a1")
            .put("width",848).put("height",480).put("duration",186.75342).put("expected_duration",187)
            .put("manifests",JSONArray().put(JSONObject().put("url",root).put("body","#EXTM3U\n#EXTINF:187,\nsegment.ts\n#EXT-X-ENDLIST\n").put("request_id","original"))))
        .put("network",JSONArray().put(JSONObject().put("url",root).put("kind","hls").put("request_id","original")))
    @Test fun hostedPlayerAndTrustedParentMustDescribeTheSameCurrentVideo() {
        val item=media();assertNotNull(WebBrowserDailymotion.metadata(item,owner))
        assertNull(WebBrowserDailymotion.metadata(item,"https://www.dailymotion.com/video/another"))
        assertNull(WebBrowserDailymotion.metadata(item,frame))
        assertTrue(WebBrowserDailymotion.frame(frame));assertFalse(WebBrowserDailymotion.frame(frame.replace("geo.dailymotion.com","geo.dailymotion.com.evil")))
        assertEquals("x5kesuj",WebBrowserDailymotion.page(owner));assertNull(WebBrowserDailymotion.page(owner.replace("dailymotion.com","dailymotion.com.evil")))
    }
    @Test fun observingTheApprovedHomepageDoesNotAuthorizeANativePlaybackTarget() {
        val root="https://www.dailymotion.com/"
        assertTrue(WebBrowserDailymotion.observing(root));assertFalse(WebBrowserDailymotion.enabled(root))
        assertNull(WebBrowserDailymotion.metadata(media(),root))
        for(value in listOf("http://www.dailymotion.com/","https://www.dailymotion.com.evil/","https://user@www.dailymotion.com/","https://www.dailymotion.com:8443/"))
            assertFalse(WebBrowserDailymotion.observing(value))
    }
    @Test fun protectionDifferentFrameOrTrackCannotBeValidatedByTheParentDomainAlone() {
        for(change in listOf<(JSONObject)->Unit>(
            {it.put("protected",true)},{it.put("frame",frame.replace("geo.dailymotion.com","unrelated.test"))},
            {it.put("dailymotion_source","blob:https://other.test/source")},{it.put("width",640)},
            {it.getJSONObject("dailymotion").put("frame",frame+"changed")},
            {it.getJSONObject("dailymotion").put("root",root+"&different=1")},
            {it.getJSONObject("dailymotion").put("expected_duration",30)},
            {it.getJSONObject("dailymotion").getJSONArray("manifests").getJSONObject(0).put("request_id","unrelated")}
        )){val item=media();change(item);assertNull(WebBrowserDailymotion.metadata(item,owner))}
    }
    @Test fun transportCopiesRemoveOnlyClientFragmentsAndKeepTheOriginalRequestIdentity() {
        val raw=root+"#client-marker";assertEquals(root,WebBrowserDailymotion.transport(raw).toString())
        val body="#EXTM3U\r\n#EXT-X-KEY:METHOD=AES-128,URI=\"key?signature=a%2Fb&literal=%23value#trace\"\r\nsegment.ts?signature=a%2Fb&literal=%23value#cell=main\r\n"
        val normalized=WebBrowserDailymotion.transportManifest(body,java.net.URI(root))
        assertEquals(body.replace("#trace","").replace("#cell=main",""),normalized)
        assertTrue(normalized.contains("signature=a%2Fb&literal=%23value"))
        assertNull(WebBrowserDailymotion.transport("https://user:password@related.test/current#marker"))
        val item=media();item.getJSONObject("dailymotion").getJSONArray("manifests").getJSONObject(0).put("request_url",raw)
        item.getJSONArray("network").getJSONObject(0).put("request_url",raw)
        assertNotNull(WebBrowserDailymotion.metadata(item,owner))
        item.getJSONArray("network").getJSONObject(0).put("request_url",root+"#different")
        assertNull(WebBrowserDailymotion.metadata(item,owner))
    }
    @Test fun selectedHostedFrameRequiresTheNativeInjectedParentAndOriginalSelection() {
        val item=media().put("dailymotion_enabled",true).put("dailymotion_ready",true)
            .put("dailymotion_owner",owner).put("capture_identity","tab:nav:port:video:epoch")
        assertSame(item,WebBrowserMediaPolicy.selectedCandidate(listOf(item),"tab:nav:port:video:epoch"))
        assertNull(WebBrowserMediaPolicy.selectedCandidate(listOf(item),"other-selection"))
        for(change in listOf<(JSONObject)->Unit>(
            {it.remove("dailymotion_owner")},{it.put("dailymotion_owner",frame)},
            {it.put("dailymotion_owner",owner.replace("x5kesuj","other"))},
            {it.put("dailymotion_enabled",false)},{it.put("dailymotion_ready",false)},{it.put("protected",true)}
        )){val copy=JSONObject(item.toString());change(copy);assertNull(WebBrowserMediaPolicy.selectedCandidate(listOf(copy),item.getString("capture_identity")))}
    }
}
