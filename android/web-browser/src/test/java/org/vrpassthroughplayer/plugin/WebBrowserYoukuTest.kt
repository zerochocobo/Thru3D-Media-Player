package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class WebBrowserYoukuTest {
    private val page="https://v.youku.com/v_show/id_XOTUxMzg4NDMy.html"
    private val source="https://new-cdn.test/current.m3u8?signature=exact"
    private fun item()=JSONObject().put("frame",page).put("blob",true).put("source","").put("width",960).put("height",540).put("duration",702.079)
        .put("youku_enabled",true).put("youku_ready",true).put("capture_identity","selected")
        .put("network",JSONArray().put(JSONObject().put("url",source).put("kind","hls").put("headers",JSONObject())))
        .put("youku",JSONObject().put("id","XOTUxMzg4NDMy").put("page",page).put("revision","a1").put("declared_drm","default")
            .put("width",960).put("height",540).put("duration",702.079).put("expected_duration",702.08).put("manifests",JSONArray().put(source))
            .put("declarations",JSONArray().put(JSONObject().put("url",source.replace("https:","http:")).put("width",960).put("height",540).put("duration",702.079))))
    @Test fun currentProgrammeAndExactTransportUpgradeSurvivePause() {
        val m=item();assertEquals("XOTUxMzg4NDMy",WebBrowserYouku.page(page));assertNotNull(WebBrowserYouku.metadata(m,page))
        assertNotNull(WebBrowserYouku.metadata(m.put("playing",false),page));assertSame(m,WebBrowserMediaPolicy.selectedCandidate(listOf(m),"selected"))
        for(url in listOf(page.replace("https:","http:"),page.replace("v.youku.com","v.youku.com.evil"),page+"#other"))assertNull(WebBrowserYouku.page(url))
    }
    @Test fun currentIdentitySizeDurationAndProtectionRemainRequired() {
        for(change in listOf<(JSONObject)->Unit>(
            {it.put("protected",true)},{it.put("blob",false)},{it.put("width",1920)},
            {it.getJSONObject("youku").put("id","XOTHER")},{it.getJSONObject("youku").put("revision","invalid")},
            {it.getJSONObject("youku").put("declared_drm","cbcs")},{it.getJSONObject("youku").put("expected_duration",1200)},
            {it.getJSONObject("youku").getJSONArray("declarations").getJSONObject(0).put("width",1920)})) {
            val m=item();change(m);assertNull(WebBrowserYouku.metadata(m,page))
        }
    }
    @Test fun signatureSelectorsAndSuccessfulObservedRequestCannotBeReplaced() {
        for(url in listOf(source+"&new=selector",source.replace("exact","other"),source.replace("new-cdn","other-cdn"))) {
            val m=item();m.getJSONArray("network").getJSONObject(0).put("url",url);assertNull(WebBrowserYouku.metadata(m,page))
        }
        assertFalse(WebBrowserYouku.sameManifest(source,source.replace("https:","http:")))
        val m=item();m.getJSONArray("network").getJSONObject(0).put("url","https://redirected-cdn.test/full.m3u8").put("original_url",source)
        m.getJSONObject("youku").put("manifests",JSONArray().put("https://redirected-cdn.test/full.m3u8"));assertNotNull(WebBrowserYouku.metadata(m,page))
    }
}
