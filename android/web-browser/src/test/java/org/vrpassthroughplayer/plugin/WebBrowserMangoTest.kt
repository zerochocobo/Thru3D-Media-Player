package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class WebBrowserMangoTest {
    private val page="https://w.mgtv.com/s/15588271.html"
    private val source="https://new-related-cdn.test/full.m3u8?signature=current"
    private fun item()=JSONObject().put("frame",page).put("blob",true).put("source","").put("width",704).put("height",396).put("duration",4026.56)
        .put("mango_enabled",true).put("mango_ready",true).put("capture_identity","chosen-main")
        .put("network",JSONArray().put(JSONObject().put("url",source).put("kind","hls").put("headers",JSONObject())))
        .put("mango",JSONObject().put("id","15588271").put("page",page).put("clear",true).put("revision","a1")
            .put("width",704).put("height",396).put("duration",4026.56).put("expected_duration",4026).put("manifests",JSONArray().put(source)))
    @Test fun publicAliasesPreserveVideoIdentity() {
        assertTrue(WebBrowserMango.enabled(page))
        assertFalse(WebBrowserMango.enabled("https://www.mgtv.com/"))
        assertEquals("15588271",WebBrowserMango.page(page))
        assertEquals("15588271",WebBrowserMango.page("https://www.mgtv.com/b/427837/15588271.html"))
        for(url in listOf("http://w.mgtv.com/s/15588271.html","https://w.mgtv.com.evil/s/15588271.html","https://secret@w.mgtv.com/s/15588271.html","https://w.mgtv.com/s/0.html"))assertNull(WebBrowserMango.page(url))
    }
    @Test fun matchedCurrentHlsSurvivesPauseWithItsOriginalMetadata() {
        val m=item();assertNotNull(WebBrowserMango.metadata(m,page))
        assertNotNull(WebBrowserMango.metadata(m.put("playing",false),page))
        assertSame(m,WebBrowserMediaPolicy.selectedCandidate(listOf(m),"chosen-main"))
    }
    @Test fun previewsProtectionAndMetadataReplacementAreRejected() {
        for(change in listOf<(JSONObject)->Unit>(
            {it.put("protected",true)}, {it.put("blob",false)}, {it.put("width",1280)}, {it.put("frame",page.replace("15588271","15588272"))},
            {it.getJSONObject("mango").put("id","15588272")}, {it.getJSONObject("mango").put("clear",false)},
            {it.getJSONObject("mango").put("revision","not-a-revision")},
            {it.put("duration",300);it.getJSONObject("mango").put("duration",300)},
            {it.getJSONObject("mango").put("duration",4020)}, {it.getJSONObject("mango").put("expected_duration",JSONObject.NULL)})) {
            val m=item();change(m);assertNull(WebBrowserMango.metadata(m,page))
        }
    }
    @Test fun declaredButUnobservedOrUnrelatedManifestsAreRejected() {
        val empty=item().put("network",JSONArray());assertNull(WebBrowserMango.metadata(empty,page))
        val other=item();other.getJSONArray("network").getJSONObject(0).put("url","https://another.test/other.m3u8");assertNull(WebBrowserMango.metadata(other,page))
        for(value in listOf("http://cdn.test/full.m3u8","https://secret@cdn.test/full.m3u8")) {
            val m=item();m.getJSONObject("mango").put("manifests",JSONArray().put(value));assertNull(WebBrowserMango.metadata(m,page))
        }
        val duplicate=item();duplicate.getJSONObject("mango").getJSONArray("manifests").put(source);assertNull(WebBrowserMango.metadata(duplicate,page))
    }
    @Test fun aDeclaredCurrentProgrammePreviewKeepsItsOwnDurationRatherThanTheFullProgramme() {
        fun preview()=item().put("duration",300.08).apply {
            getJSONObject("mango").put("duration",300.08).put("expected_duration",300.0)
                .put("program_duration",4026.0).put("preview",true).put("preview_duration",300.0)
        }
        assertNotNull(WebBrowserMango.metadata(preview(),page))
        for(change in listOf<(JSONObject)->Unit>(
            {it.put("preview",false)}, {it.remove("program_duration")}, {it.put("program_duration",300.0)},
            {it.put("preview_duration",400.0)}, {it.put("expected_duration",4026.0)})) {
            val m=preview();change(m.getJSONObject("mango"));assertNull(WebBrowserMango.metadata(m,page))
        }
        val full=item();full.getJSONObject("mango").put("program_duration",4026.0).put("preview",false)
        assertNotNull(WebBrowserMango.metadata(full,page))
    }
    @Test fun anObservedRedirectKeepsItsOwnRequestAndDeclaredOriginIdentity() {
        val m=item();m.getJSONArray("network").getJSONObject(0).put("url","https://another-related-cdn.test/full.m3u8").put("original_url",source)
        assertNotNull(WebBrowserMango.metadata(m,page))
    }
    @Test fun selectedMainNeverFallsBackToALargerPlayingSidebar() {
        val m=item();val preview=JSONObject().put("width",3840).put("height",2160).put("playing",true).put("fullscreen",true)
        assertSame(m,WebBrowserMediaPolicy.selectedCandidate(listOf(preview,m),"chosen-main"))
        assertSame(m,WebBrowserMediaPolicy.extractionCandidate(listOf(preview,m)))
        assertNull(WebBrowserMediaPolicy.selectedCandidate(listOf(preview,m),"another"))
        m.getJSONObject("mango").put("clear",false);assertNull(WebBrowserMediaPolicy.selectedCandidate(listOf(preview,m),"chosen-main"))
    }
}
