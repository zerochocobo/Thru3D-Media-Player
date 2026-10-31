package org.vrpassthroughplayer.plugin
import org.junit.Assert.*
import org.junit.Test
import org.json.JSONObject

class ListeningPolicyTest {
    @Test fun splitWebAudioUsesItsOwnInputStreamAndClock() {
        val video="http://127.0.0.1:32123/video.mp4"
        val audio="http://127.0.0.1:32123/audio.webm"
        val metadata=JSONObject().put("id",1).put("stream_index",0).put("external",true).put("filename",audio)
        val selected=ListeningPolicy.audioInput(video,metadata,audio,7.5)!!
        assertEquals(audio,selected.path);assertNotEquals(video,selected.path)
        assertEquals(0,selected.stream);assertTrue(selected.external);assertTrue(selected.origin.isNaN())
        val embedded=ListeningPolicy.audioInput(video,metadata.put("external",false),audio,7.5)!!
        assertEquals(video,embedded.path);assertEquals(0,embedded.cacheTrack)
        assertEquals(7.5,embedded.origin,0.0);assertFalse(embedded.external)
        assertNotEquals(embedded.cacheTrack,selected.cacheTrack)
    }
    @Test fun splitAudioCacheIdentitySurvivesLeaseRenewalButSeparatesStreams() {
        fun selected(path: String,stream: Int)=ListeningPolicy.audioInput("video",JSONObject()
            .put("external",true).put("filename",path).put("stream_index",stream),path,0.0)!!
        val first=selected("http://127.0.0.1:1234/first/audio.m4a",0)
        val renewed=selected("http://127.0.0.1:4321/new/audio.m4a",0)
        assertEquals(first.cacheTrack,renewed.cacheTrack)
        assertNotEquals(first.cacheTrack,selected(first.path,1).cacheTrack)
        fun key(track: Int)=ListeningCueCache.key("a".repeat(64),30.0,"en","model",track)
        assertEquals(key(first.cacheTrack),key(renewed.cacheTrack))
        assertNotEquals(key(0),key(first.cacheTrack))
    }
    @Test fun unownedExternalOrInvalidStreamsRemainUnsupported() {
        val audio="http://127.0.0.1:1234/audio.m4a"
        val metadata=JSONObject().put("external",true).put("filename",audio).put("stream_index",0)
        assertNull(ListeningPolicy.audioInput("video",metadata,"",0.0))
        assertNull(ListeningPolicy.audioInput("video",metadata,audio+"?other",0.0))
        assertNull(ListeningPolicy.audioInput("video",metadata.put("filename","https://cdn.test/private"),audio,0.0))
        metadata.put("filename",audio)
        for(stream in listOf(-1,Int.MAX_VALUE))assertNull(ListeningPolicy.audioInput("video",metadata.put("stream_index",stream),audio,0.0))
        metadata.remove("stream_index")
        assertNull(ListeningPolicy.audioInput("video",metadata,audio,0.0))
    }
    @Test fun progressUsesActualVerifiedBytesAndAudibleLookahead() {
        assertEquals(-1,ListeningPolicy.percent(0.0,0.0))
        assertEquals(25,ListeningPolicy.percent(3.0,12.0))
        assertEquals(100,ListeningPolicy.percent(13.0,12.0))
        assertEquals(0,ListeningPolicy.percent(-1.0,12.0))
    }
    @Test fun hallucinationCleanupKeepsNormalJapaneseDialogue() {
        fun accepted(text: String)=ListeningPolicy.accept(ListeningPolicy.Cue(1.0,5.0,text),"ja")
        assertFalse(accepted("……！？"))
        assertFalse(accepted("ありがとうございます。".repeat(4)))
        assertFalse(accepted("おやすみ".repeat(4)))
        assertTrue(accepted("はい、はい、はい、はい。"))
        assertTrue(accepted("ご視聴ありがとうございました。"))
        assertTrue(accepted("今日は駅で友達に会いました。"))
        assertTrue(accepted("いいえ、いいえ。私はそう思いません。"))
    }
    @Test fun configHasOnlyExplicitLanguagesAndBoundedLead() {
        for(language in listOf("zh","en","ja"))for(lead in listOf(8,12,20)) {
            val c=ListeningPolicy.Config.parse("""{"enabled":true,"language":"$language","lead":$lead,"target":""}""")
            assertEquals(language,c.language);assertFalse(c.translation)
        }
        for(value in listOf("""{"enabled":true,"language":"auto","lead":12}""","""{"enabled":true,"language":"ja","lead":12.5}""","""{"enabled":"yes","language":"ja","lead":12}"""))
            assertTrue(runCatching {ListeningPolicy.Config.parse(value)}.isFailure)
        assertFalse(ListeningPolicy.Config(true,"zh",12,"zh-Hans").translation)
        assertTrue(ListeningPolicy.Config(true,"ja",12,"zh-Hans").translation)
    }
    @Test fun deadlinesAreMediaTimesNotArrivalTimes() {
        val c=ListeningPolicy.Cue(4.0,6.0,"こんにちは")
        assertFalse(ListeningPolicy.visible(c,3.99));assertTrue(ListeningPolicy.visible(c,4.0));assertFalse(ListeningPolicy.visible(c,6.0))
        assertEquals(46.0,ListeningPolicy.horizon(10.0,3.0,12),0.0)
        assertEquals(22.0,ListeningPolicy.horizon(10.0,.5,12),0.0)
    }
    @Test fun malformedLateAndUnboundedCuesAreRejected() {
        assertNull(ListeningPolicy.Cue.parse(JSONObject("""{"start":2,"end":1,"text":"old"}""")))
        assertNull(ListeningPolicy.Cue.parse(JSONObject("""{"start":1,"end":90,"text":"long"}""")))
        val cues=(0..500).map {ListeningPolicy.Cue(it.toDouble(),it+1.0,"$it")}
        val keep=ListeningPolicy.retain(cues,100.0)
        assertEquals(64,keep.size);assertTrue(keep.all {it.end>99.75&&it.start<165})
    }
    @Test fun earlierSeekLandingCannotStopWorkBeforeStartupBufferIsReady() {
        // Real fast-seek regression: target clock 151.737 settles at 148.182.
        val anchor=151.737;val landed=148.182;val through=160.737
        assertTrue(through>=ListeningPolicy.horizon(landed,1.0,12))
        assertTrue(through<ListeningPolicy.horizon(anchor,1.0,12))
        assertTrue(through<ListeningPolicy.workHorizon(anchor,landed,true,1.0,12))
        assertEquals(ListeningPolicy.horizon(anchor,1.0,12),ListeningPolicy.workHorizon(anchor,landed,true,1.0,12),0.0)
        assertEquals(ListeningPolicy.horizon(landed,1.0,12),ListeningPolicy.workHorizon(anchor,landed,false,1.0,12),0.0)
    }
    @Test fun forwardSeekCannotReleasePreparationUsingTheOldPosition() {
        val anchor=258.173833;val landed=285.5853;val through=277.173833
        assertTrue(through>=ListeningPolicy.horizon(anchor,1.0,12))
        assertTrue(through<landed)
        val readyAt=ListeningPolicy.workHorizon(anchor,landed,true,1.0,12)
        assertFalse(through>=readyAt)
        assertEquals(landed+12,readyAt,0.0)
    }
    @Test fun recognitionBehindTheClockRestartsAtThePlaybackPosition() {
        // v7 on Quest: a +120 s drag anchored at the pre-seek clock; ASR then
        // transcribed 140 s nobody would see while showing 0 % for 30 s.
        assertTrue(ListeningPolicy.behind(320.0,426.2))
        assertFalse(ListeningPolicy.behind(300.0,304.0)) // ordinary catching up
        assertFalse(ListeningPolicy.behind(312.0,300.0)) // lookahead
    }
}
