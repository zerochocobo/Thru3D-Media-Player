package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test

class WebBrowserKeyboardSessionTest {
    @Test fun delayedKeystrokeCannotCrossInputsOnTheSamePage() {
        val session = WebBrowserKeyboardSession()
        val search = session.open(1, 10, 3)
        assertTrue(session.accepts(search))
        val password = session.open(1, 10, 3)
        assertFalse(session.accepts(search))
        assertTrue(session.accepts(password))
        assertNotEquals(search.epoch, password.epoch)
    }
    @Test fun tabMovesNavigationAndTeardownRevokeQueuedCommands() {
        val session = WebBrowserKeyboardSession()
        val first = session.open(1, 10, 3)
        val navigated = session.open(1, 10, 4)
        assertFalse(session.accepts(first))
        val moved = session.open(2, 10, 4)
        assertFalse(session.accepts(navigated))
        assertFalse(session.accepts(moved.copy(tab = 11)))
        session.close()
        assertFalse(session.accepts(moved))
        val reopened = session.open(2, 10, 4)
        assertFalse(session.accepts(moved))
        assertTrue(session.accepts(reopened))
    }
}
