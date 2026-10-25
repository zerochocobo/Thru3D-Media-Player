package org.vrpassthroughplayer.plugin

internal object ComicOcrNative {
    fun supported()=NarrationNative.supported()
    @JvmStatic external fun create(directory: String): Long
    @JvmStatic external fun cancel(engine: Long, generation: Long)
    @JvmStatic external fun analyze(engine: Long,rgb: ByteArray,width: Int,height: Int,generation: Long,unrestricted: Boolean): ByteArray
    @JvmStatic external fun destroy(engine: Long)
}
