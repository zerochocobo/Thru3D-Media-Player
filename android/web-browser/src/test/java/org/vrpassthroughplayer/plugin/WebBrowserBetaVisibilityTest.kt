package org.vrpassthroughplayer.plugin

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class WebBrowserBetaVisibilityTest {
    private fun request(hidden: Boolean, window: Int = 1, tab: Int = 2, navigation: Long = 3) =
        JSONObject().put("window", window).put("tab", tab).put("navigation", navigation).put("hidden", hidden)
    @Test fun fullScreenAndUiHidingAreIndependentAndNewDocumentsWaitForTheirOwnState() {
        val state = WebBrowserBetaVisibility()
        assertFalse(state.visible(1, 3, false))
        assertTrue(state.update(request(false), 1, 2, 3))
        assertTrue(state.visible(1, 3, false)); assertFalse(state.visible(1, 3, true))
        assertTrue(state.update(request(true), 1, 2, 3))
        assertFalse(state.visible(1, 3, false))
        assertTrue(state.update(request(false), 1, 2, 3))
        assertFalse(state.visible(1, 4, false)); assertFalse(state.visible(2, 3, false))
    }
    @Test fun staleOrMalformedCommandsCannotRevealAnotherWindowOrTab() {
        val state = WebBrowserBetaVisibility()
        for (bad in listOf(request(false, window = 2), request(false, tab = 7), request(false, navigation = 2), request(false).put("hidden", "false"))) {
            assertFalse(state.update(bad, 1, 2, 3))
            assertFalse(state.visible(1, 3, false))
        }
        val peer = WebBrowserBetaVisibility()
        state.update(request(false), 1, 2, 3)
        peer.update(request(true, window = 2, tab = 4), 2, 4, 3)
        assertTrue(state.visible(1, 3, false)); assertFalse(peer.visible(2, 3, false))
    }
}
