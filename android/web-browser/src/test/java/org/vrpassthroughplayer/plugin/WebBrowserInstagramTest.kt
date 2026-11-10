package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class WebBrowserInstagramTest {
    private val page="https://www.instagram.com/reel/Chunk8-jurw/"
    private val file="https://related.test/current.mp4?selector=exact%2Fvalue"
    private val payload=file+"&bytestart=901&byteend=999"
    private val xml="""<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" mediaPresentationDuration="PT4.967S"><Period><AdaptationSet><Representation id="video1" mimeType="video/mp4" codecs="avc1.64001F" width="720" height="1280" bandwidth="1000000"><BaseURL>https://related.test/current.mp4?selector=exact%2Fvalue</BaseURL><SegmentBase indexRange="845-900"><Initialization range="0-844"/></SegmentBase></Representation></AdaptationSet></Period></MPD>"""
    private fun media()=JSONObject().put("frame",page).put("source","").put("blob",true).put("instagram_source","blob:https://www.instagram.com/owned")
        .put("width",720).put("height",1280).put("duration",4.966666).put("instagram_ready",true).put("instagram_enabled",true).put("capture_identity","selected")
        .put("instagram",JSONObject().put("id","Chunk8-jurw").put("page",page).put("media_id","12345678901234567").put("revision","a1")
            .put("manifest",xml).put("has_audio",false).put("audio",JSONObject.NULL).put("width",720).put("height",1280).put("duration",4.966666).put("expected_duration",4.967)
            .put("video",JSONObject().put("id","video1").put("url",file).put("bandwidth",1000000).put("requests",JSONArray().put(payload))))
        .put("network",JSONArray().put(JSONObject().put("url",payload).put("kind","file").put("headers",JSONObject().put("Authorization","this-range-only"))))
    @Test fun explicitSilentPostRequiresARealMediaPayloadAndTheOriginalDeclaredFile() {
        val item=media()
        assertNotNull(WebBrowserInstagram.metadata(item,page))
        val plural=media().put("frame",page.replace("/reel/","/reels/"))
        plural.getJSONObject("instagram").put("page",page.replace("/reel/","/reels/"))
        assertNotNull(WebBrowserInstagram.metadata(plural,page.replace("/reel/","/reels/")))
        val graph=WebBrowserInstagram.manifest(xml)!!
        assertEquals(file,graph.tracks.single().url);assertEquals(4.967,graph.duration,.0001)
        assertTrue(WebBrowserInstagram.payloadRequest(graph.tracks.single(),payload))
        assertFalse(WebBrowserInstagram.payloadRequest(graph.tracks.single(),file+"&bytestart=845&byteend=900"))
        assertEquals("this-range-only",item.getJSONArray("network").getJSONObject(0).getJSONObject("headers").getString("Authorization"))
    }
    @Test fun selectedFileAndAudioIntentCannotBeForgedFromAHeaderOrAnotherPost() {
        for(change in listOf<(JSONObject)->Unit>(
            {it.put("protected",true)},{it.put("instagram_source","blob:https://other.test/media")},{it.put("width",472)},
            {it.getJSONObject("instagram").put("id","different_post")},{it.getJSONObject("instagram").put("has_audio",true)},
            {it.getJSONObject("instagram").getJSONObject("video").put("url",file+"&changed=1")},
            {it.getJSONArray("network").getJSONObject(0).put("url",file+"&bytestart=845&byteend=900")}
        )){val item=media();change(item);assertNull(WebBrowserInstagram.metadata(item,page))}
    }
    @Test fun endedReplayStartsNativeAtZeroWithoutMovingTheOriginalBrowserPosition() {
        val item=media().put("time",4.966666).put("instagram_ended",true)
        item.getJSONObject("instagram").put("start_seconds",0)
        assertNotNull(WebBrowserInstagram.metadata(item,page));assertEquals(4.966666,item.getDouble("time"),.0001)
        assertNull(WebBrowserInstagram.metadata(item.put("instagram_ended",false),page))
        item.getJSONObject("instagram").put("start_seconds",4.966666)
        assertNotNull(WebBrowserInstagram.metadata(item,page))
    }
    @Test fun protectedDynamicOrReferencedXmlCannotBeParsedAsACompleteClearPost() {
        for(bad in listOf("<!DOCTYPE MPD>"+xml,xml.replace("static","dynamic"),xml.replace("<Period>","<Period><ContentProtection/>"),
            xml.replace("<Period>","<Period><SegmentTemplate/>"),xml.replace("PT4.967S","PT0S")))assertNull(WebBrowserInstagram.manifest(bad))
        assertNull(WebBrowserInstagram.page(page+"#other"));assertNull(WebBrowserInstagram.page(page.replace("instagram.com","instagram.com.evil")))
    }
    @Test fun returnMayRebindOnlyTheSameCompleteContentInTheOriginalDocument() {
        val before=media();val identity=WebBrowserInstagram.identity(WebBrowserInstagram.metadata(before,page)!!)
        val after=media().put("instagram_source","blob:https://www.instagram.com/recreated").put("id","2").put("network_epoch",2)
        assertTrue(WebBrowserInstagram.matchesIdentity(after,identity,page))
        for(change in listOf<(JSONObject)->Unit>(
            {it.put("protected",true)},{it.put("frame",page+"?other=1")},
            {it.getJSONObject("instagram").put("media_id","12345678901234568")},
            {it.getJSONObject("instagram").put("revision","a2")},
            {it.getJSONObject("instagram").put("manifest",xml.replace("1000000","999999"))},
            {it.getJSONObject("instagram").put("has_audio",true)}
        )){val changed=media();change(changed);assertFalse(WebBrowserInstagram.matchesIdentity(changed,identity,page))}
        assertFalse(identity.has("headers"));assertFalse(identity.has("instagram_source"))
    }
    @Test fun reelsKeepTheRealDocumentAndRequireTheCurrentRenderedPost() {
        val root="https://www.instagram.com/reels/"
        fun feedMedia()=media().put("frame",root).also{it.getJSONObject("instagram").put("document",root).put("binding","rendered_card").put("active_id","Chunk8-jurw")}
        val item=feedMedia();assertNotNull(WebBrowserInstagram.metadata(item,root))
        assertTrue(WebBrowserInstagram.matchesIdentity(item,WebBrowserInstagram.identity(WebBrowserInstagram.metadata(item,root)!!),root))
        for(change in listOf<(JSONObject)->Unit>(
            {it.getJSONObject("instagram").remove("document")},{it.getJSONObject("instagram").put("active_id","next_post")},
            {it.getJSONObject("instagram").put("binding","guessed")},{it.getJSONObject("instagram").put("page",page.replace("instagram.com","other.test"))},
            {it.put("frame",root+"?different=1")},{it.put("protected",true)}
        )){val changed=feedMedia();change(changed);assertNull(WebBrowserInstagram.metadata(changed,root))}
        assertNull(WebBrowserInstagram.metadata(feedMedia().put("frame","https://www.instagram.com/explore/"),"https://www.instagram.com/explore/"))
    }
    @Test fun samePostMpdTailIsBoundedToAQuarterSecond() {
        val item=media().put("duration",5.136);item.getJSONObject("instagram").put("duration",5.136)
        assertNotNull(WebBrowserInstagram.metadata(item,page))
        item.put("duration",5.218).getJSONObject("instagram").put("duration",5.218)
        assertNull(WebBrowserInstagram.metadata(item,page))
    }
}
