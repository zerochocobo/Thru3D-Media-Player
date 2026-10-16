package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.zip.CRC32

class UsbPartitionsTest {
    private class Disk(override val sectorSize:Int=512,override val sectorCount:Long=100000):UsbBlocks {
        val sectors=mutableMapOf<Long,ByteArray>()
        var reads=0
        override fun readBlocks(lba:Long,data:ByteArray) {
            require(lba>=0 && data.size%sectorSize==0 && data.size/sectorSize<=sectorCount-lba)
            reads++
            for(at in data.indices step sectorSize) sectors[lba+at/sectorSize]?.copyInto(data,at)
        }
        fun sector(lba:Long)=sectors.getOrPut(lba) { ByteArray(sectorSize) }
        fun boot(lba:Long,fs:String) { fs.toByteArray().copyInto(sector(lba),if(fs.startsWith("FAT"))82 else 3) }
        fun signature(lba:Long=0) { sector(lba)[510]=0x55; sector(lba)[511]=0xaa.toByte() }
        fun mbr(slot:Int,type:Int,start:Long,count:Long,lba:Long=0) { signature(lba); val b=sector(lba); val at=446+slot*16; b[at+4]=type.toByte(); le(b).putInt(at+8,start.toInt()).putInt(at+12,count.toInt()) }
    }
    companion object { private fun le(b:ByteArray)=ByteBuffer.wrap(b).order(ByteOrder.LITTLE_ENDIAN) }
    private fun fails(block:()->Unit) { try { block(); fail("Invalid disk accepted") } catch(_:java.io.IOException) { } }
    @Test fun mixedMbrAndUnsignedAddressing() {
        val d=Disk(sectorCount=6000000000)
        d.mbr(0,0xc,2048,900); d.boot(2048,"FAT32   ")
        d.mbr(2,7,3000000000,900); d.boot(3000000000,"EXFAT   ")
        d.mbr(3,7,5000000000L and 0xffffffffL,900) // still a valid unsigned 32-bit entry, sorted independently
        d.boot(5000000000L and 0xffffffffL,"NTFS    ")
        val p=UsbPartitions.scan(d)
        assertEquals(setOf("FAT32","exFAT","NTFS"),p.map { it.filesystem }.toSet())
        assertEquals(3000000000L,p.last().first)
    }
    @Test fun mbrLogicalPartitionsAndCycleRejection() {
        val d=Disk(); d.mbr(0,15,100,9000)
        d.mbr(0,7,1,500,100); d.mbr(1,15,1000,7000,100); d.boot(101,"EXFAT   ")
        d.mbr(0,7,1,500,1100); d.boot(1101,"NTFS    ")
        assertEquals(listOf(101L,1101L),UsbPartitions.scan(d).map { it.first })
        d.mbr(1,15,1000,7000,1100)
        fails { UsbPartitions.scan(d) }
    }
    private fun gpt(sector:Int=512):Disk {
        val d=Disk(sectorSize=sector,sectorCount=10000)
        d.mbr(0,0xee,1,9999)
        val table=ByteArray(sector)
        // Slot zero unused; the used type GUID intentionally starts with zero.
        table[129]=1; le(table).putLong(128+32,100).putLong(128+40,899)
        d.sectors[8]=table; d.sectors[9990]=table.copyOf(); d.boot(100,"EXFAT   ")
        fun header(at:Long,other:Long,entries:Long) {
            val b=d.sector(at); "EFI PART".toByteArray().copyInto(b)
            le(b).putInt(8,0x10000).putInt(12,92).putLong(24,at).putLong(32,other).putLong(40,20).putLong(48,9980)
                .putLong(72,entries).putInt(80,4).putInt(84,128).putInt(88,CRC32().apply { update(table,0,512) }.value.toInt())
            le(b).putInt(16,CRC32().apply { update(b,0,92) }.value.toInt())
        }
        header(1,9999,8); header(9999,1,9990)
        return d
    }
    @Test fun gptHolesCustomTableLocationInclusiveLengthAnd4kSectors() {
        for(sector in listOf(512,4096)) {
            val p=UsbPartitions.scan(gpt(sector)).single()
            assertEquals(100L,p.first); assertEquals(800L,p.count); assertEquals("exFAT",p.filesystem)
        }
    }
    @Test fun corruptPrimaryUsesValidatedBackupWithoutWriting() {
        val d=gpt(); d.sector(1)[16]=0
        assertEquals(100L,UsbPartitions.scan(d).single().first)
        d.sector(9999)[16]=0
        fails { UsbPartitions.scan(d) }
    }
    @Test fun dualGptExfatAndFat32RemainSeparateAt512And4096Bytes() {
        for(sector in listOf(512,4096)) {
            val d=gpt(sector)
            for(table in listOf(8L,9990L)) {
                val b=d.sector(table); b[384]=1
                le(b).putLong(384+32,2000).putLong(384+40,2999)
            }
            d.boot(2000,"FAT32   ")
            val crc=CRC32().apply { update(d.sector(8),0,512) }.value.toInt()
            for(at in listOf(1L,9999L)) {
                val b=d.sector(at); le(b).putInt(88,crc).putInt(16,0)
                le(b).putInt(16,CRC32().apply { update(b,0,92) }.value.toInt())
            }
            val parts=UsbPartitions.scan(d)
            assertEquals(listOf("exFAT","FAT32"),parts.map { it.filesystem })
            assertEquals(listOf(100L,2000L),parts.map { it.first })
        }
    }
    @Test fun invalidGptTableChecksumAndOutOfBoundsRejected() {
        val d=gpt(); d.sector(8)[129]=2; d.sector(9990)[129]=2
        fails { UsbPartitions.scan(d) }
        val m=Disk(); m.mbr(0,7,99999,200)
        fails { UsbPartitions.scan(m) }
    }
    @Test fun overlappingPrimaryAndLogicalDataRejected() {
        val d=Disk(); d.mbr(0,7,100,1000); d.boot(100,"NTFS    "); d.mbr(1,7,500,1000)
        fails { UsbPartitions.scan(d) }
    }
    @Test fun noPartitionTableAndUnsupportedPartitionIsolation() {
        val d=Disk(); d.boot(0,"FAT32   ")
        assertEquals(0L,UsbPartitions.scan(d).single().first)
        val mixed=Disk(); mixed.mbr(0,0x83,100,1000); mixed.mbr(1,7,3000,1000); mixed.boot(3000,"NTFS    ")
        assertEquals(3000L,UsbPartitions.scan(mixed).single().first)
    }
    @Test fun fat32GeometryDoesNotRequireInformationalTypeLabel() {
        val d=Disk(sectorCount=200000); val b=d.sector(0); d.signature()
        le(b).putShort(11,512).putShort(14,32).putInt(32,200000).putInt(36,1600)
        b[13]=1; b[16]=2
        assertEquals("FAT32",UsbPartitions.scan(d).single().filesystem)
    }
    @Test fun cachedPartitionReaderClipsToPartitionAndStopsCachedReads() {
        val d=Disk(); d.sector(100)[0]=17; d.sector(101)[0]=18
        var live=true
        val r=UsbStorage.PartitionReader(d,UsbPartitions.Partition(100,200,"FAT32")) { live }
        val a=ByteArray(520); assertEquals(520,r.read(0,a)); assertEquals(17,a[0].toInt()); assertEquals(18,a[512].toInt())
        val reads=d.reads; r.read(7,ByteArray(10)); assertEquals(reads,d.reads)
        live=false; fails { r.read(0,ByteArray(10)) }
        live=true
        try { r.read(r.length,ByteArray(1)); fail("Partition overread") } catch(_:IllegalArgumentException) { }
    }
    @Test fun scsiCapacityAndReadCommandsKeep64BitAddresses() {
        fun cap10(last:Int,sector:Int)=ByteBuffer.allocate(8).putInt(last).putInt(sector).array()
        assertEquals(512 to 2147483649L,UsbScsi.capacity(cap10(0x80000000.toInt(),512)) { error("unnecessary READ CAPACITY16") })
        assertEquals(4096 to 9000000001L,UsbScsi.capacity(cap10(-1,512)) { ByteBuffer.allocate(32).putLong(9000000000L).putInt(4096).array() })
        fails { UsbScsi.capacity(cap10(-1,512)) { ByteBuffer.allocate(32).putLong(-1).putInt(512).array() } }
        val last10=UsbScsi.read(0xffffffffL,1)
        assertEquals(10,last10.size); assertEquals(0x28,last10[0].toInt()); assertEquals(-1,ByteBuffer.wrap(last10).getInt(2))
        val cross=UsbScsi.read(0xffffffffL,2)
        assertEquals(16,cross.size); assertEquals(0x88,cross[0].toInt() and 255); assertEquals(0xffffffffL,ByteBuffer.wrap(cross).getLong(2)); assertEquals(2,ByteBuffer.wrap(cross).getInt(10))
        val large=UsbScsi.read(9000000000,128)
        assertEquals(9000000000L,ByteBuffer.wrap(large).getLong(2))
    }
}
