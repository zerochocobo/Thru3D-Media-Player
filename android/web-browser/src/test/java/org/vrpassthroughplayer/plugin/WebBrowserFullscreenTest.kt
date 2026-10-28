package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test

class WebBrowserFullscreenTest {
    @Test fun aVideoMustActuallyEnterFullscreen() {
        val state = WebBrowserFullscreen()
        state.update(false, "frame:1"); assertFalse(state.active)
        state.update(true, ""); assertFalse(state.active); assertEquals(0, state.request)
        state.update(true, "frame:1"); assertTrue(state.active); assertTrue(state.matches(1))
    }
    @Test fun mediaUpdatesAndFailureReturnDoNotCreateAnotherAttempt() {
        val state = WebBrowserFullscreen()
        state.update(true, "frame:1")
        repeat(100) { state.update(true, "frame:1"); assertEquals(1, state.request) }
        state.update(false, ""); assertFalse(state.active); assertTrue(state.matches(1))
        state.update(true, "frame:1"); assertEquals(2, state.request); assertFalse(state.matches(1))
    }
    @Test fun anotherVideoOrDocumentInvalidatesThePreviousReturn() {
        val state = WebBrowserFullscreen()
        state.update(true, "frame:1"); state.update(true, "frame:2")
        assertFalse(state.matches(1)); assertTrue(state.matches(2))
        state.reset(); assertFalse(state.matches(2)); assertFalse(state.active)
        state.update(true, "frame:1"); assertTrue(state.request > 2)
    }
}
