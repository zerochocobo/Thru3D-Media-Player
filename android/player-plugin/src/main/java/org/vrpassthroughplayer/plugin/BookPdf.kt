package org.vrpassthroughplayer.plugin

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.ColorMatrix
import android.graphics.ColorMatrixColorFilter
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import kotlin.math.roundToInt

/** What the reading mode asks of a book once it is laid out: its pages, positions and pictures of pages. */
internal interface BookSheets : java.io.Closeable {
    val pages: Int
    fun describe(): JSONObject
    fun text(page: Int): JSONObject
    fun render(page: Int, edge: Int): Bitmap
    /** Where [query] occurs in the text: {"hits": [{"at", "chapter", "text", "mark": [start, length]}], "more"}. */
    fun search(query: String, limit: Int, cancelled: () -> Boolean): JSONObject = JSONObject().put("hits", JSONArray()).put("more", false)
    /** The words at an "chapter/block/character" position, for naming a bookmark. */
    fun excerpt(at: String): String = ""
}

/**
 * A PDF read in the book: its own pages, set on the reader's paper. Type size does not apply; the ink and
 * paper colours do, so night paper turns a printed page dark too.
 */
internal class PdfSheets(file: File, private val title: String, private val look: BookStyle) : BookSheets {
    private val descriptor = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
    private val renderer = try { PdfRenderer(descriptor) } catch (error: Throwable) {
        descriptor.close()
        throw IllegalArgumentException(if (error is SecurityException) "BOOK_PROTECTED" else "BOOK_UNAVAILABLE")
    }
    override val pages = renderer.pageCount

    init {
        if (pages < 1) { close(); error("BOOK_UNAVAILABLE") }
        if (pages > 20000) { close(); error("PDF_PAGE_LIMIT") }
    }

    override fun describe(): JSONObject {
        val at = JSONArray(); val chapter = JSONArray()
        for (page in 0 until pages) { at.put("0/$page/0"); chapter.put(0) }
        return JSONObject().put("title", title).put("pages", pages).put("contents", JSONArray()).put("at", at)
            .put("chapter", chapter).put("chapters", JSONArray().put("")).put("fixed", true)
            .put("aspect", BookPages.WIDTH.toDouble() / BookPages.HEIGHT)
    }

    override fun text(page: Int): JSONObject = JSONObject().put("state", "ready")
        .put("page_size", JSONArray(listOf(BookPages.WIDTH, BookPages.HEIGHT))).put("blocks", JSONArray())

    /** The printed page as large as it fits on the leaf, drawn in the reader's ink on the reader's paper. */
    override fun render(page: Int, edge: Int): Bitmap {
        val width = (edge * BookPages.WIDTH / BookPages.HEIGHT.toFloat()).roundToInt()
        val sheet = Bitmap.createBitmap(width, edge, Bitmap.Config.ARGB_8888)
        try {
            Canvas(sheet).drawColor(look.paper)
            renderer.openPage(page).use { source ->
                val margin = edge * 0.035f
                val scale = minOf((width - margin * 2) / source.width, (edge - margin * 2) / source.height)
                val w = (source.width * scale).roundToInt().coerceAtLeast(1); val h = (source.height * scale).roundToInt().coerceAtLeast(1)
                val printed = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
                try {
                    printed.eraseColor(android.graphics.Color.WHITE)
                    source.render(printed, null, Matrix().apply { setScale(w / source.width.toFloat(), h / source.height.toFloat()) },
                        PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                    Canvas(sheet).drawBitmap(printed, (width - w) / 2f, (edge - h) / 2f, Paint(Paint.FILTER_BITMAP_FLAG).apply { colorFilter = tint() })
                } finally { printed.recycle() }
            }
            return sheet
        } catch (error: Throwable) { sheet.recycle(); throw error }
    }

    /** White becomes the paper and black the ink, channel by channel. */
    private fun tint(): ColorMatrixColorFilter {
        fun channel(colour: Int, shift: Int) = (colour shr shift and 0xff).toFloat()
        val rows = FloatArray(20)
        for ((row, shift) in listOf(16, 8, 0).withIndex()) {
            val ink = channel(look.ink, shift); val paper = channel(look.paper, shift)
            rows[row * 5 + row] = (paper - ink) / 255f
            rows[row * 5 + 4] = ink
        }
        rows[18] = 1f
        return ColorMatrixColorFilter(ColorMatrix(rows))
    }

    override fun close() {
        runCatching { renderer.close() }
        runCatching { descriptor.close() }
    }
}
