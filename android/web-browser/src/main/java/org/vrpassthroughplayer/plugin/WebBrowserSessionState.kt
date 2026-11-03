package org.vrpassthroughplayer.plugin

import org.mozilla.geckoview.GeckoSession

/** A pending Gecko state notification can still describe the page before a SPA switch. */
internal object WebBrowserSessionState {
    fun matches(state: GeckoSession.SessionState?, currentUrl: String): Boolean = state != null &&
        runCatching { state[state.currentIndex].uri == currentUrl }.getOrDefault(false)
}
