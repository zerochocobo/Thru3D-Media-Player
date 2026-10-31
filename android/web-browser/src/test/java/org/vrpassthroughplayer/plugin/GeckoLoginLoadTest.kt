package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test

class GeckoLoginLoadTest {
    private val target = "https://pan.quark.cn/open/v1/oauth/authorize?fixture=only"

    @Test fun firstOpenWaitsForTheActiveSizedDisplay() {
        val state = GeckoLoginLoad()
        val events = mutableListOf<String>()
        state.open(target)
        state.ready(false, false, events::add) { events.add("reload") }
        assertTrue(events.isEmpty())
        state.ready(true, false, events::add) { events.add("reload") }
        assertEquals(listOf(target), events)
        repeat(4) { state.ready(true, false, events::add) { events.add("reload") } }
        assertEquals(listOf(target), events)
    }

    @Test fun displayMayArriveBeforeTheAuthorizationAddress() {
        val state = GeckoLoginLoad()
        val events = mutableListOf<String>()
        state.ready(true, false, events::add) { events.add("reload") }
        assertTrue(events.isEmpty())
        state.open(target)
        state.ready(true, false, events::add) { events.add("reload") }
        assertEquals(listOf(target), events)
    }

    @Test fun pauseAndDisplayLossDoNotLoseTheInitialRequestOrReplayAForm() {
        val state = GeckoLoginLoad()
        val events = mutableListOf<String>()
        state.open(target)
        state.ready(true, true, events::add) { events.add("reload") }
        state.ready(false, false, events::add) { events.add("reload") }
        assertTrue(events.isEmpty())
        state.ready(true, false, events::add) { events.add("reload") }
        state.ready(false, true, events::add) { events.add("reload") }
        state.ready(true, false, events::add) { events.add("reload") }
        assertEquals(listOf(target), events)
    }

    @Test fun modeChangeReloadsOnceAfterTheReplacementDisplay() {
        val state = GeckoLoginLoad()
        val events = mutableListOf<String>()
        state.open(target)
        state.ready(true, false, events::add) { events.add("reload") }
        state.resize()
        state.ready(false, false, events::add) { events.add("reload") }
        state.ready(true, true, events::add) { events.add("reload") }
        assertEquals(listOf(target), events)
        repeat(3) { state.ready(true, false, events::add) { events.add("reload") } }
        assertEquals(listOf(target, "reload"), events)
    }

    @Test fun modeChangeBeforeFirstDisplayLoadsTheOriginalUrlOnlyOnce() {
        val state = GeckoLoginLoad()
        val events = mutableListOf<String>()
        state.open(target); state.resize()
        repeat(2) { state.ready(true, false, events::add) { events.add("reload") } }
        assertEquals(listOf(target), events)
    }

    @Test fun closingRetiresPendingLoadsAndResizes() {
        val state = GeckoLoginLoad()
        val events = mutableListOf<String>()
        state.open(target); state.resize(); state.close()
        state.open(target); state.resize()
        state.ready(true, false, events::add) { events.add("reload") }
        assertTrue(events.isEmpty())
        assertFalse(state.allowPlaceholderRequest())
    }

    @Test fun initialBlankIsInternalAndNeverMarksAProviderDocumentStarted() {
        val state = GeckoLoginLoad()
        state.open(target)
        assertTrue(state.placeholder("about:blank"))
        assertTrue(state.allowPlaceholderRequest())
        state.started("about:blank")
        assertTrue(state.allowPlaceholderRequest())
        state.started(target)
        assertFalse(state.allowPlaceholderRequest())
        // Late initial-document observer callbacks are still ignored, not sent to OAuth policy.
        assertTrue(state.placeholder("about:blank"))
        for (url in listOf(null, target, "about:config", "about:blank#x", "data:text/html,", "javascript:void(0)")) {
            assertFalse(state.placeholder(url))
        }
    }
}
