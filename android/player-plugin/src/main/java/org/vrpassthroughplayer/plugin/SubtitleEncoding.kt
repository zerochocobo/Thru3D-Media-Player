package org.vrpassthroughplayer.plugin

import java.nio.ByteBuffer
import java.nio.charset.Charset
import java.nio.charset.CodingErrorAction

/** Decode once, before either MPV or the independent narration reader sees a file. */
internal object SubtitleEncoding {
    const val MAX_BYTES = 8 * 1024 * 1024
    val choices = setOf("auto", "UTF-8", "UTF-16LE", "UTF-16BE", "windows-949", "GB18030", "Big5", "windows-31j", "windows-1252")
    data class Guess(val charset: String, val confidence: Int)
    data class Result(val bytes: ByteArray, val charset: String, val automatic: Boolean)
    fun canonical(name: String): String? = when (name.lowercase().replace('_', '-')) {
        "auto" -> "auto"
        "utf8", "utf-8", "ascii", "us-ascii" -> "UTF-8"
        "utf-16le" -> "UTF-16LE"
        "utf-16be" -> "UTF-16BE"
        "cp949", "ms949", "windows-949", "x-windows-949", "euc-kr", "ks-c-5601-1987", "ks-c-5601-1989", "ksc5601", "uhc" -> "windows-949"
        "gb18030", "gbk", "gb2312", "cp936", "windows-936" -> "GB18030"
        "big5", "big-5", "cp950", "windows-950" -> "Big5"
        "shift-jis", "shiftjis", "sjis", "windows-31j", "ms932", "cp932" -> "windows-31j"
        "windows-1252", "iso-8859-1", "latin1" -> "windows-1252"
        else -> null
    }
    private fun charset(name: String) = Charset.forName(if (name == "windows-949") "x-windows-949" else name)
    private fun strict(bytes: ByteArray, name: String): String? = runCatching {
        charset(name).newDecoder().onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes)).toString().removePrefix("\uFEFF")
    }.getOrNull()
    private fun usable(text: String): Boolean = text.none { it == '\u0000' } &&
        text.count { it < ' ' && it !in "\t\r\n\u000c" } < 3
    private fun result(text: String, name: String, auto: Boolean): Result {
        require(usable(text)) { "Invalid subtitle text" }
        return Result(text.toByteArray(Charsets.UTF_8), name, auto)
    }
    fun decode(bytes: ByteArray, override: String = "auto", language: String = "",
               detect: (ByteArray) -> List<Guess>): Result {
        require(bytes.isNotEmpty() && bytes.size <= MAX_BYTES)
        val selected = canonical(override) ?: error("Unsupported subtitle encoding")
        if (selected != "auto") return result(strict(bytes, selected) ?: error("Invalid subtitle encoding"), selected, false)
        val bom = when {
            bytes.size >= 2 && bytes[0] == 0xff.toByte() && bytes[1] == 0xfe.toByte() -> "UTF-16LE"
            bytes.size >= 2 && bytes[0] == 0xfe.toByte() && bytes[1] == 0xff.toByte() -> "UTF-16BE"
            else -> null
        }
        if (bom != null) return result(strict(bytes, bom) ?: error("Invalid Unicode subtitle"), bom, true)
        strict(bytes, "UTF-8")?.takeIf(::usable)?.let { return result(it, "UTF-8", true) }
        // ISO-8859-1 is only a byte-preserving view for ASCII declarations/markup.
        val raw = bytes.copyOfRange(0, minOf(bytes.size, 128 * 1024)).toString(Charsets.ISO_8859_1)
        val header = raw.take(16384)
        val declaration = Regex("(?i)charset\\s*=\\s*[\"']?([a-z0-9_-]+)").find(header)?.groupValues?.get(1)?.let(::canonical)
        if (declaration != null && declaration != "auto")
            strict(bytes, declaration)?.takeIf(::usable)?.let { return result(it, declaration, true) }
        val body = raw.replace(Regex("(?is)<(style|script)\\b[^>]*>.*?</\\1>"), " ")
            .replace(Regex("<[^<>]*>"), " ").replace(Regex("&[a-zA-Z#0-9]+;"), " ")
        val sample = body.toByteArray(Charsets.ISO_8859_1)
        val guesses = detect(sample).mapNotNull { guess -> canonical(guess.charset)?.let { it to guess.confidence } }
            .groupBy({ it.first }, { it.second }).mapValues { it.value.maxOrNull() ?: 0 }
        val hint = language.ifBlank { Regex("(?i)lang\\s*:\\s*([a-z-]+)").find(header)?.groupValues?.get(1).orEmpty() }.lowercase()
        val candidates = listOf("windows-949", "GB18030", "Big5", "windows-31j", "windows-1252")
        val ranked = candidates.mapNotNull { name ->
            val text = strict(bytes, name)?.takeIf(::usable) ?: return@mapNotNull null
            val plain = text.take(128 * 1024).replace(Regex("<[^<>]*>"), " ")
            val letters = plain.count { it.code > 127 && it.isLetter() }.coerceAtLeast(1)
            val hangul = plain.count { it in '\uAC00'..'\uD7A3' }.toDouble() / letters
            val kana = plain.count { it in '\u3040'..'\u30FF' }.toDouble() / letters
            var score = (guesses[name] ?: 0).toDouble()
            // ICU's EUC-KR model misses CP949-only syllables. Strong Hangul or
            // kana evidence supplements it; a filename/system locale never forces a codec.
            if (name == "windows-949" && hangul > 0.6) score += 35 * hangul
            if (name == "windows-31j" && kana > 0.2) score += 20 * kana
            if ((name == "windows-949" && hint.startsWith("ko")) ||
                (name == "windows-31j" && hint.startsWith("ja")) ||
                (name == "Big5" && hint in setOf("zh-tw", "zh-hk", "zh-hant")) ||
                (name == "GB18030" && hint in setOf("zh-cn", "zh-sg", "zh-hans"))) score += 25
            name to score // Do not retain several full decoded copies of a large file.
        }.sortedByDescending { it.second }
        val best = ranked.firstOrNull() ?: error("Invalid subtitle text")
        return result(strict(bytes, best.first) ?: error("Invalid subtitle text"), best.first, true)
    }
}
