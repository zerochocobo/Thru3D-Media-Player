package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class WebBrowserWeiboTest {
    private val document = "https://weibo.com/newlogin"
    private val page = "https://weibo.com/7827771738/N4xlMvjhI"
    private val source = "https://any-cdn.test/current.mp4?token=synthetic"
    private fun media(id: String = "clicked") = JSONObject().put("frame",document).put("source",source)
        .put("width",1280).put("height",720).put("duration",120).put("capture_identity",id).put("weibo_enabled",true).put("weibo_ready",true)
        .put("weibo",JSONObject().put("id","N4xlMvjhI").put("page",page).put("source",source))
        .put("network",JSONArray().put(JSONObject().put("url",source).put("kind","file").put("headers",JSONObject())))
    @Test fun exactSelectedPlayerSurvivesPauseAndIgnoresBiggerPlayingNeighbors() {
        val clicked = media()
        val other = media("other").put("width",3840).put("height",2160).put("playing",true).put("fullscreen",true)
        assertNotNull(WebBrowserWeibo.metadata(clicked,document))
        assertSame(clicked,WebBrowserMediaPolicy.selectedCandidate(listOf(other,clicked),"clicked"))
        clicked.put("playing",false)
        assertSame(clicked,WebBrowserMediaPolicy.selectedCandidate(listOf(clicked,other),"clicked"))
        assertNull(WebBrowserMediaPolicy.selectedCandidate(listOf(other),"clicked"))
        assertNull(WebBrowserMediaPolicy.selectedCandidate(listOf(clicked,media()),"clicked"))
    }
    @Test fun rejectsWrongDocumentProtectedBlobUnobservedAndRecycledPlayers() {
        for (change in listOf<(JSONObject)->Unit>(
            {it.put("frame","https://weibo.com/other")},{it.put("protected",true)},{it.put("blob",true)},
            {it.put("source",source+"changed")},{it.put("network",JSONArray())},
            {it.getJSONObject("weibo").put("id","OTHER")},{it.put("duration",0)},
            {it.getJSONObject("weibo").put("page",page+"?credential=private")}
        )) { val item=media();change(item);assertNull(WebBrowserWeibo.metadata(item,document)) }
        assertNull(WebBrowserMediaPolicy.selectedCandidate(listOf(media().put("weibo_ready",false)),"clicked"))
        assertNull(WebBrowserMediaPolicy.selectedCandidate(listOf(media().put("weibo_enabled",false)),"clicked"))
        for (bad in listOf("http://weibo.com/", "https://weibo.com.evil/", "https://user@weibo.com/", "https://m.weibo.cn/")) assertFalse(WebBrowserWeibo.document(bad))
    }

    @Test fun standaloneVideoRequiresTheExactCurrentPublicFid() {
        val fid = "1034:4967272104787984"
        val detail = "https://weibo.com/tv/show/$fid"
        val tracked = "$detail?refer=video"
        val item = media().put("frame", tracked)
        item.getJSONObject("weibo").put("id", fid).put("page", detail).put("binding", "standalone")
        assertNotNull(WebBrowserWeibo.metadata(item, tracked))
        val changed = "https://weibo.com/tv/show/1034:4967272104787985?refer=video"
        assertNull(WebBrowserWeibo.metadata(item.put("frame", changed), changed))
        assertNull(WebBrowserWeibo.metadata(item.put("frame", document), document))
        assertNull(WebBrowserWeibo.metadata(item.put("frame", tracked).put("protected", true), tracked))
    }
}
