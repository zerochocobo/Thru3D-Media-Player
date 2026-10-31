package org.vrpassthroughplayer.plugin

import java.io.File

/** One owner plus any in-flight worker leases; cancellation cannot unlink a worker's input. */
internal class PhotoSource(val file: File, val nativeStereo: Boolean = false) {
    @Volatile var animation: Boolean = false
    @Volatile var animationSnapshot: ((() -> Unit) -> File?)? = null
    fun effectSnapshot(check: ()->Unit): File? {
        if(!animation)return null
        return animationSnapshot?.invoke(check) ?: error("PHOTO_DECODE_FAILED")
    }
    private var references = 1
    private var discardDepthPending = false
    @Synchronized fun discardDepth() {
        discardDepthPending = true
        if (references == 1) clearDepth()
    }
    private fun clearDepth() {
        file.parentFile?.listFiles()?.filter {
            it.name in setOf("depth.bin", "depth.json") || it.name.startsWith("stereo-")
        }?.forEach { it.delete() }
        discardDepthPending = false
    }
    @Synchronized fun retain(): PhotoSource {
        check(references > 0)
        references++
        return this
    }
    @Synchronized fun release() {
        check(references > 0)
        if (--references == 0) file.parentFile?.deleteRecursively()
        else if (references == 1 && discardDepthPending) clearDepth()
    }
}
