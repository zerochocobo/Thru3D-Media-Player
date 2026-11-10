package org.vrpassthroughplayer.plugin

import android.app.Activity
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.InputDevice
import android.view.KeyEvent
import android.view.KeyCharacterMap
import android.view.MotionEvent
import android.view.Surface
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.view.inputmethod.BaseInputConnection
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
        // Gecko owns a profile separate from Android WebView; account login pages share it.
        // A process has one runtime; recreating an Activity closes its sessions, not Gecko itself.
        private var runtime: GeckoRuntime? = null
        private var runtimeViewport: WebBrowserViewport? = null
        @Synchronized private fun viewport(lowEnd: Boolean = false): WebBrowserViewport =
            runtimeViewport ?: WebBrowserViewport(lowEnd).also { runtimeViewport = it }
        internal fun loginViewport(): WebBrowserViewport = viewport()
        /** One process runtime; login sessions share the profile but have no ordinary tab delegates. */
        internal fun engine(owner: Activity): GeckoRuntime {
            check(Looper.myLooper() == Looper.getMainLooper())
            val profile = viewport()
            return runtime ?: GeckoRuntime.create(owner.applicationContext,
                GeckoRuntimeSettings.Builder().remoteDebuggingEnabled(false).consoleOutput(false)
                    .displayDensityOverride(profile.density).displayDpiOverride(profile.dpi)
                    .screenSizeOverride(profile.width, profile.height).build()).also { runtime = it }
        }
    }
    private class Tab(val id: Int, var session: GeckoSession, var window: Int, val opener: Int = 0) {
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
        var loading = false
        var startPage = true
        var back = false
        var forward = false
        var editing = false
        var keyboardVisible = false
        var keyboardManual = false
        var editor: InputConnection? = null
        var editorAction = EditorInfo.IME_ACTION_UNSPECIFIED
        var editorType = 0
        var error = ""
        var navigation = 0L
        var playback: MediaSession? = null
        var playing = false
        var pauseToken = 0L
        var lastMediaReport = 0L
        var pauseWasPlaying = false
        var pauseHasDom = false
        val pauseReports = mutableMapOf<WebExtension.Port, Pair<Long, Boolean>>()
        val ports = mutableMapOf<WebExtension.Port, Long>()
        val media = mutableMapOf<WebExtension.Port, JSONArray>()
        val fullscreen = WebBrowserFullscreen()
        var fullscreenPort: WebExtension.Port? = null
        var restorePosition: Pair<Double, Boolean>? = null
        var restoreThroughScript = false
        var restoreOrigin = ""
        var capturedFullscreenRequest = 0L
        // P0 is per-tab and process-local. Production remains on the verified backend
        // until the pinned Gecko response/SPA and device playback gates have passed.
        var bilibiliProbe = "off"
        var douyinCaptureEnabled = true
        val sources = mutableMapOf<WebExtension.Port, JSONArray>()
        val weiboClicks = mutableMapOf<WebExtension.Port, Long>()
        var weiboRequest = 0L
        var weiboSelection = ""
        val bilibiliClicks = mutableMapOf<WebExtension.Port, Long>()
        val tencentClicks = mutableMapOf<WebExtension.Port, Long>()
        val mangoClicks = mutableMapOf<WebExtension.Port, Long>()
        val youkuClicks = mutableMapOf<WebExtension.Port, Long>()
        val niconicoClicks = mutableMapOf<WebExtension.Port, Long>()
        val twitchClicks = mutableMapOf<WebExtension.Port, Long>()
        val tiktokClicks = mutableMapOf<WebExtension.Port, Long>()
        val instagramClicks = mutableMapOf<WebExtension.Port, Long>()
        val instagramReturns = mutableMapOf<String,Pair<WebExtension.Port,JSONObject>>()
        val tedClicks = mutableMapOf<WebExtension.Port, Long>()
        val redbullClicks = mutableMapOf<WebExtension.Port, Long>()
        val streamableClicks = mutableMapOf<WebExtension.Port, Long>()
        val redditClicks = mutableMapOf<WebExtension.Port, Long>()
        val naverReturns = mutableMapOf<String,Pair<WebExtension.Port,JSONObject>>()
        val naverClicks = mutableMapOf<WebExtension.Port, Long>()
        val archiveClicks = mutableMapOf<WebExtension.Port, Long>()
        val odyseeClicks = mutableMapOf<WebExtension.Port, Long>()
        val dailymotionClicks = mutableMapOf<WebExtension.Port, Long>()
        val iqiyiClicks = mutableMapOf<WebExtension.Port, Long>()
        val douyinClicks = mutableMapOf<WebExtension.Port, Long>()
        var betaRequest = 0L
        var betaSelection = ""
        var fullScreen = false
    }
    private val ui = Handler(Looper.getMainLooper())
    private val closed = AtomicBoolean(false)
    private val exiting = AtomicBoolean(false)
    private val tabs = mutableListOf<Tab>()
    private val playbackHold = WebBrowserPlaybackHold()
    private class PendingRetention(val owner: WebBrowserPlaybackHold.Owner, val ports: Set<WebExtension.Port>,
        val ticket: WebBrowserMediaRelease.Ticket) { val suspended = mutableSetOf<WebExtension.Port>() }
    private var pendingRetention: PendingRetention? = null
    private fun invalidatePlaybackHold(tab: Tab) {
        playbackHold.invalidate(tab.id)
        pendingRetention?.takeIf { it.owner.tab == tab.id }?.let { it.ticket.complete(false); pendingRetention = null }
    }
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
    private var nextBetaRequest = 0L
    private var operationError = ""
    private fun window(id: Int = focusedWindow) = windows.first { it.id == id }
    private fun current(): Tab? = tabs.firstOrNull { it.id == window().tab }
    private fun displayed(tab: Tab): Boolean = active && tab.awake && window(tab.window).tab == tab.id
    private var active = false
    private var downTime = 0L
    private var input: BrowserInput? = null
    @Volatile private var customKeyboard = false
    private val keyboardSession = WebBrowserKeyboardSession()
    private var keyboardShowSerial = 0L
    private var keyboardEditorSerial = 0L
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
        return mediaForSelectedExtraction(url, "")
    }
    fun mediaForSelectedExtraction(url: String, selection: String): JSONObject? {
        check(Looper.myLooper() != Looper.getMainLooper())
        val result = java.util.concurrent.CompletableFuture<JSONObject?>()
        ui.post {
            val tab = current()
            val candidates = ArrayList<JSONObject>()
            if (!closed.get() && active && tab?.url == url) tab.sources.values.forEach { list ->
                for (i in 0 until list.length()) candidates.add(list.getJSONObject(i))
            }
            val chosen = if (selection.isEmpty()) WebBrowserMediaPolicy.extractionCandidate(candidates)
                else WebBrowserMediaPolicy.selectedCandidate(candidates, selection)
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
    private fun bilibiliEligible(tab: Tab) = networkPolicy()?.bilibiliEnabled(tab.url) == true
    // Prepare the explicitly selectable Beta route while the page loads; selection is
    // separate from observation so the existing player button keeps its old backend.
    private fun bilibiliEnabled(tab: Tab) = tab.bilibiliProbe !in setOf("uncapped", "network") && bilibiliEligible(tab)
    private fun douyinEnabled(tab: Tab) = WebBrowserDouyin.enabled(tab.url, tab.douyinCaptureEnabled)
    private fun networkEnabled(tab: Tab) = networkPolicy()?.enabled(tab.url) == true || tab.bilibiliProbe == "network" && bilibiliEligible(tab)
    /** Debug-only A/B/C/P0b comparison; no persistent preference, reload or account changes. */
    fun configureBilibiliProbe(tabId: Int, mode: String) {
        check(Looper.myLooper() == Looper.getMainLooper())
        check((activity()?.applicationInfo?.flags ?: 0) and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE != 0)
        require(mode in setOf("off", "uncapped", "network", "adapter"))
        val tab = current() ?: error("No focused tab")
        require(tab.id == tabId && (mode == "off" || bilibiliEligible(tab)))
        tab.bilibiliProbe = mode; tab.sources.clear(); tab.media.clear()
        sendNetworkPolicy(tab); publish()
    }
    /** Debug-only process-local override; normal Beta capture is enabled by default. */
    fun configureDouyinProbe(tabId: Int, enabled: Boolean) {
        check(Looper.myLooper() == Looper.getMainLooper())
        check((activity()?.applicationInfo?.flags ?: 0) and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE != 0)
        val tab = tabs.firstOrNull { it.id == tabId } ?: if (!enabled) return else error("Unknown tab")
        require(!enabled || current() === tab && WebBrowserDouyin.document(tab.url))
        tab.douyinCaptureEnabled = enabled; tab.sources.clear(); tab.media.clear()
        sendNetworkPolicy(tab); publish()
    }
    private fun sendNetworkPolicy(tab: Tab) {
        val message = JSONObject().put("action", "network_policy").put("enabled", networkEnabled(tab))
            .put("tencent",WebBrowserTencent.enabled(tab.url)).put("mango",WebBrowserMango.enabled(tab.url)).put("youku",WebBrowserYouku.enabled(tab.url)).put("iqiyi",WebBrowserIqiyi.enabled(tab.url)).put("niconico",WebBrowserNiconico.observing(tab.url)).put("twitch",WebBrowserTwitch.enabled(tab.url)).put("tiktok",WebBrowserTikTok.observing(tab.url)).put("instagram",WebBrowserInstagram.observing(tab.url)).put("ted",WebBrowserTed.observing(tab.url)).put("redbull",WebBrowserRedBull.observing(tab.url)).put("naver",WebBrowserNaver.observing(tab.url)).put("reddit",WebBrowserReddit.observing(tab.url)).put("streamable",WebBrowserStreamable.observing(tab.url)).put("archive",WebBrowserArchive.observing(tab.url)).put("odysee",WebBrowserOdysee.observing(tab.url)).put("dailymotion",WebBrowserDailymotion.observing(tab.url)).put("dailymotion_owner",tab.url.takeIf{WebBrowserDailymotion.observing(it)}.orEmpty())
            .put("bilibili", bilibiliEnabled(tab)).put("douyin", douyinEnabled(tab)).put("weibo", WebBrowserWeibo.document(tab.url)).put("diagnostics", mediaDiagnosticsEnabled())
        tab.ports.keys.forEach { runCatching { it.postMessage(message) } }
    }
    private fun mediaDiagnosticsEnabled() = ((activity()?.applicationInfo?.flags ?: 0) and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0
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
        val engine = engine(owner)
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

    private fun newSession() = GeckoSession(GeckoSessionSettings.Builder()
            // Keep the existing default Gecko profile across app launches. Session close/pause
            // must not clear site data; history preference controls only our URL history.
            .usePrivateMode(false)
            .userAgentMode(GeckoSessionSettings.USER_AGENT_MODE_DESKTOP)
            .viewportMode(GeckoSessionSettings.VIEWPORT_MODE_DESKTOP)
            .suspendMediaWhenInactive(true).build())
    private fun createTab(windowId: Int, opener: Int = 0): Tab =
        Tab(++nextTabId, newSession(), windowId, opener).also(::bindSession)
    private fun ownsSession(tab: Tab, session: GeckoSession) = tab.awake && tab.session === session
    private fun bindSession(tab: Tab) {
        val session = tab.session
        // Keep Gecko's default TextInputDelegate: it forwards composition, selection,
        // cursor and keyboard lifecycle to Android's InputMethodManager. A partial custom
        // delegate would suppress those notifications and break CJK input.
        installKeyboardDelegate(tab)
        session.mediaSessionDelegate = object : MediaSession.Delegate {
            override fun onActivated(session: GeckoSession, mediaSession: MediaSession) {
                if (!ownsSession(tab, session)) return
                tab.playback = mediaSession
                if (!displayed(tab)) mediaSession.pause()
                else restoreMedia(tab)

            }
            override fun onDeactivated(session: GeckoSession, mediaSession: MediaSession) {
                if (!ownsSession(tab, session)) return
                tab.playback = null; tab.playing = false; publish()
            }
            override fun onPlay(session: GeckoSession, mediaSession: MediaSession) {
                if (!ownsSession(tab, session)) return
                tab.playing = true
                if (!displayed(tab) || tab.pauseToken > 0) mediaSession.pause()
                publish()

            }
            override fun onPause(session: GeckoSession, mediaSession: MediaSession) {
                if (!ownsSession(tab, session)) return
                tab.playing = false; publish()
            }
            override fun onStop(session: GeckoSession, mediaSession: MediaSession) {
                if (!ownsSession(tab, session)) return
                tab.playing = false; publish()
            }
        }
        session.navigationDelegate = object : GeckoSession.NavigationDelegate {
            override fun onLocationChange(session: GeckoSession, url: String?,
                perms: MutableList<GeckoSession.PermissionDelegate.ContentPermission>, hasUserGesture: Boolean) {
                if (!ownsSession(tab, session)) return
                if (tab.url != url) {
                    tab.pauseToken = 0; tab.pauseReports.clear()
                    tab.sources.clear()
                    // SPA navigation has no onPageStart. Do not leave the previous video's
                    // handoff button enabled until the new document reports matching tracks.
                    for (media in tab.media.values) for (i in 0 until media.length()) {
                        media.optJSONObject(i)?.put("bilibili_ready", false)
                        media.optJSONObject(i)?.put("douyin_ready", false)
                        media.optJSONObject(i)?.put("weibo_ready", false)
                    }
                    // Single-page sites change location without onPageStart. Leaving the page
                    // that held a focused field ends its unsent-input protection; otherwise one
                    // search-box tap pins the tab forever and blocks every later popup.
                    if (!tab.editing) tab.protectedInput = false

            }
                if (url != null) tab.url = url
                if (tab.url != "about:blank") tab.startPage = false
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
            override fun onCanGoBack(session: GeckoSession, canGoBack: Boolean) {
                if (!ownsSession(tab, session)) return
                tab.back = canGoBack; publish()
            }
            override fun onCanGoForward(session: GeckoSession, canGoForward: Boolean) {
                if (!ownsSession(tab, session)) return
                tab.forward = canGoForward; publish()
            }
            override fun onLoadRequest(session: GeckoSession, request: GeckoSession.NavigationDelegate.LoadRequest): GeckoResult<AllowOrDeny> {
                if (!ownsSession(tab, session)) return GeckoResult.fromValue(AllowOrDeny.DENY)

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
                            beginNavigation(tab, request.uri)
                            session.load(GeckoSession.Loader().uri(request.uri).referrer(session))
                            publish()

            }
                    }
                    return GeckoResult.fromValue(AllowOrDeny.DENY)

            }
                // A same-document/hash request may never have onPageStop. Loading follows
                // real progress callbacks; leaving the start page is immediate and sticky.
                               if (!newWindow && request.uri != "about:blank") { tab.startPage = false; publish()
            }
                return GeckoResult.fromValue(AllowOrDeny.ALLOW)

            }
            override fun onNewSession(session: GeckoSession, uri: String): GeckoResult<GeckoSession>? {
                if (!ownsSession(tab, session)) return null

                if (current() !== tab || !WebBrowserAddress.navigable(uri) || !roomForTab(tab, true)) return null
                hideInput(); suspendTab(tab); releaseDisplay(window(tab.window))
                val child = createTab(tab.window, tab.id)
                beginNavigation(child, uri)
                tabs.add(child); window(tab.window).tab = child.id; layoutRevision++
                bindExtension(child)
                bindDisplay(child) // Gecko opens the returned session.
                publish()
                return GeckoResult.fromValue(child.session)

            }

            override fun onLoadError(session: GeckoSession, uri: String?, error: WebRequestError): GeckoResult<String>? {
                if (!ownsSession(tab, session)) return null

                tab.error = "page_load_failed"; tab.loading = false; publish(); return null // Never bypass certificate failures.

            }
        }
        session.progressDelegate = object : GeckoSession.ProgressDelegate {
            override fun onSessionStateChange(session: GeckoSession, state: GeckoSession.SessionState) {
                if (!ownsSession(tab, session)) return
                if (tab.awake) tab.savedState = state

            }
            override fun onPageStart(session: GeckoSession, url: String) {
                if (!ownsSession(tab, session)) return
                // Gecko can report a website's app-launch start before our load
                // policy rejects it. The live web document has not been replaced.
                if (!WebBrowserAddress.navigable(url)) return
                if (input?.tab === tab) hideInput()
                tab.keyboardManual = false
                if (!tab.awake) return
                beginNavigation(tab, url)
                tab.url = url
                tab.protectedInput = false
                tab.fullscreen.reset(); tab.fullscreenPort = null
                               if (tab.restoreOrigin != url) { tab.restorePosition = null; tab.restoreOrigin = ""
            }
                if (tab.parkedReturn?.optString("origin") != url) tab.parkedReturn = null
                tab.capturedFullscreenRequest = 0L
                invalidatePlaybackHold(tab)
                tab.navigation++; tab.pauseToken = 0; tab.pauseReports.clear()
                tab.weiboRequest = 0; tab.weiboSelection = ""; tab.weiboClicks.clear()
                tab.betaRequest = 0; tab.betaSelection = ""; tab.bilibiliClicks.clear()
                tab.tencentClicks.clear();tab.mangoClicks.clear();tab.youkuClicks.clear();tab.niconicoClicks.clear();tab.twitchClicks.clear();tab.tiktokClicks.clear();tab.instagramClicks.clear();tab.instagramReturns.clear();tab.tedClicks.clear();tab.redbullClicks.clear();tab.naverClicks.clear();tab.naverReturns.clear();tab.redditClicks.clear();tab.streamableClicks.clear();tab.archiveClicks.clear();tab.odyseeClicks.clear();tab.dailymotionClicks.clear();tab.iqiyiClicks.clear();tab.douyinClicks.clear()
                tab.media.clear(); tab.sources.clear(); tab.fullScreen = false; tab.editor = null; tab.editing = false; tab.keyboardVisible = false
                tab.error = ""; tab.progress = 0; publish()

            }
            override fun onPageStop(session: GeckoSession, success: Boolean) {
                if (!ownsSession(tab, session)) return
                if (!tab.awake) return
                tab.loading = false
                tab.progress = 100
                if (!success) tab.error = "page_load_failed"
                               if (success) { store()?.visit(tab.url, tab.title, System.currentTimeMillis()); publishLibrary()
            }
                publish()

            }
            override fun onProgressChange(session: GeckoSession, progress: Int) {
                if (!ownsSession(tab, session)) return
                tab.progress = progress.coerceIn(0, 100); publish()
            }
        }
        session.contentDelegate = object : GeckoSession.ContentDelegate {
            override fun onTitleChange(session: GeckoSession, title: String?) {
                if (!ownsSession(tab, session)) return
                tab.title = title.orEmpty().take(512); publish()
            }
            override fun onCloseRequest(session: GeckoSession) {
                if (!ownsSession(tab, session)) return
                if (tab.opener != 0) closeTab(tab)
            }
            override fun onFullScreen(session: GeckoSession, fullScreen: Boolean) {
                if (!ownsSession(tab, session)) return
                tab.fullScreen = fullScreen; updateFullscreen(tab); publish()

            }
            override fun onCrash(session: GeckoSession) {
                if (!ownsSession(tab, session)) return
                stoppedTab(tab, "browser_crashed")
            }
            override fun onKill(session: GeckoSession) {
                if (!ownsSession(tab, session)) return
                stoppedTab(tab, "browser_stopped")
            }
        }
        session.permissionDelegate = object : GeckoSession.PermissionDelegate {
            override fun onContentPermissionRequest(session: GeckoSession,
                perm: GeckoSession.PermissionDelegate.ContentPermission): GeckoResult<Int>? {
                if (!ownsSession(tab, session)) return GeckoResult.fromValue(GeckoSession.PermissionDelegate.ContentPermission.VALUE_DENY)

                if (perm.permission != GeckoSession.PermissionDelegate.PERMISSION_MEDIA_KEY_SYSTEM_ACCESS) return null
                val allowed = active && current() === tab && WebBrowserMediaPolicy.permitsKeys(tab.url, perm.uri, perm.thirdPartyOrigin)
                return GeckoResult.fromValue(if (allowed) GeckoSession.PermissionDelegate.ContentPermission.VALUE_ALLOW
                    else GeckoSession.PermissionDelegate.ContentPermission.VALUE_DENY)

            }
        }
        // Camera/microphone and other permissions retain Gecko's default rejection behavior.

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
                        tab.lastMediaReport = SystemClock.uptimeMillis()
                        if (tab.pauseToken > 0 && data.optLong("pause_token") == tab.pauseToken && data.optBoolean("pause_held"))
                            tab.pauseReports[port] = tab.pauseToken to data.optBoolean("pause_has_media")
                        else tab.pauseReports.remove(port)
                        pendingRetention?.takeIf { it.owner.tab == tab.id && port in it.ports }?.let { pending ->
                            if (data.optBoolean("suspended") && data.optBoolean("pause_held") && data.optLong("pause_token") == pending.owner.token)
                                pending.suspended.add(port) else pending.suspended.remove(port)
                            if (pending.suspended.containsAll(pending.ports)) {
                                pendingRetention = null
                                pending.ticket.complete(tab.awake && WebBrowserPlaybackHold.Owner(tab.id, tab.navigation, tab.url, tab.pauseToken) == pending.owner &&
                                    tab.ports.filterValues { it == tab.navigation }.keys.containsAll(pending.ports))
                            }
                        }
                        val safe = JSONArray()
                        val privateSources = JSONArray()
                        for (index in 0 until minOf(16, items.length())) {
                            val item = items.optJSONObject(index) ?: continue
                            val id = item.optString("id").take(64)
                            val networkEnabled = networkEnabled(tab)
                            val bilibiliEnabled = bilibiliEnabled(tab)
                            val douyinEnabled = douyinEnabled(tab)
                            val weiboEnabled = WebBrowserWeibo.document(tab.url)
                            val tencentEnabled = WebBrowserTencent.enabled(tab.url)
                            val mangoEnabled = WebBrowserMango.enabled(tab.url)
                            val youkuEnabled = WebBrowserYouku.enabled(tab.url)
                            val iqiyiEnabled = WebBrowserIqiyi.enabled(tab.url)
                            val niconicoEnabled = WebBrowserNiconico.enabled(tab.url)
                            val twitchEnabled = WebBrowserTwitch.enabled(tab.url)
                            val tiktokEnabled = WebBrowserTikTok.observing(tab.url)
                            val instagramEnabled = WebBrowserInstagram.observing(tab.url)
                            val tedEnabled = WebBrowserTed.observing(tab.url)
                            val redbullEnabled = WebBrowserRedBull.observing(tab.url)
                            val streamableEnabled = WebBrowserStreamable.observing(tab.url)
                            val redditEnabled = WebBrowserReddit.observing(tab.url)
                            val naverEnabled = WebBrowserNaver.observing(tab.url)
                            val archiveEnabled = WebBrowserArchive.observing(tab.url)
                            val odyseeEnabled = WebBrowserOdysee.observing(tab.url)
                            val dailymotionEnabled = WebBrowserDailymotion.enabled(tab.url)
                            val network = if (networkEnabled || bilibiliEnabled || douyinEnabled || weiboEnabled || tencentEnabled || mangoEnabled || youkuEnabled || iqiyiEnabled || niconicoEnabled || twitchEnabled || tiktokEnabled || instagramEnabled || tedEnabled || redbullEnabled || naverEnabled || redditEnabled || streamableEnabled || archiveEnabled || odyseeEnabled || dailymotionEnabled) WebBrowserNetworkMedia.candidates(item,includeSegments=tencentEnabled || iqiyiEnabled || niconicoEnabled || tedEnabled || redbullEnabled || naverEnabled || redditEnabled || streamableEnabled || archiveEnabled || odyseeEnabled || dailymotionEnabled) else JSONArray()
                            val bilibili = item.optJSONObject("bilibili")?.takeIf { bilibiliEnabled &&
                                !item.optBoolean("protected") && it.toString().length <= 96 * 1024 && it.optString("page") == tab.url }
                            val serverHeaders = item.optJSONObject("server_headers")?.let { data ->
                                data.keys().asSequence().take(4).associateWith { data.optString(it) }
                            }.orEmpty()
                            val server = !item.optBoolean("protected") && WebBrowserServerMedia.recognizes(item.optString("source"), tab.url, serverHeaders)
                            val douyin = WebBrowserDouyin.metadata(item, tab.url, douyinEnabled)
                            val weibo = WebBrowserWeibo.metadata(item, tab.url)
                            val tencent = if(tencentEnabled) WebBrowserTencent.metadata(item,tab.url) else null
                            val mango = if(mangoEnabled) WebBrowserMango.metadata(item,tab.url) else null
                            val youku = if(youkuEnabled) WebBrowserYouku.metadata(item,tab.url) else null
                            val niconico=if(niconicoEnabled)WebBrowserNiconico.metadata(item,tab.url) else null
                            val twitch=if(twitchEnabled)WebBrowserTwitch.metadata(item,tab.url) else null
                            val tiktok=if(tiktokEnabled)WebBrowserTikTok.metadata(item,tab.url) else null
                            val instagram=if(instagramEnabled)WebBrowserInstagram.metadata(item,tab.url) else null
                            val ted=if(tedEnabled)WebBrowserTed.metadata(item,tab.url) else null
                            val redbull=if(redbullEnabled)WebBrowserRedBull.metadata(item,tab.url) else null
                            val streamable=if(streamableEnabled)WebBrowserStreamable.metadata(item,tab.url) else null
                            val reddit=if(redditEnabled)WebBrowserReddit.metadata(item,tab.url) else null
                            val naver=if(naverEnabled)WebBrowserNaver.metadata(item,tab.url) else null
                            val archive=if(archiveEnabled)WebBrowserArchive.metadata(item,tab.url) else null
                            val odysee=if(odyseeEnabled)WebBrowserOdysee.metadata(item,tab.url) else null
                            val dailymotion=if(dailymotionEnabled && item.optString("frame")==port.sender.url)WebBrowserDailymotion.metadata(item,tab.url) else null
                            val iqiyi = if(iqiyiEnabled) WebBrowserIqiyi.metadata(item,tab.url) else null
                            val biliIdentity = bilibili?.let { "${it.optString("id")}:${it.optString("cid")}:${it.optInt("part")}:${it.optString("ep")}" }.orEmpty()
                            val captureIdentity = "${tab.id}:${tab.navigation}:${System.identityHashCode(port)}:$id:${item.optLong("network_epoch")}:${tab.bilibiliProbe}:${tab.douyinCaptureEnabled}:${weibo?.optString("page").orEmpty()}:$biliIdentity" +
                                (tencent?.let { ":tencent:${it.optString("id")}:${it.optString("revision")}" } ?: "") +
                                (mango?.let { ":mango:${it.optString("id")}:${it.optString("revision")}" } ?: "") +
                                (youku?.let { ":youku:${it.optString("id")}:${it.optString("revision")}" } ?: "") +
                                (niconico?.let { ":niconico:${it.optString("id")}:${it.optString("revision")}" } ?: "") +
                                (twitch?.let { ":twitch:${it.optString("id")}:${it.optString("revision")}" } ?: "") +
                                (tiktok?.let { ":tiktok:${it.optString("id")}:${it.optString("revision")}" } ?: "") +
                                (instagram?.let { ":instagram:${it.optString("id")}:${it.optString("revision")}" } ?: "") +
                                (ted?.let { ":ted:${it.optString("id")}:${it.optString("revision")}" } ?: "") +
                                (redbull?.let { ":redbull:${it.optString("id")}:${it.optString("revision")}" } ?: "") +
                                (streamable?.let { ":streamable:${it.optString("id")}:${it.optString("revision")}" } ?: "") +
                                (reddit?.let { ":reddit:${it.optString("id")}:${it.optString("revision")}" } ?: "") +
                                (naver?.let { ":naver:${it.optString("id")}:${it.optString("revision")}" } ?: "") +
                                (archive?.let { ":archive:${it.optString("id")}:${it.optString("revision")}" } ?: "") +
                                (odysee?.let { ":odysee:${it.optString("id")}:${it.optString("revision")}" } ?: "") +
                                (dailymotion?.let { ":dailymotion:${it.optString("id")}:${it.optString("revision")}" } ?: "") +
                                (iqiyi?.let { ":iqiyi:${it.optString("id")}:${it.optString("revision")}" } ?: "") +
                                (douyin?.let { ":douyin:${it.optString("id")}:${it.optString("revision")}" } ?: "")
                            safe.put(JSONObject().put("width", item.optInt("width").coerceIn(0, 32768))
                                .put("id", id).put("fullscreen", item.optBoolean("fullscreen") || server && item.optBoolean("server_play"))
                                .put("server_play", server && item.optBoolean("server_play"))
                                .put("server_media", server)
                                .put("bilibili_ready", bilibili != null && item.optBoolean("bilibili_ready"))
                                .put("douyin_ready", douyin != null && item.optBoolean("douyin_ready")).put("douyin_page",douyin?.optString("page").orEmpty())
                                .put("weibo_ready", weibo != null && item.optBoolean("weibo_ready"))
                                .put("weibo_selected", weibo != null && item.optBoolean("weibo_selected"))
                                .put("weibo_page", weibo?.optString("page").orEmpty())
                                .put("tencent_ready",tencent != null && item.optBoolean("tencent_ready"))
                                .put("tencent_page",tencent?.optString("page").orEmpty())
                                .put("mango_ready",mango != null && item.optBoolean("mango_ready"))
                                .put("youku_ready",youku != null && item.optBoolean("youku_ready"))
                                .put("niconico_ready",niconico!=null && item.optBoolean("niconico_ready")).put("niconico_page",niconico?.optString("page").orEmpty())
                                .put("twitch_ready",twitch!=null && item.optBoolean("twitch_ready")).put("twitch_page",twitch?.optString("page").orEmpty())
                                .put("tiktok_ready",tiktok!=null && item.optBoolean("tiktok_ready")).put("tiktok_page",tiktok?.optString("page").orEmpty())
                                .put("instagram_ready",instagram!=null && item.optBoolean("instagram_ready")).put("instagram_page",instagram?.optString("page").orEmpty())
                                .put("ted_ready",ted!=null && item.optBoolean("ted_ready")).put("ted_page",ted?.optString("page").orEmpty())
                                .put("redbull_ready",redbull!=null && item.optBoolean("redbull_ready")).put("redbull_page",redbull?.optString("page").orEmpty())
                                .put("streamable_ready",streamable!=null && item.optBoolean("streamable_ready")).put("streamable_page",streamable?.optString("page").orEmpty())
                                .put("reddit_ready",reddit!=null && item.optBoolean("reddit_ready")).put("reddit_page",reddit?.optString("page").orEmpty())
                                .put("naver_ready",naver!=null && item.optBoolean("naver_ready")).put("naver_page",naver?.optString("page").orEmpty())
                                .put("archive_ready",archive!=null && item.optBoolean("archive_ready")).put("archive_page",archive?.optString("page").orEmpty())
                                .put("odysee_ready",odysee!=null && item.optBoolean("odysee_ready")).put("odysee_page",odysee?.optString("page").orEmpty())
                                .put("dailymotion_ready",dailymotion!=null && item.optBoolean("dailymotion_ready")).put("dailymotion_page",dailymotion?.optString("page").orEmpty())
                                .put("iqiyi_ready",iqiyi != null && item.optBoolean("iqiyi_ready")).put("iqiyi_page",iqiyi?.optString("page").orEmpty())
                                .put("iqiyi_diagnostics",if(iqiyiEnabled)WebBrowserCaptureDiagnostics.project("iqiyi",item).put("native_binding_valid",iqiyi!=null) else null)
                                .put("tiktok_diagnostics",if(tiktokEnabled)WebBrowserCaptureDiagnostics.project("tiktok",item).put("native_binding_valid",tiktok!=null) else null)
                                .put("youku_page",youku?.let { "https://v.youku.com/v_show/id_${it.optString("id")}.html" }.orEmpty())
                                .put("mango_capture", if (mangoEnabled) WebBrowserMango.captureDiagnostics(data)
                                    .put("frame_matches", item.optString("frame") == tab.url).put("binding_valid", mango != null) else null)
                                .put("mango_page",mango?.let { "https://www.mgtv.com/b/${it.optString("id")}.html" }.orEmpty())
                                .put("selection", if (weibo != null || bilibili != null || tencent != null || mango != null || youku != null || iqiyi != null || douyin != null || niconico != null || twitch != null || tiktok != null || instagram != null || ted != null || redbull != null || naver != null || reddit != null || streamable != null || archive != null || odysee != null || dailymotion != null) captureIdentity else "")
                                .put("network_media", networkEnabled && (network.length() > 0 || !item.optBoolean("protected") && WebBrowserNetworkMedia.address(item.optString("source")) != null))
                                .put("media_epoch", "${System.identityHashCode(port)}:$id:${item.optLong("network_epoch")}")
                                .put("protected", item.optBoolean("protected"))
                                .put("height", item.optInt("height").coerceIn(0, 32768))
                                .put("playing", item.optBoolean("playing"))
                                .put("time", item.optDouble("time", 0.0).takeIf { it.isFinite() && it >= 0 } ?: 0.0)
                                .put("beta_time",instagram?.optDouble("start_seconds",item.optDouble("time",0.0)) ?: tiktok?.optDouble("start_seconds",item.optDouble("time",0.0)) ?: (item.optDouble("time",0.0).takeIf{it.isFinite()&&it>=0} ?: 0.0)))
                            val source = item.optString("source")
                            if (item.optString("frame").length <= 8192 && item.optString("agent").length <= 2048 &&
                                (source.isEmpty() || (source.length <= 16384 && (source.startsWith("https://") || source.startsWith("http://"))) || item.optBoolean("protected"))) {
                                privateSources.put(JSONObject(item.toString()).put("source", source.take(16384)).put("server", server)
                                    .put("network", network)
                                    .put("network_enabled", networkEnabled)
                                    .put("bilibili_enabled", bilibiliEnabled).put("bilibili", bilibili)
                                    .put("douyin_enabled", douyinEnabled).put("douyin", douyin).put("douyin_source",if(douyin!=null)item.optString("douyin_source") else "")
                                    .put("weibo_enabled", weiboEnabled).put("weibo", weibo)
                                    .put("tencent_enabled",tencentEnabled).put("tencent",tencent)
                                    .put("mango_enabled",mangoEnabled).put("mango",mango)
                                    .put("youku_enabled",youkuEnabled).put("youku",youku)
                                    .put("niconico_enabled",niconicoEnabled).put("niconico",niconico).put("niconico_source",if(niconico!=null)item.optString("niconico_source") else "")
                                    .put("twitch_enabled",twitchEnabled).put("twitch",twitch)
                                    .put("tiktok_enabled",tiktokEnabled).put("tiktok",tiktok).put("tiktok_source",if(tiktok!=null)item.optString("tiktok_source") else "")
                                    .put("instagram_enabled",instagramEnabled).put("instagram",instagram).put("instagram_source",if(instagram!=null)item.optString("instagram_source") else "")
                                    .put("ted_enabled",tedEnabled).put("ted",ted).put("ted_source",if(ted!=null)item.optString("ted_source") else "")
                                    .put("redbull_enabled",redbullEnabled).put("redbull",redbull).put("redbull_source",if(redbull!=null)item.optString("redbull_source") else "")
                                    .put("streamable_enabled",streamableEnabled).put("streamable",streamable).put("streamable_source",if(streamable!=null)item.optString("streamable_source") else "")
                                    .put("reddit_enabled",redditEnabled).put("reddit",reddit).put("reddit_source",if(reddit!=null)item.optString("reddit_source") else "")
                                    .put("naver_enabled",naverEnabled).put("naver",naver).put("naver_source",if(naver!=null)item.optString("naver_source") else "")
                                    .put("archive_enabled",archiveEnabled).put("archive",archive).put("archive_source",if(archive!=null)item.optString("archive_source") else "")
                                    .put("odysee_enabled",odyseeEnabled).put("odysee",odysee).put("odysee_source",if(odysee!=null)item.optString("odysee_source") else "")
                                    .put("dailymotion_enabled",dailymotionEnabled).put("dailymotion",dailymotion).put("dailymotion_source",if(dailymotion!=null)item.optString("dailymotion_source") else "").put("dailymotion_owner",if(dailymotion!=null)tab.url else "")
                                    .put("iqiyi_enabled",iqiyiEnabled).put("iqiyi",iqiyi).put("iqiyi_source",if(iqiyi!=null)item.optString("iqiyi_source") else "")
                                    .put("douyin_boundary", if (mediaDiagnosticsEnabled()) WebBrowserDouyin.metadataDiagnostics(item,tab.url,douyinEnabled,douyin != null) else null)
                                    .put("bilibili_probe", tab.bilibiliProbe)
                                    .put("diagnostic_max_height", if (tab.bilibiliProbe == "uncapped" && bilibiliEligible(tab)) 2160 else 1080)
                                    .put("capture_identity", captureIdentity)
                                    .put("fullscreen", item.optBoolean("fullscreen") || server && item.optBoolean("server_play")))
                                val click = item.optLong("weibo_request")
                                if (weibo != null && item.optBoolean("weibo_selected") && click > (tab.weiboClicks[port] ?: 0) &&
                                    click in 1..Int.MAX_VALUE.toLong() && active && current() === tab && tab.pauseToken == 0L) {
                                    tab.weiboClicks[port] = click
                                    tab.weiboRequest = ++nextBetaRequest; tab.weiboSelection = captureIdentity
                                    tab.betaRequest = tab.weiboRequest; tab.betaSelection = captureIdentity
                                }
                                val biliClick = item.optLong("bilibili_request")
                                if (bilibili != null && item.optBoolean("bilibili_ready") && biliClick > (tab.bilibiliClicks[port] ?: 0) &&
                                    biliClick in 1..Int.MAX_VALUE.toLong() && active && current() === tab && tab.pauseToken == 0L) {
                                    tab.bilibiliClicks[port] = biliClick
                                    tab.betaRequest = ++nextBetaRequest; tab.betaSelection = captureIdentity
                                }
                                val tencentClick = item.optLong("tencent_request")
                                if (tencent != null && item.optBoolean("tencent_ready") && tencentClick > (tab.tencentClicks[port] ?: 0) &&
                                    tencentClick in 1..Int.MAX_VALUE.toLong() && active && current() === tab && tab.pauseToken == 0L) {
                                    tab.tencentClicks[port] = tencentClick
                                    tab.betaRequest = ++nextBetaRequest; tab.betaSelection = captureIdentity
                                }
                                val mangoClick = item.optLong("mango_request")
                                if (mango != null && item.optBoolean("mango_ready") && mangoClick > (tab.mangoClicks[port] ?: 0) &&
                                    mangoClick in 1..Int.MAX_VALUE.toLong() && active && current() === tab && tab.pauseToken == 0L) {
                                    tab.mangoClicks[port] = mangoClick
                                    tab.betaRequest = ++nextBetaRequest; tab.betaSelection = captureIdentity
                                }
                                val youkuClick = item.optLong("youku_request")
                                if (youku != null && item.optBoolean("youku_ready") && youkuClick > (tab.youkuClicks[port] ?: 0) &&
                                    youkuClick in 1..Int.MAX_VALUE.toLong() && active && current() === tab && tab.pauseToken == 0L) {
                                    tab.youkuClicks[port] = youkuClick
                                    tab.betaRequest = ++nextBetaRequest; tab.betaSelection = captureIdentity
                                }
                                val niconicoClick = item.optLong("niconico_request")
                                val twitchClick = item.optLong("twitch_request")
                                if (twitch != null && item.optBoolean("twitch_ready") && twitchClick > (tab.twitchClicks[port] ?: 0) &&
                                    twitchClick in 1..Int.MAX_VALUE.toLong() && active && current() === tab && tab.pauseToken == 0L) {
                                    tab.twitchClicks[port] = twitchClick
                                    tab.betaRequest = ++nextBetaRequest; tab.betaSelection = captureIdentity
                                }
                                val tiktokClick = item.optLong("tiktok_request")
                                if (tiktok != null && item.optBoolean("tiktok_ready") && tiktokClick > (tab.tiktokClicks[port] ?: 0) &&
                                    tiktokClick in 1..Int.MAX_VALUE.toLong() && active && current() === tab && tab.pauseToken == 0L) {
                                    tab.tiktokClicks[port] = tiktokClick
                                    tab.betaRequest = ++nextBetaRequest; tab.betaSelection = captureIdentity
                                }
                                val instagramClick = item.optLong("instagram_request")
                                if (instagram != null && item.optBoolean("instagram_ready") && instagramClick > (tab.instagramClicks[port] ?: 0) &&
                                    instagramClick in 1..Int.MAX_VALUE.toLong() && active && current() === tab && tab.pauseToken == 0L) {
                                    tab.instagramClicks[port] = instagramClick
                                    tab.instagramReturns.clear()
                                    tab.instagramReturns[captureIdentity] = port to WebBrowserInstagram.identity(instagram)
                                    tab.betaRequest = ++nextBetaRequest; tab.betaSelection = captureIdentity
                                }
                                val tedClick = item.optLong("ted_request")
                                if (ted != null && item.optBoolean("ted_ready") && tedClick > (tab.tedClicks[port] ?: 0) &&
                                    tedClick in 1..Int.MAX_VALUE.toLong() && active && current() === tab && tab.pauseToken == 0L) {
                                    tab.tedClicks[port] = tedClick
                                    tab.betaRequest = ++nextBetaRequest; tab.betaSelection = captureIdentity
                                }
                                val redbullClick = item.optLong("redbull_request")
                                if (redbull != null && item.optBoolean("redbull_ready") && redbullClick > (tab.redbullClicks[port] ?: 0) &&
                                    redbullClick in 1..Int.MAX_VALUE.toLong() && active && current() === tab && tab.pauseToken == 0L) {
                                    tab.redbullClicks[port] = redbullClick
                                    tab.betaRequest = ++nextBetaRequest; tab.betaSelection = captureIdentity
                                }
                                val streamableClick = item.optLong("streamable_request")
                                if (streamable != null && item.optBoolean("streamable_ready") && streamableClick > (tab.streamableClicks[port] ?: 0) &&
                                    streamableClick in 1..Int.MAX_VALUE.toLong() && active && current() === tab && tab.pauseToken == 0L) {
                                    tab.streamableClicks[port] = streamableClick
                                    tab.betaRequest = ++nextBetaRequest; tab.betaSelection = captureIdentity
                                }
                                val redditClick = item.optLong("reddit_request")
                                if (reddit != null && item.optBoolean("reddit_ready") && redditClick > (tab.redditClicks[port] ?: 0) &&
                                    redditClick in 1..Int.MAX_VALUE.toLong() && active && current() === tab && tab.pauseToken == 0L) {
                                    tab.redditClicks[port] = redditClick
                                    tab.betaRequest = ++nextBetaRequest; tab.betaSelection = captureIdentity
                                }
                                val naverClick = item.optLong("naver_request")
                                if (naver != null && item.optBoolean("naver_ready") && naverClick > (tab.naverClicks[port] ?: 0) &&
                                    naverClick in 1..Int.MAX_VALUE.toLong() && active && current() === tab && tab.pauseToken == 0L) {
                                    tab.naverClicks[port] = naverClick
                                    tab.naverReturns.clear();tab.naverReturns[captureIdentity]=port to JSONObject().put("id",id).put("epoch",item.optLong("network_epoch")).put("page",naver.getString("page")).put("revision",naver.getString("revision"))
                                    tab.betaRequest = ++nextBetaRequest; tab.betaSelection = captureIdentity
                                }
                                val archiveClick = item.optLong("archive_request")
                                if (archive != null && item.optBoolean("archive_ready") && archiveClick > (tab.archiveClicks[port] ?: 0) &&
                                    archiveClick in 1..Int.MAX_VALUE.toLong() && active && current() === tab && tab.pauseToken == 0L) {
                                    tab.archiveClicks[port] = archiveClick
                                    tab.betaRequest = ++nextBetaRequest; tab.betaSelection = captureIdentity
                                }
                                val odyseeClick = item.optLong("odysee_request")
                                if (odysee != null && item.optBoolean("odysee_ready") && odyseeClick > (tab.odyseeClicks[port] ?: 0) &&
                                    odyseeClick in 1..Int.MAX_VALUE.toLong() && active && current() === tab && tab.pauseToken == 0L) {
                                    tab.odyseeClicks[port] = odyseeClick
                                    tab.betaRequest = ++nextBetaRequest; tab.betaSelection = captureIdentity
                                }
                                val dailymotionClick = item.optLong("dailymotion_request")
                                if (dailymotion != null && item.optBoolean("dailymotion_ready") && dailymotionClick > (tab.dailymotionClicks[port] ?: 0) &&
                                    dailymotionClick in 1..Int.MAX_VALUE.toLong() && active && current() === tab && tab.pauseToken == 0L) {
                                    tab.dailymotionClicks[port] = dailymotionClick
                                    tab.betaRequest = ++nextBetaRequest; tab.betaSelection = captureIdentity
                                }
                                if (niconico != null && item.optBoolean("niconico_ready") && niconicoClick > (tab.niconicoClicks[port] ?: 0) &&
                                    niconicoClick in 1..Int.MAX_VALUE.toLong() && active && current() === tab && tab.pauseToken == 0L) {
                                    tab.niconicoClicks[port] = niconicoClick
                                    tab.betaRequest = ++nextBetaRequest; tab.betaSelection = captureIdentity
                                }
                                val iqiyiClick = item.optLong("iqiyi_request")
                                val douyinClick = item.optLong("douyin_request")
                                if (douyin != null && item.optBoolean("douyin_ready") && douyinClick > (tab.douyinClicks[port] ?: 0) &&
                                    douyinClick in 1..Int.MAX_VALUE.toLong() && active && current() === tab && tab.pauseToken == 0L) {
                                    tab.douyinClicks[port] = douyinClick
                                    tab.betaRequest = ++nextBetaRequest; tab.betaSelection = captureIdentity
                                }
                                if (iqiyi != null && item.optBoolean("iqiyi_ready") && iqiyiClick > (tab.iqiyiClicks[port] ?: 0) &&
                                    iqiyiClick in 1..Int.MAX_VALUE.toLong() && active && current() === tab && tab.pauseToken == 0L) {
                                    tab.iqiyiClicks[port] = iqiyiClick
                                    tab.betaRequest = ++nextBetaRequest; tab.betaSelection = captureIdentity
                                }
                            }
                        }
                        tab.media[port] = safe
                        updateFullscreen(tab)
                        tab.sources[port] = privateSources
                        publish()
                    }
                    override fun onDisconnect(port: WebExtension.Port) {
                        tab.ports.remove(port); tab.media.remove(port); tab.sources.remove(port); tab.pauseReports.remove(port); tab.weiboClicks.remove(port)
                        tab.bilibiliClicks.remove(port)
                        tab.tencentClicks.remove(port);tab.mangoClicks.remove(port);tab.youkuClicks.remove(port);tab.niconicoClicks.remove(port);tab.twitchClicks.remove(port);tab.tiktokClicks.remove(port);tab.instagramClicks.remove(port);tab.instagramReturns.entries.removeAll{it.value.first===port};tab.tedClicks.remove(port);tab.redbullClicks.remove(port);tab.naverClicks.remove(port);tab.naverReturns.entries.removeAll{it.value.first===port};tab.redditClicks.remove(port);tab.streamableClicks.remove(port);tab.archiveClicks.remove(port);tab.odyseeClicks.remove(port);tab.dailymotionClicks.remove(port);tab.iqiyiClicks.remove(port);tab.douyinClicks.remove(port)
                        updateFullscreen(tab); publish()
                    }
                })
                port.postMessage(JSONObject().put("action", if (displayed(tab)) "resume" else "suspend"))
                port.postMessage(JSONObject().put("action", "network_policy").put("enabled", networkEnabled(tab))
                    .put("tencent",WebBrowserTencent.enabled(tab.url)).put("mango",WebBrowserMango.enabled(tab.url)).put("youku",WebBrowserYouku.enabled(tab.url)).put("iqiyi",WebBrowserIqiyi.enabled(tab.url)).put("niconico",WebBrowserNiconico.observing(tab.url)).put("twitch",WebBrowserTwitch.enabled(tab.url)).put("tiktok",WebBrowserTikTok.observing(tab.url)).put("instagram",WebBrowserInstagram.observing(tab.url)).put("ted",WebBrowserTed.observing(tab.url)).put("redbull",WebBrowserRedBull.observing(tab.url)).put("naver",WebBrowserNaver.observing(tab.url)).put("reddit",WebBrowserReddit.observing(tab.url)).put("streamable",WebBrowserStreamable.observing(tab.url)).put("archive",WebBrowserArchive.observing(tab.url)).put("odysee",WebBrowserOdysee.observing(tab.url)).put("dailymotion",WebBrowserDailymotion.observing(tab.url)).put("dailymotion_owner",tab.url.takeIf{WebBrowserDailymotion.observing(it)}.orEmpty())
                    .put("bilibili", bilibiliEnabled(tab)).put("douyin", douyinEnabled(tab)).put("weibo", WebBrowserWeibo.document(tab.url)).put("diagnostics", mediaDiagnosticsEnabled()))
                if (tab.pauseToken > 0) port.postMessage(JSONObject().put("action", "pause_media").put("token", tab.pauseToken))
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

    private fun beginNavigation(tab: Tab, url: String) {
        if (url != "about:blank") tab.startPage = false
        tab.loading = url != "about:blank"
        tab.progress = 0
        tab.error = ""
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
        beginNavigation(tab, url)
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
        tab.editor?.finishComposingText(); tab.editor = null; tab.editing = false; tab.keyboardManual = false; tab.keyboardVisible = false
        tab.ports.keys.forEach { runCatching { it.postMessage(JSONObject().put("action", "suspend")
            .put("keep_pause", playbackHold.protects(tab.id, tab.navigation)).put("pause_token", tab.pauseToken)) } }
        tab.playback?.pause()
        tab.session.setFocused(false)
        tab.session.setActive(false)
    }

    private val mediaRelease = WebBrowserMediaRelease()
    /** Only the source worker waits. Never wait on Android UI from the frame thread. */
    fun awaitMediaRelease(): Boolean = mediaRelease.await(5000)

    private fun holdOwner(request: JSONObject) = WebBrowserPlaybackHold.Owner(request.optInt("tab"),
        request.optLong("navigation", -1), request.optString("origin"), request.optLong("pause_token"))
    private fun pauseConfirmed(tab: Tab): Boolean = tab.pauseToken > 0 &&
        tab.ports.filterValues { it == tab.navigation }.keys.let { ports ->
            ports.isNotEmpty() && ports.all { tab.pauseReports[it]?.first == tab.pauseToken } &&
                (ports.any { tab.pauseReports[it]?.second == true } || !tab.playing)
        }
    /** Keep docshell/DOM/ports. The ticket confirms the pause acknowledgement and
     * UI inactivity, not synchronous reclamation of Android hardware decoders. */
    private fun retainPage(request: JSONObject, ticket: WebBrowserMediaRelease.Ticket) {
        var suspended = false
        var awaitingReport = false
        try {
            val tab = tabs.firstOrNull { it.id == request.optInt("tab") && it.window == request.optInt("window") }
                ?: return
            if (!tab.awake || window(tab.window).tab != tab.id || memoryTight()) return
            val current = WebBrowserPlaybackHold.Owner(tab.id, tab.navigation, tab.url, tab.pauseToken)
            if (!playbackHold.retain(holdOwner(request), current, pauseConfirmed(tab))) return
            if (request.optBoolean("hide")) {
                pendingRetention?.ticket?.complete(false)
                val pending = PendingRetention(current, tab.ports.filterValues { it == tab.navigation }.keys.toSet(), ticket)
                pendingRetention = pending; awaitingReport = true
                ui.postDelayed({
                    if (pendingRetention === pending) { pendingRetention = null; pending.ticket.complete(false) }
                }, 4500)
                active = false; hideInput(); tabs.forEach(::suspendTab); windows.forEach(::releaseDisplay)
            }
            // Peer-window transfers retain the source lease without hiding peers.
            publish(); suspended = true
        } finally { if (!awaitingReport) ticket.complete(suspended) }
    }

    private fun resumeRetainedPage(request: JSONObject) {
        val tab = tabs.firstOrNull { it.id == request.optInt("tab") && it.window == request.optInt("window") }
        if (tab == null || !tab.awake || tab.navigation != request.optLong("navigation", -1) || tab.url != request.optString("origin")) {
            // A killed/navigated document cannot be reconstructed as a successful return.
            // Show surviving live windows; only an explicit user action may reload.
            active = true
            windows.forEach { slot -> tabs.firstOrNull { it.id == slot.tab && it.awake }?.let(::bindDisplay) }
            operationError = "browser_page_changed"; publish(); return
        }
        selectTab(tab)
    }

    fun action(command: String) {
        if (command == "hibernate") {
            val ticket = mediaRelease.begin()
            dispatch {
                var released = false
                try {
                    active = false; hideInput(); windows.forEach(::releaseDisplay)
                    tabs.forEach { parkTab(it, keepReturn = true) }
                    publish(); released = true
                } finally { ticket.complete(released) }
            }
        } else actionWithoutRelease(command)
    }
    private fun actionWithoutRelease(command: String) = dispatch {
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
            "stop" -> { tab.session.stop(); tab.loading = false }
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
        invalidatePlaybackHold(tab)
        tab.loading = false
        tab.navigation++
        tab.ports.keys.toList().forEach { runCatching { it.disconnect() } }
        tab.ports.clear(); tab.media.clear(); tab.sources.clear(); tab.pauseToken = 0; tab.pauseReports.clear()
        tab.fullscreen.reset(); tab.fullscreenPort = null; tab.capturedFullscreenRequest = 0
        tab.fullScreen = false; tab.playback = null; tab.playing = false
        tab.restorePosition = null; tab.restoreThroughScript = false; tab.restoreOrigin = ""
        tab.editor = null; tab.editing = false; tab.protectedInput = false; tab.keyboardManual = false
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
        val candidate = tabs.filter { it.awake && !playbackHold.protects(it.id, it.navigation) && !it.protectedInput && !linked(it) &&
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
        if (!tab.awake || playbackHold.protects(tab.id, tab.navigation)) return
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
        // Retired sessions can still have JNI/EventDispatcher work queued in Gecko.
        // Reopening that same Java/native bridge lets old work race the replacement.
        // Keep the tab/state/profile, but give every wake its own session and delegates.
        tab.session = newSession(); tab.awake = true; bindSession(tab)
        tab.session.open(runtime!!); tab.error = ""; operationError = ""; bindExtension(tab)
        if (restore) {
            val pending = tab.pendingUrl
            if (pending != null) {
                if (extensionState != "pending") { tab.pendingUrl = null; tab.session.loadUri(pending) }
            } else {
                val saved = tab.savedState
                // setActive(false) flushes asynchronously; closing immediately can retain the
                // snapshot before a same-document video switch. Never restore that old page.
                if (WebBrowserSessionState.matches(saved, tab.url)) tab.session.restoreState(saved!!)
                else tab.session.loadUri(tab.url)
            }
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
        val reclaimable = tabs.filter { it.id in retained && it.awake && !playbackHold.protects(it.id, it.navigation) && it.id !in visible && !it.protectedInput && !linked(it) &&
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
                invalidatePlaybackHold(tab)
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
    fun command(value: String) {
        if (closed.get() || value.length > 8192) return
        val request = runCatching { JSONObject(value) }.getOrNull() ?: return
        if (request.optString("action") == "retain_page") {
            // Begin before posting UI work so the source worker cannot pass an old ticket.
            val ticket = mediaRelease.begin()
            dispatch { retainPage(request, ticket) }
        } else commandOnUi(request)
    }
    private fun commandOnUi(request: JSONObject) = dispatch {
        if (request.optString("action") == "keyboard_mode") {
            val enabled = request.optBoolean("enabled")
            if (customKeyboard != enabled) {
                hideInput()
                customKeyboard = enabled
                tabs.filter { it.awake }.forEach(::installKeyboardDelegate)
                current()?.let { tab ->
                    if (active) {
                        attachInput(tab)
                        if (enabled) captureKeyboardEditor(tab)
                        else input?.let { view ->
                            (view.context.getSystemService(android.content.Context.INPUT_METHOD_SERVICE) as android.view.inputmethod.InputMethodManager).restartInput(view)
                        }
                    }
                }
                publish()
            }
            return@dispatch
        }
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
            "resume_retained_page" -> resumeRetainedPage(request)
            "release_retained_page" -> {
                if (playbackHold.release(holdOwner(request))) {
                    tabs.firstOrNull { it.id == request.optInt("tab") && it.navigation == request.optLong("navigation", -1) &&
                        it.url == request.optString("origin") && it.pauseToken == request.optLong("pause_token") }?.let { tab ->
                        tab.ports.keys.forEach { runCatching { it.postMessage(JSONObject().put("action", "release_pause_media")
                            .put("token", tab.pauseToken).put("play", false)) } }
                        tab.pauseToken = 0; tab.pauseReports.clear(); tab.pauseWasPlaying = false; tab.pauseHasDom = false
                    }
                }
            }
            "restore_weibo", "restore_mango", "restore_youku", "restore_iqiyi", "restore_douyin", "restore_niconico", "restore_twitch", "restore_tiktok", "restore_instagram", "restore_ted", "restore_redbull", "restore_naver", "restore_reddit", "restore_streamable", "restore_archive", "restore_odysee", "restore_dailymotion" -> {
                val tab = tabs.firstOrNull { it.id == request.optInt("tab") && it.window == id } ?: return@dispatch
                if (!tab.awake || window(id).tab != tab.id || tab.navigation != request.optLong("navigation", -1) ||
                    tab.url != request.optString("origin")) return@dispatch
                val selection = request.optString("selection")
                val kind=when(request.optString("action")) { "restore_mango" -> "mango"; "restore_youku" -> "youku"; "restore_niconico" -> "niconico"; "restore_twitch" -> "twitch"; "restore_tiktok" -> "tiktok"; "restore_instagram" -> "instagram"; "restore_ted" -> "ted"; "restore_redbull" -> "redbull"; "restore_naver" -> "naver"; "restore_reddit" -> "reddit"; "restore_streamable" -> "streamable"; "restore_archive" -> "archive"; "restore_odysee" -> "odysee"; "restore_dailymotion" -> "dailymotion"; "restore_iqiyi" -> "iqiyi"; "restore_douyin" -> "douyin"; else -> "weibo" }
                if(kind=="naver"){
                    val witness=tab.naverReturns.remove(selection) ?: return@dispatch
                    if(witness.first !in tab.ports)return@dispatch
                    witness.first.postMessage(JSONObject(witness.second.toString()).put("action","restore_naver")
                        .put("time",request.optLong("position_ms").coerceAtLeast(0)/1000.0).put("play",request.optBoolean("play")))
                    return@dispatch
                }
                if(kind=="instagram"){
                    val witness=tab.instagramReturns.remove(selection) ?: return@dispatch
                    if(witness.first !in tab.ports)return@dispatch
                    witness.first.postMessage(JSONObject().put("action","restore_instagram").put("identity",witness.second)
                        .put("page",tab.url).put("time",request.optLong("position_ms").coerceAtLeast(0)/1000.0).put("play",request.optBoolean("play")))
                    return@dispatch
                }
                for ((port,list) in tab.sources) for (index in 0 until list.length()) {
                    val item = list.getJSONObject(index)
                    val data=item.optJSONObject(kind) ?: continue
                    if (WebBrowserMediaPolicy.selectedCandidate(listOf(item),selection) == null) continue
                    port.postMessage(JSONObject().put("action","restore_$kind").put("id",item.optString("id"))
                        .put("epoch",item.optLong("network_epoch")).put("page",data.getString("page")).put("revision",data.optString("revision"))
                        .put("time",request.optLong("position_ms").coerceAtLeast(0)/1000.0).put("play",request.optBoolean("play")))
                }
            }
            "pause_tab", "resume_tab" -> {
                val tab = tabs.firstOrNull { it.id == request.optInt("tab") && it.window == id } ?: return@dispatch
                if (!tab.awake || window(id).tab != tab.id || tab.navigation != request.optLong("navigation", -1) ||
                    tab.url != request.optString("origin")) return@dispatch
                if (request.optString("action") == "pause_tab") {
                    val token = request.optLong("pause_token")
                    if (token <= 0 || token <= tab.pauseToken) return@dispatch
                    tab.pauseToken = token; tab.pauseReports.clear()
                    val originals = tab.ports.filterValues { it == tab.navigation }.keys.associateWith { port ->
                        val list = tab.media[port] ?: JSONArray()
                        (0 until list.length()).map { list.getJSONObject(it) }
                    }
                    tab.pauseHasDom = originals.values.flatten().any { it.optString("id").toLongOrNull() != null }
                    tab.pauseWasPlaying = tab.playing || originals.values.flatten().any { it.optBoolean("playing") }
                    tab.playback?.pause()
                    originals.forEach { (port, items) -> runCatching { port.postMessage(JSONObject().put("action", "pause_media").put("token", token)
                        .put("playing_ids", JSONArray(items.filter { it.optBoolean("playing") }.map { it.optString("id") }))) } }
                } else if (tab.pauseToken > 0 && tab.pauseToken == request.optLong("pause_token")) {
                    playbackHold.release(holdOwner(request))
                    // DOM videos restore their own saved state. MediaSession.play can arrive
                    // after a subsequent pause; use it only for players without a DOM video.
                    val dom = tab.pauseHasDom || tab.pauseReports.values.any { it.first == tab.pauseToken && it.second }
                    val restore = request.optBoolean("restore_paused") || request.optBoolean("was_playing")
                    tab.ports.keys.forEach { runCatching { it.postMessage(JSONObject().put("action", "release_pause_media")
                        .put("token", tab.pauseToken).put("play", restore)) } }
                    tab.pauseToken = 0; tab.pauseReports.clear()
                    if (!dom && restore && tab.pauseWasPlaying) tab.playback?.play()
                    tab.pauseWasPlaying = false; tab.pauseHasDom = false
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

    private fun installKeyboardDelegate(tab: Tab) {
        // Observe visibility without replacing Gecko's complete system-IME behavior.
        tab.session.textInput.setDelegate(null)
        val system = tab.session.textInput.delegate
        tab.session.textInput.setDelegate(object : GeckoSession.TextInputDelegate {
            private fun owns(session: GeckoSession) = ownsSession(tab, session) && current() === tab && active
            override fun restartInput(session: GeckoSession, reason: Int) {
                if (!owns(session)) return
                keyboardEditorSerial++
                if (!customKeyboard) system.restartInput(session, reason)
                if (reason == GeckoSession.TextInputDelegate.RESTART_REASON_BLUR) {
                    if (tab.keyboardManual) {
                        tab.editing = false; tab.editor = null
                        if (customKeyboard) captureKeyboardEditor(tab)
                        publish(); return
                    }
                    keyboardShowSerial++; keyboardSession.close(); tab.keyboardVisible = false
                    tab.editing = false; tab.editor = null; publish()
                } else if (customKeyboard) captureKeyboardEditor(tab)
            }
            override fun showSoftInput(session: GeckoSession) {
                if (!owns(session)) return
                keyboardShowSerial++
                if (customKeyboard) {
                    if (keyboardSession.target?.tab != tab.id || tab.editor == null) captureKeyboardEditor(tab)
                } else {
                    system.showSoftInput(session); tab.keyboardVisible = true; publish()
                }
            }
            override fun hideSoftInput(session: GeckoSession) {
                if (!owns(session)) return
                // A manual page keyboard remains available for shortcuts after a field blurs.
                if (tab.keyboardManual) {
                    if (customKeyboard) captureKeyboardEditor(tab)
                    publish(); return
                }
                if (!customKeyboard) system.hideSoftInput(session)
                keyboardShowSerial++; keyboardSession.close(); tab.keyboardVisible = false
                tab.editing = false; tab.editor = null; publish()
            }
            override fun updateSelection(session: GeckoSession, start: Int, end: Int, composingStart: Int, composingEnd: Int) {
                if (!customKeyboard && owns(session)) system.updateSelection(session, start, end, composingStart, composingEnd)
            }
            override fun updateExtractedText(session: GeckoSession, request: android.view.inputmethod.ExtractedTextRequest,
                                             text: android.view.inputmethod.ExtractedText) {
                if (!customKeyboard && owns(session)) system.updateExtractedText(session, request, text)
            }
            override fun updateCursorAnchorInfo(session: GeckoSession, info: android.view.inputmethod.CursorAnchorInfo) {
                if (!customKeyboard && owns(session)) system.updateCursorAnchorInfo(session, info)
            }
        })
    }

    private fun captureKeyboardEditor(tab: Tab) {
        if (!customKeyboard || !active || current() !== tab || input?.tab !== tab) return
        keyboardSession.close()
        val info = EditorInfo()
        val connection = tab.session.textInput.onCreateInputConnection(info)
        tab.editor = connection
        tab.editorType = info.inputType
        tab.editorAction = info.imeOptions and EditorInfo.IME_MASK_ACTION
        tab.editing = connection != null && info.inputType != 0
        if (!tab.editing) tab.editor = null
        tab.keyboardVisible = tab.editing || tab.keyboardManual
        if (tab.keyboardVisible) {
            if (tab.editing) tab.protectedInput = true
            keyboardSession.open(tab.window, tab.id, tab.navigation)
        }
        publish()
    }

    private fun editKeyboard(target: WebBrowserKeyboardSession.Target, command: String, value: String) {
        val tab = current() ?: return
        if (!active || tab.id != target.tab || tab.window != target.window || tab.navigation != target.navigation) return
        if (command == "close") {
            tab.session.setFocused(false); hideInput(); publish(); return
        }
        if (value.length > 2048 || '\u0000' in value) return
        val editor = tab.editor
        if (editor == null || !tab.editing) {
            ui.post {
                if (customKeyboard && tab.keyboardManual && keyboardSession.accepts(target) && current() === tab &&
                    active && tab.navigation == target.navigation && input?.tab === tab && tab.editor == null) {
                    pageKeyboardInput(tab, command, value)
                }
            }
            return
        }
        val action = tab.editorAction
        (editor.handler ?: ui).post {
            if (!customKeyboard || !keyboardSession.accepts(target) || input?.tab !== tab || tab.editor !== editor ||
                current() !== tab || tab.navigation != target.navigation || tab.window != target.window) return@post
            fun key(code: Int) {
                editor.sendKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, code))
                editor.sendKeyEvent(KeyEvent(KeyEvent.ACTION_UP, code))
            }
            when (command) {
                "text" -> editor.commitText(value, 1)
                "backspace" -> if (!editor.getSelectedText(0).isNullOrEmpty()) editor.commitText("", 1)
                    else editor.deleteSurroundingTextInCodePoints(1, 0)
                "left" -> key(KeyEvent.KEYCODE_DPAD_LEFT)
                "right" -> key(KeyEvent.KEYCODE_DPAD_RIGHT)
                "enter" -> if (action in setOf(EditorInfo.IME_ACTION_NONE, EditorInfo.IME_ACTION_UNSPECIFIED) ||
                    !editor.performEditorAction(action)) key(KeyEvent.KEYCODE_ENTER)
            }
        }
    }

    /** Forward physical-style keys to Gecko even when no DOM text editor is focused. */
    private fun pageKeyboardInput(tab: Tab, command: String, value: String = ""): Boolean {
        if (!active || current() !== tab || input?.tab !== tab) return false
        fun event(key: KeyEvent): Boolean = when (key.action) {
            KeyEvent.ACTION_UP -> tab.session.textInput.onKeyUp(key.keyCode, key)
            KeyEvent.ACTION_MULTIPLE -> tab.session.textInput.onKeyMultiple(key.keyCode, key.repeatCount, key)
            else -> tab.session.textInput.onKeyDown(key.keyCode, key)
        }
        val request = WebBrowserPageKeyboard.input(command, value) ?: return false
        if (request is WebBrowserPageKeyboard.Input.Text) {
            val keys = KeyCharacterMap.load(KeyCharacterMap.VIRTUAL_KEYBOARD).getEvents(request.value.toCharArray())
            if (keys != null) keys.forEach { event(it) }
            else event(KeyEvent(SystemClock.uptimeMillis(), request.value, KeyCharacterMap.VIRTUAL_KEYBOARD, 0))
            return true
        }
        val code = when ((request as WebBrowserPageKeyboard.Input.Press).key) {
            WebBrowserPageKeyboard.Key.BACKSPACE -> KeyEvent.KEYCODE_DEL
            WebBrowserPageKeyboard.Key.DELETE -> KeyEvent.KEYCODE_FORWARD_DEL
            WebBrowserPageKeyboard.Key.ENTER -> KeyEvent.KEYCODE_ENTER
            WebBrowserPageKeyboard.Key.LEFT -> KeyEvent.KEYCODE_DPAD_LEFT
            WebBrowserPageKeyboard.Key.RIGHT -> KeyEvent.KEYCODE_DPAD_RIGHT
        }
        event(KeyEvent(KeyEvent.ACTION_DOWN, code)); event(KeyEvent(KeyEvent.ACTION_UP, code))
        return true
    }

    /** An IME connection for page shortcuts, not a hidden URL editor. Composition stays local
     * until committed; the committed characters become Gecko key events on the UI thread. */
    private inner class PageKeyboardConnection(view: View, private val owner: Tab, private val navigation: Long,
                                               private val serial: Long) : BaseInputConnection(view, true) {
        override fun getHandler(): Handler = ui
        private fun send(command: String, text: String = ""): Boolean {
            if (text.length > 2048 || '\u0000' in text) return false
            ui.post {
                if (active && current() === owner && owner.navigation == navigation && owner.keyboardManual &&
                    serial == keyboardEditorSerial && input?.tab === owner) pageKeyboardInput(owner, command, text)
            }
            return true
        }
        override fun setComposingText(text: CharSequence?, newCursorPosition: Int): Boolean =
            text != null && text.length <= 2048 && super.setComposingText(text, newCursorPosition)
        override fun commitText(text: CharSequence?, newCursorPosition: Int): Boolean {
            val sent = send("text", text?.toString().orEmpty())
            editable?.clear(); return sent
        }
        override fun deleteSurroundingText(beforeLength: Int, afterLength: Int): Boolean {
            if (!editable.isNullOrEmpty()) return super.deleteSurroundingText(beforeLength, afterLength)
            repeat(beforeLength.coerceIn(0,32)) { send("backspace") }
            repeat(afterLength.coerceIn(0,32)) { send("delete") }
            return true
        }
        override fun deleteSurroundingTextInCodePoints(beforeLength: Int, afterLength: Int): Boolean =
            deleteSurroundingText(beforeLength, afterLength)
        override fun performEditorAction(actionCode: Int): Boolean = send("enter")
        override fun sendKeyEvent(event: KeyEvent): Boolean {
            val key = KeyEvent(event)
            ui.post {
                if (active && current() === owner && owner.navigation == navigation && owner.keyboardManual &&
                    serial == keyboardEditorSerial && input?.tab === owner) {
                    when (key.action) {
                        KeyEvent.ACTION_UP -> owner.session.textInput.onKeyUp(key.keyCode, key)
                        KeyEvent.ACTION_MULTIPLE -> owner.session.textInput.onKeyMultiple(key.keyCode, key.repeatCount, key)
                        else -> owner.session.textInput.onKeyDown(key.keyCode, key)
                    }
                }
            }
            return true
        }
    }

    private inner class BrowserInput(owner: Activity) : View(owner) {
        var tab: Tab? = null
        private var imeInsetsVisible = false
        init { isFocusable = true; isFocusableInTouchMode = true; importantForAutofill = IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS }
        override fun onApplyWindowInsets(insets: android.view.WindowInsets): android.view.WindowInsets {
            if (!customKeyboard && android.os.Build.VERSION.SDK_INT >= 30) {
                val visible = insets.isVisible(android.view.WindowInsets.Type.ime())
                // Some XR runtimes use an independent floating IME without insets.
                // Only a previously reported IME may use its disappearance as dismissal.
                if (visible || imeInsetsVisible) {
                    imeInsetsVisible = visible
                    if (!visible) tab?.keyboardManual = false
                    tab?.keyboardVisible = visible; publish()
                }
            }
            return super.onApplyWindowInsets(insets)
        }
        override fun onCheckIsTextEditor(): Boolean = !customKeyboard
        // All supported Android versions use View's nullable handler (GeckoView's
        // Android 24+ path), including late IME callbacks after detachment.
        override fun onCreateInputConnection(info: EditorInfo): InputConnection? {
            if (customKeyboard) return null // Only our Gecko delegate creates the private connection.
            val owner = tab ?: return null
            val navigation = owner.navigation
            val connection = owner.session.textInput.onCreateInputConnection(info)
            val editing = connection != null && info.inputType != 0
            val pageKeys = !editing && owner.keyboardManual
            if (pageKeys) {
                info.inputType = android.text.InputType.TYPE_CLASS_TEXT or android.text.InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
                info.imeOptions = EditorInfo.IME_ACTION_NONE or EditorInfo.IME_FLAG_NO_EXTRACT_UI
            }
            ui.post {
                if (tab === owner && owner.navigation == navigation && active && current() === owner) {
                    owner.editor = if (editing) connection else null
                    owner.editorAction = info.imeOptions and EditorInfo.IME_MASK_ACTION
                    owner.editing = editing
                    if (owner.editing) owner.protectedInput = true
                    publish()
                }
            }
            return if (pageKeys) PageKeyboardConnection(this, owner, navigation, keyboardEditorSerial) else connection
        }
        override fun onKeyPreIme(code: Int, event: KeyEvent): Boolean {
            if (code == KeyEvent.KEYCODE_BACK && event.action == KeyEvent.ACTION_UP) {
                keyboardShowSerial++; tab?.keyboardVisible = false; tab?.keyboardManual = false; publish()
            }
            return tab?.session?.textInput?.onKeyPreIme(code, event) ?: false
        }
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
        if (command == "custom") {
            if (!customKeyboard || text.length > 8192) return@dispatch
            val request = runCatching { JSONObject(text) }.getOrNull() ?: return@dispatch
            val target = WebBrowserKeyboardSession.Target(request.optInt("window"), request.optInt("tab"), request.optLong("navigation"), request.optLong("epoch"))
            if (!keyboardSession.accepts(target)) return@dispatch
            editKeyboard(target, request.optString("command"), request.optString("text"))
            return@dispatch
        }
        val tab = current() ?: return@dispatch
        if (!active) return@dispatch
        if (command in setOf("show", "close") && text.isNotEmpty()) {
            val target = runCatching { JSONObject(text) }.getOrNull() ?: return@dispatch
            if (target.optInt("window") != tab.window || target.optInt("tab") != tab.id || target.optLong("navigation", -1) != tab.navigation) return@dispatch
        }
        if (command == "show") {
            tab.keyboardManual = true
            tab.session.setFocused(true); attachInput(tab)
            if (customKeyboard) captureKeyboardEditor(tab)
            else input?.let { view ->
                val serial = ++keyboardShowSerial
                val navigation = tab.navigation
                val manager = view.context.getSystemService(android.content.Context.INPUT_METHOD_SERVICE) as android.view.inputmethod.InputMethodManager
                view.post {
                    if (serial != keyboardShowSerial || current() !== tab || !active || tab.navigation != navigation || input?.tab !== tab) return@post
                    manager.restartInput(view)
                    manager.showSoftInput(view, 0,
                    object : android.os.ResultReceiver(ui) {
                        override fun onReceiveResult(code: Int, data: android.os.Bundle?) {
                            if (serial != keyboardShowSerial || current() !== tab || !active || tab.navigation != navigation || input?.tab !== tab) return
                            tab.keyboardVisible = code == android.view.inputmethod.InputMethodManager.RESULT_SHOWN ||
                                code == android.view.inputmethod.InputMethodManager.RESULT_UNCHANGED_SHOWN
                            publish()
                        }
                    })
                }
            }
            return@dispatch
        }
        if (command == "close") {
            tab.session.setFocused(false); hideInput(); publish(); return@dispatch
        }
        if (!tab.editing) {
            if (tab.keyboardManual) pageKeyboardInput(tab, command, text)
            return@dispatch
        }
        val editor = tab.editor ?: return@dispatch
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
        keyboardShowSerial++
        keyboardEditorSerial++
        keyboardSession.close()
        tabs.forEach { tab ->
            tab.editor?.let { editor -> (editor.handler ?: ui).post { editor.finishComposingText() } }
            tab.editing = false; tab.editor = null; tab.keyboardVisible = false; tab.keyboardManual = false
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
        tab?.media?.values?.flatMap { list -> (0 until list.length()).map { list.getJSONObject(it) } }
            ?.sortedByDescending { it.optBoolean("weibo_selected") }?.take(16)?.forEach(videos::put)
        return JSONObject().put("tab_id", tab?.id ?: 0).put("navigation", tab?.navigation ?: 0)
            .put("network_capture_available", tab != null && WebBrowserNetworkPolicy.available(tab.url))
            .put("network_capture_enabled", tab != null && networkEnabled(tab))
            .put("bilibili_beta_available", tab != null && bilibiliEligible(tab))
            .put("douyin_beta_available", tab != null && douyinEnabled(tab))
            .put("weibo_beta_available", tab != null && WebBrowserWeibo.document(tab.url))
            .put("tencent_beta_available",tab != null && WebBrowserTencent.enabled(tab.url))
            .put("mango_beta_available",tab != null && WebBrowserMango.enabled(tab.url))
            .put("youku_beta_available",tab != null && WebBrowserYouku.enabled(tab.url))
            .put("niconico_beta_available",tab != null && WebBrowserNiconico.enabled(tab.url))
            .put("twitch_beta_available",tab != null && WebBrowserTwitch.enabled(tab.url))
            .put("tiktok_beta_available",tab != null && WebBrowserTikTok.enabled(tab.url))
            .put("instagram_beta_available",tab != null && WebBrowserInstagram.enabled(tab.url))
            .put("ted_beta_available",tab != null && WebBrowserTed.enabled(tab.url))
            .put("redbull_beta_available",tab != null && WebBrowserRedBull.enabled(tab.url))
            .put("streamable_beta_available",tab != null && WebBrowserStreamable.enabled(tab.url))
            .put("reddit_beta_available",tab != null && WebBrowserReddit.enabled(tab.url))
            .put("naver_beta_available",tab != null && WebBrowserNaver.enabled(tab.url))
            .put("archive_beta_available",tab != null && WebBrowserArchive.enabled(tab.url))
            .put("odysee_beta_available",tab != null && WebBrowserOdysee.enabled(tab.url))
            .put("dailymotion_beta_available",tab != null && WebBrowserDailymotion.enabled(tab.url))
            .put("iqiyi_beta_available",tab != null && WebBrowserIqiyi.enabled(tab.url))
            .put("weibo_request", tab?.weiboRequest ?: 0).put("weibo_selection", tab?.weiboSelection.orEmpty())
            .put("beta_request", tab?.betaRequest ?: 0).put("beta_selection", tab?.betaSelection.orEmpty())
            .put("fullscreen_request", tab?.fullscreen?.request ?: 0).put("fullscreen_video", tab?.fullscreen?.active == true)
            .put("captured_fullscreen_request", tab?.capturedFullscreenRequest ?: 0)
            .put("url", tab?.url ?: "about:blank").put("title", tab?.title.orEmpty())
            .put("bookmark_url", tab?.url?.let(WebBrowserAddress::recordable).orEmpty())
            .put("progress", tab?.progress ?: 0).put("back", tab?.back == true || tab?.fullScreen == true).put("forward", tab?.forward == true)
            .put("loading", tab?.loading == true)
            .put("start_page", tab != null && tab.startPage && !tab.loading && tab.url == "about:blank" && tab.error.isEmpty())
            .put("pause_token", tab?.pauseToken ?: 0)
            .put("pause_confirmed", tab != null && pauseConfirmed(tab))
            .put("retained_for_playback", tab != null && playbackHold.protects(tab.id, tab.navigation))
            .put("playing", tab != null && (tab.playing || tab.media.values.any { list -> (0 until list.length()).any { i -> list.getJSONObject(i).optBoolean("playing") } }))
            .put("error", tab?.error.orEmpty()).put("editing", tab?.editing == true).put("videos", videos).put("fullscreen", tab?.fullScreen == true)
            .put("keyboard_visible", active && tab != null && current() === tab && tab.keyboardVisible)
            .put("custom_keyboard", customKeyboard && tab != null && keyboardSession.target?.tab == tab.id && tab.keyboardVisible)
            .put("keyboard_epoch", if (customKeyboard && tab != null && keyboardSession.target?.tab == tab.id) keyboardSession.target?.epoch ?: 0 else 0)
            .put("keyboard_latin", tab?.editorType?.takeIf { it != 0 }?.let { type ->
                val variation = type and android.text.InputType.TYPE_MASK_VARIATION
                (type and android.text.InputType.TYPE_MASK_CLASS) != android.text.InputType.TYPE_CLASS_TEXT ||
                    variation in setOf(android.text.InputType.TYPE_TEXT_VARIATION_URI, android.text.InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS,
                        android.text.InputType.TYPE_TEXT_VARIATION_WEB_EMAIL_ADDRESS, android.text.InputType.TYPE_TEXT_VARIATION_PASSWORD,
                        android.text.InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD, android.text.InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD)
            } ?: false)
            .also { result -> if (mediaDiagnosticsEnabled() && tab != null) {
                val ports = tab.ports.filterValues { it == tab.navigation }.keys
                result.put("pause_ports", ports.size)
                    .put("pause_report_ports", ports.count { tab.pauseReports[it]?.first == tab.pauseToken })
                    .put("pause_media_ports", ports.count { (tab.media[it]?.length() ?: 0) > 0 })
                    .put("pause_missing_media_ports", ports.count { (tab.media[it]?.length() ?: 0) > 0 && tab.pauseReports[it]?.first != tab.pauseToken })
                    .put("media_report_age_ms", if (tab.lastMediaReport > 0) (SystemClock.uptimeMillis() - tab.lastMediaReport).coerceIn(0, 3_600_000) else -1)
            } }
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
