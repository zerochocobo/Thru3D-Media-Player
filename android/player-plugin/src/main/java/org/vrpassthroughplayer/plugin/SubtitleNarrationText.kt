package org.vrpassthroughplayer.plugin

/** Synthesis-only preparation; subtitle text, cue identity and timing stay intact.
 * Call on the speech worker because the Japanese dictionary is initialized lazily. */
internal object SubtitleNarrationText {
    fun prepare(text: String, language: String): String {
        val spoken = NarrationPolicy.speechText(text, language)
        return if (language == "ja") ComicJapaneseReading.convert(spoken) else spoken
    }
}
