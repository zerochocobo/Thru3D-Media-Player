package org.vrpassthroughplayer.plugin

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.net.Uri
import android.os.Binder
import android.os.Bundle
import android.os.IBinder
import android.os.Process

/** A small dedicated process keeps the shell Binder available across VR activity restarts. */
class MiracastBrokerProvider : ContentProvider() {
    private var remote: IBinder? = null
    private var death: IBinder.DeathRecipient? = null
    override fun onCreate() = true

    @Synchronized override fun call(method: String, arg: String?, extras: Bundle?): Bundle {
        val uid = Binder.getCallingUid()
        when (method) {
            "attach" -> {
                // ContentProvider.call does not inherit query/update permission checks.
                check(uid == 2000) { "Shell activation required" }
                val next = extras?.getBinder("broker") ?: error("Missing broker")
                check(next.interfaceDescriptor == MiracastRadioClient.DESCRIPTOR) { "Unexpected broker interface" }
                if (remote === next && next.isBinderAlive) return Bundle()
                death?.let { old -> runCatching { remote?.unlinkToDeath(old, 0) } }
                val lost = IBinder.DeathRecipient { synchronized(this) { if (remote === next) { remote = null; death = null } } }
                next.linkToDeath(lost, 0)
                remote = next; death = lost
            }
            "get" -> check(uid == Process.myUid()) { "Receiver application required" }
            else -> error("Unknown broker method")
        }
        return Bundle().apply { remote?.takeIf { it.isBinderAlive }?.let { putBinder("broker", it) } }
    }

    override fun getType(uri: Uri): String? = null
    override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): Cursor? = null
    override fun insert(uri: Uri, values: ContentValues?): Uri? = throw UnsupportedOperationException()
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = throw UnsupportedOperationException()
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?): Int = throw UnsupportedOperationException()
}
