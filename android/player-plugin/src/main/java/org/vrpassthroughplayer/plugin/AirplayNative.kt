package org.vrpassthroughplayer.plugin

/** Optional until the pinned native dependency has been prepared; never disable working DLNA. */
internal object AirplayNative {
    val available = runCatching { System.loadLibrary("quest_airplay"); true }.getOrDefault(false)
    interface Listener {
        fun event(kind: String, value: String)
        fun packet(video: Boolean, bytes: ByteArray, ns: Long, codec: Int)
    }
    external fun start(listener: Listener, name: String, address: ByteArray, keyFile: String): Long
    external fun stop(handle: Long)
}
