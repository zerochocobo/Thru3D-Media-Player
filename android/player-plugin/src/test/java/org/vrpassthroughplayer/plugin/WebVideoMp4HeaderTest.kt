package org.vrpassthroughplayer.plugin

import java.nio.ByteBuffer
import org.junit.Assert.*
import org.junit.Test

class WebVideoMp4HeaderTest {
    private fun box(type: String, data: ByteArray) = ByteBuffer.allocate(8 + data.size).putInt(8 + data.size).put(type.toByteArray()).put(data).array()
    private val ftyp = box("ftyp", "isom0000isom0000".toByteArray())
    private val moov = box("moov", ByteArray(24))
    private fun inspect(mediaBytes: Long = 16L * 1024 * 1024, tail: ByteArray = moov): Pair<ByteArray, List<Pair<Long, Int>>> {
        val prefix = ftyp + ByteBuffer.allocate(16).putInt(1).put("mdat".toByteArray()).putLong(mediaBytes).array()
        val start = ftyp.size + mediaBytes
        val reads = ArrayList<Pair<Long, Int>>()
        val reader = object : Mp4InterleavePolicy.Reader {
            override val size = start + tail.size
            override fun read(offset: Long, length: Int): ByteArray {
                reads.add(offset to length)
                check(offset >= start && offset + length <= size) { "Probe attempted to read media payload" }
                return tail.copyOfRange((offset - start).toInt(), (offset - start).toInt() + length)
            }
        }
        return WebVideoMp4Header.inspect(reader, prefix) to reads
    }

    @Test fun tailMetadataSkipsMediaAndLeavesTheOriginalFileLayoutUntouched() {
        val (header, reads) = inspect()
        assertArrayEquals(ftyp + moov, header)
        assertTrue(reads.isNotEmpty())
        assertTrue(reads.sumOf { it.second } <= 16 + moov.size)
    }

    @Test fun large64BitMediaOffsetsDoNotAllocateOrReadTheGap() {
        val (header, reads) = inspect(1L shl 40)
        assertArrayEquals(ftyp + moov, header)
        assertTrue(reads.all { it.first > Int.MAX_VALUE })
    }

    @Test fun ordinaryLongMovieSampleTablesCanExceedTheInitialPayloadPrefixBudget() {
        val large=box("moov",ByteArray(4_814_955-8))
        val (header,reads)=inspect(tail=large)
        assertArrayEquals(ftyp+large,header)
        assertEquals(SphericalVideoMetadata.PREFIX_LIMIT,2*1024*1024)
        assertTrue(reads.sumOf{it.second}<=16+large.size)
    }

    @Test fun frontMetadataCrossingThePrefixIsReadAsOneExactMetadataRange() {
        val large=box("moov",ByteArray(4_814_955-8));val media=box("mdat",ByteArray(32))
        val file=ftyp+large+media;val reads=ArrayList<Pair<Long,Int>>()
        val reader=object:Mp4InterleavePolicy.Reader {
            override val size=file.size.toLong()
            override fun read(offset:Long,length:Int):ByteArray {
                reads.add(offset to length)
                assertTrue(offset+length<=ftyp.size+large.size || length<=16)
                return file.copyOfRange(offset.toInt(),offset.toInt()+length)
            }
        }
        assertArrayEquals(ftyp+large,WebVideoMp4Header.inspect(reader,file.copyOf(SphericalVideoMetadata.PREFIX_LIMIT)))
        assertTrue(reads.contains(ftyp.size.toLong() to large.size))
    }

    @Test fun protectionFragmentsDuplicateMoovAndUnboundedMetadataStayRejected() {
        for (tail in listOf(moov + box("pssh", ByteArray(16)), moov + box("moof", ByteArray(8)), moov + moov,
            box("moov",ByteArray(WebVideoMp4Header.METADATA_LIMIT-7)))) {
            assertThrows(Exception::class.java) { inspect(tail = tail) }
        }
    }

    @Test fun malformedBoxSizesCannotEscapeTheVerifiedFileBounds() {
        val truncated = ByteBuffer.allocate(16).putInt(1).put("moov".toByteArray()).putLong(Long.MAX_VALUE).array()
        assertThrows(IllegalArgumentException::class.java) { inspect(tail = truncated) }
    }
}
