package org.vrpassthroughplayer.plugin

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.net.Uri
import android.os.ParcelFileDescriptor
import java.io.Closeable
import java.io.File
import kotlin.math.roundToInt

/** Android's platform renderer, with bounded pixels and disposable per-request output. */
internal class PdfBridge(private val context: () -> Context?, emit: (Int, String) -> Unit) : Closeable {
    private var prepared = false // Only accessed by the document render worker.
    private var networkPrepared = false
    private val outputs = mutableSetOf<File>() // Guarded by the shared cache lock until copied.
    private fun cache() = File(context()?.cacheDir ?: error("PDF_UNAVAILABLE"), "pdf-pages")
    private val documents = PdfDocuments({ source, cancellation, hint ->
        val app = context() ?: error("PDF_UNAVAILABLE")
        val uri = Uri.parse(source)
        val input = if (uri.scheme == "cloud") networkInput(app, source, cancellation, hint) else null
        val proxy = input?.first
        val descriptor = proxy?.descriptor ?: if (uri.scheme == "file")
                ParcelFileDescriptor.open(File(uri.path ?: error("PDF_UNAVAILABLE")), ParcelFileDescriptor.MODE_READ_ONLY)
            else app.contentResolver.openFileDescriptor(uri, "r") ?: error("PDF_UNAVAILABLE")
        val pdf = try { PdfRenderer(descriptor) }
            catch (error: Exception) {
                descriptor.close()
                proxy?.throwFailure() // Preserve IO errors without consulting an already released descriptor.
                when (error) {
                    is SecurityException -> throw IllegalArgumentException("PDF_PASSWORD_UNSUPPORTED")
                    is IllegalArgumentException -> throw IllegalArgumentException("PDF_NOT_SEEKABLE")
                    else -> throw error
                }
            }
        object : PdfDocuments.Renderer {
            override val pages = pdf.pageCount
            override val sourceIdentity = input?.second ?: org.json.JSONObject()
            override fun validate() { proxy?.check() }
            override fun render(page: Int, edge: Int): File {
                val started = System.nanoTime()
                proxy?.check()
                val directory = cache()
                synchronized(PhotoCache.lock) {
                    directory.mkdirs()
                    if (!prepared) {
                        directory.listFiles()?.filter { it.isFile && it.name.startsWith("page-") }?.forEach { it.delete() }
                        prepared = true
                    }
                }
                return pdf.openPage(page).use { sheet ->
                    require(sheet.width > 0 && sheet.height > 0) { "PDF_UNAVAILABLE" }
                    val scale = edge.toDouble() / maxOf(sheet.width, sheet.height)
                    val width = maxOf(1, (sheet.width * scale).roundToInt())
                    val height = maxOf(1, (sheet.height * scale).roundToInt())
                    check(directory.usableSpace > PdfReadCache.RESERVE_BYTES + width.toLong() * height * 4) { "PDF_CACHE_FULL" }
                    val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                    var output: File? = null
                    try {
                        bitmap.eraseColor(Color.WHITE)
                        sheet.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                        proxy?.check()
                        val rendered = System.nanoTime()
                        output = synchronized(PhotoCache.lock) {
                            File.createTempFile("page-", ".jpg", directory).also { outputs.add(it) }
                        }
                        // Pages have an opaque white canvas. Match the high-quality screenshot
                        // path instead of spending seconds compressing a temporary PNG per page.
                        output.outputStream().use { check(bitmap.compress(Bitmap.CompressFormat.JPEG, 98, it)) }
                        if (BuildConfig.DEBUG && PlaybackPrivacy.diagnostics) {
                            val finished = System.nanoTime()
                            android.util.Log.i("QuestPdfPage", "pixels=${width}x$height render_ms=${(rendered-started)/1_000_000} encode_ms=${(finished-rendered)/1_000_000} total_ms=${(finished-started)/1_000_000}")
                        }
                        output
                    } catch (error: Throwable) {
                        synchronized(PhotoCache.lock) { output?.let { outputs.remove(it); it.delete() } }
                        throw error
                    }
                    finally { bitmap.recycle() }
                }
            }
            override fun close() { try { pdf.close() } finally { proxy?.close() } }
        }
    }, emit)

    private fun networkInput(app: Context, uri: String, cancellation: CloudCancellation, hint: org.json.JSONObject): Pair<PdfProxyInput, org.json.JSONObject> {
        CloudLibrary.start(app)
        val source = CloudLibrary.pdfSource(uri, cancellation, hint)
        var file: File? = null
        try {
            require(source.source.size > 0) { "PDF_UNAVAILABLE" }
            file = synchronized(PhotoCache.lock) {
                val root = File(app.cacheDir, "pdf-sources")
                check(root.isDirectory || root.mkdirs()) { "PDF_CACHE_FULL" }
                if (!networkPrepared) {
                    root.listFiles()?.filter { it.isFile && it.name.startsWith("source-") }?.forEach { it.delete() }
                    networkPrepared = true
                }
                File.createTempFile("source-", ".blocks", root).also { outputs.add(it) }
            }
            val cached = PdfReadCache(source, file)
            val path = file
            return PdfProxyInput(app, cached) {
                cancellation.cancel()
                synchronized(PhotoCache.lock) { outputs.remove(path) }
            } to source.identity
        } catch (error: Exception) {
            source.close(); cancellation.cancel()
            synchronized(PhotoCache.lock) { file?.let { outputs.remove(it); it.delete() } }
            throw error
        }
    }
    fun open(id: Int, uri: String) = documents.open(id, uri)
    fun openAt(id: Int, uri: String, identity: String) = documents.open(id, uri, identity)
    fun retain(session: String) = documents.retain(session)
    fun release(session: String) = documents.release(session)
    fun resolve(uri: String, edge: Int) = documents.resolve(uri, edge)
    fun resolveReading(uri: String, cancellation: CloudCancellation) = documents.resolve(uri, 3072) { cancellation.cancelled }
    fun validate(uri: String) = documents.validate(uri)
    fun releaseImage(uri: String) {
        runCatching {
            val value = Uri.parse(uri)
            if (value.scheme != "file") return
            val file = File(value.path ?: return)
            synchronized(PhotoCache.lock) {
                if (outputs.remove(file)) file.delete()
            }
        }
    }
    fun cacheDirectories(): Set<File> = synchronized(PhotoCache.lock) { outputs.toSet() }
    override fun close() = documents.close()
}
