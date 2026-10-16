package org.vrpassthroughplayer.plugin

import java.io.IOException
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.zip.CRC32

/** Byte offsets and logical block addresses are deliberately different types at the boundary. */
internal interface UsbBlocks {
    val sectorSize: Int
    val sectorCount: Long
    fun readBlocks(lba: Long, data: ByteArray)
}

internal object UsbPartitions {
    data class Partition(val first: Long, val count: Long, val filesystem: String)
    private fun invalid(): Nothing = throw IOException("Invalid USB partition table")
    fun scan(disk: UsbBlocks, unreadable: (Long) -> Unit = {}): List<Partition> {
        require(disk.sectorSize in listOf(512, 1024, 2048, 4096) && disk.sectorCount > 0)
        fun block(lba: Long): ByteArray {
            if (lba !in 0 until disk.sectorCount) invalid()
            return ByteArray(disk.sectorSize).also { disk.readBlocks(lba, it) }
        }
        fun u32(b: ByteArray, at: Int) = ByteBuffer.wrap(b).order(ByteOrder.LITTLE_ENDIAN).getInt(at).toLong() and 0xffffffffL
        fun u64(b: ByteArray, at: Int) = ByteBuffer.wrap(b).order(ByteOrder.LITTLE_ENDIAN).getLong(at).also { if (it < 0) invalid() }
        fun type(b: ByteArray): String? = when {
            String(b, 3, 8, Charsets.US_ASCII) == "NTFS    " -> "NTFS"
            String(b, 3, 8, Charsets.US_ASCII) == "EXFAT   " -> "exFAT"
            String(b, 82, 8, Charsets.US_ASCII) == "FAT32   " || fat32Bpb(b) -> "FAT32"
            else -> null
        }
        val mbr = block(0)
        // A whole-disk filesystem has no partition table (common on thumb drives).
        type(mbr)?.let { return listOf(Partition(0, disk.sectorCount, it)) }
        if (mbr[510] != 0x55.toByte() || mbr[511] != 0xaa.toByte()) invalid()
        val ranges = mutableListOf<Pair<Long, Long>>()
        fun add(first: Long, count: Long) {
            if (first <= 0 || count <= 0 || first >= disk.sectorCount || count > disk.sectorCount - first) invalid()
            if (ranges.any { first < it.first + it.second && it.first < first + count }) invalid()
            ranges.add(first to count)
            if (ranges.size > 16384) invalid()
        }
        if ((0..3).any { (mbr[446 + it * 16 + 4].toInt() and 255) == 0xee }) {
            fun gpt(at: Long): List<Pair<Long, Long>> {
                val h = block(at)
                if (String(h, 0, 8, Charsets.US_ASCII) != "EFI PART") invalid()
                val size = u32(h, 12).toInt()
                if (size !in 92..disk.sectorSize || u32(h,8)!=0x10000L || u32(h,20)!=0L || u64(h,24) != at || u64(h,32) != if(at==1L) disk.sectorCount-1 else 1L) invalid()
                val expected = u32(h,16); h.fill(0,16,20)
                if (CRC32().apply { update(h,0,size) }.value != expected) invalid()
                val firstUsable=u64(h,40); val lastUsable=u64(h,48)
                if(firstUsable<2 || lastUsable<firstUsable || lastUsable>=disk.sectorCount) invalid()
                val table=u64(h,72); val count=u32(h,80); val entry=u32(h,84)
                if(count !in 1..16384 || entry !in 128..1024 || entry%128!=0L || count*entry>16*1024*1024) invalid()
                val bytes=count*entry; val sectors=(bytes+disk.sectorSize-1)/disk.sectorSize
                if(table<2 || table>=disk.sectorCount-1 || sectors>disk.sectorCount-1-table ||
                    (at==1L && table+sectors>firstUsable) || (at!=1L && table<=lastUsable)) invalid()
                val data=ByteArray((sectors*disk.sectorSize).toInt()); disk.readBlocks(table,data)
                if(CRC32().apply { update(data,0,bytes.toInt()) }.value!=u32(h,88)) invalid()
                val found=mutableListOf<Pair<Long,Long>>()
                repeat(count.toInt()) { index ->
                    val pos=(index*entry).toInt()
                    if((0 until 16).all { data[pos+it]==0.toByte() }) return@repeat
                    val start=u64(data,pos+32); val end=u64(data,pos+40)
                    if(start<firstUsable || end<start || end>lastUsable) invalid()
                    found.add(start to (end-start+1))
                }
                return found
            }
            // Read-only backup recovery never repairs or writes the primary GPT.
            val found=try { gpt(1) } catch (_: IOException) { gpt(disk.sectorCount-1) }
            for ((first,count) in found) add(first,count)
        } else {
            for(i in 0..3) {
                val at=446+i*16; val kind=mbr[at+4].toInt() and 255
                if(kind==0) continue
                val first=u32(mbr,at+8); val count=u32(mbr,at+12)
                if(kind in listOf(5,15,133)) {
                    if(first<=0 || count<=0 || first>=disk.sectorCount || count>disk.sectorCount-first) invalid()
                    var ebr=first; val seen=mutableSetOf<Long>()
                    while(true) {
                        if(ebr<first || ebr>=first+count || !seen.add(ebr) || seen.size>4096) invalid()
                        val b=block(ebr)
                        if(b[510]!=0x55.toByte() || b[511]!=0xaa.toByte()) invalid()
                        val relative=u32(b,454); val size=u32(b,458)
                        if((b[450].toInt() and 255)!=0) { if(relative<=0 || relative>=first+count-ebr || size>first+count-ebr-relative) invalid(); add(ebr+relative,size) }
                        val nextType=b[466].toInt() and 255
                        if(nextType==0) break
                        if(nextType !in listOf(5,15,133)) invalid()
                        val next=u32(b,470); if(next<=0 || next>=count) invalid(); ebr=first+next
                    }
                } else add(first,count)
            }
        }
        var failure: IOException? = null
        val result = ranges.sortedBy { it.first }.mapNotNull { (first,count) ->
            // One unreadable/unsupported filesystem must not hide another valid partition.
            try { type(block(first))?.let { Partition(first,count,it) } }
            catch (error: IOException) { unreadable(first); failure = error; null }
        }
        if (result.isEmpty() && failure != null) throw IOException("USB partition boot sector could not be read", failure)
        return result
    }

    private fun fat32Bpb(b:ByteArray):Boolean {
        val n=ByteBuffer.wrap(b).order(ByteOrder.LITTLE_ENDIAN)
        val sector=n.getShort(11).toInt() and 65535
        val cluster=b[13].toInt() and 255
        val reserved=n.getShort(14).toInt() and 65535
        val fats=b[16].toInt() and 255
        val total=n.getInt(32).toLong() and 0xffffffffL
        val fat=n.getInt(36).toLong() and 0xffffffffL
        if(sector !in listOf(512,1024,2048,4096) || cluster==0 || cluster and (cluster-1)!=0 || reserved==0 || fats !in 1..2 || n.getShort(17).toInt()!=0 || n.getShort(22).toInt()!=0 || fat==0L) return false
        val data=total-reserved-fats*fat
        return data>0 && data/cluster in 65525..0x0ffffff5 && b[510]==0x55.toByte() && b[511]==0xaa.toByte()
    }
}
