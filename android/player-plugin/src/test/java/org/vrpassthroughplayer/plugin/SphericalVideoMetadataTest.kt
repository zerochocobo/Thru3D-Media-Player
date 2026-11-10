package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test
import java.io.File

class SphericalVideoMetadataTest {
    private fun fixture(name: String) = javaClass.getResourceAsStream("/spherical/$name")!!.use { it.readBytes() }

    @Test fun readsRealYouTubeRepresentationsWithoutVideoPayload() {
        val expected = listOf(
            Triple("youtube-vr180-avc.mp4", 1, 2), Triple("youtube-vr180-av1.mp4", 1, 2),
            Triple("youtube-vr180-vp9.webm", 1, 2), Triple("youtube-eac-vp9.webm", 3, 0),
            Triple("youtube-360-tb.mp4", 3, 1))
        val output = File("build/test-projection").apply { mkdirs() }
        for ((file, geometry, stereo) in expected) {
            val actual = SphericalVideoMetadata.parse(fixture(file))!!
            assertEquals(file, geometry, actual.getInt("geometry"))
            assertEquals(file, stereo, actual.getInt("stereo_mode"))
            assertEquals(if (file.contains("360-tb")) "equirectangular" else "mesh", actual.getString("kind"))
            File(output, "$file.json").writeText(actual.toString())
        }
    }

    @Test fun rejectsCorruptedCompressedMeshInsteadOfDisplayingItAsEquirectangular() {
        val data = fixture("youtube-vr180-avc.mp4")
        val at = data.toString(Charsets.ISO_8859_1).indexOf("dfl8")
        assertTrue(at > 0); data[at+8] = (data[at+8].toInt() xor 1).toByte()
        assertThrows(IllegalArgumentException::class.java) { SphericalVideoMetadata.parse(data) }
    }

    @Test fun rejectsOversizedInputAndDoesNotGuessFromUnknownBytes() {
        assertThrows(IllegalArgumentException::class.java) { SphericalVideoMetadata.parse(ByteArray(SphericalVideoMetadata.PREFIX_LIMIT+1)) }
        assertNull(SphericalVideoMetadata.parse("VR180 EAC SBS".toByteArray()))
        assertNull(SphericalVideoMetadata.parse(byteArrayOf()))
    }

    @Test fun sparseLargeMoovKeepsProjectionWithoutExpandingTheGeneralPrefixBudget() {
        val original=fixture("youtube-vr180-avc.mp4")
        fun size(at:Int)=java.nio.ByteBuffer.wrap(original,at,4).int
        val ftyp=original.copyOfRange(0,size(0))
        val at=original.toString(Charsets.ISO_8859_1).indexOf("moov")-4
        assertTrue(at>=ftyp.size)
        val free=java.nio.ByteBuffer.allocate(3*1024*1024).putInt(3*1024*1024).put("free".toByteArray()).array()
        val content=original.copyOfRange(at+8,at+size(at))+free
        val moov=java.nio.ByteBuffer.allocate(content.size+8).putInt(content.size+8).put("moov".toByteArray()).put(content).array()
        val header=ftyp+moov
        val before=SphericalVideoMetadata.parse(original)!!
        val after=SphericalVideoMetadata.parseSparseMp4Header(header)!!
        for(key in listOf("kind","geometry","stereo_mode"))assertEquals(before.get(key),after.get(key))
        assertThrows(IllegalArgumentException::class.java){SphericalVideoMetadata.parse(header)}
        assertThrows(IllegalArgumentException::class.java){SphericalVideoMetadata.parseSparseMp4Header(header+byteArrayOf(0))}
        assertThrows(IllegalArgumentException::class.java){SphericalVideoMetadata.parseSparseMp4Header(ByteArray(WebVideoMp4Header.METADATA_LIMIT+4097))}
    }

    @Test fun headerProbeStopsAtMediaWithoutLosingProjection() {
        for (file in listOf("youtube-vr180-avc.mp4", "youtube-vr180-av1.mp4", "youtube-360-tb.mp4",
            "youtube-vr180-vp9.webm", "youtube-eac-vp9.webm")) {
            val header = fixture(file)
            // Follow the header with a media fragment/cluster, as a DASH stream does.
            val media = if (file.endsWith(".mp4")) byteArrayOf(0, 0, 0x10, 0, 'm'.code.toByte(), 'o'.code.toByte(), 'o'.code.toByte(), 'f'.code.toByte())
                else byteArrayOf(0x1f, 0x43, 0xb6.toByte(), 0x75, 0x01, 0xff.toByte(), 0xff.toByte(), 0xff.toByte(), 0xff.toByte(), 0xff.toByte(), 0xff.toByte(), 0xff.toByte())
            val buffer = ByteArray(SphericalVideoMetadata.PREFIX_LIMIT)
            (header + media).copyInto(buffer)
            val stop = (0..header.size + media.size).first { SphericalVideoMetadata.headerComplete(buffer, it) }
            assertTrue(file, stop <= header.size + media.size)
            assertEquals(file, SphericalVideoMetadata.parse(header).toString(), SphericalVideoMetadata.parse(buffer.copyOf(stop)).toString())
        }
        val unknown = ByteArray(SphericalVideoMetadata.PREFIX_LIMIT)
        "VR180 EAC SBS".toByteArray().copyInto(unknown)
        assertFalse(SphericalVideoMetadata.headerComplete(unknown, 13))
        // A progressive file whose moov follows a large mdat cannot be read from the prefix.
        val progressive = ByteArray(64)
        byteArrayOf(0, 0, 0, 16, 'f'.code.toByte(), 't'.code.toByte(), 'y'.code.toByte(), 'p'.code.toByte()).copyInto(progressive)
        byteArrayOf(0, 0x40, 0, 0, 'm'.code.toByte(), 'd'.code.toByte(), 'a'.code.toByte(), 't'.code.toByte()).copyInto(progressive, 16)
        assertTrue(SphericalVideoMetadata.headerComplete(progressive, 24))
    }

    @Test fun truncatedMetadataNeverProducesPartialMeshes() {
        val data = fixture("youtube-vr180-avc.mp4")
        for (n in listOf(8, 20, data.size/2, data.size-1)) {
            assertNull(SphericalVideoMetadata.parse(data.copyOf(n)))
        }
    }
}
