package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class WebBrowserRedBullTest {
    private val id="rrn:content:films:f9d7a128-fd11-4e0c-9049-77de0f9515bd"
    private val page="https://www.redbull.tv/en/page/$id/anytime"
    private val root="https://related.test:8443/current.m3u8?selection=exact"
    private fun media()=JSONObject().put("frame",page).put("source","").put("blob",true).put("redbull_source","blob:https://www.redbull.tv/current")
        .put("width",1920).put("height",1080).put("duration",3945.0661)
        .put("redbull",JSONObject().put("id",id).put("page",page).put("root",root).put("revision","a1").put("width",1920).put("height",1080).put("duration",3945.0661).put("expected_duration",3945))
        .put("network",JSONArray().put(JSONObject().put("url",root).put("kind","hls")))
    @Test fun fullPlayerMetadataRequiresTheSamePublicRrnDocumentSourceSizeAndOriginalRoot() {
        assertEquals(id,WebBrowserRedBull.page(page));assertNotNull(WebBrowserRedBull.metadata(media(),page))
        assertNull(WebBrowserRedBull.page(page.replace("redbull.tv","redbull.tv.evil")))
        for(change in listOf<(JSONObject)->Unit>(
            {it.put("protected",true)},{it.put("frame",page+"?changed=1")},{it.put("redbull_source","blob:https://other.test/current")},
            {it.put("width",960)},{it.put("duration",15.015)},
            {it.getJSONObject("redbull").put("id",id.replace("f9d7","f9d8"))},
            {it.getJSONObject("redbull").put("root",root+"&changed=1")},
            {it.getJSONObject("redbull").put("expected_duration",15)}
        )){val item=media();change(item);assertNull(WebBrowserRedBull.metadata(item,page))}
        assertFalse(WebBrowserRedBull.enabled(page))
    }
}
