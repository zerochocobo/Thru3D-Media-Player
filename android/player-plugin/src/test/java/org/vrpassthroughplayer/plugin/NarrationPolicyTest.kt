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
}
