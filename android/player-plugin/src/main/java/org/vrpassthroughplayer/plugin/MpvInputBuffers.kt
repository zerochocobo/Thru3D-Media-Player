package org.vrpassthroughplayer.plugin

import java.nio.ByteBuffer
import java.nio.ByteOrder

/** GL-thread pool for model inputs. A decoder HardwareBuffer does not imply that RVM can share it. */
internal class MpvInputBuffers(width: Int, height: Int) {
    private val bytes = width * height * 3 * 4
    private val free = ArrayDeque<Pair<ByteBuffer, ByteBuffer>>()

    fun acquire(sharedAlpha: Boolean): Pair<ByteBuffer, ByteBuffer> {
        if (sharedAlpha) return EMPTY
        return free.removeFirstOrNull() ?: (plane() to plane())
    }

    private fun plane() = ByteBuffer.allocateDirect(bytes).order(ByteOrder.LITTLE_ENDIAN)

    /** Return only after the frame lease is released; inputs still used by inference cannot be reused. */
    fun release(left: ByteBuffer, right: ByteBuffer) {
        if (left.capacity() > 0) free.addLast(left to right)
    }

    fun clear() = free.clear()

    companion object {
        val EMPTY: Pair<ByteBuffer, ByteBuffer> = ByteBuffer.allocateDirect(0) to ByteBuffer.allocateDirect(0)
    }
}
