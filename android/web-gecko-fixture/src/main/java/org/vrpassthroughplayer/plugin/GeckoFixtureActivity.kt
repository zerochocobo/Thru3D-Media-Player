package org.vrpassthroughplayer.plugin

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.View
import org.json.JSONArray
import org.json.JSONObject
import org.mozilla.geckoview.*
import java.io.File
import java.util.UUID

/** Anonymous, emulator-only request diagnostics. Raw port messages never go to disk/logcat. */
class GeckoFixtureActivity : Activity() {
    companion object {
        private const val EXTENSION = "web-video@thru3d.local"
        private var runtime: GeckoRuntime? = null
    }
    private val handler = Handler(Looper.getMainLooper())
    private val viewport = WebBrowserViewport(false)
    private lateinit var session: GeckoSession
    private lateinit var view: GeckoView
    private var extension: WebExtension? = null
    private var page = "about:blank"
    private var navigation = 0
    private var progress = 0
    private var state = "starting"
    private var active = true
    private var error = ""
    private var lastReport = 0L
    private var sequence = 0
    private val instance = UUID.randomUUID().toString()
    private var trace = JSONObject()
    private var iqiyiSchema = JSONObject()
    private var rejectedNavigations = 0
    private val navigationShapes = java.util.ArrayDeque<JSONObject>()
    private val media = mutableMapOf<WebExtension.Port, JSONArray>()
    private val ports = mutableSetOf<WebExtension.Port>()
    private val portNavigation = mutableMapOf<WebExtension.Port,Int>()
    private val reports = mutableMapOf<WebExtension.Port,JSONObject>()
    private var bridge: FixtureMemoryBridge? = null
    private var owner: WebExtension.Port? = null
    private var selected: JSONObject? = null
    private var selectedAdapter: String? = null
    private var selectedNavigation = 0
    private var phase = "idle"
    private var token = 0
    private var observedRequest = 0
    private var returnTime = 0.0
    private var returnStarted = 0L
    private var seekWaitReports = 0
    private var suspendConfirmed = false
    private val ticker = object : Runnable {
            override fun run() { updateHandoff();publish(); handler.postDelayed(this, 1000) }
    }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        @Suppress("DEPRECATION")
        window.decorView.systemUiVisibility = View.SYSTEM_UI_FLAG_FULLSCREEN or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
        // Same engine/session settings as WebBrowser.engine() and newSession().
        if (runtime == null) runtime = GeckoRuntime.create(applicationContext, GeckoRuntimeSettings.Builder()
            .remoteDebuggingEnabled(false).consoleOutput(false)
            .displayDensityOverride(viewport.density).displayDpiOverride(viewport.dpi)
            .screenSizeOverride(viewport.width,viewport.height).build())
        session = GeckoSession(GeckoSessionSettings.Builder().usePrivateMode(false)
            .userAgentMode(GeckoSessionSettings.USER_AGENT_MODE_DESKTOP)
            .viewportMode(GeckoSessionSettings.VIEWPORT_MODE_DESKTOP).suspendMediaWhenInactive(true).build())
        session.navigationDelegate = object : GeckoSession.NavigationDelegate {
            override fun onLoadRequest(s: GeckoSession,request: GeckoSession.NavigationDelegate.LoadRequest): GeckoResult<AllowOrDeny> {
                // Reuse the production browser's ordinary navigation gate. A site's
                // attempted app launch must not retire the still-visible web document.
                val allowed=WebBrowserAddress.navigable(request.uri) &&
                    (request.target!=GeckoSession.NavigationDelegate.TARGET_WINDOW_NEW || request.hasUserGesture)
                if(!allowed) { rejectedNavigations++;recordNavigation("denied",request.uri);publish() }
                return GeckoResult.fromValue(if(allowed) AllowOrDeny.ALLOW else AllowOrDeny.DENY)
            }
            override fun onLocationChange(s: GeckoSession,url: String?,perms: MutableList<GeckoSession.PermissionDelegate.ContentPermission>,hasUserGesture: Boolean) {
                if (url != null) { page = url;recordNavigation("location",url) }
                sendPolicy();publish()
            }
            override fun onLoadError(s: GeckoSession,uri: String?,failure: WebRequestError): GeckoResult<String>? {
                recordNavigation("error",uri.orEmpty());error = "load_${failure.category}_${failure.code}";publish();return null
            }
        }
        session.progressDelegate = object : GeckoSession.ProgressDelegate {
            override fun onPageStart(s: GeckoSession,url: String) {
                recordNavigation("start",url)
                if(!WebBrowserAddress.navigable(url)) { recordNavigation("ignored_start",url);publish();return }
                invalidateHandoff();page=url;navigation++;media.clear();reports.clear();observedRequest=0;trace=JSONObject();iqiyiSchema=JSONObject();lastReport=0;progress=0;publish()
            }
            override fun onProgressChange(s: GeckoSession,value: Int) { progress=value;publish() }
            override fun onPageStop(s: GeckoSession,success: Boolean) { state=if(success) "loaded" else "load_failed";publish() }
        }
        session.contentDelegate = object : GeckoSession.ContentDelegate {
            override fun onCrash(s: GeckoSession) { invalidateHandoff();error="content_crashed";publish() }
            override fun onKill(s: GeckoSession) { invalidateHandoff();error="content_killed";publish() }
        }
        session.open(runtime!!)
        view=GeckoView(this);view.setSession(session);setContentView(view)
        runtime!!.webExtensionController.ensureBuiltIn("resource://android/assets/web-browser/",EXTENSION).accept({ installed ->
            if (installed == null || isFinishing) return@accept
            extension=installed;bind(installed);state="extension_ready";command(intent)
        },{ _ -> error="extension_failed";publish() })
        handler.post(ticker)
    }
    private fun bind(installed: WebExtension) {
        session.webExtensionController.setMessageDelegate(installed,object : WebExtension.MessageDelegate {
            override fun onConnect(port: WebExtension.Port) {
                if (port.sender.session !== session || port.sender.webExtension.id != EXTENSION || ports.size>=64) { port.disconnect();return }
                ports.add(port);portNavigation[port]=navigation
                port.setDelegate(object : WebExtension.PortDelegate {
                    override fun onPortMessage(message: Any,port: WebExtension.Port) {
                        if (portNavigation[port]!=navigation) return
                        val data=message as? JSONObject ?: return
                        if (data.optString("type")=="fixture_iqiyi") {
                            if (!WebBrowserIqiyi.enabled(page) || port.sender.url!=page || data.toString().length>100*1024) return
                            val schema=data.optJSONObject("state") ?: return
                            val binding=data.optJSONObject("binding") ?: return
                            iqiyiSchema=JSONObject().put("schema",schema)
                                .put("dom",data.optJSONArray("dom") ?: JSONArray())
                                .put("ready",binding.optBoolean("ready"))
                                .put("status",binding.optString("status").takeIf { it.matches(Regex("[a-z_]{1,48}")) } ?: "unavailable")
                                .put("document_time_origin",data.optDouble("document_time_origin").takeIf { it.isFinite() } ?: 0.0)
                            publish();return
                        }
                        if (data.optString("type")!="media" || data.toString().length>256*1024) return
                        val list=data.optJSONArray("videos") ?: return
                        reports[port]=data
                        // The optional local trace exports counts only. Never copy its raw object.
                        val source=data.optJSONObject("mango_capture")?.optJSONObject("fixture_trace")
                        trace=JSONObject()
                        for (key in listOf("observed_hls","stream_files","stream_h265_files","stream_av01_files",
                            "matched_stream","matched_stream_h265","matched_stream_av01"))
                            if(source?.has(key)==true) trace.put(key,source.optInt(key).coerceIn(0,24))
                        val safe=JSONArray()
                        for (i in 0 until minOf(16,list.length())) {
                            val item=list.optJSONObject(i) ?: continue
                            val captured=WebBrowserMango.captureDiagnostics(data)
                            val kind=FixtureMediaBinding.adapter(page)
                            val valid=FixtureMediaBinding.metadata(item,page)!=null
                            val iqiyiValid=WebBrowserIqiyi.metadata(item,page)!=null
                            captured.put("frame_matches",item.optString("frame")==page).put("binding_valid",WebBrowserMango.metadata(item,page)!=null)
                            safe.put(JSONObject().put("id",item.optString("id").takeIf { it.matches(Regex("[0-9]{1,8}")) }.orEmpty())
                                .put("width",item.optInt("width").coerceIn(0,32768)).put("height",item.optInt("height").coerceIn(0,32768))
                                .put("duration",item.optDouble("duration",0.0).takeIf { it.isFinite() && it in 0.0..172800.0 } ?: 0.0)
                                .put("time",item.optDouble("time",0.0).takeIf { it.isFinite() && it in 0.0..172800.0 } ?: 0.0)
                                .put("playing",item.optBoolean("playing")).put("protected",item.optBoolean("protected"))
                                .put("blob",item.optBoolean("blob")).put("adapter",kind.orEmpty()).put("js_ready",kind!=null && item.optBoolean("${kind}_ready"))
                                .put("java_ready",valid).put("mango_capture",captured)
                                .put("twitch_ready",item.optBoolean("twitch_ready")).put("twitch_binding",WebBrowserTwitch.metadata(item,page)!=null)
                                .put("ted_ready",item.optBoolean("ted_ready")).put("ted_binding",WebBrowserTed.metadata(item,page)!=null)
                                .put("iqiyi_ready",item.optBoolean("iqiyi_ready")).put("iqiyi_binding",iqiyiValid))
                        }
                        media[port]=safe;lastReport=SystemClock.uptimeMillis()
                        if (bridge!=null && owner==null && active && phase in setOf("idle","returned","invalid")) {
                            val kind=FixtureMediaBinding.adapter(page)
                            val clicked=(0 until list.length()).mapNotNull { list.optJSONObject(it) }.filter {
                                kind!=null && it.optInt("${kind}_request")>observedRequest && it.optBoolean("${kind}_ready") && FixtureMediaBinding.metadata(it,page,kind)!=null
                            }
                            if(clicked.size==1) beginHandoff(port,clicked.single())
                        }
                        updateHandoff();publish()
                    }
                    override fun onDisconnect(port: WebExtension.Port) { if(owner===port) invalidateHandoff();ports.remove(port);portNavigation.remove(port);media.remove(port);reports.remove(port);publish() }
                })
                port.postMessage(JSONObject().put("action",if(active) "resume" else "suspend"));policy(port)
            }
        },"thru3d_video")
    }
    private fun policy(port: WebExtension.Port) {
        port.postMessage(JSONObject().put("action","network_policy").put("enabled",false).put("bilibili",false)
            .put("douyin",false).put("weibo",false).put("tencent",false).put("mango",WebBrowserMango.enabled(page))
            .put("iqiyi",WebBrowserIqiyi.enabled(page)).put("twitch",WebBrowserTwitch.enabled(page))
            .put("ted",WebBrowserTed.observing(page)).put("diagnostics",true))
    }
    private fun sendPolicy() { ports.filter { portNavigation[it]==navigation }.forEach { runCatching { policy(it) } } }
    override fun onNewIntent(value: Intent) { super.onNewIntent(value);intent=value;command(value) }
    private fun command(value: Intent) {
        if (extension==null) return
        when(value.getStringExtra("operation") ?: "open") {
            "open" -> {
                val url=value.getStringExtra("url") ?: "https://www.mgtv.com/b/427837/15588271.html"
                if (FixtureMediaBinding.adapter(url)==null && !WebBrowserIqiyi.enabled(url)) { error="unsupported_public_page";publish();return }
                page=url;error="";session.loadUri(url)
            }
            "reload" -> session.reload()
            "inactive" -> { active=false;ports.toList().forEach { it.postMessage(JSONObject().put("action","suspend")) };session.setActive(false) }
            "active" -> { active=true;session.setActive(true);ports.toList().forEach { it.postMessage(JSONObject().put("action","resume")) } }
            "snapshot" -> postAll(JSONObject().put("action","snapshot"))
            "bridge" -> {
                val kind=FixtureMediaBinding.adapter(page)
                if (kind==null) { error="unsupported_native_bridge_page";publish();return }
                val name=value.getStringExtra("channel").orEmpty()
                if(!name.matches(Regex("thru3d_fixture_[a-f0-9]{32}")) || android.os.Build.HARDWARE !in setOf("ranchu","goldfish")) {
                    error="invalid_local_channel";publish();return
                }
                if(owner!=null && phase!="returned") invalidateHandoff()
                owner=null;selected=null;selectedAdapter=null;phase="idle"
                observedRequest=reports.values.flatMap { report ->
                    val list=report.optJSONArray("videos") ?: JSONArray()
                    (0 until list.length()).map { list.optJSONObject(it)?.optInt("${kind}_request") ?: 0 }
                }.maxOrNull() ?: 0
                bridge?.close();bridge=FixtureMemoryBridge(name,handler,::bridgeRequest)
            }
            else -> { error="unknown_operation" }
        }
        publish()
    }
    private fun currentSelected(): JSONObject? {
        val original=selected ?: return null
        val kind=selectedAdapter ?: return null
        if(selectedNavigation!=navigation || portNavigation[owner]!=navigation) return null
        val list=reports[owner]?.optJSONArray("videos") ?: return null
        return (0 until list.length()).mapNotNull { list.optJSONObject(it) }.singleOrNull {
            if(phase in setOf("returning","returned")) FixtureMediaBinding.sameReturned(original,it,page,kind)
            else FixtureMediaBinding.same(original,it,page,kind)
        }
    }
    private fun currentPorts() = ports.filter { portNavigation[it]==navigation }
    private fun postAll(message: JSONObject) { currentPorts().forEach { runCatching { it.postMessage(message) } } }
    private fun beginHandoff(port: WebExtension.Port,item: JSONObject) {
        val kind=FixtureMediaBinding.adapter(page) ?: return
        observedRequest=item.getInt("${kind}_request");owner=port;selected=JSONObject(item.toString());selectedAdapter=kind;selectedNavigation=navigation
        returnTime=item.optDouble("time",0.0);phase="pausing";suspendConfirmed=false;token++
        for(p in currentPorts()) {
            val list=reports[p]?.optJSONArray("videos") ?: JSONArray()
            val playing=JSONArray((0 until list.length()).mapNotNull { list.optJSONObject(it) }.filter { it.optBoolean("playing") }.map { it.optString("id") })
            p.postMessage(JSONObject().put("action","pause_media").put("token",token).put("playing_ids",playing))
        }
        val ticket=token
        handler.postDelayed({ if(token==ticket && owner!=null) invalidateHandoff() },240000)
    }
    private fun allPaused(suspended: Boolean? = null): Boolean = currentPorts().filter { (reports[it]?.optJSONArray("videos")?.length() ?: 0)>0 }.let { list ->
        list.isNotEmpty() && list.all {
            val r=reports[it]!!
            r.optInt("pause_token")==token && r.optBoolean("pause_held") && (suspended==null || r.optBoolean("suspended")==suspended)
        }
    }
    private fun updateHandoff() {
        if(owner==null) return
        val current=currentSelected()
        if(current==null) {
            val original=selected
            val kind=selectedAdapter
            val list=reports[owner]?.optJSONArray("videos") ?: JSONArray()
            val waiting=original!=null && kind!=null && selectedNavigation==navigation && portNavigation[owner]==navigation &&
                (0 until list.length()).mapNotNull { list.optJSONObject(it) }.count { FixtureMediaBinding.waitingForSeek(original,it,page,kind) }==1
            if(phase in setOf("returning","returned") && SystemClock.uptimeMillis()-returnStarted in 0..3000 && waiting) {
                phase="returning";seekWaitReports++;return
            }
            invalidateHandoff();return
        }
        if(phase=="pausing" && allPaused()) phase="held"
        if(phase=="inactive" && allPaused(true)) suspendConfirmed=true
        if(phase=="returning" && reports[owner]?.optInt("pause_token")==0 && reports[owner]?.optBoolean("suspended")==false &&
            !current.optBoolean("playing") && kotlin.math.abs(current.optDouble("time")-returnTime)<1.0) phase="returned"
    }
    private fun restoreOriginal(position: Double) {
        val original=selected ?: return
        val kind=selectedAdapter ?: return
        returnTime=position;returnStarted=SystemClock.uptimeMillis();seekWaitReports=0;active=true;session.setActive(true)
        postAll(JSONObject().put("action","resume"))
        postAll(JSONObject().put("action","release_pause_media").put("token",token).put("play",false))
        owner?.postMessage(JSONObject().put("action","restore_$kind").put("id",original.getString("id"))
            .put("epoch",original.get("network_epoch")).put("page",original.getString("frame"))
            .put("revision",original.getJSONObject(kind).getString("revision")).put("time",position).put("play",false))
        phase="returning"
    }
    private fun invalidateHandoff() {
        if(owner!=null && ::session.isInitialized) {
            active=true;session.setActive(true);postAll(JSONObject().put("action","resume"))
            postAll(JSONObject().put("action","release_pause_media").put("token",token).put("play",false))
        }
        owner=null;selected=null;selectedAdapter=null;phase="invalid";suspendConfirmed=false
    }
    private fun handoffStatus(): JSONObject {
        val current=currentSelected()
        return JSONObject().put("phase",phase).put("navigation",selectedNavigation).put("token",token)
            .put("same_binding",owner!=null && current!=null).put("suspend_confirmed",suspendConfirmed)
            .put("original_port_connected",owner!=null && owner in ports).put("return_time",returnTime).put("seek_wait_reports",seekWaitReports)
            .put("current_width",current?.optInt("width") ?: 0).put("current_height",current?.optInt("height") ?: 0)
            .put("return_quality_changed",phase in setOf("returning","returned") && selectedAdapter=="ted" && current!=null &&
                (current.opt("width")!=selected?.opt("width") || current.opt("height")!=selected?.opt("height")))
    }
    private fun bridgeRequest(request: JSONObject): JSONObject {
        when(request.optString("action")) {
            // Media reports are event driven. Ask the original ports for fresh
            // read-only snapshots rather than treating an old paused report as live.
            "status" -> postAll(JSONObject().put("action","snapshot"))
            "inactive" -> {
                check(phase=="held" && allPaused() && currentSelected()!=null)
                active=false;phase="inactive";session.setActive(false)
                postAll(JSONObject().put("action","suspend").put("keep_pause",true).put("pause_token",token))
            }
            "capture" -> {
                check(phase=="inactive" && suspendConfirmed && !active && allPaused(true) && SystemClock.uptimeMillis()-lastReport<10000)
                val candidate=currentSelected() ?: error("Current binding lost")
                return JSONObject().put("ok",true).put("media",JSONObject(candidate.toString())).put("handoff",handoffStatus())
            }
            "return" -> {
                check(owner!=null && currentSelected()!=null && phase in setOf("held","inactive"))
                val value=request.optDouble("time",returnTime)
                val duration=selected!!.getDouble("duration")
                check(value.isFinite() && value in 0.0..duration)
                restoreOriginal(value)
            }
            "close" -> { if(owner!=null && phase!="returned") invalidateHandoff();owner=null;selected=null;selectedAdapter=null;bridge?.close();bridge=null }
            else -> return JSONObject().put("ok",false)
        }
        updateHandoff();publish()
        return JSONObject().put("ok",true).put("instance",instance).put("active",active).put("handoff",handoffStatus())
    }
    private fun recordNavigation(event: String,value: String) {
        val uri=runCatching { java.net.URI(value) }.getOrNull()
        val host=uri?.host.orEmpty()
        val site=when(host) {
            "www.iqiyi.com" -> "iqiyi";"www.mgtv.com","w.mgtv.com","mgtv.com" -> "mgtv"
            "www.twitch.tv","twitch.tv","clips.twitch.tv" -> "twitch";"www.ted.com","ted.com" -> "ted";else -> "other"
        }
        val id=WebBrowserIqiyi.page(value) ?: WebBrowserMango.page(value) ?: WebBrowserTwitch.page(value) ?: WebBrowserTed.page(value)
        navigationShapes.addLast(JSONObject().put("event",event).put("site",site)
            .put("scheme",uri?.scheme?.takeIf { it in setOf("http","https","about") } ?: "other")
            .put("public_id",id.orEmpty()).put("about_blank",value=="about:blank")
            .put("has_query",!uri?.rawQuery.isNullOrEmpty()).put("has_fragment",!uri?.rawFragment.isNullOrEmpty()))
        while(navigationShapes.size>16) navigationShapes.removeFirst()
    }
    private fun publish() {
        val list=JSONArray();for (items in media.values) for (i in 0 until items.length()) if(list.length()<16) list.put(items.getJSONObject(i))
        val result=JSONObject().put("schema",1).put("scope","android_gecko_request_diagnostics_not_device_acceptance")
            .put("instance",instance).put("sequence",++sequence).put("state",state).put("error",error).put("navigation",navigation).put("progress",progress)
            .put("active",active).put("page_id",WebBrowserMango.page(page) ?: WebBrowserIqiyi.page(page) ?: WebBrowserTwitch.page(page) ?: WebBrowserTed.page(page).orEmpty())
            .put("site",if(WebBrowserIqiyi.enabled(page)) "iqiyi" else when(FixtureMediaBinding.adapter(page)) { "mango" -> "mgtv";null -> "unsupported";else -> FixtureMediaBinding.adapter(page) })
            .put("iqiyi_schema",iqiyiSchema).put("extension_ready",extension!=null)
            .put("rejected_navigations",rejectedNavigations)
            .put("navigation_shapes",JSONArray(navigationShapes.toList()))
            .put("ports",ports.count { portNavigation[it]==navigation }).put("report_age_ms",if(lastReport==0L) -1 else SystemClock.uptimeMillis()-lastReport)
            .put("viewport",JSONObject().put("width",viewport.width).put("height",viewport.height).put("density",viewport.density))
            .put("videos",list).put("fixture_trace",trace).put("handoff",handoffStatus())
        runCatching {
            val pending=File(filesDir,"state.pending");pending.writeText(result.toString())
            check(pending.renameTo(File(filesDir,"state.json")))
        }
    }
    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        bridge?.close();bridge=null
        if(::session.isInitialized) session.close()
        ports.clear();portNavigation.clear();media.clear();super.onDestroy()
    }
}
