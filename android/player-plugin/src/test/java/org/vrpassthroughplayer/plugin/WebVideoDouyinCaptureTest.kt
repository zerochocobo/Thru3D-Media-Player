package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.nio.ByteBuffer

class WebVideoDouyinCaptureTest {
    private val page = WebVideoDouyinCapture.page("https://www.douyin.com/video/6961737553342991651")!!
    private val declared = "https://cdn.test/full.mp4?signature=synthetic"
    private val source = "$declared&temp=1&__vid=fixture"
    private fun media() = JSONObject().put("douyin_enabled",true).put("protected",false).put("frame",page.url)
        .put("source",source).put("width",576).put("height",1024).put("duration",20).put("title","fixture")
        .put("douyin",JSONObject().put("page",page.url).put("id",page.id).put("duration",20)
            .put("video",JSONArray().put(JSONObject().put("width",576).put("height",1024).put("urls",JSONArray().put(declared)))))
        .put("network",JSONArray().put(JSONObject().put("url",source).put("kind","file").put("headers",JSONObject().put("Referer",page.url))))
    // Same bounded MP4 header fixture as WebVideoNetworkCaptureTest, with real track boxes.
    private fun mp4(audio: Boolean, video: Boolean = true, durationMs: Int = 20000): ByteArray {
        fun box(type: String, data: ByteArray) = ByteBuffer.allocate(8+data.size).putInt(8+data.size).put(type.toByteArray()).put(data).array()
        fun track(video: Boolean): ByteArray {
            val sample=if(video) ByteArray(78).also { ByteBuffer.wrap(it).putShort(24,576).putShort(26,1024) }+box("avcC",byteArrayOf(1,100,0,40)) else ByteArray(28)
            val stsd=box("stsd",ByteBuffer.allocate(8).putInt(0).putInt(1).array()+box(if(video)"avc1" else "mp4a",sample))
            val mdhd=ByteBuffer.allocate(24).putInt(12,1000).putInt(16,durationMs).array()
            val hdlr=ByteArray(24).also{(if(video)"vide" else "soun").toByteArray().copyInto(it,8)}
            return box("trak",box("mdia",box("mdhd",mdhd)+box("hdlr",hdlr)+box("minf",box("stbl",stsd))))
        }
        return box("ftyp","isom0000isom".toByteArray())+box("moov",(if(video)track(true) else byteArrayOf())+(if(audio)track(false) else byteArrayOf()))
    }
    @Test fun verifiesBothContainerTracksAndUsesOnlyExactObservedRequest() {
        var reads=0
        val network=WebVideoNetworkCapture({uri,headers,_->
            reads++;assertEquals(source,uri.toString());assertEquals(page.url,headers["referer"]);uri to mp4(true)
        },{true})
        val info=WebVideoDouyinCapture.resolve(page,media(),network)
        assertNotNull(info);assertEquals(1,reads)
        val d=WebVideoFormats.select(page,info!!){true}
        assertTrue(d.video.hasAudio);assertNull(d.audio);assertFalse(d.publicJson().toString().contains("synthetic"))
    }
    @Test fun renderedFeedKeepsItsOriginalDocumentAndRejectsStaleOwners() {
        val frame="https://www.douyin.com/"
        val m=media().put("frame",frame).put("blob",true).put("source","")
        val blob="blob:https://www.douyin.com/synthetic"
        m.put("douyin_source",blob).put("capture_identity","rendered-selection").put("network_epoch",9)
        m.getJSONObject("douyin").put("page",frame).put("binding","rendered_card").put("active_id",page.id).put("observed_file",source)
            .put("src",blob).put("revision","1234abcd").put("width",m.getInt("width")).put("height",m.getInt("height"))
        assertEquals(page,WebVideoDouyinCapture.selectedPage(m))
        assertNotNull(WebVideoDouyinCapture.candidate(page,m))
        val network=WebVideoNetworkCapture({uri,_,_->uri to mp4(true)},{true})
        assertNotNull(WebVideoDouyinCapture.resolve(page,m,network))
        assertEquals(page,WebVideoDouyinCapture.page(frame,m))
        assertTrue(WebVideoDouyinCapture.keeps(page,m,JSONObject(m.toString())))
        val changed=JSONObject(m.toString());changed.getJSONObject("douyin").put("revision","1234abce")
        assertFalse(WebVideoDouyinCapture.keeps(page,m,changed))
        m.getJSONObject("douyin").put("active_id","7674225615168824549")
        assertNull(WebVideoDouyinCapture.selectedPage(m));assertNull(WebVideoDouyinCapture.candidate(page,m))
        m.getJSONObject("douyin").put("page",page.url).put("active_id",page.id)
        assertNull(WebVideoDouyinCapture.selectedPage(m))
    }
    @Test fun silentFileNeverPassesAsPlayable() {
        val network=WebVideoNetworkCapture({uri,_,_->uri to mp4(false)},{true})
        assertNull(WebVideoDouyinCapture.resolve(page,media(),network))
    }
    @Test fun mseWholeFileRequiresDeclaredObservedBindingAndBothContainerTracks() {
        fun mse() = media().put("blob",true).put("source","").also {
            it.getJSONObject("douyin").put("observed_file",source)
        }
        val bound=WebVideoDouyinCapture.candidate(page,mse())!!
        assertEquals(source,bound.getString("source"))
        assertNotNull(WebVideoDouyinCapture.resolve(page,mse(),WebVideoNetworkCapture({uri,_,_->uri to mp4(true)},{true})))
        assertNull(WebVideoDouyinCapture.resolve(page,mse(),WebVideoNetworkCapture({uri,_,_->uri to mp4(false)},{true})))
        for(change in listOf<(JSONObject)->Unit>(
            {it.put("source",source)}, {it.put("blob",false)}, {it.put("network",JSONArray())},
            {it.getJSONObject("douyin").put("observed_file",source.replace("synthetic","other"))},
            {it.getJSONObject("douyin").put("observed_direct",true)})) {
            val invalid=mse();change(invalid);assertNull(WebVideoDouyinCapture.candidate(page,invalid))
        }
    }
    @Test fun msePairUsesOnlyCurrentDeclaredAudioAndInspectsBothWholeFiles() {
        val audio = "https://cdn.test/current.m4a?signature=synthetic"
        fun pair() = media().put("blob",true).put("source","").also { m ->
            m.getJSONObject("douyin").put("observed_file",source).put("observed_audio",audio)
                .put("audio",JSONArray().put(JSONObject().put("id","current-audio").put("urls",JSONArray().put(audio))))
            m.getJSONArray("network").put(JSONObject().put("kind","file").put("url",audio)
                .put("headers",JSONObject().put("Authorization","synthetic-audio-only")))
        }
        fun network(audioBytes: ByteArray = mp4(true,false)) = WebVideoNetworkCapture({uri,headers,_->
            if(uri.toString()==audio) { assertEquals("synthetic-audio-only",headers["authorization"]);uri to audioBytes }
            else { assertFalse(headers.containsKey("authorization"));uri to mp4(false) }
        },{true})
        val info=WebVideoDouyinCapture.resolve(page,pair(),network())!!
        val selected=WebVideoFormats.select(page,info){true}
        val selectedAudio=selected.audio!!
        assertEquals(source,selected.video.url.toString());assertEquals(audio,selectedAudio.url.toString())
        assertFalse(selected.video.hasAudio);assertTrue(selectedAudio.hasAudio)
        assertNull(WebVideoDouyinCapture.resolve(page,pair(),network(mp4(false)))) // Another video cannot be an audio track.
        assertNull(WebVideoDouyinCapture.resolve(page,pair(),network(mp4(true,false,3000)))) // No soundtrack/preview guessing.
        val unobserved=pair();unobserved.getJSONArray("network").remove(1)
        assertNull(WebVideoDouyinCapture.candidate(page,unobserved))
        val unrelated=pair();unrelated.getJSONObject("douyin").getJSONArray("audio").getJSONObject(0).put("urls",JSONArray().put(audio+"&other=1"))
        assertNull(WebVideoDouyinCapture.candidate(page,unrelated))
        val generic=WebVideoDouyinCapture.candidate(page,pair())!!.put("source","")
        assertNull(network().resolve(page,generic)) // Generic capture still cannot pair these opaque URLs.
    }
    @Test fun mseSharedContainerMustActuallyContainBothTracks() {
        fun shared() = media().put("blob",true).put("source","").also { m ->
            m.getJSONObject("douyin").put("observed_file",source).put("observed_muxed",true)
                .put("audio",JSONArray().put(JSONObject().put("id","muxed-file").put("urls",JSONArray().put(declared))))
        }
        var reads=0
        val full=WebVideoNetworkCapture({uri,headers,_->
            reads++;assertEquals(source,uri.toString());assertEquals(page.url,headers["referer"])
            uri to mp4(true)
        },{true})
        assertNotNull(WebVideoDouyinCapture.resolve(page,shared(),full));assertEquals(1,reads)
        assertNull(WebVideoDouyinCapture.resolve(page,shared(),WebVideoNetworkCapture({uri,_,_->uri to mp4(false)},{true})))
        assertNull(WebVideoDouyinCapture.resolve(page,shared(),WebVideoNetworkCapture({uri,_,_->uri to mp4(true,false)},{true})))
        val duplicate=shared();duplicate.getJSONObject("douyin").put("observed_audio",source)
        assertNull(WebVideoDouyinCapture.candidate(page,duplicate))
    }
    @Test fun directObservedFileHasIndependentIdentityAndStillRequiresBothRealContainerTracks() {
        val directSource = source.replace("__vid=fixture", "__vid=${page.id}")
        fun direct() = media().also { m ->
            m.put("source", directSource)
            m.getJSONArray("network").getJSONObject(0).put("url", directSource)
            val d=m.getJSONObject("douyin").put("observed_direct",true)
            d.getJSONArray("video").getJSONObject(0).put("urls",JSONArray().put(directSource))
        }
        assertNotNull(WebVideoDouyinCapture.resolve(page,direct(),WebVideoNetworkCapture({uri,_,_->uri to mp4(true)},{true})))
        assertNull(WebVideoDouyinCapture.resolve(page,direct(),WebVideoNetworkCapture({uri,_,_->uri to mp4(false)},{true})))
        val wrong=direct();wrong.put("source",source)
        assertNull(WebVideoDouyinCapture.candidate(page,wrong))
    }
    @Test fun rejectsStalePagePreviewProtectedAndUnobservedReplacement() {
        for (change in listOf<(JSONObject)->Unit>(
            {it.put("protected",true)}, {it.put("width",1080)}, {it.put("duration",2.6)},
            {it.put("frame",page.url.replace(page.id,"7674225615168824549"))}, {it.put("source",source.replace("synthetic","other"))},
            {it.put("network",JSONArray())}, {it.put("douyin_enabled",false)})) {
            val m=media();change(m);assertNull(WebVideoDouyinCapture.candidate(page,m))
        }
        assertThrows(Exception::class.java){WebVideoPage.parse(page.url)} // ordinary extractor remains disabled
    }
}
