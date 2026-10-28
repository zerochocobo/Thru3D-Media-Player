package org.vrpassthroughplayer.plugin

internal object SubtitleCharsetDetector {
    fun detect(bytes: ByteArray): List<SubtitleEncoding.Guess> =
        com.ibm.icu.text.CharsetDetector().setText(bytes).detectAll().map {
            SubtitleEncoding.Guess(it.name, it.confidence)
        }
}
