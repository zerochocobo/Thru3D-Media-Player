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
    @Test fun noSystemVolumeNeverSuggestsMountedEntryOrEject() {
        assertEquals(UsbClaimPolicy.BUSY, UsbClaimPolicy.busyMessage(false, "Pico", "Pico"))
        assertEquals(UsbClaimPolicy.BUSY, UsbClaimPolicy.busyMessage(false, "Oculus", "oculus"))
    }
}
