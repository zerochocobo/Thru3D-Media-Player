package org.vrpassthroughplayer.plugin

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import android.text.Layout
import android.text.SpannableString
import android.text.Spanned
import android.text.StaticLayout
import android.text.TextPaint
import android.text.TextUtils
import android.text.style.LeadingMarginSpan
import android.text.style.RelativeSizeSpan
import android.text.style.StyleSpan
import android.text.style.SubscriptSpan
import android.text.style.SuperscriptSpan
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.roundToInt

/**
 * Colours are opaque ARGB. [columns] full-width characters fill one line. [weight] thickens strokes as a
 * fraction of the type size: thin CJK strokes break up at headset pixel densities.
 */
internal class BookStyle(val columns: Int = 22, val spacing: Float = 1.75f, val paper: Int = 0xFFE9E2D0.toInt(),
    val ink: Int = 0xFF1D1B18.toInt(), val faint: Int = 0xFF8A8375.toInt(), val weight: Float = 0.012f,
    /** The reader's own words for the pages left in a chapter, with %d for the count; empty shows none. */
    val remaining: String = "",
    /** The space between paragraphs, in lines. */
    val paragraph: Float = 0.3f,
    /** How much of the widest text block a line fills: smaller leaves wider margins at the same type size. */
    val measure: Float = 1f,
    /** A downloaded font file for the text (absolute path, already checked by the bridge); empty: the system's. */
    val font: String = "") {
    /** What changes where the pages break, for the layout cache. */
    val key get() = "$columns/$spacing/$weight/$paragraph/$measure" +
        (if (font.isEmpty()) "" else java.io.File(font).let { "/${it.name}:${it.length()}" })
    fun withFont(path: String) = BookStyle(columns, spacing, paper, ink, faint, weight, remaining, paragraph, measure, path)
    companion object {
        /** Reader settings arrive as JSON; anything missing or out of range keeps its default. */
        fun parse(json: String): BookStyle {
            val value = runCatching { org.json.JSONObject(json) }.getOrDefault(org.json.JSONObject())
            val base = BookStyle()
            fun colour(key: String, fallback: Int) = runCatching { android.graphics.Color.parseColor(value.getString(key)) }.getOrDefault(fallback) or 0xFF000000.toInt()
            return BookStyle(value.optInt("columns", base.columns).coerceIn(12, 40), value.optDouble("spacing", base.spacing.toDouble()).toFloat().coerceIn(1.2f, 2.4f),
                colour("paper", base.paper), colour("ink", base.ink), colour("faint", base.faint),
                value.optDouble("weight", base.weight.toDouble()).toFloat().coerceIn(0f, 0.04f),
                value.optString("remaining", "").take(60).takeIf { it.count { c -> c == '%' } == 1 && "%d" in it } ?: "",
                value.optDouble("paragraph", base.paragraph.toDouble()).toFloat().coerceIn(0f, 1.5f),
                value.optDouble("measure", base.measure.toDouble()).toFloat().coerceIn(0.7f, 1f),
                value.optString("font", "").take(1024))
        }
    }
}

/**
 * Native pagination over a fixed logical page, so the page count and every position are independent
 * of the pixel size a consumer asks for. Rendering is only called from the book worker.
 */
/**
 * [only] lays out a run of chapters (the one being read, then a window around it), so the reader can
 * start at once while the whole book is paginated
 * in the background; such pages leave the book open for the whole layout that replaces them.
 */
internal class BookPages(private val book: Book, private val look: BookStyle, saved: java.io.File? = null,
    private val only: IntRange? = null) : BookSheets {
    /** [offset] and [end] bound the piece's characters within its block. */
    private class Piece(val chapter: Int, val block: Int, val from: Int, val to: Int, val top: Float, val height: Float,
        val offset: Int = 0, val end: Int = 0)
    private class Page(val chapter: Int, val pieces: List<Piece>)

    private val locale = book.language.lowercase().let {
        when {
            it.startsWith("zh-tw") || it.startsWith("zh-hk") || it.startsWith("zh-hant") -> Locale.TRADITIONAL_CHINESE
            it.startsWith("ja") -> Locale.JAPAN
            it.startsWith("ko") -> Locale.KOREA
            it.isEmpty() || it.startsWith("zh") -> Locale.SIMPLIFIED_CHINESE
            else -> Locale.forLanguageTag(book.language)
        }
    }
    /** The language the pages are read aloud in. */
    private val speech = script(book)
    private val face = BookFaces.load(look.font)
    /**
     * Line spacing is a multiple of the font's own line height, which differs between fonts (Noto
     * Serif's is far taller than the system's): scaled so a spacing step means the same everywhere.
     */
    private val lineScale = face?.let { own ->
        fun height(typeface: Typeface) = TextPaint().apply { textSize = 100f; this.typeface = typeface }.fontMetrics.let { it.descent - it.ascent }
        (height(Typeface.DEFAULT) / height(own)).takeIf { it.isFinite() && it in 0.5f..2f }
    } ?: 1f
    /** The type size follows [BookStyle.columns] across the widest block; margins only narrow the lines. */
    private val size = (CONTENT_WIDTH / look.columns).toFloat()
    private val measure = (CONTENT_WIDTH * look.measure).roundToInt()
    private val side = (WIDTH - measure) / 2f
    private val line = size * look.spacing

    /** Paints are mutable native objects: every thread that lays text out owns a set. */
    private inner class Setter {
        private val body = paint(size, false)
        private val headings = arrayOfNulls<TextPaint>(7)

        fun paint(textSize: Float, bold: Boolean) = TextPaint(Paint.ANTI_ALIAS_FLAG or Paint.SUBPIXEL_TEXT_FLAG).apply {
            this.textSize = textSize; color = look.ink; textLocale = locale; isLinearText = true
            // Adjacent CJK punctuation closes up, as typeset Chinese does, where the font supports it.
            fontFeatureSettings = "'chws'"
            typeface = when {
                face == null -> if (bold) Typeface.DEFAULT_BOLD else Typeface.DEFAULT
                bold -> Typeface.create(face, Typeface.BOLD)
                else -> face
            }
            if (look.weight > 0f && !bold) { style = Paint.Style.FILL_AND_STROKE; strokeWidth = textSize * look.weight }
        }

        fun layout(block: BookBlock.Text): StaticLayout {
            val level = block.heading.coerceIn(0, 6)
            val paint = if (level == 0) body else headings[level] ?: paint(size * when (level) {
                1 -> 1.5f; 2 -> 1.35f; 3 -> 1.2f; else -> 1.08f }, true).also { headings[level] = it }
            val text = SpannableString(block.text)
            if (!block.centered) text.setSpan(LeadingMarginSpan.Standard((size * 2).roundToInt(), 0), 0, text.length, Spanned.SPAN_INCLUSIVE_INCLUSIVE)
            for (span in block.spans) {
                val start = span.start.coerceIn(0, text.length); val end = span.end.coerceIn(start, text.length)
                if (start == end) continue
                if (span.style and BookSpan.BOLD != 0) text.setSpan(StyleSpan(Typeface.BOLD), start, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                if (span.style and BookSpan.ITALIC != 0) text.setSpan(StyleSpan(Typeface.ITALIC), start, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                if (span.style and (BookSpan.RAISED or BookSpan.LOWERED) != 0) {
                    text.setSpan(if (span.style and BookSpan.RAISED != 0) SuperscriptSpan() else SubscriptSpan(), start, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                    text.setSpan(RelativeSizeSpan(0.68f), start, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                }
            }
            return StaticLayout.Builder.obtain(text, 0, text.length, paint, measure)
                .setAlignment(if (block.centered) Layout.Alignment.ALIGN_CENTER else Layout.Alignment.ALIGN_NORMAL)
                .setLineSpacing(0f, look.spacing * lineScale).setIncludePad(false)
                .setBreakStrategy(Layout.BREAK_STRATEGY_SIMPLE).setHyphenationFrequency(Layout.HYPHENATION_FREQUENCY_NONE)
                .build()
        }
    }

    private val setter = Setter()
    private val footer = setter.paint(size * 0.58f, true).apply { color = look.faint }
    private val pictures = Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG)
    private val layouts = object : LinkedHashMap<Long, StaticLayout>(64, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<Long, StaticLayout>?) = this.size > 64
    }
    private val bounds = ConcurrentHashMap<String, IntArray>()
    private val sheets = ArrayList<Page>()
    /** First page of every chapter, for the contents list and position mapping. */
    private val starts = IntArray(book.chapters.size)
    /** Last page of every chapter. */
    private val finals = IntArray(book.chapters.size)
    override val pages: Int

    init {
        val started = System.nanoTime()
        val restored = if (only != null) null else saved?.let(::restore)
        if (restored != null) sheets.addAll(restored)
        else if (only != null && only.first == only.last) sheets.addAll(paginate(only.first.coerceIn(0, book.chapters.size - 1), setter))
        else paginateAll(only ?: book.chapters.indices)
        for (index in starts.indices) starts[index] = -1
        for ((page, sheet) in sheets.withIndex()) if (starts[sheet.chapter] < 0) starts[sheet.chapter] = page
        // A chapter of skipped art still owns a position: the page before it.
        var following = sheets.size
        for (index in starts.indices.reversed()) if (starts[index] < 0) starts[index] = maxOf(0, following - 1) else following = starts[index]
        require(sheets.isNotEmpty()) { "BOOK_UNAVAILABLE" }
        pages = sheets.size
        for ((page, sheet) in sheets.withIndex()) finals[sheet.chapter] = page
        if (restored == null && saved != null && only == null) runCatching { store(saved) }
        if (BuildConfig.DEBUG && PlaybackPrivacy.diagnostics) runCatching { android.util.Log.i("QuestBookPages",
            "chapters=${book.chapters.size} pages=$pages cached=${restored != null} paginate_ms=${(System.nanoTime() - started) / 1_000_000}") }
    }

    private fun paginateAll(range: IntRange) {
        // Chapters start on their own page, so they paginate independently: a 4-million-character
        // serial took 25 s on one Quest 2 core.
        val done = arrayOfNulls<List<Page>>(book.chapters.size)
        val next = AtomicInteger(range.first)
        val total = AtomicInteger()
        val failure = AtomicReference<Throwable?>()
        val workers = (0 until (Runtime.getRuntime().availableProcessors() - 2).coerceIn(1, 4)).map {
            Thread({
                try {
                    val own = Setter()
                    while (failure.get() == null) {
                        val index = next.getAndIncrement()
                        if (index > range.last || index >= done.size) break
                        done[index] = paginate(index, own).also { check(total.addAndGet(it.size) <= MAX_PAGES) { "PDF_PAGE_LIMIT" } }
                    }
                } catch (error: Throwable) { failure.compareAndSet(null, error) }
            }, "BookPaginate").also { it.start() }
        }
        workers.forEach { it.join() }
        failure.get()?.let { throw it }
        for (chapter in done) chapter?.let(sheets::addAll)
    }

    /** Page breaks from an earlier opening with the same type settings, or null when they do not fit this book. */
    private fun restore(file: java.io.File): List<Page>? = runCatching {
        if (!file.isFile) return@runCatching null
        java.io.DataInputStream(java.util.zip.GZIPInputStream(file.inputStream().buffered())).use { input ->
            check(input.readInt() == LAYOUT_VERSION && input.readInt() == book.chapters.size)
            val count = input.readInt().also { check(it in 1..MAX_PAGES) }
            List(count) {
                val chapter = input.readInt().also { check(it in book.chapters.indices) }
                val blocks = book.chapters[chapter].flow.blocks.size
                Page(chapter, List(input.readInt().also { check(it in 1..4096) }) {
                    Piece(input.readInt(), input.readInt().also { check(it in 0 until blocks) }, input.readInt(), input.readInt(),
                        input.readFloat(), input.readFloat(), input.readInt(), input.readInt())
                })
            }
        }
    }.getOrNull()

    private fun store(file: java.io.File) {
        val partial = java.io.File(file.path + ".part")
        java.io.DataOutputStream(java.util.zip.GZIPOutputStream(partial.outputStream().buffered())).use { output ->
            output.writeInt(LAYOUT_VERSION); output.writeInt(book.chapters.size); output.writeInt(sheets.size)
            for (sheet in sheets) {
                output.writeInt(sheet.chapter); output.writeInt(sheet.pieces.size)
                for (piece in sheet.pieces) {
                    output.writeInt(piece.chapter); output.writeInt(piece.block); output.writeInt(piece.from); output.writeInt(piece.to)
                    output.writeFloat(piece.top); output.writeFloat(piece.height); output.writeInt(piece.offset); output.writeInt(piece.end)
                }
            }
        }
        if (!partial.renameTo(file)) partial.delete()
    }

    private fun pictureBounds(path: String): IntArray = bounds.getOrPut(path) {
        val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        book.resource(path)?.let { BitmapFactory.decodeByteArray(it, 0, it.size, options) }
        intArrayOf(maxOf(0, options.outWidth), maxOf(0, options.outHeight))
    }

    private fun paginate(chapterIndex: Int, setter: Setter): List<Page> {
        val result = ArrayList<Page>()
        var pieces = ArrayList<Piece>()
        var y = 0f
        fun turn() { if (pieces.isNotEmpty()) result += Page(chapterIndex, pieces); pieces = ArrayList(); y = 0f }
        for ((index, block) in book.chapters[chapterIndex].flow.blocks.withIndex()) {
            if (block is BookBlock.Image) {
                val source = pictureBounds(block.path)
                if (source[0] < 8 || source[1] < 8) continue
                // Book art is authored for roughly half this logical width.
                val scale = minOf(measure / source[0].toFloat(), CONTENT_HEIGHT / source[1].toFloat(), 2f)
                val height = source[1] * scale
                val gap = if (y > 0f) line * 0.5f else 0f
                if (y + gap + height > CONTENT_HEIGHT) turn() else y += gap
                pieces += Piece(chapterIndex, index, 0, 0, y, height); y += height + line * 0.5f
                continue
            }
            block as BookBlock.Text
            val layout = setter.layout(block)
            val count = layout.lineCount
            if (count == 0) continue
            val gap = when { y == 0f -> 0f; block.heading > 0 -> line; else -> line * look.paragraph }
            // A heading stays with the text it introduces.
            if (block.heading > 0 && y > 0f && y + gap + layout.height + line * 2 > CONTENT_HEIGHT) turn() else y += gap
            var from = 0
            while (from < count) {
                var to = from
                while (to < count && y + layout.getLineBottom(to) - layout.getLineTop(from) <= CONTENT_HEIGHT) to++
                if (to == from) { if (y > 0f) { turn(); continue }; to = from + 1 }
                val height = (layout.getLineBottom(to - 1) - layout.getLineTop(from)).toFloat()
                pieces += Piece(chapterIndex, index, from, to, y, height, layout.getLineStart(from), layout.getLineEnd(to - 1)); y += height
                from = to
                if (from < count) turn()
            }
            if (block.heading > 0) y += line * 0.6f
        }
        turn()
        return result
    }

    /** Title, contents with their pages, and every page's "chapter/block/character" position and chapter. */
    override fun describe(): org.json.JSONObject {
        val rows = org.json.JSONArray()
        // Every row is listed; one not laid out yet (a partial layout) has page -1.
        for (row in book.contents) rows.put(org.json.JSONObject().put("title", row.title).put("depth", row.depth)
            .put("page", if (only != null && row.chapter !in only) -1 else pageOf(row.chapter, book.chapters[row.chapter].flow.anchors[row.anchor] ?: 0)))
        val at = org.json.JSONArray()
        val chapters = org.json.JSONArray()
        for (sheet in sheets) { val first = sheet.pieces.first(); at.put("${first.chapter}/${first.block}/${first.offset}"); chapters.put(sheet.chapter) }
        val names = org.json.JSONArray(); book.chapters.forEach { names.put(it.title) }
        return org.json.JSONObject().put("title", book.title).put("pages", pages).put("contents", rows).put("at", at)
            .put("chapter", chapters).put("chapters", names).put("aspect", WIDTH.toDouble() / HEIGHT).put("partial", only != null).put("language", speech)
            .put("variant", if (speech == "zh" && locale == Locale.TRADITIONAL_CHINESE) "zh_hant" else speech)
    }

    /**
     * The page's paragraphs as read-aloud blocks in logical page coordinates. A paragraph cut by the page
     * break is spoken to the end of that sentence here, and the next page starts after it, so a turn never
     * splits a sentence in two.
     */
    override fun text(page: Int): org.json.JSONObject {
        val sheet = sheets[page]
        val rows = org.json.JSONArray()
        var id = 0
        for ((index, piece) in sheet.pieces.withIndex()) {
            val block = book.chapters[piece.chapter].flow.blocks[piece.block] as? BookBlock.Text ?: continue
            val from = if (index == 0 && piece.offset > 0) sentenceEnd(block.text, piece.offset).coerceAtMost(piece.end) else piece.offset
            val to = if (index == sheet.pieces.lastIndex && piece.end < block.text.length) sentenceEnd(block.text, piece.end) else piece.end
            val spoken = if (from < to) block.text.substring(from, to).trim() else ""
            val top = TOP + piece.top
            val rect = org.json.JSONArray(listOf(side, top, side + measure, top + piece.height))
            // One paragraph is one target; its speech is split so no utterance outgrows the audio buffers.
            for ((part, words) in utterances(spoken).withIndex()) rows.put(org.json.JSONObject().put("id", id++).put("text", words)
                .put("language", speech).put("eligible", words.any { it.isLetterOrDigit() }).put("solid", true)
                .put("verified", true).put("follow_only", part > 0).put("hit_rect", rect))
        }
        return org.json.JSONObject().put("state", "ready").put("page_size", org.json.JSONArray(listOf(WIDTH, HEIGHT))).put("blocks", rows)
    }


    override fun search(query: String, limit: Int, cancelled: () -> Boolean) = BookSearch.find(book, query, limit, cancelled)
    override fun excerpt(at: String) = BookSearch.excerpt(book, at)

    /** The page showing the start of [block], or the nearest page before it. */
    private fun pageOf(chapter: Int, block: Int): Int {
        var page = starts[chapter]
        while (page + 1 < sheets.size && sheets[page + 1].chapter == chapter && sheets[page + 1].pieces.first().let {
                it.block < block || (it.block == block && it.offset == 0) }) page++
        return page
    }

    private fun layout(piece: Piece, block: BookBlock.Text) =
        layouts.getOrPut(piece.chapter.toLong() shl 32 or piece.block.toLong()) { setter.layout(block) }

    /** The caller owns and recycles the bitmap. [edge] is its height in pixels. */
    override fun render(page: Int, edge: Int): Bitmap {
        val sheet = sheets[page]
        val scale = edge / HEIGHT.toFloat()
        val bitmap = Bitmap.createBitmap(maxOf(1, (WIDTH * scale).roundToInt()), edge, Bitmap.Config.ARGB_8888)
        try {
            val canvas = Canvas(bitmap)
            canvas.drawColor(look.paper)
            canvas.scale(scale, scale)
            for (piece in sheet.pieces) when (val block = book.chapters[piece.chapter].flow.blocks[piece.block]) {
                is BookBlock.Text -> {
                    val layout = layout(piece, block)
                    val top = layout.getLineTop(piece.from).toFloat()
                    canvas.save()
                    canvas.translate(side, TOP + piece.top - top)
                    canvas.clipRect(-side, top, measure + side, top + piece.height)
                    draw(canvas, layout, piece, block)
                    canvas.restore()
                }
                is BookBlock.Image -> picture(canvas, block.path, piece, sheet.pieces.size == 1)
            }
            // A cover or plate that has the page to itself needs no folio.
            if (sheet.pieces.size == 1 && book.chapters[sheet.chapter].flow.blocks[sheet.pieces[0].block] is BookBlock.Image) return bitmap
            // A printed book's running head and folio: book title on left-hand pages, chapter on right-hand ones.
            val label = (page + 1).toString()
            val baseline = HEIGHT - BOTTOM * 0.42f
            val left = page % 2 == 1
            canvas.drawText(label, if (left) side else WIDTH - side - footer.measureText(label), baseline, footer)
            // Pages left in the chapter, quietly at the foot of the page.
            val after = finals[sheet.chapter] - page
            if (look.remaining.isNotEmpty() && after > 0) {
                val words = look.remaining.replace("%d", after.toString())
                canvas.drawText(words, (WIDTH - footer.measureText(words)) / 2f, baseline, footer)
            }
            val title = if (left) book.title else book.chapters[sheet.chapter].title
            if (title.isNotEmpty()) {
                val head = TextUtils.ellipsize(title, footer, measure * 0.8f, TextUtils.TruncateAt.END).toString()
                canvas.drawText(head, if (left) side else WIDTH - side - footer.measureText(head), TOP * 0.55f, footer)
            }
            return bitmap
        } catch (error: Throwable) { bitmap.recycle(); throw error }
    }

    /**
     * Draws the piece's lines. Full lines of body text are set flush on both sides as printed books are:
     * Chinese and Japanese spread the slack between characters, other languages between words.
     */
    private fun draw(canvas: Canvas, layout: StaticLayout, piece: Piece, block: BookBlock.Text) {
        val text = layout.text
        if (block.centered) { layout.draw(canvas); return }
        val styled = text is Spanned && text.getSpans(0, text.length, android.text.style.CharacterStyle::class.java).isNotEmpty()
        val paint = layout.paint
        val dressed = TextPaint()
        for (line in piece.from until piece.to) {
            val start = layout.getLineStart(line)
            var end = layout.getLineEnd(line)
            while (end > start && text[end - 1].isWhitespace()) end--
            if (end <= start) continue
            val baseline = layout.getLineBaseline(line).toFloat()
            val indent = layout.getPrimaryHorizontal(start)
            // Bold, italic and raised text measure differently: the layout knows where each of them falls.
            val natural = if (styled) layout.getLineMax(line) - indent else paint.getRunAdvance(text, start, end, start, end, false, end)
            var slack = measure - indent - natural
            // The last line of a paragraph, and a line left short by a long unbreakable word, stay as set.
            if (line == layout.lineCount - 1 || slack <= 0.5f || slack > size * 2.5f) slack = 0f
            val spaced = (start until end).count { text[it] == ' ' }
            val wide = (start until end).count { Character.UnicodeScript.of(text[it].code) in WIDE }
            val byWords = spaced > 0 && wide * 2 < end - start
            val gaps = if (byWords) spaced else (start until end - 1).count { !Character.isHighSurrogate(text[it]) }
            var passed = 0
            var at = start
            while (at < end) {
                val next = if (Character.isHighSurrogate(text[at]) && at + 1 < end) at + 2 else at + 1
                val shift = if (gaps > 0) slack * passed / gaps else 0f
                if (styled) {
                    val spans = (text as Spanned).getSpans(at, next, android.text.style.CharacterStyle::class.java)
                    val ink = if (spans.isEmpty()) paint else dressed.apply { set(paint); spans.forEach { it.updateDrawState(this) } }
                    canvas.drawTextRun(text, at, next, at, next, layout.getPrimaryHorizontal(at) + shift, baseline + ink.baselineShift, false, ink)
                } else {
                    val x = indent + paint.getRunAdvance(text, start, end, start, end, false, at) + shift
                    canvas.drawTextRun(text, at, next, start, end, x, baseline, false, paint)
                }
                if (!byWords || text[at] == ' ') passed++
                at = next
            }
        }
    }

    private fun picture(canvas: Canvas, path: String, piece: Piece, alone: Boolean) {
        val source = pictureBounds(path)
        val bytes = book.resource(path) ?: return
        val options = BitmapFactory.Options()
        // Decode near the drawn size; covers are often several megapixels.
        while (source[1] / (options.inSampleSize.coerceAtLeast(1) * 2) >= piece.height * 2) options.inSampleSize = options.inSampleSize.coerceAtLeast(1) * 2
        val image = runCatching { BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options) }.getOrNull() ?: return
        try {
            if (alone) {
                val scale = minOf(WIDTH / source[0].toFloat(), HEIGHT / source[1].toFloat())
                val width = source[0] * scale; val height = source[1] * scale
                canvas.drawBitmap(image, null, RectF((WIDTH - width) / 2f, (HEIGHT - height) / 2f, (WIDTH + width) / 2f, (HEIGHT + height) / 2f), pictures)
                return
            }
            val width = piece.height * source[0] / source[1]
            val left = side + (measure - width) / 2f
            canvas.drawBitmap(image, null, RectF(left, TOP + piece.top, left + width, TOP + piece.top + piece.height), pictures)
        } finally { image.recycle() }
    }

    override fun close() { if (only == null) book.close() }

    companion object {
        /** Web-novel TXT files run to millions of characters: 15 MB at large type is over 20000 pages. */
        const val MAX_PAGES = 120000
        /**
         * The language the book is written in, from its own words: kana make it Japanese, Han
         * characters Chinese, Latin letters English. Declared languages are often wrong (an EPUB
         * of Chinese text declaring English), and the voice and the fonts on offer follow this.
         */
        fun script(book: Book): String {
            var han = 0; var kana = 0; var latin = 0; var seen = 0
            loop@ for (chapter in book.chapters) for (block in chapter.flow.blocks) {
                val text = (block as? BookBlock.Text)?.text ?: continue
                for (c in text) {
                    when (c) {
                        in '぀'..'ヿ' -> kana++
                        in '一'..'鿿' -> han++
                        in 'A'..'Z', in 'a'..'z' -> latin++
                        else -> continue
                    }
                    if (++seen >= 4000) break@loop
                }
            }
            val declared = book.language.lowercase().take(2).takeIf { it in NarrationPolicy.languages } ?: "zh"
            return when {
                seen == 0 -> declared
                kana > 3 && kana * 20 > han -> "ja"
                han * 3 > latin -> "zh"
                else -> "en"
            }
        }
        /** End of the sentence running at [from], or [from] when none ends soon after it. */
        fun sentenceEnd(text: String, from: Int): Int {
            for (at in from until minOf(text.length, from + 240)) {
                if (text[at] !in "。！？!?…；;") continue
                var end = at + 1
                while (end < text.length && text[end] in CLOSERS) end++
                return end
            }
            return from
        }
        /** Sentence-sized pieces of at most about [UTTERANCE] characters, split at the weakest pause that fits. */
        fun utterances(text: String): List<String> {
            val result = ArrayList<String>()
            var start = 0
            while (start < text.length) {
                if (text.length - start <= UTTERANCE) { result += text.substring(start); break }
                var cut = -1
                for (marks in listOf("。！？!?…；;", "，、,：:")) {
                    for (at in start + UTTERANCE / 3 until start + UTTERANCE) if (text[at] in marks) cut = at + 1
                    if (cut > 0) break
                }
                if (cut < 0) cut = start + UTTERANCE
                while (cut < text.length && text[cut] in CLOSERS) cut++
                result += text.substring(start, cut); start = cut
            }
            return result.map { it.trim() }.filter { it.isNotEmpty() }
        }
        private const val UTTERANCE = 80
        private val WIDE = setOf(Character.UnicodeScript.HAN, Character.UnicodeScript.HIRAGANA, Character.UnicodeScript.KATAKANA,
            Character.UnicodeScript.HANGUL, Character.UnicodeScript.BOPOMOFO, Character.UnicodeScript.COMMON)
        private const val CLOSERS = "。！？!?…”’」』）)\"'"
        /** Bumped whenever pagination changes, so older cached page breaks are paginated again. */
        const val LAYOUT_VERSION = 3
        const val WIDTH = 1200
        const val HEIGHT = 1600
        const val TOP = 116f
        const val BOTTOM = 124f
        /** The inner margin must clear the curve of the gutter: 12% each side, the same on both pages. */
        const val CONTENT_WIDTH = 912
        const val CONTENT_HEIGHT = HEIGHT - TOP - BOTTOM
    }
}

/** Downloaded fonts, read once per file: a CJK font is megabytes, and a book is laid out many times. */
internal object BookFaces {
    private val faces = java.util.concurrent.ConcurrentHashMap<String, Typeface>()
    fun load(path: String): Typeface? {
        if (path.isEmpty()) return null
        faces[path]?.let { return it }
        val file = java.io.File(path)
        if (!file.isFile) return null
        val face = runCatching { Typeface.createFromFile(file) }.getOrNull() ?: return null
        faces[path] = face
        return face
    }
}
