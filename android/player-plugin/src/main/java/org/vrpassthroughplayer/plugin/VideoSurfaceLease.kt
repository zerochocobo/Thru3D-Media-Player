package org.vrpassthroughplayer.plugin

/** The decoder's asynchronous close owns its Surface until native MPV acknowledges release.
 * Claim and destroy both run on the render thread; a replacement never borrows that ownership. */
internal class VideoSurfaceLease<T : Any> {
    private var owner: T? = null

    fun acquire(candidate: T): Boolean {
        if (owner != null && owner !== candidate) return false
        owner = candidate
        return true
    }

    fun release(candidate: T, destroy: () -> Unit): Boolean {
        if (owner !== candidate) return false
        destroy()
        owner = null
        return true
    }
}
