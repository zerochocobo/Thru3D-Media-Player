package org.vrpassthroughplayer.plugin

import android.app.Activity
import android.content.ClipData
import android.content.Intent
import android.os.Bundle
import android.os.SystemClock
import org.json.JSONArray
import org.json.JSONObject

/** A synchronous NoDisplay handoff, never a second engine or a playback-history entry. */
class ExternalPlaybackProbeActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        try {
            if (!BuildConfig.INCLUDE_DIAGNOSTIC_MODELS || savedInstanceState != null ||
                intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0) return
            val app = applicationContext
            val reader = ExternalPlaybackIntentReader(intent)
            // Emby treats any result as "player closed" and a missing position as 0. Hand back the
            // position it sent so this probe cannot rewind the server's resume point. This runs
            // before any evidence is built, so a metadata failure cannot skip it.
            val result = Intent()
            when (val position = runCatching { reader.position() }.getOrNull()) {
                is Int -> result.putExtra("position", position)
                is Long -> result.putExtra("extra_position", position)
            }
            setResult(RESULT_CANCELED, result)
            val fields = reader.metadata().put("called_for_result", callingActivity != null)
            fields.put("result_position_returned", result.extras?.isEmpty == false)
            val request = try {
                val roots = listOfNotNull(app.dataDir, app.filesDir, app.cacheDir, app.noBackupFilesDir, app.codeCacheDir,
                    app.createDeviceProtectedStorageContext().dataDir) +
                    app.getExternalFilesDirs(null).filterNotNull() + app.externalCacheDirs.filterNotNull()
                val parsed = ExternalPlaybackRequest.parse(intent.action, intent.dataString, reader.title(), intent.type,
                    reader.headers().accepted, roots)
                // The source may not use our own providers to expose private/cache files.
                require(parsed.scheme != "content" || app.packageManager.resolveContentProvider(intent.data!!.authority!!, 0)
                    ?.applicationInfo?.uid != app.applicationInfo.uid) { "OWN_PROVIDER_DENIED" }
                parsed
            } catch (failure: Exception) {
                // Only fixed parser codes: never a Throwable, URI, Bundle or arbitrary exception message.
                fields.put("reject_code", failure.message?.takeIf { it in rejectCodes } ?: "REQUEST_REJECTED")
                null
            }
            fields.put("handoff_elapsed_ms", SystemClock.elapsedRealtime())
            // A rejected request still opens the host so its contract evidence is written once privacy is known.
            val id = if (request != null) ExternalPlaybackProbe.offer(app, request, fields)
                else ExternalPlaybackProbe.reject(app, fields)
            val launch = Intent(Intent.ACTION_MAIN)
                .setClassName(packageName, "com.godot.game.GodotAppLauncher")
                .addCategory("org.khronos.openxr.intent.category.IMMERSIVE_HMD")
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            if (request?.scheme == "content" && intent.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION != 0) {
                launch.clipData = ClipData.newRawUri("video", intent.data)
                launch.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            // Never copy the source Bundle, command_line_params, new_launch_requested or task flags.
            startActivity(launch)
            ExternalPlaybackProbe.start(app, id)
        } catch (_: Exception) {
            android.util.Log.i("ExternalPlaybackProbe", "HANDOFF_FAILED")
        } finally {
            finish() // NoDisplay must finish before onResume completes, including every error path.
        }
    }

    private companion object {
        val rejectCodes = setOf("UNSUPPORTED_ACTION", "INVALID_URI", "UNSUPPORTED_SCHEME", "URI_CREDENTIALS_NOT_SUPPORTED",
            "INVALID_FILE_URI", "PRIVATE_FILE_DENIED", "UNSUPPORTED_HEADER", "INVALID_HEADER", "DUPLICATE_HEADER",
            "OWN_PROVIDER_DENIED")
    }
}
