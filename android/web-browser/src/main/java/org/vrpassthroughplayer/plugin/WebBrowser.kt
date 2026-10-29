package org.vrpassthroughplayer.plugin

import android.app.Activity
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
import org.json.JSONArray
import org.json.JSONObject
import org.mozilla.geckoview.AllowOrDeny
import org.mozilla.geckoview.GeckoDisplay
import org.mozilla.geckoview.GeckoPreferenceController
import org.mozilla.geckoview.GeckoResult
import org.mozilla.geckoview.GeckoRuntime
import org.mozilla.geckoview.GeckoRuntimeSettings
import org.mozilla.geckoview.GeckoSession
import org.mozilla.geckoview.GeckoSessionSettings
import org.mozilla.geckoview.WebExtension
import org.mozilla.geckoview.WebRequestError
import org.mozilla.geckoview.MediaSession
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import android.util.AtomicFile
import java.io.File

/** Bounded tabs and peer display slots. All Gecko and Surface calls run on Android UI. */
class WebBrowser(private val activity: () -> Activity?) : AutoCloseable {
    companion object {
        private const val EXTENSION_ID = "web-video@thru3d.local"
        private const val NATIVE_APP = "thru3d_video"
        // Gecko owns a profile separate from Android WebView / the cloud account login flow.
        // A process has one runtime; recreating an Activity closes its sessions, not Gecko itself.
        private var runtime: GeckoRuntime? = null
        private var runtimeViewport: WebBrowserViewport? = null
        @Synchronized private fun viewport(lowEnd: Boolean = false): WebBrowserViewport =
            runtimeViewport ?: WebBrowserViewport(lowEnd).also { runtimeViewport = it }
    }
    private class Tab(val id: Int, val session: GeckoSession, var window: Int, val opener: Int = 0) {
        var openerLinked = opener != 0
        var awake = true
        var savedState: GeckoSession.SessionState? = null
        var parkedReturn: JSONObject? = null
        var touched = 0L
        var protectedInput = false
        var pendingUrl: String? = null
        var url = "about:blank"
        var title = ""
        var progress = 0
        var back = false
        var forward = false
        var editing = false
        var editor: InputConnection? = null
        var editorAction = EditorInfo.IME_ACTION_UNSPECIFIED
        var error = ""
        var navigation = 0L
        var playback: MediaSession? = null
        var playing = false
        var pauseToken = 0L
        val ports = mutableMapOf<WebExtension.Port, Long>()
        val media = mutableMapOf<WebExtension.Port, JSONArray>()
        val fullscreen = WebBrowserFullscreen()
        var fullscreenPort: WebExtension.Port? = null
        var restorePosition: Pair<Double, Boolean>? = null
        var restoreThroughScript = false
        var restoreOrigin = ""
        var capturedFullscreenRequest = 0L
        val sources = mutableMapOf<WebExtension.Port, JSONArray>()
        var fullScreen = false
    }
    private val ui = Handler(Looper.getMainLooper())
    private val closed = AtomicBoolean(false)
    private val exiting = AtomicBoolean(false)
    private val tabs = mutableListOf<Tab>()
    private var extension: WebExtension? = null
    private val cookies = WebBrowserCookies()
    private var extensionState = "pending"
    private class Window(val id: Int) {
        var tab = 0
        var display: GeckoDisplay? = null
        var owner: Tab? = null
        var surface: Surface? = null
        var width = 1280
        var height = 800
        var generation = 0L
        var detachedThrough = 0L
        var needsSurface = false
    }
    private val windows = (1..4).map(::Window)
    private val windowLimit: Int get() = if (viewport().lowEnd) 2 else 4
    private var changingLayout = false
    private var layoutRevision = 0L
    private fun liveLimit(count: Int = windows.count { it.tab != 0 }) = maxOf(2, count).coerceAtMost(windowLimit)
    private fun freeWindow(): Int? = (1..windowLimit).firstOrNull { id -> tabs.none { it.window == id } }
    private var focusedWindow = 1
    private var nextTabId = 0
    private var operationError = ""
    private fun window(id: Int = focusedWindow) = windows.first { it.id == id }
    private fun current(): Tab? = tabs.firstOrNull { it.id == window().tab }
    private fun displayed(tab: Tab): Boolean = active && tab.awake && window(tab.window).tab == tab.id
    private var active = false
    private var downTime = 0L
    private var input: BrowserInput? = null
    private var library: WebBrowserLibrary? = null
    private var networkPolicy: WebBrowserNetworkPolicy? = null
    private var recordHistory = false
    @Volatile private var libraryState = "{\"bookmarks\":[],\"history\":[]}"
    private val libraryRequest = java.util.concurrent.atomic.AtomicInteger()
    private val historyWriter = java.util.concurrent.Executors.newSingleThreadExecutor { Thread(it, "BrowserHistory").apply { isDaemon = true } }
    @Volatile private var libraryResult = "{}"
    @Volatile private var bookmarkServiceContext: android.content.Context? = null
    private val bookmarkShare = WebBookmarkShare(
        asset = { path -> activity()?.assets?.open(path)?.use { it.readBytes() } ?: error("asset") },
        handle = { request, alive ->
            val result = java.util.concurrent.CompletableFuture<JSONObject>()
            ui.post {
                if (!result.isDone) {
                    val response = try {
                        if (closed.get() || !alive()) JSONObject().put("error", "expired")
                        else (store()?.remote(request) ?: JSONObject().put("error", "storage_failed")).also { publishLibrary() }
                    } catch (_: Exception) { JSONObject().put("error", "storage_failed") }
                    result.complete(response)
                }
            }
            try { result.get(5, TimeUnit.SECONDS) }
            catch (_: Exception) { result.cancel(false); JSONObject().put("error", "storage_failed") }
        },
        onStop = {
            bookmarkServiceContext?.let { WebBookmarkService.end(it) }
            bookmarkServiceContext = null
        }
    )
    @Volatile private var state = "{}"
    init { WebBrowserSurfaceBridge.install(this) }

    // Select once before Gecko starts. The returned tier also keeps Godot in sync
    // if an earlier non-UI request has already created the process-wide runtime.
    fun configureViewport(lowEnd: Boolean): Boolean = viewport(lowEnd).lowEnd

    // Called from Godot's main thread several times per second: append, never reparse.
    @Volatile private var memoryCheckedAt = 0L
    @Volatile private var memoryTight = false
    /** Background extraction beside Gecko can push 6 GB headsets into killing the page process. */
    private fun memoryTight(): Boolean {
        val now = SystemClock.uptimeMillis()
        if (now - memoryCheckedAt > 2000) {
            memoryCheckedAt = now
            val manager = activity()?.getSystemService(android.content.Context.ACTIVITY_SERVICE) as? android.app.ActivityManager
            val info = android.app.ActivityManager.MemoryInfo()
            memoryTight = manager != null && runCatching { manager.getMemoryInfo(info); info.lowMemory || info.availMem < info.threshold * 2 }.getOrDefault(false)
        }
        return memoryTight
    }
    fun snapshot(): String = state.dropLast(1) + (if (state.length > 2) "," else "") + "\"session_ready\":" + cookies.isReady() + ",\"memory_tight\":" + memoryTight() + "}"
    /** Worker-only snapshot. Signed media locations never enter publish()/Godot/history. */
    fun mediaForExtraction(url: String): JSONObject? {
        check(Looper.myLooper() != Looper.getMainLooper())
        val result = java.util.concurrent.CompletableFuture<JSONObject?>()
        ui.post {
            val tab = current()
            val candidates = ArrayList<JSONObject>()
            if (!closed.get() && active && tab?.url == url) tab.sources.values.forEach { list ->
                for (i in 0 until list.length()) candidates.add(list.getJSONObject(i))
            }
            val chosen = candidates.maxWithOrNull(compareBy<JSONObject> { it.optBoolean("fullscreen") }.thenBy { it.optBoolean("playing") }
                .thenBy { it.optLong("width") * it.optLong("height") })
            result.complete(chosen?.let { JSONObject(it.toString()).put("title", tab?.title.orEmpty()) })
        }
        return result.get(5, TimeUnit.SECONDS)
    }
    fun cookiesForExtraction(url: String): JSONArray {
        check(Looper.myLooper() != Looper.getMainLooper())
        val started = java.util.concurrent.CompletableFuture<Unit>()
        ui.post {
            try { check(!closed.get() && ensure() != null); started.complete(Unit) }
            catch (error: Exception) { started.completeExceptionally(error) }
        }
        started.get(10, java.util.concurrent.TimeUnit.SECONDS)
        return cookies.snapshot(url)
    }
    fun captureFrame(done: (android.graphics.Bitmap?) -> Unit) {
        if (closed.get()) { done(null); return }
        dispatch {
            val current = window().display
            if (current == null) done(null)
            else current.capturePixels().accept({ bitmap -> done(bitmap) }, { _ -> done(null) })
        }
    }
    fun librarySnapshot(): String {
        val completed = libraryResult
        // The library republishes itself on every change; only the first read loads it.
        if (library == null) dispatch { store(); publishLibrary() }
        // Up to 1000 bookmarks are polled every second: append, never reparse on Godot's thread.
        return libraryState.dropLast(1) + ",\"operation\":" + completed + ",\"share\":" + bookmarkShare.status() + "}"
    }
    fun editLibrary(value: String): Int {
        if (closed.get() || value.length > 8 * 1024 * 1024) return -1
        val id = libraryRequest.incrementAndGet()
        ui.post {
            val error = try {
                if (closed.get()) "storage_failed" else {
                    val request = JSONObject(value)
                    when (request.optString("action")) {
                        "share_start" -> startBookmarkShare(request)
                        "share_stop" -> { bookmarkShare.close(); "" }
                        else -> store()?.edit(request) ?: "storage_failed"
                    }
                }
            } catch (_: Exception) { "storage_failed" }
            publishLibrary()
            libraryResult = JSONObject().put("id", id).put("state", if (error.isEmpty()) "saved" else "error")
                .put("error", error).toString()
        }
        return id
    }
    private fun startBookmarkShare(request: JSONObject): String {
        store() ?: return "storage_failed"
        if (bookmarkShare.status().optBoolean("active")) return ""
        val error = bookmarkShare.start(request.optBoolean("require_code", false))
        if (error.isNotEmpty()) return error
        return try {
            val context = activity()?.applicationContext ?: error("activity")
            val catalog = context.assets.open("translations.json").bufferedReader().use { JSONObject(it.readText()) }
            val title = catalog.optJSONObject(request.optString("language"))?.optString("Manage over Wi-Fi", "Manage over Wi-Fi") ?: "Manage over Wi-Fi"
            bookmarkServiceContext = context
            WebBookmarkService.begin(context, title) { bookmarkShare.close() }
            if (!bookmarkShare.status().optBoolean("active")) { WebBookmarkService.end(context); bookmarkServiceContext = null }
            ""
        } catch (_: Exception) { bookmarkShare.close(); "share_unavailable" }
    }
    fun setHistoryEnabled(enabled: Boolean) = dispatch { recordHistory = enabled; library?.recordHistory = enabled }
    fun clearHistory() = dispatch { store()?.clearHistory(); publishLibrary() }

    private fun store(): WebBrowserLibrary? {
        library?.let { return it }
        val app = activity()?.applicationContext ?: return null
        val directory = File(app.filesDir, "browser").also { it.mkdirs() }
        val file = AtomicFile(File(directory, "library.json"))
        val saved = runCatching { file.openRead().use { stream ->
            if (stream.channel.size() > 16 * 1024 * 1024) "{}" else stream.readBytes().toString(Charsets.UTF_8)
        } }.getOrDefault("{}")
        // Every write carries a sequence; an older queued visit never overwrites a newer edit.
        val sequence = java.util.concurrent.atomic.AtomicLong()
        var written = 0L
        fun write(json: String, at: Long) = synchronized(file) {
            if (at <= written) return@synchronized
            val output = file.startWrite()
            try { output.write(json.toByteArray(Charsets.UTF_8)); file.finishWrite(output); written = at }
            catch (error: Exception) { file.failWrite(output); throw error }
        }
        return WebBrowserLibrary(saved, saveLater = { json ->
            // Page-load visits must not fsync on the UI thread Gecko also uses.
            val at = sequence.incrementAndGet()
            historyWriter.execute { runCatching { write(json, at) } }
        }) { json -> write(json, sequence.incrementAndGet()) }.also { it.recordHistory = recordHistory; library = it }
    }
    private fun publishLibrary() { libraryState = library?.snapshot()?.toString() ?: libraryState }
    private fun networkPolicy(): WebBrowserNetworkPolicy? {
        networkPolicy?.let { return it }
        val app = activity()?.applicationContext ?: return null
        val preferences = app.getSharedPreferences("browser-network-media", android.content.Context.MODE_PRIVATE)
        return WebBrowserNetworkPolicy(preferences.getString("origins", "{}").orEmpty(), { value ->
            check(preferences.edit().putString("origins", value).commit())
        }).also { networkPolicy = it }
    }
    private fun networkEnabled(tab: Tab) = networkPolicy()?.enabled(tab.url) == true
    private fun sendNetworkPolicy(tab: Tab) {
        val message = JSONObject().put("action", "network_policy").put("enabled", networkEnabled(tab))
        tab.ports.keys.forEach { runCatching { it.postMessage(message) } }
    }
    private fun dispatch(action: () -> Unit) {
        if (closed.get()) return
        val runnable = Runnable {
            if (!closed.get()) {
                try { action() } catch (_: Exception) {
                    current()?.error = "browser_operation_failed"
                    publish()
                }
            }
        }
        if (Looper.myLooper() == Looper.getMainLooper()) runnable.run() else ui.post(runnable)
    }

    private fun ensure(): Tab? {
        current()?.let { return it }
        if (tabs.isNotEmpty()) {
            if (!roomForTab(null)) return null
            val created = createTab(focusedWindow)
            tabs.add(created); window().tab = created.id; layoutRevision++
            created.session.open(runtime!!); bindExtension(created)
            return created
        }
        val owner = activity() ?: return null
        val viewport = viewport()
        val engine = runtime ?: GeckoRuntime.create(owner.applicationContext,
            GeckoRuntimeSettings.Builder().remoteDebuggingEnabled(false).consoleOutput(false)
                .displayDensityOverride(viewport.density).displayDpiOverride(viewport.dpi)
                .screenSizeOverride(viewport.width, viewport.height).build()).also { runtime = it }
        val tab = createTab(focusedWindow)
        tabs.add(tab); window().tab = tab.id; layoutRevision++
        tab.session.open(engine)
        engine.webExtensionController.ensureBuiltIn("resource://android/assets/web-browser/", EXTENSION_ID)
            .accept({ installed ->
                if (!closed.get() && installed != null) {
                    extension = installed
                    cookies.bind(installed)
                    extensionState = "ready"
                    tabs.forEach(::bindExtension)
                    tabs.filter { it.awake }.forEach { item -> item.pendingUrl?.let { url -> item.pendingUrl = null; item.session.loadUri(url) } }
                    publish()
                }
            }, { _ ->
                extensionState = "failed"
                tabs.filter { it.awake }.forEach { item -> item.pendingUrl?.let { url -> item.pendingUrl = null; item.session.loadUri(url) } }
                publish()
            })
        publish()
        return tab
    }

    private fun createTab(windowId: Int, opener: Int = 0): Tab {
        val tab = Tab(++nextTabId, GeckoSession(GeckoSessionSettings.Builder()
            // Keep the existing default Gecko profile across app launches. Session close/pause
            // must not clear site data; history preference controls only our URL history.
            .usePrivateMode(false)
            .userAgentMode(GeckoSessionSettings.USER_AGENT_MODE_DESKTOP)
            .viewportMode(GeckoSessionSettings.VIEWPORT_MODE_DESKTOP)
            .suspendMediaWhenInactive(true).build()), windowId, opener)
        val session = tab.session
        // Keep Gecko's default TextInputDelegate: it forwards composition, selection,
        // cursor and keyboard lifecycle to Android's InputMethodManager. A partial custom
        // delegate would suppress those notifications and break CJK input.
        session.mediaSessionDelegate = object : MediaSession.Delegate {
            override fun onActivated(session: GeckoSession, mediaSession: MediaSession) {
                tab.playback = mediaSession
                if (!displayed(tab)) mediaSession.pause()
                else restoreMedia(tab)
            }
            override fun onDeactivated(session: GeckoSession, mediaSession: MediaSession) { tab.playback = null; tab.playing = false; publish() }
            override fun onPlay(session: GeckoSession, mediaSession: MediaSession) {
                tab.playing = true
                if (!displayed(tab)) mediaSession.pause()
                publish()
            }
            override fun onPause(session: GeckoSession, mediaSession: MediaSession) { tab.playing = false; publish() }
            override fun onStop(session: GeckoSession, mediaSession: MediaSession) { tab.playing = false; publish() }
        }
        session.navigationDelegate = object : GeckoSession.NavigationDelegate {
            override fun onLocationChange(session: GeckoSession, url: String?,
                perms: MutableList<GeckoSession.PermissionDelegate.ContentPermission>, hasUserGesture: Boolean) {
                if (tab.url != url) {
                    tab.sources.clear()
                    // Single-page sites change location without onPageStart. Leaving the page
                    // that held a focused field ends its unsent-input protection; otherwise one
                    // search-box tap pins the tab forever and blocks every later popup.
                    if (!tab.editing) tab.protectedInput = false
                }
                tab.url = url ?: "about:blank"
                sendNetworkPolicy(tab)
                // Re-evaluate the old automatic Netflix denial without clearing login data.
                // Reset only this EME decision; the normal delegate still checks focus/origin.
                for (perm in perms) {
                    if (perm.permission == GeckoSession.PermissionDelegate.PERMISSION_MEDIA_KEY_SYSTEM_ACCESS &&
                        perm.value == GeckoSession.PermissionDelegate.ContentPermission.VALUE_DENY &&
                        WebBrowserMediaPolicy.resetsLegacyDenial(tab.url, perm.uri, perm.thirdPartyOrigin)) {
                        runtime?.storageController?.setPermission(perm, GeckoSession.PermissionDelegate.ContentPermission.VALUE_PROMPT)
                    }
                }
                publish()
            }
            override fun onCanGoBack(session: GeckoSession, canGoBack: Boolean) { tab.back = canGoBack; publish() }
            override fun onCanGoForward(session: GeckoSession, canGoForward: Boolean) { tab.forward = canGoForward; publish() }
            override fun onLoadRequest(session: GeckoSession, request: GeckoSession.NavigationDelegate.LoadRequest): GeckoResult<AllowOrDeny> {
                val newWindow = request.target == GeckoSession.NavigationDelegate.TARGET_WINDOW_NEW
                if (!WebBrowserAddress.navigable(request.uri) || (newWindow && !request.hasUserGesture)) {
                    return GeckoResult.fromValue(AllowOrDeny.DENY)
                }
                if (active && current() === tab && WebBrowserNavigation.reusePage(tab.url, request.triggerUri,
                    request.uri, newWindow, request.hasUserGesture, request.isDirectNavigation, request.isRedirect)) {
                    val navigation = tab.navigation
                    // Resolve the original request first. Keep normal back history and Gecko's
                    // referrer policy; do not clear/recreate the logged-in browser on handoff.
                    ui.post {
                        if (!closed.get() && active && current() === tab && tab.navigation == navigation) {
                            hideInput(); operationError = ""
                            session.load(GeckoSession.Loader().uri(request.uri).referrer(session))
                            publish()
                        }
                    }
                    return GeckoResult.fromValue(AllowOrDeny.DENY)
                }
                return GeckoResult.fromValue(AllowOrDeny.ALLOW)
            }
            override fun onNewSession(session: GeckoSession, uri: String): GeckoResult<GeckoSession>? {
                if (current() !== tab || !WebBrowserAddress.navigable(uri) || !roomForTab(tab, true)) return null
                hideInput(); suspendTab(tab); releaseDisplay(window(tab.window))
                val child = createTab(tab.window, tab.id)
                tabs.add(child); window(tab.window).tab = child.id; layoutRevision++
                bindExtension(child)
                bindDisplay(child) // Gecko opens the returned session.
                publish()
                return GeckoResult.fromValue(child.session)
            }

            override fun onLoadError(session: GeckoSession, uri: String?, error: WebRequestError): GeckoResult<String>? {
                tab.error = "page_load_failed"; publish(); return null // Never bypass certificate failures.
            }
        }
        session.progressDelegate = object : GeckoSession.ProgressDelegate {
            override fun onSessionStateChange(session: GeckoSession, state: GeckoSession.SessionState) {
                if (tab.awake) tab.savedState = state
            }
            override fun onPageStart(session: GeckoSession, url: String) {
                if (!tab.awake) return
                tab.protectedInput = false
                tab.fullscreen.reset(); tab.fullscreenPort = null
                if (tab.restoreOrigin != url) { tab.restorePosition = null; tab.restoreOrigin = "" }
                if (tab.parkedReturn?.optString("origin") != url) tab.parkedReturn = null
                tab.capturedFullscreenRequest = 0L
                tab.navigation++; tab.media.clear(); tab.sources.clear(); tab.fullScreen = false; tab.editor = null; tab.editing = false
                tab.error = ""; tab.progress = 0; publish()
            }
            override fun onPageStop(session: GeckoSession, success: Boolean) {
                if (!tab.awake) return
                tab.progress = 100
                if (!success) tab.error = "page_load_failed"
                if (success) { store()?.visit(tab.url, tab.title, System.currentTimeMillis()); publishLibrary() }
                publish()
            }
            override fun onProgressChange(session: GeckoSession, progress: Int) { tab.progress = progress; publish() }
        }
        session.contentDelegate = object : GeckoSession.ContentDelegate {
            override fun onTitleChange(session: GeckoSession, title: String?) { tab.title = title.orEmpty().take(512); publish() }
            override fun onCloseRequest(session: GeckoSession) { if (tab.opener != 0) closeTab(tab) }
            override fun onFullScreen(session: GeckoSession, fullScreen: Boolean) {
                tab.fullScreen = fullScreen; updateFullscreen(tab); publish()
            }
            override fun onCrash(session: GeckoSession) { stoppedTab(tab, "browser_crashed") }
            override fun onKill(session: GeckoSession) { stoppedTab(tab, "browser_stopped") }
        }
        session.permissionDelegate = object : GeckoSession.PermissionDelegate {
            override fun onContentPermissionRequest(session: GeckoSession,
                perm: GeckoSession.PermissionDelegate.ContentPermission): GeckoResult<Int>? {
                if (perm.permission != GeckoSession.PermissionDelegate.PERMISSION_MEDIA_KEY_SYSTEM_ACCESS) return null
                val allowed = active && current() === tab && WebBrowserMediaPolicy.permitsKeys(tab.url, perm.uri, perm.thirdPartyOrigin)
                return GeckoResult.fromValue(if (allowed) GeckoSession.PermissionDelegate.ContentPermission.VALUE_ALLOW
                    else GeckoSession.PermissionDelegate.ContentPermission.VALUE_DENY)
            }
        }
        // Camera/microphone and other permissions retain Gecko's default rejection behavior.
        return tab
    }

    private fun bindExtension(tab: Tab) {
        val installed = extension ?: return
        tab.session.webExtensionController.setMessageDelegate(installed, object : WebExtension.MessageDelegate {
            override fun onConnect(port: WebExtension.Port) {
                if (!tab.awake || port.sender.session !== tab.session || port.sender.webExtension.id != EXTENSION_ID) { port.disconnect(); return }
                tab.ports[port] = tab.navigation
                port.setDelegate(object : WebExtension.PortDelegate {
                    override fun onPortMessage(message: Any, port: WebExtension.Port) {
                        if (closed.get() || !tab.awake || tab.ports[port] != tab.navigation) return
                        val data = message as? JSONObject ?: return
                        if (data.toString().length > 256 * 1024) return
                        if (data.optString("type") == "restore_video_result") {
                            if (port === tab.fullscreenPort && tab.fullscreen.matches(data.optLong("request"))) {
                                tab.restoreThroughScript = false
                                if (data.optBoolean("retry")) restoreMedia(tab) else tab.restorePosition = null
                            }
                            return
                        }
                        if (data.optString("type") != "media") return
                        val items = data.optJSONArray("videos") ?: return
                        val safe = JSONArray()
                        val privateSources = JSONArray()
                        for (index in 0 until minOf(16, items.length())) {
                            val item = items.optJSONObject(index) ?: continue
                            val id = item.optString("id").take(64)
                            val networkEnabled = networkEnabled(tab)
                            val network = if (networkEnabled) WebBrowserNetworkMedia.candidates(item) else JSONArray()
                            val server = !item.optBoolean("protected") && WebBrowserServerMedia.original(item.optString("source"), tab.url) != null
                            safe.put(JSONObject().put("width", item.optInt("width").coerceIn(0, 32768))
                                .put("id", id).put("fullscreen", item.optBoolean("fullscreen") || server && item.optBoolean("server_play"))
                                .put("server_play", server && item.optBoolean("server_play"))
                                .put("server_media", server)
                                .put("network_media", networkEnabled && (network.length() > 0 || !item.optBoolean("protected") && WebBrowserNetworkMedia.address(item.optString("source")) != null))
                                .put("media_epoch", "${System.identityHashCode(port)}:$id:${item.optLong("network_epoch")}")
                                .put("protected", item.optBoolean("protected"))
                                .put("height", item.optInt("height").coerceIn(0, 32768))
                                .put("playing", item.optBoolean("playing"))
                                .put("time", item.optDouble("time", 0.0).takeIf { it.isFinite() && it >= 0 } ?: 0.0))
                            val source = item.optString("source")
                            if (item.optString("frame").length <= 8192 && item.optString("agent").length <= 2048 &&
                                (source.isEmpty() || (source.length <= 16384 && (source.startsWith("https://") || source.startsWith("http://"))) || item.optBoolean("protected"))) {
                                privateSources.put(JSONObject(item.toString()).put("source", source.take(16384)).put("server", server)
                                    .put("network", network)
                                    .put("network_enabled", networkEnabled)
                                    .put("capture_identity", "${tab.id}:${tab.navigation}:${System.identityHashCode(port)}:$id:${item.optLong("network_epoch")}")
                                    .put("fullscreen", item.optBoolean("fullscreen") || server && item.optBoolean("server_play")))
                            }
                        }
                        tab.media[port] = safe
                        updateFullscreen(tab)
                        tab.sources[port] = privateSources
                        publish()
                    }
                    override fun onDisconnect(port: WebExtension.Port) {
                        tab.ports.remove(port); tab.media.remove(port); tab.sources.remove(port)
                        updateFullscreen(tab); publish()
                    }
                })
                port.postMessage(JSONObject().put("action", if (displayed(tab)) "resume" else "suspend"))
                port.postMessage(JSONObject().put("action", "network_policy").put("enabled", networkEnabled(tab)))
            }
        }, NATIVE_APP)
    }

    private fun updateFullscreen(tab: Tab) {
        val candidate = tab.media.entries.flatMap { (port, items) ->
            (0 until items.length()).map { items.getJSONObject(it) }
                .filter { it.optBoolean("fullscreen") && it.optString("id").isNotEmpty() }.map { port to it }
        }.maxWithOrNull(compareBy<Pair<WebExtension.Port, JSONObject>> { it.second.optBoolean("playing") }
            .thenBy { it.second.optLong("width") * it.second.optLong("height") })
        tab.fullscreen.update(tab.fullScreen || candidate?.second?.optBoolean("server_play") == true,
            candidate?.let { "${System.identityHashCode(it.first)}:${it.second.optString("id")}" }.orEmpty())
        if (tab.fullscreen.active) tab.fullscreenPort = candidate?.first
    }

    private fun restoreMedia(tab: Tab) {
        if (tab.restoreThroughScript) return
        val request = tab.restorePosition ?: return
        val media = tab.playback ?: return
        if (!active || current() !== tab || !media.isActive) return
        tab.restorePosition = null; tab.restoreOrigin = ""
        media.seekTo(request.first, false)
        if (request.second) media.play() else media.pause()
    }

    private fun videoReturn(request: JSONObject) {
        val tab = tabs.firstOrNull { it.id == request.optInt("tab") } ?: return
        val capture = request.optString("action") == "capture_video"
        val parked = tab.parkedReturn
        val parkedMatch = !capture && parked != null && parked.optLong("navigation") == request.optLong("navigation", -1) &&
            parked.optLong("request") == request.optLong("request", -1) && parked.optString("origin") == request.optString("origin")
        if (tab.url != request.optString("origin") || (!parkedMatch && (!tab.awake ||
            tab.navigation != request.optLong("navigation", -1) || !tab.fullscreen.matches(request.optLong("request"))))) return
        val port = if (parkedMatch) null else tab.fullscreenPort?.takeIf { tab.ports[it] == tab.navigation }
        if (capture) {
            if (!active || current() !== tab || !tab.fullscreen.active) return
            port?.postMessage(JSONObject().put("action", "capture_video").put("request", tab.fullscreen.request)
                .put("id", tab.fullscreen.video.substringAfter(':')))
            tab.capturedFullscreenRequest = tab.fullscreen.request
            return
        }
        val seconds = request.optDouble("position_ms", 0.0).takeIf { it.isFinite() && it >= 0 }?.div(1000.0) ?: return
        val play = request.optBoolean("play")
        val rawVideo = tab.fullscreen.video.substringAfter(':').toIntOrNull() != null
        // A closed-shadow declarative player may have no content-script video handle.
        if (!selectTab(tab)) return
        tab.parkedReturn = null
        tab.restorePosition = seconds to play; tab.restoreOrigin = tab.url
        tab.restoreThroughScript = port != null && rawVideo
        if (request.optBoolean("exit_fullscreen")) tab.session.exitFullScreen()
        if (port != null && rawVideo) port.postMessage(JSONObject().put("action", "restore_video")
            .put("request", tab.fullscreen.request).put("time", seconds).put("play", play))
        restoreMedia(tab)
    }

    fun navigate(value: String) = dispatch {
        val url = WebBrowserAddress.normalize(value)
        val tab = ensure() ?: return@dispatch
        if (url == null) { tab.error = "invalid_address"; publish(); return@dispatch }
        if (!tab.awake && !roomForSession(null)) return@dispatch
        hideInput()
        active = true
        tab.parkedReturn = null; tab.pendingUrl = null; tab.savedState = null
        tab.url = url; tab.title = ""
        wakeTab(tab, restore = false)
        bindDisplay(tab)
        tab.session.setFocused(true)
        attachInput(tab)
        if (extensionState == "pending") tab.pendingUrl = url else tab.session.loadUri(url)
        publish()
    }

    fun attach(value: Surface, w: Int, h: Int, id: Long, windowId: Int = 1): Boolean {
        if (closed.get() || windowId !in 1..windowLimit || !value.isValid || w !in 256..4096 || h !in 256..4096 || id <= 0) return false
        dispatch {
            val slot = window(windowId)
            if (id < slot.generation || id <= slot.detachedThrough || !value.isValid) return@dispatch
            releaseDisplay(slot)
            slot.surface = value; slot.width = w; slot.height = h; slot.generation = id; slot.needsSurface = false
            // Late Surface callbacks after the last close must not resurrect a blank tab.
            tabs.firstOrNull { it.id == slot.tab }?.let(::bindDisplay)
            publish()
        }
        return true
    }
    fun detach(id: Long, windowId: Int = 1) = dispatch { if (windowId in 1..4) detachNow(id, window(windowId)) }
    fun releaseForResize(id: Long, windowId: Int): Boolean {
        if (windowId !in 1..4) return false
        val finished = CountDownLatch(1)
        val release = {
            try {
                val slot = window(windowId)
                if (id == slot.generation) { releaseDisplay(slot); slot.surface = null }
                slot.detachedThrough = maxOf(slot.detachedThrough, id)
                publish()
            } finally { finished.countDown() }
        }
        if (Looper.myLooper() == Looper.getMainLooper()) release() else ui.post { release() }
        return try { finished.await(1500, TimeUnit.MILLISECONDS) } catch (_: InterruptedException) {
            Thread.currentThread().interrupt(); false
        }
    }
    private fun detachNow(id: Long, slot: Window) {
        if (id == slot.generation) {
            slot.owner?.let(::suspendTab)
            releaseDisplay(slot); slot.surface = null
            if (focusedWindow == slot.id) hideInput()
        }
        slot.detachedThrough = maxOf(slot.detachedThrough, id)
        publish()
    }
    fun detachBeforeSessionStop(id: Long, windowId: Int = 1): Boolean {
        if (windowId !in 1..4) return false
        if (Looper.myLooper() == Looper.getMainLooper()) { detachNow(id, window(windowId)); return true }
        val finished = CountDownLatch(1)
        ui.post { try { detachNow(id, window(windowId)) } finally { finished.countDown() } }
        return try { finished.await(1500, TimeUnit.MILLISECONDS) } catch (_: InterruptedException) {
            Thread.currentThread().interrupt(); false
        }
    }
    private fun bindDisplay(tab: Tab) {
        val slot = window(tab.window)
        val target = slot.surface ?: return
        if (!tab.awake || !target.isValid || !active || slot.tab != tab.id) return
        if (slot.owner === tab) return
        releaseDisplay(slot)
        val next = tab.session.acquireDisplay()
        slot.display = next; slot.owner = tab
        next.surfaceChanged(GeckoDisplay.SurfaceInfo.Builder(target).size(slot.width, slot.height)
            .newSurfaceProvider {
                if (slot.owner === tab) { releaseDisplay(slot); slot.needsSurface = true; publish() }
            }.build())
        tab.session.setActive(true)
        tab.session.setFocused(slot.id == focusedWindow)
        if (slot.id == focusedWindow) attachInput(tab)
        tab.ports.keys.forEach { runCatching { it.postMessage(JSONObject().put("action", "resume")) } }
    }
    private fun releaseDisplay(slot: Window) {
        val old = slot.display; val owner = slot.owner
        slot.display = null; slot.owner = null
        if (old != null && owner != null) { old.surfaceDestroyed(); owner.session.releaseDisplay(old) }
    }

    private fun suspendTab(tab: Tab) {
        if (!tab.awake) return
        tab.restorePosition = null; tab.restoreOrigin = ""; tab.restoreThroughScript = false
        tab.editor?.finishComposingText(); tab.editor = null; tab.editing = false
        tab.ports.keys.forEach { runCatching { it.postMessage(JSONObject().put("action", "suspend")) } }
        tab.playback?.pause()
        tab.session.setFocused(false)
        tab.session.setActive(false)
    }

    fun action(command: String) = dispatch {
        // Global unload must work even while the focused display has no selected tab.
        if (command == "hibernate") {
            active = false; hideInput(); windows.forEach(::releaseDisplay)
            tabs.forEach { parkTab(it, keepReturn = true) }
            publish(); return@dispatch
        }
        val tab = current() ?: (if (command == "resume") ensure() else null) ?: return@dispatch
        if (command in setOf("reload", "back", "forward") && !tab.awake) {
            // Gecko closes a killed/crashed session. Reloading that closed instance is a no-op.
            if (roomForSession(null)) { active = true; tab.touched = SystemClock.uptimeMillis(); wakeTab(tab); bindDisplay(tab) }
            publish(); return@dispatch
        }
        when (command) {
            "back" -> if (tab.fullScreen) tab.session.exitFullScreen() else if (tab.back) tab.session.goBack()
            "forward" -> if (tab.forward) tab.session.goForward()
            "reload" -> tab.session.reload()
            "stop" -> tab.session.stop()
            "pause" -> { active = false; tabs.forEach(::suspendTab); hideInput(); windows.forEach(::releaseDisplay) }
            "resume" -> {
                active = true
                windows.forEach { slot -> tabs.firstOrNull { it.id == slot.tab }?.let { wakeTab(it); bindDisplay(it) } }
            }
            "blur" -> { tab.session.setFocused(false); hideInput() }
            "bookmark" -> {
                operationError = try {
                    store()?.edit(JSONObject().put("action", "toggle_bookmark").put("url", tab.url).put("title", tab.title)) ?: "storage_failed"
                } catch (_: Exception) { "storage_failed" }
                publishLibrary()
            }
        }
        publish()
    }

    private fun linked(tab: Tab): Boolean = tab.awake && tabs.any { it.awake &&
        (it.id == tab.opener && tab.openerLinked || it.opener == tab.id && it.openerLinked) }
    private fun unlinkSession(tab: Tab) {
        tab.openerLinked = false
        tabs.filter { it.opener == tab.id }.forEach { it.openerLinked = false }
    }
    private fun clearDocument(tab: Tab) {
        tab.navigation++
        tab.ports.keys.toList().forEach { runCatching { it.disconnect() } }
        tab.ports.clear(); tab.media.clear(); tab.sources.clear()
        tab.fullscreen.reset(); tab.fullscreenPort = null; tab.capturedFullscreenRequest = 0
        tab.fullScreen = false; tab.playback = null; tab.playing = false
        tab.restorePosition = null; tab.restoreThroughScript = false; tab.restoreOrigin = ""
        tab.editor = null; tab.editing = false; tab.protectedInput = false
        unlinkSession(tab)
    }
    private fun stoppedTab(tab: Tab, error: String) {
        // onKill/onCrash means Gecko has already closed this session. Keep only its
        // last navigation snapshot; stale media and popup links must not occupy the budget.
        tab.awake = false
        if (window(tab.window).owner === tab) releaseDisplay(window(tab.window))
        clearDocument(tab)
        if (input?.tab === tab) { hideInput(); input?.tab = null }
        tab.error = error
        publish()
    }
    /** Extra visible windows expand the budget; background tabs still use the original two slots. */
    private fun roomForTab(replacing: Tab?, popup: Boolean = false, expanding: Boolean = false): Boolean {
        val manager = activity()?.getSystemService(android.content.Context.ACTIVITY_SERVICE) as? android.app.ActivityManager
        val memory = android.app.ActivityManager.MemoryInfo()
        manager?.getMemoryInfo(memory)
        if (memory.lowMemory || (expanding && memoryTight())) { operationError = "tabs_busy"; publish(); return false }
        if (tabs.size >= 4) { operationError = "tab_limit"; publish(); return false }
        return roomForSession(replacing, popup, liveLimit(windows.count { it.tab != 0 } + if (expanding) 1 else 0))
    }
    private fun roomForSession(replacing: Tab?, popup: Boolean = false, limit: Int = liveLimit()): Boolean {
        if (tabs.count { it.awake } < limit) return true
        val candidate = tabs.filter { it.awake && !it.protectedInput && !linked(it) &&
            (windows.none { slot -> slot.tab == it.id } || (!popup && it === replacing)) &&
            (it.savedState != null || it.url == "about:blank") }.minByOrNull { it.touched }
        if (candidate == null) { operationError = "tabs_busy"; publish(); return false }
        parkTab(candidate)
        return true
    }
    /** Close page docshells, scripts and decoders, retaining only Gecko's in-memory
     * history/form/scroll snapshot and our tab identity. Never clear the profile or
     * shut down the shared runtime: doing so would disrupt cookies and LAN sharing. */
    private fun parkTab(tab: Tab, keepReturn: Boolean = false) {
        if (!tab.awake) return
        if (keepReturn && tab.fullscreen.active) tab.parkedReturn = JSONObject()
            .put("navigation", tab.navigation).put("request", tab.fullscreen.request).put("origin", tab.url)
        suspendTab(tab)
        val slot = window(tab.window)
        if (slot.owner === tab) releaseDisplay(slot)
        clearDocument(tab)
        tab.session.textInput.setView(null)
        if (input?.tab === tab) input?.tab = null
        // Mark asleep before callbacks from close can update stale page state.
        tab.awake = false; tab.session.stop(); tab.session.close()
    }
    private fun wakeTab(tab: Tab, restore: Boolean = true) {
        if (tab.awake) return
        tab.session.open(runtime!!); tab.awake = true; tab.error = ""; operationError = ""; bindExtension(tab)
        if (restore) {
            val pending = tab.pendingUrl
            if (pending != null) {
                if (extensionState != "pending") { tab.pendingUrl = null; tab.session.loadUri(pending) }
            } else tab.savedState?.let { tab.session.restoreState(it) } ?: tab.session.loadUri(tab.url)
        }
    }
    private fun selectTab(tab: Tab): Boolean {
        val slot = window(tab.window)
        val previous = tabs.firstOrNull { it.id == slot.tab }
        if (!tab.awake && !roomForSession(previous)) return false
        hideInput(); previous?.let(::suspendTab); releaseDisplay(slot)
        wakeTab(tab)
        slot.tab = tab.id; tab.touched = SystemClock.uptimeMillis(); active = true
        focusWindow(slot.id); bindDisplay(tab); publish(); return true
    }
    private fun focusWindow(id: Int) {
        if (id !in 1..windowLimit || window(id).tab == 0) return
        if (id != focusedWindow) {
            hideInput()
            current()?.let { old ->
                // Focus moves the input/keyboard only. A second visible window keeps playing.
                old.session.setFocused(false)
            }
        }
        focusedWindow = id
        current()?.let { tab ->
            if (tab.awake) { tab.session.setFocused(true); attachInput(tab)
                tab.ports.keys.forEach { runCatching { it.postMessage(JSONObject().put("action", "resume")) } }
            }
        }
    }
    private fun layout() = WebBrowserWindowLayout(tabs.map { WebBrowserWindowLayout.Tab(it.id, it.window, it.opener) },
        windows.filter { it.tab != 0 }.associate { it.id to it.tab }, focusedWindow)

    private fun applyLayout(plan: WebBrowserWindowLayout): Boolean {
        val before = layout()
        if (before == plan) return true
        val retained = plan.tabs.map { it.id }.toSet()
        val visible = plan.selected.values.toSet()
        val required = tabs.count { it.id in retained && (it.awake || it.id in visible) }
        val limit = liveLimit(plan.selected.size)
        val reclaimable = tabs.filter { it.id in retained && it.awake && it.id !in visible && !it.protectedInput && !linked(it) &&
            (it.savedState != null || it.url == "about:blank") }.sortedBy { it.touched }
        // Merging must not discard unsent fields or opener chains to meet the smaller
        // background target. Keep those sessions within the device's hard window budget.
        if ((plan.selected.size > before.selected.size && memoryTight()) || required - windowLimit > reclaimable.size) {
            operationError = "tabs_busy"; publish(); return false
        }
        changingLayout = true
        try {
            hideInput(); downTime = 0
            // Only changed displays are released: a surviving cinema page never blinks or pauses.
            windows.filter { it.tab != (plan.selected[it.id] ?: 0) }.forEach(::releaseDisplay)
            tabs.filter { it.id !in visible }.forEach(::suspendTab)
            val removed = tabs.filter { it.id !in retained }
            tabs.removeAll(removed.toSet())
            removed.forEach { tab ->
                val wasAwake = tab.awake; tab.awake = false
                unlinkSession(tab)
                tab.ports.keys.toList().forEach { runCatching { it.disconnect() } }; tab.ports.clear()
                tab.session.textInput.setView(null)
                if (input?.tab === tab) input?.tab = null
                if (wasAwake) tab.session.close()
            }
            val byId = tabs.associateBy { it.id }
            tabs.clear()
            plan.tabs.forEach { entry -> byId[entry.id]?.let { it.window = entry.window; tabs.add(it) } }
            windows.forEach { it.tab = plan.selected[it.id] ?: 0 }
            reclaimable.take(maxOf(0, required - limit)).forEach(::parkTab)
            if (tabs.isEmpty()) { active = false; focusedWindow = 1 }
            else {
                plan.selected.values.forEach { id -> tabs.first { it.id == id }.let { wakeTab(it); bindDisplay(it) } }
                focusWindow(plan.focused)
            }
            layoutRevision++
        } finally { changingLayout = false }
        publish(); return true
    }
    private fun closeTab(tab: Tab) { applyLayout(layout().close(setOf(tab.id))) }
    fun command(value: String) = dispatch {
        if (value.length > 8192) return@dispatch
        val request = JSONObject(value)
        val id = request.optInt("window", focusedWindow)
        if (id !in 1..windowLimit) return@dispatch
        operationError = ""
        when (request.optString("action")) {
            "network_capture" -> {
                val tab = tabs.firstOrNull { it.id == window(id).tab } ?: return@dispatch
                networkPolicy()?.set(tab.url, request.optBoolean("enabled"))
                tabs.filter { WebBrowserNetworkPolicy.origin(it.url) == WebBrowserNetworkPolicy.origin(tab.url) }.forEach { item ->
                    item.sources.clear()
                    item.media.values.forEach { list -> for (index in 0 until list.length()) list.getJSONObject(index).put("network_media", false) }
                    sendNetworkPolicy(item)
                }
            }
            "capture_video", "restore_video" -> videoReturn(request)
            "pause_tab", "resume_tab" -> {
                val tab = tabs.firstOrNull { it.id == request.optInt("tab") && it.window == id } ?: return@dispatch
                if (!tab.awake || window(id).tab != tab.id || tab.navigation != request.optLong("navigation", -1) ||
                    tab.url != request.optString("origin")) return@dispatch
                if (request.optString("action") == "pause_tab") {
                    tab.pauseToken = request.optLong("pause_token")
                    tab.playback?.pause()
                    tab.ports.keys.forEach { runCatching { it.postMessage(JSONObject().put("action", "pause_media")) } }
                } else if (tab.pauseToken == request.optLong("pause_token")) {
                    tab.pauseToken = 0
                    if (request.optBoolean("was_playing")) tab.playback?.play()
                }
            }
            "focus" -> focusWindow(id)
            "new", "new_window" -> {
                if (runtime == null) { ensure(); return@dispatch }
                val separate = request.optString("action") == "new_window"
                val destination = if (separate) freeWindow() else id
                if (destination == null) { operationError = "window_limit"; publish(); return@dispatch }
                if (!roomForTab(if (separate) null else tabs.firstOrNull { it.id == window(id).tab }, expanding = separate)) return@dispatch
                val tab = createTab(destination); tabs.add(tab); layoutRevision++; tab.session.open(runtime!!); bindExtension(tab)
                selectTab(tab); tab.session.loadUri("about:blank")
            }
            "select" -> tabs.firstOrNull { it.id == request.optInt("tab") && it.window == id }?.let(::selectTab)
            "close" -> tabs.firstOrNull { it.id == request.optInt("tab") && it.window == id }?.let(::closeTab)
            "close_window" -> applyLayout(layout().close(tabs.filter { it.window == id }.map { it.id }.toSet()))
            "detach", "merge", "move_tab", "merge_window" -> {
                val action = request.optString("action")
                val moving = tabs.filter { it.window == id && (action == "merge_window" || it.id == request.optInt("tab")) }
                if (moving.isEmpty()) return@dispatch
                val destination = when {
                    request.optInt("destination") > 0 -> request.optInt("destination")
                    action == "detach" || action == "move_tab" -> freeWindow()
                    else -> windows.firstOrNull { it.id != id && it.tab != 0 }?.id
                }
                if (destination == null || destination !in 1..windowLimit || destination == id ||
                    (action == "merge_window" && window(destination).tab == 0)) {
                    operationError = "window_limit"; publish(); return@dispatch
                }
                applyLayout(layout().move(moving.map { it.id }.toSet(), destination))
            }
        }
        publish()
    }
    fun windowPointer(windowId: Int, command: String, x: Float, y: Float, scroll: Float) = dispatch {
        if (windowId !in 1..windowLimit) return@dispatch
        if (command == "down") focusWindow(windowId)
        if (windowId == focusedWindow) pointer(command, x, y, scroll)
    }

    fun pointer(command: String, x: Float, y: Float, scroll: Float) = dispatch {
        if (!active || window().display == null || !x.isFinite() || !y.isFinite() || !scroll.isFinite()) return@dispatch
        val tab = current() ?: return@dispatch
        if (command == "down") { tab.session.setFocused(true); input?.requestFocus() }
        val now = SystemClock.uptimeMillis()
        val code = when (command) {
            "down" -> { downTime = now; MotionEvent.ACTION_DOWN }
            "move" -> if (downTime > 0) MotionEvent.ACTION_MOVE else MotionEvent.ACTION_HOVER_MOVE
            "up" -> if (downTime > 0) MotionEvent.ACTION_UP else return@dispatch
            "cancel" -> if (downTime > 0) MotionEvent.ACTION_CANCEL else return@dispatch
            "scroll" -> MotionEvent.ACTION_SCROLL
            else -> return@dispatch
        }
        val mouse = code == MotionEvent.ACTION_HOVER_MOVE || code == MotionEvent.ACTION_SCROLL
        val properties = MotionEvent.PointerProperties().apply { id = 0; toolType = if (mouse) MotionEvent.TOOL_TYPE_MOUSE else MotionEvent.TOOL_TYPE_FINGER }
        val coordinates = MotionEvent.PointerCoords().apply {
            this.x = x.coerceIn(0f, 1f) * (window().width - 1); this.y = y.coerceIn(0f, 1f) * (window().height - 1)
            pressure = if (mouse) 0f else 1f; size = 1f
            if (code == MotionEvent.ACTION_SCROLL) setAxisValue(MotionEvent.AXIS_VSCROLL, scroll.coerceIn(-8f, 8f))
        }
        val event = MotionEvent.obtain(if (downTime > 0) downTime else now, now, code, 1, arrayOf(properties), arrayOf(coordinates),
            0, 0, 1f, 1f, 0, 0, if (mouse) InputDevice.SOURCE_MOUSE else InputDevice.SOURCE_TOUCHSCREEN, 0)
        try {
            if (mouse) tab.session.panZoomController.onMotionEvent(event) else tab.session.panZoomController.onTouchEvent(event)
        } finally { event.recycle() }
        if (code == MotionEvent.ACTION_UP || code == MotionEvent.ACTION_CANCEL) downTime = 0
    }

    private inner class BrowserInput(owner: Activity) : View(owner) {
        var tab: Tab? = null
        init { isFocusable = true; isFocusableInTouchMode = true; importantForAutofill = IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS }
        override fun onCheckIsTextEditor(): Boolean = true
        override fun getHandler(): Handler = tab?.session?.textInput?.getHandler(super.getHandler()) ?: super.getHandler()
        override fun onCreateInputConnection(info: EditorInfo): InputConnection? {
            val owner = tab ?: return null
            val navigation = owner.navigation
            val connection = owner.session.textInput.onCreateInputConnection(info)
            ui.post {
                if (tab === owner && owner.navigation == navigation && active && current() === owner) {
                    owner.editor = connection
                    owner.editorAction = info.imeOptions and EditorInfo.IME_MASK_ACTION
                    owner.editing = connection != null && info.inputType != 0
                    if (owner.editing) owner.protectedInput = true
                    publish()
                }
            }
            return connection
        }
        override fun onKeyPreIme(code: Int, event: KeyEvent): Boolean = tab?.session?.textInput?.onKeyPreIme(code, event) ?: false
        override fun onKeyDown(code: Int, event: KeyEvent): Boolean = tab?.session?.textInput?.onKeyDown(code, event) ?: false
        override fun onKeyUp(code: Int, event: KeyEvent): Boolean = tab?.session?.textInput?.onKeyUp(code, event) ?: false
    }

    /** Debug caller only; exercises the very same host connection used by Android IME. */
    fun probeSystemInput(done: (JSONObject) -> Unit) {
        check(Looper.myLooper() == Looper.getMainLooper())
        val view = input
        val owner = view?.tab
        val editor = owner?.editor
        if (view == null || owner == null || editor == null || !owner.editing) {
            done(JSONObject().put("connected", false)); return
        }
        val manager = view.context.getSystemService(android.content.Context.INPUT_METHOD_SERVICE) as android.view.inputmethod.InputMethodManager
        val result = JSONObject().put("served", manager.isActive(view)).put("connected", true)
        val navigation = owner.navigation
        // Gecko silently ignores edits on the wrong thread. Use the handler Android
        // uses for this connection, and never recreate the system's active editor.
        (editor.handler ?: view.handler).post {
            try {
                check(view.tab === owner && owner.navigation == navigation)
                editor.beginBatchEdit()
                try {
                    result.put("composing", editor.setComposingText("浏览", 1))
                    result.put("committed", editor.commitText("浏览器测试🙂", 1))
                } finally { editor.endBatchEdit() }
            } catch (_: Exception) { result.put("committed", false) }
            ui.post { done(result) }
        }
    }

    fun input(command: String, text: String) = dispatch {
        val tab = current() ?: return@dispatch
        if (!active || !tab.editing) return@dispatch
        val editor = tab.editor ?: return@dispatch
        if (command == "close") {
            tab.session.setFocused(false); hideInput(); publish(); return@dispatch
        }
        val value = if (command == "paste") {
            val clipboard = activity()?.getSystemService(android.content.Context.CLIPBOARD_SERVICE) as? android.content.ClipboardManager
            clipboard?.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.text?.toString()?.take(2048).orEmpty()
        } else text
        val navigation = tab.navigation
        val action = tab.editorAction
        (editor.handler ?: ui).post {
            if (input?.tab !== tab || tab.navigation != navigation || tab.editor !== editor) return@post
            when (command) {
                "text", "paste" -> if (value.length <= 2048 && '\u0000' !in value) editor.commitText(value, 1)
                "backspace" -> editor.deleteSurroundingTextInCodePoints(1, 0)
                "enter" -> {
                    if (action in setOf(EditorInfo.IME_ACTION_NONE, EditorInfo.IME_ACTION_UNSPECIFIED) || !editor.performEditorAction(action)) {
                        editor.sendKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_ENTER))
                        editor.sendKeyEvent(KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_ENTER))
                    }
                }
            }
        }
    }

    private fun attachInput(tab: Tab) {
        val owner = activity() ?: return
        val view = input ?: BrowserInput(owner).also {
            (owner.window.decorView as ViewGroup).addView(it, ViewGroup.LayoutParams(1, 1)); input = it
        }
        if (view.tab !== tab) {
            view.tab?.session?.textInput?.setView(null)
            view.tab = tab
            tab.session.textInput.setView(view)
        }
        // This attached host exposes Gecko's editor directly to the system keyboard.
        // Field values and passwords never travel through the Godot UI snapshot.
        view.requestFocus()
    }

    private fun hideInput() {
        tabs.forEach { tab ->
            tab.editor?.let { editor -> (editor.handler ?: ui).post { editor.finishComposingText() } }
            tab.editing = false; tab.editor = null
        }
        input?.let { view ->
            val imm = view.context.getSystemService(android.content.Context.INPUT_METHOD_SERVICE) as android.view.inputmethod.InputMethodManager
            imm.hideSoftInputFromWindow(view.windowToken, 0)
            view.clearFocus()
        }
        downTime = 0
    }

    private fun tabState(tab: Tab?): JSONObject {
        val videos = JSONArray()
        tab?.media?.values?.forEach { list -> for (index in 0 until list.length()) if (videos.length() < 16) videos.put(list.getJSONObject(index)) }
        return JSONObject().put("tab_id", tab?.id ?: 0).put("navigation", tab?.navigation ?: 0)
            .put("network_capture_available", tab != null && WebBrowserNetworkPolicy.available(tab.url))
            .put("network_capture_enabled", tab != null && networkEnabled(tab))
            .put("fullscreen_request", tab?.fullscreen?.request ?: 0).put("fullscreen_video", tab?.fullscreen?.active == true)
            .put("captured_fullscreen_request", tab?.capturedFullscreenRequest ?: 0)
            .put("url", tab?.url ?: "about:blank").put("title", tab?.title.orEmpty())
            .put("bookmark_url", tab?.url?.let(WebBrowserAddress::recordable).orEmpty())
            .put("progress", tab?.progress ?: 0).put("back", tab?.back == true || tab?.fullScreen == true).put("forward", tab?.forward == true)
            .put("pause_token", tab?.pauseToken ?: 0)
            .put("playing", tab != null && (tab.playing || tab.media.values.any { list -> (0 until list.length()).any { i -> list.getJSONObject(i).optBoolean("playing") } }))
            .put("error", tab?.error.orEmpty()).put("editing", tab?.editing == true).put("videos", videos).put("fullscreen", tab?.fullScreen == true)
    }
    private fun publish() {
        if (changingLayout) return
        val slots = JSONArray()
        windows.forEach { slot ->
            slots.put(tabState(tabs.firstOrNull { it.id == slot.tab }).put("id", slot.id)
                .put("attached", slot.display != null).put("generation", slot.generation)
                .put("detached_through", slot.detachedThrough).put("needs_surface", slot.needsSurface))
        }
        val entries = JSONArray()
        tabs.forEach { tab -> entries.put(JSONObject().put("id", tab.id).put("window", tab.window)
            .put("title", tab.title).put("url", tab.url).put("sleeping", !tab.awake).put("protected", tab.protectedInput || linked(tab))) }
        val slot = window()
        state = tabState(current()).put("engine", "GeckoView").put("active", active)
            .put("attached", slot.display != null).put("generation", slot.generation)
            .put("detached_through", slot.detachedThrough).put("needs_surface", slot.needsSurface)
            .put("playing", tabs.any { it.playing || it.media.values.any { list -> (0 until list.length()).any { i -> list.getJSONObject(i).optBoolean("playing") } } })
            .put("focused_window", focusedWindow).put("windows", slots).put("tab_list", entries)
            .put("operation_error", operationError).put("live_tabs", tabs.count { it.awake })
            .put("max_windows", windowLimit).put("max_live_tabs", windowLimit).put("layout_revision", layoutRevision)
            .put("extension", extensionState).put("tabs", tabs.size).toString()
    }

    /** Only for process exit/restart: Gecko cannot be started again in this process.
     * Session inactivity/flushSessionState does not commit localStorage to disk. Let
     * Gecko finish its profile shutdown before Godot terminates the Android process.
     * No website credentials are exported, and the Android UI thread never waits.
     */
    fun shutdownForAppExit(done: () -> Unit) {
        if (!exiting.compareAndSet(false, true)) return
        ui.post {
            val engine = runtime
            if (engine == null) { close(); done(); return@post }
            val completed = AtomicBoolean(false)
            val finish = Runnable { if (completed.compareAndSet(false, true)) done() }
            val timeout = Runnable {
                if (!completed.get()) {
                    android.util.Log.w("Thru3DBrowserPersistence", "shutdown_timeout")
                    finish.run()
                }
            }
            engine.delegate = object : GeckoRuntime.Delegate {
                override fun onShutdown() {
                    ui.removeCallbacks(timeout)
                    android.util.Log.i("Thru3DBrowserPersistence", "shutdown_complete")
                    finish.run()
                }
            }
            // Bound a broken engine's shutdown, without treating the timeout as a save.
            ui.postDelayed(timeout, 15_000)
            try {
                // Official release Gecko otherwise calls _exit during native shutdown,
                // before onShutdown can hand control back to Godot (breaking restart).
                // Change only this process's default branch, not the saved user profile.
                GeckoPreferenceController.setGeckoPref("toolkit.shutdown.fastShutdownStage", 0,
                    GeckoPreferenceController.PREF_BRANCH_DEFAULT).accept({
                        try { close(); engine.shutdown() }
                        catch (_: Exception) {
                            ui.removeCallbacks(timeout)
                            android.util.Log.w("Thru3DBrowserPersistence", "shutdown_failed")
                            finish.run()
                        }
                    }, { _ ->
                        ui.removeCallbacks(timeout)
                        android.util.Log.w("Thru3DBrowserPersistence", "shutdown_failed")
                        finish.run()
                    })
            } catch (_: Exception) {
                ui.removeCallbacks(timeout)
                android.util.Log.w("Thru3DBrowserPersistence", "shutdown_failed")
                finish.run()
            }
        }
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        bookmarkShare.close()
        WebBrowserSurfaceBridge.remove(this)
        val cleanup = Runnable {
            cookies.close()
            tabs.forEach(::suspendTab); windows.forEach(::releaseDisplay); hideInput()
            input?.let { (it.parent as? ViewGroup)?.removeView(it) }; input = null
            tabs.forEach { it.session.textInput.setView(null); if (it.awake) it.session.close() }; tabs.clear()
            windows.forEach { it.surface = null; it.tab = 0 }; active = false; publish()
        }
        if (Looper.myLooper() == Looper.getMainLooper()) cleanup.run() else ui.post(cleanup)
    }
}
