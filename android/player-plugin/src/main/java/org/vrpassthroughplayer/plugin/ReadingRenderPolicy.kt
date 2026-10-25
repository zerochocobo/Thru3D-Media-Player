package org.vrpassthroughplayer.plugin

/** Original-header gate, before any native decoding or generated stereo allocation. */
internal object ReadingRenderPolicy {
    fun accepts(width: Int, height: Int): Boolean = width in 1..7679 && height in 1..7679 &&
        width.toLong() * height <= 12L * 1024 * 1024
}
