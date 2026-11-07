package org.vrpassthroughplayer.plugin

import java.net.URI
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class WebVideoNiconicoCaptureTest {
    private val page="https://www.nicovideo.jp/watch/sm9"
    private val root="https://related.test/master.m3u8";private val video="https://video.test/current.m3u8";private val audio="https://audio.test/current.m3u8"
    private val key="https://keys.test/ordinary-aes-key"
    private val master="#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\",DEFAULT=YES,URI=\"$audio\"\n#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=512x384,CODECS=\"avc1.64001e,mp4a.40.2\",AUDIO=\"audio\"\n$video\n"
    private fun item(): JSONObject {
        val requests=JSONArray()
        for(url in listOf(root,video,audio,key))requests.put(JSONObject().put("url",url).put("kind",if(url==key)"segment" else "hls")
            .put("headers",JSONObject().put("authorization",if(url==key)"key-request-only" else "own-$url")))
        return JSONObject().put("frame",page).put("blob",true).put("source","").put("niconico_source","blob:https://www.nicovideo.jp/current")
            .put("width",512).put("height",384).put("duration",10.1).put("niconico_enabled",true).put("niconico_ready",true).put("capture_identity","selected")
            .put("network",requests).put("niconico",JSONObject().put("id","sm9").put("page",page).put("revision","ab1")
                .put("root",root).put("video",video).put("audio",audio).put("resources",JSONArray().put(key))
                .put("master_playlist",master)
                .put("width",512).put("height",384).put("duration",10.1).put("expected_duration",10.1).put("audio_duration",10.08)
                .put("vcodec","avc1.64001e").put("acodec","mp4a.40.2"))
    }
    private fun capture(drm: Boolean=false)=WebVideoNetworkCapture({uri,_,_ -> uri to (if(uri.toString()==root)
        error("The observed master must not be refetched")
        else "#EXTM3U\n#EXT-X-KEY:METHOD=${if(drm)"SAMPLE-AES" else "AES-128"},URI=\"$key\"\n#EXTINF:10.1,\nsegment.ts\n#EXT-X-ENDLIST\n").toByteArray()
    },{true})
    @Test fun exactGraphResolvesThroughExistingHlsWithPerRequestKeyHeaders() {
        val m=item();val p=WebVideoNiconicoCapture.page(page,m)!!;assertEquals("niconico",p.site)
        val info=WebVideoNiconicoCapture.resolve(p,m,capture())!!;val selected=WebVideoFormats.select(p,info){true}
        assertEquals(URI(video),selected.video.url);assertEquals(URI(audio),selected.audio!!.url)
        val format=info.getJSONArray("formats").getJSONObject(0)
        assertEquals("key-request-only",format.getJSONObject("browser_headers").getJSONObject(key).getString("authorization"))
        assertTrue(WebVideoNiconicoCapture.keeps(p,m,JSONObject(m.toString()).put("playing",false),selected.video))
        assertFalse(WebVideoNiconicoCapture.keeps(p,m,JSONObject(m.toString()).put("niconico_source","blob:https://www.nicovideo.jp/new"),selected.video))
    }
    @Test fun protectedLeafAndReplacedSignedAudioCannotResolve() {
        val m=item();val p=WebVideoNiconicoCapture.page(page,m)!!
        assertNull(WebVideoNiconicoCapture.resolve(p,m,capture(true)))
        m.getJSONObject("niconico").put("audio",audio+"?different=1");assertNull(WebVideoNiconicoCapture.candidate(p,m))
    }
    @Test fun observedMasterRetainsEverySignedSelectorAndCannotBeReplacedByAnotherGraph() {
        val m=item();val p=WebVideoNiconicoCapture.page(page,m)!!
        m.getJSONObject("niconico").put("master_playlist",master.replace(video,video+"?different=1"))
        assertNull(WebVideoNiconicoCapture.resolve(p,m,capture()))
        m.getJSONObject("niconico").remove("master_playlist");assertNull(WebVideoNiconicoCapture.candidate(p,m))
    }
}
