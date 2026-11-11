package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.net.URI
import java.nio.ByteBuffer

class WebVideoNetworkCaptureTest {
    @Test fun largeJavascriptIqiyiVectorSurvivesDeclaredHlsSelectionAndTheValidatedPlayerPlan() {
        // The same checked-in vector is generated and compared by the browser's
        // JS tests; AGP may run this test from the root, android, or module dir.
        val relative="web-browser/src/test/resources/iqiyi-large-wire.json"
        val fixture=listOf(java.io.File("../$relative"),java.io.File(relative),java.io.File("android/$relative")).single { it.isFile }
        val m=JSONObject(fixture.readText());val p=WebVideoPage.parse(m.getString("frame"))
        val plan=WebBrowserIqiyi.resourcePlan(m,p.url)!!;val body=plan.getString("playlist");plan.remove("playlist")
        assertTrue(body.length>256*1024);assertTrue(plan.toString().length>256*1024)
        val reads=mutableListOf<URI>()
        fun resolve(input: JSONObject=m,bytes: ByteArray=mp4(width=1440,duration=436),duration: Double=436.0) =
            resolver(emptyMap()).resolveDeclaredHls(p,input,URI(p.url),body,duration) { uri,_,_ ->
            reads.add(uri);uri to bytes
        }
        val info=resolve()!!;assertEquals(1,reads.size);assertTrue(reads.single().toString().contains("issued=UNIT%2bEXACT%3D"))
        val plain=JSONObject(info.toString())
        assertThrows(IllegalStateException::class.java) { WebVideoFormats.select(p,plain){true} }
        info.getJSONArray("formats").getJSONObject(0).put("browser_iqiyi",plan)
        val selected=WebVideoFormats.select(p,info){true};assertEquals(body,selected.video.browserManifest)
        assertEquals(436,selected.video.browserIqiyi!!.getJSONArray("requests").length())
        assertNotNull(resolve(JSONObject(m.toString()).put("duration",437)))
        assertNull(resolve(JSONObject(m.toString()).put("duration",437.1)))
        assertNull(resolve(JSONObject(m.toString()).put("duration",437),duration=437.0))
        assertNull(resolve(JSONObject(m.toString()).put("protected",true)))
        assertNull(resolve(bytes=mp4(width=1440,duration=436,protected=true)))
        val wrong=JSONObject(plan.toString());wrong.getJSONArray("requests").getJSONObject(0).put("file",99)
        info.getJSONArray("formats").getJSONObject(0).put("browser_iqiyi",wrong)
        assertThrows(IllegalStateException::class.java) { WebVideoFormats.select(p,info){true} }
    }
    private fun redditGif(file: String,other: String="https://other.test/unused.mp4"): JSONObject {
        val document="https://www.reddit.com/r/gifs/comments/abc123/title/"
        return media(candidate(file,headers=JSONObject().put("Authorization","selected-file-only")),
            candidate(other,headers=JSONObject().put("Authorization","unrelated-only")),direct=file)
            .put("frame",document).put("reddit_source",file).put("reddit_enabled",true).put("reddit_ready",true).put("capture_identity","selected")
            .put("reddit",JSONObject().put("id","abc123").put("active_id","abc123").put("page",document).put("document",document)
                .put("binding","rendered_gif").put("declared_gif",true).put("source",file).put("revision","a1")
                .put("width",1920).put("height",1080).put("duration",10).put("expected_duration",10))
    }
    @Test fun redditGifProbesOnlyItsReceivedWholeFileAndPreservesRealAudioWhenPresent() {
        val file="https://related.test:8443/current.gif?format=EXACT";val m=redditGif(file)
        val p=WebVideoRedditCapture.page(m.getString("frame"),m)!!
        val reads=mutableListOf<Pair<URI,Map<String,String>>>()
        val info=WebVideoRedditCapture.resolve(p,m,resolver(mapOf(file to mp4(audio=false)),reads))!!
        assertEquals(listOf(URI(file)),reads.map{it.first});assertEquals("selected-file-only",reads.single().second["authorization"])
        assertTrue(info.getBoolean("browser_explicit_silent"));assertTrue(info.getBoolean("browser_reddit_gif"))
        val selected=WebVideoFormats.select(p,info){true};assertTrue(selected.silent)
        assertEquals(file,selected.video.url.toString());assertTrue(WebVideoRedditCapture.keeps(p,m,m,selected.video))
        val missingProof=JSONObject(info.toString());missingProof.remove("browser_reddit_gif")
        assertThrows(IllegalStateException::class.java){WebVideoFormats.select(p,missingProof){true}}
        assertThrows(IllegalStateException::class.java){WebVideoFormats.select(page,info){true}}
        val voiced=WebVideoRedditCapture.resolve(p,m,resolver(mapOf(file to mp4())))!!
        assertFalse(voiced.getBoolean("browser_explicit_silent"))
        val actualAudio=WebVideoFormats.select(p,voiced){true};assertFalse(actualAudio.silent);assertTrue(actualAudio.video.hasAudio)
    }
    @Test fun redditGifCannotBorrowProtectionDimensionsDurationRequestsOrOrdinaryVideoSilence() {
        val file="https://related.test/current.gif?format=EXACT";val m=redditGif(file);val p=WebVideoRedditCapture.page(m.getString("frame"),m)!!
        for(bytes in listOf(mp4(audio=false,protected=true),mp4(audio=false,width=1280,height=720),mp4(audio=false,duration=12),mp4(video=false)))
            assertNull(WebVideoRedditCapture.resolve(p,m,resolver(mapOf(file to bytes))))
        for(change in listOf<(JSONObject)->Unit>({it.put("network",JSONArray())},{it.put("protected",true)},
            {it.getJSONObject("reddit").put("declared_gif","true")},{it.getJSONObject("reddit").put("active_id","another")},
            {it.getJSONObject("reddit").put("binding","rendered_post").remove("declared_gif")})) {
            val changed=JSONObject(m.toString());change(changed)
            assertNull(WebVideoRedditCapture.resolve(p,changed,resolver(mapOf(file to mp4(audio=false)))))
        }
        val info=WebVideoRedditCapture.resolve(p,m,resolver(mapOf(file to mp4(audio=false))))!!
        val track=WebVideoFormats.select(p,info){true}.video
        val changed=JSONObject(m.toString());changed.getJSONObject("reddit").put("binding","rendered_post").remove("declared_gif")
        assertFalse(WebVideoRedditCapture.keeps(p,m,changed,track))
    }

    @Test fun declaredNaverTimelineNeverFetchesTheExportOrBorrowsAnotherSegmentsAuthorization() {
        val root=URI("https://declared.test/current.m3u8?signature=ROOT")
        val first="https://segments.test/current/0.ts?signature=EXACT"
        val next="https://segments.test/current/1.ts?signature=EXACT"
        val body="#EXTM3U\n#EXT-X-TARGETDURATION:5\n#EXTINF:5,\n$first\n#EXTINF:5,\n$next\n#EXT-X-ENDLIST\n"
        val plan=WebBrowserNaver.Timeline(root,body,setOf(first,next),10.0)
        val p=WebVideoPage("naver","A".repeat(36),WebBrowserNaver.canonical("A".repeat(36),"CLIP"))
        val m=media(candidate(next,"segment",JSONObject().put("Authorization","next-only").put("Cookie","unscoped=next-only")
            .put("Referer",p.url).put("Origin","https://m.naver.com")))
        val reads=mutableListOf<Pair<URI,Map<String,String>>>()
        val info=resolver(mapOf(first to mp4()),reads).resolveDeclaredNaverTimeline(p,m,plan)!!
        assertEquals(listOf(URI(first)),reads.map{it.first});assertFalse(reads.single().second.containsKey("authorization"))
        assertFalse(reads.single().second.containsKey("cookie"));assertEquals("https://m.naver.com",reads.single().second["origin"])
        assertTrue(info.getBoolean("browser_declared_timeline"))
        val format=info.getJSONArray("formats").getJSONObject(0)
        assertEquals(root.toString(),format.getString("url"));assertEquals(body,format.getString("browser_manifest"))
        assertFalse(format.getJSONObject("browser_headers").has(root.toString()))
        assertNull(resolver(emptyMap()).resolveDeclaredNaverTimeline(p,media(),plan))
        assertNull(resolver(emptyMap()).resolveDeclaredNaverTimeline(p,media(candidate(next+"&changed=1","segment")),plan))
        assertNull(resolver(mapOf(first to mp4(protected=true))).resolveDeclaredNaverTimeline(p,m,plan))
    }
    @Test fun odyseeUsesTheDeclaredCurrentClaimAndOnlyItsObservedFileRequest() {
        val document="https://odysee.com/@PublicChannel:2/PublicClip:1";val claim="1"+"a".repeat(39)
        val file="https://related.test:8443/v6/streams/$claim/abcdef.mp4?selection=exact"
        val declared="https://other-related.test/api/v3/streams/free/PublicClip/$claim/abcdef.mp4"
        val other="https://other.test/ad.mp4"
        val baseline=media(candidate(file,headers=JSONObject().put("Authorization","actual-file-only")),candidate(other),direct=file)
            .put("frame",document).put("odysee_source",file).put("odysee_enabled",true).put("odysee_ready",true).put("capture_identity","selected")
            .put("odysee",JSONObject().put("id","@PublicChannel:2/PublicClip:1").put("page",document).put("source",file).put("declared_source",declared)
                .put("claim_id",claim).put("file_id","abcdef.mp4").put("revision","a1").put("width",1920).put("height",1080)
                .put("duration",10).put("expected_duration",10).put("whole_seconds",true))
        val rendered=JSONObject(baseline.toString()).also { it.getJSONObject("odysee").put("binding","rendered_file")
            .put("declared_source",file).put("claim_uri","lbry://@PublicChannel#2/PublicClip#1") }
        for(m in listOf(baseline,rendered)) {
            val p=WebVideoOdyseeCapture.page(document,m)!!;val reads=mutableListOf<Pair<URI,Map<String,String>>>()
            val info=WebVideoOdyseeCapture.resolve(p,m,resolver(mapOf(file to mp4()),reads))!!
            val selected=WebVideoFormats.select(p,info){true}
            assertEquals(file,selected.video.url.toString());assertEquals(listOf(URI(file)),reads.map{it.first})
            assertEquals("actual-file-only",reads.single().second["authorization"])
            assertTrue(WebVideoOdyseeCapture.keeps(p,m,m,selected.video))
            val changed=JSONObject(m.toString());changed.getJSONObject("odysee").put("revision","a2")
            assertFalse(WebVideoOdyseeCapture.keeps(p,m,changed,selected.video))
            changed.getJSONObject("odysee").put("declared_source",declared.replace("abcdef","abcdee"))
            assertNull(WebVideoOdyseeCapture.resolve(p,changed,resolver(mapOf(file to mp4()))))
            assertNull(WebVideoOdyseeCapture.resolve(p,JSONObject(m.toString()).put("protected",true),resolver(mapOf(file to mp4()))))
            assertNull(WebVideoOdyseeCapture.resolve(p,m,resolver(mapOf(file to mp4(protected=true)))))
            assertNull(WebVideoOdyseeCapture.resolve(p,m,resolver(mapOf(file to mp4(width=1280,height=720)))))
        }
    }
    @Test fun odyseeRenderedHlsUsesOnlyItsClaimRootAndObservedTracksWithTheirOwnCredentials() {
        val document="https://odysee.com/@PublicChannel:2/PublicClip:1";val claim="1"+"a".repeat(39)
        val root="https://root.test:8443/v6/streams/$claim/opaque/master.m3u8?actual=EXACT"
        val video="https://video.related.test/selected.m3u8";val audio="https://audio.related.test/selected.m3u8"
        val unrelated="https://another-player.test/master.m3u8"
        val master="#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"en\",DEFAULT=YES,URI=\"$audio\"\n"+
            "#EXT-X-STREAM-INF:BANDWIDTH=1000000,RESOLUTION=1920x1080,CODECS=\"avc1.640028,mp4a.40.2\",AUDIO=\"en\"\n$video\n"
        val vod="#EXTM3U\n#EXTINF:10,\nsegment.ts\n#EXT-X-ENDLIST\n"
        val resources=mapOf(root to master.toByteArray(),video to vod.toByteArray(),audio to vod.toByteArray())
        val blob="blob:https://odysee.com/current"
        val m=media(candidate(root,"hls",JSONObject().put("Authorization","root-only")),candidate(video,"hls"),
            candidate(audio,"hls",JSONObject().put("Authorization","audio-only")),candidate(unrelated,"hls"))
            .put("frame",document).put("blob",true).put("odysee_source",blob).put("odysee_enabled",true).put("odysee_ready",true).put("capture_identity","selected")
            .put("odysee",JSONObject().put("id","@PublicChannel:2/PublicClip:1").put("page",document).put("source",blob).put("binding","rendered_hls")
                .put("root",root).put("declared_source",root).put("claim_id",claim).put("claim_uri","lbry://@PublicChannel#2/PublicClip#1")
                .put("revision","a1").put("width",1920).put("height",1080).put("duration",10).put("expected_duration",10).put("whole_seconds",true))
        val p=WebVideoOdyseeCapture.page(document,m)!!;val reads=mutableListOf<Pair<URI,Map<String,String>>>()
        val info=WebVideoOdyseeCapture.resolve(p,m,resolver(resources,reads))!!
        val selected=WebVideoFormats.select(p,info){true}
        assertEquals(video,selected.video.url.toString());assertEquals(audio,selected.audio!!.url.toString())
        assertFalse(reads.any{it.first.toString()==unrelated});assertEquals("root-only",reads.first{it.first.toString()==root}.second["authorization"])
        assertEquals("audio-only",reads.first{it.first.toString()==audio}.second["authorization"])
        assertFalse(reads.first{it.first.toString()==video}.second.containsKey("authorization"))
        assertTrue(WebVideoOdyseeCapture.keeps(p,m,m,selected.video))
        val prefetch=JSONObject(m.toString());prefetch.getJSONArray("network").put(candidate("https://another.test/prefetch.m3u8","hls"))
        assertTrue(WebVideoOdyseeCapture.keeps(p,m,prefetch,selected.video))
        for (change in listOf<(JSONObject)->Unit>({it.put("protected",true)}, {it.put("odysee_source",blob+"-changed")},
            {it.getJSONObject("odysee").put("revision","a2")},{it.getJSONObject("odysee").put("root",root+"&changed=1")},
            {it.put("network",JSONArray().put(candidate(root,"hls")))})) {
            val latest=JSONObject(m.toString());change(latest);assertFalse(WebVideoOdyseeCapture.keeps(p,m,latest,selected.video))
        }
        val protected=resources.toMutableMap();protected[video]=vod.replace("#EXTINF:","#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"key\"\n#EXTINF:").toByteArray()
        assertNull(WebVideoOdyseeCapture.resolve(p,m,resolver(protected)))
        val noRoot=JSONObject(m.toString()).put("network",JSONArray().put(candidate(video,"hls")).put(candidate(audio,"hls")))
        assertNull(WebVideoOdyseeCapture.resolve(p,noRoot,resolver(resources)))
    }
    @Test fun archiveRequiresExactPresentationDimensionsFromTheSameFilesPixelAspectBox() {
        val document="https://archive.org/details/PublicFilm";val original="https://archive.org/download/PublicFilm/current.mp4"
        val file="https://related.test/current.mp4?selection=exact"
        val m=media(candidate(file).put("original_url",original),direct=original).put("width",426).put("height",240)
            .put("frame",document).put("archive_source",original).put("archive_enabled",true)
            .put("archive_ready",true).put("capture_identity","selected")
            .put("archive",JSONObject().put("id","PublicFilm").put("page",document).put("source",original).put("file",file)
                .put("revision","a1").put("width",426).put("height",240).put("duration",10))
        val p=WebVideoArchiveCapture.page(document,m)!!
        // Synthetic FFmpeg black 416x240 frame, setsar=40/39, libx264 ultrafast.
        val sps="6742c00dda0687effc00a0009c40000003004000000ca3c50aa8".chunked(2).map{it.toInt(16).toByte()}.toByteArray()
        val avc=byteArrayOf(1,66,-64,13,-1,-31)+ByteBuffer.allocate(2).putShort(sps.size.toShort()).array()+sps+byteArrayOf(0)
        for(bytes in listOf(mp4(width=416,height=240,aspect=40 to 39),mp4(width=416,height=240,avcConfig=avc))) {
            val header=WebVideoContainer.parse(bytes)!!
            assertEquals(416,header.width);assertEquals(426,header.displayWidth)
            assertEquals(40.0/39,header.pixelAspect,0.000001)
            val info=WebVideoArchiveCapture.resolve(p,m,resolver(mapOf(file to bytes)))!!
            val selected=WebVideoFormats.select(p,info){true}
            assertEquals(426,selected.video.width);assertEquals(416,info.getJSONArray("formats").getJSONObject(0).getInt("coded_width"))
            assertTrue(WebVideoArchiveCapture.keeps(p,m,m,selected.video))
        }
        assertNull(WebVideoArchiveCapture.resolve(p,m,resolver(mapOf(file to mp4(width=416,height=240)))))
        assertNull(WebVideoArchiveCapture.resolve(p,m,resolver(mapOf(file to mp4(width=416,height=240,aspect=41 to 39)))))
        assertNull(WebVideoArchiveCapture.resolve(p,m,resolver(mapOf(file to mp4(width=416,height=240,avcConfig=avc.copyOf(9))))))
        assertEquals(512,WebVideoContainer.parse(mp4(width=512,height=240,avcConfig=avc))!!.displayWidth)
        for(aspect in listOf(0 to 1,1 to 0,17 to 1,1 to 17,-1 to 1))assertNull(WebVideoContainer.parse(mp4(aspect=aspect)))
    }
    @Test fun archiveRedirectRetainsTheFinalRequestsOwnCredentialsAndCurrentFileIdentity() {
        val document="https://archive.org/details/PublicFilm";val original="https://archive.org/download/PublicFilm/current.mp4"
        val file="https://related.test:8443/current.mp4?selection=exact";val other="https://other.test/other.mp4"
        val m=media(candidate(file,headers=JSONObject().put("Authorization","final-only")).put("original_url",original),
            candidate(original,headers=JSONObject().put("Authorization","original-only")),candidate(other),direct=original)
            .put("frame",document).put("archive_source",original).put("archive_enabled",true)
            .put("archive_ready",true).put("capture_identity","selected")
            .put("archive",JSONObject().put("id","PublicFilm").put("page",document).put("source",original).put("file",file)
                .put("revision","a1").put("width",1920).put("height",1080).put("duration",10))
        val p=WebVideoArchiveCapture.page(document,m)!!;val reads=mutableListOf<Pair<URI,Map<String,String>>>()
        val info=WebVideoArchiveCapture.resolve(p,m,resolver(mapOf(file to mp4()),reads))!!
        val selected=WebVideoFormats.select(p,info){true}
        assertEquals(file,selected.video.url.toString());assertEquals(listOf(URI(file)),reads.map{it.first})
        assertEquals("final-only",reads.single().second["authorization"])
        assertTrue(WebVideoArchiveCapture.keeps(p,m,m,selected.video))
        val changed=JSONObject(m.toString());changed.getJSONObject("archive").put("revision","a2")
        assertFalse(WebVideoArchiveCapture.keeps(p,m,changed,selected.video))
        changed.getJSONArray("network").getJSONObject(0).put("original_url",original+"?another=1")
        assertNull(WebVideoArchiveCapture.resolve(p,changed,resolver(mapOf(file to mp4()))))
        assertNull(WebVideoArchiveCapture.resolve(p,JSONObject(m.toString()).put("protected",true),resolver(mapOf(file to mp4()))))
        assertNull(WebVideoArchiveCapture.resolve(p,m,resolver(mapOf(file to mp4(protected=true)))))
    }
    @Test fun streamableUsesOnlyTheSelectedDeclaredClipAndItsOwnRequestHeaders() {
        val document="https://streamable.com/abc123";val file="https://related.test:8443/abc123.mp4?selection=exact"
        val other="https://other.test/abc123.mp4?selection=other"
        val m=media(candidate(file,headers=JSONObject().put("Authorization","file-only")),candidate(other),direct=file)
            .put("frame",document).put("streamable_source",file).put("streamable_enabled",true)
            .put("streamable_ready",true).put("capture_identity","selected")
            .put("streamable",JSONObject().put("id","abc123").put("page",document).put("source",file).put("revision","a1")
                .put("width",1920).put("height",1080).put("duration",10).put("expected_duration",10))
        val p=WebVideoStreamableCapture.page(document,m)!!;val reads=mutableListOf<Pair<URI,Map<String,String>>>()
        val info=WebVideoStreamableCapture.resolve(p,m,resolver(mapOf(file to mp4()),reads))!!
        val selected=WebVideoFormats.select(p,info){true}
        assertEquals(file,selected.video.url.toString());assertEquals(listOf(URI(file)),reads.map{it.first})
        assertEquals("file-only",reads.single().second["authorization"])
        assertTrue(WebVideoStreamableCapture.keeps(p,m,m,selected.video))
        val changed=JSONObject(m.toString());changed.getJSONObject("streamable").put("revision","a2")
        assertFalse(WebVideoStreamableCapture.keeps(p,m,changed,selected.video))
        for(change in listOf<(JSONObject)->Unit>({it.put("protected",true)},{it.put("streamable_ready",false)},
            {it.put("network",JSONArray().put(candidate(other)))},{it.put("source",other)})) {
            val item=JSONObject(m.toString());change(item)
            assertNull(WebVideoStreamableCapture.resolve(p,item,resolver(mapOf(file to mp4()))))
        }
        assertNull(WebVideoStreamableCapture.resolve(p,m,resolver(mapOf(file to mp4(protected=true)))))
        assertNull(WebVideoStreamableCapture.resolve(p,m,resolver(mapOf(file to mp4(width=1280,height=720)))))
    }
    @Test fun declaredInstagramFileUsesItsOriginalMpdUrlAndNeverBorrowsRangeAuthorization() {
        val document="https://www.instagram.com/reel/Chunk8-jurw/";val p=WebVideoPage.parse(document)
        val file="https://new-cdn.test/current.mp4?selection=exact";val partial=file+"&bytestart=901&byteend=999"
        val xml="""<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" mediaPresentationDuration="PT10S"><Period><AdaptationSet><Representation id="v1" mimeType="video/mp4" codecs="avc1.640028" width="1920" height="1080" bandwidth="1000000"><BaseURL>$file</BaseURL><SegmentBase indexRange="845-900"><Initialization range="0-844"/></SegmentBase></Representation></AdaptationSet></Period></MPD>"""
        val m=media(candidate(partial,headers=JSONObject().put("Authorization","range-only").put("Referer","https://www.instagram.com/").put("User-Agent","video-context"))).put("frame",document).put("blob",true)
            .put("instagram_source","blob:https://www.instagram.com/current").put("instagram_ready",true).put("instagram_enabled",true).put("capture_identity","chosen")
            .put("instagram",JSONObject().put("id","Chunk8-jurw").put("page",document).put("media_id","12345678901234567").put("revision","a1")
                .put("manifest",xml).put("has_audio",false).put("audio",JSONObject.NULL).put("width",1920).put("height",1080).put("duration",10).put("expected_duration",10)
                .put("video",JSONObject().put("id","v1").put("url",file).put("bandwidth",1000000).put("requests",JSONArray().put(partial))))
        val reads=mutableListOf<Pair<URI,Map<String,String>>>()
        val info=resolver(mapOf(file to mp4(audio=false)),reads).resolveDeclaredInstagramFiles(p,m,URI(file),null,true)!!
        val selected=WebVideoFormats.select(p,info){true}
        assertTrue(selected.silent);assertEquals(file,selected.video.url.toString());assertEquals(listOf(URI(file)),reads.map{it.first})
        assertFalse(reads.single().second.containsKey("authorization"));assertEquals("https://www.instagram.com/",reads.single().second["referer"])
        assertEquals("video-context",reads.single().second["user-agent"])
        assertNull(resolver(mapOf(file to mp4(audio=false))).resolveDeclaredInstagramFiles(p,m,URI(file+"&changed=1"),null,true))
        assertNull(resolver(mapOf(file to mp4())).resolveDeclaredInstagramFiles(p,m,URI(file),null,true))
        assertNull(resolver(mapOf(file to mp4(audio=false))).resolveDeclaredInstagramFiles(p,JSONObject(m.toString()).put("network",JSONArray()),URI(file),null,true))
        assertThrows(IllegalStateException::class.java){WebVideoFormats.select(page,info){true}}
        val audio="https://audio-related.test/current.m4a?selection=own";val audioRange=audio+"&bytestart=901&byteend=999"
        val audioXml="""<AdaptationSet><Representation id="a1" mimeType="audio/mp4" codecs="mp4a.40.2" bandwidth="128000"><BaseURL>$audio</BaseURL><SegmentBase indexRange="845-900"><Initialization range="0-844"/></SegmentBase></Representation></AdaptationSet>"""
        val voiced=JSONObject(m.toString());voiced.getJSONArray("network").put(candidate(audioRange,headers=JSONObject().put("Authorization","audio-range-only").put("User-Agent","audio-context")))
        voiced.getJSONObject("instagram").put("has_audio",true).put("manifest",xml.replace("</Period>",audioXml+"</Period>"))
            .put("audio",JSONObject().put("id","a1").put("url",audio).put("bandwidth",128000).put("requests",JSONArray().put(audioRange)))
        val voicedReads=mutableListOf<Pair<URI,Map<String,String>>>()
        val voicedInfo=resolver(mapOf(file to mp4(audio=false),audio to mp4(video=false)),voicedReads).resolveDeclaredInstagramFiles(p,voiced,URI(file),URI(audio),false)!!
        val voicedSelection=WebVideoFormats.select(p,voicedInfo){true}
        assertFalse(voicedSelection.silent);assertEquals(audio,voicedSelection.audio!!.url.toString())
        assertTrue(voicedReads.none{it.second.containsKey("authorization")})
        assertEquals("audio-context",voicedReads.single{it.first.toString()==audio}.second["user-agent"])
        assertNotNull(resolver(mapOf(file to mp4(audio=false),audio to mp4(video=false,durationMs=9831))).resolveDeclaredInstagramFiles(p,voiced,URI(file),URI(audio),false))
        assertNotNull(resolver(mapOf(file to mp4(audio=false),audio to mp4(video=false,durationMs=9749))).resolveDeclaredInstagramFiles(p,voiced,URI(file),URI(audio),false))
        assertNotNull(resolver(mapOf(file to mp4(audio=false),audio to mp4(video=false,durationMs=9321))).resolveDeclaredInstagramFiles(p,voiced,URI(file),URI(audio),false))
        assertNotNull(resolver(mapOf(file to mp4(audio=false),audio to mp4(video=false,durationMs=8000))).resolveDeclaredInstagramFiles(p,voiced,URI(file),URI(audio),false))
        assertNull(resolver(mapOf(file to mp4(audio=false),audio to mp4(video=false,durationMs=7999))).resolveDeclaredInstagramFiles(p,voiced,URI(file),URI(audio),false))
        assertNull(resolver(mapOf(file to mp4(audio=false),audio to mp4(video=false,durationMs=12001))).resolveDeclaredInstagramFiles(p,voiced,URI(file),URI(audio),false))
        assertNull(resolver(mapOf(file to mp4(audio=false,durationMs=9831),audio to mp4(video=false))).resolveDeclaredInstagramFiles(p,voiced,URI(file),URI(audio),false))
        val missingAudio=JSONObject(voiced.toString());missingAudio.put("network",m.getJSONArray("network"))
        assertNull(resolver(mapOf(file to mp4(audio=false),audio to mp4(video=false))).resolveDeclaredInstagramFiles(p,missingAudio,URI(file),URI(audio),false))
    }
    @Test fun rootedCurrentHlsIgnoresPrefetchedQualitiesOutsideTheDecodedRepresentation() {
        val root="https://current.test/master.m3u8?selection=exact"
        val video="https://current.test/low.m3u8";val audio="https://current.test/audio.m3u8"
        val history=listOf(416 to 234,640 to 360,854 to 480,1280 to 720,1920 to 1080)
        val master="#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"en\",DEFAULT=YES,URI=\"audio.m3u8\"\n"+
            "#EXT-X-STREAM-INF:BANDWIDTH=100000,RESOLUTION=320x180,CODECS=\"avc1.4d400d,mp4a.40.2\",AUDIO=\"en\"\nlow.m3u8\n"+
            history.mapIndexed { i,(w,h) -> "#EXT-X-STREAM-INF:BANDWIDTH=${200000+i*100000},RESOLUTION=${w}x$h,CODECS=\"avc1.640028,mp4a.40.2\",AUDIO=\"en\"\nhistory$i.m3u8\n" }.joinToString("")
        val vod="#EXTM3U\n#EXTINF:10,\nsegment.ts\n#EXT-X-ENDLIST\n"
        val data=mapOf(root to master.toByteArray(),video to vod.toByteArray(),audio to vod.toByteArray())
        val observed=listOf(candidate(root,"hls",JSONObject().put("Authorization","root-only")),
            candidate(video,"hls",JSONObject().put("Authorization","video-only")),candidate(audio,"hls",JSONObject().put("Authorization","audio-only")))+
            history.indices.map { candidate("https://current.test/history$it.m3u8","hls") }
        val m=media(*observed.toTypedArray()).put("width",320).put("height",180)
        val reads=mutableListOf<Pair<URI,Map<String,String>>>()
        val info=resolver(data,reads).resolveRootedCurrentHls(page,m,URI(root))
        assertNotNull("Observed ABR history must not consume the current graph budget",info)
        val selected=WebVideoFormats.select(page,info!!){true}
        assertEquals(video,selected.video.url.toString());assertEquals(audio,selected.audio!!.url.toString())
        assertEquals(listOf(URI(root),URI(video),URI(audio)),reads.map { it.first })
        assertEquals(listOf("root-only","video-only","audio-only"),reads.map { it.second["authorization"] })
        val missing=media(*observed.filterNot { it.optString("url")==video }.toTypedArray()).put("width",320).put("height",180)
        assertNull(resolver(data).resolveRootedCurrentHls(page,missing,URI(root)))
        val protected=JSONObject(m.toString()).put("protected",true)
        assertNull(resolver(data).resolveRootedCurrentHls(page,protected,URI(root)))
    }

    @Test fun rootedCurrentHlsRetainsItsBudgetForManyObservedSameSizeAliases() {
        val root="https://current.test/master.m3u8";val audio="https://current.test/audio.m3u8"
        val aliases=(0..4).map { "https://current.test/alias$it.m3u8" }
        val master="#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"en\",DEFAULT=YES,URI=\"$audio\"\n"+
            aliases.joinToString("") { "#EXT-X-STREAM-INF:BANDWIDTH=100000,RESOLUTION=320x180,CODECS=\"avc1.4d400d,mp4a.40.2\",AUDIO=\"en\"\n$it\n" }
        val m=media(*(listOf(candidate(root,"hls"),candidate(audio,"hls"))+aliases.map { candidate(it,"hls") }).toTypedArray()).put("width",320).put("height",180)
        val reads=mutableListOf<Pair<URI,Map<String,String>>>()
        assertNull(resolver(mapOf(root to master.toByteArray()),reads).resolveRootedCurrentHls(page,m,URI(root)))
        assertEquals(listOf(URI(root)),reads.map { it.first })
    }

    @Test fun rootedCurrentHlsRequiresTheObservedVideoAndAudioWithoutFetchingAnotherPlayer() {
        val root="https://current.test/root.m3u8?selection=exact";val video="https://current.test/video";val audio="https://current.test/audio"
        val advert="https://another-player.test/master.m3u8"
        val master="#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"en\",DEFAULT=YES,URI=\"audio\"\n"+
            "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"en\",DEFAULT=NO,URI=\"other-audio\"\n"+
            "#EXT-X-STREAM-INF:BANDWIDTH=1000000,RESOLUTION=1920x1080,CODECS=\"avc1.640028,mp4a.40.2\",AUDIO=\"en\"\nvideo\n"
        val vod="#EXTM3U\n#EXTINF:10,\nsegment.ts\n#EXT-X-ENDLIST\n"
        val data=mapOf(root to master.toByteArray(),video to vod.toByteArray(),audio to vod.toByteArray())
        val m=media(candidate(root,"hls",JSONObject().put("Authorization","root-only")),candidate(video,"hls"),
            candidate(audio,"hls",JSONObject().put("Authorization","audio-only")),candidate(advert,"hls"))
        val reads=mutableListOf<Pair<URI,Map<String,String>>>()
        val selected=WebVideoFormats.select(page,resolver(data,reads).resolveRootedCurrentHls(page,m,URI(root))!!){true}
        assertEquals(video,selected.video.url.toString());assertEquals(audio,selected.audio!!.url.toString())
        assertFalse(reads.any{it.first.toString()==advert});assertEquals("audio-only",reads.first{it.first.toString()==audio}.second["authorization"])
        assertFalse(reads.first{it.first.toString()==video}.second.containsKey("authorization"))
        assertNull(resolver(data).resolveRootedCurrentHls(page,m,URI(root+"&changed=1")))
        assertNull(resolver(data).resolveRootedCurrentHls(page,media(candidate(root,"hls"),candidate(video,"hls")),URI(root)))
        assertNull(resolver(data).resolveRootedCurrentHls(page,media(candidate(root,"hls"),candidate(video,"hls"),candidate(audio,"hls"),candidate("https://current.test/other-audio","hls")),URI(root)))
        assertNull(resolver(data).resolveRootedCurrentHls(page,JSONObject(m.toString()).put("protected",true),URI(root)))
        val document="https://www.ted.com/talks/current_talk";val tedPage=WebVideoPage.parse(document)
        val ted=JSONObject(m.toString()).put("frame",document).put("blob",true).put("ted_source","blob:https://www.ted.com/owned")
            .put("capture_identity","selected").put("ted_enabled",true).put("ted_ready",true)
            .put("ted",JSONObject().put("id","current_talk").put("talk_id","86532").put("player_id","416668").put("page",document)
                .put("root",root).put("revision","a1").put("width",1920).put("height",1080).put("duration",10).put("expected_duration",10))
        assertTrue(WebVideoTedCapture.keeps(tedPage,ted,ted,selected.video))
        val changed=JSONObject(ted.toString());changed.getJSONArray("network").put(candidate("https://current.test/other-audio","hls"))
        assertFalse(WebVideoTedCapture.keeps(tedPage,ted,changed,selected.video))
        val id="rrn:content:films:f9d7a128-fd11-4e0c-9049-77de0f9515bd"
        val fullPage="https://www.redbull.tv/en/page/$id/anytime"
        val redbull=JSONObject(m.toString()).put("frame",fullPage).put("blob",true).put("redbull_source","blob:https://www.redbull.tv/current")
            .put("capture_identity","selected").put("redbull_enabled",true).put("redbull_ready",true)
            .put("redbull",JSONObject().put("id",id).put("page",fullPage).put("root",root).put("revision","a1")
                .put("width",1920).put("height",1080).put("duration",10).put("expected_duration",10))
        val redPage=WebVideoRedBullCapture.page(fullPage,redbull)!!
        assertNotNull(WebVideoRedBullCapture.resolve(redPage,redbull,resolver(data)))
        assertTrue(WebVideoRedBullCapture.keeps(redPage,redbull,redbull,selected.video))
        val redChanged=JSONObject(redbull.toString());redChanged.put("redbull_source","blob:https://www.redbull.tv/replaced")
        assertFalse(WebVideoRedBullCapture.keeps(redPage,redbull,redChanged,selected.video))
        redChanged.put("protected",true);assertNull(WebVideoRedBullCapture.resolve(redPage,redChanged,resolver(data)))
    }
    @Test fun dailymotionKeepsTheTrustedParentAndHostedFrameWithTheirCurrentHlsPair() {
        val owner="https://www.dailymotion.com/video/x5kesuj";val frame="https://geo.dailymotion.com/player/official.html#settings=opaque"
        val root="https://hosted.test/root.m3u8?selection=exact";val video="https://video.related.test/current";val audio="https://audio.related.test/current"
        val advert="https://advert.test/master.m3u8"
        val master="#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"en\",DEFAULT=YES,URI=\"$audio\"\n"+
            "#EXT-X-STREAM-INF:BANDWIDTH=1000000,RESOLUTION=1920x1080,CODECS=\"avc1.640028,mp4a.40.2\",AUDIO=\"en\"\n$video\n"
        val vod="#EXTM3U\n#EXTINF:10,\nsegment.ts\n#EXT-X-ENDLIST\n"
        val resources=mapOf(root to master.toByteArray(),video to vod.toByteArray(),audio to vod.toByteArray())
        val m=media(candidate(root,"hls",JSONObject().put("Authorization","root-only")),candidate(video,"hls"),
            candidate(audio,"hls",JSONObject().put("Authorization","audio-only")),candidate(advert,"hls"))
            .put("frame",frame).put("blob",true).put("capture_identity","selected").put("dailymotion_owner",owner)
            .put("dailymotion_enabled",true).put("dailymotion_ready",true).put("dailymotion_source","blob:https://geo.dailymotion.com/current")
            .put("dailymotion",JSONObject().put("id","x5kesuj").put("page",owner).put("frame",frame).put("root",root).put("revision","a1")
                .put("width",1920).put("height",1080).put("duration",10).put("expected_duration",10)
                .put("manifests",JSONArray().put(JSONObject().put("url",root).put("body",master).put("request_id","original-0"))
                    .put(JSONObject().put("url",video).put("body",vod).put("request_id","original-1"))
                    .put(JSONObject().put("url",audio).put("body",vod).put("request_id","original-2"))))
        for(i in 0 until m.getJSONArray("network").length())m.getJSONArray("network").getJSONObject(i).put("request_id","original-$i")
        val page=WebVideoDailymotionCapture.page(owner,m)!!;val reads=mutableListOf<Pair<URI,Map<String,String>>>()
        val info=WebVideoDailymotionCapture.resolve(page,m,resolver(resources,reads))!!
        val selected=WebVideoFormats.select(page,info){true}
        assertEquals(video,selected.video.url.toString());assertEquals(audio,selected.audio!!.url.toString())
        assertTrue(reads.isEmpty());assertEquals(vod,selected.video.browserManifest)
        assertFalse(selected.video.browserHeaders!!.forUrl(URI(video),emptyMap()).containsKey("authorization"))
        assertEquals("audio-only",selected.video.browserHeaders!!.forUrl(URI(audio),emptyMap())["authorization"])
        assertTrue(WebVideoDailymotionCapture.keeps(page,m,m,selected.video))
        val clientFragments=JSONObject(m.toString());val originals=clientFragments.getJSONObject("dailymotion").getJSONArray("manifests")
        originals.getJSONObject(0).put("body",master.replace("$video\n","$video#client-video\n").replace("URI=\"$audio\"","URI=\"$audio#client-audio\""))
        for(i in 1..2){
            val entry=originals.getJSONObject(i);val uri=entry.getString("url");val request=uri+"#client"
            entry.put("request_url",request).put("body",vod.replace("segment.ts","segment.ts#transport-marker"))
            clientFragments.getJSONArray("network").getJSONObject(i).put("request_url",request)
        }
        val fragmentReads=mutableListOf<Pair<URI,Map<String,String>>>()
        val fragmentInfo=WebVideoDailymotionCapture.resolve(page,clientFragments,resolver(resources,fragmentReads))!!
        assertTrue(fragmentReads.isEmpty());assertEquals(vod,WebVideoFormats.select(page,fragmentInfo){true}.video.browserManifest)
        val missingOwner=JSONObject(m.toString());missingOwner.remove("dailymotion_owner")
        assertNull(WebVideoDailymotionCapture.page(owner,missingOwner))
        for(change in listOf<(JSONObject)->Unit>(
            {it.put("dailymotion_owner","https://www.dailymotion.com/video/other")},{it.put("protected",true)},
            {it.put("frame",frame+"changed")},{it.put("dailymotion_source","blob:https://geo.dailymotion.com/replaced")},
            {it.getJSONArray("network").put(candidate("https://other.test/second.m3u8","hls"))}
        )){val changed=JSONObject(m.toString());change(changed);assertFalse(WebVideoDailymotionCapture.keeps(page,m,changed,selected.video))}
        val protected=JSONObject(m.toString());protected.getJSONObject("dailymotion").getJSONArray("manifests").getJSONObject(1)
            .put("body",vod.replace("#EXTINF:","#EXT-X-KEY:METHOD=SAMPLE-AES-CTR,URI=\"key\"\n#EXTINF:"))
        assertNull(WebVideoDailymotionCapture.resolve(page,protected,resolver(resources)))
    }
    @Test fun youkuUsesTheDeclaredObservedHlsAndRejectsAdsProtectionAndWrongRepresentations() {
        val root="https://new-cdn.test/current/list.m3u8?signature=exact"
        val init="https://new-cdn.test/current/init.mp4"
        val other="https://ad-cdn.test/large.mp4"
        val document="https://v.youku.com/v_show/id_XOTUxMzg4NDMy.html"
        val body="#EXTM3U\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:10,\nchunk.m4s\n#EXT-X-ENDLIST\n"
        val m=media(candidate(other),candidate(root,"hls",JSONObject().put("Authorization","root-only")))
            .put("frame",document).put("blob",true).put("youku_enabled",true).put("youku_ready",true).put("capture_identity","chosen")
            .put("youku",JSONObject().put("id","XOTUxMzg4NDMy").put("page",document).put("revision","a1").put("declared_drm","default")
                .put("width",1920).put("height",1080).put("duration",10.0).put("expected_duration",10.0).put("manifests",JSONArray().put(root))
                .put("declarations",JSONArray().put(JSONObject().put("url",root.replace("https:","http:")).put("width",1920).put("height",1080).put("duration",10.0))))
        val p=WebVideoYoukuCapture.page(document,m)!!
        val reads=mutableListOf<Pair<URI,Map<String,String>>>()
        val data=mapOf(root to body.toByteArray(),init to mp4())
        val info=WebVideoYoukuCapture.resolve(p,m,resolver(data,reads))!!
        val selected=WebVideoFormats.select(p,info){true}
        assertEquals(root,selected.video.url.toString());assertEquals(listOf(URI(root),URI(init)),reads.map{it.first})
        assertEquals("root-only",reads.first().second["authorization"]);assertFalse(reads.last().second.containsKey("authorization"))
        assertTrue(WebVideoYoukuCapture.keeps(p,m,m,selected.video))
        for(bad in listOf(mp4(width=1280,height=720),mp4(audio=false),mp4(protected=true)))
            assertNull(WebVideoYoukuCapture.resolve(p,m,resolver(data+(init to bad))))
        assertNull(WebVideoYoukuCapture.resolve(p,m,resolver(data+(root to body.replace("#EXTINF", "#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"key\"\n#EXTINF").toByteArray()))))
        val changed=JSONObject(m.toString());changed.getJSONObject("youku").put("revision","b2")
        assertFalse(WebVideoYoukuCapture.keeps(p,m,changed,selected.video))
    }
    @Test fun inlineHlsKeepsObservedBodyAndPerSegmentHeadersWithoutFetchingTheRoot() {
        val base = URI("https://new-cdn.test/play/current.m3u8?decision=synthetic")
        val init = "https://new-cdn.test/play/init.mp4"
        val chunk = "https://new-cdn.test/play/chunk.m4s"
        val body = "#EXTM3U\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:10,\nchunk.m4s\n#EXT-X-ENDLIST\n"
        val reads = mutableListOf<Pair<URI,Map<String,String>>>()
        val input = media(candidate(init,"segment",JSONObject().put("Cookie","init=only")),
            candidate(chunk,"segment",JSONObject().put("Authorization","chunk-only")))
        val capture = resolver(mapOf(init to mp4()),reads)
        val info = capture.resolveObservedHls(page,input,base,body)!!
        val selected = WebVideoFormats.select(page,info){true}
        assertEquals(listOf(URI(init)),reads.map { it.first })
        assertEquals("init=only",reads.single().second["cookie"])
        assertEquals(body,selected.video.browserManifest)
        assertEquals("chunk-only",selected.video.browserHeaders!!.forUrl(URI(chunk),emptyMap())["authorization"])
        assertFalse(selected.publicJson().toString().contains("decision="))
        assertNull(resolver(mapOf(init to mp4())).resolveObservedHls(page,media(),base,body))
        assertNull(resolver(mapOf(init to mp4())).resolveObservedHls(page,input,base,body.replace("#EXT-X-ENDLIST","")))
        assertNull(resolver(mapOf(init to mp4())).resolveObservedHls(page,input,base,body.replace("EXTINF:10","EXTINF:5")))
    }
    @Test fun weiboCardUsesOnlyItsObservedMuxedFileAndItsOwnCredentials() {
        val source="https://arbitrary-cdn.test/chosen.mp4?signature=synthetic"
        val other="https://arbitrary-cdn.test/neighbour.mp4"
        val document="https://weibo.com/newlogin"
        val canonical="https://weibo.com/7827771738/N4xlMvjhI"
        val item=media(candidate(other),candidate(source,headers=JSONObject().put("Authorization","only-this-request")),direct=source)
            .put("frame",document).put("weibo_enabled",true).put("weibo_ready",true).put("capture_identity","selected")
            .put("weibo",JSONObject().put("page",canonical).put("id","N4xlMvjhI").put("source",source))
        val page=WebVideoWeiboCapture.page(document,item)!!
        assertEquals(canonical,page.url)
        val reads=mutableListOf<Pair<URI,Map<String,String>>>()
        val info=WebVideoWeiboCapture.resolve(page,item,resolver(mapOf(source to mp4()),reads))!!
        assertEquals(listOf(URI(source)),reads.map{it.first})
        assertEquals("only-this-request",reads.single().second["authorization"])
        assertEquals(source,WebVideoFormats.select(page,info){true}.video.url.toString())
        for (data in listOf(mp4(audio=false),mp4(width=1280,height=720),mp4(duration=30),mp4(protected=true)))
            assertNull(WebVideoWeiboCapture.resolve(page,item,resolver(mapOf(source to data))))
        assertNull(WebVideoWeiboCapture.page(document,JSONObject(item.toString()).put("capture_identity","")))
        assertNull(WebVideoWeiboCapture.candidate(page,JSONObject(item.toString()).put("source",other)))
        assertNull(WebVideoWeiboCapture.page("https://weibo.com/another-document",item))
    }
    private val page = WebVideoPage("browser", "fixture", "webvideo://capture/fixture")
    private fun box(type: String, data: ByteArray) = ByteBuffer.allocate(8 + data.size).putInt(data.size + 8).put(type.toByteArray()).put(data).array()
    private fun mp4(video: Boolean = true, audio: Boolean = true, duration: Int = 10, protected: Boolean = false, width: Int = 1920, height: Int = 1080, aspect: Pair<Int,Int>?=null, avcConfig: ByteArray?=null,durationMs: Int=duration*1000): ByteArray {
        fun track(kind: String): ByteArray {
            val video = kind == "vide"
            val sample = if (video) ByteArray(78).also { ByteBuffer.wrap(it).putShort(24, width.toShort()).putShort(26, height.toShort()) } + box("avcC", avcConfig ?: byteArrayOf(1, 100, 0, 40)) +
                (aspect?.let {box("pasp",ByteBuffer.allocate(8).putInt(it.first).putInt(it.second).array())} ?: byteArrayOf()) else ByteArray(28)
            val stsd = box("stsd", ByteBuffer.allocate(8).putInt(0).putInt(1).array() + box(if (protected) if (video) "encv" else "enca" else if (video) "avc1" else "mp4a", sample))
            val mdhd = ByteBuffer.allocate(24).putInt(12, 1000).putInt(16, durationMs).array()
            val hdlr = ByteArray(24).also { kind.toByteArray().copyInto(it, 8) }
            return box("trak", box("mdia", box("mdhd", mdhd) + box("hdlr", hdlr) + box("minf", box("stbl", stsd))))
        }
        return box("ftyp", "isom0000isom".toByteArray()) + box("moov", (if (video) track("vide") else byteArrayOf()) + (if (audio) track("soun") else byteArrayOf())) + box("mdat", ByteArray(16))
    }
    private fun candidate(url: String, kind: String = "file", headers: JSONObject = JSONObject(), cookies: JSONArray = JSONArray()) =
        JSONObject().put("url", url).put("kind", kind).put("headers", headers).put("cookies", cookies)
    private fun media(vararg items: JSONObject, direct: String = "") = JSONObject().put("frame", "https://page.test/watch")
        .put("source", direct).put("duration", 10).put("width", 1920).put("height", 1080).put("title", "Fixture")
        .put("network", JSONArray(items.toList())).put("id", "1").put("network_epoch", 1).put("network_enabled", true)
    private fun resolver(data: Map<String, ByteArray>, observed: MutableList<Pair<URI, Map<String, String>>> = arrayListOf()) = WebVideoNetworkCapture({ uri, headers, _ ->
        observed.add(uri to headers); uri to (data[uri.toString()] ?: error("Unexpected request"))
    }, { it.height <= 1080 })

    @Test fun verifiedMuxedFileUsesActualHeadersAndBypassesExtractorAndCookieExport() {
        val url = "https://cdn.test/movie?token=private"
        val observed = arrayListOf<Pair<URI, Map<String, String>>>()
        val capture = resolver(mapOf(url to mp4()), observed)
        var extractions = 0
        val (_, d) = WebVideoResolution.select(page, { capture.resolve(page, media(candidate(url, headers = JSONObject().put("Cookie", "session=synthetic").put("Range", "bytes=99-100")))) },
            { extractions++; error("Extractor must stay cold") }, { true })
        assertEquals(0, extractions); assertEquals("avc1.640028", d.video.videoCodec); assertTrue(d.video.hasAudio)
        assertEquals("session=synthetic", observed.single().second["cookie"]); assertFalse(observed.single().second.containsKey("range"))
        assertFalse(d.publicJson().toString().contains("private")); assertFalse(d.toString().contains("cdn.test"))
    }
    @Test fun incompleteOrUnsupportedCaptureFallsBackExactlyOnceAndCancellationDoesNotExtract() {
        var extracts = 0
        val url = "https://cdn.test/movie.mp4"; val m = media(candidate(url))
        val fallback = WebVideoBrowserCapture.formats(media(direct = url))!!
        for (capture in listOf<() -> JSONObject?>({ null }, { error("invalid container") }, { JSONObject().put("formats", JSONArray()) })) {
            WebVideoResolution.select(page, capture, { extracts++; fallback }, { true })
        }
        assertEquals(3, extracts)
        assertThrows(Exception::class.java) { WebVideoResolution.select(page, { null }, { extracts++; fallback }, { true }, { error("cancelled") }) }
        assertEquals(3, extracts)
        assertNull(resolver(mapOf(url to mp4(duration = 0))).resolve(page, m))
        assertNull(resolver(mapOf(url to mp4(protected = true))).resolve(page, m))
        assertNull(resolver(mapOf(url to mp4())).resolve(page, JSONObject(m.toString()).put("protected", true)))
    }
    @Test fun observedMemberQualityIsNotReplacedByAnExtractorPreviewOrTheOld1080Cap() {
        val url = "https://cdn.test/member.mp4?token=synthetic"
        val m = media(candidate(url, headers = JSONObject().put("Authorization", "Bearer member"))).put("width", 3840).put("height", 2160)
        var extracted = false
        val capture = WebVideoNetworkCapture({ uri, headers, _ ->
            assertEquals("Bearer member", headers["authorization"]); uri to mp4(width = 3840, height = 2160)
        }, { it.height <= 2160 })
        val (_, descriptor) = WebVideoResolution.select(page, { capture.resolve(page, m) }, { extracted = true; error("Public preview must not replace member quality") }, { it.height <= 2160 })
        assertFalse(extracted); assertEquals(3840, descriptor.video.width); assertEquals(2160, descriptor.video.height)
        assertTrue(WebVideoNetworkCapture.keepsQuality(descriptor.video, m))
        val preview = WebVideoTrack("preview", URI("https://cdn.test/preview.mp4"), emptyMap(), "mp4", "avc1", "mp4a", 1920, 1080, 30.0)
        assertFalse(WebVideoNetworkCapture.keepsQuality(preview, m))
    }
    @Test fun pairsOnlyMatchingCompleteBilibiliRepresentationsAndPreservesPerTrackHeaders() {
        val v = "https://upos-a.bilivideo.com/upgcxcode/12/34/1234/1234-1-100026.m4s?token=video"
        val a = "https://upos-b.bilivideo.com/upgcxcode/12/34/1234/1234-1-30280.m4s?token=audio"
        val m = media(candidate(v, headers = JSONObject().put("Authorization", "video")), candidate(a, headers = JSONObject().put("Authorization", "audio")))
        val data = mapOf(v to mp4(audio = false), a to mp4(video = false))
        val d = WebVideoFormats.select(page, resolver(data).resolve(page, m)!!) { true }
        assertEquals("video", d.video.headers["authorization"]); assertEquals("audio", d.audio!!.headers["authorization"])
        val other = a.replace("1234-1-", "9999-1-")
        assertNull(resolver(mapOf(v to mp4(audio = false), other to mp4(video = false))).resolve(page, media(candidate(v), candidate(other))))
        assertNull(resolver(mapOf(v to mp4(audio = false), a to mp4(video = false, duration = 30))).resolve(page, m))
    }
    @Test fun rejectsUnrelatedAdsAndDoesNotPairByHostOrTimingAlone() {
        val v = "https://cdn.test/video.mp4"; val a = "https://cdn.test/audio.mp4"
        assertNull(resolver(mapOf(v to mp4(audio = false), a to mp4(video = false))).resolve(page, media(candidate(v), candidate(a))))
        assertNull(resolver(mapOf(v to mp4(), a to mp4())).resolve(page, media(candidate(v), candidate(a))))
        val chosen = resolver(mapOf(v to mp4(), a to mp4())).resolve(page, media(candidate(v), candidate(a), direct = v))!!
        assertEquals(v, chosen.getJSONArray("formats").getJSONObject(0).getString("url"))
    }
    @Test fun youtubeOnlyRemovesUnsignedRangeAndRejectsLiveSequenceRequests() {
        val url = "https://r1.googlevideo.com/videoplayback?id=abcdefgh.1&source=youtube&sparams=id,source,expire&expire=999&range=0-999&sig=opaque"
        assertEquals(url.replace("&range=0-999", ""), WebVideoNetworkCapture.wholeFile(URI(url)).toString())
        assertNull(WebVideoNetworkCapture.wholeFile(URI(url.replace("sparams=id,source,expire", "sparams=id,source,expire,range"))))
        assertNull(WebVideoNetworkCapture.wholeFile(URI(url + "&sq=10")))
        assertNull(WebVideoNetworkCapture.wholeFile(URI(url + "&live=1")))
        val signed = URI("https://cdn.test/file?range=1-20&signature=private")
        assertEquals(signed, WebVideoNetworkCapture.wholeFile(signed))
    }
    @Test fun masterPlaylistSelectsCompatibleVideoWithItsOwnAudioAndDetectsLiveOrDrmBeforeHandoff() {
        val root = "https://cdn.test/master"; val video = "https://cdn.test/video"; val audio = "https://cdn.test/audio"
        val master = "#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"en\",DEFAULT=YES,URI=\"audio\"\n" +
            "#EXT-X-STREAM-INF:BANDWIDTH=1000000,RESOLUTION=1920x1080,CODECS=\"avc1.640028,mp4a.40.2\",AUDIO=\"en\"\nvideo\n" +
            "#EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=3840x2160,CODECS=\"avc1.640033,mp4a.40.2\",AUDIO=\"en\"\nlarge\n"
        val vod = "#EXTM3U\n#EXT-X-TARGETDURATION:10\n#EXTINF:10,\nsegment.ts\n#EXT-X-ENDLIST\n"
        val data = mapOf(root to master.toByteArray(), video to vod.toByteArray(), audio to vod.toByteArray())
        val m = media(candidate(root, "hls"), candidate(video, "hls"), candidate(audio, "hls"))
        val d = WebVideoFormats.select(page, resolver(data).resolve(page, m)!!) { true }
        assertEquals(video, d.video.url.toString()); assertEquals(audio, d.audio!!.url.toString()); assertEquals("hls", d.audio.transport)
        assertNull(resolver(data + (video to vod.replace("#EXT-X-ENDLIST", "").toByteArray())).resolve(page, m))
        assertNull(resolver(data + (video to vod.replace("#EXTINF", "#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"key\"\n#EXTINF").toByteArray())).resolve(page, m))
    }
    @Test fun extensionlessHlsLeafMustContainBothAudioAndVideo() {
        val root = "https://cdn.test/list"; val init = "https://cdn.test/init.mp4"
        val playlist = "#EXTM3U\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:10,\nsegment.m4s\n#EXT-X-ENDLIST\n".toByteArray()
        val m = media(candidate(root, "hls"))
        assertNotNull(resolver(mapOf(root to playlist, init to mp4())).resolve(page, m))
        assertNull(resolver(mapOf(root to playlist, init to mp4(audio = false))).resolve(page, m))
    }
    @Test fun staticDashBaseUrlPairsValidatedWholeTracksAndRejectsProtectedOrSegmentedManifests() {
        val url = "https://cdn.test/manifest"
        val xml = """<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" mediaPresentationDuration="PT10S"><Period><AdaptationSet><Representation id="v"><BaseURL>v.mp4</BaseURL><SegmentBase indexRange="0-100"/></Representation></AdaptationSet><AdaptationSet><Representation id="a"><BaseURL>a.m4a</BaseURL></Representation></AdaptationSet></Period></MPD>"""
        val data = mapOf(url to xml.toByteArray(), "https://cdn.test/v.mp4" to mp4(audio = false), "https://cdn.test/a.m4a" to mp4(video = false))
        val m = media(candidate(url, "dash"))
        assertNotNull(WebVideoFormats.select(page, resolver(data).resolve(page, m)!!) { true }.audio)
        for (bad in listOf(xml.replace("type=\"static\"", "type=\"dynamic\""), xml.replace("<Period>", "<Period><ContentProtection/>"),
            xml.replace("<Period>", "<Period><SegmentTemplate/>"), "<!DOCTYPE MPD [<!ENTITY ext SYSTEM 'file:///private'>]>$xml"))
            assertNull(resolver(data + (url to bad.toByteArray())).resolve(page, m))
    }
    @Test fun cookieScopeAndExactRequestHeadersAreRetainedWithoutLeakingToOtherResources() {
        val cookie = JSONObject().put("name", "session").put("value", "synthetic").put("domain", "cdn.test").put("hostOnly", true).put("path", "/media").put("secure", true)
        val scope = WebVideoRequestHeaders(mapOf("https://cdn.test/media/root" to mapOf("authorization" to "exact")), JSONArray().put(cookie))
        val fallback = mapOf("cookie" to "unscoped=private", "authorization" to "private", "x-token" to "private", "user-agent" to "fixture")
        assertEquals("exact", scope.forUrl(URI("https://cdn.test/media/root"), fallback)["authorization"])
        assertEquals("session=synthetic", scope.forUrl(URI("https://cdn.test/media/segment"), fallback)["cookie"])
        for (url in listOf("https://cdn.test/other", "https://cdn.test/media-extra", "http://cdn.test/media/a", "https://other.test/media/a")) {
            val headers = scope.forUrl(URI(url), fallback)
            assertEquals(mapOf("user-agent" to "fixture"), headers)
        }
    }
    @Test fun genericIdentityDoesNotPublishPageOrResourceTokens() {
        val m = media(candidate("https://cdn.test/file.mp4?token=private"))
        val p = WebVideoNetworkCapture.page("https://server.test:8920/path?access_token=private#secret", m)!!
        assertTrue(p.url.startsWith("webvideo://capture/")); assertFalse(p.toString().contains("private")); assertFalse(p.toString().contains("server.test"))
        assertNotEquals(p, WebVideoNetworkCapture.page("https://server.test:8920/path?access_token=private#secret", JSONObject(m.toString()).put("network_epoch", 2)))
        assertNull(WebVideoNetworkCapture.page("https://page.test/watch", JSONObject(m.toString()).put("network_enabled", false)))
    }
    @Test fun currentHlsChoosesTheActuallyDecodedLeafAcrossRelatedCdnHosts() {
        val roots=listOf("https://a.cdn.test/low", "https://b.other.test/current", "https://c.hosted.test/high")
        val sizes=listOf(320 to 180,704 to 396,1280 to 720)
        val data=HashMap<String,ByteArray>()
        roots.forEachIndexed { index,root ->
            data[root]="#EXTM3U\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:10,\nchunk.m4s\n#EXT-X-ENDLIST\n".toByteArray()
            data[URI(root).resolve("init.mp4").toString()]=mp4(width=sizes[index].first,height=sizes[index].second)
        }
        val m=media(*roots.map { candidate(it,"hls") }.toTypedArray()).put("width",704).put("height",396)
        assertNull(resolver(data).resolve(page,m)) // Generic ambiguity behavior is unchanged.
        val selected=WebVideoFormats.select(page,resolver(data).resolveCurrent(page,m)!!){true}
        assertEquals(roots[1],selected.video.url.toString());assertEquals(704,selected.video.width)
        data[URI(roots[0]).resolve("init.mp4").toString()]=mp4(width=704,height=396)
        assertNull(resolver(data).resolveCurrent(page,m))
    }
    @Test fun currentHlsRequiresWholeDurationRealDimensionsAndBothTracks() {
        val root="https://cdn.test/vod"
        val vod="#EXTM3U\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:10,\nchunk.m4s\n#EXT-X-ENDLIST\n"
        val m=media(candidate(root,"hls"))
        for (bad in listOf(mp4(width=0,height=0),mp4(audio=false))) {
            assertNull(resolver(mapOf(root to vod.toByteArray(),"https://cdn.test/init.mp4" to bad)).resolveCurrent(page,m))
        }
        val valid=mapOf(root to vod.toByteArray(),"https://cdn.test/init.mp4" to mp4())
        assertNotNull(resolver(valid).resolveCurrent(page,m))
        assertNull(resolver(valid+(root to vod.replace("EXTINF:10","EXTINF:5").toByteArray())).resolveCurrent(page,m))
        assertNull(resolver(valid+(root to vod.replace("#EXT-X-ENDLIST","").toByteArray())).resolveCurrent(page,m))
        assertNull(resolver(valid).resolveCurrent(page,JSONObject(m.toString()).put("protected",true)))
    }
    @Test fun realHostContainersAreInspectedWhenFixtureDirectoryIsProvided() {
        val root = System.getenv("WEB_VIDEO_NETWORK_FIXTURES")
        org.junit.Assume.assumeTrue(root != null)
        for (name in listOf("muxed.mp4", "video.mp4", "audio.m4a", "muxed.webm", "hevc.mp4")) {
            val info = WebVideoContainer.parse(java.io.File(root, name).readBytes()) ?: error("Cannot inspect $name")
            assertEquals(name != "audio.m4a", info.video != "none"); assertEquals(name != "video.mp4", info.audio != "none")
            assertTrue(info.duration in 3.9..4.1)
        }
        assertNull(WebVideoContainer.parse(java.io.File(root, "hevc10.mp4").readBytes()))
    }
    @Test fun realCapturedFileAndHlsDecodeAndSeekThroughProductionLeasesWithScopedSession() {
        val root = System.getenv("WEB_VIDEO_NETWORK_FIXTURES"); val ffmpeg = System.getenv("WEB_VIDEO_FFMPEG")
        org.junit.Assume.assumeTrue(root != null && ffmpeg != null)
        requireNotNull(root); requireNotNull(ffmpeg)
        org.vrpassthroughplayer.plugin.MediaServerClientTest.Fixture { request, headers, _ ->
            assertEquals("session=synthetic", headers["cookie"])
            val name = URI(request.split(' ')[1]).path.substringAfterLast('/')
            val file = java.io.File(root, name); require(file.parentFile == java.io.File(root))
            val data = file.readBytes()
            val range = headers["range"]?.let { LocalStreamServer.parseRange(it, data.size.toLong()) }
            if (range == null) org.vrpassthroughplayer.plugin.MediaServerClientTest.Reply(200, body = data)
            else org.vrpassthroughplayer.plugin.MediaServerClientTest.Reply(206,
                "Content-Range: bytes ${range.first}-${range.second}/${data.size}\r\n", data.copyOfRange(range.first.toInt(), range.second.toInt() + 1))
        }.use { origin ->
            for (name in listOf("muxed.mp4", "sample-network.m3u8")) {
                val url = "${origin.url}/media/$name"
                val cookies = JSONArray().put(JSONObject().put("name", "session").put("value", "synthetic")
                    .put("domain", URI(origin.url).host).put("path", "/media").put("hostOnly", true))
                val m = media(candidate(url, if (name.endsWith("m3u8")) "hls" else "file", JSONObject().put("Cookie", "session=synthetic"), cookies)).put("duration", 4)
                val capture = WebVideoNetworkCapture({ uri, headers, prefix ->
                    RemoteMediaHttp().use { http ->
                        val connection = http.open(uri, if (prefix) "bytes=0-2097151" else "", headers)
                        try { connection.url.toURI() to connection.inputStream.use { it.readBytes() } } finally { http.release(connection) }
                    }
                }, { true })
                val descriptor = WebVideoFormats.select(page, capture.resolve(page, m)!!) { true }
                LocalStreamServer().use { local -> WebVideoStreams { local }.use { streams ->
                    val leased = streams.prepare(descriptor)
                    val log = java.io.File(root, "network-decode-$name.log")
                    val process = ProcessBuilder(ffmpeg, "-v", "error", "-ss", "2", "-i", leased, "-t", "1", "-map", "0:v", "-map", "0:a", "-f", "null", "-")
                        .redirectErrorStream(true).redirectOutput(log).start()
                    try {
                        assertTrue(process.waitFor(30, java.util.concurrent.TimeUnit.SECONDS))
                        assertEquals(log.readText(), 0, process.exitValue()); assertTrue(log.readText().isBlank())
                    } finally { process.destroyForcibly() }
                    streams.release(leased); assertFalse(local.hasSource(leased))
                } }
            }
        }
    }
}
