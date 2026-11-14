package org.vrpassthroughplayer.plugin

import android.app.Activity
import android.content.ClipData
import android.content.Intent
import android.os.Bundle
import android.provider.OpenableColumns

/** NoDisplay only receives and hands off synchronously. It never hosts Godot or replays getIntent(). */
class ExternalPlaybackActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        try {
            if (savedInstanceState != null || intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0) return
            val reader = ExternalPlaybackIntentReader(intent)
            val result = Intent()
            when (val position = reader.position()) {
                is Int -> result.putExtra("position", position)
                is Long -> result.putExtra("extra_position", position)
            }
            setResult(RESULT_CANCELED, result)
            val app = applicationContext
            val roots = listOfNotNull(app.dataDir, app.createDeviceProtectedStorageContext().dataDir) +
                app.getExternalFilesDirs(null).filterNotNull() + app.externalCacheDirs.filterNotNull()
            val headers = reader.headers().accepted
            var request = ExternalPlaybackRequest.parse(intent.action, intent.dataString, reader.title(), intent.type,
                headers, roots)
            require(request.scheme != "content" || app.packageManager.resolveContentProvider(intent.data!!.authority!!, 0)
                ?.applicationInfo?.uid != app.applicationInfo.uid)
            // Queried only after the caller's provider has been validated, under the intent's own read grant.
            val title = ExternalPlaybackContract.title(request.title, request.scheme) {
                contentResolver.query(intent.data!!, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
                    if (it.moveToFirst()) it.getString(0) else null
                }
            }
            if (title != request.title) request = ExternalPlaybackRequest.parse(intent.action, intent.dataString, title,
                intent.type, headers, roots)
            val receipt = ExternalPlaybackPending.offer(request, reader.startMs())
            try {
                val launch = Intent(Intent.ACTION_MAIN)
                    .setClassName(packageName, "com.godot.game.GodotAppLauncher")
                    .addCategory("org.khronos.openxr.intent.category.IMMERSIVE_HMD")
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                if (request.scheme == "content" && intent.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION != 0) {
                    launch.clipData = ClipData.newRawUri("video", intent.data)
                    launch.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
                // Never forward external extras, engine controls or source task flags.
                startActivity(launch)
            } catch (failure: Exception) {
                ExternalPlaybackPending.discard(receipt)
                throw failure
            }
        } catch (_: Exception) {
            // URI/header/provider errors can contain secrets. Show only a fixed, translated message.
            android.widget.Toast.makeText(this, getString(R.string.external_video_unavailable), android.widget.Toast.LENGTH_SHORT).show()
        } finally {
            finish() // Theme.NoDisplay must finish before onResume completes.
        }
    }
}

/** Process memory only: engine/Activity recreation cannot resurrect a consumed external request. */
internal object ExternalPlaybackPending {
    private val inbox = ExternalPlaybackInbox()
    private var start = 0
    @Synchronized fun offer(request: ExternalPlaybackRequest, startMs: Int): Long {
        start = startMs
        return inbox.offer(request)
    }
    @Synchronized fun claim(): Pair<ExternalPlaybackInbox.Delivery, Int>? = inbox.claimLatest()?.let { it to start }
    @Synchronized fun discard(id: Long) = inbox.discard(id)
}
