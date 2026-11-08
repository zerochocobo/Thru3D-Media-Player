package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class WebBrowserTedTest {
    private val page="https://www.ted.com/talks/current_talk"
    private val root="https://actual-related.test/root.m3u8?exact=selector"
    private fun media()=JSONObject().put("frame",page).put("source","").put("blob",true)
        .put("ted_source","blob:https://www.ted.com/owned").put("width",1280).put("height",720).put("duration",679.973)
        .put("capture_identity","selected").put("ted_enabled",true).put("ted_ready",true)
        .put("ted",JSONObject().put("id","current_talk").put("talk_id","86532").put("player_id","416668")
            .put("page",page).put("root",root).put("revision","ab12").put("width",1280).put("height",720)
            .put("duration",679.973).put("expected_duration",679))
        .put("network",JSONArray().put(JSONObject().put("kind","hls").put("url",root).put("headers",JSONObject())))
    @Test fun originalMasterAndDistinctPlayerIdentitySurvivePausedSelection() {
        val item=media().put("playing",false)
        assertNotNull(WebBrowserTed.metadata(item,page))
        assertSame(item,WebBrowserMediaPolicy.selectedCandidate(listOf(item),"selected"))
        assertNull(WebBrowserMediaPolicy.selectedCandidate(listOf(item,media()),"selected"))
        assertNull(WebBrowserMediaPolicy.selectedCandidate(listOf(item.put("ted_ready",false)),"selected"))
    }
    @Test fun wrongMasterTalkDimensionsDurationAndProtectionCannotBeAccepted() {
        for(change in listOf<(JSONObject)->Unit>(
            {it.put("protected",true)},{it.put("ted_source","blob:https://other.test/media")},
            {it.put("blob",false)},{it.put("width",640)},{it.put("duration",676.0)},
            {it.put("network",JSONArray())},{it.getJSONObject("ted").put("id","next_talk")},
            {it.getJSONObject("ted").put("root",root+"&different=1")},
            {it.getJSONObject("ted").put("expected_duration",676)},
            {it.put("frame",page+"?different=1")}
        )){val item=media();change(item);assertNull(WebBrowserTed.metadata(item,page))}
    }
    @Test fun onlyOfficialIndividualTalkPagesHaveAnIdentity() {
        assertEquals("current_talk",WebBrowserTed.page(page+"?language=en"))
        for(bad in listOf(page+"#other",page.replace("www.ted.com","www.ted.com.evil"),page.replace("https:","http:"),
            "https://www.ted.com/talks",page.replace("current_talk","%63urrent_talk")))assertNull(WebBrowserTed.page(bad))
    }
}
