package org.vrpassthroughplayer.plugin

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.mozilla.geckoview.GeckoSession

class WebBrowserSessionStateTest {
    private val first = "https://www.douyin.com/video/7693568065300931761"
    private val second = "https://www.douyin.com/video/7687219948607696891"
    private fun state(index: Int, vararg urls: String): GeckoSession.SessionState =
        requireNotNull(GeckoSession.SessionState.fromString(JSONObject().put("history", JSONObject()
            .put("index", index).put("entries", JSONArray(urls.map { JSONObject().put("url", it) }))).toString()))

    @Test fun staleSpaSnapshotMustNotRestoreTheVideoBeforeTheSwitch() {
        val beforeSwitch = state(1, first)
        assertTrue(WebBrowserSessionState.matches(beforeSwitch, first))
        assertFalse(WebBrowserSessionState.matches(beforeSwitch, second))
        val afterSwitch = state(2, first, second)
        assertTrue(WebBrowserSessionState.matches(afterSwitch, second))
        assertFalse(WebBrowserSessionState.matches(afterSwitch, first))
    }

    @Test fun backHistoryRestoresItsActiveEntryAndKeepsExactQueryAndFragment() {
        val detail = "http://192.168.1.2:8096/web/index.html#!/item?id=42"
        assertTrue(WebBrowserSessionState.matches(state(1, first, second), first))
        assertTrue(WebBrowserSessionState.matches(state(2, first, detail), detail))
        assertFalse(WebBrowserSessionState.matches(state(1, detail), detail.substringBefore('#')))
        assertFalse(WebBrowserSessionState.matches(state(1, second + "?modal_id=123"), second))
    }

    @Test fun missingOrIncompleteSnapshotLoadsTheKnownCurrentLocation() {
        assertFalse(WebBrowserSessionState.matches(null, second))
        assertFalse(WebBrowserSessionState.matches(state(0, first), second))
        assertFalse(WebBrowserSessionState.matches(state(2, first), second))
        assertFalse(WebBrowserSessionState.matches(state(1), second))
    }
}
