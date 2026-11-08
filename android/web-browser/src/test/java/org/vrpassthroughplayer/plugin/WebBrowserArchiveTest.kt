package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class WebBrowserArchiveTest {
    private val page="https://archive.org/details/PublicFilm"
    private val source="https://archive.org/download/PublicFilm/current.mp4"
    private val file="https://related.test:8443/observed-file?token=synthetic"
    private fun media()=JSONObject().put("frame",page).put("source",source).put("archive_source",source)
        .put("width",426).put("height",240).put("duration",596.416666)
        .put("archive",JSONObject().put("id","PublicFilm").put("page",page).put("source",source).put("file",file)
            .put("revision","a1").put("width",426).put("height",240).put("duration",596.416666))
        .put("network",JSONArray().put(JSONObject().put("kind","file").put("url",file).put("original_url",source)))
    @Test fun exactDownloadRedirectUsesItsOwnObservedRequest() {
        assertNotNull(WebBrowserArchive.metadata(media(),page))
        val item=media();item.put("source",file).put("archive_source",file);item.getJSONObject("archive").put("source",file)
        assertNull(WebBrowserArchive.metadata(item,page))
    }
    @Test fun anotherDocumentItemFileOrProtectionCannotBind() {
        for(change in listOf<(JSONObject)->Unit>(
            {it.put("protected",true)},{it.put("blob",true)},{it.put("frame",page+"?changed=1")},
            {it.put("archive_source",source+"?different=1")},{it.put("width",640)},{it.put("duration",20)},
            {it.getJSONObject("archive").put("id","OtherItem")},{it.getJSONObject("archive").put("file",file+"&other=1")},
            {it.getJSONArray("network").getJSONObject(0).put("original_url",source+"?different=1")},
            {it.put("network",JSONArray())}
        )) {val item=media();change(item);assertNull(WebBrowserArchive.metadata(item,page))}
    }
    @Test fun detailOnlyIdentityPreservesTheExistingManualEmbedPath() {
        assertEquals("PublicFilm",WebBrowserArchive.page(page))
        for(bad in listOf(page.replace("https:","http:"),page.replace("archive.org","archive.org.evil"),
            page.replace("https://","https://user@"),page+"#other",page+"/current.mp4"))assertNull(WebBrowserArchive.page(bad))
        assertTrue(WebBrowserArchive.enabled(page))
    }
}
