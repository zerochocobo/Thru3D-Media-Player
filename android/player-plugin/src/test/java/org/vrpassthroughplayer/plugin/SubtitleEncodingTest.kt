package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test
import java.nio.charset.Charset

class SubtitleEncodingTest {
    private fun detect(bytes: ByteArray) = SubtitleCharsetDetector.detect(bytes)
    private fun decode(bytes: ByteArray, choice: String = "auto", language: String = "") =
        SubtitleEncoding.decode(bytes, choice, language, ::detect)
    private fun smi(text: String, header: String = "") = "<SAMI><HEAD>$header</HEAD><BODY>\n" +
        (1..15).joinToString("\n") { "<SYNC Start=${it*2000}><P Class=SUBCC>$text" } + "\n<SYNC Start=32000><P>&nbsp;</BODY></SAMI>"
    @Test fun detectsKoreanChineseAndJapaneseWithoutLanguageHints() {
        val cases = listOf(
            "x-windows-949" to "안녕하세요. 오늘은 날씨가 정말 좋습니다. 우리는 함께 영화를 보고 있습니다. 괜찮아요, 내일 다시 만나요!",
            "GBK" to "你好，今天的天气真好。我们一起去看电影吧！这是一个关于朋友和家人的故事。现在开始播放中文字幕。",
            "Big5" to "你好，今天的天氣真好。我們一起去看電影吧！這是一個關於朋友和家人的故事。現在開始播放中文字幕。",
            "windows-31j" to "こんにちは。今日はとてもいい天気ですね。みんなで映画を見に行きましょう。これは友達と家族のお話です。"
        )
        for ((encoding, text) in cases) {
            for (source in listOf(smi(text), "1\n00:00:01,000 --> 00:00:05,000\n" + text.repeat(8))) {
                val result = decode(source.toByteArray(Charset.forName(encoding)))
                assertEquals("$encoding detected as ${result.charset}", source, result.bytes.toString(Charsets.UTF_8))
            }
        }
    }
    @Test fun cp949ExtensionAndSamiLanguageAreHandled() {
        val source = smi("똠방각하 뷁 쀍 똠방각하 뷁 쀍", "<STYLE>.KRCC { Name:Korean; lang:ko-KR; SAMIType:CC; }</STYLE>")
        val bytes = source.toByteArray(Charset.forName("x-windows-949"))
        assertEquals(source, decode(bytes).bytes.toString(Charsets.UTF_8))
        assertEquals(source, decode(bytes, "EUC-KR").bytes.toString(Charsets.UTF_8))
        val withoutHints = smi("똠방각하 뷁 쀍 똠방각하 뷁 쀍")
        assertEquals(withoutHints, decode(withoutHints.toByteArray(Charset.forName("x-windows-949"))).bytes.toString(Charsets.UTF_8))
    }
    @Test fun unicodeAndStaleDeclarationsNeverRegress() {
        val source = smi("한국어 中文 日本語 😀", "<meta charset=EUC-KR>")
        for (encoding in listOf("UTF-8", "UTF-16LE", "UTF-16BE")) {
            val bytes = (if (encoding == "UTF-8") "" else "\uFEFF") + source
            assertEquals(source, decode(bytes.toByteArray(Charset.forName(encoding))).bytes.toString(Charsets.UTF_8))
        }
        assertEquals(source, decode(("\uFEFF"+source).toByteArray()).bytes.toString(Charsets.UTF_8))
    }
    @Test fun explicitChoiceCorrectsAmbiguityAndDoesNotChangeOriginalBytes() {
        val source = smi("한국어 자막 테스트", "<meta charset=GBK>")
        val bytes = source.toByteArray(Charset.forName("x-windows-949")); val copy = bytes.copyOf()
        assertEquals(source, decode(bytes, "windows-949").bytes.toString(Charsets.UTF_8))
        assertArrayEquals(copy, bytes)
        assertThrows(Exception::class.java) { decode(bytes, "UTF-8") }
        assertThrows(Exception::class.java) { decode(bytes, "unknown") }
    }
    @Test fun asciiAndBinaryLimits() {
        assertEquals("UTF-8", decode(smi("Hello!").toByteArray()).charset)
        assertThrows(Exception::class.java) { decode(byteArrayOf(0, 1, 2, 0, 3)) }
        assertThrows(Exception::class.java) { decode(ByteArray(SubtitleEncoding.MAX_BYTES + 1)) }
    }
    @Test fun normalizedLeaseIsSharedImmutableAndRevocable() {
        val folder = java.nio.file.Files.createTempDirectory("subtitle-encoding").toFile()
        try {
            val original = smi("안녕하세요. 함께 영화를 보고 있습니다.")
            val file = java.io.File(folder, "movie.ko.smi").apply { writeBytes(original.toByteArray(Charset.forName("x-windows-949"))) }
            SubtitleTextSources(::detect).use { sources ->
                val first = sources.prepare(SidecarSubtitles.Track(file.absolutePath, file.name))
                val second = sources.recode(first.location, "windows-949")
                assertNotEquals(first.location, second.location)
                // Independent MPV/narration HTTP readers receive exactly the same UTF-8.
                assertEquals(original, java.net.URL(second.location).readText(Charsets.UTF_8))
                assertArrayEquals(java.net.URL(first.location).readBytes(), java.net.URL(second.location).readBytes())
                assertEquals("movie.ko.smi", sources.get(second.location)?.identity)
                sources.release(first.location)
                assertNull(sources.get(first.location))
                assertEquals(original, java.net.URL(second.location).readText(Charsets.UTF_8))
                assertEquals(original, file.readText(Charset.forName("x-windows-949")))
            }
        } finally { folder.listFiles()?.forEach { it.delete() }; folder.delete() }
    }
    @Test fun desktopFfmpegReadsNormalizedSamiSrtAndAss() {
        val executable = System.getenv("THRU3D_TEST_FFMPEG").orEmpty()
        org.junit.Assume.assumeTrue("Optional desktop demux integration requires THRU3D_TEST_FFMPEG", java.io.File(executable).isFile)
        val folder = java.nio.file.Files.createTempDirectory("subtitle-demux").toFile()
        try {
            val cases = listOf(
                Triple("x-windows-949", "ko", "안녕하세요. 오늘은 날씨가 정말 좋습니다. 우리는 함께 영화를 보고 있습니다. 괜찮아요, 내일 다시 만나요!"),
                Triple("x-windows-949", "ko", "똠방각하 뷁 쀍 똠방각하 뷁 쀍"),
                Triple("GBK", "zh-CN", "你好，今天的天气真好。我们一起去看电影吧！这是一个关于朋友和家人的故事。现在开始播放中文字幕。"),
                Triple("Big5", "zh-TW", "你好，今天的天氣真好。我們一起去看電影吧！這是一個關於朋友和家人的故事。現在開始播放中文字幕。"),
                Triple("windows-31j", "ja", "こんにちは。今日はとてもいい天気ですね。みんなで映画を見に行きましょう。これは友達と家族のお話です。")
            )
            SubtitleTextSources(::detect).use { sources ->
                for ((encoding, language, text) in cases) for (format in listOf("smi", "srt", "ass")) {
                    val content = when (format) {
                        "smi" -> smi(text, "<STYLE>.SUBCC {lang:$language; SAMIType:CC;}</STYLE>")
                        "srt" -> "1\n00:00:02,000 --> 00:00:04,000\n$text\n"
                        else -> "[Script Info]\nScriptType: v4.00+\n[Events]\n" +
                            "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n" +
                            "Dialogue: 0,0:00:02.00,0:00:04.00,Default,,0,0,0,,$text\n"
                    }
                    val raw = content.toByteArray(Charset.forName(encoding))
                    val file = java.io.File(folder, "movie.$language.$format").apply { writeBytes(raw) }
                    val track = sources.prepare(SidecarSubtitles.Track(file.absolutePath, file.name, language))
                    assertEquals(content, java.net.URL(track.location).readText(Charsets.UTF_8))
                    val process = ProcessBuilder(executable, "-v", "error", "-i", track.location,
                        "-map", "0:s:0", "-c:s", "srt", "-f", "srt", "pipe:1").redirectErrorStream(true).start()
                    try {
                        assertTrue("Desktop demux timed out", process.waitFor(20, java.util.concurrent.TimeUnit.SECONDS))
                        val decoded = process.inputStream.readBytes().toString(Charsets.UTF_8)
                        assertEquals(decoded, 0, process.exitValue())
                        assertTrue("$encoding / $format: $decoded", decoded.contains(text))
                        assertTrue("Subtitle timing must be preserved", decoded.contains("00:00:02,000 --> 00:00:04,000"))
                    } finally { process.destroyForcibly() }
                    assertArrayEquals(raw, file.readBytes())
                    sources.release(track.location)
                }
            }
        } finally { folder.listFiles()?.forEach { it.delete() }; folder.delete() }
    }
}
