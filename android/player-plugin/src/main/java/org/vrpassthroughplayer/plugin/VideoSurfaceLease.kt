package org.vrpassthroughplayer.plugin

/** The decoder's asynchronous close owns its Surface until native MPV acknowledges release.
 * Claim and destroy both run on the render thread; a replacement never borrows that ownership. */
internal class VideoSurfaceLease<T : Any> {
    var owner: T? = null
        private set

    enum class Output { WAIT, LAYER, EYE_BUFFER, SLOTS_FULL, SURFACE_TIMEOUT }

    /** Both resources share the open deadline. Only the compositor output needs this lease. A Surface
     * still held at the deadline fails the open: in the field (5YKQKKN4) such a source had wedged the
     * whole process, and eye-buffer opens beside it showed no frame either. */
    fun selectOutput(candidate: T, wantsLayer: Boolean, slotsClosing: Boolean, expired: Boolean): Output {
        if (slotsClosing) return if (expired) Output.SLOTS_FULL else Output.WAIT
        if (!wantsLayer) return Output.EYE_BUFFER
        if (acquire(candidate)) return Output.LAYER
        return if (expired) Output.SURFACE_TIMEOUT else Output.WAIT
    }

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
