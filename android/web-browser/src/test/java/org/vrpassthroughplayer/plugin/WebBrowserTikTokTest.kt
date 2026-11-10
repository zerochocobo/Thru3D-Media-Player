package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class WebBrowserTikTokTest {
    private val page = "https://www.tiktok.com/@test/video/6742501081818877190"
    private val source = "https://related-file.test/current?exact=selector"
    private fun media() = JSONObject().put("frame", page).put("source", "").put("blob", true)
        .put("tiktok_source", "blob:https://www.tiktok.com/owned").put("width", 540).put("height", 960)
        .put("duration", 27.533333).put("capture_identity", "selected").put("tiktok_enabled", true).put("tiktok_ready", true)
        .put("tiktok", JSONObject().put("id", "6742501081818877190").put("page", page).put("source", source)
            .put("revision", "ab12").put("width", 540).put("height", 960).put("duration", 27.533333).put("expected_duration", 27))
        .put("network", JSONArray().put(JSONObject().put("kind", "file").put("url", source).put("headers", JSONObject())))

    @Test fun onlyTheExplicitCurrentFileAndSelectionAreAccepted() {
        val item = media().put("playing", false)
        assertNotNull(WebBrowserTikTok.metadata(item, page))
        assertSame(item, WebBrowserMediaPolicy.selectedCandidate(listOf(item), "selected"))
        assertNull(WebBrowserMediaPolicy.selectedCandidate(listOf(item, media()), "selected"))
        assertNull(WebBrowserMediaPolicy.selectedCandidate(listOf(item), "other"))
        assertNull(WebBrowserMediaPolicy.selectedCandidate(listOf(item.put("tiktok_ready", false)), "selected"))
    }
    @Test fun wrongOwnerSourceProtectionAndDurationFailClosed() {
        for (change in listOf<(JSONObject) -> Unit>(
            { it.put("protected", true) }, { it.put("tiktok_source", "blob:https://other.test/file") },
            { it.put("network", JSONArray()) }, { it.put("frame", page + "?other") },
            { it.put("duration", 28.1) }, { it.put("width", 320) },
            { it.getJSONObject("tiktok").put("id", "6742501081818877191") },
            { it.getJSONObject("tiktok").put("expected_duration", 27.5) },
            { it.getJSONObject("tiktok").put("source", source + "&different=1") }
        )) { val item = media(); change(item); assertNull(WebBrowserTikTok.metadata(item, page)) }
    }
    @Test fun onlyMainSiteDetailPagesHaveAPlayableIdentity() {
        assertEquals("6742501081818877190", WebBrowserTikTok.page(page + "?from=page"))
        assertTrue(WebBrowserTikTok.document("https://www.tiktok.com/foryou"))
        for (bad in listOf("http://www.tiktok.com/@test/video/6742501081818877190", page + "#different",
            page.replace("www.tiktok.com", "www.tiktok.com.evil"), page.replace("/video/", "/photo/"),
            "https://www.tiktok.com/foryou", page.replace("/video/", "/video%2F"))) assertNull(WebBrowserTikTok.page(bad))
    }
    @Test fun staticFeedRetainsActualDocumentAndRequiresCurrentRenderedIdentity() {
        fun feedMedia() = media().put("frame", "https://www.tiktok.com/").also {
            it.getJSONObject("tiktok").put("binding", "rendered_card").put("active_id", "6742501081818877190").put("document", "https://www.tiktok.com/")
        }
        assertNotNull(WebBrowserTikTok.metadata(feedMedia(), "https://www.tiktok.com/"))
        for (change in listOf<(JSONObject) -> Unit>(
            { it.getJSONObject("tiktok").remove("binding") },
            { it.getJSONObject("tiktok").put("document", "https://www.tiktok.com/foryou") },
            { it.getJSONObject("tiktok").put("active_id", "6742501081818877191") },
            { it.getJSONObject("tiktok").put("page", "https://other.test/@test/video/6742501081818877190") },
            { it.put("frame", "https://www.tiktok.com/search") }
        )) { val item=feedMedia();change(item);assertNull(WebBrowserTikTok.metadata(item, "https://www.tiktok.com/")) }
        assertNull(WebBrowserTikTok.metadata(feedMedia().put("frame", "https://www.tiktok.com/search"), "https://www.tiktok.com/search"))
    }
    @Test fun endedReplayStartsAtZeroWhileKeepingTheRealBrowserPosition() {
        val item=media().put("time",27.533333).put("tiktok_ended",true)
        item.getJSONObject("tiktok").put("start_seconds",0)
        assertNotNull(WebBrowserTikTok.metadata(item,page))
        assertNull(WebBrowserTikTok.metadata(item.put("tiktok_ended",false),page))
        item.getJSONObject("tiktok").put("start_seconds",27.533333)
        assertNotNull(WebBrowserTikTok.metadata(item,page))
    }
    @Test fun explorePreviewRequiresTheSameRenderedCardAndOriginalDocument() {
        for(document in listOf("https://www.tiktok.com/explore","https://www.tiktok.com/explore/")) {
            val item=media().put("frame",document)
            val data=item.getJSONObject("tiktok").put("binding","rendered_card")
                .put("active_id","6742501081818877190").put("document",document)
            assertTrue(WebBrowserTikTok.enabled(document));assertNotNull(WebBrowserTikTok.metadata(item,document))
            data.put("document","https://www.tiktok.com/")
            assertNull(WebBrowserTikTok.metadata(item,document));data.put("document",document)
            data.put("active_id","6742501081818877191")
            assertNull(WebBrowserTikTok.metadata(item,document))
        }
        assertFalse(WebBrowserTikTok.enabled("https://www.tiktok.com/explore/other"))
        assertFalse(WebBrowserTikTok.enabled("https://www.tiktok.com/explore#other"))
    }
    @Test fun integerSdkTimeUsesTheSameBoundedBudgetAsTheActualFileProbe() {
        fun check(sdk: Double,decoded: Double): JSONObject? {
            val item=media().put("duration",decoded)
            item.getJSONObject("tiktok").put("duration",decoded).put("expected_duration",sdk)
            return WebBrowserTikTok.metadata(item,page)
        }
        assertNotNull(check(14.0,15.136553));assertNotNull(check(6.0,5.783))
        assertNotNull(check(27.0,25.0));assertNotNull(check(27.0,29.0))
        assertNull(check(27.0,24.999));assertNull(check(27.0,29.001))
        assertNotNull(check(600.0,606.0));assertNull(check(600.0,606.001))
        assertNull(check(5.5,5.783))
    }
}
