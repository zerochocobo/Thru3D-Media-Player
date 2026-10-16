package org.vrpassthroughplayer.plugin

import java.io.ByteArrayOutputStream
import java.io.DataOutputStream
import java.io.File
import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.json.JSONObject

class HeifPhotoInfoTest {
    private fun bytes(write: DataOutputStream.() -> Unit): ByteArray = ByteArrayOutputStream().also {
        DataOutputStream(it).use(write)
    }.toByteArray()
    private fun box(type: String, body: ByteArray) = bytes { writeInt(body.size + 8); writeBytes(type); write(body) }
    private fun full(type: String, body: ByteArray, flags: Int = 0) = box(type, bytes { writeInt(flags); write(body) })
    private fun fixture(stereo: Boolean = true, eyes: List<Int> = listOf(20,10), wide: Boolean = false, rotate: Boolean = false, crop: Boolean = false, camera: ByteArray? = null): ByteArray {
        val ids = listOf(99,10,20,77) // primary, right, left and an auxiliary image deliberately out of eye order.
        val infos = ids.map { item -> full("infe", bytes {
            if (wide) writeInt(item) else writeShort(item)
            writeShort(0); writeBytes("hvc1"); writeByte(0)
        }, (if (wide) 3 else 2) shl 24 or if (item == 99) 0 else 1) }.reduce { a,b -> a+b }
        val size = full("ispe", bytes { writeInt(640); writeInt(480) })
        val rotation = box("irot", byteArrayOf(if (rotate) 1 else 0))
        val uuid = box("uuid", "de22508536cb436587432f8705e7c78a".chunked(2).map { it.toInt(16).toByte() }.toByteArray() + bytes { writeInt(200) })
        val aperture = box("clap", bytes { writeInt(620); writeInt(1); writeInt(450); writeInt(1); writeInt(0); writeInt(1); writeInt(0); writeInt(1) })
        val ipma = full("ipma", bytes {
            writeInt(5)
            for (item in ids + 100) {
                if (wide) writeInt(item) else writeShort(item)
                writeByte(if (item == 100) (if (camera != null) 2 else 1) else if (crop) 3 else 2)
                if (item == 100) { writeByte(3); if (camera != null) writeByte(if (crop) 5 else 4) }
                else { writeByte(0x81); writeByte(2); if (crop) writeByte(4) }
            }
        }, if (wide) 1 shl 24 else 0)
        val grpl = if (stereo) box("grpl", full("ster", bytes {
            writeInt(100); writeInt(eyes.size); for (eye in eyes) writeInt(eye)
        })) else byteArrayOf()
        val primary = full("pitm", bytes { if (wide) writeInt(99) else writeShort(99) }, if (wide) 1 shl 24 else 0)
        return box("ftyp", "heic".toByteArray() + ByteArray(4) + "mif1heic".toByteArray()) +
            full("meta", primary + full("iinf", bytes { writeShort(ids.size); write(infos) }) +
                box("iprp", box("ipco", size+rotation+uuid+(if (crop) aperture else byteArrayOf())+(camera ?: byteArrayOf())) + ipma) + grpl) + box("mdat", byteArrayOf(1,2,3,4))
    }
    private fun camera(uuid: Boolean = true, fx: Double = .5, fy: Double? = null, cx: Double = .5, version: Int = 0, skew: Int = 0): ByteArray {
        val payload = bytes {
            writeInt(version shl 24 or 0x1000 or if (fy == null) 0 else 1)
            writeInt((fx * 65536).toInt()); writeInt((cx * 65536).toInt()); writeInt(32768)
            if (fy != null) { writeInt((fy * 65536).toInt()); writeInt(skew) }
        }
        return if (!uuid) box("cmin", payload) else box("uuid",
            "22cc04c7d6d94e079d904eb6ecbaf3a3".chunked(2).map { it.toInt(16).toByte() }.toByteArray() + payload)
    }
    private fun withFile(data: ByteArray, check: (File) -> Unit) {
        val directory = Files.createTempDirectory("thru3d-heif").toFile()
        try { val file=File(directory,"source.heic"); file.writeBytes(data); check(file) }
        finally { directory.deleteRecursively() }
    }

    @Test fun explicitStereoIdsWinOverPrimaryAndAuxiliaryOrder() = withFile(fixture()) { file ->
        val info = HeifPhotoInfo.read(file)!!
        assertEquals(99,info.primary); assertEquals(20,info.left); assertEquals(10,info.right)
        assertEquals(1280,info.packedWidth); assertEquals(480,info.height)
        assertEquals(.02,info.disparity,0.0)
        assertEquals(info.left, HeifPhotoInfo.readPrefix(file.readBytes())!!.left)
        assertEquals(PhotoHeader(1280,480,1,true),PhotoHeader.read(file.readBytes()))
    }

    @Test fun heixCompatibilityChangesOnlyPrivateBrandAndPrimaryFields() = withFile(fixture().also {
        "heix".toByteArray().copyInto(it, 8)
        "heix".toByteArray().copyInto(it, 20)
    }) { file ->
        val original=file.readBytes(); val info=HeifPhotoInfo.read(file)!!
        val copy=File(file.parentFile,"android-view.heic"); file.copyTo(copy)
        info.selectPrimary(copy,info.right!!)
        val changed=copy.readBytes()
        assertEquals("heic",String(changed,8,4)); assertEquals("heic",String(changed,20,4))
        val allowed=(8..11).toSet()+(20..23).toSet()+setOf(info.primaryOffset.toInt(),info.primaryOffset.toInt()+1,info.hiddenFlagOffsets[10]!!.toInt())
        assertTrue(original.indices.all { original[it]==changed[it] || it in allowed })
        assertArrayEquals(original,file.readBytes()); assertEquals(file.length(),copy.length())
        assertEquals(10,HeifPhotoInfo.read(copy)!!.primary)
    }

    @Test fun ordinaryHeifDoesNotMistakeOtherImagesForStereo() = withFile(fixture(false)) { file ->
        val info=HeifPhotoInfo.read(file)!!
        assertFalse(info.stereo); assertEquals(99,info.left); assertNull(info.right)
        assertEquals(640,info.packedWidth)
    }

    @Test fun rotationAnd32BitItemIdsRemainValid() = withFile(fixture(wide=true,rotate=true)) { file ->
        val info=HeifPhotoInfo.read(file)!!
        assertEquals(480,info.width); assertEquals(640,info.height); assertEquals(4,info.idBytes)
        val copy=File(file.parentFile,"view.heic"); file.copyTo(copy)
        info.selectPrimary(copy,info.right!!)
        assertEquals(10,HeifPhotoInfo.read(copy)!!.primary)
        assertEquals(99,HeifPhotoInfo.read(file)!!.primary)
        assertEquals(file.length(),copy.length())
    }

    @Test fun cleanApertureIsAppliedBeforeRotation() = withFile(fixture(wide=true,rotate=true,crop=true)) { file ->
        val info=HeifPhotoInfo.read(file)!!
        assertEquals(450,info.width); assertEquals(620,info.height)
    }

    @Test fun spatialFovUsesAssociatedIntrinsicsForBothUuidAndStandardProperties() {
        for (uuid in listOf(false, true)) withFile(fixture(camera=camera(uuid))) { file ->
            val before = file.readBytes(); val info = HeifPhotoInfo.read(file)!!
            assertEquals(90.0,info.horizontalFovDegrees!!,1e-6)
            assertEquals(info.horizontalFovDegrees,HeifPhotoInfo.readPrefix(before)!!.horizontalFovDegrees)
            assertArrayEquals(before,file.readBytes())
        }
    }

    @Test fun fovAccountsForCropRotationAndAnisotropicIntrinsics() {
        withFile(fixture(rotate=true,crop=true,camera=camera())) { file ->
            assertEquals(Math.toDegrees(2*kotlin.math.atan(450.0/640)),HeifPhotoInfo.read(file)!!.horizontalFovDegrees!!,1e-6)
        }
        withFile(fixture(rotate=true,camera=camera(fy=1.0))) { file ->
            assertEquals(Math.toDegrees(2*kotlin.math.atan(.5)),HeifPhotoInfo.read(file)!!.horizontalFovDegrees!!,1e-6)
        }
    }

    @Test fun ordinaryMissingUnsupportedAndOffAxisCamerasHaveNoSpatialFov() {
        withFile(fixture(stereo=false,camera=camera())) { assertNull(HeifPhotoInfo.read(it)!!.horizontalFovDegrees) }
        withFile(fixture()) { assertNull(HeifPhotoInfo.read(it)!!.horizontalFovDegrees) }
        for (property in listOf(camera(fx=-.5),camera(cx=.25),camera(version=1),camera(fy=1.0,skew=1),box("cmin",byteArrayOf(0)))) {
            withFile(fixture(camera=property)) { file ->
                val info = HeifPhotoInfo.read(file)!!
                assertTrue(info.stereo); assertNull(info.horizontalFovDegrees)
            }
        }
    }

    @Test fun selectingAnEyeChangesOnlyPrivatePrimaryAndVisibilityBytes() = withFile(fixture()) { file ->
        val original=file.readBytes(); val info=HeifPhotoInfo.read(file)!!
        val copy=File(file.parentFile,"view.heic"); file.copyTo(copy)
        info.selectPrimary(copy,info.right!!)
        val changed=copy.readBytes()
        val allowed=setOf(info.primaryOffset.toInt(),info.primaryOffset.toInt()+1,info.hiddenFlagOffsets[10]!!.toInt())
        assertTrue(original.indices.all { original[it]==changed[it] || it in allowed })
        assertArrayEquals(original,file.readBytes())
        assertEquals(0,changed[info.hiddenFlagOffsets[10]!!.toInt()].toInt() and 1)
    }

    @Test fun malformedPairsAndTruncatedContainersAreRejected() {
        for (eyes in listOf(listOf(20,20),listOf(20,10,77),listOf(20,1000))) {
            withFile(fixture(eyes=eyes)) { file -> assertTrue(runCatching { HeifPhotoInfo.read(file) }.isFailure) }
        }
        val source=fixture()
        withFile(source.copyOf(source.size-4)) { file -> assertTrue(runCatching { HeifPhotoInfo.read(file) }.isFailure) }
        assertNull(HeifPhotoInfo.readPrefix(source.copyOf(40)))
        withFile(ByteArray(32)) { file -> assertNull(HeifPhotoInfo.read(file)) }
    }

    @Test fun downloadedSpatialOriginalsMatchTheirRecordedEyeIds() {
        val directory=System.getenv("THRU3D_SPATIAL_FIXTURES")?.let { File(it) }
        assumeTrue(directory?.isDirectory == true)
        val files=directory!!.listFiles()!!.filter { it.extension.lowercase() in setOf("heic","heif") && !it.name.startsWith("control-") }
        assertTrue("At least five verified native stereo samples",files.size>=5)
        directory.listFiles()!!.filter { it.name.startsWith("control-") && it.extension.lowercase() in setOf("heic","heif") }.forEach {
            assertFalse("Ordinary iPhone photo is not native stereo", HeifPhotoInfo.read(it)!!.stereo)
        }
        for (file in files) {
            val info=HeifPhotoInfo.read(file)!!
            assertTrue(file.name,info.stereo); assertNotEquals(info.left,info.right)
            assertTrue(info.width>0 && info.height>0)
            assertNotNull("Spatial reference has capture intrinsics: " + file.name,info.horizontalFovDegrees)
            println("Spatial capture FOV: ${file.name} ${info.horizontalFovDegrees}")
            val prefix=file.inputStream().use { it.readNBytes(PhotoHeader.MAX_BYTES) }
            assertEquals(PhotoHeader(info.packedWidth,info.height,1,true),PhotoHeader.read(prefix))
            System.getenv("THRU3D_HEIF_PROBE_OUTPUT")?.let { output ->
                val root=File(output).apply { mkdirs() }
                val left=File(root,file.nameWithoutExtension+"-left.heic")
                val right=File(root,file.nameWithoutExtension+"-right.heic")
                file.copyTo(left,overwrite=true); file.copyTo(right,overwrite=true)
                info.selectPrimary(left,info.left); info.selectPrimary(right,info.right!!)
                File(root,file.nameWithoutExtension+".json").writeText(JSONObject()
                    .put("source",file.name).put("left_item",info.left).put("right_item",info.right)
                    .put("width",info.width).put("height",info.height).put("disparity",info.disparity)
                    .put("horizontal_fov_degrees",info.horizontalFovDegrees)
                    .put("primary",info.primary).toString(2))
            }
        }
    }
}
