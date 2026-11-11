package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class WebBrowserIqiyiTest {
    private val page="https://www.iqiyi.com/v_current.html"
    private fun largeWire(): JSONObject = javaClass.getResourceAsStream("/iqiyi-large-wire.json")!!.bufferedReader().use { JSONObject(it.readText()) }
    @Test fun restoresTheActualJavascriptTransportVectorBeforeFullRangeValidation() {
        val item=largeWire();val page=item.getString("frame")
        assertTrue(item.toString().length<132*1024)
        val plan=WebBrowserIqiyi.resourcePlan(item,page)!!
        val packed=item.getJSONObject("iqiyi").getJSONObject("playlist_delta")
        val encoded=packed.getJSONArray("rows").toString()
        packed.put("version",2).put("rows",encoded)
        assertEquals(plan.toString(),WebBrowserIqiyi.resourcePlan(item,page)!!.toString())
        packed.put("rows",encoded+"[]")
        assertNull(WebBrowserIqiyi.metadata(item,page))
        val text=plan.getString("playlist");assertTrue(text.length>256*1024)
        assertEquals(436,plan.getJSONArray("requests").length())
        for(i in 0 until 436) {
            val expected="https://declared.test/current.ts?start=${i*188}&end=${(i+1)*188}&contentlength=188&sd=${i*1000}&qd_tvid=42&issued=UNIT%2bEXACT%3D&opaque=${"ab".repeat(256)}"
            assertEquals(expected,plan.getJSONArray("requests").getJSONObject(i).getString("url"))
            assertTrue(text.contains(expected+"\n"))
        }
    }
    @Test fun corruptOrAmbiguousPackedTimelinesCannotPassTheNormalParser() {
        val edits:List<(JSONObject)->Unit> = listOf(
            { it.put("playlist","#EXTM3U") },
            { it.getJSONObject("playlist_delta").put("chars",512*1024+1) },
            { it.getJSONObject("playlist_delta").put("chars","300000") },
            { it.getJSONObject("playlist_delta").put("version",1.0) },
            { it.getJSONObject("playlist_delta").getJSONArray("rows").getJSONArray(0).put(0,1) },
            { it.getJSONObject("playlist_delta").getJSONArray("rows").getJSONArray(2).put(1,999999) },
            { it.getJSONObject("playlist_delta").getJSONArray("rows").getJSONArray(0).put(2,"#EXTM3U\n") },
            { val d=it.getJSONObject("playlist_delta");d.put("chars",d.getInt("chars")-1) },
            { val rows=it.getJSONObject("playlist_delta").getJSONArray("rows");rows.remove(rows.length()-2) }
        )
        for(edit in edits) {
            val item=largeWire();edit(item.getJSONObject("iqiyi"));assertNull(WebBrowserIqiyi.metadata(item,item.getString("frame")))
        }
    }
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
    @Test fun integerMseTotalNeedsTheCompletePlaylistAndMatchingSdkEndAnchor() {
        val m=item();val data=m.getJSONObject("iqiyi")
        data.put("dispatch_duration_ms",9480).put("sdk_duration_ms",9480).put("dispatch_status","selected_level")
            .put("dispatchers",JSONArray().put(JSONObject().put("url",url(0,752,"declared.test"))
                .put("source_id","current").put("start",0).put("end",752)))
        assertTrue(WebBrowserIqiyi.resourcePlan(m,page)!!.getString("playlist").contains("#EXTINF:7.48,"))
        data.put("sdk_duration_ms",9000);assertNull(WebBrowserIqiyi.resourcePlan(m,page))
        data.put("sdk_duration_ms",9480).put("playlist",data.getString("playlist").replace("#EXTINF:8,","#EXTINF:7,"))
        assertNull(WebBrowserIqiyi.resourcePlan(m,page))
        data.put("dispatch_duration_ms",8480).put("sdk_duration_ms",8480);assertNull(WebBrowserIqiyi.resourcePlan(m,page))
    }
    @Test fun oneSecondMseRoundingRequiresTheExactEndOfTheDeclaredSegments() {
        for ((dispatchMs, lastStart, firstExtinf) in listOf(Triple(9000, 2000, 3), Triple(9120, 2120, 2), Triple(9160, 2160, 1))) {
            val m=item();val data=m.getJSONObject("iqiyi")
            data.put("dispatch_duration_ms",dispatchMs).put("sdk_duration_ms",dispatchMs)
                .put("dispatch_status","selected_level").put("dispatchers",JSONArray().put(JSONObject()
                    .put("url",url(0,752,"declared.test")).put("source_id","current").put("start",0).put("end",752)))
            val playlist=data.getString("playlist").replace("#EXTINF:2,","#EXTINF:$firstExtinf,")
                .replace("#EXTINF:8,","#EXTINF:7,").replace("sd=2000","sd=$lastStart")
            data.put("playlist",playlist)
            val plan=WebBrowserIqiyi.resourcePlan(m,page)!!
            val body=plan.getString("playlist")
            val lastDuration=body.lineSequence().last { it.startsWith("#EXTINF:") }
                .substringAfter(':').substringBefore(',').toDouble()
            assertEquals(7.0,lastDuration,1e-9)
            assertTrue(body.contains(url(188,752,"declared.test").replace("sd=2000","sd=$lastStart")))
            for (invalid in listOf(playlist.replace("sd=$lastStart","sd=${lastStart+1}"),
                playlist.replace("sd=$lastStart","sd=$lastStart&sd=$lastStart"),playlist.replace("#EXT-X-ENDLIST",""),
                playlist.replace("#EXTINF:$firstExtinf,","#EXTINF:0.5,"))) {
                data.put("playlist",invalid)
                assertNull(WebBrowserIqiyi.resourcePlan(m,page))
            }
            data.put("playlist",playlist).put("sdk_duration_ms",dispatchMs+1)
            assertNull(WebBrowserIqiyi.resourcePlan(m,page))
        }
    }
    @Test fun zeroExtinfNeedsASubsecondSpanOnTheCurrentSdkTimeline() {
        val m=item();val data=m.getJSONObject("iqiyi")
        data.put("dispatch_duration_ms",10000).put("sdk_duration_ms",10000)
            .put("dispatch_status","selected_level").put("dispatchers",JSONArray().put(JSONObject()
                .put("url",url(0,752,"declared.test")).put("source_id","current").put("start",0).put("end",752)))
        val playlist=data.getString("playlist").replace("#EXTINF:2,","#EXTINF:0,")
            .replace("#EXTINF:8,","#EXTINF:10,").replace("sd=2000","sd=500")
        data.put("playlist",playlist)
        val normalized=WebBrowserIqiyi.resourcePlan(m,page)!!.getString("playlist")
        assertTrue(normalized.contains("#EXTINF:0.5,"))
        assertTrue(normalized.contains("#EXTINF:9.5,"))
        assertNull(WebBrowserIqiyi.plan(m,page))
        for (unbound in listOf(0,1000,1500)) {
            data.put("playlist",playlist.replace("sd=500","sd=$unbound"))
            assertNull(WebBrowserIqiyi.metadata(m,page))
        }
        data.put("playlist",playlist).put("dispatch_status","unavailable")
        assertNull(WebBrowserIqiyi.metadata(m,page))
    }
}
