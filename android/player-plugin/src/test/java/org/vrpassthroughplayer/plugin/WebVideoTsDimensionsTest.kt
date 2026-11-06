package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test

class WebVideoTsDimensionsTest {
    // Generated from a synthetic blue 704x396 frame by FFmpeg/libx264, not site media.
    private val sps = "6742c01eda02c0cfef011000000300100000030328f162ea".chunked(2).map { it.toInt(16).toByte() }.toByteArray()
    // Synthetic 864x486 blue Main10 frame, generated with FFmpeg/libx265.
    private val hevcSps = "42010102200000030090000003000003005aa006c201f1f336595952930bc05a020000030002000003003210".chunked(2).map { it.toInt(16).toByte() }.toByteArray()
    private fun packets(split: Boolean = false, pid: Int = 256, nal: ByteArray = sps): ByteArray {
        val data = ByteArray(188 * 3) { 0xff.toByte() }
        for (n in 0..2) { val p = n * 188; data[p] = 0x47; data[p + 1] = (pid shr 8).toByte(); data[p + 2] = pid.toByte(); data[p + 3] = (0x10 + n).toByte() }
        data[1] = (0x40 or (pid shr 8)).toByte()
        byteArrayOf(0,0,1,0xe0.toByte(),0,0,0x80.toByte(),0,0).copyInto(data,4)
        val payload = byteArrayOf(0,0,0,1) + nal + byteArrayOf(0,0,0,1,0x68)
        if (!split) payload.copyInto(data,13)
        else { val start = 178; payload.copyInto(data,start,0,188-start); payload.copyInto(data,192,188-start,payload.size) }
        return data
    }
    @Test fun parsesTheCroppedDimensionsFromTheSelectedVideoPid() {
        assertEquals(704 to 396, WebVideoTsDimensions.avc(packets(),256))
        assertEquals(704 to 396, WebVideoTsDimensions.avc(packets(split=true),256))
        assertNull(WebVideoTsDimensions.avc(packets(pid=257),256))
    }
    @Test fun rejectsScramblingTransportErrorsBrokenContinuityAndInvalidAdaptation() {
        for (mutate in listOf<(ByteArray)->Unit>(
            {it[3]=0xd0.toByte()}, {it[1]=(it[1].toInt() or 0x80).toByte()},
            {it[191]=0x15}, {it[3]=0x30;it[4]=0xff.toByte()}, {it[188]=0})) {
            val data=packets(split=true);mutate(data);assertNull(WebVideoTsDimensions.avc(data,256))
        }
        assertNull(WebVideoTsDimensions.avc(ByteArray(40),256))
    }
    @Test fun pmtSuppliesThePidBeforeTheExistingContainerProbeReportsDimensions() {
        val first=ByteArray(188){0xff.toByte()}
        byteArrayOf(0x47,0x50,0,0x10,0).copyInto(first)
        "02b0170001c10000e100f0001be100f0000fe101f00000000000".chunked(2).map{it.toInt(16).toByte()}.toByteArray().copyInto(first,5)
        val info=WebVideoContainer.transportStream(first+packets())!!
        assertEquals("avc1",info.video);assertEquals("mp4a.40.2",info.audio)
        assertEquals(704,info.width);assertEquals(396,info.height)
    }
    @Test fun hevcMain10SpsReportsCroppedDimensionsAcrossPackets() {
        assertEquals(864 to 486,WebVideoTsDimensions.hevc(packets(nal=hevcSps),256))
        assertEquals(864 to 486,WebVideoTsDimensions.hevc(packets(split=true,nal=hevcSps),256))
        assertNull(WebVideoTsDimensions.hevc(packets(pid=257,nal=hevcSps),256))
        assertNull(WebVideoTsDimensions.hevc(packets(nal=hevcSps.copyOf(4)),256))
        assertNull(WebVideoTsDimensions.hevc(packets(),256))
        assertNull(WebVideoTsDimensions.avc(packets(nal=hevcSps),256))
        val nonBase=hevcSps.copyOf();nonBase[1]=9
        assertNull(WebVideoTsDimensions.hevc(packets(nal=nonBase),256))
    }
    @Test fun hevcPmtUsesTheDeclaredVideoPidAndRetainsTransportValidation() {
        val pmt=ByteArray(188){0xff.toByte()}
        byteArrayOf(0x47,0x50,0,0x10,0).copyInto(pmt)
        "02b0170001c10000e100f00024e100f0000fe101f00000000000".chunked(2).map{it.toInt(16).toByte()}.toByteArray().copyInto(pmt,5)
        val info=WebVideoContainer.transportStream(pmt+packets(nal=hevcSps))!!
        assertEquals("hevc",info.video);assertEquals("mp4a.40.2",info.audio)
        assertEquals(864,info.width);assertEquals(486,info.height)
        assertEquals(0,WebVideoContainer.transportStream(pmt+packets(pid=257,nal=hevcSps))!!.width)
        val damaged=packets(split=true,nal=hevcSps);damaged[191]=0x15
        assertNull(WebVideoTsDimensions.hevc(damaged,256))
        val scrambled=packets(nal=hevcSps);scrambled[3]=0xd0.toByte()
        assertNull(WebVideoTsDimensions.hevc(scrambled,256))
    }
}
