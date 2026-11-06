package org.vrpassthroughplayer.plugin
import org.junit.Assert.*
import org.junit.Test

class WebBrowserMatteLeaseTest {
    @Test fun navigationDropsOldMaskAndReleasesItsWorkSlot() {
        val gate=WebBrowserMatteLease(1); gate.move(1)
        val old=gate.begin(1,1,100)!!; gate.move(2)
        assertNull(gate.begin(2,2,101)); assertFalse(gate.finish(old))
        val next=gate.begin(2,2,101)!!; assertTrue(gate.finish(next)); assertFalse(gate.finish(old))
    }
    @Test fun anotherWindowCannotCompleteTheHeldColor() {
        val a=WebBrowserMatteLease(1); val b=WebBrowserMatteLease(2)
        a.move(1); b.move(1)
        val first=a.begin(1,4,12)!!; val second=b.begin(1,4,12)!!
        assertFalse(a.finish(second)); assertTrue(a.finish(first)); assertTrue(b.finish(second))
    }
    @Test fun duplicateOrWrongColorDoesNotPublish() {
        val gate=WebBrowserMatteLease(3); gate.move(1)
        val ticket=gate.begin(1,4,22)!!
        assertFalse(gate.finish(ticket.copy(color=23))); assertTrue(gate.finish(ticket))
        assertFalse(gate.finish(ticket)); assertNull(gate.begin(1,3,24)); assertNull(gate.begin(1,4,24))
    }
    @Test fun closeRejectsInFlightAndFutureResults() {
        val gate=WebBrowserMatteLease(1); gate.move(1)
        val ticket=gate.begin(1,1,7)!!; gate.close()
        assertFalse(gate.finish(ticket)); assertNull(gate.begin(1,2,8))
    }
}
