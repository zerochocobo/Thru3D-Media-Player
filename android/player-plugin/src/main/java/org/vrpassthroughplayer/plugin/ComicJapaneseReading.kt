package org.vrpassthroughplayer.plugin

import com.atilika.kuromoji.ipadic.Tokenizer

/** MOSS Nano has no target-language input. Resolve known Japanese words before
 * chunking to reduce Mandarin pronunciation of Han prefixes; readings can err.
 * This is synthesis-only: OCR, translations and the selected voice stay intact. */
internal object ComicJapaneseReading {
    // Only initialized on the speech worker for Japanese containing Han text.
    private val tokenizer by lazy { Tokenizer() }

    private fun hasHan(value: String) = value.codePoints().anyMatch {
        Character.UnicodeScript.of(it) == Character.UnicodeScript.HAN
    }

    data class Prepared(val text: String, val wordEnds: Set<Int>)

    fun convert(text: String): String = prepare(text).text

    fun prepare(text: String): Prepared {
        if (!hasHan(text)) return Prepared(text, emptySet())
        val ends = HashSet<Int>()
        val converted = buildString {
            var end = 0
            for (token in tokenizer.tokenize(text)) {
                // Keep gaps, punctuation, unknown names and mixed Latin verbatim.
                append(text, end, token.position)
                val surface = token.surface
                val reading = token.reading
                if (hasHan(surface) && reading.isNotEmpty() && reading != "*" &&
                    reading.all { it in '\u30a1'..'\u30f6' || it == '\u30fc' }) {
                    for (c in reading) append(if (c in '\u30a1'..'\u30f6') (c.code - 0x60).toChar() else c)
                } else append(surface)
                ends.add(length)
                end = token.position + surface.length
            }
            append(text, end, text.length)
        }
        return Prepared(converted, ends)
    }
}
