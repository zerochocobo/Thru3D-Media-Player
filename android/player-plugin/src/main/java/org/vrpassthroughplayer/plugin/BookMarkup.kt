package org.vrpassthroughplayer.plugin

internal class BookSpan(val start: Int, val end: Int, val style: Int) {
    companion object { const val BOLD = 1; const val ITALIC = 2; const val RAISED = 4; const val LOWERED = 8 }
}

internal sealed class BookBlock {
    /** [heading] is 0 for body text, otherwise the h1..h6 level. */
    class Text(val text: String, val spans: List<BookSpan>, val heading: Int, val centered: Boolean) : BookBlock()
    class Image(val path: String) : BookBlock()
}

/** [anchors] map element ids to the block that starts at or after them. */
internal class BookFlow(val blocks: List<BookBlock>, val anchors: Map<String, Int>)

/** Tolerant tag scanner plus the reflowable subset the reader lays out. Real books are rarely valid XML. */
internal object BookMarkup {
    class Tag(val name: String, val attributes: Map<String, String>, val closing: Boolean, val empty: Boolean)

    private val entities = mapOf("nbsp" to " ", "amp" to "&", "lt" to "<", "gt" to ">", "quot" to "\"", "apos" to "'",
        "mdash" to "—", "ndash" to "–", "hellip" to "…", "ldquo" to "“", "rdquo" to "”", "lsquo" to "‘", "rsquo" to "’",
        "middot" to "·", "copy" to "©", "reg" to "®", "trade" to "™", "emsp" to " ", "ensp" to " ",
        "thinsp" to " ", "times" to "×", "bull" to "•", "laquo" to "«", "raquo" to "»", "deg" to "°", "shy" to "")
    private val raw = setOf("script", "style")
    private val hidden = setOf("head", "script", "style", "template", "rt", "rp")
    private val blocks = setOf("p", "div", "li", "blockquote", "section", "article", "aside", "header", "footer", "nav",
        "figure", "figcaption", "table", "tr", "ul", "ol", "dl", "dt", "dd", "pre", "center", "body", "html", "address",
        "main", "h1", "h2", "h3", "h4", "h5", "h6")
    private val inline = mapOf("b" to BookSpan.BOLD, "strong" to BookSpan.BOLD, "i" to BookSpan.ITALIC,
        "em" to BookSpan.ITALIC, "cite" to BookSpan.ITALIC, "sup" to BookSpan.RAISED, "sub" to BookSpan.LOWERED)

    fun unescape(text: String): String {
        if ('&' !in text) return text
        val out = StringBuilder(text.length)
        var at = 0
        while (at < text.length) {
            val amp = text.indexOf('&', at)
            if (amp < 0) { out.append(text, at, text.length); break }
            out.append(text, at, amp)
            val end = text.indexOf(';', amp)
            val name = if (end in amp + 2..amp + 10) text.substring(amp + 1, end) else ""
            val value = when {
                name.startsWith("#x") || name.startsWith("#X") -> name.substring(2).toIntOrNull(16)?.let(::codePoint)
                name.startsWith("#") -> name.substring(1).toIntOrNull()?.let(::codePoint)
                else -> entities[name]
            }
            if (value == null) { out.append('&'); at = amp + 1 } else { out.append(value); at = end + 1 }
        }
        return out.toString()
    }

    private fun codePoint(value: Int) = if (value in 1..0x10ffff && value !in 0xd800..0xdfff) String(Character.toChars(value)) else null

    fun scan(source: String, tag: (Tag) -> Unit, text: (String) -> Unit) {
        var at = 0
        val length = source.length
        while (at < length) {
            val open = source.indexOf('<', at)
            if (open < 0) { text(unescape(source.substring(at))); return }
            if (open > at) text(unescape(source.substring(at, open)))
            if (source.startsWith("<!--", open)) { at = source.indexOf("-->", open + 4).let { if (it < 0) length else it + 3 }; continue }
            if (source.startsWith("<![CDATA[", open)) {
                val end = source.indexOf("]]>", open + 9).let { if (it < 0) length else it }
                text(source.substring(open + 9, end)); at = minOf(length, end + 3); continue
            }
            val next = source.getOrElse(open + 1) { ' ' }
            if (next == '!' || next == '?') { at = source.indexOf('>', open).let { if (it < 0) length else it + 1 }; continue }
            if (next != '/' && !next.isLetter()) { text("<"); at = open + 1; continue }
            var cursor = open + 1
            val closing = next == '/'
            if (closing) cursor++
            val nameStart = cursor
            while (cursor < length && !source[cursor].isWhitespace() && source[cursor] != '>' && source[cursor] != '/') cursor++
            val name = source.substring(nameStart, cursor).substringAfter(':').lowercase()
            val attributes = LinkedHashMap<String, String>()
            var empty = false
            while (cursor < length && source[cursor] != '>') {
                val c = source[cursor]
                if (c.isWhitespace()) { cursor++; continue }
                if (c == '/') { empty = true; cursor++; continue }
                val keyStart = cursor
                while (cursor < length && !source[cursor].isWhitespace() && source[cursor] !in "=>/") cursor++
                val key = source.substring(keyStart, cursor).lowercase()
                while (cursor < length && source[cursor].isWhitespace()) cursor++
                var value = ""
                if (cursor < length && source[cursor] == '=') {
                    cursor++
                    while (cursor < length && source[cursor].isWhitespace()) cursor++
                    val quote = source.getOrElse(cursor) { '>' }
                    if (quote == '"' || quote == '\'') {
                        val end = source.indexOf(quote, cursor + 1).let { if (it < 0) length else it }
                        value = source.substring(minOf(length, cursor + 1), end); cursor = minOf(length, end + 1)
                    } else {
                        val valueStart = cursor
                        while (cursor < length && !source[cursor].isWhitespace() && source[cursor] != '>') cursor++
                        value = source.substring(valueStart, cursor)
                    }
                }
                if (key.isNotEmpty()) attributes[key] = unescape(value) else if (cursor == keyStart) cursor++
            }
            at = minOf(length, cursor + 1)
            if (name.isEmpty()) continue
            tag(Tag(name, attributes, closing, empty))
            if (!closing && !empty && name in raw) {
                // Script and style bodies may contain bare '<'.
                val end = source.indexOf("</$name", at, ignoreCase = true)
                at = if (end < 0) length else end
            }
        }
    }

    /** [resolve] turns an image reference into the book's own resource path, or "" to drop it. */
    fun flow(html: String, resolve: (String) -> String = { it }): BookFlow {
        val out = ArrayList<BookBlock>()
        val anchors = HashMap<String, Int>()
        val text = StringBuilder()
        val spans = ArrayList<BookSpan>()
        val styles = ArrayList<IntArray>() // style, start offset
        val names = ArrayList<String>()
        val open = ArrayList<Pair<String, Boolean>>() // block element, centred
        var heading = 0
        var skip = 0
        var pre = 0
        var bullet = false

        fun flush() {
            var end = text.length
            while (end > 0 && (text[end - 1].isWhitespace() || text[end - 1] == ' ')) end--
            for (style in styles) { if (style[1] < end) spans += BookSpan(style[1], end, style[0]); style[1] = 0 }
            if (end > 0) out += BookBlock.Text(text.substring(0, end), spans.filter { it.start < it.end }.map {
                BookSpan(it.start, minOf(it.end, end), it.style) }, heading, heading > 0 || open.any { it.second })
            text.setLength(0); spans.clear()
        }
        fun centred(tag: Tag) = tag.name == "center" || tag.attributes["align"].equals("center", true) ||
            tag.attributes["style"]?.replace(" ", "")?.contains("text-align:center", true) == true

        scan(html, { tag ->
            val name = tag.name
            if (name in hidden) {
                if (tag.closing) { if (skip > 0) skip-- } else if (!tag.empty) skip++
                return@scan
            }
            if (skip > 0) return@scan
            if (!tag.closing) (tag.attributes["id"] ?: tag.attributes["name"].takeIf { name == "a" })?.let {
                if (it.isNotEmpty()) anchors.putIfAbsent(it, out.size) }
            when {
                name == "br" -> flush()
                name == "hr" -> { flush(); out += BookBlock.Text("＊　＊　＊", emptyList(), 0, true) }
                name == "img" || name == "image" -> if (!tag.closing) {
                    // Old Kindle books number their pictures instead of naming them.
                    val source = tag.attributes["src"] ?: tag.attributes["xlink:href"] ?: tag.attributes["href"]
                        ?: tag.attributes["recindex"]?.let { "recindex:${it.trim().toIntOrNull() ?: 0}" } ?: ""
                    val path = if (source.isEmpty() || source.startsWith("data:", true)) "" else resolve(source)
                    if (path.isNotEmpty()) { flush(); out += BookBlock.Image(path) }
                }
                name == "td" || name == "th" -> if (tag.closing && text.isNotEmpty() && text.last() != ' ') text.append(' ')
                name in blocks -> {
                    flush()
                    if (tag.closing) {
                        val index = open.indexOfLast { it.first == name }
                        if (index >= 0) while (open.size > index) open.removeAt(open.size - 1)
                        if (name.length == 2 && name[0] == 'h') heading = 0
                        if (name == "pre" && pre > 0) pre--
                        if (name == "li") bullet = false
                    } else if (!tag.empty) {
                        open += name to centred(tag)
                        if (name.length == 2 && name[0] == 'h') heading = name[1] - '0'
                        if (name == "pre") pre++
                        if (name == "li") bullet = true
                    }
                }
                name in inline -> if (tag.closing) {
                    val index = names.lastIndexOf(name)
                    if (index >= 0) {
                        val style = styles.removeAt(index); names.removeAt(index)
                        if (style[1] < text.length) spans += BookSpan(style[1], text.length, style[0])
                    }
                } else if (!tag.empty) { names += name; styles += intArrayOf(inline.getValue(name), text.length) }
            }
        }, { piece ->
            if (skip > 0) return@scan
            for (c in piece) {
                if (pre > 0 && c == '\n') { flush(); continue }
                if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
                    if (text.isNotEmpty() && text.last() != ' ') text.append(' ')
                } else if (text.isEmpty() && (c == '　' || c == ' ')) continue // The reader indents paragraphs itself.
                else {
                    if (bullet && text.isEmpty()) text.append("• ")
                    bullet = false; text.append(c)
                }
            }
        })
        flush()
        return BookFlow(out, anchors)
    }
}
