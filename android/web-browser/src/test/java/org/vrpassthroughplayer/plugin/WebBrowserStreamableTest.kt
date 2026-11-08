package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class WebBrowserStreamableTest {
    private val page="https://streamable.com/abc123"
    private val source="https://related.test:8443/files/abc123.mp4?token=synthetic"
    private fun media()=JSONObject().put("frame",page).put("source",source).put("streamable_source",source)
        .put("width",1280).put("height",720).put("duration",14.42).put("capture_identity","selected")
        .put("streamable_enabled",true).put("streamable_ready",true)
        .put("streamable",JSONObject().put("id","abc123").put("page",page).put("source",source).put("revision","a1")
            .put("width",1280).put("height",720).put("duration",14.42).put("expected_duration",14.4144))
        .put("network",JSONArray().put(JSONObject().put("kind","file").put("url",source)))

    @Test fun exactDeclaredFileRemainsSelectableWhenPaused() {
        val item=media().put("playing",false)
        assertNotNull(WebBrowserStreamable.metadata(item,page))
        assertSame(item,WebBrowserMediaPolicy.selectedCandidate(listOf(item),"selected"))
        assertNull(WebBrowserMediaPolicy.selectedCandidate(listOf(item,media()),"selected"))
        assertNull(WebBrowserMediaPolicy.selectedCandidate(listOf(item),"other"))
    }

    @Test fun wrongItemRequestOrPlaybackIdentityIsRejected() {
        for(change in listOf<(JSONObject)->Unit>(
            {it.put("protected",true)},{it.put("blob",true)},{it.put("frame",page+"?changed=1")},
            {it.put("source",source+"&changed=1")},{it.put("streamable_source",source+"&changed=1")},
            {it.put("network",JSONArray())},{it.put("width",640)},{it.put("duration",20)},
            {it.getJSONObject("streamable").put("id","other1")},
            {it.getJSONObject("streamable").put("expected_duration",20)},
            {it.getJSONObject("streamable").put("revision","invalid")}
        )) {val item=media();change(item);assertNull(WebBrowserStreamable.metadata(item,page))}
        assertNull(WebBrowserMediaPolicy.selectedCandidate(listOf(media().put("streamable_ready",false)),"selected"))
    }

    @Test fun onlyOfficialDetailDocumentsMatch() {
        assertEquals("abc123",WebBrowserStreamable.page(page))
        for(bad in listOf(page.replace("https:","http:"),page.replace("streamable.com","streamable.com.evil"),
            page.replace("https://","https://user@"),page+"#other","https://streamable.com/e/abc123"))
            assertNull(WebBrowserStreamable.page(bad))
        assertTrue(WebBrowserStreamable.enabled(page))
    }
}
