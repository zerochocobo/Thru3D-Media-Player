package org.vrpassthroughplayer.plugin

import java.io.File
import java.io.RandomAccessFile

/**
 * Kindle books: MOBI (PalmDOC or HUFF/CDIC text) and KF8/AZW3, alone or as the newer half of a combined
 * file. The text records are joined into the book's own markup and read like any other HTML; images are
 * the file's image records. Kindle DRM is refused.
 */
internal class MobiBook(file: File, name: String) : Book {
    override var title = name.substringAfterLast('/').substringBeforeLast('.'); private set
    override var language = ""; private set
    override val chapters: List<BookChapter>
    override val contents: List<BookContents>
    private val access = RandomAccessFile(file, "r")
    private val offsets: LongArray
    private var images = -1

    init {
        try {
            val header = ByteArray(78)
            access.readFully(header)
            require(String(header, 60, 8, Charsets.ISO_8859_1) in setOf("BOOKMOBI", "TEXtREAd")) { "BOOK_UNAVAILABLE" }
            val count = u16(header, 76)
            require(count in 2..65535) { "BOOK_UNAVAILABLE" }
            val table = ByteArray(count * 8)
            access.readFully(table)
            offsets = LongArray(count + 1) { if (it < count) u32(table, it * 8) else access.length() }
            var first = 0
            var head = record(first)
            var exth = exth(head)
            // A combined file carries the old book first and the KF8 one after its boundary record.
            exth[121]?.let { boundary ->
                val start = u32(boundary, 0).toInt()
                if (start in 1 until count - 1) runCatching { record(start) }.getOrNull()?.takeIf { mobi(it) }?.let {
                    first = start; head = it; exth = exth(it)
                }
            }
            require(u16(head, 12) == 0) { "BOOK_PROTECTED" }
            val utf8 = mobi(head) && u32(head, 28) == 65001L
            val charset = if (utf8 || !mobi(head)) Charsets.UTF_8 else charset("windows-1252")
            var text = ""
            if (mobi(head)) {
                val headerLength = u32(head, 20).toInt()
                val nameAt = u32(head, 84).toInt(); val nameLength = u32(head, 88).toInt()
                if (nameAt > 0 && nameLength in 1..1024 && nameAt + nameLength <= head.size)
                    String(head, nameAt, nameLength, charset).trim().takeIf { it.isNotEmpty() }?.let { title = it }
                exth[503]?.let { String(it, charset).trim() }?.takeIf { it.isNotEmpty() }?.let { title = it }
                exth[524]?.let { language = String(it, charset).trim() }
                images = pictures(u32(head, 108), first)
                val extra = if (headerLength >= 0xE4 && head.size >= 0xF4) u16(head, 0xF2) else 0
                text = decode(head, first, extra, charset, if (u32(head, 36) >= 8) flow(u32(head, 192), first) else Long.MAX_VALUE)
            } else text = decode(head, first, 0, charset, Long.MAX_VALUE)
            val kf8 = mobi(head) && u32(head, 36) >= 8
            val parsed = ArrayList<BookChapter>()
            val pieces = parts(text, kf8)
            val chapterOf = IntArray(pieces.size) { -1 }
            for ((index, part) in pieces.withIndex()) {
                val flow = BookMarkup.flow(part.second) { reference(it) }
                if (flow.blocks.isEmpty()) continue
                chapterOf[index] = parsed.size
                parsed += BookChapter(heading(flow), flow)
            }
            require(parsed.isNotEmpty()) { "BOOK_UNAVAILABLE" }
            // Old books without headings keep their contents as a page of links to byte positions.
            val linked = if (kf8 || parsed.count { it.title.isNotEmpty() } * 2 >= parsed.size) emptyList()
                else linkedContents(text, pieces, chapterOf, charset)
            chapters = if (linked.isEmpty()) parsed else parsed.mapIndexed { index, chapter ->
                if (chapter.title.isNotEmpty()) chapter else linked.firstOrNull { it.chapter == index }?.let { BookChapter(it.title, chapter.flow) } ?: chapter }
            contents = linked.ifEmpty {
                parsed.mapIndexedNotNull { index, chapter -> if (chapter.title.isEmpty()) null else BookContents(chapter.title, 0, index, "") } }
        } catch (error: Throwable) { access.close(); throw error }
    }

    private fun mobi(head: ByteArray) = head.size >= 24 && String(head, 16, 4, Charsets.ISO_8859_1) == "MOBI"

    /** Pagination reads pictures from several threads; the file has one position. */
    private fun record(index: Int): ByteArray = synchronized(access) {
        val start = offsets[index]; val end = offsets[index + 1]
        require(end >= start && end - start <= Books.RESOURCE_BYTES && end <= access.length()) { "BOOK_UNAVAILABLE" }
        access.seek(start)
        return ByteArray((end - start).toInt()).also(access::readFully)
    }

    /** The first image record. A combined file may count it from its start or from the KF8 half. */
    private fun pictures(value: Long, first: Int): Int {
        if (value !in 1 until 0xFFFFFFFF) return -1
        for (candidate in listOf(value + first, value).map { it.toInt() }.distinct()) {
            if (candidate !in 1 until offsets.size - 1) continue
            val head = runCatching { access.seek(offsets[candidate]); ByteArray(4).also(access::readFully) }.getOrNull() ?: continue
            if (picture(head)) return candidate
        }
        return value.toInt()
    }

    private fun picture(head: ByteArray) = (head[0] == 0xFF.toByte() && head[1] == 0xD8.toByte()) ||
        String(head, Charsets.ISO_8859_1).let { it.startsWith("GIF8") || it.startsWith("PNG", 1) || it.startsWith("BM") }

    /** The length of KF8's first flow, its XHTML; stylesheets and SVG follow it in other flows. */
    private fun flow(index: Long, first: Int): Long {
        val at = (index + first).toInt()
        if (index !in 1 until 0xFFFFFFFF || at !in 1 until offsets.size - 1) return Long.MAX_VALUE
        val fdst = runCatching { record(at) }.getOrNull() ?: return Long.MAX_VALUE
        if (fdst.size < 20 || String(fdst, 0, 4, Charsets.ISO_8859_1) != "FDST" || u32(fdst, 8) < 1) return Long.MAX_VALUE
        return u32(fdst, 16).takeIf { it > 0 } ?: Long.MAX_VALUE
    }

    private fun exth(head: ByteArray): Map<Int, ByteArray> {
        if (!mobi(head) || head.size < 0x84 || u32(head, 0x80) and 0x40 == 0L) return emptyMap()
        val at = 16 + u32(head, 20).toInt()
        if (at + 12 > head.size || String(head, at, 4, Charsets.ISO_8859_1) != "EXTH") return emptyMap()
        val records = HashMap<Int, ByteArray>()
        var cursor = at + 12
        repeat(u32(head, at + 8).toInt().coerceAtMost(4096)) {
            if (cursor + 8 > head.size) return records
            val type = u32(head, cursor).toInt(); val length = u32(head, cursor + 4).toInt()
            if (length < 8 || cursor + length > head.size) return records
            records.putIfAbsent(type, head.copyOfRange(cursor + 8, cursor + length))
            cursor += length
        }
        return records
    }

    private fun decode(head: ByteArray, first: Int, extra: Int, charset: java.nio.charset.Charset, limit: Long): String {
        val compression = u16(head, 0)
        val records = u16(head, 8)
        val huffman = if (compression == 17480) Huffman(head, first, ::record) else null
        require(compression in setOf(1, 2, 17480)) { "BOOK_UNAVAILABLE" }
        val out = java.io.ByteArrayOutputStream(u32(head, 4).toInt().coerceIn(0, Books.TEXT_BYTES.toInt()))
        for (index in first + 1..first + records) {
            if (index >= offsets.size - 1) break
            val data = record(index)
            val size = data.size - trailing(data, extra)
            if (size <= 0) continue
            when (compression) {
                1 -> out.write(data, 0, size)
                2 -> palmdoc(data, size, out)
                else -> out.write(huffman!!.unpack(data.copyOf(size)))
            }
            require(out.size() <= Books.TEXT_BYTES) { "BOOK_UNAVAILABLE" }
            if (out.size() >= limit) break
        }
        val bytes = out.toByteArray()
        return String(bytes, 0, minOf(bytes.size.toLong(), limit).toInt(), charset)
    }

    /** Old books break chapters with page breaks; KF8 keeps one XHTML file after another. */
    /** Each piece with the character index where it starts in [markup]. */
    private fun parts(markup: String, kf8: Boolean): List<Pair<Int, String>> {
        val pattern = if (kf8) Regex("""<\?xml|<html[\s>]""", RegexOption.IGNORE_CASE) else Regex("""<mbp:pagebreak\s*/?>""", RegexOption.IGNORE_CASE)
        val result = ArrayList<Pair<Int, String>>()
        var start = 0
        for (match in pattern.findAll(markup)) {
            // KF8 keeps the opening of the next file with it; a page break itself belongs to neither side.
            val end = match.range.first
            if (end > start) result += start to markup.substring(start, end)
            start = if (kf8) match.range.first else match.range.last + 1
        }
        if (start < markup.length) result += start to markup.substring(start)
        return result.filter { it.second.isNotBlank() }.ifEmpty { listOf(0 to markup) }
    }

    /** The contents page's links ("filepos" counts bytes of the book's markup) mapped to the chapters they open. */
    private fun linkedContents(markup: String, pieces: List<Pair<Int, String>>, chapterOf: IntArray,
            charset: java.nio.charset.Charset): List<BookContents> {
        val utf8 = charset == Charsets.UTF_8
        val bytes = LongArray(pieces.size)
        var at = 0; var total = 0L
        for ((index, piece) in pieces.withIndex()) {
            total += if (utf8) utf8Length(markup, at, piece.first) else (piece.first - at).toLong()
            at = piece.first; bytes[index] = total
        }
        val rows = ArrayList<BookContents>()
        val seen = HashSet<Int>()
        val link = Regex("""<a\s[^>]*?filepos\s*=\s*["']?0*(\d+)[^>]*>(.*?)</a>""", setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL))
        val tags = Regex("<[^>]*>")
        for (match in link.findAll(markup)) {
            val target = match.groupValues[1].toLongOrNull() ?: continue
            val title = BookMarkup.unescape(match.groupValues[2].replace(tags, "")).replace(Regex("""\s+"""), " ").trim()
            if (title.isEmpty() || title.length > 60) continue
            var piece = bytes.indexOfLast { it <= target }
            while (piece in chapterOf.indices && chapterOf[piece] < 0) piece++
            val chapter = chapterOf.getOrElse(piece) { -1 }
            if (chapter < 0 || !seen.add(chapter)) continue
            rows += BookContents(title, 0, chapter, "")
        }
        return if (rows.size >= 2) rows.sortedBy { it.chapter } else emptyList()
    }

    private fun utf8Length(text: String, from: Int, to: Int): Long {
        var length = 0L
        var i = from
        while (i < to) {
            val c = text[i]
            length += when {
                c.code < 0x80 -> 1
                c.code < 0x800 -> 2
                Character.isHighSurrogate(c) && i + 1 < to -> { i++; 4 }
                else -> 3
            }
            i++
        }
        return length
    }

    /** "kindle:embed:000A?mime=..." in KF8, "recindex=00010" in old books: both count from the first image record. */
    private fun reference(source: String): String {
        val value = source.trim()
        if (value.startsWith("kindle:embed:", true)) {
            val code = value.substring(13).substringBefore('?')
            val number = code.fold(0) { total, c -> total * 32 + Character.digit(c, 32).coerceAtLeast(0) }
            return if (number > 0) "image:${number - 1}" else ""
        }
        if (value.startsWith("recindex:")) return value.substring(9).toIntOrNull()?.takeIf { it > 0 }?.let { "image:${it - 1}" } ?: ""
        return ""
    }

    private fun heading(flow: BookFlow): String {
        val first = flow.blocks.take(6).filterIsInstance<BookBlock.Text>()
        first.firstOrNull { it.heading in 1..3 }?.let { return it.text.take(60) }
        return first.firstOrNull { it.text.length <= 40 && TextBook.chapter.matches(it.text) }?.text ?: ""
    }

    override fun resource(path: String): ByteArray? {
        val index = path.removePrefix("image:").toIntOrNull() ?: return null
        if (images < 0 || images + index >= offsets.size - 1) return null
        return runCatching { record(images + index) }.getOrNull()
    }

    override fun close() = access.close()

    /** Huffman/CDIC text compression: a prefix code over 32-bit windows with dictionary entries that may nest. */
    private class Huffman(head: ByteArray, first: Int, record: (Int) -> ByteArray) {
        private val dict1 = LongArray(256)
        private val minCode = LongArray(33); private val maxCode = LongArray(33)
        private val entries = ArrayList<ByteArray?>()
        private val literal = ArrayList<Boolean>()

        init {
            val at = first + u32(head, 112).toInt(); val count = u32(head, 116).toInt()
            val huff = record(at)
            require(String(huff, 0, 4, Charsets.ISO_8859_1) == "HUFF") { "BOOK_UNAVAILABLE" }
            val cache = u32(huff, 8).toInt(); val base = u32(huff, 12).toInt()
            for (i in 0 until 256) dict1[i] = u32(huff, cache + i * 4)
            for (i in 1..32) {
                minCode[i] = u32(huff, base + (i - 1) * 8) shl (32 - i)
                maxCode[i] = ((u32(huff, base + (i - 1) * 8 + 4) + 1) shl (32 - i)) - 1
            }
            for (i in 1 until count) {
                val cdic = record(at + i)
                require(String(cdic, 0, 4, Charsets.ISO_8859_1) == "CDIC") { "BOOK_UNAVAILABLE" }
                val phrases = u32(cdic, 8).toInt(); val bits = u32(cdic, 12).toInt()
                val n = minOf(1 shl bits, phrases - entries.size)
                for (j in 0 until n) {
                    val offset = u16(cdic, 16 + j * 2)
                    val length = u16(cdic, 16 + offset)
                    val start = 18 + offset
                    entries += cdic.copyOfRange(start, minOf(cdic.size, start + (length and 0x7fff)))
                    literal += length and 0x8000 != 0
                }
            }
        }

        fun unpack(data: ByteArray, depth: Int = 0): ByteArray {
            require(depth < 32) { "BOOK_UNAVAILABLE" }
            val out = java.io.ByteArrayOutputStream(data.size * 3)
            val padded = data.copyOf(data.size + 8)
            var bitsLeft = data.size * 8L
            var position = 0
            var x = readLong(padded, 0)
            var n = 32
            while (true) {
                if (n <= 0) { position += 4; x = readLong(padded, position); n += 32 }
                val code = (x ushr n) and 0xFFFFFFFFL
                var entry = dict1[(code ushr 24).toInt()]
                var length = (entry and 0x1f).toInt()
                var maximum: Long
                if (entry and 0x80 == 0L) {
                    while (code < minCode[length]) length++
                    maximum = maxCode[length]
                } else maximum = ((entry ushr 8) shl (32 - length)) or ((1L shl (32 - length)) - 1)
                n -= length
                bitsLeft -= length
                if (bitsLeft < 0) break
                val index = ((maximum - code) ushr (32 - length)).toInt()
                require(index in entries.indices) { "BOOK_UNAVAILABLE" }
                var phrase = entries[index]!!
                if (!literal[index]) {
                    phrase = unpack(phrase, depth + 1)
                    entries[index] = phrase; literal[index] = true
                }
                out.write(phrase)
            }
            return out.toByteArray()
        }

        private fun readLong(data: ByteArray, at: Int): Long {
            var value = 0L
            for (i in 0 until 8) value = (value shl 8) or (data.getOrElse(at + i) { 0 }.toLong() and 0xff)
            return value
        }
    }

    internal companion object {
        /** A Palm database holding a Kindle or PalmDOC book, by its type and creator. */
        fun palm(file: File): Boolean = runCatching {
            RandomAccessFile(file, "r").use { access ->
                if (access.length() < 78) return@use false
                access.seek(60)
                String(ByteArray(8).also(access::readFully), Charsets.ISO_8859_1) in setOf("BOOKMOBI", "TEXtREAd")
            }
        }.getOrDefault(false)

        fun u16(data: ByteArray, at: Int) = if (at + 2 <= data.size) ((data[at].toInt() and 0xff) shl 8) or (data[at + 1].toInt() and 0xff) else 0
        fun u32(data: ByteArray, at: Int): Long = if (at + 4 <= data.size)
            ((data[at].toLong() and 0xff) shl 24) or ((data[at + 1].toLong() and 0xff) shl 16) or
                ((data[at + 2].toLong() and 0xff) shl 8) or (data[at + 3].toLong() and 0xff) else 0L

        /** Bytes at the end of a text record that are not text: one entry per flag bit, multibyte overlap last. */
        fun trailing(data: ByteArray, flags: Int): Int {
            var size = 0
            var bits = flags ushr 1
            while (bits != 0) {
                if (bits and 1 != 0) {
                    var value = 0
                    val end = data.size - size
                    for (i in maxOf(0, end - 4) until end) {
                        val b = data[i].toInt() and 0xff
                        if (b and 0x80 != 0) value = 0
                        value = (value shl 7) or (b and 0x7f)
                    }
                    size += value
                }
                bits = bits ushr 1
            }
            if (flags and 1 != 0 && data.size - size - 1 >= 0) size += (data[data.size - size - 1].toInt() and 3) + 1
            return size.coerceAtMost(data.size)
        }

        fun palmdoc(data: ByteArray, size: Int, out: java.io.ByteArrayOutputStream) {
            var buffer = ByteArray(maxOf(4096, size * 4))
            var length = 0
            fun put(b: Int) {
                if (length == buffer.size) buffer = buffer.copyOf(buffer.size * 2)
                buffer[length++] = b.toByte()
            }
            var i = 0
            while (i < size) {
                val c = data[i++].toInt() and 0xff
                when {
                    c == 0 || c in 9..0x7f -> put(c)
                    c in 1..8 -> { val end = minOf(size, i + c); while (i < end) put(data[i++].toInt()) }
                    c >= 0xc0 -> { put(' '.code); put(c xor 0x80) }
                    else -> {
                        if (i >= size) break
                        val pair = (c shl 8) or (data[i++].toInt() and 0xff)
                        val distance = (pair ushr 3) and 0x7ff
                        if (distance <= 0 || distance > length) continue
                        repeat((pair and 7) + 3) { put(buffer[length - distance].toInt()) }
                    }
                }
            }
            out.write(buffer, 0, length)
        }
    }
}
