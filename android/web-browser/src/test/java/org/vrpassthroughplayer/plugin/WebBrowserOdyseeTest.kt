package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class WebBrowserOdyseeTest {
    private val page="https://odysee.com/@PublicChannel:2/PublicClip:1"
    private val claim="1"+"a".repeat(39)
    private val source="https://related.test:8443/v6/streams/$claim/abcdef.mp4?token=synthetic"
    private val declared="https://other-related.test/api/v3/streams/free/PublicClip/$claim/abcdef.mp4"
    private fun media()=JSONObject().put("frame",page).put("source",source).put("odysee_source",source)
        .put("width",1280).put("height",720).put("duration",346.72)
        .put("odysee",JSONObject().put("id","@PublicChannel:2/PublicClip:1").put("page",page).put("source",source)
            .put("declared_source",declared).put("claim_id",claim).put("file_id","abcdef.mp4").put("revision","a1")
            .put("width",1280).put("height",720).put("duration",346.72).put("expected_duration",346).put("whole_seconds",true))
        .put("network",JSONArray().put(JSONObject().put("kind","file").put("url",source)))
    private val root="https://associated.test:8443/v6/streams/$claim/opaque/master.m3u8?actual=EXACT"
    private fun hls(): JSONObject=media().also { item ->
        val blob="blob:https://odysee.com/current"
        item.put("blob",true).put("source","").put("odysee_source",blob)
        item.getJSONObject("odysee").put("binding","rendered_hls").put("source",blob).put("root",root)
            .put("declared_source",root).put("claim_uri","lbry://@PublicChannel#2/PublicClip#1").remove("file_id")
        item.put("network",JSONArray().put(JSONObject().put("kind","hls").put("url",root)))
    }
    @Test fun renderedHlsBindsTheCurrentBlobFullClaimAndExactRootObservation() {
        assertNotNull(WebBrowserOdysee.metadata(hls(),page))
        for (change in listOf<(JSONObject)->Unit>(
            {it.put("blob",false)},{it.put("source",source)},{it.put("odysee_source","blob:https://other.test/current")},
            {it.getJSONObject("odysee").put("root",root+"&other=1")},
            {it.getJSONObject("odysee").put("claim_id","1"+"b".repeat(39))},
            {it.getJSONObject("odysee").put("claim_uri","lbry://OtherClip#1")},
            {it.getJSONObject("odysee").put("claim_uri","lbry://PublicClip#2")},
            {it.getJSONArray("network").getJSONObject(0).put("kind","file")},
            {it.getJSONArray("network").getJSONObject(0).put("url",root+"&different=1")},
            {it.put("protected",true)}
        )) { val item=hls();change(item);assertNull(WebBrowserOdysee.metadata(item,page)) }
    }
    @Test fun exactCurrentClaimAndFileRemainBoundAcrossDeclaredAndActualRoutes() {
        assertNotNull(WebBrowserOdysee.metadata(media(),page))
        val item=media();item.put("source",declared).put("odysee_source",declared)
        item.getJSONObject("odysee").put("source",declared);item.getJSONArray("network").getJSONObject(0).put("url",declared)
        assertNotNull(WebBrowserOdysee.metadata(item,page))
    }
    @Test fun renderedFileNeedsItsPublicUriExactFileAndOwnedRequestWithoutAnSsrDeclaration() {
        fun rendered()=media().also { item ->
            item.getJSONObject("odysee").put("binding","rendered_file").put("declared_source",source)
                .put("claim_uri","lbry://@PublicChannel#2/PublicClip#1")
        }
        assertNotNull(WebBrowserOdysee.metadata(rendered(),page))
        for(change in listOf<(JSONObject)->Unit>({it.put("blob",true)},
            {it.getJSONObject("odysee").put("root",root)},{it.getJSONObject("odysee").put("declared_source",declared)},
            {it.getJSONObject("odysee").put("claim_uri","lbry://NextClip#1")},
            {it.getJSONObject("odysee").put("file_id","abcdee.mp4")},
            {it.getJSONArray("network").getJSONObject(0).put("url",source+"&other=1")},
            {it.getJSONArray("network").getJSONObject(0).put("kind","hls")})) {
            val item=rendered();change(item);assertNull(WebBrowserOdysee.metadata(item,page))
        }
    }
    @Test fun anotherClaimFileDocumentOrUnobservedSelectorCannotBind() {
        for(change in listOf<(JSONObject)->Unit>(
            {it.put("protected",true)},{it.put("blob",true)},{it.put("frame",page+"?changed=1")},
            {it.put("source",source+"&changed=1")},{it.put("odysee_source",source+"&changed=1")},
            {it.getJSONObject("odysee").put("declared_source",declared.replace("abcdef","abcdee"))},
            {it.getJSONObject("odysee").put("declared_source",declared.replace("PublicClip","AnotherClip"))},
            {it.getJSONObject("odysee").put("declared_source",declared.replace("/free/","/paid/"))},
            {it.getJSONObject("odysee").put("claim_id","1"+"b".repeat(39))},
            {it.getJSONObject("odysee").put("expected_duration",345)},{it.put("network",JSONArray())}
        )){val item=media();change(item);assertNull(WebBrowserOdysee.metadata(item,page))}
    }
    @Test fun naturalDurationIsComparedAtTheDeclaredPrecisionAndOnlyOfficialPagesMatch() {
        val item=media();item.getJSONObject("odysee").put("expected_duration",346.72).put("whole_seconds",false)
        assertNotNull(WebBrowserOdysee.metadata(item,page))
        item.getJSONObject("odysee").put("expected_duration",348.72);assertNull(WebBrowserOdysee.metadata(item,page))
        for(bad in listOf(page.replace("https:","http:"),page.replace("odysee.com","odysee.com.evil"),page+"#other",page.replace("https://","https://user@")))assertNull(WebBrowserOdysee.page(bad))
        assertTrue(WebBrowserOdysee.enabled(page))
    }
}
