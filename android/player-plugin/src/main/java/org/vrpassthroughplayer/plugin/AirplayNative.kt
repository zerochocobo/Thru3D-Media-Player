package org.vrpassthroughplayer.plugin

/** Optional until the pinned native dependency has been prepared; never disable working DLNA. */
internal object AirplayNative {
    private val load = runCatching { System.loadLibrary("quest_airplay") }
    val available = load.isSuccess
    val loadFailure: Throwable? get() = load.exceptionOrNull()
    interface Listener {
        fun event(kind: String, value: String)
        fun packet(video: Boolean, bytes: ByteArray, ns: Long, codec: Int)
    }
    external fun start(listener: Listener, name: String, address: ByteArray, keyFile: String, requirePassword: Boolean): Long
    external fun stop(handle: Long)
}
