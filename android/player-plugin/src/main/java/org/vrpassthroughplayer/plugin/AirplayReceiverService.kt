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

/** Same connected-device lifetime as WebBookmarkService, owned only by the receive switch.
 * The listener stays available while the headset sleeps; CPU/Wi-Fi locks cover active senders only. */
class AirplayReceiverService : Service() {
    companion object {
        private const val CHANNEL = "airplay_receiver"
        private class Lease(val stop: () -> Unit) { @Volatile var active = false }
        @Volatile private var lease: Lease? = null
        internal fun begin(context: Context, stop: () -> Unit) {
            val next = Lease(stop); lease = next
            try { context.startForegroundService(Intent(context, AirplayReceiverService::class.java)) }
            catch (failure: Exception) { if (lease === next) lease = null; throw failure }
        }
        internal fun active(context: Context, value: Boolean) {
            val current = lease ?: return
            if (current.active == value) return
            current.active = value
            runCatching { context.startService(Intent(context, AirplayReceiverService::class.java)) }
        }
        internal fun end(context: Context) { lease = null; context.stopService(Intent(context, AirplayReceiverService::class.java)) }
    }
    private var owner: Lease? = null
    private var cpu: PowerManager.WakeLock? = null
    private var wifi: WifiManager.WifiLock? = null
    private val handler = Handler(Looper.getMainLooper())
    private val renew = object : Runnable {
        override fun run() {
            if (owner !== lease || owner?.active != true) return
            if (runCatching { cpu?.acquire(4 * 60 * 1000L) }.isFailure) { finish(); return }
            handler.postDelayed(this, 3 * 60 * 1000L)
        }
    }
    override fun onBind(intent: Intent?) = null
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val current = lease
        if (current == null) { stopSelf(startId); return START_NOT_STICKY }
        owner = current
        try {
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(NotificationChannel(CHANNEL, "Cast reception", NotificationManager.IMPORTANCE_LOW))
            val notification = Notification.Builder(this, CHANNEL).setSmallIcon(android.R.drawable.ic_menu_share)
                .setContentTitle("Thru3D").setContentText("Cast reception").setOngoing(true).build()
            startForeground(8792, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
            handler.removeCallbacks(renew)
            if (current.active) {
                if (cpu == null) cpu = getSystemService(PowerManager::class.java).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "Thru3D:Airplay").apply { setReferenceCounted(false) }
                renew.run()
                @Suppress("DEPRECATION")
                if (wifi == null) wifi = (applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager)
                    .createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "Thru3D:Airplay").apply { setReferenceCounted(false); acquire() }
            } else releaseLocks()
        } catch (_: Exception) { finish() }
        return START_NOT_STICKY
    }
    private fun releaseLocks() {
        handler.removeCallbacks(renew)
        runCatching { if (cpu?.isHeld == true) cpu?.release() }; cpu = null
        runCatching { if (wifi?.isHeld == true) wifi?.release() }; wifi = null
    }
    private fun finish() {
        val current = owner
        if (current != null && lease === current) { lease = null; current.stop() }
        stopSelf()
    }
    override fun onTaskRemoved(rootIntent: Intent?) { finish() }
    override fun onDestroy() {
        releaseLocks()
        val current = owner; owner = null
        if (current != null && lease === current) { lease = null; current.stop() }
        super.onDestroy()
    }
}
