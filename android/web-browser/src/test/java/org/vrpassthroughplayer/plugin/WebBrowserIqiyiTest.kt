package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class WebBrowserIqiyiTest {
    private val page="https://www.iqiyi.com/v_current.html"
    private fun url(start: Int,end: Int,host: String="new-cdn.test")="https://$host/current.ts?start=$start&end=$end&contentlength=${end-start}&sd=${if(start>=188)2000 else 0}&qd_tvid=42&signature=EXACT"
    private fun record(start: Int,end: Int,cookie: String)=JSONObject().put("url",url(start,end)).put("kind","segment")
        .put("at",System.currentTimeMillis()).put("mime","application/octet-stream").put("headers",JSONObject().put("cookie",cookie))
    private fun item(): JSONObject {
        val playlist="#EXTM3U\n#EXT-X-TARGETDURATION:8\n#EXTINF:2,\n${url(0,188,"declared.test")}\n#EXTINF:8,\n${url(188,752,"declared.test")}\n#EXT-X-ENDLIST\n"
        return JSONObject().put("frame",page).put("source","").put("iqiyi_source","blob:current").put("blob",true).put("width",1280).put("height",544).put("duration",10.0)
            .put("iqiyi",JSONObject().put("ready",true).put("id","v_current").put("revision","a1").put("page",page).put("src","blob:current").put("tvid","42").put("vid","current").put("bid",500)
                .put("ff","ts").put("drm_type",1).put("has_drm",false).put("has_root_drm",true).put("width",1280).put("height",544).put("duration",10.0).put("playlist",playlist))
            .put("network",JSONArray().put(record(0,188,"first=only")).put(record(164,752,"second=only"))
                .put(JSONObject().put("kind","hls").put("url","https://observed.test/current.m3u8?qd_tvid=42").put("headers",JSONObject())))
    }
    @Test fun mapsCompleteTimelineOverExactObservedRangesWithoutChangingUrlsOrCredentials() {
        val m=item();val plan=WebBrowserIqiyi.plan(m,page)!!;val text=plan.getString("playlist")
        assertTrue(text.contains("#EXT-X-BYTERANGE:188@0\n${url(0,188)}"))
        assertTrue(text.contains("#EXT-X-BYTERANGE:564@24\n${url(164,752)}"))
        assertFalse(text.contains("declared.test"));assertTrue(text.contains("#EXTINF:8.0,"))
        val requests=plan.getJSONArray("network")
        assertEquals(2,requests.length());assertEquals("first=only",requests.getJSONObject(0).getJSONObject("headers").getString("cookie"))
        assertEquals("second=only",requests.getJSONObject(1).getJSONObject("headers").getString("cookie"))
        assertTrue(WebBrowserIqiyi.enabled(page))
    }
    @Test fun currentElementTrackDimensionsProtectionAndDurationCannotBeBorrowed() {
        val changes:List<(JSONObject)->Unit> = listOf({it.put("iqiyi_source","blob:replacement")},{it.put("protected",true)},
            {it.put("width",960)},{it.put("duration",60.0)},{it.getJSONObject("iqiyi").put("has_drm",true)},
            {it.getJSONObject("iqiyi").put("drm_type",2)},{it.getJSONObject("iqiyi").put("ready",false)})
        for(change in changes) {val m=item();change(m);assertNull(WebBrowserIqiyi.plan(m,page))}
        assertNull(WebBrowserIqiyi.plan(item(),"https://other.test/v_current.html"))
    }
    @Test fun missingRangesDifferentFilesAndItemsJsonDispatchAndStaleRequestsCannotFillTheTail() {
        val changes:List<(JSONObject)->Unit> = listOf({it.getJSONArray("network").remove(1)},
            {it.getJSONArray("network").getJSONObject(1).put("url",url(164,752).replace("current.ts","other.ts"))},
            {it.getJSONArray("network").getJSONObject(1).put("url",url(164,752).replace("qd_tvid=42","qd_tvid=43"))},
            {it.getJSONArray("network").getJSONObject(1).put("mime","application/json")},
            {it.getJSONArray("network").getJSONObject(1).put("at",System.currentTimeMillis()-1800001)})
        for(change in changes) {val m=item();change(m);assertNull(WebBrowserIqiyi.plan(m,page))}
    }
    @Test fun protectedIncompleteDuplicateSelectorAndAmbiguousManifestDeclarationsAreRejected() {
        for(edit in listOf<(String)->String>({it.replace("#EXTINF:2,","#EXT-X-KEY:METHOD=SAMPLE-AES\n#EXTINF:2,")},
            {it.replace("#EXT-X-ENDLIST","")},{it.replace("start=188","start=188&start=189")},
            {it.replace("contentlength=564","contentlength=752")})) {
            val m=item();m.getJSONObject("iqiyi").put("playlist",edit(m.getJSONObject("iqiyi").getString("playlist")))
            assertNull(WebBrowserIqiyi.plan(m,page))
        }
        val m=item();m.getJSONArray("network").put(JSONObject().put("kind","hls").put("url","https://second.test/list.m3u8?qd_tvid=42").put("headers",JSONObject()))
        assertNull(WebBrowserIqiyi.plan(m,page))
    }
    @Test fun sdkCompleteFileDeclarationsDoNotNeedAnObservedHlsOrBufferedTail() {
        val m=item();m.put("network",JSONArray())
        m.getJSONObject("iqiyi").put("dispatch_duration_ms",10000).put("dispatch_status","selected_level").put("dispatchers",JSONArray().put(JSONObject()
            .put("url",url(0,752,"declared.test")).put("source_id","current").put("start",0).put("end",752)))
        val plan=WebBrowserIqiyi.resourcePlan(m,page)!!
        assertEquals(2,plan.getJSONArray("requests").length());assertEquals(1,plan.getJSONArray("files").length())
        m.getJSONObject("iqiyi").getJSONArray("dispatchers").getJSONObject(0).put("end",188)
        assertNull(WebBrowserIqiyi.resourcePlan(m,page))
    }
    @Test fun sdkTimeAnchorsNormalizeRoundedExtinfWithoutChangingRangeUrls() {
        val m=item();m.getJSONObject("iqiyi").put("dispatch_duration_ms",10000).put("dispatch_status","selected_level")
            .put("dispatchers",JSONArray().put(JSONObject().put("url",url(0,752,"declared.test")).put("source_id","current").put("start",0).put("end",752)))
        m.getJSONObject("iqiyi").put("playlist",m.getJSONObject("iqiyi").getString("playlist").replace("#EXTINF:8,","#EXTINF:7,"))
        val body=WebBrowserIqiyi.resourcePlan(m,page)!!.getString("playlist")
        assertTrue(body.contains("#EXTINF:8.0,"));assertTrue(body.contains(url(188,752,"declared.test")))
        m.getJSONObject("iqiyi").put("dispatch_duration_ms",20000);assertNull(WebBrowserIqiyi.resourcePlan(m,page))
    }
    @Test fun explicitSelectionOnlyAcceptsTheBoundCurrentItemAndRevision() {
        val m=item().put("iqiyi_enabled",true).put("iqiyi_ready",true).put("capture_identity","selected")
        assertNotNull(WebBrowserMediaPolicy.selectedCandidate(listOf(m),"selected"))
        assertNull(WebBrowserMediaPolicy.selectedCandidate(listOf(m),"other"))
        m.getJSONObject("iqiyi").put("id","v_replaced");assertNull(WebBrowserMediaPolicy.selectedCandidate(listOf(m),"selected"))
    }
}
