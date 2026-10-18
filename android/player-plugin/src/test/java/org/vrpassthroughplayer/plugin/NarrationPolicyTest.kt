package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test
import org.json.JSONArray

class NarrationPolicyTest {
    @Test fun onlyExplicitLanguageMetadataSelectsLanguage() {
        listOf("zh", "chi", "cmn", "zho", "zh-Hant", "zh_Hans_CN").forEach { assertEquals("zh", NarrationPolicy.language(it)) }
        listOf("en", "eng", "en-US").forEach { assertEquals("en", NarrationPolicy.language(it)) }
        listOf("", "und", "mul", "auto").forEach { assertEquals("", NarrationPolicy.language(it)) }
    }
    @Test fun japaneseAndAuthoredMultilineSelection() {
        assertTrue(NarrationPolicy.PREVIEW_WINDOW_SECONDS >= 250*.08/.8+1.0)
        assertTrue(NarrationPolicy.PREVIEW_WINDOW_SECONDS <= 30.0)
        assertEquals("ja",NarrationPolicy.language("jpn"));assertEquals("ja",NarrationPolicy.language("ja-JP"))
        val config=NarrationPolicy.Config.parse("""{"language":"ja","ja_voice":"Umiri","line":2}""")
        assertEquals("Umiri",config.voice("ja"));assertEquals(2,config.line)
        val raw=JSONArray("""[{"start":1,"end":5,"text":"<i>Hello</i><br />你好"},{"start":6,"end":9,"text":"Only one line"}]""")
        val second=NarrationPolicy.cues(raw,"zh",2)
        assertEquals(1,second.size);assertEquals("你好",second.single().text)
        assertEquals(1.0,second.single().windowStart,0.0);assertEquals(5.0,second.single().windowEnd,0.0)
        assertEquals("Hello",NarrationPolicy.cues(raw,"en",1).first().text)
        assertTrue(NarrationPolicy.cues(raw,"en",3).isEmpty())
        val simultaneous=JSONArray("""[{"start":1,"end":4,"text":"English"},{"start":1,"end":4,"text":"中文"}]""")
        assertEquals("中文",NarrationPolicy.cues(simultaneous,"zh",2).single().text)
        assertTrue(NarrationPolicy.cues(raw,"en",0).first().text.contains("你好"))
        assertEquals("2026年10月",NarrationPolicy.normalize("2026年10月","ja"))
        assertEquals("こんにちは。",NarrationPolicy.speechText("こんにちは","ja"))
        assertTrue(runCatching { NarrationPolicy.Config.parse("""{"line":9}""") }.isFailure)
    }
    @Test fun voicesRemainSeparateForEachLanguageAndDefaultsAreFemale() {
        val defaults=NarrationPolicy.Config.parse("{}")
        assertEquals("Xiaoyu",defaults.voice("zh"));assertEquals("Ava",defaults.voice("en"))
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
        assertEquals(1.8,NarrationPolicy.playbackRate(20.0,.1,.4,1.0),0.0)
    }
    @Test fun obsoleteSavedManualRatesCannotAlterTheAutomaticConfiguration() {
        for(oldRate in listOf(.8,1.0,1.3,1.8,2.34))
            assertEquals(NarrationPolicy.Config.parse("{}"),NarrationPolicy.Config.parse("{\"rate\":$oldRate}"))
    }
    @Test fun presentationWindowBudgetIsSeparateFromNaturalEosGeneration() {
        assertEquals(129,NarrationPolicy.frameBudget(6.0))
        assertEquals(250,NarrationPolicy.frameBudget(60.0))
        // The presentation target for normal long sentences still fits, including
        // the observed 98-frame example. Natural EOS generation has its own bound.
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
    @Test fun realShortSubtitlesGetEnoughGenerationRoomToReachEos() {
        val chinese=NarrationPolicy.generationFrameBudget("你今天怎么这么早就回来了", "zh", 1.9)
        assertTrue(chinese*.08>4.0)
        assertTrue(chinese>NarrationPolicy.frameBudget(1.9))
        val english=NarrationPolicy.generationFrameBudget("Can you tell me what happened?", "en", 1.5)
        assertTrue(english*.08>4.0)
        assertTrue(NarrationPolicy.generationFrameBudget("一".repeat(2048),"zh",1.0)<=250)
        assertTrue(NarrationPolicy.generationFrameBudget("你好。","zh",1.0)>52)
    }
    @Test fun subtitleFragmentsGetAnEndMarkWithoutChangingTheirWords() {
        assertEquals("你好。",NarrationPolicy.speechText("你好", "zh"))
        assertEquals("Hello.",NarrationPolicy.speechText("Hello", "en"))
        for(text in listOf("你好。","什么?","等一下......","Hello!","Really?"))assertEquals(text,NarrationPolicy.speechText(text, "zh"))
        assertEquals("",NarrationPolicy.speechText(" ","zh"))
    }
    @Test fun quotedCaptionsKeepTheirWordsWithoutLiteralWrapperTokens() {
        assertEquals("别点跳过片头!",NarrationPolicy.speechText("（别点“跳过片头”！）","zh"))
        assertEquals("Hello, it's really me.",NarrationPolicy.speechText("\"Hello, it’s (really) me\"","en"))
        assertEquals("你好。",NarrationPolicy.speechText("你好，","zh"))
    }
    @Test fun denseCaptionsEitherFinishWithinTheBoundOrAreRejectedBeforeStarting() {
        val continuous=NarrationPolicy.Config.parse("{\"timing\":\"continuous\"}");val strict=NarrationPolicy.Config.parse("{\"timing\":\"strict\"}")
        assertEquals(3.0,continuous.deadlineSlack,0.0);assertEquals(.4,strict.deadlineSlack,0.0)
        assertTrue(NarrationPolicy.canFinish(4.8,1.125,0.0,1.0,continuous.deadlineSlack))
        assertFalse(NarrationPolicy.canFinish(4.8,1.125,0.0,1.0,strict.deadlineSlack))
        assertTrue(NarrationPolicy.canFinish(2.0,1.167,1.53,1.0,continuous.deadlineSlack))
        assertFalse(NarrationPolicy.canFinish(20.0,1.125,0.0,1.0,continuous.deadlineSlack))
        assertTrue(runCatching {NarrationPolicy.Config.parse("{\"timing\":\"unbounded\"}")}.isFailure)
    }
    @Test fun defaultBorrowsTimeButCannotAccumulateAnUnlimitedBacklog() {
        val config=NarrationPolicy.Config.parse("{}")
        assertEquals("interrupt",config.timing);assertEquals(0,config.line)
        val first=NarrationPolicy.Cue(1.0,2.0,"first")
        val next=NarrationPolicy.Cue(8.0,9.0,"next")
        assertEquals(8.0,NarrationPolicy.interruptBoundary(first,listOf(first,next)),0.0)
        assertEquals(10.0,NarrationPolicy.speechDeadline(first,listOf(first,next)),0.0)
        assertEquals(Double.POSITIVE_INFINITY,NarrationPolicy.interruptBoundary(next,listOf(first,next)),0.0)
        val part=NarrationPolicy.Cue(2.0,3.0,"part",1.0,3.0)
        assertEquals(8.0,NarrationPolicy.interruptBoundary(first,listOf(first,part,next)),0.0)
        assertTrue(runCatching {NarrationPolicy.Config.parse("{\"line\":3}")}.isFailure)
    }
    @Test fun voiceNativeLanguageDoesNotRestrictReadingLanguage() {
        val groups=mapOf("zh" to listOf("Xiaoyu","Yuewen","Lingyu","Zhiming","Junhao"),
            "en" to listOf("Ava","Bella","Adam"),"ja" to listOf("Mei","Saki","Mortis","Umiri"))
        assertEquals(12,groups.values.flatten().distinct().size)
        for(voice in groups.values.flatten()) for(language in listOf("zh","en","ja")) {
            val config=NarrationPolicy.Config.parse("{\"language\":\"$language\",\"voice_override\":\"$voice\"}")
            assertEquals(voice,config.voice(language));assertEquals(language,config.language)
        }
        assertTrue(runCatching {NarrationPolicy.Config.parse("{\"voice_override\":\"../../preset\"}")}.isFailure)
    }
    @Test fun shortStreamingPrefixMustCoverTheWholeTimeUntilTheSwitch() {
        assertTrue(NarrationPolicy.streamingReady(30720,1.0,.27,true))
        assertFalse(NarrationPolicy.streamingReady(30720,1.0,.6,true))
        assertFalse(NarrationPolicy.streamingReady(30720,1.3,.27,true))
        assertFalse(NarrationPolicy.streamingReady(30720,1.0,.27,false))
        assertFalse(NarrationPolicy.streamingReady(30720,1.0,Double.POSITIVE_INFINITY,true))
        assertTrue(NarrationPolicy.streamingReady(61440,1.0,10.0,true))
    }
    @Test fun shortSpeechAlsoRespectsTheExperimentalDoubleSpeedLimit() {
        assertTrue(NarrationPolicy.playbackRate(3.0,2.0,0.0,1.0)<=1.8)
        assertEquals(1.8,NarrationPolicy.playbackRate(12.0,6.0,0.0,1.0),0.0)
    }
    @Test fun completedSpeechUsesTheActualNextCueAndLeavesGapsAtNaturalSpeed() {
        assertEquals(1.25,NarrationPolicy.fittedTempo(2.5,2.0,1.0),.000001)
        assertEquals(1.0,NarrationPolicy.fittedTempo(2.5,5.0,1.0),0.0)
        assertEquals(.8,NarrationPolicy.fittedTempo(2.5,Double.POSITIVE_INFINITY,.8),0.0)
        for(window in listOf(-1.0,0.0,.1,1.0,3.0))for(preferred in listOf(.8,1.0,1.3,2.0))
            assertTrue(NarrationPolicy.fittedTempo(8.0,window,preferred)<=1.8)
    }
    @Test fun lookaheadLetsTheFirstSentenceFinishAndRecoversInTheFollowingSpace() {
        val budgets=listOf(NarrationPolicy.SpeechBudget(3.2,2.5),NarrationPolicy.SpeechBudget(1.0,4.5))
        val rate=NarrationPolicy.plannedTempo(budgets,0.0,1.0,0.0,1.0)
        assertTrue(rate>1.0&&rate<1.5)
        assertTrue(3.2/rate>2.0&&3.2/rate<2.5) // Borrow from the following cue.
        assertEquals(1.0,NarrationPolicy.plannedTempo(listOf(NarrationPolicy.SpeechBudget(3.2,8.5)),0.0,1.0,0.0,1.0),0.0)
        assertEquals(1.8,NarrationPolicy.plannedTempo(listOf(NarrationPolicy.SpeechBudget(12.0,2.0)),0.0,1.5,.2,1.5),0.0)
    }
    @Test fun borrowingNeverReplaysACaptionThatEndedBeforeTheSeek() {
        val previous=NarrationPolicy.Cue(43.0,46.0,"previous")
        val current=NarrationPolicy.Cue(47.0,49.0,"current")
        val following=NarrationPolicy.Cue(55.0,57.0,"following")
        assertTrue(NarrationPolicy.speechDeadline(previous,listOf(previous,following))>48.0)
        assertEquals(listOf(current,following),listOf(previous,current,following).filter {NarrationPolicy.afterSeek(it,48.0,0.0)})
        assertTrue(NarrationPolicy.afterSeek(previous,48.0,3.0))
        assertTrue(NarrationPolicy.afterSeek(previous,Double.NaN,0.0)) // Standalone preview clock.
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
