package org.vrpassthroughplayer.plugin

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Handler
import android.os.Looper
import android.os.PowerManager

/** A user-started, bounded LAN session may continue after the headset display sleeps. */
class WebBookmarkService : Service() {
    companion object {
        private const val CHANNEL = "bookmark_share"
        private const val TIMEOUT = 30 * 60 * 1000L
        private class Lease(val title: String, val stop: () -> Unit)
        @Volatile private var lease: Lease? = null
        internal fun begin(context: Context, title: String, stop: () -> Unit) {
            lease = Lease(title, stop)
            try { context.startForegroundService(Intent(context, WebBookmarkService::class.java)) }
            catch (error: Exception) { lease = null; throw error }
        }
        internal fun end(context: Context) {
            lease = null
            context.stopService(Intent(context, WebBookmarkService::class.java))
        }
    }
    private var owner: Lease? = null
    private var cpu: PowerManager.WakeLock? = null
    private var wifi: WifiManager.WifiLock? = null
    private val handler = Handler(Looper.getMainLooper())
    private val expiry = Runnable { finish() }
    override fun onBind(intent: Intent?) = null
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val current = lease
        if (current == null) { stopSelf(startId); return START_NOT_STICKY }
        owner = current
        try {
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(NotificationChannel(CHANNEL, current.title, NotificationManager.IMPORTANCE_LOW))
            val notification = Notification.Builder(this, CHANNEL).setSmallIcon(android.R.drawable.ic_menu_share)
                .setContentTitle("Thru3D").setContentText(current.title).setOngoing(true).build()
            startForeground(8791, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
            if (cpu == null) cpu = getSystemService(PowerManager::class.java).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "Thru3D:Bookmarks").apply {
                setReferenceCounted(false); acquire(TIMEOUT)
            }
            @Suppress("DEPRECATION")
            if (wifi == null) wifi = (applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager)
                .createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "Thru3D:Bookmarks").apply { setReferenceCounted(false); acquire() }
            handler.removeCallbacks(expiry); handler.postDelayed(expiry, TIMEOUT)
        } catch (_: Exception) { finish() }
        return START_NOT_STICKY
    }
    private fun finish() {
        val current = owner
        if (current != null && lease === current) { lease = null; current.stop() }
        stopSelf()
    }
    override fun onTaskRemoved(rootIntent: Intent?) { finish() }
    override fun onDestroy() {
        handler.removeCallbacks(expiry)
        runCatching { if (cpu?.isHeld == true) cpu?.release() }; cpu = null
        runCatching { if (wifi?.isHeld == true) wifi?.release() }; wifi = null
        val current = owner; owner = null
        if (current != null && lease === current) { lease = null; current.stop() }
        super.onDestroy()
    }
}
