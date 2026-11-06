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
    private val media = mutableMapOf<WebExtension.Port, JSONArray>()
    private val ports = mutableSetOf<WebExtension.Port>()
    private val portNavigation = mutableMapOf<WebExtension.Port,Int>()
    private val reports = mutableMapOf<WebExtension.Port,JSONObject>()
    private var bridge: FixtureMemoryBridge? = null
    private var owner: WebExtension.Port? = null
    private var selected: JSONObject? = null
    private var selectedNavigation = 0
    private var phase = "idle"
    private var token = 0
    private var observedRequest = 0
    private var returnTime = 0.0
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
            override fun onLocationChange(s: GeckoSession,url: String?,perms: MutableList<GeckoSession.PermissionDelegate.ContentPermission>,hasUserGesture: Boolean) {
                if (url != null) page = url
                sendPolicy();publish()
            }
            override fun onLoadError(s: GeckoSession,uri: String?,failure: WebRequestError): GeckoResult<String>? {
                error = "load_${failure.category}_${failure.code}";publish();return null
            }
        }
        session.progressDelegate = object : GeckoSession.ProgressDelegate {
            override fun onPageStart(s: GeckoSession,url: String) { invalidateHandoff();page=url;navigation++;media.clear();reports.clear();observedRequest=0;trace=JSONObject();lastReport=0;progress=0;publish() }
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
                            val valid=WebBrowserMango.metadata(item,page)!=null
                            captured.put("frame_matches",item.optString("frame")==page).put("binding_valid",valid)
                            safe.put(JSONObject().put("id",item.optString("id").takeIf { it.matches(Regex("[0-9]{1,8}")) }.orEmpty())
                                .put("width",item.optInt("width").coerceIn(0,32768)).put("height",item.optInt("height").coerceIn(0,32768))
                                .put("duration",item.optDouble("duration",0.0).takeIf { it.isFinite() && it in 0.0..172800.0 } ?: 0.0)
                                .put("time",item.optDouble("time",0.0).takeIf { it.isFinite() && it in 0.0..172800.0 } ?: 0.0)
                                .put("playing",item.optBoolean("playing")).put("protected",item.optBoolean("protected"))
                                .put("blob",item.optBoolean("blob")).put("js_ready",item.optBoolean("mango_ready"))
                                .put("java_ready",valid).put("mango_capture",captured))
                        }
                        media[port]=safe;lastReport=SystemClock.uptimeMillis()
                        if (bridge!=null && owner==null && active && phase in setOf("idle","returned","invalid")) {
                            val clicked=(0 until list.length()).mapNotNull { list.optJSONObject(it) }.filter {
                                it.optInt("mango_request")>observedRequest && it.optBoolean("mango_ready") && WebBrowserMango.metadata(it,page)!=null
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
            .put("douyin",false).put("weibo",false).put("tencent",false).put("mango",WebBrowserMango.enabled(page)).put("diagnostics",true))
    }
    private fun sendPolicy() { ports.filter { portNavigation[it]==navigation }.forEach { runCatching { policy(it) } } }
    override fun onNewIntent(value: Intent) { super.onNewIntent(value);intent=value;command(value) }
    private fun command(value: Intent) {
        if (extension==null) return
        when(value.getStringExtra("operation") ?: "open") {
            "open" -> {
                val url=value.getStringExtra("url") ?: "https://www.mgtv.com/b/427837/15588271.html"
                if (!WebBrowserMango.enabled(url)) { error="unsupported_public_page";publish();return }
                page=url;error="";session.loadUri(url)
            }
            "reload" -> session.reload()
            "inactive" -> { active=false;ports.toList().forEach { it.postMessage(JSONObject().put("action","suspend")) };session.setActive(false) }
            "active" -> { active=true;session.setActive(true);ports.toList().forEach { it.postMessage(JSONObject().put("action","resume")) } }
            "snapshot" -> Unit
            "bridge" -> {
                val name=value.getStringExtra("channel").orEmpty()
                if(!name.matches(Regex("thru3d_fixture_[a-f0-9]{32}")) || android.os.Build.HARDWARE !in setOf("ranchu","goldfish")) {
                    error="invalid_local_channel";publish();return
                }
                if(owner!=null && phase!="returned") invalidateHandoff()
                owner=null;selected=null;phase="idle"
                observedRequest=reports.values.flatMap { report ->
                    val list=report.optJSONArray("videos") ?: JSONArray()
                    (0 until list.length()).map { list.optJSONObject(it)?.optInt("mango_request") ?: 0 }
                }.maxOrNull() ?: 0
                bridge?.close();bridge=FixtureMemoryBridge(name,handler,::bridgeRequest)
            }
            else -> { error="unknown_operation" }
        }
        publish()
    }
    private fun currentSelected(): JSONObject? {
        val original=selected ?: return null
        if(selectedNavigation!=navigation || portNavigation[owner]!=navigation) return null
        val list=reports[owner]?.optJSONArray("videos") ?: return null
        return (0 until list.length()).mapNotNull { list.optJSONObject(it) }.singleOrNull {
            listOf("id","frame","source","network_epoch","width","height").all { key -> it.opt(key)==original.opt(key) } &&
                it.optJSONObject("mango")?.optString("revision")==original.optJSONObject("mango")?.optString("revision") &&
                WebBrowserMango.metadata(it,page)!=null
        }
    }
    private fun currentPorts() = ports.filter { portNavigation[it]==navigation }
    private fun postAll(message: JSONObject) { currentPorts().forEach { runCatching { it.postMessage(message) } } }
    private fun beginHandoff(port: WebExtension.Port,item: JSONObject) {
        observedRequest=item.getInt("mango_request");owner=port;selected=JSONObject(item.toString());selectedNavigation=navigation
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
        if(current==null) { invalidateHandoff();return }
        if(phase=="pausing" && allPaused()) phase="held"
        if(phase=="inactive" && allPaused(true)) suspendConfirmed=true
        if(phase=="returning" && reports[owner]?.optInt("pause_token")==0 && reports[owner]?.optBoolean("suspended")==false &&
            !current.optBoolean("playing") && kotlin.math.abs(current.optDouble("time")-returnTime)<1.0) phase="returned"
    }
    private fun restoreOriginal(position: Double) {
        val original=selected ?: return
        returnTime=position;active=true;session.setActive(true)
        postAll(JSONObject().put("action","resume"))
        postAll(JSONObject().put("action","release_pause_media").put("token",token).put("play",false))
        owner?.postMessage(JSONObject().put("action","restore_mango").put("id",original.getString("id"))
            .put("epoch",original.get("network_epoch")).put("page",original.getString("frame"))
            .put("revision",original.getJSONObject("mango").getString("revision")).put("time",position).put("play",false))
        phase="returning"
    }
    private fun invalidateHandoff() {
        if(owner!=null && ::session.isInitialized) {
            active=true;session.setActive(true);postAll(JSONObject().put("action","resume"))
            postAll(JSONObject().put("action","release_pause_media").put("token",token).put("play",false))
        }
        owner=null;selected=null;phase="invalid";suspendConfirmed=false
    }
    private fun handoffStatus() = JSONObject().put("phase",phase).put("navigation",selectedNavigation).put("token",token)
        .put("same_binding",owner!=null && currentSelected()!=null).put("suspend_confirmed",suspendConfirmed)
        .put("original_port_connected",owner!=null && owner in ports).put("return_time",returnTime)
    private fun bridgeRequest(request: JSONObject): JSONObject {
        when(request.optString("action")) {
            "status" -> Unit
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
            "close" -> { if(owner!=null && phase!="returned") invalidateHandoff();owner=null;selected=null;bridge?.close();bridge=null }
            else -> return JSONObject().put("ok",false)
        }
        updateHandoff();publish()
        return JSONObject().put("ok",true).put("instance",instance).put("active",active).put("handoff",handoffStatus())
    }
    private fun publish() {
        val list=JSONArray();for (items in media.values) for (i in 0 until items.length()) if(list.length()<16) list.put(items.getJSONObject(i))
        val result=JSONObject().put("schema",1).put("scope","android_gecko_request_diagnostics_not_device_acceptance")
            .put("instance",instance).put("sequence",++sequence).put("state",state).put("error",error).put("navigation",navigation).put("progress",progress)
            .put("active",active).put("page_id",WebBrowserMango.page(page).orEmpty()).put("extension_ready",extension!=null)
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
