package org.vrpassthroughplayer.plugin

import java.nio.ByteBuffer

internal object TextDetectorNative {
    @JvmStatic external fun create(model: String): Long
    @JvmStatic external fun cancel(handle: Long,generation: Long)
    @JvmStatic external fun detect(handle: Long,rgb: ByteBuffer,width: Int,height: Int,generation: Long): String
    @JvmStatic external fun destroy(handle: Long)
}
