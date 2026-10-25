package org.vrpassthroughplayer.plugin

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import org.json.JSONObject
import java.io.File
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.RejectedExecutionException

/** Shell/system-only developer requests. Absent from the Release AAR/manifest. */
class DebugDiagnosticsReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val request = intent.getStringExtra("request") ?: return
        if (!request.matches(Regex("[A-Za-z0-9_-]{1,64}"))) return
        val pending = goAsync()
        try {
            worker.execute {
                val report = JSONObject().put("request", request).put("action", intent.action)
                    .put("diagnostic_process", DiagnosticRequests.processId)
                try {
                    val id = if (intent.action == "com.wapok.thru3d.DEBUG_PHOTO_PORTRAIT") {
                        PhotoPortraitProbe.request(context.applicationContext,request)
                    } else if (intent.action in setOf("com.wapok.thru3d.DEBUG_LAUNCH", "com.wapok.thru3d.DEBUG_LAUNCH_2D")) {
                        // XR probes must enter through the normal VR launcher. Starting
                        // GodotApp directly produced focused views but no live head pose.
                        val launch = if (intent.action!!.endsWith("_2D")) {
                            Intent().setClassName(context.packageName, "org.vrpassthroughplayer.plugin.MpvDiagnosticActivity")
                        } else {
                            Intent(Intent.ACTION_MAIN)
                                .setClassName(context.packageName, "com.godot.game.GodotAppLauncher")
                                .addCategory("org.khronos.openxr.intent.category.IMMERSIVE_HMD")
                        }
                        context.startActivity(launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                        report.put("launch_entry", if (intent.action!!.endsWith("_2D")) "diagnostic_2d" else "normal_vr_launcher")
                        1
                    } else if (intent.action == "com.wapok.thru3d.DEBUG_RVM_STANDALONE") {
                        RvmStandaloneProbe.request(context.applicationContext, intent.getStringExtra("mode") ?: "resident",
                            intent.getStringExtra("profile") ?: "256x144")
                    } else if (intent.action == "com.wapok.thru3d.DEBUG_MUSIC_FORMATS") {
                        BackgroundAudioProbe.request(context.applicationContext)
                    } else if (intent.action == "com.wapok.thru3d.DEBUG_SMB_CRYPTO") {
                        report.put("smb", SmbCryptoProbe.run())
                        1
                    } else if (intent.action == "com.wapok.thru3d.DEBUG_CLOUD_ISO") {
                        CloudIsoProbe.request(context.applicationContext, request)
                    } else if (intent.action == "com.wapok.thru3d.DEBUG_CLOUD") {
                        val provider = intent.getStringExtra("provider") ?: CloudDrive.P115
                        if (provider == "webdav_test") webDavTest(context.applicationContext, intent, report)
                        else if (provider == CloudDrive.P115) CloudPlaybackProbe.request(context.applicationContext, request, intent.getBooleanExtra("play", false))
                        else OpenListCloudProbe.request(context.applicationContext, request, provider, intent.getBooleanExtra("play", false))
                    } else if (intent.action == "com.wapok.thru3d.DEBUG_PLEX_NETWORK") {
                        val raw = intent.getStringExtra("connections") ?: error("Missing connections")
                        report.put("plex_network", PlexNetworkProbe.run(context.applicationContext, request, raw))
                        1
                    } else if (intent.action == "com.wapok.thru3d.DEBUG_DLNA") {
                        // Same discovery as the library menu; results go to logcat tag QuestDlna.
                        val app = context.applicationContext
                        Thread {
                            DlnaClient.log = { android.util.Log.i("QuestDlna", it) }
                            val lock = (app.getSystemService(android.content.Context.WIFI_SERVICE) as android.net.wifi.WifiManager)
                                .createMulticastLock("QuestDlnaDebug").apply { setReferenceCounted(false); acquire() }
                            try { DlnaClient.discover().forEach { android.util.Log.i("QuestDlna", "server ${it.json()}") } }
                            catch (error: Throwable) { android.util.Log.e("QuestDlna", "discover failed", error) }
                            finally { lock.release() }
                        }.start()
                        1
                    } else if (intent.action == "com.wapok.thru3d.DEBUG_DEPTH_BENCH") {
                        // 2D->3D model timing on the GPU; no player, no XR session needed.
                        DepthBenchmarkProbe.request(context.applicationContext, intent.getIntExtra("runs", 60))
                    } else if (intent.action == "com.wapok.thru3d.DEBUG_LOCAL_ACCESS") {
                        LocalAccessProbe.request(context.applicationContext, intent.getStringExtra("case") ?: "file_present")
                    } else if (intent.action == "com.wapok.thru3d.DEBUG_LOCAL_SELECTION") {
                        LocalSelectionProbe.request(context.applicationContext, intent.getStringExtra("case") ?: "unicode")
                    } else if (intent.action == "com.wapok.thru3d.DEBUG_MPV_DOLBY") {
                        MpvDolbyDiagnostics.request(context.applicationContext,
                            intent.getStringExtra("fixture") ?: "dovi_profile5.mkv",
                            intent.getBooleanExtra("direct", false), intent.getBooleanExtra("audio", false),
                            intent.getBooleanExtra("hardware", true), intent.getBooleanExtra("pixels_only", false))
                    } else if (intent.action == "com.wapok.thru3d.DEBUG_MPV_URI") {
                        MpvDiagnostics.requestExternal(context.applicationContext)
                    } else if (intent.action == "com.wapok.thru3d.DEBUG_MPV_SHARED") {
                        MpvSharedDiagnostics.request(context.applicationContext, intent.getBooleanExtra("hardware", true))
                    } else if (intent.action == "com.wapok.thru3d.DEBUG_MPV_MOTION") {
                        MpvMotionDiagnostics.request(context.applicationContext, intent.getStringExtra("profile") ?: "384x216",
                            intent.getBooleanExtra("ordered", false))
                    } else if (intent.action == "com.wapok.thru3d.DEBUG_MPV_AUDIO") {
                        MpvAudioDiagnostics.request(context.applicationContext, intent.getBooleanExtra("hardware", true))
                    } else if (intent.action in setOf("com.wapok.thru3d.DEBUG_MPV_CORE",
                            "com.wapok.thru3d.DEBUG_MPV_GPU", "com.wapok.thru3d.DEBUG_MPV_SOURCE")) {
                        val sourceFrame = intent.action!!.endsWith("_SOURCE")
                        MpvDiagnostics.request(context.applicationContext,
                            if (sourceFrame) "mp03_frame_identity" else intent.getStringExtra("fixture") ?: "c03_sbs_grid",
                            gpu = !intent.action!!.endsWith("_CORE"), hardware = intent.getBooleanExtra("hardware", false),
                            sourceFrame = sourceFrame)
                    } else {
                        val plugin = DiagnosticRequests.current() ?: error("Running Godot plugin unavailable")
                        when (intent.action) {
                        "com.wapok.thru3d.DEBUG_PLAYER_MPV" -> {
                            val operation = intent.getStringExtra("operation") ?: "open"
                            require(operation in setOf("open", "alpha", "depth", "playing", "seek", "hold_pixels", "observe", "stereo", "profile", "close", "pixels", "subtitle", "audio", "audio_delay", "narration", "narration_status", "display_quality", "sharpness", "cloud_accounts", "cloud_page_probe", "display_menu", "player_menu", "restart_app", "quit_app", "seek_policy_ui", "media_library_ui", "comic", "photo_open", "photo_step", "photo_depth", "photo_inspect", "photo_portrait", "alpha_blend_probe", "layer_flip", "layer_order", "hide_menus", "menu_layers", "menu_layer_filter", "menu_layer_holes", "menu_action", "menu_nav", "menu_bench", "perf_tune", "perf_sample", "stick", "pip_probe"))
                            val command = JSONObject().put("operation", operation).put("request_key", request)
                                .put("value", intent.getFloatExtra("value", 0f).toDouble())
                                .put("benchmark", intent.getBooleanExtra("benchmark", false))
                                .put("normal_fast", intent.getBooleanExtra("normal_fast", true))
                                .put("frame_cap", intent.getIntExtra("frame_cap", -1))
                                .put("roi", intent.getBooleanExtra("roi", true))
                                .put("zero_copy", intent.getBooleanExtra("zero_copy", true))
                                .put("borrow_color", intent.getBooleanExtra("borrow_color", true))
                                .put("direct_yuv", intent.getBooleanExtra("direct_yuv", true))
                                .put("normal_direct", intent.getBooleanExtra("normal_direct", true))
                                .put("layer", intent.getBooleanExtra("layer", true))
                                .put("enabled", intent.getBooleanExtra("enabled", false))
                                .put("position_ms", intent.getIntExtra("position_ms", 0))
                                .put("hold_seek_ms", intent.getIntExtra("hold_seek_ms", 0).coerceIn(0, 30000))
                                .put("profile", intent.getStringExtra("profile") ?: "384x216")
                                .put("target", intent.getStringExtra("target") ?: "")
                                .put("loop", intent.getBooleanExtra("loop", false))
                                // 2D->3D: a mono open with depth (stereo=false) or the "depth" operation.
                                .put("stereo", intent.getBooleanExtra("stereo", true))
                                .put("depth", intent.getBooleanExtra("depth", false))
                            // perf_tune / perf_sample: free-form JSON parameters (Debug only).
                            intent.getStringExtra("params")?.let { text -> JSONObject(text).let { extra -> extra.keys().forEach { key -> command.put(key, extra.get(key)) } } }
                            if (intent.hasExtra("seek_mode")) {
                                val mode = intent.getStringExtra("seek_mode")
                                require(mode in setOf("speed", "exact"))
                                command.put("seek_mode", mode)
                            }
                            if (operation == "photo_open") {
                                // Debug photo performance: an image folder and the file to open first.
                                val folder = intent.getStringExtra("folder").orEmpty()
                                require(folder.startsWith("/sdcard/") && !folder.contains(".."))
                                command.put("folder", folder).put("name", intent.getStringExtra("name").orEmpty())
                                    .put("layout", intent.getIntExtra("layout", -1)) // -1 keeps the viewer's layout
                            }
                            if (operation == "photo_inspect" && intent.hasExtra("x")) {
                                // Magnifier crop centre, picture UV top-first.
                                command.put("x", intent.getFloatExtra("x", 0.5f).coerceIn(0f, 1f).toDouble())
                                    .put("y", intent.getFloatExtra("y", 0.5f).coerceIn(0f, 1f).toDouble())
                            }
                            if (operation == "media_library_ui") {
                                val step = intent.getStringExtra("step") ?: "snapshot"
                                require(step in setOf("servers", "add", "delete", "home", "all", "genres", "tags", "folders", "scroll_end", "back", "retry", "snapshot", "reauth"))
                                val provider = intent.getStringExtra("provider") ?: "emby"
                                require(provider in setOf("emby", "jellyfin", "stash", "xbvr"))
                                command.put("step", step).put("provider", provider)
                            }
                            if (operation == "seek_policy_ui") {
                                val step = intent.getStringExtra("step")
                                require(step in setOf("global_speed", "global_exact", "bookmark_global", "bookmark_speed", "bookmark_exact", "bookmark_add", "bookmark_seek", "bookmark_delete", "timeline_drag",
                                    "recovery_setup", "recovery_open", "recovery_expand", "recovery_choose", "recovery_close", "recovery_hide", "recovery_reopen",
                                    "recovery_drag", "recovery_pull", "recovery_follow_pull", "recovery_recenter", "recovery_system_recenter", "recovery_snapshot", "recovery_finish"))
                                val marker = intent.getStringExtra("marker_id").orEmpty()
                                require(marker.isEmpty() || marker.matches(Regex("[a-f0-9]{32}")))
                                command.put("step", step).put("marker_id", marker)
                            }
                            if (operation == "depth" && intent.hasExtra("strength")) {
                                val strength = intent.getFloatExtra("strength", 1f)
                                require(strength.isFinite() && strength in 0f..4f)
                                command.put("strength", strength.toDouble())
                            }
                            if (operation == "open") {
                                val projection = intent.getIntExtra("projection", 0)
                                require(projection in 0..3)
                                command.put("projection", projection)
                                val network = intent.getStringExtra("uri")
                                if (network != null) {
                                    // Library network sources (DLNA http, SMB) through the same open path.
                                    require(android.net.Uri.parse(network).scheme in setOf("http", "https", "smb", "cloud", "file", "medialib"))
                                    if (network.startsWith("cloud://")) CloudPaths.path(network)
                                    command.put("uri", network).put("title", intent.getStringExtra("title") ?: "network")
                                } else {
                                val fixture = intent.getStringExtra("fixture") ?: "mp03_frame_identity"
                                require(fixture in setOf("mp03_frame_identity", "mp05_person_still", "mp06_text_subtitles", "mp07_motion_4k", "mp08_8k_low", "mp08_8k_high", "mp08_8k_high_30", "mp08_8k_long", "mp08_4k", "depth_2d"))
                                val directory = File(context.filesDir, "fixtures").apply { mkdirs() }
                                val target = File(directory, "$fixture.${if (fixture == "mp06_text_subtitles") "mkv" else "mp4"}")
                                if (fixture == "mp03_frame_identity") {
                                    context.assets.open("media/$fixture.mp4").use { input -> target.outputStream().use { input.copyTo(it) } }
                                } else {
                                    // Local test fixtures are pushed explicitly, outside APK assets.
                                    val limit = when {
                                        fixture == "mp08_8k_long" -> 1_500_000_000L // 4 min 8K, for windows of 60 s and more
                                        fixture.startsWith("mp08_") -> 500_000_000L
                                        fixture == "mp07_motion_4k" || fixture == "depth_2d" -> 50_000_000L
                                        else -> 20_000_000L
                                    }
                                    require(target.isFile && target.length() in 1..limit)
                                }
                                command.put("uri", "file://${target.absolutePath}").put("title", fixture)
                                }
                            }
                            if (operation == "subtitle" || operation == "audio") {
                                val track = intent.getIntExtra("track_id", 0)
                                require(track >= -1)
                                command.put("track_id", track)
                            }
                            if (operation == "audio_delay") command.put("seconds", intent.getFloatExtra("seconds", Float.NaN).toDouble())
                            if (operation == "narration") command.put("options", JSONObject(intent.getStringExtra("options") ?: "{}"))
                            plugin.requestMpvPlayerCommand(command.toString())
                        }
                        "com.wapok.thru3d.DEBUG_CANCEL_CONTROLLED" ->
                            plugin.cancelControlledProbe(intent.getIntExtra("id", -1))
                        "com.wapok.thru3d.DEBUG_RVM" -> plugin.request_rvm_profile_benchmark(
                            intent.getBooleanExtra("vulkan", false), intent.getStringExtra("profile") ?: "256x144")
                        "com.wapok.thru3d.DEBUG_CONTROLLED", "com.wapok.thru3d.DEBUG_RVM_VIDEO" -> {
                            val fixture = intent.getStringExtra("fixture") ?: "c03_sbs_grid"
                            require(fixture in listOf("c03_sbs_grid", "c04_alpha_f180", "c04_independent_alpha"))
                            val directory = File(context.filesDir, "fixtures").apply { mkdirs() }
                            val target = File(directory, "$fixture.mp4")
                            context.assets.open("media/$fixture.mp4").use { input -> target.outputStream().use { input.copyTo(it) } }
                            if (intent.action == "com.wapok.thru3d.DEBUG_RVM_VIDEO")
                                plugin.requestRvmVideoProbe("file://${target.absolutePath}", true,
                                    intent.getStringExtra("profile") ?: "256x144", intent.getBooleanExtra("vulkan", true))
                            else plugin.request_controlled_probe("file://${target.absolutePath}", 0, true,
                                intent.getStringExtra("profile") ?: "256x256")
                        }
                        else -> error("Unknown debug action")
                        }
                    }
                    report.put("state", if (id > 0) "accepted" else "rejected").put("id", id)
                } catch (error: Exception) { report.put("state", "error").put("message", error.message) }
                finally {
                    try {
                        val directory = File(context.filesDir, "diagnostics").apply { mkdirs() }
                        val temporary = File.createTempFile("request-", ".tmp", directory)
                        try {
                            temporary.writeText(report.toString())
                            check(temporary.renameTo(File(directory, "debug_request_$request.json")))
                        } finally { temporary.delete() }
                    } finally { pending.finish() }
                }
            }
        } catch (_: RejectedExecutionException) { pending.finish() }
    }
    /** A WebDAV test account through the same save path as the account panel, so a file can be
     * played via the production cloud route; "remove" deletes only an account this probe named. */
    private fun webDavTest(context: Context, intent: Intent, report: JSONObject): Int {
        CloudLibrary.start(context)
        val accounts = { (0 until CloudLibrary.accounts().length()).map { CloudLibrary.accounts().getJSONObject(it) } }
        val ours = { accounts().filter { it.getString("name") == WEBDAV_TEST_NAME && it.getString("provider") == CloudDrive.WEBDAV } }
        if (intent.getStringExtra("op") == "remove") {
            ours().forEach { CloudLibrary.remove(it.getString("id")) }
            report.put("removed", true)
            return 1
        }
        if (ours().isEmpty()) CloudLibrary.connectWebDav(WEBDAV_TEST_NAME, intent.getStringExtra("base") ?: error("Missing base"),
            intent.getStringExtra("username").orEmpty(), intent.getStringExtra("password").orEmpty())
        val account = ours().single()
        val file = intent.getStringExtra("file") ?: error("Missing file")
        // Cloud URIs name the account, then the path inside its mount.
        report.put("account_id", account.getString("id")).put("uri", CloudPaths.uri("/" + account.getString("id") + "/" + file))
        return 1
    }
    companion object {
        private const val WEBDAV_TEST_NAME = "Thru3D WebDAV test"
        private val worker = ThreadPoolExecutor(1, 1, 0, TimeUnit.MILLISECONDS, ArrayBlockingQueue(1),
            { task -> Thread(task, "QuestDebugRequest") }, ThreadPoolExecutor.AbortPolicy())
    }
}
