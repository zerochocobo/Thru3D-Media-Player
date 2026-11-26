package org.vrpassthroughplayer.plugin

/** Finding words in a book's text, and the words at a reading position: plain text work, no layout. */
internal object BookSearch {
    const val SNIPPET_BEFORE = 14
    const val SNIPPET_AFTER = 30
    const val EXCERPT = 36

    /**
     * Every occurrence of [query] in reading order, ignoring case: the position, the chapter, and a line
     * of text around it with the match marked. The whole book is searched even while only part of it is
     * laid out; the reader maps each position to its page.
     */
    fun find(book: Book, query: String, limit: Int, cancelled: () -> Boolean): org.json.JSONObject {
        val wanted = query.replace(Regex("""\s+"""), " ").trim()
        val hits = org.json.JSONArray()
        var more = false
        if (wanted.isNotEmpty()) chapters@ for ((chapter, entry) in book.chapters.withIndex()) {
            if (cancelled()) break
            for ((index, block) in entry.flow.blocks.withIndex()) {
                val text = (block as? BookBlock.Text)?.text ?: continue
                var at = text.indexOf(wanted, 0, ignoreCase = true)
                while (at >= 0) {
                    if (hits.length() >= limit) { more = true; break@chapters }
                    val from = maxOf(0, at - SNIPPET_BEFORE); val to = minOf(text.length, at + wanted.length + SNIPPET_AFTER)
                    val lead = if (from > 0) "…" else ""
                    hits.put(org.json.JSONObject().put("at", "$chapter/$index/$at").put("chapter", entry.title)
                        .put("text", lead + text.substring(from, to) + if (to < text.length) "…" else "")
                        .put("mark", org.json.JSONArray(listOf(lead.length + at - from, wanted.length))))
                    at = text.indexOf(wanted, at + wanted.length, ignoreCase = true)
                }
            }
        }
        return org.json.JSONObject().put("hits", hits).put("more", more)
    }

    /** The first words from [at] on, across paragraphs, in one line. */
    fun excerpt(book: Book, at: String): String {
        val parts = at.split('/').mapNotNull { it.toIntOrNull() }
        if (parts.size != 3 || parts[0] !in book.chapters.indices) return ""
        val blocks = book.chapters[parts[0]].flow.blocks
        val words = StringBuilder()
        var index = parts[1]; var offset = parts[2]
        while (index in blocks.indices && words.length < EXCERPT) {
            val text = (blocks[index] as? BookBlock.Text)?.text
            if (text != null && offset < text.length) {
                if (words.isNotEmpty()) words.append(' ')
                words.append(text, offset.coerceAtLeast(0), minOf(text.length, offset.coerceAtLeast(0) + EXCERPT - words.length))
            }
            index++; offset = 0
        }
        return words.toString().replace(Regex("""\s+"""), " ").trim()
    }
}
