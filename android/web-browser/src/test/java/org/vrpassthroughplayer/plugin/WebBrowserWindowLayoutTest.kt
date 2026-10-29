package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test

class WebBrowserWindowLayoutTest {
    private val layout = WebBrowserWindowLayout(listOf(
        WebBrowserWindowLayout.Tab(10, 1), WebBrowserWindowLayout.Tab(11, 1, 10),
        WebBrowserWindowLayout.Tab(20, 2), WebBrowserWindowLayout.Tab(30, 3)),
        mapOf(1 to 11, 2 to 20, 3 to 30), 1)

    @Test fun closingAnyWindowLeavesOtherWindowsAndSelectionsIntact() {
        for (window in 1..3) {
            val closed = layout.tabs.filter { it.window == window }.map { it.id }.toSet()
            val next = layout.close(closed)
            assertEquals(layout.tabs.filterNot { it.id in closed }, next.tabs)
            assertEquals(layout.selected - window, next.selected)
            assertTrue(next.focused in next.selected)
        }
    }

    @Test fun closingAllWindowsInAnyOrderNeverCreatesAPhantomBlankTab() {
        for (order in listOf(listOf(1, 2, 3), listOf(3, 2, 1), listOf(2, 1, 3))) {
            var next = layout
            order.forEach { window -> next = next.close(next.tabs.filter { it.window == window }.map { it.id }.toSet()) }
            assertTrue(next.tabs.isEmpty())
            assertTrue(next.selected.isEmpty())
            assertEquals(1, next.focused)
        }
    }

    @Test fun closingPopupReturnsToItsOpenerAndClosingBackgroundTabKeepsSelection() {
        assertEquals(10, layout.close(setOf(11)).selected[1])
        assertEquals(11, layout.close(setOf(10)).selected[1])
    }

    @Test fun mergeAppendsAllSourceTabsWithoutReplacingTheTargetPage() {
        val next = layout.move(setOf(10, 11), 3)
        assertEquals(listOf(30, 10, 11), next.tabs.filter { it.window == 3 }.map { it.id })
        assertEquals(mapOf(2 to 20, 3 to 30), next.selected)
        assertEquals(3, next.focused)
        assertEquals(10, next.tabs.last().opener)
        val reverse = layout.move(setOf(30), 1)
        assertEquals(11, reverse.selected[1])
        assertEquals(listOf(10, 11, 30), reverse.tabs.filter { it.window == 1 }.map { it.id })
    }

    @Test fun fourthWindowCanReceiveASelectedTabWithoutRenumberingTheOtherWindows() {
        val next = layout.move(setOf(11), 4)
        assertEquals(mapOf(1 to 10, 2 to 20, 3 to 30, 4 to 11), next.selected)
        assertEquals(4, next.focused)
        assertEquals(10, next.tabs.last().opener)
        val movedLast = next.move(setOf(30), 4)
        assertEquals(mapOf(1 to 10, 2 to 20, 4 to 11), movedLast.selected)
        assertEquals(4, movedLast.tabs.first { it.id == 30 }.window)
    }
}
