package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class WebBrowserNaverTest {
    private val id="A".repeat(36)
    private val page=WebBrowserNaver.canonical(id)
    private val source="https://related.test:8443/current.mp4?signature=synthetic&quality=hd"
    private val current=source+"#tid="+"T".repeat(22)
    private fun media(frame: String=page)=JSONObject().put("frame",frame).put("source",current).put("naver_source",source)
        .put("width",1280).put("height",548).put("duration",2118.379682).put("capture_identity","selected")
        .put("naver_enabled",true).put("naver_ready",true)
        .put("naver",JSONObject().put("id",id).put("page",page).put("document",frame).put("source",source).put("current_source",current)
            .put("fragment_kind","tracking").put("binding","received_card_mpd").put("revision","a1")
            .put("width",1280).put("height",548).put("duration",2118.379682).put("expected_duration",2118.38))
        .put("network",JSONArray().put(JSONObject().put("kind","file").put("url",source).put("request_url",current)
            .put("headers",JSONObject().put("authorization","OWN_REQUEST"))))

    @Test fun currentCardCanDifferFromTheNavigationSeedWithoutChangingRequestScope() {
        val frame=WebBrowserNaver.canonical("B".repeat(36));val item=media(frame).put("playing",false)
        assertEquals(id,WebBrowserNaver.metadata(item,frame)?.getString("id"))
        assertSame(item,WebBrowserMediaPolicy.selectedCandidate(listOf(item),"selected"))
        assertEquals("OWN_REQUEST",WebBrowserNetworkMedia.candidates(item).getJSONObject(0).getJSONObject("headers").getString("authorization"))
        assertNull(WebBrowserMediaPolicy.selectedCandidate(listOf(item,media(frame)),"selected"))
    }
    @Test fun arbitraryFragmentsChangedSignaturesAndOtherRawRequestsStayRejected() {
        for(change in listOf<(JSONObject)->Unit>(
            {it.put("protected",true)},{it.put("blob",true)},{it.put("frame",page+"&changed=1")},
            {it.put("source",source+"#unknown=1")},{it.put("naver_source",source+"&changed=1")},
            {it.put("network",JSONArray())},{it.put("width",640)},{it.put("duration",2200)},
            {it.getJSONObject("naver").put("id","B".repeat(36))},{it.getJSONObject("naver").put("expected_duration",2200)},
            {it.getJSONObject("naver").put("current_source",source+"#tid="+"Q".repeat(22))},
            {it.getJSONArray("network").getJSONObject(0).put("request_url",source+"#tid="+"Q".repeat(22))},
            {it.getJSONArray("network").getJSONObject(0).remove("request_url")}
        )){val item=media();change(item);assertNull(WebBrowserNaver.metadata(item,page))}
    }
    @Test fun boundedTemporalFragmentsStillNeedTheSameDeclaredHttpFile() {
        val item=media().put("source",source+"#t=0.001")
        item.getJSONObject("naver").put("current_source",source+"#t=0.001").put("fragment_kind","temporal")
        assertNotNull(WebBrowserNaver.metadata(item,page))
        item.put("source",source+"#t=9999");item.getJSONObject("naver").put("current_source",source+"#t=9999")
        assertNull(WebBrowserNaver.metadata(item,page))
    }
    @Test fun onlyTheOfficialNtvDocumentAndCanonicalPublicIdentityMatch() {
        assertEquals(id,WebBrowserNaver.page(page))
        for(bad in listOf(page.replace("https:","http:"),page.replace("m.naver.com","m.naver.com.evil"),
            page.replace("https://","https://user@"),page+"&serviceType=OTHER",page.replace("NTV","OTHER")))assertFalse(WebBrowserNaver.enabled(bad))
        assertNull(WebBrowserNaver.page(page+"&seedMediaId="+"B".repeat(36)))
    }
    @Test fun unsupportedSameDocumentTimelineServicesRetainObservationsButCannotAuthorizeBeta() {
        val moment=page.replace("NTV","MOMENT")
        assertTrue(WebBrowserNaver.observing(moment));assertFalse(WebBrowserNaver.enabled(moment))
        assertNull(WebBrowserNaver.metadata(media(moment),moment))
        assertFalse(WebBrowserNaver.observing(moment.replace("m.naver.com","m.naver.com.evil")))
    }
    private fun clip(): JSONObject {
        val frame=WebBrowserNaver.canonical(id,"CLIP")
        val root="https://declared.test/current.m3u8?signature=ROOT"
        val item=media(frame).put("source", "").put("naver_source",root).put("blob",true)
            .put("width",1080).put("height",1920).put("duration",26.379777)
        item.getJSONObject("naver").put("page",frame).put("service_type","CLIP").put("format","segment_timeline")
            .put("source",root).put("current_source","blob:https://m.naver.com/current").put("fragment_kind","blob")
            .put("width",1080).put("height",1920).put("duration",26.379777).put("expected_duration",26.38)
            .put("timeline",JSONObject().put("base","https://segments.test/current/").put("media","\$RepresentationID\$-\$Number\$.ts?signature=EXACT")
                .put("representation","1080p").put("start",0).put("timescale",1000).put("rows",JSONArray()
                    .put(JSONObject().put("t",0).put("d",4000).put("r",5)).put(JSONObject().put("t",24000).put("d",2333).put("r",0))))
        return item.put("network",JSONArray().put(JSONObject().put("kind","segment").put("url","https://segments.test/current/1080p-0.ts?signature=EXACT")
            .put("headers",JSONObject().put("authorization","THIS_SEGMENT_ONLY"))))
    }
    @Test fun receivedClipTimelineReconstructsExactSignedSegmentsWithoutPromotingTheExportToAnObservedRequest() {
        val item=clip();val frame=item.getString("frame")
        assertNotNull(WebBrowserNaver.metadata(item,frame))
        val plan=requireNotNull(WebBrowserNaver.timeline(item,frame))
        assertEquals(7,plan.refs.size);assertEquals(26.333,plan.duration,.00001)
        assertTrue(plan.refs.contains("https://segments.test/current/1080p-6.ts?signature=EXACT"))
        assertFalse(plan.playlist.contains("signature=ROOT"));assertTrue(plan.playlist.endsWith("#EXT-X-ENDLIST\n"))
        assertEquals(frame,WebBrowserNaver.canonicalPage(frame))
    }
    @Test fun clipRequiresTheCurrentWatchIdentityAndTheExactObservedRepresentationSignature() {
        for(change in listOf<(JSONObject)->Unit>(
            {it.put("frame",WebBrowserNaver.canonical("B".repeat(36),"CLIP"));it.getJSONObject("naver").put("document",it.getString("frame"))},
            {it.put("blob",false)}, {it.put("source","blob:https://other.test/current");it.getJSONObject("naver").put("current_source",it.getString("source"))},
            {it.getJSONArray("network").getJSONObject(0).put("url","https://segments.test/current/720p-0.ts?signature=EXACT")},
            {it.getJSONArray("network").getJSONObject(0).put("url","https://segments.test/current/1080p-0.ts?signature=CHANGED")}
        )){val item=clip();change(item);assertNull(WebBrowserNaver.metadata(item,item.getString("frame")))}
    }
    @Test fun clipTimelineHolesUnboundedRepeatsAndUnknownSubstitutionsAreRejectedAgainInNative() {
        for(change in listOf<(JSONObject)->Unit>(
            {it.getJSONArray("rows").getJSONObject(1).put("t",23999)}, {it.getJSONArray("rows").getJSONObject(0).put("r",-1)},
            {it.getJSONArray("rows").getJSONObject(0).put("r",2048)}, {it.put("media","\$Time\$.ts")},
            {it.put("timescale",0)}, {it.put("base","https://segments.test/current/?different=1")}
        )){val item=clip();change(item.getJSONObject("naver").getJSONObject("timeline"));assertNull(WebBrowserNaver.metadata(item,item.getString("frame")))}
    }
    @Test fun clipNumberPaddingMatchesTheExactDeclaredSignedSegment() {
        val item=clip()
        item.getJSONObject("naver").getJSONObject("timeline").put("media","\$RepresentationID\$-\$Number%05d\$.ts?signature=EXACT")
        item.getJSONArray("network").getJSONObject(0).put("url","https://segments.test/current/1080p-00000.ts?signature=EXACT")
        val plan=requireNotNull(WebBrowserNaver.timeline(item,item.getString("frame")))
        assertTrue(plan.refs.contains("https://segments.test/current/1080p-00006.ts?signature=EXACT"))
    }
    @Test fun oneMillisecondGapsPreserveTheDeclaredSegmentStartTimes() {
        val item=clip().put("duration",12.330687);val data=item.getJSONObject("naver")
        data.put("duration",12.330687).put("expected_duration",12.331)
        data.getJSONObject("timeline").put("rows",JSONArray().put(JSONObject().put("t",0).put("d",4003).put("r",0))
            .put(JSONObject().put("t",4003).put("d",4004).put("r",0)).put(JSONObject().put("t",8008).put("d",4003).put("r",0))
            .put(JSONObject().put("t",12012).put("d",266).put("r",0)))
        val plan=requireNotNull(WebBrowserNaver.timeline(item,item.getString("frame")))
        assertEquals(12.278,plan.duration,.000001);assertTrue(plan.playlist.contains("#EXTINF:4.005,"));assertTrue(plan.playlist.contains("#EXTINF:4.004,"))
        data.getJSONObject("timeline").getJSONArray("rows").getJSONObject(2).put("t",8009)
        assertNull(WebBrowserNaver.timeline(item,item.getString("frame")))
    }
}
