package org.vrpassthroughplayer.plugin

import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.view.inputmethod.InputMethodManager
import android.webkit.*
import android.widget.FrameLayout
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.util.concurrent.atomic.AtomicBoolean

/** Independent browsing surface. No OAuth handling, JavaScript bridge, external activities or cookie clearing. */
@SuppressLint("SetJavaScriptEnabled")
internal class PanoramaBrowser(private val host: () -> Activity?, originals: PanoramaOriginals) {
    private val handler = Handler(Looper.getMainLooper())
    private val capturing = AtomicBoolean()
    private val download = PanoramaDownload({ host()?.applicationContext }, originals)
    fun view(source: String) = download.view(source)
    @Volatile private var closed = false
    @Volatile private var paused = true
    @Volatile private var inForeground = true
    @Volatile private var uiPaused = true
    @Volatile private var bytes = ByteArray(0)
    @Volatile private var status = ""
    @Volatile private var title = ""
    @Volatile private var page = ""
    @Volatile private var progress = 0
    @Volatile private var editing = false
    @Volatile private var canBack = false
    @Volatile private var scrollY = 0
    @Volatile private var scrollRange = WebLoginViewport.HEIGHT
    @Volatile private var debugDocument = "{}"
    private var web: BrowserView? = null
    private var viewport: FrameLayout? = null
    private var geometry: WebLoginViewport.Geometry? = null
    private var bitmap: Bitmap? = null
    private var editor: InputConnection? = null
    private var downAt = 0L
    @Volatile private var touchActive = false
    private var document = ""
    private var navigationFailed = false
    private var navigation = 0

    private inner class BrowserView(context: Context) : WebView(context) {
        override fun onCreateInputConnection(info: EditorInfo): InputConnection? {
            editor = super.onCreateInputConnection(info)
            editing = editor != null && info.inputType != 0
            handler.post { (context.getSystemService(Context.INPUT_METHOD_SERVICE) as? InputMethodManager)
                ?.hideSoftInputFromWindow(windowToken, 0) }
            return null
        }
        fun captureEditor() {
            val info = EditorInfo(); val input = super.onCreateInputConnection(info)
            if (input != null && info.inputType != 0) { editor = input; editing = true }
        }
        fun documentHeight() = computeVerticalScrollRange().coerceAtLeast(height)
        override fun onScrollChanged(x: Int, y: Int, oldX: Int, oldY: Int) {
            super.onScrollChanged(x, y, oldX, oldY); updateScroll()
        }
    }
    fun snapshot(): String = JSONObject().put("status", status).put("title", title).put("url", page)
        .put("progress", progress).put("editing", editing && !touchActive).put("can_back", canBack)
        .put("scroll_y", scrollY).put("scroll_range", scrollRange).put("download", download.snapshot()).apply {
            if (BuildConfig.DEBUG) put("debug", JSONObject(debugDocument))
        }.toString()

    fun navigate(url: String) {
        if (closed || !PanoramaWebPolicy.allowed(url)) return
        download.cancel()
        uiPaused = false; paused = !inForeground
        handler.post {
            if (closed) return@post
            if (web == null) create()
            if (!paused) web?.onResume() else web?.onPause()
            web?.loadUrl(url)
        }
    }
    private fun create() {
        try {
            val activity = host() ?: error("No activity")
            val layout = WebLoginViewport.Geometry(activity); geometry = layout
            val context = WebLoginViewport.context(activity)
            val view = BrowserView(context); web = view
            view.isSaveEnabled = false
            view.importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS
            val container = WebLoginViewport.container(context, layout); viewport = container
            container.addView(view, FrameLayout.LayoutParams(layout.width, layout.height))
            activity.findViewById<ViewGroup>(android.R.id.content).addView(container, 0, ViewGroup.LayoutParams(layout.width, layout.height))
            view.setLayerType(View.LAYER_TYPE_SOFTWARE, null)
            container.measure(View.MeasureSpec.makeMeasureSpec(layout.width, View.MeasureSpec.EXACTLY),
                View.MeasureSpec.makeMeasureSpec(layout.height, View.MeasureSpec.EXACTLY))
            container.layout(0, 0, layout.width, layout.height)
            WebLoginViewport.configure(view, WebSettings.getDefaultUserAgent(activity))
            view.settings.javaScriptCanOpenWindowsAutomatically = false
            CookieManager.getInstance().setAcceptThirdPartyCookies(view, false)
            view.webChromeClient = object : WebChromeClient() {
                override fun onProgressChanged(view: WebView, value: Int) { progress = value }
                override fun onReceivedTitle(view: WebView, value: String?) { title = value.orEmpty().take(256) }
                override fun onPermissionRequest(request: PermissionRequest) { request.deny() }
                override fun onJsAlert(view: WebView, url: String, message: String, result: JsResult): Boolean { result.cancel(); return true }
                override fun onJsConfirm(view: WebView, url: String, message: String, result: JsResult): Boolean { result.cancel(); return true }
                override fun onJsPrompt(view: WebView, url: String, message: String, defaultValue: String, result: JsPromptResult): Boolean { result.cancel(); return true }
            }
            view.webViewClient = object : WebViewClient() {
                override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                    if (closed || paused) return true
                    val url = request.url.toString()
                    if (!PanoramaWebPolicy.allowed(url)) return true
                    if (PanoramaWebPolicy.imageNavigation(url, request.isForMainFrame, request.method)) {
                        download.start(url, sourcePage(view, url)); return true
                    }
                    return false
                }
                override fun onPageStarted(view: WebView, url: String, favicon: Bitmap?) {
                    if (!PanoramaWebPolicy.allowed(url)) { view.stopLoading(); return }
                    navigation++; navigationFailed = false; page = url; status = "Loading…"; editor = null; editing = false
                }
                override fun onPageFinished(view: WebView, url: String) {
                    if (closed || web !== view) return
                    canBack = view.canGoBack(); updateScroll()
                    val token = navigation
                    // Covers standard image responses without a filename extension. No page-provided native interface.
                    view.evaluateJavascript("document.contentType || ''") { raw ->
                        if (closed || paused || web !== view || token != navigation) return@evaluateJavascript
                        val mime = runCatching { org.json.JSONArray("[$raw]").getString(0) }.getOrDefault("")
                        if (PanoramaWebPolicy.mime(mime) in PanoramaWebPolicy.imageTypes) {
                            download.start(url, document)
                            if (view.canGoBack()) view.goBack()
                        } else { document = url; if (!navigationFailed) status = "" }
                    }
                }
                override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
                    if (request.isForMainFrame) { navigationFailed = true; status = "Page unavailable. Try reloading." }
                }
                override fun onReceivedSslError(view: WebView, callback: SslErrorHandler, error: android.net.http.SslError) {
                    callback.cancel(); navigationFailed = true; status = "Page unavailable. Try reloading."
                }
                override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
                    detach(); status = "Web browsing is unavailable on this device"; return true
                }
            }
            view.setDownloadListener { url, _, disposition, mime, _ ->
                if (closed || paused) return@setDownloadListener
                if ((PanoramaWebPolicy.mime(mime) in PanoramaWebPolicy.imageTypes || PanoramaWebPolicy.mime(mime) == "application/octet-stream") || PanoramaWebPolicy.imageNavigation(url, true, "GET")) {
                    download.start(url, sourcePage(view, url), disposition)
                } else status = "Choose a JPG, PNG or WebP original"
            }
        } catch (_: Exception) { detach(); status = "Web browsing is unavailable on this device" }
    }
    fun frame(): ByteArray {
        if (!closed && !paused && capturing.compareAndSet(false, true)) handler.post {
            try {
                if (closed || paused || web == null) return@post
                // SPA navigation (e.g. Poly Haven) does not necessarily call onPageStarted/Finished.
                web?.let { view ->
                    val result = download.snapshot()
                    if (result.optString("state") == "page") {
                        val target = result.optString("url")
                        download.cancel()
                        // App-initiated loadUrl does not re-intercept its own HTML-looking .jpg URL.
                        if (PanoramaWebPolicy.allowed(target)) view.loadUrl(target)
                    }
                    val current = view.url.orEmpty()
                    if (current != page && PanoramaWebPolicy.allowed(current)) {
                        if (document == page) document = current
                        page = current
                    }
                    canBack = view.canGoBack()
                }
                if (bitmap == null) bitmap = Bitmap.createBitmap(WebLoginViewport.WIDTH, WebLoginViewport.HEIGHT, Bitmap.Config.ARGB_8888)
                val canvas = Canvas(bitmap!!); canvas.drawColor(android.graphics.Color.WHITE)
                val scale = geometry?.density ?: 1f
                canvas.save(); canvas.scale(1f / scale, 1f / scale); viewport?.draw(canvas); canvas.restore()
                val output = ByteArrayOutputStream(); bitmap!!.compress(Bitmap.CompressFormat.JPEG, 88, output)
                bytes = output.toByteArray()
            } catch (_: Exception) { status = "Page unavailable. Try reloading." }
            finally { capturing.set(false) }
        }
        return if (closed || paused) ByteArray(0) else bytes
    }
    fun action(action: String, x: Float, y: Float, text: String) {
        if (closed || !x.isFinite() || !y.isFinite() || text.length > 4096) return
        if (action == "download_cancel") { download.cancel(); return }
        handler.post {
            val view = web ?: return@post
            if (closed || paused) return@post
            when (action) {
                "debug_inspect" -> if (BuildConfig.DEBUG) {
                    val script = """JSON.stringify({url:location.href,title:document.title,width:innerWidth,height:innerHeight,
                        scroll_y:scrollY,scroll_height:document.documentElement.scrollHeight,text:document.body.innerText.slice(0,16000),
                        links:Array.from(document.querySelectorAll('a,button,input,select,[role=button]')).slice(0,500).map(e=>{
                            const r=e.getBoundingClientRect();return {tag:e.tagName,text:(e.innerText||e.getAttribute('aria-label')||e.title||e.placeholder||'').slice(0,150),
                            href:e.href||'',type:e.type||'',x:r.x,y:r.y,w:r.width,h:r.height};})})""".trimIndent()
                    view.evaluateJavascript(script) { raw ->
                        runCatching { debugDocument = JSONObject(org.json.JSONArray("[$raw]").getString(0)).toString() }
                    }
                }
                "debug_scroll_to" -> if (BuildConfig.DEBUG) view.scrollTo(0, (y.coerceIn(0f, 1f) * (view.documentHeight()-view.height)).toInt())
                "down", "move", "up", "cancel" -> {
                    if (action == "down") { downAt = SystemClock.uptimeMillis(); touchActive = true }
                    val code = when (action) { "down" -> MotionEvent.ACTION_DOWN; "move" -> MotionEvent.ACTION_MOVE; "up" -> MotionEvent.ACTION_UP; else -> MotionEvent.ACTION_CANCEL }
                    val event = MotionEvent.obtain(downAt, SystemClock.uptimeMillis(), code,
                        x.coerceIn(0f, 1f) * view.width, y.coerceIn(0f, 1f) * view.height, 0)
                    try { view.dispatchTouchEvent(event) } finally { event.recycle() }
                    if (action == "up" || action == "cancel") touchActive = false
                    if (action == "up") handler.postDelayed({ if (!closed && web === view && !touchActive) view.captureEditor() }, 100)
                }
                "scroll" -> view.scrollBy(0, (y.coerceIn(-1f, 1f) * 160 * (geometry?.density ?: 1f)).toInt())
                "zoom_in" -> view.zoomBy(1.25f)
                "zoom_out" -> view.zoomBy(0.8f)
                "text" -> if ('\u0000' !in text) editor?.commitText(text, 1)
                "backspace" -> editor?.deleteSurroundingText(1, 0)
                "enter" -> { editor?.performEditorAction(EditorInfo.IME_ACTION_GO); editing = false; editor = null; view.clearFocus() }
                "keyboard_close" -> { editing = false; editor = null; view.clearFocus() }
                "back" -> if (view.canGoBack()) view.goBack()
                "reload" -> view.reload()
            }
        }
    }
    fun foreground(value: Boolean) { inForeground = value; applyPause() }
    fun pause(value: Boolean) { uiPaused = value; applyPause() }
    private fun applyPause() {
        paused = uiPaused || !inForeground
        handler.post { web?.let { view ->
            if (paused) {
                val event = MotionEvent.obtain(downAt, SystemClock.uptimeMillis(), MotionEvent.ACTION_CANCEL, 0f, 0f, 0)
                try { view.dispatchTouchEvent(event) } finally { event.recycle() }
                touchActive = false; view.onPause()
            } else view.onResume()
        } }
    }
    private fun updateScroll() {
        web?.let { view -> geometry?.let { scrollY = it.logical(view.scrollY); scrollRange = it.logical(view.documentHeight()) } }
    }
    private fun sourcePage(view: WebView, target: String): String = view.url.orEmpty().takeIf {
        it != target && PanoramaWebPolicy.allowed(it) && !PanoramaWebPolicy.imageNavigation(it, true, "GET")
    } ?: document
    private fun detach() {
        viewport?.let { (it.parent as? ViewGroup)?.removeView(it) }
        web?.let { it.stopLoading(); it.destroy() }
        web = null; viewport = null; bitmap?.recycle(); bitmap = null; bytes = ByteArray(0); editor = null
    }
    fun close() { closed = true; download.close(); handler.post { detach() } }
}
