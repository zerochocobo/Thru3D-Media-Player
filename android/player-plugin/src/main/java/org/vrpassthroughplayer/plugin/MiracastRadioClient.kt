package org.vrpassthroughplayer.plugin

import android.content.Context
import android.net.Uri
import android.os.Binder
import android.os.IBinder
import android.os.Parcel
import org.json.JSONObject

/** Only a shell-authenticated provider can supply this Binder; the service checks UID and signer. */
internal class MiracastRadioClient(context: Context) : AutoCloseable {
    companion object { const val DESCRIPTOR = "org.vrpassthroughplayer.miracast.Radio.v1" }
    private val lease = Binder()
    private val remote: IBinder = context.contentResolver.call(Uri.parse("content://${context.packageName}.miracast"), "get", null, null)
        ?.getBinder("broker") ?: error("Miracast broker unavailable")
    init { check(remote.interfaceDescriptor == DESCRIPTOR) { "Unexpected broker interface" } }

    fun request(command: String, available: Boolean): JSONObject {
        val data = Parcel.obtain(); val reply = Parcel.obtain()
        try {
            data.writeInterfaceToken(DESCRIPTOR); data.writeStrongBinder(lease)
            data.writeString(JSONObject().put("command", command).put("available", available).toString())
            check(remote.transact(IBinder.FIRST_CALL_TRANSACTION, data, reply, 0)) { "Broker transaction unavailable" }
            reply.readException()
            val response = reply.readString() ?: error("Missing broker response")
            check(response.length <= 8192) { "Broker response limit" }
            return JSONObject(response)
        } finally { reply.recycle(); data.recycle() }
    }
    override fun close() { runCatching { request("disable", false) } }
}
