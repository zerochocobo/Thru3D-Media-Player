package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test
import org.json.JSONArray

class NarrationPolicyTest {
    @Test fun onlyExplicitLanguageMetadataSelectsLanguage() {
        listOf("zh", "chi", "cmn", "zho", "zh-Hant", "zh_Hans_CN").forEach { assertEquals("zh", NarrationPolicy.language(it)) }
        listOf("en", "eng", "en-US").forEach { assertEquals("en", NarrationPolicy.language(it)) }
        listOf("", "und", "mul", "ja", "auto").forEach { assertEquals("", NarrationPolicy.language(it)) }
    }
    @Test fun voicesRemainSeparateForEachLanguageAndDefaultsAreFemale() {
        val defaults=NarrationPolicy.Config.parse("{}")
        assertEquals("Yuewen",defaults.voice("zh"));assertEquals("Ava",defaults.voice("en"))
        val chosen=NarrationPolicy.Config.parse("{\"zh_voice\":\"Junhao\",\"en_voice\":\"Adam\"}")
        assertEquals("Junhao",chosen.voice("zh"));assertEquals("Adam",chosen.voice("en"))
        listOf("{\"language\":\"und\"}","{\"zh_voice\":\"Ava\"}","{\"en_voice\":\"Yuewen\"}","{\"duck\":2}","{\"source_delay\":11}").forEach {
            assertTrue(runCatching { NarrationPolicy.Config.parse(it) }.isFailure)
        }
        assertEquals(1.5,NarrationPolicy.Config.parse("{\"source\":3,\"source_delay\":1.5}").sourceDelay!!,0.0)
    }
    @Test fun stylesAreNotReadButOriginalWordsAndUnicodeSurvive() {
        assertEquals("你好\n世界 & hello 🎬",NarrationPolicy.clean("{\\an8}<i>你好</i>\\N世界 &amp; hello 🎬"))
        assertEquals("二零二六年十月十七日，百分之十二点五，零零七",NarrationPolicy.normalize("2026年10月17日，12.5%，007","zh"))
        assertEquals("twelve point five percent, one hundred twenty three",NarrationPolicy.normalize("12.5%, 123","en"))
    }
    @Test fun repeatedAndCumulativeSubtitleEventsDoNotDoubleRead() {
        val cues=NarrationPolicy.cues(JSONArray("[{\"start\":1,\"end\":4,\"text\":\"Hello\"},{\"start\":1,\"end\":4,\"text\":\"Hello\"},{\"start\":1,\"end\":5,\"text\":\"Hello world\"}]"),"en")
        assertEquals(1,cues.size);assertEquals("Hello world",cues.single().text);assertEquals(5.0,cues.single().end,0.0)
    }
    @Test fun ordinaryTextAssTagsAndControlCharactersAreSafeOnAndroid() {
        assertEquals("plain subtitle",NarrationPolicy.clean("plain subtitle"))
        assertEquals("Before after",NarrationPolicy.clean("Before {\\an8}{\\i1}after{\\i0}"))
        assertEquals("first\nsecond\tthird",NarrationPolicy.clean("first\u0000\nsecond\tthird\u0007"))
        assertEquals("{unfinished",NarrationPolicy.clean("{unfinished"))
        assertEquals("unfinished}",NarrationPolicy.clean("unfinished}"))
    }
    @Test fun unicodeDigitsOutsideTheAsciiNormalizerArePreserved() {
        val text=NarrationPolicy.clean("١٢٣ ۱۲۳ １２３ 12.5%")
        assertEquals("١٢٣ ۱۲۳ 一百二十三 百分之十二点五",NarrationPolicy.normalize(text,"zh"))
        assertEquals("١٢٣ ۱۲۳ one hundred twenty three twelve point five percent",NarrationPolicy.normalize(text,"en"))
        assertEquals("١٢٣٤年",NarrationPolicy.normalize("١٢٣٤年","zh"))
    }
    @Test fun splittingLongTextKeepsTheWholeSubtitleDuckingWindow() {
        val raw=JSONArray().put(org.json.JSONObject().put("start",10).put("end",30).put("text","这是一段比较长的字幕。".repeat(20)))
        val cues=NarrationPolicy.cues(raw,"zh")
        assertTrue(cues.size>1);assertTrue(cues.all { it.text.length<=65&&it.windowStart==10.0&&it.windowEnd==30.0 })
        assertEquals(.25,NarrationPolicy.duck(15.0,listOf(cues.first()),.75,true),0.0)
        assertEquals(1.0,NarrationPolicy.duck(30.0,cues,.75,true),0.0)
        assertEquals(1.0,NarrationPolicy.duck(15.0,cues,.75,false),0.0)
    }
    @Test fun shortGapsStayDuckedButLongGapsAndPauseRestoreAudio() {
        val cues=listOf(NarrationPolicy.Cue(1.0,3.0,"a"),NarrationPolicy.Cue(3.2,4.0,"b"),NarrationPolicy.Cue(6.0,7.0,"c"))
        assertEquals(.25,NarrationPolicy.duck(3.1,cues,.75,true),0.0)
        assertEquals(1.0,NarrationPolicy.duck(5.0,cues,.75,true),0.0)
        assertEquals(1.0,NarrationPolicy.duck(2.0,cues,.75,false),0.0)
    }
    @Test fun adjacentSubtitleSpeechReservesPresentationTimeAndNeverExceedsSpeedLimit() {
        // The actual 8K failure: 6.72 seconds of PCM in a six-second cue.
        val fit=NarrationPolicy.playbackRate(6.72,6.0,.02,1.0)
        assertTrue(.02+6.72/fit+.20<6.0)
        assertEquals(1.0,NarrationPolicy.playbackRate(4.0,6.0,0.0,1.0),0.0)
        assertTrue(NarrationPolicy.playbackRate(6.72,6.0,.20,1.0)>fit)
        assertEquals(1.4,NarrationPolicy.playbackRate(20.0,.1,.4,1.0),0.0)
    }
    @Test fun generationCannotSpendTwentySecondsOfPcmOnASixSecondSubtitle() {
        assertEquals(100,NarrationPolicy.frameBudget(6.0))
        assertEquals(250,NarrationPolicy.frameBudget(60.0))
        // Every admitted complete generation must fit, including the observed
        // 98-frame long sentence that overran a six-second window at 1.3x.
        for(frames in 8..NarrationPolicy.frameBudget(6.0))for(preference in listOf(.8,1.0,1.3)) {
            val seconds=frames*.08
            val tempo=NarrationPolicy.playbackRate(seconds,6.0,0.0,preference)
            assertTrue(seconds/tempo<=5.75+.000001)
        }
    }
    @Test fun slowerPreferenceDoesNotPushSpeechPastTheSubtitleDeadline() {
        assertEquals(.8,NarrationPolicy.playbackRate(3.0,6.0,0.0,.8),0.0)
        val tempo=NarrationPolicy.playbackRate(5.0,6.0,0.0,.8)
        assertTrue(tempo>.8)
        assertEquals(5.75,5.0/tempo,.000001)
    }
    @Test fun coldSeekSkipsAnImminentCueAndBootstrapsFromTheNextOne() {
        assertFalse(NarrationPolicy.hasPreparationLead(102.0,108.0,100.0))
        assertTrue(NarrationPolicy.hasPreparationLead(108.0,114.0,100.0))
        assertTrue(NarrationPolicy.hasPreparationLead(12.0,18.0,4.0))
        assertTrue(NarrationPolicy.hasPreparationLead(12.0,13.0,10.0))
    }
    @Test fun pausedVideoCanPrepareAnImminentCueBeforeResuming() {
        assertFalse(NarrationPolicy.hasPreparationLead(12.0,20.0,11.9,true))
        assertTrue(NarrationPolicy.hasPreparationLead(12.0,20.0,11.9,false))
        assertTrue(NarrationPolicy.hasPreparationLead(12.0,20.0,12.0,false))
    }
    @Test fun audioPresentationClockKeepsTheMaskPipelineDelayAndItsOwnAnchor() {
        val observation=org.json.JSONObject("{\"position_seconds\":\"12.000\",\"observed_monotonic_ns\":1000,\"audio_pts_us\":11780000,\"audio_delay_seconds\":\"0.2\",\"audio_clock_available\":true,\"audio_observed_monotonic_ns\":900,\"audio_track_id\":\"1\",\"paused\":\"no\"}")
        val clock=NarrationPolicy.playbackClock(observation)
        assertEquals("audio",clock.kind);assertEquals(11.78,clock.position,.000001);assertEquals(900L,clock.observedNs)
        observation.put("paused","yes")
        assertEquals("video",NarrationPolicy.playbackClock(observation).kind)
    }
    @Test fun negativeAudioPrerollDoesNotBecomePositivePlaybackTime() {
        val observation=org.json.JSONObject("{\"position_seconds\":\"0.1\",\"observed_monotonic_ns\":1000,\"audio_pts_us\":-100000,\"audio_delay_seconds\":\"0.2\",\"audio_clock_available\":true,\"audio_observed_monotonic_ns\":900,\"audio_track_id\":\"1\"}")
        val clock=NarrationPolicy.playbackClock(observation)
        assertEquals("audio",clock.kind);assertEquals(-.1,clock.position,.000001)
        assertTrue(NarrationPolicy.hasPreparationLead(0.0,5.0,clock.position,clock.position>=0))
    }
    @Test fun disabledOrStaleAudioCannotReplaceTheVideoClock() {
        val observation=org.json.JSONObject("{\"position_seconds\":\"12.000\",\"observed_monotonic_ns\":1000,\"audio_pts_us\":1000000,\"audio_clock_available\":true,\"audio_observed_monotonic_ns\":900,\"audio_track_id\":\"1\"}")
        assertEquals("video",NarrationPolicy.playbackClock(observation).kind) // Old audio after a seek.
        observation.put("audio_pts_us",11980000).put("audio_track_id","")
        assertEquals("video",NarrationPolicy.playbackClock(observation).kind)
        observation.put("audio_track_id","1").put("audio_pts_us",-100000)
        assertEquals("video",NarrationPolicy.playbackClock(observation).kind)
        observation.put("audio_pts_us",11980000).put("paused_for_cache","yes")
        assertEquals("video",NarrationPolicy.playbackClock(observation).kind)
    }
}
