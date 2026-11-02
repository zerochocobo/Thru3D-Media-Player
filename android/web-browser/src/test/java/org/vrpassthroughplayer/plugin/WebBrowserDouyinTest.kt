package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test

class WebBrowserDouyinTest {
    private val id = "6961737553342991651"
    @Test fun unreleasedHandoffRequiresDebugAndExplicitTabOptIn() {
        val page = "https://www.douyin.com/video/$id"
        assertTrue(WebBrowserDouyin.enabled(page, true, true))
        for ((debug, optIn) in listOf(false to false, false to true, true to false))
            assertFalse(WebBrowserDouyin.enabled(page, debug, optIn))
        assertFalse(WebBrowserDouyin.enabled("https://www.douyin.com.evil/video/$id", true, true))
    }
    @Test fun identityAndModalMatchWithoutBroadeningLegacyCapture() {
        for (page in listOf("https://www.douyin.com/video/$id", "https://www.douyin.com/?modal_id=$id")) {
            assertEquals(id, WebBrowserDouyin.pageId(page))
            assertFalse(WebBrowserNetworkPolicy.available(page))
        }
        for (page in listOf("http://www.douyin.com/video/$id", "https://user@www.douyin.com/video/$id",
            "https://www.douyin.com.evil/video/$id", "https://www.douyin.com:443/video/$id", "https://live.douyin.com/$id",
            "https://www.douyin.com/video/$id?modal_id=7674225615168824549", "https://www.douyin.com/?modal_id=$id&modal_id=$id"))
            assertNull(page, WebBrowserDouyin.pageId(page))
    }
    @Test fun signedQueriesAndOriginCannotBeReplaced() {
        val url = "https://cdn.test/full.mp4?signature=synthetic&quality=720"
        assertTrue(WebBrowserDouyin.matches(url, "$url&temp=1&__vid=id"))
        assertTrue(WebBrowserDouyin.matches(url, "https://cdn.test/full.mp4?quality=720&signature=synthetic&__vid=id"))
        for (bad in listOf(url.replace("synthetic", "other"), url.replace("cdn.test", "other.test"), "$url&quality=360", "$url&another=1"))
            assertFalse(bad, WebBrowserDouyin.matches(url, bad))
        assertFalse(WebBrowserDouyin.matches("$url&temp=original", "$url&temp=other"))
        val declared = "$url&cquery=old&l=old"; val observed = "$url&cquery=new&l=new&__vid=$id"
        assertFalse(WebBrowserDouyin.matches(declared, observed))
        assertTrue(WebBrowserDouyin.matches(declared, observed, id))
        assertFalse(WebBrowserDouyin.matches(declared, observed.replace(id,"7674225615168824549"), id))
        assertFalse(WebBrowserDouyin.matches(declared, "$observed&__vid=$id", id))
        assertFalse(WebBrowserDouyin.matches(declared, observed.replace("synthetic","changed"), id))
    }
    @Test fun directSourceIdentityRequiresHttpsAndExactlyOneUnambiguousId() {
        val source = "https://cdn.test/full.mp4?__vid=$id"
        assertEquals(id, WebBrowserDouyin.sourceId(source))
        for (bad in listOf(source.replace("https:","http:"), "$source&__vid=$id", "$source#fragment", "https://user@cdn.test/full.mp4?__vid=$id"))
            assertNull(WebBrowserDouyin.sourceId(bad))
    }
    @Test fun cTypePrefixCanRotateOnlyForOneDeclaredObjectOnTheSameOrigin() {
        val suffix="/video/tos/cn/tos-cn-ve-15/object-fixture-1234567890/encoding-fixture-1234/"
        val declared="https://cdn.test/${"a".repeat(32)}/65000000$suffix?a=6383&mime_type=video_mp4&btag=old&dy_q=old&cquery=old&l=old"
        val observed="https://cdn.test/${"b".repeat(32)}/65000001$suffix?a=6383&mime_type=video_mp4&btag=new&dy_q=new&cquery=new&l=new&temp=1"
        assertFalse(WebBrowserDouyin.matches(declared,observed))
        assertTrue(WebBrowserDouyin.matches(declared,observed,id))
        for (bad in listOf(observed.replace("cdn.test","other.test"),observed.replace("object-fixture","other-fixture"),
            observed.replace("encoding-fixture","other-encoding"),observed.replace("tos-cn-ve-15","tos-cn-ve-16"),
            observed.replace("video_mp4","audio_mp4"),"$observed&unexpected=1","$observed&__vid=$id&__vid=$id",
            observed.replace("b".repeat(32),"not-a-signature"))) assertFalse(bad,WebBrowserDouyin.matches(declared,bad,id))
    }
}
