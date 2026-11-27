package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import java.nio.charset.Charset
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

class BookSourceTest {
    private fun temp(suffix: String) = File.createTempFile("book-", suffix).also { it.deleteOnExit() }
    private fun texts(flow: BookFlow) = flow.blocks.filterIsInstance<BookBlock.Text>()

    @Test fun markupKeepsParagraphsStylesAndImagesWithoutValidXml() {
        val flow = BookMarkup.flow("""<html><head><title>x</title><style>p > a { }</style></head><body>
            <h2 id="c1">第一章&nbsp;起</h2><p>　　他说：<b>“走 &amp; 留”</b>，然后<br/>离开。</p>
            <p align="center">1 < 2 &unknown; &#x4e2d;</p><div><img src="../Images/a%20b.jpg"/></div>
            <ul><li><p>甲</p></li><li>乙</li></ul><ruby>漢<rt>かん</rt></ruby>""") { Books.join("Text/c1.xhtml", it) }
        val text = texts(flow)
        assertEquals(listOf("第一章 起", "他说：“走 & 留”，然后", "离开。", "1 < 2 &unknown; 中", "• 甲", "• 乙", "漢"), text.map { it.text })
        assertEquals(2, text[0].heading); assertTrue(text[0].centered)
        assertEquals(listOf(3 to 10), text[1].spans.filter { it.style == BookSpan.BOLD }.map { it.start to it.end })
        assertTrue(text[3].centered); assertFalse(text[1].centered)
        assertEquals("Images/a b.jpg", (flow.blocks.first { it is BookBlock.Image } as BookBlock.Image).path)
        assertEquals(0, flow.anchors["c1"])
    }

    @Test fun printedLinesFromPdfConversionsRejoinIntoParagraphs() {
        val full = "甲乙丙丁戊己庚辛壬癸子丑寅卯辰巳午未申酉"
        val lines = ArrayList<String>()
        repeat(4) { paragraph ->
            repeat(3) { lines += full.substring(0, 19) + "，" }
            lines += "完${paragraph}。"
        }
        lines[1] = "<b>" + lines[1].substring(0, 2) + "</b>" + lines[1].substring(2)
        val html = lines.withIndex().joinToString("") { (index, line) ->
            if (index == 4) "<p id=\"two\">$line</p>" else "<p>$line</p>" } + "<p id=\"end\">1931年起，Thru3D Media Player plays files</p>"
        val flow = BookMarkup.flow("<h1>章</h1>$html")
        val text = texts(flow)
        assertEquals(6, text.size)
        assertEquals(full.substring(0, 19) + "，" + full.substring(0, 19) + "，", text[1].text.substring(0, 40))
        assertTrue(text[1].text.endsWith("完0。")); assertTrue(text[2].text.startsWith(full.substring(0, 19)))
        assertEquals(listOf(20 to 22), text[1].spans.map { it.start to it.end })
        assertEquals(2, flow.anchors["two"]); assertEquals(5, flow.anchors["end"])
    }

    @Test fun ordinaryParagraphsPoemsAndCodeAreNotRejoined() {
        val prose = (1..16).joinToString("") { "<p>" + "字".repeat(5 + it * 7 % 60) + "，</p>" }
        assertEquals(16, texts(BookMarkup.flow(prose)).size)
        val poem = (1..16).joinToString("") { "<p>床前明月光疑是，</p>" }
        assertEquals(16, texts(BookMarkup.flow(poem)).size)
        val code = "<pre>" + (1..16).joinToString("\n") { "val x = listOf(1, 2, 3, 4, 5, 6, 7, 8, 9)" } + "</pre>"
        assertEquals(16, texts(BookMarkup.flow(code)).size)
    }

    @Test(timeout = 10000) fun damagedHuffmanTableFailsInsteadOfSpinning() {
        fun be(value: Int) = byteArrayOf((value ushr 24).toByte(), (value ushr 16).toByte(), (value ushr 8).toByte(), value.toByte())
        val head = ByteArray(120).also { be(0).copyInto(it, 112); be(2).copyInto(it, 116) }
        // Every first-level entry says "code length 0": a decoder that trusts it never consumes a bit.
        val huff = "HUFF".toByteArray() + ByteArray(4) + be(16) + be(16 + 1024) + ByteArray(1024) + ByteArray(32 * 8)
        val cdic = "CDIC".toByteArray() + ByteArray(4) + be(0) + be(1)
        val huffman = MobiBook.Huffman(head, 0) { if (it == 0) huff else cdic }
        assertThrows(IllegalArgumentException::class.java) { huffman.unpack(byteArrayOf(1, 2, 3, 4, 5, 6, 7, 8)) }
    }

    @Test fun resourcesAreReadNoFurtherThanTheLimit() {
        assertEquals(10, Books.bounded(java.io.ByteArrayInputStream(ByteArray(10)), 10)?.size)
        assertNull(Books.bounded(java.io.ByteArrayInputStream(ByteArray(11)), 10))
    }

    @Test fun epubFollowsSpineOrderAndNamesChaptersFromTheContents() {
        val file = temp(".epub")
        ZipOutputStream(file.outputStream()).use { zip ->
            fun put(name: String, body: String) { zip.putNextEntry(ZipEntry(name)); zip.write(body.toByteArray()); zip.closeEntry() }
            put("mimetype", "application/epub+zip")
            put("META-INF/container.xml", """<container><rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles></container>""")
            put("OEBPS/content.opf", """<package><metadata><dc:title>样书</dc:title><dc:language>zh-CN</dc:language></metadata>
                <manifest><item id="b" href="Text/b.xhtml" media-type="application/xhtml+xml"/>
                <item id="a" href="Text/a.xhtml" media-type="application/xhtml+xml"/>
                <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/></manifest>
                <spine toc="ncx"><itemref idref="a"/><itemref idref="b"/></spine></package>""")
            put("OEBPS/toc.ncx", """<ncx><navMap><navPoint><navLabel><text>序</text></navLabel><content src="Text/a.xhtml"/>
                <navPoint><navLabel><text>正文</text></navLabel><content src="Text/b.xhtml#p2"/></navPoint></navPoint></navMap></ncx>""")
            put("OEBPS/Text/a.xhtml", "<html><body><p>甲</p></body></html>")
            put("OEBPS/Text/b.xhtml", "<html><body><p>乙</p><p id=\"p2\">丙</p></body></html>")
        }
        Books.open(file, "x.epub").use { book ->
            assertEquals("样书", book.title); assertEquals("zh-CN", book.language)
            assertEquals(listOf("序", "正文"), book.chapters.map { it.title })
            assertEquals(listOf("甲"), texts(book.chapters[0].flow).map { it.text })
            assertEquals(listOf(0 to 0, 1 to 1), book.contents.map { it.depth to it.chapter })
            assertEquals(1, book.chapters[1].flow.anchors[book.contents[1].anchor])
        }
    }

    @Test fun encryptedContentIsReportedButFontObfuscationIsNot() {
        fun book(algorithm: String) = temp(".epub").also { file ->
            ZipOutputStream(file.outputStream()).use { zip ->
                fun put(name: String, body: String) { zip.putNextEntry(ZipEntry(name)); zip.write(body.toByteArray()); zip.closeEntry() }
                put("META-INF/encryption.xml", """<encryption><enc:EncryptedData><enc:EncryptionMethod Algorithm="$algorithm"/></enc:EncryptedData></encryption>""")
                put("META-INF/container.xml", """<rootfile full-path="c.opf"/>""")
                put("c.opf", """<package><manifest><item id="a" href="a.html" media-type="text/html"/></manifest><spine><itemref idref="a"/></spine></package>""")
                put("a.html", "<p>甲</p>")
            }
        }
        Books.open(book("http://www.idpf.org/2008/embedding"), "a.epub").close()
        assertEquals("BOOK_PROTECTED", assertThrows(IllegalArgumentException::class.java) {
            Books.open(book("http://www.w3.org/2001/04/xmlenc#aes256-cbc"), "a.epub") }.message)
    }

    @Test fun plainTextDetectsLegacyChineseEncodingAndChapterHeadings() {
        val file = temp(".txt")
        file.writeBytes("书名\r\n\r\n第一章 风起\r\n　　正文一。\r\n正文二。\r\n第二章 云涌\r\n正文三。".toByteArray(Charset.forName("GB18030")))
        Books.open(file, "file:///books/长篇.txt").use { book ->
            assertEquals("长篇", book.title)
            assertEquals(listOf("", "第一章 风起", "第二章 云涌"), book.chapters.map { it.title })
            assertEquals(listOf("第一章 风起", "正文一。", "正文二。"), texts(book.chapters[1].flow).map { it.text })
            assertEquals(listOf(1, 2), book.contents.map { it.chapter })
        }
    }

    @Test fun traditionalChineseTextIsNotReadAsSimplified() {
        val file = temp(".txt")
        file.writeBytes("第一章 開始\n他們說這個時候還沒有來，於是我們就從門口走進去了。".toByteArray(Charset.forName("Big5")))
        Books.open(file, "file:///books/繁體.txt").use { book ->
            assertEquals("第一章 開始", book.chapters[0].title)
        }
    }

    @Test fun theLanguageReadAloudAndOfferedFontsComesFromTheText() {
        val chinese = temp(".txt"); chinese.writeText("第一章 开始\n作为一种普遍的经济生产模式，历史学家对西方资本主义兴起的解释一直见仁见智。")
        Books.open(chinese, "a.txt").use { assertEquals("zh", BookPages.script(it)) }
        val japanese = temp(".txt"); japanese.writeText("第一章\n吾輩は猫である。名前はまだ無い。どこで生れたかとんと見当がつかぬ。")
        Books.open(japanese, "b.txt").use { assertEquals("ja", BookPages.script(it)) }
        val english = temp(".txt"); english.writeText("Chapter One\nIt was the best of times, it was the worst of times, it was the age of wisdom.")
        Books.open(english, "c.txt").use { assertEquals("en", BookPages.script(it)) }
    }

    @Test fun serialVolumesHoldTheirChaptersOneLevelIn() {
        val file = temp(".txt")
        file.writeText("第一卷 风起\n第一章 甲\n正文\n第二章 乙\n正文\n第二卷 云涌\n第三章 丙\n正文")
        Books.open(file, "a.txt").use { book ->
            assertEquals(listOf(0, 1, 1, 0, 1), book.contents.map { it.depth })
        }
    }

    @Test fun searchFindsWordsInReadingOrderAndBookmarksNameTheirPlace() {
        val file = temp(".txt")
        file.writeText(listOf("第一章 风起", "天亮了，他还没醒。", "第二章 云涌", "Dawn came. Then dawn again.", "天亮以后").joinToString("\n"))
        Books.open(file, "a.txt").use { book ->
            val found = BookSearch.find(book, "天亮", 10) { false }
            val hits = found.getJSONArray("hits")
            assertEquals(listOf("0/1/0", "1/2/0"), (0 until hits.length()).map { hits.getJSONObject(it).getString("at") })
            assertEquals("第一章 风起", hits.getJSONObject(0).getString("chapter"))
            val first = hits.getJSONObject(0)
            val mark = first.getJSONArray("mark")
            assertEquals("天亮", first.getString("text").substring(mark.getInt(0), mark.getInt(0) + mark.getInt(1)))
            // Case does not matter, and the limit is reported.
            val dawn = BookSearch.find(book, "DAWN", 1) { false }
            assertEquals(1, dawn.getJSONArray("hits").length()); assertTrue(dawn.getBoolean("more"))
            assertEquals(0, BookSearch.find(book, "天亮", 10) { true }.getJSONArray("hits").length())
            assertEquals("他还没醒。", BookSearch.excerpt(book, "0/1/4"))
            assertEquals("", BookSearch.excerpt(book, "9/0/0"))
        }
    }

    /** A Kindle file in PalmDOC compression with the trailing multibyte entry every record carries. */
    @Test fun mobiTextDecompressesAndBreaksAtPageBreaks() {
        val html = "<html><body><h1>第一章</h1><p>甲乙丙。甲乙丙。</p><mbp:pagebreak/><h1>第二章</h1><p>丁</p><img recindex=\"00001\"/></body></html>"
        val raw = html.toByteArray(Charsets.UTF_8)
        // Literal runs only (codes 1..8 copy that many bytes), then one back-reference to the repeated sentence.
        val packed = java.io.ByteArrayOutputStream()
        for (chunk in raw.toList().chunked(8)) { packed.write(chunk.size); packed.write(chunk.toByteArray()) }
        val text = packed.toByteArray() + byteArrayOf(0) // multibyte trailing entry: zero extra bytes
        val picture = byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0xFF.toByte(), 0xE0.toByte())
        val head = ByteArray(0xF4)
        fun put16(at: Int, v: Int) { head[at] = (v shr 8).toByte(); head[at + 1] = v.toByte() }
        fun put32(at: Int, v: Long) { for (i in 0..3) head[at + i] = (v shr (24 - 8 * i)).toByte() }
        put16(0, 2); put32(4, raw.size.toLong()); put16(8, 1); put16(10, 4096)
        "MOBI".toByteArray().copyInto(head, 16); put32(20, 0xE8); put32(28, 65001); put32(36, 6)
        put32(108, 2); put16(0xF2, 1)
        val records = listOf(head, text, picture)
        val file = temp(".mobi")
        java.io.DataOutputStream(file.outputStream()).use { out ->
            out.write(ByteArray(60)); out.write("BOOKMOBI".toByteArray()); out.write(ByteArray(8)); out.writeShort(records.size)
            var offset = 78 + records.size * 8 + 2
            for (record in records) { out.writeInt(offset); out.writeInt(0); offset += record.size }
            out.writeShort(0)
            records.forEach(out::write)
        }
        Books.open(file, "a.mobi").use { book ->
            assertEquals(listOf("第一章", "第二章"), book.chapters.map { it.title })
            assertEquals("甲乙丙。甲乙丙。", texts(book.chapters[0].flow)[1].text)
            val image = book.chapters[1].flow.blocks.filterIsInstance<BookBlock.Image>().single()
            assertArrayEquals(picture, book.resource(image.path))
        }
        val decoded = java.io.ByteArrayOutputStream()
        // "abcabcabc": three literals, then a copy of 6 bytes from 3 back.
        MobiBook.palmdoc(byteArrayOf(3, 'a'.code.toByte(), 'b'.code.toByte(), 'c'.code.toByte(), 0x80.toByte(), (3 shl 3 or 3).toByte()), 6, decoded)
        assertEquals("abcabcabc", decoded.toString("UTF-8"))
    }

    /** Survey of real books: set BOOK_SAMPLES to a folder (and BOOK_SAMPLE_LIMIT); prints what fails to parse. */
    @Test fun sampleLibraryParses() {
        val root = System.getenv("BOOK_SAMPLES")?.let(::File)
        assumeTrue(root != null && root.isDirectory)
        val limit = System.getenv("BOOK_SAMPLE_LIMIT")?.toIntOrNull() ?: 400
        val files = root!!.walkTopDown().filter { it.isFile && Books.named(it.name) }.toList().shuffled(java.util.Random(7)).take(limit)
        class Tally { var books = 0; var failed = 0; var sparse = 0; var untitled = 0; var pictures = 0; var missing = 0; var millis = 0L; var slowest = 0L }
        val tallies = java.util.TreeMap<String, Tally>()
        for (file in files) {
            val tally = tallies.getOrPut(file.extension.lowercase()) { Tally() }
            tally.books++
            val started = System.nanoTime()
            try {
                Books.open(file, file.name).use { book ->
                    val count = book.chapters.sumOf { chapter -> chapter.flow.blocks.sumOf { (it as? BookBlock.Text)?.text?.length ?: 0 } }
                    val images = book.chapters.flatMap { chapter -> chapter.flow.blocks.filterIsInstance<BookBlock.Image>() }
                    tally.pictures += images.size
                    val lost = images.count { book.resource(it.path) == null }
                    tally.missing += lost
                    if (lost > 0) println("PICTURES ${file.name} missing=$lost of ${images.size} first=${images.first().path}")
                    if (count < 200 && images.isEmpty()) { tally.sparse++; println("SPARSE ${file.name} chars=$count chapters=${book.chapters.size}") }
                    if (book.contents.isEmpty()) tally.untitled++
                }
            } catch (error: Throwable) { tally.failed++; println("FAILED ${file.name}: ${error.message}") }
            val millis = (System.nanoTime() - started) / 1_000_000
            tally.millis += millis; tally.slowest = maxOf(tally.slowest, millis)
            if (millis > 3000) println("SLOW ${file.name} ${millis}ms")
        }
        for ((kind, t) in tallies) println("SUMMARY $kind books=${t.books} failed=${t.failed} sparse=${t.sparse} without_contents=${t.untitled} pictures=${t.pictures} missing=${t.missing} average_ms=${t.millis / maxOf(1, t.books)} slowest_ms=${t.slowest}")
    }
}
