package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test

class UsbSubtitleIdentityTest {
    @Test fun volumeIdentitySurvivesMutableFilesystemFlagsAndChangesWithTheActualVolume() {
        for ((filesystem, offset) in listOf("FAT32" to 67, "exFAT" to 100, "NTFS" to 72)) {
            val part = UsbPartitions.Partition(2048, 100000, filesystem)
            val boot = ByteArray(512).also { it[offset] = 12 }
            val original = UsbSubtitleIdentity.partition(part, 512, boot)
            assertEquals(64, original.length)
            boot[106] = 1; boot[112] = 75 // exFAT dirty flag and allocation percentage are not identities.
            assertEquals(original, UsbSubtitleIdentity.partition(part, 512, boot))
            boot[offset] = 13
            assertNotEquals(original, UsbSubtitleIdentity.partition(part, 512, boot))
            assertNotEquals(original, UsbSubtitleIdentity.partition(part.copy(first = 4096), 512, boot))
        }
    }
}
