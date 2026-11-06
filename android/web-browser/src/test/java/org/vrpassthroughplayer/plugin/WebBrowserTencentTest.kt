package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class WebBrowserTencentTest {
    @Test fun betaIsAvailableByDefaultOnlyOnRecognizedPublicPlayerPages() {
        assertTrue(WebBrowserTencent.enabled("https://v.qq.com/x/page/q326831cny0.html"))
        assertTrue(WebBrowserTencent.enabled("https://v.qq.com/x/cover/mzc00200example.html"))
        assertFalse(WebBrowserTencent.enabled("https://v.qq.com/"))
        assertFalse(WebBrowserTencent.enabled("https://v.qq.com.evil/x/page/q326831cny0.html"))
    }
    private val page = "https://v.qq.com/x/page/q326831cny0.html"
    private val source = "https://related-host.test/current/opaque.mp4?signature=synthetic"
    private fun request(url: String,kind: String) = JSONObject().put("url",url).put("kind",kind).put("headers",JSONObject())
    private fun item() = JSONObject().put("frame",page).put("source",source).put("width",1280).put("height",720).put("duration",10)
        .put("blob",false).put("network",JSONArray().put(request(source,"file")))
        .put("tencent",JSONObject().put("id","q326831cny0").put("page",page).put("clear",true).put("full",true)
            .put("width",1280).put("height",720).put("duration",10).put("filename","opaque.mp4").put("revision","ab123")
            .put("playlist","").put("urls",JSONArray()))
    @Test fun exactFileAndItsPublicIdentitySurvivePauseButNotSourceOrPageReplacement() {
        val m = item();assertNotNull(WebBrowserTencent.metadata(m,page))
        assertNotNull(WebBrowserTencent.metadata(JSONObject(m.toString()).put("playing",false),page))
        for (change in listOf<(JSONObject)->Unit>(
            {it.put("protected",true)}, {it.put("source",source+"-other")}, {it.put("width",1920)},
            {it.put("duration",60)}, {it.put("blob",true)}, {it.getJSONObject("tencent").put("full",false)},
            {it.getJSONObject("tencent").put("clear",false)}, {it.getJSONObject("tencent").put("id","x1111111111")})) {
            val changed = JSONObject(m.toString());change(changed);assertNull(WebBrowserTencent.metadata(changed,page))
        }
        assertNull(WebBrowserTencent.metadata(m,"https://v.qq.com/x/page/x1111111111.html"))
        assertFalse(WebBrowserTencent.document("https://v.qq.com.evil/x/page/q326831cny0.html"))
    }
    @Test fun coverRootStillRequiresTheExactCanonicalSelectedEpisode() {
        val root = "https://v.qq.com/x/cover/mzc00200example.html"
        val selected = "https://v.qq.com/x/cover/mzc00200example/q326831cny0.html"
        val m = item().put("frame",root)
        m.getJSONObject("tencent").put("page",selected)
        assertNotNull(WebBrowserTencent.metadata(m,root))
        assertNull(WebBrowserTencent.metadata(m,root.replace("example","another")))
    }
    @Test fun selectedMainCannotBecomeAnotherPlayingPreviewAfterPause() {
        val main=item().put("tencent_enabled",true).put("tencent_ready",true).put("capture_identity","selected-main")
        val preview=JSONObject().put("width",3840).put("height",2160).put("playing",true).put("fullscreen",true)
        assertSame(main,WebBrowserMediaPolicy.extractionCandidate(listOf(preview,main)))
        assertSame(main,WebBrowserMediaPolicy.selectedCandidate(listOf(preview,main),"selected-main"))
        assertNull(WebBrowserMediaPolicy.selectedCandidate(listOf(preview,main),"another"))
        main.put("playing",false)
        assertSame(main,WebBrowserMediaPolicy.selectedCandidate(listOf(preview,main),"selected-main"))
        main.put("source",source+"-replaced")
        assertNull(WebBrowserMediaPolicy.selectedCandidate(listOf(preview,main),"selected-main"))
    }
    @Test fun proxyDiagnosticsKeepOnlyBoundedStructureAndSafeNumericSamples() {
        val input=JSONArray().put(JSONObject().put("path","response.data.url").put("kind","string").put("value","https://private.test/signed").put("chars",99))
            .put(JSONObject().put("path","response.data.uid").put("kind","number").put("sample",123456789))
            .put(JSONObject().put("path","response.data.width").put("kind","number").put("sample",1280))
            .put(JSONObject().put("path","https://private.test/secret").put("kind","string"))
        val safe=WebBrowserTencent.diagnosticShape(input).toString()
        assertFalse(safe.contains("private.test"));assertFalse(safe.contains("123456789"));assertTrue(safe.contains("1280"))
        assertTrue(WebBrowserTencent.diagnosticShape(JSONArray()).length()==0)
    }
    @Test fun inlineHlsRequiresItsWholeTimelineAndActualDeclaredSegment() {
        val base = "https://new-related-host.test/hls/current.m3u8"
        val m = item().put("blob",true).put("source","")
            .put("network",JSONArray().put(request("https://new-related-host.test/hls/clip.ts","segment")))
        val data = m.getJSONObject("tencent").put("playlist","#EXTM3U\n#EXTINF:10,\nclip.ts\n#EXT-X-ENDLIST\n")
            .put("manifest_url",base).put("urls",JSONArray().put(base))
        assertNotNull(WebBrowserTencent.metadata(m,page))
        assertEquals(setOf("https://new-related-host.test/hls/clip.ts"),WebBrowserTencent.references(data))
        for (change in listOf<(JSONObject)->Unit>(
            {it.getJSONArray("network").getJSONObject(0).put("url","https://other.test/hls/clip.ts")},
            {it.getJSONObject("tencent").put("playlist",data.getString("playlist").replace("EXTINF:10","EXTINF:5"))},
            {it.getJSONObject("tencent").put("playlist",data.getString("playlist").replace("#EXT-X-ENDLIST",""))},
            {it.getJSONObject("tencent").put("playlist","#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"key\"\n"+data.getString("playlist"))},
            {it.getJSONObject("tencent").put("manifest_url","https://unknown.test/other.m3u8")})) {
            val changed = JSONObject(m.toString());change(changed);assertNull(WebBrowserTencent.metadata(changed,page))
        }
    }
    @Test fun additionalBrowserAdDurationCannotPassTheInlineHlsReadinessCheck() {
        val base="https://new-related-host.test/hls/current.m3u8"
        val m=item().put("blob",true).put("source","").put("duration",1971.668)
            .put("network",JSONArray().put(request("https://new-related-host.test/hls/clip.ts","segment")))
        m.getJSONObject("tencent").put("duration",1971.668)
            .put("playlist","#EXTM3U\n#EXTINF:1971.668,\nclip.ts\n#EXT-X-ENDLIST\n")
            .put("manifest_url",base).put("urls",JSONArray().put(base))
        assertNotNull(WebBrowserTencent.metadata(m,page))
        assertNotNull(WebBrowserTencent.metadata(JSONObject(m.toString()).put("duration",1972.158),page))
        assertNull(WebBrowserTencent.metadata(JSONObject(m.toString()).put("duration",1986.814),page))
        assertNull(WebBrowserTencent.metadata(JSONObject(m.toString()).put("duration",1972.178),page))
    }
}
