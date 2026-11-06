package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test

class WebBrowserPlaybackHoldTest {
    private val original = WebBrowserPlaybackHold.Owner(4, 7, "https://weibo.com/", 13)
    @Test fun onlyTheAcknowledgedCurrentDocumentCanBeRetained() {
        val hold = WebBrowserPlaybackHold()
        assertFalse(hold.retain(original, original, false))
        for (other in listOf(original.copy(tab = 5), original.copy(navigation = 8),
            original.copy(origin = "https://weibo.com/other"), original.copy(token = 14))) {
            assertFalse(hold.retain(original, other, true))
        }
        assertFalse(hold.protects(4, 7))
        assertTrue(hold.retain(original, original, true))
        assertTrue(hold.protects(4, 7))
        assertFalse(hold.protects(4, 8))
    }
    @Test fun lateReleaseCannotUnpinANewerTransferOnTheSameTimeline() {
        val hold = WebBrowserPlaybackHold()
        assertTrue(hold.retain(original, original, true))
        val next = original.copy(token = 14)
        assertTrue(hold.retain(next, next, true))
        assertFalse(hold.release(original))
        assertTrue(hold.protects(4, 7))
        assertTrue(hold.release(next))
        assertFalse(hold.protects(4, 7))
    }
    @Test fun documentLossInvalidatesItsHoldWithoutTouchingAnUnrelatedTab() {
        val hold = WebBrowserPlaybackHold()
        hold.retain(original, original, true)
        hold.invalidate(5)
        assertTrue(hold.protects(4, 7))
        hold.invalidate(4)
        assertFalse(hold.protects(4, 7))
        assertFalse(hold.release(original))
    }
    @Test fun malformedOrUnleasedOwnersNeverOccupyTheSessionBudget() {
        val hold = WebBrowserPlaybackHold()
        for (owner in listOf(original.copy(tab = 0), original.copy(navigation = -1),
            original.copy(origin = ""), original.copy(token = 0))) {
            assertFalse(hold.retain(owner, owner, true))
        }
        assertFalse(hold.protects(4, 7))
    }
}
