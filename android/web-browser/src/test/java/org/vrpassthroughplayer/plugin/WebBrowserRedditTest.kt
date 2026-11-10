package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class WebBrowserRedditTest {
    private val page="https://www.reddit.com/r/aww/comments/1u8wxnn/title/"
    private val source="https://related.test:8443/opaque.mp4?token=synthetic"
    private fun media(frame: String=page)=JSONObject().put("frame",frame).put("source",source).put("reddit_source",source)
        .put("width",480).put("height",854).put("duration",10.942).put("capture_identity","selected")
        .put("reddit_enabled",true).put("reddit_ready",true)
        .put("reddit",JSONObject().put("id","1u8wxnn").put("active_id","1u8wxnn").put("page",page).put("document",frame)
            .put("binding","rendered_post").put("source",source).put("revision","a1")
            .put("width",480).put("height",854).put("duration",10.942).put("expected_duration",10))
        .put("network",JSONArray().put(JSONObject().put("kind","file").put("url",source)))

    @Test fun selectedPostCanRemainPausedInDetailOrFeed() {
        for(frame in listOf(page,"https://www.reddit.com/","https://www.reddit.com/r/aww/")){
            val item=media(frame).put("playing",false)
            assertNotNull(WebBrowserReddit.metadata(item,frame))
            assertSame(item,WebBrowserMediaPolicy.selectedCandidate(listOf(item),"selected"))
            assertNull(WebBrowserMediaPolicy.selectedCandidate(listOf(item,media(frame)),"selected"))
        }
    }
    @Test fun anotherPostDocumentRequestOrDecodedRepresentationCannotBeBorrowed() {
        for(change in listOf<(JSONObject)->Unit>(
            {it.put("protected",true)},{it.put("blob",true)},{it.put("frame",page+"?changed=1")},
            {it.put("source",source+"&changed=1")},{it.put("reddit_source",source+"&changed=1")},
            {it.put("network",JSONArray())},{it.put("width",720)},{it.put("duration",20)},
            {it.getJSONObject("reddit").put("id","other1")},{it.getJSONObject("reddit").put("active_id","other1")},
            {it.getJSONObject("reddit").put("binding","inferred")},{it.getJSONObject("reddit").put("document",page+"?other=1")},
            {it.getJSONObject("reddit").put("expected_duration",20)},{it.getJSONObject("reddit").put("revision","invalid")}
        )){val item=media();change(item);assertNull(WebBrowserReddit.metadata(item,page))}
        val other=page.replace("1u8wxnn","1u8wxno")
        assertNull(WebBrowserReddit.metadata(media(other),other))
        assertNull(WebBrowserMediaPolicy.selectedCandidate(listOf(media().put("reddit_ready",false)),"selected"))
    }
    @Test fun supportedDocumentsDoNotIncludeLoginOrLookalikeHosts() {
        assertEquals("1u8wxnn",WebBrowserReddit.page(page))
        for(bad in listOf(page.replace("https:","http:"),page.replace("reddit.com","reddit.com.evil"),
            page.replace("https://","https://user@"),page+"#other","https://www.reddit.com/login/"))assertFalse(WebBrowserReddit.enabled(bad))
        assertTrue(WebBrowserReddit.enabled("https://www.reddit.com/r/aww/new/"))
    }
    @Test fun gifDeclarationHasItsOwnExplicitModeAndDecodedDurationWitness() {
        val item=media();val data=item.getJSONObject("reddit")
        data.put("binding","rendered_gif").put("declared_gif",true).put("expected_duration",10.942)
        assertNotNull(WebBrowserReddit.metadata(item,page))
        data.put("declared_gif","true");assertNull(WebBrowserReddit.metadata(item,page))
        data.put("declared_gif",true).put("expected_duration",10);assertNull(WebBrowserReddit.metadata(item,page))
        data.put("expected_duration",10.942).put("binding","rendered_post");assertNull(WebBrowserReddit.metadata(item,page))
    }
}
