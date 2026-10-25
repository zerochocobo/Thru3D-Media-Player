package org.vrpassthroughplayer.plugin

import org.junit.Assert.*
import org.junit.Test
import java.nio.file.Files
import java.io.File

class ClipExportNameTest {
    @Test fun sourceAndMediaRangeAreStableAndDistinguishMilliseconds() {
        val name = ClipExportName.base("Film.mp4", 240000000, 480000000)
        assertEquals("Film_00-04-00.000--00-08-00.000", name)
        assertEquals(name, ClipExportName.base("Film.mp4", 240000000, 480000000))
        assertNotEquals(name, ClipExportName.base("Film.mp4", 240001000, 480000000))
        assertTrue(ClipExportName.base("Film.mkv", 3600000000, 3601000000).contains("01-00-00.000--01-00-01.000"))
    }

    @Test fun namesArePortableLeavesAndBoundedUtf8WithoutSplittingUnicode() {
        val name = ClipExportName.base("folder/演示:*?<>|\"\u0000.mp4", 0, 2000000)
        assertFalse(name.any { it in "/\\:*?<>|\"" || it.code < 32 })
        assertTrue(name.startsWith("演示"))
        assertTrue(ClipExportName.base("CON.mp4", 0, 2000000).startsWith("_CON_"))
        val long = ClipExportName.base("😀".repeat(200) + ".mp4", 0, 2000000)
        assertTrue(long.toByteArray(Charsets.UTF_8).size < 255)
        assertEquals(long, String(long.toByteArray(Charsets.UTF_8), Charsets.UTF_8))
    }

    @Test fun eitherContainerAndUnindexedLocalFilesPreventDuplicateExports() {
        val root = generateSequence(File(System.getProperty("user.dir")).absoluteFile) { it.parentFile }
            .first { File(it, "tools/Build-Player.ps1").isFile }
        val parent = File(root, "build/output/loop-clip/names").apply { mkdirs() }
        val directory = Files.createTempDirectory(parent.toPath(), "case-").toFile()
        val base = ClipExportName.base("Film.mp4", 0, 2000000)
        val local = directory.resolve("$base.mkv")
        try {
            val queried = mutableListOf<String>()
            val indexed = ClipExportName.existing(directory, base) { name ->
                queried += name
                if (name.endsWith(".mkv")) ClipExportName.Existing(name, "content://video/1") else null
            }
            assertEquals(listOf("$base.mp4", "$base.mkv"), queried)
            assertEquals("content://video/1", indexed!!.uri)
            local.writeBytes(byteArrayOf(1, 2, 3))
            assertEquals(local.name, ClipExportName.existing(directory, base) { null }!!.name)
            assertEquals(3, local.length()) // Detection never rewrites the existing output.
            local.writeBytes(byteArrayOf())
            assertNull(ClipExportName.existing(directory, base) { null })
        } finally { local.delete(); directory.delete() }
    }

    @Test fun invalidRangesCannotAcquireAFileName() {
        for ((a, b) in listOf(-1L to 2000000L, 100L to 100L, 200L to 100L)) {
            try { ClipExportName.base("Film.mp4", a, b); fail("Invalid range accepted") }
            catch (_: IllegalArgumentException) { }
        }
    }
}
