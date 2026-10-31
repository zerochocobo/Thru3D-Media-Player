package org.vrpassthroughplayer.plugin

import android.app.Activity
import android.content.Context
import android.content.pm.ApplicationInfo
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.Surface
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.view.inputmethod.InputMethodManager
import org.json.JSONObject
import org.mozilla.geckoview.*
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Private account-only producer. No browser history, media extension, URL snapshot or cookie export. */
class GeckoLoginSession(private val host: () -> Activity?, private val desktopOnly: Boolean = false,
    private val touchOnly: Boolean = false,
    private val navigate: (String, Boolean) -> String?) {
    val id = UUID.randomUUID().toString()
    private val ui = Handler(Looper.getMainLooper())
    @Volatile private var closed = false
    @Volatile private var state = "{}"
    private var session: GeckoSession? = null
    private var runtime: GeckoRuntime? = null
    private var display: GeckoDisplay? = null
    private var surface: Surface? = null
    private var input: LoginInput? = null
    @Volatile private var editor: InputConnection? = null
    private var editing = false
    @Volatile private var paused = false
    private var desktop = desktopOnly
    private var progress = 0
    private var loading = true
    private var failed = false
    private var generation = 0L
    private var detachedThrough = 0L
    private var needsSurface = false
    private val load = GeckoLoginLoad()
    private var loadErrorCategory = 0
    private var loadErrorCode = 0
    private var downTime = 0L
    private var lastX = 0f
    private var lastY = 0f
    @Volatile private var navigation = 0L
    private var width = 0
    private var height = 0
    private var diagnostics = false
    private var pointerDowns = 0L
    private var pointerUps = 0L
    private var pointerCancels = 0L
    private var pointerIgnored = 0L
    private var lastPointerDrop = ""
    private var lastDownResult = -1

    init { GeckoLoginSurfaceBridge.install(this); publish() }
    fun snapshot(): JSONObject = JSONObject(state)
    private fun dispatch(block: () -> Unit) { ui.post { if (!closed) block() } }

    fun open(url: String) = dispatch {
        try {
            if (session != null) return@dispatch
            val activity = host() ?: error("Activity unavailable")
            diagnostics = activity.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0
            val current = GeckoSession(GeckoSessionSettings.Builder().usePrivateMode(true).contextId("account-$id")
                .userAgentMode(if (desktop) GeckoSessionSettings.USER_AGENT_MODE_DESKTOP else GeckoSessionSettings.USER_AGENT_MODE_MOBILE)
                .viewportMode(if (desktop) GeckoSessionSettings.VIEWPORT_MODE_DESKTOP else GeckoSessionSettings.VIEWPORT_MODE_MOBILE).suspendMediaWhenInactive(true).build())
            session = current
            current.navigationDelegate = object : GeckoSession.NavigationDelegate {
                override fun onLoadRequest(s: GeckoSession, request: GeckoSession.NavigationDelegate.LoadRequest): GeckoResult<AllowOrDeny> {
                    if (load.placeholder(request.uri)) return GeckoResult.fromValue(
                        if (load.allowPlaceholderRequest()) AllowOrDeny.ALLOW else AllowOrDeny.DENY)
                    val next = permitted(request.uri, true)
                    if (next != null && (next != request.uri || request.target == GeckoSession.NavigationDelegate.TARGET_WINDOW_NEW)) {
                        // Login popups stay in the same isolated session and under the same policy.
                        dispatch { current.loadUri(next) }
                        return GeckoResult.fromValue(AllowOrDeny.DENY)
                    }
                    return GeckoResult.fromValue(if (next != null) AllowOrDeny.ALLOW else AllowOrDeny.DENY)
                }
                override fun onSubframeLoadRequest(s: GeckoSession, request: GeckoSession.NavigationDelegate.LoadRequest) =
                    GeckoResult.fromValue(if (permitted(request.uri, false) == request.uri) AllowOrDeny.ALLOW else AllowOrDeny.DENY)
                override fun onLocationChange(s: GeckoSession, url: String?, perms: MutableList<GeckoSession.PermissionDelegate.ContentPermission>, hasUserGesture: Boolean) {
                    if (load.placeholder(url)) return
                    if (url != null) checkNavigation(s, url)
                }
                override fun onLoadError(s: GeckoSession, uri: String?, error: WebRequestError): GeckoResult<String>? {
                    if (load.placeholder(uri)) return null
                    loadErrorCategory = error.category; loadErrorCode = error.code
                    failed = true; loading = false; publish(); return null
                }
            }
            current.progressDelegate = object : GeckoSession.ProgressDelegate {
                override fun onPageStart(s: GeckoSession, url: String) {
                    if (load.placeholder(url)) return
                    load.started(url)
                    navigation++; cancelTouch(); hideInput(); progress = 0; loading = true
                    loadErrorCategory = 0; loadErrorCode = 0
                    if (checkNavigation(s, url)) failed = false
                    publish()
                }
                override fun onProgressChange(s: GeckoSession, value: Int) { progress = value; publish() }
                // Redirects and policy-consumed OAuth callbacks may stop a load successfully for us.
                override fun onPageStop(s: GeckoSession, success: Boolean) { loading = false; publish() }
            }
            current.contentDelegate = object : GeckoSession.ContentDelegate {
                override fun onCrash(s: GeckoSession) { failed = true; releaseDisplay(); publish() }
                override fun onKill(s: GeckoSession) { failed = true; releaseDisplay(); publish() }
            }
            current.permissionDelegate = object : GeckoSession.PermissionDelegate {
                override fun onContentPermissionRequest(s: GeckoSession, permission: GeckoSession.PermissionDelegate.ContentPermission) = GeckoResult.fromValue(GeckoSession.PermissionDelegate.ContentPermission.VALUE_DENY)
            }
            // Reuse the browser's default Gecko IME delegate and attached Android input host.
            // Passwords and field contents never enter the account snapshot.
            runtime = WebBrowser.engine(activity)
            current.open(runtime!!)
            input = LoginInput(activity).also { view ->
                (activity.window.decorView as ViewGroup).addView(view, ViewGroup.LayoutParams(1, 1))
                current.textInput.setView(view)
            }
            permitted(url, true)?.let { load.open(it) }
            bindDisplay()
            publish()
        } catch (_: Exception) { failed = true; publish() }
    }

    private fun permitted(url: String, main: Boolean): String? = if (closed) null else runCatching { navigate(url, main) }.getOrNull()
    private fun checkNavigation(current: GeckoSession, url: String): Boolean {
        val next = permitted(url, true)
        if (next == url) return true
        current.stop()
        if (next != null) dispatch { current.loadUri(next) }
        return false
    }
    fun action(command: String, x: Float = 0f, y: Float = 0f, text: String = "") = dispatch {
        if (!x.isFinite() || !y.isFinite() || text.length > 4096 || paused) return@dispatch
        val current = session ?: return@dispatch
        when (command) {
            "down", "move", "up", "cancel", "scroll" -> pointer(command, x, y)
            "back" -> { cancelTouch(); current.goBack() }
            "desktop", "mobile" -> {
                if (desktopOnly || desktop == (command == "desktop")) return@dispatch
                cancelTouch(); hideInput(); desktop = command == "desktop"
                current.settings.userAgentMode = if (desktop) GeckoSessionSettings.USER_AGENT_MODE_DESKTOP else GeckoSessionSettings.USER_AGENT_MODE_MOBILE
                current.settings.viewportMode = if (desktop) GeckoSessionSettings.VIEWPORT_MODE_DESKTOP else GeckoSessionSettings.VIEWPORT_MODE_MOBILE
                // Wait for the new Surface to avoid reloading at the previous CSS width.
                releaseDisplay(); surface = null; needsSurface = true; load.resize(); loading = true
            }
            "keyboard_close" -> { current.setFocused(false); hideInput() }
            "text", "paste", "backspace", "enter" -> edit(command, text)
        }
        publish()
    }

    private fun pointer(command: String, x: Float, y: Float) {
        val current = session ?: return
        if (display == null) { pointerIgnored++; lastPointerDrop = "no_display"; return }
        // Account selection cards should see the same touchscreen throughout the
        // flow, without an unrelated mouse hover immediately preceding each tap.
        if (touchOnly && command == "move" && downTime == 0L) return
        val now = SystemClock.uptimeMillis()
        val code = when (command) {
            "down" -> { if (downTime != 0L) return; current.setFocused(true); input?.requestFocus(); downTime = now; MotionEvent.ACTION_DOWN }
            "move" -> if (downTime == 0L) MotionEvent.ACTION_HOVER_MOVE else MotionEvent.ACTION_MOVE
            "up" -> if (downTime == 0L) return else MotionEvent.ACTION_UP
            "cancel" -> if (downTime == 0L) return else MotionEvent.ACTION_CANCEL
            "scroll" -> { if (downTime != 0L) return; MotionEvent.ACTION_SCROLL }
            else -> return
        }
        val mouse = code == MotionEvent.ACTION_HOVER_MOVE || code == MotionEvent.ACTION_SCROLL
        val p = MotionEvent.PointerProperties().apply { id = 0; toolType = if (mouse) MotionEvent.TOOL_TYPE_MOUSE else MotionEvent.TOOL_TYPE_FINGER }
        val c = MotionEvent.PointerCoords().apply {
            this.x = x.coerceIn(0f, 1f) * (width - 1); this.y = y.coerceIn(0f, 1f) * (height - 1)
            if (code == MotionEvent.ACTION_SCROLL) { this.x = lastX; this.y = lastY; setAxisValue(MotionEvent.AXIS_VSCROLL, -y.coerceIn(-1f, 1f) * 3f) }
            pressure = if (mouse || code == MotionEvent.ACTION_UP || code == MotionEvent.ACTION_CANCEL) 0f else 1f; size = 1f
        }
        lastX = c.x; lastY = c.y
        val event = MotionEvent.obtain(if (downTime != 0L) downTime else now, now, code, 1, arrayOf(p), arrayOf(c),
            0, 0, 1f, 1f, 0, 0, if (mouse) InputDevice.SOURCE_MOUSE else InputDevice.SOURCE_TOUCHSCREEN, 0)
        if (code == MotionEvent.ACTION_DOWN) { pointerDowns++; lastPointerDrop = ""; lastDownResult = -1 }
        if (code == MotionEvent.ACTION_UP) pointerUps++
        if (code == MotionEvent.ACTION_CANCEL) pointerCancels++
        try {
            if (mouse) current.panZoomController.onMotionEvent(event)
            else if (diagnostics && code == MotionEvent.ACTION_DOWN) {
                val document = navigation; val press = pointerDowns
                current.panZoomController.onTouchEventForDetailResult(event).accept({ result ->
                    ui.post { if (!closed && session === current && navigation == document && pointerDowns == press) { lastDownResult = result?.handledResult() ?: -2; publish() } }
                }, { _ -> ui.post { if (!closed && navigation == document && pointerDowns == press) { lastDownResult = -2; publish() } } })
            } else current.panZoomController.onTouchEvent(event)
        }
        finally { event.recycle() }
        if (code == MotionEvent.ACTION_UP || code == MotionEvent.ACTION_CANCEL) downTime = 0L
    }
    private fun cancelTouch() { if (downTime != 0L) pointer("cancel", lastX / (width - 1).coerceAtLeast(1), lastY / (height - 1).coerceAtLeast(1)); downTime = 0L }
    fun pause(value: Boolean) = dispatch {
        paused = value
        if (value) { cancelTouch(); hideInput(); session?.setFocused(false); session?.setActive(false) }
        else { session?.setActive(display != null); session?.setFocused(display != null); loadWhenReady() }
        publish()
    }

    internal fun attach(target: Surface, w: Int, h: Int, value: Long): Boolean {
        if (closed || !target.isValid || value <= 0 || w !in 256..4096 || h !in 256..4096) return false
        dispatch {
            if (value <= detachedThrough || value < generation || !target.isValid) return@dispatch
            releaseDisplay(); surface = target; width = w; height = h; generation = value; needsSurface = false
            bindDisplay()
            publish()
        }
        return true
    }
    internal fun detach(value: Long): Boolean {
        val done = CountDownLatch(1)
        val release = {
            try {
                if (value == generation) {
                    cancelTouch(); hideInput(); session?.setFocused(false); session?.setActive(false)
                    releaseDisplay(); surface = null
                }
                detachedThrough = maxOf(detachedThrough, value); publish()
            } finally { done.countDown() }
        }
        if (Looper.myLooper() == Looper.getMainLooper()) release() else ui.post { release() }
        return try { done.await(1500, TimeUnit.MILLISECONDS) } catch (_: InterruptedException) { Thread.currentThread().interrupt(); false }
    }
    private fun bindDisplay() {
        val current = session ?: return
        val target = surface ?: return
        if (display != null || closed || !target.isValid) return
        display = current.acquireDisplay().also { next ->
            next.surfaceChanged(GeckoDisplay.SurfaceInfo.Builder(target).size(width, height).newSurfaceProvider {
                releaseDisplay(); needsSurface = true; publish()
            }.build())
        }
        current.setActive(!paused); current.setFocused(!paused)
        loadWhenReady()
    }
    private fun loadWhenReady() {
        val current = session ?: return
        load.ready(display != null, paused, { url -> current.loadUri(url) }, { current.reload() })
    }
    private fun releaseDisplay() {
        val old = display; display = null
        if (old != null) { old.surfaceDestroyed(); session?.releaseDisplay(old) }
    }

    private inner class LoginInput(owner: Activity) : View(owner) {
        init { isFocusable = true; isFocusableInTouchMode = true; importantForAutofill = IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS }
        override fun onCheckIsTextEditor() = true
        // Android 24+ uses View's handler, as GeckoView does. Inherit its nullable
        // result: IME deactivation can query this view after it has been detached.
        override fun onCreateInputConnection(info: EditorInfo): InputConnection? {
            val epoch = navigation
            val connection = session?.textInput?.onCreateInputConnection(info)
            ui.post { if (!closed && !paused && epoch == navigation) { editor = connection; editing = connection != null && info.inputType != 0; publish() } }
            return connection
        }
        override fun onKeyPreIme(code: Int, event: KeyEvent) = session?.textInput?.onKeyPreIme(code, event) ?: false
        override fun onKeyDown(code: Int, event: KeyEvent) = session?.textInput?.onKeyDown(code, event) ?: false
        override fun onKeyUp(code: Int, event: KeyEvent) = session?.textInput?.onKeyUp(code, event) ?: false
    }
    private fun hideInput() {
        val old = editor; editor = null; editing = false
        old?.let { (it.handler ?: ui).post { it.finishComposingText() } }
        input?.let { (it.context.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager).hideSoftInputFromWindow(it.windowToken, 0); it.clearFocus() }
    }
    private fun edit(command: String, text: String) {
        val connection = editor ?: return
        val epoch = navigation
        val value = if (command == "paste") {
            val clipboard = host()?.getSystemService(Context.CLIPBOARD_SERVICE) as? android.content.ClipboardManager
            clipboard?.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.text?.toString()?.take(2048).orEmpty()
        } else text
        (connection.handler ?: ui).post {
            if (closed || paused || navigation != epoch || editor !== connection) return@post
            when (command) {
                "text", "paste" -> if ('\u0000' !in value) connection.commitText(value, 1)
                "backspace" -> connection.deleteSurroundingTextInCodePoints(1, 0)
                "enter" -> { connection.sendKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_ENTER)); connection.sendKeyEvent(KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_ENTER)) }
            }
        }
    }
    private fun publish() {
        val units = WebBrowser.loginViewport().pixelUnits
        state = JSONObject().put("renderer", "gecko").put("surface_id", id).put("desktop", desktop).put("desktop_only", desktopOnly).put("touch_only", touchOnly)
            // iPhone Pro Max layout width; height remains a practical VR login viewport.
            .put("width", if (desktop) 1200 else 440).put("height", if (desktop) 720 else 600)
            .put("pixel_units", units).put("generation", generation).put("attached", display != null)
            .put("needs_surface", needsSurface).put("progress", progress).put("loading", loading)
            .put("load_error_category", loadErrorCategory).put("load_error_code", loadErrorCode)
            .put("failed", failed).put("editing", editing && downTime == 0L).put("system_keyboard", true).put("navigation", navigation)
            .apply { if (diagnostics) put("input_probe", JSONObject().put("down", pointerDowns).put("up", pointerUps)
                .put("cancel", pointerCancels).put("ignored", pointerIgnored).put("drop", lastPointerDrop)
                .put("held", downTime != 0L).put("paused", paused).put("down_result", lastDownResult)) }.toString()
    }
    fun close() {
        closed = true
        ui.post {
            load.close()
            cancelTouch(); hideInput(); releaseDisplay(); surface = null
            session?.let { it.textInput.setView(null); if (it.isOpen) it.close() }; session = null
            runtime?.storageController?.clearDataForSessionContext("account-$id")
            input?.let { (it.parent as? ViewGroup)?.removeView(it) }; input = null
            GeckoLoginSurfaceBridge.remove(this); publish()
        }
    }
}
