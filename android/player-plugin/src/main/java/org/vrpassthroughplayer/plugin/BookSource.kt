package org.vrpassthroughplayer.plugin

import java.io.Closeable
import java.io.File
import java.nio.ByteBuffer
import java.nio.charset.Charset
import java.nio.charset.CodingErrorAction
import java.util.zip.ZipFile

internal class BookChapter(val title: String, val flow: BookFlow)
/** A table-of-contents row; [chapter] indexes [Book.chapters] and [anchor] may be empty. */
internal class BookContents(val title: String, val depth: Int, val chapter: Int, val anchor: String)

/** Parsed once per open. Layout and position never depend on how the text was packaged. */
internal interface Book : Closeable {
    val title: String
    val language: String
    val chapters: List<BookChapter>
    val contents: List<BookContents>
    fun resource(path: String): ByteArray?
}

internal object Books {
    const val RESOURCE_BYTES = 48L * 1024 * 1024
    const val TEXT_BYTES = 64L * 1024 * 1024
    val extensions = setOf("epub", "txt", "mobi", "azw3", "azw", "prc")

    /** The whole stream, or null when it holds more than [limit] bytes. */
    fun bounded(input: java.io.InputStream, limit: Long): ByteArray? {
        val out = java.io.ByteArrayOutputStream()
        val buffer = ByteArray(1 shl 16)
        while (true) {
            val read = input.read(buffer)
            if (read < 0) return out.toByteArray()
            if (out.size() + read > limit) return null
            out.write(buffer, 0, read)
        }
    }

    fun named(name: String) = name.substringBefore('?').substringBefore('#').substringAfterLast('.', "").lowercase() in extensions

    fun open(file: File, name: String): Book {
        val head = ByteArray(4)
        val read = file.inputStream().use { it.read(head) }
        if (read == 4 && head[0] == 'P'.code.toByte() && head[1] == 'K'.code.toByte()) return EpubBook(file)
        return if (MobiBook.palm(file)) MobiBook(file, name) else TextBook(file, name)
    }

    fun decode(bytes: ByteArray, declared: Boolean): String {
        if (bytes.size >= 3 && bytes[0] == 0xEF.toByte() && bytes[1] == 0xBB.toByte() && bytes[2] == 0xBF.toByte())
            return String(bytes, 3, bytes.size - 3, Charsets.UTF_8)
        if (bytes.size >= 2 && bytes[0] == 0xFF.toByte() && bytes[1] == 0xFE.toByte()) return String(bytes, 2, bytes.size - 2, Charsets.UTF_16LE)
        if (bytes.size >= 2 && bytes[0] == 0xFE.toByte() && bytes[1] == 0xFF.toByte()) return String(bytes, 2, bytes.size - 2, Charsets.UTF_16BE)
        if (declared) {
            val prolog = String(bytes, 0, minOf(bytes.size, 256), Charsets.ISO_8859_1)
            Regex("""encoding\s*=\s*["']([A-Za-z0-9_\-]+)["']""").find(prolog)?.groupValues?.get(1)?.let { label ->
                runCatching { Charset.forName(label) }.getOrNull()?.let { return String(bytes, it) }
            }
        }
        strict(bytes, "UTF-8")?.let { return it }
        // Big5 bytes nearly always decode as GB18030 too, into rare characters: when both decode, the one
        // that reads as everyday Chinese wins.
        val simplified = strict(bytes, "GB18030")
        val traditional = strict(bytes, "Big5")
        if (simplified != null && traditional != null) return if (everyday(traditional) > everyday(simplified)) traditional else simplified
        return simplified ?: traditional ?: String(bytes, Charset.forName("GB18030"))
    }

    /** The share of Han characters in a sample that are among the most common in simplified or traditional text. */
    fun everyday(text: String): Float {
        var han = 0; var common = 0
        for (c in text.take(20000)) {
            if (Character.UnicodeScript.of(c.code) != Character.UnicodeScript.HAN) continue
            han++
            if (c in COMMON) common++
        }
        return if (han == 0) 0f else common.toFloat() / han
    }

    private val COMMON = ("的一是不了人我在有他这中大来上国个到说们为子和你地出道也时年得就那要下以生会自着去之过家学对可她里后小么心多天而能好都然没日于起" +
        "还发成事只作当想看文无开手十用主行方又如前所本见经头面公同三已老从动两长知民样现分将外但身些与高意进把法此实回二理美点月明其种声全工己话儿者向情部正名定女问力" +
        "國會個們這來說時對後裡還發從現兩長樣將與實點話兒問為頭見經門開關無當於體學麼聽讓覺間東車書氣電寫處員機種動題歡愛認識應該錯誰給讀買賣錢張陳劉黃嗎吧呢").toSet()

    private fun strict(bytes: ByteArray, label: String): String? = runCatching {
        Charset.forName(label).newDecoder().onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes)).toString()
    }.getOrNull()

    /** Resolves [href] against the directory of [base]; both use '/' and stay inside the container. */
    fun join(base: String, href: String): String {
        val parts = ArrayList<String>(base.split('/').dropLast(1))
        val clean = href.substringBefore('#').substringBefore('?')
        if (clean.startsWith("/")) parts.clear()
        for (part in clean.split('/')) when (part) {
            "", "." -> {}
            ".." -> if (parts.isNotEmpty()) parts.removeAt(parts.size - 1)
            else -> parts += percent(part)
        }
        return parts.joinToString("/")
    }

    private fun percent(value: String): String {
        if ('%' !in value) return value
        return runCatching { java.net.URLDecoder.decode(value.replace("+", "%2B"), "UTF-8") }.getOrDefault(value)
    }
}

internal class EpubBook(file: File) : Book {
    private val zip = ZipFile(file)
    private val folded = HashMap<String, String>()
    override var title = ""; private set
    override var language = ""; private set
    override val chapters: List<BookChapter>
    override val contents: List<BookContents>

    init {
        try {
            for (entry in zip.entries()) folded.putIfAbsent(entry.name.lowercase(), entry.name)
            protection()
            val container = text("META-INF/container.xml") ?: error("BOOK_UNAVAILABLE")
            val root = Regex("""full-path\s*=\s*["']([^"']+)["']""").find(container)?.groupValues?.get(1) ?: error("BOOK_UNAVAILABLE")
            val items = LinkedHashMap<String, Array<String>>() // id -> path, media type, properties
            val spine = ArrayList<String>()
            var tocId = ""
            var field = ""
            BookMarkup.scan(text(root) ?: error("BOOK_UNAVAILABLE"), { tag ->
                field = if (tag.closing || tag.empty) "" else tag.name
                if (tag.closing) return@scan
                when (tag.name) {
                    "item" -> tag.attributes["id"]?.let { id ->
                        items[id] = arrayOf(Books.join(root, tag.attributes["href"] ?: ""), tag.attributes["media-type"] ?: "", tag.attributes["properties"] ?: "") }
                    "itemref" -> if (!tag.attributes["linear"].equals("no", true)) tag.attributes["idref"]?.let(spine::add)
                    "spine" -> tocId = tag.attributes["toc"] ?: ""
                }
            }, { value ->
                val clean = value.trim()
                if (clean.isEmpty()) return@scan
                if (field == "title" && title.isEmpty()) title = clean
                if (field == "language" && language.isEmpty()) language = clean
            })
            val documents = spine.mapNotNull { items[it] }.filter {
                it[1].contains("html", true) || it[0].substringAfterLast('.').lowercase() in setOf("xhtml", "html", "htm", "xml") }
            require(documents.isNotEmpty()) { "BOOK_UNAVAILABLE" }
            val listed = navigation(items.values.firstOrNull { "nav" in it[2].split(' ') }?.get(0),
                (items[tocId] ?: items.values.firstOrNull { it[1] == "application/x-dtbncx+xml" })?.get(0))
            val parsed = ArrayList<BookChapter>()
            val index = HashMap<String, Int>()
            var characters = 0L
            for (document in documents) {
                val source = text(document[0]) ?: continue
                characters += source.length
                require(characters <= Books.TEXT_BYTES) { "BOOK_UNAVAILABLE" }
                val flow = BookMarkup.flow(source) { Books.join(document[0], it) }
                index[document[0]] = parsed.size // Empty wrappers still let their links reach the next chapter.
                if (flow.blocks.isEmpty()) continue
                val name = listed.firstOrNull { it.path == document[0] }?.title
                    ?: (flow.blocks.firstOrNull { it is BookBlock.Text && it.heading > 0 } as? BookBlock.Text)?.text ?: ""
                parsed += BookChapter(name, flow)
            }
            require(parsed.isNotEmpty()) { "BOOK_UNAVAILABLE" }
            chapters = parsed
            contents = listed.mapNotNull { row ->
                val chapter = index[row.path] ?: return@mapNotNull null
                if (chapter >= parsed.size) null else BookContents(row.title, row.depth, chapter, row.anchor)
            }
        } catch (error: Throwable) { zip.close(); throw error }
    }

    private class Row(val title: String, val path: String, val anchor: String, val depth: Int)

    /** Font obfuscation is not DRM; any other encrypted resource is. */
    private fun protection() {
        val encryption = text("META-INF/encryption.xml") ?: return
        BookMarkup.scan(encryption, { tag ->
            if (tag.name == "encryptionmethod" && !tag.closing) {
                val algorithm = tag.attributes["algorithm"] ?: ""
                require("embedding" in algorithm || "ns.adobe.com/pdf/enc#RC" in algorithm) { "BOOK_PROTECTED" }
            }
        }, {})
    }

    private fun navigation(nav: String?, ncx: String?): List<Row> {
        val rows = ArrayList<Row>()
        if (nav != null) text(nav)?.let { source ->
            var inside = 0; var done = false; var depth = 0
            var href: String? = null
            val label = StringBuilder()
            BookMarkup.scan(source, { tag ->
                when (tag.name) {
                    "nav" -> if (tag.closing) { if (inside > 0) { inside = 0; done = rows.isNotEmpty() } }
                        else if (!done && (tag.attributes["epub:type"] ?: "toc").contains("toc")) inside = 1
                    "ol", "ul" -> if (inside > 0) depth = maxOf(0, depth + if (tag.closing) -1 else 1)
                    "a" -> if (inside > 0) {
                        if (tag.closing) {
                            val target = href; href = null
                            val name = label.toString().trim().replace(Regex("\\s+"), " ")
                            if (target != null && name.isNotEmpty()) rows += Row(name, Books.join(nav, target), target.substringAfter('#', ""), maxOf(0, depth - 1))
                        } else { href = tag.attributes["href"]; label.setLength(0) }
                    }
                }
            }, { if (inside > 0 && href != null) label.append(it) })
        }
        if (rows.isEmpty() && ncx != null) text(ncx)?.let { source ->
            var depth = 0; var field = ""; var name = ""
            BookMarkup.scan(source, { tag ->
                field = if (tag.closing || tag.empty) "" else tag.name
                when (tag.name) {
                    "navpoint" -> depth = maxOf(0, depth + if (tag.closing) -1 else 1)
                    "content" -> if (!tag.closing && depth > 0) tag.attributes["src"]?.let { target ->
                        if (name.isNotEmpty()) rows += Row(name, Books.join(ncx, target), target.substringAfter('#', ""), depth - 1); name = "" }
                }
            }, { if (field == "text" && it.isNotBlank()) name = it.trim().replace(Regex("\\s+"), " ") })
        }
        return rows
    }

    private fun entry(path: String) = zip.getEntry(path) ?: folded[path.lowercase()]?.let(zip::getEntry)
    private fun text(path: String) = resource(path)?.let { Books.decode(it, true) }
    override fun resource(path: String): ByteArray? {
        val entry = entry(path) ?: return null
        if (entry.isDirectory || entry.size > Books.RESOURCE_BYTES) return null
        // The header's size can lie: stop reading at the limit rather than trust it.
        return zip.getInputStream(entry).use { Books.bounded(it, Books.RESOURCE_BYTES) }
    }
    override fun close() = zip.close()
}

internal class TextBook(file: File, name: String) : Book {
    override val title = name.substringAfterLast('/').substringBeforeLast('.')
    override val language = ""
    override val chapters: List<BookChapter>
    override val contents: List<BookContents>

    init {
        require(file.length() in 1..Books.TEXT_BYTES) { "BOOK_UNAVAILABLE" }
        val parsed = ArrayList<BookChapter>()
        var blocks = ArrayList<BookBlock>()
        var heading = ""
        fun finish() {
            if (blocks.isNotEmpty()) parsed += BookChapter(heading, BookFlow(blocks, emptyMap()))
            blocks = ArrayList()
        }
        for (raw in Books.decode(file.readBytes(), false).lineSequence()) {
            val line = raw.trim { it.isWhitespace() || it == '　' || it == ' ' || it == '﻿' }
            if (line.isEmpty()) continue
            if (line.length <= 48 && chapter.matches(line)) {
                finish(); heading = line
                blocks += BookBlock.Text(line, emptyList(), 2, true)
            } else blocks += BookBlock.Text(line, emptyList(), 0, false)
        }
        finish()
        require(parsed.isNotEmpty()) { "BOOK_UNAVAILABLE" }
        chapters = parsed
        // Serials grouped in volumes list their chapters one level in.
        val volumes = parsed.any { volume.matches(it.title) }
        contents = parsed.mapIndexedNotNull { index, item ->
            if (item.title.isEmpty()) null else BookContents(item.title, if (volumes && !volume.matches(item.title)) 1 else 0, index, "") }
    }

    override fun resource(path: String): ByteArray? = null
    override fun close() {}

    internal companion object {
        val volume = Regex("""^第[0-9０-９零〇一二三四五六七八九十百千万两]{1,9}[卷部集篇](?![0-9０-９零〇一二三四五六七八九十百千万两]{1,9}[章回节]).{0,40}$""")
        val chapter = Regex("""^(第[0-9０-９零〇一二三四五六七八九十百千万两]{1,9}[章回卷节部篇集幕话折].{0,40}|(?i:chapter|part|book|prologue|epilogue)\b.{0,40}|序[章言幕曲]?|楔子|引子|前言|后记|後記|尾声|尾聲|终章|終章|番外.{0,30})$""")
    }
}
