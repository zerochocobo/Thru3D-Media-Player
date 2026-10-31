package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class SubtitleNarrationTextTest {
    @Test fun japaneseSubtitlesReuseComicReadingsAndSentenceEnds() {
        val examples = mapOf(
            "先生！" to "せんせい!",
            "大丈夫？" to "だいじょうぶ?",
            "今日も学校に行きます。" to "きょうもがっこうにいきます。",
            "「日本語を話してください」" to "にほんごをはなしてください。"
        )
        for ((text, expected) in examples) {
            assertEquals(expected, SubtitleNarrationText.prepare(text, "ja"))
            assertEquals(ComicNarrationSession.speechSegments(text, "ja").single(),
                SubtitleNarrationText.prepare(text, "ja"))
        }
    }

    @Test fun selectedSubtitleLineKeepsOriginalTextIdentityAndTiming() {
        val raw = JSONArray().put(JSONObject().put("start", 2.5).put("end", 7.0)
            .put("text", "Hello, teacher!\n先生！"))
        val cue = NarrationPolicy.cues(raw, "ja", 2).single()
        val original = cue.copy()
        val key = cue.key
        assertEquals("せんせい!", SubtitleNarrationText.prepare(cue.text, "ja"))
        assertEquals(original, cue)
        assertEquals(key, cue.key)
        assertEquals("先生!", cue.text)
        assertEquals(2.5, cue.start, 0.0)
        assertEquals(7.0, cue.end, 0.0)
        assertEquals("Hello, teacher!\n先生！", raw.getJSONObject(0).getString("text"))
    }

    @Test fun conversionFollowsResolvedLanguageIncludingAutomaticJapaneseMetadata() {
        for (language in listOf("ja", NarrationPolicy.language("jpn"), NarrationPolicy.language("ja-JP")))
            assertEquals("にほんご。", SubtitleNarrationText.prepare("日本語", language))
        // Han characters in another target language must not acquire Japanese readings.
        assertEquals("今天去学校。", SubtitleNarrationText.prepare("今天去学校。", "zh"))
        assertEquals("日本語.", SubtitleNarrationText.prepare("日本語", "en"))
        assertEquals("Hello!", SubtitleNarrationText.prepare("Hello！", "en"))
        for (language in NarrationPolicy.languages - "ja")
            assertEquals(NarrationPolicy.speechText("先生！", language),
                SubtitleNarrationText.prepare("先生！", language))
    }

    @Test fun mixedScriptUnknownCharactersAndKanaArePreserved() {
        assertEquals("ABC 𠮷 😀!", SubtitleNarrationText.prepare("ABC 𠮷 😀!", "ja"))
        assertEquals("こんにちは、カタカナ。", SubtitleNarrationText.prepare("こんにちは、カタカナ", "ja"))
        assertEquals("", SubtitleNarrationText.prepare("「」", "ja"))
        val text = "今日は先生と一緒に学校に行きます。".repeat(4)
        assertEquals(ComicJapaneseReading.convert(text), SubtitleNarrationText.prepare(text, "ja"))
    }
}
