package org.vrpassthroughplayer.plugin

/** UI-thread ownership of the one native player's original live document. */
class WebBrowserPlaybackHold {
    data class Owner(val tab: Int, val navigation: Long, val origin: String, val token: Long) {
        fun valid() = tab > 0 && navigation >= 0 && origin.isNotEmpty() && token > 0
    }
    private var owner: Owner? = null
    fun retain(request: Owner, current: Owner, paused: Boolean): Boolean {
        if (!request.valid() || request != current || !paused) return false
        owner = request
        return true
    }
    fun protects(tab: Int, navigation: Long) = owner?.let { it.tab == tab && it.navigation == navigation } == true
    fun release(request: Owner): Boolean {
        if (owner != request) return false
        owner = null
        return true
    }
    fun invalidate(tab: Int) { if (owner?.tab == tab) owner = null }
}
