package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test

class UsbClaimPolicyTest {
    @Test fun picoSystemMountGuidesToEjectAndRetry() {
        assertEquals(UsbClaimPolicy.BUSY_EJECT, UsbClaimPolicy.busyMessage(true, "Pico", "Pico"))
        assertEquals(UsbClaimPolicy.BUSY_EJECT, UsbClaimPolicy.busyMessage(true, "unknown", "PICO"))
    }
    @Test fun otherHeadsetsKeepTheMountedEntryGuidance() {
        assertEquals(UsbClaimPolicy.BUSY_MOUNTED, UsbClaimPolicy.busyMessage(true, "Oculus", "oculus"))
        assertEquals(UsbClaimPolicy.BUSY_MOUNTED, UsbClaimPolicy.busyMessage(true, null, null))
    }
    @Test fun forcedTakeoverNeedsAnExplicitRequestOnPico() {
        assertTrue(UsbClaimPolicy.userTakeover(true, "Pico", "Pico"))
        assertFalse(UsbClaimPolicy.userTakeover(false, "Pico", "Pico"))
        assertFalse(UsbClaimPolicy.userTakeover(true, "Oculus", "oculus"))
        assertFalse(UsbClaimPolicy.userTakeover(true, null, null))
    }
    @Test fun noSystemVolumeNeverSuggestsMountedEntryOrEject() {
        assertEquals(UsbClaimPolicy.BUSY, UsbClaimPolicy.busyMessage(false, "Pico", "Pico"))
        assertEquals(UsbClaimPolicy.BUSY, UsbClaimPolicy.busyMessage(false, "Oculus", "oculus"))
    }
    @Test fun systemMountedDiskHidesTheManagedEntryOutsidePico() {
        assertFalse(UsbClaimPolicy.listManaged(true, false, "Oculus", "oculus"))
        assertFalse(UsbClaimPolicy.listManaged(true, false, null, null))
        assertTrue(UsbClaimPolicy.listManaged(false, false, "Oculus", "oculus"))
        assertTrue(UsbClaimPolicy.listManaged(true, true, "Oculus", "oculus"))
        assertTrue(UsbClaimPolicy.listManaged(true, false, "Pico", "Pico"))
    }
}
