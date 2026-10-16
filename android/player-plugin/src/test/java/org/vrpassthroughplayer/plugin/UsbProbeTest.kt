package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.ByteOrder

class UsbProbeTest {
    private class Disk : UsbBlocks {
        override val sectorSize = 512
        override val sectorCount = 100_000L
        val data = mutableMapOf<Long, ByteArray>()
        val broken = mutableSetOf<Long>()
        fun at(lba: Long) = data.getOrPut(lba) { ByteArray(512) }
        fun partition(slot: Int, first: Long, filesystem: String) {
            val b = at(0); b[510] = 0x55; b[511] = 0xaa.toByte()
            val pos = 446 + 16 * slot; b[pos + 4] = 7
            ByteBuffer.wrap(b).order(ByteOrder.LITTLE_ENDIAN).putInt(pos + 8, first.toInt()).putInt(pos + 12, 10_000)
            filesystem.toByteArray().copyInto(at(first), if (filesystem.startsWith("FAT")) 82 else 3)
        }
        override fun readBlocks(lba: Long, data: ByteArray) {
            if (lba in broken) throw IOException("fixture read error")
            for (at in data.indices step 512) this.data[lba + at / 512]?.copyInto(data, at)
        }
    }
    @Test fun mixedFatAndExfatBothRemainVisibleAndFailuresAreNotEmptySuccesses() {
        val disk = Disk(); disk.partition(0, 2048, "EXFAT   "); disk.partition(1, 30_000, "FAT32   ")
        val result = UsbProbe.scan(0..0) { disk }
        assertEquals(listOf("exFAT", "FAT32"), result.found.map { it.partition.filesystem })
        assertEquals("", result.error()); assertEquals(2, result.json().getInt("partitions"))
        disk.broken.add(2048)
        val partial = UsbProbe.scan(0..0) { disk }
        assertEquals("FAT32", partial.found.single().partition.filesystem)
        assertEquals("partition_boot", partial.failures.single().stage)
        assertEquals("", partial.error())
        disk.broken.add(30_000)
        assertEquals("USB partition table could not be read", UsbProbe.scan(0..0) { disk }.error())
    }
    @Test fun capacityAndPartitionErrorsKeepTheirStagesAndOtherLunsContinue() {
        val disk = Disk(); disk.partition(0, 2048, "EXFAT   ")
        val result = UsbProbe.scan(0..1) { if (it == 0) throw IOException("fixture capacity") else disk }
        assertEquals(1, result.found.single().lun)
        assertEquals("capacity", result.failures.single().stage)
        assertEquals("", result.error())
        assertEquals("USB capacity could not be read", UsbProbe.scan(0..0) { throw IOException() }.error())
        assertEquals("USB partition table could not be read", UsbProbe.scan(0..0) { Disk() }.error())
        val empty = Disk(); empty.at(0)[510] = 0x55; empty.at(0)[511] = 0xaa.toByte()
        assertEquals("No supported USB partitions", UsbProbe.scan(0..0) { empty }.error())
    }
    @Test fun stopDuringDiscoveryNeverBecomesAnUnsupportedFilesystemError() {
        var alive = true
        try {
            UsbProbe.scan(0..1, { alive }) { alive = false; throw IOException("interrupted") }
            fail("Cancelled scan accepted")
        } catch (error: IOException) { assertEquals("USB access stopped", error.message) }
    }
}
