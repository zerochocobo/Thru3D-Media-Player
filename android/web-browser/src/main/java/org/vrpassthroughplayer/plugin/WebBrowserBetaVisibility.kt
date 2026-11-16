package org.vrpassthroughplayer.plugin

import org.json.JSONObject

/** UI-only state. An old window/document command cannot reveal a new page's controls. */
internal class WebBrowserBetaVisibility {
    private var ownerWindow = -1
    private var ownerNavigation = -1L
    private var hidden = true
    fun update(request: JSONObject, window: Int, tab: Int, navigation: Long): Boolean {
        if (request.optInt("window", -1) != window || request.optInt("tab", -1) != tab ||
            request.optLong("navigation", -1) != navigation || request.opt("hidden") !is Boolean) return false
        ownerWindow = window; ownerNavigation = navigation; hidden = request.getBoolean("hidden")
        return true
    }
    fun visible(window: Int, navigation: Long, fullscreen: Boolean): Boolean =
        ownerWindow == window && ownerNavigation == navigation && !hidden && !fullscreen
}
