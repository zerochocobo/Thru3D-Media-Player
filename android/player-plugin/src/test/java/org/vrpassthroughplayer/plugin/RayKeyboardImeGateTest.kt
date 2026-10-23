package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test

class RayKeyboardImeGateTest {
    @Test fun lastPanelRestoresSystemInputWithoutReleasingAnotherPanel() {
        var blocked = false
        val changes = mutableListOf<Boolean>()
        val gate = RayKeyboardImeGate({ blocked }, { blocked = it; changes.add(it) })
        val login = Any(); val browser = Any()
        gate.acquire(login); gate.acquire(login)
        assertTrue(blocked)
        assertEquals(listOf(true), changes)
        gate.acquire(browser); gate.release(login)
        assertTrue(blocked)
        gate.release(Any()); gate.release(login)
        assertTrue(blocked)
        gate.release(browser)
        assertFalse(blocked)
        assertEquals(listOf(true, true, false), changes)
    }

    @Test fun existingWindowPolicyAndLaterSearchArePreserved() {
        var blocked = true
        val gate = RayKeyboardImeGate({ blocked }, { blocked = it })
        val panel = Any()
        gate.acquire(panel); gate.release(panel)
        assertTrue(blocked)
        blocked = false // The host has since enabled system input for search.
        gate.acquire(panel)
        assertTrue(blocked)
        gate.release(panel)
        assertFalse(blocked)
        gate.release(panel) // Pause, detach and destroy can all release the same owner.
        assertFalse(blocked)
    }
}
